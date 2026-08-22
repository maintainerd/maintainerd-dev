# maintainerd-dev

Local development environment for the maintainerd platform. One command to clone the repo, set up configuration, and start everything.

Auth is now a **single repo** (`maintainerd-auth`) containing the Go backend and
both SPAs (`web/console`, `web/identity`). In dev you run the three as hot-reload
containers (`auth` profile); to test the compiled single all-in-one image the way
it ships, use the `auth-release` profile.

> **One compose file, selected by profile.** The **maintainerd core stack** and
> the **auth stack** both live in `docker-compose.yml`; you pick a slice with
> `--profile`. The core stack runs under `maintainerd` (core only), `all` (auth +
> core, no observability), or `all-observed` (everything + Prometheus/Grafana/SigNoz).
> The `auth*` profiles are documented under *Auth stack* further down. Always drive
> it through the `./maintainerd` launcher — never a raw `docker compose`.

# maintainerd core stack

The control-plane suite — **Core + Agent (docker driver compiled in) + Secret + Postgres** — in one
command. Use this to confirm the whole platform runs and the control loop turns.

## Run everything

```bash
# core stack only (Core + Agent + Secret + its Postgres)
./maintainerd up --profile=maintainerd -d --build

# auth + core together, no observability
./maintainerd up --profile=all -d --build

# everything, including observability (Prometheus + Grafana + SigNoz)
./maintainerd up --profile=all-observed -d --build
```

First run builds the service images from source (a few minutes); later runs reuse
the cache. Tear it down with `./maintainerd down` (or `./maintainerd clean` to also
drop volumes). Observability lives only under the `-observed` profiles — `maintainerd`
and `all` stay observability-free.

## What runs

| Service | Built from | Host ports | Role |
|---------|-----------|-----------|------|
| `m9d-core` | `maintainerd` | `9080` REST · `9081` gRPC | control plane — tenants/projects/resources/…, serves `core.v1` |
| `m9d-agent` | `maintainerd-agent` | — | executor — pulls work from Core, runs it via Docker |
| `m9d-secret` | `maintainerd-secret` | — | encrypted secret store — envelope-encrypted, versioned, audited (`secret.v1`) |
| `m9d-secret-db` | `postgres:16-alpine` | — | Secret's database |
| `m9d-secret-console` | `maintainerd-secret/web/console` | — (via nginx) | Secret's **own** dashboard (React/Vite) — it is adoptable alone, so it ships one |
| `m9d-core-db` | `postgres:16-alpine` | — | Core's database |
| `m9d-core-console-dev` | `maintainerd/web/console` | — (via nginx) | the platform's main dashboard (React/Vite) — **all / all-observed only** |

Only Core publishes ports to the host; the rest talk over the compose network.
**Workload containers** the stack runs (e.g. an `nginx` you ask Core for) appear
on the **host** Docker engine, because the agent's compiled-in docker driver uses the mounted host socket.

## Core console (main dashboard)

The control-plane UI, modelled on the auth console. It runs under the **`all`** and
**`all-observed`** profiles (it needs nginx as the TLS edge, which those profiles
start), served hot-reloaded through nginx at:

```
https://console.maintainerd.local
```

It talks to the core REST API same-origin (nginx routes `/api/` → `m9d-core:8080`).
The console has **no login yet** — it boots straight to the dashboard, because the
core control plane currently requires no auth. Pick the active tenant with the
top-bar switcher; projects/services/providers/agents are scoped to it, and
resources live under a project. Run `./maintainerd setup` once so `/etc/hosts` and
the local TLS cert (now covering `*.maintainerd.local`) include the console host.

### Secret console

Secret ships a console of its own — it is adoptable alone, so it does not live
inside Core's. Same profiles (`all`, `all-observed`, and `maintainerd`), served
through nginx at:

```
https://console.secret.maintainerd.local
```

`/api/` is proxied same-origin to `m9d-secret:8092`. In dev, Secret boots
**guard-open** with a loud banner — no `AUTH_*` or client credentials are set —
so its permission checks are not enforced locally and the console needs no
sign-in. Enforcing them locally means giving Secret a real Auth issuer/audience
and creating its two clients; the runbook for that is in Secret's own docs.

## Verify the loop end-to-end

```bash
docker compose --profile maintainerd ps   # Core, Agent, Secret (+ their DBs and consoles)
curl localhost:9080/healthz               # {"status":"ok"}

# create a resource; Core -> Agent -> Docker will run it, then report back
B=http://localhost:9080/api/v1
TEN=$(curl -s -XPOST $B/tenants  -d '{"name":"system","is_system":true}'          | jq -r .data.tenant_uuid)
PRJ=$(curl -s -XPOST $B/projects -d "{\"tenant_uuid\":\"$TEN\",\"name\":\"default\"}" | jq -r .data.project_uuid)
RES=$(curl -s -XPOST $B/resources -d "{\"project_uuid\":\"$PRJ\",\"kind\":\"container\",\"name\":\"web\",\"spec\":{\"image\":\"nginx:alpine\",\"name\":\"m9d-web\"}}" | jq -r .data.resource_uuid)

sleep 8
curl -s $B/resources/$RES | jq '.data | {state, observed_generation, status}'  # state: "running"
docker ps --filter name=m9d-web                                                # the container the stack ran
```

```
Core (decides)  --PullWork-->  Agent (executes)  --Run-->  Docker (runs container)
      ^                                                            |
      +----------------------- ReportStatus ------------------------+
```

## How the images build (multi-repo)

The services live in separate repos that reference each other via local `go.mod`
`replace` directives. `build/Dockerfile` builds any service from the **parent
directory** as the build context (so the sibling modules are present and the
replaces resolve); `build/Dockerfile.dockerignore` trims that context to just the
Go modules; `GOTOOLCHAIN=auto` lets the build fetch the exact Go toolchain the
modules pin.

> A Go workspace (`go.work`) is intentionally **not** used for the container build
> — it unified dependency versions across modules and broke Core's OpenTelemetry
> setup. The per-module `replace` directives are the mechanism.

## Config (env, set in `docker-compose.yml`)

| Var | Service | Purpose |
|-----|---------|---------|
| `DB_*` | core | Postgres connection; `DB_PASSWORD` resolves via `SECRET_PROVIDER` |
| `SECRET_PROVIDER` | all | secret source, default `env` |
| `SECRET_ROOT_KEY` | secret | 32-byte AES-256 root key for the store (dev value in compose) |
| `SETUP_BOOTSTRAP_TOKEN` | secret | gates the one-time `Setup` (controller registration) |
| `CORE_ADDR` | agent | Core AgentGateway (`m9d-core:8081`) |
| `GRPC_PORT` / `HTTP_PORT` | each | per-service listen ports |

## Known limitations (dev stack)

- **Secret runs standalone, not Core-attached** — `MAINTAINERD_MODE` stays
  `standalone` even under `all`. Core provisions Secret's IAM records in Auth,
  but nothing yet drives Secret's own gRPC `SetupService`, and `core` mode closes
  its REST setup wizard — so flipping it now would leave no bootstrap path.
  Override with `MAINTAINERD_SECRET_MODE=core` once that lands.
- **Secret's guards are dev-open** — no `AUTH_*` or client credentials are set,
  so it boots with the loud guard-open banner and its permission checks are not
  enforced locally. `SECRET_ROOT_KEY` is a fixed dev value.
- **No TLS/auth between services** — plaintext gRPC on the compose network; mTLS
  and system-Auth enforcement are not wired yet.
- **`m9d-agent` runs as root** to read the mounted host socket (dev convenience) — the docker runtime driver is compiled into the agent.
- **Auth co-runs but isn't wired to Core yet** — the `all`/`all-observed` profiles
  start Auth alongside the core stack, but Core does not yet provision or govern it.
  Running Auth as a Core-controlled system service (system-Auth / IAM) is the next
  integration.

---

# Auth stack

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
./maintainerd up --profile=maintainerd -d         Core stack only (Core + Agent + Secret)
./maintainerd up --profile=all -d                 Auth + core stack, no observability
./maintainerd up --profile=all-observed -d        Everything + observability (Prometheus/Grafana/SigNoz)
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
| `console.maintainerd.local`          | Core console — the platform dashboard (nginx → `m9d-core-console:3000`) |
| `console-api.maintainerd.local`      | Core REST API (nginx → `m9d-core:8080`) |
| `console.secret.maintainerd.local`   | **Secret console** (nginx → `m9d-secret-console:3000`, `/api/` → `m9d-secret:8092`) |
| `console-api.secret.maintainerd.local` | Secret REST API (nginx → `m9d-secret:8092`) |

Secret's console lives on its own host rather than inside Core's, because Secret
is adoptable alone — an organization can run just it plus Auth. Note the extra
label: a TLS wildcard matches exactly one, so `*.maintainerd.local` does **not**
cover `console.secret.…` and `setup` issues a `*.secret.maintainerd.local` SAN
for it.

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
