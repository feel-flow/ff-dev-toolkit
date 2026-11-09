/**
 * live 参照の走査（Issue `#2708`）。`/ace-refine` の Archive 候補のうち、いま live の本文から
 * ID かアンカーで言及されているものを、参照元（パス:行）付きで返す。
 *
 * 背景: Archive 候補は helpful=0 かつ git 参照 stale で選ばれ、live の本文が引用・リンクして
 * いるかは見ていなかった。PR `#2705` は coding の候補 107 件のうち 9 件を「live から参照あり」として
 * 手作業で外し、マージ後の develop でもレポートは同じ 9 件を候補に並べ続けた。
 *
 * 走査面: リポジトリの `docs/`・`plugins/`・`scripts/` と、live の PLAYBOOK ファイル群（PLAYBOOK.md と
 * playbook/ のカテゴリファイル）の**追跡ファイル**（作業ツリーの内容）。playbook の退避先
 * （PLAYBOOK_ARCHIVE_DIR_NAMES）は外す。未追跡のファイルは読まない。
 *
 * 読み方: `git grep` に候補 ID を固定文字列・大文字小文字無視（アンカー `#ace-…` を拾う）・単語境界で
 * 渡し、一致した行だけを受け取る。下の針のために、同じ走査面のエントリ見出しの行（`### ACE-`）も
 * 1 本の正規表現で拾う（全エントリ ID を照合語にすると native Windows で 1 回 3 分かかる）。走査面の全ファイルを KnowledgeReadBoundary で読むと、native Windows
 * では 1 ファイルごとに ACL 検査のプロセスが立ち、数千ファイルに対して実用にならない。git grep は
 * 追跡されたパスだけを読み、symlink を辿らない（2026-11-08 に git 2.50.1 で実測: リポジトリ外を指す追跡
 * symlink の先にある一致は出力されない）。レポートへ出すのはパスと行番号だけで、本文は出さない。
 * 文脈（エントリの範囲・索引行・Changelog 節）は本文から判定する。playbook ファイルは呼び出し側が
 * KnowledgeReadBoundary で読んだ本文を使い、playbook 以外の Markdown は一致した行を含むファイルだけを
 * 呼び出し側の読み口（main では同じ境界）で読む。どちらもフェンスと HTML コメントを空白化してから
 * 見出しを拾う（その中の例示の `## Changelog` を節の始まりにすると、後ろの本物の参照を捨てる）。
 * playbook 以外の Markdown に閉じていないフェンスか `<!--` があるときは、そのファイルでは Changelog 節の
 * 除外をやめて全部数える（空白化が EOF まで及ぶと Changelog 節が閉じず、後ろの参照を黙って捨てるため。
 * playbook ファイルの未閉フェンスは main が先に拒否する）。境界越しの読み込みは native Windows で
 * 1 ファイルごとに ACL 検査のプロセスが立つので、読むのは一致した Markdown だけにする。
 *
 * 参照に数えない言及:
 * - エントリ自身のブロック（見出し・アンカー・本文）と、どのファイルでも ID の定義行
 *   （行頭の `### ACE-x:` / `<a id="ace-x"></a>`）
 * - PLAYBOOK.md の索引行（セルの 1 つがその ID そのものの表行）
 * - `## Changelog`（`## 変更履歴`）節と `CHANGELOG.md`
 * - `legacy-format-allowlist.txt`（archive 時に ID を消す前提の台帳。数えると旧形式のエントリが
 *   永久に archive できなくなる）
 * テストの fixture や評価データが ID を例に使っているだけの言及は数える。過剰採用は「除外枠に参照元
 * 付きで 1 件余計に出る」だけで、採用漏れは使われている知見の archive を生む — 安全側は過剰採用
 * （collectMergeTargets と同じ判断）。
 *
 * 針が当たらない入力の既定は赤（docs/04-quality/TESTING.md「針が当たらない入力の既定」）:
 * - git を起動できない・rc が 0/1 以外・stderr に出力・出力を解釈できない → 走査不能として throw
 * - live のエントリ見出しのうち走査で見えなかったものが 1 件でもある → 走査面・作業ディレクトリ・照合の
 *   取り違え、またはカテゴリファイルの一部が走査から漏れた（未追跡・`-I` に飛ばされた等）として throw。
 *   見出しは live の playbook にあるので、正しく走査できていれば必ず当たる。候補だけでなく全エントリの
 *   見出しを見るのは、候補を含まないカテゴリファイルが漏れても、その中から候補へのリンクが黙って
 *   消えるため（全体の件数で見ると、他のファイルが当たることで通ってしまう）
 */
import { spawnSync } from "node:child_process";
import * as fs from "node:fs";
import * as path from "node:path";
import {
  ACE_ENTRY_ID_SOURCE,
  ENTRY_ANCHOR_LINE_PATTERN,
  ENTRY_HEADING_ID_PATTERN,
  INDEX_ROW_ID_CELL_PATTERN,
  PLAYBOOK_ARCHIVE_DIR_NAMES,
  blankCodeRegions,
  blankFencedCodeBlocks,
  blankHtmlBlockComments,
  findHtmlCommentSpans,
} from "./check-category-size";

/** 走査不能の throw に付ける接頭辞。main の catch がこれで git 由来の他のエラーと見分ける。 */
export const LIVE_SCAN_ERROR_PREFIX = "live 参照の走査に失敗しました";

/** リポジトリ直下からの走査面（Issue `#2708` の定義）。live の PLAYBOOK ファイル群は別に足す。 */
export const LIVE_SCAN_ROOTS: readonly string[] = ["docs", "plugins", "scripts"];

/** 変更履歴として読む節の見出し（レベル 2）。ここに入る言及は参照に数えない。 */
const CHANGELOG_SECTION_PATTERN = /^##\s+(?:changelog|変更履歴)(?![A-Za-z])/iu;
/** 節を区切る見出し（レベル 1〜2）。エントリの範囲と Changelog 節をここで閉じる。 */
const SECTION_BREAK_PATTERN = /^#{1,2}\s/u;
const CHANGELOG_FILE_PATTERN = /^changelog\.md$/iu;
const LEGACY_FORMAT_ALLOWLIST_FILE = "legacy-format-allowlist.txt";
/** 行中の ID 形のトークン。認識の源は ACE_ENTRY_ID_SOURCE（他スクリプトと同じ）で、大小は問わない。 */
const MENTION_TOKEN_SOURCE = String.raw`(?<!\w)(?:${ACE_ENTRY_ID_SOURCE})`;

export type GitRunResult = Readonly<{
  readonly status: number | null;
  readonly stdout: string;
  readonly stderr: string;
  readonly error?: Error;
}>;

/** git の呼び出し口（テストから差し替える）。`repoDir` は `git -C` の引数。 */
export type GitRunner = (repoDir: string, args: readonly string[], input?: string) => GitRunResult;

/**
 * 既定の git 呼び出し。`readGitLog` と同じく GIT_* 環境変数を除く（git hook 経由の実行で
 * GIT_DIR を継承すると別リポジトリを走査する）。
 */
export const runGit: GitRunner = (repoDir, args, input) => {
  const env: Record<string, string> = {};
  for (const [key, value] of Object.entries(process.env)) {
    if (value !== undefined && !key.startsWith("GIT_")) {
      env[key] = value;
    }
  }
  const result = spawnSync("git", ["-C", repoDir, ...args], {
    encoding: "utf8",
    input: input ?? "",
    env,
    maxBuffer: 64 * 1024 * 1024,
    windowsHide: true,
  });
  return {
    status: result.status,
    stdout: result.stdout ?? "",
    stderr: result.stderr ?? "",
    ...(result.error ? { error: result.error } : {}),
  };
};

/** git grep の一致行（`-n -z --full-name`）。`file` はリポジトリ直下からの POSIX 区切りのパス。 */
export type GrepLine = Readonly<{ readonly file: string; readonly line: number; readonly text: string }>;

/** live 参照の参照元。`line` は 1 始まり。 */
export type LiveReferenceSource = Readonly<{ readonly file: string; readonly line: number }>;

function firstLine(text: string): string {
  return text.trim().split("\n", 1)[0] ?? "";
}

/** ID の一覧を先頭 10 件まで並べ、残りは件数で畳む（カテゴリファイルが丸ごと漏れると数百件になる）。 */
function listHead(ids: readonly string[]): string {
  const shown = ids.slice(0, 10).join(", ");
  return ids.length > 10 ? `${shown} ほか ${String(ids.length - 10)} 件` : shown;
}

function failScan(what: string, detail: string): never {
  throw new Error(`${LIVE_SCAN_ERROR_PREFIX}（${what}）: ${detail}`);
}

/**
 * git の結果を検査して stdout を返す。`allowNoMatch` は git grep の rc=1（0 件一致）だけを空として
 * 受ける。rc>=2・シグナル終了・stderr への出力はどれも「読めなかった」で、空へ倒さない。
 */
function checkedStdout(result: GitRunResult, what: string, allowNoMatch: boolean): string {
  if (result.error) {
    failScan(what, `git を起動できません: ${result.error.message}`);
  }
  if (result.stderr.trim() !== "") {
    failScan(what, `git が診断を出力しました: ${firstLine(result.stderr)}`);
  }
  if (result.status === 0) {
    return result.stdout;
  }
  if (allowNoMatch && result.status === 1 && result.stdout === "") {
    return "";
  }
  return failScan(what, `git が rc=${String(result.status)} で終了しました`);
}

/**
 * `git grep -n -z --full-name` の出力（`パス\0行番号\0本文\n`）を読む。形が崩れた行は throw する —
 * 黙って捨てると、その行の参照が消えて候補が archive 側へ倒れる。
 */
export function parseGrepRecords(stdout: string): GrepLine[] {
  const records: GrepLine[] = [];
  for (const raw of stdout.split("\n")) {
    if (raw === "") {
      continue;
    }
    const first = raw.indexOf("\0");
    const second = first < 0 ? -1 : raw.indexOf("\0", first + 1);
    const line = second < 0 ? Number.NaN : Number(raw.slice(first + 1, second));
    if (first <= 0 || !Number.isSafeInteger(line) || line < 1) {
      failScan("出力の解釈", `git grep の出力行を解釈できません: ${JSON.stringify(raw.slice(0, 80))}`);
    }
    records.push({ file: raw.slice(0, first), line, text: raw.slice(second + 1).replace(/\r$/u, "") });
  }
  return records;
}

/**
 * 走査面の pathspec。`playbookFiles` は live の PLAYBOOK ファイル群（リポジトリ直下からの相対）で、
 * `docs/` の外に置いた PLAYBOOK でも候補自身の見出しが走査面に入るよう個別に足す。
 * `playbookDir` は PLAYBOOK.md のあるディレクトリ（直下なら空文字）。
 */
export function buildLivePathspecs(playbookFiles: readonly string[], playbookDir: string): string[] {
  const specs = LIVE_SCAN_ROOTS.map((root) => `:(top)${root}`);
  for (const file of playbookFiles) {
    specs.push(`:(top,literal)${file}`);
  }
  const base = playbookDir === "" ? "playbook" : `${playbookDir}/playbook`;
  for (const name of PLAYBOOK_ARCHIVE_DIR_NAMES) {
    specs.push(`:(top,exclude,glob)${base}/**/${name}/**`);
  }
  return specs;
}

/** live の PLAYBOOK ファイル 1 本の本文。`file` はリポジトリ直下からの相対。 */
export type PlaybookFileText = Readonly<{
  readonly file: string;
  readonly content: string;
  readonly isMain: boolean;
}>;

type PlaybookLineContext = Readonly<{
  /** 行が属するエントリの ID（エントリの外なら null） */
  readonly owner: readonly (string | null)[];
  /** 行がエントリ見出しならその ID */
  readonly heading: readonly (string | null)[];
  readonly changelog: readonly boolean[];
  /**
   * 閉じていないフェンスか `<!--` があるか。フェンスは空白化が EOF まで及んで後続の見出しを消し、
   * コメントは空白化されずに中の見出しが残るので、どちらでも節の境界が信用できない
   */
  readonly unclosed: boolean;
}>;

/**
 * 閉じていない `<!--` があるか。コード領域（フェンス・インラインコード）の中の `<!--` と、閉じた
 * コメント span の中の `<!--` は数えない（判定は findHtmlCommentSpans と同じ源）。
 */
function hasUnclosedHtmlComment(content: string): boolean {
  const scannable = blankCodeRegions(content).text;
  const spans = findHtmlCommentSpans(content);
  for (let from = scannable.indexOf("<!--"); from >= 0; from = scannable.indexOf("<!--", from + 4)) {
    if (!spans.some((span) => from >= span.start && from < span.end)) {
      return true;
    }
  }
  return false;
}

/**
 * 行ごとの文脈を作る。境界の判定はフェンスと HTML コメントを空白化した行で行う（その中の例示の
 * 見出しを境界にしない。改行位置は保存されるので行番号は原文と一致する）。
 */
function playbookLineContext(content: string): PlaybookLineContext {
  const blanked = blankFencedCodeBlocks(blankHtmlBlockComments(content));
  const unclosed = blanked.unclosedFence === true || hasUnclosedHtmlComment(content);
  const lines = blanked.text.split("\n");
  const owner: (string | null)[] = [];
  const heading: (string | null)[] = [];
  const changelog: boolean[] = [];
  let currentOwner: string | null = null;
  let inChangelog = false;
  for (const rawLine of lines) {
    const line = rawLine.replace(/\r$/u, "");
    const entry = line.match(ENTRY_HEADING_ID_PATTERN);
    if (entry) {
      currentOwner = entry[1];
    } else if (SECTION_BREAK_PATTERN.test(line)) {
      currentOwner = null;
      inChangelog = CHANGELOG_SECTION_PATTERN.test(line);
    }
    owner.push(currentOwner);
    heading.push(entry ? entry[1] : null);
    changelog.push(inChangelog);
  }
  return { owner, heading, changelog, unclosed };
}

/** live の PLAYBOOK ファイル群にあるエントリ見出しの ID（フェンス・コメントの中の例示は除く。昇順・重複なし）。 */
export function collectEntryHeadingIds(playbookFiles: readonly PlaybookFileText[]): string[] {
  const ids = new Set<string>();
  for (const file of playbookFiles) {
    for (const id of playbookLineContext(file.content).heading) {
      if (id !== null) {
        ids.add(id);
      }
    }
  }
  return [...ids].sort();
}

function sameId(a: string, b: string): boolean {
  return a.toLowerCase() === b.toLowerCase();
}

/** 行頭の `### ACE-x:` か `<a id="ace-x"></a>` で、その ID を**定義**している行か。 */
function definesId(text: string, id: string): boolean {
  const heading = text.match(ENTRY_HEADING_ID_PATTERN);
  if (heading && sameId(heading[1], id)) {
    return true;
  }
  if (!ENTRY_ANCHOR_LINE_PATTERN.test(text)) {
    return false;
  }
  const anchor = text.match(/id="([^"]+)"/u);
  return anchor !== null && sameId(anchor[1], id);
}

/** PLAYBOOK.md の索引行（セルの 1 つがその ID そのもの）か。エントリのメタ表は ID のセルを持たない。 */
function isIndexRowFor(text: string, id: string): boolean {
  const trimmed = text.trim();
  if (!trimmed.startsWith("|")) {
    return false;
  }
  return trimmed
    .split("|")
    .map((cell) => cell.trim())
    .some((cell) => INDEX_ROW_ID_CELL_PATTERN.test(cell) && sameId(cell, id));
}

export type LiveMentionClassification = Readonly<{
  /** 候補 ID → 参照元（ファイル・行の昇順。参照に数えない言及は含まない） */
  readonly references: ReadonlyMap<string, readonly LiveReferenceSource[]>;
  /** live のエントリ見出し（と候補）のうち、走査で見出しの行が 1 度も見えなかった ID（針が外れた印。昇順） */
  readonly unobservedHeadings: readonly string[];
}>;

/**
 * git grep の一致行を参照と非参照に分ける（純関数）。
 * `markdownFiles` は一致した行を含む playbook 以外の Markdown の本文（リポジトリ直下からの相対 → 本文。
 * Changelog 節の判定用）。一致があるのに本文が無い Markdown は判定できないので throw する。
 */
export function classifyLiveMentions(input: Readonly<{
  readonly candidates: readonly string[];
  readonly mentionLines: readonly GrepLine[];
  /** 針の probe（同じ走査面のエントリ見出しの行）。見出しが見えたかの判定にだけ使う */
  readonly headingLines: readonly GrepLine[];
  readonly playbookFiles: readonly PlaybookFileText[];
  readonly markdownFiles: ReadonlyMap<string, string>;
}>): LiveMentionClassification {
  const byLower = new Map(input.candidates.map((id) => [id.toLowerCase(), id]));
  const playbook = new Map(
    input.playbookFiles.map((file) => [file.file, { ...file, context: playbookLineContext(file.content) }]),
  );
  const markdown = new Map<string, PlaybookLineContext>();
  const markdownContext = (file: string): PlaybookLineContext => {
    const cached = markdown.get(file);
    if (cached !== undefined) {
      return cached;
    }
    const content = input.markdownFiles.get(file);
    if (content === undefined) {
      return failScan("文脈の判定", `Changelog 節を判定する本文が渡されていません: ${file}`);
    }
    const parsed = playbookLineContext(content);
    // 節の境界が信用できないファイルでは Changelog 節の除外をやめる（全部数える＝安全側）
    const context = parsed.unclosed ? { ...parsed, changelog: parsed.changelog.map(() => false) } : parsed;
    markdown.set(file, context);
    return context;
  };
  const references = new Map<string, LiveReferenceSource[]>();
  const observed = new Set<string>();
  const tokenPattern = new RegExp(MENTION_TOKEN_SOURCE, "giu");
  // 見出しの行が走査に現れた = そのファイルのその行が見えている（候補かどうかを問わない）
  const observeHeading = (line: GrepLine): void => {
    const pb = playbook.get(line.file);
    const headingId = pb === undefined ? null : pb.context.heading[line.line - 1] ?? null;
    if (headingId !== null) {
      observed.add(headingId);
    }
  };
  for (const line of input.headingLines) {
    observeHeading(line);
  }

  for (const mention of input.mentionLines) {
    const ids = new Set<string>();
    for (const token of mention.text.matchAll(tokenPattern)) {
      const id = byLower.get(token[0].toLowerCase());
      if (id !== undefined) {
        ids.add(id);
      }
    }
    const base = path.posix.basename(mention.file);
    const pb = playbook.get(mention.file);
    if (pb !== undefined && mention.line > pb.context.owner.length) {
      failScan("文脈の判定", `git grep の行番号が PLAYBOOK の行数を超えています: ${mention.file}:${String(mention.line)}`);
    }
    const index = mention.line - 1;
    observeHeading(mention);
    for (const id of ids) {
      if (CHANGELOG_FILE_PATTERN.test(base) || base === LEGACY_FORMAT_ALLOWLIST_FILE) {
        continue;
      }
      if (definesId(mention.text, id)) {
        continue;
      }
      if (pb !== undefined) {
        if (pb.context.owner[index] === id || pb.context.changelog[index]) {
          continue;
        }
        if (pb.isMain && isIndexRowFor(mention.text, id)) {
          continue;
        }
      } else if (/\.md$/iu.test(mention.file)) {
        const context = markdownContext(mention.file);
        if (mention.line > context.changelog.length) {
          failScan("文脈の判定", `git grep の行番号が本文の行数を超えています: ${mention.file}:${String(mention.line)}`);
        }
        if (context.changelog[index]) {
          continue;
        }
      }
      const sources = references.get(id) ?? [];
      sources.push({ file: mention.file, line: mention.line });
      references.set(id, sources);
    }
  }
  for (const sources of references.values()) {
    sources.sort((a, b) => a.file.localeCompare(b.file) || a.line - b.line);
  }
  const expected = new Set([...collectEntryHeadingIds(input.playbookFiles), ...input.candidates]);
  const unobservedHeadings = [...expected].filter((id) => !observed.has(id)).sort();
  return { references, unobservedHeadings };
}

/**
 * `realpath` の失敗を走査不能として名指す。素の ENOENT のまま投げると、main の catch が
 * 「git コマンドが見つかりません」と誤って案内する（例: MSYS 系の git が `/c/...` を返したとき）。
 */
function realPathOrFail(target: string, what: string): string {
  try {
    return fs.realpathSync.native(target);
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    return failScan(what, `パスを解決できません: ${target}: ${message}`);
  }
}

/**
 * リポジトリ直下からの POSIX 区切りの相対パス。ディレクトリだけ `realpath` で揃え、ファイル名は
 * そのまま使う（git grep が出力するのは追跡パスそのもので、symlink の解決先ではない）。
 */
function repoRelative(topReal: string, file: string): string {
  const resolved = path.resolve(file);
  const relative = path.relative(
    topReal,
    path.join(realPathOrFail(path.dirname(resolved), "走査面の解決"), path.basename(resolved)),
  );
  if (relative === ".." || relative.startsWith(`..${path.sep}`) || path.isAbsolute(relative)) {
    failScan("走査面の解決", `PLAYBOOK ファイルがリポジトリの外にあります: ${file}`);
  }
  return relative.split(path.sep).join("/");
}

export type LiveReferenceScanRequest = Readonly<{
  readonly playbookPath: string;
  /** live の PLAYBOOK ファイル群の本文（main の contentsByFile。キーは読んだときのパス） */
  readonly playbookContents: ReadonlyMap<string, string>;
  readonly candidates: readonly string[];
  readonly runGit: GitRunner;
  /**
   * 一致した行を含む playbook 以外の Markdown を読む口（Changelog 節の判定用。引数は絶対パス）。
   * main は KnowledgeReadBoundary を渡す。失敗は走査不能として扱う。
   */
  readonly readText: (absolutePath: string) => string;
}>;

/**
 * 候補ごとの live 参照を走査する。候補が 0 件なら git を呼ばずに空を返す（確かめる対象が無い）。
 * 走査が読めない・自身の見出しを拾えなかった候補があるときは LIVE_SCAN_ERROR_PREFIX 付きで throw する。
 */
export function scanLiveReferences(
  request: LiveReferenceScanRequest,
): ReadonlyMap<string, readonly LiveReferenceSource[]> {
  if (request.candidates.length === 0) {
    return new Map();
  }
  const playbookDirAbs = path.dirname(path.resolve(request.playbookPath));
  const top = checkedStdout(
    request.runGit(playbookDirAbs, ["rev-parse", "--show-toplevel"]),
    "リポジトリの特定",
    false,
  ).trim();
  if (top === "") {
    failScan("リポジトリの特定", "git rev-parse --show-toplevel が空を返しました");
  }
  const topReal = realPathOrFail(top, "リポジトリの特定");
  const mainAbs = path.resolve(request.playbookPath);
  const playbookFiles: PlaybookFileText[] = [...request.playbookContents].map(([file, content]) => ({
    file: repoRelative(topReal, file),
    content,
    isMain: path.resolve(file) === mainAbs,
  }));
  const mainRel = repoRelative(topReal, request.playbookPath);
  const playbookDir = path.posix.dirname(mainRel) === "." ? "" : path.posix.dirname(mainRel);
  const pathspecs = buildLivePathspecs(playbookFiles.map((file) => file.file), playbookDir);

  const mentionOut = checkedStdout(
    request.runGit(
      playbookDirAbs,
      [
        "grep", "-n", "-z", "--no-column", "-I", "-i", "-F", "-w", "--full-name", "--no-color",
        "-f", "-", "--", ...pathspecs,
      ],
      `${request.candidates.join("\n")}\n`,
    ),
    "ID の走査",
    true,
  );
  const mentionLines = parseGrepRecords(mentionOut);

  // 針の probe: 同じ走査面のエントリ見出しの行（`### ACE-`）を 1 本の正規表現で拾う。全エントリ ID を
  // 照合語にすると、-i -F の照合語が千件を超えて native Windows では 1 回 3 分かかる（2026-11-08 実測）。
  const headingOut = checkedStdout(
    request.runGit(playbookDirAbs, [
      "grep", "-n", "-z", "--no-column", "-I", "--full-name", "--no-color",
      "-E", "-e", "^###[[:space:]]+ACE-", "--", ...pathspecs,
    ]),
    "見出しの走査",
    true,
  );
  const headingLines = parseGrepRecords(headingOut);

  const playbookSet = new Set(playbookFiles.map((file) => file.file));
  // playbook 以外の Markdown は、一致した行を含むファイルだけを読んで Changelog 節を判定する
  // （走査面の全ファイルは読まない）。読めなければ判定できないので、参照なしへ倒さず走査不能にする。
  // 読むのは候補に一致した行を含むファイルだけ（候補以外の ID は針にしか使わず、playbook 以外の
  // Markdown の文脈は要らない。全エントリ ID の一致で読むと native Windows で数百回 ACL 検査が立つ）。
  const candidateLower = new Set(request.candidates.map((id) => id.toLowerCase()));
  const mentionsCandidate = (text: string): boolean =>
    [...text.matchAll(new RegExp(MENTION_TOKEN_SOURCE, "giu"))].some((token) => candidateLower.has(token[0].toLowerCase()));
  const markdownFiles = new Map<string, string>();
  const filesWithCandidates = new Set(mentionLines.filter((line) => mentionsCandidate(line.text)).map((line) => line.file));
  for (const file of [...filesWithCandidates].sort()) {
    // CHANGELOG.md は丸ごと参照に数えないので読まない（判定に使わないファイルの読み込み失敗で止めない）
    if (playbookSet.has(file) || !/\.md$/iu.test(file) || CHANGELOG_FILE_PATTERN.test(path.posix.basename(file))) {
      continue;
    }
    try {
      markdownFiles.set(file, request.readText(path.join(topReal, ...file.split("/"))));
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error);
      failScan("本文の読み込み", `${file}: ${message}`);
    }
  }

  const classified = classifyLiveMentions({
    candidates: request.candidates,
    mentionLines,
    headingLines,
    playbookFiles,
    markdownFiles,
  });
  if (classified.unobservedHeadings.length > 0) {
    failScan(
      "針の照合",
      `見出しを走査で拾えなかったエントリがあります（走査面・作業ディレクトリ、カテゴリファイルが git で追跡されているか・バイナリ扱いになっていないかを確認してください）: ${listHead(classified.unobservedHeadings)}`,
    );
  }
  return classified.references;
}
