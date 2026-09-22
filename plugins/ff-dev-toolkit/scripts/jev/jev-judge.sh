#!/usr/bin/env bash
#
# jev-judge.sh — Jev（TypeSafe AI System One Model）への判定アダプタ
#
# 使い方:
#   jev-judge.sh --questions <questions.json> [--state-file <file>] [--json]
#   jev-judge.sh --questions <questions.json> < state.txt
#   jev-judge.sh --check                       … 有効化・キー・依存の事前確認だけ（通信しない）
#
# 何のためにあるか:
#   ワークフローの「閉じた選択肢 / 真偽 / スコア」の判断点へ Jev を当てるための**唯一の通信口**。
#   判定点ごとに呼び出しを書くと評価の形式がばらけて比較できないので、「state + 質問集合 →
#   判定・確率・confidence・usage・レイテンシ」を 1 つの契約で返す。採否（閾値・切替 FF_JEV_MODE・
#   記録）は jev-decide.sh の責務で、本スクリプトは判定を返すだけ。shadow 並走は行わない（ADR-059）。
#
# 有効化（両方が揃ったときだけ通信する。既定は Off）:
#   FF_JEV_ENABLED=1            … オプトインのスイッチ。未設定 / 1 以外は「無効」で非 0
#   API キー                    … 次の順で解決する。値は stdout / stderr / argv に出さない
#     1. TYPESAFE_API_KEY（環境変数）
#     2. TYPESAFE_API_KEY_FILE（ファイルパス。**指定すると 3 の既定パスは見ない** —
#        指定先が無い / 読めないときは 3 へ落ちず、そのパスを名指しして exit 4）
#     3. ~/.config/ff-dev-toolkit/typesafe_api_key（既定パス。600 推奨）
#   ファイルの値は前後の空白・改行を落とす。キーは英数字と `._~+/=-` だけを許し、
#   それ以外（改行・引用符・バックスラッシュ等）を含む値は通信せず exit 4（key-invalid）
#   — curl の設定行へ差し込むため、改行が入ると別の設定行を注入できてしまう。
#   スイッチとキーを分けるのは、キーがあるだけで課金経路が開く形にしないため。
#
# 入力:
#   --questions <file>   … Jev の `questions` map（JSON object）。type は noul / choice / score。
#                          choice の option 名に `|` は使えない（ANSWER 行の区切りと衝突する）
#   --state-file <file>  … `state` の内容。JSON として妥当な object / array ならその構造のまま
#                          渡し、そうでなければ文字列として渡す。省略時は stdin を読む
#   --json               … 出力を 1 行 JSON にする（既定は KEY=value 行）
#   --check              … 事前確認だけ。通信しない
#
# 出力プロトコル（stdout）:
#   既定（行頭一致で機械可読）:
#     JEV_OK=1
#     JEV_MODEL=<応答の model>
#     JEV_LATENCY_MS=<整数。成功した試行 1 回ぶん。バックオフ待ちは含めない>
#     JEV_INPUT_TOKENS=<整数>
#     JEV_OUTPUT_TOKENS=<整数>
#     JEV_COST_USD=<小数>
#     JEV_RETRIES=<整数>
#     ANSWER=<id>|<type>|<value>|<confidence>   … 質問ごと（noul の confidence は |p-0.5|*2 を 4 桁へ丸め）
#   --json:
#     {"ok":true,"model":..,"answers":{..},"usage":{..},"latency_ms":..,"cost_usd":..,
#      "retries":..,"input_bytes":..}
#   失敗時（既定）: JEV_OK=0 と JEV_ERROR=<kind> を stdout へ、理由を stderr へ
#   失敗時（--json）: {"ok":false,"error":<kind>,"message":<理由>} を 1 行
#
# 終了コード（種別を名乗る。判定不能を 0 で返さない）:
#   0   成功
#   2   入力不正（questions が無い / JSON でない / state が空 / サイズ予算超過）
#   3   無効（FF_JEV_ENABLED が 1 でない）
#   4   キー未設定 / キー不正（key-missing / key-invalid）
#   5   401 Unauthorized
#   6   422 Unprocessable Entity（stderr へ応答本文を出す）
#   7   429 / 529 がリトライ上限まで続いた
#   8   その他の HTTP / 通信失敗 / 一時領域を作れない（kind: http-<status> / transport / tmp-unavailable）
#   9   応答を解釈できない（answers / usage が無い、要求した qid の欠落、type 不一致、値の型不正）
#   64  使い方の誤り（引数、または数値であるべき FF_JEV_* が数値でない）
#   69  依存が無い（jq / curl）
#
# サイズ予算（公式: 64K tok / request、state + 最長 1 質問で 32K tok）:
#   トークン計数器を持たないので**バイト数**で見る（`LC_ALL=C` で数える。文字数で数えると
#   日本語は 3 倍ずれる）。既定は FF_JEV_MAX_STATE_BYTES=64000（state + 最長 1 質問）/
#   FF_JEV_MAX_REQUEST_BYTES=128000（state + 全質問）。日本語 UTF-8 は 1 文字 3 バイトで
#   1〜1.5 トークンなので、64000 バイトは 1 文字 1 tok なら約 2.1 万、1.5 tok なら上限の
#   32K に達しうる。日本語主体の state で上限近くまで使うなら既定を下げる。超えたら送らずに
#   exit 2 で名乗る。
#
# リトライ（429 / 529）:
#   FF_JEV_MAX_RETRIES=4（上限 4 回 = 最大 5 回呼ぶ）、FF_JEV_RETRY_BASE_SECONDS=1 の
#   指数バックオフ（1, 2, 4, 8 秒）。Retry-After ヘッダが秒数ならそちらを優先するが、
#   FF_JEV_MAX_RETRY_AFTER_SECONDS=60 で頭打ちにする（応答の値で無期限に眠らない）。
#   上限に達したら exit 7。
#
# 価格: FF_JEV_PRICE_PER_MTOK_USD=0.042（2026-09 の公表値。入力トークン課金のみ）。
#   出力の cost_usd は概算で、請求の正本ではない。
#
# 制約: bash 3.2 互換（連想配列・mapfile 禁止）。依存は jq と curl。キーの文字種検査は C ロケールで
#       行う（ja_JP.UTF-8 では `[A-Za-z0-9]` の範囲照合が見た目どおりに効かない）。
set -uo pipefail
export LC_ALL=C

JEV_API_URL="${TYPESAFE_API_URL:-https://api.typesafe.ai/v1/systemone}"
JEV_MODEL="${TYPESAFE_MODEL:-jev-latest}"
KEY_DEFAULT_PATH="${HOME}/.config/ff-dev-toolkit/typesafe_api_key"
MAX_STATE_BYTES="${FF_JEV_MAX_STATE_BYTES:-64000}"
MAX_REQUEST_BYTES="${FF_JEV_MAX_REQUEST_BYTES:-128000}"
MAX_RETRIES="${FF_JEV_MAX_RETRIES:-4}"
RETRY_BASE="${FF_JEV_RETRY_BASE_SECONDS:-1}"
MAX_RETRY_AFTER="${FF_JEV_MAX_RETRY_AFTER_SECONDS:-60}"
PRICE_PER_MTOK="${FF_JEV_PRICE_PER_MTOK_USD:-0.042}"

QUESTIONS_FILE=""
STATE_FILE=""
OUT_JSON=0
CHECK_ONLY=0

usage() {
  sed -n '2,/^set -uo pipefail/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'
}

fail() { # $1=exit code $2=kind $3=message
  local rc="$1" kind="$2" msg="$3"
  if [ "$OUT_JSON" -eq 1 ]; then
    jq -cn --arg kind "$kind" --arg msg "$msg" '{ok:false,error:$kind,message:$msg}'
  else
    echo "JEV_OK=0"
    echo "JEV_ERROR=${kind}"
  fi
  echo "jev-judge: ${msg}" >&2
  exit "$rc"
}

while [ $# -gt 0 ]; do
  case "$1" in
    --questions) [ $# -ge 2 ] || { usage >&2; exit 64; }; QUESTIONS_FILE="$2"; shift 2 ;;
    --state-file) [ $# -ge 2 ] || { usage >&2; exit 64; }; STATE_FILE="$2"; shift 2 ;;
    --json) OUT_JSON=1; shift ;;
    --check) CHECK_ONLY=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 64 ;;
  esac
done

# ---- 依存 ----------------------------------------------------------------------
for dep in jq curl; do
  command -v "$dep" >/dev/null 2>&1 || fail 69 "missing-dependency" "依存コマンドがありません: ${dep}"
done

# ---- 数値であるべき設定（非数値を「上限なし」へ倒さない）---------------------------
require_uint() { # $1=変数名 $2=値
  case "$2" in
    ''|*[!0-9]*) fail 64 "bad-config" "${1} は 0 以上の整数である必要があります（値は出しません）" ;;
  esac
}
require_uint FF_JEV_MAX_STATE_BYTES "$MAX_STATE_BYTES"
require_uint FF_JEV_MAX_REQUEST_BYTES "$MAX_REQUEST_BYTES"
require_uint FF_JEV_MAX_RETRIES "$MAX_RETRIES"
require_uint FF_JEV_RETRY_BASE_SECONDS "$RETRY_BASE"
require_uint FF_JEV_MAX_RETRY_AFTER_SECONDS "$MAX_RETRY_AFTER"
case "$PRICE_PER_MTOK" in
  ''|*[!0-9.]*|*.*.*) fail 64 "bad-config" "FF_JEV_PRICE_PER_MTOK_USD は小数である必要があります" ;;
esac

# ---- 有効化スイッチ（キーより先に見る。無効なときはキーの有無を名乗らない）------
if [ "${FF_JEV_ENABLED:-}" != "1" ]; then
  fail 3 "disabled" "Jev は無効です（FF_JEV_ENABLED=1 を設定すると有効になります。既定は Off）"
fi

# ---- キー解決（値は一切出力しない）--------------------------------------------
API_KEY=""
if [ -n "${TYPESAFE_API_KEY:-}" ]; then
  API_KEY="$TYPESAFE_API_KEY"
elif [ -n "${TYPESAFE_API_KEY_FILE:-}" ]; then
  [ -e "$TYPESAFE_API_KEY_FILE" ] || fail 4 "key-missing" "TYPESAFE_API_KEY_FILE のファイルがありません: ${TYPESAFE_API_KEY_FILE}"
  [ -r "$TYPESAFE_API_KEY_FILE" ] || fail 4 "key-missing" "TYPESAFE_API_KEY_FILE のファイルを読めません（権限を確認）: ${TYPESAFE_API_KEY_FILE}"
  API_KEY="$(tr -d '\r\n' < "$TYPESAFE_API_KEY_FILE")"
elif [ -e "$KEY_DEFAULT_PATH" ]; then
  [ -r "$KEY_DEFAULT_PATH" ] || fail 4 "key-missing" "既定パスのキーファイルを読めません（権限を確認）: ${KEY_DEFAULT_PATH}"
  API_KEY="$(tr -d '\r\n' < "$KEY_DEFAULT_PATH")"
fi
# 前後の空白を落とす（`Bearer k  ` を送らない）
API_KEY="$(printf '%s' "$API_KEY" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
if [ -z "$API_KEY" ]; then
  fail 4 "key-missing" "API キーが未設定です（TYPESAFE_API_KEY / TYPESAFE_API_KEY_FILE / ${KEY_DEFAULT_PATH} のいずれにも無い）"
fi
case "$API_KEY" in
  *[!A-Za-z0-9._~+/=-]*) fail 4 "key-invalid" "API キーに使えない文字が含まれています（英数字と ._~+/=- のみ。値は出しません）" ;;
esac

if [ "$CHECK_ONLY" -eq 1 ]; then
  if [ "$OUT_JSON" -eq 1 ]; then
    jq -cn --arg model "$JEV_MODEL" --arg url "$JEV_API_URL" '{ok:true,check:true,model:$model,url:$url}'
  else
    echo "JEV_OK=1"
    echo "JEV_CHECK=1"
    echo "JEV_MODEL=${JEV_MODEL}"
  fi
  exit 0
fi

# ---- 入力 ----------------------------------------------------------------------
[ -n "$QUESTIONS_FILE" ] || fail 2 "invalid-input" "--questions <file> が必要です"
[ -r "$QUESTIONS_FILE" ] || fail 2 "invalid-input" "questions を読めません: ${QUESTIONS_FILE}"
jq -e 'type == "object" and length > 0' "$QUESTIONS_FILE" >/dev/null 2>&1 \
  || fail 2 "invalid-input" "questions は空でない JSON object である必要があります: ${QUESTIONS_FILE}"
jq -e 'all(.[]; (.type == "noul" or .type == "choice" or .type == "score") and has("instructions"))' \
  "$QUESTIONS_FILE" >/dev/null 2>&1 \
  || fail 2 "invalid-input" "questions の各要素は type(noul|choice|score) と instructions を持つ必要があります"
jq -e 'all(.[]; .type != "choice" or ((.criteria | type == "object") and all(.criteria | keys[]; contains("|") | not)))' \
  "$QUESTIONS_FILE" >/dev/null 2>&1 \
  || fail 2 "invalid-input" "choice の criteria は object で、option 名に | を含められません"
jq -e 'all(.[]; .type != "score" or ((.criteria | type == "array") and (.criteria | length >= 2)))' \
  "$QUESTIONS_FILE" >/dev/null 2>&1 \
  || fail 2 "invalid-input" "score の criteria は 2 要素以上の array である必要があります"

if [ -n "$STATE_FILE" ]; then
  [ -r "$STATE_FILE" ] || fail 2 "invalid-input" "state を読めません: ${STATE_FILE}"
  STATE_RAW="$(cat "$STATE_FILE")"
else
  STATE_RAW="$(cat)"
fi
[ -n "$(printf '%s' "$STATE_RAW" | tr -d '[:space:]')" ] || fail 2 "invalid-input" "state が空です"

# state は JSON として妥当な object / array なら構造のまま、そうでなければ文字列として渡す
if printf '%s' "$STATE_RAW" | jq -e 'type == "object" or type == "array"' >/dev/null 2>&1; then
  STATE_JSON="$(printf '%s' "$STATE_RAW" | jq -c .)"
else
  STATE_JSON="$(printf '%s' "$STATE_RAW" | jq -Rs .)"
fi

# ---- サイズ予算（バイトで数える。awk の length は LC_ALL=C でないと文字数になる）-------
state_bytes=$(printf '%s' "$STATE_JSON" | LC_ALL=C wc -c | tr -d ' ')
longest_q_bytes=$(jq -c '.[]' "$QUESTIONS_FILE" | LC_ALL=C awk '{ n = length($0); if (n > m) m = n } END { print m + 0 }')
all_q_bytes=$(jq -c . "$QUESTIONS_FILE" | LC_ALL=C wc -c | tr -d ' ')
if [ $((state_bytes + longest_q_bytes)) -gt "$MAX_STATE_BYTES" ]; then
  fail 2 "over-budget" "state + 最長 1 質問が予算を超えています: $((state_bytes + longest_q_bytes)) > ${MAX_STATE_BYTES} bytes（FF_JEV_MAX_STATE_BYTES）"
fi
if [ $((state_bytes + all_q_bytes)) -gt "$MAX_REQUEST_BYTES" ]; then
  fail 2 "over-budget" "state + 全質問が予算を超えています: $((state_bytes + all_q_bytes)) > ${MAX_REQUEST_BYTES} bytes（FF_JEV_MAX_REQUEST_BYTES）"
fi

REQUEST_BODY="$(jq -cn --argjson state "$STATE_JSON" --arg model "$JEV_MODEL" --slurpfile q "$QUESTIONS_FILE" \
  '{state:$state, model:$model, questions:$q[0]}')" \
  || fail 2 "invalid-input" "リクエスト本文を組み立てられません"

# ---- 通信 ----------------------------------------------------------------------
# キーは `curl -K -`（設定を stdin から読む）で渡す。argv に載せると ps で見え、
# 一時ファイルに書くと消し忘れが残る。本文は argv に載せず一時ファイルから読む
# （最大 128KB を argv に置かない）。応答本文は stdout、HTTP ステータスは末尾行。
if WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/jev-judge.XXXXXX" 2>&1)" && [ -d "$WORK_DIR" ]; then
  :
else
  fail 8 "tmp-unavailable" "一時領域を作れません（TMPDIR=${TMPDIR:-/tmp}）: ${WORK_DIR}"
fi
trap 'rm -rf "$WORK_DIR"' EXIT
printf '%s' "$REQUEST_BODY" > "$WORK_DIR/body.json"

now_ms() {
  local ns
  ns="$(date +%s%N 2>/dev/null)"
  case "$ns" in
    ''|*[!0-9]*)
      # macOS の date は %N を解さない（"N" が残る）。perl があればミリ秒、無ければ秒×1000
      perl -MTime::HiRes=time -e 'printf("%d\n", time()*1000)' 2>/dev/null || echo $(( $(date +%s) * 1000 )) ;;
    *) echo $(( ns / 1000000 )) ;;
  esac
}

do_request() { # stdout: 本文 + 改行 + ステータス行。応答ヘッダは $WORK_DIR/headers へ
  local out rc
  : > "$WORK_DIR/headers"
  out="$(printf 'url = "%s"\nheader = "Authorization: Bearer %s"\nheader = "Content-Type: application/json"\nsilent\nshow-error\nmax-time = 120\n' "$JEV_API_URL" "$API_KEY" \
    | curl -K - -X POST --data-binary "@$WORK_DIR/body.json" -D "$WORK_DIR/headers" -w '\n%{http_code}' 2>&1)"
  rc=$?
  printf '%s\n' "$out"
  return "$rc"
}
# Retry-After はコマンド置換のサブシェルから変数で返せないので、呼び出し側でファイルから読む
retry_after_header() {
  tr -d '\r' < "$WORK_DIR/headers" | awk 'tolower($1) == "retry-after:" { print $2; exit }'
}

retries=0
LATENCY_MS=0
while :; do
  t0=$(now_ms)
  RESP="$(do_request)"; curl_rc=$?
  t1=$(now_ms)
  RETRY_AFTER="$(retry_after_header)"
  HTTP_STATUS="$(printf '%s\n' "$RESP" | tail -n 1)"
  BODY="$(printf '%s\n' "$RESP" | sed '$d')"
  if [ "$curl_rc" -ne 0 ]; then
    fail 8 "transport" "curl が失敗しました (rc=${curl_rc}): $(printf '%s' "$BODY" | head -c 300)"
  fi
  case "$HTTP_STATUS" in
    200) LATENCY_MS=$((t1 - t0)); break ;;
    401) fail 5 "unauthorized" "401 Unauthorized: API キーが無効です" ;;
    422) fail 6 "unprocessable" "422 Unprocessable Entity: $(printf '%s' "$BODY" | head -c 600)" ;;
    429|529)
      if [ "$retries" -ge "$MAX_RETRIES" ]; then
        fail 7 "rate-limited" "${HTTP_STATUS} がリトライ上限（${MAX_RETRIES} 回）まで続きました"
      fi
      case "$RETRY_AFTER" in
        ''|*[!0-9]*) wait_s=$(( RETRY_BASE * (1 << retries) )) ;;
        *) wait_s="$RETRY_AFTER" ;;
      esac
      [ "$wait_s" -le "$MAX_RETRY_AFTER" ] || wait_s="$MAX_RETRY_AFTER"
      retries=$((retries + 1))
      echo "jev-judge: ${HTTP_STATUS} → ${wait_s}s 待って再試行 (${retries}/${MAX_RETRIES})" >&2
      sleep "$wait_s"
      ;;
    ''|*[!0-9]*) fail 8 "transport" "HTTP ステータスを読めません: $(printf '%s' "$RESP" | head -c 300)" ;;
    *) fail 8 "http-${HTTP_STATUS}" "HTTP ${HTTP_STATUS}: $(printf '%s' "$BODY" | head -c 300)" ;;
  esac
done

# ---- 応答の解釈（要求した qid が全部あり、type が一致し、値が正しい型であること）-------
printf '%s' "$BODY" | jq -e --slurpfile q "$QUESTIONS_FILE" '
  . as $r |
  ($r.answers | type == "object")
  and ($r.usage.input_tokens | type == "number")
  and (($q[0] | keys) - ($r.answers | keys) | length == 0)
  and all($q[0] | keys[]; . as $id | ($r.answers[$id].type == $q[0][$id].type))
  and all($r.answers[];
        (.type == "noul" and (.noul | type == "number"))
     or (.type == "choice" and (.choice | type == "string") and (.confidence | type == "number") and (.probabilities | type == "object"))
     or (.type == "score" and (.score | type == "number") and (.confidence | type == "number") and (.legend | type == "object")))
' >/dev/null 2>&1 \
  || fail 9 "bad-response" "応答が契約と違います（answers / usage の欠落、要求 qid の欠落、type 不一致、値の型不正のいずれか）: $(printf '%s' "$BODY" | head -c 300)"

RESULT="$(printf '%s' "$BODY" | jq -c \
  --argjson latency "$LATENCY_MS" --argjson retries "$retries" \
  --argjson input_bytes "$((state_bytes + all_q_bytes))" --arg price "$PRICE_PER_MTOK" '
  # 派生 confidence は 4 桁へ丸める（0.95 → 0.8999… の浮動小数表示を出さない）
  def conf: if .type == "noul" then ((((.noul - 0.5) | if . < 0 then -. else . end) * 2 * 10000) | round) / 10000 else .confidence end;
  def value: if .type == "noul" then .noul elif .type == "choice" then .choice else .score end;
  {
    ok: true,
    model: .model,
    answers: (.answers | with_entries(.value |= (. + {value: value, confidence: conf}))),
    usage: .usage,
    latency_ms: $latency,
    cost_usd: ((((.usage.input_tokens * ($price | tonumber)) / 1000000) * 10000000000 | round) / 10000000000),
    retries: $retries,
    input_bytes: $input_bytes
  }')"; jq_rc=$?
[ "$jq_rc" -eq 0 ] && [ -n "$RESULT" ] \
  || fail 9 "bad-response" "応答を変換できません (jq rc=${jq_rc}): $(printf '%s' "$BODY" | head -c 300)"

if [ "$OUT_JSON" -eq 1 ]; then
  printf '%s\n' "$RESULT"
else
  printf '%s' "$RESULT" | jq -r '
    "JEV_OK=1",
    "JEV_MODEL=\(.model)",
    "JEV_LATENCY_MS=\(.latency_ms)",
    "JEV_INPUT_TOKENS=\(.usage.input_tokens)",
    "JEV_OUTPUT_TOKENS=\(.usage.output_tokens // 0)",
    "JEV_COST_USD=\(.cost_usd)",
    "JEV_RETRIES=\(.retries)",
    (.answers | to_entries[] | "ANSWER=\(.key)|\(.value.type)|\(.value.value)|\(.value.confidence)")'
fi
exit 0
