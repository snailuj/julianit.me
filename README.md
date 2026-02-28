# julianit.me

Deploy orchestrator for julianit.me subdomains. Manages git pull, build, Caddy config, systemd services, and health checks across multiple apps from a single command.

## Quick Start

```bash
deploy-julianit                    # show status of all sites
deploy-julianit senryaku           # deploy one site
deploy-julianit ALL                # deploy everything
deploy-julianit -f metaforge       # force redeploy (skip change detection)
deploy-julianit -n ALL             # dry-run — show what would happen
```

## How It Works

**Convention-based:** each app repo provides `deploy/build.sh` for its build steps. The orchestrator handles everything cross-cutting:

1. **Change detection** — git fetch + compare HEAD to origin + check build artifact freshness
2. **Git pull** (if changes detected or `--force`)
3. **Run `deploy/build.sh`** in the app's repo
4. **Manage Caddy snippet** in `/etc/caddy/conf.d/{name}.caddy`
5. **Restart systemd service** (only for changed apps)
6. **Health check** — curl the subdomain

## Adding a New Site

1. Add a `[sites.newapp]` stanza to `sites.toml`
2. Create a systemd service file for the app
3. Add `deploy/build.sh` to the app's repo
4. Run `deploy-julianit newapp`

## Configuration

All sites are defined in `sites.toml`:

```toml
[sites.myapp]
repo = "/home/agent/projects/myapp"
subdomain = "myapp.julianit.me"
service = "myapp"
port = 8001
caddy_template = "myapp"   # optional — uses custom template from templates/
```

Apps with complex Caddy configs (e.g. path-based routing, static files) use a custom template in `templates/{name}.caddy`. Simple reverse-proxy apps don't need one.

## Per-App Build Script

Each app provides `deploy/build.sh` — runs from the repo root, handles build only:

```bash
#!/usr/bin/env bash
set -euo pipefail
python3 -m venv venv
./venv/bin/pip install -e . -q
./venv/bin/alembic upgrade head
```

No Caddy, no systemd, no git — that's the orchestrator's job.

## Registered Sites

| Site | Subdomain | Stack |
|------|-----------|-------|
| senryaku | senryaku.julianit.me | FastAPI + Python |
| metaforge | metaforge.julianit.me | Go API + Vite frontend |
