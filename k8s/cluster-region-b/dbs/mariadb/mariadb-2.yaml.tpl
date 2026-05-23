apiVersion: v1
kind: Secret
metadata:
  name: mariadb
  namespace: mariadb-2
stringData:
  password: mariadb2-root-pass
---
apiVersion: k8s.mariadb.com/v1alpha1
kind: MariaDB
metadata:
  name: mariadb
  namespace: mariadb-2
spec:
  rootPasswordSecretKeyRef:
    name: mariadb
    key: password
  replication:
    enabled: true
    primary:
      podIndex: 0
      automaticFailover: false
    replica:
      waitPoint: AfterSync
      gtid: CurrentPos
      externalPrimary:
        host: "${REGION_A_IP}"
        port: 30095
      replicaPasswordSecretKeyRef:
        name: mariadb-replication-user
        key: REPLICATION_PASSWORD
      replicationUserSecretKeyRef:
        name: mariadb-replication-user
        key: REPLICATION_USER
  port: 3306
  image: mariadb:10.11
  storage:
    size: 1Gi
