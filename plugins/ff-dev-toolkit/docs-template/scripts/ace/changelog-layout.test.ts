import { afterEach, describe, expect, it } from "vitest";
import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";
import { parseHistory, scanChangelog, selectChangelog } from "./changelog-layout";

const roots: string[] = [];
afterEach(() => { for (const root of roots.splice(0)) fs.rmSync(root, { recursive: true, force: true }); });
const canonical = ["## Changelog", "", "### [1.2.0] - 2026-10-25", "#### 追加", "- ACE-1-1: summary"].join("\n");
function fixture(main = "# PLAYBOOK") {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "ace-history-layout-")); roots.push(root);
  const book = path.join(root, "PLAYBOOK.md"); fs.writeFileSync(book, main);
  const write = (file: string, text: string) => {
    const target = path.join(root, file); fs.mkdirSync(path.dirname(target), { recursive: true }); fs.writeFileSync(target, text); return target;
  };
  return { root, book, write };
}

describe("fixed Changelog selection", () => {
  it("keeps a main history ahead of both external candidates", () => {
    const f = fixture(canonical); f.write("CHANGELOG.md", "unknown"); f.write("playbook/CHANGELOG.md", "unknown");
    expect(selectChangelog(f.book).path).toBe(f.book);
  });
  for (const candidate of ["CHANGELOG.md", "playbook/CHANGELOG.md"]) {
    it(`reads the fixed candidate ${candidate} from an absent or link-only main`, () => {
      for (const main of ["# PLAYBOOK", "## Changelog\n[履歴](CHANGELOG.md)"]) {
        const f = fixture(main); const target = f.write(candidate, canonical);
        const selected = selectChangelog(f.book);
        expect(selected.path).toBe(target); expect(selected.scan.headings[0].version).toBe("1.2.0");
      }
    });
  }
  it("does not hide broken main Helpful rows behind a valid external file", () => {
    const f = fixture("## Changelog\n- Helpful +1: ACE-1-1 / ACE-1-2（理由）"); f.write("CHANGELOG.md", canonical);
    expect(selectChangelog(f.book).path).toBe(f.book);
  });
  it("rejects two candidates even when only one has a readable history", () => {
    const f = fixture(); f.write("CHANGELOG.md", canonical); f.write("playbook/CHANGELOG.md", "");
    expect(() => selectChangelog(f.book)).toThrow("候補が複数");
  });
  it("rejects empty, unreadable and directory candidates", () => {
    const empty = fixture(); empty.write("CHANGELOG.md", ""); expect(() => selectChangelog(empty.book)).toThrow();
    const unreadable = fixture(); const file = unreadable.write("CHANGELOG.md", canonical); fs.chmodSync(file, 0);
    try { expect(() => selectChangelog(unreadable.book)).toThrow(); } finally { fs.chmodSync(file, 0o644); }
    const directory = fixture(); fs.mkdirSync(path.join(directory.root, "CHANGELOG.md")); expect(() => selectChangelog(directory.book)).toThrow();
  });
  it('accepts a safe in-area symlink candidate', () => {
    const linked = fixture(); linked.write('history.md', canonical); fs.symlinkSync('history.md', path.join(linked.root, 'CHANGELOG.md'));
    expect(selectChangelog(linked.book).text).toBe(canonical);
  });
  it("does not hide arbitrary text in the main Changelog with an external file", () => {
    const f = fixture("## Changelog\nunknown history"); f.write("CHANGELOG.md", canonical);
    expect(selectChangelog(f.book).path).toBe(f.book);
  });
  // Issue `#2587`: 導入先の実配置（説明文つきの誘導スタブ + `## Changelog` を持たない分割 CHANGELOG）。
  const proseStub = ["# PLAYBOOK", "", "## Changelog", "",
    "> **Changelog 本体は [playbook/CHANGELOG.md](playbook/CHANGELOG.md) へ移動した**。",
    "> このセクションは誘導スタブであり、**バージョン記録を持たない — ここに版を追記しない**。", "",
    "- 現行: [playbook/CHANGELOG.md](./playbook/CHANGELOG.md#top \"履歴\")",
    "- 過去分: [playbook/CHANGELOG-archive-1.65.0-1.115.0.md](playbook/CHANGELOG-archive-1.65.0-1.115.0.md)（凍結）"].join("\n");
  const headingless = ["# ACE Playbook Changelog", "", "### [1.158.0] - 2026-11-02", "", "#### 追加", "", "- ACE-9-1: summary",
    "", "### [1.157.0] - 2026-11-01", "", "#### カウンター更新", "", "- ACE-1-1: Helpful +1（理由）"].join("\n");
  it("hands a prose stub over to the fixed candidate it links to, and reads a heading-less candidate", () => {
    const f = fixture(proseStub); const target = f.write("playbook/CHANGELOG.md", headingless);
    const selected = selectChangelog(f.book);
    expect(selected.path).toBe(target);
    expect(selected.scan.headings.map((h) => h.version)).toEqual(["1.158.0", "1.157.0"]);
    const parsed = parseHistory(f.book);
    expect(parsed.versions.map((v) => [v.version, v.added.length, v.helpful.length])).toEqual([["1.158.0", 1, 0], ["1.157.0", 0, 1]]);
  });
  it.each([
    ["a link to a file that is not a fixed candidate", "## Changelog\n履歴は [別の場所](docs/history.md) へ移した。"],
    ["a candidate link next to a history-like row", `${proseStub}\n- ACE-1-1: 本体に残った行`],
    ["a candidate link next to a broken Helpful row", `${proseStub}\n- Helpful +1: ACE-1-1 / ACE-1-2（理由）`],
  ])("keeps the main Changelog when the stub has %s", (_label, main) => {
    const f = fixture(main); f.write("playbook/CHANGELOG.md", headingless);
    expect(selectChangelog(f.book).path).toBe(f.book);
  });
  it.each([
    ["a ./ prefix, a fragment and a title", ["## Changelog", "> 履歴は [分割先](./playbook/CHANGELOG.md#top '履歴') へ移した。"]],
    ["a link-only line next to prose", ["## Changelog", "履歴は分割した。", "[playbook/CHANGELOG.md](playbook/CHANGELOG.md)"]],
    ["history-like text quoted as inline code", ["## Changelog", "> 履歴（`Helpful +1` と `- ACE-1-1: 例`）は [分割先](playbook/CHANGELOG.md) へ移した。"]],
  ] as [string, string[]][])("hands the stub over when its only candidate link has %s", (_label, main) => {
    const f = fixture(main.join(String.fromCharCode(10))); const target = f.write("playbook/CHANGELOG.md", headingless);
    expect(selectChangelog(f.book).path).toBe(target);
  });
  it("keeps the main Changelog when the candidate link is only quoted as inline code", () => {
    const f = fixture(["## Changelog", "- 現行: `[history](playbook/CHANGELOG.md)` と書いていた。"].join(String.fromCharCode(10))); f.write("playbook/CHANGELOG.md", headingless);
    expect(selectChangelog(f.book).path).toBe(f.book);
  });
  it("does not read a heading-less candidate behind another level-2 heading, nor a heading-less main", () => {
    const blocked = fixture(); blocked.write("CHANGELOG.md", headingless.replace("# ACE Playbook Changelog", "## Notes"));
    expect(() => selectChangelog(blocked.book)).toThrow("版を読めません");
    const dateless = fixture(); dateless.write("CHANGELOG.md", "# History\n### [1.0.0]\n#### 追加\n- ACE-1-1: summary");
    expect(() => selectChangelog(dateless.book)).toThrow("版を読めません");
    expect(selectChangelog(fixture(headingless).book).scan.kind).toBe("absent");
    expect(scanChangelog(headingless).kind).toBe("absent");
    expect(scanChangelog(headingless, { headingless: true }).kind).toBe("found");
  });
  it("rejects a parent-directory symlink that leads outside the book area", () => {
    const f = fixture(); const outside = fixture(); outside.write("CHANGELOG.md", canonical);
    fs.symlinkSync(outside.root, path.join(f.root, "playbook")); expect(() => selectChangelog(f.book)).toThrow("outside-authority");
  });
  it("preserves missing and empty main states for the calling gate", () => {
    expect(selectChangelog(fixture().book).scan.kind).toBe("absent");
    expect(selectChangelog(fixture("## Changelog").book).scan.kind).toBe("empty");
  });
});

describe("history metadata", () => {
  it("reads only the confirmed legacy version heading grammar", () => {
    const old = ["## v4.300.0 (2026-10-25)", "- 追加: ACE-1-1（testing）", "## v4.299.0 (2026-10-24)", "- 更新: ACE-1-1 Helpful +1（理由）"].join("\n");
    expect(scanChangelog(old).headings.map((h) => [h.version, h.date, h.format])).toEqual([["4.300.0", "2026-10-25", "legacy"], ["4.299.0", "2026-10-24", "legacy"]]);
    expect(scanChangelog("## vunknown (2026-10-25)").kind).toBe("absent");
  });
  it("excludes frontmatter, fenced examples, HTML comments and following sections", () => {
    const text = ["---", "example: |", "  ## Changelog", "---", "```md", canonical, "```", "<!--", canonical, "-->", canonical, "## Other", "### [9.9.9] - 2026-10-25"].join("\n");
    expect(scanChangelog(text).headings.map((h) => h.version)).toEqual(["1.2.0"]);
  });
  it("preserves the synchronizer's date-less canonical version metadata", () => {
    expect(scanChangelog("## Changelog\n### [1.0.0]").headings[0]).toMatchObject({ version: "1.0.0", date: null });
  });
});

describe("history rows", () => {
  const lf = String.fromCharCode(10);
  const hash = String.fromCharCode(35);
  it("normalizes the observed legacy added list and Helpful reason", () => {
    const f = fixture();
    f.write("CHANGELOG.md", ["## v4.300.0 (2026-10-25)", `- 追加: ACE-1-1（testing）、ACE-1-2（coding）（PR ${hash}12）`, `- 更新: ACE-1-1 Helpful +1 ×2（同じ操作 / PR ${hash}13）`].join(lf));
    const parsed = parseHistory(f.book);
    expect(parsed.versions[0].added.map((item) => [item.id, item.pr])).toEqual([["ACE-1-1", 12], ["ACE-1-2", 12]]);
    expect(parsed.versions[0].helpful).toEqual([{ id: "ACE-1-1", reason: `同じ操作 / PR ${hash}13` }]);
  });
  it("rejects bundled IDs, zero repetitions and missing reasons in either grammar", () => {
    for (const format of ["canonical", "legacy"]) {
      const base = format === "canonical" ? canonical + lf + "#### カウンター更新" : "## v1.2.0 (2026-10-25)";
      const prefix = format === "canonical" ? "- " : "- 更新: ";
      const middle = format === "canonical" ? ": " : " ";
      for (const bad of ["ACE-1-1/ACE-1-2" + middle + "Helpful +1（理由）", "ACE-1-1" + middle + "Helpful +1 ×0（理由）", "ACE-1-1" + middle + "Helpful +1"]) {
        const f = fixture(base + lf + prefix + bad);
        expect(parseHistory(f.book).unreadableHelpful).toHaveLength(1);
      }
    }
  });
  it("reports the selected external file's actual line", () => {
    const f = fixture(); const selected = f.write("playbook/CHANGELOG.md", ["## v1.2.0 (2026-10-25)", "- 更新: ACE-1-1 / ACE-1-2 Helpful +1（理由）"].join(lf));
    expect(parseHistory(f.book).unreadableHelpful[0]).toContain(selected + ":2:");
  });
  it("does not accept an unknown legacy added list", () => {
    const f = fixture(["## v1.2.0 (2026-10-25)", "- 追加: unknown"].join(lf));
    expect(() => parseHistory(f.book)).toThrow("追加行を読めません");
  });
  it.each(["- 追加:", "- 追加: ", "- 追加:ACE-0-2（testing）"])("rejects a malformed known added prefix: %s", (row) => {
    const f = fixture(["## v1.0.0 (2026-10-25)", "- 追加: ACE-0-1（testing）", row].join("\n"));
    expect(() => parseHistory(f.book)).toThrow("追加行を読めません");
  });
  it("preserves the row scope across a metadata-only date-less heading", () => {
    const f = fixture([canonical, "### [2.0.0]", "#### カウンター更新", "- Helpful +1: ACE-0-1 / ACE-0-2（invalid）"].join("\n"));
    expect(scanChangelog(fs.readFileSync(f.book, "utf8")).headings.map((h) => h.version)).toEqual(["1.2.0", "2.0.0"]);
    expect(parseHistory(f.book).versions.map((v) => v.version)).toEqual(["1.2.0"]);
    expect(parseHistory(f.book).unreadableHelpful).toHaveLength(1);
  });
  it("recognizes spaced metadata for sync while retaining the existing row heading grammar", () => {
    const f = fixture(canonical.replace("### [", "###  ["));
    expect(selectChangelog(f.book).scan.headings[0].version).toBe("1.2.0");
    expect(parseHistory(f.book).versions).toEqual([]);
  });
});
