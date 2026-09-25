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
# ADR-066（Issue `#1875`）以降の位置づけ: **散文経路の撤去の回帰記録**。受理は型付き判定行
# （`- verdict: …`）だけになり、散文の重大度行は受理も Critical の有無も決めない。散文の
# 行分類そのものは診断（拒否時の `prose-only review refused` と、判定行の無い本文の
# `prose Critical finding in a body without typed verdict lines (not counted)`）にだけ残る。
# 入力表の 2 列の期待（受理 = accept|reject / 検出 = fire|none|unparse）は**散文の分類が
# その本文をどう読むか**の記録としてそのまま残し、row() が次の 2 点へ読み替えて照合する:
#   - 判定: 散文だけの本文は常に不受理（rc1）で、検出は常に「根拠なし」（rc4。未閉フェンス
#     の unparse 行だけ rc2）— 散文の読みがどうであれ、受理・Critical 判定へ届かない
#   - 診断: 受理列が accept の行でだけ `prose-only review refused` が 1 行、検出列が fire の
#     行でだけ `prose Critical finding in a body without typed verdict lines` が 1 行出る
#     （分類の網羅は診断の有無として保つ — 撤去で分類の検査を黙って失わない）
# 散文パーサの穴の bundle（Issue `#1765`）の子 1 / 子 2 の形は F 節で「判定に届かない」ことを
# 固定する（撤去で superseded）。
#
# 変異検出（ADR-066。1 件ずつ当てた 2026-09-25 実測）: 受理を散文でも受理する形へ戻す → 92 件赤。
#   検出の判定行なし（rc21）を散文の判定へ戻す → 103 件赤。rc21 の写像を rc1 へ変える → 103 件赤。
#   拒否の診断を外す → 92 件赤。散文 Critical の診断（not counted）を外す → 45 件赤。
#   レビュー 1 巡目の fix（同日実測）: 未完了の分岐の fail-safe 検査（critical_findings_present の rc0）を外す →
#   委譲の静的 pin（結果ファイルを検出へ渡すのは fail-safe の 1 箇所だけ）が赤。
#
# 本 suite が固定するもの:
#   (1) 積集合テーブル — 同じ入力表を**両側の公開入口**（review_body_present /
#       critical_findings_present）へ流し、上の読み替えで行ごとに照合する。
#       旧版の「受理される全形式の Critical 指摘行で検出が発火する」（Issue `#908`
#       AC）は、bullet 3 種・** 強調・先頭空白・件数あり / なし・見出しスコープの
#       全形式で「受理側の診断と検出側の診断が揃って出る」ことへ読み替えて網羅する。
#       片側だけが独自実装へ戻る変異は診断の食い違いで赤になり、散文経路を判定へ
#       戻す変異は判定の rc（常に不受理 / 根拠なし）で赤になる
#   (2) 検出だけが広い唯一の形（bullet 無しの行頭 CRITICAL: マーカー — 受理と
#       検出は別契約）と、両側が揃って除外する形（明示ゼロ・ゼロ語・空所見語彙・
#       参照語 veto 行）の境界
#   (3) 委譲の静的 pin — multi-agent.sh の判定が typed_verdicts_extract の
#       呼び出しで、結果ファイルを散文の検出へ渡さず、独自 awk（in_crit）の複製も持たないこと、adapter-common.sh
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
# 診断の文面（adapter-common.sh が出す 1 行）。期待は実装を読まずにここへ書く
PROSE_REFUSED_DIAG='typed-verdict: prose-only review refused (no valid verdict line)'
PROSE_CRIT_DIAG='typed-verdict: prose Critical finding in a body without typed verdict lines (not counted)'

row() {
  local label="$1" exp_a="$2" exp_c="$3" body rc_a rc_c got_a got_c want_rc_c
  local n_ref n_crit want_ref=0 want_crit=0
  body="$(cat)"
  printf '%s\n' "$body" > "$TMP/row-body.md"
  rc_a=0
  (
    # shellcheck source=../../scripts/adapters/adapter-common.sh
    source "$ADAPTER_COMMON"
    review_body_present "$body"
  ) 2>"$TMP/row-accept.err" || rc_a=$?
  rc_c=0
  (
    # shellcheck source=../../scripts/adapters/adapter-common.sh
    source "$ADAPTER_COMMON"
    critical_findings_present "$TMP/row-body.md"
  ) 2>"$TMP/row-crit.err" || rc_c=$?
  # 判定: 散文だけの本文は常に不受理・根拠なし（未閉フェンスの行だけ判定不能 rc2）
  want_rc_c=4
  [ "$exp_c" = "unparse" ] && want_rc_c=2
  # 診断: 散文の分類の読み（表の 2 列）から出るべき行数を導く
  [ "$exp_a" = "accept" ] && want_ref=1
  [ "$exp_c" = "fire" ] && want_crit=1
  n_ref="$(grep -cxF -- "$PROSE_REFUSED_DIAG" "$TMP/row-accept.err" || true)"
  n_crit="$(grep -cxF -- "$PROSE_CRIT_DIAG" "$TMP/row-crit.err" || true)"
  case "$rc_a" in 0) got_a="accept" ;; 1) got_a="reject" ;; *) got_a="error(rc=$rc_a)" ;; esac
  case "$rc_c" in
    0) got_c="fire" ;;
    1) got_c="none" ;;
    2) got_c="unparse" ;;
    4) got_c="no-typed" ;;
    *) got_c="error(rc=$rc_c)" ;;
  esac
  if [ "$rc_a" -ne 1 ] || [ "$rc_c" -ne "$want_rc_c" ]; then
    bad "${label}: 散文だけの本文が判定へ届いた（期待: 受理=reject 検出=rc${want_rc_c} / 実測: 受理=${got_a} 検出=${got_c}）"
  elif [ "$n_ref" != "$want_ref" ] || [ "$n_crit" != "$want_crit" ]; then
    bad "${label}: 散文の分類の読み（受理=${exp_a} 検出=${exp_c}）と診断が合わない（拒否の診断 ${n_ref} 行 / 期待 ${want_ref}、Critical の診断 ${n_crit} 行 / 期待 ${want_crit}）"
  else
    ok "${label}: 不受理・判定なし（散文の読み: 受理=${exp_a} / 検出=${exp_c}）"
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

# 件数**値**を markdown 強調で囲んだゼロ。ラベル側の強調は以前から
# 許していたが値側は許しておらず、`- Critical: **0**` が s1（件数行）に落ちずに
# s3（ラベル付き指摘行）へ流れて偽の CRITICAL_BLOCK を立てていた。レビュー本文は
# LLM 出力なのでゼロを太字で書くかは実行ごとに揺れ、同じ差分・同じ 0 件でも
# ゲートが通ったり落ちたりしていた（消費プロジェクトの実レポートで実測）。
row "強調ゼロ: - Critical: **0**" accept none <<'BODY'
- Critical: **0**
BODY

row "強調ゼロ: - Critical: *0*" accept none <<'BODY'
- Critical: *0*
BODY

row "強調ゼロ: - Critical: __0__" accept none <<'BODY'
- Critical: __0__
BODY

row "強調ゼロ語: - Critical: **なし**" accept none <<'BODY'
- Critical: **なし**
BODY

# 偽陰性を作らないこと — 強調付きの非ゼロは従来どおり発火する。
row "強調非ゼロ: - Critical: **1**" accept fire <<'BODY'
- Critical: **1**
BODY

row "強調非ゼロ: - Critical: *2*" accept fire <<'BODY'
- Critical: *2*
BODY

# ラベルとコロンを**まとめて**強調で囲んだ形（`- **Critical:** 0`）。`**` が `:` の
# 後ろへ来るため、ラベル側の `[*]*` でも値側の emph でも吸収できず、s1（件数行）
# ではなく s3（ラベル付き指摘行）へ落ちて偽の CRITICAL_BLOCK を立てていた
# （実レポートで実測 — 値側・ゼロ語側の強調を許した回とは別経路の同じ失敗形）。
# 修正は BEGIN ブロックの colon を強調跨ぎへ広げたもの。colon は s1 / s1_zero /
# s3b / s3s が共有するため、受理・検出の両モードと全ラベルへ同時に効く。
# colon を旧定義（強調を跨がない形）へ戻す変異では、直下 4 行の none 期待だけでなく
# bullet 無しの 2 行・critical 節の複数行 2 行・コロン前側の 2 行も落ちて計 9 行が
# 赤になる（実測）。「直下だけが針」と読んで他の行を削らないこと。
row "強調コロン跨ぎゼロ: - **Critical:** 0" accept none <<'BODY'
- **Critical:** 0
BODY

row "強調コロン跨ぎゼロ語: - **Critical:** なし" accept none <<'BODY'
- **Critical:** なし
BODY

row "強調コロン跨ぎゼロ: 全角コロン - **Critical：** 0" accept none <<'BODY'
- **Critical：** 0
BODY

row "強調コロン跨ぎゼロ: 単一 * の - *Critical:* 0" accept none <<'BODY'
- *Critical:* 0
BODY

# 偽陰性を作らないこと — 強調コロン跨ぎでも非ゼロ件数は従来どおり発火する。
row "強調コロン跨ぎ非ゼロ: - **Critical:** 1" accept fire <<'BODY'
- **Critical:** 1
BODY

# ラベル違いへ波及しないこと（colon は全ラベル共有 — critical 以外のゼロ / 非ゼロが
# Critical 検出へ漏れない）。
row "強調コロン跨ぎ: - **Warning:** 0 は Critical を発火しない" accept none <<'BODY'
- **Warning:** 0
BODY

row "強調コロン跨ぎ: - **Warning:** 2 は Critical を発火しない" accept none <<'BODY'
- **Warning:** 2
BODY

row "強調コロン跨ぎ: - **Suggestion:** 0 は Critical を発火しない" accept none <<'BODY'
- **Suggestion:** 0
BODY

# bullet 無しの件数行（s1 は bullet 任意）。colon を広げたことで `**Critical:** 0` が
# s1 として**受理**されるようになった（変更前は s1 / s3b / s3s のどれにも該当せず
# 不受理 = その観点の結果が欠測扱い）。件数行は値を行内に持つ自己完結行なので、
# 受理側が広がる向きは s1 の契約どおり。意図した挙動として固定する。
row "強調コロン跨ぎ: bullet 無しの **Critical:** 0 を受理する" accept none <<'BODY'
**Critical:** 0
BODY

row "強調コロン跨ぎ: bullet 無しの **Critical:** 1 は c1 で発火する" accept fire <<'BODY'
**Critical:** 1
BODY

# 既存の除外規則が強調コロン跨ぎでも効くこと — 参照語 veto は行単位で s3 に掛かる
# （`- **Critical:** 詳細は前のターンです` は s1 の値（数値 / ゼロ語）を持たないため
# s3 側へ落ち、veto されて不受理・不発火）。
row "強調コロン跨ぎ + 参照語 veto: - **Critical:** 詳細は前のターンです" reject none <<'BODY'
- **Critical:** 詳細は前のターンです
BODY

# 強調コロン跨ぎの**本物の指摘**は従来どおり受理・発火する（s3 の経路は残る）。
row "強調コロン跨ぎの実指摘: - **Critical:** 本物の指摘です" accept fire <<'BODY'
- **Critical:** 本物の指摘です
BODY

# ── 強調コロン跨ぎ × 既存経路の交点（セルフレビューで実測した 2 件の fail-open）──

# (1) bullet 無しの強調コロン跨ぎ指摘行。s3s_re がラベル直後に literal `**` を要求して
# いた間、この形は s1/s2/s3 のどれにも該当せず c2 が発火しなかった。同じ本文に
# `**Warning:** 0` のような件数行が 1 行でもあると受理だけが成立するため、**欠測
# （fail-loud）だったものが「本文あり・Critical なし」（無音の fail-open）へ化ける**。
# s3s_re の literal `**` を emph へ寄せる修正を戻すと、この 2 行が赤になる。
row "bullet 無し強調コロン跨ぎの実指摘: **Critical:** 散文" accept fire <<'BODY'
**Critical:** 認証チェックの欠落（scripts/foo.sh:10）
BODY

row "bullet 無し強調コロン跨ぎ: 件数行で受理されても Critical を見落とさない" accept fire <<'BODY'
## Summary
**Warning:** 0
**Critical:** src/db.ts:88 に SQL インジェクションがある
BODY

# (2) critical 見出しスコープ配下のゼロ宣言抑止（c3 の crit_zero）。colon が強調を
# 跨ぐようになったことで**他ラベルの件数行**（`- **Warning:** 0` / 集約形の
# `- **Suggestion:** 0 / **Critical:** 2`）が s1 ゼロへ落ちるようになり、ラベルを
# 見ない抑止トリガのままだと後続の実所見を黙らせた（実測 rc0 → rc1 の fail-open）。
# 抑止トリガへ `cls != 1 || cls_crit` を入れる修正を戻すと、この 2 行が赤になる。
row "critical 節の **Warning:** 0 は後続の実所見を黙らせない" accept fire <<'BODY'
### Critical
- **Warning:** 0
- [src/a.ts:1] 実際の Critical 指摘（信頼度: 高）
BODY

row "critical 節の集約件数行（Critical 非先頭）は後続の実所見を黙らせない" accept fire <<'BODY'
### Critical Issues
- **Suggestion:** 0 / **Critical:** 2
- [src/a.ts:1] 実際の Critical 指摘（信頼度: 高）
BODY

# (3) 抑止そのものは強調コロン跨ぎでも従来どおり効く（ゼロ宣言側を信じる既定）。
# 単行だけのテーブル行はこの c3 経路を踏まないため、複数行ボディで固定する。
# crit_zero のトリガから cls_zero を落とす変異はこの 3 行が赤になる（単行行では緑のまま）。
row "critical 節の - **Critical:** 0 の後ろの裏取り bullet は c3 で数えない" accept none <<'BODY'
### Critical Issues
- **Critical:** 0
- 参考: DOMAIN.md:322 の記述は正確
- 参考: 境界条件も確認済み
BODY

row "critical 節の - **Critical：** 0（全角）の後ろの裏取り bullet も同じ" accept none <<'BODY'
### Critical
- **Critical：** 0
- 参考: 確認済み
BODY

row "critical 節の素の - Critical: 0 の後ろの裏取り bullet（従来経路の対照）" accept none <<'BODY'
### Critical Issues
- Critical: 0
- 参考: 確認済み
BODY

# (4) コロンの**前**側の emph。ラベル側の `[*]*` は `_` を受けないため、前側 emph が
# 効くのは `- **Critical**_: 0` / `- Critical_: 0` のような `_` 混じりの形だけ。
# 前側 emph だけを削る変異はこの 2 行でしか赤にならない（後側だけを固定していると
# 「変更の半分が針を持たない」状態になる — セルフレビューで実測）。
row "コロン前側の強調: - **Critical**_: 0" accept none <<'BODY'
- **Critical**_: 0
BODY

# 前側 emph は検出側も広げる（分類そのものが変わるため）。向きは fail-safe
# （見落としを作らない側）で、非ゼロは発火する。
row "コロン前側の強調: - Critical_: 5 は発火する" accept fire <<'BODY'
- Critical_: 5
BODY

# (5) ラベル**そのもの**を `_` で囲む形は受理しない（既知の境界）。ラベル側の強調は
# `[*]*` のままで emph へ揃えていないため。受理されない = その観点は欠測として
# fail-loud になる向きで、本 PR では広げていない。
row "_ 強調ラベルは受理しない（既知の境界）: - _Critical:_ 0" reject none <<'BODY'
- _Critical:_ 0
BODY

# (6) 既知の限界（本 PR では変えていない）: s1 は行頭の 1 ラベルでスキャンが確定する
# ため、集約件数行で critical が**先頭でない**と c1 が届かない。強調の有無に関わらず
# 同じで、base でも同一挙動。契約（Critical 先頭）に沿う語順なら従来どおり発火する。
row "既知の限界: 集約件数行の Critical 非先頭は c1 が拾わない（強調あり）" accept none <<'BODY'
- **Warning:** 0 / **Critical:** 2
BODY

row "既知の限界: 集約件数行の Critical 非先頭は c1 が拾わない（素のコロン）" accept none <<'BODY'
- Warning: 0 / Critical: 2
BODY

row "対照: 集約件数行の Critical 先頭は従来どおり発火する" accept fire <<'BODY'
- Critical: 2 / Warning: 0
BODY

# 強調はゼロ**語**にも掛かる。値側だけに掛けた版では `- **指摘なし**` /
# `- **なし**` が偽 Critical として発火し続けた（実測）。ゼロ語は s2a_re /
# s4_empty_re / zero_decl_re が共有するため、片側だけ直すと同根の非対称が残る。
row "強調ゼロ語 bullet: critical 見出し配下の - **指摘なし**" accept none <<'BODY'
### Critical Issues
- **指摘なし**
BODY

row "強調ゼロ語 bullet: critical 見出し配下の - **なし**" accept none <<'BODY'
### Critical Issues
- **なし**
BODY

# 偽陰性を作らないこと — 強調された「本物の指摘」は従来どおり発火する。
row "強調された実指摘: critical 見出し配下の bullet" accept fire <<'BODY'
### Critical Issues
- **本物の指摘です**
BODY

# 行全体を強調した件数行。値の**後置**強調を許したことで s1 ゼロとして扱われる
# ようになった（変更前は `0**` の直後が境界文字でないため s3 へ落ちて発火した）。
# 意図した挙動として固定する — 後置側の emph を削る変異がここで赤になる。
row "行全体強調の件数行: - **Critical: 0**" accept none <<'BODY'
- **Critical: 0**
BODY

# 強調ゼロ語だけの本文も**受理**されること（s2a_re 側の強調許容）。これが無いと
# 「本文は - **指摘なし** の 1 行だけ」というレビュー応答が受理ゲートで弾かれ、
# その観点の結果が欠測として扱われる（実測: 受理 rc=0 → 1 へ反転）。
row "強調ゼロ語 単独行の受理: - **指摘なし**" accept none <<'BODY'
- **指摘なし**
BODY

row "強調ゼロ件報告行の受理: - **指摘 0 件**" accept none <<'BODY'
- **指摘 0 件**
BODY

# 件数**値**側だけを強調した形も対称に受理する（s2b_re の emph が前置のみだと
# 不受理になり、その観点の結果が欠測として扱われる）。
row "強調ゼロ件報告行の受理: - 指摘 **0** 件" accept none <<'BODY'
- 指摘 **0** 件
BODY

# 強調ゼロ宣言も c3 抑止のトリガになる（= 抑止の範囲が広がった向き）。
# 強調を許す前は `- **なし**` がゼロ宣言と認識されず、後続 bullet が実所見として
# 数えられて発火していた（実測: 旧実装 rc=0 → 新実装 rc=1）。既存 c3 の
# 「ゼロ宣言側を信じる」既定と一貫しているので意図した挙動として固定する。
# zero_decl_re の emph を削る変異はこの行で赤になる。
row "強調ゼロ宣言の後ろの実所見は c3 で数えない（抑止が広がった向き）" accept none <<'BODY'
### Critical
- **なし**
- [app.txt:2] 本物の指摘
BODY

# 上の抑止は c1 までは覆わない — 件数行を併記した矛盾レポートは従来どおり発火する。
row "強調ゼロ宣言 + 件数行 Critical: 1 は c1 で発火する" accept fire <<'BODY'
### Critical
- **なし**
- [app.txt:2] 本物の指摘

### Summary
- Critical: 1
BODY

# 実レポートの形（Critical 節はゼロ語、Summary の件数行だけ強調ゼロ）。
row "強調ゼロ: Critical 節はゼロ語 + Summary の件数行が **0**" accept none <<'BODY'
## Acceptance Criteria Review Results

### Critical Issues

なし。

### Summary

- AC 項目数: **7**
- Critical: **0**
BODY

# Critical 節のゼロ件宣言の後ろへ裏取り・補足の箇条書きを置く形（消費プロジェクトの
# 実レビューで CRITICAL_BLOCK の偽陽性として実測した入力をそのまま fixture 化）。
# 同じ critical スコープで一度ゼロを宣言したら、そのスコープの残りの bullet は c3 で
# 数えない（抑止は次の見出しで解除）。受理側は従来どおり受理（s4 の bullet と
# 集計行の両方がある）。
row "スコープ内の裏取りメモ: なし。+ 所見でない bullet 5 行" accept none <<'BODY'
## Code Review Results

### Critical Issues (信頼度 91-100)

なし。

主要な事実主張は in-repo で裏取りできた:
- `DOMAIN.md:322` の「新しい録音の開始を拒否する（checkUsageLimits）」は実在し、記述は正確。
- `tokenEstimator.ts:35-38` の「本番の呼び出し元は無い」は参照 2 件のみで、正確。
- `HEARING_MIN_PLAN` を明示設定している in-repo の配線は無い。
- `usageLimitResolver.ts:148,159-160` は実効値まで伝播する。
- `PLAN_LIMITS` 未知プランは `DEFAULT_PLAN_NAME` fallback へ落ちることを pin している。

### Summary
- Critical: 0
BODY

# bullet 形のゼロ宣言（`- なし`）でも同じスコープの後続 bullet を抑止する
# （散文形のゼロ宣言だけを塞ぐ変異を赤にする）。
row "スコープ内の裏取りメモ: - なし bullet + 後続 bullet" accept none <<'BODY'
### Critical Issues

- なし
- `tokenEstimator.ts:35-38` の「本番の呼び出し元は無い」は参照 2 件のみで、正確。

### Summary
- Critical: 0
BODY

# 上の偽陽性を消す変更で偽陰性を作らないこと（ここから 3 行）。ゼロ宣言の無い
# critical スコープ配下の bullet は、同梱観点テンプレートの各形式で従来どおり発火する。
row "スコープ内の本物の Critical: [path:line] + 信頼度行" accept fire <<'BODY'
## Code Review Results

### Critical Issues (信頼度 91-100)
- [app.txt:2] 認証チェックの欠落
  - 信頼度: 95

### Summary
- Critical: 1
BODY

# acceptance-criteria 観点の Critical テンプレート（`- [Issue 番号 / AC 項目] 未達の
# 説明` — path:line も信頼度行も持たない）。この観点はブロック名簿側なので、ここが
# 数えられなくなると本物の Critical が CRITICAL_BLOCK を立てない fail-open になる。
row "スコープ内の本物の Critical: acceptance-criteria 形（件数行なし）" accept fire <<'BODY'
### Critical（AC 未達）
- [AC-3 / GWT-1] ゼロ件宣言の後ろの bullet で CRITICAL_BLOCK が立つ
  - 根拠: 統合レポートのマーカーと個別結果が食い違う
BODY

# test-analysis 観点の `### Critical Gaps` 配下の散文 bullet（件数行なし）。
# 位置参照も信頼度行も持たない指摘形で、従来どおり発火し続けること。
row "スコープ内の本物の Critical: test-analysis 形（散文 bullet）" accept fire <<'BODY'
### Critical Gaps (優先度 9-10)
- 新規ガードの偽陰性を固定するケースが無い
- 未閉フェンスの分岐に相当するケースが無い
BODY

# 既知の限界（意図的に固定する）: ゼロ宣言の後ろに本物の所見形を続けて書いた矛盾
# レポートは、c3 ではゼロ宣言側を信じて数えない。件数行を併記していれば c1 が拾う。
row "既知の限界: ゼロ宣言の後の所見形 bullet（件数行なし）" accept none <<'BODY'
### Critical Issues (信頼度 91-100)

なし。

- [app.txt:2] 認証チェックの欠落
  - 信頼度: 95
BODY

row "既知の限界の逃げ道: 同じ矛盾レポートでも件数行があれば c1 が拾う" accept fire <<'BODY'
### Critical Issues (信頼度 91-100)

なし。

- [app.txt:2] 認証チェックの欠落
  - 信頼度: 95

### Summary
- Critical: 1
BODY

# 抑止は次の見出しで解除する: ゼロ宣言のあった Critical 節の後ろに別の critical
# 見出しが来たら、その配下の bullet は再び数える。
row "抑止の解除: ゼロ宣言の節の後に別の critical 見出し" accept fire <<'BODY'
### Critical Issues (信頼度 91-100)

なし。

- 裏取りのメモ（所見ではない）

### CRITICAL Issues (追記分)
- [app.txt:2] 認証チェックの欠落
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

echo "== F. 散文パーサの穴の bundle（Issue \`#1765\`）の形は判定に届かない（ADR-066 で superseded） =="

# 子 1（集約件数行で Critical が先頭でない → 散文の分類は Critical を見落とす）と
# 子 2（`- **Critical:**` の空本文 → 散文の分類は受理・発火と読む）。散文の読みは上の
# 表と同じく記録として残すが、どちらも不受理・判定なしで、判定を決めるのは型付き判定行
# だけ。同じ本文に型付き判定行を足すと、散文の読みと無関係に型付き行どおりに決まる。
row "子 1: - Warning: 0 / Critical: 2（散文は見落とす）" accept none <<'BODY'
- Warning: 0 / Critical: 2
BODY

row "子 1: - **Suggestion:** 0 / **Critical:** 2（強調あり）" accept none <<'BODY'
- **Suggestion:** 0 / **Critical:** 2
BODY

row "子 2: - **Critical:**（空本文。散文は受理・発火と読む）" accept fire <<'BODY'
- **Critical:**
BODY

# typed_row <ラベル> <期待の検出 rc> — 本文は stdin。受理は常に rc0（型付き行あり）
typed_row() {
  local label="$1" want_c="$2" body rc_a rc_c
  body="$(cat)"
  printf '%s\n' "$body" > "$TMP/typed-body.md"
  rc_a=0
  (
    # shellcheck source=../../scripts/adapters/adapter-common.sh
    source "$ADAPTER_COMMON"
    review_body_present "$body"
  ) 2>/dev/null || rc_a=$?
  rc_c=0
  (
    # shellcheck source=../../scripts/adapters/adapter-common.sh
    source "$ADAPTER_COMMON"
    critical_findings_present "$TMP/typed-body.md"
  ) 2>/dev/null || rc_c=$?
  if [ "$rc_a" -eq 0 ] && [ "$rc_c" -eq "$want_c" ]; then
    ok "${label}: 受理・検出 rc=${rc_c}（型付き判定行どおり）"
  else
    bad "${label}: 期待(受理 rc0 / 検出 rc${want_c}) 実測(受理 rc${rc_a} / 検出 rc${rc_c})"
  fi
}

typed_row "子 1 + 型付き Critical: 散文の見落としに関わらず Critical" 0 <<'BODY'
- Warning: 0 / Critical: 2
- [app.txt:2] 認証チェックの欠落
  - verdict: severity=critical failure_scenario=yes confidence=90 file=app.txt line=2
BODY

typed_row "子 2 + verdict: none: 散文の空ラベルは発火しない" 1 <<'BODY'
- **Critical:**
- verdict: none
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

# 未閉フェンスのドメイン rc=2 は上の unparse 行（E 節）が、判定行なしの rc=4 は全行が
# 固定している。awk 内部のドメイン専用値（exit 20 / 21）が公開 rc へ漏れないことは
# その行の rc 一致が兼ねる。

echo "== 委譲の静的 pin（テーブルが見ない「呼び出しの実在」） =="

# multi-agent.sh の CRITICAL 判定が共有パーサーの呼び出しであること。テーブルは
# adapter-common.sh の関数しか実行しないため、multi-agent.sh が独自 awk へ戻る
# 変異はここで赤にする（実走の検出力は tests/multi-agent-critical-marker）。
# ADR-066 以降の判定は型付き判定行の抽出（typed_verdicts_extract）で、結果ファイルを
# 散文の検出（critical_findings_present "$crit_file"）へ渡す経路は持たない。
if grep -q 'typed_verdicts_extract "\$crit_file"' "$MULTI_AGENT"; then
  ok "multi-agent.sh の CRITICAL 判定は typed_verdicts_extract の呼び出し"
else
  bad "multi-agent.sh に typed_verdicts_extract の呼び出しが無い（独自実装への復帰）"
fi
# 結果ファイルを検出（critical_findings_present）へ渡してよいのは、判定行の無い未完了の
# 観点で不採用行の fail-safe（rc0）だけを拾う 1 箇所だけ（ADR-066 レビュー 1 巡目）。検出は
# 判定行なしに rc4 を返すので散文の Critical は数えないが、rc0 以外を判定へ流す形
# （crit_rc へ代入する等）へ戻すと散文経路の復帰になる
cfp_all="$(grep -c 'critical_findings_present "\$crit_file"' "$MULTI_AGENT" || true)"
cfp_fs="$(grep -c 'critical_findings_present "\$crit_file" 2>/dev/null || tv_fs_rc=\$?' "$MULTI_AGENT" || true)"
if [ "$cfp_all" = "1" ] && [ "$cfp_fs" = "1" ] \
   && grep -q 'if \[\[ "\$tv_fs_rc" -eq 0 \]\]; then' "$MULTI_AGENT"; then
  ok "multi-agent.sh が結果ファイルを検出へ渡すのは未完了の観点の fail-safe 1 箇所だけ（散文経路は撤去済み）"
else
  bad "multi-agent.sh が結果ファイルを検出へ渡す箇所が fail-safe 以外にある（撤去した散文経路の復帰。全 ${cfp_all} 箇所 / fail-safe 形 ${cfp_fs} 箇所）"
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
