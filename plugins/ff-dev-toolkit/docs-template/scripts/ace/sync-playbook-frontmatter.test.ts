import { afterEach, describe, expect, it } from "vitest";
import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";
import { pathToFileURL } from "node:url";
import {
  bumpMinor,
  bumpPatch,
  computeSync,
  countActualEntries,
  countTopLevelFieldOccurrences,
  extractLatestChangelogVersion,
  isDirectExecution,
  main,
  readTopLevelField,
  replaceTopLevelField,
  splitFrontmatter,
} from "./sync-playbook-frontmatter";

const createdDirs: string[] = [];
function tempDir(): string {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "ace-sync-"));
  createdDirs.push(dir);
  return dir;
}
afterEach(() => {
  for (const dir of createdDirs.splice(0)) {
    fs.rmSync(dir, { recursive: true, force: true });
  }
});

const SAMPLE_FM = `---
title: "PLAYBOOK"
version: "1.59.0"
ace_entry_count: 123
updated: "2026-07-19"
tags: [ace, playbook]
---

# 本文
### ACE-1-1: entry

| Category | coding |
`;

function withCapturedConsole(fn: () => number): { status: number; output: string } {
  const originalLog = console.log;
  const originalError = console.error;
  const lines: string[] = [];
  console.log = (...args: unknown[]) => lines.push(args.map(String).join(" "));
  console.error = (...args: unknown[]) => lines.push(args.map(String).join(" "));
  try {
    return { status: fn(), output: lines.join("\n") };
  } finally {
    console.log = originalLog;
    console.error = originalError;
  }
}

describe("splitFrontmatter", () => {
  it("frontmatter と本文を分離し、本文は閉じ '---' から始まる", () => {
    const split = splitFrontmatter(SAMPLE_FM);
    expect(split).not.toBeNull();
    expect(split?.frontmatter).toContain('title: "PLAYBOOK"');
    expect(split?.rest.startsWith("---")).toBe(true);
    expect(split?.rest).toContain("# 本文");
  });

  it("先頭が '---' でなければ null", () => {
    expect(splitFrontmatter("# no frontmatter\n")).toBeNull();
  });

  it("閉じ境界が無ければ null（壊れた frontmatter）", () => {
    expect(splitFrontmatter("---\ntitle: x\n本文\n")).toBeNull();
  });
});

describe("readTopLevelField", () => {
  it("クォート付き・数値・配列を生値で取り出す", () => {
    const fm = 'title: "PLAYBOOK"\nace_entry_count: 123\ntags: [a, b]';
    expect(readTopLevelField(fm, "title")).toBe("PLAYBOOK");
    expect(readTopLevelField(fm, "ace_entry_count")).toBe("123");
    expect(readTopLevelField(fm, "tags")).toBe("[a, b]");
  });

  it("存在しないキーは null", () => {
    expect(readTopLevelField("title: x", "missing")).toBeNull();
  });

  it("metadata 配下にネストされたキーはトップレベルとして読まない（fail-open 防止）", () => {
    const fm = 'title: "PLAYBOOK"\nmetadata:\n  version: "1.0.0"\n  ace_entry_count: 1';
    expect(readTopLevelField(fm, "version")).toBeNull();
    expect(readTopLevelField(fm, "ace_entry_count")).toBeNull();
  });
});

describe("countTopLevelFieldOccurrences", () => {
  it("トップレベルの出現回数だけを数える（ネストは数えない）", () => {
    const fm = 'version: "1.0.0"\nmetadata:\n  version: "9.9.9"';
    expect(countTopLevelFieldOccurrences(fm, "version")).toBe(1);
  });

  it("トップレベルの重複は 2 以上として返す", () => {
    expect(countTopLevelFieldOccurrences('version: "1.0.0"\nversion: "2.0.0"', "version")).toBe(2);
  });

  it("存在しなければ 0", () => {
    expect(countTopLevelFieldOccurrences("title: x", "version")).toBe(0);
  });

  it("前方一致する別キーは数えない", () => {
    expect(countTopLevelFieldOccurrences("ace_entry_count_note: x", "ace_entry_count")).toBe(0);
  });
});

describe("replaceTopLevelField", () => {
  it("クォートの有無を保って値だけ差し替える", () => {
    const fm = 'version: "1.0.0"\nace_entry_count: 5';
    expect(replaceTopLevelField(fm, "version", "1.0.1")).toContain('version: "1.0.1"');
    expect(replaceTopLevelField(fm, "ace_entry_count", "6")).toContain("ace_entry_count: 6");
  });

  it("単一引用符も保ち、YAML の単一引用符エスケープ規則に従う", () => {
    const fm = "updated: '2026-01-01'\nnote: 'old'";
    expect(replaceTopLevelField(fm, "updated", "2026-07-20")).toContain("updated: '2026-07-20'");
    expect(replaceTopLevelField(fm, "note", "Bob's note")).toContain("note: 'Bob''s note'");
  });

  it("差し替えても他フィールドは不変", () => {
    const fm = 'version: "1.0.0"\nace_entry_count: 5';
    const out = replaceTopLevelField(fm, "ace_entry_count", "6");
    expect(out).toContain('version: "1.0.0"');
  });

  it("特殊文字を含む値でも壊れない（$& 等）", () => {
    const fm = "note: old";
    const out = replaceTopLevelField(fm, "note", "a$&b");
    expect(out).toBe("note: a$&b");
  });

  it("存在しないキーは null", () => {
    expect(replaceTopLevelField("a: 1", "b", "2")).toBeNull();
  });

  it("ネストされた同名キーしか無ければ null（ネスト側を書き換えない）", () => {
    const fm = 'title: "PLAYBOOK"\nmetadata:\n  version: "1.0.0"';
    expect(replaceTopLevelField(fm, "version", "1.1.0")).toBeNull();
  });
});

describe("bumpPatch", () => {
  it("patch を +1 する", () => {
    expect(bumpPatch("1.59.0")).toBe("1.59.1");
    expect(bumpPatch("0.0.9")).toBe("0.0.10");
  });

  it("semver でなければ null", () => {
    expect(bumpPatch("1.2")).toBeNull();
    expect(bumpPatch("1.2.x")).toBeNull();
    expect(bumpPatch("v1.2.3")).toBeNull();
  });
});

describe("bumpMinor", () => {
  it("minor を +1 し patch を 0 にする", () => {
    expect(bumpMinor("1.59.0")).toBe("1.60.0");
    expect(bumpMinor("1.59.1")).toBe("1.60.0");
    expect(bumpMinor("0.0.9")).toBe("0.1.0");
  });

  it("semver でなければ null", () => {
    expect(bumpMinor("1.2")).toBeNull();
    expect(bumpMinor("1.2.x")).toBeNull();
    expect(bumpMinor("v1.2.3")).toBeNull();
  });
});

describe("extractLatestChangelogVersion", () => {
  it("Changelog が無ければ absent", () => {
    expect(extractLatestChangelogVersion("# 本文\n### ACE-1: x\n")).toEqual({ kind: "absent" });
  });

  it("Changelog があるが版見出しが無ければ empty", () => {
    expect(extractLatestChangelogVersion("## Changelog\n\n（まだ無し）\n")).toEqual({ kind: "empty" });
  });

  it("最新の ### [x.y.z] を返す（先頭が最新）。count はセクション内の版見出し総数", () => {
    const md = `## Changelog\n\n### [1.60.0] - 2026-07-22\n\n#### 追加\n\n### [1.59.0] - 2026-07-20\n`;
    expect(extractLatestChangelogVersion(md)).toEqual({ kind: "found", version: "1.60.0", count: 2 });
  });

  it("版見出しが 1 件（初版のみ）なら count=1", () => {
    const md = `## Changelog\n\n### [1.0.0] - 2026-01-01\n`;
    expect(extractLatestChangelogVersion(md)).toEqual({ kind: "found", version: "1.0.0", count: 1 });
  });

  it("次の ## セクション以降の版見出しは拾わない（空 Changelog を found にしない）", () => {
    const md = `## Changelog\n\n（空）\n\n## 関連リソース\n\n### [9.9.9] - 2099-01-01\n`;
    expect(extractLatestChangelogVersion(md)).toEqual({ kind: "empty" });
  });

  it("count も次の ## セクション以降の版見出しを数えない", () => {
    const md = `## Changelog\n\n### [1.1.0] - 2026-02-01\n\n## 関連リソース\n\n### [9.9.9] - 2099-01-01\n`;
    expect(extractLatestChangelogVersion(md)).toEqual({ kind: "found", version: "1.1.0", count: 1 });
  });
});

describe("countActualEntries", () => {
  it("本文のエントリ見出しを数える", () => {
    const md = `---\nx: 1\n---\n### ACE-1-1: a\n| Category | coding |\n### ACE-1-2: b\n| Category | process |\n`;
    const r = countActualEntries(md, []);
    expect(r.ok).toBe(true);
    if (r.ok) expect(r.total).toBe(2);
  });

  it("分割ファイルの件数も合算する", () => {
    const main = `---\nx: 1\n---\n索引のみ（エントリ無し）\n`;
    const sub = `### ACE-2-1: a\n| Category | coding |\n`;
    const r = countActualEntries(main, [sub]);
    expect(r.ok).toBe(true);
    if (r.ok) expect(r.total).toBe(1);
  });

  it("旧テーブル形式とコンパクト正準フォーマット（1.62.0）の混在も正しく数える", () => {
    const main = `---\nx: 1\n---\n索引のみ（エントリ無し）\n`;
    const oldFormat = `### ACE-2-1: 旧形式\n\n| フィールド | 値 |\n| Category | coding |\n| Helpful | 0 |\n`;
    const compact = `### ACE-24-1: 新形式\n\n| Category | coding | Origin | PR #24 |\n| Date | 2026-07-31 |\n| Helpful | 0 | Harmful | 0 |\n| Status | active |\n\n本文。\n\n---\n`;
    const r = countActualEntries(main, [oldFormat, compact]);
    expect(r.ok).toBe(true);
    if (r.ok) expect(r.total).toBe(2);
  });

  it("分割レイアウトでも総エントリ数 0 は check-category-size と同じく error", () => {
    const main = `---\nx: 1\n---\n索引のみ（エントリ無し）\n`;
    const emptySub = `# 空カテゴリ\nエントリ無し\n`;
    const r = countActualEntries(main, [emptySub]);
    expect(r.ok).toBe(false);
    if (r.ok === false) expect(r.message).toContain("ACE エントリ見出し");
  });
});

/**
 * 重複キー検査用の fixture。それ以外は完全に健全な PLAYBOOK に、指定した
 * トップレベル行を 1 本だけ足して重複させる。
 */
function duplicatedFieldFixture(duplicateLine: string): string {
  return (
    `---\ntitle: "T"\nversion: "1.0.0"\ncreated: "2026-01-01"\nupdated: "2026-01-01"\n` +
    `changeImpact: medium\nace_entry_count: 1\n${duplicateLine}\n---\n` +
    `### ACE-1-1: a\n| Category | coding |\n\n## Changelog\n\n### [1.0.0] - 2026-01-01\n`
  );
}

/**
 * 管理対象 5 フィールドすべてで重複を拒否する（1 つだけ守られている状態を作らない）。
 * computeSync 層と CLI 層の両方から同じ表を回す。
 */
const MANAGED_FIELD_DUPLICATES = [
  { field: "ace_entry_count", duplicate: "ace_entry_count: 2" },
  { field: "version", duplicate: 'version: "9.9.9"' },
  { field: "created", duplicate: 'created: "2026-09-09"' },
  { field: "updated", duplicate: 'updated: "2026-09-09"' },
  { field: "changeImpact", duplicate: "changeImpact: high" },
] as const;

describe("computeSync (check)", () => {
  it("記録値と実数が一致していれば inSync=true / changes 空", () => {
    const content = `---\nace_entry_count: 2\n---\n### ACE-1-1: a\n| Category | coding |\n### ACE-1-2: b\n| Category | coding |\n`;
    const result = computeSync(content, 2, {});
    expect(result.kind).toBe("ok");
    if (result.kind === "ok") {
      expect(result.inSync).toBe(true);
      expect(result.changes).toHaveLength(0);
    }
  });

  it("ドリフトがあれば inSync=false かつ count 変更を提示（check でも content はあるべき姿）", () => {
    const content = `---\nace_entry_count: 1\n---\n### ACE-1-1: a\n| Category | coding |\n### ACE-1-2: b\n| Category | coding |\n`;
    const result = computeSync(content, 2, {});
    expect(result.kind).toBe("ok");
    if (result.kind === "ok") {
      expect(result.inSync).toBe(false);
      expect(result.changes).toContainEqual({ field: "ace_entry_count", from: "1", to: "2" });
      expect(result.content).toContain("ace_entry_count: 2");
    }
  });

  it("ace_entry_count が存在しても非数値なら欠落扱いではなく実数への補正候補として扱う", () => {
    const content = `---\nace_entry_count: many\n---\n### ACE-1-1: a\n| Category | coding |\n### ACE-1-2: b\n| Category | coding |\n`;
    const result = computeSync(content, 2, {});
    expect(result.kind).toBe("ok");
    if (result.kind === "ok") {
      expect(result.recordedCount).toBeNull();
      expect(result.inSync).toBe(false);
      expect(result.changes).toContainEqual({ field: "ace_entry_count", from: "many", to: "2" });
      expect(result.content).toContain("ace_entry_count: 2");
    }
  });

  it("frontmatter が無ければ error", () => {
    const result = computeSync("# no fm\n", 1, {});
    expect(result.kind).toBe("error");
  });

  it("ace_entry_count フィールドが欠落していれば error", () => {
    const content = `---\ntitle: x\n---\n### ACE-1-1: a\n| Category | coding |\n`;
    const result = computeSync(content, 1, {});
    expect(result.kind).toBe("error");
  });

  it("ace_entry_count が metadata 配下にしか無ければ欠落として error（Issue #615）", () => {
    const content = `---\ntitle: x\nmetadata:\n  ace_entry_count: 1\n---\n### ACE-1-1: a\n| Category | coding |\n`;
    const result = computeSync(content, 1, {});
    expect(result.kind).toBe("error");
    if (result.kind === "error") {
      expect(result.message).toContain("ace_entry_count");
      // 「トップレベルを見ている」ことを診断が明示していないと、ネストした人が原因へ辿れない
      expect(result.message).toContain("トップレベル");
    }
  });

  it("version が metadata 配下にしか無ければトップレベル未記録として扱う（Issue #615）", () => {
    const content = `---\nace_entry_count: 1\nmetadata:\n  version: "1.0.0"\n---\n### ACE-1-1: a\n| Category | coding |\n\n## Changelog\n\n### [1.0.0] - 2026-08-20\n`;
    const result = computeSync(content, 1, {});
    expect(result.kind).toBe("ok");
    if (result.kind === "ok") {
      expect(result.frontmatterVersion).toBeNull();
      expect(result.versionChangelogInSync).toBe(false);
    }
  });

  for (const { field, duplicate } of MANAGED_FIELD_DUPLICATES) {
    it(`トップレベルの ${field} 重複は error（読んだ行と書く行がずれるため）`, () => {
      const content = duplicatedFieldFixture(duplicate);
      const result = computeSync(content, 1, {});
      expect(result.kind).toBe("error");
      if (result.kind === "error") {
        expect(result.message).toContain(field);
        expect(result.message).toContain("2 回");
      }
    });
  }
});

describe("computeSync (write)", () => {
  it("write 時は updated を指定日へ更新し、body は保持", () => {
    const content = `---\nace_entry_count: 1\nupdated: "2026-01-01"\n---\n### ACE-1-1: a\n| Category | coding |\n### ACE-1-2: b\n| Category | coding |\n`;
    const result = computeSync(content, 2, { write: true, updatedDate: "2026-07-20" });
    expect(result.kind).toBe("ok");
    if (result.kind === "ok") {
      expect(result.content).toContain("ace_entry_count: 2");
      expect(result.content).toContain('updated: "2026-07-20"');
      expect(result.content).toContain("### ACE-1-1: a");
    }
  });

  it("bumpVersion 併用で version が minor +1（patch は 0）される", () => {
    const content = `---\nversion: "1.59.0"\nace_entry_count: 1\nupdated: "2026-01-01"\n---\n### ACE-1-1: a\n| Category | coding |\n### ACE-1-2: b\n| Category | coding |\n`;
    const result = computeSync(content, 2, { write: true, bumpVersion: true, updatedDate: "2026-07-20" });
    expect(result.kind).toBe("ok");
    if (result.kind === "ok") {
      expect(result.content).toContain('version: "1.60.0"');
    }
  });

  it("bumpVersion は patch が非 0 でも minor +1 して patch を 0 にする", () => {
    const content = `---\nversion: "1.59.1"\nace_entry_count: 1\nupdated: "2026-01-01"\n---\n### ACE-1-1: a\n| Category | coding |\n`;
    const result = computeSync(content, 1, { write: true, bumpVersion: true, updatedDate: "2026-07-20" });
    expect(result.kind).toBe("ok");
    if (result.kind === "ok") {
      expect(result.content).toContain('version: "1.60.0"');
    }
  });

  it("Changelog セクションが無ければドリフト扱い（Issue #615: 消せば検証が消える fail-open を塞ぐ）", () => {
    const content = `---\nversion: "1.0.0"\nace_entry_count: 1\n---\n### ACE-1-1: a\n| Category | coding |\n`;
    const result = computeSync(content, 1, {});
    expect(result.kind).toBe("ok");
    if (result.kind === "ok") {
      expect(result.changelogState).toBe("absent");
      expect(result.changelogVersion).toBeNull();
      expect(result.versionChangelogInSync).toBe(false);
    }
  });

  it("allowMissingChangelog を渡した fixture でだけ Changelog 不在を許す（CLI からは到達しない）", () => {
    const content = `---\nversion: "1.0.0"\nace_entry_count: 1\n---\n### ACE-1-1: a\n| Category | coding |\n`;
    const result = computeSync(content, 1, { allowMissingChangelog: true });
    expect(result.kind).toBe("ok");
    if (result.kind === "ok") {
      expect(result.changelogState).toBe("absent");
      expect(result.versionChangelogInSync).toBe(true);
    }
  });

  it("Changelog はあるが版見出しが無い場合は allowMissingChangelog でも許さない", () => {
    const content = `---\nversion: "1.0.0"\nace_entry_count: 1\n---\n### ACE-1-1: a\n| Category | coding |\n\n## Changelog\n\n（まだ無し）\n`;
    const result = computeSync(content, 1, { allowMissingChangelog: true });
    expect(result.kind).toBe("ok");
    if (result.kind === "ok") {
      expect(result.changelogState).toBe("empty");
      expect(result.versionChangelogInSync).toBe(false);
    }
  });

  it("frontmatter version と Changelog 最新版が一致すれば versionChangelogInSync=true", () => {
    const content = `---\nversion: "1.60.0"\nace_entry_count: 1\n---\n### ACE-1-1: a\n| Category | coding |\n\n## Changelog\n\n### [1.60.0] - 2026-07-22\n`;
    const result = computeSync(content, 1, {});
    expect(result.kind).toBe("ok");
    if (result.kind === "ok") {
      expect(result.frontmatterVersion).toBe("1.60.0");
      expect(result.changelogVersion).toBe("1.60.0");
      expect(result.versionChangelogInSync).toBe(true);
    }
  });

  it("frontmatter version と Changelog 最新版が不一致なら versionChangelogInSync=false", () => {
    const content = `---\nversion: "1.60.0"\nace_entry_count: 1\n---\n### ACE-1-1: a\n| Category | coding |\n\n## Changelog\n\n### [1.59.0] - 2026-07-20\n`;
    const result = computeSync(content, 1, {});
    expect(result.kind).toBe("ok");
    if (result.kind === "ok") {
      expect(result.versionChangelogInSync).toBe(false);
      expect(result.changelogVersion).toBe("1.59.0");
    }
  });

  it("bumpVersion で version が semver でなければ error", () => {
    const content = `---\nversion: "latest"\nace_entry_count: 1\nupdated: "2026-01-01"\n---\n### ACE-1-1: a\n| Category | coding |\n### ACE-1-2: b\n| Category | coding |\n`;
    const result = computeSync(content, 2, { write: true, bumpVersion: true });
    expect(result.kind).toBe("error");
  });

  it("updatedDate が YYYY-MM-DD でなければ error（frontmatter を壊さない）", () => {
    const content = `---\nace_entry_count: 1\nupdated: "2026-01-01"\n---\n### ACE-1-1: a\n| Category | coding |\n`;
    const result = computeSync(content, 1, { write: true, updatedDate: "today" });
    expect(result.kind).toBe("error");
    if (result.kind === "error") expect(result.message).toContain("YYYY-MM-DD");
  });

  it("updatedDate が実在しない日付なら error", () => {
    const content = `---\nace_entry_count: 1\nupdated: "2026-01-01"\n---\n### ACE-1-1: a\n| Category | coding |\n`;
    const result = computeSync(content, 1, { write: true, updatedDate: "2026-02-31" });
    expect(result.kind).toBe("error");
    if (result.kind === "error") expect(result.message).toContain("YYYY-MM-DD");
  });

  it("write で updated が欠落していれば error（黙って未更新にしない）", () => {
    const content = `---\nace_entry_count: 1\n---\n### ACE-1-1: a\n| Category | coding |\n`;
    const result = computeSync(content, 1, { write: true });
    expect(result.kind).toBe("error");
    if (result.kind === "error") {
      expect(result.message).toContain("updated");
      expect(result.message).toContain("トップレベル");
    }
  });

  it("bumpVersion で version が欠落していれば error（黙って未更新にしない）", () => {
    const content = `---\nace_entry_count: 1\nupdated: "2026-01-01"\n---\n### ACE-1-1: a\n| Category | coding |\n`;
    const result = computeSync(content, 1, { write: true, bumpVersion: true });
    expect(result.kind).toBe("error");
    if (result.kind === "error") {
      expect(result.message).toContain("version");
      expect(result.message).toContain("トップレベル");
    }
  });

  it("round-trip: 変更対象フィールド以外は完全一致", () => {
    const content = SAMPLE_FM;
    const result = computeSync(content, 123, { write: true, updatedDate: "2026-07-19" });
    expect(result.kind).toBe("ok");
    if (result.kind === "ok") {
      // count は既に一致、updated も同日なので changes は空、content は原文と一致
      expect(result.changes).toHaveLength(0);
      expect(result.content).toBe(content);
    }
  });
});

describe("computeSync (changeImpact)", () => {
  const BODY = `
### ACE-1-1: entry

| Category | coding |
`;
  function fixtureWithFm(fmFields: string): string {
    return `---\n${fmFields}\n---\n${BODY}`;
  }

  it("変更済み（created ≠ updated）なのに changeImpact 欠落なら changeImpactValid=false", () => {
    const content = fixtureWithFm(
      `title: "PLAYBOOK"\nversion: "1.59.0"\nace_entry_count: 1\ncreated: "2026-07-07"\nupdated: "2026-07-19"`,
    );
    const result = computeSync(content, 1);
    expect(result.kind).toBe("ok");
    if (result.kind !== "ok") return;
    expect(result.changeImpactValue).toBeNull();
    expect(result.changeImpactValid).toBe(false);
  });

  it("created == updated でも Changelog に版見出しが 2 件以上あれば変更済み扱いで欠落を検出する", () => {
    const content =
      `---\ntitle: "PLAYBOOK"\nversion: "1.1.0"\nace_entry_count: 1\ncreated: "2026-07-07"\nupdated: "2026-07-07"\n---\n${BODY}\n## Changelog\n\n### [1.1.0] - 2026-07-07\n\n### [1.0.0] - 2026-07-01\n`;
    const result = computeSync(content, 1);
    expect(result.kind).toBe("ok");
    if (result.kind !== "ok") return;
    expect(result.changeImpactValue).toBeNull();
    expect(result.changeImpactValid).toBe(false);
  });

  it("初版（created == updated、Changelog 1 件以下）なら changeImpact 欠落でも指摘しない", () => {
    const content = fixtureWithFm(
      `title: "PLAYBOOK"\nversion: "1.0.0"\nace_entry_count: 1\ncreated: "2026-07-07"\nupdated: "2026-07-07"`,
    );
    const result = computeSync(content, 1);
    expect(result.kind).toBe("ok");
    if (result.kind !== "ok") return;
    expect(result.changeImpactValid).toBe(true);
  });

  it("created を持たない fixture（updated のみ・Changelog なし）では presence を要求しない（後方互換）", () => {
    const result = computeSync(SAMPLE_FM, 1);
    expect(result.kind).toBe("ok");
    if (result.kind !== "ok") return;
    expect(result.changeImpactValid).toBe(true);
  });

  it("小文字の low / medium / high は valid（クォート付きも生値で判定）", () => {
    for (const rendered of ["medium", '"low"', "'high'"]) {
      const content = fixtureWithFm(
        `title: "PLAYBOOK"\nversion: "1.59.0"\nace_entry_count: 1\ncreated: "2026-07-07"\nupdated: "2026-07-19"\nchangeImpact: ${rendered}`,
      );
      const result = computeSync(content, 1);
      expect(result.kind).toBe("ok");
      if (result.kind !== "ok") return;
      expect(result.changeImpactValid).toBe(true);
    }
  });

  it("大文字・混在（MEDIUM / Medium）や値域外は changeImpactValid=false", () => {
    for (const bad of ["MEDIUM", "Medium", "critical"]) {
      const content = fixtureWithFm(
        `title: "PLAYBOOK"\nversion: "1.59.0"\nace_entry_count: 1\ncreated: "2026-07-07"\nupdated: "2026-07-19"\nchangeImpact: ${bad}`,
      );
      const result = computeSync(content, 1);
      expect(result.kind).toBe("ok");
      if (result.kind !== "ok") return;
      expect(result.changeImpactValue).toBe(bad);
      expect(result.changeImpactValid).toBe(false);
    }
  });

  it("空値（changeImpact: のみ）は欠落扱いではなく値域違反として検出する", () => {
    const content = fixtureWithFm(
      `title: "PLAYBOOK"\nversion: "1.59.0"\nace_entry_count: 1\ncreated: "2026-07-07"\nupdated: "2026-07-19"\nchangeImpact:`,
    );
    const result = computeSync(content, 1);
    expect(result.kind).toBe("ok");
    if (result.kind !== "ok") return;
    expect(result.changeImpactValue).toBe("");
    expect(result.changeImpactValid).toBe(false);
  });

  it("metadata 配下にネストされた changeImpact はトップレベル記録として扱わない（fail-open 防止）", () => {
    const content = fixtureWithFm(
      `title: "PLAYBOOK"\nversion: "1.59.0"\nace_entry_count: 1\ncreated: "2026-07-07"\nupdated: "2026-07-19"\nmetadata:\n  changeImpact: medium`,
    );
    const result = computeSync(content, 1);
    expect(result.kind).toBe("ok");
    if (result.kind !== "ok") return;
    expect(result.changeImpactValue).toBeNull();
    expect(result.changeImpactValid).toBe(false);
  });

  it("フィールドが存在する場合は created == updated でも値域を検証する", () => {
    const content = fixtureWithFm(
      `title: "PLAYBOOK"\nversion: "1.0.0"\nace_entry_count: 1\ncreated: "2026-07-07"\nupdated: "2026-07-07"\nchangeImpact: HIGH`,
    );
    const result = computeSync(content, 1);
    expect(result.kind).toBe("ok");
    if (result.kind !== "ok") return;
    expect(result.changeImpactValid).toBe(false);
  });

  it("write で updated を動かして変更済みへ遷移したら changeImpact: medium を自動追記する", () => {
    const content = fixtureWithFm(
      `title: "PLAYBOOK"\nversion: "1.0.0"\nace_entry_count: 1\ncreated: "2026-01-01"\nupdated: "2026-01-01"`,
    );
    const result = computeSync(content, 1, { write: true, updatedDate: "2026-07-21" });
    expect(result.kind).toBe("ok");
    if (result.kind !== "ok") return;
    expect(result.changes).toContainEqual({ field: "changeImpact", from: null, to: "medium" });
    expect(result.changeImpactValue).toBe("medium");
    expect(result.changeImpactValid).toBe(true);
    // updated 行の直後へ追記される
    expect(result.content).toContain(`updated: "2026-07-21"\nchangeImpact: medium`);
  });

  it("write でも値域違反（MEDIUM 等）は自動修正せず violation のまま返す", () => {
    const content = fixtureWithFm(
      `title: "PLAYBOOK"\nversion: "1.0.0"\nace_entry_count: 1\ncreated: "2026-01-01"\nupdated: "2026-01-01"\nchangeImpact: MEDIUM`,
    );
    const result = computeSync(content, 1, { write: true, updatedDate: "2026-07-21" });
    expect(result.kind).toBe("ok");
    if (result.kind !== "ok") return;
    expect(result.changeImpactValue).toBe("MEDIUM");
    expect(result.changeImpactValid).toBe(false);
    expect(result.content).not.toContain("changeImpact: medium");
  });

  it("check モードでは自動追記しない（欠落は violation として返すのみ）", () => {
    const content = fixtureWithFm(
      `title: "PLAYBOOK"\nversion: "1.59.0"\nace_entry_count: 1\ncreated: "2026-07-07"\nupdated: "2026-07-19"`,
    );
    const result = computeSync(content, 1);
    expect(result.kind).toBe("ok");
    if (result.kind !== "ok") return;
    expect(result.changes).toEqual([]);
    expect(result.content).not.toContain("changeImpact");
  });
});

describe("main (CLI contract)", () => {
  it("パス引数なしなら usage error", () => {
    const { status, output } = withCapturedConsole(() => main(["node", "sync"]));
    expect(status).toBe(2);
    expect(output).toContain("PLAYBOOK.md");
  });

  it("--check はドリフト時に exit 1 でファイルを書き換えない", () => {
    const dir = tempDir();
    const playbook = path.join(dir, "PLAYBOOK.md");
    const content = `---\nace_entry_count: 1\nupdated: "2026-01-01"\nversion: "1.0.0"\n---\n### ACE-1-1: a\n| Category | coding |\n### ACE-1-2: b\n| Category | coding |\n`;
    fs.writeFileSync(playbook, content);

    const { status, output } = withCapturedConsole(() => main(["node", "sync", playbook, "--check"]));

    expect(status).toBe(1);
    expect(output).toContain("ドリフト");
    expect(fs.readFileSync(playbook, "utf8")).toBe(content);
  });

  it("--check は変更済みなのに changeImpact 欠落なら exit 1（ファイルは書き換えない）", () => {
    const dir = tempDir();
    const playbook = path.join(dir, "PLAYBOOK.md");
    const content = `---\nace_entry_count: 1\ncreated: "2026-01-01"\nupdated: "2026-02-01"\nversion: "1.1.0"\n---\n### ACE-1-1: a\n| Category | coding |\n`;
    fs.writeFileSync(playbook, content);

    const { status, output } = withCapturedConsole(() => main(["node", "sync", playbook, "--check"]));

    expect(status).toBe(1);
    expect(output).toContain("changeImpact が未記録");
    expect(fs.readFileSync(playbook, "utf8")).toBe(content);
  });

  it("--check は changeImpact が小文字値域内なら exit 0", () => {
    const dir = tempDir();
    const playbook = path.join(dir, "PLAYBOOK.md");
    const content = `---\nace_entry_count: 1\ncreated: "2026-01-01"\nupdated: "2026-02-01"\nversion: "1.1.0"\nchangeImpact: medium\n---\n### ACE-1-1: a\n| Category | coding |\n\n## Changelog\n\n### [1.1.0] - 2026-02-01\n`;
    fs.writeFileSync(playbook, content);

    const { status, output } = withCapturedConsole(() => main(["node", "sync", playbook, "--check"]));

    expect(status).toBe(0);
    expect(output).toContain("changeImpact は記録済み");
  });

  it("--write は変更済みへ遷移した文書へ changeImpact: medium を自動追記して exit 0", () => {
    const dir = tempDir();
    const playbook = path.join(dir, "PLAYBOOK.md");
    fs.writeFileSync(
      playbook,
      `---\nace_entry_count: 1\ncreated: "2026-01-01"\nupdated: "2026-01-01"\nversion: "1.0.0"\n---\n### ACE-1-1: a\n| Category | coding |\n### ACE-1-2: b\n| Category | coding |\n\n## Changelog\n\n### [1.0.0] - 2026-01-01\n`,
    );
    const previousDate = process.env.ACE_UPDATED_DATE;
    process.env.ACE_UPDATED_DATE = "2026-07-21";
    try {
      const { status, output } = withCapturedConsole(() => main(["node", "sync", playbook, "--write"]));
      expect(status).toBe(0);
      expect(output).toContain("changeImpact: なし → medium");
      const written = fs.readFileSync(playbook, "utf8");
      expect(written).toContain("ace_entry_count: 2");
      expect(written).toContain('updated: "2026-07-21"\nchangeImpact: medium');
    } finally {
      if (previousDate === undefined) delete process.env.ACE_UPDATED_DATE;
      else process.env.ACE_UPDATED_DATE = previousDate;
    }
  });

  it("--write は値域違反（MEDIUM 等）を自動修正せず、書き込み後も報告して exit 1", () => {
    const dir = tempDir();
    const playbook = path.join(dir, "PLAYBOOK.md");
    fs.writeFileSync(
      playbook,
      `---\nace_entry_count: 1\ncreated: "2026-01-01"\nupdated: "2026-01-01"\nversion: "1.0.0"\nchangeImpact: MEDIUM\n---\n### ACE-1-1: a\n| Category | coding |\n### ACE-1-2: b\n| Category | coding |\n`,
    );
    const previousDate = process.env.ACE_UPDATED_DATE;
    process.env.ACE_UPDATED_DATE = "2026-07-21";
    try {
      const { status, output } = withCapturedConsole(() => main(["node", "sync", playbook, "--write"]));
      expect(status).toBe(1);
      expect(output).toContain("無効な値");
      // count / updated の書き込み自体は行われている（違反報告と書き込みは独立）
      const written = fs.readFileSync(playbook, "utf8");
      expect(written).toContain("ace_entry_count: 2");
      expect(written).toContain("changeImpact: MEDIUM");
    } finally {
      if (previousDate === undefined) delete process.env.ACE_UPDATED_DATE;
      else process.env.ACE_UPDATED_DATE = previousDate;
    }
  });

  it("--write で更新不要でも changeImpact 値域違反なら「すべて最新」と言わず exit 1", () => {
    const dir = tempDir();
    const playbook = path.join(dir, "PLAYBOOK.md");
    const content = `---\nace_entry_count: 1\ncreated: "2026-01-01"\nupdated: "2026-07-21"\nversion: "1.0.0"\nchangeImpact: Medium\n---\n### ACE-1-1: a\n| Category | coding |\n`;
    fs.writeFileSync(playbook, content);
    const previousDate = process.env.ACE_UPDATED_DATE;
    process.env.ACE_UPDATED_DATE = "2026-07-21";
    try {
      const { status, output } = withCapturedConsole(() => main(["node", "sync", playbook, "--write"]));
      expect(status).toBe(1);
      expect(output).toContain("無効な値");
      expect(output).not.toContain("すべて最新");
      expect(fs.readFileSync(playbook, "utf8")).toBe(content);
    } finally {
      if (previousDate === undefined) delete process.env.ACE_UPDATED_DATE;
      else process.env.ACE_UPDATED_DATE = previousDate;
    }
  });

  it("--write --bump-version は changeImpact が正常値なら false positive を出さない（exit 0）", () => {
    const dir = tempDir();
    const playbook = path.join(dir, "PLAYBOOK.md");
    fs.writeFileSync(
      playbook,
      // Changelog は先に bump 後の版（1.2.0）を持つ運用（`/ace-curate` 4-d）を写す。
      `---\nace_entry_count: 1\ncreated: "2026-01-01"\nupdated: "2026-01-01"\nversion: "1.1.0"\nchangeImpact: medium\n---\n### ACE-1-1: a\n| Category | coding |\n\n## Changelog\n\n### [1.2.0] - 2026-07-21\n`,
    );
    const previousDate = process.env.ACE_UPDATED_DATE;
    process.env.ACE_UPDATED_DATE = "2026-07-21";
    try {
      const { status, output } = withCapturedConsole(() =>
        main(["node", "sync", playbook, "--write", "--bump-version"]),
      );
      expect(status).toBe(0);
      expect(output).not.toContain("changeImpact が未記録");
      expect(output).not.toContain("無効な値");
      const written = fs.readFileSync(playbook, "utf8");
      expect(written).toContain('version: "1.2.0"');
      expect(written).toContain("changeImpact: medium");
    } finally {
      if (previousDate === undefined) delete process.env.ACE_UPDATED_DATE;
      else process.env.ACE_UPDATED_DATE = previousDate;
    }
  });

  it("--bump-version を --write なしで渡したら usage error", () => {
    const dir = tempDir();
    const playbook = path.join(dir, "PLAYBOOK.md");
    const content = `---\nace_entry_count: 1\nupdated: "2026-01-01"\nversion: "1.0.0"\n---\n### ACE-1-1: a\n| Category | coding |\n`;
    fs.writeFileSync(playbook, content);

    const { status, output } = withCapturedConsole(() => main(["node", "sync", playbook, "--bump-version"]));

    expect(status).toBe(2);
    expect(output).toContain("--write");
    expect(fs.readFileSync(playbook, "utf8")).toBe(content);
  });

  it("未知フラグは check モードへフォールバックせず usage error", () => {
    const dir = tempDir();
    const playbook = path.join(dir, "PLAYBOOK.md");
    const content = `---\nace_entry_count: 1\nupdated: "2026-01-01"\nversion: "1.0.0"\n---\n### ACE-1-1: a\n| Category | coding |\n`;
    fs.writeFileSync(playbook, content);

    const { status, output } = withCapturedConsole(() => main(["node", "sync", playbook, "--wirte"]));

    expect(status).toBe(2);
    expect(output).toContain("未知のオプション");
    expect(fs.readFileSync(playbook, "utf8")).toBe(content);
  });

  it("--check と --write の同時指定は usage error", () => {
    const dir = tempDir();
    const playbook = path.join(dir, "PLAYBOOK.md");
    fs.writeFileSync(playbook, `---\nace_entry_count: 1\nupdated: "2026-01-01"\nversion: "1.0.0"\n---\n### ACE-1-1: a\n| Category | coding |\n`);

    const { status, output } = withCapturedConsole(() => main(["node", "sync", playbook, "--check", "--write"]));

    expect(status).toBe(2);
    expect(output).toContain("同時に指定できません");
  });

  it("--write は実ファイルの count と ACE_UPDATED_DATE を更新する", () => {
    const dir = tempDir();
    const playbook = path.join(dir, "PLAYBOOK.md");
    fs.writeFileSync(
      playbook,
      `---\nace_entry_count: 1\nupdated: "2026-01-01"\nversion: "1.0.0"\n---\n### ACE-1-1: a\n| Category | coding |\n### ACE-1-2: b\n| Category | coding |\n\n## Changelog\n\n### [1.0.0] - 2026-01-01\n`,
    );
    const previousDate = process.env.ACE_UPDATED_DATE;
    process.env.ACE_UPDATED_DATE = "2026-07-21";
    try {
      const { status, output } = withCapturedConsole(() => main(["node", "sync", playbook, "--write"]));
      expect(status).toBe(0);
      expect(output).toContain("frontmatter を更新");
      const written = fs.readFileSync(playbook, "utf8");
      expect(written).toContain("ace_entry_count: 2");
      expect(written).toContain('updated: "2026-07-21"');
    } finally {
      if (previousDate === undefined) delete process.env.ACE_UPDATED_DATE;
      else process.env.ACE_UPDATED_DATE = previousDate;
    }
  });

  it("ACE_UPDATED_DATE が不正形式なら usage error でファイルを書き換えない", () => {
    const dir = tempDir();
    const playbook = path.join(dir, "PLAYBOOK.md");
    const content = `---\nace_entry_count: 1\nupdated: "2026-01-01"\nversion: "1.0.0"\n---\n### ACE-1-1: a\n| Category | coding |\n`;
    fs.writeFileSync(playbook, content);
    const previousDate = process.env.ACE_UPDATED_DATE;
    process.env.ACE_UPDATED_DATE = "2026/07/21";
    try {
      const { status, output } = withCapturedConsole(() => main(["node", "sync", playbook, "--write"]));
      expect(status).toBe(2);
      expect(output).toContain("YYYY-MM-DD");
      expect(fs.readFileSync(playbook, "utf8")).toBe(content);
    } finally {
      if (previousDate === undefined) delete process.env.ACE_UPDATED_DATE;
      else process.env.ACE_UPDATED_DATE = previousDate;
    }
  });

  it("ACE_PLAYBOOK_PATH と --bump-version の経路を処理する（minor +1）", () => {
    const dir = tempDir();
    const playbook = path.join(dir, "PLAYBOOK.md");
    fs.writeFileSync(
      playbook,
      // bump 後の 1.1.0 が Changelog に既にある状態（Changelog 先行運用）。
      `---\nace_entry_count: 1\nupdated: "2026-01-01"\nversion: "1.0.0"\n---\n### ACE-1-1: a\n| Category | coding |\n\n## Changelog\n\n### [1.1.0] - 2026-07-21\n`,
    );
    const previousPath = process.env.ACE_PLAYBOOK_PATH;
    const previousDate = process.env.ACE_UPDATED_DATE;
    process.env.ACE_PLAYBOOK_PATH = playbook;
    process.env.ACE_UPDATED_DATE = "2026-07-21";
    try {
      const { status } = withCapturedConsole(() => main(["node", "sync", "--write", "--bump-version"]));
      expect(status).toBe(0);
      const written = fs.readFileSync(playbook, "utf8");
      expect(written).toContain('version: "1.1.0"');
      expect(written).toContain('updated: "2026-07-21"');
    } finally {
      if (previousPath === undefined) delete process.env.ACE_PLAYBOOK_PATH;
      else process.env.ACE_PLAYBOOK_PATH = previousPath;
      if (previousDate === undefined) delete process.env.ACE_UPDATED_DATE;
      else process.env.ACE_UPDATED_DATE = previousDate;
    }
  });

  it("--check は version と Changelog 不一致でも exit 1（count 一致でも）", () => {
    const dir = tempDir();
    const playbook = path.join(dir, "PLAYBOOK.md");
    const content = `---\nace_entry_count: 1\nupdated: "2026-01-01"\nversion: "1.60.0"\n---\n### ACE-1-1: a\n| Category | coding |\n\n## Changelog\n\n### [1.59.0] - 2026-07-20\n`;
    fs.writeFileSync(playbook, content);

    const { status, output } = withCapturedConsole(() => main(["node", "sync", playbook, "--check"]));

    expect(status).toBe(1);
    expect(output).toContain("Changelog");
    expect(fs.readFileSync(playbook, "utf8")).toBe(content);
  });

  it("--check は Changelog に版見出しが無いとき exit 1", () => {
    const dir = tempDir();
    const playbook = path.join(dir, "PLAYBOOK.md");
    const content = `---\nace_entry_count: 1\nupdated: "2026-01-01"\nversion: "1.0.0"\n---\n### ACE-1-1: a\n| Category | coding |\n\n## Changelog\n\n（まだ無し）\n`;
    fs.writeFileSync(playbook, content);

    const { status, output } = withCapturedConsole(() => main(["node", "sync", playbook, "--check"]));

    expect(status).toBe(1);
    expect(output).toContain("版見出しなし");
  });

  // Issue #615 の再現 fixture（報告本文の frontmatter / 本文をそのまま写す）。
  const ISSUE_615_BODY = `
# T

<a id="ace-1-1"></a>

### ACE-1-1: サンプル

| フィールド | 値      |
| ---------- | ------- |
| Category   | process |
| Origin     | PR feel-flow/ff-dev-toolkit#1   |
| Date       | 2026-08-20 |
| Helpful    | 0       |
| Harmful    | 0       |
| Status     | active  |

**Insight**: x
`;

  it("--check は ## Changelog セクションごと消えていれば exit 1（Issue #615 再現 1）", () => {
    const dir = tempDir();
    const playbook = path.join(dir, "PLAYBOOK.md");
    const content = `---\ntitle: "T"\nversion: "1.0.0"\ncreated: "2026-08-01"\nupdated: "2026-08-20"\nchangeImpact: "medium"\nace_entry_count: 1\n---\n${ISSUE_615_BODY}`;
    fs.writeFileSync(playbook, content);

    const { status, output } = withCapturedConsole(() => main(["node", "sync", playbook, "--check"]));

    expect(status).toBe(1);
    expect(output).toContain("`## Changelog` セクションがありません");
    // 受理する見出し表記（レベル 2・大小文字一致）を診断が明示する
    expect(output).toContain("レベル 2");
    expect(fs.readFileSync(playbook, "utf8")).toBe(content);
  });

  it("--allow-missing-changelog は CLI から渡せない（fixture 用の緩和を本番経路へ漏らさない）", () => {
    const dir = tempDir();
    const playbook = path.join(dir, "PLAYBOOK.md");
    const content = `---\nace_entry_count: 1\nupdated: "2026-01-01"\nversion: "1.0.0"\n---\n### ACE-1-1: a\n| Category | coding |\n`;
    fs.writeFileSync(playbook, content);

    const { status, output } = withCapturedConsole(() =>
      main(["node", "sync", playbook, "--check", "--allow-missing-changelog"]),
    );

    expect(status).toBe(2);
    expect(output).toContain("未知のオプション");
    expect(output).toContain("--allow-missing-changelog");
    expect(fs.readFileSync(playbook, "utf8")).toBe(content);
  });

  for (const { field, duplicate } of MANAGED_FIELD_DUPLICATES) {
    it(`--write は ${field} がトップレベルで重複していれば usage error でファイルを書き換えない`, () => {
      const dir = tempDir();
      const playbook = path.join(dir, "PLAYBOOK.md");
      const content = duplicatedFieldFixture(duplicate);
      fs.writeFileSync(playbook, content);
      const previousDate = process.env.ACE_UPDATED_DATE;
      process.env.ACE_UPDATED_DATE = "2026-07-21";
      try {
        const { status, output } = withCapturedConsole(() => main(["node", "sync", playbook, "--write"]));
        expect(status).toBe(2);
        expect(output).toContain(field);
        expect(fs.readFileSync(playbook, "utf8")).toBe(content);
      } finally {
        if (previousDate === undefined) delete process.env.ACE_UPDATED_DATE;
        else process.env.ACE_UPDATED_DATE = previousDate;
      }
    });
  }

  it("--check は version だけ metadata 配下にあるとき exit 1（ファイルは書き換えない）", () => {
    const dir = tempDir();
    const playbook = path.join(dir, "PLAYBOOK.md");
    const content = `---\nace_entry_count: 1\nupdated: "2026-01-01"\nmetadata:\n  version: "1.0.0"\n---\n### ACE-1-1: a\n| Category | coding |\n\n## Changelog\n\n### [1.0.0] - 2026-01-01\n`;
    fs.writeFileSync(playbook, content);

    const { status, output } = withCapturedConsole(() => main(["node", "sync", playbook, "--check"]));

    expect(status).toBe(1);
    expect(output).toContain("frontmatter=なし");
    expect(output).toContain("frontmatter なし ≠ Changelog 1.0.0");
    expect(fs.readFileSync(playbook, "utf8")).toBe(content);
  });

  it("--check は version / ace_entry_count が metadata 配下にしか無ければ非 0（Issue #615 再現 2）", () => {
    const dir = tempDir();
    const playbook = path.join(dir, "PLAYBOOK.md");
    const content = `---\ntitle: "T"\ncreated: "2026-08-01"\nupdated: "2026-08-20"\nchangeImpact: "medium"\nmetadata:\n  version: "1.0.0"\n  ace_entry_count: 1\n---\n${ISSUE_615_BODY}`;
    fs.writeFileSync(playbook, content);

    const { status, output } = withCapturedConsole(() => main(["node", "sync", playbook, "--check"]));

    // トップレベルに ace_entry_count が無い = 壊れた frontmatter なので usage error 側で止める
    expect(status).toBe(2);
    expect(output).toContain("ace_entry_count");
    expect(output).toContain("トップレベル");
    expect(fs.readFileSync(playbook, "utf8")).toBe(content);
  });

  it("--write は metadata 配下へネストされた値を書き換えない（Issue #615 再現 2 の未検証部分）", () => {
    const dir = tempDir();
    const playbook = path.join(dir, "PLAYBOOK.md");
    const content = `---\ntitle: "T"\ncreated: "2026-08-01"\nupdated: "2026-08-20"\nchangeImpact: "medium"\nmetadata:\n  version: "1.0.0"\n  ace_entry_count: 1\n---\n${ISSUE_615_BODY}`;
    fs.writeFileSync(playbook, content);
    const previousDate = process.env.ACE_UPDATED_DATE;
    process.env.ACE_UPDATED_DATE = "2026-08-21";
    try {
      const { status } = withCapturedConsole(() => main(["node", "sync", playbook, "--write"]));
      expect(status).toBe(2);
      expect(fs.readFileSync(playbook, "utf8")).toBe(content);
    } finally {
      if (previousDate === undefined) delete process.env.ACE_UPDATED_DATE;
      else process.env.ACE_UPDATED_DATE = previousDate;
    }
  });

  it("--write は count 一致でも version desync なら「すべて最新」と言わず exit 1", () => {
    const dir = tempDir();
    const playbook = path.join(dir, "PLAYBOOK.md");
    const content = `---\nace_entry_count: 1\nupdated: "2026-07-21"\nversion: "1.60.0"\n---\n### ACE-1-1: a\n| Category | coding |\n\n## Changelog\n\n### [1.59.0] - 2026-07-20\n`;
    fs.writeFileSync(playbook, content);
    const previousDate = process.env.ACE_UPDATED_DATE;
    process.env.ACE_UPDATED_DATE = "2026-07-21";
    try {
      const { status, output } = withCapturedConsole(() => main(["node", "sync", playbook, "--write"]));
      expect(status).toBe(1);
      expect(output).not.toContain("すべて最新");
      expect(output).toContain("Changelog");
      expect(fs.readFileSync(playbook, "utf8")).toBe(content);
    } finally {
      if (previousDate === undefined) delete process.env.ACE_UPDATED_DATE;
      else process.env.ACE_UPDATED_DATE = previousDate;
    }
  });

  it("--write --bump-version 後は Changelog リマインダを出し desync なら exit 1", () => {
    const dir = tempDir();
    const playbook = path.join(dir, "PLAYBOOK.md");
    fs.writeFileSync(
      playbook,
      `---\nace_entry_count: 1\nupdated: "2026-01-01"\nversion: "1.0.0"\n---\n### ACE-1-1: a\n| Category | coding |\n\n## Changelog\n\n### [1.0.0] - 2026-01-01\n`,
    );
    const previousDate = process.env.ACE_UPDATED_DATE;
    process.env.ACE_UPDATED_DATE = "2026-07-21";
    try {
      const { status, output } = withCapturedConsole(() =>
        main(["node", "sync", playbook, "--write", "--bump-version"]),
      );
      expect(status).toBe(1);
      expect(output).toContain("minor+1");
      expect(output).toContain("Changelog");
      const written = fs.readFileSync(playbook, "utf8");
      expect(written).toContain('version: "1.1.0"');
    } finally {
      if (previousDate === undefined) delete process.env.ACE_UPDATED_DATE;
      else process.env.ACE_UPDATED_DATE = previousDate;
    }
  });

  it("CLI でも playbook/ 分割ファイルを合算する", () => {
    const dir = tempDir();
    const playbook = path.join(dir, "PLAYBOOK.md");
    const subDir = path.join(dir, "playbook");
    fs.mkdirSync(subDir);
    fs.writeFileSync(playbook, `---\nace_entry_count: 1\nupdated: "2026-01-01"\nversion: "1.0.0"\n---\n索引のみ\n`);
    fs.writeFileSync(path.join(subDir, "coding.md"), `### ACE-2-1: b\n| Category | coding |\n`);
    fs.writeFileSync(path.join(subDir, "process.md"), `### ACE-2-2: c\n| Category | process |\n`);

    const { status, output } = withCapturedConsole(() => main(["node", "sync", playbook, "--check"]));

    expect(status).toBe(1);
    expect(output).toContain("実数 2");
  });

  it("CLI の playbook/ 分割ファイル総件数 0 は usage error", () => {
    const dir = tempDir();
    const playbook = path.join(dir, "PLAYBOOK.md");
    const subDir = path.join(dir, "playbook");
    fs.mkdirSync(subDir);
    fs.writeFileSync(playbook, `---\nace_entry_count: 0\nupdated: "2026-01-01"\nversion: "1.0.0"\n---\n索引のみ\n`);
    fs.writeFileSync(path.join(subDir, "empty.md"), `# 空\nエントリ無し\n`);

    const { status, output } = withCapturedConsole(() => main(["node", "sync", playbook, "--check"]));

    expect(status).toBe(2);
    expect(output).toContain("ACE エントリ見出し");
  });
});

describe("isDirectExecution", () => {
  it("完全一致する argv path だけを直接実行扱いする", () => {
    const scriptPath = path.join(tempDir(), "sync-playbook-frontmatter.ts");
    expect(isDirectExecution(pathToFileURL(scriptPath).href, scriptPath)).toBe(true);
  });

  it("ファイル名を含む別スクリプトの部分一致では直接実行扱いしない", () => {
    const dir = tempDir();
    const scriptPath = path.join(dir, "sync-playbook-frontmatter.ts");
    const wrapperPath = path.join(dir, "wrapper-sync-playbook-frontmatter.ts");
    expect(isDirectExecution(pathToFileURL(scriptPath).href, wrapperPath)).toBe(false);
  });

  it("argv path が無ければ直接実行扱いしない", () => {
    const scriptPath = path.join(tempDir(), "sync-playbook-frontmatter.ts");
    expect(isDirectExecution(pathToFileURL(scriptPath).href, undefined)).toBe(false);
  });
});
