#!/usr/bin/env bash
# =============================================================================
# mongodb-pbm-physical.sh — physical/incremental backup gates and the
# physical-restore StatefulSet TAKEOVER orchestration primitives for the
# pbm/* tasks (see docs/mongodb/pbm.md).
#
# Why a takeover exists: PBM physical restore requires pbm-agent to stop
# mongod, replace its data files, and spawn temporary mongod processes
# (mongod binary must be in the agent's PATH — Percona docs' container
# guidance is "PBM files and MongoDB binaries in the same container"). In a
# plain StatefulSet mongod is the container's PID 1: a sidecar can't stop
# it, and if it exits the kubelet restarts it with its ORIGINAL arguments —
# exactly what a physical restore must prevent. So for the restore window
# the StatefulSet is patched into takeover mode: pbm binaries are copied
# into the mongod container (initContainer + emptyDir; pbm is a static Go
# binary), the mongod container's command becomes a supervisor that runs
# the original mongod command line as a background child with pbm-agent in
# the foreground, probes are removed, and the normal agent sidecar sleeps.
# Patch/revert mirror the annotation-tracked surgical pattern of
# _recovery_auto_patch_init_container/_recovery_revert_auto_patch in
# mongodb-recovery.sh (each lib carries its own copy by convention).
#
# Dependencies (sourced by the calling script, not here):
#   logging.sh, k8s.sh (_kubectl), mongodb-recovery.sh (_recovery_list_pods),
#   mongodb-pbm.sh (_pbm_exec/_pbm_exec_json idioms, storage rendering),
#   mongodb-account.sh (fail_task — used only by task scripts, not here).
#
# Everything here fails soft (rc 1 + empty/raw stdout) — the task scripts
# own fail_task codes and messages.
# =============================================================================

[[ -n "${_MONGODB_PBM_PHYSICAL_LIB_LOADED:-}" ]] && return 0
_MONGODB_PBM_PHYSICAL_LIB_LOADED=1

_PBM_PHYS_BIN_DIR="/opt/pbm-bin"
_PBM_PHYS_INIT_CONTAINER="pbm-binaries"
_PBM_PHYS_BIN_VOLUME="pbm-bin"
_PBM_PHYS_ANNOTATION="pbm-restore/auto-patched"
_PBM_PHYS_ORIGINAL_ANNOTATION="pbm-restore/original"

# ---------------------------------------------------------------------------
# _pbm_phys_get_sts_json <sts_name>
# ---------------------------------------------------------------------------
_pbm_phys_get_sts_json() {
  local sts_name="${1:?sts_name is required}"
  local out
  out=$(_kubectl get statefulset "$sts_name" -o json 2>/dev/null) || return 1
  [[ -z "$out" ]] && return 1
  printf '%s' "$out"
}

# ---------------------------------------------------------------------------
# pbm_phys_detect_mongod_container <sts_json> <agent_container>
# The non-agent container publishing port 27017; falls back to the first
# non-agent container. Fails soft when only the agent exists.
# ---------------------------------------------------------------------------
pbm_phys_detect_mongod_container() {
  local sts_json="${1:?}" agent="${2:?}"
  local name
  name=$(printf '%s' "$sts_json" | jq -r --arg a "$agent" '
    ([.spec.template.spec.containers[]?
      | select(.name != $a)
      | select(any(.ports[]?; .containerPort == 27017))][0].name)
    // ([.spec.template.spec.containers[]? | select(.name != $a)][0].name)
    // empty' 2>/dev/null)
  [[ -z "$name" ]] && return 1
  log_debug "mongo-pbm-phys" "mongod container detected: ${name}"
  printf '%s' "$name"
}

# ---------------------------------------------------------------------------
# pbm_phys_detect_engine <pod> <mongod_container>
# Ask mongod itself (buildInfo runs pre-auth, so this keeps the pbm/* tasks
# credential-free). Prints "psmdb:<version>" or "community:<version>";
# rc 1 when no sentinel came back (pod down, kubectl error).
# ---------------------------------------------------------------------------
pbm_phys_detect_engine() {
  local pod="${1:?}" container="${2:?}"
  local js out
  js='try{var b=db.adminCommand({buildInfo:1});'
  js+='print("ENGINE:"+(b.psmdbVersion?("psmdb:"+b.psmdbVersion):("community:"+b.version)));}'
  js+='catch(e){print("ENGINEERR:"+e.message);}'
  out=$(_kubectl exec "$pod" -c "$container" -- \
    mongosh --quiet --norc --eval "$js" 2>/dev/null | tail -1 | tr -d '\r') || return 1
  log_debug "mongo-pbm-phys" "engine sentinel from ${pod}/${container}: ${out}"
  [[ "$out" == ENGINE:* ]] || return 1
  printf '%s' "${out#ENGINE:}"
}

# ---------------------------------------------------------------------------
# pbm_phys_agent_volume_ok <sts_json> <agent_container> <mongod_container>
# Physical backups read data files straight off the volume, so the agent
# sidecar must mount every volumeClaimTemplate-backed volume the mongod
# container mounts, at the SAME path ($backupCursor returns absolute
# paths). rc 0 ok; rc 1 with the missing mounts (JSON array) on stdout.
# ---------------------------------------------------------------------------
pbm_phys_agent_volume_ok() {
  local sts_json="${1:?}" agent="${2:?}" mongod="${3:?}"
  local missing
  missing=$(printf '%s' "$sts_json" | jq -c --arg a "$agent" --arg m "$mongod" '
    [.spec.volumeClaimTemplates[]?.metadata.name] as $vcts
    | ([.spec.template.spec.containers[] | select(.name==$m)
        | .volumeMounts[]? | select(.name as $n | $vcts | index($n))
        | {name, mountPath}]) as $need
    | ([.spec.template.spec.containers[] | select(.name==$a)
        | .volumeMounts[]? | {name, mountPath}]) as $have
    | if ($need | length) == 0 then $need else [$need[] | select([.] - $have != [])] end
    ' 2>/dev/null) || missing='[]'
  local need_count
  need_count=$(printf '%s' "$sts_json" | jq -r --arg m "$mongod" '
    [.spec.volumeClaimTemplates[]?.metadata.name] as $vcts
    | [.spec.template.spec.containers[] | select(.name==$m)
       | .volumeMounts[]? | select(.name as $n | $vcts | index($n))] | length' 2>/dev/null) || need_count=0
  if [[ "$need_count" == "0" ]]; then
    log_debug "mongo-pbm-phys" "no volumeClaimTemplate-backed data mounts found on ${mongod} — cannot verify agent volume sharing"
    printf '[]'
    return 1
  fi
  if [[ "$(printf '%s' "$missing" | jq -r 'length' 2>/dev/null)" == "0" ]]; then
    log_debug "mongo-pbm-phys" "agent ${agent} shares all ${need_count} data mount(s) of ${mongod}"
    return 0
  fi
  log_debug "mongo-pbm-phys" "agent ${agent} is missing data mounts: ${missing}"
  printf '%s' "$missing"
  return 1
}

# ---------------------------------------------------------------------------
# pbm_phys_in_progress <sts_json>
# rc 0 when a takeover annotation is present (a previous physical restore
# is running or was left behind).
# ---------------------------------------------------------------------------
pbm_phys_in_progress() {
  local sts_json="${1:?}"
  printf '%s' "$sts_json" | jq -e --arg k "$_PBM_PHYS_ANNOTATION" \
    '.metadata.annotations[$k] == "true"' >/dev/null 2>&1
}

# ---------------------------------------------------------------------------
# _pbm_phys_added_env <sts_json> <agent_container>
# The env entries to copy from the agent sidecar into the mongod container
# for the takeover: PBM_MONGODB_URI plus the closure of $(NAME) references
# inside copied values (k8s dependent-env composition) — read live, never
# guessed. Prints a JSON array of env entries.
# ---------------------------------------------------------------------------
_pbm_phys_added_env() {
  local sts_json="${1:?}" agent="${2:?}"
  printf '%s' "$sts_json" | jq -c --arg a "$agent" '
    (.spec.template.spec.containers[] | select(.name==$a) | .env // []) as $env
    | reduce range(0; 4) as $i (["PBM_MONGODB_URI"];
        . as $names
        | ($env
           | map(select(.name as $n | $names | index($n)))
           | map((.value // "") | [scan("\\$\\(([A-Za-z_][A-Za-z0-9_]*)\\)")] | flatten)
           | flatten) as $refs
        | ($names + $refs) | unique)
    | . as $names
    | $env | map(select(.name as $n | $names | index($n)))' 2>/dev/null
}

# ---------------------------------------------------------------------------
# pbm_phys_patch_takeover <sts_name> <mongod_container> <agent_container>
# Snapshot the original shape into an annotation, then strategic-patch the
# StatefulSet into takeover mode. Requires the mongod container to declare
# an explicit command (the supervisor must reproduce the exact command
# line); rc 2 signals that precondition failure specifically.
# Prints "patched" on success.
# ---------------------------------------------------------------------------
pbm_phys_patch_takeover() {
  local sts_name="${1:?}" mongod_c="${2:?}" agent_c="${3:?}"
  local _op="pbm_phys_patch_takeover"
  local sts_json
  sts_json=$(_pbm_phys_get_sts_json "$sts_name") || return 1

  local has_cmd
  has_cmd=$(printf '%s' "$sts_json" | jq -r --arg m "$mongod_c" '
    (.spec.template.spec.containers[] | select(.name==$m) | .command // []) | length' 2>/dev/null)
  if [[ -z "$has_cmd" || "$has_cmd" == "0" ]]; then
    log_debug "$_op" "mongod container ${mongod_c} has no explicit command — supervisor cannot reproduce an image-default entrypoint"
    return 2
  fi

  local added_env added_names
  added_env=$(_pbm_phys_added_env "$sts_json" "$agent_c")
  [[ -z "$added_env" || "$added_env" == "[]" ]] && {
    log_debug "$_op" "agent ${agent_c} carries no PBM_MONGODB_URI env to copy"
    return 1
  }
  added_names=$(printf '%s' "$added_env" | jq -c 'map(.name)')

  local snapshot
  snapshot=$(printf '%s' "$sts_json" | jq -c \
    --arg m "$mongod_c" --arg a "$agent_c" --argjson added "$added_names" '
    (.spec.template.spec.containers[] | select(.name==$m)) as $mc
    | (.spec.template.spec.containers[] | select(.name==$a)) as $ac
    | {mongod_container: $m, agent_container: $a,
       mongod: {command: ($mc.command // null), args: ($mc.args // null),
                readinessProbe: ($mc.readinessProbe // null),
                livenessProbe: ($mc.livenessProbe // null),
                startupProbe: ($mc.startupProbe // null)},
       agent: {command: ($ac.command // null), args: ($ac.args // null)},
       added_env: $added,
       termination_grace_period: (.spec.template.spec.terminationGracePeriodSeconds // 30)}' 2>/dev/null) || return 1

  local agent_image
  agent_image=$(printf '%s' "$sts_json" | jq -r --arg a "$agent_c" '
    .spec.template.spec.containers[] | select(.name==$a) | .image // empty' 2>/dev/null)
  [[ -z "$agent_image" ]] && return 1

  # The original mongod command line, shell-quoted, run as a background
  # child of the supervisor: pbm-agent can shut it down (db.shutdownServer)
  # without the container dying, and spawns its own temporary mongods
  # (from PATH — the mongod image) during the restore phases.
  #
  # One-shot on purpose — NOT retried. The dbPath-flock race this could
  # otherwise hit (a recreated pod's mongod starting before its predecessor's
  # container is actually dead) is closed one layer down, by
  # pbm_phys_recreate_pods using a graceful delete: the replacement pod
  # object cannot exist until the old container is gone, so the two mongods
  # are never up at once. A retry loop here would instead risk relaunching
  # mongod against a live pbm-agent restore in progress if it ever exited
  # abnormally mid-restore for an unrelated reason (OOM, etc).
  local mongod_cmdline supervisor
  mongod_cmdline=$(printf '%s' "$snapshot" | jq -r \
    '((.mongod.command // []) + (.mongod.args // [])) | map(@sh) | join(" ")')
  supervisor=$(printf '%s\n' \
    "echo '[pbm-takeover] starting mongod (background) + pbm-agent (foreground retry loop)'" \
    "${mongod_cmdline} &" \
    "export PATH=\"${_PBM_PHYS_BIN_DIR}:\$PATH\"" \
    "while true; do" \
    "  ${_PBM_PHYS_BIN_DIR}/pbm-agent" \
    "  echo \"[pbm-takeover] pbm-agent exited rc=\$?; retrying in 5s\"" \
    "  sleep 5" \
    "done")

  # terminationGracePeriodSeconds is shortened for the takeover template
  # only: takeover pods are never gracefully shut down from the inside
  # (mongod is stopped over the wire by pbm-agent, not by a signal), and
  # the /bin/sh -c supervisor that ends up as PID 1 has no TERM trap — the
  # kernel does not apply the default SIGTERM action to an unhandled signal
  # on PID 1, so without this every delete of a takeover pod (revert,
  # rollback) would sit out the full original grace period before the
  # kubelet SIGKILLs it. Reverted to the snapshotted original value below.
  local patch
  patch=$(jq -nc \
    --arg anno "$_PBM_PHYS_ANNOTATION" --arg orig_anno "$_PBM_PHYS_ORIGINAL_ANNOTATION" \
    --arg snapshot "$snapshot" \
    --arg image "$agent_image" \
    --arg mongod "$mongod_c" --arg agent "$agent_c" \
    --arg sup "$supervisor" \
    --arg bin_dir "$_PBM_PHYS_BIN_DIR" \
    --arg init_name "$_PBM_PHYS_INIT_CONTAINER" --arg vol "$_PBM_PHYS_BIN_VOLUME" \
    --argjson env "$added_env" \
    '{metadata: {annotations: {($anno): "true", ($orig_anno): $snapshot}},
      spec: {
        updateStrategy: {rollingUpdate: {partition: 0}},
        template: {spec: {
          terminationGracePeriodSeconds: 5,
          initContainers: [{name: $init_name, image: $image,
            command: ["sh", "-c",
              "cp /usr/bin/pbm /usr/bin/pbm-agent /pbm-bin/ && chmod 755 /pbm-bin/pbm /pbm-bin/pbm-agent"],
            volumeMounts: [{name: $vol, mountPath: "/pbm-bin"}]}],
          volumes: [{name: $vol, emptyDir: {}}],
          containers: [
            {name: $mongod,
             command: ["/bin/sh", "-c"], args: [$sup],
             env: $env,
             volumeMounts: [{name: $vol, mountPath: $bin_dir}],
             readinessProbe: null, livenessProbe: null, startupProbe: null},
            {name: $agent, command: ["sleep", "infinity"], args: null}
          ]}}}}')

  if ! _kubectl patch statefulset "$sts_name" --type=strategic -p "$patch" >/dev/null 2>&1; then
    log_debug "$_op" "strategic patch failed for StatefulSet ${sts_name}"
    return 1
  fi
  log_info "$_op" "StatefulSet ${sts_name} patched into pbm takeover mode (mongod supervised, probes off, sidecar parked, pbm binaries via ${_PBM_PHYS_INIT_CONTAINER})"
  printf 'patched'
}

# ---------------------------------------------------------------------------
# pbm_phys_revert_takeover <sts_name>
# Surgical revert from the annotation snapshot: original command/args/probes
# restored, injected env/volumeMount/initContainer/volume removed via
# $patch:delete, annotations cleared. No-op (rc 0) when the annotation is
# absent. Prints "reverted" when it actually reverted.
# ---------------------------------------------------------------------------
pbm_phys_revert_takeover() {
  local sts_name="${1:?}"
  local _op="pbm_phys_revert_takeover"
  local sts_json orig
  sts_json=$(_pbm_phys_get_sts_json "$sts_name") || return 1
  pbm_phys_in_progress "$sts_json" || return 0
  orig=$(printf '%s' "$sts_json" | jq -r --arg k "$_PBM_PHYS_ORIGINAL_ANNOTATION" \
    '.metadata.annotations[$k] // empty' 2>/dev/null)
  if [[ -z "$orig" ]] || ! printf '%s' "$orig" | jq -e . >/dev/null 2>&1; then
    log_error "$_op" "takeover annotation present but ${_PBM_PHYS_ORIGINAL_ANNOTATION} snapshot is missing/corrupt on ${sts_name} — manual revert required"
    return 1
  fi

  local patch
  patch=$(jq -nc \
    --arg anno "$_PBM_PHYS_ANNOTATION" --arg orig_anno "$_PBM_PHYS_ORIGINAL_ANNOTATION" \
    --arg bin_dir "$_PBM_PHYS_BIN_DIR" \
    --arg init_name "$_PBM_PHYS_INIT_CONTAINER" --arg vol "$_PBM_PHYS_BIN_VOLUME" \
    --argjson o "$orig" \
    '{metadata: {annotations: {($anno): null, ($orig_anno): null}},
      spec: {template: {spec: {
        terminationGracePeriodSeconds: ($o.termination_grace_period // 30),
        initContainers: [{name: $init_name, "$patch": "delete"}],
        volumes: [{name: $vol, "$patch": "delete"}],
        containers: [
          {name: $o.mongod_container,
           command: $o.mongod.command, args: $o.mongod.args,
           readinessProbe: $o.mongod.readinessProbe,
           livenessProbe: $o.mongod.livenessProbe,
           startupProbe: $o.mongod.startupProbe,
           env: ($o.added_env | map({name: ., "$patch": "delete"})),
           volumeMounts: [{mountPath: $bin_dir, "$patch": "delete"}]},
          {name: $o.agent_container, command: $o.agent.command, args: $o.agent.args}
        ]}}}}')

  if ! _kubectl patch statefulset "$sts_name" --type=strategic -p "$patch" >/dev/null 2>&1; then
    log_error "$_op" "revert patch failed for StatefulSet ${sts_name} — takeover annotation left in place for a retry"
    return 1
  fi
  log_info "$_op" "StatefulSet ${sts_name} reverted to its original shape (takeover removed)"
  printf 'reverted'
}

# ---------------------------------------------------------------------------
# pbm_phys_recreate_pods <sts_name> <timeout_seconds>
# Delete every pod of the StatefulSet so they re-create with the current
# template (takeover or reverted), then wait until spec.replicas pods are
# Ready again. GRACEFUL delete on purpose: --force removes the pod object
# from the API before the old containers are actually dead, so the
# replacement's mongod races its own still-running predecessor for the
# dbPath flock and loses (DBPathInUse — field-hit in CI). A normal delete
# only releases the name once the containers are gone. --wait=false keeps
# the deletes concurrent; the Ready poll below is the real barrier.
# ---------------------------------------------------------------------------
pbm_phys_recreate_pods() {
  local sts_name="${1:?}" timeout="${2:-420}"
  local _op="pbm_phys_recreate_pods"
  local pods pod replicas selector
  replicas=$(_kubectl get statefulset "$sts_name" -o jsonpath='{.spec.replicas}' 2>/dev/null) || replicas=""
  [[ -z "$replicas" ]] && return 1
  # Resolve the selector ONCE — an empty -l would silently count every pod
  # in the namespace.
  selector=$(_kubectl get statefulset "$sts_name" \
    -o go-template='{{range $k,$v := .spec.selector.matchLabels}}{{$k}}={{$v}},{{end}}' 2>/dev/null \
    | sed 's/,$//') || selector=""
  [[ -z "$selector" ]] && return 1
  pods=$(_recovery_list_pods "$sts_name") || true
  while IFS= read -r pod; do
    [[ -z "$pod" ]] && continue
    log_debug "$_op" "deleting pod ${pod} (graceful)"
    _kubectl delete pod "$pod" --wait=false >/dev/null 2>&1 || true
  done <<< "$pods"

  local start now ready
  start=$(date +%s)
  while true; do
    ready=$(_kubectl get pods -l "$selector" -o json 2>/dev/null | jq -r '
        [.items[] | select(.metadata.deletionTimestamp == null)
         | select([.status.conditions[]? | select(.type=="Ready" and .status=="True")] | length > 0)]
        | length' 2>/dev/null) || ready=0
    if [[ "${ready:-0}" -ge "$replicas" ]]; then
      log_info "$_op" "all ${replicas} pod(s) of ${sts_name} are Ready on the current template"
      return 0
    fi
    now=$(date +%s)
    if (( now - start >= timeout )); then
      log_error "$_op" "only ${ready:-0}/${replicas} pod(s) Ready after ${timeout}s"
      return 1
    fi
    log_debug "$_op" "waiting for pods: ${ready:-0}/${replicas} Ready ($(( now - start ))s elapsed)"
    sleep 5
  done
}

# ---------------------------------------------------------------------------
# _pbm_phys_exec <pod> <mongod_container> <pbm args...>
# pbm CLI from the takeover binaries inside the mongod container.
# ---------------------------------------------------------------------------
_pbm_phys_exec() {
  local pod="${1:?}" container="${2:?}"
  shift 2
  log_debug "mongo-pbm-phys" "exec pod=${pod} container=${container}: pbm $*"
  local out rc=0
  out=$(_kubectl exec "$pod" -c "$container" -- "${_PBM_PHYS_BIN_DIR}/pbm" "$@" 2>&1) || rc=$?
  log_debug "mongo-pbm-phys" "pbm ${1:-} rc=${rc} output(truncated): ${out:0:2000}"
  printf '%s' "$out"
  return "$rc"
}

# ---------------------------------------------------------------------------
# _pbm_phys_exec_json <pod> <mongod_container> <pbm args...>
# ---------------------------------------------------------------------------
_pbm_phys_exec_json() {
  local pod="${1:?}" container="${2:?}"
  shift 2
  local out rc=0 json
  out=$(_pbm_phys_exec "$pod" "$container" "$@" -o json) || rc=$?
  json=$(printf '%s' "$out" | jq -c . 2>/dev/null) || {
    printf '%s' "$out"
    return 1
  }
  if (( rc != 0 )); then
    printf '%s' "$out"
    return "$rc"
  fi
  printf '%s' "$json"
}

# ---------------------------------------------------------------------------
# pbm_phys_wait_agents <pod> <mongod_container> <expected> <timeout>
# Poll pbm status (takeover binaries) until <expected> agents report ok.
# ---------------------------------------------------------------------------
pbm_phys_wait_agents() {
  local pod="${1:?}" container="${2:?}" expected="${3:-1}" timeout="${4:-180}"
  local start now status_json
  start=$(date +%s)
  while true; do
    if status_json=$(_pbm_phys_exec_json "$pod" "$container" status) \
        && printf '%s' "$status_json" | jq -e --argjson n "$expected" '
          [.cluster[]?.nodes[]?] | length >= $n and all(.ok == true)' >/dev/null 2>&1; then
      log_debug "mongo-pbm-phys" "all ${expected} takeover agent(s) report ok"
      return 0
    fi
    now=$(date +%s)
    if (( now - start >= timeout )); then
      log_error "mongo-pbm-phys" "takeover agents not all ok after ${timeout}s"
      return 1
    fi
    log_debug "mongo-pbm-phys" "waiting for takeover agents ($(( now - start ))s elapsed)"
    sleep 5
  done
}

# ---------------------------------------------------------------------------
# pbm_phys_wait_restore <pod> <mongod_container> <restore_name> <timeout>
# During a physical restore the database is DOWN, so progress lives in
# status files on the S3 storage: describe-restore needs an explicit
# config (-c). The storage YAML (with credentials) is piped via stdin to a
# temp file inside the container — never on an argv, never logged.
# Requires pbm_resolve_backup_location to have run (PBM_* location vars).
# Prints the final describe JSON. rc: 0 done, 1 error, 124 timeout.
# ---------------------------------------------------------------------------
pbm_phys_wait_restore() {
  local pod="${1:?}" container="${2:?}" name="${3:?}" timeout="${4:-2400}"
  local cred_row access secret cfg_yaml
  cred_row=$(pbm_read_s3_credentials "$DB_NAMESPACE")
  IFS=$'\x1f' read -r access secret <<< "$cred_row"
  cfg_yaml=$(pbm_render_storage_config "$access" "$secret")

  local start now out desc status last_status=""
  start=$(date +%s)
  while true; do
    out=$(_kubectl exec -i "$pod" -c "$container" -- sh -c \
      'cat > /tmp/.pbm-restore-cfg.yaml && exec '"${_PBM_PHYS_BIN_DIR}"'/pbm describe-restore "$1" -c /tmp/.pbm-restore-cfg.yaml -o json' \
      sh "$name" <<< "$cfg_yaml" 2>&1) || true
    if desc=$(printf '%s' "$out" | jq -c . 2>/dev/null); then
      status=$(printf '%s' "$desc" | jq -r '.status // empty' 2>/dev/null)
      if [[ "$status" != "$last_status" ]]; then
        log_debug "mongo-pbm-phys" "physical restore ${name} status: ${last_status:-<none>} -> ${status:-<unknown>}"
        last_status="$status"
      fi
      case "$status" in
        done)
          log_info "mongo-pbm-phys" "physical restore ${name} completed"
          printf '%s' "$desc"
          return 0
          ;;
        error | failed)
          log_error "mongo-pbm-phys" "physical restore ${name} ended with status=${status}: $(printf '%s' "$desc" | jq -r '.error // "unknown error"' 2>/dev/null)"
          printf '%s' "$desc"
          return 1
          ;;
      esac
    else
      log_debug "mongo-pbm-phys" "describe-restore ${name} not readable yet: ${out:0:200}"
    fi
    now=$(date +%s)
    if (( now - start >= timeout )); then
      log_error "mongo-pbm-phys" "physical restore ${name} still not finished after ${timeout}s"
      printf '%s' "${desc:-}"
      return 124
    fi
    sleep "$_PBM_POLL_INTERVAL"
  done
}
