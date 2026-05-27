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

    # HTTP block for healthz endpoint
    http {
      access_log /dev/stdout;
      client_body_temp_path /tmp/client_temp;
      proxy_temp_path /tmp/proxy_temp;
      fastcgi_temp_path /tmp/fastcgi_temp;
      uwsgi_temp_path /tmp/uwsgi_temp;
      scgi_temp_path /tmp/scgi_temp;

      server {
        listen 80;

        location /healthz {
          return 200 "ok\n";
          add_header Content-Type text/plain;
        }
      }
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
