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
#
# 契約:
#   - 見出しの一致本数が 1 本でなければ fail-closed。0 本 = 節が無い、2 本以上 =
#     要件が複数の節へ散った状態。どちらも「先頭 1 本だけ見て緑」にしない。
#   - 節は見出し行の次行から、次の見出し行（行頭 `#` + 空白）の直前まで。下位見出しの
#     小節は節に含めない（含めると、要件が小節へ移動した退行を拾えなくなる）。
#     小節へ移った needle は「節に無い」で赤くなる = fail-closed。
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
#     * 順序検査（行番号の前後比較）
#     * 文書全体の禁止パターン検査（not_contains / lacks 型。節を切ると
#       「切った節の外なら書いてよい」に意味が変わる）
#
# 既知の制約: 字下げされていないコードフェンス内の `#` 行でも節が終端する。該当する
# 文書では節が途中で切れて needle が見つからず**赤くなる**（緑のまま見逃すことは
# ない）ので、移行時に気付ける。移行前に対象節の範囲を実測すること。
#
# 本ファイルは source される前提（実行ビット不要）。bash 3.2 互換。
# 補足: 行頭が `# shellcheck …` の形をした散文コメントは shellcheck にディレクティブ
# として解釈され、そのファイルの静的検査が丸ごと止まる（Issue #530）。この注記の
# 書き出しを変えないこと。

section_scope_contains() {
  local file="$1" heading="$2" needle="$3" section heading_hits base
  base="$(basename "$file")"

  heading_hits="$(awk -v h="$heading" 'index($(0), h) == 1 { n++ } END { print n + 0 }' "$file")"
  if [ -z "$heading_hits" ]; then
    echo "節 '$heading' は検査不能です（見出し数を数えられません。${base}）"
    return 1
  fi
  if [ "$heading_hits" -ne 1 ]; then
    echo "節 '$heading' の見出しが ${heading_hits} 本あります（1 本であること。${base}）"
    return 1
  fi

  section="$(awk -v h="$heading" '
    index($(0), h) == 1 { inside = 1; next }
    inside && /^#+ / { inside = 0 }
    inside { print }
  ' "$file")"
  if [ -z "$section" ]; then
    echo "節 '$heading' が空です（${base}）"
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
