#!/usr/bin/env bash
# multi-agent.sh の構成ファイル: 失敗・スキップしたタスクの再実行の案内。
#
# scripts/multi-agent.sh が開始時に 1 回だけ source する（直接実行しない）。読み込む順・
# 読めないときの停止・--resume の入力 identity への算入は multi-agent.sh の
# MULTI_AGENT_PARTS が正本。本文は分割前の multi-agent.sh の連続した行そのままで、
# トップレベルの初期化は構成ファイル同士で分割前と同じ順に走る（入口に残したタスク種別の既定より
# 後に走る点だけが違う）。ここへ set / trap / source を足さない。
# 末尾の _ma_part_loaded の行は読み込み完了の印（途中で切れたファイルを読み込み部が
# 見分ける）。bash 3.2 互換。分割の判断は ADR-075。
# pipefail-inherited: multi-agent.sh が set -euo pipefail の下で source する

# ── Retry Advice For Failed Tasks ──
# A failed task is never re-dispatched to another CLI (see "Fallback semantics"
# in the header of multi-agent.sh). That is only a defensible default if the user is handed the
# commands they would otherwise have wanted the tool to run behind their back,
# so print them: same CLI with more time, or the configured substitute — named
# explicitly, with its cost tier, as a choice rather than a surprise.
# ホスト委譲で走らせ直せる grok-cli の観点（空白区切り。無ければ空）。条件: review で、
# 今回の実行が委譲しておらず、ホストが grok CLI のセッション（GROK_AGENT が立つ）で、
# grok-cli のタスクが落ちたこと。失敗理由は問わない（時間切れ 124 も含む）— headless の
# 捕捉が前置きだけになる失敗は再実行で直らないことが多く、ホストのサブエージェントなら
# 理由に依らず同じプロンプトを走らせ直せる（Issue `#2118`）。
grok_host_delegable_perspectives() {
  [[ "$TASK_TYPE" == "review" && "$DELEGATE_TO_HOST" != "true" ]] || return 0
  [[ -n "${GROK_AGENT:-}" ]] || return 0
  local entry task out=""
  for entry in $FAILED_TASKS; do
    task="${entry%:*}"
    [[ "${task%%/*}" == "grok-cli" ]] || continue
    case " ${out} " in *" ${task#*/} "*) ;; *) out="${out:+${out} }${task#*/}" ;; esac
  done
  [[ -z "$out" ]] || printf '%s\n' "$out"
}

antigravity_host_delegable_perspectives() {
  [[ "$TASK_TYPE" == "review" && "$DELEGATE_TO_HOST" != "true" ]] || return 0
  [[ "${ANTIGRAVITY_AGENT:-}" == "1" ]] || return 0
  local entry task out=""
  for entry in $FAILED_TASKS; do
    task="${entry%:*}"
    [[ "${task%%/*}" == "antigravity-cli" ]] || continue
    case " ${out} " in *" ${task#*/} "*) ;; *) out="${out:+${out} }${task#*/}" ;; esac
  done
  [[ -z "$out" ]] || printf '%s\n' "$out"
}

# ホスト委譲で走らせ直せる claude-code の観点（空白区切り。無ければ空）。条件は 4 つ:
# review であること、今回の実行が委譲していないこと（委譲中はそもそも CLI を起動しない）、
# ホストが Claude Code であること（Claude Code は自身が起動するシェルへ CLAUDECODE=1 を
# 渡す。他ホストへ委譲すると別モデルで claude-code レーンを埋めることになる）、そして
# 落ちた理由が利用枠切れ（billing）または資格情報の拒否（auth）であること。
# 時間切れ（124）は語が stderr にあっても断定しない（個別案内の ⏱ 分岐と同じ扱い）。
# 第 1 引数に billing か auth を渡すとその理由だけを返す。省略時は両方。
host_delegable_perspectives() {
  [[ "$TASK_TYPE" == "review" && "$DELEGATE_TO_HOST" != "true" ]] || return 0
  [[ "${CLAUDECODE:-}" == "1" ]] || return 0
  local want="${1:-}" entry task rc cause out=""
  for entry in $FAILED_TASKS $SKIPPED_TASKS; do
    task="${entry%:*}"
    rc="${entry##*:}"
    [[ "${task%%/*}" == "$DELEGATION_LANE" ]] || continue
    cause="$(skipped_task_cause "$task")"
    if [[ -z "$cause" && "$rc" != "124" ]]; then
      cause="$(classify_cli_failure_cause "${OUTPUT_DIR}/${task}.md")"
    fi
    if [[ "$want" == "billing" || "$want" == "auth" ]]; then
      [[ "$cause" == "$want" ]] || continue
    else
      [[ "$cause" == "billing" || "$cause" == "auth" ]] || continue
    fi
    case " ${out} " in *" ${task#*/} "*) ;; *) out="${out:+${out} }${task#*/}" ;; esac
  done
  [[ -z "$out" ]] || printf '%s\n' "$out"
}

# 元の ignore 境界内でコマンドごとに分離する。案内だけでは作成せず、
# 同一の委譲コマンドと resume は呼び出し元が返値を一度だけ固定して使う。
recovery_command() {
  local command="$1" base="$2" label="$3" candidate suffix=0
  candidate="${base}-${label}"
  while [[ -e "$candidate" || -L "$candidate" ]]; do
    suffix=$((suffix + 1))
    candidate="${base}-${label}-${suffix}"
  done
  printf '%s --output-dir %s' "$command" "$(shell_quote "$candidate")"
}

# 先行・継続証跡の再実行案内。失敗した CLI の --cli を残したまま --exclude-cli を足すと
# 「--cli and --exclude-cli both name」で拒否される。--route full / fast は --exclude-cli と
# 併用できない。multi-review は --route を消費し、multi-agent の argv には --wrapper-route と
# --invocation-display だけが残る。案内の argv は lineage_normalize_argv が 1 か所で整える
# （route full / fast と表示文字列を外し、--mode を省いた実行には実効 mode を固定する）。
# 相互排他の規則自体は変えない。
# distributed で --cli が残ると、失敗 CLI はプラン構築の前にスキップされ、担当観点が
# fallback へ移らず消える。--cli を付けた distributed は --cli を全部外し、その実行の観点を
# --perspective で残してから --exclude-cli を足す。CLI 1 つ + 観点明示の実行だけは、
# 代替 CLI の --cli へ置き換える（担当表に無い観点を消さない）。
# pair の主は --exclude-cli で外せない（main reviewer was excluded）。主が落ちたときと、
# 副が落ちて総合観点がまだプランに残るときは、除外を足さず別の主をこの実行だけ案内する。
# --set-reviewers は保存して終わるので、案内コマンドには入れない。
lineage_failed_cli_list() {
  local entry cli seen=" " out=""
  for entry in $FAILED_TASKS $SKIPPED_TASKS; do
    cli="${entry%%/*}"
    [[ -n "$cli" ]] || continue
    case "$seen" in *" $cli "*) continue ;; esac
    seen="${seen}${cli} "
    out="${out}${out:+ }$cli"
  done
  printf '%s' "$out"
}

lineage_eligible_clis() {
  local failed=" $(lineage_failed_cli_list) " candidate out=""
  for candidate in $AVAILABLE_CLIS; do
    case "$failed" in *" $candidate "*) ;; *) out="${out}${out:+ }$candidate" ;; esac
  done
  printf '%s' "$out"
}

lineage_argv_has_cli_filter() {
  local i=0 n="${#INVOCATION_ARGV[@]}" arg
  while [[ "$i" -lt "$n" ]]; do
    arg="${INVOCATION_ARGV[$i]}"
    case "$arg" in
      --cli | --cli=*) return 0 ;;
    esac
    i=$((i + 1))
  done
  return 1
}

# この実行が実際に組んだ観点。空フィルタの distributed へ広げないために、--cli を外す案内で残す。
lineage_planned_perspectives() {
  local entry plan="${FULL_EXECUTION_PLAN:-$EXECUTION_PLAN}" seen=" " out="" persp
  while IFS= read -r entry; do
    [[ -n "$entry" ]] || continue
    persp="${entry#*:}"
    [[ -n "$persp" && "$persp" != "$entry" ]] || continue
    case "$seen" in *" $persp "*) continue ;; esac
    seen="${seen}${persp} "
    out="${out}${out:+ }$persp"
  done <<< "$plan"
  printf '%s' "$out"
}

# 案内コマンドの argv を 1 か所で正規化する。除外案内と主の差し替え案内の両方がここを通る。
# 案内は新しい起動なので、元の実行が argv の外（環境変数・設定）から得た入力は届かない。
# argv を書き換えるだけだと、その入力が 1 つずつ落ちる（同じ系統の取りこぼしが 4 件続いた）。
# 証跡の照合と計画を決める入力は argv から外し、解決済みの値から lineage_pinned_inputs と
# lineage_reviewer_env で固定し直す（通常の失敗案内が --staged / --base / --config を
# 解決済みの値で出すのと同じ契約）。
# - --base / --staged / --config は外す（解決済みの値で付け直す）。
# - route full / fast（--route / --wrapper-route）は --exclude-cli と併用できないので外す。
# - --invocation-display は常に外す。残すと、委譲のハンドオフが元のコマンドを
#   「Re-run command」として出し、失敗した CLI へ戻る案内と循環する。
# - <drop-all>=true は --cli を全部外し、それ以外は引数に名指しした CLI の --cli だけを外す。
# - 値を取るオプション（parse_args が shift 2 するもの）は値と組で扱う。値を次の語として
#   読むと、--description '--invocation-display' のような値をオプションと取り違えて外す。
# 結果は LINEAGE_ARGV へ置く（呼び出し元が format_initial_invocation へ渡す）。
lineage_normalize_argv() { # <drop-all:true|false> [cli-to-drop...]
  local drop_all="$1" i=0 n arg nxt drop
  shift
  drop=" $* "
  LINEAGE_ARGV=()
  n="${#INVOCATION_ARGV[@]}"
  while [[ "$i" -lt "$n" ]]; do
    arg="${INVOCATION_ARGV[$i]}"
    nxt=""
    if [[ $((i + 1)) -lt "$n" ]]; then
      nxt="${INVOCATION_ARGV[$((i + 1))]}"
    fi
    case "$arg" in
      --cli)
        if [[ "$drop_all" == true || "$drop" == *" $nxt "* ]]; then
          i=$((i + 2))
          continue
        fi
        LINEAGE_ARGV+=("$arg" "$nxt")
        i=$((i + 2))
        continue
        ;;
      --cli=*)
        if [[ "$drop_all" == true || "$drop" == *" ${arg#--cli=} "* ]]; then
          i=$((i + 1))
          continue
        fi
        ;;
      --route | --wrapper-route)
        if [[ "$nxt" == "full" || "$nxt" == "fast" ]]; then
          i=$((i + 2))
          continue
        fi
        LINEAGE_ARGV+=("$arg" "$nxt")
        i=$((i + 2))
        continue
        ;;
      --route=full | --route=fast | --wrapper-route=full | --wrapper-route=fast)
        i=$((i + 1))
        continue
        ;;
      --invocation-display)
        i=$((i + 2))
        continue
        ;;
      --invocation-display=*)
        i=$((i + 1))
        continue
        ;;
      --base | --config)
        i=$((i + 2))
        continue
        ;;
      --base=* | --config=* | --staged)
        i=$((i + 1))
        continue
        ;;
      --task | --description | --github-input | --mode | --strategy | --exclude-cli | --perspective \
        | --exclude-perspective | --require-prior-review | --continue-review | --output-dir \
        | --set-reviewers | --timeout)
        LINEAGE_ARGV+=("$arg" "$nxt")
        i=$((i + 2))
        continue
        ;;
    esac
    LINEAGE_ARGV+=("$arg")
    i=$((i + 1))
  done
}

# --mode を省いた実行の実効 mode を案内へ固定する。--cli だけで distributed へ落ちた実行は、
# --cli を外すと既定の pair へ戻り、主の除外で止まるか別の計画で走る。
lineage_mode_suffix() {
  [[ "$MODE_EXPLICIT" == true ]] && return 0
  printf ' --mode %s' "$MODE"
}

# 証跡が照合する入力（base_ref の文字列と差分の取り方）と、計画を決める設定ファイルを、
# 解決済みの値で固定する。base_ref は文字列で比べるので、証跡へ渡した BASE_BRANCH そのものを出す。
lineage_pinned_inputs() {
  if [[ "$STAGED_DIFF" == "true" ]]; then
    printf ' --staged'
  else
    printf ' --base %s' "$(shell_quote "$BASE_BRANCH")"
  fi
  if config_is_explicit; then
    printf ' --config %s' "$(shell_quote "$CONFIG_FILE")"
  fi
  lineage_mode_suffix
}

# pair の主・副は環境変数・設定ファイル・ユーザー設定から決まる。この実行の解決済みの値を
# 環境変数の前置で固定する（起動時だけの環境変数が案内から落ちると別の主・副で計画される）。
# 副が空なら空文字を明示する（「副なし」の意思。未設定だと設定ファイルの副へ戻る）。
lineage_reviewer_env() { # [main-override]
  local main="${1:-$REVIEW_MAIN}"
  [[ "$MODE" == "pair" && "$TASK_TYPE" == "review" ]] || return 0
  printf 'MULTI_AGENT_REVIEW_MAIN=%s MULTI_AGENT_REVIEW_SUB=%s ' \
    "$(shell_quote "$main")" "$(shell_quote "$REVIEW_SUB")"
}

# 失敗した CLI を全部外した 1 本。1 本ずつ出すと、残ったコマンドに別の失敗 CLI が居残る。
lineage_exclude_command() { # <failed-cli>...
  local cli i=0 arg drop_all_cli=false replacement=""
  local -a kept=()
  # 残った --cli は失敗 CLI を fallback の前に落とす。distributed の明示フィルタだけ全部外す。
  if [[ "$MODE" == "distributed" && "$TASK_TYPE" == "review" ]] && lineage_argv_has_cli_filter; then
    drop_all_cli=true
    # CLI 1 つ + 観点明示の実行は担当表を通らずに計画される（担当表に無い観点も載る）。
    # --cli を全部外すと担当表の計画へ移り、その観点がどの CLI にも割り当たらず消える。
    # その形だけは、失敗した CLI の --cli を代替 CLI の --cli へ置き換える。
    if [[ -n "$CLI_FILTER" && "$CLI_FILTER" != *" "* && -n "$PERSPECTIVE_FILTER" ]]; then
      replacement="$(AVAILABLE_CLIS="$(lineage_eligible_clis)" resolve_available_fallback "$CLI_FILTER")"
    fi
  fi
  lineage_normalize_argv "$drop_all_cli" "$@"
  kept=(${LINEAGE_ARGV[@]+"${LINEAGE_ARGV[@]}"})
  local cmd extra="" p planned existing=" "
  cmd="$(lineage_reviewer_env)$(format_initial_invocation "$0" ${kept[@]+"${kept[@]}"})"
  cmd="${cmd}$(lineage_pinned_inputs)"
  if [[ -n "$replacement" ]]; then
    cmd="${cmd} --cli ${replacement}"
  elif [[ "$drop_all_cli" == true ]]; then
    planned="$(lineage_planned_perspectives)"
    i=0
    while [[ "$i" -lt "${#kept[@]}" ]]; do
      arg="${kept[$i]}"
      if [[ "$arg" == "--perspective" && $((i + 1)) -lt ${#kept[@]} ]]; then
        existing="${existing}${kept[$((i + 1))]} "
        i=$((i + 2))
        continue
      fi
      if [[ "$arg" == --perspective=* ]]; then
        existing="${existing}${arg#--perspective=} "
      fi
      i=$((i + 1))
    done
    for p in $planned; do
      case "$existing" in *" $p "*) continue ;; esac
      extra="${extra} --perspective ${p}"
      existing="${existing}${p} "
    done
  fi
  for cli in "$@"; do
    cmd="${cmd} --exclude-cli ${cli}"
  done
  printf '%s%s' "$cmd" "$extra"
}

# pair で、失敗した CLI を --exclude-cli すると主の除外拒否か総合観点の欠落になる。
pair_lineage_switches_main() { # <failed-cli>
  local cli="$1"
  [[ "$MODE" == "pair" && "$TASK_TYPE" == "review" ]] || return 1
  if [[ -n "$REVIEW_MAIN" && "$cli" == "$REVIEW_MAIN" ]]; then
    return 0
  fi
  [[ -n "$REVIEW_SUB" && "$cli" == "$REVIEW_SUB" && "$cli" != "$REVIEW_MAIN" ]] || return 1
  perspective_excluded "$COMPREHENSIVE_PERSPECTIVE" && return 1
  if [[ -n "$PERSPECTIVE_FILTER" ]] && ! list_contains "$PERSPECTIVE_FILTER" "$COMPREHENSIVE_PERSPECTIVE"; then
    return 1
  fi
  return 0
}

# 空出力 = 導入済みの別主が無い。--exclude-cli へ落とさない（主の除外契約を守る）。
lineage_main_switch_command() { # <failed-cli>
  local cli="$1" replacement invocation eligible extra="" p clear_sub=false
  eligible="$(lineage_eligible_clis)"
  replacement="$(AVAILABLE_CLIS="$eligible" resolve_available_fallback "$cli")"
  [[ -n "$replacement" ]] || return 0
  lineage_normalize_argv false
  invocation="$(format_initial_invocation "$0" ${LINEAGE_ARGV[@]+"${LINEAGE_ARGV[@]}"})"
  invocation="${invocation}$(lineage_pinned_inputs)"
  # 副が落ちている、または代替主が副と同じなら、副を空にしないと失敗 CLI か総合観点の欠落が残る。
  if [[ -n "$REVIEW_SUB" && "$cli" == "$REVIEW_SUB" && "$cli" != "$REVIEW_MAIN" ]]; then
    clear_sub=true
  fi
  if [[ -n "$REVIEW_SUB" && "$replacement" == "$REVIEW_SUB" ]]; then
    clear_sub=true
  fi
  if [[ -n "$REVIEW_SUB" ]]; then
    case " $(lineage_failed_cli_list) " in
      *" $REVIEW_SUB "*) clear_sub=true ;;
    esac
  fi
  # フィルタが空の実行へ総合観点だけを足すと、成功済みの観点が再実行から落ちる。
  # 足すのはこの実行が実際に組んだ観点（観点ファイルの全一覧ではない）。主と副が同じ pair は
  # 副の重複を省いて総合観点を組まないので、全一覧を足すと親の証跡に無い観点が混ざり拒否される。
  if [[ "$clear_sub" == true && -z "$PERSPECTIVE_FILTER" ]]; then
    for p in $(lineage_planned_perspectives); do
      extra="${extra} --perspective ${p}"
    done
  fi
  # 副を残す回も解決済みの副を固定する（起動時だけの環境変数の副が落ちると、設定の副が
  # 代替主と重なるか、別の副で計画される）。
  if [[ "$clear_sub" == true ]]; then
    printf 'MULTI_AGENT_REVIEW_MAIN=%s MULTI_AGENT_REVIEW_SUB= %s%s' \
      "$(shell_quote "$replacement")" "$invocation" "$extra"
  else
    printf '%s%s' "$(lineage_reviewer_env "$replacement")" "$invocation"
  fi
}

print_failure_advice() {
  # スキップは FAILED_TASKS に載せない（実行していないものを「終了コード付きの失敗」
  # として記録すると、rc を読む全分岐が 4 つ目の意味を持つことになる）。案内は必要
  # なので、両方の一覧を走査対象にする（Issue `#1143`）。
  [[ -n "${FAILED_TASKS}${SKIPPED_TASKS}" ]] || return 0

  # Absolute path, not basename: this script normally lives inside an installed
  # plugin and is invoked from the target project, where no same-named file
  # exists. A bare `bash multi-agent.sh ...` would fail the moment it is pasted.
  # shell_quote keeps a path with spaces runnable, and unlike printf %q it is
  # byte-transparent, so a non-ASCII --description survives a non-UTF-8 locale as
  # valid UTF-8 (see the shell_quote header for the measurement).
  local self evidence_lineage=false
  if [[ -n "${REVIEW_EVIDENCE_PRIOR:-}" || -n "${REVIEW_EVIDENCE_PARENT:-}" ]]; then
    evidence_lineage=true
  fi
  self="bash $(shell_quote "${SCRIPT_DIR}/multi-agent.sh") --task ${TASK_TYPE}"
  # Carry the flags that decide WHAT gets looked at. Dropping --base would retry
  # against a different diff than the run that just failed, which makes the
  # suggested command quietly not-a-retry.
  if [[ "$STAGED_DIFF" == "true" ]]; then
    self="${self} --staged"
  elif [[ "$TASK_TYPE" == "review" || "$INCLUDE_DIFF" == "true" ]]; then
    self="${self} --base $(shell_quote "$BASE_BRANCH")"
  fi
  if [[ "$INCLUDE_DIFF" == "true" ]]; then
    # Without this the retry builds a prompt with no diff in it — a different task,
    # not a retry of the one that failed.
    self="${self} --include-diff"
  fi
  if config_is_explicit; then
    self="${self} --config $(shell_quote "$CONFIG_FILE")"
  fi
  # 以下は観点を絞るか CLI を変える別プラン。明示/既定いずれの出力先も再利用すると、
  # 完了済みの他観点が退避され、report/cache や未回収の委譲世代を上書きしてしまう。
  # .review-results/ の ignore 境界を保ち、別コマンド同士でも成果物を退避し合わない。
  local recovery_base host_self retry_self substitute_self
  recovery_base="${OUTPUT_DIR%/}/.recovery-$(date '+%Y%m%d-%H%M%S')-$$"
  # 自動取得の本文は argv に載せない。長い AC は引数上限を超え、再実行が明示 description になって取得の意味も消える。
  if [[ "$DESCRIPTION_EXPLICIT" == true && -n "$DESCRIPTION" ]]; then
    self="${self} --description $(shell_quote "$DESCRIPTION")"
  elif [[ "$REVIEW_AC_AUTO" == true ]]; then
    self="${self} --review-ac-auto"
    if [[ -n "${REVIEW_AC_GITHUB_INPUT:-}" ]]; then
      self="${self} --github-input $(shell_quote "$REVIEW_AC_GITHUB_INPUT")"
    fi
  fi

  # 全滅した prompt-too-long は、個別の再実行コマンドより**先に**出す（公開
  # feel-flow/ff-dev-toolkit#95）。順序が案内そのもの — 後ろに置くと、読み手は先頭の
  # 再実行コマンドを打ってから原因に辿り着く。
  if prompt_too_long_run_wide; then
    local ptl_line ptl_prefix="   📐 "
    ensure_diff_size_summary
    echo "" >&2
    while IFS= read -r ptl_line; do
      echo "${ptl_prefix}${ptl_line}" >&2
      ptl_prefix="      "
    done < <(prompt_too_long_advice_lines)
  fi

  # claude-code レーンの利用枠切れまたは認証拒否は、ホストが Claude Code なら
  # --delegate-to-host でホストのセッションに走らせられる。下の個別案内（同じ CLI の
  # 再実行・再ログイン・代替 CLI）は、枠切れには同じアカウントを使い、認証拒否は
  # 非対話では claude auth login を完了できず、代替はクロスモデルの独立性を潰す。
  # 個別案内より**先に**出す。文言は原因ごと。両方なら両方を書く。
  local billing_persps auth_persps delegable_persps
  billing_persps="$(host_delegable_perspectives billing)"
  auth_persps="$(host_delegable_perspectives auth)"
  delegable_persps=""
  local dp
  for dp in $billing_persps $auth_persps; do
    case " ${delegable_persps} " in
      *" ${dp} "*) ;;
      *) delegable_persps="${delegable_persps:+${delegable_persps} }${dp}" ;;
    esac
  done
  if [[ -n "$delegable_persps" ]]; then
    host_self="$(recovery_command "$self" "$recovery_base" "host-${DELEGATION_LANE}")"
    local dp_args=""
    for dp in $delegable_persps; do dp_args="${dp_args} --perspective ${dp}"; done
    echo "" >&2
    if [[ -n "$billing_persps" ]]; then
      echo "   🤝 ${DELEGATION_LANE} — the claude CLI's account is out of quota, but this host is a" >&2
      echo "      Claude Code session whose own account can run the lane." >&2
    fi
    if [[ -n "$auth_persps" ]]; then
      echo "   🤝 ${DELEGATION_LANE} — the claude CLI rejected its credentials. A non-interactive" >&2
      echo "      session cannot run \`claude auth login\`, but this host is a Claude Code session" >&2
      echo "      whose own account can run the lane." >&2
    fi
    if [[ "$evidence_lineage" == true ]]; then
      echo "      Prior/continued review evidence cannot be combined with --resume." >&2
      echo "      Complete the failed perspective on another CLI in the same output directory." >&2
      echo "      The re-run command is printed below." >&2
    else
      echo "      Re-run with" >&2
      echo "      --delegate-to-host (never with --fresh), run each handoff prompt in a read-only" >&2
      echo "      subagent, write its answer to the output-file the handoff names, then re-run" >&2
      echo "      the same command with --resume added:" >&2
      echo "       ${host_self} --cli ${DELEGATION_LANE}${dp_args} --delegate-to-host" >&2
      echo "       ${host_self} --cli ${DELEGATION_LANE}${dp_args} --delegate-to-host --resume" >&2
    fi
  fi

  # grok CLI がホスト（GROK_AGENT が立つ）で grok-cli レーンが落ちた回は、同じ CLI の再実行より
  # ホストのサブエージェントへの委譲が効く（headless の捕捉が前置きだけになる失敗は再実行で
  # 直らないことが多い。Issue `#2118`）。個別案内より先に出す。
  local grok_persps
  grok_persps="$(grok_host_delegable_perspectives)"
  if [[ -n "$grok_persps" ]]; then
    host_self="$(recovery_command "$self" "$recovery_base" 'host-grok-cli')"
    local gp gp_args=""
    for gp in $grok_persps; do gp_args="${gp_args} --perspective ${gp}"; done
    echo "" >&2
    echo "   🤝 grok-cli — this host is a grok CLI session. Run the lane in the host instead:" >&2
    if [[ "$evidence_lineage" == true ]]; then
      echo "      Prior/continued review evidence cannot be combined with --resume." >&2
      echo "      Complete the failed perspective on another CLI in the same output directory." >&2
      echo "      The re-run command is printed below." >&2
    else
      echo "      re-run with --delegate-to-host=grok-cli (never with --fresh), run each handoff" >&2
      echo "      prompt in a read-only subagent (spawn_subagent), write its answer to the" >&2
      echo "      output-file the handoff names, then re-run the same command with --resume added:" >&2
      echo "       ${host_self} --cli grok-cli${gp_args} --delegate-to-host=grok-cli" >&2
      echo "       ${host_self} --cli grok-cli${gp_args} --delegate-to-host=grok-cli --resume" >&2
    fi
  fi

  local agy_persps
  agy_persps="$(antigravity_host_delegable_perspectives)"
  if [[ -n "$agy_persps" ]]; then
    host_self="$(recovery_command "$self" "$recovery_base" 'host-antigravity-cli')"
    local ap ap_args=""
    for ap in $agy_persps; do ap_args="${ap_args} --perspective ${ap}"; done
    echo "" >&2
    echo "   🤝 antigravity-cli — this host is an Antigravity session. Run the lane in the host instead:" >&2
    if [[ "$evidence_lineage" == true ]]; then
      echo "      Prior/continued review evidence cannot be combined with --resume." >&2
      echo "      Complete the failed perspective on another CLI in the same output directory." >&2
      echo "      The re-run command is printed below." >&2
    else
      echo "      re-run with --delegate-to-host=antigravity-cli (never with --fresh), run each handoff" >&2
      echo "      prompt in a read-only subagent (invoke_subagent), write its answer to the" >&2
      echo "      output-file the handoff names, then re-run the same command with --resume added:" >&2
      echo "       ${host_self} --cli antigravity-cli${ap_args} --delegate-to-host=antigravity-cli" >&2
      echo "       ${host_self} --cli antigravity-cli${ap_args} --delegate-to-host=antigravity-cli --resume" >&2
    fi
  fi

  echo "" >&2
  echo "   No runtime fallback was attempted (by design: swapping the model changes" >&2
  echo "   what got reviewed, and the substitute may bill a costlier tier)." >&2
  echo "   Re-run the failed task(s) yourself:" >&2
  echo "   These changed-plan commands use a new output directory; keep the original" >&2
  echo "   results and review both reports. They do not complete the original round" >&2
  echo "   or combine separate runs into one accepted prior-evidence receipt." >&2

  if [[ "$evidence_lineage" == true ]]; then
    echo "" >&2
    echo "   Prior/continued review evidence cannot be combined with --resume." >&2
    echo "   Re-run in the same output directory so the failed perspective completes" >&2
    echo "   on another CLI and the continue-review lineage is kept:" >&2
    local seen_clis=" " lineage_cli lineage_entry switch_cmd
    local -a exclude_clis=()
    for lineage_entry in $FAILED_TASKS $SKIPPED_TASKS; do
      lineage_cli="${lineage_entry%%/*}"
      case " ${seen_clis} " in
        *" ${lineage_cli} "*) continue ;;
      esac
      seen_clis="${seen_clis}${lineage_cli} "
      if pair_lineage_switches_main "$lineage_cli"; then
        if [[ "$lineage_cli" == "$REVIEW_MAIN" ]]; then
          echo "       Pair mode cannot exclude the main reviewer. Pick another main for this run" >&2
          echo "       (MULTI_AGENT_REVIEW_MAIN; --set-reviewers saves a main permanently):" >&2
        else
          echo "       Excluding the sub drops comprehensive-review instead of moving it." >&2
          echo "       Give this run a main other than the failed sub, clear the sub, and put" >&2
          echo "       comprehensive-review on that main" >&2
          echo "       (MULTI_AGENT_REVIEW_MAIN and MULTI_AGENT_REVIEW_SUB=; --set-reviewers saves permanently):" >&2
        fi
        switch_cmd="$(lineage_main_switch_command "$lineage_cli")"
        if [[ -n "$switch_cmd" ]]; then
          echo "       ${switch_cmd}" >&2
        else
          echo "       No other installed CLI can take the main role. --exclude-cli cannot remove the main reviewer." >&2
        fi
      else
        exclude_clis+=("$lineage_cli")
      fi
    done
    if [[ "${#exclude_clis[@]}" -gt 0 ]]; then
      echo "       $(lineage_exclude_command "${exclude_clis[@]}")" >&2
    fi
  fi

  local entry task rc cli persp fb fb_tier cause login_cmd skip_cause fallback_candidates candidate
  for entry in $FAILED_TASKS $SKIPPED_TASKS; do
    task="${entry%:*}"
    rc="${entry##*:}"
    cli="${task%%/*}"
    persp="${task#*/}"
    retry_self="$(recovery_command "$self" "$recovery_base" "${cli}-${persp}-retry")"
    echo "" >&2
    # 認証切れ / 残高切れの切り分け（Issue `#659`）。retry コマンドの**前**に出す —
    # 「どちらでもない」失敗と同じ 1 行に丸めると、再ログインで直るのか、この CLI
    # では今日もう何も走らないのかが読めず、代替 CLI への切替判断が遅れる。
    # timeout（124）でも分類は**する**が、断定はしない。実測 1 件目（401 → websocket
    # 再接続 5 回 → 失敗）は短い --timeout なら容易に 124 側へ倒れ、そこで切り分けを
    # 完全に抑止すると「時間を倍にせよ」だけが出る — 同じ失敗を倍待たせる案内で、
    # まさに下の分岐が避けているものになる。補足として出し、判断は利用者に渡す。
    # スキップしたタスクは「失敗」ではなく「実行していない」。下の分岐は成果物の
    # stderr を判定材料にするが、スキップには成果物が無いので、そのまま流すと
    # 「結果ファイルが書かれていない（orchestrator 起因）」という別の失敗として
    # 案内され、読み手は存在しないクラッシュを追う（Issue `#1143`）。
    skip_cause="$(skipped_task_cause "$task")"
    # スキップは失敗の分類・rc 由来の案内を一切通さない。cause も明示的に空へ倒す
    # （前の反復の値が残ると、実行していないタスクに 🔑 / 💳 / 📏 が付く）。
    if [[ -n "$skip_cause" && -n "$(lane_precheck_block "$cli")" ]]; then
      # 起動前の確認・--resume の記憶で止めたレーン（Issue `#2044`）。「この実行で既に失敗した」は事実と違う
      cause=""
      echo "     ⏭ ${task} — not started: $(lane_precheck_block_phrase "$cli")." >&2
      case "$skip_cause" in
        auth)
          login_cmd="$(cli_login_command "$cli")"
          echo "        Log in first${login_cmd:+ (${login_cmd})}, then re-run:" >&2 ;;
        model-unsupported)
          echo "        Update the CLI, or choose a model this account supports for this run with" >&2
          echo "        $(get_cli_model_env_vars "$cli" | awk '{ print $1 }')=<model>, then re-run:" >&2 ;;
        *)
          echo "        Usage comes back with time or credits; when it is back, re-run:" >&2 ;;
      esac
      echo "       $(model_env_prefix "$cli")${retry_self} --cli ${cli} --perspective ${persp}" >&2
    elif [[ -n "$skip_cause" ]]; then
      cause=""
      echo "     ⏭ ${task} — not executed. ${cli} had already failed in this run with" >&2
      echo "        $(cause_phrase "$skip_cause"), which is a property of the CLI and not of" >&2
      echo "        the task: every remaining task on ${cli} would have failed identically." >&2
      echo "        Fix that first (see the ${cli} entry above), then re-run:" >&2
      echo "       $(model_env_prefix "$cli")${retry_self} --cli ${cli} --perspective ${persp}" >&2
    else
    cause="$(classify_cli_failure_cause "${OUTPUT_DIR}/${cli}/${persp}.md")"
    if [[ "$rc" -eq 124 && -n "$cause" ]]; then
      echo "     ⏱ ${cli} — hit the time limit, but its stderr also shows $(cause_phrase "$cause")." >&2
      echo "        Check that first: more time does not fix what the stderr is reporting." >&2
      cause=""   # 断定はしない。下の 🔑 / 💳 / 📏 は時間切れでない失敗のためのもの
    fi
    case "$cause" in
      auth)
        echo "     🔑 ${cli} — the CLI stderr says its credentials were rejected, not that it" >&2
        echo "        ran out of time. Re-running as-is will fail identically." >&2
        login_cmd="$(cli_login_command "$cli")"
        if [[ -n "$login_cmd" ]]; then
          echo "        Re-authenticate first: ${login_cmd}" >&2
        else
          # 表に無い CLI（新規追加で書き漏らした場合を含む）でも助言を行き止まりに
          # しない。具体的な入口が無いことと、次に何を探せばよいかは別。
          echo "        Re-authenticate with ${cli}'s own login command first." >&2
        fi
        ;;
      billing)
        echo "     💳 ${cli} — the CLI output says its credits / usage balance are exhausted." >&2
        echo "        No amount of retrying or extra time changes that; either restore billing" >&2
        echo "        for this CLI or use the substitute below." >&2
        ;;
      model-unsupported)
        # 原因の候補（CLI の版 / アカウント種別）と対処（CLI の更新 / モデルの一時上書き）を
        # 名指しする。上書きの入口はこの層が受け付ける env だけを案内する。
        local mu_var mu_installed mu_required mu_cmd
        mu_var="$(get_cli_model_env_vars "$cli")"
        mu_var="${mu_var%% *}"
        echo "     🚫 ${cli} — the CLI stderr says the selected model is not supported for this" >&2
        echo "        CLI version or account. Retrying as-is fails identically." >&2
        echo "        Likely causes: an outdated ${cli}, or an account type that does not offer" >&2
        echo "        this model." >&2
        if [[ "$cli" == "codex-cli" ]]; then
          mu_installed="$(codex_installed_version)"
          mu_required="$(codex_required_version)"
          mu_cmd="$(codex_install_layout)"; mu_cmd="$(codex_update_command "${mu_cmd%% *}")"
          echo "        codex-cli on PATH: ${mu_installed:-unknown}; models cache written by: ${mu_required:-unknown} ($(codex_models_cache_file))." >&2
          echo "        Update the CLI: ${mu_cmd:-$(codex_manual_update_hint)}" >&2
        else
          echo "        Update ${cli} to its latest version." >&2
        fi
        if [[ -n "$mu_var" ]]; then
          echo "        Or pin a model this CLI accepts for one run: ${mu_var}=<model> (prefix the re-run below)." >&2
        fi
        ;;
      argv)
        echo "     📏 ${cli} — the CLI never started: the OS rejected its argument list as too" >&2
        echo "        long (E2BIG). This is not a model failure and not a timeout — nothing ran." >&2
        echo "        The prompt does not travel on argv (it goes to the CLI on stdin or via a" >&2
        echo "        prompt file), so what is left on argv is only the CLI's own flags: the" >&2
        echo "        model selection from MULTI_AGENT_MODEL_<CLI>, sandbox / permission flags," >&2
        echo "        and (grok) the prompt-file path. Look at an oversized MULTI_AGENT_MODEL_*" >&2
        echo "        value, or an environment whose limit is far below \`getconf ARG_MAX\`" >&2
        echo "        (Git Bash on Windows caps CreateProcess near 32KB)." >&2
        ;;
      prompt-too-long)
        # 全滅していれば上の集約案内が既に対象側を名指ししているので、ここは
        # 「この CLI も同じ理由」であることと、実測値だけを繰り返さずに置く。
        echo "     📐 ${cli} — the model refused the request itself: the prompt was too long." >&2
        echo "        Nothing was looked at, and neither more time nor a different CLI changes" >&2
        echo "        the bytes being sent — the diff under review is what has to shrink." >&2
        ensure_diff_size_summary
        if [[ -n "$DIFF_SIZE_SUMMARY" ]]; then
          echo "        Reviewed diff: ${DIFF_SIZE_SUMMARY}." >&2
        fi
        # 成果物を単体で開く読み手にも同じ実測値を残す。ここで書くのは、この関数が
        # レポート生成より前に 1 度だけ走り、分類済みの cause を既に持っているため
        # （分類をもう 1 周させないための同居であって、助言の副作用ではない）。
        annotate_result_prompt_too_long "${OUTPUT_DIR}/${cli}/${persp}.md"
        ;;
    esac
    # Only a timeout is helped by a longer limit. Offering it for expired
    # credentials or a crash sends the user off to wait twice as long for the
    # identical failure.
    if [[ "$rc" -eq 124 ]]; then
      echo "     ${task} — more time on the same CLI:" >&2
      echo "       $(model_env_prefix "$cli")${retry_self} --cli ${cli} --perspective ${persp} --timeout $((TIMEOUT * 2))" >&2
    elif [[ -n "$cause" && -f "${OUTPUT_DIR}/${cli}/${persp}.md" ]]; then
      # 分類できた失敗は上の行が原因と対処を名指し済み。汎用の「時間では直らない
      # 失敗」を重ねると、名指しした原因より汎用文が先に読まれる。
      echo "     ${task} — after fixing the cause above, re-run:" >&2
      echo "       $(model_env_prefix "$cli")${retry_self} --cli ${cli} --perspective ${persp}" >&2
    elif [[ -f "${OUTPUT_DIR}/${cli}/${persp}.md" ]]; then
      echo "     ${task} — failed for a reason more time will not fix; read the CLI" >&2
      echo "       stderr in ${OUTPUT_DIR}/${cli}/${persp}.md, then re-run:" >&2
      echo "       $(model_env_prefix "$cli")${retry_self} --cli ${cli} --perspective ${persp}" >&2
    else
      # ワーカーが記録前に死んだ形。成果物は書かれていないので、存在しない
      # ファイルを読めとは案内しない（死因は上の ⚠️ worker 行にある）。
      echo "     ${task} — no result file was written (orchestrator-side failure;" >&2
      echo "       see the ⚠️ worker line above). Re-run:" >&2
      echo "       $(model_env_prefix "$cli")${retry_self} --cli ${cli} --perspective ${persp}" >&2
    fi
    fi
    # 代替 CLI の案内はスキップにも出す（Issue `#1143`）。資格情報・残高が死んで
    # いる CLI では「代替で今すぐ回す」が最も実行可能な次の一手であり、同じ理由で
    # 落とされた観点こそその案内を必要とする。
    # プラン構築と同じ解決を使う。ここだけ get_cli_fallback を直接呼ぶと、
    # 「設定上の代替は未導入だが、その先には導入済みがある」場合に代替案が出ない。
    # 案内は headless 単発を起動するため、プランが拒否する headless Grok の
    # 不成立観点を代替先として表示しない。名簿は
    # headless_grok_unreliable_review_perspectives。他観点と同じ fallback 順・課金境界は維持する。
    fallback_candidates="$AVAILABLE_CLIS"
    if is_headless_grok_unreliable_review_perspective "$persp"; then
      fallback_candidates=""
      for candidate in $AVAILABLE_CLIS; do
        [[ "$candidate" == "grok-cli" ]] && continue
        fallback_candidates="${fallback_candidates:+$fallback_candidates }$candidate"
      done
    fi
    fb="$(AVAILABLE_CLIS="$fallback_candidates" resolve_available_fallback "$cli")"
    if [[ -n "$fb" ]]; then
      substitute_self="$(recovery_command "$self" "$recovery_base" "${cli}-${persp}-substitute-${fb}")"
      fb_tier="$(get_cli_cost_tier "$fb")"
      echo "     ${task} — or the configured substitute ${fb} [${fb_tier}]:" >&2
      # 代替 CLI の行には代替 CLI に効く env だけを前置する（失敗した CLI の
      # モデル指定を持ち越すと、実際には使われない設定を使うかのように読める）
      echo "       $(model_env_prefix "$fb")${substitute_self} --cli ${fb} --perspective ${persp}" >&2
    fi
  done
}

# 読み込み完了の印（multi-agent.sh の読み込み部が照合する。最後の行に置く）
_ma_part_loaded="multi-agent-advice.sh"
