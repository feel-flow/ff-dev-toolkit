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
import { plan, apply, check } from './generate.mjs';
import { validateConfig } from './config.mjs';

export function main(args) {
  let root = process.cwd(), input, adoption, mode = 'plan';
  for (let i = 0; i < args.length; i++) {
    const arg = args[i];
    if (arg === '--root' || arg === '--config' || arg === '--adopt') {
      if (!args[i + 1] || args[i + 1].startsWith('--')) throw new Error(`${arg} requires a value`);
      if (arg === '--root') root = args[++i]; else if (arg === '--adopt') adoption = args[++i]; else input = args[++i];
    } else if (arg === '--apply' || arg === '--check') {
      if (mode !== 'plan') throw new Error('Choose --apply or --check');
      mode = arg.slice(2);
    } else throw new Error(`Unknown argument: ${arg}`);
  }
  root = fs.realpathSync(root);
  if (mode === 'check') {
    if (input || adoption) throw new Error('--check reads existing config; do not pass --config or --adopt');
    const result = check(root);
    process.stdout.write(`${JSON.stringify(result, null, 2)}\n`);
    return result.errors.length ? 1 : 0;
  }
  if (!input) throw new Error('Provide agreed settings with --config; default operation previews changes without writing');
  const config = validateConfig(JSON.parse(fs.readFileSync(input, 'utf8')));
  const options = { adopt: adoption ? JSON.parse(fs.readFileSync(adoption, 'utf8')) : {} };
  if (mode === 'apply') {
    process.stdout.write(`${JSON.stringify(apply(root, config, options), null, 2)}\n`);
    return 0;
  }
  const result = plan(root, config, options);
  process.stdout.write(`${JSON.stringify({ changes: result.changes, conflicts: result.conflicts, retained: result.retained, adopted: result.adopted }, null, 2)}\n`);
  return result.conflicts.length ? 1 : 0;
}
// 直接起動の判定は冒頭のガードと同じ `ffGuardIsEntry`（両側 canonical）を使う。素の文字列比較に
// 戻すと、symlink 成分を含む path から起動したときにガードだけが通って `main()` が呼ばれず、
// 出力なし・exit 0 の黙った失敗になる。
if (ffGuardIsEntry(import.meta.url)) {
  try { process.exitCode = main(process.argv.slice(2)); }
  catch (error) { process.stderr.write(`ASDD: ${error.message}\n`); process.exitCode = 1; }
}
