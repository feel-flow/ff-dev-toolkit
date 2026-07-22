# project-context: empty-section-stated-ok

> このファイルは `/validate-docs` のブラインド実行で `docs/` と一緒に実行エージェントへ渡す入力です。
> `expected.md` ではありません。docs 外のプロジェクト実態（テストコード・CI/CD・本番環境・コードコメント等）を固定し、周辺ワークスペース参照を不要にします。

## Docs 外シグナル

- `docs/02-design/DOMAIN.md` が入力に含まれる。
- 実装パターン・コーディング規約は `docs/MASTER.md` の最小ルール以外に分散していない。
- テストコードは存在しない。
- CI/CD 設定・本番環境定義は存在しない。

## プロジェクトツリー（抜粋）

```text
docs/
  MASTER.md
  01-context/PROJECT.md
  02-design/ARCHITECTURE.md
  02-design/DOMAIN.md
cmd/
internal/
```

## 補足

- `docs/02-design/DOMAIN.md` は存在し、状態遷移セクションには「該当なし」と状態明記がある。
- `tests/`, `__tests__/`, `*.test.*`, `.github/workflows/`, `deployment/`, `Dockerfile` は存在しない。
