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

# encode_path: 絶対パスを Claude Code と同じ規則（/ → -）でプロジェクト名へ変換する。
# setup_projects の外に置く（後から候補を足すヘルパーからも呼ぶため。中に閉じ込めると
# 「setup_projects を一度も呼ばずにヘルパーを使うと未定義」という順序依存が残る）。
encode_path() { printf '%s' "$1" | sed 's#/#-#g'; }

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

  # --- Issue #13 系の fixture ---
  # プロジェクトディレクトリ名は「セッション開始時 cwd の絶対パスを / → - でエンコード
  # した名前」で固定される。worktree へ移動して作業し worktree を削除すると、jsonl の
  # cwd は全滅するが、名前が指すリポジトリルートは現存する。この乖離を再現する。
  #
  # 名前解決は実FSへの照合なので、fixture の「生存パス」は実在ディレクトリでなければ
  # ならない。$WORK 配下に実体を作り、その絶対パスをエンコードした名前で projects/ に置く。

  # (A) name-alive-hyphen: 名前が「ハイフンを含む実在ディレクトリ」へ解決でき、
  #     cwd は全滅。tr '-' '/' では解けないパス形状を要求する（AC-2）。
  ALIVE_HYPHEN_REAL="$WORK/repo-root/ai-feel-chatbot"
  mkdir -p "$ALIVE_HYPHEN_REAL"
  ALIVE_HYPHEN_REAL="$(cd "$ALIVE_HYPHEN_REAL" && pwd -P)"
  ALIVE_HYPHEN_NAME="$(encode_path "$ALIVE_HYPHEN_REAL")"
  mkdir -p "$WORK/claude/projects/$ALIVE_HYPHEN_NAME"
  # cwd はすべて非現存（削除済み worktree 相当）
  {
    printf '%s\n' "{\"cwd\":\"${ALIVE_HYPHEN_REAL}/.claude/worktrees/funny-kare-3bd2f4\"}"
    printf '%s\n' "{\"cwd\":\"${GONE_PATH}\"}"
  } > "$WORK/claude/projects/$ALIVE_HYPHEN_NAME/session.jsonl"

  # (B) memory-guard: 名前は非現存パスへ解決される（生存判定では守れない）が、
  #     配下に空でない memory/ がある。cwd 全滅でも memory ガードで守られる（AC-4）。
  MEMORY_NAME="$(encode_path "$GONE_PATH")-memory-holder"
  mkdir -p "$WORK/claude/projects/$MEMORY_NAME/memory"
  printf '%s\n' "{\"cwd\":\"${GONE_PATH}\"}" > "$WORK/claude/projects/$MEMORY_NAME/session.jsonl"
  echo 'persistent note' > "$WORK/claude/projects/$MEMORY_NAME/memory/note.md"

  # (C) dot-dir 両綴り: ドット始まりディレクトリ .config を含む実在パス。Claude Code は
  #     これを -.config（ドット保持）とも --config（ドット化）とも綴る実測差がある。
  #     両綴りの名前で projects/ に置き、どちらも生存保護されることを固定する（レビュー W1）。
  DOTDIR_REAL="$WORK/dotroot/.config/proj"
  mkdir -p "$DOTDIR_REAL"
  DOTDIR_REAL="$(cd "$DOTDIR_REAL" && pwd -P)"
  # -.config 綴り（ドット保持）= 素直に / だけ - 化
  DOTKEEP_NAME="$(encode_path "$DOTDIR_REAL")"
  # --config 綴り（ドット化）= さらに "-." を "--" へ（ドットも - にした綴り）
  DOTDASH_NAME="$(printf '%s' "$DOTKEEP_NAME" | sed 's#-\.#--#g')"
  for nm in "$DOTKEEP_NAME" "$DOTDASH_NAME"; do
    mkdir -p "$WORK/claude/projects/$nm"
    printf '%s\n' "{\"cwd\":\"${GONE_PATH}\"}" > "$WORK/claude/projects/$nm/session.jsonl"
  done

  # (E) realistic-orphan: 先頭 - 付きの「本物の孤児」= 実在した絶対パスをエンコードした
  #     名前だが、そのパスはもう存在しない（リポジトリごと削除された）。memory/ も無い。
  #     name_resolves_to_live の本体（ルートから辿って行き止まり）を通り、従来どおり
  #     孤児回収されることを固定する（レビュー W3 / AC-3 の現実形）。
  REALISTIC_ORPHAN_NAME="$(encode_path "${GONE_PATH}/repo--claude-worktrees-deleted-xyz")"
  mkdir -p "$WORK/claude/projects/$REALISTIC_ORPHAN_NAME"
  printf '%s\n' "{\"cwd\":\"${GONE_PATH}/repo\"}" > "$WORK/claude/projects/$REALISTIC_ORPHAN_NAME/session.jsonl"

  # (F) false-protection 負例: 通常名 "plain" は存在せず、隠し ".plain" だけが実在する。
  #     素朴なドット無条件補完だと .plain へ誤解決して真の孤児を守り続けてしまう。
  #     ここでは「.plain 実在下でも plain 名は解決されない（=孤児回収される）」を要求する。
  #     （現実装は解決しうるが fail-closed 側なので、この負例で挙動を明示的に固定する）
  FP_ROOT="$WORK/fproot"
  mkdir -p "$FP_ROOT/.plain/child"
  FP_ROOT="$(cd "$FP_ROOT" && pwd -P)"
  FP_PLAIN_NAME="$(encode_path "$FP_ROOT/plain/child")"   # plain（ドット無し）は非現存
  mkdir -p "$WORK/claude/projects/$FP_PLAIN_NAME"
  printf '%s\n' "{\"cwd\":\"${GONE_PATH}\"}" > "$WORK/claude/projects/$FP_PLAIN_NAME/session.jsonl"

  # (G) empty-memory 負例: memory/ は在るが中身が空。memory ガードの契約は
  #     「空でない memory/ だけが保護理由」なので、これは保護されず孤児回収される。
  #     ここが `[ -d memory ]` だけの過剰保護へ退行すると、memory/ を持つだけの真の孤児が
  #     永久に残り、掃除機能が静かに無効化される。
  EMPTY_MEMORY_NAME="$(encode_path "$GONE_PATH")-empty-memory"
  mkdir -p "$WORK/claude/projects/$EMPTY_MEMORY_NAME/memory"
  printf '%s\n' "{\"cwd\":\"${GONE_PATH}\"}" > "$WORK/claude/projects/$EMPTY_MEMORY_NAME/session.jsonl"

  # (H) subdir-only-memory 負例: memory/ 配下にサブディレクトリだけがあり、非ディレクトリ
  #     実体（ファイル・symlink 等）が 1 つも無い。`find ! -type d` が何も返さない形で、
  #     (G) とは「空」の作られ方が違う。現契約では同じく保護されない。
  SUBDIR_MEMORY_NAME="$(encode_path "$GONE_PATH")-subdir-memory"
  mkdir -p "$WORK/claude/projects/$SUBDIR_MEMORY_NAME/memory/nested/deeper"
  printf '%s\n' "{\"cwd\":\"${GONE_PATH}\"}" > "$WORK/claude/projects/$SUBDIR_MEMORY_NAME/session.jsonl"

  export CLAUDE_CONFIG_DIR="$WORK/claude"
  export FF_SWEEP_PROJECTS_DIR="$WORK/claude/projects"
  export FF_SWEEP_ARCHIVE_DIR="$WORK/claude/transcript-archives"
}

# add_both_guard_candidate: 名前が現存パスへ解決でき、かつ空でない memory/ も持つ候補を
# 「setup_projects の後から」1 件だけ足す。setup_projects の中に入れないのは 2 つの理由による:
#   (1) 先勝ち順序の主張はカウンタの差分（追加前 → 追加後）でしか実体から導けない。常設
#       fixture にすると before が取れず、テスト側に期待値を書き写すことになる。
#   (2) この候補には MEMORY_NAME とは別のディレクトリを使う。MEMORY_NAME 自身に名前生存を
#       持たせると「MEMORY_NAME の唯一の防御が memory ガードである」という mutation 6 の
#       前提が崩れるため、そちらには手を入れない。
# 生存パスは name-alive fixture とは別ディレクトリにする（同じ実パスだと projects/ 配下の
# エンコード名が衝突し、2 件のはずが 1 件になる）。
add_both_guard_candidate() {
  BOTH_GUARD_REAL="$WORK/repo-root/both-guard-proj"
  mkdir -p "$BOTH_GUARD_REAL"
  BOTH_GUARD_REAL="$(cd "$BOTH_GUARD_REAL" && pwd -P)"
  BOTH_GUARD_NAME="$(encode_path "$BOTH_GUARD_REAL")"
  mkdir -p "$WORK/claude/projects/$BOTH_GUARD_NAME/memory"
  printf '%s\n' "{\"cwd\":\"${GONE_PATH}\"}" > "$WORK/claude/projects/$BOTH_GUARD_NAME/session.jsonl"
  echo 'persistent note' > "$WORK/claude/projects/$BOTH_GUARD_NAME/memory/note.md"
}

# サマリー行から数値カウンタを取り出す。$1 はサマリー出力全文。
# 行が無ければ空文字を返す（呼び出し側で非空を必ず確かめること。空のまま算術へ渡すと
# `set -u` 相当の事故ではなく「0 として通る」形になり、ラベル改名を緑で見逃す）。
name_alive_count() { printf '%s\n' "$1" | sed -n 's/^スキップ 名前生存(名前→現存パス): //p'; }
memory_skip_count() { printf '%s\n' "$1" | sed -n 's/^スキップ memory 保護(空でない memory\/): //p'; }

# $1: ラベル（診断用） $2: 名前生存カウンタ $3: memory カウンタ
require_counters() {
  [ -n "$2" ] || fail "$1: 名前生存カウンタ行を読めませんでした（ラベルが変わった疑い）"
  [ -n "$3" ] || fail "$1: memory 保護カウンタ行を読めませんでした（ラベルが変わった疑い）"
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

# ============================================================================
# Issue #13: 名前が現存パスへ解決される候補・memory/ 同居候補を守る
# ============================================================================

# --- 13a. 名前→現存パス解決の候補は cwd 全滅でも回収されない（AC-1, AC-2）---
# ハイフンを含む実在パスへ解決でき、cwd はすべて非現存。dry-run で孤児に挙がらず、
# --apply でも削除・アーカイブされないこと。tr '-' '/' では解けない形状で AC-2 も兼ねる。
setup_projects
OUT="$(run_sut 2>&1)" || fail "name-alive dry-run should exit 0: $OUT"
[[ "$OUT" != *"$ALIVE_HYPHEN_NAME"* ]] || fail "name-alive must not be listed as orphan (dry-run): $OUT"
setup_projects
OUT="$(run_sut --apply 2>&1)" || fail "name-alive apply should exit 0: $OUT"
[ -d "$WORK/claude/projects/$ALIVE_HYPHEN_NAME" ] || fail "name-alive (hyphenated real path) must survive --apply"
ARCH_NAME_ALIVE="$(find "$WORK/claude/transcript-archives" -name "${ALIVE_HYPHEN_NAME}-*.tar.gz" | wc -l | tr -d ' ')"
[ "$ARCH_NAME_ALIVE" -eq 0 ] || fail "name-alive must not be archived"
ok "name resolves to live (hyphenated) path → protected from apply (AC-1, AC-2)"

# --- 13b. サマリーに名前生存スキップの独立カウンタが「数値」で出る（AC-5）---
# ラベル存在だけの照合はカウンタが常に 0 でも通る死んだ検査になる（レビュー W2）。
# fixture では name-alive は少なくとも 3 件（ALIVE_HYPHEN + dot 両綴り 2 件）あるので、
# 具体的な下限値で固定する。
setup_projects
OUT="$(run_sut 2>&1)" || fail "summary dry-run should exit 0: $OUT"
NAME_LINE="$(printf '%s\n' "$OUT" | sed -n 's/^スキップ 名前生存(名前→現存パス): //p')"
[ -n "$NAME_LINE" ] || fail "summary must show a distinct name-alive counter line: $OUT"
[ "$NAME_LINE" -ge 3 ] || fail "name-alive counter must count all name-resolved candidates (>=3), got: $NAME_LINE"
ok "summary shows name-alive counter with correct numeric value (AC-5)"

# --- 13c. 空でない memory/ 同居候補は cwd 全滅でもスキップ（AC-4）---
setup_projects
OUT="$(run_sut --apply 2>&1)" || fail "memory-guard apply should exit 0: $OUT"
[ -d "$WORK/claude/projects/$MEMORY_NAME" ] || fail "candidate with non-empty memory/ must survive --apply"
ARCH_MEM="$(find "$WORK/claude/transcript-archives" -name "${MEMORY_NAME}-*.tar.gz" | wc -l | tr -d ' ')"
[ "$ARCH_MEM" -eq 0 ] || fail "memory-guarded candidate must not be archived"
# サマリーに memory ガードの独立カウンタが数値で出ること（1 件以上）。
OUT="$(run_sut 2>&1)" || fail "memory-guard dry-run should exit 0: $OUT"
MEM_LINE="$(printf '%s\n' "$OUT" | sed -n 's/^スキップ memory 保護(空でない memory\/): //p')"
[ -n "$MEM_LINE" ] || fail "summary must show a distinct memory-guard counter line: $OUT"
[ "$MEM_LINE" -ge 1 ] || fail "memory-guard counter must be >=1, got: $MEM_LINE"
ok "non-empty memory/ sibling → protected regardless of cwd, counter numeric (AC-4)"

# --- 13d. 名前も cwd も非現存なら従来どおり孤児回収（非回帰, AC-3）---
# 既存 orphan-proj は「名前がランダム文字列（非現存パスに解決不能）+ cwd 全滅」。
# 13 系の変更後もこれが孤児として回収されることを、専用に固定する。
setup_projects
OUT="$(run_sut --apply 2>&1)" || fail "non-regression apply should exit 0: $OUT"
[ ! -d "$WORK/claude/projects/orphan-proj" ] || fail "true orphan (name unresolvable + cwd gone) must still be swept (AC-3)"
ARCH_ORPHAN="$(find "$WORK/claude/transcript-archives" -name 'orphan-proj-*.tar.gz' | wc -l | tr -d ' ')"
[ "$ARCH_ORPHAN" -ge 1 ] || fail "true orphan must still be archived (AC-3)"
ok "true orphan still swept after #13 guards (non-regression, AC-3)"

# --- 13e. ドット始まりディレクトリの両綴り（-.config / --config）が保護される（レビュー W1）---
# 実装の要（ドット保持 / ドット化の両綴り対応）を実際に発火させる。両名とも cwd 全滅。
setup_projects
OUT="$(run_sut --apply 2>&1)" || fail "dotdir apply should exit 0: $OUT"
[ -d "$WORK/claude/projects/$DOTKEEP_NAME" ] || fail "dot-kept spelling (-.config) must survive --apply"
[ -d "$WORK/claude/projects/$DOTDASH_NAME" ] || fail "dot-dashed spelling (--config) must survive --apply"
ARCH_DK="$(find "$WORK/claude/transcript-archives" -name "${DOTKEEP_NAME}-*.tar.gz" | wc -l | tr -d ' ')"
ARCH_DD="$(find "$WORK/claude/transcript-archives" -name "${DOTDASH_NAME}-*.tar.gz" | wc -l | tr -d ' ')"
[ "$ARCH_DK" -eq 0 ] && [ "$ARCH_DD" -eq 0 ] || fail "dotdir spellings must not be archived"
ok "both dot spellings (-.config / --config) resolve to live and are protected (W1)"

# --- 13f. 先頭 - 付きの現実的な孤児は名前解決本体を通って回収される（レビュー W3 / AC-3）---
# orphan-proj は先頭 - 無しで case ガードで即 return 1 するため名前解決本体を通らない。
# ここは encode(削除済み絶対パス) の名前で、ルートから辿って行き止まり → 従来回収。
setup_projects
OUT="$(run_sut --apply 2>&1)" || fail "realistic-orphan apply should exit 0: $OUT"
[ ! -d "$WORK/claude/projects/$REALISTIC_ORPHAN_NAME" ] || fail "realistic orphan (leading-dash, gone root) must be swept (W3)"
ARCH_RO="$(find "$WORK/claude/transcript-archives" -name "${REALISTIC_ORPHAN_NAME}-*.tar.gz" | wc -l | tr -d ' ')"
[ "$ARCH_RO" -ge 1 ] || fail "realistic orphan must be archived (W3)"
ok "realistic leading-dash gone-root orphan still swept via resolver body (W3, AC-3)"

# --- 13g. 過剰保護しない: 通常名 plain は隠し .plain の存在では守られない（Codex 指摘）---
setup_projects
OUT="$(run_sut --apply 2>&1)" || fail "false-protection apply should exit 0: $OUT"
[ ! -d "$WORK/claude/projects/$FP_PLAIN_NAME" ] || fail "plain name must NOT be protected by a hidden .plain dir (over-protection)"
ok "plain name is not over-protected by a sibling hidden .plain (Codex)"

# --- 13h. 名前解決の予算切れは削除せず「判定不能」として保護 + 失敗計上（レビュー Critical A）---
# 極小の NAME_RESOLVE_BUDGET を注入し、生存するはずの name-alive が rc=2（判定不能）で
# 保護され、かつ非 0 終了（失敗計上）になることを固定する。予算切れが fail-open で
# 削除経路へ落ちない（＝生存プロジェクトが消えない）ことの回帰ガード。
setup_projects
set +e
OUT="$(NAME_RESOLVE_BUDGET=1 CLAUDE_CONFIG_DIR="$WORK/claude" FF_SWEEP_PROJECTS_DIR="$WORK/claude/projects" FF_SWEEP_ARCHIVE_DIR="$WORK/claude/transcript-archives" bash "$SUT" --apply 2>&1)"
RC=$?
set -e
[ -d "$WORK/claude/projects/$ALIVE_HYPHEN_NAME" ] || fail "budget-exhausted name-alive must be protected, not swept (Critical A)"
[ "$RC" -ne 0 ] || fail "budget-exhausted undecided must be reported as failure (non-zero exit)"
[[ "$OUT" == *"判定不能"* ]] || fail "undecided protection must be reported: $OUT"
ok "name-resolve budget exhaustion → protected + reported, never swept (Critical A)"

# root 判定は 1 回だけ確定する。13i のスキップ条件と末尾の検査総数ガードの両方が使うため、
# 2 箇所で独立に評価すると片方だけ変えたときに «恒常的に赤» か «1 件消失を見逃す» に倒れる。
IS_ROOT=0
if [ "$(id -u)" -eq 0 ]; then
  IS_ROOT=1
fi

# --- 13i. memory/ が読めない場合は削除せず保護 + 失敗計上（レビュー W1 silent-hunter）---
# memory/ を作って読めなくし（chmod 000）、cwd 全滅・名前非解決の候補が削除されず
# 保護され、非 0 終了になることを確認。root では chmod が効かないためスキップ。
if [ "$IS_ROOT" -eq 0 ]; then
  setup_projects
  UNREADABLE_NAME="$(encode_path "$GONE_PATH")-unreadable-memory"
  mkdir -p "$WORK/claude/projects/$UNREADABLE_NAME/memory/sub"
  printf '%s\n' "{\"cwd\":\"${GONE_PATH}\"}" > "$WORK/claude/projects/$UNREADABLE_NAME/session.jsonl"
  echo secret > "$WORK/claude/projects/$UNREADABLE_NAME/memory/sub/x.md"
  chmod 000 "$WORK/claude/projects/$UNREADABLE_NAME/memory"
  set +e
  OUT="$(run_sut --apply 2>&1)"
  RC=$?
  set -e
  chmod 755 "$WORK/claude/projects/$UNREADABLE_NAME/memory" 2>/dev/null || true
  [ -d "$WORK/claude/projects/$UNREADABLE_NAME" ] || fail "unreadable memory/ candidate must be protected, not swept (W1)"
  [ "$RC" -ne 0 ] || fail "unreadable memory/ must be reported as failure (non-zero exit)"
  ok "unreadable memory/ → protected + reported, never swept (W1 silent-hunter)"
else
  echo "  ○ skip: root では memory/ を読めなくできないため 13i をスキップ"
fi

# --- 13j. 空の memory/ は保護理由にならない（#533 AC-1）---
# memory ガードの契約は「空でない memory/」。`[ -d memory ]` だけの過剰保護へ退行すると
# memory/ を持つだけの真の孤児が永久に残り、掃除機能が静かに無効化される。
# 既存テストは「空でない memory/ は守られる」正例しか固定していないため、その裏を張る。
# mutation 7（過剰保護の注入）に対する green pin でもある。
setup_projects
OUT="$(run_sut --apply 2>&1)" || fail "empty-memory apply should exit 0: $OUT"
[ ! -d "$WORK/claude/projects/$EMPTY_MEMORY_NAME" ] || fail "empty memory/ must not protect a true orphan (over-protection)"
ARCH_EMPTY_MEM="$(find "$WORK/claude/transcript-archives" -name "${EMPTY_MEMORY_NAME}-*.tar.gz" | wc -l | tr -d ' ')"
[ "$ARCH_EMPTY_MEM" -ge 1 ] || fail "empty-memory orphan must be archived"
ok "empty memory/ is not a protection reason → still swept (AC-1)"

# --- 13k. memory/ にサブディレクトリだけなら保護されない（#533 AC-2）---
# (G) とは「空」の作られ方が違う（find ! -type d が何も返さない形）。現契約の明示的な固定。
setup_projects
OUT="$(run_sut --apply 2>&1)" || fail "subdir-only-memory apply should exit 0: $OUT"
[ ! -d "$WORK/claude/projects/$SUBDIR_MEMORY_NAME" ] || fail "memory/ with only subdirectories must not protect (over-protection)"
ARCH_SUBDIR_MEM="$(find "$WORK/claude/transcript-archives" -name "${SUBDIR_MEMORY_NAME}-*.tar.gz" | wc -l | tr -d ' ')"
[ "$ARCH_SUBDIR_MEM" -ge 1 ] || fail "subdir-only-memory orphan must be archived"
ok "memory/ holding only subdirectories is not a protection reason → still swept (AC-2)"

# --- 13l. 両ガード該当は名前生存の先勝ち（#533 AC-3）---
# 名前が現存パスへ解決でき、かつ空でない memory/ も持つ候補は、名前生存ガードが先に
# 発火して 名前生存 に計上される（memory 保護 には入らない）。順序が入れ替わっても
# 「どちらのガードでも保護される」ため、既存の保護テストは緑のまま通ってしまう。
# 期待値はテスト側に書かず、候補を 1 件足す前後の実測値の差分から導く。
setup_projects
OUT="$(run_sut 2>&1)" || fail "first-wins baseline dry-run should exit 0: $OUT"
NAME_BEFORE="$(name_alive_count "$OUT")"
MEM_BEFORE="$(memory_skip_count "$OUT")"
require_counters "first-wins baseline" "$NAME_BEFORE" "$MEM_BEFORE"
add_both_guard_candidate
OUT="$(run_sut 2>&1)" || fail "first-wins dry-run should exit 0: $OUT"
NAME_AFTER="$(name_alive_count "$OUT")"
MEM_AFTER="$(memory_skip_count "$OUT")"
require_counters "first-wins after" "$NAME_AFTER" "$MEM_AFTER"
[[ "$OUT" != *"$BOTH_GUARD_NAME"* ]] || fail "both-guard candidate must not be listed as orphan: $OUT"
[ "$((NAME_AFTER - NAME_BEFORE))" -eq 1 ] \
  || fail "both-guard candidate must add exactly 1 to the name-alive counter (before=$NAME_BEFORE after=$NAME_AFTER)"
[ "$((MEM_AFTER - MEM_BEFORE))" -eq 0 ] \
  || fail "both-guard candidate must add 0 to the memory counter — name guard wins first (before=$MEM_BEFORE after=$MEM_AFTER)"
ok "candidate matching both guards counts as name-alive only, memory +0 (first-wins order, AC-3)"

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

# --- 5. 変異: 名前生存ガードを外すと name-alive を消す — 検出力の固定（Issue #13）---
# 健全な実装では name-alive が残ることを 13a で固定済み。ここでは name_resolves_to_live
# を常に「解決不能（=生存でない）」へ倒す変異を注入し、name-alive が消えることを確認する。
# これにより 13a が本当に名前解決ガードを検査していることを担保する。
setup_projects
MUT2="$WORK/mut-name.sh"
cp "$SUT" "$MUT2"
# 生存判定関数の本体を「常に非生存」へ差し替える。関数名は実装で固定した契約。
python3 - "$MUT2" <<'PY'
import pathlib, re, sys
p = pathlib.Path(sys.argv[1])
text = p.read_text()
# name_resolves_to_live() の定義直後に `return 1`（=生存でない）を注入して短絡させる。
anchor = 'name_resolves_to_live() {\n'
if anchor not in text:
    raise SystemExit('name-resolution mutation anchor missing (implementation drifted)')
mutated = text.replace(anchor, anchor + '  return 1  # MUTATION: force unresolved\n', 1)
if mutated == text:
    raise SystemExit('name-resolution mutation had no effect')
p.write_text(mutated)
PY
# memory ガードも同時に潰す（name-alive fixture は memory を持たないが、防御的に）。
python3 - "$MUT2" <<'PY'
import pathlib, sys
p = pathlib.Path(sys.argv[1])
text = p.read_text()
anchor = 'has_nonempty_memory() {\n'
if anchor not in text:
    raise SystemExit('memory-guard mutation anchor missing (implementation drifted)')
p.write_text(text.replace(anchor, anchor + '  return 1  # MUTATION: force no-memory\n', 1))
PY
set +e
OUT="$(CLAUDE_CONFIG_DIR="$WORK/claude" FF_SWEEP_PROJECTS_DIR="$WORK/claude/projects" FF_SWEEP_ARCHIVE_DIR="$WORK/claude/transcript-archives" bash "$MUT2" --apply 2>&1)"
set -e
# 変異後は名前生存ガードが効かず、cwd 全滅の name-alive が孤児として消えるはず。
if [ -d "$WORK/claude/projects/$ALIVE_HYPHEN_NAME" ]; then
  fail "mutation did not break name-alive protection (test ineffective)"
fi
ok "mutation: disabling name-resolution guard deletes name-alive (detector works)"

# --- 6. 変異: memory ガードを外すと memory 同居候補を消す — 検出力の固定（Issue #13）---
setup_projects
MUT3="$WORK/mut-mem.sh"
cp "$SUT" "$MUT3"
python3 - "$MUT3" <<'PY'
import pathlib, sys
p = pathlib.Path(sys.argv[1])
text = p.read_text()
anchor = 'has_nonempty_memory() {\n'
if anchor not in text:
    raise SystemExit('memory-guard mutation anchor missing (implementation drifted)')
p.write_text(text.replace(anchor, anchor + '  return 1  # MUTATION: force no-memory\n', 1))
PY
set +e
OUT="$(CLAUDE_CONFIG_DIR="$WORK/claude" FF_SWEEP_PROJECTS_DIR="$WORK/claude/projects" FF_SWEEP_ARCHIVE_DIR="$WORK/claude/transcript-archives" bash "$MUT3" --apply 2>&1)"
set -e
# memory ガードだけを潰す。MEMORY_NAME は名前が非現存パスへ解決されるため、memory ガードが
# 唯一の防御。これが外れると消えるはず。
if [ -d "$WORK/claude/projects/$MEMORY_NAME" ]; then
  fail "mutation did not break memory guard (test ineffective)"
fi
ok "mutation: disabling memory guard deletes memory-sibling (detector works)"

# --- 7. 変異: memory/ が「空でない」という条件だけを外す（#533 AC-4）---
# 13j / 13k が本当に「空でない」の部分を検査しているかを実測する。
# 変異は最小にして、空判定の結論だけを常に「空でない（保護）」へ倒す。関数の入口を
# `[ -d "$1/memory" ]` へ丸ごと差し替える形（Issue が名指しした退行）でも 13j / 13k は
# 赤くなるが、それは読めない memory/ の判定不能経路まで同時に潰すため 13i も巻き添えで
# 赤くなる（実測）。13i は 13j より前に走るので、その形では「13j / 13k が無くても
# suite は赤い」— 新しい 2 件が振る舞いの検出器であることを実測できない。ここでは
# 判定不能経路を残したまま空判定だけを倒す。この形を実装本体へ入れると、13i まで緑の
# まま 13j / 13k が赤くなることを確認してある。
# 注意（«間違った理由で赤い» の切り分け）: 同じ退行を実装本体へ入れると下のアンカー
# `[ -n "$found" ]` も一致しなくなり、本節は「実装がドリフトした」としても赤くなる。
# それはドリフト検出であって振る舞いの検出ではない。振る舞いの検出器は 13j / 13k で、
# 本節はその 2 件が空判定を見ていることの裏取りとして読むこと。
setup_projects
MUT4="$WORK/mut-bare-memory.sh"
cp "$SUT" "$MUT4"
python3 - "$MUT4" <<'PY'
import pathlib, sys
p = pathlib.Path(sys.argv[1])
text = p.read_text()
anchor = '  [ -n "$found" ]\n}\n'
if anchor not in text:
    raise SystemExit('emptiness-decision mutation anchor missing (implementation drifted)')
inject = '  [ -n "$found" ] || return 0  # MUTATION: treat an empty memory/ as non-empty\n}\n'
p.write_text(text.replace(anchor, inject, 1))
PY
# rc を捨てると変異体が途中死しても「過剰保護された」形のアサートは通ってしまう。
# この変異では判定不能（rc=2）の候補を作らないので rc=0 が期待値。
OUT="$(CLAUDE_CONFIG_DIR="$WORK/claude" FF_SWEEP_PROJECTS_DIR="$WORK/claude/projects" FF_SWEEP_ARCHIVE_DIR="$WORK/claude/transcript-archives" bash "$MUT4" --apply 2>&1)" \
  || fail "emptiness mutant should exit 0: $OUT"
# 過剰保護の変異では 13j / 13k の 2 件だけが残る（= 赤化する）。
[ -d "$WORK/claude/projects/$EMPTY_MEMORY_NAME" ] || fail "emptiness mutation did not over-protect empty memory/ (test ineffective)"
[ -d "$WORK/claude/projects/$SUBDIR_MEMORY_NAME" ] || fail "emptiness mutation did not over-protect subdir-only memory/ (test ineffective)"
# memory/ を持たない真の孤児は影響を受けない = 当該ケースだけが赤化することの実測。
[ ! -d "$WORK/claude/projects/orphan-proj" ] || fail "emptiness mutation must not affect a memory-less orphan (mutation too broad)"
ok "mutation: dropping the non-empty condition strands empty and subdir-only candidates (detector works)"

# --- 8. 変異: 2 つのガードの評価順を入れ替える（#533 AC-4）---
# 13l の先勝ち主張の検出力。両ガードに該当する候補はどちらの順でも「保護される」ため、
# 保護の有無しか見ない既存テストは入れ替えても緑のまま通る（それを同時に実測する）。
# 期待値は 13l と同じく、候補を足す前後のカウンタ差分から導く。
# この変異が赤化しなければ、順序ではなく fixture 側（memory/ が空・名前が非解決）を疑うこと。
setup_projects
MUT5="$WORK/mut-guard-order.sh"
cp "$SUT" "$MUT5"
python3 - "$MUT5" <<'PY'
import pathlib, sys
p = pathlib.Path(sys.argv[1])
text = p.read_text()
# 境界はコードだけで取る。コメント（`# (2)` 等）を境界に使うと、採番の変更や言い換えという
# 純粋に非振る舞いの編集で «間違った理由で赤い» を作ってしまう。
FI = '  fi\n'
try:
    a_start = text.index('  NAME_VERDICT=0\n')
    a_end = text.index(FI, a_start) + len(FI)
    b_start = text.index('  MEM_VERDICT=0\n', a_end)
    b_end = text.index(FI, b_start) + len(FI)
except ValueError:
    raise SystemExit('guard-order mutation anchors missing (implementation drifted)')
name_block = text[a_start:a_end]
mem_block = text[b_start:b_end]
between = text[a_end:b_start]
p.write_text(text[:a_start] + mem_block + between + name_block + text[b_end:])
PY
run_mut_order() {
  CLAUDE_CONFIG_DIR="$WORK/claude" FF_SWEEP_PROJECTS_DIR="$WORK/claude/projects" \
    FF_SWEEP_ARCHIVE_DIR="$WORK/claude/transcript-archives" bash "$MUT5" 2>&1
}
OUT="$(run_mut_order)" || fail "guard-order mutant baseline dry-run should exit 0: $OUT"
NAME_MUT_BEFORE="$(name_alive_count "$OUT")"
MEM_MUT_BEFORE="$(memory_skip_count "$OUT")"
require_counters "guard-order baseline" "$NAME_MUT_BEFORE" "$MEM_MUT_BEFORE"
add_both_guard_candidate
OUT="$(run_mut_order)" || fail "guard-order mutant dry-run should exit 0: $OUT"
NAME_MUT_AFTER="$(name_alive_count "$OUT")"
MEM_MUT_AFTER="$(memory_skip_count "$OUT")"
require_counters "guard-order after" "$NAME_MUT_AFTER" "$MEM_MUT_AFTER"
[ "$((MEM_MUT_AFTER - MEM_MUT_BEFORE))" -eq 1 ] \
  || fail "guard-order mutation did not move the candidate into the memory counter (test ineffective)"
[ "$((NAME_MUT_AFTER - NAME_MUT_BEFORE))" -eq 0 ] \
  || fail "guard-order mutation left the candidate in the name-alive counter (mutation had no effect)"
# 入れ替えても「保護される」ことは変わらず、名前生存の下限（13b）も満たしたままである。
# = 保護の有無しか見ない検査では順序の入れ替わりを検出できない、という前提の実測。
# なお実装本体へ同じ入れ替えを入れた場合、suite は fail-fast なので 13l で止まる。
# そこまでに走る保護検査（13a〜13k）が緑であることは実測したが、13l より後ろの検査に
# ついては「緑である」ではなく「未実行」であり、そう読むこと。
[[ "$OUT" != *"$BOTH_GUARD_NAME"* ]] || fail "guard-order mutation must still protect the candidate: $OUT"
[ "$NAME_MUT_AFTER" -ge 3 ] || fail "guard-order mutation must keep other name-alive candidates counted, got: $NAME_MUT_AFTER"
ok "mutation: swapping guard order reattributes the both-guard candidate to memory (detector works)"

# --- 9. 変異: memory/ の「非ディレクトリ実体」条件だけを外す（13k の固有検出器）---
# 13k を 13j と別建てにした理由は述語 `! -type d` にある（(H) は「空」の作られ方が (G) と
# 違い、find が何も返さない理由が「中身が無い」ではなく「ディレクトリしか無い」）。変異 7 は
# 空判定の結論（`[ -n "$found" ]`）を倒すので (G)(H) を同時に過剰保護し、13j の検出器を
# 2 回証明する一方で 13k の固有性は 1 度も測らない。ここでは述語だけを落として (H) だけが
# 過剰保護される形を作り、13k が単独で赤くなることを実測する。
setup_projects
MUT6="$WORK/mut-nondir-predicate.sh"
cp "$SUT" "$MUT6"
python3 - "$MUT6" <<'PY'
import pathlib, sys
p = pathlib.Path(sys.argv[1])
text = p.read_text()
anchor = '-mindepth 1 ! -type d -print -quit'
if anchor not in text:
    raise SystemExit('non-dir predicate mutation anchor missing (implementation drifted)')
p.write_text(text.replace(anchor, '-mindepth 1 -print -quit', 1))
PY
OUT="$(CLAUDE_CONFIG_DIR="$WORK/claude" FF_SWEEP_PROJECTS_DIR="$WORK/claude/projects" FF_SWEEP_ARCHIVE_DIR="$WORK/claude/transcript-archives" bash "$MUT6" --apply 2>&1)" \
  || fail "non-dir predicate mutant should exit 0: $OUT"
[ -d "$WORK/claude/projects/$SUBDIR_MEMORY_NAME" ] \
  || fail "non-dir predicate mutation did not over-protect subdir-only memory/ (13k has no unique detector)"
# (G) は依然として空なので影響を受けない = 13j ではなく 13k だけを狙えていることの実測。
[ ! -d "$WORK/claude/projects/$EMPTY_MEMORY_NAME" ] \
  || fail "non-dir predicate mutation must not affect an empty memory/ (mutation too broad)"
[ ! -d "$WORK/claude/projects/orphan-proj" ] \
  || fail "non-dir predicate mutation must not affect a memory-less orphan (mutation too broad)"
ok "mutation: dropping the non-directory predicate strands only subdir-only candidates (13k is a unique detector)"

# re-run healthy apply path already covered; ensure healthy still protects after mutation file discarded
setup_projects
OUT="$(run_sut --apply 2>&1)" || fail "healthy apply after mutation test"
[ -d "$WORK/claude/projects/live-proj" ] || fail "healthy apply must keep live"
[ -d "$WORK/claude/projects/$ALIVE_HYPHEN_NAME" ] || fail "healthy apply must keep name-alive"
[ -d "$WORK/claude/projects/$MEMORY_NAME" ] || fail "healthy apply must keep memory-sibling"
ok "healthy apply still protects live/name-alive/memory after mutation experiments"

# 検査総数を固定する。個々のアサートは「実行されなくなった」形を捕まえられないため、
# ケースが黙って消える侵食はここでだけ赤くなる。ケースを増減したら期待値も更新すること。
# 減っている場合は、まずケースが実行されなくなっていないかを疑う。
# 13i（memory/ を読めなくする検査）は root では chmod が効かずスキップされるので、
# 期待値は実行ユーザーで分岐する（固定値ひとつだと root 実行で必ず赤くなる）。
# 内訳: 16 → 22（+6）。空の memory/ が保護理由にならないこと 1 件 / memory/ が
# サブディレクトリだけの場合も同じであること 1 件 / 両ガード該当時の先勝ち順序 1 件 /
# それぞれの検出力を実測する変異 3 件（過剰保護への退行・ガード順の入れ替え・
# 非ディレクトリ述語の脱落）。
if [ "$IS_ROOT" -eq 0 ]; then
  EXPECTED_PASS=22
else
  EXPECTED_PASS=21
fi
if [ "$PASS" -ne "$EXPECTED_PASS" ]; then
  echo "✗ sweep-orphan-transcripts: 検査総数が想定と違います（期待 ${EXPECTED_PASS} / 実際 ${PASS}）" >&2
  echo "  ケースを増減したなら EXPECTED_PASS を更新すること。減っている場合は、" >&2
  echo "  ケースが黙って実行されなくなっていないかを先に確認すること。" >&2
  exit 1
fi
echo "✓ sweep-orphan-transcripts: ${PASS} checks passed（検査総数の固定値と一致）"
FF_REACHED_END=1
exit 0
