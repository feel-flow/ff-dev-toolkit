#!/usr/bin/env bash
#
# typed-verdict-parser: レビュー finding の型付き判定行（`- verdict: ...`）の文法と
# パーサの契約（受理条件の正本は adapter-common.sh の「受理条件（正）」ヘッダの (t)）。
#
# 背景: レビュー重大度は各 CLI の散文から _ff_severity_scan が抽出しており、語順・
# 強調・空本文の揺れのたびに正規表現を足してきた。型付き判定行はその系統を構造で
# 塞ぐための入口で、C1 で文法とパーサ、C2 でレビュープロンプトの要求、C4（ADR-066）で
# 強制を入れた。受理は型付き行だけで、散文だけの本文は不受理・Critical 判定は根拠なし
# （critical_findings_present の rc4）になる。散文の行分類は診断にだけ残る。
#
# 本 suite が固定するもの:
#   (A) 受理 — フェンス外の有効な (t) 行 1 件で受理。同じ行がフェンス内にしか無ければ
#       不受理。`verdict: none` だけの本文は受理・Critical 0 件
#   (B) Critical 検出 — (t) 行があれば型付き（severity=critical の件数だけで決め、
#       failure_scenario=no の降格はまだ掛けない）。散文の Critical を覆した回は診断。
#       (t) 行が無い本文は根拠なし（検出 rc4 = 表の no-typed）
#   (C) 検証 — 必須キー（severity / failure_scenario / confidence）の欠落・値域外・
#       未知キー・重複・余計な語・強調や大文字の `verdict` は型付きとして採らず、
#       理由コードを名指しした診断を出す。不採用行しか無い本文は不受理・根拠なし
#   (C) の続き — 不採用行が severity=critical を含むときは Critical 検出だけ fail-safe で
#       Critical ありへ倒す（受理・抽出は変えない）
#   (F) 候補の拡張 — コロン欠落・バッククォート・番号付き・引用・無印の verdict 行も
#       候補にし、厳密文法に合わなければ malformed-head で名指しする
#   (G) `=` も `none` も含まない散文の Verdict 行は候補にも診断にもしない
#   (D) 抽出 — typed_verdicts_extract のレコード書式と rc（不可読を rc1 へ倒さない）
#       と、散文の Critical を (t) 行が覆した回の診断（検出モードと同じ条件で抽出でも出す）
#   (P) 散文だけの本文の拒否（ADR-066）— 有効な (t) 行が無く散文の実体行だけがある本文
#       （未閉フェンスのマスク放棄の条件を含む）は不受理（rc1）で、受理モードが名指しの
#       診断 `prose-only review refused` を 1 行出す。前置きだけの本文・型付き受理・
#       Critical 検出・抽出では出さない。(t) 行の無い本文の散文 Critical は検出・抽出の
#       両モードが `prose Critical finding in a body without typed verdict lines (not counted)`
#       で名指しする（判定には数えない）。表の各ケース（vcase）はこの 2 つの診断行を
#       照合から外し（散文の分類の網羅は tests/severity-parser-intersection が持つ）、
#       (P) が文面と出る条件を個別に固定する
#   (E) 3 モードが共有パーサー _ff_severity_scan へ委譲していることの静的 pin と、
#       (t) の文法部品が interval 表記（BSD awk 非互換）を使わないことの pin
# 散文だけの本文が判定へ届かないこと（入力表を散文の分類の読みとして残したまま、全行
# 不受理・根拠なしで診断だけが分類どおりに出ること）は tests/severity-parser-intersection
# が固定する。本 suite は散文表を複製しない。
#
# 変異検出: (t) 行の検出からフェンスの除外（`!fence &&`）を外すと A2 / A3 / A7 / A9 / C23 / D1 が赤（閉じたフェンス内・未閉フェンス内の verdict 行が型付きとして数えられる。2026-09-25 実測）。
# 変異検出: confidence 欠落の判定を外す（欠落を受ける）と C3 / C21 / C24 が赤（2026-09-25 実測）。
# 変異検出: `verdict: none` を不採用へ倒すと A4 / A5 / A7 / B4 / B5 / C24 / D1 が赤（2026-09-25 実測）。
# 変異検出: critical モードの型付き優先を外す（散文の判定だけで決める）と B1 / B2 / B3 / B4 / B5 が赤（2026-09-25 実測）。
# 変異検出: 不採用行の critical fail-safe（`if (vd_rej_crit) exit 0`）を外すと C2 / C3 / C5 / C21 / C24 / C26 / F1 / F2 / F4 / F5 が赤（2026-09-25 実測）。
# 変異検出: 候補 vd_cand_re を拡張前（bullet + verdict + 区切り必須）へ戻すと F1〜F7 が赤（コロン欠落・バッククォート・番号付き・引用・無印の行が診断なしに散文へ落ちる。2026-09-25 実測）。
# 変異検出: 候補の「`=` か `none` 語を含む」条件を外すと G1 / G2 が赤（散文の Verdict 行へ診断が出る。2026-09-25 実測）。
# 変異検出（C4 / ADR-066。1 件ずつ当てて本 suite を走らせた 2026-09-25 実測）:
#   受理モードを散文でも受理する形へ戻す（`exit prose_ok ? 0 : 1`）→ C21 / C22 / G1 / P1 / P2 / P6 / P7 など 8 件赤。
#   検出モードの判定行なし（rc21）を散文の判定（`exit found ? 0 : 1`）へ戻す → A2 / A3 / C1〜C19 / F3 / F6 / F7 / G1 / G2 など 27 件赤。
#   critical_findings_present の rc21 → rc4 の写像を rc1（Critical なし）へ変える → 同じ 27 件赤。
#   拒否の診断（prose-only review refused）を外す → P1 / P2 / P6 / P7 / P8 が赤。散文 Critical の診断（not counted）を外す → D3 / P8 が赤。
# 変異検出: 抽出モードの「散文の Critical を覆した」診断（END の共有 1 箇所）を外すと B3 / B4 / D4 が赤（2026-09-25 実測）。
# 空振り検出: adapter-common.sh が不在の checkout では冒頭で ✗ を出して rc=1 になる（0 件 pass の緑にしない。2026-09-25 実測）。
# 空振り検出: typed_verdicts_extract の本体を `return 1`（常に 0 件）へ差し替えると (A) / (B) の抽出期待・C20・C24・C25・D1・(E) の委譲 pin が赤になる（名前だけ残って中身が変わる入力。2026-09-25 実測）。
# 空振り検出: 不採用行の診断の接頭辞を別名へ変える（書式変更）と C1〜C19 / C21 / C22 / C24〜C26 / F1〜F7 / D1 が赤になる（針は接頭辞つきの診断行の中だけで探す。2026-09-25 実測）。
# 空振り検出: ケース表を空にした（検査 0 件で末尾へ到達した）回は末尾の件数検査が rc=1 にする（2026-09-25 実測）。
#
# 実 CLI・ネットワーク・課金は伴わない。一時領域を作れない環境は skip せず赤にする
# （critical_findings_present / typed_verdicts_extract がファイル入力のため）。

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd -P)"
ADAPTER_COMMON="$PLUGIN_ROOT/scripts/adapters/adapter-common.sh"

[ -f "$ADAPTER_COMMON" ] || {
  echo "✗ 対象ファイルが見つかりません: $ADAPTER_COMMON" >&2
  exit 1
}

if _ff_mktemp_out="$(mktemp -d 2>&1)" && [ -d "$_ff_mktemp_out" ]; then
  TMP="$_ff_mktemp_out"
else
  echo "✗ 一時ディレクトリを作成できません（skip せず赤にする）: $_ff_mktemp_out" >&2
  exit 1
fi
FF_REACHED_END=0
_ff_exit_guard() {
  _ff_rc=$?
  rm -rf "$TMP"
  if [ "$_ff_rc" -eq 0 ] && [ "$FF_REACHED_END" -ne 1 ]; then
    echo "✗ typed-verdict-parser: 最後まで到達しませんでした（途中で中断）" >&2
    exit 1
  fi
  exit "$_ff_rc"
}
trap _ff_exit_guard EXIT

PASS=0
FAIL=0
ok()  { echo "  ✓ $1"; PASS=$((PASS + 1)); }
bad() { echo "  ✗ $1" >&2; FAIL=$((FAIL + 1)); }

# 散文だけの本文を拒否した診断と、(t) 行の無い本文の散文 Critical の診断（adapter-common.sh
# の END が出す 1 行ずつ）。期待は実装を読まずにここへ書く — 文面が変わったら本 suite が赤になる
PROSE_REFUSED_DIAG='typed-verdict: prose-only review refused (no valid verdict line)'
PROSE_CRIT_DIAG='typed-verdict: prose Critical finding in a body without typed verdict lines (not counted)'

# vcase <ラベル> <受理: accept|reject> <検出: fire|none|unparse|no-typed> <抽出: typed|untyped|unparse> <診断の針 | ->
# 本文は stdin。3 つの**公開入口**（review_body_present / critical_findings_present /
# typed_verdicts_extract）へ流し、stderr を 1 本に集めて診断を照合する。
# 診断の針が `-` のときは `typed-verdict:` 行が 1 行も出ないことを要求する。
vcase() {
  local label="$1" exp_a="$2" exp_c="$3" exp_e="$4" needle="$5"
  local body rc_a rc_c rc_e got_a got_c got_e err diag
  body="$(cat)"
  printf '%s\n' "$body" > "$TMP/body.md"
  : > "$TMP/err"
  rc_a=0
  (
    # shellcheck source=../../scripts/adapters/adapter-common.sh
    source "$ADAPTER_COMMON"
    review_body_present "$body"
  ) 2>>"$TMP/err" || rc_a=$?
  rc_c=0
  (
    # shellcheck source=../../scripts/adapters/adapter-common.sh
    source "$ADAPTER_COMMON"
    critical_findings_present "$TMP/body.md"
  ) 2>>"$TMP/err" || rc_c=$?
  rc_e=0
  (
    # shellcheck source=../../scripts/adapters/adapter-common.sh
    source "$ADAPTER_COMMON"
    typed_verdicts_extract "$TMP/body.md"
  ) >"$TMP/out" 2>>"$TMP/err" || rc_e=$?
  case "$rc_a" in 0) got_a=accept ;; *) got_a=reject ;; esac
  case "$rc_c" in 0) got_c=fire ;; 1) got_c=none ;; 2) got_c=unparse ;; 4) got_c=no-typed ;; *) got_c="error(rc=$rc_c)" ;; esac
  case "$rc_e" in 0) got_e=typed ;; 1) got_e=untyped ;; 2) got_e=unparse ;; *) got_e="error(rc=$rc_e)" ;; esac
  err="$(cat "$TMP/err")"
  if [ "$got_a" != "$exp_a" ] || [ "$got_c" != "$exp_c" ] || [ "$got_e" != "$exp_e" ]; then
    bad "${label}: 期待(受理=${exp_a} 検出=${exp_c} 抽出=${exp_e}) 実測(受理=${got_a} 検出=${got_c} 抽出=${got_e})"
    return 0
  fi
  # 散文の分類の診断 2 種（ADR-066）は照合から外す — 出る条件は散文の分類そのもので、
  # 表の列からは導けない（散文の分類の網羅は tests/severity-parser-intersection、文面と
  # 出る条件は下の (P) が固定する）。ただし受理した本文（型付き受理）では出てはいけない。
  if [ "$exp_a" = accept ] && grep -qxF -e "$PROSE_REFUSED_DIAG" -e "$PROSE_CRIT_DIAG" <<<"$err"; then
    bad "${label}: 型付き受理の本文で散文の分類の診断が出た（実測: ${err}）"
    return 0
  fi
  err="$(grep -vxF -e "$PROSE_REFUSED_DIAG" -e "$PROSE_CRIT_DIAG" <<<"$err" || true)"
  if [ "$needle" = "-" ]; then
    if grep -q 'typed-verdict:' <<<"$err"; then
      bad "${label}: 診断が出てはいけないのに出た: $err"
      return 0
    fi
  else
    # 針は `typed-verdict:` 接頭辞の診断行の中だけで探す（接頭辞＝診断の書式が
    # 変わった回を、理由コードの部分一致で緑にしない）
    diag="$(grep -F 'typed-verdict:' <<<"$err" || true)"
    if ! grep -qF -- "$needle" <<<"$diag"; then
      bad "${label}: 診断の針「${needle}」が typed-verdict 診断行に無い（実測: ${err:-空}）"
      return 0
    fi
  fi
  ok "${label}: 受理=${exp_a} / 検出=${exp_c} / 抽出=${exp_e}"
}

echo "== A. 受理: フェンス外の (t) 行 1 件で受理・フェンス内だけなら不受理 =="

vcase "A1 フェンス外の型付き warning 行" accept none typed - <<'BODY'
## レビュー結果
- verdict: severity=warning failure_scenario=yes confidence=85 file=plugins/x.sh line=42
BODY

vcase "A2 同じ行がバッククォートフェンス内にしか無い" reject no-typed untyped - <<'BODY'
```text
- verdict: severity=warning failure_scenario=yes confidence=85 file=plugins/x.sh line=42
```
BODY

vcase "A3 同じ行がチルダフェンス内にしか無い（critical）" reject no-typed untyped - <<'BODY'
~~~
- verdict: severity=critical failure_scenario=yes confidence=95
~~~
BODY

vcase "A4 verdict: none だけの本文" accept none typed - <<'BODY'
- verdict: none
BODY

vcase "A5 Critical 見出し配下の verdict: none は c3 の実所見に数えない" accept none typed - <<'BODY'
### Critical
- verdict: none
BODY

vcase "A6 bullet 3 種（* / +）と先頭空白を等価に扱う" accept none typed - <<'BODY'
* verdict: severity=suggestion failure_scenario=no confidence=60
  + verdict: severity=info failure_scenario=no confidence=40
BODY

vcase "A7 フェンス内のテンプレート引用 + フェンス外の verdict: none" accept none typed - <<'BODY'
```
- verdict: severity=critical failure_scenario=yes confidence=100
```
- verdict: none
BODY

vcase "A8 (t) 行の後ろに未閉フェンス（受理は成立・検出と抽出は判定不能）" accept unparse unparse - <<'BODY'
- verdict: severity=warning failure_scenario=yes confidence=90
```
閉じないフェンス
BODY

vcase "A9 (t) 行が未閉フェンスの内側にしか無い" reject unparse unparse - <<'BODY'
```
- verdict: severity=warning failure_scenario=yes confidence=90
BODY

echo "== B. Critical 検出: 型付き優先・降格はまだ掛けない =="

vcase "B1 型付き critical" accept fire typed - <<'BODY'
- verdict: severity=critical failure_scenario=yes confidence=90 file=a.sh line=3
BODY

vcase "B2 型付き critical + failure_scenario=no（降格しない）" accept fire typed - <<'BODY'
- verdict: severity=critical failure_scenario=no confidence=90
BODY

vcase "B3 散文の Critical 件数行を型付き warning が覆す（診断つき）" accept none typed "prose Critical finding overridden" <<'BODY'
- Critical: 2 / Warning: 0
- verdict: severity=warning failure_scenario=yes confidence=90
BODY

vcase "B4 散文の Critical 指摘行を verdict: none が覆す（診断つき）" accept none typed "prose Critical finding overridden" <<'BODY'
- Critical: 認証チェックの欠落（scripts/foo.sh:10）
- verdict: none
BODY

vcase "B5 verdict: none と型付き critical の併記（指摘側を数える・診断つき）" accept fire typed "both present" <<'BODY'
- verdict: none
- verdict: severity=critical failure_scenario=yes confidence=100
BODY

vcase "B6 型付き info / suggestion だけ" accept none typed - <<'BODY'
- verdict: severity=info failure_scenario=no confidence=10
- verdict: severity=suggestion failure_scenario=yes confidence=80
BODY

echo "== C. 検証: 欠落・値域外は型付きとして採らず名指しの診断 =="

vcase "C1 severity 欠落" reject no-typed untyped "rejected (missing-severity)" <<'BODY'
- verdict: failure_scenario=yes confidence=90
BODY

vcase "C2 failure_scenario 欠落（severity=critical の不採用行は fail-safe で検出）" reject fire untyped "rejected (missing-failure_scenario)" <<'BODY'
- verdict: severity=critical confidence=90
BODY

vcase "C3 confidence 欠落（severity=critical の不採用行は fail-safe で検出）" reject fire untyped "rejected (missing-confidence)" <<'BODY'
- verdict: severity=critical failure_scenario=yes
BODY

vcase "C4 severity が列挙外（high）" reject no-typed untyped "rejected (bad-severity)" <<'BODY'
- verdict: severity=high failure_scenario=yes confidence=90
BODY

vcase "C5 severity の大文字（Critical。値は不採用・検出は fail-safe）" reject fire untyped "rejected (bad-severity) — counted as critical (fail-safe)" <<'BODY'
- verdict: severity=Critical failure_scenario=yes confidence=90
BODY

vcase "C6 failure_scenario が yes/no 以外" reject no-typed untyped "rejected (bad-failure_scenario)" <<'BODY'
- verdict: severity=warning failure_scenario=maybe confidence=90
BODY

vcase "C7 confidence が 100 超" reject no-typed untyped "rejected (bad-confidence)" <<'BODY'
- verdict: severity=warning failure_scenario=yes confidence=101
BODY

vcase "C8 confidence が負数" reject no-typed untyped "rejected (bad-confidence)" <<'BODY'
- verdict: severity=warning failure_scenario=yes confidence=-1
BODY

vcase "C9 confidence が小数（0.0〜1.0 形）" reject no-typed untyped "rejected (bad-confidence)" <<'BODY'
- verdict: severity=warning failure_scenario=yes confidence=0.85
BODY

vcase "C10 confidence が 4 桁（0100）" reject no-typed untyped "rejected (bad-confidence)" <<'BODY'
- verdict: severity=warning failure_scenario=yes confidence=0100
BODY

vcase "C11 未知キー" reject no-typed untyped "rejected (unknown-key)" <<'BODY'
- verdict: severity=warning failure_scenario=yes confidence=90 reason=x
BODY

vcase "C12 重複キー" reject no-typed untyped "rejected (duplicate-severity)" <<'BODY'
- verdict: severity=warning failure_scenario=yes confidence=90 severity=info
BODY

vcase "C13 key=value でない語（行末の散文）" reject no-typed untyped "rejected (stray-token)" <<'BODY'
- verdict: severity=warning failure_scenario=yes confidence=90 認証が抜けている
BODY

vcase "C14 verdict を強調で囲む" reject no-typed untyped "rejected (malformed-head)" <<'BODY'
- **verdict:** severity=warning failure_scenario=yes confidence=90
BODY

vcase "C15 Verdict の大文字" reject no-typed untyped "rejected (malformed-head)" <<'BODY'
- Verdict: severity=warning failure_scenario=yes confidence=90
BODY

vcase "C16 全角コロン" reject no-typed untyped "rejected (malformed-head)" <<'BODY'
- verdict： severity=warning failure_scenario=yes confidence=90
BODY

vcase "C17 verdict: none の後ろに語" reject no-typed untyped "rejected (none-with-extra)" <<'BODY'
- verdict: none 指摘はありません
BODY

vcase "C18 line が 1 未満" reject no-typed untyped "rejected (bad-line)" <<'BODY'
- verdict: severity=warning failure_scenario=yes confidence=90 line=0
BODY

vcase "C19 file が空" reject no-typed untyped "rejected (bad-file)" <<'BODY'
- verdict: severity=warning failure_scenario=yes confidence=90 file=
BODY

vcase "C20 confidence の境界 0 と 100 は有効" accept none typed - <<'BODY'
- verdict: severity=info failure_scenario=no confidence=0
- verdict: severity=warning failure_scenario=yes confidence=100
BODY

vcase "C21 不採用の critical 行 + 散文のゼロ件行（散文では受理しない・検出は fail-safe）" reject fire untyped "rejected (missing-confidence) — counted as critical (fail-safe)" <<'BODY'
- verdict: severity=critical failure_scenario=yes
- Critical: 0 / Warning: 0 / Suggestion: 0
BODY

vcase "C22 不採用の (t) 行は散文の行分類へ流れても判定に数えない（c3 の読みは診断だけ）" reject no-typed untyped "rejected (bad-severity)" <<'BODY'
### Critical
- verdict: severity=blocker failure_scenario=yes confidence=90
BODY

vcase "C23 フェンス内の不正な verdict 行は診断しない（引用）" reject no-typed untyped - <<'BODY'
```
- verdict: severity=high
```
BODY

vcase "C24 有効な verdict: none があっても不採用の critical 行は fail-safe で検出" accept fire typed "counted as critical (fail-safe)" <<'BODY'
- verdict: none
- verdict: severity=critical failure_scenario=yes
BODY

vcase "C25 不採用の warning 行は散文判定のまま（fail-safe 注記なし）" accept none typed "rejected (bad-failure_scenario): " <<'BODY'
- verdict: severity=warning failure_scenario=yes confidence=90
- verdict: severity=warning failure_scenario=maybe confidence=90
BODY

vcase "C26 severity=CRITICAL（大文字）の不採用行も fail-safe で検出" reject fire untyped "rejected (bad-severity) — counted as critical (fail-safe)" <<'BODY'
- verdict: severity=CRITICAL failure_scenario=yes confidence=90
BODY

echo "== F. 候補の拡張: 書式の崩れた verdict 行を診断なしに散文へ落とさない =="

vcase "F1 コロン欠落（critical は fail-safe）" reject fire untyped "rejected (malformed-head)" <<'BODY'
- verdict severity=critical failure_scenario=yes confidence=95
BODY

vcase "F2 行全体をバッククォートで囲む（critical は fail-safe）" reject fire untyped "rejected (malformed-head)" <<'BODY'
- `verdict: severity=critical failure_scenario=yes confidence=95`
BODY

vcase "F3 番号付きリスト（warning は散文判定のまま）" reject no-typed untyped "rejected (malformed-head): " <<'BODY'
1. verdict: severity=warning failure_scenario=yes confidence=90
BODY

vcase "F4 番号付きリスト 1) 形（critical は fail-safe）" reject fire untyped "rejected (malformed-head) — counted as critical (fail-safe)" <<'BODY'
2) verdict: severity=critical failure_scenario=yes confidence=90
BODY

vcase "F5 引用の中の bullet（critical は fail-safe）" reject fire untyped "rejected (malformed-head)" <<'BODY'
> - verdict: severity=critical failure_scenario=yes confidence=95
BODY

vcase "F6 bullet 無しの verdict 行" reject no-typed untyped "rejected (malformed-head)" <<'BODY'
verdict: severity=warning failure_scenario=yes confidence=90
BODY

vcase "F7 引用の中の verdict: none" reject no-typed untyped "rejected (malformed-head)" <<'BODY'
> - verdict: none
BODY

echo "== G. 散文の Verdict 行は候補にも診断にもしない（= も none も含まない行） =="

vcase "G1 - **Verdict:** Approve + 契約準拠ゼロ件行（散文だけなので不受理）" reject no-typed untyped - <<'BODY'
## Summary
- **Verdict:** Approve
- Critical: 0 / Warning: 0 / Suggestion: 0
BODY

vcase "G2 bullet 無しの **Verdict**: LGTM だけ" reject no-typed untyped - <<'BODY'
**Verdict**: LGTM
BODY

echo "== D. 抽出: レコード書式と rc =="

cat > "$TMP/d1.md" <<'BODY'
## 結果
- verdict: severity=critical failure_scenario=no confidence=085 file=plugins/x.sh line=42
- verdict: severity=high failure_scenario=yes confidence=90
```
- verdict: severity=warning failure_scenario=yes confidence=99
```
- verdict: none
BODY
# 期待は実装の出力を写さず、書式の定義（adapter-common.sh の typed_verdicts_extract
# ヘッダ）から手で組む: 行番号・severity・failure_scenario・10 進正規化した
# confidence・file・line のタブ区切り。不採用行（3 行目）とフェンス内（5 行目）は出ない。
printf 'finding\t2\tcritical\tno\t85\tplugins/x.sh\t42\nnone\t7\n' > "$TMP/d1.expected"
rc_d1=0
(
  # shellcheck source=../../scripts/adapters/adapter-common.sh
  source "$ADAPTER_COMMON"
  typed_verdicts_extract "$TMP/d1.md"
) >"$TMP/d1.out" 2>"$TMP/d1.err" || rc_d1=$?
if [ "$rc_d1" -eq 0 ] && cmp -s "$TMP/d1.expected" "$TMP/d1.out"; then
  ok "D1 抽出レコードが書式どおり（不採用行・フェンス内は出ない）"
else
  bad "D1 抽出レコードが書式と違う（rc=${rc_d1}）: $(cat "$TMP/d1.out")"
fi
if grep -qF 'typed-verdict: line 3: rejected (bad-severity)' "$TMP/d1.err"; then
  ok "D1 不採用行を行番号つきで名指しする"
else
  bad "D1 不採用行の診断が行番号つきで出ない: $(cat "$TMP/d1.err")"
fi

rc_d2=0
(
  # shellcheck source=../../scripts/adapters/adapter-common.sh
  source "$ADAPTER_COMMON"
  typed_verdicts_extract "$TMP/no-such-file.md"
) >"$TMP/d2.out" 2>/dev/null || rc_d2=$?
if [ "$rc_d2" -eq 3 ] && [ ! -s "$TMP/d2.out" ]; then
  ok "D2 不在ファイルは rc=3（型付き行なし rc=1 へ倒さない）"
else
  bad "D2 不在ファイルの rc が 3 でない（rc=${rc_d2}）"
fi

printf '%s\n' '- Critical: 1' '- Warning: 本文' > "$TMP/d3.md"
rc_d3=0
(
  # shellcheck source=../../scripts/adapters/adapter-common.sh
  source "$ADAPTER_COMMON"
  typed_verdicts_extract "$TMP/d3.md"
) >"$TMP/d3.out" 2>"$TMP/d3.err" || rc_d3=$?
if [ "$rc_d3" -eq 1 ] && [ ! -s "$TMP/d3.out" ] && [ "$(cat "$TMP/d3.err")" = "$PROSE_CRIT_DIAG" ]; then
  ok "D3 散文だけの本文は rc=1・出力なし・散文 Critical の診断 1 行だけ（数えない）"
else
  bad "D3 散文だけの本文の抽出が rc=1 / 無出力 / 診断 1 行でない（rc=${rc_d3}: $(cat "$TMP/d3.err")）"
fi

echo "== P. 散文だけの本文の拒否と診断（ADR-066） =="

# pcase <ラベル> <期待 rc> <期待 stderr: diag|none> — 本文は stdin。review_body_present の
# rc と stderr を**全文一致**で見る（診断の他に何も混ざらないこと・名指しの文面そのもの）
# 第 4 引数を渡すと review_body_present の第 2 引数（診断ラベル）として渡し、期待の文面も
# `typed-verdict: <ラベル>: …` の形へ切り替える（空文字列はラベル部ごと省く）。
pcase() {
  local label="$1" exp_rc="$2" exp_err="$3" body rc want
  body="$(cat)"
  rc=0
  (
    # shellcheck source=../../scripts/adapters/adapter-common.sh
    source "$ADAPTER_COMMON"
    if [ "$#" -ge 4 ]; then review_body_present "$body" "$4"; else review_body_present "$body"; fi
  ) 2>"$TMP/p.err" || rc=$?
  want="$PROSE_REFUSED_DIAG"
  if [ "$#" -ge 4 ] && [ -n "$4" ]; then want="typed-verdict: $4: prose-only review refused (no valid verdict line)"; fi
  if [ "$rc" != "$exp_rc" ]; then
    bad "${label}: rc が期待 ${exp_rc} に対し ${rc}"
    return 0
  fi
  case "$exp_err" in
    diag)
      if [ "$(cat "$TMP/p.err")" = "$want" ]; then
        ok "${label}: rc=${rc}・診断 1 行だけ"
      else
        bad "${label}: stderr が診断 1 行と一致しない（実測: $(cat "$TMP/p.err")）"
      fi
      ;;
    none)
      if [ ! -s "$TMP/p.err" ]; then
        ok "${label}: rc=${rc}・stderr 空"
      else
        bad "${label}: stderr が空でない（実測: $(cat "$TMP/p.err")）"
      fi
      ;;
  esac
}

pcase "P1 散文の件数行だけの本文は不受理（診断つき）" 1 diag <<'BODY'
## Summary
- Critical: 0 / Warning: 0 / Suggestion: 0
BODY

pcase "P2 散文だけ + 未閉フェンス（マスク放棄の条件で散文ありと読み、不受理・診断つき）" 1 diag <<'BODY'
- Warning: 例外を握りつぶしている
```
- Critical: 0
BODY

pcase "P3 有効な型付き行 + 散文（型付きで受理・診断なし）" 0 none <<'BODY'
### Warning
- [app.sh:3] 例外を握りつぶしている
  - verdict: severity=warning failure_scenario=yes confidence=85 file=app.sh line=3
- Critical: 0 / Warning: 1 / Suggestion: 0
BODY

pcase "P4 散文の実体行も無い本文（前置きだけ）は不受理・診断なし" 1 none <<'BODY'
本レスポンスは read-only レビュー sub-agent の報告です。
BODY

pcase "P6 ラベルを渡すと診断が <ラベル>: で名指しする" 1 diag "Codex CLI/code-review" <<'BODY'
- Critical: 0 / Warning: 0 / Suggestion: 0
BODY

pcase "P7 空ラベルはラベル部ごと省く（typed-verdict: : にしない）" 1 diag "" <<'BODY'
- Critical: 0 / Warning: 0 / Suggestion: 0
BODY

# 拒否の診断は受理モードだけ。Critical 検出・抽出は同じ散文本文でも出さず、判定は
# 根拠なし（検出 rc4 / 抽出 rc1）。散文にゼロ件行しか無いので Critical の診断も出ない
printf '%s\n' '- Critical: 0 / Warning: 0 / Suggestion: 0' > "$TMP/p5.md"
p5_rc_c=0
(
  # shellcheck source=../../scripts/adapters/adapter-common.sh
  source "$ADAPTER_COMMON"
  critical_findings_present "$TMP/p5.md"
) 2>"$TMP/p5c.err" || p5_rc_c=$?
p5_rc_e=0
(
  # shellcheck source=../../scripts/adapters/adapter-common.sh
  source "$ADAPTER_COMMON"
  typed_verdicts_extract "$TMP/p5.md"
) >/dev/null 2>"$TMP/p5e.err" || p5_rc_e=$?
if [ "$p5_rc_c" -eq 4 ] && [ "$p5_rc_e" -eq 1 ] && [ ! -s "$TMP/p5c.err" ] && [ ! -s "$TMP/p5e.err" ]; then
  ok "P5 散文だけの本文の検出は rc4（根拠なし）・抽出は rc1、どちらも拒否の診断を出さない"
else
  bad "P5 検出・抽出の rc か stderr が違う（rc_c=${p5_rc_c} rc_e=${p5_rc_e}: $(cat "$TMP/p5c.err" "$TMP/p5e.err")）"
fi

# P8. (t) 行の無い本文の散文 Critical は数えず、検出・抽出の両モードが 1 行ずつ名指しする。
#     受理モードは拒否の診断だけ（Critical の診断は出さない）。fail-safe が立つ回・
#     未閉フェンスの回は出さない
printf '%s\n' '### Critical Issues' '- [app.txt:2] 散文だけで書いた指摘' > "$TMP/p8.md"
p8_rc_a=0
(
  # shellcheck source=../../scripts/adapters/adapter-common.sh
  source "$ADAPTER_COMMON"
  review_body_present "$(cat "$TMP/p8.md")"
) 2>"$TMP/p8a.err" || p8_rc_a=$?
p8_rc_c=0
(
  # shellcheck source=../../scripts/adapters/adapter-common.sh
  source "$ADAPTER_COMMON"
  critical_findings_present "$TMP/p8.md"
) 2>"$TMP/p8c.err" || p8_rc_c=$?
p8_rc_e=0
(
  # shellcheck source=../../scripts/adapters/adapter-common.sh
  source "$ADAPTER_COMMON"
  typed_verdicts_extract "$TMP/p8.md"
) >/dev/null 2>"$TMP/p8e.err" || p8_rc_e=$?
if [ "$p8_rc_a" -eq 1 ] && [ "$(cat "$TMP/p8a.err")" = "$PROSE_REFUSED_DIAG" ] \
   && [ "$p8_rc_c" -eq 4 ] && [ "$(cat "$TMP/p8c.err")" = "$PROSE_CRIT_DIAG" ] \
   && [ "$p8_rc_e" -eq 1 ] && [ "$(cat "$TMP/p8e.err")" = "$PROSE_CRIT_DIAG" ]; then
  ok "P8 散文の Critical は数えない（受理 rc1 + 拒否の診断 / 検出 rc4・抽出 rc1 + Critical の診断 1 行ずつ）"
else
  bad "P8 散文の Critical の扱いが違う（受理 rc${p8_rc_a} / 検出 rc${p8_rc_c} / 抽出 rc${p8_rc_e}: $(cat "$TMP/p8a.err" "$TMP/p8c.err" "$TMP/p8e.err")）"
fi
printf '%s\n' '### Critical Issues' '- [app.txt:2] 散文だけで書いた指摘' '- verdict: severity=critical failure_scenario=yes' > "$TMP/p8b.md"
p8b_rc_c=0
(
  # shellcheck source=../../scripts/adapters/adapter-common.sh
  source "$ADAPTER_COMMON"
  critical_findings_present "$TMP/p8b.md"
) 2>"$TMP/p8b.err" || p8b_rc_c=$?
if [ "$p8b_rc_c" -eq 0 ] && ! grep -qxF -- "$PROSE_CRIT_DIAG" "$TMP/p8b.err"; then
  ok "P8 fail-safe が立つ回は Critical あり（rc0）で、散文 Critical の診断は出さない"
else
  bad "P8 fail-safe の回の扱いが違う（rc${p8b_rc_c}: $(cat "$TMP/p8b.err")）"
fi

# D4. 散文の Critical を (t) 行が覆した回は、抽出（verdicts）モードも検出モードと同じ
#     診断を stderr へ出す（統合レポートの型付き経路は抽出だけを呼ぶ）。fail-safe が立つ回
#     （不採用の critical 行あり）は覆していないので出さない
printf '%s\n' '### Critical Issues' '- [app.txt:2] 散文だけで書いた指摘' '- verdict: none' > "$TMP/d4.md"
printf '%s\n' '### Critical Issues' '- [app.txt:2] 散文だけで書いた指摘' '- verdict: none' \
  '- verdict: severity=critical failure_scenario=yes' > "$TMP/d4b.md"
rc_d4=0
(
  # shellcheck source=../../scripts/adapters/adapter-common.sh
  source "$ADAPTER_COMMON"
  typed_verdicts_extract "$TMP/d4.md"
) >/dev/null 2>"$TMP/d4.err" || rc_d4=$?
rc_d4b=0
(
  # shellcheck source=../../scripts/adapters/adapter-common.sh
  source "$ADAPTER_COMMON"
  typed_verdicts_extract "$TMP/d4b.md"
) >/dev/null 2>"$TMP/d4b.err" || rc_d4b=$?
if [ "$rc_d4" -eq 0 ] && grep -qF 'typed-verdict: prose Critical finding overridden by typed verdict lines (0 critical)' "$TMP/d4.err"; then
  ok "D4 抽出モードも散文の Critical を覆した診断を出す"
else
  bad "D4 抽出モードが散文の Critical を覆した診断を出さない（rc=${rc_d4}）: $(cat "$TMP/d4.err")"
fi
if [ "$rc_d4b" -eq 0 ] && ! grep -qF 'prose Critical finding overridden' "$TMP/d4b.err"; then
  ok "D4 fail-safe が立つ回は覆した診断を出さない"
else
  bad "D4 fail-safe が立つ回に覆した診断が出た（rc=${rc_d4b}）: $(cat "$TMP/d4b.err")"
fi

echo "== E. 委譲と BSD awk 互換の静的 pin =="

if grep -q '_ff_severity_scan verdicts' "$ADAPTER_COMMON"; then
  ok "typed_verdicts_extract は _ff_severity_scan verdicts へ委譲する（フェンス追跡を共有）"
else
  bad "typed_verdicts_extract が共有パーサーへ委譲していない（フェンス追跡の第二実装）"
fi

# (t) の文法部品（vd_cand_re / vd_none_word / vd_head_re / vd_rej_crit_re）と vd_parse の正規表現に interval 表記
# （{n} / {n,m}）が無いこと。BSD awk は interval の対応に依存できない。
vd_lines="$(grep -E 'vd_(cand|head|rej_crit)_re *=|vd_none_word *=|vd_(sev|fs|conf|line) !~' "$ADAPTER_COMMON" || true)"
if [ -z "$vd_lines" ]; then
  bad "(t) の文法部品の定義行が見つからない（針が当たらない）"
elif grep -qE '\{[0-9]+(,[0-9]*)?\}' <<<"$vd_lines"; then
  bad "(t) の文法部品に interval 表記がある（BSD awk 非互換）: $vd_lines"
else
  ok "(t) の文法部品は interval 表記を使わない"
fi

echo
if [ $((PASS + FAIL)) -eq 0 ]; then
  echo "✗ typed-verdict-parser verify: 検査が 1 件も実行されていません" >&2
  FF_REACHED_END=1
  exit 1
fi
if [ "$FAIL" -gt 0 ]; then
  echo "✗ typed-verdict-parser verify: $FAIL 件失敗" >&2
  FF_REACHED_END=1
  exit 1
fi
echo "✓ typed-verdict-parser verify: 全 $PASS 件 pass"
FF_REACHED_END=1
