# MongoDB Replica Set StatefulSet
# Deployed when MONGO_TOPOLOGY is "2+1", "1+2", or "3+0".
# MONGO_REPLICAS is substituted at deploy time via envsubst.
# On cluster-a with topology "2+1": MONGO_REPLICAS=2
# On cluster-b with topology "2+1": MONGO_REPLICAS=1
# On cluster-dbs with topology "3+0": MONGO_REPLICAS=3
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: mongodb
  namespace: mongo-1
  labels:
    app.kubernetes.io/name: mongodb
    app.kubernetes.io/component: database
spec:
  selector:
    matchLabels:
      app: mongodb
  serviceName: mongodb
  replicas: ${MONGO_REPLICAS}
  template:
    metadata:
      labels:
        app: mongodb
        app.kubernetes.io/name: mongodb
    spec:
      securityContext:
        runAsNonRoot: true
        runAsUser: 999
        runAsGroup: 999
        fsGroup: 999
      containers:
        - name: mongodb
          image: mongo:7
          args: ["--replSet", "rs0", "--bind_ip_all"]
          ports:
            - containerPort: 27017
          env:
            - name: MONGO_INITDB_ROOT_USERNAME
              valueFrom:
                secretKeyRef:
                  name: mongodb-credentials
                  key: MONGO_ROOT_USER
            - name: MONGO_INITDB_ROOT_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: mongodb-credentials
                  key: MONGO_ROOT_PASS
          securityContext:
            allowPrivilegeEscalation: false
            privileged: false
            capabilities:
              drop:
                - ALL
            seccompProfile:
              type: RuntimeDefault
            readOnlyRootFilesystem: false
          readinessProbe:
            exec:
              command: ["mongosh", "--quiet", "--norc", "--eval", "db.adminCommand('ping').ok"]
            initialDelaySeconds: 10
            periodSeconds: 10
            timeoutSeconds: 5
            failureThreshold: 6
          volumeMounts:
            - name: data
              mountPath: /data/db
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
  name: mongodb
  namespace: mongo-1
  labels:
    app.kubernetes.io/name: mongodb
    app.kubernetes.io/component: database
spec:
  clusterIP: None
  selector:
    app: mongodb
  ports:
    - port: 27017
      targetPort: 27017
