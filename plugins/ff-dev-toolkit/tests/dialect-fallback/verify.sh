#!/usr/bin/env bash
#
# GNU / BSD で意味が変わる短オプションを「片方の方言では必ず失敗する」前提で `||` の先頭側に
# 置き、後ろの腕で同じコマンドの別方言へ倒す形を、tracked な shell ソース全体で静的に止める
# （Issue `#1807`。親 Epic `#1650`）。
#
# 背景: この系統の針は `tests/changelog-fragments/cases/identity.sh` にだけ在り、スコープが
# 1 ファイル（changelog 断片ライブラリ）に固定されていた。同じ欠陥が
# `scripts/adapters/adapter-common.sh` で再発し（Issue `#1806`。`stat -f %l … || stat -c %h …`）、
# 週次 CI（Ubuntu）で 5 suite が赤になるまで誰も気付かなかった。macOS の開発ツリーでは BSD 側が
# 正しく動くので、振る舞いテストでは原理的に当たらない。形そのものを縛る。
#
# ── 検出する形（規則表。行を足せば族を広げられる） ─────────────────────────────
#
#   コマンド  先頭側で危険な短オプション           GNU 側の意味（BSD 側の意味）
#   stat      -f（-Lf の結合・-f%z の直結を含む）  --file-system（書式指定）。全オペランドが実在すると
#                                                 rc=0 で FS 統計を stdout へ出す（ACE-1047-1）
#   date      -r（-ur の結合・-r"$e" の直結を含む）--reference=FILE（エポック秒）。同名ファイルが在ると
#                                                 rc=0 でその mtime を返す
#
#   `||` で繋いだ腕の並び（`&&` を含んでよい）のうち、危険な短オプション付きの腕より**後ろ**の
#   腕が同じコマンドを呼んでいたら違反。腕の中のコマンド置換（`n="$(stat -f …)" || n="$(…)"`）・
#   バッククォート・`{ …; }` / `( … )` のグループも辿る — 代入を繋ぐ形（ACE-1817-1）でも、危険側が
#   先だと「誤った成功」で `||` 自体が発火しない回が残るため。正しい形は「両方言で意味が変わらない
#   側（GNU 形）を先に置く」:
#     n="$(stat -c %h "$1" 2>/dev/null)" || n="$(stat -f %l "$1" 2>/dev/null)" || return 1
#     date -u -d "@$e" +%F 2>/dev/null || date -u -r "$e" +%F
#   （BSD の stat -c / date -d は未知オプションとして rc≠0・stdout 空で返るので汚れない）
#
#   論理行: バックスラッシュ継続・行末の `|` / `||` / `&&`（行末コメントは外して判定）・閉じていない `$(`・`|| {` / `&& {` で
#   始まり閉じていないブレースグループは次行へ畳み込む（畳み込みは 200 行で打ち切る）。
#
# ── 当たらない理由の規則（ファイル名での免除はしない） ──────────────────────────
#
#   R1 コメント: POSIX どおり行頭・空白直後などの `#` 以降は散文として伏せる（`${#x}` は伏せない）
#   R2 引用符の中の文字列: `'…'` / `"…"` の中身は実行されないデータとして伏せる（変異プローブが
#      旧形を `printf '%s\n' "…"` で一時ファイルへ書く形がこれに当たる）。ただし `"$(…)"` の中は
#      実行されるので改めて伏せ直して判定する
#   R3 後ろの腕が別のコマンド: `if ! m="$(stat -f …)" || ! chmod …` のように `||` の先が同じ
#      コマンドでなければ方言フォールバックではない（`chmod --reference=` の背後の BSD 専用梯子）
#   R4 `||` を持たない形: `if v="$(stat -c …)"; then …; fi; stat -f …` のように条件分岐で
#      倒す形は本規則の外（関数固有の順序針は identity.sh の stat_c_before_f が持つ）
#   ヒアドキュメント本文は除外しない（生成して実行するスクリプトの本文は実コードなので保守側へ
#   倒す。stub を書く heredoc は方言フォールバックを持たないので当たらない。プローブを書きたい
#   ときは R2 の形で書く）
#
# ── 既知の限界 ─────────────────────────────────────────────────────────────
#   - 非検出側: 引用符の中のバッククォート置換（`"…\`stat -f …\`…"`）。二重引用符の中は `$(…)` だけを辿る
#   - 非検出側: 関数越しの呼び出し（`my_stat -f … || stat -c …` の my_stat の中身は辿らない）
#   - 非検出側: 複数行にまたがるグループを**先頭の腕**に置く形（`{` 改行 `stat -f …` 改行 `} || stat -c …`）。
#     畳み込むのは `|| {` / `&& {` で後ろの腕として開いたグループだけ
#   - 誤検出側: 行をまたぐ引用符文字列の 2 行目以降は引用符の外として読む
#   - 誤検出側: `date -r "$file"`（ファイル参照）は BSD でも同じ意味だが、形では区別しない
#
# 変異検出（2026-09-27 実測。下の各変異は 1 つずつ当てて赤転を確認した。検出器の規則・境界・
# 母集団の導出それぞれに対応する fixture を持つ）:
#   規則表から stat 行を消したコピーは P1〜P5・P7〜P18・P20〜P26・M1・H1 が赤、date 行を消したコピーは P6・P19 が赤になる。
#   引用符の伏せ（R2）を外したコピーは N4・T1 が赤、コメントの伏せ（R1）を外したコピーは N5・T1 が赤、任意の `#` をコメント開始にしたコピーは P17 が赤、引用符外のバックスラッシュ escape を外したコピーは P16 が赤になる。
#   腕の中のコマンド置換の再帰を外したコピーは P3・P5・P7・P14・P23 が赤、区間の中身への再帰を外したコピーは P1・P2・P24〜P26・M1・H1 が赤、区間を読み飛ばさず割るコピーは P1・P2・P3・P5・P7・P14・P20・P21・P23〜P26・M1・H1 が赤になる。
#   `||` で腕に割るときに区間を読み飛ばさないコピーは N12・N13 が赤、バッククォートを区間として扱わないコピーは N13 が赤、ブレースを区間として扱わないコピーは P20・P23・P26 が赤になる。
#   行末コメントを外してから畳み込む処理を外したコピーは P27〜P29 が赤になる。
#   バックスラッシュ継続の畳み込みを外したコピーは P4、行末演算子の畳み込みを外したコピーは P5・P14、行末 `&&` だけを外したコピーは P14、閉じていない `$(` の畳み込みを外したコピーは P24、`|| {` の畳み込みを外したコピーは P23 が赤になり、任意の開きブレースで畳み込むコピーは M1 が赤になる。
#   コマンド語の basename 化を外したコピーは P8、代入前置の剥がしを外したコピーは P12・P13、env 等の前置の剥がしを外したコピーは P13、`&` を境界にしないコピーは P11・P17、`;` を境界にしないコピーは P1〜P26 の全件が赤になる。
#   危険側の腕自身も後ろの腕と数える順序判定のコピーは N1・N2・N8・N9・T1・H1 が赤、間に別の腕を挟むと危険を忘れるコピーは P15 が赤、短オプションの先頭アンカーを外したコピーは N9 が赤、引数直結（-f%z）を拾わないコピーは P18・P19 が赤になる。
#   shebang 判定を外したコピーは H2・T3、*.bash を外したコピーは H2、CRLF 行末の除去を外したコピーは H2、symlink も走査するコピーは H2 が赤になる。
#   作業ツリーから消えた tracked shell を黙って飛ばすコピーは E6、読めないファイルの判定を外したコピーは E5、違反ありで rc=0 を返すコピーは H1、shell 0 件で ok を返すコピーは E3 が赤になる。
#   母集団の大半（tests/ 配下）を落としてアンカーだけ残すコピーは T4 が赤になる。実ツリーの adapter-common.sh を修正前の形へ戻すと T1 と M1 が赤になる。
# 空振り検出: git リポジトリでない走査根（対象の不在）・tracked 一覧が空の repo（集合が空）・shell ソースを 1 件も持たない repo（0 件一致）・awk が非 0 で終わる走査器（書式変更で読めない回の代理）・読めない tracked shell・作業ツリーから消えた tracked shell を与えると E1〜E6 が「違反なし」ではなく検査不成立の赤になり、母集団から adapter-common.sh / 拡張子なし shell のアンカーが消えるか plugin 配下の走査件数が下限を割ると T2〜T4 が赤になる（実測 2026-09-27）。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# plugin 配下で走査されるべき shell ソースの下限（2026-09-27 実測 323 件）。導出が壊れて
# 母集団の大半が落ちてもアンカー 2 件が残る回を赤にするための床で、実数より十分低く置く。
POPULATION_FLOOR=200
# fixture の git init / add が export 済みの GIT_DIR 経由で呼び出し元リポジトリへ届かないようにする
# （Issue `#1348` / `#1368`。identity は書かないが、index を汚す経路は同じ）
# shellcheck source=../lib/git-fixture.sh
. "$SCRIPT_DIR/../lib/git-fixture.sh"

PASS=0
FAIL=0
ok()  { echo "  ✓ $1"; PASS=$((PASS + 1)); }
bad() { echo "  ✗ $1" >&2; FAIL=$((FAIL + 1)); }

if _ff_mktemp_out="$(mktemp -d "${TMPDIR:-/tmp}/ff-dialect-fallback.XXXXXX" 2>&1)" && [ -d "$_ff_mktemp_out" ]; then
  TMP="$_ff_mktemp_out"
else
  echo "✗ 一時ディレクトリを作成できません: ${_ff_mktemp_out}" >&2
  exit 1
fi
REACHED_END=0
cleanup() {
  local rc=$?
  chmod -R u+rw "$TMP" 2>/dev/null || true
  rm -rf "$TMP"
  if [ "$rc" -eq 0 ] && [ "$REACHED_END" -ne 1 ]; then
    echo "✗ dialect-fallback: 最後まで到達しませんでした（途中で中断）" >&2
    exit 1
  fi
  exit "$rc"
}
trap cleanup EXIT

# ── 走査器 ────────────────────────────────────────────────────────────────
# dialect_fallback_scan [file] — 違反を「開始行:dialect-fallback:<コマンド> -<短オプション>:論理行」で
# stdout へ出す（違反なしは空）。awk の非 0 は呼び出し側へそのまま返す（違反の有無ではなく検査不能）。
# mask() は tests/lib/pipefail-grep-q.sh と同じ契約（入出力の長さを 1:1 に保つ / コマンド置換の中は
# 伏せたまま位置だけ残し、呼び出し側が改めて伏せて判定する / `#` は行頭・空白直後などでだけコメント開始）。
# 1 回の呼び出しには 1 ファイルだけを渡す（継続行の畳み込みがファイル境界をまたがないように）。
DIALECT_AWK=awk  # E4 だけが呼び出し単位の前置代入で差し替える（環境からは読まない）
dialect_fallback_scan() {
  LC_ALL=C "$DIALECT_AWK" '
    BEGIN {
      # 規則表（ヘッダの表と 1:1。行を足すときは陽性 fixture も 1 本足す）
      nr = 0
      nr++; RC[nr] = "stat"; RF[nr] = "f"
      nr++; RC[nr] = "date"; RF[nr] = "r"
      JOIN_CAP = 200
    }
    function mask(s,   i, c, prev, out, q, depth) {
      out = ""; q = ""; depth = 0
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
          if (c == "\\" && i < length(s)) { out = out "__"; i++; continue }
          if (c == "\x27" || c == "\"") { q = c; out = out "_"; continue }
          if (c == "#" && (i == 1 || prev ~ /[[:space:];&|(]/)) {
            out = out "#"; i++
            while (i <= length(s)) { out = out "_"; i++ }
            break
          }
          out = out c
        } else {
          if (q == "\"" && c == "$" && substr(s, i + 1, 1) == "(") { depth = 1; out = out "$("; i++; continue }
          if (q == "\"" && c == "\\" && i < length(s)) { out = out "__"; i++; continue }
          if (c == q) q = ""
          out = out "_"
        }
      }
      MASK_DEPTH = depth
      return out
    }
    function strip_prefix(s,   w, guard) {
      guard = 0
      while (guard++ < 12) {
        sub(/^[[:space:]]+/, "", s)
        w = s
        sub(/[[:space:]].*$/, "", w)
        if (w == "") break
        if (w ~ /^[A-Za-z_][A-Za-z0-9_]*=/ && index(w, "$(") == 0) { sub(/^[^[:space:]]+[[:space:]]*/, "", s); continue }
        if (w ~ /^(if|then|else|elif|while|until|do|exec|command|env|sudo|time|!|\{|\(|local|export|readonly)$/) { sub(/^[^[:space:]]+[[:space:]]*/, "", s); continue }
        break
      }
      return s
    }
    # ブレースグループの開き / 閉じ（`${x}` や `{a,b}` は語でないので数えない）
    function is_open_brace(m, i,   p, x) {
      if (substr(m, i, 1) != "{") return 0
      p = (i > 1) ? substr(m, i - 1, 1) : " "
      x = substr(m, i + 1, 1)
      return (p ~ /[[:space:];&|(]/ && (x == "" || x ~ /[[:space:]]/))
    }
    function is_close_brace(m, i,   p, x) {
      if (substr(m, i, 1) != "}") return 0
      p = (i > 1) ? substr(m, i - 1, 1) : " "
      x = substr(m, i + 1, 1)
      return (p ~ /[[:space:];&]/ && (x == "" || x ~ /[[:space:];&|)<>]/))
    }
    # 伏せた版の位置 i が区間の開き（`$(` / `(` / バッククォート / ブレースグループ）か
    function is_opener(m, i,   c) {
      c = substr(m, i, 1)
      if (c == "`" || c == "(") return 1
      if (c == "$" && substr(m, i + 1, 1) == "(") return 1
      return is_open_brace(m, i)
    }
    # 開きに対応する閉じの位置（閉じが無ければ末尾）
    function span_end(m, i,   c, d, n) {
      n = length(m)
      c = substr(m, i, 1)
      if (c == "`") { i++; while (i <= n && substr(m, i, 1) != "`") i++; return (i > n) ? n : i }
      if (c == "$") i++
      c = substr(m, i, 1)
      if (c == "(") {
        d = 0
        for (; i <= n; i++) {
          c = substr(m, i, 1)
          if (c == "(") d++
          else if (c == ")") { d--; if (d == 0) return i }
        }
        return n
      }
      d = 0
      for (; i <= n; i++) {
        if (is_open_brace(m, i)) d++
        else if (is_close_brace(m, i)) { d--; if (d == 0) return i }
      }
      return n
    }
    function span_inner_start(m, i) { return (substr(m, i, 1) == "$") ? i + 2 : i + 1 }
    # 1 つの単純コマンド（伏せた版）を見て、規則ごとに「このコマンドを呼ぶ」「危険な短オプション付きで
    # 呼ぶ」を AU / AD へ立てる。短オプションは結合（-Lf）と引数の直結（-f%z）を含む。
    function note_simple(seg,   s, n, arr, w, r, k) {
      s = strip_prefix(seg)
      n = split(s, arr, /[[:space:]]+/)
      if (n < 1) return
      w = arr[1]
      sub(/^.*\//, "", w)
      for (r = 1; r <= nr; r++) {
        if (w != RC[r]) continue
        AU[r] = 1
        for (k = 2; k <= n; k++) {
          if (arr[k] == "--") break
          if (arr[k] ~ ("^-[A-Za-z]*" RF[r])) AD[r] = 1
        }
      }
    }
    # 腕（生の文字列）に含まれる単純コマンドをすべて note_simple へ渡す。コマンド置換の中も辿る
    # （バッククォート・グループの中身は伏せていないので、境界で割るだけで届く）。
    function note_cmds(raw,   m, i, c, nx, pv, a, bound, e, s) {
      m = mask(raw)
      a = 1
      for (i = 1; i <= length(m) + 1; i++) {
        c = (i <= length(m)) ? substr(m, i, 1) : ";"
        nx = substr(m, i + 1, 1)
        pv = (i > 1) ? substr(m, i - 1, 1) : ""
        bound = 0
        if (c == "|" || c == ";" || c == "(" || c == ")" || c == "`") bound = 1
        else if (c == "&" && pv != ">" && pv != "<" && nx != ">") bound = 1
        if (bound) {
          note_simple(substr(m, a, i - a))
          if ((c == "|" && nx == "|") || (c == "&" && nx == "&")) i++
          a = i + 1
        }
      }
      i = 1
      while (i <= length(m)) {
        if (substr(m, i, 2) == "$(") {
          e = span_end(m, i); s = i + 2
          note_cmds(substr(raw, s, e - s))
          i = e + 1
        } else i++
      }
    }
    # 1 つのリスト（生の文字列）を、区間の外にある `||` で腕に割り、危険側より後ろの腕が同じ
    # コマンドを呼んでいれば、その規則番号を HIT[] に立てる。
    function check_list(raw,   m, i, c, nx, a, k, r, danger, n) {
      m = mask(raw)
      if (index(m, "||") == 0) return
      k = 0; a = 1; n = length(m)
      i = 1
      while (i <= n + 1) {
        if (i <= n && is_opener(m, i)) { i = span_end(m, i) + 1; continue }
        c = (i <= n) ? substr(m, i, 1) : ""
        nx = substr(m, i + 1, 1)
        if (c == "" || (c == "|" && nx == "|")) {
          k++; ARM[k] = substr(raw, a, i - a)
          if (c != "") i++
          a = i + 1
        }
        i++
      }
      if (k < 2) return
      for (r = 1; r <= nr; r++) {
        danger = 0
        for (i = 1; i <= k; i++) {
          AU[r] = 0; AD[r] = 0
          note_cmds(ARM[i])
          if (danger && AU[r]) { HIT[r] = 1; break }
          if (AD[r]) danger = 1
        }
      }
    }
    # 論理行（生）を、区間の外にある `;` / 改行 / 単独の `&` / 対の無い `)` でリストへ割って
    # check_list へ渡し、各区間（`$(…)` / `(…)` / バッククォート / `{ …; }`）の中身へは同じ処理を
    # 再帰で当てる（区間の中で完結する `$(A || B)` を拾うため）。
    function scan_stmt(raw,   m, i, c, nx, pv, a, bound, e, s, n) {
      m = mask(raw)
      n = length(m)
      a = 1
      i = 1
      while (i <= n + 1) {
        if (i <= n && is_opener(m, i)) {
          e = span_end(m, i); s = span_inner_start(m, i)
          if (e > s) scan_stmt(substr(raw, s, e - s))
          i = e + 1
          continue
        }
        c = (i <= n) ? substr(m, i, 1) : ";"
        nx = substr(m, i + 1, 1)
        pv = (i > 1) ? substr(m, i - 1, 1) : ""
        bound = 0
        if (c == ";" || c == ")" || c == "\n") bound = 1
        else if (c == "&" && nx != "&" && pv != "&" && pv != ">" && pv != "<" && nx != ">") bound = 1
        if (bound) {
          check_list(substr(raw, a, i - a))
          a = i + 1
        }
        i++
      }
    }
    function scan(line, start,   r) {
      # 規則表のコマンド名と `||` の両方を含まない行は判定しない（走査時間の節約。判定は変えない）
      if (index(line, "||") == 0) return
      if (line !~ /(stat|date)/) return
      for (r = 1; r <= nr; r++) HIT[r] = 0
      scan_stmt(line)
      for (r = 1; r <= nr; r++) if (HIT[r]) print start ":dialect-fallback:" RC[r] " -" RF[r] ":" line
    }
    # 伏せた版の中の、開いたまま閉じていないブレースグループの数
    function open_braces(m,   i, d) {
      d = 0
      for (i = 1; i <= length(m); i++) {
        if (is_open_brace(m, i)) d++
        else if (is_close_brace(m, i)) d--
      }
      return d
    }
    function flush() {
      if (joined != "") scan(joined, start_line)
      joined = ""; nj = 0; group = 0
    }
    {
      line = $0
      sub(/\r$/, "", line)
      if (joined == "") start_line = FNR
      nj++
      if (nj < JOIN_CAP && line ~ /\\$/) { sub(/\\$/, "", line); joined = joined line " "; next }
      joined = joined line
      if (nj < JOIN_CAP) {
        m = mask(joined)
        # 行末のコメントは畳み込みの判定より先に外す（`stat -f … || # 注記` 改行 `stat -c …` や、
        # `||` の後ろにコメントだけの行を挟む形でも、未完了の `||` を保持するため）
        if (match(m, /#_*$/) && (RSTART == 1 || substr(m, RSTART - 1, 1) ~ /[[:space:];&|(]/)) {
          joined = substr(joined, 1, RSTART - 1)
          m = substr(m, 1, RSTART - 1)
        }
        # 行末が `|` / `||` / `&&` の行はバックスラッシュ無しで次行へ続く
        if (m ~ /([|]|&&)[[:space:]]*$/) { joined = joined " "; next }
        # 閉じていない `$(`: 中身の改行は区切り子。行末が演算子なら空白で繋ぐ
        if (MASK_DEPTH > 0) {
          if (line ~ /(\|\||&&|\|)[[:space:]]*$/) joined = joined " "
          else joined = joined " ; "
          next
        }
        # `|| {` / `&& {` で開いた後ろの腕のグループが閉じるまで畳み込む
        if (group || m ~ /(\|\||&&)[[:space:]]*\{[[:space:]]*$/) {
          group = 1
          if (open_braces(m) > 0) { joined = joined " ; "; next }
        }
      }
      flush()
    }
    END { flush() }
  ' "$@"
}

# dialect_fallback_check_tracked ROOT — ROOT を含む git リポジトリの tracked shell ソースを横断走査する。
# stdout 1 行目に機械可読サマリー、続けて走査したファイルの相対パス（SCANNED_FILE=…）を出す。
# 違反・走査失敗の詳細は stderr。終了コード: 0=違反なし / 1=違反あり / 2=検査不成立（0 件の主張はしない）。
dialect_fallback_check_tracked() {
  local root="$1" top list_file err_file file first hits rc scanned=0 all_hits="" errors="" files=""
  list_file="$TMP/ls-files.$$.$RANDOM"
  err_file="$TMP/scan-err.$$.$RANDOM"
  if ! top="$(git -C "$root" rev-parse --show-toplevel 2>"$err_file")"; then
    printf 'DIALECT_FALLBACK_RESULT=error_repo SCANNED=0\n'
    sed 's/^/  | /' "$err_file" >&2
    return 2
  fi
  if ! git -C "$top" ls-files -z > "$list_file" 2>"$err_file"; then
    printf 'DIALECT_FALLBACK_RESULT=error_list SCANNED=0\n'
    sed 's/^/  | /' "$err_file" >&2
    return 2
  fi
  if [ ! -s "$list_file" ]; then
    printf 'DIALECT_FALLBACK_RESULT=error_list SCANNED=0\n'
    echo "  | tracked 一覧が空 — 0 件の主張はできない" >&2
    return 2
  fi
  while IFS= read -r -d '' file; do
    [ -n "$file" ] || continue
    # tracked の symlink は実体側（tracked なら別に走査される）へ任せる
    [ ! -L "$top/$file" ] || continue
    if [ ! -e "$top/$file" ]; then
      case "$file" in
        *.sh|*.bash) errors="${errors}${file} (tracked だが作業ツリーに無い)
" ;;
      esac
      continue
    fi
    [ -f "$top/$file" ] || continue
    if [ ! -r "$top/$file" ]; then
      errors="${errors}${file} (unreadable)
"
      continue
    fi
    case "$file" in
      *.sh|*.bash) ;;
      *)
        first=""
        IFS= read -r first < "$top/$file" || true
        first="${first%$'\r'}"
        # shebang の集合は tests/lib/pipefail-grep-q.sh / tests/shellcheck/verify.sh と同じ形
        case "$first" in
          '#!'*[/\ ]sh|'#!'*[/\ ]sh' '*|'#!'*[/\ ]bash|'#!'*[/\ ]bash' '*|'#!'*[/\ ]dash|'#!'*[/\ ]dash' '*|'#!'*[/\ ]ksh|'#!'*[/\ ]ksh' '*) ;;
          *) continue ;;
        esac ;;
    esac
    rc=0
    hits="$(dialect_fallback_scan "$top/$file" 2>"$err_file")" || rc=$?
    if [ "$rc" -ne 0 ]; then
      errors="${errors}${file} (awk rc=${rc}: $(head -n 1 "$err_file"))
"
      continue
    fi
    scanned=$((scanned + 1))
    files="${files}SCANNED_FILE=${file}
"
    if [ -n "$hits" ]; then
      all_hits="${all_hits}$(printf '%s\n' "$hits" | sed "s|^|${file}:|")
"
    fi
  done < "$list_file"

  if [ -n "$errors" ]; then
    printf 'DIALECT_FALLBACK_RESULT=error_scan SCANNED=%s\n' "$scanned"
    printf '%s' "$errors" | sed 's/^/  | /' >&2
    return 2
  fi
  if [ "$scanned" -eq 0 ]; then
    printf 'DIALECT_FALLBACK_RESULT=error_empty SCANNED=0\n'
    echo "  | shell ソースが 1 件も無い — 0 件の主張はできない" >&2
    return 2
  fi
  if [ -n "$all_hits" ]; then
    printf 'DIALECT_FALLBACK_RESULT=hits SCANNED=%s\n' "$scanned"
    printf '%s' "$files"
    printf '%s' "$all_hits" | sed 's/^/  | /' >&2
    return 1
  fi
  printf 'DIALECT_FALLBACK_RESULT=ok SCANNED=%s\n' "$scanned"
  printf '%s' "$files"
  return 0
}

# ── 検出器の自己検査（fixture は printf で書く — 本ファイル自身が違反を持たないように） ──────
# 1 fixture = 1 論理行（継続行を含む）。期待タグは規則表のどの行が当たるべきか。
fx() { # $1=名前 $2...=本文の行
  local name="$1"; shift
  printf '%s\n' "$@" > "$TMP/$name.sh"
}
expect_hit() { # $1=検査 ID $2=fixture 名 $3=期待タグ（stat -f など）
  local out rc=0
  out="$(dialect_fallback_scan "$TMP/$2.sh")" || rc=$?
  if [ "$rc" -ne 0 ]; then
    bad "$1: 走査器が rc=${rc} で終わった（$2）"
  elif [[ "$out" == *":dialect-fallback:$3:"* ]]; then
    ok "$1: $2 を $3 の方言フォールバックとして検出する"
  else
    bad "$1: $2 を検出しない（期待 $3 / 出力 [${out}]）"
  fi
}
expect_clean() { # $1=検査 ID $2=fixture 名 $3=当たらない理由
  local out rc=0
  out="$(dialect_fallback_scan "$TMP/$2.sh")" || rc=$?
  if [ "$rc" -ne 0 ]; then
    bad "$1: 走査器が rc=${rc} で終わった（$2）"
  elif [ -z "$out" ]; then
    ok "$1: $2 は当たらない（$3）"
  else
    bad "$1: $2 を誤検出する（$3 / 出力 [${out}]）"
  fi
}

echo "== 方言フォールバック検出器: 陽性 fixture =="
Q="'"
B='`'
fx p1 'n="$(stat -f %l "$1" 2>/dev/null || stat -c %h "$1" 2>/dev/null)"'
expect_hit P1 p1 'stat -f'
fx p2 "read_file_identity() { stat -f ${Q}%d:%i${Q} \"\$1\" 2>/dev/null || stat -c ${Q}%d:%i${Q} \"\$1\" 2>/dev/null; }"
expect_hit P2 p2 'stat -f'
fx p3 'n="$(stat -f %l "$1")" || n="$(stat -c %h "$1")" || return 1'
expect_hit P3 p3 'stat -f'
fx p4 'stat -f %l "$f" 2>/dev/null \' '  || stat -c %h "$f"'
expect_hit P4 p4 'stat -f'
fx p5 'v="$(stat -Lf %z "$f")" ||' '  v="$(stat -c %s "$f")"'
expect_hit P5 p5 'stat -f'
fx p6 'date -u -r "$e" +%F 2>/dev/null || date -u -d "@$e" +%F'
expect_hit P6 p6 'date -r'
fx p7 'x="$(stat -f %l "$f")" && [ -n "$x" ] || x="$(stat -c %h "$f")"'
expect_hit P7 p7 'stat -f'
fx p8 '/usr/bin/stat -f %l "$f" || /usr/bin/stat -c %h "$f"'
expect_hit P8 p8 'stat -f'
fx p9 'if command stat -f %l "$f" || stat -c %h "$f"; then :; fi'
expect_hit P9 p9 'stat -f'
fx p10 'cat > "$gen" <<EOF' 'stat -f %l x 2>/dev/null || stat -c %h x' 'EOF'
expect_hit P10 p10 'stat -f'
fx p11 '[ -e "$f" ] && stat -f %l "$f" || stat -c %h "$f"'
expect_hit P11 p11 'stat -f'
fx p12 'LC_ALL=C stat -f %m "$f" || LC_ALL=C stat -c %Y "$f"'
expect_hit P12 p12 'stat -f'
fx p13 'env LC_ALL=C stat -f %m "$f" || env LC_ALL=C stat -c %Y "$f"'
expect_hit P13 p13 'stat -f'
fx p14 'x="$(stat -f %l "$f")" &&' '  [ -n "$x" ] || x="$(stat -c %h "$f")"'
expect_hit P14 p14 'stat -f'
fx p15 'stat -f %l "$f" 2>/dev/null || : || stat -c %h "$f"'
expect_hit P15 p15 'stat -f'
fx p16 'msg=don\'"${Q}"'t; stat -f %l "$f" || stat -c %h "$f"'
expect_hit P16 p16 'stat -f'
fx p17 '[ ${#f} -gt 0 ] && stat -f %l "$f" || stat -c %h "$f"'
expect_hit P17 p17 'stat -f'
fx p18 'stat -f%z "$f" 2>/dev/null || stat -c%s "$f"'
expect_hit P18 p18 'stat -f'
fx p19 'date -r"$e" +%F 2>/dev/null || date -d "@$e" +%F'
expect_hit P19 p19 'date -r'
fx p20 '{ stat -f %l "$f"; } 2>/dev/null || stat -c %h "$f"'
expect_hit P20 p20 'stat -f'
fx p21 '( stat -f %l "$f" ) 2>/dev/null || stat -c %h "$f"'
expect_hit P21 p21 'stat -f'
fx p22 "n=${B}stat -f %l \"\$f\"${B} || n=${B}stat -c %h \"\$f\"${B}"
expect_hit P22 p22 'stat -f'
fx p23 'n="$(stat -f %l "$f" 2>/dev/null)" || {' '  n="$(stat -c %h "$f")"' '}'
expect_hit P23 p23 'stat -f'
fx p24 'n="$(stat -f %l "$f" 2>/dev/null ||' '  stat -c %h "$f")"'
expect_hit P24 p24 'stat -f'
fx p25 'n="$(' '  stat -f %l "$f" 2>/dev/null || stat -c %h "$f"' ')"'
expect_hit P25 p25 'stat -f'
fx p26 'n=$( { stat -f %l "$f" 2>/dev/null; } || stat -c %h "$f")'
expect_hit P26 p26 'stat -f'
fx p27 'stat -f %l "$f" 2>/dev/null || # GNU 側へ倒す' '  stat -c %h "$f"'
expect_hit P27 p27 'stat -f'
fx p28 'stat -f %l "$f" 2>/dev/null ||' '  # GNU 側へ倒す' '  stat -c %h "$f"'
expect_hit P28 p28 'stat -f'
fx p29 'x="$(stat -f %l "$f")" && # 取れたら検証' '  [ -n "$x" ] || x="$(stat -c %h "$f")"'
expect_hit P29 p29 'stat -f'

echo "== 方言フォールバック検出器: 陰性 fixture（当たらない理由の規則） =="
fx n1 'n="$(stat -c %h "$1" 2>/dev/null)" || n="$(stat -f %l "$1" 2>/dev/null)" || return 1'
expect_clean N1 n1 'GNU 形が先（危険側が最後の腕）'
fx n2 "if ! m=\"\$(stat -f ${Q}%Lp${Q} \"\$f\" 2>/dev/null)\" || ! e=\"\$(chmod \"\$m\" \"\$g\" 2>&1)\"; then exit 2; fi"
expect_clean N2 n2 'R3: 後ろの腕が別のコマンド（chmod --reference= の背後の梯子）'
fx n3 'if v="$(stat -c "$g" "$p" 2>/dev/null)" && [[ -n "$v" ]]; then' '  printf "%s\n" "$v"; return 0' 'fi' 'stat -f "$b" "$p"'
expect_clean N3 n3 'R4: || を持たない条件分岐の形'
fx n4 "printf '%s\\n' \"f() { stat -f ${Q}%d:%i${Q} \\\"\\\$1\\\" 2>/dev/null || stat -c ${Q}%d:%i${Q} \\\"\\\$1\\\"; }\" >> \"\$t\""
expect_clean N4 n4 'R2: 引用符の中の文字列（変異プローブ）'
fx n5 '# 旧形は `$(stat -f … || stat -c …)` とコマンドを繋いでいた' 'x=1 # stat -f %l f || stat -c %h f'
expect_clean N5 n5 'R1: コメント'
fx n6 'if [[ "${1:-}" == "-f" ]]; then' '  [[ -e "${2:-}" ]] || { echo "stat: cannot read" >&2; exit 1; }' 'fi'
expect_clean N6 n6 'stub の -f 分岐（stat を呼ぶ || が無い）'
fx n7 'tmp="$(mktemp -d -t ffm || mktemp -d)"'
expect_clean N7 n7 '規則表に無いコマンド'
fx n8 'date -u -d "@$e" +%F 2>/dev/null || date -u -r "$e" +%F'
expect_clean N8 n8 'GNU 形が先の date'
fx n9 'stat --format=%h "$f" 2>/dev/null || stat -f %l "$f"'
expect_clean N9 n9 '長形の GNU オプションは短オプションの規則に当たらない'
fx n10 'stat -f %l "$a"; x=1 || stat -c %h "$b"'
expect_clean N10 n10 '別リスト（; の後ろ）の || は危険側の後ろの腕ではない'
fx n11 'f() {' '  stat -f %l "$1"' '}' 'g || stat -c %h "$f"'
expect_clean N11 n11 '関数本体（|| の腕として開いていないグループ）は畳み込まない'
fx n12 '( stat -f %l "$a" 2>/dev/null || true ) && stat -c %h "$b"'
expect_clean N12 n12 'グループの中の || はグループの外の腕を作らない'
fx n13 "n=${B}stat -f %l \"\$a\" || true${B} && stat -c %h \"\$b\""
expect_clean N13 n13 'バッククォートの中の || は外の腕を作らない'
fx n14 'stat -c %h "$f" 2>/dev/null || # BSD 側へ倒す' '  stat -f %l "$f"'
expect_clean N14 n14 'コメントを挟む継続でも GNU 形が先'

echo "== 実ツリーへの変異注入（再発元を修正前の形へ戻したコピー） =="
REL_PREFIX=""
if REL_PREFIX="$(git -C "$PLUGIN_ROOT" rev-parse --show-prefix 2>/dev/null)"; then :; else
  bad "M0: plugin 配下の相対位置（rev-parse --show-prefix）を解決できない"
  REL_PREFIX=""
fi
ADAPTER="$PLUGIN_ROOT/scripts/adapters/adapter-common.sh"
FIXED_LINE='  n="$(stat -c %h "$1" 2>/dev/null)" || n="$(stat -f %l "$1" 2>/dev/null)" || return 1'
OLD_LINE='  n="$(stat -f %l "$1" 2>/dev/null || stat -c %h "$1" 2>/dev/null)" || return 1'
if [ ! -f "$ADAPTER" ]; then
  bad "M1: 変異の母体 adapter-common.sh が無い（${ADAPTER}）"
elif ! grep -Fx -- "$FIXED_LINE" "$ADAPTER" >/dev/null; then
  bad "M1: adapter-common.sh に修正後の行が無く変異を当てられない（行が変わったら FIXED_LINE / OLD_LINE を追随させる）"
else
  awk -v fixed="$FIXED_LINE" -v old="$OLD_LINE" '$0 == fixed { print old; next } { print }' "$ADAPTER" > "$TMP/adapter-old.sh"
  m_rc=0
  m_out="$(dialect_fallback_scan "$TMP/adapter-old.sh")" || m_rc=$?
  if ! grep -Fx -- "$OLD_LINE" "$TMP/adapter-old.sh" >/dev/null; then
    bad "M1: 変異が適用されていない"
  elif [ "$m_rc" -eq 0 ] && [[ "$m_out" == *":dialect-fallback:stat -f:"* ]]; then
    ok "M1: adapter-common.sh を修正前の形へ戻したコピーは検出される"
  else
    bad "M1: adapter-common.sh の修正前の形を見逃す（rc=${m_rc} / 出力 [${m_out}]）"
  fi
fi

echo "== 横断走査の経路（fixture リポジトリ） =="
expect_unfit() { # $1=検査 ID $2=走査根 $3=期待 RESULT $4=説明
  local out rc=0
  out="$(dialect_fallback_check_tracked "$2" 2>/dev/null)" || rc=$?
  if [ "$rc" -eq 2 ] && [[ "$out" == "DIALECT_FALLBACK_RESULT=$3 "* ]]; then
    ok "$1: $4 は検査不成立（$3）として赤"
  else
    bad "$1: $4 が検査不成立にならない（rc=${rc} / [${out%%$'\n'*}]）"
  fi
}
mkdir -p "$TMP/not-a-repo"
expect_unfit E1 "$TMP/not-a-repo" error_repo 'git リポジトリでない走査根'
git init -q "$TMP/empty-repo"
expect_unfit E2 "$TMP/empty-repo" error_list 'tracked 一覧が空の repo'
git init -q "$TMP/noshell-repo"
printf 'x\n' > "$TMP/noshell-repo/README.md"
git -C "$TMP/noshell-repo" add README.md
expect_unfit E3 "$TMP/noshell-repo" error_empty 'shell ソースを 1 件も持たない repo'
git init -q "$TMP/awkfail-repo"
printf '#!/usr/bin/env bash\ntrue\n' > "$TMP/awkfail-repo/a.sh"
git -C "$TMP/awkfail-repo" add a.sh
e4_rc=0
e4_out="$(DIALECT_AWK=false dialect_fallback_check_tracked "$TMP/awkfail-repo" 2>/dev/null)" || e4_rc=$?
if [ "$e4_rc" -eq 2 ] && [[ "$e4_out" == "DIALECT_FALLBACK_RESULT=error_scan "* ]]; then
  ok "E4: 走査器（awk）の非 0 は検査不成立（error_scan）として赤"
else
  bad "E4: 走査器の失敗が検査不成立にならない（rc=${e4_rc} / [${e4_out%%$'\n'*}]）"
fi
if [ "$(id -u)" -eq 0 ]; then
  echo "  ○ E5: root では読み取り権限を落とせないため未検査（読めない tracked shell）"
else
  git init -q "$TMP/unreadable-repo"
  printf '#!/usr/bin/env bash\ntrue\n' > "$TMP/unreadable-repo/a.sh"
  git -C "$TMP/unreadable-repo" add a.sh
  chmod 000 "$TMP/unreadable-repo/a.sh"
  expect_unfit E5 "$TMP/unreadable-repo" error_scan '読めない tracked shell'
  e5_err="$(dialect_fallback_check_tracked "$TMP/unreadable-repo" 2>&1 >/dev/null || true)"
  if [[ "$e5_err" == *"a.sh (unreadable)"* ]]; then
    ok "E5b: 読めない理由をファイル名付きで名指しする"
  else
    bad "E5b: 読めない tracked shell の理由が出ない（[${e5_err}]）"
  fi
  chmod 644 "$TMP/unreadable-repo/a.sh"
fi
git init -q "$TMP/missing-repo"
printf '#!/usr/bin/env bash\ntrue\n' > "$TMP/missing-repo/a.sh"
printf 'true\n' > "$TMP/missing-repo/b.sh"
git -C "$TMP/missing-repo" add a.sh b.sh
rm -f "$TMP/missing-repo/b.sh"
expect_unfit E6 "$TMP/missing-repo" error_scan '作業ツリーから消えた tracked shell'

# 違反ありの経路: 違反ファイルを名指しして rc=1 / RESULT=hits を返す
git init -q "$TMP/hits-repo"
printf '%s\n' 'n="$(stat -f %l "$1" || stat -c %h "$1")"' > "$TMP/hits-repo/a.sh"
printf '%s\n' 'n="$(stat -c %h "$1")" || n="$(stat -f %l "$1")"' > "$TMP/hits-repo/b.sh"
git -C "$TMP/hits-repo" add a.sh b.sh
h_rc=0
h_out="$(dialect_fallback_check_tracked "$TMP/hits-repo" 2>"$TMP/hits.err")" || h_rc=$?
if [ "$h_rc" -eq 1 ] && [[ "$h_out" == "DIALECT_FALLBACK_RESULT=hits SCANNED=2"* ]] \
    && grep -F 'a.sh:1:dialect-fallback:stat -f:' "$TMP/hits.err" >/dev/null \
    && ! grep -F 'b.sh:' "$TMP/hits.err" >/dev/null; then
  ok "H1: 違反ファイルだけを名指しして rc=1（RESULT=hits）を返す"
else
  bad "H1: 違反ありの経路が壊れている（rc=${h_rc} / [${h_out%%$'\n'*}]）"
fi

# 母集団の導出: *.sh / *.bash / sh 系 shebang（CRLF を含む）を拾い、shell でないものと symlink は拾わない
git init -q "$TMP/pop-repo"
printf 'true\n' > "$TMP/pop-repo/a.sh"
printf 'true\n' > "$TMP/pop-repo/b.bash"
printf '#!/bin/sh\ntrue\n' > "$TMP/pop-repo/c"
printf '#!/usr/bin/env bash\r\ntrue\r\n' > "$TMP/pop-repo/d"
printf '#!/bin/dash\ntrue\n' > "$TMP/pop-repo/e"
printf '#!/usr/bin/env python3\nprint(1)\n' > "$TMP/pop-repo/f"
ln -s a.sh "$TMP/pop-repo/g.sh"
git -C "$TMP/pop-repo" add a.sh b.bash c d e f g.sh
p_rc=0
p_out="$(dialect_fallback_check_tracked "$TMP/pop-repo" 2>/dev/null)" || p_rc=$?
p_files="$(printf '%s\n' "$p_out" | sed -n 's/^SCANNED_FILE=//p' | sort | tr '\n' ' ')"
if [ "$p_rc" -eq 0 ] && [ "$p_files" = "a.sh b.bash c d e " ]; then
  ok "H2: 母集団は *.sh / *.bash / sh 系 shebang（CRLF 含む）で、shell でないものと symlink を含まない"
else
  bad "H2: 母集団の導出が期待と違う（rc=${p_rc} / 走査=[${p_files}] 期待=[a.sh b.bash c d e ]）"
fi

echo "== 横断走査（tracked shell ソース全体） =="
t_rc=0
t_out="$(dialect_fallback_check_tracked "$PLUGIN_ROOT")" || t_rc=$?
t_summary="${t_out%%$'\n'*}"
if [ "$t_rc" -eq 0 ]; then
  ok "T1: tracked shell ソースに方言フォールバックの違反は無い（${t_summary}）"
elif [ "$t_rc" -eq 1 ]; then
  bad "T1: GNU / BSD で意味が変わる短オプションを || の先頭側に置いた箇所がある（${t_summary}。詳細は上の | 行）"
  echo "    直し方: 両方言で意味が変わらない GNU 形（stat -c / date -d）を先に置く。失敗時にも stdout を出すコマンドは代入そのものを || で繋ぐ（ACE-1047-1 / ACE-1817-1）" >&2
else
  bad "T1: 横断走査が成立しない（${t_summary}）"
fi
# 母集団のアンカー: 再発元（*.sh）と拡張子なし shell（shebang 判定でだけ入る）が走査されていること
anchor() { # $1=検査 ID $2=plugin 相対パス $3=説明
  local want="SCANNED_FILE=${REL_PREFIX}$2"
  if [[ $'\n'"$t_out"$'\n' == *$'\n'"$want"$'\n'* ]]; then
    ok "$1: 母集団に $3 が入っている（$2）"
  else
    bad "$1: 母集団に $3 が無い（$2 — 走査対象の導出が壊れている）"
  fi
}
anchor T2 scripts/adapters/adapter-common.sh '再発元の adapter-common.sh'
anchor T3 tests/changelog-fragments/fixtures/bin/git '拡張子なしの shell（shebang 判定）'
pop_n="$(printf '%s\n' "$t_out" | grep -c -F "SCANNED_FILE=${REL_PREFIX}" || true)"
if [ "${pop_n:-0}" -ge "$POPULATION_FLOOR" ]; then
  ok "T4: plugin 配下の走査件数 ${pop_n} は下限 ${POPULATION_FLOOR} 以上"
else
  bad "T4: plugin 配下の走査件数 ${pop_n:-0} が下限 ${POPULATION_FLOOR} を割った（母集団の導出が壊れている）"
fi

REACHED_END=1
echo ""
echo "dialect-fallback: pass=${PASS} fail=${FAIL}"
[ "$FAIL" -eq 0 ]
