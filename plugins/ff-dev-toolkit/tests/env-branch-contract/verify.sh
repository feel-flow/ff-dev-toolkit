#!/usr/bin/env bash
#
# 能力層の外に新しい環境分岐（OS 名・MSYS 名・bash 版・coproc）を書けなくする非回帰ゲート
# （Issue `#2713`。親 Epic `#2709`。ADR-084 決定 3「環境分岐は能力層にだけ置く」を文言だけにしない）。
#
# 走査対象: この plugin を含む git リポジトリの tracked shell ソースのうち、plugin の親ディレクトリ
# （開発元・公開リポジトリのどちらも plugins/）の配下。`*.sh` / `*.bash` と sh 系 shebang を持つ
# 拡張子なしファイルで、CRLF 行末は外し、symlink は実体側へ任せる（母集団の導出は dialect-fallback と同じ）。
# テストも含む。リポジトリ直下の scripts/ は配布外なので走査しない（ADR-084 の文言で縛る）。
# パスは plugin 相対で扱う。plugin の外（同じ plugins/ 配下の別 plugin）の命中は基線に載せられず常に赤。
#
# ── 針（規則表） ────────────────────────────────────────────────────────────
#   OSTYPE         $OSTYPE / ${OSTYPE…} / ${#OSTYPE}
#   MSYSTEM        $MSYSTEM / ${MSYSTEM…}
#   BASH_VERSINFO  語として現れたら数える（算術の中の素の名前を含む）
#   BASH_VERSION   同上
#   uname          (a) uname の後ろに s / m / o / a / p / i を含む短オプション（-s / -m / -o / -a / -p / -i /
#                  -sm …）と GNU 長オプション（--kernel-name / --machine / --operating-system / --all /
#                  --processor / --hardware-platform）。(b) コマンド位置の素の uname（行頭・`$(`・バッククォート・
#                  `;` `|` `&` `{` `(` の直後か if / then / do / else / elif / while / until / ! の後ろで、直後が
#                  `)` バッククォート `|` `;` `&` リダイレクト・行末のもの。`os="$(uname)"` / `uname | grep -q Darwin`）。
#                  道具一覧（PATH 複製用の `for tool in … uname …`）・`command -v uname` の形と -r は数えない
#   coproc         語として現れたら数える（能力の probe `type -t coproc` を含む）
#   件数は命中した出現の数（1 行に 2 つあれば 2）。
#
# ── 当たらない理由の規則（dialect-fallback の R1 / R2 に倣う） ───────────────────
#   R1 コメント: 行頭・空白直後などの `#` 以降は伏せる（`${#x}` は伏せない）
#   R2 引用符の中の文字列: `'…'` と `$'…'` の中身はデータとして伏せる。二重引用符の中は字面だけを伏せ、
#      パラメータ展開（$NAME / ${…}）・コマンド置換（$(…) / バッククォート）は実行されるので残す
#      （dialect-fallback の R2 は二重引用符の中を `$(…)` 以外すべて伏せるが、それでは
#      `case "$OSTYPE" in` が当たらない。ここだけ dialect-fallback と違う）
#   R3 能力層の関数へ素の値を渡すだけの呼び出し: 能力層のファイルが定義する関数（`ff_*()`。名前は
#      能力層のファイルから毎回導く）の第 1 引数に置いた `"${OSTYPE:-}"` / `$OSTYPE` は数えない。分岐は
#      能力層の中にあるため（scripts/lib/wsl-notice.sh は bash が起動時に OSTYPE を上書きするので値を
#      引数で受ける設計）。能力層の外で定義した包み（tests/lib/msys-case.sh の ff_skip_msys_case など）
#      へ渡す形は数える。伏せるのは関数名から展開の閉じまでの核だけで、前後の区切り（`;` `&` `|` `(` `)`
#      空白）は残す（`ff_host_is_msys "$OSTYPE"; uname` の後続の uname を隠さない）
#   ヒアドキュメント本文は除外しない（生成して実行するスクリプトの本文は実コードなので保守側へ倒す）
#
# ── 許可（件数を問わない）と基線（縮小のみ） ─────────────────────────────────
#   許可は ADR-084 決定 3 の能力層 4 ファイル・セキュリティ境界 3 ファイル（knowledge-read-boundary.sh は
#   両方）・この suite 自身。許可パスは基線へ書かない（書くと赤）。
#   基線 baseline.tsv（path<TAB>件数。`#` 行は区分コメント）は MISS_PROBE_BASELINE と同じく縮める方向に
#   しか動かさない。赤は 3 つ: 実在しないパス / 基線より多い（基線に無いパスは基線 0 とみなす）/
#   減ったのに未更新（件数を減らした・0 にしたのに基線を直していない）。
#   `--print-baseline` は今の tree から基線を作り直して stdout へ出す（区分コメントと並びを保ち、
#   件数を今の値へ置き換え、0 件になったパスを落とし、基線に無いパスは末尾の「未区分」節へ足す）。
#   走査が成立しない・plugin の外に命中があるときは何も出さずに非 0 で終わる。縮小のみは取り直しでも
#   強制する: 基線より件数が増えたパス（基線に無い新しいパスを含む）があると、既定では stdout へ何も出さず
#   rc 1 で止め、増えたパスと件数（基線 → 現在）を stderr に名指す。出すのは利用者が明示的に通す宣言
#   `--allow-growth`（ADR-084 の L4 宣言の形。針を足して既存の分岐を数え直した回など）を付けたときだけ。
#   減っただけ・同数の回は従来どおり出す。baseline.tsv を手で書き換えて増やした変更はこの suite では
#   止められない（基線が正本なので緑になる）ため、PR の差分レビューで止める。
#
# ── 既知の限界 ─────────────────────────────────────────────────────────────
#   - 誤検出側: 行をまたぐ引用符文字列の 2 行目以降は引用符の外として読む（基線へ入る側に倒れる）
#   - 誤検出側: 複数行の case のアーム見出し（`uname)` / `uname|arch)`）は行頭の素の uname と区別できず数える
#     （行単位で直前の `in` を見ないため。基線へ入る側に倒れる。2026-11-08 時点の実ツリーには 0 件）
#   - 非検出側: 関数越し・変数越しの分岐（`os=$(get_os)` の get_os の中身は、その定義ファイル側で数える）
#   - 非検出側: 二重引用符の中のバッククォート置換は辿るが、`${…}` の中の入れ子の引用符は辿らない
#   - 非検出側: `bash -c '…'` / `sh -c '…'` / `eval '…'` など単一引用符の中で実行されるコード（R2 で
#     データとして伏せる）
#   - 非検出側: 継続行で分かれたオプション（`uname \` の次行に `-s`）。行単位で読むので 1 行目の素の
#     uname も直後が `\` のため数えない
#
# 変異検出（2026-11-08 実測。各変異を 1 つずつ当てて赤転を確認した）: R2 で二重引用符の中の展開も伏せる
# コピーは G0・P1・P2・P4〜P6・N4b・X1・T1 ほかが赤、R3 を外したコピーは N4・P9・T1・PB2 が赤、R3 の関数名を
# 能力層からの導出でなく任意の ff_* にしたコピーは P8・T1・PB2 が赤、uname のオプション条件を外したコピーは
# N6・T1・PB2 が赤、件数でなく行数を数えるコピーは P4 が赤、基線より少ない側を緑に倒すコピーは B3・B4 が赤、
# 基線のパスの実在を見ないコピーは B2 が赤、plugin の外を走査しないコピーは X1 が赤になる。
# 空振り検出: git リポジトリでない走査根（E1）・tracked 一覧が空（E2）・shell ソース 0 件（E3）・awk が非 0（E4）・読めない tracked shell（E5）・作業ツリーから消えた tracked shell（E6）・許可集合が空（E7）か許可パスの不在（E7b）・基線ファイルの不在（E8）か書式違反（E9）・能力層から関数名を 1 つも導けない（E10）を与えると「違反なし」ではなく検査不成立（rc=2）の赤になり、plugin 配下の走査件数が下限 POPULATION_FLOOR を割るか母集団のアンカーが消えると T2・T3 が赤になる（実測 2026-11-08。macOS 標準 /bin/bash 3.2）。
# 空振り検出: 今の件数が 0 件の木で --print-baseline が古い行を未区分へ戻す回（PB6）・0 バイトの基線で命中の行を基線と取り違える回（B7）・基線より増えたパスがあるのに既定で基線を出す回（PB3）・--print-baseline を伴わない --allow-growth（PB7）を赤にする。変異（2026-11-08 実測。worktree の suite を scratchpad へ写したコピーに 1 つずつ当て、無変異のコピーは pass=53 fail=0）: 整形の awk の判別を FNR == NR へ戻すと PB6、照合の awk を戻すと B7、増加の拒否を外すと PB3、コマンド位置の素の uname の針を外すと P3b、-a / -p / -i と長オプションの針を外すと P3c、モノレポの配置でキーを plugin 相対にしないと X3・X4・T1・PB2 が赤になる。
# 空振り検出: 能力層の呼び出しの前後に接した区切りを R3 が伏せて後続・先行のコマンド位置の素の uname を隠す回（P9b・P9c）と、chmod 000 の後もファイルが読める OS で E5 が検査不成立を作れない回を赤にする（変異 2026-11-08 実測。SCRIPT_DIR だけを worktree の suite へ固定した scratchpad のコピーに 1 つずつ当て、無変異のコピーは pass=56 fail=0）: R3 の伏せ範囲を一致全体（前後の区切りを含む）へ戻すと P9b・P9c が赤、chmod 000 を外して読めるままにし OS 判定へ渡す値を linux-gnu に固定すると E5 が赤（rc=0。期待 2）、同じ入力で msys に固定すると E5 は字下げした部分 skip（`  ○ skip: MSYS では成立しない検査のため未実行（E5 は…）`）になり fail=0。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# 基線（path<TAB>件数）。fixture は別のファイルを引数で渡す（環境からは読まない）
ENV_BRANCH_BASELINE="$SCRIPT_DIR/baseline.tsv"
# plugin 配下で走査されるべき shell ソースの下限（2026-11-08 実測 497 件）。導出が壊れて母集団の
# 大半が落ちる回を赤にする床で、実数より十分低く置く。
POPULATION_FLOOR=300
# ADR-084 決定 3 の能力層（R3 の関数名もここから導く）とセキュリティ境界。plugin 相対
ENV_BRANCH_CAPABILITY=(
  scripts/lib/abs-path.sh
  scripts/lib/wsl-notice.sh
  scripts/lib/knowledge-read-boundary.sh
  tests/lib/release-skip-profile.sh
)
ENV_BRANCH_SECURITY=(
  scripts/lib/knowledge-read-boundary.sh
  scripts/lib/grok-cli-readonly-boundary.sh
  scripts/lib/multi-agent-boundary.sh
)
ENV_BRANCH_ALLOW=(
  "${ENV_BRANCH_CAPABILITY[@]}"
  "${ENV_BRANCH_SECURITY[@]}"
  tests/env-branch-contract/verify.sh
)
ENV_BRANCH_AWK="awk"  # E4 だけが呼び出し単位の前置代入で差し替える（環境からは読まない）

MODE=check
ALLOW_GROWTH=0
for _arg in "$@"; do
  case "$_arg" in
    --print-baseline) MODE=print ;;
    --allow-growth) ALLOW_GROWTH=1 ;;
    *) echo "✗ env-branch-contract: 未知の引数です: ${_arg}（使えるのは --print-baseline と --allow-growth だけ）" >&2; exit 2 ;;
  esac
done
if [ "$ALLOW_GROWTH" -eq 1 ] && [ "$MODE" != print ]; then
  echo "✗ env-branch-contract: --allow-growth は --print-baseline と一緒にだけ使う" >&2
  exit 2
fi

# fixture の git init / add が export 済みの GIT_DIR 経由で呼び出し元リポジトリへ届かないようにする
# shellcheck source=../lib/git-fixture.sh
. "$SCRIPT_DIR/../lib/git-fixture.sh"
# Windows の Git Bash では chmod 000 の後もファイルが読める。そのときだけ E5 を字下げした部分 skip にする
# （tests/lib/msys-case.sh。ACE-2542-2: 能力の probe が否 かつ OS 判定が MSYS / Cygwin のときに限る。
# Linux / macOS では読めても skip せず E5 を実行して赤として出す）。公開 checkout に無ければ source しない
if [ -f "$SCRIPT_DIR/../lib/msys-case.sh" ]; then
  # shellcheck source=../lib/msys-case.sh
  . "$SCRIPT_DIR/../lib/msys-case.sh"
  ff_msys_case_selftest || exit 1
fi
ebc_skip_msys() { # <detail>
  declare -F ff_skip_msys_case >/dev/null 2>&1 && ff_skip_msys_case "${OSTYPE:-}" "$1"
}

PASS=0
FAIL=0
ok()  { echo "  ✓ $1"; PASS=$((PASS + 1)); }
bad() { echo "  ✗ $1" >&2; FAIL=$((FAIL + 1)); }

if _ff_mktemp_out="$(mktemp -d "${TMPDIR:-/tmp}/ff-env-branch.XXXXXX" 2>&1)" && [ -d "$_ff_mktemp_out" ]; then
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
    echo "✗ env-branch-contract: 最後まで到達しませんでした（途中で中断）" >&2
    exit 1
  fi
  exit "$rc"
}
trap cleanup EXIT

# ── 走査器（awk。1 回の呼び出しで全ファイルを読む） ──────────────────────────────
# 出力: <plugin 相対キー><TAB><行番号><TAB><針><TAB><行>。キーは plugin の外なら ../<名前>/… になる。
# -v top=<toplevel>/ prefix=<plugin の show-prefix> sprefix=<走査の接頭辞> caps=<R3 の関数名の選択肢>
cat > "$TMP/scan.awk" <<'AWK'
function us(k,   o) { o = ""; while (k-- > 0) o = o "~"; return o }
# s の位置 i の "$(" に対応する ")" の位置（閉じが無ければ末尾）
function find_close(s, i,   n, j, c, q, d) {
  n = length(s); q = ""; d = 0
  for (j = i + 1; j <= n; j++) {
    c = substr(s, j, 1)
    if (q == "\x27") { if (c == "\x27") q = ""; continue }
    if (c == "\\") { j++; continue }
    if (q == "\"") {
      if (c == "\"") { q = ""; continue }
      if (c == "$" && substr(s, j + 1, 1) == "(") { j = find_close(s, j); continue }
      continue
    }
    if (c == "\x27" || c == "\"") { q = c; continue }
    if (c == "(") { d++; continue }
    if (c == ")") { d--; if (d == 0) return j }
  }
  return n
}
# 入出力の長さを 1:1 に保つ伏せ字。R1（コメント）と R2（引用符の中の字面）を伏せる。伏せ字は `~`
# （識別子に使えない字。`_` だと `"$OSTYPE"` の閉じ引用符が名前の続きに見えて針が外れる）
function mask(s,   n, i, c, prev, out, q, e, closed) {
  n = length(s); out = ""; q = ""
  for (i = 1; i <= n; i++) {
    c = substr(s, i, 1)
    prev = (i > 1) ? substr(s, i - 1, 1) : ""
    if (q == "\x27") { out = out "~"; if (c == "\x27") q = ""; continue }
    if (q == "A") {
      if (c == "\\" && i < n) { out = out "~~"; i++; continue }
      out = out "~"; if (c == "\x27") q = ""; continue
    }
    if (c == "$" && substr(s, i + 1, 1) == "(") {
      e = find_close(s, i)
      closed = (e > i + 1 && substr(s, e, 1) == ")")
      out = out "$(" mask(substr(s, i + 2, e - i - 1 - closed)) (closed ? ")" : "")
      i = e
      continue
    }
    if (c == "`") {
      e = index(substr(s, i + 1), "`")
      if (e == 0) { out = out "`" mask(substr(s, i + 1)); break }
      out = out "`" mask(substr(s, i + 1, e - 1)) "`"
      i = i + e
      continue
    }
    if (q == "\"") {
      if (c == "\\" && i < n) { out = out "~~"; i++; continue }
      if (c == "\"") { q = ""; out = out "~"; continue }
      if (c == "$" && substr(s, i + 1, 1) == "{") {
        e = index(substr(s, i), "}")
        if (e == 0) e = n - i + 1
        out = out substr(s, i, e); i = i + e - 1; continue
      }
      if (c == "$" && match(substr(s, i + 1), /^[A-Za-z_][A-Za-z0-9_]*/)) {
        out = out substr(s, i, RLENGTH + 1); i = i + RLENGTH; continue
      }
      out = out ((c == "$") ? "$" : "~"); continue
    }
    if (c == "\\" && i < n) { out = out "~~"; i++; continue }
    if (c == "$" && substr(s, i + 1, 1) == "\x27") { q = "A"; out = out "~~"; i++; continue }
    if (c == "\x27" || c == "\"") { q = c; out = out "~"; continue }
    if (c == "#" && (i == 1 || prev ~ /[[:space:];&|(]/)) { out = out us(n - i + 1); break }
    out = out c
  }
  return out
}
function hits(m, re, tag,   rest, adv) {
  rest = m
  while (match(rest, re)) {
    printf "%s\t%d\t%s\t%s\n", key, FNR, tag, raw
    adv = RSTART + RLENGTH - 1
    if (adv < 1) adv = 1
    rest = substr(rest, adv + 1)
  }
}
FNR == 1 {
  rel = substr(FILENAME, length(top) + 1)
  if (index(rel, prefix) == 1) key = substr(rel, length(prefix) + 1)
  else key = "../" substr(rel, length(sprefix) + 1)
}
{
  raw = $0
  sub(/\r$/, "", raw)
  # 規則表のどの語も含まない行は判定しない（走査時間の節約。判定は変えない）
  if (raw !~ /(OSTYPE|MSYSTEM|BASH_VERSINFO|BASH_VERSION|uname|coproc)/) next
  m = mask(raw)
  # R3: 能力層の関数の第 1 引数に置いた素の OSTYPE は伏せる。伏せるのは関数名から展開の閉じ（`}` /
  # 閉じ引用符の `~`）までの核だけで、一致の先頭の区切り 1 文字と末尾の区切り 1 文字は残す（awk に先読みが
  # 無いので一致に含めて照合し、潰す範囲から外す。残さないと `; uname` の `;` が消えて後続の針が外れる）
  if (caps != "") {
    r3 = "(^|[^A-Za-z0-9_])(" caps ")[[:space:]]+~?[$][{]?OSTYPE(:-[A-Za-z0-9_]*)?[}]?~?([[:space:];&|)]|$)"
    while (match(m, r3)) {
      r3s = RSTART; r3n = RLENGTH
      if (substr(m, r3s, 1) !~ /[A-Za-z0-9_]/) { r3s++; r3n-- }
      if (substr(m, r3s + r3n - 1, 1) ~ /[[:space:];&|)]/) r3n--
      m = substr(m, 1, r3s - 1) us(r3n) substr(m, r3s + r3n)
    }
  }
  hits(m, "[$][{]?[#!]?OSTYPE([^A-Za-z0-9_]|$)", "OSTYPE")
  hits(m, "[$][{]?[#!]?MSYSTEM([^A-Za-z0-9_]|$)", "MSYSTEM")
  hits(m, "(^|[^A-Za-z0-9_])BASH_VERSINFO([^A-Za-z0-9_]|$)", "BASH_VERSINFO")
  hits(m, "(^|[^A-Za-z0-9_])BASH_VERSION([^A-Za-z0-9_]|$)", "BASH_VERSION")
  hits(m, "(^|[^A-Za-z0-9_$.-])uname[[:space:]]+-[A-Za-z]*[smoapi]", "uname")
  hits(m, "(^|[^A-Za-z0-9_$.-])uname[[:space:]]+--(kernel-name|machine|operating-system|all|processor|hardware-platform)([^A-Za-z0-9_-]|$)", "uname")
  # コマンド位置の素の uname（道具一覧 `for tool in … uname …` と `command -v uname` は位置が違うので当たらない）
  hits(m, "((^|[$][(]|`|[;|&{(])[[:space:]]*|(^|[^A-Za-z0-9_])(if|then|do|else|elif|while|until|!)[[:space:]]+)uname[[:space:]]*([)`|;&<>]|[0-9]+>|$)", "uname")
  hits(m, "(^|[^A-Za-z0-9_$.-])coproc([^A-Za-z0-9_.-]|$)", "coproc")
}
AWK

# --print-baseline の整形: 基線の区分コメントと並びを保ち、件数を今の値へ置き換え、0 件のパスを落とし、
# 基線に無いパスは末尾の「未区分」節へ足す。第 1 引数=今の件数（key<TAB>n。sort 済み）第 2 引数=基線。
# 入力の判別は FILENAME で行う（`FNR == NR` は 1 つ目が空だと 2 つ目にも成立し、基線の行を今の件数と取り違える）
cat > "$TMP/render.awk" <<'AWK'
FILENAME == ARGV[1] {
  n = split($0, f, "\t")
  if (n == 2) { cnt[f[1]] = f[2]; order[++no] = f[1] }
  next
}
/^[[:space:]]*$/ || /^#/ { print; next }
{
  split($0, f, "\t")
  if (f[1] in cnt) { print f[1] "\t" cnt[f[1]]; seen[f[1]] = 1 }
}
END {
  head = 0
  for (i = 1; i <= no; i++) {
    if (order[i] in seen) continue
    if (!head) { print ""; print "# ── 未区分（--print-baseline が足した行。区分を決めて上の節へ移す） ──"; head = 1 }
    print order[i] "\t" cnt[order[i]]
  }
}
AWK

# env_branch_check ROOT BASELINE — ROOT（plugin のディレクトリ）を含む git リポジトリの tracked shell を
# 走査し、許可と基線に照らす。stdout 1 行目は機械可読サマリー、続けて SCANNED_FILE=<キー> と
# COUNT<TAB><キー><TAB><件数>（許可パスを除く命中）を出す。違反・走査失敗の詳細は stderr。
# 終了コード: 0=違反なし / 1=違反あり / 2=検査不成立（0 件の主張はしない）
env_branch_check() {
  local root="$1" baseline="$2"
  local top prefix sprefix list_file err_file file first rc scanned=0 errors="" a cap caps="" cf
  local -a files=()
  list_file="$TMP/ls-files.$$.$RANDOM"
  err_file="$TMP/err.$$.$RANDOM"
  if ! top="$(git -C "$root" rev-parse --show-toplevel 2>"$err_file")"; then
    printf 'ENV_BRANCH_RESULT=error_repo SCANNED=0\n'
    sed 's/^/  | /' "$err_file" >&2
    return 2
  fi
  if ! prefix="$(git -C "$root" rev-parse --show-prefix 2>"$err_file")"; then
    printf 'ENV_BRANCH_RESULT=error_repo SCANNED=0\n'
    sed 's/^/  | /' "$err_file" >&2
    return 2
  fi
  # 走査の接頭辞は plugin の親（plugins/ff-dev-toolkit/ → plugins/、ff-dev-toolkit/ や空 → 全体）
  sprefix=""
  case "$prefix" in
    */*/*) sprefix="${prefix%/}"; sprefix="${sprefix%/*}/" ;;
  esac
  if ! git -C "$top" ls-files -z -- ${sprefix:+"$sprefix"} > "$list_file" 2>"$err_file"; then
    printf 'ENV_BRANCH_RESULT=error_list SCANNED=0\n'
    sed 's/^/  | /' "$err_file" >&2
    return 2
  fi
  if [ ! -s "$list_file" ]; then
    printf 'ENV_BRANCH_RESULT=error_list SCANNED=0\n'
    echo "  | tracked 一覧が空 — 0 件の主張はできない" >&2
    return 2
  fi
  : > "$TMP/scanned.$$"
  while IFS= read -r -d '' file; do
    [ -n "$file" ] || continue
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
        # shebang の集合は dialect-fallback / tests/shellcheck/verify.sh と同じ形
        case "$first" in
          '#!'*[/\ ]sh|'#!'*[/\ ]sh' '*|'#!'*[/\ ]bash|'#!'*[/\ ]bash' '*|'#!'*[/\ ]dash|'#!'*[/\ ]dash' '*|'#!'*[/\ ]ksh|'#!'*[/\ ]ksh' '*) ;;
          *) continue ;;
        esac ;;
    esac
    files+=("$top/$file")
    scanned=$((scanned + 1))
    case "$file" in
      "$prefix"*) printf '%s\n' "${file#"$prefix"}" >> "$TMP/scanned.$$" ;;
      *) printf '../%s\n' "${file#"$sprefix"}" >> "$TMP/scanned.$$" ;;
    esac
  done < "$list_file"
  if [ -n "$errors" ]; then
    printf 'ENV_BRANCH_RESULT=error_scan SCANNED=%s\n' "$scanned"
    printf '%s' "$errors" | sed 's/^/  | /' >&2
    return 2
  fi
  if [ "$scanned" -eq 0 ]; then
    printf 'ENV_BRANCH_RESULT=error_empty SCANNED=0\n'
    echo "  | shell ソースが 1 件も無い — 0 件の主張はできない" >&2
    return 2
  fi
  # 許可集合: 空・母集団に無いパスは検査不成立（名前だけ残った免除を残さない）
  if [ "${#ENV_BRANCH_ALLOW[@]}" -eq 0 ]; then
    printf 'ENV_BRANCH_RESULT=error_allow SCANNED=%s\n' "$scanned"
    echo "  | 許可集合が空 — 能力層の宣言が壊れている" >&2
    return 2
  fi
  for a in "${ENV_BRANCH_ALLOW[@]}"; do
    if ! grep -Fxq -- "$a" "$TMP/scanned.$$"; then
      errors="${errors}${a} (許可パスが走査した shell に無い)
"
    fi
  done
  if [ -n "$errors" ]; then
    printf 'ENV_BRANCH_RESULT=error_allow SCANNED=%s\n' "$scanned"
    printf '%s' "$errors" | sed 's/^/  | /' >&2
    return 2
  fi
  # R3 の関数名を能力層のファイルから導く（ACE-1901-5: 宣言から母集団を導き、空振りを赤にする）
  for cap in ${ENV_BRANCH_CAPABILITY[@]+"${ENV_BRANCH_CAPABILITY[@]}"}; do
    cf="$top/$prefix$cap"
    [ -r "$cf" ] || continue
    while IFS= read -r a; do
      [ -n "$a" ] || continue
      caps="${caps:+$caps|}$a"
    done < <(LC_ALL=C sed -n -E 's/^[[:space:]]*(function[[:space:]]+)?(ff_[A-Za-z0-9_]+)[[:space:]]*\(\).*/\2/p' "$cf")
  done
  if [ -z "$caps" ]; then
    printf 'ENV_BRANCH_RESULT=error_capability SCANNED=%s\n' "$scanned"
    echo "  | 能力層のファイルから関数名を 1 つも導けない（R3 の母集団が空）" >&2
    return 2
  fi
  # 基線: 不在・読めない・書式違反は検査不成立
  if [ ! -f "$baseline" ] || [ ! -r "$baseline" ]; then
    printf 'ENV_BRANCH_RESULT=error_baseline SCANNED=%s\n' "$scanned"
    echo "  | 基線ファイルが無いか読めない: ${baseline}" >&2
    return 2
  fi
  # 許可パスは空白区切りで渡す（BSD awk は -v の値に改行を受けない。パスは空白を含まない）
  if ! LC_ALL=C awk -F'\t' -v allow="${ENV_BRANCH_ALLOW[*]}" '
      BEGIN { n = split(allow, al, " "); for (i = 1; i <= n; i++) if (al[i] != "") A[al[i]] = 1 }
      { sub(/\r$/, "") }
      /^[[:space:]]*$/ || /^#/ { next }
      NF != 2 || $2 !~ /^[1-9][0-9]*$/ { print "  | " FNR ": path<TAB>正の件数 の形でない: " $0; bad = 1; next }
      $1 ~ /^(\/|\.\.\/)/ { print "  | " FNR ": plugin 相対でないパス: " $1; bad = 1; next }
      ($1 in A) { print "  | " FNR ": 許可パスは基線へ書かない: " $1; bad = 1; next }
      ($1 in seen) { print "  | " FNR ": 同じパスが 2 行ある: " $1; bad = 1; next }
      { seen[$1] = 1 }
      END { exit bad }
    ' "$baseline" > "$err_file" 2>&1; then
    printf 'ENV_BRANCH_RESULT=error_baseline SCANNED=%s\n' "$scanned"
    cat "$err_file" >&2
    return 2
  fi
  rc=0
  LC_ALL=C "$ENV_BRANCH_AWK" -v top="$top/" -v prefix="$prefix" -v sprefix="$sprefix" -v caps="$caps" \
    -f "$TMP/scan.awk" "${files[@]}" > "$TMP/hits.$$" 2>"$err_file" || rc=$?
  if [ "$rc" -ne 0 ]; then
    printf 'ENV_BRANCH_RESULT=error_scan SCANNED=%s\n' "$scanned"
    echo "  | 走査器（awk）が rc=${rc} で終わった: $(head -n 1 "$err_file")" >&2
    return 2
  fi
  # 照合（許可パスを除いた命中の件数を基線と比べる）
  rc=0
  LC_ALL=C awk -F'\t' -v allow="${ENV_BRANCH_ALLOW[*]}" \
      -v scanned_file="$TMP/scanned.$$" -v counts_file="$TMP/counts.$$" -v viol_file="$TMP/viol.$$" '
    BEGIN {
      n = split(allow, al, " "); for (i = 1; i <= n; i++) if (al[i] != "") A[al[i]] = 1
      while ((getline l < scanned_file) > 0) S[l] = 1
      printf "" > counts_file; printf "" > viol_file
    }
    # 1 つ目（基線）の判別は FILENAME で行う（空の基線で `FNR == NR` が命中の行にも成立しないように）
    FILENAME == ARGV[1] {
      sub(/\r$/, "")
      if ($0 ~ /^[[:space:]]*$/ || $0 ~ /^#/) next
      B[$1] = $2; next
    }
    {
      if ($1 in A) next
      C[$1]++
      L[$1] = L[$1] "      " $2 ": [" $3 "] " $4 "\n"
    }
    END {
      for (k in C) {
        print k "\t" C[k] > counts_file
        if (substr(k, 1, 3) == "../") { printf "  | %s: plugin の外の環境分岐 %d 件（基線に載せられない。能力層の関数を使う）\n%s", k, C[k], L[k] > viol_file; bad = 1; continue }
        b = (k in B) ? B[k] : 0
        if (C[k] > b) { printf "  | %s: 基線より多い（基線 %d → 現在 %d）\n%s", k, b, C[k], L[k] > viol_file; bad = 1 }
        else if (C[k] < b) { printf "  | %s: 減ったのに未更新（基線 %d → 現在 %d。--print-baseline で取り直す）\n", k, b, C[k] > viol_file; bad = 1 }
      }
      for (k in B) {
        if (k in C) continue
        if (!(k in S)) { printf "  | %s: 基線に実在しないパス（基線 %d。tracked shell に無い）\n", k, B[k] > viol_file; bad = 1 }
        else { printf "  | %s: 減ったのに未更新（基線 %d → 現在 0。--print-baseline で取り直す）\n", k, B[k] > viol_file; bad = 1 }
      }
      exit bad
    }
  ' "$baseline" "$TMP/hits.$$" || rc=$?
  if [ "$rc" -gt 1 ]; then
    printf 'ENV_BRANCH_RESULT=error_scan SCANNED=%s\n' "$scanned"
    echo "  | 照合（awk）が rc=${rc} で終わった" >&2
    return 2
  fi
  if [ "$rc" -eq 1 ]; then
    printf 'ENV_BRANCH_RESULT=hits SCANNED=%s\n' "$scanned"
  else
    printf 'ENV_BRANCH_RESULT=ok SCANNED=%s\n' "$scanned"
  fi
  sed 's/^/SCANNED_FILE=/' "$TMP/scanned.$$"
  LC_ALL=C sort "$TMP/counts.$$" | sed 's/^/COUNT	/'
  [ "$rc" -eq 0 ] || cat "$TMP/viol.$$" >&2
  return "$rc"
}

# env_branch_render BASELINE CHECK_OUT — env_branch_check の stdout（CHECK_OUT のファイル）から基線を作り直す
env_branch_render() {
  sed -n 's/^COUNT	//p' "$2" | LC_ALL=C sort > "$TMP/render-counts.$$"
  LC_ALL=C awk -f "$TMP/render.awk" "$TMP/render-counts.$$" "$1"
}

# env_branch_print ROOT BASELINE ALLOW_GROWTH — --print-baseline の本体。走査が成立しない（rc 2）・plugin の外に
# 命中がある（rc 1）・基線より増えたパスがあり ALLOW_GROWTH が 1 でない（rc 1）ときは stdout へ何も出さない
env_branch_print() {
  local root="$1" baseline="$2" allow="$3" p_rc=0 base
  base="$TMP/print.$$.$RANDOM"
  env_branch_check "$root" "$baseline" > "$base.out" 2>"$base.err" || p_rc=$?
  if [ "$p_rc" -eq 2 ]; then
    echo "✗ env-branch-contract --print-baseline: 走査が成立しないので基線を出しません（$(head -n 1 "$base.out")）" >&2
    cat "$base.err" >&2
    return 2
  fi
  if grep -q '^COUNT	\.\./' "$base.out"; then
    echo "✗ env-branch-contract --print-baseline: plugin の外に環境分岐があり、基線に載せられません" >&2
    grep '^COUNT	\.\./' "$base.out" | sed 's/^COUNT	/  | /' >&2
    return 1
  fi
  # 増えたパス（基線に無い新しいパスは基線 0 とみなす。照合の「基線より多い」行と同じ集合）
  if LC_ALL=C grep -Fq ': 基線より多い（基線 ' "$base.err" && [ "$allow" != 1 ]; then
    echo "✗ env-branch-contract --print-baseline: 基線より件数が増えたパスがあるので基線を出しません（基線は縮める方向にしか動かさない）" >&2
    LC_ALL=C grep -F ': 基線より多い（基線 ' "$base.err" >&2
    echo "  止めた層: ガード" >&2
    echo "  止めた規則: env-branch-contract の基線は縮小のみ（ADR-084 決定 3。新しい分岐は能力層へ）" >&2
    echo "  次の一手: 新しい分岐なら能力層の関数へ寄せる。針を足して既存の分岐を数え直しただけなら --print-baseline --allow-growth で明示して出し、増えたパスを区分コメントの下へ移す" >&2
    return 1
  fi
  env_branch_render "$baseline" "$base.out"
}

if [ "$MODE" = print ]; then
  p_rc=0
  env_branch_print "$PLUGIN_ROOT" "$ENV_BRANCH_BASELINE" "$ALLOW_GROWTH" || p_rc=$?
  REACHED_END=1
  exit "$p_rc"
fi

# ── fixture（隔離 git リポジトリ。本文は printf で書く — 本ファイル自身が針を持たないように） ─────
# 許可パスと能力層の関数を持つ最小の plugin 木。hooks/base.sh が基線に載る 2 件を持つ。
fx_tree() { # $1=ディレクトリ
  local d="$1" a
  for a in "${ENV_BRANCH_ALLOW[@]}"; do
    mkdir -p "$d/$(dirname "$a")"
    printf '#!/usr/bin/env bash\ntrue\n' > "$d/$a"
  done
  printf '%s\n' 'ff_host_is_msys() {' '  case "${1:-}" in msys* | cygwin*) return 0 ;; esac' '  return 1' '}' \
    > "$d/scripts/lib/wsl-notice.sh"
  mkdir -p "$d/hooks"
  printf '%s\n' '#!/usr/bin/env bash' 'case "${OSTYPE:-}" in msys*) : ;; esac' '[ "${BASH_VERSINFO[0]}" -ge 4 ] || :' \
    > "$d/hooks/base.sh"
}
fx_commit() { # $1=ディレクトリ
  ff_git_fixture_init "$1" >/dev/null
  git -C "$1" add -A
}
fx_baseline() { # $1=ファイル $2...=行
  local f="$1"; shift
  printf '%s\n' "$@" > "$f"
}
# expect_check ID ROOT BASELINE 期待rc 期待の語（stdout / stderr のどちらかに含む） 説明
expect_check() {
  local id="$1" root="$2" baseline="$3" want="$4" needle="$5" desc="$6" rc=0 out err
  out="$(env_branch_check "$root" "$baseline" 2>"$TMP/expect.err")" || rc=$?
  err="$(cat "$TMP/expect.err")"
  if [ "$rc" -ne "$want" ]; then
    bad "${id}: ${desc} — rc=${rc}（期待 ${want}） [${out%%$'\n'*}] ${err}"
  elif [[ "$out"$'\n'"$err" != *"$needle"* ]]; then
    bad "${id}: ${desc} — 期待の語 [${needle}] が出ない（[${out%%$'\n'*}] ${err}）"
  else
    ok "${id}: ${desc}"
  fi
}
TAB="$(printf '\t')"
BASE_OK="$TMP/base-ok.tsv"
fx_baseline "$BASE_OK" '# 区分 A' "hooks/base.sh${TAB}2"
NEW_LINE='case "$OSTYPE" in msys*) ;; esac'

echo "== 正常対照と陽性 / 陰性 fixture =="
fx_tree "$TMP/g0"; fx_commit "$TMP/g0"
expect_check G0 "$TMP/g0" "$BASE_OK" 0 'ENV_BRANCH_RESULT=ok' '基線どおりの tree は緑'

mk() { # $1=名前 $2=追記先（plugin 相対） $3...=追記する行
  local d="$TMP/$1" f="$2"; shift 2
  fx_tree "$d"
  mkdir -p "$d/$(dirname "$f")"
  [ -f "$d/$f" ] || printf '#!/usr/bin/env bash\n' > "$d/$f"
  printf '%s\n' "$@" >> "$d/$f"
  fx_commit "$d"
}
mk p1 hooks/new-guard.sh "$NEW_LINE"
expect_check P1 "$TMP/p1" "$BASE_OK" 1 'hooks/new-guard.sh: 基線より多い（基線 0 → 現在 1）' '許可外の hook に case "$OSTYPE" を 1 行足すと、パスと件数を名指して赤'
mk p2 hooks/base.sh "$NEW_LINE"
expect_check P2 "$TMP/p2" "$BASE_OK" 1 'hooks/base.sh: 基線より多い（基線 2 → 現在 3）' '基線に載るパスへ 1 行足すと赤'
mk p3 hooks/x.sh 'os="$(uname -s)"' 'arch=`uname -m`' 'k=$(uname -sm)'
expect_check P3 "$TMP/p3" "$BASE_OK" 1 'hooks/x.sh: 基線より多い（基線 0 → 現在 3）' 'uname -s / -m / -sm（コマンド置換・バッククォートの中を含む）を数える'
mk p3b hooks/x.sh 'os="$(uname)"' 'case "$(uname)" in Darwin*) : ;; esac' 'k=`uname`' 'uname | grep Darwin >/dev/null || :' \
  'if uname >/dev/null; then :; fi' 'v=$(uname 2>/dev/null)'
expect_check P3b "$TMP/p3b" "$BASE_OK" 1 'hooks/x.sh: 基線より多い（基線 0 → 現在 6）' 'コマンド位置の素の uname（$( )・バッククォート・パイプ・if・リダイレクトの前）を数える'
mk p3c hooks/x.sh 'a=$(uname -a)' 'p=$(uname -p)' 'i=$(uname -i)' 'uname --kernel-name' 'uname --machine >/dev/null' \
  'o=$(uname --operating-system)' 'uname --all' 'uname --processor' 'h=`uname --hardware-platform`'
expect_check P3c "$TMP/p3c" "$BASE_OK" 1 'hooks/x.sh: 基線より多い（基線 0 → 現在 9）' 'uname -a / -p / -i と GNU 長オプション 6 種をそれぞれ 1 件と数える'
mk p4 hooks/x.sh '[ "${BASH_VERSINFO[0]}" -ge 4 ] && [ "${BASH_VERSINFO[1]}" -ge 2 ]'
expect_check P4 "$TMP/p4" "$BASE_OK" 1 'hooks/x.sh: 基線より多い（基線 0 → 現在 2）' '1 行に 2 つの BASH_VERSINFO は 2 件'
mk p5 hooks/x.sh 'echo "${BASH_VERSION}"' '(( BASH_VERSINFO[0] >= 4 )) || :'
expect_check P5 "$TMP/p5" "$BASE_OK" 1 'hooks/x.sh: 基線より多い（基線 0 → 現在 2）' 'BASH_VERSION と算術の中の素の BASH_VERSINFO を数える'
mk p6 hooks/x.sh 'case "${MSYSTEM:-}" in MINGW*) : ;; esac' '[[ $OSTYPE == msys* ]] || :'
expect_check P6 "$TMP/p6" "$BASE_OK" 1 'hooks/x.sh: 基線より多い（基線 0 → 現在 2）' 'MSYSTEM と引用無しの OSTYPE を数える'
mk p7 hooks/x.sh 'coproc helper { cat; }' 'case "$(type -t coproc)" in keyword) : ;; esac'
expect_check P7 "$TMP/p7" "$BASE_OK" 1 'hooks/x.sh: 基線より多い（基線 0 → 現在 2）' 'coproc の使用と能力 probe を数える'
mk p8 hooks/x.sh 'ff_my_wrapper "${OSTYPE:-}" || :' 'my_wrapper "$OSTYPE" || :'
expect_check P8 "$TMP/p8" "$BASE_OK" 1 'hooks/x.sh: 基線より多い（基線 0 → 現在 2）' '能力層が定義しない関数（ff_* を含む）へ渡す OSTYPE は数える'
mk p9 hooks/x.sh 'ff_host_is_msys "${OSTYPE:-}" && case $OSTYPE in msys*) : ;; esac'
expect_check P9 "$TMP/p9" "$BASE_OK" 1 'hooks/x.sh: 基線より多い（基線 0 → 現在 1）' '能力層の呼び出しと同じ行の case 分岐は数える'
# P9b / P9c: R3 が伏せるのは関数名から展開の閉じまでの核だけで、前後の区切り（`;` など）は残す
# （P9b の uname の後ろはリダイレクトにする。パイプで grep -q へ流す形は run-all の再混入ガードが止める）
mk p9b hooks/new-guard.sh 'ff_host_is_msys "${OSTYPE:-}"; uname >/dev/null'
expect_check P9b "$TMP/p9b" "$BASE_OK" 1 'hooks/new-guard.sh: 基線より多い（基線 0 → 現在 1）' '能力層の呼び出しの後ろの `;` に続くコマンド位置の素の uname は数える'
mk p9c hooks/new-guard.sh 'uname;ff_host_is_msys "$OSTYPE"'
expect_check P9c "$TMP/p9c" "$BASE_OK" 1 'hooks/new-guard.sh: 基線より多い（基線 0 → 現在 1）' '能力層の呼び出しの前の `;` で終わるコマンド位置の素の uname は数える'

mk n1 scripts/lib/wsl-notice.sh "$NEW_LINE"
expect_check N1 "$TMP/n1" "$BASE_OK" 0 'ENV_BRANCH_RESULT=ok' '能力層（scripts/lib/wsl-notice.sh）に足した同じ 1 行は緑'
mk n2 hooks/x.sh "# ${NEW_LINE}" "x=1 # ${NEW_LINE}"
expect_check N2 "$TMP/n2" "$BASE_OK" 0 'ENV_BRANCH_RESULT=ok' 'コメントの中（行頭・行末）は緑（R1）'
mk n3 hooks/x.sh "echo '${NEW_LINE}'" "printf '%s' \$'uname -s \\' \$OSTYPE'"
expect_check N3 "$TMP/n3" "$BASE_OK" 0 'ENV_BRANCH_RESULT=ok' '単一引用符と ANSI-C 引用の中の文字列は緑（R2）'
mk n4 hooks/x.sh 'if ff_host_is_msys "${OSTYPE:-}"; then :; fi' 'ff_host_is_msys $OSTYPE || :'
expect_check N4 "$TMP/n4" "$BASE_OK" 0 'ENV_BRANCH_RESULT=ok' '能力層の関数へ素の OSTYPE を渡すだけの呼び出しは緑（R3）'
mk n4c hooks/x.sh 'x=1;ff_host_is_msys "$OSTYPE"; y=2' 'a=1&&ff_host_is_msys "${OSTYPE:-}"||:' '(ff_host_is_msys $OSTYPE)'
expect_check N4c "$TMP/n4c" "$BASE_OK" 0 'ENV_BRANCH_RESULT=ok' '前後に区切り（`;` `&&` `||` 括弧）が接した能力層の呼び出しも緑（R3 の核を狭めても伏せ漏れない）'
mk n5 hooks/x.sh 'echo "uname -s と OSTYPE と BASH_VERSINFO で判定する（説明文）"' 'printf "%s\n" "MSYSTEM"'
expect_check N5 "$TMP/n5" "$BASE_OK" 0 'ENV_BRANCH_RESULT=ok' '二重引用符の中の字面は緑（展開でないもの）'
mk n6 hooks/x.sh 'for tool in awk uname date; do :; done' 'r="$(uname -r)"' 'command -v uname >/dev/null' \
  'for tool in uname; do :; done' 'r=$(uname --kernel-release)'
expect_check N6 "$TMP/n6" "$BASE_OK" 0 'ENV_BRANCH_RESULT=ok' '道具一覧・command -v uname の形と uname -r / --kernel-release は数えない'
mk n7 hooks/x.sh 'X_OSTYPE_HINT=1; my_coproc_flag=1; echo "$ostype"'
expect_check N7 "$TMP/n7" "$BASE_OK" 0 'ENV_BRANCH_RESULT=ok' '別名の一部（X_OSTYPE_HINT / my_coproc_flag）と小文字の ostype 変数は数えない'
mk n4b hooks/x.sh 'echo "os=$OSTYPE ver=${BASH_VERSINFO[0]}"'
expect_check N4b "$TMP/n4b" "$BASE_OK" 1 'hooks/x.sh: 基線より多い（基線 0 → 現在 2）' '二重引用符の中の展開は数える（R2 の例外）'

echo "== 基線の 3 つの赤と書式 =="
fx_baseline "$TMP/b1.tsv" '# 区分 A'
expect_check B1 "$TMP/g0" "$TMP/b1.tsv" 1 'hooks/base.sh: 基線より多い（基線 0 → 現在 2）' '基線の 1 行を削った（実体は残る）tree は「基線より多い」で赤'
fx_baseline "$TMP/b2.tsv" '# 区分 A' "hooks/base.sh${TAB}2" "hooks/gone.sh${TAB}1"
expect_check B2 "$TMP/g0" "$TMP/b2.tsv" 1 'hooks/gone.sh: 基線に実在しないパス' '基線に実在しないパスを足すと赤'
fx_baseline "$TMP/b3.tsv" '# 区分 A' "hooks/base.sh${TAB}3"
expect_check B3 "$TMP/g0" "$TMP/b3.tsv" 1 'hooks/base.sh: 減ったのに未更新（基線 3 → 現在 2' '実体を減らしたのに基線を更新しないと赤'
mk b4 hooks/other.sh 'true'
fx_baseline "$TMP/b4.tsv" '# 区分 A' "hooks/base.sh${TAB}2" "hooks/other.sh${TAB}1"
expect_check B4 "$TMP/b4" "$TMP/b4.tsv" 1 'hooks/other.sh: 減ったのに未更新（基線 1 → 現在 0' '実体を 0 件にしたのに基線に残すと赤'
fx_baseline "$TMP/b5.tsv" "hooks/base.sh${TAB}2" "scripts/lib/wsl-notice.sh${TAB}1"
expect_check B5 "$TMP/g0" "$TMP/b5.tsv" 2 '許可パスは基線へ書かない' '許可パスを基線に書くと検査不成立'
fx_baseline "$TMP/b6.tsv" "hooks/base.sh${TAB}2" "hooks/base.sh${TAB}2"
expect_check B6 "$TMP/g0" "$TMP/b6.tsv" 2 '同じパスが 2 行ある' '同じパスの 2 行は検査不成立'
: > "$TMP/b7.tsv"
expect_check B7 "$TMP/g0" "$TMP/b7.tsv" 1 'hooks/base.sh: 基線より多い（基線 0 → 現在 2）' '0 バイトの基線でも命中の行を基線と取り違えず「基線より多い」で赤'

echo "== plugin の外（同じ plugins/ 配下の別 plugin・リポジトリ直下 scripts/） =="
ff_git_fixture_init "$TMP/x1" >/dev/null
fx_tree "$TMP/x1/plugins/ff-dev-toolkit"
mkdir -p "$TMP/x1/plugins/other/hooks" "$TMP/x1/scripts"
printf '%s\n' '#!/usr/bin/env bash' "$NEW_LINE" > "$TMP/x1/plugins/other/hooks/a.sh"
printf '%s\n' '#!/usr/bin/env bash' "$NEW_LINE" > "$TMP/x1/scripts/root-only.sh"
git -C "$TMP/x1" add -A
expect_check X1 "$TMP/x1/plugins/ff-dev-toolkit" "$BASE_OK" 1 '../other/hooks/a.sh: plugin の外の環境分岐 1 件' '別 plugin の環境分岐は基線に載せられず赤'
x1_err="$(env_branch_check "$TMP/x1/plugins/ff-dev-toolkit" "$BASE_OK" 2>&1 >/dev/null || true)"
if [[ "$x1_err" != *root-only.sh* ]]; then
  ok "X2: リポジトリ直下の scripts/（配布外）は走査しない"
else
  bad "X2: リポジトリ直下の scripts/ を走査した（[${x1_err}]）"
fi
rm -f "$TMP/x1/plugins/other/hooks/a.sh"; git -C "$TMP/x1" add -A
expect_check X3 "$TMP/x1/plugins/ff-dev-toolkit" "$BASE_OK" 0 'SCANNED_FILE=hooks/base.sh' 'モノレポの配置でもキーは plugin 相対'
printf '%s\n' '#!/usr/bin/env bash' "$NEW_LINE" > "$TMP/x1/plugins/ff-dev-toolkit/hooks/new-guard.sh"; git -C "$TMP/x1" add -A
expect_check X4 "$TMP/x1/plugins/ff-dev-toolkit" "$BASE_OK" 1 '| hooks/new-guard.sh: 基線より多い（基線 0 → 現在 1）' 'モノレポの配置でも許可外の hook に足した case "$OSTYPE" を plugin 相対のパスで名指して赤'

echo "== 検査不成立の既定（空振り） =="
mkdir -p "$TMP/e1"
e1_rc=0
e1_out="$(GIT_CEILING_DIRECTORIES="$TMP" env_branch_check "$TMP/e1" "$BASE_OK" 2>/dev/null)" || e1_rc=$?
if [ "$e1_rc" -eq 2 ] && [[ "$e1_out" == "ENV_BRANCH_RESULT=error_repo "* ]]; then
  ok "E1: git リポジトリでない走査根は検査不成立（error_repo）"
else
  bad "E1: git でない走査根が検査不成立にならない（rc=${e1_rc} / [${e1_out%%$'\n'*}]）"
fi
ff_git_fixture_init "$TMP/e2" >/dev/null
expect_check E2 "$TMP/e2" "$BASE_OK" 2 'ENV_BRANCH_RESULT=error_list' 'tracked 一覧が空の repo は検査不成立'
ff_git_fixture_init "$TMP/e3" >/dev/null
printf 'x\n' > "$TMP/e3/README.md"; git -C "$TMP/e3" add README.md
expect_check E3 "$TMP/e3" "$BASE_OK" 2 'ENV_BRANCH_RESULT=error_empty' 'shell ソースを 1 件も持たない repo は検査不成立'
e4_rc=0
e4_out="$(ENV_BRANCH_AWK=false env_branch_check "$TMP/g0" "$BASE_OK" 2>/dev/null)" || e4_rc=$?
if [ "$e4_rc" -eq 2 ] && [[ "$e4_out" == "ENV_BRANCH_RESULT=error_scan "* ]]; then
  ok "E4: 走査器（awk）の非 0 は検査不成立（error_scan）"
else
  bad "E4: 走査器の失敗が検査不成立にならない（rc=${e4_rc} / [${e4_out%%$'\n'*}]）"
fi
if [ "$(id -u)" -eq 0 ]; then
  echo "  ○ skip: E5 root では読み取り権限を落とせないため未検査（読めない tracked shell）"
else
  fx_tree "$TMP/e5"; fx_commit "$TMP/e5"
  chmod 000 "$TMP/e5/hooks/base.sh"
  if [ -r "$TMP/e5/hooks/base.sh" ] && ebc_skip_msys "E5 は chmod 000 でも tracked shell が読めて成立しない"; then
    chmod 644 "$TMP/e5/hooks/base.sh"
  else
    expect_check E5 "$TMP/e5" "$BASE_OK" 2 'hooks/base.sh (unreadable)' '読めない tracked shell はファイル名付きで検査不成立'
    chmod 644 "$TMP/e5/hooks/base.sh"
  fi
fi
fx_tree "$TMP/e6"; printf 'true\n' > "$TMP/e6/hooks/gone.sh"; fx_commit "$TMP/e6"; rm -f "$TMP/e6/hooks/gone.sh"
expect_check E6 "$TMP/e6" "$BASE_OK" 2 'hooks/gone.sh (tracked だが作業ツリーに無い)' '作業ツリーから消えた tracked shell は検査不成立'
e7_rc=0
e7_out="$( ENV_BRANCH_ALLOW=(); env_branch_check "$TMP/g0" "$BASE_OK" 2>/dev/null )" || e7_rc=$?
if [ "$e7_rc" -eq 2 ] && [[ "$e7_out" == "ENV_BRANCH_RESULT=error_allow "* ]]; then
  ok "E7: 許可集合が空なら検査不成立（error_allow）"
else
  bad "E7: 許可集合が空でも検査不成立にならない（rc=${e7_rc} / [${e7_out%%$'\n'*}]）"
fi
fx_tree "$TMP/e7b"; rm -f "$TMP/e7b/scripts/lib/abs-path.sh"; fx_commit "$TMP/e7b"
expect_check E7b "$TMP/e7b" "$BASE_OK" 2 'scripts/lib/abs-path.sh (許可パスが走査した shell に無い)' '許可パスが tree に無いと検査不成立'
expect_check E8 "$TMP/g0" "$TMP/no-such-baseline.tsv" 2 'ENV_BRANCH_RESULT=error_baseline' '基線ファイルが無いと検査不成立'
fx_baseline "$TMP/e9.tsv" 'hooks/base.sh 2'
expect_check E9 "$TMP/g0" "$TMP/e9.tsv" 2 'path<TAB>正の件数 の形でない' '基線の書式違反（タブでなく空白）は検査不成立'
fx_tree "$TMP/e10"; printf '#!/usr/bin/env bash\ntrue\n' > "$TMP/e10/scripts/lib/wsl-notice.sh"; fx_commit "$TMP/e10"
expect_check E10 "$TMP/e10" "$BASE_OK" 2 'ENV_BRANCH_RESULT=error_capability' '能力層から関数名を 1 つも導けないと検査不成立'

echo "== --print-baseline の整形 =="
mk pb1 hooks/base.sh "$NEW_LINE"
printf '#!/usr/bin/env bash\n%s\n' "$NEW_LINE" > "$TMP/pb1/hooks/zz-new.sh"
printf '#!/usr/bin/env bash\ntrue\n' > "$TMP/pb1/hooks/dropped.sh"
git -C "$TMP/pb1" add -A
fx_baseline "$TMP/pb1.tsv" '# ── 区分 A ──' "hooks/base.sh${TAB}2" '' '# ── 区分 B ──' "hooks/dropped.sh${TAB}1"
pb_rc=0
env_branch_check "$TMP/pb1" "$TMP/pb1.tsv" > "$TMP/pb1.out" 2>/dev/null || pb_rc=$?
pb_got="$(env_branch_render "$TMP/pb1.tsv" "$TMP/pb1.out")"
pb_want="$(printf '%s\n' '# ── 区分 A ──' "hooks/base.sh${TAB}3" '' '# ── 区分 B ──' '' \
  '# ── 未区分（--print-baseline が足した行。区分を決めて上の節へ移す） ──' "hooks/zz-new.sh${TAB}1")"
if [ "$pb_rc" -eq 1 ] && [ "$pb_got" = "$pb_want" ]; then
  ok "PB1: 区分コメントを保ち、件数を今の値へ置き換え、0 件のパスを落とし、新しいパスを未区分へ足す"
else
  bad "PB1: --print-baseline の整形が期待と違う（rc=${pb_rc}）"
  printf '%s\n' "--- got" "$pb_got" "--- want" "$pb_want" | sed 's/^/      /' >&2
fi
# PB3〜PB4: 縮小のみを取り直しでも強制する（増えたパスがあると既定では出さず、--allow-growth のときだけ出す）
pb_rc=0
pb_got="$(env_branch_print "$TMP/pb1" "$TMP/pb1.tsv" 0 2>"$TMP/pb3.err")" || pb_rc=$?
pb_err="$(cat "$TMP/pb3.err")"
if [ "$pb_rc" -eq 1 ] && [ -z "$pb_got" ] \
  && [[ "$pb_err" == *'| hooks/base.sh: 基線より多い（基線 2 → 現在 3）'* ]] \
  && [[ "$pb_err" == *'| hooks/zz-new.sh: 基線より多い（基線 0 → 現在 1）'* ]]; then
  ok "PB3: 基線より増えたパス（新しいパスを含む）があると既定では stdout に何も出さず rc 1 で、パスと件数を名指す"
else
  bad "PB3: 増加を既定で拒否しない（rc=${pb_rc} / stdout=[${pb_got}] / stderr=[${pb_err}]）"
fi
pb_rc=0
pb_got="$(env_branch_print "$TMP/pb1" "$TMP/pb1.tsv" 1 2>/dev/null)" || pb_rc=$?
if [ "$pb_rc" -eq 0 ] && [ "$pb_got" = "$pb_want" ]; then
  ok "PB4: --allow-growth を付けたときだけ増えた件数で基線を出す"
else
  bad "PB4: --allow-growth で基線を出さない（rc=${pb_rc}）"
  printf '%s\n' "--- got" "$pb_got" "--- want" "$pb_want" | sed 's/^/      /' >&2
fi
# PB5: 減っただけの回は宣言なしで出す
fx_tree "$TMP/pb5"
printf '%s\n' '#!/usr/bin/env bash' 'case "${OSTYPE:-}" in msys*) : ;; esac' > "$TMP/pb5/hooks/base.sh"
fx_commit "$TMP/pb5"
pb_rc=0
pb_got="$(env_branch_print "$TMP/pb5" "$BASE_OK" 0 2>/dev/null)" || pb_rc=$?
pb_want="$(printf '%s\n' '# 区分 A' "hooks/base.sh${TAB}1")"
if [ "$pb_rc" -eq 0 ] && [ "$pb_got" = "$pb_want" ]; then
  ok "PB5: 件数が減っただけの回は --allow-growth なしで基線を出す"
else
  bad "PB5: 減少の回に基線を出さない・整形が違う（rc=${pb_rc} / got=[${pb_got}]）"
fi
# PB6: 今の件数が 0 件（全分岐を能力層へ移した木）でも、古い行を「未区分」へ再出力しない
fx_tree "$TMP/pb6"
printf '%s\n' '#!/usr/bin/env bash' 'true' > "$TMP/pb6/hooks/base.sh"
fx_commit "$TMP/pb6"
fx_baseline "$TMP/pb6.tsv" '# ── 区分 A ──' "hooks/base.sh${TAB}2" '' '# ── 区分 B ──'
pb_rc=0
pb_got="$(env_branch_print "$TMP/pb6" "$TMP/pb6.tsv" 0 2>/dev/null)" || pb_rc=$?
pb_want="$(printf '%s\n' '# ── 区分 A ──' '' '# ── 区分 B ──')"
if [ "$pb_rc" -eq 0 ] && [ "$pb_got" = "$pb_want" ]; then
  ok "PB6: 今の件数が 0 件の木では区分コメントだけを出し、古い行を未区分へ戻さない"
else
  bad "PB6: 0 件の木で基線の整形が違う（rc=${pb_rc}）"
  printf '%s\n' "--- got" "$pb_got" "--- want" "$pb_want" | sed 's/^/      /' >&2
fi
# PB7: --allow-growth は --print-baseline と一緒にだけ受ける
pb_rc=0
"$BASH" "$SCRIPT_DIR/verify.sh" --allow-growth >/dev/null 2>&1 || pb_rc=$?
if [ "$pb_rc" -eq 2 ]; then
  ok "PB7: --print-baseline を伴わない --allow-growth は rc 2 で受けない"
else
  bad "PB7: 単独の --allow-growth が rc 2 にならない（rc=${pb_rc}）"
fi

echo "== 実ツリー（plugin 配下の tracked shell 全体） =="
t_rc=0
env_branch_check "$PLUGIN_ROOT" "$ENV_BRANCH_BASELINE" > "$TMP/tree.out" 2>"$TMP/tree.err" || t_rc=$?
t_summary="$(head -n 1 "$TMP/tree.out")"
if [ "$t_rc" -eq 0 ]; then
  ok "T1: 能力層の外の環境分岐は基線どおり（${t_summary}。基線の全パスが実在し件数が一致）"
elif [ "$t_rc" -eq 1 ]; then
  sed 's/^/  /' "$TMP/tree.err" >&2
  bad "T1: 能力層の外に環境分岐が増えた・基線が古い（${t_summary}。詳細は上の | 行）"
  echo "    直し方: 新しい分岐は能力層（scripts/lib/abs-path.sh / wsl-notice.sh など。ADR-084 決定 3）の関数へ寄せる。減らしたなら基線を取り直す: out=\"\$(bash plugins/ff-dev-toolkit/tests/env-branch-contract/verify.sh --print-baseline)\" && printf '%s\\n' \"\$out\" > plugins/ff-dev-toolkit/tests/env-branch-contract/baseline.tsv" >&2
else
  sed 's/^/  /' "$TMP/tree.err" >&2
  bad "T1: 走査が成立しない（${t_summary}）"
fi
pop_n="$(grep -c '^SCANNED_FILE=[^.]' "$TMP/tree.out" || true)"
if [ "${pop_n:-0}" -ge "$POPULATION_FLOOR" ]; then
  ok "T2: plugin 配下の走査件数 ${pop_n} は下限 ${POPULATION_FLOOR} 以上"
else
  bad "T2: plugin 配下の走査件数 ${pop_n:-0} が下限 ${POPULATION_FLOOR} を割った（母集団の導出が壊れている）"
fi
for anchor in hooks/guard-review-in-flight.sh tests/changelog-fragments/fixtures/bin/git; do
  if grep -Fxq "SCANNED_FILE=$anchor" "$TMP/tree.out"; then
    ok "T3: 母集団のアンカー ${anchor} が走査されている"
  else
    bad "T3: 母集団のアンカー ${anchor} が無い（走査対象の導出が壊れている）"
  fi
done
if [ "$t_rc" -ne 2 ]; then
  if env_branch_render "$ENV_BRANCH_BASELINE" "$TMP/tree.out" | cmp -s - "$ENV_BRANCH_BASELINE"; then
    ok "PB2: 基線は --print-baseline の出力と一致する（取り直しで余計な差分が出ない）"
  else
    bad "PB2: 基線が --print-baseline の出力と一致しない（取り直して区分を確かめる）"
  fi
fi

REACHED_END=1
echo ""
echo "env-branch-contract: pass=${PASS} fail=${FAIL}"
[ "$FAIL" -eq 0 ]
