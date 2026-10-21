#!/usr/bin/env bash
# multi-agent.sh の構成ファイル: 今回の出力の掃除・プラン外の結果の隔離・resume のキャッシュ・出力ディレクトリのロック・--fresh の退避。
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

# ── Clear This Run's Planned Outputs ──
# The report reads ${cli}/${perspective}.md for each plan entry; adapters only
# (over)write that file on success, leaving a prior run's file in place on
# failure/timeout. Deleting exactly this run's own targets up front means a task
# that produces no output leaves NO stale same-name file to be mis-reported as
# current — instead the report surfaces it as "no output". Scoped to
# the plan's own (cli, perspective) targets only; nothing else on disk (other
# CLIs, other perspectives, unrelated user files) is DELETED here. Callers run
# validate_execution_plan first, so every token here is already a safe segment.
# 「消さない」だけでは、観点を絞った実行のあとに前回結果が同じディレクトリへ残って
# 今回の結果と読まれる（Issue `#537` / `#654`）。その分は削除ではなく移動で塞ぐ —
# 直後に走る quarantine_unplanned_outputs が、今回のプラン外の**自筆の**結果を
# <cli>/previous/ へ退避する。利用者のファイルは移動対象にもしない。
#
# implement の staging（Issue `#392`）も同じ理由で消す。レポートだけ消して生成物を
# 残すと、今回何も書かなかった実行のあとに前回の生成物がそのまま残り、「staging に
# ある = 今回の成果」という読み方が静かに嘘になる — レポートについて上で塞いだ
# 失敗と同型。
#
# 削除の失敗は握り潰さない。rm の rc を捨てると、消せなかった前回の生成物が
# 今回の成果としてレポートに案内されたまま exit 0 で終わる（実測で再現した形）。
# 痕跡は rm 自身の stderr 1 行だけで、並列実行では他タスクの出力に紛れる。
clear_planned_outputs() {
  [[ -n "${OUTPUT_DIR:-}" ]] || return 0
  local entry cli_name persp_name staging_dir cli_dir
  # 統合レポートは通常ここで消す。generate_report は成功時にしか書かないので、
  # 「タスクは走ったがレポート生成まで到達しなかった」実行のあとに無関係な前回結果を
  # 残さないためである。ただし未解消 Critical のレポートは、次回ガードが読む唯一の
  # 永続状態でもある。setup failure や事後 revision guard がそれを消すと次回の省略を
  # 許してしまうため、新しい review report が置き換えるまで保持する。
  if [[ "$PRESERVE_PREVIOUS_CRITICAL_REPORT" != "true" ]]; then
    if ! rm -f "${OUTPUT_DIR}/integrated-report.md"; then
      echo "ERROR: cannot clear the previous integrated report: ${OUTPUT_DIR}/integrated-report.md" >&2
      return 1
    fi
  fi
  # .fixed-diff はこの関数より前に capture_baseline_and_fix_diff が現在入力で上書きする。
  # resume identity はその内容 hash を使うため、ここで消してはならない。
  while IFS= read -r entry; do
    [[ -z "$entry" ]] && continue
    cli_name="${entry%%:*}"
    persp_name="${entry#*:}"
    # <cli> が symlink だと rm -f はリンクを辿り、指し先ディレクトリ内の同名ファイル
    # （出力ディレクトリの外でありうる）を消す — OUTPUT_DIR 自体は物理解決済みでも
    # 配下コンポーネントは別（Issue `#722`）。execute_tasks では Phase 1 の
    # validate_planned_result_dirs が先に同じ検査で中断するが、削除の実行点として
    # ここでも自前で検査し、検査した物理パスに対して消す（clear_staging_dir と同じ
    # 「検査したものと消すものを一致させる」形。ヘルパも既存の resolve_expected_dir
    # を再利用する）。
    cli_dir="${OUTPUT_DIR}/${cli_name}"
    if [[ -d "$cli_dir" ]]; then
      cli_dir="$(resolve_expected_dir "$cli_dir" "the result dir for ${cli_name}")" || {
        # ループ途中の中断は「先行エントリは削除済み・以降は未削除」の半端な状態で
        # 抜ける（E2E では Phase 1 の validate が先に止めるため通常は到達しない）。
        # 到達したときに読み手が状態を推測しなくて済むよう 1 行残す。
        echo "       Some planned results may already be cleared before this abort." >&2
        return 1
      }
    elif [[ -e "$cli_dir" || -L "$cli_dir" ]]; then
      # 通常ファイル・dangling symlink は resolve できず [[ -d ]] も偽になるが、
      # 素通しすると rm -f が「何も消せないまま rc=0」で成功に見える。削除の実行点
      # としても validate_result_dir_paths と同じ fail-loud に揃える。
      echo "ERROR: the result path for ${cli_name} exists but is not a directory: ${cli_dir}" >&2
      echo "       Results are written under it, so this run cannot proceed." >&2
      return 1
    fi
    if ! rm -f "${cli_dir}/${persp_name}.md"; then
      echo "ERROR: cannot clear previous result: ${cli_dir}/${persp_name}.md" >&2
      return 1
    fi
    # 結果から導く finding の記録（review の型付き判定の集計が書く）も同じ理由で消す。
    # レポート生成まで到達しなかった実行のあとに、前回の記録が今回のものとして残らない。
    if ! rm -f "${cli_dir}/${persp_name}.findings.tsv"; then
      echo "ERROR: cannot clear previous findings record: ${cli_dir}/${persp_name}.findings.tsv" >&2
      return 1
    fi
    if [[ "${TASK_TYPE:-review}" == "implement" ]]; then
      staging_dir="$(staging_dir_for "$cli_name" "$persp_name")"
      clear_staging_dir "$staging_dir" "the staging dir for ${cli_name}/${persp_name}" || return 1
    fi
  done <<< "$EXECUTION_PLAN"
}

clear_previous_integrated_report() {
  [[ -n "${OUTPUT_DIR:-}" ]] || return 0
  if [[ "$PRESERVE_PREVIOUS_CRITICAL_REPORT" == "true" ]]; then
    return 0
  fi
  if ! rm -f "${OUTPUT_DIR}/integrated-report.md"; then
    echo "ERROR: cannot clear the previous integrated report: ${OUTPUT_DIR}/integrated-report.md" >&2
    return 1
  fi
}

# ── Quarantine Previous Runs' Unplanned Results（Issue `#537` / `#654`） ──
#
# clear_planned_outputs が消すのは**今回のプランが書く先**だけなので、観点セットを
# 絞った実行のあとには前回実行で書かれた別観点のファイルが同じディレクトリに残る。
# integrated-report.md はプランを反復するので混ざらないが、`ls .review-results/<cli>/`
# や個別ファイルを直接読む消費者（人間・エージェント）には現行結果と区別がつかない。
# 実運用で 2 度、数日前の別 PR への Critical 指摘を今回の diff への指摘として読み
# 始めるところだった（どちらもファイル先頭の `Generated` 時刻に気付いて回避した =
# 能動的に確認しない限り気付けない状態だった）。
#
# 削除ではなく `<cli>/previous/` への**退避**にするのは、clear_planned_outputs が
# 宣言している「プランの対象以外はディスク上の何にも触れない」を壊さないため
# （`rm -rf <cli>/` は利用者がそこへ置いた無関係なファイルまで消す）。
#
# 動かすのは **orchestrator 自身が書いた結果ファイルだけ**（write_output の固定
# 1 行目マーカーで判定する）。利用者が同じディレクトリへ置いた `.md` は退避しない
# — 退避物は次の実行で捨てられるので、他人のファイルを退避すると「削除ではない」
# という上の根拠が 1 実行遅れで嘘になる。マーカーの無い `.md` は動かさずに名指しする。
#
# 対象は今回のプランに載っている CLI のディレクトリ**だけ**、その直下の `*.md`
# **だけ**。プラン外の CLI のディレクトリ、`files/`（implement の staging）、
# `.md` 以外のファイルには触れない（触れない代わりに、結果ファイルを持つプラン外
# ディレクトリは report_unplanned_result_dirs が、プラン外タスクの staging 残骸は
# report_unplanned_staging_dirs が名指しする）。
#
# `previous/` は毎回作り直す（追記しない）。世代を溜めると previous/ 自体が
# 「いつの実行のものか分からない」第二の stale になり、本 Issue と同じ誤読を
# 一段深いところで再現する。previous/ はアーカイブではなく「直前の実行が
# 押し出した結果」の置き場で、次にその CLI を含む実行が走った時点で捨てる。

# write_output（adapters/adapter-common.sh）が全結果ファイルの 1 行目へ必ず書く
# マーカーの形。ここを変えるなら write_output と同時に変えること（退避対象の判定が
# 静かに全外れして、前回結果が今回の結果として残る形の退行になる）。
# ワイルドカードが受け持つのは task_label（Review / Explore / Implement）1 語ぶんだけ
# — その語に ` Result -->` は現れないので、3 タスクすべてを取りこぼさず、
# かつ本文の任意行を誤って 1 行目扱いすることもない。
is_orchestrator_result() { # <file>
  local path="$1" first=""
  # `read` の rc は捨てる — 改行で終わらない 1 行ファイルは EOF で 1 を返すが、
  # 読めた内容は正しい。読めなければ first は空のままで下の照合が偽になる。
  IFS= read -r first < "$path" 2>/dev/null || true
  [[ "$first" == '<!-- Multi-CLI '*' Result -->' ]]
}

# 解決後の物理パスが**渡されたパスそのもの**であることを確認して、その物理パスを返す。
# 呼び出し側は OUTPUT_DIR（既に pwd -P 済み）から組み立てたパスを渡すので、実体の
# ディレクトリなら解決結果は必ず一致する。一致しない = 途中に symlink があるという
# ことで、そのときは触らない。
#
# 「OUTPUT_DIR 配下か」だけを見ないのは、配下判定が 2 つの穴を通すため:
#   - <cli> が出力先の**内側**を指す symlink（例 codex-cli -> ./claude-code）だと配下
#     判定を通るが、2 つの CLI 名が同じ実ディレクトリを共有し、同じ場所から退避しつつ
#     「今回のプラン外」と名指しする矛盾した実行になる
#   - 文字列 prefix 判定は途中の symlink を見抜けない（clear_staging_dir と同じ理由）
# 検査したものと操作するものを一致させるため、呼び出し側は返り値の物理パスを使う。
#
# 前提（呼び出し側の責務）: 渡すパスの**接頭部は既に物理**であること。現在の呼び出しは
# すべて OUTPUT_DIR（execute_tasks が pwd -P 済み）から組み立てている。論理パスを
# 渡すと、symlink でないディレクトリでも不一致になり「symlink だ」と誤って中断する。
# 第 3 引数は**内向き**（解決先が OUTPUT_DIR 配下）のときに出す 1 行の説明。既定は
# 結果ディレクトリ／退避先の話なので、staging のように壊れ方が違う呼び出し（Issue `#1120`）
# は自分の言葉で上書きする。外向きの説明は呼び出し側によらず同じ（出力先の外へ届く）
# なので共有のままにする。
resolve_expected_dir() { # <path> <label> [inward-note]
  local path="$1" label="$2" inward_note="${3:-}" resolved
  if ! resolved="$(cd "$path" && pwd -P)"; then
    echo "ERROR: cannot resolve ${label}: ${path}" >&2
    return 1
  fi
  if [[ "$resolved" != "$path" ]]; then
    echo "ERROR: ${label} is a symlink to another location — refusing to touch it." >&2
    echo "       path:     ${path}" >&2
    echo "       resolves: ${resolved}" >&2
    case "$resolved" in
      "$OUTPUT_DIR"/*)
        if [[ -n "$inward_note" ]]; then
          echo "       ${inward_note}" >&2
        else
          echo "       Results are keyed by CLI name; two names sharing one directory would" >&2
          echo "       quarantine from a directory this run also reports as not its own." >&2
        fi
        ;;
      *)
        echo "       output:   ${OUTPUT_DIR}" >&2
        echo "       Moving or deleting through it would reach outside the output dir." >&2
        ;;
    esac
    return 1
  fi
  printf '%s\n' "$resolved"
}

# ── Phase 1: 検査（最初の破壊操作より前に一括で） ──
# resume の書き戻し（restore_cached_result の mkdir -p + cp）も clear_planned_outputs
# の rm -f も `${OUTPUT_DIR}/<cli>/` を素通りするので、<cli> が外向き symlink だと
# **退避処理へ到達する前に**外部へ書き、外部を消してしまう。したがって解決検査は
# 退避の中ではなく、プラン上の全 CLI について execute_tasks の破壊操作より前で行う。
# 一括にするもう 1 つの理由: CLI ごとに検査していると「A は退避済み・B で検査落ち」
# の中断が起こり、退避済みの A が次回実行の previous/ 作り直しで失われる。
validate_planned_result_dirs() {
  [[ -n "${OUTPUT_DIR:-}" ]] || return 0
  local entry cli seen_clis=""
  while IFS= read -r entry; do
    [[ -n "$entry" ]] || continue
    cli="${entry%%:*}"
    case " ${seen_clis} " in
      *" ${cli} "*) continue ;;
    esac
    seen_clis="${seen_clis} ${cli}"
    validate_result_dir_paths "$cli" || return 1
  done <<< "$EXECUTION_PLAN"
}

validate_result_dir_paths() { # <cli>
  local cli="$1" cli_dir="${OUTPUT_DIR}/${cli}" prev_dir
  if [[ -d "$cli_dir" ]]; then
    resolve_expected_dir "$cli_dir" "the result dir for ${cli}" >/dev/null || return 1
  elif [[ -e "$cli_dir" || -L "$cli_dir" ]]; then
    echo "ERROR: the result path for ${cli} exists but is not a directory: ${cli_dir}" >&2
    echo "       Results are written under it, so this run cannot proceed." >&2
    return 1
  else
    return 0
  fi
  prev_dir="${cli_dir}/previous"
  # symlink は追わずリンク自体を消す（clear_quarantine_dir）ので、解決検査が要るのは
  # 実体のディレクトリだけ。
  if [[ -d "$prev_dir" && ! -L "$prev_dir" ]]; then
    resolve_expected_dir "$prev_dir" "the quarantine dir" >/dev/null || return 1
  fi
  return 0
}

# ── Phase 2: 退避（clear_planned_outputs の後） ──
quarantine_unplanned_outputs() {
  [[ -n "${OUTPUT_DIR:-}" ]] || return 0
  UNPLANNED_RESULT_NOTES=""
  local entry cli seen_clis=""
  while IFS= read -r entry; do
    [[ -n "$entry" ]] || continue
    cli="${entry%%:*}"
    case " ${seen_clis} " in
      *" ${cli} "*) continue ;;
    esac
    seen_clis="${seen_clis} ${cli}"
    quarantine_cli_results "$cli" || return 1
  done <<< "$FULL_EXECUTION_PLAN"
  # 報告専用の関数を最終式にしない。呼び出し側は rc=2（準備段階の失敗 = レポートを
  # 出さずに中断）へ倒すので、名指しの走査が何かの拍子に非 0 を返すと、退避は成功して
  # いるのに実行ごと落ちる。退避の成否は上のループが既に返している。
  report_unplanned_result_dirs
  return 0
}

# 前回退避分を消す。素の `rm -rf` を撃たないのは clear_staging_dir と同じ理由
# （途中の symlink で再帰削除が OUTPUT_DIR の外へ抜ける）。
clear_quarantine_dir() { # <dir>
  local dir="$1" resolved discarded=0 f
  # symlink は**追わない**。`[[ -d ]]` は symlink→dir でも真になるため -L を先に見る。
  # 追うと指し先を丸ごと消す — `previous -> ../claude-code` ならプラン外 CLI の結果
  # 一式、`previous -> .` なら自分の CLI ディレクトリ（staging の files/ を含む）。
  # 解決先が OUTPUT_DIR 配下でも消してはいけないので、配下判定ではなくリンク自体の
  # 削除で塞ぐ。同型の内向き追従は clear_staging_dir にも残っていたが、Issue `#1120` で
  # 同じ方針（リンクは追わない）へ揃えた。`#722` の対象は clear_planned_outputs の
  # 外向き symlink だが、そこで再利用した resolve_expected_dir は内外どちらの
  # symlink も拒否する。
  if [[ -L "$dir" ]]; then
    if ! rm -f "$dir"; then
      echo "ERROR: cannot remove the symlink at the quarantine path: ${dir}" >&2
      return 1
    fi
    echo "  ⚠️ Removed a symlink at the quarantine path (its target was left untouched): ${dir}" >&2
    return 0
  fi
  if [[ -d "$dir" ]]; then
    resolved="$(resolve_expected_dir "$dir" "the quarantine dir")" || return 1
    for f in "$resolved"/*.md; do
      if [[ -f "$f" || -L "$f" ]]; then
        discarded=$((discarded + 1))
      fi
    done
    if ! rm -rf "$resolved"; then
      echo "ERROR: cannot clear the previous quarantine dir: ${resolved}" >&2
      return 1
    fi
    # 無言で捨てない。退避物の寿命は「次にこの CLI を含む実行が走るまで」なので、
    # 捨てた事実と件数が出ていないと、利用者は previous/ を残っているものとして探す。
    if [[ "$discarded" -gt 0 ]]; then
      echo "  🗑️  Discarded ${discarded} quarantined result(s) from an earlier run: ${resolved}" >&2
    fi
    return 0
  fi
  # ディレクトリでない残骸（ファイル・壊れた symlink 以外の実体）はそれ自体を消す。
  if [[ -e "$dir" ]]; then
    if ! rm -f "$dir"; then
      echo "ERROR: cannot remove non-directory at quarantine path: ${dir}" >&2
      return 1
    fi
  fi
  return 0
}

plan_has_entry() { # <cli:perspective>
  local target="$1" entry
  while IFS= read -r entry; do
    [[ "$entry" == "$target" ]] && return 0
  done <<< "$FULL_EXECUTION_PLAN"
  return 1
}

# plan_has_cli の EXECUTION_PLAN 版。プラン構築直後（FULL_EXECUTION_PLAN はまだ空）に
# 使うのでこちらが要る。両者を 1 つにまとめないのは、参照するプランが違うことが
# 呼び出し地点の意味そのものだから（実行前の計画 / 実行後の「今回のもの」の定義）。
plan_lists_cli() { # <cli>
  local target="$1" entry
  while IFS= read -r entry; do
    [[ -n "$entry" ]] || continue
    [[ "${entry%%:*}" == "$target" ]] && return 0
  done <<< "$EXECUTION_PLAN"
  return 1
}

plan_has_cli() { # <cli>
  local target="$1" entry
  while IFS= read -r entry; do
    [[ "${entry%%:*}" == "$target" ]] && return 0
  done <<< "$FULL_EXECUTION_PLAN"
  return 1
}

# 動かさないが名指しはする残骸を記録する。stderr へ 1 行出し、統合レポートにも
# 同じ内容を載せる（レポートだけを読む消費者にも届かせるため）。
note_unplanned_results() { # <text>
  UNPLANNED_RESULT_NOTES="${UNPLANNED_RESULT_NOTES:+${UNPLANNED_RESULT_NOTES}
}$1"
  echo "  ⚠️ Not part of this run: $1" >&2
}

quarantine_cli_results() { # <cli>
  local cli="$1"
  local cli_dir="${OUTPUT_DIR}/${cli}"
  [[ -d "$cli_dir" ]] || return 0

  local resolved_cli
  resolved_cli="$(resolve_expected_dir "$cli_dir" "the result dir for ${cli}")" || return 1

  local prev_dir="${resolved_cli}/previous"
  clear_quarantine_dir "$prev_dir" || return 1

  local moved=0 foreign=0 moved_names="" file base resolved_prev=""
  for file in "$resolved_cli"/*.md; do
    # nullglob は使わない（グローバルに効かせると他の展開の意味まで変わる）。
    # 一致 0 件のとき glob はパターンそのものへ展開されるので、実体検査で弾く。
    # ディレクトリ（`foo.md/`）は結果ファイルではないので触らない。
    [[ -f "$file" || -L "$file" ]] || continue
    base="${file##*/}"
    plan_has_entry "${cli}:${base%.md}" && continue
    if ! is_orchestrator_result "$file"; then
      foreign=$((foreign + 1))
      continue
    fi
    if [[ -z "$resolved_prev" ]]; then
      if ! mkdir -p "$prev_dir"; then
        echo "ERROR: cannot create quarantine dir: ${prev_dir}" >&2
        return 1
      fi
      resolved_prev="$(resolve_expected_dir "$prev_dir" "the quarantine dir")" || return 1
    fi
    if ! mv "$file" "${resolved_prev}/${base}"; then
      echo "ERROR: cannot quarantine a previous run's result: ${file}" >&2
      echo "       A previous run's result would be read as this run's output." >&2
      return 1
    fi
    moved=$((moved + 1))
    moved_names="${moved_names:+${moved_names}, }${base%.md}"
  done

  # finding の記録（<観点>.findings.tsv）も結果と同じ扱いで退避する。記録は結果本文から
  # 導いた派生物なので、結果だけ退避すると `ls <cli>/` に前回の記録が今回のものとして
  # 残る。動かすのは 1 行目が orchestrator の書くヘッダと一致するものだけ（利用者の
  # ファイルは動かさない — 上の .md と同じ線引き）。件数は結果の退避件数に含めない。
  # 読めない記録（権限・I/O）はヘッダを確かめられないが、黙って残すと前回の記録が今回の
  # ものとして読まれる。移動はディレクトリの権限だけで済むので、名指しの警告を出して
  # previous/ へ退避する（削除はしない）。移せなければ run を止める。ヘッダが一致しない・
  # 通常ファイルでない（symlink 等）ものは動かさずに名指しする（.md の foreign と同じ）。
  local tsv_first tsv_foreign=0
  for file in "$resolved_cli"/*.findings.tsv; do
    [[ -e "$file" || -L "$file" ]] || continue
    base="${file##*/}"
    plan_has_entry "${cli}:${base%.findings.tsv}" && continue
    if [[ -L "$file" || ! -f "$file" ]]; then
      tsv_foreign=$((tsv_foreign + 1))
      continue
    fi
    if [[ -r "$file" ]]; then
      tsv_first=""
      IFS= read -r tsv_first < "$file" || true
      if [[ "$tsv_first" != "$REVIEW_FINDINGS_TSV_HEADER" ]]; then
        tsv_foreign=$((tsv_foreign + 1))
        continue
      fi
    else
      echo "  ⚠️ Cannot read a findings record from an earlier run: ${file}" >&2
      echo "     Its header cannot be checked; moving it into previous/ so it is not read as this run's output." >&2
    fi
    if [[ -z "$resolved_prev" ]]; then
      if ! mkdir -p "$prev_dir"; then
        echo "ERROR: cannot create quarantine dir: ${prev_dir}" >&2
        return 1
      fi
      resolved_prev="$(resolve_expected_dir "$prev_dir" "the quarantine dir")" || return 1
    fi
    if ! mv "$file" "${resolved_prev}/${base}"; then
      echo "ERROR: cannot quarantine a previous run's findings record: ${file}" >&2
      echo "       A previous run's findings would be read as this run's output." >&2
      return 1
    fi
  done
  if [[ "$tsv_foreign" -gt 0 ]]; then
    note_unplanned_results "${cli}/ (${tsv_foreign} .findings.tsv file(s) this orchestrator did not write, or not a regular file — left in place, not this run's output)"
  fi

  if [[ "$moved" -gt 0 ]]; then
    echo "  🧹 Moved ${moved} result(s) from a previous run into ${resolved_prev}: ${moved_names}" >&2
  fi
  if [[ "$foreign" -gt 0 ]]; then
    note_unplanned_results "${cli}/ (${foreign} .md file(s) this orchestrator did not write — left in place, not this run's output)"
  fi
  # 報告専用（quarantine_unplanned_outputs の report_unplanned_result_dirs と同じ扱い）。
  # 走査の rc で退避成功の実行ごと落とさない。
  report_unplanned_staging_dirs "$cli" "$resolved_cli"
  return 0
}

# プラン外の CLI ディレクトリは 1 バイトも動かさない。ただし黙っていると
# `ls .review-results/` が前回実行の結果一式を今回の結果のように見せるので、
# 結果ファイルを持つものを名指しする（本 Issue が塞いだ誤読の、ディレクトリ単位版）。
report_unplanned_result_dirs() {
  local dir cli count discarded file tsv_count
  for dir in "$OUTPUT_DIR"/*/; do
    [[ -d "$dir" ]] || continue
    cli="${dir%/}"
    cli="${cli##*/}"
    # `*` は通常ドット始まりを外すが、**呼び出し元の環境に GLOBIGNORE があると
    # bash は dotglob を暗黙に有効化する**（`GLOBIGNORE` 非空 = dotglob 相当）。
    # そのまま通すと `--fresh` の退避先 `.prev-<ts>/` や `.resume-cache/` が
    # 「Not part of this run」として名指しされ、利用者は自分の出力ディレクトリの
    # 内部構造を残骸と読み違える。CLI 名がドットで始まることは無いので明示的に外す。
    case "$cli" in .*) continue ;; esac
    plan_has_cli "$cli" && continue
    count=0
    discarded=0
    for file in "${dir}"*.md; do
      if [[ -f "$file" || -L "$file" ]]; then
        count=$((count + 1))
        # 前回走が破棄された結果は mark_outputs_discarded が 1 行目へ
        # `> DISCARDED` バナーを書く。「今回の結果ではない」
        # に加えて「そもそも完成した結果ではない」まで言えるので、内訳を出す。
        # 読めないファイルは discarded と断定しない（数えないだけ）。
        # symlink は **通常ファイルのときだけ** 読む。プラン外ディレクトリは 1 バイトも
        # 動かさない契約で、その読み取りも同じ線引きに揃える（FIFO を head すると
        # 書き手が現れるまで固まり、出力先の外を指すリンクは辿ること自体が契約違反）。
        if [[ -f "$file" && ! -L "$file" ]]; then
          case "$(head -n 1 "$file" 2>/dev/null)" in
            '> DISCARDED'*) discarded=$((discarded + 1)) ;;
          esac
        fi
      fi
    done
    tsv_count=0
    for file in "${dir}"*.findings.tsv; do
      if [[ -f "$file" || -L "$file" ]]; then
        tsv_count=$((tsv_count + 1))
      fi
    done
    if [[ "$tsv_count" -gt 0 ]]; then
      note_unplanned_results "${cli}/ (${tsv_count} findings record(s) (.findings.tsv) from an earlier run — left untouched, not this run's output)"
    fi
    if [[ "$count" -gt 0 ]]; then
      if [[ "$discarded" -gt 0 ]]; then
        note_unplanned_results "${cli}/ (${count} result file(s) from an earlier run, ${discarded} of them marked DISCARDED by that run — left untouched, not this run's output)"
      else
        note_unplanned_results "${cli}/ (${count} result file(s) from an earlier run — left untouched, not this run's output)"
      fi
    fi
    # staging（files/）は直下の .md とは**独立に**名指しする。elif で束ねると、.md が
    # 1 件でもあるプラン外 CLI の staging 残骸が黙って素通りする（.md の名指しは
    # ディレクトリ直下の話で、files/ の中身の存在を伝えない）。プラン外 CLI は
    # 1 バイトも動かさない契約なので、ここも名指しだけ。unknown（走査できなかった）は
    # 「残骸あり」と断定せず、0 件とも言い切らない別文言で報告する。
    case "$(staging_root_state "${dir}files")" in
      symlink)
        note_unplanned_results "${cli}/ (files/ is a symlink left from an earlier run — not followed, not this run's output)"
        ;;
      files)
        note_unplanned_results "${cli}/ (staging file(s) under files/ from an earlier run — left untouched, not this run's output)"
        ;;
      unknown)
        note_unplanned_results "${cli}/ (could not scan files/ — treat it as possibly holding an earlier run's staging output; left untouched)"
        ;;
    esac
  done
}

# ── プラン外タスクの staging（<cli>/files/<perspective>/）の名指し（Issue `#724`） ──
#
# clear_planned_outputs が消す staging は**今回のプランに載るタスク**の分だけなので、
# 観点セットを絞った再実行のあとには、プランに入らなかったタスクの files/ に前回
# 実行の生成物が残る。`.md` 結果で塞いだ誤読（「そこにある = 今回の成果」）が一段
# 下で開いたままになる形（本 Issue）。
#
# `.md` と違い **退避はせず名指しだけ** にする（対称性を意図的に崩す）:
#   - staging の中身は orchestrator 自筆ではなく各 CLI（またはその指示で動く
#     エージェント）の生成物で、write_output の 1 行目マーカーによる「自筆かどうか」
#     の判定が任意形式のファイルには使えない。判定なしで動かすと、利用者が staging へ
#     置いたファイルまで「次の実行で捨てられる previous/」へ入れることになり、
#     `.md` 側で「他人のファイルは動かさない」と決めた根拠が 1 実行遅れで嘘になる
#   - 統合レポートの implement セクションは staging を実測して件数と実パスを書くので、
#     レポート経由の消費者はプラン内の staging だけ読む。残る誤読経路は
#     `ls <cli>/files/` の直接読みで、それは名指し（stderr + レポートの
#     Not part of this run 節）で塞がる
#
# 報告専用: 走査に失敗しても実行は落とさない（report_unplanned_result_dirs と同じ
# 扱い）。ただし数えられなかったことは隠さず「走査できなかった」として名指しする —
# 0 件と言い切ると「観測できなかった」が「何も無い」に化けるし、「N 件ある」と
# 断定すると観測していないものを観測したことにする（append_plan_sections の
# staging 実測と同じ理由で、三値〔有 / 無 / unknown〕を文言まで保って伝える）。
#
# プラン内タスクの除外は **implement のときだけ**。staging は implement の概念で、
# review / explore の実行は staging を clear もしなければ書きもしない — そこで
# plan_has_entry を見て黙ると、「観点名が今回のプランに載っている」だけの理由で
# 前回 implement の生成物が名指しから漏れる。
#
# symlink（files/ 自体・その配下のエントリとも）は**追わない**。名指しのための
# 読み取り走査でも、指し先が OUTPUT_DIR の外なら他人のツリーを歩くことになり、
# 「1 バイトも触れない」の精神（clear_quarantine_dir が rm で守っているもの）を
# 読み取りで破ることになる。リンクはリンクとして名指しして終える。
report_unplanned_staging_dirs() { # <cli> <resolved-cli-dir>
  local cli="$1" files_root="$2/files" entry name count
  if [[ -L "$files_root" ]]; then
    note_unplanned_results "${cli}/files (symlink left from an earlier run — not followed, not this run's output)"
    return 0
  fi
  [[ -d "$files_root" ]] || return 0
  for entry in "$files_root"/*; do
    # glob 不一致はパターンそのものへ展開されるので実体検査で弾く（dangling symlink
    # は -e が偽になるため -L も見る）。
    [[ -e "$entry" || -L "$entry" ]] || continue
    name="${entry##*/}"
    if [[ -L "$entry" ]]; then
      note_unplanned_results "${cli}/files/${name} (symlink left from an earlier run — not followed, not this run's output)"
      continue
    fi
    if [[ -d "$entry" ]]; then
      if [[ "${TASK_TYPE:-review}" == "implement" ]] && plan_has_entry "${cli}:${name}"; then
        continue
      fi
      count="$(count_staging_files "$entry")"
      case "$count" in
        0) ;;  # 空ディレクトリは読み手を誤らせる中身が無い
        unknown)
          note_unplanned_results "${cli}/files/${name}/ (could not scan this staging dir — treat it as possibly holding an earlier run's output; left untouched)"
          ;;
        *)
          note_unplanned_results "${cli}/files/${name}/ (${count} staging file(s) from an earlier run — left untouched, not this run's output)"
          ;;
      esac
      continue
    fi
    if [[ -f "$entry" ]]; then
      note_unplanned_results "${cli}/files/${name} (stray file from an earlier run — left untouched, not this run's output)"
      continue
    fi
    # fifo / socket 等。レイアウト外の実体も黙って素通しはしない。
    note_unplanned_results "${cli}/files/${name} (non-directory entry from an earlier run — left untouched, not this run's output)"
  done
  return 0
}

# staging 配下のファイル数を数える。走査失敗（権限・I/O、計数パイプの失敗）は
# 0 件と区別して "unknown" を返す。rc は**常に 0** — 報告専用経路で使うため、
# ここの失敗が set -e / 呼び出し元経由で実行本体を落としてはいけない。
# symlink も数える（指し先がどこでも「残骸がある」ことに変わりはない。-P 既定
# なので辿りはしない）。件数は -print0 の NUL を数える — 改行入りのファイル名を
# 行数で数えると 1 件が複数件に化ける。find の stderr は捨てない（unknown に
# なった原因が実行ログに残るように）。
count_staging_files() { # <dir>
  local count
  if ! count="$(find "$1" \( -type f -o -type l \) -print0 | tr -cd '\0' | wc -c | tr -d '[:space:]')" \
     || [[ ! "$count" =~ ^[0-9]+$ ]]; then
    printf 'unknown\n'
    return 0
  fi
  printf '%s\n' "$count"
  return 0
}

# <cli>/files の状態を三値 + α で返す: absent | symlink | empty | files | unknown。
# report_unplanned_result_dirs（プラン外 CLI の fall-back 名指し）用。unknown を
# 「有り」へ潰さない — 呼び出し側が文言を分けて伝える。rc は常に 0。
staging_root_state() { # <files-root>
  if [[ -L "$1" ]]; then
    printf 'symlink\n'
    return 0
  fi
  if [[ ! -d "$1" ]]; then
    printf 'absent\n'
    return 0
  fi
  local count
  count="$(count_staging_files "$1")"
  case "$count" in
    0) printf 'empty\n' ;;
    unknown) printf 'unknown\n' ;;
    *) printf 'files\n' ;;
  esac
  return 0
}

# ── Resume Identity And Cache（Issue `#586`） ──
#
# Cache only complete task results, keyed by the whole run input. A task-level key
# would wrongly reuse seven perspectives after the caller changed the requested
# perspective set, which is explicitly part of the review contract. timeout is
# intentionally absent: extending a deadline is the main recovery path resume is
# meant to support and does not change what the CLI is asked to review.
hash_file_or_missing() { # <label> <path>
  local label="$1" path="$2" digest
  if [[ -f "$path" ]]; then
    digest="$(git hash-object "$path" 2>/dev/null)" || return 1
    printf '%s=%s\n' "$label" "$digest"
  else
    printf '%s=(missing)\n' "$label"
  fi
}

hash_text_value() { # <label> <value>
  local label="$1" value="$2" digest
  digest="$(printf '%s' "$value" | git hash-object --stdin 2>/dev/null)" || return 1
  printf '%s=%s\n' "$label" "$digest"
}

compute_resume_identity() {
  local plan_sorted entry cli persp env_name env_value part head_oid="" base_oid=""
  plan_sorted="$(printf '%s\n' "$EXECUTION_PLAN" | LC_ALL=C sort -u)"
  if [[ "$IN_GIT_REPO" == "true" ]]; then
    head_oid="$(git -C "$REPO_ROOT" rev-parse HEAD 2>/dev/null)" || return 1
    if [[ "$STAGED_DIFF" == "true" ]]; then
      base_oid="(staged)"
    else
      base_oid="$(git -C "$REPO_ROOT" rev-parse "${BASE_BRANCH}^{commit}" 2>/dev/null)" || return 1
    fi
  fi

  # adapter-common.sh の構成ファイルも identity に入る。配列が無いのに入口だけを
  # hash すると、構成ファイルの変更が古い結果の再利用を止めない（ADR-075）。
  if [[ -z "${ADAPTER_COMMON_PARTS+x}" || "${#ADAPTER_COMMON_PARTS[@]}" -eq 0 ]]; then
    return 1
  fi

  {
    printf 'identity-version=%s\n' "$RESUME_IDENTITY_VERSION"
    printf 'task=%s\nmode=%s\nstrategy=%s\n' "$TASK_TYPE" "$MODE" "$STRATEGY"
    # 解決結果ではなく指定された名前を使う。解決結果を混ぜると、ローカル base を
    # pull しただけで origin/develop → develop と名乗りが変わり、同じ入力の再実行が
    # 「別の入力」に見えて resume が丸ごと無効化される（base-oid が実体の変化を見る）。
    printf 'base-ref=%s\nbase-oid=%s\nhead=%s\n' "$BASE_BRANCH_IDENTITY" "$base_oid" "$head_oid"
    printf 'staged=%s\ninclude-diff=%s\n' "$STAGED_DIFF" "$INCLUDE_DIFF"
    hash_text_value description "$DESCRIPTION"
    printf '%s\n' "$plan_sorted" | sed 's/^/plan=/'
    hash_file_or_missing config "$CONFIG_FILE"
    hash_file_or_missing orchestrator "${SCRIPT_DIR}/multi-agent.sh"
    # 構成ファイル（開始時に source した本体。ADR-075）も orchestrator の一部として算入する。
    # 入口だけを見ると、構成ファイルの変更が古い結果の再利用を止めない
    for part in "${MULTI_AGENT_PARTS[@]}"; do
      hash_file_or_missing "orchestrator-part:${part##*/}" "$part"
    done
    hash_file_or_missing adapter-common "$ADAPTER_COMMON"
    # 構成ファイル（adapter-common.sh が source する本体）も入口と並べて算入する。
    for part in "${ADAPTER_COMMON_PARTS[@]}"; do
      hash_file_or_missing "adapter-common-part:${part##*/}" "$part"
    done
    if [[ -n "$FIXED_DIFF_FILE" ]]; then
      hash_file_or_missing fixed-diff "$FIXED_DIFF_FILE"
    else
      printf '%s\n' 'fixed-diff=(none)'
    fi
    while IFS= read -r entry; do
      [[ -n "$entry" ]] || continue
      cli="${entry%%:*}"
      persp="${entry#*:}"
      hash_file_or_missing "adapter:${cli}" "$(get_cli_adapter "$cli")"
      hash_file_or_missing "perspective:${TASK_TYPE}:${persp}" "$(resolve_perspective_file "$persp")"
      for env_name in $(get_cli_model_env_vars "$cli"); do
        eval "env_value=\${${env_name}-}"
        hash_text_value "env:${env_name}" "$env_value"
      done
    done <<EOF
$plan_sorted
EOF
  } | git hash-object --stdin 2>/dev/null
}

cache_task_result() { # <cli> <perspective>
  local cli="$1" persp="$2" source_file cache_dir cache_file digest
  source_file="${OUTPUT_DIR}/${cli}/${persp}.md"
  [[ -f "$source_file" ]] || return 1
  cache_dir="${RESUME_CACHE_DIR}/${cli}"
  cache_file="${cache_dir}/${persp}.md"
  mkdir -p "$cache_dir" || return 1
  digest="$(git hash-object "$source_file" 2>/dev/null)" || return 1
  cp "$source_file" "${cache_file}.tmp.$$" || return 1
  printf '%s\n' "$digest" >"${cache_file}.hash.tmp.$$" || return 1
  mv "${cache_file}.tmp.$$" "$cache_file" || return 1
  mv "${cache_file}.hash.tmp.$$" "${cache_file}.hash" || return 1
}

restore_cached_result() { # <cli> <perspective>
  local cli="$1" persp="$2" cache_file expected actual target
  [[ ! -e "${RESUME_CACHE_DIR}/.pending" ]] || return 1
  cache_file="${RESUME_CACHE_DIR}/${cli}/${persp}.md"
  [[ -f "$cache_file" && -f "${cache_file}.hash" ]] || return 1
  expected="$(cat "${cache_file}.hash" 2>/dev/null)" || return 1
  [[ "$expected" =~ ^[0-9a-f]+$ ]] || return 1
  actual="$(git hash-object "$cache_file" 2>/dev/null)" || return 1
  [[ "$actual" == "$expected" ]] || return 1
  target="${OUTPUT_DIR}/${cli}/${persp}.md"
  mkdir -p "$(dirname "$target")" || return 1
  cp "$cache_file" "$target" || return 1
}

prepare_resume_execution_plan() {
  local entry cli persp active_plan=""
  FULL_EXECUTION_PLAN="$EXECUTION_PLAN"
  REUSED_TASKS=""
  EXECUTED_TASKS=""
  RESUME_IDENTITY="$(compute_resume_identity)" || {
    echo "ERROR: cannot compute the resume input identity." >&2
    return 1
  }
  [[ -n "$RESUME_IDENTITY" ]] || {
    echo "ERROR: computed an empty resume input identity." >&2
    return 1
  }
  RESUME_CACHE_DIR="${OUTPUT_DIR}/.resume-cache/${RESUME_IDENTITY}"
  mkdir -p "$RESUME_CACHE_DIR" || {
    echo "ERROR: cannot create resume cache: ${RESUME_CACHE_DIR}" >&2
    return 1
  }

  while IFS= read -r entry; do
    [[ -n "$entry" ]] || continue
    cli="${entry%%:*}"
    persp="${entry#*:}"
    if [[ "$RESUME" == "true" ]] && ! delegated_response_waiting "$cli" "$persp" \
       && restore_cached_result "$cli" "$persp"; then
      REUSED_TASKS="${REUSED_TASKS:+$REUSED_TASKS }${cli}/${persp}"
      echo "  ♻️  Reused: ${cli}/${persp}" >&2
    else
      if [[ "$RESUME" == "true" ]]; then
        echo "  ▶ Resume executes: ${cli}/${persp} (no valid completed cache)" >&2
      fi
      active_plan="${active_plan:+$active_plan
}${entry}"
      EXECUTED_TASKS="${EXECUTED_TASKS:+$EXECUTED_TASKS }${cli}/${persp}"
    fi
  done <<< "$FULL_EXECUTION_PLAN"
  EXECUTION_PLAN="$active_plan"

  if [[ -n "$EXECUTION_PLAN" ]]; then
    RESUME_CACHE_PENDING="${RESUME_CACHE_DIR}/.pending"
    if ! printf 'pid=%s\n' "$$" > "$RESUME_CACHE_PENDING"; then
      echo "ERROR: cannot mark the resume cache as pending verification: ${RESUME_CACHE_PENDING}" >&2
      return 1
    fi
  fi
}

finalize_resume_cache() {
  [[ -n "$RESUME_CACHE_PENDING" ]] || return 0
  if ! rm -f "$RESUME_CACHE_PENDING"; then
    echo "ERROR: cannot mark the resume cache as verified: ${RESUME_CACHE_PENDING}" >&2
    return 1
  fi
  RESUME_CACHE_PENDING=""
}

# ── Output Directory Lock（Issue `#402`） ──
# レポート・staging は固定パスなので、同じ output-dir の 2 run を許すと後発 run の
# clear_planned_outputs が先行 run の生成物を削除する。mkdir の原子性を lock として使い、
# 同時実行はタスク起動前に fail-loud で止める。PID の生存確認による自動 stale 回収は
# PID 再利用と確認→削除の race があるため行わない。異常終了後の lock は利用者が実行中
# process が無いことを確認してから明示的に削除する。
release_output_lock() {
  [[ "$OUTPUT_LOCK_HELD" == "true" ]] || return 0
  local owner_file="${OUTPUT_LOCK_DIR}/owner"
  rm -f "$owner_file" 2>/dev/null || true
  if ! rmdir "$OUTPUT_LOCK_DIR" 2>/dev/null; then
    echo "WARNING: could not release output-dir lock: ${OUTPUT_LOCK_DIR}" >&2
    echo "         Refusing recursive cleanup because unexpected files may be present." >&2
    return 1
  fi
  OUTPUT_LOCK_HELD=false
  return 0
}

# ── 走行中ロック ──
# 起動バナー（execute_tasks の「完了まで worktree を変更しないでください」）は stdout /
# stderr を読む人間にしか届かない。background 起動ではそれを誰も読まないまま編集が
# 始まり、数分ぶんのレビューが revision guard で丸ごと破棄される再発が観測されている。
# ロックは**機械が読む宣言**で、PreToolUse hook（hooks/guard-review-in-flight.sh）が
# これを見て編集系ツールを止める。orchestrator 側は「置く / 必ず消す」だけを担い、
# 何を止めるかは hook が決める（破棄ロジック・終了コードはこの機構で変えない）。
#
# 置き場所は OUTPUT_DIR 直下の `.review-in-flight`。hook は既定の出力先
# （<repo root>/.review-results）しか探さないので、--output-dir で既定から動かした
# 実行は hook から見えない（hook 側ヘッダーに明記。fail-open）。
#
# task 名を引数に取るのは explore / implement へ広げる余地を残すため。現状の呼び出しは
# review だけで、他の task では呼ばない（バナーと同じ線引き）。
write_run_in_flight() { # <task> <head-sha> <perspectives-csv>
  local task="$1" head_sha="$2" perspectives="$3" f
  [[ -n "${OUTPUT_DIR:-}" && -d "$OUTPUT_DIR" ]] || return 0
  f="${OUTPUT_DIR}/.review-in-flight"
  # 書けなくても実行は止めない。これは追加の防御層で、これが無い状態は
  # 「この機構を入れる前」と同じ（revision guard は従来どおり効く）。
  if printf 'pid=%s\ntask=%s\nhead=%s\nstarted=%s\nstarted_epoch=%s\nperspectives=%s\n' \
      "$$" "$task" "$head_sha" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$(date -u +%s)" \
      "$perspectives" > "$f" 2>/dev/null; then
    REVIEW_IN_FLIGHT_FILE="$f"
  else
    echo "WARNING: could not write the in-flight marker: ${f}" >&2
    echo "         The tree-edit guard hook will not fire for this run." >&2
  fi
  return 0
}

# 正常終了・DISCARDED・タイムアウト・トラップ可能なシグナル（HUP / INT / TERM）のどれでも
# 消える必要がある。消し漏らすと以後の全編集が hook に止められるので、EXIT trap
# （output_lock_exit）から呼ぶ。個々の失敗経路へ後始末を配らないのは、経路が増えるたびに
# 1 つ書き忘れるクラスの事故を構造で消すため。
# 限界: SIGKILL（kill -9）とホストのクラッシュでは trap が走らずロックが残る。その残骸への
# 緩和は hook 側にあり、PID 生存判定と経過時間の上限
# （FF_REVIEW_LOCK_MAX_AGE_SECONDS、既定 4 時間）を超えたロックは stale として
# 警告だけで通す。手で消す場合は `rm <OUTPUT_DIR>/.review-in-flight`。
remove_run_in_flight() {
  [[ -n "$REVIEW_IN_FLIGHT_FILE" ]] || return 0
  if ! rm -f "$REVIEW_IN_FLIGHT_FILE" 2>/dev/null; then
    echo "WARNING: could not remove the in-flight marker: ${REVIEW_IN_FLIGHT_FILE}" >&2
    echo "         Remove it by hand, or the edit guard keeps firing." >&2
  fi
  REVIEW_IN_FLIGHT_FILE=""
  return 0
}

output_lock_exit() {
  local rc=$?
  remove_run_in_flight
  # 失敗して返った回の理由ファイルはプロセス終了後も残る（削除は
  # current_review_series_id の冒頭にしかない）。stale 読み取りの種を残さない。
  clear_reason_file "$(review_series_reason_file)"
  release_output_lock || {
    [[ "$rc" -ne 0 ]] || rc=1
  }
  exit "$rc"
}

acquire_output_lock() {
  OUTPUT_LOCK_DIR="${OUTPUT_DIR}/.multi-agent-run.lock"
  if ! mkdir "$OUTPUT_LOCK_DIR" 2>/dev/null; then
    echo "ERROR: output dir is already in use by another orchestrator (or a stale lock remains)." >&2
    echo "       output: ${OUTPUT_DIR}" >&2
    echo "       lock:   ${OUTPUT_LOCK_DIR}" >&2
    echo "       Use a different --output-dir, or after confirming no run is active remove the stale lock." >&2
    return 1
  fi
  OUTPUT_LOCK_HELD=true
  if ! printf 'pid=%s\ntask=%s\ncwd=%s\n' "$$" "$TASK_TYPE" "$(pwd -P)" >"${OUTPUT_LOCK_DIR}/owner"; then
    release_output_lock || true
    echo "ERROR: cannot write output-dir lock metadata: ${OUTPUT_LOCK_DIR}/owner" >&2
    return 1
  fi
  # Hold the lock through report generation. Releasing after execute_tasks but before generate_report
  # would let another run clear the files while this run is reading them.
  trap output_lock_exit EXIT
  trap 'exit 130' HUP INT TERM
  return 0
}

# ── Fresh start: archive leftover output (Issue `#1025`) ──
# Run after the output lock is held so a concurrent run cannot have its files
# moved out from under it. The lock directory itself stays; everything else
# (reports, per-CLI results, resume cache) moves to `${OUTPUT_DIR}/.prev-<ts>/`.
# The unresolved-Critical guard then sees an empty output dir.
#
# 退避先は OUTPUT_DIR の**内側**（https://github.com/feel-flow/ff-dev-toolkit/issues/96）。
# 以前は兄弟の `<dir>.prev-<ts>/` で、
# 消費側が規約どおり `.review-results/` だけを gitignore していると一致せず、退避一式
# （実測 521 ファイル / 約 8MB）が丸ごとコミットへ巻き込まれた。規約を配っている側が
# 規約から外れる名前を実行時に生やしていたのが原因なので、名前の方を規約へ戻す。
#
# 結果ファイルの走査が `.prev-*` を拾わないことの確認（本 Issue の AC）:
#   - プラン外の結果ディレクトリ / staging の走査は `"$OUTPUT_DIR"/*/` の glob。
#     このスクリプトは dotglob を有効化していないが、**呼び出し元の環境に
#     `GLOBIGNORE` が設定されていると bash は dotglob を暗黙に有効化する**ので
#     `*` だけでは `.` 始まりを排除できない。report_unplanned_result_dirs は
#     ループ内で `.` 始まりを明示 skip して、退避先を「今回のプラン外」として
#     名指ししないようにしている。
#   - integrated-report / resume-cache / series タグ / 未解消 Critical guard /
#     各タスクの結果判定は固定パス（`${OUTPUT_DIR}/integrated-report.md`,
#     `${OUTPUT_DIR}/.resume-cache/<identity>`, `${OUTPUT_DIR}/<cli>/<persp>.md`）
#     だけを読む。退避後はそれらが `.prev-<ts>/` の下へ移るので今回の走査に入らない。
# ドットを含めて走査するのはこの関数だけなので、退避先と既存の `.prev-*` はここで外す。
archive_previous_outputs_if_fresh() {
  [[ "$FRESH" == "true" ]] || return 0
  [[ -n "${OUTPUT_DIR:-}" && -d "$OUTPUT_DIR" ]] || return 0

  local item base ts archive archive_base moved=0
  ts="$(date -u +%Y%m%dT%H%M%SZ)"
  archive_base=".prev-${ts}"
  archive="${OUTPUT_DIR}/${archive_base}"
  if [[ -e "$archive" ]]; then
    archive_base="${archive_base}-$$"
    archive="${OUTPUT_DIR}/${archive_base}"
  fi
  if [[ -e "$archive" ]]; then
    echo "ERROR: archive destination already exists: ${archive}" >&2
    echo "       Previous results were left untouched: ${OUTPUT_DIR}" >&2
    return 1
  fi

  for item in "$OUTPUT_DIR"/* "$OUTPUT_DIR"/.[!.]* "$OUTPUT_DIR"/..?*; do
    [[ -e "$item" || -L "$item" ]] || continue
    base="${item##*/}"
    [[ "$base" == ".multi-agent-run.lock" ]] && continue
    # 退避先を自分自身の中へ入れない。加えて過去の実行が残した `.prev-*` も動かさない
    # （`.[!.]*` はこれらを拾う）。動かすと退避が入れ子に積み上がり、`--fresh` のたびに
    # 同じバイト列を 1 段深くコピーし直すことになる。
    [[ "$base" == "$archive_base" ]] && continue
    case "$base" in .prev-*) continue ;; esac
    if [[ "$moved" -eq 0 ]]; then
      if ! mkdir "$archive"; then
        echo "ERROR: cannot create archive dir: ${archive}" >&2
        echo "       Previous results were left untouched: ${OUTPUT_DIR}" >&2
        return 1
      fi
    fi
    if ! mv "$item" "${archive}/${base}"; then
      echo "ERROR: cannot archive previous result: ${item}" >&2
      echo "       --fresh left a partial archive at ${archive}" >&2
      return 1
    fi
    moved=$((moved + 1))
  done

  if [[ "$moved" -eq 0 ]]; then
    echo "ℹ️  --fresh: no previous results to archive in ${OUTPUT_DIR}" >&2
    report_archive_accumulation
    return 0
  fi
  echo "🧹 --fresh: archived ${moved} previous result(s) to ${archive}" >&2
  report_archive_accumulation
  return 0
}

# 退避先は出力ディレクトリの内側なので gitignore に乗り、`git status` にも `ls` にも
# 現れない。コミットへ巻き込まれないのが狙いだが、見えない分だけ `--fresh` のたびに
# 黙って積み上がる（旧形式の兄弟は少なくとも untracked として見えていた）。退避完了の
# 直後に件数と合計サイズを 1 行出し、掛け目で気づけるようにする。
# 報告専用: `du` が無い / 失敗しても件数だけ出して実行は落とさない。
report_archive_accumulation() {
  local cand count=0 total=""
  local archives=()
  for cand in "$OUTPUT_DIR"/.prev-*; do
    [[ -d "$cand" ]] || continue
    archives+=("$cand")
    count=$((count + 1))
  done
  [[ "$count" -gt 0 ]] || return 0
  if total="$(du -shc "${archives[@]}" 2>/dev/null | tail -n 1 | awk '{print $1}')" \
    && [[ -n "$total" ]]; then
    echo "   ↳ ${count} archive(s) now under ${OUTPUT_DIR}/.prev-* (${total} total) — remove with: rm -rf ${OUTPUT_DIR}/.prev-*" >&2
  else
    echo "   ↳ ${count} archive(s) now under ${OUTPUT_DIR}/.prev-* — remove with: rm -rf ${OUTPUT_DIR}/.prev-*" >&2
  fi
  return 0
}

# 読み込み完了の印（multi-agent.sh の読み込み部が照合する。最後の行に置く）
_ma_part_loaded="multi-agent-outputs.sh"
