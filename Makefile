# vprofile container lab.
#
# Thin, documented wrappers around the docker compose commands in docs/container-lab.md.
# Everything here is reproducible by hand; nothing is hidden.

SHELL := /bin/bash

# Stamped into the image as OCI labels and into WEB-INF/build-info.properties so a running
# container can be traced back to the exact checkout it was built from.
export GIT_SHA    ?= $(shell git rev-parse HEAD 2>/dev/null || echo unknown)
export BUILD_DATE ?= $(shell date -u +%Y-%m-%dT%H:%M:%SZ)

# Host port for nginx. Override if something already owns port 80: make up NGINX_HTTP_PORT=8081
NGINX_HTTP_PORT ?= 80
export NGINX_HTTP_PORT

COMPOSE := docker compose
BASE_URL := http://localhost:$(NGINX_HTTP_PORT)

.DEFAULT_GOAL := help
.PHONY: help config build rebuild up down stop restart ps logs logs-app shell shell-db \
        test verify reset clean provenance image-info

help: ## Show this help
	@grep -hE '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) \
	  | awk 'BEGIN{FS=":.*?## "}{printf "  \033[1m%-14s\033[0m %s\n", $$1, $$2}'
	@echo
	@echo "  App URL: $(BASE_URL)   RabbitMQ UI: http://localhost:15672 (test/test)"

config: ## Validate and render the merged Compose configuration
	$(COMPOSE) config

build: ## Build the application image from local source
	$(COMPOSE) build app

rebuild: ## Build the application image from scratch (no layer cache)
	$(COMPOSE) build --no-cache app

up: ## Start the whole stack in the background and wait for health
	$(COMPOSE) up -d
	@$(MAKE) --no-print-directory ps

down: ## Stop and remove containers and the network (named volume is KEPT)
	$(COMPOSE) down

stop: ## Stop containers without removing them
	$(COMPOSE) stop

restart: ## Restart the application container only
	$(COMPOSE) restart app

ps: ## Show service status and health
	$(COMPOSE) ps --format 'table {{.Service}}\t{{.Status}}\t{{.Ports}}'

logs: ## Follow logs from every service
	$(COMPOSE) logs -f

logs-app: ## Follow application logs only
	$(COMPOSE) logs -f app

shell: ## Open a shell in the application container
	$(COMPOSE) exec app bash

shell-db: ## Open a MySQL client on the accounts database
	$(COMPOSE) exec db mysql -uadmin -padmin123 accounts

test: ## Run the Maven build (including tests) in a throwaway builder container
	docker build --target build -t vprofile-build:check .

verify: ## Smoke-test the running stack end to end
	@set -e; \
	echo "GET /              -> $$(curl -s -o /dev/null -w '%{http_code}' $(BASE_URL)/)"; \
	echo "GET /nginx-health  -> $$(curl -s -o /dev/null -w '%{http_code}' $(BASE_URL)/nginx-health)"; \
	echo "GET /users         -> $$(curl -s -o /dev/null -w '%{http_code}' $(BASE_URL)/users)"; \
	echo "GET /users/7 (x2)  -> $$(curl -s $(BASE_URL)/users/7 >/dev/null; curl -s $(BASE_URL)/users/7 | grep -oE 'Data is From (Cache|DB)')"; \
	echo "GET /user/rabbit   -> $$(curl -s $(BASE_URL)/user/rabbit | grep -oE '<title>[^<]*</title>')"; \
	echo "POST /login        -> $$(curl -s -o /dev/null -w '%{http_code}' -X POST -d 'username=admin_vp&password=admin_vp' $(BASE_URL)/login)"; \
	echo "MySQL rows         -> $$($(COMPOSE) exec -T db mysql -uadmin -padmin123 -N -e 'SELECT COUNT(*) FROM user;' accounts 2>/dev/null) users"

provenance: ## Show that the running image was built from this checkout
	@echo "image revision : $$(docker image inspect $${APP_IMAGE_TAG:-vprofile-app:lab} --format '{{index .Config.Labels "org.opencontainers.image.revision"}}')"
	@echo "git HEAD       : $(GIT_SHA)"
	@$(COMPOSE) exec -T app cat /usr/local/tomcat/conf/build-info.properties

image-info: ## Show image size, runtime user and layer history
	@docker image ls $${APP_IMAGE_TAG:-vprofile-app:lab} --format 'size: {{.Size}}'
	@docker run --rm --entrypoint sh $${APP_IMAGE_TAG:-vprofile-app:lab} -c 'echo "user: $$(id)"'
	@docker image history $${APP_IMAGE_TAG:-vprofile-app:lab}

reset: ## DESTRUCTIVE: remove containers AND the MySQL volume, then rebuild and start fresh
	$(COMPOSE) down -v
	$(COMPOSE) up -d --build
	@$(MAKE) --no-print-directory ps

clean: ## Remove containers, volumes and the locally built application image
	$(COMPOSE) down -v --rmi local
