# maintainerd-dev

Local development environment for the maintainerd platform. One command to clone all repos, set up configuration, and start everything.

## Quick start

```bash
# 1. Clone all repos
./maintainerd init

# 2. Create .env files + configure /etc/hosts (may prompt for sudo)
./maintainerd setup

# 3. Start everything
./maintainerd up --profile=all -d
```

Console:  http://console.auth.maintainerd.local  
Identity: http://identity.auth.maintainerd.local  

## Commands

```
./maintainerd init                    Clone all repos
./maintainerd setup                   Create .env files + configure /etc/hosts
./maintainerd up --profile=auth       Start backend + databases + nginx
./maintainerd up --profile=all        Start everything
./maintainerd up --profile=all -d     Start everything detached
./maintainerd down                    Stop all services
```

## Profiles

| Profile | Services |
|---------|----------|
| `auth`  | auth + console + identity + postgres + redis + rabbitmq + nginx |
| `all`   | auth + observability (Prometheus, Grafana) |

## Hosts (added to /etc/hosts during setup)

| Host | Routes to |
|------|-----------|
| `private-api.auth.maintainerd.local` | Internal API (nginx → auth:8080) |
| `public-api.auth.maintainerd.local`  | Public API (nginx → auth:8081) |
| `console.auth.maintainerd.local`     | Console app (nginx → console:3000) |
| `identity.auth.maintainerd.local`    | Identity app (nginx → identity:3000) |

## Architecture

```
                    nginx (port 80)
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
