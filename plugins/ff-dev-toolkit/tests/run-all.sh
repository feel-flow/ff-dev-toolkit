#!/usr/bin/env bash
#
# ff-dev-toolkit prompt fixture regression test runner.
#
# 全 suite を必ず実行し、結果を集約して報告する（Issue #146）。最初の失敗で停止する
# fail-fast だと、1 件のゲート違反が無関係な後続 suite の検出力をまとめて 0 にする。
# 実際に PR #144 の changelog-version red が 2 日間、後続 4 suite（破壊的操作を扱う
# merge-cleanup を含む）の実行を止め、その隙間で別の回帰が隠れていた。fail-fast は
# 「red は即座に直される」前提でのみ成立し、放置された瞬間に fail-silent へ反転する。
#
# suite との契約:
#   - 成功なら exit 0、失敗なら非 0 を返す
#   - 環境の都合で**検証本体をまるごと実行できなかった**場合は exit 0 を返しつつ、
#     行頭が `○ skip` の行を出力する（read-only 環境の merge-cleanup など）。ランナーは
#     これを pass ではなく skip として数え、サマリーで名指しする。マーカー文言は
#     tests/run-all/verify.sh が実在を検査するので、変えると red になる。
#     一部の検査だけを飛ばす「部分 skip」でこのマーカーを出さないこと（1 行でも
#     あると suite 全体が skip 扱いになり、実際に走った検査が報告から消える）
#   - 終了コード: 失敗 or 未実行が 1 件でもあれば 1、それ以外は 0。ただし passed が
#     0 で skipped だけの場合も 1（検証が 1 件も成立していない状態を緑にしない）
#
# 引数に suite のパスを渡すと、既定の一覧ではなくその一覧だけを実行する。
# tests/run-all/verify.sh が疑似 suite を渡して本ランナー自身の挙動を検証するための
# 口で、自己テストは常に明示引数で呼ぶため既定の一覧に自身が居ても再帰しない。
# サマリーの suite 識別子は親ディレクトリ名なので、渡す suite は親ディレクトリ名が
# 互いに一意であること（同名だとどちらが失敗したのか報告から読めない）。
#
# FF_RUN_ALL_FAST=1（値が 1 のときだけ有効）を与えると高速モードになり、suite 名
# （親ディレクトリ名）が `-selftest` で終わる suite を実行対象から除外する。selftest の
# 大半はゲート本体（tests/*/verify.sh）の検出力を変異注入で実測するもので、検査対象を
# 変更しない限り原理的に結果が変わらないのに、既定一覧では 18 suite が所要時間の
# 53.9% を占めていた（Issue #600 時点・全 76 suite の実測）。判定は `-selftest` の
# 命名規約のみで除外名簿を持たないため、新規 selftest も自動的に対象になる。既定
# （環境変数なし）は従来どおり全 suite 実行。除外は SKIPPED とは別勘定で、
# REQUIRED_SUITES の必須 skip 判定には掛からない（意図的な除外と環境都合の skip を
# 区別する）。明示引数の実行にも適用されるので、FF_RUN_ALL_FAST=1 を export したまま
# selftest を名指しすると、その suite は実行されない（除外はサマリーに出る）。
#
# トレードオフ（意図的な選択）: 判定が命名規約だけなので、対になる本体 suite を持たず
# live な検査を単独で担う `-selftest` も除外される（Issue #600 時点で 3 件:
# release-required-selftest〔scripts/check-release-required.sh の唯一の検査〕・
# mcp-state-selftest〔dist_state wrapper の byte 一致など〕・
# adapter-env-isolation-selftest〔consumer 名簿の照合など〕）。高速モードで検証されない
# のはゲートの検出力だけではない。selftest の検査対象（tests/*/verify.sh・
# tests/lib/*.sh・scripts/check-release-required.sh）を変更した回を高速モードだけで
# 通すと、退行はフル実行まで検出されない。フル実行の定期実行点は週次 CI（Issue #598。
# 未導入で、導入までは定期実行点が存在しない）に置く規約とし、`tests/` 等の変更時に
# 高速モードを拒否する安全弁は置かない — 条件分岐を増やさず、挙動を単純に保つ。
#
# 実行方式のトレードオフ: 各 suite の出力は skip マーカー判定のため command
# substitution で丸ごと受けてから出力する。そのため suite 実行中のリアルタイム進捗は
# 出ず（merge-cleanup は実 git 操作を伴うので体感差がある）、途中で kill された場合は
# 実行中 suite の出力が残らない。stdout/stderr も 1 本に合流する。skip を pass から
# 区別するために意図して受け入れているトレードオフ。
#
# Keep this read-only friendly: do not create temporary files and avoid here-doc / here-string.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# 入れ子で既定 suite 一覧を走らせると、自己テスト → 本ランナー → 自己テスト … と
# 無限再帰する（merge-cleanup の一時 git リポジトリ生成まで巻き込んで暴走する）。
# 明示引数付きの入れ子だけを許し、引数なしの入れ子は fail-closed で止める。
if [[ "${FF_RUN_ALL_NESTED:-0}" != "0" && $# -eq 0 ]]; then
  echo "✗ run-all.sh を入れ子で引数なし実行しようとしました（既定 suite 一覧は無限再帰します）" >&2
  echo "  入れ子からは検証したい suite のパスを明示引数で渡してください" >&2
  exit 1
fi
export FF_RUN_ALL_NESTED=1

if [[ $# -gt 0 ]]; then
  SCRIPTS=("$@")
  USING_DEFAULT_SCRIPTS=0
else
  USING_DEFAULT_SCRIPTS=1
  SCRIPTS=(
    # 一時ディレクトリも外部コマンドも要らない静的検査を先に置く（安価な順。
    # 全 suite を実行するので、並び順は結果ではなく報告の読みやすさの問題）。
    "$SCRIPT_DIR/skill-frontmatter/verify.sh"
    "$SCRIPT_DIR/skill-bash-blocks/verify.sh"
    # ルート設定で tracked Markdown 全体を lint し、DoD の「markdownlint エラーなし」を
    # 実行可能にする。依存は同梱 MCP の node_modules から借り、直後の selftest が
    # 新規違反を非 0・ファイル名付きで検出することを固定する（Issue #295）。
    "$SCRIPT_DIR/markdownlint/verify.sh"
    "$SCRIPT_DIR/markdownlint-selftest/verify.sh"
    # case 11（*.sh MBCS）の fail-closed 経路をシームで自動回帰（Issue #312）。
    # skill-bash-blocks の直後: 同欠陥クラスの SKILL.md 側ガードと並べて報告する。
    "$SCRIPT_DIR/mbcs-guard-failclosed/verify.sh"
    "$SCRIPT_DIR/no-hardcoded-model/verify.sh"
    "$SCRIPT_DIR/cli-registry-completeness/verify.sh"
    # 収録スキル数の手入力メタデータ（marketplace.json root/oss・plugin.json）と
    # skills/*/SKILL.md の実数の整合検査（Issue #502）。jq のみに依存する読み取り
    # 専用の静的検査。件数の複製を扱う点で cli-registry-completeness の直後に置く。
    "$SCRIPT_DIR/skill-count-consistency/verify.sh"
    # 上の gate の検出力を mktemp fixture への変異（スキル±1・補助物混入・root/oss
    # 片側更新・内訳合計不一致・抽出空振り）で実測する。一時領域不可なら丸ごと ○ skip。
    "$SCRIPT_DIR/skill-count-consistency-selftest/verify.sh"
    # agent-config.yaml が multi-agent.sh の case 文のミラーとして正しいか
    # （command / cost_tier / perspectives / fallback の値を横断照合）。
    # 上の「外部コマンド不要」の例外で、yq に依存する。読み取り専用の静的検査なので
    # 関連する cli-registry-completeness の直後に置く（yq 不在なら丸ごと ○ skip）。
    "$SCRIPT_DIR/agent-config-mirror/verify.sh"
    # 上の gate の検出力を隔離コピーへの mutation で実測する。yq / perl / mktemp -d を
    # 使い単体で〜15 秒かかる（数字を更新するときは実測してから直すこと）。検査対象の
    # 直後に置くことを優先し、安価な順の例外として扱う。
    # yq / perl 不在、または一時領域不可なら丸ごと ○ skip。
    "$SCRIPT_DIR/agent-config-mirror-selftest/verify.sh"
    # 4 スキル（multi-* 3 本 + setup-ai-config）に複製されている agent-config.yaml の
    # 説明文が一致し、実際に読まれるキーを正しく述べ、multi-agent.sh の yq 読み取りと
    # 連動しているかの静的検査。外部コマンド不要だが、同じ設定ファイルを扱う
    # agent-config-mirror 系の直後に置く。
    "$SCRIPT_DIR/agent-config-doc-sync/verify.sh"
    "$SCRIPT_DIR/ace-curate-commit/verify.sh"
    # 行数バジェット例外の運用 SSOT（PLAYBOOK）と live、README の参照、見本
    # ACE-000-3 の 4 条件を静的に照合する（Issue #351）。外部コマンド・一時領域不要。
    "$SCRIPT_DIR/ace-line-budget-docs/verify.sh"
    # docs-template/scripts/ace/*.ts（SSOT）と repository root scripts/ace/*.ts
    # （実行用 mirror）のファイル集合 + byte-identical、および #318 で統合した
    # entryHeadingSource の既知 consumer が共有 import を使うことを静的に固定する。
    # README は配置文脈に応じた正当な差分があるため対象外（Issue #338）。
    "$SCRIPT_DIR/ace-scripts-mirror/verify.sh"
    # 上の gate を隔離コピーへ 1 byte drift / 片側ファイル / ローカル regex 書き戻しで
    # poison し、検出器自身が red になることを実測する。perl / 一時領域が無い場合だけ
    # suite 全体を ○ skip する（実作業ツリーは変更しない）。
    "$SCRIPT_DIR/ace-scripts-mirror-selftest/verify.sh"
    "$SCRIPT_DIR/changelog-public-references/verify.sh"
    "$SCRIPT_DIR/changelog-version/verify.sh"
    "$SCRIPT_DIR/docs-gates/verify.sh"
    "$SCRIPT_DIR/out-of-scope-routing/verify.sh"
    # out-of-scope 判定の実挙動検証（Issue #499）: SKILL.md から抽出した行数閾値と
    # prefix 優先順位を参照実装へ流し、判定表・バッチ表の期待ルートと照合する
    # 静的検査。外部コマンド・一時領域不要。契約文言を見る out-of-scope-routing の
    # 直後に置く。
    "$SCRIPT_DIR/out-of-scope-decision/verify.sh"
    # 上 2 gate の検出力を隔離 fixture への変異注入（旧規則の言い換え・矛盾文の
    # 注入・SKILL 本文/コンシューマーからの契約節の個別削除・閾値/優先順位の改変・
    # 抽出契約行の破壊・参照実装への依存注入、の 12 種）で実測する（Issue #499）。
    # perl / 一時領域が無い場合だけ丸ごと ○ skip（実作業ツリーは変更しない）。
    # 検査対象の直後に置くことを優先し、安価な順の例外として扱う。
    "$SCRIPT_DIR/out-of-scope-routing-selftest/verify.sh"
    # /retrospective の規定（提案閾値・承認境界・read-only 境界・ask モード・trigger 語）
    # と、ワークフローチェーン記載の相互整合の静的検査（Issue #540）。モノレポでは
    # 7 ファイル / 13 針、公開配置では 6 ファイル / 11 針を見る。上限と 1 行報告の文面は
    # SKILL.md から導出して消費側文書へ伝播しているかを照合する。外部コマンド・一時領域
    # 不要。同じ「スキルの契約文言 × 消費側文書」を扱う out-of-scope 系に続けて置く。
    "$SCRIPT_DIR/retrospective-contract/verify.sh"
    # 上の gate の検出力を隔離 fixture への変異注入（チェーン記載の針それぞれからの
    # コマンド削除・規定マーカーと伝播の契約行削除・上限の片側書き換え・抽出不能化・
    # 上限の併存・絞り込み文の追従漏れ・1 行報告の drift・ゲート自身の針数ガードの
    # 縮み）で実測し、赤化した検査の件数まで照合する。ゲートの
    # 検査総数も縛るので、検査そのものが削除される侵食もここで赤くなる。モノレポでは
    # 公開配置を模した第 2 fixture も回す。perl / 一時領域が無い場合だけ丸ごと ○ skip
    # （実作業ツリーは変更しない）。検査対象の直後に置くことを優先し、安価な順の例外。
    "$SCRIPT_DIR/retrospective-contract-selftest/verify.sh"
    # `retrospective-contract` は prompt 文言だけを固定する。実際の plugin Stop hook が
    # 初回に block し、継続中・off・不正入力では fail-open するランタイム契約を fixture
    # で実行する（Issue #583）。直後の selftest は入出力・再入・mode・依存・副作用・
    # SKILL 同期・登録の変異を赤化し、consumer の検査総数も固定する。
    "$SCRIPT_DIR/retrospective-stop-hook/verify.sh"
    "$SCRIPT_DIR/retrospective-stop-hook-selftest/verify.sh"
    # squash 件名の closing keyword が Refs 運用の Issue を閉じる経路のガード。
    # 検査ロジック（scripts/check-closing-keywords.sh）の振る舞いと、SKILL.md /
    # git-workflow.md 側の規約が drift していないことを併せて見る。外部コマンド
    # 不要・一時ディレクトリ不要なので静的検査群に置く。
    "$SCRIPT_DIR/closing-keyword-guard/verify.sh"
    # 起票スキル 2 本（create-issue / out-of-scope-issue）に意図的に複製されている
    # verify-then-skip ラベル契約の照合（bash は連続した行列として、散文は行単位で）と、
    # 両者の意図的な非対称（候補の系統・アサイン方針）の固定。jq / gh / yq 不要の
    # 静的検査（`bash -n` による構文検査だけは走らせるが、契約ブロックは実行しない）。
    # 検査対象の一方 out-of-scope-issue を共有するので、out-of-scope 系・retrospective 系の
    # 契約検査群に続けて置く。
    "$SCRIPT_DIR/issue-label-contract/verify.sh"
    # 推奨ラベル・セットアップの SSOT（docs-template/scripts/setup-github-labels.sh の
    # LABEL_DEFS）と github-setup.md の表・手動例・setup-github-labels SKILL.md
    # 軸別表の 4 箇所照合 + delete 案内との交差 + 名前の正本との位置比較 +
    # stub gh での振る舞い実測（冪等・fail-closed・部分失敗）。実 CLI・ネットワーク・
    # 課金・一時ファイルを伴わない。ラベル契約つながりで issue-label-contract の直後に置く。
    "$SCRIPT_DIR/github-labels-setup/verify.sh"
    # 起票スキルが参照するラベル名 ⊆ (LABEL_DEFS ∪ GitHub デフォルト allowlist) の
    # 包含照合（Issue #624）。issue-label-contract は両スキル間の複製同期、
    # github-labels-setup は供給側 4 箇所の同期を見るのに対し、本 suite は
    # 参照側と供給側をまたぐ包含を見る（verify-then-skip の fail-soft により、
    # 供給されない参照は「起票成功のままラベルだけ黙って落ちる」ため）。
    # gh / jq / yq・一時ファイル不要の静的検査。
    "$SCRIPT_DIR/issue-label-supply/verify.sh"
    # setup-multi-agent.sh の yq 導入が Mike Farah v4 を明示取得し、非互換 yq
    # （distro パッケージ / Python / v3）を利用可能と誤認しないこと（Issue #271）。
    # install の exit 0 を信用せず post-install で flavor/capability を再検証する。
    # 一時ディレクトリと PATH 上の shim を使うが、ネットワーク・実インストールは伴わない。
    "$SCRIPT_DIR/setup-multi-agent-yq/verify.sh"
    "$SCRIPT_DIR/setup-ai-config/verify.sh"
    "$SCRIPT_DIR/assess-impact/verify.sh"
    "$SCRIPT_DIR/validate-docs/verify.sh"
    # /validate-docs §4 のプレースホルダー免除（閉じたフェンス / コメント /
    # インラインコードスパン、閉じ忘れは除外区間にしない）を fixture のトークン
    # 残存数で固定する。LLM を介さない機械照合（Issue #518）。
    "$SCRIPT_DIR/validate-docs-placeholders/verify.sh"
    # 上の gate の検出力を、マスク実装の除外範囲の拡大 / 縮小で実測する。
    # perl 不在または一時領域不可なら丸ごと ○ skip。
    "$SCRIPT_DIR/validate-docs-placeholders-selftest/verify.sh"
    # docs-template 初期セット 20 文書の構造契約（Frontmatter 必須6フィールド +
    # 文末 Changelog + init-docs SKILL ツリーとの集合一致）。/validate-docs の
    # 拡張文書チェックはオプトイン設計なので、テンプレートの Frontmatter 欠落は
    # この gate だけが守る。外部コマンド不要の静的検査（Issue #509）。
    "$SCRIPT_DIR/docs-template-frontmatter/verify.sh"
    # 上の gate の検出力を mktemp fixture への変異（FM 除去・フィールド欠落・
    # 値域外・未閉鎖・ファイル削除・ツリー片側更新・抽出空振り）で実測する。
    # perl 不在または一時領域不可なら丸ごと ○ skip。
    "$SCRIPT_DIR/docs-template-frontmatter-selftest/verify.sh"
    # 対象プロジェクトの docs/ 側 Frontmatter 付与規則の回帰ゲート。MASTER.md の
    # 付与対象 / 付与しない表から両側を導出して集合一致を見る（規則と実体の drift 検出）。
    # docs/ を持たない checkout では丸ごと ○ skip（Issue #513）。
    "$SCRIPT_DIR/docs-frontmatter-repo/verify.sh"
    # 上の gate の検出力を mktemp fixture への変異（FM 除去・値域外・未閉鎖・
    # 実体/規則の片側追加・抽出空振り・除外規則の効き）で実測する（Issue #513）。
    "$SCRIPT_DIR/docs-frontmatter-repo-selftest/verify.sh"
    # docs/ に手書きした件数・閾値と実体のドリフト検査。期待値はすべて実体から導出し、
    # 正準表現に 1 件も一致しなければ赤（抽出の空振りを緑にしない。Issue #519）。
    "$SCRIPT_DIR/docs-fact-drift/verify.sh"
    # 上の gate の検出力を、記載側 / 実体側の双方向の変異と対象外範囲（ACE 分割
    # ファイル・Changelog 節）で実測する（Issue #519）。
    "$SCRIPT_DIR/docs-fact-drift-selftest/verify.sh"
    # docs-template の実行可能フェンスを抽出して fixture 実行する動的検査。
    # 一時作業領域を使うため静的検査の後、ネットワーク検査の前に置く。
    "$SCRIPT_DIR/docs-gates-runtime/verify.sh"
    # アダプタが CLI へ渡す argv の実測。一時ディレクトリと stub CLI を使うが
    # 実 CLI・ネットワーク・課金は伴わない（〜2 秒）。静的検査の後、ネットワーク
    # 検査の前に置く。
    "$SCRIPT_DIR/adapter-model-args/verify.sh"
    # アダプタが渡す sandbox 値が、その CLI が実際に受け付ける値かの契約検査
    # （Issue #403）。同じ argv 実測のクラスなので adapter-model-args の直後。
    # 層 1 は stub CLI のみ。層 2 だけは**実 CLI の `--help`** を読むが、これは
    # clap/yargs のヘルプ生成でローカル完結し、ネットワーク・課金・認証・エージェント
    # 実行のいずれも伴わない（CLI が PATH に無ければその照合だけ ○ skip）。
    # よってネットワーク検査より前のこの位置でよい（〜3 秒）。
    "$SCRIPT_DIR/adapter-sandbox-contract/verify.sh"
    # 同梱レビューラッパー（シム）の契約（Issue #406）: AI CLI を直接起動しない
    # こと（stdin の罠を構造的に持たないこと）と、オプション・env を黙って捨てない
    # こと、setup による配置が冪等であることを固定する。stub オーケストレータのみで
    # 完結し、実 CLI・ネットワーク・課金は伴わない（〜2 秒）。
    "$SCRIPT_DIR/review-wrapper-shim/verify.sh"
    # 主+副レビュワーの解決・保存・縮退。一時ディレクトリと git リポジトリを使うが
    # 実 CLI・ネットワーク・課金は伴わない。設定の保存先は XDG_CONFIG_HOME を
    # 一時ディレクトリへ向けて隔離するので、利用者の実設定には触れない。
    "$SCRIPT_DIR/reviewer-pair/verify.sh"
    # 実行環境分離ライブラリの検出力を、現consumer 9 suiteの名簿照合と隔離copyへの
    # mutation（run_isolated除去 / センチネル部分欠落 / probe内unset / シム素起動）で
    # 常設する（Issue #439）。一時領域のみ使い、実CLI・ネットワーク・課金は伴わない。
    "$SCRIPT_DIR/adapter-env-isolation-selftest/verify.sh"
    # 公開リポジトリへの実ネットワーク到達を試みる suite（接続不可のみ丸ごと
    # ○ skip、それ以外は fail）。静的検査より後、破壊的操作を伴う
    # merge-cleanup より前に置く。他の suite を network-dependent 化する場合も
    # この位置関係（静的 → ネットワーク → 破壊的操作 → 低速）を保つこと。
    "$SCRIPT_DIR/changelog-links/verify.sh"
    # changelog-links の回帰検証（ローカル bare リポジトリ fixture のみ使用、
    # 実ネットワークには触らない）。本体の直後に置く。
    "$SCRIPT_DIR/changelog-links-selftest/verify.sh"
    # 最新版節の path-like マーカーが compare 範囲で実際に追加・変更されたかを
    # 公開タグ tree で限定検査（Issue #332 / ADR-020）。ネットワーク依存は
    # changelog-links と同じ（接続不可のみ skip）。直後に selftest。
    "$SCRIPT_DIR/changelog-attribution/verify.sh"
    # changelog-attribution の回帰検証（ローカル bare fixture のみ、ネット非依存）。
    "$SCRIPT_DIR/changelog-attribution-selftest/verify.sh"
    # 更新通知フック（hooks/check-update.sh）の回帰検証。ローカル bare リポジトリ
    # fixture のみ使用し、実ネットワークには触らない。
    "$SCRIPT_DIR/update-check/verify.sh"
    # スキル実体ドリフト検査（hooks/check-skill-drift.sh、Issue #656）。
    # リポジトリ skills/ とインストール実体の集合差分・ユニーク version 併存・検出不能
    # ・一致時無音（同一 version の cache+marketplace 含む）を fixture で固定し、
    # 差分検出を落とす変異と併存列挙を 1 件に潰す変異の検出力も同じ suite で実測する。
    # 実 ~/.claude には触れない。
    "$SCRIPT_DIR/skill-drift-check/verify.sh"
    # SSOT リポジトリの .claude/settings.json にある hook 起動コマンドのパス解決
    # （Issue #273）。settings.json が無いチェックアウト（公開リポジトリ等）では
    # ○ skip。一時ディレクトリ + stub hook のみ（〜2 秒）。
    "$SCRIPT_DIR/claude-hooks-path/verify.sh"
    # 公開リポジトリの Dependabot 健全性検知（Issue #472）。依存グラフ無効の再発と
    # 実在しない manifest パスに紐づく幽霊 alert を分けて捕捉する。検知スクリプト／
    # hook が無いチェックアウト（公開リポジトリ等）では ○ skip。gh はスタブへ
    # 差し替えるため実ネットワークには触らない。
    "$SCRIPT_DIR/public-dependabot-health/verify.sh"
    # 公開対象の禁止パターン検査（Issue #476）。同期スクリプトの --check-only
    # を使い、パターン配列は同期スクリプト側のまま再利用する。スクリプトや
    # 公開対象ディレクトリが無い checkout（公開リポジトリ等）では ○ skip。
    "$SCRIPT_DIR/sync-forbidden-patterns/verify.sh"
    # sync-dev-toolkit SKILL の「記録 SHA = 同期内容」契約の静的検査（Issue #634）。
    # skip の鍵は sync スクリプトの存在（sync-forbidden-patterns と同じ判定軸）:
    # 公開 checkout（スクリプト不在）は ○ skip、SSOT なのに SKILL 不在は red。
    # read-only・外部コマンド不要（〜1 秒）。sync 系ゲートの並びに置く。
    "$SCRIPT_DIR/sync-sha-contract/verify.sh"
    # 毎 sync リリース運用ゲート scripts/check-release-required.sh の検出力実測
    # （Issue #552）。live 状態は検査しない — 「実変更 + [Unreleased] 非空 + version
    # 据え置き」は開発中の PR では正常で、live 検査を常時ゲートに入れると通常開発が
    # 恒常的に赤くなる。疑似 SSOT + 疑似公開 clone の fixture のみ使い、実 CLI・
    # ネットワーク・課金は伴わない（〜3 秒）。同じ sync 系スクリプトを扱う
    # sync-forbidden-patterns の直後に置く。スクリプト不在の checkout・jq 不在・
    # 一時領域不可なら丸ごと ○ skip。
    "$SCRIPT_DIR/release-required-selftest/verify.sh"
    "$SCRIPT_DIR/merge-cleanup/verify.sh"
    # 既存の孤児トランスクリプト sweep（実 ~/.claude は触らず隔離 tmp のみ）。
    # merge-cleanup の Step 5.5 と同じアーカイブ思想の別口。直後に置く。
    "$SCRIPT_DIR/sweep-orphan-transcripts/verify.sh"
    # perspective フィルタの dry-run 契約。stub CLI の存在確認だけで完結し、
    # 実 CLI・ネットワーク・課金を伴わない。
    "$SCRIPT_DIR/multi-agent-plan/verify.sh"
    # 同一入力の成功済み観点を内容hash付きで再利用し、未完了だけを再実行する
    # --resume 契約（Issue #586）。8観点中7成功・1失敗、HEAD/設定/観点定義/集合変更、
    # 破損キャッシュ、統合レポートのreused/executedを逐次stub CLIで実測する。
    "$SCRIPT_DIR/multi-agent-resume/verify.sh"
    # 統合レポートの CRITICAL_BLOCK 判定の構造検査（Issue #272）と観点別段階化の
    # 契約検査（Issue #645）。一時 git リポジトリ + stub CLI で orchestrator を
    # ケースごとに実走する（1 ケース数秒）。実 CLI・ネットワーク・課金は伴わない。
    "$SCRIPT_DIR/multi-agent-critical-marker/verify.sh"
    # build_prompt の実行境界（再帰防止ガード）の回帰検査（Issue #263）。一時 git
    # リポジトリ + stub CLI（〜3 秒）。実 CLI・ネットワーク・課金は伴わない。
    "$SCRIPT_DIR/adapter-prompt-guard/verify.sh"
    # レビュー指摘の差分スコープ契約（Issue #556）: 全 review perspective のスコープ
    # 言及 + build_prompt(review) の [OUT-OF-DIFF] ラベル契約。一時 git リポジトリのみ
    # （〜2 秒）。実 CLI・ネットワーク・課金は伴わない。一時領域不可なら丸ごと ○ skip。
    "$SCRIPT_DIR/review-diff-scope/verify.sh"
    # free-tier CLI への観点集中の制御（Issue #251）: プラン警告 + free-tier 限定の
    # 同一 CLI 内逐次化 + standard の並列維持 + 途中失敗の継続。一時 git リポジトリ +
    # stub CLI で orchestrator を 4 回実走（単独実測 約 20 秒。詳細は suite README。
    # standard の逐次化変異は期限付きバリアで検出）。実 CLI・ネットワーク・課金は伴わない。
    "$SCRIPT_DIR/multi-agent-serialization/verify.sh"
    # 実行中にレビュー対象（HEAD / ブランチ / 作業ツリー）が動いたときに結果を黙って
    # 返さないこと（公開 Issue #11）。diff の固定と前後のリビジョン検証を、一時 git
    # リポジトリ + stub CLI で実走して確かめる。ミューテーション 5 件つき（詳細は
    # suite README）。実 CLI・ネットワーク・課金は伴わない。
    "$SCRIPT_DIR/multi-agent-revision-guard/verify.sh"
    # 同梱 MCP サーバーの実検査 4 本。node_modules が無い環境ではいずれも ○ skip
    # （型検査の 2 本は node が PATH に無い環境でも ○ skip。tsc の shebang が node を
    # 要求するため、環境都合の失敗を型エラーと混ぜないための分岐）。
    # dist-gate（フレッシュビルド比較 + stdio-only 不変条件、〜1 秒）を先に、
    # vitest（実プロセス起動を含む全テスト、〜5 秒）を後に置く — dist が stale
    # なら先に dist-gate が名指しし、vitest の「stale な dist で green」を防ぐ。
    # dist_state / tree_state の共通 fail-closed 実装を mutation で、2 本の dist_state
    # wrapper の byte 一致を静的比較で常設検証する（Issue #386、〜1 秒）。
    "$SCRIPT_DIR/mcp-state-selftest/verify.sh"
    "$SCRIPT_DIR/mcp-dist-gate/verify.sh"
    # 型検査（Issue #360）。vitest も esbuild build も transpile のみで型を見ないため、
    # 型エラーは下の mcp-vitest では検出できない。vitest より前に置くのは
    # mcp-dist-gate → mcp-vitest と同じ理由 — 型が壊れているファイルのテストが偶然
    # 通った状態を「緑」として報告させないため。install 済みで tsc だけ無い場合は
    # fail-closed（単体で〜1 秒）。
    "$SCRIPT_DIR/mcp-typecheck/verify.sh"
    # 上の gate の検出力を隔離クローンへの mutation で実測する（単体で〜5 秒。tsc の
    # lib 解析が cold の初回はさらに伸びる。数字を更新するときは実測してから直すこと）。
    # node_modules は symlink で借りるだけで、実物への書き込みは行わない。検査対象の
    # 直後に置くことを優先し、安価な順の例外として扱う。
    "$SCRIPT_DIR/mcp-typecheck-selftest/verify.sh"
    "$SCRIPT_DIR/mcp-vitest/verify.sh"
    # docs-template/scripts/ace の型検査（Issue #358）。vitest は esbuild の transpile
    # のみで型を見ないため、型エラーは下の ace-scripts-vitest では検出できない。
    # vitest より前に置くのは mcp-dist-gate → mcp-vitest と同じ理由 — 型が壊れている
    # ファイルのテストが偶然通った状態を「緑」として報告させないため。
    # node_modules 不在なら ○ skip、install 済みで tsc だけ無い場合は fail-closed。
    "$SCRIPT_DIR/ace-scripts-typecheck/verify.sh"
    # 上の gate の検出力を隔離クローンへの mutation で実測する（単体で〜9 秒。tsc の lib
    # 解析が cold の初回はさらに伸びる。数字を更新するときは実測してから直すこと）。
    # node_modules は symlink で借りるだけで、実物への書き込みは行わない。検査対象の
    # 直後に置くことを優先し、安価な順の例外として扱う。
    # skip 条件は上の gate と同じ node_modules 不在に加えて perl 不在・一時領域不可
    # （tsc だけ無い場合はこちらも fail-closed）。
    "$SCRIPT_DIR/ace-scripts-typecheck-selftest/verify.sh"
    # ace-refine 契約のうち、同梱シードの旧形式 0 件は
    # check-entry-format の機械可読 CLI へ委譲する（Issue #336）。
    # mcp/node_modules の esbuild を借りるため、同じ依存を使う typecheck / vitest 群に置く。
    "$SCRIPT_DIR/ace-refine/verify.sh"
    # repository root の live docs/08-knowledge に形式・frontmatter の 2 ゲートを適用する。
    # live docs 不在は適用外として ○ skip、存在するのに依存や入力が欠ける場合は fail-closed。
    # 直後の selftest は隔離 fixture への旧形式 / count drift mutation と不在境界を実測する。
    "$SCRIPT_DIR/live-ace-gates/verify.sh"
    "$SCRIPT_DIR/live-ace-gates-selftest/verify.sh"
    # docs-template/scripts/ace の vitest（Playbook 集計スクリプト群 + refine 候補算出）。
    # vitest 本体は mcp/node_modules を再利用するため mcp 系 suite より後に置く
    # （上の型検査 2 本と ace-refine も同じ node_modules を借りるので、この 4 本が同じ並びに入る）。
    "$SCRIPT_DIR/ace-scripts-vitest/verify.sh"
    # 一時 git リポジトリ + stub CLI を使い、打ち切りや猶予期間の実測待ちを含むので
    # 後ろに置く（単体で〜35 秒。数字を更新するときは実測してから直すこと）
    "$SCRIPT_DIR/multi-agent-timeout/verify.sh"
    "$SCRIPT_DIR/run-all/verify.sh"
  )
fi

# ── 環境都合で消えてはいけない suite の名簿 ──────────────────────────────────
# skip 契約（部分 skip 禁止・行頭 ○ skip・ランナーは pass と別に数える）は正しいが、
# **強制する主体が居ない**。このリポジトリに CI は無く、run-all.sh が非 0 になるのは
# 「pass が 0 件」のときだけなので、yq や node_modules が無いマシンでは該当 suite が
# 丸ごと skip され、それでも全体は緑になる（実測。Issue #274 / #372）。
#
# ここは **fail-closed を既定**にする。「環境都合の skip を許容する」という既存の
# 設計思想とは正面から衝突するが、衝突しているのは *許容するかどうか* ではなく
# *誰が許容を宣言するか*。黙って消えるのをやめ、**環境側が明示的に宣言**する形にする。
#
# 回せない環境では、理由を添えて明示的に外す:
#   FF_RUN_ALL_ALLOW_SKIP="agent-config-mirror agent-config-mirror-selftest" bash tests/run-all.sh
#   FF_RUN_ALL_ALLOW_SKIP=all   # 全部許す（旧来の挙動。1 行の警告つき）
REQUIRED_SUITES=(
  # 実行環境分離のselftestは、クリーン環境だと退行してもconsumerが緑になり得る。
  # 一時領域不足で検出力ごと消える場合は明示許可を要求する（Issue #439）。
  adapter-env-isolation-selftest
  # yq（Mike Farah v4）が要る。ミラー不変条件は他に代替する検査が無い（#274）
  agent-config-mirror
  agent-config-mirror-selftest
  # mcp/node_modules が無いと repository Markdown lint の検証イベントが消える（#295）
  markdownlint
  markdownlint-selftest
  # mcp/node_modules が要る。型検査ゲート 2 系統ぶんがここに乗っている（#372）
  mcp-dist-gate
  mcp-vitest
  mcp-typecheck
  mcp-typecheck-selftest
  ace-scripts-typecheck
  ace-scripts-typecheck-selftest
  ace-refine
  # live docs 不在は正当な適用外なので本体は必須にしない。検出力 selftest は代替がなく、
  # 環境都合で消える場合に明示許可を要求する（Issue #441）。
  live-ace-gates-selftest
  # mktemp fixture が要る。収録スキル数ゲートの検出力 selftest は代替がなく、
  # 一時領域不足で消えると count-rot の検出力喪失が黙って通る（Issue #502）。
  skill-count-consistency-selftest
  ace-scripts-vitest
  # ミラー検出器・tree-state helper・runner 自身の検出力にも代替がない。
  ace-scripts-mirror-selftest
  mcp-state-selftest
  run-all
  # 一時領域が無いと、以下が単独で守る実行時契約が丸ごと消える。単体 suite は
  # 環境都合を ○ skip として区別するが、run-all では明示許可なしの skip を通さない
  # （Issue #436 / #440）。「TMPDIR 書込不可でも全体を緑」は目標にしない。
  setup-multi-agent-yq
  docs-gates-runtime
  adapter-model-args
  adapter-sandbox-contract
  review-wrapper-shim
  sweep-orphan-transcripts
  multi-agent-timeout
  # 実行中のリビジョン変化を検出する契約は、この suite 以外どこも守っていない。
  multi-agent-revision-guard
  # out-of-scope 契約ゲート（routing / decision）の検出力 selftest。代替の検査が
  # 無く、perl・一時領域の都合で消える場合は明示許可を要求する（#499）。
  out-of-scope-routing-selftest
  # /retrospective 契約ゲートの検出力 selftest。代替の検査が無く、perl・一時領域の
  # 都合で消えるとチェーン記載の針と規定マーカーの検出力喪失が黙って通る（#540）。
  retrospective-contract-selftest
  # 自動振り返りのランタイム検出力は mutation self-test 以外に代替がない（#583）。
  retrospective-stop-hook-selftest
  # スキル実体ドリフト検査は、この suite 以外に代替がない。一時領域不足で消えると
  # 未登録スキル / 古い cache 併存の検出が黙って通る（Issue #656）。
  skill-drift-check
  # docs-template 構造契約ゲートの検出力 selftest。代替の検査が無く、perl・
  # 一時領域の都合で消えると Frontmatter 欠落回帰の検出力喪失が黙って通る（#509）。
  docs-template-frontmatter-selftest
  # /validate-docs §4 プレースホルダー免除ゲートの検出力 selftest。代替の検査が
  # 無く、perl・一時領域の都合で消えるとフェンス / コメント境界の退行が黙って通る
  # （#518）。
  validate-docs-placeholders-selftest
  # 自リポジトリ docs/ の Frontmatter 規則ゲートと件数ドリフトゲートの検出力 selftest。
  # 代替の検査が無く、perl・jq・一時領域の都合で消えると「規則と実体の drift を
  # 検出できない状態」が黙って通る（#513 / #519）。
  #
  # **公開 checkout では root に docs/ が無いため両方 ○ skip する。** fixture は
  # 「実リポジトリの docs/ をそのまま写す」設計で、baseline が実体と乖離しないことを
  # 優先している（同梱 fixture にすると baseline 自体が腐る）。したがって公開側では
  # sync-forbidden-patterns / release-required-selftest と合わせて 4 件の明示許可が要る:
  #   FF_RUN_ALL_ALLOW_SKIP="sync-forbidden-patterns release-required-selftest docs-frontmatter-repo-selftest docs-fact-drift-selftest" \
  #     bash tests/run-all.sh
  # 必須 skip で落ちたときは、この行と同じ内容をランナーが実際の skip 一覧から
  # 組み立てて表示する（下の REQUIRED_SKIPPED の案内）。
  docs-frontmatter-repo-selftest
  docs-fact-drift-selftest
  # 公開対象の禁止パターン検査。同期時以外に発火するゲートが他に無い（#476）。
  # 公開 checkout はスクリプト不在で ○ skip、一時領域不足でも ○ skip する。
  # そちらでは FF_RUN_ALL_ALLOW_SKIP=sync-forbidden-patterns が要る。
  sync-forbidden-patterns
  # 毎 sync リリース運用ゲートの検出力 selftest（#552）。代替の検査が無く、
  # 消えると「リリース漏れ・CHANGELOG 記載漏れを sync 前に止める」検出力の喪失が
  # 黙って通る。公開 checkout は root スクリプト不在で ○ skip するため、そちらでは
  # FF_RUN_ALL_ALLOW_SKIP=release-required-selftest が要る（上の 4 件の列挙参照）。
  release-required-selftest
)

# ── 既定 suite 一覧の登録漏れ検査 ──────────────────────────────────────────────
# SCRIPTS 配列は手で維持されており、**一覧から 1 行消しても誰も気づかない**。
# 消した suite は走らず、残り全部が緑のまま「All ... passed」を出す。
# 自己テスト（tests/run-all/verify.sh）は擬似 suite を明示引数で渡してランナーの集計を
# 検査する作りなので、既定の配列を一度も読まない — つまり登録の正しさは規律だけで
# 保たれていた。ここで実体（tests/<name>/verify.sh）と突き合わせる。
#
# 走査は tests/ の直下 1 階層だけ。run-all 自身の fixture は tests/run-all/fixtures/
# の下にあり、この深さには現れないので誤検出しない。
check_suite_registration() {
  local disk_names=() registered=() missing=() name script
  for script in "$SCRIPT_DIR"/*/verify.sh; do
    [[ -f "$script" ]] || continue
    disk_names+=("$(basename "$(dirname "$script")")")
  done
  # 既定一覧そのものを読む（別配列に写すと写し忘れで乖離する）。この関数は
  # 既定一覧で走るときにしか呼ばれないので SCRIPTS が既定一覧に等しい。
  for script in "${SCRIPTS[@]}"; do
    registered+=("$(basename "$(dirname "$script")")")
  done
  # 走査が空なら「漏れなし」ではなく「検査が成立していない」
  if [[ "${#disk_names[@]}" -eq 0 ]]; then
    echo "✗ tests/ 直下に verify.sh が 1 件も見つかりません（登録検査が成立していません）" >&2
    return 1
  fi
  local d r found
  for d in "${disk_names[@]}"; do
    found=0
    for r in "${registered[@]}"; do
      [[ "$d" == "$r" ]] && { found=1; break; }
    done
    [[ "$found" -eq 1 ]] || missing+=("$d")
  done
  if [[ "${#missing[@]}" -gt 0 ]]; then
    echo "✗ run-all.sh の既定 suite 一覧に未登録の suite があります:" >&2
    printf '    %s\n' "${missing[@]}" >&2
    echo "  tests/<name>/verify.sh を追加したら SCRIPTS 配列にも 1 行足してください。" >&2
    return 1
  fi
  # 名簿に実在しない suite 名が残ると、その行は永久に何も守らない（改名・削除に
  # 追従できていない状態）。登録検査のついでに実在を確かめる。
  local req unknown=()
  for req in "${REQUIRED_SUITES[@]}"; do
    found=0
    for d in "${disk_names[@]}"; do
      [[ "$req" == "$d" ]] && { found=1; break; }
    done
    [[ "$found" -eq 1 ]] || unknown+=("$req")
  done
  if [[ "${#unknown[@]}" -gt 0 ]]; then
    echo "✗ REQUIRED_SUITES に実在しない suite 名があります:" >&2
    printf '    %s\n' "${unknown[@]}" >&2
    echo "  改名・削除に追従できていません（その行は何も守っていません）。" >&2
    return 1
  fi
  echo "ℹ️  既定 suite 一覧の登録漏れなし（実体 ${#disk_names[@]} 件 / 必須 ${#REQUIRED_SUITES[@]} 件）"
  return 0
}

# --check-registration: 登録照合だけを行って終わる。全 suite を走らせずに
# この検査だけを回せるようにしておく（自己テストから安価に叩くため）。
if [[ "${FF_RUN_ALL_CHECK_REGISTRATION:-0}" == "1" ]]; then
  if [[ "$USING_DEFAULT_SCRIPTS" != "1" ]]; then
    echo "✗ FF_RUN_ALL_CHECK_REGISTRATION は既定一覧に対してのみ意味を持ちます（引数なしで実行してください）" >&2
    exit 2
  fi
  check_suite_registration
  exit $?
fi

# 既定一覧で走らせるときだけ照合する（明示引数の実行は部分実行が正当な用途）。
if [[ "$USING_DEFAULT_SCRIPTS" == "1" ]]; then
  check_suite_registration || exit 1
fi

# ── 高速モード（FF_RUN_ALL_FAST=1）────────────────────────────────────────────
# `-selftest` サフィックスの suite を実行対象から除外する（背景・トレードオフは
# ヘッダー参照）。登録漏れ検査（check_suite_registration）は既定一覧そのものへ
# 掛ける必要があるため、この除外は照合の**後**に行う。除外した suite は SKIPPED に
# 一切現れないので、REQUIRED_SUITES の必須 skip 判定（SKIPPED だけを走査する）とは
# 構造的に競合しない。
FAST_MODE=0
FAST_EXCLUDED=()
if [[ "${FF_RUN_ALL_FAST:-0}" == "1" ]]; then
  FAST_MODE=1
  FAST_KEPT=()
  for script in "${SCRIPTS[@]}"; do
    name="$(basename "$(dirname "$script")")"
    if [[ "$name" == *-selftest ]]; then
      FAST_EXCLUDED+=("$name")
    else
      FAST_KEPT+=("$script")
    fi
  done
  # 除外で実行対象が 0 件になったら成功として扱わない（検査 0 件を緑にしない）
  if [[ ${#FAST_KEPT[@]} -eq 0 ]]; then
    echo "✗ 高速モードの除外で実行対象が 0 件になりました（selftest ${#FAST_EXCLUDED[@]} 件を除外）。検査 0 件を成功として記録しません" >&2
    exit 1
  fi
  SCRIPTS=("${FAST_KEPT[@]}")
  if [[ ${#FAST_EXCLUDED[@]} -gt 0 ]]; then
    echo "⚡ 高速モード: selftest ${#FAST_EXCLUDED[@]} 件を実行対象から除外します（内訳はサマリー）"
    echo
  fi
fi

PASSED=()
FAILED=()
SKIPPED=()
NOT_RUN=()

for script in "${SCRIPTS[@]}"; do
  name="$(basename "$(dirname "$script")")"
  echo "== $name =="

  # 起動できない suite は「未実行」として記録し、ループは継続する（ここで exit すると
  # 裏口から fail-fast が戻る）。最後に非 0 終了へ寄与させることで fail-closed を保つ。
  if [[ ! -f "$script" ]]; then
    echo "✗ verify script is missing: $script" >&2
    NOT_RUN+=("$name (missing)")
    echo
    continue
  fi
  if [[ ! -x "$script" ]]; then
    echo "✗ verify script is not executable: $script" >&2
    NOT_RUN+=("$name (not executable)")
    echo
    continue
  fi

  # 出力を変数へ受けるのは skip マーカーを判定するため。command substitution は
  # パイプで完結し一時ファイルを作らないので read-only 環境でも動く。判定後に
  # そのまま全量を出力するので、診断情報は失敗時も成功時も欠けない。
  if output="$(bash "$script" 2>&1)"; then
    printf '%s\n' "$output"
    # 判定はシェル内の文字列マッチで行い、パイプを使わない。`printf | grep -q` だと
    # grep がマッチ時点で終了して上流の printf が SIGPIPE (141) で死に、pipefail の
    # もとでパイプライン全体が失敗扱いになる = マッチが「不一致」へ反転する。出力が
    # パイプ容量（64KB 程度）を超える suite で skip が pass に化ける fail-silent で、
    # 本 Issue が潰そうとしている masking と同じ種類の事故になる。
    # 左辺に改行を前置するのは、1 行目の `○ skip` も行頭マッチさせるため。
    if [[ $'\n'"$output" == *$'\n○ skip'* ]]; then
      SKIPPED+=("$name")
    else
      PASSED+=("$name")
    fi
  else
    printf '%s\n' "$output"
    FAILED+=("$name")
  fi
  echo
done

# ---- サマリー --------------------------------------------------------------
# 「実行した suite 数」と「失敗/スキップ/未実行の suite 名」を必ず出す。総数と
# 実行数が食い違ったまま success を名乗らないことが、本 Issue の masking 対策の本体。
RUN=$(( ${#PASSED[@]} + ${#FAILED[@]} + ${#SKIPPED[@]} ))

echo "== summary =="
echo "suites: total=${#SCRIPTS[@]} run=$RUN passed=${#PASSED[@]} failed=${#FAILED[@]} skipped=${#SKIPPED[@]} not-run=${#NOT_RUN[@]}"

# 高速モードの除外は「何を検証していないか」ごとサマリーへ明示する。除外は total にも
# skipped にも数えない — 環境都合の skip（検証したかったが出来なかった）と、意図的な
# 除外（検証しないと決めた）を混ぜると、必須 skip 判定の意味が壊れるため。
if [[ "$FAST_MODE" == "1" ]]; then
  if [[ ${#FAST_EXCLUDED[@]} -gt 0 ]]; then
    echo "⚡ 高速モードで selftest ${#FAST_EXCLUDED[@]} 件を除外した（これらが担う検査〔ゲート検出力・一部の live 検査〕は未実施。フル検証は FF_RUN_ALL_FAST なしで実行）: ${FAST_EXCLUDED[*]}"
  else
    echo "⚡ 高速モード: 除外対象の selftest は 0 件だった（除外は行っていない）"
  fi
fi

if [[ ${#SKIPPED[@]} -gt 0 ]]; then
  echo "○ skipped (環境都合で検証本体が未実行): ${SKIPPED[*]}"
fi

# 必須名簿の suite が skip したら失敗として扱う（既定）。環境都合で回せない場合は
# FF_RUN_ALL_ALLOW_SKIP で**明示的に宣言**する。黙って消えることを無くすのが目的で、
# 許容そのものを禁じているわけではない。
REQUIRED_SKIPPED=()
if [[ "$USING_DEFAULT_SCRIPTS" == "1" && ${#SKIPPED[@]} -gt 0 ]]; then
  _allow="${FF_RUN_ALL_ALLOW_SKIP:-}"
  if [[ "$_allow" == "all" ]]; then
    echo "⚠️  FF_RUN_ALL_ALLOW_SKIP=all — 必須 suite の skip を許容しています（検証されていない不変条件があります）" >&2
  else
    # カンマ区切りも受ける
    _allow="${_allow//,/ }"
    for _s in "${SKIPPED[@]}"; do
      for _r in "${REQUIRED_SUITES[@]}"; do
        [[ "$_s" == "$_r" ]] || continue
        _declared=0
        for _a in $_allow; do [[ "$_a" == "$_s" ]] && { _declared=1; break; }; done
        [[ "$_declared" -eq 1 ]] || REQUIRED_SKIPPED+=("$_s")
      done
    done
  fi
fi
if [[ ${#REQUIRED_SKIPPED[@]} -gt 0 ]]; then
  echo "✗ 環境都合で消してはいけない suite が skip しました: ${REQUIRED_SKIPPED[*]}" >&2
  echo "  これらが守る不変条件には代替の検査がありません（必要な実行環境は各 suite のコメントを参照）。" >&2
  echo "  回せない環境なら、理由を承知のうえで明示的に外してください:" >&2
  # 高速モード中の案内には FF_RUN_ALL_FAST=1 を前置する。落とした形をコピペすると、
  # 利用者が気づかないままフル実行へ戻るため。
  if [[ "$FAST_MODE" == "1" ]]; then
    echo "    FF_RUN_ALL_FAST=1 FF_RUN_ALL_ALLOW_SKIP=\"${REQUIRED_SKIPPED[*]}\" bash tests/run-all.sh" >&2
  else
    echo "    FF_RUN_ALL_ALLOW_SKIP=\"${REQUIRED_SKIPPED[*]}\" bash tests/run-all.sh" >&2
  fi
fi
if [[ ${#NOT_RUN[@]} -gt 0 ]]; then
  echo "✗ not run (suite を起動できなかった): ${NOT_RUN[*]}" >&2
fi
if [[ ${#FAILED[@]} -gt 0 ]]; then
  echo "✗ failed: ${FAILED[*]}" >&2
fi

if [[ ${#FAILED[@]} -gt 0 || ${#NOT_RUN[@]} -gt 0 || ${#REQUIRED_SKIPPED[@]} -gt 0 ]]; then
  exit 1
fi

if [[ ${#SKIPPED[@]} -gt 0 ]]; then
  # skip だけで pass が 0 = 検証が 1 件も成立していない。文言だけ出して 0 で終わると、
  # 終了コードしか見ない CI では「全部通った」と区別が付かないので非 0 で落とす。
  if [[ ${#PASSED[@]} -eq 0 ]]; then
    echo "✗ 検証できた suite がありません（全 ${#SKIPPED[@]} suite が環境都合でスキップ）。書き込み可能な環境で再実行してください" >&2
    exit 1
  fi
  # 高速モードでは「書き込み可能な環境で回す」だけではフル検証にならない
  # （FF_RUN_ALL_FAST も外す必要がある）ので、最終行の案内を分ける。
  if [[ "$FAST_MODE" == "1" ]]; then
    echo "実行した ${#PASSED[@]} suite は全て通過（${#SKIPPED[@]} suite は環境都合でスキップ、selftest ${#FAST_EXCLUDED[@]} 件は高速モードで未実行。フル検証は FF_RUN_ALL_FAST なしを書き込み可能な環境で行うこと）"
  else
    echo "実行した ${#PASSED[@]} suite は全て通過（${#SKIPPED[@]} suite は環境都合でスキップ。全 suite の検証は書き込み可能な環境で行うこと）"
  fi
  exit 0
fi

# 高速モードでは selftest が未実行なので、全体 pass（All ... passed）を名乗らない。
if [[ "$FAST_MODE" == "1" ]]; then
  echo "実行した ${#PASSED[@]} suite は全て通過（高速モード: selftest ${#FAST_EXCLUDED[@]} 件は未実行。フル検証は既定モードで行うこと）"
  exit 0
fi

echo "All ff-dev-toolkit fixture checks passed."
exit 0
