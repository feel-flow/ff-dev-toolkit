#!/usr/bin/env bash
# multi-agent.sh の構成ファイル: レポート本文の部品（観点ごとの節・CRITICAL_BLOCK の段階化・型付き判定の集計・委譲の引き渡し）。
#
# scripts/multi-agent.sh が開始時に 1 回だけ source する（直接実行しない）。読み込む順・
# 読めないときの停止・--resume の入力 identity への算入は multi-agent.sh の
# MULTI_AGENT_PARTS が正本。本文は分割前の multi-agent.sh の連続した行そのままで、
# トップレベルの初期化は構成ファイル同士で分割前と同じ順に走る（入口に残したタスク種別の既定より
# 後に走る点だけが違う）。ここへ set / trap / source を足さない。
# 末尾の _ma_part_loaded の行は読み込み完了の印（途中で切れたファイルを読み込み部が
# 見分ける）。bash 3.2 互換。分割の判断は ADR-075。
# pipefail-inherited: multi-agent.sh が set -euo pipefail の下で source する

# ── Report Body (shared by review / explore / implement) ──
# Appends one section per plan entry to $1. Returns 0 if at least one section was
# written, 1 if the plan yielded none (the caller prints its own "no results" line).
#
# Stale-result guard: report exactly THIS run's entries by iterating the execution plan
# instead of globbing ${cli}/*.md. A perspective absent from this plan is never
# read. In the normal flow execute_tasks clears each entry's target before
# running (clear_planned_outputs), so a prior run's result — a different
# perspective, or a same-named stale file left by a failed task — does not
# appear as current. The report only reads result files and writes report_file;
# no result file is deleted or modified *here*, though the run itself is not
# side-effect free on a shared --output-dir: execute_tasks deletes this run's own
# targets (clear_planned_outputs) and moves the plan's other results into
# <cli>/previous/, discarding what an earlier run left there
# (quarantine_unplanned_outputs). A planned entry with no
# output file (CLI failure) is surfaced, not silently dropped. Callers must pass
# only validated plan entries — today every caller reaches here via
# generate_report, which runs validate_execution_plan first.
#
# This was three byte-identical copies, one per task type. The incomplete-result
# banner below has to be on every path — a truncated review that reads as a clean
# one is the failure mode issue `#152` is about — so there is one copy to change.
append_plan_sections() {
  local report_file="$1"
  local wrote_any=1

  # 今回の実行が書かなかった結果ファイルの名指し（Issue `#537` / `#654`）。退避できない
  # もの（プラン外 CLI のディレクトリ・orchestrator 以外が書いた .md）は動かさない
  # 契約なので、レポート側で「これは今回の結果ではない」と言い切っておく。
  local note
  if [[ -n "${UNPLANNED_RESULT_NOTES:-}" ]]; then
    {
      echo ""
      echo "> **Not part of this run** — the output directory also holds files this run did not write."
      echo "> They were left untouched and are NOT this run's results:"
      echo ">"
      while IFS= read -r note; do
        [[ -n "$note" ]] || continue
        echo "> - ${note}"
      done <<< "$UNPLANNED_RESULT_NOTES"
    } >> "$report_file"
  fi

  # 全滅した prompt-too-long は個別セクションより**手前**に置く（公開
  # feel-flow/ff-dev-toolkit#95）。各セクションの INCOMPLETE を 1 本ずつ読んでから
  # 「実は全部同じ 1 つの原因だった」と気付く順序では、実測の遠回り（CLI を 1 つずつ
  # 再実行する）がレポート経由でもそのまま再現する。
  if prompt_too_long_run_wide; then
    local ptl_line
    ensure_diff_size_summary
    {
      echo ""
      echo "> **📐 PROMPT TOO LONG — read this before the per-task sections.**"
      while IFS= read -r ptl_line; do
        echo "> ${ptl_line}"
      done < <(prompt_too_long_advice_lines)
      echo ""
    } >> "$report_file"
  fi

  local entry seen=""
  while IFS= read -r entry; do
    [[ -z "$entry" ]] && continue
    # Skip a duplicate plan entry so a repeated cli:perspective (e.g. a plan
    # fallback that reassigns a perspective to an already-listed CLI) is not
    # pasted into the report twice.
    if [[ " $seen " == *" $entry "* ]]; then continue; fi
    seen="$seen $entry"
    local cli_name="${entry%%:*}"
    local perspective_name="${entry#*:}"
    local result_file="${OUTPUT_DIR}/${cli_name}/${perspective_name}.md"
    wrote_any=0

    local tier
    tier="$(get_cli_cost_tier "$cli_name")"

    {
      echo ""
      echo "## ${cli_name} — ${perspective_name} [${tier}]"
      echo ""
      if list_contains "$REUSED_TASKS" "${cli_name}/${perspective_name}"; then
        echo "**Result source:** reused"
      elif [[ -n "$(unavailable_cross_task_cause "${cli_name}/${perspective_name}")" ]]; then
        echo "**Result source:** unavailable (completed with the main reviewer only)"
      elif delegated_task_pending "${cli_name}/${perspective_name}"; then
        # 「executed」と書くと、CLI を 1 つも起動していない節が実行済みに見える
        # （skipped と同じ理由で、節の中で数行下の本文と矛盾する）。
        echo "**Result source:** delegated to the host (pending)"
      elif [[ -n "$(skipped_task_cause "${cli_name}/${perspective_name}")" ]]; then
        # スキップした節へ executed と書くと、数行下の「this task was not executed」と
        # 同じ節の中で矛盾する（Issue `#1143`）。
        echo "**Result source:** skipped"
      else
        echo "**Result source:** executed"
      fi
      echo ""
      # implement は staging を**実測して**書く（Issue `#392`）。ヘッダの無条件な
      # 「生成物は staging にある」だけだと、1 ファイルも生成しなかったタスクも
      # 同じ案内になり、利用者は空のディレクトリを探しに行く。件数は数えれば
      # 分かるのだから、断定ではなく観測を載せる。
      # 0 件を失敗にはしない — 分析だけで生成ファイルが 0 個という結果は正当。
      if [[ "${TASK_TYPE:-review}" == "implement" ]]; then
        local staging_dir file_list file_count
        staging_dir="$(staging_dir_for "$cli_name" "$perspective_name")"
        if [[ ! -d "$staging_dir" ]]; then
          echo "**Staging:** \`${staging_dir}\` — (no files generated)"
        # find の rc を捨てると、走査に失敗した（権限・I/O エラー）ケースが
        # 「0 件」や部分件数として出る。断定を観測に置き換えるのが目的なのに、
        # 観測できなかったことを 0 件と言い切っては元の木阿弥になる。
        elif ! file_list="$(find "$staging_dir" -type f 2>/dev/null)"; then
          echo "**Staging:** \`${staging_dir}\` — ⚠️ could not read the staging directory (count unknown)"
        else
          # 空文字のときに grep -c が 1 を返す形を避けるため、空を先に分岐する。
          if [[ -z "$file_list" ]]; then
            file_count=0
          else
            file_count="$(printf '%s\n' "$file_list" | wc -l | tr -d ' ')"
          fi
          if [[ "$file_count" -gt 0 ]]; then
            echo "**Staging:** \`${staging_dir}\` (${file_count} file(s))"
          else
            echo "**Staging:** \`${staging_dir}\` — (no files generated)"
          fi
        fi
        echo ""
      fi
      # 委譲待ちの判定は `-f "$result_file"` より**前**に置く。委譲タスクは CLI を
      # 起動しないので数ミリ秒で終わり、他レーンが走っている数分のあいだにホストが
      # 結果パスへ書くと、-f が先に真になってその生テキストがレポートへそのまま載る —
      # プロンプト digest の照合も本文の受理ゲートも通らないまま、しかも節見出しは
      # 「pending」と名乗る。同じ未検証ファイルが CRITICAL_BLOCK 判定の入力にもなる。
      local unavail_cause
      unavail_cause="$(unavailable_cross_task_cause "${cli_name}/${perspective_name}")"
      if [[ -n "$unavail_cause" ]]; then
        # 主担当以外の利用不可。INCOMPLETE を名乗らない — 主担当の全観点が
        # 完走した回だけここへ来るので、レビューとしては主担当のみで完了している。
        # サルベージした成果物（CLI の stderr）は本文へ貼らない: 判定材料ではなく、
        # codex はプロンプト全文を stderr へエコーするので読み手を迷わせる。
        echo "⏭ **MAIN REVIEWER ONLY** — ${cli_name} was unavailable ($(unavailable_cause_label_ja "$unavail_cause")),"
        echo "so this run completed with the main reviewer (${REVIEW_MAIN}) only. This is not a finding"
        echo "of \"clean\" for this perspective from ${cli_name}; it simply did not run. How to make it"
        echo "usable again is in the run's stderr advice; the CLI's own output is kept at"
        echo "\`${result_file}\`."
      elif delegated_task_pending "${cli_name}/${perspective_name}"; then
        # 委譲待ちは「失敗」でも「スキップ」でもない第 3 の状態。
        # それでも **INCOMPLETE を名乗る** — 消費側ゲートはこの語でレビューの未完了を
        # 判定しており、ここで名乗らないと「委譲したまま誰も実行していないレビュー」が
        # 未完了なしとして通る。次の一手（ホストが書く場所・締め方）まで書くのは、
        # この節がそれを読む唯一の場所になりうるため。
        echo "🤝 **DELEGATED — pending host execution**, so this perspective counts as **INCOMPLETE**."
        echo "No CLI was started for it. The prompt this run built is at"
        echo "\`$(delegate_dir_for "$cli_name")/${perspective_name}.prompt.md\`."
        echo "The host runs it in its own session and writes the result to"
        echo "\`${result_file}\`, then re-runs the same command **with \`--resume\`** to have it"
        echo "adopted and this report regenerated."
        echo "Absence of a finding here means unchecked, not clean."
      elif [[ -f "$result_file" ]]; then
        # An adapter marks salvaged partial output with `Status: incomplete`
        # (adapters/adapter-common.sh). Repeat that in the report: without it the
        # section looks like any other and its silence reads as "found nothing"
        # rather than "never got there".
        #
        # Scoped to the header block, because a *complete* review whose body
        # quotes that marker line would otherwise be flagged incomplete — very
        # reachable here, where the tool reviews its own scripts.
        #
        # The scope ends at the first blank line, which is what separates
        # write_output's header from the body. A fixed line count would silently
        # drift the wrong way if the header ever gained a line: the marker would
        # fall outside the window and an incomplete result would read as complete.
        #
        # Done with awk rather than `head | grep -q`: grep's early exit SIGPIPEs
        # head, and under pipefail the pipeline returns 141, flipping a match into
        # a non-match (the inversion class recorded in ACE-149).
        if awk '/^$/ { exit } /^<!-- Status: incomplete -->$/ { found = 1 } END { exit found ? 0 : 1 }' "$result_file"; then
          # 理由は断定しない — incomplete はクラッシュ・タイムアウトだけでなく、
          # アダプタが結果を拒否した場合（sandbox-refused / missing-review-body）も
          # 通る。具体的な理由は成果物内の INCOMPLETE バナーが名指しする。
          echo "⚠️ **INCOMPLETE** — the CLI failed, timed out, or its result was refused;"
          echo "what follows is output salvaged from that run, not a finished ${TASK_TYPE}."
          echo "Absence of a finding here means unchecked, not clean."
          echo ""
        fi
        if [[ "$TASK_TYPE" == "review" ]]; then
          review_verification_summary "$result_file"
          echo ""
        fi
        cat "$result_file"
      elif [[ -n "$(skipped_task_cause "${cli_name}/${perspective_name}")" ]]; then
        # スキップは「失敗して何も書けなかった」とは別の状態（Issue `#1143`）。
        # 同じ 1 行に丸めると、読み手は起きていないクラッシュの原因を探しに行く。
        # 名指しするのは (a) 実行していないこと (b) その理由が CLI 単位であること
        # (c) この節の沈黙が「所見なし」ではないこと の 3 点。
        echo "⏭ **SKIPPED** — this task was not executed, so it counts as **INCOMPLETE**."
        echo "${cli_name} had already failed in this run for a $(skipped_task_cause "${cli_name}/${perspective_name}") reason, which is a"
        echo "property of the CLI and not of the task, so every remaining ${cli_name} task was"
        echo "dropped before paying for its setup."
        echo "Absence of a finding here means unchecked, not clean."
      else
        echo "⚠️ No output produced by this task — the CLI failed before writing any"
        echo "result. See the orchestrator log for the reason and the retry command."
      fi
      echo ""
      echo "---"
      echo ""
    } >> "$report_file"
  done <<< "$EXECUTION_PLAN"

  return "$wrote_any"
}

# ── CRITICAL_BLOCK 段階化（Issue `#645`）──
# 「非ブロック」へ格下げする観点の集合。ここに載った観点の Critical は修正必須の
# まま（本文はレポートに従来どおり Critical として現れる）だが、それ単独では
# <!-- CRITICAL_BLOCK --> を立てず <!-- CRITICAL_NONBLOCK --> の注記になる。
# 実測 22 巡のうち終盤 4 巡が comment-analysis の文言 Critical だけでフルゲートを
# 再実行しており、セキュリティ穴と文言指摘が同じ重さでは重い方の警報が薄まる。
#
# 集合は denylist — 載っていない観点（comprehensive-review・将来の追加観点を含む）
# は従来どおりブロックする。allowlist（ブロックする観点を列挙）にすると、新設の
# セキュリティ系観点が名簿更新を忘れただけで黙って非ブロックへ落ちる（fail open）。
#
# 解決の**形**（env の `+set` 判定・空文字の意思表示・project config の yq 読み）は
# resolve_reviewer_pair に合わせるが、第 3 層は別物 — あちらはユーザーグローバル
# （reviewers ファイル）へ落ち、こちらは組み込み既定へ落ちる:
#   env    MULTI_AGENT_CRITICAL_NONBLOCK_PERSPECTIVES
#          空文字の明示指定は「全観点ブロック（旧挙動）」の意思表示なので、
#          下位層で埋め戻さない
#   config review.critical_nonblock_perspectives（空白またはカンマ区切りの **1 文字列**。
#          YAML リストで書くと yq -r が複数行を返し名前が観点に一致しなくなるため、
#          警告して既定へ落とす。yq が無い環境でも読めず既定へ落ちる — 解析不能な
#          config を既定で動かす扱いは load_config と同じ）
DEFAULT_CRITICAL_NONBLOCK_PERSPECTIVES="comment-analysis test-analysis type-design-analysis code-simplification"

resolve_critical_nonblock_perspectives() {
  local v cfg
  if [[ "${MULTI_AGENT_CRITICAL_NONBLOCK_PERSPECTIVES+set}" == "set" ]]; then
    v="$MULTI_AGENT_CRITICAL_NONBLOCK_PERSPECTIVES"
  else
    v="$DEFAULT_CRITICAL_NONBLOCK_PERSPECTIVES"
    if [[ -f "$CONFIG_FILE" ]] && command -v yq &>/dev/null; then
      cfg="$(yq -r '.review.critical_nonblock_perspectives // ""' "$CONFIG_FILE" 2>/dev/null || true)"
      # 複数行 = 複数要素のリスト、行頭の "- " = 単一要素のリスト（yq -r は
      # どちらもブロックシーケンス形で返す。観点名が "-" で始まることはない）
      if [[ "$cfg" == *$'\n'* || "$cfg" == -* ]]; then
        echo "⚠️ review.critical_nonblock_perspectives は YAML リストではなく 1 文字列（空白またはカンマ区切り）で指定してください。読み飛ばして既定名簿を使います" >&2
      elif [[ -n "$cfg" && "$cfg" != "null" ]]; then
        v="$cfg"
      fi
    fi
  fi
  # 区切りをスペースへ正規化（カンマ・タブ区切りも受ける）。membership 判定は
  # 前後スペースの literal 一致なので、正規化しないとタブ区切りで指定された観点が
  # 黙ってブロック側へ倒れる — fail closed の向きではあるが、利用者の指定が
  # 静かに無視される形になる
  v="${v//,/ }"
  v="${v//$'\t'/ }"
  printf '%s\n' "$v"
}

# 名簿の typo は「その観点が計画に現れない」だけでブロック側へ倒れる（fail closed）
# ため実害はないが、意図した格下げが黙って効かないので診断を残す。
warn_unknown_critical_nonblock() { # <名簿>
  local p
  for p in $1; do
    if [[ -z "$(resolve_perspective_file "$p")" ]]; then
      echo "⚠️ critical_nonblock_perspectives の '${p}' は存在しない観点名です（typo?）。未知の名前は無視され、載っていない観点は従来どおりブロックします" >&2
    fi
  done
}

# review の実行は名簿を開始時に 1 回だけ解決し、レポート生成はその値を使う。
# 生成時に読み直すと、レビュー中の plugin 更新で既定 config（${SCRIPT_DIR}/agent-config.yaml）
# が消えたとき黙って組み込み既定へ落ち、観点ファイルの存在確認も偽の typo 警告を出す。
# これで CLI の完走後の工程は、root 変化の診断（report_plugin_root_change）を除いて plugin の root から何も読まない。
resolve_critical_nonblock_at_start() {
  REVIEW_CRITICAL_NONBLOCK_SET="$(resolve_critical_nonblock_perspectives)"
  REVIEW_CRITICAL_NONBLOCK_RESOLVED=true
  warn_unknown_critical_nonblock "$REVIEW_CRITICAL_NONBLOCK_SET"
}

# ── 型付き判定行の集計（ADR-065 の C3 追記）──
# 観点結果に有効な型付き判定行（`- verdict: severity=… failure_scenario=… confidence=…`）が
# 1 行でもあれば、その観点の Critical 判定と集計は判定行（typed_verdicts_extract の
# レコード）から決め、散文の重大度行は読まない。有効な行が 1 行も無い観点は散文から
# 判定しない（ADR-066 で散文経路を撤去した）: 未完了の観点（拒否・失敗・タイムアウトの
# INCOMPLETE 成果物）は本文から Critical を決めず「未確認 › 未完了の観点」に任せ、
# 完了扱いの結果（受理は判定行を要求するので、旧版で受理された結果か手置きのものだけ）は
# 判定の根拠が無いものとして安全側（Critical あり）へ倒す。
#
# 信頼度の報告閾値（既定 80）の解決順は resolve_critical_nonblock_perspectives と同じ形:
#   env    MULTI_AGENT_REVIEW_CONFIDENCE_THRESHOLD（空文字を含む不正値は名指しで停止する —
#          閾値を黙って既定へ戻すと、利用者が下げたつもりの閾値で低信頼の列挙が変わる）
#   config review.confidence_threshold（.claude/agent-config.yaml。不正値は名指しで停止。
#          yq が無い・キーが無いときは既定 — load_config と同じ扱い）
#   既定   80（code-review テンプレートの報告閾値と同じ）
# 値は 0〜100 の整数。閾値未満の finding は報告から落とさず「未確認 › 低信頼の指摘」へ
# 列挙する。code-review のテスト有効性の例外（3 形のタグ `[TEST-VALIDITY:unreached]` /
# `[TEST-VALIDITY:coincidental]` / `[TEST-VALIDITY:one-sided]` のどれかを前置した指摘は
# 信頼度 50 以上で報告する）はこの閾値の下でも維持する — 例外の finding には
# min(閾値, 50) を当てる。素の `[TEST-VALIDITY]` や未知の語は例外にしない（通常の閾値）。
DEFAULT_REVIEW_CONFIDENCE_THRESHOLD=80
REVIEW_TEST_VALIDITY_THRESHOLD=50
REVIEW_CONFIDENCE_THRESHOLD=""

review_confidence_threshold_valid() { # <value> → rc0 = 0〜100 の整数
  local v="$1"
  [[ "$v" =~ ^[0-9]+$ ]] || return 1
  [[ "${#v}" -le 3 ]] || return 1
  [[ "$((10#$v))" -le 100 ]]
}

resolve_review_confidence_threshold() {
  local v cfg
  if [[ "${MULTI_AGENT_REVIEW_CONFIDENCE_THRESHOLD+set}" == "set" ]]; then
    v="$MULTI_AGENT_REVIEW_CONFIDENCE_THRESHOLD"
    if ! review_confidence_threshold_valid "$v"; then
      echo "ERROR: MULTI_AGENT_REVIEW_CONFIDENCE_THRESHOLD must be an integer from 0 to 100, got: '${v}'" >&2
      echo "       Unset it to use review.confidence_threshold from the project config, or the default ${DEFAULT_REVIEW_CONFIDENCE_THRESHOLD}." >&2
      return 1
    fi
  else
    v="$DEFAULT_REVIEW_CONFIDENCE_THRESHOLD"
    if [[ -f "$CONFIG_FILE" ]] && command -v yq &>/dev/null; then
      cfg="$(yq -r '.review.confidence_threshold // ""' "$CONFIG_FILE" 2>/dev/null || true)"
      if [[ -n "$cfg" && "$cfg" != "null" ]]; then
        if ! review_confidence_threshold_valid "$cfg"; then
          echo "ERROR: review.confidence_threshold in ${CONFIG_FILE} must be an integer from 0 to 100, got: '${cfg}'" >&2
          return 1
        fi
        v="$cfg"
      fi
    fi
  fi
  printf '%s\n' "$((10#$v))"
}

# 観点 1 本の型付きレコードを集計する。
#   <cli> <perspective> <result-file> <records-file> <threshold> <tsv-out> <lowconf-out>
# records-file は typed_verdicts_extract の stdout（finding / none レコード）。
# tsv-out へ finding ごとの記録（ヘッダ付き）、lowconf-out へ低信頼の列挙行を書き、
# stdout へ「Critical Warning Suggestion Info 降格 低信頼」の件数を空白区切りで 1 行出す。
#
# 降格（ADR-065 決定 7）: failure_scenario=no の finding を 1 段下げる（Critical →
# Warning、Warning → Suggestion。Suggestion / Info はそのまま）。件数と Critical 判定は
# 降格後の重大度で数え、TSV の demoted_from に元の重大度を残す。
# 信頼度は Critical 判定に掛けない — 降格後も Critical の finding は低信頼でもブロック
# する（見落としより誤ブロック側へ倒す）。低信頼は「未確認」として別に列挙するだけ。
#
# finding の範囲は判定行から遡って、判定行より字下げの浅い最寄りの箇条書き（親の指摘行）
# まで（観点テンプレートは「指摘の行の直下に判定行を 1 行置く」形を要求している）。親が
# 無いときは直前の判定行・見出しまで。summary は親の指摘行（親が無ければ最寄りの行）から
# 行頭の引用・箇条書き記号を剥がして取り、タブは空白へ置き換える。テスト有効性のタグは
# この範囲の全行から探す（本文が折り返して判定行の直前にタグが無くても拾う）。
# TSV の列は cli / perspective / severity（降格後）/ failure_scenario / confidence / file /
# line / summary / demoted_from（降格したときの元の重大度。無ければ空）の順。
REVIEW_FINDINGS_TSV_HEADER="$(printf 'cli\tperspective\tseverity\tfailure_scenario\tconfidence\tfile\tline\tsummary\tdemoted_from')"

aggregate_typed_verdicts() {
  local cli="$1" persp="$2" src="$3" records="$4" thr="$5" tsv_out="$6" low_out="$7"
  local exc_thr="$REVIEW_TEST_VALIDITY_THRESHOLD"
  if [[ "$thr" -lt "$exc_thr" ]]; then
    exc_thr="$thr"
  fi
  printf '%s\n' "$REVIEW_FINDINGS_TSV_HEADER" > "$tsv_out" || return 1
  : > "$low_out" || return 1
  awk -F '\t' -v cli="$cli" -v persp="$persp" -v srcf="$src" -v thr="$thr" \
    -v exc_thr="$exc_thr" -v tsv="$tsv_out" -v low="$low_out" '
    function trim(s) { sub(/^[[:space:]]+/, "", s); sub(/[[:space:]]+$/, "", s); return s }
    function indent_of(l,    m) { match(l, /^[[:space:]]*/); return RLENGTH }
    function clean(l) {
      sub(/\r$/, "", l)
      l = trim(l)
      while (l ~ /^>/) sub(/^>[[:space:]]*/, "", l)
      sub(/^([-*+]|[0-9]+[.)])[[:space:]]+/, "", l)
      gsub(/\t/, " ", l)
      return trim(l)
    }
    # 判定行 n が属する finding の範囲を遡って決め、f_summary（summary 列）と f_tag（テスト
    # 有効性の 3 形のタグの有無）を置く。遡りは直前の判定行・見出しで止める。範囲の先頭
    # （finding の見出し行）は、判定行より字下げの浅い最寄りの箇条書き（親の指摘行）。親が
    # 無い（判定行が字下げされていない・指摘行と同じ深さ）ときは、判定行と同じ字下げの
    # 最寄りの箇条書き — それより上の同階層の箇条書き（前の finding の `- 理由:` 等）は
    # 別の finding なので範囲に入れない。タグは範囲（先頭行〜判定行の直前）の全行から探す
    # ので、本文が折り返して判定行の直前にタグが無くても拾い、別 finding のタグは拾わない。
    function scan_finding(n,    i, l, ind, ind_v, head, sib, near, top) {
      ind_v = indent_of(src[n]); head = 0; sib = 0; near = 0; f_tag = 0
      for (i = n - 1; i >= 1; i--) {
        l = src[i]
        sub(/\r$/, "", l)
        if (i in vline) break
        if (l ~ /^[[:space:]]*#/) break
        if (tolower(l) ~ /^[[:space:]>]*([-*+]|[0-9]+[.)])?[[:space:]]*[*_`]*verdict/) break
        if (l ~ /^[[:space:]]*$/) continue
        if (l ~ /^[[:space:]]*(```|~~~)/) continue
        if (!near) near = i
        if (l ~ /^[[:space:]]*([-*+]|[0-9]+[.)])[[:space:]]/) {
          ind = indent_of(l)
          if (ind < ind_v) { head = i; break }
          if (ind == ind_v && !sib) sib = i
        }
      }
      if (!head) head = sib
      top = head ? head : near
      f_summary = top ? clean(src[top]) : ""
      if (top) {
        for (i = top; i < n; i++) {
          if (src[i] ~ /\[TEST-VALIDITY:(unreached|coincidental|one-sided)\]/) { f_tag = 1; break }
        }
      }
    }
    function label(s) {
      if (s == "critical") return "Critical"
      if (s == "warning") return "Warning"
      if (s == "suggestion") return "Suggestion"
      return "Info"
    }
    BEGIN {
      OFS = "\t"
      while ((getline l < srcf) > 0) src[++nsrc] = l
      close(srcf)
    }
    { rec[NR] = $0; if ($1 == "finding" || $1 == "none") vline[$2] = 1 }
    END {
      nc = nw = nsg = ni = nd = nl = 0
      for (r = 1; r <= NR; r++) {
        split(rec[r], f, "\t")
        if (f[1] != "finding") continue
        sev = f[3]; fs = f[4]; conf = f[5] + 0; from = ""
        if (fs == "no") {
          if (sev == "critical") { from = sev; sev = "warning" }
          else if (sev == "warning") { from = sev; sev = "suggestion" }
        }
        scan_finding(f[2] + 0)
        summ = f_summary
        t = thr + 0
        if (persp == "code-review" && f_tag) t = exc_thr + 0
        if (sev == "critical") nc++
        else if (sev == "warning") nw++
        else if (sev == "suggestion") nsg++
        else ni++
        if (from != "") nd++
        print cli, persp, sev, fs, conf, f[6], f[7], summ, from >> tsv
        if (conf < t) {
          nl++
          pos = f[6]
          if (pos != "" && f[7] != "") pos = pos ":" f[7]
          line = "- " cli " / " persp " — " label(sev)
          if (from != "") line = line "（" label(from) " から降格）"
          line = line " / 信頼度 " conf "（閾値 " t "）"
          if (pos != "") line = line " / `" pos "`"
          if (summ != "") line = line " — " summ
          print line >> low
        }
      }
      printf "%d %d %d %d %d %d\n", nc, nw, nsg, ni, nd, nl
    }
  ' "$records"
}

# 型付き経路の fail-safe（ADR-065 決定 9 を集約側でも保つ）。書式の崩れた verdict 行が
# severity=critical を名乗るなら、有効な型付き行の降格・件数に関わらず Critical ありへ
# 倒す。判定式は複製しない — 有効な finding 行（レコードの行番号）を `- verdict: none` へ
# 置き換えた写しを共有パーサー critical_findings_present へ通す。写しには型付き行
# （none）が残るので散文の判定は効かず、有効な Critical も消えているので、rc0 になるのは
# 不採用行の fail-safe だけになる。
# rc0: 不採用の critical 行あり / rc1: なし / rc2: 判定不能（写しを作れない等）
typed_verdict_failsafe_critical() { # <result-file> <records-file> <scratch-file>
  local src="$1" records="$2" scratch="$3" rc=0
  awk -F '\t' '
    FNR == NR { if ($1 == "finding") drop[$2] = 1; next }
    (FNR in drop) { print "- verdict: none"; next }
    { print }
  ' "$records" "$src" > "$scratch" || return 2
  critical_findings_present "$scratch" 2>/dev/null || rc=$?
  case "$rc" in
    0 | 1) return "$rc" ;;
    *)     return 2 ;;
  esac
}

# 観点の「未完了」の理由。append_plan_sections が節へ未完了を名乗らせる判定と同じ順
# （委譲待ち → 結果ファイルの incomplete ヘッダ → スキップ → 結果なし）で見る。
# 空文字 = 未完了ではない。
review_task_incomplete_reason() { # <cli> <perspective>
  local cli="$1" persp="$2" result_file="${OUTPUT_DIR}/$1/$2.md"
  if delegated_task_pending "${cli}/${persp}"; then
    echo "ホストへ委譲したまま結果が未回収"
  elif [[ -f "$result_file" ]]; then
    if awk '/^$/ { exit } /^<!-- Status: incomplete -->$/ { found = 1 } END { exit found ? 0 : 1 }' "$result_file"; then
      # 本文の不受理は fail_cli_task が成果物へ載せた理由コードで名指しする（ADR-066。
      # 散文だけのレビューの拒否は、stderr だけでなくレポートからも読めるようにする）
      case "$(awk -F '`' '/^> Reason code: `[a-z-]*`$/ { print $2; exit }' "$result_file" 2>/dev/null)" in
        missing-review-body-prose) echo "結果の拒否: 散文の重大度行だけのレビュー（型付き判定行なし）" ;;
        missing-review-body)       echo "結果の拒否: 型付き判定行の無い出力" ;;
        review-body-unparsed)      echo "結果の拒否: 出力を解析できない（不正な UTF-8 など）" ;;
        *)                         echo "CLI の失敗・タイムアウト・結果の拒否（途中までの出力のみ）" ;;
      esac
    fi
  elif [[ -n "$(skipped_task_cause "${cli}/${persp}")" ]]; then
    echo "同じ CLI の先行失敗によりスキップ"
  else
    echo "結果なし（CLI が結果を書く前に失敗）"
  fi
}


# ── 委譲した実行のホストへの引き渡し ──
#
# **stdout へ出す唯一のブロック**。このスクリプトの進行表示・警告・診断はすべて stderr
# なので、委譲を指定したホストは stdout をそのまま読めばよい（Issue の案 1 の形）。
# 中身は各タスクの request レコード（アダプタが書いたもの）をそのまま連結したもので、
# ここで再構成はしない — 2 箇所で組み立てると、片方だけ鍵が増えた回に食い違う。
print_delegation_handoff() {
  [[ -n "$DELEGATED_TASKS" ]] || return 0
  local task cli persp req count=0
  for task in $DELEGATED_TASKS; do
    count=$((count + 1))
  done
  printf '%s\n' '<<<FF-DELEGATED-TASKS>>>'
  printf 'count=%s\n' "$count"
  printf 'task-type=%s\n' "$TASK_TYPE"
  printf 'output-dir=%s\n' "$OUTPUT_DIR"
  for task in $DELEGATED_TASKS; do
    cli="${task%%/*}"
    persp="${task#*/}"
    req="$(delegate_dir_for "$cli")/${persp}.request"
    printf '%s\n' '--- task ---'
    printf 'FF-REVIEW-DELEGATED: %s\n' "$(delegate_dir_for "$cli")/${persp}.prompt.md"
    if [[ -r "$req" ]]; then
      cat "$req"
    else
      # レコードが読めないのは想定外（直前にアダプタが書いている）。ブロックの形は
      # 保ったまま、欠落を機械可読の鍵で名乗る — 黙って短いブロックを返すと、
      # ホストは「委譲されなかった」と読む。
      printf 'cli=%s\nperspective=%s\nerror=request-record-unreadable:%s\n' "$cli" "$persp" "$req"
      echo "⚠️  Delegation request record is unreadable: ${req}" >&2
    fi
  done
  printf '%s\n' '<<<END-FF-DELEGATED-TASKS>>>'
}

# 読み込み完了の印（multi-agent.sh の読み込み部が照合する。最後の行に置く）
_ma_part_loaded="multi-agent-report-body.sh"
