apiVersion: k8s.mariadb.com/v1alpha1
kind: MariaDB
metadata:
  name: mariadb-blue
  namespace: ${BG_NAMESPACE}
spec:
  image: mariadb:10.6
  rootPasswordSecretKeyRef:
    name: mariadb
    key: password
  storage:
    size: 1Gi
  replicas: 2
  replication:
    enabled: true
    gtidDomainId: 0
    serverIdStartIndex: 10
    semiSyncEnabled: false
    replica:
      replPasswordSecretKeyRef:
        name: mariadb
        key: password
      bootstrapFrom:
        physicalBackupTemplateRef:
          name: physicalbackup-blue
      recovery:
        enabled: true
        errorDurationThreshold: 30s
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
  host: mariadb-blue-primary.${BG_NAMESPACE}.svc.cluster.local
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
  host: peer-db-proxy.db-ops.svc.cluster.local
  port: 3306
  username: root
  passwordSecretKeyRef:
    name: mariadb
    key: password
