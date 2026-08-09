#!/usr/bin/env bats

setup() {
  export LIB_DIR="${BATS_TEST_DIRNAME}/../../../aqsh-tasks/lib"
  # shellcheck source=../../../aqsh-tasks/lib/mariadb-s3-resolver.sh
  source "${LIB_DIR}/mariadb-s3-resolver.sh"
  MARIADB_CONTAINER=mariadb
  unset BACKUP_ENDPOINT BACKUP_BUCKET BACKUP_PREFIX BACKUP_REGION
  unset BACKUP_ACCESS_SECRET BACKUP_ACCESS_KEY BACKUP_SECRET_ACCESS_SECRET BACKUP_SECRET_KEY
  unset MINIO_ENDPOINT MINIO_BUCKET MINIO_ROOT_USER MINIO_ROOT_PASSWORD _MDBT_CONFIG_LOADED_KEYS
  unset MOCK_CR_STDERR MOCK_CR_STATUS
  MOCK_CR='{"spec":{"env":[],"envFrom":[]}}'
  MOCK_PODS='{"items":[]}'
  MOCK_SECRET_PRIMARY='{"data":{}}'
  MOCK_SECRET_LATER='{"data":{}}'
  MOCK_CONFIG='{"data":{}}'
}

_kubectl() {
  case "$1:$2" in
    get:mariadb)
      [[ -z "${MOCK_CR_STDERR:-}" ]] || printf '%s\n' "$MOCK_CR_STDERR" >&2
      printf '%s' "$MOCK_CR"
      return "${MOCK_CR_STATUS:-0}"
      ;;
    get:pods) printf '%s' "$MOCK_PODS" ;;
    get:secret)
      case "$3" in
        storage-primary) printf '%s' "$MOCK_SECRET_PRIMARY" ;;
        storage-later) printf '%s' "$MOCK_SECRET_LATER" ;;
        *) return 1 ;;
      esac
      ;;
    get:configmap) printf '%s' "$MOCK_CONFIG" ;;
    *) return 1 ;;
  esac
}

b64() { printf '%s' "$1" | base64 | tr -d '\n'; }

@test "explicit secretKeyRef is retained for credentials without exposing its value" {
  local marker="credential-marker-that-must-not-appear"
  MOCK_SECRET_PRIMARY="$(jq -cn --arg a "$(b64 "$marker")" --arg s "$(b64 'second-private-marker')" \
    '{data:{access:$a,secret:$s}}')"
  MOCK_CR='{"spec":{"env":[
    {"name":"S3_ACCESS_KEY","valueFrom":{"secretKeyRef":{"name":"storage-primary","key":"access"}}},
    {"name":"S3_ACCESS_SECRET","valueFrom":{"secretKeyRef":{"name":"storage-primary","key":"secret"}}}
  ]}}'

  mdbt_s3_workload_contract database
  [ "$(jq -r '.accessKey.name' <<<"$MDBT_S3_CONTRACT")" = "storage-primary" ]
  [ "$(jq -r '.accessKey.key' <<<"$MDBT_S3_CONTRACT")" = "access" ]
  [[ "$MDBT_S3_CONTRACT" != *"$marker"* ]]
}

@test "explicit env overrides envFrom and later envFrom wins when explicit env is absent" {
  MOCK_SECRET_PRIMARY="$(jq -cn --arg old "$(b64 'old-bucket')" '{data:{S3_BUCKET:$old}}')"
  MOCK_SECRET_LATER="$(jq -cn --arg new "$(b64 'later-bucket')" '{data:{S3_BUCKET:$new}}')"
  MOCK_CR='{"spec":{"env":[{"name":"S3_BUCKET","value":"explicit-bucket"}],"envFrom":[
    {"secretRef":{"name":"storage-primary"}},
    {"secretRef":{"name":"storage-later"}}
  ]}}'
  mdbt_s3_workload_contract database
  [ "$(jq -r '.bucket.value' <<<"$MDBT_S3_CONTRACT")" = "explicit-bucket" ]

  MOCK_CR="$(jq '.spec.env=[]' <<<"$MOCK_CR")"
  mdbt_s3_workload_contract database
  [ "$(jq -r '.bucket.value' <<<"$MDBT_S3_CONTRACT")" = "later-bucket" ]
}

@test "envFrom prefix maps the effective environment name back to the Secret key" {
  MOCK_SECRET_PRIMARY="$(jq -cn --arg value "$(b64 'prefix-bucket')" '{data:{BUCKET:$value}}')"
  MOCK_CR='{"spec":{"envFrom":[{"prefix":"S3_","secretRef":{"name":"storage-primary"}}]}}'
  mdbt_s3_workload_contract database
  [ "$(jq -r '.bucket.value' <<<"$MDBT_S3_CONTRACT")" = "prefix-bucket" ]
  [ "$(jq -r '.bucket.prefix' <<<"$MDBT_S3_CONTRACT")" = "S3_" ]
}

@test "non-credential settings resolve from ConfigMap env and envFrom sources" {
  MOCK_CONFIG='{"data":{"ENDPOINT":"https://config.example.invalid","S3_BUCKET":"config-bucket","S3_BACKUP_REGION":"config-region-1"}}'
  MOCK_CR='{"spec":{"env":[
    {"name":"S3_URL","valueFrom":{"configMapKeyRef":{"name":"storage-config","key":"ENDPOINT"}}}
  ],"envFrom":[{"configMapRef":{"name":"storage-config"}}]}}'

  mdbt_s3_workload_contract database
  [ "$(jq -r '.endpoint.value' <<<"$MDBT_S3_CONTRACT")" = "https://config.example.invalid" ]
  [ "$(jq -r '.bucket.value' <<<"$MDBT_S3_CONTRACT")" = "config-bucket" ]
  [ "$(jq -r '.region.value' <<<"$MDBT_S3_CONTRACT")" = "config-region-1" ]
}

@test "exit-zero kubectl warnings stay out of MariaDB JSON" {
  MOCK_CR='{"spec":{"env":[{"name":"S3_BUCKET","value":"warning-safe-bucket"}]}}'
  MOCK_CR_STDERR='Warning: server-side deprecation notice'

  mdbt_s3_workload_contract database
  [ "$(jq -r '.bucket.value' <<<"$MDBT_S3_CONTRACT")" = "warning-safe-bucket" ]
  [[ "$MDBT_S3_CONTRACT" != *"deprecation"* ]]
}

@test "MariaDB lookup failures stay generic while NotFound remains an empty contract" {
  local private_error='private transport detail must not escape'
  MOCK_CR=''
  MOCK_CR_STATUS=1
  MOCK_CR_STDERR="$private_error"

  ! mdbt_s3_workload_contract database
  [ "$MDBT_S3_ERROR" = "cannot read the selected MariaDB workload spec" ]
  [[ "$MDBT_S3_ERROR" != *"$private_error"* ]]

  MOCK_CR_STDERR='Error from server (NotFound): mariadbs.k8s.mariadb.com "database" not found'
  mdbt_s3_workload_contract database
  [ "$MDBT_S3_CONTRACT" = '{}' ]
  [ -z "$MDBT_S3_ERROR" ]

  MOCK_CR='Error from server (NotFound): mariadbs.k8s.mariadb.com "database" not found'
  MOCK_CR_STDERR=''
  mdbt_s3_workload_contract database
  [ "$MDBT_S3_CONTRACT" = '{}' ]
  [ -z "$MDBT_S3_ERROR" ]
}

@test "workload region contract does not reuse the internal BACKUP_REGION name" {
  MOCK_CR='{"spec":{"env":[{"name":"BACKUP_REGION","value":"internal-name"}]}}'

  mdbt_s3_workload_contract database
  [ "$(jq -r 'has("region")' <<<"$MDBT_S3_CONTRACT")" = "false" ]
}

@test "literal credentials fail with a redacted actionable error" {
  MOCK_CR='{"spec":{"env":[{"name":"S3_ACCESS_KEY","value":"do-not-copy-this"}]}}'
  ! mdbt_s3_workload_contract database
  [[ "$MDBT_S3_ERROR" == *"must use secretKeyRef"* ]]
  [[ "$MDBT_S3_ERROR" != *"do-not-copy-this"* ]]
}

@test "conflicting MariaDB and Pod workload contracts fail closed" {
  MOCK_CR='{"spec":{"env":[{"name":"S3_BUCKET","value":"one-bucket"}]}}'
  MOCK_PODS='{"items":[{"spec":{"containers":[{"name":"mariadb","env":[{"name":"S3_BUCKET","value":"other-bucket"}]}]}}]}'
  ! mdbt_s3_workload_contract database
  [[ "$MDBT_S3_ERROR" == *"conflicting"* ]]
  [[ "$MDBT_S3_ERROR" != *"one-bucket"* ]]
  [[ "$MDBT_S3_ERROR" != *"other-bucket"* ]]
}

@test "workload fields override deployment fallback while explicit advanced values win" {
  MOCK_SECRET_PRIMARY="$(jq -cn \
    --arg endpoint "$(b64 'https://object.example.invalid')" \
    --arg bucket "$(b64 'workload-bucket')" \
    --arg region "$(b64 'workload-region-1')" \
    --arg access "$(b64 'private-a')" --arg secret "$(b64 'private-b')" \
    '{data:{S3_URL:$endpoint,S3_BUCKET:$bucket,S3_BACKUP_REGION:$region,S3_ACCESS_KEY:$access,S3_ACCESS_SECRET:$secret}}')"
  MOCK_CR='{"spec":{"envFrom":[{"secretRef":{"name":"storage-primary"}}]}}'
  MINIO_ENDPOINT='https://fallback.example.invalid'
  MINIO_BUCKET='fallback-bucket'
  BACKUP_BUCKET='advanced-bucket'
  BACKUP_REGION='deploy-region-1'
  _MDBT_CONFIG_LOADED_KEYS='BACKUP_REGION'

  mdbt_resolve_backup_location tenant-a database
  [ "$BACKUP_ENDPOINT" = 'https://object.example.invalid' ]
  [ "$BACKUP_BUCKET" = 'advanced-bucket' ]
  [ "$BACKUP_REGION" = 'workload-region-1' ]
  [ "$BACKUP_ACCESS_SECRET" = 'storage-primary' ]
  [ "$BACKUP_ACCESS_KEY" = 'S3_ACCESS_KEY' ]
  [ "$BACKUP_SECRET_ACCESS_SECRET" = 'storage-primary' ]
  [ "$BACKUP_SECRET_KEY" = 'S3_ACCESS_SECRET' ]
}

@test "explicit credential references win as one policy over workload credentials" {
  MOCK_SECRET_PRIMARY="$(jq -cn \
    --arg access "$(b64 'workload-access')" --arg secret "$(b64 'workload-secret')" \
    '{data:{access:$access,secret:$secret}}')"
  MOCK_CR='{"spec":{"env":[
    {"name":"S3_ACCESS_KEY","valueFrom":{"secretKeyRef":{"name":"storage-primary","key":"access"}}},
    {"name":"S3_ACCESS_SECRET","valueFrom":{"secretKeyRef":{"name":"storage-primary","key":"secret"}}}
  ]}}'
  BACKUP_ACCESS_SECRET='operator-credentials'
  BACKUP_ACCESS_KEY='operator-access'
  BACKUP_SECRET_KEY='operator-secret'

  mdbt_resolve_backup_location tenant-a database
  [ "$BACKUP_ACCESS_SECRET" = 'operator-credentials' ]
  [ "$BACKUP_ACCESS_KEY" = 'operator-access' ]
  [ "$BACKUP_SECRET_ACCESS_SECRET" = 'operator-credentials' ]
  [ "$BACKUP_SECRET_KEY" = 'operator-secret' ]
  [ "$MDBT_S3_CREDENTIAL_SOURCE" = 'reference-override' ]
}

@test "explicit credential bundle does not inherit a deploy-time fourth field" {
  MOCK_SECRET_PRIMARY="$(jq -cn \
    --arg access "$(b64 'workload-access')" --arg secret "$(b64 'workload-secret')" \
    '{data:{access:$access,secret:$secret}}')"
  MOCK_CR='{"spec":{"env":[
    {"name":"S3_ACCESS_KEY","valueFrom":{"secretKeyRef":{"name":"storage-primary","key":"access"}}},
    {"name":"S3_ACCESS_SECRET","valueFrom":{"secretKeyRef":{"name":"storage-primary","key":"secret"}}}
  ]}}'
  BACKUP_ACCESS_SECRET='operator-credentials'
  BACKUP_ACCESS_KEY='operator-access'
  BACKUP_SECRET_ACCESS_SECRET='deploy-credentials'
  BACKUP_SECRET_KEY='operator-secret'
  _MDBT_CONFIG_LOADED_KEYS='BACKUP_SECRET_ACCESS_SECRET'

  mdbt_resolve_backup_location tenant-a database
  [ "$BACKUP_ACCESS_SECRET" = 'operator-credentials' ]
  [ "$BACKUP_ACCESS_KEY" = 'operator-access' ]
  [ "$BACKUP_SECRET_ACCESS_SECRET" = 'operator-credentials' ]
  [ "$BACKUP_SECRET_KEY" = 'operator-secret' ]
  [ "$MDBT_S3_CREDENTIAL_SOURCE" = 'reference-override' ]
}

@test "explicit credential bundle does not depend on invalid workload references" {
  MOCK_CR='{"spec":{"env":[
    {"name":"S3_URL","value":"https://object.example.invalid"},
    {"name":"S3_ACCESS_KEY","valueFrom":{"secretKeyRef":{"name":"missing-workload-secret","key":"access"}}},
    {"name":"S3_ACCESS_SECRET","valueFrom":{"secretKeyRef":{"name":"missing-workload-secret","key":"secret"}}}
  ]}}'
  BACKUP_ACCESS_SECRET='operator-credentials'
  BACKUP_ACCESS_KEY='operator-access'
  BACKUP_SECRET_ACCESS_SECRET='operator-credentials'
  BACKUP_SECRET_KEY='operator-secret'

  mdbt_resolve_backup_location tenant-a database
  [ "$BACKUP_ENDPOINT" = 'https://object.example.invalid' ]
  [ "$BACKUP_ACCESS_SECRET" = 'operator-credentials' ]
  [ "$BACKUP_ACCESS_KEY" = 'operator-access' ]
  [ "$BACKUP_SECRET_ACCESS_SECRET" = 'operator-credentials' ]
  [ "$BACKUP_SECRET_KEY" = 'operator-secret' ]
  [ "$MDBT_S3_CREDENTIAL_SOURCE" = 'reference-override' ]
}

@test "explicit credential bundle still fails closed on workload location conflict" {
  MOCK_CR='{"spec":{"env":[{"name":"S3_BUCKET","value":"one-bucket"}]}}'
  MOCK_PODS='{"items":[{"spec":{"containers":[{"name":"mariadb","env":[{"name":"S3_BUCKET","value":"other-bucket"}]}]}}]}'
  BACKUP_ACCESS_SECRET='operator-credentials'
  BACKUP_ACCESS_KEY='operator-access'
  BACKUP_SECRET_ACCESS_SECRET='operator-credentials'
  BACKUP_SECRET_KEY='operator-secret'

  ! mdbt_resolve_backup_location tenant-a database
  [[ "$MDBT_S3_ERROR" == *"conflicting"* ]]
  [[ "$MDBT_S3_ERROR" != *"one-bucket"* ]]
  [[ "$MDBT_S3_ERROR" != *"other-bucket"* ]]
}

@test "workload credential references override deploy-time reference fallback" {
  MOCK_SECRET_PRIMARY="$(jq -cn \
    --arg access "$(b64 'workload-access')" --arg secret "$(b64 'workload-secret')" \
    '{data:{access:$access,secret:$secret}}')"
  MOCK_CR='{"spec":{"env":[
    {"name":"S3_ACCESS_KEY","valueFrom":{"secretKeyRef":{"name":"storage-primary","key":"access"}}},
    {"name":"S3_ACCESS_SECRET","valueFrom":{"secretKeyRef":{"name":"storage-primary","key":"secret"}}}
  ]}}'
  BACKUP_ACCESS_SECRET='deploy-credentials'
  BACKUP_ACCESS_KEY='deploy-access'
  BACKUP_SECRET_ACCESS_SECRET='deploy-credentials'
  BACKUP_SECRET_KEY='deploy-secret'
  _MDBT_CONFIG_LOADED_KEYS=$'BACKUP_ACCESS_SECRET\nBACKUP_ACCESS_KEY\nBACKUP_SECRET_ACCESS_SECRET\nBACKUP_SECRET_KEY'

  mdbt_resolve_backup_location tenant-a database
  [ "$BACKUP_ACCESS_SECRET" = 'storage-primary' ]
  [ "$BACKUP_ACCESS_KEY" = 'access' ]
  [ "$BACKUP_SECRET_ACCESS_SECRET" = 'storage-primary' ]
  [ "$BACKUP_SECRET_KEY" = 'secret' ]
  [ "$MDBT_S3_CREDENTIAL_SOURCE" = 'workload' ]
}

@test "deploy-time BACKUP_REGION remains the fallback when workload region is absent" {
  BACKUP_REGION='deploy-region-1'
  _MDBT_CONFIG_LOADED_KEYS='BACKUP_REGION'

  mdbt_resolve_backup_location tenant-a database
  [ "$BACKUP_REGION" = 'deploy-region-1' ]
}

@test "missing envFrom keys fall through but an incomplete credential pair fails" {
  MOCK_SECRET_PRIMARY="$(jq -cn --arg access "$(b64 'private-a')" '{data:{S3_ACCESS_KEY:$access}}')"
  MOCK_CR='{"spec":{"envFrom":[{"secretRef":{"name":"storage-primary"}}]}}'
  ! mdbt_resolve_backup_location tenant-a database
  [[ "$MDBT_S3_ERROR" == *"both S3 credential references"* ]]
}

@test "direct client resolves separate credential Secrets only at use time" {
  local access_marker="access-marker-private" secret_marker="secret-marker-private"
  MOCK_SECRET_PRIMARY="$(jq -cn --arg value "$(b64 "$access_marker")" '{data:{access:$value}}')"
  MOCK_SECRET_LATER="$(jq -cn --arg value "$(b64 "$secret_marker")" '{data:{secret:$value}}')"
  MOCK_CR='{"spec":{"env":[
    {"name":"S3_ACCESS_KEY","valueFrom":{"secretKeyRef":{"name":"storage-primary","key":"access"}}},
    {"name":"S3_ACCESS_SECRET","valueFrom":{"secretKeyRef":{"name":"storage-later","key":"secret"}}}
  ]}}'

  mdbt_resolve_backup_location tenant-a database
  [[ "$MDBT_S3_CONTRACT" != *"$access_marker"* ]]
  [[ "$MDBT_S3_CONTRACT" != *"$secret_marker"* ]]
  [ "$BACKUP_ACCESS_SECRET" = "storage-primary" ]
  [ "$BACKUP_SECRET_ACCESS_SECRET" = "storage-later" ]

  mdbt_s3_prepare_direct_client
  [ "$MINIO_ROOT_USER" = "$access_marker" ]
  [ "$MINIO_ROOT_PASSWORD" = "$secret_marker" ]
}

@test "operator manifest preserves separate Secret references and contains no credential values" {
  # shellcheck source=../../../aqsh-tasks/lib/mariadb-task-common.sh
  source "${LIB_DIR}/mariadb-task-common.sh"
  mdb_operator_apiversion() { printf 'k8s.mariadb.com/v1alpha1'; }
  BACKUP_ENDPOINT='https://object.example.invalid'
  BACKUP_BUCKET='example-bucket'
  BACKUP_PREFIX='mariadb/example'
  BACKUP_REGION='example-region-1'
  BACKUP_TARGET='PreferReplica'
  BACKUP_COMPRESSION='gzip'
  BACKUP_ACCESS_SECRET='access-reference'
  BACKUP_ACCESS_KEY='access-key'
  BACKUP_SECRET_ACCESS_SECRET='secret-reference'
  BACKUP_SECRET_KEY='secret-key'
  MINIO_ROOT_USER='credential-value-must-not-render'
  MINIO_ROOT_PASSWORD='another-value-must-not-render'

  local manifest
  manifest="$(mdbt_physical_backup_manifest backup example database)"
  [ "$(jq -r '.spec.storage.s3.accessKeyIdSecretKeyRef.name' <<<"$manifest")" = 'access-reference' ]
  [ "$(jq -r '.spec.storage.s3.secretAccessKeySecretKeyRef.name' <<<"$manifest")" = 'secret-reference' ]
  [[ "$manifest" != *"$MINIO_ROOT_USER"* ]]
  [[ "$manifest" != *"$MINIO_ROOT_PASSWORD"* ]]
}
