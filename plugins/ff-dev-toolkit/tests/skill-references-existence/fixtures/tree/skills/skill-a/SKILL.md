# 解決 fixture（skill-a 起点の相対パス解決）

存在するファイル `references/ok.md` は緑。
存在する兄弟ファイル `../skill-b/references/ok2.md` は緑。
存在する兄弟ディレクトリ `../skill-b/references/` は緑。
fragment 付きの実在参照 `references/ok.md#見出し` は緑（# 以降を落として解決）。
リンク形式の実在参照 [ok2](../skill-b/references/ok2.md) は緑。
存在しないファイル `references/gone.md` は赤。
存在しない兄弟ファイル `../skill-b/references/gone.md` は赤。
存在しないディレクトリ `../nope/references/` は赤。
ファイルへのディレクトリ参照 `references/ok.md/` は赤（末尾 / はディレクトリ実在を要求）。
リンク形式の欠落参照 [gone2](../skill-b/references/gone2.md) は赤。
実在するがプラグインルート外の `../../../outside.md` は赤（ESCAPES_PLUGIN_ROOT）。
末尾 .. のディレクトリ型脱出 `../../..` も赤（親のみの物理解決だと素通りする形）。
