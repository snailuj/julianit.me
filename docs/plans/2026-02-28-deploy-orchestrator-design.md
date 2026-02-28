# julianit.me Deploy Orchestrator — Design

**Date:** 2026-02-28
**Goal:** Single deploy script that manages all julianit.me subdomains. Convention-based: each app provides `deploy/build.sh`, orchestrator handles git, change detection, Caddy, systemd, health checks.

## Architecture

Central config (`sites.toml`) defines registered apps. Orchestrator reads it, detects changes, calls per-repo build scripts, manages Caddy snippets and systemd services.

## Config Format (sites.toml)

```toml
[caddy]
service = "julianit-caddy"
conf_dir = "/etc/caddy/conf.d"

[sites.senryaku]
repo = "/home/agent/projects/dojo/senryaku"
subdomain = "senryaku.julianit.me"
service = "senryaku"
port = 8000

[sites.metaforge]
repo = "/home/agent/projects/metaforge/.worktrees/feat--second-order-graph"
subdomain = "metaforge.julianit.me"
service = "metaforge-api"
port = 8080
caddy_template = "metaforge"
```

## CLI Interface

```
deploy.sh [OPTIONS] [SITE...]

Positional:
  SITE...              Sites to deploy (names from sites.toml). Use ALL for everything.
                       If omitted, shows --status.

Options:
  -f, --force          Skip change detection, always rebuild and restart
  -s, --status         Show status of all registered sites
  -n, --dry-run        Show what would be done without doing it
  -h, --help           Show help and exit
  -V, --version        Show version and exit
```

## Per-App Deploy Steps

1. **Change detection** — git fetch, compare HEAD vs origin, check build artifacts vs source age
2. **Git pull** (if changes detected or --force)
3. **Run `deploy/build.sh`** from app repo root
4. **Generate Caddy snippet** in `/etc/caddy/conf.d/{name}.caddy`
5. **Ensure systemd service** exists and matches config
6. **Reload Caddy** (once, after all apps)
7. **Restart app service** (only changed apps)
8. **Health check** — curl subdomain, report pass/fail

## Change Detection

App needs redeploying if ANY of:
- Local HEAD != origin HEAD after fetch
- Build artifacts missing (no venv/binary)
- Build artifacts older than latest source commit timestamp
- `--force` flag

## Repo Structure

```
julianit.me/
├── deploy.sh
├── sites.toml
├── templates/
│   └── metaforge.caddy
└── README.md
```

## Per-App Convention

Each app provides `deploy/build.sh` — runs from repo root, handles build only. No Caddy, no systemd.
