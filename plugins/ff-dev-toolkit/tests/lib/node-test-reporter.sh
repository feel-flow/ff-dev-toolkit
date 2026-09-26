#!/usr/bin/env bash
#
# `node --test` の reporter 未固定を静的に検出する。
#
# `node --test` の既定 reporter は **stdout が TTY かどうかで変わる**（TTY なら spec、
# pipe なら TAP）。出力を文字列で照合する検査は、この差でそのまま壊れる:
#
#   手元（対話・TTY）      `✖ roster is derived…`
#   CI（pipe・捕捉あり）   `not ok 1 - roster is derived…`
#
# しかも Node の版によって既定が動くため、**手元で緑・CI で赤**（逆向きに、手元で赤・CI で
# 偽の緑）が両方成立する。振る舞いテストでは回帰ガードを作れない — 既定が spec の環境では
# pin を外す変異が緑になるからである（ACE-307-2 と同型）。違反の形そのものを静的に縛る。
#
# 検出するのは「`node --test` を起動していて、同じ論理行に `--test-reporter=` が無い」形。
# 出力を照合しているかどうかは静的には決められないので、**起動する側へ一律 pin を要求する**。
# pin は Node 22 より前から在るので、要求しても回せなくなる環境は無い。
#
# 公開関数:
#   node_test_scan [file...]            論理行畳み込み走査。違反は「開始行:node-test-unpinned:論理行」。
#                                       引数なしなら stdin。awk 非 0 は呼び出し側へ伝播。
#   node_test_check_tracked ROOT        git 管理下の shell スクリプトを横断走査。
#                                       標準出力に機械可読サマリー、詳細は stderr。
#                                       終了コード: 0=違反なし / 1=違反あり or 検査不能
#
# テストシーム（通常は未設定）:
#   FF_NODE_TEST_GIT   git コマンド（既定: git）
#   FF_NODE_TEST_AWK   awk コマンド（既定: awk）
#
# 本ファイルは source される前提（実行ビット不要）。
# 補足: 行頭が `# shellcheck …` の形をした散文コメントは shellcheck にディレクティブとして
# 解釈され、SC1072/SC1073 でそのファイルの静的検査が丸ごと止まる。
# この注記の書き出しを変えないこと。

# 引用符とコメントを伏せた版の上で判定する。検出器自身やテストの期待値に現れる
# `node --test` の**文字列**を違反として拾わないため（自己言及で永久に赤くなる）。
node_test_scan() {
  LC_ALL=C "${FF_NODE_TEST_AWK:-awk}" '
    # 引用符とコメントを伏せた版を作る。**入出力の長さは 1:1 に保つ** — 伏せた版で区間の境界を
    # 決め、同じ位置を使って raw 側から pin を読むため（下記）。
    #
    # コマンド置換（$(...)）の中は伏せない。`out="$(node --test x)"` は二重引用符の中だが
    # 散文ではなく起動であり、しかも出力を捕捉する = stdout が pipe になる = この契約が
    # 狙っている当の形である。ここを巻き込んで伏せると、ガードが的だけを外す。
    # 単一引用符の中は展開されないので伏せたまま。
    #
    # `#` は POSIX どおり「行頭、または直前が空白 / ; / & / | / (」のときだけコメント開始。
    # 語中の `#`（`${files[@]#./}` / `$#`）をコメントにすると、pin を見失ったり行全体が
    # 消えたりする（どちらも実測で誤判定を作った）。
    function mask(s,   i, c, prev, out, q, depth) {
      out = ""; q = ""; depth = 0
      for (i = 1; i <= length(s); i++) {
        c = substr(s, i, 1)
        prev = (i > 1) ? substr(s, i - 1, 1) : ""
        if (depth > 0) {
          # 置換の**中身は伏せる**。最上位の区間分割からは見えなくし、中身の判定は
          # check_subst() が raw から取り出して**改めて伏せてから**行う（二重に伏せないと、
          # 中の引用符が効かず `grep -cE \x27… node --test …\x27` のパターン文字列を
          # 起動として拾う）。`$(` と対応する `)` だけは位置の目印として残す。
          if (c == "(") { depth++; out = out "_"; continue }
          if (c == ")") { depth--; out = out ((depth == 0) ? ")" : "_"); continue }
          out = out "_"
          continue
        }
        if (q == "") {
          if (c == "$" && substr(s, i + 1, 1) == "(") { depth = 1; out = out "$("; i++; continue }
          if (c == "\x27" || c == "\"") { q = c; out = out "_"; continue }
          if (c == "#" && (i == 1 || prev ~ /[[:space:];&|(]/)) {
            while (i <= length(s)) { out = out "_"; i++ }
            break
          }
          out = out c
        } else {
          if (q == "\"" && c == "$" && substr(s, i + 1, 1) == "(") { depth = 1; out = out "$("; i++; continue }
          if (c == q) q = ""
          out = out "_"
        }
      }
      return out
    }
    # コメントだけを伏せた版（引用符の中は残す・長さは 1:1）。pin の判定はこれに当てる —
    # 伏せた版で見ると引用符付きの正当な pin が消え、raw のまま見るとコメント内の「言及」を
    # pin と誤認する。どちらも実測で誤判定を作った。
    function strip_comment(s,   i, c, prev, out, q) {
      out = ""; q = ""
      for (i = 1; i <= length(s); i++) {
        c = substr(s, i, 1)
        prev = (i > 1) ? substr(s, i - 1, 1) : ""
        if (q == "") {
          if (c == "\x27" || c == "\"") { q = c; out = out c; continue }
          if (c == "#" && (i == 1 || prev ~ /[[:space:];&|(]/)) {
            while (i <= length(s)) { out = out "_"; i++ }
            break
          }
          out = out c
        } else {
          if (c == q) q = ""
          out = out c
        }
      }
      return out
    }
    # 区間の先頭から、起動の前に来るキーワード・ラッパ・環境変数代入を剥がす。
    # 環境変数代入の値に `$(` が含まれる場合は剥がさない — `out=$(node --test x)` の
    # `out=$(node ` まで食ってしまい、コマンド語が `--test` に化ける（実測）。
    function strip_prefix(s,   w, guard) {
      guard = 0
      while (guard++ < 12) {
        sub(/^[[:space:]]+/, "", s)
        w = s
        sub(/[[:space:]].*$/, "", w)
        if (w == "") break
        if (w ~ /^[A-Za-z_][A-Za-z0-9_]*=/ && index(w, "$(") == 0) { sub(/^[^[:space:]]+[[:space:]]+/, "", s); continue }
        if (w ~ /^(if|then|else|elif|while|until|do|exec|command|time|!|\{|\()$/) { sub(/^[^[:space:]]+[[:space:]]*/, "", s); continue }
        # パッケージランナー経由の起動（`npx node --test` / `pnpm exec node --test`）。
        if (w ~ /^(npx|pnpm|yarn|bunx)$/) {
          sub(/^[^[:space:]]+[[:space:]]+/, "", s)
          while (s ~ /^-[^[:space:]]*[[:space:]]/) sub(/^-[^[:space:]]*[[:space:]]+/, "", s)
          sub(/^(exec|run|dlx)[[:space:]]+/, "", s)
          continue
        }
        break
      }
      return s
    }
    # 区間が node の起動か（pin の有無は見ない）。`--test` は node の第 1 引数とは限らない
    # （`node --no-warnings --test x` のようにフラグを 1 つ足すだけで回避できてはいけない）。
    function is_node_test(s, raw_word,   w) {
      if (s !~ /(^|[[:space:]])--test([[:space:]]|$)/) return 0
      s = strip_prefix(s)
      w = s
      sub(/[[:space:]].*$/, "", w)
      sub(/^.*\//, "", w)
      if (w == "node") return 1
      # `"$NODE" --test x` は伏せた版では `_______ --test x` になる。変数で起動する形を
      # 落とすと、pin 要求が変数 1 つで回避できてしまう。伏せた語が全部 `_` なら raw 側を見る。
      return (w ~ /^_+$/ && raw_word ~ /^"?\$\{?[A-Za-z_]*(NODE|node)/)
    }
    # 区切り子・パイプ・括弧で割った各区間を、**伏せた版で起動判定・raw 版で pin 判定**する。
    # pin を伏せた版で見ると、引用符で括った正当な pin（`--test-reporter="$R"`）が消えて
    # 直しようのない赤になる（実測）。長さを 1:1 に保ってあるので位置で対応が取れる。
    function scan_pairs(m, raw, nc,   i, c, a, hit, seg, rawseg, ncseg, rawword) {
      hit = 0; a = 1
      for (i = 1; i <= length(m) + 1; i++) {
        c = (i <= length(m)) ? substr(m, i, 1) : ";"
        if (c == ";" || c == "|" || c == "&" || c == "(" || c == ")" || c == "\n") {
          seg = substr(m, a, i - a)
          rawseg = substr(raw, a, i - a)
          ncseg = substr(nc, a, i - a)
          rawword = rawseg
          sub(/^[[:space:]]+/, "", rawword)
          sub(/[[:space:]].*$/, "", rawword)
          if (is_node_test(seg, rawword) && ncseg !~ /--test-reporter=/) hit = 1
          a = i + 1
        }
      }
      return hit
    }
    # コマンド置換の中身を取り出して同じ判定を当てる（入れ子も辿る）。伏せた版と raw 版で
    # 同じ位置を切り出す。
    function check_subst(m, raw, nc,   i, c, depth, sa, hit, sub_raw) {
      hit = 0; i = 1
      while (i <= length(m)) {
        if (substr(m, i, 2) == "$(") {
          depth = 1; i += 2; sa = i
          while (i <= length(m) && depth > 0) {
            c = substr(m, i, 1)
            if (c == "(") depth++
            else if (c == ")") { depth--; if (depth == 0) break }
            i++
          }
          # 置換の中身は mask() を**通っていない**（depth>0 の間は素通しで写している）。
          # ここで改めて伏せないと、中の引用符が効かず `grep -cE \x27… node --test …\x27` の
          # ような**パターン文字列**を起動として拾う（実測で偽陽性を作った）。
          sub_raw = substr(raw, sa, i - sa)
          if (scan_pairs(mask(sub_raw), sub_raw, strip_comment(sub_raw))) hit = 1
          if (check_subst(mask(sub_raw), sub_raw, strip_comment(sub_raw))) hit = 1
          i++
        } else i++
      }
      return hit
    }
    function scan(line, start,   m, nc) {
      # Literal --test is necessary even inside a substitution. Filter only after
      # logical-line joining, keeping continuations and EOF handling unchanged.
      if (index(line, "--test") == 0) return
      m = mask(line)
      nc = strip_comment(line)
      if (scan_pairs(m, line, nc) || check_subst(m, line, nc)) print start ":node-test-unpinned:" line
    }
    FNR == 1 && NR > 1 {
      if (joined != "") scan(joined, start_line)
      joined = ""
    }
    {
      line = $0
      if (joined == "") start_line = FNR
      if (line ~ /\\$/) { sub(/\\$/, "", line); joined = joined line " "; next }
      joined = joined line
      scan(joined, start_line)
      joined = ""
    }
    END { if (joined != "") scan(joined, start_line) }
  ' "$@"
}

node_test_check_tracked() {
  local repo_root="$1"
  local git_cmd="${FF_NODE_TEST_GIT:-git}"
  local all_hits="" scan_errors="" skipped="" scanned=0
  local list="" file first hits rc
  local -a scan_files=() scan_paths=()

  if ! repo_root="$("$git_cmd" -C "$repo_root" rev-parse --show-toplevel 2>/dev/null)"; then
    printf 'NODE_TEST_RESULT=error_repo SCANNED=0 HITS=0 ERRORS=1 SKIPPED=0\n'
    echo "リポジトリルートを解決できない（git rev-parse 失敗）" >&2
    return 1
  fi
  if ! list="$("$git_cmd" -C "$repo_root" -c core.quotepath=false ls-files 2>/dev/null)"; then
    printf 'NODE_TEST_RESULT=error_list SCANNED=0 HITS=0 ERRORS=1 SKIPPED=0\n'
    echo "tracked ファイル一覧を取得できない（git ls-files 失敗）" >&2
    return 1
  fi
  if [ -z "$list" ]; then
    printf 'NODE_TEST_RESULT=error_list SCANNED=0 HITS=0 ERRORS=1 SKIPPED=0\n'
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
        # shebang の集合は tests/shellcheck/verify.sh の SHEBANG_RE と同じ形へ揃える。
        # 別定義を持つと、片方だけが拾うファイルが静かに無検査になる。
        case "$first" in
          '#!'*[/\ ]sh|'#!'*[/\ ]sh' '*|'#!'*[/\ ]bash|'#!'*[/\ ]bash' '*|'#!'*[/\ ]dash|'#!'*[/\ ]dash' '*|'#!'*[/\ ]ksh|'#!'*[/\ ]ksh' '*) ;;
          *) continue ;;
        esac ;;
    esac
    scan_files+=("$file")
    scan_paths+=("$repo_root/$file")
  done < <(printf '%s\n' "$list")

  # One clean batch avoids an awk process per tracked file. On hits or errors,
  # retain the original per-file diagnostics. Never invoke an empty array: awk
  # would read stdin. Preserve the API: an empty tracked roster fails above;
  # no eligible/present files still reports SCANNED=0 (and any SKIPPED count).
  if [ "${#scan_files[@]}" -gt 0 ]; then
    rc=0
    hits="$(node_test_scan "${scan_paths[@]}" 2>/dev/null)" || rc=$?
    if [ "$rc" -eq 0 ] && [ -z "$hits" ]; then
      scanned=${#scan_files[@]}
    else
      # A failed batch remains an error even if a later retry succeeds.
      if [ "$rc" -ne 0 ]; then
        scan_errors="${scan_errors}batch (awk rc=${rc})
"
      fi
      for file in "${scan_files[@]}"; do
        set +e
        hits="$(node_test_scan "$repo_root/$file" 2>/dev/null)"
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
      done
    fi
  fi

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
  if [ "$has_hits" -eq 1 ]; then
    result=hits
    echo "node --test の reporter が固定されていない起動がある" >&2
    echo "  node-test-unpinned: 既定 reporter は stdout が TTY かどうかで変わる（TTY=spec / pipe=TAP）。" >&2
    echo "                  出力を文字列で照合する検査は手元と CI で結果が変わり、しかも Node の版で" >&2
    echo "                  既定が動くため「手元で緑・CI で赤」と「CI で偽の緑」の両方が成立する。" >&2
    echo "                  起動側へ一律 pin する: node --test --test-reporter=spec <files>" >&2
    echo "                  出力を照合していない起動でも pin する — 照合の有無は静的に決められず、" >&2
    echo "                  次に照合を足した人が同じ穴を開けるため（抜け道にしない）。" >&2
    printf '%s' "$all_hits" | sed 's/^/  | /' >&2
  fi
  if [ "$has_errors" -eq 1 ]; then
    result=error_scan
    echo "走査に失敗したファイルがある — そのファイルの 0 件は主張できない" >&2
    printf '%s' "$scan_errors" | sed 's/^/  | /' >&2
  fi

  printf 'NODE_TEST_RESULT=%s SCANNED=%s HITS=%s ERRORS=%s SKIPPED=%s\n' \
    "$result" "$scanned" "$has_hits" "$has_errors" "$skipped_n"

  if [ "$result" = "ok" ]; then
    return 0
  fi
  return 1
}
