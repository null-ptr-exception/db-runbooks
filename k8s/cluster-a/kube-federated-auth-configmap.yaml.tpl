apiVersion: v1
kind: ConfigMap
metadata:
  name: kube-federated-auth-config
  namespace: db-ops
data:
  clusters.yaml: |
    authorized_clients:
      - "cluster-a/db-ops/kube-auth-proxy"
    cache:
      ttl: 60
      max_entries: 1000
    clusters:
      cluster-a:
        issuer: "${ISSUER_CLUSTER_A}"
        ca_cert: "/var/run/secrets/kubernetes.io/serviceaccount/ca.crt"
        token_path: "/var/run/secrets/kubernetes.io/serviceaccount/token"
      cluster-b:
        issuer: "${ISSUER_CLUSTER_B}"
        api_server: "https://${CLUSTER_B_IP}:6443"
        ca_cert: "/etc/kube-federated-auth/ca-certs/cluster-b-ca.crt"
        token_path: "/etc/kube-federated-auth/tokens/cluster-b-token"
