#!/usr/bin/env bash
# Runtime contract for the issue label contract guard hook.
#
# 配布物 hooks/guard-issue-labels.sh を stdin JSON で直接駆動し、受け入れ条件の
# 各分岐を固定する:
#   1. type 系も priority 系も無い gh issue create → deny（欠落系統名 + 抜け道を同じ文面で案内）
#   2. type はあるが priority が無い → priority の欠落として deny（片系統の充足を充足と読まない）
#   3. type / priority が揃い follow-up が無い → deny せず systemMessage の案内だけ
#   4. 案内した抜け道（環境代入の前置）を明示的に使った起票 → 素通し
#   5. ラベル一覧を信用できない（照会失敗 / 空 / 上限到達）→ 素通し
#   6. gh issue create を含まない Bash と、heredoc 本文にだけ現れる形 → 素通し。
#      対で「終端行の直後の実 gh issue create は検出される」も固定する
#   7. gh / jq が PATH に無い → stdin を読み切ったうえで素通し
#
# 「正しい起票を止めない」側も対で固定する:
#   - 両起票スキルのテンプレート形（行末 `\` 継続 + 3 系統）は無音。対に「継続行でも
#     ラベルが無ければ停止する」を置き、継続行で fail-open に逃げていないことを示す
#   - 引用符の中の `|` / `;` / `&&` は分割点にしない。対に「引用符の外の区切りは
#     従来どおり分割する」を置く
#   - GitHub デフォルトの非種別ラベル 1 個では種別を充足しない。残した穴（未知の
#     名前空間ラベル 1 個での充足）は現状として固定する
#
# さらに、ラベル名の正本が setup-github-labels の軸別表であること、種別の否定名簿が
# デフォルトラベル表と create-issue の type 行の差分であることを**隔離コピーへの
# 変異注入**で実測する（hook 内に名前を直書きしていたら変異が効かず緑のまま残る）。
# gh は fixtures/bin の stub に解決させる。stub は `label list` 以外を非 0 で拒否する
# ので、想定外の gh 呼び出しを足すと赤になる。
#
# run-all-required: no — jq 不在での skip を許容する（一時領域依存 suite の必須判断で名簿へ載せなかった側。既存の Bash ガード suite と同じ扱い）
# 空振り検出: 検査対象 hooks/guard-issue-labels.sh を「exit 0 だけ」の空ファイルへ差し替えると 53 件が赤になる（2026-09-18 実測。先頭は AC1「type 系も priority 系も無い起票は停止する」。対象の不在・0 件出力を「違反なし」へ倒さないことの実測）。
# 空振り検出: 軸別表の優先度行から名前空間を落とす（`priority:critical` → `critical`）と、水準語の抽出が 0 件になって 23 件が赤になる（2026-09-18 実測。AC1「欠落系統に優先度が無い」/ AC2「type はあるが priority が無い起票は停止する」/ 別命名の全 deny 検査。書式変更による抽出空振りを「違反なし」へ畳まない）。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TARGET="$PLUGIN_ROOT/hooks/guard-issue-labels.sh"
# ASDD ゲートが早期終了する経路でも stdin を読み切ることを測る共有ヘルパー
# shellcheck source=../lib/asdd-gate-drain.sh
. "$SCRIPT_DIR/../lib/asdd-gate-drain.sh"
GATE_LIB="$PLUGIN_ROOT/hooks/asdd-hook-gate.sh"
HOOKS_JSON="$PLUGIN_ROOT/hooks/hooks.json"
LABEL_SKILL="$PLUGIN_ROOT/skills/setup-github-labels/SKILL.md"
DEFAULTS_MD="$PLUGIN_ROOT/docs-template/05-operations/deployment/github-setup.md"
CREATE_ISSUE_MD="$PLUGIN_ROOT/skills/create-issue/SKILL.md"
STUB_DIR="$SCRIPT_DIR/fixtures/bin"

for f in "$TARGET" "$GATE_LIB" "$HOOKS_JSON" "$LABEL_SKILL" "$DEFAULTS_MD" "$CREATE_ISSUE_MD" "$STUB_DIR/gh"; do
  [ -f "$f" ] || { echo "✗ 必要なファイルが見つかりません: $f" >&2; exit 1; }
done
if ! command -v jq >/dev/null 2>&1; then
  echo "○ skip: jq が見つからないためスキップ（guard-issue-labels は未検査のままです）"
  exit 0
fi

# rc=0 でも -d を検査する — 2>&1 の合流は「成功 + stderr 警告」の環境で変数へ
# 警告文が混入し、以後の処理が原因不明の失敗に化けるため。
if _ff_mktemp_out="$(mktemp -d "${TMPDIR:-/tmp}/ff-guard-issue-labels.XXXXXX" 2>&1)" && [ -d "$_ff_mktemp_out" ]; then
  TEST_TMP="$_ff_mktemp_out"
else
  echo "○ skip: 一時ディレクトリを作成できない環境のためスキップ（変異注入に隔離コピーが要ります）"
  printf '  mktemp: %s\n' "$_ff_mktemp_out"
  exit 0
fi
REACHED_END=0
cleanup() {
  local rc=$?
  rm -rf "$TEST_TMP"
  if [ "$REACHED_END" -ne 1 ] && [ "$rc" -eq 0 ]; then
    echo "✗ guard-issue-labels: 最後まで到達しませんでした" >&2
    rc=1
  fi
  exit "$rc"
}
trap cleanup EXIT
trap 'exit 130' HUP INT TERM

PASS=0
FAIL=0
ok() { echo "  ✓ $1"; PASS=$((PASS + 1)); }
bad() { echo "  ✗ $1" >&2; FAIL=$((FAIL + 1)); }

# stub を PATH の先頭へ置く（本物の gh を絶対に呼ばない）。
export PATH="$STUB_DIR:$PATH"
resolved_gh="$(command -v gh || true)"
if [ "$resolved_gh" != "$STUB_DIR/gh" ]; then
  echo "✗ gh が stub に解決されません（解決先: ${resolved_gh:-なし}）。本物のリポジトリを照会しかねないため中断します" >&2
  exit 1
fi

OUT=""
RC=0
DECISION=""
REASON=""
MESSAGE=""

run_hook() { # <command> [hook-path] [env NAME=VALUE ...]
  local cmd="$1" hook="${2:-$TARGET}"
  shift 2 2>/dev/null || shift $#
  local json
  json="$(jq -n --arg c "$cmd" --arg d "$TEST_TMP" \
    '{tool_name: "Bash", tool_input: {command: $c}, cwd: $d, hook_event_name: "PreToolUse"}')"
  RC=0
  if [ "$#" -gt 0 ]; then
    OUT="$(printf '%s' "$json" | env "$@" bash "$hook" 2>/dev/null)" || RC=$?
  else
    OUT="$(printf '%s' "$json" | bash "$hook" 2>/dev/null)" || RC=$?
  fi
  DECISION="$(printf '%s' "$OUT" | jq -r '.hookSpecificOutput.permissionDecision // empty' 2>/dev/null || true)"
  REASON="$(printf '%s' "$OUT" | jq -r '.hookSpecificOutput.permissionDecisionReason // empty' 2>/dev/null || true)"
  MESSAGE="$(printf '%s' "$OUT" | jq -r '.systemMessage // empty' 2>/dev/null || true)"
  # 欠落系統の列挙は deny 文の 1 行目。以降の説明文にも「種別」「優先度」の語が
  # 出るため、系統の名指しを見る検査はこの行へスコープする（本文全体を針にすると
  # 「充足済みの系統を名指ししない」側が常に緑になり検出力を失う）。
  MISSING_LINE="$(printf '%s\n' "$REASON" | head -1)"
}

assert_deny() { # <label>
  if [ "$RC" -eq 0 ] && [ "$DECISION" = "deny" ]; then
    ok "$1"
  else
    bad "$1: exit=$RC decision=[$DECISION] out=[$OUT]"
  fi
}

assert_silent() { # <label>
  if [ "$RC" -eq 0 ] && [ -z "$OUT" ]; then
    ok "$1"
  else
    bad "$1: exit=$RC out=[$OUT]"
  fi
}

assert_not_deny() { # <label>
  if [ "$RC" -eq 0 ] && [ -z "$DECISION" ]; then
    ok "$1"
  else
    bad "$1: exit=$RC decision=[$DECISION] out=[$OUT]"
  fi
}

assert_message_only() { # <label>
  if [ "$RC" -eq 0 ] && [ -z "$DECISION" ] && [ -n "$MESSAGE" ]; then
    ok "$1"
  else
    bad "$1: exit=$RC decision=[$DECISION] out=[$OUT]"
  fi
}

echo "guard-issue-labels: 停止する側（type / priority の欠落）"
run_hook 'gh issue create --title t --body b'
assert_deny "AC1: type 系も priority 系も無い起票は停止する"
case "$MISSING_LINE" in
  *種別*) ok "AC1: 欠落系統として種別を名指しする" ;;
  *) bad "AC1: 欠落系統に種別が無い: [$MISSING_LINE]" ;;
esac
case "$MISSING_LINE" in
  *優先度*) ok "AC1: 欠落系統として優先度を名指しする" ;;
  *) bad "AC1: 欠落系統に優先度が無い: [$MISSING_LINE]" ;;
esac
case "$REASON" in
  *FF_DEV_TOOLKIT_SKIP_ISSUE_LABEL_GUARD=1*) ok "AC1: 同じ文面で抜け道（環境変数）を案内する" ;;
  *) bad "AC1: 抜け道の案内が無い: [$REASON]" ;;
esac
case "$REASON" in
  *out-of-scope-issue*) ok "AC1: 同じ文面で起票スキル経由の迂回手段を案内する" ;;
  *) bad "AC1: 起票スキルの案内が無い: [$REASON]" ;;
esac
case "$REASON" in
  *create-issue*) ok "AC1: 着手前起票の経路（create-issue）も案内する" ;;
  *) bad "AC1: create-issue の案内が無い: [$REASON]" ;;
esac

run_hook 'gh issue create --title t --label bug'
assert_deny "AC2: type はあるが priority が無い起票は停止する"
case "$MISSING_LINE" in
  *優先度*) ok "AC2: 欠落系統として優先度だけを名指しする" ;;
  *) bad "AC2: 欠落系統に優先度が無い: [$MISSING_LINE]" ;;
esac
case "$MISSING_LINE" in
  *種別*) bad "AC2: 充足済みの種別まで欠落として名指ししている: [$MISSING_LINE]" ;;
  *) ok "AC2: 充足済みの種別は欠落として名指ししない" ;;
esac

run_hook 'gh issue create --title t --label priority:high'
assert_deny "AC2 裏: priority はあるが type が無い起票も停止する"
run_hook 'gh issue create --title t --label=priority:high'
assert_deny "--label=<値> 形も解釈する"
run_hook 'gh issue create --title t -l priority:high'
assert_deny "-l 短縮形も解釈する"

echo "guard-issue-labels: 停止しない側"
run_hook 'gh issue create --title t --label bug --label priority:high'
assert_message_only "AC3: type / priority が揃い follow-up が無い起票は停止せず案内だけ"
case "$MESSAGE" in
  *follow-up*) ok "AC3: 案内が follow-up を名指しする" ;;
  *) bad "AC3: 案内に follow-up が無い: [$MESSAGE]" ;;
esac
case "$MESSAGE" in
  *create-issue*) ok "AC3: 案内が create-issue 経由なら不要である旨を添える" ;;
  *) bad "AC3: create-issue の但し書きが無い: [$MESSAGE]" ;;
esac
run_hook 'gh issue create --title t --label bug --label priority:high --label follow-up'
assert_silent "3 系統が揃った起票は無出力"
run_hook 'gh issue create --title t --label "bug,priority:high,follow-up"'
assert_silent "カンマ区切りの --label も 3 系統として読む"
run_hook 'gh issue create --title t --label enhancement --label priority:medium --repo example/repo'
assert_message_only "--repo <値> の起票でも同じ判定へ入る（stub は label list 以外を非 0 で拒否する）"
run_hook 'gh issue create --title t --label enhancement --label priority:medium --repo=example/repo'
assert_message_only "--repo=<値> 形も解釈する"

echo "guard-issue-labels: 契約どおりの起票を止めない（行継続 / 引用符）"
# 両起票スキルの「ステップ 3: 起票（単独コマンド）」テンプレートそのものの形。
# 行末 `\` を繋がずに物理行だけを見ると `--label` が一切見えず、契約を守った起票を
# deny する（しかも deny 文はそのスキルを使えと案内するのでループになる）。
SKILL_TEMPLATE="$(printf '%s\n' \
  'gh issue create \' \
  '  --repo "$expected_repo" \' \
  '  --label "bug" \' \
  '  --label "priority:high" \' \
  '  --label "follow-up" \' \
  '  --title "fix: t" \' \
  '  --body-file "/tmp/body.md"')"
run_hook "$SKILL_TEMPLATE"
assert_silent "起票スキルのテンプレート形（行末 \\ 継続 + 3 系統）は無音で通す"
SKILL_TEMPLATE_NOLABEL="$(printf '%s\n' \
  'gh issue create \' \
  '  --repo "$expected_repo" \' \
  '  --title "fix: t" \' \
  '  --body-file "/tmp/body.md"')"
run_hook "$SKILL_TEMPLATE_NOLABEL"
assert_deny "対: 行継続でもラベルが無ければ停止する（継続行で fail-open に逃げていない）"

# 引用符の中の区切り文字で分割すると、常用形（Markdown 表を含む本文・タイトル）が
# 誤 deny される。既存ガードは同じ近道でも fail-open へ倒れるが、本ガードは発火条件が
# 「ラベルが無い」なので fail-closed へ反転する。
run_hook 'gh issue create --title "A | B" --label bug --label priority:high'
assert_message_only '--title "A | B" のパイプは分割点にしない'
run_hook 'gh issue create --body "a; b" --label bug --label priority:high'
assert_message_only '--body "a; b" のセミコロンは分割点にしない'
run_hook 'gh issue create --body "a && b" --label bug --label priority:high'
assert_message_only '--body "a && b" の && は分割点にしない'
# 対: 引用符の**外**の区切りは従来どおり分割する（分割をやめたのではない）
run_hook 'gh issue list --label bug | head -1; gh issue create --title t'
assert_deny "対: 引用符の外の ; と | は分割点のまま（後続セグメントの起票を検出する）"

run_hook 'FF_DEV_TOOLKIT_SKIP_ISSUE_LABEL_GUARD=1 gh issue create --title t'
assert_silent "AC4: 案内した抜け道を前置した起票は停止しない"
run_hook 'gh issue create --title t' "$TARGET" 'FF_DEV_TOOLKIT_SKIP_ISSUE_LABEL_GUARD=1'
assert_silent "AC4: 環境変数としての抜け道でも停止しない"

echo "guard-issue-labels: AC5 ラベル一覧を信用できないときは停止しない"
run_hook 'gh issue create --title t' "$TARGET" 'FF_STUB_LABELS_MODE=fail'
assert_silent "AC5: gh label list が失敗したら停止しない"
run_hook 'gh issue create --title t' "$TARGET" 'FF_STUB_LABELS_MODE=empty'
# 注意: この検査に回帰の針としての検出力は無い。hook 側の `[ -n "$repo_labels" ]` を
# 単独で削っても後段で `*_available` が全部 0 になり結果は一致する（冗長な二重防御で、
# 両 SKILL.md の「失敗 / 空 / 上限到達」3 条件をコード側でも並べて書くためのもの）。
assert_silent "AC5: gh label list の出力が空なら停止しない（空は後段でも吸収される二重防御）"
run_hook 'gh issue create --title t' "$TARGET" 'FF_STUB_LABELS_MODE=limit'
assert_silent "AC5: gh label list が取得上限に達していたら停止しない"
run_hook 'gh issue create --title t --label bug' "$TARGET" 'FF_STUB_LABELS_MODE=nopriority'
assert_not_deny "AC5: 対象リポジトリに priority 系が実在しないなら priority を要求しない"
run_hook 'gh issue create --title t --label priority:high' "$TARGET" 'FF_STUB_LABELS_MODE=notype'
assert_not_deny "AC5: 対象リポジトリに種別へ使える名前が 1 件も無いなら種別を要求しない"
run_hook 'gh issue create --title t --label bug --label priority:high' "$TARGET" 'FF_STUB_LABELS_MODE=nofollowup'
assert_silent "AC5: 対象リポジトリに follow-up が実在しないなら案内も出さない"

echo "guard-issue-labels: 種別の否定名簿（GitHub デフォルトのうち種別でないもの）"
run_hook 'gh issue create --title t --label wontfix --label priority:high'
assert_deny "GitHub デフォルトの非種別ラベル 1 個では種別を充足しない"
run_hook 'gh issue create --title t --label "good first issue" --label priority:high'
assert_deny "空白を含む非種別ラベルも値ごと読んで種別を充足させない（断片で素通ししない）"
run_hook 'gh issue create --title t --label documentation --label priority:high'
assert_message_only "対: デフォルトのうち種別として使う名前は充足させる（否定名簿へ入れない）"
# 対: 空白を含む**固有の**種別ラベルは充足させる。素朴な空白分割へ戻すと値が断片へ
# 割れ、断片は種別候補から外れるので誤 deny になる（トークン化の回帰を検出する針）。
run_hook 'gh issue create --title t --label "my type" --label priority:high' "$TARGET" \
  'FF_STUB_LABELS_MODE=custom' "FF_STUB_LABELS=my type
priority:high
follow-up"
assert_message_only "対: 空白を含む固有の種別ラベルは値ごと読んで充足させる"
# 残した穴を現状として固定する。消費プロジェクト固有の種別名（`feature` など）を
# 誤ブロックしないために否定形判定のまま残しており、未知の名前空間ラベル 1 個での
# 種別充足はここでは塞がない。後で締めたときにこの行が差分として見える。
run_hook 'gh issue create --title t --label area:api --label priority:high'
assert_message_only "既知の穴: 未知の名前空間ラベル 1 個で種別が充足する（現状を固定）"

echo "guard-issue-labels: 優先度の別命名（綴りを消費側の実体から引く）"
# 消費側の実測（feel-flow/hearing-realtime, 付与実績 592 件）と同じ命名。正本の綴り
# （`priority:*`）は 1 件も無く、水準語だけを共有する。
ALIAS_LABELS="bug
enhancement
documentation
follow-up
P0-Critical
P1-High
P2-Medium
P3-Low"
alias_run() { # <command> [hook]
  run_hook "$1" "${2:-$TARGET}" 'FF_STUB_LABELS_MODE=custom' "FF_STUB_LABELS=$ALIAS_LABELS"
}

alias_run 'gh issue create --title t --label bug'
assert_deny "別命名: 種別だけの起票は優先度の欠落として停止する（旧形はここが素通しだった）"
case "$MISSING_LINE" in
  *優先度*) ok "別命名: 欠落系統として優先度を名指しする" ;;
  *) bad "別命名: 欠落系統に優先度が無い: [$MISSING_LINE]" ;;
esac
case "$MISSING_LINE" in
  *P0-Critical*) ok "別命名: 例として消費側の実際の綴りを出す（正本の綴りを勧めない）" ;;
  *) bad "別命名: 例が消費側の綴りでない: [$MISSING_LINE]" ;;
esac
case "$MISSING_LINE" in
  *種別*) bad "別命名: 充足済みの種別まで欠落として名指ししている: [$MISSING_LINE]" ;;
  *) ok "別命名: 充足済みの種別は欠落として名指ししない" ;;
esac

alias_run 'gh issue create --title t --label P1-High'
assert_deny "別命名: 優先度ラベルだけの起票は種別の欠落として停止する"
case "$MISSING_LINE" in
  *種別*) ok "別命名: 別命名の優先度ラベルは種別として充足しない" ;;
  *) bad "別命名: 種別が欠落として名指しされない（優先度ラベルが種別を充足している）: [$MISSING_LINE]" ;;
esac
case "$MISSING_LINE" in
  *優先度*) bad "別命名: 優先度を充足しているのに欠落として名指ししている: [$MISSING_LINE]" ;;
  *) ok "別命名: 優先度としては充足する" ;;
esac

# `gh` のラベル解決は大小を区別しないので、判定も水準語の大小を区別しない。
alias_run 'gh issue create --title t --label p1-high'
assert_deny "別命名: 水準語の大小が違っても優先度として読む"
case "$MISSING_LINE" in
  *優先度*) bad "別命名: 小文字形を優先度として読めていない: [$MISSING_LINE]" ;;
  *) ok "別命名: 小文字形も優先度として充足する" ;;
esac

alias_run 'gh issue create --title t --label bug --label P1-High'
assert_message_only "別命名: 種別 + 別命名の優先度が揃えば停止しない"
alias_run 'gh issue create --title t --label bug --label P1-High --label follow-up'
assert_silent "別命名: 3 系統が揃った起票は無出力"

# 別命名として採る条件は「同一ファミリが正本の水準の**過半**を覆う」こと。ここを
# 緩めると、優先度軸を持たないリポジトリで無関係なラベルが優先度として読まれ、
# **正しい起票が誤ブロックされる**（下 3 件はいずれもその実測形）。
run_hook 'gh issue create --title t --label docs-low' "$TARGET" 'FF_STUB_LABELS_MODE=custom' \
  "FF_STUB_LABELS=bug
follow-up
docs-low"
assert_message_only "1 水準だけの一致は優先度系統として採らない（誤ブロックしない側へ倒す）"
run_hook 'gh issue create --title t --label bug --label follow-up' "$TARGET" 'FF_STUB_LABELS_MODE=custom' \
  "FF_STUB_LABELS=bug
follow-up
effort-high
effort-low"
assert_silent "2 水準の別軸（effort-*）は優先度として採らない（正しい起票を止めない）"
run_hook 'gh issue create --title t --label bug --label follow-up' "$TARGET" 'FF_STUB_LABELS_MODE=custom' \
  "FF_STUB_LABELS=bug
follow-up
docs-high
docs-low"
assert_silent "2 水準の別軸（docs-*）も優先度として採らない"
# 区切りの要求。これが無いと水準語で終わるだけの種別ラベル（`workflow` の末尾 `low`）が
# 優先度として読まれ、種別の欠落で誤ブロックされる。
run_hook 'gh issue create --title t --label workflow --label P1-High --label P2-Medium --label P3-Low --label follow-up' \
  "$TARGET" 'FF_STUB_LABELS_MODE=custom' \
  "FF_STUB_LABELS=bug
workflow
follow-up
P1-High
P2-Medium
P3-Low"
assert_silent "区切りの無い連結（workflow の末尾 low）は水準語として読まない"
# 区切りは空白も受ける（実世界で多い `Priority: High` 形）。正本の 4 水準のうち 3 水準
# （過半）を同一ファミリが覆うので発火する。
run_hook 'gh issue create --title t --label bug' "$TARGET" 'FF_STUB_LABELS_MODE=custom' \
  "FF_STUB_LABELS=bug
follow-up
Priority: High
Priority: Medium
Priority: Low"
assert_deny "空白区切りの別命名（Priority: High）も優先度系統として読む"
case "$MISSING_LINE" in
  *"Priority: High"*) ok "空白区切りでも例に消費側の実際の綴りを出す" ;;
  *) bad "空白区切りの例が消費側の綴りでない: [$MISSING_LINE]" ;;
esac

# 発火の条件は「正本の綴りの優先度が対象リポジトリに 1 件も無い」こと。正本の綴りが
# 在るリポジトリでは、別命名らしき形のラベルがあっても判定材料に加えない。
run_hook 'gh issue create --title t --label docs-high' "$TARGET" 'FF_STUB_LABELS_MODE=custom' \
  "FF_STUB_LABELS=bug
follow-up
docs-high
docs-low
priority:high
priority:low"
assert_deny "正本の綴りが在るリポジトリでは別命名の網を張らない（docs-high は従来どおり種別）"
case "$MISSING_LINE" in
  *優先度*) ok "正本の綴りが在れば、別命名らしき形は優先度を充足しない" ;;
  *) bad "正本の綴りが在るのに別命名の網が発火している: [$MISSING_LINE]" ;;
esac

echo "guard-issue-labels: AC6 対象外と heredoc（対で固定する）"
run_hook 'npm test'
assert_silent "AC6: gh issue create を含まない Bash は素通し"
run_hook 'gh issue list --label bug'
assert_silent "AC6: gh issue create でないサブコマンドは素通し"
run_hook "echo 'gh issue create --title t'"
assert_silent "AC6: コマンド位置に無い gh（echo の文字列）は素通し"
HEREDOC_ONLY="$(printf 'cat <<%sEOF%s > note.md\ngh issue create --title t --label bug\nEOF\n' "'" "'")"
run_hook "$HEREDOC_ONLY"
assert_silent "AC6: heredoc 本文にだけ現れる gh issue create は無音"
HEREDOC_THEN_REAL="$(printf 'cat <<%sEOF%s > note.md\nメモ本文\nEOF\ngh issue create --title t\n' "'" "'")"
run_hook "$HEREDOC_THEN_REAL"
assert_deny "AC6 対: heredoc 終端行の直後に続く実 gh issue create は検出される"

echo "guard-issue-labels: AC7 gh / jq 不在と stdin の drain"
# payload をパイプバッファ（64 KiB）より大きくして drain 漏れを OS に依らず検出する
# （hook が stdin を読まずに exit すると書き手が SIGPIPE を受け、pipefail 下で rc=141）。
BIG_PAYLOAD="$(jq -n '{tool_name: "Bash", tool_input: {command: "gh issue create --title t"}, cwd: "/tmp"}')$(printf '%*s' 200000 '')"
RC=0
OUT="$(printf '%s' "$BIG_PAYLOAD" | PATH="/nonexistent" /bin/bash "$TARGET" 2>/dev/null)" || RC=$?
if [ "$RC" -eq 0 ] && [ -z "$OUT" ]; then
  ok "AC7: gh / jq が PATH に無くても stdin を読み切ってから無出力 exit 0"
else
  bad "AC7: PATH 空の drain: exit=$RC out=[$OUT]（rc=141 なら hook が stdin を drain せずに exit している）"
fi
RC=0
OUT="$(printf '%s' "$BIG_PAYLOAD" | FF_DEV_TOOLKIT_SKIP_ISSUE_LABEL_GUARD=1 PATH="/nonexistent" /bin/bash "$TARGET" 2>/dev/null)" || RC=$?
if [ "$RC" -eq 0 ] && [ -z "$OUT" ]; then
  ok "AC7: opt-out でも stdin を読み切ってから無出力 exit 0"
else
  bad "AC7: opt-out の drain: exit=$RC out=[$OUT]（rc=141 なら opt-out の早期 exit が read より前にある）"
fi
RC=0
OUT="$(printf 'not-json' | bash "$TARGET" 2>/dev/null)" || RC=$?
if [ "$RC" -eq 0 ] && [ -z "$OUT" ]; then
  ok "壊れた stdin JSON は無出力 exit 0（fail-open）"
else
  bad "壊れた stdin JSON: exit=$RC out=[$OUT]"
fi

echo "guard-issue-labels: ラベル名の正本が軸別表であることの変異注入"
if ! command -v perl >/dev/null 2>&1; then
  echo "  ○ skip: perl が無いため変異注入を実行できません（部分 skip）"
else
# hook と正本を隔離コピーし、正本だけを書き換える。hook 内にラベル名を直書きして
# いたら以下の変異は効かず、期待どおりに挙動が変わらない。
COPY="$TEST_TMP/plugin"
mkdir -p "$COPY/hooks" "$COPY/tests/lib" "$COPY/skills/setup-github-labels" \
  "$COPY/skills/create-issue" "$COPY/docs-template/05-operations/deployment"
cp "$TARGET" "$COPY/hooks/guard-issue-labels.sh"
# heredoc 除去は共有ヘルパ（hooks/../tests/lib/）を source するので、コピー側にも置く
cp "$PLUGIN_ROOT/tests/lib/heredoc-strip.sh" "$COPY/tests/lib/heredoc-strip.sh"
cp "$GATE_LIB" "$COPY/hooks/asdd-hook-gate.sh"
cp "$PLUGIN_ROOT/hooks/asdd-feature.mjs" "$COPY/hooks/asdd-feature.mjs" 2>/dev/null || true
cp "$LABEL_SKILL" "$COPY/skills/setup-github-labels/SKILL.md"
cp "$DEFAULTS_MD" "$COPY/docs-template/05-operations/deployment/github-setup.md"
cp "$CREATE_ISSUE_MD" "$COPY/skills/create-issue/SKILL.md"
COPY_HOOK="$COPY/hooks/guard-issue-labels.sh"
COPY_SKILL="$COPY/skills/setup-github-labels/SKILL.md"
COPY_DEFAULTS="$COPY/docs-template/05-operations/deployment/github-setup.md"
COPY_CREATE_ISSUE="$COPY/skills/create-issue/SKILL.md"

run_hook 'gh issue create --title t' "$COPY_HOOK"
assert_deny "正の対照: 無変異の隔離コピーでも停止する（コピー自体は判定を変えない）"

# 変異 1: 優先度の軸行を落とす → 正本から系統を引けず fail-open（無音）になる
perl -0pi -e 's/^\| *優先度 *\|.*\n//m' "$COPY_SKILL"
run_hook 'gh issue create --title t' "$COPY_HOOK"
assert_silent "変異 1: 軸別表から優先度行を削ると fail-open で無音（名前を直書きしていない証拠）"
cp "$LABEL_SKILL" "$COPY_SKILL"

# 変異 2: 優先度の名前空間を別名へ差し替える → 旧名は priority と読まれなくなる
perl -0pi -e 's/`priority:/`sev:/g' "$COPY_SKILL"
run_hook 'gh issue create --title t --label bug --label priority:high' "$COPY_HOOK" \
  'FF_STUB_LABELS_MODE=custom' "FF_STUB_LABELS=bug
sev:critical
sev:high
follow-up"
assert_deny "変異 2: 正本の名前空間を差し替えると旧 priority: は優先度として読まれない"
run_hook 'gh issue create --title t --label bug --label sev:high' "$COPY_HOOK" \
  'FF_STUB_LABELS_MODE=custom' "FF_STUB_LABELS=bug
sev:critical
sev:high
follow-up"
assert_message_only "変異 2 対: 差し替えた新名は優先度として読まれる（停止せず案内だけ）"
cp "$LABEL_SKILL" "$COPY_SKILL"

# 変異 3: 分類の補完 軸の follow-up を改名する → 案内が新名を名指しする
perl -0pi -e 's/`follow-up`/`followup`/g' "$COPY_SKILL"
run_hook 'gh issue create --title t --label bug --label priority:high' "$COPY_HOOK" \
  'FF_STUB_LABELS_MODE=custom' "FF_STUB_LABELS=bug
priority:high
followup"
if [ "$RC" -eq 0 ] && [ -z "$DECISION" ]; then
  case "$MESSAGE" in
    *"--label followup"*) ok "変異 3: 正本で改名した follow-up の新名を案内が名指しする" ;;
    *) bad "変異 3: 案内が新名を名指ししない: [$MESSAGE]" ;;
  esac
else
  bad "変異 3: 停止してしまった: exit=$RC decision=[$DECISION] out=[$OUT]"
fi
cp "$LABEL_SKILL" "$COPY_SKILL"

# 変異 4: 軸別表そのものを壊す（ヘッダを改名）→ 何も主張しない
perl -0pi -e 's/^\| *軸 *\|/| 分類軸 |/m' "$COPY_SKILL"
run_hook 'gh issue create --title t' "$COPY_HOOK"
assert_silent "変異 4: 軸別表のヘッダを改名すると抽出できず無音（表へスコープしている証拠）"
cp "$LABEL_SKILL" "$COPY_SKILL"

# 変異 5: 否定名簿の正本 (1)（デフォルトラベル表）から当該行を落とす → その名前は
# 「デフォルトで在る非種別」ではなくなり、否定形判定のまま種別として充足する
run_hook 'gh issue create --title t --label wontfix --label priority:high' "$COPY_HOOK"
assert_deny "変異 5 前: 隔離コピーでも非種別デフォルトは種別を充足しない"
perl -0pi -e 's/^\| *`wontfix` *\|.*\n//m' "$COPY_DEFAULTS"
run_hook 'gh issue create --title t --label wontfix --label priority:high' "$COPY_HOOK"
assert_message_only "変異 5: デフォルトラベル表から行を落とすと否定名簿から外れる（名前を直書きしていない証拠）"
cp "$DEFAULTS_MD" "$COPY_DEFAULTS"

# 変異 6: 否定名簿の正本 (2)（create-issue 手順 5 の type 行）を落とす → 差分が
# 取れず名簿は空になり、非種別デフォルトも種別として充足する（fail-open 側へ倒れる）
perl -0pi -e 's/^\| *type *\|.*\n//m' "$COPY_CREATE_ISSUE"
run_hook 'gh issue create --title t --label wontfix --label priority:high' "$COPY_HOOK"
assert_message_only "変異 6: type 行を落とすと否定名簿を作れず種別判定が緩む（fail-open）"
cp "$CREATE_ISSUE_MD" "$COPY_CREATE_ISSUE"

# 変異 7: 軸別表の優先度行から名前空間を落とす（`priority:critical` → `critical`）→
# 水準語（`:` 以降）を切り出せなくなり、別命名の綴りを引けない。水準語の正本が軸別表で
# あることの実測（hook 側に水準語を直書きしていたらここは緑のまま残る）。
perl -0pi -e 's/`priority:/`/g' "$COPY_SKILL"
alias_run 'gh issue create --title t --label bug' "$COPY_HOOK"
# `assert_not_deny` だと「hook が丸ごと早期 exit した」回とも区別できない
# （`[ -n "$PRIORITY_NAMES" ] || exit 0`）。follow-up の案内が出ることまで見て、
# **判定へ到達したうえで別命名を引けなかった**ことを固定する。
assert_message_only "変異 7: 軸別表から名前空間を落とすと別命名を引けず旧形の fail-open へ戻る"
cp "$LABEL_SKILL" "$COPY_SKILL"

# 変異 8: 判定を旧形へ戻す（別命名の採用を無効化）→ 同じリポジトリで優先度が要求されなく
# なり、さらに優先度ラベルが種別として充足する（報告された二重の fail-open が再現する）。
perl -0pi -e 's/^  PRIORITY_ALIAS_ACTIVE=1$/  PRIORITY_ALIAS_ACTIVE=0/m' "$COPY_HOOK"
alias_run 'gh issue create --title t --label bug' "$COPY_HOOK"
assert_message_only "変異 8: 別命名の採用を無効化すると優先度が要求されなくなる（旧形の再現）"
alias_run 'gh issue create --title t --label P1-High' "$COPY_HOOK"
assert_message_only "変異 8 対: 同時に優先度ラベルが種別として充足する（二重の fail-open）"
cp "$TARGET" "$COPY_HOOK"
alias_run 'gh issue create --title t --label bug' "$COPY_HOOK"
assert_deny "変異 8 復元: hook を戻すと再び優先度を要求する"

run_hook 'gh issue create --title t' "$COPY_HOOK"
assert_deny "復元: 正本を戻すと再び停止する"
fi

echo "guard-issue-labels: 正本のハードコード禁止（静的検査）"
# 軸別表のラベル名が hook のコード行（コメント・文言を除く）に現れていないこと。
# 名前を持たせると正本が 3 つ目になり、上の変異注入が効かなくなる。
code_lines="$(grep -v '^[[:space:]]*#' "$TARGET" || true)"
hardcoded=""
while IFS= read -r name; do
  [ -n "$name" ] || continue
  case "$name" in
    follow*) continue ;; # follow-up は「選び方」を書くので語幹が出る（変異 3 が実体を固定する）
  esac
  if grep -Fq -- "$name" <<<"$code_lines"; then
    hardcoded="${hardcoded:+$hardcoded }$name"
  fi
done <<EOF
$(awk '
  /^\|[[:space:]]*軸[[:space:]]*\|/ { on = 1; next }
  on && !/^\|/ { on = 0 }
  on {
    line = $0
    while (match(line, /`[^`]+`/)) {
      tok = substr(line, RSTART + 1, RLENGTH - 2)
      line = substr(line, RSTART + RLENGTH)
      if (tok ~ /^[a-z][a-z0-9:-]*$/) print tok
    }
  }
' "$LABEL_SKILL")
EOF
if [ -n "$hardcoded" ]; then
  bad "hook のコード行に軸別表のラベル名が直書きされています: $hardcoded"
else
  ok "hook のコード行に軸別表のラベル名を直書きしていない"
fi

echo "guard-issue-labels: 前置フィルタの静的照合（ACE-1076-2）"
# jq を起動する前に非該当を落とす前置フィルタは純粋な短絡で、削っても後段が同じ判定を
# 持つため**振る舞いでは検出できない**（実測: 3 か所どれを削っても suite は緑のまま）。
# 構造上そうなるので、位置と中身を静的に固定する。
prefilter_line="$(grep -n 'case "\$input" in' "$TARGET" | head -1 | cut -d: -f1)"
jq_line="$(grep -n 'command -v jq' "$TARGET" | head -1 | cut -d: -f1)"
if [ -n "$prefilter_line" ] && [ -n "$jq_line" ] && [ "$prefilter_line" -lt "$jq_line" ]; then
  ok "前置フィルタ（\$input の case）が command -v jq より前に在る"
  pre_block="$(sed -n "${prefilter_line},$((jq_line - 1))p" "$TARGET")"
  case "$pre_block" in
    *'*issue*)'*) ok "前置フィルタが issue の共起を見ている" ;;
    *) bad "前置フィルタに *issue*) の分岐が無い" ;;
  esac
  case "$pre_block" in
    *'*create*)'*) ok "前置フィルタが create の共起を見ている" ;;
    *) bad "前置フィルタに *create*) の分岐が無い" ;;
  esac
else
  bad "前置フィルタの位置を確認できません（case: ${prefilter_line:-なし} / jq: ${jq_line:-なし}）"
fi

echo "guard-issue-labels: hooks.json 登録の静的照合"
if jq -e '.hooks.PreToolUse[] | select(.matcher == "Bash") | .hooks[]
    | select(.command | contains("guard-issue-labels.sh"))' "$HOOKS_JSON" >/dev/null 2>&1; then
  ok "hooks.json の PreToolUse（Bash matcher）に登録されている"
else
  bad "hooks.json の PreToolUse（Bash matcher）に guard-issue-labels.sh が無い"
fi
guard_timeout="$(jq -r '.hooks.PreToolUse[] | select(.matcher == "Bash") | .hooks[]
  | select(.command | contains("guard-issue-labels.sh")) | .timeout // empty' "$HOOKS_JSON" 2>/dev/null || true)"
peer_timeouts="$(jq -r '.hooks.PreToolUse[] | select(.matcher == "Bash") | .hooks[]
  | select(.command | contains("guard-issue-labels.sh") | not) | .timeout // empty' "$HOOKS_JSON" 2>/dev/null | sort -u || true)"
if [ -n "$guard_timeout" ] && [ "$peer_timeouts" = "$guard_timeout" ]; then
  ok "既存の Bash ガードと同じ timeout 契約（${guard_timeout} 秒）で登録されている"
else
  bad "timeout が既存の Bash ガードと揃っていません（本 hook: ${guard_timeout:-なし} / 既存: ${peer_timeouts:-なし}）"
fi

echo "guard-issue-labels: ASDD ゲートの早期終了経路でも stdin を読み切る"
# 任意 Hook を止めるゲート（hooks/asdd-hook-gate.sh）は stdin を消費しない設計なので、
# 前置きが drain より前にあると「読まずに exit 0」する経路ができ、書き手がその場で
# EPIPE / SIGPIPE を受ける。ゲートが停止する 2 経路を fixture で作って固定する。
ASDD_ON="$TEST_TMP/asdd-hooks-on"
ASDD_OFF="$TEST_TMP/asdd-hooks-off"
mkdir -p "$ASDD_ON" "$ASDD_OFF"
ff_asdd_fixture "$ASDD_ON" true
ff_asdd_fixture "$ASDD_OFF" false
ASDD_PAYLOAD="$(ff_asdd_big_payload '{"tool_name":"Bash","tool_input":{"command":"echo ok"},"cwd":"/tmp","hook_event_name":"PreToolUse"}')"
ff_asdd_drain_probe "$TARGET" "$ASDD_PAYLOAD" "$ASDD_ON" PATH=/nonexistent
if [ "$FF_ASDD_DRAIN_RC" -eq 0 ] && [ -z "$FF_ASDD_DRAIN_OUT" ]; then
  ok ".asdd 設定あり + node 不在（ゲートが停止）でも stdin を読み切ってから無出力 exit 0"
else
  bad "ASDD ゲート（node 不在）の drain: exit=$FF_ASDD_DRAIN_RC out=[$FF_ASDD_DRAIN_OUT]（非 0 なら前置きが drain より前にある）"
fi
if command -v node >/dev/null 2>&1; then
  ff_asdd_drain_probe "$TARGET" "$ASDD_PAYLOAD" "$ASDD_OFF"
  if [ "$FF_ASDD_DRAIN_RC" -eq 0 ] && [ -z "$FF_ASDD_DRAIN_OUT" ]; then
    ok "features.hooks=false（ゲートが無効と判定）でも stdin を読み切ってから無出力 exit 0"
  else
    bad "ASDD ゲート（feature 無効）の drain: exit=$FF_ASDD_DRAIN_RC out=[$FF_ASDD_DRAIN_OUT]（非 0 なら前置きが drain より前にある）"
  fi
else
  echo "  ○ skip: node が無いため features.hooks=false 経路は未検査（guard-issue-labels の ASDD ゲート無効判定）"
fi

echo
if [ "$FAIL" -gt 0 ]; then
  echo "✗ guard-issue-labels: ${FAIL} 件失敗（成功 ${PASS} 件）" >&2
  REACHED_END=1
  exit 1
fi
echo "✅ guard-issue-labels: all ${PASS} checks passed"
REACHED_END=1
exit 0
