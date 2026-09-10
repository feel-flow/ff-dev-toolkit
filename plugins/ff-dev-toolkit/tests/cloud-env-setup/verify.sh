#!/usr/bin/env bash
#
# cloud-env-setup: クラウド環境セットアップ（CI / クラウド開発環境の不足ツールとロケールを揃える）の挙動契約。
#
# 対象は 3 つ:
#   1. scripts/setup-cloud-env.sh（SSOT ルート）
#      - 導入できない項目があっても exit 0、各項目を `[setup] <記号> <項目>:` の 1 行で報告する
#      - --dry-run は apt-get / npm ci / git remote set-head を実行しない（何を試みるかだけ出す）
#      - Linux + root で gh / shellcheck が不在なら apt-get を試み、成否を 1 行で報告する。
#        macOS / 非 root / --skip-install では apt-get を呼ばず手動導入を案内する
#      - ロケール: 実効 LC_CTYPE が UTF-8 でなく `locale -a` に UTF-8 があれば `export LC_ALL=...`
#        行を提示（--print-env では stdout に export 行だけ）、無ければ ❌ の 1 行警告
#   2. tests/lib/utf8-locale.sh（run-all.sh / docs-gates / docs-gates-runtime が入口で呼ぶ）
#      - 実効 LC_CTYPE が UTF-8 なら何もしない / POSIX なら `locale -a` の UTF-8 を LC_ALL に export /
#        無ければ警告して続行
#   3. scripts/probe-env-capabilities.sh の env カテゴリ「ロケール」行（ok / warn / missing）と --json
#      （--json の構造検査だけ jq を要する。jq 不在ではその検査だけを部分 skip し、setup 本体と
#      utf8-locale.sh と probe の Markdown 表の検査は走らせる）
#
# apt-get / brew / npm / curl は stub に差し替え（FF_SETUP_* シーム）、gh の不在は必要最小限の実体だけを
# symlink した PATH で作る。実ネットワークにも実パッケージにも触れない。
#
# 使い方: bash plugins/ff-dev-toolkit/tests/cloud-env-setup/verify.sh
#
# run-all-required: no — SSOT リポジトリの root scripts/ を検査する suite。配布先 checkout に
# scripts/setup-cloud-env.sh は無く、その skip は正当な適用外（claude-hooks-path /
# public-dependabot-health / sync-sha-contract と同じ扱い）。jq 不在は suite 全体を落とさず
# probe --json の検査だけを部分 skip するので、この宣言が許しているのは適用外の skip だけ

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel 2>/dev/null || true)"
SETUP="${REPO_ROOT:+$REPO_ROOT/scripts/setup-cloud-env.sh}"
PROBE="${REPO_ROOT:+$REPO_ROOT/scripts/probe-env-capabilities.sh}"
LOCALE_LIB="$PLUGIN_ROOT/tests/lib/utf8-locale.sh"

if [ -z "$REPO_ROOT" ] || [ ! -f "$SETUP" ] || [ ! -f "$PROBE" ]; then
  echo "○ skip: scripts/setup-cloud-env.sh / scripts/probe-env-capabilities.sh が無いチェックアウトのためスキップ（本 suite は SSOT リポジトリ専用の検査です）"
  FF_REACHED_END=1
  exit 0
fi
# jq は probe の --json 構造検査にしか要らない。不在で suite ごと落とすと、setup 本体
# （exit 0 契約・分岐・quote）と utf8-locale.sh の検出力まで一緒に消える
HAVE_JQ=0
command -v jq >/dev/null 2>&1 && HAVE_JQ=1

if _ff_mktemp_out="$(mktemp -d "${TMPDIR:-/tmp}/ff-cloud-env-setup.XXXXXX" 2>&1)" && [ -d "$_ff_mktemp_out" ]; then
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
  if [ "$_ff_rc" -eq 0 ] && [ "$FF_REACHED_END" -ne 1 ]; then
    echo "✗ cloud-env-setup: 最後まで到達しませんでした（途中で中断）" >&2
    exit 1
  fi
  exit "$_ff_rc"
}
trap _ff_exit_guard EXIT

PASS=0
FAIL=0
ok()  { echo "  ✓ $1"; PASS=$((PASS + 1)); }
bad() { echo "  ✗ $1" >&2; FAIL=$((FAIL + 1)); }

echo "== cloud-env-setup: setup / utf8-locale / probe ロケール行 =="

# ---- fixture: 必要最小限の実体だけを持つ PATH（gh / shellcheck / yq / go / npm を含めない）------
BIN="$TMP/bin"
mkdir -p "$BIN"
MISSING=""
for tool in bash sh env git sed head tail cut tr grep cat dirname basename mktemp rm mkdir mv chmod wc sort awk uname date id ln; do
  if p="$(command -v "$tool" 2>/dev/null)" && [ -n "$p" ]; then
    ln -sf "$p" "$BIN/$tool"
  else
    MISSING="${MISSING} ${tool}"
  fi
done
if [ -n "$MISSING" ]; then
  echo "○ skip: fixture に要る実体が PATH に無い（${MISSING}）"
  FF_REACHED_END=1
  exit 0
fi
[ "$HAVE_JQ" -eq 1 ] && ln -sf "$(command -v jq)" "$BIN/jq"
for absent in gh shellcheck yq go npm rsync; do
  if PATH="$BIN" command -v "$absent" >/dev/null 2>&1; then
    bad "fixture: 絞った PATH に ${absent} が見える（不在の fixture が成立しない）"
  fi
done

# locale stub: LC_CTYPE=POSIX、`-a` の一覧は STUB_LOCALES で差し替える
LOCALE_STUB="$TMP/locale"
cat > "$LOCALE_STUB" <<'STUB'
#!/usr/bin/env bash
if [ "${1:-}" = "-a" ]; then printf '%b' "${STUB_LOCALES:-C\nPOSIX\n}"; else printf 'LANG=\nLC_CTYPE="%s"\n' "${STUB_CTYPE:-POSIX}"; fi
STUB
chmod +x "$LOCALE_STUB"

# apt-get stub: 呼ばれたら marker を作る。STUB_APT_INSTALLS が 1 なら BIN へ実体（空の実行ファイル）を置く
APT_STUB="$TMP/apt-get"
cat > "$APT_STUB" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${STUB_APT_LOG:?}"
if [ "${STUB_APT_INSTALLS:-0}" = 1 ]; then
  pkg="${*: -1}"
  printf '%s\n' '#!/usr/bin/env bash' 'exit 0' > "${STUB_APT_BIN:?}/$pkg"
  chmod +x "${STUB_APT_BIN:?}/$pkg"
  exit 0
fi
# 失敗の出方を切り替えるシーム。setup 側は apt の出力から「パッケージ不在」と
# 「ミラーへ到達できない」を分けて報告する契約（Issue #1427）で、その分岐を実測する。
case "${STUB_APT_FAIL_MODE:-missing}" in
  network)
    echo "E: Failed to fetch http://archive.ubuntu.com/ubuntu/pool/main/r/rsync.deb  Could not resolve 'archive.ubuntu.com'" >&2 ;;
  both)
    # 実際のミラー障害の出方。リストが空のままなので Unable to locate package も同時に出る
    echo "E: Failed to fetch http://archive.ubuntu.com/ubuntu/dists/noble/InRelease  Could not resolve 'archive.ubuntu.com'" >&2
    echo "E: Unable to locate package rsync" >&2 ;;
  *)
    echo "E: Unable to locate package" >&2 ;;
esac
exit 100
STUB
chmod +x "$APT_STUB"
# curl / npm stub: 呼ばれたら marker を作って失敗する。
# curl は STUB_CURL_YQ_VERSION が空でなければ -o 先へ「その版を名乗る yq」を書いて成功する
printf '%s\n' '#!/usr/bin/env bash' 'printf "%s\n" "$*" >> "${STUB_NET_LOG:?}"' 'exit 1' > "$TMP/npm"
cat > "$TMP/curl" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${STUB_NET_LOG:?}"
[ -n "${STUB_CURL_YQ_VERSION:-}" ] || exit 1
dest=""
while [ $# -gt 0 ]; do
  if [ "$1" = "-o" ]; then dest="$2"; fi
  shift
done
[ -n "$dest" ] || exit 1
printf '%s\n' '#!/usr/bin/env bash' "printf '%s\\n' \"\${STUB_YQ_VERSION_LINE:?}\"" > "$dest"
chmod +x "$dest"
exit 0
STUB
chmod +x "$TMP/curl"
for s in npm; do chmod +x "$TMP/$s"; done

# 被検体は fixture リポジトリ内で動かす（origin 無し / mcp 無し / toolkit 無し → 実リポジトリに触れない）
FX="$TMP/fx"
mkdir -p "$FX"
git -C "$FX" init -q

# run_setup <env...> -- <args...>: 絞った PATH + stub で setup を実行し、stdout / stderr / rc を保存。
# 実行ディレクトリは FXDIR（既定は origin を持たない FX）、HOME は FXHOME で差し替える
FXDIR="$FX"
FXHOME="$TMP"
RC=0
run_setup() {
  local -a envs=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --) shift; break ;;
      *) envs+=("$1"); shift ;;
    esac
  done
  : > "$TMP/apt.log"; : > "$TMP/net.log"
  RC=0
  (cd "$FXDIR" && env -i PATH="$BIN" HOME="$FXHOME" TMPDIR="$TMP" \
      FF_SETUP_LOCALE_CMD="$LOCALE_STUB" FF_SETUP_APT_GET="$APT_STUB" FF_SETUP_NPM="$TMP/npm" FF_SETUP_CURL="$TMP/curl" \
      STUB_APT_LOG="$TMP/apt.log" STUB_APT_BIN="$BIN" STUB_NET_LOG="$TMP/net.log" \
      ${envs[@]+"${envs[@]}"} bash "$SETUP" "$@") >"$TMP/stdout.log" 2>"$TMP/stderr.log" </dev/null || RC=$?
  cat "$TMP/stdout.log" "$TMP/stderr.log" > "$TMP/out.log"
}
out_has() { grep -qF -- "$1" "$TMP/out.log"; }
line_of() { grep -F -- "[setup] " "$TMP/out.log" | grep -F -- " $1:" | head -n 1; }
# パイプ下流の grep -q を置かない（run-all の静的走査が禁じる）。部分一致は case で判定する
line_has() { case "$(line_of "$1")" in *"$2"*) return 0 ;; esac; return 1; }
row_has() { case "$(printf '%s' "$row" | jq -r "$1")" in *"$2"*) return 0 ;; esac; return 1; }

echo "-- setup: 引数と終了コード --"
run_setup -- --help
if [ "$RC" -eq 0 ] && out_has "setup-cloud-env.sh"; then ok "--help は exit 0"; else bad "--help が exit 0 でない (rc=$RC)"; fi
# 行番号で切っていると本文を足すたびにコード行が漏れる
if ! grep -qE '^[^#]' "$TMP/stdout.log"; then ok "--help は先頭コメントブロックだけを出す（コード行を漏らさない）"; else bad "--help がコード行を出した: $(grep -nE '^[^#]' "$TMP/stdout.log" | head -n 2)"; fi
run_setup -- --no-such-flag
if [ "$RC" -eq 2 ] && out_has "unknown option"; then ok "未知フラグは exit 2（引数エラーだけが非 0）"; else bad "未知フラグの扱いが契約と違う (rc=$RC)"; fi

echo "-- setup: --dry-run（Linux root・gh / shellcheck / yq 不在・POSIX ロケール + C.utf8 あり） --"
run_setup FF_SETUP_OS=Linux FF_SETUP_IS_ROOT=1 STUB_LOCALES='C\nPOSIX\nC.utf8\n' -- --dry-run
if [ "$RC" -eq 0 ]; then ok "dry-run: 不在項目があっても exit 0"; else bad "dry-run: exit ${RC}（0 でなければならない）"; sed 's/^/    | /' "$TMP/out.log" >&2; fi
for item in origin/HEAD mcp/node_modules shellcheck rsync gh yq ロケール FF_DEV_TOOLKIT_ROOT; do
  if [ -n "$(line_of "$item")" ]; then ok "dry-run: 項目 ${item} が 1 行で報告される"; else bad "dry-run: 項目 ${item} の報告行が無い"; fi
done
if line_has gh "(dry-run)" && line_has gh "apt-get install -y gh"; then
  ok "dry-run: gh 不在は「実行予定: apt-get install -y gh」と出る"
else
  bad "dry-run: gh 不在の予定行が無い: $(line_of gh)"
fi
if line_has yq "(dry-run)" && line_has yq "mikefarah"; then ok "dry-run: yq は mikefarah v4 の導入予定を出す"; else bad "dry-run: yq の予定行が無い: $(line_of yq)"; fi
if [ ! -s "$TMP/apt.log" ] && [ ! -s "$TMP/net.log" ]; then ok "dry-run: apt-get / npm / curl を呼ばない"; else bad "dry-run: 導入コマンドが呼ばれた: $(cat "$TMP/apt.log" "$TMP/net.log")"; fi
if line_has origin/HEAD "(dry-run)" && ! git -C "$FX" symbolic-ref -q refs/remotes/origin/HEAD >/dev/null 2>&1; then
  ok "dry-run: origin/HEAD は set-head を実行しない"
else
  bad "dry-run: origin/HEAD の扱いが違う: $(line_of origin/HEAD)"
fi
if line_has ロケール "⚠️" && out_has "export LC_ALL=C.utf8"; then
  ok "ロケール: POSIX + C.utf8 あり → ⚠️ と export LC_ALL=C.utf8 行"
else
  bad "ロケール: warn 分岐が契約と違う: $(line_of ロケール)"
fi

echo "-- setup: 実行モード（Linux root。apt stub が失敗 / 成功、curl 失敗・go 無し） --"
run_setup FF_SETUP_OS=Linux FF_SETUP_IS_ROOT=1 STUB_LOCALES='C\nPOSIX\n' --
if [ "$RC" -eq 0 ]; then ok "実行: 全項目が導入不能でも exit 0"; else bad "実行: exit ${RC}"; sed 's/^/    | /' "$TMP/out.log" >&2; fi
if grep -qF "install -y gh" "$TMP/apt.log" && grep -qF "install -y shellcheck" "$TMP/apt.log"; then ok "実行: gh / shellcheck の apt-get install を試みる"; else bad "実行: apt-get が呼ばれていない: $(cat "$TMP/apt.log")"; fi
if line_has gh "❌" && line_has gh "apt-get install gh に失敗"; then ok "実行: apt-get 失敗を ❌ で 1 行報告する"; else bad "実行: apt-get 失敗の報告が違う: $(line_of gh)"; fi
# 失敗理由の分類（Issue #1427）。「今回だけのミラー障害」と「この環境に無いパッケージ」を
# 同じ 1 行へ潰すと、再実行すべきか環境都合の skip 側で扱うべきかが決められない。
if line_has gh "パッケージ不在" && ! line_has gh "ミラーへ到達できない"; then
  ok "実行: apt の Unable to locate package を「パッケージ不在」と分類して報告する"
else
  bad "実行: apt 失敗の分類（パッケージ不在）が出ていない: $(line_of gh)"
fi
if line_has yq "❌" && grep -qF "yq_linux" "$TMP/net.log"; then ok "実行: yq は release 取得を試み、失敗（go 無し）を ❌ で報告する"; else bad "実行: yq の失敗報告が違う: $(line_of yq) / $(cat "$TMP/net.log")"; fi
if line_has ロケール "❌" && ! out_has "export LC_ALL="; then ok "ロケール: UTF-8 ロケール無し → ❌ の 1 行警告、export 行なし"; else bad "ロケール: missing 分岐が契約と違う: $(line_of ロケール)"; fi
if line_has origin/HEAD "❌" && line_has origin/HEAD "remote origin が無い"; then ok "実行: origin 無しは ❌ で報告し止まらない"; else bad "実行: origin 無しの報告が違う: $(line_of origin/HEAD)"; fi

run_setup FF_SETUP_OS=Linux FF_SETUP_IS_ROOT=1 STUB_APT_FAIL_MODE=network --
if line_has gh "ミラーへ到達できない" && ! line_has gh "パッケージ不在"; then
  ok "実行: apt の Could not resolve / Failed to fetch を「ミラーへ到達できない」と分類して報告する"
else
  bad "実行: apt 失敗の分類（ミラー不達）が出ていない: $(line_of gh)"
fi

# 実際のミラー障害では両方の文言が同時に出る。パッケージ名の側を先に見ると「この環境には
# 無い」と誤って断定し、「再実行すれば入る」のか「環境都合として扱う」のかが逆になる。
run_setup FF_SETUP_OS=Linux FF_SETUP_IS_ROOT=1 STUB_APT_FAIL_MODE=both --
if line_has gh "ミラーへ到達できない" && ! line_has gh "パッケージ不在"; then
  ok "実行: ミラー不達と不在の文言が同時に出る回はミラー側を採る（判断が逆にならない）"
else
  bad "実行: 両方の文言が出る回の分類が逆: $(line_of gh)"
fi

# mktemp が使えないホスト（read-only な TMPDIR 等。本 PR が対象にしているクラウドの一種）でも
# 「導入できなかった項目があっても exit 0」の契約を守り、分類できなかったことを言う。
mv "$BIN/mktemp" "$TMP/mktemp.hidden"
run_setup FF_SETUP_OS=Linux FF_SETUP_IS_ROOT=1 --
mv "$TMP/mktemp.hidden" "$BIN/mktemp"
if [ "$RC" -eq 0 ] && line_has gh "apt-get install gh に失敗" && out_has "[setup] " ; then
  ok "実行: mktemp が使えない回でも exit 0 を保ち、以降の項目まで報告し切る"
else
  bad "実行: mktemp 不在で setup が中断した (rc=$RC): $(line_of gh)"
fi

run_setup FF_SETUP_OS=Linux FF_SETUP_IS_ROOT=1 STUB_APT_INSTALLS=1 --
if [ "$RC" -eq 0 ] && line_has gh "✅" && line_has gh "apt-get install gh で導入"; then ok "実行: apt-get 成功後に PATH で実体を再確認して ✅"; else bad "実行: apt-get 成功の報告が違う (rc=$RC): $(line_of gh)"; fi
rm -f "$BIN/gh" "$BIN/shellcheck" "$BIN/rsync"

echo "-- setup: 導入しない環境（macOS / 非 root / --skip-install） --"
run_setup FF_SETUP_OS=Darwin FF_SETUP_IS_ROOT=0 --
if [ "$RC" -eq 0 ] && line_has gh "○" && line_has gh "brew install gh" && [ ! -s "$TMP/apt.log" ]; then
  ok "macOS: apt-get を呼ばず brew の手動導入を案内して exit 0"
else
  bad "macOS: 扱いが契約と違う (rc=$RC): $(line_of gh) apt=$(cat "$TMP/apt.log")"
fi
run_setup FF_SETUP_OS=Linux FF_SETUP_IS_ROOT=0 --
if [ "$RC" -eq 0 ] && line_has gh "root でないため apt-get を実行しない" && [ ! -s "$TMP/apt.log" ]; then ok "非 root: apt-get を呼ばず sudo の手動導入を案内"; else bad "非 root: 扱いが契約と違う: $(line_of gh)"; fi
run_setup FF_SETUP_OS=Linux FF_SETUP_IS_ROOT=1 -- --skip-install
if [ "$RC" -eq 0 ] && line_has gh "❌" && line_has gh "skip-install" && [ ! -s "$TMP/apt.log" ] && [ ! -s "$TMP/net.log" ]; then ok "--skip-install: 検出だけ行い導入コマンドを呼ばない"; else bad "--skip-install: 扱いが契約と違う: $(line_of gh)"; fi

echo "-- setup: yq（macOS の dry-run / 導入後の版確認） --"
run_setup FF_SETUP_OS=Darwin FF_SETUP_IS_ROOT=0 -- --dry-run
if line_has yq "自動導入しない" && ! line_has yq "(dry-run)" && [ ! -s "$TMP/net.log" ]; then
  ok "macOS + --dry-run: 実行モードで起きない curl の計画を出さない（OS 判定が先）"
else
  bad "macOS + --dry-run: yq 行が実体と食い違う: $(line_of yq)"
fi
# 導入は成功するが v3 を名乗る → ❌（置けただけで ✅ にしない）
run_setup FF_SETUP_OS=Linux FF_SETUP_IS_ROOT=0 STUB_CURL_YQ_VERSION=1 \
  STUB_YQ_VERSION_LINE='yq (https://github.com/mikefarah/yq/) version v3.4.1' --
if [ "$RC" -eq 0 ] && line_has yq "❌" && line_has yq "mikefarah v4 と確認できない"; then
  ok "yq: 導入後に --version が v4 でなければ ❌（版確認をしている）"
else
  bad "yq: 版確認が効いていない: $(line_of yq)"
fi
rm -f "$TMP/.local/bin/yq"
run_setup FF_SETUP_OS=Linux FF_SETUP_IS_ROOT=0 STUB_CURL_YQ_VERSION=1 \
  STUB_YQ_VERSION_LINE='yq (https://github.com/mikefarah/yq/) version v4.44.3' --
if [ "$RC" -eq 0 ] && ! line_has yq "❌" && line_has yq "v4.44.3"; then
  ok "yq: mikefarah v4 を確認できたら成功扱い（版を報告に含める）"
else
  bad "yq: v4 導入の報告が違う: $(line_of yq)"
fi
rm -f "$TMP/.local/bin/yq"

echo "-- setup: HOME 未設定（set -u 下の裸参照が無いこと） --"
# env -i で HOME ごと落とす。`$HOME` を裸参照していると unbound variable で rc=1 になり、
# 「導入できなかった項目があっても exit 0」の契約に届かない
RC=0
(cd "$FX" && env -i PATH="$BIN" TMPDIR="$TMP" \
    FF_SETUP_LOCALE_CMD="$LOCALE_STUB" FF_SETUP_APT_GET="$APT_STUB" FF_SETUP_NPM="$TMP/npm" FF_SETUP_CURL="$TMP/curl" \
    STUB_APT_LOG="$TMP/apt.log" STUB_NET_LOG="$TMP/net.log" \
    FF_SETUP_OS=Linux FF_SETUP_IS_ROOT=0 bash "$SETUP") >"$TMP/stdout.log" 2>"$TMP/stderr.log" </dev/null || RC=$?
cat "$TMP/stdout.log" "$TMP/stderr.log" > "$TMP/out.log"
if [ "$RC" -eq 0 ] && ! out_has "unbound variable"; then
  ok "HOME 未設定でも exit 0（unbound variable にならない）"
else
  bad "HOME 未設定で契約を割った (rc=$RC): $(head -n 5 "$TMP/out.log")"
fi
if line_has yq "❌" && line_has yq "HOME も未設定"; then
  ok "HOME 未設定: yq は導入先を決められない旨を ❌ で 1 行報告する"
else
  bad "HOME 未設定: yq 行が契約と違う: $(line_of yq)"
fi

echo "-- setup: origin ありの fixture（--skip-install は set-head しない） --"
# origin を持つ fixture を用意する（ローカル bare をリモートにするのでネットワークへ出ない）
BARE="$TMP/origin.git"
git init -q --bare "$BARE"
git -C "$BARE" symbolic-ref HEAD refs/heads/main
SEED="$TMP/seed"
git init -q -b main "$SEED"
: > "$SEED/README.md"
git -C "$SEED" -c user.email=t@example.com -c user.name=t add README.md
git -C "$SEED" -c user.email=t@example.com -c user.name=t commit -q -m seed
git -C "$SEED" push -q "$BARE" main
FX2="$TMP/fx2"
git init -q "$FX2"
git -C "$FX2" remote add origin "$BARE"
git -C "$FX2" fetch -q origin
git -C "$FX2" symbolic-ref -q --delete refs/remotes/origin/HEAD >/dev/null 2>&1 || true

FXDIR="$FX2"
run_setup FF_SETUP_OS=Linux FF_SETUP_IS_ROOT=1 -- --skip-install
if [ "$RC" -eq 0 ] && line_has origin/HEAD "--skip-install" \
  && ! git -C "$FX2" symbolic-ref -q refs/remotes/origin/HEAD >/dev/null 2>&1; then
  ok "--skip-install: origin/HEAD を検出するだけで set-head しない（symbolic-ref は不変）"
else
  bad "--skip-install: set-head を実行した / 報告が違う: $(line_of origin/HEAD)"
fi
run_setup FF_SETUP_OS=Linux FF_SETUP_IS_ROOT=1 --
if [ "$RC" -eq 0 ] && line_has origin/HEAD "✅" \
  && git -C "$FX2" symbolic-ref -q refs/remotes/origin/HEAD >/dev/null 2>&1; then
  ok "既定: origin/HEAD 未解決なら set-head で解決して ✅"
else
  bad "既定: set-head が効いていない: $(line_of origin/HEAD)"
fi
FXDIR="$FX"

echo "-- setup: --print-env --"
run_setup FF_SETUP_OS=Linux FF_SETUP_IS_ROOT=1 STUB_LOCALES='C\nPOSIX\nen_US.UTF-8\n' -- --print-env --dry-run
if [ "$RC" -eq 0 ] && [ -s "$TMP/stdout.log" ] && ! grep -qvE '^export [A-Z_]+=' "$TMP/stdout.log" && grep -qxF "export LC_ALL=en_US.UTF-8" "$TMP/stdout.log"; then
  ok "--print-env: stdout は export 行だけ（eval できる形）で LC_ALL を提示する"
else
  bad "--print-env: stdout の形が違う (rc=$RC): $(cat "$TMP/stdout.log")"
fi
if grep -qF "[setup]" "$TMP/stderr.log"; then ok "--print-env: 進捗行は stderr へ退避する"; else bad "--print-env: 進捗行が stderr に無い"; fi
# 空白を含むパスでも eval できること（--print-env の出力は eval される契約）
FX3="$TMP/fx space/repo"
mkdir -p "$FX3/plugins/ff-dev-toolkit/scripts"
: > "$FX3/plugins/ff-dev-toolkit/scripts/multi-agent.sh"
git init -q "$FX3"
FXDIR="$FX3"
run_setup FF_SETUP_OS=Linux FF_SETUP_IS_ROOT=1 -- --print-env --dry-run
FXDIR="$FX"
_want="$( (cd "$FX3" && git rev-parse --show-toplevel) )/plugins/ff-dev-toolkit"
_got="$(env -i PATH="$BIN" bash -c '. /dev/stdin >/dev/null 2>&1 <"$1"; printf "%s\n" "${FF_DEV_TOOLKIT_ROOT:-unset}"' _ "$TMP/stdout.log" || true)"
if [ "$_got" = "$_want" ]; then
  ok "--print-env: 空白を含むパスも quote され、eval で元の値に戻る"
else
  bad "--print-env: 空白入りパスの quote が壊れている: eval 後=${_got} 期待=${_want} 出力=$(cat "$TMP/stdout.log")"
fi
run_setup FF_SETUP_OS=Linux FF_SETUP_IS_ROOT=1 STUB_CTYPE=C.UTF-8 --
if line_has ロケール "✅" && ! out_has "export LC_ALL="; then ok "ロケール: 実効 LC_CTYPE が UTF-8 なら ✅ で export 行を出さない"; else bad "ロケール: ok 分岐が契約と違う: $(line_of ロケール)"; fi

echo "-- setup: 静的契約（bash 3.2 / set -euo pipefail / grep -q をパイプ下流に置かない） --"
if grep -qE '^set -euo pipefail' "$SETUP"; then ok "set -euo pipefail で動く"; else bad "set -euo pipefail が無い"; fi
if ! grep -qE '\|[[:space:]]*grep -q' "$SETUP" "$LOCALE_LIB"; then ok "grep -q をパイプ下流に置いていない（setup / utf8-locale）"; else bad "grep -q がパイプ下流にある: $(grep -nE '\|[[:space:]]*grep -q' "$SETUP" "$LOCALE_LIB")"; fi
# コメント行（「mapfile を使わない」の宣言）を除いたコード行だけを見る
code_lines="$(grep -hvE '^[[:space:]]*#' "$SETUP" "$LOCALE_LIB" "$PROBE" || true)"
if ! grep -qE 'declare -A|mapfile|readarray' <<<"$code_lines"; then ok "bash 4 専用構文（連想配列 / mapfile）を使っていない"; else bad "bash 3.2 非互換の構文がある"; fi

echo "-- utf8-locale.sh: ff_ensure_utf8_locale --"
# サブシェルで lib を読み、結果の LC_ALL と stderr を観測する
probe_lib() { # $1: STUB_CTYPE / $2: STUB_LOCALES / stdout: LC_ALL の結果
  env -i PATH="$BIN" STUB_CTYPE="$1" STUB_LOCALES="$2" FF_UTF8_LOCALE_CMD="$LOCALE_STUB" \
    bash -c '. "$1" && ff_ensure_utf8_locale && printf "%s\n" "${LC_ALL:-unset}"' _ "$LOCALE_LIB" 2>"$TMP/lib-err.log"
}
r="$(probe_lib POSIX 'C\nPOSIX\nC.UTF-8\n')"
if [ "$r" = "C.UTF-8" ] && grep -qF "LC_ALL=C.UTF-8 に固定" "$TMP/lib-err.log"; then ok "POSIX + C.UTF-8 あり → LC_ALL=C.UTF-8 を export し 1 行通知"; else bad "POSIX + C.UTF-8 の扱いが違う: LC_ALL=${r} / $(cat "$TMP/lib-err.log")"; fi
r="$(probe_lib POSIX 'C\nPOSIX\nen_US.utf8\n')"
if [ "$r" = "en_US.utf8" ]; then ok "C.UTF-8 が無ければ en_US.utf8 へ倒す"; else bad "en_US.utf8 の選択が違う: LC_ALL=${r}"; fi
r="$(probe_lib POSIX 'C\nPOSIX\n')"
if [ "$r" = "unset" ] && grep -qF "docs-gates / docs-gates-runtime" "$TMP/lib-err.log"; then ok "UTF-8 ロケール無し → export せず 1 行警告して続行（戻り値 0）"; else bad "UTF-8 無しの扱いが違う: LC_ALL=${r} / $(cat "$TMP/lib-err.log")"; fi
r="$(probe_lib ja_JP.UTF-8 'C\nPOSIX\n')"
if [ "$r" = "unset" ] && [ ! -s "$TMP/lib-err.log" ]; then ok "実効 LC_CTYPE が UTF-8 なら何もしない（利用者のロケールを上書きしない）"; else bad "UTF-8 実効時の扱いが違う: LC_ALL=${r} / $(cat "$TMP/lib-err.log")"; fi
for consumer in "$PLUGIN_ROOT/tests/run-all.sh" "$PLUGIN_ROOT/tests/docs-gates/verify.sh" "$PLUGIN_ROOT/tests/docs-gates-runtime/verify.sh"; do
  if grep -qF 'lib/utf8-locale.sh' "$consumer" && grep -qE '^[[:space:]]*ff_ensure_utf8_locale$' "$consumer"; then
    ok "$(basename "$(dirname "$consumer")")/$(basename "$consumer") が入口でロケールを固定する"
  else
    bad "$(basename "$(dirname "$consumer")")/$(basename "$consumer") がロケール固定を呼んでいない（cloud の POSIX ロケールで赤に戻る）"
  fi
done

echo "-- probe-env-capabilities.sh: ロケール行 --"
if [ "$HAVE_JQ" -eq 0 ]; then
  echo "  ○ skip: jq が無いため probe --json の構造検査だけをスキップ（setup / utf8-locale の検査は実施済み）"
fi
probe_row() { # $1: STUB_CTYPE / $2: STUB_LOCALES / stdout: ロケール行の JSON
  (cd "$FX" && env -i PATH="$BIN" HOME="$TMP" STUB_CTYPE="$1" STUB_LOCALES="$2" FF_PROBE_LOCALE_CMD="$LOCALE_STUB" \
    bash "$PROBE" --json 2>/dev/null) > "$TMP/probe.json" || return 1
  jq -c '.rows[] | select(.category=="env" and .name=="ロケール")' "$TMP/probe.json"
}
if [ "$HAVE_JQ" -eq 1 ]; then
  row="$(probe_row POSIX 'C\nPOSIX\nC.utf8\n')" || row=""
  if jq -e . "$TMP/probe.json" >/dev/null 2>&1; then ok "--json は jq . で parse できる（ロケール行追加後）"; else bad "--json が jq で parse できない"; fi
  if [ "$(printf '%s' "$row" | jq -r .status)" = "warn" ] && row_has .fix "LC_ALL=C.utf8" \
    && row_has .step "docs-gates / docs-gates-runtime"; then
    ok "probe: POSIX + C.utf8 あり → warn、回避策 LC_ALL=C.utf8、影響ステップに docs-gates 系"
  else
    bad "probe: warn 行が契約と違う: ${row}"
  fi
  row="$(probe_row POSIX 'C\nPOSIX\n')" || row=""
  if [ "$(printf '%s' "$row" | jq -r .status)" = "missing" ] && row_has .detail "UTF-8 ロケール無し"; then ok "probe: UTF-8 ロケール無し → missing"; else bad "probe: missing 行が契約と違う: ${row}"; fi
  row="$(probe_row C.UTF-8 'C\nPOSIX\nC.UTF-8\n')" || row=""
  if [ "$(printf '%s' "$row" | jq -r .status)" = "ok" ] && row_has .detail "LANG=" ; then ok "probe: 実効 LC_CTYPE=UTF-8 → ok（LANG / LC_ALL / LC_CTYPE の設定値を観測値に含む）"; else bad "probe: ok 行が契約と違う: ${row}"; fi
fi
# installed_plugins.json 行（Issue #1427）。「宣言済み」と「導入済み」を分けて見るための行で、
# 観測したいのはまさに「導入 0 件」の状態。ここで probe 自体が落ちると、クラウドで一番知りたい
# 回だけ結果表が出ない（実際 grep -o 版はそうなっていた: 一致なしの exit 1 が set -euo pipefail
# で代入ごとスクリプトを終わらせる）。0 件でも表を出し切ることを含めて固定する。
probe_plugins_row() { # $1: installed_plugins.json の中身（空文字ならファイルを置かない）
  rm -rf "$TMP/.claude/plugins"
  if [ -n "$1" ]; then
    mkdir -p "$TMP/.claude/plugins"
    printf '%s' "$1" > "$TMP/.claude/plugins/installed_plugins.json"
  fi
  PROBE_RC=0
  (cd "$FX" && env -i PATH="$BIN" HOME="$TMP" STUB_CTYPE=C.UTF-8 STUB_LOCALES='C\nC.UTF-8\n' \
    FF_PROBE_LOCALE_CMD="$LOCALE_STUB" bash "$PROBE" --json 2>/dev/null) > "$TMP/probe.json" || PROBE_RC=$?
  [ "$PROBE_RC" -eq 0 ] || return 1
  jq -c '.rows[] | select(.category=="path" and .name=="installed_plugins.json")' "$TMP/probe.json"
}
if [ "$HAVE_JQ" -eq 1 ]; then
  row="$(probe_plugins_row '{"version":2,"plugins":{}}')" || row=""
  if [ "$(printf '%s' "$row" | jq -r .status)" = "fail" ] && row_has .detail "導入 0 件"; then
    ok "probe: 導入 0 件でも probe は exit 0 で結果表を出し切り、その行を fail として報告する"
  else
    bad "probe: 導入 0 件の行が契約と違う（probe が途中で落ちた可能性）: ${row}"
  fi
  # メタデータのパスに @ が入っていても、数えるのは plugins 直下のキーだけ
  row="$(probe_plugins_row '{"version":2,"plugins":{"ff-dev-toolkit@ff-dev-toolkit":{"path":"/opt/plugins/@scoped/cache/0.1.0"}}}')" || row=""
  if [ "$(printf '%s' "$row" | jq -r .status)" = "ok" ] && row_has .detail "1 件が導入済み"; then
    ok "probe: 件数は plugins 直下のキー数（メタデータの @ を数えない）"
  else
    bad "probe: 導入件数の数え方が契約と違う: ${row}"
  fi
  row="$(probe_plugins_row '')" || row=""
  if [ "$(printf '%s' "$row" | jq -r .status)" = "missing" ]; then
    ok "probe: installed_plugins.json 不在は missing"
  else
    bad "probe: ファイル不在の行が契約と違う: ${row}"
  fi
  rm -rf "$TMP/.claude/plugins"
fi

md="$( (cd "$FX" && env -i PATH="$BIN" HOME="$TMP" STUB_CTYPE=POSIX STUB_LOCALES='C\nPOSIX\nC.utf8\n' FF_PROBE_LOCALE_CMD="$LOCALE_STUB" bash "$PROBE" 2>/dev/null) | grep -F '| env | ロケール |' || true)"
if [[ "$md" == *"⚠️ warn"* ]]; then ok "probe: Markdown 表にも同じロケール行が出る"; else bad "probe: Markdown 表にロケール行が無い"; fi

echo
if [ "$FAIL" -gt 0 ]; then
  echo "✗ cloud-env-setup verify: $FAIL 件失敗（$PASS 件成功）" >&2
  exit 1
fi
echo "✓ cloud-env-setup verify: 全 $PASS 件 pass"
FF_REACHED_END=1
