#!/usr/bin/env bash
# Resolve the object-storage policy attached to a selected MariaDB workload.
#
# The S3_* names are a db-runbooks workload contract, not fields interpreted by
# mariadb-operator.  This resolver reads Kubernetes object specs only (never
# `kubectl exec`) and translates their effective env/envFrom sources into the
# BACKUP_* values and Secret references consumed by operator and direct-s5cmd
# paths.  Secret data is read only by mdbt_s3_prepare_direct_client.

[[ -n "${_MARIADB_S3_RESOLVER_LOADED:-}" ]] && return 0
_MARIADB_S3_RESOLVER_LOADED=1

MDBT_S3_ERROR=""
MDBT_S3_VALUE=""
MDBT_S3_DESCRIPTOR=""
MDBT_S3_CONTRACT="{}"
MDBT_S3_CREDENTIAL_SOURCE="fallback"

_mdbt_s3_set_error() {
  MDBT_S3_ERROR="$1"
  return 1
}

_mdbt_s3_secret_value() {
  local name="$1" key="$2" object encoded
  MDBT_S3_VALUE=""
  if ! object="$(_kubectl get secret "$name" -o json 2>/dev/null)"; then
    _mdbt_s3_set_error "cannot read referenced Secret '${name}'"
    return 1
  fi
  encoded="$(jq -r --arg key "$key" '.data[$key] // empty' <<<"$object")"
  if [[ -z "$encoded" ]]; then
    _mdbt_s3_set_error "referenced Secret '${name}' does not contain key '${key}'"
    return 2
  fi
  if ! MDBT_S3_VALUE="$(jq -Rr '@base64d' <<<"$encoded" 2>/dev/null)"; then
    _mdbt_s3_set_error "referenced Secret '${name}' key '${key}' is not valid Secret data"
    return 1
  fi
}

_mdbt_s3_secret_key_exists() {
  local name="$1" key="$2" object
  if ! object="$(_kubectl get secret "$name" -o json 2>/dev/null)"; then
    _mdbt_s3_set_error "cannot read referenced Secret '${name}'"
    return 1
  fi
  if ! jq -e --arg key "$key" '.data | has($key)' <<<"$object" >/dev/null 2>&1; then
    _mdbt_s3_set_error "referenced Secret '${name}' does not contain key '${key}'"
    return 2
  fi
}

_mdbt_s3_configmap_value() {
  local name="$1" key="$2" object
  MDBT_S3_VALUE=""
  if ! object="$(_kubectl get configmap "$name" -o json 2>/dev/null)"; then
    _mdbt_s3_set_error "cannot read referenced ConfigMap '${name}'"
    return 1
  fi
  if ! jq -e --arg key "$key" '.data | has($key)' <<<"$object" >/dev/null 2>&1; then
    _mdbt_s3_set_error "referenced ConfigMap '${name}' does not contain key '${key}'"
    return 2
  fi
  MDBT_S3_VALUE="$(jq -r --arg key "$key" '.data[$key]' <<<"$object")"
}

_mdbt_s3_configmap_key_exists() {
  local name="$1" key="$2" object
  if ! object="$(_kubectl get configmap "$name" -o json 2>/dev/null)"; then
    _mdbt_s3_set_error "cannot read referenced ConfigMap '${name}'"
    return 1
  fi
  if ! jq -e --arg key "$key" '.data | has($key)' <<<"$object" >/dev/null 2>&1; then
    _mdbt_s3_set_error "referenced ConfigMap '${name}' does not contain key '${key}'"
    return 2
  fi
}

# _mdbt_s3_descriptor_from_container <container-json> <env-name> <credential>
# Sets MDBT_S3_DESCRIPTOR to an empty string when the variable is absent, or to
# a JSON source descriptor. Explicit env wins over envFrom; envFrom is scanned
# in reverse so the later source wins, matching Kubernetes.
_mdbt_s3_descriptor_from_container() {
  local container="$1" env_name="$2" credential="$3"
  local entry kind name key value source prefix raw_key optional
  MDBT_S3_DESCRIPTOR=""

  entry="$(jq -c --arg name "$env_name" '[.env[]? | select(.name == $name)] | last // empty' <<<"$container")"
  if [[ -n "$entry" ]]; then
    if jq -e 'has("value")' <<<"$entry" >/dev/null 2>&1; then
      if [[ "$credential" == "true" ]]; then
        _mdbt_s3_set_error "credential environment variable '${env_name}' must use secretKeyRef"
        return 1
      fi
      value="$(jq -r '.value' <<<"$entry")"
      MDBT_S3_DESCRIPTOR="$(jq -cn --arg value "$value" '{kind:"value",via:"env",value:$value}')"
      return 0
    fi
    kind="$(jq -r '
      if .valueFrom.secretKeyRef then "secret"
      elif .valueFrom.configMapKeyRef then "configmap"
      else "unsupported" end
    ' <<<"$entry")"
    case "$kind" in
      secret)
        name="$(jq -r '.valueFrom.secretKeyRef.name // empty' <<<"$entry")"
        key="$(jq -r '.valueFrom.secretKeyRef.key // empty' <<<"$entry")"
        [[ -n "$name" && -n "$key" ]] || {
          _mdbt_s3_set_error "environment variable '${env_name}' has an incomplete secretKeyRef"; return 1;
        }
        if [[ "$credential" == "true" ]]; then
          _mdbt_s3_secret_key_exists "$name" "$key" || return 1
          MDBT_S3_DESCRIPTOR="$(jq -cn --arg name "$name" --arg key "$key" '{kind:"secretRef",via:"env",name:$name,key:$key}')"
        else
          _mdbt_s3_secret_value "$name" "$key" || return 1
          value="$MDBT_S3_VALUE"
          MDBT_S3_DESCRIPTOR="$(jq -cn --arg value "$value" '{kind:"value",via:"secretKeyRef",value:$value}')"
        fi
        return 0
        ;;
      configmap)
        if [[ "$credential" == "true" ]]; then
          _mdbt_s3_set_error "credential environment variable '${env_name}' must not use configMapKeyRef"
          return 1
        fi
        name="$(jq -r '.valueFrom.configMapKeyRef.name // empty' <<<"$entry")"
        key="$(jq -r '.valueFrom.configMapKeyRef.key // empty' <<<"$entry")"
        [[ -n "$name" && -n "$key" ]] || {
          _mdbt_s3_set_error "environment variable '${env_name}' has an incomplete configMapKeyRef"; return 1;
        }
        _mdbt_s3_configmap_value "$name" "$key" || return 1
        value="$MDBT_S3_VALUE"
        MDBT_S3_DESCRIPTOR="$(jq -cn --arg value "$value" '{kind:"value",via:"configMapKeyRef",value:$value}')"
        return 0
        ;;
      *)
        _mdbt_s3_set_error "environment variable '${env_name}' uses an unsupported valueFrom source"
        return 1
        ;;
    esac
  fi

  while IFS= read -r source; do
    [[ -n "$source" ]] || continue
    prefix="$(jq -r '.prefix // ""' <<<"$source")"
    [[ "$env_name" == "$prefix"* ]] || continue
    raw_key="${env_name#"$prefix"}"
    [[ -n "$raw_key" ]] || continue

    if jq -e '.secretRef != null' <<<"$source" >/dev/null 2>&1; then
      name="$(jq -r '.secretRef.name // empty' <<<"$source")"
      optional="$(jq -r '.secretRef.optional // false' <<<"$source")"
      if [[ "$credential" == "true" ]]; then
        local secret_rc=0
        _mdbt_s3_secret_key_exists "$name" "$raw_key" || secret_rc=$?
        if [[ "$secret_rc" -eq 2 || ( "$secret_rc" -eq 1 && "$optional" == "true" ) ]]; then
          MDBT_S3_ERROR=""; continue
        elif [[ "$secret_rc" -ne 0 ]]; then
          return 1
        fi
        MDBT_S3_DESCRIPTOR="$(jq -cn --arg name "$name" --arg key "$raw_key" --arg prefix "$prefix" \
          '{kind:"secretRef",via:"envFrom",name:$name,key:$key,prefix:$prefix}')"
      else
        local secret_rc=0
        _mdbt_s3_secret_value "$name" "$raw_key" || secret_rc=$?
        if [[ "$secret_rc" -eq 2 || ( "$secret_rc" -eq 1 && "$optional" == "true" ) ]]; then
          MDBT_S3_ERROR=""; continue
        elif [[ "$secret_rc" -ne 0 ]]; then
          return 1
        fi
        value="$MDBT_S3_VALUE"
        MDBT_S3_DESCRIPTOR="$(jq -cn --arg value "$value" --arg prefix "$prefix" \
          '{kind:"value",via:"envFrom.secretRef",prefix:$prefix,value:$value}')"
      fi
      return 0
    fi

    if jq -e '.configMapRef != null' <<<"$source" >/dev/null 2>&1; then
      name="$(jq -r '.configMapRef.name // empty' <<<"$source")"
      optional="$(jq -r '.configMapRef.optional // false' <<<"$source")"
      local config_rc=0
      if [[ "$credential" == "true" ]]; then
        _mdbt_s3_configmap_key_exists "$name" "$raw_key" || config_rc=$?
      else
        _mdbt_s3_configmap_value "$name" "$raw_key" || config_rc=$?
      fi
      if [[ "$config_rc" -eq 2 || ( "$config_rc" -eq 1 && "$optional" == "true" ) ]]; then
        MDBT_S3_ERROR=""; continue
      elif [[ "$config_rc" -ne 0 ]]; then
        return 1
      fi
      if [[ "$credential" == "true" ]]; then
        _mdbt_s3_set_error "credential environment variable '${env_name}' must not use envFrom.configMapRef"
        return 1
      fi
      value="$MDBT_S3_VALUE"
      MDBT_S3_DESCRIPTOR="$(jq -cn --arg value "$value" --arg prefix "$prefix" \
        '{kind:"value",via:"envFrom.configMapRef",prefix:$prefix,value:$value}')"
      return 0
    fi
  done < <(jq -c '(.envFrom // []) | reverse[]' <<<"$container")
}

_mdbt_s3_contract_from_container() {
  local container="$1" include_credentials="${2:-true}"
  local pair env_name field credential descriptor contract="{}"
  for pair in \
    'S3_URL:endpoint:false' \
    'S3_BUCKET:bucket:false' \
    'S3_BACKUP_REGION:region:false' \
    'S3_SUBFOLDER:prefix:false' \
    'S3_ACCESS_KEY:accessKey:true' \
    'S3_ACCESS_SECRET:secretKey:true'; do
    IFS=: read -r env_name field credential <<<"$pair"
    if [[ "$credential" == "true" && "$include_credentials" != "true" ]]; then
      continue
    fi
    _mdbt_s3_descriptor_from_container "$container" "$env_name" "$credential" || return 1
    descriptor="$MDBT_S3_DESCRIPTOR"
    if [[ -n "$descriptor" ]]; then
      contract="$(jq -c --arg field "$field" --argjson source "$descriptor" '. + {($field): $source}' <<<"$contract")"
    fi
  done
  MDBT_S3_CONTRACT="$contract"
}

# mdbt_s3_workload_contract <mariadb-name>
# Resolves the effective contract from the MariaDB CR and all selected Pods.
# Every non-empty candidate must agree; an in-progress rollout with divergent
# storage policy fails closed.
mdbt_s3_workload_contract() {
  local mariadb="$1" include_credentials="${2:-true}"
  local cr_json cr_error cr_stderr_tmp pods_json container candidate normalized baseline="" count=0 cr_found=false
  # Public error state is consumed by task scripts that source this library.
  # shellcheck disable=SC2034
  MDBT_S3_ERROR=""
  MDBT_S3_CONTRACT="{}"

  cr_stderr_tmp="$(mktemp)" || {
    _mdbt_s3_set_error "cannot read the selected MariaDB workload spec"
    return 1
  }
  if cr_json="$(_kubectl get mariadb "$mariadb" -o json 2>"$cr_stderr_tmp")"; then
    rm -f "$cr_stderr_tmp"
    cr_found=true
    if ! container="$(jq -c '.spec | {env:(.env // []),envFrom:(.envFrom // [])}' <<<"$cr_json" 2>/dev/null)"; then
      _mdbt_s3_set_error "cannot read the selected MariaDB workload spec"
      return 1
    fi
    _mdbt_s3_contract_from_container "$container" "$include_credentials" || return 1
    candidate="$MDBT_S3_CONTRACT"
    normalized="$(jq -Sc . <<<"$candidate")"
    baseline="$normalized"
    count=1
  else
    cr_error="$(<"$cr_stderr_tmp")"
    rm -f "$cr_stderr_tmp"
    if [[ "$cr_json" != *NotFound* && "$cr_json" != *"not found"* &&
          "$cr_error" != *NotFound* && "$cr_error" != *"not found"* ]]; then
      _mdbt_s3_set_error "cannot read the selected MariaDB workload spec"
      return 1
    fi
  fi

  # Leave operation-specific NotFound reporting to the caller. There is no
  # workload policy (or Pod set) to inspect after the selected CR is gone.
  if [[ "$cr_found" != "true" ]]; then
    MDBT_S3_CONTRACT="{}"
    return 0
  fi

  if ! pods_json="$(_kubectl get pods -l "app.kubernetes.io/instance=${mariadb}" -o json 2>/dev/null)"; then
    _mdbt_s3_set_error "cannot list Pods for the selected MariaDB workload"
    return 1
  fi
  while IFS= read -r container; do
    [[ -n "$container" ]] || continue
    _mdbt_s3_contract_from_container "$container" "$include_credentials" || return 1
    candidate="$MDBT_S3_CONTRACT"
    normalized="$(jq -Sc . <<<"$candidate")"
    if [[ -n "$baseline" && "$normalized" != "$baseline" ]]; then
      _mdbt_s3_set_error "selected MariaDB workload candidates have conflicting object-storage configuration"
      return 1
    fi
    baseline="$normalized"
    count=$((count + 1))
  done < <(jq -c --arg name "${MARIADB_CONTAINER:-mariadb}" \
    '.items[]? | ([.spec.containers[]? | select(.name == $name)] | first // empty)' <<<"$pods_json")

  if [[ "$count" -gt 0 ]]; then
    MDBT_S3_CONTRACT="$baseline"
    [[ -n "$MDBT_S3_CONTRACT" ]] || MDBT_S3_CONTRACT="{}"
  else
    MDBT_S3_CONTRACT="{}"
  fi
}

_mdbt_s3_config_loaded() {
  local key="$1"
  grep -Fxq "$key" <<<"${_MDBT_CONFIG_LOADED_KEYS:-}"
}

_mdbt_s3_has_explicit_credential_refs() {
  local key
  for key in \
    BACKUP_ACCESS_SECRET BACKUP_ACCESS_KEY \
    BACKUP_SECRET_ACCESS_SECRET BACKUP_SECRET_KEY; do
    if [[ -n "${!key:-}" ]] && ! _mdbt_s3_config_loaded "$key"; then
      return 0
    fi
  done
  return 1
}

_mdbt_s3_workload_value() {
  local field="$1"
  jq -r --arg field "$field" '.[$field].value // empty' <<<"$MDBT_S3_CONTRACT"
}

# mdbt_resolve_backup_location <namespace> [mariadb]
# Precedence for location fields: explicit BACKUP_* environment override,
# selected workload contract, deploy-time config, compatibility default.
# Credential references use the same tiers but resolve as one bundle so a
# higher-precedence pair is never combined with a lower-precedence pair.
mdbt_resolve_backup_location() {
  local namespace="$1" mariadb workload="{}" configured_region key
  configured_region="${BACKUP_REGION:-}"
  if [[ "$#" -ge 2 ]]; then mariadb="$2"; else mariadb="${MARIADB_NAME:-}"; fi
  local access_json secret_json had_fallback_refs=false explicit_credential_refs=false
  if [[ -n "${BACKUP_ACCESS_SECRET:-}${BACKUP_ACCESS_KEY:-}${BACKUP_SECRET_ACCESS_SECRET:-}${BACKUP_SECRET_KEY:-}" ]]; then
    had_fallback_refs=true
  fi
  if _mdbt_s3_has_explicit_credential_refs; then
    explicit_credential_refs=true
  fi
  if [[ -n "$mariadb" ]]; then
    # A higher-precedence explicit credential bundle must not depend on
    # resolving or validating lower-tier workload credential references.
    if [[ "$explicit_credential_refs" == "true" ]]; then
      mdbt_s3_workload_contract "$mariadb" false || return 1
    else
      mdbt_s3_workload_contract "$mariadb" || return 1
    fi
    workload="$MDBT_S3_CONTRACT"
  else
    MDBT_S3_CONTRACT="{}"
  fi

  if [[ -z "${BACKUP_ENDPOINT:-}" ]] || _mdbt_s3_config_loaded BACKUP_ENDPOINT; then
    BACKUP_ENDPOINT="$(_mdbt_s3_workload_value endpoint)"
    BACKUP_ENDPOINT="${BACKUP_ENDPOINT:-${MINIO_ENDPOINT:-http://minio.minio.svc.cluster.local:9000}}"
  fi
  if [[ -z "${BACKUP_BUCKET:-}" ]] || _mdbt_s3_config_loaded BACKUP_BUCKET; then
    BACKUP_BUCKET="$(_mdbt_s3_workload_value bucket)"
    BACKUP_BUCKET="${BACKUP_BUCKET:-${MINIO_BUCKET:-db-backups}}"
  fi
  if [[ -z "${BACKUP_PREFIX:-}" ]] || _mdbt_s3_config_loaded BACKUP_PREFIX; then
    BACKUP_PREFIX="$(_mdbt_s3_workload_value prefix)"
    BACKUP_PREFIX="${BACKUP_PREFIX:-mariadb/${namespace}}"
  fi
  if [[ -z "${BACKUP_REGION:-}" ]] || _mdbt_s3_config_loaded BACKUP_REGION; then
    BACKUP_REGION="$(_mdbt_s3_workload_value region)"
    BACKUP_REGION="${BACKUP_REGION:-${configured_region:-us-east-1}}"
  fi

  access_json="$(jq -c '.accessKey // empty' <<<"$workload")"
  secret_json="$(jq -c '.secretKey // empty' <<<"$workload")"
  if [[ "$explicit_credential_refs" == "true" ]]; then
    # Credential references are one atomic policy. If the platform process
    # supplies any explicit reference field, preserve that set instead of
    # combining it with lower-precedence workload or deploy-time references.
    # The historical three-field form shares one Secret name for both keys.
    for key in \
      BACKUP_ACCESS_SECRET BACKUP_ACCESS_KEY \
      BACKUP_SECRET_ACCESS_SECRET BACKUP_SECRET_KEY; do
      if _mdbt_s3_config_loaded "$key"; then
        printf -v "$key" '%s' ''
      fi
    done
    BACKUP_ACCESS_SECRET="${BACKUP_ACCESS_SECRET:-minio}"
    BACKUP_ACCESS_KEY="${BACKUP_ACCESS_KEY:-access-key-id}"
    BACKUP_SECRET_ACCESS_SECRET="${BACKUP_SECRET_ACCESS_SECRET:-${BACKUP_ACCESS_SECRET}}"
    BACKUP_SECRET_KEY="${BACKUP_SECRET_KEY:-secret-access-key}"
    MDBT_S3_CREDENTIAL_SOURCE="reference-override"
  elif [[ -n "$access_json" || -n "$secret_json" ]]; then
    if [[ -z "$access_json" || -z "$secret_json" ]]; then
      _mdbt_s3_set_error "selected MariaDB workload must define both S3 credential references"
      return 1
    fi
    BACKUP_ACCESS_SECRET="$(jq -r '.name' <<<"$access_json")"
    BACKUP_ACCESS_KEY="$(jq -r '.key' <<<"$access_json")"
    BACKUP_SECRET_ACCESS_SECRET="$(jq -r '.name' <<<"$secret_json")"
    BACKUP_SECRET_KEY="$(jq -r '.key' <<<"$secret_json")"
    MDBT_S3_CREDENTIAL_SOURCE="workload"
  else
    BACKUP_ACCESS_SECRET="${BACKUP_ACCESS_SECRET:-minio}"
    BACKUP_ACCESS_KEY="${BACKUP_ACCESS_KEY:-access-key-id}"
    BACKUP_SECRET_ACCESS_SECRET="${BACKUP_SECRET_ACCESS_SECRET:-${BACKUP_ACCESS_SECRET}}"
    BACKUP_SECRET_KEY="${BACKUP_SECRET_KEY:-secret-access-key}"
    if [[ "$had_fallback_refs" == "true" ]]; then
      MDBT_S3_CREDENTIAL_SOURCE="reference-override"
    else
      MDBT_S3_CREDENTIAL_SOURCE="default"
    fi
  fi
}

# Resolve credentials only for direct S3 clients. Values remain in process
# memory and are exported under the compatibility names consumed by s5cmd.
mdbt_s3_prepare_direct_client() {
  if [[ "$MDBT_S3_CREDENTIAL_SOURCE" == "workload" || "$MDBT_S3_CREDENTIAL_SOURCE" == "reference-override" ]]; then
    _mdbt_s3_secret_value "$BACKUP_ACCESS_SECRET" "$BACKUP_ACCESS_KEY" || return 1
    MINIO_ROOT_USER="$MDBT_S3_VALUE"
    _mdbt_s3_secret_value "$BACKUP_SECRET_ACCESS_SECRET" "$BACKUP_SECRET_KEY" || return 1
    MINIO_ROOT_PASSWORD="$MDBT_S3_VALUE"
  else
    # Preserve the existing direct-client compatibility defaults during the
    # migration. Operator-native paths still use the Secret references above.
    MINIO_ROOT_USER="${MINIO_ROOT_USER:-minioadmin}"
    MINIO_ROOT_PASSWORD="${MINIO_ROOT_PASSWORD:-minioadmin-changeme-prod}"
  fi
  MINIO_ENDPOINT="$BACKUP_ENDPOINT"
  export MINIO_ENDPOINT MINIO_ROOT_USER MINIO_ROOT_PASSWORD
}
