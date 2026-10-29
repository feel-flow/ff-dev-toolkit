import { afterEach, describe, expect, it, vi } from "vitest";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { execFileSync } from "node:child_process";
import { KnowledgeReadBoundary, KNOWLEDGE_READ_MAX_BYTES, inspectDarwinReadAcl, inspectWindowsReadAcl, knowledgeReaderForSelection } from "./knowledge-read-boundary.js";
import { main as categoryMain } from "./check-category-size";
import { main as entryMain, parseAllowlist } from "./check-entry-format";
import { main as archiveMain } from "./check-archive-links";
import { main as reuseMain } from "./ace-reuse-report";
import { main as refineMain } from "./ace-refine-report";
import { main as abstractionMain } from "./ace-abstraction-report";
import { main as invariantsMain } from "./check-refine-invariants";
import { main as syncMain } from "./sync-playbook-frontmatter";
import { selectChangelog } from "./changelog-layout";

const owned: string[] = [];
const originalArgv = process.argv;
afterEach(() => {
  process.argv = originalArgv;
  vi.restoreAllMocks();
  vi.unstubAllEnvs();
  for (const dir of owned.splice(0)) fs.rmSync(dir, { recursive: true, force: true });
});

describe.skipIf(process.platform === 'win32')('ACE filesystem caller boundary census', () => {
  const callers = [
    ['check-category-size', 'category', (file: string) => categoryMain()],
    ['check-entry-format', 'allowlist', (file: string) => entryMain()],
    ['check-archive-links', 'archive', (file: string) => archiveMain()],
    ['ace-reuse-report', 'category', (file: string) => reuseMain([file])],
    ['ace-refine-report', 'category', (file: string) => refineMain([file])],
    ['ace-abstraction-report', 'category', (file: string) => abstractionMain([file])],
    ['check-refine-invariants', 'category', (file: string) => invariantsMain()],
    ['sync-playbook-frontmatter', 'category', (file: string) => syncMain()],
    ['changelog-layout', 'changelog', (file: string) => { selectChangelog(file); return 0; }],
  ] as const;
  it('covers every filesystem consumer rather than an empty selected set', () => {
    expect(callers.map(([name]) => name)).toEqual(['check-category-size', 'check-entry-format', 'check-archive-links', 'ace-reuse-report', 'ace-refine-report', 'ace-abstraction-report', 'check-refine-invariants', 'sync-playbook-frontmatter', 'changelog-layout']);
  });
  function assertCallerRefuses(kind: string, invoke: (file: string) => number, mainEscape = false): void {
    const f = fixture();
    vi.spyOn(process, 'cwd').mockReturnValue(f.project);
    vi.stubEnv('ACE_PATTERNS_PATH', ''); vi.stubEnv('ACE_LEGACY_FORMAT_ALLOWLIST', '');
    const knowledge = path.join(f.project, 'docs/08-knowledge');
    fs.mkdirSync(path.join(knowledge, 'playbook/archive'), { recursive: true });
    const main = path.join(knowledge, 'PLAYBOOK.md');
    if (mainEscape) fs.symlinkSync(f.outside, main);
    else fs.writeFileSync(main, '## エントリ一覧\n\n## Changelog\n');
    const relative = kind === 'allowlist' ? 'legacy-format-allowlist.txt' : kind === 'archive' ? 'playbook/archive/coding.md' : kind === 'changelog' ? 'CHANGELOG.md' : 'playbook/coding.md';
    if (!mainEscape) fs.symlinkSync(f.outside, path.join(knowledge, relative));
    process.argv = ['node', 'caller.ts', main];
    const logs = vi.spyOn(console, 'log').mockImplementation(() => {});
    const errors = vi.spyOn(console, 'error').mockImplementation(() => {});
    vi.spyOn(console, 'warn').mockImplementation(() => {});
    let code = 0;
    try { code = invoke(main); }
    catch (error) { code = 2; console.error(error instanceof Error ? error.message : String(error)); }
    expect(code).not.toBe(0);
    const output = [...logs.mock.calls, ...errors.mock.calls].flat().join('\n');
    expect(output).toContain('knowledge-read: outside-authority');
    expect(output).not.toContain('synthetic-private-canary');
  }
  it.each(callers)('%s refuses a discovered external %s before analysis', (_name, kind, invoke) => {
    assertCallerRefuses(kind, invoke);
  });
  it.each(callers)('%s refuses an in-project main operand that redirects outside', (_name, kind, invoke) => {
    assertCallerRefuses(kind, invoke, true);
  });
  it('recognizes the independent Git project when invoked from a subdirectory', () => {
    const f = fixture(), child = path.join(f.project, 'tools'); fs.mkdirSync(child);
    execFileSync('git', ['init', '-q', f.project], { stdio: 'pipe' });
    vi.spyOn(process, 'cwd').mockReturnValue(child);
    const reader = knowledgeReaderForSelection(f.file);
    expect(reader.projectRoot).toBe(f.project);
    expect(reader.read(f.file)).toContain('# Book');
    fs.symlinkSync(f.outside, path.join(f.project, 'implicit.md'));
    expect(() => knowledgeReaderForSelection(path.join(f.project, 'implicit.md')).read(path.join(f.project, 'implicit.md'))).toThrow('outside-authority');
  });
  it('an in-project explicit file setting does not grant its external target', () => {
    const f = fixture(); vi.spyOn(process, 'cwd').mockReturnValue(f.project);
    const alias = path.join(f.project, 'allowlist.txt'); fs.symlinkSync(f.outside, alias);
    expect(() => knowledgeReaderForSelection(f.file, [alias]).read(alias)).toThrow('outside-authority');
    expect(knowledgeReaderForSelection(f.file, [f.outside]).read(f.outside)).toBe('synthetic-private-canary');
  });
  it('refuses invalid allowlist text without echoing its value', () => {
    expect(() => parseAllowlist('synthetic-private-canary')).toThrow('ID を認識できません');
    try { parseAllowlist('synthetic-private-canary'); }
    catch (error) { expect(String(error)).not.toContain('synthetic-private-canary'); }
  });
});
function fixture() {
  const top = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), "ff-read-boundary-")));
  owned.push(top);
  const project = path.join(top, "project");
  const external = path.join(top, "shared");
  fs.mkdirSync(project, { mode: 0o700 }); fs.mkdirSync(external, { mode: 0o700 });
  const file = path.join(project, "book.md"), outside = path.join(external, "canary.md");
  fs.writeFileSync(file, "# Book" + String.fromCharCode(10));
  fs.writeFileSync(outside, "synthetic-private-canary");
  return { top, project, external, file, outside };
}

describe.skipIf(process.platform === "win32")("protected POSIX knowledge snapshots", () => {
  it("preserves UTF-8, CRLF and trailing newlines", () => {
    const f = fixture(), text = "知識" + String.fromCharCode(13, 10, 10);
    fs.writeFileSync(f.file, text);
    expect(new KnowledgeReadBoundary(f.project).read(f.file)).toBe(text);
  });
  it("retains in-root file and parent links", () => {
    const f = fixture(), target = path.join(f.project, "inside"); fs.mkdirSync(target);
    fs.writeFileSync(path.join(target, "real.md"), "normal");
    fs.symlinkSync(target, path.join(f.project, "alias"));
    fs.symlinkSync(path.join(target, "real.md"), path.join(f.project, "link.md"));
    const read = new KnowledgeReadBoundary(f.project);
    expect(read.read(path.join(f.project, "link.md"))).toBe("normal");
    expect(read.read(path.join(f.project, "alias", "real.md"))).toBe("normal");
  });
  it("rejects implicit external file and intermediate links without reading", () => {
    const f = fixture(); fs.symlinkSync(f.outside, path.join(f.project, "link.md"));
    fs.symlinkSync(f.external, path.join(f.project, "alias"));
    const read = new KnowledgeReadBoundary(f.project), spy = vi.spyOn(fs, "readSync");
    expect(() => read.read(path.join(f.project, "link.md"))).toThrow("outside-authority");
    expect(() => read.read(path.join(f.project, "alias", "canary.md"))).toThrow("outside-authority");
    expect(spy).not.toHaveBeenCalled();
  });
  it("supports an exact explicit root and rejects its prefix sibling", () => {
    const f = fixture(), sibling = f.external + "-other"; fs.mkdirSync(sibling); fs.writeFileSync(path.join(sibling, "no.md"), "not-approved");
    const read = new KnowledgeReadBoundary(f.project, { explicitRoots: [f.external] });
    expect(read.read(f.outside)).toBe("synthetic-private-canary");
    expect(() => read.read(path.join(sibling, "no.md"))).toThrow("outside-authority");
    fs.symlinkSync(path.join(sibling, "no.md"), path.join(f.external, "escape.md"));
    expect(() => read.read(path.join(f.external, "escape.md"))).toThrow("outside-authority");
  });
  it("an explicit file grant does not grant its siblings", () => {
    const f = fixture(); fs.writeFileSync(path.join(f.external, "other.md"), "other");
    const read = new KnowledgeReadBoundary(f.project, { explicitFiles: [f.outside] });
    expect(read.read(f.outside)).toBe("synthetic-private-canary");
    expect(() => read.read(path.join(f.external, "other.md"))).toThrow("outside-authority");
  });
  it("rejects dangling links, directories and hardlinks", () => {
    const f = fixture(), read = new KnowledgeReadBoundary(f.project);
    fs.symlinkSync(path.join(f.external, "absent"), path.join(f.project, "dangling.md"));
    expect(() => read.read(path.join(f.project, "dangling.md"))).toThrow("unresolvable-input");
    expect(() => read.read(f.project)).toThrow("nonregular-input");
    fs.linkSync(f.file, path.join(f.project, "hard.md"));
    expect(() => read.read(f.file)).toThrow("hardlinked-input");
  });
  it("rejects a FIFO before any open or blocking read", () => {
    const f = fixture(), fifo = path.join(f.project, "pipe.md"); execFileSync("mkfifo", [fifo]);
    const read = new KnowledgeReadBoundary(f.project), spy = vi.spyOn(fs, "openSync");
    expect(() => read.read(fifo)).toThrow("nonregular-input");
    expect(spy).not.toHaveBeenCalled();
  });
  it("accepts the byte limit and refuses limit+1", () => {
    const f = fixture(); fs.writeFileSync(f.file, Buffer.alloc(KNOWLEDGE_READ_MAX_BYTES, 65));
    expect(new KnowledgeReadBoundary(f.project).read(f.file).length).toBe(KNOWLEDGE_READ_MAX_BYTES);
    fs.appendFileSync(f.file, "B");
    expect(() => new KnowledgeReadBoundary(f.project).read(f.file)).toThrow("input-too-large");
  });
  it("rejects NUL and malformed UTF-8 without truncating", () => {
    const f = fixture(); fs.writeFileSync(f.file, Buffer.from([65, 0, 66]));
    expect(() => new KnowledgeReadBoundary(f.project).read(f.file)).toThrow("nul-input");
    fs.writeFileSync(f.file, Buffer.from([255, 254]));
    expect(() => new KnowledgeReadBoundary(f.project).read(f.file)).toThrow("invalid-text");
  });
  it("reuses one accepted snapshot without reopening its source", () => {
    const f = fixture(), read = new KnowledgeReadBoundary(f.project), spy = vi.spyOn(fs, "openSync");
    expect(read.read(f.file)).toBe("# Book" + String.fromCharCode(10));
    expect(read.read(f.file)).toBe("# Book" + String.fromCharCode(10));
    expect(spy).toHaveBeenCalledTimes(1);
  });
  it("refuses an observed change before reusing accepted bytes", () => {
    const f = fixture(), read = new KnowledgeReadBoundary(f.project); read.read(f.file);
    fs.writeFileSync(f.file, "changed source");
    expect(() => read.read(f.file)).toThrow("input-changed");
  });
  it("a controlled same-UID replacement between metadata and open releases no bytes", () => {
    const f = fixture(), read = new KnowledgeReadBoundary(f.project), original = fs.openSync;
    let swapped = false;
    vi.spyOn(fs, "openSync").mockImplementation((file, flags, mode) => {
      if (file === f.file && !swapped) {
        swapped = true; fs.renameSync(f.file, f.file + ".old"); fs.writeFileSync(f.file, "replacement");
      }
      return original(file, flags, mode);
    });
    const bytes = vi.spyOn(fs, "readSync");
    expect(() => read.read(f.file)).toThrow("input-changed");
    expect(swapped).toBe(true); expect(bytes).not.toHaveBeenCalled();
  });
  it("refuses a short/error read with a fixed non-content diagnostic", () => {
    const f = fixture(), read = new KnowledgeReadBoundary(f.project);
    vi.spyOn(fs, "readSync").mockImplementation(() => { throw new Error("synthetic-private-canary"); });
    expect(() => read.read(f.file)).toThrow("knowledge-read: read-unverifiable");
  });
  it("allows lower write bits behind a private outer parent, but not a reachable writable ancestor", () => {
    const f = fixture(); fs.chmodSync(f.project, 0o775);
    expect(new KnowledgeReadBoundary(f.project).read(f.file)).toBe("# Book" + String.fromCharCode(10));
    const reachable = fs.mkdtempSync(path.join(fs.realpathSync("/tmp"), "ff-read-shared-")); owned.push(reachable);
    fs.chmodSync(reachable, 0o777); const child = path.join(reachable, "project"); fs.mkdirSync(child, { mode: 0o700 });
    expect(() => new KnowledgeReadBoundary(child)).toThrow("replaceable-storage");
  });
  // Register native ACL coverage only where it can run; developer layouts reject every skip.
  if (process.platform === "darwin") {
    it("checks actual Darwin read-only/write ACLs without changing the parent", () => {
      const f = fixture();
      execFileSync("/bin/chmod", ["+a", "everyone allow read,readattr,readextattr,readsecurity,search", f.project]);
      const acl = () => execFileSync("/bin/ls", ["-ldeb", "--", f.project], { encoding: "utf8" });
      const before = acl(); expect(new KnowledgeReadBoundary(f.project).read(f.file)).toBe("# Book" + String.fromCharCode(10));
      expect(acl()).toBe(before);
      execFileSync("/bin/chmod", ["+a", "everyone allow write,add_file", f.project]);
      expect(() => new KnowledgeReadBoundary(f.project)).toThrow("additional-write-grant");
    });
  }
});

describe("ACL capability evidence", () => {
  it("refuses unknown/empty Darwin metadata", () => {
    expect(() => inspectDarwinReadAcl("")).toThrow("read-unverifiable");
    expect(() => inspectDarwinReadAcl("drwx------+ metadata")).toThrow("read-unverifiable");
    expect(inspectDarwinReadAcl("drwx------  metadata")).toBe(false);
    expect(inspectDarwinReadAcl("drwx------+ metadata" + String.fromCharCode(10) + " 0: group:everyone allow read,search")).toBe(true);
  });
  it("does not accept missing, duplicate or unsafe native Windows result frames", () => {
    expect(() => inspectWindowsReadAcl("0|1|0" + String.fromCharCode(13, 10) + "1|1|0", 2)).not.toThrow();
    for (const output of ["", "0|1|0", "0|1|0" + String.fromCharCode(10) + "0|1|0", "0|0|0" + String.fromCharCode(10) + "1|1|0", "0|1|1" + String.fromCharCode(10) + "1|1|0"]) {
      expect(() => inspectWindowsReadAcl(output, 2)).toThrow("read-unverifiable");
    }
    expect(() => inspectWindowsReadAcl("", 0)).toThrow("read-unverifiable");
  });
});
