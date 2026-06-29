#!/usr/bin/env bats
# =============================================================================
# E2E proof of the G1 self-heal mechanism (see CLAUDE.md "Auto-detect tier"
# and lib/mongodb-recovery.sh's _recovery_auto_patch_init_container /
# _recovery_revert_auto_patch): when the data-recovery init container is
# missing, recovery/wipe and recovery/recover (gate mode) patch it in live —
# detecting the real volume/mount-path/runAsUser from the StatefulSet and
# live mongod instead of requiring an operator to run setup-data-recovery.sh
# first — without restarting any pod other than the one actually being wiped,
# and recovery/reset (called standalone, or internally by recovery/recover)
# reverts the StatefulSet to its original shape afterwards.
#
# recovery/pre-check must stay read-only even when G1 is failing — it never
# self-heals (only gate mode does); this file proves that too.
#
# Self-contained: setup_file creates the mongo-autopatch namespace and all
# its resources, deliberately WITHOUT ever calling setup-data-recovery.sh
# (the whole point is that the init container starts out missing). Reuses
# default object names ("mongodb"/"mongodb-credentials"/
# "mongodb-recovery-config") so the existing aqsh-mongo-manager ClusterRole's
# resourceNames already cover it — only a namespace-scoped RoleBinding is
# needed, same technique as recovery_bitnami_profile.bats /
# recovery_autodetect.bats. teardown_file deletes the namespace. No other
# test file reads or writes mongo-autopatch.
# =============================================================================

setup_file() {
  load '../test_helper/bats-support/load'
  load '../test_helper/bats-assert/load'

  CTX_A="kind-cluster-a"
  CTX_B="kind-cluster-b"
  NS="mongo-core"
  ANS="mongo-autopatch"
  AQSH_URL="http://aqsh-mongodb.kind-a.test:30080"

  kubectl --context "$CTX_B" -n "$NS" wait pod \
    -l app=test-client --for=condition=Ready --timeout=120s
  TEST_POD=$(kubectl --context "$CTX_B" -n "$NS" \
    get pod -l app=test-client -o jsonpath='{.items[0].metadata.name}')
  [[ -n "$TEST_POD" ]] || { echo "test-client pod not found in $NS" >&2; return 1; }

  TOKEN=$(kubectl --context "$CTX_B" -n "$NS" create token test-client --duration=1h)

  export CTX_A CTX_B NS ANS AQSH_URL TEST_POD TOKEN

  local ctx="$CTX_A"

  kubectl --context "$ctx" create namespace "$ANS" \
    --dry-run=client -o yaml | kubectl --context "$ctx" apply -f -

  # Default object name/keys — the existing ClusterRole's resourceNames
  # already cover it; only a namespace-scoped RoleBinding is needed.
  kubectl --context "$ctx" -n "$ANS" create secret generic mongodb-credentials \
    --from-literal=MONGO_ROOT_USER=mongoadmin --from-literal=MONGO_ROOT_PASS=testpass123 \
    --dry-run=client -o yaml | kubectl --context "$ctx" apply -f -

  kubectl --context "$ctx" -n "$ANS" apply -f - <<'RB_EOF'
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: aqsh-mongo-manager
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: aqsh-mongo-manager
subjects:
  - kind: ServiceAccount
    name: kube-auth-proxy
    namespace: mongo-core
RB_EOF

  # Standard mongo:N layout (volume "data" at /data/db) — deliberately NO
  # initContainers and NO setup-data-recovery.sh call: G1 must start out
  # failing so the self-heal path is the only way recovery/wipe can proceed.
  kubectl --context "$ctx" -n "$ANS" apply -f - <<STS_EOF
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: mongodb
  namespace: ${ANS}
spec:
  replicas: 3
  selector:
    matchLabels:
      app: mongodb
  serviceName: mongodb
  template:
    metadata:
      labels:
        app: mongodb
        app.kubernetes.io/name: mongodb
    spec:
      securityContext:
        runAsNonRoot: true
        runAsUser: 999
        runAsGroup: 999
        fsGroup: 999
      containers:
        - name: mongodb
          image: mongo:7
          command: ["mongod"]
          args: ["--replSet", "rs0", "--bind_ip_all"]
          env:
            - name: MONGO_INITDB_ROOT_USERNAME
              valueFrom:
                secretKeyRef:
                  name: mongodb-credentials
                  key: MONGO_ROOT_USER
            - name: MONGO_INITDB_ROOT_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: mongodb-credentials
                  key: MONGO_ROOT_PASS
          ports:
            - containerPort: 27017
          securityContext:
            allowPrivilegeEscalation: false
            privileged: false
            capabilities:
              drop: ["ALL"]
            seccompProfile:
              type: RuntimeDefault
            readOnlyRootFilesystem: false
          readinessProbe:
            exec:
              command: ["mongosh", "--quiet", "--norc", "--eval", "db.adminCommand('ping').ok"]
            initialDelaySeconds: 10
            periodSeconds: 10
            timeoutSeconds: 5
            failureThreshold: 6
          volumeMounts:
            - name: data
              mountPath: /data/db
  volumeClaimTemplates:
    - metadata:
        name: data
      spec:
        accessModes: ["ReadWriteOnce"]
        resources:
          requests:
            storage: 1Gi
---
apiVersion: v1
kind: Service
metadata:
  name: mongodb
  namespace: ${ANS}
spec:
  clusterIP: None
  selector:
    app: mongodb
  ports:
    - port: 27017
      targetPort: 27017
STS_EOF

  echo "Waiting for 3-replica auto-patch RS rollout in ${ANS}..."
  kubectl --context "$ctx" -n "$ANS" rollout status statefulset/mongodb --timeout=300s

  # 3 members (not 2): the suite below repeatedly wipes/recovers the same
  # pod in quick succession (see "recovery/recover ... in a single call"
  # below); a 2-member RS has no quorum tolerance — any single member's
  # transient unavailability during its own resync can cost the set its
  # PRIMARY entirely. 3 members keeps a majority (2 of 3) available
  # throughout, matching recovery.bats's own reason for using 3 members.
  _init_rs "$ANS" "$ctx" 3
  _wait_for_primary "$ANS" "$ctx" 180

  local mongo_user mongo_pass
  mongo_user=$(kubectl --context "$ctx" -n "$ANS" get secret mongodb-credentials \
    -o jsonpath='{.data.MONGO_ROOT_USER}' | base64 -d)
  mongo_pass=$(kubectl --context "$ctx" -n "$ANS" get secret mongodb-credentials \
    -o jsonpath='{.data.MONGO_ROOT_PASS}' | base64 -d)
  local user_elapsed=0 user_ready=false
  while (( user_elapsed < 60 )); do
    if kubectl --context "$ctx" -n "$ANS" exec mongodb-0 -- mongosh --quiet --norc \
      "mongodb://localhost:27017/admin" --eval "
        try {
          db.getSiblingDB('admin').createUser({user:'${mongo_user}', pwd:'${mongo_pass}', roles:[{role:'root',db:'admin'}]});
          print('root user created');
        } catch(e) {
          if (/already exists/.test(e.message)) { print('root user exists'); }
          else { throw e; }
        }" >/dev/null 2>&1; then
      user_ready=true
      break
    fi
    sleep 5; user_elapsed=$((user_elapsed + 5))
  done
  if [[ "$user_ready" != true ]]; then
    echo "Failed to create/verify root user in ${ANS} after 60s" >&2
    return 1
  fi

  # Only the ConfigMap — NOT setup-data-recovery.sh — so G2 passes but G1
  # (init container) stays failing. This is the exact "almost set up"
  # precondition the self-heal mechanism targets.
  kubectl --context "$ctx" -n "$ANS" apply -f - <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: mongodb-recovery-config
  namespace: ${ANS}
data:
  wipe-targets: ""
  recovery-version: "0"
EOF
}

teardown_file() {
  local ctx="kind-cluster-a"
  kubectl --context "$ctx" delete namespace "mongo-autopatch" --ignore-not-found 2>/dev/null || true
}

setup() {
  load '../test_helper/bats-support/load'
  load '../test_helper/bats-assert/load'
}

# ---------------------------------------------------------------------------
# Helpers — same pattern as recovery_autodetect.bats / recovery_bitnami_profile.bats
# ---------------------------------------------------------------------------

kexec() {
  kubectl --context "$CTX_B" -n "$NS" exec "$TEST_POD" -- sh -c "$1"
}

http_post() {
  local url="$1" body="$2"
  local response
  response=$(kexec "curl -s --connect-timeout 5 -m 30 -w '\\n%{http_code}' \
    -X POST '${url}' \
    -H 'Authorization: Bearer ${TOKEN}' \
    -H 'Content-Type: application/json' \
    -d '${body}'")

  HTTP_CODE=$(echo "$response" | tail -1)
  HTTP_BODY=$(echo "$response" | sed '$d')
  export HTTP_CODE HTTP_BODY
}

wait_for_task() {
  local base_url="$1" task_id="$2" max_wait="${3:-300}"
  local elapsed=0 status

  while (( elapsed < max_wait )); do
    TASK_RESPONSE=$(kexec "curl -s --connect-timeout 5 -m 10 \
      -H 'Authorization: Bearer ${TOKEN}' \
      '${base_url}/executions/${task_id}'")
    export TASK_RESPONSE

    status=$(echo "$TASK_RESPONSE" | jq -r '.status // empty' 2>/dev/null || true)
    [[ "$status" == "completed" ]] && return 0
    [[ "$status" == "failed" ]] && { echo "Task ${task_id} failed: ${TASK_RESPONSE}" >&2; return 1; }
    [[ -z "$status" && -n "$TASK_RESPONSE" ]] && { echo "Task ${task_id} invalid response: ${TASK_RESPONSE}" >&2; return 1; }

    sleep 5
    elapsed=$((elapsed + 5))
  done

  echo "Task ${task_id} timed out after ${max_wait}s (status: ${status})" >&2
  return 1
}

_init_rs() {
  local namespace="$1" ctx="${2:-$CTX_A}" replicas="${3:-2}"
  echo "Initializing MongoDB replica set rs0 in ${namespace} (${replicas} members)..."
  kubectl --context "$ctx" -n "$namespace" wait pod mongodb-0 \
    --for=condition=Ready --timeout=120s || {
    echo "mongodb-0 not ready after 120s" >&2; return 1
  }
  # mongodb-0 gets priority=2 so it deterministically wins primary (same
  # technique as recovery.bats's _init_mongodb_rs) — this lets the suite
  # always target the highest ordinal (mongodb-2) for wipe/recover, which is
  # the only ordinal StatefulSet partition semantics can restart in
  # isolation; see docs/mongodb/recovery.md "Quorum warning for
  # lower-ordinal targets" for why a non-highest ordinal target can sweep up
  # every higher-ordinal pod too when none of them has individually rolled
  # onto the just-self-healed template yet.
  local members="" i prio
  for i in $(seq 0 $((replicas - 1))); do
    prio=1; [[ "$i" -eq 0 ]] && prio=2
    members+="{_id:${i},host:'mongodb-${i}.mongodb.${namespace}.svc.cluster.local:27017',priority:${prio}},"
  done
  members="${members%,}"
  kubectl --context "$ctx" -n "$namespace" exec mongodb-0 -- mongosh --quiet --norc \
    "mongodb://localhost:27017/admin" \
    --eval "
      try {
        var r = rs.initiate({_id: 'rs0', members: [${members}]});
        print('RS initiate: ' + JSON.stringify(r));
      } catch(e) {
        if (e.codeName === 'AlreadyInitialized') { print('RS already initialized'); }
        else { print('RS init error: ' + e.message); quit(1); }
      }
    " || { echo "RS initiate failed" >&2; return 1; }
  echo "RS initiated — allowing time for primary election..."
  sleep 8
}

_wait_for_primary() {
  local namespace="$1" ctx="${2:-$CTX_A}" max_wait="${3:-120}"
  local elapsed=0
  while (( elapsed < max_wait )); do
    local pod
    pod=$(kubectl --context "$ctx" -n "$namespace" get pod -l app=mongodb \
      -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
    if [[ -n "$pod" ]]; then
      local rs_check='try {
        var s = rs.status();
        var p = s.members && s.members.find(function(m){ return m.state===1 && m.health===1; });
        if (p) { quit(0); }
      } catch(e) {}
      var h = db.hello();
      if (h && (h.isWritablePrimary || h.ismaster)) { quit(0); }
      quit(1);'
      if kubectl --context "$ctx" -n "$namespace" exec "$pod" -- mongosh --quiet --norc \
        "mongodb://localhost:27017/admin?serverSelectionTimeoutMS=2000" \
        --eval "$rs_check" >/dev/null 2>&1; then
        return 0
      fi
      local user pass
      { IFS= read -r user; IFS= read -r pass; } < <(_mongo_creds "$namespace" "$ctx")
      if [[ -n "$user" && -n "$pass" ]]; then
        if kubectl --context "$ctx" -n "$namespace" exec "$pod" -- mongosh --quiet --norc \
          "mongodb://${user}:${pass}@localhost:27017/admin?authSource=admin&serverSelectionTimeoutMS=2000" \
          --eval "$rs_check" >/dev/null 2>&1; then
          return 0
        fi
      fi
    fi
    sleep 3; elapsed=$((elapsed + 3))
  done
  echo "MongoDB primary not ready in namespace ${namespace} after ${max_wait}s" >&2
  return 1
}

# ---------------------------------------------------------------------------
# _mongo_creds <namespace> [context]
# Echo "user\npass" for the mongodb-credentials secret.
# ---------------------------------------------------------------------------
_mongo_creds() {
  local namespace="$1" ctx="${2:-$CTX_A}"
  local user pass
  user=$(kubectl --context "$ctx" -n "$namespace" get secret mongodb-credentials \
    -o jsonpath='{.data.MONGO_ROOT_USER}' | base64 -d)
  pass=$(kubectl --context "$ctx" -n "$namespace" get secret mongodb-credentials \
    -o jsonpath='{.data.MONGO_ROOT_PASS}' | base64 -d)
  printf '%s\n%s\n' "$user" "$pass"
}

_find_primary_pod() {
  local namespace="$1" ctx="${2:-$CTX_A}"
  local user pass
  { IFS= read -r user; IFS= read -r pass; } < <(_mongo_creds "$namespace" "$ctx")
  local pod
  for pod in mongodb-0 mongodb-1 mongodb-2; do
    local is_primary
    is_primary=$(kubectl --context "$ctx" -n "$namespace" exec "$pod" -- mongosh --quiet --norc \
      "mongodb://${user}:${pass}@localhost:27017/admin?authSource=admin&serverSelectionTimeoutMS=3000" \
      --eval "try{var h=db.hello();print((h.isWritablePrimary||h.ismaster)?'1':'0');}catch(e){print('0');}" \
      2>/dev/null | tail -1 | tr -d '\r') || is_primary="0"
    [[ "$is_primary" == "1" ]] && { echo "$pod"; return 0; }
  done
  return 1
}

# ---------------------------------------------------------------------------
# _wipe_target <namespace> [context]
# Echo a non-primary pod name, preferring the HIGHEST ordinal — the only
# ordinal StatefulSet partition semantics can restart without also sweeping
# up every higher-ordinal pod (see _init_rs's comment and docs/mongodb/
# recovery.md "Quorum warning for lower-ordinal targets"). mongodb-0 has
# priority=2 (set in _init_rs) so it's deterministically primary, making
# mongodb-2 the deterministic answer here too.
# ---------------------------------------------------------------------------
_wipe_target() {
  local namespace="$1" ctx="${2:-$CTX_A}"
  local primary_pod
  primary_pod=$(_find_primary_pod "$namespace" "$ctx") || true
  local p
  for p in mongodb-2 mongodb-1 mongodb-0; do
    [[ "$p" != "$primary_pod" ]] && { echo "$p"; return 0; }
  done
  return 1
}

# ---------------------------------------------------------------------------
# _other_pods <target_pod>
# Echo every mongodb-N pod name except target_pod, one per line — the set
# of pods that must NEVER restart while target_pod is being self-healed/
# wiped/reset (see CLAUDE.md "不重啟其他pod狀態").
# ---------------------------------------------------------------------------
_other_pods() {
  local target_pod="$1" p
  for p in mongodb-0 mongodb-1 mongodb-2; do
    [[ "$p" != "$target_pod" ]] && echo "$p"
  done
}

# ---------------------------------------------------------------------------
# _capture_uids <namespace> <pod...>
# Echo "<pod> <uid>" one per line for each given pod.
# ---------------------------------------------------------------------------
_capture_uids() {
  local namespace="$1"; shift
  local p
  for p in "$@"; do
    printf '%s %s\n' "$p" "$(kubectl --context "$CTX_A" -n "$namespace" get pod "$p" -o jsonpath='{.metadata.uid}')"
  done
}

# ---------------------------------------------------------------------------
# _assert_uids_unchanged <namespace> <captured_uids>
# <captured_uids> is _capture_uids's output. Fails if any of those pods'
# current UID differs from what was captured.
# ---------------------------------------------------------------------------
_assert_uids_unchanged() {
  local namespace="$1" captured="$2"
  local line pod before after
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    pod="${line%% *}"; before="${line#* }"
    after=$(kubectl --context "$CTX_A" -n "$namespace" get pod "$pod" -o jsonpath='{.metadata.uid}')
    if [[ "$after" != "$before" ]]; then
      echo "pod ${pod} restarted unexpectedly: uid ${before} -> ${after}" >&2
      return 1
    fi
  done <<< "$captured"
  return 0
}

_wait_for_rs_healthy() {
  local namespace="$1" target_pod="$2" ctx="${3:-$CTX_A}" max_wait="${4:-180}"
  local user pass
  { IFS= read -r user; IFS= read -r pass; } < <(_mongo_creds "$namespace" "$ctx")
  local probe_pod p
  for p in mongodb-0 mongodb-1 mongodb-2; do
    [[ "$p" != "$target_pod" ]] && { probe_pod="$p"; break; }
  done
  local elapsed=0 state=""
  while (( elapsed < max_wait )); do
    state=$(kubectl --context "$ctx" -n "$namespace" exec "$probe_pod" -- mongosh --quiet --norc \
      "mongodb://${user}:${pass}@localhost:27017/admin?authSource=admin&serverSelectionTimeoutMS=5000" \
      --eval "try{var m=rs.status().members.filter(function(x){return x.name.indexOf('${target_pod}')!==-1;})[0];print(m?m.stateStr+','+m.health:'NONE,0');}catch(e){print('ERR,0');}" \
      2>/dev/null | tail -1 | tr -d '\r') || state="ERR,0"
    [[ "$state" == "SECONDARY,1" || "$state" == "PRIMARY,1" ]] && return 0
    sleep 5; elapsed=$((elapsed + 5))
  done
  echo "${target_pod} did not become healthy within ${max_wait}s (last: ${state})" >&2
  return 1
}

# ---------------------------------------------------------------------------
# _sts_has_init_container <namespace> [context]
# ---------------------------------------------------------------------------
_sts_has_init_container() {
  local namespace="$1" ctx="${2:-$CTX_A}"
  kubectl --context "$ctx" -n "$namespace" get statefulset mongodb \
    -o jsonpath='{.spec.template.spec.initContainers[*].name}' 2>/dev/null | tr ' ' '\n' | grep -qx data-recovery
}

_sts_auto_patched_annotation() {
  local namespace="$1" ctx="${2:-$CTX_A}"
  kubectl --context "$ctx" -n "$namespace" get statefulset mongodb \
    -o jsonpath='{.metadata.annotations.recovery/auto-patched}' 2>/dev/null || true
}

# ── G1 starts out failing ─────────────────────────────────────────────────

@test "STS starts with no data-recovery init container (G1 precondition)" {
  run _sts_has_init_container "$ANS" "$CTX_A"
  [ "$status" -ne 0 ]
}

# ── recovery/pre-check stays read-only ────────────────────────────────────

@test "recovery/pre-check reports INIT_CONTAINER_MISSING and never mutates the StatefulSet" {
  local before_rv
  before_rv=$(kubectl --context "$CTX_A" -n "$ANS" \
    get statefulset mongodb -o jsonpath='{.metadata.resourceVersion}')

  local target
  target=$(_wipe_target "$ANS" "$CTX_A")

  http_post "${AQSH_URL}/tasks/recovery%2Fpre-check" \
    "{\"namespace\":\"${ANS}\",\"target_pod\":\"${target}\"}"
  assert_equal "$HTTP_CODE" "202"

  local task_id
  task_id=$(echo "$HTTP_BODY" | jq -r '.id')
  wait_for_task "$AQSH_URL" "$task_id" 120

  local result g1_pass g1_code
  result=$(echo "$TASK_RESPONSE" | jq -r '.result.data // empty')
  g1_pass=$(echo "$result" | jq -r '.gates[] | select(.gate=="G1") | .pass' 2>/dev/null || echo "null")
  g1_code=$(echo "$result" | jq -r '.gates[] | select(.gate=="G1") | .code' 2>/dev/null || echo "null")
  assert_equal "$g1_pass" "false"
  assert_equal "$g1_code" "INIT_CONTAINER_MISSING"

  local after_rv
  after_rv=$(kubectl --context "$CTX_A" -n "$ANS" \
    get statefulset mongodb -o jsonpath='{.metadata.resourceVersion}')
  assert_equal "$after_rv" "$before_rv"

  run _sts_has_init_container "$ANS" "$CTX_A"
  [ "$status" -ne 0 ]
}

# ── recovery/wipe self-heals G1, wipes the target, leaves the other pod alone ─

@test "recovery/wipe self-heals the missing init container without restarting the other pods" {
  local target others_uids
  target=$(_wipe_target "$ANS" "$CTX_A")
  others_uids=$(_capture_uids "$ANS" $(_other_pods "$target"))
  echo "target=${target} others=$(_other_pods "$target" | tr '\n' ' ')" >&2

  local target_uid_before
  target_uid_before=$(kubectl --context "$CTX_A" -n "$ANS" get pod "$target" -o jsonpath='{.metadata.uid}')

  http_post "${AQSH_URL}/tasks/recovery%2Fwipe" \
    "{\"namespace\":\"${ANS}\",\"target_pod\":\"${target}\"}"
  assert_equal "$HTTP_CODE" "202"

  local task_id
  task_id=$(echo "$HTTP_BODY" | jq -r '.id')
  wait_for_task "$AQSH_URL" "$task_id" 120

  local result auto_patched
  result=$(echo "$TASK_RESPONSE" | jq -r '.result.data // empty')
  auto_patched=$(echo "$result" | jq -r '.auto_patched // empty' 2>/dev/null || true)
  echo "wipe gates auto_patched=${auto_patched:-<none>}" >&2

  # The self-heal must have actually happened: STS now carries the init
  # container + the tracking annotation.
  run _sts_has_init_container "$ANS" "$CTX_A"
  [ "$status" -eq 0 ]
  local annotation
  annotation=$(_sts_auto_patched_annotation "$ANS" "$CTX_A")
  assert_equal "$annotation" "true"

  # The OTHER pods must not have been touched by the self-heal patch — the
  # partition lock in the same patch call is what CLAUDE.md's "不重啟其他
  # pod" requirement depends on.
  _assert_uids_unchanged "$ANS" "$others_uids"

  # Wait for the TARGET to actually restart and reach Running — this proves
  # the auto-detected volume/mountPath/runAsUser were correct against the
  # real cluster (a wrong runAsUser/mount would CrashLoop or
  # CreateContainerConfigError here instead of reaching Running).
  local elapsed=0 target_uid_after=""
  while (( elapsed < 180 )); do
    target_uid_after=$(kubectl --context "$CTX_A" -n "$ANS" get pod "$target" -o jsonpath='{.metadata.uid}' 2>/dev/null || true)
    [[ -n "$target_uid_after" && "$target_uid_after" != "$target_uid_before" ]] && break
    sleep 5; elapsed=$((elapsed + 5))
  done
  [ -n "$target_uid_after" ]
  [ "$target_uid_after" != "$target_uid_before" ]

  elapsed=0
  until kubectl --context "$CTX_A" -n "$ANS" get pod "$target" -o jsonpath='{.status.phase}' 2>/dev/null | grep -q Running; do
    [[ $elapsed -ge 180 ]] && { echo "Target did not reach Running within 180s" >&2; break; }
    sleep 5; elapsed=$((elapsed + 5))
  done
  local target_phase
  target_phase=$(kubectl --context "$CTX_A" -n "$ANS" get pod "$target" -o jsonpath='{.status.phase}')
  assert_equal "$target_phase" "Running"

  # Still must not have touched the other pods even after the target's full restart.
  _assert_uids_unchanged "$ANS" "$others_uids"

  # wipe does not auto-reset — wipe-targets is still set.
  local wipe_targets
  wipe_targets=$(kubectl --context "$CTX_A" -n "$ANS" \
    get configmap mongodb-recovery-config -o jsonpath='{.data.wipe-targets}')
  assert_equal "$wipe_targets" "$target"
}

@test "recovery/reset reverts the self-heal patch back to the StatefulSet's original shape" {
  local target others_uids
  target=$(kubectl --context "$CTX_A" -n "$ANS" \
    get configmap mongodb-recovery-config -o jsonpath='{.data.wipe-targets}')
  [ -n "$target" ] || skip "no active wipe-target left by the previous test"
  others_uids=$(_capture_uids "$ANS" $(_other_pods "$target"))

  http_post "${AQSH_URL}/tasks/recovery%2Freset" "{\"namespace\":\"${ANS}\"}"
  assert_equal "$HTTP_CODE" "202"

  local task_id
  task_id=$(echo "$HTTP_BODY" | jq -r '.id')
  wait_for_task "$AQSH_URL" "$task_id"

  local result auto_patch_reverted
  result=$(echo "$TASK_RESPONSE" | jq -r '.result.data // empty')
  auto_patch_reverted=$(echo "$result" | jq -r '.auto_patch_reverted // empty')
  assert_equal "$auto_patch_reverted" "true"

  # StatefulSet is back to its original shape: no init container, no
  # tracking annotation.
  run _sts_has_init_container "$ANS" "$CTX_A"
  [ "$status" -ne 0 ]
  local annotation
  annotation=$(_sts_auto_patched_annotation "$ANS" "$CTX_A")
  [ -z "$annotation" ]

  # Reverting must not restart the other pods either.
  _assert_uids_unchanged "$ANS" "$others_uids"

  # wipe-targets cleared
  local wipe_targets
  wipe_targets=$(kubectl --context "$CTX_A" -n "$ANS" \
    get configmap mongodb-recovery-config -o jsonpath='{.data.wipe-targets}')
  assert_equal "$wipe_targets" ""

  _wait_for_rs_healthy "$ANS" "$target" "$CTX_A" 180
}

# ── recovery/recover: the one-call orchestrator self-heals AND self-cleans ──

@test "recovery/recover self-heals, wipes, and auto-reverts in a single call, leaving the other pods untouched" {
  run _sts_has_init_container "$ANS" "$CTX_A"
  [ "$status" -ne 0 ] || skip "StatefulSet unexpectedly still carries the init container before this test"

  # The previous two tests just wiped+resynced a member; make sure the RS
  # fully settled (primary re-elected, target healthy) before subjecting it
  # to another full recovery cycle — otherwise this test would be pressure-
  # testing RS quorum timing, not the self-heal/revert mechanism.
  _wait_for_primary "$ANS" "$CTX_A" 120

  local target others_uids
  target=$(_wipe_target "$ANS" "$CTX_A")
  _wait_for_rs_healthy "$ANS" "$target" "$CTX_A" 120
  others_uids=$(_capture_uids "$ANS" $(_other_pods "$target"))
  echo "target=${target} others=$(_other_pods "$target" | tr '\n' ' ')" >&2

  local target_uid_before
  target_uid_before=$(kubectl --context "$CTX_A" -n "$ANS" get pod "$target" -o jsonpath='{.metadata.uid}')

  http_post "${AQSH_URL}/tasks/recovery%2Frecover" \
    "{\"namespace\":\"${ANS}\",\"target_pod\":\"${target}\",\"wait_timeout\":\"300\"}"
  assert_equal "$HTTP_CODE" "202"

  local task_id
  task_id=$(echo "$HTTP_BODY" | jq -r '.id')
  wait_for_task "$AQSH_URL" "$task_id" 480

  local result reached
  result=$(echo "$TASK_RESPONSE" | jq -r '.result.data // empty')
  reached=$(echo "$result" | jq -r '.reached_running // empty')
  assert_equal "$reached" "true"

  local target_uid_after
  target_uid_after=$(kubectl --context "$CTX_A" -n "$ANS" get pod "$target" -o jsonpath='{.metadata.uid}')
  [ "$target_uid_after" != "$target_uid_before" ]

  # The other pods were never touched across the whole self-heal -> wipe ->
  # wait -> reset/revert cycle.
  _assert_uids_unchanged "$ANS" "$others_uids"

  # recover's internal reset step already reverted the self-heal patch —
  # the StatefulSet must be back to having no init container/annotation.
  run _sts_has_init_container "$ANS" "$CTX_A"
  [ "$status" -ne 0 ]
  local annotation
  annotation=$(_sts_auto_patched_annotation "$ANS" "$CTX_A")
  [ -z "$annotation" ]

  local wipe_targets
  wipe_targets=$(kubectl --context "$CTX_A" -n "$ANS" \
    get configmap mongodb-recovery-config -o jsonpath='{.data.wipe-targets}')
  assert_equal "$wipe_targets" ""

  kubectl --context "$CTX_A" -n "$ANS" \
    wait pod "$target" --for=condition=Ready --timeout=180s >/dev/null 2>&1 || true
  _wait_for_rs_healthy "$ANS" "$target" "$CTX_A" 180
}

# ── Not-Ready target: STS rolling-update controller deadlock bypass ───────────
#
# When the target pod is not Ready the StatefulSet rolling-update controller
# (OrderedReady policy) will NOT evict it — it waits for a healthy pod before
# applying the new template, creating a deadlock where the pod can't become
# healthy without the recovery init container, and the init container can't
# run without the pod being evicted.  recovery_wipe_pod detects Ready=False
# and force-deletes the pod directly so the STS controller recreates it with
# the updated template.

@test "recovery/recover force-deletes a not-Ready target pod instead of deadlocking on rolling-update" {
  run _sts_has_init_container "$ANS" "$CTX_A"
  [ "$status" -ne 0 ] || skip "StatefulSet unexpectedly still carries the init container before this test"

  _wait_for_primary "$ANS" "$CTX_A" 120

  local target others_uids
  target=$(_wipe_target "$ANS" "$CTX_A")
  _wait_for_rs_healthy "$ANS" "$target" "$CTX_A" 120
  others_uids=$(_capture_uids "$ANS" $(_other_pods "$target"))

  local target_uid_before
  target_uid_before=$(kubectl --context "$CTX_A" -n "$ANS" \
    get pod "$target" -o jsonpath='{.metadata.uid}')
  echo "target=${target} uid_before=${target_uid_before}" >&2

  # Break the target pod so it is not Ready: kill mongod and corrupt the
  # WiredTiger metadata files so every restart attempt fails → CrashLoopBackOff.
  # This simulates the real-world scenario: a pod that is Running but whose
  # readiness probe fails (or is crashing), causing the STS controller deadlock
  # described in the test block comment above.
  kubectl --context "$CTX_A" -n "$ANS" exec "$target" -- \
    bash -c "kill -9 \$(pidof mongod 2>/dev/null) 2>/dev/null; \
             printf 'CORRUPTED' > /data/db/WiredTiger.wt; \
             printf 'CORRUPTED' > /data/db/WiredTiger" 2>/dev/null || true

  # Wait up to 90s for the pod to report Ready=False
  local elapsed=0 pod_ready
  while (( elapsed < 90 )); do
    pod_ready=$(kubectl --context "$CTX_A" -n "$ANS" get pod "$target" \
      -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)
    [[ "$pod_ready" != "True" ]] && break
    sleep 3; elapsed=$((elapsed + 3))
  done
  assert_equal "$pod_ready" "False"
  echo "Confirmed ${target} is not-Ready before calling recovery/recover" >&2

  http_post "${AQSH_URL}/tasks/recovery%2Frecover" \
    "{\"namespace\":\"${ANS}\",\"target_pod\":\"${target}\",\"wait_timeout\":\"300\"}"
  assert_equal "$HTTP_CODE" "202"

  local task_id
  task_id=$(echo "$HTTP_BODY" | jq -r '.id')
  wait_for_task "$AQSH_URL" "$task_id" 480

  local result reached auto_patched
  result=$(echo "$TASK_RESPONSE" | jq -r '.result.data // empty')
  reached=$(echo "$result" | jq -r '.reached_running // empty')
  auto_patched=$(echo "$result" | jq -r '.auto_patched // empty')
  assert_equal "$reached" "true"
  assert_equal "$auto_patched" "true"

  local target_uid_after
  target_uid_after=$(kubectl --context "$CTX_A" -n "$ANS" \
    get pod "$target" -o jsonpath='{.metadata.uid}')
  [ "$target_uid_after" != "$target_uid_before" ]

  # Other pods must not have been restarted across the whole cycle.
  _assert_uids_unchanged "$ANS" "$others_uids"

  # recover's internal reset must have reverted the self-heal patch.
  run _sts_has_init_container "$ANS" "$CTX_A"
  [ "$status" -ne 0 ]
  local annotation
  annotation=$(_sts_auto_patched_annotation "$ANS" "$CTX_A")
  [ -z "$annotation" ]

  local wipe_targets
  wipe_targets=$(kubectl --context "$CTX_A" -n "$ANS" \
    get configmap mongodb-recovery-config -o jsonpath='{.data.wipe-targets}')
  assert_equal "$wipe_targets" ""

  kubectl --context "$CTX_A" -n "$ANS" \
    wait pod "$target" --for=condition=Ready --timeout=180s >/dev/null 2>&1 || true
  _wait_for_rs_healthy "$ANS" "$target" "$CTX_A" 180
}
