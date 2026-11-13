#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Back up Redis roles: BGSAVE, wait for LASTSAVE, copy the RDB (and AOF
directory) out of the container with SHA-256 checksums, verify the RDB with
redis-check-rdb, then apply retention.

Usage:
  scripts/redis-backup.sh [--env-file PATH] [--config-dir PATH] [--role ROLE]...
                          [--dest DIR] [--no-prune] [--prune-dry-run] [--no-verify]

Defaults:
  roles   every enabled role whose persistence is rdb or aof (REDIS_BACKUP_ROLES overrides)
  --prune-dry-run  list what retention would remove; takes no backup
  dest    REDIS_BACKUP_DIR, default /srv/prod-services/backups/redis (must be outside the checkout)
  prune   remove backups older than REDIS_BACKUP_RETENTION_DAYS (default 14), always keeping
          the newest REDIS_BACKUP_KEEP_MIN (default 3) per role. Only directories this script
          created (named YYYYmmddTHHMMSSZ and holding a .redis-backup marker) are ever removed.

Layout:
  <dest>/<role>/<YYYYmmddTHHMMSSZ>/{dump.rdb,appendonlydir/,info.txt,SHA256SUMS,.redis-backup}

Cron example (every 6 hours):
  15 */6 * * * cd /opt/prod-services && make backup-redis >> /var/log/redis-backup.log 2>&1
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
roles=()
dest=""
prune=1
prune_dry_run=0
verify=1

while [[ $# -gt 0 ]]; do
  case "$1" in
    --env-file) env_file="$2"; shift 2 ;;
    --config-dir) config_dir="$2"; shift 2 ;;
    --role) roles+=("$2"); shift 2 ;;
    --dest) dest="$2"; shift 2 ;;
    --no-prune) prune=0; shift ;;
    --prune-dry-run) prune_dry_run=1; shift ;;
    --no-verify) verify=0; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

load_required_env_file "$env_file" "missing env file: $env_file"
load_env_file "$config_dir/compose.env"

dest="${dest:-${REDIS_BACKUP_DIR:-$REDIS_DEFAULT_BACKUP_DIR}}"
redis_require_outside_checkout REDIS_BACKUP_DIR "$dest"
retention_days="$(setting_positive_uint REDIS_BACKUP_RETENTION_DAYS 14)"
keep_min="$(setting_positive_uint REDIS_BACKUP_KEEP_MIN 3)"
image="${REDIS_IMAGE:-$REDIS_DEFAULT_IMAGE}"

if (( ${#roles[@]} == 0 )); then
  if [[ -n "${REDIS_BACKUP_ROLES:-}" ]]; then
    read -r -a roles <<<"${REDIS_BACKUP_ROLES//,/ }"
  else
    while IFS= read -r role; do
      [[ "$(redis_role_persistence "$role")" != none ]] && roles+=("$role")
    done < <(redis_enabled_roles)
  fi
fi
(( ${#roles[@]} > 0 )) || die "no roles to back up (no enabled role has persistence; pass --role)"
for role in "${roles[@]}"; do
  redis_role_enabled "$role" || die "role $role is not enabled in REDIS_ROLES"
done

[[ -d "$dest" ]] || mkdir -p "$dest" 2>/dev/null || die "cannot create $dest. Create it once as root:
  sudo install -d -m 0700 -o $(id -u) -g $(id -g) $dest"
chmod 0700 "$dest" 2>/dev/null || true
[[ -w "$dest" ]] || die "$dest is not writable by uid $(id -u)"

backup_role() {
  local role="$1" container ts dir info aof aofdir project service

  container="$(redis_role_container "$role")"
  read -r project service < <(docker inspect -f '{{index .Config.Labels "com.docker.compose.project"}} {{index .Config.Labels "com.docker.compose.service"}}' "$container" 2>/dev/null) \
    || die "container $container ($role) is not running"
  [[ "$project" == "${COMPOSE_PROJECT_NAME:-redis}" && "$service" == "$(redis_role_service "$role")" ]] \
    || die "$container is project '$project' service '$service', not this stack's $role role"

  ts="$(date -u +%Y%m%dT%H%M%SZ)"
  dir="$dest/$role/$ts"
  [[ ! -e "$dir" ]] || die "backup dir already exists: $dir"
  mkdir -p "$dir"
  chmod 0700 "$dest/$role" "$dir"
  printf '[%s] %s: BGSAVE on %s -> %s\n' "$(date -u +%FT%TZ)" "$role" "$container" "$dir"

  redis_bgsave_and_wait "$container" ops "$REDIS_ADMIN_PASSWORD"

  info="$(redis_exec "$container" ops "$REDIS_ADMIN_PASSWORD" INFO everything | tr -d '\r')"
  {
    printf '# role=%s container=%s project=%s taken=%s\n' "$role" "$container" "$project" "$ts"
    printf '%s\n' "$info" | awk '/^# (Server|Persistence|Keyspace|Memory)$/ {p=1} /^# / && !/^# (Server|Persistence|Keyspace|Memory)$/ {p=0} p'
  } > "$dir/info.txt"

  docker cp -q "$container:/data/dump.rdb" "$dir/dump.rdb"
  aof="$(redis_info_field "$info" aof_enabled)"
  if [[ "$aof" == 1 ]]; then
    aofdir="$(redis_exec "$container" ops "$REDIS_ADMIN_PASSWORD" CONFIG GET appenddirname | tr -d '\r' | sed -n 2p)"
    docker cp -q "$container:/data/${aofdir:-appendonlydir}" "$dir/appendonlydir"
  fi

  local sums
  sums="$(cd "$dir" && find . -type f ! -name SHA256SUMS ! -name .redis-backup -print0 | sort -z | xargs -0 sha256sum)"
  printf '%s\n' "$sums" > "$dir/SHA256SUMS"

  if (( verify == 1 )); then
    docker run --rm --network none -v "$dir:/backup:ro" --entrypoint redis-check-rdb "$image" /backup/dump.rdb >/dev/null \
      || die "redis-check-rdb rejected $dir/dump.rdb"
  fi
  printf 'redis-backup v1\n' > "$dir/.redis-backup"
  chmod -R go-rwx "$dir"
  printf '[%s] %s: ok, %s, keyspace: %s\n' "$(date -u +%FT%TZ)" "$role" \
    "$(du -sh "$dir" | cut -f1)" "$(printf '%s\n' "$info" | awk -F: '/^db[0-9]+:/ {print $1":"$2}' | paste -sd' ' -)"
}

prune_role() {
  local role="$1" role_dir cutoff name kept=0
  local -a candidates=()

  role_dir="$dest/$role"
  [[ -d "$role_dir" ]] || return 0
  cutoff="$(date -u -d "-${retention_days} days" +%Y%m%dT%H%M%SZ)"

  # Newest first; names are UTC timestamps so lexical order is time order.
  while IFS= read -r name; do
    [[ "$name" =~ ^[0-9]{8}T[0-9]{6}Z$ ]] || continue
    [[ -f "$role_dir/$name/.redis-backup" ]] || continue
    kept=$(( kept + 1 ))
    (( kept <= keep_min )) && continue
    [[ "$name" < "$cutoff" ]] && candidates+=("$name")
  done < <(find "$role_dir" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | sort -r)

  for name in "${candidates[@]}"; do
    if (( prune_dry_run == 1 )); then
      printf '%s: would remove expired backup %s\n' "$role" "$role_dir/$name"
    else
      printf '%s: removing expired backup %s\n' "$role" "$role_dir/$name"
      rm -rf -- "${role_dir:?}/${name:?}"
    fi
  done
}

# --prune-dry-run only previews retention; it takes no backup.
if (( prune_dry_run == 0 )); then
  for role in "${roles[@]}"; do
    backup_role "$role"
  done
fi

if (( prune == 1 || prune_dry_run == 1 )); then
  for role in "${roles[@]}"; do
    prune_role "$role"
  done
fi
