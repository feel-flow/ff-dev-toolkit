/**
 * Index building for the spec-docs MCP server.
 *
 * All functions take explicit root paths so they are testable against
 * fixture trees and independent of the server process's cwd. The server
 * resolves PROJECT_ROOT once (cwd or env override) and passes it in.
 *
 * Indexing target is the *target project's* `docs/` tree only — this server
 * ships inside the ff-dev-toolkit plugin and must not assume the framework
 * repository layout (no docs-template/, no repo-root markdown files).
 */
import fs from 'fs';
import path from 'path';
import { SPEC_STATUS, SpecStatus } from './constants.js';
import { SectionIndexEntry, SpecIndexResult, SpecRecordMeta, Glossary } from './types.js';
import { splitSections, parseFrontMatter, buildGlossary, toPosixSeparators } from './utils.js';
import { KnowledgeReadBoundary, KnowledgeReadError } from '../../docs-template/scripts/ace/knowledge-read-boundary.js';

/** The `path` members projectRelative needs; tests pass `path.win32`. */
type PathApi = Pick<typeof path, 'relative' | 'sep'>;

/**
 * Project-root-relative path of `file`, with `/` separators on every platform
 * (Issue `#2016`). Every path a tool returns goes through here, so list_docs,
 * search and the spec index agree with each other and with the
 * `docs/02-design/` form the tool descriptions document.
 */
export const projectRelative = (projectRoot: string, file: string, p: PathApi = path): string =>
  toPosixSeparators(p.relative(projectRoot, file), p.sep);

export interface DocsReadAuthority {
  readonly projectRoot: string;
  readonly projectIdentity?: string;
  readonly allowedDocsRoot?: string;
  readonly allowedIdentity?: string;
  readonly error?: string;
}

const directoryIdentity = (dir: string): string => {
  const s = fs.lstatSync(dir);
  if (!s.isDirectory() || s.isSymbolicLink()) throw new KnowledgeReadError('invalid-root');
  return `${s.dev}:${s.ino}`;
};
const strictlyInside = (root: string, candidate: string): boolean => {
  const relative = path.relative(root, candidate);
  return relative !== '' && relative !== '..' && !relative.startsWith('..' + path.sep) && !path.isAbsolute(relative);
};

/** Called once by the host bootstrap; project files never populate this grant. */
export const captureDocsAuthority = (projectRoot: string, allowedDocsRoot?: string): DocsReadAuthority => {
  const selected = path.resolve(projectRoot);
  try {
    const real = fs.realpathSync(selected);
    const authority: DocsReadAuthority = { projectRoot: real, projectIdentity: directoryIdentity(real) };
    if (!allowedDocsRoot) return Object.freeze(authority);
    if (!path.isAbsolute(allowedDocsRoot)) throw new KnowledgeReadError('invalid-external-grant');
    const allowed = fs.realpathSync(allowedDocsRoot);
    if (path.resolve(allowedDocsRoot) !== allowed) throw new KnowledgeReadError('invalid-external-grant');
    return Object.freeze({ ...authority, allowedDocsRoot: allowed, allowedIdentity: directoryIdentity(allowed) });
  } catch {
    return Object.freeze({ projectRoot: selected, error: 'invalid-read-authority' });
  }
};

const docsReader = (projectRoot: string, authority: DocsReadAuthority): KnowledgeReadBoundary => {
  if (authority.error || !authority.projectIdentity) throw new KnowledgeReadError('invalid-read-authority');
  const projectReal = fs.realpathSync(projectRoot);
  if (projectReal !== authority.projectRoot || directoryIdentity(projectReal) !== authority.projectIdentity) throw new KnowledgeReadError('root-changed');
  const realDocs = fs.realpathSync(path.join(projectRoot, 'docs'));
  if (realDocs === projectReal) throw new KnowledgeReadError('docs-is-project-root');
  if (!strictlyInside(projectReal, realDocs)) {
    if (realDocs !== authority.allowedDocsRoot || directoryIdentity(realDocs) !== authority.allowedIdentity) throw new KnowledgeReadError('outside-docs-authority');
  }
  return new KnowledgeReadBoundary(realDocs);
};

const entryExists = (file: string): boolean => {
  try { fs.lstatSync(file); return true; }
  catch (error) {
    if ((error as NodeJS.ErrnoException).code === 'ENOENT') return false;
    throw new KnowledgeReadError('metadata-unavailable');
  }
};

/**
 * Resolve a user-supplied path strictly inside the project root.
 *
 * Returns the absolute (symlink-resolved) path, or null when the path does
 * not exist, escapes the root (`../`, absolute path, sibling-prefix like
 * `<root>x/`), or is the root itself. Symlinks are resolved with realpath so
 * a link under docs/ cannot point outside the project.
 */
export const resolveWithinRoot = (projectRoot: string, relOrAbs: string): string | null => {
  const rootAbs = path.resolve(projectRoot);
  const abs = path.resolve(rootAbs, relOrAbs);
  if (!abs.startsWith(rootAbs + path.sep)) return null;
  if (!fs.existsSync(abs)) return null;
  let real: string;
  let realRoot: string;
  try {
    real = fs.realpathSync(abs);
    realRoot = fs.realpathSync(rootAbs);
  } catch {
    return null;
  }
  if (!real.startsWith(realRoot + path.sep)) return null;
  return real;
};

/**
 * Resolve a project-root-relative path to a readable docs file.
 *
 * Requires the target to be a `.md` file whose realpath is under the realpath
 * of `<projectRoot>/docs/` — tools must never read arbitrary project files
 * (e.g. package.json, .env) even though they are inside the project root.
 *
 * Shared docs require the independently captured exact external-root grant
 * instead of the former automatic external-root trust. A handler supplies its
 * existing reader so indexing and extraction consume the same accepted bytes.
 */
export const resolveDocsPath = (projectRoot: string, relPath: string, reader?: KnowledgeReadBoundary): string | null => {
  const rootAbs = path.resolve(projectRoot);
  const requested = path.resolve(rootAbs, relPath);
  if (!requested.startsWith(rootAbs + path.sep)) return null; // lexical escape
  if (!requested.toLowerCase().endsWith('.md')) return null;
  try {
    const boundary = reader ?? docsReader(projectRoot, captureDocsAuthority(projectRoot));
    const real = boundary.authorize(requested);
    return real.toLowerCase().endsWith('.md') ? real : null;
  } catch {
    return null;
  }
};

/**
 * List `.md` files under `dir`, containing every followed symlink inside
 * `containmentRoot` (Issue #521).
 *
 * File symlinks are followed on purpose — a project may link shared docs into
 * its tree — but the link target must resolve inside the containment root.
 * Without that check the index side (`search` / `spec_*` / `list_docs`) reads
 * whatever a link inside docs/ points at, while `extract_section` refuses the
 * same path via resolveDocsPath: the read boundary existed on the path-argument
 * tool only. Directory symlinks stay unfollowed (cycle avoidance, unchanged).
 *
 * `containmentRoot` is realpath-resolved once, so a project whose `docs/` is
 * itself a symlink keeps working (its real files resolve under the real root).
 */
export const listMarkdown = (dir: string, containmentRoot: string = dir, reader?: KnowledgeReadBoundary): string[] => {
  if (!entryExists(dir)) return [];
  const boundary = reader ?? new KnowledgeReadBoundary(containmentRoot);
  boundary.directory(dir);
  return listMarkdownWithin(dir, boundary);
};

/** Recursive worker for listMarkdown. `realRoot` is already realpath-resolved. */
const listMarkdownWithin = (dir: string, reader: KnowledgeReadBoundary): string[] => {
  const out: string[] = [];
  reader.directory(dir);
  // Sorted for deterministic tool output (search ties, list_docs, spec error order).
  const entries = fs.readdirSync(dir, { withFileTypes: true }).sort((a, b) => a.name.localeCompare(b.name));
  for (const e of entries) {
    const full = path.join(dir, e.name);
    if (e.name.toLowerCase().endsWith('.md')) {
      // Follow file symlinks (stat, not lstat) so linked docs are indexed;
      // directory symlinks are intentionally not followed to avoid cycles.
      // Unverifiable candidates are errors, not a healthy empty result. No
      // source bytes are opened before type/authority/protected storage checks.
      const real = reader.authorize(full);
      if (!real.toLowerCase().endsWith('.md')) throw new KnowledgeReadError('non-markdown-input');
      out.push(full);
    } else if (e.isDirectory()) {
      out.push(...listMarkdownWithin(full, reader));
    }
  }
  return out;
};

/**
 * Return `p` when it exists and resolves inside `root`, else null (Issue #521).
 *
 * For files read by path rather than through listMarkdown (currently
 * GLOSSARY.md). realpath resolves every component, so a symlinked parent
 * directory is caught as well as a symlinked file.
 */
export const containedPath = (p: string, root: string, reader?: KnowledgeReadBoundary): string | null => {
  if (!entryExists(p)) return null;
  return (reader ?? new KnowledgeReadBoundary(root)).authorize(p);
};

export interface DocsState {
  mdFiles: string[];
  searchIndex: SectionIndexEntry[];
  specIndex: SpecIndexResult;
  glossary: Glossary;
  reader?: KnowledgeReadBoundary;
}

export const buildSearchIndex = (files: string[], projectRoot: string, reader: KnowledgeReadBoundary): SectionIndexEntry[] =>
  files.flatMap((f) => {
    const rel = projectRelative(projectRoot, f);
    const text = reader.read(f);
    const sections = splitSections(text);
    if (!sections.length) return [{ file: rel, title: path.basename(f), content: text }];
    return sections.map((s) => ({ file: rel, title: s.title || path.basename(f), content: s.content }));
  });

export const buildSpecIndex = (specsDir: string, projectRoot: string, reader?: KnowledgeReadBoundary): SpecIndexResult => {
  if (!entryExists(specsDir)) return { specs: [], errors: [] };
  const boundary = reader ?? docsReader(projectRoot, captureDocsAuthority(projectRoot));
  // Containment root is docs/ (the parent of specs/), so a link from
  // docs/specs/ to another file under docs/ stays indexable.
  const files = listMarkdown(specsDir, path.dirname(specsDir), boundary);
  const seen = new Set<string>();
  const specs: SpecRecordMeta[] = [];
  const errors: SpecIndexResult['errors'] = [];
  for (const f of files) {
    const { meta, body } = parseFrontMatter(boundary.read(f));
    const rel = projectRelative(projectRoot, f);
    const spec: SpecRecordMeta = { ...(meta as Record<string, unknown>), file: rel, body };
    const errs: string[] = [];
    const status = typeof spec.status === 'string' ? spec.status : undefined;
    if (!spec.specId) errs.push('MISSING_specId');
    if (spec.specId && seen.has(spec.specId)) errs.push('DUPLICATE_specId');
    if (spec.specId) seen.add(spec.specId);
    if (!spec.title) errs.push('MISSING_title');
    if (!status) errs.push('MISSING_status');
    if (status && !SPEC_STATUS.includes(status as SpecStatus)) errs.push('INVALID_status');
    if (!spec.version) errs.push('MISSING_version');
    if (errs.length) errors.push({ file: rel, specId: (spec.specId as string) || null, errors: errs });
    specs.push(spec);
  }
  return { specs, errors };
};

/**
 * Build the full docs state for a project root.
 *
 * Rebuilt on every tool call (docs trees are small) so results never go
 * stale within a long-lived server process.
 */
export const buildDocsState = (projectRoot: string, authority: DocsReadAuthority = captureDocsAuthority(projectRoot)): DocsState => {
  if (authority.error) throw new KnowledgeReadError('invalid-read-authority');
  const docsRoot = path.join(projectRoot, 'docs');
  if (!entryExists(docsRoot)) return { mdFiles: [], searchIndex: [], specIndex: { specs: [], errors: [] }, glossary: {} };
  const reader = docsReader(projectRoot, authority);
  const specsDir = path.join(docsRoot, 'specs');
  // The glossary is read by path, not through the walk, so it needs the same
  // containment check (the file *or* any parent component may be a symlink).
  const glossaryPath = containedPath(path.join(docsRoot, '06-reference', 'GLOSSARY.md'), docsRoot, reader);
  const mdFiles = listMarkdown(docsRoot, docsRoot, reader);
  return {
    mdFiles,
    searchIndex: buildSearchIndex(mdFiles, projectRoot, reader),
    specIndex: buildSpecIndex(specsDir, projectRoot, reader),
    glossary: glossaryPath ? buildGlossary(reader.read(glossaryPath)) : {},
    reader,
  };
};
