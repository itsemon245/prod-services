#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Operate a running Redis stack.

Usage:
  scripts/redis-ops.sh compose [--env-file PATH] [--config-dir PATH] -- <docker compose args>
  scripts/redis-ops.sh status [--env-file PATH] [--config-dir PATH]
  scripts/redis-ops.sh acl-reload [--env-file PATH] [--config-dir PATH]
  scripts/redis-ops.sh gateway-reload [--env-file PATH] [--config-dir PATH]

status          Memory, eviction, persistence, client and auth-failure counters
                per enabled role, plus the latest ACL LOG entries.
acl-reload      ACL LOAD on every enabled role, then check that each role's
                password (and REDIS_<ROLE>_PASSWORD_NEXT, when set) authenticates.
                Run `make config redis` first so users.acl holds the new hashes.
gateway-reload  haproxy -c inside the running gateway, then a hitless reload
                with docker kill -s USR2.
USAGE
}

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repo_dir="$(cd -- "$script_dir/.." && pwd)"
# shellcheck source=shared/common.sh
source "$script_dir/shared/common.sh"
# shellcheck source=shared/redis.sh
source "$script_dir/shared/redis.sh"

redis_dir="$repo_dir/redis"
env_file="$redis_dir/.env"
config_dir="$redis_dir/redis_config"
action="${1:-}"
[[ -n "$action" ]] || { usage; exit 1; }
shift
compose_args=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --env-file) env_file="$2"; shift 2 ;;
    --config-dir) config_dir="$2"; shift 2 ;;
    --) shift; compose_args=("$@"); break ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

load_required_env_file "$env_file" "missing env file: $env_file"
load_env_file "$config_dir/compose.env"

compose() {
  [[ -f "$config_dir/compose.env" ]] || die "missing $config_dir/compose.env; run make config redis"
  docker compose \
    --env-file "$env_file" \
    --env-file "$config_dir/compose.env" \
    -f "$redis_dir/docker-compose.yml" \
    -f "$config_dir/compose.override.yml" \
    "$@"
}

# Confirms the container is the one this stack started for the role.
assert_role_container() {
  local role="$1" container="$2" labels project service

  labels="$(docker inspect -f '{{index .Config.Labels "com.docker.compose.project"}} {{index .Config.Labels "com.docker.compose.service"}}' "$container" 2>/dev/null)" \
    || die "container $container ($role) does not exist; is the stack running?"
  read -r project service <<<"$labels"
  [[ "$project" == "${COMPOSE_PROJECT_NAME:-redis}" && "$service" == "$(redis_role_service "$role")" ]] \
    || die "container $container belongs to project '$project' service '$service', expected '${COMPOSE_PROJECT_NAME:-redis}' '$(redis_role_service "$role")'"
}

ops() {
  local container="$1"
  shift
  redis_exec "$container" ops "$REDIS_ADMIN_PASSWORD" "$@"
}

# Like ops(), but falls back to REDIS_ADMIN_PASSWORD_NEXT when the admin
# password itself is being rotated.
ops_any() {
  local container="$1" out
  shift
  if out="$(redis_exec "$container" ops "$REDIS_ADMIN_PASSWORD" "$@" 2>&1)" && [[ "$out" != *WRONGPASS* ]]; then
    printf '%s\n' "$out"
    return 0
  fi
  if [[ -n "${REDIS_ADMIN_PASSWORD_NEXT:-}" ]]; then
    redis_exec "$container" ops "$REDIS_ADMIN_PASSWORD_NEXT" "$@"
    return
  fi
  printf '%s\n' "$out" >&2
  return 1
}

status() {
  local role container info health f

  while IFS= read -r role; do
    container="$(redis_role_container "$role")"
    printf '== %s (%s)\n' "$role" "$container"
    if ! health="$(docker inspect -f '{{.State.Status}} {{if .State.Health}}{{.State.Health.Status}}{{end}} restart={{.HostConfig.RestartPolicy.Name}}' "$container" 2>/dev/null)"; then
      printf '   not running\n'
      continue
    fi
    printf '   state: %s\n' "$health"
    info="$(ops "$container" INFO everything | tr -d '\r')"
    for f in redis_version used_memory_human maxmemory_human maxmemory_policy mem_fragmentation_ratio \
      evicted_keys expired_keys connected_clients blocked_clients rejected_connections \
      acl_access_denied_auth acl_access_denied_cmd total_error_replies \
      rdb_last_bgsave_status rdb_changes_since_last_save aof_enabled aof_last_write_status aof_last_bgrewrite_status; do
      printf '   %-28s %s\n' "$f" "$(redis_info_field "$info" "$f")"
    done
    printf '   %-28s %s\n' keyspace "$(printf '%s\n' "$info" | awk -F: '/^db[0-9]+:/ {print $1": "$2}' | paste -sd' ' -)"
    printf '   recent ACL LOG (auth failures, denied commands):\n'
    ops "$container" ACL LOG 5 | tr -d '\r' | awk '
      /^reason$/ {getline; r=$0} /^username$/ {getline; u=$0} /^client-info$/ {getline; c=$0}
      /^count$/ {getline; n=$0}
      /^timestamp-last-updated$/ {getline; printf "     %s user=%s count=%s %s\n", r, u, n, c}' \
      | sed -E 's/ (cmd|fd|age|idle|flags|db|sub|psub|ssub|multi|watch|qbuf|qbuf-free|argv-mem|multi-mem|rbs|rbp|obl|oll|omem|tot-mem|events|redir|resp|lib-name|lib-ver|io-thread|tot-net-in|tot-net-out|tot-cmds|laddr|id|name|user)=[^ ]*//g'
  done < <(redis_enabled_roles)

  if redis_gateway_enabled; then
    printf '== gateway (%s)\n' "${REDIS_GATEWAY_CONTAINER_NAME:-redis-gateway}"
    docker inspect -f '   state: {{.State.Status}} {{if .State.Health}}{{.State.Health.Status}}{{end}}' "${REDIS_GATEWAY_CONTAINER_NAME:-redis-gateway}" 2>/dev/null || printf '   not running\n'
    printf '   denied connections per frontend (http://127.0.0.1:%s/metrics):\n' "${REDIS_GATEWAY_METRICS_PORT:-8405}"
    docker exec "${REDIS_GATEWAY_CONTAINER_NAME:-redis-gateway}" wget -q -O- http://127.0.0.1:8405/metrics 2>/dev/null \
      | awk '/^haproxy_frontend_denied_connections_total/ {print "     "$0}' || true
  fi
}

acl_reload() {
  local role container prefix name reply failed=0

  while IFS= read -r role; do
    container="$(redis_role_container "$role")"
    assert_role_container "$role" "$container"
    reply="$(ops_any "$container" ACL LOAD | tr -d '\r')"
    [[ "$reply" == OK ]] || die "ACL LOAD on $container failed: $reply"
    prefix="$(redis_role_prefix "$role")"
    for name in "REDIS_${prefix}_PASSWORD" "REDIS_${prefix}_PASSWORD_NEXT" REDIS_ADMIN_PASSWORD REDIS_ADMIN_PASSWORD_NEXT; do
      [[ -n "${!name:-}" ]] || continue
      local user=default
      [[ "$name" == REDIS_ADMIN_* ]] && user=ops
      reply="$(redis_exec "$container" "$user" "${!name}" PING 2>&1 | tr -d '\r')"
      if [[ "$reply" == PONG ]]; then
        printf '%s: ACL reloaded; %s authenticates as %s\n' "$role" "$name" "$user"
      else
        printf '%s: %s does NOT authenticate as %s: %s\n' "$role" "$name" "$user" "$reply" >&2
        failed=1
      fi
    done
  done < <(redis_enabled_roles)
  (( failed == 0 )) || die "some passwords do not authenticate; did you run make config redis first?"
}

gateway_reload() {
  local container="${REDIS_GATEWAY_CONTAINER_NAME:-redis-gateway}" state

  redis_gateway_enabled || die "REDIS_GATEWAY is off"
  docker inspect "$container" >/dev/null 2>&1 || die "gateway container $container is not running; use make serve redis"
  docker exec "$container" haproxy -c -f /usr/local/etc/haproxy/haproxy.cfg \
    || die "haproxy -c failed inside $container; not reloading"
  docker kill -s USR2 "$container" >/dev/null
  sleep 2
  state="$(docker inspect -f '{{.State.Status}}' "$container")"
  [[ "$state" == running ]] || die "gateway $container is $state after reload; check docker logs $container"
  printf 'Gateway %s reloaded (%s allowlist entries)\n' "$container" \
    "$(grep -cv '^#' "$config_dir/gateway/allowlist.lst" || true)"
}

case "$action" in
  compose) compose "${compose_args[@]}" ;;
  status) status ;;
  acl-reload) acl_reload ;;
  gateway-reload) gateway_reload ;;
  -h|--help) usage ;;
  *) die "unknown action: $action" ;;
esac
