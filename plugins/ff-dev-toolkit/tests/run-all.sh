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
    # squash 件名の closing keyword が Refs 運用の Issue を閉じる経路のガード。
    # 検査ロジック（scripts/check-closing-keywords.sh）の振る舞いと、SKILL.md /
    # git-workflow.md 側の規約が drift していないことを併せて見る。外部コマンド
    # 不要・一時ディレクトリ不要なので静的検査群に置く。
    "$SCRIPT_DIR/closing-keyword-guard/verify.sh"
    # 起票スキル 2 本（create-issue / out-of-scope-issue）に意図的に複製されている
    # verify-then-skip ラベル契約の照合（bash は連続した行列として、散文は行単位で）と、
    # 両者の意図的な非対称（候補の系統・アサイン方針）の固定。jq / gh / yq 不要の
    # 静的検査（`bash -n` による構文検査だけは走らせるが、契約ブロックは実行しない）。
    # 検査対象の一方 out-of-scope-issue を共有する out-of-scope-routing の直後に置く。
    "$SCRIPT_DIR/issue-label-contract/verify.sh"
    # 推奨ラベル・セットアップの SSOT（docs-template/scripts/setup-github-labels.sh の
    # LABEL_DEFS）と github-setup.md の表・手動例の 3 箇所照合 + stub gh での振る舞い
    # 実測（冪等・fail-closed）。実 CLI・ネットワーク・課金・一時ファイルを伴わない。
    # ラベル契約つながりで issue-label-contract の直後に置く。
    "$SCRIPT_DIR/github-labels-setup/verify.sh"
    # setup-multi-agent.sh の yq 導入が Mike Farah v4 を明示取得し、非互換 yq
    # （distro パッケージ / Python / v3）を利用可能と誤認しないこと（Issue #271）。
    # install の exit 0 を信用せず post-install で flavor/capability を再検証する。
    # 一時ディレクトリと PATH 上の shim を使うが、ネットワーク・実インストールは伴わない。
    "$SCRIPT_DIR/setup-multi-agent-yq/verify.sh"
    "$SCRIPT_DIR/setup-ai-config/verify.sh"
    "$SCRIPT_DIR/assess-impact/verify.sh"
    "$SCRIPT_DIR/validate-docs/verify.sh"
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
    # SSOT リポジトリの .claude/settings.json にある hook 起動コマンドのパス解決
    # （Issue #273）。settings.json が無いチェックアウト（公開リポジトリ等）では
    # ○ skip。一時ディレクトリ + stub hook のみ（〜2 秒）。
    "$SCRIPT_DIR/claude-hooks-path/verify.sh"
    "$SCRIPT_DIR/merge-cleanup/verify.sh"
    # 既存の孤児トランスクリプト sweep（実 ~/.claude は触らず隔離 tmp のみ）。
    # merge-cleanup の Step 5.5 と同じアーカイブ思想の別口。直後に置く。
    "$SCRIPT_DIR/sweep-orphan-transcripts/verify.sh"
    # perspective フィルタの dry-run 契約。stub CLI の存在確認だけで完結し、
    # 実 CLI・ネットワーク・課金を伴わない。
    "$SCRIPT_DIR/multi-agent-plan/verify.sh"
    # 統合レポートの CRITICAL_BLOCK 判定の構造検査（Issue #272）。一時 git リポジトリ +
    # stub CLI で orchestrator を 9 回実走する（〜15 秒）。実 CLI・ネットワーク・課金は
    # 伴わない。
    "$SCRIPT_DIR/multi-agent-critical-marker/verify.sh"
    # build_prompt の実行境界（再帰防止ガード）の回帰検査（Issue #263）。一時 git
    # リポジトリ + stub CLI（〜3 秒）。実 CLI・ネットワーク・課金は伴わない。
    "$SCRIPT_DIR/adapter-prompt-guard/verify.sh"
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
  echo "    FF_RUN_ALL_ALLOW_SKIP=\"${REQUIRED_SKIPPED[*]}\" bash tests/run-all.sh" >&2
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
  echo "実行した ${#PASSED[@]} suite は全て通過（${#SKIPPED[@]} suite は環境都合でスキップ。全 suite の検証は書き込み可能な環境で行うこと）"
  exit 0
fi

echo "All ff-dev-toolkit fixture checks passed."
exit 0
