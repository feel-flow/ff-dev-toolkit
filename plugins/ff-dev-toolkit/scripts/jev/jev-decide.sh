#!/usr/bin/env bash
#
# jev-decide.sh — 判定点の切替入口（FF_JEV_MODE の二段構え）
#
# 使い方:
#   jev-decide.sh <判定点> --questions <questions.json> [--state-file <file>] [--fill KEY=<file> ...] [--json]
#   jev-decide.sh <判定点> --questions <questions.json> < state.txt
#   jev-decide.sh --status [--json]         … 実効設定の表示（通信しない）
#   jev-decide.sh --summarize [--log <f>]   … 記録の集計（通信しない）
#   jev-decide.sh --overturn <決定 id> [--log <f>] [--note <text>] … 採用した判定を後で人が覆した記録
#
# 何のためにあるか:
#   ワークフローの判定点（/ace-curate の新規性、/retrospective の観測同一性 …）で、Jev の判定を
#   **採用するか従来経路へ落とすか**を 1 つの契約で決める。jev-judge.sh は「state + 質問 → 判定」
#   だけを返し採否を持たない。採否（閾値・opt-out・記録）をここへ集めるのは、判定点ごとに
#   閾値と fallback の書き方がばらけると「on にしたのに何が変わったか」を測れなくなるため。
#
# 二段構え（利用者決定 2026-09-22。shadow 並走はしない）:
#   FF_JEV_MODE=off（既定） … Jev を呼ばない。記録も書かない。呼び出し元は従来経路をそのまま行う。
#                             **従来経路とバイト同一**が契約（本スクリプトは exit 12 を返すだけ）
#   FF_JEV_MODE=on           … 判定点ごとに Jev を先に 1 回呼ぶ。全質問の confidence が閾値以上なら
#                             判定を**採用**（exit 0）。閾値未満は exit 10、Jev の失敗は exit 11 で、
#                             呼び出し元はその判定点だけ従来経路へ落ちる。二重走行はしない。
#   いつでも off へ戻せる（env を外すだけ。キーファイルは残してよい）。
#
# 環境変数（すべて任意。値は stdout / stderr に出さない）:
#   FF_JEV_MODE                    off | on（既定 off。それ以外は exit 64）
#   FF_JEV_POINTS                  on のとき Jev を使う判定点の名簿（空白またはカンマ区切り。
#                                  既定 "novelty retro"。**設定済みの空値は「0 件」**で、全判定点が
#                                  従来経路になる — ACE-418-2。名簿に無い判定点は exit 12）
#   FF_JEV_MIN_CONFIDENCE          採用の閾値（0〜1 の小数）。共通既定は 0.99（Choice / Score の confidence 向け。
#                                  独立評価 priorbench/jev で精度が 0.99 で跳ぶ崖を根拠にした）。
#                                  ただし Noul の判定点 novelty / retro は**組み込み既定 0.6** — Noul の
#                                  confidence（|p−0.5|×2）は実測で最大 0.94 までしか出ず、0.99 だと採用率 0% に
#                                  なる。0.6 は offline 評価（recent-candidates 225 件: ≥ 0.6 帯が占有 64% で
#                                  一致 99.3%）から引いた（ADR-059。README 末尾の帯別表）。型を跨いで閾値を
#                                  流用しない（公式 jaggedness: Noul と Choice の閾値は互換でない）
#   FF_JEV_MIN_CONFIDENCE_<POINT>  判定点別の上書き（<POINT> は判定点名を大文字化し `-` を `_` に）。
#                                  解決順は 判定点別 env → 共通 env → 判定点の組み込み既定 → 共通既定
#   FF_JEV_DECISION_LOG            記録先（既定 ${XDG_STATE_HOME:-$HOME/.local/state}/ff-dev-toolkit/jev-decisions/
#                                  <git root か cwd の basename>-<そのパスのハッシュ 8 桁>.jsonl。**作業ツリーの外**に置く —
#                                  ツリー内に置くと untracked ファイルが /ace-curate の clean ゲートと /merge-cleanup の
#                                  未コミット検査を赤にする。書けなければ採用せず exit 11 `log-unwritable`）
#   TYPESAFE_MODEL                 未指定なら on のとき **jev-1.13.0 に固定**する（閾値を較正した版。
#                                  `jev-latest` の移動で閾値が狂わないため）。明示指定はそのまま通す
#   FF_JEV_ENABLED / キー           jev-judge.sh の規定どおり（on だけでは課金経路は開かない。
#                                  無ければ exit 11 `disabled` / `key-missing` で従来経路へ）
#
# 入力:
#   <判定点>             … 英小文字・数字・`-`。名簿の照合と記録のキーに使う
#   --questions <file>   … jev-judge.sh と同じ questions map。`"{{KEY}}"` という文字列値は
#                          --fill KEY=<file> の内容で置換できる（同梱 fixture の候補文など）。
#                          置換されずに残った `{{...}}` があれば送らず exit 2
#   --state-file <file>  … state。省略時は stdin
#   --fill KEY=<file>    … 置換（複数可。KEY は英大文字・数字・`_`）
#   --json               … 出力を 1 行 JSON にする
#
# 出力（stdout。既定は KEY=value 行）:
#   JEV_DECISION=adopt|fallback|off|error   … error は exit 2（入力不正。従来経路へ落とさず直す）
#   JEV_REASON=<kind>        … adopt は `confident`、fallback は low-confidence / disabled / key-missing /
#                              unauthorized / rate-limited / bad-response / log-unwritable など、off は
#                              mode-off / point-not-listed
#   JEV_DECISION_ID=<id>     … 記録の行 id（adopt / fallback のうち記録を書けた回。--overturn に渡す）
#   JEV_THRESHOLD=<小数>     … 同上
#   JEV_MODEL=<応答の model> … 同上
#   ANSWER=<qid>|<type>|<value>|<confidence>  … 質問ごと（adopt と low-confidence のとき）
#   --json: {"decision":..,"reason":..,"id":..,"threshold":..,"model":..,"answers":{..},"latency_ms":..,
#            "usage":{..},"cost_usd":..}
#
# 終了コード（判定不能を 0 で返さない。呼び出し元は 0 のときだけ Jev の判定を使う）:
#   0   adopt            … 全質問の confidence ≥ 閾値。記録済み
#   10  fallback         … confidence < 閾値（記録済み）
#   11  fallback         … Jev の失敗（jev-judge の exit 2〜9・64・69 と disabled / key-missing）、一時領域を
#                          作れない（tmp-unavailable）、または記録先へ書けない・記録行を組み立てられない
#                          （log-unwritable。採用条件を満たしていても記録が無ければ採用しない）
#   12  off              … FF_JEV_MODE が on でない、または判定点が名簿に無い。通信しない・記録しない
#   2   入力不正         … questions が無い / JSON でない / 置換されない `{{...}}` が残る / --fill のファイルが
#                          読めない / state が無い・空
#   64  使い方の誤り     … 引数、FF_JEV_MODE の未知の値、閾値が 0〜1 の小数でない、判定点名の不正
#   69  依存が無い（jq）
#
# 記録（追記専用 JSONL。1 決定 1 行。作業ツリーの外に置くので knowledge: コミットにも clean ゲートにも掛からない）:
#   {"event":"decision","id":..,"ts":..,"point":..,"decision":..,"reason":..,"threshold":..,"model":..,
#    "answers":{qid:{type,value,confidence}},"latency_ms":..,"usage":{..},"cost_usd":..,"state_sha256":..,
#    "state_bytes":..}
#   {"event":"overturn","ref":<決定 id>,"ts":..,"note":..}   … --overturn
#   --summarize は判定点別に adopt / fallback（理由別）の件数、帯別（≥0.6 / ≥0.9 / ≥0.95 / ≥0.99。Noul の
#   判定点は 0.95 以上がほぼ出ないので ≥0.6 の帯と overturned 率を見る）の件数と、
#   adopt のうち overturn された件数・率を表で出す。記録が無い・読めない行があるときは exit 2
#   （空を「全件採用率 0%」の表にしない）
#
# 制約: bash 3.2 互換（連想配列・mapfile 禁止）。依存は jq。通信は jev-judge.sh に委ねる。
#       文字種検査（判定点名・--fill の KEY・--overturn の id）は C ロケールで行う — ja_JP.UTF-8 では
#       `[a-z]` の範囲照合が大文字も通し（`Novelty` が名簿照合を抜ける）、検査が見た目どおりに効かない。
set -uo pipefail
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
JUDGE="$SCRIPT_DIR/jev-judge.sh"

MODE="${FF_JEV_MODE:-off}"
POINTS_DEFAULT="novelty retro"
THRESHOLD_DEFAULT="0.99"
# Noul の判定点の組み込み既定（ヘッダ「FF_JEV_MIN_CONFIDENCE」参照）。名前 → 閾値
builtin_threshold() { # $1=判定点 → stdout（無ければ空）
  case "$1" in
    novelty|retro) printf '%s\n' "0.6" ;;
    *) printf '' ;;
  esac
}
MODEL_PINNED="jev-1.13.0"

POINT=""
QUESTIONS_FILE=""
STATE_FILE=""
OUT_JSON=0
ACTION="decide"
LOG_OVERRIDE=""
OVERTURN_REF=""
OVERTURN_NOTE=""
FILL_KEYS=""
FILL_FILES=""

usage() {
  sed -n '2,/^set -uo pipefail/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'
}

emit_fail() { # $1=rc $2=decision $3=reason $4=message（stderr）[$5=記録の行 id（書けた回だけ）]
  local rc="$1" decision="$2" reason="$3" msg="$4" id="${5:-}"
  if [ "$OUT_JSON" -eq 1 ]; then
    if command -v jq >/dev/null 2>&1; then
      jq -cn --arg d "$decision" --arg r "$reason" --arg m "$msg" --arg id "$id" \
        '{decision:$d,reason:$r,message:$m} + (if $id == "" then {} else {id:$id} end)'
    else
      printf '{"decision":"%s","reason":"%s"}\n' "$decision" "$reason"
    fi
  else
    echo "JEV_DECISION=${decision}"
    echo "JEV_REASON=${reason}"
    [ -n "$id" ] && echo "JEV_DECISION_ID=${id}"
  fi
  [ -n "$msg" ] && echo "jev-decide: ${msg}" >&2
  exit "$rc"
}

while [ $# -gt 0 ]; do
  case "$1" in
    --questions) [ $# -ge 2 ] || { usage >&2; exit 64; }; QUESTIONS_FILE="$2"; shift 2 ;;
    --state-file) [ $# -ge 2 ] || { usage >&2; exit 64; }; STATE_FILE="$2"; shift 2 ;;
    --fill)
      [ $# -ge 2 ] || { usage >&2; exit 64; }
      case "$2" in
        *=*) ;;
        *) echo "jev-decide: --fill は KEY=<file> の形です" >&2; exit 64 ;;
      esac
      k="${2%%=*}"; f="${2#*=}"
      case "$k" in
        ''|*[!A-Z0-9_]*) echo "jev-decide: --fill の KEY は英大文字・数字・_ だけです" >&2; exit 64 ;;
      esac
      FILL_KEYS="${FILL_KEYS}${k}"$'\n'
      FILL_FILES="${FILL_FILES}${f}"$'\n'
      shift 2 ;;
    --json) OUT_JSON=1; shift ;;
    --status) ACTION="status"; shift ;;
    --summarize) ACTION="summarize"; shift ;;
    --overturn) [ $# -ge 2 ] || { usage >&2; exit 64; }; ACTION="overturn"; OVERTURN_REF="$2"; shift 2 ;;
    --note) [ $# -ge 2 ] || { usage >&2; exit 64; }; OVERTURN_NOTE="$2"; shift 2 ;;
    --log) [ $# -ge 2 ] || { usage >&2; exit 64; }; LOG_OVERRIDE="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    --*) usage >&2; exit 64 ;;
    *)
      if [ -z "$POINT" ] && [ "$ACTION" = "decide" ]; then POINT="$1"; shift
      else usage >&2; exit 64; fi ;;
  esac
done

# ---- 設定の検証（値は出さない）---------------------------------------------------
case "$MODE" in
  on|off) ;;
  *) echo "jev-decide: FF_JEV_MODE は on か off です（未知の値）" >&2; exit 64 ;;
esac
# jq は off の判定（mode / 名簿）には要らない。off の経路は依存にも触れず exit 12 で返す契約なので、
# 依存検査は off ゲートの後（decide）と各サブコマンドの先頭に置く
require_jq() { command -v jq >/dev/null 2>&1 || { echo "jev-decide: 依存コマンドがありません: jq" >&2; exit 69; }; }

is_unit_decimal() { # 0〜1 の小数（"1" / "0.99" / ".5" を許し、"1.5" / "abc" / "" / "." を拒否）
  case "$1" in
    ''|*[!0-9.]*|*.*.*) return 1 ;;
  esac
  case "$1" in
    *[0-9]*) ;;
    *) return 1 ;;   # "." は文字種検査を通るが awk が 0 と読む — 数字を 1 つは要求する
  esac
  case "$1" in
    *.) return 1 ;;  # "1." は jq の tonumber が読めず記録行を組み立てられない
  esac
  # 0 は「全件採用」（confidence 0 でも採る）で、1.5 の「全件 fallback」と対の危険側 — 0 より大きいことを要求する
  awk -v v="$1" 'BEGIN { if (v + 0 > 0 && v + 0 <= 1) exit 0; exit 1 }'
}
is_point_name() { # 判定点名: 英小文字・数字・-（LC_ALL=C 前提）
  case "$1" in
    ''|*[!a-z0-9-]*) return 1 ;;
  esac
  return 0
}

resolve_log_path() {
  if [ -n "$LOG_OVERRIDE" ]; then printf '%s\n' "$LOG_OVERRIDE"; return; fi
  if [ -n "${FF_JEV_DECISION_LOG:-}" ]; then printf '%s\n' "$FF_JEV_DECISION_LOG"; return; fi
  # 作業ツリーの外（XDG state）へ、リポジトリごとに 1 ファイル。ツリー内に置くと untracked ファイルが
  # 呼び出し元スキルの clean ゲートを赤にする（/ace-curate Phase 3・/merge-cleanup）
  local root base hash
  root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
  base="$(basename "$root" | tr -d '\n' | tr -c 'A-Za-z0-9._-' '_')"   # 改行を先に落とす（tr -c が改行も _ にする）
  if command -v shasum >/dev/null 2>&1; then hash="$(printf '%s' "$root" | shasum -a 256 | cut -c1-8)"
  elif command -v sha256sum >/dev/null 2>&1; then hash="$(printf '%s' "$root" | sha256sum | cut -c1-8)"
  else hash="$(printf '%s' "$root" | cksum | awk '{print $1}')"; fi
  printf '%s/ff-dev-toolkit/jev-decisions/%s-%s.jsonl\n' "${XDG_STATE_HOME:-$HOME/.local/state}" "$base" "$hash"
}
LOG_PATH=""   # 使う直前に resolve_log_path で決める（off の経路は記録先にも外部コマンドにも触れない）

point_listed() { # $1=判定点。名簿は空白 / カンマ区切り。設定済みの空値は 0 件
  local list p
  if [ "${FF_JEV_POINTS+set}" = "set" ]; then list="$FF_JEV_POINTS"; else list="$POINTS_DEFAULT"; fi
  list="$(printf '%s' "$list" | tr ',' ' ')"
  for p in $list; do
    # 名簿の綴り違い（`Novelty` 等）を「その判定点は off」へ黙って倒さない — 設定の誤りとして止める
    is_point_name "$p" || { echo "jev-decide: FF_JEV_POINTS に不正な判定点名があります（英小文字・数字・- だけ）" >&2; exit 64; }
    [ "$p" = "$1" ] && return 0
  done
  return 1
}

resolve_threshold() { # $1=判定点 → stdout。判定点別 → 共通 → 既定
  local up var val
  up="$(printf '%s' "$1" | tr 'a-z-' 'A-Z_')"
  var="FF_JEV_MIN_CONFIDENCE_${up}"
  val="$(eval "printf '%s' \"\${${var}:-}\"")"
  if [ -n "$val" ]; then
    is_unit_decimal "$val" || { echo "jev-decide: ${var} は 0 より大きく 1 以下の小数である必要があります" >&2; exit 64; }
    printf '%s\n' "$val"; return
  fi
  if [ -n "${FF_JEV_MIN_CONFIDENCE:-}" ]; then
    is_unit_decimal "$FF_JEV_MIN_CONFIDENCE" || { echo "jev-decide: FF_JEV_MIN_CONFIDENCE は 0 より大きく 1 以下の小数である必要があります" >&2; exit 64; }
    printf '%s\n' "$FF_JEV_MIN_CONFIDENCE"; return
  fi
  val="$(builtin_threshold "$1")"
  if [ -n "$val" ]; then printf '%s\n' "$val"; return; fi
  printf '%s\n' "$THRESHOLD_DEFAULT"
}

now_iso() { date -u +%Y-%m-%dT%H:%M:%SZ; }

# ---- --status ---------------------------------------------------------------------
if [ "$ACTION" = "status" ]; then
  require_jq
  LOG_PATH="$(resolve_log_path)"
  if [ "${FF_JEV_POINTS+set}" = "set" ]; then points="$FF_JEV_POINTS"; else points="$POINTS_DEFAULT"; fi
  thr="${FF_JEV_MIN_CONFIDENCE:-$THRESHOLD_DEFAULT}"
  is_unit_decimal "$thr" || { echo "jev-decide: FF_JEV_MIN_CONFIDENCE は 0 より大きく 1 以下の小数である必要があります" >&2; exit 64; }
  model="${TYPESAFE_MODEL:-$MODEL_PINNED}"
  enabled="${FF_JEV_ENABLED:-}"
  [ "$enabled" = "1" ] && enabled="1" || enabled="0"
  per_point=""
  for p in $(printf '%s' "$points" | tr ',' ' '); do
    is_point_name "$p" || { echo "jev-decide: FF_JEV_POINTS に不正な判定点名があります（英小文字・数字・- だけ）" >&2; exit 64; }
    pt="$(resolve_threshold "$p")" || exit $?
    per_point="${per_point}${p}=${pt} "
  done
  per_point="${per_point% }"
  if [ "$OUT_JSON" -eq 1 ]; then
    jq -cn --arg mode "$MODE" --arg points "$points" --arg thr "$thr" --arg model "$model" \
      --arg log "$LOG_PATH" --argjson enabled "$enabled" --arg pp "$per_point" \
      '{mode:$mode,points:$points,threshold:($thr|tonumber),
        thresholds:($pp | split(" ") | map(select(length > 0) | split("=") | {key:.[0], value:(.[1]|tonumber)}) | from_entries),
        model:$model,log:$log,enabled:($enabled==1)}' \
      || { echo "jev-decide: --status の JSON を組み立てられません" >&2; exit 2; }
  else
    echo "JEV_MODE=${MODE}"
    echo "JEV_POINTS=${points}"
    echo "JEV_THRESHOLD=${thr}"
    for kv in $per_point; do
      up="$(printf '%s' "${kv%%=*}" | tr 'a-z-' 'A-Z_')"
      echo "JEV_THRESHOLD_${up}=${kv#*=}"
    done
    echo "JEV_MODEL=${model}"
    echo "JEV_LOG=${LOG_PATH}"
    echo "JEV_ENABLED=${enabled}"
  fi
  exit 0
fi

# ---- --overturn -------------------------------------------------------------------
if [ "$ACTION" = "overturn" ]; then
  require_jq
  LOG_PATH="$(resolve_log_path)"
  case "$OVERTURN_REF" in
    ''|*[!A-Za-z0-9._-]*) echo "jev-decide: --overturn の id が不正です" >&2; exit 64 ;;
  esac
  [ -s "$LOG_PATH" ] || { echo "jev-decide: 記録がありません: ${LOG_PATH}" >&2; exit 2; }
  jq -e --arg r "$OVERTURN_REF" 'select(.event == "decision" and .id == $r and .decision == "adopt")' "$LOG_PATH" >/dev/null 2>&1 \
    || { echo "jev-decide: 採用した決定 ${OVERTURN_REF} が記録にありません（覆せるのは adopt だけ）" >&2; exit 2; }
  line="$(jq -cn --arg r "$OVERTURN_REF" --arg ts "$(now_iso)" --arg note "$OVERTURN_NOTE" \
    '{event:"overturn",ref:$r,ts:$ts,note:$note}')"
  printf '%s\n' "$line" >> "$LOG_PATH" 2>/dev/null || { echo "jev-decide: 記録先へ書けません: ${LOG_PATH}" >&2; exit 11; }
  echo "JEV_OVERTURNED=${OVERTURN_REF}"
  exit 0
fi

# ---- --summarize ------------------------------------------------------------------
if [ "$ACTION" = "summarize" ]; then
  require_jq
  LOG_PATH="$(resolve_log_path)"
  [ -s "$LOG_PATH" ] || { echo "jev-decide: 記録がありません（空の表は出しません）: ${LOG_PATH}" >&2; exit 2; }
  # jq -e は最後の出力で終了コードを決めるので、1 行ずつの検査では途中の不正行が最後の正常行に隠れる。
  # -s で全行を配列にして all() で判定する（JSON として読めない行は jq 自体が非 0）
  if ! jq -e -s 'all(.[]; type == "object" and ((.event == "decision" and has("point") and has("decision") and has("answers")) or (.event == "overturn" and has("ref"))))' "$LOG_PATH" >/dev/null 2>&1; then
    echo "jev-decide: 記録に読めない行があります（集計しません）: ${LOG_PATH}" >&2; exit 2
  fi
  jq -e -s 'any(.[]; .event == "decision")' "$LOG_PATH" >/dev/null 2>&1 \
    || { echo "jev-decide: decision の行が 1 行もありません（集計しません）: ${LOG_PATH}" >&2; exit 2; }
  if [ "$OUT_JSON" -eq 1 ]; then
    SUMMARY_OUT="$(jq -s '
      def minconf: [.answers[]?.confidence] | if length == 0 then 0 else min end;
      (map(select(.event == "overturn")) | map(.ref)) as $ov
      | map(select(.event == "decision"))
      | group_by(.point)
      | map({
          point: .[0].point,
          total: length,
          adopt: (map(select(.decision == "adopt")) | length),
          fallback: (map(select(.decision == "fallback")) | group_by(.reason) | map({key: .[0].reason, value: length}) | from_entries),
          bands: {
            "ge_0.60": (map(select(minconf >= 0.60)) | length),
            "ge_0.90": (map(select(minconf >= 0.90)) | length),
            "ge_0.95": (map(select(minconf >= 0.95)) | length),
            "ge_0.99": (map(select(minconf >= 0.99)) | length)
          },
          overturned: (map(select(.decision == "adopt" and (.id as $i | $ov | index($i)) != null)) | length)
        })' "$LOG_PATH")" || { echo "jev-decide: 記録を集計できません（読めない形）: ${LOG_PATH}" >&2; exit 2; }
    printf '%s\n' "$SUMMARY_OUT"
  else
    SUMMARY_OUT="$(jq -r -s '
      def minconf: [.answers[]?.confidence] | if length == 0 then 0 else min end;
      def pct(a; b): if b == 0 then "-" else ((a * 1000 / b | round) / 10 | tostring) + "%" end;
      (map(select(.event == "overturn")) | map(.ref)) as $ov
      | map(select(.event == "decision"))
      | group_by(.point)
      | "| point | total | adopt | fallback(low-confidence) | fallback(error) | conf>=0.60 | conf>=0.90 | conf>=0.95 | conf>=0.99 | overturned/adopt |",
        "| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |",
        (.[] | . as $g
          | ($g | map(select(.decision == "adopt")) | length) as $ad
          | ($g | map(select(.decision == "adopt" and (.id as $i | $ov | index($i)) != null)) | length) as $ot
          | "| \($g[0].point) | \($g | length) | \($ad) | \($g | map(select(.decision == "fallback" and .reason == "low-confidence")) | length) | \($g | map(select(.decision == "fallback" and .reason != "low-confidence")) | length) | \($g | map(select(minconf >= 0.60)) | length) | \($g | map(select(minconf >= 0.90)) | length) | \($g | map(select(minconf >= 0.95)) | length) | \($g | map(select(minconf >= 0.99)) | length) | \($ot)/\($ad) (\(pct($ot; $ad))) |")' "$LOG_PATH")" || { echo "jev-decide: 記録を集計できません（読めない形）: ${LOG_PATH}" >&2; exit 2; }
    printf '%s\n' "$SUMMARY_OUT"
  fi
  exit 0
fi

# ---- decide -----------------------------------------------------------------------
is_point_name "$POINT" || { echo "jev-decide: 判定点名は英小文字・数字・- だけです（例 novelty）" >&2; exit 64; }

# off / 名簿外は入力を見る前に返す（通信も記録もしない）
if [ "$MODE" != "on" ]; then
  emit_fail 12 "off" "mode-off" ""
fi
point_listed "$POINT" || emit_fail 12 "off" "point-not-listed" ""
require_jq
LOG_PATH="$(resolve_log_path)"

THRESHOLD="$(resolve_threshold "$POINT")" || exit $?

[ -n "$QUESTIONS_FILE" ] || emit_fail 2 "error" "invalid-input" "--questions <file> が必要です"
[ -r "$QUESTIONS_FILE" ] || emit_fail 2 "error" "invalid-input" "questions を読めません: ${QUESTIONS_FILE}"

if WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/jev-decide.XXXXXX" 2>&1)" && [ -d "$WORK_DIR" ]; then
  :
else
  emit_fail 11 "fallback" "tmp-unavailable" "一時領域を作れません: ${WORK_DIR}"
fi
trap 'rm -rf "$WORK_DIR"' EXIT

# state を一度ファイルへ受ける（sha と bytes を記録するため）
if [ -n "$STATE_FILE" ]; then
  [ -r "$STATE_FILE" ] || emit_fail 2 "error" "invalid-input" "state を読めません: ${STATE_FILE}"
  cp "$STATE_FILE" "$WORK_DIR/state"
else
  cat > "$WORK_DIR/state"
fi
[ -n "$(tr -d '[:space:]' < "$WORK_DIR/state")" ] || emit_fail 2 "error" "invalid-input" "state が空です"
STATE_BYTES="$(LC_ALL=C wc -c < "$WORK_DIR/state" | tr -d ' ')"
if command -v shasum >/dev/null 2>&1; then
  STATE_SHA="$(shasum -a 256 "$WORK_DIR/state" | awk '{print $1}')"
elif command -v sha256sum >/dev/null 2>&1; then
  STATE_SHA="$(sha256sum "$WORK_DIR/state" | awk '{print $1}')"
else
  STATE_SHA="unavailable"
fi

# questions は JSON object であることを先に確かめる（jq の失敗を「プレースホルダ無し」へ読み替えない）
jq -e 'type == "object"' "$QUESTIONS_FILE" >/dev/null 2>&1 \
  || emit_fail 2 "error" "invalid-input" "questions は JSON object である必要があります: ${QUESTIONS_FILE}"
# 置換: 文字列値の中の "{{KEY}}" を --fill の内容で置き換える（値全体でも文中でも）
cp "$QUESTIONS_FILE" "$WORK_DIR/questions.json"
if [ -n "$FILL_KEYS" ]; then
  i=1
  while :; do
    k="$(printf '%s' "$FILL_KEYS" | sed -n "${i}p")"
    f="$(printf '%s' "$FILL_FILES" | sed -n "${i}p")"
    [ -n "$k" ] || break
    [ -f "$f" ] && [ -r "$f" ] || emit_fail 2 "error" "invalid-input" "--fill ${k} のファイルを読めません（存在しない・ディレクトリ・権限なし）: ${f}"
    [ -n "$(tr -d '[:space:]' < "$f")" ] || emit_fail 2 "error" "invalid-input" "--fill ${k} のファイルが空です（空の候補文を Jev へ送らない）: ${f}"
    jq --arg k "{{${k}}}" --rawfile v "$f" 'walk(if type == "string" then gsub($k; ($v | sub("\n$"; ""))) else . end)' \
      "$WORK_DIR/questions.json" > "$WORK_DIR/questions.next" 2>/dev/null \
      || emit_fail 2 "error" "invalid-input" "--fill ${k} を questions へ適用できません（ファイルを読めないか、questions が JSON でない）: ${f}"
    mv "$WORK_DIR/questions.next" "$WORK_DIR/questions.json"
    i=$((i + 1))
  done
fi
# 残ったプレースホルダは大小文字を問わず拒否する（小文字の {{candidate}} は --fill で埋められないので、
# 検出だけ大文字限定だと文字どおり Jev へ送られてしまう）
placeholder_left="$(jq -r '[.. | strings | select(test("\\{\\{[^}]+\\}\\}"))] | length' "$WORK_DIR/questions.json" 2>/dev/null)"
case "$placeholder_left" in
  0) ;;
  ''|*[!0-9]*) emit_fail 2 "error" "invalid-input" "questions を走査できません（JSON として読めない）: ${QUESTIONS_FILE}" ;;
  *) emit_fail 2 "error" "invalid-input" "questions に置換されていないプレースホルダ {{...}} が残っています（--fill で埋めてください）" ;;
esac

# model の固定（明示指定はそのまま）
if [ -z "${TYPESAFE_MODEL:-}" ]; then
  export TYPESAFE_MODEL="$MODEL_PINNED"
fi

# ---- Jev を 1 回呼ぶ ------------------------------------------------------------
JUDGE_OUT="$(bash "$JUDGE" --questions "$WORK_DIR/questions.json" --state-file "$WORK_DIR/state" --json 2>"$WORK_DIR/judge.err")"
JUDGE_RC=$?
JUDGE_ERR="$(cat "$WORK_DIR/judge.err")"

DECISION_ID="$(date -u +%Y%m%dT%H%M%SZ)-$$-${POINT}"

write_log() { # $1=1 行 JSON。空（jq が組み立てに失敗した形）か、書けなければ非 0 — 記録の無い採用を作らない
  local dir
  [ -n "$1" ] || return 1
  printf '%s' "$1" | jq -e 'type == "object" and .event == "decision"' >/dev/null 2>&1 || return 1
  dir="$(dirname "$LOG_PATH")"
  [ -d "$dir" ] || mkdir -p "$dir" 2>/dev/null || return 1
  printf '%s\n' "$1" >> "$LOG_PATH" 2>/dev/null || return 1
  return 0
}

if [ "$JUDGE_RC" -ne 0 ]; then
  kind="$(printf '%s' "$JUDGE_OUT" | jq -r '.error // empty' 2>/dev/null)"
  [ -n "$kind" ] || kind="judge-exit-${JUDGE_RC}"
  msg="$(printf '%s' "$JUDGE_OUT" | jq -r '.message // empty' 2>/dev/null)"
  [ -n "$msg" ] || msg="$(printf '%s' "$JUDGE_ERR" | head -n 1)"
  line="$(jq -cn --arg id "$DECISION_ID" --arg ts "$(now_iso)" --arg point "$POINT" --arg reason "$kind" \
    --arg thr "$THRESHOLD" --arg model "${TYPESAFE_MODEL}" --argjson bytes "$STATE_BYTES" --arg sha "$STATE_SHA" \
    --argjson rc "$JUDGE_RC" \
    '{event:"decision",id:$id,ts:$ts,point:$point,decision:"fallback",reason:$reason,threshold:($thr|tonumber),
      model:$model,answers:{},judge_rc:$rc,state_bytes:$bytes,state_sha256:$sha}')"
  logged_id="$DECISION_ID"
  write_log "$line" || { msg="記録先へ書けません（または記録行を組み立てられません）: ${LOG_PATH}（元の失敗: ${kind}）"; kind="log-unwritable"; logged_id=""; }
  emit_fail 11 "fallback" "$kind" "Jev の判定を使わず従来経路へ: ${msg}" "$logged_id"
fi

# 応答の最小 confidence を閾値と比べる（全質問が閾値以上のときだけ採用）
MIN_CONF="$(printf '%s' "$JUDGE_OUT" | jq -r '[.answers[].confidence] | min')"
ADOPT="$(awk -v c="$MIN_CONF" -v t="$THRESHOLD" 'BEGIN { if (c + 0 >= t + 0) print 1; else print 0 }')"
if [ "$ADOPT" -eq 1 ]; then DECISION="adopt"; REASON="confident"; else DECISION="fallback"; REASON="low-confidence"; fi

line="$(printf '%s' "$JUDGE_OUT" | jq -c --arg id "$DECISION_ID" --arg ts "$(now_iso)" --arg point "$POINT" \
  --arg decision "$DECISION" --arg reason "$REASON" --arg thr "$THRESHOLD" \
  --argjson bytes "$STATE_BYTES" --arg sha "$STATE_SHA" '
  {event:"decision",id:$id,ts:$ts,point:$point,decision:$decision,reason:$reason,threshold:($thr|tonumber),
   model:.model,answers:(.answers | with_entries(.value |= {type:.type,value:.value,confidence:.confidence})),
   latency_ms:.latency_ms,usage:.usage,cost_usd:.cost_usd,state_bytes:$bytes,state_sha256:$sha}')"
if ! write_log "$line"; then
  emit_fail 11 "fallback" "log-unwritable" "記録先へ書けない、または記録行を組み立てられないため採用しません: ${LOG_PATH}"
fi

if [ "$OUT_JSON" -eq 1 ]; then
  printf '%s' "$JUDGE_OUT" | jq -c --arg d "$DECISION" --arg r "$REASON" --arg id "$DECISION_ID" --arg thr "$THRESHOLD" \
    '{decision:$d,reason:$r,id:$id,threshold:($thr|tonumber),model:.model,answers:.answers,latency_ms:.latency_ms,usage:.usage,cost_usd:.cost_usd}'
else
  echo "JEV_DECISION=${DECISION}"
  echo "JEV_REASON=${REASON}"
  echo "JEV_DECISION_ID=${DECISION_ID}"
  echo "JEV_THRESHOLD=${THRESHOLD}"
  printf '%s' "$JUDGE_OUT" | jq -r '"JEV_MODEL=\(.model)", (.answers | to_entries[] | "ANSWER=\(.key)|\(.value.type)|\(.value.value)|\(.value.confidence)")'
fi
[ "$DECISION" = "adopt" ] && exit 0
exit 10
