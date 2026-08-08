# maintainerd-dev

Local development environment for the maintainerd platform. One command to clone the repo, set up configuration, and start everything.

Auth is now a **single repo** (`maintainerd-auth`) containing the Go backend and
both SPAs (`web/console`, `web/identity`). In dev you run the three as hot-reload
containers (`auth` profile); to test the compiled single all-in-one image the way
it ships, use the `auth-release` profile.

## Quick start

```bash
# 1. Clone the maintainerd-auth repo
./maintainerd init

# 2. Create the env file, configure hosts, and trust the local HTTPS CA
#    (prompts for sudo)
./maintainerd setup

# 3. Start auth (hot-reload) with observability
./maintainerd up --profile=auth-observed -d
```

Identity: https://identity.auth.maintainerd.local

Console: https://console.auth.maintainerd.local

(These are the **system tenant** URLs. Regular tenants live at
`{tenant}.identity.auth.maintainerd.local` and `{tenant}.console.auth.maintainerd.local`.)

## Commands

```
./maintainerd init                                Clone the maintainerd-auth repo
./maintainerd setup                               Configure env, hosts, and trusted local HTTPS
./maintainerd up --profile=auth                   Dev: 3 apps in hot-reload (no observability)
./maintainerd up --profile=auth-release --build   Release parity: the compiled all-in-one image
./maintainerd up --profile=auth-observed -d       Dev auth + observability, detached
./maintainerd up --profile=all                    Start everything (umbrella alias)
./maintainerd down                                Stop all services
./maintainerd clean                               Stop services and remove all development data
```

`auth` and `auth-release` both bind `:80/:443` and the same `*.auth.maintainerd.local`
hosts, so run **one at a time** (`./maintainerd down` before switching). The
`auth-release` image is compiled, not hot-reloaded — re-run with `--build` to pick
up code changes.

`down` preserves database data and dependency caches for the next start.
Use `clean` only when you intentionally want to reset PostgreSQL, Redis,
RabbitMQ, frontend dependencies, Go build caches, observability data, and the
local secret cache (`.secrets/`).

### `setup` owns your `.env` (one consolidated file)

There is exactly **one** env file now: `.env-samples/maintainerd-auth.env`, which
`setup` writes to `maintainerd-auth/.env`. Because the console and identity SPAs
live in the same repo and image, there are **no separate frontend `.env` files** —
the frontends call their APIs **same-origin** (`/api/v1`, `/public-api/api/v1`), and
the one cross-app link (console → identity UI) is derived from the backend's
`APP_FRONTEND_IDENTITY_HOSTNAME`. So every variable is defined **once**, in the
backend env; there are no duplicated frontend copies to keep in sync.

The **same** `.env` drives both runtime profiles:

- `auth` — bind-mounted into the hot-reload backend; the app reads it via godotenv.
- `auth-release` — bind-mounted at `/.env` into the compiled image, read the same
  way (so the `\n`-escaped JWT PEM is parsed with real newlines, which a compose
  `env_file` cannot preserve).

A few variables are **not** in the sample on purpose, to avoid duplicates:

- `OTEL_ENABLED` — owned by the launcher and injected per profile via
  `MAINTAINERD_OTEL_ENABLED` in docker-compose (on for `auth-observed`/`all`, off
  otherwise). Dev-only container settings (`ENV`, `CGO_ENABLED`, vite `NODE_ENV`/
  `CHOKIDAR_*`) likewise live in compose, not the app env.

maintainerd-dev is the **single source of truth** for these variables. Every
`setup` run **overwrites** `maintainerd-auth/.env` from the sample — so hand-edits
to the generated `.env` are discarded. Put durable local changes in the sample.

Secrets are the exception: the JWT keypair, `APP_ENCRYPTION_KEY`,
`HMAC_SECRET_KEY`, and `SETUP_BOOTSTRAP_TOKEN` are generated once, cached in
`.secrets/` (gitignored), and appended to `maintainerd-auth/.env` on every setup
(the overwrite-then-append order means they never accumulate duplicates). They
persist across setups so tokens and encrypted data stay valid, and are wiped only
by `clean`.

## Profiles

| Profile | Services | Mode |
|---------|----------|------|
| `auth` | backend + console + identity + postgres + redis + rabbitmq + nginx | Dev — 3 apps, hot reload |
| `auth-release` | single all-in-one image + postgres + redis + rabbitmq + nginx | Release parity — compiled image |
| `auth-observed` | `auth` + Prometheus + Grafana + SigNoz | Dev + observability |
| `all` | everything; currently equivalent to `auth-observed` | Dev + observability |

`auth-release` builds `maintainerd-auth/Dockerfile` (the exact image that ships on
release, both SPAs embedded via `go:embed`) and runs it behind nginx as the TLS
edge — the production topology — on the same databases, `.env`, and URLs as dev.
Use it to confirm the compiled image works before tagging a release.

## URL scheme

Local hosts mirror the production `{tenant}.{surface}.auth.maintainerd.com`
plan, on `.local` instead of `.com`. The **tenant-less** host resolves to the
**system tenant** (the root tenant the ecosystem requires); regular tenants use
a `{tenant}.` subdomain.

| Surface | System tenant | Regular tenant |
|---------|---------------|----------------|
| Identity (login UI) | `identity.auth.maintainerd.local` | `{tenant}.identity.auth.maintainerd.local` |
| Auth console (admin) | `console.auth.maintainerd.local` | `{tenant}.console.auth.maintainerd.local` |
| Data plane API (:8081) | `identity-api.auth.maintainerd.local` | — (tenant from token/client_id) |
| Control plane API (:8080) | `console-api.auth.maintainerd.local` | — (tenant from token/client_id) |

The two API hosts are **not** tenant-scoped in the URL — the tenant is resolved
from the request (bearer token / `client_id`), never the hostname.

## Hosts (added to /etc/hosts during setup)

| Host | Routes to |
|------|-----------|
| `identity.auth.maintainerd.local`             | Identity app — system tenant (nginx → identity:3000) |
| `console.auth.maintainerd.local`     | Auth console — system tenant (nginx → console:3000) |
| `identity-api.auth.maintainerd.local`         | Data plane API (nginx → auth:8081) |
| `console-api.auth.maintainerd.local` | Control plane API (nginx → auth:8080) |
| `rabbitmq.auth.maintainerd.local`    | RabbitMQ management UI |
| `prometheus.auth.maintainerd.local`  | Prometheus (`auth-observed`) |
| `grafana.auth.maintainerd.local`     | Grafana (`auth-observed`) |
| `signoz.auth.maintainerd.local`      | SigNoz (`auth-observed`) |

`/etc/hosts` has no wildcard support, so `setup` only adds the system-tenant
hosts above. To test a regular tenant, add its subdomains manually — the
wildcard TLS cert and nginx already route them:

```
127.0.0.1 acme.auth.maintainerd.local acme.console.auth.maintainerd.local
```

All browser-facing URLs use HTTPS. `setup` creates a repository-local CA and
wildcard certificate under `.certs/` (covering `*.auth.maintainerd.local`,
`identity.auth.maintainerd.local`, and `*.console.auth.maintainerd.local`), installs the
CA into the system trust store, and configures the system-tenant hostnames.
Plain HTTP requests are redirected to HTTPS. Internal Docker traffic remains on
private networks using each service's native protocol.

Firefox Snap users must fully quit and reopen Firefox after the first `setup`.
The setup command enables Firefox system-CA trust for every local profile.

## gRPC (service-to-service, mTLS)

The auth service exposes a gRPC API on `:50051` with **mutual TLS enabled
locally**. `setup` generates the material under `.certs/grpc/` (signed by the
same local CA as HTTPS) and mounts it read-only into the container:

| File | Role | Used by |
|------|------|---------|
| `server.crt` / `server.key` | server identity | auth (`GRPC_TLS_CERT_FILE` / `GRPC_TLS_KEY_FILE`) |
| `ca.crt` | trust root for client certs | auth (`GRPC_CLIENT_CA_FILE`) |
| `client.crt` / `client.key` | caller identity | you, when calling gRPC |

Because mTLS is required, every caller must present the client cert. Test from
the host with `grpcurl`:

```bash
grpcurl \
  -cacert .certs/grpc/ca.crt \
  -cert   .certs/grpc/client.crt \
  -key    .certs/grpc/client.key \
  localhost:50051 list
```

Omitting `-cert`/`-key` is expected to fail the TLS handshake — that confirms
mTLS is enforced. To turn mTLS off for local convenience, set
`GRPC_REQUIRE_MTLS=false` in `.env-samples/maintainerd-auth.env` and re-run
`setup` (the server then serves gRPC without client-cert verification).

## Architecture

**`auth` (dev)** — nginx fronts three hot-reload containers:

```
                     nginx (HTTPS 443)
              /          |            |          \
   console-api      identity-api    console      identity
   → auth:8080      → auth:8081     → console:3000  → identity:3000

          maintainerd-auth (Go, Air hot-reload)   console / identity (vite)
              |
    ┌─────────┼─────────┐
    |         |         |
  postgres  redis   rabbitmq
```

**`auth-release`** — nginx fronts one compiled image that serves both SPAs and
routes their APIs same-origin internally (what ships on release):

```
                     nginx (HTTPS 443, TLS edge)
              /          |            |          \
   console-api      identity-api    console      identity
   → :8080          → :8081         → :3000      → :3001
              \          |            |          /
              maintainerd-auth-release (single image)
                          |
              ┌───────────┼───────────┐
            postgres    redis     rabbitmq
```

## Repositories managed

| Repo | Purpose |
|------|---------|
| `maintainerd-auth` | The whole auth product: Go backend (`:8080` control, `:8081` data) plus both SPAs under `web/console` and `web/identity`, shipped as one all-in-one image |

> The former `maintainerd-auth-console` and `maintainerd-auth-identity` repos were
> consolidated into `maintainerd-auth/web/` — their full history is preserved on the
> `archive/frontends-full-history` tag in that repo.
