/**
 * Index building for the spec-docs MCP server.
 *
 * All functions take explicit root paths so they are testable against
 * fixture trees and independent of the server process's cwd. The server
 * resolves PROJECT_ROOT once (cwd or env override) and passes it in.
 *
 * Indexing target is the *target project's* `docs/` tree only — this server
 * ships inside the dev-toolkit plugin and must not assume the framework
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
 * On top of resolveWithinRoot, requires the target to be a `.md` file under
 * `<projectRoot>/docs/` — tools must never read arbitrary project files
 * (e.g. package.json, .env) even though they are inside the project root.
 */
export const resolveDocsPath = (projectRoot: string, relPath: string): string | null => {
  const abs = resolveWithinRoot(projectRoot, relPath);
  if (!abs || !abs.toLowerCase().endsWith('.md')) return null;
  let docsReal: string;
  try {
    docsReal = fs.realpathSync(path.join(path.resolve(projectRoot), 'docs'));
  } catch {
    return null;
  }
  return abs.startsWith(docsReal + path.sep) ? abs : null;
};

export const listMarkdown = (dir: string): string[] => {
  if (!fs.existsSync(dir)) return [];
  const out: string[] = [];
  // Sorted for deterministic tool output (search ties, list_docs, spec error order).
  const entries = fs.readdirSync(dir, { withFileTypes: true }).sort((a, b) => a.name.localeCompare(b.name));
  for (const e of entries) {
    const full = path.join(dir, e.name);
    if (e.isDirectory()) {
      out.push(...listMarkdown(full));
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
      if (isFile) out.push(full);
    }
  }
  return out;
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
  const files = listMarkdown(specsDir);
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
  const glossaryPath = path.join(docsRoot, '06-reference', 'GLOSSARY.md');
  const mdFiles = listMarkdown(docsRoot);
  return {
    mdFiles,
    searchIndex: buildSearchIndex(mdFiles, projectRoot),
    specIndex: buildSpecIndex(specsDir, projectRoot),
    glossary: fs.existsSync(glossaryPath) ? buildGlossary(readFileSafe(glossaryPath)) : {},
  };
};
