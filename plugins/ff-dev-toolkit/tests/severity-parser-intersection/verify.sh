#!/usr/bin/env bash
#
# severity-parser-intersection: 受理ゲートと集約 Critical 検出の積集合契約（Issue #908）。
#
# 背景: アダプタ側の本文受理文法（adapter-common.sh review_body_present）と
# multi-agent.sh 集約側の CRITICAL_BLOCK 検出文法が独立実装だった間、片側へ
# 語彙・境界を足すたびにズレて fail-open / 偽 BLOCK の両方向の非対称が再発した
# （Issue #893 の 7 巡レビューで実測）。Issue #908 で両者を共有パーサー
# （adapter-common.sh の _ff_severity_scan — 受理は accept モード、検出は
# critical モード）へ一本化した。
#
# 本 suite が固定するもの:
#   (1) 積集合テーブル — 同じ入力表を**両側の公開入口**（review_body_present /
#       critical_findings_present）へ流し、受理・検出の両期待を行ごとに固定する。
#       とくに「受理される全形式の Critical 指摘行で検出が発火する」（Issue #908
#       AC）を、bullet 3 種・** 強調・先頭空白・件数あり / なし・見出しスコープの
#       全形式で網羅する。片側だけが独自実装へ戻る変異（忠実な旧実装への復帰を
#       含む）は、旧実装と共有パーサーの挙動差がある行（* / + bullet の件数行、
#       ** 強調・散文のラベル付き指摘行、サブ見出しスコープ等）で赤になる
#   (2) 検出だけが広い唯一の形（bullet 無しの行頭 CRITICAL: マーカー — 受理と
#       検出は別契約）と、両側が揃って除外する形（明示ゼロ・ゼロ語・空所見語彙・
#       参照語 veto 行）の境界
#   (3) 委譲の静的 pin — multi-agent.sh の判定が critical_findings_present の
#       呼び出しであり独自 awk（in_crit）の複製を持たないこと、adapter-common.sh
#       の両入口が _ff_severity_scan の 2 モードへ委譲していること。テーブルは
#       共有パーサーの挙動しか見ないため、呼び出しを外して独自実装へ戻す変異は
#       テーブルだけでは検出できない — この pin が受け持つ（orchestrator 実走での
#       検出力は tests/multi-agent-critical-marker が受け持つ）
#
# 4 アダプタの behavioral テストの導入判断（Issue #908 DoD の記録）: **導入しない**。
# 受理文法は adapter-common.sh の共有層（review_body_present → _ff_severity_scan）に
# 100% 在り、4 アダプタのゲートブロックは「TASK_TYPE ガード + review_body_present
# 呼び出し + record_timeout_reason missing-review-body + fail_cli_task」の同一構造で
# アダプタ個別の文法差は無い（claude-code-adapter.sh:141 / codex-cli-adapter.sh:419 /
# copilot-cli-adapter.sh:133 / grok-cli-adapter.sh:362 を実コードで確認）。behavioral
# 実走は claude-code（tests/review-capture-fail-loud）と codex-cli
# （tests/multi-agent-critical-marker の orchestrator 実走 — 受理ゲートも通過する）で
# 済んでおり、残る copilot / grok へ stub 実走を足しても同一の共有コード経路を
# 3 倍のコストで再実行するだけになる。ゲート行の常在は review-capture-fail-loud の
# 4 アダプタ静的 pin（行順検査）が受け持つ。
#
# 実 CLI・ネットワーク・課金は伴わない。書き込み不可の環境では skip
# （critical_findings_present がファイル入力のため一時領域が要る）。

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd -P)"
ADAPTER_COMMON="$PLUGIN_ROOT/scripts/adapters/adapter-common.sh"
MULTI_AGENT="$PLUGIN_ROOT/scripts/multi-agent.sh"

[ -f "$ADAPTER_COMMON" ] || {
  echo "✗ 対象ファイルが見つかりません: $ADAPTER_COMMON" >&2
  exit 1
}
[ -f "$MULTI_AGENT" ] || {
  echo "✗ 対象ファイルが見つかりません: $MULTI_AGENT" >&2
  exit 1
}

# mktemp の失敗理由を捨てない（review-capture-fail-loud と同じ扱い）。
if _ff_mktemp_out="$(mktemp -d 2>&1)" && [ -d "$_ff_mktemp_out" ]; then
  TMP="$_ff_mktemp_out"
else
  echo "○ skip: 一時ディレクトリを作成できない環境のためスキップ"
  printf '  mktemp: %s\n' "$_ff_mktemp_out"
  exit 0
fi
# 途中死を沈黙させない（rc=0 なのにサマリー未到達 = 中断として扱う）。
FF_REACHED_END=0
_ff_exit_guard() {
  _ff_rc=$?
  rm -rf "$TMP"
  if [ "$_ff_rc" -eq 0 ] && [ "$FF_REACHED_END" -ne 1 ]; then
    echo "✗ severity-parser-intersection: 最後まで到達しませんでした（途中で中断）" >&2
    exit 1
  fi
  exit "$_ff_rc"
}
trap _ff_exit_guard EXIT

PASS=0
FAIL=0
ok()  { echo "  ✓ $1"; PASS=$((PASS + 1)); }
bad() { echo "  ✗ $1" >&2; FAIL=$((FAIL + 1)); }

# row <ラベル> <accept 期待: accept|reject> <critical 期待: fire|none|unparse>
# 本文は stdin。両側の**公開入口**を通す（_ff_severity_scan を直接呼ばない —
# 入口が独自実装へ戻る変異を挙動で検出するため）。
row() {
  local label="$1" exp_a="$2" exp_c="$3" body rc_a rc_c got_a got_c a_ok c_ok
  body="$(cat)"
  printf '%s\n' "$body" > "$TMP/row-body.md"
  rc_a=0
  (
    # shellcheck source=../../scripts/adapters/adapter-common.sh
    source "$ADAPTER_COMMON"
    review_body_present "$body"
  ) || rc_a=$?
  rc_c=0
  (
    # shellcheck source=../../scripts/adapters/adapter-common.sh
    source "$ADAPTER_COMMON"
    critical_findings_present "$TMP/row-body.md"
  ) || rc_c=$?
  case "$rc_a" in
    0) got_a="accept" ;;
    *) got_a="reject" ;;
  esac
  case "$rc_c" in
    0) got_c="fire" ;;
    1) got_c="none" ;;
    2) got_c="unparse" ;;
    *) got_c="error(rc=$rc_c)" ;;
  esac
  a_ok=0
  c_ok=0
  [ "$got_a" = "$exp_a" ] && a_ok=1
  [ "$got_c" = "$exp_c" ] && c_ok=1
  if [ "$a_ok" -eq 1 ] && [ "$c_ok" -eq 1 ]; then
    ok "${label}: 受理=${exp_a} / 検出=${exp_c}"
  else
    bad "${label}: 期待(受理=${exp_a} 検出=${exp_c}) 実測(受理=${got_a} 検出=${got_c})"
  fi
}

echo "== A. 受理される Critical 指摘行は全形式で検出が発火する（Issue #908 AC） =="

row "件数行: - bullet" accept fire <<'BODY'
- Critical: 1
BODY

row "件数行: * bullet" accept fire <<'BODY'
* Critical: 2
BODY

row "件数行: + bullet + 全大文字" accept fire <<'BODY'
+ CRITICAL: 3
BODY

row "件数行: 先頭空白付き" accept fire <<'BODY'
  - Critical: 1
BODY

row "件数行: bullet + ** 強調" accept fire <<'BODY'
- **Critical**: 4
BODY

row "件数行: Issues 修飾 + * bullet" accept fire <<'BODY'
* Critical Issues: 2
BODY

row "件数行: Gaps 修飾（test-analysis 形）" accept fire <<'BODY'
- Critical Gaps: 2
BODY

row "件数行: bullet 無し + / 区切り" accept fire <<'BODY'
Critical: 2 / Warning: 0 / Suggestion: 0
BODY

row "件数行: 日本語境界「件」" accept fire <<'BODY'
Critical: 3 件
BODY

row "件数行: Vulnerabilities 修飾" accept fire <<'BODY'
- Critical Vulnerabilities: 2
BODY

row "件数行: 全角コロン" accept fire <<'BODY'
- Critical： 1
BODY

row "指摘行: bullet + 散文（件数なし）" accept fire <<'BODY'
- Critical: 認証チェックの欠落（scripts/foo.sh:10）
BODY

row "指摘行: * bullet + 散文" accept fire <<'BODY'
* Critical: 認証チェックの欠落（scripts/foo.sh:10）
BODY

row "指摘行: + bullet + 散文" accept fire <<'BODY'
+ Critical: 認証チェックの欠落（scripts/foo.sh:10）
BODY

row "指摘行: 行頭 ** 強調 + 散文" accept fire <<'BODY'
**Critical**: 認証チェックの欠落（scripts/foo.sh:10）
BODY

row "指摘行: ** 強調 + 全角コロン" accept fire <<'BODY'
**Critical**： 認証チェックの欠落（scripts/foo.sh:10）
BODY

row "見出しスコープ: critical 見出し配下の bullet" accept fire <<'BODY'
### Critical Issues
- [app.txt:2] 認証チェックの欠落
BODY

row "見出しスコープ: サブ見出しを跨いで維持" accept fire <<'BODY'
### Critical
#### 詳細
- 停止条件が欠けている（scripts/foo.sh:10）
BODY

row "見出しスコープ: 全大文字テンプレート + 集計行" accept fire <<'BODY'
### CRITICAL Issues
- [app.txt:2] エラーが握りつぶされている

### Summary
- CRITICAL: 2
BODY

row "見出しスコープ: * bullet の指摘" accept fire <<'BODY'
### Critical
* 停止条件が欠けている（scripts/foo.sh:10）
BODY

row "見出しスコープ: + bullet の指摘" accept fire <<'BODY'
### Critical
+ 停止条件が欠けている（scripts/foo.sh:10）
BODY

# フェンス開始の CommonMark 較正（レビュー指摘）: 較正が落ちるとこの 2 行の
# フェンス様の行が引用マスクを開き、直後の実 Critical が素通り（fail-open）する。
row "info string に backtick を含む行はフェンスを開かない" accept fire <<'BODY'
```one`two
- Critical: 1
BODY

row "タブ字下げのフェンス様の行はフェンスを開かない" accept fire <<'BODY'
	```
- Critical: 1
BODY

echo "== B. 受理されるが Critical ではない（明示ゼロ・ゼロ語・他重大度） =="

row "明示ゼロ: 単独行" accept none <<'BODY'
Critical: 0
BODY

row "明示ゼロ: / 区切り（契約準拠ゼロ報告）" accept none <<'BODY'
Critical: 0 / Warning: 0 / Suggestion: 0
BODY

row "明示ゼロ: ゼロ語 none" accept none <<'BODY'
Critical: none
BODY

row "明示ゼロ: ゼロ語 zero" accept none <<'BODY'
Critical: zero
BODY

row "明示ゼロ: 日本語境界「件」" accept none <<'BODY'
Critical: 0 件
BODY

row "明示ゼロ: ゼロ語 n/a" accept none <<'BODY'
Critical: n/a
BODY

row "明示ゼロ: ゼロ語 ゼロ（全角）" accept none <<'BODY'
Critical: ゼロ
BODY

row "明示ゼロ: bullet 付き数値 0" accept none <<'BODY'
- CRITICAL: 0
BODY

row "明示ゼロ: bullet 付きゼロ語なし" accept none <<'BODY'
- Critical: なし
BODY

row "他重大度: Warning 件数行" accept none <<'BODY'
Warning: 3
BODY

row "他重大度: Suggestion 指摘行" accept none <<'BODY'
- Suggestion: ループを単純化できる（scripts/foo.sh:12）
BODY

row "空所見: critical 見出し配下の - 指摘なし" accept none <<'BODY'
### Critical
- 指摘なし
BODY

row "空所見: - なし + 集計ゼロ（error-handler-hunt 正常系）" accept none <<'BODY'
### CRITICAL Issues
- なし

### Summary
- CRITICAL: 0
BODY

# 行分類のゼロ判定はスコープ判定（c3）より優先する（レビュー指摘）: critical
# 見出し配下でも、自己完結の明示ゼロ行は実所見に数えない。
row "スコープ内ゼロ: critical 見出し配下の - Critical: 0" accept none <<'BODY'
### Critical
- Critical: 0
BODY

row "スコープ内ゼロ: critical 見出し配下の - Critical: none" accept none <<'BODY'
### Critical
- Critical: none
BODY

row "スコープ内ゼロ: critical 見出し配下の注記つき指摘なし" accept none <<'BODY'
### Critical
- 指摘なし（境界条件も確認済み）
BODY

row "他重大度スコープ: warning 見出し配下の実指摘" accept none <<'BODY'
### Warning
- stderr の破棄が早すぎる（scripts/foo.sh:12）
BODY

row "ゼロ件報告行: 指摘なし" accept none <<'BODY'
指摘なし（diff 全 hunk を読解した）
BODY

echo "== C. どちらも実体と数えない（不受理 + 検出なし） =="

row "参照語 veto: bullet 付きラベル行" reject none <<'BODY'
- Critical: 詳細は前のターンです
BODY

row "参照語 veto: * bullet のラベル行" reject none <<'BODY'
* Critical: 詳細は前のターンです
BODY

row "参照語 veto: critical 見出しスコープ内の参照 bullet" reject none <<'BODY'
### Critical
- 前述のとおり修正済み
BODY

# ATX 見出しの字下げは 0〜3 スペースのみ（レビュー指摘）: indented code（4 スペース）
# 内の見出し + bullet はスコープを開かず、どちらの側でも実体に数えない。
row "indented code 内の critical 見出し + bullet" reject none <<'BODY'
コード例:

    ### Critical
    - 例示の指摘
BODY

row "bullet 無しラベル + エラー文" reject none <<'BODY'
Warning: authentication expired
BODY

row "閉じたフェンス内の引用のみ" reject none <<'BODY'
テンプレートの引用:

```markdown
### Critical
- Critical: 1
```

以上は引用です。
BODY

row "散文のみ（メタ記述）" reject none <<'BODY'
本レスポンスは read-only レビュー sub-agent の報告であり、レビュー本文は上記のとおりです。
BODY

echo "== D. 検出だけが広い形（受理と検出は別契約 — bullet 無し行頭マーカー） =="

# bullet 無しの行頭 CRITICAL: マーカーは同形の CLI エラー文と区別できないため
# 受理しないが、集約側の検出（c4）は維持する。参照語 veto も c4 には掛けない
# （旧実装の検出範囲の保存 — 狭めると fail-open）。
row "行頭マーカー: 散文" reject fire <<'BODY'
CRITICAL: authentication bypass in app.txt
BODY

row "行頭マーカー: 0 始まりの実指摘（明示ゼロと誤認しない）" reject fire <<'BODY'
CRITICAL: 0-day exploit の兆候が依存追加に含まれている
BODY

row "行頭マーカー: コロン後空でも検出は維持" reject fire <<'BODY'
Critical:
BODY

echo "== E. 未閉フェンス（受理はマスク放棄フォールバック / 検出は判定不能） =="

row "未閉フェンス + フェンス内実体行" accept unparse <<'BODY'
途中経過の引用:

```text
（この引用は閉じられないまま本文が続いてしまった）

### Critical Issues
- [app.txt:2] 認証チェックの欠落

### Summary
- Critical: 1
BODY

row "未閉フェンス + 実体なし" reject unparse <<'BODY'
途中経過の引用:

```text
（実体行はどこにも無いまま本文が終わる）
BODY

echo "== rc 契約（不可読ファイル・ドメイン rc の分離） =="

# 開けない result file を rc=1（Critical なし）へ倒さない（fail-open 防止 —
# レビュー指摘）。旧実装は awk がファイルを開いて rc=2 = 安全側だったが、
# `< "$1"` 委譲は redirect 失敗が rc=1 に化けていた。rc=3（判定不能）で返り、
# multi-agent.sh の `*)` 診断分岐（安全側 = Critical あり）へ到達する。
MISSING_RC=0
(
  # shellcheck source=../../scripts/adapters/adapter-common.sh
  source "$ADAPTER_COMMON"
  critical_findings_present "$TMP/no-such-file.md"
) || MISSING_RC=$?
if [ "$MISSING_RC" -eq 3 ]; then
  ok "存在しない result file は rc=3（判定不能 — Critical なしに化けない）"
else
  bad "存在しない result file が rc=${MISSING_RC}（rc=1 は fail-open / rc=2 は未閉フェンスと誤診）"
fi

# 未閉フェンスのドメイン rc=2 は上の unparse 行（E 節）が固定している。awk 内部の
# ドメイン専用値（exit 20）が公開 rc へ漏れないことはその行の rc=2 一致が兼ねる。

echo "== 委譲の静的 pin（テーブルが見ない「呼び出しの実在」） =="

# multi-agent.sh の CRITICAL 判定が共有パーサーの呼び出しであること。テーブルは
# adapter-common.sh の関数しか実行しないため、multi-agent.sh が独自 awk へ戻る
# 変異はここで赤にする（実走の検出力は tests/multi-agent-critical-marker）。
if grep -q 'critical_findings_present "\$crit_file"' "$MULTI_AGENT"; then
  ok "multi-agent.sh の CRITICAL 判定は critical_findings_present の呼び出し"
else
  bad "multi-agent.sh に critical_findings_present の呼び出しが無い（独自実装への復帰）"
fi

if grep -q 'in_crit' "$MULTI_AGENT"; then
  bad "multi-agent.sh に判定 awk の複製（in_crit）が残っている（共有パーサーと並ぶ第二実装）"
else
  ok "multi-agent.sh は判定 awk の複製（in_crit）を持たない"
fi

if grep -q '_ff_severity_scan accept' "$ADAPTER_COMMON"; then
  ok "review_body_present は _ff_severity_scan accept へ委譲する"
else
  bad "review_body_present が共有パーサーへ委譲していない（受理側の独自実装への復帰）"
fi

if grep -q '_ff_severity_scan critical' "$ADAPTER_COMMON"; then
  ok "critical_findings_present は _ff_severity_scan critical へ委譲する"
else
  bad "critical_findings_present が共有パーサーへ委譲していない（検出側の独自実装への復帰）"
fi

echo
if [ "$FAIL" -gt 0 ]; then
  echo "✗ severity-parser-intersection verify: $FAIL 件失敗" >&2
  FF_REACHED_END=1
  exit 1
fi
echo "✓ severity-parser-intersection verify: 全 $PASS 件 pass"
FF_REACHED_END=1
