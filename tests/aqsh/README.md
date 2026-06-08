# Aqsh Test Suite

Validates the aqsh framework layer: federated authentication, task submission, and cross-cluster request flow.

## What it tests

- kube-federated-auth health via Istio Gateway
- Unauthenticated requests rejected (401)
- Cross-cluster authenticated requests accepted (cluster-b token → cluster-a aqsh)
- Hello task submission and completion
- In-pod request from cluster-b reaches aqsh on cluster-a

## Topology

Built on top of the shared infra layer (`tests/infra/`).

- **cluster-a**: kube-federated-auth, kube-auth-proxy + aqsh, Redis (namespace `aqsh-test`)
- **cluster-b**: test-client pod with projected SA token (namespace `aqsh-test`)
- **Istio Gateway routes**: `fedauth.kind-a.test` → federated auth, `aqsh.kind-a.test` → aqsh

All cross-component traffic goes through Istio Gateway, simulating a multi-cluster production setup.

## Run

```bash
bats tests/aqsh/
```

Teardown is opt-in: `TEARDOWN=true bats tests/aqsh/`
