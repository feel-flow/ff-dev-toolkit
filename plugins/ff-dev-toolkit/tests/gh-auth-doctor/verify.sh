#!/usr/bin/env bash
# 空振り検出: gh・powershell.exe・wsl.exe の不在、WSL 側の gh 不在・WSL の起動失敗、rc 0 の空出力・null、文字種の外のディストリ名を与えると (6)(7)(8)(10)(11)(13)(30)(34) が赤になる（各分岐を ok へ倒す変異 8 本がそれぞれその番号で赤になることを実測）。
#
# gh-auth-doctor: gh の認証を文脈ごとに `gh api user` で測る診断と、device flow の再ログインの回帰テスト。
#
# 実の gh・PowerShell・WSL は呼ばない。PATH を本 suite が作った 3 つのディレクトリ（偽の gh /
# 偽の powershell.exe・wsl.exe / 必要最小限のコマンドの転送スクリプト）だけにして起動する。
# 実ホストの /usr/bin を PATH に入れると、CI や WSL の /usr/bin/gh が「gh 不在」のケースへ混ざる。
# Windows の分岐は bash 組み込みの OSTYPE で選ばれるので、BASH_ENV のファイルで OSTYPE を
# 代入して Linux / macOS でも両側を測る（環境変数の OSTYPE は bash の起動時に上書きされる）。

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SUT="$PLUGIN_ROOT/scripts/gh-auth-doctor.sh"
BASH_BIN="$(command -v bash)"

if [ ! -f "$SUT" ]; then
  echo "✗ script not found: $SUT" >&2
  exit 1
fi

# 一時ディレクトリを作れない回は skip にせず赤にする（本 suite は全ホストで全ケースを回す）。
if _ff_mktemp_out="$(mktemp -d "${TMPDIR:-/tmp}/gh-auth-doctor-test.XXXXXX" 2>&1)" && [ -d "$_ff_mktemp_out" ]; then
  WORK="$_ff_mktemp_out"
else
  echo "✗ 一時ディレクトリを作成できません: $_ff_mktemp_out" >&2
  exit 1
fi
# 途中死を沈黙させない。`set -u` 等で死んだとき、トラップ突入時の $? は 0 になりうるので、
# 「rc=0 なのに最後まで到達していない」を中断として扱う。
FF_REACHED_END=0
_ff_exit_guard() {
  _ff_rc=$?
  rm -rf "$WORK"
  if [ "$_ff_rc" -eq 0 ] && [ "$FF_REACHED_END" -ne 1 ]; then
    echo "✗ gh-auth-doctor: 最後まで到達しませんでした（途中で中断）" >&2
    exit 1
  fi
  exit "$_ff_rc"
}
trap _ff_exit_guard EXIT

PASS=0
fail() {
  echo "✗ $1" >&2
  [ ! -f "$WORK/out" ] || sed 's/^/    | /' "$WORK/out" >&2
  exit 1
}
ok() {
  PASS=$((PASS + 1))
  echo "  ✓ $1"
}

# ── 偽のコマンド ──────────────────────────────────────────────
SYS="$WORK/sys"; GHBIN="$WORK/ghbin"; WINBIN="$WORK/winbin"
mkdir -p "$SYS" "$GHBIN" "$WINBIN"
# 必要最小限のコマンドを絶対パスへ転送する。シンボリックリンクにしないのは、Git Bash の ln -s が
# 複製になり、/usr/bin から離れた exe が DLL を見つけられないため。
for tool in dirname basename mktemp rm timeout sleep sh tr; do
  real="$(command -v "$tool" 2>/dev/null)" || continue
  printf '#!/bin/sh\nexec "%s" "$@"\n' "$real" > "$SYS/$tool"
  chmod +x "$SYS/$tool"
done
[ -x "$SYS/mktemp" ] && [ -x "$SYS/sh" ] || fail "転送スクリプトを作れません（mktemp / sh がこのホストに見つからない）"

# 偽の gh。auth login は FAKE_GH_LOGIN、api user は FAKE_GH_MODE で振る舞いを選ぶ。
# 呼ばれた引数と GH_PROMPT_DISABLED / GH_DEBUG を FAKE_LOG へ残す。login は自分の pid を
# FAKE_GH_PIDFILE へ書き、待つときは exec sleep で同じ pid のまま待つ（止めたかを pid で確かめる）。
cat > "$GHBIN/gh" <<'EOF'
#!/bin/sh
printf 'gh %s | prompt=%s debug=%s/%s\n' "$*" "${GH_PROMPT_DISABLED-unset}" "${GH_DEBUG-unset}" "${DEBUG-unset}" >> "$FAKE_LOG"
if [ "$1" = auth ] && [ "$2" = login ]; then
  [ -z "${FAKE_GH_PIDFILE:-}" ] || printf '%s\n' "$$" > "$FAKE_GH_PIDFILE"
  case "${FAKE_GH_LOGIN:-code}" in
    code|codehang)
      printf 'ABCD-9999 looks like a code but is not on the code line\n'
      printf '! First copy your one-time code: ABCD-1234\n'
      printf 'Open this URL to continue in your web browser: https://github.com/login/device\n'
      # トークン様の文字列は実行時に組み立てる（本ファイルに書くと公開同期の禁止パターンに当たる）
      printf 'debug: %s_%s\n' gho FAKESECRETTOKEN0000
      [ "${FAKE_GH_LOGIN:-code}" = code ] || exec sleep 30
      sleep "${FAKE_GH_LOGIN_SLEEP:-0}"
      printf 'Logged in as tester\n'
      exit 0 ;;
    nocode) printf 'error connecting to github.com\n' >&2; printf 'debug: %s_%s\n' gho FAKESECRETTOKEN0001 >&2; exit 1 ;;
    hang) exec sleep 30 ;;
    codehang_noterm)
      # TERM を無視したまま承認を待ち続ける gh（KILL への昇格を測る）
      printf '! First copy your one-time code: ABCD-1234\n'
      trap '' TERM
      exec sleep 30 ;;
  esac
fi
case "${FAKE_GH_MODE:-ok}" in
  ok) printf 'tester\n'; exit 0 ;;
  crlf) printf 'tester\r\n'; exit 0 ;;
  okwarn) printf 'tester\n'; printf 'warning: retried after HTTP 401 from a proxy\n' >&2; exit 0 ;;
  null) printf 'null\n'; exit 0 ;;
  401) printf 'gh: Bad credentials (HTTP 401)\n' >&2; exit 1 ;;
  nologin) printf 'To get started with GitHub CLI, please run:  gh auth login\n' >&2; exit 4 ;;
  nologin4) printf 'authentication required\n' >&2; exit 4 ;;
  nologin1) printf 'To get started with GitHub CLI, please run:  gh auth login\n' >&2; exit 1 ;;
  hang) exec sleep 30 ;;
  neterr) printf 'error connecting to api.github.com\n' >&2; exit 1 ;;
  timeout) printf 'tester\n'; exit 124 ;;
  fail1) printf 'tester\n'; exit 1 ;;
  empty) exit 0 ;;
  garbage) printf 'tester\nwarning: extra line\n'; exit 0 ;;
  emu) printf 'tester_acme\n'; exit 0 ;;
  nologin1b) printf 'You are not logged into any GitHub hosts. To log in, run: gh auth login\n' >&2; exit 1 ;;
  killed137) exit 137 ;;
esac
exit 1
EOF
# 偽の powershell.exe。PowerShell の構文は解釈できないので、受け取った -Command の文面と、gh の参照先を
# 変える環境変数が外れているかを残し、FAKE_PS_MODE に従って偽の gh を呼ぶ（nogh は Get-Command の不在 = 97）。
cat > "$WINBIN/powershell.exe" <<'EOF'
#!/bin/sh
printf 'powershell %s | env=%s/%s/%s/%s/%s/%s/%s\n' "$*" "${GH_TOKEN-unset}" "${GITHUB_TOKEN-unset}" \
  "${GH_ENTERPRISE_TOKEN-unset}" "${GITHUB_ENTERPRISE_TOKEN-unset}" "${GH_CONFIG_DIR-unset}" "${XDG_CONFIG_HOME-unset}" \
  "${GH_HOST-unset}" >> "$FAKE_LOG"
case "${FAKE_PS_MODE:-ok}" in
  nogh) exit 97 ;;
esac
# -Command の文面から --hostname の値だけを取り出して偽の gh へ渡す（ホスト名の受け渡しを振る舞いで測る）
host=""; prev=""
for arg in "$@"; do
  set -f; for word in $arg; do [ "$prev" != --hostname ] || host="$word"; prev="$word"; done; set +f
done
FAKE_GH_MODE="${FAKE_PS_MODE:-ok}" exec "$FAKE_GHBIN/gh" api --hostname "$host" user
EOF
# 偽の wsl.exe。`[-d 名前] --exec <argv...>` を受け、argv をそのまま実行する（本物の --exec と同じく
# シェルを介さない）。WSL 側の PATH には偽の gh を FAKE_WSL_GH=absent のときだけ入れない。
# FAKE_WSL_NOTICE=1 は Linux 側より前に wsl.exe 自身の通知が stdout へ出る回を模す。
cat > "$WINBIN/wsl.exe" <<'EOF'
#!/bin/sh
printf 'wsl %s | conv=%s\n' "$*" "${MSYS2_ARG_CONV_EXCL-unset}" >> "$FAKE_LOG"
distro="${FAKE_WSL_DEFAULT-Ubuntu}"
if [ "$1" = -d ]; then distro="$2"; shift 2; fi
[ "$1" = --exec ] || { printf 'unexpected wsl.exe args\n' >&2; exit 64; }
shift
if [ "${FAKE_WSL_MODE:-up}" = down ]; then printf 'Wsl/Service/WSL_E_DISTRO_NOT_FOUND\n' >&2; exit 127; fi
[ "${FAKE_WSL_NOTICE:-0}" = 0 ] || printf 'wsl: a notice from wsl.exe itself\n'
wsl_path="$FAKE_SYS"
[ "${FAKE_WSL_GH:-present}" = absent ] || wsl_path="$FAKE_GHBIN:$FAKE_SYS"
HOME="${FAKE_WSL_HOME:-/nonexistent}" WSL_DISTRO_NAME="$distro" PATH="$wsl_path" FAKE_GH_MODE="${FAKE_WSL_GH_MODE:-ok}" exec "$@"
EOF
chmod +x "$GHBIN/gh" "$WINBIN/powershell.exe" "$WINBIN/wsl.exe"
printf 'OSTYPE=msys\n' > "$WORK/env-windows.sh"
printf 'OSTYPE=linux-gnu\n' > "$WORK/env-linux.sh"

# run <windows|linux> <PATH> [VAR=値 ...] -- [引数 ...]
# 出力（stdout + stderr）を $WORK/out、終了コードを RC へ入れる。FAKE_* は毎回既定へ戻す。
run() {
  local os="$1" path="$2"; shift 2
  local assigns=()
  while [ "$#" -gt 0 ] && [ "$1" != -- ]; do assigns+=("$1"); shift; done
  [ "$#" -eq 0 ] || shift
  : > "$WORK/fake.log"
  RC=0
  env -i HOME="$WORK" TMPDIR="$WORK/tmp" PATH="$path" BASH_ENV="$WORK/env-${os}.sh" \
    FAKE_LOG="$WORK/fake.log" FAKE_GHBIN="$GHBIN" FAKE_SYS="$SYS" \
    ${assigns[@]+"${assigns[@]}"} "$BASH_BIN" "$SUT" "$@" < /dev/null > "$WORK/out" 2>&1 || RC=$?
}
mkdir -p "$WORK/tmp"
has() { grep -F -q -- "$1" "$WORK/out"; }
row() { grep -q "^$1	$2	" "$WORK/out"; }
# 出力の本文（ガードの provenance 行を除く）に Windows の語があるか。checkout のパスに同じ語が
# 含まれても偽の赤にしない。
body_mentions_windows() { awk '!/^ℹ️/ && tolower($0) ~ /wsl|powershell/ { f = 1 } END { exit !f }' "$WORK/out"; }
expect_rc() { [ "$RC" -eq "$1" ] || fail "$2 で rc=${RC}（期待 $1）"; }
FULL="$GHBIN:$WINBIN:$SYS"

echo "gh-auth-doctor:"

# (1) Windows で 3 文脈とも ok
run windows "$FULL"
expect_rc 0 "(1) 全文脈 ok"
row bash ok && row powershell ok && row 'wsl（Ubuntu）' ok || fail "(1) 3 文脈の ok 行が揃わない"
has '集計: ok=3 要復旧=0 判定不能=0' || fail "(1) 集計行が違う"
ok "(1) Windows で 3 文脈（bash / powershell / wsl）を測り、全 ok は rc 0"

# (2) コンテナ内（このシェル）だけ 401 → その文脈にだけ device flow の復旧
run windows "$FULL" FAKE_GH_MODE=401
expect_rc 3 "(2) 401"
row bash 要復旧 && row powershell ok || fail "(2) bash だけが要復旧になっていない"
has '復旧（bash）' && has 'login --hostname github.com' || fail "(2) bash の device flow の案内が無い"
! has '復旧（powershell）' && ! has '復旧（wsl）' || fail "(2) 壊れていない文脈へ復旧を案内した"
! grep -qi 'logout' "$WORK/out" || fail "(2) ログアウトを案内した"
ok "(2) このシェルの 401 は bash にだけ device flow を案内し、ログアウトを出さない"

# (3) PowerShell だけ 401
run windows "$FULL" FAKE_PS_MODE=401
expect_rc 3 "(3) PowerShell の 401"
row powershell 要復旧 && row bash ok || fail "(3) powershell だけが要復旧になっていない"
has '復旧（powershell）: 利用者の PowerShell で gh auth login -h github.com -w' || fail "(3) PowerShell の復旧案内が無い"
! has '復旧（bash）' && ! has '復旧（wsl）' && ! grep -qi 'logout' "$WORK/out" || fail "(3) 余計な案内かログアウトが出た"
ok "(3) PowerShell の 401 は PowerShell にだけ再ログインを案内する"

# (4) WSL だけ 401 → PowerShell から打つ wsl -d の 2 行
run windows "$FULL" FAKE_WSL_GH_MODE=401
expect_rc 3 "(4) WSL の 401"
row 'wsl（Ubuntu）' 要復旧 || fail "(4) wsl が要復旧になっていない"
has 'wsl -d Ubuntu -- gh auth login -h github.com -w' && has 'wsl -d Ubuntu -- gh auth setup-git' \
  || fail "(4) wsl の復旧コマンドが AC の形でない"
has 'PowerShell から打つ' || fail "(4) PowerShell から打つ形の案内が無い"
! has '復旧（bash）' && ! has '復旧（powershell）' || fail "(4) 壊れていない文脈へ復旧を案内した"
ok "(4) WSL の 401 は wsl -d <ディストリ> の login と setup-git を PowerShell から打つ形で案内する"

# (5) 未ログインも要復旧。rc 4 だけの回と、古い gh の rc 1 + 定型文の回を別々に測る
run windows "$FULL" FAKE_WSL_GH_MODE=nologin4
expect_rc 3 "(5) 未ログイン（rc 4）"
row 'wsl（Ubuntu）' 要復旧 && has '未ログイン' || fail "(5) rc 4 の未ログインが要復旧にならない"
run windows "$FULL" FAKE_GH_MODE=nologin1
expect_rc 3 "(5) 未ログイン（rc 1 + 定型文）"
row bash 要復旧 && has '未ログイン' || fail "(5) 定型文の未ログインが要復旧にならない"
run windows "$FULL" FAKE_GH_MODE=nologin1b
expect_rc 3 "(5) 未ログイン（rc 1 + もう 1 つの定型文）"
row bash 要復旧 || fail "(5) 'You are not logged into any GitHub hosts' が要復旧にならない"
ok "(5) 未ログイン（rc 4 / 定型文）は要復旧で rc 3"

# (6) wsl.exe 不在 → 判定不能（緑にしない）
mkdir -p "$WORK/winbin-nowsl"
cp "$WINBIN/powershell.exe" "$WORK/winbin-nowsl/"
run windows "$GHBIN:$WORK/winbin-nowsl:$SYS"
expect_rc 2 "(6) wsl.exe 不在"
row wsl 判定不能 && has 'wsl.exe が見つかりません' || fail "(6) wsl.exe 不在が判定不能にならない"
ok "(6) wsl.exe 不在は判定不能で rc 2"

# (7) PowerShell 不在 → 判定不能
mkdir -p "$WORK/winbin-nops"
cp "$WINBIN/wsl.exe" "$WORK/winbin-nops/"
run windows "$GHBIN:$WORK/winbin-nops:$SYS"
expect_rc 2 "(7) PowerShell 不在"
row powershell 判定不能 || fail "(7) PowerShell 不在が判定不能にならない"
ok "(7) PowerShell 不在は判定不能で rc 2"

# (8) このシェルの gh 不在 → 判定不能
run windows "$WINBIN:$SYS"
expect_rc 2 "(8) gh 不在"
row bash 判定不能 && has 'gh が見つかりません' || fail "(8) gh 不在が判定不能にならない"
ok "(8) このシェルの gh 不在は判定不能で rc 2"

# (9) PowerShell の PATH に gh が無い（97）
run windows "$FULL" FAKE_PS_MODE=nogh
expect_rc 2 "(9) PowerShell 側の gh 不在"
row powershell 判定不能 && has 'PowerShell の PATH に gh が見つかりません' || fail "(9) PowerShell 側の gh 不在が判定不能にならない"
ok "(9) PowerShell の PATH の gh 不在は判定不能"

# (10) WSL の PATH に gh が無い
run windows "$FULL" FAKE_WSL_GH=absent
expect_rc 2 "(10) WSL 側の gh 不在"
row 'wsl（Ubuntu）' 判定不能 && has 'WSL（Ubuntu）の PATH に gh が見つかりません' || fail "(10) WSL 側の gh 不在が判定不能にならない"
ok "(10) WSL の PATH の gh 不在は判定不能"

# (11) WSL 自体が起動しない（distro= 行が無い）
run windows "$FULL" FAKE_WSL_MODE=down
expect_rc 2 "(11) WSL の起動失敗"
row wsl 判定不能 && has 'WSL を起動できません' || fail "(11) WSL の起動失敗が判定不能にならない"
ok "(11) WSL の起動失敗は判定不能"

# (12) ネットワーク等の失敗は 401 と言い切らず判定不能
run windows "$FULL" FAKE_GH_MODE=neterr
expect_rc 2 "(12) ネットワーク失敗"
row bash 判定不能 && has 'rc=1: error connecting' || fail "(12) ネットワーク失敗が判定不能にならない"
ok "(12) 401 でも未ログインでもない失敗は判定不能"

# (13) rc 0 でも空出力は ok にしない
run windows "$FULL" FAKE_GH_MODE=empty
expect_rc 2 "(13) 空出力"
row bash 判定不能 || fail "(13) 空出力が ok になった"
ok "(13) rc 0 の空出力は判定不能"

# (14) rc 0 でもログイン名の形でない出力は ok にしない
run windows "$FULL" FAKE_PS_MODE=garbage
expect_rc 2 "(14) 複数行の出力"
row powershell 判定不能 || fail "(14) 複数行の出力が ok になった"
ok "(14) ログイン名でない出力は判定不能"

# (15) CRLF の出力（Windows の native exe）でもログイン名を読む
run windows "$FULL" FAKE_PS_MODE=crlf
expect_rc 0 "(15) CRLF の出力"
grep -q "^powershell	ok	tester\$" "$WORK/out" || fail "(15) CRLF の出力でログイン名を読めない"
ok "(15) CRLF の出力は CR を落として ok"

# (16) 要復旧と判定不能が混在すると rc 3（復旧が要る方を優先して返す）
run windows "$FULL" FAKE_GH_MODE=401 FAKE_WSL_MODE=down
expect_rc 3 "(16) 要復旧と判定不能の混在"
row bash 要復旧 && row wsl 判定不能 || fail "(16) 混在の行が揃わない"
ok "(16) 要復旧と判定不能の混在は rc 3"

# (17) Mac / Linux は文脈 1 つで、Windows 固有の案内も起動もしない
run linux "$FULL"
expect_rc 0 "(17) Linux"
row shell ok || fail "(17) Linux で shell 行が ok にならない"
[ "$(grep -c '	' "$WORK/out")" -eq 2 ] || fail "(17) Linux で表の行数が 1 文脈ぶんでない"
! body_mentions_windows || fail "(17) Linux の出力に Windows の文脈が出た"
! grep -q '^powershell \|^wsl ' "$WORK/fake.log" || fail "(17) Linux で powershell.exe / wsl.exe を起動した"
ok "(17) Mac / Linux は文脈 1 つで、PowerShell / WSL を起動しない"

# (18) Mac / Linux の要復旧は Windows の語を出さない
run linux "$FULL" FAKE_GH_MODE=401
expect_rc 3 "(18) Linux の 401"
has '復旧（shell）' || fail "(18) Linux の 401 で shell の復旧が出ない"
! body_mentions_windows || fail "(18) Linux の復旧案内に Windows の語が出た"
ok "(18) Mac / Linux の復旧案内は device flow だけ"

# (19) このシェルの GH_TOKEN は PowerShell へ渡さず、401 の復旧は環境変数の案内にする
run windows "$FULL" GH_TOKEN=bogus FAKE_GH_MODE=401
has '復旧（bash）: このシェルの GH_TOKEN / GITHUB_TOKEN が無効です' || fail "(19) 環境変数のトークンの案内が無い"
! has 'login --hostname' || fail "(19) 環境変数が原因なのに device flow を案内した"
grep -q '^powershell .*| env=unset/unset/unset/unset/unset/unset/unset$' "$WORK/fake.log" || fail "(19) PowerShell へ GH_TOKEN を引き継いだ"
ok "(19) GH_TOKEN は PowerShell の測定から外し、復旧は環境変数を直す案内"

# (20) --wsl-distro は -d で渡り、表のラベルに WSL 側の名前が出る
run windows "$FULL" -- --wsl-distro Debian
expect_rc 0 "(20) --wsl-distro"
grep -q '^wsl -d Debian --exec sh -c ' "$WORK/fake.log" && row 'wsl（Debian）' ok || fail "(20) --wsl-distro が -d で渡らない"
ok "(20) --wsl-distro は wsl.exe -d へ渡る"

# (21) PowerShell へ渡す文面と MSYS の引数変換の停止
run windows "$FULL"
grep -F -q "powershell -NoProfile -NonInteractive -Command foreach (\$n in @('GH_TOKEN','GITHUB_TOKEN','GH_ENTERPRISE_TOKEN','GITHUB_ENTERPRISE_TOKEN','GH_CONFIG_DIR','XDG_CONFIG_HOME','GH_HOST')) { \$v = [Environment]::GetEnvironmentVariable(\$n, 'User'); if (-not \$v) { \$v = [Environment]::GetEnvironmentVariable(\$n, 'Machine') }; if (\$v) { Set-Item -Path ('env:' + \$n) -Value \$v } }; if (-not (Get-Command gh -ErrorAction SilentlyContinue)) { exit 97 }; gh api --hostname github.com user --jq .login; exit \$LASTEXITCODE |" "$WORK/fake.log" \
  || fail "(21) PowerShell へ渡す文面が違う（永続化された値の復元・gh 不在の 97・LASTEXITCODE の伝播）"
grep -q '^wsl .*| conv=\*$' "$WORK/fake.log" || fail "(21) Windows で MSYS2_ARG_CONV_EXCL を止めていない"
ok "(21) PowerShell の文面（gh 不在の 97・LASTEXITCODE の伝播）と引数変換の停止"

# (22) 不正な引数は rc 1
run windows "$FULL" -- --hostname 'a;b'
expect_rc 1 "(22) 不正なホスト名"
run windows "$FULL" -- --no-such-option
expect_rc 1 "(22) 未知の引数"
run windows "$FULL" -- login --approve-wait x
expect_rc 1 "(22) 秒数でない --approve-wait"
run windows "$FULL" -- --probe-timeout 0
expect_rc 1 "(22) --probe-timeout 0（GNU timeout では上限なしになる）"
run windows "$FULL" -- login --approve-wait 99999999999999999999
expect_rc 1 "(22) 桁あふれの --approve-wait"
run windows "$FULL" -- --help
expect_rc 0 "(22) --help"
ok "(22) 不正なホスト名・未知の引数・0 / 桁あふれ / 秒数でない待ち時間は rc 1、--help は rc 0"

# (23) login: one-time code と URL を出し、承認後に read-back。トークン様の文字列を出さず、
# 既定では gh の出力を残さない。--log のファイルはトークン様の文字列を伏せて残す
run windows "$FULL" FAKE_GH_LOGIN_SLEEP=1 GH_DEBUG=api -- login
expect_rc 0 "(23) login"
has 'DEVICE_CODE=ABCD-1234' && has 'DEVICE_URL=https://github.com/login/device' || fail "(23) コードか URL が出ない（コードの行以外の XXXX-XXXX を拾っていないか）"
has 'READBACK=ok tester' || fail "(23) read-back が出ない"
! has 'gho_' || fail "(23) gh の出力のトークン様の文字列を転記した"
! has 'DEVICE_LOG=' || fail "(23) --log なしで gh の出力の置き場を出した"
grep -F -q 'gh auth login --hostname github.com --git-protocol https --web | prompt=1 debug=unset/unset' "$WORK/fake.log" \
  || fail "(23) gh auth login の起動形が違う（GH_PROMPT_DISABLED=1・GH_DEBUG / DEBUG を外す）"
has 'LOGIN_RC=0' || fail "(23) 背景実行で rc を受け取れないホスト向けの LOGIN_RC= 行が無い"
grep -F -q 'gh api --hostname github.com user --jq .login' "$WORK/fake.log" || fail "(23) read-back を gh api user で行っていない"
[ -z "$(ls -A "$WORK/tmp")" ] || fail "(23) 一時領域に gh の出力が残った: $(ls -A "$WORK/tmp")"
run windows "$FULL" -- login --log "$WORK/login.log"
expect_rc 0 "(23) login --log"
has "DEVICE_LOG=$WORK/login.log" || fail "(23) --log の置き場を出さない"
! grep -q 'gho_' "$WORK/login.log" && grep -F -q 'debug: ***' "$WORK/login.log" || fail "(23) --log のファイルでトークン様の文字列を伏せていない"
ok "(23) login はコードと URL だけを出し、gh api user で read-back する（gh の出力は残さないか伏せて残す）"

# (24) login: コードを出さずに gh が終わる → rc 2
run windows "$FULL" FAKE_GH_LOGIN=nocode -- login --log "$WORK/login-nocode.log"
expect_rc 2 "(24) コード無しの終了"
has 'one-time code を読み取れませんでした' || fail "(24) コードを読み取れない旨が出ない"
! grep -q 'gho_' "$WORK/login-nocode.log" && grep -F -q 'debug: ***' "$WORK/login-nocode.log" || fail "(24) コードが出ない経路で --log のファイルを伏せていない"
ok "(24) コードを読み取れない login は rc 2（--log は伏せて残す）"

# (25) login: コードが出ないまま待ち続ける gh は上限で止め、gh を残さない
started=$SECONDS
run windows "$FULL" FAKE_GH_LOGIN=hang FAKE_GH_PIDFILE="$WORK/gh.pid" -- login --code-wait 1
expect_rc 2 "(25) 待ち続ける gh"
[ $((SECONDS - started)) -lt 25 ] || fail "(25) --code-wait の上限で止まらない"
[ -s "$WORK/gh.pid" ] || fail "(25) 偽の gh が pid を残していない"
! kill -0 "$(cat "$WORK/gh.pid")" 2>/dev/null || fail "(25) 止めたはずの gh auth login が生きている"
ok "(25) コードが出ない gh は --code-wait で打ち切って止め、rc 2"

# (26) login: 承認後の read-back が 401 なら rc 3
run windows "$FULL" FAKE_GH_MODE=401 -- login
expect_rc 3 "(26) read-back の 401"
has 'READBACK=broken' || fail "(26) read-back の結果が出ない"
ok "(26) read-back が ok にならない login は rc 3"

# (27) login: GH_TOKEN / GITHUB_TOKEN があると device flow を起動しない
for var in GH_TOKEN GITHUB_TOKEN; do
  run windows "$FULL" "$var=bogus" -- login
  expect_rc 1 "(27) ${var} あり"
  ! grep -q '^gh auth login' "$WORK/fake.log" || fail "(27) ${var} ありで gh auth login を起動した"
done
ok "(27) GH_TOKEN / GITHUB_TOKEN があると login は起動前に止まる"

# (28) Windows の timeout.exe（GNU と引数の形が違う同名のコマンド）が選ばれても、全文脈を失敗に化けさせない
SYS2="$WORK/sys2"
mkdir -p "$SYS2"
cp "$SYS"/* "$SYS2/"
printf '#!/bin/sh\necho "ERROR: Invalid syntax. Default option is not allowed more than 1 time(s)." >&2\nexit 1\n' > "$SYS2/timeout"
chmod +x "$SYS2/timeout"
run windows "$GHBIN:$WINBIN:$SYS2"
expect_rc 0 "(28) timeout.exe が先に選ばれる PATH"
row bash ok && row powershell ok && row 'wsl（Ubuntu）' ok || fail "(28) timeout.exe を GNU の timeout として使った"
ok "(28) GNU の形で動かない timeout は使わずに測る"

# (29) rc 0 でログイン名が読めた回は、警告文に HTTP 401 が混ざっても ok
run windows "$FULL" FAKE_GH_MODE=okwarn
expect_rc 0 "(29) 成功時の警告文"
row bash ok || fail "(29) 成功した回を警告文の文言で要復旧にした"
ok "(29) 成功（rc 0）は文言で要復旧にしない"

# (30) rc 0 でも null（login の無い応答）は ok にしない
run windows "$FULL" FAKE_GH_MODE=null
expect_rc 2 "(30) null"
row bash 判定不能 || fail "(30) null が ok になった"
ok "(30) null は判定不能"

# (31) タイムアウト（rc 124）と、stdout にログイン名がある失敗（rc 1）は判定不能
run windows "$FULL" FAKE_GH_MODE=timeout
expect_rc 2 "(31) タイムアウト"
row bash 判定不能 && has '応答がありません' || fail "(31) タイムアウトが判定不能にならない"
run windows "$FULL" FAKE_GH_MODE=fail1
expect_rc 2 "(31) rc 1 の失敗"
row bash 判定不能 || fail "(31) rc 1 の失敗が ok になった"
run windows "$FULL" FAKE_GH_MODE=killed137
expect_rc 2 "(31) KILL で終わった gh（rc 137）"
row bash 判定不能 && has '応答がありません' || fail "(31) rc 137 が応答なしの判定不能にならない"
ok "(31) タイムアウト（124 / 137）と、出力があっても rc が非 0 の回は判定不能"

# (31b) Enterprise Managed Users のログイン名（`_` を含む）も ok
run windows "$FULL" FAKE_GH_MODE=emu
expect_rc 0 "(31b) EMU のログイン名"
grep -q "^bash	ok	tester_acme\$" "$WORK/out" || fail "(31b) EMU のログイン名を読めない"
ok "(31b) Enterprise Managed Users のログイン名（handle_shortcode）を ok と読む"

# (32) WSL の通知行が distro= より前に出ても、WSL 側の結果を読む
run windows "$FULL" FAKE_WSL_NOTICE=1 FAKE_WSL_GH_MODE=401
expect_rc 3 "(32) WSL の通知行"
row 'wsl（Ubuntu）' 要復旧 || fail "(32) 通知行のせいで WSL の 401 を落とした"
ok "(32) wsl.exe の通知行は読み飛ばす"

# (33) ディストリ名が空なら復旧の案内から -d を省く
run windows "$FULL" FAKE_WSL_DEFAULT= FAKE_WSL_GH_MODE=401
expect_rc 3 "(33) 空のディストリ名"
row wsl 要復旧 || fail "(33) 空のディストリ名で wsl 行が要復旧にならない"
has 'wsl -- gh auth login -h github.com -w' && ! has 'wsl -d  --' || fail "(33) 空のディストリ名で壊れた -d を案内した"
ok "(33) 空のディストリ名は -d を省いて案内する"

# (34) 文字種の外のディストリ名は案内へ埋め込まず判定不能
run windows "$FULL" 'FAKE_WSL_DEFAULT=Bad;Name' FAKE_WSL_GH_MODE=401
expect_rc 2 "(34) 不正なディストリ名"
row wsl 判定不能 && has 'WSL のディストリ名を読み取れません' || fail "(34) 不正なディストリ名が判定不能にならない"
! has 'Bad;Name' || fail "(34) 不正なディストリ名を出力へ埋め込んだ"
ok "(34) 文字種の外のディストリ名は判定不能"

# (35) WSL の gh が ~/.local/bin にだけある（ログインプロファイルを読まない --exec でも見つける）
mkdir -p "$WORK/wslhome/.local/bin"
cp "$GHBIN/gh" "$WORK/wslhome/.local/bin/gh"
run windows "$FULL" FAKE_WSL_GH=absent FAKE_WSL_HOME="$WORK/wslhome"
expect_rc 0 "(35) ~/.local/bin の gh"
row 'wsl（Ubuntu）' ok || fail "(35) ~/.local/bin の gh を見つけられない"
ok "(35) WSL の ~/.local/bin の gh を測る"

# (36) GITHUB_TOKEN だけでも環境変数の案内にし、PowerShell へは gh の参照先を変える変数を渡さない
run windows "$FULL" GITHUB_TOKEN=bogus GH_CONFIG_DIR=/x XDG_CONFIG_HOME=/y FAKE_GH_MODE=401
has '復旧（bash）: このシェルの GH_TOKEN / GITHUB_TOKEN が無効です' || fail "(36) GITHUB_TOKEN だけのとき環境変数の案内にならない"
grep -q '^powershell .*| env=unset/unset/unset/unset/unset/unset/unset$' "$WORK/fake.log" || fail "(36) PowerShell へ GITHUB_TOKEN / GH_CONFIG_DIR / XDG_CONFIG_HOME を引き継いだ"
run windows "$FULL" GH_ENTERPRISE_TOKEN=a GITHUB_ENTERPRISE_TOKEN=b GH_HOST=c
grep -q '^powershell .*| env=unset/unset/unset/unset/unset/unset/unset$' "$WORK/fake.log" || fail "(36) PowerShell へ GHES のトークン / GH_HOST を引き継いだ"
ok "(36) GITHUB_TOKEN 単独も環境変数の案内。PowerShell へは gh の参照先を変える変数を渡さない"

# (37) GitHub Enterprise Server では GH_ENTERPRISE_TOKEN を見て、GH_TOKEN では login を止めない
run windows "$FULL" GH_ENTERPRISE_TOKEN=bogus FAKE_GH_MODE=401 -- --hostname ghe.example.com
has '復旧（bash）: このシェルの GH_ENTERPRISE_TOKEN / GITHUB_ENTERPRISE_TOKEN が無効です' || fail "(37) GHES で GH_ENTERPRISE_TOKEN の案内にならない"
run windows "$FULL" GH_TOKEN=for-github-com -- login --hostname ghe.example.com
expect_rc 0 "(37) GHES の login（GH_TOKEN あり）"
grep -F -q 'gh auth login --hostname ghe.example.com' "$WORK/fake.log" || fail "(37) GHES の login を GH_TOKEN で止めた"
for var in GH_ENTERPRISE_TOKEN GITHUB_ENTERPRISE_TOKEN; do
  run windows "$FULL" "$var=bogus" -- login --hostname ghe.example.com
  expect_rc 1 "(37) GHES の login（${var} あり）"
done
run windows "$FULL" GH_TOKEN=bogus -- login --hostname acme.ghe.com
expect_rc 1 "(37) *.ghe.com の login（GH_TOKEN あり）"
run windows "$FULL" GH_TOKEN=bogus -- login --hostname GitHub.com
expect_rc 1 "(37) 大文字のホスト名の login（GH_TOKEN あり）"
run windows "$FULL" -- --hostname GitHub.COM
has 'gh の認証（github.com）' || fail "(37) ホスト名を小文字へ揃えていない"
ok "(37) GHES は GH_ENTERPRISE_TOKEN / GITHUB_ENTERPRISE_TOKEN、*.ghe.com と github.com（大文字を含む）は GH_TOKEN / GITHUB_TOKEN で判定する"

# (38) login: コードを出したまま承認を待ち続ける gh は --approve-wait で止め、read-back で決める
started=$SECONDS
run windows "$FULL" FAKE_GH_LOGIN=codehang FAKE_GH_MODE=401 FAKE_GH_PIDFILE="$WORK/gh2.pid" -- login --approve-wait 1
expect_rc 3 "(38) 承認待ちの打ち切り（read-back 401）"
[ $((SECONDS - started)) -lt 25 ] || fail "(38) --approve-wait で打ち切らず gh の自然終了を待った"
has 'DEVICE_CODE=ABCD-1234' && has '止めました' || fail "(38) 承認待ちを打ち切った旨が出ない"
[ -s "$WORK/gh2.pid" ] && ! kill -0 "$(cat "$WORK/gh2.pid")" 2>/dev/null || fail "(38) 承認待ちの gh auth login が生きている"
ok "(38) 承認待ちは --approve-wait で打ち切って gh を止め、read-back が ok でなければ rc 3"

# (39) --hostname は 3 文脈の gh と復旧の案内へ渡る
run windows "$FULL" FAKE_GH_MODE=401 FAKE_PS_MODE=401 FAKE_WSL_GH_MODE=401 -- --hostname ghe.example.com
expect_rc 3 "(39) GHES の 3 文脈 401"
[ "$(grep -c '^gh api --hostname ghe.example.com user' "$WORK/fake.log")" -eq 3 ] || fail "(39) 3 文脈のどれかが github.com を測った"
has 'gh の認証（ghe.example.com）' || fail "(39) 見出しにホスト名が出ない"
has 'login --hostname ghe.example.com' && has '利用者の PowerShell で gh auth login -h ghe.example.com -w' \
  && has 'wsl -d Ubuntu -- gh auth login -h ghe.example.com -w' || fail "(39) 復旧の案内にホスト名が渡らない"
ok "(39) --hostname は 3 文脈の測定と復旧の案内へ渡る"

# (40) PowerShell / WSL のコマンドへ入るホスト名は、記号を 1 つでも含めば起動前に止める
for bad in 'a b' 'a|b' 'a&b' 'a$(x)' 'a"b' "a'b" 'a`b' 'a/b'; do
  run windows "$FULL" -- --hostname "$bad"
  expect_rc 1 "(40) ホスト名 ${bad}"
  [ ! -s "$WORK/fake.log" ] || fail "(40) ホスト名 ${bad} で何かを起動した"
done
ok "(40) 記号を含むホスト名は何も起動せずに rc 1"

# (41) --wsl-distro も記号を含めば起動前に止める
for bad in 'a;b' 'a b'; do
  run windows "$FULL" -- --wsl-distro "$bad"
  expect_rc 1 "(41) ディストリ名 ${bad}"
  ! grep -q '^wsl ' "$WORK/fake.log" || fail "(41) ディストリ名 ${bad} で wsl.exe を起動した"
done
ok "(41) 記号を含む --wsl-distro は rc 1"

# (42) 環境変数のトークンの案内はこのシェルの行だけ。PowerShell / WSL の 401 は通常の復旧を案内する
run windows "$FULL" GH_TOKEN=bogus FAKE_PS_MODE=401 FAKE_WSL_GH_MODE=401
has '復旧（powershell）: 利用者の PowerShell で gh auth login -h github.com -w' && has '復旧（wsl）: 利用者の PowerShell から wsl -d Ubuntu --' \
  || fail "(42) PowerShell / WSL の 401 に通常の復旧が出ない"
! has '復旧（powershell）: このシェルの' && ! has '復旧（wsl）: このシェルの' || fail "(42) 環境変数の案内を PowerShell / WSL へ出した"
ok "(42) 環境変数のトークンの案内はこのシェルの行だけ"

# (43) 既定以外のディストリの復旧はそのディストリを -d で名指しする
run windows "$FULL" FAKE_WSL_GH_MODE=401 -- --wsl-distro Debian
has 'wsl -d Debian -- gh auth login -h github.com -w' && has 'wsl -d Debian -- gh auth setup-git' || fail "(43) 既定以外のディストリの復旧が名指ししない"
ok "(43) 既定以外のディストリは -d でそのディストリを案内する"

# (44) powershell.exe が無ければ pwsh.exe で測る
mkdir -p "$WORK/winbin-pwsh"
cp "$WINBIN/powershell.exe" "$WORK/winbin-pwsh/pwsh.exe"
cp "$WINBIN/wsl.exe" "$WORK/winbin-pwsh/"
run windows "$GHBIN:$WORK/winbin-pwsh:$SYS"
expect_rc 0 "(44) pwsh.exe だけ"
row powershell ok || fail "(44) pwsh.exe で測らない"
ok "(44) powershell.exe が無ければ pwsh.exe で測る"

# (45) 応答しない gh は --probe-timeout で打ち切って判定不能（GNU の timeout が無いホストでは上限なしで待つ契約なので、判定不能だけを見る）
started=$SECONDS
run windows "$FULL" FAKE_GH_MODE=hang FAKE_PS_MODE=ok -- --probe-timeout 1
expect_rc 2 "(45) 応答しない gh"
row bash 判定不能 || fail "(45) 応答しない gh が判定不能にならない"
if command -v timeout >/dev/null 2>&1 && timeout --version < /dev/null > /dev/null 2>&1; then
  has '応答がありません（1 秒で打ち切り）' || fail "(45) 打ち切りの理由が出ない"
  [ $((SECONDS - started)) -lt 25 ] || fail "(45) --probe-timeout で打ち切らない"
fi
ok "(45) 応答しない gh は --probe-timeout で打ち切って判定不能"

# (46) login の承認待ち中に SUT 自身が TERM で止められても、EXIT trap が gh を止め、--log を伏せ、
# LOGIN_RC= を出す（ホストのタスク停止・Ctrl-C の経路）
: > "$WORK/fake.log"
rm -f "$WORK/gh3.pid"
env -i HOME="$WORK" TMPDIR="$WORK/tmp" PATH="$FULL" BASH_ENV="$WORK/env-windows.sh" \
  FAKE_LOG="$WORK/fake.log" FAKE_GHBIN="$GHBIN" FAKE_SYS="$SYS" FAKE_GH_LOGIN=codehang FAKE_GH_PIDFILE="$WORK/gh3.pid" \
  "$BASH_BIN" "$SUT" login --log "$WORK/login3.log" < /dev/null > "$WORK/out" 2>&1 &
sut=$!
n=0
until grep -q '^DEVICE_CODE=' "$WORK/out" || [ "$n" -ge 60 ]; do sleep 0.5; n=$((n + 1)); done
grep -q '^DEVICE_CODE=' "$WORK/out" || fail "(46) DEVICE_CODE が出る前に止まった"
kill -TERM "$sut"
RC=0
wait "$sut" || RC=$?
expect_rc 143 "(46) TERM で止めた login"
has 'LOGIN_RC=143' || fail "(46) LOGIN_RC= 行が出ない"
[ -s "$WORK/gh3.pid" ] && ! kill -0 "$(cat "$WORK/gh3.pid")" 2>/dev/null || fail "(46) SUT を止めたのに gh auth login が生きている"
! grep -q 'gho_' "$WORK/login3.log" || fail "(46) 途中で止めた回の --log を伏せていない"
[ -z "$(ls -A "$WORK/tmp")" ] || fail "(46) 一時領域が残った"
ok "(46) 承認待ちで止められても EXIT trap が gh を止め、--log を伏せ、LOGIN_RC= を出す"

# (47) TERM を無視する gh は KILL で止める
started=$SECONDS
run windows "$FULL" FAKE_GH_LOGIN=codehang_noterm FAKE_GH_PIDFILE="$WORK/gh4.pid" -- login --approve-wait 1
[ $((SECONDS - started)) -lt 25 ] || fail "(47) TERM を無視する gh で止まらない"
[ -s "$WORK/gh4.pid" ] && ! kill -0 "$(cat "$WORK/gh4.pid")" 2>/dev/null || fail "(47) TERM を無視する gh が生きている（KILL へ昇格していない）"
ok "(47) TERM を無視する gh は KILL で止める"

echo "gh-auth-doctor: ${PASS} 件 pass"
FF_REACHED_END=1
