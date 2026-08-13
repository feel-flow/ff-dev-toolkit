# repository Markdown lint

ルートの `.markdownlint.json` を使い、`git ls-files` が返す tracked Markdown 全体を
`markdownlint-cli2` で検査する。実行入口は次の 1 本に固定する。

```bash
bash plugins/ff-dev-toolkit/tests/markdownlint/verify.sh
```

依存は `plugins/ff-dev-toolkit/mcp/package.json` の devDependencies に置く。初回は同
ディレクトリで `npm ci` を実行する。`node_modules` が無ければ単体 suite は行頭
`○ skip` を返すが、`run-all.sh` の `REQUIRED_SUITES` が全体を非 0 にするため、
「markdownlint エラーなし」を未検証のまま通過させない。

## baseline 方針

設定で無効にしたルールは、既存の日本語文書、配布テンプレート、意図的な違反 fixture、
HTML を含むスキル資産に広く内在し、修正すると配布内容や fixture の意味を変えるもの。
代表例は長い日本語段落（MD013）、版ごとの同名見出し（MD024）、全角表（MD060）、
HTML を使うテンプレート（MD033）、意図的な Markdown 違反 fixture（MD018/MD048）。

無効化されていない既定ルールは引き続き有効である。自己テストは隔離 fixture に
MD009 の末尾空白を注入し、非 0・ファイル名・行番号・ルール名が出ることを固定する。
新しい既存違反を設定へ追加して baseline 化する場合は、配布内容を直せない理由と、
代替する検出力が残ることを同じ変更で記録する。
