import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import os from 'node:os';
import { spawnSync } from 'node:child_process';
import { isDeepStrictEqual } from 'node:util';
import { DOCUMENTS, FEATURES, projectPath, validateConfig, loadConfig } from './config.mjs';

const digest = value => crypto.createHash('sha256').update(value).digest('hex');
const json = value => `${JSON.stringify(value, null, 2)}\n`;
const content = (root, file) => fs.existsSync(projectPath(root, file)) ? fs.readFileSync(projectPath(root, file), 'utf8') : null;
const titles = { MASTER: 'プロジェクト案内', PROJECT: '目的と完成条件', DOMAIN: '業務ルールと用語', ARCHITECTURE: '構成と技術選定', PATTERNS: '実装方針', TESTING: '確認方法', DEPLOYMENT: '利用・公開と運用' };
const decisionText = decisions => decisions.length ? decisions.map(d => `- **${d.topic}**: ${d.value}\n  理由・根拠: ${d.reason}`).join('\n') : '現在の記録はありません。';
export function render(config, date) {
  validateConfig(config);
  const files = { '.asdd/config.json': json(config) };
  const agreed = config.decisions.filter(d => d.status === 'agreed');
  for (const id of config.documents) {
    const header = `---\ntitle: ${JSON.stringify(titles[id])}\nversion: "1.0.0"\nstatus: "draft"\nowner: ${JSON.stringify(config.project.owner)}\ncreated: "${date}"\nupdated: "${date}"\n---\n\n# ${titles[id]}\n\n`;
    let body;
    if (id === 'MASTER') {
      body = `## 目的と使い方\n\n${config.project.name}\n\n${config.project.purpose}\n\nやりたいことや「今どうなっている？」を会話で伝えてください。ASDD設定は \`.asdd/config.json\` を参照します。\n\n## 構成\n\n- 利用スタイル: ${config.style}\n- 段階: ${config.stage}\n- 進め方: ${config.workflow}\n${FEATURES.map(f => `- ${f}: ${config.features[f] ? '選択済み（利用準備は --check で確認）' : '無効'}`).join('\n')}\n\n## 確認済みの事実\n\n${decisionText(config.decisions.filter(d => d.status === 'fact'))}\n\n## 合意済みの決定\n\n${decisionText(agreed)}\n\n## 提案中\n\n${decisionText(config.decisions.filter(d => d.status === 'proposed'))}\n\n## 未決事項\n\n${decisionText(config.decisions.filter(d => d.status === 'unresolved'))}\n\n## 共通ルール\n\n- 重要な未決事項を推測で確定せず、推奨案と理由を示して合意する。既に合意・委任された範囲は再質問しない。\n- 提案中・未決の内容を必須ルールや完了として扱わない。初期構築・実装準備・利用公開の状態を区別する。\n- 秘密情報を出力・コミットせず、既存の組織ルールと手編集を保持する。公開・送信・破壊的操作は現在の承認範囲を確認する。\n- テスト目標・例外処理・定数化等はプロジェクトの合意に従う。一律のカバレッジ数値やResult型を要求しない。\n- 技術選定は公式の最新LTS／本番推奨安定版を確認し、確認日・情報源・互換性・サポート期限を記録する。未確認を最新確認済みと呼ばない。\n\n## 関連文書・作業\n\n${config.documents.filter(d => d !== 'MASTER').map(d => `- [${titles[d]}](./${DOCUMENTS[d].slice(5)})`).join('\n') || '必要な観点はこの案内とIssueに記録し、必要になった時点で文書へ分けます。'}\n\n${config.github ? `[作業一覧](https://github.com/${config.github.repository}/issues)` : 'GitHub記録先は未設定です。外部への自動記録は行いません。'}`;
    } else {
      body = `## この文書の役割\n\n${titles[id]}を、確認済みの事実と合意した内容から整理します。\n\n## 現在の状態\n\n未決。初期化で文書の入口を作成した段階です。この観点の内容・完成条件は対話で確認します。\n\n## 関連する決定\n\n[プロジェクト案内](../MASTER.md)の合意済みの決定・未決事項を参照してください。推奨候補を必須方針に読み替えないでください。`;
    }
    files[DOCUMENTS[id]] = `${header}${body}\n\n## Changelog\n\n- [1.0.0] - ${date} 初版作成\n`;
  }
  for (const tool of config.tools) {
    const name = tool === 'claude' ? 'CLAUDE.md' : 'AGENTS.md';
    files[name] = `# ${name}\n\n作業前に [プロジェクト案内](docs/MASTER.md) と \`.asdd/config.json\` を読み、合意した設定に従ってください。詳細ルールは案内から関連文書へ到達します。\n\n- 初期構築・再設定は asdd-init、日常の依頼・記録・再開・状況確認は asdd-work を使用します。\n- 未決事項を推測で埋めず、必要な判断には推奨候補と理由を示します。合意・委任済み事項は繰り返し質問しません。\n- 無効なACE・振り返り・複数AIレビューを実行・催促しません。\n- 市民開発では業務の言葉で説明し、GitHub操作を利用者の前提知識にしません。\n- 記録と履歴保存は合意した範囲のみ。秘密情報・無関係な変更を保存せず、既存の組織ルールやブランチ保護を保持します。\n`;
  }
  return files;
}
function state(root) {
  const raw = content(root, '.asdd/managed.json');
  if (raw === null) return { schemaVersion: 1, created: new Date().toISOString().slice(0, 10), files: {}, originals: {} };
  const value = JSON.parse(raw);
  if (value.schemaVersion !== 1 || !/^\d{4}-\d{2}-\d{2}$/.test(value.created) || !value.files || typeof value.files !== 'object') throw new Error('Invalid generation state');
  for (const [file, hash] of Object.entries(value.files)) {
    projectPath(root, file);
    if (typeof hash !== 'string' || !/^[0-9a-f]{64}$/.test(hash)) throw new Error('Invalid managed file hash');
  }
  value.originals ??= {};
  value.preserved ??= {};
  for (const [file, enabled] of Object.entries(value.preserved)) {
    projectPath(root, file);
    if (enabled !== true || !value.files[file] || file.startsWith('.asdd/')) throw new Error('Invalid preserved file state');
  }
  for (const [file, original] of Object.entries(value.originals)) {
    projectPath(root, file);
    if (typeof original !== 'string') throw new Error('Invalid original generation content');
  }
  return value;
}
function mergeContent(current, base, next) {
  if (base === next) return current;
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'asdd-merge-'));
  try {
    const names = ['current', 'base', 'next'].map(name => path.join(directory, name));
    [current, base, next].forEach((value, i) => fs.writeFileSync(names[i], value));
    const result = spawnSync('git', ['merge-file', '-p', ...names], { encoding: 'utf8' });
    if (result.error?.code === 'ENOENT') throw new Error('Git is required to merge hand-edited documents; install Git and retry');
    if (result.error) throw new Error(`Unable to execute Git for hand-edited documents (${result.error.code ?? 'execution error'})`);
    if (result.signal || result.status === null) throw new Error(`Git merge-file did not complete (${result.signal ?? 'unknown exit status'})`);
    if (result.status === 0) return result.stdout;
    // merge-file returns the conflict count (capped at 127); fatal errors
    // and negative exit values exposed as 8-bit statuses are not conflicts.
    if (result.status > 0 && result.status <= 127) return null;
    throw new Error(`Git merge-file failed (exit ${result.status}); check the Git execution environment and retry`);
  } finally { fs.rmSync(directory, { recursive: true, force: true }); }
}
function preservesEdits(current, base, next) {
  if (isDeepStrictEqual(current, base) || isDeepStrictEqual(current, next)) return true;
  if ([current, base, next].every(value => value && typeof value === 'object' && !Array.isArray(value))) {
    return [...new Set([...Object.keys(current), ...Object.keys(base)])]
      .every(key => preservesEdits(current[key], base[key], next[key]));
  }
  return false;
}
export function plan(root, config, { adopt = {} } = {}) {
  const previous = state(root);
  const files = render(config, previous.created);
  const changes = [], conflicts = [], adopted = [], expectedHashes = {};
  if (!adopt || typeof adopt !== 'object' || Array.isArray(adopt)) throw new Error('Adoption must map reviewed file paths to SHA-256 hashes');
  for (const [file, hash] of Object.entries(adopt)) {
    if (!Object.hasOwn(files, file) || file.startsWith('.asdd/') || !/^[0-9a-f]{64}$/.test(hash)) throw new Error(`Invalid adoption target: ${file}`);
    const current = content(root, file);
    if (current === null || digest(current) !== hash) throw new Error(`Reviewed migration file changed: ${file}`);
    adopted.push(file);
  }
  for (const [file, generated] of Object.entries(files)) {
    let next = generated;
    const current = content(root, file);
    expectedHashes[file] = current === null ? null : digest(current);
    // Adopted legacy documents remain user-owned; templates never replace them.
    if (adopted.includes(file)) continue;
    if (previous.preserved?.[file]) {
      if (current === null || digest(current) !== previous.files[file]) conflicts.push(file);
      continue;
    }
    if (current === next) continue;
    // Configuration is the input to every renderer. Merging it as output would
    // leave the other generated files based on a different configuration.
    if (file === '.asdd/config.json' && current !== null) {
      const original = previous.originals[file];
      if (digest(current) !== previous.files[file] && (!original || !preservesEdits(JSON.parse(current), JSON.parse(original), config))) {
        conflicts.push(file); continue;
      }
      changes.push({ file, action: 'update', content: generated }); continue;
    }
    if (current !== null && digest(current) !== previous.files[file]) {
      next = typeof previous.originals[file] === 'string' ? mergeContent(current, previous.originals[file], generated) : null;
      if (next === null) { conflicts.push(file); continue; }
    } else if (current !== null && previous.originals[file] && digest(previous.originals[file]) !== previous.files[file]) {
      next = mergeContent(current, previous.originals[file], generated);
      if (next === null) { conflicts.push(file); continue; }
    }
    if (current !== next) changes.push({ file, action: current === null ? 'create' : 'update', content: next });
  }
  // Deselected files are retained. Losing ownership must never delete user material.
  const retained = Object.keys(previous.files).filter(file => !Object.hasOwn(files, file));
  for (const change of changes) expectedHashes[change.file] = digest(change.content);
  return { previous, files, changes, conflicts, retained, adopted, expectedHashes };
}
function write(root, file, value) {
  const target = projectPath(root, file);
  fs.mkdirSync(path.dirname(target), { recursive: true });
  const temp = `${target}.${process.pid}.asdd-tmp`;
  fs.writeFileSync(temp, value, { flag: 'wx' });
  fs.renameSync(temp, target);
}
export function apply(root, config, options) {
  const lock = projectPath(root, '.asdd/apply.lock');
  fs.mkdirSync(path.dirname(lock), { recursive: true });
  const fd = fs.openSync(lock, 'wx');
  try {
    const result = plan(root, config, options);
    if (result.conflicts.length) throw new Error(`手編集との競合。差分を確認してください: ${result.conflicts.join(', ')}`);
    const next = { schemaVersion: 1, created: result.previous.created, files: { ...result.previous.files }, originals: { ...result.previous.originals, ...result.files }, preserved: { ...result.previous.preserved } };
    for (const file of result.adopted) next.preserved[file] = true;
    for (const file of Object.keys(next.preserved)) delete next.originals[file];
    // Persist after each file write. An interruption between writes remains visible as drift.
    for (const change of result.changes) {
      write(root, change.file, change.content);
      result.previous.files[change.file] = digest(change.content);
      result.previous.originals[change.file] = result.files[change.file];
      write(root, '.asdd/managed.json', json(result.previous));
    }
    for (const file of Object.keys(result.files)) {
      const current = content(root, file);
      if (current === null || digest(current) !== result.expectedHashes[file]) throw new Error(`File changed during initialization: ${file}`);
      next.files[file] = result.expectedHashes[file];
    }
    write(root, '.asdd/managed.json', json(next));
    return { changed: result.changes.map(c => c.file), retained: result.retained, adopted: result.adopted };
  } finally { fs.closeSync(fd); fs.unlinkSync(lock); }
}
export function check(root) {
  const config = loadConfig(root);
  if (!config) return { mode: 'legacy', initialized: false, implementationReady: false, releaseReady: 'not-assessed', errors: [] };
  const previous = state(root), errors = [];
  const expected = render(config, previous.created);
  for (const file of Object.keys(expected)) {
    const current = content(root, file);
    if (current === null) errors.push(`Missing: ${file}`);
    else if (!previous.files[file] || digest(current) !== previous.files[file]) errors.push(`Changed or unmanaged: ${file}`);
  }
  if (content(root, '.asdd/apply.lock') !== null) errors.push('Initialization lock remains: inspect interrupted work before retry');
  const requirements = { ace: 'docs/08-knowledge/PLAYBOOK.md', multiReview: '.claude/agent-config.yaml', ci: '.github/workflows' };
  const capabilities = {};
  for (const feature of FEATURES) {
    capabilities[feature] = !config.features[feature] ? 'disabled' : 'configured-unverified';
    if (config.features[feature] && requirements[feature] && !fs.existsSync(projectPath(root, requirements[feature]))) errors.push(`Selected ${feature} requires setup: ${requirements[feature]}`);
  }
  const pending = config.decisions.filter(d => ['proposed', 'unresolved'].includes(d.status)).map(d => d.topic);
  // Generated document shells still require substantive human/agent review, even with no pending decisions.
  const unfinished = config.documents.filter(id => content(root, DOCUMENTS[id])?.includes('未決。初期化で文書の入口'));
  return { mode: 'asdd2', initialized: errors.length === 0, implementationReady: errors.length || pending.length || unfinished.length ? false : 'not-assessed', releaseReady: 'not-assessed', pending, unfinished, preserved: Object.keys(previous.preserved ?? {}), capabilities, errors };
}
