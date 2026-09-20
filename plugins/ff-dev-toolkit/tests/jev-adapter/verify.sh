#!/usr/bin/env bash
#
# Jev 判定アダプタ（scripts/jev/jev-judge.sh）と offline 評価ハーネス（scripts/jev/jev-eval.sh）
# の契約検査。実網には出ない — PATH の先頭へ偽 `curl` を置き、呼び出しの形（`-K -` で
# 設定を stdin から渡す・argv にキーを載せない・本文はファイル経由）と応答計画（HTTP
# ステータスの列）に対する振る舞いを実測する。
#
# 固定する契約:
#   A. 有効化の二段構え。FF_JEV_ENABLED=1 が無ければキーがあっても通信せず exit 3、
#      有効でもキーが 3 経路のどれにも無ければ通信せず exit 4。どちらも「空を返す」形に
#      しない（判定不能を不一致なしへ倒さない）
#   B. キーは stdout / stderr / argv に出ない。設定は stdin（`-K -`）経由で渡る
#   C. HTTP ステータスの種別を終了コードで名乗る（401→5 / 422→6 / 429・529 疲弊→7 /
#      その他→8 / answers 欠落→9）。429 は Retry-After を優先した上限付きリトライ
#   D. 入力不正（questions が object でない・type 不正・state 空・バイト予算超過）は
#      通信せず exit 2
#   E. ハーネスは全行を先に検証し、空ファイル・空行・読めない行・expected の qid 不在は
#      1 件も送らず exit 2。判定に 1 件でも失敗したら集計せず、その終了コードを伝える。
#      成功時は一致率・質問 id 別・group 別・confidence 帯別・p50/p95・トークン・コストを出す
#   F. 同梱 fixture（日英 Choice probe）は en / ja 各 5 件で、expected が criteria に実在する
#   G. レビューで見つかった「判定不能が成功 / 不一致へ化ける」経路の固定: 応答の qid 欠落・
#      type 不一致・値の型不正は exit 9、キーの不正文字・読めないキーファイルは通信せず exit 4、
#      数値であるべき設定の非数値は exit 64、Retry-After はバックオフより優先し上限で頭打ち、
#      バイト予算は文字数でなくバイトで数える、ハーネスはラベル不正（criteria に無い option・
#      legend に無い文言・noul の非 boolean・null / 数値の state）を通信前に exit 2 で止め、
#      --out へ書けなければ exit 2、低 confidence の不一致は該当帯へ計上される
#   H. ACE 評価セット生成器（scripts/jev/build-ace-eval-sets.ts）は合成 Playbook（6 エントリ・2 版）
#      から期待値まで固定できる形で 3 セットを作る: 正例 = Helpful 行の参照先、負例 = 同カテゴリの
#      別エントリ、recent の近傍は版の日付より前（同日は Origin PR が小さい側）だけで未来のエントリ
#      は出ない、追加候補は全 false、Helpful 候補は参照先だけ true。決定性（バイト同一）。
#      判定不能は exit 2（ラベル欠落・candidates 不在・Playbook に無い候補・数値オプション不正・
#      Changelog 不在 / 見出し drift / 読めない Helpful 行・Date 欠落）。--summarize は評価時の
#      predicted で判定し、id 契約外の行と answers 欠落を拒否する。tsx ランナー（ace-run-ts.sh）が
#      起動できない環境はこの節だけ部分 skip、実 PLAYBOOK が無い配布先は H22 だけ部分 skip
#
# 空振り検出: 同梱 fixture を空ファイルに差し替えると (F1〜F4) の 4 件が赤になる（2026-09-20 実測。52 件中 4 件失敗。0 行を「件数どおり」へ倒さない）。
# 空振り検出: 同梱 fixture から ja 側の 5 行を削ると (F1〜F4) の 4 件が赤になる（2026-09-20 実測。52 件中 4 件失敗。片側の消失を通さない）。
# 空振り検出: jev-eval.sh の空セット検査を無効化すると (E1) が赤になる（2026-09-20 実測。後段の「有効な行なし」検査も exit 2 なので rc では見分けられず、E1 は「評価セットが空です」の文言一致で赤にしている）。
# 空振り検出: 合成 Playbook の Changelog 見出しを別綴りにすると (H14) が「行が 1 件も読めない」を要求して赤になる（2026-09-20 実測。0 件を「セット 0 件で成功」へ倒さない）。
# 空振り検出: 合成 Playbook の Helpful 行を契約外の括弧にすると (H15) が赤になる（2026-09-20 実測。読めない行を黙って落として母集団を縮めない）。
# 空振り検出: 偽 curl の応答計画を空にすると (B1 / C1〜C4 / E7〜E11 / F4 / G 節) が「応答なし = exit 8」側へ倒れて赤になる（2026-09-20 実測。応答が無いのを成功へ倒さない）。
#
# 依存: bash 3.2 / jq / mktemp。一時領域を作れない環境は skip ではなく赤（suite 全体の
# skip 経路を持たない）。実作業ツリーには触れない（HOME・PATH・TMPDIR を隔離する）。
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
JUDGE="$PLUGIN_ROOT/scripts/jev/jev-judge.sh"
EVAL="$PLUGIN_ROOT/scripts/jev/jev-eval.sh"
PROBE="$PLUGIN_ROOT/scripts/jev/fixtures/ja-en-choice-probe.jsonl"

PASS=0
FAIL=0
ok()  { echo "  ✓ $1"; PASS=$((PASS + 1)); }
bad() { echo "  ✗ $1" >&2; FAIL=$((FAIL + 1)); }

command -v jq >/dev/null 2>&1 || { echo "✗ jq がありません（本 suite は jq を要する。skip ではなく赤）" >&2; exit 1; }
for f in "$JUDGE" "$EVAL" "$PROBE"; do
  [ -f "$f" ] || { echo "✗ 対象がありません: $f" >&2; exit 1; }
done

if WORK="$(mktemp -d "${TMPDIR:-/tmp}/jev-adapter.XXXXXX" 2>&1)" && [ -d "$WORK" ]; then
  :
else
  echo "✗ 一時領域を作れません（skip ではなく赤）: ${WORK}" >&2
  exit 1
fi
# 途中死（set -u 等）で $? が 0 のまま抜ける形を rc=0 の pass にしない
FF_REACHED_END=0
_ff_exit_guard() {
  _ff_rc=$?
  rm -rf "$WORK"
  if [ "$_ff_rc" -eq 0 ] && [ "$FF_REACHED_END" -ne 1 ]; then
    echo "✗ jev-adapter: 最後まで到達しませんでした（途中で中断）" >&2
    exit 1
  fi
  exit "$_ff_rc"
}
trap _ff_exit_guard EXIT

# ---- 偽 curl -------------------------------------------------------------------
# 応答計画 $FAKE/plan は 1 行 1 ステータス。先頭行を消費して返す。本文は
# $FAKE/body.<status> があればそれ、無ければ既定の成功応答。`-D <file>` があれば
# ヘッダを書く（plan の行が `429 retry-after=0` の形なら Retry-After を付ける）。
# 呼び出しごとに stdin（設定）と argv を $FAKE/call.<n>.{config,args} へ残す。
FAKE="$WORK/fake"
mkdir -p "$FAKE/bin"
cat > "$FAKE/bin/curl" <<'EOF'
#!/usr/bin/env bash
set -u
FAKE="${FAKE_CURL_DIR:?}"
n=$(( $(ls "$FAKE" | grep -c '^call\.[0-9]*\.args$') + 1 ))
cat > "$FAKE/call.$n.config"
printf '%s\n' "$@" > "$FAKE/call.$n.args"
prev=""
for a in "$@"; do
  if [ "$prev" = "--data-binary" ]; then
    case "$a" in @*) cp "${a#@}" "$FAKE/call.$n.body" 2>/dev/null ;; esac
  fi
  prev="$a"
done
if [ ! -s "$FAKE/plan" ]; then
  echo "fake curl: no planned response" >&2
  exit 7
fi
line="$(head -n 1 "$FAKE/plan")"
tail -n +2 "$FAKE/plan" > "$FAKE/plan.next" && mv "$FAKE/plan.next" "$FAKE/plan"
status="${line%% *}"
extra="${line#* }"
[ "$extra" = "$line" ] && extra=""
hdr=""
prev=""
for a in "$@"; do
  if [ "$prev" = "-D" ]; then hdr="$a"; fi
  prev="$a"
done
if [ -n "$hdr" ]; then
  printf 'HTTP/1.1 %s X\r\n' "$status" > "$hdr"
  case "$extra" in
    retry-after=*) printf 'Retry-After: %s\r\n' "${extra#retry-after=}" >> "$hdr" ;;
  esac
  printf '\r\n' >> "$hdr"
fi
if [ -f "$FAKE/body.$status" ]; then
  cat "$FAKE/body.$status"
else
  printf '%s' '{"model":"jev-1.13.0","answers":{"dept":{"type":"choice","choice":"billing","probabilities":{"billing":0.88,"technical":0.12},"confidence":0.81},"urgent":{"type":"noul","noul":0.95},"level":{"type":"score","score":1.05,"legend":{"0":"Calm","1":"Frustrated","2":"Very angry"},"probabilities":{"0":0.0,"1":0.95,"2":0.05},"confidence":0.92}},"usage":{"input_tokens":300,"output_tokens":20}}'
fi
printf '\n%s' "$status"
exit 0
EOF
chmod +x "$FAKE/bin/curl"
# 偽 sleep: 受け取った秒数を記録して眠らない。Retry-After とバックオフの値を識別するため
cat > "$FAKE/bin/sleep" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$1" >> "${FAKE_CURL_DIR:?}/sleep.log"
exit 0
EOF
chmod +x "$FAKE/bin/sleep"

# 隔離: HOME（既定キーパス）・PATH（偽 curl）・TMPDIR。実 HOME のキーは読ませない。
ISO_HOME="$WORK/home"
mkdir -p "$ISO_HOME"
export FAKE_CURL_DIR="$FAKE"
run_judge() { # 偽 curl 配下で jev-judge.sh を実行。stdout→${OUT}、stderr→${ERR}、rc→${RC}
  OUT="$( env -i HOME="$ISO_HOME" PATH="$FAKE/bin:$PATH" TMPDIR="$WORK" FAKE_CURL_DIR="$FAKE" \
        "$@" bash "$JUDGE" 2>"$WORK/stderr" )"; RC=$?
  ERR="$(cat "$WORK/stderr")"
}
run_judge_args() { # $1..=環境（VAR=val）、-- の後がスクリプト引数
  local envs=()
  while [ $# -gt 0 ] && [ "$1" != "--" ]; do envs+=("$1"); shift; done
  [ "${1:-}" = "--" ] && shift
  OUT="$( env -i HOME="$ISO_HOME" PATH="$FAKE/bin:$PATH" TMPDIR="$WORK" FAKE_CURL_DIR="$FAKE" \
        ${envs[@]+"${envs[@]}"} bash "$JUDGE" "$@" 2>"$WORK/stderr" )"; RC=$?
  ERR="$(cat "$WORK/stderr")"
}
run_eval_args() {
  local envs=()
  while [ $# -gt 0 ] && [ "$1" != "--" ]; do envs+=("$1"); shift; done
  [ "${1:-}" = "--" ] && shift
  OUT="$( env -i HOME="$ISO_HOME" PATH="$FAKE/bin:$PATH" TMPDIR="$WORK" FAKE_CURL_DIR="$FAKE" \
        ${envs[@]+"${envs[@]}"} bash "$EVAL" "$@" 2>"$WORK/stderr" )"; RC=$?
  ERR="$(cat "$WORK/stderr")"
}
reset_fake() { # $1..=応答計画の行
  rm -f "$FAKE"/call.* "$FAKE"/body.* "$FAKE/plan" "$FAKE/sleep.log"
  : > "$FAKE/plan"
  local l
  for l in "$@"; do printf '%s\n' "$l" >> "$FAKE/plan"; done
}
calls() { # 偽 curl の呼び出し回数。$FAKE が消えていたら 0 ではなく 999 を返して「通信なし」判定を空振りさせない
  if [ -d "$FAKE" ]; then ls "$FAKE" | grep -c '^call\.[0-9]*\.args$'; else echo "fake dir missing: $FAKE" >&2; echo 999; fi
}

KEY_FILE="$WORK/key"
FAKE_KEY="fake-key-0123456789abcdef-DO-NOT-LEAK"
printf '%s\n' "$FAKE_KEY" > "$KEY_FILE"
Q="$WORK/questions.json"
cat > "$Q" <<'EOF'
{
  "dept":   { "type": "choice", "instructions": "Which team?", "criteria": { "billing": null, "technical": null } },
  "urgent": { "type": "noul",   "instructions": "Urgent?" },
  "level":  { "type": "score",  "instructions": "How frustrated?", "criteria": ["Calm", "Frustrated", "Very angry"] }
}
EOF
STATE="$WORK/state.txt"
printf '支払いが 3 日間失敗しています\n' > "$STATE"

# ================================================================================
echo "== A. 有効化の二段構え =="
reset_fake 200
run_judge_args TYPESAFE_API_KEY_FILE="$KEY_FILE" -- --questions "$Q" --state-file "$STATE"
if [ "$RC" -eq 3 ] && grep -q '^JEV_ERROR=disabled$' <<<"$OUT" && [ "$(calls)" -eq 0 ]; then
  ok "A1 FF_JEV_ENABLED 未設定はキーがあっても通信せず exit 3（disabled）"
else bad "A1 disabled: rc=$RC calls=$(calls) out=$OUT"; fi

reset_fake 200
run_judge_args FF_JEV_ENABLED=0 TYPESAFE_API_KEY_FILE="$KEY_FILE" -- --questions "$Q" --state-file "$STATE"
[ "$RC" -eq 3 ] && ok "A2 FF_JEV_ENABLED=0 も無効（1 以外は Off）" || bad "A2 rc=$RC"

reset_fake 200
run_judge_args FF_JEV_ENABLED=1 -- --questions "$Q" --state-file "$STATE"
if [ "$RC" -eq 4 ] && grep -q '^JEV_ERROR=key-missing$' <<<"$OUT" && [ "$(calls)" -eq 0 ] \
   && grep -q 'TYPESAFE_API_KEY' <<<"$ERR"; then
  ok "A3 有効でもキーが無ければ通信せず exit 4（key-missing。3 経路を名指し）"
else bad "A3 key-missing: rc=$RC calls=$(calls) err=$ERR"; fi

reset_fake 200
run_judge_args FF_JEV_ENABLED=1 -- --json --check
[ "$RC" -eq 4 ] && ok "A4 --check もキー未設定を exit 4 で名乗る" || bad "A4 rc=$RC"

reset_fake 200
run_judge_args FF_JEV_ENABLED=1 TYPESAFE_API_KEY_FILE="$KEY_FILE" -- --check
if [ "$RC" -eq 0 ] && grep -q '^JEV_CHECK=1$' <<<"$OUT" && [ "$(calls)" -eq 0 ]; then
  ok "A5 --check はキーがあれば通信せずに exit 0"
else bad "A5 check: rc=$RC calls=$(calls)"; fi

# 3 経路それぞれ
reset_fake 200
run_judge_args FF_JEV_ENABLED=1 TYPESAFE_API_KEY="$FAKE_KEY" -- --questions "$Q" --state-file "$STATE"
[ "$RC" -eq 0 ] && ok "A6 キー経路 1: TYPESAFE_API_KEY" || bad "A6 rc=$RC err=$ERR"
reset_fake 200
mkdir -p "$ISO_HOME/.config/ff-dev-toolkit"
printf '%s\n' "$FAKE_KEY" > "$ISO_HOME/.config/ff-dev-toolkit/typesafe_api_key"
run_judge_args FF_JEV_ENABLED=1 -- --questions "$Q" --state-file "$STATE"
[ "$RC" -eq 0 ] && ok "A7 キー経路 3: ~/.config/ff-dev-toolkit/typesafe_api_key" || bad "A7 rc=$RC err=$ERR"
rm -rf "$ISO_HOME/.config"

# ================================================================================
echo "== B. 呼び出しの形とキーの非露出 =="
reset_fake 200
run_judge_args FF_JEV_ENABLED=1 TYPESAFE_API_KEY_FILE="$KEY_FILE" -- --questions "$Q" --state-file "$STATE"
if [ "$RC" -eq 0 ] && grep -q '^JEV_OK=1$' <<<"$OUT"; then
  ok "B1 200 応答で exit 0 / JEV_OK=1"
else bad "B1 rc=$RC out=$OUT err=$ERR"; fi
if grep -qF "$FAKE_KEY" <<<"${OUT}${ERR}"; then
  bad "B2 キーが stdout / stderr に出ている"
else ok "B2 キーは stdout / stderr に出ない"; fi
if grep -qF "$FAKE_KEY" "$FAKE/call.1.args"; then
  bad "B3 キーが curl の argv に載っている"
else ok "B3 キーは curl の argv に載らない"; fi
if grep -q "^header = \"Authorization: Bearer ${FAKE_KEY}\"$" "$FAKE/call.1.config" \
   && grep -qx -- '-K' "$FAKE/call.1.args" && grep -qx -- '-' "$FAKE/call.1.args"; then
  ok "B4 設定は -K - で stdin から渡り、Authorization ヘッダはそこにだけある"
else bad "B4 config/args: $(cat "$FAKE/call.1.config" | sed 's/Bearer .*/Bearer <redacted>/') / $(tr '\n' ' ' < "$FAKE/call.1.args")"; fi
body_arg="$(grep -A1 -x -- '--data-binary' "$FAKE/call.1.args" | tail -n 1)"
if [[ "$body_arg" == @* ]] && jq -e '.model == "jev-latest" and (.questions | keys | length == 3) and (.state | type == "string")' "$FAKE/call.1.body" >/dev/null 2>&1; then
  ok "B5 本文はファイル経由（--data-binary @file）で model / questions / state を持つ"
else bad "B5 body arg: $body_arg"; fi
for k in JEV_MODEL=jev-1.13.0 JEV_INPUT_TOKENS=300 JEV_RETRIES=0 'ANSWER=dept|choice|billing|0.81' 'ANSWER=level|score|1.05|0.92'; do
  grep -qF "$k" <<<"$OUT" && ok "B6 出力行: $k" || bad "B6 出力行が無い: $k / $OUT"
done
if grep -q '^ANSWER=urgent|noul|0.95|0.9$' <<<"$OUT"; then
  ok "B7 noul の confidence は |p-0.5|*2 で派生（0.95 → 0.9）"
else bad "B7 noul confidence: $(printf '%s\n' "$OUT" | grep '^ANSWER=urgent')"; fi
cost="$(printf '%s\n' "$OUT" | sed -n 's/^JEV_COST_USD=//p')"
if [ -n "$cost" ] && jq -en --argjson c "$cost" '($c - 0.0000126 | if . < 0 then -. else . end) < 1e-12' >/dev/null 2>&1; then
  ok "B8 概算コスト = 300 tok × 0.042 / 1e6"
else bad "B8 cost: $(printf '%s\n' "$OUT" | grep '^JEV_COST')"; fi

reset_fake 200
run_judge_args FF_JEV_ENABLED=1 TYPESAFE_API_KEY_FILE="$KEY_FILE" -- --json --questions "$Q" --state-file "$STATE"
if [ "$RC" -eq 0 ] && printf '%s' "$OUT" | jq -e '
     .ok == true and .model == "jev-1.13.0" and (.latency_ms | type == "number")
     and .usage.input_tokens == 300 and .answers.dept.value == "billing"
     and .answers.dept.confidence == 0.81 and .answers.urgent.value == 0.95
     and (.input_bytes | type == "number") and .retries == 0' >/dev/null; then
  ok "B9 --json は 1 行 JSON（ok / model / answers.value / usage / latency_ms / retries / input_bytes）"
else bad "B9 json: rc=$RC out=$OUT"; fi
[ "$(printf '%s\n' "$OUT" | wc -l | tr -d ' ')" -eq 1 ] && ok "B10 --json は 1 行" || bad "B10 行数: $(printf '%s\n' "$OUT" | wc -l)"

# state が JSON object ならそのまま構造で渡す
reset_fake 200
printf '{"finding":"x","diff":"y"}' > "$WORK/state.json"
run_judge_args FF_JEV_ENABLED=1 TYPESAFE_API_KEY_FILE="$KEY_FILE" -- --questions "$Q" --state-file "$WORK/state.json"
body_arg="$(grep -A1 -x -- '--data-binary' "$FAKE/call.1.args" | tail -n 1)"
if [ "$RC" -eq 0 ] && jq -e '.state.finding == "x"' "$FAKE/call.1.body" >/dev/null 2>&1; then
  ok "B11 JSON の state は構造のまま渡る"
else bad "B11 rc=$RC"; fi
# stdin からの state
reset_fake 200
OUT="$( printf 'stdin state\n' | env -i HOME="$ISO_HOME" PATH="$FAKE/bin:$PATH" TMPDIR="$WORK" FAKE_CURL_DIR="$FAKE" \
        FF_JEV_ENABLED=1 TYPESAFE_API_KEY_FILE="$KEY_FILE" bash "$JUDGE" --questions "$Q" 2>/dev/null )"; RC=$?
[ "$RC" -eq 0 ] && ok "B12 state は stdin からも読める" || bad "B12 rc=$RC"

# ================================================================================
echo "== C. HTTP ステータスの種別と再試行 =="
for pair in "401:5:unauthorized" "422:6:unprocessable" "500:8:http-500"; do
  st="${pair%%:*}"; rest="${pair#*:}"; want="${rest%%:*}"; kind="${rest#*:}"
  reset_fake "$st"
  printf '{"error":"boom"}' > "$FAKE/body.$st"
  run_judge_args FF_JEV_ENABLED=1 TYPESAFE_API_KEY_FILE="$KEY_FILE" -- --questions "$Q" --state-file "$STATE"
  if [ "$RC" -eq "$want" ] && grep -q "^JEV_ERROR=${kind}$" <<<"$OUT" && [ "$(calls)" -eq 1 ]; then
    ok "C1 HTTP ${st} → exit ${want}（${kind}、再試行しない）"
  else bad "C1 HTTP $st: rc=$RC calls=$(calls) out=$OUT"; fi
done

reset_fake "429 retry-after=7" "529" "200"
run_judge_args FF_JEV_ENABLED=1 TYPESAFE_API_KEY_FILE="$KEY_FILE" FF_JEV_RETRY_BASE_SECONDS=1 -- --questions "$Q" --state-file "$STATE"
if [ "$RC" -eq 0 ] && grep -q '^JEV_RETRIES=2$' <<<"$OUT" && [ "$(calls)" -eq 3 ] \
   && [ "$(tr '\n' ' ' < "$FAKE/sleep.log")" = "7 2 " ]; then
  ok "C2 429(Retry-After 7) → 529 → 200: 待ちは 7 秒（ヘッダ優先）→ 2 秒（backoff 1<<1）で 2 回再試行して成功"
else bad "C2 retry: rc=$RC calls=$(calls) sleeps=$(tr '\n' ' ' < "$FAKE/sleep.log" 2>/dev/null) out=$OUT err=$ERR"; fi
reset_fake 429 429 429 200
run_judge_args FF_JEV_ENABLED=1 TYPESAFE_API_KEY_FILE="$KEY_FILE" FF_JEV_RETRY_BASE_SECONDS=1 -- --questions "$Q" --state-file "$STATE"
if [ "$RC" -eq 0 ] && [ "$(tr '\n' ' ' < "$FAKE/sleep.log")" = "1 2 4 " ]; then
  ok "C2b ヘッダ無しの連続 429 は 1, 2, 4 秒の指数バックオフ"
else bad "C2b sleeps=$(tr '\n' ' ' < "$FAKE/sleep.log" 2>/dev/null) rc=$RC"; fi
reset_fake "429 retry-after=999" 200
run_judge_args FF_JEV_ENABLED=1 TYPESAFE_API_KEY_FILE="$KEY_FILE" FF_JEV_MAX_RETRY_AFTER_SECONDS=5 -- --questions "$Q" --state-file "$STATE"
if [ "$RC" -eq 0 ] && [ "$(tr '\n' ' ' < "$FAKE/sleep.log")" = "5 " ]; then
  ok "C2c Retry-After 999 は FF_JEV_MAX_RETRY_AFTER_SECONDS=5 で頭打ち"
else bad "C2c sleeps=$(tr '\n' ' ' < "$FAKE/sleep.log" 2>/dev/null) rc=$RC"; fi

reset_fake 429 429 429 429 429 429 429
run_judge_args FF_JEV_ENABLED=1 TYPESAFE_API_KEY_FILE="$KEY_FILE" FF_JEV_RETRY_BASE_SECONDS=0 FF_JEV_MAX_RETRIES=2 -- --questions "$Q" --state-file "$STATE"
if [ "$RC" -eq 7 ] && grep -q '^JEV_ERROR=rate-limited$' <<<"$OUT" && [ "$(calls)" -eq 3 ]; then
  ok "C3 429 が続けば上限（FF_JEV_MAX_RETRIES=2 → 3 回呼んで）exit 7"
else bad "C3 exhaust: rc=$RC calls=$(calls) out=$OUT"; fi

reset_fake 200
printf '{"model":"jev-1.13.0","usage":{"input_tokens":1}}' > "$FAKE/body.200"
run_judge_args FF_JEV_ENABLED=1 TYPESAFE_API_KEY_FILE="$KEY_FILE" -- --questions "$Q" --state-file "$STATE"
if [ "$RC" -eq 9 ] && grep -q '^JEV_ERROR=bad-response$' <<<"$OUT"; then
  ok "C4 answers が無い 200 応答は exit 9（bad-response）"
else bad "C4 rc=$RC out=$OUT"; fi

reset_fake
run_judge_args FF_JEV_ENABLED=1 TYPESAFE_API_KEY_FILE="$KEY_FILE" -- --questions "$Q" --state-file "$STATE"
if [ "$RC" -eq 8 ] && grep -q '^JEV_ERROR=transport$' <<<"$OUT"; then
  ok "C5 curl 自体の失敗（応答なし）は exit 8（transport）"
else bad "C5 rc=$RC out=$OUT"; fi

# ================================================================================
echo "== D. 入力不正は通信しない =="
reset_fake 200
printf '[1,2]' > "$WORK/bad-q.json"
run_judge_args FF_JEV_ENABLED=1 TYPESAFE_API_KEY_FILE="$KEY_FILE" -- --questions "$WORK/bad-q.json" --state-file "$STATE"
[ "$RC" -eq 2 ] && [ "$(calls)" -eq 0 ] && ok "D1 questions が object でない → exit 2、通信なし" || bad "D1 rc=$RC calls=$(calls)"
reset_fake 200
printf '{"x":{"type":"essay","instructions":"?"}}' > "$WORK/bad-q.json"
run_judge_args FF_JEV_ENABLED=1 TYPESAFE_API_KEY_FILE="$KEY_FILE" -- --questions "$WORK/bad-q.json" --state-file "$STATE"
[ "$RC" -eq 2 ] && [ "$(calls)" -eq 0 ] && ok "D2 type が noul/choice/score 以外 → exit 2" || bad "D2 rc=$RC calls=$(calls)"
reset_fake 200
printf '   \n' > "$WORK/empty-state"
run_judge_args FF_JEV_ENABLED=1 TYPESAFE_API_KEY_FILE="$KEY_FILE" -- --questions "$Q" --state-file "$WORK/empty-state"
[ "$RC" -eq 2 ] && [ "$(calls)" -eq 0 ] && ok "D3 state が空白のみ → exit 2" || bad "D3 rc=$RC calls=$(calls)"
reset_fake 200
run_judge_args FF_JEV_ENABLED=1 TYPESAFE_API_KEY_FILE="$KEY_FILE" FF_JEV_MAX_STATE_BYTES=10 -- --questions "$Q" --state-file "$STATE"
if [ "$RC" -eq 2 ] && [ "$(calls)" -eq 0 ] && grep -q '^JEV_ERROR=over-budget$' <<<"$OUT" && grep -q 'FF_JEV_MAX_STATE_BYTES' <<<"$ERR"; then
  ok "D4 state + 最長 1 質問が予算超過 → exit 2（over-budget、上限の変数名を名乗る）"
else bad "D4 rc=$RC calls=$(calls) out=$OUT err=$ERR"; fi
reset_fake 200
run_judge_args FF_JEV_ENABLED=1 TYPESAFE_API_KEY_FILE="$KEY_FILE" FF_JEV_MAX_REQUEST_BYTES=10 -- --questions "$Q" --state-file "$STATE"
[ "$RC" -eq 2 ] && [ "$(calls)" -eq 0 ] && ok "D5 state + 全質問が予算超過 → exit 2" || bad "D5 rc=$RC calls=$(calls)"
run_judge_args FF_JEV_ENABLED=1 TYPESAFE_API_KEY_FILE="$KEY_FILE" -- --bogus
[ "$RC" -eq 64 ] && ok "D6 未知の引数 → exit 64" || bad "D6 rc=$RC"

# ================================================================================
echo "== E. 評価ハーネス =="
SET="$WORK/set.jsonl"
mk_case() { # $1=id $2=group $3=expected(JSON object)
  jq -cn --arg id "$1" --arg g "$2" --argjson exp "$3" --slurpfile q "$Q" \
    '{id:$id, group:$g, state:"case state", questions:$q[0], expected:$exp}'
}

: > "$WORK/empty.jsonl"
run_eval_args FF_JEV_ENABLED=1 TYPESAFE_API_KEY_FILE="$KEY_FILE" -- --set "$WORK/empty.jsonl"
if [ "$RC" -eq 2 ] && grep -q '評価セットが空です' <<<"$ERR"; then
  ok "E1 空の評価セット → exit 2（空を不一致なしへ倒さない。文言一致）"
else bad "E1 rc=$RC err=$ERR"; fi
run_eval_args FF_JEV_ENABLED=1 TYPESAFE_API_KEY_FILE="$KEY_FILE" -- --set "$WORK/nonexistent.jsonl"
[ "$RC" -eq 2 ] && ok "E1b 無いファイル → exit 2" || bad "E1b rc=$RC"

reset_fake 200 200 200
{ mk_case c1 en '{"dept":"billing"}'; echo 'this is not json'; mk_case c3 en '{"dept":"billing"}'; } > "$SET"
run_eval_args FF_JEV_ENABLED=1 TYPESAFE_API_KEY_FILE="$KEY_FILE" -- --set "$SET"
if [ "$RC" -eq 2 ] && grep -q '2 行目' <<<"$ERR" && [ "$(calls)" -eq 0 ]; then
  ok "E2 読めない行があれば行番号を名乗って 1 件も送らず exit 2"
else bad "E2 rc=$RC calls=$(calls) err=$ERR"; fi

reset_fake 200 200
{ mk_case c1 en '{"dept":"billing"}'; echo; mk_case c3 en '{"dept":"billing"}'; } > "$SET"
run_eval_args FF_JEV_ENABLED=1 TYPESAFE_API_KEY_FILE="$KEY_FILE" -- --set "$SET"
[ "$RC" -eq 2 ] && [ "$(calls)" -eq 0 ] && ok "E3 空行も exit 2（読み飛ばして 0 件を緑にしない）" || bad "E3 rc=$RC calls=$(calls)"

reset_fake 200
mk_case c1 en '{"nope":"billing"}' > "$SET"
run_eval_args FF_JEV_ENABLED=1 TYPESAFE_API_KEY_FILE="$KEY_FILE" -- --set "$SET"
[ "$RC" -eq 2 ] && [ "$(calls)" -eq 0 ] && ok "E4 expected の qid が questions に無い → exit 2" || bad "E4 rc=$RC calls=$(calls)"

mk_case c1 en '{"dept":"billing"}' > "$SET"
reset_fake 200
run_eval_args TYPESAFE_API_KEY_FILE="$KEY_FILE" -- --set "$SET"
[ "$RC" -eq 3 ] && [ "$(calls)" -eq 0 ] && ok "E5 無効（スイッチ Off）は exit 3 を伝える" || bad "E5 rc=$RC"
reset_fake 200
run_eval_args FF_JEV_ENABLED=1 -- --set "$SET"
[ "$RC" -eq 4 ] && [ "$(calls)" -eq 0 ] && ok "E6 キー未設定は exit 4 を伝える" || bad "E6 rc=$RC"

# 成功経路: 4 件（一致 / 不一致を混ぜる。score は文言 expected も含む）
{
  mk_case c1 en '{"dept":"billing","urgent":true,"level":1}'
  mk_case c2 en '{"dept":"technical"}'
  mk_case c3 ja '{"dept":"billing","level":"Frustrated"}'
  mk_case c4 ja '{"urgent":false}'
} > "$SET"
reset_fake 200 200 200 200
run_eval_args FF_JEV_ENABLED=1 TYPESAFE_API_KEY_FILE="$KEY_FILE" FF_JEV_INTERVAL_MS=0 -- --set "$SET" --out "$WORK/results.jsonl" --json
if [ "$RC" -eq 0 ] && [ "$(calls)" -eq 4 ] && printf '%s' "$OUT" | jq -e '
     .cases == 4 and .judgements == 7
     and .overall.matches == 5 and .overall.n == 7
     and (.by_group | map(select(.group == "en")) | .[0].n == 4 and .[0].matches == 3)
     and (.by_group | map(select(.group == "ja")) | .[0].n == 3 and .[0].matches == 2)
     and (.by_question | map(select(.qid == "dept")) | .[0].n == 3 and .[0].matches == 2)
     and (.by_confidence_band | map(select(.band == "[0.8,1.0]")) | .[0].n == 7)
     and (.by_confidence_band | length == 5)
     and .input_tokens == 1200 and (.latency_ms.p50 | type == "number") and (.latency_ms.p95 | type == "number")
     and (.cost_usd > 0) and .models == ["jev-1.13.0"]' >/dev/null; then
  ok "E7 --json 集計: 7 判定中 5 一致、group / 質問 id / confidence 帯別、p50/p95、トークン、コスト"
else bad "E7 rc=$RC calls=$(calls) out=$OUT err=$ERR"; fi
if [ "$(grep -c '' "$WORK/results.jsonl")" -eq 4 ] \
   && jq -e 'select(.id == "c2") | .answers[0].match == false and .answers[0].predicted == "billing" and .answers[0].expected == "technical"' "$WORK/results.jsonl" >/dev/null \
   && jq -e 'select(.id == "c3") | [.answers[] | select(.qid == "level")] | .[0].expected == 1 and .[0].match == true' "$WORK/results.jsonl" >/dev/null \
   && jq -e 'select(.id == "c4") | .answers[0].predicted == true and .answers[0].match == false' "$WORK/results.jsonl" >/dev/null; then
  ok "E8 --out は 1 件 1 行で expected / predicted / match を持つ（score の文言 expected は legend で番号へ）"
else bad "E8 results: $(cat "$WORK/results.jsonl")"; fi

reset_fake 200 200 200 200
run_eval_args FF_JEV_ENABLED=1 TYPESAFE_API_KEY_FILE="$KEY_FILE" FF_JEV_INTERVAL_MS=0 -- --set "$SET"
if [ "$RC" -eq 0 ] && grep -q '^- overall accuracy: 71.4% (5/7)$' <<<"$OUT" \
   && grep -q '^| \[0.8,1.0\] | 7 | 5 | 71.4% |$' <<<"$OUT" \
   && grep -q '^| ja | 3 | 2 | 66.7% |$' <<<"$OUT" \
   && grep -q '^- latency ms: p50 ' <<<"$OUT"; then
  ok "E9 既定出力は Markdown 表（overall / group 別 / confidence 帯別 / latency）"
else bad "E9 rc=$RC out=$OUT"; fi

reset_fake 200 401 200 200
run_eval_args FF_JEV_ENABLED=1 TYPESAFE_API_KEY_FILE="$KEY_FILE" FF_JEV_INTERVAL_MS=0 -- --set "$SET"
if [ "$RC" -eq 5 ] && ! grep -q 'overall accuracy' <<<"$OUT" && grep -q 'c2' <<<"$ERR"; then
  ok "E10 途中 1 件の判定失敗（401）は集計せず exit 5 を伝え、case id を名乗る"
else bad "E10 rc=$RC out=$OUT err=$ERR"; fi

reset_fake 200 200 200 200
run_eval_args FF_JEV_ENABLED=1 TYPESAFE_API_KEY_FILE="$KEY_FILE" FF_JEV_INTERVAL_MS=0 -- --set "$SET" --limit 2 --json
[ "$RC" -eq 0 ] && [ "$(calls)" -eq 2 ] && printf '%s' "$OUT" | jq -e '.cases == 2' >/dev/null && ok "E11 --limit 2 は 2 件だけ送る" || bad "E11 rc=$RC calls=$(calls)"


# ================================================================================
echo "== G. 判定不能が成功 / 不一致へ化ける経路（レビュー指摘の固定）=="
# G1〜G4: 応答の形が契約と違えば exit 9（要求 qid の欠落 / type 不一致 / 値の型不正）
for pair in \
  'G1 answers が空|{"model":"m","answers":{},"usage":{"input_tokens":1}}' \
  'G2 要求 qid の一部欠落|{"model":"m","answers":{"dept":{"type":"choice","choice":"billing","probabilities":{"billing":1},"confidence":1},"level":{"type":"score","score":1,"legend":{"0":"a","1":"b","2":"c"},"probabilities":{"1":1},"confidence":1}},"usage":{"input_tokens":1}}' \
  'G3 type 不一致（dept が noul）|{"model":"m","answers":{"dept":{"type":"noul","noul":0.5},"urgent":{"type":"noul","noul":0.5},"level":{"type":"score","score":1,"legend":{"0":"a","1":"b","2":"c"},"probabilities":{"1":1},"confidence":1}},"usage":{"input_tokens":1}}' \
  'G4 noul の値が文字列|{"model":"m","answers":{"dept":{"type":"choice","choice":"billing","probabilities":{"billing":1},"confidence":1},"urgent":{"type":"noul","noul":"bad"},"level":{"type":"score","score":1,"legend":{"0":"a","1":"b","2":"c"},"probabilities":{"1":1},"confidence":1}},"usage":{"input_tokens":1}}'; do
  label="${pair%%|*}"; body="${pair#*|}"
  reset_fake 200
  printf '%s' "$body" > "$FAKE/body.200"
  run_judge_args FF_JEV_ENABLED=1 TYPESAFE_API_KEY_FILE="$KEY_FILE" -- --json --questions "$Q" --state-file "$STATE"
  if [ "$RC" -eq 9 ] && printf '%s' "$OUT" | jq -e '.ok == false and .error == "bad-response"' >/dev/null 2>&1; then
    ok "${label} → exit 9（bad-response、--json でも ok:false）"
  else bad "${label}: rc=$RC out=$OUT"; fi
done

reset_fake 200
run_judge_args FF_JEV_ENABLED=1 TYPESAFE_API_KEY="k1
url = http://attacker.invalid/" -- --questions "$Q" --state-file "$STATE"
if [ "$RC" -eq 4 ] && grep -q '^JEV_ERROR=key-invalid$' <<<"$OUT" && [ "$(calls)" -eq 0 ]; then
  ok "G5 改行を含むキーは curl 設定へ差し込まず exit 4（key-invalid、通信なし）"
else bad "G5 rc=$RC calls=$(calls) out=$OUT"; fi
reset_fake 200
run_judge_args FF_JEV_ENABLED=1 TYPESAFE_API_KEY='k"1' -- --questions "$Q" --state-file "$STATE"
[ "$RC" -eq 4 ] && [ "$(calls)" -eq 0 ] && ok "G5b 引用符を含むキーも exit 4" || bad "G5b rc=$RC calls=$(calls)"

reset_fake 200
printf '  %s  \r\n' "$FAKE_KEY" > "$WORK/key-spaces"
run_judge_args FF_JEV_ENABLED=1 TYPESAFE_API_KEY_FILE="$WORK/key-spaces" -- --questions "$Q" --state-file "$STATE"
if [ "$RC" -eq 0 ] && grep -q "^header = \"Authorization: Bearer ${FAKE_KEY}\"$" "$FAKE/call.1.config"; then
  ok "G6 キーファイルの前後空白と CRLF は落として送る"
else bad "G6 rc=$RC config=$(sed 's/Bearer .*/Bearer <redacted>/' "$FAKE/call.1.config" 2>/dev/null)"; fi

reset_fake 200
printf '%s\n' "$FAKE_KEY" > "$WORK/key-000"; chmod 000 "$WORK/key-000"
run_judge_args FF_JEV_ENABLED=1 TYPESAFE_API_KEY_FILE="$WORK/key-000" -- --questions "$Q" --state-file "$STATE"
if [ "$RC" -eq 4 ] && grep -q '読めません' <<<"$ERR" && grep -q 'key-000' <<<"$ERR" && [ "$(calls)" -eq 0 ]; then
  ok "G7 読めないキーファイル（000）は「無い」ではなく「読めません」とパスを名指しして exit 4"
else bad "G7 rc=$RC err=$ERR"; fi
chmod 600 "$WORK/key-000"

reset_fake 200
mkdir -p "$ISO_HOME/.config/ff-dev-toolkit"
printf '%s\n' "$FAKE_KEY" > "$ISO_HOME/.config/ff-dev-toolkit/typesafe_api_key"
run_judge_args FF_JEV_ENABLED=1 TYPESAFE_API_KEY_FILE="$WORK/no-such-key" -- --questions "$Q" --state-file "$STATE"
if [ "$RC" -eq 4 ] && grep -q 'no-such-key' <<<"$ERR" && [ "$(calls)" -eq 0 ]; then
  ok "G8 TYPESAFE_API_KEY_FILE が無いときは既定パスへ落ちず、指定パスを名指しして exit 4"
else bad "G8 rc=$RC calls=$(calls) err=$ERR"; fi
rm -rf "$ISO_HOME/.config"

for v in FF_JEV_MAX_RETRIES=abc FF_JEV_RETRY_BASE_SECONDS=-1 FF_JEV_MAX_STATE_BYTES=1e5 FF_JEV_MAX_RETRY_AFTER_SECONDS=1.5; do
  reset_fake 200
  run_judge_args FF_JEV_ENABLED=1 TYPESAFE_API_KEY_FILE="$KEY_FILE" "$v" -- --questions "$Q" --state-file "$STATE"
  if [ "$RC" -eq 64 ] && grep -q '^JEV_ERROR=bad-config$' <<<"$OUT" && [ "$(calls)" -eq 0 ]; then
    ok "G9 ${v%%=*} が非数値 → exit 64（上限なしへ倒さない）"
  else bad "G9 $v: rc=$RC calls=$(calls)"; fi
done

# G10: バイト予算は文字数でなくバイト。日本語 40 文字（120 バイト）の質問 + 小さな state を
# 上限 100 バイトに掛けると、文字数（約 70）なら通り、バイト（約 150）なら赤になる
reset_fake 200
cat > "$WORK/q-ja.json" <<'EOF'
{ "sev": { "type": "choice", "instructions": "この指摘の重大度を四段階で分類してくださいこの指摘の重大度を四段階で分類", "criteria": { "a": null, "b": null } } }
EOF
printf 'x' > "$WORK/state-tiny"
run_judge_args FF_JEV_ENABLED=1 TYPESAFE_API_KEY_FILE="$KEY_FILE" FF_JEV_MAX_STATE_BYTES=100 FF_JEV_MAX_REQUEST_BYTES=100000 -- --questions "$WORK/q-ja.json" --state-file "$WORK/state-tiny"
if [ "$RC" -eq 2 ] && grep -q '^JEV_ERROR=over-budget$' <<<"$OUT" && [ "$(calls)" -eq 0 ]; then
  ok "G10 日本語の質問はバイトで数えて予算超過（文字数で数えると素通りする）"
else bad "G10 rc=$RC calls=$(calls) out=$OUT err=$ERR"; fi

reset_fake 200
printf '{"d":{"type":"choice","instructions":"?","criteria":{"a|b":null,"c":null}}}' > "$WORK/q-pipe.json"
run_judge_args FF_JEV_ENABLED=1 TYPESAFE_API_KEY_FILE="$KEY_FILE" -- --questions "$WORK/q-pipe.json" --state-file "$STATE"
[ "$RC" -eq 2 ] && [ "$(calls)" -eq 0 ] && ok "G11 option 名の | は ANSWER 行と衝突するため exit 2" || bad "G11 rc=$RC calls=$(calls)"

# ---- ハーネス側 ----
for pair in \
  'G12 choice の expected が criteria に無い|{"dept":"legal"}' \
  'G13 score の expected 文言が criteria に無い|{"level":"Furious"}' \
  'G14 noul の expected が boolean でない|{"urgent":1}' \
  'G15 score の expected が object|{"level":{}}' \
  'G16 score の expected がレベル範囲外|{"level":7}'; do
  label="${pair%%|*}"; exp="${pair#*|}"
  reset_fake 200
  mk_case c1 en "$exp" > "$SET"
  run_eval_args FF_JEV_ENABLED=1 TYPESAFE_API_KEY_FILE="$KEY_FILE" -- --set "$SET"
  if [ "$RC" -eq 2 ] && grep -q '1 行目' <<<"$ERR" && [ "$(calls)" -eq 0 ]; then
    ok "${label} → 通信前に exit 2（行番号を名乗る）"
  else bad "${label}: rc=$RC calls=$(calls) err=$ERR"; fi
done
for st in 'null' '42'; do
  reset_fake 200
  jq -cn --argjson st "$st" --slurpfile q "$Q" '{id:"c1", state:$st, questions:$q[0], expected:{dept:"billing"}}' > "$SET"
  run_eval_args FF_JEV_ENABLED=1 TYPESAFE_API_KEY_FILE="$KEY_FILE" -- --set "$SET"
  [ "$RC" -eq 2 ] && [ "$(calls)" -eq 0 ] && ok "G17 state が ${st} → 通信前に exit 2" || bad "G17 state=$st rc=$RC calls=$(calls)"
done
reset_fake 200 200
{ mk_case c1 en '{"dept":"billing"}'; printf '{"id":"c2","state":"s","questions":{"x":{"type":"essay","instructions":"?"}},"expected":{"x":"y"}}\n'; } > "$SET"
run_eval_args FF_JEV_ENABLED=1 TYPESAFE_API_KEY_FILE="$KEY_FILE" -- --set "$SET"
if [ "$RC" -eq 2 ] && grep -q '2 行目' <<<"$ERR" && [ "$(calls)" -eq 0 ]; then
  ok "G18 2 行目の questions 不正でも 1 行目を送らない（事前検証は全行）"
else bad "G18 rc=$RC calls=$(calls) err=$ERR"; fi

mk_case c1 en '{"dept":"billing"}' > "$SET"
reset_fake 200
run_eval_args FF_JEV_ENABLED=1 TYPESAFE_API_KEY_FILE="$KEY_FILE" FF_JEV_INTERVAL_MS=0 -- --set "$SET" --out "$WORK/no-such-dir/r.jsonl"
if [ "$RC" -eq 2 ] && ! grep -q 'overall accuracy' <<<"$OUT" && grep -q -- '--out' <<<"$ERR"; then
  ok "G19 --out へ書けなければ集計を出さず exit 2"
else bad "G19 rc=$RC out=$OUT err=$ERR"; fi
reset_fake 200
run_eval_args FF_JEV_ENABLED=1 TYPESAFE_API_KEY_FILE="$KEY_FILE" -- --set "$SET" --limit abc
[ "$RC" -eq 64 ] && [ "$(calls)" -eq 0 ] && ok "G20 --limit abc → exit 64（全件送信へ倒さない）" || bad "G20 rc=$RC calls=$(calls)"
reset_fake 200
run_eval_args FF_JEV_ENABLED=1 TYPESAFE_API_KEY_FILE="$KEY_FILE" FF_JEV_INTERVAL_MS=abc -- --set "$SET"
[ "$RC" -eq 64 ] && [ "$(calls)" -eq 0 ] && ok "G21 FF_JEV_INTERVAL_MS=abc → exit 64（レート制御を黙って無効化しない）" || bad "G21 rc=$RC calls=$(calls)"

# G22: 応答に expected の qid が無い形は判定側で exit 9 になり、ハーネスは集計せず 9 を伝える
reset_fake 200
printf '%s' '{"model":"m","answers":{"dept":{"type":"choice","choice":"billing","probabilities":{"billing":1},"confidence":1},"level":{"type":"score","score":1,"legend":{"0":"a","1":"b","2":"c"},"probabilities":{"1":1},"confidence":1}},"usage":{"input_tokens":1}}' > "$FAKE/body.200"
mk_case c1 en '{"urgent":true}' > "$SET"
run_eval_args FF_JEV_ENABLED=1 TYPESAFE_API_KEY_FILE="$KEY_FILE" FF_JEV_INTERVAL_MS=0 -- --set "$SET"
if [ "$RC" -eq 9 ] && ! grep -q 'overall accuracy' <<<"$OUT" && grep -q 'c1' <<<"$ERR"; then
  ok "G22 応答に expected の qid が無い → 集計せず exit 9（不一致に計上しない）"
else bad "G22 rc=$RC out=$OUT err=$ERR"; fi

# G23: 低 confidence の不一致は該当帯へ計上される（較正表の意味）
reset_fake 200 200
printf '%s' '{"model":"m","answers":{"dept":{"type":"choice","choice":"technical","probabilities":{"billing":0.35,"technical":0.65},"confidence":0.3},"urgent":{"type":"noul","noul":0.6},"level":{"type":"score","score":1,"legend":{"0":"Calm","1":"Frustrated","2":"Very angry"},"probabilities":{"1":1},"confidence":0.19}},"usage":{"input_tokens":10}}' > "$FAKE/body.200"
{ mk_case c1 en '{"dept":"billing","urgent":true,"level":1}'; } > "$SET"
run_eval_args FF_JEV_ENABLED=1 TYPESAFE_API_KEY_FILE="$KEY_FILE" FF_JEV_INTERVAL_MS=0 -- --set "$SET" --json
if [ "$RC" -eq 0 ] && printf '%s' "$OUT" | jq -e '
     (.by_confidence_band | map(select(.band == "[0.2,0.4)")) | .[0].n == 2 and .[0].matches == 1)
     and (.by_confidence_band | map(select(.band == "[0.0,0.2)")) | .[0].n == 1 and .[0].matches == 1)
     and .overall.n == 3 and .overall.matches == 2' >/dev/null; then
  ok "G23 confidence 0.3 の不一致と 0.2（noul 0.6）の一致は [0.2,0.4) へ、0.19 は [0.0,0.2) へ計上"
else bad "G23 rc=$RC out=$OUT err=$ERR"; fi


# ================================================================================
echo "== H. ACE 評価セット生成器（合成 fixture で期待値まで固定 + 実 PLAYBOOK の構造検査）=="
GEN="$PLUGIN_ROOT/scripts/jev/build-ace-eval-sets.ts"
RUNNER="$PLUGIN_ROOT/scripts/ace-run-ts.sh"
LABELS="$PLUGIN_ROOT/scripts/jev/fixtures/ace-abstraction-labels.json"
PLAYBOOK_REAL="$PLUGIN_ROOT/../../docs/08-knowledge/PLAYBOOK.md"
gen() { # $@=引数。stdout→${OUT} rc→${RC}（stderr は ${ERR}）
  OUT="$(FF_DEV_TOOLKIT_ROOT="$PLUGIN_ROOT" bash "$RUNNER" "$GEN" "$@" 2>"$WORK/gen.err")"; RC=$?
  ERR="$(cat "$WORK/gen.err")"
}
# 合成 Playbook: 5 compact（日付 D1<D2<D3<D4、同日の PR 差あり）+ legacy 1 + archive 1。
# Changelog は 2 版（新→旧）。版 A（D3 / PR 30）: 追加 ACE-30-1・Helpful ACE-10-1。版 B（D2 / PR 20）: 追加 ACE-20-1
SYN="$WORK/synth"; mkdir -p "$SYN/playbook/archive"
mk_entry() { # $1=id $2=date $3=pr $4=title $5=body
  printf '<a id="%s"></a>\n\n### %s: %s\n\n| Category | testing | Origin | PR #%s |\n| Date | %s |\n| Helpful | 0 | Harmful | 0 |\n| Status | active |\n\n%s\n\n---\n\n' "$(printf '%s' "$1" | tr 'A-Z' 'a-z')" "$1" "$4" "$3" "$2" "$5"
}
{
  printf '# testing\n\n'
  mk_entry ACE-10-1 2026-01-01 10 "針の変異は赤の件数まで数える" "変異を当てたら赤になった件数を針の本数と照合する。少なければ重複針を疑う。"
  mk_entry ACE-10-2 2026-01-01 10 "fixture は境界の両側を持つ" "閾値の端ちょうどと外側の 4 点を fixture に置き、片側だけの検査にしない。"
  mk_entry ACE-20-1 2026-02-01 20 "検査総数を baseline で縛る" "針ごとの変異は検査そのものの消失を検出できないので、実行検査数を baseline と照合する。"
  mk_entry ACE-30-1 2026-03-01 30 "赤の件数と針の本数の不一致は重複針を指す" "対象を丸ごと壊した変異の赤が針の本数より少ないなら、対象の外にも一致する針がある。"
  mk_entry ACE-40-1 2026-04-01 40 "未来のエントリ" "版 A より後に追加された語彙一致の高いエントリ。針 変異 赤 件数 重複針。"
  printf '### ACE-5-9: 旧形式のエントリ\n\n| フィールド | 値 |\n| --- | --- |\n| Category | testing |\n| Insight | 旧テーブル形式 |\n\n---\n'
} > "$SYN/playbook/testing.md"
mk_entry ACE-1-1 2025-12-01 1 "アーカイブ済み" "archive 配下は母集団に入らない。" > "$SYN/playbook/archive/testing.md"
# Issue / PR の番号短縮形は公開対象の追加行に書けない（sync-forbidden-patterns）ので、記号を printf の引数で差し込む
{
  printf '# PLAYBOOK\n\n## エントリ一覧\n\n| エントリID | タイトル | Category | 参照先 |\n| --- | --- | --- | --- |\n\n## Changelog\n\n'
  printf '### [1.2.0] - 2026-03-01\n\n#### 追加\n\n- ACE-30-1: 赤の件数と針の本数の不一致は重複針を指す（Issue %s29 / PR %s30）。ACE-9-9 を deprecated に変更\n\n' '#' '#'
  printf '#### カウンター更新\n\n- ACE-10-1: Helpful +1（変異で赤になった件数を針の本数と照合し、重複針を 1 本見つけた）\n\n'
  printf '### [1.1.0] - 2026-02-01\n\n#### 追加\n\n- ACE-20-1: 検査総数を baseline で縛る（Issue %s19 / PR %s20）\n' '#' '#'
} > "$SYN/PLAYBOOK.md"
if [ ! -f "$GEN" ] || [ ! -f "$LABELS" ]; then
  bad "H0 生成器またはラベル fixture がありません: $GEN / $LABELS"
else
  gen --playbook "$SYN/PLAYBOOK.md" --out "$WORK/syn1" --recent-versions 2 --neighbors 2
  if [ "$RC" -eq 3 ]; then
    echo "  ○ skip: tsx ランナーを起動できないため H 節を実行していません（${ERR}）"
  else
    if [ "$RC" -eq 0 ] && grep -q '^entries=6 legacy=1 versions=2 added=2 helpful=1 novelty=2 helpful_dropped=0 unpaired=0 recent=6 added_from_summary=0 recent_helpful_dropped=0 abstraction=0$' <<<"$OUT"; then
      ok "H1 合成 Playbook: entries 6（legacy 1・archive 除外）/ 版 2 / 追加 2 / Helpful 1 / novelty 2 / recent 6"
    else bad "H1 rc=$RC out=$OUT err=$ERR"; fi
    # novelty: 正例は ACE-10-1、負例は同カテゴリの別エントリ。pair ごとに pos / neg が 1 件ずつ
    if jq -e 'select(.group=="pos") | .state.id=="ACE-10-1" and .expected.same_action==true and (.questions.same_action.instructions.candidate|test("重複針"))' "$WORK/syn1/novelty-pairs.jsonl" >/dev/null 2>&1 \
       && jq -e 'select(.group=="neg") | .state.id!="ACE-10-1" and .state.category=="testing" and .expected.same_action==false' "$WORK/syn1/novelty-pairs.jsonl" >/dev/null 2>&1 \
       && [ "$(jq -r '[.pair,.group]|@tsv' "$WORK/syn1/novelty-pairs.jsonl" | sort | uniq | awk '{print $1}' | sort | uniq -c | awk '$1!=2' | wc -l | tr -d ' ')" -eq 0 ]; then
      ok "H2 novelty: 正例 = Helpful 行の参照先 + 理由文、負例 = 同カテゴリの別エントリ、各 pair に pos / neg が厳密に 1 件ずつ"
    else bad "H2 novelty の形: $(cat "$WORK/syn1/novelty-pairs.jsonl" | cut -c1-200)"; fi
    # recent: 版 A の追加（30-1）は D3 より前の 3 件から 2 近傍・全 false / Helpful（10-1）は参照先 true + 近傍 1 件 false /
    # 版 B の追加（20-1）は D2 より前の 2 件 / 未来の ACE-40-1 はどこにも出ない / 近傍の日付は版の日付以下
    if [ "$(jq -r 'select(.group=="added" and .expected.same_action==true) | .id' "$WORK/syn1/recent-candidates.jsonl" | wc -l | tr -d ' ')" -eq 0 ] \
       && [ "$(jq -r 'select(.candidate|startswith("helpful-ACE-10-1")) | select(.expected.same_action==true) | .neighbor' "$WORK/syn1/recent-candidates.jsonl" | tr '\n' ' ')" = "ACE-10-1 " ] \
       && [ "$(jq -r 'select(.candidate|startswith("helpful-ACE-10-1")) | select(.expected.same_action==false) | .neighbor' "$WORK/syn1/recent-candidates.jsonl" | grep -cE '^ACE-(10-2|20-1)$')" -eq 1 ] \
       && [ "$(jq -r 'select(.candidate=="ACE-30-1") | .neighbor' "$WORK/syn1/recent-candidates.jsonl" | wc -l | tr -d ' ')" -eq 2 ] \
       && [ "$(jq -r 'select(.candidate=="ACE-20-1") | .neighbor' "$WORK/syn1/recent-candidates.jsonl" | sort | tr '\n' ' ')" = "ACE-10-1 ACE-10-2 " ] \
       && ! grep -q 'ACE-40-1' "$WORK/syn1/recent-candidates.jsonl" \
       && [ "$(jq -r 'select(.neighbor_date > .version_date) | .id' "$WORK/syn1/recent-candidates.jsonl" | wc -l | tr -d ' ')" -eq 0 ] \
       && [ "$(jq -r '.candidate' "$WORK/syn1/recent-candidates.jsonl" | sort | uniq -c | awk '$1!=2' | wc -l | tr -d ' ')" -eq 0 ]; then
      ok "H3 recent: 追加は全 false・Helpful は参照先だけ true・近傍は版より前のエントリだけ（未来の ACE-40-1 は出ない）・各候補 K=2 件"
    else bad "H3 recent の形: $(jq -c '{c:.candidate,n:.neighbor,e:.expected}' "$WORK/syn1/recent-candidates.jsonl" | tr '\n' ' ')"; fi
    # 同日の境界: 版 B と同日（D2）の追加 ACE-20-1 自身は版 B の近傍に出ない（Origin PR 20 は versionPr 20 より小さくない）
    grep -q '"candidate":"ACE-20-1"' "$WORK/syn1/recent-candidates.jsonl" && [ -z "$(jq -r 'select(.version=="1.1.0") | select(.neighbor=="ACE-20-1") | .id' "$WORK/syn1/recent-candidates.jsonl")" ] \
      && ok "H4 同日のエントリは Origin PR が小さい側だけを「前」とみなす" || bad "H4 同日境界"
    gen --playbook "$SYN/PLAYBOOK.md" --out "$WORK/syn2" --recent-versions 2 --neighbors 2
    cmp -s "$WORK/syn1/novelty-pairs.jsonl" "$WORK/syn2/novelty-pairs.jsonl" && cmp -s "$WORK/syn1/recent-candidates.jsonl" "$WORK/syn2/recent-candidates.jsonl" \
      && ok "H5 同じ入力で 2 回生成してバイト同一（決定性）" || bad "H5 生成結果が実行ごとに変わる"
    # 抽象度: レポート（候補 = 10-1, 20-1）+ ラベル → candidate 2 / non-candidate 2、expected はラベルどおり、候補 ID は非候補に出ない
    printf '{"candidates":[{"id":"ACE-20-1","format":"compact"},{"id":"ACE-10-1","format":"compact"},{"id":"ACE-5-9","format":"legacy"}]}' > "$WORK/syn-report.json"
    printf '{"ACE-10-1":{"deficient":true},"ACE-20-1":{"deficient":false},"ACE-10-2":{"deficient":false},"ACE-30-1":{"deficient":true},"ACE-40-1":{"deficient":false}}' > "$WORK/syn-labels.json"
    gen --playbook "$SYN/PLAYBOOK.md" --out "$WORK/syn3" --recent-versions 2 --neighbors 2 --abstraction-report "$WORK/syn-report.json" --labels "$WORK/syn-labels.json" --candidates 5 --non-candidates 2
    if [ "$RC" -eq 0 ] && [ "$(jq -r '[.group,.state.id,.expected.abstraction_deficient]|@tsv' "$WORK/syn3/abstraction.jsonl" | sort | tr '\n' ' ')" = "candidate	ACE-10-1	true candidate	ACE-20-1	false non-candidate	ACE-10-2	false non-candidate	ACE-30-1	true " ]; then
      ok "H6 abstraction: compact 候補だけが candidate、非候補は候補集合の外から等間隔、expected はラベル fixture どおり"
    else bad "H6 rc=$RC rows=$(cat "$WORK/syn3/abstraction.jsonl" 2>/dev/null | jq -c '[.group,.state.id,.expected]' | tr '\n' ' ') err=$ERR"; fi
    gen --playbook "$SYN/PLAYBOOK.md" --out "$WORK/syn4" --recent-versions 2 --neighbors 2 --abstraction-report "$WORK/syn-report.json" --labels "$WORK/syn-labels.json" --candidates 5 --non-candidates 2
    cmp -s "$WORK/syn3/abstraction.jsonl" "$WORK/syn4/abstraction.jsonl" && ok "H7 abstraction も決定的" || bad "H7 abstraction が実行ごとに変わる"
    # fail-closed の経路
    printf '{"ACE-20-1":{"deficient":false}}' > "$WORK/syn-labels-short.json"
    gen --playbook "$SYN/PLAYBOOK.md" --out "$WORK/syn5" --abstraction-report "$WORK/syn-report.json" --labels "$WORK/syn-labels-short.json"
    [ "$RC" -eq 2 ] && grep -q 'ACE-10-1' <<<"$ERR" && ok "H8 精読ラベルの無い ID は exit 2 で名指し" || bad "H8 rc=$RC err=$ERR"
    printf '{}' > "$WORK/syn-report-bad.json"
    gen --playbook "$SYN/PLAYBOOK.md" --out "$WORK/syn5" --abstraction-report "$WORK/syn-report-bad.json" --labels "$WORK/syn-labels.json"
    [ "$RC" -eq 2 ] && grep -q 'candidates' <<<"$ERR" && ok "H9 candidates の無いレポートは exit 2（空候補で成功にしない）" || bad "H9 rc=$RC err=$ERR"
    printf '{"candidates":[{"id":"ACE-99-9","format":"compact"}]}' > "$WORK/syn-report-ghost.json"
    gen --playbook "$SYN/PLAYBOOK.md" --out "$WORK/syn5" --abstraction-report "$WORK/syn-report-ghost.json" --labels "$WORK/syn-labels.json"
    [ "$RC" -eq 2 ] && grep -q 'ACE-99-9' <<<"$ERR" && ok "H10 Playbook に無い候補 ID は exit 2 で名指し" || bad "H10 rc=$RC err=$ERR"
    gen --playbook "$SYN/PLAYBOOK.md" --out "$WORK/syn5" --abstraction-report "$WORK/syn-report.json"
    [ "$RC" -eq 2 ] && ok "H11 --abstraction-report だけ（--labels 無し）は exit 2" || bad "H11 rc=$RC"
    for v in "--neighbors x" "--recent-versions 0" "--novelty-sample -1"; do
      # shellcheck disable=SC2086
      gen --playbook "$SYN/PLAYBOOK.md" --out "$WORK/syn5" $v
      [ "$RC" -eq 2 ] && ok "H12 数値オプションの不正（${v}）は exit 2" || bad "H12 $v rc=$RC"
    done
    mkdir -p "$WORK/nochangelog/playbook"; printf '# PLAYBOOK\n' > "$WORK/nochangelog/PLAYBOOK.md"; cp "$SYN/playbook/testing.md" "$WORK/nochangelog/playbook/"
    gen --playbook "$WORK/nochangelog/PLAYBOOK.md" --out "$WORK/syn6"
    [ "$RC" -eq 2 ] && grep -q 'Changelog がありません' <<<"$ERR" && ok "H13 Changelog の無い PLAYBOOK → exit 2（文言一致）" || bad "H13 rc=$RC err=$ERR"
    mkdir -p "$WORK/drift/playbook"; cp "$SYN/playbook/testing.md" "$WORK/drift/playbook/"; sed 's/^#### 追加/#### Added/; s/^#### カウンター更新/#### Counters/' "$SYN/PLAYBOOK.md" > "$WORK/drift/PLAYBOOK.md"
    gen --playbook "$WORK/drift/PLAYBOOK.md" --out "$WORK/syn7"
    [ "$RC" -eq 2 ] && grep -q '1 件も読めません' <<<"$ERR" && ok "H14 Changelog の見出し形式が変わって行が 1 件も読めない → exit 2（0 件を成功にしない）" || bad "H14 rc=$RC err=$ERR"
    mkdir -p "$WORK/badhelp/playbook"; cp "$SYN/playbook/testing.md" "$WORK/badhelp/playbook/"; sed 's/^- ACE-10-1: Helpful +1（/- ACE-10-1: Helpful +1 (/' "$SYN/PLAYBOOK.md" > "$WORK/badhelp/PLAYBOOK.md"
    gen --playbook "$WORK/badhelp/PLAYBOOK.md" --out "$WORK/syn8"
    [ "$RC" -eq 2 ] && grep -q 'Helpful +1' <<<"$ERR" && ok "H15 Helpful +1 を含むのに契約の形で読めない行は exit 2（黙って落とさない）" || bad "H15 rc=$RC err=$ERR"
    mkdir -p "$WORK/nodate/playbook"; cp "$SYN/PLAYBOOK.md" "$WORK/nodate/"; sed '/^| Date | 2026-02-01 |$/d' "$SYN/playbook/testing.md" > "$WORK/nodate/playbook/testing.md"
    gen --playbook "$WORK/nodate/PLAYBOOK.md" --out "$WORK/syn9"
    [ "$RC" -eq 2 ] && grep -q 'Date' <<<"$ERR" && ok "H16 Date を読めない compact エントリは exit 2（時点境界の材料を欠いたまま近傍に使わない）" || bad "H16 rc=$RC err=$ERR"
    # --summarize（recent）: 一致 / 厳しい / 参照先違い / 緩い の 4 区分と、id 形式外の行・欠落 answers の拒否
    cat > "$WORK/rec-results.jsonl" <<'EOF'
{"id":"rec-1.0.0-ACE-9-1-vs-ACE-1-1","group":"added","answers":[{"qid":"same_action","expected":false,"predicted":false,"raw":0.1}]}
{"id":"rec-1.0.0-ACE-9-1-vs-ACE-2-1","group":"added","answers":[{"qid":"same_action","expected":false,"predicted":true,"raw":0.8}]}
{"id":"rec-1.0.0-helpful-ACE-3-1-ab-vs-ACE-3-1","group":"helpful","answers":[{"qid":"same_action","expected":true,"predicted":true,"raw":0.9}]}
{"id":"rec-1.0.0-helpful-ACE-3-1-ab-vs-ACE-4-1","group":"helpful","answers":[{"qid":"same_action","expected":false,"predicted":false,"raw":0.2}]}
{"id":"rec-1.0.0-helpful-ACE-5-1-cd-vs-ACE-5-1","group":"helpful","answers":[{"qid":"same_action","expected":true,"predicted":true,"raw":0.4}]}
{"id":"rec-1.0.0-helpful-ACE-5-1-cd-vs-ACE-6-1","group":"helpful","answers":[{"qid":"same_action","expected":false,"predicted":true,"raw":0.9}]}
{"id":"rec-1.0.0-helpful-ACE-i7-1-ef-vs-ACE-i7-1","group":"helpful","answers":[{"qid":"same_action","expected":true,"predicted":false,"raw":0.3}]}
EOF
    gen --summarize "$WORK/rec-results.jsonl" --kind recent
    if [ "$RC" -eq 0 ] && grep -q '候補 4 件 / 一致 1 / Jev が「同一」側に厳しい 1 / Jev が「新規」側に緩い 1 / 同一だが参照先が違う 1' <<<"$OUT" \
       && grep -q '| 1.0.0:helpful-ACE-5-1-cd | 同一（ACE-5-1） | 同一（0.90 → ACE-6-1） | ⚠️ |' <<<"$OUT"; then
      ok "H17 --summarize recent: 評価時の predicted で判定し、参照先違いを別区分に数える（i 接頭辞 ID も可）"
    else bad "H17 rc=$RC out=$OUT err=$ERR"; fi
    printf '{"id":"bogus","answers":[{"expected":false,"predicted":false,"raw":0.1}]}\n' >> "$WORK/rec-results.jsonl"
    gen --summarize "$WORK/rec-results.jsonl" --kind recent
    [ "$RC" -eq 2 ] && grep -q 'bogus' <<<"$ERR" && ok "H18 id の形が契約外の行は集計せず exit 2 で名指し" || bad "H18 rc=$RC err=$ERR"
    printf '{"id":"rec-1.0.0-ACE-9-1-vs-ACE-1-1"}\n' > "$WORK/rec-bad.jsonl"
    gen --summarize "$WORK/rec-bad.jsonl" --kind recent
    [ "$RC" -eq 2 ] && ok "H19 answers の無い結果行は exit 2（TypeError で落ちない）" || bad "H19 rc=$RC"
    cat > "$WORK/abs-results.jsonl" <<'EOF'
{"id":"abs-ACE-1","group":"candidate","answers":[{"qid":"abstraction_deficient","expected":true,"predicted":false}]}
{"id":"abs-ACE-2","group":"candidate","answers":[{"qid":"abstraction_deficient","expected":false,"predicted":false}]}
{"id":"abs-ACE-3","group":"non-candidate","answers":[{"qid":"abstraction_deficient","expected":true,"predicted":false}]}
EOF
    gen --summarize "$WORK/abs-results.jsonl" --kind abstraction
    if [ "$RC" -eq 0 ] && grep -q '| 機械シグナル（候補 = 抽象度不足） | 50.0% | 50.0% | 1 / 1 / 1 / 0 |' <<<"$OUT" && grep -q '| Jev Noul（評価時の閾値で predicted = 抽象度不足） | - | 0.0% | 0 / 0 / 2 / 1 |' <<<"$OUT"; then
      ok "H20 --summarize abstraction: 機械シグナルと Jev を同じ定義で並べ、予測陽性 0 件の precision は「-」"
    else bad "H20 rc=$RC out=$OUT"; fi
    gen --summarize "$WORK/abs-results.jsonl" --kind novelty
    [ "$RC" -eq 2 ] && ok "H21 --kind novelty は exit 2" || bad "H21 rc=$RC"
    # 実 PLAYBOOK（SSOT 配置でだけ在る）: 構造だけを見る。件数の主張は合成側で固定済み
    if [ -f "$PLAYBOOK_REAL" ]; then
      gen --playbook "$PLAYBOOK_REAL" --out "$WORK/real1"
      if [ "$RC" -eq 0 ] && grep -q '^entries=[1-9]' <<<"$OUT" \
         && [ "$(jq -r 'select(.neighbor_date > .version_date) | .id' "$WORK/real1/recent-candidates.jsonl" | wc -l | tr -d ' ')" -eq 0 ] \
         && [ "$(jq -r 'select(.group=="added" and .expected.same_action==true) | .id' "$WORK/real1/recent-candidates.jsonl" | wc -l | tr -d ' ')" -eq 0 ] \
         && [ "$(jq -r '.group' "$WORK/real1/novelty-pairs.jsonl" | sort | uniq -c | awk '{print $1}' | sort -u | wc -l | tr -d ' ')" -eq 1 ]; then
        ok "H22 実 PLAYBOOK: 生成でき、近傍は版より前、追加候補は全 false、pos / neg 同数（${OUT}）"
      else bad "H22 rc=$RC out=$OUT err=$ERR"; fi
    else
      echo "  ○ skip: リポジトリ側の docs/08-knowledge/PLAYBOOK.md が無いため H22 だけ実行していません（配布先 checkout。合成 fixture の H1〜H21 は実行済み）"
    fi
  fi
fi

# ================================================================================
echo "== F. 同梱 fixture（日英 Choice probe）=="
if [ "$(grep -c '' "$PROBE")" -eq 10 ] \
   && [ "$(jq -r 'select(.group == "en") | .id' "$PROBE" | wc -l | tr -d ' ')" -eq 5 ] \
   && [ "$(jq -r 'select(.group == "ja") | .id' "$PROBE" | wc -l | tr -d ' ')" -eq 5 ]; then
  ok "F1 en / ja 各 5 件（計 10 行）"
else bad "F1 行数: $(grep -c '' "$PROBE")"; fi
if jq -e '.questions.severity.type == "choice" and (.expected.severity as $e | .questions.severity.criteria | has($e))' "$PROBE" >/dev/null 2>&1 \
   && [ "$(jq -e '.questions.severity.type == "choice" and (.expected.severity as $e | .questions.severity.criteria | has($e))' "$PROBE" | grep -c true)" -eq 10 ]; then
  ok "F2 全行が Choice で、expected が criteria に実在する"
else bad "F2 expected が criteria に無い行がある"; fi
if [ "$(jq -r '.pair' "$PROBE" | sort | uniq -c | awk '$1 != 2' | wc -l | tr -d ' ')" -eq 0 ] \
   && [ "$(jq -r '.state' "$PROBE" | sort -u | wc -l | tr -d ' ')" -eq 5 ]; then
  ok "F3 各 pair は en / ja の 2 行で同じ state を共有する（質問だけが違う）"
else bad "F3 pair / state の対応が崩れている"; fi
reset_fake 200 200 200 200 200 200 200 200 200 200
printf '%s' '{"model":"jev-1.13.0","answers":{"severity":{"type":"choice","choice":"critical","probabilities":{"critical":0.7,"warning":0.2,"suggestion":0.1,"info":0.0},"confidence":0.6}},"usage":{"input_tokens":150,"output_tokens":10}}' > "$FAKE/body.200"
run_eval_args FF_JEV_ENABLED=1 TYPESAFE_API_KEY_FILE="$KEY_FILE" FF_JEV_INTERVAL_MS=0 -- --set "$PROBE" --json
if [ "$RC" -eq 0 ] && printf '%s' "$OUT" | jq -e '.cases == 10 and .overall.n == 10 and (.by_group | length == 2)' >/dev/null; then
  ok "F4 fixture はそのままハーネスに流せる（偽応答で 10 件・group 2 つ）"
else bad "F4 rc=$RC out=$OUT err=$ERR"; fi

# ================================================================================
echo
echo "jev-adapter: ${PASS} passed, ${FAIL} failed"
FF_REACHED_END=1
[ "$FAIL" -eq 0 ]
