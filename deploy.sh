#!/usr/bin/env bash
# deploy.sh — Deploy orchestrator for julianit.me subdomains
# https://github.com/snailuj/julianit.me

set -euo pipefail

VERSION="1.0.0"
SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
CONFIG="${SCRIPT_DIR}/sites.toml"
TEMPLATES_DIR="${SCRIPT_DIR}/templates"

# Colours
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m'

# ---------------------------------------------------------------------------
# Usage
# ---------------------------------------------------------------------------

usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTION]... [SITE]...

Deploy one or more julianit.me subdomains. Each SITE corresponds to a
[sites.NAME] stanza in sites.toml. Use ALL to deploy every registered site.

If no SITE is given and no option is specified, --status is implied.

Examples:
  $(basename "$0") senryaku              Deploy senryaku only
  $(basename "$0") metaforge senryaku    Deploy both
  $(basename "$0") ALL                   Deploy all registered sites
  $(basename "$0") -f senryaku           Force redeploy (skip change detection)
  $(basename "$0") -s                    Show status of all sites

Options:
  -f, --force          skip change detection; always rebuild and restart
  -s, --status         show status of all registered sites and exit
  -n, --dry-run        show what would be done without doing it
  -h, --help           display this help and exit
  -V, --version        output version information and exit

Configuration:
  Sites are defined in ${CONFIG}.
  Each app repo must provide deploy/build.sh for its build steps.
  Caddy snippets are managed in /etc/caddy/conf.d/.

Report bugs to: https://github.com/snailuj/julianit.me/issues
EOF
}

version() {
    echo "deploy.sh (julianit.me) ${VERSION}"
}

# ---------------------------------------------------------------------------
# TOML parser (minimal, handles flat keys and [section.subsection])
# ---------------------------------------------------------------------------

# Read a key from a TOML section.
# Usage: toml_get <file> <section> <key>
toml_get() {
    local file="$1" section="$2" key="$3"
    awk -v section="[$section]" -v key="$key" '
        BEGIN { in_section=0 }
        /^\[/ {
            in_section = ($0 == section) ? 1 : 0
            next
        }
        in_section && $0 ~ "^"key"[[:space:]]*=" {
            sub(/^[^=]*=[[:space:]]*/, "")
            gsub(/^"|"$/, "")
            print
            exit
        }
    ' "$file"
}

# List all site names from [sites.*] sections.
toml_list_sites() {
    local file="$1"
    grep -oP '^\[sites\.\K[^\]]+' "$file"
}

# ---------------------------------------------------------------------------
# Change detection
# ---------------------------------------------------------------------------

# Returns 0 if site needs redeploying, 1 if up-to-date.
needs_deploy() {
    local name="$1" repo="$2"

    if [[ ! -d "${repo}/.git" && ! -f "${repo}/.git" ]]; then
        log "$name" "not a git repo — skipping change detection"
        return 0
    fi

    # Fetch latest from remote
    if ! git -C "$repo" fetch --quiet 2>/dev/null; then
        log "$name" "${YELLOW}fetch failed — deploying anyway${NC}"
        return 0
    fi

    local local_head remote_head
    local_head=$(git -C "$repo" rev-parse HEAD 2>/dev/null)
    remote_head=$(git -C "$repo" rev-parse '@{u}' 2>/dev/null || echo "unknown")

    if [[ "$remote_head" == "unknown" ]]; then
        log "$name" "${YELLOW}no upstream tracking — deploying${NC}"
        return 0
    fi

    if [[ "$local_head" != "$remote_head" ]]; then
        local behind
        behind=$(git -C "$repo" rev-list --count HEAD..'@{u}' 2>/dev/null || echo "?")
        log "$name" "git: ${behind} commit(s) behind origin"
        return 0
    fi

    # Check if build artifacts exist
    if [[ -f "${repo}/deploy/build.sh" ]]; then
        # Check for common build outputs
        local source_ts artifact_ts
        source_ts=$(git -C "$repo" log -1 --format='%ct' 2>/dev/null || echo 0)

        # Python projects: check venv
        if [[ -f "${repo}/pyproject.toml" && ! -d "${repo}/venv" ]]; then
            log "$name" "build artifact missing (no venv)"
            return 0
        fi

        # Check if venv/binary is older than latest commit
        if [[ -d "${repo}/venv" ]]; then
            artifact_ts=$(stat -c '%Y' "${repo}/venv" 2>/dev/null || echo 0)
            if (( artifact_ts < source_ts )); then
                log "$name" "build artifacts stale (older than source)"
                return 0
            fi
        fi

        # Go projects: check binary
        if [[ -f "${repo}/go.mod" ]]; then
            local binary
            binary=$(find "${repo}" -maxdepth 3 -name "$(basename "$repo")" -type f -executable 2>/dev/null | head -1)
            if [[ -z "$binary" ]]; then
                log "$name" "build artifact missing (no binary)"
                return 0
            fi
            artifact_ts=$(stat -c '%Y' "$binary" 2>/dev/null || echo 0)
            if (( artifact_ts < source_ts )); then
                log "$name" "build artifacts stale (older than source)"
                return 0
            fi
        fi
    fi

    return 1
}

# ---------------------------------------------------------------------------
# Caddy config generation
# ---------------------------------------------------------------------------

generate_caddy_snippet() {
    local name="$1" subdomain="$2" port="$3" repo="$4"
    local template_name caddy_conf_dir snippet

    template_name=$(toml_get "$CONFIG" "sites.${name}" "caddy_template")
    caddy_conf_dir=$(toml_get "$CONFIG" "caddy" "conf_dir")
    caddy_conf_dir="${caddy_conf_dir:-/etc/caddy/conf.d}"
    snippet="${caddy_conf_dir}/${name}.caddy"

    local new_content
    if [[ -n "$template_name" && -f "${TEMPLATES_DIR}/${template_name}.caddy" ]]; then
        new_content=$(sed -e "s|{{PORT}}|${port}|g" -e "s|{{SUBDOMAIN}}|${subdomain}|g" -e "s|{{REPO}}|${repo}|g" \
            "${TEMPLATES_DIR}/${template_name}.caddy")
    else
        new_content="${subdomain} {
    reverse_proxy 127.0.0.1:${port}
}"
    fi

    # Only write if changed
    if [[ -f "$snippet" ]] && echo "$new_content" | diff -q - "$snippet" > /dev/null 2>&1; then
        return 1  # no change
    fi

    if [[ "$DRY_RUN" == "true" ]]; then
        log "$name" "${BLUE}[dry-run]${NC} would update ${snippet}"
        return 0
    fi

    echo "$new_content" | sudo tee "$snippet" > /dev/null
    return 0
}

# ---------------------------------------------------------------------------
# Systemd service management
# ---------------------------------------------------------------------------

ensure_service() {
    local name="$1" service="$2"
    local service_file="/etc/systemd/system/${service}.service"

    if [[ ! -f "$service_file" ]]; then
        log "$name" "${YELLOW}warning: systemd service ${service} not found${NC}"
        log "$name" "create it manually or add a deploy/service.conf to the repo"
        return 1
    fi
    return 0
}

restart_service() {
    local name="$1" service="$2"

    if [[ "$DRY_RUN" == "true" ]]; then
        log "$name" "${BLUE}[dry-run]${NC} would restart ${service}"
        return 0
    fi

    sudo systemctl restart "$service"
    sleep 2

    if sudo systemctl is-active --quiet "$service"; then
        log "$name" "${GREEN}service ${service} running${NC}"
    else
        log "$name" "${RED}service ${service} FAILED to start${NC}"
        sudo journalctl -u "$service" --no-pager -n 5 2>&1 | while read -r line; do
            echo "         $line"
        done
        return 1
    fi
}

# ---------------------------------------------------------------------------
# Health check
# ---------------------------------------------------------------------------

health_check() {
    local name="$1" subdomain="$2"
    local url="https://${subdomain}/"
    local code

    code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "$url" 2>/dev/null || echo "000")

    if [[ "$code" =~ ^[23] ]]; then
        log "$name" "${GREEN}health OK${NC} — https://${subdomain}/ → HTTP ${code}"
    else
        log "$name" "${RED}health FAIL${NC} — https://${subdomain}/ → HTTP ${code}"
    fi
}

# ---------------------------------------------------------------------------
# Status display
# ---------------------------------------------------------------------------

show_status() {
    local sites
    sites=$(toml_list_sites "$CONFIG")

    printf "\n${BOLD}%-15s %-30s %-15s %s${NC}\n" "SITE" "SUBDOMAIN" "SERVICE" "STATUS"
    printf "%-15s %-30s %-15s %s\n" "----" "---------" "-------" "------"

    for name in $sites; do
        local subdomain service status
        subdomain=$(toml_get "$CONFIG" "sites.${name}" "subdomain")
        service=$(toml_get "$CONFIG" "sites.${name}" "service")
        status=$(sudo systemctl is-active "$service" 2>/dev/null || true)
        [[ -z "$status" ]] && status="inactive"

        local colour="$RED"
        [[ "$status" == "active" ]] && colour="$GREEN"

        printf "%-15s %-30s %-15s %b\n" "$name" "$subdomain" "$service" "${colour}${status}${NC}"
    done
    echo ""
}

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------

log() {
    local name="$1"
    shift
    echo -e "  ${BOLD}[${name}]${NC} $*"
}

# ---------------------------------------------------------------------------
# Deploy a single site
# ---------------------------------------------------------------------------

deploy_site() {
    local name="$1"
    local repo subdomain service port

    repo=$(toml_get "$CONFIG" "sites.${name}" "repo")
    subdomain=$(toml_get "$CONFIG" "sites.${name}" "subdomain")
    service=$(toml_get "$CONFIG" "sites.${name}" "service")
    port=$(toml_get "$CONFIG" "sites.${name}" "port")

    if [[ -z "$repo" || -z "$subdomain" || -z "$service" || -z "$port" ]]; then
        log "$name" "${RED}incomplete config in sites.toml${NC}"
        return 1
    fi

    if [[ ! -d "$repo" ]]; then
        log "$name" "${RED}repo not found: ${repo}${NC}"
        return 1
    fi

    echo ""
    log "$name" "${BOLD}deploying ${subdomain}${NC}"

    # 1. Change detection
    if [[ "$FORCE" != "true" ]]; then
        if ! needs_deploy "$name" "$repo"; then
            log "$name" "${GREEN}up-to-date — skipping${NC}"
            return 0
        fi
    else
        log "$name" "forced deploy"
    fi

    # 2. Git pull
    if [[ "$DRY_RUN" == "true" ]]; then
        log "$name" "${BLUE}[dry-run]${NC} would git pull in ${repo}"
    else
        if git -C "$repo" pull --ff-only 2>/dev/null; then
            log "$name" "git pull OK"
        else
            log "$name" "${YELLOW}git pull skipped (not fast-forward or no remote)${NC}"
        fi
    fi

    # 3. Run build script
    local build_script="${repo}/deploy/build.sh"
    if [[ -f "$build_script" ]]; then
        if [[ "$DRY_RUN" == "true" ]]; then
            log "$name" "${BLUE}[dry-run]${NC} would run ${build_script}"
        else
            log "$name" "running build script..."
            if (cd "$repo" && bash deploy/build.sh); then
                log "$name" "${GREEN}build OK${NC}"
            else
                log "$name" "${RED}build FAILED${NC}"
                return 1
            fi
        fi
    else
        log "$name" "${YELLOW}no deploy/build.sh found — skipping build${NC}"
    fi

    # 4. Caddy snippet
    if generate_caddy_snippet "$name" "$subdomain" "$port" "$repo"; then
        CADDY_CHANGED=true
        log "$name" "caddy config updated"
    fi

    # 5. Ensure systemd service exists
    ensure_service "$name" "$service" || return 1

    # 6. Restart service
    restart_service "$name" "$service" || return 1

    # 7. Health check
    health_check "$name" "$subdomain"

    DEPLOYED+=("$name")
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

FORCE=false
DRY_RUN=false
STATUS=false
SITES=()
DEPLOYED=()
CADDY_CHANGED=false

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        -h|--help)    usage; exit 0 ;;
        -V|--version) version; exit 0 ;;
        -f|--force)   FORCE=true; shift ;;
        -n|--dry-run) DRY_RUN=true; shift ;;
        -s|--status)  STATUS=true; shift ;;
        -*)           echo "$(basename "$0"): unrecognised option '$1'" >&2
                      echo "Try '$(basename "$0") --help' for more information." >&2
                      exit 1 ;;
        *)            SITES+=("$1"); shift ;;
    esac
done

# Validate config exists
if [[ ! -f "$CONFIG" ]]; then
    echo "Error: config not found at ${CONFIG}" >&2
    exit 1
fi

# Status mode (default if no sites given)
if [[ "$STATUS" == "true" ]] || [[ ${#SITES[@]} -eq 0 && "$FORCE" == "false" && "$DRY_RUN" == "false" ]]; then
    show_status
    exit 0
fi

# Expand ALL
if [[ ${#SITES[@]} -eq 1 && "${SITES[0]}" == "ALL" ]]; then
    mapfile -t SITES < <(toml_list_sites "$CONFIG")
fi

# Validate site names
all_sites=$(toml_list_sites "$CONFIG")
for site in "${SITES[@]}"; do
    if ! echo "$all_sites" | grep -qx "$site"; then
        echo "Error: unknown site '${site}'. Registered sites:" >&2
        echo "$all_sites" | sed 's/^/  /' >&2
        exit 1
    fi
done

echo ""
echo -e "${BOLD}==> julianit.me deploy${NC}"
[[ "$DRY_RUN" == "true" ]] && echo -e "    ${BLUE}(dry-run mode)${NC}"
[[ "$FORCE" == "true" ]] && echo -e "    ${YELLOW}(forced)${NC}"

# Deploy each site
ERRORS=0
for site in "${SITES[@]}"; do
    if ! deploy_site "$site"; then
        ((ERRORS++))
    fi
done

# Reload Caddy once if any config changed
if [[ "$CADDY_CHANGED" == "true" ]]; then
    caddy_service=$(toml_get "$CONFIG" "caddy" "service")
    caddy_service="${caddy_service:-julianit-caddy}"
    if [[ "$DRY_RUN" == "true" ]]; then
        echo -e "\n  ${BLUE}[dry-run]${NC} would reload caddy (${caddy_service})"
    else
        echo ""
        if sudo systemctl reload "$caddy_service" 2>/dev/null; then
            echo -e "  ${GREEN}Caddy reloaded${NC}"
        else
            echo -e "  ${YELLOW}Caddy reload failed — restarting${NC}"
            sudo systemctl restart "$caddy_service"
        fi
    fi
fi

# Summary
echo ""
if [[ ${#DEPLOYED[@]} -gt 0 ]]; then
    echo -e "${BOLD}==> Deployed:${NC} ${DEPLOYED[*]}"
fi
if [[ $ERRORS -gt 0 ]]; then
    echo -e "${RED}==> ${ERRORS} site(s) had errors${NC}"
    exit 1
else
    echo -e "${GREEN}==> Done${NC}"
fi
