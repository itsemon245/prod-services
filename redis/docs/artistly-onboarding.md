# Onboarding Artistly onto prod-services Redis

Artistly's production Redis on `wnx` (108.171.206.234) runs from a hand-made
compose file (project `appartistlyai`) with two legacy containers:

| Legacy container | Image | Contents | Ports |
|---|---|---|---|
| `redis_app` | `redis:8.0.1`, about 1.75 GB | db0: Laravel queues (incl. `ffmpeg-jobs`), Horizon, cache locks, `AccumulatorService` counters with no TTL (170,759 keys, 163,552 with TTL). db1: Laravel cache incl. `illuminate:queue:restart` (9,520 keys) | 6379 on `0.0.0.0` and `[::]` |
| `redis_session` | `redis:8.0.1` | sessions | 6380 on `0.0.0.0` and `[::]` |

Artistly moves onto standard prod-services roles, each with `databases 1`. The
standard is not relaxed to fit the legacy layout:

| Legacy | prod-services role | Policy | Persistence |
|---|---|---|---|
| `redis_app` db0 | `queue` | `noeviction` | AOF + RDB |
| `redis_app` db1 | `cache` | `allkeys-lru` | none |
| `redis_session` db0 | `session` | `volatile-ttl` | RDB |

Remote clients reach wnx through the allowlisted HAProxy gateway:

| Client | Source IP | Needs |
|---|---|---|
| editor server | 108.171.203.171 | queue, cache, session |
| ffmpeg worker VMs | 50.115.45.242 (NAT) | queue, cache |

Processes on wnx itself connect over loopback (or over the `artistly-redis`
Docker network if they run in containers).

## 1. Artistly repo changes (made in `~/Work/artistly`, branched from `origin/production`)

These must ship **before** cutover. They keep today's behaviour when the new env
keys are unset.

### `config/database.php`: give the `cache` connection its own keys

The `cache` connection reuses `REDIS_HOST`/`REDIS_PORT`/`REDIS_PASSWORD` and only
changes the DB number. After the split it lives on a different instance:

```php
'cache' => [
    'url' => env('REDIS_CACHE_URL', env('REDIS_URL')),
    'host' => env('REDIS_CACHE_HOST', env('REDIS_HOST', '127.0.0.1')),
    'username' => env('REDIS_CACHE_USERNAME', env('REDIS_USERNAME')),
    'password' => env('REDIS_CACHE_PASSWORD', env('REDIS_PASSWORD')),
    'port' => env('REDIS_CACHE_PORT', env('REDIS_PORT', '6379')),
    'database' => env('REDIS_CACHE_DB', '1'),
    'prefix' => env('REDIS_PREFIX', Str::slug(env('APP_NAME', 'laravel'), '_').'_database_caches:'),
],
```

- `REDIS_URL` must be **unset** on every host. A URL overrides host, port and
  password, and with the fallback above it would send cache traffic to the queue
  instance.
- `REDIS_CACHE_DB=0` is required on the new instances. They have
  `databases 1`, so `SELECT 1` fails loudly with `ERR DB index is out of range`.
- The `session` connection already has its own `REDIS_SESSION_*` keys and needs no
  code change.
- Leave these as they are (on the `default` connection, which goes to the queue
  role, matching where their data is today):
  - `config/cache.php` stores `redis` with `'lock_connection' => 'default'`, so
    locks stay in the old db0 keyspace.
  - Horizon (`'use' => 'default'`).
  - Reverb scaling (`REDIS_HOST`; `REVERB_REDIS_DB` must stay `0`).
  - `redisCli()` in `app/helpers.php`.
- Add the new keys to `.env.example`: `REDIS_CACHE_HOST`, `REDIS_CACHE_PORT`,
  `REDIS_CACHE_PASSWORD`, `REDIS_CACHE_DB`, `REDIS_SESSION_DB`.

### Commands the new ACL denies

The app user is `default` with `~* &* +@all -@admin`. Normal Laravel use is
unaffected: queues, Horizon, cache, `cache:clear` (FLUSHDB), locks, pub/sub,
`SCAN`, `EVAL`, `INFO`. Denied: `CONFIG`, `DEBUG`, `MONITOR`, `SHUTDOWN`,
`REPLICAOF`, `ACL SETUSER/LOAD/SAVE`, `CLIENT KILL`, `BGSAVE`/`SAVE`/`BGREWRITEAOF`.
Grep the app for any of these before cutover. None were found on
`origin/production` as of this PR.

### Follow-ups worth tracking in Artistly

- `AccumulatorService` counters (`SET` with no TTL in db0) are durable business
  data living in Redis. They go to the queue role because it is the one that
  never evicts and has AOF. Long term they belong in the database.
- `CACHE_DRIVER` is still the pre-Laravel-11 key on the ffmpeg VMs. That is fine
  for this version, but keep it in mind on upgrade.

## 2. `.env` per host after cutover

Passwords come from `redis/.env` on wnx (`REDIS_<ROLE>_PASSWORD`). Never reuse
the legacy passwords.

wnx (web, Horizon/queue workers, scheduler), processes on the host:

```dotenv
REDIS_HOST=127.0.0.1
REDIS_PORT=6392
REDIS_PASSWORD=<REDIS_QUEUE_PASSWORD>
REDIS_DB=0

REDIS_CACHE_HOST=127.0.0.1
REDIS_CACHE_PORT=6390
REDIS_CACHE_PASSWORD=<REDIS_CACHE_PASSWORD>
REDIS_CACHE_DB=0

SESSION_CONNECTION=session
REDIS_SESSION_HOST=127.0.0.1
REDIS_SESSION_PORT=6391
REDIS_SESSION_PASSWORD=<REDIS_SESSION_PASSWORD>
REDIS_SESSION_DB=0
```

If those processes run in containers, attach them to the external network
`artistly-redis` and use `redis-queue`, `redis-cache` and `redis-session`, each on
port `6379`.

Editor server (108.171.203.171):

```dotenv
REDIS_HOST=108.171.206.234
REDIS_PORT=7381
REDIS_PASSWORD=<REDIS_QUEUE_PASSWORD>
REDIS_DB=0
REDIS_CACHE_HOST=108.171.206.234
REDIS_CACHE_PORT=7379
REDIS_CACHE_PASSWORD=<REDIS_CACHE_PASSWORD>
REDIS_CACHE_DB=0
SESSION_CONNECTION=session
REDIS_SESSION_HOST=108.171.206.234
REDIS_SESSION_PORT=7380
REDIS_SESSION_PASSWORD=<REDIS_SESSION_PASSWORD>
REDIS_SESSION_DB=0
```

ffmpeg worker VMs (pm2, `queue:work --queue=ffmpeg-jobs`):

```dotenv
QUEUE_CONNECTION=redis
CACHE_DRIVER=redis
REDIS_HOST=108.171.206.234
REDIS_PORT=7381
REDIS_PASSWORD=<REDIS_QUEUE_PASSWORD>
REDIS_DB=0
REDIS_CACHE_HOST=108.171.206.234
REDIS_CACHE_PORT=7379
REDIS_CACHE_PASSWORD=<REDIS_CACHE_PASSWORD>
REDIS_CACHE_DB=0
```

On every host after editing `.env`:

- `php artisan config:clear`, or `config:cache` if the host caches config. A stale
  `bootstrap/cache/config.php` silently keeps the old values.
- Make sure no `REDIS_*` variable is set in the shell or the pm2 environment,
  because those beat `.env`. Restart pm2 apps with
  `pm2 restart ffmpeg.ecosystem.config.cjs --update-env`.

## 3. Prepare wnx (no downtime)

```sh
sudo install -d -m 0755 /opt/prod-services
git clone git@github.com:strontiumcorp/prod-services.git /opt/prod-services
cd /opt/prod-services
cp redis/examples/artistly-wnx.env.example redis/.env
cp redis/gateway.allowlist.example redis/gateway.allowlist
#   add: 108.171.203.171 and 50.115.45.242
sudo install -d -m 0700 -o 999 -g 999 /srv/prod-services/redis/{cache,session,queue}
sudo install -d -m 0700 -o "$USER" /srv/prod-services/backups/redis
make serve redis
make status redis
```

Docker-published ports bypass UFW. The gateway allowlist is the real access
control. As defense in depth, also drop non-allowlisted traffic to the gateway
ports in `DOCKER-USER`, next to the existing `BLOCKLIST` chain and manual DROP
rules. **Do not flush or replace those.** `DOCKER-USER` sees packets after DNAT,
so match the original port:

```sh
sudo iptables -N REDIS-GW-ALLOW
sudo iptables -A REDIS-GW-ALLOW -s 108.171.203.171 -j RETURN
sudo iptables -A REDIS-GW-ALLOW -s 50.115.45.242 -j RETURN
sudo iptables -A REDIS-GW-ALLOW -j DROP
sudo iptables -I DOCKER-USER -i enp39s0 -p tcp -m conntrack --ctorigdstport 7379:7381 --ctdir ORIGINAL -j REDIS-GW-ALLOW
```

Persist them the same way the existing DOCKER-USER rules are persisted.

From the editor server and an ffmpeg VM:

```sh
REDISCLI_AUTH=<queue password> redis-cli -h 108.171.206.234 -p 7381 PING   # PONG
```

From any other host, the same command must fail with a closed connection.

Traffic between the hosts crosses the public internet unencrypted, including
passwords and session data. The allowlist limits who can connect but not who
can read the traffic. The better long-term setup is a WireGuard link between
editor, ffmpeg VMs and wnx, with `REDIS_BIND_ADDRESS` set to wnx's WireGuard IP
and the gateway turned off.

## 4. Dry run (no downtime)

Find the legacy container names (`docker ps --filter label=com.docker.compose.project=appartistlyai`),
then:

```sh
cd /opt/prod-services
read -rs SRC_AUTH_REDIS_APP; export SRC_AUTH_REDIS_APP          # legacy redis_app password
read -rs SRC_AUTH_REDIS_SESSION; export SRC_AUTH_REDIS_SESSION  # legacy redis_session password
scripts/migrate-redis-legacy.sh \
  --map redis_app:0=queue --map redis_app:1=cache --map redis_session:0=session
```

Use the real container names; the password variable is derived from the name
(`appartistlyai-redis_app-1` becomes `SRC_AUTH_APPARTISTLYAI_REDIS_APP_1`). The
dry run prints and asserts every container, volume and data dir, checks auth,
and lists the clients still connected to the sources. It changes nothing.

## 5. Cutover window

1. **Ship the Artistly config change** (section 1) with `.env` still pointing at
   the legacy instances.
2. **Pause writers.** Every one of these writes to db0, db1 or sessions:
   - web, on wnx and the editor server: `php artisan down` (maintenance mode
     returns 503 before sessions or cache are touched);
   - scheduler on wnx: disable the cron entry or stop `schedule:work`;
   - Horizon and queue workers on wnx: `php artisan horizon:terminate` (lets
     running jobs finish), or stop the supervisor programs;
   - ffmpeg workers on each VM. `pm2 stop` kills after `kill_timeout`, so first
     wait for running jobs to finish:
     `redis-cli … ZCARD laravel_database_queues:ffmpeg-jobs:reserved` should be 0.
     Then `pm2 stop ffmpeg.ecosystem.config.cjs`.
3. **Migrate:**
   `scripts/migrate-redis-legacy.sh --map … --execute`. The script:
   - refuses to start while it still sees writes or active clients;
   - backs up both sources (BGSAVE, RDB + AOF, SHA-256 sums, `INFO`) under
     `/srv/prod-services/backups/redis/migrations/<timestamp>/`;
   - copies the keys;
   - verifies counts, every key's TTL, and a content sample;
   - writes `report.md`.

   It must end with `Result: PASS`.
4. **Point the clients** at the new instances (section 2) and clear the config
   cache on every host.
5. **Resume** the workers, Horizon and the scheduler, then `php artisan up`.
6. **Watch:**
   - `make status redis`: keyspace growing, `acl_access_denied_auth` 0,
     `evicted_keys` 0 on the queue;
   - the gateway logs: `docker logs -f redis-gateway` shows each accepted client
     IP;
   - the legacy instances: a new dry run should show **no clients** connected. Any
     client listed there was missed in step 4.

## 6. Rollback

The legacy containers and their data are never modified. To roll back, revert
the `.env` changes from section 2 on every host, clear the config cache, and
restart the workers. Anything written to the new instances after cutover (jobs
dispatched, sessions, counters) is not copied back, so decide quickly.

To migrate again after a rollback:

```sh
scripts/migrate-redis-legacy.sh --map … --reset-target --execute \
  --confirm-reset redis-queue --confirm-reset redis-cache --confirm-reset redis-session
scripts/migrate-redis-legacy.sh --map … --execute
```

`--reset-target` backs up each target before emptying it.

## 7. Decommission (after a soak period, e.g. 7 days)

```sh
scripts/migrate-redis-legacy.sh --map … --decommission            # preview
scripts/migrate-redis-legacy.sh --map … --decommission --execute  # docker update --restart=no
docker stop <legacy redis_app> <legacy redis_session>
```

`--restart=no` stops the legacy containers from taking ports 6379/6380 back
after a reboot. The script never stops or removes containers or volumes.

After the containers are stopped:

- Remove the interim DOCKER-USER rules for 6379/6380.
- Retire the hand-made compose file, but only after the legacy volumes'
  contents exist in at least one verified backup that you have kept.
