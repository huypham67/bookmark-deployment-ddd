# bookmark-deployment

Docker Compose stack, Nginx gateway config, and Makefile for running the full bookmark system locally and on a VM.

## System Topology

```
Internet
   │
   ▼
[Cloudflare Tunnel]
   │
   ▼
[Nginx :80]
   ├── /api/user_service/*     → user-service:8080
   ├── /api/bookmark_service/* → bookmark-service:8080
   └── /*                      → bookmark-portal

[bookmark-service]
   ├── PostgreSQL (alias: bookmark-db)   ← CRUD + migrations
   ├── Redis DB 1                         ← short links + cache + queue
   └── LPUSH "bookmark:import:jobs" ─────────────────────────────┐
                                                                  │
[bookmark-worker] ← RPOP ─────────────────────────────────────────┘
   ├── PostgreSQL (alias: bookmark-db)   ← bulk bookmark writes
   └── Redis DB 1

[user-service]
   ├── PostgreSQL (alias: user-db)       ← users table
   └── Redis DB 0                        ← rate-limit counters
```

## Services

| Service | Image | Port | Description |
|---|---|---|---|
| `postgres` | `postgres:16-alpine` | 5432 | Single PostgreSQL instance; exposes network aliases `user-db` and `bookmark-db` (two databases on one server) |
| `redis` | `redis:7-alpine` | 6379 | Shared Redis; logical DB 0 (user-service) and DB 1 (bookmark-service, bookmark-worker) |
| `user-service` | `huypham053/user-service` | — | Auth + profile API |
| `bookmark-service` | `huypham053/bookmark-service` | — | Bookmark CRUD + short links + CSV import dispatch |
| `bookmark-worker` | `huypham053/bookmark-worker` | — | Background worker; consumes import jobs from Redis queue |
| `bookmark-portal` | `ebvn/bookmark-app-portal` | — | Frontend SPA |
| `bookmark-nginx` | `nginx:alpine` | 80 | Reverse proxy / API gateway |
| `cloudflared` | `cloudflare/cloudflared` | — | Cloudflare Tunnel (production only) |

> **One postgres, two databases.** The `postgres` container serves both `user_db` and `bookmark_db`. The Docker network aliases `user-db` and `bookmark-db` both resolve to the same host — this gives each service a meaningful hostname without running two separate Postgres instances.

## Directory Layout

```
bookmark-deployment/
├── bookmark-service/
│   ├── .env.example           # env vars for bookmark-service container
│   └── .env                   # (git-ignored)
├── bookmark-worker/
│   ├── .env.example           # env vars for bookmark-worker container
│   └── .env                   # (git-ignored)
├── user-service/
│   ├── .env.example           # env vars for user-service container
│   └── .env                   # (git-ignored)
├── postgres/
│   ├── .env.example           # POSTGRES_USER, POSTGRES_PASSWORD, POSTGRES_DB
│   ├── .env                   # (git-ignored)
│   └── init/                  # SQL scripts run on first start (create user_db + bookmark_db)
├── keys/
│   ├── private.pem            # RSA private key — user-service only (git-ignored)
│   └── public.pem             # RSA public key  — bookmark-service only (git-ignored)
├── nginx/
│   └── nginx.conf             # proxy rules, rate limiting
├── config/
│   └── cloudflared.env        # TUNNEL_TOKEN (git-ignored)
├── docker-compose.yaml
└── Makefile
```

## Quick Start (Local)

### Prerequisites

- Docker + Docker Compose v2
- `openssl` (for RSA key generation)
- `make`

### 1. Set up env files and keys

```bash
make setup
# copies *.env.example → *.env for all services
# generates keys/private.pem + keys/public.pem
```

Edit the `.env` files if you need non-default credentials:

```
bookmark-deployment/postgres/.env
bookmark-deployment/user-service/.env
bookmark-deployment/bookmark-service/.env
bookmark-deployment/bookmark-worker/.env
```

### 2. Start everything

```bash
make up
```

All migrations run automatically when `user-service` and `bookmark-service` start.

### 3. Verify

```bash
make health
# user-service:     {"status":"ok"}
# bookmark-service: {"status":"ok"}
```

> `make health` calls `http://localhost/api/.../health-check` via Nginx. Note that `bookmark-nginx` in the Docker Compose does not expose a host port — to access Nginx from localhost, add a `ports: ["80:80"]` entry to the `bookmark-nginx` service for local dev, or access services directly at their individual ports if running outside Docker. In production, Cloudflare Tunnel routes external traffic to Nginx on the Docker network.

## Make Targets

```
Setup:
  make setup             Copy .env.example files + generate RSA keypair
  make gen-keys          Generate RSA keypair only
  make verify-keys       Verify keypair is valid
  make env-check         Check all .env files exist
  make validate          Validate docker-compose.yaml

Local operations:
  make up                Start all services (detached)
  make down              Stop all services
  make restart           Restart all services
  make restart-user      Restart user-service only
  make restart-bookmark  Restart bookmark-service only
  make ps                Show running containers
  make status            Show containers, volumes, networks
  make health            Curl both service health endpoints
  make pull              Pull latest images

Logs:
  make logs              Tail all logs
  make logs-user         Tail user-service logs
  make logs-bookmark     Tail bookmark-service logs
  make logs-db           Tail postgres logs
  make logs-redis        Tail Redis logs

DB shells:
  make shell-user-db     psql into user_db
  make shell-bookmark-db psql into bookmark_db
  make shell-redis       Redis CLI

Cleanup:
  make clean             Stop and remove containers
  make purge             Remove containers, volumes, and keys (DESTRUCTIVE)

VM deploy:
  make vm-setup          Upload deployment files + run setup on VM
  make vm-keys           Generate RSA keypair on VM
  make vm-up             docker compose up -d on VM
  make vm-down           Stop services on VM
  make vm-logs           Tail logs on VM
  make vm-status         Show container status on VM
  make vm-health         Curl health endpoints on VM
  make vm-restart        Restart all services on VM
  make vm-shell          SSH into VM

Utilities:
  make version           Show tool versions (docker, compose, openssl)
  make help              List all targets with descriptions
```

## VM Deployment

The Makefile targets a VM at `103.118.29.77`. Override with:

```bash
make vm-up VM_HOST=<your-ip>
```

### First-time VM setup

```bash
make vm-setup    # rsync deployment files to /opt/bookmark-system on VM, runs setup
make vm-keys     # generate RSA keypair on VM
make vm-up       # start all containers
```

### CD Pipeline (GitHub Actions)

Each service repository has its own `cd.yaml`. The self-hosted runner connects to the VM, updates the image tag in `.env`, and force-recreates the service:

| Trigger | Action |
|---|---|
| Push to `main` in a service repo | Build → push `main`/`<sha7>` tags → deploy to VM |
| Git tag `v*.*.*` in a service repo | Build → push `<tag>`/`latest` → deploy to VM |

Working directory on VM: `/opt/bookmark-system`  
Variables updated: `USER_SERVICE_TAG`, `BOOKMARK_SERVICE_TAG`, `BOOKMARK_WORKER_TAG`

## Key Management

```bash
make gen-keys     # generate keys/private.pem + keys/public.pem
make verify-keys  # verify the keypair matches (sign + verify roundtrip)
```

- `keys/private.pem` — mounted into `user-service` only (JWT signing)
- `keys/public.pem` — mounted into `bookmark-service` only (JWT validation)
- Both files are git-ignored and must be generated before starting the stack
