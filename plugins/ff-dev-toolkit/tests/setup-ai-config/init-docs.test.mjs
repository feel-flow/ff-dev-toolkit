import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';

const skill = fs.readFileSync(new URL('../../skills/init-docs/SKILL.md', import.meta.url), 'utf8');
const master = fs.readFileSync(new URL('../../docs-template/MASTER.md', import.meta.url), 'utf8');

function entry(source, masterSource = master) {
  const sections = [...source.matchAll(/^### 4-b\. 共通入口 AGENTS\.md の作成\n([\s\S]*?)(?=^### 5\. )/gm)];
  assert.equal(sections.length, 1, '共通入口の手順は1節必要');
  const masterStep = source.indexOf('### 4. MASTER.md');
  assert.ok(masterStep >= 0 && masterStep < sections[0].index, 'MASTER カスタマイズ後に入口を作る');
  const section = sections[0][1];
  assert.match(section, /標準の生成物は `AGENTS\.md` だけ/);
  assert.match(section, /`AGENTS\.md` が既にある場合は上書きしない/);
  assert.match(section, /既存の `CLAUDE\.md` なども自動で削除・置換しない/);
  const fences = [...section.matchAll(/^```markdown\n([\s\S]*?)^```$/gm)];
  assert.equal(fences.length, 1, 'AGENTS.md のテンプレートは1本必要');
  const body = fences[0][1];
  assert.match(body, /^# AGENTS\.md\n/);
  assert.match(body, /\[docs\/MASTER\.md\]\(docs\/MASTER\.md\).*最初に読む/);
  assert.match(body, /MASTER\.md の索引から/);
  assert.match(body, /情報不足時の必須確認プロトコル/);
  const protocol = body.match(/MASTER\.md の「([^」]+)」/);
  assert.ok(protocol, '参照するプロトコル名が必要');
  assert.ok(masterSource.split('\n').includes(`### ${protocol[1]}`), '参照先 MASTER の見出しが必要');
  assert.match(body, /既存の合意・組織ルール・手編集を保持/);
  assert.match(body, /秘密情報を出力・コミットしない/);
  assert.doesNotMatch(body, /CLAUDE\.md|CLAUDE_PLUGIN_ROOT|FF_DEV_TOOLKIT_ROOT/);
  return body;
}

test('legacy init-docs supplies a portable AGENTS.md entry after MASTER customization', () => {
  entry(skill);
  assert.match(skill, /v2\.1\.277/);
  assert.match(skill, /`CLAUDE\.local\.md`/);
  assert.match(skill, /`@AGENTS\.md` の import/);
  assert.match(skill, /ユーザー設定も自動変更しない/);
  assert.match(skill, /合意済みのツール設定を変更しない/);
  const report = skill.split('### 5. 完了報告\n')[1]?.split('### 6.')[0];
  assert.ok(report);
  assert.match(report, /`AGENTS\.md` を作成したか、既存のため保持したか/);
  assert.match(report, /ファイルの作成だけで読み込み済みとは報告しない/);
});

test('missing, empty, renamed or duplicated entry sections fail closed', () => {
  const removed = skill.replace(/^### 4-b\.[\s\S]*?(?=^### 5\.)/m, '');
  for (const source of ['', removed, skill.replace('### 4-b.', '### 4-c.'),
    skill.replace('### 4. MASTER.md', '### 4. Changed'), `${skill}\n${skill}`,
    skill.replace('`AGENTS.md` が既にある場合は上書きしない', '既存ファイルを使う')]) {
    assert.throws(() => entry(source));
  }
});

test('a named entry with an empty, renamed or incomplete template fails closed', () => {
  for (const transform of [
    body => body.replace(/[^\n]+/g, ''),
    body => body.replace('# AGENTS.md', '# CLAUDE.md'),
    body => `${body}\nCLAUDE.md も読む\n`,
    body => body.replace('](docs/MASTER.md)', '](MASTER.md)'),
    body => body.replace('MASTER.md の索引から', '文書を読む'),
    body => body.replace('情報不足時の必須確認プロトコル', '確認する'),
    body => body.replace('秘密情報を出力・コミットしない', '秘密情報に注意する'),
  ]) {
    const original = entry(skill);
    assert.throws(() => entry(skill.replace(original, transform(original))));
  }
});

test('a missing or renamed protocol in MASTER fails closed even when the entry keeps its name', () => {
  for (const source of ['', master.replace('### 情報不足時の必須確認プロトコル', '### 改名済み')]) {
    assert.throws(() => entry(skill, source));
  }
});
