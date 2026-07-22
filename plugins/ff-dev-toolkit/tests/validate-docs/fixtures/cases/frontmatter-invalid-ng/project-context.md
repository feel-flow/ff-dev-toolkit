# project-context: frontmatter-invalid-ng

> このファイルは `/validate-docs` のブラインド実行で `docs/` と一緒に実行エージェントへ渡す入力です。
> `expected.md` ではありません。docs 外のプロジェクト実態（テストコード・CI/CD・本番環境・コードコメント等）を固定し、周辺ワークスペース参照を不要にします。

## Docs 外シグナル

- ビジネスルール・エンティティ定義は docs 外やコードコメントに分散していない。
- 実装パターン・コーディング規約は `docs/MASTER.md` の最小ルール以外に分散していない。
- テストコードは存在しない。
- CI/CD 設定・本番環境定義は存在しない。

## プロジェクトツリー（抜粋）

```text
docs/
  MASTER.md
  01-context/PROJECT.md
  02-design/ARCHITECTURE.md
src/
README.md
```

## 補足

- `docs/` には条件付き4文書（DOMAIN / PATTERNS / TESTING / DEPLOYMENT）は含まれない。
- `tests/`, `__tests__/`, `*.test.*`, `.github/workflows/`, `deployment/`, `Dockerfile` は存在しない。
- 失敗させる対象は各コア文書の先頭 YAML Frontmatter に限定する（本文の必須セクション・内容は満たしている）。
