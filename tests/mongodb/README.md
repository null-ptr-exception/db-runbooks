# MongoDB Test Suite

Validates the MongoDB aqsh task API end-to-end: sanity-check, restart,
backup, account lifecycle, recovery, reconfig, and FCV.

## What it tests

- Sanity-check task completes without critical issues (`mongodb.bats`)
- Restart task advances StatefulSet generation and pods come back Ready
  (RollingUpdate strategy, `mongodb.bats`)
- Restart task correctly detects `updateStrategy: OnDelete` and waits for an
  operator-driven pod cycle rather than a false-positive no-op pass
  (`restart_ondelete.bats`, separate `mongo-ondelete` namespace)
- Restart task auto-detects a `rollingUpdate.partition` stuck at the replica
  count (the resting state MongoDB recovery/wipe leaves behind) and unlocks
  it before restarting, instead of silently reporting success with no pod
  actually restarted (`restart_stuck_partition.bats`, separate
  `mongo-stuck-partition` namespace)
- Backup task ships a dump to MinIO on cluster-b (`backup.bats`)
- Run-account lifecycle: create/delete/ban/extend-expiry/reset-password/
  update-roles with the dry_run → confirm gate (`account_lifecycle.bats`)
- Replica-set member recovery: gate checks, wipe + resync, reset,
  fix-no-primary, one-call recover (`recovery.bats`), plus the auto-detect
  and self-heal variants — official/Bitnami secretKeyRef and file-mounted
  credential conventions, custom naming, fresh-StatefulSet auto-patch
  (`recovery_autodetect*.bats`, `recovery_auto_patch*.bats`,
  `recovery_bitnami_profile.bats`, `recovery_custom_naming.bats`,
  `recovery_probe_skip.bats`)
- Reconfig gateway: plan/apply CAS flow, freeze window, break-glass
  force-dr (`reconfig.bats`)
- FCV gateway: status report, validated upgrade/downgrade round trip,
  INVALID_TARGET/gate rejections (`fcv.bats`), and credential auto-detect
  against a Bitnami-convention StatefulSet (`fcv_bitnami.bats`)

## Topology

Built on top of the shared 2-cluster infra (`infra/deploy.sh`).

- **cluster-a**:
  - `mongo-core` namespace: kube-federated-auth, aqsh-mongodb (with kube-auth-proxy sidecar), Redis
  - `mongo-1` namespace: MongoDB StatefulSet
- **cluster-b**:
  - `mongo-core` namespace: test-client pod
- **Istio Gateway**: `aqsh-mongodb.kind-a.test` → aqsh-mongodb, `fedauth.kind-a.test` → federated auth

## Run

```bash
bats tests/mongodb/
```

Teardown is opt-in: `TEARDOWN=true bats tests/mongodb/`
