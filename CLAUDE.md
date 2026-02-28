# julianit.me

Deploy orchestrator for julianit.me subdomains.

## Structure
- `deploy.sh` — main orchestrator, symlinked to `/usr/local/bin/deploy-julianit`
- `sites.toml` — registered sites config
- `templates/` — custom Caddy templates (most apps use default reverse_proxy)

## Convention
- Each app provides `deploy/build.sh` (build only, no infra)
- Orchestrator manages git, Caddy, systemd, health checks
- Caddy snippets live in `/etc/caddy/conf.d/{name}.caddy`
- One shared Caddy process serves all subdomains

## Test
```bash
deploy-julianit -n ALL    # dry-run
deploy-julianit           # show status
```
