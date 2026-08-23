#!/bin/bash
set -euo pipefail

# =============================================================================
# Mint a Woodpecker personal API token, headlessly.
# =============================================================================
# Woodpecker only mints user tokens for a signed-in browser session — no CLI,
# no admin API — which made `ci-secrets` the platform's one manual step. This
# drives the SSO chain (Keycloak → Forgejo → Woodpecker) with the e2e suite's
# Playwright and asks Woodpecker's own token endpoint, as platform-admin (a
# WOODPECKER_ADMIN, so org secrets work).
#
# Prints exactly one line to stdout: the token. Diagnostics go to stderr, so
#   WOODPECKER_TOKEN="$(./mint-woodpecker-token.sh --env <env>)"
# is safe. deploy.sh's ci-secrets action calls this automatically when no
# token is provided.
#
# Usage: ./mint-woodpecker-token.sh --env <env>
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# stdout carries the token and nothing else: common.sh logs to stdout, so hand
# the real stdout to fd 3 and send everything else to stderr.
exec 3>&1 1>&2

source "${SCRIPT_DIR}/lib/common.sh"

parse_env_arg "$@"
setup_paths
parse_config

E2E_DIR="${K8S_DIR}/e2e"

command -v node >/dev/null || { log_error "node not found — install Node.js, or mint the token at https://ci.${DOMAIN}/user"; exit 1; }
[[ -d "$E2E_DIR" ]] || { log_error "No e2e suite at ${E2E_DIR}"; exit 1; }

OIDC_SECRETS="${SCRIPT_ENV_DIR}/oidc-secrets.env"
[[ -f "$OIDC_SECRETS" ]] || { log_error "No ${OIDC_SECRETS} — run: ./devhub keycloak --env ${ENV}"; exit 1; }
# shellcheck disable=SC1090
source "$OIDC_SECRETS"
[[ -n "${PLATFORM_ADMIN_PASSWORD:-}" ]] || { log_error "PLATFORM_ADMIN_PASSWORD missing from ${OIDC_SECRETS}"; exit 1; }

# Same dependency handling as validate-e2e.sh: install once, quietly reuse.
if [[ ! -d "${E2E_DIR}/node_modules/@playwright/test" ]]; then
    log_info "Installing e2e dependencies (first run)..."
    (cd "$E2E_DIR" && npm install --silent >&2 && npx playwright install chromium >&2)
fi

export DEVHUB_DOMAIN="${DOMAIN}"
export DEVHUB_ENV="${ENV}"
export DEVHUB_ADMIN_USER="platform-admin"
export DEVHUB_ADMIN_PASSWORD="${PLATFORM_ADMIN_PASSWORD}"

cd "$E2E_DIR"
node tools/mint-woodpecker-token.js >&3
