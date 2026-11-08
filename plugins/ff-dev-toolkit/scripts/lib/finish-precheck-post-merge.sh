#!/usr/bin/env bash
# finish.sh の precheck 構成ファイル（マージ後工程の判定）。finish-precheck.sh と同じく入口が検査して source する。
# 関数の定義だけを置き、読み込み完了は末尾の sentinel で確認する。bash 3.2 互換。
# pipefail-inherited: finish.sh が set -uo pipefail の下で source する

if [[ "${_finish_precheck_loading:-}" != "1" ]]; then
  echo "finish-precheck-post-merge.sh は finish.sh precheck から読み込んでください" >&2
  exit 2
fi

# ── マージ後工程の判定（FF_POST_MERGE_TERMS / FF_POST_MERGE_PATHS を設定した導入先だけ） ──
# 下の helper は cmd_precheck の local（PM_ACK_RAW / pm_paths / pm_count / blocked_reason / TARGET_REPO ほか）を読み書きする。

# 2 変数はどちらも ':' 区切り。片方だけ・空要素・前後の空白は、何にも一致しないか全行へ一致する
# 指定なので受け付けない。未設定（両方）だけが判定なしで、そのときは何も読まず何も出さない。
ff_precheck_post_merge_config() {
  [[ -n "${FF_POST_MERGE_TERMS+set}" || -n "${FF_POST_MERGE_PATHS+set}" ]] || return 0
  [[ -n "${FF_POST_MERGE_TERMS+set}" && -n "${FF_POST_MERGE_PATHS+set}" ]] \
    || die_env "FF_POST_MERGE_TERMS と FF_POST_MERGE_PATHS は片方だけでは判定できません" "両方を設定するか、両方を外して再実行する"
  local name value rest item
  for name in FF_POST_MERGE_TERMS FF_POST_MERGE_PATHS; do
    if [[ "$name" == "FF_POST_MERGE_TERMS" ]]; then value="$FF_POST_MERGE_TERMS"; else value="$FF_POST_MERGE_PATHS"; fi
    rest="${value}:"
    while [[ -n "$rest" ]]; do
      item="${rest%%:*}"
      rest="${rest#*:}"
      [[ -n "$item" ]] || die_env "${name} に空の要素があります: '${value}'" "先頭・末尾・連続する ':' を外して再実行する（空の語は全行に一致し、空のパスは何にも一致しない）"
      case "$item" in
        [[:space:]]*|*[[:space:]]) die_env "${name} の要素に前後の空白があります: '${item}'" "':' の前後の空白を外して再実行する" ;;
        *[[:cntrl:]]*) die_env "${name} の要素に制御文字があります" "改行やタブを外して再実行する" ;;
      esac
      if [[ "$name" == "FF_POST_MERGE_PATHS" ]]; then
        case "$item" in
          /*|./*) die_env "FF_POST_MERGE_PATHS の要素はリポジトリルート基準で書きます: '${item}'" "先頭の / や ./ を外して再実行する（PR のファイルはルート相対で比べるので、この指定は何にも一致しない）" ;;
        esac
        pm_paths+=("$item")
      fi
    done
  done
  pm_armed=1
}

# PR の変更ファイルの読み方は ff_precheck_pr_files（finish-precheck.sh。専用セキュリティゲートの記録の
# 検査と共有）が持つ。ここは読めない回を rc 2 の停止にする（切れた側の一致を「パスなし」へ倒さない）。
ff_precheck_post_merge_files() { # <PR JSON> <base> <head OID>
  local rc=0
  ff_precheck_pr_files "$1" "$2" "$3" || rc=$?
  case "$rc" in
    0) return 0 ;;
    1) die_env "PR の変更ファイル（files）を読めません。一致なしとは読まない" "gh pr view の files を確かめて finish.sh precheck を再実行する" ;;
    *) die_env "PR の変更ファイルを git で読み直せません（origin/${2}...${3:-（先端不明）}）。API の一覧は切れている可能性があり、一致なしとは読まない" "$(ff_shell_argv git fetch origin "$2" "$3") で取り込むか、PR のブランチの checkout で finish.sh precheck を再実行する" ;;
  esac
}

ff_precheck_post_merge_matches() { # <パス> <要素>
  # shellcheck disable=SC2053 # 右辺は導入先が書く glob。`*` は `/` も跨ぐ
  [[ "$1" == $2 || "$1" == ${2%/}/* ]]
}

ff_precheck_post_merge_path_hits() { # stdin: パス 1 行ずつ / stdout: 一致したパス
  local path pat
  while IFS= read -r path; do
    path="${path%$'\r'}"
    [[ -n "$path" ]] || continue
    for pat in "${pm_paths[@]}"; do
      if ff_precheck_post_merge_matches "$path" "$pat"; then
        printf '%s\n' "$path"
        break
      fi
    done
  done
}

# どのファイルにも当たらない要素は、誤字や改名で毎回 no-path になり判定が黙って消える。
# 追跡中のファイルとこの PR の変更ファイルのどちらにも当たらない要素は rc 2 にする
# （変更ファイルも見るのは、対象を丸ごと消す PR を止めないため）。
ff_precheck_post_merge_check_paths() { # <変更ファイル>
  local tracked pat path found
  tracked="$(git -C "$repo_root" ls-files -z | LC_ALL=C tr '\0' '\n')" \
    || die_env "追跡中のファイルを読めません。FF_POST_MERGE_PATHS の要素を確かめられない" "git ls-files が通る状態で finish.sh precheck を再実行する"
  for pat in "${pm_paths[@]}"; do
    found=0
    while IFS= read -r path; do
      path="${path%$'\r'}"
      if [[ -n "$path" ]] && ff_precheck_post_merge_matches "$path" "$pat"; then
        found=1
        break
      fi
    done <<<"${1}"$'\n'"${tracked}"
    [[ "$found" -eq 1 ]] || die_env "FF_POST_MERGE_PATHS の要素がどのファイルにも一致しません: '${pat}'" "誤字やディレクトリの改名を直して再実行する（このままだと毎回「パスなし」になり、判定が動かない）"
  done
}

# 語は文字どおりの部分一致で、英字の大文字小文字を区別しない。LC_ALL=C で bytes として比べる
# （UTF-8 ロケールの tolower は実装により多バイト文字の途中の byte を書き換える）。
ff_precheck_post_merge_lines() {
  ff_precheck_scan_lines visible | LC_ALL=C awk '
    BEGIN { n = split(tolower(ENVIRON["FF_POST_MERGE_TERMS"]), terms, ":") }
    {
      low = tolower($0)
      for (i = 1; i <= n; i++) if (index(low, terms[i])) { print; next }
    }
  '
}

ff_precheck_post_merge_emit() { # <Issue> <body|report> : stdin の本文から一致行を出す
  local tok="$1" source="$2" hits line
  hits="$(ff_precheck_post_merge_lines)" \
    || die_env "Issue ${tok} の語の照合に失敗しました（awk）。一致なしとは読まない" "awk が PATH に在ることを確かめて finish.sh precheck を再実行する"
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    printf 'POST_MERGE_HIT=%s\t%s\t%s\n' "$tok" "$source" "$line"
    pm_count=$((pm_count + 1))
    pm_issue_hit=1
  done <<<"$hits"
}

# この PR の完了報告（<!-- close-issue-report:PR-N -->）の本文を JSON 配列で出す。別の PR の報告は
# 見ない（過去の Refs の PR の報告が、後の Closes の PR を毎回止めるため）。
# 本文を jq の引数へ載せない（Windows の引数上限。Issue `#2029`）。
ff_precheck_fetch_report_bodies() { # <owner/repo#N> <PR番号>
  local tok="$1" marker="<!-- close-issue-report:PR-$2 -->" owner num err text json page count
  owner="${tok%%#*}"
  num="${tok##*#}"
  local filter='if (type == "object") and (.comments | type == "array") and all(.comments[]; (type == "object") and (.body == null or (.body | type == "string")))
    then [.comments[] | (.body // "") | select(contains($marker))] else error("comments") end'
  if [[ -n "$github_input" ]]; then
    jq -n --arg repository "$github_repository" --arg issue "$tok" '{repository:$repository, issue:$issue}' >"$github_tmp/issue-scope.json" || exit 2
    printf '[]\n' >"$github_tmp/issue-comments-all.json" || exit 2
    page=0
    while :; do
      page=$((page + 1))
      [[ "$page" -le 50 ]] || die_env "Issue ${tok} のコメントのページ送りが 50 ページを超えました。一致なしとは読まない" "index の last を確かめて再実行する"
      jq -n --argjson page "$page" '{page:$page}' >"$github_tmp/comments-position.json" || exit 2
      github_file_read "$github_input" finish.precheck.issue-comments "$github_tmp/issue-scope.json" initial "$github_tmp/comments-position.json" >"$github_tmp/issue-comments.json" || exit 2
      [[ -z "$GITHUB_INPUT_HTTP_STATUS" || "$GITHUB_INPUT_HTTP_STATUS" == 200 ]] \
        || die_env "Issue ${tok} のコメントの応答が 200 ではありません（http_status=${GITHUB_INPUT_HTTP_STATUS} / page=${page}）。一致なしとは読まない" "取得し直した raw を渡して再実行する"
      count="$(jq -ej 'if type == "array" then length else error("comments") end' "$github_tmp/issue-comments.json")" \
        || die_env "Issue ${tok} のコメントが配列ではありません（page=${page}）。一致なしとは読まない" "file 入力の raw を確かめて再実行する"
      case "$GITHUB_INPUT_LAST" in
        true) [[ "$count" -eq 0 ]] || die_env "Issue ${tok} のコメントの最後のページが空ではありません（page=${page}）" "終端は last:true の空ページにして再実行する"; break ;;
        false) [[ "$count" -gt 0 ]] || die_env "Issue ${tok} のコメントに last:true の無い空ページがあります（page=${page}）" "終端を last:true にして再実行する" ;;
        *) die_env "Issue ${tok} のコメントのページに last がありません（page=${page}）。全件を読めた保証が無く、一致なしとは読まない" "各 page に last を付けて再実行する" ;;
      esac
      jq -s '.[0] + .[1]' "$github_tmp/issue-comments-all.json" "$github_tmp/issue-comments.json" >"$github_tmp/issue-comments-next.json" || exit 2
      mv "$github_tmp/issue-comments-next.json" "$github_tmp/issue-comments-all.json" || exit 2
    done
    jq --arg marker "$marker" "{comments:.} | ${filter}" "$github_tmp/issue-comments-all.json" \
      || die_env "Issue ${tok} のコメントを解釈できません。取得失敗を一致なしとは読まない" "file 入力の body を文字列か null にして再実行する"
    return 0
  fi
  err="$(mktemp)" || die_env "一時ファイルを作れません" "TMPDIR を書ける場所へ向けて再実行する"
  if ! json="$(gh issue view "$num" --repo "$owner" --json comments 2>"$err")"; then
    text="$(cat "$err")"
    rm -f "$err"
    die_env "Issue ${tok} のコメントを取得できません（gh: ${text}）。取得失敗を一致なしとは読まない" "gh issue view ${num} --repo ${owner} --json comments が通る状態で finish.sh precheck を再実行する"
  fi
  rm -f "$err"
  printf '%s' "$json" | jq --arg marker "$marker" "$filter" \
    || die_env "Issue ${tok} のコメントを解釈できません。取得失敗を一致なしとは読まない" "gh issue view の JSON を確かめて再実行する"
}

ff_precheck_post_merge_scan_issue() { # <Issue> <本文> <PR番号>
  local tok="$1" reports i n report_body
  pm_issue_hit=0
  ff_precheck_post_merge_emit "$tok" body <<<"$2"
  reports="$(ff_precheck_fetch_report_bodies "$tok" "$3")" || exit $?
  n="$(jq -ej 'length' <<<"$reports")" || die_env "Issue ${tok} の完了報告の件数を読めません" "jq の動作を確かめて再実行する"
  i=0
  while [[ "$i" -lt "$n" ]]; do
    # コメントごとに走査し、片方の閉じないフェンスが次の報告を隠さないようにする
    report_body="$(jq -r --argjson i "$i" '.[$i]' <<<"$reports")" \
      || die_env "Issue ${tok} の完了報告を読めません" "jq の動作を確かめて再実行する"
    ff_precheck_post_merge_emit "$tok" report <<<"$report_body"
    i=$((i + 1))
  done
}

# --ack-post-merge <Issue> --ack-post-merge-reason <理由> を受け取る。呼び出し側が 4 語を読み飛ばす。
ff_precheck_post_merge_take_ack() { # <--ack-post-merge> <Issue> <--ack-post-merge-reason> <理由>
  [[ $# -ge 2 && -n "$2" ]] || usage
  [[ $# -ge 4 && "$3" == "--ack-post-merge-reason" ]] \
    || die_env "--ack-post-merge には理由が要ります（直後に --ack-post-merge-reason）" "--ack-post-merge ${2} --ack-post-merge-reason '<理由>' の形で再実行する"
  local reason="$4"
  reason="${reason#"${reason%%[![:space:]]*}"}"
  reason="${reason%"${reason##*[![:space:]]}"}"
  # 出力は行頭の KEY= で読まれるので、改行入りの理由は PRECHECK= の行を偽造できる
  [[ -n "$reason" && "$reason" != *[[:cntrl:]]* ]] \
    || die_env "--ack-post-merge-reason が空か、改行・タブなどの制御文字を含みます" "1 行の理由を渡して再実行する"
  PM_ACK_RAW+=("$2")
  PM_ACK_REASON+=("$reason")
}

# ack の出力とパスの判定。本文の取得は未チェックの検査と共用し、パスに一致した回だけコメントを読む。
ff_precheck_post_merge_prepare() { # <PR JSON> <base> <head OID>
  local i=0 ack_tok changed hits line
  while [[ "$i" -lt "${#PM_ACK_RAW[@]}" ]]; do
    ack_tok="$(ff_precheck_normalize_ack "${PM_ACK_RAW[$i]}")" || die_env "--ack-post-merge の値が owner/repo#N ではありません: ${PM_ACK_RAW[$i]}" "owner/repo#N、#N、または Issue の URL を渡して再実行する"
    pm_ack_norm="${pm_ack_norm}${ack_tok}"$'\n'
    printf 'POST_MERGE_ACKED=%s\t%s\n' "$ack_tok" "${PM_ACK_REASON[$i]}"
    i=$((i + 1))
  done
  [[ "$pm_armed" -eq 1 && -n "$CLOSES_UNION" ]] || return 0
  changed="$(ff_precheck_post_merge_files "$1" "$2" "$3")" || exit $?
  ff_precheck_post_merge_check_paths "$changed"
  hits="$(ff_precheck_post_merge_path_hits <<<"$changed")"
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    printf 'POST_MERGE_PATH=%s\n' "$line"
    pm_path_hit=1
  done <<<"$hits"
}

# 判定の結果を出し、止める回は停止理由を足す。先着の理由は上書きせず併記する
# （片方だけ直して再実行し、もう一度止まる 2 段停止を作らない）。
ff_precheck_post_merge_verdict() {
  [[ "$pm_armed" -eq 1 ]] || return 0
  if [[ -z "$CLOSES_UNION" ]]; then
    echo "POST_MERGE_GATE=no-closes"
    return 0
  fi
  if [[ "$pm_path_hit" -eq 0 ]]; then
    echo "POST_MERGE_GATE=no-path"
    return 0
  fi
  echo "POST_MERGE_HIT_COUNT=${pm_count}"
  if [[ "$pm_count" -eq 0 ]]; then
    echo "POST_MERGE_GATE=clear"
    return 0
  fi
  if [[ "$pm_unacked" -eq 0 ]]; then
    echo "POST_MERGE_GATE=acked"
    return 0
  fi
  echo "POST_MERGE_GATE=blocked"
  local reason="Closes のまま閉じる Issue に、マージ後の工程を示す行が残っています（POST_MERGE_HIT= 行 / POST_MERGE_PATH= 行）"
  local next="マージ後に行う工程なら、本文の Closes を Refs に変え、--subject と --body を付けて手順 1 から再実行し、工程の完了後に Issue を閉じる。工程が済んでいる・対象外なら --ack-post-merge <owner/repo#N> --ack-post-merge-reason '<理由>' を付けて再実行し、理由を完了報告へ書く"
  if [[ -z "$blocked_reason" ]]; then
    blocked_reason="$reason"
    blocked_next="$next"
  else
    blocked_reason="${blocked_reason}／さらに${reason}"
    blocked_next="${blocked_next}。あわせて、${next}"
  fi
}

_finish_precheck_post_merge_loaded=1
