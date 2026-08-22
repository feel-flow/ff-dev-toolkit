/**
 * ACE エントリの形式ゲート（Issue #286）。
 *
 * PLAYBOOK.md §エントリテンプレートと `/ace-curate` は「旧テーブル形式
 * （`| フィールド | 値 |` ヘッダ + Insight/Context/Action ブロック）は読み取り互換として
 * 共存させるが、**新規追記には使わない**」と定めているが、これを検証する機械ゲートが
 * 無く、同じ日の追記で 2 つの形式が混在していた。
 *
 * 旧形式は同じ内容でもメタ表が 8 行（コンパクトは 4 行）になるため 1 エントリ 16〜19 行に
 * なり、行数バジェット（15 行）と導出された行数上限（ADR-019）の両方を押し上げる。
 * **形式の混在がそのまま密度超過の主因**であり、本ゲートはそれを発生源で止める。
 *
 * 「新規」と「既存の読み取り互換」の判定軸は **allowlist ファイル**（既定は PLAYBOOK.md と
 * 同階層の `legacy-format-allowlist.txt`）である。`Date` フィールドの閾値日を軸にすると、
 * その値は著者が手で書くフィールドなので**偶然満たせてしまう**（`/ace-refine` の再整形でも
 * 動く）。allowlist に載っていない ID は偶然通れない。
 *
 * 形式ゲートは索引 `PLAYBOOK.md` と `playbook/*.md` を走査する。一覧モードは指定された
 * ディレクトリ直下の `*.md` を走査する。どちらも非再帰で、`playbook/archive/` は原文を
 * verbatim 保全する場所であり、旧形式であることが正常なので**巻き込まない**。
 *
 * **検証範囲（Issue #617）**。本ゲートが赤にするのは次の 5 つだけである:
 * (1) allowlist に無いエントリに旧テーブル形式のマーカーが残っていること、
 * (2) 認識した ID の形状が `ACE_ENTRY_ID_SHAPE` を外れること、
 * (3) `###` + `ACE-` で始まる（行頭と `###` 直後の空白は問わない）のに、正準の見出し形
 *     （`### <ID>:`）へ一致しない行があること、
 * (4) 同じ ID のエントリ見出しが走査対象に 2 つ以上あること、
 * (5) 未閉フェンス・フェンス内の正準形見出し（分割の前提が壊れる形）。
 *
 * 逆に、**コンパクト正準フォーマットの構造そのものは検証しない** — anchor 行
 * （`<a id="ace-…"></a>`）・メタ 4 行・終端 `---` のいずれも**存在を要求しない**ので、
 * それらを 1 つも持たない「本文だけ」のエントリは本ゲートを通る。判定軸が旧形式マーカーの
 * **不在**だからで、「新規追記が正準フォーマットであること」まで機械保証していると
 * 読まないこと（本ゲートの保証は「旧テーブル形式の新規追記を止める」まで）。構造の
 * 検証が要るなら別ゲートとして足す（行数バジェットに基づくブロック範囲の解釈は
 * `ace-refine-report.ts` が既に持っている）。
 *
 * 実行例:
 * - 形式ゲート: npx --yes tsx scripts/ace/check-entry-format.ts docs/08-knowledge/PLAYBOOK.md
 * - 全 ID 一覧: npx --yes tsx scripts/ace/check-entry-format.ts --list-entry-ids docs/08-knowledge/playbook
 * - 旧形式 ID 一覧: npx --yes tsx scripts/ace/check-entry-format.ts --list-legacy docs/08-knowledge/playbook
 */
import * as fs from "node:fs";
import * as path from "node:path";
import { fileURLToPath } from "node:url";
import {
  ACE_ENTRY_ID_SHAPE,
  blankFencedCodeBlocks,
  blankHtmlBlockComments,
  entryHeadingSource,
  findFencedCanonicalHeadings,
} from "./check-category-size";

const EXIT_OK = 0;
const EXIT_VIOLATION = 1;
const EXIT_USAGE_ERROR = 2;

type ExitCode = typeof EXIT_OK | typeof EXIT_VIOLATION | typeof EXIT_USAGE_ERROR;
type ListExitCode = typeof EXIT_OK | typeof EXIT_USAGE_ERROR;

const DEFAULT_ALLOWLIST_BASENAME = "legacy-format-allowlist.txt";

/**
 * エントリ見出しの検出。ID 規則は `check-category-size.ts` の `entryHeadingSource` が単一の源
 * （テンプレートのプレースホルダ `### ACE-XXX:` は実 ID として扱わない）。ここへ書き写すと、
 * 同じ PLAYBOOK を読むスクリプト間で認識が静かに食い違いうる（#318）。
 *
 * 見出しの認識（広い）と ID 形状の妥当性（狭い）は別段である。認識した ID は
 * `ACE_ENTRY_ID_SHAPE` で形状を検査し、二重ハイフン `ACE-337--1` のような不正 ID は
 * fail-loud に拒否する（Issue #339。認識は狭めない — 静かに数えないと #318 が解消した
 * スクリプト間の分裂が再発する）。
 */
const ACE_ENTRY_HEADER_LINE = new RegExp(entryHeadingSource("capture-id"), "u");
/**
 * 「エントリ見出しのつもりで書かれた行」の候補を判定する 2 つの接頭辞（`###` と `ACE-`。
 * 行頭の空白と `###` 直後の空白は許容する — `isEntryHeadingCandidate` を参照）。
 * **判定の広い側**で、ここに載って `ACE_ENTRY_HEADER_LINE` に載らない行が形状違反になる
 * （Issue #617）。
 *
 * `ACE_ENTRY_ID_SHAPE` の検査は「認識された ID」にしか掛からないため、`### ACE-1.:` の
 * ように**認識器の文法から外れた**見出しは、エントリとして数えられないまま本文が直前の
 * エントリへ吸収され、形状検査にすら到達しなかった。直前が allowlist 済みなら旧形式
 * マーカー入りでも exit 0 になる（#318 / #339 が閉じた「認識して数えるが不正と言わない」
 * 穴の、「認識すらされない」変種）。空白に寛容な接頭辞判定で広く拾えば、認識器を緩めずに
 * fail-loud へ落とせる — 認識を広げると件数ゲート・refine・reuse の集計まで動くので、
 * 広げるのは**この診断だけ**にする。
 *
 * フェンス空白化済みのテキストに対して使う。テンプレートのプレースホルダ
 * （`### ACE-XXX:`）はフェンス内に書く規約なので空白化で消える — 逆に言えば、フェンスの
 * 外に書いたプレースホルダはここで赤くなるのが正しい（そのままだと吸収を起こす）。
 *
 * **正規表現ではなく素の接頭辞にしてある**。ID 文法を 1 文字も含まないことが、この定数が
 * `entryHeadingSource` の第 2 の実装**ではない**ことを構文レベルで示す（規則を書き写すと
 * #318 のスクリプト間分裂が再発する）。ここが持つ知識は「見出しは `###` で始まり `ACE-`
 * が続く」だけで、その先の妥当性判定はすべて共有の認識器へ委ねる。
 */
const ENTRY_HEADING_LEVEL_PREFIX = "###";
/** 見出しレベルの直後に来る、エントリ ID の共通接頭辞。 */
const ENTRY_HEADING_CANDIDATE_PREFIX = "ACE-";

/**
 * 「エントリ見出しのつもりで書かれた行」か（判定の広い側）。
 *
 * **行頭の空白と `###` 直後の空白の有無を許す**のが認識器（`ACE_ENTRY_HEADER_LINE`）との
 * 差である。`   ### ACE-1-1:`（インデント）も `###ACE-1-1:`（空白なし）も、書き手は
 * エントリ見出しのつもりだが認識器は取らない = 吸収を起こす形なので、候補としては拾って
 * 形状違反に落とす。**認識器の側は生の行のまま**にしておくこと — こちらも空白を許すと、
 * 吸収を起こす形が「正常なエントリ」として通り、件数ゲート・refine・reuse の分割境界だけが
 * 食い違う（沈黙する方向への悪化で、この診断を足した意味が消える）。
 *
 * `####` 以上は候補にならない。エントリ見出しは `###` 固定であり、本文中の小見出しまで
 * 巻き込むと、正常なエントリを「直すべき箇所」として名指しする偽陽性になる。除外は
 * **専用の分岐ではなく構造で効く** — `###` を消費した残りが `#` で始まり、`trimStart` は
 * 空白しか落とさないので `ACE-` へ届かない。`#` を落とす向きの変更（`replace(/^#+/, "")`
 * のような「単純化」）はこの除外を静かに壊すため、`#### ACE-…` が緑のままであることを
 * テストで固定してある。
 */
function isEntryHeadingCandidate(line: string): boolean {
  const trimmed = line.trimStart();
  if (!trimmed.startsWith(ENTRY_HEADING_LEVEL_PREFIX)) {
    return false;
  }
  const afterLevel = trimmed.slice(ENTRY_HEADING_LEVEL_PREFIX.length);
  return afterLevel.trimStart().startsWith(ENTRY_HEADING_CANDIDATE_PREFIX);
}

/** 旧テーブル形式のメタ表ヘッダ行（`| フィールド | 値 |`）。 */
const FIELD_TABLE_HEADER = /^\|\s*フィールド\s*\|/mu;
/** Markdown テーブルの区切り行。コンパクト正準はヘッダ行・区切り行を持たない。 */
const TABLE_SEPARATOR = /^\|[\s:|-]*-{3,}[\s:|-]*\|/mu;
/** 旧形式の本文ブロック（Insight / Context / Action の太字ラベル）。 */
const INSIGHT_BLOCK = /^\*\*(?:Insight|Context|Action)\*\*/mu;

export type LegacyMarker = "field-table-header" | "table-separator" | "insight-block";

export type PlaybookEntry = Readonly<{
  readonly id: RecognizedAceEntryId;
  readonly body: string;
}>;

declare const recognizedAceEntryIdBrand: unique symbol;
/** `entryHeadingSource` の共有パーサが認識した ID。形状ゲート通過済みとは限らない。 */
export type RecognizedAceEntryId = string & {
  readonly [recognizedAceEntryIdBrand]: true;
};

function asRecognizedAceEntryId(value: string): RecognizedAceEntryId {
  // この変換は ACE_ENTRY_HEADER_LINE の capture 直後だけで行う。
  // ローカル regex で再検証すると Issue #336 の単一源化を逆行する。
  return value as RecognizedAceEntryId;
}

/**
 * カテゴリファイル本文をエントリ単位（見出し行から次の見出し行の直前まで）へ分割する。
 * 最初の見出しより前（ファイルヘッダ）はどのエントリにも属さない。
 *
 * 見出しの判定は**フェンス空白化済み**の行で行う（Issue #342。フェンス内に正準形の
 * 見出し `### ACE-9-9:` があってもエントリとして数えない — reuse / refine のパーサと
 * 同じ除外規則で、4 スクリプトの認識を一致させる）。本文はフェンス空白化**前**の
 * 行から集める（旧形式マーカーの検出対象を変えない）。フェンス内の正準形見出しと
 * 未閉フェンスへの**拒否**は `splitEntries` の呼び出し側（形式ゲートの `main` または
 * 一覧処理の `readEntries`）が担う（パーサは除外するだけ — 読み取り側から import
 * されても汚れた入力で例外を投げない）。
 */
export function splitEntries(content: string): PlaybookEntry[] {
  const source = blankHtmlBlockComments(content);
  const probe = blankFencedCodeBlocks(source);
  const boundaryLines = probe.text.split("\n");
  const lines = source.split("\n");
  const entries: { id: RecognizedAceEntryId; bodyLines: string[] }[] = [];
  for (let i = 0; i < lines.length; i++) {
    const match = boundaryLines[i].match(ACE_ENTRY_HEADER_LINE);
    if (match?.[1]) {
      entries.push({ id: asRecognizedAceEntryId(match[1]), bodyLines: [] });
      continue;
    }
    if (entries.length > 0) {
      entries[entries.length - 1].bodyLines.push(lines[i]);
    }
  }
  return entries.map((entry) => ({ id: entry.id, body: entry.bodyLines.join("\n") }));
}

/** 認識された見出し 1 件。line は 0-origin（利用側で +1 して提示する）。 */
export type CanonicalEntryHeading = Readonly<{
  readonly id: RecognizedAceEntryId;
  readonly line: number;
}>;

/** 見出しのつもりだが認識されない行 1 件。line は 0-origin。 */
export type MalformedEntryHeading = Readonly<{
  readonly line: number;
  readonly text: string;
}>;

/** scanEntryHeadings の結果。両者は同じ 1 回の走査から出る（行番号の基準が揃う）。 */
export type EntryHeadingScan = Readonly<{
  readonly canonical: readonly CanonicalEntryHeading[];
  readonly malformed: readonly MalformedEntryHeading[];
}>;

/**
 * エントリ見出しの候補行を 1 回走査し、認識された見出し（ID + 行番号）と、見出しの
 * つもりだが正準形（`### <ID>:`）へ一致しない行へ振り分ける（Issue #617）。
 *
 * 引数は**フェンス空白化済み**（かつ HTML コメント空白化済み）のテキストであること。
 * 生の本文を渡すと、フェンス内の例示やコメント内の追記例まで違反として名指ししてしまう。
 * 空白化は文字数と改行位置を保つので、`line` はそのまま原文の行番号として使える。
 *
 * 両者を**同じ走査**から出すのは、重複 ID の報告位置と形状違反の報告位置が同じ行基準で
 * あることを構造的に保証するため（別々に数えると、片方だけがフェンスや HTML コメントの
 * 扱いを変えたときに「20 行目」が別の行を指す）。
 *
 * `### ACE-337--1:` のように**認識はされる**が形状が不正な ID は `malformed` には載らない
 * （`ACE_ENTRY_HEADER_LINE` に一致するため `canonical` 側へ入る）。あちらは
 * `ACE_ENTRY_ID_SHAPE` の検査が拾うので、二重報告にはならない。
 */
export function scanEntryHeadings(cleaned: string): EntryHeadingScan {
  const canonical: CanonicalEntryHeading[] = [];
  const malformed: MalformedEntryHeading[] = [];
  const lines = cleaned.split("\n");
  for (let index = 0; index < lines.length; index++) {
    const line = lines[index];
    if (!isEntryHeadingCandidate(line)) {
      continue;
    }
    const match = line.match(ACE_ENTRY_HEADER_LINE);
    if (match?.[1]) {
      canonical.push({ id: asRecognizedAceEntryId(match[1]), line: index });
      continue;
    }
    malformed.push({ line: index, text: line.trimEnd() });
  }
  return { canonical, malformed };
}

/**
 * `scanEntryHeadings` の malformed だけを取り出す**テスト向けの薄いラッパ**。
 * 本番経路（`main`）は `scanEntryHeadings` を直接呼び、canonical 側も同時に使う。
 */
export function findMalformedEntryHeadings(cleaned: string): readonly MalformedEntryHeading[] {
  return scanEntryHeadings(cleaned).malformed;
}

/** エントリ ID の出現位置 1 件（1-origin の行番号）。 */
export type EntryLocation = Readonly<{
  readonly file: string;
  readonly line: number;
}>;

/**
 * 出現位置を `coding.md: 5 行目 / process.md: 7 行目` の形へ整形する（Issue #617）。
 * 同一ファイル内の連続する出現はファイル名をまとめる（`testing.md: 20 行目 / 41 行目`）。
 * ファイル名だけだと同一ファイル内の重複で「2 箇所: testing.md, testing.md」となり、
 * どこを直せばよいか分からないため、行番号まで出す。
 */
export function formatEntryLocations(locations: readonly EntryLocation[]): string {
  const groups: { file: string; lines: number[] }[] = [];
  for (const location of locations) {
    const last = groups[groups.length - 1];
    if (last && last.file === location.file) {
      last.lines.push(location.line);
      continue;
    }
    groups.push({ file: location.file, lines: [location.line] });
  }
  return groups
    .map((group) => `${group.file}: ${group.lines.map((line) => `${String(line)} 行目`).join(" / ")}`)
    .join(" / ");
}

/**
 * エントリ本文に残る旧テーブル形式のマーカーを列挙する。
 *
 * 3 つのマーカーを **OR** で見るのは実データの都合である。live には「メタ表だけ正準へ
 * 再整形され本文は Insight/Context/Action のまま残ったハイブリッド」が 4 件あり、
 * 区切り行だけを主判定にするとこの形の新規追記が通ってしまう。表形式の 2 マーカーは
 * エントリ先頭のメタブロックだけを見る。本文中の比較表まで旧メタ表と誤認しないためで、
 * ACE-429-1 がこの偽陽性を実際に踏んだ（Issue #441）。Insight ブロックは本文に残る
 * ハイブリッドを検出するため、従来どおり本文全体を見る。
 */
export function detectLegacyMarkers(body: string): LegacyMarker[] {
  const markers: LegacyMarker[] = [];
  const metadataBlock = body.trimStart().split(/\r?\n[\t ]*\r?\n/u, 1)[0] ?? "";
  if (FIELD_TABLE_HEADER.test(metadataBlock)) {
    markers.push("field-table-header");
  }
  if (TABLE_SEPARATOR.test(metadataBlock)) {
    markers.push("table-separator");
  }
  if (INSIGHT_BLOCK.test(body)) {
    markers.push("insight-block");
  }
  return markers;
}

/** allowlist ファイルを読む。`#` 始まりのコメント行・空行・前後空白は無視する。 */
export function parseAllowlist(content: string): string[] {
  return content
    .split("\n")
    .map((line: string) => line.trim())
    .filter((line: string) => line !== "" && !line.startsWith("#"));
}

/** `playbook/` 直下の `*.md` を非再帰で列挙する（`archive/` を巻き込まない）。 */
function discoverCategoryFiles(playbookPath: string): string[] {
  const subDir = path.join(path.dirname(playbookPath), "playbook");
  if (!fs.existsSync(subDir) || !fs.statSync(subDir).isDirectory()) {
    return [];
  }
  return fs
    .readdirSync(subDir)
    .filter((entry: string) => entry.endsWith(".md"))
    .map((entry: string) => path.join(subDir, entry))
    .sort();
}

function resolveAllowlistPath(playbookPath: string): string {
  const fromEnv = process.env.ACE_LEGACY_FORMAT_ALLOWLIST;
  if (fromEnv && fromEnv.trim() !== "") {
    return path.resolve(fromEnv);
  }
  return path.join(path.dirname(playbookPath), DEFAULT_ALLOWLIST_BASENAME);
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

export class LegacyListInputError extends Error {
  public constructor(message: string) {
    super(message);
    this.name = "LegacyListInputError";
  }
}

function discoverMarkdownFiles(directoryPath: string): string[] {
  try {
    if (!fs.statSync(directoryPath).isDirectory()) {
      throw new LegacyListInputError(`対象がディレクトリではありません: ${directoryPath}`);
    }
    return fs
      .readdirSync(directoryPath)
      .filter((entry: string) => entry.endsWith(".md"))
      .map((entry: string) => path.join(directoryPath, entry))
      .sort();
  } catch (error: unknown) {
    if (error instanceof LegacyListInputError) throw error;
    const message = error instanceof Error ? error.message : String(error);
    throw new LegacyListInputError(`${directoryPath}: ${message}`);
  }
}

function readEntries(filePath: string): readonly PlaybookEntry[] {
  let content: string;
  try {
    content = fs.readFileSync(filePath, "utf8");
  } catch (error: unknown) {
    const message = error instanceof Error ? error.message : String(error);
    throw new LegacyListInputError(`${filePath}: ${message}`);
  }
  const fenceScan = blankFencedCodeBlocks(blankHtmlBlockComments(content));
  if (fenceScan.unclosedFence) {
    throw new LegacyListInputError(
      `${filePath}: ${fenceScan.unclosedFenceLine + 1} 行目に始まるコードフェンスが閉じていません`,
    );
  }
  return splitEntries(content);
}

/**
 * 指定ディレクトリ直下で認識した形状検証前の ACE エントリ ID をソート・重複除去して返す。
 * 読み込み失敗、非ディレクトリ、未閉フェンスは `LegacyListInputError` として送出する。
 */
export function listEntryIds(directoryPath: string): readonly RecognizedAceEntryId[] {
  const ids = new Set<RecognizedAceEntryId>();
  for (const filePath of discoverMarkdownFiles(directoryPath)) {
    for (const entry of readEntries(filePath)) {
      ids.add(entry.id);
    }
  }
  return [...ids].sort();
}

/**
 * 指定ディレクトリ直下の `*.md` を非再帰で読み、旧形式 ID のソート済み集合を返す。
 * 読み込み失敗、非ディレクトリ、未閉フェンスは `LegacyListInputError` として送出する。
 */
export function listLegacyEntryIds(directoryPath: string): readonly RecognizedAceEntryId[] {
  const ids = new Set<RecognizedAceEntryId>();
  for (const filePath of discoverMarkdownFiles(directoryPath)) {
    for (const entry of readEntries(filePath)) {
      if (detectLegacyMarkers(entry.body).length > 0) {
        ids.add(entry.id);
      }
    }
  }
  return [...ids].sort();
}

/**
 * 一覧 CLI は ID を字典順・重複除去で 1 行 1 件 stdout へ出す。
 * 入力全体の検証後に出力するため、入力エラー時は stdout を空に保ち診断を stderr へ出す。
 * 0 件の stdout は空。成功は 0、引数/入力エラーは 2 で、1 は返さない。
 */
function runList(argv: readonly string[]): ListExitCode {
  const mode = argv[2];
  const directoryArg = argv[3];
  if (
    argv.length !== 4 ||
    (mode !== "--list-entry-ids" && mode !== "--list-legacy") ||
    !directoryArg ||
    directoryArg.trim() === ""
  ) {
    console.error(
      "Usage: npx --yes tsx scripts/ace/check-entry-format.ts (--list-entry-ids|--list-legacy) <directory>",
    );
    return EXIT_USAGE_ERROR;
  }
  const directoryPath = path.resolve(directoryArg);
  try {
    const ids = mode === "--list-entry-ids" ? listEntryIds(directoryPath) : listLegacyEntryIds(directoryPath);
    for (const id of ids) {
      console.log(id);
    }
  } catch (error: unknown) {
    if (error instanceof LegacyListInputError) {
      console.error(`読み込み失敗: ${error.message}`);
      return EXIT_USAGE_ERROR;
    }
    throw error;
  }
  return EXIT_OK;
}

export function main(argv: readonly string[] = process.argv): ExitCode {
  if (argv[2]?.startsWith("--list-")) {
    return runList(argv);
  }
  const playbookPath = resolvePlaybookPath(argv);
  if (!playbookPath) {
    console.error(
      "引数に PLAYBOOK.md のパスを渡すか、ACE_PLAYBOOK_PATH を設定してください。",
    );
    return EXIT_USAGE_ERROR;
  }

  const allowlistPath = resolveAllowlistPath(playbookPath);
  // ファイル不在は「例外なし」= strict として扱う。fail-open にすると、allowlist を
  // 消すだけでゲートが黙って無効化される。
  let allowlist: string[] = [];
  if (fs.existsSync(allowlistPath)) {
    try {
      allowlist = parseAllowlist(fs.readFileSync(allowlistPath, "utf8"));
    } catch (error: unknown) {
      const message = error instanceof Error ? error.message : String(error);
      console.error(`読み込み失敗: ${allowlistPath}: ${message}`);
      return EXIT_USAGE_ERROR;
    }
  }
  const allowed = new Set(allowlist);

  let categoryFiles: string[];
  try {
    categoryFiles = discoverCategoryFiles(playbookPath);
  } catch (error: unknown) {
    const message = error instanceof Error ? error.message : String(error);
    console.error(`読み込み失敗: playbook/ の走査に失敗しました: ${message}`);
    return EXIT_USAGE_ERROR;
  }
  // 索引 PLAYBOOK.md 自身も常に走査する — 件数ゲート・refine・reuse の 3 者は索引の
  // 内容を集計対象に含めるため、索引だけ形式ゲートから外すと「認識して数えるが、
  // どのゲートも形式が不正とは言わない」経路（#339 が閉じる穴そのもの）が部分移行中の
  // 索引側エントリに残る。通常の索引はエントリ見出しを持たないので追加コストは無い。
  const filesToScan =
    categoryFiles.length > 0 ? [playbookPath, ...categoryFiles] : [playbookPath];

  console.log(`Playbook: ${playbookPath}`);
  console.log(
    `allowlist: ${allowlistPath}（${fs.existsSync(allowlistPath) ? `${String(allowlist.length)} 件` : "不在 = strict"}）`,
  );
  console.log(`走査対象: ${String(filesToScan.length)} ファイル（playbook/archive/ は対象外）`);

  const violations: string[] = [];
  const shapeViolations: string[] = [];
  const unclosedFenceFiles: string[] = [];
  const fencedHeadingViolations: string[] = [];
  const malformedHeadingViolations: string[] = [];
  const seenLegacy = new Set<string>();
  const seenIds = new Set<string>();
  // ID → 出現箇所（走査順）。重複を検出したうえで**どこにあるか**まで出す（Issue #617）。
  // Set の size 差分だけだと「どれが重複か」が出ず、84 エントリの Playbook では
  // 追記者が自力で突き止められない。同一ファイル内の重複もあるのでファイル名だけでは
  // 足りず、行番号まで持つ（scanEntryHeadings が形状違反と同じ走査で出す）。
  const idLocations = new Map<string, { file: string; line: number }[]>();

  for (const filePath of filesToScan) {
    let content: string;
    try {
      content = fs.readFileSync(filePath, "utf8");
    } catch (error: unknown) {
      const message = error instanceof Error ? error.message : String(error);
      console.error(`読み込み失敗: ${filePath}: ${message}`);
      return EXIT_USAGE_ERROR;
    }
    // 未閉フェンス・フェンス内の正準形見出しは、他ファイルの走査を打ち切らずに**記録して
    // 続行**し、ループ後にまとめて報告する（shapeViolations / violations と同じ方針。
    // ここで即 return すると、複数ファイルに違反があるとき 1 ファイル直すごとに再実行する
    // 二段階の修正ループになる — 下の終了判定コメント参照）。
    //
    // 未閉フェンスは分割の前提を壊す（空白化が EOF まで及び、以降のエントリが静かに
    // 吸収される）ため、当該ファイルの splitEntries は走らせない（吸収済みの分割結果で
    // 誤った形状違反を報告しない）。件数ゲート側にも同じ fail-closed があるが、
    // 本ゲート単体で走らせたときに沈黙しないよう自前でも検査する（Issue #342）。
    const cleanedForFence = blankHtmlBlockComments(content);
    const fenceScan = blankFencedCodeBlocks(cleanedForFence);
    if (fenceScan.unclosedFence) {
      unclosedFenceFiles.push(
        `${path.basename(filePath)}（${String(fenceScan.unclosedFenceLine + 1)} 行目に始まるフェンス）`,
      );
      continue;
    }
    // 閉じたフェンスの内側にある正準形見出しは fail-loud で拒否する（Issue #342。
    // パーサ（splitEntries）は除外するため以降の走査は歪まない — 記録だけして続行し、
    // 同じファイルの他の違反も同時に報告する。状態そのものは commit させない。
    const fencedHeadings = findFencedCanonicalHeadings(cleanedForFence);
    if (fencedHeadings.length > 0) {
      fencedHeadingViolations.push(
        `${path.basename(filePath)}: ` +
          fencedHeadings.map((h) => `${h.id}: ${String(h.line + 1)} 行目`).join(" / "),
      );
    }
    // 見出し行の走査は 1 回だけ。正準形へ一致しない `### ACE-` 行は、エントリとして
    // 数えられないまま本文を直前のエントリへ吸収させるので、記録して続行し（他の違反も
    // 同時に出す）終了判定で赤にする。認識された側は重複 ID の出現位置に使う。
    const headingScan = scanEntryHeadings(fenceScan.text);
    if (headingScan.malformed.length > 0) {
      malformedHeadingViolations.push(
        `${path.basename(filePath)}: ` +
          headingScan.malformed
            .map((heading) => `${String(heading.line + 1)} 行目: ${heading.text}`)
            .join(" / "),
      );
    }
    for (const heading of headingScan.canonical) {
      idLocations.set(heading.id, [
        ...(idLocations.get(heading.id) ?? []),
        { file: path.basename(filePath), line: heading.line + 1 },
      ]);
    }
    for (const entry of splitEntries(content)) {
      seenIds.add(entry.id);
      if (!ACE_ENTRY_ID_SHAPE.test(entry.id)) {
        shapeViolations.push(`${entry.id}（${path.basename(filePath)}）`);
      }
      const markers = detectLegacyMarkers(entry.body);
      if (markers.length === 0) {
        continue;
      }
      seenLegacy.add(entry.id);
      if (!allowed.has(entry.id)) {
        violations.push(
          `${entry.id}（${path.basename(filePath)} / 検出: ${markers.join(", ")}）`,
        );
      }
    }
  }

  // allowlist にあるのに旧形式でなくなった ID は警告のみ。/ace-refine の正準化と
  // allowlist の掃除を同一 PR に強制するとゲートが refine をブロックしてしまう。
  // 形状違反があるときはこの警告を出さない — ID は allowlist のキーであり、見出しの
  // ID が壊れている（例: ACE-9-9 が ACE-9--9 に化けた）状態で missing を計算すると
  // 「ACE-9-9 を allowlist から削除してください」という**誤った掃除案内**になる。
  // 未閉フェンスのファイルをスキップした場合も出さない — seenIds が不完全なので
  // missing の計算が「実在する ID を削除してください」という誤案内になる。
  // 正準形を外れた見出し（Issue #617）も同じ理由で抑制する — その見出しのエントリは
  // 数えられておらず seenIds に載らないため、live に居るのに missing として案内される。
  // ID 重複はこの条件へ加えない（seenIds は不完全にならず、missing/stale の計算は正しい）。
  if (
    shapeViolations.length === 0 &&
    unclosedFenceFiles.length === 0 &&
    malformedHeadingViolations.length === 0
  ) {
    const stale = allowlist.filter((id: string) => seenIds.has(id) && !seenLegacy.has(id));
    const missing = allowlist.filter((id: string) => !seenIds.has(id));
    if (stale.length > 0) {
      console.warn(
        `ace-format: allowlist に載っているが旧形式ではなくなった ID があります（正準化済み。allowlist から削除してください）: ${stale.join(", ")}`,
      );
    }
    if (missing.length > 0) {
      console.warn(
        `ace-format: allowlist に載っているが live に存在しない ID があります（アーカイブ済み・統合済み。allowlist から削除してください）: ${missing.join(", ")}`,
      );
    }
  }

  console.log(`旧形式エントリ: ${String(seenLegacy.size)} 件（allowlist 済み ${String(seenLegacy.size - violations.length)} 件）`);

  // 各種の違反は**すべて**報告してから終了判定を一本化する。どれかで先に return すると、
  // 複数種の違反があるとき（または複数ファイルに違反が散っているとき）ユーザーが
  // 二段階の修正ループを踏まされる（検出できたものは全部一度に出す）。
  if (unclosedFenceFiles.length > 0) {
    console.error(
      "✗ コードフェンスが閉じていないファイルがあります。フェンス内の例示を除外できないため、" +
        "当該ファイルの形式検査はスキップしました（フェンスを閉じてから再実行してください）:\n- " +
        unclosedFenceFiles.join("\n- "),
    );
  }

  if (fencedHeadingViolations.length > 0) {
    console.error(
      "✗ フェンス内に正準形のエントリ見出しがあります。例示なら ID を ACE-XXX のような" +
        "非正準形にしてください。実エントリのつもりなら、直前のコードフェンスの対応" +
        "（閉じ忘れ・裸の ``` との偶然の対）を確認してください:\n- " +
        fencedHeadingViolations.join("\n- "),
    );
  }

  if (malformedHeadingViolations.length > 0) {
    console.error(
      "⚠ `### ACE-` で始まるのにエントリ見出しとして認識されない行があります。" +
        "この行はエントリの境界にならず、本文が直前のエントリへ**吸収**されます" +
        "（件数からも消え、旧形式マーカーの検査も直前のエントリの allowlist 判定に" +
        "乗ってしまいます）。見出しを `### <ID>: <タイトル>` の形（ID は " +
        "`ACE-<番号>-<連番>`。行頭の空白と `###` 直後の空白の省略も認識されません）へ" +
        "直してください。テンプレートのプレースホルダならコードフェンスで囲みます:\n- " +
        malformedHeadingViolations.join("\n- "),
    );
  }

  const duplicateIdViolations = [...idLocations.entries()]
    .filter(([, locations]) => locations.length > 1)
    .map(
      ([id, locations]) =>
        `${id}（${String(locations.length)} 箇所: ${formatEntryLocations(locations)}）`,
    );
  if (duplicateIdViolations.length > 0) {
    console.error(
      "⚠ 同じエントリ ID が複数箇所にあります。ID はアンカー（`<a id=\"ace-…\">`）・" +
        "索引の参照先・allowlist・再利用カウンタのキーであり、重複すると" +
        "「allowlist 済み ID を再利用した新規追記が旧形式でも通る」「参照リンクが" +
        "どちらか一方にしか飛ばない」といった形で静かに壊れます。採番規則" +
        "（PLAYBOOK.md §エントリID規則）どおり PR ごとに連番を振り直してください:\n- " +
        duplicateIdViolations.join("\n- "),
    );
  }

  if (shapeViolations.length > 0) {
    console.error(
      "⚠ ID の形状が不正なエントリがあります（PLAYBOOK.md §エントリID規則の形 " +
        "`ACE-<番号>-<連番>`（Issue 由来は `ACE-i<番号>-<連番>`。段は増やせる。" +
        "連番の無い単段は旧 3 桁形式 `ACE-001` だけの歴史的例外）へ改番してください。" +
        "二重ハイフン・アンダースコア・英字 suffix・連番の無い単段は不可。" +
        "suffix や枝番を表したい場合は `-<連番>` を 1 段増やします）:\n- " +
        shapeViolations.join("\n- "),
    );
  }

  if (violations.length > 0) {
    console.error(
      "⚠ allowlist に無い旧テーブル形式のエントリがあります。新規追記は PLAYBOOK.md §エントリテンプレートのコンパクト正準フォーマット（メタ 4 行・ヘッダ行と区切り行なし・Insight/Context/Action ブロックを使わない）で書いてください。既存エントリを正準化した場合は allowlist から当該 ID を削除します。読み取り互換として意図的に旧形式を残すなら allowlist へ追加してください:\n- " +
        violations.join("\n- "),
    );
  }

  // 未閉フェンスは「入力が検査可能な形になっていない」ので USAGE、それ以外は VIOLATION。
  // 両方あるときは USAGE を優先する（スキップしたファイルがある = 違反の列挙が不完全で、
  // 上の一覧を直しても再実行で新しい違反が出うることを終了コードでも表す）。
  if (unclosedFenceFiles.length > 0) {
    return EXIT_USAGE_ERROR;
  }
  if (
    fencedHeadingViolations.length > 0 ||
    malformedHeadingViolations.length > 0 ||
    duplicateIdViolations.length > 0 ||
    shapeViolations.length > 0 ||
    violations.length > 0
  ) {
    return EXIT_VIOLATION;
  }

  console.log("✓ 旧テーブル形式の新規追記はありません。");
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
