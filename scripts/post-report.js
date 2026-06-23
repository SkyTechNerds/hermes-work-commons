// Postet QA-Report als PR-Kommentar — JUMO-konsistentes Format
module.exports = async ({ github, context }) => {
  const statusOf = (id) => {
    return process.env[`STEP_${id.toUpperCase()}_STATUS`] || 'skip';
  };
  const checks = ['secrets', 'diff', 'lint', 'paths', 'reviews', 'code-review'];
  const labels = {
    secrets: 'Secret-Scan',
    diff: 'Diff-Size',
    lint: 'Lint',
    paths: 'Path-Convention',
    reviews: 'Review-Coverage',
    'code-review': 'Code-Review'
  };
  const icon = { pass: '✅', fail: '❌', warn: '⚠️', skip: '⏭️' };

  const rows = checks.map(c => {
    const s = statusOf(c);
    return `| ${icon[s] || '❔'} | **${labels[c]}** | ${s} |`;
  }).join('\n');

  const allGreen = checks.every(c => {
    const s = statusOf(c);
    return s === 'pass' || s === 'skip';
  });

  const pr = context.payload.pull_request;
  const body = [
    '## 🤖 hermes-work QA Report',
    '',
    `PR #${pr.number} · \`${pr.head.ref}\` → \`${context.payload.repository.default_branch || 'main'}\``,
    '',
    '| Status | Check | Result |',
    '|--------|-------|--------|',
    rows,
    '',
    allGreen ? '✅ **All checks green.**' : '⚠️ **Action required** — see failed checks.'
  ].join('\n');

  await github.rest.issues.createComment({
    issue_number: context.issue.number,
    owner: context.repo.owner,
    repo: context.repo.repo,
    body
  });
};
