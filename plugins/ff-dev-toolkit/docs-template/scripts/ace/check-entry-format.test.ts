import { afterEach, describe, expect, it, vi } from "vitest";
import {
  detectLegacyMarkers,
  main,
  parseAllowlist,
  splitEntries,
} from "./check-entry-format";
import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";

/** 旧テーブル形式のエントリ（メタ表ヘッダ + 区切り行 + Insight/Context/Action）。 */
function legacyEntry(id: string): string {
  return [
    `<a id="ace-${id.toLowerCase()}"></a>`,
    "",
    `### ACE-${id}: 旧形式のエントリ`,
    "",
    "| フィールド | 値      |",
    "| ---------- | ------- |",
    "| Category   | coding  |",
    "| Origin     | PR #1   |",
    "| Date       | 2026-01-01 |",
    "| Helpful    | 0       |",
    "| Harmful    | 0       |",
    "| Status     | active  |",
    "",
    "**Insight**: 旧形式の知見本文。",
    "",
    "**Context**: 適用条件。",
    "",
    "**Action**: 推奨アクション。",
    "",
    "---",
    "",
  ].join("\n");
}

/** メタ表だけ正準化され本文は Insight/Context/Action のまま残ったハイブリッド。 */
function hybridEntry(id: string): string {
  return [
    `<a id="ace-${id.toLowerCase()}"></a>`,
    "",
    `### ACE-${id}: メタ表のみ正準化されたエントリ`,
    "",
    "| Category | coding | Origin | PR #1 |",
    "| Date | 2026-01-01 |",
    "| Helpful | 0 | Harmful | 0 |",
    "| Status | active |",
    "",
    "**Insight**: 本文は逐語のまま。",
    "",
    "---",
    "",
  ].join("\n");
}

/** コンパクト正準フォーマットのエントリ。 */
function compactEntry(id: string): string {
  return [
    `<a id="ace-${id.toLowerCase()}"></a>`,
    "",
    `### ACE-${id}: 正準フォーマットのエントリ`,
    "",
    "| Category | coding | Origin | PR #1 |",
    "| Date | 2026-08-07 |",
    "| Helpful | 0 | Harmful | 0 |",
    "| Status | active |",
    "",
    "知見の本質を 1 文で述べる。適用条件を 1 文。推奨アクションで締める。",
    "",
    "---",
    "",
  ].join("\n");
}

const CATEGORY_HEADER = [
  "# PLAYBOOK — コーディング (coding)",
  "",
  "> **Parent**: [PLAYBOOK.md](../PLAYBOOK.md)",
  "",
  "---",
  "",
  "## エントリ一覧",
  "",
].join("\n");

describe("detectLegacyMarkers", () => {
  it("メタ表ヘッダ・区切り行・Insight ブロックをすべて検出する", () => {
    const markers = detectLegacyMarkers(legacyEntry("1-1"));
    expect(markers).toContain("field-table-header");
    expect(markers).toContain("table-separator");
    expect(markers).toContain("insight-block");
  });

  it("メタ表だけ正準化されたハイブリッドも Insight ブロックで検出する", () => {
    // live 実データに 4 件存在する（メタ表を正準へ再整形し本文は逐語同一のまま残したもの）。
    // 区切り行だけを主判定にすると、このハイブリッドが新規追記されても通ってしまう。
    const markers = detectLegacyMarkers(hybridEntry("1-2"));
    expect(markers).toEqual(["insight-block"]);
  });

  it("コンパクト正準フォーマットは 1 つも検出しない", () => {
    expect(detectLegacyMarkers(compactEntry("1-3"))).toEqual([]);
  });

  it("Context / Action だけが残っている場合も検出する", () => {
    const body = "| Category | coding |\n\n**Action**: 何かする。\n";
    expect(detectLegacyMarkers(body)).toEqual(["insight-block"]);
  });
});

describe("parseAllowlist", () => {
  it("1 行 1 ID を読み、コメント行・空行・前後空白を無視する", () => {
    const content = [
      "# 旧形式として読み取り互換で残すエントリ",
      "",
      "ACE-101-1",
      "  ACE-101-2  ",
      "# 途中コメント",
      "ACE-103-1",
      "",
    ].join("\n");

    expect(parseAllowlist(content)).toEqual(["ACE-101-1", "ACE-101-2", "ACE-103-1"]);
  });

  it("空ファイルは空配列（新規プロジェクトは strict 運用）", () => {
    expect(parseAllowlist("")).toEqual([]);
  });
});

describe("splitEntries", () => {
  it("エントリ見出しごとに ID と本文へ分割する", () => {
    const content = CATEGORY_HEADER + compactEntry("1-1") + legacyEntry("1-2");
    const entries = splitEntries(content);

    expect(entries.map((e) => e.id)).toEqual(["ACE-1-1", "ACE-1-2"]);
    expect(entries[1].body).toContain("**Insight**");
    // ヘッダは最初のエントリに混ざらない
    expect(entries[0].body).not.toContain("Parent");
  });

  it("HTML コメント内の見出しはエントリとして扱わない", () => {
    const content =
      CATEGORY_HEADER +
      "<!-- 追記例:\n### ACE-001: コメント内の偽エントリ\n\n| フィールド | 値 |\n| --- | --- |\n-->\n\n" +
      compactEntry("1-1");
    const entries = splitEntries(content);

    expect(entries.map((e) => e.id)).toEqual(["ACE-1-1"]);
  });

  it("プレースホルダ見出し（ACE-XXX）は数えない", () => {
    const content = CATEGORY_HEADER + "### ACE-XXX: [タイトル]\n\n| フィールド | 値 |\n| --- | --- |\n";
    expect(splitEntries(content)).toEqual([]);
  });
});

describe("main", () => {
  const originalArgv = process.argv;
  let tmpDir = "";

  afterEach(() => {
    process.argv = originalArgv;
    delete process.env.ACE_LEGACY_FORMAT_ALLOWLIST;
    vi.restoreAllMocks();
    if (tmpDir) {
      fs.rmSync(tmpDir, { recursive: true, force: true });
      tmpDir = "";
    }
  });

  function writeLayout(options: {
    readonly subfiles: Record<string, string>;
    readonly allowlist?: string;
    readonly archive?: Record<string, string>;
  }): string {
    tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), "ace-format-"));
    const playbookPath = path.join(tmpDir, "PLAYBOOK.md");
    fs.writeFileSync(playbookPath, "# 索引\n");
    const subDir = path.join(tmpDir, "playbook");
    fs.mkdirSync(subDir);
    for (const [name, content] of Object.entries(options.subfiles)) {
      fs.writeFileSync(path.join(subDir, name), content);
    }
    if (options.archive) {
      const archiveDir = path.join(subDir, "archive");
      fs.mkdirSync(archiveDir);
      for (const [name, content] of Object.entries(options.archive)) {
        fs.writeFileSync(path.join(archiveDir, name), content);
      }
    }
    if (options.allowlist !== undefined) {
      fs.writeFileSync(path.join(tmpDir, "legacy-format-allowlist.txt"), options.allowlist);
    }
    return playbookPath;
  }

  it("allowlist に無い旧形式エントリは exit 1 で ID を名指しする", () => {
    const playbookPath = writeLayout({
      subfiles: { "coding.md": CATEGORY_HEADER + compactEntry("1-1") + legacyEntry("9-9") },
      allowlist: "ACE-1-1\n",
    });
    process.argv = ["node", "check-entry-format.ts", playbookPath];
    vi.spyOn(console, "log").mockImplementation(() => {});
    const err = vi.spyOn(console, "error").mockImplementation(() => {});

    const code = main();

    expect(code).toBe(1);
    expect(err.mock.calls.flat().join("\n")).toContain("ACE-9-9");
  });

  it("allowlist に載っている旧形式エントリは緑のまま通る（読み取り互換の維持）", () => {
    const playbookPath = writeLayout({
      subfiles: { "coding.md": CATEGORY_HEADER + legacyEntry("101-1") + compactEntry("1-1") },
      allowlist: "# 既存の旧形式\nACE-101-1\n",
    });
    process.argv = ["node", "check-entry-format.ts", playbookPath];
    vi.spyOn(console, "log").mockImplementation(() => {});
    const err = vi.spyOn(console, "error").mockImplementation(() => {});

    const code = main();

    expect(code).toBe(0);
    expect(err.mock.calls.flat().join("\n")).not.toContain("ACE-101-1");
  });

  it("メタ表だけ正準化されたハイブリッドの新規追記も赤にする", () => {
    const playbookPath = writeLayout({
      subfiles: { "coding.md": CATEGORY_HEADER + hybridEntry("9-9") },
      allowlist: "",
    });
    process.argv = ["node", "check-entry-format.ts", playbookPath];
    vi.spyOn(console, "log").mockImplementation(() => {});
    const err = vi.spyOn(console, "error").mockImplementation(() => {});

    const code = main();

    expect(code).toBe(1);
    expect(err.mock.calls.flat().join("\n")).toContain("ACE-9-9");
  });

  it("allowlist ファイルが無ければ strict（旧形式は全て赤）", () => {
    const playbookPath = writeLayout({
      subfiles: { "coding.md": CATEGORY_HEADER + legacyEntry("101-1") },
    });
    process.argv = ["node", "check-entry-format.ts", playbookPath];
    vi.spyOn(console, "log").mockImplementation(() => {});
    const err = vi.spyOn(console, "error").mockImplementation(() => {});

    const code = main();

    expect(code).toBe(1);
    expect(err.mock.calls.flat().join("\n")).toContain("ACE-101-1");
  });

  it("playbook/archive/ 配下は走査しない（原文は verbatim 保全なので旧形式が正常）", () => {
    const playbookPath = writeLayout({
      subfiles: { "coding.md": CATEGORY_HEADER + compactEntry("1-1") },
      allowlist: "",
      archive: { "coding.md": CATEGORY_HEADER + legacyEntry("55-5") },
    });
    process.argv = ["node", "check-entry-format.ts", playbookPath];
    const log = vi.spyOn(console, "log").mockImplementation(() => {});
    const err = vi.spyOn(console, "error").mockImplementation(() => {});

    const code = main();

    expect(code).toBe(0);
    const output = log.mock.calls.flat().join("\n") + err.mock.calls.flat().join("\n");
    expect(output).not.toContain("ACE-55-5");
  });

  it("allowlist にあるが旧形式でなくなった ID は警告のみ（refine の正準化をブロックしない）", () => {
    const playbookPath = writeLayout({
      subfiles: { "coding.md": CATEGORY_HEADER + compactEntry("101-1") },
      allowlist: "ACE-101-1\n",
    });
    process.argv = ["node", "check-entry-format.ts", playbookPath];
    vi.spyOn(console, "log").mockImplementation(() => {});
    const warn = vi.spyOn(console, "warn").mockImplementation(() => {});

    const code = main();

    expect(code).toBe(0);
    expect(warn.mock.calls.flat().join("\n")).toContain("ACE-101-1");
  });

  it("旧形式が 1 件も無ければ exit 0", () => {
    const playbookPath = writeLayout({
      subfiles: { "coding.md": CATEGORY_HEADER + compactEntry("1-1") + compactEntry("1-2") },
      allowlist: "",
    });
    process.argv = ["node", "check-entry-format.ts", playbookPath];
    const log = vi.spyOn(console, "log").mockImplementation(() => {});
    vi.spyOn(console, "error").mockImplementation(() => {});

    const code = main();

    expect(code).toBe(0);
    expect(log.mock.calls.flat().join("\n")).toContain("旧テーブル形式の新規追記はありません");
  });

  it("ACE_LEGACY_FORMAT_ALLOWLIST で allowlist のパスを上書きできる", () => {
    const playbookPath = writeLayout({
      subfiles: { "coding.md": CATEGORY_HEADER + legacyEntry("101-1") },
    });
    const custom = path.join(tmpDir, "custom-allowlist.txt");
    fs.writeFileSync(custom, "ACE-101-1\n");
    process.env.ACE_LEGACY_FORMAT_ALLOWLIST = custom;
    process.argv = ["node", "check-entry-format.ts", playbookPath];
    vi.spyOn(console, "log").mockImplementation(() => {});
    vi.spyOn(console, "error").mockImplementation(() => {});

    expect(main()).toBe(0);
  });

  it("引数も ACE_PLAYBOOK_PATH も無ければ usage error（exit 2）", () => {
    process.argv = ["node", "check-entry-format.ts"];
    const originalEnv = process.env.ACE_PLAYBOOK_PATH;
    delete process.env.ACE_PLAYBOOK_PATH;
    vi.spyOn(console, "error").mockImplementation(() => {});

    const code = main();

    expect(code).toBe(2);
    if (originalEnv !== undefined) {
      process.env.ACE_PLAYBOOK_PATH = originalEnv;
    }
  });
});
