# Redis Production Service

Redis is managed from the repository root.

```sh
make config redis
make serve redis
make status redis
make backup redis
```

## Roles

Each role is a separate Redis instance with `databases 1`. One role per
workload keeps eviction and durability rules from colliding.

```text
role     container      policy        persistence (default)   budget weight
cache    redis-cache    allkeys-lru   none                    30
session  redis-session  volatile-ttl  rdb                     13
queue    redis-queue    noeviction    aof (AOF + RDB)         52
ws       redis-ws       allkeys-lru   none                     5
```

Pick the roles a host runs with `REDIS_ROLES` (default: all four):

```sh
REDIS_ROLES=cache,session,queue
```

Each role is a Compose profile. Disabled roles are not started and need no
password, port, data dir or memory limit. The memory budget is split across
enabled roles only, by weight.

Per-role overrides:

```sh
REDIS_<ROLE>_PERSISTENCE=none|rdb|aof
REDIS_<ROLE>_MAXMEMORY_POLICY=allkeys-lru|volatile-ttl|noeviction|...
REDIS_<ROLE>_MAXMEMORY_MB=...
REDIS_<ROLE>_MEM_LIMIT_MB=...
```

- **`rdb`**: snapshots on `save 900 1 300 100 60 10000` with
  `stop-writes-on-bgsave-error no`. A failed snapshot does not block writes; watch
  `rdb_last_bgsave_status`.
- **`aof`**: `appendfsync everysec` plus RDB snapshots and
  `stop-writes-on-bgsave-error yes`.
- **Memory headroom**: persistent roles get 50% container headroom over
  `maxmemory` for fork copy-on-write; non-persistent roles get 30%.
- **Queue warnings**: the env check warns when the queue role is not on
  `noeviction` + `aof`.

## What The Commands Do

`make config redis` renders, for each enabled role:

```text
redis/redis_config/<role>/redis.conf          config, no secrets
redis/redis_config/<role>/users.acl           ACL users, SHA-256 password hashes only
redis/redis_config/<role>/healthcheck.secret  password of the PING-only healthcheck user (0600)
redis/redis_config/gateway/haproxy.cfg        when REDIS_GATEWAY=on
redis/redis_config/gateway/allowlist.lst      validated copy of the allowlist
redis/redis_config/compose.env                project name, COMPOSE_PROFILES, mem limits
redis/redis_config/compose.override.yml       gateway ports for enabled roles
```

Role configs are mounted as directories, so `ACL LOAD` sees a regenerated
`users.acl` without a restart.

`make serve redis` runs this flow:

```text
1. Create redis/.env from .env.example if needed
2. Prompt to generate empty passwords for the enabled roles (and admin/exporter)
3. Validate redis/.env (roles, ports unique, pinned image, allowlist entries)
4. Preview safe values; warn about data dirs inside the checkout
5. Regenerate config (gateway config is checked with haproxy -c first)
6. Create data dirs (0700; chowned to 999 when run as root)
7. docker compose up -d --wait with redis/.env + compose.env + compose.override.yml
8. ACL LOAD on every running role and check every configured password
   (containers that were not recreated would otherwise keep their old ACL)
```

`make compose-redis ARGS="ps"` runs any Compose command with the same files.

## Credentials And ACL

There is no plaintext `requirepass`. Each role's `users.acl` defines:

```text
default      app user. Clients that send only a password log in as it.
             Rules: ~* &* +@all -@admin (override: REDIS_APP_ACL_RULES)
ops          operator user for backups, ACL LOAD, status, migrations (REDIS_ADMIN_PASSWORD)
healthcheck  PING only; the Docker healthcheck reads healthcheck.secret
exporter     read-only metrics user, only when REDIS_EXPORTER=on
```

`-@admin` denies `CONFIG`, `DEBUG`, `MONITOR`, `SHUTDOWN`, `REPLICAOF`,
`ACL SETUSER/LOAD`, `CLIENT KILL`, `BGSAVE` and similar to applications.
Normal app traffic still works: queues, cache, locks, pub/sub, `SCAN`, `EVAL`,
`FLUSHDB`, `INFO`.

The healthcheck authenticates as `healthcheck`. `PING` answers `-LOADING` while
an RDB or AOF is loading, so a container is healthy only once its data is
available.

`users.acl` is read-only inside the container, so `ACL SAVE` and
`CONFIG REWRITE` fail by design. `redis/.env` is the source of truth.

### Zero-downtime password rotation

```text
1. Set REDIS_QUEUE_PASSWORD_NEXT=<new> in redis/.env
2. make reload-redis-acl          # both passwords accepted (ACL LOAD, no restart)
3. Move every client to <new>
4. REDIS_QUEUE_PASSWORD=<new>, clear REDIS_QUEUE_PASSWORD_NEXT
5. make reload-redis-acl          # old password rejected
```

The same works for `REDIS_ADMIN_PASSWORD_NEXT`. `reload-redis-acl` checks that
every configured password authenticates after the reload.

Connections already authenticated keep working after their password is
removed; Redis does not re-check existing sessions. This was verified in the
test run. To cut off a leaked password, also run, after step 5:

```sh
read -rs REDISCLI_AUTH; export REDISCLI_AUTH     # REDIS_ADMIN_PASSWORD
redis-cli --user ops -p <REDIS_QUEUE_HOST_PORT> CLIENT KILL USER default
```

Or restart the role container. Either way, clients reconnect with whatever
password they now have configured.

## Remote Clients

Published ports bypass UFW. `REDIS_BIND_ADDRESS` must never be `0.0.0.0`.
Clients on other hosts have two options.

**Preferred: a private network.** Set `REDIS_BIND_ADDRESS` to this host's
private (VPC, VLAN or WireGuard) IP. Traffic stays off the internet and is
encrypted when it runs over WireGuard.

**Otherwise: the allowlisted gateway** (`REDIS_GATEWAY=on`). This is an HAProxy
TCP gateway in front of the loopback-only Redis ports:

```text
client --(REDIS_GATEWAY_BIND_ADDRESS:REDIS_GATEWAY_<ROLE>_PORT)--> haproxy --> redis-<role>:6379
```

- **Allowlist**: `redis/gateway.allowlist`, one IP or CIDR per line, `#` comments
  (see `gateway.allowlist.example`). Entries are validated, and anything wider
  than /8 (IPv4) or /16 (IPv6) is refused.
- **Rejection**: other sources are dropped at TCP accept with
  `tcp-request connection reject unless { src -f allowlist.lst }`, before a single
  byte reaches Redis.
- **Backends**: resolved through Docker DNS with `init-addr last,libc,none`, so
  the gateway starts even if a role is down.
- **Timeouts**: 24h client and server timeouts, with `clitcpka`/`srvtcpka`, so
  idle blocking queue connections survive.
- **Logs**: accepted connections are logged to stdout with the client IP
  (`docker logs redis-gateway`). Rejected connections are not logged by HAProxy;
  they are counted (per worker, reset on reload) in
  `haproxy_frontend_denied_connections_total` on
  `127.0.0.1:REDIS_GATEWAY_METRICS_PORT/metrics` and shown by `make status redis`.
  Use a `LOG` rule in `DOCKER-USER` if you need rejected source IPs.

After editing the allowlist:

```sh
make reload-redis-gateway
```

This command:

1. Validates the allowlist.
2. Renders the new config and checks it with `haproxy -c` in a throwaway
   container. On failure, the live files are left unchanged.
3. Swaps the files in, runs `haproxy -c` again inside the running gateway, then
   sends `docker kill -s USR2`.

Existing connections stay on the old worker for up to
`REDIS_GATEWAY_HARD_STOP_AFTER` (default 1h). Restart the gateway to cut off a
removed IP immediately.

The gateway does not encrypt traffic. Add a `DOCKER-USER` allowlist for the
gateway ports as a second layer (example in
[docs/artistly-onboarding.md](docs/artistly-onboarding.md)).

## Same-host Containers

The Compose network has a fixed name (`REDIS_NETWORK_NAME`, default
`redis_default`). App containers on the same host can join it:

```yaml
networks:
  redis:
    external: true
    name: redis_default
```

They then connect to `redis-queue:6379` and so on, with no published port
involved.

## Backups

```sh
make backup redis
scripts/redis-backup.sh --role session --role queue
scripts/redis-backup.sh --prune-dry-run
```

For each role with persistence (or the `--role` list), the backup:

1. Runs `BGSAVE` and waits for `LASTSAVE` to advance and for
   `rdb_last_bgsave_status:ok`.
2. Copies `dump.rdb`, plus `appendonlydir/` when AOF is on, out of the container
   with `docker cp`.
3. Writes `info.txt` (Server, Persistence, Keyspace, Memory) and `SHA256SUMS`.
4. Checks the RDB with `redis-check-rdb` in a throwaway, network-less container.

Backups go to `REDIS_BACKUP_DIR/<role>/<UTC timestamp>/` (0700). The default is
`/srv/prod-services/backups/redis`, and the directory must be outside the
checkout.

Retention removes backups older than `REDIS_BACKUP_RETENTION_DAYS` (14), always
keeping the newest `REDIS_BACKUP_KEEP_MIN` (3) per role. It only removes
directories this script created: a timestamp name **and** a `.redis-backup`
marker. `--prune-dry-run` lists what would go and takes no backup.

Cron example:

```cron
15 */6 * * * cd /opt/prod-services && make backup-redis >> /var/log/redis-backup.log 2>&1
```

To restore a role, stop it, put `dump.rdb` (and `appendonlydir/` for AOF roles)
into its data dir owned by 999, then start it.

## Operations

`make status redis` prints, per role:

- container state and health, restart policy;
- `used_memory`/`maxmemory`, policy, fragmentation;
- `evicted_keys`, `expired_keys`, clients, `rejected_connections`;
- `acl_access_denied_auth`/`acl_access_denied_cmd` (auth failures);
- RDB/AOF status;
- keyspace;
- the latest `ACL LOG` entries with the client address.

For the gateway it prints the denied-connection counters.

Alerts to set up. With `REDIS_EXPORTER=on` there is one `redis_exporter` per
role on `127.0.0.1:9121-9124`, authenticated as the read-only `exporter` user.
Give each scrape target a `role` label in Prometheus:

```text
redis_up == 0
redis_memory_used_bytes / redis_memory_max_bytes > 0.85       # queue: writes fail at 1.0
increase(redis_evicted_keys_total{role="queue"}[5m]) > 0       # should never happen
increase(redis_acl_access_denied_auth_total[5m]) > 10          # password guessing / broken client
redis_rdb_last_bgsave_status == 0 or redis_aof_last_write_status == 0
increase(haproxy_frontend_denied_connections_total[5m]) > 0     # gateway knocks
```

Without Prometheus, the same numbers come from:

```sh
REDISCLI_AUTH=... redis-cli --user ops -p <port> INFO everything
REDISCLI_AUTH=... redis-cli --user ops -p <port> ACL LOG 20
```

## Images

All images are pinned to exact versions in `.env.example` and compose defaults:

```text
redis:8.8.4-alpine   haproxy:3.2.26-alpine (LTS)   oliver006/redis_exporter:v1.97.0-alpine
```

`make serve redis` refuses unpinned tags (`latest`, `alpine`). For immutable
deploys, append a digest (`redis:8.8.4-alpine@sha256:…`). Review release notes
before changing versions on an existing VM.

## Storage

Data dirs are host bind mounts outside the checkout by default:

```sh
REDIS_CACHE_DATA_DIR=/srv/prod-services/redis/cache
REDIS_SESSION_DATA_DIR=/srv/prod-services/redis/session
REDIS_QUEUE_DATA_DIR=/srv/prod-services/redis/queue
REDIS_WS_DATA_DIR=/srv/prod-services/redis/ws
```

Create them once as root:

```sh
sudo install -d -m 0700 -o 999 -g 999 /srv/prod-services/redis/{cache,session,queue,ws}
```

`prepare-data-dirs` creates missing dirs with mode 0700 and chowns them to 999
when run as root. Otherwise the image entrypoint chowns `/data` to `redis` (999)
on start. The preview warns when a data dir is inside the checkout; existing
`.env` files with `./data/...` keep working.

These are bind mounts, not named volumes, so `docker compose down -v` cannot
delete them.

## Migrating From A Legacy Instance

[scripts/migrate-redis-legacy.sh](../scripts/migrate-redis-legacy.sh) moves keys
from a legacy multi-DB Redis container into role instances:

```sh
scripts/migrate-redis-legacy.sh --map legacy_app:0=queue --map legacy_app:1=cache --map legacy_session:0=session            # dry run
scripts/migrate-redis-legacy.sh --map ... --execute
scripts/migrate-redis-legacy.sh --map ... --verify-only --run-dir <dir>
scripts/migrate-redis-legacy.sh --map ... --reset-target --execute --confirm-reset redis-queue ...   # after a rollback
scripts/migrate-redis-legacy.sh --map ... --decommission --execute                                  # docker update --restart=no
```

Why it works this way:

- **Source never written.** `MIGRATE ... COPY REPLACE` leaves source keys in
  place, and the source container's config is not touched. For the copy, the
  *target* is attached to the source's Docker network and detached afterwards.
  Rollback is "point clients back".
- **Server-side, binary-safe, TTL-preserving.** `MIGRATE` serialises with
  `DUMP`/`RESTORE` on the server, in batches of `--batch-size` keys
  (`KEYS k1 ... kN`), so key names and values never pass through shell
  variables.
- **Quiesced first.** Before backup and copy, each source is watched for
  `--quiesce-seconds`. `rdb_changes_since_last_save` must not move (active
  expiry does not count) and no other client may run a command. Otherwise
  `--execute` refuses, unless `--force-live`.
- **Backed up first.** Each source gets BGSAVE, then RDB + AOF are copied with
  SHA-256 sums, `INFO` and redacted container metadata, and `redis-check-rdb` is
  run on the copy.
- **Verified.**
  - `INFO keyspace` keys/expires are compared exactly.
  - `PTTL` is checked for every copied key on both sides: missing keys, added or
    lost TTLs, and TTL drift beyond the read window are all failures.
  - A random `--sample` is compared with a type-aware content digest computed by
    a read-only `EVAL_RO` script.
- **Fails closed.** The script asserts every resolved container, compose label,
  data dir and mount before acting. It refuses a non-empty target, a target that
  is in the same compose project as a source, and a run dir inside the checkout.
- **No secrets in argv.** Passwords pass through `REDISCLI_AUTH` / `docker exec -e
  NAME` and stdin. `MIGRATE AUTH2` arguments are redacted by Redis in
  `SLOWLOG`/`MONITOR` (verified).
- **Never removes containers or volumes.** `--decommission` only sets
  `--restart=no`.

Test results on throwaway containers:
[docs/migration-test-results.md](docs/migration-test-results.md). Artistly
runbook: [docs/artistly-onboarding.md](docs/artistly-onboarding.md).

## Validation

```sh
make lint
tests/redis/migration-test.sh run 300000 20000 20000
tests/redis/migration-test.sh cleanup pstest-xxxxxx
```

`make lint` does two things:

- runs shellcheck on every script;
- renders the compose file for several role combinations, plus the Artistly
  example, from throwaway env files. Gateway configs are checked with `haproxy -c`.

The end-to-end test creates uniquely named `pstest-*` containers, volumes,
networks and a work dir under `~/.cache/prod-services-tests/`. It never reads or
writes `redis/.env`. There is no CI in this repo yet; `make lint` is what a CI job
should run.

## Upgrading An Existing Host

An existing `redis/.env` keeps working. On the next `make serve redis`:

- **New admin password.** `REDIS_ADMIN_PASSWORD` (the `ops` user) is generated
  if missing, after a prompt, or with `--yes`.
- **Containers are recreated once.** Config now mounts as a directory, the
  healthcheck changed, and roles became profiles, so each container restarts
  briefly. Queue data survives (AOF). Cache, websocket and session data does
  not, because those had no persistence before.
- **Session persistence turns on.** Sessions now default to `rdb`. Set
  `REDIS_SESSION_PERSISTENCE=none` to keep the old behaviour.
- **Unchanged values stay.** `REDIS_IMAGE`, data dirs (`./data/...`), ports,
  passwords and the compose project name (`redis`) are untouched. Bump
  `REDIS_IMAGE` to `redis:8.8.4-alpine` deliberately.
- **Plaintext configs are replaced.** The old `redis_config/<role>.conf` files
  held plaintext `requirepass` values and are overwritten with a pointer.
- **Minimum password length.** Passwords must be at least 32 characters.
  Generated ones are 64.
- **Apps need no changes.** They keep authenticating with a password only, as
  the `default` user.

## Compose Layout

`redis/docker-compose.yml` uses shared `x-*` extension blocks and YAML anchors
for the hardened runtime settings. The blocks sit above `services` because
anchors must be defined before they are used.

- Put shared runtime hardening in `x-redis-common`.
- Keep each service block to role-specific ports, memory limits, data dirs and
  config mounts.

Do not hand-edit files in `redis/redis_config/`. Edit `redis/.env`,
`redis/gateway.allowlist` or `redis/templates/`, then run `make config redis`.
