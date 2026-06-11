apiVersion: v1
kind: Namespace
metadata:
  name: ${BG_NAMESPACE}
---
apiVersion: v1
kind: Secret
metadata:
  name: mariadb
  namespace: ${BG_NAMESPACE}
type: Opaque
stringData:
  password: ${MARIADB_ROOT_PASSWORD}
---
apiVersion: v1
kind: Secret
metadata:
  name: minio
  namespace: ${BG_NAMESPACE}
type: Opaque
stringData:
  access-key-id: ${MINIO_ACCESS_KEY_ID}
  secret-access-key: ${MINIO_SECRET_ACCESS_KEY}
