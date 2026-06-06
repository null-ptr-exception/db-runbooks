apiVersion: k8s.mariadb.com/v1alpha1
kind: MariaDB
metadata:
  name: mariadb-green
  namespace: ${BG_NAMESPACE}
spec:
  image: mariadb:10.11
  rootPasswordSecretKeyRef:
    name: mariadb
    key: password
  storage:
    size: 1Gi
  replicas: 2
  bootstrapFrom:
    s3:
      bucket: ${MINIO_BUCKET}
      prefix: blue
      endpoint: ${MINIO_ENDPOINT}
      region: us-east-1
      accessKeyIdSecretKeyRef:
        name: minio
        key: access-key-id
      secretAccessKeySecretKeyRef:
        name: minio
        key: secret-access-key
    backupContentType: Physical
  replication:
    enabled: true
    gtidDomainId: 1
    gtidStrictMode: false
    serverIdStartIndex: 20
    semiSyncEnabled: false
    replica:
      replPasswordSecretKeyRef:
        name: mariadb
        key: password
  multiCluster:
    enabled: true
    primary: mariadb-blue
    members:
      - name: mariadb-blue
        externalMariaDbRef:
          name: mariadb-blue
      - name: mariadb-green
        externalMariaDbRef:
          name: mariadb-green
---
apiVersion: k8s.mariadb.com/v1alpha1
kind: ExternalMariaDB
metadata:
  name: mariadb-blue
  namespace: ${BG_NAMESPACE}
spec:
  host: peer-db-proxy.db-ops.svc.cluster.local
  port: 3306
  username: root
  passwordSecretKeyRef:
    name: mariadb
    key: password
---
apiVersion: k8s.mariadb.com/v1alpha1
kind: ExternalMariaDB
metadata:
  name: mariadb-green
  namespace: ${BG_NAMESPACE}
spec:
  host: mariadb-green-primary.${BG_NAMESPACE}.svc.cluster.local
  port: 3306
  username: root
  passwordSecretKeyRef:
    name: mariadb
    key: password
