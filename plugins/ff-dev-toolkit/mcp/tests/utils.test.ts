import { describe, it, expect } from 'vitest';
import { splitSections, parseScalar, parseFrontMatter, buildGlossary, maskNonGlossaryLines, maskClosedSpans } from '../src/utils.js';

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

// ---------- maskClosedSpans: インラインコードスパン / CRLF（Issue #527） ----------

/**
 * The Issue #527 reproduction: prose quoting `<!--` in an inline code span,
 * followed by a mermaid arrow (`-->`) that must not be taken as the closer.
 *
 * The last line is the composite case: two code spans plus a real comment on
 * one line, with the quoted marker sitting *after* the real one. It exercises
 * both the "skip spans" rule and the re-examination of the same line after a
 * comment is removed (the quoted marker must not open on the second pass).
 *
 * The same *cases* also appear, as separate input of the same shape (not the
 * same bytes), in the shared corpus the awk/TS mirror gate reads
 * (tests/docs-scan-mirror/fixtures/inline-code-span-quote.md) — that gate owns
 * the cross-implementation comparison, this test owns the TS expectation.
 */
const INLINE_MARKER_FIXTURE = [
  'マーカーは `<!--` と書く',
  '- **回帰ゲート（69 suite）**: 実体と一致するはず',
  '- 初期セット 20 ファイル',
  '```mermaid',
  'graph TD',
  '    A[x] --> B[y]',
  '```',
  'KEEP-AFTER',
  '`a` <!-- x --> `<!--`',
];

describe('maskClosedSpans (Issue #527)', () => {
  it('対になったインラインコードスパン内の <!-- はコメントを開始しない', () => {
    expect(maskClosedSpans(INLINE_MARKER_FIXTURE)).toEqual([
      'マーカーは `<!--` と書く',
      '- **回帰ゲート（69 suite）**: 実体と一致するはず',
      '- 初期セット 20 ファイル',
      '',
      '',
      '',
      '',
      'KEEP-AFTER',
      '`a`  `<!--`',
    ]);
  });

  it('コードスパン外の <!-- は従来どおりコメントを開始する（narrowing の縮小防止）', () => {
    expect(maskClosedSpans(['本文 <!-- 注 --> 続き'])).toEqual(['本文  続き']);
  });

  it('同一行にスパン内の <!-- と実コメントがあるとき、実コメントだけが開始になる', () => {
    expect(maskClosedSpans(['`<!--` の説明 <!-- 実コメント', '中身', '--> 残り'])).toEqual([
      '`<!--` の説明 ',
      '',
      ' 残り',
    ]);
  });

  it('閉じていないバックティックはスパンにならない（<!-- は開始として扱う）', () => {
    expect(maskClosedSpans(['`<!-- 閉じないスパン --> 続き'])).toEqual(['` 続き']);
  });

  it('CRLF 行末でも閉じたフェンスをマスクする（awk 版と同じ判断）', () => {
    expect(maskClosedSpans(['```text\r', '中身\r', '```\r', 'KEEP\r'])).toEqual(['', '', '', 'KEEP\r']);
  });
});

// ---------- 実利用経路（用語集索引）での固定（Issue #527 統合経路） ----------
//
// maskClosedSpans 単体の期待値だけを固定すると、内部表現を変えたリファクタで
// 「マスクは正しいのに索引から用語が消える」形の回帰を取り逃す。本 Issue の実害は
// **用語が索引から静かに落ちること**なので、公開 API の buildGlossary を通した
// 用語集合そのものをここで固定する。
//
// マーカー行に `-->` を同居させないのが判別力の要: 同居させると narrowing 前の実装でも
// 同一行内で対が閉じてしまい、どのケースも緑になって何も測れない。
describe('buildGlossary: 引用マーカーが用語索引を落とさない（Issue #527）', () => {
  it('コードスパン内の <!-- と後続 mermaid 矢印の間にある用語も索引される', () => {
    const md = [
      '雛形は `<!--` で開いて書く',
      '',
      '### ACE',
      '',
      'Agentic Context Engineering',
      '',
      '```mermaid',
      'graph TD',
      '    A[x] --> B[y]',
      '```',
      '',
      '### SSOT',
      '',
      '単一の情報源',
    ].join('\n');
    const result = buildGlossary(md);
    expect(Object.keys(result).sort()).toEqual(['ACE', 'SSOT']);
    expect(result['ACE']).toBe('Agentic Context Engineering');
  });

  it('引用マーカーの後にある実コメント内の用語は索引に入らない', () => {
    const md = [
      '雛形は `<!--` で開いて書く',
      '',
      '<!--',
      '### 雛形用語',
      '',
      '雛形の定義',
      '-->',
      '',
      '### ACE',
      '',
      'Agentic Context Engineering',
    ].join('\n');
    expect(Object.keys(buildGlossary(md))).toEqual(['ACE']);
  });

  it('引用マーカー・実コメント・フェンスが同居しても公開用語集合が期待どおり', () => {
    const md = [
      'この節では `<!--` をマーカーとして説明する',
      '',
      '### 用語1',
      '',
      '定義1',
      '',
      '<!-- ### 雛形A は索引に入らない -->',
      '',
      '```markdown',
      '### 雛形B',
      '',
      '<定義>',
      '```',
      '',
      '### 用語2',
      '',
      '定義2',
      '',
      '```mermaid',
      'graph TD',
      '    用語1 --> 用語2',
      '```',
      '',
      '- SSOT: 単一の情報源',
    ].join('\n');
    expect(Object.keys(buildGlossary(md)).sort()).toEqual(['SSOT', '用語1', '用語2']);
  });
});

// ---------- awk 版との一致は tests/docs-scan-mirror へ移設（Issue #528） ----------
//
// ここには fixture 2 件ぶんの暫定照合（`ff_docs_mask_spans` を bash 経由で叩いて
// 比較する）が置かれていたが、コーパスを 2 箇所に持つことになるうえ、AC-1 が要求する
// 境界ケース（未閉鎖 opener / 記号混在 / フェンス長 / 末尾 opener など）を網羅できない。
// 常設の mirror ゲートは tests/docs-scan-mirror/verify.sh（run-all.sh の
// REQUIRED_SUITES 登録済み）が担う。**このファイルには awk 側との照合を再び書かない**
// — 二重化すると片方だけ更新されて、どちらが正本か分からなくなる。
//
// 上の describe は TS 側単体の意味論（Issue #527 の narrowing）を固定するもので、
// mirror ゲートとは関心事が違うのでここに残す。
