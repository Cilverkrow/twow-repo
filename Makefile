# Tortoise-WoW operations. Linux + Docker is the deployment platform (ADR-0028);
# there is no PowerShell equivalent of this file and there is not going to be.
#
# The contract: `make up` is the single command that gets a running server, and
# it refuses to start a broken one. Missing credentials or missing client data
# fail here with an explanation, not fifteen minutes later inside a container.

SHELL := /bin/bash
.DEFAULT_GOAL := help

COMPOSE_DIR  := deploy/compose
COMPOSE_FILE := $(COMPOSE_DIR)/docker-compose.yml
ENV_FILE     := $(COMPOSE_DIR)/.env
COMPOSE      := docker compose -f $(COMPOSE_FILE) --env-file $(ENV_FILE)
HELM_CHART   := deploy/helm/twow

# DATA_PATH in .env is relative to the compose file, matching how compose itself
# resolves it; the guard below resolves it the same way rather than guessing.
DATA_PATH ?= ./data

.PHONY: help up down restart logs ps console smoke test build extract clean config check-env check-core check-data helm-lint

help: ## Show this help
	@echo "Tortoise-WoW -- make targets"
	@echo
	@grep -hE '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) \
		| awk 'BEGIN{FS=":.*?## "}{printf "  \033[1m%-12s\033[0m %s\n", $$1, $$2}'
	@echo
	@echo "First run: cp $(COMPOSE_DIR)/.env.example $(ENV_FILE) && edit it, then 'make extract', then 'make up'."

# ------------------------------------------------------------------- guards

check-env:
	@test -f $(ENV_FILE) || { \
		echo "ERROR: $(ENV_FILE) is missing."; \
		echo "  cp $(COMPOSE_DIR)/.env.example $(ENV_FILE)"; \
		echo "  then set DB_ROOT_PASSWORD and DB_PASSWORD. It is gitignored; keep it that way."; \
		exit 1; }
	@set -a; . ./$(ENV_FILE); set +a; \
	for v in DB_ROOT_PASSWORD DB_PASSWORD; do \
		if [ -z "$${!v:-}" ]; then echo "ERROR: $$v is unset in $(ENV_FILE)."; exit 1; fi; \
		case "$${!v}" in change-me*) echo "ERROR: $$v is still the example placeholder in $(ENV_FILE)."; exit 1;; esac; \
	done

# The world server starts, loads, and then fails or serves an empty world if the
# client data is absent. Catch it here instead.
check-data: check-env
	@set -a; . ./$(ENV_FILE); set +a; \
	data="$(COMPOSE_DIR)/$${DATA_PATH:-./data}"; \
	missing=""; \
	for d in dbc maps vmaps mmaps; do \
		if [ ! -d "$$data/$$d" ] || [ -z "$$(ls -A "$$data/$$d" 2>/dev/null)" ]; then missing="$$missing $$d"; fi; \
	done; \
	if [ -n "$$missing" ]; then \
		echo "ERROR: client data missing under $$data:$$missing"; \
		echo "  It is extracted from your own game client and is never shipped in an image."; \
		echo "  Put a client at CLIENT_PATH and run 'make extract' (mmaps take an hour or more),"; \
		echo "  or point DATA_PATH in $(ENV_FILE) at an existing extraction."; \
		exit 1; \
	fi

# ------------------------------------------------------------------ lifecycle

config: check-env ## Render server configs from config/examples + .env
	@set -a; . ./$(ENV_FILE); set +a; bash $(COMPOSE_DIR)/render-config.sh

# The core is the core/ submodule (ADR-0020) and it carries the Eluna engine as
# a submodule of its own. A non-recursive clone gets a working tree that looks
# complete, and the failure lands ten minutes into a container build as a CMake
# FATAL_ERROR. Fail here instead, with the command to run.
check-core:
	@test -f core/CMakeLists.txt || { \
		echo "ERROR: core/ is empty -- the server core is a git submodule."; \
		echo "  git submodule update --init --recursive"; \
		exit 1; }
	@test -f core/src/modules/Eluna/LuaEngine.h || { \
		echo "ERROR: core/src/modules/Eluna is empty. The checkout stopped one level short:"; \
		echo "  git submodule update --init --recursive"; \
		exit 1; }

build: check-env check-core ## Build the server image
	@$(COMPOSE) build mangosd

up: check-env check-core check-data config ## Start the whole stack (the one command)
	@$(COMPOSE) up -d --build
	@echo
	@echo "Stack starting. The first start imports ~130 MB of world data and builds the"
	@echo "bot travel graph; give it several minutes before worrying. Watch it with 'make logs'."

down: ## Stop the stack, leaving data intact
	@$(COMPOSE) down

restart: ## Restart the world server only (graceful)
	@$(COMPOSE) restart mangosd

logs: ## Follow logs (S=mangosd to pick one service)
	@$(COMPOSE) logs -f --tail=200 $(S)

ps: ## Show service state and health
	@$(COMPOSE) ps

# The FIFO is how the running world server is driven; it is also what stops
# mangosd exiting on EOF. Do not attach a tty instead.
console: ## Send a console command, e.g. make console CMD='server info'
	@test -n "$(CMD)" || { echo "usage: make console CMD='server info'"; exit 1; }
	@$(COMPOSE) exec -T mangosd sh -c 'printf "%s\n" "$(CMD)" > /opt/turtle/run/mangosd.in'
	@echo "sent: $(CMD)  (output appears in 'make logs')"

extract: check-env ## Extract client data (tools profile; mmaps take hours)
	@set -a; . ./$(ENV_FILE); set +a; \
	client="$(COMPOSE_DIR)/$${CLIENT_PATH:-./client}"; \
	test -d "$$client/Data" || { \
		echo "ERROR: no game client at $$client (expected a Data/ directory)."; \
		echo "  Set CLIENT_PATH in $(ENV_FILE) to a Turtle WoW 1.18.1 build 7272 client."; \
		exit 1; }
	@$(COMPOSE) --profile tools run --rm extractor

# ---------------------------------------------------------------- validation

smoke: ## Check that the running stack is actually serving
	@fail=0; \
	for s in db realmd mangosd; do \
		state=$$($(COMPOSE) ps --format '{{.Health}}' $$s 2>/dev/null | head -1); \
		printf '  %-8s %s\n' "$$s" "$${state:-not running}"; \
		[ "$$state" = "healthy" ] || fail=1; \
	done; \
	echo "  db-init  $$($(COMPOSE) ps -a --format '{{.State}}' db-init 2>/dev/null | head -1)"; \
	$(COMPOSE) exec -T db mariadb -u root -p"$$(grep -E '^DB_ROOT_PASSWORD=' $(ENV_FILE) | cut -d= -f2-)" \
		-N -B -e "SELECT CONCAT('  realmlist rows: ', COUNT(*)) FROM tw_logon.realmlist;" || fail=1; \
	$(COMPOSE) exec -T mangosd sh -c 'printf "server info\n" > /opt/turtle/run/mangosd.in' || fail=1; \
	if [ $$fail -ne 0 ]; then echo "SMOKE FAILED"; exit 1; fi; \
	echo "SMOKE OK (console reply is in 'make logs')"

test: ## Validate compose and helm definitions (no running stack needed)
	@echo "==> docker compose config"
	@docker compose -f $(COMPOSE_FILE) config --quiet
	@echo "==> shell syntax"
	@for f in $(COMPOSE_DIR)/*.sh; do bash -n "$$f"; done
	@$(MAKE) --no-print-directory helm-lint

helm-lint: ## Lint and render the Helm chart
	@if command -v helm >/dev/null 2>&1; then \
		echo "==> helm lint"; helm lint $(HELM_CHART); \
		echo "==> helm template"; helm template twow $(HELM_CHART) >/dev/null && echo "helm template ok"; \
		echo "==> helm template (dev values)"; helm template twow $(HELM_CHART) -f $(HELM_CHART)/values-dev.yaml >/dev/null && echo "helm template -f values-dev.yaml ok"; \
	else \
		echo "helm not installed; skipping chart validation"; \
	fi

# `down -v` removes the database and the bootstrap markers, so the next `make up`
# re-imports from scratch. Rendered configs go too; client data does not.
clean: ## Remove containers, volumes and rendered configs (DESTROYS the database)
	@echo "This deletes the database volume and every character on it."
	@read -r -p "Type 'yes' to continue: " a; [ "$$a" = "yes" ] || { echo "aborted"; exit 1; }
	@$(COMPOSE) --profile tools --profile dev down -v --remove-orphans
	@rm -f $(COMPOSE_DIR)/config/*.conf
	@echo "Removed. Client data under DATA_PATH was left alone."
