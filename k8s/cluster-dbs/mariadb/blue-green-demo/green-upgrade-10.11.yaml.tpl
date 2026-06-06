apiVersion: k8s.mariadb.com/v1alpha1
kind: MariaDB
metadata:
  name: mariadb-green
  namespace: ${BG_NAMESPACE}
spec:
  image: ${GREEN_UPGRADE_IMAGE}
  rootPasswordSecretKeyRef:
    name: mariadb
    key: password
  storage:
    size: 1Gi
  replicas: 2
  # bootstrapFrom is only used for the initial restore; normal image upgrades do not re-run this S3 bootstrap.
  # Use the operator restore flow for an ad-hoc re-bootstrap instead of relying on reapplying this field.
  bootstrapFrom:
    s3:
      bucket: ${MINIO_BUCKET}
      prefix: ${MINIO_PREFIX}
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
  host: ${PEER_DB_PROXY_HOST}
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
