#!/usr/bin/env bash
#
# $VAR 直後マルチバイト展開の静的検出（Issue #278 / #311 / #312）。
#
# bash 3.2 は `$VAR` 直後のマルチバイト先頭バイトを変数名に取り込む。
# 振る舞いテストは版数・ロケール依存なので、違反の形そのものを静的に縛る。
#
# 公開関数:
#   mbcs_scan [file...]     論理行畳み込み走査。違反は「開始行:論理行」を stdout。
#                           引数なしなら stdin。awk 非 0 は呼び出し側へ伝播。
#   mbcs_check_tracked ROOT  git 管理下の shell スクリプトを横断走査。
#                           標準出力に機械可読サマリー、詳細は stderr。
#                           終了コード: 0=違反なし / 1=違反あり or 検査不能
#
# テストシーム（通常は未設定）:
#   FF_MBCS_GIT   git コマンド（既定: git）
#   FF_MBCS_AWK   awk コマンド（既定: awk）
#
# 本ファイルは source される前提（実行ビット不要）。
# 補足: 行頭が `# shellcheck …` の形をした散文コメントは shellcheck にディレクティブとして
# 解釈され、SC1072/SC1073 でそのファイルの静的検査が丸ごと止まる（Issue #530）。
# この注記の書き出しを変えないこと。

# 論理行（バックスラッシュ継続を連結）へ畳んでから走査する。
# LC_ALL=C では [:print:]/[:space:] が ASCII のみ → マルチバイト先頭バイトを拾える。
mbcs_scan() {
  LC_ALL=C "${FF_MBCS_AWK:-awk}" '
    function scan(line, start) {
      if (line ~ /\$[A-Za-z_][A-Za-z0-9_]*[^[:print:][:space:]]/) print start ":" line
    }
    {
      line = $0
      if (joined == "") start_line = FNR
      if (line ~ /\\$/) { sub(/\\$/, "", line); joined = joined line; next }
      joined = joined line
      scan(joined, start_line)
      joined = ""
    }
    END { if (joined != "") scan(joined, start_line) }
  ' "$@"
}

# Markdown の bash 系フェンス内だけを MBCS 走査する（skill-bash-blocks 用）。
# 違反は「開始行:論理行」。フェンス状態機械は skill-bash-blocks の grep -q 検査と同型。
# バックスラッシュ行継続の連結は mbcs_scan と同じく空文字結合（隣接マルチバイトを
# 取りこぼさない）。パイプ行末継続は本検査の対象外（MBCS 隣接にならない）。
mbcs_scan_bash_blocks() {
  LC_ALL=C "${FF_MBCS_AWK:-awk}" '
    function check_logical(line, start) {
      if (line ~ /\$[A-Za-z_][A-Za-z0-9_]*[^[:print:][:space:]]/) print start ":" line
    }
    { sub(/\r$/, "") }
    in_block == 0 {
      if ($0 ~ /^[[:space:]]*(```|~~~)/) {
        fence = $0
        sub(/^[[:space:]]*/, "", fence)
        fence_char = substr(fence, 1, 1)
        fence_len = 0
        while (substr(fence, fence_len + 1, 1) == fence_char) fence_len++
        info = substr(fence, fence_len + 1)
        sub(/^[[:space:]]*/, "", info)
        sub(/[[:space:]].*$/, "", info)
        in_block = 1
        open_line = FNR
        is_bash = (info ~ /^(bash|sh|shell|zsh)$/) ? 1 : 0
        joined = ""
      }
      next
    }
    {
      stripped = $0
      sub(/^[[:space:]]*/, "", stripped)
      sub(/[[:space:]]*$/, "", stripped)
      if (stripped ~ /^(`+|~+)$/ && substr(stripped, 1, 1) == fence_char && length(stripped) >= fence_len) {
        if (joined != "") { check_logical(joined, start_line); joined = "" }
        in_block = 0
        next
      }
      if (is_bash == 0) next
      line = $0
      if (joined == "") start_line = FNR
      if (line ~ /\\[[:space:]]*$/) {
        sub(/\\[[:space:]]*$/, "", line)
        joined = joined line
        next
      }
      joined = joined line
      check_logical(joined, start_line)
      joined = ""
    }
    END {
      if (in_block == 1) {
        if (joined != "") check_logical(joined, start_line)
      }
    }
  ' "$1"
}

# リポジトリ ROOT の tracked shell を横断検査する。
# stdout（1 行）: MBCS_RESULT=<code> SCANNED=<n> HITS=<0|1> ERRORS=<0|1> SKIPPED=<n>
#   code: ok | hits | error_repo | error_list | error_scan
# stderr: 人間向け詳細（hits / errors / skipped 一覧）
# exit: 0=ok のみ / 1=それ以外
mbcs_check_tracked() {
  local repo_root="$1"
  local git_cmd="${FF_MBCS_GIT:-git}"
  local all_hits="" scan_errors="" skipped="" scanned=0
  local list="" file first hits rc

  if ! repo_root="$("$git_cmd" -C "$repo_root" rev-parse --show-toplevel 2>/dev/null)"; then
    printf 'MBCS_RESULT=error_repo SCANNED=0 HITS=0 ERRORS=1 SKIPPED=0\n'
    echo "リポジトリルートを解決できない（git rev-parse 失敗）" >&2
    return 1
  fi

  if ! list="$("$git_cmd" -C "$repo_root" -c core.quotepath=false ls-files 2>/dev/null)"; then
    printf 'MBCS_RESULT=error_list SCANNED=0 HITS=0 ERRORS=1 SKIPPED=0\n'
    echo "tracked ファイル一覧を取得できない（git ls-files 失敗）" >&2
    return 1
  fi
  if [ -z "$list" ]; then
    printf 'MBCS_RESULT=error_list SCANNED=0 HITS=0 ERRORS=1 SKIPPED=0\n'
    echo "tracked ファイル一覧が空 — 0 件の主張はできない" >&2
    return 1
  fi

  while IFS= read -r file; do
    [ -n "$file" ] || continue
    if [ ! -f "$repo_root/$file" ]; then
      case "$file" in
        *.sh) skipped="${skipped}${file}
" ;;
      esac
      continue
    fi
    if [ ! -r "$repo_root/$file" ]; then
      scan_errors="${scan_errors}${file} (unreadable)
"
      continue
    fi
    case "$file" in
      *.sh) ;;
      *)
        first=""
        IFS= read -r first < "$repo_root/$file" || true
        case "$first" in
          '#!'*bash*|'#!'*/sh|'#!'*/sh' '*) ;;
          *) continue ;;
        esac ;;
    esac
    set +e
    hits="$(mbcs_scan "$repo_root/$file" 2>/dev/null)"
    rc=$?
    set -e
    if [ "$rc" -ne 0 ]; then
      scan_errors="${scan_errors}${file} (awk rc=${rc})
"
      continue
    fi
    scanned=$((scanned + 1))
    if [ -n "$hits" ]; then
      all_hits="${all_hits}${file}:
${hits}
"
    fi
  done < <(printf '%s\n' "$list")

  local skipped_n=0
  if [ -n "$skipped" ]; then
    skipped_n="$(printf '%s' "$skipped" | grep -c . || true)"
  fi
  local has_hits=0 has_errors=0 result=ok
  [ -n "$all_hits" ] && has_hits=1
  [ -n "$scan_errors" ] && has_errors=1

  if [ -n "$skipped" ]; then
    echo "（参考）作業ツリーに実体が無く走査対象外: ${skipped_n} 件" >&2
    printf '%s' "$skipped" | sed 's/^/  | /' >&2
  fi
  # 走査失敗は「0 件」を主張できないので hits より優先して error_scan にする。
  if [ "$has_hits" -eq 1 ]; then
    result=hits
    echo "\$VAR 直付けのマルチバイト展開が再混入した（\${VAR} 形式にすること）" >&2
    printf '%s' "$all_hits" | sed 's/^/  | /' >&2
  fi
  if [ "$has_errors" -eq 1 ]; then
    result=error_scan
    echo "走査に失敗したファイルがある — そのファイルの 0 件は主張できない" >&2
    printf '%s' "$scan_errors" | sed 's/^/  | /' >&2
  fi

  printf 'MBCS_RESULT=%s SCANNED=%s HITS=%s ERRORS=%s SKIPPED=%s\n' \
    "$result" "$scanned" "$has_hits" "$has_errors" "$skipped_n"

  if [ "$result" = "ok" ]; then
    return 0
  fi
  return 1
}
