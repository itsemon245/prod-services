# Production Services

Reusable Docker Compose services for production VMs. Run commands from the
repository root.

## Quick Start

Postgres:

```sh
make config db
make serve db
```

Redis:

```sh
make config redis
make serve redis
```

On the first run, the scripts can create the service `.env` file from
`.env.example` and generate random passwords for any empty password fields.
`make serve ...` validates the `.env`, prints a safe preview of non-sensitive
settings, generates missing config, prepares host data directories, then starts
Docker Compose.

To edit values manually before running the commands:

```sh
cp postgres/.env.example postgres/.env
cp redis/.env.example redis/.env
```

## Commands

```sh
make help
make install docker
make config db
make serve db
make config redis
make serve redis
make status redis
make backup redis
make reload-redis-acl
make reload-redis-gateway
make ensure-db-env
make ensure-redis-env
make lint
```

`db` and `postgres` are aliases, so `make config postgres` also works.
`make install docker` installs Docker Engine and the Compose plugin on
Debian/Ubuntu hosts.

For non-interactive env bootstrap:

```sh
scripts/postgres-env-check.sh ensure-env --yes
scripts/redis-env-check.sh ensure-env --yes
```

## Generated Files

```text
postgres/pg_config/
redis/redis_config/
```

Generated config files are ignored by git. Redis configs hold no plaintext
passwords: `users.acl` has SHA-256 hashes, and `healthcheck.secret` (0600) holds
only the password of the PING-only healthcheck user. Treat
`redis/redis_config/` as sensitive local output anyway.

Data, backups and migration runs live outside the checkout by default, under
`/srv/prod-services/`.

## Service Docs

- [Postgres production service](postgres/README.md)
- [Redis production service](redis/README.md): roles, ACL, gateway, backups, migration
- [Onboarding Artistly onto Redis](redis/docs/artistly-onboarding.md)
