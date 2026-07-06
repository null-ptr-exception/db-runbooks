# db-runbooks

2-cluster sandbox for database operations automation with aqsh, kube-auth-proxy, kube-federated-auth, and mariadb-operator on Kind clusters.

## kubectl Contexts

| Context | Cluster | Purpose |
|---------|---------|---------|
| kind-cluster-a | cluster-a | Server: aqsh, federated auth, Redis, DB instances, Istio gateway |
| kind-cluster-b | cluster-b | Client: test-client, MinIO, Istio gateway |

Always specify `--context` when running kubectl commands.

## Architecture

```text
test-client (cluster-b)
    │ Bearer Token
    ▼
Istio Gateway (cluster-a:30080)
    ├─ aqsh-mariadb.kind-a.test → aqsh (mariadb tasks)
    ├─ aqsh-mongodb.kind-a.test → aqsh (mongodb tasks)
    └─ fedauth.kind-a.test      → kube-federated-auth

Istio Gateway (cluster-b:30080)
    └─ minio.kind-b.test        → MinIO API
```

Cross-cluster DNS: `*.kind-a.test` → cluster-a IP, `*.kind-b.test` → cluster-b IP (via CoreDNS).

## Namespaces

| Namespace | Cluster | Purpose |
|-----------|---------|---------|
| mongo-core | cluster-a, cluster-b | MongoDB control plane (aqsh, fedauth, test-client) |
| db-ops | cluster-a, cluster-b | MariaDB control plane (aqsh, fedauth, test-client) |
| mongo-1 | cluster-a | MongoDB instance |
| mariadb-1 | cluster-a | MariaDB instance (operator-managed) |
| minio | cluster-b | MinIO object storage |

## Container Images

- `ghcr.io/rophy/kube-federated-auth:3.2.0`
- `ghcr.io/rophy/kube-auth-proxy:0.4.1`
- `ghcr.io/null-ptr-exception/aqsh:0.5.0` (base for `aqsh-tasks` custom image)

## aqsh Tasks

Task scripts live in `aqsh-tasks/scripts/` and are baked into the Docker image via `Dockerfile`.

Deploy-time configuration lives in `aqsh-tasks/config/` (e.g., `mongodb.env`, `mariadb.env`) and is mounted into aqsh at `/etc/aqsh/config/` via ConfigMap.

## Configuration Layers

When adding a new task parameter, decide which layer it belongs to:

- **Internal config** (`aqsh-tasks/config/*.env` → ConfigMap → `/etc/aqsh/config/*.env`,
  sourced by scripts) — for values that are fixed for a given deployment but
  vary *across* deployments: secret/StatefulSet naming conventions, credential
  key names, data/mount paths per image type. A given corporate environment
  doesn't change these between calls; they describe how that environment is
  built.
- **API spec** (`input:` in `tasks-*.yaml`) — for values a caller legitimately
  picks differently on different calls within the *same* deployment: target
  namespace/pod, force flags, account usernames, escalation levels.

**Rule of thumb**: if two environments could reasonably want different
values for X, but one environment wants the *same* value of X on every call,
X is internal config, not a task input. `credential_secret`, `credential_user`,
`credential_user_key`, `credential_pass_key`, `sts_name`, `recovery_configmap`,
`data_path`, `mount_path` (MongoDB account tasks) follow this
pattern as optional task inputs with internal-config + hardcoded-literal
fallback. MongoDB `recovery/*` and `sanity-check` tasks go a step further and
don't expose these fields as task inputs *at all* — see "Auto-detect tier" below.

**Resolution order for account tasks** (3 tiers — see MongoDB account scripts
for a worked example; MongoDB `recovery/*` and `sanity-check` use a variant
without the task-input tier — see "Auto-detect tier" below):

1. Task input — only non-empty if the caller explicitly passed it (YAML
   `default: ""`, not a literal)
2. Internal config — sourced into a `*_DEFAULT`-suffixed env var
   (e.g. `MONGO_STS_NAME_DEFAULT`), set once per deployment
3. Library hardcoded fallback — keeps zero-config use working

```bash
[[ -f /etc/aqsh/config/mongodb.env ]] && source /etc/aqsh/config/mongodb.env
_STS="${MONGO_STS_NAME:-${MONGO_STS_NAME_DEFAULT:-mongodb}}"
```

A distinct `*_DEFAULT` variable name (rather than reusing the task-input env
var name) is deliberate: sourcing the internal config file can never silently
clobber an explicit caller override, because it writes to a different name.

**Auto-detect tier (MongoDB `recovery/*`, `reconfig/*`, and `fcv/*` tasks)**:
`pre-check`, `wipe`, `reset`, `status`, `fix-no-primary`, and `recover` —
plus the reconfig gateway tasks (`reconfig/plan`, `reconfig/apply`,
`reconfig/force-dr`, `reconfig/freeze`; see `docs/mongodb/reconfig.md`,
which also keeps its policy knobs `RECONFIG_*` internal-config only) and
the FCV gateway tasks (`fcv/status`, `fcv/set`; see `docs/mongodb/fcv.md`) —
do NOT declare `sts_name`,
`recovery_configmap`, `credential_secret`, `credential_user`,
`credential_user_key`, `credential_pass_key`, `data_path`, or `mount_path` as
task inputs at all — these tasks operate on something close to a destructive
action (wipe a pod's data), so the API surface is deliberately kept to just
`namespace` + the genuinely per-call operational decisions (`target_pod`,
`force_wipe`, `level`/`force_primary_pod`, `wait_timeout`). `target_pod` is
optional for `wipe` and `recover`: when omitted, the script calls
`recovery_detect_target_pod` to find the first not-Ready non-primary pod
(highest ordinal wins when multiple candidates exist); specify it explicitly
to force-wipe a healthy pod or to override the auto-selected candidate. Resolution is a
3-tier chain with no task-input override:

1. Internal config — `*_DEFAULT`-suffixed env var, set once per deployment
2. Auto-detect — query live cluster state instead of guessing a
   Bitnami-vs-official-image profile: `sts_name` from the target pod's
   `ownerReferences`, `credential_*` from the StatefulSet's own container env
   (`secretKeyRef` for `MONGO_INITDB_ROOT_USERNAME/PASSWORD` or
   `MONGODB_ROOT_USER/PASSWORD`, or the Bitnami file-mounted-secret
   convention — a `*_FILE`-suffixed env var holding a path into a
   Secret-backed volume mount), `recovery_configmap` from the
   `data-recovery` init container's own volume binding, and
   `data_path`/`mount_path` by asking mongod itself for its real dbPath
   (`db.serverCmdLineOpts().parsed.storage.dbPath`, falling back to
   mongod's own compiled-in default `/data/db` when no `--dbpath`/config-file
   setting was given), reusing that single detected value for both `du`
   (G5) and `df` (G6) checks since `df` reports stats for whichever
   filesystem backs a path even when it's a subdirectory of the real
   mountpoint. `data_path`/`mount_path` detection queries the *target pod*
   first, but `target_pod` is frequently the broken pod recovery exists to
   fix — its mongod may not answer at all. When the direct query fails and
   the StatefulSet name is known, `recovery_resolve_data_paths` falls back
   to asking any OTHER pod in the same StatefulSet: every member shares the
   same pod template, so a healthy peer's dbPath is the value target_pod
   would report if it could answer. See the `_recovery_detect_*` /
   `recovery_resolve_*` functions in `aqsh-tasks/lib/mongodb-recovery.sh`.
3. Library hardcoded fallback — Bitnami helm chart paths

Detection always fails *soft*: if it can't find a confident signal (e.g. a
StatefulSet with no env-based credential wiring, or more than one StatefulSet
in the namespace with no target pod to disambiguate), it returns nothing and
resolution falls through to tier 3 exactly as before — it never guesses.
This doesn't change what RBAC permits: the ClusterRole's `resourceNames`
must already match the *real* object names for the deployment to work at
all (see below), regardless of whether the script learns those names from
config or by detecting them live.

If a deployment's naming convention is so unusual that neither auto-detect
nor the hardcoded fallback can resolve it (e.g. credentials provisioned with
no live signal in the StatefulSet spec at all), internal config remains the
only override — there is no per-call escape hatch for `recovery/*` tasks by
design.

**G1 self-heal**: `wipe`/`recover` (gate mode only — `pre-check` stays
read-only) go one step further than detection when the `data-recovery` init
container itself is missing: instead of just failing G1 with a manual-setup
suggestion, they patch it in live — volume name/mount path detected from the
main container's own existing `volumeMounts` against the already-detected
`data_path` (works for any layout, not a Bitnami-vs-official guess), and
`runAsUser` read from the container/pod `securityContext` (falling back to
an image-name guess only when neither is set). The same patch call locks
`updateStrategy.rollingUpdate.partition` at the current replica count, so no
pod — including the ones already `Running` — restarts as a side effect; only
a later, separate wipe lowers the partition for the one targeted pod. If the
recovery ConfigMap itself doesn't exist either (a deployment that has never
had the One-Time Setup run on it at all), self-heal creates it too (`kubectl
create --dry-run=client -o yaml | apply -f -`, so a concurrent create is a
no-op, not a race) — a fully fresh StatefulSet self-heals end-to-end in one
`wipe`/`recover` call, with no separate manual step. This needs two RBAC
verbs beyond the StatefulSet `patch` verb `recovery_wipe_pod`/`recovery_reset`
already required: `create` on `configmaps` (namespace-wide — Kubernetes RBAC
ignores `resourceNames` for `create` requests, since there's no existing
object yet to match against), and `delete` on `pods` — `recovery_wipe_pod`
force-deletes the target pod when it is not Ready, because the StatefulSet
rolling-update controller (OrderedReady policy) will not evict an unhealthy
pod on its own, creating a deadlock when the pod is broken by design
(see `tests/chart/templates/mongodb-rbac.yaml`). The StatefulSet is
annotated `recovery/auto-patched: "true"` so `recovery_reset` (called
automatically at the end of `recover`'s cycle, or by a later standalone
`reset` call) knows to revert exactly the temporary init-container/volume
addition, restoring the StatefulSet to its original shape — see
`_recovery_auto_patch_init_container`/`_recovery_revert_auto_patch` in
`aqsh-tasks/lib/mongodb-recovery.sh`. (The ConfigMap self-heal may have
created is never reverted — it's harmless, reusable state, not something
tied to one recovery cycle.) Fails soft exactly like detection: if the
ConfigMap can't be read or created (e.g. RBAC denies it), or no confident
volume-mount signal is found, G1 just fails as it always has — the One-Time
Setup script below remains available for deployments self-heal can't
resolve, but is no longer a required first step.

If a value like this also gates RBAC (e.g. `resourceNames` pinned to a
StatefulSet/Secret/ConfigMap name), template the RBAC chart from the same
chart values that produce the internal config, so a non-default convention
doesn't get silently denied — see `tests/chart/templates/mongodb-rbac.yaml`.

## Test Suites

Each DB type has its own test suite under `tests/<db>/` with:
- `helmfile.yaml` — defines Helm releases for the suite
- `setup_suite.bash` — builds image, deploys via helmfile, waits for readiness
- `*.bats` — test files using bats-core

```bash
# Run a single suite
bats tests/mongodb/
bats tests/mariadb/

# Shared infra (Istio, Cilium, CoreDNS) is managed by infra/
```

## Infrastructure

Shared infra is in `infra/` and is deployed by each suite's `setup_suite.bash`:
- `infra/ctlptl-infra.yaml` — Kind cluster definitions + local registry
- `infra/helmfile-infra.yaml` — Cilium, Istio, shared gateway
- `infra/deploy.sh` — `setup_infra` function (idempotent)

## Port Allocation

| Service | Port | Notes |
|---------|------|-------|
| Istio HTTP Gateway | 30080 | Both clusters, routes by hostname |
| Istio HTTPS Gateway | 30443 | Both clusters |
| Istio MongoDB | 30090 | Passthrough |
| Istio MariaDB | 30091 | Passthrough |
