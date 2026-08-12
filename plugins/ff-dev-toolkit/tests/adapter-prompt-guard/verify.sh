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
    echo "✗ adapter-prompt-guard: 最後まで到達しませんでした（途中で中断）" >&2
    exit 1
  fi
  exit "$_ff_rc"
}
trap _ff_exit_guard EXIT

PASS=0
FAIL=0
ok()  { echo "  ✓ $1"; PASS=$((PASS + 1)); }
bad() { echo "  ✗ $1" >&2; FAIL=$((FAIL + 1)); }

# --- diff を持つ一時リポジトリ（review の build_prompt は diff 必須） ---
REPO="$TMP/repo"
git init -q "$REPO"
cd "$REPO"
git config user.email "test@example.com"
git config user.name "adapter-prompt-guard-test"
git config commit.gpgsign false
git switch -q -c develop
echo base > app.txt
git add app.txt
git commit -qm "init"
git switch -q -c feature/x
printf 'base\nchange\n' > app.txt
git add app.txt
git commit -qm "change"

# --- perspective fixture（プロジェクト指示文の位置を示す一意マーカー入り） ---
PERSPECTIVE="$TMP/perspective.md"
printf '%s\n' '# Fixture Perspective' 'PERSPECTIVE-CONTENT-MARKER' > "$PERSPECTIVE"

# build_prompt をサブシェルで直接呼ぶ（multi-agent-timeout の D1/D2 と同じ経路）。
# $2 を省略すると STAGING_DIR 未設定 = orchestrator を経由しない直叩き実行の再現。
gen_prompt() { # $1: task_type / $2: staging_dir（省略可） / $3: inline_output（省略可） / stdout: プロンプト
  (
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
BOUNDARY_LINE="$(printf '%s\n' "$REVIEW_PROMPT" | awk 'index($0, "## Execution Boundary") { print NR; exit }')"
PERSPECTIVE_LINE="$(printf '%s\n' "$REVIEW_PROMPT" | awk 'index($0, "PERSPECTIVE-CONTENT-MARKER") { print NR; exit }')"
if [ -n "$BOUNDARY_LINE" ] && [ -n "$PERSPECTIVE_LINE" ] && [ "$BOUNDARY_LINE" -lt "$PERSPECTIVE_LINE" ]; then
  ok "review: 境界宣言が perspective より前にある（${BOUNDARY_LINE} 行目 < ${PERSPECTIVE_LINE} 行目）"
else
  bad "review: 境界宣言が perspective より前に無い（boundary=${BOUNDARY_LINE:-なし} perspective=${PERSPECTIVE_LINE:-なし}）"
fi

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
preamble_of() { # $1: プロンプト / stdout: 境界セクションより前の全行
  printf '%s\n' "$1" | awk 'index($0, "## Execution Boundary") { exit } { print }'
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

echo "== codex アダプタの実 argv への到達 =="

# stub codex は受け取った argv を 1 引数 1 行で記録する（exec "$prompt" の形で
# プロンプトが argv に乗ることを、アダプタの実起動経路で確かめる）。
STUB="$TMP/bin"
mkdir -p "$STUB"
cat > "$STUB/codex" <<SH
#!/usr/bin/env bash
for a in "\$@"; do printf '%s\n' "\$a" >> "$TMP/argv.log"; done
echo "stub review output"
SH
chmod +x "$STUB/codex"

: > "$TMP/argv.log"
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
elif grep -qF '## Execution Boundary (non-negotiable)' "$TMP/argv.log"; then
  ok "codex の実 argv に境界宣言が届いている"
else
  bad "codex の実 argv に境界宣言が無い（build_prompt を経由していない疑い）"
  head -10 "$TMP/argv.log" | sed 's/^/    | /' >&2
fi

# --staging-dir が parse_adapter_args → build_prompt → 実 argv まで通ることを、
# アダプタの実起動経路で確かめる。build_prompt 単体の出力だけを見ていると、
# アダプタが引数を落としていても気づけない（本 Issue の原因はまさに伝達漏れ）。
: > "$TMP/argv.log"
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
elif grep -qF "$STAGING_FIXTURE" "$TMP/argv.log"; then
  ok "codex の実 argv に staging の実パスが届いている"
else
  bad "codex の実 argv に staging パスが無い（--staging-dir の伝達漏れ）"
  head -10 "$TMP/argv.log" | sed 's/^/    | /' >&2
fi

echo "== orchestrator 経由での staging 伝達（Issue #392 AC1） =="

# build_prompt / アダプタ単体ではなく、multi-agent.sh を実起動して
# 「orchestrator が staging を解決 → 実在させる → アダプタへ渡す → プロンプトに載る
# → エージェントが書いた成果物が実行後も残っている」を通しで見る。
# --dry-run ではアダプタが起動しないので、ここは実行モードで回す（stub CLI のみ）。
#
# 出力先は**既定**（--output-dir 無指定 = ${REPO_ROOT}/.implement-results）にする。
# 利用者が実際に通る経路であり、サンドボックス警告が出ない側の分岐でもある。
# CWD 外を指す経路は下の「警告の発火」ケースで別に見る。
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
UNPLANNED_STAGING="$ORCH_OUT/gemini-cli/files/documentation"
mkdir -p "$UNPLANNED_STAGING"
printf 'from an earlier run\n' > "$UNPLANNED_STAGING/old.txt"

# 本物のエージェントのように staging へ書き込む stub。プロンプト（argv のどれか）
# から実パスを読み取る — 位置ではなく全 argv を走査するのは、codex アダプタが
# プロンプトを 2 番目の引数として渡すため。
cat > "$STUB/codex" <<SH
#!/usr/bin/env bash
for a in "\$@"; do printf '%s\n' "\$a" >> "$TMP/argv.log"; done
sd=""
for a in "\$@"; do
  case "\$a" in
    *"ONLY under this staging directory"*)
      sd="\$(printf '%s\n' "\$a" | awk '/ONLY under this staging directory/{getline; gsub(/^[ \t]+|[ \t]+\$/,""); print; exit}')" ;;
  esac
done
if [ -n "\$sd" ] && [ -d "\$sd" ]; then printf 'generated\n' > "\$sd/gen.ts"; fi
echo "stub implement output"
SH
chmod +x "$STUB/codex"

: > "$TMP/argv.log"
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
  elif grep -qF "$ORCH_STAGING" "$TMP/argv.log"; then
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

  # 既定パスは CWD 配下なので、サンドボックス警告は**出てはいけない**。
  # 論理パス/物理パスのずれ（symlink 越しのチェックアウト）で誤発火する形の回帰は
  # ここで赤くなる。
  expect_lacks "既定の出力先ではサンドボックス警告を出さない" \
    "$(cat "$TMP/orch.log")" "outside the CLI sandbox root"
fi

echo "== サンドボックス境界の警告（発火する側） =="

# CWD 外を --output-dir で指したときは警告が出る。上の「出ない」ケースと対になって
# いないと、警告関数を丸ごと no-op にする変異も、常に警告する変異も検出できない。
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
  bad "CWD 外 --output-dir の実行が非 0 終了した (rc=$ORCH_OUTSIDE_RC)"
  tail -25 "$TMP/orch-outside.log" | sed 's/^/    | /' >&2
else
  expect_contains "CWD 外の staging ではサンドボックス警告を出す" \
    "$(cat "$TMP/orch-outside.log")" "outside the CLI sandbox root"
fi

echo "== 相対 --output-dir の絶対化 =="

# --output-dir は値を無加工で受けるため、絶対化しないとプロンプトが
# "(absolute path)" と断言しながら相対パスを渡す。受け取ったエージェントは
# 自分の CWD = 作業ツリー基準で解決するので、本 Issue が塞ごうとした汚染に戻る。
: > "$TMP/argv.log"
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
elif grep -qF "$REPO/rel-out/codex-cli/files/feature-implementation" "$TMP/argv.log"; then
  ok "相対 --output-dir でもプロンプトには絶対パスが載る"
else
  bad "相対 --output-dir が絶対化されずプロンプトへ渡っている"
  grep -n 'staging directory' -A 2 "$TMP/argv.log" | head -6 | sed 's/^/    | /' >&2
fi

echo "== 前回の staging を消せないときの fail-loud =="

# rm の rc を捨てると、消せなかった前回の生成物が「今回の成果」としてレポートに
# 案内されたまま実行が進む。staging 自体を書き込み不可にすると、中の残骸を
# unlink できず rm が失敗する（親が書けても子は消せない）。
RMFAIL_OUT="$TMP/rmfail-out"
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
SYM_OUT="$TMP/sym-out"
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
expect_contains "symlink 脱出を真因として名指しする" \
  "$(cat "$TMP/orch-sym.log")" "resolves outside the output dir"
# 準備段階で落ちた実行はレポートを出さない。出すと、掃除できなかった前回の
# 成果物を「今回の結果」として並べたうえで "Done! View results" と案内する。
if [ -f "$SYM_OUT/integrated-report.md" ]; then
  bad "準備段階で落ちたのに統合レポートを生成した（前回の成果物を今回分として案内する）"
else
  ok "準備段階で落ちた実行はレポートを生成しない"
fi
rm -f "$SYM_OUT/codex-cli/files"

echo "== 出力モードの排他 =="

set +e
BOTH_ERR="$( (
  TASK_TYPE=implement DESCRIPTION=d STAGING_DIR="$STAGING_FIXTURE" INLINE_OUTPUT=true
  export TASK_TYPE DESCRIPTION STAGING_DIR INLINE_OUTPUT
  # shellcheck source=../../scripts/adapters/adapter-common.sh
  source "$ADAPTER_COMMON"
  build_prompt "$PERSPECTIVE" develop
) 2>&1 >/dev/null )"
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
MKFAIL_OUT="$TMP/mkfail-out"
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

echo
if [ "$FAIL" -gt 0 ]; then
  echo "✗ adapter-prompt-guard verify: $FAIL 件失敗" >&2
  exit 1
fi
echo "✓ adapter-prompt-guard verify: 全 $PASS 件 pass"
FF_REACHED_END=1
