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

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
MULTI_AGENT="$PLUGIN_ROOT/scripts/multi-agent.sh"
PERSPECTIVES_DIR="$PLUGIN_ROOT/scripts/perspectives/review"

[ -f "$MULTI_AGENT" ] || { echo "✗ multi-agent.sh が見つかりません" >&2; exit 1; }

PASS=0
FAIL=0
ok()  { echo "  ✓ $1"; PASS=$((PASS + 1)); }
bad() { echo "  ✗ $1" >&2; FAIL=$((FAIL + 1)); }

echo "== 主 + 副レビュワー体制 =="

if ! TMP="$(mktemp -d 2>/dev/null)"; then
  echo "○ skip: 一時ディレクトリを作成できない環境（本 suite の検査は1件も実行されていません）"
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

git init -q "$REPO"
git -C "$REPO" config user.email "test@example.com"
git -C "$REPO" config user.name "reviewer-pair-test"
git -C "$REPO" config commit.gpgsign false
git -C "$REPO" switch -q -c develop
printf '%s\n' base > "$REPO/app.txt"
git -C "$REPO" add app.txt
git -C "$REPO" commit -qm init
git -C "$REPO" switch -q -c feature/x

# 全 CLI を導入済みにする（dry-run なので stub は起動されない）
for name in claude codex copilot gemini grok; do
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
    env PATH="$STUB:/usr/bin:/bin" XDG_CONFIG_HOME="$CFG" HOME="$TMP/home" \
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
  env PATH="$NOCLI:/usr/bin:/bin" XDG_CONFIG_HOME="$CFG" HOME="$TMP/home" \
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
  env PATH="$SOLO:/usr/bin:/bin" XDG_CONFIG_HOME="$CFG" HOME="$TMP/home" \
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
  env PATH="$SOLO:/usr/bin:/bin" XDG_CONFIG_HOME="$CFG" HOME="$TMP/home" \
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
run "$TMP/envwin.log" MULTI_AGENT_REVIEW_MAIN=gemini-cli MULTI_AGENT_REVIEW_SUB=grok-cli -- --print-reviewers
if grep -q '^main=gemini-cli$' "$TMP/envwin.log" && grep -q '^source=env$' "$TMP/envwin.log"; then
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
  sub: gemini-cli
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
  env PATH="$STUB:/usr/bin:/bin" XDG_CONFIG_HOME="$CFG" HOME="$TMP/home" \
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

run "$TMP/one-main.log" MULTI_AGENT_REVIEW_MAIN=gemini-cli -- --print-reviewers
if grep -q '^main=gemini-cli$' "$TMP/one-main.log" && grep -q '^sub=codex-cli$' "$TMP/one-main.log"; then
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
if [ "$RUN_RC" -eq 0 ] \
  && grep -q '^     - code-review$' "$TMP/persp-main.log" \
  && ! grep -q 'comprehensive-review' "$TMP/persp-main.log"; then
  ok "個別観点だけを指定すると主のその観点だけが計画される"
else
  bad "個別観点の --perspective が期待どおりでない（rc=${RUN_RC}）"
fi

run "$TMP/persp-comp.log" -- --perspective comprehensive-review --dry-run
if [ "$RUN_RC" -eq 0 ] && grep -q 'codex-cli \[standard\]:' "$TMP/persp-comp.log"; then
  ok "総合観点だけを指定すると副だけが計画される"
else
  bad "総合観点の --perspective が期待どおりでない（rc=${RUN_RC}）"
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
  env PATH="$STUB:/usr/bin:/bin" XDG_CONFIG_HOME="$CFG" HOME="$TMP/home" \
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
run "$TMP/clifilter.log" -- --cli gemini-cli --dry-run
if [ "$RUN_RC" -eq 0 ] \
  && grep -q 'using the distributed plan' "$TMP/clifilter.log" \
  && grep -q 'Mode: distributed' "$TMP/clifilter.log"; then
  ok "--cli を渡したら分散へ落として通知する（黙って無視しない）"
else
  bad "--cli が pair モードで黙って無視されている（rc=${RUN_RC}）"
  sed 's/^/    /' "$TMP/clifilter.log" >&2
fi

# 落ちた先で --cli が実際に効いていること。通知だけ出して無視していたら意味がない。
if grep -q 'gemini-cli \[free-tier\]:' "$TMP/clifilter.log" \
  && ! grep -q 'comprehensive-review' "$TMP/clifilter.log"; then
  ok "落とした先の分散プランで --cli が実際に効いている"
else
  bad "分散へ落としたのに --cli が反映されていない"
fi

run "$TMP/clipair.log" -- --mode pair --cli gemini-cli --dry-run
if [ "$RUN_RC" -ne 0 ] && grep -q 'cannot be combined with --mode pair' "$TMP/clipair.log"; then
  ok "--mode pair を明示したうえでの --cli は矛盾として拒否する"
else
  bad "--mode pair + --cli が通った（rc=${RUN_RC}）"
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
  env PATH="$STUB:/usr/bin:/bin" XDG_CONFIG_HOME="$CFG" HOME="$TMP/home" \
    bash "$MULTI_AGENT" --task explore --base develop --description x --dry-run
) >"$TMP/explore.log" 2>&1
rc=$?
set -e
if [ "$rc" -eq 0 ] && grep -q 'Mode: distributed' "$TMP/explore.log"; then
  ok "explore は従来どおり分散モードのまま"
else
  bad "explore のモードが変わっている（rc=${rc}）"
fi

echo ""
if [ "$FAIL" -gt 0 ]; then
  echo "✗ reviewer-pair verify: $FAIL 件失敗" >&2
  exit 1
fi
echo "✓ reviewer-pair verify: 全 $PASS 件 pass"
FF_REACHED_END=1
