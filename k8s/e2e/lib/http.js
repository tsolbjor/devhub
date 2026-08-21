// HTTP from inside the browser, not from Node.
//
// Playwright's request fixture issues its requests from the Node process, which
// resolves names through glibc. Chromium resolves *.localhost to loopback
// itself, per RFC 6761, and so does curl — which is why a local platform is
// reachable in a browser while `getaddrinfo` says the hostname does not exist.
// Going through the page keeps the suite working on a workstation whose hosts
// file has not caught up, and has a second benefit: the request carries exactly
// the cookies the service just set, so an API call tests the same session the
// user has.

// Same-origin fetch from the page. Navigates first if the page is somewhere
// else, because a cross-origin call would be judged by CORS rather than by the
// service.
async function apiFetch(page, url, { navigate = true } = {}) {
  const origin = new URL(url).origin;

  if (navigate && new URL(page.url()).origin !== origin) {
    await page.goto(origin, { waitUntil: 'domcontentloaded' });
  }

  return page.evaluate(async (target) => {
    const res = await fetch(target, { credentials: 'include' });
    const body = await res.text();
    return { status: res.status, body, contentType: res.headers.get('content-type') || '' };
  }, url);
}

// The same, parsed. Returns { status, json } with json = null when the response
// was not JSON — a service answering a login page to an API call is a common
// and informative failure, and swallowing it in a parse error hides it.
async function apiJson(page, url, options) {
  const res = await apiFetch(page, url, options);
  let json = null;
  try {
    json = JSON.parse(res.body);
  } catch {
    /* left null on purpose — the caller reports status and body */
  }
  return { ...res, json };
}

// Status of a URL without following redirects and without any session: what an
// anonymous visitor gets. Used for reachability and for asserting that a
// gateway policy is actually intercepting.
async function anonymousStatus(context, url) {
  const page = await context.newPage();
  try {
    const res = await page.goto(url, { waitUntil: 'domcontentloaded', timeout: 60_000 });
    return { status: res ? res.status() : 0, url: page.url() };
  } finally {
    await page.close();
  }
}

module.exports = { apiFetch, apiJson, anonymousStatus };
