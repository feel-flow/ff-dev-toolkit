#!/usr/bin/env bash
#
# setup-multi-agent.sh の yq 導入・検証契約（Issue #271 / ACE-66-1）。
#
# - distro パッケージ（apt/yum/pacman）へ yq を投げない
# - 非互換 yq（Python / v3 / capability 欠落）を利用可能と誤認しない
# - install が 0 を返しても post-install で flavor/version/capability を再検証する
# - macOS Homebrew 経路（brew install yq）を残す
#
# 使い方: bash plugins/ff-dev-toolkit/tests/setup-multi-agent-yq/verify.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SETUP="$PLUGIN_ROOT/scripts/setup-multi-agent.sh"

[ -f "$SETUP" ] || { echo "✗ setup-multi-agent.sh が見つかりません: $SETUP" >&2; exit 1; }

if ! TMP="$(mktemp -d 2>/dev/null)"; then
  echo "○ skip: 一時ディレクトリを作成できない環境（read-only）のためスキップ"
  FF_REACHED_END=1
  exit 0
fi
# 途中死を沈黙させない。`set -u` 等で死んだとき、トラップ突入時の $? は **0** になるため、
# 終了ステータスを保存し直すだけでは足りない（実測）。「rc=0 なのに最後まで到達して
# いない」を中断として扱う。明示的な非 0 終了はそのまま通す。
FF_REACHED_END=0
_ff_exit_guard() {
  _ff_rc=$?
  rm -rf "$TMP"
  if [ "$_ff_rc" -eq 0 ] && [ "$FF_REACHED_END" -ne 1 ]; then
    echo "✗ setup-multi-agent-yq: 最後まで到達しませんでした（途中で中断）" >&2
    exit 1
  fi
  exit "$_ff_rc"
}
trap _ff_exit_guard EXIT

PASS=0
FAIL=0
ok()  { echo "  ✓ $1"; PASS=$((PASS + 1)); }
bad() { echo "  ✗ $1" >&2; FAIL=$((FAIL + 1)); }

echo "== setup-multi-agent yq 導入・検証契約 =="

# ---- 静的検査 ----------------------------------------------------------------

if syntax_err="$(bash -n "$SETUP" 2>&1)"; then
  ok "setup-multi-agent.sh が bash として構文的に妥当（bash -n）"
else
  bad "setup-multi-agent.sh が bash -n を通らない"
  printf '%s\n' "$syntax_err" | sed 's/^/    | /' >&2
fi

# distro パッケージへ yq を投げると Ubuntu 等で別実装が入る（本 Issue の本体）。
# 実行文だけを見る。print_info / コメントでの否定言及（「apt は非対応」等）は除外する。
DISTRO_YQ_HITS="$(
  grep -nE 'apt-get +.*install|apt +.*install|yum +.*install|dnf +.*install|pacman +-[Ss]' "$SETUP" \
    | grep -i 'yq' \
    | grep -vE 'print_|#|注意|非対応|別実装|パッケージ' \
    || true
)"
if [[ -n "$DISTRO_YQ_HITS" ]]; then
  bad "Linux 導入経路が distro パッケージの yq に依存している（apt/yum/pacman install yq）"
  printf '%s\n' "$DISTRO_YQ_HITS" | sed 's/^/    | /' >&2
else
  ok "apt/yum/pacman で yq を install する経路が無い"
fi

# help 文中の "brew install yq" だけでは不十分。install 分岐（brew) case）を要求する。
if grep -nE 'brew\)' "$SETUP" | head -1 >/dev/null \
  && awk '/brew\)/{f=1} f && /brew install yq/{found=1} f && /^\s*\*\)/{exit} END{exit !found}' "$SETUP"; then
  ok "Homebrew 導入分岐（brew) + brew install yq）が残っている"
else
  bad "Homebrew 導入分岐（brew) + brew install yq）が消えている"
fi

if grep -q 'github.com/mikefarah/yq' "$SETUP" && grep -q 'releases/latest/download' "$SETUP"; then
  ok "GitHub release 導入が Mike Farah 公式 URL を参照する"
else
  bad "GitHub release 導入が Mike Farah 公式 URL を参照していない"
fi

if grep -q 'export PATH="${dir}:${PATH}"' "$SETUP" && grep -q 'hash -r' "$SETUP"; then
  ok "導入後に PATH 先頭化と hash -r がある"
else
  bad "導入後の PATH 先頭化 / hash -r が無い（stale yq が勝ち続ける）"
fi

if grep -q 'yq_version_is_mikefarah_v4\|version v4\.' "$SETUP" && grep -q 'yq_capability_probe' "$SETUP"; then
  ok "version（Mike Farah v4）と capability probe の検証関数がある"
else
  bad "version / capability probe の検証関数が無い"
fi

# ---- 振る舞い検査: 関数を source して ensure_yq を直接叩く --------------------
#
# main は BASH_SOURCE ガードで走らない。print_* は本物を使い、install_yq だけ
# スタブ差し替えできるようにする。

# shellcheck disable=SC1090
source "$SETUP"

# 検出器が本当に非互換を弾くか、shim を PATH 先頭に置いて毎回実測する。
make_yq_shim() {
  # $1: mode (python-yq|v3|bad-capability)
  # local の同時代入は、dir= が呼出元の mode を拾う SC2154/SC2318 を避けるため分ける
  local mode dir
  mode="$1"
  dir="$TMP/shim-$mode"
  mkdir -p "$dir"
  case "$mode" in
    python-yq)
      cat > "$dir/yq" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "--version" ]]; then echo "yq 3.4.3"; exit 0; fi
# kislyuk/yq 風: jq へ丸投げせず、セットアップが使う式を壊す
echo "jq: error: Invalid" >&2
exit 1
EOF
      ;;
    v3)
      cat > "$dir/yq" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "--version" ]]; then
  echo "yq (https://github.com/mikefarah/yq/) version v3.4.1"
  FF_REACHED_END=1
  exit 0
fi
echo "unsupported in v3" >&2
exit 1
EOF
      ;;
    bad-capability)
      cat > "$dir/yq" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "--version" ]]; then
  echo "yq (https://github.com/mikefarah/yq/) version v4.52.4"
  FF_REACHED_END=1
  exit 0
fi
# version は偽装するが、setup が使う -r 式は常に空/失敗
exit 1
EOF
      ;;
    *)
      echo "unknown shim mode: $mode" >&2
      return 1
      ;;
  esac
  chmod +x "$dir/yq"
  echo "$dir"
}

run_ensure_yq() {
  # $1: PATH prefix dir（空可） $2: SKIP_INSTALL true/false
  # stdout+stderr を ENSURE_OUT に、終了コードを ENSURE_RC に入れる
  local path_prefix="${1:-}"
  local skip="${2:-true}"
  local old_path="$PATH"
  SKIP_INSTALL="$skip"
  if [[ -n "$path_prefix" ]]; then
    PATH="${path_prefix}:${PATH}"
  fi
  # 本物の yq を隠したいケースでは path_prefix 側だけにする呼び出し側の責任。
  # ここでは常に path_prefix を先頭に足す。
  set +e
  ENSURE_OUT="$(ensure_yq 2>&1)"
  ENSURE_RC=$?
  set -e
  PATH="$old_path"
  SKIP_INSTALL=false
}

# 1) 非互換 shim + --skip-install → 失敗・成功表示なし
for mode in python-yq v3 bad-capability; do
  shim_dir="$(make_yq_shim "$mode")"
  # 本物 yq が後段にいても shim を先に当てる
  run_ensure_yq "$shim_dir" true
  if [[ "$ENSURE_RC" -ne 0 ]] && [[ "$ENSURE_OUT" != *"✓ yq:"* ]]; then
    case "$mode" in
      python-yq|v3)
        if [[ "$ENSURE_OUT" == *"Mike Farah"* ]] || [[ "$ENSURE_OUT" == *"利用できません"* ]]; then
          ok "非互換 yq（${mode}）を --skip-install で誤認しない"
        else
          bad "非互換 yq（${mode}）の診断が不足: $ENSURE_OUT"
        fi
        ;;
      bad-capability)
        if [[ "$ENSURE_OUT" == *"capability"* ]] || [[ "$ENSURE_OUT" == *"利用できません"* ]]; then
          ok "capability 欠落 yq を --skip-install で誤認しない"
        else
          bad "capability 欠落 yq の診断が不足: $ENSURE_OUT"
        fi
        ;;
    esac
  else
    bad "非互換 yq（${mode}）を成功扱いした（rc=${ENSURE_RC}）"
    printf '%s\n' "$ENSURE_OUT" | sed 's/^/    | /' >&2
  fi
done

# 2) install_yq が 0 を返しても、PATH に互換 yq が無いなら fail-loud
install_yq() { return 0; }
# PATH から yq を隠す（stub ディレクトリだけ）
HIDE="$TMP/hide-bin"
mkdir -p "$HIDE"
# 最小限の外部コマンドを通す
for cmd in bash sh cat printf head mktemp mv chmod mkdir sudo true false; do
  if command -v "$cmd" >/dev/null 2>&1; then
    ln -sf "$(command -v "$cmd")" "$HIDE/$cmd" 2>/dev/null || true
  fi
done
# command -v yq が失敗するように yq は置かない
OLD_PATH="$PATH"
PATH="$HIDE"
SKIP_INSTALL=false
set +e
POST_OUT="$(ensure_yq 2>&1)"
POST_RC=$?
set -e
PATH="$OLD_PATH"
SKIP_INSTALL=false
# install_yq を元に戻すため再 source
# shellcheck disable=SC1090
source "$SETUP"

if [[ "$POST_RC" -ne 0 ]] && [[ "$POST_OUT" == *"導入したあとでも"* || "$POST_OUT" == *"利用できません"* || "$POST_OUT" == *"インストールに失敗"* || "$POST_OUT" == *"yq が PATH"* || "$POST_OUT" == *"見つかり"* || "$POST_OUT" == *"ありません"* ]]; then
  ok "install_yq が 0 でも互換 yq が無ければ fail-loud（ACE-66-1）"
else
  # メッセージは実装依存なので、成功表示が無く非 0 なら合格とする
  if [[ "$POST_RC" -ne 0 ]] && [[ "$POST_OUT" != *"✓ yq: インストール完了"* ]]; then
    ok "install_yq が 0 でも互換 yq が無ければ fail-loud（ACE-66-1）"
  else
    bad "install 成功スタブ + yq 不在で成功してしまった（rc=${POST_RC}）"
    printf '%s\n' "$POST_OUT" | sed 's/^/    | /' >&2
  fi
fi

# 3) install_yq が 0 でも、PATH 前方に別実装が残れば fail-loud
#    （install スタブは PATH を直さないので、前方 stale のまま失敗する契約）
# shellcheck disable=SC1090
source "$SETUP"
install_yq() { return 0; }
shim_dir="$(make_yq_shim python-yq)"
SKIP_INSTALL=false
OLD_PATH="$PATH"
PATH="${shim_dir}:${PATH}"
set +e
STALE_OUT="$(ensure_yq 2>&1)"
STALE_RC=$?
set -e
PATH="$OLD_PATH"
# shellcheck disable=SC1090
source "$SETUP"

if [[ "$STALE_RC" -ne 0 ]] && [[ "$STALE_OUT" != *"✓ yq: インストール完了"* ]]; then
  ok "install 後も PATH 前方の別実装 yq が残れば fail-loud"
else
  bad "PATH 前方の別実装を install 成功として通した（rc=${STALE_RC}）"
  printf '%s\n' "$STALE_OUT" | sed 's/^/    | /' >&2
fi

# 4) 本物の Mike Farah v4 がある環境では ensure_yq が成功する
# shellcheck disable=SC1090
source "$SETUP"
# パイプ + grep -q は使わない（run-all の SIGPIPE 再混入ガードと ACE 契約）。
REAL_YQ_VERSION=""
REAL_YQ_BIN=""
if command -v yq >/dev/null 2>&1; then
  REAL_YQ_BIN="$(command -v yq)"
  REAL_YQ_VERSION="$(yq --version 2>&1 || true)"
fi
case "$REAL_YQ_VERSION" in
  *github.com/mikefarah/yq*'version v4.'*)
    SKIP_INSTALL=true
    set +e
    REAL_OUT="$(ensure_yq 2>&1)"
    REAL_RC=$?
    set -e
    SKIP_INSTALL=false
    if [[ "$REAL_RC" -eq 0 ]] && [[ "$REAL_OUT" == *"✓ yq:"* ]]; then
      ok "互換な Mike Farah yq v4 を成功と判定する"
    else
      bad "本物の Mike Farah yq v4 を拒否した（rc=${REAL_RC}）"
      printf '%s\n' "$REAL_OUT" | sed 's/^/    | /' >&2
    fi
    ;;
  *)
    ok "（参考）ホストに Mike Farah yq v4 が無いため成功経路の実測はスキップ"
    ;;
esac

# 5) オフライン fixture で download → 配置 → PATH 先頭化 → 成功を実測
#    （ホストに本物 yq v4 があるときだけ。ネットワーク不要）
# shellcheck disable=SC1090
source "$SETUP"
case "$REAL_YQ_VERSION" in
  *github.com/mikefarah/yq*'version v4.'*)
    FAKE_REL="$TMP/fake-release"
    BINDER="$TMP/install-bin"
    BAD_FRONT="$TMP/bad-front"
    mkdir -p "$FAKE_REL" "$BINDER" "$BAD_FRONT"
    ASSET_NAME="$(yq_binary_asset_name)"
    cp "$REAL_YQ_BIN" "$FAKE_REL/${ASSET_NAME}"
    chmod +x "$FAKE_REL/${ASSET_NAME}"
    # 前方に非互換 yq を置き、install が PATH 先頭化で上書きできることを見る
    cat > "$BAD_FRONT/yq" <<'EOF'
#!/usr/bin/env bash
echo "yq 3.4.3"
FF_REACHED_END=1
exit 0
EOF
    chmod +x "$BAD_FRONT/yq"

    # brew があっても GitHub 経路を強制する（本ケースの検証対象は download/配置/PATH）
    install_yq() { install_yq_from_github; }
    YQ_GITHUB_BASE_URL="$FAKE_REL"
    YQ_INSTALL_DIR="$BINDER"
    SKIP_INSTALL=false
    OLD_PATH="$PATH"
    PATH="${BAD_FRONT}:${PATH}"
    OFF_LOG="$TMP/offline-ensure.log"
    # command substitution だと PATH export が親に残らないので、直接実行する
    set +e
    ensure_yq >"$OFF_LOG" 2>&1
    OFF_RC=$?
    set -e
    OFF_OUT="$(cat "$OFF_LOG")"
    RESOLVED="$(command -v yq 2>/dev/null || true)"
    PATH="$OLD_PATH"
    unset YQ_GITHUB_BASE_URL YQ_INSTALL_DIR
    # shellcheck disable=SC1090
    source "$SETUP"
    SKIP_INSTALL=false

    if [[ "$OFF_RC" -eq 0 ]] \
      && [[ "$OFF_OUT" == *"✓ yq:"* ]] \
      && [[ "$RESOLVED" == "${BINDER}/yq" ]] \
      && [[ -x "${BINDER}/yq" ]]; then
      ok "オフライン fixture で GitHub 経路を実測（stale 前方 → 配置 → PATH 先頭）"
    else
      bad "オフライン fixture 導入が期待どおりでない（rc=${OFF_RC} resolved=${RESOLVED}）"
      printf '%s\n' "$OFF_OUT" | sed 's/^/    | /' >&2
    fi
    ;;
  *)
    ok "（参考）ホストに Mike Farah yq v4 が無いためオフライン導入の実測はスキップ"
    ;;
esac

# 6) check_and_install_dependencies も非互換を緑にしない
# shellcheck disable=SC1090
source "$SETUP"
shim_dir="$(make_yq_shim v3)"
SKIP_INSTALL=true
OLD_PATH="$PATH"
PATH="${shim_dir}:${PATH}"
set +e
DEP_OUT="$(check_and_install_dependencies 2>&1)"
DEP_RC=$?
set -e
PATH="$OLD_PATH"
SKIP_INSTALL=false
if [[ "$DEP_RC" -ne 0 ]] && [[ "$DEP_OUT" != *"✓ yq:"* ]]; then
  ok "check_and_install_dependencies が非互換 yq で非 0"
else
  bad "check_and_install_dependencies が非互換 yq を通した（rc=${DEP_RC}）"
  printf '%s\n' "$DEP_OUT" | sed 's/^/    | /' >&2
fi

# ---- サマリー ----------------------------------------------------------------
echo
echo "setup-multi-agent-yq: passed=${PASS} failed=${FAIL}"
if [[ "$FAIL" -gt 0 ]]; then
  exit 1
fi
FF_REACHED_END=1
exit 0
FF_REACHED_END=1
