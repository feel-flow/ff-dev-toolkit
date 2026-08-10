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
 * 走査対象は `playbook/*.md` 直下のみ（非再帰）。`playbook/archive/` は原文を verbatim
 * 保全する場所であり、旧形式であることが正常なので**巻き込まない**。
 *
 * 実行例: npx --yes tsx scripts/ace/check-entry-format.ts docs/08-knowledge/PLAYBOOK.md
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

/** 旧テーブル形式のメタ表ヘッダ行（`| フィールド | 値 |`）。 */
const FIELD_TABLE_HEADER = /^\|\s*フィールド\s*\|/mu;
/** Markdown テーブルの区切り行。コンパクト正準はヘッダ行・区切り行を持たない。 */
const TABLE_SEPARATOR = /^\|[\s:|-]*-{3,}[\s:|-]*\|/mu;
/** 旧形式の本文ブロック（Insight / Context / Action の太字ラベル）。 */
const INSIGHT_BLOCK = /^\*\*(?:Insight|Context|Action)\*\*/mu;

export type LegacyMarker = "field-table-header" | "table-separator" | "insight-block";

export type PlaybookEntry = Readonly<{
  readonly id: string;
  readonly body: string;
}>;

/**
 * カテゴリファイル本文をエントリ単位（見出し行から次の見出し行の直前まで）へ分割する。
 * 最初の見出しより前（ファイルヘッダ）はどのエントリにも属さない。
 *
 * 見出しの判定は**フェンス空白化済み**の行で行う（Issue #342。フェンス内に正準形の
 * 見出し `### ACE-9-9:` があってもエントリとして数えない — reuse / refine のパーサと
 * 同じ除外規則で、4 スクリプトの認識を一致させる）。本文はフェンス空白化**前**の
 * 行から集める（旧形式マーカーの検出対象を変えない）。フェンス内の正準形見出しと
 * 未閉フェンスへの**拒否**は呼び出し側の main が担う（パーサは除外するだけ —
 * 読み取り側から import されても汚れた入力で例外を投げない）。
 */
export function splitEntries(content: string): PlaybookEntry[] {
  const source = blankHtmlBlockComments(content);
  const probe = blankFencedCodeBlocks(source);
  const boundaryLines = probe.text.split("\n");
  const lines = source.split("\n");
  const entries: { id: string; bodyLines: string[] }[] = [];
  for (let i = 0; i < lines.length; i++) {
    const match = boundaryLines[i].match(ACE_ENTRY_HEADER_LINE);
    if (match?.[1]) {
      entries.push({ id: match[1], bodyLines: [] });
      continue;
    }
    if (entries.length > 0) {
      entries[entries.length - 1].bodyLines.push(lines[i]);
    }
  }
  return entries.map((entry) => ({ id: entry.id, body: entry.bodyLines.join("\n") }));
}

/**
 * エントリ本文に残る旧テーブル形式のマーカーを列挙する。
 *
 * 3 つのマーカーを **OR** で見るのは実データの都合である。live には「メタ表だけ正準へ
 * 再整形され本文は Insight/Context/Action のまま残ったハイブリッド」が 4 件あり、
 * 区切り行だけを主判定にするとこの形の新規追記が通ってしまう。逆に区切り行のみを
 * 持つエントリは 0 件なので、Insight ブロックが実質の主判定になる。
 */
export function detectLegacyMarkers(body: string): LegacyMarker[] {
  const markers: LegacyMarker[] = [];
  if (FIELD_TABLE_HEADER.test(body)) {
    markers.push("field-table-header");
  }
  if (TABLE_SEPARATOR.test(body)) {
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

export function main(): number {
  const playbookPath = resolvePlaybookPath(process.argv);
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
  const seenLegacy = new Set<string>();
  const seenIds = new Set<string>();

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
  if (shapeViolations.length === 0 && unclosedFenceFiles.length === 0) {
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
