/**
 * Behavior-preserving split of check-category-size.ts (ADR-080).
 * Playbook analysis, merge, and discovery.
 */
import * as fs from "node:fs";
import {
  KnowledgeReadBoundary,
  knowledgeReaderForSelection,
  knowledgeInputExists,
} from "./knowledge-read-boundary";
import * as path from "node:path";
import {
  ACE_ENTRY_ID_SOURCE,
  CATEGORY_TABLE_LINE_PATTERN,
  DEFAULT_MAX_ENTRIES_PER_CATEGORY,
  DEFAULT_MAX_ENTRY_LINES,
  DEFAULT_MAX_PLAYBOOK_LINES,
  DEFAULT_WARN_ENTRIES_PER_CATEGORY,
  ENTRY_HEADING_ID_PATTERN,
  INDEX_ROW_ID_CELL_PATTERN,
  alsoUnparsable,
  describeUnparsable,
  entryHeadingNotFoundMessage,
} from "./check-category-size";
import {
  type AnalyzeResult,
  type AnalyzeSuccess,
  CATEGORY_HEADER_LABEL_PATTERN,
  CATEGORY_SLUG_PATTERN,
  type CategoryHistogram,
  type EntryCategoryMap,
  ID_HEADER_LABEL_PATTERN,
  INDEX_SECTION_HEADING_PATTERN,
  type MergeResult,
  SECTION_HEADING_LINE_PATTERN,
  TABLE_DELIMITER_LINE_PATTERN,
  TABLE_ROW_LINE_PATTERN,
  blankFencedCodeBlocks,
  blankHtmlBlockComments,
  findAbsorbedHeadingHints,
  findFencedCanonicalHeadings,
  incrementHistogram,
  isEntryCount,
  splitEntrySegments,
  trimCategoryValue,
} from "./check-category-size-text";

/**
 * PLAYBOOK.md 本文から ACE エントリブロックを走査し、Category 行を集計する。
 * HTML コメント内の追記例（### ACE-001 など）を除外するため、先にコメントを空白化する
 * （行数と行オフセットを保つため除去はしない）。分割は splitEntrySegments（見出し行を
 * 保持する単一源）で行い、コードフェンスの空白化は**分割の後**、セグメント単位で行う。
 * したがってフェンス内に**正準形の** ID を持つ見出しがあると分割はそこで切れる
 * （テンプレートのプレースホルダを `ACE-XXX` のような非正準形に保つ規則は
 * ACE_ENTRY_ID_SOURCE のコメント参照）。この形は本関数冒頭の findFencedCanonicalHeadings
 * が真因（フェンス内の正準形見出し）を名指しで拒否する（Issue `#342`。かつては
 * scanUnclosedFence のセグメント検査が「未閉フェンス」という**誤った診断**で拒否して
 * いた — 現在の scanUnclosedFence はこの形を真因側の診断へ譲る）。分割と
 * countHeaderLines がフェンスを見ない構造自体は変わっていないが、歪みを生む入力は
 * この拒否で commit 前に止まるため無害化されている。
 * `allowEmpty` が true の場合、エントリ見出しが 0 件でもエラーにせず空の結果を返す
 * （分割レイアウトの索引ファイルのように、単体では 0 件が正常なケース向け）。
 */
export function analyzePlaybookMarkdown(
  content: string,
  options: { readonly allowEmpty?: boolean } = {},
): AnalyzeResult {
  const cleaned = blankHtmlBlockComments(content);
  // フェンスが閉じているのに、その内側に正準形の見出しがある形は fail-loud で拒否する
  // （Issue `#342`）。境界をフェンス空白化側へ付け替える案は採らない — セグメント跨ぎで
  // 偶然対になる閉じ忘れ（`#353` の曖昧形）で、実エントリが「引用」として**静かに吸収**
  // される。拒否した上で、例示は非正準形（ACE-XXX）へ直させるのが安全側。
  // 未閉フェンスのときは判定しない（空白化が EOF まで及び、実在の見出しまで
  // 「フェンス内」に見える）— その形は既存の未閉検査が名指しで落とす。
  const fencedHeadings = findFencedCanonicalHeadings(cleaned);
  if (fencedHeadings.length > 0) {
    return {
      kind: "error",
      message:
        `フェンス内に正準形のエントリ見出しがあります（${fencedHeadings
          .map((h) => `${h.id}: ${String(h.line + 1)} 行目`)
          .join(" / ")}）。` +
        "例示なら ID を ACE-XXX のような非正準形にしてください（正準形の例示は分割境界の判定を歪めます）。" +
        "実エントリのつもりなら、直前のコードフェンスの対応（閉じ忘れ・裸の ``` との偶然の対）を確認してください",
    };
  }
  const { header, entries } = splitEntrySegments(cleaned);
  // ヘッダ領域（最初のエントリ見出しより前）も未閉フェンスを検査する。ここを外すと、
  // 打ち間違いがどちら側に落ちたかで検査の有無が変わる。ヘッダの未閉フェンスは
  // blankCodeRegions がファイル全体を走査するため後続の全エントリに波及し、
  // 例外宣言の判定が黙って効かなくなる（Issue `#347` のレビュー実測）。
  const headerScan = blankFencedCodeBlocks(header.text);
  if (headerScan.unclosedFence) {
    return {
      kind: "error",
      message:
        `${String(headerScan.unclosedFenceLine + 1)} 行目に始まる、` +
        "最初の ACE エントリより前（ヘッダ領域）の閉じていないコードフェンス（``` / ~~~）があります。" +
        "以降の本文が走査対象から外れ、行数バジェット例外の判定も黙って効かなくなります。" +
        "フェンスを閉じてください。",
    };
  }
  if (entries.length === 0) {
    if (options.allowEmpty === true) {
      return { kind: "ok", histogram: {}, entryCategories: {}, totalEntries: 0 };
    }
    return {
      kind: "error",
      message: entryHeadingNotFoundMessage(),
    };
  }
  const histogram: Record<string, number> = {};
  const entryCategories: Record<string, string> = {};
  const unparsable: string[] = [];

  for (const entry of entries) {
    // 本文が例示する追記テンプレート（フェンス内の `| Category | … |`）を数えない。
    // **抽出と本数カウントは必ず同じテキストで行う**（Issue `#340`）。カウントだけを
    // 空白化後に行うと、実 Category 行がフェンス例示の**後ろ**にあるブロックで
    // 「本数は 1 本・値は先に現れた例示から採用」となり、誤ったカテゴリへ静かに 1 件入る。
    // 同じテキストで数えれば 0 本 → 解析エラー / 1 本 → ok（値が空なら空値エラー）/
    // 2 本以上 → 吸収エラー、に収まる。
    const blanked = blankFencedCodeBlocks(entry.text);
    // 閉じないフェンスは以降を末尾まで空白化する。実 Category 行はフェンスより前に
    // あるので生き残り、フェンス以降にある**吸収ブロックの Category 行だけ**が消える。
    // つまり本数が 1 本へ戻り、下の吸収検出が一度も発火しない — 偽陽性ガードが
    // 検出器の証拠を消す形になる。閉じ忘れは Playbook の日常的な打ち間違いなので、
    // ace-refine-report.ts の unmeasured クロスチェックと同じく前提が崩れたら落とす。
    if (blanked.unclosedFence) {
      // 位置はセグメントの開始行 + セグメント内の相対行。ファイル名だけでは、
      // 「本文だけを見ると対になって見える」形（ヘッダで開いたフェンスとの対など）で
      // 直しようがない。130 件規模の PLAYBOOK では目視で追うことになる。
      const line = entry.startLine + blanked.unclosedFenceLine + 1;
      return {
        kind: "error",
        message:
          `${String(line)} 行目に始まる、閉じていないコードフェンス（\`\`\` / ~~~）を含む ACE ブロックがあります。` +
          "以降の本文が走査対象から外れ、そこにあるエントリが件数からも Category 集計からも" +
          "静かに消えます。フェンスを閉じてください。" +
          alsoUnparsable(unparsable),
      };
    }
    const scannable = blanked.text;
    const matches = [...scannable.matchAll(CATEGORY_TABLE_LINE_PATTERN)];
    if (matches.length === 0) {
      // 最初の 1 件で返さず全件を集める。1 件ずつ直して再実行させると、全ブロックが同じ理由で
      // 落ちている導入先（実測で 27 ファイル・約 780 件）では原因が書式だと分からない。
      const id = ENTRY_HEADING_ID_PATTERN.exec(entry.text)?.[1] ?? "ID 不明";
      unparsable.push(`${id}（${String(entry.startLine + 1)} 行目）`);
      continue;
    }
    // 1 ブロックに Category 行が 2 本以上あるのは、見出しとして認識されなかった
    // ブロックが直前のエントリへ吸収された形（split がそこで切れなかった）。
    // 検出しないと件数が過少になり、そのカテゴリの唯一のエントリなら histogram から
    // 消えるのに kind:"ok" を返す（Issue `#340`）。
    //
    // 吸収以外の原因（本文が Category 行を素の表として例示している等）でも 2 本になる。
    // メッセージは吸収を第一候補として挙げつつ、重複した Category 行の除去も促す。
    // 空値チェック（この下）より**先**に判定するのは、2 本あること自体が構造の破れで、
    // 値が空かどうかより根本的だから。順序を入れ替えると、吸収された側の値が空の
    // ケースで「値が空」とだけ報告され、ブロックが 2 つ同居している事実が出なくなる。
    if (matches.length >= 2) {
      const values = matches
        .map((entry) => trimCategoryValue(entry[1] ?? "") || "（空）")
        .join(", ");
      // 1 行目はこのセグメント自身の見出し（splitEntrySegments が保持する）。
      // 落とさずに渡すと、正しく認識された見出しが「認識されなかった候補」の先頭に出る。
      const hints = findAbsorbedHeadingHints(scannable.split("\n").slice(1).join("\n"));
      const locator =
        hints.length > 0 ? `認識されなかった見出し候補: ${hints.join(" / ")}。` : "";
      return {
        kind: "error",
        message:
          `見出しとして認識されないブロックが直前の ACE エントリへ吸収されている可能性があります` +
          `（1 ブロック内に Category 行が ${String(matches.length)} 本あります）。` +
          `検出した Category 値: ${values}。${locator}` +
          `見出しの ID が正準形（check-category-size.ts の ACE_ENTRY_ID_SOURCE）から外れていないか、` +
          `Category 行が重複していないかを確認してください。` +
          alsoUnparsable(unparsable),
      };
    }
    const categoryKey = trimCategoryValue(matches[0][1] ?? "");
    // 行はあるが値が空（`| Category |  |`）は、Category 行が無いケースと同様に
    // usage error。空文字キーで集計すると実在カテゴリの件数が過少し、超過時の
    // メッセージも読めなくなる（公開 ff-dev-toolkit#9）。
    if (categoryKey === "") {
      return {
        kind: "error",
        message: "Category の値が空の ACE ブロックがあります。" + alsoUnparsable(unparsable),
      };
    }
    incrementHistogram(histogram, categoryKey);
    // 見出しから ID を取れなかったセグメントは索引の突き合わせ対象から外れるだけで、
    // 件数集計には影響しない（splitEntrySegments は見出しでしか切らないので通常は取れる）。
    const heading = ENTRY_HEADING_ID_PATTERN.exec(entry.text);
    const entryId = heading?.[1];
    if (entryId !== undefined && entryCategories[entryId] === undefined) {
      entryCategories[entryId] = categoryKey;
    }
  }

  if (unparsable.length > 0) {
    return {
      kind: "error",
      message:
        describeUnparsable(unparsable) +
        "Category 行は `| Category | <値> |`（旧テーブル形式なら `| **カテゴリ** | <値> |`）の形で、" +
        "コードフェンスの外に置いてください。",
    };
  }

  return {
    kind: "ok",
    histogram,
    entryCategories,
    totalEntries: entries.length,
  };
}

/**
 * 複数ファイル分の解析結果（分割レイアウト用）をカテゴリ別件数・総件数で合算する。
 *
 * `CategoryHistogram` は `Partial` なので値が `undefined` になりうる。`NaN` へ倒すと比較が
 * 常に false になって超過を見逃すが、**読み飛ばしても同じく見逃す**（totalEntries だけが
 * 大きいまま、そのカテゴリの件数が 0 として扱われる）。どちらも silent に緩む側なので
 * エラーとして返す（呼び出し側が usage error へ写像する。Issue `#343` / 公開 ff-dev-toolkit#10）。
 * 壊れた histogram は analyzePlaybookMarkdown からは出ないため、これは呼び出し側の
 * 契約違反の検出にあたる。
 *
 * 検証は 2 段。per-value（非負の安全整数か）を先に走らせるのは、どのカテゴリが壊れて
 * いるかを名指しできるのがこちらだけだから。そのうえで **合計 === totalEntries** を
 * backstop に置く。ゲートが実際に依存しているのはこちらで、per-value では届かない
 * 「キーごと脱落した」形（`Object.entries` に現れないので値の検査に到達しない）を拾う。
 * 例: Category 値が `__proto__` のエントリは `{}` への代入が無視されて histogram から
 * 消えるが、totalEntries は増える。この不一致はここでしか検出できない。
 */
export function mergeAnalyses(results: readonly AnalyzeSuccess[]): MergeResult {
  const histogram: Record<string, number> = {};
  const entryCategories: Record<string, string> = {};
  let totalEntries = 0;
  for (const result of results) {
    if (!isEntryCount(result.totalEntries)) {
      return {
        kind: "error",
        message:
          `総エントリ数が非負の整数ではありません（${String(result.totalEntries)}）。` +
          `集計元が壊れているため、件数ゲートの判定を続けると超過を静かに見逃します。`,
      };
    }
    totalEntries += result.totalEntries;
    for (const [categoryKey, count] of Object.entries(result.histogram)) {
      if (!isEntryCount(count)) {
        return {
          kind: "error",
          message:
            `カテゴリ "${categoryKey}" の件数が非負の整数ではありません（${String(count)}）。` +
            `集計元の histogram が壊れているため、件数ゲートの判定を続けると超過を静かに見逃します。`,
        };
      }
      histogram[categoryKey] = (histogram[categoryKey] ?? 0) + count;
    }
    for (const [entryId, category] of Object.entries(result.entryCategories)) {
      if (entryCategories[entryId] === undefined) {
        entryCategories[entryId] = category;
      }
    }
  }
  const summed = Object.values(histogram).reduce((sum, count) => sum + count, 0);
  if (summed !== totalEntries) {
    return {
      kind: "error",
      message:
        `カテゴリ別件数の合計（${String(summed)}）が総エントリ数（${String(totalEntries)}）と一致しません。` +
        `どちらかが脱落しているため、件数ゲートの判定を続けると超過を静かに見逃します。`,
    };
  }
  return { kind: "ok", histogram, entryCategories, totalEntries };
}

/**
 * 指摘の理由。1 つへ畳まないのは直し方が違うため。
 * `missing-column` は Category 列そのものが行に無い、`column-count` はヘッダと列数が違う
 * （セル内の素の `|` が列を増やした形を含む）、`empty` は列はあるが空、
 * `mismatch` は本文の Category と食い違う、`not-a-category` は本文に対応エントリが無く
 * カテゴリ語彙にもスラッグ形にも当たらない。
 */
export type IndexCategoryFindingReason =
  | "missing-column"
  | "column-count"
  | "empty"
  | "mismatch"
  | "not-a-category";

/** 索引行 1 件分の指摘。`line` は 1-origin（利用者へそのまま提示する行番号）。 */
export type IndexCategoryFinding = Readonly<{
  readonly line: number;
  readonly entryId: string;
  readonly reason: IndexCategoryFindingReason;
  /** 索引のカテゴリ列に実際に入っていた値。`missing-column` / `column-count` / `empty` では空文字。 */
  readonly value: string;
  /** 本文の Category 値。`mismatch` のときだけ非空。 */
  readonly expected: string;
}>;

/**
 * scanIndexCategoryColumn の結果。件数と `indexSectionFound` を返すのは、
 * 「指摘 0 件」が検査した結果なのか 1 行も読めなかった結果なのかを呼び出し側から
 * 区別できるようにするため（読めなかった場合を黙って緑にすると、索引テーブルの
 * 書式や節見出しが変わった瞬間に検査だけが静かに無効化される）。
 */
export type IndexCategoryScan = Readonly<{
  readonly findings: readonly IndexCategoryFinding[];
  readonly checkedRows: number;
  /** 索引行だが Category 列の位置を決められなかった行数（ヘッダが無い / ヘッダに Category 列が無い）。 */
  readonly unresolvedRows: number;
  /** 索引テーブルの節（`## エントリ一覧`）が 1 つでも見つかったか。false なら 1 行も検査していない。 */
  readonly indexSectionFound: boolean;
}>;

/** 行末の CR を落とす（CRLF 文書で行末アンカーの正規表現が一致しなくなるのを防ぐ）。 */
function stripCarriageReturn(line: string): string {
  return line.endsWith("\r") ? line.slice(0, -1) : line;
}

/**
 * テーブル行をセルへ分割する。**素の `|` はすべてセル区切りとして扱う**。
 *
 * GFM の表はセル内に `|` を含めるとき、**インラインコードスパンの中でも** `\|` の
 * エスケープを要求する（コードスパンは `|` の分割から行を守らない）。したがって
 * コードスパンを空白化してから境界を決めると、GitHub 上では実際に列がずれている行を
 * 検査が緑にする。この関数はフェンス空白化済みの行をそのまま受け、`\|` だけを
 * 区切りから外す。
 */
function splitTableCells(line: string): string[] {
  const cells: string[] = [];
  let cellStart = -1;
  for (let i = 0; i < line.length; i++) {
    if (line[i] === "\\") {
      i += 1;
      continue;
    }
    if (line[i] !== "|") {
      continue;
    }
    if (cellStart >= 0) {
      cells.push(line.slice(cellStart, i));
    }
    cellStart = i + 1;
  }
  // 末尾の `|` を省いた行（`| a | b`）の最終セルを落とさない。落とすとヘッダと
  // データ行でセル数が食い違い、正しい行が列数不一致として指摘に出る。
  if (cellStart >= 0 && line.slice(cellStart).trim() !== "") {
    cells.push(line.slice(cellStart));
  }
  return cells;
}

/** ヘッダのセルを役割名と照合できる形へ正規化する（強調・コードスパンの記号を落とす）。 */
function normalizeHeaderLabel(cell: string): string {
  return trimCategoryValue(cell).replace(/[`*_]/gu, "").toLowerCase();
}

/** セルの値を照合できる形へ正規化する（囲みのコードスパン・強調を落とす）。 */
function normalizeCellValue(cell: string): string {
  return trimCategoryValue(cell)
    .replace(/^[`*]+/u, "")
    .replace(/[`*]+$/u, "")
    .trim();
}

/**
 * `start` 行から始まる表 1 つ分の行番号を、`limit`（節の終端）まで集める。
 *
 * **空行は表を割らない。** live の索引は追記のたびに空行を挟んだ塊になっており、
 * 空行で領域を切ると先頭の塊以外がすべて「ヘッダ不明」に落ちて検査が実質無効になる
 * （実測: 908 行中 899 行が未検査へ落ちた）。領域を終端するのは**表の行でも空行でもない行**
 * （見出し・段落・水平線）だけにする。
 *
 * 2 行目より後に区切り行が現れたら、その直前の行が**次の表のヘッダ**である。
 * そこで領域を切り、次の走査をそのヘッダ行から始める（切らずに続けると、空行 1 本だけで
 * 隣接する別の表のデータ行を前の表の列順で検査してしまう）。
 */
function collectTableRegion(
  lines: readonly string[],
  start: number,
  limit: number,
): { readonly rows: number[]; readonly nextIndex: number } {
  const rows: number[] = [];
  let cursor = start;
  while (cursor < limit) {
    const line = lines[cursor];
    if (line.trim() === "") {
      cursor += 1;
      continue;
    }
    if (!TABLE_ROW_LINE_PATTERN.test(line)) {
      break;
    }
    if (rows.length >= 2 && TABLE_DELIMITER_LINE_PATTERN.test(line)) {
      const nextHeader = rows[rows.length - 1];
      rows.pop();
      return { rows, nextIndex: nextHeader };
    }
    rows.push(cursor);
    cursor += 1;
  }
  // 空行だけを消費して終わる形でも必ず 1 行は進める（start は表の行なので rows は空にならない）。
  return { rows, nextIndex: Math.max(cursor, start + 1) };
}

/**
 * 索引行の ID を取り出す。ID 列がヘッダから解決できていればその列だけを見る
 * （別の列に ID 形の値があっても索引行とは見なさない）。解決できない場合、および
 * その行に ID 列が存在しない場合だけ、全セルから ID 形の値を探す — ここを厳密にすると
 * 索引行そのものを見落とし、未検査件数にも現れない silent green になる。
 */
function findIndexRowEntryId(
  cells: readonly string[],
  idColumn: number,
): string | undefined {
  if (idColumn >= 0 && idColumn < cells.length) {
    const value = normalizeCellValue(cells[idColumn]);
    return INDEX_ROW_ID_CELL_PATTERN.test(value) ? value : undefined;
  }
  for (const cell of cells) {
    const value = normalizeCellValue(cell);
    if (INDEX_ROW_ID_CELL_PATTERN.test(value)) {
      return value;
    }
  }
  return undefined;
}

/** scanIndexCategoryColumn が表 1 つを走査した結果（節単位・ファイル単位で合算する）。 */
type IndexRegionScan = {
  readonly findings: IndexCategoryFinding[];
  readonly checkedRows: number;
  readonly unresolvedRows: number;
};

/** 表 1 つ分（`rows` は行番号）を走査する。 */
function scanIndexRegion(
  lines: readonly string[],
  rows: readonly number[],
  vocabulary: ReadonlySet<string>,
  entryCategories: EntryCategoryMap,
): IndexRegionScan {
  const findings: IndexCategoryFinding[] = [];
  let checkedRows = 0;
  let unresolvedRows = 0;
  const hasHeader =
    rows.length >= 2 && TABLE_DELIMITER_LINE_PATTERN.test(lines[rows[1]]);
  const headerCells = hasHeader ? splitTableCells(lines[rows[0]]) : [];
  const columnOf = (pattern: RegExp): number =>
    headerCells.findIndex((cell: string) => pattern.test(normalizeHeaderLabel(cell)));
  const idColumn = hasHeader ? columnOf(ID_HEADER_LABEL_PATTERN) : -1;
  const categoryColumn = hasHeader ? columnOf(CATEGORY_HEADER_LABEL_PATTERN) : -1;

  for (const row of hasHeader ? rows.slice(2) : rows) {
    const cells = splitTableCells(lines[row]);
    const entryId = findIndexRowEntryId(cells, idColumn);
    if (entryId === undefined) {
      continue;
    }
    if (categoryColumn < 0) {
      unresolvedRows += 1;
      continue;
    }
    checkedRows += 1;
    const finding = (
      reason: IndexCategoryFindingReason,
      value: string,
      expected: string,
    ): void => {
      findings.push({ line: row + 1, entryId, reason, value, expected });
    };
    if (categoryColumn >= cells.length) {
      finding("missing-column", "", "");
      continue;
    }
    // 列数不一致は、ずれた先にたまたま語彙値が落ちると値の検査では捕まらない。
    // GFM は余剰セルを描画で捨てるので、不足・余剰のどちらも列ずれそのものである。
    if (cells.length !== headerCells.length) {
      finding("column-count", "", "");
      continue;
    }
    const value = normalizeCellValue(cells[categoryColumn]);
    if (value === "") {
      finding("empty", "", "");
      continue;
    }
    // 本文に対応エントリがあるなら**本文の Category と直接**比べる（型検査より強い）。
    const expected = entryCategories[entryId];
    if (expected !== undefined) {
      if (trimCategoryValue(expected).toLowerCase() !== value.toLowerCase()) {
        finding("mismatch", value, trimCategoryValue(expected));
      }
      continue;
    }
    // 本文に無い ID（アーカイブ済みのエントリが索引に残っている等）は突き合わせできない。
    // 語彙とスラッグ形で「カテゴリらしさ」だけを見る（ここを指摘に倒すと偽陽性になる）。
    if (vocabulary.has(value.toLowerCase()) || CATEGORY_SLUG_PATTERN.test(value)) {
      continue;
    }
    finding("not-a-category", value, "");
  }
  return { findings, checkedRows, unresolvedRows };
}

/**
 * PLAYBOOK.md の索引テーブルで、**カテゴリ列に本文と食い違う値が入っている行**を挙げる。
 *
 * 索引行の列順は導入先ごとに違う（`| ID | Category | Title | Link |` と
 * `| エントリID | タイトル | Category | 参照先 |` が実在する）。`/ace-curate` が固定の列順を
 * 写すと、カテゴリ列にタイトル 1 文が入った行が量産される。件数ゲートは本文の
 * `| Category |` 行を読むためずれないので、この食い違いは索引を読む側（索引検索・
 * レビューの集計・目視）でしか現れず、ゲートの件数と突き合わせるまで気づけない。
 *
 * **ID 列も Category 列もヘッダ行から読む**（固定位置で見ない）。ヘッダがタイトル先の
 * 導入先でもカテゴリ先の導入先でも、同じ検査がそれぞれの正しい列を見る。
 *
 * 判定は `entryCategories`（エントリ ID → 本文の Category）との直接比較が主で、
 * 本文に対応エントリが無い行だけ語彙・スラッグ形へ落とす。語彙は引数から導く
 * （本文の Category 値の集合）ので、`auth & session` のように空白・記号を含む
 * カテゴリ名でも誤検出しない。
 *
 * 走査は `## エントリ一覧` 節の中だけ。節が 1 つも無ければ 1 行も検査せず
 * `indexSectionFound: false` を返す（呼び出し側がその事実を出力する fail-closed）。
 *
 * 未閉フェンスに対しては fail-open（blankFencedCodeBlocks がその位置から空白化しない）。
 * 未閉フェンスそのものは analyzePlaybookMarkdown が名指しで落とすので、ここで二重に
 * 止めない。
 */
export function scanIndexCategoryColumn(
  content: string,
  entryCategories: EntryCategoryMap,
): IndexCategoryScan {
  const vocabulary = new Set(
    Object.values(entryCategories)
      .map((value: string) => trimCategoryValue(value).toLowerCase())
      .filter((value: string) => value !== ""),
  );
  // HTML コメント（`<!-- 追記例: … -->` に置かれた索引行の例示）と**閉じたフェンス**を
  // 落とす。インラインコードスパンは落とさない（splitTableCells のコメント参照）。
  const cleaned = blankHtmlBlockComments(content);
  const lines = blankFencedCodeBlocks(cleaned)
    .text.split("\n")
    .map(stripCarriageReturn);
  const findings: IndexCategoryFinding[] = [];
  let checkedRows = 0;
  let unresolvedRows = 0;
  let indexSectionFound = false;

  for (let line = 0; line < lines.length; line++) {
    if (!INDEX_SECTION_HEADING_PATTERN.test(lines[line])) {
      continue;
    }
    indexSectionFound = true;
    let sectionEnd = line + 1;
    while (sectionEnd < lines.length && !SECTION_HEADING_LINE_PATTERN.test(lines[sectionEnd])) {
      sectionEnd += 1;
    }
    let cursor = line + 1;
    while (cursor < sectionEnd) {
      if (!TABLE_ROW_LINE_PATTERN.test(lines[cursor])) {
        cursor += 1;
        continue;
      }
      const region = collectTableRegion(lines, cursor, sectionEnd);
      const scanned = scanIndexRegion(lines, region.rows, vocabulary, entryCategories);
      findings.push(...scanned.findings);
      checkedRows += scanned.checkedRows;
      unresolvedRows += scanned.unresolvedRows;
      cursor = region.nextIndex;
    }
    line = sectionEnd - 1;
  }

  return { findings, checkedRows, unresolvedRows, indexSectionFound };
}

/**
 * live の走査から外す退避先ディレクトリの名前。`archive` は /ace-refine の退避先、
 * `_archive` は導入先が手で作る退避先の表記揺れ。深さを問わず、この名前のディレクトリは
 * 配下ごと走査しない（原文を verbatim 保全する場所なので、数えると二重計上になる）。
 */
export const PLAYBOOK_ARCHIVE_DIR_NAMES: readonly string[] = ["archive", "_archive"];

/**
 * PLAYBOOK.md と同階層の `playbook/` ディレクトリにあるカテゴリ別分割ファイルを検出する。
 * ディレクトリが無い場合は空配列（＝単一ファイルの旧レイアウト）を返す。
 * サブディレクトリは再帰で辿る。退避先（PLAYBOOK_ARCHIVE_DIR_NAMES）と
 * `.` 始まりのディレクトリは辿らない。シンボリックリンクのディレクトリも辿らない（循環を避ける）。
 * 戻り値はフルパスのソート済み配列で、check-entry-format の形式ゲートもこの関数で走査範囲を決める。
 */
export function discoverPlaybookSubfiles(playbookPath: string, reader = knowledgeReaderForSelection(playbookPath)): string[] {
  const subDir = path.join(path.dirname(playbookPath), "playbook");
  if (!knowledgeInputExists(subDir)) {
    return [];
  }
  const found: string[] = [];
  const walk = (dir: string): void => {
    reader.directory(dir);
    for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
      const fullPath = path.join(dir, entry.name);
      // `.md` で終わる名前は種別を問わず拾う（非再帰だった頃と同じ）。ディレクトリでも拾うので、
      // 読み込み側が EISDIR で名指しして止まる — 黙って辿り込んで件数を変えるより読めない入力として出す。
      if (entry.name.endsWith(".md")) {
        reader.authorize(fullPath);
        found.push(fullPath);
        continue;
      }
      if (
        entry.isDirectory() &&
        !entry.name.startsWith(".") &&
        !PLAYBOOK_ARCHIVE_DIR_NAMES.includes(entry.name)
      ) {
        walk(fullPath);
      }
    }
  };
  walk(subDir);
  return found.sort();
}

/**
 * 正の整数を表す環境変数を厳密に解釈する。`"800abc"` や `"1e3"` のような
 * 曖昧な値・0 以下・空値は無効として既定値にフォールバックし、stderr に警告を出す。
 * rawValue を引数で受け取り、副作用なくユニットテストできるようにしている。
 * warnPrefix は警告の発信元スクリプト名（他スクリプトから再利用する際に上書きする）。
 */
export function parsePositiveIntEnv(
  rawValue: string | undefined,
  defaultValue: number,
  envName: string,
  warnPrefix: string = "ace-check",
): number {
  if (rawValue === undefined || rawValue.trim() === "") {
    return defaultValue;
  }
  const trimmed = rawValue.trim();
  // Number.MAX_SAFE_INTEGER を超える値は精度を失ったまま閾値になり、
  // 事実上チェックが無効になる。既に無効値を既定へ落とす契約なので isSafeInteger も同列に扱う。
  const parsed = Number.parseInt(trimmed, 10);
  if (!/^[0-9]+$/u.test(trimmed) || parsed < 1 || !Number.isSafeInteger(parsed)) {
    console.warn(
      `${warnPrefix}: ${envName}="${trimmed}" は無効のため、既定値 ${String(defaultValue)} を使います。`,
    );
    return defaultValue;
  }
  return parsed;
}

export function parseMaxPerCategory(): number {
  return parsePositiveIntEnv(
    process.env.ACE_MAX_ENTRIES_PER_CATEGORY,
    DEFAULT_MAX_ENTRIES_PER_CATEGORY,
    "ACE_MAX_ENTRIES_PER_CATEGORY",
  );
}

/**
 * refine 目安の警告閾値。ハード上限以上に設定されたときは警告段を出さない
 * （`ACE_MAX_ENTRIES_PER_CATEGORY=130` で旧挙動へ戻す経路）。
 */
export function parseWarnPerCategory(maxAllowed: number): number {
  const warnAllowed = parsePositiveIntEnv(
    process.env.ACE_WARN_ENTRIES_PER_CATEGORY,
    DEFAULT_WARN_ENTRIES_PER_CATEGORY,
    "ACE_WARN_ENTRIES_PER_CATEGORY",
  );
  return warnAllowed < maxAllowed ? warnAllowed : maxAllowed;
}

/**
 * `ACE_MAX_PLAYBOOK_LINES` を**明示指定したときだけ**固定上限として返す。
 * 未設定なら undefined を返し、呼び出し側は件数から上限を導出する（ADR-019）。
 * 無効値のときは既定 800 へフォールバックする従来挙動を保つ（エスケープハッチの後方互換）。
 */
export function parseExplicitMaxPlaybookLines(): number | undefined {
  const rawValue = process.env.ACE_MAX_PLAYBOOK_LINES;
  if (rawValue === undefined || rawValue.trim() === "") {
    return undefined;
  }
  return parsePositiveIntEnv(
    rawValue,
    DEFAULT_MAX_PLAYBOOK_LINES,
    "ACE_MAX_PLAYBOOK_LINES",
  );
}

export function parseMaxEntryLines(): number {
  return parsePositiveIntEnv(
    process.env.ACE_MAX_ENTRY_LINES,
    DEFAULT_MAX_ENTRY_LINES,
    "ACE_MAX_ENTRY_LINES",
  );
}

export function resolvePlaybookPath(argv: readonly string[]): string | undefined {
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

/**
 * 索引の指摘 1 件を 1 行で説明する。理由ごとに直し方が違うので、値をそのまま出すだけに
 * しない（`missing-column` は値が無いので、値だけ出すと空行が並んで原因が読めない）。
 */
export function describeIndexFinding(finding: IndexCategoryFinding): string {
  switch (finding.reason) {
    case "missing-column":
      return "Category 列がありません（ヘッダより列数が少ない。セル内の素の `|` は `\\|` へエスケープしてください）";
    case "column-count":
      return "ヘッダと列数が違います（セル内の素の `|` は、コードスパンの中にあっても列を増やします。`\\|` へエスケープしてください）";
    case "empty":
      return "Category 列が空です";
    case "mismatch":
      return `${finding.value}（本文の Category は ${finding.expected}）`;
    case "not-a-category":
      return finding.value;
  }
}

export function formatHistogram(histogram: CategoryHistogram): string {
  return Object.entries(histogram)
    .map(([key, count]) => `${key}: ${String(count)}`)
    .join("\n");
}

export function readFileOrExit(filePath: string, reader: KnowledgeReadBoundary): string | undefined {
  try {
    return reader.read(filePath);
  } catch (error: unknown) {
    const message = error instanceof Error ? error.message : String(error);
    console.error(`読み込み失敗: ${filePath}: ${message}`);
    return undefined;
  }
}
