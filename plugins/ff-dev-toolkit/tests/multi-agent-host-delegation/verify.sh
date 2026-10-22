#!/usr/bin/env bash
# 空振り検出: 明示退避のfocused対照（3hostの通常往復を除く）は最終51/0。同branch照合・全世代request・marker整合・partial lock・report-last・在庫再照合・series照合・復旧command・分類互換を個別に反転すると各4/7/1/18/7/5/2/1/2件赤（2026-10-22）。moduleとcasesの不在/不可読/空、casesの名前だけ/関数名変更は全てrc1で停止し、空集合を緑にしない。syntaxは保存SHA一致の変異sourceで個別rc0を確認。
# 空振り検出: R1復帰回帰は無変異18/0、元HEAD 69c3eb7dの不変runtimeでは5/9へ赤転（env config/base・Critical案内・detached・空fresh通知）。追加関数の不在と空のassertion集合はそれぞれrc1で停止（2026-10-22 実測）。
# 空振り検出: R2復帰回帰は22/0、修正前5a90c9a0では19/3へ赤転（非委譲full/fastのfresh案内）。full委譲のtemplate往復とfast拒否templateは保持し、非委譲2routeは案内されたfreshでrequest無しに完了する。追加関数不在・空集合は各rc1（2026-10-22 実測）。
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
chmod +x "$STUB/claude" "$STUB/codex" "$STUB/copilot"

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

echo "-- (26) codex-cli / grok-cli ホストの委譲（Issue \`#2118\`） --"
for LANE in codex-cli grok-cli; do
  LOD="$TMP/od-${LANE}"
  run_ma "host-${LANE}" --task review --cli "$LANE" --perspective code-review --base develop \
    --delegate-to-host="$LANE" --output-dir "$LOD"
  if [ "$RUN_RC" -eq 3 ] && grep -qF "cli=${LANE}" "$RUN_OUT" \
     && [ -s "$(handoff_field "$RUN_OUT" prompt-file code-review "$LANE")" ]; then
    ok "--delegate-to-host=${LANE} は ${LANE} レーンを handoff する（rc=3）"
  else
    bad "--delegate-to-host=${LANE} が handoff しない: rc=${RUN_RC} / $(tail -3 "$RUN_ERR" | tr '\n' ' ')"
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

echo ""
echo "  PASS=${PASS} FAIL=${FAIL}"
if [ "$FAIL" -gt 0 ]; then
  echo "✗ multi-agent-host-delegation verify: ${FAIL} 件失敗" >&2
  FF_REACHED_END=1
  exit 1
fi
echo "✓ multi-agent-host-delegation verify: すべて通過"
FF_REACHED_END=1
