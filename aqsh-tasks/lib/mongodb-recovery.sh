#!/usr/bin/env bash
# =============================================================================
# lib/mongodb-recovery.sh
# Recovery gate checks and operations for Bitnami MongoDB Helm chart.
#
# Provides:
#   recovery_run_gates   — run G1–G8 pre-flight checks
#   recovery_wipe_pod    — set wipe target in ConfigMap + trigger STS partition
#   recovery_reset       — clear wipe-target and restore partition
#   recovery_get_status  — show current recovery state
#   recovery_fix_diagnose / _unfreeze / _reconfig / _force_primary — E1+E5 fix
#   recovery_set_sync_source — direct pod to sync from secondary (or primary)
#   recovery_recover     — orchestrator: gates → wipe → wait → reset → set-sync
#
# Cross-cluster RS support (e.g. cluster A = PSS, cluster B = SSS):
#   G3 reads the FULL rs.status().members list from any local pod, so a PRIMARY
#   in another cluster is visible and has_primary is correctly set.
#   G4/G8 use _recovery_primary_host (reads members.name from any local probe pod)
#   + _recovery_mongosh_host (directConnection to that host:port) so oplog stats
#   and replSetResizeOplog reach the cross-cluster primary without requiring a
#   local primary pod.
#
# Depends on: logging.sh, response.sh, k8s.sh, mongodb.sh (sourced by callers)
# =============================================================================

[[ -n "${_MONGODB_RECOVERY_LIB_LOADED:-}" ]] && return 0
_MONGODB_RECOVERY_LIB_LOADED=1

# Data paths vary by MongoDB deployment type; override via API params or env:
#   Bitnami helm chart (default): /bitnami/mongodb/data/db  /bitnami/mongodb
#   Standard mongo:N image:       /data/db                  /data
_RECOVERY_DATA_PATH="${RECOVERY_DATA_PATH:-/bitnami/mongodb/data/db}"
_RECOVERY_MOUNT_PATH="${RECOVERY_MOUNT_PATH:-/bitnami/mongodb}"
readonly _RECOVERY_INIT_CONTAINER_NAME="data-recovery"
readonly _RECOVERY_DATA_SIZE_LIMIT_MB=102400   # 100 GB

# ---------------------------------------------------------------------------
# _mongo_load_credentials <namespace> <secret> <user_key> <pass_key>
# Read MongoDB credentials from a Kubernetes Secret and export them as
# _MONGO_USER / _MONGO_PASS in the calling script's scope.
# Writes a JSON error to $AQSH_RESULT_FILE and calls exit 1 on any failure.
# ---------------------------------------------------------------------------
_mongo_load_credentials() {
  local namespace="$1" secret="$2" user_key="$3" pass_key="$4"
  _MONGO_USER=$(kubectl -n "$namespace" get secret "$secret" \
    -o jsonpath="{.data.${user_key}}" 2>/dev/null | base64 -d) || {
    jq -n --arg ns "$namespace" --arg s "$secret" \
      '{"status":"error","message":"Cannot read credentials from secret","namespace":$ns,"secret":$s}' \
      > "$AQSH_RESULT_FILE"; exit 1
  }
  _MONGO_PASS=$(kubectl -n "$namespace" get secret "$secret" \
    -o jsonpath="{.data.${pass_key}}" 2>/dev/null | base64 -d) || {
    jq -n --arg ns "$namespace" --arg s "$secret" \
      '{"status":"error","message":"Cannot read credentials from secret","namespace":$ns,"secret":$s}' \
      > "$AQSH_RESULT_FILE"; exit 1
  }
  # A present-but-empty secret key decodes to "" with exit 0, so the traps above
  # do not fire — validate explicitly to avoid opaque downstream auth failures.
  if [[ -z "${_MONGO_USER}" || -z "${_MONGO_PASS}" ]]; then
    jq -n --arg ns "$namespace" --arg s "$secret" --arg uk "$user_key" --arg pk "$pass_key" \
      '{"status":"error","message":"Credentials secret is missing required key(s) or values are empty","namespace":$ns,"secret":$s,"user_key":$uk,"pass_key":$pk}' \
      > "$AQSH_RESULT_FILE"; exit 1
  fi
}

# ---------------------------------------------------------------------------
# _recovery_mongosh_pod <pod_name> <user> <pass> <js>
# Execute a mongosh JS snippet inside a specific pod via kubectl exec.
# Outputs raw mongosh stdout; caller inspects last line.
# ---------------------------------------------------------------------------
_recovery_mongosh_pod() {
  local pod="$1" user="$2" pass="$3" js="$4"
  local enc_user enc_pass
  enc_user=$(_mongo_uri_percent_encode "$user")
  enc_pass=$(_mongo_uri_percent_encode "$pass")
  _kubectl exec "$pod" -- mongosh --quiet --norc \
    "mongodb://${enc_user}:${enc_pass}@localhost:27017/admin?authSource=admin&serverSelectionTimeoutMS=5000" \
    --eval "$js" 2>&1
}

# ---------------------------------------------------------------------------
# _recovery_pod_ordinal <pod_name>
# Extract numeric ordinal from a pod name (e.g. mongodb-2 → 2).
# ---------------------------------------------------------------------------
_recovery_pod_ordinal() {
  printf '%s\n' "${1##*-}"
}

# ---------------------------------------------------------------------------
# _recovery_list_pods <sts_name>
# Return newline-separated pod names for a StatefulSet via label selector.
# ---------------------------------------------------------------------------
_recovery_list_pods() {
  local sts_name="$1"
  local label_sel
  label_sel=$(_kubectl get statefulset "$sts_name" \
    -o go-template='{{range $k,$v := .spec.selector.matchLabels}}{{$k}}={{$v}},{{end}}' 2>/dev/null \
    | sed 's/,$//') || true
  [[ -z "$label_sel" ]] && return 1
  _kubectl get pods -l "$label_sel" \
    -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# _recovery_primary_host <sts_name> <user> <pass>
# Echo the host:port of the RS PRIMARY by reading the full rs.status().members
# list from any reachable local pod. Cross-cluster aware: the PRIMARY may live
# in a different cluster; its RS-registered member name (host:port) is returned.
# Returns 1 if no PRIMARY is currently elected anywhere in the replica set.
# ---------------------------------------------------------------------------
_recovery_primary_host() {
  local sts_name="$1" user="$2" pass="$3"
  local pods_raw probe=""
  pods_raw=$(_recovery_list_pods "$sts_name") || return 1
  while IFS= read -r pod; do
    [[ -z "$pod" ]] && continue
    local phase
    phase=$(_kubectl get pod "$pod" -o jsonpath='{.status.phase}' 2>/dev/null) || continue
    [[ "$phase" == "Running" ]] && { probe="$pod"; break; }
  done <<< "$pods_raw"
  [[ -z "$probe" ]] && return 1
  local host
  host=$(_recovery_mongosh_pod "$probe" "$user" "$pass" \
    "try{var p=rs.status().members.filter(function(m){return m.stateStr==='PRIMARY'&&m.health===1;})[0];print(p?p.name:'');}catch(e){print('');}" \
    2>/dev/null | tail -1 | tr -d '\r')
  [[ -z "$host" ]] && return 1
  printf '%s\n' "$host"
}

# ---------------------------------------------------------------------------
# _recovery_mongosh_host <from_pod> <host:port> <user> <pass> <js>
# Run mongosh from inside <from_pod> connecting directly to <host:port>
# (directConnection=true). Enables cross-cluster oplog queries and admin
# commands when the PRIMARY lives in a different cluster.
# ---------------------------------------------------------------------------
_recovery_mongosh_host() {
  local from_pod="$1" host="$2" user="$3" pass="$4" js="$5"
  local enc_user enc_pass
  enc_user=$(_mongo_uri_percent_encode "$user")
  enc_pass=$(_mongo_uri_percent_encode "$pass")
  _kubectl exec "$from_pod" -- mongosh --quiet --norc \
    "mongodb://${enc_user}:${enc_pass}@${host}/admin?authSource=admin&directConnection=true&serverSelectionTimeoutMS=5000" \
    --eval "$js" 2>&1
}

# ===========================================================================
# Gate functions
# Each gate prints a single-line JSON object to stdout:
#   {"gate":"Gn","pass":true|false,"warn":true|false,"message":"...","code":"...",...}
# Returns 0 on pass/warn, 1 on blocking fail.
# ===========================================================================

_recovery_gate_g1() {
  local sts_name="$1"
  # jsonpath, not `-o json | grep`: real kubectl pretty-prints JSON with a
  # space after the colon, so a compact-JSON grep never matches.
  local ic_names
  ic_names=$(_kubectl get statefulset "$sts_name" \
    -o jsonpath='{.spec.template.spec.initContainers[*].name}' 2>/dev/null) || {
    printf '{"gate":"G1","pass":false,"code":"STS_NOT_FOUND","message":"StatefulSet %s not found","suggestion":"Verify namespace and sts_name inputs"}' \
      "$sts_name"; return 1
  }
  if printf '%s' "$ic_names" | tr ' ' '\n' | grep -qx "$_RECOVERY_INIT_CONTAINER_NAME"; then
    printf '{"gate":"G1","pass":true,"message":"Init container %s present in StatefulSet %s"}' \
      "$_RECOVERY_INIT_CONTAINER_NAME" "$sts_name"
    return 0
  fi
  printf '{"gate":"G1","pass":false,"code":"INIT_CONTAINER_MISSING","message":"Init container %s not found in StatefulSet %s","suggestion":"Apply the STS patch first: kubectl apply -f 02-sts-patch.yaml"}' \
    "$_RECOVERY_INIT_CONTAINER_NAME" "$sts_name"
  return 1
}

_recovery_gate_g2() {
  local cm_name="$1"
  if _kubectl get configmap "$cm_name" &>/dev/null; then
    printf '{"gate":"G2","pass":true,"message":"Recovery ConfigMap %s exists"}' "$cm_name"
    return 0
  fi
  printf '{"gate":"G2","pass":false,"code":"CONFIGMAP_MISSING","message":"Recovery ConfigMap %s not found","suggestion":"Apply the ConfigMap first: kubectl apply -f 01-recovery-configmap.yaml"}' \
    "$cm_name"
  return 1
}

_recovery_gate_g3() {
  local sts_name="$1" target_pod="$2" user="$3" pass="$4"
  local pods_raw
  pods_raw=$(_recovery_list_pods "$sts_name") || {
    printf '{"gate":"G3","pass":false,"code":"STS_PODS_UNRESOLVABLE","message":"Cannot list pods for StatefulSet %s","suggestion":"Check namespace and STS name"}' \
      "$sts_name"; return 1
  }
  local has_primary=false healthy_src=""
  while IFS= read -r pod; do
    [[ -z "$pod" || "$pod" == "$target_pod" ]] && continue
    local phase
    phase=$(_kubectl get pod "$pod" -o jsonpath='{.status.phase}' 2>/dev/null) || continue
    [[ "$phase" != "Running" ]] && continue
    local rs_out rs_rest any_primary self_state health
    rs_out=$(_recovery_mongosh_pod "$pod" "$user" "$pass" \
      "try{var s=rs.status();var p=s.members.some(function(x){return x.stateStr==='PRIMARY'&&x.health===1;});var m=s.members.filter(function(x){return x.self;})[0];print((p?'1':'0')+','+m.stateStr+','+m.health);}catch(e){print('0,ERR,0');}" \
      2>/dev/null | tail -1) || continue
    any_primary="${rs_out%%,*}"; rs_rest="${rs_out#*,}"; self_state="${rs_rest%%,*}"; health="${rs_rest##*,}"
    [[ "$any_primary" == "1" ]] && has_primary=true
    [[ "$self_state" == "SECONDARY" && "$health" == "1" ]] && { [[ -z "$healthy_src" ]] && healthy_src="$pod"; }
    [[ "$self_state" == "PRIMARY"   && "$health" == "1" ]] && { [[ -z "$healthy_src" ]] && healthy_src="$pod"; }
  done <<< "$pods_raw"

  if [[ "$has_primary" == "true" && -n "$healthy_src" ]]; then
    printf '{"gate":"G3","pass":true,"message":"Primary elected and healthy sync source available: %s","source_pod":"%s"}' \
      "$healthy_src" "$healthy_src"
    return 0
  elif [[ -n "$healthy_src" && "$has_primary" == "false" ]]; then
    printf '{"gate":"G3","pass":false,"code":"NO_PRIMARY","message":"Healthy secondary %s found but NO PRIMARY elected — unsafe to wipe","suggestion":"Run recovery/fix-no-primary level=diagnose to restore primary first"}' \
      "$healthy_src"
    return 1
  fi
  printf '{"gate":"G3","pass":false,"code":"NO_HEALTHY_SOURCE","message":"No healthy sync source found (excluding target pod %s)","suggestion":"Check pod status and MongoDB logs"}' \
    "$target_pod"
  return 1
}

# G5 must run before G4/G6 to provide data_mb.
# Outputs data_mb in the JSON field for callers to extract.
_recovery_gate_g5() {
  local sts_name="$1" target_pod="$2"
  local force_wipe="${FORCE_WIPE:-false}"

  # Prefer a healthy non-target pod for du (target may be crashed)
  local probe_pod="$target_pod"
  local pods_raw
  pods_raw=$(_recovery_list_pods "$sts_name") || pods_raw=""
  while IFS= read -r pod; do
    [[ -z "$pod" || "$pod" == "$target_pod" ]] && continue
    local phase
    phase=$(_kubectl get pod "$pod" -o jsonpath='{.status.phase}' 2>/dev/null) || continue
    [[ "$phase" == "Running" ]] && { probe_pod="$pod"; break; }
  done <<< "$pods_raw"

  local size_mb=0
  local du_out
  du_out=$(_kubectl exec "$probe_pod" -- du -sm "${_RECOVERY_DATA_PATH}" 2>/dev/null | awk '{print $1}') || du_out=""
  [[ -n "$du_out" && "$du_out" =~ ^[0-9]+$ ]] && size_mb="$du_out"

  if [[ "$size_mb" -eq 0 ]]; then
    printf '{"gate":"G5","pass":true,"warn":true,"message":"Cannot determine data size in pod %s — size gate skipped","data_mb":0}' \
      "$probe_pod"
    return 0
  fi

  local size_gb=$(( size_mb / 1024 ))
  if [[ "$size_mb" -gt "${_RECOVERY_DATA_SIZE_LIMIT_MB}" ]]; then
    if [[ "$force_wipe" == "true" ]]; then
      printf '{"gate":"G5","pass":true,"warn":true,"message":"Data %sMB (%sGB) exceeds 100GB — FORCE_WIPE=true override active (proceed with caution)","data_mb":%s}' \
        "$size_mb" "$size_gb" "$size_mb"
      return 0
    fi
    printf '{"gate":"G5","pass":false,"code":"DATA_TOO_LARGE","message":"Data size %sMB (%sGB) exceeds 100GB PROD safety limit","suggestion":"Use VolumeSnapshot or mongodump, or set FORCE_WIPE=true to override (high risk)","data_mb":%s}' \
      "$size_mb" "$size_gb" "$size_mb"
    return 1
  fi

  printf '{"gate":"G5","pass":true,"message":"Data size %sMB (%sGB) is within the 100GB limit","data_mb":%s}' \
    "$size_mb" "$size_gb" "$size_mb"
  return 0
}

# allow_resize=false (report mode): never mutate the cluster — report
# OPLOG_RESIZE_NEEDED as a warning instead of running replSetResizeOplog.
_recovery_gate_g4() {
  local sts_name="$1" user="$2" pass="$3" data_mb="$4" allow_resize="${5:-true}"
  local primary_host probe_pod
  if ! primary_host=$(_recovery_primary_host "$sts_name" "$user" "$pass"); then
    printf '{"gate":"G4","pass":false,"code":"NO_PRIMARY_FOR_OPLOG","message":"Cannot find primary to query oplog — ensure primary is elected first","suggestion":"Run recovery/fix-no-primary level=diagnose"}'
    return 1
  fi
  local g4_pods_raw g4_pod g4_phase
  g4_pods_raw=$(_recovery_list_pods "$sts_name") || g4_pods_raw=""
  probe_pod=""
  while IFS= read -r g4_pod; do
    [[ -z "$g4_pod" ]] && continue
    g4_phase=$(_kubectl get pod "$g4_pod" -o jsonpath='{.status.phase}' 2>/dev/null) || continue
    [[ "$g4_phase" == "Running" ]] && { probe_pod="$g4_pod"; break; }
  done <<< "$g4_pods_raw"
  if [[ -z "$probe_pod" ]]; then
    printf '{"gate":"G4","pass":false,"code":"NO_LOCAL_POD","message":"No local Running pod found to query oplog via primary %s","suggestion":"Check pod status in this cluster"}' \
      "$primary_host"
    return 1
  fi

  # All arithmetic stays inside mongosh to avoid bash float issues
  local oplog_csv
  oplog_csv=$(_recovery_mongosh_host "$probe_pod" "$primary_host" "$user" "$pass" "
var l=db.getSiblingDB('local');
var st=l.runCommand({collStats:'oplog.rs'});
var curMB=Math.ceil(st.maxSize/1024/1024);
var first=l['oplog.rs'].find({},{ts:1}).sort({ts:1}).limit(1).toArray();
var last=l['oplog.rs'].find({},{ts:1}).sort({ts:-1}).limit(1).toArray();
var winHrs=(first.length&&last.length&&last[0].ts.t>first[0].ts.t)?(last[0].ts.t-first[0].ts.t)/3600:0;
var wRate=winHrs>0.1?Math.ceil(curMB/winHrs):500;
var dataMB=${data_mb};
var syncH=Math.max(1,Math.ceil(dataMB/(5*1024)));
var reqWin=Math.max(4,syncH*2);
var reqMB=Math.max(2048,Math.ceil(dataMB*0.05),Math.ceil(wRate*reqWin));
print([curMB,Math.ceil(winHrs),wRate,syncH,reqWin,reqMB,curMB>=reqMB?'ok':'resize'].join(','));
" 2>/dev/null | tail -1 | tr -d '\r') || {
    printf '{"gate":"G4","pass":false,"code":"OPLOG_QUERY_FAILED","message":"Failed to query oplog stats from primary %s","suggestion":"Check MongoDB credentials and connectivity"}' \
      "$primary_host"
    return 1
  }

  IFS=',' read -r cur_mb win_hrs w_rate sync_h req_win req_mb verdict <<< "$oplog_csv"
  [[ -z "$verdict" ]] && {
    printf '{"gate":"G4","pass":false,"code":"OPLOG_PARSE_FAILED","message":"Unexpected oplog query output from %s: %s","suggestion":"Check MongoDB version (3.6+ required for replSetResizeOplog)"}' \
      "$primary_host" "$oplog_csv"
    return 1
  }

  if [[ "$verdict" == "ok" ]]; then
    printf '{"gate":"G4","pass":true,"message":"Oplog window sufficient: %sMB (window %sh) >= required %sMB (est. sync %sh for %sMB data)","current_mb":%s,"required_mb":%s,"window_hours":%s}' \
      "$cur_mb" "$win_hrs" "$req_mb" "$sync_h" "$data_mb" "$cur_mb" "$req_mb" "$win_hrs"
    return 0
  fi

  if [[ "$allow_resize" != "true" ]]; then
    printf '{"gate":"G4","pass":true,"warn":true,"code":"OPLOG_RESIZE_NEEDED","message":"Oplog %sMB < required %sMB (data %sMB, est. sync %sh) — auto-resize will run during wipe/recover; pre-check is read-only","current_mb":%s,"required_mb":%s,"window_hours":%s}' \
      "$cur_mb" "$req_mb" "$data_mb" "$sync_h" "$cur_mb" "$req_mb" "$win_hrs"
    return 0
  fi

  # Attempt auto-resize on primary
  log_info "recovery-g4" "Oplog ${cur_mb}MB < required ${req_mb}MB — attempting auto-resize"
  local resize_out
  resize_out=$(_recovery_mongosh_host "$probe_pod" "$primary_host" "$user" "$pass" \
    "JSON.stringify(db.adminCommand({replSetResizeOplog:1,size:${req_mb}}))" \
    2>/dev/null | tail -1) || resize_out='{}'
  if printf '%s' "$resize_out" | grep -q '"ok":1'; then
    printf '{"gate":"G4","pass":true,"warn":true,"message":"Oplog auto-resized: %sMB → %sMB on primary %s (window was %sh, required %sh for %sMB data)","old_mb":%s,"new_mb":%s}' \
      "$cur_mb" "$req_mb" "$primary_host" "$win_hrs" "$req_win" "$data_mb" "$cur_mb" "$req_mb"
    return 0
  fi

  printf '{"gate":"G4","pass":false,"code":"OPLOG_TOO_SMALL","message":"Oplog %sMB < required %sMB (data %sMB, est. sync %sh, write rate %sMB/h). Auto-resize failed.","suggestion":"Run on primary: db.adminCommand({replSetResizeOplog:1,size:%s}) — requires MongoDB 3.6+","current_mb":%s,"required_mb":%s,"window_hours":%s}' \
    "$cur_mb" "$req_mb" "$data_mb" "$sync_h" "$w_rate" "$req_mb" "$cur_mb" "$req_mb" "$win_hrs"
  return 1
}

_recovery_gate_g6() {
  local sts_name="$1" target_pod="$2" data_mb="$3"
  local required_mb=$(( data_mb * 120 / 100 ))

  # Try df inside target pod (works if init container is running or pod is up)
  local avail_mb=0
  local df_out
  df_out=$(_kubectl exec "$target_pod" -- df -m "${_RECOVERY_MOUNT_PATH}" 2>/dev/null \
    | awk 'NR==2{print $4}') || df_out=""
  [[ -n "$df_out" && "$df_out" =~ ^[0-9]+$ ]] && avail_mb="$df_out"

  # Fallback: read PVC capacity from K8s API (Bitnami volumeClaimTemplate name varies)
  if [[ "$avail_mb" -eq 0 ]]; then
    local ordinal
    ordinal=$(_recovery_pod_ordinal "$target_pod")
    local pvc_name=""
    for candidate in \
        "${sts_name}-data-${sts_name}-${ordinal}" \
        "data-${sts_name}-${ordinal}" \
        "datadir-${sts_name}-${ordinal}"; do
      if _kubectl get pvc "$candidate" &>/dev/null; then
        pvc_name="$candidate"; break
      fi
    done
    if [[ -n "$pvc_name" ]]; then
      local cap_str
      cap_str=$(_kubectl get pvc "$pvc_name" -o jsonpath='{.status.capacity.storage}' 2>/dev/null) || cap_str=""
      # 85% of total as conservative free space. Cover Ti/Gi/Mi so a large PVC
      # is not misread as 0 (which would silently skip the space gate below).
      if [[ "$cap_str" == *Ti ]]; then
        avail_mb=$(( ${cap_str%Ti} * 1024 * 1024 * 85 / 100 ))
      elif [[ "$cap_str" == *Gi ]]; then
        avail_mb=$(( ${cap_str%Gi} * 1024 * 85 / 100 ))
      elif [[ "$cap_str" == *Mi ]]; then
        avail_mb=$(( ${cap_str%Mi} * 85 / 100 ))
      fi
    fi
  fi

  if [[ "$avail_mb" -eq 0 ]]; then
    printf '{"gate":"G6","pass":true,"warn":true,"message":"Cannot determine PVC available space for pod %s — space gate skipped (ensure >= %sMB free)","required_mb":%s}' \
      "$target_pod" "$required_mb" "$required_mb"
    return 0
  fi

  if [[ "$avail_mb" -lt "$required_mb" ]]; then
    printf '{"gate":"G6","pass":false,"code":"INSUFFICIENT_PVC_SPACE","message":"PVC available space %sMB < required %sMB (data_size x 1.2) for pod %s","suggestion":"Expand the PVC or clean up data before proceeding","available_mb":%s,"required_mb":%s}' \
      "$avail_mb" "$required_mb" "$target_pod" "$avail_mb" "$required_mb"
    return 1
  fi

  printf '{"gate":"G6","pass":true,"message":"PVC available space %sMB >= required %sMB for pod %s","available_mb":%s,"required_mb":%s}' \
    "$avail_mb" "$required_mb" "$target_pod" "$avail_mb" "$required_mb"
  return 0
}

_recovery_gate_g7() {
  local sts_name="$1" target_pod="$2" user="$3" pass="$4"
  local phase
  phase=$(_kubectl get pod "$target_pod" -o jsonpath='{.status.phase}' 2>/dev/null) || phase="Unknown"
  if [[ "$phase" != "Running" ]]; then
    printf '{"gate":"G7","pass":true,"message":"Target %s is not Running (%s) — cannot hold primary lease, safe to wipe"}' \
      "$target_pod" "$phase"
    return 0
  fi
  local is_primary
  is_primary=$(_recovery_mongosh_pod "$target_pod" "$user" "$pass" \
    "try{var h=db.hello();print((h.isWritablePrimary||h.ismaster)?'1':'0');}catch(e){print('0');}" \
    2>/dev/null | tail -1) || is_primary="0"
  if [[ "$is_primary" == "1" ]]; then
    printf '{"gate":"G7","pass":false,"code":"TARGET_IS_PRIMARY","message":"Target %s is currently PRIMARY — wiping will cause an election and brief write unavailability","suggestion":"Run rs.stepDown(60) inside the pod or wait for automatic step-down, then re-run wipe"}' \
      "$target_pod"
    return 1
  fi
  printf '{"gate":"G7","pass":true,"message":"Target %s is not PRIMARY — safe to wipe"}' "$target_pod"
  return 0
}

_recovery_gate_g8() {
  local sts_name="$1" user="$2" pass="$3"
  local primary_host g8_pods_raw g8_pod g8_phase probe_pod
  primary_host=$(_recovery_primary_host "$sts_name" "$user" "$pass") || {
    printf '{"gate":"G8","pass":true,"warn":true,"message":"G8 skipped: no primary found in RS to query RECOVERING state"}'
    return 0
  }
  g8_pods_raw=$(_recovery_list_pods "$sts_name") || g8_pods_raw=""
  probe_pod=""
  while IFS= read -r g8_pod; do
    [[ -z "$g8_pod" ]] && continue
    g8_phase=$(_kubectl get pod "$g8_pod" -o jsonpath='{.status.phase}' 2>/dev/null) || continue
    [[ "$g8_phase" == "Running" ]] && { probe_pod="$g8_pod"; break; }
  done <<< "$g8_pods_raw"
  if [[ -z "$probe_pod" ]]; then
    printf '{"gate":"G8","pass":true,"warn":true,"message":"G8 skipped: no local Running pod to query RECOVERING state"}'
    return 0
  fi
  local recovering
  recovering=$(_recovery_mongosh_host "$probe_pod" "$primary_host" "$user" "$pass" \
    "try{var s=rs.status();print(s.members.filter(function(m){return m.stateStr==='RECOVERING';}).map(function(m){return m.name;}).join(','));}catch(e){print('');}" \
    2>/dev/null | tail -1) || {
    printf '{"gate":"G8","pass":true,"warn":true,"message":"G8 skipped: could not connect to primary %s to query RECOVERING state"}' "$primary_host"
    return 0
  }
  if [[ -n "$recovering" && "$recovering" != "undefined" ]]; then
    printf '{"gate":"G8","pass":true,"warn":true,"message":"Other member(s) currently RECOVERING: %s — concurrent sync may slow recovery. Consider waiting."}' \
      "$recovering"
    return 0
  fi
  printf '{"gate":"G8","pass":true,"message":"No members in RECOVERING state"}'
  return 0
}

# ---------------------------------------------------------------------------
# recovery_run_gates <sts_name> <target_pod> <cm_name> <user> <pass> [mode]
#
# Runs all G1–G8 pre-flight gates.
#   mode=report (default): run all gates, aggregate results, never exit early
#   mode=gate: exit with response_err on first blocking failure
#
# Returns response_ok (all pass) or response_err (any blocking fail) to stdout.
# ---------------------------------------------------------------------------
recovery_run_gates() {
  local sts_name="${1:?sts_name required}" target_pod="${2:?target_pod required}"
  local cm_name="${3:?cm_name required}" user="${4:?user required}" pass="${5:?pass required}"
  local mode="${6:-report}"
  local op="recovery_run_gates"

  local -a gate_results=()
  local fail_count=0 warn_count=0 data_mb=0

  # Helper: run a gate, collect result, optionally exit in gate mode
  _run_gate() {
    local gfn="$1" is_blocking="${2:-true}"
    local gout gpass
    gout=$("$gfn" "${@:3}") || true
    gpass=$(printf '%s' "$gout" | grep -o '"pass":[a-z]*' | head -1 | cut -d':' -f2)
    local gwarn
    gwarn=$(printf '%s' "$gout" | grep -o '"warn":[a-z]*' | head -1 | cut -d':' -f2)
    gate_results+=("$gout")
    [[ "$gwarn" == "true" ]] && (( warn_count++ )) || true
    if [[ "$gpass" != "true" && "$is_blocking" == "true" ]]; then
      (( fail_count++ )) || true
      if [[ "$mode" == "gate" ]]; then
        local gate_id
        gate_id=$(printf '%s' "$gout" | grep -o '"gate":"[^"]*"' | head -1 | cut -d'"' -f4)
        local msg
        msg=$(printf '%s' "$gout" | grep -o '"message":"[^"]*"' | head -1 | cut -d'"' -f4)
        response_err "$op" "Gate ${gate_id} failed: ${msg}" "$gout" 1
        return 1
      fi
    fi
    return 0
  }

  # G1: init container present
  _run_gate _recovery_gate_g1 true "$sts_name" || return 1

  # G2: recovery ConfigMap exists
  _run_gate _recovery_gate_g2 true "$cm_name" || return 1

  # G5 first: data size (provides data_mb for G4 + G6)
  local g5_out g5_pass
  g5_out=$(_recovery_gate_g5 "$sts_name" "$target_pod") || true
  g5_pass=$(printf '%s' "$g5_out" | grep -o '"pass":[a-z]*' | head -1 | cut -d':' -f2)
  local g5_warn
  g5_warn=$(printf '%s' "$g5_out" | grep -o '"warn":[a-z]*' | head -1 | cut -d':' -f2)
  data_mb=$(printf '%s' "$g5_out" | grep -o '"data_mb":[0-9]*' | head -1 | cut -d':' -f2)
  data_mb="${data_mb:-0}"

  # G3: healthy sync source + primary
  _run_gate _recovery_gate_g3 true "$sts_name" "$target_pod" "$user" "$pass" || return 1

  # G4: oplog window (uses data_mb; skip if unknown).
  # Auto-resize only in gate mode — report mode (pre-check) must stay read-only.
  local g4_resize="false"
  [[ "$mode" == "gate" ]] && g4_resize="true"
  if [[ "$data_mb" -gt 0 ]]; then
    _run_gate _recovery_gate_g4 true "$sts_name" "$user" "$pass" "$data_mb" "$g4_resize" || return 1
  else
    gate_results+=('{"gate":"G4","pass":true,"warn":true,"message":"Oplog check skipped: data size unknown"}')
    (( warn_count++ )) || true
  fi

  # G5 result (add after G4 to keep Gn order in output)
  [[ "${g5_warn:-}" == "true" ]] && (( warn_count++ )) || true
  gate_results+=("$g5_out")
  if [[ "$g5_pass" != "true" ]]; then
    (( fail_count++ )) || true
    if [[ "$mode" == "gate" ]]; then
      response_err "$op" "Gate G5 failed: data size exceeds limit" "$g5_out" 5
      return 1
    fi
  fi

  # G6: PVC space (uses data_mb)
  if [[ "$data_mb" -gt 0 ]]; then
    _run_gate _recovery_gate_g6 true "$sts_name" "$target_pod" "$data_mb" || return 1
  else
    gate_results+=('{"gate":"G6","pass":true,"warn":true,"message":"PVC space check skipped: data size unknown"}')
    (( warn_count++ )) || true
  fi

  # G7: pod-0 primary safety
  _run_gate _recovery_gate_g7 true "$sts_name" "$target_pod" "$user" "$pass" || return 1

  # G8: warn if other pods RECOVERING (non-blocking)
  local g8_out
  g8_out=$(_recovery_gate_g8 "$sts_name" "$user" "$pass") || true
  local g8_warn
  g8_warn=$(printf '%s' "$g8_out" | grep -o '"warn":[a-z]*' | head -1 | cut -d':' -f2)
  [[ "$g8_warn" == "true" ]] && (( warn_count++ )) || true
  gate_results+=("$g8_out")

  # Build gates JSON array
  local gates_json=""
  for g in "${gate_results[@]}"; do
    gates_json+="${g},"
  done
  gates_json="[${gates_json%,}]"

  local pass_count=$(( ${#gate_results[@]} - fail_count ))
  if [[ "$fail_count" -gt 0 ]]; then
    response_err "$op" "Pre-flight checks failed: ${fail_count} gate(s) blocked wipe" \
      "{\"gates\":${gates_json},\"pass\":${pass_count},\"fail\":${fail_count},\"warn\":${warn_count},\"target_pod\":\"${target_pod}\"}" 1
    return 1
  fi
  response_ok "$op" "All pre-flight gates passed (${warn_count} warning(s))" \
    "{\"gates\":${gates_json},\"pass\":${pass_count},\"fail\":0,\"warn\":${warn_count},\"target_pod\":\"${target_pod}\"}"
  return 0
}

# ---------------------------------------------------------------------------
# recovery_wipe_pod <sts_name> <target_pod> <cm_name>
# Set wipe-target in ConfigMap and trigger rolling update for the target pod.
# Must be called AFTER recovery_run_gates in gate mode.
# ---------------------------------------------------------------------------
recovery_wipe_pod() {
  local sts_name="${1:?}" target_pod="${2:?}" cm_name="${3:?}"
  local op="recovery_wipe_pod"
  local ordinal
  ordinal=$(_recovery_pod_ordinal "$target_pod")

  log_info "$op" "Setting wipe target: ${target_pod} (ordinal=${ordinal})"

  # 1. Set wipe-targets in ConfigMap (init container reads this on pod start)
  local cm_out
  if ! cm_out=$(_kubectl patch configmap "$cm_name" --type=merge \
    -p "{\"data\":{\"wipe-targets\":\"${target_pod}\"}}" 2>&1); then
    response_err "$op" "Failed to set wipe-target in ConfigMap ${cm_name}" \
      "{\"detail\":\"$(_escape_json_string "$cm_out")\",\"target_pod\":\"${target_pod}\"}" 1
    return 1
  fi

  # 2. Set partition=ordinal and bump annotation to trigger rolling update
  local ts
  ts=$(date -u +%s)
  local sts_out
  if ! sts_out=$(_kubectl patch statefulset "$sts_name" --type=merge -p \
    "{\"spec\":{\"updateStrategy\":{\"rollingUpdate\":{\"partition\":${ordinal}}},\"template\":{\"metadata\":{\"annotations\":{\"recovery/version\":\"${ts}\"}}}}}" 2>&1); then
    # Rollback CM to prevent stale wipe-target
    _kubectl patch configmap "$cm_name" --type=merge \
      -p '{"data":{"wipe-targets":""}}' &>/dev/null || true
    response_err "$op" "Failed to set partition=${ordinal} on StatefulSet ${sts_name} (CM rolled back)" \
      "{\"detail\":\"$(_escape_json_string "$sts_out")\",\"target_pod\":\"${target_pod}\"}" 1
    return 1
  fi

  log_info "$op" "Wipe initiated — run recovery/reset once pod ${target_pod} enters Running to prevent re-wipe on restart"
  response_ok "$op" "Wipe initiated for pod ${target_pod}" \
    "{\"target_pod\":\"${target_pod}\",\"ordinal\":${ordinal},\"partition_set\":${ordinal},\"configmap\":\"${cm_name}\",\"next_step\":\"Monitor pod restart; run recovery/reset once pod is Running and before sync completes\"}"
  return 0
}

# ---------------------------------------------------------------------------
# recovery_reset <sts_name> <cm_name> <replicas>
# Clear wipe-targets and restore partition to replica count (locked state).
# ---------------------------------------------------------------------------
recovery_reset() {
  local sts_name="${1:?}" cm_name="${2:?}" replicas="${3:?}"
  local op="recovery_reset"
  log_info "$op" "Clearing recovery state: CM=${cm_name}, partition=${replicas}"

  # 1. Clear wipe-targets FIRST (prevents re-wipe if pod later restarts)
  local cm_out
  if ! cm_out=$(_kubectl patch configmap "$cm_name" --type=merge \
    -p '{"data":{"wipe-targets":""}}' 2>&1); then
    response_err "$op" "Failed to clear wipe-targets in ConfigMap ${cm_name}" \
      "{\"detail\":\"$(_escape_json_string "$cm_out")\"}" 1
    return 1
  fi

  # 2. Reset partition to replica count
  local sts_out
  if ! sts_out=$(_kubectl patch statefulset "$sts_name" --type=merge -p \
    "{\"spec\":{\"updateStrategy\":{\"rollingUpdate\":{\"partition\":${replicas}}}}}" 2>&1); then
    response_err "$op" "Failed to reset partition to ${replicas} on StatefulSet ${sts_name}" \
      "{\"detail\":\"$(_escape_json_string "$sts_out")\"}" 1
    return 1
  fi

  response_ok "$op" "Recovery state cleared: wipe-targets empty, partition reset to ${replicas}" \
    "{\"sts\":\"${sts_name}\",\"configmap\":\"${cm_name}\",\"partition\":${replicas}}"
  return 0
}

# ---------------------------------------------------------------------------
# recovery_get_status <sts_name> <cm_name>
# Return current recovery state: CM wipe-targets, STS partition, pod phases.
# ---------------------------------------------------------------------------
recovery_get_status() {
  local sts_name="${1:?}" cm_name="${2:?}"
  local op="recovery_get_status"

  local wipe_targets cm_ok="false"
  _kubectl get configmap "$cm_name" &>/dev/null && cm_ok="true"
  wipe_targets=$(_kubectl get configmap "$cm_name" \
    -o jsonpath='{.data.wipe-targets}' 2>/dev/null) || wipe_targets=""

  local partition replicas
  partition=$(_kubectl get statefulset "$sts_name" \
    -o jsonpath='{.spec.updateStrategy.rollingUpdate.partition}' 2>/dev/null) || partition="unknown"
  replicas=$(_kubectl get statefulset "$sts_name" \
    -o jsonpath='{.spec.replicas}' 2>/dev/null) || replicas="unknown"

  local pods_json="[]"
  local pods_raw=""
  pods_raw=$(_recovery_list_pods "$sts_name") || true
  if [[ -n "$pods_raw" ]]; then
    local entries=""
    while IFS= read -r pod; do
      [[ -z "$pod" ]] && continue
      local phase
      phase=$(_kubectl get pod "$pod" -o jsonpath='{.status.phase}' 2>/dev/null) || phase="Unknown"
      entries+="{\"pod\":\"${pod}\",\"phase\":\"${phase}\"},"
    done <<< "$pods_raw"
    [[ -n "$entries" ]] && pods_json="[${entries%,}]"
  fi

  local active_recovery="false"
  [[ -n "$wipe_targets" ]] && active_recovery="true"

  response_ok "$op" "Recovery status retrieved" \
    "{\"sts\":\"${sts_name}\",\"configmap_found\":${cm_ok},\"wipe_targets\":\"${wipe_targets}\",\"active_recovery\":${active_recovery},\"partition\":\"${partition}\",\"replicas\":\"${replicas}\",\"pods\":${pods_json}}"
  return 0
}

# ===========================================================================
# Fix-no-primary operations  (E1+E5 combined scenario)
# ===========================================================================

# ---------------------------------------------------------------------------
# recovery_fix_diagnose <sts_name> <user> <pass>
# Query each pod's RS state and return a diagnostic report.
# ---------------------------------------------------------------------------
recovery_fix_diagnose() {
  local sts_name="${1:?}" user="${2:?}" pass="${3:?}"
  local op="recovery_fix_diagnose"
  log_info "$op" "Diagnosing RS state for StatefulSet ${sts_name}"

  local pods_raw
  pods_raw=$(_recovery_list_pods "$sts_name") || pods_raw=""

  local members_json="" primary_count=0 secondary_count=0 other_count=0
  while IFS= read -r pod; do
    [[ -z "$pod" ]] && continue
    local phase
    phase=$(_kubectl get pod "$pod" -o jsonpath='{.status.phase}' 2>/dev/null) || phase="Unknown"
    local rs_state="UNKNOWN" rs_health=0 optime_ts=0
    if [[ "$phase" == "Running" ]]; then
      local rs_out
      rs_out=$(_recovery_mongosh_pod "$pod" "$user" "$pass" \
        "try{var s=rs.status();var m=s.members.filter(function(x){return x.self;})[0];print([m.stateStr,m.health,m.optime?m.optime.ts.t:0].join(','));}catch(e){print('ERR,0,0');}" \
        2>/dev/null | tail -1) || rs_out="ERR,0,0"
      IFS=',' read -r rs_state rs_health optime_ts <<< "$rs_out"
    fi
    case "$rs_state" in PRIMARY) (( primary_count++ )) ;; SECONDARY) (( secondary_count++ )) ;; *) (( other_count++ )) ;; esac
    members_json+="{\"pod\":\"${pod}\",\"phase\":\"${phase}\",\"state\":\"${rs_state}\",\"health\":${rs_health:-0},\"optime_ts\":${optime_ts:-0}},"
  done <<< "$pods_raw"
  [[ -n "$members_json" ]] && members_json="[${members_json%,}]" || members_json="[]"

  local diagnosis recommendation
  if [[ "$primary_count" -gt 0 ]]; then
    diagnosis="PRIMARY_EXISTS"
    recommendation="Primary is already elected — no fix-no-primary needed"
  elif [[ "$secondary_count" -gt 0 ]]; then
    diagnosis="ALL_SECONDARY_NO_PRIMARY"
    recommendation="E1+E5: all pods show SECONDARY with no PRIMARY. Run fix-no-primary level=unfreeze, then level=reconfig if unfreeze does not resolve within 60s"
  else
    diagnosis="NO_HEALTHY_MEMBERS"
    recommendation="No healthy RS members found — check pod status and MongoDB logs before proceeding"
  fi

  response_ok "$op" "Diagnosis: ${diagnosis}" \
    "{\"diagnosis\":\"${diagnosis}\",\"recommendation\":\"${recommendation}\",\"primary_count\":${primary_count},\"secondary_count\":${secondary_count},\"other_count\":${other_count},\"members\":${members_json}}"
  return 0
}

# ---------------------------------------------------------------------------
# recovery_fix_unfreeze <sts_name> <user> <pass>
# Run rs.freeze(0) on all reachable Running pods to unfreeze elections.
# ---------------------------------------------------------------------------
recovery_fix_unfreeze() {
  local sts_name="${1:?}" user="${2:?}" pass="${3:?}"
  local op="recovery_fix_unfreeze"
  log_info "$op" "Sending rs.freeze(0) to all reachable pods"

  local pods_raw
  pods_raw=$(_recovery_list_pods "$sts_name") || pods_raw=""

  local results_json="" success_count=0 fail_count=0
  while IFS= read -r pod; do
    [[ -z "$pod" ]] && continue
    local phase
    phase=$(_kubectl get pod "$pod" -o jsonpath='{.status.phase}' 2>/dev/null) || continue
    [[ "$phase" != "Running" ]] && continue
    local freeze_out
    freeze_out=$(_recovery_mongosh_pod "$pod" "$user" "$pass" \
      "try{rs.freeze(0);print('ok');}catch(e){print('err:'+e.message);}" \
      2>/dev/null | tail -1) || freeze_out="err:exec failed"
    if [[ "$freeze_out" == "ok" ]]; then
      (( success_count++ ))
      results_json+="{\"pod\":\"${pod}\",\"success\":true},"
    else
      (( fail_count++ ))
      results_json+="{\"pod\":\"${pod}\",\"success\":false,\"detail\":\"${freeze_out}\"},"
    fi
  done <<< "$pods_raw"
  [[ -n "$results_json" ]] && results_json="[${results_json%,}]" || results_json="[]"

  if [[ "$success_count" -eq 0 ]]; then
    response_err "$op" "rs.freeze(0) failed on all pods — elections cannot be unfrozen" \
      "{\"success_count\":0,\"fail_count\":${fail_count},\"results\":${results_json}}" 1
    return 1
  fi
  response_ok "$op" "rs.freeze(0) sent to ${success_count} pod(s) — elections should resume within 10s" \
    "{\"success_count\":${success_count},\"fail_count\":${fail_count},\"results\":${results_json}}"
  return 0
}

# ---------------------------------------------------------------------------
# recovery_fix_reconfig <sts_name> <user> <pass>
# Run rs.reconfig({force:true}) with priority=1/votes=1 on all members
# from the pod with the most recent optime.
# ---------------------------------------------------------------------------
recovery_fix_reconfig() {
  local sts_name="${1:?}" user="${2:?}" pass="${3:?}"
  local op="recovery_fix_reconfig"
  log_info "$op" "Finding most recent pod for forced rs.reconfig"

  local pods_raw
  pods_raw=$(_recovery_list_pods "$sts_name") || pods_raw=""

  local reconfig_pod="" latest_optime=0
  while IFS= read -r pod; do
    [[ -z "$pod" ]] && continue
    local phase
    phase=$(_kubectl get pod "$pod" -o jsonpath='{.status.phase}' 2>/dev/null) || continue
    [[ "$phase" != "Running" ]] && continue
    local optime
    optime=$(_recovery_mongosh_pod "$pod" "$user" "$pass" \
      "try{var s=rs.status();var m=s.members.filter(function(x){return x.self;})[0];print(m.optime?m.optime.ts.t:0);}catch(e){print('0');}" \
      2>/dev/null | tail -1) || optime=0
    [[ "$optime" =~ ^[0-9]+$ && "$optime" -gt "$latest_optime" ]] && \
      latest_optime="$optime" && reconfig_pod="$pod"
  done <<< "$pods_raw"

  if [[ -z "$reconfig_pod" ]]; then
    response_err "$op" "No reachable Running pods found for reconfig" '{}' 1
    return 1
  fi
  log_info "$op" "Running rs.reconfig(force:true) from pod ${reconfig_pod} (optime=${latest_optime})"

  local reconfig_out
  reconfig_out=$(_recovery_mongosh_pod "$reconfig_pod" "$user" "$pass" "
try {
  var cfg=rs.conf();
  cfg.members.forEach(function(m){m.priority=1;m.votes=1;});
  cfg.version=cfg.version+1;
  print(JSON.stringify(rs.reconfig(cfg,{force:true})));
} catch(e) { print(JSON.stringify({ok:0,errmsg:e.message})); }
" 2>/dev/null | tail -1) || reconfig_out='{"ok":0,"errmsg":"exec failed"}'

  if printf '%s' "$reconfig_out" | grep -q '"ok":1'; then
    response_ok "$op" "rs.reconfig(force:true) succeeded from pod ${reconfig_pod} — election should complete within 30s" \
      "{\"reconfig_pod\":\"${reconfig_pod}\",\"result\":${reconfig_out}}"
    return 0
  fi
  response_err "$op" "rs.reconfig(force:true) failed on pod ${reconfig_pod}" \
    "{\"reconfig_pod\":\"${reconfig_pod}\",\"result\":${reconfig_out}}" 1
  return 1
}

# ---------------------------------------------------------------------------
# recovery_fix_force_primary <sts_name> <force_pod> <user> <pass>
# Last-resort: shrink RS to force_pod only, wait for election, then re-add others.
# ---------------------------------------------------------------------------
recovery_fix_force_primary() {
  local sts_name="${1:?}" force_pod="${2:?}" user="${3:?}" pass="${4:?}"
  local op="recovery_fix_force_primary"

  # Validate before interpolating into JS — pod names must be safe DNS labels.
  [[ "$force_pod" =~ ^[a-z0-9][a-z0-9-]*$ ]] || {
    response_err "$op" "Invalid force_pod: must match ^[a-z0-9][a-z0-9-]*\$" \
      "{\"force_pod\":\"$(_escape_json_string "$force_pod")\"}" 1
    return 1
  }

  log_info "$op" "Force-primary: shrinking RS to single member ${force_pod}"

  # Get current RS config to know member hosts for re-add
  local cfg_raw
  cfg_raw=$(_recovery_mongosh_pod "$force_pod" "$user" "$pass" \
    "try{print(JSON.stringify(rs.conf()));}catch(e){print(JSON.stringify({ok:0,errmsg:e.message}));}" \
    2>/dev/null | tail -1) || cfg_raw='{"ok":0,"errmsg":"exec failed"}'
  if printf '%s' "$cfg_raw" | grep -q '"ok":0'; then
    response_err "$op" "Cannot read RS config from pod ${force_pod}" \
      "{\"detail\":${cfg_raw}}" 1
    return 1
  fi

  # Shrink to single member
  local shrink_out
  shrink_out=$(_recovery_mongosh_pod "$force_pod" "$user" "$pass" "
try {
  var cfg=rs.conf();
  var me=cfg.members.filter(function(m){return m.host.indexOf('${force_pod}')!==-1;})[0];
  if(!me){print(JSON.stringify({ok:0,errmsg:'member for pod ${force_pod} not found in RS config'}));return;}
  var newCfg={_id:cfg._id,version:cfg.version+1,members:[{_id:me._id,host:me.host,priority:1,votes:1}]};
  print(JSON.stringify(rs.reconfig(newCfg,{force:true})));
} catch(e){print(JSON.stringify({ok:0,errmsg:e.message}));}
" 2>/dev/null | tail -1) || shrink_out='{"ok":0,"errmsg":"exec failed"}'

  if ! printf '%s' "$shrink_out" | grep -q '"ok":1'; then
    response_err "$op" "Failed to shrink RS to single member on pod ${force_pod}" \
      "{\"shrink_result\":${shrink_out}}" 1
    return 1
  fi

  log_info "$op" "Shrunk RS to ${force_pod} — waiting 15s for primary election"
  sleep 15

  # Re-add other Running pods using host from original config
  local pods_raw
  pods_raw=$(_recovery_list_pods "$sts_name") || pods_raw=""
  local re_add_json=""
  while IFS= read -r pod; do
    [[ -z "$pod" || "$pod" == "$force_pod" ]] && continue
    local phase
    phase=$(_kubectl get pod "$pod" -o jsonpath='{.status.phase}' 2>/dev/null) || continue
    [[ "$phase" != "Running" ]] && continue
    local pod_host
    pod_host=$(printf '%s' "$cfg_raw" | grep -o "\"host\":\"[^\"]*${pod}[^\"]*\"" | head -1 | cut -d'"' -f4)
    [[ -z "$pod_host" ]] && pod_host="${pod}.${sts_name}.${K8S_NAMESPACE}.svc.cluster.local:27017"
    local add_out
    add_out=$(_recovery_mongosh_pod "$force_pod" "$user" "$pass" \
      "try{print(JSON.stringify(rs.add('${pod_host}')));}catch(e){print(JSON.stringify({ok:0,errmsg:e.message}));}" \
      2>/dev/null | tail -1) || add_out='{"ok":0,"errmsg":"exec failed"}'
    re_add_json+="{\"pod\":\"${pod}\",\"host\":\"${pod_host}\",\"result\":${add_out}},"
  done <<< "$pods_raw"
  [[ -n "$re_add_json" ]] && re_add_json="[${re_add_json%,}]" || re_add_json="[]"

  response_ok "$op" "Force-primary complete: ${force_pod} should be PRIMARY; other members re-added" \
    "{\"force_pod\":\"${force_pod}\",\"shrink_result\":${shrink_out},\"re_add_results\":${re_add_json},\"note\":\"Verify with rs.status() — allow 15–30s for election to finalize\"}"
  return 0
}

# ===========================================================================
# Sync source
# ===========================================================================

# ---------------------------------------------------------------------------
# recovery_set_sync_source <sts_name> <target_pod> <user> <pass>
#
# Direct target_pod to sync from the best available member:
#   - Prefers a healthy SECONDARY to avoid burdening the primary
#   - Falls back to PRIMARY when no healthy secondary is found
#
# Retries up to 6 × 5 s (30 s) waiting for mongod to accept connections
# after a fresh restart before giving up.  Failure is non-fatal to the
# overall recovery — MongoDB will still sync; it just picks its own source.
# ---------------------------------------------------------------------------
recovery_set_sync_source() {
  local sts_name="${1:?}" target_pod="${2:?}" user="${3:?}" pass="${4:?}"
  local op="recovery_set_sync_source"

  # Walk all non-target Running pods; prefer SECONDARY, note PRIMARY as fallback
  local pods_raw
  pods_raw=$(_recovery_list_pods "$sts_name") || pods_raw=""

  local primary_pod="" secondary_pod=""
  while IFS= read -r pod; do
    [[ -z "$pod" || "$pod" == "$target_pod" ]] && continue
    local phase
    phase=$(_kubectl get pod "$pod" -o jsonpath='{.status.phase}' 2>/dev/null) || continue
    [[ "$phase" != "Running" ]] && continue
    local rs_out state health
    rs_out=$(_recovery_mongosh_pod "$pod" "$user" "$pass" \
      "try{var s=rs.status();var m=s.members.filter(function(x){return x.self;})[0];print(m.stateStr+','+m.health);}catch(e){print('ERR,0');}" \
      2>/dev/null | tail -1) || continue
    state="${rs_out%%,*}"; health="${rs_out##*,}"
    [[ "$state" == "SECONDARY" && "$health" == "1" && -z "$secondary_pod" ]] && secondary_pod="$pod"
    [[ "$state" == "PRIMARY"   && "$health" == "1" && -z "$primary_pod"   ]] && primary_pod="$pod"
  done <<< "$pods_raw"

  local sync_pod="" sync_type=""
  if [[ -n "$secondary_pod" ]]; then
    sync_pod="$secondary_pod"; sync_type="SECONDARY"
  elif [[ -n "$primary_pod" ]]; then
    sync_pod="$primary_pod";   sync_type="PRIMARY"
  else
    response_err "$op" "No healthy sync source found for ${target_pod} — skipping replSetSyncFrom" \
      "{\"target_pod\":\"${target_pod}\"}" 1
    return 1
  fi

  # Resolve the RS-registered host:port for the chosen pod
  local sync_host
  sync_host=$(_recovery_mongosh_pod "$sync_pod" "$user" "$pass" \
    "try{var s=rs.status();var m=s.members.filter(function(x){return x.self;})[0];print(m.name);}catch(e){print('');}" \
    2>/dev/null | tail -1) || sync_host=""
  if [[ -z "$sync_host" ]]; then
    response_err "$op" "Cannot resolve RS host:port for pod ${sync_pod}" \
      "{\"sync_pod\":\"${sync_pod}\"}" 1
    return 1
  fi

  log_info "$op" "Directing ${target_pod} to sync from ${sync_type} ${sync_pod} (${sync_host})"

  # Retry: mongod may need a moment after restart before accepting connections
  local retry_delay="${RECOVERY_SYNCFROM_RETRY_DELAY:-5}"
  local sync_out="" attempt
  for attempt in 1 2 3 4 5 6; do
    sync_out=$(_recovery_mongosh_pod "$target_pod" "$user" "$pass" \
      "try{print(JSON.stringify(db.adminCommand({replSetSyncFrom:'${sync_host}'})));}catch(e){print(JSON.stringify({ok:0,errmsg:e.message}));}" \
      2>/dev/null | tail -1) || sync_out='{}'
    printf '%s' "$sync_out" | grep -q '"ok":1' && break
    log_info "$op" "replSetSyncFrom attempt ${attempt}/6 failed — retrying in ${retry_delay}s"
    sleep "$retry_delay"
  done

  if printf '%s' "$sync_out" | grep -q '"ok":1'; then
    response_ok "$op" "Sync source set: ${target_pod} → ${sync_type} ${sync_pod} (${sync_host})" \
      "{\"target_pod\":\"${target_pod}\",\"sync_source_pod\":\"${sync_pod}\",\"sync_source_type\":\"${sync_type}\",\"sync_host\":\"${sync_host}\"}"
    return 0
  fi

  response_err "$op" "replSetSyncFrom failed after 6 attempts on pod ${target_pod} — MongoDB will choose its own sync source" \
    "{\"target_pod\":\"${target_pod}\",\"sync_pod\":\"${sync_pod}\",\"sync_host\":\"${sync_host}\",\"last_result\":${sync_out:-\{\}}}" 1
  return 1
}

# ===========================================================================
# Orchestrator
# ===========================================================================

# ---------------------------------------------------------------------------
# _recovery_pod_uid <pod_name>
# Echo the pod's metadata.uid (empty string if the pod does not exist).
# ---------------------------------------------------------------------------
_recovery_pod_uid() {
  _kubectl get pod "$1" -o jsonpath='{.metadata.uid}' 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# _recovery_pod_phase <pod_name>
# Echo the pod's status.phase (empty string if the pod does not exist).
# ---------------------------------------------------------------------------
_recovery_pod_phase() {
  _kubectl get pod "$1" -o jsonpath='{.status.phase}' 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# recovery_recover <sts> <target_pod> <cm> <user> <pass> <replicas> [timeout]
#
# Full automated recovery in a single call:
#   1. Capture the target pod's current UID (to detect restart)
#   2. Run G1–G8 gates (gate mode — aborts on first blocking failure)
#   3. recovery_wipe_pod  (set wipe-target + partition + annotation bump)
#   4. Poll until the pod is RECREATED (UID changes) AND reaches Running
#      — this guarantees the init container actually ran and wiped data
#   5. recovery_reset  (clear wipe-target + restore partition) the instant
#      the pod is Running, closing the dangerous re-wipe race automatically.
#      Only THEN attempt set-sync-source (best-effort, can take ~30s of
#      retries) — it must never delay the reset.
#
# On timeout (pod never restarts / never reaches Running) it deliberately
# does NOT reset — leaving wipe-target in place so a manual investigation can
# decide.  Initial sync is NOT awaited here; the response includes a pointer
# to monitor it.
#
# Env knobs:
#   RECOVERY_POLL_INTERVAL  seconds between polls (default 5)
# ---------------------------------------------------------------------------
recovery_recover() {
  local sts="${1:?}" target_pod="${2:?}" cm="${3:?}"
  local user="${4:?}" pass="${5:?}" replicas="${6:?}"
  local timeout="${7:-300}"
  local op="recovery_recover"
  local poll_interval="${RECOVERY_POLL_INTERVAL:-5}"

  log_info "$op" "Starting orchestrated recovery for pod ${target_pod}"

  # 1. Capture pre-wipe UID (may be empty if pod is fully gone)
  local old_uid
  old_uid=$(_recovery_pod_uid "$target_pod")
  log_info "$op" "Pre-wipe UID of ${target_pod}: '${old_uid:-<none>}'"

  # 2. Gates (gate mode)
  local gates_result
  if ! gates_result=$(recovery_run_gates "$sts" "$target_pod" "$cm" "$user" "$pass" "gate"); then
    local gdata
    gdata=$(printf '%s' "$gates_result" | grep -o '"data":.*' | sed 's/^"data"://;s/,"timestamp".*//')
    response_err "$op" "Recovery aborted at pre-flight gates" \
      "{\"phase\":\"gates\",\"gates\":${gdata:-null},\"target_pod\":\"${target_pod}\"}" 1
    return 1
  fi

  # 3. Wipe — discard the inner JSON response (we emit our own); keep exit status
  if ! recovery_wipe_pod "$sts" "$target_pod" "$cm" >/dev/null; then
    response_err "$op" "Recovery aborted while applying wipe" \
      "{\"phase\":\"wipe\",\"target_pod\":\"${target_pod}\"}" 1
    return 1
  fi

  # 4. Wait for the pod to be RECREATED and reach Running
  log_info "$op" "Waiting up to ${timeout}s for ${target_pod} to restart and reach Running"
  local start now elapsed=0 recreated=false ran=false
  start=$(date +%s)
  while (( elapsed < timeout )); do
    local cur_uid cur_phase
    cur_uid=$(_recovery_pod_uid "$target_pod")
    cur_phase=$(_recovery_pod_phase "$target_pod")

    if [[ -n "$old_uid" ]]; then
      # Pod existed before — require a NEW uid (init container has run) + Running
      [[ -n "$cur_uid" && "$cur_uid" != "$old_uid" ]] && recreated=true
      [[ "$recreated" == "true" && "$cur_phase" == "Running" ]] && { ran=true; break; }
    else
      # Pod was absent before — any Running pod with a uid means it came up
      [[ -n "$cur_uid" && "$cur_phase" == "Running" ]] && { ran=true; break; }
    fi

    sleep "$poll_interval"
    now=$(date +%s); elapsed=$(( now - start ))
  done

  # 5a. Timeout — do NOT reset; leave state for manual decision
  if [[ "$ran" != "true" ]]; then
    response_err "$op" "Pod ${target_pod} did not restart+reach Running within ${timeout}s — wipe-target left in place for manual review" \
      "{\"phase\":\"wait\",\"target_pod\":\"${target_pod}\",\"recreated\":${recreated},\"timeout\":${timeout},\"action_required\":\"Inspect pod; run recovery/reset manually once it is Running, or recovery/status to diagnose\"}" 1
    return 1
  fi

  # 5b. Reset immediately (closes the re-wipe race) — before anything else,
  # including set-sync-source which may retry for ~30s. Discard the inner JSON.
  if ! recovery_reset "$sts" "$cm" "$replicas" >/dev/null; then
    response_err "$op" "Pod ${target_pod} is Running but recovery/reset failed — wipe-target may still be set" \
      "{\"phase\":\"reset\",\"target_pod\":\"${target_pod}\",\"action_required\":\"Run recovery/reset manually NOW to prevent re-wipe on next restart\"}" 1
    return 1
  fi

  # 5c. Direct sync source: prefer secondary, fall back to primary (non-fatal)
  local sync_src_ok="false"
  if recovery_set_sync_source "$sts" "$target_pod" "$user" "$pass" >/dev/null 2>&1; then
    sync_src_ok="true"
  else
    log_info "$op" "Warning: could not set sync source — MongoDB will pick automatically"
  fi

  log_info "$op" "Recovery orchestration complete for ${target_pod}; initial sync now in progress"
  response_ok "$op" "Recovery complete for ${target_pod}: data wiped, pod restarted, recovery state cleared. Initial sync is now running." \
    "{\"target_pod\":\"${target_pod}\",\"old_uid\":\"${old_uid}\",\"recreated\":true,\"reached_running\":true,\"sync_source_set\":${sync_src_ok},\"partition_restored\":${replicas},\"elapsed_seconds\":${elapsed},\"next_step\":\"Monitor initial sync with recovery/status and rs.status() until the pod catches up to the primary (SECONDARY, optime in sync)\"}"
  return 0
}
