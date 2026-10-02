import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { execFileSync, spawnSync } from 'node:child_process';
import crypto from 'node:crypto';
import { DOCUMENTS, validateConfig, loadConfig, projectPath } from '../../scripts/asdd/config.mjs';
import { apply, plan, check, judgeMultiReviewProbe } from '../../scripts/asdd/generate.mjs';

export const config = () => ({
  schemaVersion: 1, project: { name: 'お知らせ作成', purpose: '社外向け文章を確認して保存する', owner: '@example' },
  style: 'citizen', stage: 'poc', tools: ['claude', 'codex'], documents: ['MASTER'],
  features: { ace: false, retrospective: false, multiReview: false, hooks: false, ci: false },
  workflow: 'simple', decisions: [{ topic: '完成条件', status: 'agreed', value: '文章の事実と表現を確認する', reason: '利用者との合意' }], github: null,
});
const temporary = t => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'asdd-test-'));
  t.after(() => fs.rmSync(root, { recursive: true, force: true }));
  return root;
};
test('minimal project previews without writing; generates both hosts and is repeatable', t => {
  const root = temporary(t), selected = config();
  assert.equal(plan(root, selected).changes.length, 4);
  assert.deepEqual(fs.readdirSync(root), []);
  assert.equal(apply(root, selected).changed.length, 4);
  assert.equal(apply(root, selected).changed.length, 0);
  assert.deepEqual(loadConfig(root), selected);
  assert.equal(check(root).initialized, true);
  assert.equal(check(root).releaseReady, 'not-assessed');
  assert.equal(check(root).capabilities.ace, 'disabled');
  assert.match(fs.readFileSync(path.join(root, 'AGENTS.md'), 'utf8'), /docs\/MASTER.md/);
});
test('conflicting hand edits block replacement with no partial writes', t => {
  const root = temporary(t), selected = config();
  apply(root, selected);
  const master = path.join(root, 'docs/MASTER.md');
  fs.writeFileSync(master, fs.readFileSync(master, 'utf8').replace('段階: poc', '段階: 利用者の追記'));
  const before = fs.readFileSync(path.join(root, '.asdd/config.json'), 'utf8');
  selected.stage = 'ongoing';
  assert.throws(() => apply(root, selected), /競合/);
  assert.equal(fs.readFileSync(path.join(root, '.asdd/config.json'), 'utf8'), before);
  assert.match(fs.readFileSync(path.join(root, 'docs/MASTER.md'), 'utf8'), /利用者の追記/);
});
test('non-overlapping hand edits survive repeated reconfiguration', t => {
  const root = temporary(t), selected = config(); apply(root, selected);
  const master = path.join(root, 'docs/MASTER.md');
  fs.appendFileSync(master, '\n利用者の追記\n');
  selected.stage = 'ongoing'; apply(root, selected);
  assert.match(fs.readFileSync(master, 'utf8'), /利用者の追記/);
  assert.equal(apply(root, selected).changed.length, 0);
  selected.workflow = 'standard'; apply(root, selected);
  assert.match(fs.readFileSync(master, 'utf8'), /利用者の追記/);
});
test('missing or failing Git is an environment error, preserving edits and configuration for retry', t => {
  for (const failure of ['missing', 'fatal']) {
    const root = temporary(t), selected = config(); apply(root, selected);
    const master = path.join(root, 'docs/MASTER.md'); fs.appendFileSync(master, '\nUser addition\n');
    const before = fs.readFileSync(path.join(root, '.asdd/config.json'), 'utf8');
    selected.stage = 'ongoing';
    const input = path.join(root, 'confirmed.json'); fs.writeFileSync(input, JSON.stringify(selected));
    const bin = path.join(root, 'bin'); fs.mkdirSync(bin);
    if (failure === 'fatal') fs.writeFileSync(path.join(bin, 'git'), '#!/bin/sh\nexit 128\n', { mode: 0o755 });
    const result = spawnSync(process.execPath, [new URL('../../scripts/asdd/cli.mjs', import.meta.url).pathname,
      '--root', root, '--config', input, '--apply'], { encoding: 'utf8', env: { ...process.env, PATH: bin } });
    assert.equal(result.status, 1);
    assert.match(result.stderr, failure === 'missing' ? /Git is required.*install Git/ : /Git merge-file failed \(exit 128\)/);
    assert.doesNotMatch(result.stderr, /競合/);
    assert.equal(fs.readFileSync(path.join(root, '.asdd/config.json'), 'utf8'), before);
    assert.match(fs.readFileSync(master, 'utf8'), /User addition/);
    assert.equal(fs.existsSync(path.join(root, '.asdd/apply.lock')), false);
    apply(root, selected);
    assert.equal(check(root).initialized, true);
    assert.match(fs.readFileSync(master, 'utf8'), /User addition/);
  }
});
test('hand-edited configuration must be reconciled before rendering dependent files', t => {
  const root = temporary(t), selected = config(); apply(root, selected);
  fs.writeFileSync(path.join(root, '.asdd/config.json'), JSON.stringify({ ...selected, stage: 'ongoing' }));
  selected.workflow = 'standard';
  assert.throws(() => apply(root, selected), /競合/);
  assert.equal(check(root).initialized, false);
  selected.stage = 'ongoing';
  // Confirming the actual edited configuration makes all output use that same input.
  const current = loadConfig(root); current.workflow = 'standard';
  apply(root, current);
  assert.equal(check(root).initialized, true);
  assert.match(fs.readFileSync(path.join(root, 'docs/MASTER.md'), 'utf8'), /段階: ongoing/);
});
test('poc to standard selects documents; unresolved is not implementation ready', t => {
  const root = temporary(t), selected = config();
  apply(root, selected);
  selected.style = 'developer'; selected.stage = 'ongoing'; selected.workflow = 'standard';
  selected.documents.push('TESTING');
  selected.decisions.push({ topic: '公開条件', status: 'unresolved', value: '未決', reason: '公開先を確認する' });
  apply(root, selected);
  const result = check(root);
  assert.equal(result.initialized, true);
  assert.equal(result.implementationReady, false);
  assert.deepEqual(result.pending, ['公開条件']);
  assert.deepEqual(result.unfinished, ['TESTING']);
  selected.documents = ['MASTER']; apply(root, selected);
  assert.ok(fs.existsSync(path.join(root, 'docs/04-quality/TESTING.md')));
});
test('ACE on requires setup, off does not execute or remove knowledge', t => {
  const root = temporary(t), selected = config(); apply(root, selected);
  selected.features.ace = true; apply(root, selected);
  assert.match(check(root).errors.join('\n'), /ace requires setup/);
  fs.mkdirSync(path.join(root, 'docs/08-knowledge'));
  fs.writeFileSync(path.join(root, 'docs/08-knowledge/PLAYBOOK.md'), 'User knowledge');
  selected.features.ace = false; apply(root, selected);
  assert.equal(check(root).errors.length, 0);
  assert.equal(fs.readFileSync(path.join(root, 'docs/08-knowledge/PLAYBOOK.md'), 'utf8'), 'User knowledge');
});
test('unknown config, unsupported versions, ambiguous flags and path escapes are rejected', t => {
  const root = temporary(t);
  assert.throws(() => validateConfig({ ...config(), schemaVersion: 2 }), /schemaVersion/);
  assert.throws(() => validateConfig({ ...config(), secret: 'do-not-store' }), /unknown field/);
  const invalid = config(); invalid.features.ace = 'false';
  assert.throws(() => validateConfig(invalid), /boolean/);
  for (const p of ['../out', '/tmp/out', 'foo/../../out', '.git/../file']) assert.throws(() => projectPath(root, p));
  fs.symlinkSync(os.tmpdir(), path.join(root, 'docs'));
  assert.throws(() => plan(root, config()), /Symlink/);
});
test('history without Issue recording is rejected before initialization and by read-only check', t => {
  const root = temporary(t), selected = config();
  selected.github = { repository: 'example/project', recordIssues: false, saveHistory: true,
    allowedPaths: ['output'], branchPolicy: 'pull-request' };
  assert.throws(() => plan(root, selected), /requires Issue recording/);
  assert.deepEqual(fs.readdirSync(root), []);
  fs.mkdirSync(path.join(root, '.asdd'));
  const file = path.join(root, '.asdd/config.json'); fs.writeFileSync(file, JSON.stringify(selected));
  const before = fs.readFileSync(file, 'utf8');
  assert.throws(() => check(root), /requires Issue recording/);
  assert.equal(fs.readFileSync(file, 'utf8'), before);
  for (const [recordIssues, saveHistory] of [[false, false], [true, false], [true, true]]) {
    selected.github.recordIssues = recordIssues; selected.github.saveHistory = saveHistory;
    assert.doesNotThrow(() => validateConfig(selected));
  }
});
test('check is read-only and setting-free projects stay legacy', t => {
  const root = temporary(t);
  assert.equal(check(root).mode, 'legacy'); assert.deepEqual(fs.readdirSync(root), []);
  apply(root, config());
  const before = fs.statSync(path.join(root, '.asdd/config.json')).mtimeMs;
  const cli = new URL('../../scripts/asdd/cli.mjs', import.meta.url);
  const result = JSON.parse(execFileSync(process.execPath, [cli.pathname, '--root', root, '--check'], { encoding: 'utf8' }));
  assert.equal(result.initialized, true);
  assert.equal(fs.statSync(path.join(root, '.asdd/config.json')).mtimeMs, before);
  assert.throws(() => execFileSync(process.execPath, [cli.pathname, '--root', root, '--check', '--apply'], { stdio: 'pipe' }));
});
test('foreign files and interrupted locks never get overwritten', t => {
  const root = temporary(t); fs.writeFileSync(path.join(root, 'AGENTS.md'), 'Existing rules');
  assert.throws(() => apply(root, config()), /競合/);
  assert.equal(fs.existsSync(path.join(root, '.asdd/config.json')), false);
  fs.writeFileSync(path.join(root, '.asdd/apply.lock'), '');
  assert.throws(() => apply(root, config()), /EEXIST/);
  assert.equal(fs.readFileSync(path.join(root, 'AGENTS.md'), 'utf8'), 'Existing rules');
});
test('reviewed legacy documents and AI settings migrate without rewriting; stale approval fails', t => {
  const root = temporary(t), selected = config(); selected.documents = Object.keys(DOCUMENTS);
  const existing = [...Object.values(DOCUMENTS), 'CLAUDE.md', 'AGENTS.md'];
  const adopt = {};
  for (const file of existing) {
    const target = path.join(root, file), value = `Existing agreement in ${file}\n`;
    fs.mkdirSync(path.dirname(target), { recursive: true }); fs.writeFileSync(target, value);
    adopt[file] = crypto.createHash('sha256').update(value).digest('hex');
  }
  assert.equal(plan(root, selected).conflicts.length, 9);
  assert.equal(plan(root, selected, { adopt }).adopted.length, 9);
  assert.equal(fs.existsSync(path.join(root, '.asdd')), false);
  const agentFile = path.join(root, 'AGENTS.md'); fs.appendFileSync(agentFile, 'Later edit\n');
  assert.throws(() => apply(root, selected, { adopt }), /Reviewed migration file changed/);
  assert.equal(fs.existsSync(path.join(root, '.asdd/config.json')), false);
  adopt['AGENTS.md'] = crypto.createHash('sha256').update(fs.readFileSync(agentFile)).digest('hex');
  apply(root, selected, { adopt });
  selected.stage = 'ongoing'; apply(root, selected);
  assert.equal(check(root).initialized, true);
  assert.equal(check(root).preserved.length, 9);
  assert.equal(fs.readFileSync(agentFile, 'utf8'), 'Existing agreement in AGENTS.md\nLater edit\n');
  fs.appendFileSync(agentFile, 'Unreviewed change\n');
  assert.equal(check(root).initialized, false);
  assert.throws(() => apply(root, selected), /競合/);
});
test('edits during adoption never become silently approved generation state', t => {
  const root = temporary(t), selected = config(), file = path.join(root, 'docs/MASTER.md');
  fs.mkdirSync(path.dirname(file)); fs.writeFileSync(file, 'Reviewed agreement\n');
  const adopt = { 'docs/MASTER.md': crypto.createHash('sha256').update(fs.readFileSync(file)).digest('hex') };
  const rename = fs.renameSync;
  fs.renameSync = (from, to) => {
    rename(from, to);
    if (to === path.join(fs.realpathSync(root), '.asdd/config.json')) fs.appendFileSync(file, 'Concurrent unreviewed edit\n');
  };
  try { assert.throws(() => apply(root, selected, { adopt }), /changed during initialization/); }
  finally { fs.renameSync = rename; }
  assert.equal(check(root).initialized, false);
  assert.match(fs.readFileSync(file, 'utf8'), /Concurrent unreviewed edit/);
});
// multiReview requires no project .claude/agent-config.yaml: requiring it sent adopters to
// copy the bundled default whole. The requirement is a detected AI CLI, probed through multi-agent.sh.
const withMultiReview = () => ({ ...config(), features: { ...config().features, multiReview: true } });
const skipWith = (t, reason) => {
  if (process.env.FF_ASDD_SKIP_MARKER) fs.appendFileSync(process.env.FF_ASDD_SKIP_MARKER, `${reason}\n`); else console.log(`  ○ skip: ${reason}`);
  t.skip(reason);
};
test('multiReview check passes without a project agent-config and reports the CLI probe failure', t => {
  const root = temporary(t); apply(root, withMultiReview());
  assert.equal(fs.existsSync(path.join(root, '.claude/agent-config.yaml')), false);
  const probed = [];
  const ok = check(root, { probeMultiReview: dir => { probed.push(dir); return null; } });
  assert.deepEqual(probed, [root]);
  assert.deepEqual(ok.errors, []);
  assert.equal(ok.initialized, true);
  assert.equal(ok.capabilities.multiReview, 'configured-unverified');
  const failed = check(root, { probeMultiReview: () => 'Selected multiReview requires an available AI CLI (probe)' });
  assert.deepEqual(failed.errors, ['Selected multiReview requires an available AI CLI (probe)']);
  assert.equal(failed.initialized, false);
});
test('multiReview check is not probed when the feature is off', t => {
  const root = temporary(t); apply(root, config());
  assert.equal(check(root, { probeMultiReview: () => assert.fail('probe must not run when multiReview is off') }).initialized, true);
});
test('multiReview probe verdicts name the actual cause', () => {
  const out = lines => lines.join('\n') + '\n';
  const ok = (status, extra = []) => ({ status, signal: null, stdout: out(['main=', 'main_source=unset', ...extra]), stderr: '' });
  assert.equal(judgeMultiReviewProbe(ok(3, ['available=codex-cli'])), null);
  assert.equal(judgeMultiReviewProbe({ ...ok(0, ['available=codex-cli']), stdout: out(['main=codex-cli', 'main_source=user config', 'available=codex-cli grok-cli']) }), null);
  assert.match(judgeMultiReviewProbe(ok(0, ['available='])), /requires an available AI CLI \(.* exit 0\): no AI CLI detected/);
  assert.match(judgeMultiReviewProbe({ ...ok(0), stdout: out(['main=claude-code', 'main_source=user config', 'available=codex-cli']) }),
    /main reviewer 'claude-code' \(user config\) is not installed \(available: codex-cli\)/);
  // A non-success exit fails even when available= was printed.
  assert.match(judgeMultiReviewProbe({ status: 1, signal: null, stdout: out(['available=codex-cli']), stderr: 'ERROR: unknown main reviewer: foo\n' }),
    /^Selected multiReview probe failed \(.* exit 1\): ERROR: unknown main reviewer: foo$/);
  // ERROR: wins over the ❌ status lines CLI detection prints first, and the install hints are kept.
  assert.equal(judgeMultiReviewProbe({ status: 1, signal: null, stdout: '', stderr: '  ❌ codex-cli (codex) — not installed\n\nERROR: No AI CLIs are installed. Install at least one:\n  npm install -g @openai/codex\n' }),
    'Selected multiReview requires an available AI CLI (multi-agent.sh --task review --print-reviewers exit 1): ERROR: No AI CLIs are installed. Install at least one:; npm install -g @openai/codex');
  assert.match(judgeMultiReviewProbe({ status: 2, signal: null, stdout: '', stderr: 'ℹ️ x\n❌ handoff mismatch: FF_DEV_TOOLKIT_ROOT=/other\n   cacheや別checkoutを探さず\n' }),
    /probe failed \(.* exit 2\): ❌ handoff mismatch: FF_DEV_TOOLKIT_ROOT=\/other; cacheや別checkoutを探さず$/);
  assert.match(judgeMultiReviewProbe({ status: null, signal: 'SIGTERM', stdout: '', stderr: '', error: Object.assign(new Error('spawnSync bash ETIMEDOUT'), { code: 'ETIMEDOUT' }) }),
    /^Selected multiReview probe failed \(.* timed out after 60s\)$/);
  assert.match(judgeMultiReviewProbe({ status: null, signal: null, stdout: '', stderr: '', error: Object.assign(new Error('spawnSync bash ENOENT'), { code: 'ENOENT' }) }),
    /probe failed \(.* could not start bash \(ENOENT\)\)$/);
  assert.match(judgeMultiReviewProbe({ status: null, signal: 'SIGKILL', stdout: '', stderr: '' }), /probe failed \(.* killed by SIGKILL\)$/);
  assert.ok(judgeMultiReviewProbe({ status: 1, signal: null, stdout: '', stderr: `ERROR: ${'x'.repeat(2000)}\n` }).length < 700);
});
// End to end through cli.mjs and the real multi-agent.sh. The environment is built from scratch so
// a handoff variable or a user reviewers file from the runner cannot leak in.
const CLI_COMMANDS = ['claude', 'codex', 'copilot', 'grok'];
const SYSTEM_PATH = '/usr/bin:/bin';
const env = (home, extraBin) => ({ PATH: extraBin ? `${extraBin}:${SYSTEM_PATH}` : SYSTEM_PATH, HOME: home, TMPDIR: os.tmpdir() });
const runCheck = (root, extraBin) => spawnSync(process.execPath, [new URL('../../scripts/asdd/cli.mjs', import.meta.url).pathname, '--root', root, '--check'],
  { encoding: 'utf8', env: env(root, extraBin) });
const fakeCli = (root, name = 'codex') => {
  const bin = path.join(root, 'fake-bin'); fs.mkdirSync(bin, { recursive: true });
  fs.writeFileSync(path.join(bin, name), '#!/bin/sh\nexit 0\n', { mode: 0o755 });
  return bin;
};
const saveReviewers = (home, main) => {
  fs.mkdirSync(path.join(home, '.config/ff-dev-toolkit'), { recursive: true });
  fs.writeFileSync(path.join(home, '.config/ff-dev-toolkit/reviewers'), `main=${main}\nsub=\n`);
};
test('asdd-init --check accepts multiReview with one AI CLI and no project agent-config', t => {
  const root = temporary(t); apply(root, withMultiReview());
  const result = runCheck(root, fakeCli(root));
  assert.equal(result.status, 0, result.stdout + result.stderr);
  assert.deepEqual(JSON.parse(result.stdout).errors, []);
  assert.equal(fs.existsSync(path.join(root, '.claude/agent-config.yaml')), false);
});
test('asdd-init --check accepts a saved main reviewer that is installed and rejects one that is not', t => {
  const root = temporary(t); apply(root, withMultiReview());
  const bin = fakeCli(root);
  saveReviewers(root, 'codex-cli');
  const installed = runCheck(root, bin);
  assert.equal(installed.status, 0, installed.stdout + installed.stderr);
  assert.deepEqual(JSON.parse(installed.stdout).errors, []);
  if (fs.existsSync('/usr/bin/claude') || fs.existsSync('/bin/claude')) { skipWith(t, `asdd-runtime: missing-main check not measured — claude found in ${SYSTEM_PATH}`); return; }
  saveReviewers(root, 'claude-code');
  const missing = runCheck(root, bin);
  assert.equal(missing.status, 1, missing.stdout + missing.stderr);
  assert.deepEqual(JSON.parse(missing.stdout).errors, [`Selected multiReview: main reviewer 'claude-code' (user config) is not installed (available: codex-cli). Install it, or pick another with multi-agent.sh --task review --set-reviewers main=<cli>`]);
});
test('asdd-init --check rejects multiReview when no AI CLI is installed', t => {
  const present = CLI_COMMANDS.filter(cmd => SYSTEM_PATH.split(':').some(dir => fs.existsSync(path.join(dir, cmd))));
  if (present.length) { skipWith(t, `asdd-runtime: no-CLI multiReview check not measured — ${present.join(' ')} found in ${SYSTEM_PATH}`); return; }
  const root = temporary(t); apply(root, withMultiReview());
  const result = runCheck(root);
  assert.equal(result.status, 1, result.stdout + result.stderr);
  const { errors } = JSON.parse(result.stdout);
  assert.equal(errors.length, 1, errors.join('\n'));
  assert.match(errors[0], /^Selected multiReview requires an available AI CLI \(multi-agent\.sh --task review --print-reviewers exit 1\): ERROR: No AI CLIs are installed/);
});
// setup-multi-agent.sh is the step /asdd-init runs for multiReview. Run its main to completion with
// only the environment-dependent stages stubbed, so check_config and print_summary are the real ones.
const SCRIPTS = new URL('../../scripts/', import.meta.url).pathname;
const runSetup = root => spawnSync('bash', ['-c', `. "$1" >/dev/null 2>&1
for stage in print_header check_prerequisites check_and_install_dependencies detect_ai_clis show_install_guides install_review_wrappers run_verification; do eval "$stage() { :; }"; done
main`, 'setup', path.join(SCRIPTS, 'setup-multi-agent.sh')], { cwd: root, encoding: 'utf8', env: env(root) });
test('setup-multi-agent.sh completes without telling adopters to copy the bundled agent-config whole', t => {
  const root = temporary(t);
  const result = runSetup(root);
  const output = result.stdout + result.stderr;
  assert.equal(result.status, 0, output);
  assert.match(output, /セットアップ完了/);
  assert.match(output, /\.claude\/agent-config\.yaml が無ければ同梱の既定で動きます/);
  // The bundled file may only be named as the effective config (check_config), never as a source to
  // copy from, whatever the verb (cp / cat > / install / prose).
  const bundled = path.join(SCRIPTS, 'agent-config.yaml');
  assert.deepEqual(output.split('\n').filter(line => line.includes(bundled) && !/Effective config|Config:/.test(line)), []);
  assert.doesNotMatch(output, /(cp|cat|install|rsync) [^\n]*agent-config\.yaml[^\n]*\.claude|(コピー|複製|写|雛形)[^\n]*agent-config|agent-config[^\n]*(コピー|複製|写して|雛形)/);
  assert.equal(fs.existsSync(path.join(root, '.claude')), false);
});
// The guidance claims a minimal file behaves like the bundled default for every key it leaves out.
// Run the printed example and compare the resolved plan settings against the plugin default.
test('the minimal agent-config example resolves every task like the bundled default', t => {
  const yq = (process.env.PATH ?? '').split(':').find(dir => dir && fs.existsSync(path.join(dir, 'yq')));
  if (!yq) { skipWith(t, 'asdd-runtime: minimal agent-config parity not measured — yq not on PATH'); return; }
  const home = temporary(t), bin = fakeCli(home), base = path.join(home, 'default'), minimal = path.join(home, 'minimal');
  fs.mkdirSync(base); fs.mkdirSync(minimal);
  const example = /^\s*(\[ -e \.claude\/agent-config\.yaml \] \|\|.*)$/m.exec(runSetup(home).stdout)?.[1];
  assert.ok(example, 'setup prints the minimal-file example');
  assert.equal(spawnSync('bash', ['-c', example], { cwd: minimal, env: env(home) }).status, 0);
  assert.ok(fs.existsSync(path.join(minimal, '.claude/agent-config.yaml')));
  const settings = (cwd, task) => {
    const result = spawnSync('bash', [path.join(SCRIPTS, 'multi-agent.sh'), '--task', task, '--description', 'parity', '--dry-run'],
      { cwd, encoding: 'utf8', env: { ...env(home, `${bin}:${yq}`) } });
    const output = result.stdout + result.stderr;
    assert.equal(result.status, 0, output);
    return { config: /Config: .*\((.+)\)/.exec(output)?.[1],
      plan: ['Mode', 'Strategy', 'Parallel', 'Timeout'].map(key => new RegExp(`^\\s*${key}: (.+)$`, 'm').exec(output)?.[1])
        .concat(path.basename(/^\s*Output: (.+)$/m.exec(output)?.[1] ?? '')) };
  };
  for (const task of ['review', 'explore', 'implement']) {
    const bundled = settings(base, task), override = settings(minimal, task);
    assert.equal(bundled.config, 'plugin default'); assert.equal(override.config, 'project override');
    assert.ok(bundled.plan.every(Boolean), `${task}: ${bundled.plan}`);
    assert.deepEqual(override.plan, bundled.plan, task);
  }
});
