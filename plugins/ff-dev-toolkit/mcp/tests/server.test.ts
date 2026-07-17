/**
 * End-to-end tests against the built server bundle (dist/index.js) over real
 * stdio MCP, using the official SDK client. `npm test` builds before running
 * (see package.json), which doubles as a src/dist drift guard.
 */
import { describe, it, expect, beforeAll, afterAll } from 'vitest';
import path from 'path';
import url from 'url';
import fs from 'fs';
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
