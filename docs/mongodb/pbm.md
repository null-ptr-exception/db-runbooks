# MongoDB PBM Gateway (`pbm/*`)

Percona Backup for MongoDB (PBM) task family: restorable **logical backups**,
**selective backup/restore**, and **point-in-time recovery (PITR)** for
replica-set deployments, driven entirely through the aqsh API. Supersedes the
legacy `backup` task (mongodump tarball — kept but deprecated).

Deployment naming, the agent sidecar container, the storage location, and the
S3 credentials are **not task inputs** (see CLAUDE.md "Configuration
Layers") — they resolve internal config → live cluster auto-detect →
convention literal. The API surface per call is `namespace` plus genuinely
per-call operational decisions.

## Table of Contents

1. [When To Use What](#when-to-use-what)
2. [Deployment Requirements](#deployment-requirements)
3. [Architecture: What Happens On This Deployment](#architecture-what-happens-on-this-deployment)
4. [How It Works](#how-it-works)
5. [API Reference](#api-reference)
6. [Usage Scenarios](#usage-scenarios)
7. [Logical vs Physical (and why physical is refused)](#logical-vs-physical-and-why-physical-is-refused)
8. [Deployment Settings (Internal Config)](#deployment-settings-internal-config)
9. [RBAC Requirements](#rbac-requirements)
10. [Production Hardening](#production-hardening)
11. [Future Work](#future-work)

## When To Use What

| Situation | Use |
|---|---|
| Routine restorable backup (scheduled or ad-hoc) | `pbm/backup` |
| Minute-level RPO / continuous protection | `pbm/pitr enabled=true` (+ small `oplog_span_min`) |
| Bad write / accidental drop at time T | `pbm/restore time=<T-1s>` |
| Bad data in one collection, good writes elsewhere continue | `pbm/restore time=<T-1s> ns=<db.coll>` (selective) |
| Roll back to a known-good snapshot | `pbm/restore backup_name=<name>` |
| What backups exist? Is PBM healthy? | `pbm/list`, `pbm/status` |
| Why did a backup/restore fail? | `pbm/logs event=backup/<name>` |
| Retention: drop artifacts older than N days | `pbm/delete older_than=<Nd>` |
| A backup is hammering the cluster right now | `pbm/cancel-backup` |
| MinIO endpoint/bucket moved | update internal config → `pbm/config` (dry_run → confirm) |
| One-off throwaway dump, no restore story needed | legacy `backup` (deprecated) |
| Physical/incremental backup of very large data sets | Percona Operator deployment — out of scope here, see [below](#logical-vs-physical-and-why-physical-is-refused) |
| A pod's data files are corrupt (no backup involved) | `recovery/*` (see docs/mongodb/recovery.md) |

## Deployment Requirements

PBM has two hard prerequisites the tasks can check but not create:

1. **A replica set.** Even single-node: mongod must run with `--replSet` and
   the set must be initiated. Standalone mongod is not supported by PBM.
2. **A `pbm-agent` sidecar in every mongod pod** (image
   `percona/percona-backup-mongodb`), with `PBM_MONGODB_URI` in its env
   pointing at its local mongod (`mongodb://<user>:<pass>@localhost:27017`,
   credentials via `secretKeyRef` composition). The agent is the component
   that reads/writes the S3 storage; aqsh only drives it.

A namespace without the sidecar fails every `pbm/*` task with
`NO_PBM_AGENT` and the container list it inspected. See
`tests/mongodb/pbm_helpers.bash` (`_pbm_apply_fixture`) for a complete
working StatefulSet example, including the retry wrapper that keeps the
agent container from crash-looping before `rs.initiate`.

## Architecture: What Happens On This Deployment

```text
test-client (cluster-b)
    │ POST /tasks/pbm%2Fbackup  {"namespace":"mongo-pbm"}
    ▼
Istio Gateway (cluster-a:30080) → kube-auth-proxy → aqsh
    │
    │ resolve: STS (ownerRef/only-STS) → agent container (PBM_MONGODB_URI
    │ env / image match / literal "pbm-agent") → Ready probe pod
    ▼
kubectl exec mongodb-0 -c pbm-agent -- pbm <cmd> -o json
    │                    ▲
    │                    │ PBM_MONGODB_URI (container env — aqsh never
    │                    │ loads mongo credentials for pbm/* tasks)
    ▼                    │
pbm control collections in the replica set ──► every pod's pbm-agent
    │                                             │ dump/oplog upload
    ▼                                             ▼
             MinIO (cluster-b)  s3://db-backups/mongodb/<namespace>/
```

Key properties:

- **No new binary in the aqsh image.** The `pbm` CLI ships inside the agent
  sidecar; aqsh reaches it with the `pods/exec` permission it already has.
- **Least privilege.** `pbm/*` tasks never read the MongoDB credentials
  secret — the connection string lives in the sidecar's env. The only secret
  aqsh reads is the S3 credentials secret (`minio` by convention).
- **Start-then-poll, never `--wait`.** Long operations are started, then
  polled via `describe-backup`/`describe-restore` every 10s. A dropped exec
  session can only delay a status read, not abort or falsely fail the
  operation.

## How It Works

### Agent container resolution (3-tier, no task-input tier)

1. Internal config: `PBM_AGENT_CONTAINER_DEFAULT`
2. Auto-detect from the StatefulSet's own pod template: the container
   carrying a `PBM_MONGODB_URI` env var (value or valueFrom); else the
   container whose image matches `percona-backup-mongodb`
3. Literal `pbm-agent` — accepted only if a container of that name actually
   exists; otherwise the task fails `NO_PBM_AGENT` with guidance (a missing
   sidecar means the feature isn't deployed, not a naming quirk)

### Storage auto-ensure (and the mismatch refusal)

`pbm/backup`, `pbm/pitr enable`, and `pbm/restore` call the storage guard
before acting:

- **Unset** → the resolved location (endpoint from `MINIO_ENDPOINT`, bucket
  `db-backups`, prefix `mongodb/<namespace>`) is applied automatically:
  bucket pre-created via `mc` from the aqsh pod, config fed to
  `pbm config --file /dev/stdin` (credentials never on an argv), then
  `pbm config --force-resync`. A fresh deployment needs **no setup step**.
- **Set and matching** → no-op.
- **Set but pointing elsewhere** → the task fails `STORAGE_CONFIG_MISMATCH`
  and refuses to overwrite: an existing config may protect real backups.
  `pbm/config` is the one sanctioned path to re-point storage.

### PITR lifecycle

```text
pbm/backup (base)  ──►  pbm/pitr enabled=true [oplog_span_min=N]
                              │ agents slice oplog every N minutes
                              ▼
        covered window = [base backup … newest flushed chunk]
                              │
        pbm/restore time=T  (T inside the window, any second)
                              │ PITR is DISABLED first (PBM requirement)
                              ▼
        after restore: PITR stays OFF until
        pbm/backup (fresh base)  +  pbm/pitr enabled=true
```

The restore never re-enables PITR itself: chunks sliced on top of the
pre-restore history would be misleading; a fresh base backup must anchor the
new timeline first. Every restore result carries `post_restore_required`
restating this.

- **RPO ≈ `oplog_span_min`** (PBM default 10 minutes; the e2e suite runs
  with 1). Changeable at any time via `pbm/pitr`.
- Restore time granularity is **any second inside the window** — chunks are
  storage units, not restore-point boundaries.

### Scheduling (backup 循環)

PBM has no built-in scheduler and neither does this gateway — recurrence
belongs to the caller. The house pattern is a Kubernetes CronJob POSTing to
the API (see [Usage Scenarios](#usage-scenarios)); changing the cycle is
`kubectl patch cronjob` on `spec.schedule`, effective immediately. With PITR
enabled, a daily base backup is usually enough — the oplog chunks carry the
fine-grained restore points between bases.

### Debug logging

Every `pbm/*` task accepts `log_level` (e.g. `"DEBUG"`) as an input; the
deployment baseline comes from `LOG_LEVEL_DEFAULT` in internal config. DEBUG
traces every resolution decision (which tier won), every `pbm` invocation
with truncated output, and every poll-loop status transition. S3 credentials
are masked everywhere; `pbm config` output is redacted before it reaches a
result.

## API Reference

All tasks: `namespace` (required) + `log_level` (optional, `DEBUG|INFO|WARN|ERROR`).
Gated tasks use the standard triad: `dry_run` defaults `"true"`;
executing requires `dry_run=false&confirm=true`; `dry_run=true&confirm=true`
is rejected.

### `pbm/status` — read-only

No further inputs. Returns agent health per node, storage state
(`configured`, `in_sync` vs the resolved location, current + resolved
locations), PITR state + covered chunk ranges, the running op, and a
snapshot summary.

### `pbm/backup`

| Input | Required | Meaning |
|---|---|---|
| `type` | no (`logical`) | Only `logical` executes; `physical`/`incremental`/`external` fail `UNSUPPORTED_BACKUP_TYPE` with the rationale |
| `ns` | no | Selective backup filter, e.g. `app.orders` or `app.*` (comma list allowed) |
| `wait` | no (`true`) | `false` = fire-and-forget; follow up via `pbm/list name=` |
| `wait_timeout` | no (`1200`) | Poll budget in seconds |

Ungated: a backup adds an artifact and mutates no database state. Failure
codes: `UNSUPPORTED_BACKUP_TYPE`, `NO_PBM_AGENT`, `NO_READY_POD`,
`STORAGE_CONFIG_MISMATCH`, `STORAGE_CONFIG_FAILED`, `BACKUP_START_FAILED`,
`BACKUP_FAILED`, `WAIT_TIMEOUT`. Result includes `backup_name`, final
`status`, `size_bytes`, the storage location, and a ready-to-send
`restorable_by` block.

### `pbm/list` — read-only

| Input | Required | Meaning |
|---|---|---|
| `name` | no | Backup name → full describe-backup detail (describe is folded into list) |
| `include_restores` | no (`false`) | Also return past restore operations |

Failure codes: `BACKUP_NOT_FOUND`, `PBM_CLI_ERROR`.

### `pbm/restore` — gated

| Input | Required | Meaning |
|---|---|---|
| `backup_name` | XOR `time` | Snapshot restore |
| `time` | XOR `backup_name` | PITR restore, `YYYY-MM-DDTHH:MM:SS` UTC, any second inside the covered window |
| `ns` | no | Selective restore, e.g. `app.orders` — other collections untouched |
| `wait_timeout` | no (`1500`) | Poll budget in seconds |
| `dry_run` / `confirm` | triad | dry-run validates the target and previews side effects |

dry-run verifies the snapshot exists/`done`/logical, or that `time` falls in
a covered chunk (`TIME_NOT_COVERED` otherwise), and reports whether PITR
will be disabled. Confirm disables PITR when needed, restores, and returns
`pitr_was_enabled` / `pitr_enabled_now:false` / `post_restore_required`.
Failure codes: `INVALID_INPUT`, `BACKUP_NOT_FOUND`, `BACKUP_NOT_RESTORABLE`,
`UNSUPPORTED_BACKUP_TYPE`, `TIME_NOT_COVERED`, `PITR_DISABLE_FAILED`,
`RESTORE_START_FAILED`, `RESTORE_FAILED`, `WAIT_TIMEOUT`.

### `pbm/delete` — gated

| Input | Required | Meaning |
|---|---|---|
| `backup_name` | XOR `older_than` | Delete one snapshot (`pbm delete-backup`) |
| `older_than` | XOR `backup_name` | Retention sweep: `30d` or a UTC timestamp (`pbm cleanup`, also trims PITR chunks) |
| `dry_run` / `confirm` | triad | dry-run lists exactly what would be removed |

PBM refuses removals that would break a restorable chain (e.g. the base
snapshot anchoring live PITR); that refusal surfaces verbatim in
`DELETE_FAILED`/`CLEANUP_FAILED`. Other codes: `INVALID_INPUT`,
`BACKUP_NOT_FOUND`.

### `pbm/pitr` — gated

| Input | Required | Meaning |
|---|---|---|
| `enabled` | yes | `true` / `false` |
| `oplog_span_min` | no | Chunk interval in minutes (RPO granularity); settable any time |
| `dry_run` / `confirm` | triad | dry-run reports current state, the diff, and `would_fail: NO_BASE_BACKUP` when enabling without a base |

Failure codes: `INVALID_INPUT`, `NO_BASE_BACKUP`,
`STORAGE_CONFIG_MISMATCH`/`STORAGE_CONFIG_FAILED` (enable path),
`PITR_SET_FAILED`.

### `pbm/logs` — read-only

| Input | Required | Meaning |
|---|---|---|
| `event` | no | e.g. `backup/2026-07-10T05:23:41Z` — the failed op's own trail |
| `severity` | no | `D`/`I`/`W`/`E`/`F` |
| `tail` | no (`50`) | Entry count |

### `pbm/cancel-backup` — gated

Only the triad. dry-run shows the running op that would be aborted; confirm
with nothing running fails `NO_RUNNING_OP`. The aborted backup shows as
`cancelled` in `pbm/list`.

### `pbm/config` — gated

Only the triad. dry-run: current PBM storage vs the deployment-resolved
location (credentials redacted), `in_sync`, and the action confirm would
take. confirm: applies the resolved location + `--force-resync` (an
already-in-sync confirm is a reported no-op). This is the **sanctioned path
for storage migrations** — update the internal-config ConfigMap first, then
dry_run → confirm.

## Usage Scenarios

情境速查表 (scenario quick reference):

| 情境 | 操作 |
|---|---|
| 例行備份（每日/每週循環） | CronJob → `pbm/backup`（下方範例）；改循環 = 改 CronJob schedule |
| 資料遺失窗口縮到分鐘級 | `pbm/pitr enabled=true oplog_span_min=1` |
| 誤刪/髒資料寫入於時刻 T | `pbm/restore time=T-1秒`（dry_run 先驗證覆蓋範圍） |
| 髒資料只污染一個 collection | `pbm/restore time=T-1 ns=mydb.orders`（selective，其他 collection 不動） |
| 還原到某次完整備份 | `pbm/restore backup_name=<name>` |
| 搬家：換 MinIO endpoint/bucket | 改 internal config → `pbm/config` dry_run → confirm |
| 清舊備份（保留 30 天） | `pbm/delete older_than=30d` dry_run → confirm |
| 備份失敗查原因 | `pbm/logs event=backup/<name>` |
| 資料量數百 GB、要 physical | 本環境拒絕 — 見 [Logical vs Physical](#logical-vs-physical-and-why-physical-is-refused) |

**1. First backup on a fresh deployment** (storage auto-ensures itself):

```json
POST /tasks/pbm%2Fbackup
{"namespace": "mongo-1"}
```

**2. Scheduled daily backup** — recurrence lives in a CronJob, not the API:

```yaml
apiVersion: batch/v1
kind: CronJob
metadata:
  name: mongo-1-pbm-backup
spec:
  schedule: "0 3 * * *"          # change the cycle by patching this line
  jobTemplate:
    spec:
      template:
        spec:
          restartPolicy: Never
          containers:
            - name: submit
              image: curlimages/curl:8.7.1
              command:
                - sh
                - -c
                - >
                  curl -sf -X POST
                  -H "Authorization: Bearer $(cat /var/run/secrets/tokens/aqsh-token)"
                  -H "Content-Type: application/json"
                  -d '{"namespace":"mongo-1","wait":"false"}'
                  http://aqsh-mongodb.kind-a.test:30080/tasks/pbm%2Fbackup
              volumeMounts:
                - name: aqsh-token
                  mountPath: /var/run/secrets/tokens
          volumes:
            - name: aqsh-token
              projected:
                sources:
                  - serviceAccountToken:
                      path: aqsh-token
                      expirationSeconds: 600
```

**3. Enable minute-level PITR** (after at least one base backup):

```json
POST /tasks/pbm%2Fpitr
{"namespace": "mongo-1", "enabled": "true", "oplog_span_min": "1"}
→ review the dry-run report, then:
{"namespace": "mongo-1", "enabled": "true", "oplog_span_min": "1",
 "dry_run": "false", "confirm": "true"}
```

**4. Dirty data written at 14:23:07 — roll the database back to 14:23:06:**

```json
POST /tasks/pbm%2Frestore
{"namespace": "mongo-1", "time": "2026-07-10T14:23:06"}
→ dry-run validates coverage and warns PITR will be disabled, then:
{"namespace": "mongo-1", "time": "2026-07-10T14:23:06",
 "dry_run": "false", "confirm": "true"}
```

Afterwards (the result says so too): `pbm/backup`, then re-enable
`pbm/pitr`. **Caveat**: this is a time cut, not a data filter — good writes
after 14:23:06 are lost with the bad one. When the damage is confined to one
collection and other writes must survive, restore selectively instead:

```json
{"namespace": "mongo-1", "time": "2026-07-10T14:23:06", "ns": "app.orders",
 "dry_run": "false", "confirm": "true"}
```

**5. Roll back to a known-good snapshot:**

```json
POST /tasks/pbm%2Frestore
{"namespace": "mongo-1", "backup_name": "2026-07-10T03:00:12Z",
 "dry_run": "false", "confirm": "true"}
```

**6. Retention — keep 30 days:**

```json
POST /tasks/pbm%2Fdelete
{"namespace": "mongo-1", "older_than": "30d"}
→ dry-run lists the exact victims, then confirm.
```

**7. A backup failed — why?**

```json
POST /tasks/pbm%2Flogs
{"namespace": "mongo-1", "event": "backup/2026-07-10T03:00:12Z", "severity": "E"}
```

**8. MinIO endpoint migration:**

1. Update `PBM_S3_ENDPOINT_DEFAULT` (or `MINIO_ENDPOINT`) in the
   internal-config ConfigMap — propagates to the mounted file in ~1 minute,
   no aqsh restart.
2. `pbm/config` dry-run → shows current vs resolved diff.
3. `pbm/config` confirm → applies + force-resync; backups already under the
   new location become visible to `pbm/list`.

## Logical vs Physical (and why physical is refused)

| | Logical | Physical |
|---|---|---|
| Mechanism | dump/insert over MongoDB connections | data-file copy |
| Sweet spot | small–medium data (tens of GB) | very large data (100GB–TB): much faster, no index rebuild on restore |
| Restore impact | mongod keeps running | **all mongod processes stop**, agents run a temporary mongod, then everything restarts with original config |
| Selective (`ns`) | ✅ | ❌ |
| PITR | ✅ | ✅ (restore still needs the stop/start dance) |

The stop/start dance is the blocker here: in a plain StatefulSet, mongod is
the container's PID 1 — a sidecar can't stop it, and if the pod dies the
kubelet restarts mongod with its *original* arguments, exactly what a
physical restore must prevent. Something with Kubernetes API authority has
to take over the StatefulSet during the restore; the Percona Operator is the
off-the-shelf incarnation of that "something". This is an environment
decision, not an API flag — hence `UNSUPPORTED_BACKUP_TYPE` instead of a
backup that could never be restored where it was taken.

## Deployment Settings (Internal Config)

`/etc/aqsh/config/mongodb.env` (chart: `aqsh.config."mongodb.env"`). All
optional — auto-detect/convention defaults cover the standard layout.

| Variable | Default | Meaning |
|---|---|---|
| `PBM_AGENT_CONTAINER_DEFAULT` | auto-detect → `pbm-agent` | Sidecar container name |
| `PBM_S3_CREDENTIALS_SECRET_DEFAULT` | `minio` | Secret (in the DB namespace) with `access-key-id` / `secret-access-key` |
| `PBM_S3_BUCKET_DEFAULT` | `db-backups` | Bucket |
| `PBM_S3_PREFIX_DEFAULT` | `mongodb/<namespace>` | Per-namespace object prefix |
| `PBM_S3_ENDPOINT_DEFAULT` | `MINIO_ENDPOINT` | S3 endpoint URL |
| `PBM_S3_REGION_DEFAULT` | `us-east-1` | S3 region |
| `LOG_LEVEL_DEFAULT` | `INFO` | Baseline task log verbosity (`log_level` input overrides per call) |

## RBAC Requirements

Everything the recovery/fcv/reconfig family already has covers `pbm/*`
except one addition: `get` on the S3 credentials secret, pinned by name.

| Permission | Used for |
|---|---|
| `pods/exec` create *(existing)* | running `pbm` inside the agent sidecar |
| `statefulsets` get *(existing, pinned)* | agent auto-detect from the pod template |
| `pods` get/list *(existing)* | probe-pod selection |
| `secrets` get pinned to **`minio`** *(new — `mongodb.backupSecret` chart value)* | rendering `pbm config` credentials, bucket pre-creation |

The MongoDB credentials secret is *not* needed by these tasks.

## Production Hardening

- **Dedicated PBM user instead of root** in `PBM_MONGODB_URI`: create a user
  with the [role Percona documents for PBM](https://docs.percona.com/percona-backup-mongodb/install/configure-authentication.html)
  (`readWrite` on `admin.pbmRoles` etc. via a custom `pbmAnyAction` role)
  and wire its secret into the sidecar. The tasks are agnostic — they never
  see the URI.
- **Per-deployment S3 credentials**: replace the sandbox's MinIO root
  credentials in the `minio` secret with a scoped access key.
- **Retention automation**: pair the backup CronJob with a
  `pbm/delete older_than=30d` CronJob (dry-run it manually first).

## Future Work

- **Physical/incremental backups** on operator-managed deployments, or
  hand-rolled mongod lifecycle coordination reusing the recovery library's
  StatefulSet patch/partition machinery (`aqsh-tasks/lib/mongodb-recovery.sh`)
  — a separate feature with its own gating story.
- Restore-into-a-new-cluster (side-by-side) flows for surgical data salvage.
