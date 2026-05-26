apiVersion: v1
kind: ConfigMap
metadata:
  name: nginx-proxy-config
  namespace: db-ops
data:
  nginx.conf: |
    worker_processes auto;
    error_log /dev/stderr warn;
    pid /tmp/nginx.pid;

    events {
      worker_connections 1024;
    }

    # HTTP gateway for aqsh and MinIO
    http {
      access_log /dev/stdout;
      client_body_temp_path /tmp/client_temp;
      proxy_temp_path /tmp/proxy_temp;
      fastcgi_temp_path /tmp/fastcgi_temp;
      uwsgi_temp_path /tmp/uwsgi_temp;
      scgi_temp_path /tmp/scgi_temp;

      upstream aqsh_mariadb {
        server aqsh-mariadb.db-ops.svc.cluster.local:4180;
      }

      upstream aqsh_mongodb {
        server aqsh-mongodb.db-ops.svc.cluster.local:4180;
      }

      upstream minio {
        server ${CLUSTER_MINIO_IP}:30092;
      }

      server {
        listen 80;

        location /mariadb/ {
          rewrite ^/mariadb(/.*)$ $1 break;
          proxy_pass http://aqsh_mariadb;
          proxy_set_header Host $host;
          proxy_set_header Authorization $http_authorization;
          proxy_pass_header Authorization;
        }

        location /mongodb/ {
          rewrite ^/mongodb(/.*)$ $1 break;
          proxy_pass http://aqsh_mongodb;
          proxy_set_header Host $host;
          proxy_set_header Authorization $http_authorization;
          proxy_pass_header Authorization;
        }

        # MinIO API endpoint
        location /minio/ {
          rewrite ^/minio(/.*)$ $1 break;
          proxy_pass http://minio;
          proxy_set_header Host $host;
          proxy_set_header X-Real-IP $remote_addr;
          proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
          proxy_set_header X-Forwarded-Proto $scheme;
          # MinIO requires these for proper operation
          proxy_buffering off;
          proxy_request_buffering off;
          client_max_body_size 0;
        }

        location /healthz {
          return 200 "ok\n";
          add_header Content-Type text/plain;
        }
      }
    }

    # Stream (TCP) proxy for dual-mode DB replication
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
