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
| `maintainerd-core` | `maintainerd` | `9080` REST · `9081` gRPC | control plane — tenants/projects/resources/…, serves `core.v1` |
| `maintainerd-agent` | `maintainerd-agent` | — | executor — pulls work from Core, runs it via Docker |
| `maintainerd-secret` | `maintainerd-secret` | — | encrypted secret store — envelope-encrypted, versioned, audited (`secret.v1`) |
| `maintainerd-secret-db` | `postgres:16-alpine` | — | Secret's database |
| `maintainerd-secret-console` | `maintainerd-secret/web/console` | — (via nginx) | Secret's **own** dashboard (React/Vite) — it is adoptable alone, so it ships one |
| `maintainerd-core-db` | `postgres:16-alpine` | — | Core's database |
| `maintainerd-core-console-dev` | `maintainerd/web/console` | — (via nginx) | the platform's main dashboard (React/Vite) — **all / all-observed only** |

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

It talks to the core REST API same-origin (nginx routes `/api/` → `maintainerd-core:8080`).
The core API **enforces authorization** (see "Identity in the local stack"), and the
console cannot yet obtain a token, so it renders its blocked banner and every API
call answers 401. Pick the active tenant with the
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

`/api/` is proxied same-origin to `maintainerd-secret:8092`. Secret boots
**`authorization: ENFORCED`** — the verifier trio is set in compose — so its
permission checks apply locally and an anonymous call to `/api/v1/projects` is a
401. No SPA client exists for this console in Auth yet, so it cannot sign in;
`GET /api/v1/capabilities` reports the posture. See "Identity in the local stack".

## Startup order (auth + secret are hard dependencies of core)

**auth, core and secret start at the same time.** Core does not wait for them —
it converges toward them:

```
auth ─┐
core ─┼─ all start together (compose: condition: service_started)
secret┘

core → configures auth      via auth's gRPC SetupService
core → configures secret    via secret's gRPC SetupService, strictly after auth
```

Compose deliberately uses `condition: service_started` rather than
`service_healthy` for auth and secret. Waiting for healthy would serialise a
startup meant to be concurrent, and would deadlock the case where a dependency's
own health depends on core having configured it. Core retries with backoff
instead, so "not listening yet" is a normal early state rather than an error.

`maintainerd-core`'s healthcheck hits **`/readyz`**, not `/healthz`, because readiness is
what carries the dependency state. Four checks, and they fail independently:

| Check | Answers |
|---|---|
| `database` | can core reach its own PostgreSQL |
| `auth` | is the guard usable, and is auth reachable |
| `secret` | can core reach the vault |
| `secret-setup` | has the vault been **provisioned** |

The last two are separate on purpose: a vault that answers every network probe
but was never provisioned looks healthy and refuses every real call.

Outside development a missing `AUTH_JWKS_URL`, `AUTH_ISSUER`, `AUTH_AUDIENCE`,
`AUTH_TOKEN_URL` or `SECRET_BASE_URL` is a **boot error naming them all at
once**. `APP_ENV=development` downgrades that to a warning so you can work on one
service alone — but the guards open, and any provision needing secret material
still fails closed rather than silently writing a credential into a container's
environment.

**If secret is down:** core still boots and serves, existing workloads keep
running, and the console answers. `/readyz` reports not-ready and provisioning
that needs secret material refuses. A vault outage is not a control-plane outage.

## Verify the loop end-to-end

```bash
docker compose --profile maintainerd ps   # Core, Agent, Secret (+ their DBs and consoles)
curl localhost:9080/healthz               # {"status":"ok"}  — liveness
curl localhost:9080/readyz | jq           # readiness, incl. auth/secret/secret-setup

# create a resource; Core -> Agent -> Docker will run it, then report back
B=http://localhost:9080/api/v1
TEN=$(curl -s -XPOST $B/tenants  -d '{"name":"system","is_system":true}'          | jq -r .data.tenant_uuid)
PRJ=$(curl -s -XPOST $B/projects -d "{\"tenant_uuid\":\"$TEN\",\"name\":\"default\"}" | jq -r .data.project_uuid)
RES=$(curl -s -XPOST $B/resources -d "{\"project_uuid\":\"$PRJ\",\"kind\":\"container\",\"name\":\"web\",\"spec\":{\"image\":\"nginx:alpine\",\"name\":\"maintainerd-web\"}}" | jq -r .data.resource_uuid)

sleep 8
curl -s $B/resources/$RES | jq '.data | {state, observed_generation, status}'  # state: "running"
docker ps --filter name=maintainerd-web                                                # the container the stack ran
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
| `CORE_ADDR` | agent | Core AgentGateway (`maintainerd-core:8081`) |
| `GRPC_PORT` / `HTTP_PORT` | each | per-service listen ports |
| `AUTH_JWKS_URL` / `AUTH_ISSUER` / `AUTH_AUDIENCE` | core, secret | the inbound bearer-token verifier — see below |
| `AUTH_TOKEN_URL` | core | where core mints its own outbound tokens |
| `CORE_SETUP_TOKEN` | core | gates `POST /api/v1/setup`, which bypasses the bearer guard |

## Identity in the local stack

**Both APIs enforce authorization here. An unauthenticated request is refused.**
That is deliberate: `APP_ENV=development` lets these services fall back to a
guard-open mode where every caller is treated as a blanket administrator, and for
a control plane and a secret vault that is not a mode worth having on a laptop.

### The verifier trio

Core and Secret each verify inbound bearer tokens from three values. They are
all-or-nothing — a JWKS URL with no issuer/audience check accepts any token Auth
ever signed, so both services refuse a partial set at boot.

| Var | Form | Why |
|-----|------|-----|
| `AUTH_JWKS_URL` | `http://maintainerd-auth:8081/.well-known/jwks.json` — **internal** | The service *fetches* it, so it must resolve on the compose network. JWKS is on `:8081` only; `:8080`/`:8082` answer 404. Auth has **no TLS listener** — nginx is the TLS edge — so this hop is plain HTTP. **Development only**; production points this at the https public URL or terminates inside a mesh that provides mTLS. |
| `AUTH_ISSUER` | `https://identity-api.auth.maintainerd.local` — **public** | *String-compared* against the `iss` claim, never dialled. Must be byte-identical to what Auth stamps, i.e. Auth's `APP_PUBLIC_HOSTNAME`. |
| `AUTH_AUDIENCE` | `https://core.maintainerd.local` / `https://secret.maintainerd.local` — **public** | *String-compared* against `aud`. It is the `apis.identifier` registered in Auth for that service, not an endpoint — nothing fetches it. |

The internal/public split is the part that reads like a mistake and is not: one is
an address, two are claim values.

`AUTH_TOKEN_URL` (core only) is both — core POSTs to it *and* signs that exact
string as the `aud` of its `private_key_jwt` client assertion, and Auth accepts an
assertion audience only from its own `APP_PUBLIC_HOSTNAME` set. So it is the public
form, and core mounts `.certs/` with `SSL_CERT_FILE` to trust the local CA on that
https hop.

### Confirming the guard is on

```bash
curl -s -o /dev/null -w '%{http_code}\n' http://localhost:9080/api/v1/tenants
# 401 = enforced.  200 = the guard is OPEN — stop and fix the trio.

curl -sk https://console-api.secret.maintainerd.local/api/v1/capabilities
# "guard_mode":"enforced"

curl -s http://localhost:9080/readyz     # {"status":"ready"} — includes the auth dependency
```

Boot logs must contain **neither** `AUTHORIZATION IS DISABLED` /
`API is UNAUTHENTICATED` nor `Failed to refresh HTTP JWK Set`. Note the asymmetry:
a wrong `AUTH_JWKS_URL` still logs `ENFORCED` and boots — the JWKS fetch is lazy
with a 1h retry — and then 401s every call. The refresh error is the only signal.

### If sign-in fails

Neither console can sign in yet, and the blocker is in Auth's code, not in this
compose file. `internal/oauth/service_authorize.go` → `isSeededSurfaceClient`
allows a **system** client to drive a public authorize request only when its name
is `auth-console` or `auth-identity`. Core's setup registers its console as
`maintainerd-console` with `is_system = true`, so `/api/v1/oauth/authorize`
answers `400 invalid_request "unknown or inactive client context"` for it — and
would for any other console added the same way.

Two further gaps sit behind that one:

- **No audience grant.** `client_apis` is empty, so no client may request
  `audience=https://core.maintainerd.local`. Without the parameter Auth mints
  `aud = <the client's own client_id>`, which the service then rejects. Granting it
  is `POST /api/v1/clients/{uuid}/apis` on Auth's console API, which requires
  `client:api:create` **plus step-up (ACR 2)** — an MFA'd session, so it is a
  console-UI step, not a scriptable one.
- **No SPA client for Secret's console at all.** Core's setup registers exactly one
  console client (its own), and the steward catalog
  (`maintainerd/internal/steward/builtin.go`) has no console-client kind — only
  Service, ResourceAPI, ServiceClient (m2m `private_key_jwt`) and ServicePolicy.

So the consoles are wired but parked, and the compose defaults say so honestly:
`VITE_OAUTH_CLIENT_ID` is **empty**, which makes each console render its
"cannot obtain a token" banner instead of bouncing the browser to `/authorize` for
a client that will be refused. Do not paper over this by clearing the trio — that
reopens the guard on a vault to make a UI look better.

Once a usable client exists, point a console at it without a rebuild:

```bash
export MAINTAINERD_CORE_CONSOLE_CLIENT_ID=<client_id from Auth>
export MAINTAINERD_SECRET_CONSOLE_CLIENT_ID=<client_id from Auth>
./maintainerd up --profile=all -d
```

Read the ids you already have with:

```bash
docker exec postgres-db psql -U devuser -d maintainerd \
  -c "select name, identifier, client_type, is_system from clients order by client_id;"
```

`identifier` is the `client_id` — a public value, not a credential.

The console's `VITE_OAUTH_ISSUER_URL` is `https://identity.auth.maintainerd.local`,
which is **not** the service's `AUTH_ISSUER`. The SPA appends `/authorize` and
`/end-session`, and those are pages on the identity **app**; `AUTH_ISSUER` is the
API origin that appears in the `iss` claim. Same authorization server, two
hostnames. (`web/console/src/services/api/config.ts` claims the two are the same
value; in this stack they are not.)

## Known limitations (dev stack)

- **Secret runs standalone, not Core-attached** — `MAINTAINERD_MODE` stays
  `standalone` even under `all`. Core provisions Secret's IAM records in Auth,
  but nothing yet drives Secret's own gRPC `SetupService`, and `core` mode closes
  its REST setup wizard — so flipping it now would leave no bootstrap path.
  Override with `MAINTAINERD_SECRET_MODE=core` once that lands.
- **Neither console can sign in** — both APIs enforce, but Auth refuses a public
  authorize request from any system client other than its own two seeded SPAs, and
  no audience grant exists. See "If sign-in fails" above. Work against the APIs
  with a token you mint yourself until that lands.
- **Secret's own client credentials are placeholders** — `SECRET_CLIENT_ID` /
  `SECRET_CLIENT_SECRET` satisfy a presence check and nothing more: secret has no
  outbound token code yet, and the real credential cannot be supplied anyway
  because Core's steward mints secret's keypair as `private_key_jwt` and writes the
  private key to its own `STEWARD_KEY_DIR` with no handoff to secret's container.
  `SECRET_ROOT_KEY` is a fixed dev value.
- **JWKS is fetched over plain HTTP on the compose network** — Auth serves no TLS
  (nginx is the edge) and core/secret ship from distroless without the local CA.
  Development only; see "Identity in the local stack".
- **No mTLS between services on the REST path** — plaintext gRPC on the compose
  network apart from the setup/control channels, which do use the local CA.
- **`maintainerd-agent` runs as root** to read the mounted host socket (dev convenience) — the docker runtime driver is compiled into the agent.
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
| `console.maintainerd.local`          | Core console — the platform dashboard (nginx → `maintainerd-core-console:3000`) |
| `console-api.maintainerd.local`      | Core REST API (nginx → `maintainerd-core:8080`) |
| `console.secret.maintainerd.local`   | **Secret console** (nginx → `maintainerd-secret-console:3000`, `/api/` → `maintainerd-secret:8092`) |
| `console-api.secret.maintainerd.local` | Secret REST API (nginx → `maintainerd-secret:8092`) |

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
