# 抽出 fixture（抽出されるべきトークン側）

本文の `references/a.md` は抽出される。
兄弟スキルの `../skill-b/references/b.md` も抽出される。
ディレクトリ参照 `../skill-b/references/` も抽出される。
プラグインルート `../..` も抽出される。
fragment 付き `../category.md#ace-001` も抽出される（解決時に # 以降を落とす）。
1 行に複数ある `references/x.md` と `../y.md` は両方抽出される。
リンク形式 [原則](../docs-template/principles.md) も抽出される。
リンク形式の fragment 付き [節](references/z.md#sec) も抽出される。
バッククォートとリンクの混在行 `references/m.md` と [n](../n.md) は両方抽出される。

```text
フェンスをここで開いたまま EOF に達する → UNCLOSED_FENCE として構造違反になる。
フェンス内の `references/in-fence.md` は抽出されない（UNCLOSED_FENCE のみ報告）。
