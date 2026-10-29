# spec-docs MCP server（ff-dev-toolkit 同梱）

ターゲットプロジェクトの `docs/` ツリー（`/init-docs` が展開する AI仕様駆動開発のドキュメント構造）を、標準 MCP プロトコルの検索・参照ツールとして公開するサーバー。ff-dev-toolkit プラグインの `.mcp.json` から自動起動される。

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
- **読み取り境界**: 全6ツールと `--check` は、独立に選択したプロジェクトの `docs/` 配下にある、保護された通常の `.md` を同じ読取処理で扱う。1ファイル4 MiBまで。外部リンク・壊れたリンク・特殊ファイル・安全性を確認できない権限は `INDEX_BUILD_FAILED` になる。本文の検索・用語・仕様解析・抽出は一度受け付けた内容を再利用する。
- **外部の共有 docs**: `docs/` 自体をプロジェクト外へリンクする場合、起動環境の `SPEC_DOCS_ALLOWED_DOCS_ROOT` に共有先の canonical な絶対パスを完全一致で指定して再起動する（例: macOS の `/tmp` は実体の `/private/tmp` 表記）。プロジェクト内の設定ファイルやリンク自体は許可を作らない。許可したルートの兄弟やその外への入れ子リンクは読めない。従来の自動許可からの変更であり、配布前に移行を案内する。
- **権限の前提**: 親ディレクトリを他ユーザーが置換できないことを先に確認する。同一ユーザーの悪意ある同時変更や特権ユーザーに対する隔離ではない。Windows は SID/ACL を確認できる native PowerShell が必要で、POSIX mode だけの代用はしない。権限を自動で緩めたり既存の親を chmod したりしない。
- **POSIX の group write**: 本人のみの私有 group かどうかの判定は行わない。0775/0664 等は、所有者のみの外側ディレクトリで保護されている場合を除き拒否する。必要な資料は管理者が保護された配置へ移し、拒否の自動解除は行わない。
- **frontmatter parser の既知の制約**: ネスト構造（`owners:` 配下のマップ等）・ブロックスカラー（`>-`）は簡易パースに留まる。引用符付きスカラーは対応済み。本格的な YAML 対応は必要になった時点で `yaml` パッケージのバンドルを検討

## 開発

```bash
npm install
npm run typecheck    # tsc --noEmit（strict、src + tests）
npm test             # build してから vitest（utils + indexer + stdio e2e）
npm run build        # esbuild → dist/index.js（src 変更時は再ビルドしてコミット）
npm run verify:dist  # dist がコミット済み内容と一致するか検証（build 忘れ検知）
node dist/index.js --check   # cwd を対象に索引統計 + spec エラー内訳を表示（docs/ 不在は exit 1）
```

- **型検査の位置づけ**: `vitest` も `npm run build`（esbuild）も transpile のみで型を見ないため、型検査は `npm run typecheck` だけが行う。これを `tests/mcp-typecheck/` から `tests/run-all.sh` へ配線してあり、検査範囲は `tsconfig.json` の `include`（`src` + `tests`）が正本になる（ADR-023）。`tsconfig.json` は `noEmit` 既定で、配布物 `dist/index.js` は esbuild だけが作る
- **`@ts-nocheck` / `@ts-ignore` は使わない**: これらはファイルを検査対象の一覧に残したまま検査だけを消すため、ゲートが「N ファイル・エラー 0 件」という偽の証明を出す。`tests/mcp-typecheck/` が混入を fail-closed で拒否する（判定は素のテキスト一致なので、`.ts` の中で語に言及しただけでも赤くなる）。抑制が必要な箇所は `@ts-expect-error` を使う

## トラブルシュート（プラグイン利用者向け）

- **前提**: `node` >= 22 が PATH にあること（バンドルは `--target=node22`、top-level await 使用。18/20 は EOL のためサポート外）。本パッケージの開発（vitest 実行・ビルド）は `engines` どおり >= 22.12.0 が必要（Vite 8 の engines 要求に合わせている）
- `/mcp` で spec-docs が failed になる場合: プロジェクトルートで `node <plugin>/mcp/dist/index.js --check` を実行して索引統計と WARNING を確認する
- ツールが `DOCS_NOT_INITIALIZED` を返す場合: `docs/` が無い。`/init-docs` を実行するか、`SPEC_DOCS_PROJECT_ROOT` で正しいプロジェクトを指す

初期実装は社内プロトタイプからの移植。移植時に旧 `custom/*` 独自メソッドを標準 MCP（`tools/list` / `tools/call`）へ書き直した — 旧実装は標準クライアントからツールが見えなかった。
