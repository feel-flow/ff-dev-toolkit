#!/usr/bin/env bash
# Runtime contract for the delegated long-gate background guard hook (OBS-036).
#
# 配布物 hooks/guard-long-gate-background.sh を stdin JSON で直接駆動し、受け入れ条件の
# 各分岐を固定する:
#   1. 子（agent_type あり）+ 長時間ゲート + run_in_background: true → deny
#   2. 子 + 長時間ゲート + timeout 未指定 → deny（ハーネスの自動 background 化の検出）
#   3. 子 + 長時間ゲート + timeout が要求値未満 → deny
#   4. 子 + 長時間ゲート + timeout >= 要求値 → 素通し
#   5. **親（agent_type がキーごと不在）は run_in_background でも素通し**
#      （意図的な background 運用 OBS-194 を壊さないための非適用。ここが誤検知の代償を
#        決める分岐なので、ガードの中で最も重要な 1 本）
#   6. 名簿外のコマンド（git status）と、前置フィルタで落ちるコマンド（依存インストール）
#      は素通し（どちらの経路で落ちているかはラベルで区別する）
#   7. ゲート名を引数として触るだけの操作（echo / grep / git add / git diff /
#      chmod / bash -n）では発火しない
#   8. 案内された抜け道（FF_LONG_GATE_BACKGROUND_ACK=1 の前置 / skip env）で通る
#   9. deny 文面が foreground 再実行・要求 timeout 値・ACK 抜け道を案内する
#  10. 発火と抜け道通過が TMPDIR 配下の session_id 別ログへ追記される
#      （「対策後の発生回数 0」を数える土台。数える手段の無い 0 は主張できない）
#  11. ログの置き場がリポジトリの外である（リポジトリ root へ書くと作業ツリーが
#      dirty になり、レビュー用サブエージェント起動時の dirty 判定を誤発火させる）
#  12. セグメント分割の正例（&& の 2 本目 / 環境代入の前置）と、判定の前処理
#      （ラッパ前置・シェルキーワード・クォート付きトークン・session_id の
#      サニタイズ・TMPDIR の末尾スラッシュ）
#  13. 「既知の限界」のうち **A-1（agent_type 不在）/ A-3（heredoc 本文）/ B-1
#      （timeout を載せない版）** が記述どおりであること。一覧 11 件すべてではない —
#      残りに針は無いので、この項目で「限界の記述は全部固定されている」と読まないこと
#      （記述と実装が逆になる事故を 1 度起こしている。針の在る範囲を過大に宣言すると
#      同じ事故を宣言の側で繰り返す）
#
# 変異検出（2026-09-16 実測。SURVIVED は無し）。**赤転先の列挙は代表であって網羅では
# ない** — 検査を後から足したときに列挙だけが古くなる事故を避けるため、どの記録にも
# 「ほか」を付けて非網羅であることを明示する:
#   M1  hooks.json から登録を外すと (10a) (10b) ほかが赤になる。
#   M2  サブエージェント限定の配線を外すと (3a)〜(3d) ほかが赤になる。**2 段の効き方は
#       非対称**（2026-09-16 実測。当初「片方だけ外せばもう片方が肩代わりして緑のまま」と
#       書いていたが、本判定方向では成立しない）:
#         - 本判定 `[ -n "$agent_type" ] || exit 0` **だけ**を外す → (3d) が赤になる
#           （`agent_type` キーは在るが空、という版は前置フィルタを通過するため）
#         - 前置フィルタ **だけ**を外す → 全緑のまま（親のペイロードは `agent_type` キー
#           ごと不在なので、本判定が拾う）
#       したがって本判定は冗長ではない。消すと `agent_type` を空で載せるハーネス版で
#       親の呼び出しが deny され、OBS-194 の退行になる。
#   M3  run_in_background 判定を落とすと (1c) ほかが赤になる。timeout 側のトリガが肩代わりするため、
#       「timeout を満たしていても background は独立に誤り」を測る (1c) だけが検出できる。
#   M4  timeout 未指定 / 要求値未満の判定を落とすと (2a) (2b) (4j) (5b) (8b) (8d) ほかが赤になる。
#   M5  発火の記録を no-op にすると (8a) (9a) ほかが赤になる。
#   M6  （欠番）無害な先頭語の allowlist は削除した。名簿を位置で絞った後は 1 件も
#       追加で落とさない死にコードで、外しても全緑のまま = 誰も守っていなかった。
#   M7  ACK 抜け道の判定を外すと (6a) (8b) (8c) ほかが赤になる。
#   M8  ログ置き場をリポジトリ配下へ移すと (8a) (9a) ほかが赤になる。
#   M9  名簿から run-all.sh を落とすと (4j) (8b) (8d) ほかが赤になる（名簿はこれ 1 件だけ）。
#   M10 deny ではなく systemMessage で返すと assert_deny が全滅する（(1a)〜(1c) (2a) (2b)
#       (4j) (5a) (5b) (6b) (7) (9a) ほか）。エージェントへ届かない経路への退行を、出力
#       チャネルの形で固定している。
#   M11 run-all.sh の判定を位置無制限マッチへ戻すと (4c) (4d) (4f)〜(4i) (4L-3) ほかが赤になる。
#   M12 `bash -n`（実行しない）の除外を落とすと (4h) ほかが赤になる。
#   M13 シェル経由の解決（`bash <path>/run-all.sh`）を落とすと (1a) (1b) (2a) (2b) (5a) (5b)
#       (5b-1)〜(5b-3) ほかが赤になる。
#   M15 heredoc 本文の除去を no-op にする（`code_only="$cmd"`）と (4L-4) ほかが赤になる。
#       **分割の入力だけを `$cmd` へ戻す変異は緑のまま**だった — 前置フィルタも
#       `code_only` を見ているため、そちらが先に落とす。除去は **3 箇所**で効いている
#       （前置フィルタ / 分割の入力 / QUOTED 判定の入力）。3 つ目は当初 `$cmd` を見て
#       おり、heredoc 本文の引用符 1 文字で deny が素通しへ反転していた（(4L-4b) が針）。
#   M16 クォート未閉鎖セグメントの破棄を落とすと (4L-1) (4L-2) ほかが赤になる。
#   M17 「引用符を含むコマンドは最初のセグメントだけを見る」規則を外すと
#       (4L-5)〜(4L-7) ほかが赤になる（誤検知クラスの 4 回目を閉じている規則）。
#   MA  env / command / sudo / nohup の前置スキップを外すと (5b-1) ほかが赤になる。
#   MB  strip_quotes を no-op 化すると (5b-3) ほかが赤になる。
#   MC  session_id のパス区切りサニタイズを外すと (5b-4) ほかが赤になる。
#   MD  TMPDIR の末尾スラッシュ除去を外すと (5b-5) ほかが赤になる。
#   ME  シェルキーワードのスキップを外すと (5b-2) ほかが赤になる。
#   MF  ack の記録をトリガ判定より前へ戻すと (8c) (8d) ほかが赤になる。
#   MG  QUOTED の判定入力を heredoc 除去**前**の `$cmd` へ戻すと (4L-4b) ほかが赤になる
#       （heredoc 本文の引用符 1 文字で deny が素通しへ反転していた穴）。
#   MH  （検出不能と判明）名簿へ依存インストールを戻す変異は**全緑のまま**だった。
#       前置フィルタが 3 段（生の $input / heredoc 除去後の $code_only / セグメント
#       単位）とも `run-all.sh` の綴りで絞っているため、依存インストールのセグメントは
#       名簿判定へ構造的に到達しない。
#       「名簿外であること」を hook の外から測る経路は存在しないので、検査を足すのでは
#       なくラベルを実体へ直した（(4a) (4e) (4k) は前置フィルタを測っている）。
#   MJ  deny 文面の ACK 案内を「元のコマンドの先頭」へ戻すと (6f) ほかが赤になる
#       （判定はセグメントごとなので、その置き方では効かない）。
#   MI  ACK 成立時の綴りの確保を外し、走査後の `MATCH_LABEL` を読むと (8c) (8d) ほかが
#       赤になる（ACK の後ろにセグメントが続くと ack の記録が静かに落ちていた穴）。
#
#
# あわせて hooks.json の PreToolUse（Bash matcher）登録を静的照合する。登録が外れると
# hook 本体が健在でも防御はゼロになるため、本体の挙動とは別に針を張る。
#
# ※ 判別材料の一次情報（claude 2.1.270 / 2026-09-16 実測）: 親の Bash PreToolUse には
#   `agent_id` / `agent_type` がキーごと無く、子には在る。`session_id` / `transcript_path`
#   は親子で同一。fixture の形はこの実測を写している。
#
# 一時領域を使うが git は要らない。
#
# 使い方: bash plugins/ff-dev-toolkit/tests/guard-long-gate-background/verify.sh
#
# run-all-required: no — jq 不在での skip を許容する（一時領域依存 suite の必須判断で名簿へ載せなかった側。既存の Bash ガード suite と同じ扱い）

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TARGET="$PLUGIN_ROOT/hooks/guard-long-gate-background.sh"
HOOKS_JSON="$PLUGIN_ROOT/hooks/hooks.json"

[ -f "$TARGET" ] || { echo "✗ guard-long-gate-background.sh が見つかりません: $TARGET" >&2; exit 1; }
[ -f "$HOOKS_JSON" ] || { echo "✗ hooks.json が見つかりません: $HOOKS_JSON" >&2; exit 1; }
if ! command -v jq >/dev/null 2>&1; then
  echo "○ skip: jq が見つからないためスキップ（guard-long-gate-background は未検査のままです）"
  exit 0
fi

if _ff_mktemp_out="$(mktemp -d "${TMPDIR:-/tmp}/ff-guard-longgate.XXXXXX" 2>&1)" && [ -d "$_ff_mktemp_out" ]; then
  TEST_TMP="$_ff_mktemp_out"
else
  echo "✗ 一時ディレクトリを作成できません: $_ff_mktemp_out" >&2
  exit 1
fi
REACHED_END=0
cleanup() {
  local rc=$?
  rm -rf "$TEST_TMP"
  if [ "$REACHED_END" -ne 1 ] && [ "$rc" -eq 0 ]; then
    echo "✗ guard-long-gate-background: 最後まで到達しませんでした" >&2
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

OUT=""
RC=0
DECISION=""
REASON=""

# ログ置き場を suite 専用へ隔離する（利用者の実ログを汚さず、件数も測れる）。
LOG_HOME="$TEST_TMP/tmp"
mkdir -p "$LOG_HOME"
LOG_DIR="$LOG_HOME/ff-dev-toolkit-delegation-guard"

# <command> <agent_type|""> <bg:true|false> <timeout|""> [session_id]
payload() {
  jq -n --arg c "$1" --arg at "$2" --arg bg "$3" --arg to "$4" --arg sid "${5:-sess-1}" \
    '{tool_name: "Bash", hook_event_name: "PreToolUse", session_id: $sid, cwd: "/tmp",
      tool_input: ({command: $c}
        + (if $bg == "true" then {run_in_background: true} else {} end)
        + (if $to == "" then {} else {timeout: ($to | tonumber)} end))}
     + (if $at == "" then {} else {agent_type: $at, agent_id: "agent-x"} end)'
}

# `agent_type` キーは在るが値が空のハーネス版（前置フィルタは素通ししてしまうので、
# 本判定側の非適用を測るのはこちらの形）。
payload_blank_agent_type() { # <command>
  jq -n --arg c "$1" \
    '{tool_name: "Bash", hook_event_name: "PreToolUse", session_id: "sess-1", cwd: "/tmp",
      agent_type: "", agent_id: "",
      tool_input: {command: $c, run_in_background: true}}'
}

# heredoc 本文へゲートのコマンドを書いた呼び出し（本文はデータであって実行される
# コマンドではない）。終端行の直後に実コマンドを置き、本文だけが落ちることも測る。
payload_heredoc() {
  jq -n --arg c 'cat > note.md <<EOF
手順:
  bash plugins/ff-dev-toolkit/tests/run-all.sh
EOF
git status --short' \
    '{tool_name: "Bash", hook_event_name: "PreToolUse", session_id: "sess-1", cwd: "/tmp",
      agent_type: "general-purpose", agent_id: "agent-x",
      tool_input: {command: $c}}'
}

# サブエージェントが検証報告を PR / Issue 本文へ書く形。クォート引数が複数行に
# またがり、ゲートのコマンドが**中間行**に来る（誤 deny の実測形）。
payload_multiline_body() {
  jq -n --arg c 'gh pr comment 1681 --body "検証結果:

bash plugins/ff-dev-toolkit/tests/run-all.sh → 全 green。

以上"' \
    '{tool_name: "Bash", hook_event_name: "PreToolUse", session_id: "sess-1", cwd: "/tmp",
      agent_type: "general-purpose", agent_id: "agent-x",
      tool_input: {command: $c}}'
}

# heredoc 本文（引用符入り）を落としたうえで、終端行の後ろにある実ゲートを見る形。
payload_heredoc_then_gate() {
  jq -n --arg c 'cat > note.md <<EOF
"メモ": 全件ゲートを回す
EOF
bash plugins/ff-dev-toolkit/tests/run-all.sh' \
    '{tool_name: "Bash", hook_event_name: "PreToolUse", session_id: "sess-1", cwd: "/tmp",
      agent_type: "general-purpose", agent_id: "agent-x",
      tool_input: {command: $c}}'
}

run_hook() { # <payload-json> [extra env NAME=VALUE ...]
  local json="$1"; shift
  OUT=""; RC=0; DECISION=""; REASON=""
  set +e
  OUT="$(printf '%s' "$json" | env TMPDIR="$LOG_HOME" "$@" bash "$TARGET" 2>/dev/null)"
  RC=$?
  set -e
  DECISION="$(printf '%s' "$OUT" | jq -r '.hookSpecificOutput.permissionDecision // empty' 2>/dev/null || true)"
  REASON="$(printf '%s' "$OUT" | jq -r '.hookSpecificOutput.permissionDecisionReason // empty' 2>/dev/null || true)"
}

assert_deny() { if [ "$RC" -eq 0 ] && [ "$DECISION" = "deny" ]; then ok "$1"; else bad "$1: exit=$RC decision=[$DECISION] out=[$OUT]"; fi; }
assert_silent() { if [ "$RC" -eq 0 ] && [ -z "$OUT" ]; then ok "$1"; else bad "$1: exit=$RC out=[$OUT]"; fi; }

GATE='bash plugins/ff-dev-toolkit/tests/run-all.sh'

echo "guard-long-gate-background: (1) 委譲先の background 起動を止める"
run_hook "$(payload "$GATE" general-purpose true "")"
assert_deny "(1a) 子 + run-all.sh + run_in_background:true は deny"
run_hook "$(payload 'bash /abs/path/to/tests/run-all.sh' general-purpose true "")"
assert_deny "(1b) 子 + 絶対パスの run-all.sh + run_in_background:true は deny"
# timeout を満たしていても background 起動は独立に誤り。この 1 本が無いと、
# run_in_background 判定を落とす変異を timeout 側のトリガが肩代わりして緑のままになる
# （変異注入で実測: 2026-09-16）。
run_hook "$(payload "$GATE" general-purpose true 600000)"
assert_deny "(1c) 子 + run_in_background:true は timeout=600000 でも deny"

echo "guard-long-gate-background: (2) timeout 側の発火（ハーネスの自動 background 化）"
run_hook "$(payload "$GATE" general-purpose false "")"
assert_deny "(2a) 子 + timeout 未指定は deny"
run_hook "$(payload "$GATE" general-purpose false 300000)"
assert_deny "(2b) 子 + timeout が要求値未満は deny"
run_hook "$(payload "$GATE" general-purpose false 600000)"
assert_silent "(2c) 子 + timeout=600000（要求値ちょうど）は素通し"
run_hook "$(payload "$GATE" general-purpose false 900000)"
assert_silent "(2d) 子 + timeout が要求値超は素通し"
run_hook "$(payload "$GATE" general-purpose false 300000)" FF_LONG_GATE_FOREGROUND_TIMEOUT_MS=120000
assert_silent "(2e) 要求値を env で下げると同じ timeout が素通しになる"

echo "guard-long-gate-background: (3) 親の呼び出しは構造的に対象外（OBS-194 を壊さない）"
run_hook "$(payload "$GATE" "" true "")"
assert_silent "(3a) 親（agent_type 不在）+ run_in_background:true は素通し"
run_hook "$(payload "$GATE" "" false "")"
assert_silent "(3b) 親（agent_type 不在）+ timeout 未指定は素通し"
run_hook "$(payload './plugins/ff-dev-toolkit/tests/run-all.sh' "" true "")"
assert_silent "(3c) 親 + 直接実行 + background も素通し"
# agent_type のキーはあるが空文字（載せるが値を持たないハーネス版）も親と同じ扱い。
# 前置フィルタは素通ししてしまうので、この 1 本が本判定側の針になる。
run_hook "$(payload_blank_agent_type "$GATE")"
assert_silent "(3d) agent_type が空文字の版も素通し（判定材料が無いので fail-open）"

echo "guard-long-gate-background: (4) 名簿外・無害な先頭語では発火しない"
# 依存インストールは名簿から外してある。誤検知（無害コマンドの deny）の実測された
# 面がすべて自然文へ紛れ込んだ install 名だったため、面ごと落とす判断を測る。
#
# (4a) (4e) (4k) が落ちるのは**前置フィルタ**（入力に `run-all.sh` の綴りが無ければ
# jq より前に exit 0）であって、名簿判定ではない。ラベルでそこを区別する — 「名簿外で
# あること」を測っているつもりでラベルだけがカバレッジを主張する状態にしない。
# 名簿判定まで到達したうえで当たらないことは (4a-2) (4e-2) が測る。
run_hook "$(payload 'npm ci --prefix plugins/ff-dev-toolkit/mcp' general-purpose true "")"
assert_silent "(4a) npm ci は前置フィルタで落ちる（run-all.sh の綴りを含まない）"
run_hook "$(payload 'git status --short' general-purpose true "")"
assert_silent "(4b) 短いコマンドは素通し"
run_hook "$(payload 'echo run-all.sh' general-purpose true "")"
assert_silent "(4c) echo の引数に現れるゲート名では発火しない"
run_hook "$(payload 'grep -rn run-all.sh docs' general-purpose true "")"
assert_silent "(4d) grep の引数に現れるゲート名では発火しない"
run_hook "$(payload 'pnpm install' general-purpose true "")"
assert_silent "(4e) pnpm install も前置フィルタで落ちる"
# 前置フィルタは 3 段ある（生の $input / heredoc 除去後の $code_only / セグメント単位）。
# **いずれも `run-all.sh` の綴りで絞っている**ため、依存インストールのセグメントは
# 名簿判定に構造的に到達しない。
# つまり「名簿外であること」を hook の外から測る経路は存在しない — 変異注入で実測
# （名簿へ npm を戻しても全緑のまま。2026-09-16）。以下の 2 本が測るのは
# 「入力全体のフィルタを通過しても、セグメント単位のフィルタで落ちる」ことであって、
# 名簿の内容ではない。名簿を拡張するときは**両方のフィルタ**を同時に広げる必要がある
# （hook 側にも同じ注意を置いた）。
run_hook "$(payload 'echo plugins/ff-dev-toolkit/tests/run-all.sh && npm ci' general-purpose true "")"
assert_silent "(4a-2) 入力全体のフィルタを通過しても npm ci のセグメントは落ちる"
run_hook "$(payload 'echo plugins/ff-dev-toolkit/tests/run-all.sh && pnpm install' general-purpose true "")"
assert_silent "(4e-2) 同上（pnpm install）"
# ゲート名を「実行」せず「引数として触る」だけの呼び出し。allowlist の内側
# （echo / grep）だけを負例にしていると、allowlist の外にあるこれらが全ゲート緑の
# まま deny される（クロスモデルレビューが 2 CLI 独立で検出。2026-09-16）。
# 名簿を位置で絞る判断を測るのはこの 4 本で、allowlist の拡張では代替できない。
run_hook "$(payload 'git add plugins/ff-dev-toolkit/tests/run-all.sh' general-purpose false "")"
assert_silent "(4f) git add の引数に現れるゲート名では発火しない"
run_hook "$(payload 'git diff -- plugins/ff-dev-toolkit/tests/run-all.sh' general-purpose false "")"
assert_silent "(4g) git diff の pathspec でも発火しない"
run_hook "$(payload 'bash -n plugins/ff-dev-toolkit/tests/run-all.sh' general-purpose false "")"
assert_silent "(4h) bash -n（構文検査。実行しない）では発火しない"
run_hook "$(payload 'chmod +x plugins/ff-dev-toolkit/tests/run-all.sh' general-purpose false "")"
assert_silent "(4i) chmod の引数に現れるゲート名では発火しない"
# 位置で絞っても、実行される形は取りこぼさない
run_hook "$(payload './plugins/ff-dev-toolkit/tests/run-all.sh' general-purpose false "")"
assert_deny "(4j) スクリプトを直接実行する形は deny"
run_hook "$(payload 'yarn install' general-purpose true "")"
assert_silent "(4k) yarn install も前置フィルタで落ちる"

echo "guard-long-gate-background: (4L) クォート・heredoc の中のゲート名では発火しない"
# セグメント分割は区切り記号をクォートの内側でも割るため、文字列の一部が実コマンドに
# 見える。ヘッダの「既知の限界」はこの 2 形を素通しすると宣言しており、その宣言が
# 実装と一致していることをここで測る（宣言だけがあって実装が逆、という状態を許さない）。
# 2 巡目のクロスモデルレビューが実測した誤 deny がこれで、1 巡目と同じクラスの
# 2 回目にあたる（原因の層が違う: 1 巡目はセグメント内のトークン位置、こちらは
# セグメント境界の引き方）。
run_hook "$(payload 'git commit -m "手順を直す; bash tests/run-all.sh が要る"' general-purpose false "")"
assert_silent "(4L-1) コミットメッセージ内のゲートのコマンドでは発火しない"
run_hook "$(payload 'echo "A && bash tests/run-all.sh B"' general-purpose false "")"
assert_silent "(4L-2) 二重引用符の中のゲートのコマンドでは発火しない"
run_hook "$(payload 'gh pr comment 1 --body "手順: bash plugins/ff-dev-toolkit/tests/run-all.sh を実行"' general-purpose false "")"
assert_silent "(4L-3) PR コメント本文に書いたゲートのコマンドでは発火しない"
run_hook "$(payload_heredoc)"
assert_silent "(4L-4) heredoc 本文に書いたゲートのコマンドでは発火しない"
# 対になる正例: heredoc 本文は落として、終端行の**後ろ**にある実ゲートは捕まえる。
# 本文に引用符を含める形にして、本文の中身が「引用符を含むコマンドは最初のセグメント
# だけを見る」規則へ漏れないことも同時に測る（漏れると deny が素通しへ反転する）。
run_hook "$(payload_heredoc_then_gate)"
assert_deny "(4L-4b) heredoc 終端後の実ゲートは、本文に引用符があっても捕まえる"
# 「引用符を含むコマンドは最初のセグメントだけを見る」規則が閉じる形。いずれも
# クロスモデルレビューが実測した誤 deny で、分割と未閉鎖判定が**行単位**で動くことに
# 起因していた（複数行クォート引数の中間行は区切りも引用符も含まないため balanced と
# 判定されて残り、ゲートの実行に見えた）。誤検知クラスの 4 回目にあたる。
run_hook "$(payload 'git commit -m "a; bash tests/run-all.sh; b"' general-purpose false "")"
assert_silent "(4L-5) 引用符内の区切り 2 個でも発火しない"
run_hook "$(payload_multiline_body)"
assert_silent "(4L-6) 複数行の --body に書いたゲートのコマンドでは発火しない"
run_hook "$(payload "sed -i.bak 's|bash tests/run-all.sh|bash tests/run-all.sh --fast|' README.md" general-purpose false "")"
assert_silent "(4L-7) sed の s|A|B| イディオム（区切り 3 個）でも発火しない"

echo "guard-long-gate-background: (5) セグメント分割（コマンド位置を 1 本目に限定しない）"
run_hook "$(payload "cd /repo && $GATE" general-purpose true "")"
assert_deny "(5a) && の 2 本目のゲートも捕まえる"
run_hook "$(payload 'FF_RUN_ALL_FULL=1 bash tests/run-all.sh' general-purpose false "")"
assert_deny "(5b) 環境代入を前置したゲートも捕まえる"

echo "guard-long-gate-background: (5b) 判定の前処理（変異が生き残っていた分岐）"
# 以下 5 本は、レビューが「変異を入れても全緑のまま」と実測した分岐を塞ぐもの。
# いずれも死にコードではなく、suite が到達していない入力で挙動が変わる。
run_hook "$(payload 'env FOO=1 bash plugins/ff-dev-toolkit/tests/run-all.sh' general-purpose false "")"
assert_deny "(5b-1) env ラッパ経由でも捕まえる（前置スキップ）"
run_hook "$(payload 'time bash plugins/ff-dev-toolkit/tests/run-all.sh' general-purpose false "")"
assert_deny "(5b-2) シェルキーワード time の後ろでも捕まえる"
run_hook "$(payload "bash 'plugins/ff-dev-toolkit/tests/run-all.sh'" general-purpose false "")"
assert_deny "(5b-3) クォート付きトークンでも捕まえる（strip_quotes）"
# session_id にパス区切りが混ざる回でも、ログはディレクトリを脱出しない
LOG_ESCAPE_DIR="$LOG_HOME/escaped"
rm -rf "$LOG_ESCAPE_DIR" "$LOG_DIR"
run_hook "$(payload "$GATE" general-purpose true "" '../escaped/pwned')"
if [ -e "$LOG_ESCAPE_DIR/pwned.log" ]; then
  bad "(5b-4) session_id のパス区切りでログがディレクトリを脱出した: $LOG_ESCAPE_DIR/pwned.log"
elif [ -f "$LOG_DIR/unknown-session.log" ]; then
  ok "(5b-4) session_id にパス区切りがある回は unknown-session.log へ落とす"
else
  bad "(5b-4) session_id のサニタイズ結果が期待と違う: $(ls -1 "$LOG_DIR" 2>/dev/null | tr '\n' ' ')"
fi
# TMPDIR が末尾スラッシュ付きでも、案内するパスに二重スラッシュを作らない
run_hook "$(payload "$GATE" general-purpose true "")" TMPDIR="$LOG_HOME/"
case "$REASON" in
  *//ff-dev-toolkit-delegation-guard*) bad "(5b-5) 記録先のパスに二重スラッシュが出た: [$REASON]" ;;
  *ff-dev-toolkit-delegation-guard*) ok "(5b-5) TMPDIR の末尾スラッシュを落として案内する" ;;
  *) bad "(5b-5) 記録先が案内されていません: [$REASON]" ;;
esac

echo "guard-long-gate-background: (6) 抜け道が実際に通る"
run_hook "$(payload "FF_LONG_GATE_BACKGROUND_ACK=1 $GATE" general-purpose true "")"
assert_silent "(6a) コマンド位置の FF_LONG_GATE_BACKGROUND_ACK=1 で素通し"
run_hook "$(payload "echo FF_LONG_GATE_BACKGROUND_ACK=1 && $GATE" general-purpose true "")"
assert_deny "(6b) 文字列として現れるだけの ACK では素通ししない"
# 判定はセグメントごとなので、ACK がゲートと別のセグメントに在ると効かない。
# deny 本文がこの置き方を主指示にしていると、委譲先は指示どおり直しても同じ deny を
# 受け取り、置き場所が違うという信号を 1 つも得られない（レビューが実測）。
run_hook "$(payload "FF_LONG_GATE_BACKGROUND_ACK=1 cd /repo && $GATE" general-purpose true "")"
assert_deny "(6d) ACK が別セグメントに在ると効かない"
run_hook "$(payload "cd /repo && FF_LONG_GATE_BACKGROUND_ACK=1 $GATE" general-purpose true "")"
assert_silent "(6e) ACK をゲートのセグメントの先頭に置けば効く"
if [ -n "$REASON" ] || { run_hook "$(payload "cd /repo && $GATE" general-purpose true "")"; [ "$DECISION" = "deny" ]; }; then
  case "$REASON" in
    *"ゲートを実行するセグメントの先頭"*) ok "(6f) deny 文面が ACK の置き場所をセグメント単位で案内する" ;;
    *) bad "(6f) deny 文面が「元のコマンドの先頭」のままです（別セグメントでは効かない）: [$REASON]" ;;
  esac
fi
run_hook "$(payload "$GATE" general-purpose true "")" FF_DEV_TOOLKIT_SKIP_LONG_GATE_BACKGROUND_GUARD=1
assert_silent "(6c) skip env でガードごと止まる"

echo "guard-long-gate-background: (7) deny 文面が行動を案内する"
run_hook "$(payload "$GATE" general-purpose true "")"
if [ "$DECISION" = "deny" ]; then
  case "$REASON" in
    *foreground*) ok "(7a) foreground で待つ指示がある" ;;
    *) bad "(7a) deny 文面に foreground の指示がありません: [$REASON]" ;;
  esac
  case "$REASON" in
    *600000*) ok "(7b) 要求 timeout の実値を文面に書いている（参照リンクで代替しない）" ;;
    *) bad "(7b) deny 文面に timeout の実値がありません: [$REASON]" ;;
  esac
  case "$REASON" in
    *FF_LONG_GATE_BACKGROUND_ACK=1*) ok "(7c) ACK 抜け道を案内している" ;;
    *) bad "(7c) deny 文面に ACK 抜け道の案内がありません: [$REASON]" ;;
  esac
  case "$REASON" in
    *FF_DEV_TOOLKIT_SKIP_LONG_GATE_BACKGROUND_GUARD=1*) ok "(7d) skip env を案内している" ;;
    *) bad "(7d) deny 文面に skip env の案内がありません: [$REASON]" ;;
  esac
  case "$REASON" in
    *OBS-036*) ok "(7e) 根拠の観測 ID を名指ししている" ;;
    *) bad "(7e) deny 文面に観測 ID がありません: [$REASON]" ;;
  esac
else
  bad "(7) deny が出ないため文面を検査できません: decision=[$DECISION]"
fi

echo "guard-long-gate-background: (8) 発火の記録（発生回数を数える土台）"
rm -rf "$LOG_DIR"
run_hook "$(payload "$GATE" general-purpose true "" sess-count)"
run_hook "$(payload './plugins/ff-dev-toolkit/tests/run-all.sh' general-purpose false "" sess-count)"
run_hook "$(payload "FF_LONG_GATE_BACKGROUND_ACK=1 $GATE" general-purpose true "" sess-count)"
# ACK 成立の**後ろにセグメントが続く**形。綴りを確保せず走査後の MATCH_LABEL を読むと、
# 後続が当たらないときに空へ潰れて ack の記録が静かに落ちる（実測 2026-09-16）。
# 既存の ACK ケースは単一セグメントなのでこの経路に到達していなかった。
run_hook "$(payload "FF_LONG_GATE_BACKGROUND_ACK=1 $GATE && git add plugins/ff-dev-toolkit/tests/run-all.sh" general-purpose true "" sess-count)"
run_hook "$(payload 'git status' general-purpose true "" sess-count)"
# 抜け道の前置が付いていても、発火条件を 1 つも満たしていない呼び出し（foreground かつ
# timeout 適合）は記録しない。ここを計上すると「対策後の発生回数」の母集団に、抜け道を
# 使っていない回が混ざる（ack の記録をトリガ判定より前へ置くと再発する）。
run_hook "$(payload "FF_LONG_GATE_BACKGROUND_ACK=1 $GATE" general-purpose false 600000 sess-count)"
LOG_FILE="$LOG_DIR/sess-count.log"
if [ -f "$LOG_FILE" ]; then
  ok "(8a) session_id 別のログが作られる"
  DENY_N="$(awk -F'\t' '$2 == "deny"' "$LOG_FILE" | wc -l | tr -d ' ')"
  ACK_N="$(awk -F'\t' '$2 == "ack"' "$LOG_FILE" | wc -l | tr -d ' ')"
  TOTAL_N="$(wc -l < "$LOG_FILE" | tr -d ' ')"
  [ "$DENY_N" = "2" ] && ok "(8b) deny 2 件が記録される" || bad "(8b) deny の記録件数が 2 ではありません: $DENY_N"
  [ "$ACK_N" = "2" ] && ok "(8c) 抜け道通過は後続セグメントの有無によらず記録される（0 件主張の母集団から静かに落ちない）" || bad "(8c) ack の記録件数が 2 ではありません: $ACK_N"
  [ "$TOTAL_N" = "4" ] && ok "(8d) 素通しと適合呼び出しは記録しない（発火だけを数える）" || bad "(8d) 記録の総数が 4 ではありません: $TOTAL_N"
  if awk -F'\t' '$2 == "deny"' "$LOG_FILE" | /usr/bin/grep -q 'agent_id=agent-x'; then
    ok "(8e) どの子が起こしたかを agent_id で辿れる"
  else
    bad "(8e) 記録に agent_id がありません: [$(cat "$LOG_FILE")]"
  fi
else
  bad "(8a) ログが作られていません: $LOG_FILE"
fi

echo "guard-long-gate-background: (9) ログ置き場はリポジトリの外"
run_hook "$(payload "$GATE" general-purpose true "")"
case "$REASON" in
  *"$PLUGIN_ROOT"*|*"$SCRIPT_DIR"*)
    bad "(9a) 記録先がリポジトリ配下です（作業ツリーを dirty にします）: [$REASON]" ;;
  *ff-dev-toolkit-delegation-guard*)
    ok "(9a) 記録先は TMPDIR 配下でリポジトリの外" ;;
  *)
    bad "(9a) deny 文面が記録先を案内していません: [$REASON]" ;;
esac

echo "guard-long-gate-background: (10) hooks.json の登録"
REGISTERED="$(jq -r '[.hooks.PreToolUse[]?.hooks[]?.command // empty]
  | map(select(test("guard-long-gate-background\\.sh"))) | length' "$HOOKS_JSON" 2>/dev/null || echo 0)"
[ "$REGISTERED" = "1" ] && ok "(10a) PreToolUse へ 1 本だけ登録されている" \
  || bad "(10a) hooks.json の登録本数が 1 ではありません: $REGISTERED"
MATCHER_OK="$(jq -r '[.hooks.PreToolUse[]? | select((.matcher // "") | test("Bash"))
  | .hooks[]?.command // empty] | map(select(test("guard-long-gate-background\\.sh"))) | length' "$HOOKS_JSON" 2>/dev/null || echo 0)"
[ "$MATCHER_OK" = "1" ] && ok "(10b) Bash matcher のブロックに載っている" \
  || bad "(10b) Bash matcher のブロックに載っていません: $MATCHER_OK"

echo
if [ "$FAIL" -gt 0 ]; then
  echo "✗ guard-long-gate-background: ${FAIL} 件失敗（成功 ${PASS} 件）" >&2
  REACHED_END=1
  exit 1
fi
echo "✅ guard-long-gate-background: all ${PASS} checks passed"
REACHED_END=1
exit 0
