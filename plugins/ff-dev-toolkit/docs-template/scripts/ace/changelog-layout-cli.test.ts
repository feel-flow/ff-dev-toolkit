import { afterEach, describe, expect, it } from "vitest";
import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";
import { main } from "./sync-playbook-frontmatter";
import { parseHistory } from "./changelog-layout";

const roots: string[] = [];
afterEach(() => { for (const root of roots.splice(0)) fs.rmSync(root, { recursive: true, force: true }); });
function fixture(location: string, legacy: boolean) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "history-cli-")); roots.push(root);
  fs.mkdirSync(path.join(root, "playbook"));
  const book = path.join(root, "PLAYBOOK.md");
  const history = path.join(root, location);
  const content = `---
version: "1.3.0"
ace_entry_count: 0
updated: "2026-01-01"
---
# Playbook
## Changelog
[history](CHANGELOG.md)
`;
  fs.writeFileSync(book, content);
  fs.writeFileSync(history, legacy ? "## v1.3.0 (2026-01-01)" : "## Changelog\n### [1.3.0] - 2026-01-01");
  return { root, book, history, content };
}
function run(book: string) {
  const log = console.log; const error = console.error; const lines: string[] = [];
  console.log = console.error = (...args: unknown[]) => { lines.push(args.map(String).join(" ")); };
  try { return { rc: main(["node", "sync", book, "--write"]), output: lines.join("\n") }; }
  finally { console.log = log; console.error = error; }
}
describe("selected Changelog CLI", () => {
  for (const location of ["CHANGELOG.md", "playbook/CHANGELOG.md"]) {
    for (const legacy of [false, true]) {
      it(`sync reads ${location} / legacy=${legacy} and reports actual path`, () => {
        const f = fixture(location, legacy);
        const result = run(f.book);
        expect(result.rc).toBe(0);
        expect(result.output).toContain(f.history);
        expect(result.output).toContain(`（${location}）`);
      });
    }
  }
  for (const bad of ["ambiguous", "empty", "symlink", "unreadable"]) {
    it(`${bad} cannot write the PLAYBOOK`, () => {
      const f = fixture("CHANGELOG.md", false);
      if (bad === "ambiguous") fs.writeFileSync(path.join(f.root, "playbook/CHANGELOG.md"), "");
      if (bad === "empty") fs.writeFileSync(f.history, "");
      if (bad === "symlink") {
        const external = fs.mkdtempSync(path.join(os.tmpdir(), 'history-external-')); roots.push(external);
        const target = path.join(external, 'private.md'); fs.renameSync(f.history, target); fs.symlinkSync(target, f.history);
      }
      if (bad === "unreadable") fs.chmodSync(f.history, 0);
      try { expect(run(f.book).rc).toBe(2); expect(fs.readFileSync(f.book, "utf8")).toBe(f.content); }
      finally { if (bad === "unreadable") fs.chmodSync(f.history, 0o644); }
    });
  }
  it('safe in-area linked history remains usable for a normal sync', () => {
    const f = fixture('CHANGELOG.md', false);
    fs.renameSync(f.history, `${f.history}.real`); fs.symlinkSync(`${f.history}.real`, f.history);
    expect(run(f.book).rc).toBe(0);
  });
  it("unclosed fence cannot hide invalid history behind a fallback", () => {
    const f = fixture("CHANGELOG.md", false);
    fs.appendFileSync(f.book, "\n```md\nbroken");
    expect(() => parseHistory(f.book)).toThrow("フェンス");
    expect(run(f.book).rc).toBe(2);
  });
});
