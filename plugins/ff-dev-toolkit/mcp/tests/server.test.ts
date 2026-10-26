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

const connect = async (cwd: string): Promise<Client> => {
  const client = new Client({ name: 'vitest', version: '0.0.0' });
  const transport = new StdioClientTransport({ command: process.execPath, args: [DIST], cwd });
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
