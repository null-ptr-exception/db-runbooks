# MongoDB Account Lifecycle Management

## Overview

This document explains account lifecycle management for **permanent run accounts** (not temporary accounts). These are machine-to-machine credentials used by automation and inter-service communication.

**Key Constraint:** MongoDB Community Edition lacks native `EXPIRES` mechanism (unlike MariaDB). Account expiry must be tracked via application state and external reconciliation job.

---

## Account Lifecycle State Machine

```
CREATE API
   ↓
[ACTIVE] ← Account provisioned, waiting for user password change
   │
   ├─→ User changes password → [CHANGED] ← Permanent account (final state)
   │
   └─→ Expiry window exceeded (e.g., 7 days)
        External job detects ACTIVE + expired
        ↓
       [EXPIRED_DELETED] ← Auto-cleanup (user account not found or unchanged)

[ACTIVE] ← Admin calls DELETE API
   ↓
[CANCELLED] ← Manual revocation (account deleted from database)

[ACTIVE] ← Admin calls BAN API
   ↓
[BANNED] ← Revocation (roles removed, account still exists)
```

### State Descriptions

| State | Trigger | Action | Permanent? |
|-------|---------|--------|-----------|
| **ACTIVE** | CREATE API | Account created, expires in N days | No |
| **CHANGED** | Password fingerprint differs from initial | User activated account | Yes |
| **EXPIRED_DELETED** | Reconciliation job on expired ACTIVE | Account deleted from DB | Yes |
| **BANNED** | BAN API removes all roles | Access revoked, account remains | Yes |
| **CANCELLED** | DELETE API drops account | Account deleted from DB | Yes |
| **ERROR** | System error | Operation failed | Yes |

---

## Password Delivery Flow (Zero-Trust Design)

```
Step 1: Platform Admin initiates request
├─ POST /api/accounts/create
├─ Body: { account_name, public_key }

Step 2: AQSH script creates account in isolated environment
├─ Generate random password
├─ Set status: ACTIVE (expires in N days)
├─ Encrypt password with provided public key
├─ Return encrypted payload

Step 3: API returns encrypted password
├─ Response: { account, status, expires_at, encrypted_password }
├─ ⚠️  Plaintext password never stored or logged

Step 4: Platform Team decrypts locally & distributes
├─ Use private key (held only locally, never uploaded)
├─ Extract plaintext password
├─ Send credentials via email
├─ ✅ End-to-end encrypted, zero credential persistence
```

### Why PGP + Not K8s Secret?

| Approach | Flow | Trade-off |
|----------|------|-----------|
| **K8s Secret** | API → Secret → Manual access | Requires human login; plaintext in cluster |
| **PGP Encrypted** | API → Ciphertext → Local decryption → Email | Private key never uploaded; audit trail |

**Selected:** PGP for Zero-Trust principle—system cannot read plaintext credentials.

---

## State Reconciliation Job

**Trigger:** Daily (e.g., `0 0 * * *`)

**Logic:**
```
1. Query: SELECT * FROM accounts WHERE status='ACTIVE' AND expires_at < NOW()
2. For each expired account:
   a. Check credentials fingerprint against initial_cred_fingerprint
   b. If fingerprint changed → UPDATE status → CHANGED (user activated account)
   c. If fingerprint unchanged → DELETE account → UPDATE status → EXPIRED_DELETED
   - Log audit entry
3. Auto-cleanup; no manual intervention required
```

### Why Check Credentials Fingerprint?

**Scenario:** Account provisioned on Day 0; user changes password on Day 2

- Day 0: `status=ACTIVE`, `initial_cred_fingerprint=ABC123` (original password hash)
- Day 2: User logs in & changes password → `last_cred_fingerprint=XYZ789` (new hash)
- Day 5: Reconciliation job runs
  - Checks: `last_cred_fingerprint != initial_cred_fingerprint` (ABC123 ≠ XYZ789)
  - Conclusion: User already activated account → UPDATE status → `CHANGED`
  - Action: **Do NOT delete** (account is in-use)

**Purpose:** Prevent accidental deletion of accounts that were already activated.

---

## API Reference

### CREATE Account

```bash
curl -X POST http://aqsh-mongodb:4180/api/task \
  -H "Content-Type: application/json" \
  -d '{
    "task": "account/create-account",
    "params": {
      "namespace": "mongo-1",
      "auth_db": "admin",
      "username": "app_user",
      "roles_json": "[{\"role\":\"readWrite\",\"db\":\"mydb\"}]",
      "temp_days": "14",
      "password_delivery_mode": "encrypted_payload",
      "recipient_pgp_pubkey": "-----BEGIN PGP PUBLIC KEY BLOCK-----\n...\n-----END PGP PUBLIC KEY BLOCK-----",
      "dry_run": "false",
      "confirm": "true"
    }
  }'
```

**Response (Success):**
```json
{
  "status": "CREATED",
  "reason_code": "ACCOUNT_CREATED",
  "username": "app_user",
  "auth_db": "admin",
  "expires_at": "2026-06-23T10:00:00Z",
  "delivery_payload": {
    "mode": "encrypted_payload",
    "recipient_key_fingerprint": "ABCD1234...",
    "content_type": "application/pgp-encrypted",
    "ciphertext": "-----BEGIN PGP MESSAGE-----\n...\n-----END PGP MESSAGE-----"
  },
  "roles": [{"role": "readWrite", "db": "mydb"}]
}
```

**Decrypt locally:**
```bash
echo "$CIPHERTEXT" | gpg --decrypt
```

---

### BAN Account (Revoke Access)

```bash
curl -X POST http://aqsh-mongodb:4180/api/task \
  -H "Content-Type: application/json" \
  -d '{
    "task": "account/ban-account",
    "params": {
      "namespace": "mongo-1",
      "auth_db": "admin",
      "username": "app_user",
      "ban_reason": "SECURITY_POLICY"
    }
  }'
```

**Response:**
```json
{
  "status": "BANNED",
  "reason_code": "ACCOUNT_BANNED",
  "username": "app_user",
  "ban_reason": "SECURITY_POLICY"
}
```

**Effect:** Removes all roles from account (still exists, cannot access any database)

---

### DELETE Account (Drop Completely)

```bash
curl -X POST http://aqsh-mongodb:4180/api/task \
  -H "Content-Type: application/json" \
  -d '{
    "task": "account/delete-account",
    "params": {
      "namespace": "mongo-1",
      "auth_db": "admin",
      "username": "app_user",
      "delete_reason": "MANUAL_DELETE"
    }
  }'
```

**Response:**
```json
{
  "status": "DELETED",
  "reason_code": "ACCOUNT_DELETED",
  "username": "app_user",
  "delete_reason": "MANUAL_DELETE"
}
```

**Effect:** Drops account completely (cannot be recovered)

---

### EXTEND Expiry (Forgot Password)

```bash
curl -X POST http://aqsh-mongodb:4180/api/task \
  -H "Content-Type: application/json" \
  -d '{
    "task": "account/extend-expiry",
    "params": {
      "namespace": "mongo-1",
      "auth_db": "admin",
      "username": "app_user",
      "days": "7"
    }
  }'
```

**Response:**
```json
{
  "status": "EXTENDED",
  "reason_code": "EXPIRY_EXTENDED",
  "username": "app_user",
  "new_expires_at": "2026-06-30T10:00:00Z"
}
```

---

### RESET Password

```bash
curl -X POST http://aqsh-mongodb:4180/api/task \
  -H "Content-Type: application/json" \
  -d '{
    "task": "account/reset-password",
    "params": {
      "namespace": "mongo-1",
      "auth_db": "admin",
      "username": "app_user",
      "password_delivery_mode": "encrypted_payload",
      "recipient_pgp_pubkey": "-----BEGIN PGP PUBLIC KEY BLOCK-----\n...\n-----END PGP PUBLIC KEY BLOCK-----",
      "dry_run": "false",
      "confirm": "true"
    }
  }'
```

**Response:**
```json
{
  "status": "RESET",
  "reason_code": "PASSWORD_RESET",
  "username": "app_user",
  "delivery_payload": {
    "mode": "encrypted_payload",
    "ciphertext": "-----BEGIN PGP MESSAGE-----\n...\n-----END PGP MESSAGE-----"
  }
}
```

---

### READ Account Status

```bash
curl -X GET http://aqsh-mongodb:4180/api/accounts/admin/app_user
```

**Response:**
```json
{
  "username": "app_user",
  "auth_db": "admin",
  "status": "ACTIVE",
  "expires_at": "2026-06-23T10:00:00Z",
  "created_at": "2026-06-09T10:00:00Z",
  "updated_at": "2026-06-09T10:00:00Z",
  "initial_cred_fingerprint": "ABC123...",
  "last_cred_fingerprint": "ABC123..."
}
```

---

## Reconciliation Job Operation

### Manual Trigger via CronJob

```bash
# Manual trigger:
kubectl --context kind-cluster-dbs -n mongo-1 create job \
  --from=cronjob/mongo-account-reconciler \
  mongo-account-reconciler-manual-$(date +%s)

# Check logs:
kubectl --context kind-cluster-dbs -n mongo-1 logs job/<job-name>
```

### Reconciliation Response

```json
{
  "status": "OK",
  "reason_code": "RECONCILED",
  "summary": "expiry reconciliation completed",
  "processed": 5,
  "changed": 1,
  "deleted": 3,
  "skipped": 1
}
```

---

## Policy Collection Schema

**Location:** `admin.temp_user_policies`

**Example Document:**
```json
{
  "policy_id": "uuid-or-timestamp",
  "username": "app_user",
  "auth_db": "admin",
  "roles": [{"role": "readWrite", "db": "mydb"}],
  "status": "ACTIVE",
  "created_at": "2026-06-09T10:00:00Z",
  "updated_at": "2026-06-09T10:00:00Z",
  "expires_at": "2026-06-23T10:00:00Z",
  "initial_cred_fingerprint": "sha256...",
  "last_cred_fingerprint": "sha256...",
  "password_delivery_mode": "encrypted_payload",
  "request_id": "req-123",
  "requested_by": "admin@example.com",
  "target_namespace": "mongo-1"
}
```

**Required Fields:**
- `policy_id`, `username`, `auth_db`, `roles`, `status`
- `created_at`, `expires_at`, `initial_cred_fingerprint`, `last_cred_fingerprint`
- `password_delivery_mode`, `request_id`

---

## Handling User Forgot to Change Password

**Scenario:** Account expired before user could change password

**Solution A: Extend Expiry**
```
POST /api/accounts/{account}/extend
Body: { days: 7 }
Result: ACTIVE state persists, expires_at pushed forward
```

**Solution B: Delete & Re-provision**
```
DELETE /api/accounts/{account}
CREATE new account via standard flow
```

---

## Why Full CRUD is Required

| Operation | Purpose |
|-----------|---------|
| **CREATE**  | Provision account, encrypt & return password |
| **READ/LIST** | Audit account status, check if activated, retrieve expiry date |
| **UPDATE** | Extend expiry time (user forgot to change password) |
| **DELETE** | Revoke access, clean up for re-provisioning |

Without all four: **accounts cannot be properly maintained.**

---

## Authorization & Audit

- **Access:** Platform Team only
- **Logging:** Every state transition (CREATE, EXTEND, DELETE, BAN) must record timestamp + actor
- **Compliance:** Full audit trail for account lifecycle

---

## MongoDB vs MariaDB

| Database | Native Expiry | Application Impact |
|----------|---------------|-------------------|
| **MariaDB** | `CREATE USER ... EXPIRES INTERVAL 7 DAY` | DB handles cleanup automatically |
| **MongoDB Community** |  Not supported | Implement via app-layer state + external reconciliation job |

---

## Security Notes

1. **Plaintext password** never stored, logged, or persisted
2. **PGP encrypted mode** prevents system-wide credential exposure
3. **Private key** remains on admin's machine only
4. **Fingerprint tracking** prevents accidental deletion of activated accounts
5. **State guards** prevent invalid transitions (e.g., can't extend EXPIRED_DELETED)

---

## Summary

This design addresses three requirements:

1. **Operational**: Auto-expiry for accounts not activated within the window
2. **Security**: Zero-plaintext-credential persistence; encrypted delivery
3. **Maintainability**: Full CRUD coverage for lifecycle management + separate BAN/DELETE operations
