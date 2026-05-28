apiVersion: v1
kind: ConfigMap
metadata:
  name: kube-federated-auth-config
  namespace: db-ops
data:
  clusters.yaml: |
    authorized_clients:
      - "cluster-dbs-a/db-ops/kube-auth-proxy"
      - "cluster-dbs-b/db-ops/kube-auth-proxy"
    cache:
      ttl: 60
      max_entries: 1000
    clusters:
      cluster-dbs-a:
        issuer: "https://kubernetes.default.svc.cluster.local"
        ca_cert: "/var/run/secrets/kubernetes.io/serviceaccount/ca.crt"
        token_path: "/var/run/secrets/kubernetes.io/serviceaccount/token"
      cluster-dbs-b:
        issuer: "${ISSUER_DBS_B}"
        api_server: "https://${CLUSTER_DBS_B_IP}:6443"
        ca_cert: "/etc/kube-federated-auth/ca-certs/cluster-dbs-b-ca.crt"
        token_path: "/etc/kube-federated-auth/tokens/cluster-dbs-b-token"
      cluster-apps:
        issuer: "${ISSUER_APPS}"
        api_server: "https://${CLUSTER_APPS_IP}:6443"
        ca_cert: "/etc/kube-federated-auth/ca-certs/cluster-apps-ca.crt"
        token_path: "/etc/kube-federated-auth/tokens/cluster-apps-token"
