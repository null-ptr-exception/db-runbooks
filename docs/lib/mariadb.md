# Library: mariadb.sh

Shared MariaDB operator helpers for AQSH task scripts, local scripts, and
Rundeck wrappers.

## Source

```bash
source /tasks/lib/logging.sh
source /tasks/lib/response.sh
source /tasks/lib/k8s.sh
source /tasks/lib/mariadb.sh
```

For local development from the repo root:

```bash
LIB_DIR="$PWD/aqsh-tasks/lib" \
  aqsh-tasks/scripts/mariadb/sanity-check.sh --namespace mariadb-1
```

## Target Configuration

```bash
mariadb_set_target "$context" "$namespace" "$resource" "$mdb" "$container"
```

| Parameter | Default | Description |
|-----------|---------|-------------|
| `context` | current context / in-cluster | Kubernetes context |
| `namespace` | `default` | Target namespace |
| `resource` | `mariadb` | MariaDB custom resource kind |
| `mdb` | `mariadb` | MariaDB CR and StatefulSet name |
| `container` | `mariadb` | Container name for `kubectl exec` |

## Functions

| Function | Description |
|----------|-------------|
| `mariadb_jsonpath <resource> <name> <path>` | Read a Kubernetes JSONPath from a namespaced resource |
| `mariadb_service_jsonpath <service> <path>` | Read a Service JSONPath |
| `mariadb_pod_jsonpath <pod> <path>` | Read a Pod JSONPath |
| `mariadb_pod_name <index>` | Build `<mdb>-<index>` |
| `mariadb_sts_replicas` | Read StatefulSet `.spec.replicas` |
| `mariadb_cr_replicas` | Read MariaDB CR `.spec.replicas` |
| `mariadb_list_pods [replicas]` | List MariaDB pods by replica count, labels, or name prefix |
| `mariadb_read_root_password <primary> [pods...]` | Read `MARIADB_ROOT_PASSWORD` from a MariaDB container |
| `mariadb_sql <pod> <password> <query>` | Run tabular SQL with `-N -B` |
| `mariadb_sql_vertical <pod> <password> <query>` | Run vertical SQL with `-E` |
| `mariadb_status_field <field>` | Parse `SHOW ALL SLAVES STATUS\G` output |
| `mariadb_gtid_covers <required> <actual>` | Return success when actual GTID covers required GTID |
| `mariadb_primary_service_name` | Build `<mdb>-primary` |

## Mutation Boundary

These helpers do not patch Kubernetes resources or change replication state by
themselves. Keep mutating entrypoints separate from read-only sanity checks so
automation cannot accidentally use a prepare-primary job as a general health
API.
