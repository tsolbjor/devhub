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

const PORT = Number(process.env.PORT || 8080);
const DOMAIN = process.env.DOMAIN || 'localhost';
const FORGEJO_URL = process.env.FORGEJO_URL || 'http://forgejo-http.forgejo.svc.cluster.local:3000';
const FORGEJO_TOKEN = process.env.FORGEJO_TOKEN || '';
const APPS_ORG = process.env.APPS_ORG || 'devhub';
const TEMPLATES_ORG = process.env.TEMPLATES_ORG || 'devhub-templates';
// Optional: set by `deploy.sh <env> ci-secrets`. Without a token the wizard
// still works; repo activation becomes a starter issue instead.
const WOODPECKER_URL = process.env.WOODPECKER_URL || 'http://woodpecker-server.woodpecker.svc.cluster.local';
const WOODPECKER_TOKEN = (process.env.WOODPECKER_TOKEN || '').trim();
const CAN_ACTIVATE_CI = WOODPECKER_TOKEN !== '' && WOODPECKER_TOKEN !== 'placeholder';

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

// One answer for both the live check (/api/validate-name) and the create path:
// syntactically a DNS label, not a platform hostname, not an existing repo.
async function validateName(name) {
  if (!NAME_RE.test(name || '')) {
    return {
      available: false,
      reason: 'Must be a DNS label: lowercase letters, digits and dashes, max 39 chars, starting with a letter.',
    };
  }
  if (RESERVED.has(name)) {
    return { available: false, reason: `"${name}.${DOMAIN}" is a platform hostname — pick another name.` };
  }
  try {
    await forgejo('GET', `/repos/${APPS_ORG}/${name}`);
    return { available: false, reason: `Repository ${APPS_ORG}/${name} already exists.` };
  } catch (e) {
    if (e.status !== 404) throw e;
  }
  return { available: true, reason: `${name}.${DOMAIN} is available.` };
}

// The template convention (see k8s/templates/app-template): the literal tokens
// APP_NAME and DOMAIN, in both file content and file names — APP_NAME first, so
// APP_NAME.DOMAIN resolves to <name>.<domain> — plus POSTGRES_ENABLED and
// REDIS_ENABLED, which become the values.yaml opt-in flags.
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

async function createApp({ name, description, template, options }) {
  const steps = [];
  const step = (title, detail) => steps.push({ title, detail });

  // Fail before creating anything: bad label, platform hostname, taken repo.
  const verdict = await validateName(name);
  if (!verdict.available) {
    throw Object.assign(new Error(verdict.reason), { status: NAME_RE.test(name || '') ? 409 : 400 });
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

  const created = await forgejo('POST', `/orgs/${APPS_ORG}/repos`, {
    name,
    description: description || `${name} — scaffolded by the devhub portal`,
    private: false,
    auto_init: false,
    default_branch: 'main',
  });
  step('Repository created', `${APPS_ORG}/${name}`);

  // CI activation happens BEFORE the first commit, so Woodpecker's webhook is
  // in place when the scaffold lands — the very first push builds and publishes
  // the image, and the app comes up with no human involved. Best-effort: the
  // scaffold is complete without it, so a Woodpecker hiccup must not fail the
  // wizard. Falls back to a starter issue.
  let ciActivated = false;
  let wpRepo = null;
  if (CAN_ACTIVATE_CI) {
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
    for (const issue of STARTER_ISSUES(name, options, ciActivated)) {
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
          // *-chart repos are what scaffolds render THROUGH, not FROM.
          .filter((r) => !r.name.endsWith('-chart'))
          .map((r) => ({ name: r.name, description: r.description || '' })),
      });
    }
    if (req.method === 'GET' && url.pathname === '/api/validate-name') {
      const verdict = await validateName(String(url.searchParams.get('name') || '').trim());
      return send(res, 200, verdict);
    }
    if (req.method === 'POST' && url.pathname === '/api/apps') {
      const body = await readBody(req);
      const result = await createApp({
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
  console.log(`portal listening on :${PORT} (forgejo: ${FORGEJO_URL}, org: ${APPS_ORG})`);
});
