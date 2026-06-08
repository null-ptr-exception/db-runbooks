# Infra Test Suite

Validates the shared 2-cluster infrastructure layer that all new test suites build on.

## What it tests

- Local Docker registry reachability
- Cross-cluster HTTP routing via Istio Gateway and CoreDNS (cluster-a ↔ cluster-b)

## Topology

- **cluster-a** and **cluster-b**: Kind clusters with Cilium CNI, Istio 1.24, and Istio ingress gateway
- **CoreDNS**: `*.kind-a.test` resolves to cluster-a, `*.kind-b.test` resolves to cluster-b
- **Registry**: Local registry on `localhost:5005`

## Run

```bash
bats tests/infra/
```

Teardown is opt-in: `TEARDOWN=true bats tests/infra/`
