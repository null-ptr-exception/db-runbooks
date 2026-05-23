.PHONY: single multi down \
        test-unit test-mariadb test-mongodb test-multi \
        test-quick-mariadb test-quick-mongodb test

MONGO_FLAVOR ?= official
MONGO_REPLICATION_MODE ?= 3+3

# ── Cluster lifecycle ─────────────────────────────────────────────────────────

single: ## Spin up region-a + apps-minio (single-region mode)
	MODE=single MONGO_FLAVOR=$(MONGO_FLAVOR) MONGO_REPLICATION_MODE=$(MONGO_REPLICATION_MODE) scripts/setup.sh

multi: ## Spin up region-a + region-b + apps-minio (multi-region mode)
	MODE=multi MONGO_FLAVOR=$(MONGO_FLAVOR) MONGO_REPLICATION_MODE=$(MONGO_REPLICATION_MODE) scripts/setup.sh

down: ## Tear down all clusters
	scripts/teardown.sh

# ── Tests ─────────────────────────────────────────────────────────────────────

test-unit: ## BATS unit tests (no cluster needed)
	bats tests/unit/

test-mariadb: ## Spin up single → integration/mariadb → tear down
	MODE=single MONGO_FLAVOR=$(MONGO_FLAVOR) MONGO_REPLICATION_MODE=$(MONGO_REPLICATION_MODE) scripts/setup.sh
	bats tests/integration/mariadb/ || true
	scripts/teardown.sh

test-mongodb: ## Spin up single → integration/mongodb → tear down
	MODE=single MONGO_FLAVOR=$(MONGO_FLAVOR) MONGO_REPLICATION_MODE=$(MONGO_REPLICATION_MODE) scripts/setup.sh
	bats tests/integration/mongodb/ || true
	scripts/teardown.sh

test-multi: ## Spin up multi → integration/replication → tear down
	MODE=multi MONGO_FLAVOR=$(MONGO_FLAVOR) MONGO_REPLICATION_MODE=$(MONGO_REPLICATION_MODE) scripts/setup.sh
	bats tests/integration/replication/ || true
	scripts/teardown.sh

test-quick-mariadb: ## Run mariadb integration tests (cluster must be running)
	bats tests/integration/mariadb/

test-quick-mongodb: ## Run mongodb integration tests (cluster must be running)
	bats tests/integration/mongodb/

test: test-unit test-mariadb test-mongodb ## Run all unit + integration tests

# ── Legacy aliases ────────────────────────────────────────────────────────────

up: single
deploy:
	scripts/deploy.sh
