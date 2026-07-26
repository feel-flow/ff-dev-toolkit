#!/usr/bin/env bash
#
# コマンド定義 frontmatter のポリシー検査（Issue #145 / ACE-147-1）。
#
# `disable-model-invocation: true` は SlashCommand ツールからの呼び出しを塞ぐ。
# しかし実体を同梱スクリプトへ抽出したコマンド（コマンド md が
# `bash "${CLAUDE_PLUGIN_ROOT}/scripts/x.sh" $ARGUMENTS` の 1 行）では、モデルは
# 同じスクリプトを Bash から直接叩けるため、破壊的操作は防げない。塞げるのは
# ラッパーの発見性だけである。一方 docs-template の
# `05-operations/deployment/workflow-principles.md` はフルオート 10 ステップの
# step 10 に `/merge-cleanup` を置いており、フラグは必須ステップの可用性だけを削る。
#
# 本 suite は全コマンドの frontmatter に同フラグ（`false` 以外の値）が無いことを
# fail-closed で検証する。真に任意のコマンド（人間が発火タイミングを決めるべき
# もの）で必要になった場合は下の ALLOWLIST へ理由付きで追加する。黙って付けるのを
# 防ぐのが目的で、禁止そのものが目的ではない。
#
# 一時ディレクトリも jq も要らない純粋なファイル検査なので、書き込み不可の環境でも
# 完走する。`run-all.sh` では最も安価な本 suite を先頭に置く（Issue #146 でランナーは
# 全 suite を実行する集約方式になったので、並び順は報告の読みやすさの問題）。

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
COMMANDS_DIR="$PLUGIN_ROOT/commands"

[ -d "$COMMANDS_DIR" ] || { echo "✗ commands ディレクトリが見つかりません: $COMMANDS_DIR" >&2; exit 1; }

# `disable-model-invocation` を意図的に許容するコマンドの basename。
# 追加するときは必ず理由をコメントで残す（例: 人間が発火タイミングを決めるべき
# 対話専用コマンドで、ワークフロー正本が自動実行を要求していない）。
ALLOWLIST=()

PASS=0
FAIL=0
ok()  { echo "  ✓ $1"; PASS=$((PASS + 1)); }
bad() { echo "  ✗ $1" >&2; FAIL=$((FAIL + 1)); }

is_allowlisted() {
  local name="$1" entry
  for entry in ${ALLOWLIST[@]+"${ALLOWLIST[@]}"}; do
    [ "$entry" = "$name" ] && return 0
  done
  return 1
}

# frontmatter（先頭 `---` から 2 つ目の `---` まで）を stdout へ出す。
# CR は落とす（CRLF ファイルで `/^---$/` が一致せず、抽出が静かに空になるのを防ぐ）。
extract_frontmatter() {
  awk '{ sub(/\r$/, "") } /^---$/{ n++; next } n==1{ print } n==2{ exit }' "$1"
}

echo "== コマンド frontmatter ポリシー検査 =="

shopt -s nullglob
COMMAND_FILES=("$COMMANDS_DIR"/*.md)
shopt -u nullglob

if [ "${#COMMAND_FILES[@]}" -eq 0 ]; then
  echo "✗ commands/*.md が 1 件も見つかりません（検査対象ゼロは異常）" >&2
  exit 1
fi

for file in "${COMMAND_FILES[@]}"; do
  name="$(basename "$file")"

  # 先頭行が正確に `---` であることを要求する。BOM 付き・先頭空行・別形式のときは
  # frontmatter を特定できないので、黙って pass させず loud に落とす
  # （負の主張の検査は「本当に見たのか」を先に確かめないと自己無効化する）。
  if ! first_line="$(head -n 1 "$file")"; then
    bad "$name — 先頭行を読み取れませんでした"
    continue
  fi
  first_line="${first_line%$'\r'}"
  if [ "$first_line" != "---" ]; then
    bad "$name — 先頭行が '---' ではありません（BOM / 先頭空行 / frontmatter 無し）: $(printf '%q' "$first_line")"
    continue
  fi

  # 抽出そのものの失敗を pass に埋もらせない（pipefail 下でも command substitution の
  # 終了ステータスを明示的に見る）。
  if ! frontmatter="$(extract_frontmatter "$file")"; then
    bad "$name — frontmatter の抽出に失敗しました"
    continue
  fi

  # 正の主張: 抽出結果が空でなく、既知キーを含む。これが無いと「0 行を検査して ✓」
  # という空虚な pass を許してしまう。
  if [ -z "$frontmatter" ]; then
    bad "$name — frontmatter が空です（抽出範囲を特定できていない可能性）"
    continue
  fi
  if ! printf '%s\n' "$frontmatter" | grep -Eq '^[[:space:]]*description:'; then
    bad "$name — frontmatter に description: がありません（抽出範囲が誤っている可能性）"
    continue
  fi

  # フラグ行を集める。grep の終了コード 1（不一致）は正常、2 以上は検査自体の失敗。
  set +e
  flag_lines="$(printf '%s\n' "$frontmatter" | grep -E '^[[:space:]]*disable-model-invocation:')"
  grep_status=$?
  set -e
  if [ "$grep_status" -ge 2 ]; then
    bad "$name — frontmatter の検査自体が失敗しました（grep exit $grep_status）"
    continue
  fi

  if [ "$grep_status" -eq 1 ]; then
    ok "$name — disable-model-invocation なし"
    continue
  fi

  # 値を正規化して `false` 以外を拒否する。true / True / TRUE / 'true' / "true" /
  # yes / on / 行末コメント付き / 値を次行に書いた形（値が空になる）をまとめて捕まえる。
  offending=""
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    value="${line#*:}"
    value="${value%%#*}"
    value="$(printf '%s' "$value" | tr -d '"'"'"'[:space:]' | tr '[:upper:]' '[:lower:]')"
    if [ "$value" != "false" ]; then
      offending="$line"
      break
    fi
  done <<EOF
$flag_lines
EOF

  if [ -z "$offending" ]; then
    ok "$name — disable-model-invocation は明示 false（既定値と同じなので実害なし）"
    continue
  fi

  if is_allowlisted "$name"; then
    ok "$name — disable-model-invocation あり（ALLOWLIST 記載）"
    continue
  fi

  bad "$name — disable-model-invocation が有効になっています: $(printf '%q' "$offending")"
  echo "    このフラグは実体をスクリプトへ抽出したコマンドでは破壊的操作を防げず" >&2
  echo "    （同じスクリプトを Bash から直接叩ける）、ワークフロー正本" >&2
  echo "    （docs-template の 05-operations/deployment/workflow-principles.md）が" >&2
  echo "    step 10 に置く必須ステップの可用性だけを削ります。詳細は ACE-147-1。" >&2
  echo "    真に任意のコマンドなら本ファイルの ALLOWLIST へ理由付きで追加してください。" >&2
done

echo ""
if [ "$FAIL" -gt 0 ]; then
  echo "✗ command-frontmatter verify: $FAIL 件失敗" >&2
  exit 1
fi
echo "✓ command-frontmatter verify: 全 $PASS 件 pass"
