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
#   gcp-*:   Google social login (requires gcp-idp.env filled in manually)
#   aws-*:   AWS Cognito OIDC federation (Cognito Groups → Keycloak groups)
# 'all' automatically includes 'idp' for azure/gcp/aws environments.
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"

parse_env_arg "$@"
set -- "${ARGS[@]}"

setup_paths
parse_config

# Configuration
REALM="devops"
KCADM="/opt/keycloak/bin/kcadm.sh"

# Determine Keycloak internal URL for server-side OIDC endpoints.
# *.localhost resolves to 127.0.0.1 inside glibc-based containers (RFC 6761),
# so we must use internal K8s service URLs for server-side calls.
if [[ "$DOMAIN" == "localhost" || "$DOMAIN" == *.localhost ]]; then
    KEYCLOAK_INTERNAL_URL="http://keycloak-keycloakx-http.keycloak.svc.cluster.local"
    USE_DISCOVERY=false
else
    KEYCLOAK_INTERNAL_URL="https://keycloak.${DOMAIN}"
    USE_DISCOVERY=true
fi

# Execute kcadm command in Keycloak pod
kcadm() {
    kubectl exec -n keycloak keycloak-keycloakx-0 -- ${KCADM} "$@"
}

# Login to Keycloak admin
kcadm_login() {
    local password=$(kubectl get secret keycloak-admin-secret -n keycloak -o jsonpath='{.data.KEYCLOAK_ADMIN_PASSWORD}' | base64 -d)
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

# Create OIDC client
create_client() {
    local client_id="$1"
    local redirect_uri="$2"
    local public="${3:-false}"

    local existing=$(kcadm get clients -r ${REALM} --fields id,clientId 2>/dev/null | grep "\"clientId\" : \"${client_id}\"" -B 1 | grep "\"id\"" | cut -d'"' -f4 || echo "")

    if [[ -n "$existing" ]]; then
        local client_secret=$(kcadm get clients/${existing}/client-secret -r ${REALM} 2>/dev/null | grep "value" | cut -d'"' -f4 || echo "")
        if [[ -n "$client_secret" ]]; then
            echo "${client_secret}"
            return 0
        fi
    fi

    local client_secret=$(openssl rand -hex 32)

    kcadm create clients -r ${REALM} \
        -s clientId=${client_id} \
        -s enabled=true \
        -s protocol=openid-connect \
        -s publicClient=${public} \
        -s standardFlowEnabled=true \
        -s directAccessGrantsEnabled=true \
        -s serviceAccountsEnabled=false \
        -s "redirectUris=[\"${redirect_uri}\"]" \
        -s 'webOrigins=["*"]' \
        -s secret="${client_secret}" \
        -s 'attributes={"post.logout.redirect.uris":"*"}' >&2

    echo "${client_secret}"
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

    for client_name in "grafana" "argocd" "gitlab" "vault"; do
        local client_id=$(kcadm get clients -r ${REALM} --fields id,clientId 2>/dev/null | grep "\"clientId\" : \"${client_name}\"" -B 1 | grep "\"id\"" | cut -d'"' -f4 || echo "")
        if [[ -n "$client_id" ]]; then
            kcadm update clients/${client_id}/default-client-scopes/${scope_id} -r ${REALM} 2>/dev/null || true
        fi
    done
    log_info "Groups scope added to all OIDC clients"
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

    # Create platform-admin (permanent password for testing/admin access)
    if kcadm get users -r ${REALM} -q username=platform-admin 2>/dev/null | grep -q '"username"' || \
       kcadm get users -r ${REALM} -q email=platform-admin@${DOMAIN} 2>/dev/null | grep -q '"email"'; then
        log_warn "User platform-admin already exists"
    else
        local admin_password="Admin$(openssl rand -hex 4)"

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

        log_info "User created: platform-admin"
        log_info "Username: platform-admin"
        log_info "Password: ${admin_password}"
        echo "PLATFORM_ADMIN_PASSWORD=${admin_password}" >> "${secrets_file}"
    fi
}

# Configure all clients
configure_clients() {
    log_step "Configuring OIDC clients..."

    local secrets_file="${SCRIPT_ENV_DIR}/oidc-secrets.env"
    : > "${secrets_file}"
    chmod 600 "${secrets_file}"

    # Grafana
    log_info "Configuring Grafana OIDC client..."
    local grafana_secret=$(create_client "grafana" \
        "https://grafana.${DOMAIN}/login/generic_oauth")
    echo "GRAFANA_OIDC_SECRET=${grafana_secret}" >> "${secrets_file}"

    kubectl create secret generic grafana-oidc-secret -n monitoring \
        --from-literal=client-secret="${grafana_secret}" \
        --dry-run=client -o yaml | kubectl apply -f -

    # ArgoCD
    log_info "Configuring ArgoCD OIDC client..."
    local argocd_secret=$(create_client "argocd" \
        "https://argocd.${DOMAIN}/auth/callback")
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

    # GitLab
    log_info "Configuring GitLab OIDC client..."
    local gitlab_secret=$(create_client "gitlab" \
        "https://gitlab.${DOMAIN}/users/auth/openid_connect/callback")
    echo "GITLAB_OIDC_SECRET=${gitlab_secret}" >> "${secrets_file}"

    # GitLab OIDC config: use discovery for non-localhost, explicit endpoints for localhost
    if [[ "$USE_DISCOVERY" == "true" ]]; then
        kubectl create secret generic gitlab-oidc-secret -n gitlab \
            --from-literal=provider="$(cat <<EOF
name: 'openid_connect'
label: 'Keycloak'
args:
  name: 'openid_connect'
  scope: ['openid', 'profile', 'email', 'groups']
  response_type: 'code'
  issuer: 'https://keycloak.${DOMAIN}/realms/devops'
  discovery: true
  client_auth_method: 'query'
  uid_field: 'preferred_username'
  client_options:
    identifier: 'gitlab'
    secret: '${gitlab_secret}'
    redirect_uri: 'https://gitlab.${DOMAIN}/users/auth/openid_connect/callback'
EOF
)" \
            --dry-run=client -o yaml | kubectl apply -f -
    else
        # .localhost domain: use internal URLs for server-side endpoints
        kubectl create secret generic gitlab-oidc-secret -n gitlab \
            --from-literal=provider="$(cat <<EOF
name: 'openid_connect'
label: 'Keycloak'
args:
  name: 'openid_connect'
  scope: ['openid', 'profile', 'email', 'groups']
  response_type: 'code'
  issuer: 'https://keycloak.${DOMAIN}/realms/devops'
  discovery: false
  client_auth_method: 'query'
  uid_field: 'preferred_username'
  client_options:
    identifier: 'gitlab'
    secret: '${gitlab_secret}'
    redirect_uri: 'https://gitlab.${DOMAIN}/users/auth/openid_connect/callback'
    authorization_endpoint: 'https://keycloak.${DOMAIN}/realms/devops/protocol/openid-connect/auth'
    token_endpoint: '${KEYCLOAK_INTERNAL_URL}/realms/devops/protocol/openid-connect/token'
    userinfo_endpoint: '${KEYCLOAK_INTERNAL_URL}/realms/devops/protocol/openid-connect/userinfo'
    jwks_uri: '${KEYCLOAK_INTERNAL_URL}/realms/devops/protocol/openid-connect/certs'
    end_session_endpoint: 'https://keycloak.${DOMAIN}/realms/devops/protocol/openid-connect/logout'
EOF
)" \
            --dry-run=client -o yaml | kubectl apply -f -
    fi

    # Vault
    log_info "Configuring Vault OIDC client..."
    local vault_secret=$(create_client "vault" \
        "https://vault.${DOMAIN}/ui/vault/auth/oidc/oidc/callback")
    echo "VAULT_OIDC_SECRET=${vault_secret}" >> "${secrets_file}"

    kubectl create secret generic vault-oidc-secret -n vault \
        --from-literal=client-id=vault \
        --from-literal=client-secret="${vault_secret}" \
        --dry-run=client -o yaml | kubectl apply -f -

    log_info "Client secrets saved to: ${secrets_file}"
    log_info "Kubernetes secrets created in respective namespaces"

    # Restart services that mount OIDC secrets as volumes/env vars
    log_info "Restarting services to pick up real OIDC secrets..."
    kubectl rollout restart deployment/prometheus-grafana -n monitoring 2>/dev/null || true
    kubectl rollout restart deployment/gitlab-webservice-default -n gitlab 2>/dev/null || true
}

# Configure Entra ID as a federated identity provider in Keycloak
# Requires: ENTRA_TENANT_ID, ENTRA_KEYCLOAK_CLIENT_ID (from config.yaml via parse_config)
#           ENTRA_KEYCLOAK_CLIENT_SECRET (from ${SCRIPT_ENV_DIR}/entra-idp.env)
configure_entra_idp() {
    log_step "Configuring Entra ID identity provider..."

    # Load client secret from local secrets file written by sync-tofu-outputs.sh
    local secrets_file="${SCRIPT_ENV_DIR}/entra-idp.env"
    if [[ ! -f "$secrets_file" ]]; then
        log_error "Entra ID secrets not found: ${secrets_file}"
        log_error "Run: ./sync-tofu-outputs.sh --env ${ENV}"
        exit 1
    fi
    source "$secrets_file"

    : "${ENTRA_TENANT_ID:?ENTRA_TENANT_ID not set — check config.yaml entraId.tenantId}"
    : "${ENTRA_KEYCLOAK_CLIENT_ID:?ENTRA_KEYCLOAK_CLIENT_ID not set — check config.yaml entraId.clientId}"
    : "${ENTRA_KEYCLOAK_CLIENT_SECRET:?ENTRA_KEYCLOAK_CLIENT_SECRET not set — check entra-idp.env}"

    # Update the Entra ID App Registration redirect URI to the real Keycloak domain.
    # The tofu module registers a placeholder URI; this fixes it once the domain is known.
    local redirect_uri="https://keycloak.${DOMAIN}/realms/devops/broker/entra/endpoint"
    if command -v az &>/dev/null; then
        log_info "Updating App Registration redirect URI to: ${redirect_uri}"
        az ad app update \
            --id "${ENTRA_KEYCLOAK_CLIENT_ID}" \
            --web-redirect-uris "${redirect_uri}" 2>/dev/null \
            || log_warn "Could not update redirect URI via az CLI — set it manually in the Azure portal"
    else
        log_warn "az CLI not found — set the redirect URI manually in the Azure portal:"
        log_warn "  ${redirect_uri}"
    fi

    # Skip if already configured
    if kcadm get identity-provider/instances/entra -r ${REALM} >/dev/null 2>&1; then
        log_warn "Entra ID identity provider already configured — skipping"
        return 0
    fi

    # Create the OIDC identity provider pointing to Entra ID v2.0 endpoints
    kcadm create identity-provider/instances -r ${REALM} \
        -s alias=entra \
        -s displayName="Microsoft Entra ID" \
        -s providerId=oidc \
        -s enabled=true \
        -s trustEmail=true \
        -s storeToken=false \
        -s "firstBrokerLoginFlowAlias=first broker login" \
        -s "config.useJwksUrl=true" \
        -s "config.validateSignature=true" \
        -s "config.pkceEnabled=false" \
        -s "config.clientAuthMethod=client_secret_post" \
        -s "config.defaultScope=openid profile email" \
        -s "config.authorizationUrl=https://login.microsoftonline.com/${ENTRA_TENANT_ID}/v2.0/authorize" \
        -s "config.tokenUrl=https://login.microsoftonline.com/${ENTRA_TENANT_ID}/v2.0/token" \
        -s "config.jwksUrl=https://login.microsoftonline.com/${ENTRA_TENANT_ID}/discovery/v2.0/keys" \
        -s "config.issuer=https://login.microsoftonline.com/${ENTRA_TENANT_ID}/v2.0" \
        -s "config.clientId=${ENTRA_KEYCLOAK_CLIENT_ID}" \
        -s "config.clientSecret=${ENTRA_KEYCLOAK_CLIENT_SECRET}"

    log_info "Entra ID identity provider created"

    # Mapper: sync email claim → Keycloak user email attribute
    kcadm create identity-provider/instances/entra/mappers -r ${REALM} \
        -s name="entra-email" \
        -s identityProviderMapper=oidc-user-attribute-idp-mapper \
        -s 'config={"syncMode":"INHERIT","claim":"email","user.attribute":"email"}'

    # Mappers: map Entra ID App Roles → Keycloak groups (requires Keycloak 25+)
    # App Roles are defined in the tofu module and appear in the token's 'roles' claim.
    # Assign users/groups to these App Roles in the Azure portal or via azuread_app_role_assignment.
    # syncMode=FORCE re-evaluates group membership on every login (reflects role changes immediately).
    for role_group in "devops-admins" "developers" "viewers"; do
        kcadm create identity-provider/instances/entra/mappers -r ${REALM} \
            -s "name=entra-role-${role_group}" \
            -s identityProviderMapper=oidc-group-idp-mapper \
            -s "{\"config\":{\"syncMode\":\"FORCE\",\"claim\":\"roles\",\"claim.value\":\"${role_group}\",\"group\":\"/${role_group}\"}}"
    done

    log_info "Group mappers added: Entra ID App Role → Keycloak group (devops-admins, developers, viewers)"
    log_info ""
    log_info "Next steps in Azure portal (Entra ID → Enterprise Applications → ${ENTRA_KEYCLOAK_CLIENT_ID}):"
    log_info "  Assign users or security groups to the App Roles to grant DevHub access"
    log_info "  devops-admins → full admin    developers → dev access    viewers → read-only"
}

# Configure Google as a social identity provider in Keycloak
# Requires: GOOGLE_IDP_CLIENT_ID (from config.yaml via parse_config)
#           GOOGLE_IDP_CLIENT_SECRET (from ${SCRIPT_ENV_DIR}/gcp-idp.env)
configure_google_idp() {
    log_step "Configuring Google identity provider..."

    # Load client secret from local secrets file written by the user after creating
    # the OAuth client in Google Cloud Console (sync-tofu-outputs.sh creates the template)
    local secrets_file="${SCRIPT_ENV_DIR}/gcp-idp.env"
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

    # Skip if already configured
    if kcadm get identity-provider/instances/google -r ${REALM} >/dev/null 2>&1; then
        log_warn "Google identity provider already configured — skipping"
        return 0
    fi

    # Create the Google social IdP using Keycloak's built-in google provider type
    kcadm create identity-provider/instances -r ${REALM} \
        -s alias=google \
        -s displayName="Sign in with Google" \
        -s providerId=google \
        -s enabled=true \
        -s trustEmail=true \
        -s storeToken=false \
        -s "firstBrokerLoginFlowAlias=first broker login" \
        -s "config.clientId=${GOOGLE_IDP_CLIENT_ID}" \
        -s "config.clientSecret=${GOOGLE_IDP_CLIENT_SECRET}" \
        -s "config.defaultScope=openid profile email"

    log_info "Google identity provider created"

    # Mapper: sync email claim → Keycloak user email attribute
    kcadm create identity-provider/instances/google/mappers -r ${REALM} \
        -s name="google-email" \
        -s identityProviderMapper=oidc-user-attribute-idp-mapper \
        -s 'config={"syncMode":"INHERIT","claim":"email","user.attribute":"email"}'

    log_info "Email attribute mapper added"
    log_info ""
    log_info "IMPORTANT: Google tokens do not include group/role claims."
    log_info "  After users sign in for the first time, assign them to Keycloak groups manually:"
    log_info "  Keycloak Admin → Users → <user> → Groups → Add to group"
    log_info "  Groups: devops-admins, developers, viewers"
}

# Configure AWS Cognito as a federated OIDC identity provider in Keycloak
# Requires: COGNITO_ISSUER_URL, COGNITO_HOSTED_UI_DOMAIN, COGNITO_CLIENT_ID (from config.yaml)
#           COGNITO_CLIENT_SECRET (from ${SCRIPT_ENV_DIR}/aws-idp.env)
configure_cognito_idp() {
    log_step "Configuring AWS Cognito identity provider..."

    # Load client secret from local secrets file written by sync-tofu-outputs.sh
    local secrets_file="${SCRIPT_ENV_DIR}/aws-idp.env"
    if [[ ! -f "$secrets_file" ]]; then
        log_error "Cognito secrets not found: ${secrets_file}"
        log_error "Run: ./sync-tofu-outputs.sh --env ${ENV}"
        exit 1
    fi
    source "$secrets_file"

    : "${COGNITO_ISSUER_URL:?COGNITO_ISSUER_URL not set — check config.yaml cognitoIdp.issuerUrl}"
    : "${COGNITO_HOSTED_UI_DOMAIN:?COGNITO_HOSTED_UI_DOMAIN not set — check config.yaml cognitoIdp.hostedUiDomain}"
    : "${COGNITO_CLIENT_ID:?COGNITO_CLIENT_ID not set — check config.yaml cognitoIdp.clientId}"
    : "${COGNITO_CLIENT_SECRET:?COGNITO_CLIENT_SECRET not set — check aws-idp.env}"

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

    # Skip if already configured
    if kcadm get identity-provider/instances/aws-cognito -r ${REALM} >/dev/null 2>&1; then
        log_warn "Cognito identity provider already configured — skipping"
        return 0
    fi

    # Create the OIDC identity provider pointing to Cognito's OIDC endpoints
    kcadm create identity-provider/instances -r ${REALM} \
        -s alias=aws-cognito \
        -s displayName="Sign in with AWS (Cognito)" \
        -s providerId=oidc \
        -s enabled=true \
        -s trustEmail=true \
        -s storeToken=false \
        -s "firstBrokerLoginFlowAlias=first broker login" \
        -s "config.useJwksUrl=true" \
        -s "config.validateSignature=true" \
        -s "config.pkceEnabled=false" \
        -s "config.clientAuthMethod=client_secret_post" \
        -s "config.defaultScope=openid profile email" \
        -s "config.authorizationUrl=https://${COGNITO_HOSTED_UI_DOMAIN}/oauth2/authorize" \
        -s "config.tokenUrl=https://${COGNITO_HOSTED_UI_DOMAIN}/oauth2/token" \
        -s "config.jwksUrl=${COGNITO_ISSUER_URL}/.well-known/jwks.json" \
        -s "config.issuer=${COGNITO_ISSUER_URL}" \
        -s "config.clientId=${COGNITO_CLIENT_ID}" \
        -s "config.clientSecret=${COGNITO_CLIENT_SECRET}"

    log_info "Cognito identity provider created"

    # Mapper: sync email claim → Keycloak user email attribute
    kcadm create identity-provider/instances/aws-cognito/mappers -r ${REALM} \
        -s name="cognito-email" \
        -s identityProviderMapper=oidc-user-attribute-idp-mapper \
        -s 'config={"syncMode":"INHERIT","claim":"email","user.attribute":"email"}'

    # Mappers: map Cognito groups → Keycloak groups (requires Keycloak 25+)
    # Cognito includes a `cognito:groups` array claim in the ID token when users are in groups.
    # Assign Cognito users to groups (devops-admins, developers, viewers) in the AWS console:
    #   Amazon Cognito → User pools → <pool> → Users → <user> → Add user to group
    # syncMode=FORCE re-evaluates group membership on every login.
    for group in "devops-admins" "developers" "viewers"; do
        kcadm create identity-provider/instances/aws-cognito/mappers -r ${REALM} \
            -s "name=cognito-group-${group}" \
            -s identityProviderMapper=oidc-group-idp-mapper \
            -s "{\"config\":{\"syncMode\":\"FORCE\",\"claim\":\"cognito:groups\",\"claim.value\":\"${group}\",\"group\":\"/${group}\"}}"
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
    echo "  - platform-admin (permanent password, full admin access)"
    echo "  - devops-admin (temporary password, must change on first login)"
    echo ""
    echo "Services configured with SSO:"
    echo "  - Grafana: https://grafana.${DOMAIN}"
    echo "  - ArgoCD: https://argocd.${DOMAIN}"
    echo "  - GitLab: https://gitlab.${DOMAIN}"
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
    kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=keycloakx -n keycloak --timeout=300s

    kcadm_login

    case "$action" in
        all)
            create_realm
            create_groups
            configure_clients
            configure_groups_scope
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
            echo "Usage: $0 --env local|upcloud-dev|upcloud-prod|azure-dev|azure-prod|gcp-dev|gcp-prod|aws-dev|aws-prod [all|realm|clients|user|idp]"
            exit 1
            ;;
    esac
}

main "$@"
