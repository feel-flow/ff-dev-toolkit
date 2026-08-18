import { describe, it, expect, beforeAll, afterAll } from 'vitest';
import fs from 'fs';
import os from 'os';
import path from 'path';
import url from 'url';
import { buildDocsState, listMarkdown, resolveWithinRoot, resolveDocsPath } from '../src/indexer.js';

const __dirname = path.dirname(url.fileURLToPath(import.meta.url));
const PROJECT_FIXTURE = path.resolve(__dirname, 'fixtures/project');

describe('buildDocsState', () => {
  const state = buildDocsState(PROJECT_FIXTURE);

  it('indexes only markdown files under docs/', () => {
    expect(state.mdFiles.length).toBeGreaterThan(0);
    for (const f of state.mdFiles) {
      expect(f.startsWith(path.join(PROJECT_FIXTURE, 'docs'))).toBe(true);
      expect(f.endsWith('.md')).toBe(true);
    }
  });

  it('builds a section-level search index with project-root-relative paths', () => {
    expect(state.searchIndex.length).toBeGreaterThan(state.mdFiles.length - 1);
    for (const entry of state.searchIndex) {
      expect(entry.file.startsWith('docs/')).toBe(true);
      expect(path.isAbsolute(entry.file)).toBe(false);
    }
  });

  it('indexes specs with frontmatter metadata', () => {
    const spec = state.specIndex.specs.find((s) => s.specId === 'SPEC-001');
    expect(spec).toBeDefined();
    expect(spec!.title).toBe('Auth Flow Spec');
    expect(spec!.status).toBe('draft');
    expect(spec!.tags).toEqual(['auth', 'security']);
    expect(spec!.file).toBe('docs/specs/spec-001.md');
  });

  it('reports validation errors for incomplete specs', () => {
    const err = state.specIndex.errors.find((e) => e.specId === 'SPEC-002');
    expect(err).toBeDefined();
    expect(err!.errors).toContain('MISSING_status');
    expect(err!.errors).toContain('MISSING_version');
  });

  it('reports duplicate specIds and invalid status values', () => {
    const err = state.specIndex.errors.find((e) => e.file === 'docs/specs/spec-003.md');
    expect(err).toBeDefined();
    expect(err!.errors).toContain('DUPLICATE_specId');
    expect(err!.errors).toContain('INVALID_status');
  });

  it('indexes files without level-2 headings as a single whole-file entry', () => {
    const note = state.searchIndex.filter((e) => e.file === 'docs/NOTE.md');
    expect(note.length).toBe(1);
    expect(note[0].title).toBe('NOTE.md');
    expect(note[0].content).toContain('plain note');
  });

  it('loads glossary terms from docs/06-reference/GLOSSARY.md (both list and heading styles)', () => {
    expect(state.glossary['SSO']).toContain('Single Sign-On');
    expect(state.glossary['FFID']).toContain('FeelFlow ID Platform');
  });
});

describe('buildDocsState on a project without docs/', () => {
  it('returns empty state instead of throwing', () => {
    const state = buildDocsState(path.resolve(__dirname));
    expect(state.mdFiles).toEqual([]);
    expect(state.searchIndex).toEqual([]);
    expect(state.specIndex).toEqual({ specs: [], errors: [] });
    expect(state.glossary).toEqual({});
  });
});

describe('listMarkdown', () => {
  it('returns empty array for nonexistent directory', () => {
    expect(listMarkdown(path.join(PROJECT_FIXTURE, 'no-such-dir'))).toEqual([]);
  });

  it('returns deterministic (sorted) traversal', () => {
    const a = listMarkdown(path.join(PROJECT_FIXTURE, 'docs'));
    const b = listMarkdown(path.join(PROJECT_FIXTURE, 'docs'));
    expect(a).toEqual(b);
    expect(a).toEqual([...a].sort((x, y) => x.localeCompare(y)));
  });
});

// ---------- Issue #521: symlink containment ----------
describe('listMarkdown (symlink containment)', () => {
  let tmp: string;
  let docs: string;
  const names = (files: string[]): string[] => files.map((f) => path.basename(f)).sort();

  beforeAll(() => {
    // macOS の /tmp は /private/tmp への symlink なので realpath 済みの base を使う
    tmp = fs.mkdtempSync(path.join(fs.realpathSync(os.tmpdir()), 'mcp-symlink-'));
    docs = path.join(tmp, 'project', 'docs');
    fs.mkdirSync(path.join(docs, 'sub'), { recursive: true });
    fs.mkdirSync(path.join(tmp, 'outside'), { recursive: true });

    fs.writeFileSync(path.join(docs, 'real.md'), '# real\n');
    fs.writeFileSync(path.join(docs, 'sub', 'inner.md'), '# inner\n');
    fs.writeFileSync(path.join(tmp, 'outside', 'secret.md'), '# secret\n');

    // 外部を指す symlink（封じ込め対象）
    fs.symlinkSync(path.join(tmp, 'outside', 'secret.md'), path.join(docs, 'leak.md'));
    // docs/ 内を指す symlink（許可されるべき）
    fs.symlinkSync(path.join(docs, 'sub', 'inner.md'), path.join(docs, 'internal-link.md'));
    // 壊れた symlink
    fs.symlinkSync(path.join(tmp, 'outside', 'missing.md'), path.join(docs, 'broken.md'));
  });

  afterAll(() => {
    if (tmp) fs.rmSync(tmp, { recursive: true, force: true });
  });

  it('docs/ 外を指すファイル symlink を索引しない', () => {
    expect(names(listMarkdown(docs))).not.toContain('leak.md');
  });

  it('docs/ 内を指す symlink は従来どおり索引する', () => {
    expect(names(listMarkdown(docs))).toContain('internal-link.md');
  });

  it('実ファイルは symlink 検査に影響されない', () => {
    const got = names(listMarkdown(docs));
    expect(got).toContain('real.md');
    expect(got).toContain('inner.md');
  });

  it('壊れた symlink はスキップする', () => {
    expect(names(listMarkdown(docs))).not.toContain('broken.md');
  });

  it('docs/ 自体が symlink の構成でも索引できる', () => {
    const linkedProject = path.join(tmp, 'linked-project');
    fs.mkdirSync(linkedProject, { recursive: true });
    const docsLink = path.join(linkedProject, 'docs');
    fs.symlinkSync(docs, docsLink);
    const got = names(listMarkdown(docsLink));
    expect(got).toContain('real.md');
    expect(got).toContain('internal-link.md');
    expect(got).not.toContain('leak.md');
  });

  it('containmentRoot を明示すると、その配下を指す symlink は許可される', () => {
    // specs/ を歩きつつ containment を docs/ にすると、docs/ 内へのリンクは通る
    const specs = path.join(docs, 'specs');
    fs.mkdirSync(specs, { recursive: true });
    fs.symlinkSync(path.join(docs, 'real.md'), path.join(specs, 'linked-spec.md'));
    expect(names(listMarkdown(specs, docs))).toContain('linked-spec.md');
    // containment を specs/ に狭めると同じリンクは弾かれる
    expect(names(listMarkdown(specs, specs))).not.toContain('linked-spec.md');
  });

  it('buildDocsState は docs/ 外の symlink を検索索引へ入れない', () => {
    const state = buildDocsState(path.join(tmp, 'project'));
    expect(state.mdFiles.map((f) => path.basename(f))).not.toContain('leak.md');
    expect(state.searchIndex.some((e) => e.content.includes('secret'))).toBe(false);
  });

  // ---- レビュー指摘（PR #523）: 走査の入口と、パスで読むファイル ----

  it('開始ディレクトリ自体が docs/ 外を指す symlink なら 1 件も返さない', () => {
    // docs/specs -> /outside の形。外部の「通常ファイル」は symlink フラグを
    // 持たないため、各エントリの検査だけでは素通りしてしまう
    const linkedSpecs = path.join(docs, 'linked-specs');
    fs.symlinkSync(path.join(tmp, 'outside'), linkedSpecs);
    expect(listMarkdown(linkedSpecs, docs)).toEqual([]);
  });

  it('buildDocsState は docs/specs が外部を指す symlink のとき spec を索引しない', () => {
    const proj = path.join(tmp, 'escaped-specs-project');
    const pdocs = path.join(proj, 'docs');
    fs.mkdirSync(pdocs, { recursive: true });
    fs.writeFileSync(path.join(pdocs, 'MASTER.md'), '# master\n');
    const outsideSpecs = path.join(tmp, 'outside-specs');
    fs.mkdirSync(outsideSpecs, { recursive: true });
    fs.writeFileSync(
      path.join(outsideSpecs, 'leaked-spec.md'),
      '---\nspecId: SPEC-LEAK\ntitle: leaked\nstatus: draft\nversion: 1.0.0\n---\n\nsecret body\n',
    );
    fs.symlinkSync(outsideSpecs, path.join(pdocs, 'specs'));
    const state = buildDocsState(proj);
    expect(state.specIndex.specs.map((s) => s.specId)).not.toContain('SPEC-LEAK');
  });

  it('GLOSSARY.md が docs/ 外を指す symlink なら用語を読み込まない', () => {
    const proj = path.join(tmp, 'escaped-glossary-project');
    const ref = path.join(proj, 'docs', '06-reference');
    fs.mkdirSync(ref, { recursive: true });
    const outsideGlossary = path.join(tmp, 'outside-glossary.md');
    fs.writeFileSync(outsideGlossary, '### LEAKED\n\n外部の定義\n');
    fs.symlinkSync(outsideGlossary, path.join(ref, 'GLOSSARY.md'));
    expect(buildDocsState(proj).glossary).toEqual({});
  });

  it('06-reference 自体が docs/ 外を指す symlink でも用語を読み込まない', () => {
    const proj = path.join(tmp, 'escaped-refdir-project');
    fs.mkdirSync(path.join(proj, 'docs'), { recursive: true });
    const outsideRef = path.join(tmp, 'outside-ref');
    fs.mkdirSync(outsideRef, { recursive: true });
    fs.writeFileSync(path.join(outsideRef, 'GLOSSARY.md'), '### LEAKED\n\n外部の定義\n');
    fs.symlinkSync(outsideRef, path.join(proj, 'docs', '06-reference'));
    expect(buildDocsState(proj).glossary).toEqual({});
  });

  it('docs/ 自体が symlink の構成で extract_section も動作する（3 経路の一致）', () => {
    // listMarkdown だけが動いて resolveDocsPath が落ちる非対称を防ぐ
    const shared = path.join(tmp, 'shared-docs');
    fs.mkdirSync(shared, { recursive: true });
    fs.writeFileSync(path.join(shared, 'MASTER.md'), '## 概要\n\n本文\n');
    const proj = path.join(tmp, 'symlinked-docs-project');
    fs.mkdirSync(proj, { recursive: true });
    fs.symlinkSync(shared, path.join(proj, 'docs'));

    expect(listMarkdown(path.join(proj, 'docs')).map((f) => path.basename(f))).toContain('MASTER.md');
    const resolved = resolveDocsPath(proj, 'docs/MASTER.md');
    expect(resolved).not.toBeNull();
    expect(fs.readFileSync(resolved!, 'utf-8')).toContain('本文');
  });

  it('docs/ が symlink でも ../ 脱出と docs/ 外は拒否する', () => {
    const shared = path.join(tmp, 'shared-docs2');
    fs.mkdirSync(shared, { recursive: true });
    fs.writeFileSync(path.join(shared, 'MASTER.md'), '# m\n');
    const proj = path.join(tmp, 'symlinked-docs-project2');
    fs.mkdirSync(proj, { recursive: true });
    fs.writeFileSync(path.join(proj, 'secret.md'), '# secret\n');
    fs.symlinkSync(shared, path.join(proj, 'docs'));

    expect(resolveDocsPath(proj, '../../../etc/hosts')).toBeNull();
    expect(resolveDocsPath(proj, 'secret.md')).toBeNull(); // docs/ の外
  });

  it('docs/ 内の正常な GLOSSARY.md は従来どおり読み込む', () => {
    const proj = path.join(tmp, 'ok-glossary-project');
    const ref = path.join(proj, 'docs', '06-reference');
    fs.mkdirSync(ref, { recursive: true });
    fs.writeFileSync(path.join(ref, 'GLOSSARY.md'), '### ACE\n\nAgentic Context Engineering\n');
    expect(buildDocsState(proj).glossary['ACE']).toBe('Agentic Context Engineering');
  });
});

describe('resolveWithinRoot (path traversal guard)', () => {
  it('resolves an existing file inside the root', () => {
    const abs = resolveWithinRoot(PROJECT_FIXTURE, 'docs/MASTER.md');
    expect(abs).not.toBeNull();
    expect(abs!.endsWith(path.join('docs', 'MASTER.md'))).toBe(true);
  });

  it('rejects ../ escape', () => {
    expect(resolveWithinRoot(PROJECT_FIXTURE, '../../../etc/hosts')).toBeNull();
    expect(resolveWithinRoot(PROJECT_FIXTURE, 'docs/../../indexer.test.ts')).toBeNull();
  });

  it('rejects absolute paths outside the root', () => {
    expect(resolveWithinRoot(PROJECT_FIXTURE, '/etc/hosts')).toBeNull();
  });

  it('rejects sibling-prefix directories', () => {
    // /path/to/project vs /path/to/projectx — plain startsWith would pass
    expect(resolveWithinRoot(PROJECT_FIXTURE, `${PROJECT_FIXTURE}x/file.md`)).toBeNull();
  });

  it('rejects the root itself', () => {
    expect(resolveWithinRoot(PROJECT_FIXTURE, '.')).toBeNull();
  });

  it('rejects nonexistent paths inside the root', () => {
    expect(resolveWithinRoot(PROJECT_FIXTURE, 'docs/no-such-file.md')).toBeNull();
  });
});

describe('resolveDocsPath (docs/-scoped read guard)', () => {
  it('resolves .md files under docs/', () => {
    expect(resolveDocsPath(PROJECT_FIXTURE, 'docs/MASTER.md')).not.toBeNull();
  });

  it('rejects project files outside docs/ even though they exist', () => {
    expect(resolveDocsPath(PROJECT_FIXTURE, 'package.json')).toBeNull();
  });

  it('rejects non-markdown files under docs/', () => {
    // specs dir exists but a hypothetical non-md path must not resolve
    expect(resolveDocsPath(PROJECT_FIXTURE, 'docs/specs')).toBeNull();
  });

  it('rejects traversal that leaves docs/', () => {
    expect(resolveDocsPath(PROJECT_FIXTURE, 'docs/../package.json')).toBeNull();
  });
});
