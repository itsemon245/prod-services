#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2154  # library: constants are used by the scripts that source it; repo_dir comes from them
# Shared Redis role metadata and helpers. Source after shared/common.sh.
#
# Every role has the same set of knobs. Defaults live here so the generator,
# env check, backup and ops scripts agree on them.

REDIS_ALL_ROLES=(cache session queue ws)
REDIS_DEFAULT_IMAGE="redis:8.8.4-alpine"
REDIS_DEFAULT_GATEWAY_IMAGE="haproxy:3.2.26-alpine"
REDIS_DEFAULT_EXPORTER_IMAGE="oliver006/redis_exporter:v1.97.0-alpine"
REDIS_DEFAULT_DATA_ROOT="/srv/prod-services/redis"
REDIS_DEFAULT_BACKUP_DIR="/srv/prod-services/backups/redis"
REDIS_DEFAULT_APP_ACL_RULES="~* &* +@all -@admin"

redis_role_prefix() {
  case "$1" in
    cache) printf 'CACHE\n' ;;
    session) printf 'SESSION\n' ;;
    queue) printf 'QUEUE\n' ;;
    ws) printf 'WS\n' ;;
    *) die "unknown Redis role: $1 (expected one of: ${REDIS_ALL_ROLES[*]})" ;;
  esac
}

# redis_role_default ROLE FIELD
redis_role_default() {
  local role="$1" field="$2"

  case "$field:$role" in
    container:*) printf 'redis-%s\n' "$role" ;;
    service:*) printf 'redis-%s\n' "$role" ;;
    host_port:cache) printf '6379\n' ;;
    host_port:session) printf '6380\n' ;;
    host_port:queue) printf '6381\n' ;;
    host_port:ws) printf '6382\n' ;;
    gateway_port:cache) printf '7379\n' ;;
    gateway_port:session) printf '7380\n' ;;
    gateway_port:queue) printf '7381\n' ;;
    gateway_port:ws) printf '7382\n' ;;
    exporter_port:cache) printf '9121\n' ;;
    exporter_port:session) printf '9122\n' ;;
    exporter_port:queue) printf '9123\n' ;;
    exporter_port:ws) printf '9124\n' ;;
    data_dir:*) printf '%s/%s\n' "$REDIS_DEFAULT_DATA_ROOT" "$role" ;;
    persistence:cache) printf 'none\n' ;;
    persistence:session) printf 'rdb\n' ;;
    persistence:queue) printf 'aof\n' ;;
    persistence:ws) printf 'none\n' ;;
    policy:cache) printf 'allkeys-lru\n' ;;
    policy:session) printf 'volatile-ttl\n' ;;
    policy:queue) printf 'noeviction\n' ;;
    policy:ws) printf 'allkeys-lru\n' ;;
    samples:cache|samples:session) printf '7\n' ;;
    samples:queue|samples:ws) printf '5\n' ;;
    weight:cache) printf '30\n' ;;
    weight:session) printf '13\n' ;;
    weight:queue) printf '52\n' ;;
    weight:ws) printf '5\n' ;;
    min_maxmemory:cache|min_maxmemory:session) printf '64\n' ;;
    min_maxmemory:queue) printf '128\n' ;;
    min_maxmemory:ws) printf '32\n' ;;
    label:ws) printf 'websocket\n' ;;
    label:*) printf '%s\n' "$role" ;;
    *) die "no default for Redis role field $field:$role" ;;
  esac
}

# redis_role_setting ROLE SUFFIX FIELD -> value of REDIS_<ROLE>_<SUFFIX> or the role default
redis_role_setting() {
  local role="$1" suffix="$2" field="$3" prefix name

  prefix="$(redis_role_prefix "$role")"
  name="REDIS_${prefix}_${suffix}"
  if [[ -n "${!name:-}" ]]; then
    printf '%s\n' "${!name}"
  else
    redis_role_default "$role" "$field"
  fi
}

redis_role_container() { redis_role_setting "$1" CONTAINER_NAME container; }
redis_role_service() { redis_role_default "$1" service; }
redis_role_persistence() { redis_role_setting "$1" PERSISTENCE persistence; }
redis_role_policy() { redis_role_setting "$1" MAXMEMORY_POLICY policy; }
redis_role_data_dir() { redis_role_setting "$1" DATA_DIR data_dir; }

# Prints the enabled roles, one per line, in canonical order.
# REDIS_ROLES is comma or space separated; empty/unset means all roles.
redis_enabled_roles() {
  local raw="${REDIS_ROLES:-}" item role found
  local -a requested=()

  if [[ -z "${raw//[[:space:],]/}" ]]; then
    printf '%s\n' "${REDIS_ALL_ROLES[@]}"
    return 0
  fi

  for item in ${raw//,/ }; do
    redis_role_prefix "$item" >/dev/null
    requested+=("$item")
  done

  for role in "${REDIS_ALL_ROLES[@]}"; do
    found=0
    for item in "${requested[@]}"; do
      [[ "$item" == "$role" ]] && found=1
    done
    (( found == 1 )) && printf '%s\n' "$role"
  done
  return 0
}

redis_role_enabled() {
  local role="$1" enabled

  while IFS= read -r enabled; do
    [[ "$enabled" == "$role" ]] && return 0
  done < <(redis_enabled_roles)
  return 1
}

redis_flag_enabled() {
  case "${1,,}" in
    1|yes|true|on) return 0 ;;
    ""|0|no|false|off) return 1 ;;
    *) die "expected on/off, got '$1'" ;;
  esac
}

redis_gateway_enabled() { redis_flag_enabled "${REDIS_GATEWAY:-off}"; }
redis_exporter_enabled() { redis_flag_enabled "${REDIS_EXPORTER:-off}"; }

# Names of every password the enabled configuration needs, one per line.
redis_required_password_names() {
  local role

  while IFS= read -r role; do
    printf 'REDIS_%s_PASSWORD\n' "$(redis_role_prefix "$role")"
  done < <(redis_enabled_roles)
  printf 'REDIS_ADMIN_PASSWORD\n'
  if redis_exporter_enabled; then
    printf 'REDIS_EXPORTER_PASSWORD\n'
  fi
}

# Run redis-cli inside a container. The password never appears in argv:
# it is passed to docker through the environment (docker exec -e NAME).
# redis_exec CONTAINER USER PASSWORD [redis-cli args...]
redis_exec() {
  local container="$1" user="$2" password="$3"
  shift 3

  REDISCLI_AUTH="$password" docker exec -e REDISCLI_AUTH "$container" \
    redis-cli --no-auth-warning --user "$user" "$@"
}

# Same as redis_exec, reading redis-cli commands from stdin.
redis_exec_stdin() {
  local container="$1" user="$2" password="$3"
  shift 3

  REDISCLI_AUTH="$password" docker exec -i -e REDISCLI_AUTH "$container" \
    redis-cli --no-auth-warning --user "$user" "$@"
}

# info_field "INFO output" field
redis_info_field() {
  printf '%s\n' "$1" | tr -d '\r' | awk -F: -v k="$2" '$1 == k { print $2; exit }'
}

# Trigger BGSAVE and wait until LASTSAVE moves past its previous value.
# redis_bgsave_and_wait CONTAINER USER PASSWORD [TIMEOUT_SECONDS]
redis_bgsave_and_wait() {
  local container="$1" user="$2" password="$3" timeout="${4:-600}"
  local before now reply status waited=0

  before="$(redis_exec "$container" "$user" "$password" LASTSAVE | tr -d '\r')"
  [[ "$before" =~ ^[0-9]+$ ]] || die "LASTSAVE on $container returned '$before'"

  # LASTSAVE has one-second resolution. Make sure a new save lands in a
  # later second than the previous one, or the wait below cannot see it.
  while [[ "$(date +%s)" -le "$before" ]]; do
    sleep 0.2
  done

  reply="$(redis_exec "$container" "$user" "$password" BGSAVE 2>&1 | tr -d '\r')"
  case "$reply" in
    *"Background saving started"*) ;;
    *"already in progress"*)
      # A save that started before our call may not include our view of the
      # data. Wait for it, then start our own.
      printf 'A background save is already running on %s; waiting for it first\n' "$container" >&2
      while [[ "$(redis_info_field "$(redis_exec "$container" "$user" "$password" INFO persistence)" rdb_bgsave_in_progress)" == "1" ]]; do
        sleep 1
      done
      redis_bgsave_and_wait "$container" "$user" "$password" "$timeout"
      return
      ;;
    *) die "BGSAVE on $container failed: $reply" ;;
  esac

  while :; do
    now="$(redis_exec "$container" "$user" "$password" LASTSAVE | tr -d '\r')"
    if [[ "$now" =~ ^[0-9]+$ ]] && (( now > before )); then
      break
    fi
    (( waited >= timeout )) && die "BGSAVE on $container did not finish within ${timeout}s"
    sleep 1
    waited=$(( waited + 1 ))
  done

  status="$(redis_info_field "$(redis_exec "$container" "$user" "$password" INFO persistence)" rdb_last_bgsave_status)"
  [[ "$status" == "ok" ]] || die "BGSAVE on $container finished with status '$status'"
}

# Refuse paths inside the repository checkout. Data, backups and migration
# runs must live outside it so a git clean or re-clone cannot touch them.
redis_require_outside_checkout() {
  local name="$1" path="$2" resolved repo

  repo="$(cd -- "$repo_dir" && pwd -P)"
  resolved="$(realpath -m -- "$path")"
  case "$resolved/" in
    "$repo"/*) die "$name must be outside the repository checkout ($repo), got $resolved" ;;
  esac
  [[ "$resolved" != "/" ]] || die "$name cannot be /"
}

redis_path_inside_checkout() {
  local path="$1" resolved repo

  repo="$(cd -- "$repo_dir" && pwd -P)"
  resolved="$(realpath -m -- "$path")"
  [[ "$resolved/" == "$repo"/* ]]
}
