#!/bin/bash
set -euo pipefail

# =============================================================================
# Vault Initialization and Configuration
# =============================================================================
# Usage: ./setup-vault.sh --env <env> <action>
#   all | init | unseal | configure | seed-secrets
#   admin-token | renew-admin | new-root | revoke-root | status
#
# Key handling
# ------------
# With cloud KMS auto-unseal (tofu provisions the key; deploy.sh wires it up)
# Vault unseals itself and the only sensitive artefacts are *recovery* keys,
# which are printed once and never written into the cluster.
#
# Without KMS, unseal keys are written to a gitignored file with mode 600. They
# are deliberately NOT copied into a Kubernetes secret any more: keeping unseal
# keys plus the root token inside the very cluster Vault protects makes read
# access to one namespace's secrets equivalent to holding Vault's master key.
#
# `all` creates a long-lived `platform-admin` token, stores it in the same keys
# file, and then revokes the root token. Admin work uses that token from then on.
# Vault 2.0 authenticates sys/generate-root (CVE-2026-5807), so the key quorum
# alone can no longer mint a new root: `new-root` needs the admin token too. Losing
# the keys file therefore means re-initialising Vault — the same as losing the
# unseal keys already did.
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

parse_env_arg "$@"
# Empty-array expansion is unsafe under `set -u` on older bash.
if [[ ${#ARGS[@]} -gt 0 ]]; then set -- "${ARGS[@]}"; else set --; fi

setup_paths
parse_config
use_env_kubeconfig

# Keys file stored per-environment (gitignored, mode 600)
KEYS_FILE="${SCRIPT_ENV_DIR}/vault-init-keys.json"

VAULT_EXEC="kubectl exec -n vault vault-0 -- env VAULT_ADDR=http://127.0.0.1:8200"

# Credentials tofu generated (used by seed-secrets)
SECRETS_FILE="${SCRIPT_ENV_DIR}/secrets.env"
[[ -f "$SECRETS_FILE" ]] && { set -a; source "$SECRETS_FILE"; set +a; }

# =============================================================================
# Helpers
# =============================================================================

vault_status_json() {
    $VAULT_EXEC vault status -format=json 2>/dev/null || echo '{}'
}

# True when Vault is configured with a cloud KMS seal (auto-unseal).
auto_unseal_enabled() {
    local seal
    seal="$(vault_status_json | jq -r '.type // empty')"
    case "$seal" in
        awskms|azurekeyvault|gcpckms|transit) return 0 ;;
        *) return 1 ;;
    esac
}

require_keys_file() {
    if [[ ! -f "${KEYS_FILE}" ]]; then
        log_error "Vault key material not found: ${KEYS_FILE}"
        log_error ""
        log_error "This file is written once, at init, and is intentionally not"
        log_error "backed up into the cluster. If it is lost:"
        log_error "  - with KMS auto-unseal: Vault keeps running, but admin access is"
        log_error "    gone with the admin token that was stored here"
        log_error "  - without KMS: Vault cannot be unsealed either"
        log_error "  - without KMS: Vault cannot be unsealed and must be re-initialised"
        exit 1
    fi
}

# The admin token replaces root for day-to-day platform work, and — since Vault
# 2.0 made sys/generate-root an authenticated endpoint (CVE-2026-5807) — it is also
# what makes root regeneration possible at all. Unseal keys alone are no longer
# enough.
root_token() {
    require_keys_file
    local token
    token="$(jq -r '.admin_token // .root_token // empty' "${KEYS_FILE}")"
    if [[ -z "$token" ]]; then
        log_error "No admin or root token in ${KEYS_FILE}."
        log_error "Vault 2.0 requires a valid token to regenerate root, so the key"
        log_error "quorum on its own cannot recover admin access. Options:"
        log_error "  - use another token: VAULT_TOKEN=<token> ./setup-vault.sh --env ${ENV} ..."
        log_error "  - or re-initialise Vault (destroys its data)"
        exit 1
    fi
    echo "$token"
}

# Run a vault command with an admin token.
vault_admin() {
    local token="${VAULT_TOKEN:-$(root_token)}"
    kubectl exec -n vault vault-0 -- env \
        VAULT_ADDR=http://127.0.0.1:8200 \
        VAULT_TOKEN="$token" \
        vault "$@"
}

# Same, but forwards stdin (policy writes).
vault_admin_stdin() {
    local token="${VAULT_TOKEN:-$(root_token)}"
    kubectl exec -i -n vault vault-0 -- env \
        VAULT_ADDR=http://127.0.0.1:8200 \
        VAULT_TOKEN="$token" \
        vault "$@"
}

# =============================================================================
# Init / unseal
# =============================================================================

init_vault() {
    log_step "Initializing Vault..."

    local status
    status="$(vault_status_json)"

    # Compare the raw value: jq's `//` substitutes on `false` as well as null.
    if [[ "$(echo "$status" | jq -r '.initialized')" == "true" ]]; then
        log_warn "Vault is already initialized"
        return 0
    fi

    local init_output
    if auto_unseal_enabled; then
        log_info "Cloud KMS seal detected — initialising with recovery keys"
        init_output="$($VAULT_EXEC vault operator init -format=json \
            -recovery-shares=5 -recovery-threshold=3)"
    else
        log_warn "No cloud KMS seal — Vault needs manual unsealing after every restart"
        log_warn "Provision the KMS key with tofu to enable auto-unseal"
        init_output="$($VAULT_EXEC vault operator init -format=json)"
    fi

    umask 077
    mkdir -p "${SCRIPT_ENV_DIR}"
    echo "$init_output" > "${KEYS_FILE}"
    chmod 600 "${KEYS_FILE}"

    # Remove any legacy in-cluster copy of the key material.
    if kubectl get secret vault-init-keys -n vault &>/dev/null; then
        kubectl delete secret vault-init-keys -n vault
        log_warn "Deleted the legacy vault-init-keys secret from the cluster."
        log_warn "Unseal keys and a root token stored next to the data they protect"
        log_warn "made namespace-level secret read equivalent to Vault root."
    fi

    log_info "Vault initialized. Key material: ${KEYS_FILE} (mode 600)"
    echo ""
    log_warn "MOVE THIS FILE TO OFFLINE STORAGE (password manager / HSM / sealed envelope)."
    log_warn "It is the only copy — nothing writes it back into the cluster."
    echo ""

    if auto_unseal_enabled; then
        echo "Recovery keys (needed only to generate a new root token):"
        echo "$init_output" | jq -r '.recovery_keys_b64[]' | sed 's/^/  /'
    else
        echo "Unseal keys (3 of 5 required at every restart):"
        echo "$init_output" | jq -r '.unseal_keys_b64[]' | sed 's/^/  /'
    fi
    echo ""
}

unseal_vault() {
    if auto_unseal_enabled; then
        log_info "Cloud KMS auto-unseal is active — nothing to unseal"
        $VAULT_EXEC vault status 2>/dev/null | grep -E 'Seal Type|Sealed' || true
        return 0
    fi

    log_step "Unsealing Vault..."
    require_keys_file

    local keys
    keys="$(jq -r '.unseal_keys_b64[]' "${KEYS_FILE}" | head -3)"

    for pod in vault-0 vault-1 vault-2; do
        kubectl get pod "$pod" -n vault &>/dev/null || continue
        log_info "Unsealing $pod..."
        for key in $keys; do
            kubectl exec -n vault "$pod" -- env VAULT_ADDR=http://127.0.0.1:8200 \
                vault operator unseal "$key" >/dev/null 2>&1 || true
        done
    done

    log_info "Vault unsealed"
}

# =============================================================================
# Configuration
# =============================================================================

configure_k8s_auth() {
    log_step "Configuring Kubernetes authentication..."

    vault_admin auth enable kubernetes 2>/dev/null || log_info "kubernetes auth already enabled"

    kubectl exec -n vault vault-0 -- sh -c "
        export VAULT_ADDR=http://127.0.0.1:8200
        export VAULT_TOKEN='${VAULT_TOKEN:-$(root_token)}'
        vault write auth/kubernetes/config \
            kubernetes_host=https://\$KUBERNETES_SERVICE_HOST:\$KUBERNETES_SERVICE_PORT \
            kubernetes_ca_cert=@/var/run/secrets/kubernetes.io/serviceaccount/ca.crt
    "

    log_info "Kubernetes authentication configured"
}

# A named admin identity, so the root token can be revoked without losing the
# ability to administer Vault. Stored alongside the unseal keys — the file is
# already the crown jewels, and Vault 2.0 needs a token for root regeneration.
create_admin_token() {
    require_keys_file

    if [[ -n "$(jq -r '.admin_token // empty' "${KEYS_FILE}")" ]]; then
        # Still valid? A stale token in the file is worse than none.
        if kubectl exec -n vault vault-0 -- env VAULT_ADDR=http://127.0.0.1:8200 \
             VAULT_TOKEN="$(jq -r '.admin_token' "${KEYS_FILE}")" \
             vault token lookup >/dev/null 2>&1; then
            log_info "Platform admin token already exists"
            return 0
        fi
        log_warn "Stored admin token is no longer valid — creating a new one"
    fi

    log_step "Creating the platform admin token..."

    vault_admin_stdin policy write platform-admin - <<'EOF'
# Everything except the ability to hide its own tracks: audit devices are
# root-only on purpose, so a compromised admin token cannot disable auditing.
path "*" {
  capabilities = ["create", "read", "update", "delete", "list", "sudo"]
}
path "sys/audit*" {
  capabilities = ["deny"]
}
EOF

    local token
    token="$(vault_admin token create -policy=platform-admin -orphan \
        -display-name=platform-admin -ttl=8760h -renewable=true -format=json \
        | jq -r '.auth.client_token')"
    [[ -n "$token" && "$token" != "null" ]] || { log_error "Could not create the admin token"; exit 1; }

    local tmp; tmp="$(mktemp)"
    jq --arg t "$token" '.admin_token = $t' "${KEYS_FILE}" > "$tmp" && mv "$tmp" "${KEYS_FILE}"
    chmod 600 "${KEYS_FILE}"

    log_info "Admin token stored in ${KEYS_FILE} (1 year, renewable)"
    log_info "Renew with: ./setup-vault.sh --env ${ENV} renew-admin"
}

renew_admin_token() {
    require_keys_file
    local token
    token="$(jq -r '.admin_token // empty' "${KEYS_FILE}")"
    [[ -n "$token" ]] || { log_error "No admin token in ${KEYS_FILE}"; exit 1; }

    kubectl exec -n vault vault-0 -- env VAULT_ADDR=http://127.0.0.1:8200 \
        VAULT_TOKEN="$token" vault token renew >/dev/null
    log_info "Admin token renewed for another year"
}

create_platform_roles() {
    log_step "Creating Vault policies and roles..."

    vault_admin secrets enable -path=secret kv-v2 2>/dev/null || log_info "KV v2 already enabled at secret/"

    # External Secrets: platform credentials and app secrets only. The previous
    # policy granted read on secret/data/* — every secret Vault holds, including
    # other clusters' material.
    vault_admin_stdin policy write external-secrets - <<'EOF'
path "secret/data/platform/*" {
  capabilities = ["read"]
}
path "secret/metadata/platform/*" {
  capabilities = ["list", "read"]
}
path "secret/data/apps/*" {
  capabilities = ["read"]
}
path "secret/metadata/apps/*" {
  capabilities = ["list", "read"]
}
path "secret/data/forgejo/registry-pull-token" {
  capabilities = ["read"]
}
EOF

    vault_admin write auth/kubernetes/role/external-secrets \
        bound_service_account_names=external-secrets \
        bound_service_account_namespaces=external-secrets \
        policies=external-secrets \
        ttl=1h

    # Raft snapshots: the CronJob authenticates as itself and may do exactly one
    # thing. No root token in a scheduled job.
    vault_admin_stdin policy write vault-snapshot - <<'EOF'
path "sys/storage/raft/snapshot" {
  capabilities = ["read"]
}
EOF

    vault_admin write auth/kubernetes/role/vault-snapshot \
        bound_service_account_names=vault-snapshot \
        bound_service_account_namespaces=vault \
        policies=vault-snapshot \
        ttl=15m

    log_info "Policies created: external-secrets, vault-snapshot"

    # ClusterSecretStore for the platform cluster's own ExternalSecrets. Skipped
    # when the operator is not installed yet — Vault configuration is still valid
    # without it, and deploy.sh's platform-secrets step applies it later.
    if kubectl get crd clustersecretstores.external-secrets.io &>/dev/null; then
        kubectl apply -f "${BASE_DIR}/devops/external-secrets/cluster-secret-store.yaml"
        log_info "ClusterSecretStore 'vault-backend' applied"
    else
        log_warn "External Secrets Operator not installed — skipping the ClusterSecretStore"
        log_warn "Install it, then: ./devhub deploy --env ${ENV} external-secrets"
    fi
}

# Seed the platform's own credentials into Vault so Vault — not a pile of
# hand-created K8s secrets — is the source of truth. Idempotent: existing values
# are left alone unless --force is passed.
seed_platform_secrets() {
    log_step "Seeding platform secrets into Vault..."

    local force="${1:-}"

    _kv_exists() {
        vault_admin kv get -format=json "secret/$1" &>/dev/null
    }

    _read_k8s() {
        kubectl get secret "$2" -n "$1" -o jsonpath="{.data.$3}" 2>/dev/null | base64 -d 2>/dev/null || true
    }

    # PostgreSQL — from tofu (managed) or from the bootstrap secrets (local).
    #
    # Read from data-services, never from the consuming namespaces: those Secrets
    # are the ones platform-secrets deletes to hand ownership to External Secrets,
    # so on a re-seed they may be absent — and seeding an empty password produces a
    # Secret that syncs happily and then fails authentication at the database.
    local pg_admin="${PG_ADMIN_PASSWORD:-$(_read_k8s data-services postgresql-credentials postgres-password)}"
    local pg_keycloak="${PG_KEYCLOAK_PASSWORD:-$(_read_k8s data-services postgresql-credentials keycloak-password)}"
    local pg_forgejo="${PG_FORGEJO_PASSWORD:-$(_read_k8s data-services postgresql-credentials forgejo-password)}"
    [[ -n "$pg_forgejo" ]] || pg_forgejo="$(_read_k8s data-services forgejo-db-credentials password)"

    if [[ -n "$pg_keycloak" && -n "$pg_forgejo" ]]; then
        if [[ "$force" == "--force" ]] || ! _kv_exists platform/postgres; then
            # The usernames are here because the Keycloak Operator wants both keys
            # in one secret, and keeping them together means a rotation is a single
            # `vault kv put` rather than a put plus a manifest edit.
            vault_admin kv put secret/platform/postgres \
                admin-password="${pg_admin}" \
                keycloak-username="keycloak" \
                keycloak-password="${pg_keycloak}" \
                forgejo-username="forgejo" \
                forgejo-password="${pg_forgejo}" >/dev/null
            log_info "  secret/platform/postgres"
        else
            log_info "  secret/platform/postgres (exists, left as-is)"
        fi
    else
        log_error "  no PostgreSQL credentials found to seed (keycloak='${pg_keycloak:+set}' forgejo='${pg_forgejo:+set}')"
        log_error "  Seeding a partial secret/platform/postgres would break Keycloak or"
        log_error "  Forgejo on the next restart, so nothing was written."
        exit 1
    fi

    # Redis / Valkey
    local redis_pw="${REDIS_PASSWORD:-}"
    if [[ -n "$redis_pw" ]]; then
        if [[ "$force" == "--force" ]] || ! _kv_exists platform/redis; then
            vault_admin kv put secret/platform/redis password="${redis_pw}" >/dev/null
            log_info "  secret/platform/redis"
        else
            log_info "  secret/platform/redis (exists, left as-is)"
        fi
    fi

    # Grafana admin
    local graf_user graf_pw
    graf_user="$(_read_k8s monitoring grafana-admin-secret admin-user)"
    graf_pw="$(_read_k8s monitoring grafana-admin-secret admin-password)"
    if [[ -n "$graf_pw" ]]; then
        if [[ "$force" == "--force" ]] || ! _kv_exists platform/grafana; then
            vault_admin kv put secret/platform/grafana \
                admin-user="${graf_user:-admin}" \
                admin-password="${graf_pw}" >/dev/null
            log_info "  secret/platform/grafana"
        else
            log_info "  secret/platform/grafana (exists, left as-is)"
        fi
    fi

    # Alertmanager webhook — created (possibly empty) so the ExternalSecret resolves.
    if [[ "$force" == "--force" ]] || ! _kv_exists platform/alertmanager; then
        local webhook
        webhook="$(_read_k8s monitoring alertmanager-slack webhook-url)"
        vault_admin kv put secret/platform/alertmanager webhook-url="${webhook}" >/dev/null
        log_info "  secret/platform/alertmanager${webhook:+ (webhook set)}"
    fi

    log_info "Rotate any of these with: vault kv put secret/platform/<name> <key>=<value>"
}

# Regenerate a *root* token. Rarely needed — the admin token covers normal work —
# but some operations (audit devices, seal migration) still want real root.
#
# Since Vault 2.0, sys/generate-root is authenticated: the key quorum alone will
# not do it, so this needs the admin token (or VAULT_TOKEN) as well.
new_root_token() {
    require_keys_file

    if [[ -n "$(jq -r '.root_token // empty' "${KEYS_FILE}")" ]]; then
        log_info "A root token is already present in ${KEYS_FILE}"
        return 0
    fi

    local admin="${VAULT_TOKEN:-$(jq -r '.admin_token // empty' "${KEYS_FILE}")}"
    if [[ -z "$admin" ]]; then
        log_error "Root generation needs a valid token as well as the key quorum"
        log_error "(Vault 2.0 authenticates sys/generate-root)."
        log_error "Set VAULT_TOKEN=<token> and re-run."
        exit 1
    fi

    log_step "Generating a new root token from the key quorum..."

    local vx=(kubectl exec -n vault vault-0 -- env
              VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN="$admin")

    # Cancel any half-finished attempt; a stale nonce makes every share fail.
    "${vx[@]}" vault operator generate-root -cancel >/dev/null 2>&1 || true

    local init nonce otp threshold
    init="$("${vx[@]}" vault operator generate-root -init -format=json 2>/dev/null || echo '{}')"
    nonce="$(echo "$init" | jq -r '.nonce // empty')"
    otp="$(echo "$init" | jq -r '.otp // empty')"
    [[ -n "$nonce" && -n "$otp" ]] || { log_error "Could not start root generation"; exit 1; }

    threshold="$(vault_status_json | jq -r '.t // 3')"

    local i key out encoded=""
    for ((i = 0; i < threshold; i++)); do
        key="$(jq -r ".unseal_keys_b64[$i] // .recovery_keys_b64[$i] // empty" "${KEYS_FILE}")"
        [[ -n "$key" ]] || { log_error "Only $i keys available, need ${threshold}"; exit 1; }
        out="$("${vx[@]}" vault operator generate-root -nonce="$nonce" -format=json "$key" 2>/dev/null || echo '{}')"
        encoded="$(echo "$out" | jq -r '.encoded_token // empty')"
    done
    [[ -n "$encoded" ]] || { log_error "Root generation did not complete"; exit 1; }

    local token
    token="$("${vx[@]}" vault operator generate-root \
        -decode="$encoded" -otp="$otp" -format=json 2>/dev/null | jq -r '.token // empty')"
    [[ -n "$token" ]] || { log_error "Could not decode the generated root token"; exit 1; }

    local tmp; tmp="$(mktemp)"
    jq --arg t "$token" '.root_token = $t' "${KEYS_FILE}" > "$tmp" && mv "$tmp" "${KEYS_FILE}"
    chmod 600 "${KEYS_FILE}"

    log_info "New root token written to ${KEYS_FILE}"
    log_warn "Revoke it when you are done: ./setup-vault.sh --env ${ENV} revoke-root"
}

# The root token exists to bootstrap. Leaving it in a file on a laptop is a
# standing risk with no upside.
revoke_root_token() {
    require_keys_file
    local token
    token="$(jq -r '.root_token // empty' "${KEYS_FILE}")"

    if [[ -z "$token" ]]; then
        log_info "Root token already revoked"
        return 0
    fi

    log_step "Revoking the initial root token..."

    kubectl exec -n vault vault-0 -- env \
        VAULT_ADDR=http://127.0.0.1:8200 VAULT_TOKEN="$token" \
        vault token revoke -self >/dev/null 2>&1 || true

    # Drop it from the key file too, so the file only holds unseal/recovery keys.
    local tmp
    tmp="$(mktemp)"
    jq 'del(.root_token)' "${KEYS_FILE}" > "$tmp" && mv "$tmp" "${KEYS_FILE}"
    chmod 600 "${KEYS_FILE}"

    log_info "Root token revoked and removed from ${KEYS_FILE}"
    log_info "Need admin access later: ./setup-vault.sh --env ${ENV} new-root"
}

print_summary() {
    echo ""
    echo "=============================================="
    echo "Vault Setup Complete"
    echo "=============================================="
    echo ""
    if auto_unseal_enabled; then
        echo "  Seal:       cloud KMS auto-unseal (restarts unseal themselves)"
    else
        echo "  Seal:       manual (3 of 5 unseal keys after every restart)"
        echo "              Provision the KMS key with tofu to remove this step."
    fi
    echo "  Keys:       ${KEYS_FILE}  (mode 600, gitignored, NOT in the cluster)"
    echo "  Root token: revoked — regenerate with './setup-vault.sh --env '"${ENV}"' new-root'"
    echo "  Snapshots:  CronJob vault-raft-snapshot every 6h → PVC vault-snapshots"
    echo ""
    echo "  Platform credentials live at secret/platform/* and are delivered by"
    echo "  External Secrets. Finish the switch with:"
    echo "    ./deploy.sh --env ${ENV} platform-secrets"
    echo ""
}

# =============================================================================
# Main
# =============================================================================

main() {
    local action="${1:-all}"

    echo "=============================================="
    echo "Vault Setup (${ENV}) — ${action}"
    echo "=============================================="

    case "$action" in
        all)
            init_vault
            unseal_vault
            configure_k8s_auth
            create_platform_roles
            create_admin_token
            seed_platform_secrets
            revoke_root_token
            print_summary
            ;;
        init)          init_vault ;;
        unseal)        unseal_vault ;;
        configure)     configure_k8s_auth && create_platform_roles && create_admin_token ;;
        seed-secrets)  seed_platform_secrets "${2:-}" ;;
        admin-token)   create_admin_token ;;
        renew-admin)   renew_admin_token ;;
        new-root)      new_root_token ;;
        revoke-root)   revoke_root_token ;;
        status)        $VAULT_EXEC vault status || true ;;
        *)
            echo "Usage: $0 --env <env> [all|init|unseal|configure|seed-secrets|admin-token|renew-admin|new-root|revoke-root|status]"
            exit 1
            ;;
    esac
}

main "$@"
