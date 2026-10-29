#!/usr/bin/env bash
# multi-agent.sh の構成ファイル: 実行状態の既定値・タスク結果の記録・使い方の表示・引数解析・設定の読み込み・タスク種別の既定の適用。
#
# scripts/multi-agent.sh が開始時に 1 回だけ source する（直接実行しない）。読み込む順・
# 読めないときの停止・--resume の入力 identity への算入は multi-agent.sh の
# MULTI_AGENT_PARTS が正本。本文は分割前の multi-agent.sh の連続した行そのままで、
# トップレベルの初期化は構成ファイル同士で分割前と同じ順に走る（入口に残したタスク種別の既定より
# 後に走る点だけが違う）。ここへ set / trap / source を足さない。
# 末尾の _ma_part_loaded の行は読み込み完了の印（途中で切れたファイルを読み込み部が
# 見分ける）。bash 3.2 互換。分割の判断は ADR-075。
# 例外: --resume の入力 identity の変更（compute_resume_identity・RESUME_IDENTITY_VERSION）は分割の
# 後に足した変更で、分割前の行ではない（ADR-075 決定 5）。
# pipefail-inherited: multi-agent.sh が set -euo pipefail の下で source する

# ── Defaults ──
# （旧 registry 境界。現在はどのテストも参照しない。機械的な意味を持つ見出しは
# 入口 multi-agent.sh の「All known CLI names」/「CLI Registry End」の 2 つだけ）
TASK_TYPE="review"
DESCRIPTION=""
INCLUDE_DIFF=false
CONFIG_FILE="${MULTI_AGENT_CONFIG:-}"
CONFIG_SOURCE="MULTI_AGENT_CONFIG env"
CONFIG_PROVENANCE="env"
if [[ -z "$CONFIG_FILE" ]]; then
  if [[ -f "${REPO_ROOT}/.claude/agent-config.yaml" ]]; then
    CONFIG_FILE="${REPO_ROOT}/.claude/agent-config.yaml"
    CONFIG_SOURCE="project override"
    CONFIG_PROVENANCE="project"
  else
    CONFIG_FILE="${SCRIPT_DIR}/agent-config.yaml"
    CONFIG_SOURCE="plugin default"
    CONFIG_PROVENANCE="plugin"
  fi
fi
MODE=""            # 未指定なら apply_task_defaults がタスク種別ごとに決める
REVIEW_MAIN=""
REVIEW_SUB=""
REVIEWERS_SOURCE=""
# cross_review（auto | off）とその出所（env / project config / user config / unset）。
# 読み取り・表示専用で、プラン構築には使わない（単一固定のオプトイン）。
CROSS_REVIEW=""
CROSS_REVIEW_SOURCE=""
MODE_EXPLICIT=false
# MODE の出所（--mode flag / config のキー / task default）。whitelist 拒否は config
# 由来でも発火するため、値だけ名指しすると利用者がどこを直せばよいか辿れない
# （STRATEGY_SOURCE と同じ理由 — Issue `#691` / `#699`）。
# 有効なのは validate_mode / apply_task_defaults までで、その後 MODE は --cli 経路や
# レビュワー不在の fallback で distributed へ書き換わりうる（MODE_SOURCE は追随しない）。
# 後段でこの値を表示する読み手を足すなら、そこで出所を取り直すこと。
MODE_SOURCE="task default"
PRINT_REVIEWERS=false
SET_REVIEWERS=""
STRATEGY=""
# STRATEGY の出所（--strategy flag / config のキー / task default）。pair モードの
# 非適用通知と whitelist 拒否は config 由来でも発火するため、値だけ名指しすると
# 利用者がどこを直せばよいか辿れない（Issue `#691`）。
STRATEGY_SOURCE=""
PARALLEL=true
OUTPUT_DIR=""
# Whether --output-dir was given, so the retry advice can carry it (the value
# itself is always set later by apply_task_defaults, so it cannot be inferred).
OUTPUT_DIR_EXPLICIT=false
# Config source of an output_dir read from a config file ("" when not from config);
# only the plugin default may trigger the legacy-root set-aside (Issue `#2514`).
OUTPUT_DIR_SOURCE=""
REVIEW_EVIDENCE=false
REVIEW_EVIDENCE_PRIOR=""
REVIEW_EVIDENCE_PARENT=""
REVIEW_EVIDENCE_START=""
# --evidence の producer（review-evidence.py）を開始時に読んだバイト列と、その sha256。
# pin_review_evidence_producer が埋め、begin / finish はどちらもこのバイト列を実行する。
REVIEW_EVIDENCE_PRODUCER_PATH=""
REVIEW_EVIDENCE_PRODUCER=""
REVIEW_EVIDENCE_PRODUCER_SHA256=""
# critical_nonblock_perspectives を開始時に 1 回だけ解決した値（resolve_critical_nonblock_at_start）。
# 空集合（env の空文字 = 全観点ブロック）と未解決を区別するため、解決済みの印を別に持つ。
REVIEW_CRITICAL_NONBLOCK_SET=""
REVIEW_CRITICAL_NONBLOCK_RESOLVED=false
# この実行の diff を固定したファイル。create_fixed_diff が埋め、run_single_task が
# 全アダプタへ --diff-file として配る。diff を持たないタスク（description だけの
# explore など）では空のまま = 従来どおりアダプタ側の判断に委ねる。
FIXED_DIFF_FILE=""
# 実行開始時点のリビジョンスナップショット（capture_repo_snapshot の 1 行）。
# 実行後に取り直した値と突き合わせる。git リポジトリ外では空のまま。
REPO_SNAPSHOT_BEFORE=""
# ── ツリー変化判定のパス除外（Issue `#747`） ──
#
# 常駐ツール（superpowers スキルが作る .superpowers/ 等）が実行中に書き続ける
# リポジトリでは、リビジョンガードの作業ツリー判定が毎回発火し、全タスク成功後に
# 結果が丸ごと破棄される。FF_MULTI_AGENT_IGNORE_PATHS（':' 区切り、pathspec の
# glob magic として解釈）に一致するパスを判定から外す。除外が効くのは
# **作業ツリーの指紋だけ**で、HEAD / ブランチの変化検出には影響しない
# （capture_repo_snapshot の除外は worktree の問い合わせにしか掛からない）。
# レビューは何も削除しないため、merge-cleanup と違い適用範囲を絞る必要は無い。
#
# .superpowers/** は**既定で除外**する。FF_MULTI_AGENT_IGNORE_PATHS は既定への
# **追加**であって置き換えではない — 置き換えにすると、別のパスを 1 つ設定した
# 瞬間に .superpowers 起因の全破棄が黙って再発する。
# 検証・パターン分解は parse_ignore_paths（main の冒頭で必ず呼ぶ）。
IGNORE_PATHS_DEFAULT='.superpowers/**'
IGNORE_EXCLUDE_PATHSPECS=(":(exclude,glob,top)${IGNORE_PATHS_DEFAULT}")
# 利用者指定パターンの肯定形（報告用）。既定パターンは含めない — 既定と利用者指定は
# ログで別々に名乗る（どちらの指定が効いたのかを実行ログから区別できるように）。
IGNORE_MATCH_PATHSPECS=()
# 検出そのものは adapters/adapter-common.sh の関数へ委譲する（書き写しの人手同期を
# やめるため）。ここに残すのは orchestrator 固有の方針だけ:
#   1) MULTI_AGENT_BASE_BRANCH env を最優先する
#   2) 「自動検出」と「origin/HEAD が無いのでフォールバック」を利用者へ名乗り分ける
# 2 を保つために default_base_branch_name（空を返しうる）と resolve_base_branch_ref を
# 別々に呼ぶ。畳んだ detect_base_branch では、どちらが起きたのか戻り値から分からない。
BASE_BRANCH="${MULTI_AGENT_BASE_BRANCH:-}"
BASE_BRANCH_SOURCE="MULTI_AGENT_BASE_BRANCH env"
BASE_BRANCH_EXPLICIT=false
if [[ -n "$BASE_BRANCH" ]]; then
  BASE_BRANCH_EXPLICIT=true
fi
STAGED_DIFF=false
if [[ -z "$BASE_BRANCH" ]]; then
  BASE_BRANCH="$(default_base_branch_name)"
  BASE_BRANCH_SOURCE="auto-detected from origin/HEAD"
fi
if [[ -z "$BASE_BRANCH" ]]; then
  BASE_BRANCH="develop"
  BASE_BRANCH_SOURCE="fallback — origin/HEAD not set"
fi
# 鮮度解決（ローカル / remote-tracking のどちらが古くないか）は**ここではやらない**。
# parse_args の最後の finalize_base_branch で、最終的な base に対して 1 回だけ行う。
# ここで解決すると、--base を渡した実行でも「使われない既定 base」の選択行が 1 行出て、
# 最終 base の選択行と合わせて 2 行になる（別の base を指定したときは無関係な名前の行）。
#
# 呼び出し側が指定した base の**名前**（origin/ を落とした形）。レビュー系列 ID と
# --resume の identity はこちらを使う。解決結果（BASE_BRANCH）を使うと、ローカルの
# 鮮度が変わっただけで develop ↔ origin/develop が入れ替わり、同じレビュー文脈が
# 別系列と判定される（stale のまま 1 回目 → git pull 後の 2 回目が「another
# branch/base/scope」となり、強制的にフルレビューへ落ちる）。
BASE_BRANCH_IDENTITY="${BASE_BRANCH#origin/}"
DRY_RUN=false
RESUME=false
FRESH=false
ARCHIVE_ONLY=false
ARCHIVE_PREVIOUS_BRANCH=""
ARCHIVE_KEEP_LOCK=false
ARCHIVE_DESTINATION=""
# ホスト委譲。true のとき claude-code レーンは CLI を起動せず、実行を
# ホストへ返す。既定は false = 従来どおり spawn。
DELEGATE_TO_HOST=false
TIMEOUT=""

# Space-separated filter lists (bash 3.2 compatible)
CLI_FILTER=""
PERSPECTIVE_FILTER=""
# 除外は包含フィルタへ畳み込まない。PERSPECTIVE_FILTER を埋めると、--cli と併用したとき
# 「明示ペアリング」経路（所有レジストリを迂回する）を意図せず踏む。独立に保つ。
EXCLUDE_PERSPECTIVES=""
# CLI の除外は 2 経路（--exclude-cli と config の exclude_clis）を**別々に**保つ。
# 和集合だけを持つと、プランの 1 行に出す出所（引数由来 / 設定由来）が復元できない —
# 「設定に書いた覚えのない CLI が消えている」を追えることが本機能の目的そのもの。
EXCLUDE_CLIS_FLAG=""
EXCLUDE_CLIS_CONFIG=""
EXCLUDE_CLIS_CONFIG_SOURCE=""
LIST_PERSPECTIVES=false

# Detected available CLIs (space-separated)
AVAILABLE_CLIS=""
# 導入済みなのに除外で AVAILABLE_CLIS から落ちた CLI（detect_available_clis が記録）。
# 未導入 CLI の除外は何も落としていないので入らない（単一 CLI ゲートはこれを見る）。
EXCLUDED_INSTALLED_CLIS=""

# Execution plan: CLI_NAME:PERSPECTIVE pairs (newline-separated)
EXECUTION_PLAN=""

# pair モードで「副を立てられたのに --perspective の指定で落ちた」かどうか。
# 単一 CLI 縮退警告の gate が読む。build_pair_plan を通らないモード（distributed /
# cross-model）では、現状の gate の式が短絡するためこの変数は展開されない。それでも
# 必ず初期化するのは、gate が壊れない根拠を**式の書き方**に依存させないため — 条件の
# 順序を入れ替えた瞬間に set -u で未定義参照になり、しかも壊れるのは pair 以外という
# 遠い場所になる。
PAIR_SUB_DROPPED=false
# pair の実効レビュワー構成（統合レポートの Reviewers 行。Issue `#699`）。空のままなら
# 行を出さない = pair 以外のモードでは何も足さない。build_pair_plan だけが埋める。
PAIR_REVIEWERS_NOTE=""

# Tasks that failed this run, as "cli/perspective:exit_code" (space-separated).
# Drives the retry advice printed after execution — a bare count leaves the user to
# work out which CLI to re-run and with what, which is exactly the moment they
# reach for a runtime fallback that does not exist. The exit code rides along
# because the right advice depends on it: more time helps a timeout and is useless
# for expired credentials. cli/perspective are validated single path segments and
# cannot contain ':', so the suffix is unambiguous.
FAILED_TASKS=""

# 先行タスクと同じ理由で確実に失敗すると分かっているタスク（Issue `#1143`）。
# 形式は "cli/perspective:cause" の空白区切りで、cause は auth | billing。
# FAILED_TASKS とは別に持つ — これらは「失敗した」のではなく「実行していない」ので、
# 失敗の助言（時間を足す / 原因を読む）をそのまま当てると存在しない実行を指す。
# 到達範囲は execute_tasks と同じプロセス（並列ワーカーはステータス dir 経由で
# 親へ渡す）なので、generate_report と print_failure_advice から読める。
SKIPPED_TASKS=""

# ホストへ委譲したまま結果を受け取っていないタスク。"cli/perspective" の
# 空白区切り。FAILED_TASKS とも SKIPPED_TASKS とも別に持つ —
#   - 失敗ではない: CLI は 1 つも起動しておらず、調べるべきクラッシュが存在しない
#   - スキップでもない: 実行を捨てたのではなく、別の実行主体へ渡して待っている
# 混ぜると、レポートと助言がどちらも実在しない事象（クラッシュ / 打ち切り）を指す。
DELEGATED_TASKS=""

delegated_task_pending() { # <cli/perspective> → rc0 = 委譲済みで結果待ち
  list_contains "$DELEGATED_TASKS" "$1"
}

# スキップしてよい失敗理由。classify_cli_failure_cause の分類の
# うち auth / billing / model-unsupportedだけを採る。
#   - auth / billing … 資格情報・残高は CLI 単位の状態で、同じ実行内の同一 CLI の
#                      他タスクも確実に同じ理由で落ちる
#   - model-unsupported … モデル指定は CLI 単位（MULTI_AGENT_MODEL_<CLI> / CLI 自身の
#                      設定）で、同じ実行内の同一 CLI の他タスクも同じモデルで落ちる
#   - argv           … 採らない。E2BIG は**そのタスクの argv 長**で決まるため、
#                      観点が違えば起動できる余地がある
#   - prompt-too-long … 採らない。超過量は観点ごとのプロンプト長で決まり、
#                      短い観点なら通る余地がある。全滅した回は下の集約案内が
#                      「diff を見よ」と 1 度だけ言うので、実行を先回りで
#                      止めなくても遠回りは塞がる
#   - ""（判定不能） … 採らない。fail-open で従来どおり全タスクを実行する
# 推測でスキップすると、実際には走ったはずのレビューが観点ごと消える — 誤ってスキップ
# する損失（カバレッジ 0）は、誤って実行する損失（setup 1 回分の待ち時間）より大きい。
cli_failure_is_deterministic() { # <cause> → rc0 = 残りのタスクをスキップしてよい
  case "$1" in
    auth|billing|model-unsupported) return 0 ;;
    *) return 1 ;;
  esac
}

# auth / billing で落ちた CLI とその理由（"cli:cause" の空白区切り。Issue `#1143`）。
# 逐次ブランチ専用 — 並列ブランチのワーカーはサブシェルなのでこの変数を共有できず、
# 判断はワーカー内で閉じる（親へはステータス dir の .skip 印で渡す）。
POISONED_CLIS=""

# <cli> が auth / billing で落ちていれば理由を返す（落ちていなければ空文字）。
skipped_cli_cause() { # <cli> → cause | ""
  local cli="$1" entry
  for entry in $POISONED_CLIS; do
    if [[ "${entry%:*}" == "$cli" ]]; then
      printf '%s\n' "${entry##*:}"
      return 0
    fi
  done
  return 0
}

# <cli/perspective> がスキップされていれば理由を返す（未スキップなら空文字）。
skipped_task_cause() { # <cli/perspective> → cause | ""
  local task="$1" entry
  for entry in $SKIPPED_TASKS; do
    if [[ "${entry%:*}" == "$task" ]]; then
      printf '%s\n' "${entry##*:}"
      return 0
    fi
  done
  return 0
}

# 主担当以外の CLI が「利用不可」（auth / billing / model-unsupported）で落ちた観点。
# "cli/perspective:cause" の空白区切り。FAILED_TASKS / SKIPPED_TASKS
# からは**外さない** — 「この実行がその観点の判定を出していない」ことは変わらず、
# 前回の未解消 Critical の保持（task_left_perspective_unproven）はそのまま効かせる。
# ここに載せるのは次の 3 つを変えるためだけ:
#   - 実行全体の終了コード（主担当のみの完了は失敗ではない — ADR-053 決定 1）
#   - 統合レポートの節（INCOMPLETE ではなく「主担当のみで完了（<cli>: <理由>）」の 1 行。
#     基準線は主担当 1 モデル — ADR-053 決定 1。未実施・縮退として記録させない）
#   - CRITICAL_BLOCK 判定（成果物の本文を判定しない — サルベージした stderr は判定材料ではない）
UNAVAILABLE_CROSS_TASKS=""

# <cli/perspective> が利用不可として許容された観点なら理由を返す（そうでなければ空文字）。
unavailable_cross_task_cause() { # <cli/perspective> → cause | ""
  local task="$1" entry
  for entry in $UNAVAILABLE_CROSS_TASKS; do
    if [[ "${entry%:*}" == "$task" ]]; then
      printf '%s\n' "${entry##*:}"
      return 0
    fi
  done
  return 0
}

# 利用不可の観点を集める。許容は次をすべて満たす回だけ:
#   - review の pair モードで主担当（REVIEW_MAIN）が決まっている — 主担当という概念が
#     あるのはこの経路だけ。単一 CLI の起動（無人の厳格なレビューフック・--route fast）は
#     従来どおり非 0 で返す（そちらの主担当はホスト自身で、完走をこの層は観測できない）
#   - 主担当の全観点がこの実行で判定を出した（失敗・スキップ・委譲待ちが 1 つも無い）
#     — 主担当そのものが利用不可・途中失敗なら、主担当のみの完了とは言えない。--resume で
#     再利用した観点は判定済みとして数える（完全プランで見る）
#   - その観点の CLI は主担当ではない
#   - 失敗した観点は、CLI が何も出力せずに終了した回に限る（アダプタによる結果の拒否・
#     部分出力の保全・時間切れの 124 は除く）。部分出力がある観点を許容すると、その中の
#     Critical を誰も読まなくなる
#   - 利用不可の分類は stderr の**末尾の行**だけで行う（classify_cli_failure_cause の tail）
# 途中失敗（分類不能・argv・prompt-too-long・時間切れ・拒否）は載せない — 従来どおり未確認。
collect_unavailable_cross_tasks() {
  UNAVAILABLE_CROSS_TASKS=""
  [[ "$TASK_TYPE" == "review" && "$MODE" == "pair" && -n "$REVIEW_MAIN" ]] || return 0
  local plan="${FULL_EXECUTION_PLAN:-$EXECUTION_PLAN}" entry cli persp task rc cause result main_seen=false
  while IFS= read -r entry; do
    [[ -n "$entry" ]] || continue
    [[ "${entry%%:*}" == "$REVIEW_MAIN" ]] || continue
    main_seen=true
    task_left_perspective_unproven "$REVIEW_MAIN" "${entry#*:}" && return 0
  done <<< "$plan"
  [[ "$main_seen" == "true" ]] || return 0
  for entry in $FAILED_TASKS; do
    task="${entry%:*}"; rc="${entry##*:}"; cli="${task%%/*}"; persp="${task#*/}"
    [[ "$cli" != "$REVIEW_MAIN" && "$rc" != "124" && "$rc" != "0" ]] || continue
    result="${OUTPUT_DIR}/${cli}/${persp}.md"
    [[ -f "$result" ]] || continue
    # アダプタの拒否（理由コード行あり）と、部分出力を保全した成果物は許容しない
    grep -q '^> Reason code: ' "$result" 2>/dev/null && continue
    grep -qxF 'No output was captured before the CLI was stopped.' "$result" 2>/dev/null || continue
    cause="$(classify_cli_failure_cause "$result" tail)"
    cli_failure_is_deterministic "$cause" || continue
    UNAVAILABLE_CROSS_TASKS="${UNAVAILABLE_CROSS_TASKS:+$UNAVAILABLE_CROSS_TASKS }${task}:${cause}"
  done
  # スキップは同じ CLI の先行タスクが上の条件で利用不可と判定された回だけ許容する
  # （スキップ自体は節全体の分類で起きるので、先行タスクの許容を根拠にする）
  for entry in $SKIPPED_TASKS; do
    task="${entry%:*}"; cause="${entry##*:}"; cli="${task%%/*}"
    [[ "$cli" != "$REVIEW_MAIN" ]] || continue
    cli_failure_is_deterministic "$cause" || continue
    [[ " ${UNAVAILABLE_CROSS_TASKS} " == *" ${cli}/"* ]] || continue
    UNAVAILABLE_CROSS_TASKS="${UNAVAILABLE_CROSS_TASKS:+$UNAVAILABLE_CROSS_TASKS }${task}:${cause}"
  done
  return 0
}

# 失敗・スキップの**すべて**が許容済みか（件数ではなく集合で比べる）。
all_failures_unavailable_cross() {
  [[ -n "${FAILED_TASKS}${SKIPPED_TASKS}" && -n "$UNAVAILABLE_CROSS_TASKS" ]] || return 1
  local entry
  for entry in $FAILED_TASKS $SKIPPED_TASKS; do
    [[ -n "$(unavailable_cross_task_cause "${entry%:*}")" ]] || return 1
  done
  return 0
}

# 利用不可の理由の日本語名（レポート用）。
unavailable_cause_label_ja() { # <cause>
  case "$1" in
    auth) echo "認証切れ" ;;
    billing) echo "クレジット・利用枠の上限" ;;
    model-unsupported) echo "モデル非対応" ;;
    *) echo "$1" ;;
  esac
}

# Previous unresolved review state captured before result cleanup (Issue `#843`).
# It is deliberately small: perspective names and their existing block/nonblock
# classification only. A failed rerun keeps that classification; a successful
# rerun is judged from the new result as usual.
PREVIOUS_UNRESOLVED_BLOCK=""
PREVIOUS_UNRESOLVED_NONBLOCK=""
PRESERVE_PREVIOUS_CRITICAL_REPORT=false

# Resume state. EXECUTION_PLAN starts as the complete expected plan. Immediately
# before dispatch, prepare_resume_execution_plan saves that plan here and replaces
# EXECUTION_PLAN with only the tasks that still need execution. main restores the
# complete plan before revision verification and report generation.
FULL_EXECUTION_PLAN=""

# 今回の実行では動かさないが、出力ディレクトリに残っている結果ファイルの名指し
# （Issue `#537` / `#654`）。quarantine_unplanned_outputs が実行ごとに詰め直し、
# append_plan_sections が統合レポートへも載せる（stderr だけだと、レポート経由で
# 結果を読む消費者に届かない）。
UNPLANNED_RESULT_NOTES=""
REUSED_TASKS=""
EXECUTED_TASKS=""
# 2: 構成ファイル（MULTI_AGENT_PARTS）を orchestrator と並べて identity へ算入した（ADR-075）
# 3: adapter-common.sh の構成ファイル（ADAPTER_COMMON_PARTS）も同じ形で算入した（ADR-075）
RESUME_IDENTITY_VERSION=4
RESUME_IDENTITY=""
RESUME_CACHE_DIR=""
RESUME_CACHE_PENDING=""
RESUME_INPUT_MANIFEST=""
RESUME_FIXED_DIFF_HASH=""
CACHE_MISS_REASON=""
INVOCATION_DISPLAY=""
WRAPPER_ROUTE="direct"
DELEGATION_GENERATION=""
DELEGATION_STATE_DIR=""
DELEGATION_PREVIOUS_HEAD=""
DELEGATION_PREVIOUS_IDENTITY=""
DELEGATION_PREVIOUS_GENERATION=""
DELEGATION_PREVIOUS_INVOCATION=""
DELEGATION_PREVIOUS_MANIFEST=""
DELEGATION_UNADOPTED_NOTES=""
DELEGATION_STATE_NEW=false

# 同じ output-dir を使う別 orchestrator との排他。成果物は run-id で分離せず、利用者が
# 従来どおり固定パスから読める契約を保つ代わりに、1 output-dir = 1 active run とする。
OUTPUT_LOCK_DIR=""
OUTPUT_LOCK_HELD=false

# 走行中であることを外部（PreToolUse hook）へ知らせる在庫ファイル。上の
# OUTPUT_LOCK_DIR とは目的が違う — あちらは orchestrator 同士の排他、こちらは
# 「今このツリーを触ると結果が壊れる」を hook が読むための宣言。
REVIEW_IN_FLIGHT_FILE=""

# ── Utility ──

list_contains() {
  local list="$1" item="$2"
  for i in $list; do
    [[ "$i" == "$item" ]] && return 0
  done
  return 1
}

# ── Usage ──
show_help() {
  sed -n '/^# Usage:/,/^# See:/{/^# See:/d; s/^# \{0,1\}//; p;}' "$0"
  exit 0
}

# ── Argument Parsing ──
# 最終的な base（env / 自動検出 / フォールバック / --base のいずれか）へ鮮度解決を
# **1 回だけ**掛ける。呼び出しは parse_args の末尾 1 箇所だけに保つこと — 解決を
# 複数箇所に置くと選択行が重複し、しかも「実際には使わなかった base」の行が混ざる。
#
# BASE_BRANCH_IDENTITY は解決**前**の名前（origin/ 前置は落とす）。レビュー系列 ID と
# --resume の identity 用で、`--base develop` と `--base origin/develop` と
# 「stale なので origin へ倒した develop」を同じ文脈として扱うためにある。
finalize_base_branch() {
  BASE_BRANCH_IDENTITY="${BASE_BRANCH#origin/}"
  BASE_BRANCH="$(resolve_base_branch_ref "$BASE_BRANCH")"
}

print_archive_recovery() { # [critical]: do not advertise a bare operation for known Critical state.
  local state="${1:-unknown}" cmd="bash $(shell_quote "${SCRIPT_DIR}/multi-review.sh") --route $(shell_quote "${WRAPPER_ROUTE/direct/none}")"
  cmd="${cmd} --output-dir $(shell_quote "${OUTPUT_DIR:-$(get_default_output_dir review)}")"
  if config_is_explicit; then cmd="${cmd} --config $(shell_quote "$CONFIG_FILE")"; fi
  if [[ "$state" != critical ]]; then
    echo "       Cold/clear output: drop --fresh and retry the original review invocation." >&2
    echo "       Cold/clear output only — archive once without running reviewers:" >&2
    echo "         ${cmd} --base $(shell_quote "$BASE_BRANCH") --archive-only" >&2
  fi
  echo "       Critical recovery template — replace both placeholders with confirmed values before execution:" >&2
  echo "         ${cmd} --base '<confirmed-previous-base>' --archive-only='<confirmed-previous-branch>'" >&2
  echo "       Confirm the previous branch name and its original base identity; do not infer them from the series token." >&2
  echo "       Same-branch Critical, pending requests, corrupt/legacy state stop without moving results." >&2
  echo "       Then re-run with --delegate-to-host=${DELEGATION_LANE} and no --fresh (fast: omit delegation); collect with the same argv plus --resume." >&2
}

parse_args() {
  local archive_conflict="" option
  for option in "$@"; do
    case "$option" in
      --description|--include-diff|--mode|--mode=*|--strategy|--cli|--cli=*|--perspective|--perspective=*|--exclude-cli|--exclude-cli=*|--exclude-perspective|--exclude-perspective=*|--parallel|--sequential|--timeout|--set-reviewers)
        archive_conflict="$option" ;;
    esac
  done
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --invocation-display) INVOCATION_DISPLAY="$2"; shift 2 ;;
      --wrapper-route)
        case "${2:-}" in none|fast|full) WRAPPER_ROUTE="$2" ;; *) echo 'ERROR: invalid wrapper route' >&2; exit 2 ;; esac
        shift 2 ;;
      --task)        TASK_TYPE="$2"; shift 2 ;;
      --description) DESCRIPTION="$2"; shift 2 ;;
      --include-diff) INCLUDE_DIFF=true; shift ;;
      --config)      CONFIG_FILE="$2"; CONFIG_SOURCE="--config flag"; CONFIG_PROVENANCE="flag"; shift 2 ;;
      --mode)        MODE="$2"; MODE_EXPLICIT=true; MODE_SOURCE="--mode flag"; shift 2 ;;
      --strategy)    STRATEGY="$2"; STRATEGY_SOURCE="--strategy flag"; shift 2 ;;
      --cli)         CLI_FILTER="${CLI_FILTER:+$CLI_FILTER }$2"; shift 2 ;;
      --exclude-cli)
        # 空文字は「値を渡したつもりで渡せていない」形（`--exclude-cli "$CLI"` で
        # 変数が空、等）。黙って no-op にすると、外したはずの CLI が毎回プランに
        # 載り続ける — この機能が消そうとしている状態そのものになる。シム
        # （templates/codex-review.sh）の同名オプションと同じ文言・同じ rc で拒否する。
        if [[ $# -lt 2 || -z "$2" ]]; then
          echo "ERROR: --exclude-cli には CLI 名が必要です（例: --exclude-cli grok-cli）。" >&2
          exit 2
        fi
        EXCLUDE_CLIS_FLAG="${EXCLUDE_CLIS_FLAG:+$EXCLUDE_CLIS_FLAG }$2"; shift 2 ;;
      # カンマ区切り（--perspective a,b）も受理し、空白区切りの一覧へ畳む。繰り返し
      # 指定（--perspective a --perspective b）と併用できる。分割後の各語は
      # validate_requested_perspectives の is_safe_token を通る。
      --perspective)
        # 区切りだけの値（`,` 等）は観点 0 個に畳まれ、後段の「プランが空」まで原因が
        # 名乗られないので、ここで名指しして止める。空文字（''）は従来どおり無指定扱い。
        if [[ $# -ge 2 && -n "$2" && -z "${2//[, ]/}" ]]; then
          echo "ERROR: --perspective に観点名がありません: '${2}'（カンマ区切りは a,b の形で渡してください）" >&2
          exit 2
        fi
        PERSPECTIVE_FILTER="${PERSPECTIVE_FILTER:+$PERSPECTIVE_FILTER }${2//,/ }"; shift 2 ;;
      --exclude-perspective)
        if [[ $# -lt 2 ]]; then
          echo "ERROR: --exclude-perspective には観点名が必要です。" >&2
          exit 2
        fi
        EXCLUDE_PERSPECTIVES="${EXCLUDE_PERSPECTIVES:+$EXCLUDE_PERSPECTIVES }$2"; shift 2 ;;
      --list-perspectives) LIST_PERSPECTIVES=true; shift ;;
      --parallel)    PARALLEL=true; shift ;;
      --sequential)  PARALLEL=false; shift ;;
      --evidence) REVIEW_EVIDENCE=true; shift ;;
      --require-prior-review) REVIEW_EVIDENCE=true; REVIEW_EVIDENCE_PRIOR="$2"; shift 2 ;;
      --continue-review) REVIEW_EVIDENCE=true; REVIEW_EVIDENCE_PARENT="$2"; shift 2 ;;
      --output-dir)  OUTPUT_DIR="$2"; OUTPUT_DIR_EXPLICIT=true; shift 2 ;;
      # 名前をそのまま受ける。鮮度解決は parse_args の最後で最終 base に 1 回だけ
      # 掛ける（finalize_base_branch）。ここで解決すると、init 側の既定 base の解決と
      # 合わせて選択行が 2 行出る。
      --base)        BASE_BRANCH="$2"; BASE_BRANCH_SOURCE="--base flag"; BASE_BRANCH_EXPLICIT=true; shift 2 ;;
      --staged)      STAGED_DIFF=true; shift ;;
      --resume)      RESUME=true; shift ;;
      --fresh)       FRESH=true; shift ;;
      --archive-only) ARCHIVE_ONLY=true; shift ;;
      --archive-only=*)
        ARCHIVE_ONLY=true; ARCHIVE_PREVIOUS_BRANCH="${1#--archive-only=}"
        [[ -n "$ARCHIVE_PREVIOUS_BRANCH" ]] || { echo 'ERROR: --archive-only= requires a previous branch.' >&2; exit 2; }
        shift ;;
      --dry-run)     DRY_RUN=true; shift ;;
      --delegate-to-host) DELEGATE_TO_HOST=true; shift ;;
      --delegate-to-host=*)
        DELEGATE_TO_HOST=true
        DELEGATION_LANE="${1#--delegate-to-host=}"
        if ! delegation_lane_allowed "$DELEGATION_LANE"; then
          echo "ERROR: --delegate-to-host=${DELEGATION_LANE}: only the host's own lane can be delegated (claude-code, codex-cli or grok-cli)." >&2
          exit 1
        fi
        shift ;;
      --print-reviewers) PRINT_REVIEWERS=true; shift ;;
      --set-reviewers)   SET_REVIEWERS="$2"; shift 2 ;;
      --timeout)     TIMEOUT="$2"; shift 2 ;;
      --help|-h)     show_help ;;
      *)
        echo "Unknown option: $1" >&2
        echo "Run with --help for usage" >&2
        exit 1
        ;;
    esac
  done

  if [[ "$ARCHIVE_ONLY" == true ]]; then
    if [[ "$TASK_TYPE" != review || "$FRESH" == true || "$RESUME" == true || "$DELEGATE_TO_HOST" == true \
      || "$DRY_RUN" == true || "$STAGED_DIFF" == true || "$REVIEW_EVIDENCE" == true \
      || "$LIST_PERSPECTIVES" == true || "$PRINT_REVIEWERS" == true || -n "$SET_REVIEWERS" || -n "$archive_conflict" ]]; then
      echo 'ERROR: --archive-only is a standalone review operation; use only route, config, base and output-dir.' >&2
      exit 2
    fi
    if [[ -n "$ARCHIVE_PREVIOUS_BRANCH" ]]; then
      case "$ARCHIVE_PREVIOUS_BRANCH" in refs/heads/*) ;; refs/*|detached:*) echo 'ERROR: previous branch must be a local branch name.' >&2; exit 2 ;; *) ARCHIVE_PREVIOUS_BRANCH="refs/heads/${ARCHIVE_PREVIOUS_BRANCH}" ;; esac
      git check-ref-format "$ARCHIVE_PREVIOUS_BRANCH" >/dev/null 2>&1 || { echo 'ERROR: invalid previous branch name.' >&2; exit 2; }
    fi
  fi

  # Validate task type
  case "$TASK_TYPE" in
    review|explore|implement) ;;
    *)
      echo "ERROR: Invalid task type: '${TASK_TYPE}'. Must be review, explore, or implement." >&2
      exit 1
      ;;
  esac

  if [[ "$STAGED_DIFF" == "true" && "$TASK_TYPE" != "review" ]]; then
    echo "ERROR: --staged is only valid for review tasks." >&2
    exit 2
  fi
  if [[ "$STAGED_DIFF" == "true" && "$BASE_BRANCH_EXPLICIT" == "true" ]]; then
    echo "ERROR: --staged and an explicit base (--base / MULTI_AGENT_BASE_BRANCH) are mutually exclusive." >&2
    echo "       Choose the staged index or a base-branch diff; they are different review scopes." >&2
    exit 2
  fi
  if [[ "$RESUME" == true && ( -n "$REVIEW_EVIDENCE_PRIOR" || -n "$REVIEW_EVIDENCE_PARENT" ) ]]; then
    echo "ERROR: --resume cannot be combined with prior/continued review evidence; tasks must run after the prior review." >&2
    exit 2
  fi
  if [[ "$FRESH" == true && ( -n "$REVIEW_EVIDENCE_PARENT" || -n "$REVIEW_EVIDENCE_PRIOR" ) ]]; then
    echo "ERROR: --fresh cannot be combined with prior/continued evidence; it archives the evidence lineage." >&2
    exit 2
  fi
  if [[ "$FRESH" == "true" && "$RESUME" == "true" ]]; then
    echo "ERROR: --fresh cannot be combined with --resume." >&2
    echo "       --fresh archives previous results; --resume reuses them." >&2
    exit 2
  fi
  # 委譲は review 専用。explore / implement を通すと、implement の
  # staging 契約（どこへ書いてよいか・誰が mkdir するか）をホスト側の実行主体に対して
  # 定義し直すことになり、その契約はまだ存在しない。黙って review 相当で動かさない。
  if [[ "$DELEGATE_TO_HOST" == "true" && "$TASK_TYPE" != "review" ]]; then
    echo "ERROR: --delegate-to-host is only valid for review tasks (got '${TASK_TYPE}')." >&2
    exit 2
  fi
  # --fresh との併用は拒否する。委譲は「同じコマンドをもう一度」で完了する契約だが、
  # --fresh は出力ディレクトリの中身（ホストが書いた結果と受け渡しファイルの両方）を
  # 回収より前に退避するので、2 回目が毎回新しい handoff になり**収束しない**。しかも
  # ホストが完了させたレビューが一度も読まれないまま .prev-<ts>/ へ入る（黙って失われる）。
  # --fresh + --resume を拒否しているのと同じ形で、矛盾する 2 つの意図をここで止める。
  if [[ "$FRESH" == "true" && "$DELEGATE_TO_HOST" == "true" ]]; then
    echo "ERROR: --fresh cannot be combined with --delegate-to-host." >&2
    echo "       --fresh archives the output dir (including the host's written results and the" >&2
    echo "       handoff files) before they can be collected, so the delegation never converges." >&2
    print_archive_recovery
    exit 2
  fi

  # Validate description for explore/implement
  # --list-perspectives は「その task にどんな観点があるか」を出すだけで、タスクを
  # 実行しない。description を要求すると、一覧を見たいだけの利用者が explore/implement で
  # 落ちる（実測）。dry-run が免除されているのと同じ理由。
  if [[ "$TASK_TYPE" != "review" && -z "$DESCRIPTION" \
        && "$DRY_RUN" == "false" && "$LIST_PERSPECTIVES" == "false" ]]; then
    echo "ERROR: --description is required for ${TASK_TYPE} tasks." >&2
    exit 1
  fi

  # 引数がすべて確定してから最終 base を 1 回だけ解決する（選択行も 1 行だけ）。
  finalize_base_branch
}

# ── Config Loading (v1/v2 compatible) ──
config_is_explicit() {
  case "$CONFIG_PROVENANCE" in
    env|flag) return 0 ;;
    project|plugin|legacy) return 1 ;;
    *)
      echo "ERROR: invalid config provenance: ${CONFIG_PROVENANCE}" >&2
      exit 2
      ;;
  esac
}

load_config() {
  # Fall back to review-config.yaml if agent-config.yaml doesn't exist
  if [[ ! -f "$CONFIG_FILE" ]]; then
    # An explicitly requested config that is missing must fail loud — silently
    # substituting defaults would run with settings the user did not choose.
    if config_is_explicit; then
      echo "ERROR: config file not found: $CONFIG_FILE (from ${CONFIG_SOURCE})" >&2
      exit 1
    fi
    local fallback_config="${SCRIPT_DIR}/review-config.yaml"
    if [[ -f "$fallback_config" ]]; then
      echo "ℹ️  Using legacy config: $fallback_config" >&2
      CONFIG_FILE="$fallback_config"
      CONFIG_SOURCE="legacy review-config.yaml"
      CONFIG_PROVENANCE="legacy"
    else
      echo "⚠️  Config file not found: $CONFIG_FILE (using defaults)" >&2
      return 0
    fi
  fi

  if command -v yq &>/dev/null; then
    local config_parse_error=""
    if ! config_parse_error="$(yq '.' "$CONFIG_FILE" 2>&1)"; then
      if config_is_explicit; then
        echo "ERROR: explicit config could not be parsed by yq: $CONFIG_FILE (from ${CONFIG_SOURCE})" >&2
        printf 'yq: %s\n' "$config_parse_error" >&2
        exit 1
      fi
      echo "⚠️  Config file could not be parsed by yq. Using defaults." >&2
      printf 'yq: %s\n' "$config_parse_error" >&2
      return 0
    fi

    local cfg_val
    cfg_val=$(yq -r '.mode // ""' "$CONFIG_FILE" 2>/dev/null || true)
    if [[ -n "$cfg_val" ]]; then
      MODE="$cfg_val"
      MODE_SOURCE="config mode (${CONFIG_SOURCE})"
    fi

    cfg_val=$(yq -r '.parallel // ""' "$CONFIG_FILE" 2>/dev/null || true)
    [[ "$cfg_val" == "true" ]] && PARALLEL=true
    [[ "$cfg_val" == "false" ]] && PARALLEL=false

    # 環境ごとの既定除外（例: この機械では grok が起動できない）。version に依らず
    # トップレベルで読む — 除外の理由は「その機械の環境」であってタスク種別ではない。
    # 書式は review.critical_nonblock_perspectives と同じ **1 文字列**（空白または
    # カンマ区切り）。YAML リストで書くと yq -r が複数行を返し、名前が CLI 名に
    # 一致しなくなるので、黙って無視せず警告して読み飛ばす。
    cfg_val=$(yq -r '.exclude_clis // ""' "$CONFIG_FILE" 2>/dev/null || true)
    if [[ "$cfg_val" == *$'\n'* || "$cfg_val" == -* ]]; then
      echo "⚠️  exclude_clis は YAML リストではなく 1 文字列（空白またはカンマ区切り）で指定してください。読み飛ばします" >&2
    elif [[ -n "$cfg_val" && "$cfg_val" != "null" ]]; then
      cfg_val="${cfg_val//,/ }"
      cfg_val="${cfg_val//$'\t'/ }"
      # 連続空白と前後空白を潰す。表示にそのまま出る値なので "a,  b" が
      # "a  b" のまま出ると設定の書き方の差が出力の差に見える。
      # shellcheck disable=SC2086 # 意図的な単語分割による正規化
      cfg_val="$(echo $cfg_val)"
      EXCLUDE_CLIS_CONFIG="$cfg_val"
      EXCLUDE_CLIS_CONFIG_SOURCE="$CONFIG_SOURCE"
    fi

    # v2: task-specific config
    local version
    version=$(yq -r '.version // "1.0"' "$CONFIG_FILE" 2>/dev/null || true)

    if [[ "$version" == "2.0" ]]; then
      # Read task-specific settings
      # mode をタスク単位で読む。グローバルの mode: は全タスク共通の既定で、
      # review だけ pair にしたいといった指定ができなかった（v2.0 で cost_strategy /
      # timeout / output_dir がタスク単位なのと同じ扱いへ揃える）。
      cfg_val=$(yq -r ".tasks.${TASK_TYPE}.mode // \"\"" "$CONFIG_FILE" 2>/dev/null || true)
      if [[ -n "$cfg_val" ]]; then
        MODE="$cfg_val"
        MODE_SOURCE="config tasks.${TASK_TYPE}.mode (${CONFIG_SOURCE})"
      fi

      cfg_val=$(yq -r ".tasks.${TASK_TYPE}.cost_strategy // \"\"" "$CONFIG_FILE" 2>/dev/null || true)
      if [[ -n "$cfg_val" && -z "$STRATEGY" ]]; then
        STRATEGY="$cfg_val"
        STRATEGY_SOURCE="config tasks.${TASK_TYPE}.cost_strategy (${CONFIG_SOURCE})"
      fi

      cfg_val=$(yq -r ".tasks.${TASK_TYPE}.timeout // \"\"" "$CONFIG_FILE" 2>/dev/null || true)
      [[ -n "$cfg_val" && -z "$TIMEOUT" ]] && TIMEOUT="$cfg_val"

      cfg_val=$(yq -r ".tasks.${TASK_TYPE}.output_dir // \"\"" "$CONFIG_FILE" 2>/dev/null || true)
      [[ -n "$cfg_val" && -z "$OUTPUT_DIR" ]] && { OUTPUT_DIR="${REPO_ROOT}/${cfg_val}"; OUTPUT_DIR_SOURCE="$CONFIG_SOURCE"; }
    else
      # v1 compatibility
      cfg_val=$(yq -r '.cost_strategy // ""' "$CONFIG_FILE" 2>/dev/null || true)
      if [[ -n "$cfg_val" && -z "$STRATEGY" ]]; then
        STRATEGY="$cfg_val"
        STRATEGY_SOURCE="config cost_strategy (${CONFIG_SOURCE})"
      fi

      cfg_val=$(yq -r '.timeout // ""' "$CONFIG_FILE" 2>/dev/null || true)
      [[ -n "$cfg_val" && -z "$TIMEOUT" ]] && TIMEOUT="$cfg_val"

      cfg_val=$(yq -r '.output_dir // ""' "$CONFIG_FILE" 2>/dev/null || true)
      [[ -n "$cfg_val" && -z "$OUTPUT_DIR" ]] && { OUTPUT_DIR="${REPO_ROOT}/${cfg_val}"; OUTPUT_DIR_SOURCE="$CONFIG_SOURCE"; }
    fi
  else
    if config_is_explicit; then
      echo "ERROR: yq is required to read explicit config: $CONFIG_FILE (from ${CONFIG_SOURCE})" >&2
      exit 1
    fi
    echo "ℹ️  yq not found — using defaults. Install yq for config file support." >&2
  fi
  return 0  # last &&-list may legitimately be false — don't let set -e kill the script
}

# ── Apply task-type defaults (after config + CLI args) ──
# mode の whitelist 検証（Issue `#699`）。未知の値は build_execution_plan の else 経路で
# distributed として走り、プランヘッダは誤値をそのまま表示する — `--mode distribuited`
# や設定ファイルの古い `mode: cross_model` が「指定どおり動いた」ように見える。さらに
# `#597` で入った受理ゲートは MODE 文字列に依存するので、誤設定ほど安全網が外れる。
# STRATEGY の whitelist（Issue `#691`）と同じく CLI・config の両経路がここを通る。
# apply_task_defaults と --list-perspectives の早期 exit の両方から呼ぶため関数にする
# （片方だけに置くと、一覧経路で綴り間違いが rc=0 の「確認」になる）。
validate_mode() {
  # 既定解決前に呼ばれる経路（--list-perspectives）では空でありうる。空は「未指定」で、
  # apply_task_defaults が task 既定を入れるので、ここでは拒否しない。
  [[ -n "$MODE" ]] || return 0
  case "$MODE" in
    pair|distributed|cross-model) return 0 ;;
    *)
      echo "ERROR: unknown mode '${MODE}' (from ${MODE_SOURCE})." >&2
      echo "       Valid values: pair, distributed, cross-model." >&2
      exit 1 ;;
  esac
}

apply_task_defaults() {
  # review だけ pair（主+副）を既定にする。explore / implement は従来の分散のまま。
  # 既存の分散モードは --mode distributed で引き続き使える。
  if [[ -z "$MODE" ]]; then
    if [[ "$TASK_TYPE" == "review" ]]; then MODE="pair"; else MODE="distributed"; fi
    MODE_SOURCE="task default"
  fi
  validate_mode
  # pair は review 専用。build_pair_plan は review の観点しか組まないので、他タスクで
  # 受け入れると dry-run だけ成功して実行時に「観点ファイルが無い」で全件失敗する
  # （プランは正しく見えるのに中身が存在しない、という一番たちの悪い形）。
  if [[ "$MODE" == "pair" && "$TASK_TYPE" != "review" ]]; then
    echo "ERROR: --mode pair is review-only (got --task ${TASK_TYPE})." >&2
    echo "       explore / implement use the distributed plan." >&2
    exit 1
  fi
  [[ -z "$OUTPUT_DIR" ]] && OUTPUT_DIR="$(get_default_output_dir "$TASK_TYPE")"
  [[ -z "$TIMEOUT" ]] && TIMEOUT="$(get_default_timeout "$TASK_TYPE")"
  if [[ -z "$STRATEGY" ]]; then
    STRATEGY="$(get_default_strategy "$TASK_TYPE")"
    STRATEGY_SOURCE="task default"
  fi
  # strategy の whitelist 検証（Issue `#691`）。未知の値を黙って受けると、どの分岐にも
  # 一致せず balanced と同じ「何もしない」実行に落ちる — minimize_cost の typo
  # （minimize_costs / minimise_cost 等）は振替も pair の非適用通知も出ない完全な
  # 無音になり、この通知が守ろうとする利用者がまさに踏む穴になる。CLI・config の
  # 両経路がここを通るので、dry-run でも実行でも同じく非 0 で拒否する。
  case "$STRATEGY" in
    balanced|minimize_cost|maximize_quality) ;;
    *)
      echo "ERROR: unknown strategy '${STRATEGY}' (from ${STRATEGY_SOURCE})." >&2
      echo "       Valid values: balanced, minimize_cost, maximize_quality." >&2
      exit 1 ;;
  esac
  return 0  # last &&-list may legitimately be false — don't let set -e kill the script
}

# 読み込み完了の印（multi-agent.sh の読み込み部が照合する。最後の行に置く）
_ma_part_loaded="multi-agent-options.sh"
