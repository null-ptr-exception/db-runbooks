# MariaDB native StatefulSet for replication topology.
# Deployed when MARIADB_TOPOLOGY is "2+1", "1+2", or "3+0".
# MARIADB_REPLICAS and MARIADB_BASE_SERVER_ID are substituted at deploy time
# via: envsubst '${MARIADB_REPLICAS} ${MARIADB_BASE_SERVER_ID}'
# On cluster-a with topology "2+1": MARIADB_REPLICAS=2, MARIADB_BASE_SERVER_ID=1
# On cluster-b with topology "2+1": MARIADB_REPLICAS=1, MARIADB_BASE_SERVER_ID=3
# On cluster-dbs with topology "3+0": MARIADB_REPLICAS=3, MARIADB_BASE_SERVER_ID=1
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: mariadb
  namespace: mariadb-1
  labels:
    app.kubernetes.io/name: mariadb
    app.kubernetes.io/component: database
spec:
  selector:
    matchLabels:
      app: mariadb
  serviceName: mariadb
  replicas: ${MARIADB_REPLICAS}
  template:
    metadata:
      labels:
        app: mariadb
        app.kubernetes.io/name: mariadb
    spec:
      securityContext:
        runAsNonRoot: true
        runAsUser: 999
        runAsGroup: 999
        fsGroup: 999
      containers:
        - name: mariadb
          image: mariadb:10.6
          # server-id is derived from pod ordinal + BASE_SERVER_ID so each pod
          # gets a unique ID required for GTID-based replication.
          # cluster-a with "2+1": BASE_SERVER_ID=1 → pod-0: id=1, pod-1: id=2
          # cluster-b with "2+1": BASE_SERVER_ID=3 → pod-0: id=3
          command: ["/bin/bash", "-c"]
          args:
            - |
              POD_ORDINAL="${HOSTNAME##*-}"
              SERVER_ID=$(( $BASE_SERVER_ID + $POD_ORDINAL ))
              exec mariadbd \
                --server-id="$SERVER_ID" \
                --log-bin=mysql-bin \
                --binlog-format=ROW \
                --gtid-strict-mode=ON \
                --log-slave-updates=ON \
                "$@"
          env:
            - name: MARIADB_ROOT_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: mariadb
                  key: password
            - name: BASE_SERVER_ID
              value: "${MARIADB_BASE_SERVER_ID}"
          ports:
            - containerPort: 3306
          securityContext:
            allowPrivilegeEscalation: false
            privileged: false
            capabilities:
              drop:
                - ALL
            readOnlyRootFilesystem: false
          readinessProbe:
            exec:
              command:
                - sh
                - -c
                - |
                  mariadb -u root -p"${MARIADB_ROOT_PASSWORD}" -e "SELECT 1" 2>/dev/null
            initialDelaySeconds: 15
            periodSeconds: 10
            timeoutSeconds: 5
            failureThreshold: 6
          volumeMounts:
            - name: data
              mountPath: /var/lib/mysql
  volumeClaimTemplates:
    - metadata:
        name: data
      spec:
        accessModes: ["ReadWriteOnce"]
        resources:
          requests:
            storage: 1Gi
---
apiVersion: v1
kind: Service
metadata:
  name: mariadb
  namespace: mariadb-1
  labels:
    app.kubernetes.io/name: mariadb
    app.kubernetes.io/component: database
spec:
  clusterIP: None
  selector:
    app: mariadb
  ports:
    - port: 3306
      targetPort: 3306
