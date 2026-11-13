"""Emit RESP that seeds a fake legacy Redis for migration tests.

Usage: python3 -I seed_legacy.py app|session N_DB0 N_DB1 | redis-cli --pipe

Writes a deterministic mix of strings, lists, sets, zsets, hashes and a
stream, with and without TTLs, plus awkward key names and binary values.
"""
import random
import sys


def resp(*args):
    out = [b"*%d\r\n" % len(args)]
    for a in args:
        if isinstance(a, (int, float)):
            a = str(a)
        if isinstance(a, str):
            a = a.encode()
        out.append(b"$%d\r\n%s\r\n" % (len(a), a))
    return b"".join(out)


def main():
    kind, n0, n1 = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
    rnd = random.Random(42)
    w = sys.stdout.buffer.write
    prefix = "laravel_database_"

    if kind == "session":
        w(resp("SELECT", 0))
        for i in range(n0):
            ttl = rnd.randint(3600, 7200)
            w(resp("SET", f"{prefix}sessions:{i:08x}{rnd.getrandbits(64):016x}", "a:3:{s:6:\"_token\";s:40:\"%040x\";}" % rnd.getrandbits(160), "EX", ttl))
        return

    # db0: queues, counters without TTL (AccumulatorService style), misc types.
    w(resp("SELECT", 0))
    for q in ("default", "ffmpeg-jobs", "script-storybooks"):
        for j in range(200):
            w(resp("RPUSH", f"{prefix}queues:{q}", '{"uuid":"%032x","job":"App\\\\Jobs\\\\X","attempts":0}' % rnd.getrandbits(128)))
        for j in range(20):
            w(resp("ZADD", f"{prefix}queues:{q}:delayed", 1_900_000_000 + j, '{"id":"%d"}' % j))
    for i in range(n0):
        r = i % 10
        if r < 5:
            args = ["SET", f"{prefix}counter:{i}", rnd.randint(0, 10**9)]
            if r < 3:
                args += ["EX", rnd.randint(600, 86400)]
            w(resp(*args))
        elif r == 5:
            w(resp("RPUSH", f"{prefix}list:{i}", *[f"item-{k}" for k in range(rnd.randint(1, 8))]))
            if i % 20 == 5:
                w(resp("EXPIRE", f"{prefix}list:{i}", 3600))
        elif r == 6:
            w(resp("ZADD", f"{prefix}zset:{i}", *[x for k in range(rnd.randint(1, 6)) for x in (rnd.random() * 1000, f"m{k}")]))
        elif r == 7:
            w(resp("HSET", f"{prefix}hash:{i}", *[x for k in range(rnd.randint(1, 6)) for x in (f"f{k}", f"v{rnd.getrandbits(32)}")]))
            if i % 20 == 7:
                w(resp("EXPIRE", f"{prefix}hash:{i}", 7200))
        elif r == 8:
            w(resp("SADD", f"{prefix}set:{i}", *[f"s{k}" for k in range(rnd.randint(1, 6))]))
        else:
            w(resp("SET", f"{prefix}lock:{i}", "owner", "PX", rnd.randint(600_000, 3_600_000)))
    w(resp("XADD", f"{prefix}stream:events", "*", "type", "test", "n", 1))
    w(resp("XADD", f"{prefix}stream:events", "*", "type", "test", "n", 2))
    # Awkward names and binary values.
    for name in ('key with spaces', 'quote"key', 'back\\slash', 'unicode-ключ-🔑', '*glob?[x]', 'tab\there'):
        w(resp("SET", f"{prefix}weird:{name}", name))
    w(resp("SET", f"{prefix}binary:value", bytes(range(256))))
    # Keys that expire during the test (exercises gone_in_source).
    for i in range(50):
        w(resp("SET", f"{prefix}short:{i}", "x", "EX", rnd.randint(2, 20)))

    # db1: Laravel cache.
    w(resp("SELECT", 1))
    w(resp("SET", f"{prefix}caches:illuminate:queue:restart", 1_731_000_000))
    for i in range(n1):
        if i % 4 == 0:
            w(resp("SET", f"{prefix}caches:forever:{i}", f"v{i}"))
        else:
            w(resp("SET", f"{prefix}caches:k:{i}", "s:%d:\"%x\";" % (i, rnd.getrandbits(64)), "EX", rnd.randint(60, 86400)))
    w(resp("SET", f"{prefix}caches:lock:report", "owner", "EX", 600))


if __name__ == "__main__":
    main()
