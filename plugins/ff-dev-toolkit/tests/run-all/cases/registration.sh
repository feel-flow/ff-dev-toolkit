# shellcheck shell=bash
# RUN_OUT / RUN_RC は source 元の verify.sh の expect_* が読む（このファイル単体では未使用に見える）
# shellcheck disable=SC2034
# pipefail-inherited: verify.sh が set -euo pipefail の下で source する
# case 13・14・14b: 既定 suite 一覧の登録照合と必須名簿
#
# verify.sh から source される（ok / bad / expect_* / run_runner / RUN_OUT / RUN_RC / RUNNER / TESTS_DIR を共有）。
# 読む順序は verify.sh の一覧が正本で、前の cases の fixture と関数を後ろの cases が使う（Issue `#2696`）。

echo ""
echo "== case 13: 既定 suite 一覧の登録漏れ検査 =="

# SCRIPTS 配列は手で維持されており、一覧から 1 行消しても残り全部が緑のまま「All ... passed」を
# 出す（実測）。ランナー側に照合を持たせた。ここは全 suite を走らせずに照合だけを回す
# （FF_RUN_ALL_CHECK_REGISTRATION=1）。その入口は引数なし実行を要求するので、入れ子ガードに
# 当たらないよう FF_RUN_ALL_NESTED を落として呼ぶ。
#
# 1 回の実行で「登録漏れなし」と「必須名簿の件数報告」の両方を見る（名簿の実在検査が登録照合へ
# 相乗りしていること = 改名・削除への追従）。高速モード指定下でも同じ結果になることを続けて測る
# — 除外フィルタは check_suite_registration の**後**にあり、フィルタを照合の前へ移す変異は
# 除外された selftest 群が「未登録」扱いになって赤くなる形で検出できる。
_reg_check() { # <env 指定...>
  _reg_rc=0
  if _reg_out="$(env -u FF_RUN_ALL_NESTED "$@" FF_RUN_ALL_CHECK_REGISTRATION=1 bash "$RUNNER" 2>&1)"; then
    _reg_rc=0
  else
    _reg_rc=$?
  fi
}
_reg_expect() { # <出力に含まれるべき部分文字列> <検査名>
  case "$_reg_out" in
    *"$1"*) _reg_seen=1 ;;
    *) _reg_seen=0 ;;
  esac
  if [ "$_reg_rc" -eq 0 ] && [ "$_reg_seen" -eq 1 ]; then
    ok "$2"
  else
    bad "$2 (rc=${_reg_rc})"
    printf '%s\n' "$_reg_out" | sed 's/^/    | /' >&2
  fi
}
# _reg_expect は部分文字列の完全一致しか見ないため、「必須 <件数> 件」の形が「必須 未集計」の
# ような非数値へ退行しても素通りする（実測）。件数が数字であることまで grep -E で照合する。
# `| grep -q` は case 10 の再混入ガードに自ら抵触するため grep -c（out_matches と同じ流儀）で読み切る。
_reg_expect_re() { # <grep -E パターン> <検査名>
  if [ "$_reg_rc" -eq 0 ] && [ "$(printf '%s\n' "$_reg_out" | grep -cE "$1")" -gt 0 ]; then
    ok "$2"
  else
    bad "$2 (rc=${_reg_rc})"
    printf '%s\n' "$_reg_out" | sed 's/^/    | /' >&2
  fi
}

_reg_check -u FF_RUN_ALL_FAST -u FF_RUN_ALL_FULL
_reg_expect "登録漏れなし" "現状の tests/ は既定一覧と整合している"
_reg_expect_re '必須 [0-9]+ 件' "登録照合が必須名簿の件数も報告する（実在しない名前は非 0）"

_reg_check -u FF_RUN_ALL_FULL FF_RUN_ALL_FAST=1
_reg_expect "登録漏れなし" "高速モード指定下でも登録照合はフィルタ前の全一覧で通る"
# 随伴先すべてに追随済み（実体そのもの）の正常系では、随伴先文書への
# 案内を出し続けない（毎回ノイズになる警告を正常系で出さない）。
case "$_reg_out" in
  *"docs/04-quality/TESTING.md"*) bad "登録漏れなしの正常系で随伴先文書への案内が混入している（正常系ではノイズを出さない）" ;;
  *) ok "登録漏れなしの正常系では随伴先文書への案内を出さない" ;;
esac

# 未登録の suite を検出できること。実体側に 1 本足して照合を回す（run-all.sh 本体は触らない —
# 走査先は $SCRIPT_DIR なので、複製した木で試す）。複製先は tests/ の外: tests/ 直下に置くと
# 本体の登録検査自身がそれを未登録 suite として拾う（検査対象を作ることで検査を壊す形）。
_reg_fx="$RUN_WORK/ff-registration-probe"
rm -rf "$_reg_fx"
mkdir -p "$_reg_fx/unregistered-probe"
printf '#!/usr/bin/env bash\nexit 0\n' > "$_reg_fx/unregistered-probe/verify.sh"
chmod +x "$_reg_fx/unregistered-probe/verify.sh"
cp "$TESTS_DIR/run-all.sh" "$_reg_fx/run-all.sh"
_reg_rc=0
if _reg_out="$(env -u FF_RUN_ALL_NESTED -u FF_RUN_ALL_FAST -u FF_RUN_ALL_FULL FF_RUN_ALL_CHECK_REGISTRATION=1 \
  FF_GATE_RECORD_FILE="$RUN_GATE_RECORD" bash "$_reg_fx/run-all.sh" 2>&1)"; then _reg_rc=0; else _reg_rc=$?; fi
case "$_reg_out" in
  *"unregistered-probe"*) _reg_named=1 ;;
  *) _reg_named=0 ;;
esac
# 名指しと rc だけでは「案内文言そのものが出ているか」を固定できない（1 行目だけ
# 消しても _reg_named / rc は変わらず赤にならない）。案内文言の path / 節名の
# 含有まで見る（case 38 の未掲載分岐と同じ観点）。
case "$_reg_out" in
  *"docs/04-quality/TESTING.md"*) _reg_doc_path=1 ;;
  *) _reg_doc_path=0 ;;
esac
case "$_reg_out" in
  *"新規 suite 追加の随伴先"*) _reg_doc_section=1 ;;
  *) _reg_doc_section=0 ;;
esac
if [ "$_reg_rc" -ne 0 ] && [ "$_reg_named" -eq 1 ] && [ "$_reg_doc_path" -eq 1 ] && [ "$_reg_doc_section" -eq 1 ]; then
  ok "未登録の suite を名指しして非 0 で終わり、随伴先文書のパス・節名も案内する"
else
  bad "未登録の suite を検出できなかった、または随伴先文書の案内が欠けている (rc=${_reg_rc} named=${_reg_named} doc_path=${_reg_doc_path} doc_section=${_reg_doc_section})"
  printf '%s\n' "$_reg_out" | sed 's/^/    | /' >&2
fi
rm -rf "$_reg_fx"

echo ""
echo "== case 14: 必須 suite の名簿が実体から導出され、skip が終了コードに現れる配線 =="

# yq / node_modules が無い環境では該当 suite が丸ごと skip され、それでも全体は緑になっていた
# （実測。`#274` / `#372`）。必須名簿を持たせ、名簿の suite が skip したら失敗として扱う（環境都合で
# 回せない場合は FF_RUN_ALL_ALLOW_SKIP で明示宣言する）。振る舞いの実測は「yq を PATH から
# 外した run-all」で行った（PR 本文に記録）。ここは**配線が外れないこと**を構造で固定する。
_ra_src="$TESTS_DIR/run-all.sh"
case "$(cat "$_ra_src")" in
  *"REQUIRED_SUITES=("*) _has_roster=1 ;;
  *) _has_roster=0 ;;
esac
if [ "$_has_roster" -eq 1 ]; then
  ok "必須 suite 名簿が定義されている"
else
  bad "必須 suite 名簿が消えた（環境都合の skip が黙って通る）"
fi
# かつてここには一時領域依存の必須 suite 17 名のハードコード・ミラーがあった。名簿から名前が
# 消えた側を実装（run-all.sh）が検出できず、複製でしか押さえられなかったためである。
# 現在は run-all.sh 自身が**実体から必須集合を導出して名簿と双方向で突き合わせる**ので、
# 名簿から 1 名消せば run-all がその場で赤くなる（複製は削除した）。
#
# ここでは照合が**実際に走って一致した**ことを実行で確かめる。構造検査（grep）だけだと、
# 導出関数を書いたまま呼ばない形・info 行だけ残して比較を落とした形が素通りする。
_reg_live_rc=0
# case 13 と同じ流儀で呼ぶ: 照合の入口は引数なし実行を要求するので入れ子ガードを落とし、
# モード変数は外側から漏らさない（照合はモードに依らないが、漏れると観測が回ごとに変わる）。
if _reg_live_out="$(env -u FF_RUN_ALL_NESTED -u FF_RUN_ALL_FAST -u FF_RUN_ALL_FULL \
  FF_RUN_ALL_CHECK_REGISTRATION=1 FF_GATE_RECORD_FILE="$RUN_GATE_RECORD" bash "$_ra_src" 2>&1)"; then _reg_live_rc=0; else _reg_live_rc=$?; fi
if [ "$_reg_live_rc" -eq 0 ] && printf '%s\n' "$_reg_live_out" | awk '
  index($0, "実体からの導出と一致") { found=1 } END { exit !found }
'; then
  ok "実体から導出した必須集合が REQUIRED_SUITES と一致する（照合が実際に走っている）"
else
  bad "実体からの逆向き照合が走っていない / 一致しなかった (rc=${_reg_live_rc})"
  printf '%s\n' "$_reg_live_out" | sed 's/^/    | /' >&2
fi
# 双方向のどちらか一方だけを落とす変異は上の live 照合では緑のままなので、両方向の
# 失敗経路が実装に在ることを固定する（片方向へ戻す退行がこの suite の唯一の防御）。
expect_src 'REQUIRED_SUITES に載っていない必須 suite' "$_ra_src" \
  "実体 → 名簿の向き（名簿から消えた必須 suite）の検出が在る" \
  "名簿から名前を消しても緑になる（逆向き導出が消えた）"
expect_src 'REQUIRED_SUITES の掲載に実体側の根拠がない' "$_ra_src" \
  "名簿 → 実体の向き（根拠のない掲載）の検出が在る" \
  "実体側の根拠を持たない名簿掲載が素通りする"
# 終了条件に REQUIRED_SKIPPED が含まれること。名簿だけあって配線が無い形を弾く。**エラー表示側の
# 条件と取り違えない** — 表示だけ残して終了条件から外す変異は「REQUIRED_SKIPPED を含む if 行」を
# 数えるだけでは素通りする（実測）。終了条件は FAILED / NOT_RUN と同じ行に並ぶので共起で特定する。
expect_src '^\s*if \[\[ .*FAILED\[@\].*REQUIRED_SKIPPED\[@\].*\]\]; then' "$_ra_src" \
  "必須 suite の skip が終了コードの判定に含まれている" \
  "名簿はあるが終了コードへ効いていない（skip しても緑のまま）"
# 走査の終了コードを捨てる形（`for entry in $(suite_declaration_scan …)`）は、BSD awk が
# 「開けない verify.sh を警告して次へ進み最後に非 0 を返す」ため、1 本だけ読めない suite を
# 黙って導出から落とす（名簿にも無ければ緑のまま）。受けて fail-closed にした形を固定する。
expect_src 'verify.sh の走査が失敗しました' "$_ra_src" \
  "走査の失敗を fail-closed にする経路が在る" \
  "awk の終了コードを捨てている（読めない verify.sh が黙って導出から落ちる）"
expect_src '理由の無い run-all-required 宣言、または本文の無い 空振り検出 宣言があります' "$_ra_src" \
  "理由を欠く run-all-required 宣言 / 本文を欠く 空振り検出 宣言の検出が在る" \
  "理由なしの no 宣言で判断の記録なしに必須から外れる（または本文なしの空振り検出宣言が通る）"
# 空振り検出の宣言（Issue `#1665`）: 名簿外 suite への要求・名簿の実在照合・宣言済み suite の
# 名簿残留の 3 経路が実装に在ること。振る舞いは下の 14b で複製木を崩して実測する。
expect_src '空振り検出の宣言が無い suite があります' "$_ra_src" \
  "名簿（MISS_PROBE_BASELINE）外の suite に空振り検出の宣言を要求する経路が在る" \
  "新設 suite が宣言なしで登録照合を通る（Issue 1665 の導線が消えた）"
expect_src 'MISS_PROBE_BASELINE に実在しない suite 名があります' "$_ra_src" \
  "免除名簿の実在照合が在る" \
  "改名・削除に未追従の名簿行が何も免除しないまま残る"
expect_src '空振り検出を宣言した suite が MISS_PROBE_BASELINE に残っています' "$_ra_src" \
  "宣言済み suite の名簿残留を赤にする経路が在る（名簿は縮める方向のみ）" \
  "宣言を足しても名簿が「未実測」を主張し続ける"

# ── 導出述語の対照（引用符種別と「出力文の行頭 skip」の境界）────────────────────
# 述語は run-all.sh の内部関数なので、**複製木へ run-all.sh を置いて宣言ダンプだけを回す**
# （登録照合は名簿と実体の全件一致を要求するため、probe 数本の木では回せない）。
# 二重引用符しか拾わない述語は、単一引用符・printf で skip を出す suite を導出から落とし、
# 名簿に載っていなくても緑のまま通す（静的側だけが緩い非対称）。逆に「出力文であること」を
# 落とすと、アサート行の期待値文字列まで skip 経路と誤認して必須へ引き上げる。
_pred_fx="$RUN_WORK/ff-skip-predicate-probe"
rm -rf "$_pred_fx"
mkdir -p "$_pred_fx"
cp "$_ra_src" "$_pred_fx/run-all.sh"
_pred_add() { # <suite 名> <printf 書式（verify.sh 本文）>
  mkdir -p "$_pred_fx/$1"
  # shellcheck disable=SC2059  # 書式そのものを呼び出し側が組み立てる（\047 で単一引用符を置く）
  printf "$2" > "$_pred_fx/$1/verify.sh"
  chmod +x "$_pred_fx/$1/verify.sh"
}
# 負の対照 1: アサート行にだけ `"○ skip` を含む（出力文ではない）
_pred_add pred-neg-assert '#!/usr/bin/env bash\nif [ "$OUT" = "○ skip: 期待値照合" ]; then :; fi\nexit 0\n'
# 負の対照 2: インデント付きの部分 skip（suite 全体 skip ではない）
_pred_add pred-neg-partial '#!/usr/bin/env bash\necho "  ○ skip: 一部の検査だけ飛ばした"\nexit 0\n'
# 正の対照 1: 単一引用符で行頭 skip を出す
_pred_add pred-pos-single '#!/usr/bin/env bash\necho \047○ skip: 単一引用符で行頭 skip を出す\047\nexit 0\n'
# 正の対照 2: printf の書式文字列で行頭 skip を出す
_pred_add pred-pos-printf '#!/usr/bin/env bash\nprintf \047○ skip: printf で行頭 skip を出す\\n\047\nexit 0\n'
# 負の対照 3: 理由を欠く宣言（yes / no のどちらでもなく bad として印が付く）
_pred_add pred-neg-noreason '#!/usr/bin/env bash\n# run-all-required: no\nexit 0\n'
# 正の対照 3: 本文を持つ空振り検出の宣言（probe=1）
_pred_add pred-pos-probe '#!/usr/bin/env bash\n# 空振り検出: 対象ディレクトリの不在を与えると (1) が赤になる。\nexit 0\n'
# 負の対照 4: 本文を欠く空振り検出の宣言（probe ではなく bad として印が付く）
_pred_add pred-neg-probe-empty '#!/usr/bin/env bash\n# 空振り検出:   \nexit 0\n'
# 負の対照 5: 本文を次のコメント行へ折り返した宣言（本文は同じ行に書く契約。bad）
_pred_add pred-neg-probe-continuation '#!/usr/bin/env bash\n# 空振り検出:\n#   対象不在で (1) が赤になる。\nexit 0\n'
# 負の対照 6: ヘッダの外（最初の非コメント行より後ろ）の宣言は数えない（bad）
_pred_add pred-neg-probe-late '#!/usr/bin/env bash\nset -eu\n# 空振り検出: 対象不在で (1) が赤になる。\nexit 0\n'
# 負の対照 7: heredoc 本文の中の同形も数えない（fixture を書く suite が宣言済みに化けない）
_pred_add pred-neg-probe-heredoc '#!/usr/bin/env bash\ncat > /dev/null <<EOF\n# 空振り検出: heredoc の中\nEOF\nexit 0\n'
# 対照 8: 本文付き + 本文なしが同居 — bad が勝つ（probe と bad の両方に印が付く）
_pred_add pred-mix-probe-multi '#!/usr/bin/env bash\n# 空振り検出: 対象不在で (1) が赤になる。\n# 空振り検出:\nexit 0\n'
_pred_rc=0
if ! _pred_out="$(env -u FF_RUN_ALL_NESTED -u FF_RUN_ALL_FAST -u FF_RUN_ALL_FULL \
  FF_RUN_ALL_DUMP_DECLARATIONS=1 FF_GATE_RECORD_FILE="$RUN_GATE_RECORD" \
  bash "$_pred_fx/run-all.sh" 2>&1)"; then _pred_rc=$?; fi
_pred_expect() { # <期待する 1 行> <検査名>
  if [ "$_pred_rc" -eq 0 ] && printf '%s\n' "$_pred_out" | awk -v want="$1" '
    $0 == want { found = 1 } END { exit !found }
  '; then
    ok "$2"
  else
    bad "$2 (rc=${_pred_rc})"
    printf '%s\n' "$_pred_out" | sed 's/^/    | /' >&2
  fi
}
_pred_expect 'pred-neg-assert:0:0:0:0:0' "アサート行の期待値文字列を suite 全体 skip に数えない（負の対照）"
_pred_expect 'pred-neg-partial:0:0:0:0:0' "インデント付き部分 skip を suite 全体 skip に数えない（負の対照）"
_pred_expect 'pred-pos-single:1:0:0:0:0' "単一引用符の行頭 skip を suite 全体 skip として拾う（正の対照）"
_pred_expect 'pred-pos-printf:1:0:0:0:0' "printf の書式文字列の行頭 skip を拾う（正の対照）"
_pred_expect 'pred-neg-noreason:0:0:0:1:0' "理由を欠く run-all-required 宣言に bad の印が付く（負の対照）"
_pred_expect 'pred-pos-probe:0:0:0:0:1' "本文を持つ空振り検出の宣言を probe として拾う（正の対照）"
_pred_expect 'pred-neg-probe-empty:0:0:0:1:0' "本文を欠く空振り検出の宣言は probe に数えず bad の印が付く（負の対照）"
_pred_expect 'pred-neg-probe-continuation:0:0:0:1:0' "本文を次行へ折り返した宣言は bad（本文は同じ行に書く）（負の対照）"
_pred_expect 'pred-neg-probe-late:0:0:0:1:0' "ヘッダの外に置いた宣言は probe に数えず bad の印が付く（負の対照）"
_pred_expect 'pred-neg-probe-heredoc:0:0:0:1:0' "heredoc 本文の中の同形は probe に数えず bad の印が付く（負の対照）"
_pred_expect 'pred-mix-probe-multi:0:0:0:1:1' "本文付きと本文なしが同居すると bad の印も付く（malformed が先に落ちる）"
rm -rf "$_pred_fx"

echo ""
echo "== case 14b: 空振り検出の宣言の登録照合（名簿外 suite は宣言必須・名簿は縮める方向のみ）=="

# 実体の木では全 suite が名簿か宣言のどちらかを持つので、赤の経路は複製木でしか踏めない。
# 複製木は case 26 と同じく宣言ダンプ（実装側の述語）から stub を起こし、run-all.sh の
# 名簿と stub の宣言だけを崩す。崩した先は毎回 grep -c で適用を確かめる（適用に失敗しても
# 「緑」は検出失敗と同じ顔をするため）。犠牲にする suite は**複製木の中で合成する**
# （`miss-probe-victim`。SCRIPTS と MISS_PROBE_BASELINE へ足す）— 実体の名簿から借りると、
# 全 suite が遡及済みで名簿が空になった終端状態（run-all.sh が明示的に許す）で本ケースが
# 恒久的に赤になる。
_probe_decl_rc=0
if ! _probe_decl_raw="$(env -u FF_RUN_ALL_NESTED -u FF_RUN_ALL_FAST -u FF_RUN_ALL_FULL \
  FF_RUN_ALL_DUMP_DECLARATIONS=1 FF_GATE_RECORD_FILE="$RUN_GATE_RECORD" \
  bash "$_ra_src" 2>&1)"; then _probe_decl_rc=$?; fi
# 材料は case 26 と同じ書式フィルタを通す（非 0 時の警告文や余計な語が stub 名に化けない）
_probe_decl="$(printf '%s\n' "$_probe_decl_raw" | grep -E '^[A-Za-z0-9._-]+:[01]:[01]:[01]:[01]:[01]$' || true)"
_probe_decl_n="$(printf '%s\n' "$_probe_decl" | grep -c .)"
_probe_undeclared_n="$(printf '%s\n' "$_probe_decl" | grep -c ':0$')"
_probe_fx="$RUN_WORK/ff-miss-probe-registration"
_probe_victim="miss-probe-victim"
_probe_stub() { # <dir> <yes> <no> <probe> <skip> : 複製木の stub を書く（宣言はヘッダに置く）
  {
    printf '#!/usr/bin/env bash\n'
    if [ "$2" = "1" ]; then printf '# run-all-required: yes — 複製木 stub\n'; fi
    if [ "$3" = "1" ]; then printf '# run-all-required: no — 複製木 stub\n'; fi
    if [ "$4" = "1" ]; then printf '# 空振り検出: 複製木 stub（実体の宣言を写した導出材料）\n'; fi
    if [ "$5" = "1" ]; then printf 'if false; then echo "○ skip: 逆向き導出の材料"; fi\n'; fi
    printf 'exit 0\n'
  } > "$1/verify.sh"
  chmod +x "$1/verify.sh"
}
_probe_build() { # <dir> : 実体を写した複製木 + 合成した犠牲 suite。適用を確かめ、失敗なら非 0
  rm -rf "$1"
  mkdir -p "$1"
  cp "$_ra_src" "$1/run-all.sh"
  local n flags skip rest yes no probe
  while IFS= read -r _probe_e; do
    [ -n "$_probe_e" ] || continue
    n="${_probe_e%%:*}"; flags="${_probe_e#*:}"
    skip="${flags%%:*}"; rest="${flags#*:}"
    yes="${rest%%:*}"; rest="${rest#*:}"
    no="${rest%%:*}"; rest="${rest#*:}"
    probe="${rest#*:}"
    mkdir -p "$1/$n"
    _probe_stub "$1/$n" "$yes" "$no" "$probe" "$skip"
  done <<EOF
$_probe_decl
EOF
  mkdir -p "$1/$_probe_victim"
  _probe_stub "$1/$_probe_victim" 0 0 0 0
  sed -i.bak "s|^  SCRIPTS=(\$|&\\
    \"\$SCRIPT_DIR/${_probe_victim}/verify.sh\"|; s|^MISS_PROBE_BASELINE=(\$|&\\
  ${_probe_victim}|" "$1/run-all.sh" && rm -f "$1/run-all.sh.bak"
  [ "$(grep -c "^    \"\\\$SCRIPT_DIR/${_probe_victim}/verify.sh\"\$" "$1/run-all.sh")" -eq 1 ] \
    && [ "$(grep -c "^  ${_probe_victim}\$" "$1/run-all.sh")" -eq 1 ]
}
_probe_run() { # 複製木で登録照合だけを回す（_probe_out / _probe_rc）
  _probe_rc=0
  if _probe_out="$(env -u FF_RUN_ALL_NESTED -u FF_RUN_ALL_FAST -u FF_RUN_ALL_FULL \
    FF_RUN_ALL_CHECK_REGISTRATION=1 FF_GATE_RECORD_FILE="$RUN_GATE_RECORD" \
    bash "$_probe_fx/run-all.sh" 2>&1)"; then _probe_rc=0; else _probe_rc=$?; fi
}
_probe_expect_red() { # <ラベル> <名指しされるべき suite> <含むべき文言>... : 非 0 + 名指し + 全文言
  local label="$1" who="$2" needle miss=""
  shift 2
  # 名指し対象が空だと `*""*` が常に一致して名指し検査が空振りする
  [ -n "$who" ] || { bad "$label (名指し対象が空 — 名指し検査が成立しない)"; return; }
  case "$_probe_out" in *"$who"*) ;; *) miss="${miss} 名指し(${who})" ;; esac
  for needle in "$@"; do
    case "$_probe_out" in *"$needle"*) ;; *) miss="${miss} 文言(${needle})" ;; esac
  done
  if [ "$_probe_rc" -ne 0 ] && [ -z "$miss" ]; then
    ok "$label"
  else
    bad "$label (rc=${_probe_rc} 欠落:${miss:- なし})"
    printf '%s\n' "$_probe_out" | sed 's/^/    | /' >&2
  fi
}
_probe_expect_green() { # <ラベル> <期待する免除名簿の件数> : rc=0 + ℹ️ 行の件数一致
  if [ "$_probe_rc" -eq 0 ] && [ "$(printf '%s\n' "$_probe_out" | grep -c "空振り検出の免除名簿 $2 件")" -eq 1 ]; then
    ok "$1"
  else
    bad "$1 (rc=${_probe_rc} / 期待した免除名簿 $2 件の報告が無い)"
    printf '%s\n' "$_probe_out" | sed 's/^/    | /' >&2
  fi
}
_probe_roster_n() { # 複製木の名簿の行数
  awk '/^MISS_PROBE_BASELINE=\($/ { on = 1; next } on && /^\)$/ { exit } on && /^  [A-Za-z0-9._-]+$/ { n++ } END { print n + 0 }' "$_probe_fx/run-all.sh"
}
_probe_unlist() { # 複製木の名簿から victim の行を消す。行が無かった / 消えなかった、のどちらも非 0
  [ "$(grep -c "^  ${_probe_victim}\$" "$_probe_fx/run-all.sh")" -eq 1 ] || return 1
  sed -i.bak "/^  ${_probe_victim}\$/d" "$_probe_fx/run-all.sh" && rm -f "$_probe_fx/run-all.sh.bak"
  [ "$(grep -c "^  ${_probe_victim}\$" "$_probe_fx/run-all.sh")" -eq 0 ]
}
_probe_declare() { # <suite 名> <宣言行> : stub のヘッダ（2 行目）へ宣言を差し込む
  awk -v decl="$2" 'NR == 1 { print; print decl; next } { print }' "$_probe_fx/$1/verify.sh" > "$_probe_fx/$1/verify.sh.new" \
    && mv "$_probe_fx/$1/verify.sh.new" "$_probe_fx/$1/verify.sh" && chmod +x "$_probe_fx/$1/verify.sh"
  [ "$(grep -c -F -- "$2" "$_probe_fx/$1/verify.sh")" -eq 1 ]
}
_probe_ready=0
if [ "$_probe_decl_rc" -eq 0 ] && [ "$_probe_decl_n" -ge 1 ] && _probe_build "$_probe_fx"; then
  _probe_ready=1
  ok "14b-0: 宣言ダンプ ${_probe_decl_n} 件から複製木を起こし、犠牲 suite ${_probe_victim} を SCRIPTS と名簿へ合成できた"
else
  bad "14b-0: 複製木を起こせない（decl rc=${_probe_decl_rc} 材料 ${_probe_decl_n} 件）— 以降の 14b は成立しない"
fi
if [ "$_probe_ready" -eq 1 ]; then
  _probe_n="$(_probe_roster_n)"
  # 14b-0': 崩す前の複製木は通り、免除名簿の件数（実体 + 合成 1）を報告する
  _probe_run
  _probe_expect_green "14b-0': 崩していない複製木は登録照合を通り、免除名簿の件数（${_probe_n} 件）を報告する" "$_probe_n"
  # 14b-1: 名簿から外した suite（= 新設 suite と同じ立場）が宣言なしなら赤で名指し + 正本案内
  if _probe_unlist; then
    _probe_run
    _probe_expect_red "14b-1: 名簿外で宣言の無い suite を名指しし、正本のパス・節名を案内する" \
      "$_probe_victim" "空振り検出の宣言が無い suite" "docs/04-quality/TESTING.md" "針が当たらない入力の既定"
  else
    bad "14b-1: 複製木の名簿から ${_probe_victim} を外せなかった（変異が適用されていない）"
  fi
  # 14b-2: 同じ suite のヘッダへ本文付きの宣言を足すと通り、免除名簿は 1 件減って報告される
  if _probe_declare "$_probe_victim" '# 空振り検出: 対象ディレクトリの不在を与えると (1) が赤になる。'; then
    _probe_run
    _probe_expect_green "14b-2: 名簿外でもヘッダに本文付きの宣言があれば通る（免除名簿 $((_probe_n - 1)) 件）" "$((_probe_n - 1))"
  else
    bad "14b-2: 複製木の stub へ宣言を差し込めなかった（変異が適用されていない）"
  fi
  # 14b-2b: 同じ本文でもヘッダの外（最初の非コメント行より後ろ）に置いた宣言は数えない
  _probe_build "$_probe_fx" && _probe_unlist \
    && printf '# 空振り検出: 対象ディレクトリの不在を与えると (1) が赤になる。\n' >> "$_probe_fx/$_probe_victim/verify.sh"
  if [ "$(grep -c '^# 空振り検出:' "$_probe_fx/$_probe_victim/verify.sh")" -eq 1 ]; then
    _probe_run
    _probe_expect_red "14b-2b: ヘッダの外（exit 0 の後ろ）に置いた宣言は数えず、置き場所を案内して赤にする" \
      "$_probe_victim" "本文の無い 空振り検出 宣言" "ヘッダ（最初の非コメント行より前）"
  else
    bad "14b-2b: 複製木の stub 末尾へ宣言を足せなかった（変異が適用されていない）"
  fi
  # 14b-3: 宣言を持つ suite が名簿に残っていると赤（名簿は縮める方向のみ）
  _probe_build "$_probe_fx" && _probe_declare "$_probe_victim" '# 空振り検出: 対象ディレクトリの不在を与えると (1) が赤になる。'
  _probe_run
  _probe_expect_red "14b-3: 宣言済み suite の名簿残留を赤にする" \
    "$_probe_victim" "MISS_PROBE_BASELINE に残っています"
  # 14b-4: 名簿の実在しない名前は赤
  _probe_build "$_probe_fx"
  sed -i.bak 's/^MISS_PROBE_BASELINE=($/&\
  ghost-suite-miss-probe/' "$_probe_fx/run-all.sh" && rm -f "$_probe_fx/run-all.sh.bak"
  if [ "$(grep -c '^  ghost-suite-miss-probe$' "$_probe_fx/run-all.sh")" -eq 1 ]; then
    _probe_run
    _probe_expect_red "14b-4: 名簿の実在しない suite 名を赤にする" \
      "ghost-suite-miss-probe" "MISS_PROBE_BASELINE に実在しない suite 名"
  else
    bad "14b-4: 複製木の名簿へ実在しない名前を足せなかった（変異が適用されていない）"
  fi
  # 14b-5: 本文を欠く宣言は malformed として赤（名簿の内外を問わず、名簿照合より前に落ちる。
  # probe に数えないこと自体は case 14 の負の対照 pred-neg-probe-empty が固定する）
  _probe_build "$_probe_fx" && _probe_declare "$_probe_victim" '# 空振り検出:'
  _probe_run
  _probe_expect_red "14b-5: 本文の無い宣言は malformed として赤にする（pred-neg-probe-empty と対）" \
    "$_probe_victim" "本文の無い 空振り検出 宣言"
  # 14b-6（空振り）: 免除名簿を空にすると、宣言を持たない stub が**全件**名指しされる
  _probe_build "$_probe_fx"
  sed -i.bak '/^MISS_PROBE_BASELINE=($/,/^)$/{/^  [A-Za-z0-9._-]*$/d;}' "$_probe_fx/run-all.sh" && rm -f "$_probe_fx/run-all.sh.bak"
  if [ "$(_probe_roster_n)" -eq 0 ]; then
    _probe_run
    _probe_expect_red "14b-6: 免除名簿が空（集合が空）なら宣言の無い suite が名指しされ緑に倒れない" \
      "$_probe_victim" "空振り検出の宣言が無い suite"
    # 先頭 1 件だけ報告する退行は上では緑のまま通るので、名指しの行数を材料から突き合わせる
    _probe_named_n="$(printf '%s\n' "$_probe_out" | grep -c '^    [A-Za-z0-9._-]*$')"
    if [ "$_probe_named_n" -eq $((_probe_undeclared_n + 1)) ]; then
      ok "14b-6': 宣言の無い suite を全件（${_probe_named_n} 件 = 材料 ${_probe_undeclared_n} + 犠牲 1）名指しする"
    else
      bad "14b-6': 名指しが ${_probe_named_n} 件（期待 $((_probe_undeclared_n + 1)) 件）— 先頭だけ報告する形へ退行している"
    fi
  else
    bad "14b-6: 複製木の名簿を空にできなかった（変異が適用されていない）"
  fi
  # 14b-7: 名簿が空でも全 suite が宣言済みなら通る（遡及が終わった終端状態）。1 本の宣言を
  # 落とすとその suite だけが名指しされる
  _probe_build "$_probe_fx"
  sed -i.bak '/^MISS_PROBE_BASELINE=($/,/^)$/{/^  [A-Za-z0-9._-]*$/d;}' "$_probe_fx/run-all.sh" && rm -f "$_probe_fx/run-all.sh.bak"
  _probe_declared_all=1
  for _probe_dir in "$_probe_fx"/*/; do
    _probe_dn="$(basename "$_probe_dir")"
    [ -f "$_probe_dir/verify.sh" ] || continue
    if [ "$(grep -c '^# 空振り検出: ' "$_probe_dir/verify.sh")" -eq 0 ]; then
      _probe_declare "$_probe_dn" '# 空振り検出: 終端状態の材料（複製木 stub）。対象不在で (1) が赤になる。' || _probe_declared_all=0
    fi
  done
  if [ "$(_probe_roster_n)" -eq 0 ] && [ "$_probe_declared_all" -eq 1 ]; then
    _probe_run
    _probe_expect_green "14b-7: 免除名簿が空でも全 suite が宣言済みなら通る（免除名簿 0 件）" 0
    sed -i.bak '/^# 空振り検出: /d' "$_probe_fx/$_probe_victim/verify.sh" && rm -f "$_probe_fx/$_probe_victim/verify.sh.bak"
    if [ "$(grep -c '^# 空振り検出: ' "$_probe_fx/$_probe_victim/verify.sh")" -eq 0 ]; then
      _probe_run
      _probe_expect_red "14b-7': 終端状態から 1 本の宣言を落とすと、その suite だけが名指しされる" \
        "$_probe_victim" "空振り検出の宣言が無い suite"
      _probe_named_n="$(printf '%s\n' "$_probe_out" | grep -c '^    [A-Za-z0-9._-]*$')"
      [ "$_probe_named_n" -eq 1 ] && ok "14b-7'': 名指しは 1 件だけ（宣言済み suite を巻き込まない）" \
        || bad "14b-7'': 名指しが ${_probe_named_n} 件（期待 1 件）"
    else
      bad "14b-7': 犠牲 suite の宣言を落とせなかった（変異が適用されていない）"
    fi
  else
    bad "14b-7: 終端状態の複製木を作れなかった（名簿 $(_probe_roster_n) 件 / 全宣言 ${_probe_declared_all}）"
  fi
fi
rm -rf "$_probe_fx"

# suite-cases-end: registration.sh
