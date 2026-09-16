#!/usr/bin/env bash
#
# `set -o pipefail` 配下でパイプの下流に `grep -q` を置く形を静的に検出する。
#
# `grep -q` は一致した時点で読むのをやめて終了する。上流が書き続けていると上流は
# EPIPE / SIGPIPE で死に、`pipefail` はパイプライン全体の終了コードをその非 0 にする。
# つまり **一致が「不一致」へ反転する**:
#
#   肯定形  `if printf '%s\n' "$s" | grep -q X; then`      一致しているのに偽の赤
#   否定形  `if ! printf '%s\n' "$s" | grep -q X; then`    一致しているのに偽の緑
#
# しかも反転するのは「上流が grep の打ち切りに間に合わず書き続けたとき」だけなので、
# payload が小さいうちは何も起きない。節や出力が育った日に、無関係な変更のせいで
# 壊れたように見える形で表面化する（実測: payload 262KB / needle 先頭で偽陰性 100/100、
# パイプを使わない形は 0/100）。振る舞いテストでは回帰ガードを作れない — 小さい payload
# では変異が緑になるからである。違反の形そのものを静的に縛る。
#
# ── 何が禁止で、何が代替か（抜け道もここに列挙する） ────────────────────────
#
#   禁止: `set -o pipefail` 配下で、`printf` / `echo` / `cat` を上流に置いたパイプの
#         下流へ `grep -q`（`-Eq` / `-qE` / `-Fq` / `-iq` などのフラグ結合、`--quiet`
#         を含む）を書くこと。`echo "$s" | grep -q ...` / `cat "$f" | grep -q ...` へ
#         逃げても同じ欠陥なので、3 つとも禁止側に数える（抜け道にしない）。
#         否定形 `if ! ... | grep -q` も同じ検出規則で拾う
#         （こちらは偽の緑になるぶん悪い）。間に `sed` などを挟んでも上流が死ぬのは
#         同じなので、鎖の上流に居れば拾う。
#   代替: `grep -q <<<"$s"`（here-string。上流プロセスが無いので反転しない）
#         `case "$s" in *needle*) ...` / `[[ "$s" =~ ... ]]`（そもそもパイプを使わない）
#         `grep -q ... "$file"`（ファイルを直接渡す）
#         `grep -c` / `grep` 単独（入力を読み切るので上流が EPIPE で死なない）
#   例外: payload が原理的に小さく、上流が打ち切りに間に合うことが自明な場合に限り、
#         同じ論理行の行末へ `# pipefail-safe: <根拠>` を書いて除外を宣言できる。
#         根拠は「なぜ原理的に小さいか」を書く（「たぶん短い」は根拠ではない）。
#
# 検出するのは形だけで、payload の大小は静的に決められない。だから**上流に置く側へ
# 一律で言い換えを求める**（例外は上の行末マーカーで明示的に宣言させる）。
#
# 公開関数:
#   pipefail_grep_q_scan [file...]        論理行畳み込み走査。違反は「開始行:pipefail-grep-q:論理行」。
#                                         引数なしなら stdin。`pipefail` を設定していない
#                                         入力は 1 件も報告しない。awk 非 0 は呼び出し側へ伝播。
#   pipefail_grep_q_check_tracked ROOT    git 管理下の shell スクリプトを横断走査。
#                                         標準出力に機械可読サマリー、詳細は stderr。
#                                         終了コード: 0=違反なし / 1=違反あり or 検査不能
#
# 既知の限界（保守側に倒す・変更時はこの一覧と fixture を更新すること）:
#   - 誤検出側: ヒアドキュメント本文。`<<EOF` の中に書いた禁止イディオムも実行文として拾う
#     （本文の構文解析は入れない。fixture を書きたいときは here-string か
#     `printf '%s\n' > file` での生成へ分ける）
#   - 非検出側: `printf` / `echo` / `cat` 以外の上流（`git log | grep -q` など）。読み切らない
#     上流は他にもあるが、実測した反転事例に合わせて 3 つに絞っている
#   - 非検出側: 関数越しの `printf`（`emit | grep -q X` の `emit` が内部で printf する形）。
#     呼び出し先まで辿らない
#   - 非検出側: 自分では `pipefail` を張らず source 元から継承するファイル。設定行が同じ
#     ファイルに無いと報告しない（`pipefail` 未設定のファイルを一律で禁止しないため）
#   - 非検出側: オペランドの後ろに置いた `-q`（`grep -e "$pat" -q` 形）
#
# テストシーム（通常は未設定）:
#   FF_PIPEFAIL_GREP_Q_GIT   git コマンド（既定: git）
#   FF_PIPEFAIL_GREP_Q_AWK   awk コマンド（既定: awk）
#
# 本ファイルは source される前提（実行ビット不要）。
# 補足: 行頭が `# shellcheck ...` の形をした散文コメントは shellcheck にディレクティブとして
# 解釈され、SC1072/SC1073 でそのファイルの静的検査が丸ごと止まる。
# この注記の書き出しを変えないこと。

# 引用符とコメントを伏せた版の上で判定する。検出器自身やテストの期待値に現れる
# 違反の**文字列**を違反として拾わないため（自己言及で永久に赤くなる）。
# mask() の契約は tests/lib/node-test-reporter.sh と同じ（入出力の長さを 1:1 に保つ /
# コマンド置換の中は素通しして check_subst() が改めて伏せる / `#` は POSIX どおり
# 行頭・空白直後などでだけコメント開始）。同じ形にしてあるのは、片方で見つかった
# 誤判定の直しをもう片方へ移せるようにするため。
pipefail_grep_q_scan() {
  LC_ALL=C "${FF_PIPEFAIL_GREP_Q_AWK:-awk}" '
    function mask(s,   i, c, prev, out, q, depth) {
      out = ""; q = ""; depth = 0; MASK_CMT = 0
      for (i = 1; i <= length(s); i++) {
        c = substr(s, i, 1)
        prev = (i > 1) ? substr(s, i - 1, 1) : ""
        if (depth > 0) {
          if (c == "(") { depth++; out = out "_"; continue }
          if (c == ")") { depth--; out = out ((depth == 0) ? ")" : "_"); continue }
          out = out "_"
          continue
        }
        if (q == "") {
          if (c == "$" && substr(s, i + 1, 1) == "(") { depth = 1; out = out "$("; i++; continue }
          # バックスラッシュ直後の 1 文字は引用符状態を変えない。ここを素通しすると
          # escape された二重引用符を引用符の開始と読み、以降の実パイプまで伏せてしまう。
          if (c == "\\" && i < length(s)) { out = out "__"; i++; continue }
          if (c == "\x27" || c == "\"") { q = c; out = out "_"; continue }
          if (c == "#" && (i == 1 || prev ~ /[[:space:];&|(]/)) {
            # コメント開始位置を残す（行末マーカーの判定に使う）。開始の `#` だけ素の
            # まま出し、本文は伏せる。
            MASK_CMT = i
            out = out "#"; i++
            while (i <= length(s)) { out = out "_"; i++ }
            break
          }
          out = out c
        } else {
          if (q == "\"" && c == "$" && substr(s, i + 1, 1) == "(") { depth = 1; out = out "$("; i++; continue }
          # 二重引用符の中でもバックスラッシュは次の 1 文字を escape する（単一引用符の
          # 中では literal なので escape しない）。
          if (q == "\"" && c == "\\" && i < length(s)) { out = out "__"; i++; continue }
          if (c == q) q = ""
          out = out "_"
        }
      }
      return out
    }
    # 区間の先頭から、コマンド語の前に来るキーワード・環境変数代入を剥がす。
    # 値に `$(` を含む代入は剥がさない（`out=$(printf ...` の `out=$(printf ` まで
    # 食ってコマンド語が化ける。node-test 側で実測した罠）。
    function strip_prefix(s,   w, guard) {
      guard = 0
      while (guard++ < 12) {
        sub(/^[[:space:]]+/, "", s)
        w = s
        sub(/[[:space:]].*$/, "", w)
        if (w == "") break
        if (w ~ /^[A-Za-z_][A-Za-z0-9_]*=/ && index(w, "$(") == 0) { sub(/^[^[:space:]]+[[:space:]]+/, "", s); continue }
        if (w ~ /^(if|then|else|elif|while|until|do|exec|command|env|sudo|time|!|\{|\()$/) { sub(/^[^[:space:]]+[[:space:]]*/, "", s); continue }
        break
      }
      return s
    }
    function cmdword(s,   w) {
      s = strip_prefix(s)
      w = s
      sub(/[[:space:]].*$/, "", w)
      sub(/^.*\//, "", w)
      return w
    }
    # 上流に置くと打ち切りで死ぬ側。シェル組み込み / 外部いずれの実体でも形は同じ。
    function is_source_cmd(w) { return (w == "printf" || w == "echo" || w == "cat") }
    # 下流の `grep -q`。短オプションの結合（-Eq / -qE / -Fq / -iq）と長形を拾う。
    # `grep -c` や grep 単独は入力を読み切るので**対象外**（言い換え先の 1 つでもある）。
    function is_grep_q(s,   w, n, i, arr) {
      s = strip_prefix(s)
      w = s
      sub(/[[:space:]].*$/, "", w)
      sub(/^.*\//, "", w)
      if (w !~ /^[a-z]*grep$/) return 0
      n = split(s, arr, /[[:space:]]+/)
      for (i = 2; i <= n; i++) {
        if (arr[i] == "--quiet" || arr[i] == "--silent") return 1
        if (arr[i] ~ /^-[A-Za-z]*q[A-Za-z]*$/) return 1
      }
      return 0
    }
    # 伏せた版をパイプ・区切り子で割り、「上流に printf/echo/cat が居るパイプ鎖の
    # 下流に grep -q が居る」形を探す。`||` は論理和なので鎖を切る（パイプではない）。
    # 上流判定を直前の 1 区間に限らないのは、間に別のフィルタを挟んでも上流が
    # EPIPE で死ぬのは同じだから。
    function scan_chain(m,   i, c, a, seg, up, hit, nx, pv, bound, piped) {
      up = 0; hit = 0; a = 1
      for (i = 1; i <= length(m) + 1; i++) {
        c = (i <= length(m)) ? substr(m, i, 1) : ";"
        nx = substr(m, i + 1, 1)
        pv = (i > 1) ? substr(m, i - 1, 1) : ""
        bound = 0; piped = 0
        # `|&` は stderr 込みのパイプなので鎖を繋ぐ（`&` は読み飛ばす）。`||` は論理和で鎖を切る。
        if (c == "|") { bound = 1; if (nx != "|") piped = 1 }
        else if (c == "&") {
          # リダイレクトの `&`（`2>&1` / `&>` / `<&`）は鎖の境界ではない。境界にすると
          # `printf … 2>&1 | grep -q` のような実違反で上流を見失う。
          if (pv != ">" && pv != "<" && nx != ">") bound = 1
        }
        else if (c == ";" || c == "(" || c == ")" || c == "\n") bound = 1
        if (bound) {
          seg = substr(m, a, i - a)
          if (up && is_grep_q(seg)) hit = 1
          if (piped) { if (is_source_cmd(cmdword(seg))) up = 1 }
          else up = 0
          if (c == "|" && (nx == "|" || nx == "&")) i++
          else if (c == "&" && nx == "&") i++
          a = i + 1
        }
      }
      return hit
    }
    # コマンド置換の中身へ同じ判定を当てる（入れ子も辿る）。中身は mask() を通って
    # いないので、ここで改めて伏せてから見る。
    function check_subst(m, raw,   i, c, depth, sa, hit, sub_raw) {
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
          sub_raw = substr(raw, sa, i - sa)
          if (scan_chain(mask(sub_raw))) hit = 1
          if (check_subst(mask(sub_raw), sub_raw)) hit = 1
          i++
        } else i++
      }
      return hit
    }
    # pipefail を設定していないファイルでは反転しないので報告しない。設定行は使用箇所より
    # 後ろにあることもある（関数定義の中など）ため、違反はいったん溜めて END で出す。
    function flush(   i) {
      if (pf) for (i = 1; i <= n; i++) print buf[i]
      n = 0; pf = 0
    }
    function scan(line, start,   m) {
      m = mask(line)
      # 終端に `;` `&` `)` を認めるのは `set -o pipefail;` / `set -euo pipefail)` の形を
      # 取りこぼさないため（取りこぼすとそのファイルは丸ごと無検査になる）。
      if (m ~ /(^|[^[:alnum:]_])set[[:space:]]/ && m ~ /-[A-Za-z]*o[[:space:]]+pipefail([[:space:]]|[;&)]|$)/) pf = 1
      # 行末マーカーによる明示的な除外宣言（ヘッダーコメントの「例外」節が正本）。
      # 実コメントで始まるマーカーだけを認める — 引用符の中の同じ文言で除外できると、
      # 違反行を文字列で包むだけで検査を黙らせられる。
      if (MASK_CMT > 0 && substr(line, MASK_CMT) ~ /^# pipefail-safe:/) return
      if (scan_chain(m) || check_subst(m, line)) { n++; buf[n] = start ":pipefail-grep-q:" line }
    }
    FNR == 1 && NR > 1 { if (joined != "") { scan(joined, start_line); joined = "" } flush() }
    {
      line = $0
      if (joined == "") start_line = FNR
      if (line ~ /\\$/) { sub(/\\$/, "", line); joined = joined line " "; next }
      joined = joined line
      # 行末が `|` / `&&` の行はバックスラッシュ無しで次行へ続く。畳み込まないと
      # 上流と `grep -q` が別の論理行に分かれて鎖が切れる（tests/lib/exit-code-guard.sh と同形）。
      if (mask(joined) ~ /([|]|&&)[[:space:]]*$/) { joined = joined " "; next }
      scan(joined, start_line)
      joined = ""
    }
    END { if (joined != "") scan(joined, start_line); flush() }
  ' "$@"
}

pipefail_grep_q_check_tracked() {
  local repo_root="$1"
  local git_cmd="${FF_PIPEFAIL_GREP_Q_GIT:-git}"
  local all_hits="" scan_errors="" skipped="" scanned=0
  local list="" file first hits rc

  if ! repo_root="$("$git_cmd" -C "$repo_root" rev-parse --show-toplevel 2>/dev/null)"; then
    printf 'PIPEFAIL_GREP_Q_RESULT=error_repo SCANNED=0 HITS=0 ERRORS=1 SKIPPED=0\n'
    echo "リポジトリルートを解決できない（git rev-parse 失敗）" >&2
    return 1
  fi
  if ! list="$("$git_cmd" -C "$repo_root" -c core.quotepath=false ls-files 2>/dev/null)"; then
    printf 'PIPEFAIL_GREP_Q_RESULT=error_list SCANNED=0 HITS=0 ERRORS=1 SKIPPED=0\n'
    echo "tracked ファイル一覧を取得できない（git ls-files 失敗）" >&2
    return 1
  fi
  if [ -z "$list" ]; then
    printf 'PIPEFAIL_GREP_Q_RESULT=error_list SCANNED=0 HITS=0 ERRORS=1 SKIPPED=0\n'
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
        # shebang の集合は tests/shellcheck/verify.sh の SHEBANG_RE・
        # tests/lib/node-test-reporter.sh と同じ形へ揃える。別定義を持つと、片方だけが
        # 拾うファイルが静かに無検査になる。
        case "$first" in
          '#!'*[/\ ]sh|'#!'*[/\ ]sh' '*|'#!'*[/\ ]bash|'#!'*[/\ ]bash' '*|'#!'*[/\ ]dash|'#!'*[/\ ]dash' '*|'#!'*[/\ ]ksh|'#!'*[/\ ]ksh' '*) ;;
          *) continue ;;
        esac ;;
    esac
    set +e
    hits="$(pipefail_grep_q_scan "$repo_root/$file" 2>/dev/null)"
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
  if [ "$has_hits" -eq 1 ]; then
    result=hits
    echo "pipefail 配下でパイプの下流に grep -q を置いている箇所がある" >&2
    echo "  pipefail-grep-q: grep -q は一致した時点で読むのをやめる。上流の printf / echo / cat が" >&2
    echo "                  書き続けていると EPIPE で死に、pipefail がその非 0 をパイプライン全体の" >&2
    echo "                  終了コードにするため、一致が「不一致」へ反転する（否定形 if ! ... は" >&2
    echo "                  偽の緑になる）。payload が小さいうちは起きないので、育った日に壊れる。" >&2
    echo "                  言い換える: grep -q <<<\"\$s\"（here-string） / case / [[ =~ ]] /" >&2
    echo "                  ファイルを直接 grep -q へ渡す / grep -c（入力を読み切る）。" >&2
    echo "                  printf を echo や cat へ言い換えても同じ欠陥なので抜け道にならない" >&2
    echo "                  （3 つとも検出する）。間に別のフィルタを挟む形も同じ。" >&2
    echo "                  payload が原理的に小さいことが自明な箇所だけ、その論理行の行末へ" >&2
    echo "                  「# pipefail-safe: <根拠>」を書いて除外を宣言できる。" >&2
    printf '%s' "$all_hits" | sed 's/^/  | /' >&2
  fi
  if [ "$has_errors" -eq 1 ]; then
    result=error_scan
    echo "走査に失敗したファイルがある — そのファイルの 0 件は主張できない" >&2
    printf '%s' "$scan_errors" | sed 's/^/  | /' >&2
  fi

  printf 'PIPEFAIL_GREP_Q_RESULT=%s SCANNED=%s HITS=%s ERRORS=%s SKIPPED=%s\n' \
    "$result" "$scanned" "$has_hits" "$has_errors" "$skipped_n"

  if [ "$result" = "ok" ]; then
    return 0
  fi
  return 1
}
