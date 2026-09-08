#!/usr/bin/env bash
#
# adapter-prompt-guard: build_prompt の実行境界（再帰防止ガード）の回帰検査（Issue #263）。
#
# 背景: サブレビューの CLI がレビュー対象プロジェクトの AGENTS.md / レビュー用
# スキルを読み込み、プロジェクト規約に従って別のレビューラッパーや AI CLI を
# 再帰起動し、結果を返さないままタイムアウトする事故が実レビューで起きた。
# 対策はプロンプト先頭近くの Execution Boundary 宣言で、本 suite はその宣言が
# (1) 生成されること、(2) perspective（プロジェクト側指示文の入口）より前に
# 置かれること、(3) task-type ごとのファイル操作境界が正しいこと、(4) codex
# アダプタの実 argv まで届くこと、を固定する。
#
# Issue #392 の追加分: implement の staging ディレクトリ**実パス**がプロンプトに
# 載ること。パスを渡さずに「staging にだけ書け」と命じると、エージェントは推測する
# しかなく、最も自然な推測は CWD = 作業ツリーになる。ここで固定するのは
# (a) パスを渡せば実パスが載り、退避文言（インライン出力）が消えること、
# (b) 渡さなければ退避文言が残ること（直叩き実行の正式サポート）、
# (c) --staging-dir が codex の実 argv まで届くこと、の 3 点。
#
# ガードの効果そのもの（LLM が指示に従うか）は stub では測れない。ここで固定する
# のは「ガードが届いている」ことまでで、実効性は実 CLI での完走確認を PR に記録する。
#
# 実 CLI・ネットワーク・課金は伴わない。書き込み不可の環境では skip。

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd -P)"
ADAPTER_COMMON="$PLUGIN_ROOT/scripts/adapters/adapter-common.sh"
ADAPTERS_DIR="$PLUGIN_ROOT/scripts/adapters"
# fixture リポジトリの identity を呼び出し元へ漏らさない（Issue #1348 / #1368）
# fixture リポジトリの identity を呼び出し元へ漏らさない（Issue #1348 / #1368）
# shellcheck source=../lib/git-fixture.sh
. "$SCRIPT_DIR/../lib/git-fixture.sh"

[ -f "$ADAPTER_COMMON" ] || {
  echo "✗ 対象ファイルが見つかりません: $ADAPTER_COMMON" >&2
  exit 1
}

# shellcheck source=../lib/adapter-env-isolation.sh
. "$SCRIPT_DIR/../lib/adapter-env-isolation.sh"
# orchestrator も起動する suite なので、アダプタ変数だけでなく orchestrator 専用の
# 変数も -u の対象へ入れる（lib の契約どおり 2 本渡す）。これが無いと、利用者が
# MULTI_AGENT_CONFIG を export しているだけで本 suite が環境依存で赤くなる
# — 実測: `mode: pair` を書いた config を指すと implement 実行が rc=1 で落ちる。
build_isolate_env "MULTI_AGENT_CONFIG MULTI_AGENT_MODEL_CLAUDE_CODE" \
  "$PLUGIN_ROOT/scripts/multi-agent.sh" "$ADAPTERS_DIR"/*.sh

# mktemp の stderr を捨てない。捨てると read-only 以外の失敗（TMPDIR が不正な
# パス・quota 超過など）まで「書き込み可能な環境で再実行してください」に誤帰属し、
# 恒常的に壊れた TMPDIR が suite を exit 0 で無効化し続ける。2>&1 で受けると
# 成功時はパス・失敗時は理由が同じ変数に入る。
# rc=0 でも -d を検査する — 2>&1 の合流は「成功 + stderr 警告」の環境で変数へ
# 警告文が混入し、以後の git init が原因不明の失敗に化けるため。
# skip 文言で read-only と断定しない（すぐ上のコメントのとおり原因は 1 つではない。
# 断定すると、壊れた TMPDIR の調査が read-only の確認だけで打ち切られる）。
_ff_mktemp_rc=0
_ff_mktemp_out="$(mktemp -d 2>&1)" || _ff_mktemp_rc=$?
if [ "$_ff_mktemp_rc" -eq 0 ] && [ -d "$_ff_mktemp_out" ]; then
  TMP="$_ff_mktemp_out"
else
  echo "○ skip: 一時ディレクトリを作成できない環境のためスキップ"
  printf '  mktemp: %s\n' "$_ff_mktemp_out"
  # rc=0 なのに -d が偽 = 出力へ警告文が混入した形。ディレクトリ自体は作られている
  # 可能性が高いが、パスを警告文と機械的に分離できない（2>&1 の合流順は保証されない）
  # ため自動削除はしない。次の一手だけを 1 行で示す（Issue #769 項目 5）。
  if [ "$_ff_mktemp_rc" -eq 0 ]; then
    echo "  次の一手: mktemp は成功(rc=0)しているため、上記出力中のパスに一時ディレクトリが未回収で残っている可能性があります。手動で確認・削除してください。"
  fi
  exit 0
fi
# 途中死を沈黙させない。`set -u` 等で死んだとき、トラップ突入時の $? は **0** になるため、
# 終了ステータスを保存し直すだけでは足りない（実測）。「rc=0 なのに最後まで到達して
# いない」を中断として扱う。明示的な非 0 終了はそのまま通す。
FF_REACHED_END=0
_ff_exit_guard() {
  _ff_rc=$?
  rm -rf "$TMP"
  # 残留検査の陰性対照だけは $TMP の外（走査先の共有 temp 直下）に置くので、
  # 上の rm -rf では届かない。途中死でも取り残さないようここで消す。
  if [ -n "${FF_DECOY_LIST:-}" ]; then
    printf '%s' "$FF_DECOY_LIST" | while IFS= read -r _ff_decoy; do
      if [ -n "$_ff_decoy" ]; then rm -f "$_ff_decoy"; fi
    done
  fi
  if [ "$_ff_rc" -eq 0 ] && [ "$FF_REACHED_END" -ne 1 ]; then
    echo "✗ adapter-prompt-guard: 最後まで到達しませんでした（途中で中断）" >&2
    exit 1
  fi
  # rc≠0 の途中死にも 1 行の文脈を残す。死んだコマンドが自分では何も喋らない形
  #（SIGPIPE 等）だと、captured 出力は ✓ の羅列のまま suite だけ赤くなり、
  # 読む人に原因の手がかりが残らない。
  if [ "$_ff_rc" -ne 0 ] && [ "$FF_REACHED_END" -ne 1 ]; then
    echo "✗ adapter-prompt-guard: サマリー前に中断しました (rc=${_ff_rc})" >&2
  fi
  exit "$_ff_rc"
}
trap _ff_exit_guard EXIT

PASS=0
FAIL=0
ok()  { echo "  ✓ $1"; PASS=$((PASS + 1)); }
bad() { echo "  ✗ $1" >&2; FAIL=$((FAIL + 1)); }

# --- diff を持つ一時リポジトリ（review の build_prompt は diff 必須） ---
# グローバル / システムの git 設定（core.hooksPath / init.templateDir 由来の hook など）を
# fixture へ継承させない。継承すると利用者環境の hook が fixture の git commit で実行され、
# 失敗時に suite の文脈なしの git エラーで abort する。orchestrator を起動するケースでも
# 同じ設定で走らせたいので export する（run_isolated の -u は MULTI_AGENT_* / FF_TIMEOUT_*
# だけを落とすので、この 2 つはサブプロセスまで届く）。
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
REPO="$TMP/repo"
ff_git_fixture_init "$REPO" "adapter-prompt-guard-test" "test@example.com"
cd "$REPO"
git config commit.gpgsign false
git switch -q -c develop
echo base > app.txt
git add app.txt
git commit -qm "init"
git switch -q -c feature/x
printf 'base\nchange\n' > app.txt
git add app.txt
git commit -qm "change"

# 上の遮断が効いていることを検査で固定する（項目 4 だけが針を持たず fail-open していた）。
# GIT_CONFIG_GLOBAL は git 2.32 以降でしか解釈されないので、古い git では継承が起きる。
# 黙って継承したまま緑にするより、理由を名指しして赤くする方がよい。
# 判定は「全件 == ローカル件数」で行う。origin のパス書式に照合しないこと: git は
# --show-origin を **cwd 相対**（`file:.git/config`）で出すため、絶対パスで除外する形は
# cwd 依存で静かに空振りする（実測でこれを踏んだ）。件数は git 自身に数えさせる。
git config --list >"$TMP/gitcfg-all.txt" 2>/dev/null || true
git config --list --local >"$TMP/gitcfg-local.txt" 2>/dev/null || true
GITCFG_ALL="$(/usr/bin/grep -c '' "$TMP/gitcfg-all.txt" || true)"
GITCFG_LOCAL="$(/usr/bin/grep -c '' "$TMP/gitcfg-local.txt" || true)"
[ -n "$GITCFG_ALL" ] || GITCFG_ALL=0
[ -n "$GITCFG_LOCAL" ] || GITCFG_LOCAL=0
if [ "$GITCFG_ALL" -eq "$GITCFG_LOCAL" ] && [ "$GITCFG_LOCAL" -gt 0 ]; then
  ok "fixture の git 設定はグローバル / システムを継承しない（全 ${GITCFG_ALL} 件がローカル）"
else
  bad "fixture の git 設定に外部由来が混ざる（全 ${GITCFG_ALL} 件 / ローカル ${GITCFG_LOCAL} 件。GIT_CONFIG_GLOBAL は git 2.32 以降。実行中: $(git --version)）"
  git config --list --show-origin >"$TMP/gitcfg-origins.txt" 2>/dev/null || true
  sed 's/^/    | /' "$TMP/gitcfg-origins.txt" >&2 || true
fi

# --- perspective fixture（プロジェクト指示文の位置を示す一意マーカー入り） ---
PERSPECTIVE="$TMP/perspective.md"
printf '%s\n' '# Fixture Perspective' 'PERSPECTIVE-CONTENT-MARKER' > "$PERSPECTIVE"

# build_prompt をサブシェルで直接呼ぶ（multi-agent-timeout の D1/D2 と同じ経路）。
# $2 を省略すると STAGING_DIR 未設定 = orchestrator を経由しない直叩き実行の再現。
#
# プレフィックスを持たない build_prompt の入力（DIFF_FILE 等）は、lib の
# unset_prompt_env_vars で落とす（名簿は lib の 1 箇所だけ。Issue #769）。漏れると
# diff の取得元や有無が変わる（本 suite は fixture リポジトリの diff を前提にする）。
# アダプタを CLI として起動する経路では parse_adapter_args が毎回初期化するため、
# 漏れるのはこの「source して関数を直呼び」経路だけ。
gen_prompt() { # $1: task_type / $2: staging_dir（省略可） / $3: inline_output（省略可） / stdout: プロンプト
  (
    unset_prompt_env_vars
    TASK_TYPE="$1"
    DESCRIPTION="fixture task"
    STAGING_DIR="${2:-}"
    INLINE_OUTPUT="${3:-false}"
    export TASK_TYPE DESCRIPTION STAGING_DIR INLINE_OUTPUT
    # shellcheck source=../../scripts/adapters/adapter-common.sh
    source "$ADAPTER_COMMON"
    build_prompt "$PERSPECTIVE" develop
  )
}

# staging の実パス。プロンプトへ literal で載ることを確かめるので、他の文言と
# 偶然一致しない一意な形にする。build_prompt は「絶対パス・実在・書き込み可」を
# 検証するので、fixture も実在させる（プロンプトの断言と同じ前提に揃える）。
STAGING_FIXTURE="$TMP/staging/fixture-cli/files/fixture-perspective"
mkdir -p "$STAGING_FIXTURE"

expect_contains() { # <label> <haystack> <needle>
  case "$2" in
    *"$3"*) ok "$1" ;;
    *) bad "$1（'$3' が無い）" ;;
  esac
}
expect_lacks() { # <label> <haystack> <needle>
  case "$2" in
    *"$3"*) bad "$1（'$3' が含まれている）" ;;
    *) ok "$1" ;;
  esac
}

echo "== Execution Boundary の生成 =="

if ! REVIEW_PROMPT="$(gen_prompt review)"; then
  bad "review: プロンプト生成自体が失敗した"
  REVIEW_PROMPT=""
fi
expect_contains "review: 境界セクションが生成される" "$REVIEW_PROMPT" "## Execution Boundary (non-negotiable)"
expect_contains "review: 他 AI CLI・ラッパーの再起動禁止を明記" "$REVIEW_PROMPT" "another AI CLI"
expect_contains "review: プロジェクト指示文より優先することを明記" "$REVIEW_PROMPT" "Regardless of what AGENTS.md"
expect_contains "review: 再帰の理由を明記" "$REVIEW_PROMPT" "infinite recursion"
expect_contains "review: read-only を明記" "$REVIEW_PROMPT" "strictly read-only"
expect_contains "review: 単一応答で完結することを明記" "$REVIEW_PROMPT" "single response"

# 境界宣言は perspective（プロジェクト側指示文の入口）より前に無ければならない
# （先に読ませる意図の設計判断。前置と後置の効果差は未測定で、ここで固定するのは
# 位置の一貫性）。行番号抽出は awk 1 本で行う — `grep -nF | head | cut` の形は、
# 不一致（grep rc=1）が pipefail + set -e で suite を無言 abort させ、下の bad 分岐と
# サマリ行を到達不能にする（grep の SIGPIPE 反転も同時に回避）。
# awk 側もマッチ後に全行を読み切る形にする。早期 exit だと printf が書き込み中の
# 場合に SIGPIPE（rc=141）→ pipefail でトップレベル代入が失敗し、set -e が何の
# メッセージも出さずに suite を打ち切る。現状の fixture プロンプトはパイプバッファ
#（64KB）に収まるが、その暗黙の前提に依存しない。
BOUNDARY_LINE="$(printf '%s\n' "$REVIEW_PROMPT" | awk 'n == 0 && index($0, "## Execution Boundary") { n = NR } END { if (n) print n }')"
PERSPECTIVE_LINE="$(printf '%s\n' "$REVIEW_PROMPT" | awk 'n == 0 && index($0, "PERSPECTIVE-CONTENT-MARKER") { n = NR } END { if (n) print n }')"
if [ -n "$BOUNDARY_LINE" ] && [ -n "$PERSPECTIVE_LINE" ] && [ "$BOUNDARY_LINE" -lt "$PERSPECTIVE_LINE" ]; then
  ok "review: 境界宣言が perspective より前にある（${BOUNDARY_LINE} 行目 < ${PERSPECTIVE_LINE} 行目）"
else
  bad "review: 境界宣言が perspective より前に無い（boundary=${BOUNDARY_LINE:-なし} perspective=${PERSPECTIVE_LINE:-なし}）"
fi

echo "== ホスト環境からの diff 汚染の遮断（Issue #564） =="

# gen_prompt の unset が外れると、利用者が export した DIFF_FILE / STAGED_DIFF /
# INCLUDE_DIFF を build_prompt が読み、**fixture リポジトリではない diff**（あるいは
# 空の diff）でプロンプトを組み立てる。症状は「そのマシンでだけ赤い suite」で、
# Issue #374 / #378 で潰した env 漏れと同型。unset する 3 変数それぞれに、漏れたときだけ
# 落ちる針を置く（DIFF_FILE は載る側と囮の不在の 2 件、STAGED_DIFF は載る側 1 件、
# INCLUDE_DIFF は diff 節が生えないことの不在検査 1 件。「対」になっているのは DIFF_FILE のみ）。
#
# 効いている針は「fixture の変更行が載っていること」の方。DECOY マーカーの不在は
# 単独では空振りしうる（漏れ方によっては diff が空になり、マーカーも当然入らない）。
# CHANGED_FILES は現在 build_prompt から読まれていないため針を書けない。unset は
# 将来 Changed Files 節が復活したときのための予防で、ここでは主張しない。
DECOY_DIFF="$TMP/decoy.diff"
printf '%s\n' 'diff --git a/decoy.txt b/decoy.txt' '+DECOY-DIFF-MARKER' > "$DECOY_DIFF"

if ! DIFFFILE_LEAK_PROMPT="$(
  export DIFF_FILE="$DECOY_DIFF" CHANGED_FILES="decoy.txt"
  gen_prompt review
)"; then
  bad "review(DIFF_FILE 汚染下): プロンプト生成自体が失敗した"
  DIFFFILE_LEAK_PROMPT=""
fi
expect_contains "ホストの DIFF_FILE 下でも fixture の diff を載せる" "$DIFFFILE_LEAK_PROMPT" "+change"
expect_lacks "ホストの DIFF_FILE の中身を載せない" "$DIFFFILE_LEAK_PROMPT" "DECOY-DIFF-MARKER"

# STAGED_DIFF が漏れると get_diff_content が `git diff --cached` へ切り替わり、
# 全コミット済みの fixture では diff が空になる（DIFF_FILE より後に効くので、
# 上のケースだけでは STAGED_DIFF を unset から外す変異が生き残る）。
if ! STAGED_LEAK_PROMPT="$(
  export STAGED_DIFF=true
  gen_prompt review
)"; then
  bad "review(STAGED_DIFF 汚染下): プロンプト生成自体が失敗した"
  STAGED_LEAK_PROMPT=""
fi
expect_contains "ホストの STAGED_DIFF 下でも fixture の diff を載せる" "$STAGED_LEAK_PROMPT" "+change"

# INCLUDE_DIFF は implement のみで効く（review には diff が常に載る）。漏れると
# implement プロンプトへ本来無い diff 節が生える。
if ! INCLUDEDIFF_LEAK_PROMPT="$(
  export INCLUDE_DIFF=true
  gen_prompt implement "$STAGING_FIXTURE"
)"; then
  bad "implement(INCLUDE_DIFF 汚染下): プロンプト生成自体が失敗した"
  INCLUDEDIFF_LEAK_PROMPT=""
fi
expect_lacks "ホストの INCLUDE_DIFF で implement へ diff 節が生えない" \
  "$INCLUDEDIFF_LEAK_PROMPT" "## Current Changes (git diff)"

echo "== Execution Boundary の生成（続き） =="

if ! EXPLORE_PROMPT="$(gen_prompt explore)"; then
  bad "explore: プロンプト生成自体が失敗した"
  EXPLORE_PROMPT=""
fi
expect_contains "explore: 境界セクションが生成される" "$EXPLORE_PROMPT" "## Execution Boundary (non-negotiable)"
expect_contains "explore: read-only を明記" "$EXPLORE_PROMPT" "strictly read-only"

echo "== implement: staging パスの伝達（Issue #392） =="

# (a) パスあり — orchestrator 経由の本線
if ! IMPLEMENT_PROMPT="$(gen_prompt implement "$STAGING_FIXTURE")"; then
  bad "implement: プロンプト生成自体が失敗した"
  IMPLEMENT_PROMPT=""
fi
expect_contains "implement: 境界セクションが生成される" "$IMPLEMENT_PROMPT" "## Execution Boundary (non-negotiable)"
expect_contains "implement: staging への出力境界を明記" "$IMPLEMENT_PROMPT" "ONLY under this staging directory"
expect_contains "implement: staging の実パスがプロンプトに載る" "$IMPLEMENT_PROMPT" "$STAGING_FIXTURE"
expect_contains "implement: staging 外への書き込み禁止を明記" "$IMPLEMENT_PROMPT" "the working tree is off limits"
expect_lacks "implement: パスがあるとき退避文言（インライン出力）は出さない" "$IMPLEMENT_PROMPT" "emit the file contents inline"
expect_lacks "implement: read-only 行を含まない（staging 書き込みと矛盾させない）" "$IMPLEMENT_PROMPT" "strictly read-only"

# preamble と境界宣言が同じ分岐を向いていること。片方が「staging へ書け」、
# もう片方が「書くな」だと、エージェントは矛盾を自分で解消して working tree へ行く。
# 抽出は行番号固定ではなく「境界セクションより前の領域」— preamble を可読性のため
# 折り返しただけで赤くなる形にはしない。
# 打ち切りは exit ではなくフラグで行う（上の行番号抽出と同じ理由 — 早期 exit は
# 上流 printf の SIGPIPE を招き、pipefail + set -e で無言 abort する）。
preamble_of() { # $1: プロンプト / stdout: 境界セクションより前の全行
  printf '%s\n' "$1" | awk 'index($0, "## Execution Boundary") { stop = 1 } stop != 1 { print }'
}
IMPLEMENT_PREAMBLE="$(preamble_of "$IMPLEMENT_PROMPT")"
expect_contains "implement: preamble も staging へ書く指示になっている" "$IMPLEMENT_PREAMBLE" "under the staging directory"

# (b) パスなし + --inline-output — アダプタ直叩き実行の正式サポート経路。
# 退避先（インライン出力）が残ることを固定する。
if ! IMPLEMENT_NOSTAGE="$(gen_prompt implement "" true)"; then
  bad "implement(直叩き): プロンプト生成自体が失敗した"
  IMPLEMENT_NOSTAGE=""
fi
expect_contains "implement(直叩き): 退避先（インライン出力）を明記" "$IMPLEMENT_NOSTAGE" "emit the file contents inline"
expect_contains "implement(直叩き): working tree へ書かせない" "$IMPLEMENT_NOSTAGE" "Do NOT write to the working tree"
expect_lacks "implement(直叩き): 存在しない staging へ書けと命じない" "$IMPLEMENT_NOSTAGE" "ONLY under this staging directory"

IMPLEMENT_NOSTAGE_PREAMBLE="$(preamble_of "$IMPLEMENT_NOSTAGE")"
expect_contains "implement(直叩き): preamble も inline 報告の指示になっている" "$IMPLEMENT_NOSTAGE_PREAMBLE" "report the generated files inline"

# (c) パスなし + オプトインなし — 渡し忘れ。静かに退避モードへ落ちず fail-loud。
# これが無いと、orchestrator 側の分岐（TASK_TYPE == implement で --staging-dir を
# 付ける）が壊れたとき、プロンプトが黙って inline 指示に切り替わり、生成ファイル
# 0 個・警告なし・exit 0 で終わる。
set +e
NOSTAGE_ERR="$( (gen_prompt implement) 2>&1 >/dev/null )"
NOSTAGE_RC=$?
set -e
if [ "$NOSTAGE_RC" -ne 0 ]; then
  ok "implement: staging も --inline-output も無い実行を非 0 で拒否する (rc=$NOSTAGE_RC)"
else
  bad "implement: staging 未指定が黙って通った（渡し忘れが退避モードへ静かに落ちる）"
fi
expect_contains "implement: 拒否理由に両方の対処が出る" "$NOSTAGE_ERR" "--inline-output"

# (d) プロンプトの断言（絶対パス・実在・書き込み可）を、断言する層が検証すること。
# 検証が無いと、直叩きが渡した相対パス・不在パス・read-only パスに対しても同じ
# 断言が出る。相対パスが特に危険で、「絶対パスだ」と言われたエージェントは自分の
# CWD = 作業ツリー基準で解決する。
expect_rejects() { # <label> <staging_dir> <期待する理由の断片>
  local out rc
  set +e
  out="$( (gen_prompt implement "$2") 2>&1 >/dev/null )"
  rc=$?
  set -e
  if [ "$rc" -eq 0 ]; then
    bad "$1（黙って通った）"
    return
  fi
  case "$out" in
    *"$3"*) ok "$1" ;;
    *) bad "$1（理由に '$3' が無い: ${out}）" ;;
  esac
}
expect_rejects "implement: 相対パスの staging を拒否する" "relative/staging" "absolute path"
expect_rejects "implement: 実在しない staging を拒否する" "$TMP/does-not-exist" "does not exist"

NOWRITE_STAGING="$TMP/nowrite-staging"
mkdir -p "$NOWRITE_STAGING"
chmod 555 "$NOWRITE_STAGING"
if [ -w "$NOWRITE_STAGING" ]; then
  # root 実行や一部の FS では 555 でも書けてしまう。前提が崩れた検査を
  # 「合格」として数えないよう、明示的にスキップを名乗る。
  echo "  ○ skip: このユーザーでは 555 のディレクトリにも書けるため書込可検査をスキップ"
else
  expect_rejects "implement: 書き込めない staging を拒否する" "$NOWRITE_STAGING" "not writable"
fi
chmod 755 "$NOWRITE_STAGING"

echo "== codex アダプタの実入力（stdin）への到達 =="

# stub codex は argv を 1 引数 1 行で、stdin を丸ごと記録する。Issue #712 以降
# プロンプト本文は argv ではなく stdin（--stdin-file の一時ファイル）で届くため、
# 「プロンプトが届いたか」は stdin.log を、「本文が argv に乗っていないか」
# （Windows CreateProcess ~32KB 上限の再発防止）は argv.log を見る。
#
# implement のアダプタは本番起動の前に `codex exec --help` を読み、書き込み境界を
# staging へ絞る `-C/--cd` があることを確かめてから走る（無ければ広い境界で走らせず
# に停止する）。stub もそこに応答しないと、implement 経路がその停止で終わってしまう。
# 能力確認は本題ではないので**記録も stdin 読み取りもせず**に返し、以降のログ検査を
# 従来どおりの内容に保つ。
CODEX_HELP_ARM='case " $* " in *" exec --help "*) printf "  -C, --cd <DIR>\n"; exit 0 ;; esac'
STUB="$TMP/bin"
mkdir -p "$STUB"
cat > "$STUB/codex" <<SH
#!/usr/bin/env bash
${CODEX_HELP_ARM}
for a in "\$@"; do printf '%s\n' "\$a" >> "$TMP/argv.log"; done
cat >> "$TMP/stdin.log"
echo "- Suggestion: stub review output"
SH
chmod +x "$STUB/codex"

: > "$TMP/argv.log"
: > "$TMP/stdin.log"
set +e
run_isolated PATH="$STUB:$PATH" CODEX_HOME="$TMP/codex-home" \
  bash "$ADAPTERS_DIR/codex-cli-adapter.sh" "$PERSPECTIVE" "$TMP/out.md" \
  --base develop --timeout 30 --task-type review --description "fixture" \
  >"$TMP/adapter.log" 2>&1
ADAPTER_RC=$?
set -e
if [ "$ADAPTER_RC" -ne 0 ]; then
  bad "codex アダプタが非 0 終了した (rc=$ADAPTER_RC)"
  tail -20 "$TMP/adapter.log" | sed 's/^/    | /' >&2
elif [ ! -s "$TMP/argv.log" ]; then
  bad "codex の argv が記録されていない（stub 未経由の疑い）"
elif grep -qF '## Execution Boundary (non-negotiable)' "$TMP/stdin.log"; then
  ok "codex の実入力（stdin）に境界宣言が届いている"
else
  bad "codex の実入力に境界宣言が無い（build_prompt を経由していない疑い）"
  head -10 "$TMP/stdin.log" | sed 's/^/    | /' >&2
fi

# Issue #712 の AC そのもの: プロンプト本文が argv に乗らないこと。ここが argv へ
# 戻ると、Windows / Git Bash では diff が大きいだけで全 CLI が exit 126 になる。
# 負の主張は起動成功（argv 非空）を前提条件にする — アダプタが exec 前に死ぬと
# 空ログへの grep 不一致が「乗っていない」と同じ顔で緑になる。
if [ ! -s "$TMP/argv.log" ]; then
  bad "argv が記録されておらず、負の主張（argv に乗らない）を測定できない"
elif grep -qF '## Execution Boundary (non-negotiable)' "$TMP/argv.log"; then
  bad "プロンプト本文が argv に乗っている（Issue #712 の退行 — Windows で exit 126 に戻る）"
  head -10 "$TMP/argv.log" | sed 's/^/    | /' >&2
else
  ok "プロンプト本文は argv に乗らない（stdin / 一時ファイル経由を維持）"
fi

# --staging-dir が parse_adapter_args → build_prompt → 実 argv まで通ることを、
# アダプタの実起動経路で確かめる。build_prompt 単体の出力だけを見ていると、
# アダプタが引数を落としていても気づけない（本 Issue の原因はまさに伝達漏れ）。
: > "$TMP/argv.log"
: > "$TMP/stdin.log"
set +e
run_isolated PATH="$STUB:$PATH" CODEX_HOME="$TMP/codex-home" \
  bash "$ADAPTERS_DIR/codex-cli-adapter.sh" "$PERSPECTIVE" "$TMP/out-implement.md" \
  --base develop --timeout 30 --task-type implement --description "fixture" \
  --staging-dir "$STAGING_FIXTURE" \
  >"$TMP/adapter-implement.log" 2>&1
ADAPTER_RC=$?
set -e
if [ "$ADAPTER_RC" -ne 0 ]; then
  bad "codex アダプタ(implement)が非 0 終了した (rc=$ADAPTER_RC)"
  tail -20 "$TMP/adapter-implement.log" | sed 's/^/    | /' >&2
elif [ ! -s "$TMP/argv.log" ]; then
  bad "codex(implement) の argv が記録されていない（stub 未経由の疑い）"
elif grep -qF "$STAGING_FIXTURE" "$TMP/stdin.log"; then
  ok "codex の実入力（stdin）に staging の実パスが届いている"
else
  bad "codex の実入力に staging パスが無い（--staging-dir の伝達漏れ）"
  head -10 "$TMP/stdin.log" | sed 's/^/    | /' >&2
fi

echo "== orchestrator 経由での staging 伝達（Issue #392 AC1） =="

# build_prompt / アダプタ単体ではなく、multi-agent.sh を実起動して
# 「orchestrator が staging を解決 → 実在させる → アダプタへ渡す → プロンプトに載る
# → エージェントが書いた成果物が実行後も残っている」を通しで見る。
# --dry-run ではアダプタが起動しないので、ここは実行モードで回す（stub CLI のみ）。
#
# 出力先は**既定**（--output-dir 無指定 = ${REPO_ROOT}/.implement-results）にする。
# 利用者が実際に通る経路であり、CLI の CWD を repository root へ固定する側も見る。
# repository root 外を指す経路は下の fail-loud ケースで別に見る。
#
# 注意: この実行は codex-cli が feature-implementation を担当できる前提に依存する
# （scripts/agent-config.yaml の観点割り当て）。ラインナップを変えるとここが赤くなる
# が、argv.log が空になる形で fail-loud に落ちるので沈黙はしない。
ORCH_OUT="$REPO/.implement-results"
ORCH_STAGING="$ORCH_OUT/codex-cli/files/feature-implementation"

# 前回実行の残骸を仕込む。clear_planned_outputs が staging も掃除することを確かめる
# （消し漏らすと前回の生成物が今回の成果として読まれる）。
mkdir -p "$ORCH_STAGING"
printf 'stale from a previous run\n' > "$ORCH_STAGING/stale.txt"

# プランに含まれない CLI の staging も仕込む。掃除は実行プランに閉じている（意図的）
# ことを固定し、「全部消える」という誤った期待がドキュメントへ再流入するのを防ぐ。
UNPLANNED_STAGING="$ORCH_OUT/grok-cli/files/migration"
mkdir -p "$UNPLANNED_STAGING"
printf 'from an earlier run\n' > "$UNPLANNED_STAGING/old.txt"

# 本物のエージェントのように staging へ書き込む stub。プロンプト本文は Issue #712
# 以降 stdin で届くため、stdin を丸ごと記録してから実パスを読み取る（argv も記録し、
# 本文が argv へ戻る退行を上の負の検査で見張れるようにする）。
cat > "$STUB/codex" <<SH
#!/usr/bin/env bash
${CODEX_HELP_ARM}
for a in "\$@"; do printf '%s\n' "\$a" >> "$TMP/argv.log"; done
cat >> "$TMP/stdin.log"
pwd -P > "$TMP/cli-cwd.log"
sd="\$(awk '/ONLY under this staging directory/{getline; gsub(/^[ \t]+|[ \t]+\$/,""); print; exit}' "$TMP/stdin.log")"
if [ -n "\$sd" ] && [ -d "\$sd" ]; then printf 'generated\n' > "\$sd/gen.ts"; fi
echo "stub implement output"
SH
chmod +x "$STUB/codex"

: > "$TMP/argv.log"
: > "$TMP/stdin.log"
set +e
( cd "$REPO" && run_isolated PATH="$STUB:$PATH" CODEX_HOME="$TMP/codex-home" \
  bash "$PLUGIN_ROOT/scripts/multi-agent.sh" \
  --task implement --cli codex-cli --perspective feature-implementation \
  --description "fixture implement task" --base develop --timeout 30 \
  ) >"$TMP/orch.log" 2>&1
ORCH_RC=$?
set -e

if [ "$ORCH_RC" -ne 0 ]; then
  bad "multi-agent.sh --task implement が非 0 終了した (rc=$ORCH_RC)"
  tail -25 "$TMP/orch.log" | sed 's/^/    | /' >&2
  # 実行が死んだ状態で後続を回すと、テスト自身が作ったディレクトリを根拠に
  # 「orchestrator が実在させた」等の空虚な ✓ が並ぶ。rc で門を閉じる。
  bad "orchestrator が完走しなかったため、以降の staging 検査は未検証"
else
  ok "multi-agent.sh --task implement が完走した"

  if [ -d "$ORCH_STAGING" ]; then
    ok "orchestrator が staging ディレクトリを実在させる（エージェントに mkdir させない）"
  else
    bad "staging ディレクトリが作られていない: $ORCH_STAGING"
  fi

  if [ -e "$ORCH_STAGING/stale.txt" ]; then
    bad "前回実行の staging 残骸が消えていない（今回の成果と誤読される）"
  else
    ok "前回実行の staging 残骸が実行前に掃除される"
  fi

  # 成果物の**生存**。パスが届く・ディレクトリが在る・stale が消える、を全部
  # 満たしても、実行後に staging を空にする実装なら生成物は消える（実測で
  # すり抜けた変異）。CLI が書いたファイルが残っていることを直接見る。
  if [ -f "$ORCH_STAGING/gen.ts" ]; then
    ok "CLI が staging へ書いた生成物が実行後も残っている"
  else
    bad "生成物が staging に残っていない（実行後に消されている疑い）: $ORCH_STAGING/gen.ts"
  fi

  if [ -f "$UNPLANNED_STAGING/old.txt" ]; then
    ok "プラン外 CLI の staging は掃除しない（掃除は実行プランに閉じる）"
  else
    bad "プラン外 CLI の staging まで消した（他の実行の成果物を巻き込む）"
  fi

  if [ ! -s "$TMP/argv.log" ]; then
    bad "orchestrator 経由の argv が記録されていない（stub 未経由の疑い）"
  elif grep -qF "$ORCH_STAGING" "$TMP/stdin.log"; then
    ok "orchestrator が解決した staging の実パスがプロンプトへ届いている"
  else
    bad "プロンプトに staging の実パスが無い（orchestrator → アダプタの伝達漏れ）"
    tail -25 "$TMP/orch.log" | sed 's/^/    | /' >&2
  fi

  # レポートは staging を実測して案内する。パスの literal がレポートにも載ることで、
  # staging_dir_for のレイアウトを変えたときレポート文言の追随漏れが赤くなる。
  ORCH_REPORT="$ORCH_OUT/integrated-report.md"
  if [ -f "$ORCH_REPORT" ]; then
    expect_contains "レポートが staging の実パスを案内する" "$(cat "$ORCH_REPORT")" "$ORCH_STAGING"
    expect_contains "レポートが実測ファイル数を出す" "$(cat "$ORCH_REPORT")" "1 file(s)"
  else
    bad "統合レポートが生成されていない: $ORCH_REPORT"
  fi

  if [ "$(cat "$TMP/cli-cwd.log" 2>/dev/null || true)" = "$(cd "$REPO" && pwd -P)" ]; then
    ok "CLI の CWD（sandbox root）を repository root に固定する"
  else
    bad "CLI の CWD が repository root と一致しない"
  fi
fi

echo "== repository root 外の output-dir を実行前に拒否 =="

# repository root 外を --output-dir で指したときは、書けない staging をプロンプトへ
# 載せず、CLI 起動前に fail-loud で止める。
: > "$TMP/argv.log"
: > "$TMP/stdin.log"
set +e
( cd "$REPO" && run_isolated PATH="$STUB:$PATH" CODEX_HOME="$TMP/codex-home" \
  bash "$PLUGIN_ROOT/scripts/multi-agent.sh" \
  --task implement --cli codex-cli --perspective feature-implementation \
  --description "fixture implement task" --base develop --timeout 30 \
  --output-dir "$TMP/outside-out" \
  ) >"$TMP/orch-outside.log" 2>&1
ORCH_OUTSIDE_RC=$?
set -e
if [ "$ORCH_OUTSIDE_RC" -ne 0 ]; then
  ok "repository root 外の output-dir を非 0 で拒否する (rc=$ORCH_OUTSIDE_RC)"
else
  bad "repository root 外の output-dir が実行された"
fi
expect_contains "拒否理由が sandbox root と output-dir の境界を名指しする" \
  "$(cat "$TMP/orch-outside.log")" "outside the CLI sandbox root"
if [ ! -s "$TMP/argv.log" ]; then
  ok "境界外 output-dir では CLI を起動しない"
else
  bad "境界外 output-dir を拒否した後に CLI を起動した"
fi

echo "== サブディレクトリ起動でも repository root を sandbox root にする =="
mkdir -p "$REPO/sub/dir"
: > "$TMP/argv.log"
: > "$TMP/stdin.log"
set +e
( cd "$REPO/sub/dir" && run_isolated PATH="$STUB:$PATH" CODEX_HOME="$TMP/codex-home" \
  bash "$PLUGIN_ROOT/scripts/multi-agent.sh" \
  --task implement --cli codex-cli --perspective feature-implementation \
  --description "fixture implement from subdir" --base develop --timeout 30 \
  ) >"$TMP/orch-subdir.log" 2>&1
ORCH_SUBDIR_RC=$?
set -e
if [ "$ORCH_SUBDIR_RC" -eq 0 ]; then
  ok "サブディレクトリからの implement が完走する"
else
  bad "サブディレクトリからの implement が非 0 終了した (rc=$ORCH_SUBDIR_RC)"
fi
if [ "$(cat "$TMP/cli-cwd.log" 2>/dev/null || true)" = "$(cd "$REPO" && pwd -P)" ]; then
  ok "サブディレクトリ起動でも CLI の CWD は repository root"
else
  bad "サブディレクトリ起動で CLI の CWD が呼び出し元 subdir のまま"
fi

echo "== 相対 --output-dir の絶対化 =="

# --output-dir は値を無加工で受けるため、絶対化しないとプロンプトが
# "(absolute path)" と断言しながら相対パスを渡す。受け取ったエージェントは
# 自分の CWD = 作業ツリー基準で解決するので、本 Issue が塞ごうとした汚染に戻る。
: > "$TMP/argv.log"
: > "$TMP/stdin.log"
set +e
( cd "$REPO" && run_isolated PATH="$STUB:$PATH" CODEX_HOME="$TMP/codex-home" \
  bash "$PLUGIN_ROOT/scripts/multi-agent.sh" \
  --task implement --cli codex-cli --perspective feature-implementation \
  --description "fixture implement task" --base develop --timeout 30 \
  --output-dir rel-out \
  ) >"$TMP/orch-rel.log" 2>&1
ORCH_REL_RC=$?
set -e
if [ "$ORCH_REL_RC" -ne 0 ]; then
  bad "相対 --output-dir の実行が非 0 終了した (rc=$ORCH_REL_RC)"
  tail -25 "$TMP/orch-rel.log" | sed 's/^/    | /' >&2
elif [ ! -s "$TMP/argv.log" ]; then
  bad "相対 --output-dir 実行の argv が記録されていない（stub 未経由の疑い）"
elif grep -qF "$REPO/rel-out/codex-cli/files/feature-implementation" "$TMP/stdin.log"; then
  ok "相対 --output-dir でもプロンプトには絶対パスが載る"
else
  bad "相対 --output-dir が絶対化されずプロンプトへ渡っている"
  # 診断でパイプを死なせない。`grep | head` は head が先に終わると grep が SIGPIPE で
  # 死に、pipefail + set -e が **失敗を報告している最中に** suite を打ち切る（不一致で
  # grep が rc=1 になる経路も同じ）。一度ファイルへ落としてから読む。
  { grep -n 'staging directory' -A 2 "$TMP/stdin.log" || true; } > "$TMP/relout-diag.log"
  head -6 "$TMP/relout-diag.log" | sed 's/^/    | /' >&2
fi

echo "== 前回の staging を消せないときの fail-loud =="

# rm の rc を捨てると、消せなかった前回の生成物が「今回の成果」としてレポートに
# 案内されたまま実行が進む。staging 自体を書き込み不可にすると、中の残骸を
# unlink できず rm が失敗する（親が書けても子は消せない）。
RMFAIL_OUT="$REPO/.rmfail-out"
RMFAIL_STAGING="$RMFAIL_OUT/codex-cli/files/feature-implementation"
mkdir -p "$RMFAIL_STAGING"
printf 'stale\n' > "$RMFAIL_STAGING/stale.txt"
chmod 555 "$RMFAIL_STAGING"
if [ -w "$RMFAIL_STAGING" ]; then
  echo "  ○ skip: このユーザーでは 555 のディレクトリにも書けるため rm 失敗検査をスキップ"
else
  set +e
  ( cd "$REPO" && run_isolated PATH="$STUB:$PATH" CODEX_HOME="$TMP/codex-home" \
    bash "$PLUGIN_ROOT/scripts/multi-agent.sh" \
    --task implement --cli codex-cli --perspective feature-implementation \
    --description "fixture implement task" --base develop --timeout 30 \
    --output-dir "$RMFAIL_OUT" \
    ) >"$TMP/orch-rmfail.log" 2>&1
  RMFAIL_RC=$?
  set -e
  if [ "$RMFAIL_RC" -eq 0 ]; then
    bad "前回の staging を消せないのに実行が成功扱いになった"
  else
    ok "前回の staging を消せない実行を非 0 で終える (rc=$RMFAIL_RC)"
  fi
  # 「別の理由でたまたま落ちた」を合格にしない。真因を名指ししていることまで見る。
  expect_contains "掃除失敗を真因として名指しする" \
    "$(cat "$TMP/orch-rmfail.log")" "cannot clear staging dir"
  expect_contains "誤読の危険を明示する" \
    "$(cat "$TMP/orch-rmfail.log")" "would be reported as this run's output"
fi
chmod 755 "$RMFAIL_STAGING"

echo "== symlink 経由の再帰削除を拒否する =="

# パスの**途中**が symlink だと、rm -rf が出力先の外を消しに行く。
# <cli>/files が外部を指す symlink のとき、rm -rf <cli>/files/<persp> は
# その外部側を消す。OUTPUT_DIR を物理化しても文字列 prefix 判定では見抜けない。
SYM_OUT="$REPO/.sym-out"
SYM_VICTIM="$TMP/sym-victim"
mkdir -p "$SYM_OUT/codex-cli" "$SYM_VICTIM/feature-implementation"
printf 'must survive\n' > "$SYM_VICTIM/feature-implementation/precious.txt"
ln -s "$SYM_VICTIM" "$SYM_OUT/codex-cli/files"

set +e
( cd "$REPO" && run_isolated PATH="$STUB:$PATH" CODEX_HOME="$TMP/codex-home" \
  bash "$PLUGIN_ROOT/scripts/multi-agent.sh" \
  --task implement --cli codex-cli --perspective feature-implementation \
  --description "fixture implement task" --base develop --timeout 30 \
  --output-dir "$SYM_OUT" \
  ) >"$TMP/orch-sym.log" 2>&1
SYM_RC=$?
set -e

if [ -f "$SYM_VICTIM/feature-implementation/precious.txt" ]; then
  ok "出力先の外にあるファイルを消さない（symlink をたどった再帰削除をしない）"
else
  bad "symlink 経由で出力先の外のファイルを消した"
fi
if [ "$SYM_RC" -eq 0 ]; then
  bad "symlink 脱出を検出したのに実行が成功扱いになった"
else
  ok "symlink 脱出を検出して非 0 で終える (rc=$SYM_RC)"
fi
# 真因の名指しは「symlink だから触らない」+「その先は出力先の外」の 2 段。Issue #1120 で
# 判定が配下判定から resolve_expected_dir（解決後 == 渡したパス）へ移ったため、前者が
# 一次の理由になった。片方だけを見ると、判定が緩んだ側の退行を素通しする。
expect_contains "symlink を追わないことを真因として名指しする" \
  "$(cat "$TMP/orch-sym.log")" "is a symlink to another location"
expect_contains "指し先が出力先の外であることも示す" \
  "$(cat "$TMP/orch-sym.log")" "reach outside the output dir"
# 準備段階で落ちた実行はレポートを出さない。出すと、掃除できなかった前回の
# 成果物を「今回の結果」として並べたうえで "Done! View results" と案内する。
if [ -f "$SYM_OUT/integrated-report.md" ]; then
  bad "準備段階で落ちたのに統合レポートを生成した（前回の成果物を今回分として案内する）"
else
  ok "準備段階で落ちた実行はレポートを生成しない"
fi
rm -f "$SYM_OUT/codex-cli/files"

echo "== 出力先の**内側**を指す symlink も追わない（Issue #1120） =="

# 旧実装は「解決先が OUTPUT_DIR 配下なら消す」という配下判定だったので、内向きの
# symlink は判定を通り、指し先（別 CLI の staging 成果一式）が丸ごと消えた。
# 指し先が出力先の内か外かは、消してよいかどうかと関係がない。
IN_OUT="$REPO/.inward-out"
IN_VICTIM="$IN_OUT/claude-code/files/feature-implementation"
mkdir -p "$IN_OUT/codex-cli" "$IN_VICTIM"
printf 'must survive\n' > "$IN_VICTIM/precious.txt"
ln -s ../claude-code/files "$IN_OUT/codex-cli/files"

set +e
( cd "$REPO" && run_isolated PATH="$STUB:$PATH" CODEX_HOME="$TMP/codex-home" \
  bash "$PLUGIN_ROOT/scripts/multi-agent.sh" \
  --task implement --cli codex-cli --perspective feature-implementation \
  --description "fixture implement task" --base develop --timeout 30 \
  --output-dir "$IN_OUT" \
  ) >"$TMP/orch-inward.log" 2>&1
IN_RC=$?
set -e

if [ -f "$IN_VICTIM/precious.txt" ]; then
  ok "出力先の内側にある別 CLI の staging 成果を消さない"
else
  bad "内向き symlink を追って別 CLI の staging 成果を消した"
fi
if [ "$IN_RC" -eq 0 ]; then
  bad "内向き symlink を検出したのに実行が成功扱いになった"
else
  ok "内向き symlink を検出して非 0 で終える (rc=$IN_RC)"
fi
expect_contains "内向きでも symlink を真因として名指しする" \
  "$(cat "$TMP/orch-inward.log")" "is a symlink to another location"

echo "== 観点ディレクトリが未作成でも中間 symlink を素通ししない（Issue #1120） =="

# leaf（<cli>/files/<perspective>）が未作成の回は -L / -d / -e がすべて偽になる。
# leaf の状態だけを見る実装だと検査を素通りし、後続の mkdir -p がリンク先へ staging
# を作って書き込む — 初回実行がまさにこの形（実測で再現）。親を先に検査する。
NEW_OUT="$REPO/.inward-new-out"
NEW_VICTIM="$REPO/.inward-new-victim"
mkdir -p "$NEW_OUT/codex-cli" "$NEW_VICTIM"
printf 'must survive\n' > "$NEW_VICTIM/precious.txt"
ln -s "$NEW_VICTIM" "$NEW_OUT/codex-cli/files"   # leaf は作らない

set +e
( cd "$REPO" && run_isolated PATH="$STUB:$PATH" CODEX_HOME="$TMP/codex-home" \
  bash "$PLUGIN_ROOT/scripts/multi-agent.sh" \
  --task implement --cli codex-cli --perspective feature-implementation \
  --description "fixture implement task" --base develop --timeout 30 \
  --output-dir "$NEW_OUT" \
  ) >"$TMP/orch-inward-new.log" 2>&1
NEW_RC=$?
set -e

if [ ! -e "$NEW_VICTIM/feature-implementation" ] \
  && [ -f "$NEW_VICTIM/precious.txt" ]; then
  ok "leaf 未作成でもリンク先へ staging を作らない"
else
  bad "leaf 未作成の回に中間 symlink を追ってリンク先へ staging を作った"
  ls -la "$NEW_VICTIM" | sed 's/^/    /' >&2
fi
if [ "$NEW_RC" -eq 0 ]; then
  bad "leaf 未作成の中間 symlink を検出したのに実行が成功扱いになった"
else
  ok "leaf 未作成でも中間 symlink を検出して非 0 で終える (rc=$NEW_RC)"
fi

echo "== 親も末端も symlink の組合せ（Issue #1120） =="

# 親（<cli>/files）が外を指し、末端（<persp>）も symlink というケース。leaf の
# 種別だけを見る実装では -L 分岐が先に当たり、親を一度も検査しないまま
# 出力先の外の symlink を unlink して rc=0 で続行する（実測で再現した経路）。
BOTH_OUT="$REPO/.both-sym-out"
BOTH_VICTIM="$REPO/.both-sym-victim"
BOTH_PRECIOUS="$REPO/.both-sym-precious"
mkdir -p "$BOTH_OUT/codex-cli" "$BOTH_VICTIM" "$BOTH_PRECIOUS"
printf 'must survive\n' > "$BOTH_PRECIOUS/precious.txt"
ln -s "$BOTH_VICTIM" "$BOTH_OUT/codex-cli/files"
ln -s "$BOTH_PRECIOUS" "$BOTH_VICTIM/feature-implementation"

set +e
( cd "$REPO" && run_isolated PATH="$STUB:$PATH" CODEX_HOME="$TMP/codex-home" \
  bash "$PLUGIN_ROOT/scripts/multi-agent.sh" \
  --task implement --cli codex-cli --perspective feature-implementation \
  --description "fixture implement task" --base develop --timeout 30 \
  --output-dir "$BOTH_OUT" \
  ) >"$TMP/orch-both-sym.log" 2>&1
BOTH_RC=$?
set -e

if [ -L "$BOTH_VICTIM/feature-implementation" ] && [ -f "$BOTH_PRECIOUS/precious.txt" ]; then
  ok "親も末端も symlink の組合せで、出力先の外の symlink を unlink しない"
else
  bad "親を検査せず末端 symlink を unlink した（出力先の外へ手を出している）"
  ls -la "$BOTH_VICTIM" | sed 's/^/    /' >&2
fi
if [ "$BOTH_RC" -eq 0 ]; then
  bad "親も末端も symlink の組合せを検出したのに実行が成功扱いになった"
else
  ok "親も末端も symlink の組合せを検出して非 0 で終える (rc=$BOTH_RC)"
fi
# 外向きの説明（出力先の外へ届く）をそのまま流用すると、内向きでは端的に嘘になる。
expect_contains "内向き固有の被害（別タスクの staging を消す）を述べる" \
  "$(cat "$TMP/orch-inward.log")" "erase another task's staging output"
if grep -qF "reach outside the output dir" "$TMP/orch-inward.log"; then
  bad "内向きなのに「出力先の外へ届く」と説明している"
else
  ok "内向きに外向きの説明を流用しない"
fi
rm -f "$IN_OUT/codex-cli/files"

echo "== staging パス自体が symlink ならリンクだけを外して続行する =="

# 途中のコンポーネントと違い、リンク末端そのものは実体を作り直せば実行を続けられる。
# clear_quarantine_dir（previous/ が symlink のとき）と同じ扱いに揃える。
LEAF_OUT="$REPO/.leaf-out"
LEAF_VICTIM="$LEAF_OUT/claude-code/files/feature-implementation"
mkdir -p "$LEAF_OUT/codex-cli/files" "$LEAF_VICTIM"
printf 'must survive\n' > "$LEAF_VICTIM/precious.txt"
ln -s ../../claude-code/files/feature-implementation \
  "$LEAF_OUT/codex-cli/files/feature-implementation"

set +e
( cd "$REPO" && run_isolated PATH="$STUB:$PATH" CODEX_HOME="$TMP/codex-home" \
  bash "$PLUGIN_ROOT/scripts/multi-agent.sh" \
  --task implement --cli codex-cli --perspective feature-implementation \
  --description "fixture implement task" --base develop --timeout 30 \
  --output-dir "$LEAF_OUT" \
  ) >"$TMP/orch-leaf.log" 2>&1
LEAF_RC=$?
set -e

if [ -f "$LEAF_VICTIM/precious.txt" ]; then
  ok "リンク末端の指し先を消さない"
else
  bad "staging パス自体の symlink を追って指し先を消した"
fi
if [ "$LEAF_RC" -eq 0 ]; then
  ok "リンクを外して実行を続ける (rc=0)"
else
  bad "リンクを外せば続行できるのに実行が失敗した (rc=$LEAF_RC)"
  tail -25 "$TMP/orch-leaf.log" | sed 's/^/    | /' >&2
fi
if [ -d "$LEAF_OUT/codex-cli/files/feature-implementation" ] \
   && [ ! -L "$LEAF_OUT/codex-cli/files/feature-implementation" ]; then
  ok "symlink を外して実体の staging を作り直す"
else
  bad "symlink 除去後の staging が実ディレクトリになっていない"
fi
expect_contains "リンクを外したことを名乗る" \
  "$(cat "$TMP/orch-leaf.log")" "Removed a symlink at the staging path"

echo "== 出力モードの排他 =="

set +e
# gen_prompt を使う（同じ引数で両モードを指定できる）。ここで build_prompt を
# もう一度べた書きすると、gen_prompt の環境分離（DIFF_FILE 等の unset）を持たない
# 2 つ目の直呼び経路が生まれ、ホスト環境の値でこのケースだけが揺れる。
BOTH_ERR="$( (gen_prompt implement "$STAGING_FIXTURE" true) 2>&1 >/dev/null )"
BOTH_RC=$?
set -e
if [ "$BOTH_RC" -ne 0 ]; then
  ok "--staging-dir と --inline-output の同時指定を非 0 で拒否する (rc=$BOTH_RC)"
else
  bad "出力モードの同時指定が黙って通った（片方が静かに優先される）"
fi
expect_contains "排他である理由を出す" "$BOTH_ERR" "mutually exclusive"

echo "== staging を作れないときの fail-loud =="

# 親ディレクトリが書けない状態は mkdir -p が失敗する reachable な経路。
# ここを warn-and-continue に退行させると、staging 無しのまま実行が進む。
MKFAIL_OUT="$REPO/.mkfail-out"
mkdir -p "$MKFAIL_OUT/codex-cli"
chmod 555 "$MKFAIL_OUT/codex-cli"
if [ -w "$MKFAIL_OUT/codex-cli" ]; then
  echo "  ○ skip: このユーザーでは 555 のディレクトリにも書けるため mkdir 失敗検査をスキップ"
else
  set +e
  ( cd "$REPO" && run_isolated PATH="$STUB:$PATH" CODEX_HOME="$TMP/codex-home" \
    bash "$PLUGIN_ROOT/scripts/multi-agent.sh" \
    --task implement --cli codex-cli --perspective feature-implementation \
    --description "fixture implement task" --base develop --timeout 30 \
    --output-dir "$MKFAIL_OUT" \
    ) >"$TMP/orch-mkfail.log" 2>&1
  MKFAIL_RC=$?
  set -e
  if [ "$MKFAIL_RC" -eq 0 ]; then
    bad "staging を作れないのに実行が成功扱いになった"
  else
    ok "staging を作れない実行を非 0 で終える (rc=$MKFAIL_RC)"
  fi
  expect_contains "staging 作成失敗の理由と対処が出る" \
    "$(cat "$TMP/orch-mkfail.log")" "Cannot create staging dir"
fi
chmod 755 "$MKFAIL_OUT/codex-cli"

echo "== 同一 output-dir の並行実行を lock で拒否（Issue #402） =="

LOCK_OUT="$REPO/.shared-output"
LOCK_STAGING="$LOCK_OUT/codex-cli/files/feature-implementation"
LOCK_STARTED="$TMP/lock-holder-started"
LOCK_RELEASE="$TMP/lock-holder-release"
LOCK_CALLS="$TMP/lock-holder-calls"
: >"$LOCK_CALLS"
cat >"$STUB/codex" <<SH
#!/usr/bin/env bash
${CODEX_HELP_ARM}
echo "start \$\$" >> "$LOCK_CALLS"
: > "$LOCK_STARTED"
deadline=\$((SECONDS + 10))
while [ ! -f "$LOCK_RELEASE" ]; do
  if [ "\$SECONDS" -ge "\$deadline" ]; then
    echo "stub: timed out waiting for release" >&2
    exit 1
  fi
  sleep 0.1
done
echo "stub implement output"
SH
chmod +x "$STUB/codex"

( cd "$REPO" && run_isolated PATH="$STUB:$PATH" CODEX_HOME="$TMP/codex-home" \
  bash "$PLUGIN_ROOT/scripts/multi-agent.sh" \
  --task implement --cli codex-cli --perspective feature-implementation \
  --description "first concurrent fixture" --base develop --timeout 30 \
  --output-dir "$LOCK_OUT" \
  ) >"$TMP/orch-lock-first.log" 2>&1 &
LOCK_FIRST_PID=$!

LOCK_WAIT=0
while [ ! -f "$LOCK_STARTED" ] && [ "$LOCK_WAIT" -lt 100 ]; do
  sleep 0.1
  LOCK_WAIT=$((LOCK_WAIT + 1))
done
if [ ! -f "$LOCK_STARTED" ]; then
  bad "先行 run が lock 保持中の CLI 実行へ到達しない"
else
  mkdir -p "$LOCK_STAGING"
  printf 'must survive competing run\n' >"$LOCK_STAGING/sentinel.txt"

  set +e
  ( cd "$REPO" && run_isolated PATH="$STUB:$PATH" CODEX_HOME="$TMP/codex-home" \
    bash "$PLUGIN_ROOT/scripts/multi-agent.sh" \
    --task implement --cli codex-cli --perspective feature-implementation \
    --description "second concurrent fixture" --base develop --timeout 30 \
    --output-dir "$LOCK_OUT" \
    ) >"$TMP/orch-lock-second.log" 2>&1
  LOCK_SECOND_RC=$?
  set -e

  if [ "$LOCK_SECOND_RC" -ne 0 ]; then
    ok "同じ output-dir の後発 run をタスク起動前に非 0 で拒否する (rc=$LOCK_SECOND_RC)"
  else
    bad "同じ output-dir の後発 run が実行され、成果物競合を許した"
  fi
  expect_contains "競合した output-dir と lock path を名指しする" \
    "$(cat "$TMP/orch-lock-second.log")" ".multi-agent-run.lock"
  if [ -f "$LOCK_STAGING/sentinel.txt" ]; then
    ok "後発 run が先行 run の staging 成果物を消さない"
  else
    bad "後発 run の実行前クリアが先行 run の staging 成果物を削除した"
  fi
  if [ "$(wc -l <"$LOCK_CALLS" | tr -d ' ')" -eq 1 ]; then
    ok "競合拒否された後発 run は CLI を起動しない"
  else
    bad "競合拒否された後発 run も CLI を起動した"
  fi
fi

: >"$LOCK_RELEASE"
set +e
wait "$LOCK_FIRST_PID"
LOCK_FIRST_RC=$?
set -e
if [ "$LOCK_FIRST_RC" -eq 0 ]; then
  ok "先行 run は lock 保持後も正常完了する"
else
  bad "先行 run が非 0 終了した (rc=$LOCK_FIRST_RC)"
  tail -25 "$TMP/orch-lock-first.log" | sed 's/^/    | /' >&2
fi
if [ ! -e "$LOCK_OUT/.multi-agent-run.lock" ]; then
  ok "完了時に output-dir lock を解放する"
else
  bad "完了後も output-dir lock が残っている"
fi

echo "== 全 4 アダプタのプロンプト受け渡し形（Issue #712） =="

# fixture リポジトリの diff を約 240KB へ太らせる（この suite の後続検査は無いので
# ここからの変異は安全）。プロンプト本文が argv から stdin / prompt-file へ移った
# ことに加え、「argv の総量がプロンプト規模と独立」という Issue #712 の実性質を
# 実寸で固定する（Windows / Git Bash の CreateProcess ~32KB 上限が診る量は argv）。
awk 'BEGIN { for (i = 0; i < 4000; i++) printf "large-diff-line-%06d-xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx\n", i }' > "$REPO/big.txt"
git -C "$REPO" add big.txt
git -C "$REPO" commit -qm "large diff fixture"

DELIV="$TMP/deliv"
DELIV_BIN="$DELIV/bin"
mkdir -p "$DELIV_BIN" "$TMP/grok-home"

BOUNDARY_MARKER='## Execution Boundary (non-negotiable)'

# stub: argv を 1 行 1 引数で、stdin を丸ごと記録する。--prompt-file の値がある
# 場合はその実体も stdin ログへ写す（アダプタは実行後にファイルを消すため、
# 実行中にしか読めない）。
for cli in claude codex copilot grok; do
  cat > "$DELIV_BIN/$cli" <<SH
#!/usr/bin/env bash
prev=""
pf=""
for a in "\$@"; do
  printf '%s\n' "\$a" >> "$DELIV/${cli}-argv.log"
  if [ "\$prev" = "--prompt-file" ]; then pf="\$a"; fi
  prev="\$a"
done
cat >> "$DELIV/${cli}-stdin.log"
if [ -n "\$pf" ] && [ -f "\$pf" ]; then cat "\$pf" >> "$DELIV/${cli}-stdin.log"; fi
echo "- Suggestion: stub review output"
SH
  chmod +x "$DELIV_BIN/$cli"
done

deliver_adapter() { # $1: cli 名 / $2: adapter ファイル名
  local cli="$1" adapter="$2" rc=0 argv_bytes stdin_bytes
  : > "$DELIV/${cli}-argv.log"
  : > "$DELIV/${cli}-stdin.log"
  set +e
  ( cd "$REPO" && run_isolated PATH="$DELIV_BIN:$PATH" CODEX_HOME="$TMP/codex-home" GROK_HOME="$TMP/grok-home" \
      bash "$ADAPTERS_DIR/$adapter" "$PERSPECTIVE" "$DELIV/out-${cli}.md" \
      --base develop --timeout 30 --task-type review --description "fixture" \
    ) >"$DELIV/${cli}.log" 2>&1
  rc=$?
  set -e
  # grok はサンドボックス適用の肯定確認が stub では成立せず非 0 で終わりうる
  # （adapter-sandbox-contract と同じ扱い）。ここで見るのは受け渡し形なので rc は
  # 条件にせず、stub 到達（argv 非空）だけを前提条件にする。
  if [ ! -s "$DELIV/${cli}-argv.log" ]; then
    bad "${cli}: stub が起動していない（受け渡し形の検査が成立しない） (rc=${rc})"
    tail -5 "$DELIV/${cli}.log" | sed 's/^/    | /' >&2
    return 0
  fi
  if grep -qF "$BOUNDARY_MARKER" "$DELIV/${cli}-argv.log"; then
    bad "${cli}: プロンプト本文が argv に乗っている（Issue #712 の退行 — Windows で exit 126 に戻る）"
  else
    ok "${cli}: プロンプト本文は argv に乗らない"
  fi
  if grep -qF "$BOUNDARY_MARKER" "$DELIV/${cli}-stdin.log"; then
    ok "${cli}: プロンプト本文が stdin / prompt-file 経由で CLI へ届く"
  else
    bad "${cli}: プロンプト本文が CLI へ届いていない"
    tail -5 "$DELIV/${cli}.log" | sed 's/^/    | /' >&2
  fi
  argv_bytes="$(wc -c < "$DELIV/${cli}-argv.log" | tr -d ' ')"
  stdin_bytes="$(wc -c < "$DELIV/${cli}-stdin.log" | tr -d ' ')"
  if [ "$argv_bytes" -lt 8192 ] && [ "$stdin_bytes" -gt 200000 ]; then
    ok "${cli}: argv ${argv_bytes}B < 8KB / 本文 ${stdin_bytes}B > 200KB（argv がプロンプト規模と独立）"
  else
    bad "${cli}: argv=${argv_bytes}B / 本文=${stdin_bytes}B が期待レンジ外（argv 肥大 or 本文欠落）"
  fi
}

deliver_adapter claude claude-code-adapter.sh
deliver_adapter codex codex-cli-adapter.sh
deliver_adapter copilot copilot-cli-adapter.sh
deliver_adapter grok grok-cli-adapter.sh

# CLI 固有の受け渡し形。実測で確定した契約が編集で崩れると、Windows の exit 126 か
# 「stdin 無視で誤ったプロンプトに答える」（copilot の非空 -p）へ戻る。
if awk 'prev == "-p" && $0 == "" { found = 1 } { prev = $0 } END { exit found ? 0 : 1 }' "$DELIV/copilot-argv.log"; then
  ok "copilot: -p は空文字（1.0.80 実測: 非空にすると stdin が無視される）"
else
  bad "copilot: -p が空文字でない（stdin 無視＝プロンプト全損の退行リスク）"
fi
if grep -qxF -- "--prompt-file" "$DELIV/grok-argv.log"; then
  ok "grok: --prompt-file 経由（0.2.118 実測: stdin を読まない）"
else
  bad "grok: --prompt-file が argv に無い"
fi
if grep -qxF -- "-" "$DELIV/codex-argv.log" && grep -qxF "exec" "$DELIV/codex-argv.log"; then
  ok "codex: exec - の形（PROMPT を stdin から読む）"
else
  bad "codex: exec - の形でない"
fi
if grep -qxF -- "-p" "$DELIV/claude-argv.log"; then
  ok "claude: -p + stdin（位置引数プロンプトなし）"
else
  bad "claude: -p が argv に無い"
fi

echo "== 失敗経路のプロンプト一時ファイル掃除（EXIT trap） =="

# fail_cli_task は exit するため、成功パスの rm -f には失敗時に到達しない。
# CLI を失敗させ、プロンプトが残留しないことを実測する。
#
# **専用 TMPDIR を渡すだけでは検査にならない**（実測）。macOS の /usr/bin/mktemp は
# テンプレート無しで呼ぶと `$TMPDIR` を無視し、Darwin のユーザ専用 temp
# （confstr(_CS_DARWIN_USER_TEMP_DIR) = /var/folders/.../T）へ書く。
# アダプタの materialize_prompt_file は素の `mktemp` なので、差し替えた TMPDIR の
# 中を見る検査は**常に空のディレクトリを見ている**ことになり、掃除漏れがあっても緑になる。
# そこで「同じ env で mktemp が実際に使う場所」を 1 度測ってから、そこを見る。
# 直前に置いたセンチネルより新しいファイルだけを対象にして、無関係な残骸を拾わない。
#
# **走査は BOUNDARY_MARKER で引いてはいけない。** そこは Darwin ではユーザ共有の
# temp であり、境界宣言は全アダプタ・全 task-type のプロンプトへ必ず入るので、
# 並行して走っている**別プロセスの生きたプロンプト**にも一致する。一致すると
# (1) こちらは「EXIT trap の掃除漏れ」として偽陽性で赤くなり、(2) 下の rm -f が
# 相手の生きたファイルを消して、相手を run_with_timeout の TOCTOU 経由で
# 「CLI が 1 で落ちた」へ誤帰属させる。原因がこの suite にあるので相手側からは
# 追跡できない。そこで実行ごと・arm ごとに一意なトークンを perspective 本文へ埋め、
# それで引く。perspective 本文は build_prompt がどの task-type でもプロンプトへ載せる
# ので、残留の検出力は落ちない（変異 5 = _FF_PROMPT_FILE の登録外しで両 arm が赤くなる
# ことを実測済み）。触らないことの側は下の陰性対照 arm が針を持つ。

# resolve_real_tmpdir <env で渡す TMPDIR> — その env で mktemp が実際に書くディレクトリ
resolve_real_tmpdir() {
  local probe dir
  probe="$(TMPDIR="$1" mktemp 2>/dev/null)" || return 1
  [ -f "$probe" ] || return 1
  dir="$(dirname "$probe")"
  rm -f "$probe"
  printf '%s\n' "$dir"
}

# prompt_residue <センチネル> <トークン> <走査するディレクトリ...> — トークンを含む残留ファイル
prompt_residue() {
  local sentinel="$1" token="$2" d
  shift 2
  for d in "$@"; do
    [ -d "$d" ] || continue
    find "$d" -maxdepth 1 -type f -newer "$sentinel" \
      -exec grep -lF "$token" {} + 2>/dev/null
  done
  # 「見つからなかった」は非 0 で返さない。`$( )` 代入の rc が set -e に拾われて
  # スイートが**残留無しのときだけ**途中死する（実測）。
  return 0
}

# arm ごとに一意なトークンと、それを本文に持つ perspective fixture を作る。
# fixture 自体は $TMP 配下（走査は -maxdepth 1 なので届かない）に置く。
RESIDUE_SEQ=0
RESIDUE_TOKEN=""
RESIDUE_PERSPECTIVE=""
FF_DECOY_LIST=""
new_residue_fixture() {
  RESIDUE_SEQ=$((RESIDUE_SEQ + 1))
  RESIDUE_TOKEN="FF-PROMPT-RESIDUE-TOKEN-$$-${RESIDUE_SEQ}"
  RESIDUE_PERSPECTIVE="$TMP/perspective-residue-${RESIDUE_SEQ}.md"
  printf '%s\n' '# Fixture Perspective' 'PERSPECTIVE-CONTENT-MARKER' "$RESIDUE_TOKEN" \
    > "$RESIDUE_PERSPECTIVE"
}

# assert_residue_clean <ラベル> <トークン> <陰性対照の置き場所> <走査するディレクトリ...>
#
# 2 つの arm（CLI 失敗経路 / 起動前拒否経路）が同じ手順を踏むのでヘルパへ括る。
# 検査は 2 件:
#   1. 自分の実行のプロンプトが残っていないこと（本題）
#   2. 境界宣言だけを持ちトークンを持たないファイル＝**並行して走る別プロセスの
#      生きたプロンプト相当**に、走査も削除も及ばないこと（陰性対照）
# 2 は共有 temp を走査する以上ずっと必要な針で、マーカー走査へ戻す変異で赤くなる。
#
# 移行期の注意（Issue #896 のマージまで）: 陰性対照は境界宣言を含むファイルを共有
# temp 直下へ一時的に置く。**修正前**の本 suite（マーカーで引いて rm -f する形）が
# 並行して走っていると、それを掴んで消すので 2 の arm が赤くなる。原因は退行ではなく
# 相手側の旧コードなので、そのときは相手の実行が終わってから測り直すこと。
# 修正後どうしの並行実行はトークンが PID ごとに違うので衝突しない。
assert_residue_clean() {
  local label="$1" token="$2" real_tmp="$3"
  shift 3
  local decoy="" residue
  if [ -n "$real_tmp" ] && [ -d "$real_tmp" ]; then
    decoy="${real_tmp}/ff-prompt-guard-foreign.$$.${RESIDUE_SEQ}"
    FF_DECOY_LIST="${FF_DECOY_LIST}${decoy}
"
    printf '%s\n' "$BOUNDARY_MARKER" 'foreign live prompt of a concurrent run' > "$decoy"
  fi
  residue="$(prompt_residue "$SENTINEL" "$token" "$@")"
  if [ -n "$residue" ]; then
    bad "${label}でプロンプト一時ファイルが残留している（EXIT trap の掃除漏れ）"
    printf '%s\n' "$residue" | sed 's/^/    | /' >&2
    printf '%s\n' "$residue" | while IFS= read -r leaked; do rm -f "$leaked"; done
  else
    ok "${label}でもプロンプト一時ファイルが残留しない（EXIT trap が掃除。走査先: ${real_tmp}）"
  fi
  if [ -z "$decoy" ]; then
    bad "${label}: 陰性対照を置けなかった（他プロセスのファイルに触らないことを確かめていない）"
  elif [ -f "$decoy" ]; then
    ok "${label}: 境界宣言だけを持つ他プロセス相当のファイルには触らない（陰性対照が生存）"
    rm -f "$decoy"
  else
    bad "${label}: 走査が他プロセス相当のファイルを削除した（共有 temp の巻き添え — 並行実行中の別プロセスを壊す）"
  fi
}

FAILTMP="$TMP/failtmp"
FAILBIN="$DELIV/fail-bin"
mkdir -p "$FAILTMP" "$FAILBIN"
printf '%s\n' '#!/usr/bin/env bash' 'exit 1' > "$FAILBIN/codex"
chmod +x "$FAILBIN/codex"
REAL_TMP="$(resolve_real_tmpdir "$FAILTMP")" || REAL_TMP=""
if [ -z "$REAL_TMP" ]; then
  bad "mktemp が実際に使うディレクトリを特定できない（残留検査は成立しない）"
fi
new_residue_fixture
SENTINEL="$TMP/prompt-residue-sentinel"
: > "$SENTINEL"
set +e
( cd "$REPO" && run_isolated PATH="$FAILBIN:$PATH" CODEX_HOME="$TMP/codex-home" TMPDIR="$FAILTMP" \
    bash "$ADAPTERS_DIR/codex-cli-adapter.sh" "$RESIDUE_PERSPECTIVE" "$DELIV/out-fail.md" \
    --base develop --timeout 30 --task-type review --description "fixture" \
  ) >"$DELIV/fail.log" 2>&1
FAIL_RC=$?
set -e
if [ "$FAIL_RC" -ne 0 ]; then
  ok "CLI 失敗でアダプタは非 0 終了する (rc=${FAIL_RC})"
else
  bad "CLI が exit 1 なのにアダプタが 0 で完走した"
fi
assert_residue_clean "失敗経路" "$RESIDUE_TOKEN" "$REAL_TMP" "$FAILTMP" "$REAL_TMP"

# 上のケースは「CLI が起動して非 0 で落ちた」形。アダプタが**起動前に自分で止める**
# 形（orchestrator-error / rc=125）は別経路で、こちらも同じ掃除を受けなければ
# ならない。implement のプロンプトは diff 込みで数百 KB になりうるので、拒否する
# たびに残ると効いてくる。実例が codex の `-C/--cd` 能力確認（Issue #896）— 旧版の
# codex を検出して本番起動をやめる経路。
LEGACYTMP="$TMP/legacytmp"
LEGACYBIN="$DELIV/legacy-bin"
LEGACYSTAGE="$TMP/legacy-staging"
mkdir -p "$LEGACYTMP" "$LEGACYBIN" "$LEGACYSTAGE"
# `-C, --cd` を持たない codex の help を返す stub（本番起動には応答しない）。
{
  printf '%s\n' '#!/usr/bin/env bash'
  printf '%s\n' 'case " $* " in'
  printf '%s\n' '  *" exec --help "*) printf "  -s, --sandbox <SANDBOX_MODE>\n      --add-dir <DIR>\n"; exit 0 ;;'
  printf '%s\n' 'esac'
  printf '%s\n' 'echo "stub output"'
} > "$LEGACYBIN/codex"
chmod +x "$LEGACYBIN/codex"
LEGACY_REAL_TMP="$(resolve_real_tmpdir "$LEGACYTMP")" || LEGACY_REAL_TMP=""
if [ -z "$LEGACY_REAL_TMP" ]; then
  bad "mktemp が実際に使うディレクトリを特定できない（起動前拒否の残留検査は成立しない）"
fi
new_residue_fixture
: > "$SENTINEL"
set +e
( cd "$REPO" && run_isolated PATH="$LEGACYBIN:$PATH" CODEX_HOME="$TMP/codex-home" TMPDIR="$LEGACYTMP" \
    bash "$ADAPTERS_DIR/codex-cli-adapter.sh" "$RESIDUE_PERSPECTIVE" "$DELIV/out-legacy.md" \
    --base develop --timeout 30 --task-type implement --description "fixture" \
    --staging-dir "$LEGACYSTAGE" \
  ) >"$DELIV/legacy.log" 2>&1
LEGACY_RC=$?
set -e
if [ "$LEGACY_RC" -ne 0 ]; then
  ok "起動前の拒否（-C/--cd 非対応の codex）でアダプタは非 0 終了する (rc=${LEGACY_RC})"
else
  bad "-C/--cd を持たない codex なのにアダプタが 0 で完走した"
fi
assert_residue_clean "起動前の拒否経路" "$RESIDUE_TOKEN" "$LEGACY_REAL_TMP" "$LEGACYTMP" "$LEGACY_REAL_TMP"

echo
if [ "$FAIL" -gt 0 ]; then
  echo "✗ adapter-prompt-guard verify: $FAIL 件失敗" >&2
  # サマリーへ到達した失敗はセンチネルを立ててから終える。立てないと EXIT トラップの
  # 「サマリー前に中断しました」が正規の失敗にも付き、途中死と区別できなくなる。
  FF_REACHED_END=1
  exit 1
fi
echo "✓ adapter-prompt-guard verify: 全 $PASS 件 pass"
FF_REACHED_END=1
