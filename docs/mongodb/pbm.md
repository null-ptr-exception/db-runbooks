# MongoDB PBM Gateway (`pbm/*`)

Percona Backup for MongoDB (PBM) task family: restorable **logical,
physical and incremental backups**, **selective (logical) backup/restore**,
and **point-in-time recovery (PITR)** for replica-set deployments, driven
entirely through the aqsh API. Physical restores run a **full-downtime
StatefulSet takeover** orchestrated by the task itself — no operator
required. Supersedes the legacy `backup` task (mongodump tarball — kept but
deprecated).

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
7. [Choosing a Backup Type: Logical vs Physical/Incremental](#choosing-a-backup-type-logical-vs-physicalincremental)
8. [Physical Restore: the Takeover](#physical-restore)
9. [Deployment Settings (Internal Config)](#deployment-settings-internal-config)
10. [RBAC Requirements](#rbac-requirements)
11. [Production Hardening](#production-hardening)
12. [Future Work](#future-work)

## When To Use What

| Situation | Use |
|---|---|
| Ad-hoc restorable backup | `pbm/backup` |
| Recurring backup cycle (PBM has no built-in scheduler) | `pbm/schedule` — aqsh-managed CronJob, one gated call |
| Very large data sets — dump/insert too slow | `pbm/backup type=physical` (needs PSMDB, see [requirements](#deployment-requirements)) |
| Large data + frequent backups without re-uploading everything | `pbm/backup type=incremental` (chain auto-anchors its `--base`) |
| Minute-level RPO / continuous protection | `pbm/pitr enabled=true` (+ small `oplog_span_min`) — works on logical AND physical bases |
| Bad write / accidental drop at time T | `pbm/restore time=<T-1s>` |
| Bad data in one collection, good writes elsewhere continue | `pbm/restore time=<T-1s> ns=<db.coll>` (selective — logical bases only) |
| Roll back to a known-good snapshot | `pbm/restore backup_name=<name>` (physical/incremental = **full-cluster downtime**, see [takeover](#physical-restore)) |
| What backups exist? Is PBM healthy? Physical-ready? | `pbm/list`, `pbm/status` |
| Why did a backup/restore fail? | `pbm/logs event=backup/<name>` |
| Retention: drop artifacts older than N days | `pbm/delete older_than=<Nd>` (PBM protects live chains/PITR anchors) |
| A backup is hammering the cluster right now | `pbm/cancel-backup` |
| MinIO endpoint/bucket moved | update internal config → `pbm/config` (dry_run → confirm) |
| One-off throwaway dump, no restore story needed | legacy `backup` (deprecated) |
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

**Physical/incremental backups add two more prerequisites** (both
live-detected per call, never guessed):

3. **The mongod engine must be Percona Server for MongoDB (PSMDB)** — the
   `$backupCursor` aggregation physical backups are built on is a PSMDB
   extension; vanilla MongoDB Community fails with `PSMDB_REQUIRED` (the
   engine is read from `buildInfo`, which runs pre-auth, so aqsh stays
   credential-free). PSMDB is a drop-in replacement image.
4. **The agent sidecar must mount the data volume at the same path as
   mongod** — `$backupCursor` returns absolute file paths the agent reads
   straight off the volume. Missing mounts fail `AGENT_NO_DATA_VOLUME`
   with the exact list; this is a deployment change, deliberately never
   auto-patched by a backup task (it would restart every pod).

Physical **restores** need no extra deployment wiring — the takeover
injects everything it needs and removes it afterwards
(see [Physical Restore](#physical-restore)); the mongod container must
however declare an explicit `command` (`PHYSICAL_UNSUPPORTED_SPEC`
otherwise), since the takeover supervisor reproduces its exact command
line.

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

### Scheduling

<a id="scheduling"></a>**PBM has no built-in scheduler** — Percona's own
docs say it plainly: *"We recommend using `crond` or similar services to
schedule backup snapshots"* (still true as of PBM 2.15.0). There is no
`pbm config --set-schedule` and no `schedules:` config section; the
cron-in-CR scheduled backups people sometimes attribute to PBM are a
**Percona Operator for MongoDB** feature, implemented by the operator on
top of PBM. Treat any claim to the contrary as misinformation.

This gateway therefore owns the scheduling itself: **`pbm/schedule`**
manages one aqsh-owned Kubernetes CronJob per namespace
(`pbm-backup-schedule` by convention) that submits `pbm/backup`
(`wait=false`) back into the aqsh API on the given cron expression, using
a short-lived projected ServiceAccount token. Callers see only
`schedule="0 2 * * *"` + `type` — the CronJob name and aqsh URL are
internal config (`PBM_SCHEDULE_CRONJOB_DEFAULT`,
`PBM_SCHEDULE_AQSH_URL_DEFAULT`), never inputs. Changing the cycle is one
gated call, effective immediately; `enabled=false` suspends without losing
the definition. With PITR enabled, a daily base backup is usually enough —
the oplog chunks carry the fine-grained restore points between bases.

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
locations), PITR state + covered chunk ranges, the running op, a snapshot
summary, `physical_ready` (`engine` from live `buildInfo`, `psmdb` flag,
`agent_data_volume`) and `physical_restore_in_progress` (a takeover
annotation is on the StatefulSet).

### `pbm/backup`

| Input | Required | Meaning |
|---|---|---|
| `type` | no (`logical`) | `logical` \| `physical` \| `incremental` — the latter two gate on the live-detected PSMDB engine + agent data volume; `external` fails `UNSUPPORTED_BACKUP_TYPE` (snapshot tooling is infra-owned) |
| `ns` | no | Selective backup filter, e.g. `app.orders` or `app.*` (comma list; **logical only** — PBM restriction) |
| `wait` | no (`true`) | `false` = fire-and-forget; follow up via `pbm/list name=` |
| `wait_timeout` | no (`1200`) | Poll budget in seconds |

An incremental backup with no completed chain automatically becomes the
`--base` (reported as `incremental_base: true` — no extra input). Ungated:
a backup adds an artifact and mutates no database state. Failure codes:
`UNSUPPORTED_BACKUP_TYPE`, `PSMDB_REQUIRED`, `AGENT_NO_DATA_VOLUME`,
`PHYSICAL_UNSUPPORTED_SPEC`, `NO_PBM_AGENT`, `NO_READY_POD`,
`STORAGE_CONFIG_MISMATCH`, `STORAGE_CONFIG_FAILED`, `BACKUP_START_FAILED`,
`BACKUP_FAILED`, `WAIT_TIMEOUT`. Result includes `backup_name`, `type`,
final `status`, `size_bytes`, the storage location, and a ready-to-send
`restorable_by` block; non-logical results carry a `restore_note` naming
the downtime cost.

### `pbm/list` — read-only

| Input | Required | Meaning |
|---|---|---|
| `name` | no | Backup name → full describe-backup detail (describe is folded into list) |
| `include_restores` | no (`false`) | Also return past restore operations |

Failure codes: `BACKUP_NOT_FOUND`, `PBM_CLI_ERROR`.

### `pbm/restore` — gated

| Input | Required | Meaning |
|---|---|---|
| `backup_name` | XOR `time` | Snapshot restore — the flow follows the backup's own type: logical = online, physical/incremental = [takeover](#physical-restore) |
| `time` | XOR `backup_name` | PITR restore, `YYYY-MM-DDTHH:MM:SS` UTC (no `Z` — PBM rejects it), any second inside the covered window; the newest done base at/before T is picked and pinned with `--base-snapshot` — a physical base runs the takeover |
| `ns` | no | Selective restore, e.g. `app.orders` — other collections untouched (**logical bases only**) |
| `wait_timeout` | no (`1500`) | Poll budget in seconds |
| `dry_run` / `confirm` | triad | dry-run validates the target and previews side effects — for a physical flavor that includes `downtime: true`, the step `plan`, and any `takeover_leftover` warning |

dry-run verifies the snapshot exists/`done`, or that `time` falls in a
covered chunk (`TIME_NOT_COVERED` otherwise; note the first chunk after
enabling PITR can take ~2 minutes to flush), and reports the resolved
`restore_flavor` plus whether PITR will be disabled. Confirm disables PITR
when needed, restores, and returns `pitr_was_enabled` /
`pitr_enabled_now:false` / `post_restore_required`; physical results add
`downtime: true`, `takeover_reverted` and `metadata_resynced`.
Failure codes: `INVALID_INPUT`, `BACKUP_NOT_FOUND`, `BACKUP_NOT_RESTORABLE`,
`UNSUPPORTED_BACKUP_TYPE`, `TIME_NOT_COVERED`, `PITR_DISABLE_FAILED`,
`PSMDB_REQUIRED`, `PHYSICAL_UNSUPPORTED_SPEC`, `TAKEOVER_PATCH_FAILED`,
`TAKEOVER_PODS_NOT_READY`, `RESTORE_START_FAILED`, `RESTORE_FAILED`,
`WAIT_TIMEOUT` (physical: takeover deliberately left in place),
`REVERT_FAILED`, `POST_RESTORE_UNHEALTHY`.

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

### `pbm/schedule` — gated

| Input | Required | Meaning |
|---|---|---|
| `schedule` | to create | Five-field cron expression, e.g. `0 2 * * *` |
| `type` | no (`logical`) | Backup type for scheduled runs — `physical`/`incremental` prerequisites are re-checked by `pbm/backup` at every run |
| `enabled` | no | `false` suspends the schedule (definition kept), `true` resumes |
| `remove` | no (`false`) | Deletes the managed CronJob; exclusive with the other inputs |
| `dry_run` / `confirm` | triad | dry-run shows the current schedule and the exact diff confirm would apply |

Manages the aqsh-owned CronJob described in [Scheduling](#scheduling) —
see there for why PBM itself cannot do this. Unset inputs inherit the live
values (e.g. `enabled=false` alone suspends without touching the cron
expression). Failure codes: `INVALID_INPUT`, `NO_PBM_AGENT` (a schedule
without a PBM-capable deployment would just fail every tick),
`SCHEDULE_APPLY_FAILED`.

### `pbm/config` — gated

Only the triad. dry-run: current PBM storage vs the deployment-resolved
location (credentials redacted), `in_sync`, and the action confirm would
take. confirm: applies the resolved location + `--force-resync` (an
already-in-sync confirm is a reported no-op). This is the **sanctioned path
for storage migrations** — update the internal-config ConfigMap first, then
dry_run → confirm.

## Usage Scenarios

Scenario quick reference:

| Scenario | Operation |
|---|---|
| Routine backup cycle (daily/weekly) | `pbm/schedule schedule="0 2 * * *"` (dry_run → confirm); change the cycle with another call |
| Shrink the data-loss window to minutes | `pbm/pitr enabled=true oplog_span_min=1` |
| Bad write / accidental drop at time T | `pbm/restore time=<T-1s>` (dry_run validates coverage first) |
| Bad data confined to one collection | `pbm/restore time=<T-1s> ns=mydb.orders` (selective — other collections untouched) |
| Roll back to a specific backup | `pbm/restore backup_name=<name>` |
| Storage migration: new MinIO endpoint/bucket | update internal config → `pbm/config` dry_run → confirm |
| Retention: keep 30 days | `pbm/delete older_than=30d` dry_run → confirm |
| Diagnose a failed backup | `pbm/logs event=backup/<name>` |
| Hundreds of GB — backup/restore duration is the bottleneck | `pbm/backup type=physical` (restore needs a maintenance window — [takeover](#physical-restore)) |
| Large data backed up often, without full re-uploads | `pbm/backup type=incremental` (first call auto-becomes the `--base`) |

**1. First backup on a fresh deployment** (storage auto-ensures itself):

```json
POST /tasks/pbm%2Fbackup
{"namespace": "mongo-1"}
```

**2. Scheduled daily backup** — one call; aqsh owns the CronJob plumbing
(see [Scheduling](#scheduling) for why PBM itself has no scheduler):

```json
POST /tasks/pbm%2Fschedule
{"namespace": "mongo-1", "schedule": "0 3 * * *"}
→ review the dry-run diff, then:
{"namespace": "mongo-1", "schedule": "0 3 * * *",
 "dry_run": "false", "confirm": "true"}
```

Change the cycle by calling again with a new `schedule`; pause with
`{"enabled": "false"}`; delete with `{"remove": "true"}`. Environments
that already run their own scheduler can keep POSTing `pbm/backup`
directly — the API is stateless either way.

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

**8. Large data set — physical base + incremental chain + PITR:**

```json
POST /tasks/pbm%2Fbackup   {"namespace": "mongo-1", "type": "physical"}
POST /tasks/pbm%2Fbackup   {"namespace": "mongo-1", "type": "incremental"}   ← auto --base on first call
POST /tasks/pbm%2Fpitr     {"namespace": "mongo-1", "enabled": "true", ...}  ← chunks slice on top
```

Restore (full-cluster downtime — plan a maintenance window):

```json
POST /tasks/pbm%2Frestore
{"namespace": "mongo-1", "backup_name": "2026-07-11T03:00:12Z"}
→ dry-run shows restore_flavor=physical, downtime:true and the step plan;
{"namespace": "mongo-1", "backup_name": "2026-07-11T03:00:12Z",
 "dry_run": "false", "confirm": "true", "wait_timeout": "2400"}
```

A `time=` restore whose picked base is physical runs the same takeover and
replays the oplog on top; the result names the base
(`restored.base_snapshot` / `base_type`).

**9. MinIO endpoint migration:**

1. Update `PBM_S3_ENDPOINT_DEFAULT` (or `MINIO_ENDPOINT`) in the
   internal-config ConfigMap — propagates to the mounted file in ~1 minute,
   no aqsh restart.
2. `pbm/config` dry-run → shows current vs resolved diff.
3. `pbm/config` confirm → applies + force-resync; backups already under the
   new location become visible to `pbm/list`.

## Choosing a Backup Type: Logical vs Physical/Incremental

| | Logical | Physical | Incremental |
|---|---|---|---|
| Mechanism | dump/insert over MongoDB connections | data-file copy via `$backupCursor` | physical, changed blocks only |
| Engine | any | **PSMDB only** | **PSMDB only** |
| Sweet spot | small–medium data (tens of GB) | very large data (100GB–TB): much faster, no index rebuild on restore | large data backed up often — tiny uploads after the base |
| Backup impact | dump load on mongod | file streaming, cluster stays online | file streaming, cluster stays online |
| Restore impact | mongod keeps running | **full-cluster downtime** ([takeover](#physical-restore)) | same — PBM reconstructs base + increments itself |
| Selective (`ns`) | ✅ | ❌ | ❌ |
| PITR | ✅ | ✅ (point-in-time restore also runs the takeover) | ✅ (ditto) |

Rule of thumb: start logical; switch the base to physical/incremental when
backup or restore duration becomes the bottleneck — and budget the
maintenance window physical restores need.

## Physical Restore

<a id="physical-restore"></a>PBM's physical restore protocol requires
pbm-agent to stop mongod, replace the data files, and spawn temporary
mongod processes (Percona's container guidance: PBM and mongod binaries in
the same container). In a plain StatefulSet mongod is the container's
PID 1: a sidecar can't stop it, and if it exits the kubelet restarts it
with its *original* arguments — exactly what the restore must prevent. The
Percona Operator solves this by taking over the StatefulSet; **this gateway
does the same takeover itself**, with the annotation-tracked surgical
patch/revert pattern the recovery library pioneered:

```text
pbm/restore (physical/incremental target, confirm=true)
  1  disable PITR if enabled (shared contract)
  2  snapshot the original shape → pbm-restore/original annotation
  3  strategic-patch the StatefulSet into TAKEOVER mode:
       • initContainer copies pbm/pbm-agent (static Go binaries) from the
         agent sidecar's image into an emptyDir → /opt/pbm-bin
       • mongod container command → supervisor: original mongod command
         line as a background child + pbm-agent in a foreground retry loop
         (agent can now stop/start mongod freely inside the container)
       • PBM_MONGODB_URI env copied verbatim from the sidecar spec
         (dependency closure of $(VAR) refs — read live, never guessed)
       • probes removed; the normal agent sidecar parked on sleep
  4  force-recreate all pods on the takeover template; wait agents ok
  5  pbm restore <name>   (or --time T --base-snapshot <base>)
  6  poll progress ON THE S3 STORAGE (describe-restore -c … — the
     database is down; the config is piped via stdin, never on an argv)
  7  surgical revert (original command/args/probes back, injected
     env/volume/initContainer $patch:delete'd, annotations cleared)
  8  force-recreate all pods → mongod boots on the RESTORED data
  9  pbm config --force-resync  → result carries post_restore_required
```

Failure handling: every step before the restore starts rolls the takeover
back automatically. A **wait timeout does NOT roll back** (agents may still
be copying — reverting mid-flight would corrupt the restore): the takeover
is left in place, `pbm/status` shows `physical_restore_in_progress: true`,
and the next `pbm/restore` confirm reverts the leftover first — only do
that after verifying the previous restore actually finished or died
(`pbm/logs`). If the post-restore revert itself fails (`REVERT_FAILED`),
the `pbm-restore/original` annotation still holds the original shape for a
manual or retried revert — the restored data is already on disk at that
point.

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
| `PBM_SCHEDULE_CRONJOB_DEFAULT` | `pbm-backup-schedule` | Name of the CronJob `pbm/schedule` manages (RBAC-pinned — `mongodb.scheduleCronjob` chart value) |
| `PBM_SCHEDULE_AQSH_URL_DEFAULT` | `http://aqsh.mongo-core.svc.cluster.local:4180` | In-cluster aqsh URL scheduled runs submit to |
| `LOG_LEVEL_DEFAULT` | `INFO` | Baseline task log verbosity (`log_level` input overrides per call) |

## RBAC Requirements

Everything the recovery/fcv/reconfig family already has covers `pbm/*`
except one addition: `get` on the S3 credentials secret, pinned by name.

| Permission | Used for |
|---|---|
| `pods/exec` create *(existing)* | running `pbm` inside the agent sidecar / takeover container |
| `statefulsets` get, **patch** *(existing, pinned)* | agent auto-detect; the physical-restore takeover patch/revert |
| `pods` get/list/**delete** *(existing)* | probe-pod selection; takeover pod recreation |
| `secrets` get pinned to **`minio`** *(new — `mongodb.backupSecret` chart value)* | rendering `pbm config` credentials, bucket pre-creation, storage-side restore progress |
| `batch/cronjobs` get/patch/delete pinned to **`pbm-backup-schedule`** + namespace-wide create *(new — `mongodb.scheduleCronjob` chart value; create can't be pinned, same as configmaps)* | the `pbm/schedule` managed CronJob |

The physical-restore takeover introduces **no new RBAC**: the patch/delete
verbs were already granted for the recovery/* self-heal machinery.

The MongoDB credentials secret is *not* needed by these tasks.

## Production Hardening

- **Dedicated PBM user instead of root** in `PBM_MONGODB_URI`: create a user
  with the [role Percona documents for PBM](https://docs.percona.com/percona-backup-mongodb/install/configure-authentication.html)
  (`readWrite` on `admin.pbmRoles` etc. via a custom `pbmAnyAction` role)
  and wire its secret into the sidecar. The tasks are agnostic — they never
  see the URI.
- **Percent-encode URI credentials**: when composing `PBM_MONGODB_URI` from
  secret-backed env vars (`mongodb://$(USER):$(PASS)@localhost:27017`), a
  password containing `@ : / %` breaks URI parsing — encode those characters
  (`@` → `%40`, …) in the secret value or the composition. A field-tested
  gotcha, not a theoretical one.
- **keyFile hygiene** (auth-enabled replica sets): mongod rejects keyFiles
  with stray whitespace or too-open permissions — copy from the Secret via
  an initContainer with `chmod 400` under mongod's own runAsUser (see
  `tests/mongodb/pbm_helpers.bash` for a working example).
- **Per-deployment S3 credentials**: replace the sandbox's MinIO root
  credentials in the `minio` secret with a scoped access key. For
  TLS-fronted object storage, note PBM's `insecureSkipTLSVerify` exists for
  lab use only — front production storage with a real certificate.
- **Retention automation**: `pbm/schedule` covers backups only — pair it
  with your own recurring `pbm/delete older_than=30d` call (dry-run it
  manually first).
- **Physical restore = maintenance window**: rehearse the takeover restore
  in staging and time it — the whole cluster is down from step 4 to step 8
  of the [takeover flow](#physical-restore).

## Future Work

- **`external` backups** (storage-level snapshots coordinated by PBM) —
  needs infra-owned snapshot tooling.
- Restore-into-a-new-cluster (side-by-side) flows for surgical data salvage.
