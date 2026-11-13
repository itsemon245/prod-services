#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Copy keys from legacy Redis containers (one instance, several logical DBs)
into prod-services role instances (one role per instance, databases 1),
without modifying the source.

Usage:
  scripts/migrate-redis-legacy.sh --map SRC_CONTAINER:SRC_DB=ROLE [--map ...] [mode] [options]

Modes (default --dry-run):
  --dry-run        Resolve and assert containers, volumes, dirs and auth; check that
                   writers are quiet; print the plan. Changes nothing anywhere.
  --execute        Back up every source (BGSAVE + RDB/AOF copy + checksums + INFO),
                   check writers are quiet, copy keys with MIGRATE COPY REPLACE in
                   batches, verify, write report.md.
  --verify-only    Re-run verification for an earlier run (needs --run-dir).
  --reset-target   Empty the mapped target roles so a migration can be re-run after a
                   rollback. Backs each target up first. Needs --execute and
                   --confirm-reset CONTAINER for every target being emptied.
  --decommission   Final step: docker update --restart=no on every source container so
                   it cannot take its ports back after a reboot. Needs --execute.
                   Never stops, removes or edits containers or volumes.

Options:
  --env-file PATH        prod-services redis env (default redis/.env)
  --config-dir PATH      generated config dir (default redis/redis_config)
  --run-dir DIR          where backups, key lists and reports go
                         (default $REDIS_BACKUP_DIR/migrations/<UTC timestamp>, outside the checkout)
  --batch-size N         keys per MIGRATE (default 500)
  --timeout-ms N         MIGRATE timeout (default 30000)
  --quiesce-seconds N    how long to watch sources for writers (default 10)
  --force-live           continue even if writers look active (data written after the
                         copy will be missing from the targets)
  --sample N             keys per mapping whose content is compared (default 500)
  --yes                  do not ask for the typed confirmation

Source credentials (never on the command line):
  SRC_AUTH_<CONTAINER>   password for that source container; the container name is
                         upper-cased with non-alphanumerics replaced by _ (redis_app ->
                         SRC_AUTH_REDIS_APP). Falls back to SRC_AUTH.
  SRC_USER               ACL user on the sources (default: default)
Target credentials come from the env file: REDIS_<ROLE>_PASSWORD (app user, used by
MIGRATE AUTH2) and REDIS_ADMIN_PASSWORD (ops user, used for checks and backups).

Rollback: the source is never written to. Point clients back at it. To migrate again,
--reset-target the targets, then --execute.
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
mode=dry-run
execute=0
maps=()
run_dir=""
batch_size=500
timeout_ms=30000
quiesce_seconds=10
force_live=0
sample_size=500
assume_yes=0
confirm_resets=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --map) maps+=("$2"); shift 2 ;;
    --dry-run) mode=dry-run; shift ;;
    --execute) execute=1; [[ "$mode" == dry-run ]] && mode=execute; shift ;;
    --verify-only) mode=verify-only; shift ;;
    --reset-target) mode=reset-target; shift ;;
    --decommission) mode=decommission; shift ;;
    --confirm-reset) confirm_resets+=("$2"); shift 2 ;;
    --env-file) env_file="$2"; shift 2 ;;
    --config-dir) config_dir="$2"; shift 2 ;;
    --run-dir) run_dir="$2"; shift 2 ;;
    --batch-size) batch_size="$2"; shift 2 ;;
    --timeout-ms) timeout_ms="$2"; shift 2 ;;
    --quiesce-seconds) quiesce_seconds="$2"; shift 2 ;;
    --force-live) force_live=1; shift ;;
    --sample) sample_size="$2"; shift 2 ;;
    --yes) assume_yes=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument: $1 (see --help)" ;;
  esac
done

require_positive_uint --batch-size "$batch_size"
require_positive_uint --timeout-ms "$timeout_ms"
require_uint --quiesce-seconds "$quiesce_seconds"
require_uint --sample "$sample_size"
(( ${#maps[@]} > 0 )) || die "at least one --map SRC_CONTAINER:SRC_DB=ROLE is required"
if [[ "$mode" == reset-target || "$mode" == decommission ]] && (( execute == 0 )); then
  printf 'note: --%s without --execute only prints what it would do\n' "$mode"
fi

load_required_env_file "$env_file" "missing env file: $env_file"
load_env_file "$config_dir/compose.env"
project="${COMPOSE_PROJECT_NAME:-${REDIS_COMPOSE_PROJECT_NAME:-redis}}"
src_user="${SRC_USER:-default}"

if [[ -z "$run_dir" ]]; then
  [[ "$mode" == verify-only ]] && die "--verify-only needs --run-dir of the run to verify"
  run_dir="${REDIS_BACKUP_DIR:-$REDIS_DEFAULT_BACKUP_DIR}/migrations/$(date -u +%Y%m%dT%H%M%SZ)"
fi
redis_require_outside_checkout --run-dir "$run_dir"

section() { printf '\n== %s\n' "$*"; }
ts() { date -u +%FT%TZ; }

# ---------------------------------------------------------------- mappings
declare -a m_src=() m_db=() m_role=()
declare -A seen_target=() seen_source_db=()
for spec in "${maps[@]}"; do
  [[ "$spec" =~ ^([A-Za-z0-9][A-Za-z0-9_.-]*):([0-9]+)=([a-z]+)$ ]] \
    || die "bad --map '$spec'; expected SRC_CONTAINER:SRC_DB=ROLE, e.g. redis_app:1=cache"
  src="${BASH_REMATCH[1]}" db="${BASH_REMATCH[2]}" role="${BASH_REMATCH[3]}"
  redis_role_prefix "$role" >/dev/null
  redis_role_enabled "$role" || die "role $role is not enabled in REDIS_ROLES of $env_file"
  [[ -z "${seen_target[$role]:-}" ]] || die "role $role is mapped twice; one source DB per target"
  [[ -z "${seen_source_db[$src:$db]:-}" ]] || die "$src:$db is mapped twice"
  seen_target[$role]=1
  seen_source_db[$src:$db]=1
  m_src+=("$src") m_db+=("$db") m_role+=("$role")
done
mapfile -t sources < <(printf '%s\n' "${m_src[@]}" | awk '!seen[$0]++')

src_password() {
  local container="$1" name
  name="SRC_AUTH_$(printf '%s' "$container" | tr '[:lower:]' '[:upper:]' | tr -c 'A-Z0-9' '_')"
  if [[ -n "${!name:-}" ]]; then
    printf '%s\n' "${!name}"
  elif [[ -n "${SRC_AUTH:-}" ]]; then
    printf '%s\n' "$SRC_AUTH"
  else
    die "no password for source $container: export $name (or SRC_AUTH), e.g. read -rs $name; export $name"
  fi
}

src_cli() { local c="$1"; shift; redis_exec "$c" "$src_user" "$(src_password "$c")" "$@"; }
src_cli_stdin() { local c="$1"; shift; redis_exec_stdin "$c" "$src_user" "$(src_password "$c")" "$@"; }
tgt_cli() { local c="$1"; shift; redis_exec "$c" ops "$REDIS_ADMIN_PASSWORD" "$@"; }
tgt_cli_stdin() { local c="$1"; shift; redis_exec_stdin "$c" ops "$REDIS_ADMIN_PASSWORD" "$@"; }
target_container() { redis_role_container "$1"; }
app_password() { local n; n="REDIS_$(redis_role_prefix "$1")_PASSWORD"; printf '%s\n' "${!n}"; }

mounts_of() {
  docker inspect -f '{{range .Mounts}}{{.Type}}:{{if .Name}}{{.Name}}{{else}}{{.Source}}{{end}}->{{.Destination}} {{end}}' "$1"
}

# ---------------------------------------------------------------- resolve + assert
declare -A src_info=() tgt_ok=()

resolve_source() {
  local c="$1" state proj image restart databases ping
  docker inspect "$c" >/dev/null 2>&1 || die "source container $c does not exist"
  read -r state proj image restart < <(docker inspect -f '{{.State.Status}} {{or (index .Config.Labels "com.docker.compose.project") "-"}} {{.Config.Image}} {{.HostConfig.RestartPolicy.Name}}' "$c")
  [[ "$state" == running ]] || die "source $c is $state, not running"
  [[ "$proj" != "$project" ]] || die "source $c belongs to this stack's compose project '$project'; refusing (source and target must differ)"
  ping="$(src_cli "$c" PING 2>&1 | tr -d '\r')"
  [[ "$ping" == PONG ]] || die "cannot authenticate to source $c as $src_user: $ping"
  databases="$(src_cli "$c" CONFIG GET databases | tr -d '\r' | sed -n 2p)"
  src_info[$c]="$databases"
  printf 'source %-24s id=%s image=%s project=%s restart=%s databases=%s\n' "$c" \
    "$(docker inspect -f '{{.Id}}' "$c" | cut -c1-12)" "$image" "$proj" "$restart" "$databases"
  printf '       mounts: %s\n' "$(mounts_of "$c")"
  printf '       keyspace: %s\n' "$(src_cli "$c" INFO keyspace | tr -d '\r' | grep '^db' | paste -sd' ' -)"
  printf '       memory: used=%s maxmemory=%s policy=%s aof=%s\n' \
    "$(redis_info_field "$(src_cli "$c" INFO memory)" used_memory_human)" \
    "$(src_cli "$c" CONFIG GET maxmemory | tr -d '\r' | sed -n 2p)" \
    "$(src_cli "$c" CONFIG GET maxmemory-policy | tr -d '\r' | sed -n 2p)" \
    "$(src_cli "$c" CONFIG GET appendonly | tr -d '\r' | sed -n 2p)"
}

resolve_target() {
  local role="$1" c proj service state dbs size ping datadir
  c="$(target_container "$role")"
  docker inspect "$c" >/dev/null 2>&1 || die "target container $c ($role) does not exist; run make serve redis first"
  read -r state proj service < <(docker inspect -f '{{.State.Status}} {{index .Config.Labels "com.docker.compose.project"}} {{index .Config.Labels "com.docker.compose.service"}}' "$c")
  [[ "$state" == running ]] || die "target $c is $state"
  [[ "$proj" == "$project" && "$service" == "$(redis_role_service "$role")" ]] \
    || die "target $c is project '$proj' service '$service', expected '$project' '$(redis_role_service "$role")'"
  for s in "${sources[@]}"; do
    [[ "$(docker inspect -f '{{.Id}}' "$s")" != "$(docker inspect -f '{{.Id}}' "$c")" ]] || die "source and target are the same container: $c"
  done
  ping="$(redis_exec "$c" default "$(app_password "$role")" PING 2>&1 | tr -d '\r')"
  [[ "$ping" == PONG ]] || die "target $c: app password REDIS_$(redis_role_prefix "$role")_PASSWORD does not authenticate: $ping"
  [[ "$(app_password "$role")" != *[\"\\]* ]] || die "REDIS_$(redis_role_prefix "$role")_PASSWORD must not contain quotes or backslashes"
  dbs="$(tgt_cli "$c" CONFIG GET databases | tr -d '\r' | sed -n 2p)"
  [[ "$dbs" == 1 ]] || die "target $c has databases $dbs; prod-services roles must have databases 1"
  size="$(tgt_cli "$c" DBSIZE | tr -d '\r')"
  datadir="$(docker inspect -f '{{range .Mounts}}{{if eq .Destination "/data"}}{{.Source}}{{end}}{{end}}' "$c")"
  for s in "${sources[@]}"; do
    docker inspect -f '{{range .Mounts}}{{.Source}}{{"\n"}}{{end}}' "$s" | grep -qxF "$datadir" \
      && die "target $c data dir $datadir is also mounted by source $s"
  done
  printf 'target %-24s role=%s project=%s persistence=%s policy=%s maxmemory=%s dbsize=%s\n' "$c" "$role" "$proj" \
    "$(redis_role_persistence "$role")" \
    "$(tgt_cli "$c" CONFIG GET maxmemory-policy | tr -d '\r' | sed -n 2p)" \
    "$(tgt_cli "$c" CONFIG GET maxmemory | tr -d '\r' | sed -n 2p)" "$size"
  printf '       data dir: %s\n' "$datadir"
  tgt_ok[$role]="$size"
}

# ---------------------------------------------------------------- writer check
client_activity() {
  # Clients other than ourselves that ran something within the window.
  local c="$1" window="$2"
  src_cli "$c" CLIENT LIST | tr -d '\r' | awk -v w="$window" '
    { cmd=""; idle=""; addr=""; name=""
      for (i=1;i<=NF;i++) { split($i,kv,"="); if (kv[1]=="cmd") cmd=kv[2]; if (kv[1]=="idle") idle=kv[2]; if (kv[1]=="addr") addr=kv[2]; if (kv[1]=="name") name=kv[2] } }
    cmd=="client|list" { next }
    { printf "%s name=%s cmd=%s idle=%ss%s\n", addr, name, cmd, idle, (idle+0 <= w ? "  <- active" : "") }'
}

# Returns 0 when the source looks quiet: rdb_changes_since_last_save did not
# move over the window, and no other client ran a command in it.
check_quiet() {
  local c="$1" i1 i2 d1 d2 e1 e2 v1 v2 s1 s2 writes active clients
  i1="$(src_cli "$c" INFO everything | tr -d '\r')"
  sleep "$quiesce_seconds"
  i2="$(src_cli "$c" INFO everything | tr -d '\r')"
  d1="$(redis_info_field "$i1" rdb_changes_since_last_save)"; d2="$(redis_info_field "$i2" rdb_changes_since_last_save)"
  e1="$(redis_info_field "$i1" expired_keys)"; e2="$(redis_info_field "$i2" expired_keys)"
  v1="$(redis_info_field "$i1" evicted_keys)"; v2="$(redis_info_field "$i2" evicted_keys)"
  s1="$(redis_info_field "$i1" rdb_last_save_time)"; s2="$(redis_info_field "$i2" rdb_last_save_time)"
  clients="$(client_activity "$c" "$quiesce_seconds")"
  active="$(printf '%s\n' "$clients" | grep -c 'active$' || true)"
  if [[ "$s1" != "$s2" ]]; then
    writes="unknown (a snapshot ran during the window)"
  else
    # Active expiry does not count as a change (checked on 8.0.1), so the
    # change counter only moves when a client writes.
    writes="$(( d2 - d1 ))"
  fi
  printf 'source %s over %ss: writes=%s (expired %s, evicted %s), clients:\n' "$c" "$quiesce_seconds" \
    "$writes" "$(( e2 - e1 ))" "$(( v2 - v1 ))"
  if [[ -n "$clients" ]]; then printf '  %s\n' "$clients"; else printf '  (none besides this script)\n'; fi
  [[ "$writes" == 0 && "$active" == 0 ]]
}

writers_gate() {
  local c quiet=1
  section "Writer check ($(ts))"
  for c in "${sources[@]}"; do
    check_quiet "$c" || quiet=0
  done
  if (( quiet == 0 )); then
    if (( force_live == 1 )); then
      printf 'WARNING: writers look active; continuing because of --force-live. Keys written after the copy will be missing.\n'
    elif [[ "$mode" == dry-run ]]; then
      printf 'Writers look active. Pause them before --execute (see docs), or pass --force-live.\n'
    else
      die "writers look active on a source; pause them (queue workers, scheduler, web via maintenance mode) and retry, or pass --force-live"
    fi
  else
    printf 'All sources quiet.\n'
  fi
}

# ---------------------------------------------------------------- backup
backup_source() {
  local c="$1" dir image aof aofdir dbfile
  dir="$run_dir/backup/$c"
  mkdir -p "$dir"
  chmod 0700 "$run_dir/backup" "$dir"
  printf '[%s] backup %s -> %s\n' "$(ts)" "$c" "$dir"
  redis_bgsave_and_wait "$c" "$src_user" "$(src_password "$c")"
  src_cli "$c" INFO everything | tr -d '\r' > "$dir/info.txt"
  src_cli "$c" INFO keyspace | tr -d '\r' > "$dir/keyspace.txt"
  # Container metadata without Env/Cmd, which may hold passwords.
  docker inspect -f 'name={{.Name}} id={{.Id}} image={{.Config.Image}} restart={{.HostConfig.RestartPolicy.Name}}{{"\n"}}mounts={{range .Mounts}}{{.Type}}:{{if .Name}}{{.Name}}{{else}}{{.Source}}{{end}}->{{.Destination}} {{end}}{{"\n"}}ports={{range $p, $b := .NetworkSettings.Ports}}{{$p}}={{range $b}}{{.HostIp}}:{{.HostPort}} {{end}}{{end}}' "$c" > "$dir/container.txt"
  dbfile="$(src_cli "$c" CONFIG GET dbfilename | tr -d '\r' | sed -n 2p)"
  docker cp -q "$c:$(src_cli "$c" CONFIG GET dir | tr -d '\r' | sed -n 2p)/${dbfile:-dump.rdb}" "$dir/dump.rdb"
  aof="$(src_cli "$c" CONFIG GET appendonly | tr -d '\r' | sed -n 2p)"
  if [[ "$aof" == yes ]]; then
    aofdir="$(src_cli "$c" CONFIG GET appenddirname | tr -d '\r' | sed -n 2p)"
    docker cp -q "$c:$(src_cli "$c" CONFIG GET dir | tr -d '\r' | sed -n 2p)/${aofdir:-appendonlydir}" "$dir/appendonlydir"
  fi
  image="$(docker inspect -f '{{.Config.Image}}' "$c")"
  docker run --rm --network none -v "$dir:/backup:ro" --entrypoint redis-check-rdb "$image" /backup/dump.rdb >/dev/null \
    || die "redis-check-rdb rejected the backup of $c"
  local sums
  sums="$(cd "$dir" && find . -type f ! -name SHA256SUMS -print0 | sort -z | xargs -0 sha256sum)"
  printf '%s\n' "$sums" > "$dir/SHA256SUMS"
  chmod -R go-rwx "$dir"
  printf '[%s] backup %s ok (%s): %s\n' "$(ts)" "$c" "$(du -sh "$dir" | cut -f1)" "$(paste -sd' ' "$dir/keyspace.txt" | tr -s ' ')"
}

# ---------------------------------------------------------------- network
declare -a connected_nets=()
cleanup_networks() {
  local entry net c
  for entry in "${connected_nets[@]}"; do
    net="${entry%%|*}" c="${entry#*|}"
    docker network disconnect "$net" "$c" >/dev/null 2>&1 \
      && printf '[%s] detached target %s from network %s\n' "$(ts)" "$c" "$net"
  done
}

# Attach the target (never the source) to the source's network and set
# target_ip to the target's IP there, so the source's MIGRATE can reach it.
# Not called in a subshell: connected_nets must survive for cleanup.
target_ip=""
attach_target_to_source_net() {
  local src="$1" tgt="$2" net
  net="$(docker inspect -f '{{range $n, $_ := .NetworkSettings.Networks}}{{$n}}{{"\n"}}{{end}}' "$src" | sed -n 1p)"
  [[ -n "$net" && "$net" != host && "$net" != none ]] || die "source $src has no usable bridge network ('$net')"
  target_ip="$(docker inspect -f "{{with index .NetworkSettings.Networks \"$net\"}}{{.IPAddress}}{{end}}" "$tgt")"
  if [[ -z "$target_ip" ]]; then
    docker network connect "$net" "$tgt"
    connected_nets+=("$net|$tgt")
    target_ip="$(docker inspect -f "{{with index .NetworkSettings.Networks \"$net\"}}{{.IPAddress}}{{end}}" "$tgt")"
    printf '[%s] attached target %s to source network %s as %s\n' "$(ts)" "$tgt" "$net" "$target_ip"
  fi
  [[ -n "$target_ip" ]] || die "could not get an IP for $tgt on $net"
}

# ---------------------------------------------------------------- copy
quote_keys() {
  # redis-cli parses stdin lines like the shell: quote each key, escaping \ and ".
  LC_ALL=C sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' -e 's/^/"/' -e 's/$/"/'
}

scan_keys() {
  local src="$1" db="$2" out="$3" before lines
  before="$(src_cli "$src" -n "$db" DBSIZE | tr -d '\r')"
  src_cli "$src" -n "$db" --scan --count 1000 | LC_ALL=C sort -u > "$out"
  lines="$(wc -l < "$out")"
  printf '[%s] scanned %s db%s: %s keys (DBSIZE before scan: %s)\n' "$(ts)" "$src" "$db" "$lines" "$before"
  # SCAN may repeat keys (deduped above); with writers paused it cannot return
  # more keys than existed. More lines means writes or keys containing newlines.
  (( lines <= before )) || die "scan of $src db$db returned more keys ($lines) than DBSIZE ($before): writers active, or key names contain newlines"
}

copy_mapping() {
  local i="$1" src="${m_src[$1]}" db="${m_db[$1]}" role="${m_role[$1]}" tgt keys ip out started bad ok nokey
  tgt="$(target_container "$role")"
  keys="$run_dir/keys/$src-db$db.txt"
  out="$run_dir/logs/migrate-$src-db$db.out"
  section "Copy $src db$db -> $tgt ($role)"
  scan_keys "$src" "$db" "$keys"
  attach_target_to_source_net "$src" "$tgt"
  ip="$target_ip"
  started="$(date +%s)"
  quote_keys < "$keys" \
    | MIG_HOST="$ip" MIG_PW="$(app_password "$role")" MIG_N="$batch_size" MIG_T="$timeout_ms" awk '
        BEGIN { pre = "MIGRATE " ENVIRON["MIG_HOST"] " 6379 \"\" 0 " ENVIRON["MIG_T"] " COPY REPLACE AUTH2 default \"" ENVIRON["MIG_PW"] "\" KEYS"; n = ENVIRON["MIG_N"] + 0 }
        { line = line " " $0; c++ }
        c == n { print pre line; line = ""; c = 0 }
        END { if (c > 0) print pre line }' \
    | src_cli_stdin "$src" -n "$db" > "$out"
  ok="$(grep -cx OK "$out" || true)"
  nokey="$(grep -cx NOKEY "$out" || true)"
  bad="$(grep -vxE 'OK|NOKEY' "$out" | head -3 || true)"
  printf '[%s] %s batches OK, %s NOKEY (all keys of the batch expired), %ss\n' "$(ts)" "$ok" "$nokey" "$(( $(date +%s) - started ))"
  [[ -z "$bad" ]] || die "MIGRATE failed for $src db$db -> $tgt: $bad (see $out)"
}

# ---------------------------------------------------------------- verify
# Type-aware content digest, read-only (EVAL_RO). Single quotes only so it can
# be passed inside a double-quoted redis-cli argument.
read -r -d '' DIGEST_LUA <<'LUA' || true
local function s(x) if type(x) == 'table' then local o = {} for i = 1, #x do o[i] = s(x[i]) end return '[' .. table.concat(o, ',') .. ']' end x = tostring(x) return string.len(x) .. ':' .. x end
local k = KEYS[1] local t = redis.call('TYPE', k)['ok'] local v = ''
if t == 'string' then v = s(redis.call('GET', k))
elseif t == 'list' then v = s(redis.call('LRANGE', k, 0, -1))
elseif t == 'set' then local m = redis.call('SMEMBERS', k) table.sort(m) v = s(m)
elseif t == 'zset' then v = s(redis.call('ZRANGE', k, 0, -1, 'WITHSCORES'))
elseif t == 'hash' then local h = redis.call('HGETALL', k) local p = {} for i = 1, #h, 2 do p[#p + 1] = s(h[i]) .. '=' .. s(h[i + 1]) end table.sort(p) v = table.concat(p, ',')
elseif t == 'stream' then v = s(redis.call('XRANGE', k, '-', '+'))
end
return t .. ' ' .. redis.sha1hex(v)
LUA
DIGEST_LUA="$(printf '%s' "$DIGEST_LUA" | tr '\n' ' ')"

keyspace_line() {
  # "keys=N expires=M" for one db from INFO keyspace output.
  printf '%s\n' "$1" | tr -d '\r' | awk -F'[:,=]' -v db="db$2" '$1 == db { print "keys=" $3 " expires=" $5; found=1 } END { if (!found) print "keys=0 expires=0" }'
}

verify_mapping() {
  local i="$1" src="${m_src[$1]}" db="${m_db[$1]}" role="${m_role[$1]}" tgt keys vdir t0 t1 tol sk tk result sample
  tgt="$(target_container "$role")"
  keys="$run_dir/keys/$src-db$db.txt"
  [[ -f "$keys" ]] || die "missing key list $keys; was this run executed?"
  vdir="$run_dir/verify/$src-db$db"
  mkdir -p "$vdir"
  section "Verify $src db$db -> $tgt ($role)"

  sk="$(keyspace_line "$(src_cli "$src" INFO keyspace)" "$db")"
  tk="$(keyspace_line "$(tgt_cli "$tgt" INFO keyspace)" 0)"
  printf 'counts: source db%s %s | target db0 %s\n' "$db" "$sk" "$tk"

  # PTTL of every copied key on both sides, line-aligned with the key list.
  t0="$(date +%s%3N)"
  quote_keys < "$keys" | sed 's/^/PTTL /' | src_cli_stdin "$src" -n "$db" | tr -d '\r' > "$vdir/source.pttl"
  t1="$(date +%s%3N)"
  quote_keys < "$keys" | sed 's/^/PTTL /' | tgt_cli_stdin "$tgt" | tr -d '\r' > "$vdir/target.pttl"
  # Both sides tick down in real time; the target is read one pass later.
  tol="$(( (t1 - t0) + 5000 ))"
  [[ "$(wc -l < "$vdir/source.pttl")" == "$(wc -l < "$keys")" && "$(wc -l < "$vdir/target.pttl")" == "$(wc -l < "$keys")" ]] \
    || die "PTTL output does not line up with the key list for $src db$db"
  result="$(paste -d' ' "$vdir/source.pttl" "$vdir/target.pttl" | awk -v tol="$tol" '
    { s = $1 + 0; t = $2 + 0; if (s != -2) sp++; if (t != -2) tp++ }
    s == -2 { gone++; next }
    t == -2 { missing++; if (missing <= 5) bad = bad " missing@" NR; next }
    s == -1 && t != -1 { ttl_added++; if (++e <= 5) bad = bad " ttl_added@" NR; next }
    s >= 0 && t == -1 { ttl_lost++; if (++e <= 5) bad = bad " ttl_lost@" NR; next }
    s >= 0 && (t > s + 1000 || s - t > tol) { drift++; if (++e <= 5) bad = bad " ttl_drift@" NR "(" s "/" t ")"; next }
    s == -1 { ok_persist++; next }
    { ok_ttl++ }
    END { printf "%d %d checked=%d ok_no_ttl=%d ok_ttl=%d gone_in_source=%d missing=%d ttl_added=%d ttl_lost=%d ttl_drift=%d%s\n",
          sp, tp, NR, ok_persist, ok_ttl, gone, missing, ttl_added, ttl_lost, drift, bad }')"
  local src_present tgt_present
  read -r src_present tgt_present result <<<"$result"
  printf 'keys+TTL: %s (tolerance %sms)\n' "$result" "$tol"

  # Exact set check. The PTTL pass purged every expired key it touched, so
  # after it each side should hold exactly the listed keys that still exist.
  # More keys in the target: keys that did not come from the source. More in
  # the source: keys written after the scan, which were not copied. Fewer is
  # fine (keys expiring since the pass).
  local sk2 tk2 s_now t_now extra_target new_source
  sk2="$(keyspace_line "$(src_cli "$src" INFO keyspace)" "$db")"
  tk2="$(keyspace_line "$(tgt_cli "$tgt" INFO keyspace)" 0)"
  s_now="${sk2#keys=}"; s_now="${s_now%% *}"
  t_now="${tk2#keys=}"; t_now="${t_now%% *}"
  extra_target=$(( t_now - tgt_present ))
  new_source=$(( s_now - src_present ))
  (( extra_target < 0 )) && extra_target=0
  (( new_source < 0 )) && new_source=0
  printf 'key set: source has %s listed keys + %s unlisted; target has %s listed keys + %s unlisted\n' \
    "$src_present" "$new_source" "$tgt_present" "$extra_target"
  result+=" unlisted_in_source=$new_source unlisted_in_target=$extra_target"

  # Content digest of a random sample.
  sample="$vdir/sample.keys"
  shuf -n "$sample_size" "$keys" > "$sample" || true
  quote_keys < "$sample" | sed "s|^|EVAL_RO \"$DIGEST_LUA\" 1 |" | src_cli_stdin "$src" -n "$db" | tr -d '\r' > "$vdir/source.digest"
  quote_keys < "$sample" | sed "s|^|EVAL_RO \"$DIGEST_LUA\" 1 |" | tgt_cli_stdin "$tgt" | tr -d '\r' > "$vdir/target.digest"
  local digest_result
  digest_result="$(paste -d'|' "$vdir/source.digest" "$vdir/target.digest" | awk -F'|' '
    $1 ~ /^none / { gone++; next }
    $1 !~ /^[a-z]+ [0-9a-f]{40}$/ { err++; if (err <= 3) bad = bad " error@" NR ":" $1; next }
    $1 == $2 { same++; next }
    { diff++; if (diff <= 5) bad = bad " differs@" NR "(" $1 " vs " $2 ")" }
    END { printf "sampled=%d identical=%d gone_in_source=%d different=%d errors=%d%s\n", NR, same, gone, diff, err, bad }')"
  printf 'content: %s\n' "$digest_result"

  printf '| %s db%s | %s | %s | %s | %s | %s |\n' "$src" "$db" "$tgt ($role)" "$sk" "$tk" "$result" "$digest_result" \
    >> "$run_dir/verify/summary.md"

  if [[ "$result" =~ missing=0\ ttl_added=0\ ttl_lost=0\ ttl_drift=0 && "$digest_result" =~ different=0\ errors=0 ]] \
    && (( extra_target == 0 && new_source == 0 )); then
    printf 'PASS %s db%s -> %s\n' "$src" "$db" "$tgt"
    return 0
  fi
  printf 'FAIL %s db%s -> %s\n' "$src" "$db" "$tgt"
  return 1
}

verify_all() {
  local i failed=0
  mkdir -p "$run_dir/verify"
  printf '| source | target | source keyspace | target keyspace | keys + TTL | content sample |\n|---|---|---|---|---|---|\n' > "$run_dir/verify/summary.md"
  for i in "${!m_src[@]}"; do
    verify_mapping "$i" || failed=1
  done
  return "$failed"
}

# ---------------------------------------------------------------- confirm
confirm_typed() {
  local word="$1" answer
  (( assume_yes == 1 )) && return 0
  [[ -t 0 ]] || die "not a terminal; pass --yes to confirm non-interactively"
  printf 'Type %s to continue: ' "$word" >&2
  IFS= read -r answer
  [[ "$answer" == "$word" ]] || die "not confirmed"
}

# ---------------------------------------------------------------- main
section "Plan ($mode) $(ts)"
printf 'env file:   %s\nproject:    %s\nrun dir:    %s\n' "$env_file" "$project" "$run_dir"
for i in "${!m_src[@]}"; do
  printf 'map:        %s db%s -> %s (%s)\n' "${m_src[$i]}" "${m_db[$i]}" "$(target_container "${m_role[$i]}")" "${m_role[$i]}"
done

section "Sources"
for s in "${sources[@]}"; do resolve_source "$s"; done
for i in "${!m_src[@]}"; do
  (( m_db[i] < src_info[${m_src[$i]}] )) || die "${m_src[$i]} has databases ${src_info[${m_src[$i]}]}; db${m_db[$i]} does not exist"
done

section "Targets"
for i in "${!m_role[@]}"; do resolve_target "${m_role[$i]}"; done

case "$mode" in
  dry-run)
    for i in "${!m_role[@]}"; do
      (( tgt_ok[${m_role[$i]}] == 0 )) || printf 'NOTE: target %s is not empty (%s keys); --execute will refuse. Use --reset-target after a rollback.\n' \
        "$(target_container "${m_role[$i]}")" "${tgt_ok[${m_role[$i]}]}"
    done
    writers_gate
    section "Dry run complete; nothing was changed"
    printf 'Next: pause writers, then rerun with --execute.\n'
    ;;

  execute)
    for i in "${!m_role[@]}"; do
      (( tgt_ok[${m_role[$i]}] == 0 )) || die "target $(target_container "${m_role[$i]}") is not empty (${tgt_ok[${m_role[$i]}]} keys); refusing to merge. Use --reset-target first."
    done
    [[ ! -e "$run_dir" ]] || die "run dir already exists: $run_dir"
    confirm_typed migrate
    mkdir -p "$run_dir"/{keys,logs,verify}
    chmod 0700 "$run_dir"
    exec > >(tee -a "$run_dir/migration.log") 2>&1
    trap cleanup_networks EXIT
    printf 'maps: %s\n' "${maps[*]}" > "$run_dir/maps.txt"
    # Writers must be quiet before the backup, so the backup, the copy and the
    # verification all see the same data.
    writers_gate
    section "Backup sources"
    for s in "${sources[@]}"; do backup_source "$s"; done
    for i in "${!m_src[@]}"; do copy_mapping "$i"; done
    cleanup_networks
    connected_nets=()
    if verify_all; then
      verdict=PASS
    else
      verdict=FAIL
    fi
    writers_gate || true
    {
      printf '# Redis migration %s\n\n' "$(basename "$run_dir")"
      printf 'Result: **%s**\n\n' "$verdict"
      cat "$run_dir/verify/summary.md"
      # shellcheck disable=SC2016  # literal markdown backticks
      printf '\nBackups (with SHA256SUMS) are in %s; key lists in %s.\n' '`backup/`' '`keys/`'
      printf 'Rollback: point clients back at the source containers, which were not modified.\n'
    } > "$run_dir/report.md"
    section "Result: $verdict (report: $run_dir/report.md)"
    [[ "$verdict" == PASS ]] || exit 1
    printf 'Next: point clients at the new instances, resume writers, then run --decommission --execute.\n'
    ;;

  verify-only)
    [[ -d "$run_dir/keys" ]] || die "$run_dir has no keys/; pass the run dir of an executed migration"
    if verify_all; then
      section "Result: PASS"
    else
      section "Result: FAIL"
      exit 1
    fi
    ;;

  reset-target)
    for i in "${!m_role[@]}"; do
      tgt="$(target_container "${m_role[$i]}")"
      printf 'reset: would empty %s (%s, %s keys) after backing it up to %s/target-backup/%s\n' \
        "$tgt" "${m_role[$i]}" "${tgt_ok[${m_role[$i]}]}" "$run_dir" "$tgt"
      if (( execute == 1 )); then
        printf '%s\n' "${confirm_resets[@]}" | grep -qxF "$tgt" || die "pass --confirm-reset $tgt to empty it"
      fi
    done
    (( execute == 1 )) || { section "Dry run; nothing was changed"; exit 0; }
    confirm_typed reset
    mkdir -p "$run_dir/target-backup"
    chmod 0700 "$run_dir" "$run_dir/target-backup"
    for i in "${!m_role[@]}"; do
      tgt="$(target_container "${m_role[$i]}")"
      dir="$run_dir/target-backup/$tgt"
      mkdir -p "$dir"
      redis_bgsave_and_wait "$tgt" ops "$REDIS_ADMIN_PASSWORD"
      docker cp -q "$tgt:/data/dump.rdb" "$dir/dump.rdb"
      (cd "$dir" && sha256sum dump.rdb > SHA256SUMS)
      tgt_cli "$tgt" INFO keyspace | tr -d '\r' > "$dir/keyspace.txt"
      reply="$(tgt_cli "$tgt" FLUSHALL SYNC | tr -d '\r')"
      [[ "$reply" == OK ]] || die "FLUSHALL on $tgt failed: $reply"
      printf '[%s] emptied %s (backup: %s); dbsize now %s\n' "$(ts)" "$tgt" "$dir" "$(tgt_cli "$tgt" DBSIZE | tr -d '\r')"
    done
    ;;

  decommission)
    for s in "${sources[@]}"; do
      printf 'decommission: %s restart policy %s -> no\n' "$s" "$(docker inspect -f '{{.HostConfig.RestartPolicy.Name}}' "$s")"
    done
    (( execute == 1 )) || { section "Dry run; nothing was changed"; exit 0; }
    confirm_typed decommission
    for s in "${sources[@]}"; do
      docker update --restart=no "$s" >/dev/null
      printf '[%s] %s restart policy is now %s. It keeps running; stop it when ready with: docker stop %s\n' \
        "$(ts)" "$s" "$(docker inspect -f '{{.HostConfig.RestartPolicy.Name}}' "$s")" "$s"
    done
    printf 'Containers and volumes were not removed.\n'
    ;;
esac
