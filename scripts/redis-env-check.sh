#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Validate, preview, or prepare Redis service inputs.

Usage:
  scripts/redis-env-check.sh ensure-env [--env-file PATH] [--yes]
  scripts/redis-env-check.sh validate [--env-file PATH]
  scripts/redis-env-check.sh preview [--env-file PATH]
  scripts/redis-env-check.sh check [--env-file PATH]
  scripts/redis-env-check.sh prepare-data-dirs [--env-file PATH]
  scripts/redis-env-check.sh print-allowlist [--env-file PATH]

Only roles listed in REDIS_ROLES need passwords, ports and data dirs.
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
action="${1:-validate}"
# shellcheck disable=SC2034  # read by confirm() in shared/common.sh
assume_yes=0

if [[ $# -gt 0 ]]; then
  shift
fi

while [[ $# -gt 0 ]]; do
  case "$1" in
    --yes)
      assume_yes=1
      shift
      ;;
    --env-file)
      [[ $# -ge 2 ]] || die "--env-file requires a path"
      env_file="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "unknown argument: $1"
      ;;
  esac
done

create_env_file_if_missing() {
  local env_dir example_file

  [[ -f "$env_file" ]] && return 0

  example_file="$redis_dir/.env.example"
  [[ -f "$example_file" ]] || die "missing env example: $example_file"

  if ! confirm "Missing $env_file. Create it from $example_file and generate missing passwords?"; then
    die "missing env file: $env_file. Copy $example_file to $env_file or rerun with --yes."
  fi

  env_dir="$(dirname -- "$env_file")"
  mkdir -p "$env_dir"
  cp "$example_file" "$env_file"
  chmod 0600 "$env_file"
  printf 'Created %s from %s\n' "$env_file" "$example_file"
}

ensure_passwords() {
  local missing name password value

  missing=()
  # Role selection and exporter flag decide which passwords are needed.
  REDIS_ROLES="$(env_file_value REDIS_ROLES)"
  REDIS_EXPORTER="$(env_file_value REDIS_EXPORTER)"

  while IFS= read -r name; do
    value="$(env_file_value "$name")"
    [[ -n "$value" ]] || missing+=("$name")
  done < <(redis_required_password_names)

  (( ${#missing[@]} == 0 )) && return 0

  if ! confirm "Missing Redis password values in $env_file: ${missing[*]}. Generate random passwords now?"; then
    die "Redis passwords are required in $env_file"
  fi

  for name in "${missing[@]}"; do
    password="$(generate_secret)"
    set_env_file_value "$name" "$password"
    printf 'Generated %s in %s\n' "$name" "$env_file"
  done
}

ensure_env_file() {
  create_env_file_if_missing
  ensure_passwords
  chmod 0600 "$env_file"
}

require_password() {
  local name="$1"
  local value="${!name:-}"
  local next="${name}_NEXT"

  require_non_empty "$name" "$value"
  [[ ! "$value" =~ [[:space:]#] ]] || die "$name cannot contain whitespace or #"
  (( ${#value} >= 32 )) || die "$name must be at least 32 characters"
  if [[ -n "${!next:-}" ]]; then
    local next_value="${!next}"
    [[ ! "$next_value" =~ [[:space:]#] ]] || die "$next cannot contain whitespace or #"
    [[ "$next_value" != "$value" ]] || die "$next must differ from $name"
    (( ${#next_value} >= 32 )) || die "$next must be at least 32 characters"
  fi
}

validate_port() {
  local name="$1" value

  value="$(env_value "$name" "$2")"
  require_uint "$name" "$value"
  (( value >= 1 && value <= 65535 )) || die "$name must be between 1 and 65535"
  printf '%s\n' "$value"
}

validate_ip() {
  local name="$1" value="$2"

  [[ "$value" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ || "$value" =~ ^[0-9a-fA-F:]+$ ]] \
    || die "$name must be an IPv4 or IPv6 address, got '$value'"
}

validate_role() {
  local role="$1" prefix persistence policy data_dir

  prefix="$(redis_role_prefix "$role")"
  require_non_empty "REDIS_${prefix}_CONTAINER_NAME" "$(redis_role_container "$role")"
  require_password "REDIS_${prefix}_PASSWORD"

  persistence="$(redis_role_persistence "$role")"
  case "$persistence" in
    none|rdb|aof) ;;
    *) die "REDIS_${prefix}_PERSISTENCE must be none, rdb or aof, got '$persistence'" ;;
  esac

  policy="$(redis_role_policy "$role")"
  case "$policy" in
    noeviction|allkeys-lru|allkeys-lfu|allkeys-random|volatile-lru|volatile-lfu|volatile-random|volatile-ttl) ;;
    *) die "REDIS_${prefix}_MAXMEMORY_POLICY is not a Redis eviction policy: '$policy'" ;;
  esac
  if [[ "$role" == queue && "$policy" != noeviction ]]; then
    printf 'warning: queue role uses %s; jobs can be evicted. noeviction is strongly recommended.\n' "$policy" >&2
  fi
  if [[ "$role" == queue && "$persistence" != aof ]]; then
    printf 'warning: queue role persistence is %s; jobs written since the last snapshot are lost on crash.\n' "$persistence" >&2
  fi

  data_dir="$(redis_role_data_dir "$role")"
  require_non_empty "REDIS_${prefix}_DATA_DIR" "$data_dir"
  [[ "$data_dir" != "/" ]] || die "REDIS_${prefix}_DATA_DIR cannot be /"

  host_ports+=("$(validate_port "REDIS_${prefix}_HOST_PORT" "$(redis_role_default "$role" host_port)")")
  if redis_gateway_enabled; then
    host_ports+=("$(validate_port "REDIS_GATEWAY_${prefix}_PORT" "$(redis_role_default "$role" gateway_port)")")
  fi
  if redis_exporter_enabled; then
    host_ports+=("$(validate_port "REDIS_${prefix}_EXPORTER_PORT" "$(redis_role_default "$role" exporter_port)")")
  fi

  validate_optional_positive_uint "REDIS_${prefix}_MAXMEMORY_MB"
  validate_optional_positive_uint "REDIS_${prefix}_MEM_LIMIT_MB"
}

validate_env() {
  local role
  host_ports=()

  require_non_empty REDIS_IMAGE "$(env_value REDIS_IMAGE "$REDIS_DEFAULT_IMAGE")"
  case "$(env_value REDIS_IMAGE "$REDIS_DEFAULT_IMAGE")" in
    *:latest|*:alpine|redis) die "REDIS_IMAGE must pin a version, for example $REDIS_DEFAULT_IMAGE" ;;
  esac
  validate_ip REDIS_BIND_ADDRESS "$(env_value REDIS_BIND_ADDRESS 127.0.0.1)"

  mapfile -t enabled_roles < <(redis_enabled_roles)
  (( ${#enabled_roles[@]} > 0 )) || die "REDIS_ROLES selects no roles"

  # Admin user: backups, ACL LOAD, status, migrations.
  require_password REDIS_ADMIN_PASSWORD
  redis_flag_enabled "${REDIS_GATEWAY:-off}" || true
  redis_flag_enabled "${REDIS_EXPORTER:-off}" || true

  if redis_exporter_enabled; then
    require_password REDIS_EXPORTER_PASSWORD
    validate_ip REDIS_EXPORTER_BIND_ADDRESS "$(env_value REDIS_EXPORTER_BIND_ADDRESS 127.0.0.1)"
  fi

  if redis_gateway_enabled; then
    validate_ip REDIS_GATEWAY_BIND_ADDRESS "$(env_value REDIS_GATEWAY_BIND_ADDRESS 0.0.0.0)"
    host_ports+=("$(validate_port REDIS_GATEWAY_METRICS_PORT 8405)")
    validate_optional_positive_uint REDIS_GATEWAY_MAXCONN
    validate_duration_value REDIS_GATEWAY_HARD_STOP_AFTER "$(env_value REDIS_GATEWAY_HARD_STOP_AFTER 1h)"
    print_allowlist >/dev/null
  fi

  for role in "${enabled_roles[@]}"; do
    validate_role "$role"
  done

  local duplicates
  duplicates="$(printf '%s\n' "${host_ports[@]}" | sort | uniq -d | tr '\n' ' ')"
  [[ -z "$duplicates" ]] || die "host port(s) used more than once: $duplicates"

  validate_duration_value REDIS_STOP_GRACE_PERIOD "$(env_value REDIS_STOP_GRACE_PERIOD 30s)"
  validate_size_value REDIS_LOG_MAX_SIZE "$(env_value REDIS_LOG_MAX_SIZE 100m)"
  require_positive_uint REDIS_LOG_MAX_FILE "$(env_value REDIS_LOG_MAX_FILE 5)"
  require_positive_uint REDIS_PIDS_LIMIT "$(env_value REDIS_PIDS_LIMIT 4096)"
  require_positive_uint REDIS_BACKUP_RETENTION_DAYS "$(env_value REDIS_BACKUP_RETENTION_DAYS 14)"

  validate_optional_positive_uint REDIS_MEMORY_MB
  validate_optional_positive_uint REDIS_CPU_CORES
  validate_optional_positive_uint REDIS_HOST_MEMORY_RESERVE_PERCENT
  validate_optional_positive_uint REDIS_MEMORY_BUDGET_PERCENT
  validate_optional_positive_uint REDIS_CONTAINER_MEMORY_OVERHEAD_PERCENT
  validate_optional_positive_uint REDIS_PERSISTENT_CONTAINER_MEMORY_OVERHEAD_PERCENT
  validate_optional_positive_uint REDIS_QUEUE_CONTAINER_MEMORY_OVERHEAD_PERCENT
}

# Validated allowlist entries, one per line. Comments and blank lines dropped.
print_allowlist() {
  local file line entry ip bits lineno=0

  file="$(resolve_path_relative_to "$redis_dir" "${REDIS_GATEWAY_ALLOWLIST_FILE:-./gateway.allowlist}")"
  [[ -f "$file" ]] || die "REDIS_GATEWAY=on but the allowlist file is missing: $file (copy redis/gateway.allowlist.example)"

  while IFS= read -r line || [[ -n "$line" ]]; do
    lineno=$(( lineno + 1 ))
    entry="${line%%#*}"
    entry="${entry//[[:space:]]/}"
    [[ -n "$entry" ]] || continue

    ip="${entry%%/*}"
    bits=""
    [[ "$entry" == */* ]] && bits="${entry#*/}"

    if [[ "$ip" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]]; then
      local octet
      for octet in "${BASH_REMATCH[@]:1}"; do
        (( 10#$octet <= 255 )) || die "$file:$lineno: invalid IPv4 address '$entry'"
      done
      if [[ -n "$bits" ]]; then
        { [[ "$bits" =~ ^[0-9]+$ ]] && (( bits <= 32 )); } || die "$file:$lineno: invalid IPv4 prefix '$entry'"
        (( bits >= 8 )) || die "$file:$lineno: '$entry' is wider than /8; list the networks that need access"
      fi
    elif [[ "$ip" =~ ^[0-9a-fA-F:]+$ && "$ip" == *:* ]]; then
      if [[ -n "$bits" ]]; then
        { [[ "$bits" =~ ^[0-9]+$ ]] && (( bits <= 128 )); } || die "$file:$lineno: invalid IPv6 prefix '$entry'"
        (( bits >= 16 )) || die "$file:$lineno: '$entry' is wider than /16; list the networks that need access"
      fi
    else
      die "$file:$lineno: expected one IPv4/IPv6 address or CIDR per line, got '$entry'"
    fi
    printf '%s\n' "$entry"
  done < "$file"
}

preview_env() {
  local role prefix dir

  printf 'Redis .env preview:\n'
  printf '  REDIS_IMAGE=%s\n' "$(env_value REDIS_IMAGE "$REDIS_DEFAULT_IMAGE")"
  printf '  REDIS_ROLES=%s\n' "$(redis_enabled_roles | paste -sd, -)"
  printf '  REDIS_COMPOSE_PROJECT_NAME=%s\n' "$(env_value REDIS_COMPOSE_PROJECT_NAME redis)"
  printf '  REDIS_NETWORK_NAME=%s\n' "$(env_value REDIS_NETWORK_NAME redis_default)"
  printf '  REDIS_BIND_ADDRESS=%s\n' "$(env_value REDIS_BIND_ADDRESS 127.0.0.1)"
  while IFS= read -r role; do
    prefix="$(redis_role_prefix "$role")"
    dir="$(resolve_path_relative_to "$redis_dir" "$(redis_role_data_dir "$role")")"
    printf '  %-8s container=%s port=%s persistence=%s policy=%s data=%s\n' "$role" \
      "$(redis_role_container "$role")" \
      "$(env_value "REDIS_${prefix}_HOST_PORT" "$(redis_role_default "$role" host_port)")" \
      "$(redis_role_persistence "$role")" "$(redis_role_policy "$role")" "$dir"
    if redis_path_inside_checkout "$dir"; then
      printf '    warning: data dir is inside the repository checkout; prefer %s\n' "$(redis_role_default "$role" data_dir)"
    fi
    if [[ -n "$(env_value "REDIS_${prefix}_PASSWORD_NEXT" "")" ]]; then
      printf '    password rotation in progress: REDIS_%s_PASSWORD_NEXT is set\n' "$prefix"
    fi
  done < <(redis_enabled_roles)
  if redis_gateway_enabled; then
    printf '  REDIS_GATEWAY=on bind=%s allowlist=%s (%s entries)\n' \
      "$(env_value REDIS_GATEWAY_BIND_ADDRESS 0.0.0.0)" \
      "$(resolve_path_relative_to "$redis_dir" "${REDIS_GATEWAY_ALLOWLIST_FILE:-./gateway.allowlist}")" \
      "$(print_allowlist | grep -c . || true)"
  else
    printf '  REDIS_GATEWAY=off\n'
  fi
  if redis_exporter_enabled; then
    printf '  REDIS_EXPORTER=on bind=%s\n' "$(env_value REDIS_EXPORTER_BIND_ADDRESS 127.0.0.1)"
  else
    printf '  REDIS_EXPORTER=off\n'
  fi
  printf '  REDIS_BACKUP_DIR=%s retention=%sd\n' "$(env_value REDIS_BACKUP_DIR "$REDIS_DEFAULT_BACKUP_DIR")" "$(env_value REDIS_BACKUP_RETENTION_DAYS 14)"
  printf '  REDIS_MEMORY_MB=%s\n' "$(env_value REDIS_MEMORY_MB auto)"
  printf '  REDIS_CPU_CORES=%s\n' "$(env_value REDIS_CPU_CORES auto)"
  printf '  REDIS_HOST_MEMORY_RESERVE_PERCENT=%s\n' "$(env_value REDIS_HOST_MEMORY_RESERVE_PERCENT 10)"
  printf '  REDIS_MEMORY_BUDGET_PERCENT=%s\n' "$(env_value REDIS_MEMORY_BUDGET_PERCENT 70)"
  printf '  REDIS_STOP_GRACE_PERIOD=%s\n' "$(env_value REDIS_STOP_GRACE_PERIOD 30s)"
  printf '  REDIS_LOG_MAX_SIZE=%s\n' "$(env_value REDIS_LOG_MAX_SIZE 100m)"
  printf '  REDIS_LOG_MAX_FILE=%s\n' "$(env_value REDIS_LOG_MAX_FILE 5)"
  printf '  REDIS_PIDS_LIMIT=%s\n' "$(env_value REDIS_PIDS_LIMIT 4096)"
}

prepare_one_data_dir() {
  local role="$1" resolved_dir owner

  resolved_dir="$(resolve_path_relative_to "$redis_dir" "$(redis_role_data_dir "$role")")"

  if [[ -e "$resolved_dir" && ! -d "$resolved_dir" ]]; then
    die "data dir for $role exists but is not a directory: $resolved_dir"
  fi

  if [[ ! -d "$resolved_dir" ]]; then
    if ! mkdir -p "$resolved_dir" 2>/dev/null; then
      die "cannot create $resolved_dir. Create it once as root:
  sudo install -d -m 0700 -o 999 -g 999 $resolved_dir"
    fi
    # Snapshots hold application data (sessions, jobs): no world access.
    chmod 0700 "$resolved_dir"
  fi

  owner="$(stat -c %u "$resolved_dir")"
  if [[ "$owner" != 999 ]]; then
    if (( EUID == 0 )); then
      chown 999:999 "$resolved_dir"
      chmod 0700 "$resolved_dir"
      owner=999
    else
      # The official image's entrypoint chowns /data to redis (uid 999) when it
      # starts as root, so this is only informational.
      printf 'note: %s is owned by uid %s; the Redis entrypoint will chown it to 999 on start\n' "$resolved_dir" "$owner"
    fi
  fi
  printf 'Redis %s data directory is ready: %s (owner uid %s)\n' "$role" "$resolved_dir" "$owner"
}

prepare_data_dirs() {
  local role

  while IFS= read -r role; do
    prepare_one_data_dir "$role"
  done < <(redis_enabled_roles)
}

load_env() {
  load_required_env_file "$env_file" "missing env file: $env_file. Copy redis/.env.example to redis/.env first."
}

case "$action" in
  ensure-env)
    ensure_env_file
    printf 'Redis .env is ready: %s\n' "$env_file"
    ;;
  validate)
    load_env
    validate_env
    printf 'Redis .env is valid: %s\n' "$env_file"
    ;;
  preview)
    load_env
    preview_env
    ;;
  check)
    load_env
    validate_env
    printf 'Redis .env is valid: %s\n' "$env_file"
    preview_env
    ;;
  prepare-data-dirs)
    load_env
    validate_env
    prepare_data_dirs
    ;;
  print-allowlist)
    load_env
    print_allowlist
    ;;
  -h|--help)
    usage
    ;;
  *)
    die "unknown action: $action"
    ;;
esac
