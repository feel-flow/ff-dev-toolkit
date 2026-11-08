#!/usr/bin/env bash
# finish.sh の precheck 構成ファイル（専用セキュリティゲートの記録の判定。Issue `#2684`）。finish-precheck.sh と
# 同じく入口が検査して source する。関数の定義だけを置き、読み込み完了は末尾の sentinel で確認する。bash 3.2 互換。
# pipefail-inherited: finish.sh が set -uo pipefail の下で source する

if [[ "${_finish_precheck_loading:-}" != "1" ]]; then
  echo "finish-precheck-security-record.sh は finish.sh precheck から読み込んでください" >&2
  exit 2
fi

# ── 専用セキュリティゲートの記録 ──
# セキュリティに関わる変更の PR は、本文に専用セキュリティゲートの結果を 1 行残す（規定の正本は
# docs-template の self-review.md「レビュー担当の選択と利用制限時の継続」の専用セキュリティゲート項）。
# 散文の規定だけでは該当 14 件中 10 件で記録が落ちた（2026-11-07 実測）ので、全ホストが通るここで確かめる。
# 分類は review-route.sh に任せる（プロジェクト設定 review.security_* の解決を再実装しない）。記録を求めるのは
# REVIEW_SECURITY_GATE が none（該当なし）と off（security_review=off）以外の回。この 2 つは主担当ホストに
# 依らず決まる。分類できない回（変更ファイルを読めない・ルータの失敗・出力に判定行が無い）は該当なしへ
# 倒さず unknown として記録を求める。
# 下の helper は cmd_precheck の local（blocked_reason / blocked_next）と、finish-precheck.sh の
# ff_precheck_scan_lines / ff_precheck_pr_files を使う。

# stdin: PR 本文 / stdout: 記録として認める最初の行。認める形:
#   - キー `専用セキュリティゲート` が行頭（字下げ・リスト記号・番号・強調の後）にある。地の文の言及や
#     インラインコードの記入例は数えない。引用（`>`）の中も数えない — ff_precheck_scan_lines は `> ` 付きの
#     フェンスを認識しないので、引用の中のフェンスに置いた記入例が可視行として届く
#   - キーの後に（強調の `*` と空白を挟んで）`:` か `：` が続く
#   - 値の頭（最初の括弧 `（` / `(` の前）が「実施」「未確認」「未対応」で終わる。括弧の中（根拠の path・理由）の
#     語は数えない。「未実施」「実施しない」「を実施する」「実施予定」「対象外（… 実施せず）」と、review-route.sh の
#     報告行を貼っただけの「… を実行する（…）」（結果の無い計画行）は数えない
# フェンスと HTML コメントの中（PR テンプレートの記入例など）は数えない。バイトで比べる（LC_ALL=C）。
# 最初の一致の後も入力を最後まで読む — 途中で終わると上流が SIGPIPE で落ち、pipefail で一致を失う。
ff_precheck_security_record_line() {
  ff_precheck_scan_lines visible | LC_ALL=C awk '
    function ends(s, t) { return length(s) >= length(t) && substr(s, length(s) - length(t) + 1) == t }
    BEGIN { key = "専用セキュリティゲート"; colon = "："; paren = "（"; found = "" }
    found != "" { next }
    {
      i = index($0, key)
      if (!i) next
      if (substr($0, 1, i - 1) !~ /^[[:space:]*_+0-9.)-]*$/) next
      rest = substr($0, i + length(key))
      sub(/^[*_ ]*/, "", rest)
      if (substr(rest, 1, 1) == ":") rest = substr(rest, 2)
      else if (substr(rest, 1, length(colon)) == colon) rest = substr(rest, length(colon) + 1)
      else next
      head = rest
      j = index(head, paren); if (j) head = substr(head, 1, j - 1)
      j = index(head, "("); if (j) head = substr(head, 1, j - 1)
      sub(/[[:space:]*_]+$/, "", head)
      if (ends(head, "未実施")) next
      if (ends(head, "実施") || ends(head, "未確認") || ends(head, "未対応")) found = $0
    }
    END { if (found != "") print found }'
}

ff_precheck_security_record() { # <PR JSON> <base> <head OID> <PR 本文>
  local files="" files_rc=0 out="" route_rc=0 route_err="" errf sensitive="unknown" gate="" why="" line record=""
  local evidence="" first="" reason="" next=""
  files="$(ff_precheck_pr_files "$1" "$2" "$3")" || files_rc=$?
  files="${files//$'\r'/}"
  if [[ "$files_rc" -ne 0 ]]; then
    why="PR の変更ファイルを読めません（origin/${2}...${3:-（先端不明）}）"
    files=""
  elif [[ -z "$files" ]]; then
    why="PR の変更ファイルが 0 件です"
  fi
  # 変更ファイルを読めない回も呼ぶ — security_review=off は分類に依らず効く（空の一覧は根が unknown に
  # するので、off でなければ none にはならない）。設定はリポジトリルートの .claude/agent-config.yaml を
  # 読むので、ルートで呼ぶ。終了コード 2（判定不能）でも判定行は出るので、rc ではなく出力の行で読む。
  # 判定行が出ない失敗（plugin root ガード・使い方の誤り）の原因は rc と stderr の末尾で残す
  errf="$(mktemp)" || die_env "一時ファイルを作れません" "TMPDIR を書ける場所へ向けて再実行する"
  assert_bundled_shebang_lf "$plugin_root/scripts/review-route.sh"
  out="$(cd "$repo_root" && { [[ -z "$files" ]] || printf '%s\n' "$files"; } | FF_JEV_MODE=off FF_DEV_TOOLKIT_ROOT="${plugin_root}" \
    bash "$plugin_root/scripts/review-route.sh" --files-from - 2>"$errf")" || route_rc=$?
  route_err="$(tail -n 1 "$errf" 2>/dev/null | tr -d '\r')" || route_err=""
  rm -f "$errf"
  sensitive="$(printf '%s\n' "$out" | sed -n 's/^REVIEW_SECURITY_SENSITIVE=//p' | head -n 1)"
  gate="$(printf '%s\n' "$out" | sed -n 's/^REVIEW_SECURITY_GATE=//p' | head -n 1)"
  evidence="$(printf '%s\n' "$out" | sed -n 's/^REVIEW_SECURITY_EVIDENCE=//p')"
  case "$sensitive" in
    yes|no|unknown) ;;
    *)
      sensitive="unknown"
      [[ -n "$why" ]] || why="review-route.sh の判定行（REVIEW_SECURITY_SENSITIVE）がありません（rc=${route_rc}${route_err:+: ${route_err}}）"
      ;;
  esac
  [[ -n "$gate" || -n "$why" ]] || why="review-route.sh の判定行（REVIEW_SECURITY_GATE）がありません（rc=${route_rc}${route_err:+: ${route_err}}）"
  [[ -z "$why" ]] || sensitive="unknown"
  # 根が unknown にした理由（設定を読めない等）は報告行の末尾の「判定不能: …）」にある。前半（「… を実行する（」
  # 「未対応（主担当 unknown。」など）は主担当ホストで変わるので取らない
  if [[ "$sensitive" == "unknown" && -z "$why" ]]; then
    why="$(printf '%s\n' "$out" | LC_ALL=C sed -n 's/^REVIEW_SECURITY_REPORT_LINE=.*\(判定不能: .*\)）$/\1/p' | head -n 1)"
    [[ -n "$why" ]] || why="review-route.sh が unknown を返しました"
  fi
  echo "SECURITY_SENSITIVE=${sensitive}"
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    echo "SECURITY_EVIDENCE=${line}"
  done <<<"$evidence"
  [[ -z "$why" ]] || echo "SECURITY_UNKNOWN_REASON=${why}"
  if [[ "$gate" == "off" ]]; then
    echo "SECURITY_RECORD_GATE=off"
    return 0
  fi
  if [[ -z "$why" && "$sensitive" == "no" && "$gate" == "none" ]]; then
    echo "SECURITY_RECORD_GATE=not-required"
    return 0
  fi
  record="$(printf '%s\n' "$4" | ff_precheck_security_record_line)" || record=""
  if [[ -n "$record" ]]; then
    echo "SECURITY_RECORD_GATE=recorded"
    echo "SECURITY_RECORD=${record}"
    return 0
  fi
  echo "SECURITY_RECORD_GATE=missing"
  first="${evidence%%$'\n'*}"
  if [[ "$sensitive" == "yes" ]]; then
    reason="セキュリティに関わる変更（根拠: ${first:-根拠不明}。全件は SECURITY_EVIDENCE=）ですが、PR 本文に専用セキュリティゲートの記録行がありません"
  else
    reason="セキュリティに関わる変更かを判定できません（${why}）。該当なしとは読まず、PR 本文に専用セキュリティゲートの記録行を求めます"
  fi
  next="主担当の専用セキュリティゲート（review-route.sh の REVIEW_SECURITY_GATE）を実行し、PR 本文に「専用セキュリティゲート: /security-review 実施（指摘 N 件）」のような結果の行、実行できなかった回は「専用セキュリティゲート: 未確認（<理由>）」を書いてから finish.sh precheck を再実行する。「対象外」「未実施」と「… を実行する（…）」の計画行は記録に数えない。glob の誤検知と判断した回も理由を書いた「未確認」で残す。専用ゲートを使わない導入先は review.security_review: \"off\" を設定する（設定ファイルを読むには yq が要る。無い環境では環境変数 MULTI_AGENT_SECURITY_REVIEW=off）"
  if [[ "$files_rc" -eq 2 ]]; then
    next="先に $(ff_shell_argv git fetch origin "$2" "$3") で PR の差分を取り込み、finish.sh precheck を再実行する（取り込めれば分類できる）。取り込めない回は、${next}"
  fi
  if [[ -z "$blocked_reason" ]]; then
    blocked_reason="$reason"
    blocked_next="$next"
  else
    blocked_reason="${blocked_reason}／さらに${reason}"
    blocked_next="${blocked_next}。あわせて、${next}"
  fi
  return 0
}

_finish_precheck_security_record_loaded=1
