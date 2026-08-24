#!/bin/bash
# =============================================================================
# Shared Library for Kubernetes Platform Scripts
# =============================================================================
# Source this file from other scripts:
#   SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
#   source "${SCRIPT_DIR}/lib/common.sh"
#
# Configuration model
# -------------------
#   overlays/<env>/config.yaml       human-owned, committed: domain, TLS, toggles
#   scripts/<env>/tofu-outputs.env   machine-owned, gitignored: everything tofu knows
#
# sync-tofu-outputs.sh writes the second file; nothing rewrites the first. That
# keeps infrastructure values out of git diffs and removes the fragile
# `sed -i` / `grep -A1` round-trip that used to sit between tofu and Helm.
# =============================================================================

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# All logging goes to stderr: stdout is for data. Functions whose output is
# captured ($(...)) can therefore log freely without the caller swallowing a
# diagnostic into a variable — which is exactly how an error message once
# ended up stored as a credential.
log_info() { echo -e "${GREEN}[INFO]${NC} $1" >&2; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1" >&2; }
log_error() { echo -e "${RED}[ERROR]${NC} $1" >&2; }
log_step() { echo -e "${BLUE}[STEP]${NC} $1" >&2; }
log_phase() { { echo -e "\n${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"; echo -e "${CYAN}  PHASE: $1${NC}"; echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}\n"; } >&2; }

PLATFORM_ENVS="local upcloud-dev upcloud-prod azure-dev azure-prod gcp-dev gcp-prod aws-dev aws-prod"
WORKLOAD_ENVS="upcloud-workload azure-workload gcp-workload aws-workload"

# =============================================================================
# Argument Parsing
# =============================================================================

# Parse --env <environment> from arguments.
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
                    echo "Usage: $0 --env <environment> [...]"
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
        echo "Usage: $0 --env <environment> [...]"
        exit 1
    fi

    if [[ " ${PLATFORM_ENVS} ${WORKLOAD_ENVS} " != *" ${ENV} "* ]]; then
        log_error "Invalid environment: $ENV"
        log_error "Platform environments: ${PLATFORM_ENVS}"
        log_error "Workload environments: ${WORKLOAD_ENVS}"
        exit 1
    fi

    export ENV
}

# True when $ENV is a workload cluster environment.
is_workload_env() {
    [[ " ${WORKLOAD_ENVS} " == *" ${ENV} "* ]]
}

# Cloud name derived from the environment (local, aws, azure, gcp, upcloud).
env_cloud() {
    case "$ENV" in
        local) echo "local" ;;
        *) echo "${ENV%%-*}" ;;
    esac
}

# =============================================================================
# YAML reading
# =============================================================================

# Read a scalar from a YAML file by dotted path: yaml_get <file> a.b.c
#
# Indentation-aware, so it cannot pick up a same-named key from a different
# parent — the previous `grep -A1 'redis:' | grep host:` approach silently
# returned the wrong value whenever keys were reordered. Handles scalars only
# (no sequences), which is all config.yaml holds. Inline comments and
# surrounding quotes are stripped; a missing path yields an empty string.
yaml_get() {
    local file="$1" path="$2"
    [[ -f "$file" ]] || return 0

    awk -v want="$path" '
        # strip trailing comments outside quotes (config.yaml has no # in values)
        {
            line = $0
            sub(/[[:space:]]*#.*$/, "", line)
            if (line ~ /^[[:space:]]*$/) next

            # indentation width
            match(line, /^[ ]*/)
            indent = RLENGTH

            # key: value
            if (line !~ /^[ ]*[A-Za-z0-9_.-]+:/) next
            key = line
            sub(/^[ ]*/, "", key)
            val = key
            sub(/^[A-Za-z0-9_.-]+:[ ]*/, "", val)
            sub(/:.*$/, "", key)

            # pop deeper levels off the path stack
            while (depth > 0 && indents[depth] >= indent) depth--
            depth++
            indents[depth] = indent
            keys[depth] = key

            full = keys[1]
            for (i = 2; i <= depth; i++) full = full "." keys[i]

            if (full == want) {
                gsub(/^[ \t]+|[ \t]+$/, "", val)
                # strip one layer of matching quotes
                if (val ~ /^".*"$/) { sub(/^"/, "", val); sub(/"$/, "", val) }
                else if (val ~ /^'"'"'.*'"'"'$/) { sub(/^'"'"'/, "", val); sub(/'"'"'$/, "", val) }
                print val
                exit
            }
        }
    ' "$file"
}

# =============================================================================
# Configuration
# =============================================================================

# Layered config lookup: the environment's local answers file (written by
# setup-env.sh, gitignored under k8s/scripts/<env>/) wins; the committed
# overlay config.yaml is the fallback and doubles as the sample. This is what
# lets the wizard record your domain without ever editing a committed file.
# All generated per-environment state lives under _setup/<env>/ at the repo
# root — visible, gitignored, and deletable as a unit ('devhub reset').
# See _setup/README.md for what is safe to delete and what never is.
#
# Anchored to this file's own location, not the caller's SCRIPT_DIR: devhub
# and the k8s/scripts/*.sh scripts source this from different directories.
_COMMON_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
setup_root() { echo "$(cd "${_COMMON_LIB_DIR}/../../.." && pwd)/_setup"; }

# Path to an environment's state directory, migrating from the pre-_setup
# location (k8s/scripts/<env>/) the first time it is asked for.
env_state_dir() {
    local env="$1" dir old
    dir="$(setup_root)/${env}"
    old="${_COMMON_LIB_DIR}/../${env}"
    if [[ -d "$old" && ! -e "$dir" ]]; then
        mkdir -p "$(dirname "$dir")"
        mv "$old" "$dir"
        echo "[INFO] Moved generated files k8s/scripts/${env}/ → _setup/${env}/" >&2
    fi
    echo "$dir"
}

cfg_get() {
    local key="$1" v=""
    v="$(yaml_get "$(setup_root)/${ENV}/config.yaml" "$key")"
    if [[ -n "$v" ]]; then
        echo "$v"
    else
        yaml_get "${K8S_DIR}/overlays/${ENV}/config.yaml" "$key"
    fi
}

# Parse config (local answers over committed overlay, see cfg_get) and load
# tofu-outputs.env (generated).
#
# Exports, from config:
#   DOMAIN TLS_TYPE TLS_SECRET_NAME CLUSTER_ISSUER ACME_EMAIL DATA_SERVICES_TYPE
#   PLATFORM_VAULT_URL PLATFORM_LOKI_URL ALERT_SLACK_WEBHOOK_SECRET
# Exports, from tofu-outputs.env (cloud-dependent):
#   PG_HOST REDIS_HOST VALKEY_HOST S3_* AZURE_* GCS_* AWS_* LOKI_* VELERO_* VAULT_KMS_* ...
parse_config() {
    local config_file="${K8S_DIR}/overlays/${ENV}/config.yaml"
    if [[ ! -f "$config_file" ]]; then
        log_error "Config file not found: $config_file"
        exit 1
    fi

    export DOMAIN=$(cfg_get domain)
    export TLS_TYPE=$(cfg_get tls.type)
    export TLS_SECRET_NAME=$(cfg_get tls.secretName)
    export CLUSTER_ISSUER=$(cfg_get tls.clusterIssuer)
    export ACME_EMAIL=$(cfg_get acmeEmail)
    export DATA_SERVICES_TYPE=$(cfg_get dataServices.type)
    export PLATFORM_VAULT_URL=$(cfg_get platformVaultUrl)
    export PLATFORM_LOKI_URL=$(cfg_get platformLokiUrl)
    export GITOPS_REPO_URL=$(cfg_get gitops.repoUrl)
    export GITOPS_REVISION=$(cfg_get gitops.targetRevision)

    # Defaults
    TLS_SECRET_NAME="${TLS_SECRET_NAME:-local-tls-secret}"
    ACME_EMAIL="${ACME_EMAIL:-admin@example.com}"
    DATA_SERVICES_TYPE="${DATA_SERVICES_TYPE:-local}"
    GITOPS_REVISION="${GITOPS_REVISION:-HEAD}"

    # The URL ArgoCD clones from, which is not always the URL a human clones from.
    #
    # On local, gitops.repoUrl is https://git.localhost/... — reachable from the
    # workstation through the gateway, and unreachable from inside the cluster:
    # glibc answers *.localhost with 127.0.0.1 in getaddrinfo before /etc/hosts is
    # consulted, so a pod dials itself and a hostAlias cannot override it (the
    # same reason Keycloak's server-side endpoints use KEYCLOAK_INTERNAL_URL).
    # ArgoCD therefore addresses Forgejo by its Service, over plain HTTP inside
    # the cluster. Everywhere else the two URLs are identical.
    if [[ "$DOMAIN" == "localhost" || "$DOMAIN" == *.localhost ]]; then
        local repo_path="${GITOPS_REPO_URL#*://}"
        repo_path="${repo_path#*/}"
        export GITOPS_REPO_URL_INTERNAL="http://forgejo-http.forgejo.svc.cluster.local:3000/${repo_path}"
    else
        export GITOPS_REPO_URL_INTERNAL="$GITOPS_REPO_URL"
    fi

    load_tofu_outputs
    default_infra_vars
}

# Source the generated tofu output file, if present.
load_tofu_outputs() {
    local outputs_file="${SCRIPT_ENV_DIR}/tofu-outputs.env"

    if [[ -f "$outputs_file" ]]; then
        # shellcheck disable=SC1090
        set -a
        source "$outputs_file"
        set +a
        log_info "Loaded tofu outputs from ${outputs_file}"
    elif [[ "$DATA_SERVICES_TYPE" == "managed" ]] || is_workload_env; then
        log_warn "No tofu outputs found at ${outputs_file}"
        log_warn "Run: ./sync-tofu-outputs.sh --env ${ENV}"
    fi
}

# Every variable referenced by template_values must exist (possibly empty) or
# envsubst leaves the literal ${VAR} in rendered Helm values.
default_infra_vars() {
    local v
    for v in \
        PG_HOST PG_PORT VALKEY_HOST REDIS_HOST REDIS_PORT REDIS_TLS_ENABLED \
        S3_ENDPOINT S3_REGION AWS_REGION \
        AZURE_STORAGE_ACCOUNT AZURE_SUBSCRIPTION_ID AZURE_RESOURCE_GROUP AZURE_NODE_RESOURCE_GROUP \
        GCS_PROJECT_ID \
        EXTERNAL_DNS_IRSA_ROLE_ARN EXTERNAL_DNS_IDENTITY_CLIENT_ID EXTERNAL_DNS_GSA_EMAIL \
        CERT_MANAGER_ROLE_ARN CERT_MANAGER_GSA_EMAIL \
        LOKI_IRSA_ROLE_ARN LOKI_IDENTITY_CLIENT_ID LOKI_GSA_EMAIL LOKI_BUCKET LOKI_CONTAINER \
        VELERO_IRSA_ROLE_ARN VELERO_IDENTITY_CLIENT_ID VELERO_GSA_EMAIL VELERO_BUCKET VELERO_CONTAINER \
        CLUSTER_AUTOSCALER_IRSA_ROLE_ARN CLUSTER_NAME OIDC_ISSUER_URL \
        VAULT_KMS_KEY_ID VAULT_KMS_IRSA_ROLE_ARN VAULT_IDENTITY_CLIENT_ID \
        VAULT_KEY_VAULT_NAME VAULT_KEY_NAME VAULT_GSA_EMAIL \
        VAULT_KMS_REGION VAULT_KMS_KEY_RING VAULT_KMS_CRYPTO_KEY \
        ENTRA_TENANT_ID ENTRA_KEYCLOAK_CLIENT_ID \
        COGNITO_ISSUER_URL COGNITO_HOSTED_UI_DOMAIN COGNITO_CLIENT_ID GOOGLE_IDP_CLIENT_ID
    do
        export "${v}=${!v:-}"
    done

    # The local environment runs its own data services at fixed service names.
    if [[ "${DATA_SERVICES_TYPE:-local}" == "local" ]]; then
        export PG_HOST="${PG_HOST:-postgresql.data-services.svc.cluster.local}"
        export VALKEY_HOST="${VALKEY_HOST:-valkey.data-services.svc.cluster.local}"
        export REDIS_HOST="${REDIS_HOST:-$VALKEY_HOST}"
        export S3_ENDPOINT="${S3_ENDPOINT:-http://minio.data-services.svc.cluster.local:9000}"
    fi

    # Managed PostgreSQL (Azure/AWS/GCP/UpCloud) refuses plaintext connections
    # ("no pg_hba.conf entry ... no encryption"); the local in-cluster
    # PostgreSQL has no TLS at all. Consumers template ${PG_SSL_MODE}.
    if [[ "${DATA_SERVICES_TYPE:-local}" == "managed" ]]; then
        export PG_SSL_MODE="${PG_SSL_MODE:-require}"
    else
        export PG_SSL_MODE="${PG_SSL_MODE:-disable}"
    fi

    # Convenience defaults derived from other values.
    export PG_PORT="${PG_PORT:-5432}"
    export REDIS_PORT="${REDIS_PORT:-6379}"
    export PLATFORM_LOKI_URL="${PLATFORM_LOKI_URL:-}"
}

# =============================================================================
# Templating
# =============================================================================

# Per-run private directory for rendered values. Rendered files can contain
# hostnames and role ARNs, and predictable /tmp paths are trivially clobbered by
# other users on a shared machine.
#
# Created by setup_paths in the top-level shell — creating it lazily from inside a
# command substitution (get_values_args) meant the cleanup trap fired when that
# subshell exited, deleting the files before helm could read them.
init_render_dir() {
    [[ -n "${RENDER_DIR:-}" ]] && return 0
    RENDER_DIR="$(mktemp -d "${TMPDIR:-/tmp}/devhub-render.XXXXXX")"
    chmod 700 "$RENDER_DIR"
    export RENDER_DIR
    trap '_devhub_on_exit' EXIT
}

# Single EXIT handler shared by every cleanup concern (only one EXIT trap can
# exist per shell): scratch directory removal and ephemeral Forgejo token
# revocation. Failures inside must not mask the script's own exit code.
_devhub_on_exit() {
    forgejo_cleanup_tokens || true
    [[ -n "${RENDER_DIR:-}" ]] && rm -rf "${RENDER_DIR}"
    return 0
}

render_dir() {
    if [[ -z "${RENDER_DIR:-}" ]]; then
        log_error "render_dir called before setup_paths — no scratch directory"
        exit 1
    fi
    echo "$RENDER_DIR"
}

# Variables envsubst is allowed to substitute. The list is explicit so that
# ArgoCD's own `$oidc.keycloak.clientSecret` placeholders survive templating.
TEMPLATE_VARS='${DOMAIN} ${TLS_SECRET_NAME} ${CLUSTER_ISSUER} ${ACME_EMAIL}
${PG_HOST} ${PG_PORT} ${PG_SSL_MODE} ${VALKEY_HOST} ${REDIS_HOST} ${REDIS_PORT} ${REDIS_TLS_ENABLED}
${S3_ENDPOINT} ${S3_REGION} ${AWS_REGION}
${AZURE_STORAGE_ACCOUNT} ${AZURE_SUBSCRIPTION_ID} ${AZURE_RESOURCE_GROUP} ${AZURE_NODE_RESOURCE_GROUP}
${GCS_PROJECT_ID}
${EXTERNAL_DNS_IRSA_ROLE_ARN} ${EXTERNAL_DNS_IDENTITY_CLIENT_ID} ${EXTERNAL_DNS_GSA_EMAIL}
${CERT_MANAGER_ROLE_ARN} ${CERT_MANAGER_GSA_EMAIL}
${LOKI_IRSA_ROLE_ARN} ${LOKI_IDENTITY_CLIENT_ID} ${LOKI_GSA_EMAIL} ${LOKI_BUCKET} ${LOKI_CONTAINER}
${VELERO_IRSA_ROLE_ARN} ${VELERO_IDENTITY_CLIENT_ID} ${VELERO_GSA_EMAIL} ${VELERO_BUCKET} ${VELERO_CONTAINER}
${CLUSTER_AUTOSCALER_IRSA_ROLE_ARN} ${CLUSTER_NAME}
${VAULT_KMS_KEY_ID} ${VAULT_KMS_IRSA_ROLE_ARN} ${VAULT_IDENTITY_CLIENT_ID}
${VAULT_KEY_VAULT_NAME} ${VAULT_KEY_NAME} ${VAULT_GSA_EMAIL}
${VAULT_KMS_REGION} ${VAULT_KMS_KEY_RING} ${VAULT_KMS_CRYPTO_KEY}
${ENTRA_TENANT_ID} ${PLATFORM_LOKI_URL} ${PLATFORM_VAULT_URL}
${ENV} ${GITOPS_REPO_URL} ${GITOPS_REPO_URL_INTERNAL} ${GITOPS_REVISION}'

# Template a file with the allow-listed environment variables.
template_values() {
    local input="$1"
    local output="$2"
    envsubst "$TEMPLATE_VARS" < "$input" > "$output"
}

# Get Helm values args for a component (base + templated overlay).
# Usage: get_values_args <component>
get_values_args() {
    local component="$1"
    local base_values="${BASE_DIR}/devops/${component}/values.yaml"
    local overlay_values="${OVERLAY_DIR}/devops/${component}/values.yaml"
    local dir
    dir="$(render_dir)"

    local args=""

    if [[ -f "$base_values" ]]; then
        template_values "$base_values" "${dir}/${component}-base-values.yaml"
        args="-f ${dir}/${component}-base-values.yaml"
    fi

    if [[ -f "$overlay_values" ]]; then
        template_values "$overlay_values" "${dir}/${component}-overlay-values.yaml"
        args="$args -f ${dir}/${component}-overlay-values.yaml"
    fi

    echo "$args"
}

# =============================================================================
# Cluster safety
# =============================================================================

# Point kubectl/helm at the kubeconfig generated for $ENV, when one exists.
#
# Without this, a script inherits whatever context the shell happens to be on —
# which is how workload components end up installed on the platform cluster.
use_env_kubeconfig() {
    local kubeconfig="${SCRIPT_ENV_DIR}/kubeconfig"

    if [[ -f "$kubeconfig" ]]; then
        export KUBECONFIG="$kubeconfig"
        log_info "Using kubeconfig: ${kubeconfig}"
    elif [[ "$ENV" != "local" ]]; then
        log_warn "No kubeconfig at ${kubeconfig} — falling back to the current context:"
        log_warn "  $(kubectl config current-context 2>/dev/null || echo '<none>')"
        log_warn "Run ./sync-tofu-outputs.sh --env ${ENV} to fetch the right one."
    fi
}

# Refuse to continue if the active context does not look like the expected
# cluster. Matches on the tofu-reported cluster name when available.
require_cluster_match() {
    local expected="${1:-${CLUSTER_NAME:-}}"
    local context
    context="$(kubectl config current-context 2>/dev/null || echo '')"

    if [[ -z "$context" ]]; then
        log_error "No active kubectl context — cannot verify the target cluster"
        exit 1
    fi

    # local has no kubeconfig file and no tofu-reported name; the best available
    # check is that the active context at least looks like a local cluster —
    # otherwise "--env local" happily runs against whatever cloud cluster the
    # shell happens to be pointed at.
    if [[ "${ENV:-}" == "local" && -z "$expected" ]]; then
        if [[ "$context" =~ rancher-desktop|k3s|k3d|kind|docker-desktop|colima|minikube ]]; then
            log_info "Target cluster verified: ${context} (local)"
            return 0
        fi
        log_error "Refusing to run: --env local, but the active context does not look local"
        log_error "  active context: ${context}"
        log_error "  expected something like rancher-desktop, k3s, kind or docker-desktop"
        exit 1
    fi

    if [[ -z "$expected" ]]; then
        log_warn "Cluster name unknown (no tofu outputs); target context is: ${context}"
        return 0
    fi

    if [[ "$context" != *"$expected"* ]]; then
        log_error "Refusing to deploy: active context does not match ${ENV}"
        log_error "  expected cluster name to contain: ${expected}"
        log_error "  active context:                   ${context}"
        log_error "Fix with: export KUBECONFIG=${SCRIPT_ENV_DIR}/kubeconfig"
        exit 1
    fi

    log_info "Target cluster verified: ${context}"
}

# =============================================================================
# Helm Repos
# =============================================================================

add_helm_repos() {
    command -v helm &>/dev/null || { log_error "helm required"; exit 1; }

    log_step "Adding Helm repositories..."

    local -a repos=(
        "jetstack https://charts.jetstack.io"
        "hashicorp https://helm.releases.hashicorp.com"
        "external-secrets https://charts.external-secrets.io"
        "prometheus-community https://prometheus-community.github.io/helm-charts"
        "grafana https://grafana.github.io/helm-charts"
        "argo https://argoproj.github.io/argo-helm"
        "external-dns https://kubernetes-sigs.github.io/external-dns/"
        "headlamp https://kubernetes-sigs.github.io/headlamp/"
        "jameswynn https://jameswynn.github.io/helm-charts"
        "woodpecker https://woodpecker-ci.org/"
        "kyverno https://kyverno.github.io/kyverno"
        "stakater https://stakater.github.io/stakater-charts"
        "vmware-tanzu https://vmware-tanzu.github.io/helm-charts"
        "autoscaler https://kubernetes.github.io/autoscaler"
    )

    local -a names=()
    local entry
    for entry in "${repos[@]}"; do
        helm repo add ${entry} 2>/dev/null || true
        names+=("${entry%% *}")
    done

    # Only these repos, not `helm repo update` over everything: an unrelated dead
    # repo in the user's own helm config would otherwise fail the run.
    helm repo update "${names[@]}"
    # Forgejo and Envoy Gateway are OCI charts — no repo to add, pulled by URL.
    log_info "Helm repositories updated"
}

# =============================================================================
# Requirement Checks
# =============================================================================

check_requirements() {
    log_info "Checking requirements..."
    command -v kubectl &>/dev/null || { log_error "kubectl required"; exit 1; }
    command -v envsubst &>/dev/null || { log_error "envsubst required (install gettext)"; exit 1; }
    command -v jq &>/dev/null || { log_error "jq required"; exit 1; }
    kubectl cluster-info &>/dev/null || { log_error "Cannot connect to cluster"; exit 1; }

    if [[ -z "${DOMAIN:-}" ]]; then
        log_error "DOMAIN not set. Check config.yaml in overlay directory."
        exit 1
    fi

    if [[ "$DOMAIN" == *example.com ]]; then
        log_error "DOMAIN is still the placeholder '${DOMAIN}'"
        log_error "Run './devhub setup --env ${ENV}' (answers land in k8s/scripts/${ENV}/config.yaml),"
        log_error "or edit ${K8S_DIR}/overlays/${ENV}/config.yaml directly."
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
# Call after parse_env_arg, before parse_config.
# Sets: K8S_DIR, BASE_DIR, ARGOCD_DIR, OVERLAY_DIR, CERTS_DIR, SCRIPT_ENV_DIR
setup_paths() {
    K8S_DIR="${SCRIPT_DIR}/.."
    BASE_DIR="${K8S_DIR}/base"
    ARGOCD_DIR="${K8S_DIR}/argocd"
    OVERLAY_DIR="${K8S_DIR}/overlays/${ENV}"
    CERTS_DIR="${K8S_DIR}/certs"
    SCRIPT_ENV_DIR="$(env_state_dir "$ENV")"

    # Ensure generated-files directory exists
    mkdir -p "${SCRIPT_ENV_DIR}"
    chmod 700 "${SCRIPT_ENV_DIR}"

    # Scratch space for rendered Helm values (removed on exit).
    init_render_dir
}

# =============================================================================
# Forgejo helpers
# =============================================================================
# The platform talks to Forgejo the same way everywhere: find the pod, mint a
# short-lived admin token, call the JSON API through kubectl exec, revoke the
# token when the script exits. These helpers are that pattern, once — used by
# deploy.sh, deploy-workload.sh and register-workload-cluster.sh.
# (setup-gitops-repo.sh still carries its own copy and can adopt these later.)

# Name of the Forgejo pod, or empty when it is not running. Honours the
# caller's KUBECONFIG, so a script targeting another cluster can prefix:
#   KUBECONFIG="$PLATFORM_KUBECONFIG" forgejo_pod
forgejo_pod() {
    kubectl get pod -n forgejo -l app.kubernetes.io/name=forgejo \
        -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true
}

# The bootstrap admin account's username.
forgejo_admin_user() {
    kubectl get secret forgejo-admin-secret -n forgejo \
        -o jsonpath='{.data.username}' 2>/dev/null | base64 -d || true
}

# Mint a Forgejo access token.
#   forgejo_token_create [--keep] <pod> <token-name> <scopes> [username]
# Echoes the raw token; returns non-zero when it cannot be minted.
# Defaults to the admin account. Without --keep the token is *ephemeral*: it
# is registered for revocation when the script exits (trap-based, so failures
# still clean up). Pass --keep only for credentials that are stored and must
# outlive the run (registry tokens, ArgoCD repo-creds, the portal bot token).
_FORGEJO_EPHEMERAL_TOKENS=()
forgejo_token_create() {
    local keep=false
    if [[ "${1:-}" == "--keep" ]]; then keep=true; shift; fi
    local pod="$1" name="$2" scopes="$3" user="${4:-}"
    [[ -n "$user" ]] || user="$(forgejo_admin_user)"
    [[ -n "$pod" && -n "$user" ]] || return 1

    local token
    token="$(kubectl exec -n forgejo "$pod" -- forgejo admin user generate-access-token \
        --username "$user" --token-name "$name" --scopes "$scopes" --raw 2>/dev/null \
        | tr -d '\r' | tail -1)"
    [[ -n "$token" ]] || return 1

    if ! $keep; then
        # Remember the kubeconfig too: the trap fires long after a caller's
        # per-call KUBECONFIG prefix has reverted.
        _FORGEJO_EPHEMERAL_TOKENS+=("${KUBECONFIG:-}"$'\t'"${pod}"$'\t'"${user}"$'\t'"${name}")
        trap '_devhub_on_exit' EXIT
    fi
    echo "$token"
}

# Revoke one token by name. Token management authenticates with basic auth;
# the credentials go in over stdin (curl -K -) so they never appear in the
# pod's argv. Best-effort — cleanup must not fail the script.
forgejo_token_delete() {
    local pod="$1" user="$2" name="$3"
    local admin pass
    admin="$(forgejo_admin_user)"
    pass="$(kubectl get secret forgejo-admin-secret -n forgejo \
        -o jsonpath='{.data.password}' 2>/dev/null | base64 -d || true)"
    [[ -n "$pod" && -n "$admin" && -n "$pass" ]] || return 0
    printf 'user = "%s:%s"\n' "$admin" "$pass" | kubectl exec -i -n forgejo "$pod" -- \
        curl -fsS -K - -X DELETE \
        "http://localhost:3000/api/v1/users/${user}/tokens/${name}" >/dev/null 2>&1 || true
}

# Revoke every ephemeral token minted this run (called from the EXIT trap).
forgejo_cleanup_tokens() {
    local entry kc pod user name
    for entry in ${_FORGEJO_EPHEMERAL_TOKENS[@]+"${_FORGEJO_EPHEMERAL_TOKENS[@]}"}; do
        IFS=$'\t' read -r kc pod user name <<<"$entry"
        if [[ -n "$kc" ]]; then
            KUBECONFIG="$kc" forgejo_token_delete "$pod" "$user" "$name"
        else
            forgejo_token_delete "$pod" "$user" "$name"
        fi
    done
    _FORGEJO_EPHEMERAL_TOKENS=()
    return 0
}

# Call the Forgejo JSON API from inside the pod.
#   forgejo_api <pod> <token> <method> <path> [json-body]
# A body, when given, goes in over stdin. Output is the response body; a
# non-2xx answer returns curl's non-zero exit code.
forgejo_api() {
    local pod="$1" token="$2" method="$3" path="$4" body="${5:-}"
    if [[ -n "$body" ]]; then
        printf '%s' "$body" | kubectl exec -i -n forgejo "$pod" -- curl -fsS -X "$method" \
            "http://localhost:3000/api/v1${path}" \
            -H "Authorization: token ${token}" -H "Content-Type: application/json" \
            --data-binary @- 2>/dev/null
    else
        kubectl exec -n forgejo "$pod" -- curl -fsS -X "$method" \
            "http://localhost:3000/api/v1${path}" \
            -H "Authorization: token ${token}" 2>/dev/null
    fi
}

# =============================================================================
# DNS-01 ClusterIssuer (wildcard certificates)
# =============================================================================
# Let's Encrypt will not issue a wildcard over HTTP-01, so the apps listener's
# certificate needs DNS-01. The solver differs per cloud; the credentials are
# the same DNS identity external-dns uses (tofu also federates it to
# cert-manager's service account). Shared between deploy.sh
# (enable_workload_target) and deploy-workload.sh — previously duplicated.
# Uses the exported infra vars parse_config provides.
apply_dns01_issuer() {
    local cloud="$1"
    local solver=""
    case "$cloud" in
        aws)
            solver="      - dns01:
          route53:
            region: ${AWS_REGION:-eu-west-1}" ;;
        azure)
            solver="      - dns01:
          azureDNS:
            resourceGroupName: ${DNS_ZONE_RESOURCE_GROUP:-${AZURE_RESOURCE_GROUP:-}}
            subscriptionID: ${AZURE_SUBSCRIPTION_ID:-}
            hostedZoneName: ${DOMAIN}
            environment: AzurePublicCloud
            managedIdentity:
              clientID: ${EXTERNAL_DNS_IDENTITY_CLIENT_ID:-}" ;;
        gcp)
            solver="      - dns01:
          cloudDNS:
            project: ${GCS_PROJECT_ID:-}" ;;
        upcloud)
            log_warn "UpCloud has no cert-manager DNS-01 solver; the platform uses Cloudflare."
            log_warn "Create the letsencrypt-dns01 ClusterIssuer manually with a cloudflare solver and an API token secret."
            return 0
            ;;
        *)
            log_warn "No DNS-01 solver for '${cloud}' — create the letsencrypt-dns01 ClusterIssuer manually"
            return 0
            ;;
    esac

    cat <<EOF | kubectl apply -f -
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-dns01
spec:
  acme:
    server: https://acme-v02.api.letsencrypt.org/directory
    email: ${ACME_EMAIL}
    privateKeySecretRef:
      name: letsencrypt-dns01
    solvers:
${solver}
EOF
    log_info "letsencrypt-dns01 ClusterIssuer applied (wildcard certificates)"
}

# -----------------------------------------------------------------------------
# App namespace cleanup — the tail end of deprovisioning a developer app.
#
# Deleting an app's Forgejo repository makes the ApplicationSets prune
# everything ArgoCD deployed, but two things survive: the devhub-* namespace
# (CreateNamespace=true namespaces are not ArgoCD-tracked) and the PVCs inside
# it — the postgres volume keeps costing money until someone deletes it.
#
# A namespace counts as orphaned when BOTH:
#   - it holds no deployments, statefulsets, daemonsets, cronjobs or pods
#     (Kyverno-generated quota/LimitRange/NetworkPolicies do not count), and
#   - it is older than CLEANUP_MIN_AGE_MINUTES (default 60) — so a freshly
#     synced app whose workloads have not landed yet is never swept up.
#
# Dry-run by default; pass "apply" to delete. Deleting the namespace takes the
# PVCs (and their cloud disks) with it. Exposed as the cleanup-apps action of
# deploy.sh (platform/single-cluster envs) and deploy-workload.sh.
cleanup_orphaned_app_namespaces() {
    local mode="${1:-dry-run}"
    local min_age_minutes="${CLEANUP_MIN_AGE_MINUTES:-60}"
    log_step "Scanning devhub-* namespaces for orphans (min age ${min_age_minutes}m, mode: ${mode})..."

    local now ns created age_s workloads pods found=0
    now="$(date +%s)"
    for ns in $(kubectl get namespaces -o name 2>/dev/null | sed 's|namespace/||' | grep '^devhub-' || true); do
        created="$(kubectl get namespace "$ns" -o jsonpath='{.metadata.creationTimestamp}')"
        age_s=$(( now - $(date -d "$created" +%s) ))
        if (( age_s < min_age_minutes * 60 )); then
            log_info "  ${ns}: younger than ${min_age_minutes}m — skipped"
            continue
        fi
        workloads="$(kubectl get deployments,statefulsets,daemonsets,cronjobs -n "$ns" -o name 2>/dev/null | wc -l)"
        pods="$(kubectl get pods -n "$ns" -o name 2>/dev/null | wc -l)"
        if (( workloads > 0 || pods > 0 )); then
            log_info "  ${ns}: ${workloads} workload(s), ${pods} pod(s) — in use"
            continue
        fi
        found=$((found + 1))
        if [[ "$mode" == "apply" ]]; then
            log_warn "  ${ns}: orphaned — deleting (PVCs and their disks go with it)"
            kubectl delete namespace "$ns" --wait=false
        else
            log_warn "  ${ns}: orphaned — would delete (PVCs: $(kubectl get pvc -n "$ns" -o name 2>/dev/null | wc -l))"
        fi
    done

    if (( found == 0 )); then
        log_info "No orphaned app namespaces"
    elif [[ "$mode" != "apply" ]]; then
        log_info "Dry run — re-run with 'apply' to delete: ${found} namespace(s)"
    fi
}
