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
import { splitSections, parseFrontMatter, buildGlossary } from './utils.js';

export const readFileSafe = (p: string): string => {
  try {
    return fs.readFileSync(p, 'utf-8');
  } catch {
    return '';
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
 * Containment is measured against **docs/**, not the project root, so a project
 * whose `docs/` is itself a symlink works here exactly as it does in
 * listMarkdown (Issue #521 — previously `resolveDocsPath` routed through
 * resolveWithinRoot first, which rejected the linked tree as "outside the
 * project" and made extract_section the one tool that failed on that layout).
 * The lexical check on the *requested* path still rejects `../` traversal early.
 */
export const resolveDocsPath = (projectRoot: string, relPath: string): string | null => {
  const rootAbs = path.resolve(projectRoot);
  const requested = path.resolve(rootAbs, relPath);
  if (!requested.startsWith(rootAbs + path.sep)) return null; // lexical escape
  if (!requested.toLowerCase().endsWith('.md')) return null;
  if (!fs.existsSync(requested)) return null;
  let real: string;
  let docsReal: string;
  try {
    real = fs.realpathSync(requested);
    docsReal = fs.realpathSync(path.join(rootAbs, 'docs'));
  } catch {
    return null;
  }
  return real.startsWith(docsReal + path.sep) ? real : null;
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
export const listMarkdown = (dir: string, containmentRoot: string = dir): string[] => {
  if (!fs.existsSync(dir)) return [];
  let realRoot: string;
  let realDir: string;
  try {
    realRoot = fs.realpathSync(path.resolve(containmentRoot));
    realDir = fs.realpathSync(path.resolve(dir));
  } catch {
    return [];
  }
  // The start directory itself must be inside the root. Without this a
  // directory symlink at the entry point (`docs/specs -> /outside`) would put
  // plain files — which carry no symlink flag of their own — inside the walk.
  if (realDir !== realRoot && !realDir.startsWith(realRoot + path.sep)) return [];
  return listMarkdownWithin(dir, realRoot);
};

/** Recursive worker for listMarkdown. `realRoot` is already realpath-resolved. */
const listMarkdownWithin = (dir: string, realRoot: string): string[] => {
  const out: string[] = [];
  // Sorted for deterministic tool output (search ties, list_docs, spec error order).
  const entries = fs.readdirSync(dir, { withFileTypes: true }).sort((a, b) => a.name.localeCompare(b.name));
  for (const e of entries) {
    const full = path.join(dir, e.name);
    if (e.isDirectory()) {
      out.push(...listMarkdownWithin(full, realRoot));
    } else if (e.name.toLowerCase().endsWith('.md')) {
      // Follow file symlinks (stat, not lstat) so linked docs are indexed;
      // directory symlinks are intentionally not followed to avoid cycles.
      let isFile = e.isFile();
      if (!isFile && e.isSymbolicLink()) {
        try {
          isFile = fs.statSync(full).isFile();
        } catch {
          continue; // broken symlink — skip
        }
      }
      if (!isFile) continue;
      if (e.isSymbolicLink() && !isWithinRealRoot(full, realRoot)) continue; // escapes the root
      out.push(full);
    }
  }
  return out;
};

/** True when `p` resolves (following symlinks) to a path inside `realRoot`. */
const isWithinRealRoot = (p: string, realRoot: string): boolean => {
  try {
    return fs.realpathSync(p).startsWith(realRoot + path.sep);
  } catch {
    return false; // unresolvable — treat as outside
  }
};

/**
 * Return `p` when it exists and resolves inside `root`, else null (Issue #521).
 *
 * For files read by path rather than through listMarkdown (currently
 * GLOSSARY.md). realpath resolves every component, so a symlinked parent
 * directory is caught as well as a symlinked file.
 */
export const containedPath = (p: string, root: string): string | null => {
  let realRoot: string;
  try {
    realRoot = fs.realpathSync(path.resolve(root));
  } catch {
    return null;
  }
  if (!fs.existsSync(p)) return null;
  return isWithinRealRoot(p, realRoot) ? p : null;
};

export interface DocsState {
  mdFiles: string[];
  searchIndex: SectionIndexEntry[];
  specIndex: SpecIndexResult;
  glossary: Glossary;
}

export const buildSearchIndex = (files: string[], projectRoot: string): SectionIndexEntry[] =>
  files.flatMap((f) => {
    const rel = path.relative(projectRoot, f);
    const text = readFileSafe(f);
    const sections = splitSections(text);
    if (!sections.length) return [{ file: rel, title: path.basename(f), content: text }];
    return sections.map((s) => ({ file: rel, title: s.title || path.basename(f), content: s.content }));
  });

export const buildSpecIndex = (specsDir: string, projectRoot: string): SpecIndexResult => {
  if (!fs.existsSync(specsDir)) return { specs: [], errors: [] };
  // Containment root is docs/ (the parent of specs/), so a link from
  // docs/specs/ to another file under docs/ stays indexable.
  const files = listMarkdown(specsDir, path.dirname(specsDir));
  const seen = new Set<string>();
  const specs: SpecRecordMeta[] = [];
  const errors: SpecIndexResult['errors'] = [];
  for (const f of files) {
    const { meta, body } = parseFrontMatter(readFileSafe(f));
    const rel = path.relative(projectRoot, f);
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
export const buildDocsState = (projectRoot: string): DocsState => {
  const docsRoot = path.join(projectRoot, 'docs');
  const specsDir = path.join(docsRoot, 'specs');
  // The glossary is read by path, not through the walk, so it needs the same
  // containment check (the file *or* any parent component may be a symlink).
  const glossaryPath = containedPath(path.join(docsRoot, '06-reference', 'GLOSSARY.md'), docsRoot);
  const mdFiles = listMarkdown(docsRoot);
  return {
    mdFiles,
    searchIndex: buildSearchIndex(mdFiles, projectRoot),
    specIndex: buildSpecIndex(specsDir, projectRoot),
    glossary: glossaryPath ? buildGlossary(readFileSafe(glossaryPath)) : {},
  };
};
