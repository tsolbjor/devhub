#!/bin/bash
set -euo pipefail

# =============================================================================
# Sync OpenTofu Outputs to K8s Overlay Config
# =============================================================================
# Reads managed data service outputs from tofu and writes them into the
# matching k8s overlay config.yaml. Also fetches the cluster kubeconfig.
#
# Usage: ./sync-tofu-outputs.sh --env upcloud-dev|upcloud-prod
#
# Prerequisites:
#   - tofu apply has been run in the corresponding tofu environment
#   - upctl CLI installed (for kubeconfig fetch)
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

parse_env_arg "$@"

# Map k8s env to tofu directory
REPO_ROOT="${SCRIPT_DIR}/../.."
case "$ENV" in
    upcloud-dev)  TOFU_DIR="${REPO_ROOT}/tofu/upcloud/dev" ;;
    upcloud-prod) TOFU_DIR="${REPO_ROOT}/tofu/upcloud/prod" ;;
    *)
        log_error "sync-tofu-outputs only works with upcloud-dev or upcloud-prod"
        exit 1
        ;;
esac

CONFIG_FILE="${SCRIPT_DIR}/../overlays/${ENV}/config.yaml"

if [[ ! -d "$TOFU_DIR" ]]; then
    log_error "Tofu directory not found: $TOFU_DIR"
    exit 1
fi

if [[ ! -f "$CONFIG_FILE" ]]; then
    log_error "Config file not found: $CONFIG_FILE"
    exit 1
fi

# ─── Read tofu outputs ──────────────────────────────────────────────

log_step "Reading tofu outputs from ${TOFU_DIR}..."

cd "$TOFU_DIR"

if [[ ! -f terraform.tfstate ]] && [[ ! -d .terraform ]]; then
    log_error "Tofu has not been initialized/applied in ${TOFU_DIR}"
    log_error "Run: cd ${TOFU_DIR} && tofu init && tofu apply"
    exit 1
fi

OUTPUTS=$(tofu output -json)

PG_HOST=$(echo "$OUTPUTS" | jq -r '.pg_host.value')
PG_PORT=$(echo "$OUTPUTS" | jq -r '.pg_port.value')
VALKEY_HOST=$(echo "$OUTPUTS" | jq -r '.valkey_host.value')
VALKEY_PORT=$(echo "$OUTPUTS" | jq -r '.valkey_port.value')
S3_ENDPOINT=$(echo "$OUTPUTS" | jq -r '.s3_endpoint.value')
S3_REGION=$(echo "$OUTPUTS" | jq -r '.s3_region.value')
CLUSTER_NAME=$(echo "$OUTPUTS" | jq -r '.cluster_name.value')

log_info "PostgreSQL: ${PG_HOST}:${PG_PORT}"
log_info "Valkey:     ${VALKEY_HOST}:${VALKEY_PORT}"
log_info "S3:         ${S3_ENDPOINT} (${S3_REGION})"
log_info "Cluster:    ${CLUSTER_NAME}"

# ─── Update config.yaml ─────────────────────────────────────────────

log_step "Updating ${CONFIG_FILE}..."

# Context-aware replacement within the dataServices section
sed -i "/^dataServices:/,\$ {
    /postgresql:/,/host:/ { s|host: .*|host: ${PG_HOST}:${PG_PORT}| }
    /valkey:/,/host:/ { s|host: .*|host: ${VALKEY_HOST}:${VALKEY_PORT}| }
    /s3:/,/endpoint:/ { s|endpoint: .*|endpoint: ${S3_ENDPOINT}| }
    /s3:/,/region:/ { s|region: .*|region: ${S3_REGION}| }
}" "$CONFIG_FILE"

log_info "Config updated"

# ─── Fetch kubeconfig ────────────────────────────────────────────────

log_step "Fetching kubeconfig for cluster: ${CLUSTER_NAME}..."

KUBECONFIG_DIR="${SCRIPT_DIR}/${ENV}"
mkdir -p "$KUBECONFIG_DIR"
KUBECONFIG_FILE="${KUBECONFIG_DIR}/kubeconfig"

if command -v upctl &>/dev/null; then
    upctl kubernetes config "${CLUSTER_NAME}" --write "${KUBECONFIG_FILE}"
    log_info "Kubeconfig written to: ${KUBECONFIG_FILE}"
    log_info "Use with: export KUBECONFIG=${KUBECONFIG_FILE}"
else
    log_warn "upctl not found — install UpCloud CLI to fetch kubeconfig automatically"
    log_warn "  https://github.com/UpCloudLtd/upcloud-cli"
    log_warn "Or download kubeconfig from UpCloud console and save to: ${KUBECONFIG_FILE}"
fi

# ─── Summary ─────────────────────────────────────────────────────────

echo ""
log_info "Sync complete. Next steps:"
echo ""
echo "  1. Set domain and acmeEmail in: ${CONFIG_FILE}"
echo "  2. export KUBECONFIG=${KUBECONFIG_FILE}"
echo "  3. ./deploy.sh --env ${ENV}"
echo ""
