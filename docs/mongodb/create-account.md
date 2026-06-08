# MongoDB Account Lifecycle Tasks

This document describes temporary account lifecycle management for single-cluster MongoDB (`kind-cluster-dbs`, namespace `mongo-1`).

## Core Rules

1. If password fingerprint changes, the account is treated as permanent (`CHANGED`) and must not be auto-deleted.
2. If account is expired and password fingerprint is unchanged, the account must be dropped.
3. `force-permanent` sets policy status to `PERMANENT`; expiry reconciler must always skip it.

## Policy Collection

Collection: `admin.temp_user_policies`

Required fields:

- `policy_id`
- `username`
- `auth_db`
- `roles`
- `status`
- `created_at` (UTC)
- `expires_at` (UTC)
- `initial_cred_fingerprint`
- `last_cred_fingerprint`
- `password_delivery_mode`
- `request_id`

Status enum:

- `ACTIVE`
- `CHANGED`
- `PERMANENT`
- `EXPIRED_PENDING`
- `EXPIRED_DELETED`
- `ERROR`
- `CANCELLED`
- `BANNED`

## Shared Mutation Precheck Pipeline

All mutation tasks run the same order:

1. Input validation
2. Read root secret from Kubernetes (`mongodb-credentials` by default)
3. Resolve primary from headless service seed
4. Connectivity check (`mongo_check`)
5. Account existence check
6. State guard check
7. Execute mutation
8. Post-verify and persist policy update

No mutation endpoint should bypass this pipeline.

## Tasks

### `create-account`

Create (or recreate when `allow_existing=true`) a temporary account.

Request fields:

- `namespace` (default `mongo-1`)
- `sts_name` (default `mongodb`)
- `credential_secret`, `credential_user_key`, `credential_pass_key`
- `auth_db` (default `admin`)
- `username`
- `roles_json` (`[{"role":"readWrite","db":"mydb"}]`)
- `database` (fallback role db when `roles_json` empty)
- `temp_days`
- `dry_run`
- `confirm`
- `allow_existing`
- password policy fields (`password_length`, `password_special_chars`, `password_special_max`)
- `password_delivery_mode` (`one_time_plaintext` or `encrypted_payload`)
- `recipient_pgp_pubkey` (required when `password_delivery_mode=encrypted_payload`; accepts ASCII-armored key text or base64-encoded armored key)

Encrypted delivery behavior:

1. Task receives `recipient_pgp_pubkey`.
2. Script imports the key into a temporary GnuPG home.
3. Generated password is encrypted using OpenPGP (`gpg --armor --encrypt`).
4. Task result returns ciphertext only (no plaintext password in payload).
5. Recipient decrypts locally using their private key.

Example request (encrypted mode):

```json
{
	"namespace": "mongo-1",
	"auth_db": "admin",
	"username": "qa_temp_user",
	"roles_json": "[{\"role\":\"readWrite\",\"db\":\"admin\"}]",
	"dry_run": "false",
	"confirm": "true",
	"password_delivery_mode": "encrypted_payload",
	"recipient_pgp_pubkey": "-----BEGIN PGP PUBLIC KEY BLOCK-----\n...\n-----END PGP PUBLIC KEY BLOCK-----"
}
```

Example `delivery_payload` (encrypted):

```json
{
	"mode": "encrypted_payload",
	"recipient_key_fingerprint": "ABCD1234...",
	"content_type": "application/pgp-encrypted",
	"ciphertext": "-----BEGIN PGP MESSAGE-----\n...\n-----END PGP MESSAGE-----"
}
```

Recipient-side decryption example:

```bash
echo "$CIPHERTEXT" | gpg --decrypt
```

Notes:

1. The server does not need recipient private keys.
2. Decryption must happen on the recipient side.
3. `one_time_plaintext` is still available for internal/trusted flows.

### `delete-account`

Drop user and mark policy terminal.

### `ban-account`

Ban by removing all roles (`roles: []`) and mark policy `BANNED`.

### `extend-expiry`

Extend `expires_at` (default ACTIVE only). Can reject terminal/changed/permanent states unless override is enabled.

### `update-account-roles`

Replace role bindings using explicit role-to-db array.

### `force-permanent`

Set policy to `PERMANENT`, clear expiry enforcement path, and persist force metadata.

### `reset-password`

Rotate password for the same account and return a fresh delivery payload. By default blocks `CHANGED` and `PERMANENT` unless `reset_override=true`.

Delivery mode behavior:

1. Supports both `one_time_plaintext` and `encrypted_payload`.
2. When `password_delivery_mode=encrypted_payload`, `recipient_pgp_pubkey` is required.
3. Invalid `password_delivery_mode` fails input validation before password mutation.
4. `initial_cred_fingerprint` is preserved when already present; `last_cred_fingerprint` is updated to the rotated credential fingerprint.

### `reconcile-expiry`

Cron-friendly reconciliation:

1. Read ACTIVE policies where `expires_at <= now`.
2. If account missing: mark `EXPIRED_DELETED`.
3. If fingerprint changed: mark `CHANGED`.
4. If unchanged: drop user and mark `EXPIRED_DELETED`.

## CronJob Patch and Operations

Use a Kubernetes CronJob in `mongo-1` to invoke reconcile task periodically.

Example patch workflow:

1. Ensure service account can call aqsh-mongodb endpoint.
2. Configure schedule (recommended every 30-60 min).
3. Keep `concurrencyPolicy: Forbid`.
4. Keep CronJob always deployed; no-op is expected when nothing to process.

Manual trigger example:

```bash
kubectl --context kind-cluster-dbs -n mongo-1 create job --from=cronjob/mongo-account-reconciler mongo-account-reconciler-manual-$(date +%s)
```

Inspect logs:

```bash
kubectl --context kind-cluster-dbs -n mongo-1 logs job/<job-name>
```

Verification checks:

1. Changed-password account remains present and policy is `CHANGED`.
2. Expired unchanged account is removed and policy is `EXPIRED_DELETED`.
3. No ACTIVE records leads to no-op success.

## Security Notes

1. Plaintext password must never be written to logs, errors, or policy documents.
2. `one_time_plaintext` response is intended only for immediate downstream delivery.
3. Prefer encrypted payload mode when key management is available.
