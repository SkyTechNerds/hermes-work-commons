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
const ALLOWED_OWNERS = ['SkyTechNerds', 'JUMO-GmbH-Co-KG', 'schimanski-antegma'];  // bei public: nur diese Orgs bedienen

// Laufende Pipeline-Laeufe je repo#pr. Der auto-Approve (Reply-/Mention-Pfad)
// darf NICHT entscheiden, waehrend ein Lauf noch laeuft: die Findings dieses
// Laufs sind dann noch nicht gepostet -> er saehe faelschlich 0 offene Threads
// und wuerde zu frueh approven (PR #375).
const RUNS_IN_FLIGHT = new Set();
// Wurde ein auto-Approve waehrend eines laufenden Pipeline-Laufs uebersprungen,
// muss er NACH dem Lauf nachgeholt werden — sonst geht eine Thread-Aufloesung,
// die mitten im Lauf passiert, verloren und der PR bleibt un-approved (PR #376).
const PENDING_REEVAL = new Set();
const PORT = parseInt(process.env.PORT || '3956', 10);
const LOG = process.env.HERMES_APP_LOG || '/var/log/hermes-work-app.log';
const WORKROOT = process.env.HERMES_APP_WORKROOT || '/opt/hermes-app-workdir';

const APP_ID = fs.readFileSync(path.join(CONF_DIR, 'app-id'), 'utf8').trim();
const PRIVATE_KEY = fs.readFileSync(path.join(CONF_DIR, 'private-key.pem'), 'utf8');
const WEBHOOK_SECRET = fs.readFileSync(path.join(CONF_DIR, 'webhook-secret'), 'utf8').trim();

// Discord-Sichtbarkeit: kompakte Status-Meldung nach jeder Verarbeitung (optional).
// Webhook-URL in /etc/hermes-work-app/discord-webhook (chmod 600); fehlt sie -> stiller no-op.
let DISCORD_WEBHOOK = '';
try { DISCORD_WEBHOOK = fs.readFileSync(path.join(CONF_DIR, 'discord-webhook'), 'utf8').trim(); } catch {}
function notifyDiscord(text) {
  if (!DISCORD_WEBHOOK) return;
  fetch(DISCORD_WEBHOOK, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ content: text.slice(0, 1900), username: 'CodeMole', allowed_mentions: { parse: [] } }),
  }).catch((e) => log(`discord-notify-fail: ${e.message}`));
}

function log(msg) {
  const line = `${new Date().toISOString()} ${msg}\n`;
  process.stdout.write(line);
  try { fs.appendFileSync(LOG, line); } catch {}
}

// Ref-Namen aus dem Webhook-Payload landen in git-/Script-Argumenten -> validieren
// (gleiche Regeln wie SAFE_BRANCH im Discord-Listener).
function validRef(ref) {
  return typeof ref === 'string' && ref.length > 0 && ref.length <= 200
    && /^[A-Za-z0-9._\/-]+$/.test(ref)
    && !ref.includes('..') && !ref.startsWith('-') && !ref.startsWith('/');
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
  if (!ALLOWED_OWNERS.includes((repo || '').split('/')[0])) { log(`skip ${repo}: owner nicht in Whitelist`); return; }
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
  if (!validRef(branch) || !validRef(base)) {
    log(`skip ${repo}#${pr}: ungültiger Ref-Name (branch/base)`); return;
  }
  if (!/^[A-Za-z0-9._-]+$/.test(project)) {
    log(`skip ${repo}#${pr}: ungültiger Projekt-Name`); return;
  }

  let token;
  try { token = await installationToken(installationId); }
  catch (e) { log(`token-fail ${repo}#${pr}: ${e.message}`); return; }

  log(`run ${repo}#${pr} (${branch} -> ${base}, project=${project})`);
  const flightKey = `${repo}#${pr}`;
  RUNS_IN_FLIGHT.add(flightKey);
  try {
  const test = await run(path.join(BOTS_DIR, '_common', 'run-checks.sh'),
    [repo, String(pr), branch, base, 'post'], token, project);
  log(`test ${repo}#${pr} exit ${test.code}: ${test.out.slice(-160).replace(/\n/g, ' ')}`);

  const review = await run(path.join(BOTS_DIR, '_common', 'ai-review.sh'),
    [repo, String(pr)], token, project);
  const fm = review.out.match(/AI-REVIEW: (\d+)/);
  log(`ai-review ${repo}#${pr}: ${fm ? fm[1] : '?'} findings (exit ${review.code})`);

  // page-audit (a11y/Semantik/Timing, Zwei-Pass) — no-op ohne page-audit-Config in .codemole.yml
  const audit = await run(path.join(BOTS_DIR, '_common', 'page-audit', 'audit.sh'),
    [repo, String(pr), branch, base], token, project);
  const am = audit.out.match(/PAGE-AUDIT: (\d+|nicht konfiguriert)/);
  log(`page-audit ${repo}#${pr}: ${am ? am[1] : '?'} (exit ${audit.code})`);

  const passC = (test.out.match(/✅/g) || []).length;
  const failC = (test.out.match(/❌/g) || []).length;
  const reviewErr = review.code !== 0 || /AI-REVIEW-ERROR/.test(review.out);
  const reviewSkip = /kein Diff|per ignore ausgenommen/.test(review.out);
  const now = new Date().toLocaleTimeString('de-DE', { timeZone: 'Europe/Berlin', hour: '2-digit', minute: '2-digit' });
  const runnerFail = /run-checks:\s/.test(test.out) || /run\.js fehlt/.test(test.out);
  const testLine = `🧪 Tests: ${passC}✅ ${failC}❌${runnerFail ? ' ⚠️ Runner-Fehler' : ''}`;
  let reviewLine;
  if (reviewErr) {
    const em = review.out.match(/AI-REVIEW-ERROR:\s*([^\n]+)/);
    const reason = em ? em[1].slice(0, 90) : `Fehler (exit ${review.code})`;
    reviewLine = `🔍 Review: ⚠️ FEHLGESCHLAGEN — ${reason}`;
  } else if (reviewSkip) {
    reviewLine = `🔍 Review: ⏭️ übersprungen (kein Diff)`;
  } else {
    const n = fm ? fm[1] : '0';
    reviewLine = `🔍 Review: ✅ fertig — ${n === '0' ? 'sauber, keine Findings' : n + ' Finding(s)'}`;
  }
  const auditLine = (am && /^\d+$/.test(am[1]) && am[1] !== '0') ? `\n🔎 Audit: ${am[1]} neue Finding(s)` : '';
  const findingsN = fm ? parseInt(fm[1], 10) : null;
  const auditN = (am && /^\d+$/.test(am[1])) ? parseInt(am[1], 10) : 0;
  const clean = !runnerFail && failC === 0 && !reviewErr && !reviewSkip && findingsN === 0 && auditN === 0;
  await run(path.join(BOTS_DIR, '_common', 'pr-approve.sh'),
    [repo, String(pr), clean ? 'approve' : 'dismiss',
     clean ? 'Alle Checks bestanden, KI-Review ohne Findings. — CodeMole'
           : 'Nicht mehr sauber (Findings oder fehlgeschlagene Checks) — Approve zurückgezogen.'],
    token, project);
  if (reviewErr || runnerFail) {
    const head = reviewErr ? 'CODE-REVIEW FEHLGESCHLAGEN' : 'TEST-RUNNER FEHLGESCHLAGEN';
    const detail = reviewErr ? reviewLine.replace('🔍 Review: ⚠️ FEHLGESCHLAGEN — ', '') : 'run-checks brach ab (Clone/Fetch/Checkout/Lock?)';
    notifyDiscord(`🚨🚨 **${head}** 🚨🚨\n**${repo}#${pr}** · \`${branch}\` → \`${base}\` · ${now}\n❌ ${detail}\n${testLine}${auditLine}\n<https://github.com/${repo}/pull/${pr}>`);
  } else {
    notifyDiscord(`🦫 **${repo}#${pr}** · \`${branch}\` → \`${base}\` · ${now}\n${testLine}\n${reviewLine}${auditLine}\n<https://github.com/${repo}/pull/${pr}>`);
  }
  } finally {
    RUNS_IN_FLIGHT.delete(flightKey);
    if (PENDING_REEVAL.delete(flightKey)) {
      const _re = await run(path.join(BOTS_DIR, '_common', 'pr-approve.sh'),
        [repo, String(pr), 'auto'], token, project);
      log(`auto-approve ${flightKey}: nachgeholt nach Lauf — ${(_re.out || '').slice(-160).replace(/\n/g, ' ')} [exit ${_re.code}]`);
    }
  }
}

// Antwortet auf Replies zu eigenen Inline-Findings (pull_request_review_comment).
async function handleReviewComment(payload) {
  const c = payload.comment || {};
  const repo = payload.repository.full_name;
  if (!ALLOWED_OWNERS.includes((repo || '').split('/')[0])) { log(`skip ${repo}: owner nicht in Whitelist`); return; }
  const pr = payload.pull_request && payload.pull_request.number;
  const installationId = payload.installation && payload.installation.id;

  if (!c.in_reply_to_id) { log(`skip reply ${repo}#${pr}: kein Reply (Top-Level)`); return; }
  if (c.user && c.user.type === 'Bot') { log(`skip reply ${repo}#${pr}: Bot-Autor (Loop-Schutz)`); return; }
  if (!installationId || !pr) return;

  let token;
  try { token = await installationToken(installationId); }
  catch (e) { log(`reply token-fail ${repo}#${pr}: ${e.message}`); return; }

  log(`reply ${repo}#${pr} on comment ${c.id} (-> ${c.in_reply_to_id})`);
  const out = await run(path.join(BOTS_DIR, '_common', 'ai-reply.sh'),
    [repo, String(pr), String(c.id)], token, projectForRepo(repo));
  log(`ai-reply ${repo}#${pr}: ${out.out.slice(-140).replace(/\n/g, ' ')}`);
  if (/geantwortet/.test(out.out)) notifyDiscord(`\ud83e\uddab **${repo}#${pr}** \u00b7 auf Review-Reply geantwortet\n<https://github.com/${repo}/pull/${pr}>`);
  if (RUNS_IN_FLIGHT.has(`${repo}#${pr}`)) {
    log(`auto-approve ${repo}#${pr}: uebersprungen (Pipeline-Lauf aktiv) — wird nachgeholt`);
    PENDING_REEVAL.add(`${repo}#${pr}`);
  } else {
    { const _ap = await run(path.join(BOTS_DIR, '_common', 'pr-approve.sh'), [repo, String(pr), 'auto'], token, projectForRepo(repo)); log(`auto-approve ${repo}#${pr}: ${(_ap.out||'').slice(-160).replace(/\n/g,' ')} [exit ${_ap.code}]`); }
  }
}

// Q&A auf Top-Level-PR-Kommentare: antwortet NUR bei Mention @the-codemole
// (sonst würde der Bot in jede menschliche Unterhaltung grätschen).
async function handleIssueComment(payload) {
  const repo = payload.repository.full_name;
  if (!ALLOWED_OWNERS.includes((repo || '').split('/')[0])) { log(`skip ${repo}: owner nicht in Whitelist`); return; }
  const c = payload.comment || {};
  const pr = payload.issue && payload.issue.number;
  const installationId = payload.installation && payload.installation.id;
  if (!pr || !installationId) return;
  if (c.user && c.user.type === 'Bot') { log(`skip comment ${repo}#${pr}: Bot-Autor (Loop-Schutz)`); return; }
  if (!/@the-codemole/i.test(c.body || '')) { log(`skip comment ${repo}#${pr}: keine Mention`); return; }

  let token;
  try { token = await installationToken(installationId); }
  catch (e) { log(`comment token-fail ${repo}#${pr}: ${e.message}`); return; }

  log(`comment ${repo}#${pr}: Mention von ${c.user && c.user.login} (comment ${c.id})`);
  const out = await run(path.join(BOTS_DIR, '_common', 'ai-comment.sh'),
    [repo, String(pr), String(c.id)], token, projectForRepo(repo));
  log(`ai-comment ${repo}#${pr}: ${out.out.slice(-120).replace(/\n/g, ' ')}`);
  if (/geantwortet/.test(out.out)) notifyDiscord(`\ud83e\uddab **${repo}#${pr}** \u00b7 Frage per Mention beantwortet\n<https://github.com/${repo}/pull/${pr}>`);
  if (RUNS_IN_FLIGHT.has(`${repo}#${pr}`)) {
    log(`auto-approve ${repo}#${pr}: uebersprungen (Pipeline-Lauf aktiv) — wird nachgeholt`);
    PENDING_REEVAL.add(`${repo}#${pr}`);
  } else {
    { const _ap = await run(path.join(BOTS_DIR, '_common', 'pr-approve.sh'), [repo, String(pr), 'auto'], token, projectForRepo(repo)); log(`auto-approve ${repo}#${pr}: ${(_ap.out||'').slice(-160).replace(/\n/g,' ')} [exit ${_ap.code}]`); }
  }
}

// Fremde Installation (Org nicht in ALLOWED_OWNERS) sofort wieder entfernen.
// installation-Events liefert GitHub automatisch (kein Event-Abo noetig).
// So bleibt die App zwar public/installierbar, aber nur die Whitelist-Orgs behalten sie.
async function handleInstallation(payload) {
  const inst = payload.installation || {};
  const owner = (inst.account && inst.account.login) || '';
  const id = inst.id;
  if (ALLOWED_OWNERS.includes(owner)) { log(`installation ${owner} (#${id}): erlaubt`); return; }
  const jwt = makeAppJwt();
  await new Promise((resolve) => {
    const req = https.request({
      host: 'api.github.com', path: `/app/installations/${id}`, method: 'DELETE',
      headers: { Authorization: `Bearer ${jwt}`, Accept: 'application/vnd.github+json', 'User-Agent': 'hermes-work-app' },
    }, r => { r.on('data', () => {}); r.on('end', () => { log(`installation ${owner} (#${id}): NICHT in Whitelist -> deinstalliert (HTTP ${r.statusCode})`); resolve(); }); });
    req.on('error', (e) => { log(`installation-delete-fail ${owner}: ${e.message}`); resolve(); });
    req.end();
  });
  notifyDiscord(`\ud83d\udeab Fremde Installation abgelehnt: **${owner}** (nicht in Whitelist) \u2014 automatisch deinstalliert.`);
}

// Lighthouse on-demand: Label `lighthouse` an den PR → schwerer Zwei-Pass-Lauf,
// Ergebnis als eigener Kommentar. Läuft bewusst NICHT bei jedem Push (zu langsam).
async function handleLighthouse(payload) {
  const repo = payload.repository.full_name;
  if (!ALLOWED_OWNERS.includes((repo || '').split('/')[0])) { log(`skip ${repo}: owner nicht in Whitelist`); return; }
  const prData = payload.pull_request || {};
  const pr = prData.number;
  const branch = prData.head && prData.head.ref;
  const base = (prData.base && prData.base.ref) || 'main';
  const installationId = payload.installation && payload.installation.id;
  if (prData.state !== 'open' || !pr || !branch || !installationId) return;

  let token;
  try { token = await installationToken(installationId); }
  catch (e) { log(`lighthouse token-fail ${repo}#${pr}: ${e.message}`); return; }

  log(`lighthouse ${repo}#${pr} (Label-Trigger, ${branch} vs ${base})`);
  const out = await run(path.join(BOTS_DIR, '_common', 'page-audit', 'lighthouse.sh'),
    [repo, String(pr), branch, base], token, projectForRepo(repo));
  log(`lighthouse ${repo}#${pr}: ${out.out.slice(-120).replace(/\n/g, ' ')}`);
  if (/LIGHTHOUSE: fertig/.test(out.out)) notifyDiscord(`\u26a1 **${repo}#${pr}** \u00b7 Lighthouse-Lauf fertig (Label-Trigger)\n<https://github.com/${repo}/pull/${pr}>`);
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
  // Body-Limit VOR der Signaturprüfung: PR-Payloads sind klein; unbegrenztes
  // Sammeln wäre ein Memory-DoS am öffentlichen Endpoint.
  const MAX_BODY = 2 * 1024 * 1024;
  const chunks = [];
  let received = 0;
  let tooBig = false;
  req.on('data', c => {
    received += c.length;
    if (received > MAX_BODY) {
      if (!tooBig) { tooBig = true; log(`payload too large (${received}b), dropping`); req.destroy(); }
      return;
    }
    chunks.push(c);
  });
  req.on('end', () => {
    if (tooBig) return;
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
    } else if (event === 'pull_request' && payload.action === 'labeled' &&
               payload.label && payload.label.name === 'lighthouse') {
      handleLighthouse(payload).catch(e => log(`lighthouse-error: ${e.message}`));
    } else if (event === 'pull_request_review_comment' && payload.action === 'created') {
      handleReviewComment(payload).catch(e => log(`reply-error: ${e.message}`));
    } else if (event === 'issue_comment' && payload.action === 'created' &&
               payload.issue && payload.issue.pull_request) {
      handleIssueComment(payload).catch(e => log(`comment-error: ${e.message}`));
    } else if (event === 'installation' && payload.action === 'created') {
      handleInstallation(payload).catch(e => log(`installation-error: ${e.message}`));
    } else {
      log(`ignored event=${event} action=${payload.action || '-'}`);
    }
  });
});

server.listen(PORT, () => log(`hermes-work-app listening on :${PORT} (app-id ${APP_ID})`));
