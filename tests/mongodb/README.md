# MongoDB Test Suite

Validates MongoDB aqsh tasks: sanity-check and restart.

## What it tests

- Sanity-check task completes without critical issues
- Restart task advances StatefulSet generation and pods come back Ready

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
