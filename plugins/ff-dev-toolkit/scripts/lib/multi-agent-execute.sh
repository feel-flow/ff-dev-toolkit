#!/usr/bin/env bash
# multi-agent.sh の構成ファイル: タスクの実行と rc の記録・ホスト委譲の回収・全タスクの実行・実行中にレビュー対象が動いていないことの検証。
#
# scripts/multi-agent.sh が開始時に 1 回だけ source する（直接実行しない）。読み込む順・
# 読めないときの停止・--resume の入力 identity への算入は multi-agent.sh の
# MULTI_AGENT_PARTS が正本。本文は分割前の multi-agent.sh の連続した行そのままで、
# トップレベルの初期化は構成ファイル同士で分割前と同じ順に走る（入口に残したタスク種別の既定より
# 後に走る点だけが違う）。ここへ set / trap / source を足さない。
# 末尾の _ma_part_loaded の行は読み込み完了の印（途中で切れたファイルを読み込み部が
# 見分ける）。bash 3.2 互換。分割の判断は ADR-075。
# pipefail-inherited: multi-agent.sh が set -euo pipefail の下で source する

# ── タスク実行 + rc 記録（Issue `#251`） ──
# タスクの rc は 1 ファイルずつ status dir へ記録し、親が wait 後に回収する
# （background プロセスの exit code だけでは、逐次ワーカーが抱える複数タスクの
# 内訳が失われるため、並列タスク側も同じ記録方式に揃える）。
# 記録は tmp へ書いてから mv する原子的保存 — 書き込み途中の死（ENOSPC 等）で
# **空の rc ファイル**が残ると、bash 3.2 では [[ "" -eq 0 ]] が真になり、失敗した
# タスクが INCOMPLETE 成果物の存在だけで「✅ Done」へ化ける（アダプタは失敗時も
# サルベージ成果物を書く仕様のため、-f 検査はバックストップにならない）。
# rc ファイルは ${cli}/${persp}.rc のサブディレクトリ構成 — 平坦な連結名だと
# 区切り文字を含む CLI 名が将来入ったときに衝突が静かに開く。
run_task_recorded() { # $1: cli / $2: perspective / $3: status dir
  local rc=0
  run_single_task "$1" "$2" || rc=$?
  # 逐次ワーカー（run_cli_group）が「この CLI はもう走らせない」を判断するために
  # rc を必要とする。rc ファイル経由で読ませると、記録に失敗した回に判断材料ごと
  # 消える（記録失敗はワーカーを殺すが、殺す前に判断は済ませたい）。
  LAST_TASK_RC="$rc"
  mkdir -p "${3}/${1}"
  if ! { printf '%s\n' "$rc" > "${3}/${1}/${2}.rc.tmp" \
         && mv "${3}/${1}/${2}.rc.tmp" "${3}/${1}/${2}.rc"; }; then
    # 記録に失敗してもワーカーは死んでよいが、死ぬ前に名乗る — 回収側は
    # 「ファイルなし = 失敗」で安全側に拾うが、原因（どのタスクの記録が
    # 書けなかったか）はこの行にしか残らない。
    echo "  ⚠️ Failed to record status for ${1}/${2} (task rc=${rc}): ${3} is not writable" >&2
    return 1
  fi
}

# ── Per-CLI Worker（Issue `#251`） ──
# EXECUTION_PLAN から自分の CLI の観点だけを計画順に**逐次**実行する。flat-rate
# CLI 専用 — レート制限は実行時失敗であり、本ツールは実行時 fallback を持たない
# ため、throttle された観点はカバレッジゼロになる。同時 burst を作らないことが
# 防御になる。premium / standard tier は従来どおりタスク単位で並列（一律逐次化は
# pair モード既定の premium 8 観点で実行時間を観点数倍にする退行になる）。
run_cli_group() { # $1: cli / $2: status dir
  local cli="$1" sdir="$2" entry gseen="" persp poison="" cause=""
  while IFS= read -r entry; do
    [[ -z "$entry" ]] && continue
    [[ "${entry%%:*}" == "$cli" ]] || continue
    if [[ " $gseen " == *" $entry "* ]]; then continue; fi
    gseen="$gseen $entry"
    persp="${entry#*:}"
    # 先行タスクが auth / billing で落ちていたら、この CLI の残りは実行しない
    # （Issue `#1143`）。フル setup（プロンプト構築・diff 読み込み・タイムアウト待ち）
    # を払ってから同じ失敗を引くだけなので、払う前に落とす。
    # 親プロセスは変数を見られない（このワーカーはバックグラウンドのサブシェル）ので、
    # 理由はステータス dir へ書いて回収側に読ませる。
    if [[ -n "$poison" ]]; then
      record_task_skipped "$cli" "$persp" "$poison" "$sdir" || return 1
      continue
    fi
    # 進捗を名乗ってから実行する — ワーカーが途中で死んだとき、どのタスクの
    # 処理中だったかはこの行でしか相関できない（逐次ブランチの ▶ 表示と対）。
    echo "▶ ${cli} → ${persp} (serialized)" >&2
    run_task_recorded "$cli" "$persp" "$sdir" || return 1
    # 委譲レーンの rc（DELEGATION_PENDING_EXIT_CODE = 123）はここへ来うる（flat-rate の
    # grok-cli を minimize_cost で委譲した場合。Issue `#2118`）。委譲待ちは成果物を書かないので
    # classify_cli_failure_cause が空を返し、cli_failure_is_deterministic（auth / billing /
    # model-unsupported だけを採る）に掛からない — 残り観点はスキップされない。この分類を
    # 広げるときは 123 を除外すること（委譲待ちを「CLI 単位の決定的失敗」にしない）。
    if [[ "${LAST_TASK_RC:-0}" -ne 0 && "${LAST_TASK_RC:-0}" -ne 124 ]]; then
      cause="$(classify_cli_failure_cause "${OUTPUT_DIR}/${cli}/${persp}.md")"
      if cli_failure_is_deterministic "$cause"; then
        poison="$cause"
      fi
    fi
  done <<< "$EXECUTION_PLAN"
}

# スキップを回収側へ伝える印。rc ファイルは書かない — rc の意味論（0 = 成功 /
# 非 0 = その終了コードで失敗 / 不在 = ワーカーが記録前に死んだ）へ 4 つ目の値を
# 混ぜると、既存の 3 分岐すべてが「この値は何を意味するか」を再解釈することになる。
record_task_skipped() { # $1: cli / $2: perspective / $3: cause / $4: status dir
  mkdir -p "${4}/${1}"
  if ! { printf '%s\n' "$3" > "${4}/${1}/${2}.skip.tmp" \
         && mv "${4}/${1}/${2}.skip.tmp" "${4}/${1}/${2}.skip"; }; then
    # 印を書けなければスキップを黙って成立させない。回収側は rc ファイル不在を
    # 「ワーカーが記録前に死んだ」= 失敗として拾うので、安全側には倒れる。
    echo "  ⚠️ Failed to record the skip marker for ${1}/${2}: ${4} is not writable" >&2
    return 1
  fi
  echo "  ⏭ Skipped ${1}/${2} — ${1} already failed in this run for a ${3} reason (not task-specific)." >&2
}



# ── 委譲を残したまま指定を落とした実行の停止 ──
#
# 委譲の受け渡し先（<cli>/<perspective>.md）は、同じ実行の clear_planned_outputs が
# 「今回のプランの対象」として消す場所そのもの。回収（collect_delegated_responses）は
# --delegate-to-host が**再度**渡されたときだけ走るので、2 段階の手順で 2 回目のフラグを
# 落とすと、ホストが書いた結果が 1 行の通知も無く消え、そのうえ枯渇していて動かない
# CLI が起動される。フラグの取り違えはこの手順で最も起きやすい操作なので、消す前に止める。
#
# 「委譲が未完了である」ことの印は request ファイル（受理時に消える）。これが残っている
# 観点が今回のプランに居て、それが今回の委譲レーン以外（委譲なしの実行ではすべてのレーン）
# なら中断する。同じレーンの委譲の再実行は回収へ進む。
guard_outstanding_delegations() {
  # 委譲中の実行でも、別レーンの未回収 handoff は守る（Issue `#2118`: レーンが可変になったため）
  [[ -n "${OUTPUT_DIR:-}" ]] || return 0
  local entry cli persp req outstanding=""
  while IFS= read -r entry; do
    [[ -n "$entry" ]] || continue
    cli="${entry%%:*}"
    persp="${entry#*:}"
    req="$(delegate_dir_for "$cli")/${persp}.request"
    [[ -f "$req" ]] || continue
    if [[ "$DELEGATE_TO_HOST" == "true" && "$cli" == "$DELEGATION_LANE" ]]; then continue; fi
    outstanding="${outstanding:+${outstanding} }${cli}/${persp}"
  done <<< "$EXECUTION_PLAN"
  [[ -n "$outstanding" ]] || return 0
  echo "ERROR: an unfinished host delegation exists for: ${outstanding}" >&2
  echo "       This run was started without --delegate-to-host for that lane, so it would clear those result" >&2
  echo "       paths (destroying anything the host wrote there) and start the CLI instead." >&2
  local resume_flag="--delegate-to-host"
  case " ${outstanding}" in
    *" grok-cli/"*) resume_flag="--delegate-to-host=grok-cli" ;;
    *" codex-cli/"*) resume_flag="--delegate-to-host=codex-cli" ;;
  esac
  echo "       Either re-run with ${resume_flag} to finish the round trip, or abandon the" >&2
  echo "       delegation by removing its handoff files:" >&2
  local abandon_entry abandon_cli abandon_persp
  for abandon_entry in $outstanding; do
    abandon_cli="${abandon_entry%%/*}"
    abandon_persp="${abandon_entry#*/}"
    echo "         rm -f $(shell_quote "$(delegate_dir_for "$abandon_cli")/${abandon_persp}.request") $(shell_quote "$(delegate_dir_for "$abandon_cli")/${abandon_persp}.prompt.md")" >&2
  done
  return 1
}

# ── ホストが書き戻した結果の回収 ──
#
# 委譲したレーンの結果は、ホストが <output-dir>/<cli>/<perspective>.md へ**直接**書く
# （Issue の指定どおり、レビュー結果の所定の場所そのもの）。その場所は
# clear_planned_outputs が「今回のプランの対象」として消す場所でもあるので、消される前に
# アダプタが読む位置（.delegated/<perspective>.response.md）へ移しておく。
#
# ここは運ぶだけで**内容を見ない**。「このプロンプトへの応答か」「レビュー本文として
# 成立しているか」の判定はアダプタ側（delegate_task）に 1 箇所だけ置く — 同じ判定を
# 2 箇所に置くと、片方だけ緩めた回に受理条件が静かにずれる。
# 委譲レビューのレーン（PreToolUse hook が置く凍結レーン）を解放する。
# あの経路のレーンは、終端イベントに相関 ID が無いため agent 系イベントでは閉じられない。
# **回収の到達そのものが「委譲したレビューは終わった」という宣言**なので、ここが唯一の
# 確定的な解放点になる。ここで消さないと、3 分のレビューのあと未対応レーンの寿命
# （既定 1800 秒）まで編集が凍結され、「正常完了」が「手で拒否された起動」と同じ扱いになる。
# レーンの形式は hook 側の正本に合わせる（`perspectives=delegated-review` を持つ *.lane）。
release_delegated_review_lanes() {
  local lane_dir lane
  lane_dir="${OUTPUT_DIR}/.review-in-flight.d"
  [[ -d "$lane_dir" ]] || return 0
  for lane in "$lane_dir"/*.lane; do
    [[ -f "$lane" ]] || continue
    grep -qx 'perspectives=delegated-review' "$lane" 2>/dev/null || continue
    rm -f "$lane" 2>/dev/null || true
  done
  return 0
}

collect_delegated_responses() {
  [[ "$DELEGATE_TO_HOST" == "true" ]] || return 0
  local entry cli persp dir src dst collected=0 names=""
  release_delegated_review_lanes
  # New handoffs advertise the generation response slot directly. A late legacy/final
  # path write must never be relabelled as a response to the current generation.
  [[ -z "$DELEGATION_GENERATION" ]] || return 0
  while IFS= read -r entry; do
    [[ -n "$entry" ]] || continue
    cli="${entry%%:*}"
    persp="${entry#*:}"
    task_is_delegated "$cli" || continue
    # 回収するのは「未応答の handoff がある観点」だけ。印は request ファイルで、
    # 受理した時点で消える。これを見ないと、**前の巡で受理済みの成果物**まで応答として
    # 回収してしまい、request が無いので digest 照合に落ちて stale 退避 → 再委譲となる。
    # 複数観点のレーンでは 1 観点ずつ答える通常の進み方が収束しなくなる（実測）。
    [[ -f "$(delegate_dir_for "$cli")/${persp}.request" ]] || continue
    src="${OUTPUT_DIR}/${cli}/${persp}.md"
    # symlink は運ばない（指し先は出力先の外でもありうる）。動かさないと
    # clear_planned_outputs が**リンクだけ**を消す（指し先は残る）ので、握り潰さず名指しする。
    if [[ -L "$src" ]]; then
      echo "  ⚠️ Not collecting a symlink at a delegated result path (left for the normal clear): ${src}" >&2
      continue
    fi
    [[ -f "$src" ]] || continue
    dir="$(delegate_dir_for "$cli")"
    if ! mkdir -p "$dir"; then
      echo "ERROR: cannot create the delegation dir: ${dir}" >&2
      return 1
    fi
    dst="${dir}/${persp}.response.md"
    if ! mv "$src" "$dst"; then
      echo "ERROR: cannot collect the host-written result: ${src}" >&2
      echo "       It sits where this run clears its own targets, so leaving it there would" >&2
      echo "       delete the host's work a moment later." >&2
      return 1
    fi
    collected=$((collected + 1))
    names="${names:+${names}, }${cli}/${persp}"
  done <<< "$EXECUTION_PLAN"
  if [[ "$collected" -gt 0 ]]; then
    echo "  🤝 Collected ${collected} host-written result(s) for adoption: ${names}" >&2
  fi
  return 0
}

# ── Execute All Tasks ──
execute_tasks() {
  if [[ -z "$EXECUTION_PLAN" ]]; then
    echo "Nothing to execute." >&2
    return 0
  fi

  # Reject a plan with unsafe path segments before writing/deleting anything.
  # ここから下の準備段階の失敗は rc=2 で返す（main がレポート生成を止める根拠）。
  validate_execution_plan || return 2

  mkdir -p "$OUTPUT_DIR"
  # 実在させた直後に**絶対かつ物理**のパスへ解決する。ここが staging パスの
  # 正規化の単一地点で、2 つの嘘を同時に潰している:
  #   1) --output-dir / 設定ファイルは値を無加工で受けるので相対値が入りうる。
  #      相対のまま implement へ流すと、プロンプトが "(absolute path)" と断言
  #      しながら相対パスを渡し、受け取ったエージェントは自分の CWD = 作業ツリー
  #      基準で解決してそこへ書く（本 Issue が塞ごうとした汚染そのもの）。
  #   2) 既定の OUTPUT_DIR は git rev-parse --show-toplevel（物理）由来、$PWD は
  #      論理なので、symlink 越しのチェックアウトでは同じ場所を違う綴りで指す。
  #      揃えておかないと validate_implement_output_boundary が毎回誤発火する
  #      （旧名 warn_if_staging_outside_sandbox。現存しないので grep しないこと）。
  if ! OUTPUT_DIR="$(cd "$OUTPUT_DIR" && pwd -P)"; then
    echo "ERROR: cannot resolve output dir: ${OUTPUT_DIR}" >&2
    return 2
  fi
  validate_implement_output_boundary || return 2
  validate_output_dir_boundary || return 2
  acquire_output_lock || return 2
  # --fresh must run after the lock and before the unresolved-Critical guard,
  # so leftover reports are no longer the guard's input.
  archive_previous_outputs_if_fresh || return 2
  # Read and compare delegation state before changing any report, response, handoff or cache.
  validate_planned_result_dirs || return 2
  load_delegation_state || return 2
  guard_outstanding_delegations || return 2
  prepare_resume_input || return 2
  guard_and_select_delegation_generation || return 2
  # Keep the existing unresolved-Critical guard before report/result cleanup.
  capture_and_guard_unresolved_critical_state || return 2
  clear_previous_integrated_report || return 2
  collect_delegated_responses || return 2
  # A task without prompt diff must not inherit the previous review's fixed diff.
  # Diff-bearing tasks overwrite the file in create_fixed_diff below; removing it
  # here for all tasks would erase the bytes before resume identity can hash them.
  if [[ "$TASK_TYPE" != "review" && "$INCLUDE_DIFF" != "true" ]]; then
    if ! rm -f "${OUTPUT_DIR}/.fixed-diff"; then
      echo "ERROR: cannot clear the previous fixed diff: ${OUTPUT_DIR}/.fixed-diff" >&2
      return 2
    fi
  fi
  capture_baseline_and_fix_diff || return 2
  prepare_resume_execution_plan || return 2
  clear_planned_outputs || return 2
  # 今回のプランに載っていない前回結果を退避する。プラン**全体**（resume で再利用へ
  # 倒れた観点を含む FULL_EXECUTION_PLAN）を基準にする — 実行分だけの
  # EXECUTION_PLAN で判定すると、resume が直前にキャッシュから書き戻した結果を
  # 自分で退避してしまう。レポートも main で FULL_EXECUTION_PLAN へ戻してから
  # 反復するので、「今回のもの」の定義が両者で一致する。
  quarantine_unplanned_outputs || return 2

  if [[ -z "$EXECUTION_PLAN" ]]; then
    echo "♻️  All ${TASK_TYPE} tasks were restored from the validated resume cache." >&2
    return 0
  fi

  local pids=""
  local failed=0
  local count=0
  local seen=""
  FAILED_TASKS=""
  SKIPPED_TASKS=""
  DELEGATED_TASKS=""
  POISONED_CLIS=""

  # review だけ: タスクを 1 つでも起動する前に「完了までツリーを触らない」バナーを
  # 1 回出す。ツリーが動いた実行の破棄（verify_repo_unchanged）は**事後検出**で、
  # 着手前に注意を促さないと数分のレビューが丸ごと無駄になる再発が起きていた。
  # 破棄ロジックは並列・逐次のどちらの経路でも同じように走るので、バナーもこの
  # 分岐の**外**で出す（片方の経路にしか置かないと、出ないほうで同じ事故が再発する）。
  # explore / implement では出さない（review 限定）。破棄ロジック・終了コードは変えない。
  if [[ "$TASK_TYPE" == "review" ]]; then
    # HEAD は起動時に固定した基準（REPO_SNAPSHOT_BEFORE の第 1 フィールド＝フル SHA）
    # から作る。ここで HEAD を引き直すと、baseline を取ってからバナーを出すまでの間に
    # HEAD が動いた場合に、破棄診断の「HEAD: <前> → <後>」の <前> と食い違う値を
    # 見せてしまう。短縮は記録済みの SHA を引くだけなので HEAD の移動に影響されない。
    local banner_head="n/a"
    if [[ -n "$REPO_SNAPSHOT_BEFORE" ]]; then
      local banner_head_full="${REPO_SNAPSHOT_BEFORE%% *}"
      case "$banner_head_full" in
        unborn) banner_head="unborn" ;;
        *)
          banner_head="$(git rev-parse --short "$banner_head_full" 2>/dev/null || printf '%s' "${banner_head_full:0:12}")"
          [[ -n "$banner_head" ]] || banner_head="n/a"
          ;;
      esac
    fi
    # 進行表示はこのスクリプトでは一貫して stderr（直後の "⏳ Waiting for" と同じ）。
    # stdout は結果を受け取る側のものなので、注意喚起をそちらへ混ぜない。
    echo "⚠️  完了まで worktree を変更しないでください（commit / push / checkout / 編集）。変更を検出すると結果は全破棄されます（HEAD: ${banner_head}）" >&2
    # バナーと同じ地点で機械可読の宣言も置く。読まれないバナーの
    # 代わりに hook が読む。観点一覧は今回のプラン**全体**（resume で再利用へ倒れた
    # 観点を含む FULL_EXECUTION_PLAN）から作る — 利用者から見て「走っているレビュー」
    # はレポートに載る観点の集合であって、実行したタスクだけではない。
    local in_flight_perspectives="" in_flight_seen="" plan_entry plan_persp
    while IFS= read -r plan_entry; do
      [[ -n "$plan_entry" ]] || continue
      plan_persp="${plan_entry#*:}"
      list_contains "$in_flight_seen" "$plan_persp" && continue
      in_flight_seen="${in_flight_seen:+${in_flight_seen} }${plan_persp}"
      in_flight_perspectives="${in_flight_perspectives:+${in_flight_perspectives},}${plan_persp}"
    done <<< "$FULL_EXECUTION_PLAN"
    write_run_in_flight "$TASK_TYPE" "${REPO_SNAPSHOT_BEFORE%% *}" "$in_flight_perspectives"
  fi

  # 並列起動の直前に負荷を実測する（閾値超なら今回だけ逐次へ倒す）。
  apply_load_gate || return 2

  if [[ "$PARALLEL" == "true" ]]; then
    # ── 並列実行: CLI 間は並列、同一 CLI 内は逐次（Issue `#251`） ──
    # minimize_cost が premium の観点を最安 tier へ振り替えると、同一 CLI
    # （現行の振替先は flat-rate の grok-cli — issue `#783` で free-tier が消えた後の
    # 最安 tier）へ複数観点が集中する。本ツールは
    # 実行時 fallback を意図的に持たないため、throttle されたタスクは別 CLI で
    # 再実行されず**その観点のカバレッジがゼロ**になる — 同一 CLI への同時 burst を
    # 作らないことが防御になる。CLI が違えばレート制限は独立なので並列のまま。
    # status dir は実行ごとに一意にする — 固定パスだと同じ OUTPUT_DIR を使う
    # 並行実行が互いの rc を削除・混同する。一意化は mktemp ではなく自 PID で行う
    # — orchestrator は mktemp を呼ばない、がこのスクリプトの検査済み契約で
    # （multi-agent-timeout suite の tmpdir ケースは「mktemp が壊れても落ちるのは
    # アダプタ側だけ」を固定している）、並行実行は別プロセス = 別 PID なので
    # 一意性はこれで足りる。同一 PID の残骸（過去のクラッシュ）は先に消す。
    local status_dir="${OUTPUT_DIR}/.task-rc.$$"
    rm -rf "$status_dir"
    if ! mkdir -p "$status_dir"; then
      echo "ERROR: cannot create task-status directory: ${status_dir}" >&2
      return 1
    fi

    local group_clis=""
    while IFS= read -r entry; do
      [[ -z "$entry" ]] && continue
      # Skip a duplicate plan entry so the same cli:perspective is not executed
      # twice (a plan fallback can list it more than once).
      if [[ " $seen " == *" $entry "* ]]; then continue; fi
      seen="$seen $entry"
      count=$((count + 1))
      local cli="${entry%%:*}"
      if ! list_contains "$group_clis" "$cli"; then
        group_clis="${group_clis:+$group_clis }$cli"
      fi
    done <<< "$EXECUTION_PLAN"

    # minimize_cost の振替で観点が集中したときだけ、振替先 tier（flat-rate）の CLI を
    # 1 本の逐次ワーカーへ（balanced 等では flat-rate も従来どおりタスク並列 — 自前の
    # 2 観点は集中ではなく常態のため。レビュー指摘で strategy 条件を追加）。それ以外は
    # 従来どおりタスク単位で並列。
    # pid と並行してラベル（worker:<cli> / task:<cli>/<persp>。空白を含まない）を
    # 記録する — rc ファイル不在の失敗で「どのプロセスが・どの rc で死んだか」を
    # 相関できるのはこの対応表だけ（wait の rc は下で回収して報告する）。
    local serialized_clis="" pid_labels=""
    local group_cli
    for group_cli in $group_clis; do
      if [[ "$STRATEGY" == "minimize_cost" && "$(get_cli_cost_tier "$group_cli")" == "flat-rate" ]]; then
        serialized_clis="${serialized_clis:+$serialized_clis }$group_cli"
        run_cli_group "$group_cli" "$status_dir" &
        pids="${pids:+$pids }$!"
        pid_labels="${pid_labels:+$pid_labels }worker:${group_cli}"
      fi
    done
    local spawn_seen=""
    while IFS= read -r entry; do
      [[ -z "$entry" ]] && continue
      if [[ " $spawn_seen " == *" $entry "* ]]; then continue; fi
      spawn_seen="$spawn_seen $entry"
      local spawn_cli="${entry%%:*}"
      if list_contains "$serialized_clis" "$spawn_cli"; then continue; fi
      run_task_recorded "$spawn_cli" "${entry#*:}" "$status_dir" &
      pids="${pids:+$pids }$!"
      pid_labels="${pid_labels:+$pid_labels }task:${spawn_cli}/${entry#*:}"
    done <<< "$EXECUTION_PLAN"

    if [[ -n "$serialized_clis" ]]; then
      # 公開ユーザーの端末へ毎回出る行なので、SSOT 側の Issue 番号は書かない
      # （公開リポジトリでは独立採番のため無関係な Issue を指す）。追跡はコメントで。
      echo "⏳ Waiting for ${count} ${TASK_TYPE} task(s) — flat-rate CLI(s) run their tasks sequentially (rate-limit protection):${serialized_clis:+ }${serialized_clis}" >&2
    else
      echo "⏳ Waiting for ${count} parallel ${TASK_TYPE} tasks..." >&2
    fi
    # wait の rc は成否の情報源ではない（rc ファイルが単一情報源）が、外部 kill 等で
    # ワーカーが記録前に死んだときの唯一の死因なので、非 0 は名指しで残す。
    set +e
    local pid wait_idx=0 wrc wlabel
    for pid in $pids; do
      wait_idx=$((wait_idx + 1))
      wait "$pid"
      wrc=$?
      if [[ $wrc -ne 0 ]]; then
        # shellcheck disable=SC2086 # one whitespace-delimited label per worker
        wlabel="$(printf '%s\n' $pid_labels | awk -v n="$wait_idx" 'NR == n')"
        echo "  ⚠️ ${wlabel:-worker} exited with rc=${wrc} — tasks it had not recorded yet will be counted as failed below" >&2
      fi
    done
    set -e

    # 回収は計画順。rc ファイルが無い = ワーカーが記録前に死んだ（kill・クラッシュ）
    # 形で、これも失敗として数える — 沈黙の未実行を「成功」に見せない。
    local collect_seen=""
    while IFS= read -r entry; do
      [[ -z "$entry" ]] && continue
      if [[ " $collect_seen " == *" $entry "* ]]; then continue; fi
      collect_seen="$collect_seen $entry"
      local cli="${entry%%:*}"
      local persp="${entry#*:}"
      local task_name="${cli}/${persp}"
      local rc_file="${status_dir}/${cli}/${persp}.rc"
      local skip_file="${status_dir}/${cli}/${persp}.skip"
      local exit_code
      # スキップは rc の判定より**前**に見る（Issue `#1143`）。スキップしたタスクは
      # rc ファイルを書かないので、順序を逆にすると「ワーカーが記録前に死んだ」へ
      # 落ちて、理由が失われたうえに死因の追跡へ読み手を送る。
      if [[ -f "$skip_file" ]]; then
        local skip_cause
        skip_cause="$(cat "$skip_file" 2>/dev/null)" || skip_cause=""
        if ! cli_failure_is_deterministic "$skip_cause"; then
          # 印が読めない / 想定外の値。スキップは実行の欠落なので、理由が確定
          # できないものを「意図したスキップ」として通さない（失敗側へ倒す）。
          failed=$((failed + 1))
          FAILED_TASKS="${FAILED_TASKS:+$FAILED_TASKS }${task_name}:1"
          echo "  ❌ Unreadable skip marker (content='${skip_cause}'): ${task_name}" >&2
          continue
        fi
        failed=$((failed + 1))
        SKIPPED_TASKS="${SKIPPED_TASKS:+$SKIPPED_TASKS }${task_name}:${skip_cause}"
        continue
      fi
      if [[ ! -f "$rc_file" ]]; then
        failed=$((failed + 1))
        FAILED_TASKS="${FAILED_TASKS:+$FAILED_TASKS }${task_name}:1"
        echo "  ❌ Worker died before recording a status: ${task_name}" >&2
        continue
      fi
      # 読めない・空・非数値の rc は「判定不能」として失敗へ倒す。bash 3.2 の
      # [[ "" -eq 0 ]] は真、英字は unbound variable で set -e 即死のため、
      # 数値検証を通してからでないと -eq 比較に入れられない。
      exit_code="$(cat "$rc_file" 2>/dev/null)" || exit_code=""
      if ! [[ "$exit_code" =~ ^[0-9]+$ ]]; then
        failed=$((failed + 1))
        FAILED_TASKS="${FAILED_TASKS:+$FAILED_TASKS }${task_name}:1"
        echo "  ❌ Corrupt/empty status file (content='${exit_code}'): ${task_name}" >&2
        continue
      fi
      if [[ "$exit_code" -eq 0 && -f "${OUTPUT_DIR}/${task_name}.md" ]]; then
        echo "  ✅ Done: ${task_name}" >&2
        if ! cache_task_result "$cli" "$persp"; then
          failed=$((failed + 1))
          FAILED_TASKS="${FAILED_TASKS:+$FAILED_TASKS }${task_name}:1"
          echo "  ❌ Cannot persist completed resume cache: ${task_name}" >&2
        fi
      elif [[ "$exit_code" -eq "$DELEGATION_PENDING_EXIT_CODE" ]] && task_is_delegated "$cli"; then
        # 委譲済み・結果待ち。失敗にも成果物なしにも数えない — CLI は
        # 1 つも起動しておらず、調べるべきクラッシュも、再実行で埋まる打ち切りも無い。
        # レーン束縛を条件へ入れてあるので、委譲していない CLI が偶然 123 を返した場合は
        # 従来どおり失敗として扱う（fail-safe 側）。
        DELEGATED_TASKS="${DELEGATED_TASKS:+$DELEGATED_TASKS }${task_name}"
        echo "  🤝 Delegated (pending host): ${task_name}" >&2
      elif [[ "$exit_code" -ne 0 ]]; then
        failed=$((failed + 1))
        FAILED_TASKS="${FAILED_TASKS:+$FAILED_TASKS }${task_name}:${exit_code}"
        report_task_failure "$task_name" "$exit_code"
      else
        # Success exit but no output file — surface as a failure, not silent OK.
        # 書き込み失敗はもうここへ来ない（write_output が rc へ載せ、アダプタが 125 で
        # 落ちる）。この分岐はそれ以外の「0 を返したのに成果物が無い」退行のための砦
        # として残す — 埋めてしまうと、次に同型が生えたとき静かに成功として通る。
        failed=$((failed + 1))
        FAILED_TASKS="${FAILED_TASKS:+$FAILED_TASKS }${task_name}:0"
        echo "  ❌ No output file: ${task_name}" >&2
      fi
    done <<< "$EXECUTION_PLAN"
    rm -rf "$status_dir"
  else
    while IFS= read -r entry; do
      [[ -z "$entry" ]] && continue
      # Skip a duplicate plan entry so the same cli:perspective is not executed
      # twice (a plan fallback can list it more than once).
      if [[ " $seen " == *" $entry "* ]]; then continue; fi
      seen="$seen $entry"
      local cli="${entry%%:*}"
      local persp="${entry#*:}"

      # 先行タスクが auth / billing で落ちた CLI の残りは実行しない（Issue `#1143`）。
      # 逐次ブランチはループ自体が親プロセスなので、ステータス dir を経由せず
      # そのまま SKIPPED_TASKS へ記録する。
      local seq_cause
      seq_cause="$(skipped_cli_cause "$cli")"
      if [[ -n "$seq_cause" ]]; then
        failed=$((failed + 1))
        SKIPPED_TASKS="${SKIPPED_TASKS:+$SKIPPED_TASKS }${cli}/${persp}:${seq_cause}"
        echo "  ⏭ Skipped ${cli}/${persp} — ${cli} already failed in this run for a ${seq_cause} reason (not task-specific)." >&2
        continue
      fi

      echo "▶ ${cli} → ${persp}" >&2
      # Capture the status rather than testing it inline: the parallel branch
      # distinguishes a fired deadline from a crash, and this path has to give the
      # same diagnosis or the reason depends on which mode you happened to run.
      local task_rc=0
      run_single_task "$cli" "$persp" || task_rc=$?
      if [[ $task_rc -eq "$DELEGATION_PENDING_EXIT_CODE" ]] && task_is_delegated "$cli"; then
        # 並列経路と同じ扱い。片方の経路にだけ置くと、実行モードを
        # 変えただけで「委譲待ち」が「失敗」に化ける。
        DELEGATED_TASKS="${DELEGATED_TASKS:+$DELEGATED_TASKS }${cli}/${persp}"
        echo "  🤝 Delegated (pending host): ${cli}/${persp}" >&2
      elif [[ $task_rc -ne 0 ]]; then
        failed=$((failed + 1))
        FAILED_TASKS="${FAILED_TASKS:+$FAILED_TASKS }${cli}/${persp}:${task_rc}"
        report_task_failure "${cli}/${persp}" "$task_rc"
        # この CLI の残タスクを落とすかどうかは、失敗のたびに判定する（Issue `#1143`）。
        # 124（timeout）は除く — 案内層と同じ規則（print_failure_advice は 124 の
        # とき分類を断定材料にしない）。時間を足せば通る失敗でカバレッジを捨てない。
        local seq_fail_cause
        if [[ $task_rc -ne 124 ]]; then
          seq_fail_cause="$(classify_cli_failure_cause "${OUTPUT_DIR}/${cli}/${persp}.md")"
          if cli_failure_is_deterministic "$seq_fail_cause"; then
            POISONED_CLIS="${POISONED_CLIS:+$POISONED_CLIS }${cli}:${seq_fail_cause}"
          fi
        fi
      elif [[ ! -f "${OUTPUT_DIR}/${cli}/${persp}.md" ]]; then
        # 並列側と同じ砦（write_output の失敗は 125 で来るので、ここは別経路用）。
        # Adapter reported success but wrote no output — count it as a failure so
        # a silently-empty run shows up in the exit code, not only the report.
        failed=$((failed + 1))
        FAILED_TASKS="${FAILED_TASKS:+$FAILED_TASKS }${cli}/${persp}:0"
        echo "  ❌ No output file: ${cli}/${persp}" >&2
      elif ! cache_task_result "$cli" "$persp"; then
        failed=$((failed + 1))
        FAILED_TASKS="${FAILED_TASKS:+$FAILED_TASKS }${cli}/${persp}:1"
        echo "  ❌ Cannot persist completed resume cache: ${cli}/${persp}" >&2
      fi
    done <<< "$EXECUTION_PLAN"
  fi

  echo "" >&2
  local skipped_count=0 entry_count
  for entry_count in $SKIPPED_TASKS; do
    skipped_count=$((skipped_count + 1))
  done
  local failed_only=$((failed - skipped_count))
  [[ "$failed_only" -ge 0 ]] || failed_only=0
  local delegated_count=0 delegated_entry
  for delegated_entry in $DELEGATED_TASKS; do
    delegated_count=$((delegated_count + 1))
  done
  collect_unavailable_cross_tasks
  local unavailable_entry
  if [[ $failed -gt 0 ]] && all_failures_unavailable_cross; then
    # 失敗・スキップのすべてが主担当以外の利用不可。主担当の結果で
    # 完了させる。使えるようにする手順は print_failure_advice が 🔑 / 💳 / 🚫 で添える。
    echo "ℹ️  Completed with the main reviewer (${REVIEW_MAIN}) only: the second CLI was unavailable" >&2
    echo "   (authentication / credits / unsupported model). Not a failure — the next run tries it again." >&2
    for unavailable_entry in $UNAVAILABLE_CROSS_TASKS; do
      echo "     ⏭ ${unavailable_entry%:*} — $(cause_phrase "${unavailable_entry##*:}")" >&2
    done
    if [[ $delegated_count -gt 0 ]]; then
      echo "🤝 ${delegated_count} ${TASK_TYPE} task(s) delegated to the host and still pending." >&2
    fi
    print_failure_advice || true
    return 0
  elif [[ $failed -gt 0 ]]; then
    if [[ $skipped_count -gt 0 ]]; then
      echo "⚠️  ${failed_only} ${TASK_TYPE} task(s) failed, ${skipped_count} not executed (skipped)." >&2
    else
      echo "⚠️  ${failed} ${TASK_TYPE} task(s) failed." >&2
    fi
    print_failure_advice
    return 1
  elif [[ $delegated_count -gt 0 ]]; then
    # 「全部成功」と名乗らない。委譲したタスクはまだ結果を持っておらず、
    # 統合レポートにもその観点は pending として載る。
    echo "🤝 ${delegated_count} ${TASK_TYPE} task(s) delegated to the host and still pending; every other task completed." >&2
  else
    echo "✅ All ${TASK_TYPE} tasks completed successfully." >&2
  fi
}

# ── 実行中にレビュー対象が動いていないことの検証 ──
#
# 実行開始時に取ったスナップショットと突き合わせ、一致しなければ結果を破棄する。
# 警告に留めない理由: この機構が守っているのは「レポートの内容」ではなく「レポートを
# 信じてよいかどうか」で、信じてよいか分からない結果を exit 0 で返すのは、この Issue が
# 塞ごうとしている silent failure そのもの。
#
# 検出できない形は 1 つではない。既知のものを明示しておく:
#   - 実行中に動いて**元へ戻された**変化（前後比較の原理的な限界）
#   - gitignore 済みパスへの書き込み、除外パス配下の変化、内容を読めない untracked
#     エントリの中身（capture_repo_snapshot の「見えないものを明示しておく」の項）
#
# 往復のケースで固定 diff が守るのは**プロンプトへ載る diff のバイト列**までで、
# 「往復を受け持つ」わけではない。その区間にエージェントが直接読んだ作業ツリーの
# ファイル実体は、固定 diff でも前後比較でも守れず、既知の穴として残る。
# それでも 2 つで 1 組にする意味はある — 固定 diff は往復中も diff を動かさず、
# 前後比較は往復しない変化（大多数）を捕らえるので、片方だけより穴が小さい。
# 破棄した実行の成果物を「完成した結果」に見せない。
#
# レポートを書かないだけでは足りない。個別結果 ${cli}/${persp}.md はタスクが書いた
# 時点でディスクに残り、ヘッダーは `Status: complete` のままになる。しかもそのパスは
# skills/multi-review/SKILL.md が「結果は後から参照できる」と案内している場所そのもの
# で、破棄を宣言した直後に完成扱いの結果が同じ場所に並ぶ。消さずに印を付けるのは、
# CLI に払ったぶんの出力を証跡として残すため。
mark_outputs_discarded() {
  local entry cli persp f tmp
  while IFS= read -r entry; do
    [[ -z "$entry" ]] && continue
    cli="${entry%%:*}"
    persp="${entry#*:}"
    f="${OUTPUT_DIR}/${cli}/${persp}.md"
    [[ -f "$f" ]] || continue
    tmp="${f}.discarding.$$"
    # 差し替えは ASCII のみのパターンで行う（ロケール依存の text 処理を持ち込まない）。
    if { printf '%s\n\n' "> DISCARDED — the repository changed while this run was in flight. Nothing below was verified against a stable revision; do not read it as a finished ${TASK_TYPE}." \
         && sed 's/^<!-- Status: complete -->$/<!-- Status: discarded -->/' "$f"; } > "$tmp" 2>/dev/null \
       && mv "$tmp" "$f"; then
      continue
    fi
    rm -f "$tmp" 2>/dev/null || true
    echo "  could not mark as discarded: ${f}" >&2
  done <<< "$EXECUTION_PLAN"
}

report_discarded_output_paths() {
  local entry cli persp f reported=false
  # Only name files that were actually written. A failed task can leave no file,
  # and telling the user to preserve a path that does not exist hides that fact.
  while IFS= read -r entry; do
    [[ -z "$entry" ]] && continue
    cli="${entry%%:*}"
    persp="${entry#*:}"
    f="${OUTPUT_DIR}/${cli}/${persp}.md"
    [[ -f "$f" ]] || continue
    if [[ "$reported" == "false" ]]; then
      echo "   The discarded per-task results are kept as evidence — read them before anything else:" >&2
      reported=true
    fi
    printf '     %s\n' "$f" >&2
  done <<< "$EXECUTION_PLAN"
  if [[ "$reported" == "true" ]]; then
    echo "   Re-running clears these files first, so read or copy them now." >&2
  fi
}

# ── 除外に一致した変化の報告（Issue `#747`） ──
#
# 除外パス配下の変化は判定から消えるが、**黙って消してはいけない** — 実行ログから
# 「ガードが緩んだのか、本当に何も変わっていないのか」を区別できなくなる
# （merge-cleanup の report_ignored_changes と同じ原則）。判定後に status を
# 肯定形の同じパターンで引き直し、件数と一覧を出す:
#   - 利用者指定（FF_MULTI_AGENT_IGNORE_PATHS）… 一致 0 件でもその旨を出す。
#     「設定したのに何も変わらない」の原因がパターンの書き間違いだと分かるように
#   - 既定（.superpowers/**）… 一致があるときだけ 1 行 + 一覧。無いのが通常なので
#     毎回のログを占有しない
# status の失敗は非 0 で返す — 呼び出し側（verify_repo_unchanged）が破棄へ倒す。
# 「除外した中身を確認できない」は「除外が正しく効いたか分からない」と同じで、
# 分からないまま成功を名乗るのはこのガードが塞いでいる silent failure そのもの。
report_ignored_tree_changes() {
  [[ "$IN_GIT_REPO" == "true" ]] || return 0
  local root ignored count
  if ! root="$(cd "$REPO_ROOT" 2>/dev/null && pwd -P)"; then
    echo "ERROR: cannot resolve the repository root to list ignored tree changes." >&2
    return 1
  fi
  if [[ "${#IGNORE_MATCH_PATHSPECS[@]}" -gt 0 ]]; then
    # 全体一致の :(top) を先頭に置いてから肯定形を並べる意味は無い（こちらは除外では
    # なく選択）。CWD 相対に縮まないよう root へ cd してから引く（capture_repo_snapshot
    # と同じ理由）。
    if ! ignored="$(cd "$root" && git status --porcelain -- "${IGNORE_MATCH_PATHSPECS[@]}")"; then
      echo "ERROR: cannot list the changes matched by FF_MULTI_AGENT_IGNORE_PATHS." >&2
      return 1
    fi
    if [[ -z "$ignored" ]]; then
      echo "ℹ️ No uncommitted changes match FF_MULTI_AGENT_IGNORE_PATHS (patterns are repo-root-relative globs: '${FF_MULTI_AGENT_IGNORE_PATHS:-}')" >&2
    else
      count="$(printf '%s\n' "$ignored" | wc -l | tr -d ' ')" || {
        echo "ERROR: cannot count the changes matched by FF_MULTI_AGENT_IGNORE_PATHS." >&2
        return 1
      }
      echo "ℹ️ Excluded from the tree-change check: ${count} path(s) matched FF_MULTI_AGENT_IGNORE_PATHS" >&2
      printf '%s\n' "$ignored" | sed 's/^/  - /' >&2 || {
        echo "ERROR: cannot print the changes matched by FF_MULTI_AGENT_IGNORE_PATHS." >&2
        return 1
      }
    fi
  fi
  if ! ignored="$(cd "$root" && git status --porcelain -- ":(glob,top)${IGNORE_PATHS_DEFAULT}")"; then
    echo "ERROR: cannot list the changes matched by the default ignore pattern '${IGNORE_PATHS_DEFAULT}'." >&2
    return 1
  fi
  if [[ -n "$ignored" ]]; then
    count="$(printf '%s\n' "$ignored" | wc -l | tr -d ' ')" || {
      echo "ERROR: cannot count the changes matched by the default ignore pattern '${IGNORE_PATHS_DEFAULT}'." >&2
      return 1
    }
    echo "ℹ️ Default exclusion '${IGNORE_PATHS_DEFAULT}' kept ${count} changed path(s) out of the tree-change check" >&2
    printf '%s\n' "$ignored" | sed 's/^/  - /' >&2 || {
      echo "ERROR: cannot print the changes matched by the default ignore pattern '${IGNORE_PATHS_DEFAULT}'." >&2
      return 1
    }
  fi
  return 0
}

verify_repo_unchanged() {
  local after
  if ! after="$(capture_repo_snapshot "$(output_dir_repo_relative)" "${IGNORE_EXCLUDE_PATHSPECS[@]}")"; then
    echo "" >&2
    echo "❌ Cannot read the repository state after the run — discarding the result." >&2
    echo "   The baseline was taken, so this is a failure to verify, not a clean run:" >&2
    echo "   nothing here can confirm the reviewed revision stayed put. Reporting an" >&2
    echo "   unverifiable run as valid is the exact failure this guard exists to prevent." >&2
    mark_outputs_discarded
    echo "   No report was generated; this run's per-task results are marked DISCARDED." >&2
    report_discarded_output_paths
    echo "   Re-run once the repository is settled." >&2
    return 1
  fi

  # 除外に一致した変化を名指しする（黙って無視しない）。この一覧が取れないなら、
  # 除外が正しく効いたかどうかも確認できていない — スナップショット不能と同じく
  # fail-closed で破棄する（Issue `#747`）。
  if ! report_ignored_tree_changes; then
    echo "" >&2
    echo "❌ Cannot list the changes excluded from the tree-change check — discarding the result." >&2
    echo "   Without that listing there is no way to confirm the exclusion worked as" >&2
    echo "   configured, so this run cannot be verified (same as an unreadable snapshot)." >&2
    mark_outputs_discarded
    echo "   No report was generated; this run's per-task results are marked DISCARDED." >&2
    report_discarded_output_paths
    echo "   Re-run once the repository is settled." >&2
    return 1
  fi

  [[ "$after" == "$REPO_SNAPSHOT_BEFORE" ]] && return 0

  # どこが動いたのかを名指しする。3 つのうちどれが変わったかで利用者の次の一手が
  # まったく違う（ブランチを戻す / commit を戻す / 作業ツリーを片付ける）。
  local b_head b_branch b_tree a_head a_branch a_tree
  read -r b_head b_branch b_tree <<< "$REPO_SNAPSHOT_BEFORE"
  read -r a_head a_branch a_tree <<< "$after"

  echo "" >&2
  echo "❌ The repository changed while the ${TASK_TYPE} was running — discarding the result." >&2
  if [[ "$b_branch" != "$a_branch" ]]; then
    echo "   branch:   ${b_branch} → ${a_branch}" >&2
  fi
  if [[ "$b_head" != "$a_head" ]]; then
    echo "   HEAD:     ${b_head} → ${a_head}" >&2
  fi
  if [[ "$b_tree" != "$a_tree" ]]; then
    echo "   worktree: changed (tracked and untracked files, excluding the output dir)" >&2
  fi
  echo "" >&2
  echo "   Tasks read the working tree while they run, so what each one actually looked" >&2
  echo "   at is now unknown — and a report built from that would read as a clean result." >&2
  mark_outputs_discarded
  echo "   No report was generated; this run's per-task results are marked DISCARDED" >&2
  echo "   so they cannot be mistaken for a finished ${TASK_TYPE}." >&2
  report_discarded_output_paths
  echo "   Re-run once the repository is settled." >&2
  return 1
}

# 読み込み完了の印（multi-agent.sh の読み込み部が照合する。最後の行に置く）
_ma_part_loaded="multi-agent-execute.sh"
