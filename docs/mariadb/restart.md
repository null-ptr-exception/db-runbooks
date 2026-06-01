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
- For automatic update strategies, it waits until all current pods have been
  recreated and are Ready.
- For `OnDelete` or `Never`, it reports the CR patch as pending because those
  strategies intentionally do not let this task force a Pod restart.
- After the operator-driven restart, it compares the primary before and after.
  An unexpected primary move is reported as `ROLE_CHANGED` unless
  `allow_role_change=true`.

This task does **not** promote replicas or patch operator/Service state. Use a
separate, explicit promote-replica procedure for role changes.

## Input

| Name | Env Var | Type | Required | Default | Notes |
|------|---------|------|----------|---------|-------|
| `namespace` | `DB_NAMESPACE` | string | yes | - | Validated `^mariadb-[0-9]+$` |
| `context` | `K8S_CONTEXT` | string | no | `""` | Optional for in-cluster AQSH |
| `resource` | `MARIADB_RESOURCE` | string | no | `mariadb` | MariaDB CR kind |
| `mdb` | `MARIADB_NAME` | string | no | `mariadb` | MariaDB CR name |
| `container` | `MARIADB_CONTAINER` | string | no | `mariadb` | MariaDB container name |
| `allow_role_change` | `ALLOW_ROLE_CHANGE` | string | no | `false` | Tolerate a primary move |
| `wait_timeout` | `WAIT_TIMEOUT` | string | no | `300` | Operator rollout wait timeout (s) |
| `dry_run` | `DRY_RUN` | string | no | `true` | Plan only, change nothing |
| `confirm` | `CONFIRM` | string | no | `false` | Required with `dry_run=false` |
| `annotation_key` | `RESTART_ANNOTATION_KEY` | string | no | `aqsh.null-ptr-exception.dev/restarted-at` | Pod-template annotation key patched on the MariaDB CR |
| `metadata_field` | `RESTART_METADATA_FIELD` | string | no | `auto` | `auto`, `podMetadata`, or `inheritMetadata` |

Valid namespaces: `mariadb-1`, `mariadb-2`, `mariadb-3`

Deprecated compatibility inputs:

| Flag | Behaviour |
|------|-----------|
| `--target-pod` | Returns `TARGET_POD_UNSUPPORTED`; operator-driven restart is resource-scoped |
| `--include-primary` | Accepted but ignored; mariadb-operator controls rollout order |

## Output (written to `$AQSH_RESULT_FILE`)

```json
{
  "status": "READY",
  "reason_code": "RESTART_DRY_RUN",
  "summary": "Dry-run made no changes; mariadb-operator will decide restart order after the annotation patch",
  "target": {
    "context": "kind-cluster-dbs",
    "namespace": "mariadb-1",
    "resource": "mariadb",
    "mdb": "mariadb",
    "update_strategy": "ReplicasFirstPrimaryLast",
    "replicas": 1
  },
  "operator_controlled": true,
  "annotation": {
    "metadata_field": "podMetadata",
    "key": "aqsh.null-ptr-exception.dev/restarted-at",
    "value": null
  },
  "dry_run": true,
  "confirm": false,
  "allow_role_change": false,
  "changed": false,
  "primary_before": "mariadb-0",
  "primary_after": null,
  "restart_order": [],
  "pods": [
    {
      "name": "mariadb-0",
      "role": "primary",
      "uid_before": "9f6...",
      "ready_before": true,
      "restarted": false,
      "ready_after": null
    }
  ]
}
```

`restart_order` is always empty because the task delegates ordering to
mariadb-operator.

### Status / reason_code matrix

| status | reason_code | Meaning |
|--------|-------------|---------|
| `READY` | `RESTART_DRY_RUN` | Dry-run plan; no patch applied |
| `RESTARTED` | `RESTART_COMPLETED` | CR patched, operator recreated all current pods, and pods are Ready |
| `PATCHED` | `OPERATOR_UPDATE_PENDING` | CR patched, but `OnDelete` or `Never` strategy leaves restart pending |
| `WARN` | `ROLE_CHANGED` | Operator restart completed but primary moved; tolerated via `allow_role_change` |
| `BLOCKED` | `RESTART_CONFIRM_REQUIRED` | `dry_run=false` without `confirm=true` |
| `BLOCKED` | `MARIADB_OPERATOR_REQUIRED` | MariaDB CR not found; native StatefulSet-only mode is unsupported |
| `BLOCKED` | `MARIADB_PODS_NOT_FOUND` | MariaDB CR exists but no MariaDB pods were found |
| `BLOCKED` | `POD_NOT_READY` | Existing MariaDB pod is not Ready before the patch |
| `BLOCKED` | `TARGET_POD_UNSUPPORTED` | `target_pod` was requested, but operator-driven restart is resource-scoped |
| `BLOCKED` | `RESTART_METADATA_FIELD_UNSUPPORTED` | CRD exposes neither `spec.podMetadata` nor `spec.inheritMetadata` |
| `BLOCKED` | `RESTART_METADATA_FIELD_INVALID` | `metadata_field` is not `auto`, `podMetadata`, or `inheritMetadata` |
| `ERROR` | `ROLE_CHANGED` | Primary moved unexpectedly (`allow_role_change=false`) |
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

RBAC: the `aqsh-mariadb-manager` ClusterRole must allow `get`/`list`/`watch`
on `mariadbs`, `statefulsets`, and `pods`; `patch` on `mariadbs`; and `create`
on `pods/exec` for optional SQL role probes.

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
| `OnDelete` / `Never` update strategy | `status=PATCHED`, `reason_code=OPERATOR_UPDATE_PENDING` |
| CR patch denied or failed | `status=ERROR`, `reason_code=RESTART_PATCH_FAILED` |
| Operator rollout timeout | `status=ERROR`, `reason_code=OPERATOR_RESTART_TIMEOUT` |
| Primary moves unexpectedly | `status=ERROR`, `reason_code=ROLE_CHANGED` |
