/**
 * `playbook/archive/` の保全本文内リンクの基準ずれを検査するゲート（Issue #288 穴 2）。
 *
 * `/ace-refine` は原文を archive へ **verbatim 保全**する。原文は live 側にあった時点の
 * 相対リンク `./<category>.md#ace-xxx`（live では自ファイル参照）を持つため、archive へ
 * 運ばれると基準がずれる。archive から辿ると (a) ファイル不在で 404、(b) anchor 不在で
 * 先頭に着地、(c) **live ではなくアーカイブ済みの複製に着地する**（リンクチェッカーには
 * 映らず、読者は live に着いたつもりで古い複製を読む）のいずれかになる。
 *
 * verbatim 保全が必須条件なので**リンク自体は書き換えられない**。したがって唯一 actionable な
 * 対応は「archive ファイル冒頭に読み替えの注記を置く」であり、本スクリプトはその注記の
 * 存在を機械的に強制する:
 *
 *   archive ファイルに `](./...)` 形式のリンクが 1 件以上あるなら、冒頭 **Parent ブロック内**
 *   の注記が必須。加えて同一ファイル内の `<a id>` 重複を拒否する（Issue #492）。
 *
 * リンクが 0 件のファイルには注記を強制しない（不要な定型文を増やさない）。
 * 走査対象は `playbook/archive/` 直下の *.md のみ（非再帰）。
 *
 * 実行例: npx --yes tsx scripts/ace/check-archive-links.ts docs/08-knowledge/PLAYBOOK.md
 */
import * as fs from "node:fs";
import * as path from "node:path";
import { fileURLToPath } from "node:url";

const EXIT_OK = 0;
const EXIT_VIOLATION = 1;
const EXIT_USAGE_ERROR = 2;

/**
 * 冒頭注記の判定に使う固定文言。`/ace-refine` SKILL.md R3-a の注記テンプレートと
 * PLAYBOOK.md §運用ルールの文言に一致させる（テンプレートを変えるなら両方を同時に変える）。
 */
export const LIVE_BASIS_NOTE_MARKER = "保全本文内の相対リンクは live 基準";

/**
 * Markdown リンクのうち `./` で始まるものだけを数える。
 * コードスパン内の `` `./x.md#ace-y` `` は Markdown リンクではないのでマッチしない
 * — これは重要で、冒頭注記そのものが読み替え例として `./<category>.md#ace-xxx` を
 * 含むため、コードスパンまで数えると「注記を入れたファイルは常に違反」という
 * 自己矛盾したゲートになる。
 * `../` で始まるリンクは archive 基準で正しいので対象外。
 */
export function countRelativeEntryLinks(content: string): number {
  const matches = content.match(/\]\(\.\/[^)]*\)/gu);
  return matches ? matches.length : 0;
}

/**
 * archive ファイル冒頭の Parent ブロック（`> **Parent**` から始まる連続引用）を返す。
 * ファイル全体の includes だと、エントリ本文や後段の引用にマーカーが偶然含まれても
 * 冒頭注記ありと誤判定する（Issue #492）。
 * Parent ブロックが無ければ null。
 */
export function extractOpeningParentBlock(content: string): string | null {
  const lines = content.split("\n");
  let headerEnd = lines.length;
  for (let i = 0; i < lines.length; i++) {
    if (
      lines[i].trim() === "---" ||
      /^<a\s+id="/u.test(lines[i]) ||
      /^###\s+ACE-/u.test(lines[i])
    ) {
      headerEnd = i;
      break;
    }
  }
  let start = -1;
  for (let i = 0; i < headerEnd; i++) {
    if (/^>\s*\*\*Parent\*\*/u.test(lines[i])) {
      start = i;
      break;
    }
  }
  if (start < 0) {
    return null;
  }
  const collected: string[] = [];
  for (let i = start; i < headerEnd; i++) {
    if (lines[i].startsWith(">")) {
      collected.push(lines[i]);
      continue;
    }
    break;
  }
  return collected.join("\n");
}

/**
 * 冒頭注記（読み替えの案内）が **Parent ブロック内** に存在するか。
 * ファイル全体を走査しない（本文への偶然一致を注記と見なさない）。
 */
export function hasLiveBasisNote(content: string): boolean {
  const parent = extractOpeningParentBlock(content);
  return parent !== null && parent.includes(LIVE_BASIS_NOTE_MARKER);
}

const HTML_ID_ATTRIBUTE_PATTERN = /<a\s+id="([^"]+)"/giu;

/**
 * 同一ファイル内の `<a id>` 重複を検出する（Issue #492）。
 * append 型 archive へ同じエントリを二度保全すると、存在検証は緑のまま
 * アンカーが分裂する（ACE-490-2）。
 */
export function findDuplicateAnchors(content: string): string[] {
  const counts = new Map<string, number>();
  for (const match of content.matchAll(HTML_ID_ATTRIBUTE_PATTERN)) {
    const id = match[1];
    counts.set(id, (counts.get(id) ?? 0) + 1);
  }
  return [...counts.entries()]
    .filter(([, count]) => count > 1)
    .map(([id]) => id)
    .sort();
}

/**
 * PLAYBOOK.md と同階層の `playbook/archive/` にあるファイルを検出する。
 * ディレクトリが無い場合は空配列（＝`/ace-refine` 未実行）を返す。
 * `check-category-size` の discoverPlaybookSubfiles と同じく**非再帰**で走査する。
 */
export function discoverArchiveFiles(playbookPath: string): string[] {
  const archiveDir = path.join(path.dirname(playbookPath), "playbook", "archive");
  if (!fs.existsSync(archiveDir) || !fs.statSync(archiveDir).isDirectory()) {
    return [];
  }
  return fs
    .readdirSync(archiveDir)
    .filter((entry: string) => entry.endsWith(".md"))
    .map((entry: string) => path.join(archiveDir, entry))
    .sort();
}

function resolvePlaybookPath(argv: readonly string[]): string | undefined {
  const fromArg = argv[2];
  if (fromArg && fromArg.trim() !== "") {
    return path.resolve(fromArg);
  }
  const fromEnv = process.env.ACE_PLAYBOOK_PATH;
  if (fromEnv && fromEnv.trim() !== "") {
    return path.resolve(fromEnv);
  }
  return undefined;
}

export function main(): number {
  const playbookPath = resolvePlaybookPath(process.argv);
  if (!playbookPath) {
    console.error(
      "引数に PLAYBOOK.md のパスを渡すか、ACE_PLAYBOOK_PATH を設定してください。",
    );
    return EXIT_USAGE_ERROR;
  }

  let archiveFiles: string[];
  try {
    archiveFiles = discoverArchiveFiles(playbookPath);
  } catch (error: unknown) {
    const message = error instanceof Error ? error.message : String(error);
    console.error(`読み込み失敗: playbook/archive/ の走査に失敗しました: ${message}`);
    return EXIT_USAGE_ERROR;
  }

  console.log(`Playbook: ${playbookPath}`);
  if (archiveFiles.length === 0) {
    console.log("playbook/archive/ が無いため検査対象なし（/ace-refine 未実行）。");
    return EXIT_OK;
  }
  console.log(`archive ファイル: ${String(archiveFiles.length)} 件`);

  // 最初の違反で止めず全件を報告する。1 件目を直したら 2 件目が出る往復を作らない。
  const noteViolations: string[] = [];
  const anchorViolations: string[] = [];

  for (const filePath of archiveFiles) {
    let content: string;
    try {
      content = fs.readFileSync(filePath, "utf8");
    } catch (error: unknown) {
      const message = error instanceof Error ? error.message : String(error);
      console.error(`読み込み失敗: ${filePath}: ${message}`);
      return EXIT_USAGE_ERROR;
    }
    const linkCount = countRelativeEntryLinks(content);
    const noted = hasLiveBasisNote(content);
    const duplicateIds = findDuplicateAnchors(content);
    console.log(
      `  ${filePath}: ./ リンク ${String(linkCount)} 件 / 冒頭注記 ${noted ? "あり" : "なし"}` +
        (duplicateIds.length > 0
          ? ` / 重複 <a id> ${duplicateIds.join(", ")}`
          : ""),
    );
    if (linkCount > 0 && !noted) {
      noteViolations.push(`${filePath}（./ リンク ${String(linkCount)} 件）`);
    }
    if (duplicateIds.length > 0) {
      anchorViolations.push(`${filePath}（${duplicateIds.join(", ")}）`);
    }
  }

  if (noteViolations.length > 0) {
    console.error(
      `⚠ 保全本文内に \`./\` 相対リンクがあるのに冒頭注記が無い archive ファイルがあります。原文は verbatim 保全のためリンクを書き換えられないので、代わりに「${LIVE_BASIS_NOTE_MARKER}」の注記をファイル冒頭（Parent ブロック内）へ追加してください（テンプレートは /ace-refine SKILL.md R3-a）。注記が無いと、読者は live に着いたつもりでアーカイブ済みの古い複製を読みます:\n- ` +
        noteViolations.join("\n- "),
    );
  }
  if (anchorViolations.length > 0) {
    console.error(
      `⚠ archive ファイル内で同一の \`<a id>\` が複数回出現しています。append 型 archive への保全は「存在」ではなく「一意」で検証してください（ACE-490-2）。重複アンカーは着地が分裂し、後段の存在検証を緑のまま通します:\n- ` +
        anchorViolations.join("\n- "),
    );
  }
  if (noteViolations.length > 0 || anchorViolations.length > 0) {
    return EXIT_VIOLATION;
  }

  console.log("✓ archive の保全本文内リンクはすべて注記で担保されています。");
  console.log("✓ archive の <a id> アンカーは各ファイル内で一意です。");
  return EXIT_OK;
}

/**
 * このモジュールが CLI として直接実行されたときだけ true。
 * argv の部分一致（`.includes(...)` / `.includes(".test.")`）だとディレクトリ名や
 * 別名スクリプトで silent no-op / 誤爆するため、解決済みパスの完全一致で判定する。
 */
export function isDirectExecution(
  moduleUrl: string,
  argvPath: string | undefined,
): boolean {
  if (!argvPath) return false;
  const modulePath = fileURLToPath(moduleUrl);
  try {
    return (
      fs.realpathSync.native(modulePath) ===
      fs.realpathSync.native(path.resolve(argvPath))
    );
  } catch {
    return path.resolve(modulePath) === path.resolve(argvPath);
  }
}

// 直接実行（tsx 経由の CLI）のときのみ自動実行する。テストから import したときは
// 副作用なく関数だけを取り込めるようにする。
if (isDirectExecution(import.meta.url, process.argv[1])) {
  process.exitCode = main();
}
