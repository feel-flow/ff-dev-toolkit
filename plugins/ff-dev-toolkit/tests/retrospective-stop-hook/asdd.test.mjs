import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, mkdirSync, writeFileSync, rmSync, symlinkSync, readdirSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { spawnSync } from 'node:child_process';
const plugin = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');
const hooks = ['retrospective-context.sh', 'retrospective-stop.sh', 'check-update.sh', 'check-skill-drift.sh', 'auto-update-marketplace.sh', 'guard-checkout-restore.sh', 'guard-pr-followup.sh', 'guard-background-cwd.sh', 'guard-review-in-flight.sh'];
const configuration = () => ({ schemaVersion: 1, project: { name: 'Example', purpose: 'Verify hooks', owner: 'tester' }, style: 'citizen', stage: 'poc', tools: ['claude', 'codex'], documents: ['MASTER'], features: { ace: false, retrospective: false, multiReview: false, hooks: true, ci: false }, workflow: 'simple', decisions: [], github: null });
function fixture(t) {
  const root = mkdtempSync(path.join(tmpdir(), 'asdd-hook-'));
  t.after(() => rmSync(root, { recursive: true, force: true }));
  mkdirSync(path.join(root, '.asdd'));
  return root;
}
function save(root, config) { writeFileSync(path.join(root, '.asdd/config.json'), JSON.stringify(config)); }
function run(root, hook, extraEnv = {}) {
  const input = hook === 'retrospective-stop.sh' ? { hook_event_name: 'Stop', stop_hook_active: false } : { hook_event_name: 'UserPromptSubmit', prompt: 'work' };
  const env = { ...process.env, PWD: root, ...extraEnv };
  delete env.RETROSPECTIVE_MODE;
  Object.assign(env, extraEnv);
  return spawnSync('/bin/bash', [path.join(plugin, 'hooks', hook)], { cwd: root, env, input: JSON.stringify(input), encoding: 'utf8', timeout: 5000 });
}
function silent(result) { assert.equal(result.status, 0, result.stderr); assert.equal(result.stdout, ''); assert.equal(result.stderr, ''); }

test('retrospective disabled stays silent for both hooks and auto/ask env overrides', t => {
  const root = fixture(t); save(root, configuration());
  for (const hook of hooks.slice(0, 2)) for (const mode of ['', 'auto', 'ask']) silent(run(root, hook, { RETROSPECTIVE_MODE: mode }));
});
test('hooks disabled suppress every optional hook and leave no state files', t => {
  const root = fixture(t); const config = configuration(); config.features.hooks = false; config.features.retrospective = true; save(root, config);
  for (const hook of hooks) silent(run(root, hook));
  assert.deepEqual(readdirSync(root), ['.asdd']); assert.deepEqual(readdirSync(path.join(root, '.asdd')), ['config.json']);
});
test('on -> off -> on applies without persistent markers; environment off wins', t => {
  const root = fixture(t); const config = configuration();
  for (const enabled of [true, false, true]) {
    config.features.retrospective = enabled; save(root, config);
    for (const hook of hooks.slice(0, 2)) {
      const result = run(root, hook); assert.equal(result.status, 0);
      if (enabled) assert.match(result.stdout, /ff-dev-toolkit:retrospective/); else silent(result);
    }
  }
  for (const hook of hooks.slice(0, 2)) silent(run(root, hook, { RETROSPECTIVE_MODE: 'off' }));
});
test('subdirectory resolves project config, nested repository does not inherit parent', t => {
  const root = fixture(t); save(root, configuration());
  const sub = path.join(root, 'src/deep'); mkdirSync(sub, { recursive: true });
  silent(run(sub, hooks[0])); silent(run(sub, hooks[1]));
  mkdirSync(path.join(sub, '.git'));
  assert.match(run(sub, hooks[0]).stdout, /ff-dev-toolkit:retrospective/);
});
test('malformed, unsupported, and symlink config stop automation with a nonblocking diagnostic', t => {
  const root = fixture(t);
  for (const source of ['{', JSON.stringify({ ...configuration(), schemaVersion: 999 })]) {
    writeFileSync(path.join(root, '.asdd/config.json'), source);
    for (const hook of hooks.slice(0, 2)) {
      const result = run(root, hook); assert.equal(result.status, 0); assert.equal(result.stdout, ''); assert.match(result.stderr, /ASDD.*検証できない/);
    }
  }
  rmSync(path.join(root, '.asdd/config.json'));
  const target = path.join(root, 'outside.json'); writeFileSync(target, JSON.stringify(configuration())); symlinkSync(target, path.join(root, '.asdd/config.json'));
  assert.match(run(root, hooks[0]).stderr, /ASDD.*検証できない/);
});
test('ASDD config with missing Node does not fall back to automatic injection', t => {
  const root = fixture(t); save(root, configuration());
  const result = run(root, hooks[0], { PATH: '/nonexistent' });
  assert.equal(result.status, 0); assert.equal(result.stdout, ''); assert.match(result.stderr, /Node.js/);
});
