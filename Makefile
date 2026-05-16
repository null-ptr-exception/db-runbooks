.PHONY: up down deploy test

up:
	scripts/setup.sh

down:
	scripts/teardown.sh

deploy:
	scripts/deploy.sh

test:
	scripts/test.sh
