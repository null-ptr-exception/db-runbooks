# K8s Secrets Gateway (secrets/*) — aqsh-mariadb

Safe CRUD for Kubernetes Secrets in the MariaDB namespace, for
caller-chosen credentials (monitoring accounts, read-only app accounts, API
keys). The five tasks — `secrets/pubkey`, `secrets/get`, `secrets/plan`,
`secrets/apply`, `secrets/delete` — are **the same scripts the MongoDB
gateway serves**; the full design, API reference, failure codes and usage
scenarios live in [docs/mongodb/secrets.md](../mongodb/secrets.md). This
page covers what differs on the MariaDB deployment.

## Table of Contents

- [Architecture Recap](#architecture-recap)
- [What Differs on MariaDB](#what-differs-on-mariadb)
- [Usage Scenario: monitoring account for mariadb-1](#usage-scenario-monitoring-account-for-mariadb-1)
- [Deployment Settings (Internal Config)](#deployment-settings-internal-config)
- [RBAC Requirements](#rbac-requirements)

## Architecture Recap

```text
caller ── secrets/pubkey ──▶ aqsh-mariadb (db-ops)     private key mounted at
caller: jq '{keys:{...}}' | gpg -e -r <fpr> | base64   /etc/aqsh/pgp/private.asc
caller ── secrets/plan ────▶ decrypt in-pod, diff vs live Secret → plan_hash
caller ── secrets/apply ───▶ CAS check → create -f - / patch --patch-file
                             (values stdin-only)      ──▶ Secret in mariadb-1
```

Values are PGP-encrypted end-to-end (caller → aqsh pod memory); gateway
logs, task inputs and results carry only ciphertext, key names, actions and
sha256 fingerprints. Upsert is merge-only behind a stateless `plan_hash`
CAS; delete is confirm-gated.

## What Differs on MariaDB

| Aspect | MongoDB gateway | MariaDB gateway |
|---|---|---|
| Gateway host (sandbox) | `aqsh-mongodb.kind-a.test:30080` | `aqsh-mariadb.kind-a.test:30080` |
| Internal config file | `mongodb.env` | `mariadb.env` |
| Protected-secret auto-detect | Live, from StatefulSet env (official + Bitnami conventions) | **None** — operator CR conventions (`rootPasswordSecretKeyRef`) have no single live signal this detection trusts, so protection is config-list only |
| Protected list in this sandbox | `minio` (+ auto-detected `mongodb-credentials`) | `mariadb` (operator root password), `minio` (S3 credentials) |
| RBAC template | `mongodb-rbac.yaml` (rule added for this family) | `mariadb-rbac.yaml` — **already had** namespace-wide `get/create/patch/delete` on secrets (account-password rule); no change needed |

Because there is no live auto-detect tier here, **an unlisted root secret is
unprotected**: every MariaDB deployment must put its operator root-password
Secret (and any operator/infra secrets — replication, S3, TLS) into
`SECRETS_PROTECTED_NAMES_DEFAULT`. Auto-detect from the MariaDB CR is
Future Work (tracked in the MongoDB page).

## Usage Scenario: monitoring account for mariadb-1

```bash
# fetch + import the deployment key (once)
# task: secrets/pubkey → {public_key, fingerprint}
echo "$RESULT" | jq -r '.public_key' | gpg --import
FPR=$(echo "$RESULT" | jq -r '.fingerprint')

PAYLOAD=$(jq -nc '{keys: {"monitor-user": "monitor", "monitor-pass": "user-chosen-pass"}}' \
  | gpg --encrypt --armor --trust-model always -r "$FPR" | base64 -w0)

# secrets/plan {namespace:"mariadb-1", secret_name:"monitor-credentials", payload:$PAYLOAD}
#   → changes all-create + plan_hash
# secrets/apply {…, plan_hash} → action:"created"
```

Create the DB account itself with `create-account`
([create-account.md](create-account.md)); this family only materializes the
Secret the app mounts. Verify later with `secrets/get` (per-key
`value_sha256`), rotate a single key by sending a one-key payload
(merge-only), decommission via `secrets/delete` → preview → `confirm:
"true"`.

## Deployment Settings (Internal Config)

`/etc/aqsh/config/mariadb.env` (commented reference in
`aqsh-tasks/config/mariadb.env`):

| Key | Sandbox value | Meaning |
|---|---|---|
| `SECRETS_PGP_KEY_PATH_DEFAULT` | `/etc/aqsh/pgp/private.asc` | deployment private key mount path |
| `SECRETS_PROTECTED_NAMES_DEFAULT` | `mariadb,minio` | Secrets this family refuses to touch — **must** include the operator root-password Secret |
| `LOG_LEVEL_DEFAULT` | `INFO` | baseline verbosity (`log_level` input per call) |

Keypair provisioning is identical to the MongoDB gateway (chart value
`aqsh.pgpKey` → Secret `aqsh-pgp`; both `db-ops` aqsh releases on the two
clusters receive the same suite-generated key in e2e).

## RBAC Requirements

`tests/chart/templates/mariadb-rbac.yaml` (role `aqsh-mariadb-manager`)
already grants `secrets: get/create/patch/delete` namespace-wide in
`mariadb.namespace` for the account-password flow — this family introduced
**no new RBAC** on the MariaDB side. The compensating control for the wide
grant is the in-script protected-name refusal, which is why keeping
`SECRETS_PROTECTED_NAMES_DEFAULT` accurate matters more here than on the
MongoDB gateway.
