#!/usr/bin/env bash
# =============================================================================
# scripts/lib/k8s.sh
# Kubernetes helper functions using kubectl.
#
# Usage:
#   source scripts/lib/logging.sh
#   source scripts/lib/response.sh
#   source scripts/lib/k8s.sh
#
#   # Optional – set a default namespace and/or kubeconfig
#   K8S_NAMESPACE="default"
#   K8S_CONTEXT=""      # empty → current context / in-cluster config
#   K8S_KUBECONFIG=""   # empty → use ~/.kube/config / KUBECONFIG env
#
# Every public function returns a JSON string (via response_ok / response_err).
# =============================================================================

# Guard against double-sourcing
[[ -n "${_K8S_LIB_LOADED:-}" ]] && return 0
_K8S_LIB_LOADED=1

# Defaults (callers may override before sourcing or afterwards)
K8S_NAMESPACE="${K8S_NAMESPACE:-default}"
K8S_CONTEXT="${K8S_CONTEXT:-}"
K8S_KUBECONFIG="${K8S_KUBECONFIG:-}"


# ---------------------------------------------------------------------------
# k8s_use_kubeconfig <path>
# Set the active kubeconfig to the given file.
# Returns: JSON response
# ---------------------------------------------------------------------------
k8s_use_kubeconfig() {
  local kubeconfig="${1:?path is required}"
  local op="k8s_use_kubeconfig"

  if [[ ! -f "$kubeconfig" ]]; then
    log_error "$op" "kubeconfig file not found: $kubeconfig"
    response_err "$op" "kubeconfig file not found" "{\"path\":\"$kubeconfig\"}" 1
    return 1
  fi

  K8S_KUBECONFIG="$kubeconfig"
  log_info "$op" "Using kubeconfig: $kubeconfig"
  response_ok "$op" "kubeconfig set" "{\"path\":\"$kubeconfig\"}"
}

# ---------------------------------------------------------------------------
# _kubectl [args...]
# Wrapper that injects --namespace and --kubeconfig when set.
# ---------------------------------------------------------------------------
_kubectl() {
  local args=()
  if [[ -n "$K8S_KUBECONFIG" ]]; then
    args+=(--kubeconfig "$K8S_KUBECONFIG")
  fi
  if [[ -n "$K8S_CONTEXT" ]]; then
    args+=(--context "$K8S_CONTEXT")
  fi
  if [[ -n "$K8S_NAMESPACE" ]]; then
    args+=(--namespace "$K8S_NAMESPACE")
  fi
  kubectl "${args[@]}" "$@"
}

# ---------------------------------------------------------------------------
# _kubectl_global [args...]
# Wrapper WITHOUT automatic namespace injection (for cluster-wide commands).
# ---------------------------------------------------------------------------
_kubectl_global() {
  local args=()
  if [[ -n "$K8S_KUBECONFIG" ]]; then
    args+=(--kubeconfig "$K8S_KUBECONFIG")
  fi
  if [[ -n "$K8S_CONTEXT" ]]; then
    args+=(--context "$K8S_CONTEXT")
  fi
  kubectl "${args[@]}" "$@"
}

# ---------------------------------------------------------------------------
# k8s_check
# Verify that kubectl is available and the cluster is reachable.
# Returns: JSON response
# ---------------------------------------------------------------------------
k8s_check() {
  local op="k8s_check"
  log_info "$op" "Checking cluster connectivity"

  # ── In-cluster: use curl against the in-pod service-account token ──────────
  # kubectl cluster-info --request-timeout bypasses in-cluster KUBECONFIG and
  # falls back to localhost:8080 (unavailable), so we use the K8s API directly.
  local sa_token="/var/run/secrets/kubernetes.io/serviceaccount/token"
  if [[ -f "$sa_token" ]]; then
    local token ca_cert api_host api_port out
    token=$(cat "$sa_token" 2>/dev/null || true)
    ca_cert="/var/run/secrets/kubernetes.io/serviceaccount/ca.crt"
    api_host="${KUBERNETES_SERVICE_HOST:-kubernetes.default.svc}"
    api_port="${KUBERNETES_SERVICE_PORT_HTTPS:-${KUBERNETES_SERVICE_PORT:-443}}"
    if ! out=$(curl -sf --cacert "$ca_cert" \
        -H "Authorization: Bearer $token" \
        --max-time 5 \
        "https://${api_host}:${api_port}/healthz" 2>&1); then
      log_error "$op" "Cannot reach cluster API: $out"
      response_err "$op" "Cannot reach cluster" "{\"detail\":\"$(_escape_json_string "$(echo "$out" | head -1)")\"}" 1
      return 1
    fi
    log_info "$op" "Cluster is reachable (in-cluster curl)"
    response_ok "$op" "Cluster is reachable" "{\"healthz\":\"$(_escape_json_string "$out")\"}"
    return 0
  fi

  # ── Out-of-cluster: use kubectl ────────────────────────────────────────────
  if ! command -v kubectl &>/dev/null; then
    log_error "$op" "kubectl not found in PATH"
    response_err "$op" "kubectl not found in PATH" '{}' 127
    return 1
  fi

  local out
  if ! out=$(_kubectl_global cluster-info --request-timeout=5s 2>&1); then
    log_error "$op" "Cannot reach cluster: $out"
    response_err "$op" "Cannot reach cluster" "{\"detail\":\"$(_escape_json_string "$(echo "$out" | head -1)")\"}" 1
    return 1
  fi

  log_info "$op" "Cluster is reachable (kubectl)"
  response_ok "$op" "Cluster is reachable" "{\"info\":\"$(_escape_json_string "$(echo "$out" | head -1)")\"}"
}

# ---------------------------------------------------------------------------
# k8s_get_namespaces
# List all namespaces.
# Returns: JSON response with array of namespace names.
# ---------------------------------------------------------------------------
k8s_get_namespaces() {
  local op="k8s_get_namespaces"
  log_info "$op" "Listing namespaces"

  local out
  if ! out=$(_kubectl_global get namespaces -o json 2>&1); then
    log_error "$op" "Failed to list namespaces: $out"
    response_err "$op" "Failed to list namespaces" "{\"detail\":\"$(_escape_json_string "$out")\"}" 1
    return 1
  fi

  local names
  names=$(echo "$out" | grep -o '"name": *"[^"]*"' | grep -v 'kubernetes.io' | awk -F'"' '{print "\"" $4 "\""}' | paste -sd ',' -)
  log_info "$op" "Namespaces retrieved"
  response_ok "$op" "Namespaces retrieved" "{\"namespaces\":[${names}]}"
}

# ---------------------------------------------------------------------------
# k8s_namespace_exists <namespace>
# Check whether a namespace exists.
# Returns: JSON response; data.exists = true|false
# ---------------------------------------------------------------------------
k8s_namespace_exists() {
  local namespace="${1:?namespace is required}"
  local op="k8s_namespace_exists"
  log_debug "$op" "Checking namespace: $namespace"

  if _kubectl_global get namespace "$namespace" &>/dev/null; then
    log_info "$op" "Namespace '$namespace' exists"
    response_ok "$op" "Namespace exists" "{\"namespace\":\"$namespace\",\"exists\":true}"
  else
    log_info "$op" "Namespace '$namespace' does not exist"
    response_ok "$op" "Namespace does not exist" "{\"namespace\":\"$namespace\",\"exists\":false}"
  fi
}

# ---------------------------------------------------------------------------
# k8s_create_namespace <namespace>
# Create a namespace if it does not already exist.
# Returns: JSON response
# ---------------------------------------------------------------------------
k8s_create_namespace() {
  local namespace="${1:?namespace is required}"
  local op="k8s_create_namespace"
  log_info "$op" "Creating namespace: $namespace"

  local out
  if out=$(_kubectl_global get namespace "$namespace" 2>&1); then
    log_info "$op" "Namespace '$namespace' already exists"
    response_ok "$op" "Namespace already exists" "{\"namespace\":\"$namespace\",\"created\":false}"
    return 0
  fi

  if ! out=$(_kubectl_global create namespace "$namespace" 2>&1); then
    log_error "$op" "Failed to create namespace '$namespace': $out"
    response_err "$op" "Failed to create namespace" "{\"namespace\":\"$namespace\",\"detail\":\"$(_escape_json_string "$out")\"}" 1
    return 1
  fi

  log_info "$op" "Namespace '$namespace' created"
  response_ok "$op" "Namespace created" "{\"namespace\":\"$namespace\",\"created\":true}"
}

# ---------------------------------------------------------------------------
# k8s_get_pods [label_selector]
# List pods in the current namespace (K8S_NAMESPACE).
# Optional: filter by label selector, e.g. "app=myapp"
# Returns: JSON response with pod list.
# ---------------------------------------------------------------------------
k8s_get_pods() {
  local selector="${1:-}"
  local op="k8s_get_pods"
  log_info "$op" "Listing pods in namespace '$K8S_NAMESPACE' selector='${selector:-all}'"

  local args=(-o json)
  [[ -n "$selector" ]] && args+=(-l "$selector")

  local out
  if ! out=$(_kubectl get pods "${args[@]}" 2>&1); then
    log_error "$op" "Failed to list pods: $out"
    response_err "$op" "Failed to list pods" "{\"detail\":\"$(_escape_json_string "$out")\"}" 1
    return 1
  fi

  log_info "$op" "Found pods in namespace '$K8S_NAMESPACE'"
  response_ok "$op" "Pods retrieved" "{\"namespace\":\"$K8S_NAMESPACE\",\"selector\":\"${selector:-all}\",\"raw\":$out}"
}

# ---------------------------------------------------------------------------
# k8s_get_pod_status <pod_name>
# Get the status/phase of a specific pod.
# Returns: JSON response with phase, conditions, containerStatuses.
# ---------------------------------------------------------------------------
k8s_get_pod_status() {
  local pod_name="${1:?pod_name is required}"
  local op="k8s_get_pod_status"
  log_info "$op" "Getting status of pod '$pod_name'"

  local out
  if ! out=$(_kubectl get pod "$pod_name" -o json 2>&1); then
    log_error "$op" "Pod '$pod_name' not found or error: $out"
    response_err "$op" "Pod not found" "{\"pod\":\"$pod_name\",\"detail\":\"$(_escape_json_string "$out")\"}" 1
    return 1
  fi

  response_ok "$op" "Pod status retrieved" "{\"pod\":\"$pod_name\",\"raw\":$out}"
}

# ---------------------------------------------------------------------------
# k8s_get_sts [label_selector]
# List StatefulSets in the current namespace.
# Returns: JSON response
# ---------------------------------------------------------------------------
k8s_get_sts() {
  local selector="${1:-}"
  local op="k8s_get_sts"
  log_info "$op" "Listing StatefulSets in namespace '$K8S_NAMESPACE' selector='${selector:-all}'"

  local args=(-o json)
  [[ -n "$selector" ]] && args+=(-l "$selector")

  local out
  if ! out=$(_kubectl get statefulset "${args[@]}" 2>&1); then
    log_error "$op" "Failed to list StatefulSets: $out"
    response_err "$op" "Failed to list StatefulSets" "{\"detail\":\"$(_escape_json_string "$out")\"}" 1
    return 1
  fi

  response_ok "$op" "StatefulSets retrieved" "{\"namespace\":\"$K8S_NAMESPACE\",\"selector\":\"${selector:-all}\",\"raw\":$out}"
}

# ---------------------------------------------------------------------------
# k8s_filter_sts_by_name <name_pattern>
# Filter StatefulSets whose name contains the given pattern.
# Returns: JSON response with matching STS names and replicas.
# ---------------------------------------------------------------------------
k8s_filter_sts_by_name() {
  local pattern="${1:?name_pattern is required}"
  local op="k8s_filter_sts_by_name"
  log_info "$op" "Filtering StatefulSets by name pattern '$pattern' in namespace '$K8S_NAMESPACE'"

  local out
  if ! out=$(_kubectl get statefulset -o json 2>&1); then
    log_error "$op" "Failed to list StatefulSets: $out"
    response_err "$op" "Failed to list StatefulSets" "{\"detail\":\"$(_escape_json_string "$out")\"}" 1
    return 1
  fi

  # Extract names that match pattern (use -F for literal/fixed-string matching)
  local matches
  matches=$(echo "$out" | grep -o '"name":"[^"]*"' | awk -F'"' '{print $4}' | grep -F "$pattern" || true)

  if [[ -z "$matches" ]]; then
    log_info "$op" "No StatefulSets matching '$pattern'"
    response_ok "$op" "No StatefulSets matched" "{\"namespace\":\"$K8S_NAMESPACE\",\"pattern\":\"$pattern\",\"matches\":[]}"
    return 0
  fi

  local json_array
  json_array=$(echo "$matches" | awk '{printf "\"%s\",", $0}' | sed 's/,$//')
  log_info "$op" "Found StatefulSets matching '$pattern'"
  response_ok "$op" "StatefulSets matched" "{\"namespace\":\"$K8S_NAMESPACE\",\"pattern\":\"$pattern\",\"matches\":[${json_array}]}"
}

# ---------------------------------------------------------------------------
# k8s_get_sts_detail <sts_name>
# Get full JSON detail of a single StatefulSet.
# Returns: JSON response
# ---------------------------------------------------------------------------
k8s_get_sts_detail() {
  local sts_name="${1:?sts_name is required}"
  local op="k8s_get_sts_detail"
  log_info "$op" "Getting detail of StatefulSet '$sts_name'"

  local out
  if ! out=$(_kubectl get statefulset "$sts_name" -o json 2>&1); then
    log_error "$op" "StatefulSet '$sts_name' not found: $out"
    response_err "$op" "StatefulSet not found" "{\"sts\":\"$sts_name\",\"detail\":\"$(_escape_json_string "$out")\"}" 1
    return 1
  fi

  response_ok "$op" "StatefulSet detail retrieved" "{\"sts\":\"$sts_name\",\"raw\":$out}"
}

# ---------------------------------------------------------------------------
# k8s_scale_sts <sts_name> <replicas>
# Scale a StatefulSet to the given replica count.
# Returns: JSON response
# ---------------------------------------------------------------------------
k8s_scale_sts() {
  local sts_name="${1:?sts_name is required}"
  local replicas="${2:?replicas is required}"
  local op="k8s_scale_sts"
  log_info "$op" "Scaling StatefulSet '$sts_name' to $replicas replica(s)"

  local out
  if ! out=$(_kubectl scale statefulset "$sts_name" --replicas="$replicas" 2>&1); then
    log_error "$op" "Failed to scale StatefulSet '$sts_name': $out"
    response_err "$op" "Failed to scale StatefulSet" "{\"sts\":\"$sts_name\",\"replicas\":$replicas,\"detail\":\"$(_escape_json_string "$out")\"}" 1
    return 1
  fi

  log_info "$op" "StatefulSet '$sts_name' scaled to $replicas"
  response_ok "$op" "StatefulSet scaled" "{\"sts\":\"$sts_name\",\"replicas\":$replicas}"
}

# ---------------------------------------------------------------------------
# k8s_get_deployments [label_selector]
# List Deployments in the current namespace.
# Returns: JSON response
# ---------------------------------------------------------------------------
k8s_get_deployments() {
  local selector="${1:-}"
  local op="k8s_get_deployments"
  log_info "$op" "Listing Deployments in namespace '$K8S_NAMESPACE' selector='${selector:-all}'"

  local args=(-o json)
  [[ -n "$selector" ]] && args+=(-l "$selector")

  local out
  if ! out=$(_kubectl get deployment "${args[@]}" 2>&1); then
    log_error "$op" "Failed to list Deployments: $out"
    response_err "$op" "Failed to list Deployments" "{\"detail\":\"$(_escape_json_string "$out")\"}" 1
    return 1
  fi

  response_ok "$op" "Deployments retrieved" "{\"namespace\":\"$K8S_NAMESPACE\",\"selector\":\"${selector:-all}\",\"raw\":$out}"
}

# ---------------------------------------------------------------------------
# k8s_scale_deployment <deploy_name> <replicas>
# Scale a Deployment to the given replica count.
# Returns: JSON response
# ---------------------------------------------------------------------------
k8s_scale_deployment() {
  local deploy_name="${1:?deploy_name is required}"
  local replicas="${2:?replicas is required}"
  local op="k8s_scale_deployment"
  log_info "$op" "Scaling Deployment '$deploy_name' to $replicas replica(s)"

  local out
  if ! out=$(_kubectl scale deployment "$deploy_name" --replicas="$replicas" 2>&1); then
    log_error "$op" "Failed to scale Deployment '$deploy_name': $out"
    response_err "$op" "Failed to scale Deployment" "{\"deployment\":\"$deploy_name\",\"replicas\":$replicas,\"detail\":\"$(_escape_json_string "$out")\"}" 1
    return 1
  fi

  log_info "$op" "Deployment '$deploy_name' scaled to $replicas"
  response_ok "$op" "Deployment scaled" "{\"deployment\":\"$deploy_name\",\"replicas\":$replicas}"
}

# ---------------------------------------------------------------------------
# k8s_get_services [label_selector]
# List Services in the current namespace.
# Returns: JSON response
# ---------------------------------------------------------------------------
k8s_get_services() {
  local selector="${1:-}"
  local op="k8s_get_services"
  log_info "$op" "Listing Services in namespace '$K8S_NAMESPACE' selector='${selector:-all}'"

  local args=(-o json)
  [[ -n "$selector" ]] && args+=(-l "$selector")

  local out
  if ! out=$(_kubectl get service "${args[@]}" 2>&1); then
    log_error "$op" "Failed to list Services: $out"
    response_err "$op" "Failed to list Services" "{\"detail\":\"$(_escape_json_string "$out")\"}" 1
    return 1
  fi

  response_ok "$op" "Services retrieved" "{\"namespace\":\"$K8S_NAMESPACE\",\"selector\":\"${selector:-all}\",\"raw\":$out}"
}

# ---------------------------------------------------------------------------
# k8s_get_nodes
# List all cluster nodes.
# Returns: JSON response
# ---------------------------------------------------------------------------
k8s_get_nodes() {
  local op="k8s_get_nodes"
  log_info "$op" "Listing cluster nodes"

  local out
  if ! out=$(_kubectl_global get nodes -o json 2>&1); then
    log_error "$op" "Failed to list nodes: $out"
    response_err "$op" "Failed to list nodes" "{\"detail\":\"$(_escape_json_string "$out")\"}" 1
    return 1
  fi

  response_ok "$op" "Nodes retrieved" "{\"raw\":$out}"
}

# ---------------------------------------------------------------------------
# k8s_describe <resource_type> <resource_name>
# Describe a Kubernetes resource (output as plain text embedded in JSON).
# Returns: JSON response
# ---------------------------------------------------------------------------
k8s_describe() {
  local resource_type="${1:?resource_type is required}"
  local resource_name="${2:?resource_name is required}"
  local op="k8s_describe"
  log_info "$op" "Describing $resource_type '$resource_name'"

  local out
  if ! out=$(_kubectl describe "$resource_type" "$resource_name" 2>&1); then
    log_error "$op" "Failed to describe $resource_type '$resource_name': $out"
    response_err "$op" "Failed to describe resource" "{\"resource_type\":\"$resource_type\",\"resource_name\":\"$resource_name\"}" 1
    return 1
  fi

  # Escape newlines for JSON
  local escaped_out
  escaped_out=$(echo "$out" | sed ':a;N;$!ba;s/\n/\\n/g' | sed 's/"/\\"/g')
  response_ok "$op" "Resource described" "{\"resource_type\":\"$resource_type\",\"resource_name\":\"$resource_name\",\"description\":\"${escaped_out}\"}"
}

# ---------------------------------------------------------------------------
# k8s_get_pod_logs <pod_name> [container] [tail_lines]
# Retrieve logs from a pod (optionally a specific container).
# tail_lines defaults to 100.
# Returns: JSON response with logs embedded as string.
# ---------------------------------------------------------------------------
k8s_get_pod_logs() {
  local pod_name="${1:?pod_name is required}"
  local container="${2:-}"
  local tail="${3:-100}"
  local op="k8s_get_pod_logs"
  log_info "$op" "Getting logs from pod '$pod_name' container='${container:-default}' tail=$tail"

  local args=("$pod_name" "--tail=$tail")
  [[ -n "$container" ]] && args+=(-c "$container")

  local out
  if ! out=$(_kubectl logs "${args[@]}" 2>&1); then
    log_error "$op" "Failed to get logs from pod '$pod_name': $out"
    response_err "$op" "Failed to get pod logs" "{\"pod\":\"$pod_name\",\"detail\":\"$(_escape_json_string "$out")\"}" 1
    return 1
  fi

  local escaped_out
  escaped_out=$(echo "$out" | sed ':a;N;$!ba;s/\n/\\n/g' | sed 's/"/\\"/g')
  response_ok "$op" "Pod logs retrieved" "{\"pod\":\"$pod_name\",\"container\":\"${container:-}\",\"tail\":$tail,\"logs\":\"${escaped_out}\"}"
}

# ---------------------------------------------------------------------------
# k8s_exec <pod_name> <command...>
# Execute a command inside a pod (non-interactive).
# Returns: JSON response with stdout/stderr output.
# ---------------------------------------------------------------------------
k8s_exec() {
  local pod_name="${1:?pod_name is required}"
  shift
  local cmd=("$@")
  local op="k8s_exec"
  log_info "$op" "Executing command in pod '$pod_name': ${cmd[*]}"

  local out
  if ! out=$(_kubectl exec "$pod_name" -- "${cmd[@]}" 2>&1); then
    log_error "$op" "Command failed in pod '$pod_name': $out"
    response_err "$op" "Command execution failed" "{\"pod\":\"$pod_name\",\"command\":\"$(_escape_json_string "${cmd[*]}")\",\"output\":\"$(_escape_json_string "$out")\"}" 1
    return 1
  fi

  local escaped_out
  escaped_out=$(echo "$out" | sed ':a;N;$!ba;s/\n/\\n/g' | sed 's/"/\\"/g')
  response_ok "$op" "Command executed" "{\"pod\":\"$pod_name\",\"command\":\"$(_escape_json_string "${cmd[*]}")\",\"output\":\"${escaped_out}\"}"
}

# ---------------------------------------------------------------------------
# k8s_apply <manifest_file>
# Apply a Kubernetes manifest file.
# Returns: JSON response
# ---------------------------------------------------------------------------
k8s_apply() {
  local manifest="${1:?manifest_file is required}"
  local op="k8s_apply"
  log_info "$op" "Applying manifest: $manifest"

  if [[ ! -f "$manifest" ]]; then
    log_error "$op" "Manifest file not found: $manifest"
    response_err "$op" "Manifest file not found" "{\"file\":\"$manifest\"}" 1
    return 1
  fi

  local out
  if ! out=$(_kubectl apply -f "$manifest" 2>&1); then
    log_error "$op" "Failed to apply manifest '$manifest': $out"
    response_err "$op" "Failed to apply manifest" "{\"file\":\"$manifest\",\"detail\":\"$(_escape_json_string "$out")\"}" 1
    return 1
  fi

  local escaped_out
  escaped_out=$(echo "$out" | sed ':a;N;$!ba;s/\n/\\n/g' | sed 's/"/\\"/g')
  response_ok "$op" "Manifest applied" "{\"file\":\"$manifest\",\"output\":\"${escaped_out}\"}"
}

# ---------------------------------------------------------------------------
# k8s_delete_resource <resource_type> <resource_name>
# Delete a specific Kubernetes resource.
# Returns: JSON response
# ---------------------------------------------------------------------------
k8s_delete_resource() {
  local resource_type="${1:?resource_type is required}"
  local resource_name="${2:?resource_name is required}"
  local op="k8s_delete_resource"
  log_info "$op" "Deleting $resource_type '$resource_name' in namespace '$K8S_NAMESPACE'"

  local out
  if ! out=$(_kubectl delete "$resource_type" "$resource_name" 2>&1); then
    log_error "$op" "Failed to delete $resource_type '$resource_name': $out"
    response_err "$op" "Failed to delete resource" "{\"resource_type\":\"$resource_type\",\"resource_name\":\"$resource_name\",\"detail\":\"$(_escape_json_string "$out")\"}" 1
    return 1
  fi

  response_ok "$op" "Resource deleted" "{\"resource_type\":\"$resource_type\",\"resource_name\":\"$resource_name\"}"
}

# ---------------------------------------------------------------------------
# k8s_get_events [resource_name]
# Get events in the current namespace, optionally filtered by resource name.
# Returns: JSON response
# ---------------------------------------------------------------------------
k8s_get_events() {
  local resource_name="${1:-}"
  local op="k8s_get_events"
  log_info "$op" "Getting events in namespace '$K8S_NAMESPACE' resource='${resource_name:-all}'"

  local args=(get events -o json)
  [[ -n "$resource_name" ]] && args+=(--field-selector "involvedObject.name=${resource_name}")

  local out
  if ! out=$(_kubectl "${args[@]}" 2>&1); then
    log_error "$op" "Failed to get events: $out"
    response_err "$op" "Failed to get events" "{\"detail\":\"$(_escape_json_string "$out")\"}" 1
    return 1
  fi

  response_ok "$op" "Events retrieved" "{\"namespace\":\"$K8S_NAMESPACE\",\"resource\":\"${resource_name:-all}\",\"raw\":$out}"
}

# ---------------------------------------------------------------------------
# k8s_rollout_status <resource_type> <resource_name>
# Wait for a rollout to complete and return its status.
# resource_type: deployment | statefulset | daemonset
# Returns: JSON response
# ---------------------------------------------------------------------------
k8s_rollout_status() {
  local resource_type="${1:?resource_type is required}"
  local resource_name="${2:?resource_name is required}"
  local op="k8s_rollout_status"
  log_info "$op" "Getting rollout status for $resource_type '$resource_name'"

  local out
  if ! out=$(_kubectl rollout status "$resource_type/$resource_name" --timeout=120s 2>&1); then
    log_error "$op" "Rollout not complete for $resource_type '$resource_name': $out"
    response_err "$op" "Rollout not complete" "{\"resource_type\":\"$resource_type\",\"resource_name\":\"$resource_name\",\"detail\":\"$(_escape_json_string "$out")\"}" 1
    return 1
  fi

  response_ok "$op" "Rollout complete" "{\"resource_type\":\"$resource_type\",\"resource_name\":\"$resource_name\",\"status\":\"complete\"}"
}

# ---------------------------------------------------------------------------
# k8s_rollout_restart <resource_type> <resource_name>
# Trigger a rolling restart of a Deployment/StatefulSet/DaemonSet.
# Returns: JSON response
# ---------------------------------------------------------------------------
k8s_rollout_restart() {
  local resource_type="${1:?resource_type is required}"
  local resource_name="${2:?resource_name is required}"
  local op="k8s_rollout_restart"
  log_info "$op" "Restarting $resource_type '$resource_name'"

  local out
  if ! out=$(_kubectl rollout restart "$resource_type/$resource_name" 2>&1); then
    log_error "$op" "Failed to restart $resource_type '$resource_name': $out"
    response_err "$op" "Failed to restart rollout" "{\"resource_type\":\"$resource_type\",\"resource_name\":\"$resource_name\",\"detail\":\"$(_escape_json_string "$out")\"}" 1
    return 1
  fi

  response_ok "$op" "Rollout restart triggered" "{\"resource_type\":\"$resource_type\",\"resource_name\":\"$resource_name\"}"
}

# ---------------------------------------------------------------------------
# k8s_get_configmap <cm_name>
# Get a ConfigMap and return its data.
# Returns: JSON response
# ---------------------------------------------------------------------------
k8s_get_configmap() {
  local cm_name="${1:?cm_name is required}"
  local op="k8s_get_configmap"
  log_info "$op" "Getting ConfigMap '$cm_name'"

  local out
  if ! out=$(_kubectl get configmap "$cm_name" -o json 2>&1); then
    log_error "$op" "ConfigMap '$cm_name' not found: $out"
    response_err "$op" "ConfigMap not found" "{\"configmap\":\"$cm_name\",\"detail\":\"$(_escape_json_string "$out")\"}" 1
    return 1
  fi

  response_ok "$op" "ConfigMap retrieved" "{\"configmap\":\"$cm_name\",\"raw\":$out}"
}

# ---------------------------------------------------------------------------
# k8s_get_secret <secret_name>
# Get a Secret (data will be base64-encoded as returned by the API).
# Returns: JSON response
# ---------------------------------------------------------------------------
k8s_get_secret() {
  local secret_name="${1:?secret_name is required}"
  local op="k8s_get_secret"
  log_info "$op" "Getting Secret '$secret_name'"

  local out
  if ! out=$(_kubectl get secret "$secret_name" -o json 2>&1); then
    log_error "$op" "Secret '$secret_name' not found: $out"
    response_err "$op" "Secret not found" "{\"secret\":\"$secret_name\",\"detail\":\"$(_escape_json_string "$out")\"}" 1
    return 1
  fi

  response_ok "$op" "Secret retrieved" "{\"secret\":\"$secret_name\",\"raw\":$out}"
}

# ---------------------------------------------------------------------------
# k8s_top_pods
# Get CPU/memory usage of pods (requires metrics-server).
# Returns: JSON response with raw text output.
# ---------------------------------------------------------------------------
k8s_top_pods() {
  local op="k8s_top_pods"
  log_info "$op" "Getting pod resource usage in namespace '$K8S_NAMESPACE'"

  local out
  if ! out=$(_kubectl top pods 2>&1); then
    log_error "$op" "Failed to get pod resource usage: $out"
    response_err "$op" "Failed to get pod resource usage" "{\"detail\":\"$(_escape_json_string "$out")\"}" 1
    return 1
  fi

  local escaped_out
  escaped_out=$(echo "$out" | sed ':a;N;$!ba;s/\n/\\n/g' | sed 's/"/\\"/g')
  response_ok "$op" "Pod resource usage retrieved" "{\"namespace\":\"$K8S_NAMESPACE\",\"usage\":\"${escaped_out}\"}"
}

# ---------------------------------------------------------------------------
# k8s_port_forward <resource> <local_port> <remote_port> [background]
# Port-forward a pod/service port to localhost.
# Set background="true" to run in background (returns PID in data).
# CAUTION: background processes must be managed by the caller.
# Returns: JSON response
# ---------------------------------------------------------------------------
k8s_port_forward() {
  local resource="${1:?resource is required (e.g. pod/mypod or svc/mysvc)}"
  local local_port="${2:?local_port is required}"
  local remote_port="${3:?remote_port is required}"
  local background="${4:-false}"
  local op="k8s_port_forward"
  log_info "$op" "Port-forwarding $resource $local_port->$remote_port (background=$background)"

  if [[ "$background" == "true" ]]; then
    _kubectl port-forward "$resource" "${local_port}:${remote_port}" &>/dev/null &
    local pid=$!
    log_info "$op" "Port-forward running in background (PID=$pid)"
    response_ok "$op" "Port-forward started in background" "{\"resource\":\"$resource\",\"local_port\":$local_port,\"remote_port\":$remote_port,\"pid\":$pid}"
  else
    local out
    if ! out=$(_kubectl port-forward "$resource" "${local_port}:${remote_port}" 2>&1); then
      log_error "$op" "Port-forward failed: $out"
      response_err "$op" "Port-forward failed" "{\"resource\":\"$resource\",\"detail\":\"$(_escape_json_string "$out")\"}" 1
      return 1
    fi
    response_ok "$op" "Port-forward completed" "{\"resource\":\"$resource\",\"local_port\":$local_port,\"remote_port\":$remote_port}"
  fi
}

# ---------------------------------------------------------------------------
# k8s_sts_pod_names <sts_name>
# List all pod names that belong to a StatefulSet (by label selector derived
# from the STS spec).  Falls back to name-prefix matching.
# Returns: JSON response with array of pod names.
# ---------------------------------------------------------------------------
k8s_sts_pod_names() {
  local sts_name="${1:?sts_name is required}"
  local op="k8s_sts_pod_names"
  log_info "$op" "Listing pod names for StatefulSet '$sts_name' in namespace '$K8S_NAMESPACE'"

  # Retrieve match-labels from the STS spec
  local selector_out
  selector_out=$(_kubectl get statefulset "$sts_name" \
    -o jsonpath='{range .spec.selector.matchLabels}{@}{"\n"}{end}' 2>&1) || true

  local pod_out
  # Try label selector first; fall back to name prefix if selector is empty
  if [[ -n "$selector_out" ]]; then
    local label_selector
    label_selector=$(_kubectl get statefulset "$sts_name" \
      -o go-template='{{range $k,$v := .spec.selector.matchLabels}}{{$k}}={{$v}},{{end}}' 2>&1 | sed 's/,$//')
    if ! pod_out=$(_kubectl get pods -l "$label_selector" \
        -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>&1); then
      log_error "$op" "Failed to list pods for STS '$sts_name': $pod_out"
      response_err "$op" "Failed to list STS pods" "{\"sts\":\"$sts_name\",\"detail\":\"$pod_out\"}" 1
      return 1
    fi
  else
    if ! pod_out=$(_kubectl get pods \
        -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>&1 | \
        grep "^${sts_name}-" || true); then
      log_error "$op" "Failed to list pods for STS '$sts_name': $pod_out"
      response_err "$op" "Failed to list STS pods" "{\"sts\":\"$sts_name\",\"detail\":\"$pod_out\"}" 1
      return 1
    fi
  fi

  local json_array=""
  if [[ -n "$pod_out" ]]; then
    json_array=$(echo "$pod_out" | awk '{printf "\"%s\",", $0}' | sed 's/,$//')
  fi
  response_ok "$op" "STS pod names retrieved" \
    "{\"sts\":\"$sts_name\",\"namespace\":\"$K8S_NAMESPACE\",\"pods\":[${json_array}]}"
}

# ---------------------------------------------------------------------------
# k8s_sts_all_pods_ready <sts_name>
# Check whether all desired replicas of a StatefulSet are Ready.
# Returns: JSON response; data.ready=true when readyReplicas == replicas.
# ---------------------------------------------------------------------------
k8s_sts_all_pods_ready() {
  local sts_name="${1:?sts_name is required}"
  local op="k8s_sts_all_pods_ready"
  log_info "$op" "Checking if all pods of StatefulSet '$sts_name' are Ready"

  local out
  if ! out=$(_kubectl get statefulset "$sts_name" -o json 2>&1); then
    log_error "$op" "StatefulSet '$sts_name' not found: $out"
    response_err "$op" "StatefulSet not found" "{\"sts\":\"$sts_name\",\"detail\":\"$(_escape_json_string "$out")\"}" 1
    return 1
  fi

  local desired ready
  desired=$(echo "$out" | grep -o '"replicas": *[0-9]*' | head -1 | grep -o '[0-9]*$')
  ready=$(echo "$out" | grep -o '"readyReplicas": *[0-9]*' | head -1 | grep -o '[0-9]*$')

  desired="${desired:-0}"
  ready="${ready:-0}"

  local is_ready="false"
  if [[ "$desired" -gt 0 && "$ready" -eq "$desired" ]]; then
    is_ready="true"
  fi

  log_info "$op" "STS '$sts_name': desired=$desired ready=$ready allReady=$is_ready"
  response_ok "$op" "STS pod readiness checked" \
    "{\"sts\":\"$sts_name\",\"namespace\":\"$K8S_NAMESPACE\",\"desired\":${desired},\"ready\":${ready},\"allReady\":${is_ready}}"
}

# ---------------------------------------------------------------------------
# k8s_wait_sts_ready <sts_name> [timeout_seconds]
# Poll until all pods of a StatefulSet are Ready, or timeout is reached.
# timeout_seconds defaults to 300 (5 minutes).
# Returns: JSON response
# ---------------------------------------------------------------------------
k8s_wait_sts_ready() {
  local sts_name="${1:?sts_name is required}"
  local timeout="${2:-300}"
  local op="k8s_wait_sts_ready"
  log_info "$op" "Waiting up to ${timeout}s for all pods of STS '$sts_name' to be Ready"

  local start elapsed
  start=$(date +%s)
  while true; do
    elapsed=$(( $(date +%s) - start ))
    if (( elapsed >= timeout )); then
      log_error "$op" "Timed out after ${timeout}s waiting for STS '$sts_name' to be Ready"
      response_err "$op" "Timed out waiting for STS ready" \
        "{\"sts\":\"$sts_name\",\"timeout\":${timeout}}" 1
      return 1
    fi

    local check_out desired ready
    check_out=$(_kubectl get statefulset "$sts_name" -o json 2>/dev/null) || true
    desired=$(echo "$check_out" | grep -o '"replicas": *[0-9]*' | head -1 | grep -o '[0-9]*$')
    ready=$(echo "$check_out" | grep -o '"readyReplicas": *[0-9]*' | head -1 | grep -o '[0-9]*$')
    desired="${desired:-0}"; ready="${ready:-0}"

    if [[ "$desired" -gt 0 && "$ready" -eq "$desired" ]]; then
      log_info "$op" "STS '$sts_name' is fully Ready (${ready}/${desired}) after ${elapsed}s"
      response_ok "$op" "STS is fully Ready" \
        "{\"sts\":\"$sts_name\",\"desired\":${desired},\"ready\":${ready},\"elapsed_seconds\":${elapsed}}"
      return 0
    fi
    log_debug "$op" "STS '$sts_name' not ready yet (${ready:-0}/${desired:-0}), elapsed=${elapsed}s"
    sleep 5
  done
}

# ---------------------------------------------------------------------------
# k8s_get_pvc [label_selector]
# List PersistentVolumeClaims in the current namespace.
# Returns: JSON response with raw PVC list.
# ---------------------------------------------------------------------------
k8s_get_pvc() {
  local selector="${1:-}"
  local op="k8s_get_pvc"
  log_info "$op" "Listing PVCs in namespace '$K8S_NAMESPACE' selector='${selector:-all}'"

  local args=(-o json)
  [[ -n "$selector" ]] && args+=(-l "$selector")

  local out
  if ! out=$(_kubectl get pvc "${args[@]}" 2>&1); then
    log_error "$op" "Failed to list PVCs: $out"
    response_err "$op" "Failed to list PVCs" "{\"detail\":\"$(_escape_json_string "$out")\"}" 1
    return 1
  fi

  response_ok "$op" "PVCs retrieved" \
    "{\"namespace\":\"$K8S_NAMESPACE\",\"selector\":\"${selector:-all}\",\"raw\":$out}"
}

# ---------------------------------------------------------------------------
# k8s_get_pvc_detail <pvc_name>
# Get full detail of a single PVC including capacity and phase.
# Returns: JSON response with name, phase, capacity, storageClass.
# ---------------------------------------------------------------------------
k8s_get_pvc_detail() {
  local pvc_name="${1:?pvc_name is required}"
  local op="k8s_get_pvc_detail"
  log_info "$op" "Getting detail for PVC '$pvc_name'"

  local out
  if ! out=$(_kubectl get pvc "$pvc_name" -o json 2>&1); then
    log_error "$op" "PVC '$pvc_name' not found: $out"
    response_err "$op" "PVC not found" "{\"pvc\":\"$pvc_name\",\"detail\":\"$(_escape_json_string "$out")\"}" 1
    return 1
  fi

  local phase capacity storage_class
  phase=$(echo "$out" | grep -o '"phase":"[^"]*"' | head -1 | cut -d'"' -f4)
  capacity=$(echo "$out" | grep -o '"storage":"[^"]*"' | head -1 | cut -d'"' -f4)
  storage_class=$(echo "$out" | grep -o '"storageClassName":"[^"]*"' | head -1 | cut -d'"' -f4)

  response_ok "$op" "PVC detail retrieved" \
    "{\"pvc\":\"$pvc_name\",\"namespace\":\"$K8S_NAMESPACE\",\"phase\":\"${phase:-unknown}\",\"capacity\":\"${capacity:-unknown}\",\"storageClass\":\"${storage_class:-}\",\"raw\":$out}"
}

# ---------------------------------------------------------------------------
# k8s_check_pvc_usage <pod_name> <mount_path> [warn_percent]
# Check disk usage of a volume mount path inside a running pod.
# Executes `df` inside the pod and returns usage percentage.
# warn_percent: threshold above which the response message warns. Default 80.
# Returns: JSON response with used_percent, warn fields.
# ---------------------------------------------------------------------------
k8s_check_pvc_usage() {
  local pod_name="${1:?pod_name is required}"
  local mount_path="${2:?mount_path is required}"
  local warn_pct="${3:-80}"
  local op="k8s_check_pvc_usage"
  log_info "$op" "Checking disk usage at '$mount_path' in pod '$pod_name'"

  local df_out
  if ! df_out=$(_kubectl exec "$pod_name" -- df -h "$mount_path" 2>&1); then
    log_error "$op" "Failed to run df in pod '$pod_name': $df_out"
    response_err "$op" "Failed to get disk usage" \
      "{\"pod\":\"$pod_name\",\"mount_path\":\"$mount_path\",\"detail\":\"$df_out\"}" 1
    return 1
  fi

  # Parse the percentage from df output (column 5, strip %)
  local used_pct
  used_pct=$(echo "$df_out" | awk 'NR==2{gsub(/%/,"",$5); print $5}')
  used_pct="${used_pct:-0}"

  local warn="false"
  if (( used_pct >= warn_pct )); then
    warn="true"
    log_error "$op" "PVC usage at $mount_path in pod $pod_name is ${used_pct}% (threshold: ${warn_pct}%)"
  else
    log_info "$op" "PVC usage at $mount_path in pod $pod_name is ${used_pct}% (threshold: ${warn_pct}%)"
  fi

  response_ok "$op" "PVC usage checked" \
    "{\"pod\":\"$pod_name\",\"mount_path\":\"$mount_path\",\"used_percent\":${used_pct},\"warn_threshold\":${warn_pct},\"warn\":${warn}}"
}

# ---------------------------------------------------------------------------
# k8s_sts_restart <sts_name> [pod_selector] [timeout_seconds]
# Restart a StatefulSet and wait for all pods to be Ready.
#
# Automatically detects updateStrategy:
#   RollingUpdate — kubectl rollout restart + rollout status
#   OnDelete      — kubectl rollout restart, then wait for pods to cycle
#                   (operator deletes/recreates pods; rollout status unsupported)
#
# pod_selector: label selector for kubectl wait (OnDelete only).
#               defaults to "app.kubernetes.io/name=<sts_name>"
# timeout_seconds: defaults to 300
#
# Returns: JSON response with ready/replicas counts
# ---------------------------------------------------------------------------
k8s_sts_restart() {
  local sts_name="${1:?sts_name is required}"
  local pod_selector="${2:-}"
  local timeout="${3:-300}"
  local op="k8s_sts_restart"

  log_info "$op" "Restarting StatefulSet '$sts_name' in namespace '$K8S_NAMESPACE'"

  # Trigger restart
  local out
  if ! out=$(_kubectl rollout restart statefulset "$sts_name" 2>&1); then
    log_error "$op" "Failed to restart StatefulSet '$sts_name': $out"
    response_err "$op" "Failed to restart StatefulSet" \
      "{\"sts\":\"$sts_name\",\"detail\":\"$(echo "$out" | head -1)\"}" 1
    return 1
  fi

  # Single snapshot read of strategy/replicas/partition — avoids the TOCTOU
  # risk of separate sequential `kubectl get` calls, each of which could
  # observe a different point in time if another actor (e.g. mongodb
  # recovery's own partition patches) mutates the StatefulSet in between.
  local sts_json strategy replicas_spec partition
  sts_json=$(_kubectl get statefulset "$sts_name" -o json 2>/dev/null) || sts_json="{}"
  strategy=$(echo "$sts_json" | jq -r '.spec.updateStrategy.type // "RollingUpdate"')
  strategy="${strategy:-RollingUpdate}"
  replicas_spec=$(echo "$sts_json" | jq -r '.spec.replicas // empty')
  partition=$(echo "$sts_json" | jq -r '.spec.updateStrategy.rollingUpdate.partition // empty')
  log_debug "$op" "Detected updateStrategy for '$sts_name': $strategy"
  log_info "$op" "Update strategy: $strategy"

  if [[ "$strategy" == "OnDelete" ]]; then
    # OnDelete: rollout status is unsupported — operator deletes/recreates pods
    local selector="${pod_selector:-app.kubernetes.io/name=${sts_name}}"
    log_debug "$op" "OnDelete pod_selector resolution: ${pod_selector:+explicit=\"${pod_selector}\"}${pod_selector:-default=\"app.kubernetes.io/name=${sts_name}\"} -> using \"${selector}\""
    log_info "$op" "OnDelete: waiting for pods to cycle (selector: $selector)"
    sleep 5
    # Wait for at least one pod to go NotReady (operator has deleted the old pod)
    log_debug "$op" "Waiting up to 60s for a pod matching '$selector' to go NotReady (operator/manual pod cycle)"
    # Both waits below capture combined stdout+stderr into a variable rather
    # than letting kubectl print directly — this function's stdout is
    # captured wholesale by callers via `result=$(k8s_sts_restart ...)`
    # (see mongodb/restart.sh), so an uncaptured "pod/x condition met" line
    # from kubectl would get prepended to the JSON response and break the
    # caller's `jq` parse (jq exit 4 on invalid JSON, fatal under set -e).
    out=$(_kubectl wait pod \
      --for=condition=Ready=False \
      --selector="$selector" \
      --timeout=60s 2>&1) || true
    # Wait for all pods to be Ready again
    log_debug "$op" "Waiting up to ${timeout}s for all pods matching '$selector' to be Ready again"
    if ! out=$(_kubectl wait pod \
        --for=condition=Ready \
        --selector="$selector" \
        --timeout="${timeout}s" 2>&1); then
      log_error "$op" "Pods did not become Ready within ${timeout}s: $out"
      response_err "$op" "Pods did not become Ready" \
        "{\"sts\":\"$sts_name\",\"timeout\":${timeout},\"detail\":\"$(echo "$out" | head -1)\"}" 1
      return 1
    fi
  else
    # RollingUpdate: a rollingUpdate.partition left at/above the replica
    # count (e.g. the locked resting state MongoDB recovery/wipe leaves a
    # StatefulSet in between wipes — see mongodb-recovery.sh's
    # recovery_reset, which deliberately restores partition to the replica
    # count) makes `kubectl rollout status` report success immediately
    # (updatedReplicas >= replicas-partition is already true) without any
    # pod ever rolling. Detect and unlock it so restart actually restarts.
    local partition_reset="false"
    log_debug "$op" "rollingUpdate.partition for '$sts_name': ${partition:-<unset>} (spec.replicas: ${replicas_spec:-<unset>})"

    if [[ -n "$partition" && -n "$replicas_spec" && "$partition" -ge "$replicas_spec" ]]; then
      log_info "$op" "rollingUpdate.partition ($partition) >= replicas ($replicas_spec) — would block every pod from rolling; resetting partition to 0"
      if ! out=$(_kubectl patch statefulset "$sts_name" --type=merge \
          -p '{"spec":{"updateStrategy":{"rollingUpdate":{"partition":0}}}}' 2>&1); then
        log_error "$op" "Failed to reset stuck partition on '$sts_name': $out"
        response_err "$op" "Failed to reset stuck rollingUpdate.partition" \
          "{\"sts\":\"$sts_name\",\"partition\":${partition},\"replicas\":${replicas_spec},\"detail\":\"$(echo "$out" | head -1)\"}" 1
        return 1
      fi
      partition_reset="true"
    fi

    # RollingUpdate: standard rollout status
    if ! out=$(_kubectl rollout status statefulset "$sts_name" --timeout="${timeout}s" 2>&1); then
      log_error "$op" "Rollout did not complete within ${timeout}s: $out"
      response_err "$op" "Rollout timed out" \
        "{\"sts\":\"$sts_name\",\"timeout\":${timeout},\"detail\":\"$(echo "$out" | head -1)\"}" 1
      return 1
    fi
  fi

  local ready replicas
  ready=$(_kubectl get statefulset "$sts_name" \
    -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
  replicas=$(_kubectl get statefulset "$sts_name" \
    -o jsonpath='{.status.replicas}' 2>/dev/null || echo "0")
  ready="${ready:-0}"; replicas="${replicas:-0}"

  log_info "$op" "StatefulSet '$sts_name' restarted: ${ready}/${replicas} ready"
  response_ok "$op" "StatefulSet restarted" \
    "{\"sts\":\"$sts_name\",\"namespace\":\"$K8S_NAMESPACE\",\"strategy\":\"$strategy\",\"partition_reset\":${partition_reset:-false},\"ready\":${ready},\"replicas\":${replicas}}"
}

# ---------------------------------------------------------------------------
# check_k8s_layer
# Layer 1 of the MongoDB sanity check: Kubernetes infrastructure health.
# Checks cluster connectivity, node readiness, STS pod readiness, pod
# restart counts & conditions, PVC disk usage, and Warning events.
#
# Requires (from calling environment):
#   _sc_pass / _sc_warn / _sc_fail / _sc_section  — check result helpers
#   SC_PASS / SC_WARN / SC_FAIL                    — result counters
#   STS_NAME, K8S_NAMESPACE                        — set before calling
#   PVC_MOUNT_PATH, PVC_WARN_PERCENT, PVC_CRIT_PERCENT
#   RESTART_WARN_COUNT
# ---------------------------------------------------------------------------
check_k8s_layer() {
  _sc_section "Layer 1: Kubernetes Infrastructure"

  # 1a. cluster connectivity ─────────────────────────────────────────────────
  local r
  r=$(k8s_check 2>/dev/null)
  if [[ "$(_json_status "$r")" == "success" ]]; then
    _sc_pass "kubectl: cluster is reachable"
  else
    _sc_fail "kubectl: cannot reach cluster" "$(_json_field "$r" "message")"
    return 1
  fi

  # 1b. Node readiness + resource pressure ────────────────────────────────────
  local nodes_r nodes_json
  nodes_r=$(k8s_get_nodes 2>/dev/null)
  nodes_json=$(echo "$nodes_r" | grep -o '"raw":{.*' | sed 's/"raw"://') || nodes_json=""
  if [[ "$(_json_status "$nodes_r")" == "success" && -n "$nodes_json" ]]; then
    local node_names
    node_names=$(echo "$nodes_json" | grep -o '"name":"[^"]*"' | \
      awk -F'"' '{print $4}' | grep -v 'kubernetes.io' | head -50 || true)
    local node_count=0 node_not_ready=0 node_pressure=0
    local n
    for n in $node_names; do
      node_count=$(( node_count + 1 ))
      local node_j
      node_j=$(_kubectl get node "$n" -o json 2>/dev/null) || node_j=""
      [[ -z "$node_j" ]] && continue

      local ready_status
      ready_status=$(echo "$node_j" | \
        jq -r '.status.conditions[] | select(.type == "Ready") | .status' 2>/dev/null) || ready_status=""
      if [[ "$ready_status" != "True" ]]; then
        _sc_fail "Node '$n': Not Ready (status=${ready_status:-unknown})"
        node_not_ready=$(( node_not_ready + 1 ))
      fi

      local pressure_types=("MemoryPressure" "DiskPressure" "PIDPressure")
      local pt
      for pt in "${pressure_types[@]}"; do
        local pt_status
        pt_status=$(echo "$node_j" | \
          jq -r ".status.conditions[] | select(.type == \"${pt}\") | .status" 2>/dev/null) || pt_status=""
        if [[ "$pt_status" == "True" ]]; then
          _sc_warn "Node '$n': $pt is active — resource pressure on node"
          node_pressure=$(( node_pressure + 1 ))
        fi
      done
    done
    if [[ "$node_count" -gt 0 && "$node_not_ready" -eq 0 && "$node_pressure" -eq 0 ]]; then
      _sc_pass "Nodes: all ${node_count} node(s) Ready, no resource pressure"
    elif [[ "$node_count" -eq 0 ]]; then
      _sc_warn "Nodes: could not enumerate node list"
    fi
  else
    _sc_warn "Nodes: could not retrieve node list"
  fi

  # 1c. StatefulSet all pods ready ────────────────────────────────────────────
  r=$(k8s_sts_all_pods_ready "$STS_NAME" 2>/dev/null)
  if [[ "$(_json_status "$r")" == "success" ]]; then
    local desired ready all_ready
    desired=$(_json_field "$r" "desired")
    ready=$(_json_field "$r" "ready")
    all_ready=$(_json_field "$r" "allReady")
    if [[ "$all_ready" == "true" ]]; then
      _sc_pass "STS '$STS_NAME': all pods ready (${ready}/${desired})"
    else
      _sc_fail "STS '$STS_NAME': not all pods ready (${ready}/${desired})"
    fi
  else
    _sc_fail "STS '$STS_NAME': could not determine readiness" "$(_json_field "$r" "message")"
  fi

  # 1d. Pod conditions + restart counts ──────────────────────────────────────
  local pod_json
  pod_json=$(_kubectl get pods -l "app=${STS_NAME}" -o json 2>/dev/null) || \
  pod_json=$(_kubectl get pods -o json 2>/dev/null) || pod_json=""

  if [[ -n "$pod_json" ]]; then
    local pod_names
    pod_names=$(echo "$pod_json" | grep -o '"name":"[^"]*"' | \
      awk -F'"' '{print $4}' | grep "^${STS_NAME}-" | head -20 || true)
    if [[ -z "$pod_names" ]]; then
      pod_names=$(echo "$pod_json" | grep -o '"name":"[^"]*"' | \
        awk -F'"' '{print $4}' | grep -v 'kubernetes.io' | head -20 || true)
    fi

    local p
    for p in $pod_names; do
      local restart_count
      restart_count=$(echo "$pod_json" | grep -A 50 "\"name\":\"${p}\"" | \
        grep -o '"restartCount":[0-9]*' | head -1 | cut -d':' -f2 || echo "0")
      restart_count="${restart_count:-0}"
      if (( restart_count >= RESTART_WARN_COUNT )); then
        _sc_warn "Pod '$p': high restart count (${restart_count} >= ${RESTART_WARN_COUNT})" \
          "Frequent restarts may indicate OOM kills or crash loops"
      else
        _sc_pass "Pod '$p': restart count OK (${restart_count})"
      fi

      local pod_detail
      pod_detail=$(_kubectl get pod "$p" -o json 2>/dev/null) || pod_detail=""
      if [[ -n "$pod_detail" ]]; then
        local containers_ready scheduled
        containers_ready=$(echo "$pod_detail" | \
          jq -r '.status.conditions[] | select(.type == "ContainersReady") | .status' 2>/dev/null) || containers_ready=""
        scheduled=$(echo "$pod_detail" | \
          jq -r '.status.conditions[] | select(.type == "PodScheduled") | .status' 2>/dev/null) || scheduled=""
        if [[ "$scheduled" != "True" ]]; then
          _sc_fail "Pod '$p': not scheduled (PodScheduled=${scheduled:-unknown})" \
            "Check node resources, taints, or PVC binding"
        fi
        if [[ "$containers_ready" != "True" ]]; then
          _sc_warn "Pod '$p': containers not ready (ContainersReady=${containers_ready:-unknown})" \
            "Pod may be in init or a container is still starting"
        fi
      fi
    done
  else
    _sc_warn "Could not retrieve pod list for condition/restart checks"
  fi

  # 1e. PVC disk usage ────────────────────────────────────────────────────────
  local pod_list_r
  pod_list_r=$(k8s_sts_pod_names "$STS_NAME" 2>/dev/null)
  if [[ "$(_json_status "$pod_list_r")" == "success" ]]; then
    local pods_raw
    pods_raw=$(echo "$pod_list_r" | grep -o '"pods":\[[^]]*\]' | \
      sed 's/"pods":\[//' | sed 's/\]//' | tr ',' '\n' | tr -d '"' || true)
    local pod
    for pod in $pods_raw; do
      [[ -z "$pod" ]] && continue
      local usage_r
      usage_r=$(k8s_check_pvc_usage "$pod" "$PVC_MOUNT_PATH" "$PVC_WARN_PERCENT" 2>/dev/null) || {
        _sc_warn "Pod '$pod': could not check disk usage at $PVC_MOUNT_PATH"
        continue
      }
      if [[ "$(_json_status "$usage_r")" == "success" ]]; then
        local used_pct warn_flag
        used_pct=$(_json_field "$usage_r" "used_percent")
        warn_flag=$(_json_field "$usage_r" "warn")
        used_pct="${used_pct:-0}"
        if (( used_pct >= PVC_CRIT_PERCENT )); then
          _sc_fail "Pod '$pod' PVC $PVC_MOUNT_PATH: ${used_pct}% used (critical >= ${PVC_CRIT_PERCENT}%)" \
            "Disk full will halt MongoDB writes"
        elif [[ "$warn_flag" == "true" ]]; then
          _sc_warn "Pod '$pod' PVC $PVC_MOUNT_PATH: ${used_pct}% used (warn >= ${PVC_WARN_PERCENT}%)" \
            "Consider expanding the PVC or archiving data"
        else
          _sc_pass "Pod '$pod' PVC $PVC_MOUNT_PATH: ${used_pct}% used"
        fi
      else
        _sc_warn "Pod '$pod': disk usage check failed"
      fi
    done
  else
    _sc_warn "Could not list STS pod names – skipping PVC usage checks"
  fi

  # 1f. Kubernetes Warning events ─────────────────────────────────────────────
  local events_out
  events_out=$(_kubectl get events --field-selector type=Warning \
    -o jsonpath='{range .items[*]}{.reason}: {.message} [{.count}x] ({.involvedObject.name}){"\n"}{end}' \
    2>/dev/null) || events_out=""
  local event_count
  event_count=$(echo "$events_out" | grep -c . 2>/dev/null || echo "0")
  event_count="${event_count//[[:space:]]/}"
  if [[ "$event_count" -gt 0 ]]; then
    _sc_warn "K8s Warning events: ${event_count} event(s) in namespace '${K8S_NAMESPACE}'" \
      "Run: kubectl get events -n ${K8S_NAMESPACE} --field-selector type=Warning"
    local shown=0
    while IFS= read -r line && [[ $shown -lt 5 ]]; do
      [[ -z "$line" ]] && continue
      printf '           ⚠  %s\n' "$line"
      shown=$(( shown + 1 ))
    done <<< "$events_out"
    [[ "$event_count" -gt 5 ]] && printf '           … and %d more\n' $(( event_count - 5 ))
  else
    _sc_pass "K8s Warning events: none in namespace '${K8S_NAMESPACE}'"
  fi
}
