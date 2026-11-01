/**
 * Behavior-preserving split of check-category-size.ts (ADR-080).
 * Fence, segment, and line-budget text helpers.
 */
import {
  ACE_ENTRY_HEADER_PATTERN,
  EXCEPTION_EXTRA_BUDGET_FACTOR,
  blankCodeRegions,
  entryHeadingSource,
} from "./check-category-size";

/**
 * フェンス開始行（``` / ~~~ の 3 本以上。以降は情報文字列）。
 *
 * **インデントは制限しない**（CommonMark は 3 まで）。ACE の本文はリスト項目の中に
 * フェンスを置くことがあり、その場合インデントはリスト内容カラム基準で測られるため
 * トップレベル基準の「3 まで」では取りこぼす。取りこぼすとフェンス内の行頭 `|` が
 * 実 Category 行として数えられ、**正常なエントリが吸収エラーになる**（偽陽性）。
 * 逆にインデントを許しすぎるとインデントコードブロック中の ``` を開始と誤認しうるが、
 * その場合は対になる終端が無く unclosedFence の fail-closed 側へ落ちる（黙らない）。
 */
export const FENCE_OPEN_PATTERN = /^[ \t]*(`{3,}|~{3,})/u;
/**
 * フェンス終了行の候補（記号だけの行。末尾は空白のみ）。
 * 「開始と同じ記号・同数以上」の照合は呼び出し側（blankFencedCodeBlocks）が行う。
 * この定数だけでは終端条件は完結しない。
 */
export const FENCE_CLOSE_PATTERN = /^[ \t]*(`{3,}|~{3,})[ \t]*$/u;
/**
 * 見出し行（`#` 1〜6 + 空白）。吸収エラーで「認識されなかった見出し候補」を挙げるのに使う。
 * 判定には使わない。呼び出し側が trim 済みの行を渡すのでインデントは問わない。
 */
const ANY_HEADING_LINE_PATTERN = /^#{1,6}\s/u;
/** findHtmlCommentSpans の 1 件。`end` は排他（`source.slice(start, end)` が span 全体）。 */
export type HtmlCommentSpan = Readonly<{ readonly start: number; readonly end: number }>;

/**
 * 閉じた HTML コメント span（`<!--` 〜 最初の `-->`）を先頭から列挙する。
 * ace-refine-report.ts はこの関数を import する（同じ判定の私製コピーを置かない）。
 *
 * **インラインコードスパンの中の `<!--` はコメントの開始として扱わない**。
 * 素の正規表現 `<!--[\s\S]*?-->` で探すと、本文が `` `<!--` `` と書式を説明しただけで
 * ずっと後ろの `-->`（ACE INSERTION POINT のマーカー等）と対になり、間の約 1000 行が
 * 空白化された（実測）。巻き込まれたフェンスの閉じ行も消えるので、診断は
 * 「その手前のフェンスが閉じていない」という無関係な位置を名指しする。
 *
 * 走査は左から 1 回で、先に始まった構造が勝つ（CommonMark と同じ優先順位）:
 * バックティック列が先なら**同じ行の中で同じ長さの**列までをコードとして飛ばし、
 * `<!--` が先ならコメントとして `-->` まで取る（コメント内のバックティックは数えない）。
 * 長さの合う相手が無いバックティック列は 1 文字の本文として扱う（blankInlineCodeSpans と
 * 同じ fail-open）。バックスラッシュでエスケープされたバックティックはコードスパンを開かない
 * （閉じ側はコードスパンの中なのでエスケープを見ない。CommonMark と同じ）。`-->` の無い `<!--` 以降にはコメントが成立しないので走査を終える
 * （正規表現版と同じ「閉じたコメントのみ」の意味論）。
 *
 * **残る限界**: 複数行にまたがるコードスパン（CommonMark は許す）とフェンスの中の
 * 閉じない `<!--` は拾えない。フェンスを先に見ないのは、フェンス検出側
 * （blankCodeRegions）がコメント空白化後のテキストを前提にしているため。
 */
export function findHtmlCommentSpans(source: string): HtmlCommentSpan[] {
  const spans: HtmlCommentSpan[] = [];
  let i = 0;
  while (i < source.length) {
    const ch = source[i];
    if (ch === "`" && isBackslashEscaped(source, i)) {
      // `\`` はバックティックの文字そのもの（CommonMark のエスケープ）。コードスパンを
      // 開かないので 1 文字だけ本文として進め、残りの列は次の周回でトークン化する。
      // ここで開始と見なすと、コメント内のバックティックと対になって本物のコメントを
      // 見落とし、コメント内の追記例の見出しを実エントリとして数える。
      i += 1;
      continue;
    }
    if (ch === "`") {
      let runEnd = i;
      while (runEnd < source.length && source[runEnd] === "`") {
        runEnd += 1;
      }
      const closeEnd = findClosingBacktickRun(source, runEnd, runEnd - i);
      i = closeEnd ?? runEnd;
      continue;
    }
    if (ch === "<" && source.startsWith("<!--", i)) {
      const close = source.indexOf("-->", i + 4);
      if (close === -1) {
        break;
      }
      spans.push({ start: i, end: close + 3 });
      i = close + 3;
      continue;
    }
    i += 1;
  }
  return spans;
}

/** `index` の直前に奇数個のバックスラッシュが連続していれば true（エスケープされている）。 */
function isBackslashEscaped(source: string, index: number): boolean {
  let count = 0;
  for (let k = index - 1; k >= 0 && source[k] === "\\"; k--) {
    count += 1;
  }
  return count % 2 === 1;
}

/**
 * `from` 以降・同じ行の中で、長さがちょうど `length` のバックティック列を探し、
 * その列の直後の位置を返す。無ければ undefined。列はトークン単位で見る
 * （長い列の一部を相手にしない。blankInlineCodeSpans のコメント参照）。
 */
function findClosingBacktickRun(source: string, from: number, length: number): number | undefined {
  let j = from;
  while (j < source.length && source[j] !== "\n") {
    if (source[j] !== "`") {
      j += 1;
      continue;
    }
    let runEnd = j;
    while (runEnd < source.length && source[runEnd] === "`") {
      runEnd += 1;
    }
    if (runEnd - j === length) {
      return runEnd;
    }
    j = runEnd;
  }
  return undefined;
}
/**
 * エントリの anchor 行（`<a id="ace-…"></a>`）。エントリブロックの始点を見出しより
 * 手前へ広げるのに使う。ace-refine-report.ts はこの値を import する。
 * check と refine でブロック範囲が食い違うと、anchor 行と見出し行の間に置かれた宣言を
 * 片側だけが拾い、「check は密度警告を出すのに refine の圧縮候補は空」になる。
 */
export const ENTRY_ANCHOR_LINE_PATTERN = /^<a id="ace-[\w-]+"><\/a>\s*$/iu;
/**
 * エントリ範囲を打ち切る `##` レベル見出し（Changelog 等の後続セクション）。
 * ace-refine-report.ts はこの値を import する。
 */
export const SECTION_HEADING_LINE_PATTERN = /^## /u;
/**
 * テーブル行の候補（行頭が `|`）。表の連続範囲を切り出すのに使う。
 *
 * GFM は先頭 `|` の省略も許すが、省略形まで受けると `|` を含む散文がすべて表の行に見え、
 * 表の範囲を決められない。live / docs-template の PLAYBOOK はいずれも先頭 `|` を書く。
 * 先頭 `|` を省いた索引は「索引テーブルの節が見つからない / 行を拾えない」経路で
 * 未検査として報告されるので、黙って緑にはならない。
 */
export const TABLE_ROW_LINE_PATTERN = /^\s*\|/u;
/**
 * ヘッダ直下の区切り行（`| --- | :--: | … |`）。**ヘッダ行の同定はこの行の実在で行う**。
 * 区切り行を見ずに「索引行の手前で最初に見つかった `|` 行」をヘッダとして採ると、
 * 表の外に落ちた索引行が遠く離れた別の表のヘッダと対応付き、その表の列順で検査される。
 *
 * **末尾の `|` は任意**（GFM は省略を許す）。必須にすると省略形の表でヘッダを認識できず、
 * 列が入れ替わった行が未検査のまま exit 0 で素通りする。
 */
export const TABLE_DELIMITER_LINE_PATTERN = /^\s*\|\s*:?-+:?\s*(?:\|\s*:?-+:?\s*)*\|?\s*$/u;
/** ヘッダのカテゴリ列。導入先ごとに `Category` / `カテゴリ` の表記ゆれがある。 */
export const CATEGORY_HEADER_LABEL_PATTERN = /^(?:category|カテゴリ)$/u;
/** ヘッダの ID 列。`ID` / `エントリID` / `ACE ID` / `Entry ID` の表記ゆれを吸収する。 */
export const ID_HEADER_LABEL_PATTERN = /^(?:(?:ace|entry|エントリ)\s*)?id$/u;
/**
 * 索引テーブルを含む節の見出し。検査はこの節の中だけを走査する。
 * 節へ限定しないと、1 セル目が ACE ID の別表（改番履歴など）が Category 列を持たないだけで
 * 恒久的に未検査件数へ積まれ、意味のある未検査が埋もれる。
 * 見出しが 1 つも無い PLAYBOOK では 1 行も検査せず、その事実を出力する（fail-closed）。
 */
export const INDEX_SECTION_HEADING_PATTERN = /^##\s+(?:エントリ一覧|entries|entry list|index)\s*$/iu;
/**
 * カテゴリ値として許す ASCII スラッグの形（`coding` / `documentation-quality`）。
 * 実体から取った語彙に一致しない値でも、この形なら正当なカテゴリとして受ける
 * （全エントリを archive したカテゴリの索引行が残っている場合など、語彙側が先に空になる）。
 * 索引の列を取り違えた行に入るのはタイトル 1 文なので、空白・和文・句読点でこの形から外れる。
 */
export const CATEGORY_SLUG_PATTERN = /^[A-Za-z0-9]+(?:[-_][A-Za-z0-9]+)*$/u;

/** 存在しないキーは undefined（Record 全面 number ではない）。呼び出し側は ?? 0 で読む。 */
export type CategoryHistogram = Readonly<Partial<Record<string, number>>>;

/**
 * エントリ ID → 本文の Category 値。索引行のカテゴリ列を**本文と直接**突き合わせるために持つ。
 * 語彙集合だけで判定すると、英単語 1 語のタイトル（英語 Playbook では普通）が ASCII スラッグに
 * 見えて、列の入れ替わりが素通りする。
 */
export type EntryCategoryMap = Readonly<Record<string, string>>;

export type AnalyzeSuccess = Readonly<{
  readonly kind: "ok";
  readonly histogram: CategoryHistogram;
  /**
   * 同一 ID が 2 回現れたら**先勝ち**。ID の一意性は check-entry-format のゲートが見るので、
   * ここで別の失敗の形を増やさない（衝突時に索引がどちらの本文と比べられるかが変わるだけ）。
   */
  readonly entryCategories: EntryCategoryMap;
  readonly totalEntries: number;
}>;

export type AnalyzeFailure = Readonly<{
  readonly kind: "error";
  readonly message: string;
}>;

export type AnalyzeResult = AnalyzeSuccess | AnalyzeFailure;

/**
 * mergeAnalyses の検証を通った histogram。`CategoryHistogram` と違い `Partial` でないのは
 * 意図的で、「合算を通った値はすべて非負の安全整数」という検証結果を型で表している。
 * これにより呼び出し側は値の再チェックを持たずに済む（2 つ目の guard を置くと、
 * 片方が `continue`・片方が error という分岐の食い違いが生まれる。Issue `#343`）。
 * **キーの実在は保証しない**（`Record` 全面 number は添字読みに対して嘘をつく）ので、
 * `Object.entries` で走査する用途にのみ使うこと。
 */
export type MergedCategoryHistogram = Readonly<Record<string, number>>;

/** mergeAnalyses の成功結果。`AnalyzeSuccess` の histogram を狭めたリファインメント。 */
export type MergeSuccess = Readonly<{
  readonly kind: "ok";
  readonly histogram: MergedCategoryHistogram;
  /** 分割レイアウトの全ファイル分を合算した ID → Category（先勝ち）。 */
  readonly entryCategories: EntryCategoryMap;
  readonly totalEntries: number;
}>;

export type MergeResult = MergeSuccess | AnalyzeFailure;

/** 件数として妥当な値（非負の安全整数）か。負数・小数・安全整数外は合算前に弾く。 */
export function isEntryCount(value: unknown): value is number {
  return typeof value === "number" && Number.isSafeInteger(value) && value >= 0;
}

export function trimCategoryValue(raw: string): string {
  return raw.replace(/\s+/gu, " ").trim();
}

export function incrementHistogram(
  histogram: Record<string, number>,
  categoryKey: string,
): void {
  const next = (histogram[categoryKey] ?? 0) + 1;
  histogram[categoryKey] = next;
}

/**
 * Playbook の総行数を数える。wc -l 準拠で改行文字（\n）の出現回数を返す。
 * 末尾に改行が無い最終行は数えない（wc -l と同じ挙動）。
 */
export function countPlaybookLines(content: string): number {
  const matches = content.match(/\n/gu);
  return matches ? matches.length : 0;
}

/**
 * 行数が閾値を超過しているか。境界（ちょうど）は超過扱いしない。
 */
export function isOverLineThreshold(lineCount: number, max: number): boolean {
  return lineCount > max;
}

/**
 * 最初の ACE エントリ見出しより前の行数（= ヘッダ部）を数える。
 * エントリ見出しが 1 件も無いファイルは全体がヘッダなので総行数を返す。
 * HTML コメントは行数を保ったまま空白化してから探すため、コメント内の追記例が
 * ヘッダ境界として誤検出されることはない。
 */
export function countHeaderLines(content: string): number {
  const blanked = blankHtmlBlockComments(content);
  const match = blanked.match(ACE_ENTRY_HEADER_PATTERN);
  if (match?.index === undefined) {
    return countPlaybookLines(content);
  }
  return countPlaybookLines(blanked.slice(0, match.index));
}

/** countBudgetExceptions の結果本体。導出上限へ足すのは declared のみ。 */
type BudgetExceptionCounts = {
  /** 宣言として採用したエントリの数（deriveMaxLines へ渡す） */
  readonly declared: number;
  /** ファイル中のマーカー出現数（採用可否を問わない。差分の報告にだけ使う） */
  readonly occurrences: number;
};

/**
 * 未閉フェンスを見ていない tally。`declared` を導出上限へ流してよいのはこちらだけ。
 * `unclosedFence` をリテラル型にしてあるので、`if (tally.unclosedFence) return …` を
 * 通していない値をこの型の場所へ入れると**コンパイルが通らない**。正しさが
 * 「main のどこでガードするか」という位置合わせではなく型で保たれる。
 */
export type ReliableBudgetExceptionTally = Readonly<
  BudgetExceptionCounts & { readonly unclosedFence: false }
>;

/**
 * countBudgetExceptions の結果。
 *
 * `unclosedFence` は `scanUnclosedFence`（ファイル全体走査とセグメント単位の合成。
 * Issue `#353`）の結果。**`blankCodeRegions` 単体の結果とは一致しない** — 境界をまたいで
 * 対になる形では、ファイル全体走査が false でもこちらは true になる。
 *
 * true のときの `declared` の壊れ方は 3 通りある（いずれも実測）:
 * (1) 未閉フェンス内の例示マーカーが宣言として残り、上限が緩む、
 * (2) 未閉フェンスの手前で偽の対が組まれ、正当な宣言が空白化されて偽の密度警告になる、
 * (3) 境界をまたぐ偽の対で同じく宣言が落ちる（この形はファイル全体走査から見ると
 * フェンスが閉じているので、空白化そのものは汚れていない — fail-closed 側の検出）。
 * どれも「警告が出る / 出ない」という形でしか表に出ないため、値だけを見て正常な計数と
 * 区別することはできない。
 *
 * **throw ではなく戻り値へ載せる**。理由は 2 つ: (1) `countBudgetExceptions` の呼び出しは
 * `main()` の既存 try/catch（discoverPlaybookSubfiles を包むもの）の外にあり、モジュール
 * 末尾の `process.exitCode = main()` も包まれていないので、throw は uncaught のスタック
 * トレースとして表に出る（既存の「読み込み失敗: …」系メッセージと不揃いになる）。
 * (2) 診断を値で持てば、呼び出し側がファイル名を添えて既存の exit 2（usage error =
 * 入力そのものが壊れている）へそのまま写像できる。ace-refine-report.ts の
 * EntryLineMeasurementResult が同じ形を取っているが、共有するのは理由 (2) だけ
 * （あちらの main は try/catch を持つ。同ファイルの findOverBudgetEntries が
 * 「throw しても main の catch がより悪いメッセージへ写像する」と書いているとおり）。
 *
 * 汚染側でも `declared` を**読めるまま**にしてあるのは、check と refine の相互一致テストが
 * 「汚染入力で declared === 1 かつ unclosedFence === true」を同時に固定しており、
 * 値を落とすと 2 ファイル間の唯一の drift 検出源が壊れるため。
 */
export type BudgetExceptionTally =
  | ReliableBudgetExceptionTally
  | Readonly<
      BudgetExceptionCounts & {
        readonly unclosedFence: true;
        /** 閉じていないフェンスの開始行（0-origin）。汚染側にだけ載る */
        readonly unclosedFenceLine: number;
      }
    >;

/**
 * エントリ密度から行数上限を導出する（Issue `#285` / ADR-019）。
 *
 *   上限 = ヘッダ行数 + 件数 × (エントリ行数バジェット + 1)
 *          + 例外件数 × バジェット × (EXCEPTION_BUDGET_MULTIPLIER - 1)
 *
 * 固定行数を上限にすると「1 エントリ 13 行 × 件数」と構造的に噛み合わず、
 * 件数ゲートより 2 倍以上早く発火して警告が恒常化する。
 * 件数から導出すれば、警告が出るのは「1 エントリが太い」＝バジェット違反のときだけになり、
 * curate で 1 件増えても上限が同じ分だけ伸びるため refine 直後の余裕が構造的に残る。
 * `+ 1` はエントリブロック間の空行 1 行。末項の EXCEPTION_EXTRA_BUDGET_FACTOR は例外宣言
 * 1 件に与える追加バジェット本数で、EXCEPTION_BUDGET_MULTIPLIER から導出される
 * （ace-refine-report.ts が 1 エントリ上限に使う倍率と同じ源。片方だけずれると
 * 「check は警告を出すのに refine の候補が空」になる）。
 */
export function deriveMaxLines(input: {
  readonly headerLines: number;
  readonly entryCount: number;
  readonly exceptionCount: number;
  readonly maxEntryLines: number;
}): number {
  return (
    input.headerLines +
    input.entryCount * (input.maxEntryLines + 1) +
    input.exceptionCount * input.maxEntryLines * EXCEPTION_EXTRA_BUDGET_FACTOR
  );
}

/**
 * HTML ブロックコメントを「同じ行数の空白」へ置換する（除去しない）。
 * コメント内の追記例（`### ACE-001` など）を走査対象から外す目的は除去と同じだが、
 * 行数が保存されるため countHeaderLines が総行数と同じ基準で測れる。
 * 除去にするとヘッダを過小に測り、導出上限が不当に厳しくなる。
 *
 * export するのは、同じ PLAYBOOK を読む他 3 スクリプト（check-entry-format /
 * ace-reuse-report / ace-refine-report）がフェンス走査の前処理として同じ空白化を
 * 使うため（Issue `#342`。findFencedCanonicalHeadings は「空白化は文字数を保つ」ことを
 * 前提に同一 offset で比較するので、前処理の私製コピーが 1 つでも除去や `u` 付き
 * `[^\n]` に変わると、その利用者だけ境界が静かにずれる — 単一源はここに置く）。
 */
export function blankHtmlBlockComments(source: string): string {
  let result = "";
  let last = 0;
  for (const span of findHtmlCommentSpans(source)) {
    result += source.slice(last, span.start) + blankNonNewline(source.slice(span.start, span.end));
    last = span.end;
  }
  return result + source.slice(last);
}

/**
 * 改行以外を空白へ置き換える。**`u` フラグを付けてはならない**。
 * `u` を付けると `[^\n]` が非 BMP 文字（絵文字など）を 1 コードポイントとして拾い、
 * UTF-16 で 2 単位のものを空白 1 個へ潰すため、結果が原文より短くなる。
 * 行数（`\n` の位置）は `u` の有無に関わらず保存されるが、長さの保存は `u` を外して
 * はじめて成立する。空白化後のオフセットで原文を切り出す消費者が現れたとき、
 * `u` があると「コメント内に絵文字が 1 個あるだけで境界が 1 文字ずれる」形で静かに壊れる。
 */
function blankNonNewline(text: string): string {
  return text.replace(/[^\n]/g, " ");
}

/**
 * blankCodeRegions の結果。`unclosedFence` は「このファイルのコード例外判定は信用できない」
 * という意味なので、呼び出し側は必ず消費すること（黙って続けると出力から区別できない）。
 *
 * 汚染は**未閉フェンス以降だけではない**。閉じ忘れの後ろで最初に現れる記号だけのフェンス行が
 * 終端として消費されるため、**閉じ忘れより手前**にある正当な宣言が偽の対の内側に入って
 * 空白化される形も実測で起きる（Issue `#354` の回帰テスト参照）。範囲を「以降」と限定して
 * 読むと、手前は無事だと誤解する。
 */
export type CodeRegionBlankResult =
  | Readonly<{ readonly text: string; readonly unclosedFence: false }>
  | Readonly<{
      readonly text: string;
      readonly unclosedFence: true;
      /**
       * 閉じていないフェンスの**開始行**（0-origin）。位置を返すのは、この診断が発火する形
       * （ヘッダ領域で開いたフェンスがエントリ本文の裸の ``` と対になる形など）では
       * ユーザーの目に本文のフェンスが対になって見えるため。ファイル名だけを渡すと、
       * 閉じているように見える本文を延々見返すことになる。
       *
       * 任意プロパティにしないのは、この値が**利用者へ提示する行番号**になったから
       * （「N 行目に始まる」）。`?? 0` で埋めると、生成側の抜けが「自信を持って 1 行目を
       * 指す」形で表に出る — 本 PR が消したのと同じ失敗の形。
       */
      readonly unclosedFenceLine: number;
    }>;

/**
 * blankFencedCodeBlocks の結果。`unclosedFence` は呼び出し側で fail-closed に使う。
 * 位置を任意プロパティにしない理由は CodeRegionBlankResult と同じ。
 */
export type BlankedSegment =
  | Readonly<{ readonly text: string; readonly unclosedFence: false }>
  | Readonly<{
      readonly text: string;
      readonly unclosedFence: true;
      /** 閉じていないフェンスの開始行（セグメント内の 0-origin） */
      readonly unclosedFenceLine: number;
    }>;

/**
 * Markdown のフェンス付きコードブロックを「同じ行数の空白」へ置換する（除去しない）。
 * 目的は blankHtmlBlockComments と同じで、本文が例示している追記テンプレート
 * （`| Category | coding | …` を含むフェンス）を走査対象から外すこと。
 *
 * 空白化した `text` は 2 通りに消費される（Issue `#342`）。(1) **フェンス内の正準形見出しの
 * 検出**（findFencedCanonicalHeadings）: フェンス内に正準形の見出し（`### ACE-9-9:` の
 * ような実 ID の例示）があると分割境界の判定が歪むため、件数ゲートと形式ゲートは
 * fail-loud に拒否し、レポート系（reuse / refine）は空白化済みテキストで見出しを検出して
 * **除外 + 警告**する — 4 スクリプトの認識一致は、認識正規表現の単一源だけでなく
 * **前処理の単一源**も要る。境界を空白化側へ付け替える案は採らない（セグメント跨ぎで
 * 偶然対になる閉じ忘れ（`#353` の曖昧形）で、実エントリが引用として静かに吸収される）。
 * (2) セグメント単位の Category 抽出（`#341`。フェンス内の `| Category | … |` 例示を
 * 値として採用しない）。
 *
 * 行単位で走査するのは、正規表現で開始〜終了を対にするより「行数が保存される」ことが
 * 自明になるため（split/join("\n") は行数を変えない）。blankHtmlBlockComments が
 * 先に走るので、HTML コメント内のバックティックは既に空白化されており、
 * コメント内の断片が本文のフェンスと対になることはない。
 *
 * CommonMark の完全な実装ではない。既知の乖離は 2 つ:
 * インデントを制限しない（FENCE_OPEN_PATTERN のコメント参照）ことと、
 * バックティック開始フェンスの情報文字列にバックティックを含められない規則を見ないこと。
 */
export function blankFencedCodeBlocks(source: string): BlankedSegment {
  const lines = source.split("\n");
  let openFence: string | undefined;
  let openIndex = -1;
  for (let i = 0; i < lines.length; i++) {
    const line = lines[i];
    // CRLF 文書では split("\n") 後の各行末に \r が残る。FENCE_CLOSE_PATTERN は行末を
    // アンカーするので、\r を落とさないと**すべてのフェンスが閉じなくなり**、
    // 以降が丸ごと空白化されて本ファイルが足した吸収検出そのものが黙る。
    const probe = line.endsWith("\r") ? line.slice(0, -1) : line;
    if (openFence === undefined) {
      const opened = FENCE_OPEN_PATTERN.exec(probe);
      if (opened) {
        openFence = opened[1];
        openIndex = i;
        lines[i] = blankLine(line);
      }
      continue;
    }
    const closed = FENCE_CLOSE_PATTERN.exec(probe);
    lines[i] = blankLine(line);
    // 終端記号は開始と同種・同数以上でなければ閉じない（``` の中の ~~~ や、
    // 4 本フェンスの中の 3 本行は本文）。この照合を緩めると入れ子の例示が途中で
    // 閉じ、続きの本文（実 Category 行を含む）が空白化される。
    if (closed && closed[1][0] === openFence[0] && closed[1].length >= openFence.length) {
      openFence = undefined;
      openIndex = -1;
    }
  }
  const text = lines.join("\n");
  return openFence === undefined
    ? { text, unclosedFence: false }
    : { text, unclosedFence: true, unclosedFenceLine: openIndex };
}

export function blankLine(line: string): string {
  return blankNonNewline(line);
}

/** findFencedCanonicalHeadings の 1 件。line は 0-origin（利用側で +1 して提示する）。 */
export type FencedCanonicalHeading = Readonly<{
  readonly id: string;
  readonly line: number;
}>;

/**
 * **閉じた**フェンスの内側にある正準形のエントリ見出しを列挙する（Issue `#342`）。
 * 判定は「cleaned では見出しに一致するが、フェンス空白化後の同じ位置は空白化されて
 * いる」こと — 空白化は文字数を保つため、同一 offset の文字比較で内外を判別できる。
 *
 * 未閉フェンスのときは空配列を返す（判定しない）。空白化が EOF まで及ぶため、実在の
 * 見出しまで「フェンス内」に見えてしまう — その形は既存の未閉検査
 * （scanUnclosedFence / analyzePlaybookMarkdown のヘッダ・セグメント検査）が名指しで
 * 落とす領分であり、ここで重ねて報告すると診断が二重になる。
 *
 * 消費側の分担: 件数ゲート（analyzePlaybookMarkdown）と形式ゲート
 * （check-entry-format）は fail-loud に拒否し、例示を ACE-XXX のような非正準形へ
 * 直させる。レポート系（ace-reuse-report の parsePlaybookEntries、経由で
 * ace-refine-report）は除外 + 警告 — 読み取り専用ツールは汚れた入力でも走れる方が
 * 有用で、状態そのものはゲートが commit 前に止める。
 */
export function findFencedCanonicalHeadings(cleaned: string): FencedCanonicalHeading[] {
  const probe = blankFencedCodeBlocks(cleaned);
  if (probe.unclosedFence) {
    return [];
  }
  const pattern = new RegExp(entryHeadingSource("capture-id"), "gmu");
  const found: FencedCanonicalHeading[] = [];
  for (const match of cleaned.matchAll(pattern)) {
    const idx = match.index ?? 0;
    // フェンス内の行は空白化されるので、見出し先頭の `#` が probe 側では ` ` になる
    if (probe.text[idx] !== cleaned[idx]) {
      const id = match[1];
      if (id === undefined) {
        // capture-id モードのパターンで capture が無いのは契約違反。空文字へ正常化すると
        // 「ID の無い名指し」という自信を持って間違う診断になる（blankCodeRegions の
        // 契約違反ガードと同じ判断）。
        throw new Error(
          "findFencedCanonicalHeadings: entryHeadingSource(\"capture-id\") のマッチに ID capture がありません（パターンの契約違反）",
        );
      }
      const line = (cleaned.slice(0, idx).match(/\n/gu) ?? []).length;
      found.push({ id, line });
    }
  }
  return found;
}

/**
 * 1 行の中の**対になった**インラインコードスパン（`` `…` ``）を空白化する。
 * CommonMark と同じく「**同じ長さの**バックティック列どうし」を開閉として対にし、
 * 長さの合う相手が無い列はそのまま残す（fail-open）。
 *
 * 正規表現（`` /(`+)[^`\n]*?\1/ `` の形）では**書けない**。後方参照は「同じ文字列」までは
 * 保証するが、`` `+ `` がバックトラックで縮むため**列の途中で切れない**ことは保証しない。
 * 3 連と 2 連が同じ行にあると、片方の列の一部ともう片方の一部を勝手に組にして、
 * その間にある**正当な宣言を空白化して落とす**（実測: `prefix ``` <!-- 宣言 --> ``` の行で
 * declared が 1 → 0）。落とす側の誤りは refine と食い違うぶん質が悪い。
 * 列を先にトークン化してから長さで対にすれば、この経路は構造的に消える。
 */
export function blankInlineCodeSpans(probeLine: string, line: string): string {
  const runs: { readonly start: number; readonly length: number }[] = [];
  for (let i = 0; i < probeLine.length; ) {
    if (probeLine[i] !== "`") {
      i += 1;
      continue;
    }
    let end = i;
    while (end < probeLine.length && probeLine[end] === "`") {
      end += 1;
    }
    runs.push({ start: i, length: end - i });
    i = end;
  }
  const spans: { readonly start: number; readonly end: number }[] = [];
  for (let i = 0; i < runs.length; ) {
    const open = runs[i];
    let close = -1;
    for (let k = i + 1; k < runs.length; k++) {
      if (runs[k].length === open.length) {
        close = k;
        break;
      }
    }
    if (close === -1) {
      i += 1;
      continue;
    }
    spans.push({ start: open.start, end: runs[close].start + runs[close].length });
    i = close + 1;
  }
  if (spans.length === 0) {
    return line;
  }
  let result = "";
  let last = 0;
  for (const span of spans) {
    result += line.slice(last, span.start) + blankNonNewline(line.slice(span.start, span.end));
    last = span.end;
  }
  return result + line.slice(last);
}

/**
 * 吸収エラーのメッセージで「認識されなかった見出し候補」を名指しするための見出し行。
 * **判定には使わない**（メッセージ文字列だけに影響する）。
 *
 * 引数は**フェンス空白化後**のテキストであること。生セグメントを渡すと、フェンス内の
 * テンプレート例（`### ACE-XXX: …`）まで候補に混ざり、直すべき箇所として正しい本文を
 * 指してしまう。ACE を含む行があればそれだけに絞り（本文の小見出しを混ぜない）、
 * 1 本も無ければ見出し行全体を返す（`ACE-` ごと書き忘れた見出しも名指しできるように）。
 *
 * **セグメント自身の見出し行（1 行目）は呼び出し側が落としてから渡すこと**。
 * splitEntrySegments が見出しを保持するようになったため（Issue `#353`）、渡したままだと
 * 「正しく認識された見出し」が「認識されなかった候補」として先頭に出て、直すべき箇所を
 * 取り違えさせる。
 */
export function findAbsorbedHeadingHints(scannable: string): string[] {
  const headings = scannable
    .split("\n")
    .map((line: string) => line.trim())
    .filter((line: string) => ANY_HEADING_LINE_PATTERN.test(line));
  const aceLike = headings.filter((line: string) => line.includes("ACE"));
  return aceLike.length > 0 ? aceLike : headings;
}

/** エントリブロック 1 つ分。`startLine` は原文における 0-origin の開始行。 */
export type PlaybookSegment = Readonly<{
  readonly text: string;
  readonly startLine: number;
}>;

/** splitEntrySegments の結果。header + entries を連結すると原文が復元できる。 */
export type PlaybookSegments = Readonly<{
  /** 最初のエントリ見出しより前。エントリが 0 件ならファイル全体 */
  readonly header: PlaybookSegment;
  /** 各エントリブロック（**見出し行を含む**） */
  readonly entries: readonly PlaybookSegment[];
}>;

/**
 * PLAYBOOK 本文をエントリブロックへ切る。**見出し行はセグメントに残す**（Issue `#353` / `#357`）。
 *
 * 旧実装は `split(ACE_ENTRY_HEADER_PATTERN)` を使っており、マッチした `### ACE-1-1:` が
 * 結果から**消えていた**。消えるのは接頭辞だけなのでタイトル残骸（`` ```markdown の説明 `` の
 * ような文字列）がセグメントの 1 行目として現れ、行ベースの状態機械には**フェンス開始行に
 * 見える**。同じ物理行をファイル全体走査は `###` 始まりとして見るので一致しない — つまり
 * 2 つの走査が同じファイルについて**別の行集合**を見ていた。実測される症状は 2 つで、
 * どちらも見出しタイトルにインラインコードを書いた瞬間に踏む:
 * (1) 実フェンスが 1 本も無いのに「閉じていないフェンス」で全体が止まる（Issue `#357`）、
 * (2) エントリ内の記号だけのフェンス行の本数のパリティで、2 つの走査の判定が入れ替わる。
 *
 * 見出し行を保持すれば `^###` 始まりの行はどちらの走査でもフェンスにならず、この class が
 * 丸ごと消える。セグメント境界の切り方を本関数へ集約したことで、走査単位の違い（セグメントは
 * 境界で状態がリセットされる）だけが残り、それは scanUnclosedFence が合成して吸収する。
 * ただし境界を求める実装はもう 1 箇所ある — `countHeaderLines` は同じ `entryHeadingSource`
 * から組んだ正規表現で独立にヘッダ境界を出す（正規表現の源は単一だが実装は 2 つ）。
 * 一致は check-category-size.test.ts が固定している。
 *
 * 引数は **HTML コメントを空白化済み**のテキストであること。生の本文を渡すと、コメント内の
 * 追記例（`### ACE-001:` など）が境界になり、件数と Category 集計の両方が壊れる。
 * `startLine` を生ファイルの行番号として使えるのは、blankHtmlBlockComments が改行位置を
 * 保存するから（blankNonNewline のコメント参照）。除去に変えるとここが静かにずれる。
 */
export function splitEntrySegments(cleaned: string): PlaybookSegments {
  // `g` はここで生成する正規表現にだけ付ける（モジュール定数へ付けると lastIndex が
  // 呼び出し間で持ち越される。CATEGORY_TABLE_LINE_PATTERN のコメント参照）。
  const pattern = new RegExp(entryHeadingSource("non-capturing"), "gmu");
  const starts: number[] = [];
  for (const match of cleaned.matchAll(pattern)) {
    if (match.index !== undefined) {
      starts.push(match.index);
    }
  }
  const lineOf = (offset: number): number => {
    const newlines = cleaned.slice(0, offset).match(/\n/gu);
    return newlines ? newlines.length : 0;
  };
  const headerEnd = starts[0] ?? cleaned.length;
  const entries = starts.map((start, index) => ({
    text: cleaned.slice(start, starts[index + 1] ?? cleaned.length),
    startLine: lineOf(start),
  }));
  return { header: { text: cleaned.slice(0, headerEnd), startLine: 0 }, entries };
}

/** scanUnclosedFence の結果。`found` が true のときだけ位置と走査単位が付く。 */
export type UnclosedFenceScan =
  | Readonly<{ readonly found: false }>
  | Readonly<{
      readonly found: true;
      /** 原文における開始行（0-origin。2 つの走査が違う行を指すときは手前の方） */
      readonly line: number;
      /** どの走査が見たか。`"both"` は両方が同じ入力を未閉と判定したことを意味する */
      readonly scope: "file" | "segment" | "both";
    }>;

/**
 * 「どちらの走査単位で見ても対にならないフェンス」を探す合成判定（Issue `#353`）。
 * check（countBudgetExceptions）と refine（maskCommentSpans）が**この関数だけ**を通すことで、
 * **未閉フェンスを理由とする拒否**について 2 つの CLI の入力集合が一致する（check は
 * Category 行の不備など他の理由でも拒否するので、拒否集合そのものは check の方が広い）。
 *
 * 合成する 2 つ:
 * - **ファイル全体**（blankCodeRegions）: 例外マーカーの空白化が実際に行われる単位。
 *   ここが汚れているという事実そのもの
 * - **セグメント単位**（blankFencedCodeBlocks × ヘッダ + 各エントリ）: 境界で状態が
 *   リセットされるため、**境界をまたいで対になる**書き間違い（ヘッダで開いたフェンスが
 *   エントリ本文の裸の ``` と対になる形）を検出できる。ファイル全体走査はこれを
 *   「閉じている」と見るので素通しする — Issue `#353` が報告した非対称そのもの
 *
 * **測った包含関係**: 分割規則を splitEntrySegments へ揃えた現在、セグメント単位は
 * ファイル全体を**包含している**（全セグメントが閉じて終わるなら、各セグメントへ閉じた状態で
 * 入るファイル全体走査も閉じて終わる）。実測: ファイル全体の項を落とす変異でも**検出力
 * （`found`）は 1 件も変わらず**、赤くなるのは包含を固定した `scope === "both"` の
 * assertion だけ（総当たり 7776 件のうち 5724 件がファイル全体側でも未閉と判定する）。
 * それでも OR のまま残すのは、この包含が「分割規則が単一源であること」に依存しており、
 * 崩れたときに黙って検出力が下がる側だから。`scope` はそのための観測点で、
 * 総当たりテストが固定している。なお `scope: "file"` は包含が成り立つ限り到達しない
 * （実測 0/7776）。`Math.min` のタイブレークも同じ理由で現状は常にセグメント側を選ぶ。
 *
 * **合成するのは判定だけで、空白化には一切影響させない** — `declared` / `hasException` の値は
 * 従来と同じ入力の関数のままにしておかないと、check と refine の相互一致テスト
 * （唯一の drift 検出源）の前提が崩れる。
 *
 * 位置は 2 つのうち**先に現れる方**を返す。直すべき箇所は先頭側にあることが多く、
 * 後ろを指すと「そこは対になっている」と読まれて調査が空回りする。
 */
export function scanUnclosedFence(content: string): UnclosedFenceScan {
  const fileWide = blankCodeRegions(content);
  const cleaned = blankHtmlBlockComments(content);
  const { header, entries } = splitEntrySegments(cleaned);
  let segmentLine: number | undefined;
  for (const segment of [header, ...entries]) {
    const blanked = blankFencedCodeBlocks(segment.text);
    if (blanked.unclosedFence) {
      segmentLine = segment.startLine + blanked.unclosedFenceLine;
      break;
    }
  }
  if (fileWide.unclosedFence) {
    const fileLine = fileWide.unclosedFenceLine;
    if (segmentLine === undefined) {
      return { found: true, line: fileLine, scope: "file" };
    }
    return { found: true, line: Math.min(fileLine, segmentLine), scope: "both" };
  }
  if (segmentLine !== undefined) {
    // ファイル全体では対になっているのにセグメント単位で対にならない形は、フェンス内に
    // 正準形の見出しがあって**分割が対の内側で切れた**ときにも生じる（Issue `#342`）。
    // その場合の真因はフェンス内見出しで、件数ゲート / 形式ゲートが名指しで拒否する。
    // ここで「未閉」と報告すると、本文を見ると対になって見えるため利用者の調査が
    // 空回りする — 真因側の診断へ譲る。
    if (findFencedCanonicalHeadings(cleaned).length > 0) {
      return { found: false };
    }
    return { found: true, line: segmentLine, scope: "segment" };
  }
  return { found: false };
}
