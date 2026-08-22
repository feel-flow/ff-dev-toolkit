import { afterEach, describe, expect, it, vi } from "vitest";
import {
  detectLegacyMarkers,
  findMalformedEntryHeadings,
  isDirectExecution,
  listEntryIds,
  listLegacyEntryIds,
  main,
  parseAllowlist,
  splitEntries,
} from "./check-entry-format";
import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

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
    const markers = detectLegacyMarkers(splitEntries(legacyEntry("1-1"))[0]?.body ?? "");
    expect(markers).toContain("field-table-header");
    expect(markers).toContain("table-separator");
    expect(markers).toContain("insight-block");
  });

  it("メタ表だけ正準化されたハイブリッドも Insight ブロックで検出する", () => {
    // live 実データに 4 件存在する（メタ表を正準へ再整形し本文は逐語同一のまま残したもの）。
    // 区切り行だけを主判定にすると、このハイブリッドが新規追記されても通ってしまう。
    const markers = detectLegacyMarkers(splitEntries(hybridEntry("1-2"))[0]?.body ?? "");
    expect(markers).toEqual(["insight-block"]);
  });

  it("コンパクト正準フォーマットは 1 つも検出しない", () => {
    expect(detectLegacyMarkers(splitEntries(compactEntry("1-3"))[0]?.body ?? "")).toEqual([]);
  });

  it("正準メタの本文にある比較表は旧メタ表と誤認しない", () => {
    const body = [
      "| Category | process | Origin | PR #429 |",
      "| Date | 2026-08-12 |",
      "| Helpful | 0 | Harmful | 0 |",
      "| Status | active |",
      "",
      "移行結果を比較する。",
      "",
      "| 移行 | 結果 |",
      "| --- | --- |",
      "| 1 本目 | 成功 |",
    ].join("\n");
    expect(detectLegacyMarkers(body)).toEqual([]);
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

  it("フェンス内の正準形見出しは境界にせず、本文は空白化前の行を保つ（Issue #342）", () => {
    // 境界の判定はフェンス空白化済みの行、本文の収集は空白化前の行 — の二系統走査。
    // 本文側まで空白化すると、旧形式マーカーの検出対象（引用された例示を含む本文）が
    // 静かに消えて detectLegacyMarkers の入力が変わる。
    const fence = "```";
    const content =
      CATEGORY_HEADER +
      [
        "### ACE-1-1: 例示を含む実エントリ",
        "",
        `${fence}markdown`,
        "### ACE-9-9: 悪い例",
        fence,
        "",
        "---",
        "",
      ].join("\n");
    const entries = splitEntries(content);
    expect(entries.map((e) => e.id)).toEqual(["ACE-1-1"]);
    expect(entries[0].body).toContain("### ACE-9-9: 悪い例");
  });
});

describe("--list-legacy 機械可読 CLI（Issue #336）", () => {
  let tmpDir = "";

  afterEach(() => {
    vi.restoreAllMocks();
    if (tmpDir) {
      fs.rmSync(tmpDir, { recursive: true, force: true });
      tmpDir = "";
    }
  });

  function writeDirectory(files: Readonly<Record<string, string>>): string {
    tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), "ace-list-legacy-"));
    for (const [name, content] of Object.entries(files)) {
      fs.writeFileSync(path.join(tmpDir, name), content);
    }
    return tmpDir;
  }

  function resolveSeedDirectory(): string {
    const sourceDir = path.dirname(fileURLToPath(import.meta.url));
    const candidates = [
      path.resolve(sourceDir, "../../08-knowledge/playbook"),
      path.resolve(sourceDir, "../../plugins/ff-dev-toolkit/docs-template/08-knowledge/playbook"),
    ];
    const found = candidates.find((candidate) => fs.existsSync(candidate));
    if (!found) {
      throw new Error(`docs-template の見本ディレクトリが見つかりません: ${candidates.join(", ")}`);
    }
    return found;
  }

  it("プレースホルダは除外し、コロン直後に空白がない見出しも ID だけを返す", () => {
    const directory = writeDirectory({
      "coding.md": [
        CATEGORY_HEADER,
        "### ACE-XXX: [タイトル]",
        "",
        "**Insight**: これはテンプレート例。",
        "",
        "### ACE-1-1:タイトル",
        "",
        "**Insight**: 旧形式。",
        "",
      ].join("\n"),
    });

    expect(listLegacyEntryIds(directory)).toEqual(["ACE-1-1"]);
  });

  it("stdout は字典順・重複除去の 1 行 1 ID だけで、0 件なら空", () => {
    const directory = writeDirectory({
      "b.md": CATEGORY_HEADER + legacyEntry("2-1") + legacyEntry("1-1"),
      "a.md": CATEGORY_HEADER + legacyEntry("1-1"),
    });
    const log = vi.spyOn(console, "log").mockImplementation(() => {});
    vi.spyOn(console, "error").mockImplementation(() => {});

    expect(main(["node", "check-entry-format.ts", "--list-legacy", directory])).toBe(0);
    expect(log.mock.calls.map(([line]) => line)).toEqual(["ACE-1-1", "ACE-2-1"]);

    log.mockClear();
    fs.writeFileSync(path.join(directory, "a.md"), CATEGORY_HEADER + compactEntry("1-1"));
    fs.writeFileSync(path.join(directory, "b.md"), CATEGORY_HEADER + compactEntry("2-1"));
    expect(main(["node", "check-entry-format.ts", "--list-legacy", directory])).toBe(0);
    expect(log).not.toHaveBeenCalled();
  });

  it("--list-entry-ids は形式を問わず認識した ID 集合を返す", () => {
    const directory = writeDirectory({
      "b.md": CATEGORY_HEADER + legacyEntry("2-1") + compactEntry("1-1"),
      "a.md": CATEGORY_HEADER + compactEntry("1-1"),
    });
    const log = vi.spyOn(console, "log").mockImplementation(() => {});

    expect(main(["node", "check-entry-format.ts", "--list-entry-ids", directory])).toBe(0);
    expect(log.mock.calls.map(([line]) => line)).toEqual(["ACE-1-1", "ACE-2-1"]);
  });

  it("直下の Markdown だけを走査し、子ディレクトリは読まない", () => {
    const directory = writeDirectory({ "coding.md": CATEGORY_HEADER + compactEntry("1-1") });
    const archiveDir = path.join(directory, "archive");
    fs.mkdirSync(archiveDir);
    fs.writeFileSync(path.join(archiveDir, "coding.md"), CATEGORY_HEADER + legacyEntry("9-9"));

    expect(listLegacyEntryIds(directory)).toEqual([]);
  });

  it("未閉コードフェンスは不完全な一覧を出さず exit 2", () => {
    const directory = writeDirectory({
      "a.md": CATEGORY_HEADER + legacyEntry("1-1"),
      "b.md": CATEGORY_HEADER + "```markdown\n",
    });
    const log = vi.spyOn(console, "log").mockImplementation(() => {});
    const err = vi.spyOn(console, "error").mockImplementation(() => {});

    expect(main(["node", "check-entry-format.ts", "--list-legacy", directory])).toBe(2);
    expect(log).not.toHaveBeenCalled();
    expect(err.mock.calls.flat().join("\n")).toContain("b.md");
    expect(err.mock.calls.flat().join("\n")).toContain("閉じていません");
  });

  it("引数不備とディレクトリ以外の対象は exit 2", () => {
    const directory = writeDirectory({ "coding.md": CATEGORY_HEADER + compactEntry("1-1") });
    const err = vi.spyOn(console, "error").mockImplementation(() => {});

    expect(main(["node", "check-entry-format.ts", "--list-legacy"])).toBe(2);
    expect(
      main(["node", "check-entry-format.ts", "--list-legacy", path.join(directory, "coding.md")]),
    ).toBe(2);
    expect(
      main(["node", "check-entry-format.ts", "--list-legacy", path.join(directory, "missing")]),
    ).toBe(2);
    expect(err.mock.calls.flat().join("\n")).toContain("ディレクトリではありません");
    expect(err.mock.calls.flat().join("\n")).toContain("missing");
  });

  it("未知の一覧オプションは通常ゲートへ落とさず stdout を空にして exit 2", () => {
    const log = vi.spyOn(console, "log").mockImplementation(() => {});
    const err = vi.spyOn(console, "error").mockImplementation(() => {});

    expect(main(["node", "check-entry-format.ts", "--list-legcy", "."])).toBe(2);
    expect(log).not.toHaveBeenCalled();
    expect(err.mock.calls.flat().join("\n")).toContain("Usage:");
  });

  it("Markdown が 0 件なら両一覧モードとも成功し stdout は空", () => {
    const directory = writeDirectory({ "legacy.txt": legacyEntry("9-9") });
    const log = vi.spyOn(console, "log").mockImplementation(() => {});

    expect(main(["node", "check-entry-format.ts", "--list-entry-ids", directory])).toBe(0);
    expect(main(["node", "check-entry-format.ts", "--list-legacy", directory])).toBe(0);
    expect(log).not.toHaveBeenCalled();
  });

  it("現行 docs-template の見本 ID 集合と旧形式 0 件を固定する", () => {
    const seedDir = resolveSeedDirectory();
    expect(listEntryIds(seedDir)).toEqual(["ACE-000-1", "ACE-000-2", "ACE-000-3"]);
    expect(listLegacyEntryIds(seedDir)).toEqual([]);
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

describe("ID 形状の fail-loud 検査（Issue #339）", () => {
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

  function runWith(content: string): { code: number; err: string } {
    tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), "ace-shape-"));
    const playbookPath = path.join(tmpDir, "PLAYBOOK.md");
    fs.writeFileSync(playbookPath, "# 索引\n");
    const subDir = path.join(tmpDir, "playbook");
    fs.mkdirSync(subDir);
    fs.writeFileSync(path.join(subDir, "coding.md"), content);
    fs.writeFileSync(path.join(tmpDir, "legacy-format-allowlist.txt"), "");
    process.argv = ["node", "check-entry-format.ts", playbookPath];
    vi.spyOn(console, "log").mockImplementation(() => {});
    const err = vi.spyOn(console, "error").mockImplementation(() => {});
    const code = main();
    return { code, err: err.mock.calls.flat().join("\n") };
  }

  it.each([
    ["ACE-337--1", "二重ハイフン"],
    ["ACE-1_9", "アンダースコア"],
    ["ACE-01a", "英字 suffix（単段）"],
    ["ACE-438-1a", "英字 suffix（多段。#339 で落とすと決定した形）"],
    ["ACE-1", "連番の無い単段（PR 由来は連番必須）"],
    ["ACE-01", "連番の無い 2 桁（旧 3 桁形式ではない）"],
    ["ACE-0001", "連番の無い 4 桁（旧 3 桁形式ではない）"],
    ["ACE-i425", "連番の無い Issue 由来（連番必須）"],
  ])("不正 ID %s（%s）は非 0 で名指しされる", (badId) => {
    const body = [
      CATEGORY_HEADER,
      `### ${badId}: 不正な形状のエントリ`,
      "",
      "| Category | coding | Origin | PR #1 |",
      "| Date | 2026-01-01 |",
      "| Helpful | 0 | Harmful | 0 |",
      "| Status | active |",
      "",
      "本文。",
      "",
      "---",
      "",
    ].join("\n");
    const { code, err } = runWith(body);
    expect(code).toBe(1);
    expect(err).toContain(badId);
    expect(err).toContain("形状");
    // AC の「直し方を名指しする」を固定 — 誘導先（§エントリID規則）と同じ解決策。
    // 「単段」の禁止も文面に含まれること（regex だけ厳格化して文面が古い drift の検出）
    expect(err).toContain("-<連番>");
    expect(err).toContain("単段");
  });

  it.each(["ACE-001", "ACE-438-1", "ACE-i425-1", "ACE-1-2-3", "ACE-1-2-3-4"])(
    "正準な ID %s は pass する",
    (goodId) => {
      const body = [
        CATEGORY_HEADER,
        `### ${goodId}: 正準な形状のエントリ`,
        "",
        "| Category | coding | Origin | PR #1 |",
        "| Date | 2026-01-01 |",
        "| Helpful | 0 | Harmful | 0 |",
        "| Status | active |",
        "",
        "本文。",
        "",
        "---",
        "",
      ].join("\n");
      const { code, err } = runWith(body);
      expect(code).toBe(0);
      expect(err).toBe("");
    },
  );

  it("不正 ID は旧形式判定と独立に報告される（compact 形式でも赤）", () => {
    const { code, err } = runWith(CATEGORY_HEADER + compactEntry("9-9").replace("ACE-9-9", "ACE-9--9"));
    expect(code).toBe(1);
    expect(err).toContain("ACE-9--9");
  });
});

describe("ID 形状: 複数エントリ混在（Issue #339 / g フラグ回帰の検出）", () => {
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

  it("正 2 件 + 不正 2 件の混在で、不正のみ全件名指し・正は無罪になる", () => {
    // 1 ファイル 1 エントリの fixture だけだと、形状 regex に g フラグが付く回帰
    // （lastIndex 状態で .test() が交互に偽る）を検出できない。混在 + 全件報告の
    // 検査は、報告の一括性（片方の違反で打ち切らない）も同時に固定する。
    const mk = (id: string): string =>
      [
        `### ${id}: エントリ`,
        "",
        "| Category | coding | Origin | PR #1 |",
        "| Date | 2026-01-01 |",
        "| Helpful | 0 | Harmful | 0 |",
        "| Status | active |",
        "",
        "本文。",
        "",
        "---",
        "",
      ].join("\n");
    tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), "ace-shape-mix-"));
    const playbookPath = path.join(tmpDir, "PLAYBOOK.md");
    fs.writeFileSync(playbookPath, "# 索引\n");
    fs.mkdirSync(path.join(tmpDir, "playbook"));
    fs.writeFileSync(
      path.join(tmpDir, "playbook", "coding.md"),
      CATEGORY_HEADER + mk("ACE-1-1") + mk("ACE-9--9") + mk("ACE-2-1") + mk("ACE-3_1"),
    );
    fs.writeFileSync(path.join(tmpDir, "legacy-format-allowlist.txt"), "");
    process.argv = ["node", "check-entry-format.ts", playbookPath];
    vi.spyOn(console, "log").mockImplementation(() => {});
    const err = vi.spyOn(console, "error").mockImplementation(() => {});

    const code = main();
    const out = err.mock.calls.flat().join("\n");

    expect(code).toBe(1);
    expect(out).toContain("ACE-9--9");
    expect(out).toContain("ACE-3_1");
    expect(out).not.toContain("ACE-1-1（");
    expect(out).not.toContain("ACE-2-1（");
  });
});

describe("ID 形状違反時の allowlist 警告抑制（Issue #339）", () => {
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

  it("見出しの ID が壊れているとき、missing 警告で誤った allowlist 掃除を案内しない", () => {
    // allowlist の ACE-9-9 が見出し側で ACE-9--9 に化けた形。ID は allowlist の
    // キーなので、この状態で missing を計算すると「ACE-9-9 を削除してください」
    // という誤案内になる — 形状違反があるときは掃除警告を出さない。
    tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), "ace-shape-warn-"));
    const playbookPath = path.join(tmpDir, "PLAYBOOK.md");
    fs.writeFileSync(playbookPath, "# 索引\n");
    fs.mkdirSync(path.join(tmpDir, "playbook"));
    fs.writeFileSync(
      path.join(tmpDir, "playbook", "coding.md"),
      CATEGORY_HEADER + legacyEntry("9--9"),
    );
    fs.writeFileSync(path.join(tmpDir, "legacy-format-allowlist.txt"), "ACE-9-9\n");
    process.argv = ["node", "check-entry-format.ts", playbookPath];
    vi.spyOn(console, "log").mockImplementation(() => {});
    const warn = vi.spyOn(console, "warn").mockImplementation(() => {});
    const err = vi.spyOn(console, "error").mockImplementation(() => {});

    const code = main();

    expect(code).toBe(1);
    expect(err.mock.calls.flat().join("\n")).toContain("ACE-9--9");
    expect(warn.mock.calls.flat().join("\n")).not.toContain("allowlist から削除");
  });
});

describe("索引 PLAYBOOK.md 自身の走査（Issue #339）", () => {
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

  it("分割レイアウトでも索引に残った不正 ID を名指しする（部分移行中の穴）", () => {
    // 件数ゲート・refine・reuse は索引の内容も集計対象に含める。索引だけ形式ゲート
    // から外れると「認識して数えるが、どのゲートも形式が不正とは言わない」経路が残る。
    tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), "ace-shape-index-"));
    const playbookPath = path.join(tmpDir, "PLAYBOOK.md");
    fs.writeFileSync(
      playbookPath,
      "# 索引\n\n### ACE-337--1: 部分移行で索引に残ったエントリ\n\n本文。\n",
    );
    fs.mkdirSync(path.join(tmpDir, "playbook"));
    fs.writeFileSync(path.join(tmpDir, "playbook", "coding.md"), CATEGORY_HEADER + compactEntry("1-1"));
    fs.writeFileSync(path.join(tmpDir, "legacy-format-allowlist.txt"), "");
    process.argv = ["node", "check-entry-format.ts", playbookPath];
    vi.spyOn(console, "log").mockImplementation(() => {});
    const err = vi.spyOn(console, "error").mockImplementation(() => {});

    const code = main();

    expect(code).toBe(1);
    expect(err.mock.calls.flat().join("\n")).toContain("ACE-337--1");
  });
});

describe("フェンス内の正準形見出し・未閉フェンスの一括報告（Issue #342）", () => {
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

  function runWithSubfiles(subfiles: Record<string, string>): { code: number; err: string } {
    tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), "ace-fence-"));
    const playbookPath = path.join(tmpDir, "PLAYBOOK.md");
    fs.writeFileSync(playbookPath, "# 索引\n");
    const subDir = path.join(tmpDir, "playbook");
    fs.mkdirSync(subDir);
    for (const [name, content] of Object.entries(subfiles)) {
      fs.writeFileSync(path.join(subDir, name), content);
    }
    fs.writeFileSync(path.join(tmpDir, "legacy-format-allowlist.txt"), "");
    process.argv = ["node", "check-entry-format.ts", playbookPath];
    vi.spyOn(console, "log").mockImplementation(() => {});
    const err = vi.spyOn(console, "error").mockImplementation(() => {});
    const code = main();
    return { code, err: err.mock.calls.flat().join("\n") };
  }

  const fence = "```";

  function fencedHeadingEntry(): string {
    return (
      CATEGORY_HEADER +
      [
        "### ACE-1-1: 例示を含む実エントリ",
        "",
        `${fence}markdown`,
        "### ACE-9-9: 悪い例",
        fence,
        "",
        "---",
        "",
      ].join("\n")
    );
  }

  it("フェンス内の正準形見出しは exit 1 でファイル・行・ID を名指しし、両対処を案内する", () => {
    const { code, err } = runWithSubfiles({ "coding.md": fencedHeadingEntry() });
    expect(code).toBe(1);
    expect(err).toContain("coding.md");
    expect(err).toContain("ACE-9-9");
    expect(err).toContain("ACE-XXX");
    expect(err).toContain("フェンスの対応");
  });

  it("別ファイルの形状違反も同じ 1 回の実行で報告する（二段階の修正ループを作らない）", () => {
    const { code, err } = runWithSubfiles({
      "coding.md": fencedHeadingEntry(),
      "testing.md": CATEGORY_HEADER + compactEntry("337--1"),
    });
    expect(code).toBe(1);
    expect(err).toContain("ACE-9-9");
    expect(err).toContain("ACE-337--1");
  });

  it("未閉フェンスのファイルはスキップして記録し、他ファイルの違反も報告して exit 2", () => {
    const unclosed =
      CATEGORY_HEADER +
      ["### ACE-1-1: 未閉フェンスを持つエントリ", "", fence, "閉じない例示", ""].join("\n");
    const { code, err } = runWithSubfiles({
      "coding.md": unclosed,
      "testing.md": CATEGORY_HEADER + legacyEntry("9-9"),
    });
    // スキップしたファイルがある = 列挙が不完全なので usage error 側を優先する
    expect(code).toBe(2);
    expect(err).toContain("コードフェンスが閉じていない");
    expect(err).toContain("coding.md");
    expect(err).toContain("ACE-9-9");
  });
});

describe("findMalformedEntryHeadings（Issue #617）", () => {
  it("正準形の見出しだけのテキストでは 1 件も返さない（正値の固定）", () => {
    // 過剰に広い候補パターンへ変異したとき、正常なエントリを名指ししてしまう形を
    // ここで落とす。旧 3 桁・PR スコープ式・Issue 由来・3 段・コロン直後に空白の
    // 無い形まで、認識器が通す全ての形を並べる。
    // 末尾 3 行は「候補の接頭辞を `### ` まで広げる」変異の検出用 — ACE エントリ
    // ではない h3 見出しは候補にならない（これが無いと接頭辞の変異が生き残る）。
    const cleaned = [
      "### ACE-001: 旧 3 桁",
      "### ACE-438-1: PR スコープ式",
      "### ACE-i425-1: Issue 由来",
      "### ACE-1-2-3: 3 段",
      "### ACE-1-1:コロン直後に空白なし",
      "本文の行。",
      "## ACE- ではじまる ## 見出し",
      "### 補足",
      "### ACE 記法についての h3 見出し",
      "#### ACE-1-1: h4 はエントリ見出しではない",
    ].join("\n");

    expect(findMalformedEntryHeadings(cleaned)).toEqual([]);
  });

  it("インデント付き・`###` 直後の空白なしの見出しも候補として拾う", () => {
    // どちらも書き手はエントリ見出しのつもりだが認識器は取らない = 吸収を起こす形。
    // 候補側だけを空白に寛容にすることで、認識器を広げずに fail-loud へ落とす。
    const cleaned = ["   ### ACE-1-1: インデント付き", "###ACE-1-2: 空白なし"].join("\n");

    expect(findMalformedEntryHeadings(cleaned)).toEqual([
      { line: 0, text: "   ### ACE-1-1: インデント付き" },
      { line: 1, text: "###ACE-1-2: 空白なし" },
    ]);
  });

  it("認識器の文法から外れた見出しを 0-origin 行番号つきで返す", () => {
    const cleaned = ["# 索引", "", "### ACE-1.: 検証用の不正ID", "", "本文。"].join("\n");

    expect(findMalformedEntryHeadings(cleaned)).toEqual([
      { line: 2, text: "### ACE-1.: 検証用の不正ID" },
    ]);
  });

  it("認識される不正形状 ID（ACE-337--1）は返さない（形状検査との二重報告を作らない）", () => {
    const cleaned = "### ACE-337--1: 二重ハイフン\n";

    expect(findMalformedEntryHeadings(cleaned)).toEqual([]);
  });
});

describe("認識されない `### ACE-` 見出しの fail-loud（Issue #617）", () => {
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

  function run(options: {
    readonly subfiles: Record<string, string>;
    readonly allowlist?: string;
  }): { code: number; err: string; warn: string } {
    tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), "ace-malformed-"));
    const playbookPath = path.join(tmpDir, "PLAYBOOK.md");
    fs.writeFileSync(playbookPath, "# 索引\n");
    const subDir = path.join(tmpDir, "playbook");
    fs.mkdirSync(subDir);
    for (const [name, content] of Object.entries(options.subfiles)) {
      fs.writeFileSync(path.join(subDir, name), content);
    }
    fs.writeFileSync(
      path.join(tmpDir, "legacy-format-allowlist.txt"),
      options.allowlist ?? "",
    );
    process.argv = ["node", "check-entry-format.ts", playbookPath];
    vi.spyOn(console, "log").mockImplementation(() => {});
    const warn = vi.spyOn(console, "warn").mockImplementation(() => {});
    const err = vi.spyOn(console, "error").mockImplementation(() => {});
    const code = main();
    return {
      code,
      err: err.mock.calls.flat().join("\n"),
      warn: warn.mock.calls.flat().join("\n"),
    };
  }

  it("直前の allowlist 済みエントリへ吸収される不正 ID 見出しを exit 1 で名指しする", () => {
    // Issue #617 の実測形。`### ACE-1.:` はエントリとして数えられず、旧形式マーカー
    // 入りの本文が直前の allowlist 済みエントリへ吸収されて exit 0 になっていた。
    const { code, err } = run({
      subfiles: {
        "coding.md":
          CATEGORY_HEADER +
          legacyEntry("97-1") +
          ["### ACE-1.: 検証用の不正ID", "", "**Insight**: 旧形式マーカー入り。", ""].join("\n"),
      },
      allowlist: "ACE-97-1\n",
    });

    expect(code).toBe(1);
    expect(err).toContain("coding.md");
    expect(err).toContain("### ACE-1.: 検証用の不正ID");
    expect(err).toContain("吸収");
  });

  it("インデント付きの見出しを exit 1 で名指しする（吸収を起こす形）", () => {
    const { code, err } = run({
      subfiles: {
        "coding.md": CATEGORY_HEADER + "   ### ACE-1-1: インデント付き\n\n本文。\n",
      },
    });

    expect(code).toBe(1);
    expect(err).toContain("### ACE-1-1: インデント付き");
  });

  it("`###` 直後の空白が無い見出しを exit 1 で名指しする", () => {
    const { code, err } = run({
      subfiles: { "coding.md": CATEGORY_HEADER + "###ACE-1-1: 空白なし\n\n本文。\n" },
    });

    expect(code).toBe(1);
    expect(err).toContain("###ACE-1-1: 空白なし");
  });

  it("フェンスの外に置いたプレースホルダ見出しも赤にする", () => {
    const { code, err } = run({
      subfiles: { "coding.md": CATEGORY_HEADER + "### ACE-XXX: [タイトル]\n\n本文。\n" },
    });

    expect(code).toBe(1);
    expect(err).toContain("### ACE-XXX: [タイトル]");
  });

  it("フェンス内のプレースホルダ見出しは緑のまま通る（正値の固定）", () => {
    const fence = "```";
    const { code, err } = run({
      subfiles: {
        "coding.md":
          CATEGORY_HEADER +
          [
            "### ACE-1-1: 例示を含む実エントリ",
            "",
            `${fence}markdown`,
            "### ACE-XXX: [タイトル]",
            fence,
            "",
            "---",
            "",
          ].join("\n"),
      },
    });

    expect(code).toBe(0);
    expect(err).not.toContain("認識されない");
  });

  it("正準形の見出しだけのレイアウトは緑のまま通る（正値の固定）", () => {
    // `### 補足` は ACE エントリではない h3 見出し。候補の接頭辞を `### ` へ広げる
    // 変異はここで赤くなる（正準エントリだけの fixture では変異が生き残る）。
    // `#### ACE-…` は h4 なのでエントリ見出しではない — 見出しレベルの検査を外す変異は
    // ここで赤くなる。
    const { code, err } = run({
      subfiles: {
        "coding.md":
          CATEGORY_HEADER +
          compactEntry("1-1") +
          compactEntry("i425-1") +
          "### 補足\n\n#### ACE-1-1 の適用条件\n\n本文。\n",
        "testing.md": CATEGORY_HEADER + compactEntry("001") + compactEntry("1-2-3"),
      },
    });

    expect(code).toBe(0);
    expect(err).toBe("");
  });

  it("不正 ID 見出しがあるときは allowlist 掃除の警告を出さない（誤案内の抑制）", () => {
    // 吸収された見出しは seenIds に載らないので、missing を計算すると live に居る
    // ID を「削除してください」と案内してしまう（形状違反時の抑制と同じ理由）。
    const { code, warn } = run({
      subfiles: {
        "coding.md": CATEGORY_HEADER + compactEntry("1-1") + "### ACE-1.: 不正ID\n\n本文。\n",
      },
      allowlist: "ACE-9-9\n",
    });

    expect(code).toBe(1);
    expect(warn).not.toContain("allowlist から削除");
  });
});

describe("エントリ ID の重複検出（Issue #617）", () => {
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

  function run(options: {
    readonly index?: string;
    readonly subfiles: Record<string, string>;
    readonly archive?: Record<string, string>;
    readonly allowlist?: string;
  }): { code: number; err: string; warn: string } {
    tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), "ace-dup-id-"));
    const playbookPath = path.join(tmpDir, "PLAYBOOK.md");
    fs.writeFileSync(playbookPath, options.index ?? "# 索引\n");
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
    fs.writeFileSync(
      path.join(tmpDir, "legacy-format-allowlist.txt"),
      options.allowlist ?? "",
    );
    process.argv = ["node", "check-entry-format.ts", playbookPath];
    vi.spyOn(console, "log").mockImplementation(() => {});
    const warn = vi.spyOn(console, "warn").mockImplementation(() => {});
    const err = vi.spyOn(console, "error").mockImplementation(() => {});
    const code = main();
    return {
      code,
      err: err.mock.calls.flat().join("\n"),
      warn: warn.mock.calls.flat().join("\n"),
    };
  }

  it("allowlist 済み ID を再利用した旧形式の新規追記を exit 1 で止める", () => {
    // Issue #617 の実測形。allowed.has(entry.id) は ID 単位なので、既存の
    // allowlist 済み ID を再利用すると旧形式のまま新規追加できていた。
    const { code, err } = run({
      subfiles: { "coding.md": CATEGORY_HEADER + legacyEntry("97-1") + legacyEntry("97-1") },
      allowlist: "ACE-97-1\n",
    });

    expect(code).toBe(1);
    expect(err).toContain("ACE-97-1");
    expect(err).toContain("2 箇所");
  });

  it("同一ファイル内の重複は行番号で場所を分けて示す（ファイル名だけでは直せない）", () => {
    // legacyEntry は anchor 行 + 空行 + 見出しなので、CATEGORY_HEADER（8 行）の直後に
    // 2 件並べると見出しは 10 行目と 30 行目に来る。
    const { code, err } = run({
      subfiles: { "coding.md": CATEGORY_HEADER + legacyEntry("97-1") + legacyEntry("97-1") },
      allowlist: "ACE-97-1\n",
    });

    expect(code).toBe(1);
    expect(err).toContain("coding.md: 10 行目 / 30 行目");
  });

  it("別カテゴリファイルにまたがる重複は出現箇所をファイルごとに示す", () => {
    const { code, err } = run({
      subfiles: {
        "coding.md": CATEGORY_HEADER + compactEntry("524-1"),
        "process.md": CATEGORY_HEADER + compactEntry("524-1"),
      },
    });

    expect(code).toBe(1);
    expect(err).toContain("ACE-524-1");
    expect(err).toContain("coding.md: 10 行目");
    expect(err).toContain("process.md: 10 行目");
  });

  it("重複 ID があっても allowlist の掃除案内は出す（抑制対象は見出し不一致だけ）", () => {
    // 重複しても seenIds は不完全にならないので missing の計算は正しい。ここを
    // 見出し不一致と同じ抑制条件へ入れると、本来出るべき掃除案内が黙って消える。
    const { code, warn } = run({
      subfiles: {
        "coding.md": CATEGORY_HEADER + compactEntry("524-1"),
        "process.md": CATEGORY_HEADER + compactEntry("524-1"),
      },
      allowlist: "ACE-9-9\n",
    });

    expect(code).toBe(1);
    expect(warn).toContain("allowlist から削除");
  });

  it("索引 PLAYBOOK.md 側との重複も検出する（部分移行中の二重掲載）", () => {
    const { code, err } = run({
      index: "# 索引\n\n" + compactEntry("1-1"),
      subfiles: { "coding.md": CATEGORY_HEADER + compactEntry("1-1") },
    });

    expect(code).toBe(1);
    expect(err).toContain("ACE-1-1");
  });

  it("各 ID が 1 回ずつなら緑のまま通る（正値の固定）", () => {
    const { code, err } = run({
      subfiles: {
        "coding.md": CATEGORY_HEADER + compactEntry("524-1") + compactEntry("524-2"),
        "process.md": CATEGORY_HEADER + compactEntry("524-3"),
      },
    });

    expect(code).toBe(0);
    expect(err).toBe("");
  });

  it("archive に同じ ID の原文があっても重複扱いしない（compact の保全形は正常）", () => {
    // playbook/archive/ は走査対象外。ここを巻き込むと /ace-refine の compact
    // （live と archive の両方に同じ ID が残る形）が構造的に赤くなる。
    const { code, err } = run({
      subfiles: { "coding.md": CATEGORY_HEADER + compactEntry("41-3") },
      archive: { "coding.md": legacyEntry("41-3") },
    });

    expect(code).toBe(0);
    expect(err).toBe("");
  });
});

describe("isDirectExecution", () => {
  function tempDir(): string {
    return fs.realpathSync.native(os.tmpdir());
  }

  it("完全一致する argv path だけを直接実行扱いする", () => {
    const scriptPath = path.join(tempDir(), "check-entry-format.ts");
    expect(isDirectExecution(pathToFileURL(scriptPath).href, scriptPath)).toBe(true);
  });

  it("ファイル名を含む別スクリプトの部分一致では直接実行扱いしない", () => {
    const dir = tempDir();
    const scriptPath = path.join(dir, "check-entry-format.ts");
    const wrapperPath = path.join(dir, "wrapper-check-entry-format.ts");
    const testPath = path.join(dir, "check-entry-format.test.ts");
    expect(isDirectExecution(pathToFileURL(scriptPath).href, wrapperPath)).toBe(false);
    expect(isDirectExecution(pathToFileURL(scriptPath).href, testPath)).toBe(false);
  });

  it("argv path が無ければ直接実行扱いしない", () => {
    const scriptPath = path.join(tempDir(), "check-entry-format.ts");
    expect(isDirectExecution(pathToFileURL(scriptPath).href, undefined)).toBe(false);
  });
});
