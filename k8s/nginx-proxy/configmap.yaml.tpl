apiVersion: v1
kind: ConfigMap
metadata:
  name: nginx-proxy-config
  namespace: db-ops
data:
  nginx.conf: |
    worker_processes 1;
    error_log /dev/stderr warn;
    pid /tmp/nginx.pid;

    events {
      worker_connections 1024;
    }

    stream {
      log_format proxy '$remote_addr [$time_local] '
                       '$protocol $status $bytes_sent $bytes_received '
                       '$session_time "$upstream_addr"';
      access_log /dev/stdout proxy;

      server {
        listen 27017;
        proxy_pass ${PEER_DBS_IP}:30090;
        proxy_connect_timeout 5s;
        proxy_timeout 300s;
      }

      server {
        listen 3306;
        proxy_pass ${PEER_DBS_IP}:30091;
        proxy_connect_timeout 5s;
        proxy_timeout 300s;
      }
    }
