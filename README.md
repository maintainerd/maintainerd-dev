# maintainerd-dev

Local development environment for the maintainerd platform. One command to clone all repos, set up configuration, and start everything.

## Quick start

```bash
# 1. Clone all repos
./maintainerd init

# 2. Create env files, configure hosts, and trust the local HTTPS CA
#    (prompts for sudo)
./maintainerd setup

# 3. Start auth with observability
./maintainerd up --profile=auth-observed -d
```

Identity: https://identity.auth.maintainerd.local

Console: https://console.auth.maintainerd.local

(These are the **system tenant** URLs. Regular tenants live at
`{tenant}.identity.auth.maintainerd.local` and `{tenant}.console.auth.maintainerd.local`.)

## Commands

```
./maintainerd init                    Clone all repos
./maintainerd setup                   Configure env, hosts, and trusted local HTTPS
./maintainerd up --profile=auth       Start auth without observability
./maintainerd up --profile=auth-observed    Start auth with observability
./maintainerd up --profile=auth-observed -d Start observed auth detached
./maintainerd up --profile=all        Start everything (umbrella alias)
./maintainerd down                    Stop all services
./maintainerd clean                   Stop services and remove all development data
```

`down` preserves database data and dependency caches for the next start.
Use `clean` only when you intentionally want to reset PostgreSQL, Redis,
RabbitMQ, frontend dependencies, Go build caches, observability data, and the
local secret cache (`.secrets/`).

### `setup` owns your `.env` files

maintainerd-dev is the **single source of truth** for local environment
variables. Every `setup` run **overwrites** each repo's `.env` from
`.env-samples/` — so hand-edits to a repo `.env` are discarded. Put durable
local changes in the sample, not the generated file.

Secrets are the exception: the JWT keypair, `APP_ENCRYPTION_KEY`, and
`HMAC_SECRET_KEY` are generated once, cached in `.secrets/` (gitignored), and
appended to `maintainerd-auth/.env` on every setup. They persist across setups
so tokens and encrypted data stay valid, and are wiped only by `clean`.

## Profiles

| Profile | Services |
|---------|----------|
| `auth` | auth + console + identity + postgres + redis + rabbitmq + nginx |
| `auth-observed` | auth + Prometheus + Grafana + SigNoz |
| `all` | everything; currently equivalent to `auth-observed` |

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

```
                     nginx (HTTPS port 443)
              /          |            |          \
   console-api      identity-api    console      identity
   → auth:8080      → auth:8081      → :3000      → :3000

          maintainerd-auth (Go)
              |
    ┌─────────┼─────────┐
    |         |         |
  postgres  redis   rabbitmq

  console (React)  → console-api.auth.maintainerd.local   (control plane)
  identity (React) → identity-api.auth.maintainerd.local           (data plane)
```

## Repositories managed

| Repo | Purpose |
|------|---------|
| `maintainerd-auth` | Go backend (dual-port: 8080 internal, 8081 public) |
| `maintainerd-auth-console` | Internal admin dashboard (React + Vite) |
| `maintainerd-auth-identity` | Public hosted login UI (React + Vite) |
