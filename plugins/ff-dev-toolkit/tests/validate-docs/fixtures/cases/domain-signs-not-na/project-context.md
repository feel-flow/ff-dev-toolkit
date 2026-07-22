# project-context: domain-signs-not-na

> このファイルは `/validate-docs` のブラインド実行で `docs/` と一緒に実行エージェントへ渡す入力です。
> `expected.md` ではありません。docs 外のプロジェクト実態（テストコード・CI/CD・本番環境・コードコメント等）を固定し、周辺ワークスペース参照を不要にします。

## Docs 外シグナル

- タスク状態遷移と差し戻し可否のルールが `docs/02-design/ARCHITECTURE.md` と `src/task.ts` コメントに分散している。
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
  task.ts
README.md
```

## 補足

- `src/task.ts` には docs/02-design/ARCHITECTURE.md と同じタスク状態遷移ルールを説明するコメントがある。
- `tests/`, `__tests__/`, `*.test.*`, `.github/workflows/`, `deployment/`, `Dockerfile` は存在しない。
