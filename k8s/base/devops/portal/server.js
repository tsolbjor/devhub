// Portal backend — scaffolds a new application by writing to Forgejo, and
// nothing else. No kubeconfig, no Vault token, no kubectl: the cluster reacts
// to the git state this creates (forgejo-appset deploys the repo, Kyverno
// fences the namespace), so every provision is a commit somebody can read,
// revert and mirror.
//
// Runs on a stock node:22-alpine image with zero dependencies: http for the
// server, global fetch for the Forgejo JSON API.

'use strict';

const http = require('http');
const fs = require('fs');
const path = require('path');
const crypto = require('crypto');

const PORT = Number(process.env.PORT || 8080);
const DOMAIN = process.env.DOMAIN || 'localhost';
const FORGEJO_URL = process.env.FORGEJO_URL || 'http://forgejo-http.forgejo.svc.cluster.local:3000';
const FORGEJO_TOKEN = process.env.FORGEJO_TOKEN || '';
// Whose token that is: a dedicated non-admin bot account, an org member via the
// `portal-bot` team, NOT the Forgejo site admin. Used only for log messages and
// error text — the portal never reads /user back (its token scopes cannot), so
// the name is configuration, taken from the token secret's `username` key.
// Keep it in step with PORTAL_BOT_USER in deploy.sh.
const FORGEJO_BOT_USER = (process.env.FORGEJO_BOT_USER || 'devhub-bot').trim();
const APPS_ORG = process.env.APPS_ORG || 'devhub';
const TEMPLATES_ORG = process.env.TEMPLATES_ORG || 'devhub-templates';
// Optional: set by `deploy.sh <env> ci-secrets`. Without a token the wizard
// still works; repo activation becomes a starter issue instead.
const WOODPECKER_URL = process.env.WOODPECKER_URL || 'http://woodpecker-server.woodpecker.svc.cluster.local';
const WOODPECKER_TOKEN = (process.env.WOODPECKER_TOKEN || '').trim();
const CAN_ACTIVATE_CI = WOODPECKER_TOKEN !== '' && WOODPECKER_TOKEN !== 'placeholder';
// Keycloak's JWKS endpoint, for verifying the gateway-forwarded access token
// (defense in depth — see userFromRequest). Always the in-cluster Service URL,
// never the public hostname: on local, glibc answers *.localhost with the
// pod's own loopback.
const KEYCLOAK_JWKS_URL = (process.env.KEYCLOAK_JWKS_URL || '').trim();
// Groups whose members may provision (create apps, enable add-ons). Read
// endpoints stay open to every authenticated user. Keycloak's groups client
// scope maps membership into the access token's `groups` claim.
const PROVISION_GROUPS = new Set(
  (process.env.PROVISION_GROUPS || 'developers,devops-admins')
    .split(',').map((s) => s.trim().replace(/^\//, '')).filter(Boolean),
);

if (!KEYCLOAK_JWKS_URL) {
  console.warn(
    '[WARN] KEYCLOAK_JWKS_URL is not set — access tokens will be parsed WITHOUT '
    + 'signature verification, relying on the gateway SecurityPolicy and the '
    + 'NetworkPolicy alone. Set it to Keycloak\'s in-cluster JWKS endpoint.',
  );
}

const INDEX_HTML = fs.readFileSync(path.join(__dirname, 'index.html'), 'utf8');

// ── Forgejo API ─────────────────────────────────────────────────────────────

async function forgejo(method, apiPath, body) {
  const res = await fetch(`${FORGEJO_URL}/api/v1${apiPath}`, {
    method,
    headers: {
      Authorization: `token ${FORGEJO_TOKEN}`,
      'Content-Type': 'application/json',
    },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  const text = await res.text();
  let json = null;
  try { json = text ? JSON.parse(text) : null; } catch { /* non-JSON error body */ }
  if (!res.ok) {
    const message = (json && (json.message || json.error)) || text || res.statusText;
    const err = new Error(`Forgejo ${method} ${apiPath}: ${res.status} ${message}`);
    err.status = res.status;
    throw err;
  }
  return json;
}

// Activate a repo in Woodpecker so the first push already builds. Forgejo's
// numeric repo id is Woodpecker's forge_remote_id.
async function woodpeckerActivate(forgeRemoteId) {
  const res = await fetch(`${WOODPECKER_URL}/api/repos?forge_remote_id=${forgeRemoteId}`, {
    method: 'POST',
    headers: { Authorization: `Bearer ${WOODPECKER_TOKEN}` },
  });
  const text = await res.text();
  if (!res.ok) throw new Error(`Woodpecker activation: ${res.status} ${text || res.statusText}`);
  try { return JSON.parse(text); } catch { return null; }
}

// ── Scaffolding ─────────────────────────────────────────────────────────────

// Repo names become DNS labels (namespace devhub-<name>, hostname <name>.<domain>),
// so the rules are DNS-1123's, with headroom for the devhub- prefix.
const NAME_RE = /^[a-z](?:[a-z0-9-]{0,37}[a-z0-9])?$/;

// Hostnames the platform itself claims on the same domain. An app named
// "grafana" would resolve — into the wrong service. Extendable per environment
// without a rebuild: RESERVED_NAMES="foo,bar".
const RESERVED = new Set([
  'keycloak', 'auth', 'vault', 'git', 'ci', 'argocd', 'grafana', 'prometheus',
  'alertmanager', 'loki', 'tempo', 'headlamp', 'home', 'homepage', 'portal',
  'registry', 'www', 'api', 'status',
  ...(process.env.RESERVED_NAMES || '').split(',').map((s) => s.trim()).filter(Boolean),
]);

// Identity comes from the gateway: the SecurityPolicy authenticates the
// browser and forwards the Keycloak access token upstream
// (forwardAccessToken). The NetworkPolicy admits only the gateway and the
// gateway never forwards an unauthenticated request — but as defense in depth
// the token's RS256 signature is verified here too, against Keycloak's JWKS
// (KEYCLOAK_JWKS_URL, in-cluster). Only if no JWKS URL is configured does the
// portal fall back to trusting the perimeter and parsing the payload as-is
// (startup warning above). Forgejo usernames match Keycloak's
// preferred_username because Forgejo accounts are created by the same
// Keycloak OIDC login.

// JWKS cache: kid → KeyObject. Refetched on an unknown kid (key rotation),
// rate-limited so a stream of garbage kids cannot hammer Keycloak. Throws
// only when the endpoint itself is unreachable/broken AND no keys are cached
// — an infrastructure failure the caller may distinguish from a bad token.
const jwks = { keys: new Map(), lastFetch: 0, lastError: null };
const JWKS_REFETCH_MIN_MS = 30 * 1000;

async function jwksKeyFor(kid) {
  if (jwks.keys.has(kid)) return jwks.keys.get(kid);
  if (Date.now() - jwks.lastFetch >= JWKS_REFETCH_MIN_MS) {
    jwks.lastFetch = Date.now();
    try {
      const res = await fetch(KEYCLOAK_JWKS_URL);
      if (!res.ok) throw new Error(`JWKS fetch: ${res.status} ${res.statusText}`);
      const body = await res.json();
      const fresh = new Map();
      for (const k of body.keys || []) {
        if (k.kty !== 'RSA' || (k.use && k.use !== 'sig') || !k.kid) continue;
        try { fresh.set(k.kid, crypto.createPublicKey({ key: k, format: 'jwk' })); }
        catch (e) { console.error(`JWKS key ${k.kid}: ${e.message}`); }
      }
      jwks.keys = fresh; // replace wholesale: rotated-out keys must stop verifying
      jwks.lastError = null;
    } catch (e) {
      jwks.lastError = e;
      if (jwks.keys.size === 0) throw e;
    }
  } else if (jwks.keys.size === 0 && jwks.lastError) {
    throw jwks.lastError;
  }
  return jwks.keys.get(kid) || null;
}

// Verify signature and expiry; returns the claims or null. Any surprise about
// the TOKEN (bad alg, unknown kid, bad signature, expired) is an
// unauthenticated request; only a JWKS infrastructure failure propagates.
async function verifyToken(parts) {
  let header;
  try { header = JSON.parse(Buffer.from(parts[0], 'base64url').toString('utf8')); }
  catch { return null; }
  if (header.alg !== 'RS256' || !header.kid) return null;
  const key = await jwksKeyFor(header.kid); // may throw: JWKS unreachable
  if (!key) return null;
  try {
    const ok = crypto.verify(
      'RSA-SHA256',
      Buffer.from(`${parts[0]}.${parts[1]}`),
      key,
      Buffer.from(parts[2], 'base64url'),
    );
    if (!ok) return null;
    const claims = JSON.parse(Buffer.from(parts[1], 'base64url').toString('utf8'));
    if (typeof claims.exp === 'number' && claims.exp * 1000 < Date.now()) return null;
    return claims;
  } catch (e) {
    console.error(`token verification: ${e.message}`);
    return null;
  }
}

let lastJwksWarn = 0;
function parsePayloadUnverified(parts) {
  try { return JSON.parse(Buffer.from(parts[1], 'base64url').toString('utf8')); }
  catch { return null; }
}

async function userFromRequest(req) {
  const m = (req.headers.authorization || '').match(/^Bearer (.+)$/i);
  if (!m) return null;
  const parts = m[1].split('.');
  if (parts.length !== 3) return null;
  let claims = null;
  if (KEYCLOAK_JWKS_URL) {
    try {
      claims = await verifyToken(parts);
    } catch (e) {
      // JWKS endpoint unreachable and no keys cached. Verification here is
      // defense in depth — the gateway + NetworkPolicy perimeter is the
      // primary control — so degrade to perimeter trust rather than locking
      // everyone out, and say so loudly (at most once a minute). Note: the
      // keycloak namespace's ingress NetworkPolicy must admit the portal for
      // the JWKS fetch to work at all.
      if (Date.now() - lastJwksWarn > 60 * 1000) {
        lastJwksWarn = Date.now();
        console.error(`[WARN] JWKS unavailable (${e.message}) — falling back to unverified token parsing (perimeter trust)`);
      }
      claims = parsePayloadUnverified(parts);
    }
  } else {
    // Perimeter-trust fallback: gateway + NetworkPolicy only.
    claims = parsePayloadUnverified(parts);
  }
  if (!claims || !claims.preferred_username) return null;
  // Keycloak's groups mapper emits plain names (full.path: false); strip a
  // leading slash anyway so a full-path realm config still matches.
  const groups = Array.isArray(claims.groups)
    ? claims.groups.map((g) => String(g).replace(/^\//, ''))
    : [];
  return { username: claims.preferred_username, groups };
}

// Provisioning (creating apps, enabling add-ons) is gated on group
// membership; reading stays open to everyone the gateway signed in.
function requireProvisioner(user) {
  if (!user) {
    throw Object.assign(
      new Error('No identity on the request — the gateway must forward the access token (forwardAccessToken).'),
      { status: 401 },
    );
  }
  if (!user.groups.some((g) => PROVISION_GROUPS.has(g))) {
    throw Object.assign(
      new Error(
        `Provisioning requires membership of one of: ${[...PROVISION_GROUPS].join(', ')} — `
        + `${user.username} is in [${user.groups.join(', ') || 'no groups'}]. Ask a platform admin.`,
      ),
      { status: 403 },
    );
  }
  return user;
}

// Run fn over items with at most `limit` in flight; resolves in input order.
async function mapLimit(items, limit, fn) {
  const out = new Array(items.length);
  let next = 0;
  const worker = async () => {
    while (next < items.length) {
      const i = next++;
      out[i] = await fn(items[i], i);
    }
  };
  await Promise.all(Array.from({ length: Math.min(limit, items.length) }, worker));
  return out;
}

// The user's effective permission on an app repo ('owner', 'admin', 'write',
// 'read', 'none'). Org owners come back as admin/owner too.
//
// Forgejo only answers this for a caller that is admin on the repo, and the
// portal's bot deliberately is not admin everywhere: its team in the apps org
// has includes_all_repositories=false, so it administers the repos it created
// (Forgejo makes the creator an admin collaborator) and the ones deploy.sh
// adopted — but not, say, a repo a human made by hand, and not the private
// GitOps repository. Keeping the bot out of those is the point of the
// arrangement, so a 403 here is expected operation, not an error: report "no
// permission" for that one repo rather than failing the whole listing. Logged,
// because it is also how a missing adoption shows up.
async function userRepoPermission(username, name) {
  try {
    const p = await forgejo(
      'GET',
      `/repos/${APPS_ORG}/${name}/collaborators/${encodeURIComponent(username)}/permission`,
    );
    return (p && p.permission) || 'none';
  } catch (e) {
    if (e.status === 404 || e.status === 422) return 'none';
    if (e.status === 403) {
      console.error(
        `permission lookup on ${APPS_ORG}/${name} denied — ${FORGEJO_BOT_USER} is not admin there; `
        + `treating as no access for ${username} (a platform admin can adopt the repo: deploy.sh <env> portal-token)`,
      );
      return 'none';
    }
    throw e;
  }
}

const CAN_DEPROVISION = (perm) => perm === 'admin' || perm === 'owner';

// Template repos named addon-* are platform add-ons (see /api/addons), not
// scaffolding templates; enabled add-ons live in the apps org under the same
// name, so the prefix is reserved on both sides.
const ADDON_PREFIX = 'addon-';

// The one "name is taken" verdict. createApp has to recognise it to decide
// whether to try resuming an orphaned repo, so it lives in one place rather
// than being compared as a duplicated literal in two functions.
const repoExistsReason = (name) => `Repository ${APPS_ORG}/${name} already exists.`;

// One answer for both the live check (/api/validate-name) and the create path:
// syntactically a DNS label, not a platform hostname, not an existing repo.
async function validateName(name) {
  if (!NAME_RE.test(name || '')) {
    return {
      available: false,
      reason: 'Must be a DNS label: lowercase letters, digits and dashes, max 39 chars, starting with a letter.',
    };
  }
  if (name.startsWith(ADDON_PREFIX)) {
    return { available: false, reason: `The "${ADDON_PREFIX}" prefix is reserved for platform add-ons.` };
  }
  if (RESERVED.has(name)) {
    return { available: false, reason: `"${name}.${DOMAIN}" is a platform hostname — pick another name.` };
  }
  try {
    await forgejo('GET', `/repos/${APPS_ORG}/${name}`);
    return { available: false, reason: repoExistsReason(name) };
  } catch (e) {
    if (e.status !== 404) throw e;
  }
  return { available: true, reason: `${name}.${DOMAIN} is available.` };
}

// The template convention (see k8s/templates/app-template): the literal tokens
// APP_NAME and DOMAIN, in both file content and file names — APP_NAME first, so
// APP_NAME.DOMAIN resolves to <name>.<domain> — plus POSTGRES_ENABLED and
// REDIS_ENABLED, which become the values.yaml opt-in flags.
//
// WARNING for template authors: replacement is a global, literal string swap
// on EVERY file — there is no word-boundary or escaping mechanism. A template
// that uses the bare words APP_NAME, DOMAIN, POSTGRES_ENABLED or
// REDIS_ENABLED in prose (a README sentence, a code comment) gets them
// substituted too. Treat the four tokens as reserved; write "domain name",
// "the app's name", etc. in prose. Documented in k8s/templates/
// TEMPLATE-AUTHORING.md.
function substitute(text, name, options) {
  return text
    .split('APP_NAME').join(name)
    .split('DOMAIN').join(DOMAIN)
    .split('POSTGRES_ENABLED').join(options && options.postgres ? 'true' : 'false')
    .split('REDIS_ENABLED').join(options && options.redis ? 'true' : 'false');
}

// Optional add-ons as files: templates that keep manifests under optional/ get
// them copied into k8s/ when asked for; anything else under optional/ never
// ships. The default app-template no longer uses this — its data services are
// the POSTGRES_ENABLED/REDIS_ENABLED flags in k8s/values.yaml — but custom
// raw-manifest templates still can.
const OPTIONS = {
  postgres: { file: 'optional/postgres.yaml', dest: 'k8s/postgres.yaml' },
  redis: { file: 'optional/redis.yaml', dest: 'k8s/redis.yaml' },
};

const STARTER_ISSUES = (name, options, ciActivated) => {
  const issues = [];
  if (!ciActivated) {
    issues.push({
      title: 'Activate CI in Woodpecker',
      body:
        `Enable this repository at https://ci.${DOMAIN}/repos/add. Registry credentials ` +
        'come from the devhub org-level Woodpecker secrets (`registry_user`/`registry_token`), ' +
        'so no per-repo secret setup is needed. Until activated, pushes build nothing. ' +
        '(A platform admin can make this automatic: `deploy.sh <env> ci-secrets`.)',
    });
  }
  issues.push(
    {
      title: `Verify the app is reachable at https://${name}.${DOMAIN}`,
      body:
        'The devhub-app chart\'s HTTPRoute attaches to the workload gateway\'s wildcard ' +
        '`apps` listener; external-dns creates the DNS record from the HTTPRoute and ' +
        'cert-manager serves the wildcard certificate (DNS-01). Nothing to configure per ' +
        'app — this is a check, after the first image is pushed. Exception: on UpCloud the ' +
        '`letsencrypt-dns01` ClusterIssuer is a manual Cloudflare setup; ask a platform ' +
        'admin if TLS fails there.',
    },
    {
      title: 'Review resource requests and limits',
      body:
        'The chart ships conservative defaults; override them under `app.resources` in ' +
        'k8s/values.yaml. Kyverno enforces that requests and limits exist, and the ' +
        'namespace quota caps the total.',
    },
    {
      title: 'Set up the project board',
      body:
        `Create a kanban board at https://git.${DOMAIN}/${APPS_ORG}/${name}/projects ` +
        '(the "Basic Kanban" template fits the starter issues). Forgejo has no Projects ' +
        'API yet (forgejo/forgejo#5330), so the portal cannot create it for you — the ' +
        'starter issues are grouped under the "Getting started" milestone in the meantime.',
    },
  );
  for (const key of ['postgres', 'redis']) {
    if (options[key]) {
      issues.push({
        title: `Plan the move from dev-grade ${key} to a managed service`,
        body:
          `\`${key}.enabled: true\` in k8s/values.yaml runs a single in-namespace instance; ` +
          'its password is generated in-cluster by an External Secrets `Password` generator ' +
          '(nothing is committed) and the connection env vars are injected into the app ' +
          'container by the chart. Fine for development — production data belongs on the ' +
          `managed ${key === 'postgres' ? 'PostgreSQL' : 'cache'} the platform provisions per cloud.`,
      });
    }
  }
  return issues;
};

async function templateFiles(templateRepo) {
  const repo = await forgejo('GET', `/repos/${TEMPLATES_ORG}/${templateRepo}`);
  const tree = await forgejo(
    'GET',
    `/repos/${TEMPLATES_ORG}/${templateRepo}/git/trees/${encodeURIComponent(repo.default_branch)}?recursive=true`,
  );
  return (tree.tree || []).filter((e) => e.type === 'blob').map((e) => e.path);
}

async function fileContent(templateRepo, filePath) {
  const entry = await forgejo(
    'GET',
    `/repos/${TEMPLATES_ORG}/${templateRepo}/contents/${filePath.split('/').map(encodeURIComponent).join('/')}`,
  );
  return Buffer.from(entry.content, 'base64').toString('utf8');
}

// A previous run may have created the repository and crashed before the
// scaffold commit landed. Such a repo is empty (zero branches) and safe to
// resume into — returns the repo object if so, null if the name is free, and
// throws a 409 if the repo exists with content (genuinely taken).
async function resumableOrphan(name) {
  let repo;
  try {
    repo = await forgejo('GET', `/repos/${APPS_ORG}/${name}`);
  } catch (e) {
    if (e.status === 404) return null;
    throw e;
  }
  const branches = await forgejo('GET', `/repos/${APPS_ORG}/${name}/branches`).catch(() => [{}]);
  if (Array.isArray(branches) && branches.length === 0) return repo;
  throw Object.assign(new Error(repoExistsReason(name)), { status: 409 });
}

async function createApp({ name, description, template, options, creator }) {
  const steps = [];
  const step = (title, detail) => steps.push({ title, detail });

  // Fail before creating anything: bad label, platform hostname, taken repo.
  // Exception: a repo that exists but is EMPTY is the debris of a crashed
  // earlier run — resume it instead of declaring the name taken forever.
  const verdict = await validateName(name);
  let created = null;
  if (!verdict.available) {
    if (verdict.reason !== repoExistsReason(name)) {
      throw Object.assign(new Error(verdict.reason), { status: NAME_RE.test(name || '') ? 409 : 400 });
    }
    created = await resumableOrphan(name); // throws 409 when non-empty
    step('Repository resumed', `${APPS_ORG}/${name} existed but was empty (a previous run failed) — continuing`);
  }

  // Read the template, substitute, route optional files.
  const paths = await templateFiles(template);
  const files = [];
  for (const p of paths) {
    const opt = Object.entries(OPTIONS).find(([, o]) => o.file === p);
    if (p.startsWith('optional/')) {
      if (!opt || !options[opt[0]]) continue;
    }
    const raw = await fileContent(template, p);
    const dest = opt && options[opt[0]] ? opt[1].dest : p;
    files.push({
      operation: 'create',
      path: substitute(dest, name, options),
      content: Buffer.from(substitute(raw, name, options), 'utf8').toString('base64'),
    });
  }
  step('Template read', `${files.length} files from ${TEMPLATES_ORG}/${template}`);

  // Only templates that ship a pipeline get activated in Woodpecker — a repo
  // without .woodpecker.yml (e.g. one deploying a stock upstream image) has
  // nothing to build.
  const hasCI = paths.includes('.woodpecker.yml');

  if (!created) {
    created = await forgejo('POST', `/orgs/${APPS_ORG}/repos`, {
      name,
      description: description || `${name} — scaffolded by the devhub portal`,
      private: false,
      auto_init: false,
      default_branch: 'main',
    });
    step('Repository created', `${APPS_ORG}/${name}`);
  }

  // Everything from here to the scaffold commit must not leave an orphan: a
  // failure before the commit deletes the empty repo again (best-effort), so
  // the name does not become permanently "taken". After the commit the repo
  // is a valid scaffold and is never rolled back.
  let committed = false;
  try {
    // Record who provisioned this: the signed-in user becomes repository admin,
    // which is also what authorises them to deprovision it later. Best-effort —
    // a user who has never opened Forgejo (so no account yet) just isn't added.
    if (creator) {
      try {
        await forgejo('PUT',
          `/repos/${APPS_ORG}/${name}/collaborators/${encodeURIComponent(creator.username)}`,
          { permission: 'admin' });
        step('Owner recorded', `${creator.username} is repository admin — and may deprovision it here`);
      } catch (err) {
        console.error(`collaborator ${creator.username} on ${name}: ${err.message}`);
        step('Owner not recorded', `${err.message} — sign in to Forgejo once, then ask an admin to add you`);
      }
    }

    // CI activation happens BEFORE the first commit, so Woodpecker's webhook is
    // in place when the scaffold lands — the very first push builds and publishes
    // the image, and the app comes up with no human involved. Best-effort: the
    // scaffold is complete without it, so a Woodpecker hiccup must not fail the
    // wizard. Falls back to a starter issue.
    let ciActivated = false;
    let wpRepo = null;
    if (CAN_ACTIVATE_CI && hasCI) {
      try {
        wpRepo = await woodpeckerActivate(created.id);
        ciActivated = true;
        step('CI activated', 'enabled in Woodpecker before the first commit — the scaffold itself builds');
      } catch (err) {
        console.error(`woodpecker activation for ${name}: ${err.message}`);
        step('CI activation failed', `${err.message} — left as a starter issue`);
      }
    }

    // One commit with every file. The batch contents endpoint initialises an
    // empty repository, so no auto_init README to collide with the template's.
    await forgejo('POST', `/repos/${APPS_ORG}/${name}/contents`, {
      message: `Scaffold ${name} from ${TEMPLATES_ORG}/${template}`,
      files,
    });
    committed = true;
    step('Files committed', `${files.length} files on main${ciActivated ? ' — CI is building the first image' : ''}`);

    if (options.issues) {
      // Group the starter issues under one milestone. This is the best grouping
      // the API offers: Forgejo has no Projects (kanban) endpoints yet
      // (forgejo/forgejo#5330), so board creation stays a starter issue.
      let milestoneId = null;
      try {
        const milestone = await forgejo('POST', `/repos/${APPS_ORG}/${name}/milestones`, {
          title: 'Getting started',
          description: 'Scaffold follow-ups created by the portal.',
        });
        milestoneId = milestone && milestone.id ? milestone.id : null;
      } catch (err) {
        console.error(`milestone for ${name}: ${err.message}`);
      }
      let count = 0;
      for (const issue of STARTER_ISSUES(name, options, ciActivated || !hasCI)) {
        await forgejo('POST', `/repos/${APPS_ORG}/${name}/issues`,
          milestoneId ? { ...issue, milestone: milestoneId } : issue);
        count += 1;
      }
      step('Starter issues created', `${count} work items${milestoneId ? ' under the "Getting started" milestone' : ''}`);
    }

    return {
      steps,
      repo: `https://git.${DOMAIN}/${APPS_ORG}/${name}`,
      issues: `https://git.${DOMAIN}/${APPS_ORG}/${name}/issues`,
      board: `https://git.${DOMAIN}/${APPS_ORG}/${name}/projects`,
      ci: ciActivated && wpRepo && wpRepo.id
        ? `https://ci.${DOMAIN}/repos/${wpRepo.id}`
        : `https://ci.${DOMAIN}/repos/add`,
      ciActivated,
      argocd: `https://argocd.${DOMAIN}/applications`,
      image: `git.${DOMAIN}/${APPS_ORG}/${name}`,
      url: `https://${name}.${DOMAIN}`,
    };
  } catch (err) {
    if (!committed) {
      // Roll the empty repo back so the name is not permanently "taken" —
      // best-effort: if this fails too, the next attempt resumes the orphan.
      await forgejo('DELETE', `/repos/${APPS_ORG}/${name}`)
        .catch((e) => console.error(`rollback of ${APPS_ORG}/${name}: ${e.message}`));
    }
    throw err;
  }
}

// ── Add-ons ─────────────────────────────────────────────────────────────────
//
// A platform add-on is a template repository named addon-* in the templates
// org (published by `deploy.sh <env> portal-templates`, like every template).
// Enabling one copies it into the apps org under the same name — and the
// existing conventions do all the work from there: forgejo-appset deploys the
// repo to every registered workload cluster, Kyverno fences its devhub-<name>
// namespace. Disabling is the same repo deletion the apps list uses. Still
// git-only: enable is a commit, disable is a deletion, both auditable and both
// covered by the push mirror. See k8s/docs/ADDONS.md for the convention.

async function listAddons(username) {
  const repos = await forgejo('GET', `/orgs/${TEMPLATES_ORG}/repos`).catch(() => []);
  const templates = (repos || []).filter((t) => t.name.startsWith(ADDON_PREFIX));
  // One enabled-check (+ permission lookup) per add-on — in parallel, bounded.
  return mapLimit(templates, 8, async (t) => {
    let enabled = false;
    let canDisable = false;
    try {
      await forgejo('GET', `/repos/${APPS_ORG}/${t.name}`);
      enabled = true;
      if (username) canDisable = CAN_DEPROVISION(await userRepoPermission(username, t.name));
    } catch (e) {
      if (e.status !== 404) throw e;
    }
    return {
      name: t.name,
      description: t.description || '',
      enabled,
      canDisable,
      repo: enabled ? `https://git.${DOMAIN}/${APPS_ORG}/${t.name}` : null,
      issues: enabled ? `https://git.${DOMAIN}/${APPS_ORG}/${t.name}/issues` : null,
      template: `https://git.${DOMAIN}/${TEMPLATES_ORG}/${t.name}`,
    };
  });
}

async function enableAddon({ name, creator }) {
  const steps = [];
  const step = (title, detail) => steps.push({ title, detail });

  if (!NAME_RE.test(name || '') || !name.startsWith(ADDON_PREFIX)) {
    throw Object.assign(new Error('Not an add-on name.'), { status: 400 });
  }
  // The templates org is the catalog: only add-ons the platform published can
  // be enabled — this is never a way to create an arbitrary repo.
  let template;
  try {
    template = await forgejo('GET', `/repos/${TEMPLATES_ORG}/${name}`);
  } catch (e) {
    if (e.status === 404) throw Object.assign(new Error(`No such add-on: ${name}.`), { status: 404 });
    throw e;
  }
  try {
    await forgejo('GET', `/repos/${APPS_ORG}/${name}`);
    throw Object.assign(new Error(`${name} is already enabled.`), { status: 409 });
  } catch (e) {
    if (e.status !== 404) throw e;
  }

  // Copy everything except optional/ (that mechanism is the app wizard's).
  // Same APP_NAME/DOMAIN substitution as the scaffold — an add-on template
  // mostly needs DOMAIN, e.g. for the platform's public git hostname.
  const paths = await templateFiles(name);
  const files = [];
  for (const p of paths) {
    if (p.startsWith('optional/')) continue;
    const raw = await fileContent(name, p);
    files.push({
      operation: 'create',
      path: substitute(p, name, {}),
      content: Buffer.from(substitute(raw, name, {}), 'utf8').toString('base64'),
    });
  }
  step('Template read', `${files.length} files from ${TEMPLATES_ORG}/${name}`);

  const created = await forgejo('POST', `/orgs/${APPS_ORG}/repos`, {
    name,
    description: template.description || `${name} — platform add-on, enabled via the devhub portal`,
    private: false,
    auto_init: false,
    default_branch: 'main',
  });
  step('Add-on enabled', `${APPS_ORG}/${name} — forgejo-appset deploys it to every registered workload cluster`);

  // Same rollback contract as createApp: a failure before the enabling commit
  // deletes the empty repo (best-effort) so the add-on is not stuck half-on.
  let committed = false;
  try {
    // Whoever enabled it administers it — and is thereby authorised to disable it.
    if (creator) {
      try {
        await forgejo('PUT',
          `/repos/${APPS_ORG}/${name}/collaborators/${encodeURIComponent(creator.username)}`,
          { permission: 'admin' });
        step('Owner recorded', `${creator.username} is repository admin — and may disable the add-on here`);
      } catch (err) {
        console.error(`collaborator ${creator.username} on ${name}: ${err.message}`);
        step('Owner not recorded', `${err.message} — sign in to Forgejo once, then ask an admin to add you`);
      }
    }

    // Add-ons that build their own image ship a .woodpecker.yml; most run a
    // stock upstream image and skip CI entirely.
    if (CAN_ACTIVATE_CI && paths.includes('.woodpecker.yml')) {
      try {
        await woodpeckerActivate(created.id);
        step('CI activated', 'enabled in Woodpecker before the first commit');
      } catch (err) {
        console.error(`woodpecker activation for ${name}: ${err.message}`);
        step('CI activation failed', `${err.message} — activate manually at https://ci.${DOMAIN}/repos/add`);
      }
    }

    await forgejo('POST', `/repos/${APPS_ORG}/${name}/contents`, {
      message: `Enable ${name} from ${TEMPLATES_ORG}/${name}`,
      files,
    });
    committed = true;
    step('Files committed', `${files.length} files on main`);

    // The template's SETUP.md is the handover: whatever a human must still do
    // (tokens into Vault, upstream accounts, tuning) becomes the one open issue.
    const setup = files.find((f) => f.path === 'SETUP.md');
    if (setup) {
      await forgejo('POST', `/repos/${APPS_ORG}/${name}/issues`, {
        title: `Finish setting up ${name}`,
        body: Buffer.from(setup.content, 'base64').toString('utf8'),
      });
      step('Setup issue created', 'the remaining manual steps, from the template\'s SETUP.md');
    }

    return {
      steps,
      repo: `https://git.${DOMAIN}/${APPS_ORG}/${name}`,
      issues: `https://git.${DOMAIN}/${APPS_ORG}/${name}/issues`,
      argocd: `https://argocd.${DOMAIN}/applications`,
    };
  } catch (err) {
    if (!committed) {
      await forgejo('DELETE', `/repos/${APPS_ORG}/${name}`)
        .catch((e) => console.error(`rollback of ${APPS_ORG}/${name}: ${e.message}`));
    }
    throw err;
  }
}

// ── HTTP plumbing ───────────────────────────────────────────────────────────

function send(res, status, body, type = 'application/json') {
  const data = type === 'application/json' ? JSON.stringify(body) : body;
  res.writeHead(status, { 'Content-Type': `${type}; charset=utf-8`, 'Cache-Control': 'no-store' });
  res.end(data);
}

function readBody(req) {
  return new Promise((resolve, reject) => {
    let size = 0;
    const chunks = [];
    req.on('data', (c) => {
      size += c.length;
      if (size > 64 * 1024) { reject(Object.assign(new Error('Body too large'), { status: 413 })); req.destroy(); return; }
      chunks.push(c);
    });
    req.on('end', () => {
      try { resolve(JSON.parse(Buffer.concat(chunks).toString('utf8') || '{}')); }
      catch { reject(Object.assign(new Error('Invalid JSON'), { status: 400 })); }
    });
    req.on('error', reject);
  });
}

const server = http.createServer(async (req, res) => {
  const url = new URL(req.url, `http://${req.headers.host || 'portal'}`);
  try {
    if (req.method === 'GET' && url.pathname === '/healthz') {
      return send(res, 200, 'ok', 'text/plain');
    }
    if (req.method === 'GET' && url.pathname === '/') {
      return send(res, 200, INDEX_HTML, 'text/html');
    }
    if (req.method === 'GET' && url.pathname === '/api/config') {
      const repos = await forgejo('GET', `/orgs/${TEMPLATES_ORG}/repos`).catch(() => []);
      return send(res, 200, {
        domain: DOMAIN,
        appsOrg: APPS_ORG,
        templates: (repos || [])
          // *-chart repos are what scaffolds render THROUGH, not FROM; addon-*
          // repos are platform add-ons, offered on /api/addons instead.
          .filter((r) => !r.name.endsWith('-chart') && !r.name.startsWith(ADDON_PREFIX))
          .map((r) => ({ name: r.name, description: r.description || '' })),
      });
    }
    if (req.method === 'GET' && url.pathname === '/api/validate-name') {
      const verdict = await validateName(String(url.searchParams.get('name') || '').trim());
      return send(res, 200, verdict);
    }
    if (req.method === 'GET' && url.pathname === '/api/apps') {
      // The signed-in user's deprovisionable apps: every devhub-org repo they
      // hold admin on. The platform gitops repo is never offered.
      const user = await userFromRequest(req);
      if (!user) return send(res, 200, { user: null, apps: [] });
      const repos = await forgejo('GET', `/orgs/${APPS_ORG}/repos?limit=100`);
      const candidates = (repos || []).filter(
        // Enabled add-ons are managed on the add-ons view, not as apps.
        (r) => r.name !== 'devhub' && !r.name.startsWith(ADDON_PREFIX),
      );
      // One permission check per repo — in parallel, bounded.
      const perms = await mapLimit(candidates, 8, (r) => userRepoPermission(user.username, r.name));
      const apps = candidates
        .filter((r, i) => CAN_DEPROVISION(perms[i]))
        .map((r) => ({
          name: r.name,
          description: r.description || '',
          repo: `https://git.${DOMAIN}/${APPS_ORG}/${r.name}`,
          url: `https://${r.name}.${DOMAIN}`,
        }));
      return send(res, 200, { user: user.username, apps });
    }
    if (req.method === 'DELETE' && url.pathname.startsWith('/api/apps/')) {
      const name = decodeURIComponent(url.pathname.slice('/api/apps/'.length));
      if (!NAME_RE.test(name) || name === 'devhub') {
        throw Object.assign(new Error('Not a deprovisionable application.'), { status: 400 });
      }
      const user = await userFromRequest(req);
      if (!user) {
        throw Object.assign(
          new Error('No identity on the request — the gateway must forward the access token (forwardAccessToken).'),
          { status: 401 },
        );
      }
      const perm = await userRepoPermission(user.username, name);
      if (!CAN_DEPROVISION(perm)) {
        throw Object.assign(
          new Error(
            `Deprovisioning needs admin on ${APPS_ORG}/${name}; ${user.username} has "${perm}". `
            + `(If you do hold admin there, the portal itself may not: ${FORGEJO_BOT_USER} can only `
            + 'read permissions on repositories it administers — ask a platform admin to run '
            + '`deploy.sh <env> portal-token`, which adopts pre-existing repositories.)',
          ),
          { status: 403 },
        );
      }
      // Deleting the repository IS the deprovision: the ApplicationSets stop
      // generating the Application on their next scan and ArgoCD prunes every
      // deployed resource. Still git-shaped — the portal never touches the
      // cluster. The namespace and its volumes are swept by the platform's
      // `deploy.sh <env> cleanup-apps` (they survive on purpose, as an undo
      // window alongside the Velero backups).
      await forgejo('DELETE', `/repos/${APPS_ORG}/${name}`);
      console.log(`deprovisioned ${APPS_ORG}/${name} by ${user.username}`);
      return send(res, 200, {
        deleted: name,
        note:
          'Repository deleted. ArgoCD removes the deployed workloads within its next scan (≤30 min). ' +
          'The namespace, its volumes and the container images remain until a platform admin runs ' +
          'cleanup-apps / deletes the packages — backups expire on their own.',
      });
    }
    if (req.method === 'GET' && url.pathname === '/api/addons') {
      const user = await userFromRequest(req);
      return send(res, 200, {
        user: user ? user.username : null,
        addons: await listAddons(user ? user.username : null),
      });
    }
    if (req.method === 'POST' && url.pathname === '/api/addons') {
      const body = await readBody(req);
      const result = await enableAddon({
        name: String(body.name || '').trim(),
        creator: requireProvisioner(await userFromRequest(req)),
      });
      return send(res, 201, result);
    }
    if (req.method === 'POST' && url.pathname === '/api/apps') {
      const body = await readBody(req);
      const result = await createApp({
        creator: requireProvisioner(await userFromRequest(req)),
        name: String(body.name || '').trim(),
        description: String(body.description || '').trim().slice(0, 255),
        template: NAME_RE.test(String(body.template || '')) ? String(body.template) : 'app-template',
        options: {
          postgres: Boolean(body.postgres),
          redis: Boolean(body.redis),
          issues: body.issues !== false,
        },
      });
      return send(res, 201, result);
    }
    return send(res, 404, { error: 'Not found' });
  } catch (err) {
    const status = err.status && err.status >= 400 && err.status < 600 ? err.status : 500;
    console.error(`${req.method} ${url.pathname}: ${err.message}`);
    return send(res, status, { error: err.message });
  }
});

server.listen(PORT, () => {
  console.log(
    `portal listening on :${PORT} (forgejo: ${FORGEJO_URL} as ${FORGEJO_BOT_USER}, `
    + `apps org: ${APPS_ORG}, templates org: ${TEMPLATES_ORG})`,
  );
});
