# task-authoring — adding or changing an aqsh task

The expensive decision in this repo is **which layer a value lives in**. A task
input is a public API promise: once it ships you can add fields but never
remove one, and a value that should have been deployment configuration becomes
a permanent hole a caller can steer. Get this right before writing the script.

The short rule lives in the project guide → *Configuration Layers*. This
document is the decision procedure plus the mistakes that are easy to make.

<!-- This file is the vendor-neutral source of truth. Agent-specific adapters
     point here rather than copying it: .claude/skills/task-authoring/SKILL.md
     for Claude Code, AGENTS.md for everything that reads AGENTS.md. Keep the
     glob list below in sync with those adapters — task_authoring_triggers.bats
     checks it. -->

## When this applies

<!-- TRIGGER-GLOBS-START -->
- `aqsh-tasks/tasks-mariadb.yaml`
- `aqsh-tasks/tasks-mongodb.yaml`
- `aqsh-tasks/config/*.env`
- `aqsh-tasks/scripts/**`
- `tests/chart/templates/*-rbac.yaml`
<!-- TRIGGER-GLOBS-END -->

Read this before editing any of the above, and when reviewing a diff that
touches them. Also read it whenever you are unsure whether a value should be
caller-suppliable, or you are introducing a new reason code.

**Skip it** for pure test edits, docs-only changes, and `infra/` cluster wiring.

## The layer decision

Ask, in order:

1. **Is it *this deployment's own* identity or capability grant** (a Vault role,
   a signing key, the credentials this deployment was provisioned with, an
   endpoint that determines *who we act as*)?
   → **Never a task input**, at any tier. Deploy-time internal config only.
   A credential the **caller** already holds, for a system outside this
   deployment, is not this case — see the note under the worked example.
2. **Would two different deployments reasonably want different values, while
   one deployment wants the same value on every call?**
   → **Internal config** (`aqsh-tasks/config/*.env` → ConfigMap →
   `/etc/aqsh/config/*.env`).
3. **Can the cluster tell us the answer?**
   → **Auto-detect** from live state, in preference to guessing an image/chart
   profile. Must fail soft (below).
4. **Does a caller legitimately pick differently on different calls within the
   same deployment?**
   → **Task input** in `tasks-*.yaml`.

Everything else gets a **library hardcoded fallback** so zero-config use keeps
working.

### Worked example — the migration tasks get this right, both ways

> These three rows are from `feature/migration_integration_mariadb`, not this
> branch — `lib/vault.sh` and the `VAULT_*` block in `config/mariadb.env` land
> with that feature. Kept here because it is the cleanest value-vs-identity
> contrast the repo has.

| Value | Layer | Why |
|-------|-------|-----|
| `minio_endpoint` / `minio_access_key` / `minio_bucket` | **task input**, falling back to `MINIO_*_DEFAULT` | A migration source is legitimately *some other* MinIO than this deployment's own, so no deploy-time value can reach it. Same deployment, different value per call → input. See the credential note below — this is deliberately not a Rule 1 violation. |
| `VAULT_ADDR` / `VAULT_MOUNT` / `VAULT_ROLE_ID` / `VAULT_SECRET_ID` | **internal config only**, no input at any tier | These are not a value, they are an **identity**. Exposing them would let a caller redirect a write to a Vault identity other than the one this deployment was provisioned with. Rule 1. |
| `vault_path` | **task input** | Where the values land, not who may write them. Rule 4. |

Both decisions live in the same feature. When a reviewer asks "why is one
caller-suppliable and the other not?", *that* distinction — value vs identity —
is the answer, and it belongs in the script header the way
`aqsh-tasks/lib/vault.sh` writes it.

#### Why a caller-supplied credential is not a Rule 1 violation

`minio_access_key`/`minio_secret_key` are credential-shaped, so the two rows
above look contradictory until you ask *whose* identity is at stake:

- The **Vault AppRole** is the deployment's own. Accepting it per call would let
  a caller borrow privilege the deputy holds and the caller does not — a
  confused deputy. There is no legitimate reason to override it, because the
  deployment can only ever write as itself.
- The **MinIO keys** belong to the caller's own migration source. They grant
  nothing the caller doesn't already have, and no deploy-time value could reach
  an arbitrary third-party endpoint. Refusing them would not add safety, it
  would just make cross-deployment migration impossible.

So the test is not "does it look like a secret" but **"could a caller use this
to act as someone they aren't?"**

The carve-out is small and enumerable — check yourself against it before
claiming a new one. Credential-shaped inputs across both gateways fall into
three shapes:

| Shape | Inputs | Why it's safe |
|-------|--------|---------------|
| **By reference** (default) | `credential_secret`, `credential_user_key`, `credential_pass_key`, `repl_password_secret`, `repl_password_key`, `password_secret_name`, `password_secret_key`, `secret_name`, `secret_keys` | The value never crosses the API at all — only the name of a Secret the deployment can already read |
| **By value, encrypted** | `secrets/*` `payload` | PGP-encrypted against the deployment key; plaintext never crosses the API |
| **By value, plaintext — the caller's own** | `minio_access_key` / `minio_secret_key` (the caller's migration source), `peer_token` (the caller's own bearer token, forwarded so this gateway can call a peer gateway *as the caller*) | Grants nothing the caller doesn't already hold; no deploy-time value could substitute |

Two entries in that last row, and `peer_token` is the clearest reading of the
rule: it is literally the caller's own identity being forwarded, never the
deployment's. If you think you need a third, you are probably reaching for the
deployment's identity — go back to Rule 1.

A caller-supplied credential still owes three things, all of which the migration
tasks do today — copy them:

1. **Never in the result payload.** `migration-preflight.sh` builds its result
   without any `minio_*` credential field.
2. **Never in a log line.** Log the Secret *name*, never a value.
3. **Never in process argv.** Reach the tool through the environment
   (`export AWS_SECRET_ACCESS_KEY=...`) or stdin, never `--flag "$SECRET"` on a
   command line that `ps -ef` can read. `lib/vault.sh` goes further for the
   token, using a mode-600 `curl --config` file.

Plus the fourth, which is what keeps the common case clean: **fall back to
`*_DEFAULT` deploy-time config**, so a caller migrating within one deployment
sends no secret at all.

### When the API surface should be smaller than the resolution chain

Destructive task families (`recovery/*`, `reconfig/*`, `fcv/*`, `pbm/*`,
`pods/*`, `sts/orphan-delete`) deliberately expose **no** resolution fields as
task inputs at all — not `sts_name`, not `credential_*`, not `data_path`. Their
input surface is `namespace` plus the genuinely per-call operational decisions
(`target_pod`, `force_wipe`, `level`, `wait_timeout`). Follow that precedent for
anything that wipes, deletes, or reconfigures: the resolution chain drops to
internal config → auto-detect → hardcoded, with no per-call escape hatch.

## What already guards you (and what doesn't)

The public input surface **is** pinned by tests — this is the one part of the
convention that is mechanically enforced, so know it before you fight it:

- `tests/unit/aqsh/mariadb_public_inputs.bats` snapshots the **exact ordered
  input list** for each MariaDB task. Adding, removing, or reordering an
  `input:` turns it red.
- `tests/unit/aqsh/task_inputs.bats` forbids `context` / `K8S_CONTEXT` as a
  task input on either gateway, while asserting `lib/k8s.sh` keeps it for local
  CLI use.
- `tests/unit/aqsh/mariadb_namespace_patterns.bats` covers the `pattern:`
  constraints.

⛔ **A red snapshot is the question, not the chore.** The correct response is to
re-run the four-question decision above and justify the new field — then update
the snapshot in the same commit. Updating it first, reflexively, defeats the
only tripwire this repo has on its own API surface.

Run them in seconds: `bats --recursive tests/unit`.

Everything else in this document is convention with no automation. In
particular nothing checks that a `script:` path exists, that a new task got a
docs page, or that a reason code kept its spelling.

## Implementation rules

### 1. `*_DEFAULT` naming is not cosmetic

```bash
[[ -f /etc/aqsh/config/mongodb.env ]] && source /etc/aqsh/config/mongodb.env
_STS="${MONGO_STS_NAME:-${MONGO_STS_NAME_DEFAULT:-mongodb}}"
```

The internal-config variable **must** carry the `_DEFAULT` suffix and must not
reuse the task input's env var name. Sourcing the config file after the task
input is set would otherwise silently clobber an explicit caller override —
and it would do so without any error, which is the worst kind of bug this repo
produces.

Corollary: the YAML `default:` for such an input must be `""`, never a literal.
A literal default is indistinguishable from an explicit caller value, which
collapses tier 1 into tier 3 and makes internal config unreachable.

### 2. Detection fails soft, and says so

Auto-detect returns **nothing** when it has no confident signal — more than one
StatefulSet with no target pod to disambiguate, a credential with no env-based
wiring — and resolution falls through to the next tier. It never guesses.

⚠️ **Report which tier won.** A detection that silently degrades to the
hardcoded Bitnami path on every call — because RBAC is missing a verb, say —
looks identical to one that is working. Include the resolved source in the
result payload (`"resolution": {"sts_name": "autodetect", "data_path":
"fallback"}`) so an operator can tell the difference. Absence of an error is
not evidence that detection worked.

### 3. RBAC is coupled to the naming convention

If a value gates RBAC — anything that ends up in `resourceNames` for a
StatefulSet, Secret, or ConfigMap — **template the RBAC chart from the same
chart values that produce the internal config**. See
`tests/chart/templates/mongodb-rbac.yaml`:

```yaml
resourceNames: [{{ .Values.mongodb.stsName | default "mongodb" | quote }}]
```

A deployment with a non-default naming convention that updates
`config/mongodb.env` but not the chart gets a `Forbidden` at runtime, in a code
path that local tests never reach. Change them in the same commit.

Two Kubernetes RBAC facts worth remembering, because both already shaped rules
in that file:

- `resourceNames` is **ignored for `create`** — there is no existing object to
  match — so a `create` grant is always namespace-wide. Guard in the script
  instead (the `secrets/*` family does this with `PROTECTED_SECRET`).
- Task-level safety boundaries are independent of the RBAC grant.
  `pods/delete` holds an unscoped `delete` on pods but verifies the target's
  own `ownerReferences` first (`POD_NOT_MEMBER`) and its UID against the
  preceding dry-run (`POD_REPLACED`). Write the script-level check; do not
  assume RBAC narrows it for you.

### 4. Gating contract

- Destructive tasks take `dry_run` (`default: "true"`) **and** `confirm`
  (`default: "false"`). The safe combination is the one you get by passing
  nothing.
- Where a plan and its apply are separate calls, carry a **CAS token computed
  from live state**, not a stored TTL token — `plan_hash` in `secrets/apply`
  and `reconfig/apply`, `pod_uid` in `pods/delete`. A TTL is a proxy for "the
  world may have changed"; a hash of the live state checks it directly, needs
  no storage, and catches a change that happened inside the window.
- Whether an operation is graceful or forced is decided **internally** from
  observed state (e.g. the pod's own `Ready` condition), never from a
  caller-facing flag.

### 5. Reason codes are a contract

`docs/*/sanity-check.md` publishes its codes under the heading *Stable Reason
Codes*. That promise is already made and nothing pins it in a test, so treat a
rename as a breaking change and say so in the commit body. New codes: `SCREAMING_SNAKE`,
specific enough to branch on, and added to the task's doc page in the same
commit.

## Checklist for a new task

- [ ] Every `input:` field survives the four-question layer decision above
- [ ] `pattern:` set on anything reaching a shell, a path, or a Kubernetes name
- [ ] Destructive → `dry_run` / `confirm` defaults are safe-by-omission
- [ ] Script writes JSON to `$AQSH_RESULT_FILE` via `lib/response.sh`
- [ ] New `*_DEFAULT` settings documented in `aqsh-tasks/config/<db>.env`, with
      the unset behaviour stated explicitly — a `*_DEFAULT` that is merely
      absent degrades to the hardcoded fallback, so anything that must not
      silently no-op needs a named failure code instead (the migration
      branch's `VAULT_NOT_CONFIGURED` is the model)
- [ ] RBAC in `tests/chart/templates/<db>-rbac.yaml` updated in the same commit
- [ ] `docs/<db>/<task>.md` page + README task-table row
- [ ] `tests/unit/<db>/` coverage (mocked kubectl — the only fast signal) and a
      `.bats` case in the suite
- [ ] New `tests/mongodb/*.bats` file added to a shard list in
      `.github/workflows/ci.yaml` — nothing auto-discovers it

## Anti-patterns

- Exposing a credential, key path, or auth endpoint as a task input "for
  flexibility" — that is a confused-deputy hole, not flexibility.
- A literal `default:` on an input that also has an internal-config tier.
- Auto-detect that guesses a Bitnami-vs-official profile instead of reading
  live state, or that guesses when the signal is ambiguous.
- Changing a naming convention in `config/*.env` without the matching RBAC
  chart change.
- Adding a shared helper to `lib/secrets.sh`, `lib/pods.sh`, or `lib/k8s.sh`
  while only testing one gateway — MongoDB and MariaDB both consume those.
