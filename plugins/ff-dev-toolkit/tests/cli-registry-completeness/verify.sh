#!/usr/bin/env bash
#
# CLI レジストリの完全性検査（Issue #240）。
#
# multi-agent.sh の CLI レジストリは bash 3.2 互換のため連想配列を使えず、
# 「1 CLI につき、以下すべての case 文を lockstep で書く」構造になっている。
#   command / adapter / perspectives(review, explore, implement) / fallback /
#   model env / cost tier
# 数は書かない。この suite 自身が count-rot を防ぐためのものなので、ここに件数を
# 直書きすると真っ先に腐る（初版は「7 つ」と書いて実際は 8 つだった）。
# さらにレジストリの写しが 3 箇所ある（agent-config.yaml の人間向け対応表、
# setup-multi-agent.sh の検出一覧、no-hardcoded-model の期待アダプタ数）。
#
# 潰している事故: **手で維持する並行リストの片側だけが動くこと**。どの lookup も
# 既定が `echo ""` なので、書き漏らしはエラーにならないまま該当 CLI がプランから
# 消える。逆に消し忘れた arm はどこからも呼ばれず、レビューでも差分に現れない。
#
# 検査は「片方向で足りるか」を毎回疑うこと。初版は
#   - ALL_CLIS → lookup の一方向しか見ておらず、消し忘れた arm を素通しした
#   - 観点の照合が非アンカーの部分一致で、`analysis.md` が `type-design-analysis`
#     の部分文字列として通った
#   - レジストリ → ファイルの向きが無く、実体の無い観点名が通った
#   - 観点を review から explore へ付け替える取り違えを見なかった
# いずれも実測で緑になることが確認されている。現在は集合一致（両方向）で閉じている。
#
# 実 CLI は 1 つも起動しない。multi-agent.sh の前半を評価して lookup 関数を直接
# 呼ぶだけなので、課金もネットワークも一時ファイルも要らない。

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
MULTI_AGENT="$PLUGIN_ROOT/scripts/multi-agent.sh"
ADAPTERS_DIR="$PLUGIN_ROOT/scripts/adapters"
PERSPECTIVES_DIR="$PLUGIN_ROOT/scripts/perspectives"
AGENT_CONFIG="$PLUGIN_ROOT/scripts/agent-config.yaml"
SETUP_SCRIPT="$PLUGIN_ROOT/scripts/setup-multi-agent.sh"
NO_HARDCODED="$PLUGIN_ROOT/tests/no-hardcoded-model/verify.sh"

for path in "$MULTI_AGENT" "$ADAPTERS_DIR" "$PERSPECTIVES_DIR" \
            "$AGENT_CONFIG" "$SETUP_SCRIPT" "$NO_HARDCODED"; do
  [ -e "$path" ] || { echo "✗ 対象が見つかりません: $path" >&2; exit 1; }
done

PASS=0
FAIL=0
ok()  { echo "  ✓ $1"; PASS=$((PASS + 1)); }
bad() { echo "  ✗ $1" >&2; FAIL=$((FAIL + 1)); }

TASKS="review explore implement"
KNOWN_TIERS="premium standard metered free-tier flat-rate"

# レジストリの所有表に載らないが、モードによって動的に割り当てられる観点。
# 「ファイルはあるが誰も所有していない」を無条件に許すと迷子検出が死ぬので、
# 明示の allowlist にする。追加は意図的な編集を強制する形にしておくこと。
#   review/code-review          — build_cross_model_plan の既定 perspective
#   review/comprehensive-review — build_pair_plan が副レビュワーへ割り当てる観点。
#     所有レジストリ（分散モード用の割当）には載らないので、ここに書かないと
#     「誰も所有していない迷子」として検出される
DYNAMIC_PERSPECTIVES="review/code-review review/comprehensive-review"

# ── multi-agent.sh の前半（lookup 定義域）だけを取り込む ─────────────────────
#
# 切り出しの境界は**コメント行**なので、書き換えても multi-agent.sh は文法エラーに
# ならない。境界を検出できないまま awk を走らせるとファイル全体が返り、eval が
# 末尾の `main "$@"` まで実行して、テストの中で本物の CLI が課金付きで起動する。
# 実測: 境界を消すと切り出しが 289 行 → 1320 行（全体）になる。
REGISTRY_SENTINEL='# ── Defaults ──'

if ! grep -qxF -- "$REGISTRY_SENTINEL" "$MULTI_AGENT"; then
  echo "✗ multi-agent.sh に切り出し境界'${REGISTRY_SENTINEL}'が見つかりません" >&2
  echo "  境界を変更したなら本 suite の REGISTRY_SENTINEL も更新してください" >&2
  echo "  （このまま進むとファイル全体を eval して実 CLI を起動します）" >&2
  exit 1
fi

REGISTRY_SRC="$(awk -v sentinel="$REGISTRY_SENTINEL" '$0 == sentinel { exit } { print }' "$MULTI_AGENT")"

# 境界検出をすり抜けた場合の二重の歯止め。エントリポイントが混ざっていたら評価しない。
case "$REGISTRY_SRC" in
  *'main "$@"'*)
    echo "✗ 切り出した範囲にエントリポイント（main \"\$@\"）が含まれています — eval を中止します" >&2
    exit 1
    ;;
esac

# shellcheck disable=SC1090
eval "$REGISTRY_SRC"

# 取り込んだ前半には `SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"` が含まれる。
# $0 は本 verify.sh なので、そのままだと get_cli_adapter が tests/ 配下の
# 存在しないパスを組み立てて「アダプタが無い」と誤検出する。本来の値へ戻す。
SCRIPT_DIR="$PLUGIN_ROOT/scripts"

LOOKUPS="get_cli_command get_cli_adapter get_cli_fallback get_cli_model_env_vars get_cli_cost_tier"
for task in $TASKS; do LOOKUPS="$LOOKUPS get_cli_perspectives_${task}"; done

for fn in $LOOKUPS; do
  if ! declare -F "$fn" >/dev/null 2>&1; then
    echo "✗ 切り出した範囲に ${fn} の定義がありません（境界がずれた可能性）" >&2
    exit 1
  fi
done

if [ -z "${ALL_CLIS:-}" ]; then
  echo "✗ ALL_CLIS を読み出せません（multi-agent.sh の構造が変わった可能性）" >&2
  exit 1
fi

list_has() { # <list> <needle>
  case " $1 " in *" $2 "*) return 0 ;; *) return 1 ;; esac
}

sorted() { printf '%s\n' $1 | sort -u; }   # 意図的な非クォート展開（空白区切り→行）

# 集合の差分を「どちら側に何が余っているか」まで出す。件数だけだと直す先が分からない。
compare_sets() { # <label> <expected(空白区切り)> <actual(空白区切り)> <expected名> <actual名>
  local label="$1" expected="$2" actual="$3" ename="$4" aname="$5"
  local only_e only_a
  only_e="$(comm -23 <(sorted "$expected") <(sorted "$actual") | tr '\n' ' ')"
  only_a="$(comm -13 <(sorted "$expected") <(sorted "$actual") | tr '\n' ' ')"
  if [ -z "${only_e// }" ] && [ -z "${only_a// }" ]; then
    ok "$label"
  else
    bad "$label"
    [ -n "${only_e// }" ] && echo "      ${ename} にだけある: ${only_e}" >&2
    [ -n "${only_a// }" ] && echo "      ${aname} にだけある: ${only_a}" >&2
  fi
  return 0
}

echo "== CLI レジストリの完全性 =="
echo "ALL_CLIS: $ALL_CLIS"
echo

# ── (1) ALL_CLIS → lookup: すべての lookup が非空を返すか ────────────────────

cli_count=0
for cli in $ALL_CLIS; do
  cli_count=$((cli_count + 1))
  echo "--- $cli ---"

  cmd="$(get_cli_command "$cli")"
  if [ -n "$cmd" ]; then ok "get_cli_command → $cmd"
  else bad "get_cli_command が空（case 文の書き漏らし）"; fi

  adapter="$(get_cli_adapter "$cli")"
  if [ -z "$adapter" ]; then
    bad "get_cli_adapter が空（case 文の書き漏らし）"
  elif [ -f "$adapter" ]; then
    ok "get_cli_adapter → $(basename "$adapter")（実在）"
  else
    bad "get_cli_adapter が実在しないパスを返す: $adapter"
  fi

  tier="$(get_cli_cost_tier "$cli")"
  if list_has "$KNOWN_TIERS" "$tier"; then
    ok "get_cli_cost_tier → $tier"
  else
    bad "get_cli_cost_tier が未知の tier を返す: '${tier}'（既知: ${KNOWN_TIERS}）"
  fi

  envs="$(get_cli_model_env_vars "$cli")"
  if [ -n "$envs" ]; then ok "get_cli_model_env_vars → $envs"
  else bad "get_cli_model_env_vars が空（失敗時の再実行コマンドに env が前置されない）"; fi

  # fallback は「その CLI が未インストールのときの代替」。自分自身を指すと
  # プラン構築が自分へ戻るだけで、代替として機能しない。
  fb="$(get_cli_fallback "$cli")"
  if [ -z "$fb" ]; then
    bad "get_cli_fallback が空（未インストール時に観点が黙って落ちる）"
  elif [ "$fb" = "$cli" ]; then
    bad "get_cli_fallback が自分自身を指している: $fb"
  elif list_has "$ALL_CLIS" "$fb"; then
    ok "get_cli_fallback → $fb"
  else
    bad "get_cli_fallback が ALL_CLIS 外を指している: $fb"
  fi

  # タスクごとに個別で見る。3 つを連結して「どれか 1 つでもあれば OK」にすると、
  # 新規 CLI で review の arm だけ書き忘れた場合が通ってしまう（実測で確認済み）。
  for task in $TASKS; do
    owned="$(get_cli_perspectives_"$task" "$cli")"
    if [ -n "$owned" ]; then
      ok "get_cli_perspectives_${task} → ${owned}"
    else
      bad "get_cli_perspectives_${task} が空（${task} のプランにこの CLI が一度も現れない）"
    fi
  done
done

if [ "$cli_count" -gt 0 ]; then
  ok "ALL_CLIS の ${cli_count} 件すべてを検査した"
else
  bad "ALL_CLIS が空 — 検査が空振りしている"
fi

echo
echo "== lookup → ALL_CLIS（消し忘れた case arm の検出） =="

# lookup 本体から arm ラベルを収穫して ALL_CLIS と突き合わせる。
# 一方向（ALL_CLIS → lookup）だけだと、CLI を消したとき arm を 1 つ残しても
# 誰も呼ばないまま気づかれない。差分にも「消した 6 箇所」しか現れない。
harvest_arms() { # <関数名>
  printf '%s\n' "$REGISTRY_SRC" | awk -v fn="$1" '
    $0 ~ "^" fn "\\(\\)" { inside = 1; next }
    inside && /^}/ { exit }
    inside && match($0, /^[[:space:]]+[a-z0-9|_-]+\)/) {
      label = substr($0, RSTART, RLENGTH - 1)
      gsub(/[[:space:]]/, "", label)
      if (label != "*") print label
    }
  '
}

for fn in $LOOKUPS; do
  arms="$(harvest_arms "$fn" | tr '\n' ' ')"
  compare_sets "${fn} の case arm が ALL_CLIS と一致" "$ALL_CLIS" "$arms" "ALL_CLIS" "$fn"
done

echo
echo "== アダプタの過不足 =="

expected_adapters="$(for cli in $ALL_CLIS; do basename "$(get_cli_adapter "$cli")"; done | tr '\n' ' ')"
actual_adapters="$(cd "$ADAPTERS_DIR" && ls -1 ./*-adapter.sh 2>/dev/null | sed 's|^\./||' | tr '\n' ' ')"
compare_sets "adapters/*-adapter.sh の集合が ALL_CLIS と一致" \
  "$expected_adapters" "$actual_adapters" "レジストリ" "実ファイル"

echo
echo "== 観点とプロンプトファイルの一致 =="

# レジストリが名指しする観点を `<task>/<name>` の形で集める。
owned_perspectives=""
for cli in $ALL_CLIS; do
  for task in $TASKS; do
    for p in $(get_cli_perspectives_"$task" "$cli"); do
      owned_perspectives="$owned_perspectives ${task}/${p}"
    done
  done
done
owned_perspectives="$owned_perspectives $DYNAMIC_PERSPECTIVES"

# 実在するプロンプトファイルを同じ形で集める。
disk_perspectives=""
for task in $TASKS; do
  [ -d "$PERSPECTIVES_DIR/$task" ] || continue
  for f in "$PERSPECTIVES_DIR/$task"/*.md; do
    [ -f "$f" ] || continue
    disk_perspectives="$disk_perspectives ${task}/$(basename "$f" .md)"
  done
done

if [ -z "${disk_perspectives// }" ]; then
  bad "観点ファイルが 1 件も見つからない — 検査が空振りしている"
else
  # 集合一致で両方向を一度に閉じる:
  #   レジストリ側にだけある = 実体の無い観点名（実行時に「ファイルが無い」で落ちる）
  #   ファイル側にだけある   = 誰も実行しない迷子プロンプト
  # `<task>/<name>` で比較するので、観点を別タスクへ付け替える取り違えも捕まる。
  # 部分一致で照合していた初版は `analysis.md` を `type-design-analysis` の
  # 部分文字列として通していた（`grep -w` もハイフンが単語境界になるため効かない）。
  compare_sets "観点の集合がレジストリと prompts/ で一致" \
    "$owned_perspectives" "$disk_perspectives" "レジストリ" "perspectives/"
fi

echo
echo "== レジストリの写し（人が手で維持している並行リスト） =="

# agent-config.yaml の agents: / fallback: は実行時に読まれない対応表。だからこそ
# 黙って嘘になれる（ACE-70-2 の一段上の形）。読まれないものほど機械で縛る。
yaml_block_keys() { # <ブロック名>
  awk -v block="$1" '
    $0 == block ":" { inside = 1; next }
    inside && /^[a-zA-Z]/ { exit }
    inside && match($0, /^  [a-z0-9-]+:/) {
      key = substr($0, RSTART + 2, RLENGTH - 3)
      print key
    }
  ' "$AGENT_CONFIG"
}

compare_sets "agent-config.yaml の agents: が ALL_CLIS と一致" \
  "$ALL_CLIS" "$(yaml_block_keys agents | tr '\n' ' ')" "ALL_CLIS" "agents:"
compare_sets "agent-config.yaml の fallback: が ALL_CLIS と一致" \
  "$ALL_CLIS" "$(yaml_block_keys fallback | tr '\n' ' ')" "ALL_CLIS" "fallback:"

# キー集合が一致していても、**値**が実装とずれていれば対応表は嘘になる。実際に
# 実装が grok-cli → gemini-cli に変わったのに YAML は codex-cli のままだった
# （キー比較だけの検査は 55 件 green のまま素通しした）。
yaml_fallback_value() { # <cli>
  awk -v key="  $1:" '
    $0 == "fallback:" { inside = 1; next }
    inside && /^[a-zA-Z]/ { exit }
    inside && index($0, key) == 1 {
      rest = substr($0, length(key) + 1)
      sub(/#.*$/, "", rest)
      gsub(/[[:space:]]/, "", rest)
      print rest
      exit
    }
  ' "$AGENT_CONFIG"
}

fallback_value_mismatch=0
for cli in $ALL_CLIS; do
  want="$(get_cli_fallback "$cli")"
  got="$(yaml_fallback_value "$cli")"
  if [ "$want" != "$got" ]; then
    bad "agent-config.yaml の fallback.${cli} が実装と不一致: YAML=${got:-（空）} / 実装=${want}"
    fallback_value_mismatch=1
  fi
done
[ "$fallback_value_mismatch" -eq 0 ] && ok "agent-config.yaml の fallback の値が実装と一致"

# setup-multi-agent.sh の検出一覧（`name:command:tier` の行）。ここが漏れると
# 「N/M 利用可能」の分母がずれ、未導入 CLI の案内も出ない。
setup_clis="$(awk '
  /^[a-z0-9-]+:[a-z0-9-]+:[A-Za-z-]+"?$/ { split($0, a, ":"); print a[1] }
  /local clis="[a-z0-9-]+:/ { sub(/.*local clis="/, ""); split($0, a, ":"); print a[1] }
' "$SETUP_SCRIPT" | tr '\n' ' ')"
compare_sets "setup-multi-agent.sh の CLI 一覧が ALL_CLIS と一致" \
  "$ALL_CLIS" "$setup_clis" "ALL_CLIS" "setup-multi-agent.sh"

# no-hardcoded-model の期待アダプタ数。ALL_CLIS から導ける値を手で持っているので、
# ここでだけ突き合わせておく（あちらは multi-agent.sh を読まない設計のため）。
expected_count="$(printf '%s\n' $ALL_CLIS | wc -l | tr -d ' ')"
declared_count="$(awk -F= '/^EXPECTED_ADAPTER_COUNT=/ { print $2; exit }' "$NO_HARDCODED" | tr -d ' ')"
if [ "$declared_count" = "$expected_count" ]; then
  ok "no-hardcoded-model の EXPECTED_ADAPTER_COUNT が ALL_CLIS の件数と一致 (${expected_count})"
else
  bad "no-hardcoded-model の EXPECTED_ADAPTER_COUNT が不一致: 宣言=${declared_count} / ALL_CLIS=${expected_count}"
fi

echo
if [ "$FAIL" -gt 0 ]; then
  echo "✗ cli-registry-completeness verify: $FAIL 件失敗" >&2
  exit 1
fi
echo "✓ cli-registry-completeness verify: 全 $PASS 件 pass"
