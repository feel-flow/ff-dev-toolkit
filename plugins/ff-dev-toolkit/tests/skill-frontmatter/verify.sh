#!/usr/bin/env bash
#
# Skill frontmatter と単一正本のポリシー検査（Issue #141 / #145 / ACE-147-1）。
#
# `disable-model-invocation: true` はモデルからの呼び出しを塞ぐ。
# しかし実体を同梱スクリプトへ抽出した skill（SKILL.md が
# `bash "${FF_DEV_TOOLKIT_ROOT}/scripts/x.sh" $ARGUMENTS` の 1 行）では、モデルは
# 同じスクリプトを Bash から直接叩けるため、破壊的操作は防げない。塞げるのは
# ラッパーの発見性だけである。一方 docs-template の
# `05-operations/deployment/workflow-principles.md` はフルオート 10 ステップの
# step 10 に `/merge-cleanup` を置いており、フラグは必須ステップの可用性だけを削る。
#
# 本 suite は全 skill が Agent Skills 標準の構造・name を持ち、frontmatter に
# 同フラグ（`false` 以外の値）が無いことを fail-closed で検証する。真に任意の skill
# （人間が発火タイミングを決めるべき
# もの）で必要になった場合は下の ALLOWLIST へ理由付きで追加する。黙って付けるのを
# 防ぐのが目的で、禁止そのものが目的ではない。
#
# 一時ディレクトリも jq も要らない純粋なファイル検査なので、書き込み不可の環境でも
# 完走する。`run-all.sh` では最も安価な本 suite を先頭に置く（Issue #146 でランナーは
# 全 suite を実行する集約方式になったので、並び順は報告の読みやすさの問題）。

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SKILLS_DIR="$PLUGIN_ROOT/skills"

[ -d "$SKILLS_DIR" ] || { echo "✗ skills ディレクトリが見つかりません: $SKILLS_DIR" >&2; exit 1; }

# Issue #141 で移行した14手順。将来 skill が増えてもよいが、この14件の欠落は
# Codex 対応範囲の後退なので fail-closed で拒否する。
MIGRATED_SKILLS=(
  ace-curate ace-setup assess-impact close-issue create-issue init-docs
  merge-cleanup multi-explore multi-implement multi-review pre-commit-check
  refine-issue setup-ai-config validate-docs
)
for migrated in "${MIGRATED_SKILLS[@]}"; do
  [ -s "$SKILLS_DIR/$migrated/SKILL.md" ] || {
    echo "✗ Issue #141 の移行対象 skill が見つからないか空です: $migrated" >&2
    exit 1
  }
done

# Issue #141 で commands/*.md は同名 skills/*/SKILL.md へ正本移行した。
# legacy command を再追加すると Codex から見えない第2正本が復活するため拒否する。
if [ -d "$PLUGIN_ROOT/commands" ] && find "$PLUGIN_ROOT/commands" -type f -name '*.md' -print -quit | grep . >/dev/null; then
  echo "✗ legacy commands/*.md が残っています。skills/<name>/SKILL.md を単一正本にしてください" >&2
  exit 1
fi

# `disable-model-invocation` を意図的に許容する skill 名。
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

echo "== Skill frontmatter・単一正本ポリシー検査 =="

shopt -s nullglob
SKILL_FILES=("$SKILLS_DIR"/*/SKILL.md)
shopt -u nullglob

if [ "${#SKILL_FILES[@]}" -eq 0 ]; then
  echo "✗ skills/*/SKILL.md が 1 件も見つかりません（検査対象ゼロは異常）" >&2
  exit 1
fi

for file in "${SKILL_FILES[@]}"; do
  name="$(basename "$(dirname "$file")")"

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
  if ! declared_name="$(printf '%s\n' "$frontmatter" | awk -F: '/^[[:space:]]*name:/{ sub(/^[^:]*:[[:space:]]*/, ""); print; exit }')"; then
    bad "$name — frontmatter の name 抽出に失敗しました"
    continue
  fi
  declared_name="$(printf '%s' "$declared_name" | tr -d "\"'[:space:]")"
  if [ "$declared_name" != "$name" ]; then
    bad "$name — frontmatter name がディレクトリ名と一致しません: $(printf '%q' "$declared_name")"
    continue
  fi
  unsupported_keys="$(printf '%s\n' "$frontmatter" | awk -F: '
    /^[A-Za-z0-9_-]+:/ {
      key=$1
      if (key != "name" && key != "description" && key != "license" &&
          key != "allowed-tools" && key != "metadata") print key
    }
  ')"
  if [ -n "$unsupported_keys" ]; then
    bad "$name — Agent Skills 標準外の frontmatter key があります: $(printf '%s' "$unsupported_keys" | paste -sd, -)"
    continue
  fi
  if grep -Eq '(/cache/|plugins/cache)[^`[:space:]]*/[0-9]+\.[0-9]+' "$file"; then
    bad "$name — バージョン固定 cache パスが含まれています"
    continue
  fi
  if grep -Eq 'AskUserQuestion|`(Task|Write|Edit)` ツール' "$file"; then
    bad "$name — 特定ホスト固有のツール名を必須手順に使用しています"
    continue
  fi

  # フラグ行を集める。grep の終了コード 1（不一致）は正常、2 以上は検査自体の失敗。
  set +e
  flag_lines="$(printf '%s\n' "$frontmatter" | grep -E '^[[:space:]]*disable-model-invocation:')"
  grep_status=$?
  set -e
  if [ "$grep_status" -ge 2 ]; then
    bad "$name — frontmatter の検査自体が失敗しました（grep exit ${grep_status}）"
    continue
  fi

  if [ "$grep_status" -eq 1 ]; then
    ok "$name — name/description 正常、disable-model-invocation なし"
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
  echo "    このフラグは実体をスクリプトへ抽出した skill では破壊的操作を防げず" >&2
  echo "    （同じスクリプトを Bash から直接叩ける）、ワークフロー正本" >&2
  echo "    （docs-template の 05-operations/deployment/workflow-principles.md）が" >&2
  echo "    step 10 に置く必須ステップの可用性だけを削ります。詳細は ACE-147-1。" >&2
  echo "    真に任意の skill なら本ファイルの ALLOWLIST へ理由付きで追加してください。" >&2
done

echo ""
if [ "$FAIL" -gt 0 ]; then
  echo "✗ skill-frontmatter verify: $FAIL 件失敗" >&2
  exit 1
fi
echo "✓ skill-frontmatter verify: 全 $PASS 件 pass"
