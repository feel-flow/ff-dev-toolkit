/**
 * Pure utility functions for the MCP server.
 * Extracted for testability — no side effects, no file I/O.
 */
import { SectionIndexEntry, Glossary } from './types.js';

/** Split markdown into level-2 heading sections. */
export const splitSections = (markdown: string): SectionIndexEntry[] => {
  const lines = markdown.split(/\r?\n/);
  const sections: SectionIndexEntry[] = [];
  let current: { title: string; buf: string[] } = { title: '', buf: [] };
  for (const line of lines) {
    if (line.startsWith('## ')) {
      if (current.title || current.buf.length) sections.push({ file: '', title: current.title, content: current.buf.join('\n') });
      current = { title: line.slice(3).trim(), buf: [] };
    } else current.buf.push(line);
  }
  if (current.title || current.buf.length) sections.push({ file: '', title: current.title, content: current.buf.join('\n') });
  return sections;
};

/** Parse a YAML-like scalar value. */
export const parseScalar = (val: string): unknown => {
  const t = val.trim();
  if (t === '[]') return [];
  if (/^\[.*\]$/.test(t)) return t.slice(1, -1).split(',').map(s => s.trim()).filter(Boolean);
  if (/^(true|false)$/.test(t)) return t === 'true';
  if (/^[0-9]+$/.test(t)) return Number(t);
  // Strip surrounding quotes from quoted scalars (e.g. summary: "..." / '...')
  if (t.length >= 2 && ((t.startsWith('"') && t.endsWith('"')) || (t.startsWith("'") && t.endsWith("'")))) {
    return t.slice(1, -1);
  }
  return t;
};

/** Parse YAML-ish front matter from a markdown string. */
export const parseFrontMatter = (raw: string): { meta: Record<string, unknown>; body: string } => {
  const FRONT = '---';
  if (!raw.startsWith(FRONT)) return { meta: {}, body: raw };
  const lines = raw.split(/\r?\n/);
  let i = 1; const metaLines: string[] = [];
  while (i < lines.length && lines[i] !== FRONT) { metaLines.push(lines[i]); i++; }
  if (i === lines.length) return { meta: {}, body: raw };
  const body = lines.slice(i + 1).join('\n');
  const meta: Record<string, unknown> = {};
  let current: string | null = null;
  for (const l of metaLines) {
    if (!l.trim()) continue;
    const m = l.match(/^([A-Za-z0-9_]+):\s*(.*)$/);
    if (m) {
      current = m[1];
      const v = m[2];
      meta[current] = (v === '' || v === '>-') ? '' : parseScalar(v);
    } else if (/^\s+-\s+/.test(l) && current) {
      const arr = Array.isArray(meta[current]) ? [...(meta[current] as unknown[])] : [];
      arr.push(l.replace(/^\s+-\s+/, '').trim());
      meta[current] = arr;
    }
  }
  return { meta, body };
};

/**
 * Blank the lines of GLOSSARY.md that must not be scanned for terms (Issue #517).
 *
 * Three exclusion regions, all confirmed-closed before they take effect:
 *   1. closed code fences (``` / ~~~)         — format examples
 *   2. closed HTML comments (<!-- ... -->)    — entry templates
 *   3. everything from a `## Changelog` heading to EOF — release notes, whose
 *      `- something: description` bullets otherwise register as terms
 *
 * **Unclosed** fences/comments are deliberately NOT treated as regions: a stray
 * opening marker must not silently swallow every real term after it. The same
 * "closed span only" rule the ACE line-budget exception uses.
 *
 * Lines are blanked rather than removed so indices stay stable for the caller's
 * heading/definition scan.
 */
export const maskNonGlossaryLines = (lines: string[]): string[] => {
  const masked = maskClosedSpans(lines);
  // The Changelog cut is searched in the already-masked lines: a `## Changelog`
  // shown inside a fence or comment is an example, and must not blank every
  // real term that follows it.
  //
  // The whitespace class is `[ \t]`, **not** `\s` (aligned 2026-09). `\s` also
  // accepts NBSP (U+00A0) and other non-ASCII space characters that the awk
  // side (tests/lib/docs-scan.sh's `ff_docs_fm_verdict` / `ff_docs_body` /
  // `ff_docs_claim_body` / `ff_docs_mask_changelog`) cannot match without
  // leaving its ASCII-class constraint (run-all case 11 — the same reasoning
  // that pinned `fenceOpenerOf` below to `[ \t]*`). Before the alignment awk
  // additionally required exactly one space and no trailing whitespace
  // (`/^## Changelog$/`), so `##  Changelog` (2 spaces) or a trailing-space
  // heading masked here but stayed as body text on the awk side — this regex
  // and all awk-side occurrences must be changed together, or the two
  // implementations diverge again. tests/docs-scan-mirror pins both directions:
  // the relaxed spacing via positive fixtures, and the ASCII-class constraint
  // via an NBSP negative fixture that goes red if this widens back to `\s`.
  const changelog = masked.findIndex((l) => /^##[ \t]+Changelog[ \t]*$/.test(l));
  if (changelog !== -1) for (let i = changelog; i < masked.length; i++) masked[i] = '';
  return masked;
};

/**
 * A code fence opener: the run character and its length (CommonMark: >= 3).
 *
 * The indent class is `[ \t]*`, **not** `\s*` (Issue #706). `\s` also accepts
 * NBSP (U+00A0), a vertical tab and a form feed, none of which the awk side can
 * match without leaving its ASCII-class constraint (docs-scan.sh design notes /
 * run-all case 11) — `[ \t]*` keeps the two implementations on the same indent
 * class. It does not cap the indent width, so 4+ columns of spaces/tabs still
 * open a fence here even though CommonMark caps fence indentation at 0-3
 * spaces (see the known-limitation note in docs-scan.sh's `ff_docs_mask_spans`
 * header — the awk side has the same gap). A trailing `\r` stays accepted so
 * CRLF input behaves identically on both sides.
 */
const fenceOpenerOf = (l: string): { char: string; len: number } | null => {
  const m = l.match(/^[ \t]*(`{3,}|~{3,})/);
  return m ? { char: m[1][0], len: m[1].length } : null;
};

/**
 * True when `l` closes a fence opened by `open`. CommonMark requires the same
 * character, a run at least as long, and **no info string** — so ```` ```ts ````
 * inside a ```` ```markdown ```` block is content, not a closing marker.
 */
const closesFence = (l: string, open: { char: string; len: number }): boolean => {
  const m = l.match(/^[ \t]*(`{3,}|~{3,})[ \t\r]*$/);
  return !!m && m[1][0] === open.char && m[1].length >= open.len;
};

/**
 * Replace each paired single-backtick code span with the same number of spaces.
 *
 * Used only to locate a comment opener: padding preserves length, so a column in
 * the returned string maps straight back to the same column of the original.
 *
 * The rule must stay identical to `ff_docs_mask_inline_spans` /
 * `blank_code_spans` in `tests/lib/docs-scan.sh` — single-backtick pairs only,
 * escaped backticks not distinguished. Changing one side alone drifts silently.
 */
const blankCodeSpans = (l: string): string => l.replace(/`[^`]*`/g, (m) => ' '.repeat(m.length));

/**
 * Blank every closed fence / HTML-comment span, left to right.
 *
 * A single pass is what makes the two kinds compose: whichever marker opens
 * first wins, and any marker inside the resulting span is never examined (so a
 * ``` inside a comment cannot pair with a fence outside it, and vice versa).
 *
 * Three deliberate narrowings:
 *   - an opener with no matching close is **skipped, not honoured** — the scan
 *     continues so a stray marker neither swallows the rest of the file nor
 *     hides a later closed span
 *   - for comments only the commented characters are removed, so a term with a
 *     trailing note (`### ACE <!-- 補足 -->`) survives
 *   - a `<!--` inside a paired inline code span does **not** open a comment
 *     (Issue #527): prose quoting the marker would otherwise pair with the next
 *     `-->` in the file — a mermaid arrow (`A --> B`) is enough — and silently
 *     swallow everything in between
 *   - the **closing** search applies the same code-span rule (Issue #706), so
 *     prose quoting `` `-->` `` no longer terminates a comment early
 *
 * Chosen behaviour, not an oversight: the closing search still **crosses fence
 * spans**, so a stray `<!--` in prose pairs with a `-->` inside a later fence (a
 * mermaid arrow is enough). Issue #706 implemented both alternatives — step over
 * fence bodies, and stop at the fence boundary — and rejected both: a comment
 * holding a fence *opener* reads as unclosed either way (stopping at the
 * boundary fails even when the matching closer lives inside the comment;
 * stepping over fence bodies fails when it lives outside), and everything
 * after it is swallowed as fence content instead — confirmed by
 * docs-frontmatter-repo-selftest case G19 going red under both alternatives.
 * Not examining markers inside an already-open comment follows from the
 * single-pass rule above, and matches CommonMark, where an HTML block opened
 * by `<!--` runs to the line containing `-->` and does not parse fences in
 * between. Pinned by tests/docs-scan-mirror/fixtures/comment-wraps-fence.md
 * and tests/docs-scan-mirror/fixtures/unclosed-comment-before-fence.md.
 */
export const maskClosedSpans = (lines: string[]): string[] => {
  const out = [...lines];
  let i = 0;
  while (i < out.length) {
    const fence = fenceOpenerOf(out[i]);
    // Fence detection reads the raw line (``` itself would be blanked); only the
    // comment opener is looked up in the blanked copy. Lengths match, so the
    // `indexOf(fence.char) < commentAt` precedence comparison is unaffected.
    const commentAt = blankCodeSpans(out[i]).indexOf('<!--');
    if (fence && (commentAt === -1 || out[i].indexOf(fence.char) < commentAt)) {
      const close = out.findIndex((l, j) => j > i && closesFence(l, fence));
      if (close === -1) { i++; continue; } // unclosed: skip this opener only
      for (let k = i; k <= close; k++) out[k] = '';
      i = close + 1;
    } else if (commentAt !== -1) {
      i = maskCommentAt(out, i, commentAt);
    } else i++;
  }
  return out;
};

/**
 * Remove one HTML comment starting at `out[i]`, column `at`. Returns the line
 * index to examine next (the same line when the comment closed on it, so a
 * second comment or a fence after it is still seen).
 */
const maskCommentAt = (out: string[], i: number, at: number): number => {
  // The closer is located in the code-span-blanked copy, exactly like the opener
  // (Issue #706). Blanking preserves length, so the index maps back unchanged.
  const sameLineEnd = blankCodeSpans(out[i]).indexOf('-->', at);
  if (sameLineEnd !== -1) {
    out[i] = out[i].slice(0, at) + out[i].slice(sameLineEnd + 3);
    return i;
  }
  // The multi-line search deliberately ignores fences (see maskClosedSpans).
  const close = out.findIndex((l, j) => j > i && blankCodeSpans(l).includes('-->'));
  if (close === -1) return i + 1; // unclosed: skip this opener only
  const tail = out[close].slice(blankCodeSpans(out[close]).indexOf('-->') + 3);
  out[i] = out[i].slice(0, at);
  for (let k = i + 1; k < close; k++) out[k] = '';
  out[close] = tail;
  return close;
};

/** Build a glossary map from GLOSSARY.md content. */
export const buildGlossary = (md: string): Glossary => {
  const res: Glossary = {};
  const lines = maskNonGlossaryLines(md.split(/\r?\n/));
  for (const line of lines) {
    const m = line.match(/^[-*]\s+([^:]+):\s*(.+)$/); if (m) res[m[1].trim()] = m[2].trim();
  }
  for (let i = 0; i < lines.length; i++) {
    const h = lines[i]; const hm = h.match(/^###\s+(.+?)\s*$/); if (!hm) continue;
    const raw = hm[1].trim(); const term = raw.replace(/\s*\(.+\)\s*$/, '').trim();
    let j = i + 1; const buf: string[] = [];
    while (j < lines.length && lines[j].trim() === '') j++;
    while (j < lines.length) { const l = lines[j]; if (/^#{1,6}\s/.test(l) || /^---+$/.test(l) || /^\|/.test(l) || !l.trim()) break; buf.push(l.trim()); j++; }
    if (term && buf.length && !res[term]) res[term] = buf.join(' ');
  }
  return res;
};
