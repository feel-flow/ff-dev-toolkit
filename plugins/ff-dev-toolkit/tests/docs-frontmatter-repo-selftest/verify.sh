#!/usr/bin/env bash
#
# docs-frontmatter-repo/verify.sh 自身の検出力検証（Issue #513）。
#
# fixture を mktemp に組み立て、FF_DOCS_REPO_ROOT で本体を駆動して以下を実測する:
#   G1.  実リポジトリの docs/ をそのまま写した baseline が緑
#   G2.  1 文書の Frontmatter を丸ごと除去 → 赤
#   G3.  必須フィールド（owner）を 1 つ除去 → 赤
#   G4.  version を SemVer 以外（"1.0"）へ → 赤
#   G5.  status を値域外（"published"）へ → 赤
#   G6.  changeImpact を大文字（"LOW"）へ → 赤
#   G7.  `## Changelog` 見出しを除去 → 赤
#   G8.  Frontmatter の閉じ `---` を除去 → 赤
#   G9.  実体側にだけ新しい仕様文書を追加（MASTER の索引は未更新）→ 赤（drift 検出。
#        **これが #513 の本来の目的** — Frontmatter 無しの文書を足しても気付かない穴）
#   G10. 規則側にだけリンクを追加（実体は無い）→ 赤（drift 検出）
#   G11. §関連ドキュメント の見出しを壊す → 赤。ただし赤くなる経路は**集合不一致**で
#        あって「規則側が 0 件」ではない — `ff_docs_rule_targets` は MASTER.md 自身と
#        ACE Playbook 索引行を別経路で必ず出すため、docs 側のどんな変異でも規則側は
#        0 件にならない。規則側 0 件の fail-closed 分岐（`1 件も抽出できません`）は
#        fixture から到達不能で、ここでは測っていない（除外側の同型分岐は G12 が実際に踏む）
#   G12. §Frontmatter 付与しない表を壊して除外抽出を空振りさせる → 赤（fail-closed）
#   G13. 除外対象（08-knowledge/playbook/ 配下）に Frontmatter 無しの文書を足す → 緑
#        （除外規則が効いていることの確認。ここが赤になると規則が広すぎる）
#   G14. docs/MASTER.md が無いツリー → 行頭 `○ skip` を出して緑（検査対象不在）
#   G15. changeImpact の引用符が片側だけ → 赤（YAML として不正）
#   G16. changeImpact が引用符なし → 緑（PLAYBOOK.md の実形式なので受理する）
#   G17. 本物の `## Changelog` を消しフェンス内に例示だけ残す → 赤
#   G18. 書き込み不可の TMPDIR でも完走する（here-doc を使っていないこと）
#   G19. コメント内のフェンス開始が外側のフェンスと対にならない → 緑
#   G20. 未閉鎖の開始マーカーの後ろにある「閉じた span」も除外される → 赤
#   G21. 行内コメントはコメントされた文字だけを消す → 緑
#   G22. version キーの重複（有効 + 無効）→ 赤（YAML として不正・実効値がパーサ依存）
#   G23. status キーの重複（無効を先に置く）→ 赤
#   G24. version の先頭ゼロ（`01.0.0`）→ 赤 / G25. `0.0.0` → 緑
#   G26. 未閉鎖コメントが後続の本物の `## Changelog` を消さない → 緑（契約の固定）
#   G27. Frontmatter 内の `## Changelog`（YAML コメントとして成立する）を実在節と
#        数えない → 赤
#   G28. status が review / approved / deprecated → いずれも緑（値域の正常系。
#        baseline は全 draft なので、値域が 3 値へ戻っても他のケースでは気付けない）
#   G29〜G30. updated の形式違反（ゼロ埋めなし / 月 13）→ 赤
#   G31. updated が created より前 → 赤
#   G32〜G34. 重複キーの正規化（コロン前の空白 / 二重引用符キー / 任意フィールド）→ 赤
#   G35. 重複キー（単一引用符付きキー）→ 赤
#   G36. created と updated が同日 → 緑（前後関係の検査が等号を弾かないこと）
#
# 変異はすべて ASCII 行への perl / ファイル操作で行う（多バイト文字クラス不使用）。
# 書き込み不可の環境（read-only チェックアウト等）では skip して成功扱いにする。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TESTS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_ROOT="$(cd "$TESTS_DIR/../../.." && pwd)"
TARGET="$TESTS_DIR/docs-frontmatter-repo/verify.sh"

[ -f "$TARGET" ] || { echo "✗ docs-frontmatter-repo/verify.sh が見つかりません: $TARGET" >&2; exit 1; }
[ -f "$REPO_ROOT/docs/MASTER.md" ] || {
  echo "○ skip: $REPO_ROOT/docs/MASTER.md が無いためスキップ（fixture の元になる docs/ が必要）"
  exit 0
}

command -v perl >/dev/null 2>&1 || {
  echo "○ skip: perl が無い環境のためスキップ（変異注入に必要）"
  exit 0
}

if _ff_mktemp_out="$(mktemp -d 2>&1)"; then
  TMP="$_ff_mktemp_out"
else
  echo "○ skip: 一時ディレクトリを作成できない環境（read-only）のためスキップ"
  printf '  mktemp: %s\n' "$_ff_mktemp_out"
  exit 0
fi
FF_REACHED_END=0
_ff_exit_guard() {
  _ff_rc=$?
  rm -rf "$TMP"
  if [ "$_ff_rc" -eq 0 ] && [ "$FF_REACHED_END" -ne 1 ]; then
    echo "✗ selftest が末尾に到達せず終了しました（中断を緑にしない）" >&2
    exit 1
  fi
  exit "$_ff_rc"
}
trap _ff_exit_guard EXIT

PASS=0
FAIL=0
ok()  { echo "  ✓ $1"; PASS=$((PASS + 1)); }
bad() { echo "  ✗ $1" >&2; FAIL=$((FAIL + 1)); }

# fixture を（再）構築する。実リポジトリの docs/ をそのまま写すので baseline が
# 実体と乖離しない（一覧をここに書かない = 対象が増えても追随不要）。
make_fixture() {
  rm -rf "$TMP/root"
  mkdir -p "$TMP/root"
  cp -R "$REPO_ROOT/docs" "$TMP/root/docs"
}

# $1=ケース名 $2=期待（green / red）$3=赤のとき出力に必要な理由（ERE、省略可）
#
# 第 3 引数を渡すと「非 0 で終わった」だけでなく**狙った検査で赤くなったか**まで見る。
# 変異が別の検査を偶発的に壊したケースを検出力ありと数えないため（レビュー指摘）。
run_case() {
  local name="$1" expect="$2" why="${3:-}" rc=0
  FF_DOCS_REPO_ROOT="$TMP/root" bash "$TARGET" > "$TMP/out.log" 2>&1 || rc=$?
  if [ "$expect" = "green" ]; then
    if [ "$rc" -eq 0 ]; then
      ok "$name: 緑（期待どおり）"
    else
      bad "$name: 緑を期待しましたが rc=${rc} で赤でした"
      sed 's/^/    /' "$TMP/out.log" | tail -10 >&2
    fi
    return
  fi
  if [ "$rc" -eq 0 ]; then
    bad "$name: 赤を期待しましたが緑のまま通りました（検出力なし）"
    sed 's/^/    /' "$TMP/out.log" | tail -10 >&2
  elif [ -n "$why" ] && ! grep -qE "$why" "$TMP/out.log"; then
    bad "$name: 赤になりましたが理由が違います（期待: ${why}）"
    sed 's/^/    /' "$TMP/out.log" | grep '✗' | head -6 >&2
  else
    ok "$name: 赤（期待どおり）"
  fi
}

# 変異が実際に入ったことを確かめる。**赤ケースは理由 ERE が空振りを捕まえる**（変異が
# no-op なら緑のまま = 「検出力なし」で落ちる）が、**緑ケースは何も測らずに緑になる**。
# fixture は原本の写しなので「原本と同一なら変異が入っていない」で判定できる。
assert_mutated() { # $1=docs/ 起点の相対パス $2=ケース名
  if ! cmp -s "$REPO_ROOT/$1" "$TMP/root/$1"; then return 0; fi
  bad "$2: 変異が入っていません（${1} が原本と同一）。対象文書の表現が変わった可能性があります"
  return 1
}

VICTIM="docs/07-project-management/RISKS.md"

echo "== G1. baseline =="
make_fixture
run_case "G1 baseline（実 docs/ の写し）" green

echo "== G2〜G8. Frontmatter / Changelog 構造の変異 =="
make_fixture
perl -0777 -i -pe 's/\A---\n.*?\n---\n//s' "$TMP/root/$VICTIM"
run_case "G2 Frontmatter 丸ごと除去" red "Frontmatter 開始"

make_fixture
perl -i -ne 'print unless /^owner: /' "$TMP/root/$VICTIM"
run_case "G3 必須フィールド（owner）除去" red "欠落または引用符なし: owner"

make_fixture
perl -i -pe 's/^version: "[0-9.]+"$/version: "1.0"/' "$TMP/root/$VICTIM"
run_case "G4 version が SemVer 以外" red "SemVer 形式"

make_fixture
perl -i -pe 's/^status: "[a-z]+"$/status: "published"/' "$TMP/root/$VICTIM"
run_case "G5 status が値域外" red "status が値域"

make_fixture
perl -i -pe 's/^changeImpact: "?[a-z]+"?$/changeImpact: "LOW"/' "$TMP/root/$VICTIM"
run_case "G6 changeImpact が大文字" red "changeImpact が小文字"

make_fixture
perl -i -pe 's/^## Changelog$/## 変更履歴/' "$TMP/root/$VICTIM"
run_case "G7 ## Changelog 見出しの除去" red "Changelog セクションがありません"

make_fixture
perl -i -pe 'if (/^---$/) { $ff_n++; $_ = "-  -\n" if $ff_n == 2 }' "$TMP/root/$VICTIM"
run_case "G8 Frontmatter の閉じ --- を破損" red "Frontmatter が閉じていません"

echo "== G9〜G10. 規則と実体の drift =="
make_fixture
printf '# 新しい仕様文書\n\n本文だけで Frontmatter がない。\n' > "$TMP/root/docs/01-context/STAKEHOLDERS.md"
run_case "G9 実体側にだけ Frontmatter 無しの仕様文書を追加" red "規則と実体が乖離"

make_fixture
perl -i -pe 's|^- \[01-context/CONSTRAINTS\.md\].*$|$&\n- [01-context/NOT_EXIST.md](./01-context/NOT_EXIST.md) - 実体なし|' "$TMP/root/docs/MASTER.md"
run_case "G10 規則側にだけリンクを追加（実体なし）" red "規則と実体が乖離"

echo "== G11〜G12. 抽出の空振り（fail-closed）=="
make_fixture
perl -i -pe 's/^## 関連ドキュメント$/## 関連資料/' "$TMP/root/docs/MASTER.md"
run_case "G11 §関連ドキュメント 見出しの破損" red "規則と実体が乖離"

make_fixture
perl -i -pe 's/^\*\*付与しない（非仕様文書）\*\*:$/付与しない:/' "$TMP/root/docs/MASTER.md"
run_case "G12 付与しない表の見出し破損（除外抽出の空振り）" red "除外パターンを MASTER.md"

echo "== G13. 除外規則が効いていること =="
make_fixture
printf '# 分割ファイル\n\nFrontmatter を持たない ACE 分割ファイル。\n' > "$TMP/root/docs/08-knowledge/playbook/new-category.md"
[ -f "$TMP/root/docs/08-knowledge/playbook/new-category.md" ] \
  || bad "G13: 変異が入っていません（追加したはずのファイルがありません）"
run_case "G13 除外対象に Frontmatter 無しの文書を追加" green

echo "== G15〜G17. レビュー指摘（PR #524）のケース =="
make_fixture
perl -i -pe 's/^changeImpact: "([a-z]+)"$/changeImpact: "$1/' "$TMP/root/$VICTIM"
run_case "G15 changeImpact の引用符が片側だけ" red "changeImpact が小文字"

make_fixture
# 引用符なしは PLAYBOOK.md（ACE スクリプトが書く形式）で実在するため受理する。
# 置換は**現在値に依存させない** — changeImpact は MASTER.md §バージョニングルール が
# 毎回の更新で書き換えを義務づけるフィールドで、値を焼き込むと次の更新で置換が no-op に
# なり、このケースが baseline の複製へ静かに退化する（緑は空振りでも緑）
perl -i -pe 's/^changeImpact: "([a-z]+)"$/changeImpact: $1/' "$TMP/root/$VICTIM"
assert_mutated "$VICTIM" "G16" || true
run_case "G16 changeImpact が引用符なし（両側なしは妥当）" green

make_fixture
# 本物の `## Changelog` を消し、フェンス内に例示だけを残す → 節ありと数えてはいけない
perl -i -pe 's/^## Changelog$/## 変更履歴/' "$TMP/root/$VICTIM"
printf '\n```markdown\n## Changelog\n```\n' >> "$TMP/root/$VICTIM"
run_case "G17 フェンス内の ## Changelog を実在節と数えない" red "Changelog セクションがありません"

echo "== G19〜G21. マスク境界（PR #524 レビュー 2 巡目）のケース =="
# 単一パスで処理していないと、コメント内のフェンス開始が「外側の閉じフェンス」と
# 対になり、間に挟まれた本物の `## Changelog` まで除外される。
make_fixture
perl -i -pe 's/^## Changelog$/<!--\n```markdown\n## sample heading\n-->\n$&/' "$TMP/root/$VICTIM"
printf '\n```\n' >> "$TMP/root/$VICTIM"
run_case "G19 コメント内のフェンスが外側のフェンスと対にならない" green

# 未閉鎖マーカーで走査を打ち切ると、後続の「閉じたフェンス内の例示」が素通りして
# 実在の節と数えられてしまう（本物の見出しを消しても緑になる）。
make_fixture
perl -i -pe 's/^## Changelog$/## Changelog-renamed/' "$TMP/root/$VICTIM"
printf '\n~~~\nunclosed opener (no closing ~~~ below)\n\n```markdown\n## Changelog\n```\n' \
  >> "$TMP/root/$VICTIM"
run_case "G20 未閉鎖マーカーの後ろの閉じた span も除外する" red "Changelog セクションがありません"

# 行全体を消すと、コメントの前に書かれた本文（ここでは見出しそのもの）も走査から落ちる。
make_fixture
perl -i -pe 's/^## Changelog$/$&<!-- note -->/' "$TMP/root/$VICTIM"
run_case "G21 行内コメントはコメント部分だけを消す" green

echo "== G22〜G26. Frontmatter スキーマの厳格化（PR #524 レビュー 3 巡目）=="
# 重複キーは YAML として不正。実効値がパーサ依存（多くは後勝ち）なので、
# 「有効な行が 1 本あれば OK」ではゲートが保証した値と実際の値が食い違う。
make_fixture
perl -i -pe 's/^(version: "[0-9.]+")$/$1\nversion: "invalid"/' "$TMP/root/$VICTIM"
run_case "G22 version キーの重複（有効 + 無効）" red "重複キー"

# 順序を入れ替えても検出する（後勝ち・先勝ちのどちらの解釈でも不正）
make_fixture
perl -i -pe 's/^(status: "[a-z]+")$/status: "published"\n$1/' "$TMP/root/$VICTIM"
run_case "G23 status キーの重複（無効を先に）" red "重複キー"

# SemVer は各要素の先頭ゼロを認めない
make_fixture
perl -i -pe 's/^version: "[0-9.]+"$/version: "01.0.0"/' "$TMP/root/$VICTIM"
run_case "G24 version の先頭ゼロ（01.0.0）" red "SemVer 形式"

make_fixture
perl -i -pe 's/^version: "[0-9.]+"$/version: "0.0.0"/' "$TMP/root/$VICTIM"
assert_mutated "$VICTIM" "G25" || true
run_case "G25 version が 0.0.0（各要素の単独ゼロは妥当）" green

# 未閉鎖 opener の契約: 対応探索を打ち切るだけで、後続本文は走査対象に残す。
# CommonMark の「閉じ忘れコメントは文書末尾まで」と意図的に異なる（閉じ忘れ 1 個で
# 以降の検査が全部消えるのを避ける）。同梱 MCP の maskCommentAt と同じ振る舞い。
make_fixture
perl -i -pe 's/^## Changelog$/<!-- unclosed comment opener\n$&/' "$TMP/root/$VICTIM"
assert_mutated "$VICTIM" "G26" || true
run_case "G26 未閉鎖コメントが後続の本物の ## Changelog を消さない" green

echo "== G27〜G31. レビュー 4 巡目のケース =="
# `## Changelog` は YAML コメントとしても成立するので、Frontmatter 内に 1 行あるだけで
# 本文の節が無くても通ってしまう（探索範囲を Frontmatter の後ろに限る）
make_fixture
perl -i -pe 's/^## Changelog$/## 変更履歴/' "$TMP/root/$VICTIM"
perl -i -pe 's/^(changeImpact: .*)$/$1\n## Changelog/' "$TMP/root/$VICTIM"
run_case "G27 Frontmatter 内の ## Changelog を実在節と数えない" red "Changelog セクションがありません"

# status の正常系。値域が誤って 3 値へ戻っても baseline（全 draft）では気付けない
for _st in review approved deprecated; do
  make_fixture
  perl -i -pe "s/^status: \"[a-z]+\"\$/status: \"${_st}\"/" "$TMP/root/$VICTIM"
  assert_mutated "$VICTIM" "G28 (${_st})" || true
  run_case "G28 status が ${_st}（値域内）" green
done

# 日付の形式と前後関係
make_fixture
perl -i -pe 's/^updated: "[0-9-]+"$/updated: "2026-8-18"/' "$TMP/root/$VICTIM"
run_case "G29 updated がゼロ埋めなし（2026-8-18）" red "updated が YYYY-MM-DD"

make_fixture
perl -i -pe 's/^updated: "[0-9]{4}-[0-9]{2}/updated: "2026-13/' "$TMP/root/$VICTIM"
run_case "G30 updated の月が 13" red "updated が YYYY-MM-DD"

make_fixture
perl -i -pe 's/^updated: "[0-9-]+"$/updated: "2020-01-01"/' "$TMP/root/$VICTIM"
run_case "G31 updated が created より前" red "より前です"

echo "== G32〜G34. 重複キーの正規化（PR #524 レビュー 5 巡目）=="
# `version : "x"`（コロン前の空白）も `"version": "x"`（引用符付きキー）も YAML では
# 同じキー。完全前置だけで数えると取り逃す
make_fixture
perl -i -pe 's/^(version: "[0-9.]+")$/$1\nversion : "invalid"/' "$TMP/root/$VICTIM"
run_case "G32 重複キー（コロン前に空白）" red "重複キー"

make_fixture
perl -i -pe 's/^(version: "[0-9.]+")$/$1\n"version": "invalid"/' "$TMP/root/$VICTIM"
run_case "G33 重複キー（引用符付きキー）" red "重複キー"

# 必須6フィールド以外（MASTER.md §任意フィールド の reviewers / tags 等）も対象
make_fixture
perl -i -pe 's/^(owner: .*)$/$1\nreviewers: "a"\nreviewers: "b"/' "$TMP/root/$VICTIM"
run_case "G34 重複キー（任意フィールド reviewers）" red "重複キー"

echo "== G35〜G36. レビュー 6 巡目のケース =="
# 単一引用符付きキーも YAML では同じキー
make_fixture
perl -i -pe "s/^(version: \"[0-9.]+\")\$/\$1\n'version': \"invalid\"/" "$TMP/root/$VICTIM"
run_case "G35 重複キー（単一引用符付きキー）" red "重複キー"

# created == updated は正常系（前後関係の検査が等号を弾かないこと）。
# 等号は fixture から読んだ created を代入して作る（固定値を書くと created が変わった
# 日に等号が成立せず、別の条件を測るケースへ静かに変わる）
make_fixture
_created="$(awk -F'"' '/^created: /{print $2; exit}' "$TMP/root/$VICTIM")"
perl -i -pe "s/^updated: \"[0-9-]+\"\$/updated: \"${_created}\"/" "$TMP/root/$VICTIM"
assert_mutated "$VICTIM" "G36" || true
run_case "G36 updated と created が同日（${_created}）" green

echo "== G18. 書き込み不可の TMPDIR でも完走する =="
make_fixture
RO_DIR="$TMP/ro"
mkdir -p "$RO_DIR" && chmod 500 "$RO_DIR"
rc=0
TMPDIR="$RO_DIR" FF_DOCS_REPO_ROOT="$TMP/root" bash "$TARGET" > "$TMP/out.log" 2>&1 || rc=$?
chmod 700 "$RO_DIR"
if [ "$rc" -eq 0 ]; then
  ok "G18 書き込み不可の TMPDIR で完走（here-doc を使っていない）"
else
  bad "G18 書き込み不可の TMPDIR で rc=${rc}（here-doc / here-string が一時ファイルを要求している可能性）"
  sed 's/^/    /' "$TMP/out.log" | tail -6 >&2
fi

echo "== G14. 検査対象が無いツリー =="
rm -rf "$TMP/root"
mkdir -p "$TMP/root"
rc=0
FF_DOCS_REPO_ROOT="$TMP/root" bash "$TARGET" > "$TMP/out.log" 2>&1 || rc=$?
if [ "$rc" -eq 0 ] && grep -c '^○ skip' "$TMP/out.log" > "$TMP/skipcount" 2>/dev/null && [ "$(cat "$TMP/skipcount")" -ge 1 ]; then
  ok "G14 docs/MASTER.md が無いツリー: 行頭 ○ skip を出して緑"
else
  bad "G14 docs/MASTER.md が無いツリー: rc=${rc} / skip マーカーを確認できません"
  sed 's/^/    /' "$TMP/out.log" | tail -6 >&2
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
FF_REACHED_END=1
echo "✅ docs-frontmatter-repo-selftest: all checks passed"
