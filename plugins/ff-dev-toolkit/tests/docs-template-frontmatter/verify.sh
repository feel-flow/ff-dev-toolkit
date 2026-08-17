#!/usr/bin/env bash
#
# docs-template 初期セット 20 文書の構造契約検査（Issue #509）。
#
# /init-docs の初期セット 20 ファイルは全数が YAML Frontmatter（必須6フィールド）と
# 文書末尾の `## Changelog` セクションを持つ、という規則を #509 で確立した。しかし
# /validate-docs の拡張文書チェックは「Frontmatter を持つ場合のみ検証」のオプトイン
# 設計なので、テンプレートから Frontmatter が欠落する回帰が起きると、生成された
# docs は再び検証対象から静かに漏れる（#509 以前の状態への逆戻り）。この規則は
# 他のどの suite も守っていないため、本 suite が fail-closed で固定する。
#
# 検査:
#   A. 初期セット 20 ファイルが実在する（欠落 = 赤）
#   B. skills/init-docs/SKILL.md のディレクトリ構造ツリー（ステップ2 のフェンス）と
#      本 suite の一覧が集合として一致する（SKILL 側だけ増減 = 赤。一覧の複製 drift
#      を fail-closed で検出する）
#   C. 各ファイルの先頭行が `---` で、Frontmatter ブロックが閉じている
#   D. 必須6フィールド（title / version / status / owner / created / updated）が
#      引用符付き `key: "value"` 形式で揃っている
#   E. version が SemVer 形式、status が値域（draft/review/approved/deprecated）内
#   F. changeImpact は存在する場合のみ小文字 low/medium/high（初版省略可のため
#      存在自体は要求しない。MASTER.md の文書管理ルール準拠）
#   G. 文書内に `## Changelog` 見出しがある
#
# 正規表現は ASCII クラスのみ使用（bash 3.2 / BSD ツールの MBCS 事故防止）。
# 一時ディレクトリ不要の純粋なファイル検査で、read-only 環境でも完走する。
#
# FF_DOCS_TEMPLATE_ROOT でプラグインルートを差し替えられる（selftest 用。
# 直下に docs-template/ と skills/init-docs/SKILL.md がある前提）。

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DEFAULT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
ROOT="${FF_DOCS_TEMPLATE_ROOT:-$DEFAULT_ROOT}"

TEMPLATE_DIR="$ROOT/docs-template"
INIT_DOCS_SKILL="$ROOT/skills/init-docs/SKILL.md"

[ -d "$TEMPLATE_DIR" ] || { echo "✗ docs-template が見つかりません: $TEMPLATE_DIR" >&2; exit 1; }
[ -f "$INIT_DOCS_SKILL" ] || { echo "✗ skills/init-docs/SKILL.md が見つかりません: $INIT_DOCS_SKILL" >&2; exit 1; }

PASS=0
FAIL=0
ok()  { echo "  ✓ $1"; PASS=$((PASS + 1)); }
bad() { echo "  ✗ $1" >&2; FAIL=$((FAIL + 1)); }

# 初期セット 20 ファイル（skills/init-docs/SKILL.md ステップ2 のツリーの複製。
# 検査 B が SKILL 側との集合一致を fail-closed で照合する）
INITIAL_SET=(
  "MASTER.md"
  "01-context/PROJECT.md"
  "01-context/CONSTRAINTS.md"
  "02-design/ARCHITECTURE.md"
  "02-design/DOMAIN.md"
  "02-design/API.md"
  "02-design/DATABASE.md"
  "03-implementation/PATTERNS.md"
  "03-implementation/CONVENTIONS.md"
  "03-implementation/INTEGRATIONS.md"
  "03-implementation/DECISION_TREE.md"
  "03-implementation/FALLBACK.md"
  "04-quality/TESTING.md"
  "04-quality/VALIDATION.md"
  "05-operations/DEPLOYMENT.md"
  "06-reference/GLOSSARY.md"
  "06-reference/DECISIONS.md"
  "07-project-management/ROADMAP.md"
  "07-project-management/TASKS.md"
  "07-project-management/RISKS.md"
)

echo "== A. 初期セット 20 ファイルの実在 =="
if [ "${#INITIAL_SET[@]}" -eq 20 ]; then
  ok "一覧の件数が 20"
else
  bad "一覧の件数が 20 ではありません: ${#INITIAL_SET[@]}"
fi
for rel in "${INITIAL_SET[@]}"; do
  if [ -f "$TEMPLATE_DIR/$rel" ]; then
    ok "実在: $rel"
  else
    bad "初期セットのファイルが見つかりません: $rel"
  fi
done

echo "== B. skills/init-docs/SKILL.md のツリーとの集合一致 =="
# ステップ2 見出し（### 2.）以降の最初のフェンスブロックから *.md 名を抽出する。
# フェンスの検出・ファイル名抽出とも ASCII パターンのみ（罫線文字には触れない）。
tree_names="$(awk '
  /^### 2\./ { in_step2 = 1; next }
  in_step2 && /^```/ { if (in_fence) { exit } in_fence = 1; next }
  in_fence { print }
' "$INIT_DOCS_SKILL" | grep -oE '[A-Za-z_]+\.md' | LC_ALL=C sort)"
list_names="$(for rel in "${INITIAL_SET[@]}"; do basename "$rel"; done | LC_ALL=C sort)"
if [ -z "$tree_names" ]; then
  bad "SKILL.md のツリーから .md 名を 1 件も抽出できません（抽出の空振りを緑にしない）"
elif [ "$tree_names" = "$list_names" ]; then
  ok "SKILL.md のツリーと本 suite の一覧が一致（$(printf '%s\n' "$tree_names" | wc -l | tr -d ' ') 件）"
else
  bad "SKILL.md のツリーと本 suite の一覧が乖離しています（どちらかの更新漏れ）"
  echo "  --- SKILL.md 側にのみ存在:" >&2
  LC_ALL=C comm -23 <(printf '%s\n' "$tree_names") <(printf '%s\n' "$list_names") | sed 's/^/    /' >&2
  echo "  --- 本 suite 側にのみ存在:" >&2
  LC_ALL=C comm -13 <(printf '%s\n' "$tree_names") <(printf '%s\n' "$list_names") | sed 's/^/    /' >&2
fi

echo "== C〜G. 各ファイルの Frontmatter / Changelog 構造 =="
for rel in "${INITIAL_SET[@]}"; do
  f="$TEMPLATE_DIR/$rel"
  [ -f "$f" ] || continue  # 欠落は検査 A で既に赤

  # C. 先頭行が --- で、2 行目以降に閉じの --- がある
  first_line="$(head -1 "$f")"
  if [ "$first_line" != "---" ]; then
    bad "$rel: 先頭行が Frontmatter 開始（---）ではありません"
    continue
  fi
  close_line="$(awk 'NR > 1 && /^---$/ { print NR; exit }' "$f")"
  if [ -z "$close_line" ]; then
    bad "$rel: Frontmatter が閉じていません（2 行目以降に --- がない）"
    continue
  fi

  # D〜G をファイル 1 パスの awk で判定する（パイプ入力の grep -q* は SIGPIPE 事故
  # 防止のため禁止 — run-all case 10）。flags はこの awk の printf が全出力を統制する
  flags="$(awk -v fm_end="$close_line" '
    NR >= 2 && NR < fm_end {
      if ($0 ~ /^title: "[^"]+"$/)    f["title"] = 1
      if ($0 ~ /^version: "[^"]+"$/)  f["version"] = 1
      if ($0 ~ /^version: "[0-9]+\.[0-9]+\.[0-9]+"$/) f["semver"] = 1
      if ($0 ~ /^status: "[^"]+"$/)   f["status"] = 1
      if ($0 ~ /^status: "(draft|review|approved|deprecated)"$/) f["statusdom"] = 1
      if ($0 ~ /^owner: "[^"]+"$/)    f["owner"] = 1
      if ($0 ~ /^created: "[^"]+"$/)  f["created"] = 1
      if ($0 ~ /^updated: "[^"]+"$/)  f["updated"] = 1
      if ($0 ~ /^changeImpact:/)      f["ci"] = 1
      if ($0 ~ /^changeImpact: "(low|medium|high)"$/) f["cidom"] = 1
    }
    /^## Changelog$/ { f["changelog"] = 1 }
    END {
      printf "title=%d version=%d semver=%d status=%d statusdom=%d owner=%d created=%d updated=%d ci=%d cidom=%d changelog=%d\n", \
        f["title"], f["version"], f["semver"], f["status"], f["statusdom"], \
        f["owner"], f["created"], f["updated"], f["ci"], f["cidom"], f["changelog"]
    }
  ' "$f")"
  has_flag() { case " $flags " in *" $1=1 "*) return 0 ;; *) return 1 ;; esac; }

  # D. 必須6フィールド（引用符付き key: "value" 形式）
  missing=""
  for key in title version status owner created updated; do
    has_flag "$key" || missing="$missing $key"
  done
  if [ -n "$missing" ]; then
    bad "$rel: 必須フィールドが欠落または引用符なし:${missing}"
    continue
  fi

  # E. version の SemVer 形式と status の値域
  if ! has_flag semver; then
    bad "$rel: version が SemVer 形式（\"x.y.z\"）ではありません"
    continue
  fi
  if ! has_flag statusdom; then
    bad "$rel: status が値域（draft/review/approved/deprecated）外です"
    continue
  fi

  # F. changeImpact は存在する場合のみ小文字の値域を要求（初版省略可）
  if has_flag ci && ! has_flag cidom; then
    bad "$rel: changeImpact が小文字の low/medium/high ではありません"
    continue
  fi

  # G. ## Changelog 見出し
  if ! has_flag changelog; then
    bad "$rel: ## Changelog セクションがありません"
    continue
  fi

  ok "$rel: Frontmatter / Changelog 構造 OK"
done

echo ""
echo "結果: pass=${PASS} fail=${FAIL}"
if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
if [ "$PASS" -eq 0 ]; then
  echo "✗ 検査が 1 件も成立していません" >&2
  exit 1
fi
echo "✅ docs-template-frontmatter: all checks passed"
