---
name: spec-driven
description: 開発タスクを仕様駆動の5ゲート（要件→仕様→計画→実装→検証）で進行管理するスキル。機能要求や Issue を受けたとき、受け入れ基準の確定と仕様文書の先行更新をゲートとして強制し、進行表に証拠付きで記録する。「仕様駆動で進めて」「spec-driven」「ゲート管理して」「要件から順に固めて」「受け入れ基準を決めてから実装して」と言われたとき、または曖昧な機能要求のまま実装に入りそうなときに使用。
---

# 仕様駆動ゲート管理（spec-driven）

## ASDD 2.0 設定がある場合

最初に[共通設定契約](../asdd-init/references/configuration.md)を読み、`scripts/asdd/config.mjs` の `loadConfig(root)` で対象プロジェクトの `.asdd/config.json` を検証する。以下の従来手順より、合意済みの文書構成・機能スイッチ・ワークフローを優先する。設定なしは従来互換、不正設定は自動処理を止めて診断する。

合意した確認方法だけを適用する。カバレッジ80%、Result pattern、strict、定数化などの推奨を未合意のゲートにしない。ACE・振り返り・複数AIレビューの無効設定を尊重し、チェーン末尾にも追加しない。市民開発のIssue中心運用では、既存の組織ルールを保ちつつ、未採用のPR・7文書を必須化しない。

開発セッションを「要件確認 → 仕様 → 計画 → 実装 → 検証」の5ゲートで統制する。
FeelFlow の書籍『AI仕様駆動開発』の方法論を蒸留したもの。成果物ドキュメントを作る genai-consultant 系と違い、**開発の進行そのものを駆動する**プロセススキル。

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

## 成果物

**ゲート進行表** `spec-driven-gates-{タスクslug}-{YYYYMMDD}.md`（YYYYMMDD は**開始日＝初回実行日**〔実行環境のローカルタイムゾーン〕。タスク中は同一ファイルを更新し続ける）— 以下の構成:

1. **タスクサマリー**（要求の出所〔Issue 番号・依頼文〕・現在のゲート・モード〔標準/軽量〕。直下にメタ情報欄〔slug の由来・対象リポジトリ・**参照 ACE エントリ**〔記録値は Step 1 項目 3〕〕）
2. **ゲート進行表**（G0〜G4 の各ゲートに: 状態〔未着手 / 通過 / **提案通過**〔更新案の提示のみで適用待ち〕/ 差し戻し〕 / 通過条件チェック結果 / **証拠**〔質問と回答・更新した文書のパス・テスト結果等〕 / 通過日時）
3. **受け入れ基準と検証結果**（基準ごとに 未検証 / PASS / FAIL）
4. **未解決事項リスト**（ID 採番〔SD-1, SD-2, …。**進行表本文の出現順**〕。本文→ID 参照と、リスト側に発生ゲート・関連する受け入れ基準を記載〔双方向〕。ブロッカーには「誰に確認するか」を明記）

※ 進行表は**作業中の中間成果物**で、既定ではコミットしない。リポジトリ内に保存するとき `spec-driven-gates-*.md` が ignore されていなければ `.gitignore` への追加を提案し、監査用の要約は G4 で PR 本文か Issue コメントへ転記する。コミットする方針が明示されていればそれに従う（提案も転記も不要）。

## 参照ファイル（progressive disclosure）

| ファイル | 読むタイミング |
|---|---|
| `references/gate-criteria.md` | ゲート判定時（Step 2 以降常時）。各ゲートの通過条件と運用原則 |
| `references/spec-docs-map.md` | G1 仕様ゲート時。7文書体系・判断マトリクス・影響度評価・frontmatter の書き方 |
| `references/version-convergence.md` | G4 で、`version` を変更した文書か `.version-claims/` の対象を変えた回だけ。共有版の再確定手順 |
| `${FF_DEV_TOOLKIT_ROOT}/docs-template/` | 仕様文書が存在しないとき。コア7文書のテンプレート。体系全体の整備・検証は `/init-docs`・`/validate-docs` |

## 実行手順

### Step 1: タスクの受領とモード判定

1. **入力**（Issue・機能要求・依頼文）を読み、タスクサマリーを書く。作業単位は Issue のラベルと [git-workflow の bundle 節](../../docs-template/05-operations/deployment/git-workflow.md#bundle子を全件-1-pr-で束ねる着手単位)で決める（親が `bundle` の子は bundle から着手し直す）
2. **モード判定**: Git Workflow の tier 判定に従う（**自己申告で宣言しない**。宣言制は申告漏れがそのまま「全部標準」または「全部軽量」へ倒れる）。着手時点は差分が無いので、変更予定の path を渡した暫定判定を使う:

   ```bash
   FF_DEV_TOOLKIT_ROOT="${FF_DEV_TOOLKIT_ROOT}" bash "${FF_DEV_TOOLKIT_ROOT}/scripts/workflow-tier.sh" docs/MASTER.md README.md
   ```

   引数は変更予定の path（上は例）。`WORKFLOW_TIER=light` なら**軽量モード**（G1〜G2 を簡略化。受け入れ基準1個と影響度 LOW の確認は必須）、`standard` / `full` と判定材料が取れなかった `unknown` は標準モード。スクリプトが無ければ標準モード。PR 前の確定判定が暫定判定を拘束することと各 tier の扱いは [DEPLOYMENT の「変更規模による tier」](../../docs-template/05-operations/DEPLOYMENT.md#変更規模による-tier)が正本
3. **着手前の Playbook 参照（ACE Reuse）**: [git-workflow の「着手前の Playbook 参照」](../../docs-template/05-operations/deployment/git-workflow.md#着手前の-playbook-参照ace-reuse)を実行する（手順の正本。ここは起動点）。索引の既定パスは `docs/08-knowledge/PLAYBOOK.md`（`/ace-setup` で配置を変えたプロジェクトは実配置）。結果は「参照 ACE エントリ」欄へ、ヒットした ID / `0 件` / `Playbook なし` / `読み取り失敗（理由）` のいずれかで記録し、空欄のまま次のゲートへ進まない（空欄は「0 件」と「未検索」を区別できない）。Playbook 不在・読み取り失敗ではタスクを止めない
4. **タスク slug**: Issue 番号があれば `issue-{番号}`。なければタスク名から導出する（英語名はそのまま kebab-case、日本語名は読みのヘボン式ローマ字 kebab-case〔長音は省略（しょう→sho・ちゅう→chu・おう→o）、促音は子音重ね〕）
5. ゲート進行表を作成し、項目 3 の結果を反映する（保存先はユーザー指定、無ければカレント作業ディレクトリ。コミットの扱いは「成果物」の注記）

### Step 2: G0 要件ゲート

`references/gate-criteria.md` の「G0 要件: 通過条件」で判定し、チェック結果と証拠を進行表に記録する。曖昧な点は質問にし、対話できない場合（バッチ・自律実行）は SD-n に記録して、**回答なしで安全に進められる範囲だけ**にスコープを絞る。

### Step 3: G1 仕様ゲート

`references/spec-docs-map.md` を読み:

1. 変更が影響する仕様文書を判断マトリクスで特定する。文書がなければ `${FF_DEV_TOOLKIT_ROOT}/docs-template/` の対応テンプレートから最小構成で新設する（**新設は変更が影響する文書のみ**。7文書への底上げは別タスクとして SD-n に提案し、書く材料がない文書を推測で起こさない）
2. **コードより先に仕様文書を更新する**（ドキュメント先、コード後）。**依頼範囲が実装前まで（G2 以前）の場合は、更新案（差分）の提示に留め、適用はユーザー確認後とし、G1 の状態は「提案通過」と記録する**（適用後に「通過」へ更新）
3. 影響度を LOW / MEDIUM / HIGH で評価する。**HIGH の場合は一旦停止**し、関係者確認・ADR・移行計画の要否を判定する（対話できない場合は SD-n に記録して停止し、指示を仰ぐ）
4. frontmatter（version / updated / changeImpact）の更新を差分に含め、証拠（文書パスと差分要約）を進行表に記録する。値の書き方と新設文書の埋め方は spec-docs-map.md の「影響度評価」
5. G1 で置く version は作業 tree 上の暫定値である。この時点の `origin/<default-branch>` SHA を共有版の基準として進行表へ記録し、再確定（G4 項目 1）を先取りして完了扱いしない

### Step 4: G2 計画ゲート

1. 実装を検証可能な単位に分解する（1単位 = 1つの明確な出力 + 完了条件）
2. 分解した単位と受け入れ基準の対応表を作る（カバー漏れの検出）
3. 触ってよい範囲・触らない範囲を明示する
4. 進行表に記録して通過判定する

### Step 5: G3 実装ゲート

1. 単位ごとに「実装 → テスト → 確認」を回す（一括実装しない）
2. **仕様にない挙動が必要になったら G1 に戻る**（仕様を先に更新してから実装。戻った事実を進行表に記録）
3. スコープ外に踏み出しそうになったら止まり、別タスク化を提案する
4. ff-dev-toolkit の公開対象を変える通常 PR で、リポジトリに `changelog.d/README.md` があれば、その schema に従う一意な断片を追加する。共有の `oss/ff-dev-toolkit/CHANGELOG.md` を編集するのは、plugin version を上げるリリース準備と同期手順の footer-only 追従 PR だけ
5. 全単位の完了とテストのパスを確認して通過判定する

### Step 6: G4 検証ゲートと完了

1. **共有版の再確定**: `version` を変更した文書、または `.version-claims/` の対象を変えた回は、`references/version-convergence.md` の手順で最新 default branch から version・Changelog・claim を再確定する（push 済み commit を上書きしない収束規則もそこ）
2. **受け入れ基準を1つずつ実行して判定**し、結果（PASS/FAIL と証拠）を進行表に記録する。FAIL があれば完了と言わずに該当ゲートへ戻る
3. 仕様文書と実装の乖離がないか最終確認する
4. 学び（ハマりどころ・設計判断）があれば1〜3行で進行表に記録する
5. **監査要約を転記する**: 要約（ゲート判定・受け入れ基準の検証結果・スコープ外・SD-n）を PR 本文または Issue コメントへ転記し、転記状態（転記先 URL、または「未転記」）を進行表に記録する。未転記なら次項の報告に転記用の要約を含める。この記録があるまで監査証拠を伴う完了として扱わない（進行表自体をコミットする方針なら転記と記録は不要）
6. 進行表を完成させ、ユーザーに以下を報告する: 全ゲートの通過状況 / 受け入れ基準の判定結果 / 未解決事項（SD-n）/ 監査要約の転記状態（転記先 URL または未転記）

## 注意事項

- **保存前のセルフチェック**: 本スキルの ID リスト（未確定・未合意・未確認・未解決・確認事項）の全 ID が、リスト自身を除く本文に少なくとも1回出現することを確認する（双方向参照の破れ防止）
- 飛ばさない・戻ってよい・通過判定を自己申告にしない・推測で補完しない: `references/gate-criteria.md` の「ゲート運用の原則」と G0
- 進行表の記録が目的化して開発が止まるのは本末転倒。1ゲートの記録は数行でよい
- 本スキルの方法論の出典は references/ 各ファイル末尾の「出典」セクションを参照
