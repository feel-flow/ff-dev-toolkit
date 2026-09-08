import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { execFileSync, spawnSync } from 'node:child_process';
import crypto from 'node:crypto';
import { DOCUMENTS, validateConfig, loadConfig, projectPath } from '../../scripts/asdd/config.mjs';
import { apply, plan, check } from '../../scripts/asdd/generate.mjs';

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
