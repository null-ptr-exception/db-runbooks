FROM docker:29.4.0-dind
RUN for attempt in 1 2 3; do \
      apk add --no-cache bash coreutils curl git jq python3 openssl gettext gnupg tar gzip xz libstdc++ && break; \
      test "$attempt" -lt 3 || exit 1; sleep 3; \
    done
ENV PATH="/root/.local/bin:/root/.local/share/mise/shims:${PATH}"
SHELL ["/bin/bash", "-o", "pipefail", "-c"]
RUN curl --retry 3 -fsSL https://mise.jdx.dev/install.sh | sh
WORKDIR /workspace
COPY .mise.toml .mise.toml
RUN mise trust /workspace && mise install kubectl helm helmfile ctlptl \
    && mise reshim \
    && eval "$(mise env --shell bash)" \
    && helm plugin install https://github.com/databus23/helm-diff
RUN curl --retry 3 -fsSL https://github.com/bats-core/bats-core/archive/refs/tags/v1.13.0.tar.gz \
      | tar -xz -C /tmp \
    && /tmp/bats-core-1.13.0/install.sh /root/.local \
    && rm -rf /tmp/bats-core-1.13.0
COPY ttl-entrypoint.sh /usr/local/bin/local-e2e-entrypoint.sh
RUN chmod +x /usr/local/bin/local-e2e-entrypoint.sh
ENTRYPOINT ["/usr/local/bin/local-e2e-entrypoint.sh"]
