# SSO Testing Guide

## Admin User Credentials

**Platform Administrator Account**:
- Username: `platform-admin`
- Password: Check `k8s/scripts/local/oidc-secrets.env` for `PLATFORM_ADMIN_PASSWORD`
- Email: platform-admin@localhost
- Group: `devops-admins` (full admin access to all services)

> **Note**: The password is auto-generated during setup. To reset it manually:
> ```bash
> kubectl exec -n keycloak keycloak-keycloakx-0 -- /opt/keycloak/bin/kcadm.sh set-password -r devops --username platform-admin --new-password "YourNewPassword"
> ```
> Avoid special characters like `!` `@` `$` in passwords set via kcadm to prevent shell escaping issues.

**Keycloak Admin Console**:
- URL: https://keycloak.localhost/admin/
- Username: `admin`
- Password: Run `kubectl get secret keycloak-admin-secret -n keycloak -o jsonpath='{.data.KEYCLOAK_ADMIN_PASSWORD}' | base64 -d`

## Testing SSO Login - Step by Step

### 1. Test Grafana SSO

**Steps**:
1. Open https://grafana.localhost in your browser
2. You should see a "Sign in with Keycloak" button
3. Click the button
4. You'll be redirected to Keycloak login page
5. Enter credentials:
   - Username: `platform-admin`
   - Password: value from `PLATFORM_ADMIN_PASSWORD`
6. Click "Sign In"
7. You should be redirected back to Grafana
8. **Expected Result**: You are logged in as admin with full access

**Verify Access**:
- Check user icon in top-right → Should show "platform-admin"
- Go to Configuration → Users → You should see the Users management page (admin only)
- Try creating a dashboard → Should work (admin has full permissions)

---

### 2. Test GitLab SSO

**Steps**:
1. Open https://gitlab.localhost in your browser
2. You'll be redirected to the sign-in page
3. Look for the "Keycloak" button (OpenID Connect provider)
4. Click the "Keycloak" button
5. You'll be redirected to Keycloak login page
6. Enter credentials:
   - Username: `platform-admin`
   - Password: value from `PLATFORM_ADMIN_PASSWORD`
7. Click "Sign In"
8. You should be redirected back to GitLab
9. **Expected Result**: You are logged in and a new GitLab account is auto-created

**Verify Access**:
- Check user avatar in top-right → Should show "platform-admin"
- You should be able to create projects
- Go to Admin Area (wrench icon) → Should have admin access

**Note**: On first login, GitLab auto-creates a user account linked to your Keycloak identity.

---

### 3. Test ArgoCD SSO

**Steps**:
1. Open https://argocd.localhost in your browser
2. You should see the login page
3. Look for "LOG IN VIA KEYCLOAK" button
4. Click the button
5. You'll be redirected to Keycloak login page
6. Enter credentials:
   - Username: `platform-admin`
   - Password: value from `PLATFORM_ADMIN_PASSWORD`
7. Click "Sign In"
8. You should be redirected back to ArgoCD
9. **Expected Result**: You are logged in with admin access

**Verify Access**:
- Check user info in top-left → Should show "platform-admin"
- You should see "+ NEW APP" button (admin only)
- Try accessing Settings → You should have full access

**Troubleshooting**:
- If ArgoCD returns 500 error:
  1. Check ArgoCD server logs: `kubectl logs -n argocd deployment/argocd-server`
  2. Restart ArgoCD: `kubectl rollout restart deployment argocd-server -n argocd`
  3. Wait 30 seconds and try again

---

### 4. Test Vault SSO (Optional)

**Note**: Vault OIDC requires additional manual configuration after setup.

**Steps to Enable**:
1. Vault must be initialized and unsealed first
2. Enable OIDC auth method:
   ```bash
   vault auth enable oidc
   ```
3. Configure OIDC:
   ```bash
   vault write auth/oidc/config \
     oidc_discovery_url="https://keycloak.localhost/realms/devops" \
     oidc_client_id="vault" \
     oidc_client_secret="<from kubectl get secret vault-oidc-secret -n vault>" \
     default_role="reader"
   ```
4. Create a role:
   ```bash
   vault write auth/oidc/role/reader \
     bound_audiences="vault" \
     allowed_redirect_uris="https://vault.localhost/ui/vault/auth/oidc/oidc/callback" \
     user_claim="sub" \
     policies="default"
   ```

---

## Troubleshooting Common Issues

### Issue: "Invalid redirect URI"

**Cause**: The redirect URI in the service doesn't match what's registered in Keycloak.

**Fix**:
1. Log in to Keycloak Admin Console
2. Go to: Realm: devops → Clients → [service-name]
3. Check "Valid Redirect URIs"
4. Should include:
   - Grafana: `https://grafana.localhost/login/generic_oauth`
   - ArgoCD: `https://argocd.localhost/auth/callback`
   - GitLab: `https://gitlab.localhost/users/auth/openid_connect/callback`

### Issue: "User not authorized" or "Access Denied"

**Cause**: User is not in the correct group or group mappings are incorrect.

**Fix**:
1. Log in to Keycloak Admin Console
2. Go to: Realm: devops → Users → Search for "platform-admin"
3. Click on the user → Groups tab
4. Ensure user is member of: `devops-admins`
5. If not, click "Join Group" and select "devops-admins"

### Issue: Service doesn't show SSO login button

**Cause**: Service hasn't picked up OIDC configuration.

**Fix**:
1. Check that the OIDC secret exists:
   ```bash
   kubectl get secret <service>-oidc-secret -n <namespace>
   ```
2. Restart the service:
   ```bash
   # Grafana
   kubectl rollout restart deployment prometheus-grafana -n monitoring

   # ArgoCD
   kubectl rollout restart deployment argocd-server -n argocd

   # GitLab
   kubectl rollout restart deployment gitlab-webservice-default -n gitlab
   ```
3. Wait 30-60 seconds for pods to restart
4. Try accessing the service again

### Issue: "Account is not fully set up"

**Cause**: User has required actions pending in Keycloak.

**Fix**:
1. Log in to Keycloak Admin Console
2. Go to: Realm: devops → Users → Search for the user
3. Click on the user → Required Actions tab
4. Remove any required actions
5. Click "Save"

---

## Verification Checklist

Use this checklist to verify SSO is working correctly:

- [ ] **Keycloak**
  - [ ] Admin console accessible at https://keycloak.localhost/admin/
  - [ ] Realm "devops" exists
  - [ ] Groups exist: devops-admins, developers, viewers
  - [ ] platform-admin user exists and is in devops-admins group
  - [ ] All client IDs exist: grafana, argocd, gitlab, vault

- [ ] **Grafana**
  - [ ] "Sign in with Keycloak" button visible
  - [ ] Redirects to Keycloak login
  - [ ] Successfully logs in
  - [ ] User has admin access
  - [ ] Can create/edit dashboards

- [ ] **GitLab**
  - [ ] "Keycloak" button visible on sign-in page
  - [ ] Redirects to Keycloak login
  - [ ] Successfully logs in
  - [ ] User account auto-created
  - [ ] Can create projects

- [ ] **ArgoCD**
  - [ ] "LOG IN VIA KEYCLOAK" button visible
  - [ ] Redirects to Keycloak login
  - [ ] Successfully logs in
  - [ ] User has admin access
  - [ ] Can create applications

---

## Group-Based Access Control

### Groups and Their Permissions

**devops-admins**:
- Grafana: Admin role (full access)
- ArgoCD: Admin role (can create/delete apps, modify settings)
- GitLab: Admin access (can manage projects and settings)

**developers**:
- Grafana: Editor role (can create/edit dashboards)
- ArgoCD: Read-only access (can view apps but not modify)
- GitLab: Developer access (can push code, create merge requests)

**viewers**:
- Grafana: Viewer role (read-only access to dashboards)
- ArgoCD: Read-only access
- GitLab: Reporter access (read-only)

### Testing Different Access Levels

To test different access levels:

1. Create test users in Keycloak:
   ```bash
   # Developer user
   kubectl exec -n keycloak keycloak-keycloakx-0 -- /opt/keycloak/bin/kcadm.sh create users -r devops \
     -s username=dev-test -s email=dev@localhost -s enabled=true -s emailVerified=true

   # Set password
   kubectl exec -n keycloak keycloak-keycloakx-0 -- /opt/keycloak/bin/kcadm.sh set-password -r devops \
     --username dev-test --new-password "Dev123!"
   ```

2. Assign to different groups in Keycloak Admin Console

3. Test login with different users to verify permissions

---

## Security Notes

- **Passwords**: Change the default platform-admin password for production use
- **Groups**: Regularly audit group memberships
- **Sessions**: Sessions are managed by Keycloak - logout from one service doesn't logout from all (yet)
- **Client Secrets**: Stored in Kubernetes secrets - rotate periodically in production
- **SSL/TLS**: All OAuth communication uses HTTPS

---

## Getting Help

If SSO is not working:

1. Check service logs:
   ```bash
   kubectl logs -n monitoring deployment/prometheus-grafana
   kubectl logs -n argocd deployment/argocd-server
   kubectl logs -n gitlab deployment/gitlab-webservice-default
   ```

2. Check Keycloak logs:
   ```bash
   kubectl logs -n keycloak keycloak-keycloakx-0
   ```

3. Verify OIDC endpoints are accessible:
   ```bash
   curl -k https://keycloak.localhost/realms/devops/.well-known/openid-configuration
   ```

4. Check the full SSO documentation: `k8s/docs/KEYCLOAK_SSO.md`
