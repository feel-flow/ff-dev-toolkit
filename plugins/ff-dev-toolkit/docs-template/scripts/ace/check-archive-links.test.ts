import { afterEach, describe, expect, it, vi } from "vitest";
import {
  countRelativeEntryLinks,
  discoverArchiveFiles,
  extractOpeningParentBlock,
  findDuplicateAnchors,
  hasLiveBasisNote,
  LIVE_BASIS_NOTE_MARKER,
  main,
} from "./check-archive-links";
import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";

describe("countRelativeEntryLinks", () => {
  it("`](./...)` 形式のリンクを数える", () => {
    const md = [
      "本文 [ACE-1-1](./testing.md#ace-1-1) と [ACE-1-2](./coding.md#ace-1-2)。",
      "",
    ].join("\n");

    expect(countRelativeEntryLinks(md)).toBe(2);
  });

  it("`../` で始まるリンクは archive 基準で正しいので数えない", () => {
    const md = "> **Parent**: [PLAYBOOK.md](../../PLAYBOOK.md) / [live](../testing.md#ace-1-1)\n";

    expect(countRelativeEntryLinks(md)).toBe(0);
  });

  it("コードスパン内の `./...` は Markdown リンクではないので数えない（注記文の自己検出を防ぐ）", () => {
    // 冒頭注記そのものが `./<category>.md#ace-xxx` を例示として含む。これを違反として
    // 数えると「注記を入れたファイルは常に違反」になり、ゲートが自己矛盾する。
    const md = "本文中の `./<category>.md#ace-xxx` は live 側のリンクである。\n";

    expect(countRelativeEntryLinks(md)).toBe(0);
  });

  it("リンクが無ければ 0", () => {
    expect(countRelativeEntryLinks("# アーカイブ\n")).toBe(0);
  });
});

function archiveWithParent(noteInParent: boolean, extra = ""): string {
  const note = noteInParent
    ? `> **${LIVE_BASIS_NOTE_MARKER}**: 各エントリ本文は原文を verbatim 保全している。\n`
    : "> 注記はここに無い。\n";
  return [
    "# PLAYBOOK Archive — テスト戦略 (testing)",
    "",
    "> **Parent**: [PLAYBOOK.md](../../PLAYBOOK.md) — アーカイブ済みエントリの保管場所。",
    note,
    "",
    "---",
    "",
    extra,
  ].join("\n");
}

describe("extractOpeningParentBlock / hasLiveBasisNote", () => {
  it("Parent ブロック内の規定マーカーだけを注記ありと判定する", () => {
    expect(hasLiveBasisNote(archiveWithParent(true))).toBe(true);
    const parent = extractOpeningParentBlock(archiveWithParent(true));
    expect(parent).toContain(LIVE_BASIS_NOTE_MARKER);
  });

  it("Parent ブロック外（エントリ本文）のマーカーは注記なし", () => {
    const md = archiveWithParent(false, `本文に ${LIVE_BASIS_NOTE_MARKER} と書く。\n`);
    expect(hasLiveBasisNote(md)).toBe(false);
  });

  it("最初の --- より後の Parent ブロックは冒頭ではない", () => {
    const md = [
      "# PLAYBOOK Archive — testing (testing)",
      "",
      "---",
      "",
      "> **Parent**: 後段。",
      `> **${LIVE_BASIS_NOTE_MARKER}**: ここに書いても無効。`,
      "",
    ].join("\n");
    expect(extractOpeningParentBlock(md)).toBeNull();
    expect(hasLiveBasisNote(md)).toBe(false);
  });

  it("Parent ブロック自体が無ければ false", () => {
    expect(hasLiveBasisNote("# PLAYBOOK Archive — ツール設定 (tooling)\n")).toBe(false);
    expect(extractOpeningParentBlock("# PLAYBOOK Archive\n")).toBeNull();
  });
});

describe("findDuplicateAnchors", () => {
  it("同一ファイル内の同じ <a id> を返す", () => {
    const md = [
      '<a id="ace-164-2"></a>',
      "",
      "### ACE-164-2: first",
      "",
      '<a id="ace-164-2"></a>',
      "",
      "### ACE-164-2: duplicate",
      "",
    ].join("\n");
    expect(findDuplicateAnchors(md)).toEqual(["ace-164-2"]);
  });

  it("一意なら空配列", () => {
    const md = '<a id="ace-1-1"></a>\n\n<a id="ace-1-2"></a>\n';
    expect(findDuplicateAnchors(md)).toEqual([]);
  });
});

describe("discoverArchiveFiles", () => {
  let tmpDir = "";

  afterEach(() => {
    if (tmpDir) {
      fs.rmSync(tmpDir, { recursive: true, force: true });
      tmpDir = "";
    }
  });

  it("playbook/archive/ 配下の .md をソート済みで返す", () => {
    tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), "ace-archive-"));
    const playbookPath = path.join(tmpDir, "PLAYBOOK.md");
    fs.writeFileSync(playbookPath, "# index\n");
    const archiveDir = path.join(tmpDir, "playbook", "archive");
    fs.mkdirSync(archiveDir, { recursive: true });
    fs.writeFileSync(path.join(archiveDir, "tooling.md"), "");
    fs.writeFileSync(path.join(archiveDir, "coding.md"), "");
    fs.writeFileSync(path.join(archiveDir, "README.txt"), "");

    expect(discoverArchiveFiles(playbookPath)).toEqual([
      path.join(archiveDir, "coding.md"),
      path.join(archiveDir, "tooling.md"),
    ]);
  });

  it("archive/ が無ければ空配列（refine 未実行のプロジェクト）", () => {
    tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), "ace-archive-"));
    const playbookPath = path.join(tmpDir, "PLAYBOOK.md");
    fs.writeFileSync(playbookPath, "# index\n");
    fs.mkdirSync(path.join(tmpDir, "playbook"));

    expect(discoverArchiveFiles(playbookPath)).toEqual([]);
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

  function writeArchive(files: Record<string, string>): string {
    tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), "ace-archive-main-"));
    const playbookPath = path.join(tmpDir, "PLAYBOOK.md");
    fs.writeFileSync(playbookPath, "# index\n");
    const archiveDir = path.join(tmpDir, "playbook", "archive");
    fs.mkdirSync(archiveDir, { recursive: true });
    for (const [name, content] of Object.entries(files)) {
      fs.writeFileSync(path.join(archiveDir, name), content);
    }
    return playbookPath;
  }

  it("`./` リンクを含むのに冒頭注記が無い archive ファイルは exit 1 で名指しする", () => {
    const playbookPath = writeArchive({
      "tooling.md":
        "# PLAYBOOK Archive — ツール設定 (tooling)\n\n本文 [ACE-1-1](./tooling.md#ace-1-1)。\n",
    });
    process.argv = ["node", "check-archive-links.ts", playbookPath];
    vi.spyOn(console, "log").mockImplementation(() => {});
    const err = vi.spyOn(console, "error").mockImplementation(() => {});

    const code = main();

    expect(code).toBe(1);
    const errOut = err.mock.calls.flat().join("\n");
    expect(errOut).toContain("tooling.md");
    expect(errOut).toContain(LIVE_BASIS_NOTE_MARKER);
  });

  it("注記があれば `./` リンクを含んでいても exit 0（verbatim 保全と両立させる）", () => {
    const playbookPath = writeArchive({
      "testing.md":
        archiveWithParent(true, "本文 [ACE-1-1](./testing.md#ace-1-1)。\n"),
    });
    process.argv = ["node", "check-archive-links.ts", playbookPath];
    vi.spyOn(console, "log").mockImplementation(() => {});
    const err = vi.spyOn(console, "error").mockImplementation(() => {});

    const code = main();

    expect(code).toBe(0);
    expect(err.mock.calls.flat().join("\n")).not.toContain("testing.md");
  });

  it("`./` リンクが 0 件なら注記が無くても exit 0（不要な注記を強制しない）", () => {
    const playbookPath = writeArchive({
      "coding.md":
        "# PLAYBOOK Archive — コーディング (coding)\n\n本文 [live](../coding.md#ace-1-1)。\n",
    });
    process.argv = ["node", "check-archive-links.ts", playbookPath];
    vi.spyOn(console, "log").mockImplementation(() => {});
    const err = vi.spyOn(console, "error").mockImplementation(() => {});

    const code = main();

    expect(code).toBe(0);
    expect(err.mock.calls.flat().join("\n")).not.toContain("coding.md");
  });

  it("違反ファイルが複数あれば全て名指しする（最初の 1 件で止めない）", () => {
    const playbookPath = writeArchive({
      "tooling.md": "# archive\n\n[a](./tooling.md#ace-1-1)\n",
      "process.md": "# archive\n\n[b](./process.md#ace-2-1)\n",
    });
    process.argv = ["node", "check-archive-links.ts", playbookPath];
    vi.spyOn(console, "log").mockImplementation(() => {});
    const err = vi.spyOn(console, "error").mockImplementation(() => {});

    const code = main();

    expect(code).toBe(1);
    const errOut = err.mock.calls.flat().join("\n");
    expect(errOut).toContain("tooling.md");
    expect(errOut).toContain("process.md");
  });

  it("archive/ が存在しないプロジェクトは exit 0（refine 未実行を赤にしない）", () => {
    tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), "ace-archive-main-"));
    const playbookPath = path.join(tmpDir, "PLAYBOOK.md");
    fs.writeFileSync(playbookPath, "# index\n");
    process.argv = ["node", "check-archive-links.ts", playbookPath];
    const log = vi.spyOn(console, "log").mockImplementation(() => {});
    vi.spyOn(console, "error").mockImplementation(() => {});

    const code = main();

    expect(code).toBe(0);
    expect(log.mock.calls.flat().join("\n")).toContain("archive");
  });

  it("エントリ本文にだけ注記マーカーがあっても `./` リンク付きなら exit 1", () => {
    const playbookPath = writeArchive({
      "tooling.md": archiveWithParent(
        false,
        `本文に「${LIVE_BASIS_NOTE_MARKER}」と書いて [ACE-1-1](./tooling.md#ace-1-1)。\n`,
      ),
    });
    process.argv = ["node", "check-archive-links.ts", playbookPath];
    vi.spyOn(console, "log").mockImplementation(() => {});
    const err = vi.spyOn(console, "error").mockImplementation(() => {});

    const code = main();

    expect(code).toBe(1);
    expect(err.mock.calls.flat().join("\n")).toContain("tooling.md");
  });

  it("同一ファイル内の重複 <a id> は exit 1 で名指しする", () => {
    const playbookPath = writeArchive({
      "testing.md": archiveWithParent(
        true,
        [
          '<a id="ace-164-2"></a>',
          "",
          "### ACE-164-2: first",
          "",
          '<a id="ace-164-2"></a>',
          "",
          "### ACE-164-2: second",
          "",
        ].join("\n"),
      ),
    });
    process.argv = ["node", "check-archive-links.ts", playbookPath];
    vi.spyOn(console, "log").mockImplementation(() => {});
    const err = vi.spyOn(console, "error").mockImplementation(() => {});

    const code = main();

    expect(code).toBe(1);
    const errOut = err.mock.calls.flat().join("\n");
    expect(errOut).toContain("testing.md");
    expect(errOut).toContain("ace-164-2");
  });

  it("引数も ACE_PLAYBOOK_PATH も無ければ usage error（exit 2）", () => {
    process.argv = ["node", "check-archive-links.ts"];
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
