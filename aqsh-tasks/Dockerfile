FROM ghcr.io/null-ptr-exception/aqsh:0.4.0

ARG KUBECTL_VERSION=v1.30.0
ARG TASKS_YAML=tasks-mariadb.yaml

# Install base tools + mongosh + mariadb-client
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
       jq python3 curl ca-certificates gnupg \
       mariadb-client \
    # mongosh (MongoDB official apt repo for Debian)
    && curl -fsSL https://www.mongodb.org/static/pgp/server-7.0.asc \
       | gpg --dearmor -o /usr/share/keyrings/mongodb-server-7.0.gpg \
    && echo "deb [ signed-by=/usr/share/keyrings/mongodb-server-7.0.gpg ] https://repo.mongodb.org/apt/debian bookworm/mongodb-org/7.0 main" \
       > /etc/apt/sources.list.d/mongodb-org-7.0.list \
    && apt-get update \
    && apt-get install -y --no-install-recommends mongodb-mongosh \
    && rm -rf /var/lib/apt/lists/* \
    # kubectl
    && curl -fsSLo /usr/local/bin/kubectl "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/$(dpkg --print-architecture)/kubectl" \
    && curl -fsSLo /tmp/kubectl.sha256 "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/$(dpkg --print-architecture)/kubectl.sha256" \
    && echo "$(cat /tmp/kubectl.sha256)  /usr/local/bin/kubectl" | sha256sum -c - \
    && chmod +x /usr/local/bin/kubectl \
    && rm -f /tmp/kubectl.sha256 \
    # MinIO client (mc)
    && curl -fsSLo /usr/local/bin/mc "https://dl.min.io/client/mc/release/linux-$(dpkg --print-architecture)/mc" \
    && chmod +x /usr/local/bin/mc

COPY ${TASKS_YAML} /etc/aqsh/tasks.yaml
COPY --chmod=0755 lib/ /tasks/lib/
COPY --chmod=0755 scripts/ /tasks/
