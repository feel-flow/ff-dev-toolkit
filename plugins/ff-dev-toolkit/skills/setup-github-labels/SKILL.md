---
name: setup-github-labels
description: Use when setting up recommended GitHub labels for a repository. 推奨ラベル構成（GitHub デフォルト + バージョニング・緊急度のカスタムラベル）のうち不足分だけを冪等に作成する。「ラベルを整備して」「ラベルをセットアップして」「推奨ラベルを作って」「set up labels」「create the recommended labels」と言われたとき、および create-issue や Git Workflow の実在確認（verify-then-skip）がラベル不在を報告したときに使用する。起票時にラベルを付けるのは create-issue（あちらはラベルを作らない）。本スキルはリポジトリ設定を変更する側で、既存ラベルには触れない。
---

# /setup-github-labels — 推奨ラベル構成の冪等セットアップ

対象リポジトリに、AI Spec-Driven Development の推奨カスタムラベル（`major` / `minor` / `patch` / `hotfix` / `urgent`）のうち**存在しないものだけ**を作成します。既存ラベルの色・説明は変更しません。

推奨ラベル構成の定義と背景は `docs-template/05-operations/deployment/github-setup.md`（導入済みプロジェクトでは `docs/05-operations/deployment/github-setup.md`）を参照してください。

## プラグインルートの解決

同梱ファイルを参照する前に `FF_DEV_TOOLKIT_ROOT` を解決する。Claude Code では `${CLAUDE_PLUGIN_ROOT}` を使い、Codex など他ホストでは読み込んだこの `SKILL.md` の絶対パスから `../..` を解決する。以下の `${FF_DEV_TOOLKIT_ROOT}` はその絶対パスを指す。バージョン別 cache を探索して選ばない。

## 前提

- GitHub CLI（`gh`）がインストール・認証済みであること
- 対象リポジトリへのラベル作成権限があること

## 手順

### 1. 対象リポジトリの確認

本スキルは**リポジトリ設定を変更する**（ラベルを作成する）。起票と違って Issue 単位で取り消せる操作ではないため、対象リポジトリ（`OWNER/REPO`）をユーザーの意図と突き合わせてから実行する。ユーザーが対象を明示していない場合はカレントリポジトリ（`gh repo view`）を候補として提示し、確認を取る。確認を挟まない自律フローから呼ばれた場合も、作業対象として文脈上確定しているリポジトリ以外へは適用しない。

### 2. セットアップスクリプトの実行

同梱スクリプトを実行する。ラベル定義の正本（SSOT）はスクリプト内の `LABEL_DEFS` ブロックで、`github-setup.md` の推奨ラベル表との一致は `tests/github-labels-setup/verify.sh` が検査している。

```bash
bash "${FF_DEV_TOOLKIT_ROOT}/docs-template/scripts/setup-github-labels.sh" --repo "OWNER/REPO"
```

消費プロジェクトが `scripts/setup-github-labels.sh` として同スクリプトをコピー済みの場合（`github-setup.md` の「自動セットアップ」手順)は、そちらを実行してもよい（コピー時点では同一内容。ただしコピーは toolkit 更新後に drift しうるので、差分がある場合は同梱実体を優先する）。プロジェクトに常備したい場合は `${FF_DEV_TOOLKIT_ROOT}/docs-template/scripts/setup-github-labels.sh` をプロジェクトの `scripts/` へコピーする。

スクリプトの動作:

- `gh label list` で実在を確認し、**不足しているラベルだけ**を作成する（既存ラベルの色・説明には触れない。再実行しても安全な冪等動作）
- ラベル一覧を信用できない場合（照会失敗・空の一覧・取得上限到達）は、**1 件も作成せず**非 0 で終了する（fail-closed）。「存在しない」と誤断定したまま作成に進むと、実在するラベルへの作成失敗や重複整備が起きるため

### 3. 完了報告

スクリプトが標準出力へ書き出す `CREATED=` / `SKIPPED_EXISTING=` / `FAILED=` の行を**そのまま読んで**報告する（記憶からは書かない）。あわせて:

- 非 0 終了で 1 件も作成されなかった場合は、「ラベルが存在しない」ではなく「**実在を確認できなかった**」として理由（照会失敗・空の一覧・上限到達のいずれか）を報告し、理由に対応する次のアクションを提案する: 照会失敗なら `gh auth status` の確認、空の一覧や対象の取り違えの疑いなら `--repo` の明示指定、上限到達（ラベルが 200 件以上あるリポジトリ）なら `github-setup.md` の「手動セットアップ」での個別作成またはラベル体系の整理
- `FAILED=` が非空の場合は、権限不足（ラベル作成には write 権限が必要）の可能性を添える

## 重要ルール

- 既存ラベルを変更・削除しないこと（`gh label create --force` や `gh label edit` を使わない。消費プロジェクトが意図的に変えた色・説明を上書きしない）
- 対象リポジトリを確認せずに実行しないこと（リポジトリ設定の変更であり、暗黙の `GH_REPO` / cwd 任せにしない）
- ラベル定義を変えるときはスクリプトの `LABEL_DEFS`・`github-setup.md` の推奨ラベル表・同ページの手動セットアップ例の 3 箇所を同時に変えること（件数が変わる場合は `tests/github-labels-setup/verify.sh` の `EXPECTED_LABEL_COUNT` も）。一部だけ直すと `tests/github-labels-setup` が red になる
- 報告はスクリプトの出力を写すこと。付与系スキル（create-issue）との棲み分け: あちらは起票時に**既存ラベルを付けるだけ**（作らない）、こちらは**ラベルを作るだけ**（Issue には触れない）
