/**
 * spec-docs MCP server (dev-toolkit plugin)
 * --------------------------------------------------------------
 * Standard MCP protocol server (tools/list, tools/call via the SDK's
 * high-level McpServer API) exposing the *target project's* `docs/`
 * tree — the structure deployed by /init-docs — as search/lookup tools.
 *
 * Ported from an internal prototype.
 * Intentional differences from the origin:
 *   - Standard MCP methods instead of the legacy `custom/*` handlers
 *     (the origin was not callable from standard MCP clients).
 *   - PROJECT_ROOT = cwd (or SPEC_DOCS_PROJECT_ROOT env), never the
 *     location of this script — the server ships inside a plugin.
 *   - Indexes only `docs/` (no docs-template/, no repo-root files).
 *   - Indexes are rebuilt per tool call, so a long-lived server never
 *     serves stale results (docs trees are small; see indexer.ts).
 * ERROR HANDLING:
 *   - "No result" (null / []) is reserved for a healthy docs/ tree with no
 *     match. Broken preconditions (no docs/, unreadable file, index build
 *     failure) return structured isError results so the client can tell
 *     "not found" from "misconfigured".
 *   - The SDK additionally converts thrown handler errors to isError results.
 * SECURITY: extract_section resolves paths strictly under docs/ (see
 *   resolveDocsPath in indexer.ts — symlink-resolved, .md only).
 */
import { McpServer } from '@modelcontextprotocol/sdk/server/mcp.js';
import { StdioServerTransport } from '@modelcontextprotocol/sdk/server/stdio.js';
import { z } from 'zod';
import fs from 'fs';
import path from 'path';
import { EXCERPT_PADDING_CHARS } from './constants.js';
import { splitSections } from './utils.js';
import { buildDocsState, resolveDocsPath, DocsState } from './indexer.js';

const SERVER_NAME = 'spec-docs';
const SERVER_VERSION = '1.0.0';

const PROJECT_ROOT = path.resolve(process.env.SPEC_DOCS_PROJECT_ROOT || process.cwd());
const DOCS_ROOT = path.join(PROJECT_ROOT, 'docs');

/** Wrap a plain JS value as an MCP text content result. */
const jsonResult = (data: unknown) => ({
  content: [{ type: 'text' as const, text: JSON.stringify(data, null, 2) }],
});

const errorResult = (data: Record<string, unknown>) => ({
  ...jsonResult(data),
  isError: true as const,
});

type ToolResult = ReturnType<typeof jsonResult> | ReturnType<typeof errorResult>;

/**
 * Shared handler wrapper: fails loud (structured isError) when docs/ is
 * missing or the index cannot be built, instead of returning an empty
 * "success" that is indistinguishable from "no match".
 */
const withDocsState = <A>(handler: (state: DocsState, args: A) => ToolResult) => {
  return async (args: A): Promise<ToolResult> => {
    if (!fs.existsSync(DOCS_ROOT)) {
      return errorResult({
        error: 'DOCS_NOT_INITIALIZED',
        projectRoot: PROJECT_ROOT,
        hint: 'No docs/ directory under the project root. Run /init-docs first, or set SPEC_DOCS_PROJECT_ROOT to the correct project.',
      });
    }
    let state: DocsState;
    try {
      state = buildDocsState(PROJECT_ROOT);
    } catch (e) {
      return errorResult({
        error: 'INDEX_BUILD_FAILED',
        projectRoot: PROJECT_ROOT,
        cause: (e as Error).message,
        hint: 'Failed to index docs/. Check directory permissions, or SPEC_DOCS_PROJECT_ROOT.',
      });
    }
    return handler(state, args);
  };
};

const server = new McpServer({ name: SERVER_NAME, version: SERVER_VERSION });

server.registerTool(
  'search',
  {
    description:
      'Keyword search over the project docs/ tree (title-weighted). Returns file, section title, score, and excerpt.',
    inputSchema: {
      query: z.string().min(1).describe('Keyword to search for (case-insensitive)'),
      limit: z.number().int().min(1).max(20).default(5).describe('Max results'),
    },
  },
  withDocsState((state, { query, limit }: { query: string; limit: number }) => {
    const q = query.toLowerCase();
    const hits = state.searchIndex
      .map((i) => {
        const titleLc = i.title.toLowerCase();
        const contentLc = i.content.toLowerCase();
        const score = (titleLc.includes(q) ? 3 : 0) + (contentLc.includes(q) ? 1 : 0);
        if (!score) return null;
        const pos = contentLc.indexOf(q);
        const excerpt =
          pos >= 0
            ? i.content.slice(Math.max(0, pos - EXCERPT_PADDING_CHARS), pos + q.length + EXCERPT_PADDING_CHARS)
            : '';
        return { file: i.file, title: i.title, score, excerpt };
      })
      .filter((x): x is NonNullable<typeof x> => x !== null)
      .sort((a, b) => b.score - a.score)
      .slice(0, limit);
    return jsonResult(hits);
  }),
);

server.registerTool(
  'extract_section',
  {
    description:
      'Extract a level-2 markdown heading section from a docs file (path relative to the project root, e.g. "docs/MASTER.md"). Only .md files under docs/ are readable.',
    inputSchema: {
      file: z.string().min(1).describe('Project-root-relative path of the markdown file (must be under docs/)'),
      heading: z.string().min(1).describe('Exact level-2 heading title'),
    },
  },
  withDocsState((_state, { file, heading }: { file: string; heading: string }) => {
    const abs = resolveDocsPath(PROJECT_ROOT, file);
    if (!abs) {
      return errorResult({
        error: 'FILE_NOT_ACCESSIBLE',
        file,
        hint: 'Path must be an existing .md file under docs/, given relative to the project root (e.g. "docs/MASTER.md"). Paths outside docs/ are not readable.',
      });
    }
    let text: string;
    try {
      text = fs.readFileSync(abs, 'utf-8');
    } catch (e) {
      return errorResult({ error: 'FILE_READ_FAILED', file, cause: (e as NodeJS.ErrnoException).code ?? (e as Error).message });
    }
    const sections = splitSections(text);
    const found = sections.find((s) => s.title.trim() === heading.trim());
    if (!found) {
      return jsonResult({ found: null, availableHeadings: sections.map((s) => s.title).filter(Boolean) });
    }
    return jsonResult({ title: found.title, content: found.content });
  }),
);

server.registerTool(
  'glossary_lookup',
  {
    description: 'Look up a term in docs/06-reference/GLOSSARY.md (case-insensitive).',
    inputSchema: { term: z.string().min(1).describe('Glossary term') },
  },
  withDocsState((state, { term }: { term: string }) => {
    const key = Object.keys(state.glossary).find((k) => k.toLowerCase() === term.toLowerCase());
    return jsonResult(key ? { term: key, definition: state.glossary[key] } : null);
  }),
);

server.registerTool(
  'list_docs',
  {
    description: 'List markdown file paths under the project docs/ tree (project-root-relative).',
    inputSchema: {
      prefix: z.string().optional().describe('Filter: only paths starting with this prefix (e.g. "docs/02-design/")'),
    },
  },
  withDocsState((state, { prefix }: { prefix?: string }) => {
    const rels = state.mdFiles.map((f) => path.relative(PROJECT_ROOT, f));
    return jsonResult(prefix ? rels.filter((r) => r.startsWith(prefix)) : rels);
  }),
);

server.registerTool(
  'spec_lookup',
  {
    description: 'Retrieve a spec document from docs/specs/ by its specId (frontmatter field).',
    inputSchema: { specId: z.string().min(1).describe('Spec identifier') },
  },
  withDocsState((state, { specId }: { specId: string }) => {
    const s = state.specIndex.specs.find((sp) => (sp.specId || '').toLowerCase() === specId.toLowerCase());
    if (!s) {
      // Surface index errors on miss: a spec with broken frontmatter is not
      // retrievable by specId, and "null" alone would hide the reason.
      if (state.specIndex.errors.length) {
        return jsonResult({
          found: null,
          specIndexErrors: state.specIndex.errors,
          hint: 'Specs with frontmatter errors are not retrievable by specId. Fix the listed errors.',
        });
      }
      return jsonResult(null);
    }
    const { body, ...meta } = s;
    return jsonResult({ meta, body });
  }),
);

server.registerTool(
  'spec_search',
  {
    description: 'Substring search over spec title, tags, and summary in docs/specs/.',
    inputSchema: {
      query: z.string().min(1).describe('Keyword to search for (case-insensitive)'),
      limit: z.number().int().min(1).max(20).default(5).describe('Max results'),
    },
  },
  withDocsState((state, { query, limit }: { query: string; limit: number }) => {
    const q = query.toLowerCase();
    const hits = state.specIndex.specs
      .map((s) => {
        const title = (s.title || '').toLowerCase();
        const summary = (s.summary || '').toLowerCase();
        const tags = Array.isArray(s.tags) ? s.tags.join(' ').toLowerCase() : '';
        const score = [title, summary, tags].reduce((acc, part) => acc + (part.includes(q) ? 1 : 0), 0);
        if (!score) return null;
        return { specId: s.specId, title: s.title, status: s.status, score };
      })
      .filter((x): x is NonNullable<typeof x> => x !== null)
      .sort((a, b) => b.score - a.score)
      .slice(0, limit);
    return jsonResult(hits);
  }),
);

// ---------- Check mode ----------
if (process.argv.includes('--check')) {
  try {
    const state = buildDocsState(PROJECT_ROOT);
    console.error(
      `[${SERVER_NAME}] root=${PROJECT_ROOT} files=${state.mdFiles.length} sections=${state.searchIndex.length} ` +
        `specs=${state.specIndex.specs.length} specErrors=${state.specIndex.errors.length} glossaryTerms=${Object.keys(state.glossary).length}`,
    );
    for (const err of state.specIndex.errors) {
      console.error(`[${SERVER_NAME}]   spec error: ${err.file} (${err.specId ?? 'no specId'}): ${err.errors.join(', ')}`);
    }
    if (!fs.existsSync(DOCS_ROOT)) {
      console.error(`[${SERVER_NAME}] WARNING: no docs/ directory under ${PROJECT_ROOT} — run /init-docs first.`);
      process.exit(1);
    }
    if (state.mdFiles.length === 0) {
      console.error(`[${SERVER_NAME}] WARNING: docs/ exists but contains no markdown files.`);
    }
    process.exit(0);
  } catch (e) {
    console.error(`[${SERVER_NAME}] CHECK FAILED: ${(e as Error).message}`);
    process.exit(1);
  }
}

// ---------- Start server ----------
try {
  const transport = new StdioServerTransport();
  await server.connect(transport);
  console.error(`[${SERVER_NAME}] server started (project root: ${PROJECT_ROOT})`);
  if (!fs.existsSync(DOCS_ROOT)) {
    console.error(`[${SERVER_NAME}] WARNING: no docs/ directory under ${PROJECT_ROOT} — tools will return DOCS_NOT_INITIALIZED.`);
  }
} catch (e) {
  console.error(`[${SERVER_NAME}] failed to start: ${(e as Error).message}`);
  process.exit(1);
}
