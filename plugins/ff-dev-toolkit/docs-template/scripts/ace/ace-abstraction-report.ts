/**
 * ACE エントリの抽象度レポート（Issue #1135 / ADR-047）。
 *
 * 「適用条件が固有名なしで書けるか」という抽象度の下限に対して、**候補を提示するだけ**の
 * 読み取り専用レポート。エントリ本文（タイトル + 適用条件 + アクション）に残る固有名
 * （Issue/PR 参照・ファイルパス・コードスパンの識別子）をスコア化し、
 * (1) 抽象度の下限を下回る可能性のあるエントリ、(2) 抽象度を 1 段上げれば同一のアクションへ
 * 畳める統合候補の組、を Markdown（既定）または JSON（`--json`）で出力する。
 *
 * 組は極大クリークとして列挙するので、閾値を満たした候補対はすべていずれかの組に含まれる。
 * それでも組へ入らない対が出たら「組にできなかった候補対」節へ別勘定で出す（この節が
 * 空でないことは実装の退行を意味する。`--max-groups` の表示打ち切りとは別物）。
 *
 * **ゲートではない**。着手時の実測で機械シグナル単独の精度は 47% / 再現率 85% であり、
 * exit 1 で止めると偽陽性が /ace-curate のチェーンを壊す。**候補が何件出ても終了コードは 0**
 * で、非 0 になるのは入力そのものが測れないとき（パス不備・エントリ 0 件・未閉フェンス・
 * 読み込み失敗）だけである。最終判定は /ace-curate の新規性バー（抽象度の下限の項）と
 * /ace-refine 手順 2 の LLM 判断が行う。本スクリプトの役割は入力を候補組へ絞ることだけ。
 *
 * **dry-run 既定**であり、書き換えオプションは持たない（AC: 承認なしで実行しても
 * 既存ファイルが書き換えられない）。統合の適用は /ace-refine R3-c の承認ゲートの仕事。
 *
 * エントリの認識（見出し / 分割 / HTML コメント除外）は check-category-size.ts の
 * 単一源（entryHeadingSource / splitEntrySegments）へ乗せる。書き写すと「件数ゲートは
 * 数えるのに抽象度レポートは見ない」分裂が起きる（#318 と同型）。
 *
 * 実行例:
 *   npx --yes tsx docs-template/scripts/ace/ace-abstraction-report.ts docs/08-knowledge/PLAYBOOK.md
 *   npx --yes tsx docs-template/scripts/ace/ace-abstraction-report.ts docs/08-knowledge/PLAYBOOK.md --json
 */
import * as fs from "node:fs";
import {
  blankFencedCodeBlocks,
  blankHtmlBlockComments,
  discoverPlaybookSubfiles,
  entryHeadingSource,
  findFencedCanonicalHeadings,
  isDirectExecution,
  scanUnclosedFence,
  splitEntrySegments,
} from "./check-category-size";
import { detectLegacyMarkers } from "./check-entry-format";

const EXIT_OK = 0;
const EXIT_RUNTIME_ERROR = 1;
const EXIT_USAGE_ERROR = 2;

const WARN_PREFIX = "ace-abstraction-report";

/**
 * 候補とみなすスコアの下限。score は
 * 「Issue/PR 参照あり → +2 / ファイルパスあり → +1 / 識別子 3 件以上 → +1 / 6 件以上 → +1」。
 *
 * 2 は「Issue/PR 参照を 1 つ持つ」または「パス + 識別子」で到達する水準。着手時の実測
 * （live corpus 736 件）では 279 件（37.9%）が該当し、精読した 49 件の真陽性率は 47%。
 * ここを 3 に上げると強い候補 119 件まで絞れるが、Issue が真陽性の代表例として挙げた
 * ACE-296-2（シグナル 0）のような取りこぼしが増える方向であり、**絞り込み用途**では
 * 再現率を優先して 2 に置く。判定は人間 / LLM が行うので偽陽性のコストは読む手間だけ。
 */
export const CANDIDATE_SCORE_THRESHOLD = 2;
/** 強い候補（レポート上で印を付けるだけ。閾値としては使わない） */
export const STRONG_SCORE_THRESHOLD = 3;
/** 識別子（コードスパン）の件数がこの数以上なら +1 */
export const IDENTIFIER_SIGNAL_THRESHOLD = 3;
/** 識別子がこの数以上ならさらに +1（固有名が本文を埋めている状態） */
export const IDENTIFIER_DENSE_THRESHOLD = 6;

/**
 * 統合候補の組と判定する最小の共有キー数。1 にすると「同じコマンド名を 1 回書いた」
 * だけの無関係な対が大量に出る（live corpus で 4 桁）。2 は着手時の精読で確定した
 * 7 組のうち 5 組以上を残しつつ、組数を人が読める規模に保つ実測値。
 */
export const MIN_SHARED_KEYS = 2;
/**
 * 共有キーの Jaccard 係数の下限。ACE のタイトルは日本語主体でラテン語彙が少なく、
 * キー集合が小さいため係数は高く出やすい。0.12 は「片方が固有名だらけで、もう片方の
 * 少数のキーを偶然含む」対を落とすための下限。
 */
export const MIN_JACCARD = 0.12;
/** キーとして採用する最小長（`ts` や `sh` のような 2 文字トークンの偶然一致を落とす） */
const MIN_KEY_LENGTH = 3;
/** タイトル語彙をキーに採る最小長 */
const MIN_TITLE_WORD_LENGTH = 4;

/** レポートへ載せる統合候補の組数の既定上限（`--max-groups` で変更可） */
export const DEFAULT_MAX_GROUPS = 40;
/** レポートへ載せる候補エントリ一覧の既定上限（`--max-candidates` で変更可） */
export const DEFAULT_MAX_CANDIDATES = 60;
/** レポートへ載せる「組にできなかった候補対」の既定上限（`--max-ungrouped-pairs` で変更可） */
export const DEFAULT_MAX_UNGROUPED_PAIRS = 40;

/** エントリ見出し行（ID 捕捉）。源は check-category-size の entryHeadingSource */
const ENTRY_HEADING_LINE = new RegExp(entryHeadingSource("capture-id") + "(.*)$", "mu");
/** メタ行（`| Category | … |` 等のテーブル行）。Origin の PR 番号はここに入る */
const META_TABLE_LINE = /^\s*\|/u;
/**
 * 旧テーブル形式の段落マーカー（`**Insight**:` / `**Context**:` / `**Action**:` 等）。
 * `**Context**` 段落だけをシグナルから外すために、段落の切れ目を見つけるのに使う。
 */
const LEGACY_PARAGRAPH_MARKER = /^\s*\*\*[A-Za-z][A-Za-z ]*\*\*\s*[:：]/u;
/** 旧テーブル形式の `**Context**:` 段落の開始行 */
const LEGACY_CONTEXT_MARKER = /^\s*\*\*Context\*\*\s*[:：]/u;
/** エントリ間の水平線 */
const HORIZONTAL_RULE_LINE = /^\s*---+\s*$/u;
/** anchor 行 */
const ANCHOR_LINE = /^\s*<a id="[^"]*"><\/a>\s*$/iu;
/** `##` 見出し（Changelog 等の後続セクション） */
const SECTION_HEADING = /^##\s/u;
/** Category メタセル */
const CATEGORY_CELL = /^\s*\|\s*Category\s*\|\s*([^|]+)\|/imu;
/** ACE エントリ間の相互参照リンク（固有名ではなく索引。シグナルから除外する） */
const ACE_CROSS_REFERENCE_LINK = /\[ACE-[^\]]*\]\([^)]*\)/gu;
/** インラインコードスパン */
const CODE_SPAN = /`([^`\n]+)`/gu;
/** Issue / PR 参照 */
const ISSUE_REFERENCE = /(?:PR|Issue)\s*#\d+|#\d+/gu;
/** ファイルパスらしいコードスパン（区切り `/` を含む、または既知の拡張子で終わる） */
const PATH_LIKE = /\/|\.(?:ts|tsx|js|mjs|cjs|md|sh|bash|zsh|json|ya?ml|toml|dart|swift|py|rb|go|rs)\b/u;

export type EntryFormat = "compact" | "legacy";

export type AbstractionSignals = Readonly<{
  /** 本文中の Issue / PR 参照（メタ行の Origin は含まない） */
  readonly issueRefs: readonly string[];
  /** ファイルパスらしいコードスパン */
  readonly paths: readonly string[];
  /** パス以外のコードスパン（コマンド名・API 名・スクリプト名） */
  readonly identifiers: readonly string[];
}>;

export type AbstractionEntry = Readonly<{
  readonly id: string;
  readonly title: string;
  /** Category メタ行の値。欠落時は "unknown" */
  readonly category: string;
  readonly format: EntryFormat;
  readonly signals: AbstractionSignals;
  readonly score: number;
  /** 統合候補の照合キー（識別子 + タイトルのラテン語彙。正規化済み・重複排除済み） */
  readonly keys: readonly string[];
}>;

export type MergeCandidateMember = Readonly<{
  readonly id: string;
  readonly category: string;
  readonly format: EntryFormat;
  readonly title: string;
}>;

export type MergeCandidateGroup = Readonly<{
  readonly members: readonly MergeCandidateMember[];
  /** 2 件以上のメンバーが共有するキー（多いものから） */
  readonly sharedKeys: readonly string[];
  /** 組内の対の Jaccard 係数の最大値（強さの指標） */
  readonly topJaccard: number;
  /** 組がカテゴリを跨いでいるか（現行 /ace-refine の索引目視では隣り合わない組） */
  readonly crossCategory: boolean;
}>;

/**
 * 候補対としては成立したのに、完全連結の制約で組へ入れられなかった対。
 * 「検出したが組にできなかった」分であり、`--max-groups` の表示打ち切りとは別勘定。
 */
export type UngroupedPair = Readonly<{
  readonly members: readonly [MergeCandidateMember, MergeCandidateMember];
  readonly sharedKeys: readonly string[];
  readonly jaccard: number;
  readonly crossCategory: boolean;
}>;

export type MergeCandidateAnalysis = Readonly<{
  readonly groups: readonly MergeCandidateGroup[];
  readonly ungroupedPairs: readonly UngroupedPair[];
  /** 閾値を満たした候補対の総数（組へ入ったものも入らなかったものも含む） */
  readonly qualifyingPairs: number;
  /** 候補対を 1 つ以上持つエントリの実数 */
  readonly pairedEntries: number;
  /** 候補対を持つのにどの組にも入らなかったエントリの実数 */
  readonly ungroupedEntries: number;
}>;

export type CategoryBreakdown = Readonly<{
  readonly category: string;
  readonly total: number;
  readonly compactTotal: number;
  readonly legacyTotal: number;
  readonly compactCandidates: number;
  readonly legacyCandidates: number;
}>;

export type AbstractionReport = Readonly<{
  readonly totalEntries: number;
  readonly compactEntries: number;
  readonly legacyEntries: number;
  readonly candidateEntries: number;
  readonly compactCandidates: number;
  readonly legacyCandidates: number;
  readonly strongCandidates: number;
  readonly categories: readonly CategoryBreakdown[];
  readonly candidates: readonly AbstractionEntry[];
  readonly groups: readonly MergeCandidateGroup[];
  /**
   * 統合候補の組に含まれる**延べ**エントリ数（メンバー数の総和）。極大クリークは
   * 重なりうるので、同じ ID が複数の組に現れる分だけ実数より大きくなる。
   * 読む側が「何件のエントリを読むことになるか」を知りたいときは groupedEntryCount を見る。
   */
  readonly groupedEntries: number;
  /** 組に現れるエントリの**実数**（重複を除いた distinct 件数） */
  readonly groupedEntryCount: number;
  readonly ungroupedPairs: readonly UngroupedPair[];
  readonly qualifyingPairs: number;
  readonly pairedEntries: number;
  readonly ungroupedEntries: number;
}>;

/** エントリセグメントを「見出し直後のメタ行ブロック」と「本文」へ切る。 */
type EntryParts = Readonly<{ readonly metaBlock: string; readonly bodyLines: readonly string[] }>;

/**
 * 見出しの直後に**連続する**テーブル行だけをメタ行ブロックとして切り出す。
 *
 * かつては「行頭が `|` の行」をすべて落としていたが、それは本文中の**通常のテーブル**まで
 * 落としていた（live corpus で 12 エントリ）。本文の表に書かれた固有名は測るべき対象なので、
 * メタ行の除外は位置（見出し直後の連続ブロック）で限定する。anchor 行と先行する空行は
 * ブロックの手前として読み飛ばす。
 */
function splitEntryParts(scannable: string): EntryParts {
  const lines = scannable.split("\n").slice(1); // 見出し行は title として別に渡される
  let index = 0;
  while (
    index < lines.length &&
    (lines[index].trim() === "" || ANCHOR_LINE.test(lines[index]))
  ) {
    index += 1;
  }
  const meta: string[] = [];
  while (index < lines.length && META_TABLE_LINE.test(lines[index])) {
    meta.push(lines[index]);
    index += 1;
  }
  return { metaBlock: meta.join("\n"), bodyLines: lines.slice(index) };
}

/**
 * 旧テーブル形式の `**Context**:` 段落を落とす（次の `**Xxx**:` マーカーまで）。
 *
 * 旧形式の `Context` は「その知見が出た調査ログ」を構造的に置く枠で、PR 番号と
 * 具体パスが必ず入る。ここを数えると旧形式は 60/60 が候補になり、シグナルが測るのは
 * 抽象度不足ではなく**書式の冗長性**になる。`Insight` / `Action` は compact の本文と
 * 同じ役割（主張と処方）なので残し、compact と同じ意味で測れるようにする。
 */
function stripLegacyContextParagraph(bodyLines: readonly string[]): string[] {
  const kept: string[] = [];
  let inContext = false;
  for (const line of bodyLines) {
    if (LEGACY_CONTEXT_MARKER.test(line)) {
      inContext = true;
      continue;
    }
    if (inContext) {
      // 次の段落マーカー、または空行の後に来る非マーカー行で Context 段落は終わる。
      if (LEGACY_PARAGRAPH_MARKER.test(line)) {
        inContext = false;
      } else {
        continue;
      }
    }
    kept.push(line);
  }
  return kept;
}

/**
 * シグナル計測の対象テキストを組み立てる。
 *
 * 除外するもの:
 * - **見出し直後の**メタ行ブロック（`| Category | tooling | Origin | PR #49 |` 等）—
 *   Origin の PR 番号は出所の記録であって本文の固有名ではない。ここを数えると全エントリが
 *   候補になる。本文中の通常のテーブルは**除外しない**
 * - コードフェンス — 例示は常に許されるので固有名として数えない
 * - anchor 行 / 水平線 / `##` 見出し
 * - ACE エントリ間の相互参照リンク — `./testing.md#ace-361-1` の `.md` を
 *   ファイルパスとして数えないため、リンク構文ごと落とす
 * - legacy 形式の `**Context**:` 段落（stripLegacyContextParagraph 参照）
 */
function buildSignalText(scannable: string, title: string, format: EntryFormat): string {
  const { bodyLines } = splitEntryParts(scannable);
  const withoutContext =
    format === "legacy" ? stripLegacyContextParagraph(bodyLines) : [...bodyLines];
  const body = withoutContext
    .filter(
      (line) =>
        !HORIZONTAL_RULE_LINE.test(line) &&
        !ANCHOR_LINE.test(line) &&
        !SECTION_HEADING.test(line),
    )
    .join("\n");
  return `${title}\n${body}`.replace(ACE_CROSS_REFERENCE_LINK, " ");
}

/**
 * コードスパンを正規化形で重複排除する（表記は最初の出現を残す）。
 *
 * 同じ識別子を本文で何度も書いただけで識別子 3 件 / 6 件の閾値を超えるのは、
 * 「固有名の**種類**が多い」というシグナルの意図と食い違う（live corpus では
 * 34 件が重複で水増しされ、うち 12 件は重複を除くと候補から外れた）。
 */
function dedupeByNormalizedForm(spans: readonly string[]): string[] {
  const seen = new Set<string>();
  const unique: string[] = [];
  for (const span of spans) {
    const key = normalizeKey(span);
    if (key === "" || seen.has(key)) {
      continue;
    }
    seen.add(key);
    unique.push(span);
  }
  return unique;
}

function computeSignals(signalText: string): AbstractionSignals {
  const spans = [...signalText.matchAll(CODE_SPAN)].map((match) => match[1]);
  const paths = dedupeByNormalizedForm(spans.filter((span) => PATH_LIKE.test(span)));
  const identifiers = dedupeByNormalizedForm(spans.filter((span) => !PATH_LIKE.test(span)));
  const issueRefs = [...signalText.matchAll(ISSUE_REFERENCE)].map((match) => match[0]);
  return { issueRefs, paths, identifiers };
}

function scoreSignals(signals: AbstractionSignals): number {
  return (
    (signals.issueRefs.length > 0 ? 2 : 0) +
    (signals.paths.length > 0 ? 1 : 0) +
    (signals.identifiers.length >= IDENTIFIER_SIGNAL_THRESHOLD ? 1 : 0) +
    (signals.identifiers.length >= IDENTIFIER_DENSE_THRESHOLD ? 1 : 0)
  );
}

/** 照合キーの正規化: 小文字化し、記号（`$` `{` `}` 引用符・括弧・句読点）を落とす */
function normalizeKey(raw: string): string {
  return raw
    .toLowerCase()
    .replace(/[`'"$(){}[\]（）、。,.:;!?]/gu, " ")
    .replace(/\s+/gu, " ")
    .trim();
}

function buildKeys(title: string, signals: AbstractionSignals): string[] {
  const keys = new Set<string>();
  for (const identifier of signals.identifiers) {
    const key = normalizeKey(identifier);
    if (key.length >= MIN_KEY_LENGTH) {
      keys.add(key);
    }
  }
  for (const word of normalizeKey(title).split(/[\s/]+/u)) {
    // 日本語タイトルは分かち書きされないため、ラテン文字を含む語だけをキーに採る。
    // 数字のみの語（"3.2" → "3 2"）は落ちる。
    if (word.length >= MIN_TITLE_WORD_LENGTH && /[a-z]/u.test(word)) {
      keys.add(word);
    }
  }
  return [...keys];
}

/** エントリ範囲を後続の `##` セクション（Changelog 等）の手前で打ち切る。 */
function truncateAtSectionHeading(segmentText: string): string {
  const lines = segmentText.split("\n");
  const cut = lines.findIndex((line) => SECTION_HEADING.test(line));
  return cut === -1 ? segmentText : lines.slice(0, cut).join("\n");
}

/** 入力そのものが不完全でレポートを出せない状態（使用方法エラーとして扱う） */
export class PlaybookInputError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "PlaybookInputError";
  }
}

/**
 * PLAYBOOK 本文（**1 ファイル分**）を ACE エントリへ切り、固有名シグナルを計測する。
 *
 * 前処理の順序が結果を決める。HTML コメント空白化 → **ファイル全体のフェンス空白化** →
 * 分割、の順で行う。分割してからセグメント単位でフェンスを空白化すると、閉じたフェンス内の
 * `### ACE-9-9:` が実エントリとして数えられ、例示中の固有名がスコアへ入る
 * （check-category-size / check-entry-format / ace-reuse-report と同じ前処理へ揃える）。
 *
 * 未閉フェンスは EOF まで空白化が及んで以降のエントリを静かに吸収するため、
 * **黙って原文へ退避せず** PlaybookInputError を投げる（呼び出し側は usage error で止める）。
 * 「候補 0 件の正常レポート」と「入力が壊れていて測れていない」を取り違えないため。
 *
 * 各エントリの範囲は後続の `##` 見出し（Changelog 等）の手前で打ち切る。打ち切らないと
 * 最終エントリのセグメントがファイル末尾まで伸び、Changelog 配下の PR 番号・コードスパンが
 * 最終エントリのスコアへ混入する。**呼び出し側はファイルを連結せず 1 ファイルずつ渡すこと** —
 * 連結すると次ファイルの前書きを直前ファイルの最終エントリが吸収する（main を参照）。
 */
export function parseAbstractionEntries(
  content: string,
  onWarn: (message: string) => void = (message) => console.warn(message),
): AbstractionEntry[] {
  const fence = scanUnclosedFence(content);
  if (fence.found) {
    throw new PlaybookInputError(
      `コードフェンスが閉じていません（${String(fence.line + 1)} 行目に始まるフェンス。走査単位=${fence.scope}）`,
    );
  }
  const cleaned = blankHtmlBlockComments(content);
  const fencedHeadings = findFencedCanonicalHeadings(cleaned);
  if (fencedHeadings.length > 0) {
    // 黙って除外しない — 件数ゲートが fail-loud に拒否する状態なので、こちらでも名指しする。
    onWarn(
      `${WARN_PREFIX}: フェンス内に正準形の見出しがあります（${fencedHeadings
        .map((heading) => `${heading.id}: ${String(heading.line + 1)} 行目`)
        .join(" / ")}）。エントリとしては数えません（例示は ACE-XXX へ）`,
    );
  }
  const blanked = blankFencedCodeBlocks(cleaned);
  const { entries: segments } = splitEntrySegments(blanked.text);
  const entries: AbstractionEntry[] = [];

  for (const segment of segments) {
    const scannable = truncateAtSectionHeading(segment.text);
    const heading = ENTRY_HEADING_LINE.exec(scannable);
    if (heading === null) {
      onWarn(
        `${WARN_PREFIX}: ${String(segment.startLine + 1)} 行目のエントリ見出しを解釈できません（スキップします）`,
      );
      continue;
    }
    const id = heading[1];
    const title = heading[2].trim();
    if (title === "") {
      onWarn(`${WARN_PREFIX}: ${id} の見出しにタイトルがありません（空として扱います）`);
    }
    // Category はメタ行ブロックからだけ読む（本文中の表に `| Category | … |` の行が
    // あっても、それはエントリのメタデータではない）。
    const { metaBlock } = splitEntryParts(scannable);
    const categoryMatch = CATEGORY_CELL.exec(metaBlock);
    if (categoryMatch === null) {
      onWarn(`${WARN_PREFIX}: ${id} の Category 行が見つかりません（unknown として扱います）`);
    }
    // 旧形式の判定は check-entry-format の detectLegacyMarkers を共有する（単一源）。
    // `**Insight**` だけを見る自前判定は、メタ表ヘッダ行・区切り行だけが残った旧形式を
    // compact と誤分類し、形式ゲートと分裂する（3 マーカーの OR 契約は #441 で確定済み）。
    const body = scannable.split("\n").slice(1).join("\n");
    const format: EntryFormat = detectLegacyMarkers(body).length > 0 ? "legacy" : "compact";
    const signalText = buildSignalText(scannable, title, format);
    const signals = computeSignals(signalText);
    entries.push({
      id,
      title,
      category: categoryMatch === null ? "unknown" : categoryMatch[1].trim(),
      format,
      signals,
      score: scoreSignals(signals),
      keys: buildKeys(title, signals),
    });
  }

  return entries;
}

export type MergeCandidateOptions = Readonly<{
  readonly minSharedKeys?: number | undefined;
  readonly minJaccard?: number | undefined;
}>;

type Pairing = Readonly<{
  readonly a: number;
  readonly b: number;
  readonly shared: readonly string[];
  readonly jaccard: number;
}>;

/**
 * 「抽象度を 1 段上げれば同一のアクションに畳める」組を出す。
 *
 * **カテゴリ横断を許す**のが現行 /ace-refine 手順 2 との差である。着手時の精読で
 * 確定した 7 組のうち 5 組がカテゴリを跨いでおり、同一カテゴリ制約は最も価値の高い
 * 候補（同じ事実の三重記録など）をちょうど落としていた。索引テーブルのタイトル列を
 * 目視する現行手順では、カテゴリが分かれた組は物理的に隣り合わない。
 *
 * **legacy（旧テーブル形式）は組の対象から外す。** ADR-047 決定 4 のとおり、旧形式の
 * 候補は「抽象度不足」ではなく「正準化未了」であり、行き先は R3-b（圧縮・正準化）で
 * R3-c（統合）ではない。混ぜると R3-c の入力に正準化待ちが紛れる。
 *
 * 組は**極大クリーク**（組の中のどの 2 件も直接の候補対で、かつそれ以上広げられない集合）
 * として列挙する。貪欲な完全連結は「先に強い対で組を作ると、後から来た有効な対が
 * どの組にも入れず消える」形を作り、live 実測では候補対を持つ 110 件のうち 22 件が
 * 落ちていた。極大クリークなら**すべての候補対がいずれかの組に含まれる**（辺は必ず
 * どこかの極大クリークの内側にある）ため、検出した対が痕跡なく消えることがない。
 * 連結成分（推移閉包）を使わない理由は逆側で、`bash` / `grep` のような汎用キーで鎖が
 * 繋がり、実測で 40 件の毛玉が 1 組できたためである。
 *
 * **1 つのエントリが複数の組に現れることを許す**（極大クリークは重なりうる）。
 * 「A は B とも C とも畳めるが B と C は畳めない」は実際にある形で、片方を落とすと
 * 有効な統合候補が消える。読む側は同じ ID が 2 度出ることを前提に、どちらを採るかを
 * 判断する（README の該当節に明記）。
 *
 * 「上位主張から元エントリそれぞれのアクションが再導出できるか」の判定は LLM 側の仕事で、
 * ここは読む対象を絞るところまでしかやらない。
 */
export function analyzeMergeCandidates(
  entries: readonly AbstractionEntry[],
  options: MergeCandidateOptions = {},
): MergeCandidateAnalysis {
  const minShared = options.minSharedKeys ?? MIN_SHARED_KEYS;
  const minJaccard = options.minJaccard ?? MIN_JACCARD;
  // 組生成の母集団は compact のみ（legacy は R3-b へ回す。ADR-047 決定 4）。
  const indices = entries
    .map((entry, index) => ({ entry, index }))
    .filter(({ entry }) => entry.format === "compact")
    .map(({ index }) => index);
  const keySets = new Map<number, Set<string>>(
    indices.map((index) => [index, new Set(entries[index].keys)]),
  );
  const pairings: Pairing[] = [];

  for (let i = 0; i < indices.length; i += 1) {
    const indexA = indices[i];
    const setA = keySets.get(indexA) as Set<string>;
    if (setA.size === 0) {
      continue;
    }
    for (let j = i + 1; j < indices.length; j += 1) {
      const indexB = indices[j];
      const setB = keySets.get(indexB) as Set<string>;
      if (setB.size === 0) {
        continue;
      }
      const shared = [...setA].filter((key) => setB.has(key));
      if (shared.length < minShared) {
        continue;
      }
      const jaccard = shared.length / new Set([...setA, ...setB]).size;
      if (jaccard < minJaccard) {
        continue;
      }
      pairings.push({ a: indexA, b: indexB, shared, jaccard });
    }
  }

  const pairKey = (left: number, right: number): string =>
    left < right ? `${String(left)}:${String(right)}` : `${String(right)}:${String(left)}`;
  const jaccardByPair = new Map(
    pairings.map((pairing) => [pairKey(pairing.a, pairing.b), pairing.jaccard]),
  );

  // 隣接リスト。決定的な出力にするため、頂点も隣接も昇順で扱う。
  const adjacency = new Map<number, Set<number>>();
  for (const pairing of pairings) {
    for (const [self, other] of [
      [pairing.a, pairing.b],
      [pairing.b, pairing.a],
    ] as const) {
      const bucket = adjacency.get(self) ?? new Set<number>();
      bucket.add(other);
      adjacency.set(self, bucket);
    }
  }

  // Bron–Kerbosch（ピボットあり）で極大クリークを列挙する。頂点は候補対を持つ
  // エントリだけ（live 実測で 3 桁）なので、この規模では素朴な実装で十分速い。
  const cliques: number[][] = [];
  const neighborsOf = (vertex: number): Set<number> => adjacency.get(vertex) ?? new Set<number>();
  const expand = (clique: number[], candidates: Set<number>, excluded: Set<number>): void => {
    if (candidates.size === 0 && excluded.size === 0) {
      if (clique.length >= 2) {
        cliques.push([...clique].sort((left, right) => left - right));
      }
      return;
    }
    // ピボットは候補 ∪ 除外の中で次数最大の頂点（分岐を減らす）。同点は番号順で決める。
    let pivot = -1;
    let pivotDegree = -1;
    for (const vertex of [...candidates, ...excluded].sort((left, right) => left - right)) {
      const degree = [...neighborsOf(vertex)].filter((other) => candidates.has(other)).length;
      if (degree > pivotDegree) {
        pivot = vertex;
        pivotDegree = degree;
      }
    }
    const pivotNeighbors = pivot === -1 ? new Set<number>() : neighborsOf(pivot);
    const branchOn = [...candidates]
      .filter((vertex) => !pivotNeighbors.has(vertex))
      .sort((left, right) => left - right);
    for (const vertex of branchOn) {
      const neighbors = neighborsOf(vertex);
      expand(
        [...clique, vertex],
        new Set([...candidates].filter((other) => neighbors.has(other))),
        new Set([...excluded].filter((other) => neighbors.has(other))),
      );
      candidates.delete(vertex);
      excluded.add(vertex);
    }
  };
  expand([], new Set([...adjacency.keys()].sort((left, right) => left - right)), new Set());

  const toMember = (index: number): MergeCandidateMember => ({
    id: entries[index].id,
    category: entries[index].category,
    format: entries[index].format,
    title: entries[index].title,
  });

  const groups: MergeCandidateGroup[] = cliques.map((clique) => {
    // 共有シグナルは「2 件以上のメンバーが持つキー」— 3 件以上の組では全メンバーの
    // 積集合が空になることがあり、積集合にすると組の根拠が消える。
    const frequency = new Map<string, number>();
    for (const index of clique) {
      for (const key of keySets.get(index) ?? []) {
        frequency.set(key, (frequency.get(key) ?? 0) + 1);
      }
    }
    const sharedKeys = [...frequency.entries()]
      .filter(([, count]) => count >= 2)
      .sort((left, right) => right[1] - left[1] || left[0].localeCompare(right[0]))
      .map(([key]) => key);
    let topJaccard = 0;
    for (let i = 0; i < clique.length; i += 1) {
      for (let j = i + 1; j < clique.length; j += 1) {
        topJaccard = Math.max(topJaccard, jaccardByPair.get(pairKey(clique[i], clique[j])) ?? 0);
      }
    }
    const members = clique.map((index) => toMember(index));
    return {
      members,
      sharedKeys,
      topJaccard,
      crossCategory: new Set(members.map((member) => member.category)).size > 1,
    };
  });

  // 並び順は「件数 → 最大 Jaccard → メンバー ID 列」で決める。先頭 ID だけで比べると、
  // 同じエントリを共有する 2 組（極大クリークは重なりうる）が同点になり、順序が
  // クリーク列挙の内部順に落ちる。ID 列まで見れば順序は内容だけで決まる。
  const memberKey = (group: MergeCandidateGroup): string =>
    group.members.map((member) => member.id).join("\u0000");
  groups.sort(
    (left, right) =>
      right.members.length - left.members.length ||
      right.topJaccard - left.topJaccard ||
      memberKey(left).localeCompare(memberKey(right)),
  );

  // 極大クリークはすべての候補対を覆うため、ここは構造的に 0 件になる。0 件であること
  // 自体が「検出した対を 1 つも捨てていない」ことの監査になるので、集計は残して出す
  // （実装が退行して対を落とすようになったら、この数が 0 でなくなって表に出る）。
  const coveredPairs = new Set<string>();
  for (const clique of cliques) {
    for (let i = 0; i < clique.length; i += 1) {
      for (let j = i + 1; j < clique.length; j += 1) {
        coveredPairs.add(pairKey(clique[i], clique[j]));
      }
    }
  }
  const ungroupedPairs: UngroupedPair[] = pairings
    .filter((pairing) => !coveredPairs.has(pairKey(pairing.a, pairing.b)))
    .map((pairing) => ({
      members: [toMember(pairing.a), toMember(pairing.b)] as const,
      sharedKeys: [...pairing.shared].sort((left, right) => left.localeCompare(right)),
      jaccard: pairing.jaccard,
      crossCategory: entries[pairing.a].category !== entries[pairing.b].category,
    }));

  const pairedIndices = new Set<number>();
  for (const pairing of pairings) {
    pairedIndices.add(pairing.a);
    pairedIndices.add(pairing.b);
  }
  const groupedIndices = new Set(cliques.flat());
  const ungroupedEntries = [...pairedIndices].filter(
    (index) => !groupedIndices.has(index),
  ).length;

  return {
    groups,
    ungroupedPairs,
    qualifyingPairs: pairings.length,
    pairedEntries: pairedIndices.size,
    ungroupedEntries,
  };
}

/**
 * 後方互換の薄いラッパー。組だけが要る呼び出し側（テストを含む）はこちらを使う。
 * 未配置対の集計も要るときは analyzeMergeCandidates を直接呼ぶこと。
 */
export function findMergeCandidateGroups(
  entries: readonly AbstractionEntry[],
  options: MergeCandidateOptions = {},
): MergeCandidateGroup[] {
  return [...analyzeMergeCandidates(entries, options).groups];
}

export function buildAbstractionReport(
  entries: readonly AbstractionEntry[],
  analysis: MergeCandidateAnalysis,
): AbstractionReport {
  const { groups } = analysis;
  const isCandidate = (entry: AbstractionEntry): boolean =>
    entry.score >= CANDIDATE_SCORE_THRESHOLD;
  const categoryNames = [...new Set(entries.map((entry) => entry.category))].sort((a, b) =>
    a.localeCompare(b),
  );
  const categories = categoryNames.map((category) => {
    const inCategory = entries.filter((entry) => entry.category === category);
    const compact = inCategory.filter((entry) => entry.format === "compact");
    const legacy = inCategory.filter((entry) => entry.format === "legacy");
    return {
      category,
      total: inCategory.length,
      compactTotal: compact.length,
      legacyTotal: legacy.length,
      compactCandidates: compact.filter(isCandidate).length,
      legacyCandidates: legacy.filter(isCandidate).length,
    };
  });
  const candidates = entries
    .filter(isCandidate)
    .slice()
    .sort((left, right) => right.score - left.score || left.id.localeCompare(right.id));
  return {
    totalEntries: entries.length,
    compactEntries: entries.filter((entry) => entry.format === "compact").length,
    legacyEntries: entries.filter((entry) => entry.format === "legacy").length,
    candidateEntries: candidates.length,
    compactCandidates: candidates.filter((entry) => entry.format === "compact").length,
    legacyCandidates: candidates.filter((entry) => entry.format === "legacy").length,
    strongCandidates: candidates.filter((entry) => entry.score >= STRONG_SCORE_THRESHOLD).length,
    categories,
    candidates,
    groups,
    groupedEntries: groups.reduce((sum, group) => sum + group.members.length, 0),
    groupedEntryCount: new Set(
      groups.flatMap((group) => group.members.map((member) => member.id)),
    ).size,
    ungroupedPairs: analysis.ungroupedPairs,
    qualifyingPairs: analysis.qualifyingPairs,
    pairedEntries: analysis.pairedEntries,
    ungroupedEntries: analysis.ungroupedEntries,
  };
}

// `exactOptionalPropertyTypes` が有効なので、省略と明示的な undefined を同じに扱うには
// `| undefined` を明示する（parseArgs は指定の無いフラグを undefined のまま載せる）。
export type FormatOptions = Readonly<{
  readonly maxGroups?: number | undefined;
  readonly maxCandidates?: number | undefined;
  readonly maxUngroupedPairs?: number | undefined;
}>;

function escapeCell(value: string): string {
  return value.replace(/\|/gu, "\\|");
}

export function formatAbstractionReport(
  report: AbstractionReport,
  options: FormatOptions = {},
): string {
  const maxGroups = options.maxGroups ?? DEFAULT_MAX_GROUPS;
  const maxCandidates = options.maxCandidates ?? DEFAULT_MAX_CANDIDATES;
  const maxUngroupedPairs = options.maxUngroupedPairs ?? DEFAULT_MAX_UNGROUPED_PAIRS;
  const lines: string[] = [];

  lines.push("# ACE 抽象度レポート（報告のみ / dry-run）");
  lines.push("");
  lines.push(
    `対象エントリ: ${String(report.totalEntries)} 件（compact ${String(report.compactEntries)} / legacy ${String(report.legacyEntries)}）`,
  );
  lines.push(
    `抽象度の下限を下回る候補: ${String(report.candidateEntries)} 件（compact ${String(report.compactCandidates)} / legacy ${String(report.legacyCandidates)}、うち強い候補 ${String(report.strongCandidates)} 件）`,
  );
  lines.push(
    `統合候補: ${String(report.groups.length)} 組（延べ ${String(report.groupedEntries)} 件 / 実数 ${String(report.groupedEntryCount)} 件）`,
  );
  lines.push(
    `候補対: ${String(report.qualifyingPairs)} 対 / ${String(report.pairedEntries)} 件（うち組にできなかった対 ${String(report.ungroupedPairs.length)} 対・どの組にも入らなかったエントリ ${String(report.ungroupedEntries)} 件）`,
  );
  lines.push("");
  lines.push(
    "> 候補は判定結果ではありません。最終判定は `/ace-curate` の新規性バー（抽象度の下限）と",
  );
  lines.push(
    "> `/ace-refine` 手順 2 の LLM 判断が行います。legacy（旧テーブル形式）の候補は抽象度不足ではなく",
  );
  lines.push("> 書式の冗長性を測っているため、R3-b（圧縮 / 正準化）へ回してください。");
  lines.push("");

  lines.push("## カテゴリ別内訳");
  lines.push("");
  lines.push("| カテゴリ | 件数 | compact 件数 | compact 候補 | legacy 件数 | legacy 候補 |");
  lines.push("| --- | ---: | ---: | ---: | ---: | ---: |");
  for (const row of report.categories) {
    lines.push(
      `| ${escapeCell(row.category)} | ${String(row.total)} | ${String(row.compactTotal)} | ${String(row.compactCandidates)} | ${String(row.legacyTotal)} | ${String(row.legacyCandidates)} |`,
    );
  }
  lines.push("");

  lines.push("## 統合候補（抽象度を 1 段上げれば同一のアクションへ畳める組）");
  lines.push("");
  if (report.groups.length === 0) {
    lines.push("該当なし。");
    lines.push("");
  } else {
    const shown = report.groups.slice(0, maxGroups);
    for (const [index, group] of shown.entries()) {
      const scope = group.crossCategory ? "カテゴリ横断" : "同一カテゴリ";
      lines.push(
        `### 組 ${String(index + 1)}: ${String(group.members.length)} 件 / ${scope} / 最大 Jaccard ${group.topJaccard.toFixed(2)}`,
      );
      lines.push("");
      lines.push("| ID | カテゴリ | 形式 | タイトル |");
      lines.push("| --- | --- | --- | --- |");
      for (const member of group.members) {
        lines.push(
          `| ${member.id} | ${escapeCell(member.category)} | ${member.format} | ${escapeCell(member.title)} |`,
        );
      }
      lines.push("");
      lines.push(
        `共有シグナル: ${group.sharedKeys.slice(0, 8).map((key) => `\`${key}\``).join(" / ")}`,
      );
      lines.push("");
    }
    if (report.groups.length > shown.length) {
      lines.push(
        `（残り ${String(report.groups.length - shown.length)} 組は省略。\`--max-groups\` で拡張できます）`,
      );
      lines.push("");
    }
  }

  lines.push("## 組にできなかった候補対");
  lines.push("");
  lines.push(
    "> 完全連結の制約（組の中のどの 2 件も直接の候補対であること）で組へ入らなかった対です。",
  );
  lines.push(
    "> 上の「省略」とは別勘定で、こちらは**検出はしたが組にできなかった**分です。対単位では有効な候補なので、",
  );
  lines.push("> 組が尽きたらここも読んでください。");
  lines.push("");
  if (report.ungroupedPairs.length === 0) {
    lines.push("該当なし。");
    lines.push("");
  } else {
    const shown = report.ungroupedPairs.slice(0, maxUngroupedPairs);
    lines.push("| A | B | Jaccard | 範囲 | 共有シグナル |");
    lines.push("| --- | --- | ---: | --- | --- |");
    for (const pair of shown) {
      const [first, second] = pair.members;
      lines.push(
        `| ${first.id} (${escapeCell(first.category)}) | ${second.id} (${escapeCell(second.category)}) | ${pair.jaccard.toFixed(2)} | ${pair.crossCategory ? "横断" : "同一"} | ${pair.sharedKeys
          .slice(0, 6)
          .map((key) => `\`${escapeCell(key)}\``)
          .join(" / ")} |`,
      );
    }
    lines.push("");
    if (report.ungroupedPairs.length > shown.length) {
      lines.push(
        `（残り ${String(report.ungroupedPairs.length - shown.length)} 対は省略。\`--max-ungrouped-pairs\` で拡張できます）`,
      );
      lines.push("");
    }
  }

  lines.push("## 抽象度の下限を下回る候補エントリ");
  lines.push("");
  if (report.candidates.length === 0) {
    lines.push("該当なし。");
    lines.push("");
  } else {
    const shown = report.candidates.slice(0, maxCandidates);
    lines.push("| ID | カテゴリ | 形式 | score | 参照 | パス | 識別子 | タイトル |");
    lines.push("| --- | --- | --- | ---: | ---: | ---: | ---: | --- |");
    for (const entry of shown) {
      lines.push(
        `| ${entry.id} | ${escapeCell(entry.category)} | ${entry.format} | ${String(entry.score)} | ${String(entry.signals.issueRefs.length)} | ${String(entry.signals.paths.length)} | ${String(entry.signals.identifiers.length)} | ${escapeCell(entry.title)} |`,
      );
    }
    lines.push("");
    if (report.candidates.length > shown.length) {
      lines.push(
        `（残り ${String(report.candidates.length - shown.length)} 件は省略。\`--max-candidates\` で拡張できます）`,
      );
      lines.push("");
    }
  }

  return lines.join("\n");
}

export type ParsedArgs =
  | Readonly<{ readonly ok: true; readonly playbookPath: string; readonly json: boolean } & FormatOptions>
  | Readonly<{ readonly ok: false; readonly message: string }>;

/**
 * `<playbook>` に加えて `--json` / `--max-groups=N` / `--max-candidates=N` /
 * `--max-ungrouped-pairs=N` を受ける。
 */
export function parseArgs(argv: readonly string[]): ParsedArgs {
  let playbookPath: string | undefined;
  let json = false;
  let maxGroups: number | undefined;
  let maxCandidates: number | undefined;
  let maxUngroupedPairs: number | undefined;

  const readCount = (raw: string): number | undefined => {
    if (!/^[0-9]+$/u.test(raw)) {
      return undefined;
    }
    const parsed = Number.parseInt(raw, 10);
    return parsed >= 1 && Number.isSafeInteger(parsed) ? parsed : undefined;
  };

  for (const arg of argv) {
    if (arg === "--json") {
      json = true;
      continue;
    }
    if (arg.startsWith("--max-groups=")) {
      const value = readCount(arg.slice("--max-groups=".length));
      if (value === undefined) {
        return { ok: false, message: `--max-groups は 1 以上の整数で指定してください: ${arg}` };
      }
      maxGroups = value;
      continue;
    }
    if (arg.startsWith("--max-candidates=")) {
      const value = readCount(arg.slice("--max-candidates=".length));
      if (value === undefined) {
        return { ok: false, message: `--max-candidates は 1 以上の整数で指定してください: ${arg}` };
      }
      maxCandidates = value;
      continue;
    }
    if (arg.startsWith("--max-ungrouped-pairs=")) {
      const value = readCount(arg.slice("--max-ungrouped-pairs=".length));
      if (value === undefined) {
        return {
          ok: false,
          message: `--max-ungrouped-pairs は 1 以上の整数で指定してください: ${arg}`,
        };
      }
      maxUngroupedPairs = value;
      continue;
    }
    if (arg.startsWith("-")) {
      return { ok: false, message: `不明なオプションです: ${arg}` };
    }
    if (playbookPath !== undefined) {
      return { ok: false, message: `PLAYBOOK のパスは 1 つだけ指定してください: ${arg}` };
    }
    playbookPath = arg;
  }

  if (playbookPath === undefined) {
    return { ok: false, message: "PLAYBOOK のパスが指定されていません" };
  }
  return { ok: true, playbookPath, json, maxGroups, maxCandidates, maxUngroupedPairs };
}

const USAGE =
  "Usage: npx --yes tsx docs-template/scripts/ace/ace-abstraction-report.ts <path/to/PLAYBOOK.md> [--json] [--max-groups=N] [--max-candidates=N] [--max-ungrouped-pairs=N]";

/**
 * テスト用の注入ポイント。既定は実ファイル読み込み（ace-reuse-report の MainDeps と同じ作法）。
 * 書き込み系の口は**持たせない** — dry-run 既定は「オプションが無い」ことで保証する。
 */
export type MainDeps = Readonly<{
  readonly readFile: (filePath: string) => string;
}>;

const DEFAULT_DEPS: MainDeps = {
  readFile: (filePath) => fs.readFileSync(filePath, "utf8"),
};

/**
 * CLI エントリポイント。**読み取り専用**（書き込み経路を一切持たない）。
 *
 * 終了コード: 0 = レポートを出せた（候補が何件でも 0）/ 1 = 実行時エラー（読み込み失敗等）/
 * 2 = 使用方法エラー（パス未指定・不明なオプション・ファイル不在・**ACE エントリ 0 件**・
 * **未閉フェンス**）。ゲートではないので候補の件数は終了コードに影響しないが、
 * 「測れていない」入力は 0 で通さない。
 */
export function main(
  argv: readonly string[] = process.argv.slice(2),
  deps: MainDeps = DEFAULT_DEPS,
): number {
  const parsed = parseArgs(argv);
  if (!parsed.ok) {
    console.error(`ERROR: ${parsed.message}`);
    console.error(USAGE);
    return EXIT_USAGE_ERROR;
  }
  const { playbookPath } = parsed;
  if (!fs.existsSync(playbookPath) || !fs.statSync(playbookPath).isFile()) {
    console.error(`ERROR: PLAYBOOK ファイルが見つかりません: ${playbookPath}`);
    return EXIT_USAGE_ERROR;
  }

  try {
    // 分割レイアウト（playbook/*.md）ではエントリ本体はサブファイル側にある。
    // **ファイルを連結せず 1 ファイルずつ解析する** — 連結すると次ファイルの前書きを
    // 直前ファイルの最終エントリのセグメントが吸収し、そこにある PR 番号・パスが
    // 最終エントリのスコアへ混入する。
    const targets = [playbookPath, ...discoverPlaybookSubfiles(playbookPath)];
    const entries = targets.flatMap((file) => parseAbstractionEntries(deps.readFile(file)));
    if (entries.length === 0) {
      // レポートを出さずに止める（ace-refine-report の 0 件 = usage error と同じ契約）。
      // 誤ったパスを渡したときに「対象 0 / 候補 0」の正常レポートが出ると、「整理対象なし」
      // として読まれてしまう。「候補が無い」と「まだ何も測れていない」を取り違えない。
      console.error(
        `ERROR: ACE エントリが 0 件でした。playbookPath や playbook/ サブディレクトリの指定を確認してください: ${playbookPath}`,
      );
      return EXIT_USAGE_ERROR;
    }
    const analysis = analyzeMergeCandidates(entries);
    const report = buildAbstractionReport(entries, analysis);
    if (parsed.json) {
      console.log(JSON.stringify(report, null, 2));
    } else {
      console.log(
        formatAbstractionReport(report, {
          maxGroups: parsed.maxGroups,
          maxCandidates: parsed.maxCandidates,
          maxUngroupedPairs: parsed.maxUngroupedPairs,
        }),
      );
    }
    return EXIT_OK;
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    if (error instanceof PlaybookInputError) {
      // 入力そのものが不完全（未閉フェンス等）。候補 0 件の正常レポートと区別するため、
      // レポートを出さずに usage error で止める。
      console.error(`ERROR: 入力を解析できません: ${message}`);
      return EXIT_USAGE_ERROR;
    }
    console.error(`ERROR: レポート生成に失敗しました: ${message}`);
    return EXIT_RUNTIME_ERROR;
  }
}

// 直接実行（tsx 経由の CLI）のときのみ自動実行する。判定は isDirectExecution
// （パス完全一致）で、check-category-size と同じ契約。
if (isDirectExecution(import.meta.url, process.argv[1])) {
  process.exitCode = main();
}
