apiVersion: k8s.mariadb.com/v1alpha1
kind: PhysicalBackup
metadata:
  name: physicalbackup-blue
  namespace: ${BG_NAMESPACE}
spec:
  mariaDbRef:
    name: mariadb-blue
  # No schedule: runs exactly once, immediately (a cron would fire indefinitely).
  target: PreferReplica
  compression: bzip2
  storage:
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
