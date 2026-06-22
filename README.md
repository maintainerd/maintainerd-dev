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

Console: https://console.auth.maintainerd.local

Identity: https://identity.auth.maintainerd.local

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
RabbitMQ, frontend dependencies, Go build caches, and observability data.

## Profiles

| Profile | Services |
|---------|----------|
| `auth` | auth + console + identity + postgres + redis + rabbitmq + nginx |
| `auth-observed` | auth + Prometheus + Grafana + SigNoz |
| `all` | everything; currently equivalent to `auth-observed` |

## Hosts (added to /etc/hosts during setup)

| Host | Routes to |
|------|-----------|
| `private-api.auth.maintainerd.local` | Internal API (nginx → auth:8080) |
| `public-api.auth.maintainerd.local`  | Public API (nginx → auth:8081) |
| `console.auth.maintainerd.local`     | Console app (nginx → console:3000) |
| `identity.auth.maintainerd.local`    | Identity app (nginx → identity:3000) |
| `rabbitmq.auth.maintainerd.local`    | RabbitMQ management UI |
| `prometheus.auth.maintainerd.local`  | Prometheus (`auth-observed`) |
| `grafana.auth.maintainerd.local`     | Grafana (`auth-observed`) |
| `signoz.auth.maintainerd.local`      | SigNoz (`auth-observed`) |

All browser-facing URLs use HTTPS. `setup` creates a repository-local CA and
wildcard certificate under `.certs/`, installs the CA into the system trust
store, and configures the required local hostnames. Plain HTTP requests are
redirected to HTTPS. Internal Docker traffic remains on private networks using
each service's native protocol.

Firefox Snap users must fully quit and reopen Firefox after the first `setup`.
The setup command enables Firefox system-CA trust for every local profile.

## Architecture

```
                nginx (HTTPS port 443)
                   /    |    |    \
    private-api    public-api  console  identity
    → auth:8080   → auth:8081  → :3000  → :3000

          maintainerd-auth (Go)
              |
    ┌─────────┼─────────┐
    |         |         |
  postgres  redis   rabbitmq

  console (React)  → private-api.auth.maintainerd.local
  identity (React) → public-api.auth.maintainerd.local
```

## Repositories managed

| Repo | Purpose |
|------|---------|
| `maintainerd-auth` | Go backend (dual-port: 8080 internal, 8081 public) |
| `maintainerd-auth-console` | Internal admin dashboard (React + Vite) |
| `maintainerd-auth-identity` | Public hosted login UI (React + Vite) |
