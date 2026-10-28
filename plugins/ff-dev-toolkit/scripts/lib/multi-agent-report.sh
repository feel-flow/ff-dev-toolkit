#!/usr/bin/env bash
# multi-agent.sh の構成ファイル: 統合レポートの生成（review / explore / implement）。
#
# scripts/multi-agent.sh が開始時に 1 回だけ source する（直接実行しない）。読み込む順・
# 読めないときの停止・--resume の入力 identity への算入は multi-agent.sh の
# MULTI_AGENT_PARTS が正本。本文は分割前の multi-agent.sh の連続した行そのままで、
# トップレベルの初期化は構成ファイル同士で分割前と同じ順に走る（入口に残したタスク種別の既定より
# 後に走る点だけが違う）。ここへ set / trap / source を足さない。
# 末尾の _ma_part_loaded の行は読み込み完了の印（途中で切れたファイルを読み込み部が
# 見分ける）。bash 3.2 互換。分割の判断は ADR-075。
# pipefail-inherited: multi-agent.sh が set -euo pipefail の下で source する

# ── Generate Report (review) ──
# pair の実効レビュワー行（Issue `#699`）。pair 以外・未設定では 1 バイトも足さない
# ので、他モードのレポート書式は不変。severity 行文法（`- Critical: N` 等）にも
# ゼロ語文法にも一致しない `**Label:** value` 形なので、共有 severity パーサー
# （adapter-common.sh の _ff_severity_scan）の受理判定・CRITICAL_BLOCK 検出とは
# 干渉しない — 既存の Mode / Strategy 行と同じ形にしてあるのはそのため。
# 先頭に改行を置くのは、コマンド置換が末尾改行を落とすため（`$(...)` の直後に
# 改行を書くと、行が空のとき余分な空行が残る）。ヒアドキュメント側は
# `**Mode:** ...$(pair_reviewers_report_line)` と続けて書く。
pair_reviewers_report_line() {
  [[ -n "$PAIR_REVIEWERS_NOTE" ]] || return 0
  printf '\n**Reviewers:** %s' "$PAIR_REVIEWERS_NOTE"
}

generate_review_report() {
  local final_report_file="${OUTPUT_DIR}/integrated-report.md"
  local report_file
  report_file="$(umask 077; mktemp "${OUTPUT_DIR}/.report-building.XXXXXX")" || return 1

  echo "📝 Generating integrated review report..." >&2

  if ! cat > "$report_file" <<HEADER
# Multi-CLI Review — Integrated Report

**Generated:** $(date -u +"%Y-%m-%dT%H:%M:%SZ")
**Mode:** ${MODE}$(pair_reviewers_report_line)
**Strategy:** ${STRATEGY}
**Base Branch:** ${BASE_BRANCH}

---

HEADER
  then
    echo "ERROR: cannot initialize the integrated review report." >&2
    rm -f "$report_file" 2>/dev/null || true
    return 1
  fi

  local has_results=true
  append_plan_sections "$report_file" || has_results=false

  if [[ "$has_results" == "false" ]]; then
    if ! echo "(No review results found.)" >> "$report_file"; then
      echo "ERROR: cannot write the integrated review report." >&2
      rm -f "$report_file" 2>/dev/null || true
      return 1
    fi
  fi

  # CRITICAL_BLOCK は Critical の実所見があるときだけ出す（Issue `#272`）。マーカーは
  # pre-push ゲートが push をブロックする根拠なので、誤出力は誤ブロック、出力漏れは
  # ゲートの素通りになる。旧判定 `^\s*-\s*\[.*:.*\]` は重大度に関係なく [file:line]
  # 箇条書き全部に発火し、Important のみのレビューでも Critical と宣言していた。
  #
  # さらに観点別の段階化を掛ける（Issue `#645`）: 非ブロック観点（既定は
  # DEFAULT_CRITICAL_NONBLOCK_PERSPECTIVES、multi-agent-report-body.sh の resolve_critical_nonblock_perspectives
  # で上書き可）の Critical は CRITICAL_BLOCK を立てず、<!-- CRITICAL_NONBLOCK -->
  # の注記として出す。注記のマーカー名と本文に文字列 "CRITICAL_BLOCK" を含めては
  # ならない — 消費側ゲートの正規契約はマーカー全文の固定文字列一致
  # `grep -qF -- '<!-- CRITICAL_BLOCK -->'`（multi-cli-review-orchestration.md）だが、
  # 旧来のゲートには裸の部分一致 `grep -q "CRITICAL_BLOCK"` が残っており、含めると
  # ブロックしないはずの注記がブロックとして誤検知される。なお連結される各 result
  # file の**本文**が当該文字列を含む可能性（Verdict 語彙・マーカーの引用）は
  # 生成側では消せない — 引用ごと書き換えるとレビュー本文を改変することになる。
  # だからこそ消費側契約をマーカー全文一致に締めてある（裸の言及では発火しない）。
  #
  # 判定は連結後の統合レポートではなく**各 result file の本文**に掛ける — 連結後に
  # 掛けると (1) 1 本の CLI 出力の未閉フェンスが後続セクション全部を不可視にする
  # 越境マスク、(2) orchestrator 自身が書く節見出しの判定への混入、が構造的に生まれる。
  #
  # 判定本体は共有パーサー（adapters/adapter-common.sh の _ff_severity_scan、
  # Issue `#908`）の型付き判定行 — 抽出は typed_verdicts_extract、不採用行の fail-safe は
  # critical_findings_present — へ委譲する。アダプタ側の受理ゲート review_body_present と
  # **同一のフェンス追跡・同一の文法**を参照する。ここへ判定式を複製しないこと — 独立
  # 実装だった間は、片側へ語彙・境界を足すたびにズレて fail-open / 偽 BLOCK の両方向の
  # 非対称が再発した（Issue `#893` の 7 巡レビューで実測）。散文の重大度行（s1〜s4 /
  # c1〜c4）は ADR-066 以降、判定に使わない（診断だけ）。
  #
  # フェンスが閉じないまま本文が終わる場合は判定不能（rc=2）として安全側（マーカー
  # あり）へ倒す。判定を実行できない場合（rc=3: 不可読ファイル / awk 実行失敗）と、
  # 完了扱いの結果に型付き判定行が無い場合（rc=4: 根拠なし）も同様に安全側へ倒し、
  # 診断を stderr へ残す。検出力は tests/multi-agent-critical-marker/ が stub CLI の
  # 実走で固定する。
  local crit_entry crit_seen="" crit_file crit_rc crit_found crit_persp
  local crit_block_hits="" crit_nonblock_hits="" crit_nonblock_set
  # 判定不能（未閉フェンス / awk 失敗）は実所見と別のリストに持つ。マーカーの
  # 発火条件としては同格（安全側 = Critical あり）だが、レポート上で「実所見が
  # あった」と「本文を判定しきれなかった」を同じ文で報告すると、判定不能の観測が
  # stderr にしか残らず、INCOMPLETE と同型の「空振りを所見と読む」誤読を生む。
  local crit_block_unparse="" crit_nonblock_unparse="" crit_target
  local crit_block_retained="" crit_nonblock_retained="" state_block state_nonblock state_series
  # 型付き判定行の集計（ADR-065 の C3 追記。multi-agent-report-body.sh の resolve_review_confidence_threshold 付近の
  # コメントが正）。観点ごとに finding の記録（<cli>/<観点>.findings.tsv）を毎回作り直す —
  # 前回の実行・--resume の再利用観点の記録が今回の本文と食い違わないよう、プランの観点は
  # 判定の前に記録を消し、型付き経路で判定した観点だけ書き直す。
  local conf_thr typed_tmp typed_rc typed_counts typed_rows="" typed_incomplete="" typed_failsafe="" typed_overrode=""
  local typed_undecided="" typed_undecided_crit="" typed_nobasis="" typed_unfenced="" typed_unreadable=""
  local typed_unavailable="" tv_unavail
  local tv_cli tv_tsv tv_reason tv_c tv_w tv_s tv_i tv_d tv_l tv_fs_rc tv_exc_thr
  conf_thr="${REVIEW_CONFIDENCE_THRESHOLD:-}"
  if [[ -z "$conf_thr" ]]; then
    if ! conf_thr="$(resolve_review_confidence_threshold)"; then
      rm -f "$report_file" 2>/dev/null || true
      return 1
    fi
  fi
  tv_exc_thr="$REVIEW_TEST_VALIDITY_THRESHOLD"
  if [[ "$conf_thr" -lt "$tv_exc_thr" ]]; then
    tv_exc_thr="$conf_thr"
  fi
  if ! typed_tmp="$(mktemp -d "${TMPDIR:-/tmp}/ff-typed-verdicts.XXXXXX")" || [[ ! -d "$typed_tmp" ]]; then
    echo "ERROR: cannot create a scratch dir for the typed verdict aggregation." >&2
    rm -f "$report_file" 2>/dev/null || true
    return 1
  fi
  if ! : > "${typed_tmp}/lowconf"; then
    echo "ERROR: cannot write the typed verdict scratch file: ${typed_tmp}/lowconf" >&2
    rm -rf "$typed_tmp" 2>/dev/null || true
    rm -f "$report_file" 2>/dev/null || true
    return 1
  fi
  if [[ "$REVIEW_CRITICAL_NONBLOCK_RESOLVED" == true ]]; then
    crit_nonblock_set="$REVIEW_CRITICAL_NONBLOCK_SET"
  else
    crit_nonblock_set="$(resolve_critical_nonblock_perspectives)"
    warn_unknown_critical_nonblock "$crit_nonblock_set"
  fi
  while IFS= read -r crit_entry; do
    [[ -z "$crit_entry" ]] && continue
    if [[ " $crit_seen " == *" $crit_entry "* ]]; then continue; fi
    crit_seen="$crit_seen $crit_entry"
    crit_persp="${crit_entry#*:}"
    tv_cli="${crit_entry%%:*}"
    tv_tsv="${OUTPUT_DIR}/${tv_cli}/${crit_persp}.findings.tsv"
    if ! rm -f "$tv_tsv"; then
      echo "ERROR: cannot clear the previous findings record: ${tv_tsv}" >&2
      rm -rf "$typed_tmp" 2>/dev/null || true
      rm -f "$report_file" 2>/dev/null || true
      return 1
    fi
    # 主担当以外の利用不可は未完了の観点に数えず、1 行で別記する。
    # 前回の未解消 Critical の保持は下の task_left_perspective_unproven がそのまま効かせる
    # （FAILED_TASKS / SKIPPED_TASKS から外していないため）。
    tv_unavail="$(unavailable_cross_task_cause "${tv_cli}/${crit_persp}")"
    if [[ -n "$tv_unavail" ]]; then
      typed_unavailable="${typed_unavailable}- ${tv_cli} / ${crit_persp} — 主担当（${REVIEW_MAIN}）のみで完了（${tv_cli}: $(unavailable_cause_label_ja "$tv_unavail")）
"
      tv_reason=""
    else
      tv_reason="$(review_task_incomplete_reason "$tv_cli" "$crit_persp")"
    fi
    if [[ -n "$tv_reason" ]]; then
      typed_incomplete="${typed_incomplete}- ${tv_cli} / ${crit_persp} — ${tv_reason}
"
    fi
    # A failed/timeout/skipped rerun did not prove resolution. Preserve that
    # perspective's prior classification instead of judging incomplete output.
    if task_left_perspective_unproven "${crit_entry%%:*}" "$crit_persp"; then
      if list_contains "$PREVIOUS_UNRESOLVED_BLOCK" "$crit_persp"; then
        crit_block_retained="${crit_block_retained:+$crit_block_retained }$crit_persp"
        continue
      fi
      if list_contains "$PREVIOUS_UNRESOLVED_NONBLOCK" "$crit_persp"; then
        crit_nonblock_retained="${crit_nonblock_retained:+$crit_nonblock_retained }$crit_persp"
        continue
      fi
    fi
    # 委譲待ちの観点は、この実行の判定を出していない。結果パスにファイルがあっても
    # それは受理ゲート（プロンプト digest / レビュー本文）を 1 つも通っていない —
    # 委譲タスクは CLI を起動しないので数ミリ秒で終わり、他レーンが走っている数分の
    # あいだにホストがそこへ書けば -f は真になる。レポート本文側は同じ理由で
    # delegated_task_pending を -f より前に置いてあり、こちらだけ読むと 2 つの消費者が
    # 同じパスについて別の判断をする。
    if delegated_task_pending "${crit_entry%%:*}/${crit_entry#*:}"; then
      continue
    fi
    # 利用不可で許容した観点の成果物はサルベージした stderr で、判定材料ではない
    # （本文を判定すると、エコーされたプロンプトのフェンス崩れ等で安全側へ倒れうる）。
    [[ -z "$tv_unavail" ]] || continue
    crit_file="${OUTPUT_DIR}/${crit_entry%%:*}/${crit_entry#*:}.md"
    [[ -f "$crit_file" ]] || continue
    # 型付き経路: 有効な判定行が 1 行でもあれば、降格後の重大度と不採用行の fail-safe で
    # 決める。判定行が無い（rc1）本文は散文から判定しない（ADR-066）— 未完了の観点は
    # 判定を出さず（未確認 › 未完了の観点で名指し済み）、完了扱いの結果は根拠なしとして
    # 安全側へ倒す。未閉フェンス（rc2）・判定不能（rc3）は完了・未完了を問わず従来どおり
    # 安全側へ倒し、レポートでは rc ごとに別の文で名指しする（どれも「散文で判定した」
    # とは書かない）。
    typed_rc=0
    typed_verdicts_extract "$crit_file" >"${typed_tmp}/records" 2>"${typed_tmp}/diag" || typed_rc=$?
    if [[ "$typed_rc" -eq 0 ]]; then
      cat "${typed_tmp}/diag" >&2 2>/dev/null || true
      if ! typed_counts="$(aggregate_typed_verdicts "$tv_cli" "$crit_persp" "$crit_file" \
          "${typed_tmp}/records" "$conf_thr" "${typed_tmp}/tsv" "${typed_tmp}/low1")" \
        || ! cat "${typed_tmp}/low1" >> "${typed_tmp}/lowconf" \
        || ! mv "${typed_tmp}/tsv" "$tv_tsv"; then
        echo "ERROR: cannot aggregate the typed verdict lines of ${crit_file} into ${tv_tsv}." >&2
        rm -rf "$typed_tmp" 2>/dev/null || true
        rm -f "$report_file" 2>/dev/null || true
        return 1
      fi
      read -r tv_c tv_w tv_s tv_i tv_d tv_l <<< "$typed_counts"
      typed_rows="${typed_rows}| ${tv_cli} / ${crit_persp} | ${tv_c} | ${tv_w} | ${tv_s} | ${tv_i} | ${tv_d} | ${tv_l} |
"
      tv_fs_rc=0
      typed_verdict_failsafe_critical "$crit_file" "${typed_tmp}/records" "${typed_tmp}/scratch" || tv_fs_rc=$?
      if [[ "$tv_fs_rc" -eq 0 ]]; then
        echo "⚠️ typed verdict: ${crit_file} has a malformed verdict line naming severity=critical — counted as critical (fail-safe)" >&2
        typed_failsafe="${typed_failsafe:+${typed_failsafe} }${tv_cli}/${crit_persp}"
      fi
      if [[ "$tv_c" -gt 0 || "$tv_fs_rc" -eq 0 ]]; then
        crit_rc=0
      elif [[ "$tv_fs_rc" -eq 1 ]]; then
        crit_rc=1
      else
        crit_rc=3
      fi
      # 散文の Critical を型付き行が覆した観点（ADR-065 決定 6）。判定は共有パーサーの
      # 抽出診断（検出モードと同じ条件で出る 1 行）に任せ、ここへ判定式を複製しない。
      # stderr は上の diag 中継で出ているので、レポートにも 1 行残す（stderr だけだと
      # レポート経由の読み手に届かない）
      if grep -qF 'prose Critical finding overridden by typed verdict lines' "${typed_tmp}/diag" 2>/dev/null; then
        typed_overrode="${typed_overrode:+${typed_overrode} }${tv_cli}/${crit_persp}"
      fi
    elif [[ "$typed_rc" -eq 1 && -n "$tv_reason" ]]; then
      # 未完了の観点で判定行が無い: 本文（拒否した散文・途中までの出力）から Critical を
      # 決めない。散文の Critical があった回は数えずに名指しだけする（診断は共有パーサー）。
      # ただし書式の崩れた verdict 行が severity=critical を名乗る回は、ADR-065 決定 9 の
      # fail-safe を未完了の観点でも保つ — 不採用行しか無い本文は受理されない（= 必ずここへ
      # 来る）ので、ここで見ないと崩れた Critical 宣言がどこでも数えられない。判定式は複製
      # せず共有パーサーの検出を使う（判定行なしは rc4、不採用の critical 行があれば rc0）
      cat "${typed_tmp}/diag" >&2 2>/dev/null || true
      tv_fs_rc=0
      critical_findings_present "$crit_file" 2>/dev/null || tv_fs_rc=$?
      if [[ "$tv_fs_rc" -eq 0 ]]; then
        echo "⚠️ typed verdict: ${crit_file} has a malformed verdict line naming severity=critical — counted as critical (fail-safe)" >&2
        typed_failsafe="${typed_failsafe:+${typed_failsafe} }${tv_cli}/${crit_persp}"
        crit_rc=0
      else
        typed_undecided="${typed_undecided:+${typed_undecided} }${tv_cli}/${crit_persp}"
        if grep -qF 'prose Critical finding in a body without typed verdict lines' "${typed_tmp}/diag" 2>/dev/null; then
          typed_undecided_crit="${typed_undecided_crit:+${typed_undecided_crit} }${tv_cli}/${crit_persp}"
        fi
        continue
      fi
    else
      cat "${typed_tmp}/diag" >&2 2>/dev/null || true
      case "$typed_rc" in
        1)
          typed_nobasis="${typed_nobasis:+${typed_nobasis} }${tv_cli}/${crit_persp}"
          echo "⚠️ CRITICAL_BLOCK 判定: ${crit_file} は完了扱いの結果なのに有効な型付き判定行が 1 行も無く、判定の根拠がありません（散文の重大度行は読みません — ADR-066）。根拠なしを Critical なしとして通さないため、安全側（Critical あり）に倒します" >&2
          crit_rc=4 ;;
        2)
          typed_unfenced="${typed_unfenced:+${typed_unfenced} }${tv_cli}/${crit_persp}"
          crit_rc=2 ;;
        *)
          typed_unreadable="${typed_unreadable:+${typed_unreadable} }${tv_cli}/${crit_persp}"
          crit_rc=3 ;;
      esac
    fi
    # 判定不能（rc=2: 未閉フェンス / rc=3: 不可読ファイル・awk 失敗 / rc=4: 完了扱いの
    # 結果に判定行が無い）は「Critical あり」へ倒す。
    # 倒した先の重さ（ブロック / 非ブロック）はその観点の段階に従う — 非ブロック
    # 観点は Critical が実在してもブロックしない契約なので、判定不能をブロックまで
    # 格上げすると安全側を越えて旧挙動の誤ブロックが戻る。
    crit_found=""
    case "$crit_rc" in
      0) crit_found=real ;;
      1) : ;;
      2)
        echo "⚠️ CRITICAL_BLOCK 判定: ${crit_file} のコードフェンスが閉じておらず本文を判定しきれません。判定不能を Critical なしとして通さないため、安全側（Critical あり）に倒します" >&2
        crit_found=unparse ;;
      4)
        # 診断は上の分岐で出した（判定行なし）
        crit_found=unparse ;;
      *)
        echo "⚠️ CRITICAL_BLOCK 判定を実行できませんでした（判定 rc=${crit_rc}: ${crit_file} — 不可読ファイルまたは判定器の実行失敗）。判定不能を Critical なしとして通さないため、安全側（Critical あり）に倒します" >&2
        crit_found=unparse ;;
    esac
    if [[ -n "$crit_found" ]]; then
      if [[ " ${crit_nonblock_set} " == *" ${crit_persp} "* ]]; then
        crit_target="nonblock"
      else
        crit_target="block"
      fi
      case "${crit_target}:${crit_found}" in
        block:real)
          [[ " ${crit_block_hits} " == *" ${crit_persp} "* ]] || crit_block_hits="${crit_block_hits:+${crit_block_hits} }${crit_persp}" ;;
        block:unparse)
          [[ " ${crit_block_unparse} " == *" ${crit_persp} "* ]] || crit_block_unparse="${crit_block_unparse:+${crit_block_unparse} }${crit_persp}" ;;
        nonblock:real)
          [[ " ${crit_nonblock_hits} " == *" ${crit_persp} "* ]] || crit_nonblock_hits="${crit_nonblock_hits:+${crit_nonblock_hits} }${crit_persp}" ;;
        nonblock:unparse)
          [[ " ${crit_nonblock_unparse} " == *" ${crit_persp} "* ]] || crit_nonblock_unparse="${crit_nonblock_unparse:+${crit_nonblock_unparse} }${crit_persp}" ;;
      esac
    fi
  done <<< "$EXECUTION_PLAN"
  # 集計節はマーカーより**前**に置く — 未解消 Critical のガードはレポート末尾 12 行
  # （previous_report_has_critical_marker）だけからマーカーを読むので、後ろへ足すと
  # マーカーが窓から押し出される。節の文言には未完了検査の語（大文字の英単語）も
  # マーカー名も書かない — 消費側ゲートはレポート全体への部分一致でそれらを数える
  # （multi-cli-review-orchestration.md の pre-push 例）。
  if ! {
    echo ""
    echo "## 型付き判定の集計"
    echo ""
    echo "型付き判定行（\`verdict:\`）を持つ観点は、その行だけで重大度を数える。\`failure_scenario=no\` の finding は 1 段降格（Critical → Warning、Warning → Suggestion）した後の重大度で数え、Critical の判定もこの重大度で行う。信頼度の閾値は ${conf_thr}（code-review のテスト有効性の 3 形のタグ \`[TEST-VALIDITY:unreached|coincidental|one-sided]\` の指摘は ${tv_exc_thr}）。"
    echo ""
    if [[ -n "$typed_rows" ]]; then
      echo "| 観点 | Critical | Warning | Suggestion | Info | うち降格 | うち低信頼 |"
      echo "| --- | --- | --- | --- | --- | --- | --- |"
      printf '%s' "$typed_rows"
      echo ""
      echo "finding ごとの記録: 出力先の \`<cli>/<観点>.findings.tsv\`（列: cli / perspective / severity / failure_scenario / confidence / file / line / summary / demoted_from）"
    else
      echo "型付き判定行を持つ観点はない。"
    fi
    if [[ -n "$typed_failsafe" ]]; then
      echo ""
      echo "書式の崩れた判定行が severity=critical を名乗っていたため、表の件数に関わらず Critical ありとして扱った観点（fail-safe）: ${typed_failsafe// /, }"
    fi
    if [[ -n "$typed_overrode" ]]; then
      echo ""
      echo "散文の重大度行では Critical ありと読めたが、型付き判定行の Critical が 0 件のため型付き行で判定した観点（散文側の Critical 指摘を判定行へ書き漏らしていないか確認する）: ${typed_overrode// /, }"
    fi
    if [[ -n "$typed_undecided" ]]; then
      echo ""
      echo "型付き判定行が無いため本文から重大度を判定しなかった未完了の観点（散文の重大度行は読まない。下の「未確認 › 未完了の観点」を参照）: ${typed_undecided// /, }"
    fi
    if [[ -n "$typed_undecided_crit" ]]; then
      echo ""
      echo "そのうち、拒否・中断した本文の散文に Critical の記述があった観点（判定には数えていない。再実行して型付き判定行で確かめる）: ${typed_undecided_crit// /, }"
    fi
    if [[ -n "$typed_nobasis" ]]; then
      echo ""
      echo "完了扱いの結果なのに型付き判定行が 1 行も無く、判定の根拠が無いため安全側（Critical あり）へ倒した観点（旧版で受理された結果の再利用など。再実行する）: ${typed_nobasis// /, }"
    fi
    if [[ -n "$typed_unfenced" ]]; then
      echo ""
      echo "コードフェンスが閉じておらず型付き判定行を読み切れないため安全側（Critical あり）へ倒した観点: ${typed_unfenced// /, }"
    fi
    if [[ -n "$typed_unreadable" ]]; then
      echo ""
      echo "結果を判定できなかった（不可読・判定器の実行失敗）ため安全側（Critical あり）へ倒した観点: ${typed_unreadable// /, }"
    fi
    echo ""
    echo "### 未確認 › 低信頼の指摘"
    echo ""
    if [[ -s "${typed_tmp}/lowconf" ]]; then
      echo "信頼度が閾値未満の finding。報告から落とさず、「指摘なし」とも読まない — 対応の前に裏取りする。"
      echo ""
      cat "${typed_tmp}/lowconf"
    else
      echo "なし"
    fi
    echo ""
    echo "### 未確認 › 未完了の観点"
    echo ""
    if [[ -n "$typed_incomplete" ]]; then
      echo "レビューを完了していない観点。この観点の沈黙は「指摘なし」ではなく未確認。"
      echo ""
      printf '%s' "$typed_incomplete"
    else
      echo "なし"
    fi
    if [[ -n "$typed_unavailable" ]]; then
      echo ""
      echo "### 主担当のみで完了した観点（2 本目の CLI が利用不可）"
      echo ""
      printf '%s' "$typed_unavailable"
    fi
  } >> "$report_file"; then
    echo "ERROR: cannot write the typed verdict aggregation to the integrated review report." >&2
    rm -rf "$typed_tmp" 2>/dev/null || true
    rm -f "$report_file" 2>/dev/null || true
    return 1
  fi
  rm -rf "$typed_tmp" 2>/dev/null || true
  if [[ -n "$crit_block_hits" || -n "$crit_block_unparse" || -n "$crit_block_retained" ]]; then
    if ! {
      echo ""
      echo "<!-- CRITICAL_BLOCK -->"
      if [[ -n "$crit_block_hits" ]]; then
        echo "Critical issues detected (${crit_block_hits// /, }). Review before proceeding."
      fi
      if [[ -n "$crit_block_unparse" ]]; then
        echo "Unparseable result treated as critical (${crit_block_unparse// /, }): the body could not be fully judged — see the run diagnostics."
      fi
      if [[ -n "$crit_block_retained" ]]; then
        echo "Previous Critical remains unresolved because its rerun produced no verdict — it failed, was skipped, or is still delegated to the host (${crit_block_retained// /, })."
      fi
    } >> "$report_file"; then
      echo "ERROR: cannot write blocking Critical state to the integrated review report." >&2
      rm -f "$report_file" 2>/dev/null || true
      return 1
    fi
  fi
  if [[ -n "$crit_nonblock_hits" || -n "$crit_nonblock_unparse" || -n "$crit_nonblock_retained" ]]; then
    # 本文に "CRITICAL_BLOCK" を部分一致で含めないこと（上の段階化コメント参照）。
    if ! {
      echo ""
      echo "<!-- CRITICAL_NONBLOCK -->"
      if [[ -n "$crit_nonblock_hits" ]]; then
        echo "Critical findings in non-blocking perspectives (${crit_nonblock_hits// /, })."
      fi
      if [[ -n "$crit_nonblock_unparse" ]]; then
        echo "Unparseable result treated as critical, in non-blocking perspectives (${crit_nonblock_unparse// /, })."
      fi
      if [[ -n "$crit_nonblock_retained" ]]; then
        echo "Previous non-blocking Critical remains unresolved because its rerun produced no verdict — it failed, was skipped, or is still delegated to the host (${crit_nonblock_retained// /, })."
      fi
      echo "Fix them per the review response policy; on their own they do not re-trigger the full gate."
    } >> "$report_file"; then
      echo "ERROR: cannot write non-blocking Critical state to the integrated review report." >&2
      rm -f "$report_file" 2>/dev/null || true
      return 1
    fi
  fi

  # Machine-readable final line for the next partial run. It is intentionally
  # unsigned and minimal: the guard prevents accidental omission, not hostile
  # report tampering. Perspective names are validated before they are consumed.
  state_block="${crit_block_hits}${crit_block_hits:+ }${crit_block_unparse}${crit_block_unparse:+ }${crit_block_retained}"
  state_nonblock="${crit_nonblock_hits}${crit_nonblock_hits:+ }${crit_nonblock_unparse}${crit_nonblock_unparse:+ }${crit_nonblock_retained}"
  state_block="${state_block% }"
  state_nonblock="${state_nonblock% }"
  state_series="$(current_review_series_id)" || {
    echo "ERROR: cannot identify the current review series for the report." >&2
    case "$(review_series_failure_reason)" in
      repo-root)       echo "       The project root is gone or unreadable: ${REPO_ROOT}." >&2 ;;
      git-error)       echo "       git cannot read HEAD here — this run is not inside a git worktree, or .git/HEAD is corrupt (the two are indistinguishable from git)." >&2 ;;
      # 理由を読めなかった回（記録に失敗した / 別実行の残骸だった）。原因は名乗れないが、
      # 復帰手段まで消すと利用者に次の一手が残らない。ガード側の既定アームと同じ文言を出す。
      *)               echo "       Run from inside the repository worktree, with the project root still present and HEAD resolvable, then retry." >&2 ;;
    esac
    rm -f "$report_file" 2>/dev/null || true
    return 1
  }
  if ! printf '<!-- MULTI_CLI_UNRESOLVED_CRITICAL series:%s block:%s nonblock:%s -->\n' \
    "$state_series" "${state_block:--}" "${state_nonblock:--}" >> "$report_file"; then
    echo "ERROR: cannot persist unresolved Critical state in the integrated report." >&2
    rm -f "$report_file" 2>/dev/null || true
    return 1
  fi

  if ! output_artifact copy integrated-report.md "${report_file#"$OUTPUT_DIR"/}"; then
    echo "ERROR: cannot publish the completed integrated review report." >&2
    rm -f "$report_file" 2>/dev/null || true
    return 1
  fi
  rm -f "$report_file" || return 1

  echo "📄 Report: ${final_report_file}" >&2
}

# ── Generate Report (explore) ──
generate_explore_report() {
  local report_file
  report_file="$(umask 077; mktemp "${OUTPUT_DIR}/.report-building.XXXXXX")" || return 1

  echo "📝 Generating integrated explore report..." >&2

  cat > "$report_file" <<HEADER
# Multi-CLI Explore — Integrated Report

**Generated:** $(date -u +"%Y-%m-%dT%H:%M:%SZ")
**Description:** ${DESCRIPTION}
**Mode:** ${MODE}
**Strategy:** ${STRATEGY}

---

HEADER

  local has_results=true
  append_plan_sections "$report_file" || has_results=false

  if [[ "$has_results" == "false" ]]; then
    echo "(No explore results found.)" >> "$report_file"
  fi

  output_artifact copy integrated-report.md "${report_file#"$OUTPUT_DIR"/}" || { rm -f "$report_file"; return 1; }
  rm -f "$report_file" || return 1
  echo "📄 Report: ${OUTPUT_DIR}/integrated-report.md" >&2
}

# ── Generate Report (implement) ──
generate_implement_report() {
  local report_file
  report_file="$(umask 077; mktemp "${OUTPUT_DIR}/.report-building.XXXXXX")" || return 1

  echo "📝 Generating integrated implement report..." >&2

  cat > "$report_file" <<HEADER
# Multi-CLI Implement — Integrated Report

**Generated:** $(date -u +"%Y-%m-%dT%H:%M:%SZ")
**Description:** ${DESCRIPTION}
**Mode:** ${MODE}
**Strategy:** ${STRATEGY}

---

⚠️ **Generated files are in the staging directory, not the working tree.** Review before applying.

Staging (per task): \`${OUTPUT_DIR}/<cli>/files/<perspective>/\` — each section below
names its own path and the number of files actually found there.

Only the tasks in **this** run's plan had their staging cleared beforehand. If you
narrowed the run (\`--cli\` / \`--perspective\`), other tasks' \`files/\` directories may
still hold output from an earlier run — read the sections below, not the whole tree.
If any such leftovers exist, a "Not part of this run" list naming them appears
below (and on stderr); they are left untouched and are NOT this run's output.

---

HEADER

  local has_results=true
  append_plan_sections "$report_file" || has_results=false

  if [[ "$has_results" == "false" ]]; then
    echo "(No implement results found.)" >> "$report_file"
  fi

  output_artifact copy integrated-report.md "${report_file#"$OUTPUT_DIR"/}" || { rm -f "$report_file"; return 1; }
  rm -f "$report_file" || return 1
  echo "📄 Report: ${OUTPUT_DIR}/integrated-report.md" >&2
}

# ── Generate Report (dispatcher) ──
generate_report() {
  # Reject a plan with unsafe path segments before any builder reads from it.
  validate_execution_plan || return 1
  case "$TASK_TYPE" in
    review)    generate_review_report ;;
    explore)   generate_explore_report ;;
    implement) generate_implement_report ;;
  esac
}

# 読み込み完了の印（multi-agent.sh の読み込み部が照合する。最後の行に置く）
_ma_part_loaded="multi-agent-report.sh"
