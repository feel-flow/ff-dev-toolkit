/**
 * End-to-end tests against the built server bundle (dist/index.js) over real
 * stdio MCP, using the official SDK client. `npm test` builds before running
 * (see package.json), which doubles as a src/dist drift guard.
 */
import { describe, it, expect, beforeAll, afterAll } from 'vitest';
import path from 'path';
import url from 'url';
import fs from 'fs';
import os from 'os';
import { execFileSync } from 'child_process';
import { Client } from '@modelcontextprotocol/sdk/client/index.js';
import { StdioClientTransport } from '@modelcontextprotocol/sdk/client/stdio.js';

const __dirname = path.dirname(url.fileURLToPath(import.meta.url));
const DIST = path.resolve(__dirname, '../dist/index.js');
const PROJECT_FIXTURE = path.resolve(__dirname, 'fixtures/project');

const parseText = (res: any): any => JSON.parse(res.content[0].text);

const serverEnv = (grant?: string): Record<string, string> => {
  const env = Object.fromEntries(Object.entries(process.env).filter(([key, value]) => value !== undefined && !key.startsWith('SPEC_DOCS_'))) as Record<string, string>;
  if (grant !== undefined) env.SPEC_DOCS_ALLOWED_DOCS_ROOT = grant;
  return env;
};
const connect = async (cwd: string, grant?: string, extraEnv: Record<string, string> = {}): Promise<Client> => {
  const client = new Client({ name: 'vitest', version: '0.0.0' });
  const transport = new StdioClientTransport({ command: process.execPath, args: [DIST], cwd, env: { ...serverEnv(grant), ...extraEnv } });
  await client.connect(transport);
  return client;
};

describe('spec-docs server over stdio (fixture project)', () => {
  let client: Client;

  beforeAll(async () => {
    expect(fs.existsSync(DIST)).toBe(true);
    client = await connect(PROJECT_FIXTURE);
  });

  afterAll(async () => {
    await client.close();
  });

  it('exposes exactly the 6 documented tools', async () => {
    const { tools } = await client.listTools();
    expect(tools.map((t) => t.name).sort()).toEqual([
      'extract_section',
      'glossary_lookup',
      'list_docs',
      'search',
      'spec_lookup',
      'spec_search',
    ]);
  });

  it('search finds docs content', async () => {
    const res = await client.callTool({ name: 'search', arguments: { query: 'アーキテクチャ' } });
    const hits = parseText(res);
    expect(hits.length).toBeGreaterThan(0);
    expect(hits[0].file.startsWith('docs/')).toBe(true);
  });

  it('list_docs filters by the documented docs/02-design/ prefix', async () => {
    // On Windows the paths used to come back as docs\02-design\..., so the
    // prefix from the tool description matched nothing (Issue `#2016`).
    const res = await client.callTool({ name: 'list_docs', arguments: { prefix: 'docs/02-design/' } });
    expect(parseText(res)).toEqual(['docs/02-design/ARCHITECTURE.md', 'docs/02-design/DOMAIN.md']);
  });

  it('search applies the declared default limit (5) and enforces the max (20)', async () => {
    // Guards the argument-validation layer itself: if the schema default were
    // lost, `limit` would be undefined and slice(0, undefined) returns every
    // match — the loose `toBeGreaterThan(0)` above would stay green.
    // The query hits a dedicated fixture (docs/06-reference/limit-probe.md,
    // seven sections) so the expectations cannot rot as other fixture files
    // are reorganized.
    const QUERY = 'limitprobefixture';
    const dflt = parseText(await client.callTool({ name: 'search', arguments: { query: QUERY } }));
    expect(dflt.length).toBe(5);

    // Control: the default is a cap, not a shortage of matches.
    const wide = parseText(
      await client.callTool({ name: 'search', arguments: { query: QUERY, limit: 20 } }),
    );
    expect(wide.length).toBe(7);

    // Declared max actually enforced. Only isError — no SDK message-text
    // assertions, which change across bumps.
    const over = await client.callTool({
      name: 'search',
      arguments: { query: QUERY, limit: 21 },
    });
    expect(over.isError).toBe(true);
  });

  it('search keeps its declared inputSchema across zod majors', async () => {
    // zod 3 → 4 (Issue `#2335`) changes who renders the JSON Schema. Pin the
    // contract clients see: required query, integer limit bounded 1..20 with
    // default 5. additionalProperties is intentionally not asserted (zod 4
    // stops emitting it; unknown keys were stripped at runtime either way).
    const { tools } = await client.listTools();
    const schema: any = tools.find((t) => t.name === 'search')?.inputSchema;
    expect(schema.type).toBe('object');
    expect(schema.required).toEqual(['query']);
    expect(schema.properties.query).toMatchObject({ type: 'string', minLength: 1 });
    expect(schema.properties.limit).toMatchObject({ type: 'integer', minimum: 1, maximum: 20, default: 5 });
  });

  it('search rejects out-of-contract arguments and accepts unknown keys as before', async () => {
    // Only isError is asserted; zod 4 rewords the messages.
    for (const args of [{ query: '' }, {}, { query: 'x', limit: 0 }, { query: 'x', limit: 2.5 }]) {
      const res = await client.callTool({ name: 'search', arguments: args as any });
      expect(res.isError, JSON.stringify(args)).toBe(true);
    }
    const extra = await client.callTool({ name: 'search', arguments: { query: 'limitprobefixture', bogus: 1 } as any });
    expect(extra.isError).toBeFalsy();
  });

  it('extract_section refuses to read project files outside docs/', async () => {
    const res = await client.callTool({
      name: 'extract_section',
      arguments: { file: 'package.json', heading: 'x' },
    });
    expect(res.isError).toBe(true);
    expect(parseText(res).error).toBe('FILE_NOT_ACCESSIBLE');
  });

  it('extract_section refuses ../ traversal', async () => {
    const res = await client.callTool({
      name: 'extract_section',
      arguments: { file: 'docs/../package.json', heading: 'x' },
    });
    expect(res.isError).toBe(true);
    expect(parseText(res).error).toBe('FILE_NOT_ACCESSIBLE');
  });

  it('extract_section returns available headings on a heading miss', async () => {
    const res = await client.callTool({
      name: 'extract_section',
      arguments: { file: 'docs/MASTER.md', heading: 'そんな見出しはない' },
    });
    expect(res.isError).toBeFalsy();
    const body = parseText(res);
    expect(body.found).toBeNull();
    expect(Array.isArray(body.availableHeadings)).toBe(true);
    expect(body.availableHeadings.length).toBeGreaterThan(0);
  });

  it('spec_lookup surfaces index errors when the specId is not found', async () => {
    const res = await client.callTool({ name: 'spec_lookup', arguments: { specId: 'SPEC-999' } });
    const body = parseText(res);
    expect(body.found).toBeNull();
    expect(body.specIndexErrors.length).toBeGreaterThan(0);
  });
});

// The complete public read surface is exercised against the shipped bundle.
// An empty or omitted tool vector must fail rather than report a green probe.
const boundaryCalls = [
  { name: 'search', arguments: { query: 'ff_mcp_private_canary_2432' } },
  { name: 'list_docs', arguments: {} },
  { name: 'extract_section', arguments: { file: 'docs/MASTER.md', heading: 'Boundary' } },
  { name: 'glossary_lookup', arguments: { term: 'CANARY' } },
  { name: 'spec_search', arguments: { query: 'canary' } },
  { name: 'spec_lookup', arguments: { specId: 'SPEC-PRIVATE' } },
];
describe('built server protected docs boundary', () => {
  const canary = 'ff_mcp_private_canary_2432';
  let tmp: string;
  let project: string;
  let shared: string;
  beforeAll(() => {
    tmp = fs.mkdtempSync(path.join(fs.realpathSync(os.tmpdir()), 'mcp-boundary-'));
    shared = path.join(tmp, 'shared');
    fs.mkdirSync(path.join(shared, '06-reference'), { recursive: true });
    fs.mkdirSync(path.join(shared, 'specs'));
    fs.writeFileSync(path.join(shared, 'MASTER.md'), `## Boundary\n\n${canary}\n`);
    fs.writeFileSync(path.join(shared, '06-reference/GLOSSARY.md'), `### CANARY\n\n${canary}\n`);
    fs.writeFileSync(path.join(shared, 'specs/private.md'), `---\nspecId: SPEC-PRIVATE\ntitle: canary\nstatus: draft\nversion: 1.0.0\n---\n\n${canary}\n`);
    expect(boundaryCalls.map(call => call.name).sort()).toEqual(['extract_section', 'glossary_lookup', 'list_docs', 'search', 'spec_lookup', 'spec_search']);
  });
  afterAll(() => fs.rmSync(tmp, { recursive: true, force: true }));

  const newProject = (name: string): string => {
    project = path.join(tmp, name);
    fs.mkdirSync(project);
    return project;
  };
  const assertRefused = async (root: string, grant?: string): Promise<void> => {
    const client = await connect(root, grant);
    try {
      for (const call of boundaryCalls) {
        const response = await client.callTool(call);
        expect(response.isError, call.name).toBe(true);
        expect(parseText(response).error, call.name).toBe('INDEX_BUILD_FAILED');
        expect(JSON.stringify(response), call.name).not.toContain(canary);
      }
    } finally { await client.close(); }
  };
  it('refuses docs -> project root for every tool', async () => {
    const root = newProject('project-root');
    fs.writeFileSync(path.join(root, 'MASTER.md'), `## Boundary\n${canary}\n`);
    fs.symlinkSync('.', path.join(root, 'docs'));
    await assertRefused(root);
  });
  it('refuses docs -> .. for every tool', async () => {
    const root = newProject('project-parent');
    fs.symlinkSync('..', path.join(root, 'docs'));
    await assertRefused(root);
  });
  it('refuses an ungranted external docs root for every tool', async () => {
    const root = newProject('external');
    fs.symlinkSync(shared, path.join(root, 'docs'));
    await assertRefused(root);
  });
  it('refuses a dangling docs root instead of claiming an uninitialized project', async () => {
    const root = newProject('dangling-root');
    fs.symlinkSync(path.join(tmp, 'missing-docs'), path.join(root, 'docs'));
    await assertRefused(root);
  });
  for (const kind of ['hardlink', 'oversized', 'nul', 'directory', 'dangling-file']) {
    it(`refuses ${kind} input through every built tool`, async () => {
      const root = newProject('input-' + kind), docs = path.join(root, 'docs');
      fs.mkdirSync(docs);
      const file = path.join(docs, 'MASTER.md');
      if (kind === 'directory') fs.mkdirSync(file);
      else if (kind === 'dangling-file') fs.symlinkSync(path.join(tmp, 'missing.md'), file);
      else {
        fs.writeFileSync(file, kind === 'oversized' ? canary + 'x'.repeat(4 * 1024 * 1024) : kind === 'nul' ? canary + String.fromCharCode(0) : canary);
        if (kind === 'hardlink') fs.linkSync(file, path.join(docs, 'other.md'));
      }
      await assertRefused(root);
    });
  }
  it.skipIf(process.platform === 'win32')('refuses a FIFO before opening through every built tool', async () => {
    const root = newProject('fifo'), docs = path.join(root, 'docs');
    fs.mkdirSync(docs); execFileSync('mkfifo', [path.join(docs, 'MASTER.md')]);
    await assertRefused(root);
  });
  it('preserves all six tools for an exact explicit external root', async () => {
    const root = newProject('explicit');
    fs.symlinkSync(shared, path.join(root, 'docs'));
    const client = await connect(root, shared);
    try {
      for (const call of boundaryCalls) {
        const response = await client.callTool(call);
        expect(response.isError, call.name).toBeFalsy();
        const expected = call.name === 'list_docs' ? 'docs/MASTER.md' : call.name === 'spec_search' ? 'SPEC-PRIVATE' : canary;
        expect(JSON.stringify(response), call.name).toContain(expected);
      }
    } finally { await client.close(); }
  });
  it('all built tools consume accepted snapshots without readFileSync on source markdown', async () => {
    const root = newProject('snapshot-only');
    fs.symlinkSync(shared, path.join(root, 'docs'));
    const preload = path.join(tmp, 'deny-unbounded-source-read.cjs');
    fs.writeFileSync(preload, [
      'const fs = require("node:fs");',
      'const original = fs.readFileSync;',
      'fs.readFileSync = function(file, ...args) {',
      '  if (typeof file === "string" && file.endsWith(".md")) throw new Error("unexpected source pathname reopen");',
      '  return original.call(this, file, ...args);',
      '};',
    ].join('\n'));
    const client = await connect(root, shared, { NODE_OPTIONS: '--require ' + JSON.stringify(preload) });
    try {
      for (const call of boundaryCalls) {
        expect((await client.callTool(call)).isError, call.name).toBeFalsy();
      }
    } finally { await client.close(); }
  });
  it('refuses a sibling-prefix grant and a nested escaping file link', async () => {
    const sibling = shared + '-sibling';
    fs.mkdirSync(sibling);
    const root = newProject('sibling-prefix');
    fs.symlinkSync(sibling, path.join(root, 'docs'));
    await assertRefused(root, shared);
    const nested = newProject('nested');
    const docs = path.join(nested, 'docs');
    fs.mkdirSync(docs);
    fs.symlinkSync(path.join(shared, 'MASTER.md'), path.join(docs, 'MASTER.md'));
    await assertRefused(nested);
  });
  it('refuses a parent link into private glossary data', async () => {
    const root = newProject('glossary-parent');
    fs.mkdirSync(path.join(root, 'docs'));
    fs.symlinkSync(path.join(shared, '06-reference'), path.join(root, 'docs/06-reference'));
    await assertRefused(root);
  });
  it('keeps the external grant identity frozen after server startup', async () => {
    const root = newProject('frozen');
    const selected = path.join(tmp, 'selected');
    fs.cpSync(shared, selected, { recursive: true });
    fs.symlinkSync(selected, path.join(root, 'docs'));
    const client = await connect(root, selected);
    try {
      const first = await client.callTool(boundaryCalls[1]);
      expect(first.isError).toBeFalsy();
      fs.renameSync(selected, selected + '-original');
      fs.cpSync(shared, selected, { recursive: true });
      for (const call of boundaryCalls) {
        const response = await client.callTool(call);
        expect(response.isError, call.name).toBe(true);
        expect(JSON.stringify(response), call.name).not.toContain(canary);
      }
    } finally { await client.close(); }
  });
  it('--check refuses ungranted docs and accepts an exact explicit root', () => {
    const root = newProject('check');
    fs.symlinkSync(shared, path.join(root, 'docs'));
    expect(() => execFileSync(process.execPath, [DIST, '--check'], { cwd: root, env: serverEnv(), stdio: 'pipe', timeout: 10000 })).toThrow();
    const output = execFileSync(process.execPath, [DIST, '--check'], { cwd: root, env: serverEnv(shared), encoding: 'utf8', stdio: 'pipe', timeout: 10000 });
    expect(output).not.toContain(canary);
  });
});

describe('spec-docs server on a project without docs/', () => {
  it('returns DOCS_NOT_INITIALIZED instead of an empty success', async () => {
    const client = await connect(__dirname); // tests/ dir has no docs/
    try {
      const res = await client.callTool({ name: 'search', arguments: { query: 'anything' } });
      expect(res.isError).toBe(true);
      const body = parseText(res);
      expect(body.error).toBe('DOCS_NOT_INITIALIZED');
      expect(body.hint).toContain('/init-docs');
    } finally {
      await client.close();
    }
  });
});

describe('ASDD minimal generated project', () => {
  it('searches MASTER without requiring the other six documents', async () => {
    const root = fs.mkdtempSync(path.join(os.tmpdir(), 'asdd-mcp-'));
    let client: Client | undefined;
    try {
      const configuration = path.join(root, 'confirmed.json');
      fs.writeFileSync(configuration, JSON.stringify({
        schemaVersion: 1, project: { name: '月次集計', purpose: '元データとの合計照合', owner: '@example' },
        style: 'citizen', stage: 'poc', tools: ['claude', 'codex'], documents: ['MASTER'], workflow: 'simple',
        features: { ace: false, retrospective: false, multiReview: false, hooks: false, ci: false },
        decisions: [], github: null,
      }));
      execFileSync(process.execPath, [path.resolve(__dirname, '../../scripts/asdd/cli.mjs'), '--root', root, '--config', configuration, '--apply']);
      client = await connect(root);
      const result = await client.callTool({ name: 'search', arguments: { query: '元データとの合計照合' } });
      expect(result.isError).toBeFalsy();
      expect(parseText(result).some((hit: { file: string }) => hit.file === 'docs/MASTER.md')).toBe(true);
      expect(fs.readdirSync(path.join(root, 'docs'))).toEqual(['MASTER.md']);
    } finally {
      await client?.close(); fs.rmSync(root, { recursive: true, force: true });
    }
  });
});
