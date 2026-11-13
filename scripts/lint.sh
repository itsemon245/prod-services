#!/usr/bin/env bash
# Run shellcheck on every script and render the Redis compose file for several role
# combinations. Uses only a throwaway temp dir; never reads or writes redis/.env.
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repo_dir="$(cd -- "$script_dir/.." && pwd)"
# shellcheck source=shared/common.sh
source "$script_dir/shared/common.sh"
shellcheck_image="${SHELLCHECK_IMAGE:-koalaman/shellcheck:v0.11.0}"

mapfile -t scripts < <(cd "$repo_dir" && git ls-files -co --exclude-standard '*.sh' | sort -u)
printf 'shellcheck (%s): %s files\n' "$shellcheck_image" "${#scripts[@]}"
if command -v shellcheck >/dev/null 2>&1; then
  (cd "$repo_dir" && shellcheck -x "${scripts[@]}")
else
  docker run --rm --network none -v "$repo_dir:/mnt:ro" -w /mnt "$shellcheck_image" -x "${scripts[@]}"
fi

work="$(mktemp -d "${TMPDIR:-/tmp}/prod-services-lint.XXXXXX")"
cleanup() {
  # Only ever remove the directory this run created.
  [[ "$work" == "${TMPDIR:-/tmp}"/prod-services-lint.* && -d "$work" ]] && rm -rf -- "$work"
}
trap cleanup EXIT

render() {
  local name="$1"
  shift
  local dir="$work/$name"
  local base="$repo_dir/redis/.env.example"
  if [[ "${1:-}" == --base ]]; then base="$2"; shift 2; fi
  mkdir -p "$dir"
  cp "$base" "$dir/.env"
  printf '203.0.113.10\n198.51.100.0/28\n' > "$dir/allowlist"
  local kv
  for kv in "REDIS_GATEWAY_ALLOWLIST_FILE=$dir/allowlist" REDIS_MEMORY_MB=8192 REDIS_CPU_CORES=4 "$@"; do
    set_env_file_value "${kv%%=*}" "${kv#*=}" "$dir/.env"
  done
  "$script_dir/generate-redis-config.sh" --env-file "$dir/.env" --output-dir "$dir/cfg" --yes >/dev/null
  docker compose --env-file "$dir/.env" --env-file "$dir/cfg/compose.env" \
    -f "$repo_dir/redis/docker-compose.yml" -f "$dir/cfg/compose.override.yml" config -q
  printf 'compose config ok: %-14s services: %s\n' "$name" "$(docker compose --env-file "$dir/.env" --env-file "$dir/cfg/compose.env" \
    -f "$repo_dir/redis/docker-compose.yml" -f "$dir/cfg/compose.override.yml" config --services | sort | paste -sd' ' -)"
}

render all-roles
render all-features REDIS_GATEWAY=on REDIS_EXPORTER=on
render queue-only REDIS_ROLES=queue
render artistly REDIS_ROLES=cache,session,queue REDIS_GATEWAY=on
render artistly-example --base "$repo_dir/redis/examples/artistly-wnx.env.example"
