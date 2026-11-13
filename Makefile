SHELL := /bin/bash
.SHELLFLAGS := -eu -o pipefail -c

.DEFAULT_GOAL := help

KNOWN_SERVICES := db postgres redis
KNOWN_INSTALLERS := docker
SERVICE_ARG := $(firstword $(filter $(KNOWN_SERVICES),$(MAKECMDGOALS)))
SERVICE := $(if $(SERVICE_ARG),$(SERVICE_ARG),db)
CANONICAL_SERVICE := $(if $(filter postgres,$(SERVICE)),db,$(SERVICE))
INSTALL_ARG := $(firstword $(filter $(KNOWN_INSTALLERS),$(MAKECMDGOALS)))
INSTALLER := $(if $(INSTALL_ARG),$(INSTALL_ARG),docker)
REDIS_OPS_GOALS := backup status backup-redis status-redis reload-redis-acl reload-redis-gateway compose-redis lint
KNOWN_GOALS := help install docker install-docker config serve db postgres redis config-db serve-db ensure-db-env validate-db-env preview-db-env ensure-db-config prepare-db-data-dir config-redis serve-redis ensure-redis-env validate-redis-env preview-redis-env ensure-redis-config prepare-redis-data-dirs $(REDIS_OPS_GOALS)
UNKNOWN_GOALS := $(filter-out $(KNOWN_GOALS),$(MAKECMDGOALS))

ifneq ($(UNKNOWN_GOALS),)
$(error Unknown make goal(s): $(UNKNOWN_GOALS))
endif

.PHONY: help install docker install-docker config serve db postgres redis config-db serve-db ensure-db-env validate-db-env preview-db-env ensure-db-config prepare-db-data-dir config-redis serve-redis ensure-redis-env validate-redis-env preview-redis-env ensure-redis-config prepare-redis-data-dirs $(REDIS_OPS_GOALS)

help:
	@printf 'Usage:\n'
	@printf '  make install docker  Install Docker Engine and Compose plugin on Debian/Ubuntu\n'
	@printf '  make config db     Generate Postgres config from host resources\n'
	@printf '  make serve db      Validate env, preview safe values, ensure config/data dir, start Postgres\n'
	@printf '  make config redis  Generate Redis configs from host resources\n'
	@printf '  make serve redis   Validate env, preview safe values, ensure config/data dirs, start Redis\n'
	@printf '  make status redis  Memory, eviction, persistence and auth-failure counters per role\n'
	@printf '  make backup redis  BGSAVE, copy RDB/AOF with checksums to REDIS_BACKUP_DIR, prune\n'
	@printf '  make reload-redis-acl      Regenerate ACL files and ACL LOAD (password rotation)\n'
	@printf '  make reload-redis-gateway  Regenerate, check and hitlessly reload the HAProxy gateway\n'
	@printf '  make compose-redis ARGS="ps"  Run docker compose with the generated Redis env\n'
	@printf '  make lint          shellcheck and docker compose config on throwaway env files\n'
	@printf '  make ensure-db-env     Create/fill postgres/.env passwords when needed\n'
	@printf '  make ensure-redis-env  Create/fill redis/.env passwords when needed\n'
	@printf '\n'
	@printf 'Aliases:\n'
	@printf '  db and postgres both refer to the Postgres service\n'

install:
	@$(MAKE) --no-print-directory install-$(INSTALLER)

config:
	@$(MAKE) --no-print-directory config-$(CANONICAL_SERVICE)

serve:
	@$(MAKE) --no-print-directory serve-$(CANONICAL_SERVICE)

backup:
	@$(MAKE) --no-print-directory backup-$(CANONICAL_SERVICE)

status:
	@$(MAKE) --no-print-directory status-$(CANONICAL_SERVICE)

docker db postgres redis:
	@:

install-docker:
	@scripts/install/docker.sh

config-db:
	@scripts/generate-postgres-config.sh

ensure-db-env:
	@scripts/postgres-env-check.sh ensure-env

validate-db-env:
	@scripts/postgres-env-check.sh validate

preview-db-env:
	@scripts/postgres-env-check.sh preview

ensure-db-config:
	@if [[ ! -s postgres/pg_config/postgresql.conf || ! -s postgres/pg_config/pg_hba.conf ]]; then \
		printf 'Postgres config is missing; running make config db\n'; \
		$(MAKE) --no-print-directory config db; \
	elif [[ scripts/generate-postgres-config.sh -nt postgres/pg_config/postgresql.conf || postgres/templates/postgresql.conf.tpl -nt postgres/pg_config/postgresql.conf || postgres/templates/pg_hba.conf.tpl -nt postgres/pg_config/pg_hba.conf || ( -f postgres/.env && postgres/.env -nt postgres/pg_config/postgresql.conf ) ]]; then \
		printf 'Postgres config inputs changed; running make config db\n'; \
		$(MAKE) --no-print-directory config db; \
	else \
		printf 'Postgres config exists: postgres/pg_config\n'; \
	fi

prepare-db-data-dir:
	@scripts/postgres-env-check.sh prepare-data-dir

serve-db:
	@scripts/postgres-env-check.sh ensure-env
	@scripts/postgres-env-check.sh validate
	@scripts/postgres-env-check.sh preview
	@$(MAKE) --no-print-directory ensure-db-config
	@$(MAKE) --no-print-directory prepare-db-data-dir
	@docker compose --env-file postgres/.env -f postgres/docker-compose.yml up -d

config-redis:
	@scripts/generate-redis-config.sh

ensure-redis-env:
	@scripts/redis-env-check.sh ensure-env

validate-redis-env:
	@scripts/redis-env-check.sh validate

preview-redis-env:
	@scripts/redis-env-check.sh preview

ensure-redis-config:
	@# Always regenerate: it is cheap and idempotent, and inputs now include
	@# REDIS_ROLES, the gateway allowlist and shared scripts.
	@$(MAKE) --no-print-directory config redis

prepare-redis-data-dirs:
	@scripts/redis-env-check.sh prepare-data-dirs

serve-redis:
	@scripts/redis-env-check.sh ensure-env
	@scripts/redis-env-check.sh validate
	@scripts/redis-env-check.sh preview
	@$(MAKE) --no-print-directory ensure-redis-config
	@$(MAKE) --no-print-directory prepare-redis-data-dirs
	@scripts/redis-ops.sh compose -- up -d --wait
	@# Containers that were not recreated still hold the ACL they started with;
	@# load the regenerated users.acl and check every password authenticates.
	@scripts/redis-ops.sh acl-reload

compose-redis:
	@scripts/redis-ops.sh compose -- $(ARGS)

status-redis:
	@scripts/redis-ops.sh status

backup-redis:
	@scripts/redis-backup.sh

reload-redis-acl:
	@$(MAKE) --no-print-directory config redis
	@scripts/redis-ops.sh acl-reload

reload-redis-gateway:
	@$(MAKE) --no-print-directory config redis
	@scripts/redis-ops.sh gateway-reload

lint:
	@scripts/lint.sh
