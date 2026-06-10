FROM ghcr.io/null-ptr-exception/aqsh:0.5.0

ARG KUBECTL_VERSION=v1.30.0

# Install base tools + mongosh + mariadb-client
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
       jq python3 curl ca-certificates gnupg libgnutls30=3.7.9-2+deb12u7 \
       mariadb-client \
    && dpkg-query -W -f='${Version}\n' libgnutls30 | grep -qx '3.7.9-2+deb12u7' \
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

# Both the main configs (task-*.yaml: defaults + include) and the included task
# lists (tasks-*.yaml) land flat in /etc/aqsh so the relative include resolves.
COPY aqsh-tasks/task*.yaml /etc/aqsh/
COPY --chmod=0755 aqsh-tasks/lib/ /tasks/lib/
COPY --chmod=0755 aqsh-tasks/scripts/ /tasks/
