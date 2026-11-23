#!/usr/bin/env bash
# Grok のレビュー実行と同じセッションの状態だけを表示する。
# 読み取りは Grok が記録するイベントの日時・種類・フェーズに限定する。
readonly GROK_REVIEW_PROGRESS_TAIL_LINES=64
readonly GROK_REVIEW_PROGRESS_INTERVAL_SECONDS=10

grok_review_session_id() {
  if command -v uuidgen >/dev/null 2>&1; then
    uuidgen | LC_ALL=C tr '[:upper:]' '[:lower:]'
  elif command -v node >/dev/null 2>&1; then
    node -p 'require("node:crypto").randomUUID()'
  else
    return 1
  fi
}

grok_review_latest_progress() {
  local event_file="$1"
  [[ -f "$event_file" && ! -L "$event_file" ]] || return 0
  tail -n "$GROK_REVIEW_PROGRESS_TAIL_LINES" "$event_file" 2>/dev/null |
    jq -rRs '
      [split("\n")[] | fromjson? | objects | select(.ts | type == "string")
      | if .type == "phase_changed" then
          select(.phase == "streaming_reasoning" or .phase == "waiting_for_model"
                 or .phase == "streaming_text" or .phase == "tool_execution"
                 or .phase == "permission_prompt") | [.ts, .phase]
        elif .type == "tool_completed" then [.ts, "tool_completed"]
        else empty end] | last // empty | @tsv'
}

grok_review_phase_label() {
  case "$1" in
    streaming_reasoning) printf '%s' '推論中' ;;
    waiting_for_model) printf '%s' 'モデルの応答を待機中' ;;
    streaming_text) printf '%s' 'レビュー結果を生成中' ;;
    tool_execution) printf '%s' 'ツールを実行中' ;;
    permission_prompt) printf '%s' 'ツールの実行可否を確認中' ;;
    tool_completed) printf '%s' 'ツール実行が終了' ;;
  esac
}

watch_grok_review_progress() {
  local event_file="$1"
  local start="$SECONDS" previous="" latest="" label=""
  while sleep "$GROK_REVIEW_PROGRESS_INTERVAL_SECONDS"; do
    latest="$(grok_review_latest_progress "$event_file" 2>/dev/null)" || latest=""
    if [[ -z "$latest" ]]; then
      label="進捗イベントを確認できません"
    elif [[ "$latest" == "$previous" ]]; then
      label="進捗イベントの更新を待機中"
    else
      label="$(grok_review_phase_label "${latest#*$'\t'}")"
    fi
    printf '   Grok CLI: %s（経過 %s 秒）\n' "$label" "$((SECONDS - start))" >&2
    previous="$latest"
  done
}

stop_grok_progress_monitor() {
  local monitor_pid="$1"
  kill -KILL -- -"$monitor_pid" 2>/dev/null || kill -KILL "$monitor_pid" 2>/dev/null || true
  wait "$monitor_pid" 2>/dev/null || true
}

run_grok_review_with_progress() {
  local event_file="$1" monitor_pid
  shift
  # 進捗を独自のグループに置く。ログ読み取りの停止を待つ間に CLI を期限切れにしない。
  {
    set -m
    (set +m; watch_grok_review_progress "$event_file") </dev/null >/dev/null 2>&3 3>&- &
    monitor_pid=$!
    set +m
  } 2>/dev/null
  # この関数の呼び出し元はレビュー実行専用のコマンド置換。
  trap 'stop_grok_progress_monitor '"$monitor_pid" EXIT
  run_with_timeout "$@" 3>&-
}
