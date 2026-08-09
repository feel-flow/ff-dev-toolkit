import { afterEach, describe, expect, it, vi } from "vitest";
import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";
import {
  findOverBudgetEntries,
  findPromotionCandidates,
  findRefineArchiveCandidates,
  formatRefineReport,
  isListedInPatterns,
  main,
  measureEntryLines,
  resolvePatternsPath,
  type EntryLineMeasurement,
} from "./ace-refine-report";
import { computeReuseStats, parsePlaybookEntries, type ReuseStats } from "./ace-reuse-report";
// 結合テスト（末尾の describe）で同一 fixture に対して check 側の判定も測るため。
// 依存方向は ace-refine-report.ts → check-category-size.ts と同じ向きに揃えている。
import { analyzePlaybookMarkdown, main as checkCategorySizeMain } from "./check-category-size";
// 見出し認識の一致（#318）は 4 スクリプト横断なので、形式ゲート側もここへ通す。
import { splitEntries } from "./check-entry-format";

const NOW = new Date("2026-07-31T00:00:00Z");

function statsOf(
  pairs: readonly (readonly [string, Partial<ReuseStats>])[],
): Map<string, ReuseStats> {
  const map = new Map<string, ReuseStats>();
  for (const [id, partial] of pairs) {
    map.set(id, {
      gitRefCount: 0,
      lastGitRefDate: null,
      crossRefCount: 0,
      ...partial,
    });
  }
  return map;
}

describe("measureEntryLines", () => {
  it("anchor 行から終端 --- までを 1 エントリの行数として数える", () => {
    const md = [
      "# 見出し",
      "",
      '<a id="ace-24-1"></a>', // ここから 7 行（--- まで）
      "",
      "### ACE-24-1: コンパクト形式のエントリ",
      "",
      "本文 1 行。",
      "",
      "---",
      "",
      '<a id="ace-24-2"></a>',
      "",
      "### ACE-24-2: 次のエントリ",
      "",
      "本文。",
      "",
      "---",
      "",
    ].join("\n");

    const result = measureEntryLines(md).measurements;
    expect(result).toHaveLength(2);
    expect(result[0]).toMatchObject({ id: "ACE-24-1", lineCount: 7, hasException: false });
    expect(result[1]).toMatchObject({ id: "ACE-24-2", lineCount: 7, hasException: false });
  });

  it("終端 --- が無い最終エントリは最後の非空行までを数える", () => {
    const md = [
      '<a id="ace-30-1"></a>',
      "",
      "### ACE-30-1: 区切りなし最終エントリ",
      "",
      "本文。",
      "",
      "",
    ].join("\n");

    const result = measureEntryLines(md).measurements;
    expect(result).toHaveLength(1);
    expect(result[0].lineCount).toBe(5);
  });

  it("ace-line-budget-exception コメントを持つエントリは hasException になる", () => {
    const md = [
      '<a id="ace-40-1"></a>',
      "",
      "### ACE-40-1: 例外宣言付きエントリ",
      "",
      "<!-- ace-line-budget-exception: 反直感的な仕様の詳細が必要 -->",
      "",
      "本文。",
      "",
      "---",
    ].join("\n");

    const result = measureEntryLines(md).measurements;
    expect(result[0].hasException).toBe(true);
  });

  /**
   * 未閉フェンス（Issue #349）。blankCodeRegions は「閉じていないフェンス以降を空白化しない」
   * fail-open なので、そこから先の例外マーカー判定は**両方向へ**壊れる。片方だけを fixture に
   * すると、もう片方の経路を消す変異が緑のまま通る（下の 2 件は hasException が逆に出る）。
   */
  it("未閉フェンス内のマーカーは宣言として残る（緩む方向）— unclosedFence で信用できないと分かる", () => {
    const md = [
      '<a id="ace-70-1"></a>',
      "",
      "### ACE-70-1: 閉じ忘れフェンスを含むエントリ",
      "",
      "```markdown",
      "<!-- ace-line-budget-exception: 例示のつもり -->",
      "",
      "本文。",
      "",
      "---",
    ].join("\n");

    const result = measureEntryLines(md);
    // コードとして例示しただけのマーカーが宣言に数えられ、そのエントリの上限が黙って 2 倍になる
    expect(result.measurements[0].hasException).toBe(true);
    expect(result.unclosedFence).toBe(true);
  });

  it("未閉フェンスが後続の実宣言を巻き込んで落とす（厳しい方向）— これも unclosedFence で分かる", () => {
    // ```text が閉じられないまま、後続コードブロックの終端 ``` に閉じられ、その間にある
    // **正当な宣言**がまとめて空白化される。最後に残った ``` が開いたままになる。
    const md = [
      '<a id="ace-71-1"></a>',
      "",
      "### ACE-71-1: 閉じ忘れが宣言を巻き込むエントリ",
      "",
      "```text",
      "例示コード",
      "<!-- ace-line-budget-exception: 本物の宣言 -->",
      "本文。",
      "```js",
      "const a = 1;",
      "```",
      "続きの本文。",
      "```",
      "閉じ忘れた末尾。",
      "",
      "---",
    ].join("\n");

    const result = measureEntryLines(md);
    // 実在する宣言が消え、伸びるはずの上限が伸びない（refine 側だけが 15 行で判定する）
    expect(result.measurements[0].hasException).toBe(false);
    expect(result.unclosedFence).toBe(true);
  });

  it("フェンスが閉じていれば unclosedFence は立たない（例示マーカーは宣言に数えない）", () => {
    const md = [
      '<a id="ace-72-1"></a>',
      "",
      "### ACE-72-1: フェンスが閉じたエントリ",
      "",
      "```markdown",
      "<!-- ace-line-budget-exception: 書式の例示 -->",
      "```",
      "",
      "本文。",
      "",
      "---",
    ].join("\n");

    const result = measureEntryLines(md);
    expect(result.measurements[0].hasException).toBe(false);
    expect(result.unclosedFence).toBe(false);
  });

  it("チルダフェンス（~~~）の閉じ忘れも unclosedFence になる（エラー文言が両方を名指しするため）", () => {
    const md = [
      '<a id="ace-73-1"></a>',
      "",
      "### ACE-73-1: チルダフェンスの閉じ忘れ",
      "",
      "~~~markdown",
      "<!-- ace-line-budget-exception: 例示のつもり -->",
      "",
      "---",
    ].join("\n");

    expect(measureEntryLines(md).unclosedFence).toBe(true);
  });

  it("HTML コメント内の見出し（テンプレートの追記例）はエントリとして数えない", () => {
    const md = [
      "<!-- 追記例:",
      "### ACE-001: コメント内の偽エントリ",
      "-->",
      "",
      '<a id="ace-50-1"></a>',
      "",
      "### ACE-50-1: 実エントリ",
      "",
      "本文。",
      "",
      "---",
    ].join("\n");

    const result = measureEntryLines(md).measurements;
    expect(result.map((m) => m.id)).toEqual(["ACE-50-1"]);
  });

  it("プレースホルダ見出し（ACE-XXX）はエントリとして数えない", () => {
    const md = ["### ACE-XXX: [タイトル]", "", "本文。", "---"].join("\n");
    expect(measureEntryLines(md).measurements).toHaveLength(0);
  });

  it("閉じられていない <!--（コード例内の断片等）で後続エントリを見失わない", () => {
    // 旧実装は行単位の状態機械で、閉じない <!-- 以降の全エントリを黙って落とした
    // （parsePlaybookEntries は閉じたコメントしか除外しないため乖離する）。
    const md = [
      '<a id="ace-60-1"></a>',
      "",
      "### ACE-60-1: コード例に <!-- を含むエントリ",
      "",
      '本文。例: `grep \'<!--\' file.md` のような記述。',
      "",
      "---",
      "",
      '<a id="ace-60-2"></a>',
      "",
      "### ACE-60-2: 後続エントリ",
      "",
      "本文。",
      "",
      "---",
    ].join("\n");

    const result = measureEntryLines(md).measurements;
    expect(result.map((m) => m.id)).toEqual(["ACE-60-1", "ACE-60-2"]);
    expect(result[0].lineCount).toBe(7);
    expect(result[1].lineCount).toBe(7);
  });

  it("本文中間の --- ではなく最後の --- を終端とする（後方走査のロック）", () => {
    const md = [
      '<a id="ace-61-1"></a>',
      "",
      "### ACE-61-1: 本文に区切り線を含むエントリ",
      "",
      "前半。",
      "---",
      "後半。",
      "",
      "---",
    ].join("\n");

    const result = measureEntryLines(md).measurements;
    expect(result[0].lineCount).toBe(9); // 中間の --- (6行目) で切らない
  });

  it("終端 --- を欠いた最終エントリが後続の ## セクション（Changelog 等）まで膨張しない", () => {
    const md = [
      '<a id="ace-62-1"></a>',
      "",
      "### ACE-62-1: 終端なしの最終エントリ",
      "",
      "本文。",
      "",
      "## Changelog",
      "",
      "### [1.2.0] - 2026-07-31",
      "",
      "変更内容の羅列。",
      "",
      "---",
      "",
      "続き。",
    ].join("\n");

    const result = measureEntryLines(md).measurements;
    expect(result).toHaveLength(1);
    // ## Changelog の手前（5行目の本文）まで。Changelog 内の --- (13行目) に届かない
    expect(result[0].lineCount).toBe(5);
  });

  it("anchor 直後に空行なしで見出しが続く形（i-1 分岐）も anchor 行から数える", () => {
    const md = [
      '<a id="ace-63-1"></a>',
      "### ACE-63-1: 空行なし形式",
      "",
      "本文。",
      "",
      "---",
    ].join("\n");

    const result = measureEntryLines(md).measurements;
    expect(result[0].lineCount).toBe(6);
  });

  it("例外マーカーは HTML コメントとして書かれたものだけ有効（本文プロースの言及は無効）", () => {
    const md = [
      '<a id="ace-64-1"></a>',
      "",
      "### ACE-64-1: マーカーに言及するだけのエントリ",
      "",
      "本文で ace-line-budget-exception という語に言及する（コメントではない）。",
      "",
      "---",
    ].join("\n");

    const result = measureEntryLines(md).measurements;
    expect(result[0].hasException).toBe(false);
  });
});

describe("findOverBudgetEntries", () => {
  const byFile = (measurements: readonly EntryLineMeasurement[], unclosedFence = false) =>
    new Map([["playbook/tooling.md", { measurements, unclosedFence }]]);

  it("上限超過のみを行数降順で列挙し、例外宣言付きは 2 倍の上限で判定する", () => {
    const over = findOverBudgetEntries(
      byFile([
        { id: "ACE-1-1", lineCount: 15, hasException: false }, // ちょうど → OK
        { id: "ACE-1-2", lineCount: 16, hasException: false }, // 超過
        { id: "ACE-1-3", lineCount: 28, hasException: true }, // 例外内（<= 30）→ OK
        { id: "ACE-1-4", lineCount: 31, hasException: true }, // 例外上限も超過
      ]),
      15,
    );
    // 圧縮効果の大きい順（行数降順）
    expect(over.map((o) => o.id)).toEqual(["ACE-1-4", "ACE-1-2"]);
    expect(over[0].limit).toBe(30);
    expect(over[1].limit).toBe(15);
    expect(over[0].file).toBe("playbook/tooling.md");
  });

  /**
   * hasException を読む唯一の関数なので、汚染された測定値を渡されたら落とす（Issue #349）。
   * これはコンパイル時の強制ではなく backstop で、正規の入口は main のゲート — main の catch は
   * ファイル名を含まない一般メッセージへ写像するため、ここまで来た時点で診断としては劣化している。
   * それでも「静かに誤った候補一覧を出す」よりはよい。
   */
  it("未閉フェンスで汚染された測定値を渡されたら落ちる（main のゲートを迂回させない）", () => {
    expect(() =>
      findOverBudgetEntries(byFile([{ id: "ACE-1-1", lineCount: 99, hasException: true }], true), 15),
    ).toThrow(/playbook\/tooling\.md/u);
  });
});

describe("findRefineArchiveCandidates", () => {
  const entriesMd = [
    '<a id="ace-10-1"></a>',
    "",
    "### ACE-10-1: helpful=0 の stale エントリ",
    "",
    "| フィールド | 値 |",
    "| Category | coding |",
    "| Date | 2026-01-01 |",
    "| Helpful | 0 |",
    "| Status | active |",
    "",
    "---",
    "",
    '<a id="ace-10-2"></a>',
    "",
    "### ACE-10-2: helpful=2 の stale エントリ",
    "",
    "| フィールド | 値 |",
    "| Category | coding |",
    "| Date | 2026-01-01 |",
    "| Helpful | 2 |",
    "| Status | active |",
    "",
    "---",
  ].join("\n");

  it("stale 判定（findArchiveCandidates）に helpful === 0 の積集合を取る", () => {
    const entries = parsePlaybookEntries(entriesMd, () => {});
    const stats = statsOf([
      ["ACE-10-1", {}],
      ["ACE-10-2", {}],
    ]);
    const candidates = findRefineArchiveCandidates(entries, stats, NOW, 90);
    expect(candidates.map((c) => c.id)).toEqual(["ACE-10-1"]);
  });

  it("Helpful フィールドが読めなかったエントリ（0 化）はアーカイブ候補にしない", () => {
    // 壊れた Helpful は警告つきで 0 に落ちるが、それは「実績ゼロ」ではない。
    // 誤アーカイブ推奨を防ぐため helpfulParsed=false は候補から除外する（安全側）。
    const broken = entriesMd.replace("| Helpful | 0 |", "| Helpful | 0 (要確認) |");
    const entries = parsePlaybookEntries(broken, () => {});
    const stats = statsOf([
      ["ACE-10-1", {}],
      ["ACE-10-2", {}],
    ]);
    expect(entries.find((e) => e.id === "ACE-10-1")?.helpful).toBe(0);
    expect(findRefineArchiveCandidates(entries, stats, NOW, 90)).toEqual([]);
  });
});

describe("findPromotionCandidates", () => {
  const entries = parsePlaybookEntries(
    [
      '<a id="ace-20-1"></a>',
      "",
      "### ACE-20-1: Helpful 5 の未収載エントリ",
      "",
      "| Category | process | Origin | PR #20 |",
      "| Date | 2026-06-01 |",
      "| Helpful | 5 | Harmful | 0 |",
      "| Status | active |",
      "",
      "---",
      "",
      '<a id="ace-20-2"></a>',
      "",
      "### ACE-20-2: Helpful 6 の収載済みエントリ",
      "",
      "| Category | process | Origin | PR #20 |",
      "| Date | 2026-06-01 |",
      "| Helpful | 6 | Harmful | 0 |",
      "| Status | active |",
      "",
      "---",
      "",
      '<a id="ace-20-3"></a>',
      "",
      "### ACE-20-3: Helpful 4 の未達エントリ",
      "",
      "| Category | process | Origin | PR #20 |",
      "| Date | 2026-06-01 |",
      "| Helpful | 4 | Harmful | 0 |",
      "| Status | active |",
      "",
      "---",
    ].join("\n"),
    () => {},
  );

  it("Helpful >= 閾値かつ PATTERNS.md 未収載のみ列挙する", () => {
    const patterns = "## 実証済みパターン（ACE 昇格）\n\n出典: [ACE-20-2](...)\n";
    const candidates = findPromotionCandidates(entries, patterns, 5);
    expect(candidates.map((c) => c.id)).toEqual(["ACE-20-1"]);
  });

  it("PATTERNS.md 不在（null）のときは Helpful 条件のみで列挙する", () => {
    const candidates = findPromotionCandidates(entries, null, 5);
    expect(candidates.map((c) => c.id)).toEqual(["ACE-20-1", "ACE-20-2"]);
  });

  it("deprecated エントリは Helpful が高くても昇格候補にしない", () => {
    const deprecated = parsePlaybookEntries(
      [
        "### ACE-21-1: 反証済みだが Helpful が高いエントリ",
        "",
        "| Category | process | Origin | PR #21 |",
        "| Date | 2026-06-01 |",
        "| Helpful | 7 | Harmful | 8 |",
        "| Status | deprecated |",
        "",
        "---",
      ].join("\n"),
      () => {},
    );
    expect(findPromotionCandidates(deprecated, null, 5)).toEqual([]);
  });

  it("収載判定は完全 ID トークン一致（ACE-20-10 の収載が ACE-20-1 を抑止しない）", () => {
    const patterns = "出典: [ACE-20-10](../08-knowledge/playbook/process.md#ace-20-10)\n";
    expect(isListedInPatterns(patterns, "ACE-20-10")).toBe(true);
    expect(isListedInPatterns(patterns, "ACE-20-1")).toBe(false);
    // 逆方向: ACE-20-1 の収載は ACE-20-10 を抑止しない
    const patterns2 = "出典: [ACE-20-1](...)\n";
    expect(isListedInPatterns(patterns2, "ACE-20-1")).toBe(true);
    expect(isListedInPatterns(patterns2, "ACE-20-10")).toBe(false);
  });
});

describe("resolvePatternsPath", () => {
  it("既定は PLAYBOOK と同階層の ../03-implementation/PATTERNS.md", () => {
    const resolved = resolvePatternsPath("/repo/docs/08-knowledge/PLAYBOOK.md", undefined);
    expect(resolved).toBe(path.resolve("/repo/docs/03-implementation/PATTERNS.md"));
  });

  it("ACE_PATTERNS_PATH が指定されていれば優先する", () => {
    const resolved = resolvePatternsPath(
      "/repo/docs/08-knowledge/PLAYBOOK.md",
      "/repo/docs/patterns/CUSTOM.md",
    );
    expect(resolved).toBe(path.resolve("/repo/docs/patterns/CUSTOM.md"));
  });
});

describe("formatRefineReport", () => {
  it("候補ゼロでも各セクションと read-only 注記を出力する", () => {
    const report = formatRefineReport({
      archiveCandidates: [],
      overBudget: [],
      promotionCandidates: [],
      patternsPath: "/repo/docs/03-implementation/PATTERNS.md",
      patternsExists: true,
      totalEntries: 3,
      now: NOW,
      staleDays: 90,
      maxEntryLines: 15,
      promoteMin: 5,
    });
    expect(report).toContain("# ACE refine 候補レポート（dry-run）");
    expect(report).toContain("## Archive 候補（helpful=0 かつ stale、0 件）");
    expect(report).toContain("## 行数バジェット超過（0 件）");
    expect(report).toContain("## PATTERNS.md 昇格候補（Helpful >= 5、0 件）");
    expect(report).toContain("/ace-refine の承認ゲート");
  });
});

describe("main（fixture E2E）", () => {
  const tempDirs: string[] = [];

  afterEach(() => {
    vi.restoreAllMocks();
    vi.unstubAllEnvs();
    for (const dir of tempDirs.splice(0)) {
      fs.rmSync(dir, { recursive: true, force: true });
    }
  });

  function makeFixture(): { playbookPath: string } {
    const root = fs.mkdtempSync(path.join(os.tmpdir(), "ace-refine-"));
    tempDirs.push(root);
    const knowledgeDir = path.join(root, "docs", "08-knowledge");
    const implDir = path.join(root, "docs", "03-implementation");
    fs.mkdirSync(path.join(knowledgeDir, "playbook"), { recursive: true });
    fs.mkdirSync(implDir, { recursive: true });

    const playbookPath = path.join(knowledgeDir, "PLAYBOOK.md");
    fs.writeFileSync(playbookPath, "# ACE Playbook\n\n## エントリ一覧\n", "utf8");

    // 旧テーブル形式（stale・helpful=0）と新コンパクト形式（Helpful 5）の混在
    fs.writeFileSync(
      path.join(knowledgeDir, "playbook", "coding.md"),
      [
        "# PLAYBOOK — コーディング (coding)",
        "",
        '<a id="ace-90-1"></a>',
        "",
        "### ACE-90-1: 旧テーブル形式の stale エントリ",
        "",
        "| フィールド | 値 |",
        "| ---------- | -- |",
        "| Category   | coding |",
        "| Origin     | PR #90 |",
        "| Date       | 2026-01-01 |",
        "| Helpful    | 0 |",
        "| Harmful    | 0 |",
        "| Status     | active |",
        "",
        "**Insight**: 古い知見。",
        "",
        "**Context**: 発見状況。",
        "",
        "**Action**: 推奨アクション。長いエントリにするための行。",
        "",
        "---",
        "",
        '<a id="ace-91-1"></a>',
        "",
        "### ACE-91-1: コンパクト形式の高評価エントリ",
        "",
        "| Category | coding | Origin | PR #91 |",
        "| Date | 2026-06-01 |",
        "| Helpful | 5 | Harmful | 0 |",
        "| Status | active |",
        "",
        "本文 2 文。適用条件を 1 文。",
        "",
        "---",
        "",
      ].join("\n"),
      "utf8",
    );

    fs.writeFileSync(path.join(implDir, "PATTERNS.md"), "# PATTERNS.md\n", "utf8");
    return { playbookPath };
  }

  const emptyLog = () => ({ commits: [], malformedCount: 0 });

  it("混在フォーマットの fixture から Archive 候補・行数超過・昇格候補を列挙する", () => {
    const { playbookPath } = makeFixture();
    const logSpy = vi.spyOn(console, "log").mockImplementation(() => {});
    vi.spyOn(console, "warn").mockImplementation(() => {});

    const code = main([playbookPath], { readLog: emptyLog, now: () => NOW });
    expect(code).toBe(0);

    const report = logSpy.mock.calls.map((c) => String(c[0])).join("\n");
    // 旧形式 helpful=0 + stale → Archive 候補（Category 付きで列挙）
    expect(report).toContain(
      "- ACE-90-1: 旧テーブル形式の stale エントリ（Category: coding / Date: 2026-01-01 / Helpful: 0）",
    );
    // 旧形式 20 行 > 15 → 行数超過（anchor〜終端 --- の実測値を固定）
    expect(report).toContain("- ACE-90-1: 20 行（上限 15）");
    // 新形式 Helpful 5・PATTERNS 未収載 → 昇格候補
    expect(report).toContain(
      "- ACE-91-1: コンパクト形式の高評価エントリ（Category: coding / Helpful: 5）",
    );
    // 新形式はコンパクトなので行数超過に出ない
    expect(report).not.toMatch(/- ACE-91-1: \d+ 行/u);
  });

  it("存在しない playbookPath は使用方法エラー（exit 2）", () => {
    vi.spyOn(console, "error").mockImplementation(() => {});
    expect(
      main(["/no/such/dir/PLAYBOOK.md"], { readLog: emptyLog, now: () => NOW }),
    ).toBe(2);
  });

  it("ACE エントリ 0 件は fail-loud（exit 2）— 誤パスの空レポートを完了扱いさせない", () => {
    const root = fs.mkdtempSync(path.join(os.tmpdir(), "ace-refine-empty-"));
    tempDirs.push(root);
    const emptyPlaybook = path.join(root, "PLAYBOOK.md");
    fs.writeFileSync(emptyPlaybook, "# ACE Playbook\n\nエントリなし\n", "utf8");
    const errSpy = vi.spyOn(console, "error").mockImplementation(() => {});
    vi.spyOn(console, "log").mockImplementation(() => {});

    expect(main([emptyPlaybook], { readLog: emptyLog, now: () => NOW })).toBe(2);
    expect(errSpy.mock.calls.flat().join("\n")).toContain("ACE エントリが 0 件");
  });

  it("ACE_MAX_ENTRY_LINES の上書きが行数判定に反映される", () => {
    const { playbookPath } = makeFixture();
    const logSpy = vi.spyOn(console, "log").mockImplementation(() => {});
    vi.spyOn(console, "warn").mockImplementation(() => {});
    vi.stubEnv("ACE_MAX_ENTRY_LINES", "50");

    const code = main([playbookPath], { readLog: emptyLog, now: () => NOW });
    expect(code).toBe(0);

    const report = logSpy.mock.calls.map((c) => String(c[0])).join("\n");
    expect(report).toContain("## 行数バジェット超過（0 件）");
  });

  it("ACE_PROMOTE_HELPFUL_MIN の上書きが昇格判定に反映される", () => {
    const { playbookPath } = makeFixture();
    const logSpy = vi.spyOn(console, "log").mockImplementation(() => {});
    vi.spyOn(console, "warn").mockImplementation(() => {});
    vi.stubEnv("ACE_PROMOTE_HELPFUL_MIN", "6");

    const code = main([playbookPath], { readLog: emptyLog, now: () => NOW });
    expect(code).toBe(0);

    const report = logSpy.mock.calls.map((c) => String(c[0])).join("\n");
    expect(report).toContain("昇格候補（Helpful >= 6、0 件）");
  });

  it("新コンパクト形式のエントリが警告なしでパースされる（Helpful/Date/Status 互換）", () => {
    const { playbookPath } = makeFixture();
    vi.spyOn(console, "log").mockImplementation(() => {});
    const warnSpy = vi.spyOn(console, "warn").mockImplementation(() => {});

    const code = main([playbookPath], { readLog: emptyLog, now: () => NOW });
    expect(code).toBe(0);
    // parsePlaybookEntries 由来のフィールド欠落警告が 1 件も出ないこと
    const warns = warnSpy.mock.calls.map((c) => String(c[0]));
    expect(warns.filter((w) => w.includes("フィールドが見つかりません"))).toEqual([]);
  });

  it("引数なしは使用方法エラー（exit 2）", () => {
    vi.spyOn(console, "error").mockImplementation(() => {});
    expect(main([], { readLog: emptyLog, now: () => NOW })).toBe(2);
  });

  /**
   * 未閉フェンスは実行時エラー（exit 1）で中断し、**レポート本文を 1 行も出さない**（Issue #349）。
   * stderr 警告だけにすると、/ace-refine は stdout の「超過 0 件」を候補一覧として R2 の
   * 承認ゲートへ積んでしまう。stdout に何も出ないことまで固定しないと、警告を足しただけの
   * 実装が緑のまま通る。
   */
  it("未閉フェンスを含むファイルは fail-loud（exit 1）でレポートを出さない", () => {
    const { playbookPath } = makeFixture();
    const codingPath = path.join(path.dirname(playbookPath), "playbook", "coding.md");
    fs.appendFileSync(codingPath, "\n```markdown\n閉じ忘れたフェンス。\n", "utf8");
    const logSpy = vi.spyOn(console, "log").mockImplementation(() => {});
    const errSpy = vi.spyOn(console, "error").mockImplementation(() => {});
    vi.spyOn(console, "warn").mockImplementation(() => {});

    expect(main([playbookPath], { readLog: emptyLog, now: () => NOW })).toBe(1);
    const stderr = errSpy.mock.calls.flat().map(String).join("\n");
    expect(stderr).toContain("閉じていないコードフェンス");
    // どのファイルを直せばよいかを名指しする（複数サブファイルでは指名が唯一の手掛かり）
    expect(stderr).toContain("coding.md");
    expect(logSpy).not.toHaveBeenCalled();
    // 本ゲートがここで return したこと。findOverBudgetEntries の backstop まで流れると
    // 終了コードと logSpy は同じでも、名指しの無い一般メッセージへ劣化する
    expect(stderr).not.toContain("レポート生成に失敗しました");
  });

  /**
   * 索引 PLAYBOOK.md 自身も検査対象（README の documented invocation は
   * `ace-refine-report.ts docs/08-knowledge/PLAYBOOK.md` で、エントリを索引に直接置く
   * 非分割レイアウトではこのファイルが対象の 100% を占める）。サブファイルだけを fixture に
   * すると、`file !== playbookPath` のような変異が緑のまま通り、しかもその変異体は
   * exit 0 でレポートを印字する — Issue #349 の症状そのものが復活する。
   */
  it("索引ファイル自身の未閉フェンスも fail-loud（非分割レイアウトの既定形）", () => {
    const { playbookPath } = makeFixture();
    fs.appendFileSync(playbookPath, "\n```markdown\n閉じ忘れたフェンス。\n", "utf8");
    const logSpy = vi.spyOn(console, "log").mockImplementation(() => {});
    const errSpy = vi.spyOn(console, "error").mockImplementation(() => {});
    vi.spyOn(console, "warn").mockImplementation(() => {});

    expect(main([playbookPath], { readLog: emptyLog, now: () => NOW })).toBe(1);
    const stderr = errSpy.mock.calls.flat().map(String).join("\n");
    expect(stderr).toContain("PLAYBOOK.md");
    expect(stderr).toContain("閉じていないコードフェンス");
    expect(stderr).not.toContain("レポート生成に失敗しました");
    expect(logSpy).not.toHaveBeenCalled();
  });

  /**
   * 全件を配列へ貯めてから落とす構造（最初の 1 件で return しない）は、複数ファイルを
   * 一度に名指しするためだけに存在する。1 ファイルしか測らないと `join(", ")` を
   * `[0]` へ縮める変異が生き残り、2 周目の実行まで残りの問題が見えない。
   */
  it("未閉フェンスが複数ファイルにあるとき全件を名指しする", () => {
    const { playbookPath } = makeFixture();
    const playbookDir = path.join(path.dirname(playbookPath), "playbook");
    fs.appendFileSync(path.join(playbookDir, "coding.md"), "\n```markdown\n閉じ忘れ。\n", "utf8");
    fs.writeFileSync(
      path.join(playbookDir, "testing.md"),
      "# PLAYBOOK — テスト (testing)\n\n```markdown\n閉じ忘れ。\n",
      "utf8",
    );
    vi.spyOn(console, "log").mockImplementation(() => {});
    const errSpy = vi.spyOn(console, "error").mockImplementation(() => {});
    vi.spyOn(console, "warn").mockImplementation(() => {});

    expect(main([playbookPath], { readLog: emptyLog, now: () => NOW })).toBe(1);
    const stderr = errSpy.mock.calls.flat().map(String).join("\n");
    expect(stderr).toContain("coding.md");
    expect(stderr).toContain("testing.md");
    expect(stderr).not.toContain("レポート生成に失敗しました");
  });
});

/**
 * 行数バジェット定数の結合テスト（Issue #313）。
 *
 * ace-refine-report と check-category-size は同じ 3 つの値（1 エントリのバジェット・
 * 例外マーカー文字列・例外時の倍率）を使うが、判定の粒度が違う — refine は 1 エントリ単位で
 * `lineCount > limit` を見て圧縮候補を挙げ、check はファイル全体の合計行数を
 * 件数から導出した上限と比べて警告する。値がずれると「check は警告を出すのに
 * refine の候補が空」という静かな不整合になる。
 *
 * ここでは**同一 fixture に両方の main を通す**。各ファイル内で自分の既定値を
 * 個別にピンするテストは既にあるが（`- ACE-90-1: 20 行（上限 15）` /
 * `導出上限 24 = ヘッダ 8 + 1 件 × 16`）、それらは「2 つの既定値が同じ値であること」を
 * 検査しない — 片方の定数とその同ファイルのテストを揃えて書き換えれば両方緑で通る。
 * 一致を assert するだけでも足りない（ACE-153-5: 定数の一致を検査しても適用は無検査に
 * なりうる／ACE-301-4: 共有契約の byte 照合は結合部を守らない）ため、
 * 両者の判定が同じ入力で同時に反転することを挙動で測る。
 */
describe("行数バジェット定数の単一源（check-category-size との結合）", () => {
  const tempDirs: string[] = [];
  const originalArgv = process.argv;
  const emptyLog = () => ({ commits: [], malformedCount: 0 });

  afterEach(() => {
    process.argv = originalArgv;
    vi.restoreAllMocks();
    vi.unstubAllEnvs();
    delete process.env.ACE_MAX_ENTRY_LINES;
    for (const dir of tempDirs.splice(0)) {
      fs.rmSync(dir, { recursive: true, force: true });
    }
  });

  /**
   * wc -l 行数ちょうどのコンパクト正準エントリブロックを作る。
   * 例外マーカーを足すぶん本文が 1 行減るので、**マーカーの有無で総行数が変わらない**。
   * ケース A/B が同一行数で marker だけ differ できるのはこの性質による。
   */
  function entryBlockOfLines(id: string, totalLines: number, withException: boolean): string {
    const fixed = [
      `<a id="ace-${id}"></a>`,
      "",
      `### ACE-${id}: t`,
      "",
      "| Category | coding | Origin | PR #1 |",
      "| Date | 2026-06-01 |",
      "| Helpful | 0 | Harmful | 0 |",
      "| Status | active |",
      "",
    ];
    if (withException) {
      fixed.push("<!-- ace-line-budget-exception: 反直感的な詳細のため -->");
    }
    const tail = ["---", "", ""];
    const bodyCount = totalLines - (fixed.length + tail.length - 1);
    if (bodyCount < 0) {
      throw new Error(`totalLines=${String(totalLines)} は固定部より短く表現できません`);
    }
    const body = Array.from({ length: bodyCount }, (_, i) => `本文 ${String(i)}`);
    return [...fixed, ...body, ...tail].join("\n");
  }

  function makeFixture(count: number, totalLines: number, withException: boolean): string {
    const root = fs.mkdtempSync(path.join(os.tmpdir(), "ace-budget-coupling-"));
    tempDirs.push(root);
    const knowledgeDir = path.join(root, "docs", "08-knowledge");
    const implDir = path.join(root, "docs", "03-implementation");
    fs.mkdirSync(path.join(knowledgeDir, "playbook"), { recursive: true });
    fs.mkdirSync(implDir, { recursive: true });

    const playbookPath = path.join(knowledgeDir, "PLAYBOOK.md");
    fs.writeFileSync(playbookPath, "# ACE Playbook\n\n## エントリ一覧\n", "utf8");
    fs.writeFileSync(path.join(implDir, "PATTERNS.md"), "# PATTERNS.md\n", "utf8");

    const entries = Array.from({ length: count }, (_, i) =>
      entryBlockOfLines(`1-${String(i + 1)}`, totalLines, withException),
    ).join("");
    fs.writeFileSync(
      path.join(knowledgeDir, "playbook", "coding.md"),
      `# PLAYBOOK — コーディング (coding)\n\n${entries}`,
      "utf8",
    );
    return playbookPath;
  }

  /** 同一 fixture に両方の main を通し、それぞれの出力を返す。 */
  function runBoth(playbookPath: string): {
    readonly refineReport: string;
    readonly checkWarnings: string;
  } {
    const logSpy = vi.spyOn(console, "log").mockImplementation(() => {});
    const errSpy = vi.spyOn(console, "error").mockImplementation(() => {});
    vi.spyOn(console, "warn").mockImplementation(() => {});

    expect(main([playbookPath], { readLog: emptyLog, now: () => NOW })).toBe(0);
    const refineReport = logSpy.mock.calls.map((c) => String(c[0])).join("\n");

    errSpy.mockClear();
    process.argv = ["node", "check-category-size.ts", playbookPath];
    // 行数超過は警告のみ（exit code は不変）という既存契約もここで踏む
    expect(checkCategorySizeMain()).toBe(0);
    const checkWarnings = errSpy.mock.calls.flat().map(String).join("\n");

    return { refineReport, checkWarnings };
  }

  it("既定バジェットは両者に同じ値として効く（18 行 × 3 件・例外なし → 両方が超過を報告）", () => {
    const { refineReport, checkWarnings } = runBoth(makeFixture(3, 19, false));

    // refine: 1 エントリ 18 行 > 既定 15 → 3 件すべて候補
    expect(refineReport).toContain("## 行数バジェット超過（3 件）");
    expect(refineReport).toContain("18 行（上限 15）");
    // check: 合計行数 > ヘッダ + 3 × (15 + 1) → 密度警告
    expect(checkWarnings).toContain("エントリ密度が行数バジェットを超過");
  });

  it("例外マーカーは両者を同時に緩める（同一行数で marker だけ differ → 両方が沈黙）", () => {
    const { refineReport, checkWarnings } = runBoth(makeFixture(3, 19, true));

    // refine: 例外上限 15 × 2 = 30 なので 18 行は候補外
    expect(refineReport).toContain("## 行数バジェット超過（0 件）");
    // check: 例外 3 件ぶんの余裕が加算され上限内
    expect(checkWarnings).not.toContain("エントリ密度が行数バジェットを超過");
  });

  it("例外時の倍率も両者に同じ値として効く（35 行 × 3 件・例外あり → 両方が超過を報告）", () => {
    // 35 行は 15 × 2 = 30 超・15 × 3 = 45 以下。倍率が 2 から動くと両者の判定が反転する。
    const { refineReport, checkWarnings } = runBoth(makeFixture(3, 36, true));

    expect(refineReport).toContain("## 行数バジェット超過（3 件）");
    expect(refineReport).toContain("35 行（上限 30・例外宣言あり）");
    expect(checkWarnings).toContain("エントリ密度が行数バジェットを超過");
  });

  /**
   * 非対称そのものの回帰（Issue #349）。「check が処理を拒否したファイルを refine だけが
   * 黙って測る」状態に戻らないことを、同一 fixture に対する両者の終了コードで固定する。
   * refine 側を `not.toBe(0)` で測るのは、両ファイルが別々の終了コード taxonomy を持つため
   * （refine の 2 は誤パス相当に予約されている）。値ではなく「拒否したこと」が契約。
   */
  it("未閉フェンスを含む同一 fixture は両者そろって拒否する（片方だけ測らない）", () => {
    const playbookPath = makeFixture(1, 19, false);
    fs.appendFileSync(
      path.join(path.dirname(playbookPath), "playbook", "coding.md"),
      "\n```markdown\n閉じ忘れたフェンス。\n",
      "utf8",
    );
    const logSpy = vi.spyOn(console, "log").mockImplementation(() => {});
    vi.spyOn(console, "error").mockImplementation(() => {});
    vi.spyOn(console, "warn").mockImplementation(() => {});

    expect(main([playbookPath], { readLog: emptyLog, now: () => NOW })).not.toBe(0);
    expect(logSpy).not.toHaveBeenCalled();

    process.argv = ["node", "check-category-size.ts", playbookPath];
    expect(checkCategorySizeMain()).toBe(2);
  });

  /**
   * 走査単位の非対称そのものの回帰（Issue #353）。ヘッダ領域で開いたフェンスが
   * エントリ本文の裸の ``` と対になる形は、**ファイル全体走査では「閉じている」**ため
   * refine 側の診断が立たず、check だけが拒否していた。しかも refine はそのまま
   * 「本物の例外宣言が無い」ものとして測るので、上限が 30 ではなく 15 で判定され
   * 偽の圧縮候補が出る（実測: hasException が false へ倒れる）。
   */
  it("セグメント境界をまたいで対になる閉じ忘れも両者そろって拒否する（Issue #353）", () => {
    const playbookPath = makeFixture(1, 19, false);
    const codingPath = path.join(path.dirname(playbookPath), "playbook", "coding.md");
    // ヘッダ領域（最初のエントリ見出しより前）で開き、エントリ本文の裸の ``` で対になる
    fs.writeFileSync(
      codingPath,
      "# PLAYBOOK — 実装 (coding)\n\n追記例:\n```markdown\n" +
        fs.readFileSync(codingPath, "utf8").replace(/^# .*\n/u, "") +
        "\n```\n",
      "utf8",
    );
    const logSpy = vi.spyOn(console, "log").mockImplementation(() => {});
    const errSpy = vi.spyOn(console, "error").mockImplementation(() => {});
    vi.spyOn(console, "warn").mockImplementation(() => {});

    expect(main([playbookPath], { readLog: emptyLog, now: () => NOW })).not.toBe(0);
    const stderr = errSpy.mock.calls.flat().map(String).join("\n");
    expect(stderr).toContain("閉じていないコードフェンス");
    // 位置まで名指しする（Issue #353 の追加 DoD）。ファイル名だけでは、この形は
    // 本文だけを見るとフェンスが対になって見えるため直しようがない。
    // 4 行目 = ヘッダ領域で開いた ```markdown（1-origin）。
    expect(stderr).toContain("coding.md:4");
    expect(logSpy).not.toHaveBeenCalled();

    process.argv = ["node", "check-category-size.ts", playbookPath];
    expect(checkCategorySizeMain()).toBe(2);
  });

  /**
   * 逆に、**実フェンスが 1 本も無い**ファイルはどちらも拒否しない（Issue #357）。
   * 合成判定を素朴な OR にすると、見出しタイトル中の ``` を偽の開始と見なす側の
   * 誤検出が refine へも広がり、正常なファイルが 2 つの CLI から拒否される。
   * #353 の AC はこの形を含まないので、このテストが唯一の歯止めになる。
   */
  it("見出しタイトル中の ``` だけのファイルはどちらも拒否しない（Issue #357 の偽陽性を広げない）", () => {
    const playbookPath = makeFixture(1, 19, false);
    const codingPath = path.join(path.dirname(playbookPath), "playbook", "coding.md");
    fs.writeFileSync(
      codingPath,
      fs
        .readFileSync(codingPath, "utf8")
        .replace(/^### (ACE-[\w-]+):.*$/mu, "### $1: ```markdown を説明するエントリ"),
      "utf8",
    );
    vi.spyOn(console, "log").mockImplementation(() => {});
    vi.spyOn(console, "error").mockImplementation(() => {});
    vi.spyOn(console, "warn").mockImplementation(() => {});

    expect(main([playbookPath], { readLog: emptyLog, now: () => NOW })).toBe(0);

    process.argv = ["node", "check-category-size.ts", playbookPath];
    expect(checkCategorySizeMain()).toBe(0);
  });
});

/**
 * エントリ見出しの ID 規則が 4 スクリプトで一致していることを、同一 fixture を
 * 4 者へ通して behavioral に測る（#318）。
 *
 * 期待値は「4 者が互いに一致すること」ではなく **正準形そのもの**で書く。相互一致だけを
 * 測ると、ID 本体を狭い系へ戻す変異で 4 者が揃って取りこぼしても緑のまま通ってしまい、
 * 変異試験が空振りする（ACE-153-5 の「一致を検査しても適用は無検査」と同型）。
 */
describe("エントリ見出し ID 規則の単一源（4 スクリプトの認識一致）", () => {
  afterEach(() => {
    vi.restoreAllMocks();
  });

  /** コンパクト正準の 1 エントリ。見出し行だけを差し替えられるようにしてある。 */
  function entryBlock(heading: string): string {
    return [
      "",
      heading,
      "",
      "| Category | coding | Origin | PR #1 |",
      "| Date | 2026-06-01 |",
      "| Helpful | 0 | Harmful | 0 |",
      "| Status | active |",
      "",
      "本文",
      "",
      "---",
      "",
    ].join("\n");
  }

  /**
   * プレースホルダ見出しを**必ず先頭**に置いた fixture を組む。
   * 認識されない見出しのブロックは直前のセグメントへ吸収されるため、途中に置くと
   * 「隣のエントリの Category 行が 2 本ある」状態になり、先勝ちで緑のまま通ってしまう。
   * 先頭なら分割のヘッダ側（splitEntrySegments の header）に入るので、誤認識が件数へ素直に出る。
   */
  function buildFixture(realHeadings: readonly string[]): string {
    return [
      "# PLAYBOOK — テスト",
      "",
      entryBlock("### ACE-XXX: プレースホルダ"),
      ...realHeadings.map((h) => entryBlock(h)),
    ].join("\n");
  }

  /**
   * 同一 fixture を 4 スクリプトの見出し認識へ通す。
   * check-category-size は split ベースで ID を返さず件数だけを返すため、
   * ID 集合の照合は 3 者、件数の照合は 4 者で行う。
   */
  function recognizeByAll(content: string): {
    readonly categorySizeCount: number;
    readonly entryFormatIds: string[];
    readonly refineIds: string[];
    readonly reuseIds: string[];
  } {
    vi.spyOn(console, "warn").mockImplementation(() => {});
    const analyzed = analyzePlaybookMarkdown(content);
    if (analyzed.kind !== "ok") {
      throw new Error(`check-category-size がこの fixture を解析できない: ${analyzed.message}`);
    }
    return {
      categorySizeCount: analyzed.totalEntries,
      entryFormatIds: splitEntries(content).map((e) => e.id),
      refineIds: measureEntryLines(content).measurements.map((m) => m.id),
      reuseIds: parsePlaybookEntries(content).map((e) => e.id),
    };
  }

  it("3 段以上の ID（ACE-1-2-3）を 4 者すべてがエントリとして認識する", () => {
    const got = recognizeByAll(buildFixture(["### ACE-1-2-3: 3 段 ID"]));

    expect(got.entryFormatIds).toEqual(["ACE-1-2-3"]);
    expect(got.refineIds).toEqual(["ACE-1-2-3"]);
    expect(got.reuseIds).toEqual(["ACE-1-2-3"]);
    expect(got.categorySizeCount).toBe(1);
  });

  it("`:` の直後にスペースが無い見出しを 4 者すべてがエントリとして認識する", () => {
    const got = recognizeByAll(buildFixture(["### ACE-1-1:スペース無し"]));

    expect(got.entryFormatIds).toEqual(["ACE-1-1"]);
    expect(got.refineIds).toEqual(["ACE-1-1"]);
    expect(got.reuseIds).toEqual(["ACE-1-1"]);
    expect(got.categorySizeCount).toBe(1);
  });

  it("プレースホルダ見出し（ACE-XXX）は 4 者すべてがエントリとして数えない", () => {
    const got = recognizeByAll(buildFixture(["### ACE-318-1: 実 ID"]));

    expect(got.entryFormatIds).toEqual(["ACE-318-1"]);
    expect(got.refineIds).toEqual(["ACE-318-1"]);
    expect(got.reuseIds).toEqual(["ACE-318-1"]);
    expect(got.categorySizeCount).toBe(1);
  });

  /**
   * 正準な ID 形式それぞれについて、見出し認識（4 者）と参照走査の**両方**が同じ ID へ到達する
   * ことを測る。3 段 ID だけを見ると `i` 枝や旧 3 桁を落とす変異が素通りするため、形式ごとに回す。
   * 参照走査まで含めるのは、見出し側だけ広げると誤 stale → 誤アーカイブになるため（#318）。
   */
  const CANONICAL_IDS = ["ACE-001", "ACE-438-1", "ACE-i425-1", "ACE-1-2-3", "ACE-438-1a"] as const;
  it.each(CANONICAL_IDS)("正準 ID %s は 4 者すべてが認識し、参照走査からも到達できる", (id) => {
    const content = buildFixture([`### ${id}: 正準形`]);
    const got = recognizeByAll(content);

    expect(got.entryFormatIds).toEqual([id]);
    expect(got.refineIds).toEqual([id]);
    expect(got.reuseIds).toEqual([id]);
    expect(got.categorySizeCount).toBe(1);

    const stats = computeReuseStats(
      parsePlaybookEntries(content),
      [{ date: "2026-08-01", subject: `chore: ${id} を再利用した`, body: "" }],
      content,
    );
    expect(stats.get(id)?.gitRefCount).toBe(1);
  });

  /**
   * 末尾が `-` の ID を許すと、見出しは認識されるのに参照走査の `\b` が `-` の手前まで後退して
   * その ID を永久に取り出せなくなる（参照 0 件 → 誤 stale → 誤アーカイブ）。単一源が末尾 `-` を
   * 文法から外していることを、4 者そろって非認識になることで固定する。
   */
  it("末尾が `-` の ID（ACE-337-）は 4 者すべてがエントリとして認識しない", () => {
    const content = buildFixture(["### ACE-337-: 末尾ハイフン", "### ACE-337-1: 正常"]);
    const got = recognizeByAll(content);

    expect(got.entryFormatIds).toEqual(["ACE-337-1"]);
    expect(got.refineIds).toEqual(["ACE-337-1"]);
    expect(got.reuseIds).toEqual(["ACE-337-1"]);
    expect(got.categorySizeCount).toBe(1);
  });

  it("スペースの有無でタイトル抽出が壊れない（従来形式は従来どおり）", () => {
    vi.spyOn(console, "warn").mockImplementation(() => {});
    const entries = parsePlaybookEntries(
      buildFixture(["### ACE-318-1: スペースあり", "### ACE-318-2:スペース無し"]),
    );

    expect(entries.map((e) => [e.id, e.title])).toEqual([
      ["ACE-318-1", "スペースあり"],
      ["ACE-318-2", "スペース無し"],
    ]);
  });

  /**
   * タイトルの無い見出しは、従来 reuse だけが取りこぼす一方 check-category-size は件数に
   * 数えていた（統合前の drift の一例）。統合後は 4 者そろって認識し、reuse は空タイトルを
   * 黙って通さず onWarn で表面化させる。
   */
  it("タイトルの無い見出しは 4 者そろって認識し、reuse は空タイトルを警告する", () => {
    const content = buildFixture(["### ACE-318-1:"]);
    const got = recognizeByAll(content);

    expect(got.entryFormatIds).toEqual(["ACE-318-1"]);
    expect(got.refineIds).toEqual(["ACE-318-1"]);
    expect(got.reuseIds).toEqual(["ACE-318-1"]);
    expect(got.categorySizeCount).toBe(1);

    const warnings: string[] = [];
    const entries = parsePlaybookEntries(content, (m) => warnings.push(m));
    expect(entries.map((e) => e.title)).toEqual([""]);
    expect(warnings).toContain(
      "ace-reuse-report: ACE-318-1 の見出しにタイトルがありません（空として扱います）",
    );
  });

  it("ID 参照の走査も見出しと同じ ID 規則で行う（見出しだけ広げると誤 stale になる）", () => {
    // 3 段 ID の参照が見えないと gitRefCount が 0 のまま stale 判定へ落ちる。
    vi.spyOn(console, "warn").mockImplementation(() => {});
    const content = buildFixture(["### ACE-1-2-3: 3 段 ID"]);
    const stats = computeReuseStats(
      parsePlaybookEntries(content),
      [{ date: "2026-08-01", subject: "chore: ACE-1-2-3 を再利用した", body: "" }],
      content,
    );

    expect(stats.get("ACE-1-2-3")?.gitRefCount).toBe(1);
  });
});
