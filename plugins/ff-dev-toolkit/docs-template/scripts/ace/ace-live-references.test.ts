import { afterEach, describe, expect, it } from "vitest";
import { execFileSync } from "node:child_process";
import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";
import {
  LIVE_SCAN_ERROR_PREFIX,
  buildLivePathspecs,
  classifyLiveMentions,
  parseGrepRecords,
  runGit,
  scanLiveReferences,
  type GitRunResult,
  type GitRunner,
  type GrepLine,
  type PlaybookFileText,
} from "./ace-live-references";

/**
 * live 参照の走査（Issue `#2708`）。fixture は PR `#2705` が手作業で外した参照の形を写す:
 * 他エントリからのアンカーリンク・ADR の根拠としての引用・PLAYBOOK 本文の言及・shell の診断文。
 * 数えない側は、自身のブロック・索引行・Changelog（節と CHANGELOG.md）・legacy allowlist・
 * ID の前方一致（ACE-300-9 と ACE-300-90）・archive 配下・走査面の外。
 */
const FENCE = "```";

function entry(id: string, body: readonly string[]): string[] {
  return [
    `<a id="${id.toLowerCase()}"></a>`,
    "",
    `### ${id}: ${id} のタイトル`,
    "",
    `| Category | coding | Origin | PR #${id.split("-")[1]} |`,
    "| Date | 2026-01-01 |",
    "| Helpful | 0 | Harmful | 0 |",
    "| Status | active |",
    "",
    ...body,
    "",
    "---",
    "",
  ];
}

const CANDIDATES = [
  "ACE-300-1", "ACE-300-2", "ACE-300-3", "ACE-300-4", "ACE-300-5",
  "ACE-300-6", "ACE-300-7", "ACE-300-8", "ACE-300-9", "ACE-300-10",
  "ACE-300-12", "ACE-300-13", "ACE-300-14",
] as const;

const PLAYBOOK_MAIN = [
  "# ACE Playbook",
  "",
  "## 運用ルール",
  "",
  "規則の根拠は ACE-300-6 を参照。",
  "",
  "## エントリ一覧",
  "",
  "| ID | タイトル | カテゴリ | リンク |",
  "| --- | --- | --- | --- |",
  ...CANDIDATES.map(
    (id) => `| ${id} | ${id} のタイトル | coding | [playbook/coding.md#${id.toLowerCase()}](./playbook/coding.md#${id.toLowerCase()}) |`,
  ),
  "",
  "## Changelog",
  "",
  "### [1.0.0] - 2026-01-01",
  "",
  "- Archived: ACE-300-3（索引と Changelog だけに残る記載）",
  "",
].join("\n");

const CODING = [
  "# PLAYBOOK — コーディング (coding)",
  "",
  "## エントリ一覧",
  "",
  ...entry("ACE-300-1", ["本文で自分（ACE-300-1、[自身](#ace-300-1)）に触れても参照に数えない。"]),
  ...entry("ACE-300-2", ["誰からも参照されない本文。"]),
  ...entry("ACE-300-3", ["索引と Changelog にだけ現れる。"]),
  ...entry("ACE-300-4", [
    `${FENCE}markdown`,
    "## Changelog",
    FENCE,
    "<!--",
    "## Changelog（HTML コメントの中の例示）",
    "-->",
    "フェンスとコメントの後ろの言及は Changelog 節ではない: ACE-300-10 を補う。",
  ]),
  ...entry("ACE-300-5", ["関連: [アンカーだけのリンク](#ace-300-2)"]),
  ...entry("ACE-300-6", ["PLAYBOOK の運用ルールから引用される。"]),
  ...entry("ACE-300-7", ["Changelog・CHANGELOG.md・allowlist にだけ現れる。"]),
  ...entry("ACE-300-8", ["shell の診断文から案内される。"]),
  ...entry("ACE-300-9", ["前方一致の ACE-300-90 と archive にだけ現れる。"]),
  ...entry("ACE-300-10", ["フェンスの後ろの本文から参照される。"]),
  ...entry("ACE-300-12", ["閉じていないフェンスのある Markdown の後半から参照される。"]),
  ...entry("ACE-300-13", ["閉じていない HTML コメントのある Markdown から参照される。"]),
  ...entry("ACE-300-14", ["Changelog 節の後ろの別の節から参照される。"]),
  // 候補ではない（追跡済みの）エントリ。針の probe がこの見出しを見ていることを固定する
  ...entry("ACE-300-30", ["候補ではないエントリ。"]),
].join("\n");

const LIVE_FILES: Readonly<Record<string, string>> = {
  "docs/08-knowledge/PLAYBOOK.md": PLAYBOOK_MAIN,
  "docs/08-knowledge/playbook/coding.md": CODING,
  "docs/06-reference/DECISIONS.md": [
    "# 決定記録",
    "",
    "## ADR-001: 例",
    "",
    "根拠: ACE-300-5（語彙の共有）。ACE-300-90 は別の ID。",
    "",
    "## Changelog",
    "",
    "- 2026-01-01: ACE-300-7 を反映",
    "",
    // Changelog 節は次のレベル 2 見出しで閉じる
    "## 付録",
    "",
    "付録の根拠: ACE-300-14",
    "",
  ].join("\n"),
  // 節の境界が信用できない Markdown（閉じていないフェンス / `<!--`）では Changelog 節の除外をやめる
  "docs/unclosed-fence.md": [
    "# メモ",
    "",
    "## Changelog",
    "",
    `${FENCE}yaml`,
    "- 閉じ忘れたフェンス",
    "",
    "## 使い方",
    "",
    "使い方の根拠: ACE-300-12",
    "",
  ].join("\n"),
  "docs/unclosed-comment.md": [
    "# メモ",
    "",
    "## 手順",
    "",
    "<!-- 閉じ忘れたコメント",
    "## Changelog",
    "",
    "手順の根拠: ACE-300-13",
    "",
  ].join("\n"),
  // playbook 以外の Markdown でも、フェンスと HTML コメントの中の `## Changelog` は節の始まりにしない
  "docs/guide.md": [
    "# 手引き",
    "",
    "## 手順",
    "",
    `${FENCE}markdown`,
    "## Changelog",
    FENCE,
    "",
    "<!--",
    "## Changelog",
    "-->",
    "",
    "手順の根拠: ACE-300-2 を参照。",
    "",
  ].join("\n"),
  "docs/CHANGELOG.md": "# Changelog\n\n- ACE-300-7 を追加\n",
  "docs/08-knowledge/legacy-format-allowlist.txt": "# allowlist\nACE-300-7\n",
  "plugins/demo/tests/foo/verify.sh": "#!/usr/bin/env bash\n## Changelog（shell のコメントは見出しではない）\n# 直し方は ACE-300-8 を参照\n",
};

/** live の走査面の外、または走査面から外す配置（実 git の結合テストだけで使う）。 */
const OFF_SURFACE_FILES: Readonly<Record<string, string>> = {
  "docs/08-knowledge/playbook/archive/coding.md": [
    "# PLAYBOOK archive — コーディング (coding)",
    "",
    "### ACE-300-99: 退避済みのエントリ",
    "",
    "| Status | merged |",
    "",
    "> Merged into: [ACE-300-6](../coding.md#ace-300-6)",
    "",
    "archive の本文は live ではない: ACE-300-9",
    "",
  ].join("\n"),
  "other/README.md": "走査面の外: ACE-300-1 / ACE-300-9\n",
};

const PLAYBOOK_FILES: readonly PlaybookFileText[] = [
  { file: "docs/08-knowledge/PLAYBOOK.md", content: PLAYBOOK_MAIN, isMain: true },
  { file: "docs/08-knowledge/playbook/coding.md", content: CODING, isMain: false },
];

/** 期待する参照（参照に数えない言及を除いた残り）。行番号は fixture から引く。 */
function lineOf(file: string, needle: string): number {
  const index = LIVE_FILES[file].split("\n").findIndex((line) => line.includes(needle));
  if (index < 0) throw new Error(`fixture に ${needle} がありません: ${file}`);
  return index + 1;
}
const EXPECTED_REFERENCES: ReadonlyMap<string, readonly { file: string; line: number }[]> = new Map([
  ["ACE-300-10", [{ file: "docs/08-knowledge/playbook/coding.md", line: lineOf("docs/08-knowledge/playbook/coding.md", "ACE-300-10 を補う") }]],
  ["ACE-300-2", [
    { file: "docs/08-knowledge/playbook/coding.md", line: lineOf("docs/08-knowledge/playbook/coding.md", "#ace-300-2)") },
    { file: "docs/guide.md", line: lineOf("docs/guide.md", "手順の根拠: ACE-300-2") },
  ]],
  ["ACE-300-5", [{ file: "docs/06-reference/DECISIONS.md", line: lineOf("docs/06-reference/DECISIONS.md", "根拠: ACE-300-5") }]],
  ["ACE-300-6", [{ file: "docs/08-knowledge/PLAYBOOK.md", line: lineOf("docs/08-knowledge/PLAYBOOK.md", "根拠は ACE-300-6") }]],
  ["ACE-300-8", [{ file: "plugins/demo/tests/foo/verify.sh", line: lineOf("plugins/demo/tests/foo/verify.sh", "ACE-300-8 を参照") }]],
  ["ACE-300-12", [{ file: "docs/unclosed-fence.md", line: lineOf("docs/unclosed-fence.md", "使い方の根拠: ACE-300-12") }]],
  ["ACE-300-13", [{ file: "docs/unclosed-comment.md", line: lineOf("docs/unclosed-comment.md", "手順の根拠: ACE-300-13") }]],
  ["ACE-300-14", [{ file: "docs/06-reference/DECISIONS.md", line: lineOf("docs/06-reference/DECISIONS.md", "付録の根拠: ACE-300-14") }]],
]);

function sortedEntries(map: ReadonlyMap<string, readonly { file: string; line: number }[]>) {
  return [...map].sort(([a], [b]) => a.localeCompare(b));
}

/** `git grep -i -F -w` の照合だけを写した模擬（純関数の検査用。走査面の pathspec は実 git の検査で見る）。 */
function simulateGrep(files: Readonly<Record<string, string>>, ids: readonly string[]): GrepLine[] {
  // ID は英数字とハイフンだけなので、文字クラスの外ではそのまま正規表現に埋め込める。
  const pattern = new RegExp(`(?<![A-Za-z0-9_])(?:${ids.join("|")})(?![A-Za-z0-9_])`, "iu");
  const out: GrepLine[] = [];
  for (const file of Object.keys(files).sort()) {
    files[file].split("\n").forEach((text, index) => {
      if (pattern.test(text)) out.push({ file, line: index + 1, text });
    });
  }
  return out;
}

/** 一致した行を含む playbook 以外の Markdown の本文（scanLiveReferences が readText で読む分）。 */
function markdownFilesOf(mentionLines: readonly GrepLine[]): Map<string, string> {
  const playbookSet = new Set(PLAYBOOK_FILES.map((file) => file.file));
  const files = [...new Set(mentionLines.map((m) => m.file))].filter((f) => !playbookSet.has(f) && f.endsWith(".md"));
  return new Map(files.map((file) => [file, LIVE_FILES[file]]));
}

/** 針の probe（`git grep -E '^###[[:space:]]+ACE-'`）の模擬。 */
function simulateHeadingProbe(files: Readonly<Record<string, string>>): GrepLine[] {
  const out: GrepLine[] = [];
  for (const file of Object.keys(files).sort()) {
    files[file].split("\n").forEach((text, index) => {
      if (/^###\s+ACE-/u.test(text)) out.push({ file, line: index + 1, text });
    });
  }
  return out;
}

function classifyFixture(
  mentionLines = simulateGrep(LIVE_FILES, CANDIDATES),
  markdownFiles = markdownFilesOf(mentionLines),
  headingLines = simulateHeadingProbe(LIVE_FILES),
) {
  return classifyLiveMentions({
    candidates: CANDIDATES,
    mentionLines,
    headingLines,
    playbookFiles: PLAYBOOK_FILES,
    markdownFiles,
  });
}

describe("classifyLiveMentions（Issue `#2708`）", () => {
  it("他エントリ・ADR・PLAYBOOK 本文・shell からの言及だけを参照元付きで返す", () => {
    const classified = classifyFixture();
    expect(sortedEntries(classified.references)).toEqual(sortedEntries(EXPECTED_REFERENCES));
    expect(classified.unobservedHeadings).toEqual([]);
  });

  it("参照に数えない言及（自身のブロック・索引行・Changelog・CHANGELOG.md・allowlist・前方一致）だけの候補は参照なし", () => {
    const { references } = classifyFixture();
    for (const id of ["ACE-300-1", "ACE-300-3", "ACE-300-4", "ACE-300-7", "ACE-300-9"]) {
      expect(references.has(id), id).toBe(false);
    }
  });

  it("フェンスと HTML コメントの中の `## Changelog` は節の境界にしない（playbook とそれ以外の Markdown の両方）", () => {
    const { references } = classifyFixture();
    expect(references.get("ACE-300-10")).toEqual(EXPECTED_REFERENCES.get("ACE-300-10"));
    expect(references.get("ACE-300-2")?.some((source) => source.file === "docs/guide.md")).toBe(true);
  });

  it("一致があるのに本文が渡されていない Markdown は判定できないので throw する", () => {
    expect(() => classifyFixture(undefined, new Map())).toThrow(/（文脈の判定）: Changelog 節を判定する本文が渡されていません/u);
  });

  it("見出しが見えなかったエントリを名指しする（候補でないエントリも含める。針が外れた走査を参照なしの緑へ倒さない）", () => {
    const coding = "docs/08-knowledge/playbook/coding.md";
    const without = (lines: readonly GrepLine[], needle: string): GrepLine[] =>
      lines.filter((m) => !(m.file === coding && m.line === lineOf(coding, needle)));
    const mentions = simulateGrep(LIVE_FILES, CANDIDATES);
    const headings = simulateHeadingProbe(LIVE_FILES);
    // 候補の見出しは ID の走査と probe の両方に現れる。両方から消えたときだけ未観測になる
    expect(classifyFixture(without(mentions, "### ACE-300-4:"), undefined, without(headings, "### ACE-300-4:")).unobservedHeadings)
      .toEqual(["ACE-300-4"]);
    // 候補でないエントリの見出しは probe にしか現れない
    expect(classifyFixture(mentions, undefined, without(headings, "### ACE-300-30:")).unobservedHeadings).toEqual(["ACE-300-30"]);
    expect(classifyFixture([], new Map(), []).unobservedHeadings).toEqual([...CANDIDATES, "ACE-300-30"].sort());
  });

  it("PLAYBOOK の行数を超える行番号は文脈を判定できないので throw する", () => {
    expect(() =>
      classifyFixture([{ file: "docs/08-knowledge/playbook/coding.md", line: 100000, text: "ACE-300-1" }]),
    ).toThrow(LIVE_SCAN_ERROR_PREFIX);
  });
});

describe("parseGrepRecords / buildLivePathspecs", () => {
  it("`パス\\0行\\0本文` を読み、CRLF の \\r を落とす", () => {
    expect(parseGrepRecords("docs/a.md\u00003\u0000see ACE-1-1\r\nb.sh\u000012\u0000# ACE-1-1\n")).toEqual([
      { file: "docs/a.md", line: 3, text: "see ACE-1-1" },
      { file: "b.sh", line: 12, text: "# ACE-1-1" },
    ]);
    expect(parseGrepRecords("")).toEqual([]);
  });

  it("形が崩れた出力行は捨てずに throw する（捨てると参照が消えて archive 側へ倒れる）", () => {
    expect(() => parseGrepRecords("docs/a.md:3:see ACE-1-1\n")).toThrow(LIVE_SCAN_ERROR_PREFIX);
    expect(() => parseGrepRecords("docs/a.md\u0000x\u0000see\n")).toThrow(LIVE_SCAN_ERROR_PREFIX);
  });

  it("走査面は docs/plugins/scripts と live の PLAYBOOK ファイル。退避先は外す", () => {
    expect(buildLivePathspecs(["kb/PLAYBOOK.md", "kb/playbook/coding.md"], "kb")).toEqual([
      ":(top)docs",
      ":(top)plugins",
      ":(top)scripts",
      ":(top,literal)kb/PLAYBOOK.md",
      ":(top,literal)kb/playbook/coding.md",
      ":(top,exclude,glob)kb/playbook/**/archive/**",
      ":(top,exclude,glob)kb/playbook/**/_archive/**",
    ]);
    const rootLayout = buildLivePathspecs(["PLAYBOOK.md"], "");
    expect(rootLayout[rootLayout.length - 1]).toBe(":(top,exclude,glob)playbook/**/_archive/**");
  });
});

/** git hook 経由で走ったときの GIT_DIR 等を引き継がない（runGit と同じ）。 */
function gitEnv(): NodeJS.ProcessEnv {
  return Object.fromEntries(Object.entries(process.env).filter(([key]) => !key.startsWith("GIT_")));
}

/** playbook 以外の Markdown を読む口（main は KnowledgeReadBoundary を渡す。ここは境界の検査ではない）。 */
const readFile = (file: string): string => fs.readFileSync(file, "utf8");

describe("scanLiveReferences（実 git・Issue `#2708`）", () => {
  const tempDirs: string[] = [];
  afterEach(() => {
    for (const dir of tempDirs.splice(0)) fs.rmSync(dir, { recursive: true, force: true });
  });

  function makeRepo(options: { readonly track?: (file: string) => boolean } = {}): string {
    const root = fs.mkdtempSync(path.join(os.tmpdir(), "ace-live-refs-"));
    tempDirs.push(root);
    for (const [file, content] of Object.entries({ ...LIVE_FILES, ...OFF_SURFACE_FILES })) {
      fs.mkdirSync(path.join(root, path.dirname(file)), { recursive: true });
      fs.writeFileSync(path.join(root, file), content);
    }
    execFileSync("git", ["init", "-q", root], { env: gitEnv(), stdio: "pipe" });
    const tracked = Object.keys({ ...LIVE_FILES, ...OFF_SURFACE_FILES }).filter(options.track ?? (() => true));
    execFileSync("git", ["-C", root, "add", "--", ...tracked], { env: gitEnv(), stdio: "pipe" });
    return root;
  }

  function contentsOf(root: string): Map<string, string> {
    return new Map(PLAYBOOK_FILES.map((file) => [path.join(root, file.file), file.content]));
  }

  it("走査面（archive・走査面の外を除く）の参照だけを返す", () => {
    const root = makeRepo();
    const references = scanLiveReferences({
      playbookPath: path.join(root, "docs/08-knowledge/PLAYBOOK.md"),
      playbookContents: contentsOf(root),
      candidates: CANDIDATES,
      runGit,
      readText: readFile,
    });
    expect(sortedEntries(references)).toEqual(sortedEntries(EXPECTED_REFERENCES));
  });

  it.skipIf(process.platform === "win32")("リポジトリ外を指す追跡 symlink の先は読まない", () => {
    const root = makeRepo();
    const outside = fs.mkdtempSync(path.join(os.tmpdir(), "ace-live-refs-outside-"));
    tempDirs.push(outside);
    fs.writeFileSync(path.join(outside, "secret.md"), "外部の言及: ACE-300-1\n");
    fs.symlinkSync(path.join(outside, "secret.md"), path.join(root, "docs/linked.md"));
    execFileSync("git", ["-C", root, "add", "--", "docs/linked.md"], { env: gitEnv(), stdio: "pipe" });
    const references = scanLiveReferences({
      playbookPath: path.join(root, "docs/08-knowledge/PLAYBOOK.md"),
      playbookContents: contentsOf(root),
      candidates: CANDIDATES,
      runGit,
      readText: readFile,
    });
    // symlink を足しても参照は増えない（リンク先の ACE-300-1 は出ない）
    expect(sortedEntries(references)).toEqual(sortedEntries(EXPECTED_REFERENCES));
    expect([...references.values()].flat().some((source) => source.file === "docs/linked.md")).toBe(false);
  });

  it("PLAYBOOK のカテゴリファイルが未追跡なら、針（自身の見出し）が外れて throw する", () => {
    const root = makeRepo({ track: (file) => file !== "docs/08-knowledge/playbook/coding.md" });
    expect(() =>
      scanLiveReferences({
        playbookPath: path.join(root, "docs/08-knowledge/PLAYBOOK.md"),
        playbookContents: contentsOf(root),
        candidates: CANDIDATES,
        runGit,
        readText: readFile,
      }),
    ).toThrow(/（針の照合）: 見出しを走査で拾えなかったエントリがあります.*ACE-300-1, /u);
  });

  it("候補を含まないカテゴリファイルが漏れても、そのエントリを名指しして throw する（中から候補へのリンクを黙って捨てない）", () => {
    const root = makeRepo();
    const extra = path.join(root, "docs/08-knowledge/playbook/fresh.md");
    // 候補ではない（作りたての）エントリが、候補 ACE-300-1 へリンクしている
    const extraContent = ["# PLAYBOOK — 新規 (fresh)", "", ...entry("ACE-300-20", ["関連: [ACE-300-1](coding.md#ace-300-1)"])].join("\n");
    fs.writeFileSync(extra, extraContent); // git add しない（未追跡）
    expect(() =>
      scanLiveReferences({
        playbookPath: path.join(root, "docs/08-knowledge/PLAYBOOK.md"),
        playbookContents: new Map([...contentsOf(root), [extra, extraContent]]),
        candidates: CANDIDATES,
        runGit,
        readText: readFile,
      }),
    ).toThrow(/（針の照合）: [^\n]*）: ACE-300-20$/u);
  });

  it("カテゴリファイルの一部だけが走査から漏れても、漏れた候補を名指しして throw する（全体では当たっていても通さない）", () => {
    const root = makeRepo();
    const extra = path.join(root, "docs/08-knowledge/playbook/extra.md");
    const extraContent = ["# PLAYBOOK — 追加 (extra)", "", ...entry("ACE-300-11", ["未追跡のカテゴリファイルにだけ在る。"])].join("\n");
    fs.writeFileSync(extra, extraContent); // git add しない（未追跡）
    expect(() =>
      scanLiveReferences({
        playbookPath: path.join(root, "docs/08-knowledge/PLAYBOOK.md"),
        playbookContents: new Map([...contentsOf(root), [extra, extraContent]]),
        candidates: [...CANDIDATES, "ACE-300-11"],
        runGit,
        readText: readFile,
      }),
    ).toThrow(/（針の照合）: [^\n]*）: ACE-300-11$/u);
  });

  it("git で追跡されていない PLAYBOOK（リポジトリの外・未追跡）では走査不能として throw する", () => {
    // 一時ディレクトリの祖先にリポジトリがあれば rev-parse は通るが、PLAYBOOK が追跡されて
    // いないので針が外れる。どちらの経路でも「参照なし」の緑にはならない。
    const root = fs.mkdtempSync(path.join(os.tmpdir(), "ace-live-refs-nogit-"));
    tempDirs.push(root);
    fs.mkdirSync(path.join(root, "docs/08-knowledge/playbook"), { recursive: true });
    fs.writeFileSync(path.join(root, "docs/08-knowledge/PLAYBOOK.md"), PLAYBOOK_MAIN);
    expect(() =>
      scanLiveReferences({
        playbookPath: path.join(root, "docs/08-knowledge/PLAYBOOK.md"),
        playbookContents: new Map([[path.join(root, "docs/08-knowledge/PLAYBOOK.md"), PLAYBOOK_MAIN]]),
        candidates: ["ACE-300-1"],
        runGit,
        readText: readFile,
      }),
    ).toThrow(/（リポジトリの特定）|（針の照合）/u);
  });
});

describe("scanLiveReferences の git 失敗（読めない入力を参照なしへ倒さない）", () => {
  const root = fs.realpathSync.native(os.tmpdir());
  const request = (fake: GitRunner) => ({
    playbookPath: path.join(root, "PLAYBOOK.md"),
    playbookContents: new Map<string, string>(),
    candidates: ["ACE-300-1"],
    runGit: fake,
    readText: (): string => {
      throw new Error("本文は読まない想定");
    },
  });
  const revParseOk = (rest: GitRunner): GitRunner => (repoDir, args, input) =>
    args[0] === "rev-parse" ? { status: 0, stdout: `${root}\n`, stderr: "" } : rest(repoDir, args, input);

  // 期待する理由まで照合する。接頭辞だけだと、失敗を空出力へ倒す変異でも後段の針（自身の見出し）
  // が throw して緑のまま通り、git の結果の検査が効いているかを測れない。
  it.each<[string, GitRunResult, RegExp]>([
    ["rc=128", { status: 128, stdout: "", stderr: "" }, /（ID の走査）: git が rc=128 で終了しました/u],
    ["シグナル終了", { status: null, stdout: "", stderr: "" }, /（ID の走査）: git が rc=null で終了しました/u],
    ["stderr への出力（rc=0）", { status: 0, stdout: "", stderr: "warning: something\n" }, /（ID の走査）: git が診断を出力しました: warning: something/u],
    ["stderr への出力（rc=1）", { status: 1, stdout: "", stderr: "fatal: bad pathspec\n" }, /（ID の走査）: git が診断を出力しました: fatal: bad pathspec/u],
    ["git を起動できない", { status: null, stdout: "", stderr: "", error: new Error("spawn git ENOENT") }, /（ID の走査）: git を起動できません: spawn git ENOENT/u],
  ])("ID の走査が %s なら理由を名指しして throw する", (_label, result, reason) => {
    expect(() => scanLiveReferences(request(revParseOk(() => result)))).toThrow(reason);
  });

  it("rev-parse が失敗したら throw する", () => {
    expect(() => scanLiveReferences(request(() => ({ status: 128, stdout: "", stderr: "fatal: not a git repository\n" }))))
      .toThrow(/（リポジトリの特定）: git が診断を出力しました: fatal: not a git repository/u);
  });

  it("Changelog 節の判定に要る Markdown の本文を読めなければ throw する", () => {
    const mention = `docs/x.md\u00001\u0000ACE-300-1\n`;
    const fake = revParseOk(() => ({ status: 0, stdout: mention, stderr: "" }));
    const failingRead = (): string => {
      throw new Error("knowledge-read: read-unverifiable");
    };
    expect(() => scanLiveReferences({ ...request(fake), readText: failingRead }))
      .toThrow(/（本文の読み込み）: docs\/x\.md: knowledge-read: read-unverifiable/u);
  });

  it("リポジトリ直下のパスを解決できなければ、git の不在ではなく走査不能として名指す", () => {
    const missing = path.join(root, "ace-live-refs-no-such-dir", "nested");
    const fake: GitRunner = () => ({ status: 0, stdout: `${missing}\n`, stderr: "" });
    expect(() => scanLiveReferences(request(fake))).toThrow(/（リポジトリの特定）: パスを解決できません/u);
  });

  it("候補に一致しない Markdown の本文は読まない（native Windows で ACL 検査を数百回立てない）", () => {
    const main = path.join(root, "PLAYBOOK.md");
    const out = `PLAYBOOK.md\u00001\u0000### ACE-300-1: 候補\ndocs/y.md\u00003\u0000関連: ACE-999-1\n`;
    const fake = revParseOk(() => ({ status: 0, stdout: out, stderr: "" }));
    // request() の readText は呼ばれたら throw する
    const references = scanLiveReferences({
      ...request(fake),
      playbookContents: new Map([[main, "### ACE-300-1: 候補\n"]]),
    });
    expect(references.size).toBe(0);
  });

  it("候補が 0 件なら git を呼ばない", () => {
    let called = 0;
    const fake: GitRunner = () => {
      called += 1;
      return { status: 128, stdout: "", stderr: "" };
    };
    expect(scanLiveReferences({ ...request(fake), candidates: [] }).size).toBe(0);
    expect(called).toBe(0);
  });
});
