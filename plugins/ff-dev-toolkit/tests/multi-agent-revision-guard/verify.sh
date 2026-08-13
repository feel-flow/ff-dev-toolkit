#!/usr/bin/env bash
#
# 並列実行中にレビュー対象（HEAD / ブランチ / 作業ツリー）が動いたとき、結果を
# 黙って返さないことの回帰テスト（公開 Issue feel-flow/ff-dev-toolkit#11）。
#
# 塞いでいるのは 2 つで、片方だけでは穴が残る:
#   ② diff の固定 …… 以前は各アダプタが**自分の起動時に** git から diff を取っていた。
#      並列タスクの起動時刻はばらけるので、実行中の checkout / commit でタスクごとに
#      別の diff をレビューしうる。しかも全員が正常終了する。
#   ① 前後のリビジョン検証 …… プロンプトの diff を固定しても、CLI エージェント自身は
#      作業ツリーのファイル実体を読む。実行前後でリポジトリが動いていたら結果を破棄する。
#
# ② だけでは「エージェントが読んだファイル」を守れず、① だけでは「切り替え → 元に戻す」
# を検出できない（前後のスナップショットが一致するため）。両方を別々に検査する。
#
# 実 CLI は 1 つも起動しない（stub で覆う）。書き込み不可の環境では skip。

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
MULTI_AGENT="$PLUGIN_ROOT/scripts/multi-agent.sh"
ADAPTER_COMMON="$PLUGIN_ROOT/scripts/adapters/adapter-common.sh"

[ -f "$MULTI_AGENT" ] || { echo "✗ multi-agent.sh が見つかりません" >&2; exit 1; }
[ -f "$ADAPTER_COMMON" ] || { echo "✗ adapter-common.sh が見つかりません" >&2; exit 1; }

# 実行環境の MULTI_AGENT_* からの分離（Issue #374 / #378 / #383）。
# **存在検査より後に置くこと**（先に置くと被検体不在の診断が抽出失敗に化ける）。
# shellcheck source=../lib/adapter-env-isolation.sh
. "$PLUGIN_ROOT/tests/lib/adapter-env-isolation.sh"
build_isolate_env "MULTI_AGENT_CONFIG" \
  "$MULTI_AGENT" "$PLUGIN_ROOT"/scripts/adapters/*.sh

PASS=0
FAIL=0
ok()  { echo "  ✓ $1"; PASS=$((PASS + 1)); }
bad() { echo "  ✗ $1" >&2; FAIL=$((FAIL + 1)); }

# mktemp の stderr を捨てない。捨てると read-only 以外の失敗（不正な TMPDIR・quota
# 超過など）まで「書き込み可能な環境で再実行してください」へ誤帰属し、恒常的に壊れた
# TMPDIR が suite を exit 0 で無効化し続ける。
if _ff_mktemp_out="$(mktemp -d 2>&1)"; then
  TMP="$_ff_mktemp_out"
else
  echo "○ skip: 一時ディレクトリを作成できない環境（read-only）のためスキップ"
  printf '  mktemp: %s\n' "$_ff_mktemp_out"
  exit 0
fi
trap 'cd /; rm -rf "$TMP"' EXIT

# ── 被検体リポジトリ ──
REPO="$TMP/repo"
git init -q "$REPO"
cd "$REPO"
git config user.email "test@example.com"
git config user.name "multi-agent-revision-guard-test"
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

# 各ケースの前にこの状態へ戻す。stub がリポジトリを動かすケースがあるため。
CLEAN_HEAD="$(git rev-parse HEAD)"
reset_repo() {
  cd "$REPO"
  git switch -q feature/x 2>/dev/null || true
  git reset -q --hard "$CLEAN_HEAD"
  git clean -qfd -e .review-results
}

# ══════════════════════════════════════════════════════════════
echo "== 単体: capture_repo_snapshot =="
# ══════════════════════════════════════════════════════════════
# shellcheck source=../../scripts/adapters/adapter-common.sh
. "$ADAPTER_COMMON"
# adapter-common.sh は source 時に無条件で EXIT trap を張る（_FF_TIMEOUT_REASON_EXIT_TRAP
# のガードは**再**インストールを防ぐだけで、既存の trap を保存しない）。上で仕掛けた
# 後始末が奪われるため張り直す — 奪われたままだと実行のたびに mktemp -d が残る（実測）。
trap 'cd /; rm -rf "$TMP"' EXIT

snap() { capture_repo_snapshot "${1:-}"; }

BASE_SNAP="$(snap)"
if [[ -n "$BASE_SNAP" && "$(snap)" == "$BASE_SNAP" ]]; then
  ok "同じ状態なら同じ値を返す（安定している）"
else
  bad "同じ状態で値が揺れる: '${BASE_SNAP}' vs '$(snap)'"
fi

# 3 フィールド（HEAD / ブランチ / 作業ツリーのハッシュ）である契約。
# verify_repo_unchanged が read -r で 3 つに割って「どこが動いたか」を名指しするため、
# 形が崩れると診断だけが静かに壊れる（判定自体は文字列比較なので通ってしまう）。
if [[ "$(printf '%s\n' "$BASE_SNAP" | awk '{print NF}')" == "3" ]]; then
  ok "スナップショットは 3 フィールド（HEAD / branch / worktree）"
else
  bad "スナップショットのフィールド数が 3 でない: '${BASE_SNAP}'"
fi

# --- E2: commit で HEAD が前進 ---
git commit -q --allow-empty -m "mid-run commit"
if [[ "$(snap)" != "$BASE_SNAP" ]]; then
  ok "E2: commit（HEAD 前進）を検出する"
else
  bad "E2: commit を検出できない"
fi
reset_repo

# --- E1: ブランチ切り替え ---
git switch -q develop
if [[ "$(snap)" != "$BASE_SNAP" ]]; then
  ok "E1: ブランチ切り替えを検出する"
else
  bad "E1: ブランチ切り替えを検出できない"
fi
reset_repo

# --- E1b: 同じコミットを指す別ブランチへの切り替え ---
# 上の E1 は SHA も変わるので、HEAD フィールドだけでも通ってしまう（ブランチ名
# フィールドを削っても緑のまま）。SHA と作業ツリーが同一のまま名前だけが変わる形を
# 別に置き、ブランチ名を見ている根拠を固定する。
git switch -q -c feature/same-commit
if [[ "$(snap)" != "$BASE_SNAP" ]]; then
  ok "E1b: 同一 SHA の別ブランチへの切り替えを検出する（ブランチ名を見ている）"
else
  bad "E1b: 同一 SHA の別ブランチ切り替えを検出できない"
fi
git switch -q feature/x
git branch -qD feature/same-commit

# --- E3: tracked ファイルの編集 ---
echo mutated >> src/app.txt
if [[ "$(snap)" != "$BASE_SNAP" ]]; then
  ok "E3: tracked ファイルの編集を検出する"
else
  bad "E3: tracked ファイルの編集を検出できない"
fi
reset_repo

# --- E6: 新規 untracked ファイル（implement の作業ツリー汚染） ---
# ここが --untracked-files=no では見えない。implement タスクが staging ではなく作業
# ツリーへ生成物を書いた事故は「新規ファイルの出現」としてしか現れないので、tracked
# だけを見ていると**最も危険なケースだけ**が無防備になる。
touch src/LEAKED_BY_AGENT.txt
if [[ "$(snap)" != "$BASE_SNAP" ]]; then
  ok "E6: 新規 untracked ファイル（作業ツリー汚染）を検出する"
else
  bad "E6: 新規 untracked ファイルを検出できない（-uno 相当に退行している）"
fi
reset_repo

# --- 実行前から dirty な tracked ファイルの**追加編集** ---
# `git status --porcelain` は状態コードとパスしか返さないので、既に ` M` のファイルを
# さらに編集しても出力は変わらない。レビュー対象に未コミット変更があるのは通常の
# 使い方（diff も git diff HEAD を和集合に含む）で、ここを取りこぼすと中心的なケースが
# 無防備になる。内容まで指紋に入っていることを固定する。
echo "already dirty" >> src/app.txt
DIRTY_SNAP="$(snap)"
if [[ "$(git status --porcelain)" == " M src/app.txt" ]]; then
  ok "前提: 実行前から tracked ファイルが dirty（状態コードは以後変わらない）"
else
  bad "前提が崩れた: 想定した dirty 状態になっていない"
fi
echo "edited again mid-run" >> src/app.txt
if [[ "$(snap)" != "$DIRTY_SNAP" ]]; then
  ok "既に dirty な tracked ファイルの追加編集を検出する（状態コードは不変）"
else
  bad "dirty なファイルの追加編集を検出できない（指紋が内容に盲目）"
fi
reset_repo

# --- 既存 untracked ファイルの内容変更 ---
# 出現は status が捉えるが、既にあるものを上書きされても `?? path` のままになる。
touch src/preexisting.txt
UNTRACKED_SNAP="$(snap)"
echo "overwritten by agent" > src/preexisting.txt
if [[ "$(snap)" != "$UNTRACKED_SNAP" ]]; then
  ok "既存 untracked ファイルの内容変更を検出する（状態コードは不変）"
else
  bad "既存 untracked ファイルの内容変更を検出できない"
fi
reset_repo

# --- unborn（初回コミット前）でも stage 内容の変化を捉える ---
# unborn では git diff HEAD だけが失敗し、--cached は空ツリー相手に成立する。
# 両方まとめて飛ばすと `A  path` のまま stage 内容だけを差し替える変化を取りこぼす。
UNBORN="$TMP/unborn"
git init -q "$UNBORN"
git -C "$UNBORN" config user.email t@t
git -C "$UNBORN" config user.name t
printf 'v1\n' > "$UNBORN/f.txt"
git -C "$UNBORN" add f.txt
UNBORN_A="$(cd "$UNBORN" && capture_repo_snapshot)"
printf 'TOTALLY DIFFERENT\n' > "$UNBORN/f.txt"
git -C "$UNBORN" add f.txt
UNBORN_B="$(cd "$UNBORN" && capture_repo_snapshot)"
if [[ "$(git -C "$UNBORN" status --porcelain)" == "A  f.txt" ]]; then
  ok "前提: unborn では状態コードが A のまま動かない"
else
  bad "前提が崩れた: unborn の状態コードが想定と違う"
fi
if [[ "$UNBORN_A" != "$UNBORN_B" ]]; then
  ok "unborn でも stage 内容の差し替えを検出する（--cached を飛ばしていない）"
else
  bad "unborn で stage 内容の差し替えを検出できない（diff --cached を飛ばしている）"
fi
cd "$REPO"

# --- git リポジトリ外では取得に失敗する（E7: 検証不能を成功に見せない） ---
NOGIT="$TMP/not-a-repo"
mkdir -p "$NOGIT"
set +e
( cd "$NOGIT" && capture_repo_snapshot ) >/dev/null 2>&1
NOGIT_RC=$?
set -e
if [[ $NOGIT_RC -ne 0 ]]; then
  ok "E7: git リポジトリ外では非 0 を返す（呼び出し側が fail-closed にできる）"
else
  bad "E7: git リポジトリ外でも rc=0 を返す（検証不能を成功に見せる）"
fi
cd "$REPO"

# --- index だけが動く変更（--staged レビューが読む面） ---
# worktree を動かさずに stage 内容だけが変わる形。status の状態コードは同じままで、
# --staged レビューが実際に読むのは index の内容なので、ここも指紋に要る。
# worktree と status コードを固定したまま index だけを動かす。worktree も動かすと
# git diff HEAD だけで発火してしまい、--cached 成分を分離できない（実測: --cached を
# 外した版でもその形の検査は緑のままだった）。
printf 'A\n' > src/app.txt; git add src/app.txt; printf 'B\n' > src/app.txt
STAGED_SNAP="$(snap)"
STAGED_CODE="$(git status --porcelain)"
printf 'A2\n' > src/app.txt; git add src/app.txt; printf 'B\n' > src/app.txt
if [[ "$(git status --porcelain)" == "$STAGED_CODE" ]]; then
  ok "前提: status コードは MM のまま動かない（--cached 成分が分離できる）"
else
  bad "前提が崩れた: status コードが動いてしまい --cached を分離できない"
fi
if [[ "$(snap)" != "$STAGED_SNAP" ]]; then
  ok "stage 内容の変化を検出する（--staged レビューが読む面）"
else
  bad "stage 内容の変化を検出できない"
fi
reset_repo

# --- 内容を読めない untracked エントリがあってもスナップショットは成立する ---
# git hash-object は blob にできないものに当たると fatal で落ちる。素通しにすると、
# リポジトリに untracked の symlink が 1 つあるだけでスナップショット取得が失敗し、
# ガードどころか**ツール全体が起動しなくなる**（正常な実行を落とすのは、見逃すのと
# 別種だが同じくらい悪い）。
mkdir -p src/realdir
ln -s realdir src/dirlink
ln -s no-such-target src/danglink
echo secret > src/noread.txt
chmod 000 src/noread.txt
if BENIGN_SNAP="$(snap 2>/dev/null)" && [[ -n "$BENIGN_SNAP" ]]; then
  ok "untracked の symlink・壊れたリンク・読めないファイルがあっても取得できる"
else
  bad "良性の untracked エントリでスナップショット取得が失敗する（ツールが起動不能になる）"
fi
# それでも「新しいパスの出現」は捉え続ける（E6 の保護が消えていないこと）
touch src/LEAKED_WITH_SYMLINKS.txt
if [[ "$(snap 2>/dev/null)" != "$BENIGN_SNAP" ]]; then
  ok "読めないエントリを飛ばしても新規パスの出現は検出し続ける"
else
  bad "読めないエントリを飛ばした結果、新規パスの出現まで見えなくなっている"
fi
chmod 644 src/noread.txt
reset_repo

# --- 除外パスの glob メタ文字が無関係なパスを監視から外さないこと ---
# `:(exclude)a*` は a*/ と abc/ の両方を消す（実測）。literal を付けないと、
# --output-dir の名前次第で監視範囲が黙って縮む。
mkdir -p 'a*' abc
echo 1 > 'a*/f'
echo 2 > abc/g
GLOB_SNAP="$(snap 'a*')"
echo 3 >> abc/g
if [[ "$(snap 'a*')" != "$GLOB_SNAP" ]]; then
  ok "除外パスの glob メタ文字が無関係なパスを監視から外さない（literal 指定）"
else
  bad "除外が glob として解釈され、無関係なパスまで監視から外れている"
fi
reset_repo

# --- 除外パス: orchestrator 自身の出力を数えない ---
mkdir -p "$REPO/.review-results/codex-cli"
echo "result" > "$REPO/.review-results/codex-cli/code-review.md"
EXCLUDED_SNAP="$(snap .review-results)"
echo "more" > "$REPO/.review-results/codex-cli/other.md"
if [[ "$(snap .review-results)" == "$EXCLUDED_SNAP" ]]; then
  ok "除外パス配下への書き込みは変化として数えない（正常な実行が毎回落ちない）"
else
  bad "除外パスが効いていない（orchestrator 自身の出力で誤発火する）"
fi
# 除外しなければ同じ書き込みが変化として見えること = 除外検査が空振りしていない証拠
if [[ "$(snap)" != "$(printf '%s' "$EXCLUDED_SNAP")" ]]; then
  ok "前提: 除外を外せば同じ書き込みが変化として見える（検査が空振りしていない）"
else
  bad "前提が崩れた: 除外の有無で結果が変わらない"
fi
reset_repo
rm -rf "$REPO/.review-results"

# --- CWD 非依存: サブディレクトリから呼んでも監視範囲が縮まない ---
# `git status --porcelain -- .` は CWD 相対に狭まる。orchestrator の main() は
# REPO_ROOT へ cd しないため、サブディレクトリから起動された実行が、そのサブツリーの
# 外で起きた変化を静かに見逃す形になる（実測で再現した）。
# **除外引数を必ず渡すこと。** 走査範囲は ':/' が固定するので、除外なしの比較では
# cd を外しても値が一致してしまう（実測: cd 削除版でもこの検査は緑のまま）。CWD 相対に
# 縮むのは `:(exclude)` の側で、orchestrator は必ず除外を渡す構成で呼ぶ。
mkdir -p "$REPO/.review-results"
echo out > "$REPO/.review-results/dummy.md"
ROOT_SNAP="$(snap .review-results)"
SUB_SNAP="$(cd "$REPO/src" && capture_repo_snapshot .review-results)"
if [[ "$SUB_SNAP" == "$ROOT_SNAP" ]]; then
  ok "サブディレクトリから呼んでも同じ値（CWD 非依存）"
else
  bad "CWD によって値が変わる: root='${ROOT_SNAP}' src='${SUB_SNAP}'"
fi
# サブツリーの**外**の変化を、サブディレクトリからでも捉えられること
touch "$REPO/ROOT_LEVEL_CHANGE.txt"
if [[ "$(cd "$REPO/src" && capture_repo_snapshot .review-results)" != "$SUB_SNAP" ]]; then
  ok "サブディレクトリから呼んでもリポジトリ全体を見る"
else
  bad "サブディレクトリから呼ぶと外側の変化を見逃す（pathspec が CWD 相対に縮んでいる）"
fi
reset_repo

# --- detached HEAD で壊れない ---
git checkout -q --detach HEAD
DETACHED_SNAP="$(snap)" || DETACHED_SNAP=""
if [[ -n "$DETACHED_SNAP" && "$(printf '%s\n' "$DETACHED_SNAP" | awk '{print NF}')" == "3" ]]; then
  ok "detached HEAD でも 3 フィールドを返す"
else
  bad "detached HEAD でスナップショットが壊れる: '${DETACHED_SNAP}'"
fi
reset_repo

# ══════════════════════════════════════════════════════════════
echo "== 単体: prompt_diff_content（固定 diff の受け渡し） =="
# ══════════════════════════════════════════════════════════════
FIXED="$TMP/fixed.diff"
printf 'diff --git a/src/app.txt b/src/app.txt\nFIXED-CONTENT-MARKER\n' > "$FIXED"

DIFF_FILE="$FIXED"
if [[ "$(prompt_diff_content develop)" == "$(cat "$FIXED")" ]]; then
  ok "DIFF_FILE の中身をそのまま返す"
else
  bad "DIFF_FILE の中身が返らない"
fi

# E4 の核心: リポジトリが動いても、固定したバイト列は変わらない。
# 「切り替え → 元に戻す」は前後スナップショットの一致をすり抜けるので、往復のあいだに
# 走ったタスクを守れるのはこの固定だけ。
git commit -q --allow-empty -m "moves during the run"
if [[ "$(prompt_diff_content develop)" == "$(cat "$FIXED")" ]]; then
  ok "E4: 実行中にリポジトリが動いても固定 diff は変わらない"
else
  bad "E4: リポジトリの変化が固定 diff に漏れている"
fi
reset_repo

# 空の DIFF_FILE はエラーにしない。review は orchestrator の事前ガードが空 diff を
# 止めるが、implement --include-diff にその保証は無く、「まだ変更が無い」という正常な
# 状態をハードエラーへ変えてしまう。
: > "$TMP/empty.diff"
DIFF_FILE="$TMP/empty.diff"
if prompt_diff_content develop >/dev/null 2>&1; then
  ok "空の DIFF_FILE はエラーにしない"
else
  bad "空の DIFF_FILE がエラーになる（implement --include-diff の正常系を壊す）"
fi

# 不在の DIFF_FILE では**従来取得へ落ちない**。落ちると、固定したはずの diff が失われた
# まま各タスクが別々の diff を読む状態へ静かに戻る（この機構が塞いでいる不整合そのもの）。
DIFF_FILE="$TMP/does-not-exist.diff"
set +e
MISSING_OUT="$(prompt_diff_content develop 2>/dev/null)"
MISSING_RC=$?
set -e
if [[ $MISSING_RC -ne 0 ]]; then
  ok "不在の DIFF_FILE は fail-loud（rc=${MISSING_RC}）"
else
  bad "不在の DIFF_FILE が rc=0 で通る"
fi
if [[ -z "$MISSING_OUT" ]]; then
  ok "不在の DIFF_FILE で従来取得へフォールバックしない"
else
  bad "不在の DIFF_FILE で黙って git から取り直している（固定が無意味になる）"
fi

# E9: DIFF_FILE 無指定はアダプタ直叩きの後方互換。従来どおり自分で git から取る。
DIFF_FILE=""
if prompt_diff_content develop | /usr/bin/grep -q "app.txt"; then
  ok "E9: DIFF_FILE 無指定なら従来どおり git から取る（直叩き互換）"
else
  bad "E9: DIFF_FILE 無指定で diff を取得できない（直叩きが壊れる）"
fi
unset DIFF_FILE

# --- base ブランチ解決の SSOT 化が挙動を変えていないこと ---
if [[ "$(resolve_base_branch_ref develop)" == "develop" ]]; then
  ok "resolve_base_branch_ref: ローカルブランチを優先する"
else
  bad "resolve_base_branch_ref がローカルブランチを返さない"
fi
if [[ -z "$(default_base_branch_name)" ]]; then
  ok "default_base_branch_name: origin/HEAD 未設定なら空（既定化は呼び出し側の方針）"
else
  bad "default_base_branch_name が origin/HEAD 未設定で空を返さない"
fi
if [[ "$(detect_base_branch)" == "develop" ]]; then
  ok "detect_base_branch: 合成しても従来どおり develop へ倒れる"
else
  bad "detect_base_branch の合成結果が変わった: '$(detect_base_branch)'"
fi

# ══════════════════════════════════════════════════════════════
echo "== 統合: orchestrator の前後検証 =="
# ══════════════════════════════════════════════════════════════
STUB="$TMP/bin"
mkdir -p "$STUB"
PROMPT_DIR="$TMP/prompts"
mkdir -p "$PROMPT_DIR"

# codex stub。受け取ったプロンプトを PID ごとに保存し、リポジトリを動かす指示
# ファイルがあればそのとおりに動かす（実行中のブランチ操作の決定的な再現）。
cat > "$STUB/codex" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" > "$PROMPT_DIR/prompt.\$\$"
if [ -f "$TMP/mutate-commit" ]; then
  git -C "$REPO" commit -q --allow-empty -m "changed by stub" 2>/dev/null || true
fi
if [ -f "$TMP/mutate-untracked" ]; then
  : > "$REPO/LEAKED_MID_RUN.txt"
fi
if [ -f "$TMP/mutate-worktree" ]; then
  echo "touched by stub" >> "$REPO/src/app.txt"
fi
if [ -f "$TMP/mutate-unverifiable" ]; then
  # 実行後のスナップショット取得を失敗させる（.git を退避する）。「検証できなかった」を
  # 「変化なし」として成功に見せないことの検査に使う。
  mv "$REPO/.git" "$REPO/.git-hidden" 2>/dev/null || echo "stub: could not hide .git" >&2
fi
if [ -f "$TMP/mutate-branch" ]; then
  git -C "$REPO" switch -q develop 2>/dev/null || echo "stub: branch switch failed" >&2
fi
if [ -f "$TMP/mutate-roundtrip" ]; then
  # 別ブランチへ移って**元へ戻す**。前後スナップショットは一致するので、ここを守るのは
  # 固定 diff の側になる（前後比較では原理的に検出できない形）。
  git -C "$REPO" switch -q develop 2>/dev/null && git -C "$REPO" switch -q feature/x 2>/dev/null \
    || echo "stub: round-trip failed" >&2
fi
echo "## Findings"
echo "- Suggestion: stub review"
SH
chmod +x "$STUB/codex"

run_orchestrator() {
  set +e
  run_isolated PATH="$STUB:/usr/bin:/bin" bash "$MULTI_AGENT" \
    --task review --cli codex-cli --perspective code-review \
    --base develop --timeout 60 "$@" \
    >"$TMP/run.log" 2>&1
  local rc=$?
  set -e
  return $rc
}

clear_mutations() {
  rm -f "$TMP/mutate-commit" "$TMP/mutate-untracked" "$TMP/mutate-worktree" \
        "$TMP/mutate-branch" "$TMP/mutate-roundtrip" "$TMP/mutate-unverifiable"
  # .git を退避するケースの後始末。戻さないと以降の全ケースが git 無しで走る。
  [[ -d "$REPO/.git-hidden" && ! -d "$REPO/.git" ]] && mv "$REPO/.git-hidden" "$REPO/.git"
  return 0
}

# --- 正常系: 誤発火しないこと（最重要の非回帰） ---
# orchestrator は実行中ずっと OUTPUT_DIR へ書き込む。ここを作業ツリーの変化として
# 数えてしまうと、**何も悪くない実行が毎回落ちる**。既定の出力先はリポジトリ配下。
reset_repo
clear_mutations
rm -rf "$REPO/.review-results" "$PROMPT_DIR"/*
if run_orchestrator; then
  ok "正常系: 誤発火せず rc=0 で完走する"
else
  bad "正常系で非 0 終了した（ガードが誤発火している）"
  tail -15 "$TMP/run.log" | sed 's/^/    | /' >&2
fi
if [[ -f "$REPO/.review-results/integrated-report.md" ]]; then
  ok "正常系: 統合レポートが生成される"
else
  bad "正常系で統合レポートが生成されない"
fi
# 固定 diff が実際にアダプタまで届いていること（配線の検査）
if [[ -f "$REPO/.review-results/.fixed-diff" ]]; then
  ok "固定 diff が出力ディレクトリに残る（何をレビューしたか後から確認できる）"
else
  bad "固定 diff ファイルが作られていない"
fi
if /usr/bin/grep -q "app.txt" "$PROMPT_DIR"/prompt.* 2>/dev/null; then
  ok "固定 diff の中身がプロンプトへ載っている"
else
  bad "プロンプトに diff が載っていない"
fi

# --- E2 統合: 実行中の commit ---
reset_repo
clear_mutations
: > "$TMP/mutate-commit"
rm -rf "$REPO/.review-results" "$PROMPT_DIR"/*
if run_orchestrator; then
  bad "E2 統合: 実行中に commit されても rc=0 で成功扱いになった"
else
  ok "E2 統合: 実行中の commit で非 0 終了する"
fi
if [[ ! -f "$REPO/.review-results/integrated-report.md" ]]; then
  ok "E2 統合: 統合レポートを生成しない"
else
  bad "E2 統合: 破棄したはずの実行のレポートが残っている"
fi
if /usr/bin/grep -q "^   HEAD:" "$TMP/run.log" && ! /usr/bin/grep -q "^   branch:" "$TMP/run.log"; then
  ok "E2 統合: 動いた箇所だけ（HEAD）を名指しし、動いていない箇所は挙げない"
else
  bad "E2 統合: 診断が変化した箇所を正しく絞れていない"
  tail -10 "$TMP/run.log" | sed 's/^/    | /' >&2
fi

# --- E1 統合: 実行中のブランチ切り替え（branch: 診断行の実走） ---
# 3 フィールド契約が崩れると判定は文字列比較なので通り、診断の帰属だけが静かに壊れる。
reset_repo
clear_mutations
: > "$TMP/mutate-branch"
rm -rf "$REPO/.review-results" "$PROMPT_DIR"/*
if run_orchestrator; then
  bad "E1 統合: 実行中のブランチ切り替えが見逃された"
else
  ok "E1 統合: 実行中のブランチ切り替えで非 0 終了する"
fi
if /usr/bin/grep -q "^   branch:" "$TMP/run.log"; then
  ok "E1 統合: ブランチの変化として名指しする（3 フィールドの帰属が生きている）"
else
  bad "E1 統合: branch の変化が診断に出ない"
  tail -10 "$TMP/run.log" | sed 's/^/    | /' >&2
fi
clear_mutations

# --- E4 統合: 往復（前後比較では検出できない形を固定 diff が受け止める） ---
# 別ブランチへ移って元へ戻すので前後スナップショットは一致し、ガードは発火しない。
# それでもタスクが読む diff は固定したバイト列のままであることを主張する。
reset_repo
clear_mutations
: > "$TMP/mutate-roundtrip"
rm -rf "$REPO/.review-results" "$PROMPT_DIR"/*
if run_orchestrator; then
  ok "E4 統合: 往復は前後一致なのでガードは発火しない（誤発火しない）"
else
  bad "E4 統合: 往復で誤発火した"
  tail -10 "$TMP/run.log" | sed 's/^/    | /' >&2
fi
if [[ -f "$REPO/.review-results/.fixed-diff" ]] \
   && sed -n '/## Code Changes/,$p' "$PROMPT_DIR"/prompt.* 2>/dev/null \
      | /usr/bin/grep -q "app.txt"; then
  ok "E4 統合: 往復中でもプロンプトは固定した diff を載せている"
else
  bad "E4 統合: 往復中に固定 diff が失われている"
fi
clear_mutations

# --- E6 統合: 実行中の作業ツリー汚染（新規 untracked ファイル） ---
reset_repo
clear_mutations
: > "$TMP/mutate-untracked"
rm -rf "$REPO/.review-results" "$PROMPT_DIR"/*
if run_orchestrator; then
  bad "E6 統合: 作業ツリーへの新規ファイル生成が見逃された"
else
  ok "E6 統合: 実行中の新規 untracked ファイルで非 0 終了する"
fi
if /usr/bin/grep -q "^   worktree:" "$TMP/run.log" && ! /usr/bin/grep -q "^   HEAD:" "$TMP/run.log"; then
  ok "E6 統合: 作業ツリーの変化だけを名指しする（HEAD は挙げない）"
else
  bad "E6 統合: 作業ツリーの変化が診断に出ない"
fi

# --- 中核シナリオ: 複数タスクが同一の diff を読むこと ---
# この Issue の出発点は「タスクごとに別の瞬間の diff を読む」ことだった。単一タスクの
# 実行ではその形を再現できないので、2 タスクを --sequential で走らせ、先行タスクが
# 作業ツリーを書き換えた**あと**に後続タスクが起動する順序を作る。修正前の実装なら
# 後続タスクは書き換え後の diff を読む。修正後は 2 つのプロンプトが同じバイト列を持つ。
reset_repo
clear_mutations
: > "$TMP/mutate-worktree"
rm -rf "$REPO/.review-results" "$PROMPT_DIR"/*
set +e
run_isolated PATH="$STUB:/usr/bin:/bin" bash "$MULTI_AGENT" \
  --task review --cli codex-cli --sequential \
  --base develop --timeout 60 >"$TMP/multi.log" 2>&1
set -e
clear_mutations
PROMPT_COUNT="$(find "$PROMPT_DIR" -maxdepth 1 -type f -name 'prompt.*' | wc -l | tr -d ' ')"
if [[ "$PROMPT_COUNT" -ge 2 ]]; then
  ok "前提: 2 タスク以上が起動した（単一タスクでは中核シナリオを再現できない）"
  # 各プロンプトの diff 部分だけを取り出して突き合わせる
  # 抽出が空振りしていないことを先に主張する。見出しが build_prompt 側で改名されると
  # 全ファイルで抽出が空になり、ハッシュが「空入力の 1 種」へ潰れて DIFF_HASHES=1 に
  # なる — この suite で最も強い検査が静かに緑を返す形になる。
  EXTRACTED_MIN="$(for f in "$PROMPT_DIR"/prompt.*; do
      sed -n '/## Code Changes/,$p' "$f" | wc -c | tr -d ' '
    done | sort -n | head -1)"
  if [[ "${EXTRACTED_MIN:-0}" -gt 100 ]]; then
    ok "前提: 各プロンプトから diff 部分を抽出できている（${EXTRACTED_MIN} bytes 以上）"
  else
    bad "前提が崩れた: プロンプトから diff 部分を抽出できていない（見出しの改名？）"
  fi
  DIFF_HASHES="$(for f in "$PROMPT_DIR"/prompt.*; do
      sed -n '/## Code Changes/,$p' "$f" | git hash-object --stdin
    done | sort -u | wc -l | tr -d ' ')"
  if [[ "$DIFF_HASHES" == "1" ]]; then
    ok "中核: 先行タスクが作業ツリーを書き換えても全タスクが同一の diff を読む"
  else
    bad "中核: タスク間で diff が食い違っている（固定が効いていない。異なる内容 ${DIFF_HASHES} 種）"
  fi
else
  bad "前提が崩れた: 起動したタスクが ${PROMPT_COUNT} 件（2 件以上を期待）"
fi

# --- 出力先の境界: tracked ファイルを含む出力先を入口で弾く ---
# 除外は 4 つの問い合わせすべてに効くので、`--output-dir src` のようにソースを含む
# ディレクトリを指定されると実コードの変更がガードから消える。同時に、出力先に
# tracked ファイルがあると orchestrator 自身の上書きで毎回破棄になる。どちらも
# 「起動してから壊れる」ので、入口で止める。
reset_repo
clear_mutations
rm -rf "$REPO/.review-results" "$PROMPT_DIR"/*
set +e
run_isolated PATH="$STUB:/usr/bin:/bin" bash "$MULTI_AGENT" \
  --task review --cli codex-cli --perspective code-review \
  --base develop --timeout 60 --output-dir "$REPO/src" >"$TMP/srcout.log" 2>&1
SRCOUT_RC=$?
set -e
if [[ $SRCOUT_RC -ne 0 ]] && /usr/bin/grep -q "contains tracked files" "$TMP/srcout.log"; then
  ok "出力先に tracked ファイルがあれば起動前に弾く（ガードの無効化を塞ぐ）"
else
  bad "tracked ファイルを含む出力先が通ってしまう (rc=${SRCOUT_RC})"
  tail -6 "$TMP/srcout.log" | sed 's/^/    | /' >&2
fi

# --- 出力先の境界: リポジトリ root を弾く ---
# root は「厳密な部分パス」ではないため除外が効かず、自分が書く .fixed-diff で
# 毎回ガードに掛かる。しかも診断は「リポジトリが変化した」と出て、利用者は存在しない
# checkout を探すことになる。
set +e
run_isolated PATH="$STUB:/usr/bin:/bin" bash "$MULTI_AGENT" \
  --task review --cli codex-cli --perspective code-review \
  --base develop --timeout 60 --output-dir "$REPO" >"$TMP/rootout.log" 2>&1
ROOTOUT_RC=$?
set -e
if [[ $ROOTOUT_RC -ne 0 ]] && /usr/bin/grep -q "must not be the repository root" "$TMP/rootout.log"; then
  ok "出力先がリポジトリ root なら起動前に弾く（誤診断つきの毎回失敗を避ける）"
else
  bad "リポジトリ root の出力先が通ってしまう (rc=${ROOTOUT_RC})"
  tail -6 "$TMP/rootout.log" | sed 's/^/    | /' >&2
fi
reset_repo
rm -rf "$REPO/.review-results"

# --- 破棄した実行の個別結果が「完成」を名乗らないこと ---
# レポートを書かないだけでは足りない。個別結果は書かれた時点で残り、ヘッダーは
# Status: complete のまま — しかもそのパスは skills/multi-review が「後から参照できる」
# と案内している場所そのもの。
reset_repo
clear_mutations
: > "$TMP/mutate-commit"
rm -rf "$REPO/.review-results" "$PROMPT_DIR"/*
run_orchestrator || true
clear_mutations
DISCARDED_FILE="$REPO/.review-results/codex-cli/code-review.md"
if [[ -f "$DISCARDED_FILE" ]]; then
  ok "前提: 破棄された実行でも個別結果はディスクに残る（証跡として保全）"
  if /usr/bin/grep -q "Status: discarded" "$DISCARDED_FILE" \
     && ! /usr/bin/grep -q "Status: complete" "$DISCARDED_FILE"; then
    ok "破棄した実行の個別結果が complete を名乗らない"
  else
    bad "破棄したのに個別結果のヘッダーが complete のまま"
  fi
  if /usr/bin/grep -q "DISCARDED" "$DISCARDED_FILE"; then
    ok "破棄した個別結果の先頭に警告が入る"
  else
    bad "破棄した個別結果に警告が入っていない"
  fi
else
  bad "前提が崩れた: 個別結果が書かれていない"
fi
reset_repo

# --- E3 統合: 実行中の tracked ファイル編集 ---
reset_repo
clear_mutations
: > "$TMP/mutate-worktree"
rm -rf "$REPO/.review-results" "$PROMPT_DIR"/*
if run_orchestrator; then
  bad "E3 統合: 実行中の作業ツリー編集が見逃された"
else
  ok "E3 統合: 実行中の tracked ファイル編集で非 0 終了する"
fi
clear_mutations

# --- E5: --staged レビューでも同じ保護が効く ---
# staged 経路は diff の取り方が別（git diff --cached）なので、固定と検証の両方が
# この経路にも掛かっていることを別途確かめる。
reset_repo
clear_mutations
rm -rf "$REPO/.review-results" "$PROMPT_DIR"/*
printf 'base\nchange\nSTAGED-ONLY-MARKER\n' > "$REPO/src/app.txt"
git -C "$REPO" add src/app.txt
set +e
run_isolated PATH="$STUB:/usr/bin:/bin" bash "$MULTI_AGENT" \
  --task review --cli codex-cli --perspective code-review \
  --staged --timeout 60 >"$TMP/staged.log" 2>&1
STAGED_RC=$?
set -e
if [[ $STAGED_RC -eq 0 ]]; then
  ok "E5: --staged の正常系が誤発火せず完走する"
else
  bad "E5: --staged の正常系で非 0 終了した"
  tail -12 "$TMP/staged.log" | sed 's/^/    | /' >&2
fi
# 非空だけでは足りない（ブランチ diff も非空なので、--staged が固定時に無視される
# 退行を検出できない）。staged 側にしか無いマーカーの有無で見る。
if /usr/bin/grep -q "STAGED-ONLY-MARKER" "$REPO/.review-results/.fixed-diff" 2>/dev/null; then
  ok "E5: 固定 diff の中身が staged の内容になっている"
else
  bad "E5: 固定 diff が staged の内容でない（--staged が固定時に無視されている）"
fi
reset_repo

# --- diff を載せないタスクは前回の固定 diff を持ち越さない ---
# explore は diff をプロンプトへ載せないので固定 diff を作らない。消さずに残すと、
# 直前の review が残した diff がその実行の成果物として並ぶ。
reset_repo
clear_mutations
rm -rf "$REPO/.review-results" "$TMP/explore-out"
run_orchestrator || true
[[ -f "$REPO/.review-results/.fixed-diff" ]] || bad "前提: review 実行が固定 diff を残していない"
set +e
run_isolated PATH="$STUB:/usr/bin:/bin" bash "$MULTI_AGENT" \
  --task explore --cli codex-cli --perspective dependency-mapping \
  --description "stub exploration" --output-dir "$REPO/.review-results" \
  --timeout 60 >"$TMP/explore.log" 2>&1
EXPLORE_RC=$?
set -e
# rc を捨てると、clear_planned_outputs より後の別の失敗でも .fixed-diff は消えるので、
# 「持ち越さない」の主張が別の理由で通ってしまう。
if [[ $EXPLORE_RC -eq 0 ]]; then
  ok "前提: explore 実行が完走した（持ち越し検査が別要因で通らない）"
else
  bad "前提が崩れた: explore 実行が非 0 (rc=${EXPLORE_RC})"
  tail -8 "$TMP/explore.log" | sed 's/^/    | /' >&2
fi
if [[ ! -f "$REPO/.review-results/.fixed-diff" ]]; then
  ok "diff を載せないタスクは前回の固定 diff を持ち越さない"
else
  bad "explore 実行後も前回の固定 diff が残っている（今回の成果物に見える）"
fi
reset_repo

# --- 検証不能を成功に見せない（実行後のスナップショットが取れない場合） ---
# 「変化がなかった」と「変化したか分からない」は別の事実で、後者を成功として返すのは
# この機構が塞いでいる silent failure そのもの。
reset_repo
clear_mutations
: > "$TMP/mutate-unverifiable"
rm -rf "$REPO/.review-results" "$PROMPT_DIR"/*
if run_orchestrator; then
  bad "検証不能な実行が rc=0 で成功扱いになった"
else
  ok "実行後のスナップショットを取得できない場合は非 0 終了する"
fi
if /usr/bin/grep -q "Cannot read the repository state after the run" "$TMP/run.log"; then
  ok "検証不能を「変化なし」ではなく「検証できなかった」として報告する"
else
  bad "検証不能の診断が出ない"
  tail -8 "$TMP/run.log" | sed 's/^/    | /' >&2
fi
clear_mutations
if [[ ! -f "$REPO/.review-results/integrated-report.md" ]]; then
  ok "検証不能な実行では統合レポートを生成しない"
else
  bad "検証不能なのに統合レポートが生成された"
fi
reset_repo

# --- stale レポートを残さない ---
# 「レポート未生成」で終わるとき、前回のレポートが残っていると、中断を告げた直後に
# 案内先（cat integrated-report.md）で無関係な前回の結果を読ませることになる。
reset_repo
clear_mutations
rm -rf "$REPO/.review-results" "$PROMPT_DIR"/*
run_orchestrator || true
[[ -f "$REPO/.review-results/integrated-report.md" ]] || bad "前提: 先行実行のレポートが作られていない"
: > "$TMP/mutate-commit"
rm -f "$PROMPT_DIR"/*
run_orchestrator || true
if [[ ! -f "$REPO/.review-results/integrated-report.md" ]]; then
  ok "中断時に前回の統合レポートが残らない（stale 誤読を塞ぐ）"
else
  bad "中断したのに前回の統合レポートが残っている"
fi
clear_mutations

# ══════════════════════════════════════════════════════════════
echo "== ミューテーション: ガードが実際に効いているか =="
# ══════════════════════════════════════════════════════════════
# 検査が「たまたま通っている」だけでないことを、被検体を壊して確かめる。
MUTANT_ROOT="$TMP/mutant"
rm -rf "$MUTANT_ROOT"
mkdir -p "$MUTANT_ROOT"
cp -R "$PLUGIN_ROOT/scripts" "$MUTANT_ROOT/scripts"
MUTANT_MULTI_AGENT="$MUTANT_ROOT/scripts/multi-agent.sh"
MUTANT_COMMON="$MUTANT_ROOT/scripts/adapters/adapter-common.sh"

run_mutant() {
  set +e
  run_isolated PATH="$STUB:/usr/bin:/bin" bash "$1" \
    --task review --cli codex-cli --perspective code-review \
    --base develop --timeout 60 \
    >"$TMP/mutant.log" 2>&1
  local rc=$?
  set -e
  return $rc
}

# M1: 事後検証の呼び出しを取り除く → E2 統合が見逃されるはず
perl -0pi -e 's/^(\s*)verify_repo_unchanged \|\| exit 1$/$1: # mutated/m' "$MUTANT_MULTI_AGENT"
# 適用できたかは**実際に中身が変わったか**で判定する（M3 の注記と同じ理由）。
if cmp -s "$MUTANT_MULTI_AGENT" "$PLUGIN_ROOT/scripts/multi-agent.sh"; then
  bad "M1: ミューテーションを適用できなかった（被検体と同一。検査が無意味）"
else
  reset_repo
  clear_mutations
  : > "$TMP/mutate-commit"
  rm -rf "$REPO/.review-results"
  if run_mutant "$MUTANT_MULTI_AGENT"; then
    ok "M1: 事後検証を外すと commit が見逃される（本体の検査が効いている証拠）"
  else
    bad "M1: 事後検証を外しても非 0 のまま（別要因で落ちており E2 統合が空振りの疑い）"
    tail -10 "$TMP/mutant.log" | sed 's/^/    | /' >&2
  fi
  clear_mutations
fi

# M2: 不在 DIFF_FILE で従来取得へフォールバックさせる → 固定が無意味になるはず
perl -0pi -e 's/echo "ERROR: --diff-file is missing or unreadable: \$\{DIFF_FILE\}" >&2/get_diff_content "\$base_branch"; return 0/' "$MUTANT_COMMON"
if cmp -s "$MUTANT_COMMON" "$PLUGIN_ROOT/scripts/adapters/adapter-common.sh"; then
  bad "M2: ミューテーションを適用できなかった（被検体と同一。検査が無意味）"
else
  # **別プロセス**で読み込む。本 suite は既に adapter-common.sh を source しており、
  # そこで定義された readonly 変数は subshell にも引き継がれるため、subshell 内で
  # もう一度 source すると "readonly variable" で落ちる — ミューテーションの成否では
  # なく二重 source の失敗を測ってしまう。
  set +e
  env -u DIFF_FILE bash -c '
    set -euo pipefail
    cd "$1"
    . "$2"
    DIFF_FILE="$3"
    prompt_diff_content develop >/dev/null 2>&1
  ' _ "$REPO" "$MUTANT_COMMON" "$TMP/does-not-exist.diff"
  MUT_RC=$?
  set -e
  if [[ $MUT_RC -eq 0 ]]; then
    ok "M2: フォールバックさせると rc=0 で通る（fail-loud の検査が効いている証拠）"
  else
    bad "M2: フォールバックさせても非 0（不在 DIFF_FILE の検査が空振りの疑い）"
  fi
fi

# M3: 作業ツリーの指紋を `git status` だけへ戻す（内容に盲目な旧実装）→ 既に dirty な
# ファイルの追加編集が見逃されるはず。この退行は状態コードが同じままなので、
# 「新規に変更が現れる」形しか試していない検査では緑のまま通り抜ける。
MUTANT_COMMON_M3="$TMP/adapter-common-status-only.sh"
# tracked の内容を見る 2 行だけを落とす。適用できたかどうかは**実際に中身が変わったか**
# で判定する — パターン一致の有無で判定すると、被検体の書き方が変わったときに
# 「変異を当てられなかった」ことに気づけないまま検査だけが通り抜ける（実際に踏んだ）。
# 行を削除すると空の if ブロックになって構文エラーで落ちる（＝変異ではなく破壊）。
# no-op へ置換して、挙動だけが変わった状態を作る。
perl -pe 's/^(\s*)git diff (?:HEAD|--cached) -- "\$\{pathspec\[\@\]\}" \|\| exit 1$/$1:/' \
  "$PLUGIN_ROOT/scripts/adapters/adapter-common.sh" > "$MUTANT_COMMON_M3"
if cmp -s "$MUTANT_COMMON_M3" "$PLUGIN_ROOT/scripts/adapters/adapter-common.sh"; then
  bad "M3: ミューテーションを適用できなかった（被検体と同一。検査が無意味）"
else
  reset_repo
  echo "already dirty" >> "$REPO/src/app.txt"
  set +e
  env -u DIFF_FILE bash -c '
    set -euo pipefail
    cd "$1"
    . "$2"
    before="$(capture_repo_snapshot)"
    echo "edited again mid-run" >> src/app.txt
    after="$(capture_repo_snapshot)"
    [ "$before" = "$after" ]
  ' _ "$REPO" "$MUTANT_COMMON_M3"
  M3_RC=$?
  set -e
  if [[ $M3_RC -eq 0 ]]; then
    ok "M3: 内容の指紋を外すと dirty ファイルの追加編集が見逃される（検査が効いている証拠）"
  else
    bad "M3: 内容の指紋を外しても検出される（内容指紋の検査が空振りの疑い）"
  fi
  reset_repo
fi

# M4: リポジトリ root への cd を外す → 除外が CWD 相対に縮み、サブディレクトリからの
# 呼び出しが root からの呼び出しと食い違うはず。走査範囲は ':/' が固定するので、
# **除外を渡さない比較ではこの退行を検出できない**（この suite が実際に踏んでいた穴）。
MUTANT_COMMON_M4="$TMP/adapter-common-no-cd.sh"
perl -pe 's/^(\s*)cd "\$root" \|\| exit 1$/$1:/' \
  "$PLUGIN_ROOT/scripts/adapters/adapter-common.sh" > "$MUTANT_COMMON_M4"
if cmp -s "$MUTANT_COMMON_M4" "$PLUGIN_ROOT/scripts/adapters/adapter-common.sh"; then
  bad "M4: ミューテーションを適用できなかった（被検体と同一。検査が無意味）"
else
  reset_repo
  mkdir -p "$REPO/.review-results"
  echo out > "$REPO/.review-results/dummy.md"
  set +e
  env -u DIFF_FILE bash -c '
    set -euo pipefail
    cd "$1"
    . "$2"
    root_snap="$(capture_repo_snapshot .review-results)"
    sub_snap="$(cd src && capture_repo_snapshot .review-results)"
    [ "$root_snap" = "$sub_snap" ]
  ' _ "$REPO" "$MUTANT_COMMON_M4" 2>/dev/null
  M4_RC=$?
  set -e
  if [[ $M4_RC -ne 0 ]]; then
    ok "M4: cd を外すとサブディレクトリからの値が食い違う（cd の検査が効いている証拠）"
  else
    bad "M4: cd を外しても一致する（CWD 非依存の検査が空振りの疑い）"
  fi
  reset_repo
  rm -rf "$REPO/.review-results"
fi

# M5: 指紋から git diff --cached を外す → worktree と status コードを固定したまま
# index だけが動く変化（--staged レビューが読む面）が見逃されるはず。
MUTANT_COMMON_M5="$TMP/adapter-common-no-cached.sh"
perl -pe 's/^(\s*)git diff --cached -- "\$\{pathspec\[\@\]\}" \|\| exit 1$/$1:/' \
  "$PLUGIN_ROOT/scripts/adapters/adapter-common.sh" > "$MUTANT_COMMON_M5"
if cmp -s "$MUTANT_COMMON_M5" "$PLUGIN_ROOT/scripts/adapters/adapter-common.sh"; then
  bad "M5: ミューテーションを適用できなかった（被検体と同一。検査が無意味）"
else
  reset_repo
  set +e
  env -u DIFF_FILE bash -c '
    set -euo pipefail
    cd "$1"
    . "$2"
    printf "A\n" > src/app.txt; git add src/app.txt; printf "B\n" > src/app.txt
    before="$(capture_repo_snapshot)"
    printf "A2\n" > src/app.txt; git add src/app.txt; printf "B\n" > src/app.txt
    after="$(capture_repo_snapshot)"
    [ "$before" = "$after" ]
  ' _ "$REPO" "$MUTANT_COMMON_M5"
  M5_RC=$?
  set -e
  if [[ $M5_RC -eq 0 ]]; then
    ok "M5: --cached を外すと index だけの変化が見逃される（検査が効いている証拠）"
  else
    bad "M5: --cached を外しても検出される（index 成分の検査が空振りの疑い）"
  fi
  reset_repo
fi

# ══════════════════════════════════════════════════════════════
echo ""
echo "── 結果: ${PASS} passed, ${FAIL} failed ──"
[[ "$FAIL" -eq 0 ]] || exit 1
exit 0
