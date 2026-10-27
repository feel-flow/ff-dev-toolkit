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

# ホスト委譲で走らせ直せる claude-code の観点（空白区切り。無ければ空）。条件は 4 つ:
# review であること、今回の実行が委譲していないこと（委譲中はそもそも CLI を起動しない）、
# ホストが Claude Code であること（Claude Code は自身が起動するシェルへ CLAUDECODE=1 を
# 渡す。他ホストへ委譲すると別モデルで claude-code レーンを埋めることになる）、そして
# 落ちた理由が利用枠切れ（billing）であること。時間切れ（124）は billing の語が stderr に
# あっても断定しない（個別案内の ⏱ 分岐と同じ扱い）。
host_delegable_perspectives() {
  [[ "$TASK_TYPE" == "review" && "$DELEGATE_TO_HOST" != "true" ]] || return 0
  [[ "${CLAUDECODE:-}" == "1" ]] || return 0
  local entry task rc cause out=""
  for entry in $FAILED_TASKS $SKIPPED_TASKS; do
    task="${entry%:*}"
    rc="${entry##*:}"
    [[ "${task%%/*}" == "$DELEGATION_LANE" ]] || continue
    cause="$(skipped_task_cause "$task")"
    if [[ -z "$cause" && "$rc" != "124" ]]; then
      cause="$(classify_cli_failure_cause "${OUTPUT_DIR}/${task}.md")"
    fi
    [[ "$cause" == "billing" ]] || continue
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
  local self
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
  if [[ -n "$DESCRIPTION" ]]; then
    self="${self} --description $(shell_quote "$DESCRIPTION")"
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

  # claude-code レーンの利用枠切れは、ホストが Claude Code なら --delegate-to-host で
  # ホストのセッションに走らせられる。下の個別案内（同じ CLI の再実行・
  # codex 代替）はどちらも利用枠切れには効かない — 前者は同じアカウントの枠を使い、
  # 後者はクロスモデルの独立性を潰す — ので、個別案内より**先に**出す。
  local delegable_persps
  delegable_persps="$(host_delegable_perspectives)"
  if [[ -n "$delegable_persps" ]]; then
    host_self="$(recovery_command "$self" "$recovery_base" "host-${DELEGATION_LANE}")"
    local dp dp_args=""
    for dp in $delegable_persps; do dp_args="${dp_args} --perspective ${dp}"; done
    echo "" >&2
    echo "   🤝 ${DELEGATION_LANE} — the claude CLI's account is out of quota, but this host is a" >&2
    echo "      Claude Code session whose own account can run the lane. Re-run with" >&2
    echo "      --delegate-to-host (never with --fresh), run each handoff prompt in a read-only" >&2
    echo "      subagent, write its answer to the output-file the handoff names, then re-run" >&2
    echo "      the same command with --resume added:" >&2
    echo "       ${host_self} --cli ${DELEGATION_LANE}${dp_args} --delegate-to-host" >&2
    echo "       ${host_self} --cli ${DELEGATION_LANE}${dp_args} --delegate-to-host --resume" >&2
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
    echo "      re-run with --delegate-to-host=grok-cli (never with --fresh), run each handoff" >&2
    echo "      prompt in a read-only subagent (spawn_subagent), write its answer to the" >&2
    echo "      output-file the handoff names, then re-run the same command with --resume added:" >&2
    echo "       ${host_self} --cli grok-cli${gp_args} --delegate-to-host=grok-cli" >&2
    echo "       ${host_self} --cli grok-cli${gp_args} --delegate-to-host=grok-cli --resume" >&2
  fi

  echo "" >&2
  echo "   No runtime fallback was attempted (by design: swapping the model changes" >&2
  echo "   what got reviewed, and the substitute may bill a costlier tier)." >&2
  echo "   Re-run the failed task(s) yourself:" >&2
  echo "   These changed-plan commands use a new output directory; keep the original" >&2
  echo "   results and review both reports. They do not complete the original round" >&2
  echo "   or combine separate runs into one accepted prior-evidence receipt." >&2

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
    if [[ -n "$skip_cause" ]]; then
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
