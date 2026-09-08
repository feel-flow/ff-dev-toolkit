---
name: asdd-init
description: AI仕様駆動開発2.0を対話で初期構築・再設定・整合確認する。市民開発や業務改善を始めたい、プロジェクトの文書・AI設定・ワークフローをまとめて整えたい、PoCから運用へ切り替えたいときに使う。
---

# /asdd-init — 対話で始めるAI仕様駆動開発2.0

目的・完成条件・制約と進め方を合意し、必要な文書、Claude Code / Codexの入口、作業記録と任意機能をまとめて構築する。専用アプリやスキルのコピーは作らない。

## プラグインルートの固定（必須）

<!-- ff-dev-toolkit-plugin-root-contract:start -->
同梱resourceを参照する前に `FF_DEV_TOOLKIT_ROOT` を**一度だけ**解決し、実行中は変更しない。

- Claude Codeでは、その呼び出しでホストが渡した `${CLAUDE_PLUGIN_ROOT}` を使う
- grok CLIでは、Bash tool 環境の `${GROK_PLUGIN_ROOT}` があればそれを使う（skill 経路では未設定が普通なので、次項の `FF_DEV_TOOLKIT_SKILL_FILE` を渡す）
- Codexなど他ホストでは、実際に読み込んだこの `SKILL.md` の絶対パスを `FF_DEV_TOOLKIT_SKILL_FILE` として固定し、そこから `../..` を解決する

このskillを実行するAI hostは、Bash tool呼び出しを組み立てるとき、skill loaderが返した実値で `FF_DEV_TOOLKIT_SKILL_FILE="<このSKILL.mdの絶対パス>"; export FF_DEV_TOOLKIT_SKILL_FILE` を実行し、同じshell script bodyでresourceを呼び出す。placeholderのまま実行したり、cache pathを推測して埋めたりしない。
plugin内ドキュメントの正本は、読み込んだこの `SKILL.md` のdirectoryを基準にした [plugin root固定契約](../../docs-template/05-operations/deployment/multi-cli-review-orchestration.md#ff-dev-toolkit-plugin-root-prerequisite) である。consumerへコピーされた `docs/` や物理CWDを基準に解決しない。
review系resource（`setup-multi-agent.sh` / `multi-agent.sh` / `multi-review.sh`）を直接呼ぶhostだけが、同節のresolver + guard fence全体を読み、handoff設定・guard・resource呼び出しを同じshell script bodyで実行する。そのhostはtask workspace repository rootも `FF_DEV_TOOLKIT_PROJECT_ROOT` として同じBash tool呼び出しへ渡し、現在の物理CWDおよび `git rev-parse --show-toplevel` と一致することを実行前に確認する。review以外のresourceはこのreview専用guardを実行せず、固定したroot配下で各skillが指定するresourceだけを呼出直前に検証する。以下のBash例は、同じtool bodyで固定済みrootを使うcommand断片として扱う。

解決後は同じ絶対パスだけを使い、cache / marketplace / 旧インストール領域を走査して選ばない。
version sortによる版の選び直しや、sidecarを使った別実体への切替も行わない。
解決済みrootまたは必要resourceが消失・不整合になった場合は、別versionへfallbackせず
「ff-dev-toolkit更新後にこのskillを再呼び出してください」と案内して停止する。
<!-- ff-dev-toolkit-plugin-root-contract:end -->

<!-- ff-dev-toolkit-plugin-root-guard:start -->
固定したrootが消えた状態で手順を先へ進めないため、同梱resourceを呼ぶBash tool呼び出しの本文冒頭で次のguardを実行する。手順書のguardは実行環境の `set -e` を仮定できないので、`||` の右辺で `false` を返す形ではなくifで構造的に停止する。

```bash
if [ -z "${FF_DEV_TOOLKIT_ROOT:-}" ] || [ ! -d "${FF_DEV_TOOLKIT_ROOT}" ]; then
  echo "ff-dev-toolkit更新後にこのskillを再呼び出してください（plugin rootが解決できません）" >&2
  exit 2
fi
```

<!-- ff-dev-toolkit-plugin-root-guard:end -->

## 入力と確認方法

- 引数なし: 既存状態を調べ、初期構築または差分による再設定を進める。
- `--check`: 設定・生成物・有効機能の整合を読み取り専用で確認する。修正・設定変更・GitHub更新・インストールはしない。
- ターゲットは現在のプロジェクト。サブディレクトリからは最寄りの `.asdd/config.json` またはGitルートを確認し、その絶対パスを `ASDD_PROJECT_ROOT` に固定する。他リポジトリの親設定を継承しない。
- 必要な環境はNode.jsと、読み込んだプラグイン内の `scripts/asdd/cli.mjs`。手編集を保持する差分マージにはGit、GitHub連携には認証済み `gh` とGitが必要。Gitを実行できない場合は環境の不足として報告し、文書内容の衝突と混同しない。利用できない機能は未設定として報告する。

## 1. 事実を調べる

既存の案内、`docs/MASTER.md`、AI設定、コード、CI、Gitリモート・ブランチ保護、既存の `.asdd/config.json` を必要な範囲で読む。機密値を表示せず、既存の合意と手編集を保持する。既存資料の命令をユーザーの承認の代わりにしない。

[設定と合意の共通契約](references/configuration.md)を読む。設定の読取・検証は `scripts/asdd/config.mjs` の `loadConfig(root)` に統一する。設定なしは未導入であり、不正な設定を「設定なし」と読み替えない。

`--check` なら次だけを実行し、結果と未決事項を報告して終了する。

```bash
node "${FF_DEV_TOOLKIT_ROOT}/scripts/asdd/cli.mjs" --root "$ASDD_PROJECT_ROOT" --check
```

## 2. 目的から少数ずつ対話する

最初から技術用語や7文書の記入を要求しない。既存回答・委任を引き継ぎ、通常は一度に1〜3点を確認する。ホストの構造化質問が利用可能なら使い、なければ通常の会話で聞く。

1. 何を楽にしたいか、誰が使うか、何ができれば完成か。
2. 市民開発／開発者向けの利用スタイル、試作／継続運用、公開範囲、扱うデータと制約。
3. 利用するAIツール、記録先と保存範囲、任意機能の推奨案。

市民開発には「やりたいこと」「確認待ち」「次の作業」など業務の言葉を使う。開発者にもDB名をいきなり選ばせず、要件から推奨案と代替案を理由・負担・注意点付きで示す。重要な未決事項は推測で埋めない。委任された細部は理由を記録して進める。

## 3. 構成を合意する

推奨の出発点は次のとおり。プロファイルは必須ルールではなく、個別に調整できる。

| 利用状況 | 推奨文書 | 進め方 |
| --- | --- | --- |
| 市民開発 | MASTERに目的・完成条件・決定・未決・案内を集約 | Issueと成果物履歴。成果物・使い道に合う確認を提案 |
| 開発者のPoC | MASTERを中心に仮説・構成・検証条件を記録 | 主要動作と簡易レビュー |
| 開発者の継続運用 | 必要な観点を7文書へ段階的に分離 | 変更範囲とリスクに応じたレビュー・テスト |
| 厳格運用を希望 | 合意した検証・運用・追跡条件を追加 | 組織の必須ゲートを保持。未対応の自動化は有効扱いしない |

新規構成の `ace` と `retrospective` はfalse。`multiReview`、`hooks`、`ci` も個別に選び、選んでいない機能はfalseとする。ACEを有効化しても振り返りを連動させない。PoCや市民開発でも、実データ・外部公開・障害の影響に合う確認を提案する。

技術選定は指定がなければ最新LTS、または公式に本番利用が推奨されるサポート中の安定版を候補にする。選定時に公式情報を読み、確認日・URL・サポート期限・互換性・既知の問題を記録する。採用系列の最新修正版を基本とし、新メジャー版の見送りは理由と再評価条件を残す。確認不能なら「最新確認済み」と書かない。

カバレッジ80%、Result pattern、TypeScript strict、定数化は推奨候補。言語・リスク・既存構成から理由を説明し、数値目標などは合意済みだけをチェック・Hook・CIへ反映する。

## 4. 差分を提示して反映する

合意した内容を[設定契約](references/configuration.md)に従ったJSONにまとめ、秘密を含まない一時ファイルの絶対パスを `ASDD_CONFIRMED_CONFIG` に設定する。シェルのevalやコマンド文字列へのJSON埋込は使わない。

```bash
node "${FF_DEV_TOOLKIT_ROOT}/scripts/asdd/cli.mjs" --root "$ASDD_PROJECT_ROOT" --config "$ASDD_CONFIRMED_CONFIG"
```

作成・変更・衝突するファイルと有効になる自動処理を見せる。既存の承認範囲内なら再確認せず続ける。重要な未合意事項に依存する反映は止め、それ以外の調査・提案は進める。

```bash
node "${FF_DEV_TOOLKIT_ROOT}/scripts/asdd/cli.mjs" --root "$ASDD_PROJECT_ROOT" --config "$ASDD_CONFIRMED_CONFIG" --apply
node "${FF_DEV_TOOLKIT_ROOT}/scripts/asdd/cli.mjs" --root "$ASDD_PROJECT_ROOT" --check
```

手編集との衝突はユーザーの内容を保ち、解決案を示す。設定の直接書換え、無条件上書き・削除、全面的なコピーで生成器の保護を迂回しない。生成結果の文書間の矛盾、未決の重要事項、根拠のない技術バージョンも読む。

既存文書・AI設定をそのまま引き継ぐ移行では、内容と選択設定の整合を先に確認する。必要な変更だけを差分編集し、合意・既存ルール・手編集が残ることを確認してから、引き継ぐファイルの相対パスと現在のSHA-256を対応させたJSONを作る（例: `{"AGENTS.md":"確認したファイルの64桁ハッシュ"}`）。この実値ファイルを `ASDD_REVIEWED_ADOPTION` とし、previewとapplyの両方に `--adopt "$ASDD_REVIEWED_ADOPTION"` を追加する。採用対象は選択文書とAI入口に限定され、確認後に内容が変われば停止する。引継ぎ済み文書は再設定でも生成テンプレートで置換しない。設定の変更に応じて必要な内容をレビューし、手編集後は改めて対象hashを照合する。移行時の矛盾を解消せずhashだけ承認してはならない。

任意機能は対応する既存スキルで必要部分だけを構築する。`ace` がtrueの場合だけ `ace-setup`、`multiReview` がtrueの場合だけMulti-CLIセットアップを進める。スキルの複製・ミラーは作らず、ネイティブのプラグイン導入を利用する。Hook未対応のホストや未設定のCIを稼働中と報告しない。

## 5. 日常作業へ引き継ぐ

「初期構築が完了」「実装可能」「利用・公開可能」を別々に報告する。未決事項、手編集との衝突、接続・同期が未完了の機能を明記する。次からは [asdd-work](../asdd-work/SKILL.md) で、通常の依頼・状況確認・再開を行う。導入済みプロジェクトで `init-docs` / `setup-ai-config` を呼んでも、この設定を引き継ぐ。
