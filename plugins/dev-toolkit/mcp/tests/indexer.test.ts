import { describe, it, expect } from 'vitest';
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
