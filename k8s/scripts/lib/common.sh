#!/bin/bash
# =============================================================================
# Shared Library for Kubernetes Platform Scripts
# =============================================================================
# Source this file from other scripts:
#   SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
#   source "${SCRIPT_DIR}/lib/common.sh"
# =============================================================================

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }
log_step() { echo -e "${BLUE}[STEP]${NC} $1"; }
log_phase() { echo -e "\n${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"; echo -e "${CYAN}  PHASE: $1${NC}"; echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}\n"; }

# =============================================================================
# Argument Parsing
# =============================================================================

# Parse --env local|upcloud from arguments.
# Sets ENV global and removes --env <val> from args.
# Remaining args are placed in ARGS array.
parse_env_arg() {
    ENV=""
    ARGS=()

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --env)
                if [[ -z "${2:-}" ]]; then
                    log_error "Missing value for --env"
                    echo "Usage: $0 --env local|upcloud [...]"
                    exit 1
                fi
                ENV="$2"
                shift 2
                ;;
            *)
                ARGS+=("$1")
                shift
                ;;
        esac
    done

    if [[ -z "$ENV" ]]; then
        log_error "Missing required --env argument"
        echo "Usage: $0 --env local|upcloud [...]"
        exit 1
    fi

    case "$ENV" in
        local|upcloud) ;;
        *)
            log_error "Invalid environment: $ENV (must be local or upcloud)"
            exit 1
            ;;
    esac

    export ENV
}

# =============================================================================
# Configuration Parsing
# =============================================================================

# Parse config.yaml for the selected environment.
# Exports: DOMAIN, TLS_SECRET_NAME, TLS_TYPE, CLUSTER_ISSUER, ACME_EMAIL,
#          DATA_SERVICES_TYPE, and for managed: PG_HOST, VALKEY_HOST, S3_ENDPOINT, S3_REGION
parse_config() {
    local config_file="${K8S_DIR}/overlays/${ENV}/config.yaml"
    if [[ ! -f "$config_file" ]]; then
        log_error "Config file not found: $config_file"
        exit 1
    fi

    # Helper: strip inline YAML comments, trim whitespace, remove surrounding quotes
    _yaml_val() { sed 's/[[:space:]]*#.*$//' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | sed 's/^"\(.*\)"$/\1/' | sed "s/^'\(.*\)'$/\1/"; }

    export DOMAIN=$(grep -E '^domain:' "$config_file" | sed 's/domain:[[:space:]]*//' | _yaml_val)
    export TLS_SECRET_NAME=$(grep -E '^[[:space:]]*secretName:' "$config_file" | head -1 | sed 's/.*secretName:[[:space:]]*//' | _yaml_val)
    export TLS_TYPE=$(grep -E '^[[:space:]]*type:' "$config_file" | head -1 | sed 's/.*type:[[:space:]]*//' | _yaml_val)
    export CLUSTER_ISSUER=$(grep -E '^[[:space:]]*clusterIssuer:' "$config_file" | head -1 | sed 's/.*clusterIssuer:[[:space:]]*//' | _yaml_val)
    export ACME_EMAIL=$(grep -E '^acmeEmail:' "$config_file" | sed 's/acmeEmail:[[:space:]]*//' | _yaml_val)

    # Defaults
    TLS_SECRET_NAME="${TLS_SECRET_NAME:-local-tls-secret}"
    ACME_EMAIL="${ACME_EMAIL:-admin@example.com}"

    # Data services type
    export DATA_SERVICES_TYPE=$(grep -A1 '^dataServices:' "$config_file" | grep 'type:' | sed 's/.*type:[[:space:]]*//' | _yaml_val || echo "local")
    DATA_SERVICES_TYPE="${DATA_SERVICES_TYPE:-local}"

    # Managed data service endpoints (if type is managed)
    if [[ "$DATA_SERVICES_TYPE" == "managed" ]]; then
        export PG_HOST="${PG_HOST:-$(grep -A1 'postgresql:' "$config_file" | grep 'host:' | sed 's/.*host:[[:space:]]*//' | _yaml_val)}"
        export VALKEY_HOST="${VALKEY_HOST:-$(grep -A1 'valkey:' "$config_file" | grep 'host:' | sed 's/.*host:[[:space:]]*//' | _yaml_val)}"
        export S3_ENDPOINT="${S3_ENDPOINT:-$(grep -A2 's3:' "$config_file" | grep 'endpoint:' | sed 's/.*endpoint:[[:space:]]*//' | _yaml_val)}"
        export S3_REGION="${S3_REGION:-$(grep -A2 's3:' "$config_file" | grep 'region:' | sed 's/.*region:[[:space:]]*//' | _yaml_val)}"
    else
        export PG_HOST="${PG_HOST:-}"
        export VALKEY_HOST="${VALKEY_HOST:-}"
        export S3_ENDPOINT="${S3_ENDPOINT:-}"
        export S3_REGION="${S3_REGION:-}"
    fi
}

# =============================================================================
# Templating
# =============================================================================

# Template overlay values with environment variables.
# Restricted list to avoid breaking ArgoCD's $oidc.keycloak.clientSecret.
template_values() {
    local input="$1"
    local output="$2"
    envsubst '${DOMAIN} ${TLS_SECRET_NAME} ${CLUSTER_ISSUER} ${ACME_EMAIL} ${PG_HOST} ${VALKEY_HOST} ${S3_ENDPOINT} ${S3_REGION}' < "$input" > "$output"
}

# Get Helm values args for a component (base + templated overlay).
# Usage: get_values_args <component>
get_values_args() {
    local component="$1"
    local base_values="${BASE_DIR}/devops/${component}/values.yaml"
    local overlay_values="${OVERLAY_DIR}/devops/${component}/values.yaml"
    local templated_values="/tmp/${component}-overlay-values.yaml"

    local args=""

    if [[ -f "$base_values" ]]; then
        args="-f $base_values"
    fi

    if [[ -f "$overlay_values" ]]; then
        template_values "$overlay_values" "$templated_values"
        args="$args -f $templated_values"
    fi

    echo "$args"
}

# =============================================================================
# Helm Repos
# =============================================================================

add_helm_repos() {
    command -v helm &>/dev/null || { log_error "helm required"; exit 1; }

    log_step "Adding Helm repositories..."

    helm repo add jetstack https://charts.jetstack.io 2>/dev/null || true
    helm repo add codecentric https://codecentric.github.io/helm-charts 2>/dev/null || true
    helm repo add hashicorp https://helm.releases.hashicorp.com 2>/dev/null || true
    helm repo add external-secrets https://charts.external-secrets.io 2>/dev/null || true
    helm repo add prometheus-community https://prometheus-community.github.io/helm-charts 2>/dev/null || true
    helm repo add grafana https://grafana.github.io/helm-charts 2>/dev/null || true
    helm repo add gitlab https://charts.gitlab.io 2>/dev/null || true
    helm repo add argo https://argoproj.github.io/argo-helm 2>/dev/null || true
    helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx 2>/dev/null || true

    helm repo update
    log_info "Helm repositories updated"
}

# =============================================================================
# Requirement Checks
# =============================================================================

check_requirements() {
    log_info "Checking requirements..."
    command -v kubectl &>/dev/null || { log_error "kubectl required"; exit 1; }
    command -v envsubst &>/dev/null || { log_error "envsubst required (install gettext)"; exit 1; }
    kubectl cluster-info &>/dev/null || { log_error "Cannot connect to cluster"; exit 1; }

    if [[ -z "${DOMAIN:-}" ]]; then
        log_error "DOMAIN not set. Check config.yaml in overlay directory."
        exit 1
    fi

    if [[ "$ENV" == "local" && ! -f "${CERTS_DIR:-/nonexistent}/domains/local-dev.crt" ]]; then
        log_error "Certificates not found. Run: ./setup-ca.sh --env local"
        exit 1
    fi

    log_info "Requirements satisfied (env: $ENV, domain: $DOMAIN)"
}

check_all_requirements() {
    log_step "Checking all requirements..."

    local missing=()
    command -v kubectl &>/dev/null || missing+=("kubectl")
    command -v helm &>/dev/null || missing+=("helm")
    command -v openssl &>/dev/null || missing+=("openssl")
    command -v jq &>/dev/null || missing+=("jq")
    command -v envsubst &>/dev/null || missing+=("envsubst (gettext)")
    command -v curl &>/dev/null || missing+=("curl")

    if [[ ${#missing[@]} -gt 0 ]]; then
        log_error "Missing required tools: ${missing[*]}"
        exit 1
    fi

    if ! kubectl cluster-info &>/dev/null; then
        log_error "Cannot connect to Kubernetes cluster."
        log_error "Make sure Rancher Desktop (or your K8s) is running."
        exit 1
    fi

    log_info "All requirements satisfied"
}

# =============================================================================
# Common Path Setup
# =============================================================================

# Set up standard paths based on SCRIPT_DIR and ENV.
# Call after parse_env_arg and parse_config.
# Sets: K8S_DIR, BASE_DIR, ARGOCD_DIR, OVERLAY_DIR, CERTS_DIR, SCRIPT_ENV_DIR
setup_paths() {
    K8S_DIR="${SCRIPT_DIR}/.."
    BASE_DIR="${K8S_DIR}/base"
    ARGOCD_DIR="${K8S_DIR}/argocd"
    OVERLAY_DIR="${K8S_DIR}/overlays/${ENV}"
    CERTS_DIR="${K8S_DIR}/certs"
    SCRIPT_ENV_DIR="${SCRIPT_DIR}/${ENV}"

    # Ensure generated-files directory exists
    mkdir -p "${SCRIPT_ENV_DIR}"
}
