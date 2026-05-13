# lib/k8s.sh

Kubernetes helper functions using `kubectl`. Every function returns a JSON string via `response_ok` / `response_err`.

## Setup

```bash
source /tasks/lib/logging.sh
source /tasks/lib/response.sh
source /tasks/lib/k8s.sh

K8S_NAMESPACE="mongo-1"    # target namespace
K8S_KUBECONFIG=""          # empty = use in-cluster / KUBECONFIG env
```

## Connection Functions

### `k8s_check`

Verify that `kubectl` is available and the cluster is reachable.

**Returns**: `data.info` — first line of `cluster-info` output.

### `k8s_use_kubeconfig <path>`

Set the active kubeconfig file.

| Parameter | Required | Description |
|-----------|----------|-------------|
| path | yes | Absolute path to kubeconfig file |

---

## Namespace Functions

### `k8s_get_namespaces`

List all cluster namespaces.

**Returns**: `data.namespaces` — array of namespace names.

### `k8s_namespace_exists <namespace>`

**Returns**: `data.exists` — `true` / `false`.

### `k8s_create_namespace <namespace>`

Creates namespace if it does not already exist.

**Returns**: `data.created` — `true` if created, `false` if already existed.

---

## Pod Functions

### `k8s_get_pods [label_selector]`

List pods in `K8S_NAMESPACE`. Optional label selector e.g. `"app=mongodb"`.

### `k8s_get_pod_status <pod_name>`

Get phase, conditions, and containerStatuses for a pod.

### `k8s_get_pod_logs <pod_name> [container] [tail_lines]`

Retrieve pod logs.

### `k8s_exec <pod_name> <command...>`

Run a command inside a pod.

---

## StatefulSet Functions

### `k8s_get_sts [label_selector]`

List StatefulSets in `K8S_NAMESPACE`.

### `k8s_get_sts_detail <sts_name>`

Get full JSON of a single StatefulSet.

### `k8s_filter_sts_by_name <pattern>`

Filter StatefulSets whose name contains `pattern`.

**Returns**: `data.matches` — array of matching names.

### `k8s_scale_sts <sts_name> <replicas>`

Scale a StatefulSet.

### `k8s_sts_pod_names <sts_name>`

**Returns**: `data.pods` — array of pod names belonging to the StatefulSet.

### `k8s_sts_all_pods_ready <sts_name>`

**Returns**: `data.desired`, `data.ready`, `data.allReady` (boolean).

---

## Rollout Functions

### `k8s_rollout_restart <type> <name>`

Trigger a rolling restart (equivalent to `kubectl rollout restart`).

| Parameter | Example |
|-----------|---------|
| type | `statefulset` |
| name | `mongodb` |

### `k8s_rollout_status <type> <name>`

Wait for rollout to complete (120 s timeout).

---

## Deployment Functions

### `k8s_get_deployments [label_selector]`

### `k8s_scale_deployment <name> <replicas>`

---

## Service Functions

### `k8s_get_services [label_selector]`

### `k8s_port_forward <resource> <local_port> <remote_port> [background]`

---

## ConfigMap / Secret Functions

### `k8s_get_configmap <name>`

### `k8s_get_secret <name>`

---

## Disk / PVC Functions

### `k8s_check_pvc_usage <pod_name> <mount_path> <warn_percent>`

Run `df` inside the pod to get disk usage.

**Returns**: `data.used_percent`, `data.warn` (boolean).

---

## Monitoring Functions

### `k8s_get_events [resource_name]`

Get K8s events for the namespace (optionally filtered by resource name).

### `k8s_top_pods`

CPU/memory usage (requires metrics-server).

---

## Example

```bash
source /tasks/lib/logging.sh
source /tasks/lib/response.sh
source /tasks/lib/k8s.sh

K8S_NAMESPACE="mongo-1"

r=$(k8s_sts_all_pods_ready "mongodb")
echo "$r"
# {"status":"success","operation":"k8s_sts_all_pods_ready","data":{"desired":1,"ready":1,"allReady":true},...}
```
