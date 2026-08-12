#!/usr/bin/env bash
#
# agent-config-mirror gate の検出力を mutation で実測する（Issue #242）。
# 作業ツリーは変更せず、現在の plugin tree を一時領域へコピーして poison する。

set -euo pipefail
set -f

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SOURCE_VERIFY="$PLUGIN_ROOT/tests/agent-config-mirror/verify.sh"

if ! command -v yq >/dev/null 2>&1; then
  echo "○ skip: yq が見つからないため agent-config-mirror の mutation self-test をスキップ（検査は1件も実行されていません）"
  FF_REACHED_END=1
  exit 0
fi

# 検査対象の suite は flavor/version が違う yq を skip ではなく fail-closed で弾く。
# ここが `command -v yq` だけだと、Python yq が入った環境で baseline が「失敗した」と
# 報告され、環境問題がハーネスの破損に見える。判定を対象側と揃える。
if ! SELFTEST_YQ_VERSION="$(yq --version 2>&1)"; then
  echo "○ skip: yq --version を実行できないため mutation self-test をスキップ（検査は1件も実行されていません）"
  FF_REACHED_END=1
  exit 0
fi
case "$SELFTEST_YQ_VERSION" in
  *github.com/mikefarah/yq*'version v4.'*) ;;
  *)
    echo "○ skip: Mike Farah yq v4 ではないため mutation self-test をスキップ（検出: ${SELFTEST_YQ_VERSION}。検査は1件も実行されていません）"
    FF_REACHED_END=1
    exit 0
    ;;
esac

if ! command -v perl >/dev/null 2>&1; then
  echo "○ skip: perl が見つからないため agent-config-mirror の mutation self-test をスキップ（検査は1件も実行されていません）"
  FF_REACHED_END=1
  exit 0
fi

if ! TMP="$(mktemp -d "${TMPDIR:-/tmp}/agent-config-mirror-selftest.XXXXXX" 2>/dev/null)"; then
  echo "○ skip: 書き込み可能な一時領域を作れないため agent-config-mirror の mutation self-test をスキップ（検査は1件も実行されていません）"
  FF_REACHED_END=1
  exit 0
fi
# 途中死を沈黙させない。`set -u` 等で死んだとき、トラップ突入時の $? は **0** になるため、
# 終了ステータスを保存し直すだけでは足りない（実測）。「rc=0 なのに最後まで到達して
# いない」を中断として扱う。明示的な非 0 終了はそのまま通す。
FF_REACHED_END=0
_ff_exit_guard() {
  _ff_rc=$?
  rm -rf "$TMP"
  if [ "$_ff_rc" -eq 0 ] && [ "$FF_REACHED_END" -ne 1 ]; then
    echo "✗ agent-config-mirror-selftest: 最後まで到達しませんでした（途中で中断）" >&2
    exit 1
  fi
  exit "$_ff_rc"
}
trap _ff_exit_guard EXIT

PASS=0
FAIL=0
ok()  { echo "  ✓ $1"; PASS=$((PASS + 1)); }
bad() { echo "  ✗ $1" >&2; FAIL=$((FAIL + 1)); }

# ── baseline の期待値を CLI ロスターから導出する ─────────────────────────────
#
# 期待件数と CLI 名を直書きすると、CLI を 1 つ増減しただけで（#240 の cursor-cli 削除 /
# #252 の grok-cli 追加で実際に起きている）この suite が red になる。しかも診断は
# 「baseline が pass しなかった」なので、ゲート側のバグに見えて原因に辿り着けない。
#
# 件数 canary そのものは残す。値 mutation はゲートの比較が**壊れた**ことを捕まえるが、
# 検査が**丸ごと削除**されたことは捕まえられない（削除しても残りは pass する）。
# 件数だけがそれを捕まえる。ロスターとの結合だけを切る。
#
# 注意: この式は「1 CLI あたり 8 件」の内訳が変わると腐る。ミラーするキーを増減した
# ときは CHECKS_PER_CLI を実測して直すこと（ロスター変更には追従するが、キー追加には
# 追従しない）。
SELFTEST_PARSER="$PLUGIN_ROOT/tests/lib/cli-registry-parser.sh"
# shellcheck disable=SC1090,SC1091 # runtime-checked repo-local shared helper
. "$SELFTEST_PARSER"
if ! cli_registry_load "$PLUGIN_ROOT/scripts/multi-agent.sh"; then
  echo "✗ self-test の期待値を作れません（registry を静的解析できない）" >&2
  printf '  %s\n' "$CLI_REGISTRY_ERROR" >&2
  exit 1
fi

# 1 CLI あたり: command / cost_tier / agents.<cli> キー集合 / perspectives キー集合 /
# review / explore / implement / fallback.<cli> の 8 件。
CHECKS_PER_CLI=8
# CLI を跨がない分: ALL_CLIS 全件検査 / agents: キー集合 / fallback: キー集合 の 3 件。
CHECKS_SHARED=3
# shellcheck disable=SC2086 # 空白区切りリストの意図的な分割（先頭で set -f 済み）
CLI_COUNT="$(set -- $ALL_CLIS; echo $#)"
MIRROR_PASS_LINE="agent-config-mirror verify: 全 $((CLI_COUNT * CHECKS_PER_CLI + CHECKS_SHARED)) 件 pass"

# 「正当な並べ替え」mutation 用。実ロスターを反転するので、CLI が増減しても
# 退役済みの CLI を注入し直してしまうことがない。
REVERSED_ALL_CLIS=""
for selftest_cli in $ALL_CLIS; do
  REVERSED_ALL_CLIS="${selftest_cli}${REVERSED_ALL_CLIS:+ }${REVERSED_ALL_CLIS}"
done

assert_contains() { # <label> <haystack> <needle>
  local label="$1" haystack="$2" needle="$3"
  case "$haystack" in
    *"$needle"*) ok "$label" ;;
    *) bad "${label}（期待する診断が無い: ${needle}）" ;;
  esac
}

remember_file() { # <file>
  MUTATION_BEFORE="$(cksum < "$1")"
}

assert_file_changed() { # <label> <file>
  local label="$1" file="$2" after
  after="$(cksum < "$file")"
  if [ "$MUTATION_BEFORE" != "$after" ]; then
    return 0
  fi
  bad "${label} の置換対象が見つからず fixture が未変更"
  return 1
}

reset_fixture() {
  rm -rf "$TMP/plugin"
  mkdir -p "$TMP/plugin/scripts" "$TMP/plugin/tests/agent-config-mirror" "$TMP/plugin/tests/lib"
  cp "$PLUGIN_ROOT/scripts/multi-agent.sh" "$TMP/plugin/scripts/multi-agent.sh"
  cp "$PLUGIN_ROOT/scripts/agent-config.yaml" "$TMP/plugin/scripts/agent-config.yaml"
  cp "$SOURCE_VERIFY" "$TMP/plugin/tests/agent-config-mirror/verify.sh"
  cp "$PLUGIN_ROOT/tests/lib/cli-registry-parser.sh" "$TMP/plugin/tests/lib/cli-registry-parser.sh"
  FIXTURE_VERIFY="$TMP/plugin/tests/agent-config-mirror/verify.sh"
  FIXTURE_MULTI="$TMP/plugin/scripts/multi-agent.sh"
  FIXTURE_YAML="$TMP/plugin/scripts/agent-config.yaml"
}

reset_completeness_fixture() {
  rm -rf "$TMP/plugin"
  mkdir -p "$TMP/plugin/scripts" "$TMP/plugin/tests/cli-registry-completeness" \
    "$TMP/plugin/tests/no-hardcoded-model" "$TMP/plugin/tests/lib"
  cp "$PLUGIN_ROOT/scripts/multi-agent.sh" "$TMP/plugin/scripts/multi-agent.sh"
  cp "$PLUGIN_ROOT/scripts/agent-config.yaml" "$TMP/plugin/scripts/agent-config.yaml"
  cp "$PLUGIN_ROOT/scripts/setup-multi-agent.sh" "$TMP/plugin/scripts/setup-multi-agent.sh"
  cp -R "$PLUGIN_ROOT/scripts/adapters" "$TMP/plugin/scripts/adapters"
  cp -R "$PLUGIN_ROOT/scripts/perspectives" "$TMP/plugin/scripts/perspectives"
  cp "$PLUGIN_ROOT/tests/cli-registry-completeness/verify.sh" \
    "$TMP/plugin/tests/cli-registry-completeness/verify.sh"
  cp "$PLUGIN_ROOT/tests/no-hardcoded-model/verify.sh" \
    "$TMP/plugin/tests/no-hardcoded-model/verify.sh"
  cp "$PLUGIN_ROOT/tests/lib/cli-registry-parser.sh" "$TMP/plugin/tests/lib/cli-registry-parser.sh"
  FIXTURE_VERIFY="$TMP/plugin/tests/cli-registry-completeness/verify.sh"
  FIXTURE_MULTI="$TMP/plugin/scripts/multi-agent.sh"
  FIXTURE_YAML="$TMP/plugin/scripts/agent-config.yaml"
}

run_fixture() { # <label> [PATH]
  local label="$1" path_value="${2:-$PATH}" output
  if output="$(PATH="$path_value" /bin/bash "$FIXTURE_VERIFY" 2>&1)"; then
    bad "$label が red にならなかった"
    RUN_OUTPUT="$output"
    return 1
  fi
  RUN_OUTPUT="$output"
  ok "$label が非 0 終了"
  return 0
}

echo "== agent-config-mirror mutation self-test =="

# 1. 健全なコピーはまず green。mutation runner 自体の壊れを先に検出する。
reset_fixture
if RUN_OUTPUT="$(/bin/bash "$FIXTURE_VERIFY" 2>&1)"; then
  assert_contains "baseline の検査件数が期待どおり" "$RUN_OUTPUT" "$MIRROR_PASS_LINE"
else
  bad "baseline が失敗した"
fi

# completeness 側の fixture も同じく green baseline を取る。これが無いと、コピー漏れで
# fixture が「対象が見つかりません」で即死しても run_fixture は「非 0 終了」を計上し、
# 副作用の marker が無いのも「拒否したから」ではなく「そこまで走らなかったから」に
# なる。空振りのアサートを pass として数えないための足場。
reset_completeness_fixture
if RUN_OUTPUT="$(/bin/bash "$FIXTURE_VERIFY" 2>&1)"; then
  assert_contains "completeness fixture の baseline が green" "$RUN_OUTPUT" "cli-registry-completeness verify:"
else
  # 「失敗した」だけでは、fixture のコピー漏れなのかレジストリ自体の不整合なのかが
  # 区別できず診断が行き止まりになる。実際の出力を添える。
  bad "completeness fixture の baseline が失敗した（fixture のコピー漏れ、またはレジストリ自体の不整合）"
  printf '    %s\n' "$RUN_OUTPUT" >&2
fi

# 2. 値ドリフト。**この suite が存在する理由そのもの**で、両側とも構造的には正常な
# YAML / case 文だが値だけが食い違う形。構造・輸送・安全系の mutation はすべて比較の
# 上流で止まるため、最終比較（compare_scalar / compare_perspective）を潰しても
# 他の mutation は全部 red のままで、ゲートが値照合能力を失ったことに気づけない。
#
# YAML 側だけを変える形と実装側だけを変える形の両方を撃つ。片側だけだと、比較の
# 引数を取り違える種類のバグが片方向でだけ露出する。
reset_fixture
remember_file "$FIXTURE_YAML"
perl -0pi -e 's/    command: claude\n/    command: gemini\n/' "$FIXTURE_YAML"
if assert_file_changed "YAML command 値ドリフト" "$FIXTURE_YAML" && run_fixture "YAML command 値ドリフト"; then
  assert_contains "command の食い違いを名指しで報告" "$RUN_OUTPUT" "command が不一致"
fi

reset_fixture
remember_file "$FIXTURE_YAML"
perl -0pi -e 's/    cost_tier: premium\n/    cost_tier: standard\n/' "$FIXTURE_YAML"
if assert_file_changed "YAML cost_tier 値ドリフト" "$FIXTURE_YAML" && run_fixture "YAML cost_tier 値ドリフト"; then
  assert_contains "cost_tier の食い違いを名指しで報告" "$RUN_OUTPUT" "cost_tier が不一致"
fi

reset_fixture
remember_file "$FIXTURE_MULTI"
perl -0pi -e 's/(get_cli_cost_tier\(\) \{\n  case "\$1" in\n    )claude-code\) echo "premium"/${1}claude-code) echo "standard"/' "$FIXTURE_MULTI"
if assert_file_changed "実装側 cost_tier 値ドリフト" "$FIXTURE_MULTI" && run_fixture "実装側 cost_tier 値ドリフト"; then
  assert_contains "実装だけ変えた食い違いも報告" "$RUN_OUTPUT" "cost_tier が不一致"
fi

reset_fixture
remember_file "$FIXTURE_YAML"
perl -0pi -e 's/        - type-design-analysis\n/        - api-surface-analysis\n/' "$FIXTURE_YAML"
if assert_file_changed "観点名の差し替え" "$FIXTURE_YAML" && run_fixture "観点名の差し替え"; then
  assert_contains "観点名の食い違いを報告" "$RUN_OUTPUT" "perspectives.review が不一致"
fi

# Issue #242 の GWT-2 そのもの: 実装側の観点を 1 つ増やし、YAML は据え置く。
reset_fixture
remember_file "$FIXTURE_MULTI"
perl -0pi -e 's/(get_cli_perspectives_review\(\) \{\n  case "\$1" in\n    claude-code\) echo "type-design-analysis code-simplification)"/${1} extra-perspective"/' "$FIXTURE_MULTI"
if assert_file_changed "実装側の観点追加" "$FIXTURE_MULTI" && run_fixture "実装側の観点追加"; then
  assert_contains "実装側の観点追加を報告" "$RUN_OUTPUT" "perspectives.review が不一致"
fi

# 観点は順序も load-bearing（プラン出力の並びに出る）。要素集合が同じままの
# 並べ替えは、集合比較へ退化した実装だと素通りする。
reset_fixture
remember_file "$FIXTURE_YAML"
perl -0pi -e 's/        - type-design-analysis\n        - code-simplification([^\n]*)\n/        - code-simplification$1\n        - type-design-analysis\n/' "$FIXTURE_YAML"
if assert_file_changed "観点の並べ替え" "$FIXTURE_YAML" && run_fixture "観点の並べ替え"; then
  assert_contains "要素集合が同じ並べ替えも不一致として報告" "$RUN_OUTPUT" "perspectives.review が不一致"
fi

reset_fixture
remember_file "$FIXTURE_YAML"
perl -0pi -e 's/^  claude-code: codex-cli$/  claude-code: gemini-cli/m' "$FIXTURE_YAML"
if assert_file_changed "fallback 値ドリフト" "$FIXTURE_YAML" && run_fixture "fallback 値ドリフト"; then
  assert_contains "fallback の食い違いを報告" "$RUN_OUTPUT" "fallback.claude-code が不一致"
fi

# 3. YAML 構造異常の**実注入**。単一ドキュメント検査と重複キー検査は、これまで
# 「yq が出力後に非 0 で落ちる」経路しか撃たれていなかった。比較そのもの
# （doc_count != 1 / dup_total != 0）を潰しても selftest が緑のままだったので、
# 実際に異常な YAML を食わせて検出を固定する。
#
# 重複キーは tasks.review.timeout に入れる。agents:/fallback: の重複は
# キー集合検査が独立に捕まえるため、重複キー検査の固有カバレッジにならない。
reset_fixture
remember_file "$FIXTURE_YAML"
perl -0pi -e 's/^    timeout: 900$/    timeout: 900\n    timeout: 1/m' "$FIXTURE_YAML"
if assert_file_changed "実重複キー注入" "$FIXTURE_YAML" && run_fixture "実重複キー注入"; then
  assert_contains "重複キーを検出する" "$RUN_OUTPUT" "重複キーがあります"
fi

reset_fixture
remember_file "$FIXTURE_YAML"
printf '%s\n' '---' 'version: "2.0"' >> "$FIXTURE_YAML"
if assert_file_changed "2 つ目のドキュメント注入" "$FIXTURE_YAML" && run_fixture "2 つ目のドキュメント注入"; then
  assert_contains "複数ドキュメントを検出する" "$RUN_OUTPUT" "単一ドキュメントではありません"
fi

# 4. scalar の埋込み末尾改行。raw command substitution なら消えて false-green になる。
reset_fixture
remember_file "$FIXTURE_YAML"
perl -0pi -e 's/command: claude\n/command: "claude\\n"\n/' "$FIXTURE_YAML"
if assert_file_changed "scalar 埋込み改行" "$FIXTURE_YAML" && run_fixture "scalar 埋込み改行"; then
  assert_contains "scalar 埋込み改行を構造異常として報告" "$RUN_OUTPUT" "安全な単一 token でない"
fi

# 5. sequence の 1 要素に改行。raw 行 transport なら 2 要素との境界を失う。
reset_fixture
perl -0pi -e 's/- type-design-analysis\n        - code-simplification[^\n]*/- "type-design-analysis\\ncode-simplification"/' "$FIXTURE_YAML"
if run_fixture "sequence 埋込み改行"; then
  assert_contains "sequence 埋込み改行を token 違反として報告" "$RUN_OUTPUT" "安全 token でない要素"
fi

# 6. map key の空白・改行・空文字。raw word splitting / 空行除外なら見失う。
for encoded_key in '"co dex"' '"co\ndex"' '""'; do
  reset_fixture
  ENCODED_KEY="$encoded_key" perl -0pi -e 's/agents:\n/agents:\n  $ENV{ENCODED_KEY}: {}\n/' "$FIXTURE_YAML"
  if run_fixture "特殊 map key ${encoded_key}"; then
    assert_contains "特殊 map key を compact JSON で保持" "$RUN_OUTPUT" "agents: のキーが想定外"
  fi
done

# 7. scalar / list / root map の型違い。後続の fallback 検査とサマリーまで集約する。
reset_fixture
perl -0pi -e 's/command: claude\n/command: [claude]\n/' "$FIXTURE_YAML"
perl -0pi -e 's/review:\n        - type-design-analysis/review: wrong-type/' "$FIXTURE_YAML"
perl -0pi -e 's/^fallback:\n(?:  [^\n]*\n)*/fallback: wrong-type\n/m' "$FIXTURE_YAML"
if run_fixture "複合型異常"; then
  assert_contains "scalar 型異常を報告" "$RUN_OUTPUT" "型が文字列でない"
  assert_contains "sequence 型異常を報告" "$RUN_OUTPUT" "配列でない"
  assert_contains "root map 型異常を報告" "$RUN_OUTPUT" "fallback: が map でない"
  assert_contains "型異常でも最終サマリーを報告" "$RUN_OUTPUT" "agent-config-mirror verify:"
fi

# 8. perspectives の未知 task key。
reset_fixture
perl -0pi -e 's/(    perspectives:\n)/$1      unknown:\n        - type-design-analysis\n/' "$FIXTURE_YAML"
if run_fixture "未知 perspective task"; then
  assert_contains "未知 perspective task を key set 違反として報告" "$RUN_OUTPUT" "perspectives のキーが想定外"
fi

# 9. sentinel の重複 / 逆順。
reset_fixture
perl -0pi -e 's/(# ── CLI Registry End ──)/$1\n$1/' "$FIXTURE_MULTI"
if run_fixture "終了 sentinel 重複"; then
  assert_contains "sentinel 重複を静的 parser で拒否" "$RUN_OUTPUT" "レジストリ境界が一意ではありません"
fi

reset_fixture
# 行位置を awk で確実に逆転させる。
awk '
  $0 == "# ── All known CLI names ──" { next }
  $0 == "# ── CLI Registry End ──" { print "# ── All known CLI names ──"; next }
  NR == 2 { print "# ── CLI Registry End ──" }
  { print }
' "$PLUGIN_ROOT/scripts/multi-agent.sh" > "$FIXTURE_MULTI"
if run_fixture "sentinel 逆順"; then
  assert_contains "sentinel 逆順を静的 parser で拒否" "$RUN_OUTPUT" "レジストリ境界が正順ではありません"
fi

# 10. sentinel 外で registry symbol を上書きすると、実行時だけ後続定義が勝って
# parser の値と食い違う。ファイル全体の一意性検査で false-green を拒否する。
reset_fixture
remember_file "$FIXTURE_MULTI"
perl -0pi -e 's/# ── CLI Registry End ──/# ── CLI Registry End ──\nALL_CLIS="grok-cli"/' "$FIXTURE_MULTI"
if assert_file_changed "sentinel 後の ALL_CLIS 再定義" "$FIXTURE_MULTI" && run_fixture "sentinel 後の ALL_CLIS 再定義"; then
  assert_contains "境界外の ALL_CLIS 書き換えを拒否" "$RUN_OUTPUT" "ALL_CLIS を registry 境界外で書き換えられません"
fi

reset_completeness_fixture
remember_file "$FIXTURE_MULTI"
perl -0pi -e 's/# ── CLI Registry End ──/# ── CLI Registry End ──\nget_cli_command() { echo "overridden"; }/' "$FIXTURE_MULTI"
if assert_file_changed "sentinel 後の lookup 再定義" "$FIXTURE_MULTI" && run_fixture "sentinel 後の lookup 再定義"; then
  assert_contains "境界外の lookup 定義を拒否" "$RUN_OUTPUT" "get_cli_command を registry 境界外で定義できません"
fi

# 行頭アンカーだけでは複合 command 内の定義を見逃す。同じ値変更を、実際に
# shell が受理する `then` 後の代入と `;` 後の関数定義でも個別に固定する。
reset_fixture
remember_file "$FIXTURE_MULTI"
perl -0pi -e 's/# ── CLI Registry End ──/# ── CLI Registry End ──\nif true; then ALL_CLIS="grok-cli"; fi/' "$FIXTURE_MULTI"
if assert_file_changed "複合 command 内の ALL_CLIS 再定義" "$FIXTURE_MULTI" && run_fixture "複合 command 内の ALL_CLIS 再定義"; then
  assert_contains "複合 command 内の ALL_CLIS 書き換えを拒否" "$RUN_OUTPUT" "ALL_CLIS を registry 境界外で書き換えられません"
fi

reset_completeness_fixture
remember_file "$FIXTURE_MULTI"
perl -0pi -e 's/# ── CLI Registry End ──/# ── CLI Registry End ──\ntrue; get_cli_command() { echo "overridden"; }/' "$FIXTURE_MULTI"
if assert_file_changed "複合 command 内の lookup 再定義" "$FIXTURE_MULTI" && run_fixture "複合 command 内の lookup 再定義"; then
  assert_contains "複合 command 内の lookup 定義を拒否" "$RUN_OUTPUT" "get_cli_command を registry 境界外で定義できません"
fi

# `NAME=` 形だけを列挙すると、`=` を使わずに変数へ書き込む形が丸ごと素通りする。
# 下の 4 つはいずれも bash 3.2 で実際に ALL_CLIS を上書きでき、旧実装では green だった。
for bypass in \
  'printf -v ALL_CLIS %s "grok-cli"' \
  'read -r ALL_CLIS <<< "grok-cli"' \
  'read -r -a ALL_CLIS <<< "grok-cli"' \
  'unset ALL_CLIS'; do
  reset_fixture
  remember_file "$FIXTURE_MULTI"
  BYPASS="$bypass" perl -0pi -e 's/# ── CLI Registry End ──/"# ── CLI Registry End ──\n" . $ENV{BYPASS}/e' "$FIXTURE_MULTI"
  if assert_file_changed "= を使わない ALL_CLIS 書き換え (${bypass})" "$FIXTURE_MULTI" &&
    run_fixture "= を使わない ALL_CLIS 書き換え (${bypass})"; then
    assert_contains "${bypass} を拒否" "$RUN_OUTPUT" "ALL_CLIS を registry 境界外で書き換えられません"
  fi
done

# 行継続で識別子を割ると、物理行単位の検査はすり抜けるが shell には 1 つの定義として届く。
reset_fixture
remember_file "$FIXTURE_MULTI"
perl -0pi -e 's/# ── CLI Registry End ──/# ── CLI Registry End ──\nget_cli_\\\ncommand() { echo "overridden"; }/' "$FIXTURE_MULTI"
if assert_file_changed "行継続で割った lookup 定義" "$FIXTURE_MULTI" && run_fixture "行継続で割った lookup 定義"; then
  assert_contains "行継続を畳んでから拒否" "$RUN_OUTPUT" "get_cli_command を registry 境界外で定義できません"
fi

# required の名前だけを照合すると、**新しい** registry 関数を境界外に足したときに
# 見逃す。接頭辞で拾って allowlist で許す形になっていることを固定する。
reset_fixture
remember_file "$FIXTURE_MULTI"
perl -0pi -e 's/# ── CLI Registry End ──/# ── CLI Registry End ──\nget_cli_region() { echo "tokyo"; }/' "$FIXTURE_MULTI"
if assert_file_changed "境界外の新規 registry 関数" "$FIXTURE_MULTI" && run_fixture "境界外の新規 registry 関数"; then
  assert_contains "未知の get_cli_* 定義も拒否" "$RUN_OUTPUT" "get_cli_region を registry 境界外で定義できません"
fi

# 逆向きの固定。境界外検査は実行されないコメント行に発火してはいけない。
# multi-agent.sh は日本語コメントで lookup 名を繰り返し引用しており、`関数名()` と
# 書いた瞬間に「再定義できません」と出ると、何も再定義していないのに診断が嘘になる。
reset_fixture
remember_file "$FIXTURE_MULTI"
perl -0pi -e 's/# ── CLI Registry End ──/# ── CLI Registry End ──\n# 正本は get_cli_command()\n# ALL_CLIS の順に回す/' "$FIXTURE_MULTI"
if assert_file_changed "コメント行での言及" "$FIXTURE_MULTI"; then
  if RUN_OUTPUT="$(/bin/bash "$FIXTURE_VERIFY" 2>&1)"; then
    assert_contains "コメント行の言及では red にしない" "$RUN_OUTPUT" "$MIRROR_PASS_LINE"
  else
    bad "コメント行での関数名・変数名の言及を再定義と誤検出した"
  fi
else
  # green 経路の mutation は「red にならなかった」で捕まえられない。置換が不成立だと
  # 確認そのものが走らないので、件数の食い違いだけでなく理由も残す。
  echo "    → コメント行の言及が green のままであることの確認は実行されていない" >&2
fi

# 11. registry 内の副作用。トップレベル・閉じ括弧バイパス・関数本体のいずれも
# shell として実行せず、制限文法 parser が marker 作成前に拒否する。
reset_fixture
SIDE_EFFECT="$TMP/should-not-exist-top-level"
SIDE_EFFECT_LINE="touch '$SIDE_EFFECT'"
remember_file "$FIXTURE_MULTI"
SIDE_EFFECT_LINE="$SIDE_EFFECT_LINE" perl -0pi -e 's/# ── CLI Registry End ──/$ENV{SIDE_EFFECT_LINE}\n# ── CLI Registry End ──/' "$FIXTURE_MULTI"
if assert_file_changed "registry トップレベル副作用" "$FIXTURE_MULTI" && run_fixture "registry トップレベル副作用"; then
  assert_contains "トップレベル副作用を静的 parser で拒否" "$RUN_OUTPUT" "許可されていないトップレベル行"
  if [ ! -e "$SIDE_EFFECT" ]; then ok "トップレベル副作用を実行しない"; else bad "トップレベル副作用が実行された"; fi
fi

reset_fixture
SIDE_EFFECT="$TMP/should-not-exist-close-bypass"
SIDE_EFFECT_LINE="}; touch '$SIDE_EFFECT'"
remember_file "$FIXTURE_MULTI"
SIDE_EFFECT_LINE="$SIDE_EFFECT_LINE" perl -0pi -e 's/^}$/\Q$ENV{SIDE_EFFECT_LINE}\E/m' "$FIXTURE_MULTI"
if assert_file_changed "閉じ括弧副作用バイパス" "$FIXTURE_MULTI" && run_fixture "閉じ括弧副作用バイパス"; then
  # shellcheck disable=SC2016 # parser 診断中の shell 構文は意図的なリテラル
  assert_contains "閉じ括弧副作用を静的 parser で拒否" "$RUN_OUTPUT" 'case の後は `}` だけで関数を閉じなければなりません'
  if [ ! -e "$SIDE_EFFECT" ]; then ok "閉じ括弧副作用を実行しない"; else bad "閉じ括弧副作用が実行された"; fi
fi

reset_fixture
SIDE_EFFECT="$TMP/should-not-exist-function-body"
SIDE_EFFECT_LINE="  touch '$SIDE_EFFECT'"
remember_file "$FIXTURE_MULTI"
SIDE_EFFECT_LINE="$SIDE_EFFECT_LINE" perl -0pi -e 's/(get_cli_command\(\) \{\n)/$1$ENV{SIDE_EFFECT_LINE}\n/' "$FIXTURE_MULTI"
if assert_file_changed "lookup 関数本体副作用" "$FIXTURE_MULTI" && run_fixture "lookup 関数本体副作用"; then
  # shellcheck disable=SC2016 # parser 診断中の $1 は意図的なリテラル
  assert_contains "lookup 本体副作用を静的 parser で拒否" "$RUN_OUTPUT" '関数先頭は `case "$1" in` でなければなりません'
  if [ ! -e "$SIDE_EFFECT" ]; then ok "lookup 本体副作用を実行しない"; else bad "lookup 本体副作用が実行された"; fi
fi

# 同じ共有 parser を使う completeness suite でも C1 の 2 経路を個別に固定する。
reset_completeness_fixture
SIDE_EFFECT="$TMP/completeness-should-not-exist-close-bypass"
SIDE_EFFECT_LINE="}; touch '$SIDE_EFFECT'"
remember_file "$FIXTURE_MULTI"
SIDE_EFFECT_LINE="$SIDE_EFFECT_LINE" perl -0pi -e 's/^}$/\Q$ENV{SIDE_EFFECT_LINE}\E/m' "$FIXTURE_MULTI"
if assert_file_changed "completeness 閉じ括弧副作用" "$FIXTURE_MULTI" && run_fixture "completeness 閉じ括弧副作用"; then
  # shellcheck disable=SC2016 # parser 診断中の shell 構文は意図的なリテラル
  assert_contains "completeness も閉じ括弧副作用を拒否" "$RUN_OUTPUT" 'case の後は `}` だけで関数を閉じなければなりません'
  if [ ! -e "$SIDE_EFFECT" ]; then ok "completeness が閉じ括弧副作用を実行しない"; else bad "completeness が閉じ括弧副作用を実行した"; fi
fi

reset_completeness_fixture
SIDE_EFFECT="$TMP/completeness-should-not-exist-function-body"
SIDE_EFFECT_LINE="  touch '$SIDE_EFFECT'"
remember_file "$FIXTURE_MULTI"
SIDE_EFFECT_LINE="$SIDE_EFFECT_LINE" perl -0pi -e 's/(get_cli_command\(\) \{\n)/$1$ENV{SIDE_EFFECT_LINE}\n/' "$FIXTURE_MULTI"
if assert_file_changed "completeness lookup 本体副作用" "$FIXTURE_MULTI" && run_fixture "completeness lookup 本体副作用"; then
  # shellcheck disable=SC2016 # parser 診断中の $1 は意図的なリテラル
  assert_contains "completeness も lookup 本体副作用を拒否" "$RUN_OUTPUT" '関数先頭は `case "$1" in` でなければなりません'
  if [ ! -e "$SIDE_EFFECT" ]; then ok "completeness が lookup 本体副作用を実行しない"; else bad "completeness が lookup 本体副作用を実行した"; fi
fi

# 12. ALL_CLIS の duplicate / glob / 非 canonical space は fail-closed。
for replacement in \
  'claude-code claude-code codex-cli copilot-cli gemini-cli grok-cli' \
  'claude-code * codex-cli copilot-cli gemini-cli grok-cli' \
  'claude-code  codex-cli copilot-cli gemini-cli grok-cli'; do
  reset_fixture
  REPLACEMENT="$replacement" perl -0pi -e 's/^ALL_CLIS="[^"]*"$/ALL_CLIS="$ENV{REPLACEMENT}"/m' "$FIXTURE_MULTI"
  if run_fixture "ALL_CLIS 異常 (${replacement})"; then
    case "$replacement" in
      'claude-code claude-code'*)
        assert_contains "ALL_CLIS 重複を token 検査で拒否" "$RUN_OUTPUT" "重複 token がある"
        ;;
      *)
        assert_contains "ALL_CLIS の危険な形を静的 parser で拒否" "$RUN_OUTPUT" "ALL_CLIS は安全 token の単一 ASCII space 区切り"
        ;;
    esac
  fi
done

# 13. map key set は順不同。ALL_CLIS の正当な並べ替えは green のままにする。
# green が単なる置換 no-op でも成立しないよう、実行前に fixture の変更を必ず確認する。
reset_fixture
remember_file "$FIXTURE_MULTI"
REVERSED_ALL_CLIS="$REVERSED_ALL_CLIS" perl -0pi -e 's/^ALL_CLIS="[^"]*"$/"ALL_CLIS=\"" . $ENV{REVERSED_ALL_CLIS} . "\""/me' "$FIXTURE_MULTI"
if assert_file_changed "ALL_CLIS 正当並べ替え" "$FIXTURE_MULTI"; then
  if RUN_OUTPUT="$(/bin/bash "$FIXTURE_VERIFY" 2>&1)"; then
    assert_contains "ALL_CLIS 並べ替え後も key set が一致" "$RUN_OUTPUT" "$MIRROR_PASS_LINE"
  else
    bad "ALL_CLIS の正当な並べ替えを key set 差分と誤認した"
  fi
else
  # 同上。CLI が 1 件だけのロスターでは反転しても元と同じになるため、置換不成立は
  # 「起こりえない」ではなく「起こったら確認が消える」side として扱う。
  echo "    → 正当な並べ替えが green のままであることの確認は実行されていない" >&2
fi

# 14. lookup arm に command を混ぜた source は実行せず、制限文法違反として拒否する。
reset_fixture
remember_file "$FIXTURE_MULTI"
perl -0pi -e 's/claude-code\) echo "claude" ;;/claude-code) echo "claude"; return 23 ;;/' "$FIXTURE_MULTI"
if assert_file_changed "lookup arm command 混入" "$FIXTURE_MULTI" && run_fixture "lookup arm command 混入"; then
  # shellcheck disable=SC2016 # parser 診断中の shell 構文は意図的なリテラル
  assert_contains "lookup arm の任意 command を静的 parser で拒否" "$RUN_OUTPUT" 'case arm は `<token>) echo "固定値" ;;` 形式'
fi

# 15. yq の flavor/version/capability と producer status を偽る shim。
REAL_YQ="$(command -v yq)"
for mode in python-yq v3 bad-capability partial-failure document-count-failure duplicate-key-failure; do
  reset_fixture
  STUB="$TMP/yq-${mode}"
  mkdir -p "$STUB"
  cat > "$STUB/yq" <<EOF
#!/usr/bin/env bash
case "${mode}" in
  python-yq) echo 'yq 3.4.3'; exit 0 ;;
  v3) echo 'yq (https://github.com/mikefarah/yq/) version v3.4.1'; exit 0 ;;
  bad-capability)
    if [[ "\${1:-}" == --version ]]; then echo 'yq (https://github.com/mikefarah/yq/) version v4.52.4'; exit 0; fi
    echo '{}'; exit 0 ;;
  partial-failure)
    if [[ "\${1:-}" == --version ]]; then echo 'yq (https://github.com/mikefarah/yq/) version v4.52.4'; exit 0; fi
    if [[ "\${*}" == *'"doc": documentIndex'* ]]; then exec "$REAL_YQ" "\$@"; fi
    if [[ "\${1:-}" == '.' ]]; then exec "$REAL_YQ" "\$@"; fi
    if [[ "\${*}" == *documentIndex* || "\${*}" == *'keys | length'* ]]; then exec "$REAL_YQ" "\$@"; fi
    echo 'partial-output'; exit 23 ;;
  document-count-failure)
    if [[ "\${1:-}" == --version ]]; then echo 'yq (https://github.com/mikefarah/yq/) version v4.52.4'; exit 0; fi
    if [[ "\${*}" == *'"doc": documentIndex'* || "\${1:-}" == '.' ]]; then exec "$REAL_YQ" "\$@"; fi
    if [[ "\${*}" == *documentIndex* ]]; then echo '0'; exit 23; fi
    exec "$REAL_YQ" "\$@" ;;
  duplicate-key-failure)
    if [[ "\${1:-}" == --version ]]; then echo 'yq (https://github.com/mikefarah/yq/) version v4.52.4'; exit 0; fi
    if [[ "\${*}" == *'"doc": documentIndex'* || "\${1:-}" == '.' || "\${*}" == *documentIndex* ]]; then exec "$REAL_YQ" "\$@"; fi
    # capability probe（"dupes" を含む）は素通し。probe まで潰すと「probe が失敗した」
    # 側で先に落ちてしまい、重複キー検査の出力後 nonzero を撃てない。
    if [[ "\${*}" == *'"dupes"'* ]]; then exec "$REAL_YQ" "\$@"; fi
    if [[ "\${*}" == *'keys | length'* ]]; then echo '0'; exit 23; fi
    exec "$REAL_YQ" "\$@" ;;
esac
EOF
  chmod +x "$STUB/yq"
  if run_fixture "yq shim ${mode}" "$STUB:/usr/bin:/bin"; then
    case "$mode" in
      python-yq|v3) assert_contains "非 Mike Farah v4 を拒否" "$RUN_OUTPUT" "Mike Farah yq v4 が必要" ;;
      bad-capability) assert_contains "能力 probe 不一致を拒否" "$RUN_OUTPUT" "capability probe の結果が非互換" ;;
      partial-failure)
        assert_contains "yq 出力後 nonzero を検査失敗として報告" "$RUN_OUTPUT" "tag の取得に失敗: partial-output"
        assert_contains "yq 非 0 でも最終サマリーを報告" "$RUN_OUTPUT" "agent-config-mirror verify:"
        ;;
      document-count-failure)
        assert_contains "document count の出力後 nonzero を拒否" "$RUN_OUTPUT" "document 数を取得できません"
        ;;
      duplicate-key-failure)
        assert_contains "duplicate key 検査の出力後 nonzero を拒否" "$RUN_OUTPUT" "重複キー検査を実行できません"
        ;;
    esac
  fi
done

echo
if [ "$FAIL" -gt 0 ]; then
  echo "✗ agent-config-mirror self-test: $FAIL 件失敗" >&2
  exit 1
fi
echo "✓ agent-config-mirror self-test: 全 $PASS 件 pass"
FF_REACHED_END=1
