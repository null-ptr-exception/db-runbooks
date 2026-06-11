apiVersion: apps/v1
kind: Deployment
metadata:
  name: aqsh-mongodb
  namespace: db-ops
spec:
  replicas: 1
  selector:
    matchLabels:
      app: aqsh-mongodb
  template:
    metadata:
      labels:
        app: aqsh-mongodb
    spec:
      serviceAccountName: kube-auth-proxy
      containers:
        - name: aqsh
          image: ghcr.io/null-ptr-exception/db-runbooks
          imagePullPolicy: Never
          command: ["/bin/sh", "-ceu"]
          args:
            - cp "$AQSH_TASKS_CONFIG" /etc/aqsh/tasks.yaml && exec aqsh
          env:
            - name: AQSH_MODE
              value: both
            - name: AQSH_BIND
              value: "0.0.0.0:8080"
            - name: AQSH_REDIS_ADDR
              value: "redis:6379"
            - name: AQSH_TASKS_CONFIG
              value: /etc/aqsh/task-mongodb.yaml
            - name: AQSH_TASKS_DIR
              value: /tasks
            - name: AQSH_REQUIRE_IDENTITY
              value: "true"
            - name: AQSH_WORKER_QUEUES
              value: "mongodb"
          ports:
            - containerPort: 8080
          livenessProbe:
            httpGet:
              path: /health
              port: 8080
            initialDelaySeconds: 5
            periodSeconds: 10
          readinessProbe:
            httpGet:
              path: /health
              port: 8080
            initialDelaySeconds: 5
            periodSeconds: 10
        - name: kube-auth-proxy
          image: ghcr.io/rophy/kube-auth-proxy:0.4.1
          env:
            - name: UPSTREAM
              value: "http://localhost:8080"
            - name: TOKEN_REVIEW_URL
              value: "http://${CLUSTER_AUTH_IP}:30080"
            - name: PORT
              value: "4180"
          ports:
            - containerPort: 4180
          livenessProbe:
            httpGet:
              path: /healthz
              port: 4180
            initialDelaySeconds: 5
            periodSeconds: 10
          readinessProbe:
            httpGet:
              path: /healthz
              port: 4180
            initialDelaySeconds: 5
            periodSeconds: 10
