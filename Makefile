.PHONY: preflight test-mongodb test-mariadb test-unit teardown

preflight:
	scripts/preflight.sh

test-mongodb:
	bats tests/mongodb/

test-mariadb:
	bats tests/mariadb/

test-unit:
	bats --recursive tests/unit

teardown:
	kind delete cluster --name cluster-a
	kind delete cluster --name cluster-b
	docker rm -f registry
