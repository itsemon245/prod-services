#!/usr/bin/env bash
# shellcheck disable=SC2015  # test harness: pass/fail chains are intentional
# Upgrade test: deploy the Redis stack from a base git ref (default
# origin/main, the old single-file-config layout), write data, then upgrade
# the same checkout in place to the working tree with `make serve redis`.
#
#   tests/redis/upgrade-test.sh [BASE_REF]
#   tests/redis/migration-test.sh cleanup pstest-XXXXXX   # removes what this created
#
# Throwaway only: project/containers pstest-<id>-*, work dir under
# $HOME/.cache/prod-services-tests/. Never touches redis/.env of this repo.
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repo_dir="$(cd -- "$script_dir/../.." && pwd)"
# shellcheck source=../../scripts/shared/common.sh
source "$repo_dir/scripts/shared/common.sh"

base_ref="${1:-origin/main}"
base_dir="$HOME/.cache/prod-services-tests"
id="pstest-$(openssl rand -hex 3)"
work="$base_dir/$id"
old="$work/checkout"
port_base=$(( 30000 + RANDOM % 20000 ))
failures=0
pass() { printf 'TEST PASS: %s\n' "$*"; }
fail() { printf 'TEST FAIL: %s\n' "$*"; failures=$(( failures + 1 )); }
step() { printf '\n######## %s  [%s]\n' "$*" "$(date -u +%T)"; }

mkdir -p "$old"
chmod 0700 "$work"
printf '%s\n' "$id" > "$base_dir/last-id"
printf 'id=%s work=%s base=%s\n' "$id" "$work" "$base_ref"

step "Deploy $base_ref (old layout)"
git -C "$repo_dir" archive "$base_ref" | tar -x -C "$old"
env_file="$old/redis/.env"
cp "$old/redis/.env.example" "$env_file"
kv() { set_env_file_value "$1" "$2" "$env_file"; }
# The old code derives the project from the directory name; pin it so this
# test cannot collide with anything else.
kv COMPOSE_PROJECT_NAME "$id"
kv REDIS_MEMORY_MB 4096
kv REDIS_CPU_CORES 2
i=0
for r in cache session queue ws; do
  R="${r^^}"
  kv "REDIS_${R}_CONTAINER_NAME" "$id-$r"
  kv "REDIS_${R}_HOST_PORT" "$(( port_base + i ))"
  kv "REDIS_${R}_DATA_DIR" "$work/data/$r"
  i=$(( i + 1 ))
done
(cd "$old" && scripts/redis-env-check.sh ensure-env --yes >/dev/null && scripts/generate-redis-config.sh | tail -2 \
  && scripts/redis-env-check.sh prepare-data-dirs >/dev/null \
  && docker compose --env-file redis/.env --env-file redis/redis_config/compose.env -f redis/docker-compose.yml up -d --wait 2>&1 | tail -2)
docker ps --filter "label=com.docker.compose.project=$id" --format '{{.Names}} {{.Status}}'

queue_pw="$(env_file_value REDIS_QUEUE_PASSWORD "$env_file")"
cache_pw="$(env_file_value REDIS_CACHE_PASSWORD "$env_file")"
qport=$(( port_base + 2 ))
cport=$(( port_base + 0 ))
for n in $(seq 1 1000); do printf 'SET job:%s payload-%s\n' "$n" "$n"; done \
  | REDISCLI_AUTH="$queue_pw" redis-cli --no-auth-warning -p "$qport" >/dev/null
REDISCLI_AUTH="$cache_pw" redis-cli --no-auth-warning -p "$cport" SET cached yes >/dev/null
printf 'queue dbsize before upgrade: %s\n' "$(REDISCLI_AUTH="$queue_pw" redis-cli --no-auth-warning -p "$qport" DBSIZE)"
grep -c '^requirepass ' "$old"/redis/redis_config/*.conf | paste -sd' ' - | sed 's/^/plaintext requirepass lines before: /'

step "Upgrade the checkout in place to the working tree and run make serve redis"
(cd "$repo_dir" && git ls-files -co --exclude-standard -z | tar --null -T - -cf -) | tar -x -C "$old"
# Same values a real upgrade would see (project/network are "redis"/"redis_default"
# on real hosts, which are the new defaults).
kv REDIS_COMPOSE_PROJECT_NAME "$id"
kv REDIS_NETWORK_NAME "${id}_default"
(cd "$old" && scripts/redis-env-check.sh ensure-env --yes | grep -i generated || true)
(cd "$old" && make serve redis 2>&1 | grep -vE '^  ' | tail -12)
for _ in $(seq 1 45); do
  [[ "$(docker ps --filter "label=com.docker.compose.project=$id" --filter health=starting -q | wc -l)" == 0 ]] && break
  sleep 2
done
docker ps --filter "label=com.docker.compose.project=$id" --format '{{.Names}} {{.Status}}'

step "Checks"
for r in cache session queue ws; do
  [[ "$(docker inspect -f '{{.State.Health.Status}}' "$id-$r" 2>/dev/null)" == healthy ]] && pass "$r healthy after upgrade" || fail "$r not healthy"
done
[[ "$(REDISCLI_AUTH="$queue_pw" redis-cli --no-auth-warning -p "$qport" DBSIZE)" == 1000 ]] && pass "queue data survived (1000 keys, AOF)" || fail "queue data lost"
[[ "$(REDISCLI_AUTH="$queue_pw" redis-cli --no-auth-warning -p "$qport" GET job:777)" == payload-777 ]] && pass "queue value intact" || fail "queue value"
[[ "$(REDISCLI_AUTH="$cache_pw" redis-cli --no-auth-warning -p "$cport" PING)" == PONG ]] && pass "existing app password still works (default user)" || fail "app password broken"
if grep -l '^requirepass ' "$old"/redis/redis_config/*.conf "$old"/redis/redis_config/*/redis.conf 2>/dev/null; then fail "plaintext requirepass left behind"; else pass "no plaintext requirepass left in redis_config"; fi
[[ -n "$(env_file_value REDIS_ADMIN_PASSWORD "$env_file")" ]] && pass "REDIS_ADMIN_PASSWORD generated" || fail "no admin password"
[[ "$(docker inspect -f '{{.NetworkSettings.Networks}}' "$id-queue")" == *"${id}_default"* ]] && pass "same network kept" || fail "network changed"
printf 'session persistence now: %s\n' "$(grep -h '^save\|^appendonly' "$old/redis/redis_config/session/redis.conf" | paste -sd' ' -)"

printf '\nid=%s failures=%s\nClean up with: tests/redis/migration-test.sh cleanup %s\n' "$id" "$failures" "$id"
(( failures == 0 ))
