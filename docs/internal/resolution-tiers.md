# Resolution tiers — how tasks resolve a value

Reference for the resolution machinery summarised in `AGENTS.md` →
*Configuration Layers*. Read `AGENTS.md` for the rule (which layer does a value
belong to). Read this when you need to know **how a specific tier actually
works**, or **which tier combination a given task family uses**.

---

## The four tiers

| Tier | Source | Set by |
|------|--------|--------|
| Task input | `input:` in `tasks-*.yaml`, arriving as an env var | The caller, per call |
| Internal config | `aqsh-tasks/config/*.env` → ConfigMap → `/etc/aqsh/config/*.env` | The deployment, once |
| Auto-detect | Live Kubernetes / database state | Nobody — discovered |
| Hardcoded fallback | A literal in `lib/*.sh` | The repo |

Not every family uses all four. The two recurring combinations are:

**With a task-input tier** (account tasks):

1. Task input — non-empty only if the caller explicitly passed it (YAML
   `default: ""`, never a literal)
2. Internal config — a `*_DEFAULT`-suffixed env var
3. Library hardcoded fallback — keeps zero-config use working

```bash
[[ -f /etc/aqsh/config/mongodb.env ]] && source /etc/aqsh/config/mongodb.env
_STS="${MONGO_STS_NAME:-${MONGO_STS_NAME_DEFAULT:-mongodb}}"
```

The distinct `*_DEFAULT` name is deliberate: sourcing the internal config file
can never silently clobber an explicit caller override, because it writes to a
different variable.

**Without a task-input tier** (destructive families — see the registry below):

1. Internal config — `*_DEFAULT`-suffixed env var
2. Auto-detect — live cluster state
3. Library hardcoded fallback — Bitnami helm chart paths

These families do NOT declare `sts_name`, `recovery_configmap`,
`credential_secret`, `credential_user`, `credential_user_key`,
`credential_pass_key`, `data_path`, or `mount_path` as task inputs at all.
They operate close to a destructive action, so the API surface is deliberately
kept to `namespace` plus the genuinely per-call operational decisions
(`target_pod`, `force_wipe`, `level`/`force_primary_pod`, `wait_timeout`).

If a deployment's naming convention is so unusual that neither auto-detect nor
the hardcoded fallback resolves it, internal config remains the only override —
there is no per-call escape hatch for these families, by design.

---

## Registry — which family uses which combination

> ✅ **This table is checked.** `tests/unit/aqsh/resolution_registry_drift.bats`
> asserts the set of namespaced task families in `tasks-mariadb.yaml` +
> `tasks-mongodb.yaml` is exactly the set named in the first column below. Add a
> family without a row here, or leave a row for a family that no longer exists,
> and `bats --recursive tests/unit` goes red in seconds.
>
> The check is set equality with **no exemption list** — that is deliberate. An
> allowlist is itself a registry, and it would drift the same way.

| Task family | Tiers | Family-specific notes | Docs |
|-------------|-------|-----------------------|------|
| MongoDB account tasks | input → config → fallback | The worked example for the task-input tier | [account-lifecycle](../mongodb/account-lifecycle.md) |
| `recovery/*` | config → auto-detect → fallback | `pre-check`, `wipe`, `reset`, `status`, `fix-no-primary`, `recover`. `target_pod` optional for `wipe`/`recover` — see below | [recovery](../mongodb/recovery.md) |
| `reconfig/*` | config → auto-detect → fallback | `plan`, `apply`, `force-dr`, `freeze`. Policy knobs `RECONFIG_*` are internal-config only | [reconfig](../mongodb/reconfig.md) |
| `fcv/*` | config → auto-detect → fallback | `status`, `set` | [fcv](../mongodb/fcv.md) |
| `pbm/*` | config → auto-detect → fallback | Agent container name, storage location, and S3 credentials are internal-config/auto-detect only. **Never loads MongoDB credentials at all** | [pbm](../mongodb/pbm.md) |
| `sts/*` | config → auto-detect → fallback | `sts/orphan-delete` only. `kubectl delete --cascade=orphan`; step 1 of the PVC-enlarge workaround. PVC resize / STS recreate stay manual | [sts-orphan-delete](../mongodb/sts-orphan-delete.md) |
| `oplog/*` | config → auto-detect → fallback | Oplog size is per-node state. `oplog/resize` applies to **every current member** rather than taking one | [oplog](../mongodb/oplog.md) |
| `ops/*` | config → auto-detect → fallback | `currentOp` is per-node → optional `target_pod`, defaulting to the elected PRIMARY | [ops](../mongodb/ops.md) |
| `profiler/*` | config → auto-detect → fallback | Profiler level is per-node → same optional `target_pod` | [profiler](../mongodb/profiler.md) |
| `mql/*` | config → auto-detect → fallback | `mql/read` takes the same optional `target_pod`; `mql/write` always targets the elected PRIMARY. `admin`/`local`/`config` are always refused regardless of internal config | [mql](../mongodb/mql.md) |
| `secrets/*` | **own contract** | DB-agnostic, served by BOTH gateways from one script. See below | [mongodb](../mongodb/secrets.md) · [mariadb](../mariadb/secrets.md) |
| `pods/*` | auto-detect (instance name) | Same API shape on both gateways, **different scripts**. See below | [mongodb](../mongodb/pods.md) · [mariadb](../mariadb/pods.md) |
| `blue-green/*` | **input-forward — the exception** | The only *namespaced* family that exposes its resolution fields (`mdb`, `blue_name`, `green_name`, `green_namespace`) as task inputs. It orchestrates two instances across two AQSH gateways, so the caller genuinely names both sides per call, and it carries `peer_aqsh_url` + `peer_token` — the caller's own bearer token, forwarded so the peer gateway acts *as the caller* | [blue-green](../mariadb/blue-green.md) |
| `common/*` | **none** | `common/hello` — smoke test, takes `name` and resolves nothing. Listed so the drift check needs no exemption list | — |
| MariaDB object storage | **own 4-tier order** | Scoped exception to generic live auto-detection | [object-storage-resolution](../mariadb/object-storage-resolution.md) |

---

## How auto-detect works

Auto-detect queries live state instead of guessing a Bitnami-vs-official image
profile:

| Value | Detected from |
|-------|---------------|
| `sts_name` | The target pod's `ownerReferences` |
| `credential_*` | The StatefulSet's own container env — `secretKeyRef` for `MONGO_INITDB_ROOT_USERNAME/PASSWORD` or `MONGODB_ROOT_USER/PASSWORD`, or the Bitnami file-mounted-secret convention (a `*_FILE`-suffixed env var holding a path into a Secret-backed volume mount) |
| `recovery_configmap` | The `data-recovery` init container's own volume binding |
| Headless Service | The StatefulSet's own `spec.serviceName` — used to build pod seed FQDNs (`<sts>-0.<headless-svc>.<ns>.svc.cluster.local`). **Never assumed to equal the StatefulSet name**: Bitnami's chart commonly names it `<release>-headless`. Tier-1 override is `MONGO_HEADLESS_SVC_DEFAULT` |
| `data_path` / `mount_path` | mongod itself — `db.serverCmdLineOpts().parsed.storage.dbPath`, falling back to mongod's compiled-in default `/data/db` when no `--dbpath`/config-file setting was given |

Implementation: the `_recovery_detect_*` / `recovery_resolve_*` functions in
`aqsh-tasks/lib/mongodb-recovery.sh`.

**One detected `data_path` serves both the `du` (G5) and `df` (G6) checks** —
`df` reports stats for whichever filesystem backs a path even when that path is
a subdirectory of the real mountpoint, so a second detection would be redundant.

**Healthy-peer fallback.** `data_path`/`mount_path` detection queries the
*target pod* first, but `target_pod` is frequently the broken pod recovery
exists to fix — its mongod may not answer at all. When the direct query fails
and the StatefulSet name is known, `recovery_resolve_data_paths` asks any OTHER
pod in the same StatefulSet: every member shares one pod template, so a healthy
peer's dbPath is the value `target_pod` would report if it could answer.

**`target_pod` selection for `wipe`/`recover`.** When omitted, the script calls
`recovery_detect_target_pod` to find the first not-Ready non-primary pod
(highest ordinal wins when several qualify). Pass it explicitly to force-wipe a
healthy pod or to override the auto-selected candidate.

### Detection fails soft

If auto-detect finds no confident signal — a StatefulSet with no env-based
credential wiring, or more than one StatefulSet in the namespace with no target
pod to disambiguate — it returns **nothing** and resolution falls through to the
hardcoded fallback exactly as before. It never guesses.

⚠️ Failing soft means a permanently-broken detection is **indistinguishable
from a working one** at the API. Report the winning tier in the result payload
so an operator can tell the difference.

Failing soft also does not change what RBAC permits: the ClusterRole's
`resourceNames` must already match the *real* object names for the deployment to
work at all, whether the script learned those names from config or detected them
live. Template the RBAC chart from the same chart values that produce the
internal config — see `tests/chart/templates/mongodb-rbac.yaml`.

---

## Self-healing the missing init container (gate G1)

`recovery/*` runs eight pre-flight gates, G1-G8; each reports a
`{"gate":"G1",...}` line. **G1 is the one that checks the `data-recovery` init
container is present in the StatefulSet spec** — the full gate table is in
[recovery](../mongodb/recovery.md#pre-flight-gates-g1g8).

`wipe`/`recover` (gate mode only — `pre-check` stays read-only) go one step
beyond detection when that init container is missing: instead of failing G1 with
a manual-setup suggestion, they patch it in live.

- **Volume name / mount path** detected from the main container's own existing
  `volumeMounts` against the already-detected `data_path` — works for any
  layout, not a Bitnami-vs-official guess.
- **`runAsUser`** read from the container/pod `securityContext`, falling back to
  an image-name guess only when neither is set.
- **No side-effect restarts.** The same patch call locks
  `updateStrategy.rollingUpdate.partition` at the current replica count, so no
  pod — including ones already `Running` — restarts. Only a later, separate wipe
  lowers the partition for the one targeted pod.
- **Missing ConfigMap is created too** (`kubectl create --dry-run=client -o yaml
  | kubectl apply -f -`, so a concurrent create is a no-op, not a race). A fresh
  StatefulSet self-heals end-to-end in one `wipe`/`recover` call.

**RBAC** — two verbs beyond the StatefulSet `patch` that
`recovery_wipe_pod`/`recovery_reset` already require:

- `create` on `configmaps`, **namespace-wide** — Kubernetes RBAC ignores
  `resourceNames` for `create`, since there is no existing object to match.
- `delete` on `pods` — `recovery_wipe_pod` force-deletes the target pod when it
  is not Ready, because the StatefulSet rolling-update controller (OrderedReady)
  will not evict an unhealthy pod on its own, deadlocking when the pod is broken
  by design.

See `tests/chart/templates/mongodb-rbac.yaml`.

**Reverting.** The StatefulSet is annotated `recovery/auto-patched: "true"` so
`recovery_reset` — called automatically at the end of `recover`'s cycle, or by a
later standalone `reset` — reverts exactly the temporary init-container/volume
addition, restoring the original shape. See
`_recovery_auto_patch_init_container` / `_recovery_revert_auto_patch` in
`aqsh-tasks/lib/mongodb-recovery.sh`. The ConfigMap self-heal may have created
is never reverted — harmless, reusable state, not tied to one recovery cycle.

**Fails soft, like detection.** If the ConfigMap can't be read or created (RBAC
denies it), or no confident volume-mount signal is found, G1 fails as it always
has. The One-Time Setup script remains available for deployments self-heal can't
resolve, but is no longer a required first step.

---

## Families with their own contract

### `secrets/*`

DB-agnostic — `pubkey`, `get`, `plan`, `apply`, `delete`, served by BOTH
gateways from the shared `scripts/secrets/` + `lib/secrets.sh`. **None of the
tier rules above apply**: there is no `target_pod`, no destructive-wipe
semantics, and no StatefulSet/credential resolution chain.

Task inputs are `namespace`, `secret_name`, and a PGP-encrypted `payload` (plus
`mode`, and `plan_hash` for `apply`). The deployment PGP key path and the
protected-secret list are internal-config/auto-detect only, and secret VALUES
arrive PGP-encrypted against the deployment key — never as plaintext task inputs.

### `pods/*`

`pods/list` and `pods/delete`, served by BOTH gateways. API-shape-agnostic
across DBs (same inputs, gating, result-code contract) but — unlike `secrets/*`
— **not the same script**. Each gateway resolves its own instance and member-pod
list with its own library:

- MongoDB: `mongodb-recovery.sh`'s `recovery_resolve_sts_name` + `k8s.sh`'s
  `_k8s_sts_owned_pod_names`
- MariaDB: `mariadb.sh`'s `mariadb_autodetect_target` + `mariadb_list_member_pods`

They share only a small generic K8s-status/identity helper (`lib/pods.sh`).

Pure Kubernetes-API operations — neither task connects to the database engine or
reads a credential, so `pods/list` works **even when the database is down**, and
both work unchanged across MongoDB's Bitnami/official image split.

The instance name is not a task input (auto-detect tier, same as `ops/*`).
`pods/delete`'s `target_pod` is required and is verified against that specific
Pod's own `ownerReferences` (`pods_fetch_json` + `pods_owned_by_sts`) before any
delete — `POD_NOT_MEMBER` otherwise. This is a task-level safety boundary
independent of the underlying RBAC grant, which is an unscoped `delete` on
`pods` in the namespace.

Checking the target Pod's **own object**, rather than deriving membership from a
separately-listed live member set, is what makes `POD_ALREADY_DELETED` reachable
for an already-gone target instead of that case always surfacing as
`POD_NOT_MEMBER` first.

A confirmed delete (`dry_run=false`) additionally requires `pod_uid` — the
target's UID from the preceding dry-run — and rejects with `POD_REPLACED` if the
live UID no longer matches. `kubectl delete` has no UID-precondition flag, so
this is a script-level check immediately before a name-based
`kubectl delete pod`, not a server-enforced one: it closes the *realistic*
window — the often human-paced gap between a dry-run and its confirm — but a
replacement created between the check and the delete itself would still be hit.

Whether the delete is graceful or forced (`--grace-period=0 --force`) is decided
internally from the pod's own `Ready` condition, never a caller-facing field.
