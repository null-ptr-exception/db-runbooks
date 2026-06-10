# Task: restart (aqsh-mariadb)

Operator-driven restart of a MariaDB cluster managed by mariadb-operator.

## Description

This task does not delete MariaDB Pods and does not choose the rollout order.
It patches a Pod-template annotation on the `MariaDB` custom resource:

```text
spec.podMetadata.annotations["aqsh.null-ptr-exception.dev/restarted-at"]
```

For older CRDs that do not expose `spec.podMetadata`, the task falls back to
`spec.inheritMetadata.annotations` when that field exists. That CR change is
reconciled by mariadb-operator. The operator decides how to restart the data
plane based on `spec.updateStrategy`, such as
`ReplicasFirstPrimaryLast`, `RollingUpdate`, `OnDelete`, or `Never`.

The task remains conservative:

- It requires a MariaDB CR. Native StatefulSet-only mode is not restarted by
  this task.
- It blocks before patching if any current MariaDB Pod is not Ready.
- It defaults to dry-run and requires `dry_run=false` plus `confirm=true`.
- After patching, it waits until all current pods have been recreated and are
  Ready. Strategies that do not auto-recreate pods (`OnDelete`, `Never`) will
  therefore reach the wait timeout and report `OPERATOR_RESTART_TIMEOUT`.

This task does **not** track primary/replica roles, impose a restart order, or
promote replicas — mariadb-operator owns the rollout. Its only job is to patch
the restart annotation and confirm the operator recreated every pod. Use a
separate, explicit promote-replica procedure for role changes.

## Input

| Name | Env Var | Type | Required | Default | Notes |
|------|---------|------|----------|---------|-------|
| `namespace` | `DB_NAMESPACE` | string | yes | - | Validated `^mariadb-[0-9]+$` |
| `context` | `K8S_CONTEXT` | string | no | `""` | Optional for in-cluster AQSH |
| `resource` | `MARIADB_RESOURCE` | string | no | `mariadb` | MariaDB CR kind |
| `mdb` | `MARIADB_NAME` | string | no | _auto-detect_ | MariaDB CR name. When omitted, auto-detected from the namespace (single CR); several return `MARIADB_AMBIGUOUS`, none returns `MARIADB_OPERATOR_REQUIRED`. |
| `container` | `MARIADB_CONTAINER` | string | no | `mariadb` | MariaDB container name |
| `wait_timeout` | `WAIT_TIMEOUT` | string | no | `300` | Operator rollout wait timeout (s) |
| `dry_run` | `DRY_RUN` | string | no | `true` | Plan only, change nothing |
| `confirm` | `CONFIRM` | string | no | `false` | Required with `dry_run=false` |
| `annotation_key` | `RESTART_ANNOTATION_KEY` | string | no | `aqsh.null-ptr-exception.dev/restarted-at` | Pod-template annotation key patched on the MariaDB CR |
| `metadata_field` | `RESTART_METADATA_FIELD` | string | no | `auto` | `auto`, `podMetadata`, or `inheritMetadata` |

Valid namespaces: `mariadb-1`, `mariadb-2`, `mariadb-3`

## Output (written to `$AQSH_RESULT_FILE`)

```json
{
  "status": "READY",
  "reason_code": "RESTART_DRY_RUN",
  "summary": "Dry-run made no changes; the operator decides restart order after the patch",
  "namespace": "mariadb-1",
  "mdb": "mariadb",
  "operator_controlled": true,
  "annotation": {
    "key": "aqsh.null-ptr-exception.dev/restarted-at",
    "metadata_field": "podMetadata"
  },
  "dry_run": true,
  "confirm": false,
  "changed": false,
  "pods": [
    {
      "name": "mariadb-0",
      "uid_before": "9f6...",
      "restarted": false,
      "ready_after": null
    }
  ]
}
```

Each `pods` entry is restart evidence: `uid_before` is the Pod UID before the
patch, and after the rollout `restarted`/`ready_after` report whether the
operator recreated that Pod and it became Ready again.

### Status / reason_code matrix

| status | reason_code | Meaning |
|--------|-------------|---------|
| `READY` | `RESTART_DRY_RUN` | Dry-run plan; no patch applied |
| `RESTARTED` | `RESTART_COMPLETED` | CR patched, operator recreated all current pods, and pods are Ready |
| `BLOCKED` | `RESTART_CONFIRM_REQUIRED` | `dry_run=false` without `confirm=true` |
| `BLOCKED` | `MARIADB_OPERATOR_REQUIRED` | MariaDB CR not found; native StatefulSet-only mode is unsupported |
| `BLOCKED` | `MARIADB_PODS_NOT_FOUND` | MariaDB CR exists but no MariaDB pods were found |
| `BLOCKED` | `POD_NOT_READY` | Existing MariaDB pod is not Ready before the patch |
| `BLOCKED` | `RESTART_METADATA_FIELD_UNSUPPORTED` | CRD exposes neither `spec.podMetadata` nor `spec.inheritMetadata` |
| `BLOCKED` | `RESTART_METADATA_FIELD_INVALID` | `metadata_field` is not `auto`, `podMetadata`, or `inheritMetadata` |
| `ERROR` | `RESTART_PATCH_FAILED` | `kubectl patch mariadb` failed |
| `ERROR` | `OPERATOR_RESTART_TIMEOUT` | CR patched, but pods did not all recreate and become Ready within `wait_timeout` |
| `ERROR` | `KUBECTL_UNAVAILABLE` | Kubernetes API not reachable |

All non-`ERROR`-on-infra outcomes are reported with task status `completed` and
a structured result; the script exits `0` so callers branch on `status` /
`reason_code`, not the process exit code.

## Permissions

| Field | Value |
|-------|-------|
| `allowed_groups` | `system:serviceaccounts` |
| Timeout | 8 minutes |

RBAC: this task needs `get`/`list`/`watch` on `mariadbs`, `statefulsets`, and
`pods`, plus `patch` on `mariadbs`. It does not exec into pods. (The shared
`aqsh-mariadb-manager` ClusterRole also grants `create` on `pods/exec` for other
MariaDB tasks such as `status` and `sanity-check`.)

## API Example

```bash
TOKEN=$(kubectl --context kind-cluster-apps -n app-a create token test-client --duration=10m)
MARIADB_AQSH_URL="http://<cluster-dbs-ip>:30081"

# 1. Dry-run: see the operator-controlled restart plan (default; changes nothing)
curl -s -X POST "$MARIADB_AQSH_URL/tasks/restart" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"namespace": "mariadb-1"}'

# 2. Execute: patch the MariaDB CR annotation and let mariadb-operator restart it
curl -s -X POST "$MARIADB_AQSH_URL/tasks/restart" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"namespace": "mariadb-1", "dry_run": "false", "confirm": "true"}'
```

## Error Cases

| Scenario | Behaviour |
|----------|-----------|
| Namespace does not match pattern | aqsh rejects with 400 before task runs |
| MariaDB CR not found | `status=BLOCKED`, `reason_code=MARIADB_OPERATOR_REQUIRED` |
| Restart requested without confirm | `status=BLOCKED`, `reason_code=RESTART_CONFIRM_REQUIRED` |
| Existing pod is not Ready | `status=BLOCKED`, `reason_code=POD_NOT_READY` |
| Single-pod cluster | Allowed; operator decides whether and how to restart the primary |
| `OnDelete` / `Never` update strategy | Pods are not auto-recreated, so the wait reaches `status=ERROR`, `reason_code=OPERATOR_RESTART_TIMEOUT` |
| CR patch denied or failed | `status=ERROR`, `reason_code=RESTART_PATCH_FAILED` |
| Operator rollout timeout | `status=ERROR`, `reason_code=OPERATOR_RESTART_TIMEOUT` |
