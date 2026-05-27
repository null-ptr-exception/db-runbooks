#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# mongodb/rs-init.sh
# aqsh task: Initialize (or verify) a MongoDB Replica Set across clusters.
#
# Inputs (injected by aqsh from tasks.yaml):
#   DB_NAMESPACE    — target namespace, e.g. "mongo-1"
#   RS_TOPOLOGY     — "2+1" | "1+2" | "3+0" (A+B: pods on cluster-a + cluster-b)
#   CLUSTER_A_IP    — Node IP of cluster-dbs-a (or cluster-dbs for 3+0)
#   CLUSTER_B_IP    — Node IP of cluster-dbs-b (required for 2+1 / 1+2)
#
# NodePort layout (must match k8s/cluster-dbs/mongodb/nodeport-pod*.yaml):
#   pod-0: 30090   pod-1: 30094   pod-2: 30096
#
# Idempotent: if the RS is already configured with the expected topology,
# the task succeeds without re-initialising.
#
# Writes JSON result to $AQSH_RESULT_FILE:
#   {topology, rs_name, members_count, primary, members: [...]}
# =============================================================================

LIB_DIR="/tasks/lib"
source "${LIB_DIR}/logging.sh"
source "${LIB_DIR}/response.sh"
source "${LIB_DIR}/k8s.sh"
source "${LIB_DIR}/mongodb.sh"

RS_NAME="rs0"
CRED_SECRET="${MONGO_CRED_SECRET:-mongodb-credentials}"
CRED_USER_KEY="${MONGO_CRED_USER_KEY:-MONGO_ROOT_USER}"
CRED_PASS_KEY="${MONGO_CRED_PASS_KEY:-MONGO_ROOT_PASS}"

log_info "rs-init" "Starting RS init for namespace=${DB_NAMESPACE} topology=${RS_TOPOLOGY}"

# ── Preflight failure helper ──────────────────────────────────────────────────
_preflight_critical() {
  local reason="${1:-preflight failed}"
  log_error "rs-init" "Preflight failed: ${reason}"
  jq -n \
    --arg status    "critical" \
    --arg reason    "${reason}" \
    --arg namespace "${DB_NAMESPACE}" \
    '{status: $status, namespace: $namespace, reason: $reason}' \
    > "$AQSH_RESULT_FILE"
  exit 1
}

# ── Read credentials ──────────────────────────────────────────────────────────
export K8S_NAMESPACE="${DB_NAMESPACE}"

MONGO_USER=$(kubectl -n "${DB_NAMESPACE}" get secret "${CRED_SECRET}" \
  -o jsonpath="{.data.${CRED_USER_KEY}}" 2>/dev/null | base64 -d) || \
  _preflight_critical "cannot read '${CRED_USER_KEY}' from secret '${CRED_SECRET}'"

MONGO_PASS=$(kubectl -n "${DB_NAMESPACE}" get secret "${CRED_SECRET}" \
  -o jsonpath="{.data.${CRED_PASS_KEY}}" 2>/dev/null | base64 -d) || \
  _preflight_critical "cannot read '${CRED_PASS_KEY}' from secret '${CRED_SECRET}'"

export MONGO_HOST="mongodb-0.mongodb.${DB_NAMESPACE}.svc.cluster.local"
export MONGO_PORT="27017"
export MONGO_USER MONGO_PASS
export MONGO_AUTHDB="admin"
export MONGO_TIMEOUT="15000"

# ── Validate topology and build member list ───────────────────────────────────
# Members format: "host:port:priority" space-separated
# pod-0 on cluster-a always gets priority=2 (preferred primary)
declare -a RS_MEMBERS=()

case "${RS_TOPOLOGY}" in
  2+1)
    [[ -z "${CLUSTER_A_IP:-}" ]] && _preflight_critical "CLUSTER_A_IP required for topology ${RS_TOPOLOGY}"
    [[ -z "${CLUSTER_B_IP:-}" ]] && _preflight_critical "CLUSTER_B_IP required for topology ${RS_TOPOLOGY}"
    RS_MEMBERS=(
      "${CLUSTER_A_IP}:30090:2"
      "${CLUSTER_A_IP}:30094:1"
      "${CLUSTER_B_IP}:30090:1"
    )
    ;;
  1+2)
    [[ -z "${CLUSTER_A_IP:-}" ]] && _preflight_critical "CLUSTER_A_IP required for topology ${RS_TOPOLOGY}"
    [[ -z "${CLUSTER_B_IP:-}" ]] && _preflight_critical "CLUSTER_B_IP required for topology ${RS_TOPOLOGY}"
    RS_MEMBERS=(
      "${CLUSTER_A_IP}:30090:2"
      "${CLUSTER_B_IP}:30090:1"
      "${CLUSTER_B_IP}:30094:1"
    )
    ;;
  3+0)
    [[ -z "${CLUSTER_A_IP:-}" ]] && _preflight_critical "CLUSTER_A_IP required for topology ${RS_TOPOLOGY}"
    RS_MEMBERS=(
      "${CLUSTER_A_IP}:30090:2"
      "${CLUSTER_A_IP}:30094:1"
      "${CLUSTER_A_IP}:30096:1"
    )
    ;;
  *)
    _preflight_critical "Unknown RS_TOPOLOGY '${RS_TOPOLOGY}'; supported: 2+1, 1+2, 3+0"
    ;;
esac

MEMBER_COUNT="${#RS_MEMBERS[@]}"
log_info "rs-init" "Expected ${MEMBER_COUNT} RS members: ${RS_MEMBERS[*]}"

# ── Build JSON members array for rs.initiate() ───────────────────────────────
_build_members_js() {
  local js="["
  local i=0
  for entry in "${RS_MEMBERS[@]}"; do
    local host="${entry%%:*}"
    local rest="${entry#*:}"
    local port="${rest%%:*}"
    local priority="${rest##*:}"
    if (( i > 0 )); then js+=","; fi
    js+="{_id:${i},host:'${host}:${port}',priority:${priority}}"
    (( i++ )) || true
  done
  js+="]"
  printf '%s' "$js"
}

# ── Check if RS already initialized ──────────────────────────────────────────
log_info "rs-init" "Checking current RS status on ${MONGO_HOST}:${MONGO_PORT}..."

RS_STATUS_OK=$(_mongosh_eval "admin" \
  "try { var s=rs.status(); print(s.ok ? 'ok' : 'not-ok'); } catch(e) { print('not-initialized'); }" \
  2>/dev/null || echo "not-initialized")
RS_STATUS_OK="${RS_STATUS_OK// /}"

if [[ "$RS_STATUS_OK" == "ok" ]]; then
  log_info "rs-init" "RS '${RS_NAME}' already initialized — verifying member count"

  ACTUAL_MEMBER_COUNT=$(_mongosh_eval "admin" \
    "var s=rs.status(); print(s.members ? s.members.length : 0);" 2>/dev/null | tail -1 || echo "0")

  if [[ "$ACTUAL_MEMBER_COUNT" == "$MEMBER_COUNT" ]]; then
    log_info "rs-init" "RS is healthy with ${ACTUAL_MEMBER_COUNT} members — nothing to do"
  else
    log_info "rs-init" "RS has ${ACTUAL_MEMBER_COUNT} members but expected ${MEMBER_COUNT}; re-configuring..."
    MEMBERS_JS=$(_build_members_js)
    _mongosh_eval "admin" \
      "rs.reconfig({_id:'${RS_NAME}',members:${MEMBERS_JS}},{force:false})" >/dev/null 2>&1 || true
  fi
else
  # ── Initiate the Replica Set ────────────────────────────────────────────────
  log_info "rs-init" "RS not initialized — calling rs.initiate()"
  MEMBERS_JS=$(_build_members_js)

  _mongosh_eval "admin" \
    "rs.initiate({_id:'${RS_NAME}',members:${MEMBERS_JS}})" \
    > /dev/null || _preflight_critical "rs.initiate() failed — check that MongoDB pods are running and reachable via NodePorts"
fi

# ── Wait for primary election (up to 120s) ───────────────────────────────────
log_info "rs-init" "Waiting for primary election (up to 120s)..."
ELECTED=0
for _i in $(seq 1 24); do
  sleep 5
  PRIMARY_STATE=$(_mongosh_eval "admin" \
    "try { var m=rs.status().members; var p=m ? m.filter(x=>x.stateStr==='PRIMARY') : []; print(p.length > 0 ? p[0].name : 'none'); } catch(e) { print('none'); }" \
    2>/dev/null | tail -1 || echo "none")
  PRIMARY_STATE="${PRIMARY_STATE// /}"

  if [[ "$PRIMARY_STATE" != "none" && -n "$PRIMARY_STATE" ]]; then
    log_info "rs-init" "Primary elected: ${PRIMARY_STATE}"
    ELECTED=1
    break
  fi
  log_info "rs-init" "Waiting for primary... (${_i}/24)"
done

if (( ELECTED == 0 )); then
  _preflight_critical "Primary not elected after 120s — RS nodes may not be reachable via NodePorts"
fi

# ── Collect final RS status ───────────────────────────────────────────────────
FINAL_STATUS_JSON=$(_mongosh_eval "admin" \
  "var s=rs.status();
   var out={rs:s.set,members_count:s.members?s.members.length:0,members:[]};
   (s.members||[]).forEach(function(m){
     out.members.push({name:m.name,state:m.stateStr,health:m.health});
   });
   print(JSON.stringify(out));" \
  2>/dev/null | tail -1 || echo '{}')

log_info "rs-init" "RS init complete: ${FINAL_STATUS_JSON}"

jq -n \
  --arg  topology      "${RS_TOPOLOGY}" \
  --arg  namespace     "${DB_NAMESPACE}" \
  --arg  rs_name       "${RS_NAME}" \
  --argjson member_count "${MEMBER_COUNT}" \
  --argjson rs_status  "${FINAL_STATUS_JSON}" \
  '{topology: $topology, namespace: $namespace, rs_name: $rs_name,
    expected_members: $member_count, rs_status: $rs_status}' \
  > "$AQSH_RESULT_FILE"
