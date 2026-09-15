#!/usr/bin/env bash
# Mutation self-test for retrospective prompt/Stop hooks (Issues #583 / #616).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
CONSUMER="$PLUGIN_ROOT/tests/retrospective-stop-hook/verify.sh"
EXPECTED_CONSUMER_CHECKS=111

command -v perl >/dev/null 2>&1 || { echo "○ skip: perl が無いため retrospective Stop hook self-test をスキップ"; exit 0; }
# rc=0 でも -d を検査する — 2>&1 の合流は「成功 + stderr 警告」の環境で変数へ
# 警告文が混入し、以後の処理が原因不明の失敗に化けるため。
if _ff_mktemp_out="$(mktemp -d "${TMPDIR:-/tmp}/retrospective-stop-hook-selftest.XXXXXX" 2>&1)" && [ -d "$_ff_mktemp_out" ]; then
  TMP="$_ff_mktemp_out"
else
  echo "○ skip: 一時ディレクトリを作成できないため retrospective Stop hook self-test をスキップ"
  printf '  mktemp: %s\n' "$_ff_mktemp_out"
  exit 0
fi
REACHED_END=0
cleanup() {
  local rc=$?
  rm -rf "$TMP"
  if [ "$REACHED_END" -ne 1 ] && [ "$rc" -eq 0 ]; then
    echo "✗ retrospective Stop hook self-test: 最後まで到達しませんでした" >&2
    rc=1
  fi
  exit "$rc"
}
trap cleanup EXIT

make_fixture() {
  local name="$1"
  local root="$TMP/$name/plugin"
  mkdir -p "$root/hooks" "$root/tests/retrospective-stop-hook" "$root/skills/retrospective"
  cp "$PLUGIN_ROOT/hooks/retrospective-stop.sh" "$root/hooks/retrospective-stop.sh"
  cp "$PLUGIN_ROOT/hooks/retrospective-context.sh" "$root/hooks/retrospective-context.sh"
  cp "$PLUGIN_ROOT/hooks/hooks.json" "$root/hooks/hooks.json"
  cp "$PLUGIN_ROOT/skills/retrospective/SKILL.md" "$root/skills/retrospective/SKILL.md"
  cp "$CONSUMER" "$root/tests/retrospective-stop-hook/verify.sh"
  cp "$PLUGIN_ROOT/tests/retrospective-stop-hook/asdd.test.mjs" "$root/tests/retrospective-stop-hook/asdd.test.mjs"
  cp "$PLUGIN_ROOT/hooks/asdd-hook-gate.sh" "$PLUGIN_ROOT/hooks/asdd-feature.mjs" "$root/hooks/"
  # Stop hook がターンの分類を委譲する先（Issue `#1612`）。hooks.json は .sh しか登録
  # しないので上の導出には載らない — 明示の copy がここに要る。
  cp "$PLUGIN_ROOT/hooks/retrospective-chain-tail.mjs" "$root/hooks/retrospective-chain-tail.mjs"
  mkdir -p "$root/tests/lib"
  cp "$PLUGIN_ROOT/tests/lib/asdd-gate-drain.sh" "$root/tests/lib/asdd-gate-drain.sh"
  # sandbox へ入れる hook 集合も hooks.json から導出する。消費側（asdd.test.mjs）は
  # 静音契約の名簿を hooks.json から導出するので、ここで列挙を持つと**同じ名簿を 2 か所**
  # で持つことになり、ガードを 1 本足したときに「sandbox に実体が無い」という偽の赤で
  # 止まる。導出できなければ（登録の書式が変わった）そこで落とす — 空の名簿で fixture を
  # 作ると、消費側が spawn に失敗して原因の分からない赤になる。
  #
  # 導出規則は消費側の HOOK_COMMAND_PATTERN と同じ 1 つ:
  # `$CLAUDE_PLUGIN_ROOT/hooks/<name>.sh`、**波括弧は任意**。ここだけが波括弧を必須に
  # していると、`"$CLAUDE_PLUGIN_ROOT/hooks/x.sh"` と書いた登録が消費側の名簿には入る
  # のに sandbox へ copy されず、spawn 失敗という原因の読めない赤になる。
  local registered hook
  registered="$(grep -oE '\$\{?CLAUDE_PLUGIN_ROOT\}?/hooks/[A-Za-z0-9._-]+\.sh' "$PLUGIN_ROOT/hooks/hooks.json" | sed 's#.*/##' | sort -u)"
  [ -n "$registered" ] || { echo "✗ hooks.json から hook 名簿を導出できません" >&2; return 1; }
  for hook in $registered; do
    cp "$PLUGIN_ROOT/hooks/$hook" "$root/hooks/$hook"
  done
  mkdir -p "$root/scripts/asdd"
  cp "$PLUGIN_ROOT/scripts/asdd/config.mjs" "$root/scripts/asdd/config.mjs"

  printf '%s' "$root"
}

run_consumer() {
  local root="$1" rc=0
  OUT="$(bash "$root/tests/retrospective-stop-hook/verify.sh" 2>&1)" || rc=$?
  RC=$rc
}

echo "== retrospective Stop hook mutation self-test =="

BASE="$(make_fixture baseline)"
run_consumer "$BASE"
if [ "$RC" -ne 0 ]; then
  echo "✗ baseline が green ではありません: $OUT" >&2
  exit 1
fi
echo "  ✓ baseline は green"
if printf '%s' "$OUT" | grep -F "retrospective Stop hook: ${EXPECTED_CONSUMER_CHECKS} 件すべて成功" >/dev/null; then
  echo "  ✓ consumer の検査総数は ${EXPECTED_CONSUMER_CHECKS} 件"
else
  echo "✗ consumer の検査総数が期待 ${EXPECTED_CONSUMER_CHECKS} 件と一致しません: $OUT" >&2
  exit 1
fi

# 変異検出の期待文字列（`✖ <テスト名>`）は node --test の reporter に依存する。既定の
# reporter は Node のバージョンと stdout が TTY かで変わり（実測 2026-09-12: v22.20.0 は
# 非 TTY で TAP、v24.18.0 は spec）、この self-test は consumer の出力を `$()` で捕捉する
# = 非 TTY。固定が外れると Node 24 のローカルだけ緑で Node 22 の CI が赤になるので、
# 変異ではなく静的検査で押さえる（変異にすると Node 24 では既定が spec なので空振りする）。
NODE_TEST_LINES="$(grep -cE '(^|[^[:alnum:]_-])node --test( |$)' "$CONSUMER" || true)"
NODE_TEST_PINNED="$(grep -cE '(^|[^[:alnum:]_-])node --test .*--test-reporter=' "$CONSUMER" || true)"
if [ "$NODE_TEST_LINES" -lt 1 ] || [ "$NODE_TEST_LINES" -ne "$NODE_TEST_PINNED" ]; then
  echo "✗ consumer の node --test に reporter 固定（--test-reporter=spec）がありません" >&2
  echo "  node --test の行数 ${NODE_TEST_LINES} / うち reporter 固定 ${NODE_TEST_PINNED}" >&2
  echo "  reporter を固定しないと、変異検出の期待文字列が Node のバージョンで一致しなくなります" >&2
  exit 1
fi
echo "  ✓ consumer は node --test の reporter を固定している"

# ---- 変異を書くときの規則（Issue #936）--------------------------------------
# **意味の錨を持たず、対象が複数箇所に現れうる変異には `/g` を付ける。** 単発置換だと、
# 後から同じ文字列が増えた時点で「1 箇所だけ変異 → 残りが契約を満たすので消費側は緑」
# という空振りになり、selftest が「変異が検出されない」という**逆の理由**で赤くなる。
# 実測（PR #926 が SKILL.md へ定型文の 2 箇所目を足した回）: SKILL 定型文 drift の
# 変異が空振りし、develop の全件ゲートが赤いまま残った。
#
# 棚卸し（2026-08-27 実測、2026-09-01 Issue #840 で更新。対象ファイル内の出現数）:
#   複数箇所 → `/g` 必須: `case "$MODE" in`（retrospective-stop.sh: 2 / context.sh: 2）/
#     `ff-dev-toolkit:retrospective`（context.sh: 2）/ `{"hookSpecificOutput"`（context.sh: 2）
#   意味の錨へ限定: SKILL.md の定型文は自動発火節の番号付き判定リストへ範囲を閉じる。
#     散文中の引用数は契約ではないため数えず、増減を良性変更として許容する（Issue #956）
#   1 箇所のみ: `  0:active)`（stop.sh） / `input.stop_hook_active || RETROSPECTIVE_DONE`（mjs） /
#     `retrospectiveDone || codexStop` /
#     `INPUT_TIMEOUT_SECONDS=2` / `Automatic retrospective check before stop` /
#     `Codex の Stop 入力（\`model\` フィールドあり）は常に無音` /
#     `if ! command -v node ...` / `"Stop": [` / `"UserPromptSubmit": [` /
#     `codexHost && nonInteractive`（context.sh: 1）/
#     `(Number(process.argv[1]) || 2) * 1000`（context.sh: 1。discard 段の bound は
#       `Number(process.argv[1]) * 1000 || 2000` と別形にしてあり、この数え方に入らない）/
#     `|| HOST_STATE="inject"`（context.sh: 1）/ `[ "$HOST_STATE" = "skip" ]`（context.sh: 1）/
#     `IFS= read -r -t "$INPUT_TIMEOUT_SECONDS" -d '' _`（context.sh: 1）/
#     `[ "$READ_RC" -ne 0 ]`（stop.sh: 1 / context.sh: 1）/ `READ_RC=$?`（stop.sh: 1）/
#     `setTimeout(latch,`（context.sh: 1）/ `[ "$RETROSPECTIVE_OFF" -eq 0 ]`（context.sh: 1）/
#     `...registeredHooks()`（asdd.test.mjs: 1）
#   `finish("inject")` は context.sh に 3 箇所あるが、変異は前後の行ごと指定して一意に当てている
#   `process.exit(2)` は 3 箇所あるが、変異は前後の行ごと指定して一意に当てている
#   shebang 直後への 1 行挿入（ASDD ゲートを drain より前へ戻す変異）は `\A` 固定なので一意
#
# 変異対象の文字列を増やす変更を入れたら、この棚卸しを実測し直すこと。

# 棚卸しを**機械検査**にする（Issue #936 のレビュー指摘）。ヘッダーのコメントだけでは
# 出現数が増えたことに誰も気づけない — #936 はまさにその形で develop を赤くした。
# 変異の直前に出現数を固定し、増減したら「変異が届いていないかもしれない」と名指しで落とす。
expect_occurrences() { # <ファイル> <固定文字列> <期待数>
  local n
  n="$(LC_ALL=C grep -cF -- "$2" "$1" 2>/dev/null || echo 0)"
  if [ "$n" -ne "$3" ]; then
    echo "✗ 変異対象の出現数が想定と違います（${1##*/}: 「$2」が ${n} 件 / 期待 $3 件）" >&2
    echo "  出現が増えたなら /g の要否とヘッダーの棚卸しを見直すこと。単発置換のままだと" >&2
    echo "  変異が空振りし、selftest が「検出されない」という逆の理由で赤くなる（Issue #936）" >&2
    exit 1
  fi
}

# 変異の検査は**登録してから並列に回す**。
#
# consumer 1 回が実測 21 秒（うち 3 秒は入力上限の契約を測る sleep で、これは契約そのもの
# なので削れない）で、変異は 43 件あるため直列だと 15 分、並列エージェント下の高負荷では
# 1 時間級になる。**時間が理由で誰も回さない検査は、検出力ゼロの検査と同じ**なので、
# 実行時間そのものを設計対象にする。
#
# 並列化できるのは fixture が変異ごとに隔離されているから（make_fixture が $TMP/<name>/plugin
# を作り、consumer はその root だけを読む）。共有状態は無い。ここで変えるのは**実行の仕方**
# だけで、変異の一覧・期待診断・判定条件はすべて元のまま — 43 個の登録ブロックには触らない。
#
# 出力は登録順に並べ直す（完了順にすると、同じ一覧でも実行のたびに並びが変わって前回との
# 差分が読めない。run-all.sh の並列実行と同じ理由）。
MUTATIONS=0
BENIGN=0
JOB_N=0
JOB_NAMES=()
JOB_KINDS=()
JOB_EXPECTED=()
JOB_ROOTS=()

register_job() { # <kind: mutation|benign> <name> <expected> <root>
  JOB_KINDS+=("$1")
  JOB_NAMES+=("$2")
  JOB_EXPECTED+=("$3")
  JOB_ROOTS+=("$4")
  JOB_N=$((JOB_N + 1))
}

check_mutation() {
  register_job mutation "$1" "$2" "$3"
}

# 良性の変更で赤くならないことも測る（Issue #931）。定型文の照合を「どこかに 1 つ」から
# 「自動発火の節の中」へ絞ったので、逆に厳しすぎないかを固定しておく必要がある。
# 散文への加筆で毎回この suite が止まるなら、SKILL.md を書き足せなくなる。
check_no_regression() { # <名前> <root>
  register_job benign "$1" "" "$2"
}

ROOT="$(make_fixture active-guard)"
# `#1612` で再入ガードは判定モジュール側へ移った（shell の `!= "first"` は case へ）。
expect_occurrences "$ROOT/hooks/retrospective-chain-tail.mjs" 'input.stop_hook_active || RETROSPECTIVE_DONE' 1
perl -0pi -e 's/input\.stop_hook_active \|\| RETROSPECTIVE_DONE/RETROSPECTIVE_DONE/' "$ROOT/hooks/retrospective-chain-tail.mjs"
check_mutation "再入ガード削除" "stop_hook_active=true は再継続せず終了を許可" "$ROOT"

ROOT="$(make_fixture off-guard)"
expect_occurrences "$ROOT/hooks/retrospective-stop.sh" 'case "$MODE" in' 2
perl -0pi -e 's/case "\$MODE" in/case "auto" in/g' "$ROOT/hooks/retrospective-stop.sh"
check_mutation "off ガード削除" "RETROSPECTIVE_MODE=off は自動振り返りを無効化" "$ROOT"

ROOT="$(make_fixture invalid-json)"
# 変異は「壊す」ではなく「別の正しい答えを返す」形にすること。単に
# process.stdout.write へ差し替えると input が未定義のまま先へ進んで例外終了し、
# hook 側の `|| exit 0` が拾って**無音 = 期待どおり**に見えてしまう（実測で空振り）。
expect_occurrences "$ROOT/hooks/retrospective-chain-tail.mjs" '    process.exit(2);' 1
perl -0pi -e 's/  } catch \(_\) \{\n    process\.exit\(2\);\n  }/  } catch (_) {\n    finish("first");\n  }/' "$ROOT/hooks/retrospective-chain-tail.mjs"
check_mutation "不正 JSON fail-open 削除" "不正 JSON は fail-open" "$ROOT"

ROOT="$(make_fixture registration)"
perl -0pi -e 's/"Stop": \[/"StopDisabled": [/' "$ROOT/hooks/hooks.json"
check_mutation "Stop 登録削除" "hooks.json の Stop 登録が不正" "$ROOT"

ROOT="$(make_fixture context-registration)"
perl -0pi -e 's/"UserPromptSubmit": \[/"UserPromptSubmitDisabled": [/' "$ROOT/hooks/hooks.json"
check_mutation "UserPromptSubmit 登録削除" "hooks.json の UserPromptSubmit 登録が不正" "$ROOT"

ROOT="$(make_fixture context-visible-warning)"
expect_occurrences "$ROOT/hooks/retrospective-context.sh" '{"hookSpecificOutput"' 2
perl -0pi -e 's/\{"hookSpecificOutput"/\{"systemMessage":"visible","hookSpecificOutput"/g' "$ROOT/hooks/retrospective-context.sh"
check_mutation "事前注入への表示用 Warning 混入" "UserPromptSubmit の事前注入契約が不正" "$ROOT"

ROOT="$(make_fixture context-off-guard)"
expect_occurrences "$ROOT/hooks/retrospective-context.sh" 'case "$MODE" in' 2
perl -0pi -e 's/case "\$MODE" in/case "auto" in/g' "$ROOT/hooks/retrospective-context.sh"
check_mutation "事前注入の off ガード削除" "context hook も RETROSPECTIVE_MODE=off なら無効" "$ROOT"

# 事前注入が載せるスキル本文の絶対パス。散文の針だけでは、実行される側（パスを組む分岐と
# JSON エスケープ）を外す変異が緑で通る。倒れ方が「パスを足したつもりで注入契約ごと失う」
# 向きなので、6 分岐すべてを常設の変異で固定する。
ROOT="$(make_fixture context-skill-path-default-removed)"
expect_occurrences "$ROOT/hooks/retrospective-context.sh" '%s%s"}}' 2
perl -0pi -e 's/read-only\. %s%s"\}\}\\n. "\$FILING_CLAUSE" "\$SKILL_PATH_CLAUSE"\n\nexit 0/read-only. %s"}}\\n\x27 "\$FILING_CLAUSE"\n\nexit 0/' "$ROOT/hooks/retrospective-context.sh"
check_mutation "既定分岐からスキル経路を削除" "事前注入（__unset__）のスキル経路が不正" "$ROOT"

ROOT="$(make_fixture context-skill-path-ask-removed)"
expect_occurrences "$ROOT/hooks/retrospective-context.sh" '%s%s"}}' 2
perl -0pi -e 's/read-only\. %s%s"\}\}\\n. "\$FILING_CLAUSE" "\$SKILL_PATH_CLAUSE"\n    exit 0/read-only. %s"}}\\n\x27 "\$FILING_CLAUSE"\n    exit 0/' "$ROOT/hooks/retrospective-context.sh"
check_mutation "ask 分岐からスキル経路を削除" "事前注入（ask）のスキル経路が不正" "$ROOT"

ROOT="$(make_fixture context-skill-path-backslash-unescaped)"
expect_occurrences "$ROOT/hooks/retrospective-context.sh" '_ff_escaped="${_ff_skill_file//\\/\\\\}"' 1
perl -0pi -e 's/_ff_escaped="\$\{_ff_skill_file\/\/\\\\\/\\\\\\\\\}"/_ff_escaped="\${_ff_skill_file}"/' "$ROOT/hooks/retrospective-context.sh"
check_mutation "スキル経路のバックスラッシュ非エスケープ" "敵対的な root でスキル経路が壊れた" "$ROOT"

ROOT="$(make_fixture context-skill-path-quote-unescaped)"
expect_occurrences "$ROOT/hooks/retrospective-context.sh" '_ff_escaped="${_ff_escaped//\"/\\\"}"' 1
perl -0pi -e 's/_ff_escaped="\$\{_ff_escaped\/\/\\"\/\\\\\\"\}"/_ff_escaped="\${_ff_escaped}"/' "$ROOT/hooks/retrospective-context.sh"
check_mutation "スキル経路の引用符非エスケープ" "敵対的な root でスキル経路が壊れた" "$ROOT"

ROOT="$(make_fixture context-skill-path-cntrl-guard-removed)"
expect_occurrences "$ROOT/hooks/retrospective-context.sh" '*[[:cntrl:]]*) : ;;' 1
perl -0pi -e 's/\*\[\[:cntrl:\]\]\*\) : ;;/*__never_matches__*) : ;;/' "$ROOT/hooks/retrospective-context.sh"
check_mutation "スキル経路の制御文字ガード削除" "制御文字を含む root で注入が壊れた" "$ROOT"

ROOT="$(make_fixture context-skill-path-existence-removed)"
expect_occurrences "$ROOT/hooks/retrospective-context.sh" 'if [ -f "$_ff_skill_file" ]; then' 1
perl -0pi -e 's/if \[ -f "\$_ff_skill_file" \]; then/if true; then/' "$ROOT/hooks/retrospective-context.sh"
check_mutation "スキル経路の実在検査削除" "スキル経路の fallback が不正" "$ROOT"

# Issue #840: 非対話 codex exec の判定そのもの。判定を外す（常に注入する）と消費側の
# スキップ検査が赤くなること = 変異赤化の常設実測。
ROOT="$(make_fixture noninteractive-skip-removed)"
expect_occurrences "$ROOT/hooks/retrospective-context.sh" 'codexHost && nonInteractive' 1
perl -0pi -e 's/codexHost && nonInteractive/false/' "$ROOT/hooks/retrospective-context.sh"
check_mutation "非対話スキップ判定の削除" "Codex 非対話（model + bypassPermissions）は事前注入をスキップ" "$ROOT"

# 判定の過拡大（permission_mode を見ずに model だけでスキップ）は、Codex 対話セッション
# の注入を失う向きの退行。既存の Codex 事前注入検査（permission_mode なし入力）が捕まえる。
ROOT="$(make_fixture noninteractive-overreach)"
expect_occurrences "$ROOT/hooks/retrospective-context.sh" 'codexHost && nonInteractive' 1
perl -0pi -e 's/codexHost && nonInteractive/codexHost/' "$ROOT/hooks/retrospective-context.sh"
check_mutation "非対話判定の過拡大（model だけでスキップ）" "Codex UserPromptSubmit の事前注入契約が不正" "$ROOT"

# Issue #840 レビュー指摘: 判別 node の入力上限を実質無効化（1 時間へ延長）すると、
# stdin を閉じないホストの fixture が EOF まで待って skip し、fail-open が消える。
ROOT="$(make_fixture context-input-bound-removed)"
expect_occurrences "$ROOT/hooks/retrospective-context.sh" '(Number(process.argv[1]) || 2) * 1000' 1
perl -0pi -e 's/\(Number\(process\.argv\[1\]\) \|\| 2\) \* 1000/3600000/' "$ROOT/hooks/retrospective-context.sh"
check_mutation "判別 node の入力上限を無効化" "stdin を閉じないホストでは入力上限で注入へ倒す（fail-open）" "$ROOT"

# 異常終了 fallback（|| HOST_STATE="inject"）の削除: 非 0 終了の stub が途中まで出した
# "skip" がそのまま採用され、fail-open が skip 方向へ反転する。
ROOT="$(make_fixture context-exit-fallback-removed)"
expect_occurrences "$ROOT/hooks/retrospective-context.sh" '|| HOST_STATE="inject"' 1
perl -0pi -e 's/ \|\| HOST_STATE="inject"//' "$ROOT/hooks/retrospective-context.sh"
check_mutation "判別 node 異常終了 fallback の削除" "判別 node が異常終了（skip 出力 + 非 0）でも注入へ倒す（fail-open）" "$ROOT"

# skip の完全一致ガードを否定形（inject 以外は skip）へ緩めると、予期しない出力で
# 注入が消える。
ROOT="$(make_fixture context-hoststate-guard-loosened)"
expect_occurrences "$ROOT/hooks/retrospective-context.sh" '[ "$HOST_STATE" = "skip" ]' 1
perl -0pi -e 's/\[ "\$HOST_STATE" = "skip" \]/[ "\$HOST_STATE" != "inject" ]/' "$ROOT/hooks/retrospective-context.sh"
check_mutation "HOST_STATE ガードの緩和" "判別 node の予期しない出力は skip と扱わない（fail-open）" "$ROOT"

# JSON parse 失敗を skip へ倒す退行（catch 側だけを狙う。finish("inject") は 3 箇所
# あるため前行ごと指定して一意に当てる）。
ROOT="$(make_fixture context-parse-failure-to-skip)"
perl -0pi -e 's/\} catch \(_\) \{\n    finish\("inject"\);/} catch (_) {\n    finish("skip");/' "$ROOT/hooks/retrospective-context.sh"
check_mutation "parse 失敗の fail-open 反転" "途中で切れた不正 JSON は注入へ倒す（fail-open）" "$ROOT"

ROOT="$(make_fixture context-skill-routing)"
expect_occurrences "$ROOT/hooks/retrospective-context.sh" 'ff-dev-toolkit:retrospective' 2
perl -0pi -e 's/ff-dev-toolkit:retrospective/ff-dev-toolkit:missing/g' "$ROOT/hooks/retrospective-context.sh"
check_mutation "事前注入のスキル経路破壊" "UserPromptSubmit の事前注入契約が不正" "$ROOT"

ROOT="$(make_fixture initial-decision)"
perl -0pi -e 's/decision/decisionBroken/g' "$ROOT/hooks/retrospective-stop.sh"
check_mutation "初回 decision 破壊" "初回 Stop の出力契約が不正" "$ROOT"

ROOT="$(make_fixture event-guard)"
perl -0pi -e 's/  if \(input\.hook_event_name !== "Stop"\) process\.exit\(2\);\n//' "$ROOT/hooks/retrospective-chain-tail.mjs"
check_mutation "イベント判別削除" "別イベントは fail-open" "$ROOT"

ROOT="$(make_fixture boolean-guard)"
perl -0pi -e 's/  if \(typeof input\.stop_hook_active !== "boolean"\) process\.exit\(2\);\n//' "$ROOT/hooks/retrospective-chain-tail.mjs"
check_mutation "再入フラグ型判別削除" "再入フラグ欠損は fail-open" "$ROOT"

ROOT="$(make_fixture node-guard)"
perl -0pi -e 's/if ! command -v node >\/dev\/null 2>&1; then/if false; then/' "$ROOT/hooks/retrospective-stop.sh"
check_mutation "Node.js 前提ガード削除" "Node.js 不在の fail-open 通知が不正" "$ROOT"

ROOT="$(make_fixture secondary-guard)"
perl -0pi -e 's/input\.stop_hook_active \|\| RETROSPECTIVE_DONE\.test\(message\)/input.stop_hook_active/' "$ROOT/hooks/retrospective-chain-tail.mjs"
check_mutation "secondary guard 削除" "secondary guard が終了を許可" "$ROOT"

ROOT="$(make_fixture codex-host-guard)"
expect_occurrences "$ROOT/hooks/retrospective-chain-tail.mjs" 'RETROSPECTIVE_DONE.test(message) || codexStop' 1
perl -0pi -e 's/RETROSPECTIVE_DONE\.test\(message\) \|\| codexStop/RETROSPECTIVE_DONE.test(message)/' "$ROOT/hooks/retrospective-chain-tail.mjs"
check_mutation "Codex Stop の表示抑止ガード削除" "Codex Stop は Feedback を返さず事前注入に委ねる" "$ROOT"

ROOT="$(make_fixture ask-reentry)"
expect_occurrences "$ROOT/hooks/retrospective-stop.sh" '  0:active)' 1
perl -0pi -e 's/  0:active\)\n    exit 0\n    ;;/  0:active)\n    case "\$MODE" in [Aa][Ss][Kk]) ;; *) exit 0 ;; esac\n    ;;/' "$ROOT/hooks/retrospective-stop.sh"
check_mutation "ask 再入ガード削除" "ask モードの継続中も再入せず終了を許可" "$ROOT"

ROOT="$(make_fixture filesystem-side-effect)"
perl -0pi -e 's{\A(#![^\n]*\n)}{$1: > "\$HOME/.ff-stop-state"\n}' "$ROOT/hooks/retrospective-stop.sh"
check_mutation "filesystem marker 追加" "hook が filesystem へ副作用を作成" "$ROOT"

# --- Issue `#1612`: チェーン末尾判定 ---------------------------------------------
# 判定の退行は 2 方向あり、**向きごとに別の変異で測る**。片方だけだと、もう一方は
# 「全部ブロックする」「全部黙る」のどちらかに倒れたまま緑で通る。

ROOT="$(make_fixture chain-tail-quiet-exit)"
expect_occurrences "$ROOT/hooks/retrospective-stop.sh" '  0:no-tail)' 1
perl -0pi -e 's/  0:no-tail\)/  0:__never_no_tail__)/' "$ROOT/hooks/retrospective-stop.sh"
check_mutation "no-tail の無音終了削除（改修前の挙動へ戻る）" "質問・設計相談のターンは継続を返さない（AC1）" "$ROOT"

ROOT="$(make_fixture chain-tail-fail-open)"
expect_occurrences "$ROOT/hooks/retrospective-chain-tail.mjs" 'if (verdict === "no-tail") return "no-tail";' 1
perl -0pi -e 's/if \(verdict === "no-tail"\) return "no-tail";/return "no-tail";/' "$ROOT/hooks/retrospective-chain-tail.mjs"
check_mutation "判定不能を注入なしへ倒す（fail-closed 反転）" "ターン境界が読み取れない transcript は継続側へ倒す（fail-closed）" "$ROOT"

ROOT="$(make_fixture chain-tail-loose-merge)"
expect_occurrences "$ROOT/hooks/retrospective-chain-tail.mjs" 'const GH_PR_MERGE = ' 1
perl -0pi -e 's/const GH_PR_MERGE = [^\n]*;/const GH_PR_MERGE = \/gh[ \\t]+pr[ \\t]+merge\/;/' "$ROOT/hooks/retrospective-chain-tail.mjs"
check_mutation "gh pr merge をコマンド位置で見なくする（引用の誤検出）" "gh pr merge を引用しただけのコマンドはチェーン末尾にしない" "$ROOT"

ROOT="$(make_fixture chain-tail-sidechain)"
expect_occurrences "$ROOT/hooks/retrospective-chain-tail.mjs" 'entry.isSidechain === true' 1
perl -0pi -e 's/entry\.isSidechain === true \|\| //' "$ROOT/hooks/retrospective-chain-tail.mjs"
check_mutation "sidechain をターン境界に含める（末尾の痕跡を見落とす）" "sidechain の user 行はターン境界にしない" "$ROOT"

ROOT="$(make_fixture chain-tail-skill-name)"
expect_occurrences "$ROOT/hooks/retrospective-chain-tail.mjs" 'TAIL_SKILLS.has(skillSegment(input.skill))' 1
perl -0pi -e 's/TAIL_SKILLS\.has\(skillSegment\(input\.skill\)\)/false/' "$ROOT/hooks/retrospective-chain-tail.mjs"
check_mutation "Skill 実行の検出削除" "/ace-curate を実行したターンは従来どおり継続を返す（AC3）" "$ROOT"

ROOT="$(make_fixture chain-tail-explicit)"
expect_occurrences "$ROOT/hooks/retrospective-chain-tail.mjs" 'return invokesTailCommand(prompt) ? "tail" : "no-tail";' 1
perl -0pi -e 's/return invokesTailCommand\(prompt\) \? "tail" : "no-tail";/return "no-tail";/' "$ROOT/hooks/retrospective-chain-tail.mjs"
check_mutation "利用者の明示指定の検出削除" "利用者が /retrospective を明示したターンは継続を返す（AC4）" "$ROOT"

ROOT="$(make_fixture chain-tail-module-missing)"
perl -0pi -e 's/if \[ ! -f "\$CHAIN_TAIL_DETECTOR" \]; then/if false; then/' "$ROOT/hooks/retrospective-stop.sh"
check_mutation "判定モジュール不在の診断削除（無言で自動振り返りが消える）" "判定モジュール不在は応答をブロックせず復旧ヒントを通知" "$ROOT"

ROOT="$(make_fixture context-notification-guard)"
expect_occurrences "$ROOT/hooks/retrospective-context.sh" 'finish(notification ? "skip-notification" : "inject");' 1
perl -0pi -e 's/finish\(notification \? "skip-notification" : "inject"\);/finish("inject");/' "$ROOT/hooks/retrospective-context.sh"
check_mutation "通知ターンの事前注入抑止削除（OBS-187 初回へ戻る）" "task notification のターンには事前注入しない（AC2）" "$ROOT"

ROOT="$(make_fixture chain-tail-delivered)"
expect_occurrences "$ROOT/hooks/retrospective-chain-tail.mjs" 'if (deliveredRetrospective(block)) return "done";' 1
perl -0pi -e 's/if \(deliveredRetrospective\(block\)\) return "done";\n//' "$ROOT/hooks/retrospective-chain-tail.mjs"
check_mutation "span 内の実施済み判定を削除（通知のたびに再要求へ戻る）" "span 内で振り返りを出し終えていれば、同じ span の後続応答で再要求しない" "$ROOT"

ROOT="$(make_fixture chain-tail-delivered-too-wide)"
expect_occurrences "$ROOT/hooks/retrospective-chain-tail.mjs" 'if (verdict === "done") return "active";' 1
perl -0pi -e 's/if \(verdict === "done"\) return "active";/if (verdict === "done" || verdict === "tail") return "active";/' "$ROOT/hooks/retrospective-chain-tail.mjs"
check_mutation "実施済み判定をチェーン末尾全体へ広げる（未実施でも黙る）" "span 内に振り返りが無ければチェーン末尾として継続を要求する" "$ROOT"

ROOT="$(make_fixture chain-tail-merge-anchor)"
expect_occurrences "$ROOT/hooks/retrospective-chain-tail.mjs" '(?:^|[\n;&|(])' 1
perl -0pi -e 's/\(\?:\^\|\[\\n;&\|\(\]\)/(?:[\\n;&|(])/' "$ROOT/hooks/retrospective-chain-tail.mjs"
check_mutation "gh pr merge の行頭一致を落とす（ワークフローが実際に打つ形を見落とす）" "行頭の gh pr merge を拾う（ワークフローが実際に打つ形）" "$ROOT"

ROOT="$(make_fixture chain-tail-merge-prefix)"
expect_occurrences "$ROOT/hooks/retrospective-chain-tail.mjs" '(?:[A-Za-z_][A-Za-z0-9_]*=[^\s]*[ \t]+)*(?:[^\s]*\/)?' 1
perl -0pi -e 's/\(\?:\[A-Za-z_\]\[A-Za-z0-9_\]\*=\[\^\\s\]\*\[ \\t\]\+\)\*\(\?:\[\^\\s\]\*\\\/\)\?//' "$ROOT/hooks/retrospective-chain-tail.mjs"
check_mutation "環境代入・明示パスの前置を落とす" "環境代入と明示パスが前置された gh pr merge も拾う" "$ROOT"

ROOT="$(make_fixture chain-tail-slashcommand)"
expect_occurrences "$ROOT/hooks/retrospective-chain-tail.mjs" 'block.name === "SlashCommand"' 1
perl -0pi -e 's/block\.name === "SlashCommand"/false/' "$ROOT/hooks/retrospective-chain-tail.mjs"
check_mutation "SlashCommand 経路の検出削除" "SlashCommand 経由の /ace-curate も拾う" "$ROOT"

# 誤検出側。prompt 全文を検索する実装へ戻すと、リポジトリのファイル名を口にした
# ターンが全部チェーン末尾になる（実測でこの形の退行が入った）。
ROOT="$(make_fixture chain-tail-command-substring)"
expect_occurrences "$ROOT/hooks/retrospective-chain-tail.mjs" 'const TAIL_COMMAND = ' 1
perl -0pi -e 's/const TAIL_COMMAND = [^\n]*;/const TAIL_COMMAND = \/\\\/(?:[A-Za-z0-9_-]+:)?(?:ace-curate|merge-cleanup|retrospective)\\b\/;/' "$ROOT/hooks/retrospective-chain-tail.mjs"
perl -0pi -e 's/  return TAIL_COMMAND\.test\(text\.trim\(\)\.split\(\/\\s\+\/\)\[0\] \|\| ""\);/  return TAIL_COMMAND.test(text);/' "$ROOT/hooks/retrospective-chain-tail.mjs"
check_mutation "コマンド形の判定を部分一致へ戻す（パス言及が末尾扱いになる）" "パスとしてコマンド名を含む prompt はチェーン末尾にしない" "$ROOT"

ROOT="$(make_fixture chain-tail-tool-result-guard)"
expect_occurrences "$ROOT/hooks/retrospective-chain-tail.mjs" 'if (content.some((block) => block && block.type === "tool_result")) return null;' 1
perl -0pi -e 's/  if \(content\.some\(\(block\) => block && block\.type === "tool_result"\)\) return null;\n//' "$ROOT/hooks/retrospective-chain-tail.mjs"
check_mutation "tool_result 判定の削除（text 付き tool_result が偽の境界になる）" "text を伴う tool_result エントリを境界にしない" "$ROOT"

ROOT="$(make_fixture chain-tail-ismeta)"
expect_occurrences "$ROOT/hooks/retrospective-chain-tail.mjs" 'entry.isMeta === true' 1
perl -0pi -e 's/ \|\| entry\.isMeta === true//' "$ROOT/hooks/retrospective-chain-tail.mjs"
check_mutation "isMeta 除外の削除（ホスト記帳が偽の境界になる）" "ホスト記帳の isMeta エントリを境界にしない" "$ROOT"

ROOT="$(make_fixture chain-tail-skill-exact)"
expect_occurrences "$ROOT/hooks/retrospective-chain-tail.mjs" 'TAIL_SKILLS.has(skillSegment(input.skill))' 1
perl -0pi -e 's/TAIL_SKILLS\.has\(skillSegment\(input\.skill\)\)/[...TAIL_SKILLS].some((n) => skillSegment(input.skill).startsWith(n))/' "$ROOT/hooks/retrospective-chain-tail.mjs"
check_mutation "skill 名の完全一致を前方一致へ緩める" "名前が前方一致するだけの skill はチェーン末尾にしない" "$ROOT"

ROOT="$(make_fixture chain-tail-delivered-loose)"
expect_occurrences "$ROOT/hooks/retrospective-chain-tail.mjs" 'RETROSPECTIVE_DELIVERED.test(block.text)' 1
perl -0pi -e 's/RETROSPECTIVE_DELIVERED\.test\(block\.text\)/RETROSPECTIVE_DONE.test(block.text)/' "$ROOT/hooks/retrospective-chain-tail.mjs"
check_mutation "span 内の実施済み判定を 1 行報告まで広げる（散文の引用で黙る）" "散文が定型文を引用しただけでは実施済みと見なさない" "$ROOT"

ROOT="$(make_fixture chain-tail-parse-failure)"
expect_occurrences "$ROOT/hooks/retrospective-chain-tail.mjs" 'if (i === 0 && partialHead) continue;' 1
perl -0pi -e 's/      if \(i === 0 && partialHead\) continue;\n      return "unknown";/      continue;/' "$ROOT/hooks/retrospective-chain-tail.mjs"
check_mutation "読めない行を全位置で読み飛ばす（判定不能を no-tail へ倒す）" "読めない行があれば、その手前を根拠に no-tail と断定しない" "$ROOT"

ROOT="$(make_fixture chain-tail-empty-model)"
expect_occurrences "$ROOT/hooks/retrospective-chain-tail.mjs" 'typeof input.model === "string" && input.model !== ""' 1
perl -0pi -e 's/typeof input\.model === "string" && input\.model !== ""/typeof input.model === "string"/' "$ROOT/hooks/retrospective-chain-tail.mjs"
check_mutation "空文字の model を Codex ホストと見なす" "空文字の model は Codex ホストと見なさない" "$ROOT"

ROOT="$(make_fixture stop-detector-rc-guard)"
expect_occurrences "$ROOT/hooks/retrospective-stop.sh" 'if [ "$DETECTOR_RC" -eq 2 ]; then' 1
perl -0pi -e 's/if \[ "\$DETECTOR_RC" -eq 2 \]; then/if [ "\$DETECTOR_RC" -ne 0 ]; then/' "$ROOT/hooks/retrospective-stop.sh"
check_mutation "実行できないモジュールを fail-open 扱いへ戻す（無音で自動振り返りが止まる）" "読めない判定モジュールは無音にせず復旧ヒントを返す" "$ROOT"

ROOT="$(make_fixture stop-detector-state-guard)"
expect_occurrences "$ROOT/hooks/retrospective-stop.sh" '  0:first)' 1
perl -0pi -e 's/  0:first\)\n    ;;\n  \*\)/  *)\n    ;;\n  __never_matches__)/' "$ROOT/hooks/retrospective-stop.sh"
check_mutation "state 語の whitelist を catch-all へ戻す（未知の state が無音になる）" "未知の state 語も無音にせず復旧ヒントを返す" "$ROOT"

ROOT="$(make_fixture stop-failopen-noise)"
expect_occurrences "$ROOT/hooks/retrospective-stop.sh" 'if [ "$DETECTOR_RC" -eq 2 ]; then' 1
perl -0pi -e 's/if \[ "\$DETECTOR_RC" -eq 2 \]; then\n  exit 0\nfi/if false; then\n  exit 0\nfi/' "$ROOT/hooks/retrospective-stop.sh"
check_mutation "設計どおりの fail-open にも復旧ヒントを出す（別イベントのたびに通知が飛ぶ）" "exit 2 は設計どおりの fail-open として無音で通す" "$ROOT"

ROOT="$(make_fixture context-notification-trim)"
expect_occurrences "$ROOT/hooks/retrospective-context.sh" '.replace(/^\s+/, "")' 1
perl -0pi -e 's/\.replace\(\/\^\\s\+\/, ""\)//' "$ROOT/hooks/retrospective-context.sh"
check_mutation "通知判定の先頭空白除去を落とす" "先頭に空白・改行がある通知でも抑止する" "$ROOT"

ROOT="$(make_fixture chain-tail-single-stage)"
expect_occurrences "$ROOT/hooks/retrospective-chain-tail.mjs" 'const CAP_STAGES = ' 1
perl -0pi -e 's/const CAP_STAGES = [^\n]*;/const CAP_STAGES = [512 * 1024];/' "$ROOT/hooks/retrospective-chain-tail.mjs"
check_mutation "読み取り窓を広げない（長いターンが全部 fail-closed へ落ちる）" "初段の読み取り窓を超える長いターンでも境界まで遡って判定する" "$ROOT"

ROOT="$(make_fixture context-notification-substring)"
expect_occurrences "$ROOT/hooks/retrospective-context.sh" 'prompt.startsWith("<task-notification>")' 1
perl -0pi -e 's/prompt\.startsWith\("<task-notification>"\)/prompt.includes("<task-notification>")/' "$ROOT/hooks/retrospective-context.sh"
check_mutation "通知判定を前置一致から部分一致へ緩める" "通知トークンを途中で引用しただけの prompt には従来どおり注入（前置一致）" "$ROOT"

# 節見出しの literal は消費側から採る（テスト側へ複製しない）。複製すると、見出しを
# 改名したときに変異が無音の no-op へ変わり、`check_mutation` は「狙った診断で red に
# なりません」と落ちるだけで原因に辿れない。取得できなければここで止める。
AUTOFIRE_HEADING="$(awk -F"'" '/^AUTOFIRE_HEADING=/ {print $2; exit}' "$CONSUMER")"
if [ -z "$AUTOFIRE_HEADING" ]; then
  echo "✗ 消費側から AUTOFIRE_HEADING を取得できません（変異が空振りするため中断）" >&2
  exit 1
fi
echo "  ✓ 消費側から節見出しを取得した（${AUTOFIRE_HEADING}）"

ROOT="$(make_fixture skill-drift)"
# グローバルな出現数は固定しない。消費側とこの変異はどちらも意味を担う自動発火節の
# 判定リストへ固定済みで、散文への引用追加は契約を変えない（Issue #956）。
# 壊すのは**意味を担う出現**（自動発火の判定リスト内）だけにする。この定型文はスキルの
# 正規出力なので散文中にも引用され、素朴な最左一致では「散文側の 1 件目」を壊すだけの
# 空振りになりうる（Issue #931）。範囲を節に閉じたうえで、**判定リスト行**（`N. ` 始まり）
# の中の出現だけを狙う。節に閉じるだけでは、リストより前の散文引用へ最短一致が当たり、
# 消費側は正常なリストを見て緑のまま = 偽の赤になる（Issue #962）。塞ぐのは 3 つ:
# 行頭アンカーで同一行の相互参照、負の先読み `(?!\n## )` で節越え、
# `\n\d+\. [^\n]*?` で「判定リスト行の中」。
FF_AUTOFIRE_HEADING="$AUTOFIRE_HEADING" perl -0pi \
  -e 's/(^\Q$ENV{FF_AUTOFIRE_HEADING}\E(?:(?!\n## ).)*?\n\d+\. [^\n]*?)振り返り: 今回は作業完了前のため対象外/${1}振り返り: 未完了/ms' \
  "$ROOT/skills/retrospective/SKILL.md"
check_mutation "SKILL 定型文 drift（自動発火の判定リスト側）" "hook / SKILL.md の自動発火契約が drift" "$ROOT"

# 節内かつ判定リストより前へ引用を足しても、変異が判定リスト行へ到達すること。
# 上の 3 つ目の絞りが外れると、変異が散文へ当たって消費側が緑になるため検出できる。
ROOT="$(make_fixture skill-drift-with-in-section-prose)"
FF_AUTOFIRE_HEADING="$AUTOFIRE_HEADING" perl -0pi \
  -e 's/(^\Q$ENV{FF_AUTOFIRE_HEADING}\E\n)/${1}\n参考: 未完了ターンは `振り返り: 今回は作業完了前のため対象外` と報告する。\n/m' \
  "$ROOT/skills/retrospective/SKILL.md"
FF_AUTOFIRE_HEADING="$AUTOFIRE_HEADING" perl -0pi \
  -e 's/(^\Q$ENV{FF_AUTOFIRE_HEADING}\E(?:(?!\n## ).)*?\n\d+\. [^\n]*?)振り返り: 今回は作業完了前のため対象外/${1}振り返り: 未完了/ms' \
  "$ROOT/skills/retrospective/SKILL.md"
check_mutation "節内散文が先にあっても変異は判定リスト行へ届く" "hook / SKILL.md の自動発火契約が drift" "$ROOT"

# 見出しを改名すると節の抽出が空になり、消費側は赤へ倒れる。
# この針が測るのは**抽出が空になった場合の挙動**であって、`[ -n ... ]` ガードの有無では
# ない（そのガードを外しても、空文字列を非空パターンで照合すれば偽になるので赤のまま。
# ガードは多重防御であり、この fixture はその削除に無感応である）。
ROOT="$(make_fixture autofire-heading-rename)"
FF_AUTOFIRE_HEADING="$AUTOFIRE_HEADING" perl -0pi \
  -e 's/^\Q$ENV{FF_AUTOFIRE_HEADING}\E/## 自動発火の契約/m' \
  "$ROOT/skills/retrospective/SKILL.md"
check_mutation "自動発火 節見出しの改名" "hook / SKILL.md の自動発火契約が drift" "$ROOT"

# 節に絞るだけでは足りない — **節内の散文**へ定型文を足したうえで判定リスト側を壊すと、
# 節全体を見る実装では散文側の出現で満たされ、#931 が狭い範囲で再発する（クロスモデル
# レビュー指摘）。この 2 段変異が赤くなることで「番号付きリスト行まで絞っている」ことを
# 実測する。1 段目だけでは良性変更なので、2 段目の破壊とセットで初めて意味を持つ。
ROOT="$(make_fixture in-section-prose-then-drift)"
FF_AUTOFIRE_HEADING="$AUTOFIRE_HEADING" perl -0pi \
  -e 's/(^\Q$ENV{FF_AUTOFIRE_HEADING}\E\n)/${1}\n本節では `振り返り: 今回は作業完了前のため対象外` の扱いを説明する（節内の散文）。\n/m' \
  "$ROOT/skills/retrospective/SKILL.md"
perl -0pi -e 's/^(\d+\. [^\n]*?)振り返り: 今回は作業完了前のため対象外/${1}振り返り: 未完了/m' \
  "$ROOT/skills/retrospective/SKILL.md"
check_mutation "節内の散文を残して判定リスト側を壊す" "hook / SKILL.md の自動発火契約が drift" "$ROOT"

# 定型文の契約は**両側**（SKILL.md の判定リストと hook の出力）で成立する。SKILL 側だけを
# 固定しても、hook 側の文字列が変わった drift は検出できない。
ROOT="$(make_fixture hook-incomplete-report)"
perl -0pi -e 's/振り返り: 今回は作業完了前のため対象外/振り返り: 未完了/g' \
  "$ROOT/hooks/retrospective-stop.sh"
check_mutation "hook 側 定型文 drift" "継続理由の必須境界が不足" "$ROOT"

ROOT="$(make_fixture skill-codex-host-drift)"
expect_occurrences "$ROOT/skills/retrospective/SKILL.md" 'Codex の Stop 入力（`model` フィールドあり）は常に無音' 1
perl -0pi -e 's/Codex の Stop 入力（`model` フィールドあり）は常に無音/Codex の Stop 入力は fallback/' \
  "$ROOT/skills/retrospective/SKILL.md"
check_mutation "SKILL の Codex Stop 無音契約 drift" "hook / SKILL.md の自動発火契約が drift" "$ROOT"

# Issue #840: SKILL.md の非対話スキップ規定（判定リスト項目 5）の drift。
ROOT="$(make_fixture skill-noninteractive-drift)"
expect_occurrences "$ROOT/skills/retrospective/SKILL.md" 'Codex の非対話の単発実行（UserPromptSubmit 入力に `model` があり' 1
perl -0pi -e 's/Codex の非対話の単発実行（UserPromptSubmit 入力に `model` があり/Codex の非対話の単発実行（入力に `model` があり/' \
  "$ROOT/skills/retrospective/SKILL.md"
check_mutation "SKILL の非対話スキップ規定 drift" "hook / SKILL.md の自動発火契約が drift" "$ROOT"

# 事前注入が担う契約は `#1612` で入れ替わった。定型文はもう注入文に無いので、
# 同じ位置で守るのは**発火条件そのもの**になる（旧: 定型文の綴り一致）。
ROOT="$(make_fixture context-chain-tail-drift)"
expect_occurrences "$ROOT/hooks/retrospective-context.sh" 'workflow chain tail' 2
perl -0pi -e 's/workflow chain tail/workflow closeout/g' \
  "$ROOT/hooks/retrospective-context.sh"
check_mutation "事前注入のチェーン末尾条件 drift" "UserPromptSubmit の事前注入契約が不正" "$ROOT"

ROOT="$(make_fixture stdin-timeout)"
perl -0pi -e 's/INPUT_TIMEOUT_SECONDS=2/INPUT_TIMEOUT_SECONDS=5/' "$ROOT/hooks/retrospective-stop.sh"
check_mutation "stdin 上限延長" "stdin 入力上限の決定的fixtureが失敗" "$ROOT"

ROOT="$(make_fixture ask-system-message)"
perl -0pi -e 's/Automatic retrospective check before stop/Automatic retrospective before stop/' "$ROOT/hooks/retrospective-stop.sh"
check_mutation "ask systemMessage drift" "ask モードの出力契約が不正" "$ROOT"

# ASDD ゲートの前置きを drain より前へ戻す退行。ゲートの早期終了はすべて exit 0 なので、
# 前置きが先にあると stdin 未読のまま抜け、書き手（ホスト）が EPIPE / SIGPIPE を受ける。
# 変異は「drain より前で ASDD ゲートが止めうる」状態を shebang 直後の 1 行で作る
# （行を動かす変異は regex で一意に書けないため、同じ失敗を最小形で再現する）。
ROOT="$(make_fixture stop-gate-before-drain)"
perl -0pi -e 's{\A(\#![^\n]*\n)}{$1source "\${BASH_SOURCE[0]\%/*}/asdd-hook-gate.sh"; asdd_hook_enabled retrospective || exit 0\n}' \
  "$ROOT/hooks/retrospective-stop.sh"
check_mutation "Stop hook の ASDD ゲートを drain より前へ戻す" "retrospective-stop.sh の drain（node 不在）" "$ROOT"

ROOT="$(make_fixture context-gate-before-drain)"
perl -0pi -e 's{\A(\#![^\n]*\n)}{$1source "\${BASH_SOURCE[0]\%/*}/asdd-hook-gate.sh"; asdd_hook_enabled retrospective || exit 0\n}' \
  "$ROOT/hooks/retrospective-context.sh"
check_mutation "事前注入 hook の ASDD ゲートを drain より前へ戻す" "retrospective-context.sh の drain（node 不在）" "$ROOT"

# 事前注入 hook の stdin 読み取りを node へ委譲したまま、判別を走らせない経路
# （kill switch が off / node 不在）の shell drain を外す退行（この hook が他の hook と
# 契約を揃える前の形）。判別 node が読む経路は無傷なので、赤くなるのは node 不在の probe。
ROOT="$(make_fixture context-no-node-drain-removed)"
expect_occurrences "$ROOT/hooks/retrospective-context.sh" "IFS= read -r -t \"\$INPUT_TIMEOUT_SECONDS\" -d '' _" 1
perl -0pi -e 's/IFS= read -r -t "\$INPUT_TIMEOUT_SECONDS" -d \x27\x27 _/:/' "$ROOT/hooks/retrospective-context.sh"
check_mutation "node 不在時の shell drain 削除" "retrospective-context.sh の drain（node 不在）" "$ROOT"

# ここから 5 件はクロスモデルレビューの裁定に対応する常設実測。
#
# (1) 天井: bounded read で諦める形へ戻す退行。入力上限（2 秒）を過ぎたあとの discard
# 段を殺すと、bash の逐次読み（~265 KB/s）では数 MB を読み切れず書き手が SIGPIPE で
# 死ぬ。200,000 バイトの probe だけでは上限内に収まるため緑のまま = 天井を測れない。
ROOT="$(make_fixture stop-drain-escalation-removed)"
expect_occurrences "$ROOT/hooks/retrospective-stop.sh" '[ "$READ_RC" -ne 0 ]' 1
perl -0pi -e 's/\[ "\$READ_RC" -ne 0 \]/false/' "$ROOT/hooks/retrospective-stop.sh"
check_mutation "Stop hook の discard 段を削除（bounded read へ戻す）" \
  "retrospective-stop.sh の天井 drain（ゲート早期終了）" "$ROOT"

ROOT="$(make_fixture context-drain-escalation-removed)"
expect_occurrences "$ROOT/hooks/retrospective-context.sh" '[ "$READ_RC" -ne 0 ]' 1
perl -0pi -e 's/\[ "\$READ_RC" -ne 0 \]/false/' "$ROOT/hooks/retrospective-context.sh"
check_mutation "事前注入 hook の discard 段を削除（bounded read へ戻す）" \
  "retrospective-context.sh の天井 drain（off）" "$ROOT"

# (2) 遅延 producer: 判別 node が入力上限で「答えを確定してから EOF まで捨てる」のを
# やめ、上限でそのまま終了する形へ戻す退行。上限を過ぎてから書き始めるホストの書き手が
# SIGPIPE を受ける。
ROOT="$(make_fixture context-latch-removed)"
expect_occurrences "$ROOT/hooks/retrospective-context.sh" 'setTimeout(latch,' 1
perl -0pi -e 's/setTimeout\(latch,/setTimeout(() => finish("inject"),/' "$ROOT/hooks/retrospective-context.sh"
check_mutation "判別 node が入力上限で drain を打ち切る" \
  "retrospective-context.sh の遅延 producer drain" "$ROOT"

# (3) kill switch（RETROSPECTIVE_MODE=off）の判定を判別 node より後ろへ戻す退行。
# off でも毎プロンプト node が起動する（drain は残るので SIGPIPE は出ず、壁時間だけが
# 増える）。tracer stub が「off で node が起動した」ことを見て赤になる。
ROOT="$(make_fixture context-off-after-detector)"
expect_occurrences "$ROOT/hooks/retrospective-context.sh" '[ "$RETROSPECTIVE_OFF" -eq 0 ]' 1
perl -0pi -e 's/\[ "\$RETROSPECTIVE_OFF" -eq 0 \] && command -v node/command -v node/' \
  "$ROOT/hooks/retrospective-context.sh"
check_mutation "kill switch の判定を判別 node より後ろへ戻す" \
  "retrospective-context.sh: off なのに node が起動した" "$ROOT"

# (4) 空 stdin の早期 exit を drain の隣へ戻す退行。ASDD ゲートより前に抜けるので、
# ゲートの stderr 診断（設定はあるが検証できない）が無検査のまま消える。
ROOT="$(make_fixture stop-empty-input-exit-before-gate)"
expect_occurrences "$ROOT/hooks/retrospective-stop.sh" 'READ_RC=$?' 1
perl -0pi -e 's/READ_RC=\$\?\n/READ_RC=\$?\n[ -n "\$HOOK_INPUT" ] || exit 0\n/' \
  "$ROOT/hooks/retrospective-stop.sh"
check_mutation "空 stdin の早期 exit を ASDD ゲートより前へ戻す" \
  "retrospective-stop.sh: 空 stdin でゲートの診断が消えた" "$ROOT"

# 静音契約の名簿が縮む変異（崩壊床の検出力）。名簿は hooks.json から導出するので、
# 縮めるには導出へ filter を足すしかない。hooks.json の登録と hooks/*.sh のゲート呼び出し
# という 2 つの実体との突き合わせが赤になる = 名簿が縮んだまま緑にならないことの実測。
ROOT="$(make_fixture roster-shrunk)"
expect_occurrences "$ROOT/tests/retrospective-stop-hook/asdd.test.mjs" '...registeredHooks()' 1
perl -0pi -e 's/\.\.\.registeredHooks\(\)/...registeredHooks().filter(dropped => dropped !== "guard-effort-actual.sh")/' \
  "$ROOT/tests/retrospective-stop-hook/asdd.test.mjs"
check_mutation "静音契約の名簿を 1 本減らす" "✖ roster is derived from hooks.json" "$ROOT"

# Issue #1451: FILING の ask 判定を大文字小文字・空白無視から厳密一致へ狭める退化。
# 空白・大文字混在の別名検査（Stop 側）が赤になること。
ROOT="$(make_fixture filing-ask-strict)"
perl -0pi -e 's/\[Aa\]\[Ss\]\[Kk\]\)\n    FILING_CLAUSE/ask)\n    FILING_CLAUSE/' "$ROOT/hooks/retrospective-stop.sh"
check_mutation "FILING の ask 別名判定の厳密化" "FILING の値の判定が不正" "$ROOT"

# 既定分岐の「承認を待たない」文言が承認待ちへ退化する変異。既定モードの positive grep が赤になること。
# 同じ句は hook 冒頭のコメントにもあるため /g で全出現を置換する（先頭 1 件だけだとコメントが
# 変わって注入文は無傷のまま、変異が空振りする）。
ROOT="$(make_fixture filing-default-approval)"
perl -0pi -e 's/without waiting for approval/after asking the user for approval/g' "$ROOT/hooks/retrospective-stop.sh"
check_mutation "既定の起票文言が承認待ちへ退化" "継続理由の必須境界が不足" "$ROOT"

# 節の外（散文）へ定型文を足すだけの変更は、意味を担う出現を壊していないので緑のまま
# であること。ここが赤くなる実装は「出現数の増加そのもの」を検出しているだけで、
# Issue #931 の欠陥（意味を担う側の破壊を見逃す）は直っていない。
ROOT="$(make_fixture prose-mention)"
printf '\n本節は `振り返り: 今回は作業完了前のため対象外` の扱いに触れる（散文中の引用）。\n' \
  >> "$ROOT/skills/retrospective/SKILL.md"
check_no_regression "節外の散文へ定型文を追記" "$ROOT"

# 節**内**へコードフェンスの例示を足しても赤くならないこと。上の EOF 追記は awk の
# 打ち切り位置より後なので節の境界を一切通らない — 境界そのものを測るのはこちら。
# フェンス内の `## ` 行で抽出が早期終了する実装だと、純粋な加筆でここが赤くなる。
ROOT="$(make_fixture fenced-heading-in-section)"
perl -0pi -e 's{(対応ホストでは[^\n]*\n)}{$1\n```text\n## セッション振り返り\n```\n}' \
  "$ROOT/skills/retrospective/SKILL.md"
check_no_regression "自動発火 節内へフェンス例示を追加" "$ROOT"

# ── 登録した検査を並列に回す ─────────────────────────────────────────────────
#
#   既定の同時実行数: 論理 CPU 数（上限 8）。上限を置くのは、consumer が測る入力上限の
#   契約（2 秒の上限 < 3 秒の EOF）が負荷で潰れると «間違った理由で赤い» を作るため。
#   上書き: FF_RETRO_SELFTEST_JOBS=<1〜64>。`1` で逐次へ戻る。解釈できない値と上限超過は
#   1 行警告のうえ既定値で続行する（fail-safe 側）。
#   spool は逐次実行でも使うので、確保できない回は退避せず fail-closed で止める。
RETRO_JOBS_DEFAULT=4
if command -v getconf >/dev/null 2>&1; then
  _retro_cpu="$(getconf _NPROCESSORS_ONLN 2>/dev/null || true)"
  case "$_retro_cpu" in
    ''|*[!0-9]*) ;;
    *) [ "$_retro_cpu" -ge 1 ] && RETRO_JOBS_DEFAULT=$(( _retro_cpu > 8 ? 8 : _retro_cpu )) ;;
  esac
fi
RETRO_JOBS="$RETRO_JOBS_DEFAULT"
# 入れ子の実行（run-all.sh から suite として呼ばれた回）は、明示指定が無ければ**予算を半分に
# 落とす**。run-all.sh が自分自身へ掛けている規約は「入れ子なら逐次」だが、この suite に
# そのまま当てると Issue の目的が消える — この suite が走るのは FF_RUN_ALL_FULL=1 のときだけで、
# それは必ず run-all.sh 経由（＝入れ子）だから、逐次へ倒すと短縮が一度も効かない。
#
# 掛け算の懸念（外 8 × 内 8 = 64）は、内部並列を持つ suite が**この 1 本だけ**なので実際には
# 成立しない。実態は「外側の 8 スロットのうち 1 つが内側 N を持つ」で、ピークは 7 + N。
# 予算を半分（上限 4）に落とせば、外側が既に受け入れている 8 並列と同程度に収まる。
#
# 実測の余裕: 16 論理 CPU で 32 並列（= 2× コア）でも 43 + 良性 2 のまま緑で、consumer が測る
# 実時間の契約（入力上限 2 秒 < EOF 3 秒 / 10MB を 2 秒以内）は壊れなかった。コア数の少ない CI を
# 考えて既定は控えめに置き、必要なら FF_RETRO_SELFTEST_JOBS で明示的に上書きする。
if [ -z "${FF_RETRO_SELFTEST_JOBS:-}" ] && [ "${FF_RUN_ALL_NESTED:-0}" != "0" ]; then
  RETRO_JOBS=$(( RETRO_JOBS_DEFAULT / 2 ))
  [ "$RETRO_JOBS" -ge 1 ] || RETRO_JOBS=1
fi
case "${FF_RETRO_SELFTEST_JOBS:-}" in
  '') ;;
  *[!0-9]*|'')
    echo "⚠️  FF_RETRO_SELFTEST_JOBS=\"${FF_RETRO_SELFTEST_JOBS}\" は解釈できない値です。既定（${RETRO_JOBS_DEFAULT}）で続行します" >&2 ;;
  *)
    if [ "$FF_RETRO_SELFTEST_JOBS" -ge 1 ] && [ "$FF_RETRO_SELFTEST_JOBS" -le 64 ]; then
      RETRO_JOBS="$FF_RETRO_SELFTEST_JOBS"
    else
      echo "⚠️  FF_RETRO_SELFTEST_JOBS=${FF_RETRO_SELFTEST_JOBS} は範囲外（1〜64）です。既定（${RETRO_JOBS_DEFAULT}）で続行します" >&2
    fi ;;
esac

# spool は**逐次実行でも要る**（run_job は同時実行数に関わらず結果をここへ書く）。作れない回に
# 「逐次へ退避します」と言っても退避先が無く、最後に「rc が残っていない」で落ちる — 成立しない
# 退避を警告文だけが約束する形になる。ここは fail-closed で止める。
#
# $TMP 自体は冒頭の mktemp -d が成功した時点で書けているので、この失敗は「走行中に消えた」
# のような異常であり、黙って続ける理由が無い。
SPOOL="$TMP/spool"
mkdir -p "$SPOOL" 2>/dev/null || {
  echo "✗ spool を作成できません: ${SPOOL}（${TMP} は作成済みなので、走行中に失われた可能性があります）" >&2
  exit 1
}

run_job() { # <index>
  local i="$1" root="${JOB_ROOTS[$1]}" rc=0 out
  out="$(bash "$root/tests/retrospective-stop-hook/verify.sh" 2>&1)" || rc=$?
  printf '%s' "$out" > "$SPOOL/$i.out"
  # rc は本文を書き終えた**後に** rename で置く。「rc ファイルの実在 = その出力が完成している」
  # を親が追加の同期なしに読めるようにするため（run-all.sh の spool と同じ規約）。
  printf '%s' "$rc" > "$SPOOL/$i.rc.tmp"
  mv "$SPOOL/$i.rc.tmp" "$SPOOL/$i.rc"
}

# 同時実行数の制限は **bash 3.2 で動く形**で書く。`wait -n` は bash 4.3 以降で、macOS 標準の
# 3.2 では `invalid option` になる。`wait -n || break` のように書くと**常に break して制限が
# 効かず**、全 job が一斉に起動する（結果は登録順の判定で正しく出るので、設計だけが静かに
# 壊れる）。走っている子の数を数えて空くまで短く待つ形にする。
_retro_started=0
_retro_waits=0
while [ "$_retro_started" -lt "$JOB_N" ]; do
  while [ "$(jobs -rp | wc -l | tr -d ' ')" -ge "$RETRO_JOBS" ]; do
    _retro_waits=$((_retro_waits + 1))
    sleep 0.2
  done
  run_job "$_retro_started" &
  _retro_started=$((_retro_started + 1))
done
wait

# 判定は登録順に行う（出力の並びを実行のたびに変えない）。
_retro_i=0
while [ "$_retro_i" -lt "$JOB_N" ]; do
  name="${JOB_NAMES[$_retro_i]}"
  kind="${JOB_KINDS[$_retro_i]}"
  expected="${JOB_EXPECTED[$_retro_i]}"
  if [ ! -f "$SPOOL/$_retro_i.rc" ]; then
    # rc を残さず子が消えた。pass にも fail にも倒さず、検査が成立していないこととして止める。
    echo "✗ $name の検査が完了しませんでした（rc が残っていない）" >&2
    exit 1
  fi
  RC="$(cat "$SPOOL/$_retro_i.rc")"
  OUT="$(cat "$SPOOL/$_retro_i.out" 2>/dev/null || true)"
  if [ "$kind" = mutation ]; then
    if [ "$RC" -ne 0 ] && printf '%s' "$OUT" | grep -F "$expected" >/dev/null; then
      echo "  ✓ $name を検出"
      MUTATIONS=$((MUTATIONS + 1))
    else
      echo "✗ $name が狙った診断で red になりません: exit=$RC output=[$OUT]" >&2
      exit 1
    fi
  else
    if [ "$RC" -eq 0 ]; then
      echo "  ✓ $name では red にならない"
      BENIGN=$((BENIGN + 1))
    else
      echo "✗ $name で red になりました（偽の赤）: exit=$RC output=[$OUT]" >&2
      exit 1
    fi
  fi
  _retro_i=$((_retro_i + 1))
done

# 制限が壊れても**結果は変わらない**（判定は登録順で行うため）。壊れるのは実行の仕方だけなので、
# 何も言わなければ誰も気づけない — 実際 `wait -n`（bash 4.3 以降）で書いた初版は macOS 標準の
# bash 3.2 で `invalid option` になり、全 job を一斉起動していたのに緑だった。
# job が同時実行数より多い回は、制限が最低 1 回は効いているはずである。
#
# **判定ループの後ろへ置く**。前に置くと、全 job が即死する回（spool 消失・fork 枯渇・ENOSPC）に
# プールが飽和せず waits=0 になり、真の失敗を隠して「プールが無効化されています」という誤った
# 原因を名指しする。実 job の診断が先に出てから、この主張を確かめる。
if [ "$JOB_N" -gt "$RETRO_JOBS" ] && [ "$_retro_waits" -eq 0 ]; then
  echo "✗ 同時実行数の制限が一度も効いていません（job ${JOB_N} 件 / 上限 ${RETRO_JOBS}）— プールが無効化されています" >&2
  exit 1
fi

# 件数は名前付き定数で持つ（このファイルは EXPECTED_CONSUMER_CHECKS で既にその慣習）。
EXPECTED_MUTATIONS=75
EXPECTED_BENIGN=2
if [ "$MUTATIONS" -ne "$EXPECTED_MUTATIONS" ]; then
  echo "✗ mutation 実行数が不正: ${MUTATIONS}（期待 ${EXPECTED_MUTATIONS}）" >&2
  exit 1
fi
if [ "$BENIGN" -ne "$EXPECTED_BENIGN" ]; then
  echo "✗ 良性変更の検査数が不正: ${BENIGN}（期待 ${EXPECTED_BENIGN}）" >&2
  exit 1
fi
REACHED_END=1
echo "✓ retrospective Stop hook mutation self-test: ${EXPECTED_MUTATIONS} 件すべて検出 / 良性変更 ${EXPECTED_BENIGN} 件は緑"
