#!/usr/bin/env bash
#
# Markdown 契約検査の節スコープ照合（Issue #796 / #812）。
#
# 文書全体の grep だけで固定文言を検査すると、同じ一文を別の節（ハードルール節・
# 引用・再掲）へ書き写した時点で、**本来在るべき節から消えても緑のまま**通る。
# PR #810 で ace-refine の SKILL.md に対して実測した（ACE-810-1）。要件が「その節に
# 在ること」自体である検査は、見出しから節を切り出してから照合する。
#
# 公開関数:
#   section_scope_contains FILE HEADING NEEDLE
#       FILE の HEADING 節に NEEDLE（リテラル）が在れば 0。
#       在なければ 1 を返し、理由 1 行を stdout へ出す（呼び出し側の bad へ渡す）。
#       HEADING は見出し行の**リテラル前方一致**（`### 5. コードベース探索` のように
#       番号まで書く。正規表現ではない）。
#   section_scope_extract FILE HEADING
#       節本文そのものを stdout へ出して 0。節が確定できなければ 1 を返し、理由 1 行を
#       stdout へ出す（section_scope_contains はこれを使う）。節本文を要する検査
#       （番号列の順序など、真偽では足りないもの）はここを通す。**呼び出し側で awk を
#       書き直さない** — 節の定義が 2 つ並存すると、フェンス追跡や終端の規則が片方だけ
#       更新され、同じ文書に対して 2 つの答えが出る（2026-09 のレビュー指摘）。
#
# 契約:
#   - 見出しの一致本数が 1 本でなければ fail-closed。0 本 = 節が無い、2 本以上 =
#     要件が複数の節へ散った状態。どちらも「先頭 1 本だけ見て緑」にしない。
#   - 節は見出し行の次行から、次の見出し行（行頭 `#` + 空白）の直前まで。下位見出しの
#     小節は節に含めない（含めると、要件が小節へ移動した退行を拾えなくなる）。
#     小節へ移った needle は「節に無い」で赤くなる = fail-closed。
#   - コードフェンス（``` / ~~~）の中は見出しとして解釈しない。フェンス本文の
#     `# コメント` 行や `## 見出しの例示` で節が切れないよう、見出しの計数・節の
#     切り出しの双方でフェンス状態を追う。フェンス本文そのものは節に含める
#     （手順書のコマンド列は「その節に在ること」が要件になる典型）。
#   - 照合に grep は使わない。パイプ入力の `grep -q*` は `set -euo pipefail` 下で
#     上流を SIGPIPE にする事故になり、tests/run-all/verify.sh case 10 が横断検査で
#     禁じている。ここでは awk（入力を読み切る）とシェル内 `case` で照合する。
#
# 移行の判断基準（どの検査をこのヘルパへ寄せるか）:
#   対象 — 「その節に在ること」自体が要件のもの。
#     * 手順書のステップ内の分岐・条件（そのステップから消えたら実行経路に届かない）
#     * ハードルール節・安全弁節の固定文言
#     * 節ごとの契約（完了報告テンプレートの項目、入口宣言 など）
#     * 同じ語が文書内の別所へ引用・再掲されている針（全文 grep が写しに当たる）
#   非対象 — 節へ寄せない。
#     * 文書全体に 1 回だけ在ればよい針（frontmatter の description、他文書への伝播）
#     * 出現回数を固定する contains_exactly / expect_fixed_count 型
#     * 順序検査（行番号の前後比較）。ただし「節の中での順序」を見たいだけなら
#       `section_scope_extract` で本文を取る（自前の awk で節を切り直さない）
#     * 文書全体の禁止パターン検査（not_contains / lacks 型。節を切ると
#       「切った節の外なら書いてよい」に意味が変わる）
#
# 既知の制約: 閉じられていないフェンスがあると、そこから EOF までがフェンス本文として
# 扱われ、以降の見出しが見えなくなる。位置によって壊れ方が違い、対象見出しより**前**なら
# 見出し 0 本、**後**なら節が文書末尾まで伸びて別節の needle を拾う（= 緑で通る
# fail-open。2026-09 実測）。そこでスキャンは EOF 時点でフェンスが開いたままなら
# 見出し本数も本文も出さず、非数値 `UNCLOSED_FENCE` を返して既存の「検査不能」経路
# （赤）へ落とす。未閉じフェンスは位置に依らず検査不能で、緑にはならない。
# 移行前に対象節の範囲を実測すること。
#
# 本ファイルは source される前提（実行ビット不要）。bash 3.2 互換。
# 補足: 行頭が `# shellcheck …` の形をした散文コメントは shellcheck にディレクティブ
# として解釈され、そのファイルの静的検査が丸ごと止まる（Issue #530）。この注記の
# 書き出しを変えないこと。

# 見出し本数と節本文を 1 パスで取る（フェンス状態機械を 2 回書かないため）。
# 出力は 1 行目が見出し本数、2 行目以降が節本文。本文は END でまとめて出すので、
# 見出しが 2 本以上でも「先頭 1 本ぶんの本文」が漏れて誤って照合されることはない。
# フェンス状態機械は tests/lib/mbcs-guard.sh の mbcs_scan_bash_blocks と同型
# （開始フェンスの文字種と長さを記録し、同種・同長以上のフェンスだけを終了とみなす）。
_section_scope_scan() {
  awk -v h="$1" '
    { sub(/\r$/, "") }
    {
      line = $0
      stripped = line
      sub(/^[[:space:]]*/, "", stripped)
      if (in_fence == 1) {
        closer = stripped
        sub(/[[:space:]]*$/, "", closer)
        if (closer ~ /^(`+|~+)$/ && substr(closer, 1, 1) == fence_char && length(closer) >= fence_len) {
          in_fence = 0
        }
        if (inside == 1) body = body line "\n"
        next
      }
      if (stripped ~ /^(```|~~~)/) {
        fence_char = substr(stripped, 1, 1)
        fence_len = 0
        while (substr(stripped, fence_len + 1, 1) == fence_char) fence_len++
        in_fence = 1
        if (inside == 1) body = body line "\n"
        next
      }
      if (index(line, h) == 1) { n++; inside = 1; next }
      if (inside == 1 && line ~ /^#+ /) inside = 0
      if (inside == 1) body = body line "\n"
    }
    END {
      # EOF でフェンスが開いたままなら節の終端が決められない。見出し本数も本文も
      # 出さず、非数値を返して呼び出し側の「検査不能」経路（赤）へ落とす。
      if (in_fence == 1) { print "UNCLOSED_FENCE"; exit }
      print n + 0
      printf "%s", body
    }
  ' "$2"
}

section_scope_extract() {
  local file="$1" heading="$2" scan section heading_hits base nl
  base="$(basename "$file")"
  nl='
'

  scan="$(_section_scope_scan "$heading" "$file")"
  case "$scan" in
    *"$nl"*)
      heading_hits="${scan%%"$nl"*}"
      section="${scan#*"$nl"}"
      ;;
    *)
      heading_hits="$scan"
      section=""
      ;;
  esac
  case "$heading_hits" in
    ''|*[!0-9]*)
      echo "節 '$heading' は検査不能です（見出し数を数えられません。${base}）"
      return 1
      ;;
  esac
  if [ "$heading_hits" -ne 1 ]; then
    echo "節 '$heading' の見出しが ${heading_hits} 本あります（1 本であること。${base}）"
    return 1
  fi

  if [ -z "$section" ]; then
    echo "節 '$heading' が空です（${base}）"
    return 1
  fi

  printf '%s' "$section"
}

section_scope_contains() {
  local file="$1" heading="$2" needle="$3" section base
  base="$(basename "$file")"

  if ! section="$(section_scope_extract "$file" "$heading")"; then
    echo "$section"
    return 1
  fi

  case "$section" in
    *"$needle"*) return 0 ;;
    *)
      echo "節 '$heading' に '$needle' がありません（${base}）"
      return 1
      ;;
  esac
}
