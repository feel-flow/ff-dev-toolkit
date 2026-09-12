import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, mkdirSync, writeFileSync, readFileSync, rmSync, symlinkSync, readdirSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { spawnSync } from 'node:child_process';
const plugin = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');
// 名簿は列挙せず hooks.json から導出する。列挙だと、ガードを 1 本足したときに名簿への
// 追記だけが落ち、その hook の静音契約が**未検査のまま緑**になる（実際に
// guard-effort-actual.sh / guard-issue-labels.sh がそうなっていた）。導出できない
// コマンドは throw して fail-closed にする（黙って名簿が縮む経路を残さない）。
//
// 導出規則はこの 1 つ（`$CLAUDE_PLUGIN_ROOT/hooks/<name>.sh`、波括弧は任意）で、
// self-test 側の sandbox 名簿も同じ正規表現を使う。片方だけが波括弧を要求していると、
// `"$CLAUDE_PLUGIN_ROOT/hooks/x.sh"` と書いた登録がこちらの名簿には入るのに sandbox
// へは copy されず、spawn 失敗という原因の読めない赤になる。
const HOOK_COMMAND_PATTERN = /\$\{?CLAUDE_PLUGIN_ROOT\}?\/hooks\/([A-Za-z0-9._-]+\.sh)/;
// 意図的に ASDD ゲートを通さない（= 無効化できない必須の）hook を登録したときだけ、
// ここへ明示的に足す。空のままでも崩壊床は効く（下の roster テストを参照）。
const ungatedHooks = new Set([]);
function registeredHooks() {
  const manifest = JSON.parse(readFileSync(path.join(plugin, 'hooks/hooks.json'), 'utf8'));
  const names = new Set();
  for (const matchers of Object.values(manifest.hooks)) for (const matcher of matchers) for (const entry of matcher.hooks) {
    const matched = HOOK_COMMAND_PATTERN.exec(entry.command);
    if (!matched) throw new Error(`hooks.json のコマンドから hook スクリプト名を導出できません: ${entry.command}`);
    if (!ungatedHooks.has(matched[1])) names.add(matched[1]);
  }
  return [...names];
}
// 振り返り 2 本だけは名前で持つ — 入力の形（Stop / UserPromptSubmit）と、注入文言を
// 見る検査がこの 2 本を名指しするため。名簿全体はこの 2 本 + 導出分で、上の roster 検査が
// 「名簿 = hooks.json の登録 = ゲートを呼ぶ hook 実体」の一致を固定する。
const retrospectiveHooks = ['retrospective-context.sh', 'retrospective-stop.sh'];
const hooks = [...retrospectiveHooks, ...registeredHooks().filter(hook => !retrospectiveHooks.includes(hook)).sort()];
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

// 崩壊床: 名簿が縮む変異（slice / filter / 列挙への書き戻し）は、独立した 2 つの実体
// — hooks.json の登録と hooks/*.sh のゲート呼び出し — と食い違って赤になる。
// 逆に hook を 1 本足したときは、両方の実体に現れた時点で名簿へ自動で入る。
//
// 突き合わせは「ゲート実体 ⊆ 登録」の片方向だけにする。逆向き（登録 ⊆ ゲート実体）まで
// 強制すると、意図的に非ゲート（= 無効化できない必須）な hook を登録した瞬間に偽の赤に
// なり、hooks.json 側を正しく書いた変更が止まる。非ゲートで登録するものは ungatedHooks
// へ明示して名簿から外す。allowlist が空でも、名簿が縮む変異は上の deepEqual が赤にする。
test('roster is derived from hooks.json and covers every ASDD-gated hook script', () => {
  assert.deepEqual([...hooks].sort(), registeredHooks().sort());
  const gated = readdirSync(path.join(plugin, 'hooks'))
    .filter(name => name.endsWith('.sh') && name !== 'asdd-hook-gate.sh')
    .filter(name => /^\s*asdd_hook_enabled\s/m.test(readFileSync(path.join(plugin, 'hooks', name), 'utf8')));
  const registered = registeredHooks();
  for (const hook of gated) {
    assert.ok(registered.includes(hook), `${hook} は ASDD ゲートを呼ぶのに hooks.json の登録から導出できない`);
  }
  for (const hook of ungatedHooks) {
    assert.ok(!gated.includes(hook), `${hook} は ASDD ゲートを呼ぶので ungatedHooks から外すこと`);
  }
  for (const hook of retrospectiveHooks) assert.ok(hooks.includes(hook), `${hook} が名簿に無い`);
});
test('retrospective disabled stays silent for both hooks and auto/ask env overrides', t => {
  const root = fixture(t); save(root, configuration());
  for (const hook of retrospectiveHooks) for (const mode of ['', 'auto', 'ask']) silent(run(root, hook, { RETROSPECTIVE_MODE: mode }));
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
    for (const hook of retrospectiveHooks) {
      const result = run(root, hook); assert.equal(result.status, 0);
      if (enabled) assert.match(result.stdout, /ff-dev-toolkit:retrospective/); else silent(result);
    }
  }
  for (const hook of retrospectiveHooks) silent(run(root, hook, { RETROSPECTIVE_MODE: 'off' }));
});
test('subdirectory resolves project config, nested repository does not inherit parent', t => {
  const root = fixture(t); save(root, configuration());
  const sub = path.join(root, 'src/deep'); mkdirSync(sub, { recursive: true });
  silent(run(sub, retrospectiveHooks[0])); silent(run(sub, retrospectiveHooks[1]));
  mkdirSync(path.join(sub, '.git'));
  assert.match(run(sub, retrospectiveHooks[0]).stdout, /ff-dev-toolkit:retrospective/);
});
test('malformed, unsupported, and symlink config stop automation with a nonblocking diagnostic', t => {
  const root = fixture(t);
  for (const source of ['{', JSON.stringify({ ...configuration(), schemaVersion: 999 })]) {
    writeFileSync(path.join(root, '.asdd/config.json'), source);
    for (const hook of retrospectiveHooks) {
      const result = run(root, hook); assert.equal(result.status, 0); assert.equal(result.stdout, ''); assert.match(result.stderr, /ASDD.*検証できない/);
    }
  }
  rmSync(path.join(root, '.asdd/config.json'));
  const target = path.join(root, 'outside.json'); writeFileSync(target, JSON.stringify(configuration())); symlinkSync(target, path.join(root, '.asdd/config.json'));
  assert.match(run(root, retrospectiveHooks[0]).stderr, /ASDD.*検証できない/);
});
test('ASDD config with missing Node does not fall back to automatic injection', t => {
  const root = fixture(t); save(root, configuration());
  const result = run(root, retrospectiveHooks[0], { PATH: '/nonexistent' });
  assert.equal(result.status, 0); assert.equal(result.stdout, ''); assert.match(result.stderr, /Node.js/);
});
