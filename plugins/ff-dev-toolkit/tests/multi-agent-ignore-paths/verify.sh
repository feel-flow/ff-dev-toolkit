#!/usr/bin/env bash
#
# multi-agent.sh のツリー変化判定パス除外（Issue #747）の回帰テスト。
#
# 常駐ツール（superpowers スキルが作る .superpowers/ 等）が実行中にツリーを触る
# リポジトリでは、リビジョンガードが毎回発火して全タスク成功後の結果が丸ごと
# 破棄される。除外の口（FF_MULTI_AGENT_IGNORE_PATHS + 既定の .superpowers/**）が
#   (a) 除外パス配下の変化（untracked / tracked dirty / index-only）では破棄しない
#   (b) 除外の外の変化では従来どおり破棄する
#   (c) 空パターン・空白付きパターン・文字クラス（':' 区切りと衝突して黙って分断）・
#       glob magic で何にも一致しない '.' / '/' 単体は起動前に中断する（fail-closed）
#   (d) 既定 .superpowers/** が env 未設定でも効き、効いたことをログへ 1 行出す。
#       env 指定は既定への**追加**で置き換えではない（同一実行で両方が生きる）
# ことを固定する。除外は**作業ツリー判定だけ**に効き、HEAD / ブランチの変化検出には
# 影響しないこと（実行中 commit は除外全開でも破棄）も併せて固定する。
# glob 意味論は git 2.50.1 の実測に合わせる: '**' と '**/*' は全パス一致（警告つきで
# 許容）、'*' は '/' を跨がず直下のみ（警告なし）、'.' / '/' は何にも一致しない（拒否。
# '/' は肯定形 :(glob,top)/ が rc=128 で落ちるため報告クエリごと壊れる）。
#
# 実 CLI は 1 つも起動しない（stub で覆う）。書き込み不可の環境では skip。

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
MULTI_AGENT="$PLUGIN_ROOT/scripts/multi-agent.sh"
ADAPTER_COMMON="$PLUGIN_ROOT/scripts/adapters/adapter-common.sh"

[ -f "$MULTI_AGENT" ] || { echo "✗ multi-agent.sh が見つかりません" >&2; exit 1; }
[ -f "$ADAPTER_COMMON" ] || { echo "✗ adapter-common.sh が見つかりません" >&2; exit 1; }

# 実行環境の MULTI_AGENT_* / FF_MULTI_AGENT_* からの分離。FF_MULTI_AGENT_IGNORE_PATHS
# はまさに本 suite の被検体つまみなので、ホストの設定が漏れると全ケースの前提が崩れる。
# センチネルに含めて、抽出（tests/lib の FF_MULTI_AGENT 対応）ごと fail-closed で検査する。
# **存在検査より後に置くこと**（先に置くと被検体不在の診断が抽出失敗に化ける）。
# shellcheck source=../lib/adapter-env-isolation.sh
. "$PLUGIN_ROOT/tests/lib/adapter-env-isolation.sh"
build_isolate_env "MULTI_AGENT_CONFIG FF_MULTI_AGENT_IGNORE_PATHS" \
  "$MULTI_AGENT" "$PLUGIN_ROOT"/scripts/adapters/*.sh

PASS=0
FAIL=0
ok()  { echo "  ✓ $1"; PASS=$((PASS + 1)); }
bad() { echo "  ✗ $1" >&2; FAIL=$((FAIL + 1)); }

# rc=0 でも -d を検査する — 2>&1 の合流は「成功 + stderr 警告」の環境で変数へ
# 警告文が混入し、以後の処理が原因不明の失敗に化けるため。
if _ff_mktemp_out="$(mktemp -d 2>&1)" && [ -d "$_ff_mktemp_out" ]; then
  TMP="$_ff_mktemp_out"
else
  echo "○ skip: 一時ディレクトリを作成できない環境のためスキップ"
  printf '  mktemp: %s\n' "$_ff_mktemp_out"
  exit 0
fi
trap 'cd /; rm -rf "$TMP"' EXIT

# ── 被検体リポジトリ ──
REPO="$TMP/repo"
git init -q "$REPO"
cd "$REPO"
git config user.email "test@example.com"
git config user.name "multi-agent-ignore-paths-test"
git config commit.gpgsign false
git switch -q -c develop
mkdir -p src
echo base > src/app.txt
git add src/app.txt
git commit -qm "init"
git switch -q -c feature/x
printf 'base\nchange\n' > src/app.txt
git add src/app.txt
git commit -qm "change"

CLEAN_HEAD="$(git rev-parse HEAD)"
reset_repo() {
  cd "$REPO"
  git switch -q feature/x 2>/dev/null || true
  git reset -q --hard "$CLEAN_HEAD"
  git clean -qfd -e .review-results
  rm -rf "$REPO/.superpowers" "$REPO/cache"
}

# ══════════════════════════════════════════════════════════════
echo "== 単体: capture_repo_snapshot の追加除外 pathspec =="
# ══════════════════════════════════════════════════════════════
# shellcheck source=../../scripts/adapters/adapter-common.sh
. "$ADAPTER_COMMON"
# adapter-common.sh は source 時に無条件で EXIT trap を張る（既存 trap を保存しない）
# ため張り直す — 奪われたままだと実行のたびに mktemp -d が残る。
trap 'cd /; rm -rf "$TMP"' EXIT

BASE_SNAP="$(capture_repo_snapshot '' ':(exclude,glob,top)cache/**')"
mkdir -p cache
echo blob > cache/blob.bin
AFTER_SNAP="$(capture_repo_snapshot '' ':(exclude,glob,top)cache/**')"
if [[ -n "$BASE_SNAP" && "$AFTER_SNAP" == "$BASE_SNAP" ]]; then
  ok "追加除外 pathspec 配下への書き込みは変化として数えない"
else
  bad "追加除外 pathspec が効いていない"
fi
# 除外しなければ同じ書き込みが見えること = 検査が空振りしていない証拠
if [[ "$(capture_repo_snapshot)" != "$BASE_SNAP" ]]; then
  ok "前提: 除外を外せば同じ書き込みが変化として見える（検査が空振りしていない）"
else
  bad "前提が崩れた: 除外の有無で結果が変わらない"
fi
# 除外は作業ツリー判定だけに効き、HEAD / ブランチには効かないこと
git commit -q --allow-empty -m "moves during the run"
if [[ "$(capture_repo_snapshot '' ':(exclude,glob,top)cache/**')" != "$BASE_SNAP" ]]; then
  ok "追加除外があっても HEAD の変化（commit）は検出する"
else
  bad "追加除外が HEAD の変化検出まで消している"
fi
reset_repo

# --- 除外配下の tracked / index の変化も一様に数えない（4 問い合わせの一様性） ---
# 除外は status / diff HEAD / diff --cached / untracked 内容のすべてに同じものが
# 掛かる契約。untracked（status 面）だけで検査すると、diff 系から除外が落ちる退行
#（「同じリポジトリを 2 つの物差しで測る」形）が緑のまま通る。
mkdir -p vendor
echo v > vendor/lib.txt
git add vendor/lib.txt
git commit -qm "vendor"
TRACKED_EXCL="$(capture_repo_snapshot '' ':(exclude,glob,top)vendor/**')"
TRACKED_PLAIN="$(capture_repo_snapshot)"
echo "dirty edit" >> vendor/lib.txt
if [[ "$(capture_repo_snapshot '' ':(exclude,glob,top)vendor/**')" == "$TRACKED_EXCL" ]]; then
  ok "除外配下の tracked ファイルの編集（diff HEAD 面）も変化として数えない"
else
  bad "除外が diff HEAD 面に効いていない（tracked の編集で発火する）"
fi
git add vendor/lib.txt
if [[ "$(capture_repo_snapshot '' ':(exclude,glob,top)vendor/**')" == "$TRACKED_EXCL" ]]; then
  ok "除外配下の index 内容の変化（diff --cached 面）も変化として数えない"
else
  bad "除外が diff --cached 面に効いていない（index の変化で発火する）"
fi
if [[ "$(capture_repo_snapshot)" != "$TRACKED_PLAIN" ]]; then
  ok "前提: 除外を外せば tracked / index の同じ変化が見える（検査が空振りしていない）"
else
  bad "前提が崩れた: 除外なしでも tracked / index の変化が見えない"
fi
reset_repo

# 肯定形の pathspec は受け付けない（走査範囲が黙ってそのパスだけへ縮むため）
set +e
capture_repo_snapshot '' ':(glob,top)src/**' >/dev/null 2>&1
POSITIVE_RC=$?
set -e
if [[ $POSITIVE_RC -ne 0 ]]; then
  ok "肯定形の追加 pathspec は非 0 で拒否する（監視範囲の黙った縮小を塞ぐ）"
else
  bad "肯定形の追加 pathspec が rc=0 で通る"
fi

# ══════════════════════════════════════════════════════════════
echo "== 統合: orchestrator の除外つき前後検証 =="
# ══════════════════════════════════════════════════════════════
STUB="$TMP/bin"
mkdir -p "$STUB"
PROMPT_DIR="$TMP/prompts"
mkdir -p "$PROMPT_DIR"

# codex stub。指示ファイルがあれば実行中にリポジトリへ書き込む。
cat > "$STUB/codex" <<SH
#!/usr/bin/env bash
{ printf '%s\n' "\$*"; cat; } > "$PROMPT_DIR/prompt.\$\$"
if [ -f "$TMP/mutate-superpowers" ]; then
  mkdir -p "$REPO/.superpowers"
  echo "written by resident tool" > "$REPO/.superpowers/state.json"
fi
if [ -f "$TMP/mutate-cache" ]; then
  mkdir -p "$REPO/cache"
  echo "written by resident tool" > "$REPO/cache/blob.bin"
fi
if [ -f "$TMP/mutate-untracked" ]; then
  : > "$REPO/LEAKED_MID_RUN.txt"
fi
if [ -f "$TMP/mutate-subdir" ]; then
  : > "$REPO/src/LEAKED_SUB.txt"
fi
if [ -f "$TMP/mutate-commit" ]; then
  git -C "$REPO" commit -q --allow-empty -m "changed by stub" 2>/dev/null || true
fi
echo "## Findings"
echo "- Suggestion: stub review"
SH
chmod +x "$STUB/codex"

# 既定では FF_MULTI_AGENT_IGNORE_PATHS を空で固定する（ホスト値は build_isolate_env が
# 除去済み。空文字列は未設定と同じ扱い）。ケース固有の値は引数で上書きする。
run_orchestrator() {
  local ignore_paths="$1"
  local script="${2:-$MULTI_AGENT}"
  set +e
  run_isolated PATH="$STUB:/usr/bin:/bin" \
    FF_MULTI_AGENT_IGNORE_PATHS="$ignore_paths" bash "$script" \
    --task review --cli codex-cli --perspective code-review \
    --base develop --timeout 60 \
    >"$TMP/run.log" 2>&1
  local rc=$?
  set -e
  return $rc
}

clear_mutations() {
  rm -f "$TMP/mutate-superpowers" "$TMP/mutate-cache" "$TMP/mutate-untracked" \
        "$TMP/mutate-subdir" "$TMP/mutate-commit"
  return 0
}

# --- (d) 既定除外: .superpowers/ への実行中書き込みで破棄しない + ログ 1 行 ---
reset_repo
clear_mutations
: > "$TMP/mutate-superpowers"
rm -rf "$REPO/.review-results" "$PROMPT_DIR"/*
if run_orchestrator ""; then
  ok "既定除外: 実行中の .superpowers/ 書き込みで破棄されない（rc=0）"
else
  bad "既定除外が効かず .superpowers/ の書き込みで破棄された"
  tail -15 "$TMP/run.log" | sed 's/^/    | /' >&2
fi
if [[ -f "$REPO/.review-results/integrated-report.md" ]]; then
  ok "既定除外: 統合レポートが生成される"
else
  bad "既定除外: 統合レポートが生成されない"
fi
if /usr/bin/grep -q "Default exclusion '.superpowers/\*\*' kept" "$TMP/run.log"; then
  ok "既定除外が効いたことを実行ログへ 1 行出す"
else
  bad "既定除外が効いたのにログへ出ない（黙って無視している）"
  tail -10 "$TMP/run.log" | sed 's/^/    | /' >&2
fi
if /usr/bin/grep -q "\.superpowers/" "$TMP/run.log"; then
  ok "既定除外で無視したパスを一覧で名指しする"
else
  bad "既定除外で無視したパスがログに出ない"
fi
clear_mutations

# --- (a) 利用者指定: 除外パス配下の実行中書き込みで破棄しない + 件数一覧 ---
# 既定 .superpowers/** への書き込みも**同じ実行**で行う。env 指定が既定を置き換える
# 退行（別のパスを 1 つ設定した瞬間に .superpowers 起因の全破棄が再発する形）は、
# env なしのケースと env ありのケースを別々に走らせるだけでは検出できない。
reset_repo
clear_mutations
: > "$TMP/mutate-cache"
: > "$TMP/mutate-superpowers"
rm -rf "$REPO/.review-results" "$PROMPT_DIR"/*
if run_orchestrator "cache/**"; then
  ok "利用者指定の除外パス配下の書き込みで破棄されない（rc=0。同時に既定除外も生存）"
else
  bad "FF_MULTI_AGENT_IGNORE_PATHS の除外が効かず破棄された（または env 指定が既定 .superpowers/** を置き換えている）"
  tail -15 "$TMP/run.log" | sed 's/^/    | /' >&2
fi
if /usr/bin/grep -q "Excluded from the tree-change check: 1 path(s) matched FF_MULTI_AGENT_IGNORE_PATHS" "$TMP/run.log" \
   && /usr/bin/grep -q "cache/" "$TMP/run.log"; then
  ok "無視した変更を件数と一覧でログへ出す（黙って無視しない）"
else
  bad "無視した変更の件数・一覧がログに出ない"
  tail -10 "$TMP/run.log" | sed 's/^/    | /' >&2
fi
if /usr/bin/grep -q "Default exclusion '.superpowers/\*\*' kept" "$TMP/run.log"; then
  ok "env 指定は既定への追加（同一実行で既定 .superpowers/** のログも出る）"
else
  bad "env 指定時に既定 .superpowers/** の除外ログが出ない（置き換えになっている疑い）"
  tail -10 "$TMP/run.log" | sed 's/^/    | /' >&2
fi
clear_mutations

# --- 指定はあるのに 1 件も一致しない場合はその旨を出す ---
reset_repo
clear_mutations
rm -rf "$REPO/.review-results" "$PROMPT_DIR"/*
if run_orchestrator "no-such-dir/**"; then
  ok "一致 0 件の除外指定でも正常完走する"
else
  bad "一致 0 件の除外指定で失敗した"
  tail -10 "$TMP/run.log" | sed 's/^/    | /' >&2
fi
if /usr/bin/grep -q "No uncommitted changes match FF_MULTI_AGENT_IGNORE_PATHS" "$TMP/run.log"; then
  ok "1 件も一致しない場合はその旨をログへ出す（書き間違いに気づける）"
else
  bad "一致 0 件の注記がログに出ない"
  tail -10 "$TMP/run.log" | sed 's/^/    | /' >&2
fi

# --- (b) 除外の外の変化は従来どおり破棄する ---
reset_repo
clear_mutations
: > "$TMP/mutate-untracked"
rm -rf "$REPO/.review-results" "$PROMPT_DIR"/*
if run_orchestrator "cache/**"; then
  bad "除外の外の変化（新規 untracked）が見逃された"
else
  ok "除外の外の変化は従来どおり破棄する（rc 非 0）"
fi
if [[ ! -f "$REPO/.review-results/integrated-report.md" ]]; then
  ok "除外の外の変化では統合レポートを生成しない"
else
  bad "破棄したはずの実行のレポートが残っている"
fi
clear_mutations

# --- 除外は HEAD / ブランチの変化検出に影響しない ---
# '**' は作業ツリー判定を事実上無効化する指定（警告つきで許容）。それでも実行中の
# commit は HEAD フィールドが捉えて破棄する = 除外が効くのは作業ツリーだけ。
reset_repo
clear_mutations
: > "$TMP/mutate-commit"
rm -rf "$REPO/.review-results" "$PROMPT_DIR"/*
if run_orchestrator "**"; then
  bad "除外全開で実行中の commit まで見逃された（HEAD 検出が消えている）"
else
  ok "除外を全開にしても実行中の commit（HEAD 変化）は破棄する"
fi
if /usr/bin/grep -q "^   HEAD:" "$TMP/run.log"; then
  ok "HEAD の変化として名指しする"
else
  bad "HEAD の変化が診断に出ない"
  tail -10 "$TMP/run.log" | sed 's/^/    | /' >&2
fi
if /usr/bin/grep -q "matches every path" "$TMP/run.log"; then
  ok "全パス一致パターンには無効化の警告を出す"
else
  bad "全パス一致パターンの警告が出ない"
fi
clear_mutations

# --- '**/*' も全パス一致（git 2.50.1 実測: 除外 7/7）— 警告つきで無効化される ---
# 旧実装の警告リストは '**'/'*'/'.'/'/' のリテラル列挙で、'**/*' が素通りだった。
reset_repo
clear_mutations
: > "$TMP/mutate-subdir"
rm -rf "$REPO/.review-results" "$PROMPT_DIR"/*
if run_orchestrator "**/*"; then
  ok "'**/*': 全パス一致としてサブディレクトリの書き込みも除外される（rc=0）"
else
  bad "'**/*' が全パス一致として扱われていない"
  tail -10 "$TMP/run.log" | sed 's/^/    | /' >&2
fi
if /usr/bin/grep -q "matches every path" "$TMP/run.log"; then
  ok "'**/*' にも無効化の警告を出す"
else
  bad "'**/*' に全パス一致の警告が出ない（リテラル列挙の取りこぼし）"
fi
clear_mutations

# --- '*' は glob magic で '/' を跨がない（直下のみ。全パス一致ではない） ---
reset_repo
clear_mutations
: > "$TMP/mutate-untracked"
rm -rf "$REPO/.review-results" "$PROMPT_DIR"/*
if run_orchestrator "*"; then
  ok "'*': リポジトリ直下の書き込みは除外される（rc=0）"
else
  bad "'*' が直下の変化を除外できていない"
  tail -10 "$TMP/run.log" | sed 's/^/    | /' >&2
fi
if ! /usr/bin/grep -q "matches every path" "$TMP/run.log"; then
  ok "'*' には全パス一致の警告を出さない（直下のみの正当な指定）"
else
  bad "'*' に全パス一致の警告が出る（実測と逆の案内）"
fi
clear_mutations
reset_repo
clear_mutations
: > "$TMP/mutate-subdir"
rm -rf "$REPO/.review-results" "$PROMPT_DIR"/*
if run_orchestrator "*"; then
  bad "'*' がサブディレクトリの変化まで除外している（glob の '*' は '/' を跨がないはず）"
  tail -10 "$TMP/run.log" | sed 's/^/    | /' >&2
else
  ok "'*': サブディレクトリの変化は従来どおり破棄する（'/' を跨がない）"
fi
clear_mutations

# --- '.' / '/' は glob magic で何にも一致しない → 起動前に拒否 ---
# 旧実装は「全パス一致」と逆の警告を出して通していた。'.' は除外 0 件のまま座り続け、
# '/' は verify 時の肯定形クエリ :(glob,top)/ を rc=128 で落として破棄まで道連れにする。
for noop_spec in '.' '/'; do
  reset_repo
  clear_mutations
  rm -rf "$REPO/.review-results" "$PROMPT_DIR"/*
  if run_orchestrator "$noop_spec"; then
    bad "何にも一致しない '${noop_spec}' が通ってしまう（除外 0 件のまま成功を名乗る）"
  else
    if /usr/bin/grep -q "matches nothing" "$TMP/run.log"; then
      ok "何にも一致しない '${noop_spec}' を中断する"
    else
      bad "'${noop_spec}' は失敗したが診断が違う"
      tail -6 "$TMP/run.log" | sed 's/^/    | /' >&2
    fi
  fi
  PROMPT_COUNT="$(find "$PROMPT_DIR" -maxdepth 1 -type f -name 'prompt.*' | wc -l | tr -d ' ')"
  if [[ "$PROMPT_COUNT" -eq 0 ]]; then
    ok "'${noop_spec}' では CLI を 1 つも起動しない（支払い前に止まる）"
  else
    bad "'${noop_spec}' で CLI が起動してしまった（${PROMPT_COUNT} 件）"
  fi
done

# --- 文字クラス（[...]）は ':' 区切りと衝突して黙って分断される → 起動前に拒否 ---
# 'logs/[[:digit:]]*/**' は 'logs/[[' / 'digit' / ']]*/**' に分断され、3 破片とも
# git は rc=0 で受け付けて何にも一致しない（実測）= エラーの出ない fail-open。
# FF_MERGE_CLEANUP_PROTECT_BRANCHES の先例と同じく明示拒否する。
reset_repo
clear_mutations
rm -rf "$REPO/.review-results" "$PROMPT_DIR"/*
if run_orchestrator 'logs/[[:digit:]]*/**'; then
  bad "文字クラスを含むパターンが通ってしまう（分断されて何にも一致しないまま）"
else
  if /usr/bin/grep -q "character class" "$TMP/run.log"; then
    ok "文字クラスを含むパターンを中断する（プレフィックス glob を案内）"
  else
    bad "文字クラスのパターンは失敗したが診断が違う"
    tail -6 "$TMP/run.log" | sed 's/^/    | /' >&2
  fi
fi
PROMPT_COUNT="$(find "$PROMPT_DIR" -maxdepth 1 -type f -name 'prompt.*' | wc -l | tr -d ' ')"
if [[ "$PROMPT_COUNT" -eq 0 ]]; then
  ok "文字クラスのパターンでは CLI を 1 つも起動しない（支払い前に止まる）"
else
  bad "文字クラスのパターンで CLI が起動してしまった（${PROMPT_COUNT} 件）"
fi

# --- (c) 空パターン・空白付きパターンは起動前に中断する ---
for bad_spec in "cache/**::tmp/**" ":cache/**" "cache/**:"; do
  reset_repo
  clear_mutations
  rm -rf "$REPO/.review-results" "$PROMPT_DIR"/*
  if run_orchestrator "$bad_spec"; then
    bad "空パターンを含む指定 '${bad_spec}' が通ってしまう（fail-open）"
  else
    if /usr/bin/grep -q "contains an empty pattern" "$TMP/run.log"; then
      ok "空パターンを含む指定 '${bad_spec}' を中断する"
    else
      bad "空パターン指定 '${bad_spec}' は失敗したが診断が違う"
      tail -6 "$TMP/run.log" | sed 's/^/    | /' >&2
    fi
  fi
  PROMPT_COUNT="$(find "$PROMPT_DIR" -maxdepth 1 -type f -name 'prompt.*' | wc -l | tr -d ' ')"
  if [[ "$PROMPT_COUNT" -eq 0 ]]; then
    ok "空パターン指定 '${bad_spec}' では CLI を 1 つも起動しない（支払い前に止まる）"
  else
    bad "空パターン指定 '${bad_spec}' で CLI が起動してしまった（${PROMPT_COUNT} 件）"
  fi
done

reset_repo
clear_mutations
rm -rf "$REPO/.review-results" "$PROMPT_DIR"/*
if run_orchestrator "cache/** :tmp/**"; then
  bad "空白付きパターンが通ってしまう（何にも一致しないまま成功を名乗る）"
else
  if /usr/bin/grep -q "leading/trailing whitespace" "$TMP/run.log"; then
    ok "前後に空白の付いたパターンを中断する"
  else
    bad "空白付きパターンは失敗したが診断が違う"
    tail -6 "$TMP/run.log" | sed 's/^/    | /' >&2
  fi
fi
PROMPT_COUNT="$(find "$PROMPT_DIR" -maxdepth 1 -type f -name 'prompt.*' | wc -l | tr -d ' ')"
if [[ "$PROMPT_COUNT" -eq 0 ]]; then
  ok "空白付きパターンでは CLI を 1 つも起動しない（支払い前に止まる）"
else
  bad "空白付きパターンで CLI が起動してしまった（${PROMPT_COUNT} 件）"
fi

# ══════════════════════════════════════════════════════════════
echo "== ミューテーション: 除外検査が実際に効いているか =="
# ══════════════════════════════════════════════════════════════
MUTANT_ROOT="$TMP/mutant"
rm -rf "$MUTANT_ROOT"
mkdir -p "$MUTANT_ROOT"
cp -R "$PLUGIN_ROOT/scripts" "$MUTANT_ROOT/scripts"
MUTANT_MULTI_AGENT="$MUTANT_ROOT/scripts/multi-agent.sh"

# M1: 空パターンの拒否を外す → 空パターン指定が通ってしまうはず
perl -0pi -e 's/if \[\[ -z "\$item" \]\]; then/if false; then/' "$MUTANT_MULTI_AGENT"
if cmp -s "$MUTANT_MULTI_AGENT" "$PLUGIN_ROOT/scripts/multi-agent.sh"; then
  bad "M1: ミューテーションを適用できなかった（被検体と同一。検査が無意味）"
else
  reset_repo
  clear_mutations
  rm -rf "$REPO/.review-results" "$PROMPT_DIR"/*
  if run_orchestrator "cache/**::tmp/**" "$MUTANT_MULTI_AGENT"; then
    ok "M1: 空パターン拒否を外すと通ってしまう（本体の検査が効いている証拠）"
  else
    bad "M1: 空パターン拒否を外しても非 0（別要因で落ちており (c) が空振りの疑い）"
    tail -10 "$TMP/run.log" | sed 's/^/    | /' >&2
  fi
fi

# M2: 除外 pathspec の受け渡しを外す → 既定 .superpowers/ の書き込みで破棄されるはず
rm -rf "$MUTANT_ROOT/scripts"
cp -R "$PLUGIN_ROOT/scripts" "$MUTANT_ROOT/scripts"
perl -0pi -e 's/ "\$\{IGNORE_EXCLUDE_PATHSPECS\[\@\]\}"//g' "$MUTANT_MULTI_AGENT"
if cmp -s "$MUTANT_MULTI_AGENT" "$PLUGIN_ROOT/scripts/multi-agent.sh"; then
  bad "M2: ミューテーションを適用できなかった（被検体と同一。検査が無意味）"
else
  reset_repo
  clear_mutations
  : > "$TMP/mutate-superpowers"
  rm -rf "$REPO/.review-results" "$PROMPT_DIR"/*
  if run_orchestrator "" "$MUTANT_MULTI_AGENT"; then
    bad "M2: 受け渡しを外しても rc=0（既定除外の検査が空振りの疑い）"
    tail -10 "$TMP/run.log" | sed 's/^/    | /' >&2
  else
    ok "M2: 受け渡しを外すと .superpowers/ 書き込みで破棄される（配線の検査が効いている証拠）"
  fi
  clear_mutations
fi

# M3: 文字クラスの拒否を外す → 分断された破片のまま CLI が起動してしまうはず
# （git は破片を rc=0 で受け付けるため、拒否が無いと他のどの段でも止まらない）
rm -rf "$MUTANT_ROOT/scripts"
cp -R "$PLUGIN_ROOT/scripts" "$MUTANT_ROOT/scripts"
perl -0pi -e 's/\*\\\[\*\|\*\\\]\*\)/__ff_mutated_never__)/' "$MUTANT_MULTI_AGENT"
if cmp -s "$MUTANT_MULTI_AGENT" "$PLUGIN_ROOT/scripts/multi-agent.sh"; then
  bad "M3: ミューテーションを適用できなかった（被検体と同一。検査が無意味）"
else
  reset_repo
  clear_mutations
  rm -rf "$REPO/.review-results" "$PROMPT_DIR"/*
  run_orchestrator 'logs/[[:digit:]]*/**' "$MUTANT_MULTI_AGENT" || true
  PROMPT_COUNT="$(find "$PROMPT_DIR" -maxdepth 1 -type f -name 'prompt.*' | wc -l | tr -d ' ')"
  if [[ "$PROMPT_COUNT" -ge 1 ]]; then
    ok "M3: 文字クラス拒否を外すと CLI が起動してしまう（起動前ゲートの検査が効いている証拠）"
  else
    bad "M3: 文字クラス拒否を外しても CLI が起動しない（別要因で落ちており検査が空振りの疑い）"
    tail -10 "$TMP/run.log" | sed 's/^/    | /' >&2
  fi
  clear_mutations
fi

# ══════════════════════════════════════════════════════════════
echo ""
echo "── 結果: ${PASS} passed, ${FAIL} failed ──"
[[ "$FAIL" -eq 0 ]] || exit 1
exit 0
