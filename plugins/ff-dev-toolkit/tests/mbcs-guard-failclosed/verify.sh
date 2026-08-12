#!/usr/bin/env bash
#
# mbcs-guard の fail-closed 経路の自動回帰（Issue #312）。
#
# case 11（run-all/verify.sh）は self-test（検出器の空振り）と本番横断走査を
# 毎回実行するが、次の経路は手動変異に依存していた:
#   - git rev-parse 失敗 → error_repo
#   - git ls-files 失敗 / 空 → error_list
#   - 読み取り不能ファイル → error_scan
#   - awk 非 0 → error_scan
#   - 正常ミニリポジトリ → ok
#
# 共有実装 tests/lib/mbcs-guard.sh の FF_MBCS_GIT / FF_MBCS_AWK シームで固定する。
# 書き込み不可環境では ○ skip（mktemp 必須）。

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TESTS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=../lib/mbcs-guard.sh
. "$TESTS_DIR/lib/mbcs-guard.sh"

PASS=0
FAIL=0
ok()  { echo "  ✓ $1"; PASS=$((PASS + 1)); }
bad() { echo "  ✗ $1" >&2; FAIL=$((FAIL + 1)); }

# mktemp の stderr を捨てない。捨てると read-only 以外の失敗（TMPDIR が不正な
# パス・quota 超過など）まで「書き込み可能な環境で再実行してください」に誤帰属し、
# 恒常的に壊れた TMPDIR が suite を exit 0 で無効化し続ける。2>&1 で受けると
# 成功時はパス・失敗時は理由が同じ変数に入る。
if _ff_mktemp_out="$(mktemp -d 2>&1)"; then
  TMP="$_ff_mktemp_out"
else
  echo "○ skip: 一時ディレクトリを作成できない環境（read-only）のためスキップ"
  printf '  mktemp: %s\n' "$_ff_mktemp_out"
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
    echo "✗ mbcs-guard-failclosed: 最後まで到達しませんでした（途中で中断）" >&2
    exit 1
  fi
  exit "$_ff_rc"
}
trap _ff_exit_guard EXIT

echo "== mbcs-guard fail-closed 経路の自動回帰 =="

# ---- helper: stub git --------------------------------------------------------
write_git_stub() {
  # $1=path $2=mode: revparse-fail | lsfiles-fail | lsfiles-empty | passthrough
  local dest="$1" mode="$2"
  case "$mode" in
    revparse-fail)
      cat > "$dest" <<'STUB'
#!/usr/bin/env bash
if [[ "$*" == *rev-parse* ]]; then
  echo "fatal: not a git repository" >&2
  exit 128
fi
exec /usr/bin/git "$@"
STUB
      ;;
    lsfiles-fail)
      cat > "$dest" <<'STUB'
#!/usr/bin/env bash
if [[ "$*" == *ls-files* ]]; then
  echo "fatal: ls-files failed" >&2
  exit 128
fi
if [[ "$*" == *rev-parse* ]]; then
  # 次引数の -C path を解釈して show-toplevel
  exec /usr/bin/git "$@"
fi
exec /usr/bin/git "$@"
STUB
      ;;
    lsfiles-empty)
      cat > "$dest" <<'STUB'
#!/usr/bin/env bash
if [[ "$*" == *ls-files* ]]; then
  FF_REACHED_END=1
  exit 0
fi
exec /usr/bin/git "$@"
STUB
      ;;
    *)
      echo "unknown stub mode: $mode" >&2
      exit 2
      ;;
  esac
  chmod +x "$dest"
}

# ---- fixture: 正常ミニリポジトリ ---------------------------------------------
GOOD_REPO="$TMP/good"
git init -q "$GOOD_REPO"
git -C "$GOOD_REPO" config user.email "test@example.com"
git -C "$GOOD_REPO" config user.name "mbcs-test"
git -C "$GOOD_REPO" config commit.gpgsign false
printf '%s\n' '#!/usr/bin/env bash' 'echo "ok: ${name}（safe）"' > "$GOOD_REPO/ok.sh"
chmod +x "$GOOD_REPO/ok.sh"
git -C "$GOOD_REPO" add ok.sh
git -C "$GOOD_REPO" commit -qm "init"

# ---- fixture: 読み取り不能 .sh を含むリポジトリ -------------------------------
UNREAD_REPO="$TMP/unread"
git init -q "$UNREAD_REPO"
git -C "$UNREAD_REPO" config user.email "test@example.com"
git -C "$UNREAD_REPO" config user.name "mbcs-test"
git -C "$UNREAD_REPO" config commit.gpgsign false
printf '%s\n' '#!/usr/bin/env bash' 'echo safe' > "$UNREAD_REPO/locked.sh"
git -C "$UNREAD_REPO" add locked.sh
git -C "$UNREAD_REPO" commit -qm "init"
chmod a-r "$UNREAD_REPO/locked.sh"

# ---- fixture: awk 失敗用（常に exit 2） ----------------------------------------
BAD_AWK="$TMP/bad-awk"
cat > "$BAD_AWK" <<'AWK'
#!/usr/bin/env bash
exit 2
AWK
chmod +x "$BAD_AWK"

# 関数は env(1) では呼べない。シームは呼び出し側で export / 前置代入する。
summary_of() {
  # $1=repo_root — stdout に MBCS_RESULT 行だけ
  local root="$1"
  set +e
  local out
  out="$(mbcs_check_tracked "$root" 2>/dev/null)"
  set -e
  printf '%s\n' "$out" | grep '^MBCS_RESULT=' | tail -n 1 || true
}

# ---- 1. git rev-parse 失敗 → error_repo --------------------------------------
STUB_DIR="$TMP/stub-revparse"
mkdir -p "$STUB_DIR"
write_git_stub "$STUB_DIR/git" revparse-fail
SUM="$(FF_MBCS_GIT="$STUB_DIR/git" summary_of "$GOOD_REPO")"
case "$SUM" in
  MBCS_RESULT=error_repo\ *) ok "git rev-parse 失敗 → error_repo" ;;
  *) bad "git rev-parse 失敗が error_repo にならない: $SUM" ;;
esac

# ---- 2. git ls-files 失敗 → error_list ---------------------------------------
STUB_DIR="$TMP/stub-lsfail"
mkdir -p "$STUB_DIR"
write_git_stub "$STUB_DIR/git" lsfiles-fail
SUM="$(FF_MBCS_GIT="$STUB_DIR/git" summary_of "$GOOD_REPO")"
case "$SUM" in
  MBCS_RESULT=error_list\ *) ok "git ls-files 失敗 → error_list" ;;
  *) bad "git ls-files 失敗が error_list にならない: $SUM" ;;
esac

# ---- 3. git ls-files 空 → error_list -----------------------------------------
STUB_DIR="$TMP/stub-lsempty"
mkdir -p "$STUB_DIR"
write_git_stub "$STUB_DIR/git" lsfiles-empty
SUM="$(FF_MBCS_GIT="$STUB_DIR/git" summary_of "$GOOD_REPO")"
case "$SUM" in
  MBCS_RESULT=error_list\ *) ok "git ls-files 空 → error_list" ;;
  *) bad "git ls-files 空が error_list にならない: $SUM" ;;
esac

# ---- 4. 読み取り不能ファイル → error_scan ------------------------------------
SUM="$(summary_of "$UNREAD_REPO")"
case "$SUM" in
  MBCS_RESULT=error_scan\ *) ok "読み取り不能 *.sh → error_scan" ;;
  *) bad "読み取り不能が error_scan にならない: $SUM" ;;
esac

# ---- 5. awk 非 0 → error_scan ------------------------------------------------
SUM="$(FF_MBCS_AWK="$BAD_AWK" summary_of "$GOOD_REPO")"
case "$SUM" in
  MBCS_RESULT=error_scan\ *) ok "awk 非 0 → error_scan" ;;
  *) bad "awk 非 0 が error_scan にならない: $SUM" ;;
esac

# ---- 6. 正常ミニリポジトリ → ok（偽陽性なし） --------------------------------
SUM="$(summary_of "$GOOD_REPO")"
case "$SUM" in
  MBCS_RESULT=ok\ *) ok "正常ミニリポジトリ → ok（偽陽性なし）" ;;
  *) bad "正常リポジトリが ok にならない: $SUM" ;;
esac

# ---- 7. 違反ファイル → hits --------------------------------------------------
HIT_REPO="$TMP/hits"
git init -q "$HIT_REPO"
git -C "$HIT_REPO" config user.email "test@example.com"
git -C "$HIT_REPO" config user.name "mbcs-test"
git -C "$HIT_REPO" config commit.gpgsign false
# 違反行を 2 分割で書いて、本 suite ファイル自体が case 11 の対象に違反を直書きしない
{
  printf '%s\n' '#!/usr/bin/env bash'
  printf '%s' 'echo "bad: $name'
  printf '%s\n' '（x）"'
} > "$HIT_REPO/bad.sh"
git -C "$HIT_REPO" add bad.sh
git -C "$HIT_REPO" commit -qm "bad"
SUM="$(summary_of "$HIT_REPO")"
case "$SUM" in
  MBCS_RESULT=hits\ *) ok "違反 *.sh → hits" ;;
  *) bad "違反ファイルが hits にならない: $SUM" ;;
esac

echo ""
if [ "$FAIL" -gt 0 ]; then
  echo "✗ mbcs-guard-failclosed verify: $FAIL 件失敗（$PASS 件成功）" >&2
  exit 1
fi
echo "✓ mbcs-guard-failclosed verify: 全 $PASS 件 pass"
FF_REACHED_END=1
exit 0
FF_REACHED_END=1
