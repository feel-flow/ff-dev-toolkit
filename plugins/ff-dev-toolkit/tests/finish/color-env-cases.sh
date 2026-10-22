#!/usr/bin/env bash
# finish suite の共有 Git / gh fixture で、precheck の JSON 各境界の環境を測る。
# gh の応答だけを stub にし、precheck・jq・鮮度照合は実体を使う。

_ff_finish_color_cases() {
  local color_original_gh="$BIN/gh" BIN="$TMP/color-bin" color_log="$TMP/color-env.tsv"
  local color_cases="force clicolor-force clicolor all" color_case color_count=0 color_before color_after
  local color_control color_control_rc color_parse_rc color_initial_env color_expected_env
  local FORCE_COLOR CLICOLOR_FORCE CLICOLOR NO_COLOR
  local STUB_COLOR_ORIGINAL_GH="$color_original_gh" STUB_COLOR_ENV_LOG="$color_log"
  export STUB_COLOR_ORIGINAL_GH STUB_COLOR_ENV_LOG
  mkdir -p "$BIN"
  cat >"$BIN/gh" <<'COLOR_GH'
#!/usr/bin/env bash
set -uo pipefail
printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$1 $2" "${5:-}" \
  "${FORCE_COLOR+x}" "${CLICOLOR_FORCE+x}" "${CLICOLOR+x}" "${NO_COLOR+x}" "${NO_COLOR-}" \
  >>"${STUB_COLOR_ENV_LOG:?}"
case "$1 $2" in
  'pr view'|'repo view'|'api graphql')
    # 現行の実 gh でも、CLICOLOR_FORCE は pipe と NO_COLOR より優先される。
    # FORCE_COLOR 単独の着色を実 gh で再現したとは扱わない。
    if [ -n "${CLICOLOR_FORCE:-}" ] && [ "${CLICOLOR_FORCE}" != 0 ]; then
      color_json="$("${STUB_COLOR_ORIGINAL_GH:?}" "$@")"; color_rc=$?
      [ "$color_rc" -eq 0 ] || exit "$color_rc"
      printf '%s\n' "$color_json" | jq -C .
      exit $?
    fi
    ;;
esac
exec "${STUB_COLOR_ORIGINAL_GH:?}" "$@"
COLOR_GH
  chmod +x "$BIN/gh"
  write_pr_json "Closes #${PRN}" '[{"name":"lint","conclusion":"SUCCESS"}]'
  : >"$color_log"
  color_control_rc=0
  color_control="$(CLICOLOR_FORCE=1 NO_COLOR=1 "$BIN/gh" pr view "$PRN" --json state)" || color_control_rc=$?
  color_parse_rc=0
  printf '%s\n' "$color_control" | jq -e . >/dev/null 2>&1 || color_parse_rc=$?
  case "$color_control" in
    *$'\033['*)
      if [ "$color_control_rc" -eq 0 ] && [ "$color_parse_rc" -ne 0 ]; then
        ok "COLOR0: 対照の CLICOLOR_FORCE は JSON に ANSI を出し、実 jq が拒否する"
      else
        bad "COLOR0: 着色対照が成立しない（gh=${color_control_rc} jq=${color_parse_rc}）"
      fi ;;
    *) bad "COLOR0: 着色対照に ANSI が無い（針が着色経路へ届いていない）" ;;
  esac

  for color_case in $color_cases; do
    color_count=$((color_count + 1))
    unset FORCE_COLOR CLICOLOR_FORCE CLICOLOR
    NO_COLOR=1; export NO_COLOR
    case "$color_case" in
      force) FORCE_COLOR=1; export FORCE_COLOR; color_expected_env='x:1|:|:|x:1' ;;
      clicolor-force) CLICOLOR_FORCE=1; export CLICOLOR_FORCE; color_expected_env=':|x:1|:|x:1' ;;
      clicolor) CLICOLOR=1; export CLICOLOR; color_expected_env=':|:|x:1|x:1' ;;
      all) FORCE_COLOR=1; CLICOLOR_FORCE=1; CLICOLOR=1; export FORCE_COLOR CLICOLOR_FORCE CLICOLOR; color_expected_env='x:1|x:1|x:1|x:1' ;;
      *) bad "COLOR fixture: 未知のケース ${color_case}"; continue ;;
    esac
    color_before="${FORCE_COLOR+x}:${FORCE_COLOR-}|${CLICOLOR_FORCE+x}:${CLICOLOR_FORCE-}|${CLICOLOR+x}:${CLICOLOR-}|${NO_COLOR+x}:${NO_COLOR-}"
    # finish の除去処理より前に、実際の子プロセスへ届く入力の集合を確かめる。
    color_initial_env="$(bash -c 'printf "%s:%s|%s:%s|%s:%s|%s:%s" "${FORCE_COLOR+x}" "${FORCE_COLOR-}" "${CLICOLOR_FORCE+x}" "${CLICOLOR_FORCE-}" "${CLICOLOR+x}" "${CLICOLOR-}" "${NO_COLOR+x}" "${NO_COLOR-}"')"
    : >"$color_log"
    # watch の通信失敗を返し、成功済み checks の JSON 再取得にも必ず到達させる。
    STUB_CHECKS_TIMEOUT=1 run_finish "$WORK" precheck "$PRN"
    color_after="${FORCE_COLOR+x}:${FORCE_COLOR-}|${CLICOLOR_FORCE+x}:${CLICOLOR_FORCE-}|${CLICOLOR+x}:${CLICOLOR-}|${NO_COLOR+x}:${NO_COLOR-}"
    if [ "$RC" -eq 0 ] && has_line "$OUT" PRECHECK=ready && has_line "$OUT" PR_SNAPSHOT=unchanged \
      && has_line "$OUT" PR_HEAD_REF=feature/ && has_line "$OUT" "PR_HEAD_OID=${HEAD_OID}" \
      && has_line "$OUT" PR_BASE_REF=develop && has_line "$OUT" CHECKS=passed; then
      ok "COLOR1/${color_case}: 色の設定があっても head/base・checks・snapshot を読んで ready"
    else
      bad "COLOR1/${color_case}: JSON の読み取りが成立しない（rc=${RC}）: ${OUT} / ${ERR}"
    fi
    if awk -F '\t' '
      { n++; if (NF != 7 || $3 != "" || $4 != "" || $5 != "" || $6 != "x" || $7 != "1") invalid++ }
      $1 == "pr view" { pr++ }
      $1 == "pr view" && $2 == "statusCheckRollup" { checks_json++ }
      $1 == "repo view" { repo++ }
      $1 == "pr checks" { watch++ }
      $1 == "api graphql" { threads++ }
      END { exit !(n == 6 && pr == 3 && checks_json == 1 && repo == 1 && watch == 1 && threads == 1 && !invalid) }
    ' "$color_log"; then
      ok "COLOR2/${color_case}: gh 全6呼出しで3変数が未指定、NO_COLOR を保持（JSON 各境界へ到達）"
    else
      bad "COLOR2/${color_case}: gh の環境または対象経路が不足: $(cat "$color_log")"
    fi
    if [ "$color_initial_env" = "$color_expected_env" ] && [ "$color_before" = "$color_after" ]; then
      ok "COLOR3/${color_case}: 入力は指定ケースだけで、呼び出し元の設定を保持"
    else
      bad "COLOR3/${color_case}: 入力集合か呼び出し元の保持が不正（入力=${color_initial_env} 期待=${color_expected_env}）"
    fi
  done
  if [ "$color_count" -eq 4 ]; then
    ok "COLOR4: 色の設定4ケースを実行した"
  else
    bad "COLOR4: ケースが空か不足（期待4 / 実行${color_count}）"
  fi
  write_pr_json "Closes #${PRN}" '[]'
}
