#!/usr/bin/env bash
#
# agent-config.yaml が multi-agent.sh のミラーとして正しいことの機械検査（Issue #242）。
#
# scripts/agent-config.yaml の agents.*（command / cost_tier / perspectives）と
# fallback: は、**実行時に yq で一度も読まれない**。CLI レジストリの正本は
# scripts/multi-agent.sh の case 文（get_cli_command / get_cli_cost_tier /
# get_cli_perspectives_* / get_cli_fallback）である。
#
# 同じファイルの他ブロックは読まれるので「YAML は読まれない」と一般化しないこと。
# review.main / review.sub、version / mode / parallel、tasks.<task>.{mode,cost_strategy,
# timeout,output_dir} とその v1 トップレベル相当は yq で読まれる（agent-config.yaml も
# review: ブロックに「ここは実行時に読まれる」と明記している）。読まれるキーの列挙を
# ここに書くと設定追加のたびに腐るので、証明できる否定 — agents.* の command /
# cost_tier / perspectives と fallback: は読まれない — だけを主張する。
#
# 潰している事故: **読まれない対応表が黙って嘘になること**（ACE-70-2 の一段上の形）。
# YAML と case 文が食い違っても実行時には何も起きないので、コメントで「正本は
# multi-agent.sh」と注意書きしても、誰も食い違いに気づかない。この suite は
# 「検証されたミラー」へ格上げする — 片方だけ直したら red にする。
#
# cli-registry-completeness との分担:
#   あちらは agents:/fallback: の **キー集合**が ALL_CLIS と一致することと、
#   fallback の **値**が実装と一致することを見る。ここは残りの**値**――
#   command / cost_tier / perspectives(review, explore, implement)――を横断で
#   突き合わせる。fallback も本 suite の対象に含める（Issue #242 の DoD は
#   command / cost_tier / perspectives / fallback の全キーを要求している。
#   cli-registry と重複するが、ミラー整合という一つの関心事を 1 suite で完結させ、
#   多層で守る）。
#
# 値の一致だけでなく **YAML の構造** も検査する。非典型な YAML（重複キー・複数
# ドキュメント・ブロックスカラー・想定外フィールド・空/非文字列の観点要素）は、
# 値照合だけだと素通しして緑になれる（すべて実測）。そのため単一ドキュメント性・
# 重複キー無し・型/スタイル・キー集合・要素境界を明示的に確かめる。詳細と負例は
# 本 suite の README を参照。
#
# 先例: tests/multi-agent-timeout/verify.sh が DEFAULT_TIMEOUT_* / tasks.*.timeout /
# REVIEW_TIMEOUT / 利用者向け文書を横断検査しているのと同じ型。
#
# 実 CLI は 1 つも起動しない。multi-agent.sh のレジストリは shell として実行せず、
# 制限文法 parser で固定 case arm のデータへ変換する。YAML 側は yq で読むだけなので、
# 課金もネットワークも一時ファイルも要らない。
#
# yq が無い環境では、YAML 側を 1 つも読めず検証本体がまるごと成立しないので、
# 行頭 `○ skip` + exit 0 で全体スキップする（部分 skip はしない）。

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
MULTI_AGENT="$PLUGIN_ROOT/scripts/multi-agent.sh"
AGENT_CONFIG="$PLUGIN_ROOT/scripts/agent-config.yaml"

for f in "$MULTI_AGENT" "$AGENT_CONFIG"; do
  [ -f "$f" ] || { echo "✗ 対象ファイルが見つかりません: $f" >&2; exit 1; }
done

# yq 不在は「YAML 側を 1 件も読めない」= 検証本体が丸ごと成立しないケース。
# run-all.sh の契約どおり行頭 `○ skip` を出して exit 0 する（部分 skip ではない）。
if ! command -v yq >/dev/null 2>&1; then
  echo "○ skip: yq が見つからないためスキップ（本 suite の検査は1件も実行されていません。brew install yq などで有効化）"
  exit 0
fi

# 同名の Python yq や v3 は tag/style/documentIndex/JSON 出力の契約が異なる。
# 「存在するが非互換」は検査不能なので skip ではなく fail-closed にする。
if ! YQ_VERSION="$(yq --version 2>&1)"; then
  echo "✗ yq --version の実行に失敗しました: ${YQ_VERSION}" >&2
  exit 1
fi
case "$YQ_VERSION" in
  *github.com/mikefarah/yq*'version v4.'*) ;;
  *)
    echo "✗ Mike Farah yq v4 が必要です（検出: ${YQ_VERSION}）" >&2
    exit 1
    ;;
esac

# この suite が依存する operator と compact JSON 出力を小さな fixture で実測する。
# version 文字列だけを偽装した非互換 shim を本番 YAML へ通さない。
YQ_PROBE_EXPECTED='{"doc":0,"root":"!!map","seq":"!!seq","style":"","keys":["a"]}'
if ! YQ_PROBE="$(printf '%s\n' 'a: [x]' | yq -o=json -I=0 \
  '{"doc": documentIndex, "root": (. | tag), "seq": (.a | tag), "style": (.a[0] | style), "keys": (. | keys | sort)}' 2>&1)"; then
  echo "✗ yq v4 capability probe の実行に失敗しました: ${YQ_PROBE}" >&2
  exit 1
fi
if [ "$YQ_PROBE" != "$YQ_PROBE_EXPECTED" ]; then
  echo "✗ yq v4 capability probe の結果が非互換です" >&2
  echo "  期待=${YQ_PROBE_EXPECTED}" >&2
  echo "  実際=${YQ_PROBE}" >&2
  exit 1
fi

# 下の重複キー検査は「yq が重複キーを保持したまま keys に並べる」ことに乗っている。
# 将来 keys が暗黙に dedup する実装／shim を通すと、重複を注入しても差が 0 になり
# 検査が黙って無力化する。乗っているセマンティクスは probe で固定する。
YQ_DUP_PROBE_EXPECTED='{"dupes":1,"kept":["a","a"]}'
if ! YQ_DUP_PROBE="$(printf '%s\n' 'a: 1' 'a: 2' | yq -o=json -I=0 \
  '{"dupes": ((keys | length) - (keys | unique | length)), "kept": (. | keys)}' 2>&1)"; then
  echo "✗ yq v4 重複キー probe の実行に失敗しました: ${YQ_DUP_PROBE}" >&2
  exit 1
fi
if [ "$YQ_DUP_PROBE" != "$YQ_DUP_PROBE_EXPECTED" ]; then
  echo "✗ yq が重複キーを保持しません。重複キー検査が成立しない環境です" >&2
  echo "  期待=${YQ_DUP_PROBE_EXPECTED}" >&2
  echo "  実際=${YQ_DUP_PROBE}" >&2
  exit 1
fi

PASS=0
FAIL=0
ok()  { echo "  ✓ $1"; PASS=$((PASS + 1)); }
bad() { echo "  ✗ $1" >&2; FAIL=$((FAIL + 1)); }

TASKS="review explore implement"

# `[a-z]` と sort の意味を実行環境の locale に依存させない。
LC_ALL=C
export LC_ALL

# pathname expansion はレジストリの空白区切り値を分割するときに不要で、`*` 等が
# 混入した場合に作業ディレクトリのファイル名へ化けるだけなので、suite 全体で無効化する。
set -f

# ── multi-agent.sh の registry を shell として実行せず静的に読む ─────────────
#
# eval/source で mutable な本番スクリプトを取り込むと、形の allowlist に漏れが 1 つ
# あるだけでテスト中に任意 command を実行できる。共有 parser は sentinel 間の全行を
# `ALL_CLIS` + 固定値を返す単純 case arm の制限文法として検証し、TSV データへ変換する。
# さらにファイル全体で registry symbol の境界外再定義を拒否する。関数本体も含めて
# 未許可行を拒否するため、registry の内容は一切実行されない。
REGISTRY_PARSER="$PLUGIN_ROOT/tests/lib/cli-registry-parser.sh"
[ -f "$REGISTRY_PARSER" ] || { echo "✗ registry parser が見つかりません: $REGISTRY_PARSER" >&2; exit 1; }
# shellcheck disable=SC1090,SC1091 # runtime-checked repo-local shared helper
. "$REGISTRY_PARSER"

if ! cli_registry_load "$MULTI_AGENT"; then
  echo "✗ multi-agent.sh の registry を安全に静的解析できません" >&2
  printf '  %s\n' "$CLI_REGISTRY_ERROR" >&2
  exit 1
fi

# CLI 名・観点名・command・tier・fallback はすべて単一の安全 token。
# raw word splitting を使う前に canonical form と重複を再確認する。
is_safe_token() { # 英小文字/数字を単一ハイフンでつないだ token
  case "$1" in
    ""|*[!a-z0-9-]*|-*|*-|*--*) return 1 ;;
    *) return 0 ;;
  esac
}

TOKEN_LIST_ERR=""
validate_token_list() { # <空白区切りリスト> <ラベル>
  local list="$1" label="$2" token canonical="" seen=" "
  TOKEN_LIST_ERR=""
  [ -n "$list" ] || { TOKEN_LIST_ERR="${label} が空"; return 1; }
  for token in $list; do
    if ! is_safe_token "$token"; then
      TOKEN_LIST_ERR="${label} に安全 token でない値がある: ${token}"
      return 1
    fi
    case "$seen" in
      *" $token "*) TOKEN_LIST_ERR="${label} に重複 token がある: ${token}"; return 1 ;;
    esac
    [ -z "$canonical" ] || canonical="${canonical} "
    canonical="${canonical}${token}"
    seen="${seen}${token} "
  done
  if [ "$list" != "$canonical" ]; then
    TOKEN_LIST_ERR="${label} は単一 ASCII space 区切りではない"
    return 1
  fi
  return 0
}

if ! validate_token_list "${ALL_CLIS:-}" "ALL_CLIS"; then
  echo "✗ ${TOKEN_LIST_ERR}" >&2
  exit 1
fi

# ── YAML の構造チェック（読み出し前に形を確かめる） ─────────────────────────
#
# ミラー照合は「値が一致するか」だけでなく「YAML が期待する形か」まで見る。形を
# 見ないと、次の食い違いが値照合をすり抜けて緑になる（すべて実測）:
#   - 観点を join(" ") で 1 本に潰すと、要素境界・空要素・並びの差が消える
#   - スカラを command substitution で受けるとブロックスカラー（`|`）の末尾改行が
#     削れ、`claude` と誤って一致する（本来 1 トークンの想定なのに）
#   - 同じキーを 2 回書いても yq は last-wins で読み、古い値が黙って隠れる
#   - agents.<cli> の下に想定外フィールドを足しても、その値を読まなければ気づかない
#   - 複数ドキュメントだと 2 つ目以降を yq が読まず、そこの食い違いが丸ごと消える

# パース不能な YAML を空値で素通しさせない。壊れた YAML を「全部空 vs 実装値」の
# 不一致として出すと、原因が「値がずれた」のか「読めていない」のか区別できない。
if ! yq '.' "$AGENT_CONFIG" >/dev/null 2>&1; then
  echo "✗ agent-config.yaml を yq でパースできません（YAML 構文エラー）" >&2
  exit 1
fi

# 単一ドキュメントであること。pipeline 全体を checked assignment で受け、producer の
# 非 0 を「0件」へ畳まない。
if ! doc_count="$(yq -r 'documentIndex' "$AGENT_CONFIG" | awk 'END { print NR + 0 }')"; then
  echo "✗ agent-config.yaml の document 数を取得できません" >&2
  exit 1
fi
if [ "$doc_count" != "1" ]; then
  echo "✗ agent-config.yaml が単一ドキュメントではありません（documentIndex 行数=${doc_count}）" >&2
  echo "  複数ドキュメントだと 2 つ目以降のミラー食い違いを検出できません" >&2
  exit 1
fi

# 重複キーの検出。yq はパースを拒否せず last-wins で読むので、全 map 横断で
# 「キー数 − ユニークキー数」を合算する。yq/awk いずれの失敗も fail-closed。
#
# `sum + 0` は空入力に対しても 0 を印字する。yq が黙って何も返さなくなった世界と
# 「重複ゼロ」が区別できないので、1 行も届かなかったら明示的に失敗させる
# （root が map である以上、健全なら必ず 1 行以上出る）。
if ! dup_total="$(yq -r '[.. | select(tag == "!!map") | (keys | length) - (keys | unique | length)] | .[]' "$AGENT_CONFIG" |
  awk '{ sum += $1 } END { if (NR == 0) exit 1; print sum + 0 }')"; then
  echo "✗ agent-config.yaml の重複キー検査を実行できません（producer が 1 行も返さない場合を含む）" >&2
  exit 1
fi
if [ "$dup_total" != "0" ]; then
  echo "✗ agent-config.yaml に重複キーがあります（マップ横断の重複数=${dup_total}）" >&2
  echo "  yq は重複を last-wins で読むため、古い値が黙って隠れます" >&2
  exit 1
fi

# ── YAML 側の読み出しヘルパ（すべて status 確認 + compact JSON transport） ───
#
# raw 行区切りは scalar の末尾改行、sequence の要素境界、map key の改行を保持できない。
# yq の compact JSON ならデータ中の改行は `\n` として残るため、command substitution の
# 末尾改行除去や Apple diff の /dev/fd 制約に依存せず比較できる。

YQ_ERR=""
yq_checked() { # <format: raw|json> <式> — REPLY / YQ_ERR
  local format="$1" expression="$2" output
  REPLY=""
  YQ_ERR=""
  case "$format" in
    raw)
      if ! output="$(yq -r "$expression" "$AGENT_CONFIG" 2>&1)"; then
        YQ_ERR="$output"
        return 1
      fi
      ;;
    json)
      if ! output="$(yq -o=json -I=0 "$expression" "$AGENT_CONFIG" 2>&1)"; then
        YQ_ERR="$output"
        return 1
      fi
      ;;
    *) YQ_ERR="内部エラー: 未知の yq 出力形式 ${format}"; return 1 ;;
  esac
  REPLY="$output"
  return 0
}

YAML_SCALAR_ERR=""
yaml_scalar_json() { # <yqパス式> — JSON_VALUE / YAML_SCALAR_ERR
  local p="$1" node_tag node_style
  JSON_VALUE="null"
  YAML_SCALAR_ERR=""
  if ! yq_checked raw "$p | tag"; then
    YAML_SCALAR_ERR="tag の取得に失敗: ${YQ_ERR}"
    return 1
  fi
  node_tag="$REPLY"
  if [ "$node_tag" = "!!null" ]; then
    return 0
  fi
  if [ "$node_tag" != "!!str" ]; then
    YAML_SCALAR_ERR="型が文字列でない (tag=${node_tag})"
    return 1
  fi
  if ! yq_checked raw "$p | style"; then
    YAML_SCALAR_ERR="style の取得に失敗: ${YQ_ERR}"
    return 1
  fi
  node_style="$REPLY"
  case "$node_style" in
    literal|folded)
      YAML_SCALAR_ERR="ブロックスカラー (style=${node_style}) は使用不可"
      return 1
      ;;
  esac
  if ! yq_checked raw "$p | test(\"^[a-z0-9]+(-[a-z0-9]+)*$\")"; then
    YAML_SCALAR_ERR="安全 token 検査に失敗: ${YQ_ERR}"
    return 1
  fi
  if [ "$REPLY" != "true" ]; then
    YAML_SCALAR_ERR="安全な単一 token でない"
    return 1
  fi
  if ! yq_checked json "$p"; then
    YAML_SCALAR_ERR="値の JSON 化に失敗: ${YQ_ERR}"
    return 1
  fi
  JSON_VALUE="$REPLY"
  return 0
}

json_string() { # trusted shell token → JSON string
  printf '"%s"' "$1"
}

impl_list_json() { # canonical space-separated safe tokens → compact JSON array
  local list="$1" token result="[" comma=""
  for token in $list; do
    result="${result}${comma}$(json_string "$token")"
    comma=","
  done
  printf '%s]' "$result"
}

impl_key_set_json() { # canonical space-separated safe tokens → C-locale sorted JSON array
  local list="$1" sorted
  # key set は順不同。YAML 側の `keys | sort` と同じ正準順にし、ALL_CLIS の並べ替えを
  # 実体差分と誤認しない。token 検査 + set -f 後なので意図的な語分割は安全。
  # shellcheck disable=SC2086
  if ! sorted="$(printf '%s\n' $list | LC_ALL=C sort)"; then
    return 1
  fi
  impl_list_json "$sorted"
}

compare_scalar() { # <ラベル> <yqパス式> <実装値>
  local label="$1" p="$2" impl="$3" impl_json
  if ! is_safe_token "$impl"; then
    bad "${label} の実装値が安全な単一 token でない: ${impl:-（空）}"
    return 0
  fi
  if ! yaml_scalar_json "$p"; then
    bad "${label} が構造異常: ${YAML_SCALAR_ERR}"
    return 0
  fi
  impl_json="$(json_string "$impl")"
  if [ "$impl_json" = "$JSON_VALUE" ]; then
    ok "${label} が一致 (${impl})"
  else
    bad "${label} が不一致: YAML(JSON)=${JSON_VALUE} / 実装=${impl}"
  fi
  return 0
}

LOOKUP_ERR=""
lookup_checked() { # <関数名> <CLI> — REPLY / LOOKUP_ERR
  local fn="$1" cli="$2"
  REPLY=""
  LOOKUP_ERR=""
  if ! cli_registry_lookup "$fn" "$cli"; then
    LOOKUP_ERR="$CLI_REGISTRY_ERROR"
    return 1
  fi
  return 0
}

compare_lookup_scalar() { # <ラベル> <path> <lookup> <cli>
  local label="$1" p="$2" fn="$3" cli="$4" impl
  if ! lookup_checked "$fn" "$cli"; then
    bad "$LOOKUP_ERR"
    return 0
  fi
  impl="$REPLY"
  compare_scalar "$label" "$p" "$impl"
  return 0
}

compare_key_set() { # <ラベル> <yqパス式> <期待 JSON配列>
  local label="$1" p="$2" expected_json="$3" node_tag
  if ! yq_checked raw "$p | tag"; then
    bad "${label} の型取得に失敗: ${YQ_ERR}"
    return 0
  fi
  node_tag="$REPLY"
  if [ "$node_tag" != "!!map" ]; then
    bad "${label} が map でない (tag=${node_tag})"
    return 0
  fi
  if ! yq_checked json "$p | keys | sort"; then
    bad "${label} のキー取得に失敗: ${YQ_ERR}"
    return 0
  fi
  if [ "$REPLY" = "$expected_json" ]; then
    ok "${label} のキーが想定どおり"
  else
    bad "${label} のキーが想定外: ${REPLY}（期待: ${expected_json}）"
  fi
  return 0
}

compare_perspective() { # <ラベル> <yqパス式> <実装値(space区切り)>
  local label="$1" p="$2" impl="$3" ftag anomalies yaml_json impl_json
  if ! validate_token_list "$impl" "${label} の実装値"; then
    bad "$TOKEN_LIST_ERR"
    return 0
  fi
  if ! yq_checked raw "$p | tag"; then
    bad "${label} の型取得に失敗: ${YQ_ERR}"
    return 0
  fi
  ftag="$REPLY"
  if [ "$ftag" != "!!seq" ]; then
    bad "${label} が配列でない (tag=${ftag})"
    return 0
  fi
  # 型、空白のみ、改行、空白、連続ハイフンなどを token grammar で一括拒否する。
  if ! yq_checked raw "[$p | .[] | select((tag != \"!!str\") or ((tag == \"!!str\") and (test(\"^[a-z0-9]+(-[a-z0-9]+)*$\") | not)))] | length"; then
    bad "${label} の要素検査に失敗: ${YQ_ERR}"
    return 0
  fi
  anomalies="$REPLY"
  if [ "$anomalies" != "0" ]; then
    bad "${label} に安全 token でない要素がある（異常要素=${anomalies}）"
    return 0
  fi
  if ! yq_checked json "$p"; then
    bad "${label} の JSON 化に失敗: ${YQ_ERR}"
    return 0
  fi
  yaml_json="$REPLY"
  impl_json="$(impl_list_json "$impl")"
  if [ "$yaml_json" = "$impl_json" ]; then
    ok "${label} が一致 (${impl})"
  else
    bad "${label} が不一致: YAML=${yaml_json} / 実装=${impl_json}"
  fi
  return 0
}

compare_lookup_perspective() { # <ラベル> <path> <lookup> <cli>
  local label="$1" p="$2" fn="$3" cli="$4" impl
  if ! lookup_checked "$fn" "$cli"; then
    bad "$LOOKUP_ERR"
    return 0
  fi
  impl="$REPLY"
  compare_perspective "$label" "$p" "$impl"
  return 0
}

echo "== agent-config.yaml ミラー整合 =="
echo "ALL_CLIS: $ALL_CLIS"
echo

# ── (1) ALL_CLIS を回して値を突き合わせる ───────────────────────────────────
#
# 不一致は「どのキーが」「YAML 側は何で」「実装側は何か」まで名指しする。件数だけだと
# 直す先が分からない。

cli_count=0
for cli in $ALL_CLIS; do
  cli_count=$((cli_count + 1))
  echo "--- $cli ---"

  # lookup 自体の非 0 も検査不能として集約し、空値や stderr を実装値へ化けさせない。
  compare_lookup_scalar "agents.${cli}.command" ".agents.\"$cli\".command" \
    get_cli_command "$cli"
  compare_lookup_scalar "agents.${cli}.cost_tier" ".agents.\"$cli\".cost_tier" \
    get_cli_cost_tier "$cli"

  # agents.<cli> と perspectives は map 型 + 厳密な key set を compact JSON で照合。
  # 空白・改行・空文字を含む未知 key も JSON escape された 1 要素として保持される。
  compare_key_set "agents.${cli}" ".agents.\"$cli\"" \
    '["command","cost_tier","perspectives"]'
  compare_key_set "agents.${cli}.perspectives" ".agents.\"$cli\".perspectives" \
    '["explore","implement","review"]'

  # perspectives（review / explore / implement）。順序・要素境界込みで比較する。
  # 集合一致だと「観点の並べ替え」を見逃すが、レジストリは space 区切りの並びを
  # そのまま出力に使う（build_distributed_plan）ので、順序も対応表として意味を持つ。
  for task in $TASKS; do
    compare_lookup_perspective "agents.${cli}.perspectives.${task}" \
      ".agents.\"$cli\".perspectives.\"$task\"" "get_cli_perspectives_${task}" "$cli"
  done

  # fallback（スカラ）
  compare_lookup_scalar "fallback.${cli}" ".fallback.\"$cli\"" get_cli_fallback "$cli"
done

if [ "$cli_count" -gt 0 ]; then
  ok "ALL_CLIS の ${cli_count} 件すべてを検査した"
else
  bad "ALL_CLIS が空 — 検査が空振りしている"
fi

echo
echo "== YAML に余剰キーが無いこと（実装に無い CLI を対応表に残していない） =="

# ALL_CLIS → YAML の一方向（値の照合）だけだと、実装から消した CLI の arm を YAML に
# 残しても気づかれない。逆向きは map key 全体を compact JSON 配列として厳密比較する。
# raw 行 transport や部分文字列 membership を使わないため、空白・改行・空 key も red。
# map key は順不同なので、実装側も YAML の `keys | sort` と同じ C-locale 順へ正準化する。
if ! expected_cli_keys_json="$(impl_key_set_json "$ALL_CLIS")"; then
  echo "✗ ALL_CLIS の key set JSON 化に失敗しました" >&2
  exit 1
fi
compare_key_set "agents:" ".agents" "$expected_cli_keys_json"
compare_key_set "fallback:" ".fallback" "$expected_cli_keys_json"

echo
if [ "$FAIL" -gt 0 ]; then
  echo "✗ agent-config-mirror verify: $FAIL 件失敗" >&2
  exit 1
fi
echo "✓ agent-config-mirror verify: 全 $PASS 件 pass"
