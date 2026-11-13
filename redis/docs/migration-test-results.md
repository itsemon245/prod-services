# Redis stack and legacy migration: test results

All runs used throwaway resources only. Containers, volumes and networks were
named `pstest-<id>-*`, and work dirs lived under `~/.cache/prod-services-tests/`.
Each run was cleaned up afterwards by `tests/redis/migration-test.sh cleanup
<id>`, which refuses anything without the run's prefix. No real server, no real
data, and neither this repo's `redis/.env` nor `redis/redis_config/` were touched.

Environment: Arch Linux 7.2.11, 12 cores, Docker 29.9.2, Compose 5.6.1. Legacy
side `redis:8.0.1` (the version on wnx); target `redis:8.8.4-alpine`.

## End-to-end: `tests/redis/migration-test.sh run 300000 20000 20000`

Run of record `pstest-7feee6`, 2026-11-13: **55 checks passed, 0 failed.**

Fake legacy layout, built like wnx's:

- Two containers, `redis_app` and `redis_session`, with `databases 16`.
- Password set by `--requirepass` on the command line, AOF on.
- Named volumes and their own network.

Seeded data:

| Instance | DB | Keys | With TTL | Contents |
|---|---|---|---|---|
| redis_app | 0 | 300,064 | 150,050 | queue lists (`default`, `ffmpeg-jobs`, `script-storybooks`), delayed zsets, counters without TTL, lists, zsets, hashes, sets, a stream, locks, 50 keys with 2–20s TTLs; awkward names (spaces, quotes, backslash, UTF-8/emoji, glob chars, tab); a 256-byte binary value |
| redis_app | 1 | 20,002 | 15,001 | cache entries, `illuminate:queue:restart`, a lock |
| redis_session | 0 | 20,000 | 20,000 | sessions |

Mapping: `redis_app:0=queue`, `redis_app:1=cache`, `redis_session:0=session`.

### Results by step

| # | Step | Result |
|---|---|---|
| 1 | Dry run | Resolved and asserted containers, compose labels, volumes, data dirs and auth. Writers quiet. Nothing changed. |
| 1b | Writer active during dry run and `--execute` | Dry run flagged it. `--execute` refused before backing up or copying. |
| 2 | `--execute` (run 1) | Backups: redis_app 51 MB, redis_session 5.9 MB, both `redis-check-rdb` OK with SHA256SUMS. Copied 300,015 + 20,002 + 20,000 keys in 601 + 41 + 40 MIGRATE batches. **25 s total**, including backups and verification. 48 short-TTL keys expired between `DBSIZE` and `SCAN`, as expected. |
| 2 | Verification (all three mappings) | Keys/expires equal on both sides. PTTL of every key on both sides: 0 missing, 0 TTL added/lost/drifted. Exact key-set check: 0 unlisted keys either side. 500-key content digest sample: 500/500 identical. `Result: PASS` |
| 3 | Independent checks | `INFO keyspace` equal per mapping. All awkward key names and the binary value byte-identical. `ffmpeg-jobs` list identical and in order. Lock TTL preserved. Counters without TTL stay without TTL. Backup checksums verify. |
| 3 | Secrets | Target password not visible in the source's `SLOWLOG` (logging every command; Redis redacts `MIGRATE AUTH2`). No password in any file of the run dir. Passwords never in argv (stdin and `docker exec -e NAME` only). |
| 3 | Source untouched | Target detached from the legacy network after the run. Source restart policy unchanged. |
| 4 | Rollback | Source changed afterwards: a new job, a new key, 2 deleted counters, a new cache key. `--execute` refused to merge into a non-empty target. `--reset-target --execute` refused without `--confirm-reset`, then with it backed up and emptied the 3 targets. |
| 5 | Run again | `PASS` again in 25 s. Post-rollback job and key present, deleted counters absent. `--verify-only` on the run passes. |
| 5b | Verifier catches damage | One target key deleted: `missing=1`, mapping FAIL. One stray key added: `+ 1 unlisted`, mapping FAIL. Untouched mapping still PASS. |
| 6 | `--decommission --execute` | Sources now `restart=no` and still running. Volumes intact. Nothing stopped or removed. |
| 7 | `scripts/redis-backup.sh` | session (RDB) and queue (RDB + `appendonlydir`) backed up, checksums verify. cache (persistence none) skipped by default. Retention: with 7 marked backups and `KEEP_MIN=3`, the dry run listed exactly the 4 expired ones; the real prune removed only those. A timestamp-named dir without the marker and a foreign dir were both kept. |
| 8 | ACL | App user gets `NOPERM` on `CONFIG GET`. No `requirepass` in any `redis.conf`. `users.acl` holds hashes only. |
| 8 | Rotation | Phase 1 (`_NEXT` set, `acl-reload`): old and new passwords both work. Phase 2 (promoted, `acl-reload`): old password rejected. A connection authenticated with the old password before rotation **kept working** afterwards; see "Findings". |
| 10 | Gateway | A source not on the allowlist was rejected. After the allowlist edit and `gateway-reload` (`haproxy -c` then USR2), the same source reached the queue through the gateway. Adding `0.0.0.0/0` was refused, and the live `haproxy.cfg` and `allowlist.lst` stayed byte-identical. Accepted connections are logged with client IP. |
| 10 | Exporter | `redis_up 1` as the read-only `exporter` user. No `NOPERM` in exporter logs. `redis_acl_access_denied_auth_total` counts failed logins. |

### Verification output (run 1)

```text
counts: source db0 keys=300015 expires=150000 | target db0 keys=300015 expires=150000
keys+TTL: checked=300015 ok_no_ttl=150015 ok_ttl=150000 gone_in_source=0 missing=0 ttl_added=0 ttl_lost=0 ttl_drift=0 (tolerance 7288ms)
key set: source has 300015 listed keys + 0 unlisted; target has 300015 listed keys + 0 unlisted
content: sampled=500 identical=500 gone_in_source=0 different=0 errors=0
PASS redis_app db0 -> queue
counts: source db1 keys=20002 expires=15001 | target db0 keys=20002 expires=15001
...
PASS redis_app db1 -> cache
counts: source db0 keys=20000 expires=20000 | target db0 keys=20000 expires=20000
...
PASS redis_session db0 -> session
```

## Upgrade in place: `tests/redis/upgrade-test.sh`

This test deploys `origin/main` (old layout: single-file configs with plaintext
`requirepass`), writes 1000 queue keys, overlays this branch onto the same
checkout, and runs `make serve redis`. **10/10 passed**:

- `REDIS_ADMIN_PASSWORD` was generated.
- All four containers were recreated once and became healthy.
- Queue data survived through AOF (1000 keys, values intact).
- Existing app passwords still authenticate (as the `default` user).
- No `requirepass` is left in `redis_config/`.
- The same Docker network was kept.

## `make lint`

shellcheck 0.11.0 is clean on all scripts. `docker compose config` renders for
these role combinations:

- all roles;
- all features (gateway + exporters);
- queue only;
- Artistly-like;
- `redis/examples/artistly-wnx.env.example`.

Every generated HAProxy config passes `haproxy -c`.

## Findings that changed the design

- **Expiry and the dirty counter.** Active expiry does not increment
  `rdb_changes_since_last_save` (checked on 8.0.1). The writer check therefore
  uses the raw delta. Subtracting `expired_keys` would hide real writes.
- **Lazy expiry makes counts drift.** `INFO keyspace` counts differ between
  instances while expired keys wait to be purged. Verification uses the
  per-key PTTL pass, which also purges what it touches, followed by an exact
  key-set check instead of comparing raw counts.
- **Running containers keep their ACL.** They keep the ACL they started with
  until `ACL LOAD`. `make serve redis` now ends with `acl-reload`; without it,
  turning on the exporter left it unable to log in.
- **Existing sessions survive rotation.** Connections authenticated before a
  password rotation stay authenticated. Rotation is still zero-downtime, but
  revoking a leaked password also needs `CLIENT KILL USER default` or a restart.
  This is documented in the README.
- **Rejects are not logged.** HAProxy logs neither `tcp-request connection
  reject` nor `session reject`. Rejections are counted in
  `haproxy_frontend_denied_connections_total`, and the counter resets on reload.
- **Image entrypoint and `redis-check-rdb`.** Through the image entrypoint,
  `redis-check-rdb` exits 1; with `--entrypoint redis-check-rdb` it works. Both
  backup paths use the latter.
