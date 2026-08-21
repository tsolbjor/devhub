// Everything the suite needs to know about the environment under test, read
// from the variables validate-e2e.sh exports. Nothing here reaches for a
// kubeconfig: these tests are a *user's* view of the platform, and a user has a
// browser and a password, not cluster access.

const DOMAIN = process.env.DEVHUB_DOMAIN;
const ENV = process.env.DEVHUB_ENV || 'local';

if (!DOMAIN) {
  throw new Error('DEVHUB_DOMAIN is not set — run this through k8s/scripts/validate-e2e.sh');
}

// Subdomains match k8s/overlays/<env>/config.yaml services: and the HTTPRoutes
// in devops/httproutes.yaml. Keep the two in step — a service that moves needs
// changing in both places or this suite reports it as down.
const host = (sub) => `https://${sub}.${DOMAIN}`;

const services = {
  keycloak: host('keycloak'),
  vault: host('vault'),
  forgejo: host('git'),
  woodpecker: host('ci'),
  argocd: host('argocd'),
  grafana: host('grafana'),
  prometheus: host('prometheus'),
  headlamp: host('headlamp'),
  homepage: host('home'),
};

const credentials = {
  username: process.env.DEVHUB_ADMIN_USER || 'platform-admin',
  password: process.env.DEVHUB_ADMIN_PASSWORD,
};

const realm = process.env.DEVHUB_REALM || 'devops';

// gitops.repoUrl from the overlay's config.yaml: the repository ArgoCD
// reconciles this environment from. Its web page is what the Forgejo tests
// open, because "some repository exists" is a weaker claim than "the one the
// platform depends on is there".
const gitopsRepoUrl = (process.env.DEVHUB_GITOPS_REPO_URL || '').replace(/\.git$/, '');

module.exports = { DOMAIN, ENV, services, credentials, realm, gitopsRepoUrl, host };
