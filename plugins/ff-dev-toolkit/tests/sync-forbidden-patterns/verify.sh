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
# 同じ「公開対象へ非公開の識別子を混ぜない」系として、**追加行限定**の検査
# （scripts/check-added-bare-refs.sh）も本 suite が固定する。全文検査にできない
# （既存行に同型が多数ある）ため対象が差分の追加行に限られる点だけが上と違う:
#   - 公開対象の追加行に番号短縮形があれば file:line で名指しして非 0 にする
#   - 同型が既存行にだけある木は通す（差分限定であることの実測）
#   - 公開 URL 形式・fence / inline code / markdown リンク内の追加行は通す。
#     許可規則の真実源は scripts/scan-bare-issue-refs.sh で、検査側も本 suite も
#     規則を複製しない（走査器を素朴な全件検出へ差し替える変異で実測する）
#   - ローカル develop が無く origin/develop だけの clone でも成立する
#   - 公開対象が無い checkout は skip ではなく「対象 0 件で pass」（判定は base ref の
#     解決より前に置く）。base ref を解決できない木は fail-closed
#   - fence が閉じていないファイル（意図的な fixture が実在する）は走査を諦めず、
#     fence 記号を潰した写しで走査し直す（閉じない fence の素通しを作らない）
#
# 到達可能参照の allowlist（scripts/scan-unreachable-repo-refs.sh）は 2 つの形を見る。
# `owner/repo#N` は owner を問わず全件、URL 形（`https://github.com/<org>/<repo>/...`
# と SCP 形）は SSOT の org 配下だけ。後者を org へ絞るのは、公開対象に外部の公開
# リポジトリ URL と、そもそもリポジトリでない GitHub のパスが多数あり、owner を
# 問わない allowlist が成立しないため。本 suite は許可側（外部 owner・非リポジトリ
# パス・サブドメイン）と禁止側を対で固定する。
#
# 本ファイルは公開同期対象。禁止パターンのリテラルを隣接して書かないこと
# （隔離 fixture へ実行時に組み立てて流す。再現性のために実パスを戻すと
# 公開同期が止まる）。

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel 2>/dev/null || true)"
# fixture リポジトリの identity を呼び出し元へ漏らさない（Issue #1348 / #1368）
# 本 suite は公開 checkout へ verify.sh だけをコピーする。lib 不在なら source せず、対象スクリプト不在の既存 skip へ到達する
# shellcheck source=../lib/git-fixture.sh
if [ -f "$SCRIPT_DIR/../lib/git-fixture.sh" ]; then
  . "$SCRIPT_DIR/../lib/git-fixture.sh"
fi

SYNC="${REPO_ROOT:+$REPO_ROOT/scripts/sync-dev-toolkit-to-public.sh}"
# 到達不能参照の走査器。同期スクリプトを写す fixture はこれも要る
# （不在は fail-closed で exit 非 0 になる = 検査が成立しない）。
UNREACHABLE_SRC="${REPO_ROOT:+$REPO_ROOT/scripts/scan-unreachable-repo-refs.sh}"

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

# rc=0 でも -d を検査する — 2>&1 の合流は「成功 + stderr 警告」の環境で変数へ
# 警告文が混入し、以後の処理が原因不明の失敗に化けるため。
if _ff_mktemp_out="$(mktemp -d "${TMPDIR:-/tmp}/sync-forbidden-patterns.XXXXXX" 2>&1)" && [ -d "$_ff_mktemp_out" ]; then
  TMP="$_ff_mktemp_out"
else
  echo "○ skip: 一時ディレクトリを作成できない環境のためスキップ"
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
cp "$UNREACHABLE_SRC" "$FAKE/scripts/scan-unreachable-repo-refs.sh"
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
cp "$UNREACHABLE_SRC" "$STG/scripts/scan-unreachable-repo-refs.sh"
printf '%s\n' 'MIT' > "$STG/plugins/ff-dev-toolkit/LICENSE"
printf '%s\n' 'ok' > "$STG/plugins/ff-dev-toolkit/ok.md"
printf '%s\n' 'ok' > "$STG/oss/ff-dev-toolkit/ok.md"
ff_git_fixture_init "$STG" "sync-forbidden-selftest" "selftest@example.com"
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
ff_git_fixture_init "$PUB" "sync-forbidden-selftest" "selftest@example.com"
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

# --- 11. 公開対象の追加行に bare な番号短縮形を書かせない（差分限定） --------
# 対象は scripts/check-added-bare-refs.sh。既存行に同型が多数あるため全文検査は
# 成立せず、base ref との差分の**追加行**だけを見る。許可規則（公開 URL 形式・
# fence / inline code / markdown リンク内）は scripts/scan-bare-issue-refs.sh が
# 真実源で、本 suite も検査側も規則を複製しない（変異注入でそれを実測する）。
ADDED_REFS="$REPO_ROOT/scripts/check-added-bare-refs.sh"
SCANNER_SRC="$REPO_ROOT/scripts/scan-bare-issue-refs.sh"

# 番号短縮形のリテラルを本ファイルへ隣接して書かない（本ファイルは公開同期対象で、
# 上記の検査自身の対象でもある）。fixture へは実行時に組み立てて流す。
HASH="$(printf '%s' '#')"

if [[ ! -f "$ADDED_REFS" || ! -f "$SCANNER_SRC" || ! -f "$UNREACHABLE_SRC" ]]; then
  bad "追加行の bare 参照検査（または走査器）が見つかりません"
else
  expect_refs_rc() { # label want_rc needle cmd...
    local label="$1" want="$2" needle="$3" out rc
    shift 3
    set +e
    out="$("$@" 2>&1)"
    rc=$?
    set -e
    if [[ "$rc" -eq "$want" && "$out" == *"$needle"* ]]; then
      ok "$label"
    else
      bad "$label (rc=${rc} / 期待 ${want})"
      printf '%s\n' "$out" | sed 's/^/    | /' >&2
    fi
  }

  # 「1 行当たれば緑」にしない。列挙した needle が**すべて**出ることを見る
  # （形ごと・行ごとの検出力を区別するため）。
  expect_refs_all() { # label want_rc needles(改行区切り) cmd...
    local label="$1" want="$2" needles="$3" out rc missing="" nd
    shift 3
    set +e
    out="$("$@" 2>&1)"
    rc=$?
    set -e
    while IFS= read -r nd; do
      [[ -n "$nd" ]] || continue
      case "$out" in
        *"$nd"*) ;;
        *) missing="${missing} ${nd}" ;;
      esac
    done <<<"$needles"
    if [[ "$rc" -eq "$want" && -z "$missing" ]]; then
      ok "$label"
    else
      bad "$label (rc=${rc} / 期待 ${want}${missing:+ / 不足:${missing}})"
      printf '%s\n' "$out" | sed 's/^/    | /' >&2
    fi
  }

  # 出るべき行と**出てはいけない行**を対で見る（片側だけだと、許容側が違反側へ
  # 滑っても緑のまま通る）。
  expect_refs_only() { # label want_rc needle absent cmd...
    local label="$1" want="$2" needle="$3" absent="$4" out rc
    shift 4
    set +e
    out="$("$@" 2>&1)"
    rc=$?
    set -e
    if [[ "$rc" -eq "$want" && "$out" == *"$needle"* && "$out" != *"$absent"* ]]; then
      ok "$label"
    else
      bad "$label (rc=${rc} / 期待 ${want} / ${absent} は出ないこと)"
      printf '%s\n' "$out" | sed 's/^/    | /' >&2
    fi
  }

  # 偽 SSOT repo: 公開対象 2 つ・検査スクリプト一式・origin/develop だけを持ち、
  # ローカル develop は作らない（AC の「develop が無い clone」を模す）。
  refs_fixture_prepare() {
    local dir="$1"
    mkdir -p "$dir/scripts" "$dir/plugins/ff-dev-toolkit" "$dir/oss/ff-dev-toolkit"
    cp "$SYNC" "$dir/scripts/sync-dev-toolkit-to-public.sh"
    cp "$SCANNER_SRC" "$dir/scripts/scan-bare-issue-refs.sh"
    cp "$ADDED_REFS" "$dir/scripts/check-added-bare-refs.sh"
    cp "$UNREACHABLE_SRC" "$dir/scripts/scan-unreachable-repo-refs.sh"
    printf '%s\n' 'baseline' > "$dir/oss/ff-dev-toolkit/doc.md"
  }
  refs_fixture_commit() {
    local dir="$1"
    ff_git_fixture_init "$dir" "sync-forbidden-selftest" "selftest@example.com" || return 1
    git -C "$dir" symbolic-ref HEAD refs/heads/work
    git -C "$dir" add -A
    git -C "$dir" commit -qm "baseline"
    git -C "$dir" update-ref refs/remotes/origin/develop HEAD
  }
  refs_run() { bash "$1/scripts/check-added-bare-refs.sh"; }

  # 11-1. 追加行の混入をファイルと行で名指しする。3 つの形（`Issue <番号>` /
  # `PR <番号>` / 文頭の番号）と、公開対象 2 つの**どちらの配下でも**検出することを
  # 対で固定する（1 形・1 ディレクトリだけの針は、残りが外れても緑のまま通る）。
  F_DETECT="$TMP/refs-detect"
  refs_fixture_prepare "$F_DETECT"
  printf '%s\n' 'baseline' > "$F_DETECT/plugins/ff-dev-toolkit/doc.md"
  refs_fixture_commit "$F_DETECT"
  {
    printf '%s\n' "detail: Issue ${HASH}123 を参照"
    printf '%s\n' "follow-up: PR ${HASH}124 を参照"
    printf '%s\n' "${HASH}125 の対応をここに書く"
  } >> "$F_DETECT/plugins/ff-dev-toolkit/doc.md"
  printf '%s\n' "oss 側の追加行: PR ${HASH}126" >> "$F_DETECT/oss/ff-dev-toolkit/doc.md"
  expect_refs_all "3 つの形を公開対象 2 つの配下でファイルと行まで名指しする" 1 \
    'plugins/ff-dev-toolkit/doc.md:2
plugins/ff-dev-toolkit/doc.md:3
plugins/ff-dev-toolkit/doc.md:4
oss/ff-dev-toolkit/doc.md:2' refs_run "$F_DETECT"

  # 11-2. ローカル develop が無く origin/develop だけの clone でも成立する
  if git -C "$F_DETECT" rev-parse --verify --quiet develop >/dev/null 2>&1; then
    bad "fixture にローカル develop が出来ている（origin/develop だけの clone を模せていない）"
  else
    expect_refs_rc "ローカル develop が無い clone は origin/develop を基準に検査する" 1 \
      "base=origin/develop" refs_run "$F_DETECT"
  fi

  # 11-3. 既存行にだけ同型がある木は通す（全文検査にしない）
  F_EXISTING="$TMP/refs-existing"
  refs_fixture_prepare "$F_EXISTING"
  printf '%s\n' "既存行: Issue ${HASH}123" 'baseline' > "$F_EXISTING/plugins/ff-dev-toolkit/doc.md"
  refs_fixture_commit "$F_EXISTING"
  printf '%s\n' 'clean added line' >> "$F_EXISTING/plugins/ff-dev-toolkit/doc.md"
  expect_refs_rc "既存行の同型は許容する（差分の追加行だけを見る）" 0 "クリア" \
    refs_run "$F_EXISTING"

  # 11-4. 許可規則（公開 URL 形式 / inline code / markdown リンク / fence 内）
  F_ALLOWED="$TMP/refs-allowed"
  refs_fixture_prepare "$F_ALLOWED"
  printf '%s\n' 'baseline' > "$F_ALLOWED/plugins/ff-dev-toolkit/doc.md"
  refs_fixture_commit "$F_ALLOWED"
  {
    printf '%s\n' 'public url: https://github.com/feel-flow/ff-dev-toolkit/issues/123'
    printf '%s\n' "inline code: \`${HASH}123\`"
    printf '%s\n' "link: [PR ${HASH}123](https://github.com/feel-flow/ff-dev-toolkit/pull/123)"
    printf '%s\n' '```'
    printf '%s\n' "fence 内: ${HASH}123"
    printf '%s\n' '```'
  } >> "$F_ALLOWED/plugins/ff-dev-toolkit/doc.md"
  expect_refs_rc "公開 URL / inline code / リンク / fence 内の追加行は通す" 0 "クリア" \
    refs_run "$F_ALLOWED"

  # 11-5. 公開対象が無い checkout は skip ではなく「対象 0 件で pass」
  # （公開対象の判定は base ref の解決より前。commit も origin/develop も無い木で通る）
  F_NOTARGET="$TMP/refs-no-targets"
  mkdir -p "$F_NOTARGET/scripts"
  cp "$SYNC" "$F_NOTARGET/scripts/sync-dev-toolkit-to-public.sh"
  cp "$SCANNER_SRC" "$F_NOTARGET/scripts/scan-bare-issue-refs.sh"
  cp "$ADDED_REFS" "$F_NOTARGET/scripts/check-added-bare-refs.sh"
  cp "$UNREACHABLE_SRC" "$F_NOTARGET/scripts/scan-unreachable-repo-refs.sh"
  ff_git_fixture_init "$F_NOTARGET" "sync-forbidden-selftest" "selftest@example.com"
  expect_refs_rc "公開対象が無い checkout は対象 0 件で pass する（skip にしない）" 0 \
    "対象 0 件" refs_run "$F_NOTARGET"

  # 11-6. base ref を解決できない木は fail-closed（クリアにしない）
  F_NOBASE="$TMP/refs-no-base"
  refs_fixture_prepare "$F_NOBASE"
  printf '%s\n' 'baseline' > "$F_NOBASE/plugins/ff-dev-toolkit/doc.md"
  refs_fixture_commit "$F_NOBASE"
  git -C "$F_NOBASE" update-ref -d refs/remotes/origin/develop
  printf '%s\n' "detail: Issue ${HASH}123 を参照" >> "$F_NOBASE/plugins/ff-dev-toolkit/doc.md"
  expect_refs_rc "base ref を解決できない木は fail-closed で止まる" 2 \
    "base ref を解決できません" refs_run "$F_NOBASE"

  # 11-7. fence が閉じていないファイル（意図的な fixture が実在する）でも諦めない。
  # 閉じない fence は「以降が走査対象外」= fail-open なので、閉じられなかった開始行を
  # 潰して走査し直す
  F_FENCE="$TMP/refs-unclosed-fence"
  refs_fixture_prepare "$F_FENCE"
  printf '%s\n' 'intro' '```' 'unclosed body' > "$F_FENCE/plugins/ff-dev-toolkit/doc.md"
  refs_fixture_commit "$F_FENCE"
  printf '%s\n' "detail: Issue ${HASH}123 を参照" >> "$F_FENCE/plugins/ff-dev-toolkit/doc.md"
  expect_refs_rc "fence が閉じていないファイルの追加行も検出する" 1 \
    "plugins/ff-dev-toolkit/doc.md:4" refs_run "$F_FENCE"

  # 11-8. 11-7 の対。同じファイルに未閉 fence があっても、**正しく閉じた fence の
  # 内側**の追加行は通す。潰す対象を「閉じられなかった開始行だけ」に絞らず fence
  # 記号行を一律に潰すと、この 3 行目が違反になる（fixture を持つ現役 suite へ
  # ケースを足す将来の PR が誤って赤くなる）。
  F_FENCE_MIX="$TMP/refs-fence-mixed"
  refs_fixture_prepare "$F_FENCE_MIX"
  printf '%s\n' 'intro' > "$F_FENCE_MIX/plugins/ff-dev-toolkit/doc.md"
  refs_fixture_commit "$F_FENCE_MIX"
  {
    printf '%s\n' '```'                                  # 2: 閉じる fence の開始
    printf '%s\n' "閉じた fence の内側: ${HASH}123"        # 3: 通す
    printf '%s\n' '```'                                  # 4: 閉じる
    printf '%s\n' '~~~'                                  # 5: 閉じない fence の開始
    printf '%s\n' "未閉 fence の後: Issue ${HASH}456"      # 6: 検出する
  } >> "$F_FENCE_MIX/plugins/ff-dev-toolkit/doc.md"
  expect_refs_only "未閉 fence の後は検出し、閉じた fence の内側は通す" 1 \
    "plugins/ff-dev-toolkit/doc.md:6" "plugins/ff-dev-toolkit/doc.md:3" \
    refs_run "$F_FENCE_MIX"

  # 11-9. 未追跡の新規ファイルは差分に出ない。ファイル全体が新規＝全行が追加行なので
  # 全行を走査する（新規 suite のヘッダが再発源なので、ここを素通しにしない）。
  F_UNTRACKED="$TMP/refs-untracked"
  refs_fixture_prepare "$F_UNTRACKED"
  printf '%s\n' 'baseline' > "$F_UNTRACKED/plugins/ff-dev-toolkit/doc.md"
  refs_fixture_commit "$F_UNTRACKED"
  printf '%s\n' "新規ファイルの見出し: Issue ${HASH}777" \
    > "$F_UNTRACKED/plugins/ff-dev-toolkit/new.md"
  expect_refs_rc "未追跡の新規ファイルも全行を追加行として検出する" 1 \
    "plugins/ff-dev-toolkit/new.md:1" refs_run "$F_UNTRACKED"

  # 11-10. 11-9 の対。未追跡ファイルでも許可規則は同じで、走査したことが件数に出る
  # （0 件走査の緑と本物の通過を見分ける）。
  F_UNTRACKED_OK="$TMP/refs-untracked-clean"
  refs_fixture_prepare "$F_UNTRACKED_OK"
  printf '%s\n' 'baseline' > "$F_UNTRACKED_OK/plugins/ff-dev-toolkit/doc.md"
  refs_fixture_commit "$F_UNTRACKED_OK"
  printf '%s\n' "新規ファイル: inline code の \`${HASH}777\` は通す" \
    > "$F_UNTRACKED_OK/plugins/ff-dev-toolkit/new.md"
  expect_refs_rc "未追跡の新規ファイルを走査した件数がクリア表示に出る" 0 \
    "未追跡 1 ファイル" refs_run "$F_UNTRACKED_OK"

  # 11-11. 変異: 走査器を「許可規則を持たない素朴な全件検出」へ差し替えると、
  # 11-4 と同じ木が赤になる（許可規則が走査器側にあり、検査側が複製していない実測）。
  # 許可規則は inline code / markdown リンク / fence の 3 つあるので、行番号を
  # すべて名指しして「どれか 1 行が当たれば緑」にしない
  M_ALLOW="$TMP/refs-mutate-allow"
  cp -R "$F_ALLOWED" "$M_ALLOW"
  {
    printf '%s\n' '#!/usr/bin/env bash'
    printf '%s\n' '# 変異: fence / inline code / リンクを見ない素朴な走査'
    printf 'hits="$(LC_ALL=C grep -n -E "%s[0-9]+" -)" || exit 0\n' "$HASH"
    printf '%s\n' 'printf "%s\n" "$hits" | LC_ALL=C sed "s/$/:ref/"'
    printf '%s\n' 'exit 1'
  } > "$M_ALLOW/scripts/scan-bare-issue-refs.sh"
  # 3=inline code / 4=markdown リンク / 6=fence の内側（2=公開 URL 形式は番号短縮形を
  # 含まないので素朴な走査でも当たらない）
  expect_refs_all "許可規則を外すと inline code / リンク / fence の追加行が行ごとに赤になる（変異）" 1 \
    'plugins/ff-dev-toolkit/doc.md:3
plugins/ff-dev-toolkit/doc.md:4
plugins/ff-dev-toolkit/doc.md:6' refs_run "$M_ALLOW"

  # 11-12. 変異: 差分限定を外す（文脈行数を無限大にして全行を追加行扱いにする）と、
  # 11-3 の「既存行にだけ同型がある木」が赤になる
  M_DIFF="$TMP/refs-mutate-diff"
  cp -R "$F_EXISTING" "$M_DIFF"
  LC_ALL=C sed 's/--unified=0/--unified=1000000/' \
    "$F_EXISTING/scripts/check-added-bare-refs.sh" > "$M_DIFF/scripts/check-added-bare-refs.sh"
  expect_refs_rc "差分限定を外すと既存行の同型で赤になる（変異）" 1 \
    "plugins/ff-dev-toolkit/doc.md:1" refs_run "$M_DIFF"

  # 11-13. 変異: fence 不整合時の再走査を外すと、11-7 が検出ではなく走査不成立になる
  # （素通し = クリアにはならないことも同時に固定する）
  M_FENCE="$TMP/refs-mutate-fence"
  cp -R "$F_FENCE" "$M_FENCE"
  LC_ALL=C sed 's/2) ;;/99) ;;/' \
    "$F_FENCE/scripts/check-added-bare-refs.sh" > "$M_FENCE/scripts/check-added-bare-refs.sh"
  expect_refs_rc "fence 不整合時の再走査を外すと走査不成立で止まる（変異）" 2 \
    "走査が成立しませんでした" refs_run "$M_FENCE"

  # 11-14. 変異: 走査器が「閉じられなかった開始行」を名指ししなくなると、潰す行を
  # 決められず再走査が前進しない。素通しではなく走査不成立で止まることを固定する
  M_NOLINE="$TMP/refs-mutate-no-lineno"
  cp -R "$F_FENCE_MIX" "$M_NOLINE"
  LC_ALL=C sed 's/unclosed-fence:%d:/unclosed-fence:1:/' \
    "$F_FENCE_MIX/scripts/scan-bare-issue-refs.sh" > "$M_NOLINE/scripts/scan-bare-issue-refs.sh"
  expect_refs_rc "未閉 fence の開始行が名指しされないと走査不成立で止まる（変異）" 2 \
    "走査が成立しませんでした" refs_run "$M_NOLINE"

  # 11-15. 変異: 走査器が「1 件以上検出」を意味する rc=1 を出力なしで返す（起動自体の
  # 失敗など）と、ヒット 0 件として通さず走査不成立で止まる
  M_EMPTY="$TMP/refs-mutate-empty-hit"
  cp -R "$F_DETECT" "$M_EMPTY"
  {
    printf '%s\n' '#!/usr/bin/env bash'
    printf '%s\n' '# 変異: 契約を満たさない走査器（出力なしで rc=1）'
    printf '%s\n' 'cat >/dev/null'
    printf '%s\n' 'exit 1'
  } > "$M_EMPTY/scripts/scan-bare-issue-refs.sh"
  expect_refs_rc "出力なしの rc=1 はヒット 0 件にせず走査不成立で止まる（変異）" 2 \
    "走査が成立しませんでした" refs_run "$M_EMPTY"

  # 11-16. 外部 diff ドライバが設定された環境でも成立する。自前のハンクヘッダが
  # 出ない差分では追加行が空になり、**診断なしで全ファイル素通し**になるため
  refs_run_extdiff() { GIT_EXTERNAL_DIFF=/usr/bin/true bash "$1/scripts/check-added-bare-refs.sh"; }
  expect_refs_rc "外部 diff ドライバ下でも追加行を取り違えず検出する" 1 \
    "plugins/ff-dev-toolkit/doc.md:2" refs_run_extdiff "$F_DETECT"

  # 11-17. live: この作業ツリーの追加行がクリアであること（ゲート本体）。
  # rc=2（検査不成立）を skip へ降格しない — 唯一の常設呼び出し側でそれをやると、
  # origin/develop を持たない clone / worktree でゲートが一度も発火せずに緑になる
  set +e
  live_refs_out="$(bash "$ADDED_REFS" 2>&1)"
  live_refs_rc=$?
  set -e
  if [[ "$live_refs_rc" -eq 0 ]]; then
    ok "現在の作業ツリーの追加行に番号短縮形は無い（live）"
  elif [[ "$live_refs_rc" -eq 2 ]]; then
    bad "追加行の検査が成立しなかった（live / fail-closed）"
    printf '%s\n' "$live_refs_out" | sed 's/^/    | /' >&2
  else
    bad "現在の作業ツリーの追加行に番号短縮形がある（live）"
    printf '%s\n' "$live_refs_out" | sed 's/^/    | /' >&2
  fi
fi

# --- 12. 公開側から到達できない参照を止める（allowlist 側） -------------------
# 対象は scripts/scan-unreachable-repo-refs.sh と、それを呼ぶ 2 つの入口
# （同期前の全文検査 --check-only / 追加行限定の check-added-bare-refs.sh）。
# 見る形は 2 つ: `owner/repo#N`（owner を問わず全件）と、SSOT の org 配下の URL
# （`https://github.com/<org>/<repo>/...` と SCP 形 `git@github.com:<org>/<repo>.git`）。
# 後者は 12-17 以降で固定する — owner を問わない allowlist は成立しないため、
# 判定対象を org へ絞って外部 owner と GitHub の自前パスには触れない。ホスト名の
# 大小文字違いと明示ポート（`https://GitHub.com/...` / `github.com:443/...`）は
# 同じ URL なので同じ規則で見る（書き方を変えるだけの回避形を作らない）。
#
# 11 との違いは**許可規則の向き**にある。11（bare `#N`）は「ミラー先の文脈で
# GitHub がリンク化するか」が論点なので fence / inline code / リンクの中を除外する。
# 12（修飾形 `owner/repo#N`）は「非公開リポジトリの識別子が公開物へ出るか」が論点で、
# それは fence の中でも同じだけ出るため除外しない。11 の修正（bare → 修飾形）が
# 12 の違反を作る関係なので、片方だけでは往復が閉じない。
#
# 本ファイルは公開同期対象＝ 12 の検査対象そのものなので、**allowlist に無い
# owner/repo のリテラルを隣接して書かないこと**（fixture へは実行時に組み立てて流す）。
if [[ ! -f "$UNREACHABLE_SRC" ]]; then
  bad "到達不能参照の走査器が見つかりません"
else
  # 未登録の owner/repo を実行時に組み立てる（リテラルで置くと本ファイル自身が
  # 検査に当たる）。allowlist の owner とも例示 owner とも一致しない名前にする。
  UNLISTED="$(printf '%s-%s/%s' 'unlisted' 'org' 'internal-project')"

  # 12-1. 走査器の self-test（走査規則そのものの検出力。ゲート側の配線とは別に固定する）
  scanner_rc=0
  scanner_out="$(bash "$UNREACHABLE_SRC" --self-test 2>&1)" || scanner_rc=$?
  if [[ "$scanner_rc" -eq 0 ]]; then
    ok "到達不能参照の走査器の self-test が通る"
  else
    bad "到達不能参照の走査器の self-test が失敗した (rc=${scanner_rc})"
    printf '%s\n' "$scanner_out" | sed 's/^/    | /' >&2
  fi

  # 12-2. 同期前の全文検査が、未登録の owner/repo を file:line で名指しして止める
  # （AC: denylist に載っていない非公開リポジトリ名でも非 0 になること）
  U_HIT="$TMP/unreachable-hit"
  mkdir -p "$U_HIT"
  printf '%s\n' "詳細は ${UNLISTED}${HASH}2640 を参照。" > "$U_HIT/doc.md"
  expect_hit_reason "未登録の owner/repo を file:line で名指しして止める" \
    "doc.md:1" "到達できない" run_check --scan-dir "$U_HIT"

  # 12-3. 12-2 の対。allowlist 掲載の公開リポジトリ・例示 owner・URL 内のアンカーは
  # 通す（止める側だけを固定すると、許可側が違反側へ滑っても緑のまま通る）
  U_OK="$TMP/unreachable-ok"
  mkdir -p "$U_OK"
  {
    printf '%s\n' "公開ミラー自身への参照 feel-flow/ff-dev-toolkit${HASH}55 は通す。"
    printf '%s\n' "例示 owner の owner/repo${HASH}1 は通す。"
    printf '%s\n' "URL 内のアンカー https://github.com/feel-flow/ff-dev-toolkit/blob/HEAD/CHANGELOG.md${HASH}0440 は参照ではない。"
    printf '%s\n' "パスの途中 a/b/c${HASH}9 は参照として数えない。"
  } > "$U_OK/doc.md"
  expect_clear "allowlist 掲載・例示 owner・URL アンカー・パス途中は通す" \
    run_check --scan-dir "$U_OK"

  # 12-4. fence / inline code の中でも止める（11 との許可規則の非対称を実測する。
  # ここを 11 と同じ規則にすると、コードブロックへ書いた非公開識別子が素通りする）
  U_FENCE="$TMP/unreachable-fence"
  mkdir -p "$U_FENCE"
  {
    printf '%s\n' '```'
    printf '%s\n' "${UNLISTED}${HASH}7"
    printf '%s\n' '```'
    printf '%s\n' "inline code の \`${UNLISTED}${HASH}8\` も止める。"
  } > "$U_FENCE/doc.md"
  expect_hit "fence / inline code の中の未登録参照も止める" "doc.md:2" \
    run_check --scan-dir "$U_FENCE"
  expect_hit "inline code の中の未登録参照も止める" "doc.md:4" \
    run_check --scan-dir "$U_FENCE"

  # 12-5. 変異: allowlist から掲載リポジトリを外したコピーだけが 12-3 を赤にする
  # （allowlist が実際に読まれていることの実測。本 suite は allowlist を複製しない）
  M_ALLOWLIST="$TMP/unreachable-mutate-repo"
  mkdir -p "$M_ALLOWLIST/scripts"
  LC_ALL=C sed "/^  'feel-flow\/ff-dev-toolkit'\$/d" "$SYNC" \
    > "$M_ALLOWLIST/scripts/sync-dev-toolkit-to-public.sh"
  cp "$UNREACHABLE_SRC" "$M_ALLOWLIST/scripts/scan-unreachable-repo-refs.sh"
  expect_hit "allowlist から掲載リポジトリを外すと通っていた参照が赤になる（変異）" \
    "doc.md:1" bash "$M_ALLOWLIST/scripts/sync-dev-toolkit-to-public.sh" \
    --check-only --scan-dir "$U_OK"

  # 12-6. 12-5 の対。例示 owner の許可も同じ allowlist から来ている
  M_OWNER="$TMP/unreachable-mutate-owner"
  mkdir -p "$M_OWNER/scripts"
  LC_ALL=C sed "/^  'owner'\$/d" "$SYNC" \
    > "$M_OWNER/scripts/sync-dev-toolkit-to-public.sh"
  cp "$UNREACHABLE_SRC" "$M_OWNER/scripts/scan-unreachable-repo-refs.sh"
  expect_hit "例示 owner を外すと fixture の例示参照が赤になる（変異）" \
    "doc.md:2" bash "$M_OWNER/scripts/sync-dev-toolkit-to-public.sh" \
    --check-only --scan-dir "$U_OK"

  # 12-7. 走査器が無い checkout は素通しにしない（fail-closed）。
  # 「走査器が消えても検査はクリアを出す」状態は、ゲートが 1 件も発火しないまま
  # 規約が守られているように見える本 Issue の欠陥そのもの
  M_NOSCAN="$TMP/unreachable-no-scanner"
  mkdir -p "$M_NOSCAN/scripts"
  cp "$SYNC" "$M_NOSCAN/scripts/sync-dev-toolkit-to-public.sh"
  expect_fail "走査器が無いと素通しにせず止まる（fail-closed）" "走査器が見つかりません" \
    bash "$M_NOSCAN/scripts/sync-dev-toolkit-to-public.sh" --check-only --scan-dir "$U_OK"

  # 12-8. 追加行限定の入口でも同じ規則が効く。既存行の同型は通し、追加行だけ止める
  # （全文検査と差分限定の 2 入口があり、後者だけ規則が抜ける経路を作らない）
  F_UNREACH="$TMP/refs-unreachable"
  refs_fixture_prepare "$F_UNREACH"
  printf '%s\n' "既存行: ${UNLISTED}${HASH}1" 'baseline' \
    > "$F_UNREACH/plugins/ff-dev-toolkit/doc.md"
  refs_fixture_commit "$F_UNREACH"
  printf '%s\n' "追加行: ${UNLISTED}${HASH}2" >> "$F_UNREACH/plugins/ff-dev-toolkit/doc.md"
  expect_refs_only "追加行の未登録参照だけを止め、既存行の同型は通す" 1 \
    "plugins/ff-dev-toolkit/doc.md:3" "plugins/ff-dev-toolkit/doc.md:1" \
    refs_run "$F_UNREACH"

  # 12-9. 追加行限定の入口で allowlist を取得できないときは fail-closed。
  # 空の allowlist で通すと、全参照が許可された状態と区別が付かない
  M_NOALLOW="$TMP/refs-empty-allowlist"
  cp -R "$F_UNREACH" "$M_NOALLOW"
  LC_ALL=C sed 's/^      emit_reachable_allowlist; exit 0 ;;$/      exit 0 ;;/' \
    "$F_UNREACH/scripts/sync-dev-toolkit-to-public.sh" \
    > "$M_NOALLOW/scripts/sync-dev-toolkit-to-public.sh"
  expect_refs_rc "allowlist が空なら追加行の検査も fail-closed で止まる（変異）" 2 \
    "allowlist が空です" refs_run "$M_NOALLOW"

  # 12-11. 診断のパス短縮は正規表現ではなくリテラル一致で行う。走査 root の絶対パスに
  # 正規表現メタ文字（+ 等）が含まれると、regex 剥がしでは前方一致が外れて開発機の
  # 絶対パスがそのまま診断へ出る（他の診断はリテラル置換なので、ここだけ規則が違うと
  # 出力が環境依存で揺れる）。メタ文字入りの root で相対パスになることを固定する。
  U_META="$TMP/meta+dir"
  mkdir -p "$U_META"
  printf '%s\n' "詳細は ${UNLISTED}${HASH}2640 を参照。" > "$U_META/doc.md"
  expect_hit_reason "走査 root に正規表現メタ文字があっても診断は相対パスで出す" \
    "  doc.md:1:" "到達できない" run_check --scan-dir "$U_META"
  # 針は検査側と同じ正規化を通したパスで作る。mktemp の /var/... は検査側で
  # /private/var/... へ解決されるため、正規化前の値で照合すると絶対パスが漏れていても
  # 一致せず、変異下でも緑のまま通る（この対で実測して確かめてある）。
  U_META_REAL="$(cd "$U_META" && pwd)"
  meta_out="$(run_check --scan-dir "$U_META" 2>&1 || true)"
  case "$meta_out" in
    *"$U_META_REAL/doc.md"*) bad "診断に走査 root の絶対パスが漏れている（メタ文字入り root）"
      printf '%s\n' "$meta_out" | sed 's/^/    | /' >&2 ;;
    *) ok "メタ文字入り root でも絶対パスを診断へ漏らさない" ;;
  esac

  # 12-12. 相対パス + 番号アンカー（`docs/RUNBOOK.md#404`）は参照ではない。
  # 参照と同じ形をしているため、切り分けを外すと公開対象に既にある `path/file.md#断片`
  # 形（実測 161 件）の番号版が出た瞬間に、「RUNBOOK.md を REACHABLE_REPOS へ足せ」
  # という誤った案内で同期が止まる
  U_ANCHOR="$TMP/unreachable-anchor"
  mkdir -p "$U_ANCHOR"
  {
    printf '%s\n' "ops/RUNBOOK.md${HASH}404 は参照ではない"
    printf '%s\n' "[details](guide/setup.md${HASH}123) も参照ではない"
    printf '%s\n' "theme/dark.css${HASH}1 も参照ではない"
    printf '%s\n' "2026/12${HASH}1 のような日付断片も参照ではない"
  } > "$U_ANCHOR/doc.md"
  expect_clear "相対パス + 番号アンカー・日付断片は参照として数えない" \
    run_check --scan-dir "$U_ANCHOR"

  # 12-13. URL 除去が日本語の直後で止まること。除外文字の否定クラスで書くと
  # 「…/issues/46）。」の全角句読点を URL の一部として飲み込み、その後ろにある
  # 本物の参照ごと消える（検出 0 件の緑になる = fail-open）
  U_CJK="$TMP/unreachable-cjk"
  mkdir -p "$U_CJK"
  printf '%s\n' "詳細は https://github.com/feel-flow/ff-dev-toolkit/issues/46）。${UNLISTED}${HASH}3 も参照。" \
    > "$U_CJK/doc.md"
  expect_hit "URL の直後が全角文字でも、その先の未登録参照を飲み込まない" "doc.md:1" \
    run_check --scan-dir "$U_CJK"

  # 12-14. 内容が無害でも、ファイル名に未登録参照があれば止める
  # （denylist 側は内容とファイル名の両方を見ており、こちらだけ内容限定だと
  # 「無害な本文 + 未登録参照を含むファイル名」が両ゲートを通る）
  U_NAME="$TMP/unreachable-name"
  mkdir -p "$U_NAME"
  printf '%s\n' 'harmless content' > "$U_NAME/notes-${UNLISTED##*/}${HASH}12.md"
  printf '%s\n' 'harmless content' > "$U_NAME/ok.md"
  name_probe="$TMP/unreachable-name-probe"
  mkdir -p "$name_probe/${UNLISTED%%/*}"
  printf '%s\n' 'harmless content' > "$name_probe/${UNLISTED%%/*}/${UNLISTED##*/}${HASH}12.md"
  expect_hit_reason "本文が無害でもファイル名の未登録参照で止める" \
    "ファイル名" "到達できない" run_check --scan-dir "$name_probe"

  # 12-15. ヒットが多くても exit 1 の契約と案内文を保つ。打ち切りを
  # `awk ... | head -10` で書くと head が先に閉じて awk が SIGPIPE で死に、
  # pipefail + errexit が exit 141 させて案内文へ到達しない
  U_MANY="$TMP/unreachable-many"
  mkdir -p "$U_MANY"
  awk -v n=4000 -v ref="${UNLISTED}${HASH}" 'BEGIN { for (i = 1; i <= n; i++) printf "line %d: %s%d\n", i, ref, i }' \
    > "$U_MANY/doc.md"
  expect_refs_rc "ヒットが数千件でも exit 1 と案内文を保つ（SIGPIPE で 141 にしない）" 1 \
    "REACHABLE_REPOS へ足し" run_check --scan-dir "$U_MANY"

  # 12-16. 追加行限定の入口でも、走査器が契約を満たさない rc=1（出力なし）を
  # ヒット 0 件として通さない（bare 参照側と同じ扱い。片方だけ緩いと素通し経路になる）
  M_EMPTYHIT="$TMP/refs-unreachable-empty-hit"
  cp -R "$F_UNREACH" "$M_EMPTYHIT"
  {
    printf '%s\n' '#!/usr/bin/env bash'
    printf '%s\n' '# 変異: 契約を満たさない走査器（出力なしで rc=1）'
    printf '%s\n' 'exit 1'
  } > "$M_EMPTYHIT/scripts/scan-unreachable-repo-refs.sh"
  expect_refs_rc "到達不能参照の走査器が出力なしの rc=1 を返したら走査不成立で止まる（変異）" 2 \
    "走査が成立しませんでした" refs_run "$M_EMPTYHIT"

  # 12-17〜12-22. URL 形（org スコープ）。`owner/repo#N` と同じ allowlist を、
  # SSOT の org 配下の `https://github.com/<org>/<repo>/...` と SCP 形
  # `git@github.com:<org>/<repo>.git` にも掛ける。owner を問わない allowlist は
  # 成立しない（公開対象には外部の公開リポジトリ URL と、github.com/sponsors/... の
  # ようにリポジトリですらないパスが多数ある）ので、判定対象を org へ絞ることで
  # 誤検出を出さずに未登録名だけを止める。
  #
  # org スコープの未登録名を実行時に組み立てる（本ファイルは検査対象そのもので、
  # リテラルで置くと live 検査に当たる）。
  SCOPED_UNLISTED="$(printf '%s-%s/%s' 'feel' 'flow' 'internal-only')"

  # 12-17. 未登録の org スコープ URL を file:line で名指しして止める
  # （AC: denylist に載っていない非公開リポジトリの URL でも非 0 になること）
  U_URL_HIT="$TMP/unreachable-url-hit"
  mkdir -p "$U_URL_HIT"
  {
    printf '%s\n' "詳細は https://github.com/${SCOPED_UNLISTED}/issues/1 を参照。"
    printf '%s\n' "clone は git@github.com:${SCOPED_UNLISTED}.git"
    # 同じ URL の別表記。取り逃がすと「書き方を変えるだけで検査を抜けられる」
    # 回避形になる（ホスト名は大小文字を区別せず、明示ポートは権威部の一部）
    printf '%s\n' "大小文字違いの https://GitHub.com/${SCOPED_UNLISTED}/issues/2 も同じ URL。"
    printf '%s\n' "明示ポートの https://github.com:443/${SCOPED_UNLISTED}/issues/3 も同じ URL。"
  } > "$U_URL_HIT/doc.md"
  expect_hit_reason "org スコープの未登録 URL を file:line で名指しして止める" \
    "doc.md:1" "到達できない" run_check --scan-dir "$U_URL_HIT"
  expect_hit "SCP 形（git@github.com:org/repo.git）も同じ規則で止める" "doc.md:2" \
    run_check --scan-dir "$U_URL_HIT"
  expect_hit "ホスト名の大小文字違い（GitHub.com）も同じ規則で止める" "doc.md:3" \
    run_check --scan-dir "$U_URL_HIT"
  expect_hit "明示ポート（github.com:443）をポート番号ごと org と読み違えず止める" "doc.md:4" \
    run_check --scan-dir "$U_URL_HIT"

  # 12-18. 12-17 の対。外部 owner の公開リポジトリ URL・リポジトリでない GitHub の
  # 自前パス・サブドメイン・org ページは 1 件も誤検出しない（AC の 2 項目め）。
  # 止める側だけを固定すると、org スコープが外部 owner へ広がっても緑のまま通る
  U_URL_OK="$TMP/unreachable-url-ok"
  mkdir -p "$U_URL_OK"
  {
    printf '%s\n' "公開ミラー自身の https://github.com/feel-flow/ff-dev-toolkit/issues/1 は通す。"
    printf '%s\n' "clone URL の https://github.com/feel-flow/ff-dev-toolkit.git も通す。"
    printf '%s\n' "SCP 形の git@github.com:feel-flow/ff-dev-toolkit.git も通す。"
    printf '%s\n' "外部 owner の https://github.com/mikefarah/yq には触らない。"
    printf '%s\n' "リポジトリでないパス https://github.com/sponsors/wooorm にも触らない。"
    printf '%s\n' "設定ページ https://github.com/settings/copilot にも触らない。"
    printf '%s\n' "サブドメイン https://docs.github.com/ja/actions にも触らない。"
    printf '%s\n' "org ページ https://github.com/feel-flow は repo を持たない。"
    printf '%s\n' "大小文字違いでも許可名は通す https://GitHub.com/Feel-Flow/FF-Dev-Toolkit。"
    printf '%s\n' "大小文字違いのサブドメイン https://Docs.GitHub.com/ja/actions にも触らない。"
    printf '%s\n' "大小文字違いの外部 owner https://GitHub.com/MikeFarah/yq にも触らない。"
    printf '%s\n' "明示ポート付きの許可名 https://github.com:443/feel-flow/ff-dev-toolkit も通す。"
  } > "$U_URL_OK/doc.md"
  expect_clear "外部 owner・非リポジトリパス・サブドメイン・org ページは誤検出しない（大小文字違い・明示ポートを含む）" \
    run_check --scan-dir "$U_URL_OK"

  # 12-19. 変異: allowlist から掲載リポジトリを外したコピーだけが 12-18 を赤にする
  # （URL 形の判定も同じ allowlist を読んでいることの実測。`.git` 付き・SCP 形も
  # 同じ名前へ正規化されるので、同じ 1 行の削除で 3 形すべてが赤になる）
  M_URL_REPO="$TMP/unreachable-url-mutate-repo"
  mkdir -p "$M_URL_REPO/scripts"
  LC_ALL=C sed "/^  'feel-flow\/ff-dev-toolkit'\$/d" "$SYNC" \
    > "$M_URL_REPO/scripts/sync-dev-toolkit-to-public.sh"
  cp "$UNREACHABLE_SRC" "$M_URL_REPO/scripts/scan-unreachable-repo-refs.sh"
  expect_hit "allowlist から掲載リポジトリを外すと通っていた URL が赤になる（変異）" \
    "doc.md:1" bash "$M_URL_REPO/scripts/sync-dev-toolkit-to-public.sh" \
    --check-only --scan-dir "$U_URL_OK"
  expect_hit "同じ変異で clone URL（.git）も赤になる（変異）" \
    "doc.md:2" bash "$M_URL_REPO/scripts/sync-dev-toolkit-to-public.sh" \
    --check-only --scan-dir "$U_URL_OK"
  expect_hit "同じ変異で SCP 形も赤になる（変異。3 形すべてが同じ 1 行に依っている）" \
    "doc.md:3" bash "$M_URL_REPO/scripts/sync-dev-toolkit-to-public.sh" \
    --check-only --scan-dir "$U_URL_OK"

  # 12-20. 変異: 判定対象 org を外すと、URL 形の検査は「対象 0 件で何も見ない」に
  # なる。これを通すと「検査が存在しない」と「違反が無い」が区別できないので
  # fail-closed（配線を外したら赤くなること）
  M_URL_ORG="$TMP/unreachable-url-mutate-org"
  mkdir -p "$M_URL_ORG/scripts"
  LC_ALL=C sed "/^  'feel-flow'\$/d" "$SYNC" \
    > "$M_URL_ORG/scripts/sync-dev-toolkit-to-public.sh"
  cp "$UNREACHABLE_SRC" "$M_URL_ORG/scripts/scan-unreachable-repo-refs.sh"
  expect_fail "判定対象 org を空にすると fail-closed で止まる（変異）" "org 行がありません" \
    bash "$M_URL_ORG/scripts/sync-dev-toolkit-to-public.sh" --check-only --scan-dir "$U_URL_OK"

  # 12-21. 追加行限定の入口でも URL 形の規則が効く。既存行の同型は通し、追加行だけ止める
  # （全文検査と差分限定の 2 入口があり、後者だけ規則が抜ける経路を作らない）
  F_URL="$TMP/refs-url"
  refs_fixture_prepare "$F_URL"
  printf '%s\n' "既存行: https://github.com/${SCOPED_UNLISTED}/issues/1" 'baseline' \
    > "$F_URL/plugins/ff-dev-toolkit/doc.md"
  refs_fixture_commit "$F_URL"
  printf '%s\n' "追加行: https://github.com/${SCOPED_UNLISTED}/issues/2" \
    >> "$F_URL/plugins/ff-dev-toolkit/doc.md"
  expect_refs_only "追加行の org スコープ URL だけを止め、既存行の同型は通す" 1 \
    "plugins/ff-dev-toolkit/doc.md:3" "plugins/ff-dev-toolkit/doc.md:1" \
    refs_run "$F_URL"

  # 12-23. 変異: org 行の値が owner 名の形を外れる（末尾空白）と、org 行の件数は
  # 1 件のままなのに orgs のキーが実在の org と一致しなくなり、URL 形の検査が
  # 「判定対象があるのに何も止めない」状態になる。件数だけでは検出できないので
  # 値の形まで見て fail-closed にすること（12-20 の件数ゲートの穴）
  M_URL_ORGFMT="$TMP/unreachable-url-mutate-orgfmt"
  mkdir -p "$M_URL_ORGFMT/scripts"
  LC_ALL=C sed "s|^  'feel-flow'\$|  'feel-flow '|" "$SYNC" \
    > "$M_URL_ORGFMT/scripts/sync-dev-toolkit-to-public.sh"
  cp "$UNREACHABLE_SRC" "$M_URL_ORGFMT/scripts/scan-unreachable-repo-refs.sh"
  expect_fail "org 行の値が owner 名の形を外れると fail-closed で止まる（変異）" "書式が違います" \
    bash "$M_URL_ORGFMT/scripts/sync-dev-toolkit-to-public.sh" --check-only --scan-dir "$U_URL_OK"

  # 12-22. 走査器の self-test が URL 形の許可・禁止も固定していること（走査規則
  # そのものの検出力。ゲート側の配線とは別に走査器側でも対を持つ）
  selftest_out="$(bash "$UNREACHABLE_SRC" --self-test 2>&1)" || true
  case "$selftest_out" in
    *"org スコープの URL / SCP 形だけを止め"*) ok "走査器の self-test が URL 形の対を固定している" ;;
    *) bad "走査器の self-test に URL 形の対が無い"
       printf '%s\n' "$selftest_out" | sed 's/^/    | /' >&2 ;;
  esac

  # 12-10. live: この作業ツリーの公開対象に未登録の owner/repo が無いこと。
  # 12-2〜12-9 は隔離 fixture の検査で、ゲート本体が現ツリーへ当たっているかは別
  expect_clear "現在の公開対象作業ツリーに未登録の owner/repo は無い（live）" run_check
fi

# --- 13. 本番プロンプト資産（scripts/perspectives/）の code fence 整合 ---------
# 観点プロンプトは multi-agent.sh が CLI へそのまま渡す本番資産であり、公開ミラー
# 対象でもある。ここで fence が閉じないと実害が 2 つ出る:
#   - Markdown として読むと、閉じなかった開始行以降が丸ごとコードブロックへ化け、
#     意図した節区切りが読み手にも CLI にも伝わらない
#   - fence 境界を追う走査器 scripts/scan-bare-issue-refs.sh が rc=2（走査不成立）を
#     返す。呼び出し側 scripts/check-added-bare-refs.sh は開始行を潰して再走査する
#     回復経路を持つが、潰した行の内側は本来の fence 判定と意味が変わる。本番資産の
#     記述ミスのためにその回復経路を常用させない
# 対象は scripts/perspectives/ 配下の Markdown に**限定**する。tests/ 配下の
# fixtures と heredoc で fixture を組み立てる verify.sh には**意図的な**未閉 fence が
# 実在し（走査器が fail-closed であること自体を固定する資産）、それらは直さない。
# 入れ子を書きたい場合の正しい形は「外側のフェンス文字数を増やす」（4 連 backtick で
# 3 連を囲む）。閉じフェンスを足すだけの修正はブロックの範囲が変わるので不可。
FENCE_SCANNER="$REPO_ROOT/scripts/scan-bare-issue-refs.sh"
PERSPECTIVES_REL="plugins/ff-dev-toolkit/scripts/perspectives"

fence_scan_rc() { # $1=ファイル -> 走査器の rc を stdout へ（2 = 走査不成立）
  local rc=0
  bash "$FENCE_SCANNER" < "$1" >/dev/null 2>&1 || rc=$?
  printf '%s\n' "$rc"
}

# 行が「閉じフェンスになりうる行」（字下げ 3 まで・同記号 3 連以上・後続は空白のみ）
# かを見て、最後の 1 件の行番号を返す。awk の繰り返し区間 {n,m} は環境差があるため
# 使わず、先頭空白の剥がしと連長の数え上げで判定する。
last_closing_fence_line() { # $1=ファイル -> 行番号（無ければ空）
  awk '
    {
      line = $0
      sub(/\r$/, "", line)
      ind = 0
      while (ind < 3 && substr(line, 1, 1) == " ") { line = substr(line, 2); ind++ }
      c = substr(line, 1, 1)
      if (c != "`" && c != "~") next
      n = 0
      while (substr(line, n + 1, 1) == c) n++
      if (n < 3) next
      if (substr(line, n + 1) ~ /^[ \t]*$/) last = NR
    }
    END { if (last) print last }
  ' "$1"
}

if [[ ! -f "$FENCE_SCANNER" ]]; then
  bad "fence 境界を追う走査器が見つかりません: $FENCE_SCANNER"
elif [[ ! -d "$REPO_ROOT/$PERSPECTIVES_REL" ]]; then
  bad "観点プロンプトのディレクトリが見つかりません: $PERSPECTIVES_REL"
else
  PERSPECTIVE_FILES=()
  while IFS= read -r p; do
    [[ "$p" == *.md ]] || continue
    PERSPECTIVE_FILES+=("$p")
  done < <(git -C "$REPO_ROOT" ls-files -- "$PERSPECTIVES_REL")

  if [[ "${#PERSPECTIVE_FILES[@]}" -eq 0 ]]; then
    bad "観点プロンプトの Markdown が 0 件のため fence 検査が成立しません"
  else
    UNBALANCED=()
    for p in "${PERSPECTIVE_FILES[@]}"; do
      if [[ "$(fence_scan_rc "$REPO_ROOT/$p")" -eq 2 ]]; then
        UNBALANCED+=("$p")
      fi
    done
    if [[ "${#UNBALANCED[@]}" -eq 0 ]]; then
      ok "観点プロンプト ${#PERSPECTIVE_FILES[@]} 件の code fence が開閉している（走査器が rc=2 を返さない）"
    else
      bad "観点プロンプト ${#UNBALANCED[@]} 件の code fence が閉じていません（入れ子は外側のフェンス文字数を増やして書くこと）"
      printf '    | %s\n' "${UNBALANCED[@]}" >&2
    fi

    # 検出力の実測: 実ファイルの閉じフェンスを 1 つ削った写しが rc=2 になること。
    # これが赤くならないなら、上の緑は「検査が空振りしている」ことの証明にしかならない
    FENCE_MUT_SRC="$REPO_ROOT/${PERSPECTIVE_FILES[0]}"
    mut_line="$(last_closing_fence_line "$FENCE_MUT_SRC")"
    if [[ -z "$mut_line" ]]; then
      bad "変異注入の対象（閉じフェンス行）が無いため検出力を実測できません: ${PERSPECTIVE_FILES[0]}"
    else
      FENCE_MUT="$TMP/perspective-fence-mutant.md"
      awk -v n="$mut_line" 'NR != n' "$FENCE_MUT_SRC" > "$FENCE_MUT"
      if [[ "$(fence_scan_rc "$FENCE_MUT")" -eq 2 ]]; then
        ok "閉じフェンスを 1 つ削った写しは走査不成立（rc=2）になる（変異注入で検出力を実測）"
      else
        bad "閉じフェンスを 1 つ削っても rc=2 にならない（fence 検査が空振りしている）"
      fi
    fi
  fi
fi

echo
if [[ "$FAIL" -gt 0 ]]; then
  echo "✗ sync-forbidden-patterns verify: ${FAIL} 件 fail / ${PASS} 件 pass" >&2
  FF_REACHED_END=1
  exit 1
fi
echo "✓ sync-forbidden-patterns verify: 全 ${PASS} 件 pass"
FF_REACHED_END=1
exit 0
