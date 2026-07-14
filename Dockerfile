FROM ghcr.io/null-ptr-exception/aqsh:0.5.0

ARG KUBECTL_VERSION=v1.30.0
ARG S5CMD_VERSION=2.3.0

# Install base tools + mongosh + mariadb-client
RUN apt-get update \
    && apt-get upgrade -y \
    && apt-get install -y --no-install-recommends \
       jq python3 curl ca-certificates gnupg libgnutls30 \
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
    # s5cmd — S3 client for the backup tasks (#57: replaced mc; pinned GitHub
    # release + checksum, unlike the unpinned dl.min.io fetch that broke in #70)
    && arch="$(dpkg --print-architecture)" \
    && case "$arch" in \
         amd64) s5_asset="Linux-64bit"; s5_sha256="de0fdbfa3aceae55e069ba81a0fc17b2026567637603734a387b2fca06c299b4" ;; \
         arm64) s5_asset="Linux-arm64"; s5_sha256="1439f0d00ecedcd2a2f1f2c6749bbb0152b2257bf5086f29646ec8ae38798e24" ;; \
         *) echo "unsupported architecture: $arch" >&2; exit 1 ;; \
       esac \
    && curl -fsSLo /tmp/s5cmd.tar.gz "https://github.com/peak/s5cmd/releases/download/v${S5CMD_VERSION}/s5cmd_${S5CMD_VERSION}_${s5_asset}.tar.gz" \
    && echo "${s5_sha256}  /tmp/s5cmd.tar.gz" | sha256sum -c - \
    && tar -xzf /tmp/s5cmd.tar.gz -C /usr/local/bin s5cmd \
    && chmod +x /usr/local/bin/s5cmd \
    && rm -f /tmp/s5cmd.tar.gz

# Both the main configs (task-*.yaml: defaults + include) and the included task
# lists (tasks-*.yaml) land flat in /etc/aqsh so the relative include resolves.
COPY aqsh-tasks/task*.yaml /etc/aqsh/
COPY --chmod=0755 aqsh-tasks/lib/ /tasks/lib/
COPY --chmod=0755 aqsh-tasks/scripts/ /tasks/
