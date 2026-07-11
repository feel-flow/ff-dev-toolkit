# spec-docs MCP server（dev-toolkit 同梱）

ターゲットプロジェクトの `docs/` ツリー（`/init-docs` が展開する AI仕様駆動開発のドキュメント構造）を、標準 MCP プロトコルの検索・参照ツールとして公開するサーバー。dev-toolkit プラグインの `.mcp.json` から自動起動される。

## ツール

| ツール | 内容 |
|---|---|
| `search` | docs/ 全体のキーワード検索（見出し重み付き、抜粋付き） |
| `extract_section` | 指定ファイルのレベル2見出しセクション抽出 |
| `glossary_lookup` | `docs/06-reference/GLOSSARY.md` の用語検索（大文字小文字無視） |
| `list_docs` | docs/ 配下の Markdown パス一覧（prefix フィルタ可） |
| `spec_lookup` | `docs/specs/**` の frontmatter `specId` による取得 |
| `spec_search` | spec の title / tags / summary の部分一致検索 |

## 設計メモ

- **プロジェクトルート解決**: `SPEC_DOCS_PROJECT_ROOT` env → `process.cwd()`。プラグイン設置場所は一切参照しない
- **索引対象**: `docs/` のみ（移植元が索引していた `docs-template/` / リポ直下 md は対象外 — 汎用化方針による）
- **鮮度**: 索引はツール呼び出しごとに再構築（docs ツリーは小さいため十分速く、長寿命サーバーでも stale にならない）
- **配布**: `dist/index.js` は esbuild による self-contained ESM バンドル（依存込み・コミット対象）。プラグインは `npm install` できないため
- **エラー意味論**: `null` / `[]` は「docs/ は健全だが該当なし」の場合に限る。前提が壊れている場合は構造化エラーを `isError` で返す — `DOCS_NOT_INITIALIZED`（docs/ 不在）/ `INDEX_BUILD_FAILED`（索引構築失敗）/ `FILE_NOT_ACCESSIBLE`（docs/ 外・非 .md・不在）/ `FILE_READ_FAILED`（I/O 失敗）。`extract_section` の見出しミスは `availableHeadings` 付きで返す
- **読み取り境界**: `extract_section` が読めるのは `docs/` 配下の実在する `.md` のみ（symlink は realpath 解決後に判定。プロジェクトルート内であっても docs/ 外は読めない）
- **frontmatter parser の既知の制約**: ネスト構造（`owners:` 配下のマップ等）・ブロックスカラー（`>-`）は簡易パースに留まる。引用符付きスカラーは対応済み。本格的な YAML 対応は必要になった時点で `yaml` パッケージのバンドルを検討

## 開発

```bash
npm install
npm run typecheck    # tsc --noEmit（strict）
npm test             # build してから vitest（utils + indexer + stdio e2e）
npm run build        # esbuild → dist/index.js（src 変更時は再ビルドしてコミット）
npm run verify:dist  # dist がコミット済み内容と一致するか検証（build 忘れ検知）
node dist/index.js --check   # cwd を対象に索引統計 + spec エラー内訳を表示（docs/ 不在は exit 1）
```

## トラブルシュート（プラグイン利用者向け）

- **前提**: `node` >= 18 が PATH にあること（バンドルは `--target=node18`、top-level await 使用）
- `/mcp` で spec-docs が failed になる場合: プロジェクトルートで `node <plugin>/mcp/dist/index.js --check` を実行して索引統計と WARNING を確認する
- ツールが `DOCS_NOT_INITIALIZED` を返す場合: `docs/` が無い。`/init-docs` を実行するか、`SPEC_DOCS_PROJECT_ROOT` で正しいプロジェクトを指す

初期実装は社内プロトタイプからの移植。移植時に旧 `custom/*` 独自メソッドを標準 MCP（`tools/list` / `tools/call`）へ書き直した — 旧実装は標準クライアントからツールが見えなかった。
