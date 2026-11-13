#!/usr/bin/env bash
# shellcheck disable=SC2015,SC2010,SC2012  # test harness: pass/fail chains and ls listings are intentional
# End-to-end test of the Redis stack and scripts/migrate-redis-legacy.sh on
# throwaway resources only.
#
#   tests/redis/migration-test.sh run [N_DB0_KEYS] [N_DB1_KEYS] [N_SESSIONS]
#   tests/redis/migration-test.sh cleanup pstest-XXXXXX
#
# Everything it creates is named pstest-<id>-* and labelled pstest=<id>; the
# work dir is $HOME/.cache/prod-services-tests/pstest-<id> (outside the repo
# and outside /tmp). It never reads or writes redis/.env or redis/redis_config.
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repo_dir="$(cd -- "$script_dir/../.." && pwd)"
# shellcheck source=../../scripts/shared/common.sh
source "$repo_dir/scripts/shared/common.sh"

base_dir="$HOME/.cache/prod-services-tests"
legacy_image="${LEGACY_IMAGE:-redis:8.0.1}"

step() { printf '\n######## %s  [%s]\n' "$*" "$(date -u +%T)"; }
pass() { printf 'TEST PASS: %s\n' "$*"; }
fail() { printf 'TEST FAIL: %s\n' "$*"; failures=$(( failures + 1 )); }
failures=0

cleanup() {
  local id="$1" work c v n
  [[ "$id" =~ ^pstest-[a-z0-9]{6}$ ]] || die "refusing to clean up '$id': not a pstest-xxxxxx id"
  work="$base_dir/$id"
  printf 'Cleanup for %s. Resources found:\n' "$id"
  docker ps -a --filter "label=pstest=$id" --format '  container {{.Names}}'
  docker ps -a --filter "label=com.docker.compose.project=$id" --format '  container {{.Names}} (compose)'
  docker volume ls --filter "label=pstest=$id" --format '  volume {{.Name}}'
  docker network ls --filter "label=pstest=$id" --format '  network {{.Name}}'
  docker network ls --filter "name=^${id}_(net|default)$" --format '  network {{.Name}}'
  printf '  work dir %s\n' "$work"

  for c in $(docker ps -aq --filter "label=pstest=$id") $(docker ps -aq --filter "label=com.docker.compose.project=$id"); do
    n="$(docker inspect -f '{{.Name}}' "$c")"
    [[ "$n" == "/$id-"* ]] || die "container $n does not carry the $id- prefix; not removing"
    docker rm -f "$c" >/dev/null && printf 'removed container %s\n' "$n"
  done
  for v in $(docker volume ls -q --filter "label=pstest=$id"); do
    [[ "$v" == "$id-"* ]] || die "volume $v does not carry the $id- prefix; not removing"
    docker volume rm "$v" >/dev/null && printf 'removed volume %s\n' "$v"
  done
  for n in $(docker network ls -q --filter "label=pstest=$id") $(docker network ls -q --filter "name=^${id}_(net|default)$"); do
    v="$(docker network inspect -f '{{.Name}}' "$n")"
    [[ "$v" == "$id"* ]] || die "network $v does not carry the $id prefix; not removing"
    docker network rm "$n" >/dev/null && printf 'removed network %s\n' "$v"
  done
  if [[ -d "$work" ]]; then
    [[ "$(realpath "$work")" == "$base_dir/$id" ]] || die "work dir resolves elsewhere; not removing"
    # Data dirs were chowned to 999 by the Redis entrypoint; remove them from
    # a container that only sees this work dir.
    docker run --rm --network none -v "$work:/w" redis:8.8.4-alpine sh -c 'rm -rf /w/data /w/backups' >/dev/null 2>&1 || true
    rm -rf -- "${work:?}"
    printf 'removed work dir %s\n' "$work"
  fi
}

if [[ "${1:-}" == cleanup ]]; then
  cleanup "${2:?usage: cleanup pstest-xxxxxx}"
  exit 0
fi
[[ "${1:-}" == run ]] || die "usage: $0 run [N_DB0] [N_DB1] [N_SESSIONS] | cleanup pstest-xxxxxx"
n_db0="${2:-300000}"
n_db1="${3:-20000}"
n_sess="${4:-20000}"

id="pstest-$(openssl rand -hex 3)"
work="$base_dir/$id"
mkdir -p "$work"
chmod 0700 "$work"
env_file="$work/redis.env"
cfg="$work/cfg"
port_base=$(( 30000 + RANDOM % 20000 ))
legacy_pw="$(generate_secret)"
printf 'id=%s work=%s port_base=%s\n' "$id" "$work" "$port_base"
printf '%s\n' "$id" > "$base_dir/last-id"

# ------------------------------------------------------------------ fake legacy
step "Create fake legacy instances (named volumes, own network, $legacy_image, databases 16)"
docker network create --label "pstest=$id" "$id-legacy" >/dev/null
for name in app session; do
  docker volume create --label "pstest=$id" "$id-$name-data" >/dev/null
  # Password via --requirepass on the command line, like the hand-made legacy compose.
  docker run -d --name "$id-redis_$name" --label "pstest=$id" --network "$id-legacy" \
    --restart unless-stopped -v "$id-$name-data:/data" "$legacy_image" \
    redis-server --requirepass "$legacy_pw" --appendonly yes --save "60 1000" >/dev/null
done
sleep 2
lcli() { local c="$1"; shift; REDISCLI_AUTH="$legacy_pw" docker exec -i -e REDISCLI_AUTH "$c" redis-cli --no-auth-warning "$@"; }

step "Seed: db0=$n_db0 keys, db1=$n_db1 keys, sessions=$n_sess"
t0=$(date +%s)
python3 -I "$script_dir/seed_legacy.py" app "$n_db0" "$n_db1" | lcli "$id-redis_app" --pipe | tail -1
python3 -I "$script_dir/seed_legacy.py" session "$n_sess" 0 | lcli "$id-redis_session" --pipe | tail -1
printf 'seeded in %ss\n' "$(( $(date +%s) - t0 ))"
lcli "$id-redis_app" INFO keyspace | tr -d '\r' | grep ^db
lcli "$id-redis_session" INFO keyspace | tr -d '\r' | grep ^db
# Log every command on the source so we can check MIGRATE AUTH2 is redacted.
lcli "$id-redis_app" CONFIG SET slowlog-log-slower-than 0 >/dev/null
lcli "$id-redis_app" CONFIG SET slowlog-max-len 100000 >/dev/null

# ------------------------------------------------------------------ target stack
step "Create target prod-services stack (project $id, roles cache,session,queue)"
cp "$repo_dir/redis/.env.example" "$env_file"
kv() { set_env_file_value "$1" "$2" "$env_file"; }
kv REDIS_COMPOSE_PROJECT_NAME "$id"
kv REDIS_NETWORK_NAME "${id}_net"
kv REDIS_ROLES cache,session,queue
kv REDIS_MEMORY_MB 8192
kv REDIS_CPU_CORES 2
kv REDIS_BACKUP_DIR "$work/backups"
i=0
for r in cache session queue ws; do
  R="${r^^}"
  kv "REDIS_${R}_CONTAINER_NAME" "$id-$r"
  kv "REDIS_${R}_DATA_DIR" "$work/data/$r"
  kv "REDIS_${R}_HOST_PORT" "$(( port_base + i ))"
  kv "REDIS_${R}_EXPORTER_PORT" "$(( port_base + 10 + i ))"
  kv "REDIS_GATEWAY_${R}_PORT" "$(( port_base + 20 + i ))"
  i=$(( i + 1 ))
done
kv REDIS_GATEWAY_METRICS_PORT "$(( port_base + 30 ))"
"$repo_dir/scripts/generate-redis-config.sh" --env-file "$env_file" --output-dir "$cfg" --yes | tail -4
"$repo_dir/scripts/redis-env-check.sh" prepare-data-dirs --env-file "$env_file" | grep -v '^note'
ops() { "$repo_dir/scripts/redis-ops.sh" "$1" --env-file "$env_file" --config-dir "$cfg" "${@:2}"; }
ops compose -- up -d --wait 2>&1 | tail -3
docker ps --filter "label=com.docker.compose.project=$id" --format '{{.Names}} {{.Status}}'

mig() { "$repo_dir/scripts/migrate-redis-legacy.sh" --env-file "$env_file" --config-dir "$cfg" \
  --map "$id-redis_app:0=queue" --map "$id-redis_app:1=cache" --map "$id-redis_session:0=session" \
  --quiesce-seconds 3 "$@"; }
export SRC_AUTH="$legacy_pw"

# ------------------------------------------------------------------ 1. dry run
step "1. Dry run"
if mig --dry-run; then pass "dry run"; else fail "dry run"; fi

step "1b. Dry run with an active writer is flagged, --execute refuses"
( for _ in $(seq 1 200); do lcli "$id-redis_app" SET laravel_database_live:writer "$(date +%s%N)" >/dev/null; sleep 0.05; done ) &
writer=$!
sleep 1
out="$(mig --dry-run 2>&1 || true)"
grep -q 'Writers look active' <<<"$out" && pass "dry run flags active writer" || fail "dry run did not flag active writer"
out="$(mig --execute --yes --run-dir "$work/backups/migrations/refused" 2>&1 || true)"
grep -q 'writers look active' <<<"$out" && pass "execute refuses with active writer" || { fail "execute did not refuse"; printf '%s\n' "$out" | tail -5; }
wait "$writer" || true

# ------------------------------------------------------------------ 2. execute
step "2. Execute"
run1="$work/backups/migrations/run1"
t0=$(date +%s)
if mig --execute --yes --run-dir "$run1"; then pass "execute run1 ($(( $(date +%s) - t0 ))s)"; else fail "execute run1"; fi

# ------------------------------------------------------------------ 3. independent checks
step "3. Independent verification of counts, TTLs, awkward keys, backups, secrets"
admin_pw="$(env_file_value REDIS_ADMIN_PASSWORD "$env_file")"
tcli() { local c="$1"; shift; REDISCLI_AUTH="$admin_pw" docker exec -i -e REDISCLI_AUTH "$c" redis-cli --no-auth-warning --user ops "$@"; }
for pair in "$id-redis_app 0 $id-queue" "$id-redis_app 1 $id-cache" "$id-redis_session 0 $id-session"; do
  read -r s d t <<<"$pair"
  sk="$(lcli "$s" INFO keyspace | tr -d '\r' | awk -F'[:,=]' -v db="db$d" '$1==db {print $3, $5}')"
  tk="$(tcli "$t" INFO keyspace | tr -d '\r' | awk -F'[:,=]' '$1=="db0" {print $3, $5}')"
  printf '%s db%s keys/expires=%s | %s keys/expires=%s\n' "$s" "$d" "$sk" "$t" "$tk"
  [[ "$sk" == "$tk" ]] && pass "counts $s db$d == $t" || fail "counts $s db$d != $t"
done
for k in 'laravel_database_weird:key with spaces' 'laravel_database_weird:quote"key' 'laravel_database_weird:back\slash' 'laravel_database_weird:unicode-ключ-🔑' 'laravel_database_weird:*glob?[x]' "$(printf 'laravel_database_weird:tab\there')" laravel_database_binary:value; do
  a="$(lcli "$id-redis_app" -n 0 --no-raw GET "$k")"; b="$(tcli "$id-queue" --no-raw GET "$k")"
  [[ -n "$a" && "$a" == "$b" ]] && pass "value of $(printf '%q' "$k")" || fail "value of $(printf '%q' "$k"): '$a' vs '$b'"
done
a="$(lcli "$id-redis_app" -n 0 LRANGE laravel_database_queues:ffmpeg-jobs 0 -1 | sha256sum)"
b="$(tcli "$id-queue" LRANGE laravel_database_queues:ffmpeg-jobs 0 -1 | sha256sum)"
[[ "$a" == "$b" ]] && pass "ffmpeg-jobs queue identical and in order" || fail "ffmpeg-jobs queue differs"
p1="$(lcli "$id-redis_app" -n 1 PTTL laravel_database_caches:lock:report)"; p2="$(tcli "$id-cache" PTTL laravel_database_caches:lock:report)"
printf 'lock PTTL source=%s target=%s\n' "$p1" "$p2"
(( p2 > 0 && p1 - p2 < 60000 && p2 - p1 < 1000 )) && pass "TTL preserved on cache lock" || fail "TTL not preserved"
[[ "$(tcli "$id-queue" PTTL laravel_database_counter:3)" == -1 ]] && pass "non-TTL counter stays persistent" || fail "counter gained a TTL"
if (cd "$run1/backup/$id-redis_app" && sha256sum -c --quiet SHA256SUMS); then pass "source backup checksums verify"; else fail "source backup checksums"; fi
ls "$run1/backup/$id-redis_app"
if lcli "$id-redis_app" SLOWLOG GET 100000 | grep -q "$(env_file_value REDIS_QUEUE_PASSWORD "$env_file")"; then fail "target password visible in source SLOWLOG"; else pass "MIGRATE AUTH2 password redacted in source SLOWLOG"; fi
if grep -rqF "$legacy_pw" "$run1" || grep -rqF "$admin_pw" "$run1"; then fail "a password was written to the run dir"; else pass "no passwords in run dir"; fi
[[ -z "$(docker inspect -f '{{range $n, $_ := .NetworkSettings.Networks}}{{$n}} {{end}}' "$id-queue" | grep -o "$id-legacy" || true)" ]] \
  && pass "target detached from legacy network after run" || fail "target still attached to legacy network"
[[ "$(docker inspect -f '{{.HostConfig.RestartPolicy.Name}}' "$id-redis_app")" == unless-stopped ]] && pass "source restart policy untouched" || fail "source restart policy changed"

# ------------------------------------------------------------------ 4. rollback
step "4. Roll back: clients point back at the source, which keeps changing"
lcli "$id-redis_app" -n 0 RPUSH laravel_database_queues:ffmpeg-jobs '{"after":"rollback"}' >/dev/null
lcli "$id-redis_app" -n 0 SET laravel_database_after:rollback yes >/dev/null
lcli "$id-redis_app" -n 0 DEL laravel_database_counter:0 laravel_database_counter:1 >/dev/null
lcli "$id-redis_app" -n 1 SET laravel_database_caches:after:rollback yes EX 3600 >/dev/null
out="$(mig --execute --yes --run-dir "$work/backups/migrations/refused2" 2>&1 || true)"
grep -q 'is not empty' <<<"$out" && pass "execute refuses to merge into a non-empty target" || fail "execute did not refuse non-empty target"
out="$(mig --reset-target --execute --yes --run-dir "$work/backups/migrations/reset-noconfirm" 2>&1 || true)"
grep -q 'pass --confirm-reset' <<<"$out" && pass "reset-target refuses without --confirm-reset" || fail "reset-target ran without --confirm-reset"
mig --reset-target --run-dir "$work/backups/migrations/reset-dry" | grep 'reset: would'
reset_dir="$work/backups/migrations/reset"
if mig --reset-target --execute --yes --confirm-reset "$id-queue" --confirm-reset "$id-cache" --confirm-reset "$id-session" --run-dir "$reset_dir"; then
  pass "reset-target"
else
  fail "reset-target"
fi
ls "$reset_dir/target-backup"

# ------------------------------------------------------------------ 5. run again
step "5. Run again"
run2="$work/backups/migrations/run2"
t0=$(date +%s)
if mig --execute --yes --run-dir "$run2"; then pass "execute run2 ($(( $(date +%s) - t0 ))s)"; else fail "execute run2"; fi
[[ "$(tcli "$id-queue" GET laravel_database_after:rollback)" == yes ]] && pass "post-rollback write present" || fail "post-rollback write missing"
[[ "$(tcli "$id-queue" EXISTS laravel_database_counter:0)" == 0 ]] && pass "post-rollback delete honoured" || fail "deleted key resurrected"
[[ "$(tcli "$id-queue" LINDEX laravel_database_queues:ffmpeg-jobs -1)" == '{"after":"rollback"}' ]] && pass "post-rollback job present" || fail "post-rollback job missing"
if "$repo_dir/scripts/migrate-redis-legacy.sh" --env-file "$env_file" --config-dir "$cfg" \
  --map "$id-redis_app:0=queue" --map "$id-redis_app:1=cache" --map "$id-redis_session:0=session" --verify-only --run-dir "$run2" >/dev/null; then
  pass "--verify-only on run2"; else fail "--verify-only on run2"; fi
step "5b. Verification catches a missing key and a stray key"
tcli "$id-queue" DEL laravel_database_counter:3 >/dev/null   # i%10==3: counter without TTL
tcli "$id-cache" SET laravel_database_caches:stray yes >/dev/null
out="$("$repo_dir/scripts/migrate-redis-legacy.sh" --env-file "$env_file" --config-dir "$cfg" \
  --map "$id-redis_app:0=queue" --map "$id-redis_app:1=cache" --map "$id-redis_session:0=session" --verify-only --run-dir "$run2" 2>&1 || true)"
grep -E '^(PASS|FAIL) |missing=|key set:' <<<"$out" | sed 's/^/  /' | cut -c1-200
grep -q "FAIL $id-redis_app db0" <<<"$out" && grep -qE 'missing=1 ' <<<"$out" && pass "missing target key detected" || fail "missing target key not detected"
grep -q "FAIL $id-redis_app db1" <<<"$out" && grep -qE 'target has [0-9]+ listed keys \+ 1 unlisted' <<<"$out" && pass "stray target key detected" || fail "stray target key not detected"
grep -q "PASS $id-redis_session db0" <<<"$out" && pass "untouched mapping still passes" || fail "untouched mapping"

# ------------------------------------------------------------------ 6. decommission
step "6. Decommission"
mig --decommission --run-dir "$work/x" | grep decommission
mig --decommission --execute --yes --run-dir "$work/x"
for c in "$id-redis_app" "$id-redis_session"; do
  [[ "$(docker inspect -f '{{.HostConfig.RestartPolicy.Name}} {{.State.Status}}' "$c")" == "no running" ]] \
    && pass "$c restart=no and still running" || fail "$c state after decommission"
done
docker volume inspect "$id-app-data" "$id-session-data" >/dev/null && pass "source volumes still exist" || fail "source volume missing"

# ------------------------------------------------------------------ 7. backups + retention
step "7. Backup command and retention"
if "$repo_dir/scripts/redis-backup.sh" --env-file "$env_file" --config-dir "$cfg" --no-prune; then pass "backup of persistent roles"; else fail "backup"; fi
for role in session queue; do
  d="$(find "$work/backups/$role" -mindepth 1 -maxdepth 1 -type d | sort | tail -1)"
  (cd "$d" && sha256sum -c --quiet SHA256SUMS) && pass "$role backup checksums ($(ls "$d" | paste -sd' ' -))" || fail "$role backup checksums"
done
[[ -d "$work/backups/cache" ]] && fail "cache (persistence none) was backed up by default" || pass "cache skipped by default (no persistence)"
# Fake history: 6 expired marked backups, 1 expired unmarked dir, 1 foreign file.
for n in 1 2 3 4 5 6; do mkdir -p "$work/backups/queue/2025010${n}T000000Z" && printf 'redis-backup v1\n' > "$work/backups/queue/2025010${n}T000000Z/.redis-backup"; done
mkdir -p "$work/backups/queue/20250101T120000Z" "$work/backups/queue/not-a-backup"
out="$("$repo_dir/scripts/redis-backup.sh" --env-file "$env_file" --config-dir "$cfg" --role queue --prune-dry-run)"
printf '%s\n' "$out" | grep 'would remove' || true
# The newest 3 marked backups are always kept (REDIS_BACKUP_KEEP_MIN), the rest
# of the 2025 ones are expired; unmarked dirs must never be listed.
marked="$(find "$work/backups/queue" -mindepth 2 -maxdepth 2 -name .redis-backup | wc -l)"
expected=$(( marked - 3 ))
[[ "$(grep -c 'would remove' <<<"$out")" == "$expected" ]] && ! grep -qE 'would remove .*(120000Z|not-a-backup|2026)' <<<"$out" \
  && pass "prune dry run lists exactly the $expected expired marked backups (of $marked marked)" || fail "prune dry run list"
ls "$work/backups/queue" | grep -c . | xargs printf 'queue backup entries before prune: %s\n'
"$repo_dir/scripts/redis-backup.sh" --env-file "$env_file" --config-dir "$cfg" --role queue | grep removing || true
[[ -d "$work/backups/queue/20250101T120000Z" && -d "$work/backups/queue/not-a-backup" ]] && pass "unmarked dirs kept" || fail "unmarked dir removed"
[[ ! -d "$work/backups/queue/20250101T000000Z" ]] && pass "expired marked backups removed" || fail "expired backup kept"

# ------------------------------------------------------------------ 8. ACL + rotation
step "8. ACL users and zero-downtime password rotation"
old_pw="$(env_file_value REDIS_QUEUE_PASSWORD "$env_file")"
new_pw="$(generate_secret)"
qport="$(env_file_value REDIS_QUEUE_HOST_PORT "$env_file")"
[[ "$(REDISCLI_AUTH="$old_pw" redis-cli --no-auth-warning -p "$qport" CONFIG GET maxmemory 2>&1)" == *NOPERM* ]] && pass "app user cannot CONFIG GET" || fail "app user has admin commands"
grep -q requirepass "$cfg"/*/redis.conf && fail "plaintext requirepass in redis.conf" || pass "no plaintext passwords in redis.conf"
grep -qF "$old_pw" "$cfg"/*/users.acl && fail "plaintext password in users.acl" || pass "users.acl holds hashes only"
# A long-lived client authenticated with the old password.
( printf 'AUTH %s\r\n' "$old_pw"; sleep 12; printf 'PING\r\n'; sleep 1 ) | redis-cli --no-auth-warning -p "$qport" > "$work/longlived.out" 2>&1 &
ll=$!
kv REDIS_QUEUE_PASSWORD_NEXT "$new_pw"
"$repo_dir/scripts/generate-redis-config.sh" --env-file "$env_file" --output-dir "$cfg" --yes >/dev/null
ops acl-reload
[[ "$(REDISCLI_AUTH="$new_pw" redis-cli --no-auth-warning -p "$qport" PING)" == PONG && "$(REDISCLI_AUTH="$old_pw" redis-cli --no-auth-warning -p "$qport" PING)" == PONG ]] \
  && pass "phase 1: old and new passwords both work" || fail "phase 1"
kv REDIS_QUEUE_PASSWORD "$new_pw"
kv REDIS_QUEUE_PASSWORD_NEXT ""
"$repo_dir/scripts/generate-redis-config.sh" --env-file "$env_file" --output-dir "$cfg" --yes >/dev/null
ops acl-reload
[[ "$(REDISCLI_AUTH="$old_pw" redis-cli --no-auth-warning -p "$qport" PING 2>&1)" == *WRONGPASS* ]] && pass "phase 2: old password rejected" || fail "phase 2: old password still accepted"
wait "$ll" || true
printf 'long-lived connection opened with the old password, after both reloads: %s\n' "$(tr -d '\r' < "$work/longlived.out" | paste -sd' ' -)"
docker ps --filter "label=com.docker.compose.project=$id" --format '{{.Names}} {{.Status}}'

# ------------------------------------------------------------------ 9. status
step "9. make status equivalent"
ops status > "$work/status.txt"
head -40 "$work/status.txt"

# ------------------------------------------------------------------ 10. gateway + exporter
step "10. Allowlisted gateway and exporters"
gw="$id-gateway"
gw_qport=$(( port_base + 22 ))
printf '10.255.255.1   # nobody we connect from\n' > "$work/allowlist"
kv REDIS_GATEWAY on
kv REDIS_EXPORTER on
kv REDIS_GATEWAY_BIND_ADDRESS 127.0.0.1
kv REDIS_GATEWAY_CONTAINER_NAME "$gw"
kv REDIS_GATEWAY_ALLOWLIST_FILE "$work/allowlist"
"$repo_dir/scripts/redis-env-check.sh" ensure-env --env-file "$env_file" --yes | grep -i generated || true
"$repo_dir/scripts/generate-redis-config.sh" --env-file "$env_file" --output-dir "$cfg" --yes | grep -E 'Gateway|profiles'
ops compose -- up -d --wait 2>&1 | tail -2
# Same as make serve redis: running containers load the regenerated users.acl.
ops acl-reload | grep -c 'authenticates' | xargs printf 'acl-reload: %s passwords verified\n'
qpw="$(env_file_value REDIS_QUEUE_PASSWORD "$env_file")"
r="$(REDISCLI_AUTH="$qpw" timeout 3 redis-cli --no-auth-warning -p "$gw_qport" PING 2>&1 || true)"
[[ "$r" != *PONG* ]] && pass "gateway rejects a source not on the allowlist" || fail "gateway let a non-allowlisted source through"
printf '10.255.255.1\n172.16.0.0/12   # docker bridge range, local test only\n' > "$work/allowlist"
"$repo_dir/scripts/generate-redis-config.sh" --env-file "$env_file" --output-dir "$cfg" --yes >/dev/null
ops gateway-reload 2>&1 | grep -vE 'WARNING|NOTICE|^Warnings' || true
r="$(REDISCLI_AUTH="$qpw" timeout 3 redis-cli --no-auth-warning -p "$gw_qport" GET laravel_database_after:rollback 2>&1 || true)"
[[ "$r" == yes ]] && pass "after reload the allowlisted source reaches the queue through the gateway" || fail "gateway after reload: $r"
cp "$cfg/gateway/haproxy.cfg" "$work/haproxy.before"
printf '0.0.0.0/0\n' >> "$work/allowlist"
if "$repo_dir/scripts/generate-redis-config.sh" --env-file "$env_file" --output-dir "$cfg" --yes >/dev/null 2>&1; then
  fail "0.0.0.0/0 accepted in the allowlist"
else
  cmp -s "$work/haproxy.before" "$cfg/gateway/haproxy.cfg" && grep -q 172.16 "$cfg/gateway/allowlist.lst" \
    && pass "0.0.0.0/0 refused and live gateway files unchanged" || fail "live gateway files changed after a refused entry"
fi
printf '10.255.255.1\n172.16.0.0/12\n' > "$work/allowlist"
docker logs "$gw" 2>&1 | grep -E ' fe_redis_queue ' | tail -1 | sed 's/^/  gateway log: /'
grep -q ' fe_redis_queue ' <<<"$(docker logs "$gw" 2>&1)" && pass "gateway logs accepted connections with client IP" || fail "no gateway connection log"
REDISCLI_AUTH=wrong-password-for-test redis-cli --no-auth-warning -p "$qport" PING >/dev/null 2>&1 || true
sleep 1
m="$(curl -fsS "http://127.0.0.1:$(env_file_value REDIS_QUEUE_EXPORTER_PORT "$env_file")/metrics" || true)"
grep -E '^redis_(up|memory_max_bytes|acl_access_denied_auth_total|aof_last_write_status) ' <<<"$m" | sed 's/^/  /'
grep -q '^redis_up 1' <<<"$m" && pass "exporter scrapes the queue role as the read-only exporter user" || fail "exporter not up"
grep -qE '^redis_acl_access_denied_auth_total [1-9]' <<<"$m" && pass "auth failures visible in exporter metrics" || fail "auth failures not visible"
exporter_logs="$(docker logs "$id-queue-exporter" 2>&1)"
grep -iE 'noperm' <<<"$exporter_logs" | head -3 | sed 's/^/  exporter: /' || true
! grep -qi noperm <<<"$exporter_logs" && pass "exporter ACL covers every command it runs" || fail "exporter hit NOPERM"
curl -fsS "http://127.0.0.1:$(env_file_value REDIS_GATEWAY_METRICS_PORT "$env_file")/metrics" | grep -E '^haproxy_frontend_denied_connections_total\{proxy="fe_redis' | sed 's/^/  /'

step "Summary"
printf 'id=%s work=%s failures=%s\n' "$id" "$work" "$failures"
for r in "$run1" "$run2"; do printf -- '--- %s\n' "$r"; cat "$r/report.md"; done
printf '\nClean up with: tests/redis/migration-test.sh cleanup %s\n' "$id"
(( failures == 0 ))
