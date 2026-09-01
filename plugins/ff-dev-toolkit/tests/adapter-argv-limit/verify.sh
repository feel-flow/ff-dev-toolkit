#!/usr/bin/env bash
#
# adapter-argv-limit: diff が OS の argv 上限（ARG_MAX / E2BIG）を超える規模でも
# 全 4 アダプタがレビューを完走することの実測（Issue #1148 / 公開
# feel-flow/ff-dev-toolkit#55）。
#
# 背景: 公開リポジトリへ「大きな diff で全 CLI が status 126（Argument list too
# long）で失敗する」報告が来た。実測条件は 0.36.0 / macOS で、ARG_MAX 1,048,576 に
# 対して `git diff` が 2,129,295 バイト。当時アダプタはプロンプト（diff 込み）を
# argv で渡していたため、CLI が起動する前に execve が E2BIG を返していた。
#
# 経路そのものは Issue #712 で塞がっている（materialize_prompt_file → stdin /
# --prompt-file）。ただし #712 の動機は Windows / Git Bash の CreateProcess 上限
# ~32KB で、**針を持っていた suite（adapter-prompt-guard）の fixture は 240KB** —
# macOS / Linux の ARG_MAX（1MB / 2MB）を超えない。つまり報告された再現条件その
# ものは、どの suite でも一度も走っていなかった。ここで実寸の ARG_MAX を跨がせる。
#
# 固定するのは 4 点（CLI ごと）:
#   1. ARG_MAX を超える diff でもアダプタが 0 終了する（126 で落ちない）
#   2. 成果物が complete で残る（INCOMPLETE への降格で「完走」を偽らない）
#   3. argv の総量がプロンプト規模と独立（8KB 未満）
#   4. diff 全体が stdin / prompt-file 経由で CLI へ届く（末尾マーカーで確認）
#
# 変異検出: プロンプトを argv へ戻すと 1〜4 が同時に赤くなる（execve が E2BIG を
# 返してアダプタが 126 で落ちる）。切り詰めて argv に収める変異は 4 が赤くなる。
#
# 実 CLI・ネットワーク・課金は伴わない（PATH 上の stub を叩く）。書き込み不可の
# 環境、および fixture が現実的なサイズに収まらない環境では skip。

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd -P)"
ADAPTERS_DIR="$PLUGIN_ROOT/scripts/adapters"
ADAPTER_COMMON="$ADAPTERS_DIR/adapter-common.sh"

[ -f "$ADAPTER_COMMON" ] || {
  echo "✗ 対象ファイルが見つかりません: $ADAPTER_COMMON" >&2
  exit 1
}

# shellcheck source=../lib/adapter-env-isolation.sh
. "$SCRIPT_DIR/../lib/adapter-env-isolation.sh"
# 抽出源にはアダプタ実装を渡す（lib の契約: 渡したファイルに現れる名前だけが
# 名簿に載る）。orchestrator は起動しないので渡さない。
build_isolate_env "MULTI_AGENT_MODEL_CLAUDE_CODE" "$ADAPTERS_DIR"/*.sh

# ── fixture のサイズを決める ──
# 上限は getconf に聞く。値が取れない / 数値でない環境では実測条件を作れないので、
# 推測した既定で「超えたつもり」の緑を出さずに skip する（この suite の主張は
# 「実寸の ARG_MAX を跨いだ」だから、跨げていないなら主張ごと成立しない）。
ARG_MAX="$(getconf ARG_MAX 2>/dev/null || true)"
case "$ARG_MAX" in
  ''|*[!0-9]*) ARG_MAX_NUMERIC=false ;;
  *)           ARG_MAX_NUMERIC=true ;;
esac
if [ "$ARG_MAX_NUMERIC" != true ]; then
  echo "○ skip: getconf ARG_MAX が数値を返さない環境のためスキップ（取得値: '${ARG_MAX}'。検査は1件も実行されていません）"
  exit 0
fi
# 実寸を跨ぐのが目的なので上限を勝手に下げない。ただし ARG_MAX が極端に大きい環境
# （一部の Linux で数十 MB）まで fixture を作るのは実行時間の割に得るものが無い。
FIXTURE_CAP=$((16 * 1024 * 1024))
if [ "$ARG_MAX" -gt "$FIXTURE_CAP" ]; then
  echo "○ skip: ARG_MAX=${ARG_MAX} が fixture 上限 ${FIXTURE_CAP} を超えるためスキップ（検査は1件も実行されていません）"
  exit 0
fi

# mktemp の stderr を捨てない（read-only 以外の失敗を read-only へ誤帰属させない）。
_ff_mktemp_rc=0
_ff_mktemp_out="$(mktemp -d 2>&1)" || _ff_mktemp_rc=$?
if [ "$_ff_mktemp_rc" -eq 0 ] && [ -d "$_ff_mktemp_out" ]; then
  TMP="$_ff_mktemp_out"
else
  echo "○ skip: 一時ディレクトリを作成できない環境のためスキップ（検査は1件も実行されていません）"
  printf '  mktemp: %s\n' "$_ff_mktemp_out"
  exit 0
fi

# 途中死を沈黙させない（rc=0 のまま最後まで到達していない形を中断として扱う）。
FF_REACHED_END=0
_ff_exit_guard() {
  _ff_rc=$?
  rm -rf "$TMP"
  if [ "$_ff_rc" -eq 0 ] && [ "$FF_REACHED_END" -ne 1 ]; then
    echo "✗ adapter-argv-limit: 最後まで到達しませんでした（途中で中断）" >&2
    exit 1
  fi
  if [ "$_ff_rc" -ne 0 ] && [ "$FF_REACHED_END" -ne 1 ]; then
    echo "✗ adapter-argv-limit: サマリー前に中断しました (rc=${_ff_rc})" >&2
  fi
  exit "$_ff_rc"
}
trap _ff_exit_guard EXIT
trap 'exit 130' HUP INT TERM

PASS=0
FAIL=0
ok()  { echo "  ✓ $1"; PASS=$((PASS + 1)); }
bad() { echo "  ✗ $1" >&2; FAIL=$((FAIL + 1)); }

# ── fixture リポジトリ（ARG_MAX 超えの diff を持つ） ──
# 利用者環境の hook / template を継承させない（継承すると fixture の git commit が
# 利用者の hook を実行し、失敗が文脈なしの git エラーになる）。
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
REPO="$TMP/repo"
git init -q "$REPO"
git -C "$REPO" config user.email "test@example.com"
git -C "$REPO" config user.name "adapter-argv-limit-test"
git -C "$REPO" config commit.gpgsign false
git -C "$REPO" switch -q -c develop
echo base > "$REPO/app.txt"
git -C "$REPO" add app.txt
git -C "$REPO" commit -qm "init"
git -C "$REPO" switch -q -c feature/big

# 末尾マーカーは diff の**最後**に来る位置へ置く。先頭側だけ届く切り詰めを
# 「届いた」と読まないため（切り詰め変異はここで赤くなる）。
TAIL_MARKER='ARGV-LIMIT-DIFF-TAIL-MARKER'
TARGET_BYTES=$((ARG_MAX + 256 * 1024))
awk -v target="$TARGET_BYTES" -v marker="$TAIL_MARKER" '
  BEGIN {
    line = "argv-limit-fixture-payload-xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"
    n = int(target / (length(line) + 1)) + 1
    for (i = 0; i < n; i++) printf "%s-%08d\n", line, i
    print marker
  }' > "$REPO/big.txt"
git -C "$REPO" add big.txt
git -C "$REPO" commit -qm "oversized diff fixture"

DIFF_BYTES="$(git -C "$REPO" diff develop...HEAD | wc -c | tr -d ' ')"
if [ "$DIFF_BYTES" -gt "$ARG_MAX" ]; then
  ok "前提: fixture の diff ${DIFF_BYTES}B が ARG_MAX ${ARG_MAX}B を超えている"
else
  bad "前提が崩れている: diff ${DIFF_BYTES}B ≦ ARG_MAX ${ARG_MAX}B（この suite の主張が成立しない）"
fi

# ── perspective fixture ──
PERSPECTIVE="$TMP/perspective.md"
printf '%s\n' '# Fixture Perspective' 'Report findings.' > "$PERSPECTIVE"

# ── stub CLI（argv と stdin を記録し、受理されるレビュー本文を返す） ──
BIN="$TMP/bin"
GROK_HOME_DIR="$TMP/grok-home"
mkdir -p "$BIN" "$GROK_HOME_DIR"
# grok のサンドボックス肯定確認はイベントログを見る。stub は実行のたびに
# ProfileApplied を追記する（workspace はアダプタの CWD = `pwd -P` で相関される）。
for cli in claude codex copilot grok; do
  cat > "$BIN/$cli" <<SH
#!/usr/bin/env bash
prev=""
pf=""
for a in "\$@"; do
  printf '%s\n' "\$a" >> "$TMP/${cli}-argv.log"
  if [ "\$prev" = "--prompt-file" ]; then pf="\$a"; fi
  prev="\$a"
done
cat >> "$TMP/${cli}-stdin.log"
if [ -n "\$pf" ] && [ -f "\$pf" ]; then cat "\$pf" >> "$TMP/${cli}-stdin.log"; fi
if [ "\$(basename "\$0")" = "grok" ]; then
  printf '{"timestamp":"t","event_type":"ProfileApplied","profile":"read-only","enforced":true,"workspace":"%s"}\n' \\
    "\$(pwd -P)" >> "$GROK_HOME_DIR/sandbox-events.jsonl"
fi
echo "- Suggestion: stub review output"
SH
  chmod +x "$BIN/$cli"
done

echo "== ARG_MAX 超えの diff で 4 アダプタが完走する（Issue #1148） =="

check_adapter() { # $1: stub 名 / $2: アダプタファイル名
  local cli="$1" adapter="$2" rc=0 out="$TMP/out-${cli}.md"
  local argv_bytes stdin_bytes
  : > "$TMP/${cli}-argv.log"
  : > "$TMP/${cli}-stdin.log"
  set +e
  ( cd "$REPO" && run_isolated PATH="$BIN:$PATH" CODEX_HOME="$TMP/codex-home" GROK_HOME="$GROK_HOME_DIR" \
      bash "$ADAPTERS_DIR/$adapter" "$PERSPECTIVE" "$out" \
      --base develop --timeout 60 --task-type review \
  ) >"$TMP/${cli}.log" 2>&1
  rc=$?
  set -e

  if [ "$rc" -eq 0 ]; then
    ok "${cli}: ARG_MAX 超えの diff でも 0 終了（126 で落ちない）"
  else
    bad "${cli}: rc=${rc} で失敗（126 は execve の E2BIG＝プロンプトが argv に戻った形）"
    tail -8 "$TMP/${cli}.log" | sed 's/^/    | /' >&2
  fi

  if [ -f "$out" ] && grep -qF '<!-- Status: complete -->' "$out"; then
    ok "${cli}: 成果物が complete で残る"
  else
    bad "${cli}: 成果物が complete でない（完走していない）"
  fi

  argv_bytes="$(wc -c < "$TMP/${cli}-argv.log" | tr -d ' ')"
  stdin_bytes="$(wc -c < "$TMP/${cli}-stdin.log" | tr -d ' ')"
  # 下限も見る。起動できなかった回（execve が E2BIG）は argv ログが 0B になるので、
  # 上限だけの検査は「argv は小さい」で空振りの緑を出す。
  if [ "$argv_bytes" -gt 0 ] && [ "$argv_bytes" -lt 8192 ]; then
    ok "${cli}: argv ${argv_bytes}B < 8KB（diff ${DIFF_BYTES}B と独立）"
  elif [ "$argv_bytes" -eq 0 ]; then
    bad "${cli}: stub が起動していない（argv 0B — argv 検査が成立しない）"
  else
    bad "${cli}: argv ${argv_bytes}B が 8KB 以上（プロンプト規模が argv に乗っている）"
  fi

  if grep -qF "$TAIL_MARKER" "$TMP/${cli}-stdin.log"; then
    ok "${cli}: diff 末尾まで stdin / prompt-file 経由で届く（本文 ${stdin_bytes}B）"
  else
    bad "${cli}: diff 末尾が CLI へ届いていない（本文 ${stdin_bytes}B — 未達 or 切り詰め）"
  fi
}

check_adapter claude  claude-code-adapter.sh
check_adapter codex   codex-cli-adapter.sh
check_adapter copilot copilot-cli-adapter.sh
check_adapter grok    grok-cli-adapter.sh

echo ""
if [ "$FAIL" -eq 0 ]; then
  echo "✓ adapter-argv-limit verify: 全 ${PASS} 件 pass"
  FF_REACHED_END=1
  exit 0
fi
echo "✗ adapter-argv-limit verify: ${FAIL} 件失敗（pass ${PASS} 件）" >&2
FF_REACHED_END=1
exit 1
