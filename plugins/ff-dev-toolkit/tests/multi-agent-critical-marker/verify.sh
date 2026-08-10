#!/usr/bin/env bash
#
# multi-agent-critical-marker: 統合レポートの CRITICAL_BLOCK 判定の構造検査（Issue #272）。
#
# 背景: 旧判定式 `^\s*-\s*\[.*:.*\]` は重大度に関係なく [file:line] 形式の箇条書き
# すべてに発火し、Important のみのレビューでも「Critical issues detected」を宣言して
# いた（PR #270 で実際に発生）。CRITICAL_BLOCK は pre-push ゲート（docs-gates-runtime
# 参照）が push をブロックする根拠なので、誤出力は「Critical が無いのに push が
# 止まる」実害になる。逆に Critical の実所見でマーカーが出ない退行は、ゲートの
# 素通りという逆向きの実害になる。両方向を stub CLI の実走で固定する。
#
# 実 CLI は起動しない。codex コマンドを stub で覆い、レビュー本文だけを差し替えて
# orchestrator → generate_review_report の実経路を通す（判定式を単体で切り出して
# 検査すると、呼び出し側の変化で検査が別物になる）。
#
# 書き込み不可の環境では skip して成功扱いにする。

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd -P)"
MULTI_AGENT="$PLUGIN_ROOT/scripts/multi-agent.sh"

[ -f "$MULTI_AGENT" ] || {
  echo "✗ 対象ファイルが見つかりません: $MULTI_AGENT" >&2
  exit 1
}

# 実行環境の MULTI_AGENT_* から分離する（Issue #374 / #378 の共通機構）。
# shellcheck source=../lib/adapter-env-isolation.sh
. "$SCRIPT_DIR/../lib/adapter-env-isolation.sh"
build_isolate_env "MULTI_AGENT_CONFIG MULTI_AGENT_CODEX_PROFILE" \
  "$MULTI_AGENT" "$PLUGIN_ROOT"/scripts/adapters/*.sh

if ! TMP="$(mktemp -d 2>/dev/null)"; then
  echo "○ skip: 一時ディレクトリを作成できない環境（read-only）のためスキップ"
  exit 0
fi
trap 'rm -rf "$TMP"' EXIT

PASS=0
FAIL=0
ok()  { echo "  ✓ $1"; PASS=$((PASS + 1)); }
bad() { echo "  ✗ $1" >&2; FAIL=$((FAIL + 1)); }

# --- レビュー対象の差分を持つ一時リポジトリ ---
REPO="$TMP/repo"
git init -q "$REPO"
cd "$REPO"
git config user.email "test@example.com"
git config user.name "multi-agent-critical-marker-test"
git config commit.gpgsign false
git switch -q -c develop
echo base > app.txt
git add app.txt
git commit -qm "init"
git switch -q -c feature/x
printf 'base\nchange for review\n' > app.txt
git add app.txt
git commit -qm "change"

# --- stub CLI（codex のみ。レビュー本文は $TMP/body.md をそのまま出す） ---
STUB="$TMP/bin"
mkdir -p "$STUB"
cat > "$STUB/codex" <<SH
#!/usr/bin/env bash
cat "$TMP/body.md"
SH
chmod +x "$STUB/codex"

REPORT="$REPO/.review-results/integrated-report.md"
MARKER='<!-- CRITICAL_BLOCK -->'

# run_case <ラベル> <expect: present|absent> <センチネル> <本文ヒアドキュメントを stdin から>
# センチネルは本文中の一意な行で、「本文がレポートに到達したこと」を先に確かめる。
# これが無いと、stub や adapter 経路の故障で本文が判定器に届かないまま absent ケースが
# 空振り合格する（マーカーが出ない理由が「Critical なし」ではなく「本文なし」でも ✓）。
run_case() {
  local label="$1" expect="$2" sentinel="$3" rc=0
  cat > "$TMP/body.md"
  if ! grep -qF "$sentinel" "$TMP/body.md"; then
    bad "${label}: fixture がセンチネル '${sentinel}' を含んでいない（self-test のバグ）"
    return
  fi
  rm -rf "$REPO/.review-results"
  set +e
  run_isolated PATH="$STUB:$PATH" bash "$MULTI_AGENT" \
    --task review --cli codex-cli --perspective code-review \
    --base develop --timeout 60 >"$TMP/run.log" 2>&1
  rc=$?
  set -e
  if [[ $rc -ne 0 ]]; then
    bad "${label}: orchestrator が非 0 終了した (rc=$rc)"
    tail -5 "$TMP/run.log" | sed 's/^/    | /' >&2
    return
  fi
  if [[ ! -f "$REPORT" ]]; then
    bad "${label}: 統合レポートが生成されていない"
    return
  fi
  if ! grep -qF "$sentinel" "$REPORT"; then
    bad "${label}: 本文がレポートに到達していない（判定は空振り）"
    return
  fi
  if grep -qF "$MARKER" "$REPORT"; then
    if [[ "$expect" == "present" ]]; then
      ok "${label}: マーカーが出る"
    else
      bad "${label}: Critical が無いのにマーカーが出た（push ゲートの誤ブロック）"
      grep -n -B2 -A1 -F "$MARKER" "$REPORT" | sed 's/^/    | /' >&2
    fi
  else
    if [[ "$expect" == "absent" ]]; then
      ok "${label}: マーカーが出ない"
    else
      bad "${label}: Critical の実所見があるのにマーカーが出ない（push ゲートの素通り）"
    fi
  fi
}

echo "== CRITICAL_BLOCK 判定の構造検査 =="

# 1. Important のみ（[file:line] 箇条書きあり・Critical 0 件）→ 出ない
run_case "Important のみの [file:line] 箇条書き" absent "sentinel-case-1" <<'BODY'
<!-- sentinel-case-1 -->
## Code Review Results

### Critical Issues (信頼度 91-100)

なし。

### Important Issues (信頼度 80-90)
- [app.txt:2] 変更行の説明が不足している
  - 信頼度: 85
- [app.txt:1] 既存行との一貫性
  - 信頼度: 82

### Summary
- 検出された問題数: 2
- Critical: 0
- Important: 2
BODY

# 2. Critical セクションに実所見 → 出る
run_case "Critical セクションの実所見" present "sentinel-case-2" <<'BODY'
<!-- sentinel-case-2 -->
## Code Review Results

### Critical Issues (信頼度 91-100)
- [app.txt:2] 認証チェックの欠落
  - 信頼度: 95

### Summary
- Critical: 1
BODY

# 3. 箇条書きは無いが Summary の集計が Critical >= 1 → 出る
run_case "Summary 集計のみの Critical" present "sentinel-case-3" <<'BODY'
<!-- sentinel-case-3 -->
## Review

重大な問題を本文で説明する（箇条書きは使わない）。

### Summary
- Critical: 2
- Important: 0
BODY

# 4. 完了レビューがフェンス内と散文で Critical 判定文字列を引用 → 出ない
#    （本ツールが自身のスクリプトや perspective 文書をレビューすると実際に起こる形）
run_case "フェンス引用と散文言及のみ" absent "sentinel-case-4" <<'BODY'
<!-- sentinel-case-4 -->
## Code Review Results

判定式のレビュー。この検査は `- Critical: 1` のような Summary 行と、
行頭の CRITICAL: マーカーを探す（散文の中の言及はこの行のように無害）。
テンプレートの引用:

```markdown
### Critical Issues (信頼度 91-100)
- [ファイル名:行番号] 問題の説明

### Summary
- Critical: 1
```

### Summary
- 検出された問題数: 0
- Critical: 0
BODY

# 5. 行頭の大文字マーカー → 出る
run_case "行頭 CRITICAL: マーカー" present "sentinel-case-5" <<'BODY'
<!-- sentinel-case-5 -->
## Review

CRITICAL: authentication bypass in app.txt

### Summary
- Critical: 1
BODY

# 6. error-handler-hunt テンプレートの全大文字形 → 出る（同梱 perspective の実契約。
#    大文字小文字の吸収が落ちると同 perspective の Critical が丸ごと素通りする）
run_case "全大文字テンプレート（CRITICAL Issues / - CRITICAL: N）" present "sentinel-case-6" <<'BODY'
<!-- sentinel-case-6 -->
## Error Handler Hunt Results

### CRITICAL Issues
- [app.txt:2] エラーが握りつぶされている
  - 信頼度: 95

### Summary
- CRITICAL: 2
BODY

# 7. 未閉フェンスの後ろに実 Critical → 出る（フェンス不整合は判定不能として安全側 =
#    マーカーありへ倒す。旧トグル実装は以降を全部読み飛ばして素通りしていた）
run_case "未閉フェンスの後ろの実 Critical" present "sentinel-case-7" <<'BODY'
<!-- sentinel-case-7 -->
## Review

途中経過の引用:

```text
（この引用は閉じられないまま本文が続いてしまった）

### Critical Issues
- [app.txt:2] 認証チェックの欠落

### Summary
- Critical: 1
BODY

# 8. Critical 見出し配下の「- なし」箇条書き → 出ない（空所見の箇条書き表記。
#    ケース 1 の散文「なし。」と対で、最も紛らわしい変種を固定する）
run_case "Critical 見出し配下の - なし 箇条書き" absent "sentinel-case-8" <<'BODY'
<!-- sentinel-case-8 -->
## Code Review Results

### Critical Issues (信頼度 91-100)
- なし

### Important Issues (信頼度 80-90)
- [app.txt:2] 軽微な指摘

### Summary
- Critical: 0
BODY

# 9. 見出しなし・語彙違いの集計行のみ（test-analysis 形）→ 出る
run_case "集計行の語彙違い（- Critical Gaps: N）" present "sentinel-case-9" <<'BODY'
<!-- sentinel-case-9 -->
## Test Analysis

本文で重大なギャップを説明する（Critical 見出しは使わない）。

### Summary
- Critical Gaps: 2
BODY

echo
if [ "$FAIL" -gt 0 ]; then
  echo "✗ multi-agent-critical-marker verify: $FAIL 件失敗" >&2
  exit 1
fi
echo "✓ multi-agent-critical-marker verify: 全 $PASS 件 pass"
