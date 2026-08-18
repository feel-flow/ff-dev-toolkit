import { describe, it, expect } from 'vitest';
import { splitSections, parseScalar, parseFrontMatter, buildGlossary, maskNonGlossaryLines } from '../src/utils.js';

// ---------- splitSections ----------
describe('splitSections', () => {
  it('空文字列からは1つの空セクションを返す', () => {
    const result = splitSections('');
    expect(result).toHaveLength(1);
    expect(result[0].title).toBe('');
  });

  it('## 見出しで正しく分割する', () => {
    const md = `# Title\nIntro text\n## Section A\nContent A\n## Section B\nContent B`;
    const result = splitSections(md);
    expect(result).toHaveLength(3); // intro + A + B
    expect(result[0].title).toBe('');
    expect(result[1].title).toBe('Section A');
    expect(result[1].content).toContain('Content A');
    expect(result[2].title).toBe('Section B');
    expect(result[2].content).toContain('Content B');
  });

  it('## のみの見出し（レベル2）で分割し、### は無視する', () => {
    const md = `## Top\n### Sub\nDetail\n## Another`;
    const result = splitSections(md);
    expect(result).toHaveLength(2);
    expect(result[0].title).toBe('Top');
    expect(result[0].content).toContain('### Sub');
    expect(result[1].title).toBe('Another');
  });

  it('file フィールドは常に空文字列', () => {
    const result = splitSections('## Test\nContent');
    for (const s of result) {
      expect(s.file).toBe('');
    }
  });
});

// ---------- parseScalar ----------
describe('parseScalar', () => {
  it('空配列 "[]" を空配列に変換', () => {
    expect(parseScalar('[]')).toEqual([]);
  });

  it('配列 "[a, b, c]" をパース', () => {
    expect(parseScalar('[a, b, c]')).toEqual(['a', 'b', 'c']);
  });

  it('true/false をbooleanに変換', () => {
    expect(parseScalar('true')).toBe(true);
    expect(parseScalar('false')).toBe(false);
  });

  it('数値文字列を数値に変換', () => {
    expect(parseScalar('42')).toBe(42);
    expect(parseScalar('0')).toBe(0);
  });

  it('それ以外は文字列のまま返す', () => {
    expect(parseScalar('hello world')).toBe('hello world');
  });

  it('前後の空白をトリムする', () => {
    expect(parseScalar('  42  ')).toBe(42);
    expect(parseScalar('  true  ')).toBe(true);
  });
});

// ---------- parseFrontMatter ----------
describe('parseFrontMatter', () => {
  it('front matterがない場合は空metaと全体をbodyとして返す', () => {
    const result = parseFrontMatter('Just some text');
    expect(result.meta).toEqual({});
    expect(result.body).toBe('Just some text');
  });

  it('基本的なfront matterをパースする', () => {
    const raw = `---\ntitle: Hello\nstatus: draft\nversion: 1\n---\nBody content`;
    const result = parseFrontMatter(raw);
    expect(result.meta.title).toBe('Hello');
    expect(result.meta.status).toBe('draft');
    expect(result.meta.version).toBe(1);
    expect(result.body).toBe('Body content');
  });

  it('閉じ境界がない場合は空metaを返す', () => {
    const raw = `---\ntitle: Hello\nno closing`;
    const result = parseFrontMatter(raw);
    expect(result.meta).toEqual({});
    expect(result.body).toBe(raw);
  });

  it('配列値をパースする', () => {
    const raw = `---\ntags: [api, backend]\n---\nContent`;
    const result = parseFrontMatter(raw);
    expect(result.meta.tags).toEqual(['api', 'backend']);
  });

  it('リスト形式の配列をパースする', () => {
    const raw = `---\nowners:\n  - alice\n  - bob\n---\nContent`;
    const result = parseFrontMatter(raw);
    expect(result.meta.owners).toEqual(['alice', 'bob']);
  });

  it('空値と >- をパースする', () => {
    const raw = `---\nempty:\nsummary: >-\n---\nContent`;
    const result = parseFrontMatter(raw);
    expect(result.meta.empty).toBe('');
    expect(result.meta.summary).toBe('');
  });
});

// ---------- buildGlossary ----------
describe('buildGlossary', () => {
  it('箇条書き形式の用語をパースする', () => {
    const md = `- SSOT: Single Source of Truth\n- MVP: Minimum Viable Product`;
    const result = buildGlossary(md);
    expect(result['SSOT']).toBe('Single Source of Truth');
    expect(result['MVP']).toBe('Minimum Viable Product');
  });

  it('### 見出し形式の用語をパースする', () => {
    const md = `### API\n\nApplication Programming Interface`;
    const result = buildGlossary(md);
    expect(result['API']).toBe('Application Programming Interface');
  });

  it('括弧付き見出しから用語を抽出する', () => {
    const md = `### SSOT (Single Source of Truth)\n\n唯一の信頼できる情報源`;
    const result = buildGlossary(md);
    expect(result['SSOT']).toBe('唯一の信頼できる情報源');
  });

  it('空文字列からは空のGlossaryを返す', () => {
    const result = buildGlossary('');
    expect(result).toEqual({});
  });

  it('箇条書きと見出しが混在する場合、箇条書きが優先される', () => {
    const md = `- API: REST interface\n\n### API\n\nApplication Programming Interface`;
    const result = buildGlossary(md);
    expect(result['API']).toBe('REST interface');
  });

  // ---- Issue #517: 走査対象外の領域 ----

  it('閉じた HTML コメント内の ### 見出しを用語として登録しない', () => {
    const md = [
      '<!-- 用語を追加するときの形式:',
      '',
      '### <用語>（<英語表記>）',
      '',
      '<定義と説明>',
      '-->',
      '',
      '### ACE',
      '',
      'Agentic Context Engineering',
    ].join('\n');
    const result = buildGlossary(md);
    expect(Object.keys(result)).toEqual(['ACE']);
  });

  it('1 行で閉じた HTML コメント内の見出しも登録しない', () => {
    const md = `<!-- ### 雛形 -->\n\n### ACE\n\nAgentic Context Engineering`;
    expect(Object.keys(buildGlossary(md))).toEqual(['ACE']);
  });

  it('閉じたコードフェンス内の ### 見出しを用語として登録しない', () => {
    const md = [
      '```markdown',
      '### <用語>',
      '',
      '<定義>',
      '```',
      '',
      '### ACE',
      '',
      'Agentic Context Engineering',
    ].join('\n');
    expect(Object.keys(buildGlossary(md))).toEqual(['ACE']);
  });

  it('~~~ フェンスも同様に除外する', () => {
    const md = `~~~text\n### <用語>\n\n<定義>\n~~~\n\n### ACE\n\nAgentic Context Engineering`;
    expect(Object.keys(buildGlossary(md))).toEqual(['ACE']);
  });

  it('コメント / フェンス外の実見出しは従来どおり登録する', () => {
    const md = [
      '### suite',
      '',
      'ゲートの最小単位',
      '',
      '<!-- 雛形は見出し行として書かない -->',
      '',
      '### SSOT',
      '',
      '単一の情報源',
    ].join('\n');
    const result = buildGlossary(md);
    expect(result['suite']).toBe('ゲートの最小単位');
    expect(result['SSOT']).toBe('単一の情報源');
  });

  it('複数のコメント / フェンスをそれぞれ正しく除外する', () => {
    const md = [
      '<!-- ### 雛形A -->',
      '',
      '### 用語1',
      '',
      '定義1',
      '',
      '```',
      '### 雛形B',
      '',
      '本文',
      '```',
      '',
      '### 用語2',
      '',
      '定義2',
    ].join('\n');
    const result = buildGlossary(md);
    expect(Object.keys(result).sort()).toEqual(['用語1', '用語2']);
  });

  it('閉じていない HTML コメントは後続の正規用語を消さない（fail-safe）', () => {
    const md = `<!-- 閉じ忘れ\n\n### ACE\n\nAgentic Context Engineering`;
    const result = buildGlossary(md);
    expect(result['ACE']).toBe('Agentic Context Engineering');
  });

  it('閉じていないコードフェンスは後続の正規用語を消さない（fail-safe）', () => {
    const md = '```\n\n### ACE\n\nAgentic Context Engineering';
    const result = buildGlossary(md);
    expect(result['ACE']).toBe('Agentic Context Engineering');
  });

  it('コメント内外に同名見出しがある場合、実見出しの定義が入る', () => {
    const md = `<!--\n### ACE\n\nコメント側の定義\n-->\n\n### ACE\n\n実体側の定義`;
    expect(buildGlossary(md)['ACE']).toBe('実体側の定義');
  });

  it('## Changelog 節の "- 何か: 説明" 箇条書きを用語として登録しない', () => {
    const md = [
      '### ACE',
      '',
      'Agentic Context Engineering',
      '',
      '## Changelog',
      '',
      '### [1.1.0] - 2026-08-17',
      '',
      '#### 追加',
      '',
      '- 2 巡目レビューの指摘: シムの根拠を訂正',
      '- 固有語 23 件を収録（API: HTTP API を提供しない）',
    ].join('\n');
    const result = buildGlossary(md);
    expect(Object.keys(result)).toEqual(['ACE']);
  });

  it('Changelog 節の ### 見出し（版番号）も用語にしない', () => {
    const md = `### ACE\n\n定義\n\n## Changelog\n\n### [2.0.0] - 2026-08-17\n\n#### 変更\n\n本文全体を書き換え`;
    expect(Object.keys(buildGlossary(md))).toEqual(['ACE']);
  });

  // ---- レビュー指摘（PR #523）: 除外判定そのものの境界 ----

  it('フェンス内の "## Changelog" は本物の節として扱わない（以降の用語を消さない）', () => {
    const md = [
      '```markdown',
      '## Changelog',
      '```',
      '',
      '### ACE',
      '',
      'Agentic Context Engineering',
    ].join('\n');
    expect(buildGlossary(md)['ACE']).toBe('Agentic Context Engineering');
  });

  it('HTML コメント内の "## Changelog" も以降の用語を消さない', () => {
    const md = `<!--\n## Changelog\n-->\n\n### ACE\n\nAgentic Context Engineering`;
    expect(buildGlossary(md)['ACE']).toBe('Agentic Context Engineering');
  });

  it('4 連バッククォートのフェンス内に 3 連の例を置いても外側が閉じない', () => {
    const md = [
      '````markdown',
      '```',
      '### <雛形A>',
      '```',
      '',
      '### <雛形B>',
      '',
      '<定義>',
      '````',
      '',
      '### ACE',
      '',
      'Agentic Context Engineering',
    ].join('\n');
    expect(Object.keys(buildGlossary(md))).toEqual(['ACE']);
  });

  it('info string 付きフェンス行は閉じフェンスにならない', () => {
    const md = [
      '```markdown',
      '```ts',
      '### <雛形>',
      '',
      '<定義>',
      '```',
      '',
      '### ACE',
      '',
      'Agentic Context Engineering',
    ].join('\n');
    expect(Object.keys(buildGlossary(md))).toEqual(['ACE']);
  });

  it('閉じた HTML コメント内のフェンス記号が外側の用語を消さない', () => {
    const md = [
      '<!--',
      '```',
      '-->',
      '',
      '### ACE',
      '',
      'Agentic Context Engineering',
      '',
      '### suite',
      '',
      'ゲートの最小単位',
    ].join('\n');
    const result = buildGlossary(md);
    expect(result['ACE']).toBe('Agentic Context Engineering');
    expect(result['suite']).toBe('ゲートの最小単位');
  });

  it('閉じ忘れマーカーの後にある「閉じた span」もきちんと除外する', () => {
    const md = [
      '<!-- 閉じ忘れ',
      '',
      '### 用語1',
      '',
      '定義1',
      '',
      '```',
      '### <雛形>',
      '',
      '<定義>',
      '```',
      '',
      '### 用語2',
      '',
      '定義2',
    ].join('\n');
    const result = buildGlossary(md);
    expect(Object.keys(result).sort()).toEqual(['用語1', '用語2']);
  });

  it('行内コメント付きの見出しは用語として残る', () => {
    const md = `### ACE <!-- 補足: 略称 -->\n\nAgentic Context Engineering`;
    expect(buildGlossary(md)['ACE']).toBe('Agentic Context Engineering');
  });

  it('行内コメント付きの箇条書きも用語として残る', () => {
    const md = `- SSOT: Single Source of Truth <!-- 単一の情報源 -->`;
    expect(buildGlossary(md)['SSOT']).toBe('Single Source of Truth');
  });

  it('複数行コメントの終了行に続く本文（-->の後ろ）は保持される', () => {
    // buildGlossary 経由では検証できない: markdown では `--> ### x` は行頭でないため
    // 見出しにならない。保持そのものをマスク関数の出力で直接確かめる
    const masked = maskNonGlossaryLines(['<!--', '雛形', '--> 残すべき本文']);
    expect(masked).toEqual(['', '', ' 残すべき本文']);
  });

  it('同一行に 2 つのコメントがあっても両方除去し、外側は残る', () => {
    const md = `### ACE <!-- a --><!-- b -->\n\nAgentic Context Engineering`;
    expect(buildGlossary(md)['ACE']).toBe('Agentic Context Engineering');
  });

  it('フェンス内の <!-- は外側のコメントと対にならない', () => {
    const md = [
      '```',
      '<!--',
      '```',
      '',
      '### ACE',
      '',
      'Agentic Context Engineering',
    ].join('\n');
    expect(buildGlossary(md)['ACE']).toBe('Agentic Context Engineering');
  });

  it('異なる記号（``` と ~~~）は互いを閉じない', () => {
    const md = [
      '```',
      '~~~',
      '### <雛形>',
      '',
      '<定義>',
      '```',
      '',
      '### ACE',
      '',
      'Agentic Context Engineering',
    ].join('\n');
    expect(Object.keys(buildGlossary(md))).toEqual(['ACE']);
  });
});
