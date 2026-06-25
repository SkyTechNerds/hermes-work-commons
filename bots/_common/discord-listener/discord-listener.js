#!/usr/bin/env node
/**
 * Hermes-Work Discord-Listener
 *
 * Listens on configured Discord channels for TEST_REQUEST / PR_READY /
 * PR_COMMENT messages, parses the repo + PR number from the footer, and
 * invokes `bots/<project>/test-pr.sh` to run the project-specific tests.
 * Posts the result back as a PR comment via gh api.
 *
 * Architecture:
 *   Discord Channel  →  bot listener  →  bots/<project>/test-pr.sh  →  GitHub PR comment
 *                                              ↓
 *                                         (project-specific checks)
 *
 * Channel → Repo mapping in discord-listener-config.json.
 *
 * Trigger messages (footer text, case-insensitive):
 *   TEST_REQUEST branch=<x> pr=<n>      → run tests, post report
 *   JUMO_TEST_REQUEST branch=<x> pr=<n> → run tests, post report (JUMO only)
 *   retest                              → re-run last test for this PR
 *   snapshots update                    → call test-pr.sh with mode=update-snapshots
 *
 * Run via systemd: `systemctl start hermes-discord-listener`
 */

'use strict';

const { Client, GatewayIntentBits, Events, EmbedBuilder } = require('discord.js');
const { spawn, execSync } = require('node:child_process');
const fs = require('node:fs');
const path = require('node:path');

// --- Config ----------------------------------------------------------------

const CONFIG_PATH = process.env.HERMES_LISTENER_CONFIG
  || path.join(__dirname, 'discord-listener-config.json');
const TOKEN_PATH = process.env.HERMES_DISCORD_TOKEN
  || '/root/.config/discord-bot-token.txt';
const LOG_PATH = process.env.HERMES_LISTENER_LOG
  || '/var/log/hermes-discord-listener.log';
const BOTS_DIR = process.env.HERMES_BOTS_DIR
  || '/opt/hermes-work-commons/bots';
const GITHUB_TOKEN_PATH = process.env.HERMES_GH_TOKEN
  || '/root/.config/gh-token-raw.txt';

let config;
try {
  config = JSON.parse(fs.readFileSync(CONFIG_PATH, 'utf8'));
} catch (e) {
  log(`FATAL: cannot read config ${CONFIG_PATH}: ${e.message}`);
  process.exit(1);
}

// channels: Map<channelId, {repo, name, project}>
const channels = new Map();
for (const ch of config.channels) {
  channels.set(ch.id, ch);
}

// --- Logging ---------------------------------------------------------------

function log(msg) {
  const line = `${new Date().toISOString()} ${msg}\n`;
  process.stdout.write(line);
  try { fs.appendFileSync(LOG_PATH, line); } catch {}
}

// --- Token Loading --------------------------------------------------------

let discordToken;

// Per-channel GitHub tokens: Map<channelId, string>. Loaded lazily on first
// trigger per channel so a single broken token file does not prevent the
// other channels from working.
const githubTokens = new Map();

function loadDiscordToken() {
  try {
    const stat = fs.statSync(TOKEN_PATH);
    if ((stat.mode & 0o077) !== 0) {
      throw new Error(`token file ${TOKEN_PATH} has permissive mode ${(stat.mode & 0o777).toString(8)} (need 600)`);
    }
    discordToken = fs.readFileSync(TOKEN_PATH, 'utf8').trim();
    if (!discordToken) throw new Error('empty file');
    log(`discord token loaded (${discordToken.length} chars)`);
  } catch (e) {
    log(`FATAL: cannot read discord token from ${TOKEN_PATH}: ${e.message}`);
    process.exit(1);
  }
}

/**
 * Load and cache the GitHub token for a given channel. Each channel declares
 * its own token_file in the config (mapped from a BW vault item at deploy
 * time). Returns the token string or throws.
 */
function loadGithubTokenForChannel(channelCfg) {
  const cid = channelCfg && channelCfg.id;
  if (!cid) throw new Error('channelCfg has no id');
  if (githubTokens.has(cid)) return githubTokens.get(cid);

  const tokFile = channelCfg.github && channelCfg.github.token_file;
  if (!tokFile) throw new Error(`channel ${cid} has no github.token_file configured`);

  const stat = fs.statSync(tokFile);
  // Refuse world-readable / group-readable token files (service runs as root).
  if ((stat.mode & 0o077) !== 0) {
    throw new Error(`token file ${tokFile} has permissive mode ${(stat.mode & 0o777).toString(8)} (need 600)`);
  }
  const tok = fs.readFileSync(tokFile, 'utf8').trim();
  if (!tok) throw new Error(`empty token file ${tokFile}`);
  log(`github token loaded for channel ${channelCfg.name || cid} (${tok.length} chars from ${tokFile})`);
  githubTokens.set(cid, tok);
  return tok;
}

// --- Message Parsing -------------------------------------------------------

// Footer format: "TEST_REQUEST branch=wcms-1234 pr=440 repo=JUMO-GmbH-Co-KG/JUMO-Website-CMS"
// Also accepts PR_READY and PR_COMMENT as synonymous triggers (advertised in
// trigger_pattern docs and SETUP.md), and JUMO_TEST_REQUEST as a project-scoped
// variant.
// A test trigger is TEST_REQUEST/PR_READY (NOT *_COMMENT -> that goes to Nero).
// Fields branch=/pr=/repo= are parsed order-independently (composite action
// posts repo= pr= branch=; JUMO inline posts branch= pr=). MUST carry pr=+branch=.
const TRIGGER_PATTERN = /^(?:JUMO_)?(?:TEST_REQUEST|PR_READY)\b/i;

function parseTestRequest(content) {
  if (!TRIGGER_PATTERN.test(content)) return null;
  if (/^(?:JUMO_)?(?:TEST_REQUEST|PR_READY)_COMMENT/i.test(content)) return null;
  const prM = content.match(/\bpr=(\d+)/i);
  const brM = content.match(/\bbranch=(\S+)/i);
  const rpM = content.match(/\brepo=(\S+)/i);
  if (!prM || !brM) return null;
  const isJumo = /^JUMO_/i.test(content);
  return {
    prefix: isJumo ? 'JUMO_TEST_REQUEST' : 'TEST_REQUEST',
    branch: brM[1],
    pr: prM[1],
    repo: rpM ? rpM[1] : null,
  };
}

// --- Input Validation ------------------------------------------------------

// Whitelist of characters safe for a git branch name. Used to reject shell-meta
// and path-traversal attempts in Discord messages before they reach a shell.
const SAFE_BRANCH = /^[A-Za-z0-9._\/-]+$/;

function validateBranch(branch) {
  if (!branch || branch.length > 200) return false;
  if (branch.includes('..')) return false;       // path traversal
  if (branch.startsWith('-')) return false;      // looks like a CLI flag
  if (branch.startsWith('/') || branch.includes('\0')) return false;
  return SAFE_BRANCH.test(branch);
}

function validatePr(pr) {
  const n = Number(pr);
  return Number.isInteger(n) && n > 0 && n < 10_000_000;
}

// --- Bot Identification ----------------------------------------------------

// Resolve the project directory (under BOTS_DIR) for a repo. The mapping
// MUST come from the channel config — repo names do not always match
// project directory names (e.g. JUMO-GmbH-Co-KG/JUMO-Website-CMS → "jumo").
// `channelCfg` is the only authoritative source; this function is a
// last-resort fallback used only when channelCfg.project is missing.
function projectForRepo(repoFullName) {
  const parts = repoFullName.split('/');
  if (parts.length !== 2) return null;
  const [owner, name] = parts;
  // Reject anything that could escape BOTS_DIR via path traversal.
  if (!/^[A-Za-z0-9._-]+$/.test(owner) || !/^[A-Za-z0-9._-]+$/.test(name)) {
    return null;
  }
  if (name === 'JUMO-Website-CMS') return 'jumo';
  if (name === 'homeassistant-config') return 'ha';
  return name;  // for SkyTechNerds/ha-soft-presence etc.
}

function resolveProject(channelCfg, repoFullName) {
  // Shared channel: derive project from repo= in the message (authoritative).
  // Per-repo channel: fall back to the configured project name.
  const fromRepo = repoFullName ? projectForRepo(repoFullName) : null;
  if (fromRepo) return fromRepo;
  if (channelCfg && typeof channelCfg.project === 'string'
      && /^[A-Za-z0-9._-]+$/.test(channelCfg.project)) {
    return channelCfg.project;
  }
  return null;
}

// --- Test Invocation -------------------------------------------------------

function runTest(repoFullName, pr, branch, project, mode = 'collect') {
  // Defensive: project was already validated by resolveProject, but assert
  // again here in case runTest is called from a future code path that
  // forgets to validate.
  if (!project || !/^[A-Za-z0-9._-]+$/.test(project)) {
    throw new Error(`refusing to run: invalid project name "${project}"`);
  }
  const script = path.join(BOTS_DIR, project, 'test-pr.sh');
  // Resolve and verify the script lives under BOTS_DIR (no symlink escape).
  const realBots = fs.realpathSync(BOTS_DIR);
  const realScript = fs.realpathSync(script);
  if (!realScript.startsWith(realBots + path.sep)) {
    throw new Error(`test script ${realScript} is outside BOTS_DIR ${realBots}`);
  }
  if (!fs.existsSync(realScript)) {
    throw new Error(`No test script at ${realScript}`);
  }
  // JUMO wrapper expects <branch> <pr> dev; HA wrappers expect <pr> <branch> main.
  const args = (project === 'jumo')
    ? [realScript, branch, String(pr), 'dev', mode]
    : [realScript, String(pr), branch, 'main', mode];
  log(`running ${realScript} (${project}) ${args.slice(1).join(' ')}`);
  const env = { ...process.env, REPO: repoFullName, PATH: process.env.PATH };
  const result = spawn('bash', args, {
    env,
    cwd: BOTS_DIR,
    timeout: 600_000,  // 10 min
  });
  return new Promise((resolve, reject) => {
    let stdout = '', stderr = '';
    result.stdout.on('data', d => stdout += d);
    result.stderr.on('data', d => stderr += d);
    result.on('close', code => {
      log(`test exit ${code}: ${stdout.slice(-200)}`);
      if (code === 0) resolve({ stdout, stderr });
      else reject(new Error(`test exit ${code}: ${stderr.slice(-500)}`));
    });
  });
}

// --- GitHub PR Comment Posting ---------------------------------------------

/**
 * Post a comment to a GitHub PR using the channel-specific token. Resolves
 * with {ok, status, body} so the caller can react to GitHub-side failures
 * instead of reporting success to Discord when the PR comment never landed.
 */
async function postPRComment(channelCfg, repoFullName, pr, body) {
  let token;
  try {
    token = loadGithubTokenForChannel(channelCfg);
  } catch (e) {
    log(`skipping PR comment for ${repoFullName}#${pr}: ${e.message}`);
    return { ok: false, status: 0, body: `token-load: ${e.message}` };
  }
  const url = `https://api.github.com/repos/${repoFullName}/issues/${pr}/comments`;
  const payload = JSON.stringify({ body });
  return new Promise((resolve) => {
    const proc = spawn('curl', [
      '-sS', '-w', '\n__HTTP_STATUS__:%{http_code}',
      '-X', 'POST', url,
      '-H', `Authorization: token ${token}`,
      '-H', 'Content-Type: application/json',
      '-H', 'User-Agent: hermes-discord-listener',
      '-d', payload,
    ]);
    let out = '', err = '';
    proc.stdout.on('data', d => out += d);
    proc.stderr.on('data', d => err += d);
    proc.on('close', code => {
      const m = out.match(/__HTTP_STATUS__:(\d+)\s*$/);
      const status = m ? parseInt(m[1], 10) : 0;
      const bodyOnly = out.replace(/__HTTP_STATUS__:\d+\s*$/, '');
      if (code !== 0) {
        log(`PR comment curl exit ${code}: ${err.slice(0, 200)}`);
        return resolve({ ok: false, status, body: `curl exit ${code}: ${err.slice(0, 500)}` });
      }
      if (status < 200 || status >= 300) {
        log(`PR comment HTTP ${status}: ${bodyOnly.slice(0, 200)}`);
        return resolve({ ok: false, status, body: bodyOnly });
      }
      log(`PR comment OK (HTTP ${status}) for ${repoFullName}#${pr}`);
      resolve({ ok: true, status, body: bodyOnly });
    });
  });
}

// --- Main Handler ----------------------------------------------------------

async function handleTestRequest(message, channelCfg, parsed) {
  const { pr, branch, prefix } = parsed;
  // Per-repo channel: repo is bound to the channel. Shared channel: repo comes
  // from the (trusted-webhook) message, whitelisted via allowed_repos so a
  // spoofed Discord message cannot run an arbitrary repo.
  let repo = channelCfg && channelCfg.repo;
  if (channelCfg && channelCfg.shared) {
    repo = parsed.repo || repo;
    const allow = Array.isArray(channelCfg.allowed_repos) ? channelCfg.allowed_repos : [];
    if (!repo || (allow.length && !allow.includes(repo))) {
      return;  // not the listener's repo (e.g. JUMO) -> Nero handles it
    }
  }

  // Prefix must match what this channel declares. e.g. a TEST_REQUEST in the
  // JUMO channel (which expects JUMO_TEST_REQUEST) must be rejected so users
  // cannot accidentally fire the wrong project's runner.
  if (!channelCfg || !repo) {
    return message.reply('❌ Channel not configured for test runs.');
  }
  if (!channelCfg.shared) {
    const expectedPrefix = channelCfg.trigger_prefix || 'TEST_REQUEST';
    if (prefix !== expectedPrefix) {
      return message.reply(`❌ Wrong trigger for this channel: expected ${expectedPrefix}, got ${prefix}.`);
    }
  }

  // Validate inputs BEFORE passing them to a shell-spawning script.
  if (!validateBranch(branch)) {
    return message.reply(`❌ Invalid branch name: \`${branch.slice(0, 80)}\``);
  }
  if (!validatePr(pr)) {
    return message.reply(`❌ Invalid PR number: \`${pr}\``);
  }

  const project = resolveProject(channelCfg, repo);
  if (!project) {
    return message.reply(`❌ Cannot resolve project for ${repo}.`);
  }

  // Acknowledge in Discord
  const ack = await message.reply(`🔄 Running tests for ${repo}#${pr} (${branch})…`);
  log(`ack posted for ${repo}#${pr}`);

  try {
    const { stdout } = await runTest(repo, pr, branch, project);
    // The project test-pr.sh self-posts the PR comment AND self-resolves its
    // own GitHub token (load-token.sh). The listener does NOT post again.
    log(`done ${repo}#${pr}: ${stdout.slice(-160)}`);
    await ack.edit(`✅ Tests done for ${repo}#${pr} — Report auf dem PR gepostet`);
    // Claude-Logik-Review (separat, $0 via claude -p) — postet Inline-Findings
    try {
      const out = await new Promise((res) => {
        const p = spawn('bash', [path.join(BOTS_DIR, '_common', 'ai-review.sh'), repo, String(pr)], { timeout: 180000 });
        let o = '';
        p.stdout.on('data', (d) => { o += d; });
        p.stderr.on('data', (d) => { o += d; });
        p.on('close', () => res(o));
        p.on('error', () => res(''));
      });
      const fm = out.match(/AI-REVIEW: (\d+)/);
      const nf = fm ? fm[1] : '0';
      log(`ai-review ${repo}#${pr}: ${nf} findings`);
      if (nf !== '0') await ack.edit(`✅ ${repo}#${pr} — Tests + Review (${nf} Hinweise) gepostet`);
    } catch (e) { log(`ai-review error ${repo}#${pr}: ${e.message}`); }
  } catch (e) {
    await ack.edit(`❌ Test failed: ${e.message.slice(0, 500)}`);
    log(`FAIL ${repo}#${pr}: ${e.message}`);
  }
}

// --- Client ----------------------------------------------------------------

const client = new Client({
  intents: [
    GatewayIntentBits.Guilds,
    GatewayIntentBits.GuildMessages,
    GatewayIntentBits.MessageContent,
  ],
});

client.once(Events.ClientReady, c => {
  log(`logged in as ${c.user.tag} (id=${c.user.id})`);
  log(`watching ${channels.size} channels: ${[...channels.values()].map(c => c.name).join(', ')}`);
});

client.on(Events.MessageCreate, async message => {
  // Ignore self + bots
  if (message.author.bot && !message.webhookId) return;  // allow webhook triggers; skip real bots/self

  const channelCfg = channels.get(message.channelId);
  if (!channelCfg) return;  // not a watched channel

  const content = message.content.trim();

  // Command: retest → re-run last test for the latest PR in this channel
  if (content === '!retest' || content === 'retest') {
    log(`retest in ${message.channel.name}`);
    // Find last TEST_REQUEST in channel
    try {
      const recent = await message.channel.messages.fetch({ limit: 20 });
      const last = recent.find(m => TRIGGER_PATTERN.test(m.content));
      if (last) {
        const parsed = parseTestRequest(last.content);
        if (parsed) return handleTestRequest(last, channelCfg, parsed);
      }
      await message.reply('❌ No recent TEST_REQUEST found in this channel.');
    } catch (e) {
      log(`retest error: ${e.message}`);
    }
    return;
  }

  // Command: status → report listener health
  if (content === '!status' || content === 'status') {
    return message.reply(`✅ Hermes-Work Listener v${config.version} — watching ${channels.size} channels. Last message: ${new Date().toISOString()}`);
  }

  // Main trigger: TEST_REQUEST branch=X pr=Y
  const parsed = parseTestRequest(content);
  if (!parsed) return;

  await handleTestRequest(message, channelCfg, parsed);
});

client.on(Events.Error, err => log(`client error: ${err.message}`));

// --- Startup ---------------------------------------------------------------

loadDiscordToken();
log('connecting to Discord...');
client.login(discordToken);

// Graceful shutdown
process.on('SIGINT', () => { log('SIGINT, shutting down'); client.destroy(); process.exit(0); });
process.on('SIGTERM', () => { log('SIGTERM, shutting down'); client.destroy(); process.exit(0); });