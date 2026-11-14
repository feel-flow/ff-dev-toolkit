#!/usr/bin/env bash
# 空振り検出: nativeセルフレビュー文書契約は3経路・3host mapping・固定prompt・完了条件・OS/CLI/機械ガードの境界・3入口参照を照合。49変異（見出しだけ/経路反転/host tool欠落・入替/境界欠落/旧unconditional経路復帰/read-only・完了判定反転等）と不在/不可読/空/非fileの4入力を全て赤で拒否（2026-10-29実測）。実ホストの完走は別途PRで実測する。
# 空振り検出: 明示退避のfocused対照（3hostの通常往復を除く）は最終51/0。同branch照合・全世代request・marker整合・partial lock・report-last・在庫再照合・series照合・復旧command・分類互換を個別に反転すると各4/7/1/18/7/5/2/1/2件赤（2026-10-22）。moduleとcasesの不在/不可読/空、casesの名前だけ/関数名変更は全てrc1で停止し、空集合を緑にしない。syntaxは保存SHA一致の変異sourceで個別rc0を確認。
# 空振り検出: R1復帰回帰は無変異18/0、元HEAD 69c3eb7dの不変runtimeでは5/9へ赤転（env config/base・Critical案内・detached・空fresh通知）。追加関数の不在と空のassertion集合はそれぞれrc1で停止（2026-10-22 実測）。
# 空振り検出: R2復帰回帰は22/0、修正前5a90c9a0では19/3へ赤転（非委譲full/fastのfresh案内）。full委譲のtemplate往復とfast拒否templateは保持し、非委譲2routeは案内されたfreshでrequest無しに完了する。追加関数不在・空集合は各rc1（2026-10-22 実測）。
# 空振り検出: 実hook完了レーンの退避回帰は24/0。制御directoryの退避除外を外すと22/2、活動中・不正な完了記録の検査を外すと6/18へ赤転。別copyでcase呼出だけを空化すると24件の下限照合がrc1で停止する（2026-10-28実測、Issue `#2429`）。
# git-path-isolation: 固定 PATH は実 CLI / yq / 更新 CLI の混入と不在検査の偽緑を防ぐ。
# git の親ディレクトリ全体は追加しない（同居する CLI も露出するため）。Xcode 障害時は
# DEVELOPER_DIR=/Library/Developer/CommandLineTools bash plugins/ff-dev-toolkit/tests/multi-agent-host-delegation/verify.sh
# を使う。正本: docs/04-quality/TESTING.md「ホスト git 障害時の切り分け」。
#
# multi-agent-host-delegation: claude-code レーンを CLI spawn ではなくホストのセッション内
# エージェントで走らせる選択肢。
#
# 背景: claude-code レーンは `claude` CLI を別プロセスとして起動するため、その CLI が
# ログインしているアカウントの利用枠が尽きると、ホスト側のセッションが別アカウントで
# 動き続けていてもこのレーンだけ実行できない。`claude auth` には呼び出し単位のアカウント
# 選択が無い（実測 / claude 2.1.263）ので CLI 側では解決できず、実行主体をホストへ移す
# 選択肢を足すのが本機能。
#
# 固定する契約:
#   (1) --delegate-to-host では claude-code の CLI を 1 回も起動しない（起動回数 0）
#   (2) 委譲したタスクの handoff が **stdout** に出て、prompt-file と output-file を名指しする
#   (3) 委譲待ちの終了コードは 3（失敗の 1 とは別の値。「ホストを待てばよい」と
#       「レビューが失敗した」を混同させない）
#   (4) 統合レポートが当該観点を DELEGATED として載せ、かつ INCOMPLETE を名乗る
#       （消費側ゲートはこの語で未完了を判定する）
#   (5) ホストが所定パスへ書いた結果を再実行が受理し、CLI 起動経路と同じヘッダーで保存する
#   (6) 別 HEAD の応答は新世代へ採らず、旧世代の証跡を元のパスに保つ
#   (7) レビュー本文として成立しない応答（重大度行なし）は受理しない
#   (8) `claude` が未導入でも委譲経路は成立する（観点が fallback CLI へ再配分されない）
#   (9) 既定（フラグ無し）は従来どおり CLI を起動する — 委譲は既定の挙動を変えない
#  (10) 委譲に対応しないアダプタは --delegate-dir を拒否する（効かないつまみにしない）
#  (11) review 以外の task と、対象レーンがプランに無い実行は拒否する
#  (12) --sequential 経路でも同じ（並列経路とは別実装なので、片方だけ直すと退行が隠れる）
#  (13) 失敗したレーンがあるときは終了コード 1 が 3 より優先され、handoff は出続ける
#  (14) 前回の未解消 Critical は、委譲待ちの観点について保持される（pre-push ゲートの fail-open 防止）
#  (15) 自分で incomplete / discarded を名乗る応答は受理しない（本文全体を走査する）
#  (16) 正規ヘッダー付きの応答はヘッダーを二重にせず受理する
#  (17) 採用結果を書けない実行は fail-loud で止まり、世代別のホスト応答を残す
#  (18) 応答パスの symlink は受理しない（指し先を本文として受理しない）
#  (19) 委譲を残したままフラグを落とした実行は、結果を消す前に中断する
#  (20) --fresh との併用は拒否する（回収より前に退避され収束しないため）
#  (21) 複数観点の部分受理が --resume で収束する（受理済みが再委譲されない）
#  (22) 委譲待ちのあいだに結果パスへ現れたファイルを、本文にも Critical 判定にも採らない
#  (23) 新 HEAD の応答は最初の resume で採用し、遅い旧世代の応答を混ぜない
#  (23b) 単独 adapter の legacy digest / superseded 保護も維持する
#  (27) 同 HEAD の description / wrapper route 違いは全成果物・起動数を変えず拒否する
#  (28) metadata の欠落・破損等は同 HEAD / 新 HEAD の両方で証跡を守って停止する
#  (29) state 不在の plan 外 CLI symlink は辿らず、対象レーンの実行を続ける
#  (30) 保存 manifest の委譲レーンは今回の plan 外でも unsafe symlink を拒否する
#  (31) state 保存後・dispatch 前の中断は同じ世代で再開し、次1回の応答を採用する
#  (24) 部分書き込み（ヘッダーだけ無事）を受理成功と判定しない
#  (26) codex-cli / grok-cli ホストの委譲と、ホストのレーンでない値の拒否・別レーンの未回収 handoff の保護・
#       grok ホストでの委譲案内（Issue `#2118`）
#  (25) 型付き判定行（ADR-065）の契約が委譲プロンプトに載り、型付き行だけの応答を CLI 起動
#       経路と同じ共有関数で受理する。散文だけの応答は受理せず（ADR-066）、正規形の理由で
#       退避して `<レーン>/<観点>` を名指しした拒否の診断を出す（(5a)）
#
# 変異検出: task_is_delegated を常に偽へ倒すと (1)(2)(3)(4)(8)(12) が赤。
#           review_body_present の呼び出しを外すと (7) が赤。
#           delegation_response_declares_incomplete の走査を先頭 1 段落へ戻すと (15) が赤。
#           task_left_perspective_unproven から委譲待ちを外すと (14) が赤。
#           Critical 判定ループの委譲待ちガードを外すと (22) が赤。
#           回収の「未応答の handoff があるときだけ」条件を外すと (21) が赤。
#           delegation_output_written の本文一致検査を外すと (24) が赤。
#           build_prompt の Typed Verdict Lines 見出しを外すと (25) のプロンプト検査が赤。
#           C4（ADR-066）の変異（2026-09-25 実測）: 受理モードを散文でも受理する形へ戻すと (5a) の拒否・退避と (5) が赤（4 件）。
#           拒否の診断を外すと (5a) の診断検査が赤。委譲の退避理由を正規形の定数から旧文面へ戻すと (5a) の理由検査が赤。
#           レビュー 1 巡目の fix（同日実測）: review_body_present の awk 異常終了を rc1（型付き行なし）へ畳む、または
#           委譲の退避理由を review_body_refusal_clause から正規形の固定文へ戻すと (5b) が赤。
# 空振り検出: metadata整合性拡張前の(23)(23b)(27)(28)(29)(30)は無変異34/0。同HEADの早期照合を無効化すると30/4（description/routeの無変更拒否・初回command表示・1回回復）、generationを固定すると31/3（世代分離・B初回採用・旧証跡保全）へ赤転（2026-10-22 実測）。各変異は独立fixtureへ1回だけ適用し、前後SHA256とrc・赤assertionを記録。
# 空振り検出: (29)(30)は現行2/0。全CLIを検査した修正前snapshotでは(29)だけ赤1/1、保存manifestの委譲laneを拾う条件を外す単一変異では(30)だけ赤1/1（2026-10-22 実測）。無関係なsymlinkのskipと、保存委譲laneの拒否を相互の対照として固定。
# 空振り検出: metadata整合性拡張後の(23)(28)(31)は無変異44/0。headとmanifestの照合だけを外すとvalid-headの4件が赤40/4、generationとgeneration-hashの照合だけを外すとvalid-generation/有効hash差替の8件が赤36/8（2026-10-22 実測）。同/新HEAD・元argv/description落ちを測り、新HEAD正常退役・state-only再開と次1回採用は両変異でも緑。各変異の1回適用・前後SHA256・rcを記録。
#
# 実 CLI は 1 つも起動しない（claude / codex を stub で覆う）。書き込み不可の環境では skip。

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd -P)"
# fixture リポジトリの identity を呼び出し元へ漏らさない（経緯は tests/lib/git-fixture.sh のヘッダ）
# shellcheck source=../lib/git-fixture.sh
. "$SCRIPT_DIR/../lib/git-fixture.sh"

MULTI_AGENT="$PLUGIN_ROOT/scripts/multi-agent.sh"
CLAUDE_ADAPTER="$PLUGIN_ROOT/scripts/adapters/claude-code-adapter.sh"
CODEX_ADAPTER="$PLUGIN_ROOT/scripts/adapters/codex-cli-adapter.sh"

for f in "$MULTI_AGENT" "$CLAUDE_ADAPTER" "$CODEX_ADAPTER"; do
  [ -f "$f" ] || {
    echo "✗ 対象ファイルが見つかりません: $f" >&2
    exit 1
  }
done

# 主担当 host の既定は skill 層で選ぶ。script 直接呼出の既定 CLI 契約は変えない。
NATIVE_CONTRACT="$SCRIPT_DIR/native-self-review-contract.py"
[[ ! -L "$NATIVE_CONTRACT" && -f "$NATIVE_CONTRACT" && -r "$NATIVE_CONTRACT" && -s "$NATIVE_CONTRACT" ]] || { echo '✗ native self-review contract missing/unreadable/empty' >&2; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo '✗ python3 is required for native self-review contract' >&2; exit 1; }
python3 "$NATIVE_CONTRACT" --plugin-root "$PLUGIN_ROOT" --self-test

# shellcheck source=../lib/adapter-env-isolation.sh
. "$SCRIPT_DIR/../lib/adapter-env-isolation.sh"
# shellcheck source=../lib/multi-agent-sources.sh
. "$SCRIPT_DIR/../lib/multi-agent-sources.sh"
# 抽出源は入口と構成ファイル（scripts/lib/multi-agent-*.sh）の全部。MULTI_AGENT_CROSS_REVIEW は
# 構成ファイルにだけ現れるので、構成ファイルを渡し忘れると fail-closed で止まる
ma_sources_load "${MULTI_AGENT%/*}"
build_isolate_env "MULTI_AGENT_CONFIG MULTI_AGENT_MODEL_CLAUDE_CODE MULTI_AGENT_CROSS_REVIEW" \
  "${MA_SOURCES[@]}" "$PLUGIN_ROOT"/scripts/adapters/*.sh
unset_isolated_vars

# rc=0 でも -d を検査する — 2>&1 の合流は「成功 + stderr 警告」の環境で変数へ
# 警告文が混入し、以後の処理が原因不明の失敗に化けるため。
if _ff_mktemp_out="$(mktemp -d 2>&1)" && [ -d "$_ff_mktemp_out" ]; then
  TMP="$_ff_mktemp_out"
else
  echo "○ skip: 一時ディレクトリを作成できない環境のためスキップ（検査は1件も実行されていません）"
  printf '  mktemp: %s\n' "$_ff_mktemp_out"
  exit 0
fi

FF_REACHED_END=0
_ff_exit_guard() {
  _ff_rc=$?
  rm -rf "$TMP"
  if [ "$_ff_rc" -eq 0 ] && [ "$FF_REACHED_END" -ne 1 ]; then
    echo "✗ multi-agent-host-delegation: 最後まで到達しませんでした（途中で中断）" >&2
    exit 1
  fi
  exit "$_ff_rc"
}
trap _ff_exit_guard EXIT
trap 'exit 130' HUP INT TERM

PASS=0
FAIL=0
ok()  { echo "  ✓ $1"; PASS=$((PASS + 1)); }
bad() { echo "  ✗ $1" >&2; FAIL=$((FAIL + 1)); }

# --- レビュー対象の差分を持つ一時リポジトリ ---
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
# レビュー巡回の上限（multi-agent.sh の review 本体が同じブランチの異なる HEAD を数える）は
# この suite の関心外。同じ feature/x で HEAD を進めながら review を何度も起動するので、
# 上限を 0（無効）に固定して直交させる（multi-agent-plan / guard-review-in-flight (a)〜(m) と同じ）
export FF_REVIEW_ROUND_LIMIT=0
unset FF_REVIEW_ROUND_ACK
REPO="$TMP/repo"
ff_git_fixture_init "$REPO" "host-delegation-test" "test@example.com"
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

# --- stub CLI 群 ---
# claude は**起動回数だけ**を数える。委譲経路で 1 度でも起動したら (1) が赤になる。
# codex は常に受理される最小のレビュー本文を返す（他レーンが従来どおり走ることの対照）。
STUB="$TMP/bin"
mkdir -p "$STUB"
CLAUDE_COUNT="$TMP/claude-count"
CODEX_COUNT="$TMP/codex-count"
export FF_TEST_CODEX_COUNT="$CODEX_COUNT"
: > "$CLAUDE_COUNT"
: > "$CODEX_COUNT"
cat > "$STUB/claude" <<SH
#!/usr/bin/env bash
n=\$( (cat "$CLAUDE_COUNT" 2>/dev/null || echo 0) )
echo "\$((n + 1))" > "$CLAUDE_COUNT"
cat >/dev/null
echo "- Critical: 0"
echo "- Important: 0"
echo "- verdict: none"
SH
cat > "$STUB/codex" <<'SH'
#!/usr/bin/env bash
cat >/dev/null
printf 'codex\n' >> "${FF_TEST_CODEX_COUNT:?}"
echo "- Critical: 0"
echo "- Important: 0"
echo "- verdict: none"
SH
cp "$STUB/codex" "$STUB/copilot"
cp "$STUB/codex" "$STUB/agy"
chmod +x "$STUB/claude" "$STUB/codex" "$STUB/copilot" "$STUB/agy"

# 空ファイル（起動 0 回）でも必ず数値を返す。`cat` の素の結果を使うと空文字になり、
# 比較が「0 と等しくない」へ倒れて、起動していないのに起動したと報告する。
claude_launch_count() {
  local n
  n="$(cat "$CLAUDE_COUNT" 2>/dev/null || true)"
  case "$n" in
    '' | *[!0-9]*) echo 0 ;;
    *) echo "$n" ;;
  esac
}
codex_launch_count() { wc -l < "$CODEX_COUNT" | tr -d ' '; }

# 世代の識別子は実装から作り直さず、ホストへ返したレコードから読む。
handoff_field() { # <stdout> <key> [perspective] [cli]
  awk -v key="$2" -v perspective="${3:-code-review}" -v cli="${4:-claude-code}" '
    function emit() { if (f["cli"] == cli && f["perspective"] == perspective && f[key] != "") print f[key] }
    /^--- task ---$/ { emit(); for (k in f) delete f[k]; next }
    /^<<<END-FF-DELEGATED-TASKS>>>$/ { emit(); for (k in f) delete f[k]; next }
    /^[A-Za-z-]+=/ { k=$0; sub(/=.*/, "", k); v=$0; sub(/^[^=]*=/, "", v); f[k]=v }
  ' "$1"
}
tree_hashes() { # <output-dir>。一覧と全バイトの両方を比較する（空集合も記録）。
  ( cd "$1" && find . \( -type f -o -type l \) -print | LC_ALL=C sort | while IFS= read -r file; do
      printf '%s ' "$file"
      if [ -L "$file" ]; then printf 'symlink='; readlink "$file"; else git hash-object "$file"; fi
    done )
}

# handoff は物理パス（orchestrator が OUTPUT_DIR を pwd -P で解決する）で名乗る。
# fixture の TMPDIR は macOS では /var -> /private/var の symlink 越しなので、
# $REPO の綴りのまま照合すると本文が正しくても一致しない。
REPO_PHYS="$(cd "$REPO" && pwd -P)"

# PATH は stub と最小限のシステムパスだけにする（ホストの本物の CLI を引かない）。
STUB_PATH="$STUB:/usr/bin:/bin:/usr/sbin:/sbin"

OUT_N=0
# run_ma <label> <args...> → rc を RUN_RC、stdout/stderr を RUN_OUT / RUN_ERR へ
run_ma() {
  local label="$1"; shift
  OUT_N=$((OUT_N + 1))
  RUN_OUT="$TMP/out.${OUT_N}.${label}"
  RUN_ERR="$TMP/err.${OUT_N}.${label}"
  RUN_RC=0
  run_isolated PATH="$STUB_PATH" HOME="$TMP/home" \
    FF_DEV_TOOLKIT_ROOT="$PLUGIN_ROOT" bash "${MA_ENTRY:-$MULTI_AGENT}" "$@" > "$RUN_OUT" 2> "$RUN_ERR" || RUN_RC=$?
  local prompt response
  prompt="$(handoff_field "$RUN_OUT" prompt-file)"
  response="$(handoff_field "$RUN_OUT" output-file)"
  if [ -n "$prompt" ]; then PROMPT_FILE="$prompt"; fi
  if [ -n "$response" ]; then RESPONSE_FILE="$response"; fi
}

BASE_ARGS="--task review --mode cross-model --perspective code-review --base develop"

echo "-- (1)(2)(3) 委譲は CLI を起動せず handoff を stdout へ出す --"
# shellcheck disable=SC2086 # BASE_ARGS は語分割して渡す固定の引数列
run_ma delegate1 $BASE_ARGS --cli claude-code --delegate-to-host

if [ "$(claude_launch_count)" = "0" ]; then
  ok "委譲経路で claude を 1 回も起動していない（起動回数 0）"
else
  bad "委譲経路で claude が $(claude_launch_count) 回起動した（CLI を起動しないのが本機能の前提）"
fi

if [ "$RUN_RC" -eq 3 ]; then
  ok "委譲待ちの終了コードは 3（失敗の 1 と別の値）"
else
  bad "委譲待ちの終了コードが 3 ではない: rc=${RUN_RC}"
fi

RESULT_FILE="$REPO_PHYS/.review-results/claude-code/code-review.md"
if grep -qF '<<<FF-DELEGATED-TASKS>>>' "$RUN_OUT" \
   && grep -qF '<<<END-FF-DELEGATED-TASKS>>>' "$RUN_OUT"; then
  ok "handoff ブロックが stdout に出ている"
else
  bad "handoff ブロックが stdout に無い（ホストが読む唯一の経路）"
fi
if [ -n "${PROMPT_FILE:-}" ] && [ -n "${RESPONSE_FILE:-}" ] \
   && grep -qF "prompt-file=${PROMPT_FILE}" "$RUN_OUT" \
   && grep -qF "output-file=${RESPONSE_FILE}" "$RUN_OUT" \
   && [ "$RESPONSE_FILE" = "${PROMPT_FILE%.prompt.md}.response.md" ]; then
  ok "handoff が prompt-file と output-file を絶対パスで名指ししている"
else
  bad "handoff に prompt-file / output-file が無い（ホストは何をどこへ書けばよいか分からない）"
fi
case "${RESPONSE_FILE:-}" in
  "$REPO_PHYS/.review-results/claude-code/.delegated/generations/"*'/code-review.response.md')
    ok "ホスト応答の受け皿は世代別で、canonical 結果とは別のパス" ;;
  *) bad "世代別の応答パスが handoff に無い: ${RESPONSE_FILE:-missing}" ;;
esac
if [ -s "$PROMPT_FILE" ]; then
  ok "プロンプトがファイルとして書き出されている: ${PROMPT_FILE}"
else
  bad "プロンプトファイルが空／不在: ${PROMPT_FILE}"
fi
# (25) ホストへ渡すプロンプトは CLI 起動経路と同じ build_prompt の生成物なので、型付き
# 判定行の出力契約もそのまま載っている（委譲経路だけ契約が欠けると、ホストの応答だけが
# 不受理へ落ちる）。針は見出し 1 行（折り返しをまたがない）
if grep -qF '## Typed Verdict Lines (one per finding)' "$PROMPT_FILE" \
   && grep -qF -- '- verdict: none' "$PROMPT_FILE"; then
  ok "(25) 委譲プロンプトに型付き判定行の契約（Typed Verdict Lines / verdict: none）が載っている"
else
  bad "(25) 委譲プロンプトに型付き判定行の契約が無い（ホスト経路だけ契約が欠ける）"
fi
if [ ! -e "$RESULT_FILE" ]; then
  ok "委譲待ちのあいだ結果ファイルは作られない（空振りを結果と読ませない）"
else
  bad "委譲待ちなのに結果ファイルがある: ${RESULT_FILE}"
fi

echo "-- (4) 統合レポートは DELEGATED かつ INCOMPLETE を名乗る --"
REPORT="$REPO_PHYS/.review-results/integrated-report.md"
if [ -f "$REPORT" ] && grep -qF 'DELEGATED' "$REPORT" && grep -qF 'INCOMPLETE' "$REPORT"; then
  ok "レポートが当該観点を DELEGATED / INCOMPLETE として載せている"
else
  bad "レポートに DELEGATED / INCOMPLETE が無い（未完了のレビューが完了に見える）"
fi

echo "-- (7) レビュー本文として成立しない応答は受理しない --"
printf 'looks fine to me\n' > "$RESPONSE_FILE"
# shellcheck disable=SC2086
run_ma reject $BASE_ARGS --cli claude-code --delegate-to-host
if [ "$RUN_RC" -eq 3 ] && grep -qF 'refusing it as a review result' "$RUN_ERR"; then
  ok "重大度行を含まない応答を拒否し、handoff をやり直す"
else
  bad "重大度行を含まない応答が拒否されていない（rc=${RUN_RC}）"
fi
if ls "${PROMPT_FILE%.prompt.md}".response.rejected.*.md >/dev/null 2>&1; then
  ok "拒否した応答は捨てずに退避してある（ホストが払った実行の証跡）"
else
  bad "拒否した応答の退避物が無い"
fi

echo "-- (5a) 散文だけの応答（型付き判定行なし）は受理しない（ADR-066） --"
# CLI 起動経路と同じ共有関数（review_body_present）で拒否し、応答を退避して handoff を
# やり直す。拒否の診断は `<レーン>/<観点>` のラベルで名指しされ、退避理由は不受理の
# 正規形（adapter-common.sh の REVIEW_BODY_REFUSAL_PHRASE）を展開する
rm -f "${PROMPT_FILE%.prompt.md}".response.rejected.*.md
cat > "$RESPONSE_FILE" <<'BODY'
## Summary

- Critical: 0
- Important: 1

### Important
- [app.txt:2] change is untested
BODY
# shellcheck disable=SC2086
run_ma proseonly $BASE_ARGS --cli claude-code --delegate-to-host
if [ "$RUN_RC" -eq 3 ] && grep -qF -- 'the delegated response contains no valid typed verdict line (neither a `- verdict: severity=... failure_scenario=... confidence=...` line nor `- verdict: none`) — refusing it as a review result.' "$RUN_ERR"; then
  ok "(5a) 散文だけの委譲応答を正規形の理由で拒否し、handoff をやり直す（rc=3）"
else
  bad "(5a) 散文だけの委譲応答が正規形の理由で拒否されていない（rc=${RUN_RC}）"
fi
if grep -qxF 'typed-verdict: claude-code/code-review: prose-only review refused (no valid verdict line)' "$RUN_ERR"; then
  ok "(5a) 拒否の診断が <レーン>/<観点> を名指しする"
else
  bad "(5a) 散文だけの委譲応答を拒否したのに名指しの診断が無い"
fi
if ls "${PROMPT_FILE%.prompt.md}".response.rejected.*.md >/dev/null 2>&1; then
  ok "(5a) 拒否した散文の応答は捨てずに退避してある"
else
  bad "(5a) 拒否した散文の応答の退避物が無い"
fi

echo "-- (5b) 受理判定の awk が落ちた応答は解析不能の理由で退避する（型付き判定行なしと言わない） --"
AWK5B="$TMP/awk5b"
mkdir -p "$AWK5B"
REAL_AWK5B="$(command -v awk)"
cat > "$AWK5B/awk" <<SH
#!/usr/bin/env bash
for a in "\$@"; do
  case "\$a" in ff_mode=accept) exit 2 ;; esac
done
exec "$REAL_AWK5B" "\$@"
SH
chmod +x "$AWK5B/awk"
printf -- '- Critical: 0\n- verdict: none\n' > "$RESPONSE_FILE"
REAL_STUB_PATH_5B="$STUB_PATH"
STUB_PATH="$AWK5B:$STUB_PATH"
# shellcheck disable=SC2086
run_ma unparsed5b $BASE_ARGS --cli claude-code --delegate-to-host
STUB_PATH="$REAL_STUB_PATH_5B"
if [ "$RUN_RC" -eq 3 ] && grep -qF 'the delegated response could not be parsed as a review body (the parser exited with status 2' "$RUN_ERR" \
   && ! grep -qF 'the delegated response contains no valid typed verdict line' "$RUN_ERR"; then
  ok "(5b) 解析できない委譲応答を解析不能の理由で退避する（rc=3）"
else
  bad "(5b) 解析できない委譲応答の理由が違う（rc=${RUN_RC}）"
fi

echo "-- (5) ホストの書き戻しを受理し、CLI 起動経路と同じヘッダーで保存する --"
cat > "$RESPONSE_FILE" <<'BODY'
## Summary

- Critical: 0
- Important: 1

### Important
- [app.txt:2] change is untested
  - verdict: severity=warning failure_scenario=yes confidence=85 file=app.txt line=2
BODY
# shellcheck disable=SC2086
run_ma adopt $BASE_ARGS --cli claude-code --delegate-to-host
if [ "$RUN_RC" -eq 0 ]; then
  ok "受理できた実行は rc=0（委譲待ちが解消している）"
else
  bad "受理後の rc が 0 ではない: rc=${RUN_RC}"
fi
if [ "$(claude_launch_count)" = "0" ]; then
  ok "受理の実行でも claude を起動していない"
else
  bad "受理の実行で claude が起動した（回数=$(claude_launch_count)）"
fi
# ヘッダーはファイルを awk 自身に開かせて見る。`head | grep -q` の形にすると grep の
# 早期終了が head を SIGPIPE で殺し、pipefail 下では一致が非一致へ反転する（ACE-149。
# run-all の再混入ガードが同型を赤にする）。
result_header_ok() { # <file>
  awk '
    /^$/ { exit }
    NR == 1 && /^<!-- Multi-CLI Review Result -->$/ { a = 1 }
    /^<!-- CLI: Claude Code -->$/ { b = 1 }
    /^<!-- Status: complete -->$/ { c = 1 }
    END { exit (a && b && c) ? 0 : 1 }
  ' "$1"
}
if result_header_ok "$RESULT_FILE"; then
  ok "受理した結果は write_output と同じヘッダーを持つ（レポートから CLI 起動経路と区別できない）"
else
  bad "受理した結果のヘッダーが CLI 起動経路と一致しない"
  sed -n '1,8p' "$RESULT_FILE" | sed 's/^/    /'
fi
if grep -qF 'change is untested' "$RESULT_FILE"; then
  ok "ホストが書いた本文が保存されている"
else
  bad "ホストが書いた本文が失われている"
fi
if [ -e "$PROMPT_FILE" ]; then
  bad "受理後もプロンプトが残っている（次回の滞留物になる）"
else
  ok "受理した時点で受け渡しファイルを消費している"
fi

# (5) の応答は型付き判定行を持つので、受理で typed-verdict 診断は出ない
if grep -qF 'typed-verdict:' "$RUN_ERR"; then
  bad "(5) 型付きの委譲応答の受理で typed-verdict 診断が出た: $(grep -F 'typed-verdict:' "$RUN_ERR")"
else
  ok "(5) 型付きの委譲応答の受理では typed-verdict 診断を出さない"
fi

echo "-- (25) 型付き判定行だけの応答を委譲経路でも受理する --"
# 散文の重大度行を 1 行も持たず、型付き判定行だけで成立する応答。CLI 起動経路と同じ
# 共有関数で受理されること（委譲経路だけ型付き行を知らない、の退行を赤にする）
# shellcheck disable=SC2086
run_ma handoffT $BASE_ARGS --cli claude-code --delegate-to-host
cat > "$RESPONSE_FILE" <<'BODY'
## Code Review Results

- [app.txt:2] change is untested (TYPEDONLY)
  - verdict: severity=warning failure_scenario=yes confidence=85 file=app.txt line=2
BODY
# shellcheck disable=SC2086
run_ma adoptT $BASE_ARGS --cli claude-code --delegate-to-host
if [ "$RUN_RC" -eq 0 ] && result_header_ok "$RESULT_FILE" && grep -qF 'TYPEDONLY' "$RESULT_FILE"; then
  ok "(25) 型付き判定行だけの委譲応答を受理し、同じヘッダーで保存する"
else
  bad "(25) 型付き判定行だけの委譲応答が受理されない（rc=${RUN_RC}）"
fi
if grep -qF 'typed-verdict:' "$RUN_ERR"; then
  bad "(25) 型付き経路で受理したのに typed-verdict 診断が出た: $(grep -F 'typed-verdict:' "$RUN_ERR")"
else
  ok "(25) 型付き経路の受理では拒否の診断も不採用の診断も出ない"
fi

echo "-- (6) 別 HEAD の応答は新しい世代に採らない --"
# shellcheck disable=SC2086
run_ma handoff2 $BASE_ARGS --cli claude-code --delegate-to-host
OLD_RESPONSE="$RESPONSE_FILE"
printf -- '- Critical: 0\n- verdict: none\n- OLDHEAD_ONLY\n' > "$OLD_RESPONSE"
OLD_RESPONSE_HASH="$(git hash-object "$OLD_RESPONSE")"
printf 'base\nchange\nmore\n' > app.txt
git add app.txt
git commit -qm "more"
# shellcheck disable=SC2086
run_ma stale $BASE_ARGS --cli claude-code --delegate-to-host
if [ "$RUN_RC" -eq 3 ] && [ "$RESPONSE_FILE" != "$OLD_RESPONSE" ] \
   && ! grep -qF OLDHEAD_ONLY "$REPORT"; then
  ok "入力が変わった後は別世代を handoff し、旧応答をレポートへ採らない"
else
  bad "別入力への応答が新世代へ混ざる（rc=${RUN_RC}）"
fi
if [ -f "$OLD_RESPONSE" ] && [ "$(git hash-object "$OLD_RESPONSE")" = "$OLD_RESPONSE_HASH" ]; then
  ok "受理しなかった旧世代の応答は元のパスとバイトを保つ"
else
  bad "受理しなかった旧世代の応答が改変・削除された"
fi

echo "-- (8) claude 未導入でも委譲経路は成立する（fallback 再配分が起きない）--"
# --cli claude-code で lineup を 1 本に固定すると、そもそも振替先が存在しないので
# 「振り替えられていない」の検査が構造的に必ず通る（空振り）。分散プランのまま
# `claude` 不在で走らせ、claude-code が**プランに残って自分の観点を持つ**ことを見る。
NO_CLAUDE="$TMP/bin-noclaude"
mkdir -p "$NO_CLAUDE"
cp "$STUB/codex" "$NO_CLAUDE/codex"
FRESH_OUT="$TMP/repo2-results"
run_isolated PATH="$NO_CLAUDE:/usr/bin:/bin:/usr/sbin:/sbin" HOME="$TMP/home" \
  bash "$MULTI_AGENT" --task review --mode distributed \
  --base develop --delegate-to-host --output-dir "$FRESH_OUT" \
  > "$TMP/out.noclaude" 2> "$TMP/err.noclaude" || true
if grep -qF 'claude-code — delegated to the host' "$TMP/err.noclaude"; then
  ok "claude 未導入でも claude-code は「委譲先」として可用と報告される"
else
  bad "claude 未導入だと claude-code が未導入扱いになる（委譲の指定がその状況で無効になる）"
  tail -5 "$TMP/err.noclaude" | sed 's/^/    /'
fi
# 分散プランでの claude-code の持ち観点（registry 由来）は 3 件。fallback 再配分が
# 起きていれば、この 3 件は codex-cli の結果として現れる。
NOCLAUDE_PROMPTS=0
for f in "$FRESH_OUT"/claude-code/.delegated/generations/*/*.prompt.md; do
  [ -f "$f" ] && NOCLAUDE_PROMPTS=$((NOCLAUDE_PROMPTS + 1))
done
if [ "$NOCLAUDE_PROMPTS" -ge 2 ]; then
  ok "claude 未導入でも claude-code の担当観点ぶん（${NOCLAUDE_PROMPTS} 件）のプロンプトが作られる"
else
  bad "claude 未導入で claude-code の観点が消えた（プロンプト ${NOCLAUDE_PROMPTS} 件）"
fi
NOCLAUDE_REASSIGNED=0
for f in "$FRESH_OUT"/claude-code/.delegated/generations/*/*.prompt.md; do
  [ -f "$f" ] || continue
  b="${f##*/}"; b="${b%.prompt.md}"
  [ -e "$FRESH_OUT/codex-cli/${b}.md" ] && NOCLAUDE_REASSIGNED=$((NOCLAUDE_REASSIGNED + 1))
done
if [ "$NOCLAUDE_REASSIGNED" -eq 0 ]; then
  ok "委譲レーンの観点が codex-cli へ振り替えられていない"
else
  bad "委譲レーンの観点 ${NOCLAUDE_REASSIGNED} 件が別 CLI へ振り替えられた"
fi

echo "-- (9) 既定（フラグ無し）は従来どおり CLI を起動する --"
: > "$CLAUDE_COUNT"
DEFAULT_OUT="$TMP/repo3-results"
# shellcheck disable=SC2086
run_ma default $BASE_ARGS --cli claude-code --output-dir "$DEFAULT_OUT"
if [ "$(claude_launch_count)" -ge 1 ]; then
  ok "フラグ無しでは claude を起動する（既定の挙動は変えていない）"
else
  bad "フラグ無しでも claude が起動しない（既定の挙動が変わっている）"
  tail -5 "$RUN_ERR" | sed 's/^/    /'
fi
if [ ! -d "$DEFAULT_OUT/claude-code/.delegated" ]; then
  ok "フラグ無しでは受け渡しディレクトリを作らない"
else
  bad "フラグ無しでも .delegated/ が作られている"
fi

echo "-- (10) 委譲に対応しないアダプタは --delegate-dir を拒否する --"
DENY_RC=0
run_isolated PATH="$STUB_PATH" HOME="$TMP/home" \
  bash "$PLUGIN_ROOT/scripts/adapters/copilot-cli-adapter.sh" "$PLUGIN_ROOT/perspectives/review/code-review.md" \
  "$TMP/deny.md" --base develop --delegate-dir "$TMP/deny-dir" \
  > "$TMP/out.deny" 2> "$TMP/err.deny" || DENY_RC=$?
if [ "$DENY_RC" -ne 0 ] && grep -qF 'not supported by' "$TMP/err.deny"; then
  ok "copilot-cli アダプタ（非ホストレーン）は --delegate-dir を拒否する（黙って無視しない）"
else
  bad "copilot-cli アダプタが --delegate-dir を受理した（効かないつまみ / モデル独立性の黙った喪失）"
fi

echo "-- (11) 適用範囲の外は拒否する --"
run_ma explore --task explore --description x --delegate-to-host
if [ "$RUN_RC" -ne 0 ] && grep -qF 'only valid for review tasks' "$RUN_ERR"; then
  ok "review 以外の task では拒否する"
else
  bad "explore で --delegate-to-host が通った（rc=${RUN_RC}）"
fi
# shellcheck disable=SC2086
run_ma notinplan $BASE_ARGS --cli codex-cli --delegate-to-host
if [ "$RUN_RC" -ne 0 ] && grep -qF 'is not in this plan' "$RUN_ERR"; then
  ok "対象レーンがプランに無い実行は拒否する（意図が黙って落ちない）"
else
  bad "claude-code がプランに無いのに --delegate-to-host が通った（rc=${RUN_RC}）"
fi

echo "-- (12) --sequential 経路でも同じ（並列経路とは別実装） --"
# 直前のケース (9) が意図的に claude を起動しているので、起動回数の起点を戻す。
: > "$CLAUDE_COUNT"
SEQ_OUT="$TMP/seq-results"
run_ma seq --task review --mode cross-model --perspective code-review --base develop \
  --cli claude-code --delegate-to-host --sequential --output-dir "$SEQ_OUT"
if [ "$RUN_RC" -eq 3 ] && grep -qF '<<<FF-DELEGATED-TASKS>>>' "$RUN_OUT"; then
  ok "--sequential でも委譲待ち rc=3 と handoff が成立する"
else
  bad "--sequential で委譲が成立しない（rc=${RUN_RC}）— 逐次経路は別実装なので片方だけの修正で退行が隠れる"
  tail -5 "$RUN_ERR" | sed 's/^/    /'
fi
if [ "$(claude_launch_count)" = "0" ]; then
  ok "--sequential でも claude を起動していない"
else
  bad "--sequential で claude が起動した（回数=$(claude_launch_count)）"
fi

echo "-- (13) 失敗レーンがあるときは rc=1 が rc=3 より優先され、handoff は出続ける --"
FAILSTUB="$TMP/bin-failcodex"
mkdir -p "$FAILSTUB"
cp "$STUB/claude" "$FAILSTUB/claude"
cat > "$FAILSTUB/codex" <<'SH'
#!/usr/bin/env bash
cat >/dev/null
echo "boom" >&2
exit 7
SH
chmod +x "$FAILSTUB/codex"
MIX_OUT="$TMP/mix-results"
MIX_RC=0
run_isolated PATH="$FAILSTUB:/usr/bin:/bin:/usr/sbin:/sbin" HOME="$TMP/home" \
  bash "$MULTI_AGENT" --task review --mode cross-model --perspective code-review \
  --base develop --cli claude-code --cli codex-cli --delegate-to-host \
  --output-dir "$MIX_OUT" > "$TMP/out.mix" 2> "$TMP/err.mix" || MIX_RC=$?
if [ "$MIX_RC" -eq 1 ]; then
  ok "失敗レーンがあるときの終了コードは 1（「ホストを待てばよい」と読ませない）"
else
  bad "失敗レーンがあるのに rc=${MIX_RC}（3 を返すと、失敗したレーンの再実行が落ちる）"
fi
if grep -qF '<<<FF-DELEGATED-TASKS>>>' "$TMP/out.mix"; then
  ok "失敗があっても handoff は stdout に出る（ホストは委譲分を進められる）"
else
  bad "失敗があると handoff が出ない（委譲したレーンが進めなくなる）"
fi

echo "-- (14) 前回の未解消 Critical は委譲待ちの観点について保持される --"
CRIT_OUT="$TMP/crit-results"
CRITSTUB="$TMP/bin-crit"
mkdir -p "$CRITSTUB"
cat > "$CRITSTUB/claude" <<'SH'
#!/usr/bin/env bash
cat >/dev/null
echo "### Critical Issues"
echo "- [app.txt:2] boom"
echo "  - verdict: severity=critical failure_scenario=yes confidence=90 file=app.txt line=2"
echo "- Critical: 1"
SH
chmod +x "$CRITSTUB/claude"
run_isolated PATH="$CRITSTUB:/usr/bin:/bin:/usr/sbin:/sbin" HOME="$TMP/home" \
  bash "$MULTI_AGENT" --task review --mode cross-model --perspective code-review \
  --base develop --cli claude-code --output-dir "$CRIT_OUT" \
  > "$TMP/out.crit1" 2> "$TMP/err.crit1" || true
if grep -qF -- '<!-- CRITICAL_BLOCK -->' "$CRIT_OUT/integrated-report.md" 2>/dev/null; then
  ok "前提: CLI 起動経路で CRITICAL_BLOCK が立つ"
  run_ma crit2 --task review --mode cross-model --perspective code-review --base develop \
    --cli claude-code --delegate-to-host --output-dir "$CRIT_OUT"
  if grep -qF -- '<!-- CRITICAL_BLOCK -->' "$CRIT_OUT/integrated-report.md" 2>/dev/null; then
    ok "委譲待ちの再実行でも前回の CRITICAL_BLOCK が保持される（pre-push ゲートが素通りしない）"
  else
    bad "委譲待ちの再実行で CRITICAL_BLOCK が消えた（未解消 Critical のまま push が通る fail-open）"
  fi
else
  bad "前提が崩れた: CLI 起動経路で CRITICAL_BLOCK が立たない"
fi

echo "-- (15) 自分で incomplete / discarded を名乗る応答は受理しない --"
INC_OUT="$TMP/inc-results"
run_ma inc1 --task review --mode cross-model --perspective code-review --base develop \
  --cli claude-code --delegate-to-host --output-dir "$INC_OUT"
# revision guard が破棄した成果物と同じ形（バナー前置 → 空行 → ヘッダー）。
# 先頭 1 段落しか見ない判定はここを素通りする。
cat > "$RESPONSE_FILE" <<'BODY'
> DISCARDED — the repository changed while this run was in flight.

<!-- Multi-CLI Review Result -->
<!-- CLI: Claude Code -->
<!-- Perspective: code-review -->
<!-- Task Type: review -->
<!-- Status: discarded -->

- Critical: 0
- Important: 0
BODY
run_ma inc2 --task review --mode cross-model --perspective code-review --base develop \
  --cli claude-code --delegate-to-host --output-dir "$INC_OUT"
if [ "$RUN_RC" -eq 3 ] && grep -qF 'declares itself incomplete/discarded' "$RUN_ERR"; then
  ok "破棄済み成果物を「完成した結果」へ格上げしない（本文全体を走査している）"
else
  bad "破棄済み成果物が受理された（rc=${RUN_RC}）— 失敗した実行のサルベージが complete として載る"
fi

echo "-- (16) 正規ヘッダー付きの応答はヘッダーを二重にせず受理する --"
HDR_OUT="$TMP/hdr-results"
HDR_RESULT="$HDR_OUT/claude-code/code-review.md"
run_ma hdr1 --task review --mode cross-model --perspective code-review --base develop \
  --cli claude-code --delegate-to-host --output-dir "$HDR_OUT"
cat > "$RESPONSE_FILE" <<'BODY'
<!-- Multi-CLI Review Result -->
<!-- CLI: Claude Code -->
<!-- Perspective: code-review -->
<!-- Task Type: review -->
<!-- Status: complete -->
<!-- Generated: 2026-09-12T00:00:00Z -->

- Critical: 0
- Important: 1
- verdict: none
- 本文の目印 HDRBODY
BODY
run_ma hdr2 --task review --mode cross-model --perspective code-review --base develop \
  --cli claude-code --delegate-to-host --output-dir "$HDR_OUT"
HDR_COUNT="$(grep -c '^<!-- Multi-CLI Review Result -->$' "$HDR_RESULT" 2>/dev/null || true)"
if [ "$RUN_RC" -eq 0 ] && [ "$HDR_COUNT" = "1" ] && grep -qF 'HDRBODY' "$HDR_RESULT"; then
  ok "ヘッダー付き応答を受理し、ヘッダーは 1 つ・本文は保持される"
else
  bad "ヘッダー付き応答の正規化が壊れている（rc=${RUN_RC} / ヘッダー ${HDR_COUNT} 個）"
fi

echo "-- (17) 受理結果を書けない実行は fail-loud でホスト応答を残す --"
LOCK_OUT="$TMP/lock-results"
run_ma lock1 --task review --mode cross-model --perspective code-review --base develop \
  --cli claude-code --delegate-to-host --output-dir "$LOCK_OUT"
LOCK_RESPONSE="$RESPONSE_FILE"
printf -- '- Critical: 0\n- verdict: none\n' > "$LOCK_RESPONSE"
chmod 555 "$LOCK_OUT/claude-code"
run_ma lock2 --task review --mode cross-model --perspective code-review --base develop \
  --cli claude-code --delegate-to-host --output-dir "$LOCK_OUT"
chmod 755 "$LOCK_OUT/claude-code"
if [ "$RUN_RC" -ne 0 ] && grep -qE 'could not be written|cannot write|Permission denied' "$RUN_ERR"; then
  ok "受理結果の書込失敗は fail-loud で止まる"
else
  bad "受理結果の書込失敗が握り潰された（rc=${RUN_RC}）"
fi
if [ -f "$LOCK_RESPONSE" ] && grep -qF -- '- verdict: none' "$LOCK_RESPONSE"; then
  ok "止まった実行はホスト応答を世代別の受け皿に残す"
else
  bad "ホストの成果物が消えた（作り直させることになる）"
fi

echo "-- (18) 応答パスの symlink は採らない --"
LINK_OUT="$TMP/link-results"
OUTSIDE="$TMP/outside-secret.md"
printf -- '- Critical: 0\n- verdict: none\n- 外部ファイルの本文\n' > "$OUTSIDE"
OUTSIDE_HASH="$(git hash-object "$OUTSIDE")"
run_ma link1 --task review --mode cross-model --perspective code-review --base develop \
  --cli claude-code --delegate-to-host --output-dir "$LINK_OUT"
ln -s "$OUTSIDE" "$RESPONSE_FILE"
run_ma link2 --task review --mode cross-model --perspective code-review --base develop \
  --cli claude-code --delegate-to-host --output-dir "$LINK_OUT"
if [ "$RUN_RC" -ne 0 ] && grep -qiE 'symlink|unsafe delegation file' "$RUN_ERR" \
   && ! grep -qF '外部ファイルの本文' "$LINK_OUT/integrated-report.md"; then
  ok "応答パスの symlink を名指しして拒否し、外部本文を受理しない"
else
  bad "応答パスの symlink が採用された（rc=${RUN_RC}）"
fi
if [ -f "$OUTSIDE" ] && [ "$(git hash-object "$OUTSIDE")" = "$OUTSIDE_HASH" ]; then
  ok "symlink の指し先は触られていない"
else
  bad "symlink の指し先が改変・削除された"
fi

echo "-- (19) 委譲を残したままフラグを落とした実行は中断する --"
DROP_OUT="$TMP/drop-results"
DROP_RESULT="$DROP_OUT/claude-code/code-review.md"
run_ma drop1 --task review --mode cross-model --perspective code-review --base develop \
  --cli claude-code --delegate-to-host --output-dir "$DROP_OUT"
DROP_RESULT="$RESPONSE_FILE"
printf -- '- Critical: 0\n- verdict: none\n- 目印 DROPBODY\n' > "$DROP_RESULT"
: > "$CLAUDE_COUNT"
run_ma drop2 --task review --mode cross-model --perspective code-review --base develop \
  --cli claude-code --output-dir "$DROP_OUT"
if [ "$RUN_RC" -ne 0 ] && grep -qF 'an unfinished host delegation exists for' "$RUN_ERR"; then
  ok "フラグを落とした再実行は、結果を消す前に中断する"
else
  bad "フラグを落とした再実行が素通りした（rc=${RUN_RC}）— ホストの成果物が無言で消える"
fi
if [ -f "$DROP_RESULT" ] && grep -qF 'DROPBODY' "$DROP_RESULT"; then
  ok "中断した実行はホストの成果物を残す"
else
  bad "ホストの成果物が消えた"
fi
if [ "$(claude_launch_count)" = "0" ]; then
  ok "中断した実行は CLI を起動しない（枯渇している CLI を呼びに行かない）"
else
  bad "中断したはずの実行が claude を起動した（回数=$(claude_launch_count)）"
fi

echo "-- (20) --fresh との併用は拒否する --"
run_ma freshcombo --task review --mode cross-model --perspective code-review --base develop \
  --cli claude-code --delegate-to-host --fresh --output-dir "$TMP/fresh-results"
if [ "$RUN_RC" -ne 0 ] && grep -qF 'cannot be combined with --delegate-to-host' "$RUN_ERR"; then
  ok "--fresh との併用を拒否する（回収より前に退避され収束しないため）"
else
  bad "--fresh と併用できてしまう（rc=${RUN_RC}）— 完了済みレビューが読まれないまま退避され、handoff が繰り返される"
fi

run_ma freshgrok --task review --cli grok-cli --perspective code-review --base develop \
  --delegate-to-host=grok-cli --fresh --output-dir "$TMP/fresh-grok"
if [ "$RUN_RC" -eq 2 ] && grep -qF 're-run with --delegate-to-host=grok-cli and no --fresh' "$RUN_ERR"; then
  ok "=grok-cli と --fresh の拒否案内は渡したレーンを保つ（素のフラグ = claude-code へ戻さない）"
else
  bad "=grok-cli と --fresh の拒否案内がレーンを落とした: rc=${RUN_RC}"
fi

echo "-- (21) 複数観点の部分受理と --resume での収束 --"
# 分散プランの claude-code は registry 上 3 観点を持つ。1 観点ずつ答える通常の進み方で
# handoff 件数が減り、受理済みが再委譲されないことを見る（--resume なしだと
# clear_planned_outputs が受理済みを消して再委譲するため収束しない）。
# cross-model モードは複数 --perspective を受けても 1 観点しか残さないので distributed を使う。
MP_OUT="$TMP/multi-persp-results"
: > "$CLAUDE_COUNT"
mp_run() { # <label> <追加引数...>
  local label="$1"; shift
  MP_RC=0
  run_isolated PATH="$STUB_PATH" HOME="$TMP/home" \
    bash "$MULTI_AGENT" --task review --mode distributed --base develop \
    --cli claude-code --delegate-to-host --output-dir "$MP_OUT" "$@" \
    > "$TMP/out.${label}" 2> "$TMP/err.${label}" || MP_RC=$?
  MP_OUT_FILE="$TMP/out.${label}"
  MP_ERR_FILE="$TMP/err.${label}"
}
mp_pending_count() { grep -c -- '--- task ---' "$MP_OUT_FILE" 2>/dev/null || true; }
# 委譲待ちの観点名を 1 つ取り出す（registry の並びに依存しない）
mp_first_pending() {
  sed -n 's/^perspective=//p' "$MP_OUT_FILE" | sed -n '1p'
}

mp_run mp1
MP_TOTAL="$(mp_pending_count)"
if [ "$MP_RC" -eq 3 ] && [ "$MP_TOTAL" -ge 2 ]; then
  ok "分散プランの複数観点がまとめて handoff される（${MP_TOTAL} 件）"
else
  bad "複数観点の handoff が成立しない（rc=${MP_RC} / ${MP_TOTAL} 件）"
  tail -5 "$MP_ERR_FILE" | sed 's/^/    /'
fi
if grep -qF "count=${MP_TOTAL}" "$MP_OUT_FILE"; then
  ok "handoff が件数を名乗り、タスクブロック数と一致する"
else
  bad "handoff の count がタスクブロック数と一致しない"
  grep -E '^count=' "$MP_OUT_FILE" | sed 's/^/    /'
fi

# 1 観点だけ答える
MP_FIRST="$(mp_first_pending)"
printf -- '- Critical: 0\n- verdict: none\n- 目印 MPBODY\n' > "$(handoff_field "$MP_OUT_FILE" output-file "$MP_FIRST")"
mp_run mp2 --resume
MP_LEFT="$(mp_pending_count)"
if [ "$MP_RC" -eq 3 ] && [ "$MP_LEFT" -eq $((MP_TOTAL - 1)) ]; then
  ok "1 観点を受理し、残りだけを出し直す（${MP_TOTAL} → ${MP_LEFT}）"
else
  bad "部分受理で handoff 件数が減らない（rc=${MP_RC} / 残り ${MP_LEFT} 件）"
fi
if grep -qF 'MPBODY' "$MP_OUT/claude-code/${MP_FIRST}.md" 2>/dev/null; then
  ok "受理済み観点の成果物が残っている（再委譲されていない）"
else
  bad "受理済み観点が消えた（毎巡やり直しになり収束しない）"
fi

# 残りを全部答えて締める
for mp_persp in $(sed -n 's/^perspective=//p' "$MP_OUT_FILE"); do
  printf -- '- Critical: 0\n- verdict: none\n- 目印 MPREST\n' > "$(handoff_field "$MP_OUT_FILE" output-file "$mp_persp")"
done
mp_run mp3 --resume
if [ "$MP_RC" -eq 0 ] && grep -qF 'MPBODY' "$MP_OUT/claude-code/${MP_FIRST}.md"; then
  ok "全観点を答え終えると rc=0 で締まり、最初に受理した成果物も残る"
else
  bad "複数観点の往復が収束しない（rc=${MP_RC}）"
  tail -6 "$MP_ERR_FILE" | sed 's/^/    /'
fi
if [ "$(claude_launch_count)" = "0" ]; then
  ok "複数観点の往復でも claude を 1 度も起動していない"
else
  bad "複数観点の往復で claude が起動した（回数=$(claude_launch_count)）"
fi

echo "-- (22) 委譲待ちのあいだに結果パスへ現れたファイルを結果として読まない --"
# 委譲タスクは CLI を起動しないので数ミリ秒で終わる。他レーンが走っている数分のあいだに
# ホストが結果パスへ書くと、レポート生成時には「委譲待ち」かつ「ファイルが在る」状態に
# なる。そのファイルは digest 照合も本文の受理ゲートも通っていないので、本文としても
# Critical 判定の入力としても採ってはいけない。遅い co-lane で同じ窓を作って実測する。
RACE_OUT="$TMP/race-results"
RACESTUB="$TMP/bin-race"
mkdir -p "$RACESTUB"
cp "$STUB/claude" "$RACESTUB/claude"
cat > "$RACESTUB/codex" <<SH
#!/usr/bin/env bash
cat >/dev/null
# 委譲タスクが終わった後・レポート生成の前に、結果パスへ割り込む
mkdir -p "$RACE_OUT/claude-code"
{
  echo "### Critical Issues"
  echo "- [app.txt:2] RACEBODY 未検証の割り込み"
  echo "- Critical: 1"
} > "$RACE_OUT/claude-code/code-review.md"
echo "- Critical: 0"
echo "- Important: 0"
echo "- verdict: none"
SH
chmod +x "$RACESTUB/codex"
: > "$CLAUDE_COUNT"
RACE_RC=0
run_isolated PATH="$RACESTUB:/usr/bin:/bin:/usr/sbin:/sbin" HOME="$TMP/home" \
  bash "$MULTI_AGENT" --task review --mode cross-model --perspective code-review \
  --base develop --cli claude-code --cli codex-cli --delegate-to-host \
  --output-dir "$RACE_OUT" > "$TMP/out.race" 2> "$TMP/err.race" || RACE_RC=$?
RACE_REPORT="$RACE_OUT/integrated-report.md"
if [ -f "$RACE_OUT/claude-code/code-review.md" ]; then
  ok "前提: 委譲待ちのあいだに結果パスへファイルが現れている"
else
  bad "前提が崩れた: 割り込みファイルが作られていない"
fi
if grep -qF 'DELEGATED' "$RACE_REPORT" 2>/dev/null && ! grep -qF 'RACEBODY' "$RACE_REPORT" 2>/dev/null; then
  ok "レポートは未検証ファイルを本文に採らず、DELEGATED のまま報告する"
else
  bad "未検証ファイルがレポート本文へ載った（digest 照合も受理ゲートも通っていない）"
fi
if ! grep -qF -- '<!-- CRITICAL_BLOCK -->' "$RACE_REPORT" 2>/dev/null; then
  ok "未検証ファイルの Critical を判定の入力にしない（本文側と同じ判断になる）"
else
  bad "未検証ファイルが CRITICAL_BLOCK の判定に使われた（2 つの消費者が同じパスで別判断になる）"
fi

echo "-- (23) 未完了の旧世代と新 HEAD の応答を分離する --"
AMB_OUT="$TMP/amb-results"
AMB_RESULT="$AMB_OUT/claude-code/code-review.md"
amb_run() {
  local label="$1"; shift
  run_ma "$label" --task review --mode cross-model --perspective code-review --base develop \
    --cli claude-code --cli codex-cli --delegate-to-host --output-dir "$AMB_OUT" "$@"
  AMB_RC="$RUN_RC"; AMB_ERR="$RUN_ERR"
}
amb_run amb1
AMB_A="$RESPONSE_FILE"
printf 'base\nchange\namb\n' > app.txt
git add app.txt
git commit -qm "amb input change"
amb_run amb2
AMB_B="$RESPONSE_FILE"
if [ "$AMB_RC" -eq 3 ] && [ "$AMB_A" != "$AMB_B" ] \
   && grep -qiE 'unadopted|not adopted|未採用' "$AMB_ERR"; then
  ok "新 HEAD は旧未完了を未採用と報告し、別世代を handoff する"
else
  bad "新 HEAD の世代分離または旧未完了の報告が無い"
fi
amb_run amb3 --resume
if [ "$AMB_RC" -eq 3 ] && [ "$AMB_B" = "$RESPONSE_FILE" ]; then
  ok "未応答の同入力 resume は同じ世代の受け皿を保つ"
else
  bad "未応答の resume が別の受け皿へ移った"
fi
printf -- '- Critical: 0\n- verdict: none\n- LATE_HEAD_A\n' > "$AMB_A"
AMB_A_HASH="$(git hash-object "$AMB_A")"
printf -- '- Critical: 0\n- verdict: none\n- HEAD_B_ONLY\n' > "$AMB_B"
AMB_SUB_HASH="$(git hash-object "$AMB_OUT/codex-cli/code-review.md")"
AMB_LAUNCHES="$(codex_launch_count)"
amb_run amb4 --resume
if [ "$AMB_RC" -eq 0 ] && grep -qF HEAD_B_ONLY "$AMB_RESULT" \
   && ! grep -qF LATE_HEAD_A "$AMB_OUT/integrated-report.md"; then
  ok "新世代 B は最初の resume で採用し、遅い A を混ぜない"
else
  bad "新世代 B が初回 resume で採用されない、または A が混入（rc=${AMB_RC}）"
fi
if [ -f "$AMB_A" ] && [ "$(git hash-object "$AMB_A")" = "$AMB_A_HASH" ] \
   && [ "$(codex_launch_count)" = "$AMB_LAUNCHES" ] \
   && [ "$(git hash-object "$AMB_OUT/codex-cli/code-review.md")" = "$AMB_SUB_HASH" ]; then
  ok "旧世代の証跡と完了済み副 CLI の結果を保ち、追加起動しない"
else
  bad "旧世代の証跡または副 CLI の完了結果が変わった"
fi

echo "-- (23b) 単独 adapter の legacy digest / superseded 保護を保つ --"
LEGACY_CHECK=0
if ( set -euo pipefail
  . "$PLUGIN_ROOT/scripts/adapters/adapter-common.sh" >/dev/null 2>&1
  DELEGATE_DIR="$TMP/legacy-digest"; OUTPUT_FILE="$TMP/legacy-result.md"; TASK_TYPE=review
  delegate_task claude-code 'Claude Code' code-review 'prompt A' Read || :
  printf -- '- verdict: none\n- LEGACY_DIFFERENT_INPUT\n' > "$DELEGATE_DIR/code-review.response.md"
  delegate_task claude-code 'Claude Code' code-review 'prompt B' Read || :
  compgen -G "$DELEGATE_DIR/code-review.response.stale.*.md" >/dev/null || exit 1
  DELEGATE_DIR="$TMP/legacy-adapter"
  delegate_task claude-code 'Claude Code' code-review 'prompt A' Read || :
  delegate_task claude-code 'Claude Code' code-review 'prompt B' Read || :
  delegate_task claude-code 'Claude Code' code-review 'prompt B' Read || :
  grep -qx 'superseded=1' "$DELEGATE_DIR/code-review.request" || exit 1
  printf -- '- verdict: none\n- LEGACY_OLD\n' > "$DELEGATE_DIR/code-review.response.md"
  delegate_task claude-code 'Claude Code' code-review 'prompt B' Read || :
  compgen -G "$DELEGATE_DIR/code-review.response.ambiguous.*.md" >/dev/null || exit 1
  printf -- '- verdict: none\n- LEGACY_NEW\n' > "$DELEGATE_DIR/code-review.response.md"
  delegate_task claude-code 'Claude Code' code-review 'prompt B' Read || exit 1
  grep -qF LEGACY_NEW "$OUTPUT_FILE"
) > "$TMP/legacy-adapter.stdout" 2> "$TMP/legacy-adapter.stderr"; then LEGACY_CHECK=1; fi
if [ "$LEGACY_CHECK" -eq 1 ] && grep -qF 'cannot be attributed to one prompt' "$TMP/legacy-adapter.stderr"; then
  ok "単独 adapter は未応答の再実行でも旧応答を曖昧として拒否し、その次の正当応答を採る"
else bad "単独 adapter の digest / superseded 清算が退行した"; fi

echo "-- (24) 本文まで書けたことを確かめてから応答を消す --"
# write_output は cat の失敗を rc へ載せないので、ヘッダーだけ書けて本文の途中で
# 失敗した成果物（部分書き込み）は「先頭行がヘッダー」だけの検査を通過する。
# 受理した本文と書けた本文の一致まで見ていることを、ヘルパー単体で実測する。
PARTIAL_OK=0
PARTIAL_FULL="$TMP/partial-full.md"
PARTIAL_TRUNC="$TMP/partial-trunc.md"
cat > "$PARTIAL_FULL" <<'BODY'
<!-- Multi-CLI Review Result -->
<!-- CLI: Claude Code -->
<!-- Perspective: code-review -->
<!-- Task Type: review -->
<!-- Status: complete -->
<!-- Generated: 2026-09-12T00:00:00Z -->

- Critical: 0
- Important: 1
- 本文の続き
BODY
# 本文の途中で切れた成果物（ヘッダーは無事）
head -9 "$PARTIAL_FULL" > "$PARTIAL_TRUNC"
PARTIAL_BODY="$(printf -- '- Critical: 0\n- Important: 1\n- 本文の続き')"
if ( set -euo pipefail
     . "$PLUGIN_ROOT/scripts/adapters/adapter-common.sh" >/dev/null 2>&1
     delegation_output_written "$PARTIAL_FULL" "$PARTIAL_BODY" ); then
  PARTIAL_OK=$((PARTIAL_OK + 1))
else
  bad "完全に書けた成果物を「書けていない」と判定した（受理が全滅する）"
fi
if ( set -euo pipefail
     . "$PLUGIN_ROOT/scripts/adapters/adapter-common.sh" >/dev/null 2>&1
     delegation_output_written "$PARTIAL_TRUNC" "$PARTIAL_BODY" ); then
  bad "部分書き込み（ヘッダーだけ無事）を成功と判定した — 直後にホストの応答が消える"
else
  PARTIAL_OK=$((PARTIAL_OK + 1))
fi
if [ "$PARTIAL_OK" -eq 2 ]; then
  ok "受理した本文と書けた本文の一致まで確かめている（部分書き込みを成功にしない）"
fi

echo "-- (26) codex-cli / grok-cli / antigravity-cli ホストの委譲（Issue \`#2118\` / \`#2785\`） --"
for LANE in codex-cli grok-cli antigravity-cli; do
  LOD="$TMP/od-${LANE}"
  run_ma "host-${LANE}" --task review --cli "$LANE" --perspective code-review --base develop \
    --delegate-to-host="$LANE" --output-dir "$LOD"
  if [ "$RUN_RC" -eq 3 ] && grep -qF "cli=${LANE}" "$RUN_OUT" \
     && [ -s "$(handoff_field "$RUN_OUT" prompt-file code-review "$LANE")" ]; then
    ok "--delegate-to-host=${LANE} は ${LANE} レーンを handoff する（rc=3）"
  else
    bad "--delegate-to-host=${LANE} が handoff しない: rc=${RUN_RC} / $(tail -3 "$RUN_ERR" | tr '\n' ' ')"
  fi
  if [ "$LANE" = "antigravity-cli" ]; then
    run_ma "guard-${LANE}" --task review --cli "$LANE" --perspective code-review --base develop \
      --output-dir "$LOD" --resume
    if [ "$RUN_RC" -eq 1 ] && grep -qF -- '--delegate-to-host=antigravity-cli' "$RUN_ERR"; then
      ok "未回収の antigravity-cli handoff が残るとき --delegate-to-host=antigravity-cli を案内して中断する"
    else
      bad "未回収の antigravity-cli handoff 保護・復旧案内が不足: rc=${RUN_RC}"
    fi
  fi
done
run_ma host-bad --task review --cli codex-cli --perspective code-review --base develop \
  --delegate-to-host=copilot-cli
if [ "$RUN_RC" -eq 1 ] && [ ! -s "$RUN_OUT" ]; then
  ok "ホストのレーンでない値（copilot-cli）は exit 1 で拒否する"
else
  bad "--delegate-to-host=copilot-cli を拒否しない: rc=${RUN_RC}"
fi

XOD="$TMP/od-xlane"
# shellcheck disable=SC2086 # BASE_ARGS は語分割して渡す固定の引数列
run_ma xlane1 $BASE_ARGS --delegate-to-host --output-dir "$XOD"
XRC1=$RUN_RC
# shellcheck disable=SC2086 # 同上
run_ma xlane2 $BASE_ARGS --delegate-to-host=codex-cli --output-dir "$XOD" --resume
if [ "$XRC1" -eq 3 ] && [ "$RUN_RC" -eq 1 ] && grep -qF 'unfinished host delegation exists for: claude-code/' "$RUN_ERR"; then
  ok "別レーンの委譲で再実行しても、未回収の claude-code handoff を消さずに中断する"
else
  bad "別レーンの委譲が未回収の handoff を守らない: rc1=${XRC1} rc2=${RUN_RC}"
fi

GROKFAIL="$TMP/grokfail-bin"
mkdir -p "$GROKFAIL"
printf '#!/usr/bin/env bash\ncat >/dev/null 2>&1\necho "preamble only"\nexit 1\n' > "$GROKFAIL/grok"
chmod +x "$GROKFAIL/grok"
for GA in 1 ""; do
  GRC=0
  run_isolated PATH="$GROKFAIL:$STUB_PATH" HOME="$TMP/home" GROK_AGENT="$GA" \
    bash "$MULTI_AGENT" --task review --cli grok-cli --perspective code-review --base develop \
    --output-dir "$TMP/od-grokfail-${GA:-none}" > "$TMP/out.grokfail" 2> "$TMP/err.grokfail" || GRC=$?
  if [ -n "$GA" ]; then
    if [ "$GRC" -ne 0 ] && grep -qF -- '--cli grok-cli --perspective code-review --delegate-to-host=grok-cli --resume' "$TMP/err.grokfail"; then
      ok "grok ホスト（GROK_AGENT あり）で grok-cli が落ちると --delegate-to-host=grok-cli の手順を案内する"
    else
      bad "grok ホストで grok-cli が落ちても委譲の案内が出ない: rc=${GRC}"
    fi
  elif grep -qF -- '--delegate-to-host=grok-cli' "$TMP/err.grokfail"; then
    bad "grok ホストでない実行に grok-cli 委譲を案内した（委譲先のセッションが無い）"
  else
    ok "GROK_AGENT が無い実行では grok-cli 委譲を案内しない"
  fi
done

AGYFAIL="$TMP/agyfail-bin"
mkdir -p "$AGYFAIL"
printf '#!/usr/bin/env bash\ncat >/dev/null 2>&1\necho "preamble only"\nexit 1\n' > "$AGYFAIL/agy"
chmod +x "$AGYFAIL/agy"
for AA in 1 ""; do
  ARC=0
  run_isolated -u ANTIGRAVITY_AGENT PATH="$AGYFAIL:$STUB_PATH" HOME="$TMP/home" ${AA:+ANTIGRAVITY_AGENT="$AA"} \
    bash "$MULTI_AGENT" --task review --cli antigravity-cli --perspective code-review --base develop \
    --output-dir "$TMP/od-agyfail-${AA:-none}" > "$TMP/out.agyfail" 2> "$TMP/err.agyfail" || ARC=$?
  if [ -n "$AA" ]; then
    if [ "$ARC" -ne 0 ] && grep -qF -- '--cli antigravity-cli --perspective code-review --delegate-to-host=antigravity-cli --resume' "$TMP/err.agyfail"; then
      ok "Antigravity ホスト（ANTIGRAVITY_AGENT=1）で antigravity-cli が落ちると --delegate-to-host=antigravity-cli の手順を案内する"
    else
      bad "Antigravity ホストで antigravity-cli が落ちても委譲の案内が出ない: rc=${ARC}"
    fi
  elif grep -qF -- '--delegate-to-host=antigravity-cli' "$TMP/err.agyfail"; then
    bad "Antigravity ホストでない実行に antigravity-cli 委譲を案内した（委譲先のセッションが無い）"
  else
    ok "ANTIGRAVITY_AGENT が無い実行では antigravity-cli 委譲を案内しない"
  fi
done

echo "-- (27) description / wrapper route の付け忘れは書換え前に止まり、元 argv 1 回で回復 --"
RECOVERY_DESC="日本語の受入条件
\"引用\" と 'single' と \$literal を保持"
RECOVERY_OUT="$TMP/recovery-results"
RECOVERY_ARGS=(--route full --base develop --delegate-to-host --description "$RECOVERY_DESC"
  --output-dir "$RECOVERY_OUT" --sequential)
MA_ENTRY="$PLUGIN_ROOT/scripts/multi-review.sh"
run_ma recovery-initial "${RECOVERY_ARGS[@]}"
RECOVERY_HANDOFF="$RUN_OUT"
if [ "$RUN_RC" -eq 3 ] && [ "$(grep -c '^--- task ---$' "$RUN_OUT")" -eq 4 ]; then
  ok "前提: 実体 multi-review.sh --route full が主4観点を委譲する"
else bad "wrapper full の初回委譲に到達しない（rc=${RUN_RC}）"; fi
for recovery_persp in $(sed -n 's/^perspective=//p' "$RECOVERY_HANDOFF"); do
  printf -- '- Critical: 0\n- verdict: none\n- RECOVERY_ORIGINAL\n' \
    > "$(handoff_field "$RECOVERY_HANDOFF" output-file "$recovery_persp")"
done
RECOVERY_SUB="$RECOVERY_OUT/codex-cli/comprehensive-review.md"
RECOVERY_SUB_HASH="$(git hash-object "$RECOVERY_SUB")"
tree_hashes "$RECOVERY_OUT" > "$TMP/recovery-before.hashes"
RECOVERY_CODEX="$(codex_launch_count)"; RECOVERY_CLAUDE="$(claude_launch_count)"
run_ma recovery-description-omitted --route full --base develop --delegate-to-host \
  --output-dir "$RECOVERY_OUT" --sequential --resume
tree_hashes "$RECOVERY_OUT" > "$TMP/recovery-after-description.hashes"
if [ "$RUN_RC" -ne 0 ] && grep -qF -- '--resume input differs from the initial host delegation at the same HEAD.' "$RUN_ERR" \
   && cmp -s "$TMP/recovery-before.hashes" "$TMP/recovery-after-description.hashes" \
   && [ "$(codex_launch_count)" = "$RECOVERY_CODEX" ] && [ "$(claude_launch_count)" = "$RECOVERY_CLAUDE" ]; then
  ok "description 落ちは応答/request/prompt/report/cacheを不変のまま拒否し、CLI追加起動0"
else bad "description 落ちが成果物を変えた、CLIを起動した、または照合へ到達しない"; fi
if grep -qF 'Repeat the initial command (including --route and --description)' "$RUN_ERR" \
   && grep -qF -- '--route' "$RUN_ERR" && grep -qF full "$RUN_ERR" \
   && grep -qF '日本語の受入条件' "$RUN_ERR" && grep -qF '"引用"' "$RUN_ERR" \
   && grep -qF 'single' "$RUN_ERR" && grep -qF '$literal を保持' "$RUN_ERR"; then
  ok "拒否は初回 route と改行・引用・日本語を含む description をコマンドで示す"
else bad "拒否の初回コマンド表示から route または description が落ちた"; fi
run_ma recovery-route-omitted --base develop --delegate-to-host --description "$RECOVERY_DESC" \
  --output-dir "$RECOVERY_OUT" --sequential --resume
tree_hashes "$RECOVERY_OUT" > "$TMP/recovery-after-route.hashes"
if [ "$RUN_RC" -ne 0 ] && grep -qF -- '--resume input differs from the initial host delegation at the same HEAD.' "$RUN_ERR" \
   && cmp -s "$TMP/recovery-before.hashes" "$TMP/recovery-after-route.hashes" \
   && [ "$(codex_launch_count)" = "$RECOVERY_CODEX" ] && [ "$(claude_launch_count)" = "$RECOVERY_CLAUDE" ]; then
  ok "wrapper route 落ちも全成果物不変・CLI追加起動0で拒否する"
else bad "wrapper route 落ちが成果物を変えた、CLIを起動した、または照合へ到達しない"; fi
run_ma recovery-original-once "${RECOVERY_ARGS[@]}" --resume
if [ "$RUN_RC" -eq 0 ] && [ "$(grep -c 'RECOVERY_ORIGINAL' "$RECOVERY_OUT/integrated-report.md")" -eq 4 ] \
   && [ "$(codex_launch_count)" = "$RECOVERY_CODEX" ] \
   && [ "$(git hash-object "$RECOVERY_SUB")" = "$RECOVERY_SUB_HASH" ]; then
  ok "元 argv の次1回で4観点を採用し、副CLIの結果・起動数を保つ"
else bad "元 argv 1回で回復しない、または完了済み副CLIを壊す（rc=${RUN_RC}）"; fi
unset MA_ENTRY

echo "-- (28) metadata の legacy / 欠落 / 壊れ / 重複 / symlink は証跡を守る --"
for state_mode in same-head new-head; do
STATE_SOURCE="$TMP/state-${state_mode}-source-results"
STATE_DESC="state integrity original description"
run_ma state-source --task review --mode cross-model --perspective code-review --base develop \
  --cli claude-code --cli codex-cli --delegate-to-host --description "$STATE_DESC" --output-dir "$STATE_SOURCE"
if [ "$RUN_RC" -ne 3 ]; then bad "${state_mode}: metadata比較の初回handoffに到達しない"; continue; fi
STATE_RESPONSE_REL="${RESPONSE_FILE#"$(cd "$STATE_SOURCE" && pwd -P)"/}"
printf -- '- Critical: 0\n- verdict: none\n- STATE_EVIDENCE\n' > "$RESPONSE_FILE"
if [ "$state_mode" = new-head ]; then git commit --allow-empty -qm "metadata new HEAD"; fi
for state_case in legacy orphan-state missing-metadata missing-manifest missing-invocation broken duplicate nul symlink request-duplicate request-nul valid-head valid-generation generation-hash missing-generation-hash; do
  STATE_ARGV_MODES="original"
  case "$state_case" in valid-head|valid-generation|generation-hash|missing-generation-hash) STATE_ARGV_MODES="original omitted-description" ;; esac
  for state_argv in $STATE_ARGV_MODES; do
  STATE_OUT="$TMP/state-${state_case}-results"
  # request内の絶対pathを保つため、コピーを同じ場所へ戻してから壊す。
  cp -R "$STATE_SOURCE" "$STATE_OUT"
  STATE_BACKUP="$TMP/state-backup-${state_case}"
  mv "$STATE_SOURCE" "$STATE_BACKUP"
  mv "$STATE_OUT" "$STATE_SOURCE"
  case "$state_case" in
    legacy)
      mkdir -p "$STATE_SOURCE/claude-code/.delegated"
      printf 'prompt-digest=legacy\n' > "$STATE_SOURCE/claude-code/.delegated/code-review.request"
      rm -rf "$STATE_SOURCE/.delegation-state" ;;
    orphan-state) rm -rf "$STATE_SOURCE/.delegation-state" ;;
    missing-generation-hash)
      sed '/^generation-hash=/d' "$STATE_SOURCE/.delegation-state/metadata" > "$TMP/state-metadata-new"
      mv "$TMP/state-metadata-new" "$STATE_SOURCE/.delegation-state/metadata" ;;
    missing-*) rm -f "$STATE_SOURCE/.delegation-state/${state_case#missing-}" ;;
    valid-head)
      STATE_OTHER_HEAD="$(git rev-parse develop)"
      sed "s/^head=.*/head=${STATE_OTHER_HEAD}/" "$STATE_SOURCE/.delegation-state/metadata" > "$TMP/state-metadata-new"
      mv "$TMP/state-metadata-new" "$STATE_SOURCE/.delegation-state/metadata" ;;
    valid-generation)
      sed 's/^generation=.*/generation=g-1-2-3/' "$STATE_SOURCE/.delegation-state/metadata" > "$TMP/state-metadata-new"
      mv "$TMP/state-metadata-new" "$STATE_SOURCE/.delegation-state/metadata" ;;
    generation-hash)
      STATE_OTHER_HASH="$(printf 'different generation\n' | git hash-object --stdin)"
      sed "s/^generation-hash=.*/generation-hash=${STATE_OTHER_HASH}/" "$STATE_SOURCE/.delegation-state/metadata" > "$TMP/state-metadata-new"
      mv "$TMP/state-metadata-new" "$STATE_SOURCE/.delegation-state/metadata" ;;
    broken) printf 'this is not metadata\n' > "$STATE_SOURCE/.delegation-state/metadata" ;;
    duplicate) cat "$STATE_SOURCE/.delegation-state/metadata" > "$TMP/metadata-copy"
      cat "$TMP/metadata-copy" >> "$STATE_SOURCE/.delegation-state/metadata" ;;
    nul) printf '\000' >> "$STATE_SOURCE/.delegation-state/metadata" ;;
    request-duplicate) printf 'cli=claude-code\n' >> "$STATE_SOURCE/${STATE_RESPONSE_REL%.response.md}.request" ;;
    request-nul) printf '\000' >> "$STATE_SOURCE/${STATE_RESPONSE_REL%.response.md}.request" ;;
    symlink) mv "$STATE_SOURCE/.delegation-state/metadata" "$TMP/metadata-link-target"
      ln -s "$TMP/metadata-link-target" "$STATE_SOURCE/.delegation-state/metadata" ;;
  esac
  tree_hashes "$STATE_SOURCE" > "$TMP/state-${state_case}-before.hashes"
  STATE_CODEX="$(codex_launch_count)"; STATE_CLAUDE="$(claude_launch_count)"
  STATE_REPLAY_ARGS=(--task review --mode cross-model --perspective code-review --base develop
    --cli claude-code --cli codex-cli --delegate-to-host --output-dir "$STATE_SOURCE" --resume)
  [ "$state_argv" != original ] || STATE_REPLAY_ARGS+=(--description "$STATE_DESC")
  run_ma "state-${state_case}-${state_argv}" "${STATE_REPLAY_ARGS[@]}"
  tree_hashes "$STATE_SOURCE" > "$TMP/state-${state_case}-after.hashes"
  if [ "$RUN_RC" -ne 0 ] && grep -qF 'cannot safely resume the saved host delegation:' "$RUN_ERR" \
     && cmp -s "$TMP/state-${state_case}-before.hashes" "$TMP/state-${state_case}-after.hashes" \
     && [ "$(codex_launch_count)" = "$STATE_CODEX" ] && [ "$(claude_launch_count)" = "$STATE_CLAUDE" ] \
     && grep -qF STATE_EVIDENCE "$STATE_SOURCE/$STATE_RESPONSE_REL"; then
    ok "${state_mode}/${state_case}/${state_argv}: metadata拒否・全証跡不変・CLI追加起動0"
  else bad "${state_mode}/${state_case}/${state_argv}: metadataがfail closedでない、または証跡を変えた（rc=${RUN_RC}）"; fi
  rm -rf "$STATE_SOURCE"
  mv "$STATE_BACKUP" "$STATE_SOURCE"
  done
done
done

echo "-- (29) state の無い plan 外 CLI の symlink は辿らず、対象レーンを続行する --"
UNPLANNED_OUT="$TMP/unplanned-symlink-results"
UNPLANNED_TARGET="$TMP/unplanned-external"
mkdir -p "$UNPLANNED_OUT" "$UNPLANNED_TARGET"
# Plant the unplanned link only after genuine empty-root initialization; old
# nonempty unmarked output is intentionally no longer adopted (Issue `#2429`).
( . "$PLUGIN_ROOT/scripts/lib/multi-agent-boundary.sh"; ff_review_output_prepare "$REPO" "$UNPLANNED_OUT" true review ) >/dev/null
printf 'UNPLANNED_EXTERNAL_EVIDENCE\n' > "$UNPLANNED_TARGET/code-review.md"
ln -s "$UNPLANNED_TARGET" "$UNPLANNED_OUT/claude-code"
UNPLANNED_HASH="$(git hash-object "$UNPLANNED_TARGET/code-review.md")"
UNPLANNED_CODEX="$(codex_launch_count)"; UNPLANNED_CLAUDE="$(claude_launch_count)"
run_ma unplanned-symlink --task review --mode cross-model --perspective code-review --base develop \
  --cli codex-cli --output-dir "$UNPLANNED_OUT"
if [ "$RUN_RC" -eq 0 ] && [ -f "$UNPLANNED_OUT/codex-cli/code-review.md" ] \
   && grep -qF '<!-- Status: complete -->' "$UNPLANNED_OUT/codex-cli/code-review.md" \
   && [ "$(codex_launch_count)" -eq $((UNPLANNED_CODEX + 1)) ] \
   && [ "$(claude_launch_count)" = "$UNPLANNED_CLAUDE" ] \
   && [ -L "$UNPLANNED_OUT/claude-code" ] \
   && [ "$(readlink "$UNPLANNED_OUT/claude-code")" = "$UNPLANNED_TARGET" ] \
   && [ "$(git hash-object "$UNPLANNED_TARGET/code-review.md")" = "$UNPLANNED_HASH" ]; then
  ok "無関係な unplanned symlink と外部証跡を保ち、codex-only plan が完走する"
else bad "無関係な unplanned symlink を拒否・追随した、または対象レーンが完走しない（rc=${RUN_RC}）"; fi

echo "-- (30) plan から外れた保存済み委譲レーンの symlink を見落とさない --"
SAVED_OUT="$TMP/saved-lane-results"
run_ma saved-lane-initial --task review --mode cross-model --perspective code-review --base develop \
  --cli claude-code --delegate-to-host --output-dir "$SAVED_OUT"
SAVED_RESPONSE="$RESPONSE_FILE"
printf -- '- verdict: none\n- SAVED_LANE_EVIDENCE\n' > "$SAVED_RESPONSE"
SAVED_EXTERNAL="$TMP/saved-lane-external"
mv "$SAVED_OUT/claude-code" "$SAVED_EXTERNAL"
ln -s "$SAVED_EXTERNAL" "$SAVED_OUT/claude-code"
tree_hashes "$SAVED_OUT" > "$TMP/saved-lane-before.hashes"
tree_hashes "$SAVED_EXTERNAL" > "$TMP/saved-external-before.hashes"
SAVED_CODEX="$(codex_launch_count)"; SAVED_CLAUDE="$(claude_launch_count)"
run_ma saved-lane-removed --task review --mode cross-model --perspective code-review --base develop \
  --cli codex-cli --output-dir "$SAVED_OUT" --resume
tree_hashes "$SAVED_OUT" > "$TMP/saved-lane-after.hashes"
tree_hashes "$SAVED_EXTERNAL" > "$TMP/saved-external-after.hashes"
if [ "$RUN_RC" -ne 0 ] && grep -qF 'cannot safely resume the saved host delegation:' "$RUN_ERR" \
   && grep -qF '/claude-code' "$RUN_ERR" \
   && cmp -s "$TMP/saved-lane-before.hashes" "$TMP/saved-lane-after.hashes" \
   && cmp -s "$TMP/saved-external-before.hashes" "$TMP/saved-external-after.hashes" \
   && [ "$(codex_launch_count)" = "$SAVED_CODEX" ] && [ "$(claude_launch_count)" = "$SAVED_CLAUDE" ] \
   && grep -qF SAVED_LANE_EVIDENCE "$SAVED_RESPONSE"; then
  ok "保存 manifest の委譲laneは現plan外でも拒否し、未回収handoff・応答・cacheを保つ"
else bad "保存 manifest の委譲laneをplan外として見落とし、証跡を変えた（rc=${RUN_RC}）"; fi

echo "-- (31) state 保存後・dispatch 前の中断は同じ世代で再開できる --"
STATE_ONLY_OUT="$TMP/state-only-results"
STATE_ONLY_ARGS=(--task review --mode cross-model --perspective code-review --base develop
  --cli claude-code --cli codex-cli --delegate-to-host --description "state-only original"
  --output-dir "$STATE_ONLY_OUT" --sequential)
run_ma state-only-initial "${STATE_ONLY_ARGS[@]}"
STATE_ONLY_GENERATION="$(sed -n 's/^generation=//p' "$STATE_ONLY_OUT/.delegation-state/metadata")"
STATE_ONLY_IDENTITY="$(sed -n 's/^identity=//p' "$STATE_ONLY_OUT/.delegation-state/metadata")"
# state publish は dispatch より先。捕捉済み fixed diff は残し、dispatch の生成物だけを除く。
rm -rf "$STATE_ONLY_OUT/claude-code" "$STATE_ONLY_OUT/codex-cli" "$STATE_ONLY_OUT/.resume-cache"
rm -f "$STATE_ONLY_OUT/integrated-report.md"
STATE_ONLY_CODEX="$(codex_launch_count)"; STATE_ONLY_CLAUDE="$(claude_launch_count)"
run_ma state-only-resume "${STATE_ONLY_ARGS[@]}" --resume
if [ "$RUN_RC" -eq 3 ] && [ -n "$STATE_ONLY_GENERATION" ] \
   && [ "$(sed -n 's/^generation=//p' "$STATE_ONLY_OUT/.delegation-state/metadata")" = "$STATE_ONLY_GENERATION" ] \
   && [ "$(sed -n 's/^identity=//p' "$STATE_ONLY_OUT/.delegation-state/metadata")" = "$STATE_ONLY_IDENTITY" ] \
   && [ "$RESPONSE_FILE" = "${PROMPT_FILE%.prompt.md}.response.md" ] && [ -s "$PROMPT_FILE" ] \
   && [ "$(codex_launch_count)" -eq $((STATE_ONLY_CODEX + 1)) ] \
   && [ "$(claude_launch_count)" = "$STATE_ONLY_CLAUDE" ] \
   && ! grep -qF 'cannot safely resume the saved host delegation:' "$RUN_ERR"; then
  ok "正常なstate-onlyは同じgeneration/identityでhandoffを再作成する"
else bad "正常なstate-onlyを破損扱いした、または別世代へ移した（rc=${RUN_RC}）"; fi
printf -- '- verdict: none\n- STATE_ONLY_ADOPTED\n' > "$RESPONSE_FILE"
STATE_ONLY_SUB_HASH="$(git hash-object "$STATE_ONLY_OUT/codex-cli/code-review.md")"
STATE_ONLY_CODEX="$(codex_launch_count)"
run_ma state-only-adopt "${STATE_ONLY_ARGS[@]}" --resume
if [ "$RUN_RC" -eq 0 ] && grep -qF STATE_ONLY_ADOPTED "$STATE_ONLY_OUT/claude-code/code-review.md" \
   && [ "$(codex_launch_count)" = "$STATE_ONLY_CODEX" ] \
   && [ "$(git hash-object "$STATE_ONLY_OUT/codex-cli/code-review.md")" = "$STATE_ONLY_SUB_HASH" ]; then
  ok "state-only再開後の応答は次1回で採用し、副CLIの結果を保つ"
else bad "state-only再開後の応答が次1回で採用されない（rc=${RUN_RC}）"; fi

echo "-- base advance adopts the same delegation when the diff hash is unchanged --"
BASE_ADV_OLD="$(git -C "$REPO" rev-parse develop)"
BASE_ADV_HEAD="$(git -C "$REPO" rev-parse HEAD)"
BASE_ADV_BRANCH="$(git -C "$REPO" branch --show-current)"
BASE_ADV_REMOTE="$(git -C "$REPO" rev-parse refs/remotes/origin/develop 2>/dev/null || true)"
BASE_ADV_OUT="$TMP/base-advance-results"
BASE_ADV_ARGS=(--task review --mode cross-model --perspective code-review --base develop
  --cli claude-code --cli codex-cli --delegate-to-host --description "base-advance original"
  --output-dir "$BASE_ADV_OUT" --sequential)
run_ma base-adv-initial "${BASE_ADV_ARGS[@]}"
if [ "$RUN_RC" -eq 3 ] && [ -n "${RESPONSE_FILE:-}" ]; then
  ok "base 前進の初期委譲は応答待ちで止まる"
  printf '%s\n' '- Critical: 0' '- Important: 0' '- verdict: none' '- BASE_ADV_ADOPTED' > "$RESPONSE_FILE"
else
  bad "base 前進の初期委譲が応答待ちにならない（rc=${RUN_RC}）"
fi
BASE_ADV_CODEX="$(codex_launch_count)"
run_ma base-adv-adopt "${BASE_ADV_ARGS[@]}" --resume
if [ "$RUN_RC" -eq 0 ] && [ "$(codex_launch_count)" = "$BASE_ADV_CODEX" ] \
   && ! grep -qF 'ERROR: --resume input differs' "$RUN_ERR" \
   && grep -qF BASE_ADV_ADOPTED "$BASE_ADV_OUT/claude-code/code-review.md"; then
  ok "未回収の resume は委譲応答を採用し、完了済みの副 CLI を再起動しない"
else
  bad "未回収の resume が委譲応答を採用しない（rc=${RUN_RC} codex=$(codex_launch_count)/${BASE_ADV_CODEX}）"
fi

echo "-- recorded OID spelling adopts a still-pending delegation --"
BASE_SPELL_OUT="$TMP/base-spelling-results"
BASE_SPELL_ARGS=(--task review --mode cross-model --perspective code-review --base develop
  --cli claude-code --cli codex-cli --delegate-to-host --description "base-spelling original"
  --output-dir "$BASE_SPELL_OUT" --sequential)
run_ma base-spell-initial "${BASE_SPELL_ARGS[@]}"
if [ "$RUN_RC" -eq 3 ] && [ -n "${RESPONSE_FILE:-}" ]; then
  printf '%s\n' '- Critical: 0' '- Important: 0' '- verdict: none' '- BASE_SPELL_ADOPTED' > "$RESPONSE_FILE"
fi
BASE_SPELL_CODEX="$(codex_launch_count)"
run_ma base-spell-resume --task review --mode cross-model --perspective code-review --base "$BASE_ADV_OLD" \
  --cli claude-code --cli codex-cli --delegate-to-host --description "base-spelling original" \
  --output-dir "$BASE_SPELL_OUT" --sequential --resume
if [ "$RUN_RC" -eq 0 ] && [ "$(codex_launch_count)" = "$BASE_SPELL_CODEX" ] \
   && ! grep -qF 'ERROR: --resume input differs' "$RUN_ERR" \
   && grep -qF BASE_SPELL_ADOPTED "$BASE_SPELL_OUT/claude-code/code-review.md"; then
  ok "記録した OID を --base に渡しても未回収の委譲結果を採用する"
else
  bad "記録した OID の --base が base-ref の二重拒否になった（rc=${RUN_RC}）"
fi

echo "-- ancestor base adopts a still-pending delegation when the diff hash is unchanged --"
BASE_ANC_OUT="$TMP/base-ancestor-results"
BASE_ANC_ARGS=(--task review --mode cross-model --perspective code-review --base develop
  --cli claude-code --cli codex-cli --delegate-to-host --description "base-ancestor original"
  --output-dir "$BASE_ANC_OUT" --sequential)
run_ma base-anc-initial "${BASE_ANC_ARGS[@]}"
if [ "$RUN_RC" -eq 3 ] && [ -n "${RESPONSE_FILE:-}" ]; then
  printf '%s\n' '- Critical: 0' '- Important: 0' '- verdict: none' '- BASE_ANC_ADOPTED' > "$RESPONSE_FILE"
fi
BASE_ANC_CODEX="$(codex_launch_count)"
git -C "$REPO" switch -q develop
printf 'side\n' > "$REPO/side-base.txt"
git -C "$REPO" add side-base.txt
git -C "$REPO" commit -qm "side base"
git -C "$REPO" switch -q "$BASE_ADV_BRANCH"
run_ma base-anc-resume "${BASE_ANC_ARGS[@]}" --resume
if [ "$RUN_RC" -eq 0 ] && [ "$(git -C "$REPO" rev-parse HEAD)" = "$BASE_ADV_HEAD" ] \
   && [ "$(codex_launch_count)" = "$BASE_ANC_CODEX" ] \
   && ! grep -qF 'ERROR: --resume input differs' "$RUN_ERR" \
   && grep -qF BASE_ANC_ADOPTED "$BASE_ANC_OUT/claude-code/code-review.md"; then
  ok "祖先 base で diff hash が同じ resume は同じ世代を採用し、副 CLI を再起動しない"
else
  bad "祖先 base の resume が同じ世代を採用しない（rc=${RUN_RC} codex=$(codex_launch_count)/${BASE_ANC_CODEX}）"
fi
git -C "$REPO" branch -f develop "$BASE_ADV_OLD"

echo "-- non-ancestor base with the same fixed diff names the recorded OID --"
BASE_REJ_OUT="$TMP/base-reject-results"
BASE_REJ_ARGS=(--task review --mode cross-model --perspective code-review --base develop
  --cli claude-code --cli codex-cli --delegate-to-host --description "base-reject original"
  --output-dir "$BASE_REJ_OUT" --sequential)
run_ma base-rej-initial "${BASE_REJ_ARGS[@]}"
BASE_REJ_TREE="$(git -C "$REPO" rev-parse "${BASE_ADV_OLD}^{tree}")"
BASE_REJ_ROOT="$(git -C "$REPO" commit-tree "$BASE_REJ_TREE" -m 'not an ancestor')"
BASE_REJ_MANIFEST="$BASE_REJ_OUT/.delegation-state/manifest"
BASE_REJ_META="$BASE_REJ_OUT/.delegation-state/metadata"
awk -v new="$BASE_REJ_ROOT" '
  index($0, "base-oid=") == 1 { print "base-oid=" new; next }
  { print }
' "$BASE_REJ_MANIFEST" > "$BASE_REJ_MANIFEST.new"
mv "$BASE_REJ_MANIFEST.new" "$BASE_REJ_MANIFEST"
BASE_REJ_ID="$(git hash-object --no-filters "$BASE_REJ_MANIFEST")"
awk -v id="$BASE_REJ_ID" 'index($0, "identity=") == 1 { print "identity=" id; next } { print }' \
  "$BASE_REJ_META" > "$BASE_REJ_META.new"
mv "$BASE_REJ_META.new" "$BASE_REJ_META"
run_ma base-rej-resume "${BASE_REJ_ARGS[@]}" --resume
if [ "$RUN_RC" -ne 0 ] && grep -qF 'ERROR: --resume input differs' "$RUN_ERR" \
   && grep -qF "Recorded base OID: ${BASE_REJ_ROOT}" "$RUN_ERR" \
   && grep -qF 'Keep the original --base spelling.' "$RUN_ERR" \
   && grep -qF 'Do not rewrite refs/remotes/origin/develop.' "$RUN_ERR" \
   && grep -qF 'Passing --base <recorded OID> is not a second base-ref rejection when the diff hash is unchanged.' "$RUN_ERR" \
   && grep -qF 'If the diff hash changed, or the recorded OID is not an ancestor' "$RUN_ERR"; then
  ok "祖先でない base は記録 OID と二重拒否しない手順を出して拒否する"
else
  bad "祖先でない base の拒否案内が足りない（rc=${RUN_RC}）"
fi
BASE_REJ_NOW="$(git -C "$REPO" rev-parse develop)"
BASE_REJ_REMOTE="$(git -C "$REPO" rev-parse refs/remotes/origin/develop 2>/dev/null || true)"
if [ "$BASE_REJ_NOW" = "$BASE_ADV_OLD" ] && [ "$BASE_REJ_REMOTE" = "$BASE_ADV_REMOTE" ]; then
  ok "resume の拒否は develop と refs/remotes/origin/develop を書き換えない"
else
  bad "resume の拒否が develop または remote-tracking ref を変えた"
fi

echo "-- changed diff still rejects a base move --"
BASE_DIFF_OUT="$TMP/base-diff-results"
BASE_DIFF_ARGS=(--task review --mode cross-model --perspective code-review --base develop
  --cli claude-code --cli codex-cli --delegate-to-host --description "base-diff original"
  --output-dir "$BASE_DIFF_OUT" --sequential)
run_ma base-diff-initial "${BASE_DIFF_ARGS[@]}"
if [ "$RUN_RC" -eq 3 ] && [ -n "${RESPONSE_FILE:-}" ]; then
  printf '%s\n' '- Critical: 0' '- Important: 0' '- verdict: none' > "$RESPONSE_FILE"
fi
BASE_DIFF_ROOT="$(git -C "$REPO" commit-tree "$BASE_REJ_TREE" -m 'different history')"
git -C "$REPO" branch -f develop "$BASE_DIFF_ROOT"
run_ma base-diff-reject "${BASE_DIFF_ARGS[@]}" --resume
if [ "$RUN_RC" -ne 0 ] && grep -qF 'ERROR: --resume input differs' "$RUN_ERR" \
   && grep -qF "Recorded base OID: ${BASE_ADV_OLD}" "$RUN_ERR" \
   && grep -qF 'Do not rewrite refs/remotes/origin/develop.' "$RUN_ERR" \
   && ! grep -qF 'Keep the original --base spelling.' "$RUN_ERR"; then
  ok "diff が変わる base 移動は resume を拒否する"
else
  bad "diff が変わる base 移動を resume が採用した（rc=${RUN_RC}）"
fi
git -C "$REPO" branch -f develop "$BASE_ADV_OLD"
git -C "$REPO" switch -q "$BASE_ADV_BRANCH"

echo "-- ancestor base whose diff hash changed rejects resume --"
printf 'extra\n' > "$REPO/shrink-extra.txt"
git -C "$REPO" add shrink-extra.txt
git -C "$REPO" commit -qm "shrink the remaining diff"
BASE_SHRINK_OUT="$TMP/base-shrink-results"
BASE_SHRINK_ARGS=(--task review --mode cross-model --perspective code-review --base develop
  --cli claude-code --cli codex-cli --delegate-to-host --description "base-shrink original"
  --output-dir "$BASE_SHRINK_OUT" --sequential)
run_ma base-shrink-initial "${BASE_SHRINK_ARGS[@]}"
if [ "$RUN_RC" -eq 3 ] && [ -n "${RESPONSE_FILE:-}" ]; then
  printf '%s\n' '- Critical: 0' '- Important: 0' '- verdict: none' '- BASE_SHRINK_PENDING' > "$RESPONSE_FILE"
fi
git -C "$REPO" branch -f develop "$BASE_ADV_HEAD"
run_ma base-shrink-resume "${BASE_SHRINK_ARGS[@]}" --resume
if [ "$RUN_RC" -ne 0 ] && grep -qF 'ERROR: --resume input differs' "$RUN_ERR" \
   && grep -qF "Recorded base OID: ${BASE_ADV_OLD}" "$RUN_ERR" \
   && grep -qF 'Do not rewrite refs/remotes/origin/develop.' "$RUN_ERR" \
   && ! grep -qF 'Keep the original --base spelling.' "$RUN_ERR"; then
  ok "祖先で diff hash が変わる base 前進は resume を採用しない"
else
  bad "祖先で diff hash が変わる resume を採用した（rc=${RUN_RC}）"
fi
git -C "$REPO" reset -q --hard "$BASE_ADV_HEAD"
git -C "$REPO" branch -f develop "$BASE_ADV_OLD"
git -C "$REPO" switch -q "$BASE_ADV_BRANCH"

echo "-- prior or continued evidence tells the operator to exclude the failed CLI --"
# Earlier cases leave the default .review-results inside the fixture repo. Evidence
# refuses a dirty worktree, so park that output outside the repo and restore it after.
EV_PARK="$TMP/ev-park"
mkdir -p "$EV_PARK"
if [ -e "$REPO/.review-results" ]; then
  mv "$REPO/.review-results" "$EV_PARK/review-results"
fi
EV_STATUS="$(git -C "$REPO" status --porcelain --untracked-files=all)"
if [ -z "$EV_STATUS" ]; then
  ok "継続証跡の前に fixture の作業ツリーは clean"
else
  bad "継続証跡の前に fixture の作業ツリーが汚れている"
  printf '%s\n' "$EV_STATUS" >&2
fi
EV_PARENT="$TMP/parent-ev-2502"
EV_CONT="$TMP/continue-ev-2502"
EV_CODEX_GOOD="$TMP/codex-good"
cp "$STUB/codex" "$EV_CODEX_GOOD"
run_ma ev-parent --task review --mode cross-model --perspective code-review --base develop \
  --cli claude-code --cli codex-cli --evidence --sequential --timeout 30 \
  --output-dir "$EV_PARENT"
if [ "$RUN_RC" -eq 0 ] && [ -f "$EV_PARENT/review-evidence.json" ]; then
  ok "継続の親になる evidence を両方の CLI で作れる"
else
  bad "継続の親 evidence を作れない（rc=${RUN_RC}）"
  tail -n 30 "$RUN_ERR" >&2 || true
fi
cat > "$STUB/codex" <<'SH'
#!/usr/bin/env bash
cat >/dev/null
printf 'codex\n' >> "${FF_TEST_CODEX_COUNT:?}"
exit 1
SH
chmod +x "$STUB/codex"
run_ma ev-fail --task review --mode cross-model --perspective code-review --base develop \
  --cli claude-code --cli codex-cli --evidence --continue-review "$EV_PARENT/review-evidence.json" \
  --sequential --timeout 30 --output-dir "$EV_CONT"
grep -vF 'cannot be combined with --resume' "$RUN_ERR" >"$TMP/ev-resume-left.txt" || true
if [ "$RUN_RC" -ne 0 ] && grep -qF -- '--exclude-cli codex-cli' "$RUN_ERR" \
   && grep -qF -- "$EV_CONT" "$RUN_ERR" \
   && ! grep -qF -- '--resume' "$TMP/ev-resume-left.txt"; then
  ok "先行・継続の失敗案内は同じ出力先の --exclude-cli で、--resume の再実行を出さない"
else
  bad "先行・継続の失敗案内が --exclude-cli ではない、または --resume を勧めている（rc=${RUN_RC}）"
fi
cp "$EV_CODEX_GOOD" "$STUB/codex"
chmod +x "$STUB/codex"
EV_ADVICE_LINE=""
while IFS= read -r EV_ADVICE_CANDIDATE; do
  case "$EV_ADVICE_CANDIDATE" in
    *"--exclude-cli codex-cli"*) EV_ADVICE_LINE="$EV_ADVICE_CANDIDATE"; break ;;
  esac
done < "$RUN_ERR"
EV_ADVICE_LINE="${EV_ADVICE_LINE#"${EV_ADVICE_LINE%%[![:space:]]*}"}"
case "$EV_ADVICE_LINE" in
  *" --cli codex-cli"* | *" --cli=codex-cli"* | *" --route full"* | *" --route fast"* | *" --route=full"* | *" --route=fast"*)
    bad "案内コマンドが失敗 CLI の --cli または --route full/fast を残している"
    ;;
  *"--exclude-cli codex-cli"*)
    ok "案内コマンドは失敗 CLI の --cli を外した --exclude-cli である"
    ;;
  *)
    bad "exclude-cli の案内コマンドを取り出せない"
    ;;
esac
EV_RERUN_RC=0
run_isolated PATH="$STUB_PATH" HOME="$TMP/home" \
  FF_DEV_TOOLKIT_ROOT="$PLUGIN_ROOT" \
  bash -c "$EV_ADVICE_LINE" > "$TMP/ev-rerun.out" 2> "$TMP/ev-rerun.err" || EV_RERUN_RC=$?
RUN_RC="$EV_RERUN_RC"
RUN_ERR="$TMP/ev-rerun.err"
EV_VERIFY_RC=0
python3 -B "$PLUGIN_ROOT/scripts/review-evidence.py" verify \
  --file "$EV_CONT/review-evidence.json" --output "$EV_CONT" \
  --base develop --required code-review >/dev/null 2>"$TMP/ev-verify.err" || EV_VERIFY_RC=$?
if [ "$RUN_RC" -eq 0 ] && [ "$EV_VERIFY_RC" -eq 0 ] \
   && python3 -B -c 'import json,sys; r=json.load(open(sys.argv[1])); assert r.get("parent")' \
        "$EV_CONT/review-evidence.json"; then
  ok "失敗した CLI を外した再実行は同じ出力先で継続の系譜を verify できる"
else
  bad "exclude-cli の再実行が継続の系譜を完了しない（rc=${RUN_RC} verify=${EV_VERIFY_RC}）"
  tail -n 20 "$RUN_ERR" >&2 || true
  tail -n 20 "$TMP/ev-verify.err" >&2 || true
fi

echo "-- distributed --cli keeps failed perspectives on the rerun --"
EV_DIST_PARENT="$TMP/dist-parent-2502"
EV_DIST_CONT="$TMP/dist-cont-2502"
run_ma ev-dist-parent --task review --mode distributed --base develop \
  --cli claude-code --cli codex-cli --evidence --sequential --timeout 30 \
  --output-dir "$EV_DIST_PARENT"
if [ "$RUN_RC" -eq 0 ] && [ -f "$EV_DIST_PARENT/review-evidence.json" ]; then
  ok "distributed の親 evidence を両方の CLI で作れる"
else
  bad "distributed の親 evidence を作れない（rc=${RUN_RC}）"
  tail -n 30 "$RUN_ERR" >&2 || true
fi
cat > "$STUB/codex" <<'SH'
#!/usr/bin/env bash
cat >/dev/null
printf 'codex\n' >> "${FF_TEST_CODEX_COUNT:?}"
exit 1
SH
chmod +x "$STUB/codex"
run_ma ev-dist-fail --task review --mode distributed --base develop \
  --cli claude-code --cli codex-cli --evidence \
  --continue-review "$EV_DIST_PARENT/review-evidence.json" \
  --sequential --timeout 30 --output-dir "$EV_DIST_CONT"
EV_DIST_LINE=""
while IFS= read -r EV_ADVICE_CANDIDATE; do
  case "$EV_ADVICE_CANDIDATE" in
    *"--exclude-cli codex-cli"*) EV_DIST_LINE="$EV_ADVICE_CANDIDATE"; break ;;
  esac
done < "$RUN_ERR"
EV_DIST_LINE="${EV_DIST_LINE#"${EV_DIST_LINE%%[![:space:]]*}"}"
EV_DIST_CLI_LEFT=false
case "$EV_DIST_LINE" in
  *" --cli "* | *" --cli="*) EV_DIST_CLI_LEFT=true ;;
esac
case "$EV_DIST_LINE" in
  *"--exclude-cli codex-cli"*--perspective\ code-review*--perspective\ test-analysis*--perspective\ acceptance-criteria*)
    if [ "$RUN_RC" -ne 0 ] && [ "$EV_DIST_CLI_LEFT" = false ]; then
      ok "distributed の失敗案内は --cli を外し失敗観点を --perspective で残す"
    else
      bad "distributed の失敗案内が観点を残していない（rc=${RUN_RC}）"
      printf '  line: %s\n' "$EV_DIST_LINE" >&2
    fi
    ;;
  *)
    bad "distributed の失敗案内が観点を残していない（rc=${RUN_RC}）"
    printf '  line: %s\n' "$EV_DIST_LINE" >&2
    ;;
esac
cp "$EV_CODEX_GOOD" "$STUB/codex"
chmod +x "$STUB/codex"
EV_RERUN_RC=0
run_isolated PATH="$STUB_PATH" HOME="$TMP/home" \
  FF_DEV_TOOLKIT_ROOT="$PLUGIN_ROOT" \
  bash -c "$EV_DIST_LINE" > "$TMP/ev-dist-rerun.out" 2> "$TMP/ev-dist-rerun.err" || EV_RERUN_RC=$?
RUN_RC="$EV_RERUN_RC"
RUN_ERR="$TMP/ev-dist-rerun.err"
EV_VERIFY_RC=0
python3 -B "$PLUGIN_ROOT/scripts/review-evidence.py" verify \
  --file "$EV_DIST_CONT/review-evidence.json" --output "$EV_DIST_CONT" \
  --base develop --required code-review,test-analysis,acceptance-criteria \
  >/dev/null 2>"$TMP/ev-dist-verify.err" || EV_VERIFY_RC=$?
if [ "$RUN_RC" -eq 0 ] && [ "$EV_VERIFY_RC" -eq 0 ] \
   && python3 -B -c 'import json,sys; r=json.load(open(sys.argv[1])); \
assert r["results"].get("claude-code:code-review")=="complete"; \
assert r["results"].get("claude-code:test-analysis")=="complete"; \
assert r["results"].get("claude-code:acceptance-criteria")=="complete"; \
assert "codex-cli:code-review" not in r["results"]; assert r.get("parent")' \
        "$EV_DIST_CONT/review-evidence.json"; then
  ok "distributed の再実行は失敗観点を別 CLI で完走し継続の系譜を verify できる"
else
  bad "distributed の再実行が失敗観点を別 CLI で完走しない（rc=${RUN_RC} verify=${EV_VERIFY_RC}）"
  tail -n 40 "$RUN_ERR" >&2 || true
  tail -n 20 "$TMP/ev-dist-verify.err" >&2 || true
fi

# 失敗した CLI の案内を 1 本取り出す（先頭の空白を落とす）。
lineage_advice_line() { # <needle>
  LINEAGE_LINE=""
  local candidate
  while IFS= read -r candidate; do
    case "$candidate" in
      *"$1"*) LINEAGE_LINE="$candidate"; break ;;
    esac
  done < "$RUN_ERR"
  LINEAGE_LINE="${LINEAGE_LINE#"${LINEAGE_LINE%%[![:space:]]*}"}"
}

echo "-- implicit distributed (--cli without --mode) keeps its mode on the rerun --"
EV_IMPL_PARENT="$TMP/impl-parent-2646"
EV_IMPL_CONT="$TMP/impl-cont-2646"
cp "$EV_CODEX_GOOD" "$STUB/codex"
chmod +x "$STUB/codex"
run_ma ev-impl-parent --task review --base develop \
  --cli claude-code --cli codex-cli --evidence --sequential --timeout 30 \
  --output-dir "$EV_IMPL_PARENT"
if [ "$RUN_RC" -eq 0 ] && [ -f "$EV_IMPL_PARENT/review-evidence.json" ]; then
  ok "--mode を省いた --cli の親 evidence を作れる"
else
  bad "--mode を省いた --cli の親 evidence を作れない（rc=${RUN_RC}）"
  tail -n 30 "$RUN_ERR" >&2 || true
fi
cat > "$STUB/codex" <<'SH'
#!/usr/bin/env bash
cat >/dev/null
printf 'codex\n' >> "${FF_TEST_CODEX_COUNT:?}"
exit 1
SH
chmod +x "$STUB/codex"
run_ma ev-impl-fail --task review --base develop \
  --cli claude-code --cli codex-cli --evidence \
  --continue-review "$EV_IMPL_PARENT/review-evidence.json" \
  --sequential --timeout 30 --output-dir "$EV_IMPL_CONT"
lineage_advice_line "--exclude-cli codex-cli"
case "$LINEAGE_LINE" in
  *" --mode distributed"*"--exclude-cli codex-cli"*)
    ok "--cli だけで distributed になった実行の案内は --mode distributed を固定する"
    ;;
  *)
    bad "--cli だけで distributed になった実行の案内が実効 mode を固定していない（pair へ戻る）"
    printf '  line: %s\n' "$LINEAGE_LINE" >&2
    ;;
esac
cp "$EV_CODEX_GOOD" "$STUB/codex"
chmod +x "$STUB/codex"
EV_RERUN_RC=0
run_isolated PATH="$STUB_PATH" HOME="$TMP/home" \
  FF_DEV_TOOLKIT_ROOT="$PLUGIN_ROOT" \
  bash -c "$LINEAGE_LINE" > "$TMP/ev-impl-rerun.out" 2> "$TMP/ev-impl-rerun.err" || EV_RERUN_RC=$?
EV_VERIFY_RC=0
python3 -B "$PLUGIN_ROOT/scripts/review-evidence.py" verify \
  --file "$EV_IMPL_CONT/review-evidence.json" --output "$EV_IMPL_CONT" \
  --base develop --required code-review,test-analysis,acceptance-criteria \
  >/dev/null 2>"$TMP/ev-impl-verify.err" || EV_VERIFY_RC=$?
if [ "$EV_RERUN_RC" -eq 0 ] && [ "$EV_VERIFY_RC" -eq 0 ]; then
  ok "--mode を省いた実行の案内コマンドは distributed のまま失敗観点を完走する"
else
  bad "--mode を省いた実行の案内コマンドが完走しない（rc=${EV_RERUN_RC} verify=${EV_VERIFY_RC}）"
  tail -n 30 "$TMP/ev-impl-rerun.err" >&2 || true
  tail -n 20 "$TMP/ev-impl-verify.err" >&2 || true
fi

echo "-- single --cli with explicit perspectives swaps the CLI instead of dropping it --"
EV_ONE_PARENT="$TMP/one-parent-2646"
EV_ONE_CONT="$TMP/one-cont-2646"
run_ma ev-one-parent --task review --mode distributed --base develop \
  --cli codex-cli --perspective comprehensive-review --evidence --sequential --timeout 30 \
  --output-dir "$EV_ONE_PARENT"
if [ "$RUN_RC" -eq 0 ] && [ -f "$EV_ONE_PARENT/review-evidence.json" ]; then
  ok "単一 --cli + 観点明示の親 evidence を作れる"
else
  bad "単一 --cli + 観点明示の親 evidence を作れない（rc=${RUN_RC}）"
  tail -n 30 "$RUN_ERR" >&2 || true
fi
cat > "$STUB/codex" <<'SH'
#!/usr/bin/env bash
cat >/dev/null
printf 'codex\n' >> "${FF_TEST_CODEX_COUNT:?}"
exit 1
SH
chmod +x "$STUB/codex"
run_ma ev-one-fail --task review --mode distributed --base develop \
  --cli codex-cli --perspective comprehensive-review --evidence \
  --continue-review "$EV_ONE_PARENT/review-evidence.json" \
  --sequential --timeout 30 --output-dir "$EV_ONE_CONT"
lineage_advice_line "--exclude-cli codex-cli"
case "$LINEAGE_LINE" in
  *" --cli codex-cli"* | *" --cli=codex-cli"*)
    bad "単一 --cli の案内が失敗した CLI の --cli を残している"
    printf '  line: %s\n' "$LINEAGE_LINE" >&2
    ;;
  *"--perspective comprehensive-review"*" --cli claude-code"*"--exclude-cli codex-cli"*)
    ok "単一 --cli + 観点明示の案内は失敗した CLI の --cli を代替 CLI へ置き換える"
    ;;
  *)
    bad "単一 --cli + 観点明示の案内が代替 CLI へ置き換えていない（観点が担当表で消える）"
    printf '  line: %s\n' "$LINEAGE_LINE" >&2
    ;;
esac
cp "$EV_CODEX_GOOD" "$STUB/codex"
chmod +x "$STUB/codex"
EV_RERUN_RC=0
run_isolated PATH="$STUB_PATH" HOME="$TMP/home" \
  FF_DEV_TOOLKIT_ROOT="$PLUGIN_ROOT" \
  bash -c "$LINEAGE_LINE" > "$TMP/ev-one-rerun.out" 2> "$TMP/ev-one-rerun.err" || EV_RERUN_RC=$?
EV_VERIFY_RC=0
python3 -B "$PLUGIN_ROOT/scripts/review-evidence.py" verify \
  --file "$EV_ONE_CONT/review-evidence.json" --output "$EV_ONE_CONT" \
  --base develop --required comprehensive-review \
  >/dev/null 2>"$TMP/ev-one-verify.err" || EV_VERIFY_RC=$?
if [ "$EV_RERUN_RC" -eq 0 ] && [ "$EV_VERIFY_RC" -eq 0 ] \
   && python3 -B -c 'import json,sys; r=json.load(open(sys.argv[1])); \
assert r["results"].get("claude-code:comprehensive-review")=="complete"; assert r.get("parent")' \
        "$EV_ONE_CONT/review-evidence.json"; then
  ok "単一 --cli の案内コマンドは担当表に無い観点も代替 CLI で完走する"
else
  bad "単一 --cli の案内コマンドが観点を完走しない（rc=${EV_RERUN_RC} verify=${EV_VERIFY_RC}）"
  tail -n 30 "$TMP/ev-one-rerun.err" >&2 || true
  tail -n 20 "$TMP/ev-one-verify.err" >&2 || true
fi

echo "-- multi-review --route fast drops route from the failure advice --"
EV_ROUTE_PARENT="$TMP/route-parent-2502"
EV_ROUTE_CONT="$TMP/route-cont-2502"
MA_ENTRY="$PLUGIN_ROOT/scripts/multi-review.sh"
run_ma ev-route-parent --route fast --base develop --description route-evidence \
  --evidence --sequential --timeout 30 --output-dir "$EV_ROUTE_PARENT"
if [ "$RUN_RC" -eq 0 ] && [ -f "$EV_ROUTE_PARENT/review-evidence.json" ]; then
  ok "route fast の親 evidence を作れる"
else
  bad "route fast の親 evidence を作れない（rc=${RUN_RC}）"
  tail -n 30 "$RUN_ERR" >&2 || true
fi
cat > "$STUB/codex" <<'SH'
#!/usr/bin/env bash
cat >/dev/null
printf 'codex\n' >> "${FF_TEST_CODEX_COUNT:?}"
exit 1
SH
chmod +x "$STUB/codex"
run_ma ev-route-fail --route fast --base develop --description route-evidence \
  --evidence --continue-review "$EV_ROUTE_PARENT/review-evidence.json" \
  --sequential --timeout 30 --output-dir "$EV_ROUTE_CONT"
unset MA_ENTRY
EV_ROUTE_LINE=""
while IFS= read -r EV_ADVICE_CANDIDATE; do
  case "$EV_ADVICE_CANDIDATE" in
    *"--exclude-cli codex-cli"*) EV_ROUTE_LINE="$EV_ADVICE_CANDIDATE"; break ;;
  esac
done < "$RUN_ERR"
EV_ROUTE_LINE="${EV_ROUTE_LINE#"${EV_ROUTE_LINE%%[![:space:]]*}"}"
case "$EV_ROUTE_LINE" in
  *" --route full"* | *" --route fast"* | *" --route=full"* | *" --route=fast"* \
    | *"--wrapper-route fast"* | *"--wrapper-route full"* | *" --wrapper-route=fast"* \
    | *" --wrapper-route=full"* | *" --cli codex-cli"* | *" --cli=codex-cli"*)
    bad "route fast の案内が --route / --wrapper-route / 失敗 CLI の --cli を残している"
    printf '  line: %s\n' "$EV_ROUTE_LINE" >&2
    ;;
  *"--exclude-cli codex-cli"*)
    ok "route fast の案内は --wrapper-route と失敗 CLI の --cli を外した --exclude-cli である"
    ;;
  *)
    bad "route fast の exclude-cli 案内を取り出せない（rc=${RUN_RC}）"
    tail -n 40 "$RUN_ERR" >&2 || true
    ;;
esac
cp "$EV_CODEX_GOOD" "$STUB/codex"
chmod +x "$STUB/codex"
EV_RERUN_RC=0
run_isolated PATH="$STUB_PATH" HOME="$TMP/home" \
  FF_DEV_TOOLKIT_ROOT="$PLUGIN_ROOT" \
  bash -c "$EV_ROUTE_LINE" > "$TMP/ev-route-rerun.out" 2> "$TMP/ev-route-rerun.err" || EV_RERUN_RC=$?
RUN_RC="$EV_RERUN_RC"
RUN_ERR="$TMP/ev-route-rerun.err"
EV_VERIFY_RC=0
python3 -B "$PLUGIN_ROOT/scripts/review-evidence.py" verify \
  --file "$EV_ROUTE_CONT/review-evidence.json" --output "$EV_ROUTE_CONT" \
  --base develop --required comprehensive-review \
  >/dev/null 2>"$TMP/ev-route-verify.err" || EV_VERIFY_RC=$?
if [ "$RUN_RC" -eq 0 ] && [ "$EV_VERIFY_RC" -eq 0 ] \
   && python3 -B -c 'import json,sys; r=json.load(open(sys.argv[1])); \
assert r["results"].get("claude-code:comprehensive-review")=="complete"; \
assert "codex-cli:comprehensive-review" not in r["results"]; assert r.get("parent")' \
        "$EV_ROUTE_CONT/review-evidence.json"; then
  ok "route fast の再実行は総合観点を別 CLI で完走し継続の系譜を verify できる"
else
  bad "route fast の再実行が継続の系譜を完了しない（rc=${RUN_RC} verify=${EV_VERIFY_RC}）"
  tail -n 40 "$RUN_ERR" >&2 || true
  tail -n 20 "$TMP/ev-route-verify.err" >&2 || true
fi
# pair の主は --exclude-cli で外せない。落ちた主は別の主へ差し替え、落ちた副の総合観点は
# 副任せにせずその主へ移す。打ち直すと別 CLI で完走し、継続の系譜が verify できる。
PAIR_XDG="$TMP/pair-xdg"
mkdir -p "$PAIR_XDG/ff-dev-toolkit"
PAIR_REVIEWERS="$PAIR_XDG/ff-dev-toolkit/reviewers"
printf '%s\n' 'main=claude-code' 'sub=codex-cli' > "$PAIR_REVIEWERS"
EV_CLAUDE_GOOD="$TMP/claude-good"
cp "$STUB/claude" "$EV_CLAUDE_GOOD"
run_ma_pair() {
  local label="$1"; shift
  OUT_N=$((OUT_N + 1))
  RUN_OUT="$TMP/out.${OUT_N}.${label}"
  RUN_ERR="$TMP/err.${OUT_N}.${label}"
  RUN_RC=0
  run_isolated PATH="$STUB_PATH" HOME="$TMP/home" XDG_CONFIG_HOME="$PAIR_XDG" \
    FF_DEV_TOOLKIT_ROOT="$PLUGIN_ROOT" bash "$MULTI_AGENT" "$@" > "$RUN_OUT" 2> "$RUN_ERR" || RUN_RC=$?
}
pair_advice_line() { # <needle>
  PAIR_ADVICE_LINE=""
  local candidate
  while IFS= read -r candidate; do
    case "$candidate" in
      *"MULTI_AGENT_REVIEW_MAIN="*"bash "*) PAIR_ADVICE_LINE="$candidate"; break ;;
    esac
  done < "$RUN_ERR"
  PAIR_ADVICE_LINE="${PAIR_ADVICE_LINE#"${PAIR_ADVICE_LINE%%[![:space:]]*}"}"
}
echo "-- pair main failure switches the main instead of excluding it --"
EV_PAIR_PARENT="$TMP/pair-parent-main"
EV_PAIR_CONT="$TMP/pair-cont-main"
run_ma_pair pair-main-parent --task review --mode pair --perspective code-review --base develop \
  --evidence --sequential --timeout 30 --output-dir "$EV_PAIR_PARENT"
if [ "$RUN_RC" -eq 0 ] && [ -f "$EV_PAIR_PARENT/review-evidence.json" ]; then
  ok "pair の主だけの親 evidence を作れる"
else
  bad "pair の主だけの親 evidence を作れない（rc=${RUN_RC}）"
  tail -n 30 "$RUN_ERR" >&2 || true
fi
cat > "$STUB/claude" << 'SH'
#!/usr/bin/env bash
cat >/dev/null
exit 1
SH
chmod +x "$STUB/claude"
cp "$PAIR_REVIEWERS" "$TMP/pair-reviewers-before"
# multi-review 経由の実行と同じく --wrapper-route full と表示文字列を付ける。案内がこれを引き継ぐと、
# 委譲のハンドオフが元のコマンドを「Re-run command」として出し、失敗した主へ戻る案内と循環する。
run_ma_pair pair-main-fail --task review --mode pair --perspective code-review --base develop \
  --evidence --continue-review "$EV_PAIR_PARENT/review-evidence.json" \
  --wrapper-route full --invocation-display 'bash multi-review.sh --route full --base develop' \
  --sequential --timeout 30 --output-dir "$EV_PAIR_CONT"
grep -vF 'cannot be combined with --resume' "$RUN_ERR" > "$TMP/pair-main-resume-left.txt" || true
if [ "$RUN_RC" -ne 0 ] && grep -qF -- 'MULTI_AGENT_REVIEW_MAIN=codex-cli' "$RUN_ERR" \
   && grep -qF -- '--set-reviewers' "$RUN_ERR" \
   && grep -qF -- "$EV_PAIR_CONT" "$RUN_ERR" \
   && ! grep -qF -- '--exclude-cli claude-code' "$RUN_ERR" \
   && ! grep -qF -- '--resume' "$TMP/pair-main-resume-left.txt"; then
  ok "pair の主の失敗案内は別の主で、--exclude-cli と --resume を出さない"
else
  bad "pair の主の失敗案内が別の主ではない（rc=${RUN_RC}）"
  tail -n 40 "$RUN_ERR" >&2 || true
fi
if cmp -s "$PAIR_REVIEWERS" "$TMP/pair-reviewers-before"; then
  ok "主の差し替え案内は reviewers 設定を保存しない"
else
  bad "主の差し替え案内が reviewers 設定を書き換えた"
fi
pair_advice_line
# 代替主が副と同じときは MULTI_AGENT_REVIEW_SUB= が bash の前に入る。
if [[ "$PAIR_ADVICE_LINE" == "MULTI_AGENT_REVIEW_MAIN=codex-cli "*"bash "*"--output-dir ${EV_PAIR_CONT}"* ]] \
   || [[ "$PAIR_ADVICE_LINE" == "MULTI_AGENT_REVIEW_MAIN=codex-cli "*"bash "*"--output-dir \"${EV_PAIR_CONT}\""* ]]; then
  ok "主の失敗案内コマンドは MULTI_AGENT_REVIEW_MAIN と同じ出力先である"
else
  bad "主の失敗案内コマンドを取り出せない"
  printf '  line: %s\n' "$PAIR_ADVICE_LINE" >&2
fi
case "$PAIR_ADVICE_LINE" in
  *"--invocation-display"* | *"--wrapper-route full"* | *"--wrapper-route=full"*)
    bad "主の差し替え案内が元の表示文字列か --wrapper-route full を引き継いでいる"
    printf '  line: %s\n' "$PAIR_ADVICE_LINE" >&2
    ;;
  "")
    bad "主の差し替え案内を取り出せない（表示文字列の除去を確かめられない）"
    ;;
  *)
    ok "主の差し替え案内は元の表示文字列と --wrapper-route full を引き継がない"
    ;;
esac
cp "$EV_CLAUDE_GOOD" "$STUB/claude"
chmod +x "$STUB/claude"
EV_RERUN_RC=0
run_isolated PATH="$STUB_PATH" HOME="$TMP/home" XDG_CONFIG_HOME="$PAIR_XDG" \
  FF_DEV_TOOLKIT_ROOT="$PLUGIN_ROOT" \
  bash -c "$PAIR_ADVICE_LINE" > "$TMP/pair-main-rerun.out" 2> "$TMP/pair-main-rerun.err" || EV_RERUN_RC=$?
RUN_RC="$EV_RERUN_RC"
RUN_ERR="$TMP/pair-main-rerun.err"
EV_VERIFY_RC=0
python3 -B "$PLUGIN_ROOT/scripts/review-evidence.py" verify \
  --file "$EV_PAIR_CONT/review-evidence.json" --output "$EV_PAIR_CONT" \
  --base develop --required code-review >/dev/null 2>"$TMP/pair-main-verify.err" || EV_VERIFY_RC=$?
if [ "$RUN_RC" -eq 0 ] && [ "$EV_VERIFY_RC" -eq 0 ] \
   && python3 -B -c 'import json,sys; r=json.load(open(sys.argv[1])); assert r["results"].get("codex-cli:code-review")=="complete"; assert r.get("parent")' \
        "$EV_PAIR_CONT/review-evidence.json"; then
  ok "別の主での再実行は code-review をその CLI で完走し継続の系譜を verify できる"
else
  bad "別の主での再実行が継続の系譜を完了しない（rc=${RUN_RC} verify=${EV_VERIFY_RC}）"
  tail -n 30 "$RUN_ERR" >&2 || true
  tail -n 20 "$TMP/pair-main-verify.err" >&2 || true
fi

echo "-- pair sub failure moves comprehensive-review onto another main --"
EV_PAIR_SUB_PARENT="$TMP/pair-parent-sub"
EV_PAIR_SUB_CONT="$TMP/pair-cont-sub"
run_ma_pair pair-sub-parent --task review --mode pair --perspective comprehensive-review --base develop \
  --evidence --sequential --timeout 30 --output-dir "$EV_PAIR_SUB_PARENT"
if [ "$RUN_RC" -eq 0 ] && [ -f "$EV_PAIR_SUB_PARENT/review-evidence.json" ]; then
  ok "pair の総合観点の親 evidence を作れる"
else
  bad "pair の総合観点の親 evidence を作れない（rc=${RUN_RC}）"
  tail -n 30 "$RUN_ERR" >&2 || true
fi
cat > "$STUB/codex" << 'SH'
#!/usr/bin/env bash
cat >/dev/null
exit 1
SH
chmod +x "$STUB/codex"
run_ma_pair pair-sub-fail --task review --mode pair --perspective comprehensive-review --base develop \
  --evidence --continue-review "$EV_PAIR_SUB_PARENT/review-evidence.json" \
  --sequential --timeout 30 --output-dir "$EV_PAIR_SUB_CONT"
grep -vF 'cannot be combined with --resume' "$RUN_ERR" > "$TMP/pair-sub-resume-left.txt" || true
if [ "$RUN_RC" -ne 0 ] && grep -qF -- 'MULTI_AGENT_REVIEW_MAIN=claude-code' "$RUN_ERR" \
   && grep -qF -- 'MULTI_AGENT_REVIEW_SUB=' "$RUN_ERR" \
   && grep -qF -- '--perspective comprehensive-review' "$RUN_ERR" \
   && grep -qF -- '--set-reviewers' "$RUN_ERR" \
   && ! grep -qF -- '--exclude-cli codex-cli' "$RUN_ERR" \
   && ! grep -qF -- '--resume' "$TMP/pair-sub-resume-left.txt"; then
  ok "pair の副の失敗案内は総合観点を別の主へ移し、--exclude-cli を出さない"
else
  bad "pair の副の失敗案内が総合観点を別の主へ移していない（rc=${RUN_RC}）"
  tail -n 40 "$RUN_ERR" >&2 || true
fi
pair_advice_line
case "$PAIR_ADVICE_LINE" in
  *"MULTI_AGENT_REVIEW_SUB="*)
    ok "副の失敗案内コマンドは副を空にして主を差し替える"
    ;;
  *)
    bad "副の失敗案内コマンドを取り出せない"
    printf '  line: %s\n' "$PAIR_ADVICE_LINE" >&2
    ;;
esac
cp "$EV_CODEX_GOOD" "$STUB/codex"
chmod +x "$STUB/codex"
EV_RERUN_RC=0
run_isolated PATH="$STUB_PATH" HOME="$TMP/home" XDG_CONFIG_HOME="$PAIR_XDG" \
  FF_DEV_TOOLKIT_ROOT="$PLUGIN_ROOT" \
  bash -c "$PAIR_ADVICE_LINE" > "$TMP/pair-sub-rerun.out" 2> "$TMP/pair-sub-rerun.err" || EV_RERUN_RC=$?
RUN_RC="$EV_RERUN_RC"
RUN_ERR="$TMP/pair-sub-rerun.err"
EV_VERIFY_RC=0
python3 -B "$PLUGIN_ROOT/scripts/review-evidence.py" verify \
  --file "$EV_PAIR_SUB_CONT/review-evidence.json" --output "$EV_PAIR_SUB_CONT" \
  --base develop --required comprehensive-review >/dev/null 2>"$TMP/pair-sub-verify.err" || EV_VERIFY_RC=$?
if [ "$RUN_RC" -eq 0 ] && [ "$EV_VERIFY_RC" -eq 0 ] \
   && python3 -B -c 'import json,sys; r=json.load(open(sys.argv[1])); assert r["results"].get("claude-code:comprehensive-review")=="complete"; assert "codex-cli:comprehensive-review" not in r["results"]; assert r.get("parent")' \
        "$EV_PAIR_SUB_CONT/review-evidence.json"; then
  ok "別の主での再実行は総合観点をその CLI で完走し継続の系譜を verify できる"
else
  bad "別の主での総合観点の再実行が継続の系譜を完了しない（rc=${RUN_RC} verify=${EV_VERIFY_RC}）"
  tail -n 30 "$RUN_ERR" >&2 || true
  tail -n 20 "$TMP/pair-sub-verify.err" >&2 || true
fi
cp "$EV_CLAUDE_GOOD" "$STUB/claude"
chmod +x "$STUB/claude"

echo "-- evidence が無い pair の失敗は主の差し替え案内にしない --"
run_ma_pair pair-plain-fail --task review --mode pair --perspective code-review --base develop \
  --sequential --timeout 30 --output-dir "$TMP/pair-plain-fail"
cat > "$STUB/claude" << 'SH'
#!/usr/bin/env bash
cat >/dev/null
exit 1
SH
chmod +x "$STUB/claude"
run_ma_pair pair-plain-fail --task review --mode pair --perspective code-review --base develop \
  --sequential --timeout 30 --output-dir "$TMP/pair-plain-fail"
if [ "$RUN_RC" -ne 0 ] && ! grep -qF -- 'MULTI_AGENT_REVIEW_MAIN=' "$RUN_ERR" \
   && ! grep -qF -- 'cannot be combined with --resume' "$RUN_ERR"; then
  ok "証跡が無い失敗案内は主の差し替えも --resume 拒否も出さない"
else
  bad "証跡が無い失敗案内が pair の差し替え案内になっている（rc=${RUN_RC}）"
  tail -n 30 "$RUN_ERR" >&2 || true
fi
cp "$EV_CLAUDE_GOOD" "$STUB/claude"
chmod +x "$STUB/claude"

# 系譜の案内は新しい起動なので、元の実行が起動時だけの環境変数から得た入力は届かない。
# 証跡の照合（base_ref の文字列）と計画（設定ファイル・pair の主と副）を決める入力を
# 環境変数だけで与え、印刷された案内を環境変数なしで打ち直して受け付けられることを表で固定する。
# timeout・モデルなど照合も計画の担当も変えない入力は拒否を起こさないので表に載せない。
# 同じ表で、観点集合を実際の計画から取ること（主と副が同じ pair）と、値を取るオプションの値を
# オプションと取り違えないこと（argv の正規化）も固定する。
echo "-- lineage advice pins inputs that came only from the environment --"
git -C "$REPO" branch -f release develop
LINEAGE_ENV_CONFIG="$TMP/lineage-env-config.yaml"
cp "$PLUGIN_ROOT/scripts/agent-config.yaml" "$LINEAGE_ENV_CONFIG"
EV_CODEX_FAIL="$TMP/codex-fail"
cat > "$EV_CODEX_FAIL" << 'SH'
#!/usr/bin/env bash
cat >/dev/null
printf 'codex\n' >> "${FF_TEST_CODEX_COUNT:?}"
exit 1
SH
chmod +x "$EV_CODEX_FAIL"
# pair で代替主と副が別になるには 3 つ目の CLI が要る。copilot の adapter は read-only の前に
# `copilot help permissions` で deny の優先を確かめるので、その問い合わせに応える stub を使う。
# （grok は組み込みの sandbox が TMPDIR へ書き込みを許すため、TMPDIR 配下の fixture を拒否する）
LINEAGE_COPILOT_GOOD="$TMP/lineage-copilot-good"
cat > "$LINEAGE_COPILOT_GOOD" << 'SH'
#!/usr/bin/env bash
if [ "${1:-}" = help ] && [ "${2:-}" = permissions ]; then
  echo "--deny-tool <tool>  --disallow-temp-dir"
  echo "Denial rules always take precedence over allow rules."
  exit 0
fi
cat >/dev/null
echo "- Critical: 0"
echo "- Important: 0"
echo "- verdict: none"
SH
chmod +x "$LINEAGE_COPILOT_GOOD"
# yq は run-all の前提（multi-agent-plan と同じ扱い）。無い環境は skip にせず赤にする。
LINEAGE_YQ_BIN="$TMP/lineage-yq-bin"
mkdir -p "$LINEAGE_YQ_BIN"
LINEAGE_YQ_READY=false
if LINEAGE_YQ="$(command -v yq)" && [ -x "$LINEAGE_YQ" ] && ln -s "$LINEAGE_YQ" "$LINEAGE_YQ_BIN/yq"; then
  LINEAGE_YQ_READY=true
fi
LINEAGE_ENV_N=0
# <label> <advice-needle> <pin-needle|!absent> <verify-base> <required> <rerun-needle|-> <env...> -- <args...>
# 親を codex 成功で作り、codex 失敗で継続し、案内に pin-needle があること、案内を環境変数なしで
# 打ち直すと完走し継続の証跡が verify できること（rerun-needle があれば打ち直しの出力に載ること）を見る。
lineage_env_case() {
  local label="$1" needle="$2" pin="$3" vbase="$4" required="$5" rerun_needle="$6"
  local -a envs=() args=()
  shift 6
  while [ "$#" -gt 0 ] && [ "$1" != "--" ]; do envs+=("$1"); shift; done
  [ "$#" -gt 0 ] && shift
  args=("$@")
  LINEAGE_ENV_N=$((LINEAGE_ENV_N + 1))
  local parent="$TMP/lineage-env-${LINEAGE_ENV_N}-parent" cont="$TMP/lineage-env-${LINEAGE_ENV_N}-cont"
  local err="$TMP/lineage-env-${LINEAGE_ENV_N}.err" rerun_out="$TMP/lineage-env-${LINEAGE_ENV_N}-rerun.out"
  local rerun_err="$TMP/lineage-env-${LINEAGE_ENV_N}-rerun.err" verify_err="$TMP/lineage-env-${LINEAGE_ENV_N}-verify.err"
  local rc=0 rerun_rc=0 verify_rc=0 line="" candidate
  cp "$EV_CLAUDE_GOOD" "$STUB/claude"
  cp "$EV_CODEX_GOOD" "$STUB/codex"
  cp "$LINEAGE_COPILOT_GOOD" "$STUB/copilot"
  chmod +x "$STUB/claude" "$STUB/codex" "$STUB/copilot"
  run_isolated PATH="$STUB_PATH" HOME="$TMP/home" XDG_CONFIG_HOME="$PAIR_XDG" \
    FF_DEV_TOOLKIT_ROOT="$PLUGIN_ROOT" ${envs[@]+"${envs[@]}"} bash "$MULTI_AGENT" "${args[@]}" \
    --evidence --sequential --timeout 30 --output-dir "$parent" > /dev/null 2> "$err" || rc=$?
  if [ "$rc" -ne 0 ] || [ ! -f "$parent/review-evidence.json" ]; then
    bad "${label}: 親 evidence を作れない（rc=${rc}）"
    tail -n 30 "$err" >&2 || true
    return 0
  fi
  cp "$EV_CODEX_FAIL" "$STUB/codex"
  rc=0
  run_isolated PATH="$STUB_PATH" HOME="$TMP/home" XDG_CONFIG_HOME="$PAIR_XDG" \
    FF_DEV_TOOLKIT_ROOT="$PLUGIN_ROOT" ${envs[@]+"${envs[@]}"} bash "$MULTI_AGENT" "${args[@]}" \
    --evidence --continue-review "$parent/review-evidence.json" \
    --sequential --timeout 30 --output-dir "$cont" > /dev/null 2> "$err" || rc=$?
  while IFS= read -r candidate; do
    case "$candidate" in *"$needle"*"bash "* | *"bash "*"$needle"*) line="$candidate"; break ;; esac
  done < "$err"
  line="${line#"${line%%[![:space:]]*}"}"
  # pin-needle が ! で始まるときは、案内に含まれてはならない語として読む。
  local pin_ok=false
  case "$pin" in
    '!'*) case "$line" in *"${pin#!}"*) ;; *) pin_ok=true ;; esac ;;
    *) case "$line" in *"$pin"*) pin_ok=true ;; esac ;;
  esac
  if [ -n "$line" ] && [ "$pin_ok" = true ]; then
    ok "${label}: 案内は元の実行の入力を保つ"
  else
    # 打ち直しの判定も続ける（入力の欠落が実際に拒否・別計画になることを同じ回で示す）
    bad "${label}: 案内が元の実行の入力を保っていない（rc=${rc}）"
    printf '  line: %s\n' "$line" >&2
  fi
  if [ -z "$line" ]; then
    bad "${label}: 失敗案内の行が見つからない（rc=${rc}）"
    tail -n 30 "$err" >&2 || true
    return 0
  fi
  run_isolated PATH="$STUB_PATH" HOME="$TMP/home" XDG_CONFIG_HOME="$PAIR_XDG" \
    FF_DEV_TOOLKIT_ROOT="$PLUGIN_ROOT" \
    bash -c "$line" > "$rerun_out" 2> "$rerun_err" || rerun_rc=$?
  python3 -B "$PLUGIN_ROOT/scripts/review-evidence.py" verify \
    --file "$cont/review-evidence.json" --output "$cont" \
    --base "$vbase" --required "$required" >/dev/null 2>"$verify_err" || verify_rc=$?
  local needle_seen=true
  if [ "$rerun_needle" != "-" ]; then
    needle_seen=false
    if grep -F -- "$rerun_needle" "$rerun_out" "$rerun_err" > /dev/null; then needle_seen=true; fi
  fi
  if [ "$rerun_rc" -eq 0 ] && [ "$verify_rc" -eq 0 ] && [ "$needle_seen" = true ]; then
    ok "${label}: 案内をそのまま（環境変数なしで）打ち直すと完走し継続の証跡を verify できる"
  else
    bad "${label}: 案内をそのまま（環境変数なしで）打ち直すと受け付けられない（rc=${rerun_rc} verify=${verify_rc}）"
    printf '  line: %s\n' "$line" >&2
    tail -n 30 "$rerun_err" >&2 || true
    tail -n 20 "$verify_err" >&2 || true
  fi
}
lineage_env_case "MULTI_AGENT_BASE_BRANCH" "--exclude-cli codex-cli" "--base release" \
  release code-review,test-analysis,acceptance-criteria - \
  MULTI_AGENT_BASE_BRANCH=release -- \
  --task review --mode distributed --cli claude-code --cli codex-cli
LINEAGE_SAVED_PATH="$STUB_PATH"
if [ "$LINEAGE_YQ_READY" = true ]; then
  STUB_PATH="$LINEAGE_YQ_BIN:$LINEAGE_SAVED_PATH"
  lineage_env_case "MULTI_AGENT_CONFIG" "--exclude-cli codex-cli" "--config ${LINEAGE_ENV_CONFIG}" \
    develop code-review,test-analysis,acceptance-criteria "$LINEAGE_ENV_CONFIG" \
    MULTI_AGENT_CONFIG="$LINEAGE_ENV_CONFIG" -- \
    --task review --mode distributed --base develop --cli claude-code --cli codex-cli
else
  bad "MULTI_AGENT_CONFIG: 明示した設定ファイルの読み取りに必要な yq が無い"
fi
STUB_PATH="$LINEAGE_SAVED_PATH"
# 主・副とも環境変数だけで与え、落ちた主を差し替える。副を固定しないと、打ち直しは
# ユーザー設定の副（codex-cli。失敗のまま）へ戻り、総合観点が完走しない。
lineage_env_case "MULTI_AGENT_REVIEW_MAIN / _SUB" "MULTI_AGENT_REVIEW_MAIN=claude-code" \
  "MULTI_AGENT_REVIEW_SUB=copilot-cli" \
  develop code-review,comprehensive-review - \
  MULTI_AGENT_REVIEW_MAIN=codex-cli MULTI_AGENT_REVIEW_SUB=copilot-cli -- \
  --task review --mode pair --base develop --perspective code-review --perspective comprehensive-review
# 主と副が同じ pair は副の重複を省き、総合観点を組まない。落ちた主を差し替える案内が
# 観点ファイルの全一覧を足すと、親の証跡に無い総合観点が混ざり継続が拒否される。
lineage_env_case "MULTI_AGENT_REVIEW_MAIN = _SUB" "MULTI_AGENT_REVIEW_MAIN=claude-code" \
  "!--perspective comprehensive-review" \
  develop code-review - \
  MULTI_AGENT_REVIEW_MAIN=codex-cli MULTI_AGENT_REVIEW_SUB=codex-cli -- \
  --task review --mode pair --base develop
# 値を取るオプションの値がオプション名に見えても、値として残す（次の語と一緒に外さない）。
lineage_env_case "--description の値がオプション名" "--exclude-cli codex-cli" \
  "--description --invocation-display --mode cross-model" \
  develop code-review - -- \
  --task review --description --invocation-display --mode cross-model --perspective code-review \
  --base develop --cli claude-code --cli codex-cli
cp "$EV_CLAUDE_GOOD" "$STUB/claude"
cp "$EV_CODEX_GOOD" "$STUB/codex"
cp "$EV_CODEX_GOOD" "$STUB/copilot"
chmod +x "$STUB/claude" "$STUB/codex" "$STUB/copilot"

if [ -e "$EV_PARK/review-results" ]; then
  rm -rf "$REPO/.review-results"
  mv "$EV_PARK/review-results" "$REPO/.review-results"
fi

# archive-only-cases:start
ARCHIVE_CASES_FILE="$SCRIPT_DIR/archive-only-cases.sh"
[[ -f "$ARCHIVE_CASES_FILE" && -r "$ARCHIVE_CASES_FILE" && -s "$ARCHIVE_CASES_FILE" ]] || { echo '✗ archive-only cases missing/unreadable/empty' >&2; exit 1; }
# shellcheck source=archive-only-cases.sh
. "$ARCHIVE_CASES_FILE"
[[ "$(type -t run_archive_only_cases)" == function ]] || { echo '✗ archive-only case function missing' >&2; exit 1; }
ARCHIVE_BEFORE=$((PASS + FAIL))
run_archive_only_cases
[[ $((PASS + FAIL - ARCHIVE_BEFORE)) -ge 34 ]] || { echo '✗ archive-only assertion collection empty/incomplete' >&2; exit 1; }
[[ "$(type -t run_archive_recovery_cases)" == function ]] || { echo '✗ archive recovery case function missing' >&2; exit 1; }
ARCHIVE_RECOVERY_BEFORE=$((PASS + FAIL))
run_archive_recovery_cases
[[ $((PASS + FAIL - ARCHIVE_RECOVERY_BEFORE)) -ge 22 ]] || { echo '✗ archive recovery assertion collection empty/incomplete' >&2; exit 1; }
# archive-only-cases:end

# completed-lane-cases:start
COMPLETED_LANE_CASES_FILE="$SCRIPT_DIR/completed-lane-cases.sh"
[[ ! -L "$COMPLETED_LANE_CASES_FILE" && -f "$COMPLETED_LANE_CASES_FILE" && -r "$COMPLETED_LANE_CASES_FILE" && -s "$COMPLETED_LANE_CASES_FILE" ]] || { echo '✗ completed lane cases missing/unreadable/empty' >&2; exit 1; }
# shellcheck source=completed-lane-cases.sh
. "$COMPLETED_LANE_CASES_FILE"
[[ "$(type -t run_completed_lane_cases)" == function ]] || { echo '✗ completed lane case function missing' >&2; exit 1; }
COMPLETED_LANE_BEFORE=$((PASS + FAIL))
run_completed_lane_cases
[[ $((PASS + FAIL - COMPLETED_LANE_BEFORE)) -ge 24 ]] || { echo '✗ completed lane assertion collection empty/incomplete' >&2; exit 1; }
# completed-lane-cases:end

echo ""
echo "  PASS=${PASS} FAIL=${FAIL}"
if [ "$FAIL" -gt 0 ]; then
  echo "✗ multi-agent-host-delegation verify: ${FAIL} 件失敗" >&2
  FF_REACHED_END=1
  exit 1
fi
echo "✓ multi-agent-host-delegation verify: すべて通過"
FF_REACHED_END=1
