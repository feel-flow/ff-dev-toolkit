#!/usr/bin/env bash
# sweep-orphan-transcripts: 孤児トランスクリプト sweep の回帰テスト
# 実 ~/.claude は触らない。隔離した一時ディレクトリだけで完結する。

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SUT="$PLUGIN_ROOT/scripts/sweep-orphan-transcripts.sh"

if [ ! -f "$SUT" ]; then
  echo "✗ script not found: $SUT" >&2
  exit 1
fi

# mktemp の stderr を捨てない。捨てると read-only 以外の失敗（TMPDIR が不正な
# パス・quota 超過など）まで「書き込み可能な環境で再実行してください」に
# 誤帰属し、恒常的に壊れた TMPDIR が suite を exit 0 で無効化し続ける。
# 2>&1 で受けると、成功時はパス・失敗時は理由が同じ変数に入る。
if _ff_mktemp_out="$(mktemp -d "${TMPDIR:-/tmp}/sweep-orphan-test.XXXXXX" 2>&1)"; then
  WORK="$_ff_mktemp_out"
else
  echo "○ skip: 一時ディレクトリを作成できないためスキップ（本 suite の検査は1件も実行されていません。書き込み可能な環境で再実行してください）"
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
  rm -rf "$WORK"
  if [ "$_ff_rc" -eq 0 ] && [ "$FF_REACHED_END" -ne 1 ]; then
    echo "✗ sweep-orphan-transcripts: 最後まで到達しませんでした（途中で中断）" >&2
    exit 1
  fi
  exit "$_ff_rc"
}
trap _ff_exit_guard EXIT

PASS=0
fail() {
  echo "✗ $1" >&2
  exit 1
}
ok() {
  PASS=$((PASS + 1))
  echo "  ✓ $1"
}

setup_projects() {
  # $WORK/claude/{projects,transcript-archives}
  rm -rf "$WORK/claude"
  mkdir -p "$WORK/claude/projects" "$WORK/claude/transcript-archives" "$WORK/live-cwd" "$WORK/gone-cwd-placeholder"
  # gone path: create then remove so we have a concrete path string
  GONE_PATH="$WORK/was-here-but-gone"
  mkdir -p "$GONE_PATH"
  GONE_PATH="$(cd "$GONE_PATH" && pwd -P)"
  rmdir "$GONE_PATH"

  LIVE_PATH="$(cd "$WORK/live-cwd" && pwd -P)"

  # orphan: cwd points to missing path
  mkdir -p "$WORK/claude/projects/orphan-proj"
  printf '%s\n' "{\"cwd\":\"${GONE_PATH}\"}" > "$WORK/claude/projects/orphan-proj/session.jsonl"
  mkdir -p "$WORK/claude/projects/orphan-proj/subagents"
  echo leftover > "$WORK/claude/projects/orphan-proj/subagents/agent.jsonl"

  # live: cwd exists
  mkdir -p "$WORK/claude/projects/live-proj"
  printf '%s\n' "{\"cwd\":\"${LIVE_PATH}\"}" > "$WORK/claude/projects/live-proj/session.jsonl"

  # no cwd: skill injection only
  mkdir -p "$WORK/claude/projects/no-cwd-proj"
  echo '{"type":"skill"}' > "$WORK/claude/projects/no-cwd-proj/skill-injections.jsonl"

  # mixed: one gone + one live → treat as live (do not sweep)
  mkdir -p "$WORK/claude/projects/mixed-proj"
  {
    printf '%s\n' "{\"cwd\":\"${GONE_PATH}\"}"
    printf '%s\n' "{\"cwd\":\"${LIVE_PATH}\"}"
  } > "$WORK/claude/projects/mixed-proj/session.jsonl"

  export CLAUDE_CONFIG_DIR="$WORK/claude"
  export FF_SWEEP_PROJECTS_DIR="$WORK/claude/projects"
  export FF_SWEEP_ARCHIVE_DIR="$WORK/claude/transcript-archives"
}

run_sut() {
  bash "$SUT" "$@"
}

# --- 1. dry-run が既定で削除しない ---
setup_projects
OUT="$(run_sut 2>&1)" || fail "dry-run should exit 0: $OUT"
# パイプ + grep -q は使わない（run-all case 10 の SIGPIPE 再混入ガード）
[[ "$OUT" == *'orphan-proj'* ]] || fail "dry-run should list orphan-proj"
[[ "$OUT" == *'dry-run'* ]] || fail "dry-run mode label"
[ -d "$WORK/claude/projects/orphan-proj" ] || fail "dry-run must not delete orphan"
[ -d "$WORK/claude/projects/live-proj" ] || fail "live must remain"
[ -d "$WORK/claude/projects/no-cwd-proj" ] || fail "no-cwd must remain"
[ -d "$WORK/claude/projects/mixed-proj" ] || fail "mixed must remain"
ok "dry-run lists orphan and deletes nothing"

# --- 2. --apply は孤児だけ回収し live/no-cwd/mixed を残す ---
setup_projects
OUT="$(run_sut --apply 2>&1)" || fail "apply should exit 0: $OUT"
[ ! -d "$WORK/claude/projects/orphan-proj" ] || fail "orphan should be removed"
[ -d "$WORK/claude/projects/live-proj" ] || fail "live must remain after apply"
[ -d "$WORK/claude/projects/no-cwd-proj" ] || fail "no-cwd must remain after apply"
[ -d "$WORK/claude/projects/mixed-proj" ] || fail "mixed must remain after apply"
ARCH_COUNT="$(find "$WORK/claude/transcript-archives" -name 'orphan-proj-*.tar.gz' | wc -l | tr -d ' ')"
[ "$ARCH_COUNT" -ge 1 ] || fail "archive file should exist"
# subagents もアーカイブに含まれる
ARCHIVE_FILE="$(find "$WORK/claude/transcript-archives" -name 'orphan-proj-*.tar.gz' | head -1)"
ARCHIVE_LIST="$(tar -tzf "$ARCHIVE_FILE")"
[[ "$ARCHIVE_LIST" == *'subagents'* ]] || fail "archive should include subagents"
ok "apply archives orphan (with subagents) and keeps live/no-cwd/mixed"

# --- 3. 未知引数は usage error ---
setup_projects
set +e
OUT="$(run_sut --delete-all 2>&1)"
RC=$?
set -e
[ "$RC" -eq 2 ] || fail "unknown arg should exit 2, got $RC"
ok "unknown argument rejected with exit 2"

# --- 4. 変異: cwd 照合を壊すと live を消す危険 — 検出力の固定 ---
# 健全な実装では live が残ることを上で固定済み。ここでは「orphan 判定を
# 常に true にする」変異をスクリプトへ注入して red になることを確認する。
setup_projects
MUT="$WORK/mut-sut.sh"
cp "$SUT" "$MUT"
# collect_cwds の live 判定を無効化（存在する cwd を無視）
# shellcheck disable=SC2016
if ! grep -q 'if \[ -d "\$value" \]; then' "$MUT"; then
  fail "mutation target not found (implementation drifted)"
fi
# macOS sed: use python for portability
python3 - "$MUT" <<'PY'
import pathlib, sys
p = pathlib.Path(sys.argv[1])
text = p.read_text()
old = 'if [ -d "$value" ]; then\n      return 3\n    fi'
new = 'if false; then\n      return 3\n    fi'
if old not in text:
    raise SystemExit('mutation anchor missing')
p.write_text(text.replace(old, new, 1))
PY
set +e
OUT="$(CLAUDE_CONFIG_DIR="$WORK/claude" FF_SWEEP_PROJECTS_DIR="$WORK/claude/projects" FF_SWEEP_ARCHIVE_DIR="$WORK/claude/transcript-archives" bash "$MUT" --apply 2>&1)"
set -e
# 変異後は live も消えるはず → この状態を「悪い実装」として検出し、
# 健全な verify が live 残存を要求していることの意味を固定する。
if [ -d "$WORK/claude/projects/live-proj" ]; then
  fail "mutation did not break live protection (test ineffective)"
fi
ok "mutation: disabling live-cwd check deletes live (detector works)"

# re-run healthy apply path already covered; ensure healthy still protects after mutation file discarded
setup_projects
OUT="$(run_sut --apply 2>&1)" || fail "healthy apply after mutation test"
[ -d "$WORK/claude/projects/live-proj" ] || fail "healthy apply must keep live"
ok "healthy apply still protects live after mutation experiment"

echo "✓ sweep-orphan-transcripts: ${PASS} checks passed"
FF_REACHED_END=1
exit 0
FF_REACHED_END=1
