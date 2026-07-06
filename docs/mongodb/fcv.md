# MongoDB FCV Gateway (aqsh-mongodb)

`fcv/status` and `fcv/set` manage MongoDB's **featureCompatibilityVersion
(FCV)** — the switch that controls which persisted-data features a replica
set is allowed to use, independent of which binary is running. Upgrading a
MongoDB binary does NOT bump the FCV; downgrading a binary REQUIRES the FCV
to be lowered first. These tasks make both moves safe: every request is
validated against the running binary's documented compatibility table, and
an out-of-range target fails loudly (`INVALID_TARGET`) — never a silent
no-op.

Deployment naming/credential conventions (StatefulSet name, credential
secret and keys) are **not task inputs** — they resolve via internal config
→ live-cluster auto-detect → hardcoded fallback, exactly like `recovery/*`
and `reconfig/*` (see CLAUDE.md "Configuration Layers"). Both official
(`MONGO_INITDB_ROOT_*`) and Bitnami (`MONGODB_ROOT_*`, including
file-mounted `*_FILE` secrets) credential conventions are detected from the
live StatefulSet spec. Callers only ever send `namespace` (+ the target for
`set`).

## Table of Contents

1. [When To Use What (Decision Table)](#when-to-use-what-decision-table)
2. [Version ↔ FCV Compatibility Table](#version--fcv-compatibility-table)
3. [Architecture & Flow](#architecture--flow)
4. [API Reference](#api-reference)
5. [Usage Scenarios](#usage-scenarios)
6. [Transitional State](#transitional-state)
7. [Deployment Settings (Internal Config)](#deployment-settings-internal-config)
8. [RBAC Requirements](#rbac-requirements)

---

## When To Use What (Decision Table)

| Situation | Use | Do NOT use |
|---|---|---|
| "What FCV are we on? What could we move to?" | `fcv/status` (read-only, always safe) | — |
| Binary upgrade finished and burned in — enable the new features | `fcv/set` upgrade (dry_run → confirm) | — |
| Need to roll the binary BACK a major version | `fcv/set` downgrade **first**, then downgrade the binary | downgrading the binary first (mongod will refuse to start) |
| A previous FCV change was interrupted (transitional state) | `fcv/set` with the pending target (finish) or the stable version (roll back) | any other target (refused: `TRANSITIONAL_STATE`) |
| Jumping more than one major version (e.g. 6.0 → 8.0) | two rounds: binary 7.0 + `fcv/set 7.0`, then binary 8.0 + `fcv/set 8.0` | a single `fcv/set 8.0` on a 7.0 binary (refused: `INVALID_TARGET`) |

**Operational guidance**: after a binary upgrade, run with the old FCV for a
burn-in period before raising it — FCV upgrade enables persisted-format
features that make binary downgrade impossible without a full FCV downgrade
first. FCV downgrade is the riskier direction: the server refuses it when
incompatible features are in use (e.g. indexes/collections using
newer-format options), which surfaces as `SET_FCV_FAILED` with the server's
own diagnostic.

---

## Version ↔ FCV Compatibility Table

A mongod binary of series X.Y accepts exactly two FCV values: its own
series and one step back. The predecessor is **not** plain `major-1`
arithmetic in the pre-5.0 era — this table is authoritative (it is the same
table `fcv_previous_series` in `aqsh-tasks/lib/mongodb-fcv.sh` implements;
keep both in sync):

| Binary series | Allowed FCV values | Notes |
|---|---|---|
| 8.0 | `7.0`, `8.0` | |
| 7.0 | `6.0`, `7.0` | `setFeatureCompatibilityVersion` requires `confirm: true` from 7.0 onward — the task adds it automatically |
| 6.0 | `5.0`, `6.0` | |
| 5.0 | `4.4`, `5.0` | ⚠ irregular: predecessor is 4.4, not 4.0 |
| 4.4 | `4.2`, `4.4` | ⚠ irregular: point-release era |
| 4.2 | `4.0`, `4.2` | |
| ≥ 9.0 (X.0) | `(X-1).0`, `X.0` | derived by the annual-release rule |
| anything else (< 4.2, or a non-`.0` series like 7.1) | — | `UNSUPPORTED_SERVER_VERSION` — the task never guesses |

Consequences the tasks enforce:

- Binary 7.0 + requested FCV `5.0` → `INVALID_TARGET` (allowed: `6.0 7.0`).
- Requested FCV above the binary (`8.0` on a 7.0 binary) → `INVALID_TARGET`.
  Upgrade the binary first, then the FCV.
- Multi-major moves are always **binary + FCV in lockstep, one major at a
  time** (see decision table).

---

## Architecture & Flow

The sandbox `mongo-1` namespace runs a 3-member RS (`mongodb-0/1/2`).
Concretely, on this architecture:

```
Operator / test-client (cluster-b)
     │  POST /tasks/fcv%2Fset      {namespace, target_version, dry_run, confirm}
     ▼
aqsh (mongo-core, cluster-a) → mongodb/fcv/set.sh
     │ 1. gate: dry_run/confirm triad (INVALID_INPUT on violations)
     │ 2. resolve (3-tier, no task inputs):
     │      sts_name      config *_DEFAULT → single-STS/ownerRef detect → "mongodb"
     │      credentials   config *_DEFAULT → live STS env secretKeyRef detect
     │                    (official MONGO_INITDB_ROOT_*, Bitnami MONGODB_ROOT_*,
     │                     Bitnami *_FILE file-mounted secrets) → hardcoded keys
     │ 3. kubectl get pods → probe pod (first Ready, fallback Running)
     │ 4. kubectl exec probe → mongosh rs.status() → PRIMARY host:port
     │ 5. kubectl exec probe → mongosh directConnection to PRIMARY:
     │      getParameter featureCompatibilityVersion + db.version()   (read)
     │ 6. validate: series table → allowed set → transitional → direction
     │ 7. dry_run? → DRY_RUN_READY preview and stop
     │ 8. kubectl exec probe → mongosh directConnection to PRIMARY:
     │      adminCommand({setFeatureCompatibilityVersion, confirm?})  (write)
     │ 9. re-read FCV and require it converged at the target
     ▼
result JSON → task .result.data
```

`fcv/status` is steps 2–6 only, ending in a read-only report.

Debug visibility: every resolution decision (which tier won, detected
secret/keys — names only, never values), the probe pod and primary chosen,
the computed allowed-target set, whether `confirm: true` was included, and
each raw mongosh sentinel line are logged at DEBUG level — set `LOG_LEVEL=DEBUG`
on the aqsh container to see them.

---

## API Reference

Base URL (sandbox): `http://aqsh-mongodb.kind-a.test:30080`. Slash-named
tasks are URL-encoded: `POST /tasks/fcv%2Fstatus`, `POST /tasks/fcv%2Fset`.

### `fcv/status` — read-only report

| Input | Required | Meaning |
|---|---|---|
| `namespace` | yes | Namespace of the MongoDB StatefulSet |

Result (`.result.data`):

```json
{
  "namespace": "mongo-1",
  "sts": "mongodb",
  "primary": "mongodb-0.mongodb.mongo-1.svc.cluster.local:27017",
  "server_version": "7.0.21",
  "server_series": "7.0",
  "fcv": "7.0",
  "transitional": false,
  "target_fcv": null,
  "allowed_targets": ["6.0", "7.0"]
}
```

On an unknown binary series the report still completes, with
`allowed_targets: []` and `"warning": "UNSUPPORTED_SERVER_VERSION"` —
read-only status never fails for that; only `fcv/set` does.

### `fcv/set` — gated mutation (dry_run → confirm)

| Input | Required | Default | Meaning |
|---|---|---|---|
| `namespace` | yes | — | Namespace of the MongoDB StatefulSet |
| `target_version` | yes | — | Requested FCV, `X.Y` (e.g. `"6.0"`) |
| `dry_run` | no | `"true"` | Validate + preview only; nothing is changed |
| `confirm` | no | `"false"` | Must be `"true"` when `dry_run` is `"false"` |

Gate rules (identical to the account tasks): `dry_run=true` (default) runs
the full validation and returns a preview; `dry_run=true` + `confirm=true`
is rejected; `dry_run=false` without `confirm=true` is rejected.

Success result:

```json
{
  "status": "ok",
  "reason_code": "FCV_SET",
  "summary": "FCV changed 7.0 -> 6.0 (downgrade).",
  "namespace": "mongo-1",
  "server_version": "7.0.21",
  "previous_fcv": "7.0",
  "current_fcv": "6.0",
  "target_version": "6.0",
  "direction": "downgrade",
  "changed": true,
  "was_transitional": false
}
```

Dry-run result: `status`/`reason_code` `DRY_RUN_READY`, `changed: false`,
`would_change: true`, plus the same `direction`/version fields.

### Result codes

| `reason_code` | Task status | Trigger |
|---|---|---|
| `FCV_SET` | completed | FCV changed and verified converged at the target |
| `DRY_RUN_READY` | completed | Validation passed; preview only, nothing changed |
| `ALREADY_AT_TARGET` | completed | Target equals the current stable FCV — explicit no-op, `changed: false` |
| `INVALID_INPUT` | failed | Gate violation (confirm/dry_run combination) or malformed target |
| `INVALID_TARGET` | failed | Target not in the binary's allowed set — the message lists the allowed values |
| `UNSUPPORTED_SERVER_VERSION` | failed | Binary series not in the compatibility table (and not derivable) |
| `TRANSITIONAL_STATE` | failed | FCV is mid-transition and the target matches neither the pending nor the stable version |
| `NO_PRIMARY` | failed | No Ready/Running pod, or the replica set has no reachable PRIMARY |
| `FCV_READ_FAILED` | failed | Could not read version/FCV from the primary (auth, connectivity) |
| `SET_FCV_FAILED` | failed | The server rejected the change (details carry its `codeName`/message), or the FCV did not converge after the command |

---

## Usage Scenarios

### 1. Check where you stand — anytime, zero risk

```json
POST /tasks/fcv%2Fstatus
{"namespace": "mongo-1"}
```

### 2. Enable new features after a binary upgrade (FCV upgrade)

Binary was upgraded 6.0 → 7.0 and has burned in; FCV is still `6.0`.

```json
POST /tasks/fcv%2Fset
{"namespace": "mongo-1", "target_version": "7.0"}
```

Returns `DRY_RUN_READY` with `direction: "upgrade"`. Then execute:

```json
POST /tasks/fcv%2Fset
{"namespace": "mongo-1", "target_version": "7.0", "dry_run": "false", "confirm": "true"}
```

### 3. Prepare a binary downgrade (FCV downgrade first)

Need to roll the binary back from 7.0 to 6.0. The binary refuses to start
on data newer than its own FCV, so lower the FCV **before** touching the
image:

```json
POST /tasks/fcv%2Fset
{"namespace": "mongo-1", "target_version": "6.0", "dry_run": "false", "confirm": "true"}
```

If incompatible features are in use the server refuses and the task fails
`SET_FCV_FAILED` with the server's diagnostic — nothing is left half-done.

### 4. Finish (or roll back) a stuck transition

`fcv/status` shows `"transitional": true, "fcv": "6.0", "target_fcv": "7.0"`
— a previous setFCV was interrupted. Re-run toward the pending target to
finish, or toward the stable version to abort:

```json
POST /tasks/fcv%2Fset
{"namespace": "mongo-1", "target_version": "7.0", "dry_run": "false", "confirm": "true"}
```

Any other target is refused with `TRANSITIONAL_STATE`.

### 5. What a rejected request looks like

Requesting `5.0` on a 7.0 binary:

```json
{
  "status": "ERROR",
  "reason_code": "INVALID_TARGET",
  "summary": "target FCV 5.0 is not allowed for MongoDB 7.0.21; allowed: 6.0 7.0",
  "details": {"server_version": "7.0.21", "current_fcv": "7.0", "allowed_targets": ["6.0", "7.0"]}
}
```

---

## Transitional State

The FCV document can carry a `targetVersion` field when a
`setFeatureCompatibilityVersion` run was interrupted (e.g. a primary
step-down mid-transition). In that state the effective FCV is the *lower*
of the two versions and some operations are restricted.

- `fcv/status` surfaces it as `transitional: true` + `target_fcv`.
- `fcv/set` only accepts the pending target (finish the transition) or the
  stable version (roll it back) — MongoDB's documented remediation — and
  refuses anything else with `TRANSITIONAL_STATE`.
- After executing, `fcv/set` re-reads the FCV and fails `SET_FCV_FAILED` if
  the document is still transitional — "the command returned ok" is not
  reported as success until the FCV actually converged.

---

## Deployment Settings (Internal Config)

No new keys. The FCV tasks reuse the existing MongoDB resolution defaults
from `/etc/aqsh/config/mongodb.env` (all optional — auto-detect covers a
conventional deployment with zero config):

| Key | Meaning | Touch it? |
|---|---|---|
| `MONGO_STS_NAME_DEFAULT` | StatefulSet name when detection shouldn't run | 不建議動 |
| `MONGO_CRED_SECRET_DEFAULT` | Credential secret name | 不建議動 |
| `MONGO_CRED_USER_DEFAULT` | Literal username (when not stored in the secret) | 不建議動 |
| `MONGO_CRED_USER_KEY_DEFAULT` / `MONGO_CRED_PASS_KEY_DEFAULT` | Keys inside the credential secret | 不建議動 |

---

## RBAC Requirements

No additions. The FCV tasks run entirely within what the existing
`aqsh-mongo-manager` ClusterRole already grants (see
`tests/chart/templates/mongodb-rbac.yaml`):

- `pods` get/list — probe-pod selection and primary discovery
- `pods/exec` create — running mongosh inside a member pod
- `statefulsets` get/list — StatefulSet + credential auto-detection
- `secrets` get (named credential secret) — loading root credentials

`setFeatureCompatibilityVersion` itself is a mongod admin command executed
through `pods/exec`, not a Kubernetes API mutation.
