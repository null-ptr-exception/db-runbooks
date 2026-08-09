#!/usr/bin/env bash
# =============================================================================
# lib/mongodb-reconfig.sh
# Reconfig gateway: gated rs.reconfig() with plan/apply separation and a
# separate force-dr break-glass path.
#
# Provides:
#   reconfig_plan       — read-only risk report for a set of intent ops
#   reconfig_apply      — execute ops (one reconfig step per op, CAS-guarded)
#   reconfig_force_dr   — DR break-glass: strip votes from an unreachable
#                         site with rs.reconfig({force:true})
#   reconfig_freeze     — toggle the change-freeze annotation on the STS
#
# Design (see docs/mongodb/reconfig.md):
#   * Callers submit INTENT OPS (add_member/remove_member/set_votes/
#     set_priority/set_hidden), never a raw replica-set config document.
#     The library reads the live rs.conf() and projects the ops onto it, so
#     configVersion handling, _id allocation, and field preservation are
#     never the caller's problem.
#   * plan returns a plan_hash binding (namespace, sts, ops, configVersion,
#     term). apply recomputes it — if the live config moved since plan, the
#     hash no longer matches and apply refuses (PLAN_STALE). No stored
#     token, no TTL: the guard is compare-and-swap on the real world.
#   * Every op executes as its own rs.reconfig() step, which trivially
#     satisfies the MongoDB 4.4+ single-voting-change-per-reconfig rule.
#   * block-level findings can never be overridden; warn-level findings
#     require a non-empty override_reason on apply.
#
# Depends on: logging.sh, response.sh, k8s.sh, mongodb.sh,
#             mongodb-recovery.sh (sourced by callers)
# =============================================================================

[[ -n "${_MONGODB_RECONFIG_LIB_LOADED:-}" ]] && return 0
_MONGODB_RECONFIG_LIB_LOADED=1

# Internal-config tier (CLAUDE.md "Configuration Layers"): policy knobs that
# are fixed per deployment. None of these are task inputs.
[[ -f /etc/aqsh/config/mongodb.env ]] && source /etc/aqsh/config/mongodb.env
_RECONFIG_AUDIT_CM="${RECONFIG_AUDIT_CONFIGMAP_DEFAULT:-mongodb-reconfig-audit}"
_RECONFIG_DR_MIN_UNREACHABLE_S="${RECONFIG_DR_MIN_UNREACHABLE_SECONDS_DEFAULT:-300}"
_RECONFIG_LAG_WARN_S="${RECONFIG_LAG_WARN_SECONDS_DEFAULT:-60}"
_RECONFIG_AUDIT_MAX_ENTRIES="${RECONFIG_AUDIT_MAX_ENTRIES_DEFAULT:-20}"

readonly _RECONFIG_ANN_FREEZE="reconfig.db-runbooks/freeze"
readonly _RECONFIG_ANN_FREEZE_REASON="reconfig.db-runbooks/freeze-reason"
readonly _RECONFIG_ANN_DR_ACTIVE="reconfig.db-runbooks/dr-active"
readonly _RECONFIG_ANN_DR_INCIDENT="reconfig.db-runbooks/dr-incident"

# ===========================================================================
# Facts: live topology from mongod + k8s
# ===========================================================================

# ---------------------------------------------------------------------------
# _reconfig_probe_pod <sts_name>
# Echo the name of a Ready pod of the StatefulSet (fallback: any Running pod).
# ---------------------------------------------------------------------------
_reconfig_probe_pod() {
  local sts_name="$1"
  local pods_raw
  pods_raw=$(_recovery_list_pods "$sts_name") || return 1
  local pod ready phase
  while IFS= read -r pod; do
    [[ -z "$pod" ]] && continue
    ready=$(_kubectl get pod "$pod" \
      -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null) || continue
    [[ "$ready" == "True" ]] && { printf '%s\n' "$pod"; return 0; }
  done <<< "$pods_raw"
  while IFS= read -r pod; do
    [[ -z "$pod" ]] && continue
    phase=$(_kubectl get pod "$pod" -o jsonpath='{.status.phase}' 2>/dev/null) || continue
    [[ "$phase" == "Running" ]] && { printf '%s\n' "$pod"; return 0; }
  done <<< "$pods_raw"
  return 1
}

# JS snippet shared by plan/apply/force-dr: one round trip returns config
# members, per-member status/health/lag, and heartbeat ages. lastHeartbeatRecv
# ages are computed inside mongosh (Date math) so bash never parses dates.
# shellcheck disable=SC2016  # single-quoted on purpose: this is JavaScript
readonly _RECONFIG_FACTS_JS='
try {
  var c = rs.conf();
  var s = rs.status();
  var po = 0;
  s.members.forEach(function(m){
    if (m.state === 1 && m.health === 1 && m.optime && m.optime.ts) { po = m.optime.ts.t; }
  });
  var now = Date.now();
  print(JSON.stringify({
    ok: 1,
    set: c._id,
    version: c.version,
    // rs.status().term is a BSON Long in mongosh — JSON.stringify would emit
    // {low,high,unsigned}; force a plain number so jq/bash see a scalar
    term: (s.term !== undefined ? (s.term.toNumber ? s.term.toNumber() : s.term) : 0),
    members: c.members.map(function(m){
      return {_id: m._id, host: m.host, votes: m.votes, priority: m.priority,
              arbiterOnly: !!m.arbiterOnly, hidden: !!m.hidden, tags: (m.tags || {})};
    }),
    status: s.members.map(function(m){
      var hb = -1;
      if (m.self) { hb = 0; }
      else if (m.lastHeartbeatRecv) {
        var t = (typeof m.lastHeartbeatRecv.getTime === "function")
          ? m.lastHeartbeatRecv.getTime() : new Date(m.lastHeartbeatRecv).getTime();
        // epoch(0) means "never heard from" — report a huge age, not 1970-now
        hb = (t > 0) ? Math.floor((now - t) / 1000) : 999999999;
      }
      return {name: m.name, state: m.stateStr, health: (m.health === undefined ? 0 : m.health),
              optime_ts: (m.optime && m.optime.ts) ? m.optime.ts.t : 0,
              lag: (po > 0 && m.optime && m.optime.ts) ? (po - m.optime.ts.t) : null,
              heartbeat_age_s: hb};
    }),
    has_primary: s.members.some(function(m){ return m.state === 1 && m.health === 1; })
  }));
} catch(e) { print(JSON.stringify({ok: 0, errmsg: e.message})); }
'

# ---------------------------------------------------------------------------
# _reconfig_get_facts <sts_name> <user> <pass> [probe_pod]
# Echo the facts JSON ({ok:1, set, version, term, members, status,
# has_primary}) read from probe_pod (auto-picked when omitted). Returns 1
# with an {ok:0} payload on stdout when nothing answers.
# ---------------------------------------------------------------------------
_reconfig_get_facts() {
  local sts_name="$1" user="$2" pass="$3" probe="${4:-}"
  if [[ -z "$probe" ]]; then
    probe=$(_reconfig_probe_pod "$sts_name") || {
      printf '{"ok":0,"errmsg":"no Ready/Running pod found for StatefulSet %s"}\n' "$sts_name"
      return 1
    }
  fi
  local out
  out=$(_recovery_mongosh_pod "$probe" "$user" "$pass" "$_RECONFIG_FACTS_JS" \
    2>/dev/null | tail -1 | tr -d '\r') || out='{"ok":0,"errmsg":"exec failed"}'
  [[ -z "$out" ]] && out='{"ok":0,"errmsg":"empty facts"}'
  if ! printf '%s' "$out" | jq -e '.ok == 1' >/dev/null 2>&1; then
    printf '%s\n' "$out"
    return 1
  fi
  printf '%s\n' "$out"
}

# ---------------------------------------------------------------------------
# _reconfig_zone_map <sts_name>
# Echo JSON [{pod, zone}] joining each STS pod's spec.nodeName to its Node's
# topology.kubernetes.io/zone label. Fails soft: pods with no resolvable
# zone get zone:"" — callers decide whether that skips the simulation.
# ---------------------------------------------------------------------------
_reconfig_zone_map() {
  local sts_name="$1"
  local label_sel pods_json nodes_json
  label_sel=$(_kubectl get statefulset "$sts_name" \
    -o go-template='{{range $k,$v := .spec.selector.matchLabels}}{{$k}}={{$v}},{{end}}' 2>/dev/null \
    | sed 's/,$//') || true
  [[ -z "$label_sel" ]] && { printf '[]\n'; return 0; }
  pods_json=$(_kubectl get pods -l "$label_sel" -o json 2>/dev/null) || { printf '[]\n'; return 0; }
  nodes_json=$(_kubectl_global get nodes -o json 2>/dev/null) || nodes_json='{"items":[]}'
  jq -cn --argjson pods "$pods_json" --argjson nodes "$nodes_json" '
    ($nodes.items | map({key: .metadata.name,
                         value: (.metadata.labels["topology.kubernetes.io/zone"] // "")})
                  | from_entries) as $zones
    | [$pods.items[] | {pod: .metadata.name,
                        zone: ($zones[.spec.nodeName // ""] // "")}]
  ' 2>/dev/null || printf '[]\n'
}

# ===========================================================================
# Intent ops: validation and projection
# ===========================================================================

# jq preamble shared by validation/projection/diff. Member selectors match a
# member by exact host, by pod name ("mongodb-2" matches host
# "mongodb-2.mongodb.ns.svc...:27017"), or by host-without-port.
readonly _RECONFIG_JQ_DEFS='
  def sel_matches($m): (.host == $m)
    or (.host | startswith($m + "."))
    or (.host | startswith($m + ":"));
'

# ---------------------------------------------------------------------------
# reconfig_validate_ops <ops_json>
# Schema-check the intent ops array. Echoes the canonicalised (jq -cS) ops on
# success; echoes {"error": "..."} and returns 1 on any violation.
# ---------------------------------------------------------------------------
reconfig_validate_ops() {
  local ops_json="$1"
  local canon
  if ! canon=$(printf '%s' "$ops_json" | jq -cS . 2>/dev/null); then
    printf '{"error":"ops_json is not valid JSON"}\n'
    return 1
  fi
  local verdict
  verdict=$(jq -cn --argjson ops "$canon" '
    def bad($msg): {error: $msg};
    if ($ops | type) != "array" then bad("ops_json must be a JSON array")
    elif ($ops | length) == 0 then bad("ops_json must contain at least one op")
    elif ($ops | length) > 20 then bad("ops_json exceeds 20 ops — split the change")
    else
      [ $ops[] |
        if (type != "object") then bad("each op must be an object")
        elif .action == "add_member" then
          if ((.host // "") | type) != "string" or (.host // "") == "" then bad("add_member requires host")
          elif (has("votes") and ((.votes | type) != "number" or ((.votes == 0 or .votes == 1) | not))) then bad("add_member votes must be 0 or 1")
          elif (has("priority") and ((.priority | type) != "number" or .priority < 0 or .priority > 1000)) then bad("add_member priority must be 0..1000")
          elif (has("hidden") and (.hidden | type) != "boolean") then bad("add_member hidden must be a boolean")
          else empty end
        elif .action == "remove_member" then
          if ((.member // "") | type) != "string" or (.member // "") == "" then bad("remove_member requires member") else empty end
        elif .action == "set_votes" then
          if ((.member // "") | type) != "string" or (.member // "") == "" then bad("set_votes requires member")
          # NOT `[0,1] | index(.votes)` — the pipe rebinds `.` to [0,1], so
          # `.votes` indexes an array with a string and aborts the whole program
          elif ((.votes | type) != "number" or ((.votes == 0 or .votes == 1) | not)) then bad("set_votes votes must be 0 or 1")
          else empty end
        elif .action == "set_priority" then
          if ((.member // "") | type) != "string" or (.member // "") == "" then bad("set_priority requires member")
          elif ((.priority | type) != "number" or .priority < 0 or .priority > 1000) then bad("set_priority priority must be 0..1000")
          else empty end
        elif .action == "set_hidden" then
          if ((.member // "") | type) != "string" or (.member // "") == "" then bad("set_hidden requires member")
          elif ((.hidden | type) != "boolean") then bad("set_hidden hidden must be a boolean")
          else empty end
        else bad("unknown action: " + ((.action // "missing") | tostring))
        end
      ] | if length > 0 then .[0] else {ok: true} end
    end
  ' 2>/dev/null) || { printf '{"error":"ops schema validation failed"}\n'; return 1; }
  if [[ "$(printf '%s' "$verdict" | jq -r '.ok // empty')" != "true" ]]; then
    printf '%s\n' "$verdict"
    return 1
  fi
  printf '%s\n' "$canon"
}

# ---------------------------------------------------------------------------
# _reconfig_apply_op <members_json> <op_json>
# Project ONE op onto a members array. Echoes the new members array, or
# {"error": "..."} with rc=1. Mirrors MongoDB's own constraints where a wrong
# combination is unrepresentable: votes:0 forces priority:0, hidden:true
# forces priority:0.
# ---------------------------------------------------------------------------
_reconfig_apply_op() {
  local members="$1" op="$2"
  jq -cn --argjson members "$members" --argjson op "$op" "
    ${_RECONFIG_JQ_DEFS}"'
    def err($msg): {error: $msg};
    def resolve($m): [$members[] | select(sel_matches($m))] as $hits
      | if ($hits | length) == 0 then err("member not found in config: " + $m)
        elif ($hits | length) > 1 then err("member selector is ambiguous: " + $m)
        else $hits[0] end;
    $op.action as $a
    | if $a == "add_member" then
        ($op.host | if contains(":") then . else . + ":27017" end) as $host
        | if any($members[]; .host == $host) then err("member already in config: " + $host)
          else
            (([$members[]._id] | max // -1) + 1) as $newid
            | ($op.votes // 1) as $v
            | ($op.hidden // false) as $h
            | (if $h or $v == 0 then 0 else ($op.priority // 1) end) as $p
            | $members + [{_id: $newid, host: $host, votes: $v, priority: $p,
                           arbiterOnly: false, hidden: $h, tags: {}}]
          end
      elif $a == "remove_member" then
        resolve($op.member) as $hit
        | if ($hit | has("error")) then $hit
          else [$members[] | select(._id != $hit._id)] end
      elif $a == "set_votes" then
        resolve($op.member) as $hit
        | if ($hit | has("error")) then $hit
          else [$members[] | if ._id == $hit._id
                then .votes = $op.votes
                     | (if $op.votes == 0 then .priority = 0 else . end)
                else . end]
          end
      elif $a == "set_priority" then
        resolve($op.member) as $hit
        | if ($hit | has("error")) then $hit
          else [$members[] | if ._id == $hit._id then .priority = $op.priority else . end]
          end
      elif $a == "set_hidden" then
        resolve($op.member) as $hit
        | if ($hit | has("error")) then $hit
          else [$members[] | if ._id == $hit._id
                then .hidden = $op.hidden
                     | (if $op.hidden then .priority = 0 else . end)
                else . end]
          end
      else err("unknown action: " + $a)
      end
  '
}

# ---------------------------------------------------------------------------
# _reconfig_project_members <members_json> <ops_json>
# Apply every op in sequence. Echoes the final members array, or
# {"error": "...", "op_index": N} with rc=1 on the first failing op.
# ---------------------------------------------------------------------------
_reconfig_project_members() {
  local members="$1" ops="$2"
  local n i op out
  n=$(printf '%s' "$ops" | jq 'length')
  for (( i = 0; i < n; i++ )); do
    op=$(printf '%s' "$ops" | jq -c ".[$i]")
    out=$(_reconfig_apply_op "$members" "$op") || true
    if printf '%s' "$out" | jq -e 'type == "object" and has("error")' >/dev/null 2>&1; then
      printf '%s' "$out" | jq -c --argjson i "$i" '. + {op_index: $i}'
      return 1
    fi
    members="$out"
  done
  printf '%s\n' "$members"
}

# ---------------------------------------------------------------------------
# _reconfig_diff <before_members> <after_members>
# Echo {added, removed, vote_changes, priority_changes, hidden_changes}.
# ---------------------------------------------------------------------------
_reconfig_diff() {
  local before="$1" after="$2"
  jq -cn --argjson b "$before" --argjson a "$after" '
    ([$b[].host]) as $bh | ([$a[].host]) as $ah
    | {
        added:   [$a[] | select(.host as $h | $bh | index($h) | not) | .host],
        removed: [$b[] | select(.host as $h | $ah | index($h) | not) | .host],
        vote_changes: [ $a[] as $m | ($b[] | select(.host == $m.host)) as $o
                        | select($o.votes != $m.votes)
                        | {host: $m.host, from: $o.votes, to: $m.votes} ],
        priority_changes: [ $a[] as $m | ($b[] | select(.host == $m.host)) as $o
                            | select($o.priority != $m.priority)
                            | {host: $m.host, from: $o.priority, to: $m.priority} ],
        hidden_changes: [ $a[] as $m | ($b[] | select(.host == $m.host)) as $o
                          | select($o.hidden != $m.hidden)
                          | {host: $m.host, from: $o.hidden, to: $m.hidden} ]
      }
  '
}

# ---------------------------------------------------------------------------
# _reconfig_plan_hash <namespace> <sts> <canonical_ops> <version> <term>
# Stateless CAS token: apply recomputes this from the live config — any
# drift in ops or configVersion/term invalidates it. No storage, no TTL.
# ---------------------------------------------------------------------------
_reconfig_plan_hash() {
  local ns="$1" sts="$2" ops="$3" version="$4" term="$5"
  local h
  h=$(printf '%s|%s|%s|%s|%s' "$ns" "$sts" "$ops" "$version" "$term" \
    | sha256sum | cut -c1-24)
  printf 'rcp%s' "$h"
}

# ===========================================================================
# Freeze / DR annotations
# ===========================================================================

# ---------------------------------------------------------------------------
# _reconfig_get_annotation <sts_name> <key>
# ---------------------------------------------------------------------------
_reconfig_get_annotation() {
  local sts_name="$1" key="$2"
  # kubectl's jsonpath dialect needs dots escaped even inside bracket quotes;
  # go through jq instead — no escaping rules to get wrong
  _kubectl get statefulset "$sts_name" -o json 2>/dev/null \
    | jq -r --arg k "$key" '.metadata.annotations[$k] // ""' 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# _reconfig_set_annotations <sts_name> <json_object_of_annotations>
# Values of null remove the annotation (kubectl merge-patch semantics).
# ---------------------------------------------------------------------------
_reconfig_set_annotations() {
  local sts_name="$1" ann_json="$2"
  local patch
  patch=$(jq -cn --argjson a "$ann_json" '{metadata: {annotations: $a}}')
  _kubectl patch statefulset "$sts_name" --type=merge -p "$patch" >/dev/null
}

# ---------------------------------------------------------------------------
# reconfig_freeze <sts_name> <enabled true|false> <reason>
# ---------------------------------------------------------------------------
reconfig_freeze() {
  local sts_name="$1" enabled="$2" reason="$3"
  local op="reconfig_freeze"
  local ann
  if [[ "$enabled" == "true" ]]; then
    ann=$(jq -cn --arg k1 "$_RECONFIG_ANN_FREEZE" --arg k2 "$_RECONFIG_ANN_FREEZE_REASON" \
      --arg r "$reason" '{($k1): "true", ($k2): $r}')
  else
    ann=$(jq -cn --arg k1 "$_RECONFIG_ANN_FREEZE" --arg k2 "$_RECONFIG_ANN_FREEZE_REASON" \
      '{($k1): null, ($k2): null}')
  fi
  if ! _reconfig_set_annotations "$sts_name" "$ann"; then
    response_err "$op" "Failed to patch freeze annotation on StatefulSet ${sts_name}" '{}' 1
    return 1
  fi
  local audit_entry
  audit_entry=$(jq -cn --arg sts "$sts_name" --arg enabled "$enabled" --arg reason "$reason" \
    '{action: "freeze", sts: $sts, enabled: $enabled, reason: $reason}')
  local audited=true
  reconfig_audit_append "$audit_entry" || audited=false
  response_ok "$op" "Freeze ${enabled} on StatefulSet ${sts_name}" \
    "{\"sts\":\"${sts_name}\",\"freeze\":${enabled},\"reason\":\"$(_escape_json_string "$reason")\",\"audited\":${audited}}"
}

# ===========================================================================
# Audit trail (per-namespace ConfigMap ring buffer)
# ===========================================================================

# ---------------------------------------------------------------------------
# reconfig_audit_append <entry_json>
# Append an entry ({ts, operator...} added here) to the audit ConfigMap,
# keeping the newest $_RECONFIG_AUDIT_MAX_ENTRIES. Fails soft (rc=1, logged):
# an audit-write failure is reported as audited:false in the task response
# rather than rolling back an already-executed reconfig.
# ---------------------------------------------------------------------------
reconfig_audit_append() {
  local entry="$1"
  local op="reconfig_audit_append"
  local stamped
  stamped=$(printf '%s' "$entry" | jq -c --arg ts "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" \
    '. + {ts: $ts}') || { log_error "$op" "Audit entry is not valid JSON"; return 1; }

  # create-if-missing: RBAC grants namespace-wide create + name-pinned get/patch
  if ! _kubectl get configmap "$_RECONFIG_AUDIT_CM" >/dev/null 2>&1; then
    _kubectl create configmap "$_RECONFIG_AUDIT_CM" --from-literal=entries='[]' \
      >/dev/null 2>&1 || true   # concurrent create is fine — we re-read below
  fi
  local entries
  entries=$(_kubectl get configmap "$_RECONFIG_AUDIT_CM" \
    -o jsonpath='{.data.entries}' 2>/dev/null) || entries='[]'
  [[ -z "$entries" ]] && entries='[]'
  local new_entries patch
  new_entries=$(jq -cn --argjson cur "$entries" --argjson e "$stamped" \
    --argjson max "$_RECONFIG_AUDIT_MAX_ENTRIES" \
    '($cur + [$e]) | .[- $max:]' 2>/dev/null) || {
    log_error "$op" "Existing audit entries are corrupt — resetting ring buffer"
    new_entries=$(jq -cn --argjson e "$stamped" '[$e]')
  }
  patch=$(jq -cn --arg e "$new_entries" '{data: {entries: $e}}')
  if ! _kubectl patch configmap "$_RECONFIG_AUDIT_CM" --type=merge -p "$patch" >/dev/null 2>&1; then
    log_error "$op" "Failed to write audit entry to ConfigMap ${_RECONFIG_AUDIT_CM}"
    return 1
  fi
  return 0
}

# ===========================================================================
# Check engine
# ===========================================================================

# ---------------------------------------------------------------------------
# reconfig_run_checks <sts_name> <canonical_ops> <user> <pass>
# Run every gate against live facts and echo one JSON document:
#   {risk_level, checks[], diff, projected_members, current_version, term,
#    plan_hash, steps, facts}
# rc=1 only when facts themselves are unreadable (no report possible).
# block/warn findings are DATA in the report, not an error.
# ---------------------------------------------------------------------------
reconfig_run_checks() {
  local sts_name="$1" ops="$2" user="$3" pass="$4"
  local op="reconfig_run_checks"

  local facts
  facts=$(_reconfig_get_facts "$sts_name" "$user" "$pass") || {
    printf '%s\n' "$facts"
    return 1
  }
  local members version term
  members=$(printf '%s' "$facts" | jq -c '.members')
  version=$(printf '%s' "$facts" | jq -r '.version')
  term=$(printf '%s' "$facts" | jq -r '.term')

  local checks="[]"
  _add_check() {  # <id> <status> <detail>
    checks=$(printf '%s' "$checks" | jq -c --arg id "$1" --arg st "$2" --arg d "$3" \
      '. + [{id: $id, status: $st, detail: $d}]')
  }

  # ── projection (block: unresolvable ops) ──────────────────────────────────
  local projected proj_err=""
  projected=$(_reconfig_project_members "$members" "$ops") || {
    proj_err=$(printf '%s' "$projected" | jq -r '"op[" + (.op_index | tostring) + "]: " + .error')
    _add_check "member_resolution" "block" "$proj_err"
    projected="$members"
  }
  [[ -z "$proj_err" ]] && _add_check "member_resolution" "pass" "all ops resolve against the live config"

  # ── projected structure (block) ────────────────────────────────────────────
  if [[ -z "$proj_err" ]]; then
    local struct
    struct=$(jq -cn --argjson m "$projected" '
      ([$m[] | select(.votes == 1)] | length) as $voting
      | ([$m[] | select(.votes == 1 and .priority > 0)] | length) as $electable
      | if $voting == 0 then {st: "block", d: "projected config has zero voting members"}
        elif $voting > 7 then {st: "block", d: "projected config has \($voting) voting members (MongoDB max is 7)"}
        elif $electable == 0 then {st: "block", d: "no voting member has priority > 0 — nothing could ever be elected primary"}
        else {st: "pass", d: "\($voting) voting member(s), \($electable) electable"} end')
    _add_check "projected_structure" "$(printf '%s' "$struct" | jq -r '.st')" \
      "$(printf '%s' "$struct" | jq -r '.d')"
  fi

  # ── k8s cross-check (block for local hosts, warn for drift/foreign) ───────
  local sts_pods headless_svc
  sts_pods=$(_recovery_list_pods "$sts_name" 2>/dev/null | tr '\n' ' ') || sts_pods=""
  # Pod FQDNs embed the STS's spec.serviceName, which is not guaranteed to
  # equal the STS name (Bitnami: "<release>-headless") — match on the
  # resolved headless service, plus the STS name itself for the conventional
  # layout, so a local host is never misclassified as cross-cluster.
  headless_svc=$(recovery_resolve_headless_service "$sts_name")
  local k8s_findings
  k8s_findings=$(jq -cn --argjson ops "$ops" --argjson m "$members" \
    --arg pods "$sts_pods" --arg sts "$sts_name" --arg svc "$headless_svc" --arg ns "$K8S_NAMESPACE" '
    ($pods | split(" ") | map(select(. != ""))) as $podlist
    | (["." + $sts + "." + $ns + ".", "." + $svc + "." + $ns + "."] | unique) as $local_markers
    | def is_local($fqdn):
        any($local_markers[]; . as $mk | $fqdn | contains($mk))
        or ($fqdn | endswith("." + $sts)) or ($fqdn | endswith("." + $svc));
    [ $ops[] | select(.action == "add_member")
        | (.host | if contains(":") then split(":")[0] else . end) as $fqdn
        | ($fqdn | split(".")[0]) as $podname
        | if is_local($fqdn) then
            if ($podlist | index($podname)) then empty
            else {st: "block", d: ("add_member host " + $fqdn + " matches this StatefulSet naming but pod " + $podname + " does not exist — scale the StatefulSet first")}
            end
          else {st: "warn", d: ("add_member host " + $fqdn + " is not locally verifiable (cross-cluster member?) — confirm it is reachable before apply")}
          end ]
    + [ $m[] | (.host | if contains(":") then split(":")[0] else . end) as $fqdn
        | ($fqdn | split(".")[0]) as $podname
        | select(is_local($fqdn) and (($podlist | index($podname)) | not))
        | {st: "warn", d: ("existing member " + .host + " has no backing pod in this cluster — config/StatefulSet drift")} ]
    | if length == 0 then [{st: "pass", d: "members and StatefulSet pods are consistent"}] else . end
  ')
  local n_findings i finding
  n_findings=$(printf '%s' "$k8s_findings" | jq 'length')
  for (( i = 0; i < n_findings; i++ )); do
    finding=$(printf '%s' "$k8s_findings" | jq -c ".[$i]")
    _add_check "k8s_member_check" "$(printf '%s' "$finding" | jq -r '.st')" \
      "$(printf '%s' "$finding" | jq -r '.d')"
  done

  # ── freeze / DR annotations (block) ───────────────────────────────────────
  local frozen dr_active
  frozen=$(_reconfig_get_annotation "$sts_name" "$_RECONFIG_ANN_FREEZE")
  dr_active=$(_reconfig_get_annotation "$sts_name" "$_RECONFIG_ANN_DR_ACTIVE")
  if [[ "$frozen" == "true" ]]; then
    local freeze_reason
    freeze_reason=$(_reconfig_get_annotation "$sts_name" "$_RECONFIG_ANN_FREEZE_REASON")
    _add_check "change_window" "block" "change freeze is active on ${sts_name}: ${freeze_reason:-no reason recorded}"
  else
    _add_check "change_window" "pass" "no change freeze"
  fi
  if [[ "$dr_active" == "true" ]]; then
    _add_check "dr_state" "warn" "dr-active is set (incident: $(_reconfig_get_annotation "$sts_name" "$_RECONFIG_ANN_DR_INCIDENT")) — this apply should be the post-DR recovery flow (rejoin members hidden+votes:0 first, restore votes only after lag catches up)"
  else
    _add_check "dr_state" "pass" "no active DR"
  fi

  # ── vote parity (warn) ────────────────────────────────────────────────────
  local total_votes
  total_votes=$(printf '%s' "$projected" | jq '[.[].votes] | add // 0')
  if (( total_votes % 2 == 0 )); then
    _add_check "vote_parity" "warn" "projected total votes = ${total_votes} (even) — a 50/50 split cannot elect; prefer an odd count via a third-site witness, not an arbiter co-located with an existing site"
  else
    _add_check "vote_parity" "pass" "projected total votes = ${total_votes} (odd)"
  fi

  # ── PSA / arbiter (warn) ──────────────────────────────────────────────────
  if printf '%s' "$projected" | jq -e 'any(.[]; .arbiterOnly)' >/dev/null; then
    _add_check "psa_arbiter" "warn" "config contains an arbiter — majority write concern can stall and rollbacks grow under PSA when a data-bearing member is down"
  else
    _add_check "psa_arbiter" "pass" "no arbiter"
  fi

  # ── member health (warn) ──────────────────────────────────────────────────
  local unhealthy
  unhealthy=$(printf '%s' "$facts" | jq -c --argjson lagwarn "$_RECONFIG_LAG_WARN_S" \
    '[.status[] | select(.health != 1 or ((.lag // 0) > $lagwarn)) | {name, state, health, lag}]')
  if [[ "$(printf '%s' "$unhealthy" | jq 'length')" -gt 0 ]]; then
    _add_check "member_health" "warn" "cluster is not fully healthy — reconfig on an unstable set amplifies risk: $(printf '%s' "$unhealthy" | jq -c .)"
  else
    _add_check "member_health" "pass" "all members healthy, lag within ${_RECONFIG_LAG_WARN_S}s"
  fi

  # ── primary impact (warn) ─────────────────────────────────────────────────
  local primary_host
  primary_host=$(printf '%s' "$facts" | jq -r '[.status[] | select(.state == "PRIMARY" and .health == 1)][0].name // ""')
  if [[ -n "$primary_host" ]]; then
    local primary_impact
    primary_impact=$(jq -cn --argjson b "$members" --argjson a "$projected" --arg p "$primary_host" '
      ([$b[] | select(.host == $p)][0] // null) as $before
      | ([$a[] | select(.host == $p)][0] // null) as $after
      | if $before == null then "none"
        elif $after == null then "removed"
        elif ($after.votes == 0 and $before.votes == 1) or ($after.priority == 0 and $before.priority > 0) then "demoted"
        else "none" end')
    if [[ "$primary_impact" != '"none"' ]]; then
      _add_check "primary_impact" "warn" "this change ${primary_impact//\"/} the current primary (${primary_host}) — expect a stepdown and election"
    else
      _add_check "primary_impact" "pass" "current primary unaffected"
    fi
  fi

  # ── zone quorum simulation (warn / skip — never guesses) ─────────────────
  local zone_map
  zone_map=$(_reconfig_zone_map "$sts_name")
  local zone_sim
  zone_sim=$(jq -cn --argjson zm "$zone_map" --argjson m "$projected" --argjson st "$(printf '%s' "$facts" | jq -c '.status')" '
    ($zm | map({key: .pod, value: .zone}) | from_entries) as $podzone
    | [ $m[] | select(.votes == 1) | . as $mem
        | ($mem.host | split(".")[0]) as $pod
        # a member added by this plan has no rs.status entry yet — count it
        # as healthy, the k8s_member_check gate already vetted its pod
        | ([$st[] | select(.name == $mem.host)][0]) as $s
        | {host: $mem.host, votes: $mem.votes,
           zone: ($podzone[$pod] // ""),
           healthy: (if $s == null then true else ($s.health == 1) end)} ] as $voters
    | ([$voters[].zone] | unique) as $zones
    | ([$voters[].votes] | add // 0) as $total
    | (($total / 2 | floor) + 1) as $majority
    | if any($voters[]; .zone == "") then
        {mode: "skip", detail: "one or more voting members have no resolvable zone label — simulation skipped (never guesses)"}
      elif ($zones | length) == 1 then
        {mode: "single_zone", zone: $zones[0]}
      else
        {mode: "simulated", majority: $majority, total: $total,
         zones: [ $zones[] as $z
                  | {zone: $z,
                     surviving_healthy_votes: ([$voters[] | select(.zone != $z and .healthy) | .votes] | add // 0)}
                  | . + {survives: (.surviving_healthy_votes >= $majority)} ]}
      end
  ')
  local sim_mode
  sim_mode=$(printf '%s' "$zone_sim" | jq -r '.mode')
  case "$sim_mode" in
    skip)
      _add_check "zone_quorum" "skip" "$(printf '%s' "$zone_sim" | jq -r '.detail')"
      ;;
    single_zone)
      _add_check "zone_quorum" "warn" "all voting members sit in one zone ($(printf '%s' "$zone_sim" | jq -r '.zone')) — a single zone outage takes the whole set down"
      ;;
    simulated)
      local nz z_entry z_name
      nz=$(printf '%s' "$zone_sim" | jq '.zones | length')
      for (( i = 0; i < nz; i++ )); do
        z_entry=$(printf '%s' "$zone_sim" | jq -c ".zones[$i]")
        z_name=$(printf '%s' "$z_entry" | jq -r '.zone')
        if [[ "$(printf '%s' "$z_entry" | jq -r '.survives')" == "true" ]]; then
          _add_check "zone_quorum_${z_name}_down" "pass" \
            "if zone ${z_name} is lost, $(printf '%s' "$z_entry" | jq -r '.surviving_healthy_votes')/$(printf '%s' "$zone_sim" | jq -r '.total') healthy votes remain (majority: $(printf '%s' "$zone_sim" | jq -r '.majority'))"
        else
          _add_check "zone_quorum_${z_name}_down" "warn" \
            "if zone ${z_name} is lost, only $(printf '%s' "$z_entry" | jq -r '.surviving_healthy_votes')/$(printf '%s' "$zone_sim" | jq -r '.total') healthy votes remain — no automatic election (majority: $(printf '%s' "$zone_sim" | jq -r '.majority'))"
        fi
      done
      ;;
  esac

  # ── assemble report ───────────────────────────────────────────────────────
  local risk="pass"
  if printf '%s' "$checks" | jq -e 'any(.[]; .status == "warn")' >/dev/null; then risk="warn"; fi
  if printf '%s' "$checks" | jq -e 'any(.[]; .status == "block")' >/dev/null; then risk="block"; fi

  local diff steps plan_hash
  diff=$(_reconfig_diff "$members" "$projected")
  steps=$(printf '%s' "$ops" | jq 'length')
  plan_hash=$(_reconfig_plan_hash "$K8S_NAMESPACE" "$sts_name" "$ops" "$version" "$term")

  jq -cn \
    --arg risk "$risk" \
    --argjson checks "$checks" \
    --argjson diff "$diff" \
    --argjson projected "$projected" \
    --argjson version "$version" \
    --argjson term "$term" \
    --argjson steps "$steps" \
    --arg hash "$plan_hash" \
    --argjson facts "$facts" \
    '{risk_level: $risk, checks: $checks, diff: $diff,
      projected_members: $projected, current_version: $version, term: $term,
      steps: $steps, plan_hash: $hash,
      health: {has_primary: $facts.has_primary, status: $facts.status}}'
}

# ===========================================================================
# plan / apply
# ===========================================================================

# ---------------------------------------------------------------------------
# reconfig_plan <sts_name> <ops_json> <user> <pass>
# ---------------------------------------------------------------------------
reconfig_plan() {
  local sts_name="$1" ops_json="$2" user="$3" pass="$4"
  local op="reconfig_plan"

  local ops
  ops=$(reconfig_validate_ops "$ops_json") || {
    response_err "$op" "Invalid ops_json" "$ops" 1
    return 1
  }
  local report
  report=$(reconfig_run_checks "$sts_name" "$ops" "$user" "$pass") || {
    response_err "$op" "Cannot read replica set facts" "$report" 1
    return 1
  }
  local risk
  risk=$(printf '%s' "$report" | jq -r '.risk_level')
  log_info "$op" "Plan for ${sts_name}: risk_level=${risk}"
  response_ok "$op" "Plan complete: risk_level=${risk}" "$report"
}

# JS template for one apply step: swap in the projected members, CAS on the
# version we just read, and run a NON-force reconfig on the primary.
# Placeholders __EXPECTED_VERSION__ / __MEMBERS_JSON__ / __FORCE__ are
# substituted by _reconfig_exec_step.
# shellcheck disable=SC2016
readonly _RECONFIG_STEP_JS_TEMPLATE='
try {
  var cfg = rs.conf();
  if (cfg.version !== __EXPECTED_VERSION__) {
    print(JSON.stringify({ok: 0, errmsg: "config version moved during apply: expected __EXPECTED_VERSION__, found " + cfg.version}));
  } else {
    cfg.members = __MEMBERS_JSON__;
    cfg.version = cfg.version + 1;
    print(JSON.stringify(rs.reconfig(cfg, {force: __FORCE__})));
  }
} catch(e) { print(JSON.stringify({ok: 0, errmsg: e.message})); }
'

# ---------------------------------------------------------------------------
# _reconfig_exec_step <exec_fn_pod> <target primary_host|""> <user> <pass>
#                     <expected_version> <members_json> <force true|false>
# When target is empty the step runs directly on exec_fn_pod (force-dr path);
# otherwise it runs from exec_fn_pod against primary_host (normal path).
# ---------------------------------------------------------------------------
_reconfig_exec_step() {
  local pod="$1" target="$2" user="$3" pass="$4"
  local expected_version="$5" members_json="$6" force="$7"
  local js="$_RECONFIG_STEP_JS_TEMPLATE"
  js="${js//__EXPECTED_VERSION__/$expected_version}"
  js="${js//__MEMBERS_JSON__/$members_json}"
  js="${js//__FORCE__/$force}"
  local out
  if [[ -n "$target" ]]; then
    out=$(_recovery_mongosh_host "$pod" "$target" "$user" "$pass" "$js" \
      2>/dev/null | tail -1 | tr -d '\r') || out='{"ok":0,"errmsg":"exec failed"}'
  else
    out=$(_recovery_mongosh_pod "$pod" "$user" "$pass" "$js" \
      2>/dev/null | tail -1 | tr -d '\r') || out='{"ok":0,"errmsg":"exec failed"}'
  fi
  [[ -z "$out" ]] && out='{"ok":0,"errmsg":"empty reconfig result"}'
  printf '%s\n' "$out"
}

# ---------------------------------------------------------------------------
# reconfig_apply <sts_name> <ops_json> <plan_hash> <override_reason>
#                <requested_by> <request_id> <user> <pass>
# ---------------------------------------------------------------------------
reconfig_apply() {
  local sts_name="$1" ops_json="$2" plan_hash="$3" override_reason="$4"
  local requested_by="$5" request_id="$6" user="$7" pass="$8"
  local op="reconfig_apply"

  local ops
  ops=$(reconfig_validate_ops "$ops_json") || {
    response_err "$op" "Invalid ops_json" "$ops" 1
    return 1
  }
  [[ -z "$plan_hash" ]] && {
    response_err "$op" "plan_hash is required — run reconfig/plan first and pass its plan_hash" \
      '{"code":"PLAN_HASH_REQUIRED"}' 1
    return 1
  }

  # Re-run every gate against the live world (apply never trusts a stale report)
  local report
  report=$(reconfig_run_checks "$sts_name" "$ops" "$user" "$pass") || {
    response_err "$op" "Cannot read replica set facts" '{}' 1
    return 1
  }
  local risk
  risk=$(printf '%s' "$report" | jq -r '.risk_level')

  if [[ "$risk" == "block" ]]; then
    response_err "$op" "Apply refused: block-level findings cannot be overridden" \
      "$(printf '%s' "$report" | jq -c '{code: "BLOCKED", risk_level, checks: [.checks[] | select(.status == "block")]}')" 1
    return 1
  fi
  if [[ "$risk" == "warn" && -z "$override_reason" ]]; then
    response_err "$op" "Apply refused: warn-level findings require override_reason" \
      "$(printf '%s' "$report" | jq -c '{code: "OVERRIDE_REQUIRED", risk_level, checks: [.checks[] | select(.status == "warn")]}')" 1
    return 1
  fi

  # CAS: the recomputed hash embeds the LIVE configVersion/term — a mismatch
  # means either the ops differ from what was planned or the config moved.
  local live_hash
  live_hash=$(printf '%s' "$report" | jq -r '.plan_hash')
  if [[ "$live_hash" != "$plan_hash" ]]; then
    response_err "$op" "Apply refused: plan is stale (config changed since plan, or ops differ) — re-run reconfig/plan" \
      "$(jq -cn --arg got "$plan_hash" --arg want "$live_hash" \
        '{code: "PLAN_STALE", submitted_hash: $got, live_hash: $want}')" 1
    return 1
  fi

  # Normal reconfig needs a primary; without one, this is a recovery problem,
  # not a change-management problem — refuse and point at the right tools.
  if [[ "$(printf '%s' "$report" | jq -r '.health.has_primary')" != "true" ]]; then
    response_err "$op" "No primary elected — normal reconfig is impossible. Use recovery/fix-no-primary, or reconfig/force-dr for a site-loss DR" \
      '{"code":"NO_PRIMARY"}' 1
    return 1
  fi

  local probe primary_host
  probe=$(_reconfig_probe_pod "$sts_name") || {
    response_err "$op" "No Ready/Running pod to execute from" '{}' 1
    return 1
  }
  primary_host=$(_recovery_primary_host "$sts_name" "$user" "$pass") || {
    response_err "$op" "Cannot resolve primary host" '{}' 1
    return 1
  }

  local pre_conf
  pre_conf=$(_reconfig_get_facts "$sts_name" "$user" "$pass" "$probe" | jq -c '{version, members}')

  # ── execute: one op per reconfig step (safe-reconfig compliant) ───────────
  local n i step_op members expected_version projected step_out
  n=$(printf '%s' "$ops" | jq 'length')
  local step_results="[]"
  for (( i = 0; i < n; i++ )); do
    step_op=$(printf '%s' "$ops" | jq -c ".[$i]")

    # Fresh read before each step: version for CAS + members for projection
    local step_facts
    step_facts=$(_reconfig_get_facts "$sts_name" "$user" "$pass" "$probe") || {
      response_err "$op" "Lost contact with replica set at step $((i + 1))/${n}" \
        "$(jq -cn --argjson completed "$step_results" '{code: "STEP_FACTS_FAILED", completed_steps: $completed}')" 1
      return 1
    }
    members=$(printf '%s' "$step_facts" | jq -c '.members')
    expected_version=$(printf '%s' "$step_facts" | jq -r '.version')
    projected=$(_reconfig_apply_op "$members" "$step_op") || true
    if printf '%s' "$projected" | jq -e 'type == "object" and has("error")' >/dev/null 2>&1; then
      response_err "$op" "Step $((i + 1))/${n} no longer applies to the live config" \
        "$(jq -cn --argjson e "$projected" --argjson completed "$step_results" \
          '{code: "STEP_PROJECTION_FAILED", detail: $e, completed_steps: $completed}')" 1
      return 1
    fi

    log_info "$op" "Step $((i + 1))/${n}: $(printf '%s' "$step_op" | jq -r '.action') (expected version ${expected_version})"
    step_out=$(_reconfig_exec_step "$probe" "$primary_host" "$user" "$pass" \
      "$expected_version" "$projected" "false")
    if ! printf '%s' "$step_out" | jq -e '.ok == 1' >/dev/null 2>&1; then
      local audit_fail
      audit_fail=$(jq -cn --arg sts "$sts_name" --argjson ops "$ops" --argjson i "$i" \
        --argjson result "$step_out" --arg by "$requested_by" --arg rid "$request_id" \
        '{action: "apply", outcome: "failed", sts: $sts, ops: $ops, failed_step: $i,
          result: $result, requested_by: $by, request_id: $rid}')
      reconfig_audit_append "$audit_fail" || true
      response_err "$op" "rs.reconfig failed at step $((i + 1))/${n}" \
        "$(jq -cn --argjson r "$step_out" --argjson completed "$step_results" \
          '{code: "RECONFIG_FAILED", result: $r, completed_steps: $completed}')" 1
      return 1
    fi
    step_results=$(printf '%s' "$step_results" | jq -c --argjson s "$step_op" \
      '. + [{op: $s, ok: true}]')
    # A step that touched the primary itself may trigger a stepdown; give the
    # set a moment and re-resolve the primary for the next step.
    if (( i + 1 < n )); then
      sleep 2
      primary_host=$(_recovery_primary_host "$sts_name" "$user" "$pass") || {
        response_err "$op" "Primary lost between steps $((i + 1)) and $((i + 2)) — remaining ops not applied" \
          "$(jq -cn --argjson completed "$step_results" '{code: "PRIMARY_LOST_MID_APPLY", completed_steps: $completed}')" 1
        return 1
      }
      probe=$(_reconfig_probe_pod "$sts_name") || probe="$probe"
    fi
  done

  # ── post-verify: primary still there, capture the resulting config ────────
  local elapsed=0 post_facts="" post_ok=false
  while (( elapsed < 60 )); do
    post_facts=$(_reconfig_get_facts "$sts_name" "$user" "$pass" 2>/dev/null) && \
      [[ "$(printf '%s' "$post_facts" | jq -r '.has_primary')" == "true" ]] && { post_ok=true; break; }
    sleep 5; elapsed=$((elapsed + 5))
  done

  # Successful gated apply ends any DR state: config management is back on
  # the normal path.
  local dr_cleared=false
  if [[ "$(_reconfig_get_annotation "$sts_name" "$_RECONFIG_ANN_DR_ACTIVE")" == "true" ]]; then
    _reconfig_set_annotations "$sts_name" \
      "$(jq -cn --arg k1 "$_RECONFIG_ANN_DR_ACTIVE" --arg k2 "$_RECONFIG_ANN_DR_INCIDENT" \
        '{($k1): null, ($k2): null}')" && dr_cleared=true
  fi

  # NOTE: not ${post_facts:-{}} — bash closes the expansion at the FIRST `}`,
  # so a non-empty value would gain a stray trailing brace and corrupt the JSON
  local post_conf
  [[ -z "$post_facts" ]] && post_facts='{}'
  post_conf=$(printf '%s' "$post_facts" | jq -c '{version: (.version // null), members: (.members // [])}')
  local audited=true
  local audit_entry
  audit_entry=$(jq -cn --arg sts "$sts_name" --argjson ops "$ops" \
    --argjson pre "$pre_conf" --argjson post "$post_conf" \
    --arg by "$requested_by" --arg rid "$request_id" --arg reason "$override_reason" \
    --arg risk "$risk" --arg hash "$plan_hash" \
    '{action: "apply", outcome: "success", sts: $sts, ops: $ops, risk_level: $risk,
      plan_hash: $hash, override_reason: $reason, pre: $pre, post: $post,
      requested_by: $by, request_id: $rid}')
  reconfig_audit_append "$audit_entry" || audited=false

  local result
  result=$(jq -cn \
    --arg sts "$sts_name" \
    --argjson steps "$step_results" \
    --argjson pre "$pre_conf" \
    --argjson post "$post_conf" \
    --argjson post_ok "$post_ok" \
    --argjson audited "$audited" \
    --argjson dr_cleared "$dr_cleared" \
    --arg risk "$risk" \
    '{sts: $sts, risk_level: $risk, steps: $steps, pre: $pre, post: $post,
      primary_ok_after_apply: $post_ok, audited: $audited, dr_cleared: $dr_cleared}')
  if [[ "$post_ok" != "true" ]]; then
    response_err "$op" "Reconfig steps applied but no healthy primary observed within 60s — investigate before further changes" \
      "$result" 1
    return 1
  fi
  response_ok "$op" "Reconfig applied: ${n} step(s), primary healthy" "$result"
}

# ===========================================================================
# force-dr
# ===========================================================================

# ---------------------------------------------------------------------------
# _reconfig_dr_preconditions <sts_name> <user> <pass>
# Evaluate the three machine-checkable break-glass preconditions from live
# state (never cached):
#   P1 no elected primary anywhere in the set
#   P2 surviving healthy votes below majority (force is actually needed)
#   P3 every unreachable VOTING member unheard-of for >= threshold seconds
# Echoes {ready, preconditions[], survivors[], unreachable[], facts}.
# rc=1 when no survivor answers at all.
# ---------------------------------------------------------------------------
_reconfig_dr_preconditions() {
  local sts_name="$1" user="$2" pass="$3"
  local op="reconfig_dr_preconditions"

  # Freshest-optime survivor view (same selection as recovery_fix_reconfig)
  local pods_raw survivor="" latest_optime=-1 survivors="[]"
  pods_raw=$(_recovery_list_pods "$sts_name") || pods_raw=""
  local pod phase optime
  while IFS= read -r pod; do
    [[ -z "$pod" ]] && continue
    phase=$(_kubectl get pod "$pod" -o jsonpath='{.status.phase}' 2>/dev/null) || continue
    [[ "$phase" != "Running" ]] && continue
    optime=$(_recovery_mongosh_pod "$pod" "$user" "$pass" \
      "try{var s=rs.status();var m=s.members.filter(function(x){return x.self;})[0];print(m.optime?m.optime.ts.t:0);}catch(e){print('-1');}" \
      2>/dev/null | tail -1 | tr -d '\r') || optime="-1"
    [[ "$optime" =~ ^[0-9]+$ ]] || continue
    survivors=$(printf '%s' "$survivors" | jq -c --arg p "$pod" --argjson o "$optime" \
      '. + [{pod: $p, optime_ts: $o}]')
    if (( optime > latest_optime )); then latest_optime="$optime"; survivor="$pod"; fi
  done <<< "$pods_raw"

  if [[ -z "$survivor" ]]; then
    printf '{"ready":false,"error":"no reachable surviving mongod — force-dr has nothing to execute from"}\n'
    return 1
  fi

  local facts
  facts=$(_reconfig_get_facts "$sts_name" "$user" "$pass" "$survivor") || {
    printf '{"ready":false,"error":"cannot read rs.status/rs.conf from survivor %s"}\n' "$survivor"
    return 1
  }

  jq -cn --argjson facts "$facts" --argjson survivors "$survivors" \
    --argjson minage "$_RECONFIG_DR_MIN_UNREACHABLE_S" --arg survivor "$survivor" '
    ($facts.members) as $members
    | ($facts.status) as $status
    | ([$members[].votes] | add // 0) as $total_votes
    | (($total_votes / 2 | floor) + 1) as $majority
    | [ $status[] | select(.health != 1) ] as $down
    | ([ $status[] | select(.health == 1) | .name ]) as $up_names
    | ([ $members[] | select(.votes == 1 and (.host as $h | $up_names | index($h))) ] | length) as $healthy_votes
    | [ $down[] | .name as $n
        | ([$members[] | select(.host == $n)][0]) as $mem
        | {host: .name, state: .state, heartbeat_age_s: .heartbeat_age_s,
           votes: (if $mem == null then 0 else $mem.votes end),
           priority: (if $mem == null then 0 else $mem.priority end)} ] as $unreachable
    | [
        {id: "no_primary",
         pass: ($facts.has_primary | not),
         detail: (if $facts.has_primary then "a healthy PRIMARY exists — quorum is intact, force-dr is the wrong tool" else "no elected primary anywhere in the set" end)},
        {id: "quorum_lost",
         pass: ($healthy_votes < $majority),
         detail: "healthy voting members: \($healthy_votes)/\($total_votes) (majority needed: \($majority))"},
        {id: "unreachable_age",
         pass: ([$unreachable[] | select(.votes == 1)] | all(.heartbeat_age_s >= $minage)),
         detail: (if ([$unreachable[] | select(.votes == 1)] | length) == 0
                  then "no unreachable voting members — nothing to strip votes from"
                  else "unreachable voting members must be unheard-of for >= \($minage)s: \([$unreachable[] | select(.votes == 1) | {host, heartbeat_age_s}])"
                  end)}
      ] as $pre
    # stripping votes requires at least one unreachable voting member, fold
    # that into unreachable_age pass/fail: empty list means NOT ready
    | ($pre | map(if .id == "unreachable_age" and ([$unreachable[] | select(.votes == 1)] | length) == 0
                  then .pass = false else . end)) as $pre2
    | {ready: ($pre2 | all(.pass)),
       preconditions: $pre2,
       survivor: $survivor,
       survivors: $survivors,
       unreachable: $unreachable,
       majority: $majority, total_votes: $total_votes, healthy_votes: $healthy_votes,
       facts: {version: $facts.version, term: $facts.term, members: $facts.members}}
  '
}

# ---------------------------------------------------------------------------
# _reconfig_dr_suggested_members <members_json> <unreachable_json>
# The break-glass config: every unreachable member keeps its slot but loses
# votes and priority (never deleted — the site may come back).
# ---------------------------------------------------------------------------
_reconfig_dr_suggested_members() {
  local members="$1" unreachable="$2"
  jq -cn --argjson m "$members" --argjson u "$unreachable" '
    ([$u[].host]) as $lost
    | [ $m[] | if (.host as $h | $lost | index($h)) then .votes = 0 | .priority = 0 else . end ]
  '
}

# ---------------------------------------------------------------------------
# reconfig_force_dr <sts_name> <incident_id> <mode dry_run|confirm>
#                   <plan_hash> <requested_by> <user> <pass>
# ---------------------------------------------------------------------------
reconfig_force_dr() {
  local sts_name="$1" incident_id="$2" mode="$3" plan_hash="$4" requested_by="$5"
  local user="$6" pass="$7"
  local op="reconfig_force_dr"

  [[ -z "$incident_id" ]] && {
    response_err "$op" "incident_id is required for force-dr" '{"code":"INCIDENT_REQUIRED"}' 1
    return 1
  }

  local pre
  pre=$(_reconfig_dr_preconditions "$sts_name" "$user" "$pass") || {
    response_err "$op" "force-dr preconditions cannot be evaluated" "$pre" 1
    return 1
  }

  local members version term unreachable suggested
  members=$(printf '%s' "$pre" | jq -c '.facts.members')
  version=$(printf '%s' "$pre" | jq -r '.facts.version')
  term=$(printf '%s' "$pre" | jq -r '.facts.term')
  unreachable=$(printf '%s' "$pre" | jq -c '.unreachable')
  suggested=$(_reconfig_dr_suggested_members "$members" "$unreachable")

  # Hash binds incident + suggested member set + live version/term. The
  # dry_run → confirm pair is the same CAS pattern as plan → apply.
  local dr_canon live_hash
  dr_canon=$(jq -cn --arg inc "$incident_id" --argjson s "$suggested" \
    '{incident: $inc, members: $s}' | jq -cS .)
  live_hash=$(_reconfig_plan_hash "$K8S_NAMESPACE" "$sts_name" "$dr_canon" "$version" "$term")

  local ready
  ready=$(printf '%s' "$pre" | jq -r '.ready')

  if [[ "$mode" == "dry_run" ]]; then
    local msg="force-dr preconditions NOT met — confirm would be refused"
    [[ "$ready" == "true" ]] && msg="force-dr preconditions met — review suggested config, then re-call with confirm=true and this plan_hash"
    response_ok "$op" "$msg" \
      "$(printf '%s' "$pre" | jq -c --arg hash "$live_hash" --argjson sm "$suggested" \
        'del(.facts) + {suggested_members: $sm, plan_hash: $hash, mode: "dry_run"}')"
    return 0
  fi

  # ── confirm ───────────────────────────────────────────────────────────────
  if [[ "$ready" != "true" ]]; then
    response_err "$op" "force-dr refused: preconditions not met" \
      "$(printf '%s' "$pre" | jq -c '{code: "PRECONDITIONS_NOT_MET", preconditions, unreachable}')" 1
    return 1
  fi
  if [[ -z "$plan_hash" ]]; then
    response_err "$op" "plan_hash is required for confirm — run with dry_run first" \
      '{"code":"PLAN_HASH_REQUIRED"}' 1
    return 1
  fi
  if [[ "$live_hash" != "$plan_hash" ]]; then
    response_err "$op" "force-dr refused: state changed since dry_run — re-run dry_run and review again" \
      "$(jq -cn --arg got "$plan_hash" --arg want "$live_hash" \
        '{code: "PLAN_STALE", submitted_hash: $got, live_hash: $want}')" 1
    return 1
  fi

  local survivor
  survivor=$(printf '%s' "$pre" | jq -r '.survivor')
  log_info "$op" "Executing forced reconfig from survivor ${survivor} (incident ${incident_id})"

  local step_out
  step_out=$(_reconfig_exec_step "$survivor" "" "$user" "$pass" \
    "$version" "$suggested" "true")
  if ! printf '%s' "$step_out" | jq -e '.ok == 1' >/dev/null 2>&1; then
    reconfig_audit_append "$(jq -cn --arg sts "$sts_name" --arg inc "$incident_id" \
      --argjson result "$step_out" --arg by "$requested_by" \
      '{action: "force-dr", outcome: "failed", sts: $sts, incident_id: $inc,
        result: $result, requested_by: $by}')" || true
    response_err "$op" "rs.reconfig(force:true) failed on survivor ${survivor}" \
      "$(jq -cn --argjson r "$step_out" --arg s "$survivor" '{code: "RECONFIG_FAILED", survivor: $s, result: $r}')" 1
    return 1
  fi

  # Wait for the surviving side to elect a primary
  local elapsed=0 elected="" post_facts=""
  while (( elapsed < 90 )); do
    post_facts=$(_reconfig_get_facts "$sts_name" "$user" "$pass" "$survivor" 2>/dev/null) && \
      elected=$(printf '%s' "$post_facts" | jq -r '[.status[] | select(.state == "PRIMARY" and .health == 1)][0].name // ""') && \
      [[ -n "$elected" ]] && break
    sleep 5; elapsed=$((elapsed + 5))
  done

  _reconfig_set_annotations "$sts_name" \
    "$(jq -cn --arg k1 "$_RECONFIG_ANN_DR_ACTIVE" --arg k2 "$_RECONFIG_ANN_DR_INCIDENT" \
      --arg inc "$incident_id" '{($k1): "true", ($k2): $inc}')" || true

  local audited=true
  reconfig_audit_append "$(jq -cn --arg sts "$sts_name" --arg inc "$incident_id" \
    --argjson pre_members "$members" --argjson post_members "$suggested" \
    --argjson unreachable "$unreachable" --arg by "$requested_by" \
    --arg survivor "$survivor" --arg elected "$elected" --arg hash "$plan_hash" \
    '{action: "force-dr", outcome: "success", sts: $sts, incident_id: $inc,
      plan_hash: $hash, survivor: $survivor, elected_primary: $elected,
      pre_members: $pre_members, post_members: $post_members,
      unreachable: $unreachable, requested_by: $by}')" || audited=false

  local result
  result=$(jq -cn --arg sts "$sts_name" --arg inc "$incident_id" --arg survivor "$survivor" \
    --arg elected "$elected" --argjson suggested "$suggested" \
    --argjson unreachable "$unreachable" --argjson audited "$audited" \
    '{sts: $sts, incident_id: $inc, survivor: $survivor,
      elected_primary: (if $elected == "" then null else $elected end),
      post_members: $suggested, unreachable: $unreachable,
      dr_active: true, audited: $audited,
      recovery_note: "when the lost site returns: rejoin members with set_hidden true (keeps votes 0), wait for lag to reach 0, then restore votes/priority one member at a time via the normal plan/apply flow"}')
  if [[ -z "$elected" ]]; then
    response_err "$op" "Forced reconfig applied but no primary elected within 90s — check surviving members" "$result" 1
    return 1
  fi
  response_ok "$op" "force-dr complete: ${elected} elected primary; dr-active set on ${sts_name}" "$result"
}
