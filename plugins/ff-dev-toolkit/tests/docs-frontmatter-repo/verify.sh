#!/usr/bin/env bash
#
# 対象プロジェクトの docs/ 側 Frontmatter 付与規則の回帰ゲート（Issue #513）。
#
# #511 で自リポジトリ docs/ の仕様文書へ Frontmatter を付与し、付与対象 / 対象外の
# 線引きを docs/MASTER.md §文書運用ルール §Frontmatter に明文化した。しかしこの規則を
# 機械的に守るゲートが無く、**新しい仕様文書を Frontmatter 無しで追加しても誰も
# 気付かない**。/validate-docs の Frontmatter スキーマチェックは「Frontmatter を持つ
# 場合のみ検証する」オプトイン設計なので、無い文書は「違反ゼロ」ではなく「検証対象外」
# として静かに緑になる（#509 以前と同じ穴）。
#
# テンプレート側の同型ゲートは tests/docs-template-frontmatter/（#509 / PR #510）。
# 構造検査の実装は tests/lib/docs-scan.sh に共有し、両者で同じ契約を使う。
#
# 検査:
#   A. 規則側の対象一覧（MASTER.md §関連ドキュメント のリンク + MASTER 自身 +
#      §Frontmatter 付与対象表の ACE Playbook 索引）を導出できる（空振り = 赤）
#   B. 実体側の対象一覧（docs/**/*.md − §Frontmatter 付与しない表の除外パターン）を
#      導出できる（空振り = 赤）
#   C. A と B が集合として一致する（片側だけ増減 = 赤。規則と実体の drift 検出）
#   D. 対象の各文書が Frontmatter 必須6フィールド・SemVer・status 値域・
#      changeImpact の小文字値域・`## Changelog` を満たす
#   E. version を bump した文書の bump 幅（major / minor / patch）と changeImpact が
#      MASTER.md §バージョニングルール の対応表と一致する（Issue #902）
#
# E の設計判断（Issue #902）:
#   - **新 suite を作らず本 suite へ統合する。** 対象文書の集合（B で導出したもの）も
#     Frontmatter の読み方も同じで、分けると走査と除外規則が二重管理になる
#   - **比較 base は merge-base(origin/HEAD の指す既定ブランチ, HEAD)。** PR 単位の
#     bump 幅を見るため。`HEAD~1` だと、複数コミットの PR で version bump と
#     changeImpact 更新が別コミットに割れたとき片方だけを見て誤判定する。既定ブランチは
#     `origin/HEAD` から導出する（scripts/check-version-claims.sh と同じ解決方法）。
#     ref を解決できない / merge-base が取れない checkout では **この検査だけ**を
#     インデント付き `○ skip` で飛ばす（run-all.sh ヘッダーの部分 skip 契約）。
#     base 側に文書が無い（初版）・version 据え置きはどちらも緑
#   - **対応表は MASTER.md から導出し、ここに複製しない。** 3 幅すべてを相異なる
#     changeImpact とともに導出できなければ赤にする（導出元の消失を緑にしない）
#   - **比較 base の鮮度は本 suite の前提条件（fetch はしない）。** 比較 base は local の
#     `origin/<default>` で、suite にネットワークを持ち込まない。鮮度は git-workflow の
#     「検証・レビュー前の base 追随確認」が担う。stale なら bump 幅が実際と違って見える
#     （偽 green / 偽 red のどちらも起こり得る）
#
# **件数も対象名もこのファイルに書かない。** 両側を導出して比較するのが目的なので、
# ここに一覧を持つと最初に腐る（skill-count-consistency と同じ方針）。
#
# docs/MASTER.md が無いチェックアウト（公開リポジトリ側など）では行頭 `○ skip` を
# 出して exit 0 する。検査対象そのものが存在しないため。
#
# FF_DOCS_REPO_ROOT で対象リポジトリのルートを差し替えられる（selftest 用）。

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DEFAULT_ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"
ROOT="${FF_DOCS_REPO_ROOT:-$DEFAULT_ROOT}"

# shellcheck source=../lib/docs-scan.sh
. "$SCRIPT_DIR/../lib/docs-scan.sh"

DOCS_ROOT="$ROOT/docs"
MASTER="$DOCS_ROOT/MASTER.md"

if [ ! -f "$MASTER" ]; then
  echo "○ skip: $MASTER が無いためスキップ（本 suite の検査は1件も実行されていません。docs/ を持つリポジトリで実行してください）"
  exit 0
fi

PASS=0
FAIL=0
ok()  { echo "  ✓ $1"; PASS=$((PASS + 1)); }
bad() { echo "  ✗ $1" >&2; FAIL=$((FAIL + 1)); }

# --- E（Issue #902）で使う小道具 ---------------------------------------------
# Frontmatter から 1 フィールドの値を読む（stdin。閉じ行より前の最初の 1 件）。
# 重複キーは D が先に赤にするので、ここは先勝ちで足りる。
ff_fm_field() {
  # 途中で exit しない — stdin がパイプのとき上流を SIGPIPE で殺し、
  # pipefail のもとでコマンド置換全体が失敗する（D の Changelog 判定と同じ罠）。
  awk -v key="$1" '
    NR == 1 { if ($0 != "---") no_fm = 1; next }
    no_fm || closed { next }
    $0 == "---" { closed = 1; next }
    !got && index($0, key ":") == 1 {
      v = substr($0, length(key) + 2)
      gsub(/^[ \t]+|[ \t]+$/, "", v)
      gsub(/^["\047]|["\047]$/, "", v)
      got = 1
    }
    END { if (!no_fm && got) print v }
  '
}

# old → new の bump 幅を major / minor / patch で返す。
# 据え置き・後退・非 SemVer では何も出さない（呼び出し側が fail-closed に扱う）。
ff_bump_width() {
  awk -v o="$1" -v n="$2" '
    BEGIN {
      if (split(o, a, ".") != 3 || split(n, b, ".") != 3) exit
      for (i = 1; i <= 3; i++) if (a[i] !~ /^[0-9]+$/ || b[i] !~ /^[0-9]+$/) exit
      if (b[1] + 0 > a[1] + 0) { print "major"; exit }
      if (b[1] + 0 < a[1] + 0) exit
      if (b[2] + 0 > a[2] + 0) { print "minor"; exit }
      if (b[2] + 0 < a[2] + 0) exit
      if (b[3] + 0 > a[3] + 0) { print "patch" }
    }
  ' < /dev/null
}

echo "== A. 規則側の対象一覧を MASTER.md から導出 =="
RULE_LIST="$(ff_docs_rule_targets "$MASTER" || true)"
rule_n=0
[ -z "$RULE_LIST" ] || rule_n="$(printf '%s\n' "$RULE_LIST" | wc -l | tr -d ' ')"
if [ "$rule_n" -eq 0 ]; then
  bad "MASTER.md から対象一覧を 1 件も抽出できません（抽出の空振りを緑にしない）"
else
  ok "規則側 ${rule_n} 件を導出"
fi

echo "== B. 実体側の対象一覧を docs/ から導出 =="
if ! ACTUAL_LIST="$(ff_docs_actual_targets "$DOCS_ROOT" "$MASTER")"; then
  bad "除外パターンを MASTER.md §Frontmatter 付与しない表から抽出できません（fail-closed）"
  ACTUAL_LIST=""
fi
actual_n=0
[ -z "$ACTUAL_LIST" ] || actual_n="$(printf '%s\n' "$ACTUAL_LIST" | wc -l | tr -d ' ')"
if [ "$actual_n" -eq 0 ]; then
  bad "docs/ から対象ファイルを 1 件も抽出できません（抽出の空振りを緑にしない）"
else
  ok "実体側 ${actual_n} 件を導出"
fi

echo "== C. 規則側と実体側の集合一致 =="
if [ "$rule_n" -gt 0 ] && [ "$actual_n" -gt 0 ]; then
  if [ "$RULE_LIST" = "$ACTUAL_LIST" ]; then
    ok "規則（MASTER.md）と実体（docs/）が一致（${rule_n} 件）"
  else
    bad "規則と実体が乖離しています（MASTER.md か docs/ の更新漏れ）"
    echo "  --- 規則側にのみ存在（実体が無いのに索引に載っている）:" >&2
    LC_ALL=C comm -23 <(printf '%s\n' "$RULE_LIST") <(printf '%s\n' "$ACTUAL_LIST") | sed 's/^/    /' >&2
    echo "  --- 実体側にのみ存在（Frontmatter 規則の適用対象なのに MASTER.md に載っていない）:" >&2
    LC_ALL=C comm -13 <(printf '%s\n' "$RULE_LIST") <(printf '%s\n' "$ACTUAL_LIST") | sed 's/^/    /' >&2
  fi
fi

echo "== D. 各文書の Frontmatter / Changelog 構造 =="
if [ "$actual_n" -eq 0 ]; then
  bad "対象が 0 件のため構造検査を実行できません"
else
  # 実体側を対象にする（C が赤でも個々の文書の構造は検査したい）
  while IFS= read -r rel; do
    [ -n "$rel" ] || continue
    verdict="$(ff_docs_fm_verdict "$DOCS_ROOT/$rel")"
    case "$verdict" in
      OK) ok "$rel: Frontmatter / Changelog 構造 OK" ;;
      NG:*) bad "$rel: ${verdict#NG:}" ;;
      *) bad "$rel: 判定関数が想定外の値を返しました: $verdict" ;;
    esac
  done < <(printf '%s\n' "$ACTUAL_LIST")
fi

echo "== E. version bump 幅と changeImpact の対応 =="
# 対応表は MASTER.md §バージョニングルール から導出する（ここに複製しない）。
# 表の各行は「| <changeImpact> | <基準> | <バージョン更新> |」で、3 列目にだけ
# パッチ / マイナー / メジャー が現れる。節の終わりは次の見出し行。
MAP="$(awk '
  /^### バージョニングルール$/ { in_sec = 1; next }
  in_sec && /^#/ { in_sec = 0 }
  in_sec && /^\|/ {
    if (split($0, c, "|") < 4) next
    impact = c[2]; bump = c[4]
    gsub(/^[ \t]+|[ \t]+$/, "", impact)
    gsub(/^[ \t]+|[ \t]+$/, "", bump)
    if (impact !~ /^(low|medium|high)$/) next
    w = ""
    if (index(bump, "パッチ") > 0) w = "patch"
    else if (index(bump, "マイナー") > 0) w = "minor"
    else if (index(bump, "メジャー") > 0) w = "major"
    if (w != "") print w " " impact
  }
' "$MASTER" | LC_ALL=C sort)"
map_ok=0
if [ -n "$MAP" ]; then
  map_ok="$(printf '%s\n' "$MAP" | awk '
    { w[$1]++; i[$2]++; n++ }
    END {
      print (n == 3 && w["patch"] == 1 && w["minor"] == 1 && w["major"] == 1 \
             && i["low"] == 1 && i["medium"] == 1 && i["high"] == 1) ? 1 : 0
    }
  ')"
fi
if [ "$map_ok" != "1" ]; then
  bad "MASTER.md §バージョニングルール から bump 幅と changeImpact の対応を 3 組（major/minor/patch と low/medium/high の 1 対 1）導出できません（導出元の消失を緑にしない）"
elif [ "$actual_n" -eq 0 ]; then
  bad "対象が 0 件のため bump 幅の照合を実行できません"
else
  ok "対応表を MASTER.md から 3 組導出"
  # 比較 base は merge-base(既定ブランチ, HEAD)。PR 単位の bump 幅を見るため
  # （HEAD~1 だと bump と changeImpact 更新が別コミットに割れた PR で誤判定する）。
  # fetch はしない（suite にネットワークを持ち込まない）。local の origin ref が stale だと
  # bump 幅が実際と違って見える — 鮮度は git-workflow の base 追随確認が担う（先頭コメント参照）。
  e_skip=""
  doc_prefix=""
  default_ref=""
  base_commit=""
  if ! doc_prefix="$(git -C "$DOCS_ROOT" rev-parse --show-prefix 2>/dev/null)"; then
    e_skip="docs/ が git 管理下にありません"
  elif ! default_ref="$(git -C "$DOCS_ROOT" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null)"; then
    e_skip="origin/HEAD を解決できず比較 base の既定ブランチを特定できません"
  elif ! base_commit="$(git -C "$DOCS_ROOT" merge-base "$default_ref" HEAD 2>/dev/null)"; then
    e_skip="${default_ref} と HEAD の merge-base を取得できません"
  fi
  if [ -n "$e_skip" ]; then
    echo "  ○ skip: bump 幅の照合を飛ばしました（${e_skip}）"
  else
    e_changed=0
    e_unreadable=0
    while IFS= read -r rel; do
      [ -n "$rel" ] || continue
      old_blob=""
      # base 側に文書が無い（初版）なら照合対象外 = 緑。
      # 「在るのに読めない」は検査不能なので赤にする（初版と同じ緑へ倒さない）。
      git -C "$DOCS_ROOT" cat-file -e "${base_commit}:${doc_prefix}${rel}" 2>/dev/null || continue
      if ! old_blob="$(git -C "$DOCS_ROOT" show "${base_commit}:${doc_prefix}${rel}" 2>/dev/null)"; then
        bad "$rel: base（${base_commit}）側に文書が在りますが blob を読み取れません（検査不能）"
        e_unreadable=$((e_unreadable + 1))
        continue
      fi
      old_ver="$(printf '%s\n' "$old_blob" | ff_fm_field version)"
      # base 側に version が無い（この PR で Frontmatter を付けた）も照合対象外
      [ -n "$old_ver" ] || continue
      new_ver="$(ff_fm_field version < "$DOCS_ROOT/$rel")"
      [ "$old_ver" != "$new_ver" ] || continue
      e_changed=$((e_changed + 1))
      width="$(ff_bump_width "$old_ver" "$new_ver")"
      if [ -z "$width" ]; then
        bad "$rel: version が ${old_ver} から ${new_ver} へ変わっていますが bump 幅を判定できません（後退または非 SemVer）"
        continue
      fi
      # ff_fm_field の注記と同じ理由でパイプ上では exit しない（上流を SIGPIPE で殺さない）。
      want="$(printf '%s\n' "$MAP" | awk -v w="$width" '$1 == w && !seen { print $2; seen = 1 }')"
      ci="$(ff_fm_field changeImpact < "$DOCS_ROOT/$rel")"
      if [ -z "$ci" ]; then
        bad "$rel: bump 幅=${width}（${old_ver} → ${new_ver}）changeImpact 未設定 — MASTER.md の対応は ${want}"
      elif [ "$ci" != "$want" ]; then
        bad "$rel: bump 幅=${width}（${old_ver} → ${new_ver}）changeImpact=${ci} — MASTER.md の対応は ${want}"
      else
        ok "$rel: bump 幅=${width}（${old_ver} → ${new_ver}）と changeImpact=${ci} が対応"
      fi
    done < <(printf '%s\n' "$ACTUAL_LIST")
    # 読めなかった文書がある間は「変更なし」と言い切れない（赤の横に緑を並べない）。
    if [ "$e_changed" -eq 0 ] && [ "$e_unreadable" -eq 0 ]; then
      ok "比較 base（${default_ref} との merge-base）から version を変更した文書はありません"
    fi
  fi
fi

echo ""
echo "結果: pass=${PASS} fail=${FAIL}"
if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
if [ "$PASS" -eq 0 ]; then
  echo "✗ 検査が 1 件も成立していません" >&2
  exit 1
fi
echo "✅ docs-frontmatter-repo: all checks passed"
