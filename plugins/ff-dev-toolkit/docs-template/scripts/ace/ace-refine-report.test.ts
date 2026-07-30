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
import { parsePlaybookEntries, type ReuseStats } from "./ace-reuse-report";

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

    const result = measureEntryLines(md);
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

    const result = measureEntryLines(md);
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

    const result = measureEntryLines(md);
    expect(result[0].hasException).toBe(true);
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

    const result = measureEntryLines(md);
    expect(result.map((m) => m.id)).toEqual(["ACE-50-1"]);
  });

  it("プレースホルダ見出し（ACE-XXX）はエントリとして数えない", () => {
    const md = ["### ACE-XXX: [タイトル]", "", "本文。", "---"].join("\n");
    expect(measureEntryLines(md)).toHaveLength(0);
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

    const result = measureEntryLines(md);
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

    const result = measureEntryLines(md);
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

    const result = measureEntryLines(md);
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

    const result = measureEntryLines(md);
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

    const result = measureEntryLines(md);
    expect(result[0].hasException).toBe(false);
  });
});

describe("findOverBudgetEntries", () => {
  const byFile = (measurements: readonly EntryLineMeasurement[]) =>
    new Map([["playbook/tooling.md", measurements]]);

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
});
