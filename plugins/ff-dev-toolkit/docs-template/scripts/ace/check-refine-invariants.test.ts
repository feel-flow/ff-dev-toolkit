import { afterEach, describe, expect, it, vi } from "vitest";
import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";
import {
  compactProvenance,
  extractComparableBody,
  extractMetaFields,
  evaluateRefineInvariants,
  isVariantBCompact,
  main,
  mergedIntoTarget,
  parseChangelogOperations,
  splitEntryBlocks,
} from "./check-refine-invariants";

const LIVE_CANONICAL = [
  "### ACE-41-3: 並列委任は完了報告だけでは足りない",
  "",
  "| Category | process | Origin | PR #41 |",
  "| Date | 2026-07-07 |",
  "| Helpful | 4 | Harmful | 0 |",
  "| Status | active |",
  "",
  "**Insight**: 複数ファイルを機械的にコピーすると一部だけ完了する。",
  "",
].join("\n");

const ARCHIVE_VARIANT_B = [
  "### ACE-41-3: 並列委任は完了報告だけでは足りない",
  "",
  "> Compacted: 2026-08-14（live 側はメタ表のみ正準フォーマットへ再整形。本文は逐語同一で無改変。本エントリが原文）",
  "",
  "| フィールド | 値 |",
  "| ---------- | -- |",
  "| Category   | process |",
  "| Origin     | PR #41 |",
  "| Date       | 2026-07-07 |",
  "| Helpful    | 4 |",
  "| Harmful    | 0 |",
  "| Status     | active |",
  "",
  "**Insight**: 複数ファイルを機械的にコピーすると一部だけ完了する。",
  "",
].join("\n");

const PLAYBOOK_CHANGELOG = [
  "## エントリ一覧",
  "",
  "| エントリID | タイトル | Category | 参照先 |",
  "| ---------- | -------- | -------- | ------ |",
  "| ACE-41-3   | 並列委任は完了報告だけでは足りない | process | [playbook/process.md#ace-41-3](./playbook/process.md#ace-41-3) |",
  "| ACE-404-2  | trap EXIT の rc=0 化 | testing | [playbook/testing.md#ace-404-2](./playbook/testing.md#ace-404-2) |",
  "",
  "## Changelog",
  "",
  "### [1.140.0] - 2026-08-14",
  "",
  "#### 整理（/ace-refine）",
  "",
  "- Merged: ACE-430-1 → ACE-404-2（Helpful 1 を合算）",
  "- Compacted: process の旧テーブル形式 1 件: ACE-41-3（本文は逐語無改変）",
  "- Promoted: ACE-72-2（PATTERNS.md へ蒸留）",
  "",
].join("\n");

const LIVE_TARGET = [
  "### ACE-404-2: trap EXIT の rc=0 化はセンチネルで判定する",
  "",
  "| Category | testing | Origin | PR #404 |",
  "| Date | 2026-08-12 |",
  "| Helpful | 2 | Harmful | 0 |",
  "| Status | active |",
  "",
  "終了ステータスの保存では直らない。",
  "",
].join("\n");

const ARCHIVE_MERGED = [
  "### ACE-430-1: trap EXIT で掃除する suite は途中死しても rc=0",
  "",
  "> Merged into: [ACE-404-2](../testing.md#ace-404-2)（2026-08-14 /ace-refine）",
  "",
  "| Category | testing | Origin | PR #430 |",
  "| Date | 2026-08-12 |",
  "| Helpful | 1 | Harmful | 0 |",
  "| Status | merged |",
  "",
  "トラップ最終コマンドの成功が rc を上書きする。",
  "",
].join("\n");

const PATTERNS_LISTED = [
  "## 13. 実証済みパターン（ACE 昇格）",
  "",
  "### hook の fail-open は黙ることではない",
  "",
  "恒久異常はスキップした旨を通知したうえで exit 0 にする。",
  "",
  "出典: [ACE-72-2](../08-knowledge/playbook/tooling.md#ace-72-2)",
  "",
  "## Changelog",
  "",
  "- ACE-72-2 を蒸留昇格",
  "",
].join("\n");

function blocksOf(text: string, filePath = "memory.md") {
  return splitEntryBlocks(text, filePath);
}

describe("parseChangelogOperations", () => {
  it("Compacted / Merged / Promoted の ID を取る", () => {
    const ops = parseChangelogOperations(PLAYBOOK_CHANGELOG);
    expect(ops.compactedIds).toEqual(["ACE-41-3"]);
    expect(ops.mergedPairs).toEqual([{ source: "ACE-430-1", target: "ACE-404-2" }]);
    expect(ops.promotedIds).toEqual(["ACE-72-2"]);
    expect(ops.malformedMerged).toEqual([]);
  });

  it("矢印が壊れた Merged 行を malformed にする", () => {
    const ops = parseChangelogOperations("- Merged: ACE-1-1 => ACE-1-2\n");
    expect(ops.mergedPairs).toEqual([]);
    expect(ops.malformedMerged).toEqual(["- Merged: ACE-1-1 => ACE-1-2"]);
  });

  it("ID を列挙していない Compacted 行は空集合（集合一致の対象にしない）", () => {
    const ops = parseChangelogOperations(
      "- Compacted: tooling 全 46 件、testing 旧形式 40 件。原文は archive へ保全\n",
    );
    expect(ops.compactedIds).toEqual([]);
  });
});

describe("extractMetaFields / extractComparableBody", () => {
  it("正準 4 行から Origin と Harmful を行中から取る", () => {
    const meta = extractMetaFields(LIVE_CANONICAL);
    expect(meta.Category).toBe("process");
    expect(meta.Origin).toBe("PR #41");
    expect(meta.Date).toBe("2026-07-07");
    expect(meta.Helpful).toBe("4");
    expect(meta.Harmful).toBe("0");
    expect(meta.Status).toBe("active");
  });

  it("旧テーブル形式からも同じ 6 フィールドを取る", () => {
    const meta = extractMetaFields(ARCHIVE_VARIANT_B);
    expect(meta).toEqual(extractMetaFields(LIVE_CANONICAL));
  });

  it("provenance とメタ表を除く本文が live / archive で一致する", () => {
    expect(extractComparableBody(LIVE_CANONICAL)).toBe(
      extractComparableBody(ARCHIVE_VARIANT_B),
    );
    expect(extractComparableBody(LIVE_CANONICAL)).toContain("**Insight**:");
    expect(extractComparableBody(ARCHIVE_VARIANT_B)).not.toContain("Compacted:");
    expect(extractComparableBody(ARCHIVE_VARIANT_B)).not.toContain("フィールド");
  });

  it("次エントリ直前の <a id> と --- は本文に含めない", () => {
    const withNextAnchor = `${LIVE_CANONICAL}\n<a id="ace-78-1"></a>\n`;
    const withRule = `${ARCHIVE_VARIANT_B}\n---\n`;
    expect(extractComparableBody(withNextAnchor)).toBe(extractComparableBody(withRule));
    expect(extractComparableBody(withNextAnchor)).not.toContain("ace-78-1");
  });

  it("第 2 変種の provenance を識別する", () => {
    expect(isVariantBCompact(ARCHIVE_VARIANT_B)).toBe(true);
    expect(compactProvenance(LIVE_CANONICAL)).toBeNull();
  });
});

describe("evaluateRefineInvariants", () => {
  const healthy = () =>
    evaluateRefineInvariants({
      playbookContent: PLAYBOOK_CHANGELOG,
      liveBlocks: [...blocksOf(LIVE_CANONICAL), ...blocksOf(LIVE_TARGET)],
      archiveBlocks: [...blocksOf(ARCHIVE_VARIANT_B), ...blocksOf(ARCHIVE_MERGED)],
      patternsContent: PATTERNS_LISTED,
    });

  it("健全な compact / merge / promote は違反 0", () => {
    expect(healthy()).toEqual([]);
  });

  it("Changelog Compacted ID が live に無いと違反（後続 merge でない場合）", () => {
    const violations = evaluateRefineInvariants({
      playbookContent: PLAYBOOK_CHANGELOG,
      liveBlocks: blocksOf(LIVE_TARGET),
      archiveBlocks: [...blocksOf(ARCHIVE_VARIANT_B), ...blocksOf(ARCHIVE_MERGED)],
      patternsContent: PATTERNS_LISTED,
    });
    expect(
      violations.some((v) => v.includes("ACE-41-3") && v.includes("live に見出しが無い")),
    ).toBe(true);
  });

  it("compact の Category 不一致を検出する", () => {
    const drifted = ARCHIVE_VARIANT_B.replace("| Category   | process |", "| Category   | testing |");
    const violations = evaluateRefineInvariants({
      playbookContent: PLAYBOOK_CHANGELOG,
      liveBlocks: [...blocksOf(LIVE_CANONICAL), ...blocksOf(LIVE_TARGET)],
      archiveBlocks: [...blocksOf(drifted), ...blocksOf(ARCHIVE_MERGED)],
      patternsContent: PATTERNS_LISTED,
    });
    expect(violations.some((v) => v.includes("ACE-41-3") && v.includes("Category"))).toBe(
      true,
    );
  });

  it("compact の Helpful 減少を検出する", () => {
    const decreased = LIVE_CANONICAL.replace("| Helpful | 4 |", "| Helpful | 3 |");
    const violations = evaluateRefineInvariants({
      playbookContent: PLAYBOOK_CHANGELOG,
      liveBlocks: [...blocksOf(decreased), ...blocksOf(LIVE_TARGET)],
      archiveBlocks: [...blocksOf(ARCHIVE_VARIANT_B), ...blocksOf(ARCHIVE_MERGED)],
      patternsContent: PATTERNS_LISTED,
    });
    expect(violations.some((v) => v.includes("ACE-41-3") && v.includes("Helpful"))).toBe(
      true,
    );
  });

  it("Changelog Compacted ID が archive に無いと違反", () => {
    const violations = evaluateRefineInvariants({
      playbookContent: PLAYBOOK_CHANGELOG,
      liveBlocks: [...blocksOf(LIVE_CANONICAL), ...blocksOf(LIVE_TARGET)],
      archiveBlocks: blocksOf(ARCHIVE_MERGED),
      patternsContent: PATTERNS_LISTED,
    });
    expect(violations.some((v) => v.includes("ACE-41-3") && v.includes("archive"))).toBe(
      true,
    );
  });

  it("第 2 変種の本文が食い違うと違反", () => {
    const drifted = LIVE_CANONICAL.replace("一部だけ完了する。", "要約してしまった。");
    const violations = evaluateRefineInvariants({
      playbookContent: PLAYBOOK_CHANGELOG,
      liveBlocks: [...blocksOf(drifted), ...blocksOf(LIVE_TARGET)],
      archiveBlocks: [...blocksOf(ARCHIVE_VARIANT_B), ...blocksOf(ARCHIVE_MERGED)],
      patternsContent: PATTERNS_LISTED,
    });
    expect(violations.some((v) => v.includes("本文が live と archive で一致しない"))).toBe(
      true,
    );
  });

  it("統合元が live に残っていると違反", () => {
    const leftover = [
      "### ACE-430-1: 残存",
      "",
      "| Category | testing | Origin | PR #430 |",
      "| Date | 2026-08-12 |",
      "| Helpful | 1 | Harmful | 0 |",
      "| Status | active |",
      "",
      "残っている。",
      "",
    ].join("\n");
    const violations = evaluateRefineInvariants({
      playbookContent: PLAYBOOK_CHANGELOG,
      liveBlocks: [
        ...blocksOf(LIVE_CANONICAL),
        ...blocksOf(LIVE_TARGET),
        ...blocksOf(leftover),
      ],
      archiveBlocks: [...blocksOf(ARCHIVE_VARIANT_B), ...blocksOf(ARCHIVE_MERGED)],
      patternsContent: PATTERNS_LISTED,
    });
    expect(violations.some((v) => v.includes("統合元が live に残っている"))).toBe(true);
  });

  it("統合元が索引に残っていると違反", () => {
    const withIndex = PLAYBOOK_CHANGELOG.replace(
      "| ACE-41-3   |",
      "| ACE-430-1  | leftover | testing | [x](./x) |\n| ACE-41-3   |",
    );
    const violations = evaluateRefineInvariants({
      playbookContent: withIndex,
      liveBlocks: [...blocksOf(LIVE_CANONICAL), ...blocksOf(LIVE_TARGET)],
      archiveBlocks: [...blocksOf(ARCHIVE_VARIANT_B), ...blocksOf(ARCHIVE_MERGED)],
      patternsContent: PATTERNS_LISTED,
    });
    expect(violations.some((v) => v.includes("索引テーブルに残っている"))).toBe(true);
  });

  it("archive の Status が active のままだと違反", () => {
    const activeMerged = ARCHIVE_MERGED.replace("| Status | merged |", "| Status | active |");
    const violations = evaluateRefineInvariants({
      playbookContent: PLAYBOOK_CHANGELOG,
      liveBlocks: [...blocksOf(LIVE_CANONICAL), ...blocksOf(LIVE_TARGET)],
      archiveBlocks: [...blocksOf(ARCHIVE_VARIANT_B), ...blocksOf(activeMerged)],
      patternsContent: PATTERNS_LISTED,
    });
    expect(violations.some((v) => v.includes("Status が merged ではない"))).toBe(true);
  });

  it("archive 見出しが 2 件あると一意性違反", () => {
    const violations = evaluateRefineInvariants({
      playbookContent: PLAYBOOK_CHANGELOG,
      liveBlocks: [...blocksOf(LIVE_CANONICAL), ...blocksOf(LIVE_TARGET)],
      archiveBlocks: [
        ...blocksOf(ARCHIVE_VARIANT_B),
        ...blocksOf(ARCHIVE_MERGED),
        ...blocksOf(ARCHIVE_MERGED, "other.md"),
      ],
      patternsContent: PATTERNS_LISTED,
    });
    expect(violations.some((v) => v.includes("一意でない"))).toBe(true);
  });

  it("Merged into の ID が Changelog の統合先と違うと違反", () => {
    const wrongTarget = ARCHIVE_MERGED.replace(
      "[ACE-404-2](../testing.md#ace-404-2)",
      "[ACE-999-9](../testing.md#ace-999-9)",
    );
    const violations = evaluateRefineInvariants({
      playbookContent: PLAYBOOK_CHANGELOG,
      liveBlocks: [...blocksOf(LIVE_CANONICAL), ...blocksOf(LIVE_TARGET)],
      archiveBlocks: [...blocksOf(ARCHIVE_VARIANT_B), ...blocksOf(wrongTarget)],
      patternsContent: PATTERNS_LISTED,
    });
    expect(violations.some((v) => v.includes("Merged into のリンク先が ACE-999-9"))).toBe(
      true,
    );
  });

  it("統合先が live に無いと違反", () => {
    const violations = evaluateRefineInvariants({
      playbookContent: PLAYBOOK_CHANGELOG,
      liveBlocks: blocksOf(LIVE_CANONICAL),
      archiveBlocks: [...blocksOf(ARCHIVE_VARIANT_B), ...blocksOf(ARCHIVE_MERGED)],
      patternsContent: PATTERNS_LISTED,
    });
    expect(violations.some((v) => v.includes("が live に無い"))).toBe(true);
  });

  it("統合先の live Status が active でないと違反", () => {
    const deprecatedTarget = LIVE_TARGET.replace("| Status | active |", "| Status | deprecated |");
    const violations = evaluateRefineInvariants({
      playbookContent: PLAYBOOK_CHANGELOG,
      liveBlocks: [...blocksOf(LIVE_CANONICAL), ...blocksOf(deprecatedTarget)],
      archiveBlocks: [...blocksOf(ARCHIVE_VARIANT_B), ...blocksOf(ARCHIVE_MERGED)],
      patternsContent: PATTERNS_LISTED,
    });
    expect(violations.some((v) => v.includes("live Status が active ではない"))).toBe(
      true,
    );
  });

  it("Helpful 合算下限を下回ると違反", () => {
    const tooLow = LIVE_TARGET.replace("| Helpful | 2 |", "| Helpful | 0 |");
    const violations = evaluateRefineInvariants({
      playbookContent: PLAYBOOK_CHANGELOG,
      liveBlocks: [...blocksOf(LIVE_CANONICAL), ...blocksOf(tooLow)],
      archiveBlocks: [...blocksOf(ARCHIVE_VARIANT_B), ...blocksOf(ARCHIVE_MERGED)],
      patternsContent: PATTERNS_LISTED,
    });
    expect(violations.some((v) => v.includes("Helpful 合算下限"))).toBe(true);
  });

  it("Harmful 合算下限を下回ると違反", () => {
    const sourceWithHarmful = ARCHIVE_MERGED.replace("| Harmful | 0 |", "| Harmful | 2 |");
    const violations = evaluateRefineInvariants({
      playbookContent: PLAYBOOK_CHANGELOG,
      liveBlocks: [...blocksOf(LIVE_CANONICAL), ...blocksOf(LIVE_TARGET)],
      archiveBlocks: [...blocksOf(ARCHIVE_VARIANT_B), ...blocksOf(sourceWithHarmful)],
      patternsContent: PATTERNS_LISTED,
    });
    expect(violations.some((v) => v.includes("Harmful 合算下限"))).toBe(true);
  });

  it("Merged into が archive を指すと違反", () => {
    const badHref = ARCHIVE_MERGED.replace(
      "(../testing.md#ace-404-2)",
      "(./archive/testing.md#ace-404-2)",
    );
    const violations = evaluateRefineInvariants({
      playbookContent: PLAYBOOK_CHANGELOG,
      liveBlocks: [...blocksOf(LIVE_CANONICAL), ...blocksOf(LIVE_TARGET)],
      archiveBlocks: [...blocksOf(ARCHIVE_VARIANT_B), ...blocksOf(badHref)],
      patternsContent: PATTERNS_LISTED,
    });
    expect(violations.some((v) => v.includes("live の ACE-404-2 を指していない"))).toBe(
      true,
    );
  });

  it("Merged into のアンカーが別 ID だと違反", () => {
    const wrongHash = ARCHIVE_MERGED.replace(
      "(../testing.md#ace-404-2)",
      "(../testing.md#ace-wrong)",
    );
    const violations = evaluateRefineInvariants({
      playbookContent: PLAYBOOK_CHANGELOG,
      liveBlocks: [...blocksOf(LIVE_CANONICAL), ...blocksOf(LIVE_TARGET)],
      archiveBlocks: [...blocksOf(ARCHIVE_VARIANT_B), ...blocksOf(wrongHash)],
      patternsContent: PATTERNS_LISTED,
    });
    expect(violations.some((v) => v.includes("live の ACE-404-2 を指していない"))).toBe(
      true,
    );
  });

  it("同じ統合先への複数ソースは Helpful を合算する", () => {
    const changelog = `${PLAYBOOK_CHANGELOG}- Merged: ACE-408-2 → ACE-404-2\n`;
    const secondSource = [
      "### ACE-408-2: 二件目",
      "",
      "> Merged into: [ACE-404-2](../testing.md#ace-404-2)（2026-08-14 /ace-refine）",
      "",
      "| Category | testing | Origin | PR #408 |",
      "| Date | 2026-08-11 |",
      "| Helpful | 3 | Harmful | 0 |",
      "| Status | merged |",
      "",
      "本文。",
      "",
    ].join("\n");
    const violations = evaluateRefineInvariants({
      playbookContent: changelog,
      liveBlocks: [...blocksOf(LIVE_CANONICAL), ...blocksOf(LIVE_TARGET)],
      archiveBlocks: [
        ...blocksOf(ARCHIVE_VARIANT_B),
        ...blocksOf(ARCHIVE_MERGED),
        ...blocksOf(secondSource),
      ],
      patternsContent: PATTERNS_LISTED,
    });
    expect(violations.some((v) => v.includes("統合元合計 4"))).toBe(true);
  });

  it("連鎖 merge の最終 survivor が live なら中間は live 不要", () => {
    const changelog = PLAYBOOK_CHANGELOG.replace(
      "| ACE-404-2  | trap | testing | [playbook/testing.md#ace-404-2](./playbook/testing.md#ace-404-2) |\n",
      "| ACE-500-1  | 最終 | testing | [playbook/testing.md#ace-500-1](./playbook/testing.md#ace-500-1) |\n",
    ).replace(
      "- Merged: ACE-430-1 → ACE-404-2（Helpful 1 を合算）",
      "- Merged: ACE-430-1 → ACE-404-2（Helpful 1 を合算）\n- Merged: ACE-404-2 → ACE-500-1",
    );
    const midArchive = [
      "### ACE-404-2: 中間",
      "",
      "> Merged into: [ACE-500-1](../testing.md#ace-500-1)（2026-08-15 /ace-refine）",
      "",
      "| Category | testing | Origin | PR #404 |",
      "| Date | 2026-08-12 |",
      "| Helpful | 2 | Harmful | 0 |",
      "| Status | merged |",
      "",
      "中間。",
      "",
    ].join("\n");
    const finalLive = [
      "### ACE-500-1: 最終",
      "",
      "| Category | testing | Origin | PR #500 |",
      "| Date | 2026-08-15 |",
      "| Helpful | 3 | Harmful | 0 |",
      "| Status | active |",
      "",
      "最終。",
      "",
    ].join("\n");
    const violations = evaluateRefineInvariants({
      playbookContent: changelog,
      liveBlocks: [...blocksOf(LIVE_CANONICAL), ...blocksOf(finalLive)],
      archiveBlocks: [
        ...blocksOf(ARCHIVE_VARIANT_B),
        ...blocksOf(ARCHIVE_MERGED),
        ...blocksOf(midArchive),
      ],
      patternsContent: PATTERNS_LISTED,
    });
    expect(violations.filter((v) => v.includes("統合先") && v.includes("live に無い"))).toEqual(
      [],
    );
  });

  it("壊れた Merged 行は違反", () => {
    const changelog = `${PLAYBOOK_CHANGELOG}- Merged: ACE-1-1 => ACE-1-2\n`;
    const violations = evaluateRefineInvariants({
      playbookContent: changelog,
      liveBlocks: [...blocksOf(LIVE_CANONICAL), ...blocksOf(LIVE_TARGET)],
      archiveBlocks: [...blocksOf(ARCHIVE_VARIANT_B), ...blocksOf(ARCHIVE_MERGED)],
      patternsContent: PATTERNS_LISTED,
    });
    expect(violations.some((v) => v.includes("merge 行が解析できない"))).toBe(true);
  });

  it("compact 対象の live 見出しが 2 件なら違反", () => {
    const violations = evaluateRefineInvariants({
      playbookContent: PLAYBOOK_CHANGELOG,
      liveBlocks: [
        ...blocksOf(LIVE_CANONICAL),
        ...blocksOf(LIVE_CANONICAL, "other.md"),
        ...blocksOf(LIVE_TARGET),
      ],
      archiveBlocks: [...blocksOf(ARCHIVE_VARIANT_B), ...blocksOf(ARCHIVE_MERGED)],
      patternsContent: PATTERNS_LISTED,
    });
    expect(violations.some((v) => v.includes("ACE-41-3") && v.includes("live 見出し"))).toBe(
      true,
    );
  });

  it("Changelog 節にある本文+出典は昇格節の収載に数えない", () => {
    const pairOnlyInChangelog = [
      "## 13. 実証済みパターン（ACE 昇格）",
      "",
      "- 該当なし",
      "",
      "## Changelog",
      "",
      "### 偽のパターン",
      "",
      "恒久異常は通知したうえで exit 0 にする。",
      "",
      "出典: [ACE-72-2](../08-knowledge/playbook/tooling.md#ace-72-2)",
      "",
    ].join("\n");
    const violations = evaluateRefineInvariants({
      playbookContent: PLAYBOOK_CHANGELOG,
      liveBlocks: [...blocksOf(LIVE_CANONICAL), ...blocksOf(LIVE_TARGET)],
      archiveBlocks: [...blocksOf(ARCHIVE_VARIANT_B), ...blocksOf(ARCHIVE_MERGED)],
      patternsContent: pairOnlyInChangelog,
    });
    expect(violations.some((v) => v.includes("promote ACE-72-2"))).toBe(true);
  });

  it("Changelog だけの昇格言及は promote 違反", () => {
    const changelogOnly = [
      "## 13. 実証済みパターン（ACE 昇格）",
      "",
      "- 該当なし",
      "",
      "## Changelog",
      "",
      "- ACE-72-2 を蒸留昇格",
      "",
    ].join("\n");
    const violations = evaluateRefineInvariants({
      playbookContent: PLAYBOOK_CHANGELOG,
      liveBlocks: [...blocksOf(LIVE_CANONICAL), ...blocksOf(LIVE_TARGET)],
      archiveBlocks: [...blocksOf(ARCHIVE_VARIANT_B), ...blocksOf(ARCHIVE_MERGED)],
      patternsContent: changelogOnly,
    });
    expect(violations.some((v) => v.includes("promote ACE-72-2"))).toBe(true);
  });

  it("第 1 変種は本文不一致を本文違反にしない", () => {
    const variantA = ARCHIVE_VARIANT_B.replace(
      "live 側はメタ表のみ正準フォーマットへ再整形。本文は逐語同一で無改変。本エントリが原文",
      "live 側を要約済み。本文の原文は本エントリが正",
    );
    const summarized = LIVE_CANONICAL.replace(
      "**Insight**: 複数ファイルを機械的にコピーすると一部だけ完了する。",
      "委任先の完了報告を信じず実ファイルを照合する。",
    );
    const violations = evaluateRefineInvariants({
      playbookContent: PLAYBOOK_CHANGELOG,
      liveBlocks: [...blocksOf(summarized), ...blocksOf(LIVE_TARGET)],
      archiveBlocks: [...blocksOf(variantA), ...blocksOf(ARCHIVE_MERGED)],
      patternsContent: PATTERNS_LISTED,
    });
    expect(violations.filter((v) => v.includes("本文"))).toEqual([]);
  });
});

describe("mergedIntoTarget", () => {
  it("ポインタから統合先 ID を取る", () => {
    expect(mergedIntoTarget(ARCHIVE_MERGED)).toBe("ACE-404-2");
  });
});

describe("main", () => {
  const originalArgv = process.argv;
  let tmpDir = "";

  afterEach(() => {
    process.argv = originalArgv;
    vi.restoreAllMocks();
    if (tmpDir) {
      fs.rmSync(tmpDir, { recursive: true, force: true });
      tmpDir = "";
    }
  });

  function writeRepo(opts?: { mutateLiveBody?: boolean }): string {
    tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), "ace-refine-inv-"));
    const knowledge = path.join(tmpDir, "docs", "08-knowledge");
    const playbookDir = path.join(knowledge, "playbook");
    const archiveDir = path.join(playbookDir, "archive");
    const patternsDir = path.join(tmpDir, "docs", "03-implementation");
    fs.mkdirSync(archiveDir, { recursive: true });
    fs.mkdirSync(patternsDir, { recursive: true });
    const playbookPath = path.join(knowledge, "PLAYBOOK.md");
    fs.writeFileSync(playbookPath, PLAYBOOK_CHANGELOG);
    const liveBody = opts?.mutateLiveBody
      ? LIVE_CANONICAL.replace("一部だけ完了する。", "壊した。")
      : LIVE_CANONICAL;
    fs.writeFileSync(path.join(playbookDir, "process.md"), liveBody);
    fs.writeFileSync(path.join(playbookDir, "testing.md"), LIVE_TARGET);
    fs.writeFileSync(path.join(archiveDir, "process.md"), ARCHIVE_VARIANT_B);
    fs.writeFileSync(path.join(archiveDir, "testing.md"), ARCHIVE_MERGED);
    fs.writeFileSync(path.join(patternsDir, "PATTERNS.md"), PATTERNS_LISTED);
    return playbookPath;
  }

  it("健全な fixture は exit 0", () => {
    const playbookPath = writeRepo();
    process.argv = ["node", "check-refine-invariants.ts", playbookPath];
    vi.spyOn(console, "log").mockImplementation(() => {});
    vi.spyOn(console, "error").mockImplementation(() => {});
    expect(main()).toBe(0);
  });

  it("本文を変異させると exit 1（fail-closed）", () => {
    const playbookPath = writeRepo({ mutateLiveBody: true });
    process.argv = ["node", "check-refine-invariants.ts", playbookPath];
    vi.spyOn(console, "log").mockImplementation(() => {});
    const err = vi.spyOn(console, "error").mockImplementation(() => {});
    expect(main()).toBe(1);
    expect(err.mock.calls.flat().join("\n")).toContain("ACE-41-3");
  });

  it("引数が無ければ usage error", () => {
    process.argv = ["node", "check-refine-invariants.ts"];
    delete process.env.ACE_PLAYBOOK_PATH;
    vi.spyOn(console, "error").mockImplementation(() => {});
    expect(main()).toBe(2);
  });
});
