#!/bin/bash
set -euo pipefail

# =============================================================================
# Keycloak Realm and Client Configuration Script
# =============================================================================
# Creates the devops realm and configures OIDC clients for all services.
#
# Usage: ./setup-keycloak.sh --env local|upcloud-dev|upcloud-prod|azure-dev|azure-prod|gcp-dev|gcp-prod|aws-dev|aws-prod \
#                            [all|realm|clients|user|idp]
#
# The 'idp' action configures a cloud identity provider:
#   azure-*: Entra ID federation (via OIDC, App Roles → Keycloak groups)
#   gcp-*:   Google social login (requires manual-secrets.env filled in)
#   aws-*:   AWS Cognito OIDC federation (Cognito Groups → Keycloak groups)
# 'all' automatically includes 'idp' for azure/gcp/aws environments.
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

parse_env_arg "$@"
# Empty-array expansion is unsafe under `set -u` on older bash.
if [[ ${#ARGS[@]} -gt 0 ]]; then set -- "${ARGS[@]}"; else set --; fi

setup_paths
parse_config
use_env_kubeconfig
# Repo convention: never touch a cluster without checking it is the right one.
# Without this, `--env local` while a prod kubeconfig is active would rewrite the
# prod realm's clients and cross-write oidc-secrets.env.
require_cluster_match

# Credentials from tofu (secrets.env) and manually-provided ones
# (manual-secrets.env, e.g. the Google OAuth client). sync-tofu-outputs.sh writes
# both; they replaced the per-cloud *-idp.env files.
for f in "${SCRIPT_ENV_DIR}/secrets.env" "${SCRIPT_ENV_DIR}/manual-secrets.env"; do
    [[ -f "$f" ]] && { set -a; source "$f"; set +a; }
done

# Configuration
REALM="devops"
KCADM="/opt/keycloak/bin/kcadm.sh"

# Server-side OIDC calls always go through the in-cluster Service:
#   - on local, *.localhost resolves to 127.0.0.1 inside glibc containers
#     (RFC 6761), so the external name dials the pod itself
#   - on clouds, pods cannot hairpin through their own public load balancer
#     IP (Forgejo's discovery fetch timed out against keycloak.<domain>)
# KC_HOSTNAME_BACKCHANNEL_DYNAMIC=true on the Keycloak CR makes the internal
# discovery document carry matching internal token/jwks endpoints, while
# browser-facing URLs stay on KC_HOSTNAME.
KEYCLOAK_INTERNAL_URL="http://keycloak-service.keycloak.svc.cluster.local:8080"

# Execute kcadm command in Keycloak pod
kcadm() {
    kubectl exec -n keycloak keycloak-0 -- ${KCADM} "$@"
}

# As kcadm, but forwards stdin — for `create ... -f -` with a JSON body that
# kcadm's -s syntax cannot express (nested JSON config values).
kcadm_stdin() {
    kubectl exec -i -n keycloak keycloak-0 -- ${KCADM} "$@"
}

# Login to Keycloak admin
kcadm_login() {
    local password=$(kubectl get secret keycloak-admin-secret -n keycloak -o jsonpath='{.data.password}' | base64 -d)
    kcadm config credentials --server http://localhost:8080 --realm master --user admin --password "${password}" >/dev/null
    log_info "Logged in to Keycloak admin CLI"
}

# Create realm
create_realm() {
    log_step "Creating realm: ${REALM}..."

    if kcadm get realms/${REALM} >/dev/null 2>&1; then
        log_warn "Realm ${REALM} already exists"
        return 0
    fi

    kcadm create realms -s realm=${REALM} -s enabled=true \
        -s displayName="DevOps Platform" \
        -s registrationAllowed=false \
        -s loginWithEmailAllowed=true \
        -s duplicateEmailsAllowed=false \
        -s resetPasswordAllowed=true \
        -s editUsernameAllowed=false \
        -s bruteForceProtected=true \
        -s sslRequired=external

    log_info "Realm ${REALM} created"
}

# Create (or read back) an OIDC client, printing its secret on stdout.
#
# Hardening, applied to new clients and retrofitted onto existing ones:
#   - webOrigins "+" derives the CORS allow-list from the registered redirect
#     URIs. "*" put a wildcard on the token endpoint, so any origin could read
#     token responses.
#   - directAccessGrantsEnabled=false turns off the ROPC password grant, which
#     trades a username/password straight for tokens, bypassing the browser
#     flow and any MFA the upstream IdP enforces — and the local break-glass
#     accounts have passwords. Nothing in this repo uses ROPC: the e2e suite and
#     mint-woodpecker-token.sh both drive the browser SSO flow.
#   - post.logout.redirect.uris "+" means "the registered redirect URIs";
#     "*" made every client an open redirect.
#
# None of these clients needs CORS at all: every one of them exchanges the code
# server-side (Grafana, Forgejo, Vault, argocd-server, or Envoy Gateway acting
# for Homepage/Portal/Headlamp/apps). Note that Keycloak's "+" skips redirect
# URIs containing a wildcard, so the shared `apps` client — whose redirect is
# https://*.<domain>/oauth2/callback — resolves to no web origins at all. That
# is correct for it: the gateway, not a browser script, calls the token endpoint.
CLIENT_HARDENING=(
    -s standardFlowEnabled=true
    -s directAccessGrantsEnabled=false
    -s serviceAccountsEnabled=false
    -s 'webOrigins=["+"]'
    -s 'attributes={"post.logout.redirect.uris":"+"}'
)

create_client() {
    local client_id="$1"
    local redirect_uri="$2"
    local public="${3:-false}"

    local existing client_secret
    existing="$(kcadm get clients -r ${REALM} --fields id,clientId 2>/dev/null | grep "\"clientId\" : \"${client_id}\"" -B 1 | grep "\"id\"" | cut -d'"' -f4 || echo "")"

    if [[ -n "$existing" ]]; then
        # A client created by an older run still carries webOrigins=*, ROPC and
        # the post-logout wildcard. Re-applying the hardened flags is idempotent
        # and the only way those clients ever get fixed; tolerate failure so a
        # re-run is never fatal.
        #
        # attributes is merged with jq rather than passed as a literal object:
        # kcadm's `-s attributes={...}` replaces the whole map, which would drop
        # the defaults Keycloak wrote at creation (backchannel-logout flags,
        # secret creation time, device-grant switch, …).
        local -a harden=(
            -s standardFlowEnabled=true
            -s directAccessGrantsEnabled=false
            -s serviceAccountsEnabled=false
            -s 'webOrigins=["+"]'
        )
        local attrs
        attrs="$(kcadm get "clients/${existing}" -r ${REALM} 2>/dev/null \
            | jq -c '(.attributes // {}) + {"post.logout.redirect.uris":"+"}' 2>/dev/null || true)"
        [[ -n "$attrs" ]] && harden+=(-s "attributes=${attrs}")

        kcadm update "clients/${existing}" -r ${REALM} "${harden[@]}" >&2 \
            || log_warn "Could not re-apply the hardened settings to client ${client_id}"

        client_secret="$(kcadm get clients/${existing}/client-secret -r ${REALM} 2>/dev/null | grep "value" | cut -d'"' -f4 || echo "")"
        if [[ -n "$client_secret" ]]; then
            echo "${client_secret}"
            return 0
        fi
        log_error "Client ${client_id} exists but its secret could not be read"
        return 1
    fi

    client_secret="$(openssl rand -hex 32)"

    if ! kcadm create clients -r ${REALM} \
        -s clientId=${client_id} \
        -s enabled=true \
        -s protocol=openid-connect \
        -s publicClient=${public} \
        "${CLIENT_HARDENING[@]}" \
        -s "redirectUris=[\"${redirect_uri}\"]" \
        -s secret="${client_secret}" >&2; then
        log_error "kcadm create failed for the OIDC client '${client_id}'"
        return 1
    fi

    echo "${client_secret}"
}

# require_client_secret <var-name> <client-id> <redirect-uri> [public]
#
# `local x=$(create_client ...)` swallows the command's exit status, so a failed
# kcadm create used to leave x empty and the run then wrote client-secret="" into
# a Kubernetes secret and into oidc-secrets.env: SSO for that service silently
# broken while the script reported success. Check the status *and* the value.
require_client_secret() {
    local _rcs_var="$1" _rcs_id="$2" _rcs_uri="$3" _rcs_public="${4:-false}"
    local _rcs_value _rcs_rc=0

    _rcs_value="$(create_client "$_rcs_id" "$_rcs_uri" "$_rcs_public")" || _rcs_rc=$?
    if [[ $_rcs_rc -ne 0 ]]; then
        log_error "Could not configure the OIDC client '${_rcs_id}' (exit ${_rcs_rc})"
        log_error "Nothing was written — re-run once Keycloak is healthy:"
        log_error "  ./devhub keycloak --env ${ENV} clients"
        exit 1
    fi
    # An opaque Keycloak secret is a long single token. Anything shorter, or
    # containing whitespace, is an error message that leaked through a pipeline.
    if [[ ${#_rcs_value} -lt 20 || "$_rcs_value" == *[[:space:]]* ]]; then
        log_error "Implausible client secret for '${_rcs_id}' (${#_rcs_value} chars) — refusing to store it"
        exit 1
    fi

    printf -v "$_rcs_var" '%s' "$_rcs_value"
}

# Create groups
create_groups() {
    log_step "Creating groups..."

    for group in "devops-admins" "developers" "viewers"; do
        if kcadm get groups -r ${REALM} --fields name 2>/dev/null | grep -q "\"name\" : \"${group}\""; then
            log_warn "Group ${group} already exists"
            continue
        fi

        kcadm create groups -r ${REALM} -s name=${group}
        log_info "Created group: ${group}"
    done

    # devops-admins may administer this realm through the realm-scoped console
    # (https://keycloak.<domain>/admin/${REALM}/console/) — with the Entra App
    # Role mapped onto the group, realm administration is assigned in Entra.
    # The master realm stays local-only break-glass. add-roles is idempotent
    # in effect but not in exit code, hence the tolerant call.
    kcadm add-roles -r ${REALM} --gname devops-admins \
        --cclientid realm-management --rolename realm-admin 2>/dev/null \
        || log_warn "realm-admin grant for devops-admins already present (or failed — check manually)"
    log_info "devops-admins granted realm-admin (realm console via Entra)"
}

# Configure groups client scope
configure_groups_scope() {
    log_step "Configuring groups client scope..."

    local scope_id=$(kcadm get client-scopes -r ${REALM} --fields id,name 2>/dev/null | grep -B 1 "\"name\" : \"groups\"" | grep "\"id\"" | cut -d'"' -f4 || echo "")

    if [[ -z "$scope_id" ]]; then
        scope_id=$(kcadm create client-scopes -r ${REALM} \
            -s name=groups \
            -s protocol=openid-connect \
            -s 'attributes={"include.in.token.scope":"true","display.on.consent.screen":"true"}' -i 2>&1)
        log_info "Created groups client scope: ${scope_id}"

        kcadm create client-scopes/${scope_id}/protocol-mappers/models -r ${REALM} \
            -s name=groups \
            -s protocol=openid-connect \
            -s protocolMapper=oidc-group-membership-mapper \
            -s 'config={"full.path":"false","id.token.claim":"true","access.token.claim":"true","claim.name":"groups","userinfo.token.claim":"true"}' >/dev/null
        log_info "Added group membership mapper to groups scope"
    else
        log_warn "Groups client scope already exists"
    fi

    kcadm update realms/${REALM}/default-default-client-scopes/${scope_id} -r ${REALM} 2>/dev/null || true

    for client_name in "grafana" "argocd" "forgejo" "vault" "headlamp" "homepage" "portal" "apps"; do
        local client_id=$(kcadm get clients -r ${REALM} --fields id,clientId 2>/dev/null | grep "\"clientId\" : \"${client_name}\"" -B 1 | grep "\"id\"" | cut -d'"' -f4 || echo "")
        if [[ -n "$client_id" ]]; then
            kcadm update clients/${client_id}/default-client-scopes/${scope_id} -r ${REALM} 2>/dev/null || true
        fi
    done
    log_info "Groups scope added to all OIDC clients"
}

# MCP authorization-server prep — realm-wide, one-time, idempotent.
#
# Keycloak brokers MCP clients (Claude Code, VS Code, MCP Inspector) through
# the same realm and IdP federation as browsers. Three pieces:
#
#   1. An optional `mcp` client scope whose audience mapper stamps `aud: mcp`
#      into access tokens. The devhub-app chart's gateway JWT policy requires
#      that audience on /mcp routes — one shared audience for every app,
#      mirroring the shared `apps` browser client. Per-app audiences (their
#      own scope + mapper) are a later hardening step.
#   2. Offline sessions: MCP clients request `offline_access` (advertised in
#      each app's RFC 9728 metadata) so the connection outlives the 10h SSO
#      session cap. The idle window is set explicitly rather than inherited.
#      Note: offline tokens are Keycloak's own — offboarding a user in the
#      upstream IdP does not revoke them; see the realm console's Sessions view.
#   3. A client policy accepting OAuth Client ID Metadata Documents: MCP
#      clients identify themselves with a client_id URL, no registration.
#      Needs `features: cimd` in keycloak-cr.yaml (experimental) — without it
#      the profile PUT fails, which is warned about rather than fatal so the
#      scope and session pieces still apply.
configure_mcp() {
    log_step "Configuring MCP authorization support..."

    # 1. `mcp` client scope with a static audience, realm-wide optional so any
    #    client (including CIMD ones) may request it without being pre-wired.
    local scope_id=$(kcadm get client-scopes -r ${REALM} --fields id,name 2>/dev/null | grep -B 1 "\"name\" : \"mcp\"" | grep "\"id\"" | cut -d'"' -f4 || echo "")
    if [[ -z "$scope_id" ]]; then
        scope_id=$(kcadm create client-scopes -r ${REALM} \
            -s name=mcp \
            -s protocol=openid-connect \
            -s 'attributes={"include.in.token.scope":"true","display.on.consent.screen":"true","consent.screen.text":"Access MCP servers"}' -i 2>&1)
        log_info "Created mcp client scope: ${scope_id}"

        kcadm create client-scopes/${scope_id}/protocol-mappers/models -r ${REALM} \
            -s name=mcp-audience \
            -s protocol=openid-connect \
            -s protocolMapper=oidc-audience-mapper \
            -s 'config={"included.custom.audience":"mcp","access.token.claim":"true","id.token.claim":"false","introspection.token.claim":"true"}' >/dev/null
        log_info "Added audience mapper (aud: mcp) to mcp scope"
    else
        log_warn "mcp client scope already exists"
    fi
    kcadm update realms/${REALM}/default-optional-client-scopes/${scope_id} -r ${REALM} 2>/dev/null || true
    log_info "mcp scope registered as a realm optional scope"

    # 2. Offline session policy: 30 sliding idle days. Every refresh resets the
    #    window, so an MCP connection in weekly use never re-authenticates.
    kcadm update realms/${REALM} -s offlineSessionIdleTimeout=2592000
    log_info "Offline session idle timeout set to 30 days"

    # 3. CIMD client profile + policy. The profiles/policies endpoints replace
    #    the whole realm-owned list on PUT — this realm defines no others, and
    #    the existence check keeps re-runs from clobbering manual edits.
    local trusted_domains='["claude.ai","*.claude.ai","vscode.dev","code.visualstudio.com","localhost","127.0.0.1"]'

    if kcadm get realms/${REALM}/client-policies/profiles -r ${REALM} 2>/dev/null | grep -q '"name" : "mcp-cimd-clients"'; then
        log_warn "CIMD client profile already exists"
    else
        local profile_body
        profile_body=$(cat <<EOF
{
  "profiles": [
    {
      "name": "mcp-cimd-clients",
      "description": "Accept MCP clients that identify via OAuth Client ID Metadata Documents",
      "executors": [
        {
          "executor": "client-id-metadata-document",
          "configuration": {
            "cimd-allow-http-scheme": false,
            "cimd-allow-permitted-domains": ${trusted_domains},
            "cimd-restrict-same-domain": false,
            "only-allow-confidential-client": false
          }
        }
      ]
    }
  ]
}
EOF
)
        if printf '%s' "$profile_body" | kcadm_stdin update realms/${REALM}/client-policies/profiles -r ${REALM} -f - 2>/dev/null; then
            log_info "CIMD client profile created (trusted: Claude Code, VS Code, localhost)"
        else
            log_warn "CIMD client profile failed — is 'features: cimd' set in keycloak-cr.yaml and Keycloak restarted?"
            return 0
        fi
    fi

    if kcadm get realms/${REALM}/client-policies/policies -r ${REALM} 2>/dev/null | grep -q '"name" : "mcp-cimd-clients"'; then
        log_warn "CIMD client policy already exists"
    else
        local policy_body
        policy_body=$(cat <<EOF
{
  "policies": [
    {
      "name": "mcp-cimd-clients",
      "description": "Apply the CIMD profile when client_id is an https URL from a trusted domain",
      "enabled": true,
      "conditions": [
        {
          "condition": "client-id-uri",
          "configuration": {
            "client-id-uri-scheme": ["https"],
            "client-id-uri-allow-permitted-domains": ${trusted_domains}
          }
        }
      ],
      "profiles": ["mcp-cimd-clients"]
    }
  ]
}
EOF
)
        if printf '%s' "$policy_body" | kcadm_stdin update realms/${REALM}/client-policies/policies -r ${REALM} -f - 2>/dev/null; then
            log_info "CIMD client policy created"
        else
            log_warn "CIMD client policy failed — is 'features: cimd' set in keycloak-cr.yaml and Keycloak restarted?"
        fi
    fi
}

# Password for a local realm account.
#
# Charset is hex plus one leading uppercase letter: CLAUDE.md notes that
# kcadm-via-kubectl-exec breaks on `!`, `@` and `$`, and openssl's base64 output
# can carry `+`, `/` and `=`, so hex is the safe alphabet. 24 bytes is 96 bits;
# the previous "Admin$(openssl rand -hex 4)" was 32 bits — brute-forceable — on
# an account that is simultaneously realm admin, ArgoCD admin, Forgejo admin and
# Vault platform-admin. The leading letter satisfies mixed-case realm policies.
gen_local_password() {
    printf 'D%s' "$(openssl rand -hex 24)"
}

# Create admin user
create_admin_user() {
    log_step "Creating admin users..."

    local secrets_file="${SCRIPT_ENV_DIR}/oidc-secrets.env"

    # Create devops-admin (temporary password)
    if kcadm get users -r ${REALM} -q username=devops-admin 2>/dev/null | grep -q '"username"' || \
       kcadm get users -r ${REALM} -q email=devops-admin@${DOMAIN} 2>/dev/null | grep -q '"email"'; then
        log_warn "User devops-admin already exists"
    else
        local temp_password=$(openssl rand -base64 12)

        kcadm create users -r ${REALM} \
            -s username=devops-admin \
            -s email=devops-admin@${DOMAIN} \
            -s enabled=true \
            -s emailVerified=true >/dev/null

        local user_id=$(kcadm get users -r ${REALM} -q username=devops-admin --fields id 2>/dev/null | grep "\"id\"" | cut -d'"' -f4)

        kcadm update users/${user_id}/reset-password -r ${REALM} \
            -s type=password \
            -s value="${temp_password}" \
            -s temporary=true -n

        kcadm update users/${user_id} -r ${REALM} -s 'requiredActions=[]'

        local group_id=$(kcadm get groups -r ${REALM} --fields id,name 2>/dev/null | grep -B 1 "devops-admins" | grep "\"id\"" | cut -d'"' -f4)
        if [[ -n "$group_id" ]]; then
            kcadm update users/${user_id}/groups/${group_id} -r ${REALM} -s userId=${user_id} -s groupId=${group_id} -n
        fi

        log_info "User created: devops-admin (temporary password)"
        echo "DEVOPS_ADMIN_PASSWORD=${temp_password}" >> "${secrets_file}"
    fi

    # Create platform-admin — BREAK-GLASS account.
    #
    # A local realm user with a permanent password, in devops-admins, which maps
    # to ArgoCD admin, Forgejo admin, Vault platform-admin and Keycloak
    # realm-admin. It bypasses IdP federation entirely, so no upstream
    # conditional access or MFA applies to it. It exists because the automated
    # setup (validate-e2e, mint-woodpecker-token) needs a password login and
    # because federation can break. On a federated environment, disable it once
    # real admins can sign in through the IdP.
    if kcadm get users -r ${REALM} -q username=platform-admin 2>/dev/null | grep -q '"username"' || \
       kcadm get users -r ${REALM} -q email=platform-admin@${DOMAIN} 2>/dev/null | grep -q '"email"'; then
        if grep -q '^PLATFORM_ADMIN_PASSWORD=' "${secrets_file}" 2>/dev/null; then
            log_warn "User platform-admin already exists"
        else
            # The user exists but the stored password is gone (the file was
            # regenerated). Keycloak cannot read a password back, so reset it
            # and store the new one — same end state as a fresh create.
            local user_id=$(kcadm get users -r ${REALM} -q username=platform-admin 2>/dev/null | grep '"id"' | head -1 | cut -d'"' -f4)
            local admin_password
            admin_password="$(gen_local_password)"
            kcadm set-password -r ${REALM} --userid "${user_id}" --new-password "${admin_password}"
            echo "PLATFORM_ADMIN_PASSWORD=${admin_password}" >> "${secrets_file}"
            log_info "User platform-admin existed with no stored password — password reset and stored"
        fi
    else
        local admin_password
        admin_password="$(gen_local_password)"

        kcadm create users -r ${REALM} \
            -s username=platform-admin \
            -s email=platform-admin@${DOMAIN} \
            -s firstName=Platform \
            -s lastName=Administrator \
            -s enabled=true \
            -s emailVerified=true >/dev/null

        local user_id=$(kcadm get users -r ${REALM} -q username=platform-admin --fields id 2>/dev/null | grep "\"id\"" | cut -d'"' -f4)

        kcadm update users/${user_id}/reset-password -r ${REALM} \
            -s type=password \
            -s value="${admin_password}" \
            -s temporary=false -n

        kcadm update users/${user_id} -r ${REALM} -s 'requiredActions=[]'

        local group_id=$(kcadm get groups -r ${REALM} --fields id,name 2>/dev/null | grep -B 1 "devops-admins" | grep "\"id\"" | cut -d'"' -f4)
        if [[ -n "$group_id" ]]; then
            kcadm update users/${user_id}/groups/${group_id} -r ${REALM} -s userId=${user_id} -s groupId=${group_id} -n
        fi

        log_info "User created: platform-admin (break-glass — bypasses IdP federation)"
        # Never printed: quickstart tees every step's output to
        # _setup/<env>/logs/*.log, so printing it would put the credential in a
        # second file, in shell scrollback and on any shared screen.
        log_info "Password stored in ${secrets_file}; read it with:"
        log_info "  grep PLATFORM_ADMIN_PASSWORD ${secrets_file}"
        echo "PLATFORM_ADMIN_PASSWORD=${admin_password}" >> "${secrets_file}"
    fi
}

# Configure all clients
configure_clients() {
    log_step "Configuring OIDC clients..."

    local secrets_file="${SCRIPT_ENV_DIR}/oidc-secrets.env"
    # Rewrite only the client-secret lines. The *_ADMIN_PASSWORD lines written
    # by the user step must survive a clients re-run — losing them silently
    # breaks everything that signs in with the stored password (validate-e2e,
    # mint-woodpecker-token), while the passwords themselves stay valid in
    # Keycloak with no way to read them back.
    if [[ -f "$secrets_file" ]]; then
        grep '_ADMIN_PASSWORD=' "$secrets_file" > "${secrets_file}.tmp" || true
        mv "${secrets_file}.tmp" "$secrets_file"
    else
        : > "${secrets_file}"
    fi
    chmod 600 "${secrets_file}"

    # Grafana
    log_info "Configuring Grafana OIDC client..."
    local grafana_secret
    require_client_secret grafana_secret "grafana" \
        "https://grafana.${DOMAIN}/login/generic_oauth"
    echo "GRAFANA_OIDC_SECRET=${grafana_secret}" >> "${secrets_file}"

    kubectl create secret generic grafana-oidc-secret -n monitoring \
        --from-literal=client-secret="${grafana_secret}" \
        --dry-run=client -o yaml | kubectl apply -f -

    # ArgoCD
    log_info "Configuring ArgoCD OIDC client..."
    local argocd_secret
    require_client_secret argocd_secret "argocd" \
        "https://argocd.${DOMAIN}/auth/callback"
    echo "ARGOCD_OIDC_SECRET=${argocd_secret}" >> "${secrets_file}"

    if kubectl get secret argocd-secret -n argocd >/dev/null 2>&1; then
        kubectl patch secret argocd-secret -n argocd \
            --type='json' \
            -p="[{'op': 'add', 'path': '/data/oidc.keycloak.clientSecret', 'value':'$(echo -n ${argocd_secret} | base64 -w0)'}]"
    else
        kubectl create secret generic argocd-secret -n argocd \
            --from-literal=oidc.keycloak.clientSecret="${argocd_secret}" \
            --dry-run=client -o yaml | kubectl apply -f -
    fi

    # Forgejo
    log_info "Configuring Forgejo OIDC client..."
    local forgejo_secret
    require_client_secret forgejo_secret "forgejo" \
        "https://git.${DOMAIN}/user/oauth2/keycloak/callback"
    echo "FORGEJO_OIDC_SECRET=${forgejo_secret}" >> "${secrets_file}"

    kubectl create secret generic forgejo-oidc-secret -n forgejo \
        --from-literal=key=forgejo \
        --from-literal=secret="${forgejo_secret}" \
        --dry-run=client -o yaml | kubectl apply -f - >/dev/null

    register_forgejo_oidc "${forgejo_secret}"

    # Vault
    log_info "Configuring Vault OIDC client..."
    local vault_secret
    require_client_secret vault_secret "vault" \
        "https://vault.${DOMAIN}/ui/vault/auth/oidc/oidc/callback"
    echo "VAULT_OIDC_SECRET=${vault_secret}" >> "${secrets_file}"

    kubectl create secret generic vault-oidc-secret -n vault \
        --from-literal=client-id=vault \
        --from-literal=client-secret="${vault_secret}" \
        --dry-run=client -o yaml | kubectl apply -f -

    # Headlamp
    log_info "Configuring Headlamp OIDC client..."
    # Headlamp — same shape as Homepage: Envoy Gateway is the OIDC client on
    # its behalf (k8s/base/devops/headlamp/oidc-securitypolicy.yaml). Headlamp
    # itself does no OIDC — managed API servers reject tokens from a custom
    # issuer, so it talks to the API as its read-only ServiceAccount instead.
    local headlamp_secret
    require_client_secret headlamp_secret "headlamp" \
        "https://headlamp.${DOMAIN}/oauth2/callback"
    echo "HEADLAMP_OIDC_SECRET=${headlamp_secret}" >> "${secrets_file}"

    kubectl create secret generic headlamp-oidc-secret -n headlamp \
        --from-literal=client-secret="${headlamp_secret}" \
        --dry-run=client -o yaml | kubectl apply -f -

    # Homepage
    #
    # Homepage itself is not an OIDC client — Envoy Gateway is, on its behalf
    # (k8s/base/devops/homepage/oidc-securitypolicy.yaml). Hence the gateway's
    # callback path as the redirect URI, and a secret holding only the client
    # secret under the key Envoy Gateway expects.
    log_info "Configuring Homepage OIDC client..."
    local homepage_secret
    require_client_secret homepage_secret "homepage" \
        "https://home.${DOMAIN}/oauth2/callback"
    echo "HOMEPAGE_OIDC_SECRET=${homepage_secret}" >> "${secrets_file}"

    kubectl create secret generic homepage-oidc-secret -n homepage \
        --from-literal=client-secret="${homepage_secret}" \
        --dry-run=client -o yaml | kubectl apply -f -

    # Portal — same shape as Homepage: Envoy Gateway is the OIDC client on its
    # behalf (k8s/base/devops/portal/oidc-securitypolicy.yaml).
    log_info "Configuring Portal OIDC client..."
    local portal_secret
    require_client_secret portal_secret "portal" \
        "https://portal.${DOMAIN}/oauth2/callback"
    echo "PORTAL_OIDC_SECRET=${portal_secret}" >> "${secrets_file}"

    # Shared confidential client for developer applications: the devhub-app
    # chart's gateway SecurityPolicy signs users in with it. One client covers
    # every app because Keycloak accepts a single-label host wildcard — and a
    # scaffolded hostname is always exactly <app>.<domain>. The secret reaches
    # app namespaces from Vault (secret/apps/oidc-gateway, seeded by
    # setup-vault.sh seed-secrets) via External Secrets.
    local apps_secret
    require_client_secret apps_secret "apps" \
        "https://*.${DOMAIN}/oauth2/callback"
    echo "APPS_OIDC_SECRET=${apps_secret}" >> "${secrets_file}"

    kubectl create namespace portal 2>/dev/null || true
    kubectl create secret generic portal-oidc-secret -n portal \
        --from-literal=client-secret="${portal_secret}" \
        --dry-run=client -o yaml | kubectl apply -f -

    log_info "Client secrets saved to: ${secrets_file}"
    log_info "Kubernetes secrets created in respective namespaces"

    # Restart services that mount OIDC secrets as volumes/env vars
    log_info "Restarting services to pick up real OIDC secrets..."
    kubectl rollout restart deployment/prometheus-grafana -n monitoring 2>/dev/null || true
    kubectl rollout restart deployment/forgejo -n forgejo 2>/dev/null || true
    kubectl rollout restart deployment/headlamp -n headlamp 2>/dev/null || true
}

# Register Keycloak as an OAuth2 login source inside Forgejo.
#
# This lives here, not in the Helm values, because the chart's init container hard
# fails when the discovery URL 404s — and the realm only exists once this script has
# run. Idempotent: an existing 'keycloak' source is updated with the new secret.
register_forgejo_oidc() {
    local client_secret="$1"
    local discovery="${KEYCLOAK_INTERNAL_URL}/realms/${REALM}/.well-known/openid-configuration"

    local pod
    pod="$(kubectl get pod -n forgejo -l app.kubernetes.io/name=forgejo \
        -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")"
    if [[ -z "$pod" ]]; then
        log_warn "Forgejo is not running — re-run this script once it is to enable SSO there"
        return 0
    fi

    # `auth list` prints: ID <tab> Name <tab> Type <tab> Enabled
    local existing_id
    existing_id="$(kubectl exec -n forgejo "$pod" -- gitea admin auth list 2>/dev/null |
        awk -F'\t' '$2 == "keycloak" { print $1; exit }' | tr -d '[:space:]')"

    if [[ -n "$existing_id" ]]; then
        if kubectl exec -n forgejo "$pod" -- gitea admin auth update-oauth \
            --id "$existing_id" \
            --key forgejo --secret "$client_secret" \
            --auto-discover-url "$discovery" >/dev/null 2>&1; then
            log_info "Forgejo OAuth source 'keycloak' updated"
        else
            log_warn "Could not update Forgejo's 'keycloak' login source — check it in the UI"
        fi
        return 0
    fi

    if kubectl exec -n forgejo "$pod" -- gitea admin auth add-oauth \
        --name keycloak \
        --provider openidConnect \
        --key forgejo --secret "$client_secret" \
        --auto-discover-url "$discovery" \
        --scopes "openid email profile groups" \
        --group-claim-name groups \
        --admin-group devops-admins >/dev/null 2>&1; then
        log_info "Forgejo OAuth source 'keycloak' registered"
    else
        log_warn "Could not register Keycloak in Forgejo. Add it by hand:"
        log_warn "  Site Administration → Authentication Sources → OAuth2, discovery URL:"
        log_warn "  ${discovery}"
    fi
}

# Configure Entra ID as a federated identity provider in Keycloak
# Requires: ENTRA_TENANT_ID, ENTRA_KEYCLOAK_CLIENT_ID (from tofu-outputs.env via parse_config)
#           ENTRA_KEYCLOAK_CLIENT_SECRET (from ${SCRIPT_ENV_DIR}/secrets.env)
configure_entra_idp() {
    log_step "Configuring Entra ID identity provider..."

    # Load client secret from local secrets file written by sync-tofu-outputs.sh
    local secrets_file="${SCRIPT_ENV_DIR}/secrets.env"
    if [[ ! -f "$secrets_file" ]]; then
        log_error "Entra ID secrets not found: ${secrets_file}"
        log_error "Run: ./sync-tofu-outputs.sh --env ${ENV}"
        exit 1
    fi
    source "$secrets_file"

    : "${ENTRA_TENANT_ID:?ENTRA_TENANT_ID not set — run sync-tofu-outputs.sh}"
    : "${ENTRA_KEYCLOAK_CLIENT_ID:?ENTRA_KEYCLOAK_CLIENT_ID not set — run sync-tofu-outputs.sh}"
    : "${ENTRA_KEYCLOAK_CLIENT_SECRET:?ENTRA_KEYCLOAK_CLIENT_SECRET not set — check secrets.env}"

    # The App Registration's redirect URI is owned by tofu (the module knows
    # the domain), so this only verifies it — a mismatch here means Entra will
    # answer every login with AADSTS50011.
    local redirect_uri="https://keycloak.${DOMAIN}/realms/devops/broker/entra/endpoint"
    if command -v az &>/dev/null; then
        local configured
        configured="$(az ad app show --id "${ENTRA_KEYCLOAK_CLIENT_ID}" \
            --query 'web.redirectUris[0]' -o tsv 2>/dev/null || echo "")"
        if [[ "$configured" != "$redirect_uri" ]]; then
            log_warn "App Registration redirect URI is '${configured:-<unset>}' but Keycloak brokers at:"
            log_warn "  ${redirect_uri}"
            log_warn "Re-run 'tofu apply' (the module sets it from the domain), or fix it in the Azure portal."
        fi
    fi

    # Every setting this script owns, in one list, so create and update apply
    # exactly the same configuration.
    #
    # The update path matters: tofu keeps the App Registration's client secret on
    # a 2-year time_rotating schedule, so it *will* change. The instance still
    # exists after a rotation, and the previous skip-if-exists left the stale
    # config.clientSecret in place — every federated login then failed with
    # invalid_client and re-running this script did nothing about it. kcadm
    # update does a GET, merges the -s settings and PUTs, so nested config keys
    # not listed here survive.
    local -a entra_settings=(
        -s displayName="Microsoft Entra ID"
        -s providerId=oidc
        -s enabled=true
        -s trustEmail=true
        -s storeToken=false
        -s "firstBrokerLoginFlowAlias=first broker login"
        -s "config.useJwksUrl=true"
        -s "config.validateSignature=true"
        -s "config.pkceEnabled=false"
        -s "config.clientAuthMethod=client_secret_post"
        -s "config.defaultScope=openid profile email"
        -s "config.authorizationUrl=https://login.microsoftonline.com/${ENTRA_TENANT_ID}/oauth2/v2.0/authorize"
        -s "config.tokenUrl=https://login.microsoftonline.com/${ENTRA_TENANT_ID}/oauth2/v2.0/token"
        -s "config.jwksUrl=https://login.microsoftonline.com/${ENTRA_TENANT_ID}/discovery/v2.0/keys"
        -s "config.issuer=https://login.microsoftonline.com/${ENTRA_TENANT_ID}/v2.0"
        -s "config.clientId=${ENTRA_KEYCLOAK_CLIENT_ID}"
        -s "config.clientSecret=${ENTRA_KEYCLOAK_CLIENT_SECRET}"
    )

    # Idempotent: an existing instance is re-configured rather than skipped, and
    # the mappers below are ensured either way — a run that died between instance
    # and mappers used to leave the IdP half-configured forever.
    if kcadm get identity-provider/instances/entra -r ${REALM} >/dev/null 2>&1; then
        log_info "Entra ID identity provider exists — re-applying its configuration"
        kcadm update identity-provider/instances/entra -r ${REALM} "${entra_settings[@]}"
        log_info "Entra ID configuration refreshed (client secret re-applied from secrets.env)"
    else
        kcadm create identity-provider/instances -r ${REALM} \
            -s alias=entra "${entra_settings[@]}"
        log_info "Entra ID identity provider created"
    fi

    # ensure_entra_mapper <name> <json-body>
    # Mapper creates are the one part of this section that cannot be re-issued:
    # Keycloak answers 409 on a duplicate name, and set -e then killed the whole
    # setup half-way. Check by name first. The body goes in as JSON over stdin —
    # kcadm's -s syntax cannot express a config value that is itself JSON (the
    # advanced group mapper's "claims"), it answers "Cannot parse the JSON".
    ensure_entra_mapper() {
        local name="$1" body="$2"
        if kcadm get identity-provider/instances/entra/mappers -r ${REALM} --fields name 2>/dev/null \
                | grep -q "\"name\" : \"${name}\""; then
            log_info "Mapper ${name} already exists"
            return 0
        fi
        printf '%s' "$body" | kcadm_stdin create identity-provider/instances/entra/mappers -r ${REALM} -f -
    }

    # Mapper: sync email claim → Keycloak user email attribute
    ensure_entra_mapper "entra-email" \
        '{"name":"entra-email","identityProviderAlias":"entra","identityProviderMapper":"oidc-user-attribute-idp-mapper","config":{"syncMode":"INHERIT","claim":"email","user.attribute":"email"}}'

    # Mapper: username = the UPN's local part. Entra's preferred_username is
    # the full UPN (an email), and that flows through Keycloak into every
    # downstream service as the username — Forgejo rejects "@" in usernames
    # and 500s on the very first SSO login trying to auto-create the account.
    ensure_entra_mapper "entra-username" \
        '{"name":"entra-username","identityProviderAlias":"entra","identityProviderMapper":"oidc-username-idp-mapper","config":{"syncMode":"INHERIT","template":"${CLAIM.preferred_username | localpart}","target":"LOCAL"}}'

    # Mappers: map Entra ID App Roles → Keycloak groups via the Advanced Claim
    # to Group mapper (oidc-advanced-group-idp-mapper — the only stock group
    # mapper that matches a claim value; "oidc-group-idp-mapper" does not exist,
    # and a mapper row with an unknown type NPEs every federated login).
    # App Roles are defined in the tofu module and appear in the token's 'roles' claim.
    # Assign users/groups to these App Roles in the Azure portal or via azuread_app_role_assignment.
    # syncMode=FORCE re-evaluates group membership on every login (reflects role changes immediately).
    local role_group
    for role_group in "devops-admins" "developers" "viewers"; do
        ensure_entra_mapper "entra-role-${role_group}" \
            "{\"name\":\"entra-role-${role_group}\",\"identityProviderAlias\":\"entra\",\"identityProviderMapper\":\"oidc-advanced-group-idp-mapper\",\"config\":{\"syncMode\":\"FORCE\",\"claims\":\"[{\\\"key\\\":\\\"roles\\\",\\\"value\\\":\\\"${role_group}\\\"}]\",\"are.claim.values.regex\":\"false\",\"group\":\"/${role_group}\"}}"
    done

    log_info "Group mappers added: Entra ID App Role → Keycloak group (devops-admins, developers, viewers)"
    log_info ""
    log_info "Next steps in Azure portal (Entra ID → Enterprise Applications → ${ENTRA_KEYCLOAK_CLIENT_ID}):"
    log_info "  Assign users or security groups to the App Roles to grant DevHub access"
    log_info "  devops-admins → full admin    developers → dev access    viewers → read-only"
}

# Configure Google as a social identity provider in Keycloak
# Requires: GOOGLE_IDP_CLIENT_ID (from tofu-outputs.env via parse_config)
#           GOOGLE_IDP_CLIENT_SECRET (from ${SCRIPT_ENV_DIR}/manual-secrets.env)
configure_google_idp() {
    log_step "Configuring Google identity provider..."

    # Load client secret from local secrets file written by the user after creating
    # the OAuth client in Google Cloud Console (sync-tofu-outputs.sh creates the template)
    local secrets_file="${SCRIPT_ENV_DIR}/manual-secrets.env"
    if [[ ! -f "$secrets_file" ]]; then
        log_error "Google IdP secrets not found: ${secrets_file}"
        log_error "Run: ./sync-tofu-outputs.sh --env ${ENV}"
        log_error "Then fill in GOOGLE_IDP_CLIENT_ID and GOOGLE_IDP_CLIENT_SECRET in the file"
        exit 1
    fi
    source "$secrets_file"

    : "${GOOGLE_IDP_CLIENT_ID:?GOOGLE_IDP_CLIENT_ID not set — fill in ${secrets_file}}"
    : "${GOOGLE_IDP_CLIENT_SECRET:?GOOGLE_IDP_CLIENT_SECRET not set — fill in ${secrets_file}}"

    if [[ "$GOOGLE_IDP_CLIENT_ID" == "FILL_IN_MANUALLY" || "$GOOGLE_IDP_CLIENT_SECRET" == "FILL_IN_MANUALLY" ]]; then
        log_error "gcp-idp.env still has placeholder values — fill in the actual OAuth client credentials"
        exit 1
    fi

    # One list for create and update, same as the Entra and Cognito sections.
    # The Google OAuth client is created by hand (no Terraform resource exists),
    # so its secret is rotated by hand too — and re-running this script has to be
    # what picks the new value out of manual-secrets.env. Skipping an existing
    # instance left the stale secret in place and every Google login then failed
    # with invalid_client, with nothing in the script's output saying so.
    local -a google_settings=(
        -s displayName="Sign in with Google"
        -s providerId=google
        -s enabled=true
        -s trustEmail=true
        -s storeToken=false
        -s "firstBrokerLoginFlowAlias=first broker login"
        -s "config.clientId=${GOOGLE_IDP_CLIENT_ID}"
        -s "config.clientSecret=${GOOGLE_IDP_CLIENT_SECRET}"
        -s "config.defaultScope=openid profile email"
    )

    if kcadm get identity-provider/instances/google -r ${REALM} >/dev/null 2>&1; then
        log_info "Google identity provider exists — re-applying its configuration"
        kcadm update identity-provider/instances/google -r ${REALM} "${google_settings[@]}"
        log_info "Google configuration refreshed (client secret re-applied from manual-secrets.env)"
    else
        # Keycloak's built-in google provider type.
        kcadm create identity-provider/instances -r ${REALM} \
            -s alias=google "${google_settings[@]}"
        log_info "Google identity provider created"
    fi

    # Mapper: sync email claim → Keycloak user email attribute. Checked by name,
    # like the other two IdPs: Keycloak answers 409 on a duplicate and set -e
    # then killed the run half-way through.
    if kcadm get identity-provider/instances/google/mappers -r ${REALM} --fields name 2>/dev/null \
            | grep -q '"name" : "google-email"'; then
        log_info "Mapper google-email already exists"
    else
        printf '%s' \
            '{"name":"google-email","identityProviderAlias":"google","identityProviderMapper":"oidc-user-attribute-idp-mapper","config":{"syncMode":"INHERIT","claim":"email","user.attribute":"email"}}' \
            | kcadm_stdin create identity-provider/instances/google/mappers -r ${REALM} -f -
        log_info "Email attribute mapper added"
    fi
    log_info ""
    log_info "IMPORTANT: Google tokens do not include group/role claims."
    log_info "  After users sign in for the first time, assign them to Keycloak groups manually:"
    log_info "  Keycloak Admin → Users → <user> → Groups → Add to group"
    log_info "  Groups: devops-admins, developers, viewers"
}

# Configure AWS Cognito as a federated OIDC identity provider in Keycloak
# Requires: COGNITO_ISSUER_URL, COGNITO_HOSTED_UI_DOMAIN, COGNITO_CLIENT_ID (from config.yaml)
#           COGNITO_CLIENT_SECRET (from ${SCRIPT_ENV_DIR}/secrets.env)
configure_cognito_idp() {
    log_step "Configuring AWS Cognito identity provider..."

    # Load client secret from local secrets file written by sync-tofu-outputs.sh
    local secrets_file="${SCRIPT_ENV_DIR}/secrets.env"
    if [[ ! -f "$secrets_file" ]]; then
        log_error "Cognito secrets not found: ${secrets_file}"
        log_error "Run: ./sync-tofu-outputs.sh --env ${ENV}"
        exit 1
    fi
    source "$secrets_file"

    : "${COGNITO_ISSUER_URL:?COGNITO_ISSUER_URL not set — check config.yaml cognitoIdp.issuerUrl}"
    : "${COGNITO_HOSTED_UI_DOMAIN:?COGNITO_HOSTED_UI_DOMAIN not set — check config.yaml cognitoIdp.hostedUiDomain}"
    : "${COGNITO_CLIENT_ID:?COGNITO_CLIENT_ID not set — check config.yaml cognitoIdp.clientId}"
    : "${COGNITO_CLIENT_SECRET:?COGNITO_CLIENT_SECRET not set — check secrets.env}"

    # Update the Cognito app client callback URL to the real Keycloak domain.
    # The tofu module registers a placeholder; this fixes it once the domain is known.
    local redirect_uri="https://keycloak.${DOMAIN}/realms/devops/broker/aws-cognito/endpoint"
    if command -v aws &>/dev/null; then
        local user_pool_id
        user_pool_id=$(echo "${COGNITO_ISSUER_URL}" | sed 's|.*/||')
        local aws_region
        aws_region=$(echo "${COGNITO_ISSUER_URL}" | sed 's|https://cognito-idp\.||' | sed 's|\.amazonaws.*||')

        log_info "Updating Cognito app client callback URL to: ${redirect_uri}"
        aws cognito-idp update-user-pool-client \
            --user-pool-id "${user_pool_id}" \
            --client-id "${COGNITO_CLIENT_ID}" \
            --region "${aws_region}" \
            --callback-urls "${redirect_uri}" \
            --allowed-o-auth-flows code \
            --allowed-o-auth-scopes openid email profile \
            --allowed-o-auth-flows-user-pool-client \
            --supported-identity-providers COGNITO 2>/dev/null \
            || log_warn "Could not update Cognito callback URL via aws CLI — set it manually in the AWS console"
    else
        log_warn "aws CLI not found — set the callback URL manually in the AWS console:"
        log_warn "  ${redirect_uri}"
    fi

    # One list for create and update, same as the Entra section: re-running has
    # to re-apply config.clientSecret. Recreating the Cognito app client (or
    # rotating its secret) leaves the Keycloak instance in place, and a stale
    # secret there fails every federated login with invalid_client while the
    # script reports success.
    local -a cognito_settings=(
        -s displayName="Sign in with AWS (Cognito)"
        -s providerId=oidc
        -s enabled=true
        -s trustEmail=true
        -s storeToken=false
        -s "firstBrokerLoginFlowAlias=first broker login"
        -s "config.useJwksUrl=true"
        -s "config.validateSignature=true"
        -s "config.pkceEnabled=false"
        -s "config.clientAuthMethod=client_secret_post"
        -s "config.defaultScope=openid profile email"
        -s "config.authorizationUrl=https://${COGNITO_HOSTED_UI_DOMAIN}/oauth2/authorize"
        -s "config.tokenUrl=https://${COGNITO_HOSTED_UI_DOMAIN}/oauth2/token"
        -s "config.jwksUrl=${COGNITO_ISSUER_URL}/.well-known/jwks.json"
        -s "config.issuer=${COGNITO_ISSUER_URL}"
        -s "config.clientId=${COGNITO_CLIENT_ID}"
        -s "config.clientSecret=${COGNITO_CLIENT_SECRET}"
    )

    # Idempotent, like the Entra section: an existing instance is re-configured
    # rather than skipped, and the mappers below are ensured either way.
    # Returning early here meant a run that died between the instance and the
    # mappers left the IdP permanently half-configured — which is exactly what
    # the broken group mappers below used to cause.
    if kcadm get identity-provider/instances/aws-cognito -r ${REALM} >/dev/null 2>&1; then
        log_info "Cognito identity provider exists — re-applying its configuration"
        kcadm update identity-provider/instances/aws-cognito -r ${REALM} "${cognito_settings[@]}"
        log_info "Cognito configuration refreshed (client secret re-applied from secrets.env)"
    else
        kcadm create identity-provider/instances -r ${REALM} \
            -s alias=aws-cognito "${cognito_settings[@]}"
        log_info "Cognito identity provider created"
    fi

    # ensure_cognito_mapper <name> <json-body> — the Entra pattern, for the same
    # two reasons: Keycloak answers 409 on a duplicate mapper name, which under
    # set -e killed the run half-way and left the IdP without group mappers; and
    # kcadm's `-s key=value` syntax cannot express a config value that is itself
    # JSON (the advanced group mapper's "claims") — it answers "Cannot parse the
    # JSON". The body goes in over stdin instead.
    ensure_cognito_mapper() {
        local name="$1" body="$2"
        if kcadm get identity-provider/instances/aws-cognito/mappers -r ${REALM} --fields name 2>/dev/null \
                | grep -q "\"name\" : \"${name}\""; then
            log_info "Mapper ${name} already exists"
            return 0
        fi
        printf '%s' "$body" | kcadm_stdin create identity-provider/instances/aws-cognito/mappers -r ${REALM} -f -
    }

    # Mapper: sync email claim → Keycloak user email attribute
    ensure_cognito_mapper "cognito-email" \
        '{"name":"cognito-email","identityProviderAlias":"aws-cognito","identityProviderMapper":"oidc-user-attribute-idp-mapper","config":{"syncMode":"INHERIT","claim":"email","user.attribute":"email"}}'

    # Mappers: Cognito group → Keycloak group, through the Advanced Claim to
    # Group mapper (oidc-advanced-group-idp-mapper). That is the only stock group
    # mapper that matches a claim value: "oidc-group-idp-mapper" does not exist,
    # and a mapper row with an unknown type NPEs *every* federated login — the
    # same trap documented in the Entra section above. The old call also passed
    # the config as a bare `-s "{...}"`, which is not valid kcadm syntax, so
    # under set -e it either aborted the run or poisoned Cognito logins.
    #
    # Cognito puts a `cognito:groups` array claim in the ID token when users are
    # in groups. Assign them in the AWS console:
    #   Amazon Cognito → User pools → <pool> → Users → <user> → Add user to group
    # syncMode=FORCE re-evaluates group membership on every login.
    local cognito_group
    for cognito_group in "devops-admins" "developers" "viewers"; do
        ensure_cognito_mapper "cognito-group-${cognito_group}" \
            "{\"name\":\"cognito-group-${cognito_group}\",\"identityProviderAlias\":\"aws-cognito\",\"identityProviderMapper\":\"oidc-advanced-group-idp-mapper\",\"config\":{\"syncMode\":\"FORCE\",\"claims\":\"[{\\\"key\\\":\\\"cognito:groups\\\",\\\"value\\\":\\\"${cognito_group}\\\"}]\",\"are.claim.values.regex\":\"false\",\"group\":\"/${cognito_group}\"}}"
    done

    log_info "Group mappers added: Cognito group → Keycloak group (devops-admins, developers, viewers)"
    log_info ""
    log_info "Next steps in AWS console (Amazon Cognito → User pools → ${COGNITO_ISSUER_URL##*/}):"
    log_info "  Assign users to Cognito groups to grant DevHub access"
    log_info "  devops-admins → full admin    developers → dev access    viewers → read-only"
}

# Print summary
print_summary() {
    echo ""
    echo "=============================================="
    echo "Keycloak Setup Complete!"
    echo "=============================================="
    echo ""
    echo "Realm: ${REALM}"
    echo "URL: https://keycloak.${DOMAIN}/realms/${REALM}"
    echo ""
    echo "Admin Console: https://keycloak.${DOMAIN}/admin/"
    echo "Realm Login: https://keycloak.${DOMAIN}/realms/${REALM}/account/"
    echo ""
    echo "Credentials saved to:"
    echo "  ${SCRIPT_ENV_DIR}/oidc-secrets.env"
    echo ""
    echo "Realm Users:"
    echo "  - platform-admin  BREAK-GLASS: permanent password, full admin, no IdP/MFA"
    echo "                    grep PLATFORM_ADMIN_PASSWORD ${SCRIPT_ENV_DIR}/oidc-secrets.env"
    echo "  - devops-admin (temporary password, must change on first login)"
    echo ""
    echo "Services configured with SSO:"
    echo "  - Grafana: https://grafana.${DOMAIN}"
    echo "  - ArgoCD: https://argocd.${DOMAIN}"
    echo "  - Forgejo:    https://git.${DOMAIN}"
    echo "  - Vault: https://vault.${DOMAIN}"
    echo ""
}

# Main
main() {
    local action="${1:-all}"

    echo "=============================================="
    echo "Keycloak Setup (${ENV})"
    echo "Domain: ${DOMAIN}"
    echo "=============================================="

    log_info "Waiting for Keycloak to be ready..."
    kubectl wait --for=condition=ready pod -l app=keycloak -n keycloak --timeout=300s

    kcadm_login

    case "$action" in
        all)
            create_realm
            create_groups
            configure_clients
            configure_groups_scope
            configure_mcp
            create_admin_user
            if [[ "$ENV" == azure-* ]]; then
                configure_entra_idp
            elif [[ "$ENV" == gcp-* ]]; then
                configure_google_idp
            elif [[ "$ENV" == aws-* ]]; then
                configure_cognito_idp
            fi
            print_summary
            ;;
        realm)
            create_realm
            ;;
        clients)
            configure_clients
            ;;
        user)
            create_admin_user
            ;;
        mcp)
            configure_mcp
            ;;
        idp)
            if [[ "$ENV" == azure-* ]]; then
                configure_entra_idp
            elif [[ "$ENV" == gcp-* ]]; then
                configure_google_idp
            elif [[ "$ENV" == aws-* ]]; then
                configure_cognito_idp
            else
                log_error "The 'idp' action is only supported for azure-*, gcp-*, and aws-* environments"
                exit 1
            fi
            ;;
        *)
            echo "Usage: $0 --env local|upcloud-dev|upcloud-prod|azure-dev|azure-prod|gcp-dev|gcp-prod|aws-dev|aws-prod [all|realm|clients|user|idp|mcp]"
            exit 1
            ;;
    esac
}

main "$@"
