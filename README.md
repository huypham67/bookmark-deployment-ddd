# bookmark-deployment

Deployment orchestration for the **bookmark microservices** stack. Adapted from the monolith `deployment/` repo to run `user-service` and `bookmark-service` as independent services with **database-per-service**.

## Topology

```
                          ┌─────────────┐
        Internet ──▶ nginx (gateway, :80)
                          └──────┬──────┘
            /api/user_service/ ──┤      ├── /api/bookmark_service/
                                 ▼      ▼
                       user-service   bookmark-service
                          │   │          │   │   │
                     ┌────┘   └──┐  ┌────┘   │   └────┐
                     ▼           ▼  ▼        ▼        ▼
                  user-db     (shared redis)   bookmark-db
                 (Postgres)                    (Postgres)
                                 ▲
              /  (everything else) ──▶ portal (frontend)
              cloudflared ──▶ secure tunnel
```

- **Database-per-service**: `user-db` (→ `user_db`) and `bookmark-db` (→ `bookmark_db`) are separate Postgres instances. No cross-service foreign keys.
- **Shared Redis**: rate limiting for both services; cache + short-links for bookmark-service. Services use separate logical DB indexes (user=0, bookmark=1).
- **Self-migrating**: each service runs its own migrations on startup — no init scripts needed.
- **JWT**: `user-service` signs tokens; `bookmark-service` validates them. A **single shared keypair** in `./keys` is mounted into both (the shared JWT provider loads both keys). `JWT_ISSUER`/`JWT_AUDIENCE` are identical across both services.

## Services

| Service | Image | Depends on | Exposed |
|---------|-------|------------|---------|
| user-db | postgres:16-alpine | — | 5433→5432 |
| bookmark-db | postgres:16-alpine | — | 5432 |
| redis | redis:7-alpine | — | 6379 |
| user-service | huypham053/user-service:${USER_SERVICE_TAG} | user-db, redis | via nginx |
| bookmark-service | huypham053/bookmark-service:${BOOKMARK_SERVICE_TAG} | bookmark-db, redis | via nginx |
| portal | ebvn/bookmark-app-portal:mono | services | via nginx |
| nginx | nginx:alpine | services, portal | 80 |
| cloudflared | cloudflare/cloudflared | — | tunnel |

## Quick Start

```bash
make setup        # create env files from examples + generate the shared JWT keypair
make up           # start the whole stack
make health       # curl both services' health-check through the gateway
make logs         # tail all logs
make down         # stop
```

Set image tags (default `latest`):
```bash
USER_SERVICE_TAG=<sha> BOOKMARK_SERVICE_TAG=<sha> make up
```

## Routes (via nginx :80)

| Path | Upstream |
|------|----------|
| `/api/user_service/` | user-service:8080 |
| `/api/user_service/swagger/` | user-service swagger |
| `/api/bookmark_service/` | bookmark-service:8080 |
| `/api/bookmark_service/swagger/` | bookmark-service swagger |
| `/` | portal frontend |

## Configuration

Real `.env` files are git-ignored; commit only the `*.example` templates.

| File | Purpose |
|------|---------|
| `postgres/user-db.env` | user-db credentials + `POSTGRES_DB=user_db` |
| `postgres/bookmark-db.env` | bookmark-db credentials + `POSTGRES_DB=bookmark_db` |
| `user-service/.env` | user-service app config (DB=user-db, Redis DB 0, JWT issuer/audience) |
| `bookmark-service/.env` | bookmark-service app config (DB=bookmark-db, Redis DB 1, same JWT issuer/audience) |
| `config/cloudflared.env` | `TUNNEL_TOKEN` |
| `keys/` | shared JWT keypair (mounted read-only into both services) |

## Make Targets

`make help` lists everything. Highlights:

| Target | Description |
|--------|-------------|
| `setup` | env files + keys |
| `up` / `down` / `restart` | lifecycle |
| `health` | check both services through nginx |
| `logs-user` / `logs-bookmark` | per-service logs |
| `shell-user-db` / `shell-bookmark-db` / `shell-redis` | data store shells |
| `validate` | `docker compose config` check |
| `purge` | ⚠️ remove containers + volumes + keys |
| `vm-*` | deploy/manage on a remote VM over SSH |

## Notes

- The CD pipelines in each service repo (`.github/workflows/cd.yaml`) deploy by `docker compose pull <service>` + `up -d --force-recreate <service>` against this stack on the target host.
- For production, replace the default `admin/admin` credentials and supply a real `cloudflared` tunnel token.
