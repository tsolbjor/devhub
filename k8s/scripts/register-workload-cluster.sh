#!/bin/bash
set -euo pipefail

# =============================================================================
# Register Workload Cluster with Platform ArgoCD
# =============================================================================
# Connects a workload cluster to the platform cluster's ArgoCD so it can
# deploy apps, and provisions the Vault token the workload cluster needs to
# pull secrets via External Secrets Operator.
#
# What this script does:
#   1. Adds the workload cluster to ArgoCD via `argocd cluster add`
#   2. Creates a Vault AppRole/token for the workload cluster
#   3. Stores the token in the workload cluster's `external-secrets` namespace
#   4. Creates a GitLab group deploy token (read_registry) for image pulls
#   5. Stores the registry credentials in Vault for app ExternalSecrets to use
#
# Usage:
#   ./register-workload-cluster.sh --env aws-workload [--platform-env aws-dev]
#
# Prerequisites:
#   - Platform cluster kubeconfig is available (set PLATFORM_KUBECONFIG)
#   - Workload cluster kubeconfig: k8s/scripts/<workload-env>/kubeconfig
#   - ArgoCD CLI installed and logged in (argocd login)
#   - Vault CLI installed (vault) or vault is accessible via kubectl
#   - GitLab is running on the platform cluster
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

# Parse --env and optional --platform-env
PLATFORM_ENV=""
ENV=""
ARGS=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        --env)
            ENV="$2"; shift 2 ;;
        --platform-env)
            PLATFORM_ENV="$2"; shift 2 ;;
        *)
            ARGS+=("$1"); shift ;;
    esac
done

if [[ -z "$ENV" ]]; then
    log_error "Missing --env argument"
    echo "Usage: $0 --env aws-workload [--platform-env aws-dev]"
    exit 1
fi

case "$ENV" in
    aws-workload|azure-workload|gcp-workload|upcloud-workload) ;;
    *)
        log_error "Invalid workload environment: $ENV"
        exit 1
        ;;
esac

# Derive platform env if not specified
if [[ -z "$PLATFORM_ENV" ]]; then
    CLOUD="${ENV%-workload}"
    PLATFORM_ENV="${CLOUD}-dev"
    log_warn "No --platform-env specified, defaulting to: ${PLATFORM_ENV}"
fi

WORKLOAD_KUBECONFIG="${SCRIPT_DIR}/${ENV}/kubeconfig"
PLATFORM_KUBECONFIG="${PLATFORM_KUBECONFIG:-${SCRIPT_DIR}/${PLATFORM_ENV}/kubeconfig}"

if [[ ! -f "$WORKLOAD_KUBECONFIG" ]]; then
    log_error "Workload kubeconfig not found: ${WORKLOAD_KUBECONFIG}"
    log_error "Run: ./sync-tofu-outputs.sh --env ${ENV}"
    exit 1
fi

if [[ ! -f "$PLATFORM_KUBECONFIG" ]]; then
    log_warn "Platform kubeconfig not found: ${PLATFORM_KUBECONFIG}"
    log_warn "Set PLATFORM_KUBECONFIG=<path> to override"
fi

setup_paths
parse_config

CONFIG_FILE="${SCRIPT_DIR}/../overlays/${ENV}/config.yaml"
_yaml_val() { sed 's/[[:space:]]*#.*$//' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | sed "s/['\"]//g"; }
PLATFORM_VAULT_URL=$(grep -E '^platformVaultUrl:' "$CONFIG_FILE" | sed 's/platformVaultUrl:[[:space:]]*//' | _yaml_val)

# ─── Step 1: Register workload cluster in ArgoCD ──────────────────────

log_phase "Step 1: Register workload cluster in ArgoCD"

if command -v argocd &>/dev/null; then
    WORKLOAD_CONTEXT=$(KUBECONFIG="$WORKLOAD_KUBECONFIG" kubectl config current-context)
    log_info "Adding workload cluster to ArgoCD (context: ${WORKLOAD_CONTEXT})..."

    KUBECONFIG="$WORKLOAD_KUBECONFIG" argocd cluster add "$WORKLOAD_CONTEXT" \
        --name "${ENV}" \
        --yes \
        --kubeconfig "$PLATFORM_KUBECONFIG" 2>/dev/null || true

    WORKLOAD_SERVER=$(KUBECONFIG="$WORKLOAD_KUBECONFIG" kubectl config view \
        --minify --output 'jsonpath={.clusters[0].cluster.server}')

    log_info "Workload cluster registered as: ${ENV}"
    log_info "Server URL: ${WORKLOAD_SERVER}"
    echo ""
    log_info "Update k8s/argocd/apps/gitlab-appset.yaml destination.server to:"
    log_info "  ${WORKLOAD_SERVER}"
    echo ""
else
    log_warn "argocd CLI not found — install it: https://argo-cd.readthedocs.io/en/stable/cli_installation/"
    log_warn "Then run: argocd cluster add <workload-context> --name ${ENV}"
    WORKLOAD_SERVER="https://PENDING_REGISTRATION"
fi

# ─── Step 2: Create Vault token for workload cluster ─────────────────

log_phase "Step 2: Create Vault token for External Secrets Operator"

VAULT_POLICY_NAME="workload-${ENV}-secrets"
VAULT_TOKEN_ROLE="workload-${ENV}"

if command -v vault &>/dev/null && [[ -n "${VAULT_ADDR:-}" ]]; then
    log_info "Creating Vault policy: ${VAULT_POLICY_NAME}"

    vault policy write "${VAULT_POLICY_NAME}" - <<EOF
# Allow workload cluster to read app secrets
path "secret/data/apps/*" {
  capabilities = ["read"]
}
# Allow workload cluster to read registry pull token
path "secret/data/gitlab/registry-pull-token" {
  capabilities = ["read"]
}
EOF

    log_info "Creating Vault token for workload cluster..."
    VAULT_TOKEN=$(vault token create \
        -policy="${VAULT_POLICY_NAME}" \
        -ttl=0 \
        -period=24h \
        -display-name="workload-${ENV}" \
        -format=json | jq -r '.auth.client_token')

    log_info "Storing Vault token in workload cluster..."
    KUBECONFIG="$WORKLOAD_KUBECONFIG" kubectl create namespace external-secrets 2>/dev/null || true
    KUBECONFIG="$WORKLOAD_KUBECONFIG" kubectl create secret generic vault-workload-token \
        --namespace external-secrets \
        --from-literal=token="${VAULT_TOKEN}" \
        --dry-run=client -o yaml | \
        KUBECONFIG="$WORKLOAD_KUBECONFIG" kubectl apply -f -

    log_info "Vault token stored in workload cluster"

elif [[ -n "${PLATFORM_KUBECONFIG:-}" && -f "$PLATFORM_KUBECONFIG" ]]; then
    log_info "vault CLI not configured — using kubectl exec to configure Vault via platform cluster"

    VAULT_POD=$(KUBECONFIG="$PLATFORM_KUBECONFIG" kubectl get pod -n vault \
        -l app.kubernetes.io/name=vault \
        -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")

    if [[ -z "$VAULT_POD" ]]; then
        log_warn "No Vault pod found on platform cluster"
        log_warn "Set VAULT_ADDR and VAULT_TOKEN environment variables to configure Vault directly"
        log_warn "Then re-run this script"
    else
        log_info "Using Vault pod: ${VAULT_POD}"
        KUBECONFIG="$PLATFORM_KUBECONFIG" kubectl exec -n vault "${VAULT_POD}" -- \
            vault policy write "${VAULT_POLICY_NAME}" - <<EOF
path "secret/data/apps/*" {
  capabilities = ["read"]
}
path "secret/data/gitlab/registry-pull-token" {
  capabilities = ["read"]
}
EOF
        VAULT_TOKEN=$(KUBECONFIG="$PLATFORM_KUBECONFIG" kubectl exec -n vault "${VAULT_POD}" -- \
            vault token create \
            -policy="${VAULT_POLICY_NAME}" \
            -ttl=0 -period=24h \
            -display-name="workload-${ENV}" \
            -format=json | jq -r '.auth.client_token')

        KUBECONFIG="$WORKLOAD_KUBECONFIG" kubectl create namespace external-secrets 2>/dev/null || true
        KUBECONFIG="$WORKLOAD_KUBECONFIG" kubectl create secret generic vault-workload-token \
            --namespace external-secrets \
            --from-literal=token="${VAULT_TOKEN}" \
            --dry-run=client -o yaml | \
            KUBECONFIG="$WORKLOAD_KUBECONFIG" kubectl apply -f -

        log_info "Vault token stored in workload cluster"
    fi
else
    log_warn "Vault not accessible — skipping Vault token creation"
    log_warn "Manually create a Vault token with read access to secret/data/apps/* and secret/data/gitlab/registry-pull-token"
    log_warn "Then store it: kubectl create secret generic vault-workload-token -n external-secrets --from-literal=token=<token>"
fi

# ─── Step 3: Create GitLab registry deploy token ──────────────────────

log_phase "Step 3: Create GitLab registry deploy token"

GITLAB_POD=""
if [[ -n "${PLATFORM_KUBECONFIG:-}" && -f "$PLATFORM_KUBECONFIG" ]]; then
    GITLAB_POD=$(KUBECONFIG="$PLATFORM_KUBECONFIG" kubectl get pod -n gitlab \
        -l app=webservice \
        -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
fi

if [[ -z "$GITLAB_POD" ]]; then
    log_warn "GitLab webservice pod not found on platform cluster"
    log_warn "Create a GitLab group deploy token manually:"
    log_warn "  1. GitLab → devhub group → Settings → Repository → Deploy tokens"
    log_warn "  2. Name: workload-registry-pull, Scopes: read_registry"
    log_warn "  3. Store in Vault: vault kv put secret/gitlab/registry-pull-token username=<name> token=<token>"
    log_warn "  4. Store in workload cluster: kubectl create secret docker-registry registry-pull-secret \\"
    log_warn "       -n devhub --docker-server=registry.${DOMAIN:-DOMAIN} \\"
    log_warn "       --docker-username=<name> --docker-password=<token>"
else
    log_info "GitLab pod found: ${GITLAB_POD}"
    log_info "Creating group deploy token via GitLab Rails console..."

    # Use Rails console to create the deploy token
    DEPLOY_TOKEN_OUTPUT=$(KUBECONFIG="$PLATFORM_KUBECONFIG" kubectl exec -n gitlab "${GITLAB_POD}" -- \
        gitlab-rails runner "
group = Group.find_by_path('devhub')
if group.nil?
  puts 'ERROR: group devhub not found'
  exit 1
end
existing = group.deploy_tokens.find_by(name: 'workload-registry-pull')
existing.revoke! if existing
token = group.deploy_tokens.create!(
  name: 'workload-registry-pull',
  username: 'workload-registry-pull',
  read_registry: true,
  read_repository: false,
  expires_at: nil
)
puts \"TOKEN=#{token.token}\"
puts \"USERNAME=#{token.username}\"
" 2>&1 || echo "ERROR")

    if echo "$DEPLOY_TOKEN_OUTPUT" | grep -q "^TOKEN="; then
        REGISTRY_TOKEN=$(echo "$DEPLOY_TOKEN_OUTPUT" | grep "^TOKEN=" | cut -d= -f2)
        REGISTRY_USER=$(echo "$DEPLOY_TOKEN_OUTPUT" | grep "^USERNAME=" | cut -d= -f2)
        log_info "Deploy token created: ${REGISTRY_USER}"

        # Store in Vault
        if command -v vault &>/dev/null && [[ -n "${VAULT_ADDR:-}" ]]; then
            vault kv put secret/gitlab/registry-pull-token \
                username="${REGISTRY_USER}" \
                token="${REGISTRY_TOKEN}"
            log_info "Registry pull token stored in Vault at: secret/gitlab/registry-pull-token"
        elif [[ -n "$VAULT_POD" ]]; then
            KUBECONFIG="$PLATFORM_KUBECONFIG" kubectl exec -n vault "${VAULT_POD}" -- \
                vault kv put secret/gitlab/registry-pull-token \
                    username="${REGISTRY_USER}" \
                    token="${REGISTRY_TOKEN}"
            log_info "Registry pull token stored in Vault at: secret/gitlab/registry-pull-token"
        else
            log_warn "Vault not accessible — store the token manually:"
            log_warn "  vault kv put secret/gitlab/registry-pull-token username=${REGISTRY_USER} token=${REGISTRY_TOKEN}"
        fi
    else
        log_warn "Failed to create deploy token via Rails console"
        log_warn "Output: ${DEPLOY_TOKEN_OUTPUT}"
        log_warn "Create a deploy token manually in GitLab (see docs above)"
    fi
fi

# ─── Summary ───────────────────────────────────────────────────────────

echo ""
log_info "Registration complete. Summary:"
echo ""
echo "  Workload cluster: ${ENV}"
echo "  Platform cluster: ${PLATFORM_ENV}"
if [[ "${WORKLOAD_SERVER:-}" != "https://PENDING_REGISTRATION" ]]; then
    echo "  Cluster URL:      ${WORKLOAD_SERVER:-<unknown>}"
fi
echo ""
echo "  Next steps:"
echo "  1. Update k8s/argocd/apps/gitlab-appset.yaml destination.server to the workload cluster URL"
echo "  2. Verify External Secrets: kubectl --kubeconfig ${WORKLOAD_KUBECONFIG} get clustersecretstore vault-backend"
echo "  3. Push an app to GitLab devhub group — ArgoCD will auto-discover and deploy it"
echo ""
