#!/usr/bin/env bash
#
# sync-forbidden-patterns: 公開対象の禁止パターン検査を run-all から常時走らせる。
#
# 背景: 検査は公開同期を実行したときにしか走らず、同期は承認制で頻度が低い。
# 違反が develop に潜伏し、全 suite が緑のまま後の dry-run で初めて検出された。
# 発火しないゲートは無いのと同じ期間がある。
#
# 固定する契約:
#   - 公開対象の作業ツリーに禁止パターンを 1 件混入した隔離 dir を
#     --check-only --scan-dir すると、内容は file:line、ファイル名は相対パスで
#     名指しして非 0 で終わる
#   - 違反のない現状の公開対象作業ツリーは --check-only（target 不要）でクリアする
#   - パターン一覧の単一の真実源は同期スクリプトの配列。本 suite は配列を
#     持たない。スクリプト複製へ新しいパターンを足すと検出され、元スクリプト
#     では検出されないことで「更新後の一覧が使われる」を実測する
#   - 同期スクリプトや公開対象ディレクトリが無い checkout では ○ skip
#   - 一時領域を作れない場合も ○ skip（変異 fixture 用。live 検査の前に判定する）
#   - --check-only の live 分岐（--scan-dir なし）は、スクリプト配置先の
#     PUBLIC_TARGETS 作業ツリーを見る。隔離の偽リポジトリで配線を実測する
#   - 禁止パターンは走査から落ちない。走査はバイト指向（LC_ALL=C +
#     --binary-files=text）で、NUL を含む非空ファイルはファイルを読み切って
#     判定し fail-closed にする。grep の binary 判定に乗せると、判定する側と
#     走査する側で読む量が食い違い、大きなファイルの後方の NUL が素通りを作る
#   - 上の 2 点は BSD grep と GNU grep の両方で実測する（片方でしか成立しない
#     契約を書かない）
#   - symlink・FIFO 等の通常ファイル以外・改行を含むパスは fail-closed で拒否する
#     （走査対象にならない、または行区切りの突き合わせが成立しないため）
#   - binary 判定に使うツールの失敗と「binary だった」を混同しない。読めない
#     ファイルもそれと分かる診断で止める
#   - クリア表示に走査したファイル数を出す（空の走査と本物の通過を見分ける）
#
# 本ファイルは公開同期対象。禁止パターンのリテラルを隣接して書かないこと
# （隔離 fixture へ実行時に組み立てて流す。再現性のために実パスを戻すと
# 公開同期が止まる）。

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel 2>/dev/null || true)"
SYNC="${REPO_ROOT:+$REPO_ROOT/scripts/sync-dev-toolkit-to-public.sh}"

if [[ -z "$REPO_ROOT" || ! -f "$SYNC" ]]; then
  echo "○ skip: 同期スクリプトが無いチェックアウトのためスキップ（本 suite は SSOT リポジトリ専用の検査です）"
  FF_REACHED_END=1
  exit 0
fi

if ! targets="$("$SYNC" --list-targets)"; then
  echo "✗ --list-targets が失敗しました（スクリプトは存在するので検査不能は skip にしない）" >&2
  exit 1
fi
if [[ -z "$targets" ]]; then
  echo "✗ --list-targets の出力が空です（公開対象一覧の真実源が空なら検査は成立していない）" >&2
  exit 1
fi

while IFS= read -r t; do
  [[ -n "$t" ]] || continue
  if [[ ! -d "$REPO_ROOT/$t" ]]; then
    echo "○ skip: 公開対象ディレクトリが揃っていないチェックアウトのためスキップ"
    FF_REACHED_END=1
    exit 0
  fi
done <<<"$targets"

if _ff_mktemp_out="$(mktemp -d "${TMPDIR:-/tmp}/sync-forbidden-patterns.XXXXXX" 2>&1)"; then
  TMP="$_ff_mktemp_out"
else
  echo "○ skip: 一時ディレクトリを作成できない環境（read-only）のためスキップ"
  printf '  mktemp: %s\n' "$_ff_mktemp_out"
  FF_REACHED_END=1
  exit 0
fi

FF_REACHED_END=0
_ff_exit_guard() {
  _ff_rc=$?
  rm -rf "$TMP"
  if [[ "$_ff_rc" -eq 0 && "$FF_REACHED_END" -ne 1 ]]; then
    echo "✗ sync-forbidden-patterns: 最後まで到達しませんでした（途中で中断）" >&2
    exit 1
  fi
  exit "$_ff_rc"
}
trap _ff_exit_guard EXIT

PASS=0
FAIL=0
ok()  { echo "  ✓ $1"; PASS=$((PASS + 1)); }
bad() { echo "  ✗ $1" >&2; FAIL=$((FAIL + 1)); }

# 旧公開パスを実行時に組み立てる。本ファイルへ隣接リテラルで書かない。
retired_path="$(printf '%s%s' 'plugins/' 'dev-toolkit')"

run_check() {
  bash "$SYNC" --check-only "$@"
}

expect_clear() {
  local label="$1" out rc
  shift
  set +e
  out="$("$@" 2>&1)"
  rc=$?
  set -e
  if [[ "$rc" -eq 0 && "$out" == *"禁止パターン検査: クリア"* ]]; then
    ok "$label"
  else
    bad "$label (rc=${rc})"
    printf '%s\n' "$out" | sed 's/^/    | /' >&2
  fi
}

expect_hit() {
  local label="$1" needle="$2" out rc
  shift 2
  set +e
  out="$("$@" 2>&1)"
  rc=$?
  set -e
  if [[ "$rc" -ne 0 && "$out" == *"$needle"* ]]; then
    ok "$label"
  else
    bad "$label (rc=${rc})"
    printf '%s\n' "$out" | sed 's/^/    | /' >&2
  fi
}

# 非 0 に加えて「どの理由で止まったか」まで見る。ファイル名だけを見る assert は、
# 走査不能の guard が消えても内容違反として非 0 になる経路で空振りする。
expect_hit_reason() {
  local label="$1" needle="$2" reason="$3" out rc
  shift 3
  set +e
  out="$("$@" 2>&1)"
  rc=$?
  set -e
  if [[ "$rc" -ne 0 && "$out" == *"$needle"* && "$out" == *"$reason"* ]]; then
    ok "$label"
  else
    bad "$label (rc=${rc})"
    printf '%s\n' "$out" | sed 's/^/    | /' >&2
  fi
}

expect_fail() {
  local label="$1" needle="$2" out rc
  shift 2
  set +e
  out="$("$@" 2>&1)"
  rc=$?
  set -e
  if [[ "$rc" -ne 0 && "$out" == *"$needle"* ]]; then
    ok "$label"
  else
    bad "$label (rc=${rc})"
    printf '%s\n' "$out" | sed 's/^/    | /' >&2
  fi
}

echo "sync-forbidden-patterns verify:"

# --- 1. 現状の公開対象作業ツリーはクリア（--target なしで検査できること） ----
expect_clear "現状の公開対象作業ツリーは --check-only でクリアする" run_check

# --- 2. 違反のない隔離 dir は pass ------------------------------------------
mkdir -p "$TMP/clean"
printf '%s\n' 'safe content' > "$TMP/clean/ok.md"
: > "$TMP/clean/empty.txt"
expect_clear "違反のない隔離 dir は --scan-dir でクリアする（空ファイル含む）" \
  run_check --scan-dir "$TMP/clean"

mkdir -p "$TMP/empty"
expect_clear "空の --scan-dir はクリアする" run_check --scan-dir "$TMP/empty"

# --- 3. 内容への混入をファイルと行で名指しする（変異） ------------------------
mkdir -p "$TMP/content"
printf '%s\n' 'safe line 1' 'safe line 2' "$retired_path" > "$TMP/content/note.md"
expect_hit "内容の混入をファイルと行で名指しして非 0 にする" "note.md:3" \
  run_check --scan-dir "$TMP/content"

# --- 4. ファイル名への混入を名指しする（変異） --------------------------------
mkdir -p "$TMP/name/${retired_path}"
printf '%s\n' 'safe' > "$TMP/name/${retired_path}/x.txt"
expect_hit "ファイル名の混入をパスで名指しして非 0 にする" "$retired_path" \
  run_check --scan-dir "$TMP/name"

# --- 5. 配列を更新すると新しいパターンが使われる（二重定義しないことの実測） --
sentinel="ff476sentinelforbidden"
awk -v s="$sentinel" '
  /^FORBIDDEN_PATTERNS=\(/ {
    print
    print "  '\''" s "'\''"
    next
  }
  { print }
' "$SYNC" > "$TMP/mutated.sh"
chmod +x "$TMP/mutated.sh"
mkdir -p "$TMP/sentinel"
printf '%s\n' 'safe line' "$sentinel" > "$TMP/sentinel/s.txt"

expect_hit "配列へ足したパターンを複製スクリプトが検出する" "s.txt:2" \
  bash "$TMP/mutated.sh" --check-only --scan-dir "$TMP/sentinel"
expect_clear "元スクリプトは未登録のセンチネルを検出しない（一覧は配列が真実源）" \
  run_check --scan-dir "$TMP/sentinel"

# --- 6. live 分岐（--scan-dir なし）の配線を偽リポジトリで実測 ---------------
FAKE="$TMP/fake"
mkdir -p "$FAKE/scripts" "$FAKE/plugins/ff-dev-toolkit" "$FAKE/oss/ff-dev-toolkit"
cp "$SYNC" "$FAKE/scripts/sync-dev-toolkit-to-public.sh"
printf '%s\n' 'ok' > "$FAKE/plugins/ff-dev-toolkit/ok.md"
printf '%s\n' 'ok' > "$FAKE/oss/ff-dev-toolkit/ok.md"
expect_clear "偽リポジトリの live --check-only は健全ならクリアする" \
  bash "$FAKE/scripts/sync-dev-toolkit-to-public.sh" --check-only

printf '%s\n' 'safe' 'safe' "$retired_path" > "$FAKE/plugins/ff-dev-toolkit/hit.md"
expect_hit "live --check-only は PUBLIC_TARGETS 作業ツリーの混入を file:line で名指しする" \
  "plugins/ff-dev-toolkit/hit.md:3" \
  bash "$FAKE/scripts/sync-dev-toolkit-to-public.sh" --check-only

# --- 7. symlink / binary は fail-closed。空ファイルは通す -------------------
mkdir -p "$TMP/link"
printf '%s\n' 'safe' > "$TMP/link/ok.md"
ln -s ok.md "$TMP/link/alias.md"
expect_hit "symlink 混入は相対パスを名指しして非 0 にする" "alias.md" \
  run_check --scan-dir "$TMP/link"

# FIFO は走査対象にならないうえ、grep -r が open した時点で書き手が来るまで
# 無言でブロックする（検査が返らない = 可用性の fail-open）。symlink と同じく
# 拒否する。mkfifo が使えない環境ではこのケースだけ観測できない。
mkdir -p "$TMP/fifo"
printf '%s\n' 'safe' > "$TMP/fifo/ok.md"
if mkfifo "$TMP/fifo/pipe" 2>/dev/null; then
  expect_hit_reason "FIFO 混入は非 0 にする（ハングさせない）" "pipe" \
    "通常ファイル以外" \
    run_check --scan-dir "$TMP/fifo"
  rm -f "$TMP/fifo/pipe"
else
  echo "  ⚠ mkfifo が使えないため、FIFO の拒否は観測していません"
fi

# 固定する契約は「禁止パターンは走査から落ちない」。走査はバイト指向
# （LC_ALL=C + --binary-files=text）で、binary 判定は grep ではなくファイルを
# 読み切って NUL の有無で決める。grep に任せると、判定する側（-l は最初の一致で
# 読むのをやめる）とパターンを走査する側（読み進めて NUL で打ち切る）で読む量が
# 食い違い、GNU grep では 96KiB 超のファイルが素通りする（#486 で実測）。
# fixture は内容依存で結果が変わらないものだけを置く（乱数は使わない。#482）。
binary_reason="binary ファイルが含まれています"
mkdir -p "$TMP/bin"
printf 'header\0\0\0trailer\n' > "$TMP/bin/blob.bin"
expect_hit_reason "NUL を含む非空 binary は非 0 にする" "blob.bin" \
  "$binary_reason" \
  run_check --scan-dir "$TMP/bin"

# 素通しが実害になることの実証。理由まで見るのは、guard が消えても内容違反として
# 非 0 になる経路があると、ファイル名だけの assert が空振りするため。
mkdir -p "$TMP/bin-payload"
printf 'header\0\0\0 %s tail\n' "$retired_path" > "$TMP/bin-payload/payload.bin"
expect_hit_reason "NUL の内側に隠した禁止パターンを素通しさせない" "payload.bin" \
  "$binary_reason" \
  run_check --scan-dir "$TMP/bin-payload"

# NUL の位置は grep の binary 判定（先頭バッファのみ）より後ろにも置ける。
# 読み切って判定するので位置に依存しない。
mkdir -p "$TMP/late-nul"
{
  i=0
  while [[ "$i" -lt 4000 ]]; do
    printf 'filler line %s aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\n' "$i"
    i=$((i + 1))
  done
  printf '\0\0\0 %s tail\n' "$retired_path"
} > "$TMP/late-nul/late.bin"
expect_hit_reason "先頭バッファより後ろに NUL がある大きなファイルも非 0 にする" "late.bin" \
  "$binary_reason" \
  run_check --scan-dir "$TMP/late-nul"

# 走査そのものも先頭バッファで打ち切られてはいけない。NUL を含まない大きな
# ファイルの末尾に禁止パターンを置き、内容違反として名指しされることを見る。
mkdir -p "$TMP/late-hit"
{
  i=0
  while [[ "$i" -lt 4000 ]]; do
    printf 'filler line %s aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\n' "$i"
    i=$((i + 1))
  done
  printf '%s tail\n' "$retired_path"
} > "$TMP/late-hit/late.txt"
expect_hit_reason "先頭バッファより後ろにある禁止パターンも内容違反として名指しする" \
  "late.txt:4001" "禁止パターン検出（内容）" \
  run_check --scan-dir "$TMP/late-hit"

# 走査対象の突き合わせは行区切りで行うため、改行を含むパスは 1 件が複数行へ割れ、
# どの断片も実在せず binary 判定から落ちる。名前を理由に検査を外れる経路を
# 作らないよう、fail-closed で拒否する。
mkdir -p "$TMP/newline"
printf 'header\0\0\0 %s tail\n' "$retired_path" > "$TMP/newline/$(printf 'weird\nname.bin')"
printf '%s\n' 'safe' > "$TMP/newline/ok.md"
expect_hit_reason "改行を含むパスは検査が成立しないものとして非 0 にする" "name.bin" \
  "改行を含むパス" \
  run_check --scan-dir "$TMP/newline"

# 現ロケールで復号できない行があっても、走査はバイト指向なので禁止パターンは
# 掛かる（ロケールに依存しない）。UTF-8 ロケールでも内容違反として名指しする。
mkdir -p "$TMP/mixed"
printf '\377\376 %s tail\nplain ascii line\n' "$retired_path" > "$TMP/mixed/mixed.txt"
expect_hit_reason "復号できない行の中の禁止パターンも内容違反として名指しする" \
  "mixed.txt:1" "禁止パターン検出（内容）" \
  run_check --scan-dir "$TMP/mixed"

# 走査そのものが失敗した場合は「クリア」にしない。exit 1 は「マッチ無し」で
# 正常なので、2 以上だけを失敗として扱う。
mkdir -p "$TMP/shim-grep"
printf '%s\n' '#!/bin/sh' 'exit 2' > "$TMP/shim-grep/grep"
chmod +x "$TMP/shim-grep/grep"
expect_hit_reason "禁止パターン走査の失敗は検査不能として非 0 にする" "grep exit=2" \
  "禁止パターン検査自体が失敗" \
  env PATH="$TMP/shim-grep:$PATH" bash "$SYNC" --check-only --scan-dir "$TMP/clean"

# 違反の判定は終了コードではなく出力の有無で行う。マッチ行を出しながら exit 1 を
# 返す grep（実装によっては binary を後から見つけたときにこうなる）を置いて、
# 見つけた違反を捨てないことを実測する。前段の binary 判定がこの入力を先に
# 止めてしまうため、実装差そのものは注入しないと観測できない。
# shim は自分自身を呼び返さないよう、実体の grep を絶対パスで埋め込む。
real_grep="$(command -v grep)"
mkdir -p "$TMP/shim-grep-hit"
{
  printf '%s\n' '#!/bin/sh'
  printf '%s\n' 'case " $* " in'
  printf '%s\n' '  *" -rnE "*) printf "%s\\n" "/tmp/planted.txt:1:planted"; exit 1 ;;'
  printf '%s\n' 'esac'
  printf 'exec %s "$@"\n' "$real_grep"
} > "$TMP/shim-grep-hit/grep"
chmod +x "$TMP/shim-grep-hit/grep"
expect_hit_reason "マッチを出しながら exit 1 を返す走査でも違反として扱う" "planted" \
  "禁止パターン検出（内容）" \
  env PATH="$TMP/shim-grep-hit:$PATH" bash "$SYNC" --check-only --scan-dir "$TMP/clean"

# 逆向き: 出力なし + exit 1 は「一致なし」として通す（上の判定が全部を違反に
# しないことの対）。
mkdir -p "$TMP/shim-grep-miss"
{
  printf '%s\n' '#!/bin/sh'
  printf '%s\n' 'case " $* " in'
  printf '%s\n' '  *" -rnE "*) exit 1 ;;'
  printf '%s\n' 'esac'
  printf 'exec %s "$@"\n' "$real_grep"
} > "$TMP/shim-grep-miss/grep"
chmod +x "$TMP/shim-grep-miss/grep"
expect_clear "出力なしの exit 1 は一致なしとして通す" \
  env PATH="$TMP/shim-grep-miss:$PATH" bash "$SYNC" --check-only --scan-dir "$TMP/clean"

# binary 判定に使うツールの失敗は「binary だった」と混同しない（原因の特定を
# 奪わない）。判定に使う wc を落として、専用の診断で止まることを見る。
mkdir -p "$TMP/shim-wc"
printf '%s\n' '#!/bin/sh' 'exit 2' > "$TMP/shim-wc/wc"
chmod +x "$TMP/shim-wc/wc"
expect_hit_reason "binary 判定ツールの失敗は binary 検出と区別して非 0 にする" "ok.md" \
  "binary 判定自体が失敗" \
  env PATH="$TMP/shim-wc:$PATH" bash "$SYNC" --check-only --scan-dir "$TMP/clean"

# パイプの前段（tr）だけが落ちる形も同じ診断で止める。pipefail に頼っている
# ぶん、後段だけを落とす shim では前段の異常検知が固定されない。
mkdir -p "$TMP/shim-tr"
printf '%s\n' '#!/bin/sh' 'exit 2' > "$TMP/shim-tr/tr"
chmod +x "$TMP/shim-tr/tr"
expect_hit_reason "判定パイプの前段（tr）だけの失敗も検査不能として非 0 にする" "ok.md" \
  "binary 判定自体が失敗" \
  env PATH="$TMP/shim-tr:$PATH" bash "$SYNC" --check-only --scan-dir "$TMP/clean"

# 読めないファイルは「ツールが失敗した」ではなく読めないことを名乗る。
# root では権限が効かないので観測しない。
if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
  mkdir -p "$TMP/unreadable"
  printf '%s\n' 'secret' > "$TMP/unreadable/locked.txt"
  chmod 000 "$TMP/unreadable/locked.txt"
  expect_hit_reason "読めないファイルは専用の診断で非 0 にする" "locked.txt" \
    "検査対象を読めません" \
    run_check --scan-dir "$TMP/unreadable"
  chmod 644 "$TMP/unreadable/locked.txt"
else
  echo "  ⚠ root 実行のため、読めないファイルの診断は観測していません"
fi

# 比較する側が早期終了すると、書き手が SIGPIPE で死んで「ツールの失敗」に化ける。
# 実 binary（PNG 等）はこの形なので、パイプバッファを超える大きさで NUL を先頭
# 付近に置いた fixture で、binary として報告されることを固定する（#488）。
mkdir -p "$TMP/big-bin"
{
  printf 'PNG\0\0\0'
  i=0
  while [[ "$i" -lt 20000 ]]; do
    printf 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
'
    i=$((i + 1))
  done
} > "$TMP/big-bin/image.bin"
expect_hit_reason "先頭付近に NUL がある大きな binary も binary として報告する" "image.bin" \
  "$binary_reason" \
  run_check --scan-dir "$TMP/big-bin"

# ファイル名側の走査もバイト指向にする。不正な UTF-8 を含む名前があると、
# ロケール依存のままでは実装ごとに違う壊れ方をする（BSD は sed が
# illegal byte sequence で落ちて診断が出ない / GNU は「binary file matches」に
# なって該当パスが報告から消える）。禁止パターンを含む名前で名指しを固定する。
# APFS は不正な UTF-8 のファイル名を拒否するため、作れない環境では観測しない。
mkdir -p "$TMP/badname"
printf '%s\n' 'safe' > "$TMP/badname/ok.md"
bad_component="$(printf 'bad\377\376dir')"
if mkdir -p "$TMP/badname/$bad_component/$retired_path" 2>/dev/null; then
  printf '%s\n' 'x' > "$TMP/badname/$bad_component/$retired_path/x.txt"
  expect_hit_reason "不正な UTF-8 を含むパスの中の禁止パターンも名指しする" \
    "$retired_path" "禁止パターン検出（ファイル名）" \
    run_check --scan-dir "$TMP/badname"
else
  echo "  ⚠ 不正な UTF-8 のパスを作れない環境のため、この経路は観測していません"
fi

# 上の実行時ケースはファイルシステム依存（APFS は不正な UTF-8 名を拒否する）なので、
# ロケール固定が両方に入っていること自体は環境非依存の静的検査で固定する。
# 片方だけ入れると不正バイトがロケール依存の照合へ流れて「一致なし」に化けるため、
# 2 箇所を対で見る。
has_name_locale_pins() {
  local script="$1"
  grep -qF '| LC_ALL=C sed ' "$script" || return 1
  grep -qF 'name_hits="$(LC_ALL=C grep -E ' "$script" || return 1
  return 0
}
if has_name_locale_pins "$SYNC"; then
  ok "ファイル名側の前処理と照合の両方にロケール固定が入っている（静的検査）"
else
  bad "ファイル名側のロケール固定が片方または両方欠けている"
fi
sed 's/| LC_ALL=C sed /| sed /' "$SYNC" > "$TMP/no-sed-pin.sh"
if has_name_locale_pins "$TMP/no-sed-pin.sh"; then
  bad "静的検査が前処理側の欠落を検出できない（空振りしている）"
else
  ok "静的検査は前処理側の欠落を検出する"
fi
sed 's/name_hits="\$(LC_ALL=C grep -E /name_hits="\$(grep -E /' "$SYNC" > "$TMP/no-grep-pin.sh"
if has_name_locale_pins "$TMP/no-grep-pin.sh"; then
  bad "静的検査が照合側の欠落を検出できない（空振りしている）"
else
  ok "静的検査は照合側の欠落を検出する"
fi

# 走査したファイル数を出す（空の走査と本物の pass を見分けられるようにする）。
# 部分一致だと 2 が 12 や 22 にも当たるので、区切りごと照合する。空ファイルも
# ファイル名検査の対象なので数に入れる（除くと空ファイルだけの走査が 0 件になり、
# 空の走査と見分けられない）。node_modules 配下は除外されるので数にも入らない。
expect_count() {
  local label="$1" dir="$2" want="$3" out rc
  set +e
  out="$(run_check --scan-dir "$dir" 2>&1)"
  rc=$?
  set -e
  if [[ "$rc" -eq 0 && "$out" == *"/ ${want} ファイル）"* ]]; then
    ok "$label"
  else
    bad "$label (rc=${rc}, 期待 ${want} 件)"
    printf '%s\n' "$out" | sed 's/^/    | /' >&2
  fi
}
mkdir -p "$TMP/counted"
printf '%s\n' 'a' > "$TMP/counted/a.md"
printf '%s\n' 'b' > "$TMP/counted/b.md"
expect_count "クリア表示に走査したファイル数が出る" "$TMP/counted" 2

mkdir -p "$TMP/counted-empty"
: > "$TMP/counted-empty/only-empty.txt"
expect_count "空ファイルだけの走査も件数に出る（0 件と区別できる）" "$TMP/counted-empty" 1

mkdir -p "$TMP/counted-nm/node_modules/pkg"
printf '%s\n' 'a' > "$TMP/counted-nm/a.md"
printf '%s\n' 'x' > "$TMP/counted-nm/node_modules/pkg/y.md"
expect_count "除外した node_modules 配下は件数に入らない" "$TMP/counted-nm" 1

# 空行だけのファイル・末尾改行なしのファイルは通す（偽陽性で実同期を止めない）。
mkdir -p "$TMP/edge"
printf '\n\n\n' > "$TMP/edge/blank.txt"
printf 'no trailing newline' > "$TMP/edge/no-nl.txt"
: > "$TMP/edge/empty.txt"
expect_clear "空行のみ・末尾改行なし・空ファイルはクリアする" \
  run_check --scan-dir "$TMP/edge"


# --- 8. 作業ツリー検査は node_modules 配下を見ない --------------------------
# 除外は「禁止パターン走査」だけでなく「binary 判定」にも要る。片方だけ除外を
# 落とすと、npm が置いた binary で実同期が止まる（偽陽性）。fixture は両方を
# 踏むように、禁止文字列と NUL 入り binary を node_modules 配下へ置く。
mkdir -p "$TMP/nm/node_modules/pkg"
printf '%s\n' "$retired_path" > "$TMP/nm/node_modules/pkg/secret.txt"
printf 'header\0\0\0trailer\n' > "$TMP/nm/node_modules/pkg/blob.bin"
printf '%s\n' 'safe' > "$TMP/nm/ok.md"
expect_clear "node_modules 配下の禁止文字列と binary は作業ツリー検査から除外する" \
  run_check --scan-dir "$TMP/nm"

# --- 8b. 実同期の staging 経路（prune=0）も走査不能を fail-closed にする ------
# --check-only が通るのは prune=1 の分岐だけで、公開を止めるのは prune=0 側。
# 片方だけ直しても suite が緑のままにならないよう、偽の source / target を組んで
# --dry-run で staging 走査まで到達させる（rsync の前に検査が走る）。
STG="$TMP/stage-repo"
mkdir -p "$STG/scripts" "$STG/plugins/ff-dev-toolkit" "$STG/oss/ff-dev-toolkit"
cp "$SYNC" "$STG/scripts/sync-dev-toolkit-to-public.sh"
printf '%s\n' 'MIT' > "$STG/plugins/ff-dev-toolkit/LICENSE"
printf '%s\n' 'ok' > "$STG/plugins/ff-dev-toolkit/ok.md"
printf '%s\n' 'ok' > "$STG/oss/ff-dev-toolkit/ok.md"
git -C "$STG" init -q
git -C "$STG" config user.email selftest@example.com
git -C "$STG" config user.name sync-forbidden-selftest
git -C "$STG" add -A
git -C "$STG" commit -qm "staging fixture"

PUBTGT="$TMP/public-target"
mkdir -p "$PUBTGT"
git -C "$PUBTGT" init -q
git -C "$PUBTGT" remote add origin git@github.com:feel-flow/ff-dev-toolkit.git

# 対照: 健全な staging は検査を通過する。ここは rsync の有無に結果を預けない
# （検査のクリア表示は rsync より前に出る）ため rc は見ない。
set +e
stage_clean_out="$(bash "$STG/scripts/sync-dev-toolkit-to-public.sh" --target "$PUBTGT" --dry-run 2>&1)"
set -e
if [[ "$stage_clean_out" == *"禁止パターン検査: クリア"* ]]; then
  ok "健全な staging は prune=0 の走査を通過する（対照）"
else
  bad "staging fixture が検査へ到達していない"
  printf '%s\n' "$stage_clean_out" | sed 's/^/    | /' >&2
fi

# 本題: HEAD に NUL 入り binary をコミットすると staging 走査で止まる。
printf 'header\0\0\0 %s tail\n' "$retired_path" > "$STG/plugins/ff-dev-toolkit/staged.bin"
git -C "$STG" add -A
git -C "$STG" commit -qm "staged binary"
expect_hit_reason "staging 走査（prune=0）も NUL 入り binary で公開前に止まる" "staged.bin" \
  "$binary_reason" \
  bash "$STG/scripts/sync-dev-toolkit-to-public.sh" --target "$PUBTGT" --dry-run

# 改行パスの拒否も分岐ごとに配線が要る。片方だけ落ちると、公開を止める側だけが
# 名前を理由に検査を外れる（改行の検査は走査不能の判定より前に出るため、
# fixture からは NUL 入り binary を外して単独で観測する）。
git -C "$STG" rm -q "plugins/ff-dev-toolkit/staged.bin"
printf '%s\n' 'x' > "$STG/plugins/ff-dev-toolkit/$(printf 'staged\nname.md')"
git -C "$STG" add -A
git -C "$STG" commit -qm "staged newline path"
expect_hit_reason "staging 走査（prune=0）も改行を含むパスで止まる" "name.md" \
  "改行を含むパス" \
  bash "$STG/scripts/sync-dev-toolkit-to-public.sh" --target "$PUBTGT" --dry-run

# --- 9. スクリプト不在の checkout は ○ skip --------------------------------
PUB="$TMP/public-checkout"
mkdir -p "$PUB/plugins/ff-dev-toolkit/tests/sync-forbidden-patterns"
cp "$SCRIPT_DIR/verify.sh" "$PUB/plugins/ff-dev-toolkit/tests/sync-forbidden-patterns/verify.sh"
git -C "$PUB" init -q
git -C "$PUB" config user.email selftest@example.com
git -C "$PUB" config user.name sync-forbidden-selftest
set +e
skip_out="$(bash "$PUB/plugins/ff-dev-toolkit/tests/sync-forbidden-patterns/verify.sh" 2>&1)"
skip_rc=$?
set -e
if [[ "$skip_rc" -eq 0 && $'\n'"$skip_out" == *$'\n○ skip'* ]]; then
  ok "同期スクリプトが無い checkout は行頭 ○ skip で exit 0"
else
  bad "スクリプト不在の skip 契約が崩れた (rc=${skip_rc})"
  printf '%s\n' "$skip_out" | sed 's/^/    | /' >&2
fi

# --- 10. 新設フラグの不正組み合わせは説明付きで非 0 --------------------------
expect_fail "--scan-dir 単独は拒否する" "--check-only と一緒" \
  bash "$SYNC" --scan-dir "$TMP/clean"
expect_fail "--check-only と --dry-run は同時に使えない" "--dry-run" \
  bash "$SYNC" --check-only --dry-run
expect_fail "--check-only と --target は同時に使えない" "--target" \
  bash "$SYNC" --check-only --target "$TMP/clean"
expect_fail "存在しない --scan-dir は拒否する" "存在しません" \
  bash "$SYNC" --check-only --scan-dir "$TMP/does-not-exist"

echo
if [[ "$FAIL" -gt 0 ]]; then
  echo "✗ sync-forbidden-patterns verify: ${FAIL} 件 fail / ${PASS} 件 pass" >&2
  FF_REACHED_END=1
  exit 1
fi
echo "✓ sync-forbidden-patterns verify: 全 ${PASS} 件 pass"
FF_REACHED_END=1
exit 0
