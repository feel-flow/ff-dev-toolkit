#!/usr/bin/env bash
#
# 主 + 副レビュワー体制の回帰テスト（Issue #255）。
#
# 実 CLI は起動しない。stub の存在だけを command -v で検出させた dry-run を使う。
# 設定の保存先は XDG_CONFIG_HOME を一時ディレクトリへ向けて隔離する（利用者の
# 実設定を読みも書きもしない）。
#
# 潰している事故:
#   - モデル slug が設定ファイル経由で保存され、.sh しか走査しない
#     tests/no-hardcoded-model をすり抜ける（ACE-70-2 の再発経路）
#   - 縮退が「黙って単一レビューになる」形で起き、利用者が気づけない
#   - CI が対話待ちで止まる、あるいは逆に空のレビューを通す
#
# 検査は失敗側だけでなく**正常系も**置く。安全側のガードは落ちる方向が安全に
# 見えるため、「壊れたときに落ちる」だけを書くと、常に落ちる実装でも緑になる
# （ACE-253-3 / ACE-253-4）。
#
# run-all-required: no — 一時領域が無い環境の skip を許容する（一時領域依存 suite の必須判断で名簿へ載せなかった側。必須へ昇格するなら REQUIRED_SUITES へ移す）

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# fixture リポジトリの identity を呼び出し元へ漏らさない（Issue #1348 / #1368）
# fixture リポジトリの identity を呼び出し元へ漏らさない（Issue #1348 / #1368）
# shellcheck source=../lib/git-fixture.sh
. "$SCRIPT_DIR/../lib/git-fixture.sh"

MULTI_AGENT="$PLUGIN_ROOT/scripts/multi-agent.sh"

PERSPECTIVES_DIR="$PLUGIN_ROOT/scripts/perspectives/review"

[ -f "$MULTI_AGENT" ] || { echo "✗ multi-agent.sh が見つかりません" >&2; exit 1; }

# 実行環境の MULTI_AGENT_* からの分離（Issue #374 / #378 / #383）。
# orchestrator は --config 未指定時に $MULTI_AGENT_CONFIG を最優先で読むため、
# ホストが export していると suite が意図した config（プロジェクト直下 or 同梱既定）が
# 実行環境の指定にすり替わる（実測: MULTI_AGENT_CONFIG=/no/such/config.yaml で rc=1）。
# **存在検査より後に置くこと。** 先に置くと multi-agent.sh が無い環境で grep が rc=2 を
# 返し、「抽出が失敗しました」という分離機構側の診断が先に出て、真因である
# 「multi-agent.sh が見つかりません」が隠れる（既存の存在検査が事実上デッドコードになる）。
# shellcheck source=../lib/adapter-env-isolation.sh
source "$PLUGIN_ROOT/tests/lib/adapter-env-isolation.sh"
build_isolate_env "MULTI_AGENT_CONFIG" "$MULTI_AGENT"

PASS=0
FAIL=0
ok()  { echo "  ✓ $1"; PASS=$((PASS + 1)); }
bad() { echo "  ✗ $1" >&2; FAIL=$((FAIL + 1)); }

echo "== 主 + 副レビュワー体制 =="

# mktemp の stderr を捨てない。捨てると read-only 以外の失敗（TMPDIR が不正な
# パス・quota 超過など）まで「書き込み可能な環境で再実行してください」に誤帰属し、
# 恒常的に壊れた TMPDIR が suite を exit 0 で無効化し続ける。2>&1 で受けると
# 成功時はパス・失敗時は理由が同じ変数に入る。
# rc=0 でも -d を検査する — 2>&1 の合流は「成功 + stderr 警告」の環境で変数へ
# 警告文が混入し、以後の処理が原因不明の失敗に化けるため。
if _ff_mktemp_out="$(mktemp -d 2>&1)" && [ -d "$_ff_mktemp_out" ]; then
  TMP="$_ff_mktemp_out"
else
  echo "○ skip: 一時ディレクトリを作成できない環境（本 suite の検査は1件も実行されていません）"
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
    echo "✗ reviewer-pair: 最後まで到達しませんでした（途中で中断）" >&2
    exit 1
  fi
  exit "$_ff_rc"
}
trap _ff_exit_guard EXIT

REPO="$TMP/repo"
STUB="$TMP/stub"
CFG="$TMP/config"
mkdir -p "$REPO" "$STUB" "$CFG"

ff_git_fixture_init "$REPO" "reviewer-pair-test" "test@example.com"
git -C "$REPO" config commit.gpgsign false
git -C "$REPO" switch -q -c develop
printf '%s\n' base > "$REPO/app.txt"
git -C "$REPO" add app.txt
git -C "$REPO" commit -qm init
git -C "$REPO" switch -q -c feature/x

# 全 CLI を導入済みにする（dry-run なので stub は起動されない）
for name in claude codex copilot grok; do
  printf '%s\n' '#!/usr/bin/env bash' 'exit 99' > "$STUB/$name"
  chmod +x "$STUB/$name"
done

# PATH を stub + システムだけに絞るのは「どの CLI が導入済みか」を支配するため。
# その副作用で yq も見えなくなり、設定ファイル経由の検査が黙って skip される
# （実際に一度踏んだ）。yq は ALL_CLIS のメンバーではないので、stub 側へ通す。
YQ_AVAILABLE=false
if command -v yq >/dev/null 2>&1; then
  ln -sf "$(command -v yq)" "$STUB/yq" 2>/dev/null && YQ_AVAILABLE=true
fi

# run <出力ファイル> [env...] -- [args...]
RUN_RC=0
run() {
  local out="$1"; shift
  local envs=()
  while [[ $# -gt 0 && "$1" != "--" ]]; do envs+=("$1"); shift; done
  [[ "${1:-}" == "--" ]] && shift
  set +e
  (
    cd "$REPO"
    run_isolated env PATH="$STUB:/usr/bin:/bin" XDG_CONFIG_HOME="$CFG" HOME="$TMP/home" \
      ${envs[@]+"${envs[@]}"} bash "$MULTI_AGENT" --task review --base develop "$@"
  ) >"$out" 2>&1
  RUN_RC=$?
  set -e
}

reset_config() { rm -rf "${CFG:?}/ff-dev-toolkit"; }

# ── 状態出力と保存 ──────────────────────────────────────────────

echo ""
echo "-- 状態出力（--print-reviewers） --"
reset_config
run "$TMP/print-unset.log" -- --print-reviewers
if [ "$RUN_RC" -eq 3 ]; then
  ok "未設定なら exit 3（スキル層はこの終了コードで分岐する）"
else
  bad "未設定の終了コードが 3 でない（rc=${RUN_RC}）"
fi
# 前置一致だけだと `available=`（値が空）で通ってしまう。空のリストは、スキル層が
# 提示できる選択肢がゼロの状態で、まさに選択肢を作れない場面。値まで見る。
if grep -qE '^available=[a-z][a-z0-9-]*' "$TMP/print-unset.log" \
  && grep -qE '^known=[a-z][a-z0-9-]*' "$TMP/print-unset.log" \
  && grep -q '^known=.*claude-code' "$TMP/print-unset.log"; then
  ok "検出済み CLI と既知 CLI を値付きで出力する（選択肢を作る材料になる）"
else
  bad "available= / known= が空、または既知 CLI 名を含まない"
  sed 's/^/    /' "$TMP/print-unset.log" >&2
fi

# CLI が 1 つも無い環境。detect_available_clis は案内を出して exit する（関数の
# return ではないので握りつぶせない）。状態を後から出す実装だと 1 バイトも出ずに
# 終わる — /multi-review の最初のコマンドなので、プラグインだけ入れた人が最初に
# 踏む経路になる。
NOCLI="$TMP/nocli-bin"
mkdir -p "$NOCLI"
set +e
(
  cd "$REPO"
  run_isolated env PATH="$NOCLI:/usr/bin:/bin" XDG_CONFIG_HOME="$CFG" HOME="$TMP/home" \
    bash "$MULTI_AGENT" --task review --base develop --print-reviewers
) >"$TMP/nocli.log" 2>"$TMP/nocli.err"
rc=$?
set -e
# 検出は「1 つも無い」時点で案内を出して exit するので、available= / known= は
# 出ない。出るべきは**検出より前の状態**（main / sub / 出所）で、これが 1 行も
# 無いと利用者は何も手がかりを得られない。
if grep -q '^main=' "$TMP/nocli.log" \
  && grep -q '^source=' "$TMP/nocli.log"; then
  ok "CLI が 1 つも無くても、検出より前の状態は出力する（無言で終わらない）"
else
  bad "CLI が無い環境で状態が 1 行も出ていない（rc=${rc}）"
  echo "      stdout: $(wc -c < "$TMP/nocli.log" | tr -d ' ') bytes" >&2
fi
if grep -q 'npm install' "$TMP/nocli.err"; then
  ok "CLI が無い環境でインストール案内が stderr に届く（唯一の手がかりを捨てない）"
else
  bad "インストール案内が握りつぶされている"
  sed 's/^/    /' "$TMP/nocli.err" >&2
fi

echo ""
echo "-- 保存（--set-reviewers） --"
run "$TMP/set.log" -- --set-reviewers main=claude-code,sub=codex-cli
if [ "$RUN_RC" -eq 0 ]; then
  ok "主・副の保存が成功する"
else
  bad "保存に失敗した（rc=${RUN_RC}）"
  sed 's/^/    /' "$TMP/set.log" >&2
fi

run "$TMP/print-set.log" -- --print-reviewers
if [ "$RUN_RC" -eq 0 ] \
  && grep -q '^main=claude-code$' "$TMP/print-set.log" \
  && grep -q '^sub=codex-cli$' "$TMP/print-set.log"; then
  ok "保存後は exit 0 で主・副を読み出せる"
else
  bad "保存した値を読み出せない（rc=${RUN_RC}）"
  sed 's/^/    /' "$TMP/print-set.log" >&2
fi

# ── プランの形 ──────────────────────────────────────────────────

echo ""
echo "-- プランの形（主に全観点 / 副に総合 1 本） --"
run "$TMP/pair.log" -- --dry-run
# 件数だけの比較は「重複 1 件 + 欠落 1 件」で通ってしまう。集合で突き合わせる。
expected_main="$(find "$PERSPECTIVES_DIR" -name '*.md' -not -name 'comprehensive-review.md' -exec basename {} .md \; | sort | tr '\n' ' ')"
actual_main="$(awk '/^   claude-code /{f=1;next} /^   [a-z]/{f=0} f&&/^     - /{print $2}' "$TMP/pair.log" | sort | tr '\n' ' ')"
if [ "$expected_main" = "$actual_main" ]; then
  ok "主が review 観点すべてを担当する（集合一致）"
else
  bad "主の観点集合が不一致"
  echo "      期待: ${expected_main}" >&2
  echo "      実際: ${actual_main}" >&2
fi
# 重複が無いこと（集合一致は sort -u ではないので、重複はここで落ちる）
dup="$(awk '/^   claude-code /{f=1;next} /^   [a-z]/{f=0} f&&/^     - /{print $2}' "$TMP/pair.log" | sort | uniq -d | tr '\n' ' ')"
if [ -z "${dup// }" ]; then
  ok "主の観点に重複が無い（同じ差分を二重に見ない）"
else
  bad "主の観点が重複している: ${dup}"
fi
sub_lines="$(awk '/^   codex-cli /{f=1;next} /^   [a-z]/{f=0} f&&/^     - /{print $2}' "$TMP/pair.log")"
if [ "$sub_lines" = "comprehensive-review" ]; then
  ok "副は総合レビュー 1 本だけを担当する"
else
  bad "副の担当が総合レビュー 1 本ではない: ${sub_lines:-（なし）}"
fi
# 総合レビューが主に混ざっていないこと（主は個別観点、副は総合、という分担）。
# パイプの下流に grep -q を置かない — 一致した時点で下流が終了し、上流が SIGPIPE で
# 死んで pipefail のもとで判定が反転する（Issue #234 / ACE-249。このセッションで
# 一度踏んだうえ、ここでも書いてガードに捕まえられた）。awk 内で完結させる。
# 主のブロックが見つからないまま「重複が無い」と判定しないこと（vacuous pass）。
if awk '/^   claude-code /{f=1;seen=1;next} /^   [a-z]/{f=0} f&&/comprehensive-review/{found=1} END{exit (seen && !found)?0:1}' "$TMP/pair.log"; then
  ok "総合レビューを主に重複させない"
else
  bad "総合レビューが主にも割り当てられている（同じ差分を二重に見る）"
fi
# --perspective 無しの既定形。副が計画されているので縮退の話は一切出ない
# （Issue #597 の追加出力が正常系へ漏れていないことの確認）。
if ! grep -q 'Plan resolved to a single CLI' "$TMP/pair.log" \
  && ! grep -q 'running single-reviewer' "$TMP/pair.log"; then
  ok "既定の pair プランでは縮退メッセージが一切出ない"
else
  bad "縮退していないのに縮退メッセージが出ている"
  sed 's/^/    | /' "$TMP/pair.log" >&2
fi

# ── 縮退（すべて続行。止めるのは主が未導入のときだけ） ──────────

echo ""
echo "-- 縮退 --"
run "$TMP/nosub.log" MULTI_AGENT_REVIEW_MAIN=claude-code MULTI_AGENT_REVIEW_SUB= -- --dry-run
if [ "$RUN_RC" -eq 0 ] && grep -q 'No sub reviewer set' "$TMP/nosub.log"; then
  ok "副が未設定なら主のみで続行し、設定を促す"
else
  bad "副が未設定のときの縮退が期待と違う（rc=${RUN_RC}）"
fi

run "$TMP/same.log" MULTI_AGENT_REVIEW_MAIN=codex-cli MULTI_AGENT_REVIEW_SUB=codex-cli -- --dry-run
if [ "$RUN_RC" -eq 0 ] && grep -q 'same CLI as main' "$TMP/same.log"; then
  ok "副が主と同じなら重複排除して続行する"
else
  bad "主 == 副 の重複排除が働いていない（rc=${RUN_RC}）"
fi

# 副が未導入。claude だけを PATH に置く
SOLO="$TMP/solo"
mkdir -p "$SOLO"
printf '%s\n' '#!/usr/bin/env bash' 'exit 99' > "$SOLO/claude"
chmod +x "$SOLO/claude"
set +e
(
  cd "$REPO"
  run_isolated env PATH="$SOLO:/usr/bin:/bin" XDG_CONFIG_HOME="$CFG" HOME="$TMP/home" \
    MULTI_AGENT_REVIEW_MAIN=claude-code MULTI_AGENT_REVIEW_SUB=codex-cli \
    bash "$MULTI_AGENT" --task review --base develop --dry-run
) >"$TMP/submissing.log" 2>&1
rc=$?
set -e
if [ "$rc" -eq 0 ] && grep -q "sub reviewer 'codex-cli' is not installed" "$TMP/submissing.log"; then
  ok "副が未導入なら警告して主のみで続行する"
else
  bad "副が未導入のときの縮退が期待と違う（rc=${rc}）"
fi

set +e
(
  cd "$REPO"
  run_isolated env PATH="$SOLO:/usr/bin:/bin" XDG_CONFIG_HOME="$CFG" HOME="$TMP/home" \
    MULTI_AGENT_REVIEW_MAIN=grok-cli \
    bash "$MULTI_AGENT" --task review --base develop --dry-run
) >"$TMP/mainmissing.log" 2>&1
rc=$?
set -e
if [ "$rc" -ne 0 ] && grep -q "main reviewer 'grok-cli' is not installed" "$TMP/mainmissing.log"; then
  ok "主が未導入なら fail-loud（レビュー不能なので続行しない）"
else
  bad "主が未導入なのに続行した（rc=${rc}）"
fi

# ── 値の検証（モデル slug を保存できないこと） ──────────────────

echo ""
echo "-- 値の検証 --"
for bad_value in gpt-5.6-sol claude-opus-5 sonnet-4 grok-4; do
  run "$TMP/slug.log" "MULTI_AGENT_REVIEW_SUB=${bad_value}" -- --dry-run
  if [ "$RUN_RC" -ne 0 ] && grep -q "unknown sub reviewer: '${bad_value}'" "$TMP/slug.log"; then
    ok "モデル slug '${bad_value}' を拒否する"
  else
    bad "モデル slug '${bad_value}' が通った（rc=${RUN_RC}）— 設定ファイル経由で ACE-70-2 が再発する"
  fi
done

if grep -q 'Reviewers are CLI names, not model names' "$TMP/slug.log"; then
  ok "拒否理由が「CLI 名であってモデル名ではない」ことを説明する"
else
  bad "拒否メッセージが期待する値の形を説明していない"
fi

# main / sub の両方を独立に検査する。片方だけ試すと、もう片方の検証を外す変更が
# 素通りする（実際に main 側の検証だけを外す変異が緑のまま通った）。
run "$TMP/setslug.log" -- --set-reviewers main=claude-code,sub=gpt-5.6-sol
saved_sub="$(awk -F= '/^sub=/{print $2}' "$CFG/ff-dev-toolkit/reviewers" 2>/dev/null || true)"
if [ "$RUN_RC" -ne 0 ] && [ "$saved_sub" != "gpt-5.6-sol" ]; then
  ok "sub の不正値は保存前に拒否する（壊れた設定を書き残さない）"
else
  bad "sub の不正値が保存された（rc=${RUN_RC} / 保存値=${saved_sub}）"
fi

run "$TMP/setslugmain.log" -- --set-reviewers main=gpt-5.6-sol,sub=codex-cli
saved_main="$(awk -F= '/^main=/{print $2}' "$CFG/ff-dev-toolkit/reviewers" 2>/dev/null || true)"
if [ "$RUN_RC" -ne 0 ] && [ "$saved_main" != "gpt-5.6-sol" ]; then
  ok "main の不正値は保存前に拒否する"
else
  bad "main の不正値が保存された（rc=${RUN_RC} / 保存値=${saved_main}）"
fi

# 解決時も main / sub を独立に検査する
run "$TMP/slugmain.log" MULTI_AGENT_REVIEW_MAIN=claude-opus-5 -- --dry-run
if [ "$RUN_RC" -ne 0 ] && grep -q "unknown main reviewer: 'claude-opus-5'" "$TMP/slugmain.log"; then
  ok "解決時も main のモデル slug を拒否する"
else
  bad "解決時に main のモデル slug が通った（rc=${RUN_RC}）"
fi

# ACE-70-2 の再入経路は「設定ファイル経由」。既存の拒否テストは env と
# --set-reviewers しか通っておらず、env のときだけ検証する実装でも全件緑になる。
# 2 つのファイル経路を直接書いて塞ぐ。
mkdir -p "$REPO/.claude"
cat > "$REPO/.claude/agent-config.yaml" <<'YAML'
version: "2.0"
review:
  main: gpt-5.6-sol
YAML
run "$TMP/yamlslug.log" -- --dry-run
if [ "$YQ_AVAILABLE" = "true" ]; then
  if [ "$RUN_RC" -ne 0 ] && grep -q "unknown main reviewer: 'gpt-5.6-sol'" "$TMP/yamlslug.log"; then
    ok "プロジェクト設定ファイル経由のモデル slug も拒否する"
  else
    bad "設定ファイル経由でモデル slug が通った（rc=${RUN_RC}）— ACE-70-2 の再入経路"
  fi
else
  ok "○ yq 不在のため設定ファイル経由の検査はスキップ"
fi
rm -rf "$REPO/.claude"

printf '%s\n' 'main=claude-code' 'sub=gpt-5.6-sol' > "$CFG/ff-dev-toolkit/reviewers"
run "$TMP/fileslug.log" -- --dry-run
if [ "$RUN_RC" -ne 0 ] && grep -q "unknown sub reviewer: 'gpt-5.6-sol'" "$TMP/fileslug.log"; then
  ok "ユーザーグローバルの手編集によるモデル slug も拒否する"
else
  bad "手編集した設定ファイルのモデル slug が通った（rc=${RUN_RC}）"
fi
run "$TMP/restore2.log" -- --set-reviewers main=claude-code,sub=codex-cli

run "$TMP/setnomain.log" -- --set-reviewers sub=codex-cli
if [ "$RUN_RC" -ne 0 ]; then
  ok "main を省略した保存を拒否する（副だけでは成立しない）"
else
  bad "main 無しの保存が通った"
fi

run "$TMP/setsame.log" -- --set-reviewers main=codex-cli,sub=codex-cli
if [ "$RUN_RC" -ne 0 ]; then
  ok "主と同じ CLI を副として保存させない"
else
  bad "主 == 副 の保存が通った"
fi

# ── 3 層解決の優先順位 ──────────────────────────────────────────

echo ""
echo "-- 3 層解決 --"
run "$TMP/setbase.log" -- --set-reviewers main=claude-code,sub=codex-cli
run "$TMP/envwin.log" MULTI_AGENT_REVIEW_MAIN=copilot-cli MULTI_AGENT_REVIEW_SUB=grok-cli -- --print-reviewers
if grep -q '^main=copilot-cli$' "$TMP/envwin.log" && grep -q '^source=env$' "$TMP/envwin.log"; then
  ok "env がユーザーグローバルより優先される"
else
  bad "3 層解決の優先順位が env > user になっていない"
  sed 's/^/    /' "$TMP/envwin.log" >&2
fi

mkdir -p "$REPO/.claude"
cat > "$REPO/.claude/agent-config.yaml" <<'YAML'
version: "2.0"
tasks:
  review:
    mode: pair
review:
  main: grok-cli
  sub: copilot-cli
YAML
run "$TMP/projwin.log" -- --print-reviewers
if [ "$YQ_AVAILABLE" = "true" ]; then
  if grep -q '^main=grok-cli$' "$TMP/projwin.log"; then
    ok "プロジェクト設定がユーザーグローバルより優先される"
  else
    bad "プロジェクト設定が読まれていない"
    sed 's/^/    /' "$TMP/projwin.log" >&2
  fi
else
  ok "○ yq 不在のためプロジェクト設定の優先順位検査はスキップ（他の検査は実行済み）"
fi
rm -rf "$REPO/.claude"

# ── 非対話・CI ─────────────────────────────────────────────────

echo ""
echo "-- 未設定 × 非対話 --"
reset_config
set +e
(
  cd "$REPO"
  run_isolated env PATH="$STUB:/usr/bin:/bin" XDG_CONFIG_HOME="$CFG" HOME="$TMP/home" \
    bash "$MULTI_AGENT" --task review --base develop --dry-run </dev/null
) >"$TMP/ci.log" 2>&1
rc=$?
set -e
if [ "$rc" -eq 0 ] && grep -q 'falling back to the distributed plan' "$TMP/ci.log"; then
  ok "未設定なら対話を試みず、従来の分散プランで続行する（CI を止めない）"
else
  bad "未設定 × 非対話の挙動が期待と違う（rc=${rc}）"
  sed 's/^/    /' "$TMP/ci.log" >&2
fi
if ! grep -qE '選んでください|Select|\[y/n\]' "$TMP/ci.log"; then
  ok "非対話で対話プロンプトを出さない"
else
  bad "非対話なのに対話プロンプトを出している"
fi

# 片側だけ指定したときの混ざり方。ペア単位ではなく**フィールド単位**の優先順位に
# 統一したので、4 通りすべてが説明できる形になっているかを固定する。片側指定を
# 検査しないと、上位層の main と下位層の sub が非対称に混ざる実装でも緑になる。
echo ""
echo "-- 3 層解決（片側指定） --"
run "$TMP/base.log" -- --set-reviewers main=claude-code,sub=codex-cli

# 出所（source）は片側指定のときに最も知りたい情報なのに、env のケースだけを
# 主張すると `source` をハードコードした実装でも通る。各層で個別に主張する。
run "$TMP/src-user.log" -- --print-reviewers
if grep -q '^main_source=user config$' "$TMP/src-user.log" \
  && grep -q '^sub_source=user config$' "$TMP/src-user.log"; then
  ok "ユーザーグローバル由来の出所を正しく報告する"
else
  bad "出所の報告が user config になっていない"
  sed 's/^/    /' "$TMP/src-user.log" >&2
fi

run "$TMP/one-main.log" MULTI_AGENT_REVIEW_MAIN=copilot-cli -- --print-reviewers
if grep -q '^main=copilot-cli$' "$TMP/one-main.log" && grep -q '^sub=codex-cli$' "$TMP/one-main.log"; then
  ok "env で main だけ指定すると sub は下位層から引き継ぐ"
else
  bad "main だけの env 指定で sub の解決が壊れている"
  sed 's/^/    /' "$TMP/one-main.log" >&2
fi

# 混ざった場合の出所。ここが単一の値だと、どちらを直せばよいか分からない。
if grep -q '^main_source=env$' "$TMP/one-main.log" \
  && grep -q '^sub_source=user config$' "$TMP/one-main.log"; then
  ok "層をまたいだときは main / sub それぞれの出所を報告する"
else
  bad "混在時の出所がフィールド単位で報告されていない"
  sed 's/^/    /' "$TMP/one-main.log" >&2
fi

run "$TMP/one-sub.log" MULTI_AGENT_REVIEW_SUB=grok-cli -- --print-reviewers
if grep -q '^main=claude-code$' "$TMP/one-sub.log" && grep -q '^sub=grok-cli$' "$TMP/one-sub.log"; then
  ok "env で sub だけ指定すると main は下位層から引き継ぐ"
else
  bad "sub だけの env 指定で main の解決が壊れている"
  sed 's/^/    /' "$TMP/one-sub.log" >&2
fi

run "$TMP/empty-sub.log" MULTI_AGENT_REVIEW_SUB= -- --print-reviewers
if grep -q '^main=claude-code$' "$TMP/empty-sub.log" && grep -q '^sub=$' "$TMP/empty-sub.log"; then
  ok "env で sub を空にすると「今回は副なし」として下位層で埋め戻さない"
else
  bad "空文字での副なし指定が下位層に上書きされている"
  sed 's/^/    /' "$TMP/empty-sub.log" >&2
fi

# ── --perspective と縮退の組合せ ───────────────────────────────

echo ""
echo "-- --perspective と縮退 --"
run "$TMP/persp-main.log" -- --perspective code-review --dry-run
# 「プランに総合観点が無い」はプラン行の書式で測る。ログ全体の grep にすると、
# 副の脱落理由（観点名を名乗る 1 行）まで拾って判定が反転する（Issue #597）。
if [ "$RUN_RC" -eq 0 ] \
  && grep -q '^     - code-review$' "$TMP/persp-main.log" \
  && ! grep -q '^     - comprehensive-review$' "$TMP/persp-main.log"; then
  ok "個別観点だけを指定すると主のその観点だけが計画される"
else
  bad "個別観点の --perspective が期待どおりでない（rc=${RUN_RC}）"
fi

# 副の脱落は 4 経路すべてが理由を出すこと（Issue #597）。ここだけ else が無く、
# クロスモデルのつもりが単一 CLI レビューになったことに気づけなかった。
if grep -q "sub reviewer 'codex-cli' runs only 'comprehensive-review'" "$TMP/persp-main.log" \
  && grep -q -- '--perspective (code-review)' "$TMP/persp-main.log"; then
  ok "--perspective で副が落ちる経路も理由を名乗る（無言で落とさない）"
else
  bad "--perspective による副の脱落が無言（他 3 経路と不揃い）"
  sed 's/^/    | /' "$TMP/persp-main.log" >&2
fi

# 単一 CLI へ縮退したこと自体の警告（#183 と同等）が pair モードでも出ること。
if grep -q 'Plan resolved to a single CLI (claude-code)' "$TMP/persp-main.log" \
  && grep -q 'means zero review coverage' "$TMP/persp-main.log" \
  && grep -q -- '--mode cross-model --perspective code-review' "$TMP/persp-main.log"; then
  ok "pair モードでも単一 CLI 縮退警告と cross-model の案内が出る"
else
  bad "pair モードで単一 CLI 縮退警告が出ていない（#183 の gate が distributed 限定のまま）"
  sed 's/^/    | /' "$TMP/persp-main.log" >&2
fi

run "$TMP/persp-comp.log" -- --perspective comprehensive-review --dry-run
if [ "$RUN_RC" -eq 0 ] && grep -q 'codex-cli \[standard\]:' "$TMP/persp-comp.log"; then
  ok "総合観点だけを指定すると副だけが計画される"
else
  bad "総合観点の --perspective が期待どおりでない（rc=${RUN_RC}）"
fi

# 副が残っている以上、縮退はしていない。プランの CLI 数は 1 になるが、それは
# 要求どおりなので警告は雑音（Issue #597）。CLI 数だけを見る gate はここで落ちる。
if ! grep -q 'Plan resolved to a single CLI' "$TMP/persp-comp.log" \
  && ! grep -q 'runs only' "$TMP/persp-comp.log"; then
  ok "総合観点の明示指定では副が残り、余計な縮退警告を出さない"
else
  bad "副が計画されているのに縮退警告が出ている（正常系を壊している）"
  sed 's/^/    | /' "$TMP/persp-comp.log" >&2
fi

# --exclude-perspective で副の唯一の担当を外した経路。理由は名乗るが、縮退警告は
# 出さない（「その観点を走らせるな」は明示指定なので、--mode cross-model の案内は
# 的外れ）。理由と警告は別の判断なので、両方を 1 ケースで固定する。
run "$TMP/persp-excl.log" -- --exclude-perspective comprehensive-review --dry-run
if [ "$RUN_RC" -eq 0 ] \
  && grep -q "sub reviewer 'codex-cli' runs only 'comprehensive-review'" "$TMP/persp-excl.log" \
  && grep -q -- 'excluded by --exclude-perspective' "$TMP/persp-excl.log"; then
  ok "--exclude-perspective で副が落ちる経路も理由を名乗る"
else
  bad "--exclude-perspective による副の脱落が無言、または理由が不正確（rc=${RUN_RC}）"
  sed 's/^/    | /' "$TMP/persp-excl.log" >&2
fi
if ! grep -q 'Plan resolved to a single CLI' "$TMP/persp-excl.log"; then
  ok "明示的な除外には縮退警告を出さない（cross-model の案内が的外れなため）"
else
  bad "明示的な --exclude-perspective へ縮退警告を出している"
  sed 's/^/    | /' "$TMP/persp-excl.log" >&2
fi

# 併用時の優先順位。除外は「走らせるな」で、フィルタは「これを走らせろ」。両方が
# 副を落とす条件を満たすため、どちらの理由を名乗るかは分岐の順序で決まる。除外を
# 先に評価しないと、--perspective の値を括弧に入れた理由文が出て、しかも縮退警告
# まで付く（明示的に外した観点について cross-model を勧める形になる）。
run "$TMP/persp-both.log" -- --perspective code-review --exclude-perspective comprehensive-review --dry-run
if [ "$RUN_RC" -eq 0 ] \
  && grep -q -- 'excluded by --exclude-perspective' "$TMP/persp-both.log" \
  && ! grep -q -- 'not in --perspective' "$TMP/persp-both.log" \
  && ! grep -q 'Plan resolved to a single CLI' "$TMP/persp-both.log"; then
  ok "--perspective と --exclude-perspective の併用は除外を先に評価する"
else
  bad "併用時に --perspective 側の理由が出ている（除外より後に評価されている）（rc=${RUN_RC}）"
  sed 's/^/    | /' "$TMP/persp-both.log" >&2
fi

# 副が居ないのに総合観点を明示された場合。空プランで exit 1 になると
# 「副が居なければ主のみで続行」という縮退契約に反する。主へ回す。
run "$TMP/persp-comp-nosub.log" MULTI_AGENT_REVIEW_SUB= -- --perspective comprehensive-review --dry-run
if [ "$RUN_RC" -eq 0 ] \
  && grep -q 'no sub reviewer available' "$TMP/persp-comp-nosub.log" \
  && grep -q 'claude-code \[premium\]:' "$TMP/persp-comp-nosub.log"; then
  ok "副が居ないとき総合観点の明示指定は主へ回す（空プランで止めない）"
else
  bad "副なし × 総合観点の明示指定が空プランになっている（rc=${RUN_RC}）"
  sed -n '/Execution Plan/,$p' "$TMP/persp-comp-nosub.log" | sed 's/^/    /' >&2
fi

# ── pair は review 専用 ────────────────────────────────────────

echo ""
echo "-- pair の適用範囲 --"
set +e
(
  cd "$REPO"
  run_isolated env PATH="$STUB:/usr/bin:/bin" XDG_CONFIG_HOME="$CFG" HOME="$TMP/home" \
    bash "$MULTI_AGENT" --task explore --mode pair --description x --base develop --dry-run
) >"$TMP/pair-explore.log" 2>&1
rc=$?
set -e
if [ "$rc" -ne 0 ] && grep -q 'review-only' "$TMP/pair-explore.log"; then
  ok "explore に pair を指定したら事前に拒否する（実行時に全件失敗させない）"
else
  bad "explore で pair が通った（dry-run だけ成功して実行時に壊れる）（rc=${rc}）"
fi

# ── 保存の安全性 ───────────────────────────────────────────────

echo ""
echo "-- 保存の安全性 --"
run "$TMP/base2.log" -- --set-reviewers main=claude-code,sub=codex-cli
run "$TMP/reject.log" -- --set-reviewers main=gpt-5.6-sol,sub=codex-cli
kept_main="$(awk -F= '/^main=/{print $2}' "$CFG/ff-dev-toolkit/reviewers" 2>/dev/null || true)"
kept_sub="$(awk -F= '/^sub=/{print $2}' "$CFG/ff-dev-toolkit/reviewers" 2>/dev/null || true)"
if [ "$kept_main" = "claude-code" ] && [ "$kept_sub" = "codex-cli" ]; then
  ok "保存を拒否したとき既存の設定が無傷で残る"
else
  bad "拒否された保存が既存の設定を壊した（main=${kept_main} sub=${kept_sub}）"
fi

# 保存先がディレクトリだった場合。キャッシュなら消して自己修復してよいが、
# 利用者の設定を消してよいかを判断できるのは利用者だけ。fail-loud にする。
rm -f "$CFG/ff-dev-toolkit/reviewers"
mkdir -p "$CFG/ff-dev-toolkit/reviewers/sentinel"
run "$TMP/dirconf.log" -- --set-reviewers main=claude-code,sub=codex-cli
if [ "$RUN_RC" -ne 0 ] && [ -d "$CFG/ff-dev-toolkit/reviewers/sentinel" ]; then
  ok "保存先がディレクトリなら消さずに fail-loud する"
else
  bad "保存先のディレクトリを削除した（rc=${RUN_RC}）— 利用者のデータを消している"
fi
rm -rf "$CFG/ff-dev-toolkit/reviewers"
run "$TMP/restore.log" -- --set-reviewers main=claude-code,sub=codex-cli

# ── --cli との相互作用 ─────────────────────────────────────────
#
# --cli は分散モード用のフィルタで、pair には対応する概念が無い。review の既定が
# pair になったことで、従来 --cli で回していた指定が黙って無視される状態になって
# いた（効かないつまみ）。黙って捨てるのが最悪なので、分散へ落として通知する。

echo ""
echo "-- --cli との相互作用 --"
run "$TMP/clifilter.log" -- --cli grok-cli --dry-run
if [ "$RUN_RC" -eq 0 ] \
  && grep -q 'using the distributed plan' "$TMP/clifilter.log" \
  && grep -q 'Mode: distributed' "$TMP/clifilter.log"; then
  ok "--cli を渡したら分散へ落として通知する（黙って無視しない）"
else
  bad "--cli が pair モードで黙って無視されている（rc=${RUN_RC}）"
  sed 's/^/    /' "$TMP/clifilter.log" >&2
fi

# 落ちた先で --cli が実際に効いていること。通知だけ出して無視していたら意味がない。
if grep -q 'grok-cli \[flat-rate\]:' "$TMP/clifilter.log" \
  && ! grep -q 'comprehensive-review' "$TMP/clifilter.log"; then
  ok "落とした先の分散プランで --cli が実際に効いている"
else
  bad "分散へ落としたのに --cli が反映されていない"
fi

# 明示 --cli は意図的な単一モデルなので、縮退警告は出さない（#183 の設計を維持）。
if ! grep -q 'Plan resolved to a single CLI' "$TMP/clifilter.log"; then
  ok "明示 --cli の単一 CLI には縮退警告を出さない"
else
  bad "意図的な単一モデル指定へ縮退警告を出している"
fi

run "$TMP/clipair.log" -- --mode pair --cli grok-cli --dry-run
if [ "$RUN_RC" -ne 0 ] && grep -q 'cannot be combined with --mode pair' "$TMP/clipair.log"; then
  ok "--mode pair を明示したうえでの --cli は矛盾として拒否する"
else
  bad "--mode pair + --cli が通った（rc=${RUN_RC}）"
fi

# ── --strategy との相互作用（Issue #691） ──────────────────────
#
# minimize_cost の振替（premium → 最安 tier）は分散プラン専用で、pair には対応する
# 概念が無い。--cli（#255）は分散モード用フィルタなので分散へ落とせば意図を守れた
# が、cost strategy で設定済みの主・副（誰が見たか）を入れ替えるのは別問題なので、
# pair では「適用されない」を名乗るだけにし、プランは一切変えない。

echo ""
echo "-- --strategy との相互作用 --"
run "$TMP/strategy.log" -- --strategy minimize_cost --dry-run
if [ "$RUN_RC" -eq 0 ] \
  && grep -q "cost strategy 'minimize_cost'" "$TMP/strategy.log" \
  && grep -q 'does not apply in pair mode' "$TMP/strategy.log"; then
  ok "--strategy minimize_cost を渡したら適用されない旨を通知する（黙って無視しない）"
else
  bad "--strategy minimize_cost が pair モードで黙って無視されている（rc=${RUN_RC}）"
  sed 's/^/    /' "$TMP/strategy.log" >&2
fi
# 通知は値の出所まで名乗ること。config 由来でも発火するため、値だけだと利用者は
# どこを直せばよいか辿れない。
if grep -q 'from --strategy flag' "$TMP/strategy.log"; then
  ok "通知が値の出所（--strategy flag）を名乗る"
else
  bad "通知に値の出所が無い"
  sed 's/^/    /' "$TMP/strategy.log" >&2
fi
# 通知が「効かせる場所」まで指すこと。宣言だけだと利用者は次の一手を組み立てられない。
if grep -q -- '--set-reviewers' "$TMP/strategy.log" \
  && grep -q -- '--mode distributed' "$TMP/strategy.log"; then
  ok "通知がコストを下げる代替手段（--set-reviewers / --mode distributed）を案内する"
else
  bad "通知に代替手段の案内が無い"
  sed 's/^/    /' "$TMP/strategy.log" >&2
fi
# 通知のみでプランは通常の pair のまま（主の振替も分散への降格もしない）。
# 「💰 minimize_cost: ... → ...」は分散プランの振替行で、pair では出ないこと。
if grep -q 'Mode: pair' "$TMP/strategy.log" \
  && grep -q 'claude-code \[premium\]:' "$TMP/strategy.log" \
  && ! grep -q '💰 minimize_cost:' "$TMP/strategy.log" \
  && ! grep -q 'using the distributed plan' "$TMP/strategy.log"; then
  ok "通知のみでプランは pair のまま（振替・分散降格をしない）"
else
  bad "minimize_cost が pair のプランを変えている（rc=${RUN_RC}）"
  sed 's/^/    /' "$TMP/strategy.log" >&2
fi
# プラン不変の完全比較。主の存在確認だけだと「副だけ落とす」「観点を 1 つ削る」
# 変異が素通りする。CLI ヘッダ行と観点行の並び全体を、--strategy 無しの既定 pair
# （pair.log）と突き合わせる。空同士の一致は vacuous pass なので非空も主張する。
plan_lines() { grep -E '^   [a-z][a-z0-9-]+ \[[a-z-]+\]:$|^     - ' "$1"; }
if [ -n "$(plan_lines "$TMP/strategy.log")" ] \
  && [ "$(plan_lines "$TMP/pair.log")" = "$(plan_lines "$TMP/strategy.log")" ]; then
  ok "主・副の CLI と観点の並びが既定 pair と完全一致する（プラン不変）"
else
  bad "minimize_cost 付き pair のプランが既定 pair と一致しない"
  diff <(plan_lines "$TMP/pair.log") <(plan_lines "$TMP/strategy.log") | sed 's/^/    /' >&2 || true
fi
# --strategy 無しの既定 pair（上の pair.log）に通知が漏れないこと。既定 strategy は
# balanced なので、常時表示になったら「既定実行の出力を変えない」契約に反する。
if ! grep -q 'does not apply in pair mode' "$TMP/pair.log"; then
  ok "--strategy 無しの pair では通知を出さない（既定実行の出力は従来のまま）"
else
  bad "既定の pair 実行へ minimize_cost の通知が漏れている"
  sed 's/^/    /' "$TMP/pair.log" >&2
fi

# 通知は stderr のみに出ること。stdout は --print-reviewers 等の機械可読出力の
# 面なので、混ざるとスキル層のパースを壊す。stdout / stderr を分離して実測する。
set +e
(
  cd "$REPO"
  run_isolated env PATH="$STUB:/usr/bin:/bin" XDG_CONFIG_HOME="$CFG" HOME="$TMP/home" \
    bash "$MULTI_AGENT" --task review --base develop --strategy minimize_cost --dry-run
) >"$TMP/strategy-out.log" 2>"$TMP/strategy-err.log"
rc=$?
set -e
if [ "$rc" -eq 0 ] \
  && grep -q 'does not apply in pair mode' "$TMP/strategy-err.log" \
  && ! grep -q 'does not apply in pair mode' "$TMP/strategy-out.log"; then
  ok "通知は stderr のみに出る（stdout の機械可読出力を汚さない）"
else
  bad "通知の出力先が stderr に限定されていない（rc=${rc}）"
  echo "      stdout:" >&2; sed 's/^/        /' "$TMP/strategy-out.log" >&2
fi

# ── strategy 値の whitelist（Issue #691） ──
#
# 通知は minimize_cost の完全一致ゲートなので、typo（minimize_costs 等）を黙って
# 受けると振替も通知も無い完全な無音に戻る。未知の値は dry-run でも非 0 で拒否する。

echo ""
echo "-- strategy 値の whitelist --"
run "$TMP/strategy-typo.log" -- --strategy minimize_costs --dry-run
if [ "$RUN_RC" -ne 0 ] \
  && grep -q "unknown strategy 'minimize_costs'" "$TMP/strategy-typo.log" \
  && grep -q 'balanced, minimize_cost, maximize_quality' "$TMP/strategy-typo.log"; then
  ok "typo の strategy 値を有効値の一覧付きで拒否する（無音に落とさない）"
else
  bad "typo の strategy 値が通った（rc=${RUN_RC}）— 振替も通知も無い無音に戻る"
  sed 's/^/    /' "$TMP/strategy-typo.log" >&2
fi
# 拒否は出所を名乗ること（config 由来との切り分け）。
if grep -q "from --strategy flag" "$TMP/strategy-typo.log"; then
  ok "拒否メッセージが値の出所を名乗る"
else
  bad "拒否メッセージに値の出所が無い"
  sed 's/^/    /' "$TMP/strategy-typo.log" >&2
fi
# 正当な値は通ること。拒否側だけ書くと「常に拒否する」実装でも緑になる。
run "$TMP/strategy-maxq.log" -- --strategy maximize_quality --dry-run
if [ "$RUN_RC" -eq 0 ] && ! grep -q 'unknown strategy' "$TMP/strategy-maxq.log"; then
  ok "正当な値 maximize_quality は受理する（常時拒否ではない）"
else
  bad "正当な strategy 値が拒否された（rc=${RUN_RC}）"
  sed 's/^/    /' "$TMP/strategy-maxq.log" >&2
fi

# ── config 由来の strategy（Issue #691） ──
#
# STRATEGY は CLI flag だけでなく設定ファイルからも入る。通知・whitelist が
# flag 経路だけで実装されると、config 経由の typo / minimize_cost が再び無音になる。

echo ""
echo "-- config 由来の strategy --"
if [ "$YQ_AVAILABLE" = "true" ]; then
  mkdir -p "$REPO/.claude"
  cat > "$REPO/.claude/agent-config.yaml" <<'YAML'
version: "2.0"
tasks:
  review:
    cost_strategy: minimize_cost
YAML
  run "$TMP/strategy-cfg2.log" -- --dry-run
  if [ "$RUN_RC" -eq 0 ] \
    && grep -q 'does not apply in pair mode' "$TMP/strategy-cfg2.log" \
    && grep -q 'tasks.review.cost_strategy' "$TMP/strategy-cfg2.log" \
    && grep -q 'Mode: pair' "$TMP/strategy-cfg2.log" \
    && [ "$(plan_lines "$TMP/pair.log")" = "$(plan_lines "$TMP/strategy-cfg2.log")" ]; then
    ok "v2 config の cost_strategy でも通知が出て（出所キー付き）プランは不変"
  else
    bad "v2 config 由来の minimize_cost が無音、またはプランを変えている（rc=${RUN_RC}）"
    sed 's/^/    /' "$TMP/strategy-cfg2.log" >&2
  fi

  cat > "$REPO/.claude/agent-config.yaml" <<'YAML'
version: "2.0"
tasks:
  review:
    cost_strategy: minimise_cost
YAML
  run "$TMP/strategy-cfg2-typo.log" -- --dry-run
  if [ "$RUN_RC" -ne 0 ] \
    && grep -q "unknown strategy 'minimise_cost'" "$TMP/strategy-cfg2-typo.log" \
    && grep -q 'tasks.review.cost_strategy' "$TMP/strategy-cfg2-typo.log"; then
    ok "v2 config 経由の typo も出所キー付きで拒否する"
  else
    bad "v2 config 経由の typo が通った（rc=${RUN_RC}）"
    sed 's/^/    /' "$TMP/strategy-cfg2-typo.log" >&2
  fi

  cat > "$REPO/.claude/agent-config.yaml" <<'YAML'
cost_strategy: minimize_cost
YAML
  run "$TMP/strategy-cfg1.log" -- --dry-run
  if [ "$RUN_RC" -eq 0 ] \
    && grep -q 'does not apply in pair mode' "$TMP/strategy-cfg1.log" \
    && grep -q 'config cost_strategy' "$TMP/strategy-cfg1.log" \
    && grep -q 'Mode: pair' "$TMP/strategy-cfg1.log" \
    && [ "$(plan_lines "$TMP/pair.log")" = "$(plan_lines "$TMP/strategy-cfg1.log")" ]; then
    ok "v1 config の cost_strategy でも通知が出て（出所キー付き）プランは不変"
  else
    bad "v1 config 由来の minimize_cost が無音、またはプランを変えている（rc=${RUN_RC}）"
    sed 's/^/    /' "$TMP/strategy-cfg1.log" >&2
  fi
  rm -rf "$REPO/.claude"
else
  ok "○ yq 不在のため config 由来の strategy 検査はスキップ（flag 経路は実行済み）"
fi

# ── 既存モードの温存 ───────────────────────────────────────────

echo ""
echo "-- 既存モードの温存 --"
run "$TMP/dist.log" -- --mode distributed --dry-run
if [ "$RUN_RC" -eq 0 ] && grep -q 'Mode: distributed' "$TMP/dist.log" \
  && ! grep -q 'comprehensive-review' "$TMP/dist.log"; then
  ok "--mode distributed で従来の分散プランが使える"
else
  bad "従来の分散モードが壊れている（rc=${RUN_RC}）"
fi

set +e
(
  cd "$REPO"
  run_isolated env PATH="$STUB:/usr/bin:/bin" XDG_CONFIG_HOME="$CFG" HOME="$TMP/home" \
    bash "$MULTI_AGENT" --task explore --base develop --description x --dry-run
) >"$TMP/explore.log" 2>&1
rc=$?
set -e
if [ "$rc" -eq 0 ] && grep -q 'Mode: distributed' "$TMP/explore.log"; then
  ok "explore は従来どおり分散モードのまま"
else
  bad "explore のモードが変わっている（rc=${rc}）"
fi

# ── pair/plan の無言経路と観測性（Issue #699） ────────────────────
#
# #597 が潰した「無言の脱落」と同系統の残件 4 点。いずれも「起きたことが実行ログ /
# レポートから復元できない」形で、プランは正しく見えるのに事実が伝わらない。
echo ""
echo "-- mode 値の whitelist（Issue #699） --"
run "$TMP/mode-typo.log" -- --mode distribuited --dry-run
if [ "$RUN_RC" -ne 0 ] \
  && grep -q "unknown mode 'distribuited'" "$TMP/mode-typo.log" \
  && grep -q 'pair, distributed, cross-model' "$TMP/mode-typo.log"; then
  ok "typo の mode 値を有効値の一覧付きで拒否する（distributed へ黙って化けない）"
else
  bad "typo の mode 値が通った（rc=${RUN_RC}）— distributed 扱いで走り、受理ゲートの安全網も外れる"
  sed 's/^/    /' "$TMP/mode-typo.log" >&2
fi
if grep -q "from --mode flag" "$TMP/mode-typo.log"; then
  ok "mode の拒否メッセージが値の出所を名乗る"
else
  bad "mode の拒否メッセージに値の出所が無い（config 由来と切り分けられない）"
  sed 's/^/    /' "$TMP/mode-typo.log" >&2
fi
# 正当な値は通ること（常時拒否する実装でも緑にならないように）。
run "$TMP/mode-cross.log" -- --mode cross-model --perspective code-review --dry-run
if [ "$RUN_RC" -eq 0 ] && ! grep -q 'unknown mode' "$TMP/mode-cross.log"; then
  ok "正当な値 cross-model は受理する（常時拒否ではない）"
else
  bad "正当な mode 値が拒否された（rc=${RUN_RC}）"
  sed 's/^/    /' "$TMP/mode-cross.log" >&2
fi

# mode も CLI flag だけでなく設定ファイルから入る。whitelist が flag 経路だけだと
# config 由来の typo が黙って distributed として走る（STRATEGY と同型）。
echo ""
echo "-- config 由来の mode（Issue #699） --"
if [ "$YQ_AVAILABLE" = "true" ]; then
  mkdir -p "$REPO/.claude"
  cat > "$REPO/.claude/agent-config.yaml" <<'YAML'
version: "2.0"
tasks:
  review:
    mode: distribuited
YAML
  run "$TMP/mode-cfg2-typo.log" -- --dry-run
  if [ "$RUN_RC" -ne 0 ] \
    && grep -q "unknown mode 'distribuited'" "$TMP/mode-cfg2-typo.log" \
    && grep -q 'from config tasks.review.mode' "$TMP/mode-cfg2-typo.log"; then
    ok "v2 config 由来の mode typo を出所キー付きで拒否する"
  else
    bad "v2 config 由来の mode typo が通った（rc=${RUN_RC}）"
    sed 's/^/    /' "$TMP/mode-cfg2-typo.log" >&2
  fi

  cat > "$REPO/.claude/agent-config.yaml" <<'YAML'
mode: cross_model
YAML
  run "$TMP/mode-cfg1-typo.log" -- --dry-run
  if [ "$RUN_RC" -ne 0 ] \
    && grep -q "unknown mode 'cross_model'" "$TMP/mode-cfg1-typo.log" \
    && grep -q 'from config mode' "$TMP/mode-cfg1-typo.log"; then
    ok "v1 config の古い mode 値（cross_model）を出所キー付きで拒否する"
  else
    bad "v1 config 由来の古い mode 値が通った（rc=${RUN_RC}）"
    sed 's/^/    /' "$TMP/mode-cfg1-typo.log" >&2
  fi
  rm -rf "$REPO/.claude"
else
  echo "  ○ skip: yq が無いため config 由来の mode 検査を実行できません"
fi

# --list-perspectives は apply_task_defaults の手前で抜けるので、whitelist を
# そちらにだけ置くと一覧経路で綴り間違いが rc=0 の「確認」になる。
run "$TMP/mode-list.log" -- --mode distribuited --list-perspectives
if [ "$RUN_RC" -ne 0 ] && grep -q "unknown mode 'distribuited'" "$TMP/mode-list.log"; then
  ok "--list-perspectives 経路でも不正な mode を拒否する"
else
  bad "--list-perspectives で不正な mode が rc=0 の確認になった（rc=${RUN_RC}）"
  sed 's/^/    /' "$TMP/mode-list.log" >&2
fi
run "$TMP/mode-list-ok.log" -- --list-perspectives
if [ "$RUN_RC" -eq 0 ] && grep -q 'code-review' "$TMP/mode-list-ok.log"; then
  ok "mode 未指定の --list-perspectives は従来どおり一覧を返す"
else
  bad "--list-perspectives が退行した（rc=${RUN_RC}）"
  sed 's/^/    /' "$TMP/mode-list-ok.log" >&2
fi

echo ""
echo "-- 副なし既定構成の未カバー観点（Issue #699） --"
# 副が居ない既定構成では総合観点が誰にも割り当てられずプランが 1 件少なくなる。
# 既定で主へ回さないのは同一モデル二重レビューの回避（設計判断）だが、走らない
# ことは名乗る — 何も出ないと件数が少ない理由が実行ログから復元できない。
run "$TMP/nosub-uncovered.log" MULTI_AGENT_REVIEW_SUB= -- --dry-run
if [ "$RUN_RC" -eq 0 ] \
  && grep -q "comprehensive-review — no reviewer; not covered in this run" "$TMP/nosub-uncovered.log"; then
  ok "副なし既定構成で未カバーの総合観点を名指しする"
else
  bad "総合観点が無言で落ちている（rc=${RUN_RC}）— プランの件数差が説明されない"
  sed 's/^/    /' "$TMP/nosub-uncovered.log" >&2
fi
# 名指しは「捨てた」だけで、主へ二重に載せないこと（設計判断の固定）。
if [ "$(grep -c '^  - comprehensive-review$' "$TMP/nosub-uncovered.log" || true)" -eq 0 ]; then
  ok "未カバーの総合観点をプランへ載せない（同一モデル二重レビューを避ける既定）"
else
  bad "総合観点がプランに載っている（副なしの既定では主へ回さない設計）"
  sed 's/^/    /' "$TMP/nosub-uncovered.log" >&2
fi
# 副が居る通常構成では名指しが出ないこと（常時表示の雑音にしない）。
run "$TMP/withsub-quiet.log" -- --dry-run
# 否定 grep だけだと早期失敗・分岐未到達でも緑になる。rc と既定プランの一致も見る。
if [ "$RUN_RC" -eq 0 ] \
  && [ -n "$(plan_lines "$TMP/withsub-quiet.log")" ] \
  && [ "$(plan_lines "$TMP/pair.log")" = "$(plan_lines "$TMP/withsub-quiet.log")" ] \
  && ! grep -q "not covered in this run" "$TMP/withsub-quiet.log"; then
  ok "副が居る構成では未カバー通知を出さない（既定実行の出力とプランを変えない）"
else
  bad "副が居るのに未カバー通知が出ている、または既定プランが変わった（rc=${RUN_RC}）"
  sed 's/^/    /' "$TMP/withsub-quiet.log" >&2
fi

echo ""
echo "-- 除外と ↪ 宣言の順序（Issue #699） --"
# `--perspective X --exclude-perspective X`（副なし）で「主に回した」と宣言した
# 直後に捨てる矛盾出力になっていた。除外判定を宣言より前に置く。
run "$TMP/excl-order.log" MULTI_AGENT_REVIEW_SUB= -- \
  --perspective comprehensive-review --exclude-perspective comprehensive-review --dry-run
# 否定 grep だけにしない。この組合せは空プランで rc!=0 になるのが正しい挙動なので、
# 「空プランで中断した」ことまで確かめて、別の失敗で緑になる経路を塞ぐ。
if [ "$RUN_RC" -ne 0 ] \
  && grep -q 'Execution plan is empty' "$TMP/excl-order.log" \
  && ! grep -q '↪ comprehensive-review → ' "$TMP/excl-order.log"; then
  ok "除外された観点に「主へ回した」の宣言行が出ない（空プランとして中断する）"
else
  bad "除外した観点を「主へ回した」と宣言している、または中断していない（rc=${RUN_RC}）"
  sed 's/^/    /' "$TMP/excl-order.log" >&2
fi
# 矛盾した宣言を消したぶん、除外が原因のときは空プラン診断がそれを名指しすること。
# 名指しが無いと、利用者は原因でないつまみ（--cli / --perspective / --mode）だけを
# 示され、実際の原因である --exclude-perspective が候補に挙がらない。
if grep -q -- '--exclude-perspective (comprehensive-review) removed perspective' "$TMP/excl-order.log" \
  && grep -q -- 'Check --cli / --perspective / --exclude-perspective / --mode' "$TMP/excl-order.log"; then
  ok "空プラン診断が原因の --exclude-perspective を名指しする"
else
  bad "空プラン診断が除外を名指ししない（原因でないつまみだけを指している）"
  sed 's/^/    /' "$TMP/excl-order.log" >&2
fi
# 除外していなければ従来どおり宣言が出ること（宣言そのものを消していない）。
run "$TMP/excl-none.log" MULTI_AGENT_REVIEW_SUB= -- --perspective comprehensive-review --dry-run
if [ "$RUN_RC" -eq 0 ] && grep -q '↪ comprehensive-review → ' "$TMP/excl-none.log"; then
  ok "除外していなければ「主へ回した」の宣言は従来どおり出る"
else
  bad "除外なしの明示指定で宣言行が消えた（rc=${RUN_RC}）"
  sed 's/^/    /' "$TMP/excl-none.log" >&2
fi

# ── cross_review 設定（単一固定のオプトイン） ─────────────────────────────
#
# 別 CLI が在るときにスキル層がクロスレビューを 1 本加えるか（auto）／常に主担当のみか（off）のオプトイン。
# orchestrator は 3 層（env > project config > user config）で解決して
# --print-reviewers に **表示するだけ**で、プラン・縮退警告・レポート行は変えない
# （分岐はスキル層）。ここで固定するのは (1) 解決と出所、(2) 保存の部分更新、
# (3) 不正値の入口ごとの拒否、(4) 「挙動を変えない」の完全比較、の 4 点。
# 表示側だけ書くと「常に off と表示する」実装でも緑になるので、既定 auto の
# 正常系と precedence を先に主張する。

echo ""
echo "-- cross_review: 既定と旧形式ファイルの互換 --"
reset_config
run "$TMP/cr-default.log" -- --print-reviewers
if [ "$RUN_RC" -eq 3 ] \
  && grep -q '^cross_review=auto$' "$TMP/cr-default.log" \
  && grep -q '^cross_review_source=unset$' "$TMP/cr-default.log"; then
  ok "未設定なら cross_review=auto / cross_review_source=unset を表示し、exit 3 は変わらない"
else
  bad "未設定時の cross_review 表示が期待と違う（rc=${RUN_RC}）"
  sed 's/^/    /' "$TMP/cr-default.log" >&2
fi
# 新しい 2 行は既存行の**後ろ**（source= の直後、available= の前）。既存行の並びと
# 綴り（`^main=` 等の grep 契約）を変えないことを、行番号ではなく相対順で固定する。
if [ "$(grep -n -E '^(source|cross_review|cross_review_source|available)=' "$TMP/cr-default.log" | cut -d: -f2- | cut -d= -f1 | tr '\n' ' ')" = "source cross_review cross_review_source available " ]; then
  ok "cross_review の 2 行は source= の直後・available= の前に並ぶ（既存行順は不変）"
else
  bad "--print-reviewers の行順が期待と違う"
  sed 's/^/    /' "$TMP/cr-default.log" >&2
fi
# 旧形式（3 行目が無い）の手書きファイルは cross_review 未設定として読む。
mkdir -p "$CFG/ff-dev-toolkit"
printf '%s\n' 'main=claude-code' 'sub=codex-cli' > "$CFG/ff-dev-toolkit/reviewers"
run "$TMP/cr-legacy.log" -- --print-reviewers
if [ "$RUN_RC" -eq 0 ] \
  && grep -q '^main=claude-code$' "$TMP/cr-legacy.log" \
  && grep -q '^cross_review=auto$' "$TMP/cr-legacy.log" \
  && grep -q '^cross_review_source=unset$' "$TMP/cr-legacy.log"; then
  ok "cross_review 行の無い旧形式ファイルは unset として読める（後方互換）"
else
  bad "旧形式ファイルの読み出しが壊れている（rc=${RUN_RC}）"
  sed 's/^/    /' "$TMP/cr-legacy.log" >&2
fi

echo ""
echo "-- cross_review: 保存と部分更新 --"
run "$TMP/cr-base.log" -- --set-reviewers main=claude-code,sub=codex-cli
# 選んでいないときは 3 行目を書かない（unset のまま）。書いてしまうと出所が
# user config に化けて「利用者が選んでいない」事実が消える。
if [ "$RUN_RC" -eq 0 ] \
  && ! grep -q '^cross_review=' "$CFG/ff-dev-toolkit/reviewers" \
  && grep -q 'Saved reviewers: main=claude-code sub=codex-cli cross_review=auto' "$TMP/cr-base.log"; then
  ok "cross_review を指定しない保存はファイルに行を足さず、✅ 行は実効値 auto を出す"
else
  bad "cross_review 未指定の保存でファイル形式または ✅ 行が期待と違う（rc=${RUN_RC}）"
  sed 's/^/    /' "$TMP/cr-base.log" >&2
  sed 's/^/    | /' "$CFG/ff-dev-toolkit/reviewers" >&2
fi
run "$TMP/cr-setoff.log" -- --set-reviewers cross_review=off
if [ "$RUN_RC" -eq 0 ] \
  && grep -q '^main=claude-code$' "$CFG/ff-dev-toolkit/reviewers" \
  && grep -q '^sub=codex-cli$' "$CFG/ff-dev-toolkit/reviewers" \
  && grep -q '^cross_review=off$' "$CFG/ff-dev-toolkit/reviewers" \
  && grep -q 'Saved reviewers: main=claude-code sub=codex-cli cross_review=off' "$TMP/cr-setoff.log"; then
  ok "cross_review=off 単独の保存が通り、主・副は保存済みの値を引き継ぐ"
else
  bad "cross_review=off 単独の保存が失敗、または主・副が消えた（rc=${RUN_RC}）"
  sed 's/^/    /' "$TMP/cr-setoff.log" >&2
  sed 's/^/    | /' "$CFG/ff-dev-toolkit/reviewers" >&2 || true
fi
run "$TMP/cr-print-off.log" -- --print-reviewers
if [ "$RUN_RC" -eq 0 ] \
  && grep -q '^main=claude-code$' "$TMP/cr-print-off.log" \
  && grep -q '^sub=codex-cli$' "$TMP/cr-print-off.log" \
  && grep -q '^cross_review=off$' "$TMP/cr-print-off.log" \
  && grep -q '^cross_review_source=user config$' "$TMP/cr-print-off.log"; then
  ok "保存後は cross_review=off / cross_review_source=user config を読み出せ、exit 0 は変わらない"
else
  bad "保存した cross_review を読み出せない（rc=${RUN_RC}）"
  sed 's/^/    /' "$TMP/cr-print-off.log" >&2
fi
# `main=X` だけの再保存で off が消えない（sub の引き継ぎと同じ部分更新の作法）。
run "$TMP/cr-keep.log" -- --set-reviewers main=claude-code
rc_keep=$RUN_RC
run "$TMP/cr-keep-print.log" -- --print-reviewers
# 保存の rc と ✅ 行も見る — 見ないと「保存が失敗して前の値が残った」回も緑になる
# （pr-test-analyzer の変異実測で空振りを確認）。
if [ "$rc_keep" -eq 0 ] && [ "$RUN_RC" -eq 0 ] \
  && grep -q 'Saved reviewers: main=claude-code sub=codex-cli cross_review=off' "$TMP/cr-keep.log" \
  && grep -q '^cross_review=off$' "$CFG/ff-dev-toolkit/reviewers" \
  && grep -q '^sub=codex-cli$' "$TMP/cr-keep-print.log" \
  && grep -q '^cross_review=off$' "$TMP/cr-keep-print.log"; then
  ok "main= だけの再保存は保存済みの cross_review=off（と sub）を引き継ぐ"
else
  bad "main= だけの再保存で cross_review が消えた（rc=${RUN_RC}）"
  sed 's/^/    /' "$TMP/cr-keep-print.log" >&2
fi
# auto へ戻す経路も通ること（off しか書けない実装を弾く）。
run "$TMP/cr-setauto.log" -- --set-reviewers cross_review=auto
rc_auto=$RUN_RC
run "$TMP/cr-print-auto.log" -- --print-reviewers
if [ "$rc_auto" -eq 0 ] && [ "$RUN_RC" -eq 0 ] \
  && grep -q '^cross_review=auto$' "$TMP/cr-print-auto.log" \
  && grep -q '^cross_review_source=user config$' "$TMP/cr-print-auto.log"; then
  ok "cross_review=auto の明示保存は出所 user config で auto を返す（unset と区別される）"
else
  bad "cross_review=auto の明示保存が期待と違う（rc=${RUN_RC}）"
  sed 's/^/    /' "$TMP/cr-print-auto.log" >&2
fi
# 主が保存されていない状態でも cross_review 単独は保存できる（受け入れ条件:
# main= の有無を問わない）。読み戻しは主未設定（exit 3）+ cross_review=off。
reset_config
run "$TMP/cr-nomain.log" -- --set-reviewers cross_review=off
if [ "$RUN_RC" -eq 0 ] \
  && grep -q '^main=$' "$CFG/ff-dev-toolkit/reviewers" \
  && grep -q '^cross_review=off$' "$CFG/ff-dev-toolkit/reviewers"; then
  ok "引き継ぐ主が無くても cross_review 単独の保存が通り、main は空のまま書かれる"
else
  bad "主なしの cross_review 単独の保存が失敗した（rc=${RUN_RC}）"
  sed 's/^/    /' "$TMP/cr-nomain.log" >&2
  sed 's/^/    | /' "$CFG/ff-dev-toolkit/reviewers" >&2 || true
fi
run "$TMP/cr-nomain-print.log" -- --print-reviewers
if [ "$RUN_RC" -eq 3 ] \
  && grep -q '^main=$' "$TMP/cr-nomain-print.log" \
  && grep -q '^cross_review=off$' "$TMP/cr-nomain-print.log" \
  && grep -q '^cross_review_source=user config$' "$TMP/cr-nomain-print.log"; then
  ok "主未設定 + cross_review=off は exit 3（主未設定）のまま off を出所 user config で読み戻す"
else
  bad "主未設定 + cross_review=off の読み戻しが期待と違う（rc=${RUN_RC}）"
  sed 's/^/    /' "$TMP/cr-nomain-print.log" >&2
fi
# 明示した空値は「解除」ではなく拒否（契約は auto | off の 2 値。解除は cross_review=auto）。
run "$TMP/cr-empty.log" -- --set-reviewers cross_review=
if [ "$RUN_RC" -ne 0 ] && grep -q 'cross_review= needs a value' "$TMP/cr-empty.log" \
  && grep -q '^cross_review=off$' "$CFG/ff-dev-toolkit/reviewers"; then
  ok "cross_review= の空値は非 0 で拒否され、保存済みの off は変わらない"
else
  bad "cross_review= の空値が通った、または保存値が変わった（rc=${RUN_RC}）"
  sed 's/^/    /' "$TMP/cr-empty.log" >&2
fi

echo ""
echo "-- cross_review: 不正値の拒否（入口ごと） --"
run "$TMP/cr-base2.log" -- --set-reviewers main=claude-code,sub=codex-cli,cross_review=off
run "$TMP/cr-badset.log" -- --set-reviewers cross_review=maybe
if [ "$RUN_RC" -ne 0 ] \
  && grep -q "unknown cross_review value: 'maybe'" "$TMP/cr-badset.log" \
  && grep -q '^cross_review=off$' "$CFG/ff-dev-toolkit/reviewers"; then
  ok "--set-reviewers cross_review=maybe を値を名指しして拒否し、既存の設定を壊さない"
else
  bad "不正な cross_review 値が保存された、または値を名乗らない（rc=${RUN_RC}）"
  sed 's/^/    /' "$TMP/cr-badset.log" >&2
fi
run "$TMP/cr-badkey.log" -- --set-reviewers main=claude-code,cross-review=off
if [ "$RUN_RC" -ne 0 ] && grep -q "unknown reviewer key: 'cross-review'" "$TMP/cr-badkey.log" \
  && grep -q 'expected main=, sub= or cross_review=' "$TMP/cr-badkey.log"; then
  ok "キーの綴り間違いは拒否し、エラー文が cross_review= を候補に挙げる"
else
  bad "未知キーの拒否メッセージが cross_review= を案内しない（rc=${RUN_RC}）"
  sed 's/^/    /' "$TMP/cr-badkey.log" >&2
fi
run "$TMP/cr-badenv.log" MULTI_AGENT_CROSS_REVIEW=maybe -- --print-reviewers
if [ "$RUN_RC" -eq 1 ] \
  && grep -q "unknown cross_review value: 'maybe'" "$TMP/cr-badenv.log" \
  && grep -q 'MULTI_AGENT_CROSS_REVIEW' "$TMP/cr-badenv.log"; then
  ok "env の不正値は出所（MULTI_AGENT_CROSS_REVIEW）付きで exit 1 に拒否する"
else
  bad "env の不正な cross_review 値が通った、または出所を名乗らない（rc=${RUN_RC}）"
  sed 's/^/    /' "$TMP/cr-badenv.log" >&2
fi
# 解決は --dry-run（プラン構築）経路でも同じ関数を通る。表示経路だけ検証する
# 実装だと、実行時に不正値が黙って auto 扱いになる。
run "$TMP/cr-badenv-run.log" MULTI_AGENT_CROSS_REVIEW=maybe -- --dry-run
if [ "$RUN_RC" -ne 0 ] && grep -q "unknown cross_review value: 'maybe'" "$TMP/cr-badenv-run.log"; then
  ok "プラン構築経路でも env の不正値を拒否する"
else
  bad "--dry-run で env の不正な cross_review 値が通った（rc=${RUN_RC}）"
  sed 's/^/    /' "$TMP/cr-badenv-run.log" >&2
fi
printf '%s\n' 'main=claude-code' 'sub=codex-cli' 'cross_review=maybe' > "$CFG/ff-dev-toolkit/reviewers"
run "$TMP/cr-badfile.log" -- --print-reviewers
if [ "$RUN_RC" -eq 1 ] \
  && grep -q "unknown cross_review value: 'maybe'" "$TMP/cr-badfile.log" \
  && grep -q 'user config' "$TMP/cr-badfile.log"; then
  ok "手編集した user config の不正値も出所付きで拒否する"
else
  bad "手編集ファイルの不正な cross_review 値が通った（rc=${RUN_RC}）"
  sed 's/^/    /' "$TMP/cr-badfile.log" >&2
fi
# 壊れた 3 行目を `main=X` の再保存で引き継いで書き戻す経路も塞ぐ。
run "$TMP/cr-badcarry.log" -- --set-reviewers main=claude-code
if [ "$RUN_RC" -ne 0 ] && grep -q "unknown cross_review value: 'maybe'" "$TMP/cr-badcarry.log"; then
  ok "壊れた保存値を main= の再保存で引き継がない（書き戻す前に拒否する）"
else
  bad "壊れた cross_review 値が再保存で引き継がれた（rc=${RUN_RC}）"
  sed 's/^/    /' "$TMP/cr-badcarry.log" >&2
fi
if [ "$YQ_AVAILABLE" = "true" ]; then
  printf '%s\n' 'main=claude-code' 'sub=codex-cli' > "$CFG/ff-dev-toolkit/reviewers"
  mkdir -p "$REPO/.claude"
  cat > "$REPO/.claude/agent-config.yaml" <<'YAML'
version: "2.0"
review:
  cross_review: maybe
YAML
  run "$TMP/cr-badyaml.log" -- --print-reviewers
  if [ "$RUN_RC" -eq 1 ] \
    && grep -q "unknown cross_review value: 'maybe'" "$TMP/cr-badyaml.log" \
    && grep -q 'review.cross_review' "$TMP/cr-badyaml.log"; then
    ok "プロジェクト設定の不正値も出所キー付きで拒否する"
  else
    bad "プロジェクト設定の不正な cross_review 値が通った（rc=${RUN_RC}）"
    sed 's/^/    /' "$TMP/cr-badyaml.log" >&2
  fi
  # YAML の自然な書き方 `cross_review: false` は yq の `//` で「無い」扱いになり、黙って
  # auto へ化ける経路があった（silent-failure-hunter 指摘）。false は名指しで拒否する。
  cat > "$REPO/.claude/agent-config.yaml" <<'YAML'
version: "2.0"
review:
  cross_review: false
YAML
  run "$TMP/cr-falseyaml.log" -- --print-reviewers
  if [ "$RUN_RC" -eq 1 ] \
    && grep -q "unknown cross_review value: 'false'" "$TMP/cr-falseyaml.log"; then
    ok "プロジェクト設定の cross_review: false は未設定に化けず、'false' を名指しして拒否する"
  else
    bad "cross_review: false が黙って通った（rc=${RUN_RC}）"
    sed 's/^/    /' "$TMP/cr-falseyaml.log" >&2
  fi
  rm -rf "$REPO/.claude"
else
  ok "○ yq 不在のためプロジェクト設定の cross_review 不正値検査はスキップ"
fi

# 手編集ファイルの未知キー（typo）は行を名指しして警告し、読み取りは止めない。
printf '%s\n' 'main=claude-code' 'sub=codex-cli' 'cross-review=off' > "$CFG/ff-dev-toolkit/reviewers"
run "$TMP/cr-typo.log" -- --print-reviewers
if [ "$RUN_RC" -eq 0 ] \
  && grep -q "ignoring unknown key 'cross-review'" "$TMP/cr-typo.log" \
  && grep -q '^cross_review=auto$' "$TMP/cr-typo.log"; then
  ok "保存ファイルの未知キー 'cross-review' は警告付きで読み飛ばされ、exit 0 のまま"
else
  bad "保存ファイルの未知キーが黙って捨てられた（rc=${RUN_RC}）"
  sed 's/^/    /' "$TMP/cr-typo.log" >&2
fi
printf '%s\n' 'main=claude-code' 'sub=codex-cli' 'cross_review=off' 'cross_review=auto' > "$CFG/ff-dev-toolkit/reviewers"
run "$TMP/cr-dup.log" -- --print-reviewers
if [ "$RUN_RC" -eq 0 ] \
  && grep -q "duplicate key 'cross_review'" "$TMP/cr-dup.log" \
  && grep -q '^cross_review=auto$' "$TMP/cr-dup.log"; then
  ok "保存ファイルの重複キーは警告され、最後の値が勝つ"
else
  bad "保存ファイルの重複キーが黙って処理された（rc=${RUN_RC}）"
  sed 's/^/    /' "$TMP/cr-dup.log" >&2
fi
# 上位層（env）が勝っていても、保存ファイルの不正値はその場で検証される（上位層を
# 外した瞬間に「突然の exit 1」になる遅延を作らない）。
printf '%s\n' 'main=claude-code' 'sub=codex-cli' 'cross_review=maybe' > "$CFG/ff-dev-toolkit/reviewers"
MULTI_AGENT_CROSS_REVIEW=off run "$TMP/cr-lower-bad.log" -- --print-reviewers
if [ "$RUN_RC" -eq 1 ] \
  && grep -q "unknown cross_review value: 'maybe'" "$TMP/cr-lower-bad.log" \
  && grep -q 'Repair it with: --set-reviewers cross_review=auto' "$TMP/cr-lower-bad.log"; then
  ok "env が勝っていても保存ファイルの不正値は検証され、修復コマンドが案内される"
else
  bad "上位層が在るときに保存ファイルの不正値が見逃された（rc=${RUN_RC}）"
  sed 's/^/    /' "$TMP/cr-lower-bad.log" >&2
fi

# 大文字は受理しない（契約は小文字 2 値。正規化を足す「親切な」変更で受理集合が黙って広がるのを止める）。
run "$TMP/cr-upper.log" -- --set-reviewers cross_review=OFF
if [ "$RUN_RC" -ne 0 ] && grep -q "unknown cross_review value: 'OFF'" "$TMP/cr-upper.log"; then
  ok "cross_review=OFF（大文字）は拒否される"
else
  bad "cross_review=OFF が通った（rc=${RUN_RC}）"
  sed 's/^/    /' "$TMP/cr-upper.log" >&2
fi
# 手編集で `key = value` と空白を入れた行はキーが 'cross_review ' になる。黙って auto に
# 化けず、未知キーとして行を名指しする。
printf '%s\n' 'main=claude-code' 'sub=codex-cli' 'cross_review = off' > "$CFG/ff-dev-toolkit/reviewers"
run "$TMP/cr-spaced.log" -- --print-reviewers
if [ "$RUN_RC" -eq 0 ] \
  && grep -q "ignoring unknown key 'cross_review '" "$TMP/cr-spaced.log" \
  && grep -q '^cross_review=auto$' "$TMP/cr-spaced.log"; then
  ok "空白入りの 'cross_review = off' は未知キーとして警告され、黙って auto に化けない"
else
  bad "空白入りキーが黙って読み飛ばされた（rc=${RUN_RC}）"
  sed 's/^/    /' "$TMP/cr-spaced.log" >&2
fi
# review 専用の設定だが resolve_reviewer_pair は全タスクで走る（MULTI_AGENT_REVIEW_MAIN と
# 同じ契約）。不正値は explore でも exit 1 — 現状の契約を固定し、変えるなら意図的に変える。
reset_config
set +e
(
  cd "$REPO"
  run_isolated env PATH="$STUB:/usr/bin:/bin" XDG_CONFIG_HOME="$CFG" HOME="$TMP/home" \
    MULTI_AGENT_CROSS_REVIEW=maybe bash "$MULTI_AGENT" --task explore --description "probe" --dry-run
) >"$TMP/cr-explore-bad.log" 2>&1
rc_explore=$?
set -e
if [ "$rc_explore" -eq 1 ] && grep -q "unknown cross_review value: 'maybe'" "$TMP/cr-explore-bad.log"; then
  ok "不正な MULTI_AGENT_CROSS_REVIEW は review 以外のタスク（explore）でも exit 1 で名指し拒否される"
else
  bad "explore タスクでの不正 cross_review の扱いが契約と違う（rc=${rc_explore}）"
  sed 's/^/    /' "$TMP/cr-explore-bad.log" >&2
fi

echo ""
echo "-- cross_review: 3 層解決の優先順位 --"
run "$TMP/cr-prec-base.log" -- --set-reviewers main=claude-code,sub=codex-cli,cross_review=off
if [ "$YQ_AVAILABLE" = "true" ]; then
  mkdir -p "$REPO/.claude"
  cat > "$REPO/.claude/agent-config.yaml" <<'YAML'
version: "2.0"
review:
  cross_review: auto
YAML
  run "$TMP/cr-proj.log" -- --print-reviewers
  if [ "$RUN_RC" -eq 0 ] \
    && grep -q '^cross_review=auto$' "$TMP/cr-proj.log" \
    && grep -q '^cross_review_source=project config$' "$TMP/cr-proj.log" \
    && grep -q '^main=claude-code$' "$TMP/cr-proj.log"; then
    ok "プロジェクト設定（auto）がユーザーグローバル（off）より優先され、主・副は user config のまま"
  else
    bad "cross_review の project config > user config が壊れている（rc=${RUN_RC}）"
    sed 's/^/    /' "$TMP/cr-proj.log" >&2
  fi
  # 利用者が実際に書く値は off。yaml 層の驚き（真偽値の扱い等）は off でだけ出るので、
  # 実 yq で off を通す経路を持つ。
  cat > "$REPO/.claude/agent-config.yaml" <<'YAML'
version: "2.0"
review:
  cross_review: off
YAML
  run "$TMP/cr-proj-off.log" -- --print-reviewers
  if [ "$RUN_RC" -eq 0 ] \
    && grep -q '^cross_review=off$' "$TMP/cr-proj-off.log" \
    && grep -q '^cross_review_source=project config$' "$TMP/cr-proj-off.log"; then
    ok "プロジェクト設定の cross_review: off は実 yq で off / project config と読まれる"
  else
    bad "プロジェクト設定の cross_review: off が読まれない（rc=${RUN_RC}）"
    sed 's/^/    /' "$TMP/cr-proj-off.log" >&2
  fi
  cat > "$REPO/.claude/agent-config.yaml" <<'YAML'
version: "2.0"
review:
  cross_review: auto
YAML
  run "$TMP/cr-env.log" MULTI_AGENT_CROSS_REVIEW=off -- --print-reviewers
  if [ "$RUN_RC" -eq 0 ] \
    && grep -q '^cross_review=off$' "$TMP/cr-env.log" \
    && grep -q '^cross_review_source=env$' "$TMP/cr-env.log"; then
    ok "env（off）がプロジェクト設定（auto）より優先される"
  else
    bad "cross_review の env > project config が壊れている（rc=${RUN_RC}）"
    sed 's/^/    /' "$TMP/cr-env.log" >&2
  fi
  rm -rf "$REPO/.claude"
else
  ok "○ yq 不在のためプロジェクト設定の優先順位検査はスキップ"
fi
run "$TMP/cr-env-user.log" MULTI_AGENT_CROSS_REVIEW=auto -- --print-reviewers
if [ "$RUN_RC" -eq 0 ] \
  && grep -q '^cross_review=auto$' "$TMP/cr-env-user.log" \
  && grep -q '^cross_review_source=env$' "$TMP/cr-env-user.log" \
  && grep -q '^main_source=user config$' "$TMP/cr-env-user.log"; then
  ok "env（auto）がユーザーグローバル（off）より優先され、主・副の出所は独立に user config のまま"
else
  bad "cross_review の env > user config、または main/sub との独立性が壊れている（rc=${RUN_RC}）"
  sed 's/^/    /' "$TMP/cr-env-user.log" >&2
fi
# 空文字の env は「未設定」（副の `MULTI_AGENT_REVIEW_SUB=` とは違い、空に意味を
# 持たせない）。下位層の off がそのまま見えること。
run "$TMP/cr-env-empty.log" MULTI_AGENT_CROSS_REVIEW= -- --print-reviewers
if [ "$RUN_RC" -eq 0 ] \
  && grep -q '^cross_review=off$' "$TMP/cr-env-empty.log" \
  && grep -q '^cross_review_source=user config$' "$TMP/cr-env-empty.log"; then
  ok "空文字の env は未設定として下位層（user config）へ落ちる"
else
  bad "空文字の MULTI_AGENT_CROSS_REVIEW が下位層を隠している（rc=${RUN_RC}）"
  sed 's/^/    /' "$TMP/cr-env-empty.log" >&2
fi
# 主が未設定で cross_review だけが在るファイル（exit 3 の契約が変わらないこと）。
printf '%s\n' 'main=' 'sub=' 'cross_review=off' > "$CFG/ff-dev-toolkit/reviewers"
run "$TMP/cr-only.log" -- --print-reviewers
if [ "$RUN_RC" -eq 3 ] \
  && grep -q '^main=$' "$TMP/cr-only.log" \
  && grep -q '^cross_review=off$' "$TMP/cr-only.log" \
  && grep -q '^cross_review_source=user config$' "$TMP/cr-only.log"; then
  ok "cross_review だけが在って主が無ければ exit 3 のまま（終了コードの契約は主の有無だけで決まる）"
else
  bad "cross_review の有無が exit code に影響している（rc=${RUN_RC}）"
  sed 's/^/    /' "$TMP/cr-only.log" >&2
fi

echo ""
echo "-- cross_review: 挙動を変えない（プラン完全一致） --"
# 読み取り・表示専用の契約。plan_lines（CLI と観点の並び）だけでなく dry-run の
# 出力**全体**を突き合わせる — 縮退警告・ℹ️ 行・レポート行のどれか 1 行でも
# 増減すれば落ちる。dry-run の出力は決定的（時刻・乱数を含まない）なので byte
# 一致で比較できる。空同士の一致は vacuous pass なので非空も主張する。
printf '%s\n' 'main=claude-code' 'sub=codex-cli' > "$CFG/ff-dev-toolkit/reviewers"
run "$TMP/cr-plan-unset.log" -- --dry-run
rc_unset=$RUN_RC
printf '%s\n' 'main=claude-code' 'sub=codex-cli' 'cross_review=off' > "$CFG/ff-dev-toolkit/reviewers"
run "$TMP/cr-plan-off.log" -- --dry-run
if [ "$rc_unset" -eq 0 ] && [ "$RUN_RC" -eq 0 ] \
  && [ -n "$(plan_lines "$TMP/cr-plan-off.log")" ] \
  && cmp -s "$TMP/cr-plan-unset.log" "$TMP/cr-plan-off.log"; then
  ok "cross_review=off の pair プランは未設定時と出力全体が byte 一致する（挙動を変えない）"
else
  bad "cross_review=off が dry-run の出力を変えている（rc=${rc_unset}/${RUN_RC}）"
  diff "$TMP/cr-plan-unset.log" "$TMP/cr-plan-off.log" | sed 's/^/    /' >&2 || true
fi
# 既定 pair（pair.log）とも一致すること。上の 2 本が同じ形で壊れていても落ちる。
if [ "$(plan_lines "$TMP/pair.log")" = "$(plan_lines "$TMP/cr-plan-off.log")" ]; then
  ok "cross_review=off の主・副 CLI と観点の並びが既定 pair と完全一致する"
else
  bad "cross_review=off のプランが既定 pair と一致しない"
  diff <(plan_lines "$TMP/pair.log") <(plan_lines "$TMP/cr-plan-off.log") | sed 's/^/    /' >&2 || true
fi
# 単一 CLI への縮退警告（既存契約）は cross_review=off でも従来どおり出る。
# off は「スキル層がクロスレビューへ回さない」であって、orchestrator の縮退通知を
# 黙らせる設定ではない。
run "$TMP/cr-degrade.log" -- --perspective code-review --dry-run
if [ "$RUN_RC" -eq 0 ] \
  && grep -q 'Plan resolved to a single CLI (claude-code)' "$TMP/cr-degrade.log" \
  && grep -q "sub reviewer 'codex-cli' runs only 'comprehensive-review'" "$TMP/cr-degrade.log"; then
  ok "cross_review=off でも単一 CLI 縮退警告と副の脱落理由は従来どおり出る"
else
  bad "cross_review=off が縮退警告を黙らせている（rc=${RUN_RC}）"
  sed 's/^/    /' "$TMP/cr-degrade.log" >&2
fi
run "$TMP/cr-degrade-env.log" MULTI_AGENT_CROSS_REVIEW=off MULTI_AGENT_REVIEW_SUB= -- --dry-run
if [ "$RUN_RC" -eq 0 ] && grep -q 'No sub reviewer set' "$TMP/cr-degrade-env.log"; then
  ok "env cross_review=off でも副なしの縮退通知は従来どおり出る"
else
  bad "env cross_review=off が副なしの縮退通知を消している（rc=${RUN_RC}）"
  sed 's/^/    /' "$TMP/cr-degrade-env.log" >&2
fi
# --help が新キーを案内すること（保存の入口が発見できないと設定は存在しないに等しい）。
run "$TMP/cr-help.log" -- --help
if [ "$RUN_RC" -eq 0 ] && grep -q -- '--set-reviewers' "$TMP/cr-help.log" \
  && grep -q 'cross_review=auto|off' "$TMP/cr-help.log"; then
  ok "--help が --set-reviewers の cross_review=auto|off を案内する"
else
  bad "--help に cross_review の案内が無い（rc=${RUN_RC}）"
fi
run "$TMP/cr-restore.log" -- --set-reviewers main=claude-code,sub=codex-cli

echo ""
if [ "$FAIL" -gt 0 ]; then
  echo "✗ reviewer-pair verify: $FAIL 件失敗" >&2
  exit 1
fi
echo "✓ reviewer-pair verify: 全 $PASS 件 pass"
FF_REACHED_END=1
