#!/usr/bin/env bats

setup() {
  export TEST_TMPDIR="${BATS_TEST_TMPDIR}"
  export PATH="${TEST_TMPDIR}/bin:${PATH}"
  export LIB_DIR="${BATS_TEST_DIRNAME}/../../../aqsh-tasks/lib"
  export SCRIPT="${BATS_TEST_DIRNAME}/../../../aqsh-tasks/scripts/mariadb/migration/migration-preflight.sh"
  export MARIADB_NAME=mariadb
  export _LOG_CURRENT_LEVEL=3
  mkdir -p "${TEST_TMPDIR}/bin"

  # Mock kubectl
  cat > "${TEST_TMPDIR}/bin/kubectl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

args=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --context|--namespace|--kubeconfig) shift 2 ;;
    -n) shift 2 ;;
    *) args+=("$1"); shift ;;
  esac
done

cmd="${args[0]:-}"

if [[ "$cmd" == "cluster-info" ]]; then
  echo "Kubernetes control plane is running"
  exit 0
fi

if [[ "$cmd" == "get" ]]; then
  resource="${args[1]:-}"
  name="${args[2]:-}"
  output="${args[*]}"

  if [[ "$output" == *'items[*]'* ]]; then
    if [[ "$resource" == "mariadb" ]]; then
      printf '%s' "${KUBECTL_CR_NAMES:-mariadb}" | tr ' ' '\n' | sed '/^$/d'
    elif [[ "$resource" == "statefulset" ]]; then
      printf '%s' "${KUBECTL_STS_NAMES:-}" | tr ' ' '\n' | sed '/^$/d'
    fi
    exit 0
  fi

  if [[ "$resource" == "mariadb" && -n "$name" && "$name" != "-o" ]]; then
    case "$output" in
      *'.spec.replicas'*) printf '%s' "${KUBECTL_CR_REPLICAS:-1}" ;;
      *) printf '{}' ;;
    esac
    exit 0
  fi

  if [[ "$resource" == "statefulset" && -n "$name" && "$name" != "-o" ]]; then
    case "$output" in
      *'.spec.replicas'*) printf '%s' "${KUBECTL_STS_REPLICAS:-1}" ;;
      *) printf '{}' ;;
    esac
    exit 0
  fi
fi

if [[ "$cmd" == "exec" ]]; then
  shift_index=0
  for i in "${!args[@]}"; do
    if [[ "${args[$i]}" == "--" ]]; then
      shift_index=$((i + 1))
      break
    fi
  done
  command=("${args[@]:$shift_index}")

  # Simulate pod not found
  pod="${args[1]:-}"
  if [[ "${KUBECTL_POD_EXEC_FAIL:-false}" == "true" ]]; then
    echo "Error: pods \"${pod}\" not found" >&2
    exit 1
  fi

  case "${command[*]}" in
    "true") exit 0 ;;
    "bash -c echo -n > /dev/tcp/"*) exit "${MINIO_TCP_EXIT:-0}" ;;
    "bash -c curl"*) exit "${MINIO_HTTP_EXIT:-0}" ;;
    *) exit 0 ;;
  esac
fi

echo "unexpected kubectl invocation: ${args[*]}" >&2
exit 1
EOF
  chmod +x "${TEST_TMPDIR}/bin/kubectl"

  # Mock s5cmd (S3/MinIO client)
  #   `ls` with no s3:// target (after --endpoint-url <url>) = auth-only probe,
  #   controlled by S5_AUTH_EXIT.
  #   `ls s3://bucket/` = bucket check, controlled by S5_BUCKET_LS_EXIT — a
  #   non-zero value emits a generic error (not "no object found"), which the
  #   script treats as BLOCK rather than an empty-but-accessible bucket.
  cat > "${TEST_TMPDIR}/bin/s5cmd" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

target=""
saw_ls=0
prev=""
for a in "$@"; do
  [[ "$prev" == "ls" ]] && target="$a"
  [[ "$a" == "ls" ]] && saw_ls=1
  prev="$a"
done

if [[ "$saw_ls" -eq 1 ]]; then
  if [[ -z "$target" ]]; then
    exit "${S5_AUTH_EXIT:-0}"
  fi
  if [[ "${S5_BUCKET_LS_EXIT:-0}" != "0" ]]; then
    echo "ERROR \"ls ${target}\": AccessDenied" >&2
    exit 1
  fi
  exit 0
fi

exit 0
EOF
  chmod +x "${TEST_TMPDIR}/bin/s5cmd"
}

# ---------------------------------------------------------------------------
# Pod exec checks
# ---------------------------------------------------------------------------

@test "pod exec PASS returns structured JSON with target pod" {
  run "${SCRIPT}" --namespace db-1 --mdb mariadb --json

  [ "$status" -eq 0 ]
  result=$(printf '%s' "$output" | jq -r '.status')
  pod=$(printf '%s' "$output" | jq -r '.target.pod')

  # Overall status is WARN, not PASS, because --minio-endpoint is omitted.
  [ "$result" = "WARN" ]
  [ "$pod" = "mariadb-0" ]
}

@test "pod exec PASS includes pod_exec check" {
  run "${SCRIPT}" --namespace db-1 --mdb mariadb --json

  [ "$status" -eq 0 ]
  check_status=$(printf '%s' "$output" | jq -r '.checks[] | select(.name == "pod_exec") | .status')
  [ "$check_status" = "PASS" ]
}

@test "pod exec failure emits BLOCK with POD_EXEC_FAILED" {
  export KUBECTL_POD_EXEC_FAIL=true

  run "${SCRIPT}" --namespace db-1 --mdb mariadb --json

  [ "$status" -eq 0 ]
  result=$(printf '%s' "$output" | jq -r '.status')
  reason=$(printf '%s' "$output" | jq -r '.checks[] | select(.name == "pod_exec") | .reason_code')

  [ "$result" = "BLOCK" ]
  [ "$reason" = "POD_EXEC_FAILED" ]
}

@test "auto-detects MariaDB CR when --mdb is omitted" {
  export KUBECTL_CR_NAMES="mdb-source"
  unset MARIADB_NAME

  run "${SCRIPT}" --namespace db-1 --json

  [ "$status" -eq 0 ]
  mdb=$(printf '%s' "$output" | jq -r '.target.mdb')
  [ "$mdb" = "mdb-source" ]
}

@test "reports MARIADB_AMBIGUOUS when several CRs exist and --mdb is omitted" {
  export KUBECTL_CR_NAMES="alpha beta"
  unset MARIADB_NAME

  run "${SCRIPT}" --namespace db-1 --json

  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.reason_code')" = "MARIADB_AMBIGUOUS" ]
}

# ---------------------------------------------------------------------------
# Argument validation
# ---------------------------------------------------------------------------

@test "exits 2 when --namespace is missing" {
  run "${SCRIPT}" --mdb mariadb --json
  [ "$status" -eq 2 ]
}

# ---------------------------------------------------------------------------
# MinIO checks — no endpoint supplied
# ---------------------------------------------------------------------------

@test "warns MINIO_ENDPOINT_NOT_PROVIDED when --minio-endpoint is omitted" {
  run "${SCRIPT}" --namespace db-1 --mdb mariadb --json

  [ "$status" -eq 0 ]
  reason=$(printf '%s' "$output" | jq -r '.checks[] | select(.name == "minio") | .reason_code')
  [ "$reason" = "MINIO_ENDPOINT_NOT_PROVIDED" ]
}

@test "overall status is WARN when only minio endpoint is missing" {
  run "${SCRIPT}" --namespace db-1 --mdb mariadb --json

  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.status')" = "WARN" ]
}

# ---------------------------------------------------------------------------
# MinIO checks — deploy-time MINIO_*_DEFAULT fallback
# ---------------------------------------------------------------------------

@test "falls back to MINIO_ENDPOINT_DEFAULT when --minio-endpoint is omitted" {
  export MINIO_ENDPOINT_DEFAULT="http://minio.minio.svc:9000"
  export MINIO_TCP_EXIT=0
  export MINIO_HTTP_EXIT=0

  run "${SCRIPT}" --namespace db-1 --mdb mariadb --json

  [ "$status" -eq 0 ]
  # The "minio" WARN check only fires when the endpoint is still unset —
  # the default should route into the real TCP/HTTP checks instead.
  [ "$(printf '%s' "$output" | jq 'any(.checks[]; .name == "minio")')" = "false" ]
  [ "$(printf '%s' "$output" | jq -r '.checks[] | select(.name == "minio_tcp") | .status')" = "PASS" ]
  [ "$(printf '%s' "$output" | jq -r '.minio.endpoint')" = "http://minio.minio.svc:9000" ]
}

@test "an explicit --minio-endpoint overrides MINIO_ENDPOINT_DEFAULT" {
  export MINIO_ENDPOINT_DEFAULT="http://default.minio.svc:9000"
  export MINIO_TCP_EXIT=0
  export MINIO_HTTP_EXIT=0

  run "${SCRIPT}" --namespace db-1 --mdb mariadb \
    --minio-endpoint http://explicit.minio.svc:9000 --json

  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.minio.endpoint')" = "http://explicit.minio.svc:9000" ]
}

@test "falls back to MINIO_ACCESS_KEY_DEFAULT/MINIO_SECRET_KEY_DEFAULT/MINIO_BUCKET_DEFAULT" {
  export MINIO_ENDPOINT_DEFAULT="http://minio.minio.svc:9000"
  export MINIO_ACCESS_KEY_DEFAULT="minioadmin"
  export MINIO_SECRET_KEY_DEFAULT="minioadmin123"
  export MINIO_BUCKET_DEFAULT="db-backups"
  export MINIO_TCP_EXIT=0
  export MINIO_HTTP_EXIT=0
  export S5_AUTH_EXIT=0
  export S5_BUCKET_LS_EXIT=0

  run "${SCRIPT}" --namespace db-1 --mdb mariadb --json

  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | jq -r '.checks[] | select(.name == "minio_auth") | .status')" = "PASS" ]
  [ "$(printf '%s' "$output" | jq -r '.checks[] | select(.name == "minio_bucket") | .status')" = "PASS" ]
  [ "$(printf '%s' "$output" | jq -r '.minio.bucket')" = "db-backups" ]
}

@test "still warns MINIO_ENDPOINT_NOT_PROVIDED when neither input nor default is set" {
  unset MINIO_ENDPOINT_DEFAULT || true

  run "${SCRIPT}" --namespace db-1 --mdb mariadb --json

  [ "$status" -eq 0 ]
  reason=$(printf '%s' "$output" | jq -r '.checks[] | select(.name == "minio") | .reason_code')
  [ "$reason" = "MINIO_ENDPOINT_NOT_PROVIDED" ]
}

# ---------------------------------------------------------------------------
# MinIO checks — endpoint supplied, TCP reachable
# ---------------------------------------------------------------------------

@test "minio_tcp PASS when TCP connection succeeds from inside pod" {
  export MINIO_TCP_EXIT=0

  run "${SCRIPT}" --namespace db-1 --mdb mariadb \
    --minio-endpoint http://minio.minio.svc:9000 --json

  [ "$status" -eq 0 ]
  tcp_status=$(printf '%s' "$output" | jq -r '.checks[] | select(.name == "minio_tcp") | .status')
  [ "$tcp_status" = "PASS" ]
}

@test "minio_tcp BLOCK when TCP connection fails from inside pod" {
  export MINIO_TCP_EXIT=1

  run "${SCRIPT}" --namespace db-1 --mdb mariadb \
    --minio-endpoint http://minio.minio.svc:9000 --json

  [ "$status" -eq 0 ]
  tcp_status=$(printf '%s' "$output" | jq -r '.checks[] | select(.name == "minio_tcp") | .status')
  tcp_reason=$(printf '%s' "$output" | jq -r '.checks[] | select(.name == "minio_tcp") | .reason_code')

  [ "$tcp_status" = "BLOCK" ]
  [ "$tcp_reason" = "MINIO_TCP_FAILED" ]
}

# ---------------------------------------------------------------------------
# MinIO checks — HTTP health
# ---------------------------------------------------------------------------

@test "minio_http PASS when curl health check succeeds" {
  export MINIO_HTTP_EXIT=0

  run "${SCRIPT}" --namespace db-1 --mdb mariadb \
    --minio-endpoint http://minio.minio.svc:9000 --json

  [ "$status" -eq 0 ]
  http_status=$(printf '%s' "$output" | jq -r '.checks[] | select(.name == "minio_http") | .status')
  [ "$http_status" = "PASS" ]
}

@test "minio_http WARN when curl is unavailable in pod (non-blocking)" {
  export MINIO_HTTP_EXIT=1

  run "${SCRIPT}" --namespace db-1 --mdb mariadb \
    --minio-endpoint http://minio.minio.svc:9000 --json

  [ "$status" -eq 0 ]
  http_status=$(printf '%s' "$output" | jq -r '.checks[] | select(.name == "minio_http") | .status')
  [ "$http_status" = "WARN" ]
}

# ---------------------------------------------------------------------------
# MinIO credential checks (s5cmd-based, from aqsh context)
# ---------------------------------------------------------------------------

@test "minio_auth WARN when credentials are not supplied" {
  run "${SCRIPT}" --namespace db-1 --mdb mariadb \
    --minio-endpoint http://minio.minio.svc:9000 --json

  [ "$status" -eq 0 ]
  auth_status=$(printf '%s' "$output" | jq -r '.checks[] | select(.name == "minio_auth") | .status')
  [ "$auth_status" = "WARN" ]
}

@test "minio_auth PASS when s5cmd auth probe succeeds" {
  export S5_AUTH_EXIT=0

  run "${SCRIPT}" --namespace db-1 --mdb mariadb \
    --minio-endpoint http://minio.minio.svc:9000 \
    --minio-access-key minioadmin \
    --minio-secret-key minioadmin123 --json

  [ "$status" -eq 0 ]
  auth_status=$(printf '%s' "$output" | jq -r '.checks[] | select(.name == "minio_auth") | .status')
  [ "$auth_status" = "PASS" ]
}

@test "minio_auth BLOCK when s5cmd auth probe fails" {
  export S5_AUTH_EXIT=1

  run "${SCRIPT}" --namespace db-1 --mdb mariadb \
    --minio-endpoint http://minio.minio.svc:9000 \
    --minio-access-key wrong \
    --minio-secret-key wrong --json

  [ "$status" -eq 0 ]
  auth_status=$(printf '%s' "$output" | jq -r '.checks[] | select(.name == "minio_auth") | .status')
  auth_reason=$(printf '%s' "$output" | jq -r '.checks[] | select(.name == "minio_auth") | .reason_code')

  [ "$auth_status" = "BLOCK" ]
  [ "$auth_reason" = "MINIO_AUTH_FAILED" ]
}

@test "minio_bucket PASS when bucket is accessible" {
  export S5_AUTH_EXIT=0
  export S5_BUCKET_LS_EXIT=0

  run "${SCRIPT}" --namespace db-1 --mdb mariadb \
    --minio-endpoint http://minio.minio.svc:9000 \
    --minio-access-key minioadmin \
    --minio-secret-key minioadmin123 \
    --minio-bucket db-backups --json

  [ "$status" -eq 0 ]
  bucket_status=$(printf '%s' "$output" | jq -r '.checks[] | select(.name == "minio_bucket") | .status')
  [ "$bucket_status" = "PASS" ]
}

@test "minio_bucket BLOCK when bucket is not accessible" {
  export S5_AUTH_EXIT=0
  export S5_BUCKET_LS_EXIT=1

  run "${SCRIPT}" --namespace db-1 --mdb mariadb \
    --minio-endpoint http://minio.minio.svc:9000 \
    --minio-access-key minioadmin \
    --minio-secret-key minioadmin123 \
    --minio-bucket missing-bucket --json

  [ "$status" -eq 0 ]
  bucket_status=$(printf '%s' "$output" | jq -r '.checks[] | select(.name == "minio_bucket") | .status')
  bucket_reason=$(printf '%s' "$output" | jq -r '.checks[] | select(.name == "minio_bucket") | .reason_code')

  [ "$bucket_status" = "BLOCK" ]
  [ "$bucket_reason" = "MINIO_BUCKET_NOT_ACCESSIBLE" ]
}

# ---------------------------------------------------------------------------
# Full pass scenario
# ---------------------------------------------------------------------------

@test "PREFLIGHT_PASS when all checks succeed including MinIO" {
  export S5_AUTH_EXIT=0
  export S5_BUCKET_LS_EXIT=0
  export MINIO_TCP_EXIT=0
  export MINIO_HTTP_EXIT=0

  run "${SCRIPT}" --namespace db-1 --mdb mariadb \
    --minio-endpoint http://minio.minio.svc:9000 \
    --minio-access-key minioadmin \
    --minio-secret-key minioadmin123 \
    --minio-bucket db-backups --json

  [ "$status" -eq 0 ]
  result=$(printf '%s' "$output" | jq -r '.status')
  reason=$(printf '%s' "$output" | jq -r '.reason_code')

  [ "$result" = "PASS" ]
  [ "$reason" = "PREFLIGHT_PASS" ]
}

# ---------------------------------------------------------------------------
# --strict-exit behaviour
# ---------------------------------------------------------------------------

@test "strict-exit exits 1 on BLOCK" {
  export KUBECTL_POD_EXEC_FAIL=true

  run "${SCRIPT}" --namespace db-1 --mdb mariadb --json --strict-exit

  [ "$status" -eq 1 ]
}

@test "result JSON includes minio endpoint and bucket fields" {
  run "${SCRIPT}" --namespace db-1 --mdb mariadb \
    --minio-endpoint http://minio.svc:9000 \
    --minio-bucket my-bucket --json

  [ "$status" -eq 0 ]
  endpoint=$(printf '%s' "$output" | jq -r '.minio.endpoint')
  bucket=$(printf '%s' "$output" | jq -r '.minio.bucket')

  [ "$endpoint" = "http://minio.svc:9000" ]
  [ "$bucket" = "my-bucket" ]
}
