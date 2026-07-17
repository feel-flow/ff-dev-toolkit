import { afterEach, describe, expect, it, vi } from "vitest";
import {
  analyzePlaybookMarkdown,
  countPlaybookLines,
  discoverPlaybookSubfiles,
  isOverLineThreshold,
  main,
  mergeAnalyses,
  parsePositiveIntEnv,
} from "./check-category-size";
import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";

describe("analyzePlaybookMarkdown", () => {
  it("HTML コメント内の ACE 見出しは無視し、実エントリのみ数える", () => {
    const md = `
<!-- 追記例:
### ACE-001: コメント内の偽エントリ

| フィールド | 値 |
| Category | security |
-->

### ACE-001: 実エントリ

| フィールド | 値 |
| Category | coding |
| Origin | PR #1 |
`;

    const result = analyzePlaybookMarkdown(md);
    expect(result.kind).toBe("ok");
    if (result.kind === "ok") {
      expect(result.totalEntries).toBe(1);
      expect(result.histogram.coding).toBe(1);
      expect(result.histogram.security).toBeUndefined();
    }
  });

  it("ACE-1000 のように 4 桁以上の ID もエントリとして扱う", () => {
    const md = `
### ACE-1000: 将来の連番

| フィールド | 値 |
| Category | process |
| Origin | PR #999 |
`;

    const result = analyzePlaybookMarkdown(md);
    expect(result.kind).toBe("ok");
    if (result.kind === "ok") {
      expect(result.totalEntries).toBe(1);
      expect(result.histogram.process).toBe(1);
    }
  });

  it("PRスコープ式 ID（ACE-438-1）と Issue 式（ACE-i425-1）もエントリとして扱う", () => {
    const md = `
### ACE-438-1: PRスコープ式エントリ

| フィールド | 値 |
| Category | coding |
| Origin | PR #438 |

### ACE-438-2: 同一PRの2件目

| フィールド | 値 |
| Category | testing |
| Origin | PR #438 |

### ACE-i425-1: Issue 由来エントリ

| フィールド | 値 |
| Category | process |
| Origin | Issue #425 |
`;

    const result = analyzePlaybookMarkdown(md);
    expect(result.kind).toBe("ok");
    if (result.kind === "ok") {
      expect(result.totalEntries).toBe(3);
      expect(result.histogram.coding).toBe(1);
      expect(result.histogram.testing).toBe(1);
      expect(result.histogram.process).toBe(1);
    }
  });

  it("プレースホルダ見出し（ACE-XXX / ACE-NNN）と i の後が非数字（ACE-iabc）は集計しない", () => {
    const md = `
### ACE-XXX: [タイトル]

| フィールド | 値 |
| Category | coding / architecture / testing |

### ACE-NNN: 別プレースホルダ

| フィールド | 値 |
| Category | testing |

### ACE-iabc: i の後が数字でないため実IDではない

| フィールド | 値 |
| Category | security |

### ACE-001: 実エントリ

| フィールド | 値 |
| Category | coding |
| Origin | PR #1 |
`;

    const result = analyzePlaybookMarkdown(md);
    expect(result.kind).toBe("ok");
    if (result.kind === "ok") {
      expect(result.totalEntries).toBe(1);
      expect(result.histogram.coding).toBe(1);
      expect(result.histogram.testing).toBeUndefined();
      expect(result.histogram.security).toBeUndefined();
    }
  });

  it("ACE 見出しが無い場合は error を返す", () => {
    const result = analyzePlaybookMarkdown("# 見出しのみ\n");
    expect(result.kind).toBe("error");
  });

  it("allowEmpty:true なら見出し0件でも error にせず空の ok を返す（分割レイアウトの索引ファイル向け）", () => {
    const result = analyzePlaybookMarkdown("# 索引のみ\n", { allowEmpty: true });
    expect(result.kind).toBe("ok");
    if (result.kind === "ok") {
      expect(result.totalEntries).toBe(0);
      expect(result.histogram).toEqual({});
    }
  });

  it("allowEmpty:true でも Category 行が解析できないブロックは依然 error", () => {
    const md = "### ACE-1-1: 実エントリだが Category 行が壊れている\n\n| Origin | PR #1 |\n";
    const result = analyzePlaybookMarkdown(md, { allowEmpty: true });
    expect(result.kind).toBe("error");
  });
});

describe("mergeAnalyses", () => {
  it("複数ファイルの histogram / totalEntries を合算する", () => {
    const merged = mergeAnalyses([
      { kind: "ok", histogram: { coding: 2, process: 1 }, totalEntries: 3 },
      { kind: "ok", histogram: { process: 4 }, totalEntries: 4 },
      { kind: "ok", histogram: {}, totalEntries: 0 },
    ]);
    expect(merged.totalEntries).toBe(7);
    expect(merged.histogram).toEqual({ coding: 2, process: 5 });
  });

  it("空配列は totalEntries 0 の ok を返す", () => {
    const merged = mergeAnalyses([]);
    expect(merged.kind).toBe("ok");
    expect(merged.totalEntries).toBe(0);
    expect(merged.histogram).toEqual({});
  });
});

describe("discoverPlaybookSubfiles", () => {
  let tmpDir = "";

  afterEach(() => {
    if (tmpDir) {
      fs.rmSync(tmpDir, { recursive: true, force: true });
      tmpDir = "";
    }
  });

  it("playbook/ ディレクトリが無い場合は空配列（旧レイアウト）", () => {
    tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), "ace-split-"));
    const playbookPath = path.join(tmpDir, "PLAYBOOK.md");
    fs.writeFileSync(playbookPath, "# no subfiles\n");

    expect(discoverPlaybookSubfiles(playbookPath)).toEqual([]);
  });

  it("playbook/ 配下の .md ファイルをソート済みで返す（.md 以外は無視）", () => {
    tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), "ace-split-"));
    const playbookPath = path.join(tmpDir, "PLAYBOOK.md");
    fs.writeFileSync(playbookPath, "# index\n");
    const subDir = path.join(tmpDir, "playbook");
    fs.mkdirSync(subDir);
    fs.writeFileSync(path.join(subDir, "tooling.md"), "");
    fs.writeFileSync(path.join(subDir, "coding.md"), "");
    fs.writeFileSync(path.join(subDir, "README.txt"), "");

    expect(discoverPlaybookSubfiles(playbookPath)).toEqual([
      path.join(subDir, "coding.md"),
      path.join(subDir, "tooling.md"),
    ]);
  });
});

describe("countPlaybookLines", () => {
  it("末尾に改行がある場合は改行数を数える（wc -l 準拠）", () => {
    expect(countPlaybookLines("a\nb\nc\n")).toBe(3);
  });

  it("末尾に改行が無い最終行は数えない（wc -l 準拠）", () => {
    expect(countPlaybookLines("a\nb\nc")).toBe(2);
  });

  it("空文字は 0 行", () => {
    expect(countPlaybookLines("")).toBe(0);
  });

  it("改行のみは 1 行", () => {
    expect(countPlaybookLines("\n")).toBe(1);
  });
});

describe("isOverLineThreshold", () => {
  it("閾値ちょうどは超過しない（境界は > 判定）", () => {
    expect(isOverLineThreshold(800, 800)).toBe(false);
  });

  it("閾値+1 は超過する", () => {
    expect(isOverLineThreshold(801, 800)).toBe(true);
  });

  it("閾値未満は超過しない", () => {
    expect(isOverLineThreshold(10, 800)).toBe(false);
  });
});

describe("parsePositiveIntEnv", () => {
  afterEach(() => {
    vi.restoreAllMocks();
  });

  it("未設定・空文字・空白のみは既定値", () => {
    expect(parsePositiveIntEnv(undefined, 800, "X")).toBe(800);
    expect(parsePositiveIntEnv("", 800, "X")).toBe(800);
    expect(parsePositiveIntEnv("   ", 800, "X")).toBe(800);
  });

  it("正の整数はそのまま採用（前後空白は無視）", () => {
    expect(parsePositiveIntEnv("5000", 800, "X")).toBe(5000);
    expect(parsePositiveIntEnv("  900  ", 800, "X")).toBe(900);
  });

  it("数字以外を含む値は既定値へフォールバックし警告する", () => {
    const warn = vi.spyOn(console, "warn").mockImplementation(() => {});
    expect(parsePositiveIntEnv("800abc", 800, "ACE_MAX_PLAYBOOK_LINES")).toBe(800);
    expect(parsePositiveIntEnv("1e3", 800, "ACE_MAX_PLAYBOOK_LINES")).toBe(800);
    expect(parsePositiveIntEnv("abc", 800, "ACE_MAX_PLAYBOOK_LINES")).toBe(800);
    expect(warn).toHaveBeenCalled();
  });

  it("0 以下・負数は既定値へフォールバックし警告する", () => {
    const warn = vi.spyOn(console, "warn").mockImplementation(() => {});
    expect(parsePositiveIntEnv("0", 800, "X")).toBe(800);
    expect(parsePositiveIntEnv("-5", 800, "X")).toBe(800);
    expect(warn).toHaveBeenCalled();
  });
});

describe("main（行数警告のみ・exit code 不変）", () => {
  const originalArgv = process.argv;
  let tmpDir = "";

  afterEach(() => {
    process.argv = originalArgv;
    delete process.env.ACE_MAX_PLAYBOOK_LINES;
    delete process.env.ACE_MAX_ENTRIES_PER_CATEGORY;
    vi.restoreAllMocks();
    if (tmpDir) {
      fs.rmSync(tmpDir, { recursive: true, force: true });
      tmpDir = "";
    }
  });

  function writePlaybook(body: string): string {
    tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), "ace-line-"));
    const file = path.join(tmpDir, "PLAYBOOK.md");
    fs.writeFileSync(file, body);
    return file;
  }

  it("行数のみ超過なら exit 0・stderr に警告・行数は常時出力", () => {
    const body =
      "### ACE-1-1: t\n\n| Category | coding |\n| Origin | PR #1 |\n" +
      "x\n".repeat(20);
    const file = writePlaybook(body);
    process.env.ACE_MAX_PLAYBOOK_LINES = "5";
    process.argv = ["node", "check-category-size.ts", file];
    const log = vi.spyOn(console, "log").mockImplementation(() => {});
    const err = vi.spyOn(console, "error").mockImplementation(() => {});

    const code = main();

    expect(code).toBe(0);
    expect(log.mock.calls.flat().join("\n")).toContain("総行数:");
    expect(err.mock.calls.flat().join("\n")).toContain("行数が閾値を超過");
  });

  it("カテゴリ件数超過なら exit 1（既存ゲートは不変）", () => {
    const body =
      "### ACE-1-1: a\n\n| Category | coding |\n| Origin | PR #1 |\n" +
      "### ACE-1-2: b\n\n| Category | coding |\n| Origin | PR #1 |\n";
    const file = writePlaybook(body);
    process.env.ACE_MAX_ENTRIES_PER_CATEGORY = "1";
    process.argv = ["node", "check-category-size.ts", file];
    vi.spyOn(console, "log").mockImplementation(() => {});
    vi.spyOn(console, "error").mockImplementation(() => {});

    const code = main();

    expect(code).toBe(1);
  });

  describe("分割レイアウト（playbook/ サブディレクトリ検出）", () => {
    function writeSplitPlaybook(indexBody: string, subfiles: Record<string, string>): string {
      tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), "ace-split-main-"));
      const indexPath = path.join(tmpDir, "PLAYBOOK.md");
      fs.writeFileSync(indexPath, indexBody);
      const subDir = path.join(tmpDir, "playbook");
      fs.mkdirSync(subDir);
      for (const [name, content] of Object.entries(subfiles)) {
        fs.writeFileSync(path.join(subDir, name), content);
      }
      return indexPath;
    }

    it("索引(0件) + サブファイルを合算し、総件数・カテゴリ別件数に反映する", () => {
      const indexPath = writeSplitPlaybook("# 索引のみ、エントリ見出しなし\n", {
        "coding.md": "### ACE-1-1: a\n\n| Category | coding |\n| Origin | PR #1 |\n",
        "process.md":
          "### ACE-1-2: b\n\n| Category | process |\n| Origin | PR #1 |\n" +
          "### ACE-1-3: c\n\n| Category | process |\n| Origin | PR #1 |\n",
      });
      process.argv = ["node", "check-category-size.ts", indexPath];
      const log = vi.spyOn(console, "log").mockImplementation(() => {});
      vi.spyOn(console, "error").mockImplementation(() => {});

      const code = main();

      expect(code).toBe(0);
      const out = log.mock.calls.flat().join("\n");
      expect(out).toContain("総エントリ数: 3");
      expect(out).toContain("coding: 1");
      expect(out).toContain("process: 2");
      expect(out).toContain("分割レイアウト検出");
    });

    it("サブファイル側の行数超過も個別に警告する（exit code は不変）", () => {
      const indexPath = writeSplitPlaybook("# 索引\n", {
        "coding.md":
          "### ACE-1-1: a\n\n| Category | coding |\n| Origin | PR #1 |\n" + "x\n".repeat(20),
      });
      process.env.ACE_MAX_PLAYBOOK_LINES = "5";
      process.argv = ["node", "check-category-size.ts", indexPath];
      vi.spyOn(console, "log").mockImplementation(() => {});
      const err = vi.spyOn(console, "error").mockImplementation(() => {});

      const code = main();

      expect(code).toBe(0);
      const errOut = err.mock.calls.flat().join("\n");
      expect(errOut).toContain("coding.md");
      expect(errOut).toContain("行数が閾値を超過");
    });

    it("索引・サブファイルの全てが0件なら usage error（exit 2）", () => {
      const indexPath = writeSplitPlaybook("# 索引\n", {
        "coding.md": "# まだ空\n",
      });
      process.argv = ["node", "check-category-size.ts", indexPath];
      vi.spyOn(console, "log").mockImplementation(() => {});
      vi.spyOn(console, "error").mockImplementation(() => {});

      const code = main();

      expect(code).toBe(2);
    });

    it("カテゴリ件数ゲートは分割レイアウトでも合算値で判定する", () => {
      const indexPath = writeSplitPlaybook("# 索引\n", {
        "coding.md": "### ACE-1-1: a\n\n| Category | coding |\n| Origin | PR #1 |\n",
        "coding2.md": "### ACE-1-2: b\n\n| Category | coding |\n| Origin | PR #1 |\n",
      });
      process.env.ACE_MAX_ENTRIES_PER_CATEGORY = "1";
      process.argv = ["node", "check-category-size.ts", indexPath];
      vi.spyOn(console, "log").mockImplementation(() => {});
      vi.spyOn(console, "error").mockImplementation(() => {});

      const code = main();

      expect(code).toBe(1);
    });
  });
});
