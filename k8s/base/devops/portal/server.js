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

// The template convention (see k8s/templates/app-template): the literal tokens
// APP_NAME and DOMAIN, in both file content and file names. APP_NAME first, so
// APP_NAME.DOMAIN resolves to <name>.<domain>.
function substitute(text, name) {
  return text.split('APP_NAME').join(name).split('DOMAIN').join(DOMAIN);
}

// Optional add-ons: files the template keeps under optional/, copied into k8s/
// only when asked for. Anything else under optional/ never ships.
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
        'k8s/httproute.yaml attaches to the workload gateway\'s wildcard `apps` listener; ' +
        'external-dns creates the DNS record from the HTTPRoute and cert-manager serves the ' +
        'wildcard certificate (DNS-01). Nothing to configure per app — this is a check, after ' +
        'the first image is pushed. Exception: on UpCloud the `letsencrypt-dns01` ClusterIssuer ' +
        'is a manual Cloudflare setup; ask a platform admin if TLS fails there.',
    },
    {
      title: 'Review resource requests and limits',
      body:
        'k8s/deployment.yaml ships conservative defaults. Kyverno enforces that requests ' +
        'and limits exist, and the namespace quota caps the total.',
    },
  );
  for (const key of Object.keys(OPTIONS)) {
    if (options[key]) {
      issues.push({
        title: `Plan the move from dev-grade ${key} to a managed service`,
        body:
          `k8s/${key}.yaml runs a single in-namespace instance; its password is generated ` +
          'in-cluster by an External Secrets `Password` generator (nothing is committed). ' +
          'Fine for development — production data belongs on the managed ' +
          (key === 'postgres' ? 'PostgreSQL' : 'cache') +
          ' the platform provisions per cloud.',
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

  if (!NAME_RE.test(name || '')) {
    throw Object.assign(
      new Error('Name must be a DNS label: lowercase letters, digits and dashes, max 39 chars, starting with a letter.'),
      { status: 400 },
    );
  }

  // Fail before creating anything if the repo already exists.
  let exists = true;
  try { await forgejo('GET', `/repos/${APPS_ORG}/${name}`); } catch (e) {
    if (e.status === 404) exists = false; else throw e;
  }
  if (exists) {
    throw Object.assign(new Error(`Repository ${APPS_ORG}/${name} already exists.`), { status: 409 });
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
      path: substitute(dest, name),
      content: Buffer.from(substitute(raw, name), 'utf8').toString('base64'),
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

  // One commit with every file. The batch contents endpoint initialises an
  // empty repository, so no auto_init README to collide with the template's.
  await forgejo('POST', `/repos/${APPS_ORG}/${name}/contents`, {
    message: `Scaffold ${name} from ${TEMPLATES_ORG}/${template}`,
    files,
  });
  step('Files committed', `${files.length} files on main`);

  // CI activation — best-effort: the scaffold is complete without it, so a
  // Woodpecker hiccup must not fail the wizard. Falls back to a starter issue.
  let ciActivated = false;
  let wpRepo = null;
  if (CAN_ACTIVATE_CI) {
    try {
      wpRepo = await woodpeckerActivate(created.id);
      ciActivated = true;
      step('CI activated', 'repository enabled in Woodpecker (org registry secrets apply)');
    } catch (err) {
      console.error(`woodpecker activation for ${name}: ${err.message}`);
      step('CI activation failed', `${err.message} — left as a starter issue`);
    }
  }

  if (options.issues) {
    let count = 0;
    for (const issue of STARTER_ISSUES(name, options, ciActivated)) {
      await forgejo('POST', `/repos/${APPS_ORG}/${name}/issues`, issue);
      count += 1;
    }
    step('Starter issues created', `${count} work items`);
  }

  return {
    steps,
    repo: `https://git.${DOMAIN}/${APPS_ORG}/${name}`,
    issues: `https://git.${DOMAIN}/${APPS_ORG}/${name}/issues`,
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
        templates: (repos || []).map((r) => ({ name: r.name, description: r.description || '' })),
      });
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
