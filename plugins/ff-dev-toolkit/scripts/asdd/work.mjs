#!/usr/bin/env node
// ff-dev-toolkit-node-root-guard:start
// plugin root 固定ガード（node entry 側）。判定も案内文言も shell 側ガードと同じで、
// **文言の正本は shell ガード block ただ 1 つ**である。ここは写しで、tests/plugin-root-contract
// が同じ fixture で shell 側と node 側を実走し、案内の本文が 1 行も違わないことを照合する
// （ソース文字列の比較にすると `${var:-既定}` のような言語ごとの綴りを吸収する正規化規則が
// 第 3 の正本になるので、consumer が実際に読む出力の側で縛る）。案内文言を別ファイルへ
// 切り出して読み込む形は採らない — このガードが動くのは plugin root が壊れているときで、
// ちょうどそのとき読めない可能性のある file へ案内文言を預けることになる（shell 側が
// 「実行部と同じファイルへ置く」を選んだのと同じ理由）。
//
// **候補は探しに行かない** — cache / marketplace / 旧インストール領域の走査も version 名の
// 並べ替えによる選び直しもしない。それが本ガードの防ごうとしている失敗そのもので、探索を
// 足すと防御が防御対象を踏む。渡された handoff を canonical 化して自分の実体位置と比べるだけ
// にする。handoff が 1 つも無い直接起動（端末・テスト・CI の pin 実行）は止めない — 比較対象が
// 無い状態を不一致とみなすと、正規の直接起動が全部止まる。
//
// 判定不能は素通しではなく停止に倒す（fail-closed）。更新中の部分的な消失では、判定材料
// （別 plugin かどうかを言う manifest）そのものが壊れた領域の内側にある。
//
// entry として起動されたときだけ走らせる。この file は library としても import される
// （`work.mjs` の `recordWork` / `workStatus` は tests から直接 import される）ので、import 経路で
// 止めると shell 側の「bash で起動したときだけ効く」より広い範囲を殺す。判定は `process.argv[1]` と
// `import.meta.url` の**両方**を canonical 化して比べる（`ffGuardIsEntry`）。素の文字列比較にしない
// のは `mktemp -d` のように symlink を含む path で起動されると成立しないためで、片側だけを canonical
// 化しないのは `--preserve-symlinks-main` 下で `import.meta.url` が起動した綴りのまま残り、
// 「不一致 = import」と誤認してガードを丸ごと迂回できるためである。
//
// file 末尾の `main()` 起動も同じ `ffGuardIsEntry` を使う。判定の基準が割れると、symlink 成分を
// 含む絶対 path からの起動で「ガードは通るのに `main()` が一度も呼ばれない」= 出力なし・exit 0 の
// 黙った失敗になる。
//
// ESM の static import は巻き上げられるため、この block より下に書いた sibling module
// （`config.mjs` / `generate.mjs`）の評価はガードより先に起きる。これらの top-level は関数と
// 定数の定義だけで、project にも filesystem にも触れない。ガードが先に走ることを要求している
// のは entry 自身の文と `main()` の呼び出しで、そこは block の配置検査が固定する。
import { lstatSync as ffGuardLstat, readFileSync as ffGuardRead, realpathSync as ffGuardRealpath } from 'node:fs';
import { dirname as ffGuardDirname } from 'node:path';
import { fileURLToPath as ffGuardFromUrl } from 'node:url';
function ffGuardManifestField(file, key) {
  // symlink・非通常ファイル・読めないものは「確認できない」に倒す（除外の根拠にしない）。
  // `JSON.parse` が返すのは root object 直下のキーだけなので、`author` のような入れ子 object が
  // top-level の `name` より前にある manifest で `author.name` を掴む fail-open にならない。
  try {
    if (!ffGuardLstat(file).isFile()) return '';
    const value = JSON.parse(ffGuardRead(file, 'utf8'))[key];
    return typeof value === 'string' ? value : '';
  } catch { return ''; }
}
function ffGuardSelfPath(selfUrl) {
  // 自分の実体位置。`import.meta.url` は既定では realpath 済みだが、`--preserve-symlinks-main`
  // 下では起動した綴り（symlink）のまま渡ってくるので、ここで canonical 化する。
  try { return ffGuardRealpath(ffGuardFromUrl(selfUrl)); } catch { return ''; }
}
function ffGuardIsEntry(selfUrl) {
  // entry として起動されたか。両側を canonical 化して比べる。片側だけ canonical だと、
  // symlink のまま残った `import.meta.url` との不一致を import と誤認してガードを素通りする。
  const self = ffGuardSelfPath(selfUrl);
  let launched = '';
  try { launched = process.argv[1] ? ffGuardRealpath(process.argv[1]) : ''; } catch { launched = ''; }
  return self !== '' && launched === self;
}
function ffGuardAssertPluginRoot(selfUrl) {
  const emit = line => process.stderr.write(`${line}\n`);
  const self = ffGuardSelfPath(selfUrl);
  if (!self) { emit('❌ 起動したスクリプトの実体位置を取得できません'); return false; }
  if (!ffGuardIsEntry(selfUrl)) return true;
  let dir = '';
  try { dir = ffGuardRealpath(ffGuardDirname(self)); } catch { dir = ''; }
  if (!dir) { emit(`❌ 起動したスクリプトのdirectoryを解決できません: ${self}`); return false; }
  let scripts = '', root = '';
  try { scripts = ffGuardRealpath(ffGuardDirname(dir)); root = ffGuardRealpath(ffGuardDirname(scripts)); } catch { root = ''; }
  if (!root) { emit(`❌ 自分のplugin rootを解決できません: ${dir}`); return false; }
  // 起動した綴りがsymlinkなら止める。ESM loaderは実体まで解決してから読むので、期待root内の
  // symlinkから別checkoutの実体を実行でき、「実体位置とhandoffの照合」の前提が崩れる。
  let launchedIsLink = false;
  try { launchedIsLink = ffGuardLstat(process.argv[1]).isSymbolicLink(); } catch { launchedIsLink = false; }
  if (launchedIsLink) {
    emit('❌ ff-dev-toolkit更新後にこのskillを再呼び出してください（起動したスクリプトがsymlinkです）');
    emit(`   起動したスクリプト: ${self}`);
    emit('   symlinkは期待rootの内側から別領域の実体を指せるため、実体位置の照合が成立しません。');
    emit('   別のインストール領域へ切り替えて実行しないこと — version混在と未リリースWIPの実行になります。');
    emit('   cacheや別checkoutを探さず、実体のパスで起動してください。');
    return false;
  }
  let used = '';
  const skipped = [];
  for (const name of ['FF_DEV_TOOLKIT_ROOT', 'CLAUDE_PLUGIN_ROOT', 'GROK_PLUGIN_ROOT']) {
    const value = process.env[name];
    if (!value) continue;
    let canonical = '';
    try { canonical = ffGuardRealpath(value); } catch { canonical = ''; }
    // 正規形は plugin root だが、scripts/ を直接指す綴りも正規に受理されている
    // （templates/codex-review.sh の canonical_toolkit_root が両方を受ける）。同じ実体を
    // 指している限り一致として扱う。
    if (canonical && (canonical === root || canonical === scripts)) { used ||= name; continue; }
    // 実在する別 plugin の root は我々への handoff ではない（別 plugin 経由の正規呼び出しまで
    // 殺さない）。ただし除外できるのは「manifestが通常ファイルとして読めて、名前が別だと確認
    // できた」ときだけにする。消えているroot も、読めないmanifest も、誰のものか判定できない
    // 点は同じ。
    const other = canonical ? ffGuardManifestField(`${canonical}/.claude-plugin/plugin.json`, 'name') : '';
    if (other && other !== 'ff-dev-toolkit') { skipped.push(`${name}=別plugin(${other})`); continue; }
    emit('❌ ff-dev-toolkit更新後にこのskillを再呼び出してください（plugin rootが固定値と一致しません）');
    emit(`   起動したスクリプト: ${self}`);
    emit(`   このスクリプトのplugin root: ${root}`);
    emit(`   hostが渡したroot（${name}）: ${value}`);
    if (!canonical) emit('   不一致の内容: 指しているdirectoryが実在しません（plugin rootが消えています）');
    else if (!other) emit('   不一致の内容: 指す先のplugin manifestを読めず、誰のrootか判定できません（判定不能は停止に倒します）');
    else emit('   不一致の内容: このスクリプトは別のインストール領域の実体です');
    emit('   別のインストール領域へ切り替えて実行しないこと — version混在と未リリースWIPの実行になります。');
    emit('   cacheや別checkoutを探さず、pluginを再導入してからskillを呼び直してください。');
    return false;
  }
  // provenance（実体 path と version の 1 行）は「想定外の場所から起動された」ことを agent にも
  // ログを読む人にも見せて診断コストを下げる。照合を飛ばした handoff も理由付きで出す — 渡って
  // いた事実を「なし・直接起動」と報告すると、診断価値を損ない事実とも食い違う。node entry の
  // 出力契約は stdout の JSON なので、この情報行は stderr にだけ書く。
  const version = ffGuardManifestField(`${root}/.claude-plugin/plugin.json`, 'version') || 'version不明';
  const handoff = used || 'なし・直接起動';
  emit(`ℹ️  ff-dev-toolkit ${version} — 実行実体: ${self}（handoff: ${handoff}${skipped.length ? ` / 照合対象外: ${skipped.join(' ')}` : ''}）`);
  return true;
}
if (!ffGuardAssertPluginRoot(import.meta.url)) process.exit(2);
// ff-dev-toolkit-node-root-guard:end
import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import { execFileSync } from 'node:child_process';
import { loadConfig, relativePath, projectPath } from './config.mjs';

const hash = value => crypto.createHash('sha256').update(value).digest('hex');
const stringify = value => `${JSON.stringify(value, null, 2)}\n`;
const run = (root, command, args, input) => execFileSync(command, args, {
  cwd: root, encoding: 'utf8', input, stdio: ['pipe', 'pipe', 'pipe'], maxBuffer: 16 * 1024 * 1024,
  timeout: 60_000, env: { ...process.env, GH_PROMPT_DISABLED: '1', GIT_TERMINAL_PROMPT: '0' },
}).trim();
const pages = value => JSON.parse(value).flat();
const marker = task => `<!-- asdd-task:${task} -->`;
const eventMarker = event => `<!-- asdd-event:${event} -->`;
const listText = items => items.length ? items.map(item => `- ${item}`).join('\n') : 'なし';
const saveState = (root, state) => {
  const file = projectPath(root, '.asdd/local/work.json');
  fs.mkdirSync(path.dirname(file), { recursive: true });
  const temporary = `${file}.${process.pid}.tmp`;
  fs.writeFileSync(temporary, stringify(state), { flag: 'wx' });
  fs.renameSync(temporary, file);
};
function readState(root) {
  const file = projectPath(root, '.asdd/local/work.json');
  return fs.existsSync(file) ? JSON.parse(fs.readFileSync(file, 'utf8')) : { schemaVersion: 1, tasks: {} };
}
export function validateRecord(record) {
  if (!record || typeof record !== 'object' || Array.isArray(record)) throw new Error('Record must be an object');
  const fields = ['taskId', 'title', 'summary', 'doneWhen', 'decisions', 'openItems', 'nextSteps', 'files'];
  if (Object.keys(record).some(key => !fields.includes(key))) throw new Error('Unknown record field');
  if (!/^[a-zA-Z0-9][a-zA-Z0-9_-]{0,79}$/.test(record.taskId ?? '')) throw new Error('Use a stable taskId (letters, numbers, hyphen, underscore)');
  for (const field of ['title', 'summary']) if (typeof record[field] !== 'string' || !record[field].trim()) throw new Error(`${field} is required`);
  for (const field of ['doneWhen', 'decisions', 'openItems', 'nextSteps', 'files']) {
    if (!Array.isArray(record[field]) || record[field].some(item => typeof item !== 'string' || !item.trim())) throw new Error(`${field} must be an array of strings`);
  }
  if (!record.doneWhen.length) throw new Error('Agreed completion conditions are required');
  if (new Set(record.files).size !== record.files.length) throw new Error('Duplicate artifact path');
  record.files.forEach(relativePath);
  // JSON key order can change when another conversation recreates the same
  // record. Identity follows the field values, not the serializer's ordering.
  return Object.fromEntries(fields.map(field => [field, record[field]]));
}
function settings(root) {
  const config = loadConfig(root);
  if (!config?.github) throw new Error('GitHub recording destination is not configured');
  return config.github;
}
const trustedRecord = (entry, actor) => entry.user?.id === actor.id
  || ['OWNER', 'MEMBER', 'COLLABORATOR'].includes(entry.author_association);
function recordingActor(command) {
  const actor = JSON.parse(command('gh', ['api', 'user']));
  if (!Number.isSafeInteger(actor.id) || actor.id <= 0) throw new Error('Cannot verify the GitHub recording account');
  return actor;
}
function issueFor(repository, taskId, command, actor) {
  const issues = pages(command('gh', ['api', `repos/${repository}/issues?state=all&per_page=100`, '--paginate', '--slurp']));
  const matches = issues.filter(issue => !issue.pull_request && trustedRecord(issue, actor) && issue.body?.includes(marker(taskId)));
  if (matches.length > 1) throw new Error('Duplicate task records: reconcile the existing issues before continuing');
  return matches[0] ?? null;
}
function commentsFor(repository, number, command) {
  return pages(command('gh', ['api', `repos/${repository}/issues/${number}/comments?per_page=100`, '--paginate', '--slurp']));
}
function historyCommit(event, command) {
  const candidates = command('git', ['log', '--no-show-signature', '--format=%H', '--fixed-strings', `--grep=ASDD event ${event}`, 'HEAD']).split('\n').filter(Boolean);
  const matches = candidates.filter(commit => command('git', ['show', '--no-show-signature', '-s', '--format=%B', commit]).split('\n').includes(`ASDD event ${event}`));
  if (matches.length > 1) throw new Error('Multiple commits for this recording event; reconcile history before continuing');
  return matches[0] ?? null;
}
function pendingHistory(record, event, command, defaultBranch) {
  const branch = command('git', ['symbolic-ref', '--short', 'HEAD']);
  const refs = command('git', ['ls-remote', '--heads', 'origin', `refs/heads/${branch}`, `refs/heads/${defaultBranch}`]);
  const remote = new Map(refs.split('\n').filter(Boolean).map(line => {
    const [sha, ref] = line.split(/\s+/); return [ref, sha];
  }));
  const base = remote.get(`refs/heads/${branch}`) ?? remote.get(`refs/heads/${defaultBranch}`);
  let head;
  try { head = command('git', ['rev-parse', '--verify', 'HEAD']); } catch { return; } // New, empty repository.
  if (base) command('git', ['cat-file', '-e', `${base}^{commit}`]); // Do not fetch during preview/check.
  const commits = command('git', ['rev-list', head, ...(base ? ['--not', base] : [])]).split('\n').filter(Boolean);
  // The sole permitted unpublished commit is a retry of this exact event.
  if (commits.length > 1) throw new Error('Unpublished history requires separate review before saving artifacts');
  for (const commit of commits) {
    const message = command('git', ['show', '--no-show-signature', '-s', '--format=%B', commit]);
    const parents = command('git', ['show', '--no-show-signature', '-s', '--format=%P', commit]).split(' ').filter(Boolean);
    const files = command('git', ['diff-tree', '--root', '--no-commit-id', '--name-only', '-r', '-z', commit]).split('\0').filter(Boolean);
    if (!message.split('\n').includes(`ASDD event ${event}`) || parents.length > 1 || files.some(file => !record.files.includes(file))) {
      throw new Error('Unpublished history outside this recording event; review and synchronize it separately');
    }
  }
}
function preflight(root, record, github, command) {
  if (!github.recordIssues) throw new Error('Issue recording is disabled');
  const fileHashes = {};
  for (const file of record.files) {
    if (!github.allowedPaths.some(allowed => file === allowed || file.startsWith(`${allowed}/`))) throw new Error(`Artifact outside agreed save scope: ${file}`);
    if (file.split('/').some(part => part === '.git' || /^\.env(?:\.|$)/.test(part) || /^(?:id_rsa|id_ed25519)$/.test(part))) throw new Error(`Credential or Git-internal path is not an artifact: ${file}`);
    const target = projectPath(root, file);
    if (!fs.statSync(target).isFile()) throw new Error(`Artifact is not a file: ${file}`);
    fileHashes[file] = hash(fs.readFileSync(target));
  }
  const event = hash(JSON.stringify({ record, fileHashes, repository: github.repository }));
  if (github.saveHistory && record.files.length) {
    const origin = command('git', ['remote', 'get-url', 'origin']);
    const repository = origin.replace(/^git@github\.com:/, '').replace(/^https:\/\/github\.com\//, '').replace(/\.git$/, '');
    if (repository !== github.repository) throw new Error('Git origin does not match the agreed GitHub repository');
    const repo = JSON.parse(command('gh', ['repo', 'view', github.repository, '--json', 'isPrivate,defaultBranchRef']));
    const branch = command('git', ['symbolic-ref', '--short', 'HEAD']);
    if (github.branchPolicy === 'direct' && !repo.isPrivate) throw new Error('Direct history saving requires the agreed private repository');
    if (github.branchPolicy === 'pull-request' && branch === repo.defaultBranchRef.name) throw new Error('Use a work branch and the existing PR workflow');
    const staged = command('git', ['diff', '--cached', '--name-only', '-z']).split('\0').filter(Boolean);
    if (staged.length) {
      const prior = readState(root).tasks[record.taskId];
      if (prior?.event !== event || !prior.staging || staged.some(file => !record.files.includes(file)
        || command('git', ['rev-parse', `:${file}`]) !== prior.staging[file]
        || command('git', ['hash-object', '--', file]) !== prior.staging[file])) {
        throw new Error('Staged changes already exist; preserve them before recording');
      }
    }
    pendingHistory(record, event, command, repo.defaultBranchRef?.name ?? branch);
  }
  return event;
}
export function recordWork(root, record, { apply = false, command = (cmd, args, input) => run(root, cmd, args, input) } = {}) {
  record = validateRecord(record);
  const github = settings(root);
  const event = preflight(root, record, github, command);
  const body = `${marker(record.taskId)}\n${eventMarker(event)}\n\n## 現在地\n\n${record.summary}\n\n## 完成条件\n\n${listText(record.doneWhen)}\n\n## 決定\n\n${listText(record.decisions)}\n\n## 未決事項\n\n${listText(record.openItems)}\n\n## 成果物\n\n${listText(record.files)}\n\n## 次の作業\n\n${listText(record.nextSteps)}\n`;
  if (!apply) return { repository: github.repository, event, body, files: record.files, saveHistory: github.saveHistory, applied: false };
  const lock = projectPath(root, '.asdd/work.lock');
  fs.mkdirSync(path.dirname(lock), { recursive: true });
  const fd = fs.openSync(lock, 'wx');
  let state, progress;
  try {
    state = readState(root);
    const prior = state.tasks[record.taskId];
    progress = { issue: null, commit: null, pushed: false, ...(prior?.event === event ? prior : {}),
      event, status: 'pending', checkedAt: new Date().toISOString() };
    state.tasks[record.taskId] = progress;
    saveState(root, state);
    const actor = recordingActor(command);
    let issue = issueFor(github.repository, record.taskId, command, actor);
    if (!issue) {
      const url = command('gh', ['issue', 'create', '--repo', github.repository, '--title', record.title, '--body-file', '-'], body);
      const match = url.match(new RegExp(`^https://github\\.com/${github.repository.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')}/issues/(\\d+)$`));
      if (!match) throw new Error('Issue creation result is uncertain; inspect existing records before retry');
      issue = { number: Number(match[1]), html_url: url, body };
    } else {
      const comments = commentsFor(github.repository, issue.number, command);
      if (!issue.body?.includes(eventMarker(event)) && !comments.some(comment => trustedRecord(comment, actor) && comment.body?.includes(eventMarker(event)))) {
        command('gh', ['issue', 'comment', String(issue.number), '--repo', github.repository, '--body-file', '-'], body);
      }
    }
    progress.issue = issue.html_url; progress.status = 'issue-recorded'; saveState(root, state);
    if (github.saveHistory && record.files.length) {
      // Include only explicitly selected paths; never stage the whole working tree.
      progress.staging = Object.fromEntries(record.files.map(file => [file, command('git', ['hash-object', '--', file])]));
      saveState(root, state); // Recognize our own index entries after a failed commit hook.
      command('git', ['add', '--', ...record.files]);
      const staged = command('git', ['diff', '--cached', '--name-only', '-z']).split('\0').filter(Boolean);
      if (staged.some(file => !record.files.includes(file))) throw new Error('Unexpected staged files; do not commit unrelated work');
      if (staged.length) {
        command('git', ['commit', '-m', `chore: #${issue.number} ${record.title.replace(/[\r\n]/g, ' ')}`, '-m', `ASDD event ${event}`]);
        progress.commit = command('git', ['rev-parse', 'HEAD']);
        progress.pushed = false;
        saveState(root, state);
        const message = command('git', ['show', '--no-show-signature', '-s', '--format=%B', progress.commit]);
        if (!message.split('\n').includes(`ASDD event ${event}`)) {
          throw new Error('Commit created but its ASDD event marker was changed; history is unsynced. Reconcile the commit message with the existing hook policy before retrying');
        }
      }
      // HEAD may have advanced since a successful save. Recover this event's
      // actual commit, including when the local receipt was lost.
      progress.commit = historyCommit(event, command);
      progress.history = progress.commit ? 'saved' : 'unchanged';
      progress.pushed = false;
      saveState(root, state);
      if (progress.commit) {
        const branch = command('git', ['symbolic-ref', '--short', 'HEAD']);
        const repo = JSON.parse(command('gh', ['repo', 'view', github.repository, '--json', 'isPrivate,defaultBranchRef']));
        pendingHistory(record, event, command, repo.defaultBranchRef?.name ?? branch);
        command('git', ['push', 'origin', `HEAD:refs/heads/${branch}`]);
        progress.pushed = true;
        const commitMarker = `<!-- asdd-commit:${event}:${progress.commit} -->`;
        const comments = commentsFor(github.repository, issue.number, command);
        if (!comments.some(comment => trustedRecord(comment, actor) && comment.body?.includes(commitMarker))) {
          command('gh', ['issue', 'comment', String(issue.number), '--repo', github.repository, '--body-file', '-'], `${commitMarker}\n\n履歴保存: https://github.com/${github.repository}/commit/${progress.commit}\n\n${github.branchPolicy === 'pull-request' ? '作業ブランチへ保存済み。PR・マージ・公開は別途確認します。' : '合意した保存先へ同期済み。公開・送信は別途確認します。'}\n`);
        }
      }
    }
    progress.status = 'synced'; saveState(root, state);
    return progress;
  } catch (error) {
    if (progress) { progress.status = 'unsynced'; saveState(root, state); }
    // Child-process stderr can contain credentials. Report stage and exit status, not raw command output.
    const reason = error.status !== undefined ? `External operation failed (exit ${error.status})` : error.message;
    return { ...progress, status: 'unsynced', error: reason };
  } finally { fs.closeSync(fd); fs.unlinkSync(lock); }
}
export function workStatus(root, taskId, { command = (cmd, args, input) => run(root, cmd, args, input) } = {}) {
  if (!/^[a-zA-Z0-9][a-zA-Z0-9_-]{0,79}$/.test(taskId)) throw new Error('Invalid taskId');
  const github = settings(root), actor = recordingActor(command), issue = issueFor(github.repository, taskId, command, actor);
  return { checkedAt: new Date().toISOString(), repository: github.repository,
    issue: issue ? { url: issue.html_url, state: issue.state, title: issue.title, body: issue.body, updatedAt: issue.updated_at } : null,
    comments: issue ? commentsFor(github.repository, issue.number, command).map(c => ({ body: c.body, createdAt: c.created_at,
      author: { id: c.user?.id ?? null, login: c.user?.login ?? null, association: c.author_association ?? null },
      trusted: trustedRecord(c, actor) })) : [],
    local: readState(root).tasks[taskId] ?? null,
  };
}
function main(args) {
  let root = process.cwd(), record, task, apply = false;
  for (let i = 0; i < args.length; i++) {
    const arg = args[i];
    if (['--root', '--record', '--status'].includes(arg)) {
      if (!args[i + 1] || args[i + 1].startsWith('--')) throw new Error(`${arg} requires a value`);
      const value = args[++i];
      if (arg === '--root') root = value; else if (arg === '--record') record = value; else task = value;
    } else if (arg === '--apply') apply = true;
    else throw new Error(`Unknown argument: ${arg}`);
  }
  if ((!record && !task) || (record && task) || (task && apply)) throw new Error('Use --record file [--apply] or --status taskId');
  root = fs.realpathSync(root);
  const result = task ? workStatus(root, task) : recordWork(root, JSON.parse(fs.readFileSync(record, 'utf8')), { apply });
  process.stdout.write(stringify(result));
  return result.status === 'unsynced' ? 1 : 0;
}
// 直接起動の判定は冒頭のガードと同じ `ffGuardIsEntry`（両側 canonical）を使う。素の文字列比較に
// 戻すと、symlink 成分を含む path から起動したときにガードだけが通って `main()` が呼ばれず、
// 出力なし・exit 0 の黙った失敗になる。
if (ffGuardIsEntry(import.meta.url)) {
  try { process.exitCode = main(process.argv.slice(2)); }
  catch (error) { process.stderr.write(`ASDD: ${error.status !== undefined ? 'External operation failed; no success was confirmed' : error.message}\n`); process.exitCode = 1; }
}
