import { afterEach, describe, expect, it, vi } from "vitest";
import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";
import {
  archivedProvenance,
  compactProvenance,
  extractComparableBody,
  extractMetaFields,
  evaluateRefineInvariants,
  isArchivedMergedIntoHref,
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

/**
 * R3-a（stale アーカイブ）の fixture。
 * 「過去に compact 済み → 後日 archive」は SKILL.md R3-0 が正規の遷移として手順化しており
 * （保全済み ID には原文を再コピーせず provenance 行だけを追記して live を撤去する）、
 * live に見出しが無いのが**正常な**着地である（Issue #1028）。
 */
const ARCHIVE_TESTING = "docs/08-knowledge/playbook/archive/testing.md";
const ARCHIVE_PROCESS = "docs/08-knowledge/playbook/archive/process.md";

const ARCHIVED_PROVENANCE =
  "> Archived: 2026-08-30 / 理由: helpful=0・90日以上参照なし（原文は 2026-08-14 の圧縮で保全済み）";

const ARCHIVE_COMPACTED_THEN_ARCHIVED = ARCHIVE_VARIANT_B.replace(
  /^(> Compacted:.*)$/mu,
  `$1\n${ARCHIVED_PROVENANCE}`,
);

const LIVE_INDEX_ROW_41_3 =
  "| ACE-41-3   | 並列委任は完了報告だけでは足りない | process | [playbook/process.md#ace-41-3](./playbook/process.md#ace-41-3) |\n";

const PLAYBOOK_WITH_ARCHIVED = PLAYBOOK_CHANGELOG.replace(
  LIVE_INDEX_ROW_41_3,
  "",
).replace(
  "- Compacted: process の旧テーブル形式 1 件: ACE-41-3（本文は逐語無改変）",
  "- Compacted: process の旧テーブル形式 1 件: ACE-41-3（本文は逐語無改変）\n- Archived: ACE-41-3（helpful=0・stale。原文は圧縮で保全済みのため provenance のみ追記）",
);

const LIVE_INDEX_ROW_404_2 =
  "| ACE-404-2  | trap EXIT の rc=0 化 | testing | [playbook/testing.md#ace-404-2](./playbook/testing.md#ace-404-2) |\n";

/** 統合先 ACE-404-2 が後日アーカイブされた Changelog。 */
const PLAYBOOK_MERGE_TARGET_ARCHIVED = PLAYBOOK_CHANGELOG.replace(
  LIVE_INDEX_ROW_404_2,
  "",
).replace(
  "- Merged: ACE-430-1 → ACE-404-2（Helpful 1 を合算）",
  "- Merged: ACE-430-1 → ACE-404-2（Helpful 1 を合算）\n- Archived: ACE-404-2（helpful=0・stale）",
);

/** archive へ運ばれた統合先。R3-a は verbatim 保全なので Status は active のまま。 */
const ARCHIVE_TARGET_ARCHIVED = LIVE_TARGET.replace(
  "### ACE-404-2: trap EXIT の rc=0 化はセンチネルで判定する\n",
  `### ACE-404-2: trap EXIT の rc=0 化はセンチネルで判定する\n\n${ARCHIVED_PROVENANCE}\n`,
);

/** 統合先が archive へ移ったので、統合元の Merged into も archive 内を指すよう付け替える。 */
const ARCHIVE_MERGED_INTO_ARCHIVED = ARCHIVE_MERGED.replace(
  "(../testing.md#ace-404-2)",
  "(./testing.md#ace-404-2)",
);

function blocksOf(text: string, filePath = "memory.md") {
  return splitEntryBlocks(text, filePath);
}

describe("parseChangelogOperations", () => {
  it("Compacted / Merged / Promoted の ID を取る", () => {
    const ops = parseChangelogOperations(PLAYBOOK_CHANGELOG);
    expect(ops.compactedIds).toEqual(["ACE-41-3"]);
    expect(ops.mergedPairs).toEqual([{ source: "ACE-430-1", target: "ACE-404-2" }]);
    expect(ops.promotedIds).toEqual(["ACE-72-2"]);
    expect(ops.archivedIds).toEqual([]);
    expect(ops.malformedMerged).toEqual([]);
    expect(ops.malformedArchived).toEqual([]);
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

describe("Archived（R3-a: stale アーカイブ / Issue #1028）", () => {
  it("Changelog の Archived 行から ID を取る", () => {
    const ops = parseChangelogOperations(PLAYBOOK_WITH_ARCHIVED);
    expect(ops.archivedIds).toEqual(["ACE-41-3"]);
    expect(ops.compactedIds).toEqual(["ACE-41-3"]);
  });

  it("ID を列挙していない Archived 行は空集合", () => {
    const ops = parseChangelogOperations(
      "- Archived: なし（`findRefineArchiveCandidates` の候補 0 件）\n",
    );
    expect(ops.archivedIds).toEqual([]);
  });

  it("archive の Archived: provenance を識別する", () => {
    expect(archivedProvenance(ARCHIVE_COMPACTED_THEN_ARCHIVED)).toBe(ARCHIVED_PROVENANCE);
    expect(archivedProvenance(ARCHIVE_VARIANT_B)).toBeNull();
  });

  // AC 1: compact 済み ID の live 存続要求は Archived 記録で解除される
  it("compact 済み ID が Archived 記録付きで live から消えていれば違反 0", () => {
    const violations = evaluateRefineInvariants({
      playbookContent: PLAYBOOK_WITH_ARCHIVED,
      liveBlocks: blocksOf(LIVE_TARGET),
      archiveBlocks: [
        ...blocksOf(ARCHIVE_COMPACTED_THEN_ARCHIVED),
        ...blocksOf(ARCHIVE_MERGED),
      ],
      patternsContent: PATTERNS_LISTED,
    });
    expect(violations).toEqual([]);
  });

  // AC 2: 記録があるのに archive で一意でない（0 件 / 2 件以上）なら非 0
  it("Archived 記録があるのに archive に無いと違反", () => {
    const violations = evaluateRefineInvariants({
      playbookContent: PLAYBOOK_WITH_ARCHIVED,
      liveBlocks: blocksOf(LIVE_TARGET),
      archiveBlocks: blocksOf(ARCHIVE_MERGED),
      patternsContent: PATTERNS_LISTED,
    });
    expect(
      violations.some(
        (v) => v.startsWith("archive ACE-41-3") && v.includes("archive に見出しが無い"),
      ),
    ).toBe(true);
  });

  it("Archived 記録の ID が archive に 2 件あると違反", () => {
    const violations = evaluateRefineInvariants({
      playbookContent: PLAYBOOK_WITH_ARCHIVED,
      liveBlocks: blocksOf(LIVE_TARGET),
      archiveBlocks: [
        ...blocksOf(ARCHIVE_COMPACTED_THEN_ARCHIVED),
        ...blocksOf(ARCHIVE_COMPACTED_THEN_ARCHIVED, "other.md"),
        ...blocksOf(ARCHIVE_MERGED),
      ],
      patternsContent: PATTERNS_LISTED,
    });
    expect(
      violations.some((v) => v.startsWith("archive ACE-41-3") && v.includes("一意でない")),
    ).toBe(true);
  });

  // AC 4: 記録なき消失は引き続き拒否する（Archived パースが穴にならないこと）
  it("Archived 記録が無いまま compact 済み ID が live から消えたら違反", () => {
    const violations = evaluateRefineInvariants({
      playbookContent: PLAYBOOK_CHANGELOG,
      liveBlocks: blocksOf(LIVE_TARGET),
      archiveBlocks: [...blocksOf(ARCHIVE_VARIANT_B), ...blocksOf(ARCHIVE_MERGED)],
      patternsContent: PATTERNS_LISTED,
    });
    expect(
      violations.some(
        (v) => v.startsWith("compact ACE-41-3") && v.includes("live に見出しが無い"),
      ),
    ).toBe(true);
  });

  it("Archived と記録された ID が live に残っていると違反", () => {
    const violations = evaluateRefineInvariants({
      playbookContent: PLAYBOOK_WITH_ARCHIVED,
      liveBlocks: [...blocksOf(LIVE_CANONICAL), ...blocksOf(LIVE_TARGET)],
      archiveBlocks: [
        ...blocksOf(ARCHIVE_COMPACTED_THEN_ARCHIVED),
        ...blocksOf(ARCHIVE_MERGED),
      ],
      patternsContent: PATTERNS_LISTED,
    });
    expect(violations.some((v) => v.includes("live に残っている"))).toBe(true);
  });

  it("Archived と記録された ID が索引テーブルに残っていると違反", () => {
    const withIndex = PLAYBOOK_WITH_ARCHIVED.replace(
      "| ACE-404-2  |",
      `${LIVE_INDEX_ROW_41_3}| ACE-404-2  |`,
    );
    const violations = evaluateRefineInvariants({
      playbookContent: withIndex,
      liveBlocks: blocksOf(LIVE_TARGET),
      archiveBlocks: [
        ...blocksOf(ARCHIVE_COMPACTED_THEN_ARCHIVED),
        ...blocksOf(ARCHIVE_MERGED),
      ],
      patternsContent: PATTERNS_LISTED,
    });
    expect(violations.some((v) => v.includes("索引テーブルに残っている"))).toBe(true);
  });

  it("archive に Archived: provenance が無いと違反", () => {
    const violations = evaluateRefineInvariants({
      playbookContent: PLAYBOOK_WITH_ARCHIVED,
      liveBlocks: blocksOf(LIVE_TARGET),
      archiveBlocks: [...blocksOf(ARCHIVE_VARIANT_B), ...blocksOf(ARCHIVE_MERGED)],
      patternsContent: PATTERNS_LISTED,
    });
    expect(violations.some((v) => v.includes("Archived: provenance が無い"))).toBe(true);
  });

  // AC 3: 統合先の後日アーカイブは「許容」で固定する。
  // 許容の条件は Archived 記録 + archive での一意 + 統合元の Merged into が archive を指すこと
  // （chain の着地が live から archive へ移るので、ポインタも一緒に付け替える）。
  it("統合先が Archived 記録付きで archive へ移っていれば違反 0", () => {
    const violations = evaluateRefineInvariants({
      playbookContent: PLAYBOOK_MERGE_TARGET_ARCHIVED,
      liveBlocks: blocksOf(LIVE_CANONICAL),
      archiveBlocks: [
        ...blocksOf(ARCHIVE_VARIANT_B),
        ...blocksOf(ARCHIVE_MERGED_INTO_ARCHIVED, ARCHIVE_TESTING),
        ...blocksOf(ARCHIVE_TARGET_ARCHIVED, ARCHIVE_TESTING),
      ],
      patternsContent: PATTERNS_LISTED,
    });
    expect(violations).toEqual([]);
  });

  it("統合先が archive 済みなのに Merged into が live を指したままだと違反", () => {
    const violations = evaluateRefineInvariants({
      playbookContent: PLAYBOOK_MERGE_TARGET_ARCHIVED,
      liveBlocks: blocksOf(LIVE_CANONICAL),
      archiveBlocks: [
        ...blocksOf(ARCHIVE_VARIANT_B),
        ...blocksOf(ARCHIVE_MERGED, ARCHIVE_TESTING),
        ...blocksOf(ARCHIVE_TARGET_ARCHIVED, ARCHIVE_TESTING),
      ],
      patternsContent: PATTERNS_LISTED,
    });
    expect(violations.some((v) => v.includes("へ解決しない"))).toBe(true);
  });

  it("archive 済み統合先への Merged into が別ファイルを指していると違反", () => {
    const wrongFile = ARCHIVE_MERGED.replace(
      "(../testing.md#ace-404-2)",
      "(./process.md#ace-404-2)",
    );
    const violations = evaluateRefineInvariants({
      playbookContent: PLAYBOOK_MERGE_TARGET_ARCHIVED,
      liveBlocks: blocksOf(LIVE_CANONICAL),
      archiveBlocks: [
        ...blocksOf(ARCHIVE_VARIANT_B),
        ...blocksOf(wrongFile, ARCHIVE_TESTING),
        ...blocksOf(ARCHIVE_TARGET_ARCHIVED, ARCHIVE_TESTING),
      ],
      patternsContent: PATTERNS_LISTED,
    });
    expect(violations.some((v) => v.includes("へ解決しない"))).toBe(true);
  });

  it("archive 済み統合先への裸アンカーが別ファイル間だと違反", () => {
    const bareAnchor = ARCHIVE_MERGED.replace("(../testing.md#ace-404-2)", "(#ace-404-2)");
    const violations = evaluateRefineInvariants({
      playbookContent: PLAYBOOK_MERGE_TARGET_ARCHIVED,
      liveBlocks: blocksOf(LIVE_CANONICAL),
      archiveBlocks: [
        ...blocksOf(ARCHIVE_VARIANT_B),
        ...blocksOf(bareAnchor, ARCHIVE_PROCESS),
        ...blocksOf(ARCHIVE_TARGET_ARCHIVED, ARCHIVE_TESTING),
      ],
      patternsContent: PATTERNS_LISTED,
    });
    expect(violations.some((v) => v.includes("へ解決しない"))).toBe(true);
  });

  it("archive 済み統合先への裸アンカーは同一ファイルなら受ける", () => {
    const bareAnchor = ARCHIVE_MERGED.replace("(../testing.md#ace-404-2)", "(#ace-404-2)");
    const violations = evaluateRefineInvariants({
      playbookContent: PLAYBOOK_MERGE_TARGET_ARCHIVED,
      liveBlocks: blocksOf(LIVE_CANONICAL),
      archiveBlocks: [
        ...blocksOf(ARCHIVE_VARIANT_B),
        ...blocksOf(bareAnchor, ARCHIVE_TESTING),
        ...blocksOf(ARCHIVE_TARGET_ARCHIVED, ARCHIVE_TESTING),
      ],
      patternsContent: PATTERNS_LISTED,
    });
    expect(violations).toEqual([]);
  });

  // 統合の根拠だったカウンターが archive 側で 0 に落ちていたら緑にしない
  it("archive 済み統合先でもカウンター合算下限を検証する", () => {
    const zeroed = ARCHIVE_TARGET_ARCHIVED.replace(
      "| Helpful | 2 | Harmful | 0 |",
      "| Helpful | 0 | Harmful | 0 |",
    );
    const richSource = ARCHIVE_MERGED_INTO_ARCHIVED.replace(
      "| Helpful | 1 | Harmful | 0 |",
      "| Helpful | 5 | Harmful | 0 |",
    );
    const violations = evaluateRefineInvariants({
      playbookContent: PLAYBOOK_MERGE_TARGET_ARCHIVED,
      liveBlocks: blocksOf(LIVE_CANONICAL),
      archiveBlocks: [
        ...blocksOf(ARCHIVE_VARIANT_B),
        ...blocksOf(richSource, ARCHIVE_TESTING),
        ...blocksOf(zeroed, ARCHIVE_TESTING),
      ],
      patternsContent: PATTERNS_LISTED,
    });
    expect(violations.some((v) => v.includes("Helpful 合算下限"))).toBe(true);
  });

  it("archive 済み統合先でも統合元カウンターの数値検査は飛ばさない", () => {
    const unreadable = ARCHIVE_MERGED_INTO_ARCHIVED.replace(
      "| Helpful | 1 | Harmful | 0 |",
      "| Helpful | - | Harmful | n/a |",
    );
    const violations = evaluateRefineInvariants({
      playbookContent: PLAYBOOK_MERGE_TARGET_ARCHIVED,
      liveBlocks: blocksOf(LIVE_CANONICAL),
      archiveBlocks: [
        ...blocksOf(ARCHIVE_VARIANT_B),
        ...blocksOf(unreadable, ARCHIVE_TESTING),
        ...blocksOf(ARCHIVE_TARGET_ARCHIVED, ARCHIVE_TESTING),
      ],
      patternsContent: PATTERNS_LISTED,
    });
    expect(violations.some((v) => v.includes("数値として読めない"))).toBe(true);
  });

  it("統合先が Archived 記録付きなのに archive に無いと違反", () => {
    const violations = evaluateRefineInvariants({
      playbookContent: PLAYBOOK_MERGE_TARGET_ARCHIVED,
      liveBlocks: blocksOf(LIVE_CANONICAL),
      archiveBlocks: [
        ...blocksOf(ARCHIVE_VARIANT_B),
        ...blocksOf(ARCHIVE_MERGED_INTO_ARCHIVED, ARCHIVE_TESTING),
      ],
      patternsContent: PATTERNS_LISTED,
    });
    expect(violations.some((v) => v.includes("archive に無い"))).toBe(true);
  });

  it("統合先が Archived 記録なく live から消えていれば従来どおり違反", () => {
    const violations = evaluateRefineInvariants({
      playbookContent: PLAYBOOK_CHANGELOG,
      liveBlocks: blocksOf(LIVE_CANONICAL),
      archiveBlocks: [
        ...blocksOf(ARCHIVE_VARIANT_B),
        ...blocksOf(ARCHIVE_MERGED),
        ...blocksOf(ARCHIVE_TARGET_ARCHIVED),
      ],
      patternsContent: PATTERNS_LISTED,
    });
    expect(violations.some((v) => v.includes("統合先（最終 ACE-404-2）が live に無い"))).toBe(
      true,
    );
  });

  // AC 4 の裏側: 解除のトリガは Changelog の記録であって archive 側の provenance ではない
  it("archive に Archived: provenance だけあり Changelog の記録が無いと違反", () => {
    const violations = evaluateRefineInvariants({
      playbookContent: PLAYBOOK_CHANGELOG,
      liveBlocks: blocksOf(LIVE_TARGET),
      archiveBlocks: [
        ...blocksOf(ARCHIVE_COMPACTED_THEN_ARCHIVED),
        ...blocksOf(ARCHIVE_MERGED),
      ],
      patternsContent: PATTERNS_LISTED,
    });
    expect(
      violations.some(
        (v) => v.startsWith("compact ACE-41-3") && v.includes("live に見出しが無い"),
      ),
    ).toBe(true);
  });

  // 実データの 50 件はすべてこの型（compact でも merge 統合先でもない素の R3-a）
  it("compact でも統合先でもない素のアーカイブも検証対象になる", () => {
    const changelog = PLAYBOOK_CHANGELOG.replace(
      "- Promoted: ACE-72-2（PATTERNS.md へ蒸留）",
      "- Promoted: ACE-72-2（PATTERNS.md へ蒸留）\n- Archived: ACE-900-1（helpful=0・stale）",
    );
    const violations = evaluateRefineInvariants({
      playbookContent: changelog,
      liveBlocks: [...blocksOf(LIVE_CANONICAL), ...blocksOf(LIVE_TARGET)],
      archiveBlocks: [...blocksOf(ARCHIVE_VARIANT_B), ...blocksOf(ARCHIVE_MERGED)],
      patternsContent: PATTERNS_LISTED,
    });
    expect(
      violations.some(
        (v) => v.startsWith("archive ACE-900-1") && v.includes("archive に見出しが無い"),
      ),
    ).toBe(true);
  });

  it("統合元を Archived としても記録すると違反（終端状態の二重化）", () => {
    const changelog = PLAYBOOK_CHANGELOG.replace(
      "- Promoted: ACE-72-2（PATTERNS.md へ蒸留）",
      "- Promoted: ACE-72-2（PATTERNS.md へ蒸留）\n- Archived: ACE-430-1",
    );
    const violations = evaluateRefineInvariants({
      playbookContent: changelog,
      liveBlocks: [...blocksOf(LIVE_CANONICAL), ...blocksOf(LIVE_TARGET)],
      archiveBlocks: [...blocksOf(ARCHIVE_VARIANT_B), ...blocksOf(ARCHIVE_MERGED)],
      patternsContent: PATTERNS_LISTED,
    });
    expect(violations.some((v) => v.includes("両立しない終端状態"))).toBe(true);
  });

  it("1 行に複数 ID を列挙した Archived 行を全件拾う", () => {
    const ids = Array.from({ length: 32 }, (_, i) => `ACE-${String(700 + i)}-1`);
    const ops = parseChangelogOperations(
      `- Archived: ${ids.join(", ")}（helpful=0・stale。原文は archive へ保全）\n`,
    );
    expect(ops.archivedIds).toEqual([...ids].sort());
  });

  // archivedIds は検査を「外す」方向に効くので、理由の散文中の ID は拾わない
  it("理由の散文に現れた ID は archived として拾わない", () => {
    expect(
      parseChangelogOperations("- Archived: なし（ACE-41-3 は次回持ち越し）\n").archivedIds,
    ).toEqual([]);
    expect(
      parseChangelogOperations(
        "- Archived: ACE-1-1, ACE-2-2（判断は ACE-3-3 に従った）\n",
      ).archivedIds,
    ).toEqual(["ACE-1-1", "ACE-2-2"]);
  });

  it("区切りが , / 、 でない Archived 行は malformed として拒否する", () => {
    const ops = parseChangelogOperations("- Archived: ACE-1-1 / ACE-2-1（stale）\n");
    expect(ops.archivedIds).toEqual([]);
    expect(ops.malformedArchived).toEqual(["- Archived: ACE-1-1 / ACE-2-1（stale）"]);
    const violations = evaluateRefineInvariants({
      playbookContent: `${PLAYBOOK_CHANGELOG}- Archived: ACE-1-1 と ACE-2-1\n`,
      liveBlocks: [...blocksOf(LIVE_CANONICAL), ...blocksOf(LIVE_TARGET)],
      archiveBlocks: [...blocksOf(ARCHIVE_VARIANT_B), ...blocksOf(ARCHIVE_MERGED)],
      patternsContent: PATTERNS_LISTED,
    });
    expect(violations.some((v) => v.includes("ID 列が途中で切れている"))).toBe(true);
  });

  it("理由の括弧書きが続く Archived 行は malformed にしない", () => {
    const ops = parseChangelogOperations(
      "- Archived: ACE-1-1, ACE-2-1（helpful=0・stale。原文は archive へ保全）\n",
    );
    expect(ops.archivedIds).toEqual(["ACE-1-1", "ACE-2-1"]);
    expect(ops.malformedArchived).toEqual([]);
    expect(
      parseChangelogOperations("- Archived: なし（ACE-9-9 は次回持ち越し）\n").malformedArchived,
    ).toEqual([]);
  });

  // Issue #1115: 句点・括弧書きの後ろに ID が続く形は、前半だけ採用されて後続 ID が無検証になる。
  it("句点の後に ID が続く Archived 行は malformed として拒否する", () => {
    const ops = parseChangelogOperations("- Archived: ACE-1-1。ACE-2-1\n");
    expect(ops.archivedIds).toEqual([]);
    expect(ops.malformedArchived).toEqual(["- Archived: ACE-1-1。ACE-2-1"]);
  });

  it("理由の括弧書きの後に ID が続く Archived 行は malformed として拒否する", () => {
    const ops = parseChangelogOperations("- Archived: ACE-1-1（注記） / ACE-2-1\n");
    expect(ops.archivedIds).toEqual([]);
    expect(ops.malformedArchived).toEqual(["- Archived: ACE-1-1（注記） / ACE-2-1"]);
    const violations = evaluateRefineInvariants({
      playbookContent: `${PLAYBOOK_CHANGELOG}- Archived: ACE-1-1（注記） / ACE-2-1\n`,
      liveBlocks: [...blocksOf(LIVE_CANONICAL), ...blocksOf(LIVE_TARGET)],
      archiveBlocks: [...blocksOf(ARCHIVE_VARIANT_B), ...blocksOf(ARCHIVE_MERGED)],
      patternsContent: PATTERNS_LISTED,
    });
    expect(violations.some((v) => v.includes("archive 行の ID 列が途中で切れている"))).toBe(
      true,
    );
  });

  it("理由の括弧を閉じ忘れた Archived 行は malformed として拒否する", () => {
    const ops = parseChangelogOperations("- Archived: ACE-1-1（stale, ACE-2-1\n");
    expect(ops.archivedIds).toEqual([]);
    expect(ops.malformedArchived).toEqual(["- Archived: ACE-1-1（stale, ACE-2-1"]);
  });

  it("括弧で包んだ後続 ID が続く Archived 行も malformed として拒否する", () => {
    const ops = parseChangelogOperations("- Archived: ACE-1-1（注記） / （ACE-2-1）\n");
    expect(ops.archivedIds).toEqual([]);
    expect(ops.malformedArchived).toEqual(["- Archived: ACE-1-1（注記） / （ACE-2-1）"]);
  });

  it("括弧書きでない散文で理由を書いた Archived 行は malformed として拒否する", () => {
    const ops = parseChangelogOperations("- Archived: ACE-1-1。stale だったため撤去\n");
    expect(ops.archivedIds).toEqual([]);
    expect(ops.malformedArchived).toEqual(["- Archived: ACE-1-1。stale だったため撤去"]);
  });

  // live PLAYBOOK の実例（括弧書きの後ろに ID を含まない補足が続く形）は受理し続ける。
  it("理由の括弧書きの後に ID を含まない散文・注記が続く Archived 行は受理する", () => {
    const ops = parseChangelogOperations(
      "- Archived: ACE-1-1, ACE-2-1（helpful=0・stale）。**原文は圧縮で保全済み**（再コピーはしない）\n",
    );
    expect(ops.archivedIds).toEqual(["ACE-1-1", "ACE-2-1"]);
    expect(ops.malformedArchived).toEqual([]);
  });

  it("archive 済み統合先の Status が active でないと違反", () => {
    const deprecated = ARCHIVE_TARGET_ARCHIVED.replace(
      "| Status | active |",
      "| Status | deprecated |",
    );
    const violations = evaluateRefineInvariants({
      playbookContent: PLAYBOOK_MERGE_TARGET_ARCHIVED,
      liveBlocks: blocksOf(LIVE_CANONICAL),
      archiveBlocks: [
        ...blocksOf(ARCHIVE_VARIANT_B),
        ...blocksOf(ARCHIVE_MERGED_INTO_ARCHIVED, ARCHIVE_TESTING),
        ...blocksOf(deprecated, ARCHIVE_TESTING),
      ],
      patternsContent: PATTERNS_LISTED,
    });
    expect(violations.some((v) => v.includes("archive Status が active ではない"))).toBe(
      true,
    );
  });

  it("統合元カウンターが読めなくても統合先の構造検査は報告される", () => {
    const unreadable = ARCHIVE_MERGED.replace(
      "| Helpful | 1 | Harmful | 0 |",
      "| Helpful | - | Harmful | n/a |",
    );
    const violations = evaluateRefineInvariants({
      playbookContent: PLAYBOOK_CHANGELOG,
      liveBlocks: blocksOf(LIVE_CANONICAL),
      archiveBlocks: [...blocksOf(ARCHIVE_VARIANT_B), ...blocksOf(unreadable)],
      patternsContent: PATTERNS_LISTED,
    });
    expect(violations.some((v) => v.includes("数値として読めない"))).toBe(true);
    expect(violations.some((v) => v.includes("統合先（最終 ACE-404-2）が live に無い"))).toBe(
      true,
    );
  });

  it("isArchivedMergedIntoHref は archive 内の実着地だけを受ける", () => {
    const call = (href: string, from = ARCHIVE_TESTING, to = ARCHIVE_TESTING) =>
      isArchivedMergedIntoHref(href, "ACE-404-2", from, to);
    expect(call("./testing.md#ace-404-2")).toBe(true);
    expect(call("testing.md#ace-404-2")).toBe(true);
    expect(call("#ace-404-2")).toBe(true);
    // live 基準（`../`）は受けない
    expect(call("../testing.md#ace-404-2")).toBe(false);
    // アンカー違い・別ファイル・実在しないファイルはいずれも着地しない
    expect(call("./testing.md#ace-999-9")).toBe(false);
    expect(call("#ace-404-2", ARCHIVE_PROCESS, ARCHIVE_TESTING)).toBe(false);
    expect(call("./process.md#ace-404-2", ARCHIVE_PROCESS, ARCHIVE_TESTING)).toBe(false);
    expect(call("./testing.md#ace-404-2", ARCHIVE_PROCESS, ARCHIVE_TESTING)).toBe(true);
  });
});

describe("Changelog 節限定 / ID 列限定 / 重複除去（Issue #1030）", () => {
  // 欠陥 1: 走査を `## Changelog` 節に限定する。
  // エントリ本文が refine 運用を解説して同形 bullet を書くと操作として誤採用されていた。
  it("Changelog 節の外の Compacted / Promoted / Merged / Archived 行は採用しない", () => {
    const outside = [
      "## エントリ一覧",
      "",
      "### ACE-900-1: Changelog の書き方",
      "",
      "整理の記録は次の形で書く。",
      "",
      "- Compacted: ACE-777-1",
      "- Promoted: ACE-777-2",
      "- Merged: ACE-777-3 → ACE-777-4",
      "- Archived: ACE-777-5",
      "",
      "## Changelog",
      "",
      "- Compacted: ACE-41-3（本文は逐語無改変）",
      "",
    ].join("\n");
    const ops = parseChangelogOperations(outside);
    expect(ops.compactedIds).toEqual(["ACE-41-3"]);
    expect(ops.promotedIds).toEqual([]);
    expect(ops.mergedPairs).toEqual([]);
    expect(ops.archivedIds).toEqual([]);
  });

  it("Changelog 節より後ろのレベル 2 節に戻った行も採用しない", () => {
    const after = [
      "## Changelog",
      "",
      "- Compacted: ACE-41-3",
      "",
      "## 付録",
      "",
      "- Compacted: ACE-777-1",
      "",
    ].join("\n");
    expect(parseChangelogOperations(after).compactedIds).toEqual(["ACE-41-3"]);
  });

  it("レベル 2 見出しがあるのに Changelog 節が無ければ操作 0 件", () => {
    const noChangelog = ["## エントリ一覧", "", "- Compacted: ACE-777-1", ""].join("\n");
    expect(parseChangelogOperations(noChangelog).compactedIds).toEqual([]);
  });

  // 欠陥 2: Promoted も `Archived:` と同じ ID 列限定にする。
  it("Promoted の理由の散文に現れた ID は採用しない", () => {
    const ops = parseChangelogOperations(
      "- Promoted: なし（Helpful>=5 の ACE-47-1 / ACE-47-2 は PATTERNS.md へ収載済みで冪等スキップ）\n",
    );
    expect(ops.promotedIds).toEqual([]);
    expect(ops.malformedPromoted).toEqual([]);
  });

  it("Promoted の ID 列は理由の括弧書きで打ち切る", () => {
    const ops = parseChangelogOperations(
      "- Promoted: ACE-1-1, ACE-2-1（判断は ACE-3-3 に従った）\n",
    );
    expect(ops.promotedIds).toEqual(["ACE-1-1", "ACE-2-1"]);
    expect(ops.malformedPromoted).toEqual([]);
  });

  it("区切りが , / 、 でない Promoted 行は malformed として拒否する", () => {
    const ops = parseChangelogOperations("- Promoted: ACE-1-1 / ACE-2-1（蒸留）\n");
    expect(ops.promotedIds).toEqual([]);
    expect(ops.malformedPromoted).toEqual(["- Promoted: ACE-1-1 / ACE-2-1（蒸留）"]);
    const violations = evaluateRefineInvariants({
      playbookContent: `${PLAYBOOK_CHANGELOG}- Promoted: ACE-1-1 と ACE-2-1\n`,
      liveBlocks: [...blocksOf(LIVE_CANONICAL), ...blocksOf(LIVE_TARGET)],
      archiveBlocks: [...blocksOf(ARCHIVE_VARIANT_B), ...blocksOf(ARCHIVE_MERGED)],
      patternsContent: PATTERNS_LISTED,
    });
    expect(violations.some((v) => v.includes("promote 行の ID 列が途中で切れている"))).toBe(
      true,
    );
  });

  // Issue #1115: Archived と共有実装なので、同じ取りこぼしを Promoted でも拒否する。
  it("句点の後に ID が続く Promoted 行は malformed として拒否する", () => {
    const ops = parseChangelogOperations("- Promoted: ACE-1-1。ACE-2-1\n");
    expect(ops.promotedIds).toEqual([]);
    expect(ops.malformedPromoted).toEqual(["- Promoted: ACE-1-1。ACE-2-1"]);
  });

  it("理由の括弧書きの後に ID が続く Promoted 行は malformed として拒否する", () => {
    const ops = parseChangelogOperations("- Promoted: ACE-1-1（注記） / ACE-2-1\n");
    expect(ops.promotedIds).toEqual([]);
    expect(ops.malformedPromoted).toEqual(["- Promoted: ACE-1-1（注記） / ACE-2-1"]);
    const violations = evaluateRefineInvariants({
      playbookContent: `${PLAYBOOK_CHANGELOG}- Promoted: ACE-1-1（注記） / ACE-2-1\n`,
      liveBlocks: [...blocksOf(LIVE_CANONICAL), ...blocksOf(LIVE_TARGET)],
      archiveBlocks: [...blocksOf(ARCHIVE_VARIANT_B), ...blocksOf(ARCHIVE_MERGED)],
      patternsContent: PATTERNS_LISTED,
    });
    expect(violations.some((v) => v.includes("promote 行の ID 列が途中で切れている"))).toBe(
      true,
    );
  });

  it("理由の括弧を閉じ忘れた Promoted 行は malformed として拒否する", () => {
    const ops = parseChangelogOperations("- Promoted: ACE-1-1（蒸留, ACE-2-1\n");
    expect(ops.promotedIds).toEqual([]);
    expect(ops.malformedPromoted).toEqual(["- Promoted: ACE-1-1（蒸留, ACE-2-1"]);
  });

  it("括弧で包んだ後続 ID が続く Promoted 行も malformed として拒否する", () => {
    const ops = parseChangelogOperations("- Promoted: ACE-1-1（注記） / （ACE-2-1）\n");
    expect(ops.promotedIds).toEqual([]);
    expect(ops.malformedPromoted).toEqual(["- Promoted: ACE-1-1（注記） / （ACE-2-1）"]);
  });

  it("括弧書きでない散文で理由を書いた Promoted 行は malformed として拒否する", () => {
    const ops = parseChangelogOperations("- Promoted: ACE-1-1。PATTERNS.md へ蒸留\n");
    expect(ops.promotedIds).toEqual([]);
    expect(ops.malformedPromoted).toEqual(["- Promoted: ACE-1-1。PATTERNS.md へ蒸留"]);
  });

  it("理由の括弧書きの後に ID を含まない散文・注記が続く Promoted 行は受理する", () => {
    const ops = parseChangelogOperations(
      "- Promoted: ACE-1-1, ACE-2-1（[PATTERNS.md](../03-implementation/PATTERNS.md) へ蒸留）。元エントリは live に残す\n",
    );
    expect(ops.promotedIds).toEqual(["ACE-1-1", "ACE-2-1"]);
    expect(ops.malformedPromoted).toEqual([]);
  });

  // Compacted は前置きの散文と ID ごとの注記を持つ実例があるため、
  // コロン直後アンカーではなく「括弧書きの外」を ID 列とする。
  it("Compacted の括弧書きに現れた ID は採用しない", () => {
    expect(
      parseChangelogOperations("- Compacted: なし（ACE-9-9 は次回に持ち越し）\n").compactedIds,
    ).toEqual([]);
  });

  it("Compacted は前置きの散文と ID ごとの注記があっても全件拾う", () => {
    const ops = parseChangelogOperations(
      "- Compacted: process の旧テーブル形式 3 件を再整形（本文は逐語無改変）: ACE-1-1（18 → 12 行）, ACE-2-1, ACE-3-1（16 → 12 行）\n",
    );
    expect(ops.compactedIds).toEqual(["ACE-1-1", "ACE-2-1", "ACE-3-1"]);
  });

  // Issue #1184: 注記と前置き散文は許すが、**ID どうしの区切り**は `Archived:` /
  // `Promoted:` と同じ厳密さにする（`,` / `、` 以外は列挙として読まない）。
  it("Compacted の ID を `/` で並べた行は malformed として拒否する", () => {
    const ops = parseChangelogOperations("- Compacted: ACE-1-1 / ACE-2-1\n");
    expect(ops.compactedIds).toEqual([]);
    expect(ops.malformedCompacted).toEqual(["- Compacted: ACE-1-1 / ACE-2-1"]);
  });

  it("Compacted の ID を句点で区切った行は malformed として拒否する", () => {
    const ops = parseChangelogOperations("- Compacted: ACE-1-1。ACE-2-1\n");
    expect(ops.compactedIds).toEqual([]);
    expect(ops.malformedCompacted).toEqual(["- Compacted: ACE-1-1。ACE-2-1"]);
  });

  it("Compacted の注記の後ろが `,` / `、` 以外で続く行は malformed として拒否する", () => {
    const ops = parseChangelogOperations("- Compacted: ACE-1-1（18 → 12 行） / ACE-2-1\n");
    expect(ops.compactedIds).toEqual([]);
    expect(ops.malformedCompacted).toEqual(["- Compacted: ACE-1-1（18 → 12 行） / ACE-2-1"]);
  });

  it("Compacted の注記の直後に区切り無しで ID が続く行は malformed として拒否する", () => {
    const ops = parseChangelogOperations("- Compacted: ACE-1-1（18 → 12 行）ACE-2-1\n");
    expect(ops.compactedIds).toEqual([]);
    expect(ops.malformedCompacted).toEqual(["- Compacted: ACE-1-1（18 → 12 行）ACE-2-1"]);
  });

  it("Compacted の ID 列の後ろに ID を含まない散文が続く行は受理する", () => {
    const ops = parseChangelogOperations(
      "- Compacted: ACE-1-1（18 → 12 行）, ACE-2-1（16 → 12 行）— 行数は anchor 行〜終端を含む。原文は archive へ保全\n",
    );
    expect(ops.compactedIds).toEqual(["ACE-1-1", "ACE-2-1"]);
    expect(ops.malformedCompacted).toEqual([]);
  });

  it("Compacted の後続散文の括弧内に現れた ID は列挙の続きとみなさない", () => {
    const ops = parseChangelogOperations(
      "- Compacted: ACE-1-1（18 → 12 行）。本文は逐語同一（ACE-1-1 のみ 3 段落を 1 行へ連結）\n",
    );
    expect(ops.compactedIds).toEqual(["ACE-1-1"]);
    expect(ops.malformedCompacted).toEqual([]);
  });

  it("前置きと後続の両方に ID が裸で現れる Compacted 行は malformed として拒否する", () => {
    const ops = parseChangelogOperations("- Compacted: ACE-1-1 は据え置き。圧縮したのは ACE-2-1\n");
    expect(ops.compactedIds).toEqual([]);
    expect(ops.malformedCompacted).toEqual([
      "- Compacted: ACE-1-1 は据え置き。圧縮したのは ACE-2-1",
    ]);
  });

  // 注記の**位置**は Compacted の自由度として残す（狭めると develop で通っていた行が落ちる）。
  // 厳密にするのは ID どうしの区切りが `,` / `、` かどうかだけ。
  it("注記の前に空白がある Compacted 行は受理する", () => {
    const ops = parseChangelogOperations("- Compacted: ACE-1-1 （18 → 12 行）, ACE-2-1\n");
    expect(ops.compactedIds).toEqual(["ACE-1-1", "ACE-2-1"]);
    expect(ops.malformedCompacted).toEqual([]);
  });

  it("注記が連続する Compacted 行は受理する", () => {
    const ops = parseChangelogOperations("- Compacted: ACE-1-1（18 → 12 行）（逐語同一）, ACE-2-1\n");
    expect(ops.compactedIds).toEqual(["ACE-1-1", "ACE-2-1"]);
    expect(ops.malformedCompacted).toEqual([]);
  });

  it("区切りの後ろに注記がある Compacted 行は受理する", () => {
    const ops = parseChangelogOperations("- Compacted: ACE-1-1（18 → 12 行）, （再整形のみ）ACE-2-1\n");
    expect(ops.compactedIds).toEqual(["ACE-1-1", "ACE-2-1"]);
    expect(ops.malformedCompacted).toEqual([]);
  });

  // 閉じ括弧の**余り**は、括弧書きが 1 つも無い行として ID を隣接させ、
  // `ACE-1-1ACE-2-1` という実在しない ID 1 件へ融合させる（実在 2 件は無検証になる）。
  it("閉じ括弧が余る Compacted 行は malformed として拒否する", () => {
    const ops = parseChangelogOperations("- Compacted: ACE-1-1）ACE-2-1\n");
    expect(ops.compactedIds).toEqual([]);
    expect(ops.malformedCompacted).toEqual(["- Compacted: ACE-1-1）ACE-2-1"]);
  });

  it("半角の閉じ括弧が余る Compacted 行も malformed として拒否する", () => {
    const ops = parseChangelogOperations("- Compacted: ACE-1-1)ACE-2-1\n");
    expect(ops.compactedIds).toEqual([]);
    expect(ops.malformedCompacted).toEqual(["- Compacted: ACE-1-1)ACE-2-1"]);
  });

  // parseChangelogOperations の戻り値だけを見ていると、malformedCompacted を violations へ
  // 積む配線（evaluateRefineInvariants）を消してもテストが緑のままになる。
  it("区切りが不正な Compacted 行はゲートの違反として報告される", () => {
    const violations = evaluateRefineInvariants({
      playbookContent: `${PLAYBOOK_CHANGELOG}- Compacted: ACE-1-1 / ACE-2-1\n`,
      liveBlocks: [...blocksOf(LIVE_CANONICAL), ...blocksOf(LIVE_TARGET)],
      archiveBlocks: [...blocksOf(ARCHIVE_VARIANT_B), ...blocksOf(ARCHIVE_MERGED)],
      patternsContent: PATTERNS_LISTED,
    });
    expect(violations.some((v) => v.includes("compact 行の ID 列が読めない"))).toBe(true);
    expect(violations.some((v) => v.includes("- Compacted: ACE-1-1 / ACE-2-1"))).toBe(true);
  });

  it("括弧を閉じ忘れた Compacted 行もゲートの違反として報告される", () => {
    const violations = evaluateRefineInvariants({
      playbookContent: `${PLAYBOOK_CHANGELOG}- Compacted: ACE-1-1（注記, ACE-2-1\n`,
      liveBlocks: [...blocksOf(LIVE_CANONICAL), ...blocksOf(LIVE_TARGET)],
      archiveBlocks: [...blocksOf(ARCHIVE_VARIANT_B), ...blocksOf(ARCHIVE_MERGED)],
      patternsContent: PATTERNS_LISTED,
    });
    expect(violations.some((v) => v.includes("compact 行の ID 列が読めない"))).toBe(true);
  });

  // 規則の適用範囲は **ID どうしの間**だけ。ID が 1 件の行に散文が付いていても、
  // 区切りが存在しないので違反にはならない（`Compacted:` に許した補足散文と区別できない）。
  it("ID が 1 件だけの Compacted 行は散文が付いていても受理する", () => {
    const ops = parseChangelogOperations("- Compacted: ACE-1-1 は据え置き。圧縮は次回\n");
    expect(ops.compactedIds).toEqual(["ACE-1-1"]);
    expect(ops.malformedCompacted).toEqual([]);
  });

  it("Compacted の区切りは `,` / `、` / 空白の有無を問わず受理する", () => {
    const ops = parseChangelogOperations("- Compacted: ACE-1-1,ACE-2-1、　ACE-3-1, ACE-4-1\n");
    expect(ops.compactedIds).toEqual(["ACE-1-1", "ACE-2-1", "ACE-3-1", "ACE-4-1"]);
    expect(ops.malformedCompacted).toEqual([]);
  });

  // 番兵 U+FFFC が入力に直接書かれても、区切り（`,` / `、`）の要求は外れない。
  // 注記 1 つと同じ扱いになるだけで、ID が検査から漏れる経路は生まれない。
  it("入力に直接書かれた U+FFFC は区切りの要求を外さない", () => {
    expect(
      parseChangelogOperations("- Compacted: ACE-1-1\uFFFC ACE-2-1\n").malformedCompacted,
    ).toEqual(["- Compacted: ACE-1-1\uFFFC ACE-2-1"]);
    const separated = parseChangelogOperations("- Compacted: ACE-1-1\uFFFC, ACE-2-1\n");
    expect(separated.compactedIds).toEqual(["ACE-1-1", "ACE-2-1"]);
    expect(separated.malformedCompacted).toEqual([]);
  });

  // 欠陥 3: 同一の Merged 行が 2 行あっても合算下限は 1 回分。
  it("同一の Merged 行が 2 行あっても合算は 1 回分", () => {
    const duplicated = `${PLAYBOOK_CHANGELOG}- Merged: ACE-430-1 → ACE-404-2（重複記載）\n`;
    expect(parseChangelogOperations(duplicated).mergedPairs).toEqual([
      { source: "ACE-430-1", target: "ACE-404-2" },
    ]);
    // 統合先 Helpful=1 / 統合元 Helpful=1。二重加算されると下限 2 を要求して落ちる。
    const targetHelpfulOne = LIVE_TARGET.replace(
      "| Helpful | 2 | Harmful | 0 |",
      "| Helpful | 1 | Harmful | 0 |",
    );
    const violations = evaluateRefineInvariants({
      playbookContent: duplicated,
      liveBlocks: [...blocksOf(LIVE_CANONICAL), ...blocksOf(targetHelpfulOne)],
      archiveBlocks: [...blocksOf(ARCHIVE_VARIANT_B), ...blocksOf(ARCHIVE_MERGED)],
      patternsContent: PATTERNS_LISTED,
    });
    expect(violations).toEqual([]);
  });

  it("統合先が違う Merged 行は重複除去でまとめない", () => {
    const ops = parseChangelogOperations(
      "- Merged: ACE-1-1 → ACE-2-1\n- Merged: ACE-1-1 → ACE-3-1\n",
    );
    expect(ops.mergedPairs).toEqual([
      { source: "ACE-1-1", target: "ACE-2-1" },
      { source: "ACE-1-1", target: "ACE-3-1" },
    ]);
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

  function writeRepo(opts?: { mutateLiveBody?: boolean; archived?: boolean }): string {
    tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), "ace-refine-inv-"));
    const knowledge = path.join(tmpDir, "docs", "08-knowledge");
    const playbookDir = path.join(knowledge, "playbook");
    const archiveDir = path.join(playbookDir, "archive");
    const patternsDir = path.join(tmpDir, "docs", "03-implementation");
    fs.mkdirSync(archiveDir, { recursive: true });
    fs.mkdirSync(patternsDir, { recursive: true });
    const playbookPath = path.join(knowledge, "PLAYBOOK.md");
    fs.writeFileSync(
      playbookPath,
      opts?.archived ? PLAYBOOK_WITH_ARCHIVED : PLAYBOOK_CHANGELOG,
    );
    const liveBody = opts?.mutateLiveBody
      ? LIVE_CANONICAL.replace("一部だけ完了する。", "壊した。")
      : LIVE_CANONICAL;
    // archived fixture では live 側から ACE-41-3 が撤去済み（R3-a step 4）
    fs.writeFileSync(path.join(playbookDir, "process.md"), opts?.archived ? "" : liveBody);
    fs.writeFileSync(path.join(playbookDir, "testing.md"), LIVE_TARGET);
    fs.writeFileSync(
      path.join(archiveDir, "process.md"),
      opts?.archived ? ARCHIVE_COMPACTED_THEN_ARCHIVED : ARCHIVE_VARIANT_B,
    );
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

  it("compact → 後日 archive の fixture も exit 0（Issue #1028）", () => {
    const playbookPath = writeRepo({ archived: true });
    process.argv = ["node", "check-refine-invariants.ts", playbookPath];
    vi.spyOn(console, "log").mockImplementation(() => {});
    const err = vi.spyOn(console, "error").mockImplementation(() => {});
    expect(main()).toBe(0);
    expect(err.mock.calls.flat().join("\n")).not.toContain("ACE-41-3");
  });

  it("本文を変異させると exit 1（fail-closed）", () => {
    const playbookPath = writeRepo({ mutateLiveBody: true });
    process.argv = ["node", "check-refine-invariants.ts", playbookPath];
    vi.spyOn(console, "log").mockImplementation(() => {});
    const err = vi.spyOn(console, "error").mockImplementation(() => {});
    expect(main()).toBe(1);
    expect(err.mock.calls.flat().join("\n")).toContain("ACE-41-3");
  });

  it("Archived 記録の ID が archive に無ければ exit 1（archive ループ由来）", () => {
    const playbookPath = writeRepo({ archived: true });
    const archiveProcess = path.join(
      path.dirname(playbookPath),
      "playbook",
      "archive",
      "process.md",
    );
    fs.writeFileSync(archiveProcess, "");
    process.argv = ["node", "check-refine-invariants.ts", playbookPath];
    vi.spyOn(console, "log").mockImplementation(() => {});
    const err = vi.spyOn(console, "error").mockImplementation(() => {});
    expect(main()).toBe(1);
    expect(err.mock.calls.flat().join("\n")).toContain("archive ACE-41-3");
  });

  it("引数が無ければ usage error", () => {
    process.argv = ["node", "check-refine-invariants.ts"];
    delete process.env.ACE_PLAYBOOK_PATH;
    vi.spyOn(console, "error").mockImplementation(() => {});
    expect(main()).toBe(2);
  });
});

describe("parseChangelogOperations — Codex レビュー追補（Issue #1030）", () => {
  it("コードフェンス内の偽 `## Changelog` を節境界として採用しない", () => {
    const content = [
      "# PLAYBOOK",
      "",
      "```markdown",
      "## Changelog",
      "- Compacted: ACE-9-9",
      "```",
      "",
      "## Changelog",
      "",
      "### [1.1.0] - 2026-09-01",
      "",
      "- Compacted: ACE-1-1",
      "",
    ].join("\n");
    const ops = parseChangelogOperations(content);
    expect(ops.compactedIds).toEqual(["ACE-1-1"]);
  });

  it("HTML コメント内の Compacted 例示を操作として採用しない", () => {
    const content = [
      "## Changelog",
      "",
      "<!--",
      "- Compacted: ACE-9-9",
      "-->",
      "- Compacted: ACE-1-1",
      "",
    ].join("\n");
    const ops = parseChangelogOperations(content);
    expect(ops.compactedIds).toEqual(["ACE-1-1"]);
  });

  it("Compacted 行の括弧閉じ忘れは部分採用せず違反へ回す", () => {
    const content = [
      "## Changelog",
      "",
      "- Compacted: ACE-1-1（注記, ACE-2-1",
      "",
    ].join("\n");
    const ops = parseChangelogOperations(content);
    expect(ops.compactedIds).toEqual([]);
    expect(ops.malformedCompacted).toHaveLength(1);
  });

  // 括弧の対応種（全角 / 半角）が食い違う行は、書き手が意図した注記の範囲と
  // パーサが読む範囲がずれたまま受理されるため 4 ラベル共通で違反にする。
  it("括弧の対応種が食い違う Compacted / Archived 行は malformed として拒否する", () => {
    const compacted = parseChangelogOperations("- Compacted: ACE-1-1（注記), ACE-2-1\n");
    expect(compacted.compactedIds).toEqual([]);
    expect(compacted.malformedParenthesisKind).toEqual([
      "- Compacted: ACE-1-1（注記), ACE-2-1",
    ]);
    const archived = parseChangelogOperations("- Archived: ACE-1-1(注記）\n");
    expect(archived.archivedIds).toEqual([]);
    expect(archived.malformedParenthesisKind).toEqual(["- Archived: ACE-1-1(注記）"]);
    const violations = evaluateRefineInvariants({
      playbookContent: `${PLAYBOOK_CHANGELOG}- Archived: ACE-1-1(注記）\n`,
      liveBlocks: [...blocksOf(LIVE_CANONICAL), ...blocksOf(LIVE_TARGET)],
      archiveBlocks: [...blocksOf(ARCHIVE_VARIANT_B), ...blocksOf(ARCHIVE_MERGED)],
      patternsContent: PATTERNS_LISTED,
    });
    expect(violations.some((v) => v.includes("括弧の対応種が食い違っている"))).toBe(true);
  });

  it("同じ種類で入れ子にした括弧書きは対応種の違反にしない", () => {
    const ops = parseChangelogOperations("- Archived: ACE-1-1（注記 (詳細) ここまで）\n");
    expect(ops.archivedIds).toEqual(["ACE-1-1"]);
    expect(ops.malformedParenthesisKind).toEqual([]);
    expect(ops.malformedArchived).toEqual([]);
  });

  // 括弧の中にしか ID が無い行は、括弧の外の ID 列が空になるので「無操作」に化け、
  // 宣言された ID が archive 存在・provenance・逐語一致の検査から丸ごと外れる。
  it("括弧の中だけに ID を列挙した行は 4 ラベルとも malformed として拒否する", () => {
    const compacted = parseChangelogOperations(
      "- Compacted: 3 件（ACE-1-1, ACE-2-1, ACE-3-1）をまとめて圧縮\n",
    );
    expect(compacted.compactedIds).toEqual([]);
    expect(compacted.malformedParentheticalIds).toEqual([
      "- Compacted: 3 件（ACE-1-1, ACE-2-1, ACE-3-1）をまとめて圧縮",
    ]);

    const archived = parseChangelogOperations("- Archived: 2 件（ACE-1-1, ACE-2-1）を撤去\n");
    expect(archived.archivedIds).toEqual([]);
    expect(archived.malformedParentheticalIds).toEqual([
      "- Archived: 2 件（ACE-1-1, ACE-2-1）を撤去",
    ]);

    const promoted = parseChangelogOperations("- Promoted: 2 件（ACE-1-1, ACE-2-1）を昇格\n");
    expect(promoted.promotedIds).toEqual([]);
    expect(promoted.malformedParentheticalIds).toEqual([
      "- Promoted: 2 件（ACE-1-1, ACE-2-1）を昇格",
    ]);

    const merged = parseChangelogOperations("- Merged: 2 件（ACE-1-1, ACE-2-1）を統合\n");
    expect(merged.mergedPairs).toEqual([]);
    expect(merged.malformedMerged).toEqual([]);
    expect(merged.malformedParentheticalIds).toEqual([
      "- Merged: 2 件（ACE-1-1, ACE-2-1）を統合",
    ]);

    const violations = evaluateRefineInvariants({
      playbookContent: `${PLAYBOOK_CHANGELOG}- Compacted: 3 件（ACE-1-1, ACE-2-1, ACE-3-1）をまとめて圧縮\n`,
      liveBlocks: [...blocksOf(LIVE_CANONICAL), ...blocksOf(LIVE_TARGET)],
      archiveBlocks: [...blocksOf(ARCHIVE_VARIANT_B), ...blocksOf(ARCHIVE_MERGED)],
      patternsContent: PATTERNS_LISTED,
    });
    expect(violations.some((v) => v.includes("ID が括弧の中の列挙にしかない"))).toBe(true);
  });

  // 括弧の中身が散文の注記（無操作宣言の理由）は従来どおり無視し続ける。
  // 判別は「中身が ID の列挙だけか」で行い、`なし` のような語はハードコードしない。
  it("無操作宣言の注記に ID が現れる行は引き続き無視する", () => {
    const withoutId = parseChangelogOperations("- Archived: なし（ACE-X は次回再評価）\n");
    expect(withoutId.archivedIds).toEqual([]);
    expect(withoutId.malformedParentheticalIds).toEqual([]);
    const withId = parseChangelogOperations("- Archived: なし（ACE-9-9 は次回再評価）\n");
    expect(withId.archivedIds).toEqual([]);
    expect(withId.malformedParentheticalIds).toEqual([]);
    expect(withId.malformedArchived).toEqual([]);
    const promoted = parseChangelogOperations(
      "- Promoted: なし（Helpful>=5 の ACE-9-9 は PATTERNS.md へ収載済みで冪等スキップ）\n",
    );
    expect(promoted.promotedIds).toEqual([]);
    expect(promoted.malformedParentheticalIds).toEqual([]);
  });

  // 判定軸は「ID を除いた残りに文字が無いか」なので、区切りが `,` / `、` 以外でも、
  // 括弧が入れ子でも同じ 1 つの判定で拾う。
  it("括弧内の ID 列挙は区切りが / でも入れ子でも malformed として拒否する", () => {
    const nested = parseChangelogOperations("- Compacted: 2 件（（ACE-1-1, ACE-2-1））を圧縮\n");
    expect(nested.compactedIds).toEqual([]);
    expect(nested.malformedParentheticalIds).toEqual([
      "- Compacted: 2 件（（ACE-1-1, ACE-2-1））を圧縮",
    ]);

    const slashSeparated = parseChangelogOperations("- Archived: 2 件（ACE-1-1 / ACE-2-1）を撤去\n");
    expect(slashSeparated.archivedIds).toEqual([]);
    expect(slashSeparated.malformedParentheticalIds).toEqual([
      "- Archived: 2 件（ACE-1-1 / ACE-2-1）を撤去",
    ]);
  });

  // 無操作を宣言していても、括弧の中が ID の列挙だけなら「理由の散文」ではないので違反。
  it("無操作宣言でも括弧の中が ID の列挙だけなら malformed として拒否する", () => {
    const ops = parseChangelogOperations("- Promoted: なし（ACE-1-1, ACE-2-1）\n");
    expect(ops.promotedIds).toEqual([]);
    expect(ops.malformedParentheticalIds).toEqual(["- Promoted: なし（ACE-1-1, ACE-2-1）"]);
  });

  it("括弧の対応種が食い違う Promoted / Merged 行も malformed として拒否する", () => {
    const promoted = parseChangelogOperations("- Promoted: ACE-1-1（注記)\n");
    expect(promoted.promotedIds).toEqual([]);
    expect(promoted.malformedParenthesisKind).toEqual(["- Promoted: ACE-1-1（注記)"]);

    const merged = parseChangelogOperations("- Merged: ACE-1-1 → ACE-2-1(注記）\n");
    expect(merged.mergedPairs).toEqual([]);
    expect(merged.malformedParenthesisKind).toEqual(["- Merged: ACE-1-1 → ACE-2-1(注記）"]);
  });

  // 全角括弧書きの中に半角の閉じだけが現れる書き方（`a) b)` の箇条・顔文字）は、
  // 全角の開閉差が 0 で種類をまたいだ対応ではないため対応種違反にしない。
  it("全角括弧書きの中の孤立した半角閉じは対応種違反にしない", () => {
    const archived = parseChangelogOperations("- Archived: ACE-1-1（理由: a) 速い）\n");
    expect(archived.malformedParenthesisKind).toEqual([]);
    expect(archived.malformedArchived).toEqual([]);
    expect(archived.archivedIds).toEqual(["ACE-1-1"]);

    const merged = parseChangelogOperations("- Merged: ACE-1-1 → ACE-2-1（理由 a) ）\n");
    expect(merged.malformedParenthesisKind).toEqual([]);
    expect(merged.malformedMerged).toEqual([]);
    expect(merged.mergedPairs).toEqual([{ source: "ACE-1-1", target: "ACE-2-1" }]);
  });

  // 対応相手の無い括弧は 4 ラベル共通の前提検査で拒否する。以前は `Compacted:` だけが直接見て、
  // `Archived:` / `Promoted:` は理由部経由、`Merged:` は括弧を一切見なかったため、
  // `- Merged: ACE-1-1 → ACE-2-1（注記` や `- Archived: なし（注記` が黙って無視されていた。
  it("括弧を閉じ忘れた行は 4 ラベルとも malformed として拒否する", () => {
    for (const open of ["（", "("]) {
      const compacted = parseChangelogOperations(`- Compacted: ACE-1-1${open}注記\n`);
      expect(compacted.compactedIds).toEqual([]);
      expect(compacted.malformedCompacted).toEqual([`- Compacted: ACE-1-1${open}注記`]);

      const archived = parseChangelogOperations(`- Archived: ACE-1-1${open}注記\n`);
      expect(archived.archivedIds).toEqual([]);
      expect(archived.malformedArchived).toEqual([`- Archived: ACE-1-1${open}注記`]);

      const promoted = parseChangelogOperations(`- Promoted: ACE-1-1${open}注記\n`);
      expect(promoted.promotedIds).toEqual([]);
      expect(promoted.malformedPromoted).toEqual([`- Promoted: ACE-1-1${open}注記`]);

      const merged = parseChangelogOperations(`- Merged: ACE-1-1 → ACE-2-1${open}注記\n`);
      expect(merged.mergedPairs).toEqual([]);
      expect(merged.malformedMerged).toEqual([`- Merged: ACE-1-1 → ACE-2-1${open}注記`]);
    }
  });

  // ID 列を持たない無操作宣言の行は、閉じ忘れがあっても以前は素通りしていた
  // （`Archived:` / `Promoted:` は理由部の走査に入らないため）。
  it("無操作宣言の行でも括弧を閉じ忘れていれば malformed として拒否する", () => {
    const archived = parseChangelogOperations("- Archived: なし（未閉じ\n");
    expect(archived.malformedArchived).toEqual(["- Archived: なし（未閉じ"]);

    const promoted = parseChangelogOperations("- Promoted: なし（未閉じ\n");
    expect(promoted.malformedPromoted).toEqual(["- Promoted: なし（未閉じ"]);
  });

  // 全角括弧書きの中の孤立した半角閉じは、対応種違反にしないのと同じ理由で
  // 「対応相手の無い括弧」としても違反にしない（4 ラベルで一貫させる）。
  it("全角括弧書きの中の孤立した半角閉じは 4 ラベルとも違反にしない", () => {
    const compacted = parseChangelogOperations(
      "- Compacted: ACE-1-1, ACE-2-1（理由: a) 速い）\n",
    );
    expect(compacted.compactedIds).toEqual(["ACE-1-1", "ACE-2-1"]);
    expect(compacted.malformedCompacted).toEqual([]);

    const archived = parseChangelogOperations("- Archived: ACE-1-1（理由: a) 速い）\n");
    expect(archived.archivedIds).toEqual(["ACE-1-1"]);
    expect(archived.malformedArchived).toEqual([]);

    const promoted = parseChangelogOperations("- Promoted: ACE-1-1（理由: a) 速い）\n");
    expect(promoted.promotedIds).toEqual(["ACE-1-1"]);
    expect(promoted.malformedPromoted).toEqual([]);

    const merged = parseChangelogOperations("- Merged: ACE-1-1 → ACE-2-1（理由: a) 速い）\n");
    expect(merged.mergedPairs).toEqual([{ source: "ACE-1-1", target: "ACE-2-1" }]);
    expect(merged.malformedMerged).toEqual([]);
  });
  // 半角の閉じ余りを許すのは**全角括弧書きの中**に限る。括弧書きの外の裸の `)` まで許すと、
  // 閉じ余りが注記の境界にならないまま前後の ID を偽 ID へ融合させる害が残る。
  it("全角括弧書きの外に現れた半角閉じの余りは 4 ラベルとも malformed として拒否する", () => {
    const compacted = parseChangelogOperations("- Compacted: ACE-1-1)\n");
    expect(compacted.compactedIds).toEqual([]);
    expect(compacted.malformedCompacted).toEqual(["- Compacted: ACE-1-1)"]);

    const archived = parseChangelogOperations("- Archived: ACE-1-1)\n");
    expect(archived.archivedIds).toEqual([]);
    expect(archived.malformedArchived).toEqual(["- Archived: ACE-1-1)"]);

    const promoted = parseChangelogOperations("- Promoted: ACE-1-1)\n");
    expect(promoted.promotedIds).toEqual([]);
    expect(promoted.malformedPromoted).toEqual(["- Promoted: ACE-1-1)"]);

    const merged = parseChangelogOperations("- Merged: ACE-1-1 → ACE-2-1)\n");
    expect(merged.mergedPairs).toEqual([]);
    expect(merged.malformedMerged).toEqual(["- Merged: ACE-1-1 → ACE-2-1)"]);
  });

  // 全角の閉じ括弧の余りは、対応する開きが無い時点で違反（前後の ID を融合させる）。
  it("全角の閉じ括弧の余りは 4 ラベルとも malformed として拒否する", () => {
    const compacted = parseChangelogOperations("- Compacted: ACE-1-1）ACE-2-1\n");
    expect(compacted.compactedIds).toEqual([]);
    expect(compacted.malformedCompacted).toEqual(["- Compacted: ACE-1-1）ACE-2-1"]);

    const archived = parseChangelogOperations("- Archived: ACE-1-1）ACE-2-1\n");
    expect(archived.archivedIds).toEqual([]);
    expect(archived.malformedArchived).toEqual(["- Archived: ACE-1-1）ACE-2-1"]);

    const promoted = parseChangelogOperations("- Promoted: ACE-1-1）ACE-2-1\n");
    expect(promoted.promotedIds).toEqual([]);
    expect(promoted.malformedPromoted).toEqual(["- Promoted: ACE-1-1）ACE-2-1"]);

    const merged = parseChangelogOperations("- Merged: ACE-1-1 → ACE-2-1）注記\n");
    expect(merged.mergedPairs).toEqual([]);
    expect(merged.malformedMerged).toEqual(["- Merged: ACE-1-1 → ACE-2-1）注記"]);
  });

  // `hasOnlyParentheticalIds` の内部ガードが「全角と半角を 1 本の深さで数える」旧述語のままだと、
  // 括弧の中にしか ID が無い行へ全角括弧書きの中の半角閉じ（`（笑 :-) ）`）が付いただけで
  // ガードが真になり、括弧内 ID 列挙の検査を素通りして操作 0 件・違反 0 件で黙って通る。
  it("全角括弧書きの中に半角閉じを含む行でも括弧内 ID 列挙は malformed として拒否する", () => {
    const compacted = parseChangelogOperations(
      "- Compacted: 3 件（ACE-1-1, ACE-2-1）をまとめて圧縮（笑 :-) ）\n",
    );
    expect(compacted.compactedIds).toEqual([]);
    expect(compacted.malformedParentheticalIds).toEqual([
      "- Compacted: 3 件（ACE-1-1, ACE-2-1）をまとめて圧縮（笑 :-) ）",
    ]);

    const promoted = parseChangelogOperations(
      "- Promoted: なし（ACE-1-1, ACE-2-1）（笑 :-) ）\n",
    );
    expect(promoted.promotedIds).toEqual([]);
    expect(promoted.malformedParentheticalIds).toEqual([
      "- Promoted: なし（ACE-1-1, ACE-2-1）（笑 :-) ）",
    ]);
  });

  // 同じ形で顔文字が括弧書きの外に出た場合は、裸の半角閉じ余りとして
  // ラベル別の malformed バケットが先に拾う（どちらの経路でも違反であることを固定する）。
  it("括弧内 ID 列挙の行に括弧書きの外の顔文字が付く形も malformed として拒否する", () => {
    const compacted = parseChangelogOperations(
      "- Compacted: 3 件（ACE-1-1, ACE-2-1）をまとめて圧縮 :-)\n",
    );
    expect(compacted.compactedIds).toEqual([]);
    expect(compacted.malformedCompacted).toEqual([
      "- Compacted: 3 件（ACE-1-1, ACE-2-1）をまとめて圧縮 :-)",
    ]);

    const promoted = parseChangelogOperations("- Promoted: なし（ACE-1-1, ACE-2-1） :-)\n");
    expect(promoted.promotedIds).toEqual([]);
    expect(promoted.malformedPromoted).toEqual(["- Promoted: なし（ACE-1-1, ACE-2-1） :-)"]);
  });
});
