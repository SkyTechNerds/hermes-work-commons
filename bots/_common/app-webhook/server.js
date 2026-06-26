#!/usr/bin/env node
/**
 * hermes-work-app — GitHub-App-Webhook-Handler.
 *
 * GitHub  --https-->  web.skycryer.com (Apache-Proxy)  -->  dieser Handler (113:PORT)
 *
 * Auf `pull_request` (opened/reopened/synchronize/ready_for_review) holt er ein
 * Installation-Access-Token (App-JWT -> /app/installations/<id>/access_tokens) und
 * fährt damit die UNVERÄNDERTEN bots/<project>/test-pr.sh + _common/ai-review.sh.
 * Posts erscheinen dann als `hermes-work[bot]` (App-Identität) statt unter einem PAT-User.
 *
 * Läuft PARALLEL zum Discord-Listener: gleiche Scripts, nur die Token-Quelle ist das
 * Installation-Token (via GH_TOKEN/GITHUB_TOKEN-Env, das load-token.sh/pr-diff.sh/
 * review-comment.sh respektieren). Eigener REPO_DIR, um Workdir-Races zu vermeiden.
 *
 * Secrets in /etc/hermes-work-app/: app-id, private-key.pem, webhook-secret (chmod 600).
 */
'use strict';
const http = require('node:http');
const https = require('node:https');
const crypto = require('node:crypto');
const fs = require('node:fs');
const path = require('node:path');
const { spawn } = require('node:child_process');

const CONF_DIR = process.env.HERMES_APP_CONF || '/etc/hermes-work-app';
const BOTS_DIR = process.env.HERMES_BOTS_DIR || '/opt/hermes-work-commons/bots';
const PORT = parseInt(process.env.PORT || '3956', 10);
const LOG = process.env.HERMES_APP_LOG || '/var/log/hermes-work-app.log';
const WORKROOT = process.env.HERMES_APP_WORKROOT || '/opt/hermes-app-workdir';

const APP_ID = fs.readFileSync(path.join(CONF_DIR, 'app-id'), 'utf8').trim();
const PRIVATE_KEY = fs.readFileSync(path.join(CONF_DIR, 'private-key.pem'), 'utf8');
const WEBHOOK_SECRET = fs.readFileSync(path.join(CONF_DIR, 'webhook-secret'), 'utf8').trim();

function log(msg) {
  const line = `${new Date().toISOString()} ${msg}\n`;
  process.stdout.write(line);
  try { fs.appendFileSync(LOG, line); } catch {}
}

function projectForRepo(full) {
  const name = (full || '').split('/')[1] || '';
  if (name === 'homeassistant-config') return 'ha';
  if (name === 'JUMO-Website-CMS') return 'jumo';
  return name; // z. B. ha-soft-presence
}

// --- GitHub-App-Auth -------------------------------------------------------

function b64url(buf) {
  return Buffer.from(buf).toString('base64')
    .replace(/=+$/, '').replace(/\+/g, '-').replace(/\//g, '_');
}

function makeAppJwt() {
  const now = Math.floor(Date.now() / 1000);
  const header = b64url(JSON.stringify({ alg: 'RS256', typ: 'JWT' }));
  const payload = b64url(JSON.stringify({ iat: now - 60, exp: now + 540, iss: APP_ID }));
  const data = `${header}.${payload}`;
  const sig = crypto.createSign('RSA-SHA256').update(data).sign(PRIVATE_KEY);
  return `${data}.${b64url(sig)}`;
}

function installationToken(installationId) {
  const jwt = makeAppJwt();
  return new Promise((resolve, reject) => {
    const req = https.request({
      host: 'api.github.com',
      path: `/app/installations/${installationId}/access_tokens`,
      method: 'POST',
      headers: {
        Authorization: `Bearer ${jwt}`,
        Accept: 'application/vnd.github+json',
        'User-Agent': 'hermes-work-app',
      },
    }, r => {
      let d = ''; r.on('data', c => d += c);
      r.on('end', () => {
        try {
          const j = JSON.parse(d);
          if (j.token) resolve(j.token);
          else reject(new Error(`no token (HTTP ${r.statusCode}): ${d.slice(0, 200)}`));
        } catch (e) { reject(e); }
      });
    });
    req.on('error', reject);
    req.end();
  });
}

// --- Script-Runner ---------------------------------------------------------

function run(script, args, token, project) {
  return new Promise((resolve) => {
    const env = {
      ...process.env,
      GH_TOKEN: token,
      GITHUB_TOKEN: token,
      REPO_DIR: path.join(WORKROOT, project),  // eigener Workdir (kein Listener-Race)
    };
    const p = spawn('bash', [script, ...args], { env, cwd: BOTS_DIR, timeout: 600000 });
    let out = '';
    p.stdout.on('data', d => out += d);
    p.stderr.on('data', d => out += d);
    p.on('close', code => resolve({ code, out }));
    p.on('error', () => resolve({ code: -1, out }));
  });
}

async function handlePullRequest(payload) {
  const repo = payload.repository.full_name;
  const pr = payload.number || (payload.pull_request && payload.pull_request.number);
  const prData = payload.pull_request || {};
  const branch = prData.head && prData.head.ref;
  const base = (prData.base && prData.base.ref) || 'main';
  const installationId = payload.installation && payload.installation.id;
  const project = projectForRepo(repo);

  // Gate: nur offene, nicht-gemergte PRs.
  if (prData.state !== 'open' || prData.merged) {
    log(`skip ${repo}#${pr}: state=${prData.state} merged=${prData.merged}`);
    return;
  }
  if (prData.draft) { log(`skip ${repo}#${pr}: draft`); return; }
  if (!installationId) { log(`skip ${repo}#${pr}: keine installation.id`); return; }
  if (!project || !branch) { log(`skip ${repo}#${pr}: project/branch fehlt`); return; }

  let token;
  try { token = await installationToken(installationId); }
  catch (e) { log(`token-fail ${repo}#${pr}: ${e.message}`); return; }

  log(`run ${repo}#${pr} (${branch} -> ${base}, project=${project})`);
  const test = await run(path.join(BOTS_DIR, project, 'test-pr.sh'),
    [String(pr), branch, base, 'collect'], token, project);
  log(`test ${repo}#${pr} exit ${test.code}: ${test.out.slice(-160).replace(/\n/g, ' ')}`);

  const review = await run(path.join(BOTS_DIR, '_common', 'ai-review.sh'),
    [repo, String(pr)], token, project);
  const fm = review.out.match(/AI-REVIEW: (\d+)/);
  log(`ai-review ${repo}#${pr}: ${fm ? fm[1] : '?'} findings (exit ${review.code})`);
}

// --- HTTP-Server -----------------------------------------------------------

function verify(sigHeader, body) {
  if (!sigHeader) return false;
  const expected = 'sha256=' + crypto.createHmac('sha256', WEBHOOK_SECRET).update(body).digest('hex');
  const a = Buffer.from(sigHeader);
  const b = Buffer.from(expected);
  return a.length === b.length && crypto.timingSafeEqual(a, b);
}

const server = http.createServer((req, res) => {
  if (req.method === 'GET' && req.url.endsWith('/health')) {
    res.writeHead(200, { 'Content-Type': 'text/plain' });
    return res.end('hermes-work-app ok\n');
  }
  if (req.method !== 'POST' || !req.url.endsWith('/webhook')) {
    res.writeHead(404); return res.end('not found\n');
  }
  const chunks = [];
  req.on('data', c => chunks.push(c));
  req.on('end', () => {
    const body = Buffer.concat(chunks);
    if (!verify(req.headers['x-hub-signature-256'], body)) {
      log('signature-FAIL'); res.writeHead(401); return res.end('bad signature\n');
    }
    const event = req.headers['x-github-event'];
    let payload;
    try { payload = JSON.parse(body.toString('utf8')); }
    catch { res.writeHead(400); return res.end('bad json\n'); }

    if (event === 'ping') { log('ping ok'); res.writeHead(200); return res.end('pong\n'); }

    // Sofort ack (GitHub-10s-Timeout), Arbeit asynchron.
    res.writeHead(202); res.end('accepted\n');

    if (event === 'pull_request' &&
        ['opened', 'reopened', 'synchronize', 'ready_for_review'].includes(payload.action)) {
      handlePullRequest(payload).catch(e => log(`handler-error: ${e.message}`));
    } else {
      log(`ignored event=${event} action=${payload.action || '-'}`);
    }
  });
});

server.listen(PORT, () => log(`hermes-work-app listening on :${PORT} (app-id ${APP_ID})`));
