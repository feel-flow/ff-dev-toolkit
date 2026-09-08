---
name: spec-driven
description: 開発タスクを仕様駆動の5ゲート（要件→仕様→計画→実装→検証）で進行管理するスキル。機能要求や Issue を受けたとき、受け入れ基準の確定と仕様文書の先行更新をゲートとして強制し、進行表に証拠付きで記録する。「仕様駆動で進めて」「spec-driven」「ゲート管理して」「要件から順に固めて」「受け入れ基準を決めてから実装して」と言われたとき、または曖昧な機能要求のまま実装に入りそうなときに使用。
---

# 仕様駆動ゲート管理（spec-driven）

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

1. **タスクサマリー**（要求の出所〔Issue 番号・依頼文〕・現在のゲート・モード〔標準/軽量〕。直下にメタ情報欄〔slug の由来・対象リポジトリ・**参照 ACE エントリ**〕）
   - **参照 ACE エントリ**: Step 1 の Playbook 索引検索の結果を書く欄。ヒットしたエントリ ID を並べる。ヒットが無ければ `0 件`、Playbook が存在しないリポジトリなら `Playbook なし`、存在するのに読めない場合は `読み取り失敗（理由）` と書く（欄を空のままにしない — 空欄は「検索した結果 0 件」と「検索していない」を区別できない）
2. **ゲート進行表**（G0〜G4 の各ゲートに: 状態〔未着手 / 通過 / **提案通過**〔更新案の提示のみで適用待ち〕/ 差し戻し〕 / 通過条件チェック結果 / **証拠**〔質問と回答・更新した文書のパス・テスト結果等〕 / 通過日時）
3. **受け入れ基準と検証結果**（基準ごとに 未検証 / PASS / FAIL）
4. **未解決事項リスト**（ID 採番〔SD-1, SD-2, …。**進行表本文の出現順**〕。本文→ID 参照と、リスト側に発生ゲート・関連する受け入れ基準を記載〔双方向〕。ブロッカーには「誰に確認するか」を明記）

※ 進行表は監査可能性のための記録であり、これ自体が目的ではない。記録は簡潔に、判断の証拠を残すことを優先する。

※ 進行表は**作業中の中間成果物**として扱い、既定ではリポジトリへコミットしない。監査に必要な要約（ゲート判定・受け入れ基準の検証結果・スコープ外）は PR 本文や Issue コメントへ転記して残す。リポジトリ側にコミットして保存する方針が明示されている場合はそちらに従う。

## 参照ファイル（progressive disclosure）

| ファイル | 読むタイミング |
|---|---|
| `references/gate-criteria.md` | ゲート判定時（Step 2 以降常時）。各ゲートの通過条件チェックリストと運用原則 |
| `references/spec-docs-map.md` | G1 仕様ゲート時。7文書体系・判断マトリクス・影響度評価 |
| `${FF_DEV_TOOLKIT_ROOT}/docs-template/` | 仕様文書が存在しないとき。コア7文書のテンプレート（MASTER.md はルート直下、他は `01-context/PROJECT.md`・`02-design/ARCHITECTURE.md`・`02-design/DOMAIN.md`・`03-implementation/PATTERNS.md`・`04-quality/TESTING.md`・`05-operations/DEPLOYMENT.md`）。frontmatter はテンプレート本体に組み込み済み。ドキュメント体系のフル整備・検証は `/init-docs`・`/validate-docs` コマンドを使う（ゲート判定には gate-criteria.md を使う） |

## 実行手順

### Step 1: タスクの受領とモード判定

1. **入力**（Issue・機能要求・依頼文）を読み、タスクサマリーを書く
2. **モード判定**: Git Workflow の tier 判定に従う（**自己申告で宣言しない**。宣言制は申告漏れがそのまま「全部標準」または「全部軽量」へ倒れる）。着手時点はまだ差分が無いので、予定している変更対象の path を渡した**暫定判定**を使う:

   ```bash
   bash "${FF_DEV_TOOLKIT_ROOT}/scripts/workflow-tier.sh" docs/MASTER.md README.md
   ```

   引数は「これから変更する予定の path」を並べる（上は例）。出力の `WORKFLOW_TIER=light` なら**軽量モード**（G1〜G2 を簡略化。ただし受け入れ基準1個と影響度 LOW の確認は必須）、`standard` / `full` と、判定材料が取れなかった `unknown` は標準モード。**判定パターンの実効値は `workflow-tier.sh --list-rules` が持ち、各 tier で何をするかの正本は `docs-template/05-operations/DEPLOYMENT.md` §主要ステップ が持つ**（文書は判定パターンを書き写さないので、上書きされた環境でも嘘にならない）。スクリプトが無い環境では標準モードで進める。

   暫定判定は path の挙げ漏れで軽い側へ倒れるため、**PR を出す前に引数なしで実行した確定判定が拘束する**。確定が `light` でなければ、そこから標準モードの手当てを補う（暫定を追認しない）
3. **着手前の Playbook 参照（ACE Reuse）**: 変更対象領域のキーワード（機能名・ファイル名・エラー文言・ドメイン語）で `docs/08-knowledge/PLAYBOOK.md` の索引（エントリ一覧）を検索し、ヒットしたエントリを読む。Issue 本文に「関連 ACE エントリ」が添付されている場合はそれを起点にする。**検索結果は必ずタスクサマリーの「参照 ACE エントリ」欄へ記録する**（進行表ファイルは項目 5 で作成するため、それまで結果を下書きとして保持し、作成時に反映する）: ヒットしたエントリ ID、ヒットが無ければ `0 件`、Playbook が存在しないリポジトリなら `Playbook なし`、存在するのに読めない場合は `読み取り失敗（理由）`。いずれも「検索を実施した」記録であり、欄が空のまま次のゲートへ進まない（未記録は Step 1 未完了として扱う）。Playbook の既定パスは `docs/08-knowledge/PLAYBOOK.md` だが、`/ace-setup` で配置先を変えているプロジェクトではその実配置を解決し、見つからないときだけ `Playbook なし` とする。**Playbook 不在・読み取り失敗は標準手順を止める理由にしない**（該当を記録して続行する。探索の失敗でタスクを止めない）。役立ったエントリの ACE ID は G3 実装時にコミット本文と `implementation-notes.md` へ書き、`/ace-curate` の Helpful カウンターへ届ける。手順と記録先ごとの届き方の正本は `docs-template/05-operations/deployment/git-workflow.md` の「着手前の Playbook 参照（ACE Reuse）」で、本 Step はその起動点をゲートに載せるだけであり、別手順を定義しない
4. **タスク slug**: Issue 番号があれば `issue-{番号}`。なければタスク名から導出する（英語名はそのまま kebab-case、日本語名は読みのヘボン式ローマ字 kebab-case〔長音は省略（しょう→sho・ちゅう→chu・おう→o）、促音は子音重ね〕）
5. ゲート進行表を作成する（保存先: ユーザー指定。指定がなければカレント作業ディレクトリ）。進行表は中間成果物のためコミットしない。Git リポジトリ内に保存する場合、`spec-driven-gates-*.md` が ignore されていなければ `.gitignore` へのパターン追加を提案する（リポジトリ側にコミットする方針が明示されている場合を除く）

### Step 2: G0 要件ゲート

`references/gate-criteria.md` の G0 チェックリストに従う:

1. 要求を Why / What の1〜2文に言語化する
2. **受け入れ基準を 3〜5 個**、観測可能な形で書く
3. スコープ外を明記する
4. 曖昧な点は**実装案でなく質問**にする。対話できる場合はユーザーに確認し、できない場合（バッチ・自律実行）は質問を SD-n に記録し、**回答がなくても安全に進められる範囲だけ**を対象にスコープを絞る（勝手な補完で埋めない）
5. チェック結果と証拠を進行表に記録して G0 を通過判定する

### Step 3: G1 仕様ゲート

`references/spec-docs-map.md` を読み:

1. 変更が影響する仕様文書を判断マトリクスで特定する。文書がなければ `${FF_DEV_TOOLKIT_ROOT}/docs-template/` の対応テンプレートから最小構成で新設する（**新設するのは変更が影響する文書のみ**。7文書・最小3文書への底上げは別タスクとして SD-n に提案する。書く材料がない文書を推測で起こさない）
2. **コードより先に仕様文書を更新する**（ドキュメント先、コード後）。**依頼範囲が実装前まで（G2 以前）の場合は、更新案（差分）の提示に留め、適用はユーザー確認後とし、G1 の状態は「提案通過」と記録する**（適用後に「通過」へ更新）
3. 影響度を LOW / MEDIUM / HIGH で評価する。**HIGH の場合は一旦停止**し、関係者確認・ADR・移行計画の要否を判定する（対話できない場合は SD-n に記録して停止し、指示を仰ぐ）
4. frontmatter（version / updated / changeImpact〔値は小文字: low|medium|high〕）の更新を差分に含め、進行表に証拠（更新した文書のパスと差分要約）を記録する。テンプレートから新設する場合、**frontmatter はテンプレート本体に組み込み済みのため、プレースホルダー（owner / created 等）を実際の値で埋める**（`changeImpact` キーが無いテンプレート由来文書には追記し、テンプレート初期値が大文字の場合は小文字へ正規化する）
5. G1 で置く version は作業 tree 上の暫定値である。共有版を置く commit の基準として、この時点の `origin/<default-branch>` SHA を進行表へ記録する。再確定の実行手順は G4 が正本であり、ここでは先取りして完了扱いしない

### Step 4: G2 計画ゲート

1. 実装を検証可能な単位に分解する（1単位 = 1つの明確な出力 + 完了条件）
2. 分解した単位と受け入れ基準の対応表を作る（カバー漏れの検出）
3. 触ってよい範囲・触らない範囲を明示する
4. 進行表に記録して通過判定する

### Step 5: G3 実装ゲート

1. 単位ごとに「実装 → テスト → 確認」を回す（一括実装しない）
2. **仕様にない挙動が必要になったら G1 に戻る**（仕様を先に更新してから実装。戻った事実を進行表に記録）
3. スコープ外に踏み出しそうになったら止まり、別タスク化を提案する
4. リポジトリに `changelog.d/README.md` があり、ff-dev-toolkit の公開対象を変える通常 PR なら、同 README の schema に従う一意な断片を追加し、共有の `oss/ff-dev-toolkit/CHANGELOG.md` は編集しない。共有本文を編集するのは plugin version を同時に上げるリリース準備、または同期手順が規定する比較リンク footer-only 追従 PR だけとする
5. 全単位の完了とテストのパスを確認して通過判定する

### Step 6: G4 検証ゲートと完了

1. **共有版を最新 default branch から再確定する**:
   1. G1/G3 の変更と断片を provisional commit にまとめる（まだ push しない）。`git status --porcelain --untracked-files=all` が空になるまで無関係な変更を混ぜず、以後の version / claim 更新はこの commit へ `git commit --amend --no-edit` する
   2. `default_ref="$(git symbolic-ref --quiet --short refs/remotes/origin/HEAD)"` を解決し、`origin/*` 形式であることを確認して `default_branch="${default_ref#origin/}"` を得る。`git rev-parse --verify --quiet "refs/remotes/origin/${default_branch}"` も通らなければ停止する
   3. `git fetch origin "+refs/heads/${default_branch}:refs/remotes/origin/${default_branch}"` で明示 refspec を fetch する。dirty tree・fetch 失敗・ref 解決不能は stale 値へ fallback せず停止する
   4. `git merge-base --is-ancestor "origin/${default_branch}" HEAD` が偽なら、先行 tree を rebase / merge で取り込み、remote の版ブロックを保全した現在版から version と Changelog を再生成する
   5. `.version-claims/` が存在するリポジトリでは、version を変更した文書、およびリポジトリ固有ルールで version 不変時にも claim を要求する PLAYBOOK / PATTERNS ごとに、同梱 `${FF_DEV_TOOLKIT_ROOT}/scripts/update-version-claim.sh --base "origin/${default_branch}" --document <path>` を実行し、元の階層を保持した `.version-claims/<文書 path>.claim` を `document=<path>` / `version=<version>` / `change=<hash>` の3行だけで更新する。`.version-claims/` が無い利用先ではこの手順だけを省略する。helper は base blob ID（新規時は `ABSENT`）と current blob ID から Git 設定非依存の hash を生成し、symlink 親階層や検査不能を拒否する。文書・Changelog・claim と検証修正を stage し、`${FF_DEV_TOOLKIT_ROOT}/scripts/check-version-claims.sh --root "$(git rev-parse --show-toplevel)"` で index/tree の双方向対応を検査してから provisional commit を amend し、同じ commit に含める
   6. 同じ文書の先行 PR が祖先検査後に merge された場合、claim の content conflict を片寄せ・削除で解消せず、最新 base から version / Changelog / claim を再生成する。feature branch 自身への push は default branch の CAS ではなく、merge-ready 前の祖先検査と文書別 claim を PR 経路の境界とする
   7. amend 後の commit に対して受け入れ基準を再実行し、**初回 push 前**と merge-ready 直前にも手順2〜4を繰り返す。初回 push 前に remote が動いたら rebase と再生成へ戻る。既に feature branch を push 済みなら公開済み commit を amend / rebase せず、最新 default branch を merge して現在版から再生成した reconciliation commit を追加し、claim と G4 を再実行して通常 push する。再生成と G4 は最大3回とし、収束しなければ直列化を求めて停止する。`--force` / `--force-with-lease` で上書きしない
2. **受け入れ基準を1つずつ実行して判定**し、結果（PASS/FAIL と証拠）を進行表に記録する。FAIL があれば完了と言わずに該当ゲートへ戻る
3. 仕様文書と実装の乖離がないか最終確認する
4. 学び（ハマりどころ・設計判断）があれば1〜3行で進行表に記録する
5. **監査要約を転記する**: 進行表はコミットしないため、要約（ゲート判定・受け入れ基準の検証結果・スコープ外・未解決事項〔SD-n〕）を PR 本文または Issue コメントへ転記する。転記の成否にかかわらず、転記状態を進行表に記録する: 転記済みの場合は転記先（URL 等）、転記先がまだ無い・書き込めない場合は「未転記」と記録し、後者は次項の報告に転記用の要約を含める（転記済みか未転記の進行表への記録があるまで、監査証拠を伴う完了として扱わない。リポジトリ方針で進行表自体をコミットする場合は転記不要）
6. 進行表を完成させ、ユーザーに以下を報告する: 全ゲートの通過状況 / 受け入れ基準の判定結果 / 未解決事項（SD-n）/ 監査要約の転記状態（転記先 URL または未転記）

## 注意事項

- **保存前のセルフチェック**: 本スキルの ID リスト（未確定・未合意・未確認・未解決・確認事項）の全 ID が、リスト自身を除く本文に少なくとも1回出現することを確認する（双方向参照の破れ防止）
- **ゲートを飛ばさない**。ただし前提が崩れたら前のゲートに戻るのは正常（戻りを失敗として隠さない）
- **通過判定を自己申告にしない**。証拠（質問と回答・文書パス・テスト結果）のないチェックは未通過として扱う
- 曖昧な要求を推測で補完しない。質問するか、安全な範囲にスコープを絞って SD-n に残す
- 進行表の記録が目的化して開発が止まるのは本末転倒。1ゲートの記録は数行でよい
- 本スキルの方法論の出典は references/ 各ファイル末尾の「出典」セクションを参照
