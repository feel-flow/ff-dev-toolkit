#!/usr/bin/env bash
# gh の認証を文脈ごとに `gh api user` で測る診断と、device flow での再ログイン。bash 3.2 対応。
set -euo pipefail

# Windows の作業機では gh が 3 つの文脈（このシェル = Claude の Bash ツール / PowerShell / WSL）で
# 別々に認証されうる。keyring 保存では hosts.yml に差が出ず、`gh auth status` の文言も当てに
# ならないので、見分ける手段は各文脈で `gh api user` を実際に呼ぶことだけ。判定は終了コードと
# 実出力の両方で行い、判定材料が揃わない回（コマンド不在・タイムアウト・空出力）は ok にしない。
# ff-dev-toolkit-script-root-guard:start
# plugin root 固定ガード（script 側）。同じ停止を skill 本文の契約節も述べているが、
# ホストが実行部だけを解決済み絶対 path として注入し契約節が本文から落ちた経路では、
# 散文のガードはちょうどそのとき手元に無い（防御が守ろうとしている失敗と、防御が
# 失われる条件が同じ）。実行部と同じファイルへ置くことで、契約を読んでいない consumer
# でも止まる。**候補は探しに行かない** — cache / marketplace / 旧インストール領域の
# 走査も version 名の並べ替えによる選び直しもしない。それが本ガードの防ごうとしている
# 失敗そのもので、探索を足すと防御が防御対象を踏む。渡された handoff を canonical 化
# して自分の実体位置と比べるだけにする。handoff が 1 つも無い直接起動（端末・テスト・
# CI の pin 実行）は止めない — 比較対象が無い状態を不一致とみなすと、正規の直接起動が
# 全部止まる。
#
# 到達性は呼び出し側とセットで成り立つ。host は plugin root を Bash tool の環境へ
# export せず、実行部テキストへ解決済みの値を差し込むだけなので、handoff を運ぶのが
# skill 本文の resolver だけだと「本文が落ちた」ちょうどそのときに handoff も消え、
# ガードは比較対象なしで素通しになる。そこで固定 root 経由の実行部は
# `FF_DEV_TOOLKIT_ROOT="${FF_DEV_TOOLKIT_ROOT}" bash "${FF_DEV_TOOLKIT_ROOT}/scripts/<名>"`
# の形にして handoff を**同じ 1 行へ**載せる。実行するスクリプトの path だけを別領域へ
# 書き換える事故は、この 1 行の中の不一致として検出できる。
#
# 判定不能は素通しではなく停止に倒す（fail-closed）。更新中の部分的な消失では、
# 判定材料（別 plugin かどうかを言う manifest）そのものが壊れた領域の内側にある。
#
# 外部コマンドを使わない。PATH が壊れた環境はこのガードが最後の砦になる場面そのもので、
# dirname / grep / sed に依存すると「自分の位置を判定できないまま素通し」になる。
# その代わり builtin 側の環境依存を自分で閉じる: path の canonical 化はすべて
# `CDPATH= cd -P --` で行う。`cd` は CDPATH が効くと**別のdirectoryへ移動したうえで
# 移動先を stdout へ出す**ので、export された CDPATH に同名の subdirectory があると
# 相対起動（`bash scripts/<名>`）で自分の位置を取り違え、コマンド置換も 2 行になる。
# 「止めない」と明文で約束している端末・テスト・CI の直接起動が、正規の handoff 付き
# でも止まっていた。各 script の複製は byte 一致で、tests/plugin-root-contract が固定する。
ff_script_root_guard_manifest_field() { # <plugin.json> <キー> → 値をstdoutへ / 読めなければ非0
  # JSON を「文字列の外 / 中」に分けて走査し、**root object 直下（ネスト深さ 1）のキー**
  # だけを返す。行単位に最初の `"<キー>"` を拾う形だと、`author` のような入れ子 object が
  # top-level の `name` より前にある manifest で `author.name` を掴み、別 plugin と誤読して
  # 照合ごと飛ばす（= fail-open）。同じ判定を docs-template の resolver fence の awk も
  # 「`{` 直後の name marker」として要求しており、厳しさを揃える。fence と違って version も
  # 読むので「最初のキー」ではなく「深さ 1 のキー」に寄せる。
  local file="$1" key="$2" line="" rest="" seg="" tmp="" acc=""
  local depth=0 instr=0 expect=0 last="" bs=0
  # symlink・非通常ファイル・読めないものは「確認できない」に倒す（除外の根拠にしない）。
  [ -f "$file" ] && [ ! -L "$file" ] && [ -r "$file" ] || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    rest="$line"
    while [ -n "$rest" ]; do
      if [ "$instr" -eq 1 ]; then
        case "$rest" in
          *'"'*) seg="${rest%%'"'*}"; rest="${rest#*'"'}" ;;
          *) acc="${acc}${rest}"; rest=""; continue ;;
        esac
        # 直前が奇数個の backslash なら、その `"` は escape されていて文字列は続く。
        tmp="$seg"; bs=0
        while [ "${tmp%\\}" != "$tmp" ]; do bs=$((bs + 1)); tmp="${tmp%\\}"; done
        acc="${acc}${seg}"
        if [ $((bs % 2)) -eq 1 ]; then acc="${acc}\""; continue; fi
        instr=0
        if [ "$expect" -eq 1 ]; then printf '%s' "$acc"; return 0; fi
        last="$acc"; acc=""
        continue
      fi
      case "$rest" in
        *'"'*) seg="${rest%%'"'*}"; rest="${rest#*'"'}"; instr=1; acc="" ;;
        *) seg="$rest"; rest="" ;;
      esac
      # 深さは文字列の外に出た構造文字だけで数える（値の中の括弧に釣られない）。
      tmp="$seg"
      while [ "${tmp#*'{'}" != "$tmp" ]; do depth=$((depth + 1)); tmp="${tmp#*'{'}"; done
      tmp="$seg"
      while [ "${tmp#*'['}" != "$tmp" ]; do depth=$((depth + 1)); tmp="${tmp#*'['}"; done
      tmp="$seg"
      while [ "${tmp#*'}'}" != "$tmp" ]; do depth=$((depth - 1)); tmp="${tmp#*'}'}"; done
      tmp="$seg"
      while [ "${tmp#*']'}" != "$tmp" ]; do depth=$((depth - 1)); tmp="${tmp#*']'}"; done
      case "$seg" in
        *:*) if [ "$depth" -eq 1 ] && [ -n "$last" ] && [ "$last" = "$key" ]; then expect=1; fi ;;
      esac
      # 値が object / array なら、次に閉じる文字列はその中身であって値ではない。
      case "$seg" in
        *'{'*|*'['*|*,*) expect=0 ;;
      esac
      last=""
    done
  done < "$file"
  return 1
}
ff_assert_script_plugin_root() {
  local self="${1:-}" dir="" root="" var="" value="" canonical="" used="" skipped="" other="" version="" quiet=0
  [ -n "$self" ] || { echo "❌ 起動したスクリプトの実体位置を取得できません" >&2; return 1; }
  case "$self" in */*) dir="${self%/*}" ;; *) dir="." ;; esac
  dir="$(CDPATH= cd -P -- "$dir" 2>/dev/null && pwd -P)" || dir=""
  [ -n "$dir" ] || { echo "❌ 起動したスクリプトのdirectoryを解決できません: ${self}" >&2; return 1; }
  root="$(CDPATH= cd -P -- "${dir}/.." 2>/dev/null && pwd -P)" || root=""
  [ -n "$root" ] || { echo "❌ 自分のplugin rootを解決できません: ${dir}" >&2; return 1; }
  self="${dir}/${self##*/}"
  # スクリプト自身がsymlinkなら止める。親directoryしかcanonical化しないと、期待root内の
  # symlinkから別checkoutの実体を実行でき、「実体位置とhandoffの照合」の前提が崩れる。
  if [ -L "$self" ]; then
    {
      echo "❌ ff-dev-toolkit更新後にこのskillを再呼び出してください（起動したスクリプトがsymlinkです）"
      echo "   起動したスクリプト: ${self}"
      echo "   symlinkは期待rootの内側から別領域の実体を指せるため、実体位置の照合が成立しません。"
      echo "   別のインストール領域へ切り替えて実行しないこと — version混在と未リリースWIPの実行になります。"
      echo "   cacheや別checkoutを探さず、実体のパスで起動してください。"
    } >&2
    return 1
  fi
  for var in FF_DEV_TOOLKIT_ROOT CLAUDE_PLUGIN_ROOT GROK_PLUGIN_ROOT; do
    eval "value=\${${var}:-}"
    [ -n "$value" ] || continue
    canonical="$(CDPATH= cd -P -- "$value" 2>/dev/null && pwd -P)" || canonical=""
    # 正規形は plugin root だが、scripts/ を直接指す綴りも正規に受理されている
    # （templates/codex-review.sh の canonical_toolkit_root が両方を受ける）。同じ実体を
    # 指している限り一致として扱う。
    if [ -n "$canonical" ] && { [ "$canonical" = "$root" ] || [ "$canonical" = "$dir" ]; }; then
      [ -n "$used" ] || used="$var"
      continue
    fi
    # 実在する別 plugin の root は我々への handoff ではない（別 plugin 経由の正規呼び出し
    # まで殺さない）。ただし除外できるのは「manifestが通常ファイルとして読めて、名前が別だと
    # 確認できた」ときだけにする。消えているroot も、読めないmanifest も、誰のものか判定
    # できない点は同じ。
    other=""
    if [ -n "$canonical" ]; then
      other="$(ff_script_root_guard_manifest_field "${canonical}/.claude-plugin/plugin.json" name)" || other=""
    fi
    if [ -n "$other" ] && [ "$other" != "ff-dev-toolkit" ]; then
      skipped="${skipped:+${skipped} }${var}=別plugin(${other})"
      continue
    fi
    {
      echo "❌ ff-dev-toolkit更新後にこのskillを再呼び出してください（plugin rootが固定値と一致しません）"
      echo "   起動したスクリプト: ${self}"
      echo "   このスクリプトのplugin root: ${root}"
      echo "   hostが渡したroot（${var}）: ${value}"
      if [ -z "$canonical" ]; then
        echo "   不一致の内容: 指しているdirectoryが実在しません（plugin rootが消えています）"
      elif [ -z "$other" ]; then
        echo "   不一致の内容: 指す先のplugin manifestを読めず、誰のrootか判定できません（判定不能は停止に倒します）"
      else
        echo "   不一致の内容: このスクリプトは別のインストール領域の実体です"
      fi
      echo "   別のインストール領域へ切り替えて実行しないこと — version混在と未リリースWIPの実行になります。"
      echo "   cacheや別checkoutを探さず、pluginを再導入してからskillを呼び直してください。"
    } >&2
    return 1
  done
  # provenance（実体 path と version の 1 行）は「想定外の場所から起動された」ことを
  # agent にもログを読む人にも見せて診断コストを下げる。照合を飛ばした handoff も理由付きで
  # 出す — 渡っていた事実を「なし・直接起動」と報告すると、診断価値を損ない事実とも食い違う。
  # 出力そのものが契約になっている script（成功時は無出力・stderr を混ぜない等）では情報行が
  # 契約違反になるので、その basename だけを**この block 内の allowlist**で抑止する。
  # 外から env で抑止できる形にすると allowlist が実効的な制約にならないので、環境変数では
  # 抑止できない。抑止できるのは provenance だけで、停止の判定と案内は抑止できない。
  case "${self##*/}" in
    check-merge-freshness.sh|check-plugin-versions.sh) quiet=1 ;;
  esac
  if [ "$quiet" -ne 1 ]; then
    version="$(ff_script_root_guard_manifest_field "${root}/.claude-plugin/plugin.json" version)" || version=""
    echo "ℹ️  ff-dev-toolkit ${version:-version不明} — 実行実体: ${self}（handoff: ${used:-なし・直接起動}${skipped:+ / 照合対象外: ${skipped}}）" >&2
  fi
  return 0
}
ff_assert_script_plugin_root "${BASH_SOURCE[0]}" || exit 1
# ff-dev-toolkit-script-root-guard:end
# 中断コードが 1 なのは、本スクリプトの 2 / 3 が判定結果（判定不能が残った / 要復旧の文脈が
# ある）だから。ガードの停止は判定ではなく中断なので 1 を使う。

SCRIPT_PATH="$(CDPATH= cd -P -- "$(dirname "$0")" && pwd -P)/$(basename "$0")"
MODE=diagnose
GH_HOST_NAME=github.com
WSL_DISTRO=""
LOG_FILE=""
CODE_WAIT=60
APPROVE_WAIT=960
PROBE_TIMEOUT=60
usage() {
  echo 'Usage: gh-auth-doctor.sh [diagnose] [--hostname HOST] [--wsl-distro NAME] [--probe-timeout SECONDS]'
  echo '       gh-auth-doctor.sh login [--hostname HOST] [--log FILE] [--code-wait SECONDS] [--approve-wait SECONDS]'
  echo 'Exit（diagnose）: 0=全文脈 ok, 3=要復旧の文脈あり, 2=判定不能が残った（要復旧なし）, 1=起動不能/不正引数'
  echo 'Exit（login）: 0=read-back で認証を確認, 3=read-back が ok にならない, 2=one-time code を読み取れない, 1=起動不能/不正引数/環境変数のトークンあり'
}
case "${1:-}" in
  diagnose|login) MODE="$1"; shift ;;
esac
while [ "$#" -gt 0 ]; do
  case "$1" in
    --hostname|--wsl-distro|--log|--code-wait|--approve-wait|--probe-timeout)
      [ "$#" -ge 2 ] && [ -n "$2" ] || { usage >&2; exit 1; }
      case "$1" in
        --hostname) GH_HOST_NAME="$2" ;;
        --wsl-distro) WSL_DISTRO="$2" ;;
        --log) LOG_FILE="$2" ;;
        --code-wait) CODE_WAIT="$2" ;;
        --approve-wait) APPROVE_WAIT="$2" ;;
        --probe-timeout) PROBE_TIMEOUT="$2" ;;
      esac
      shift 2 ;;
    --help|-h) usage; exit 0 ;;
    *) usage >&2; exit 1 ;;
  esac
done
# ホスト名とディストリ名は PowerShell / WSL へ渡すコマンドと復旧の案内に入るので、文字種を閉じてから使う。
case "$GH_HOST_NAME" in
  ''|*[!A-Za-z0-9.:-]*) echo "ホスト名の形が不正です: ${GH_HOST_NAME}" >&2; exit 1 ;;
esac
# gh はホスト名を小文字で扱うので、環境変数の判定と案内も小文字へ揃える（bash 3.2 に ${,,} は無い）。
GH_HOST_NAME="$(printf '%s' "$GH_HOST_NAME" | tr '[:upper:]' '[:lower:]')"
case "$WSL_DISTRO" in
  *[!A-Za-z0-9._-]*) echo "ディストリ名の形が不正です: ${WSL_DISTRO}" >&2; exit 1 ;;
esac
# 0 は GNU timeout では「上限なし」になり、桁あふれは [ -lt ] を壊すので、1〜6 桁の正の整数に閉じる。
for value in "$CODE_WAIT" "$APPROVE_WAIT" "$PROBE_TIMEOUT"; do
  case "$value" in
    ''|*[!0-9]*|0*|???????*) echo "--code-wait / --approve-wait / --probe-timeout は 1〜999999 の秒数で指定してください: ${value}" >&2; exit 1 ;;
  esac
done

WORK="$(mktemp -d "${TMPDIR:-/tmp}/gh-auth-doctor.XXXXXX")"
LOGIN_PID=""
# 背景で起動した gh auth login は、どの経路で抜けても止める（残すと承認されたときに資格情報だけが
# 裏で書き換わる）。TERM で止まらなければ KILL を送り、それでも残れば黙らずに知らせる。
stop_login() {
  local n=0
  [ -n "$LOGIN_PID" ] || return 0
  if kill -0 "$LOGIN_PID" 2>/dev/null; then
    if ! kill "$LOGIN_PID" 2>/dev/null; then :; fi
    while kill -0 "$LOGIN_PID" 2>/dev/null && [ "$n" -lt 5 ]; do sleep 1; n=$((n + 1)); done
    if kill -0 "$LOGIN_PID" 2>/dev/null; then
      if ! kill -9 "$LOGIN_PID" 2>/dev/null; then :; fi
      sleep 1
      if kill -0 "$LOGIN_PID" 2>/dev/null; then
        echo "⚠️ gh auth login（pid ${LOGIN_PID}）を止められませんでした。利用者には承認しないよう伝え、プロセスを手で止めてください" >&2
      fi
    fi
  fi
  LOGIN_PID=""
}
# login は承認待ちで長く生きるので、ホストのタスク停止・Ctrl-C でも EXIT trap を通して gh を止め、
# --log のファイルを伏せ字にしてから抜ける。背景実行で rc を受け取れないホスト向けに LOGIN_RC= を出す。
cleanup() {
  local rc=$?
  stop_login
  if [ "$MODE" = login ] && [ -n "$LOG_FILE" ]; then
    mask_tokens "$LOG_FILE" || echo "⚠️ --log の伏せ字に失敗しました: ${LOG_FILE}" >&2
  fi
  rm -rf "$WORK"
  [ "$MODE" != login ] || echo "LOGIN_RC=${rc}"
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM
STATE=""
DETAIL=""

# coreutils の timeout があれば上限を付ける。Windows には引数の形が違う同名の timeout.exe（指定秒数を
# 待つだけのコマンド）があり、PATH の順序でそちらが選ばれると全文脈が失敗に化けるので、GNU 版かを
# `--version` で起動時に 1 回だけ確かめる（timeout.exe は --version を拒否する）。macOS の既定には
# 無いので、無ければ上限なしで待つ。
TIMEOUT_OK=0
if command -v timeout >/dev/null 2>&1 && timeout --version < /dev/null > /dev/null 2>&1; then TIMEOUT_OK=1; fi
with_timeout() {
  if [ "$TIMEOUT_OK" -eq 1 ]; then timeout -k 5 "$PROBE_TIMEOUT" "$@"; else "$@"; fi
}

# gh は github.com・*.ghe.com（と開発用の *.github.com・localhost・*.github.localhost）では
# GH_TOKEN / GITHUB_TOKEN を、それ以外の GitHub Enterprise Server では GH_ENTERPRISE_TOKEN /
# GITHUB_ENTERPRISE_TOKEN を、保存済みの資格情報より優先する。
is_github_host() {
  case "$GH_HOST_NAME" in
    github.com|*.ghe.com|*.github.com|localhost|*.github.localhost) return 0 ;;
    *) return 1 ;;
  esac
}
if is_github_host; then ENV_TOKEN_NAMES='GH_TOKEN / GITHUB_TOKEN'; else ENV_TOKEN_NAMES='GH_ENTERPRISE_TOKEN / GITHUB_ENTERPRISE_TOKEN'; fi
env_token_set() {
  if is_github_host; then
    [ -n "${GH_TOKEN:-}${GITHUB_TOKEN:-}" ]
  else
    [ -n "${GH_ENTERPRISE_TOKEN:-}${GITHUB_ENTERPRISE_TOKEN:-}" ]
  fi
}

# `gh api user --jq .login` の結果を ok / broken / unknown に分ける。終了コードで先に分け、文言は
# 失敗したときだけ見る（成功した回の警告文に `HTTP 401` が混ざっても要復旧にしない）。401 と未ログイン
# だけを要復旧（broken）と言い切り、それ以外の失敗（ネットワーク・レート制限・タイムアウト）と、
# 形の合わない成功（空出力・null・ログイン名でない文字列）は判定不能（unknown）に倒す。
classify() { # rc stdout-file stderr-file → STATE / DETAIL
  local rc="$1" out="" err="" line=""
  out="$(<"$2")"; err="$(<"$3")"
  out="${out//$'\r'/}"; err="${err//$'\r'/}"
  if [ "$rc" -eq 0 ]; then
    case "$out" in
      # ログイン名は英数字とハイフン。Enterprise Managed Users は `<handle>_<shortcode>` で `_` を含む。
      ''|null|*[!A-Za-z0-9_-]*) STATE=unknown; DETAIL='gh api user が成功を返しましたが、ログイン名を読み取れません' ;;
      *) STATE=ok; DETAIL="$out" ;;
    esac
    return 0
  fi
  case "$out$err" in
    *'HTTP 401'*|*'Bad credentials'*) STATE=broken; DETAIL='HTTP 401（Bad credentials）'; return 0 ;;
  esac
  # 資格情報が無いとき、gh は 4 で終わって定型文で gh auth login を促す（古い gh は 1 で同じ定型文を出す）。
  case "$rc:$out$err" in
    4:*|*'To get started with GitHub CLI, please run:'*|*'You are not logged into any GitHub hosts'*)
      STATE=broken; DETAIL='未ログイン（gh auth login が必要）'; return 0 ;;
  esac
  case "$rc" in
    124|137) STATE=unknown; DETAIL="応答がありません（${PROBE_TIMEOUT} 秒で打ち切り）"; return 0 ;;
  esac
  line="${err%%$'\n'*}"
  [ -n "$line" ] || line="${out%%$'\n'*}"
  STATE=unknown; DETAIL="gh api user が失敗しました（rc=${rc}${line:+: ${line:0:160}}）"
}

probe_shell() {
  local rc=0
  if ! command -v gh >/dev/null 2>&1; then STATE=unknown; DETAIL='gh が見つかりません（PATH）'; return 0; fi
  with_timeout gh api --hostname "$GH_HOST_NAME" user --jq .login < /dev/null > "$WORK/out" 2> "$WORK/err" || rc=$?
  classify "$rc" "$WORK/out" "$WORK/err"
}

# PowerShell を子プロセスとして起動し、その PATH の gh で測る。gh が PowerShell の PATH に無い回を
# 判定不能として分けるため、Get-Command の不在を 97 で返す（gh 自身は 97 を使わない）。
# 子はこのシェルの環境を引き継ぐ。gh の参照先を変える変数（トークン・設定ディレクトリ・既定ホスト）は
# このシェルの値を外したうえで、Windows に永続化された値（ユーザー → マシンの順）があれば戻し、新しく
# 開いた PowerShell ウィンドウと同じ値で測る — 引き継ぐと、保存済みの資格情報ではなくこのシェルの
# 環境変数を測ってしまう（無効な GH_TOKEN を引き継いで 401 になったのを実測）。
PS_GH_VARS="'GH_TOKEN','GITHUB_TOKEN','GH_ENTERPRISE_TOKEN','GITHUB_ENTERPRISE_TOKEN','GH_CONFIG_DIR','XDG_CONFIG_HOME','GH_HOST'"
probe_powershell() {
  local ps="" rc=0 script="" restore=""
  if command -v powershell.exe >/dev/null 2>&1; then ps=powershell.exe
  elif command -v pwsh.exe >/dev/null 2>&1; then ps=pwsh.exe
  else STATE=unknown; DETAIL='PowerShell（powershell.exe / pwsh.exe）が見つかりません'; return 0; fi
  restore="foreach (\$n in @(${PS_GH_VARS})) { \$v = [Environment]::GetEnvironmentVariable(\$n, 'User'); if (-not \$v) { \$v = [Environment]::GetEnvironmentVariable(\$n, 'Machine') }; if (\$v) { Set-Item -Path ('env:' + \$n) -Value \$v } }"
  script="${restore}; if (-not (Get-Command gh -ErrorAction SilentlyContinue)) { exit 97 }; gh api --hostname ${GH_HOST_NAME} user --jq .login; exit \$LASTEXITCODE"
  (
    unset GH_TOKEN GITHUB_TOKEN GH_ENTERPRISE_TOKEN GITHUB_ENTERPRISE_TOKEN GH_CONFIG_DIR XDG_CONFIG_HOME GH_HOST
    with_timeout "$ps" -NoProfile -NonInteractive -Command "$script" < /dev/null > "$WORK/out" 2> "$WORK/err"
  ) || rc=$?
  if [ "$rc" -eq 97 ]; then STATE=unknown; DETAIL='PowerShell の PATH に gh が見つかりません'; return 0; fi
  classify "$rc" "$WORK/out" "$WORK/err"
}

# WSL の gh を既定（または --wsl-distro）のディストリで測る。--exec はシェルを介さずに argv を
# そのまま渡すので、`$WSL_DISTRO_NAME` は WSL 側の sh が展開する（`wsl.exe bash -lc '…'` の形は
# 既定シェルが先に展開して空にする）。--exec はログインプロファイルを読まないので、利用者が gh を
# 入れがちな ~/.local/bin は PATH へ足す。`distro=` の行が無い回は WSL 自体が
# 起動していない。その行より前に出た wsl.exe の通知は読み飛ばす。
WSL_NAME=""
probe_wsl() {
  local rc=0 line="" found=0
  local args=()
  if ! command -v wsl.exe >/dev/null 2>&1; then STATE=unknown; DETAIL='wsl.exe が見つかりません'; return 0; fi
  [ -z "$WSL_DISTRO" ] || args=(-d "$WSL_DISTRO")
  with_timeout wsl.exe ${args[@]+"${args[@]}"} --exec sh -c \
    'PATH="$PATH:$HOME/.local/bin"; printf "distro=%s\n" "$WSL_DISTRO_NAME"; command -v gh >/dev/null 2>&1 || exit 97; gh api --hostname "$1" user --jq .login' \
    sh "$GH_HOST_NAME" < /dev/null > "$WORK/out" 2> "$WORK/err" || rc=$?
  : > "$WORK/wsl-out"
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line//$'\r'/}"
    if [ "$found" -eq 1 ]; then printf '%s\n' "$line" >> "$WORK/wsl-out"; continue; fi
    case "$line" in
      distro=*) found=1; WSL_NAME="${line#distro=}" ;;
    esac
  done < "$WORK/out"
  if [ "$found" -eq 0 ]; then
    case "$rc" in
      124|137) STATE=unknown; DETAIL="WSL が応答しません（${PROBE_TIMEOUT} 秒で打ち切り）" ;;
      *) STATE=unknown; DETAIL="WSL を起動できません（rc=${rc}）" ;;
    esac
    return 0
  fi
  case "$WSL_NAME" in
    *[!A-Za-z0-9._-]*) WSL_NAME=""; STATE=unknown; DETAIL='WSL のディストリ名を読み取れません'; return 0 ;;
  esac
  [ -n "$WSL_NAME" ] || WSL_NAME="$WSL_DISTRO"
  if [ "$rc" -eq 97 ]; then STATE=unknown; DETAIL="WSL${WSL_NAME:+（${WSL_NAME}）}の PATH に gh が見つかりません"; return 0; fi
  classify "$rc" "$WORK/wsl-out" "$WORK/err"
}

# --log で渡されたファイルにトークン様の文字列が混ざっていたら伏せ字にする（gh の出力には通常
# 現れないが、将来の版やデバッグ出力で混ざっても、保存したファイルに残さない）。
mask_tokens() { # <file>
  local f="$1" line="" buf="" n=0 re='(gh[opsur]_[A-Za-z0-9_]+|github_pat_[A-Za-z0-9_]+)'
  [ -f "$f" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    n=0
    while [[ $line =~ $re ]]; do
      # 置換が効かない入力（不正なバイト列で照合と置換が食い違う等）でも抜け、行ごと伏せる。
      n=$((n + 1))
      if [ "$n" -gt 20 ]; then line='[REDACTED]'; break; fi
      line="${line/"${BASH_REMATCH[1]}"/***}"
    done
    buf="${buf}${line}"$'\n'
  done < "$f"
  printf '%s' "$buf" > "$f"
}

# 利用者がブラウザで承認する device flow を非対話で起動し、one-time code と URL だけを出力する。
# トークンは gh が資格情報ストアへ書くだけで、本スクリプトは読まない・出さない（`gh auth token` を
# 呼ばない）。承認の完了は gh の終了で知り、最後に `gh api user` で read-back する。gh の出力は
# 既定では一時領域に置いて終了時に消し、--log を渡したときだけ伏せ字にして残す（伏せ字は EXIT trap が
# 当てるので、途中で止められた回にも効く）。
login_device() {
  local log="$WORK/login.log" rc=0 waited=0 line="" code="" url="" alive=1 pid=""
  local code_re='([[:upper:][:digit:]]{4}-[[:upper:][:digit:]]{4})'
  local url_re='(https?://[^[:space:]]+/login/device)'
  if ! command -v gh >/dev/null 2>&1; then echo 'gh が見つかりません（PATH）' >&2; exit 1; fi
  if env_token_set; then
    echo "❌ このシェルには ${ENV_TOKEN_NAMES} が設定されています。gh は環境変数を優先して device flow を受け付けないので、環境変数を外してから再実行してください" >&2
    exit 1
  fi
  [ -z "$LOG_FILE" ] || log="$LOG_FILE"
  : > "$log"
  ( unset GH_DEBUG DEBUG; GH_PROMPT_DISABLED=1 exec gh auth login --hostname "$GH_HOST_NAME" --git-protocol https --web ) \
    < /dev/null > "$log" 2>&1 &
  LOGIN_PID=$!
  pid="$LOGIN_PID"
  while :; do
    alive=1
    kill -0 "$pid" 2>/dev/null || alive=0
    while IFS= read -r line || [ -n "$line" ]; do
      line="${line//$'\r'/}"
      case "$line" in
        *one-time\ code*) if [ -z "$code" ] && [[ $line =~ $code_re ]]; then code="${BASH_REMATCH[1]}"; fi ;;
      esac
      if [ -z "$url" ] && [[ $line =~ $url_re ]]; then url="${BASH_REMATCH[1]}"; fi
    done < "$log"
    [ -z "$code" ] || break
    [ "$alive" -eq 1 ] || break
    [ "$waited" -lt "$CODE_WAIT" ] || break
    sleep 1
    waited=$((waited + 1))
  done
  if [ -z "$code" ]; then
    # gh が自分で終わっていれば止めない（回収済みの pid へ signal を送らない）。
    if [ "$alive" -eq 1 ]; then stop_login; else LOGIN_PID=""; fi
    wait "$pid" 2>/dev/null || rc=$?
    if [ -n "$LOG_FILE" ]; then
      echo "❌ gh auth login から one-time code を読み取れませんでした（rc=${rc}。gh の出力: ${LOG_FILE}）" >&2
    else
      echo "❌ gh auth login から one-time code を読み取れませんでした（rc=${rc}。gh の出力を確かめるには --log FILE を付けて再実行する）" >&2
    fi
    exit 2
  fi
  echo "DEVICE_CODE=${code}"
  echo "DEVICE_URL=${url:-https://${GH_HOST_NAME}/login/device}"
  [ -z "$LOG_FILE" ] || echo "DEVICE_LOG=${LOG_FILE}"
  echo "利用者がブラウザで DEVICE_URL を開き、DEVICE_CODE を入力して承認するのを待っています（コードの有効期限は約 15 分。上限 ${APPROVE_WAIT} 秒）"
  waited=0
  while kill -0 "$pid" 2>/dev/null && [ "$waited" -lt "$APPROVE_WAIT" ]; do
    sleep 1
    waited=$((waited + 1))
  done
  if kill -0 "$pid" 2>/dev/null; then
    stop_login
    echo "承認を ${APPROVE_WAIT} 秒待っても gh auth login が終わらないので止めました。read-back で確かめます"
  fi
  wait "$pid" 2>/dev/null || rc=$?
  LOGIN_PID=""
  [ "$rc" -eq 0 ] || echo "gh auth login が rc=${rc} で終わりました。read-back で確かめます"
  probe_shell
  echo "READBACK=${STATE} ${DETAIL}"
  [ "$STATE" = ok ] || exit 3
  exit 0
}

if [ "$MODE" = login ]; then login_device; fi

case "${OSTYPE:-}" in
  msys*|cygwin*) WINDOWS=1 ;;
  *) WINDOWS=0 ;;
esac
KEYS=()
STATES=()
DETAILS=()
record() { KEYS+=("$1"); STATES+=("$STATE"); DETAILS+=("$DETAIL"); }
if [ "$WINDOWS" -eq 1 ]; then
  # Git Bash（MSYS）は native exe へ渡す引数のうち `/` で始まる語をパスへ書き換える。
  # 本スクリプトの引数にパスは無いので、変換を止めて argv をそのまま渡す。
  export MSYS2_ARG_CONV_EXCL='*'
  probe_shell; record bash
  probe_powershell; record powershell
  probe_wsl; record wsl
else
  probe_shell; record shell
fi

n_ok=0; n_broken=0; n_unknown=0
echo "gh の認証（${GH_HOST_NAME}）を文脈ごとに gh api user で測りました"
printf '%s\t%s\t%s\n' 文脈 結果 詳細
for i in "${!KEYS[@]}"; do
  case "${STATES[$i]}" in
    ok) label=ok; n_ok=$((n_ok + 1)) ;;
    broken) label=要復旧; n_broken=$((n_broken + 1)) ;;
    *) label=判定不能; n_unknown=$((n_unknown + 1)) ;;
  esac
  key="${KEYS[$i]}"
  [ "$key" != wsl ] || [ -z "$WSL_NAME" ] || key="wsl（${WSL_NAME}）"
  printf '%s\t%s\t%s\n' "$key" "$label" "${DETAILS[$i]}"
done
echo "集計: ok=${n_ok} 要復旧=${n_broken} 判定不能=${n_unknown}"
# 復旧の案内は壊れている文脈にだけ出す。どの文脈にもログアウトは案内しない — keyring を共有する
# 文脈では、1 つのログアウトが他の文脈のトークンまで失効させる。
login_hint="bash \"${SCRIPT_PATH}\" login --hostname ${GH_HOST_NAME}"
wsl_d=""
[ -z "$WSL_NAME" ] || wsl_d="-d ${WSL_NAME} "
for i in "${!KEYS[@]}"; do
  key="${KEYS[$i]}"
  case "${STATES[$i]}" in
    broken)
      case "$key" in
        # gh は保存済みの資格情報より環境変数を優先するので、device flow で入れ直しても直らない。
        bash|shell) if env_token_set; then echo "復旧（${key}）: このシェルの ${ENV_TOKEN_NAMES} が無効です。環境変数を外すか有効な値にする（gh は保存済みの資格情報より環境変数を優先する）"; continue; fi ;;
      esac
      case "$key" in
        bash) echo "復旧（bash）: このシェルで device flow を起動する — 利用者と対話しているセッションから、ホストの背景実行で ${login_hint} を起動し、表示された DEVICE_CODE を利用者へ伝えて DEVICE_URL をブラウザで開いて承認してもらう（利用者が PowerShell でログインし直しても、このシェルの gh には届かないことがある）" ;;
        shell) echo "復旧（shell）: このシェルで device flow を起動する — 利用者と対話しているセッションから、ホストの背景実行で ${login_hint} を起動し、表示された DEVICE_CODE を利用者へ伝えて DEVICE_URL をブラウザで開いて承認してもらう" ;;
        powershell) echo "復旧（powershell）: 利用者の PowerShell で gh auth login -h ${GH_HOST_NAME} -w を実行してもらう。ログアウトはしない（資格情報を共有する他の文脈まで壊れる）" ;;
        wsl) echo "復旧（wsl）: 利用者の PowerShell から wsl ${wsl_d}-- gh auth login -h ${GH_HOST_NAME} -w を実行し、続けて wsl ${wsl_d}-- gh auth setup-git を実行してもらう（WSL のプロンプトに入らず、PowerShell から打つ）" ;;
      esac ;;
    unknown)
      case "$key" in
        bash|shell) echo "確認（${key}）: 判定不能の理由（gh の有無・ネットワーク）を解消してから再実行する" ;;
        powershell) echo '確認（powershell）: 判定不能の理由を解消してから再実行する（PowerShell の gh を使わない作業機なら対象外）' ;;
        wsl) echo '確認（wsl）: 判定不能の理由を解消してから再実行する（WSL の gh を使わない作業機なら対象外）' ;;
      esac ;;
  esac
done
[ "$n_broken" -eq 0 ] || exit 3
[ "$n_unknown" -eq 0 ] || exit 2
exit 0
