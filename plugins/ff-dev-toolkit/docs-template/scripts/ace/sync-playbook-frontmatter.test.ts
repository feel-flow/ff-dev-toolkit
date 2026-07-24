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
  extractLatestChangelogVersion,
  isDirectExecution,
  main,
  readField,
  replaceField,
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

describe("readField", () => {
  it("クォート付き・数値・配列を生値で取り出す", () => {
    const fm = 'title: "PLAYBOOK"\nace_entry_count: 123\ntags: [a, b]';
    expect(readField(fm, "title")).toBe("PLAYBOOK");
    expect(readField(fm, "ace_entry_count")).toBe("123");
    expect(readField(fm, "tags")).toBe("[a, b]");
  });

  it("存在しないキーは null", () => {
    expect(readField("title: x", "missing")).toBeNull();
  });
});

describe("replaceField", () => {
  it("クォートの有無を保って値だけ差し替える", () => {
    const fm = 'version: "1.0.0"\nace_entry_count: 5';
    expect(replaceField(fm, "version", "1.0.1")).toContain('version: "1.0.1"');
    expect(replaceField(fm, "ace_entry_count", "6")).toContain("ace_entry_count: 6");
  });

  it("単一引用符も保ち、YAML の単一引用符エスケープ規則に従う", () => {
    const fm = "updated: '2026-01-01'\nnote: 'old'";
    expect(replaceField(fm, "updated", "2026-07-20")).toContain("updated: '2026-07-20'");
    expect(replaceField(fm, "note", "Bob's note")).toContain("note: 'Bob''s note'");
  });

  it("差し替えても他フィールドは不変", () => {
    const fm = 'version: "1.0.0"\nace_entry_count: 5';
    const out = replaceField(fm, "ace_entry_count", "6");
    expect(out).toContain('version: "1.0.0"');
  });

  it("特殊文字を含む値でも壊れない（$& 等）", () => {
    const fm = "note: old";
    const out = replaceField(fm, "note", "a$&b");
    expect(out).toBe("note: a$&b");
  });

  it("存在しないキーは null", () => {
    expect(replaceField("a: 1", "b", "2")).toBeNull();
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

  it("最新の ### [x.y.z] を返す（先頭が最新）", () => {
    const md = `## Changelog\n\n### [1.60.0] - 2026-07-22\n\n#### 追加\n\n### [1.59.0] - 2026-07-20\n`;
    expect(extractLatestChangelogVersion(md)).toEqual({ kind: "found", version: "1.60.0" });
  });

  it("次の ## セクション以降の版見出しは拾わない（空 Changelog を found にしない）", () => {
    const md = `## Changelog\n\n（空）\n\n## 関連リソース\n\n### [9.9.9] - 2099-01-01\n`;
    expect(extractLatestChangelogVersion(md)).toEqual({ kind: "empty" });
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

  it("分割レイアウトでも総エントリ数 0 は check-category-size と同じく error", () => {
    const main = `---\nx: 1\n---\n索引のみ（エントリ無し）\n`;
    const emptySub = `# 空カテゴリ\nエントリ無し\n`;
    const r = countActualEntries(main, [emptySub]);
    expect(r.ok).toBe(false);
    if (r.ok === false) expect(r.message).toContain("ACE エントリ見出し");
  });
});

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

  it("Changelog が無い fixture では versionChangelogInSync は true（検証スキップ）", () => {
    const content = `---\nversion: "1.0.0"\nace_entry_count: 1\n---\n### ACE-1-1: a\n| Category | coding |\n`;
    const result = computeSync(content, 1, {});
    expect(result.kind).toBe("ok");
    if (result.kind === "ok") {
      expect(result.changelogVersion).toBeNull();
      expect(result.versionChangelogInSync).toBe(true);
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
    if (result.kind === "error") expect(result.message).toContain("updated");
  });

  it("bumpVersion で version が欠落していれば error（黙って未更新にしない）", () => {
    const content = `---\nace_entry_count: 1\nupdated: "2026-01-01"\n---\n### ACE-1-1: a\n| Category | coding |\n`;
    const result = computeSync(content, 1, { write: true, bumpVersion: true });
    expect(result.kind).toBe("error");
    if (result.kind === "error") expect(result.message).toContain("version");
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
      `---\nace_entry_count: 1\nupdated: "2026-01-01"\nversion: "1.0.0"\n---\n### ACE-1-1: a\n| Category | coding |\n### ACE-1-2: b\n| Category | coding |\n`,
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
      `---\nace_entry_count: 1\nupdated: "2026-01-01"\nversion: "1.0.0"\n---\n### ACE-1-1: a\n| Category | coding |\n`,
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
