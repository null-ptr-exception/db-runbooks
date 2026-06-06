apiVersion: v1
kind: Service
metadata:
  name: ${BG_MEMBER}-primary-nodeport
  namespace: ${BG_NAMESPACE}
  labels:
    app.kubernetes.io/name: mariadb
    app.kubernetes.io/component: database
    app.kubernetes.io/instance: ${BG_MEMBER}
spec:
  type: NodePort
  selector:
    statefulset.kubernetes.io/pod-name: ${BG_MEMBER}-0
  ports:
    - name: mariadb
      port: 3306
      targetPort: 3306
      nodePort: 30091
