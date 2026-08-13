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
# 実 CLI は 1 つも起動しない。multi-agent.sh の registry は shell として実行せず、
# 共有の制限文法 parser（tests/lib/cli-registry-parser.sh）でデータ化するだけなので、
# 課金もネットワークも一時ファイルも要らない。source 内に副作用が混ざっていても、
# このテストプロセスから実行される経路が無い。

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

# レジストリ参照の失敗を「診断ゼロの途中死」にしない。
# `x="$(get_cli_... "$cli")"` の裸代入は、`set -euo pipefail` 下で失敗すると
# **直前までの出力を出して rc=1、メッセージ無し**で終わる。どの CLI のどの lookup が
# 落ちたのか読めない。
#
# 現状この経路は到達不能（cli-registry-parser.sh が「required 関数それぞれに `*` default
# arm がちょうど 1 件」を強制するので lookup は必ず値を返す）。つまり実害はまだ無い。
# しかしその不変条件に依存した fail-closed なので、default arm 要求を緩めた瞬間に
# 「診断不能な red」へ変わる。壊れたときに原因が読める形にしておく。
# agent-config-mirror/verify.sh の lookup_checked と同じ扱いに揃える。
# 呼び出しは `x="$(lookup_checked ...)"` の形になる = **サブシェル**。この中で
# カウンタを増やしても親には残らない（実測: ✗ 行だけ出て FAIL は 0 のまま = suite は
# pass を名乗れる）。ここでは診断を stderr へ出すだけにして、**カウントは親で**上げる。
lookup_checked() { # $1: 説明, $2...: 実行するコマンド
  local what="$1"; shift
  local out rc=0
  out="$("$@" 2>&1)" || rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "  ✗ レジストリ参照に失敗: ${what}（rc=${rc}）" >&2
    printf '%s\n' "$out" | sed 's/^/      /' >&2
    return 1
  fi
  printf '%s' "$out"
}

TASKS="review explore implement"
KNOWN_TIERS="premium standard metered free-tier flat-rate"

# `[a-z]` の意味を実行環境の locale に依存させない。
LC_ALL=C
export LC_ALL

# レジストリの所有表に載らないが、モードによって動的に割り当てられる観点。
# 「ファイルはあるが誰も所有していない」を無条件に許すと迷子検出が死ぬので、
# 明示の allowlist にする。追加は意図的な編集を強制する形にしておくこと。
#   review/code-review          — build_cross_model_plan の既定 perspective
#   review/comprehensive-review — build_pair_plan が副レビュワーへ割り当てる観点。
#     所有レジストリ（分散モード用の割当）には載らないので、ここに書かないと
#     「誰も所有していない迷子」として検出される
DYNAMIC_PERSPECTIVES="review/code-review review/comprehensive-review"

# ── multi-agent.sh の registry を shell として実行せず静的に読む ─────────────
#
# agent-config-mirror と同じ共有 parser で sentinel 間の全行を制限文法として検証し、
# case arm をデータ化する。ファイル全体で registry symbol の境界外再定義も拒否する。
# mutable な本番 source を eval/source しないので、境界内に副作用を注入されても
# テストプロセスから実行される経路が無い。
REGISTRY_PARSER="$PLUGIN_ROOT/tests/lib/cli-registry-parser.sh"
[ -f "$REGISTRY_PARSER" ] || { echo "✗ registry parser が見つかりません: $REGISTRY_PARSER" >&2; exit 1; }
# shellcheck disable=SC1090,SC1091 # runtime-checked repo-local shared helper
. "$REGISTRY_PARSER"

if ! cli_registry_load "$MULTI_AGENT"; then
  echo "✗ multi-agent.sh の registry を安全に静的解析できません" >&2
  printf '  %s\n' "$CLI_REGISTRY_ERROR" >&2
  exit 1
fi

SCRIPT_DIR="$PLUGIN_ROOT/scripts"
LOOKUPS="get_cli_command get_cli_adapter get_cli_fallback get_cli_model_env_vars get_cli_cost_tier"
for task in $TASKS; do LOOKUPS="$LOOKUPS get_cli_perspectives_${task}"; done

registry_print() { # <lookup名> <CLI>
  if ! cli_registry_lookup "$1" "$2"; then
    return 1
  fi
  printf '%s\n' "$REPLY"
}
get_cli_command() { registry_print get_cli_command "$1"; }
get_cli_adapter() {
  # parser が source の値を `${SCRIPT_DIR}/adapters/<cli>-adapter.sh` と検証済み。
  if ! cli_registry_lookup get_cli_adapter "$1"; then return 1; fi
  [ -n "$REPLY" ] || return 0
  printf '%s/adapters/%s-adapter.sh\n' "$SCRIPT_DIR" "$1"
}
get_cli_fallback() { registry_print get_cli_fallback "$1"; }
get_cli_model_env_vars() { registry_print get_cli_model_env_vars "$1"; }
get_cli_cost_tier() { registry_print get_cli_cost_tier "$1"; }
get_cli_perspectives_review() { registry_print get_cli_perspectives_review "$1"; }
get_cli_perspectives_explore() { registry_print get_cli_perspectives_explore "$1"; }
get_cli_perspectives_implement() { registry_print get_cli_perspectives_implement "$1"; }

list_has() { # <list> <needle>
  case " $1 " in *" $2 "*) return 0 ;; *) return 1 ;; esac
}

# 集合の差分を「どちら側に何が余っているか」まで出す。件数だけだと直す先が分からない。
# `comm <(...)` は /dev/fd を使い、read-only sandbox 上の Apple tool で開けないことが
# あるため、Bash 3.2 の membership 比較だけで両方向を走査する。
compare_sets() { # <label> <expected(空白区切り)> <actual(空白区切り)> <expected名> <actual名>
  local label="$1" expected="$2" actual="$3" ename="$4" aname="$5"
  local item only_e="" only_a=""
  for item in $expected; do
    if ! list_has "$actual" "$item"; then only_e="${only_e} ${item}"; fi
  done
  for item in $actual; do
    if ! list_has "$expected" "$item"; then only_a="${only_a} ${item}"; fi
  done
  if [ -z "$only_e" ] && [ -z "$only_a" ]; then
    ok "$label"
  else
    bad "$label"
    [ -n "$only_e" ] && echo "      ${ename} にだけある:${only_e}" >&2
    [ -n "$only_a" ] && echo "      ${aname} にだけある:${only_a}" >&2
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

  cmd="$(lookup_checked "get_cli_command($cli)" get_cli_command "$cli")" || { FAIL=$((FAIL + 1)); continue; }
  if [ -n "$cmd" ]; then ok "get_cli_command → $cmd"
  else bad "get_cli_command が空（case 文の書き漏らし）"; fi

  adapter="$(lookup_checked "get_cli_adapter($cli)" get_cli_adapter "$cli")" || { FAIL=$((FAIL + 1)); continue; }
  if [ -z "$adapter" ]; then
    bad "get_cli_adapter が空（case 文の書き漏らし）"
  elif [ -f "$adapter" ]; then
    ok "get_cli_adapter → $(basename "$adapter")（実在）"
  else
    bad "get_cli_adapter が実在しないパスを返す: $adapter"
  fi

  tier="$(lookup_checked "get_cli_cost_tier($cli)" get_cli_cost_tier "$cli")" || { FAIL=$((FAIL + 1)); continue; }
  if list_has "$KNOWN_TIERS" "$tier"; then
    ok "get_cli_cost_tier → $tier"
  else
    bad "get_cli_cost_tier が未知の tier を返す: '${tier}'（既知: ${KNOWN_TIERS}）"
  fi

  envs="$(lookup_checked "get_cli_model_env_vars($cli)" get_cli_model_env_vars "$cli")" || { FAIL=$((FAIL + 1)); continue; }
  if [ -n "$envs" ]; then ok "get_cli_model_env_vars → $envs"
  else bad "get_cli_model_env_vars が空（失敗時の再実行コマンドに env が前置されない）"; fi

  # fallback は「その CLI が未インストールのときの代替」。自分自身を指すと
  # プラン構築が自分へ戻るだけで、代替として機能しない。
  fb="$(lookup_checked "get_cli_fallback($cli)" get_cli_fallback "$cli")" || { FAIL=$((FAIL + 1)); continue; }
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
    owned="$(lookup_checked "get_cli_perspectives_${task}($cli)" "get_cli_perspectives_${task}" "$cli")" || { FAIL=$((FAIL + 1)); continue; }
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

# parser が検証してデータ化した arm ラベルを ALL_CLIS と突き合わせる。
# 一方向（ALL_CLIS → lookup）だけだと、CLI を消したとき arm を 1 つ残しても
# 誰も呼ばないまま気づかれない。差分にも「消した 6 箇所」しか現れない。
for fn in $LOOKUPS; do
  if ! cli_registry_arms "$fn"; then
    bad "${fn} の case arm を取得できない: ${CLI_REGISTRY_ERROR}"
    continue
  fi
  arms="$REPLY"
  compare_sets "${fn} の case arm が ALL_CLIS と一致" "$ALL_CLIS" "$arms" "ALL_CLIS" "$fn"
done

echo
echo "== アダプタの過不足 =="

expected_adapters="$(for cli in $ALL_CLIS; do basename "$(get_cli_adapter "$cli")"; done | tr '\n' ' ')"
actual_adapters=""
for adapter_file in "$ADAPTERS_DIR"/*-adapter.sh; do
  [ -f "$adapter_file" ] || continue
  actual_adapters="${actual_adapters} $(basename "$adapter_file")"
done
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
echo "== 既定有効 CLI 間の観点重複（Issue #275） =="

# distributed plan は各 CLI の所有観点をそのまま実行するため、既定で有効な 2 CLI が
# 同じ観点を持つと、同じ問いへ二重にコストを払う。既定有効かどうかは別リストを
# 増やさず get_cli_cost_tier != metered から導く。metered は全 task で明示 --cli が
# 必要（Issue #250）なので、他 CLI と所有観点が重なっても既定プランでは競合しない。
#
# 意図的重複の allowlist は持たない。既定プランで重複させたい場合も、所有権を 1 CLI
# へ寄せ、比較が必要な呼び出しだけ --mode cross-model を使うのがコスト境界だから。
default_overlap=0
for task in $TASKS; do
  for cli in $ALL_CLIS; do
    [ "$(get_cli_cost_tier "$cli")" = "metered" ] && continue
    for p in $(get_cli_perspectives_"$task" "$cli"); do
      for other in $ALL_CLIS; do
        [ "$other" = "$cli" ] && break
        [ "$(get_cli_cost_tier "$other")" = "metered" ] && continue
        if list_has "$(get_cli_perspectives_"$task" "$other")" "$p"; then
          bad "${task}/${p} を既定有効 CLI が重複所有: ${other}, ${cli}"
          default_overlap=1
        fi
      done
    done
  done
done
[ "$default_overlap" -eq 0 ] && ok "既定有効 CLI の観点集合が task ごとに disjoint"

# 現行レジストリには metered の copilot-cli と既定 CLI の意図的重複がある。この正例を
# 名指しして、将来検査が「全 CLI の重複禁止」へ退化するのを防ぐ。
if list_has "$(get_cli_perspectives_review copilot-cli)" "test-analysis" \
  && list_has "$(get_cli_perspectives_review codex-cli)" "test-analysis"; then
  ok "metered copilot-cli の重複所有は明示 opt-in のため許容"
else
  bad "metered CLI allow 例の前提（copilot-cli / codex-cli の test-analysis）が消失"
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
  want="$(lookup_checked "get_cli_fallback($cli)" get_cli_fallback "$cli")" || { FAIL=$((FAIL + 1)); continue; }
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
expected_count=0
for cli in $ALL_CLIS; do expected_count=$((expected_count + 1)); done
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
