# 抽出 fixture（非検出側 = 誤検知源のデコイ集）

散文中の references/plain.md への言及はバッククォートが無いので抽出されない。
プレースホルダの `../<category>.md#ace-xxx` は `<>` を含むので抽出されない。
グロブの `references/*.md` は `*` を含むので抽出されない。
空白を含む `references/ 配下のファイル` は抽出されない（パスではなく散文）。
接頭辞が異なる `docs/references/x.md` は抽出されない（本検査の対象は ../ と references/ 起点のみ）。
インラインコード内のリンク記法例 `[x](../fake.md)` は抽出されない（実パス主張ではない）。
リンク形式でもスキーム付き [外部](https://example.com/references/x.md) は抽出されない。
リンク形式でもアンカーのみ [節へ](#見出し) は抽出されない。
リンク形式でも消費側プロジェクト起点 [正本](docs/08-knowledge/PLAYBOOK.md) は抽出されない。
リンク形式でもプレースホルダ [live](../<category>.md#ace-yyy) は抽出されない。

```markdown
レポート例のフェンス内は抽出されない:
- パス: `../images/missing.jpeg`
- パス: `references/gone-in-fence.md`
- リンク: [索引](../../PLAYBOOK.md#エントリ一覧)
```

~~~text
チルダフェンス内の `../also/in-fence.md` も抽出されない。
~~~

フェンスが正しく閉じていれば UNCLOSED_FENCE も出ない。
