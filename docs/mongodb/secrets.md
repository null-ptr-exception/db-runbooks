# K8s Secrets Gateway (secrets/*) — aqsh-mongodb

Safe CRUD for Kubernetes Secrets in the DB namespace, for credentials whose
values are **chosen by the caller** (monitoring accounts, read-only app
accounts, third-party API keys) rather than generated server-side. The core
guarantee: **a secret value never crosses the gateway, task inputs, task
results, or logs in plaintext** — it travels PGP-encrypted against a
deployment-held key and is decrypted only inside the aqsh pod, on its way
into the Kubernetes API.

The same five tasks are served verbatim by the MariaDB gateway — see
[docs/mariadb/secrets.md](../mariadb/secrets.md) for the deployment
differences.

## Table of Contents

- [When To Use What](#when-to-use-what)
- [Architecture](#architecture)
- [How It Works](#how-it-works)
- [API Reference](#api-reference)
- [Usage Scenarios](#usage-scenarios)
- [Deployment Settings (Internal Config)](#deployment-settings-internal-config)
- [RBAC Requirements](#rbac-requirements)
- [Security Notes](#security-notes)
- [Future Work](#future-work)

## When To Use What

| You want to… | Use |
|---|---|
| Give a **human** a DB account password | `account/create-account` with `password_delivery_mode` ([account-lifecycle.md](account-lifecycle.md)) — delivery is outbound-encrypted to *the recipient's* key |
| Give an **application** a Secret its pods mount, with values you chose | `secrets/plan` → `secrets/apply` |
| Check whether a deployed Secret still holds the values you pushed | `secrets/get` (sha256 fingerprints, no values) |
| Remove a Secret this family manages | `secrets/delete` (confirm-gated) |
| Store values an operator/controller owns (root credentials, S3 creds) | **Don't** — these are protected (`PROTECTED_SECRET`) and belong to their owning workflow |
| Sync from Vault/cloud secret managers | External Secrets Operator, not this gateway |

## Architecture

```text
caller workstation                        cluster-a
──────────────────                        ─────────
1. secrets/pubkey  ───────────────────▶   aqsh (mongo-core)
   ◀── deployment public key + fpr        │  private key: Secret aqsh-pgp
                                          │  mounted /etc/aqsh/pgp/private.asc
2. jq '{keys:{...}}' | gpg --encrypt      │
   --recipient <fpr> | base64             │
                                          │
3. secrets/plan {namespace, secret_name,  │ decrypt in-pod → diff vs live
   payload} ──────────────────────────▶   │ Secret → per-key create/update/
   ◀── changes + plan_hash                │ unchanged + plan_hash (CAS token)
                                          │
4. secrets/apply {…, plan_hash} ──────▶   │ recompute hash from live state;
                                          │ mismatch → PLAN_STALE, else
                                          ▼
                                     Secret in mongo-1
                                     (create -f - / patch --patch-file,
                                      values stdin-only, never argv)
```

Plaintext exists in exactly two places: the caller's machine and the aqsh
pod's process memory during a task run. The HTTP body, gateway/audit logs,
aqsh execution records and task results only ever contain ciphertext, key
*names*, actions and sha256 digests.

## How It Works

### Inbound PGP: the mirror image of account delivery

`account/*` tasks encrypt **outbound** (server-generated password → the
*recipient's* public key). This family reverses the direction: the
**deployment** holds the keypair. The private key is provisioned as the
`aqsh-pgp` Secret and mounted read-only; `secrets/pubkey` derives the public
half from it on demand (there is no separate public-key file to drift).
Payloads are accepted ASCII-armored or base64(armored) — the same
dual-format tolerance as `recipient_pgp_pubkey`.

The payload contract after decryption:

```json
{"keys": {"username": "monitor", "password": "user-chosen-pass"}}
```

One ciphertext blob for the whole payload (never one input per key), so
nothing about the values — not even their count per input field — leaks into
request logs. Key names must match `[-._a-zA-Z0-9]+`; values must be JSON
strings (binary content is out of scope — see Future Work).

### plan_hash: stateless CAS, borrowed from reconfig

`secrets/plan` returns `plan_hash = "sec" + sha256(namespace | secret_name |
payload_digest | live resourceVersion-or-"absent" | mode)[0:24]`.
`secrets/apply` recomputes that hash from **live** state and refuses on
mismatch (`PLAN_STALE`). Consequences, identical to `reconfig/apply`'s CAS
([reconfig.md](reconfig.md#how-it-works)):

- No stored plan, no token table, no TTL — the hash *is* the binding.
- Any external edit, delete, or concurrent create between plan and apply
  invalidates the plan (resourceVersion moved).
- Changing the payload between plan and apply also invalidates it
  (payload_digest moved) — you cannot plan an innocuous change and apply a
  different one.
- Switching `mode` between plan and apply also invalidates it — an
  `add_only` plan cannot be applied as a clobbering upsert.

### Merge-only writes

`apply` only touches the keys present in the payload; existing keys stay
(`retained_keys` in the result names them). Creating uses a full manifest on
stdin (`kubectl create -f -`); updating uses `kubectl patch --type merge
--patch-file /dev/stdin`. Neither path ever puts a value into process argv
(`kubectl patch -p` would land base64 values in `/proc/<pid>/cmdline`).
When every key is already `unchanged`, apply writes nothing and returns
`action: "unchanged"` — re-applying is free and idempotent. There is no
replace/prune mode by design; deleting keys means deleting the Secret
(`secrets/delete`) or using direct kubectl with your own RBAC.

**Three write modes**, all merge-only, all server-enforced in plan AND
apply, all bound into the plan_hash (a plan made under one mode cannot be
applied under another):

| `mode` | Existing key, different value | Existing key, same value | New key |
|---|---|---|---|
| `upsert` (default) | overwritten (`update`) | `unchanged` | written (`create`) |
| `add_only` | **whole call fails `KEY_CONFLICT`** (details name the keys, never values) | `unchanged` — idempotent re-push passes | written (`create`) |
| `skip_existing` | silently skipped (`skipped`), value untouched | `skipped` | written (`create`) |

`add_only` is for shared Secrets where clobbering must be an *error*
(several writers, nobody may overwrite anyone else's keys).
`skip_existing` is SQL's INSERT IGNORE: seed defaults without disturbing
whatever is already there — plan/apply report the skipped keys by name and
`summary.skipped`, and apply writes only the `create` keys.

### Protected secrets: auto-detected, no per-call override

`plan`, `apply` and `delete` refuse (`PROTECTED_SECRET`) to touch Secrets
that belong to other machinery, resolved without any caller input:

1. **Internal config** — `SECRETS_PROTECTED_NAMES_DEFAULT`, a comma/space
   list (the PBM S3 credentials Secret `minio` in this deployment).
2. **Live auto-detect** — the root-credential Secret wired into the
   namespace's StatefulSet env, found by the same detection the recovery
   tasks use (`_recovery_detect_credentials` in
   `aqsh-tasks/lib/mongodb-recovery.sh`): official-image
   `MONGO_INITDB_ROOT_USERNAME/PASSWORD` secretKeyRefs, Bitnami
   `MONGODB_ROOT_USER/PASSWORD`, and the Bitnami `*_FILE` file-mounted
   convention are all recognized. Detection fails **soft**: in a namespace
   with no such wiring (or an ambiguous one) it adds nothing and the config
   list alone applies. It never guesses.

There is deliberately no per-call escape hatch — same posture as the
`recovery/*` auto-detect tier (CLAUDE.md "Configuration Layers"). If a
protected write is truly intended, it belongs to the owning workflow (e.g.
PBM storage migration via `pbm/config`), not this API.

### Value hygiene and debug logging

Every task accepts `log_level` (`DEBUG` gives the full decision trail:
payload format detection, key import fingerprint, per-key diff outcomes,
plan-hash inputs, kubectl outcomes). The logging contract: **key names, key
counts, value lengths and sha256 digests may be logged; values and decrypted
payload text never are** — at any level. Results follow the same rule:
`secrets/get` reports `value_sha256` per key so callers can verify drift
without ever reading a value back.

## API Reference

All tasks: `allowed_groups: ["system:serviceaccounts"]`, inputs are strings.
Failure results are `{status: "ERROR", reason_code, summary, details}`.

### secrets/pubkey

| Input | Required | Meaning |
|---|---|---|
| `log_level` | no | `DEBUG`/`INFO`/`WARN`/`ERROR` for this call |

Returns `{public_key, fingerprint, content_type}`. Fails
`PGP_KEY_UNAVAILABLE` when the deployment key Secret is missing/unmounted.

### secrets/get

| Input | Required | Meaning |
|---|---|---|
| `namespace` | yes | target namespace |
| `secret_name` | yes | Secret to describe |
| `log_level` | no | per-call verbosity |

Returns `{secret_name, namespace, type, resource_version, created_at,
keys: [{key, value_sha256}]}`. Fails `PROTECTED_SECRET` (protected secrets
are refused even read-only — fingerprints of root credentials would enable
offline dictionary checks against a weak password), `NOT_FOUND`,
`OPERATION_FAILED`.

### secrets/plan

| Input | Required | Meaning |
|---|---|---|
| `namespace` | yes | target namespace |
| `secret_name` | yes | Secret to create or merge into |
| `payload` | yes | PGP ciphertext (armored or base64) of `{"keys": {...}}` |
| `mode` | no | `upsert` (default) / `add_only` (changing an existing value fails `KEY_CONFLICT`) / `skip_existing` (existing keys silently skipped, only new keys written) |
| `log_level` | no | per-call verbosity |

Read-only. Returns `{namespace, secret_name, mode, secret_exists, changes:
[{key, action: create|update|unchanged|skipped}], retained_keys, summary
(incl. `skipped`), payload_digest, plan_hash}`. Fails `PROTECTED_SECRET`,
`PGP_KEY_UNAVAILABLE`, `DECRYPT_FAILED`, `PAYLOAD_INVALID`,
`INVALID_INPUT`, `KEY_CONFLICT` (add_only; details carry
`conflicting_keys`), `OPERATION_FAILED`.

### secrets/apply

| Input | Required | Meaning |
|---|---|---|
| `namespace`, `secret_name`, `payload`, `mode` | as plan | same as plan (mode must MATCH the plan's — it is hash material) |
| `plan_hash` | yes | token from `secrets/plan` (`^sec[0-9a-f]{24}$`) |
| `requested_by`, `request_id` | no | audit passthrough, echoed in the result |
| `log_level` | no | per-call verbosity |

Returns plan's diff fields plus `{action: created|patched|unchanged, mode,
plan_hash, requested_by, request_id}`. Fails everything plan can, plus
`PLAN_STALE` (details carry `given_plan_hash` vs `live_plan_hash`) and
`APPLY_FAILED`.

### secrets/delete

| Input | Required | Meaning |
|---|---|---|
| `namespace` | yes | target namespace |
| `secret_name` | yes | Secret to delete |
| `confirm` | no | default `"false"` = read-only preview; `"true"` deletes |
| `log_level` | no | per-call verbosity |

Preview returns the `secrets/get` shape plus `{deleted: false,
confirm_required: true}`; confirmed delete returns it with `{deleted:
true}`. Fails `PROTECTED_SECRET`, `NOT_FOUND`, `OPERATION_FAILED`.

## Usage Scenarios

### 1. Provision a monitoring account's credentials (user-chosen password)

```bash
# One-time per deployment: fetch + import the deployment key
curl -s -X POST "$AQSH/tasks/secrets%2Fpubkey" -H "Authorization: Bearer $TOKEN" \
  -H 'Content-Type: application/json' -d '{}'          # → poll execution
echo "$RESULT" | jq -r '.public_key' | gpg --import
FPR=$(echo "$RESULT" | jq -r '.fingerprint')

# Encrypt the whole payload once, base64 to one line
PAYLOAD=$(jq -nc '{keys: {username: "monitor", password: "user-chosen-pass"}}' \
  | gpg --encrypt --armor --trust-model always -r "$FPR" | base64 -w0)

# plan → inspect → apply
curl ... -d "$(jq -nc --arg p "$PAYLOAD" \
  '{namespace:"mongo-1", secret_name:"monitor-credentials", payload:$p}')" \
  "$AQSH/tasks/secrets%2Fplan"
# → {"changes":[{"key":"username","action":"create"},{"key":"password","action":"create"}],
#    "plan_hash":"sec3f9c…", "secret_exists":false, ...}

curl ... -d "$(jq -nc --arg p "$PAYLOAD" --arg h "sec3f9c…" \
  '{namespace:"mongo-1", secret_name:"monitor-credentials", payload:$p,
    plan_hash:$h, requested_by:"alice", request_id:"TICKET-123"}')" \
  "$AQSH/tasks/secrets%2Fapply"
# → {"action":"created", ...}
```

The app then mounts `monitor-credentials` as usual. (Creating the DB user
itself stays with `account/create-account`; wiring the two together is
Future Work.)

### 2. Rotate one key, leave the rest

Encrypt a payload containing only `{"keys": {"password": "new-pass"}}` and
plan/apply against the same Secret: `password` shows `update`, every other
key appears in `retained_keys` and survives untouched.

### 2b. Shared Secret, several writers, nobody may clobber anybody

Add `"mode": "add_only"` to both plan and apply. Adding a brand-new key or
re-pushing an identical value succeeds; a payload that would *change* an
existing key's value fails `KEY_CONFLICT` with the offending key names in
`details.conflicting_keys` — in plan (early warning) and again in apply
(server-enforced even if the caller ignored the plan). Because `mode` is
part of the plan_hash, the add_only guarantee cannot be dropped between the
two steps.

### 2c. Seed defaults without touching anything that already exists

`"mode": "skip_existing"` (INSERT IGNORE): send the full desired key set;
keys that already exist — with any value — are reported as `skipped` and
left exactly as they are, only genuinely new keys get written. No error,
idempotent, safe to run on every deploy.

### 3. Drift check without reading values

`secrets/get` returns `value_sha256` per key — compare against
`sha256(expected-value)` locally. The reconciliation idea mirrors the
account family's credential fingerprints.

### 4. Decommission

`secrets/delete` without `confirm` shows exactly what would go (key names +
fingerprints); rerun with `confirm: "true"` to delete.

### 5. Someone edited the Secret while you were deciding

`apply` fails `PLAN_STALE` and changes nothing (the external edit survives).
Re-run `plan`, review the new diff — it now reflects the live state — and
apply with the fresh hash.

## Deployment Settings (Internal Config)

`/etc/aqsh/config/mongodb.env` (see `aqsh-tasks/config/mongodb.env` for the
commented reference):

| Key | Default | Meaning |
|---|---|---|
| `SECRETS_PGP_KEY_PATH_DEFAULT` | `/etc/aqsh/pgp/private.asc` | where the deployment private key is mounted |
| `SECRETS_PROTECTED_NAMES_DEFAULT` | *(empty)* | extra protected Secret names, on top of the auto-detected root-credential Secret. These repeat names the chart values own (`mongodb.backupSecret`) — rename them together |
| `SECRETS_AUTODETECT_DEFAULT` | `true` | `false` skips the live root-credential detection (2 kubectl calls per write task) — for deployments where it cannot succeed anyway |
| `LOG_LEVEL_DEFAULT` | `INFO` | baseline verbosity (`log_level` input overrides per call) |

**Keypair provisioning:** two chart paths
(`tests/chart/templates/aqsh.yaml`), both mounting `/etc/aqsh/pgp`:

- `aqsh.pgpKey` — armored private key as a helm value, rendered into Secret
  `aqsh-pgp`. Used by the e2e suites (throwaway per-run key injected via the
  runtime-values second `helmfile apply`). Convenient, but the key material
  transits helm values and release storage.
- `aqsh.pgpSecretName` — name of a **pre-created** Secret (key
  `private.asc`), provisioned out-of-band. The production path: key
  material never touches helm.

Rotating either way: new key Secret → restart aqsh → callers re-fetch via
`secrets/pubkey` (old ciphertexts stop decrypting, by design).

## RBAC Requirements

`tests/chart/templates/mongodb-rbac.yaml` (role `aqsh-mongo-manager`):

- `secrets`: `get`, `create`, `patch`, `delete` — **namespace-wide**, unlike
  the older pinned `get` rule, because this family's purpose is caller-named
  Secrets and `create` ignores `resourceNames` anyway (no object exists yet
  to match). The compensating control is in-script: the protected-name
  refusal above, which RBAC cannot express.
- `statefulsets`: `list`/`get` (already present) — used read-only by the
  protected-secret auto-detect.

Namespaces beyond `mongodb.namespace` need their own RoleBinding to the
ClusterRole (the pbm/secrets test fixtures show the shape).

## Security Notes

- **In transit**: PGP end-to-end from caller to aqsh pod; TLS/gateway logs
  see ciphertext only. Confidentiality does not depend on the transport.
- **At rest**: this family gets values *into* K8s Secrets safely; at-rest
  protection of Secrets themselves is the cluster's job (etcd encryption,
  RBAC on `get secrets`). The gateway's namespace-wide RBAC is scoped to the
  one DB namespace it manages.
- **No values in results, ever** — drift checks use sha256 fingerprints.
  `payload_digest` in results is a digest of the canonical payload JSON, so
  low-entropy payloads could in principle be brute-forced offline by someone
  holding both the result *and* a candidate list; treat task results as
  internal, as with the account family's fingerprints. For protected
  (root-credential) secrets even the read-only fingerprints are refused —
  `secrets/get` fails `PROTECTED_SECRET` like the write tasks.
- **Relationship to account delivery** ([account-lifecycle.md](account-lifecycle.md)):
  that flow's "Why PGP + Not K8s Secret?" argues against K8s Secrets for
  **human** delivery — unchanged. This family is **app** delivery; PGP
  protects transit, the Secret is the deliverable.
- Weak user-chosen passwords are accepted (this API stores what the caller
  chose, it does not police account policy) — enforce password policy where
  the account is created.

## Future Work

- `account/create-account` accepting a caller-chosen password via this
  payload mechanism (touches the shared account lib — separate discussion).
- Binary values (payload `keys_b64` variant).
- Replace/prune mode behind its own confirm gate.
- MariaDB root-credential auto-detect (operator CR conventions) — today the
  MariaDB deployment protects by config list only.
