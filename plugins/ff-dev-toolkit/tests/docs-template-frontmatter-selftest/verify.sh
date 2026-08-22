#!/usr/bin/env bash
#
# docs-template-frontmatter/verify.sh 自身の検出力検証（Issue #509）。
#
# fixture を mktemp に組み立て、FF_DOCS_TEMPLATE_ROOT で本体を駆動して以下を実測する:
#   G1. 実リポジトリの docs-template をそのまま写した baseline が緑
#   G2. 1 ファイルの Frontmatter を丸ごと除去 → 赤
#   G3. 必須フィールド（owner）を 1 つ除去 → 赤
#   G4. version を SemVer 以外（"1.0"）へ → 赤
#   G5. status を値域外（"published"）へ → 赤
#   G6. changeImpact を大文字（"LOW"）へ → 赤
#   G7. `## Changelog` 見出しを除去 → 赤
#   G8. 初期セットの 1 ファイルを削除 → 赤
#   G9. SKILL.md のツリーにだけ新ファイルを追記（suite 一覧は未更新） → 赤（drift 検出）
#   G10. Frontmatter の閉じ `---` を除去 → 赤
#   G11. SKILL.md のツリーから .md 名を抽出できない書式破損 → 赤（fail-closed）
#
# Issue #526（共有 lib ff_docs_fm_verdict への統合で入った検査）:
#   G12. 必須キーの重複（有効値 + 無効値） → 赤・理由は「重複キー」
#   G13. 必須キーの重複（無効値を先に置く） → 赤・理由は「重複キー」
#   G14〜G16. SemVer の先頭ゼロ（01.0.0 / 1.02.3 / 1.0.03） → 赤・理由は「SemVer」
#   G17. version が "0.0.0"（各要素の単独ゼロは妥当） → 緑
#   G18. status が `implementing`（docs/specs/ の 6 値はコア文書に適用しない） → 赤
#   G19. created が `"TBD"`（日付プレースホルダー免除は "YYYY-MM-DD" 限定） → 赤
#   G20. 実日付で updated < created → 赤・理由は「より前です」
#   G21. 引用符付きキー（`"version":`）の重複 → 赤・理由は「重複キー」
#   G22. created だけ雛形・updated は実日付（前後比較のスキップ境界） → 緑
#   G23〜G25. status の正当値 review / approved / deprecated → 各々緑
#             （`draft` は初期セット全 20 文書の値なので G1 baseline が測っている）
#   G26. status が `done`（specs 側スキーマの中間状態） → 赤・理由は「status が値域」
#   G27. `## Changelog` を Frontmatter 内へ移動（`#` 始まりは YAML コメントとして
#        成立するため、配置制約が無いと通る） → 赤・理由は「Changelog セクションがありません」
#
# ケース数は EXPECTED_G_CASES で固定する（検査の削除、または追加時の期待値未更新を
# 赤にする。release-required-selftest の EXPECTED_CHECKS と同型）。
#
# 赤ケースは**理由の ERE まで照合する**（run_case の第 3 引数）。変異が別の検査を
# 偶発的に壊したケースを検出力ありと数えないため。緑ケースは assert_mutated で
# 「変異が実際に入ったこと」を測る（no-op なら緑は何も証明しない）。
#
# 変異はすべて ASCII 行への perl / ファイル操作で行う（多バイト文字クラス不使用）。
# 書き込み不可の環境（read-only チェックアウト等）では skip して成功扱いにする。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TESTS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
PLUGIN_ROOT="$(cd "$TESTS_DIR/.." && pwd)"
TARGET="$TESTS_DIR/docs-template-frontmatter/verify.sh"

[ -f "$TARGET" ] || { echo "✗ docs-template-frontmatter/verify.sh が見つかりません: $TARGET" >&2; exit 1; }

command -v perl >/dev/null 2>&1 || {
  echo "○ skip: perl が無い環境のためスキップ（変異注入に必要）"
  exit 0
}

# mktemp の stderr を捨てない（read-only 以外の失敗まで skip に誤帰属させない）。
if _ff_mktemp_out="$(mktemp -d 2>&1)"; then
  TMP="$_ff_mktemp_out"
else
  echo "○ skip: 一時ディレクトリを作成できない環境（read-only）のためスキップ"
  printf '  mktemp: %s\n' "$_ff_mktemp_out"
  exit 0
fi
# 途中死を沈黙させない（rc=0 なのに最後まで到達していない場合を中断として扱う）。
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

# run_case の実行数。末尾で EXPECTED_G_CASES と突き合わせる（検査の削除、または
# 追加時の期待値未更新を赤にする。release-required-selftest の EXPECTED_CHECKS と同型）。
CASES=0
EXPECTED_G_CASES=27

# 初期セット 20 ファイル（本体 suite と同一の一覧）
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

# fixture を（再）構築する。実リポジトリの初期セット 20 件と init-docs SKILL.md を
# そのまま写す（baseline が実体と乖離しない）。
make_fixture() {
  rm -rf "$TMP/root"
  mkdir -p "$TMP/root/skills/init-docs"
  local rel dir
  for rel in "${INITIAL_SET[@]}"; do
    dir="$(dirname "$rel")"
    mkdir -p "$TMP/root/docs-template/$dir"
    cp "$PLUGIN_ROOT/docs-template/$rel" "$TMP/root/docs-template/$rel"
  done
  cp "$PLUGIN_ROOT/skills/init-docs/SKILL.md" "$TMP/root/skills/init-docs/SKILL.md"
}

# $1=ケース名 $2=期待（green / red）$3=赤のとき出力に必要な理由（ERE、省略可）
#
# 第 3 引数を渡すと「非 0 で終わった」だけでなく**狙った検査で赤くなったか**まで見る。
# 変異が別の検査を偶発的に壊したケースを検出力ありと数えないため。
run_case() {
  local name="$1" expect="$2" why="${3:-}" rc=0
  CASES=$((CASES + 1))
  FF_DOCS_TEMPLATE_ROOT="$TMP/root" bash "$TARGET" > "$TMP/out.log" 2>&1 || rc=$?
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
    # 診断行そのものが set -e で死なないようにする（本 PR が検査 B で潰した
    # 「report 分岐へ到達する前に死ぬ」と同型）: ✗ が 0 行なら grep が非 0 を返し、
    # 下流を head にすると 7 行目以降で SIGPIPE + pipefail を踏む。grep はファイル
    # 入力（パイプではない）にし、`|| true` と tail で両方を塞ぐ
    { grep '✗' "$TMP/out.log" || true; } | tail -6 | sed 's/^/    /' >&2
  else
    ok "$name: 赤（期待どおり）"
  fi
}

# 変異が実際に入ったことを確かめる。**赤ケースは理由 ERE が空振りを捕まえる**（変異が
# no-op なら緑のまま = 「検出力なし」で落ちる）が、**緑ケースは何も測らずに緑になる**。
# fixture は原本の写しなので「原本と同一なら変異が入っていない」で判定できる。
assert_mutated() { # $1=docs-template/ 起点の相対パス $2=ケース名
  if ! cmp -s "$PLUGIN_ROOT/docs-template/$1" "$TMP/root/docs-template/$1"; then return 0; fi
  bad "$2: 変異が入っていません（${1} が原本と同一）。対象文書の表現が変わった可能性があります"
  return 1
}

echo "== G1. baseline =="
make_fixture
run_case "G1 実体を写した baseline" green

echo "== G2. Frontmatter 丸ごと除去 =="
make_fixture
close_line="$(awk 'NR > 1 && /^---$/ { print NR; exit }' "$TMP/root/docs-template/02-design/API.md")"
perl -i -ne 'print if $. > '"$close_line" "$TMP/root/docs-template/02-design/API.md"
run_case "G2 API.md の Frontmatter 除去" red "先頭行が Frontmatter 開始"

echo "== G3. 必須フィールド除去 =="
make_fixture
perl -i -ne 'print unless /^owner: /' "$TMP/root/docs-template/06-reference/GLOSSARY.md"
run_case "G3 GLOSSARY.md の owner 除去" red "欠落または引用符なし: owner"

echo "== G4. version 非 SemVer =="
make_fixture
perl -i -pe 's/^version: ".*"$/version: "1.0"/' "$TMP/root/docs-template/07-project-management/RISKS.md"
run_case "G4 RISKS.md の version を 1.0 へ" red "SemVer 形式"

echo "== G5. status 値域外 =="
make_fixture
perl -i -pe 's/^status: ".*"$/status: "published"/' "$TMP/root/docs-template/01-context/CONSTRAINTS.md"
run_case "G5 CONSTRAINTS.md の status を published へ" red "status が値域"

echo "== G6. changeImpact 大文字 =="
make_fixture
perl -i -pe 's/^changeImpact: ".*"$/changeImpact: "LOW"/' "$TMP/root/docs-template/MASTER.md"
run_case "G6 MASTER.md の changeImpact を LOW へ" red "changeImpact が小文字"

echo "== G7. Changelog 見出し除去 =="
make_fixture
perl -i -pe 's/^## Changelog$/## History/' "$TMP/root/docs-template/04-quality/VALIDATION.md"
run_case "G7 VALIDATION.md の ## Changelog 除去" red "Changelog セクションがありません"

echo "== G8. ファイル削除 =="
make_fixture
rm "$TMP/root/docs-template/03-implementation/CONVENTIONS.md"
run_case "G8 CONVENTIONS.md 削除" red "初期セットのファイルが見つかりません"

echo "== G9. SKILL.md ツリーだけに新ファイル追記（drift） =="
make_fixture
# ツリーのフェンス内の MASTER.md 行の直後に ASCII のみの新規行を足す
awk '
  { print }
  /MASTER\.md/ && !done { print "|-- NEWDOC.md"; done = 1 }
' "$TMP/root/skills/init-docs/SKILL.md" > "$TMP/skill.tmp"
mv "$TMP/skill.tmp" "$TMP/root/skills/init-docs/SKILL.md"
run_case "G9 SKILL.md ツリーへ NEWDOC.md 追記" red "ツリーと本 suite の一覧が乖離"

echo "== G10. Frontmatter 未閉鎖 =="
make_fixture
close_line="$(awk 'NR > 1 && /^---$/ { print NR; exit }' "$TMP/root/docs-template/02-design/DATABASE.md")"
perl -i -ne 'print unless $. == '"$close_line" "$TMP/root/docs-template/02-design/DATABASE.md"
run_case "G10 DATABASE.md の閉じ --- 除去" red "Frontmatter が閉じていません"

echo "== G11. ツリー抽出の空振り（fail-closed） =="
make_fixture
# ステップ2 のフェンスを開始直後に閉じ、ツリー本体を抽出不能にする
awk '
  /^### 2\./ { print; step2 = 1; next }
  step2 && /^```/ && !closed { print "```"; print "```"; closed = 1; skipping = 1; next }
  skipping && /^```/ { skipping = 0; next }
  skipping { next }
  { print }
' "$TMP/root/skills/init-docs/SKILL.md" > "$TMP/skill.tmp"
mv "$TMP/skill.tmp" "$TMP/root/skills/init-docs/SKILL.md"
run_case "G11 ツリー抽出 0 件" red "\.md 名を 1 件も抽出できません"

echo "== G12〜G13. 重複キー（Issue #526 AC-1） =="
make_fixture
# 有効な行はそのまま残し、その直後へ無効値の同じキーを足す（「有効な行が 1 本あれば
# OK」の実装はこれを通す。YAML パーサの多くは後勝ちなので実効値は "invalid"）
perl -i -pe 's/^(version: ".*")$/$1\nversion: "invalid"/' "$TMP/root/docs-template/02-design/API.md"
run_case "G12 API.md の version キー重複（有効 + 無効）" red "重複キー"

make_fixture
# 無効値を先に置く（順序を入れ替えても検出することの pin）
perl -i -pe 's/^(status: ".*")$/status: "published"\n$1/' "$TMP/root/docs-template/02-design/DOMAIN.md"
run_case "G13 DOMAIN.md の status キー重複（無効を先に）" red "重複キー"

echo "== G14〜G17. SemVer の先頭ゼロ（Issue #526 AC-2） =="
make_fixture
perl -i -pe 's/^version: ".*"$/version: "01.0.0"/' "$TMP/root/docs-template/04-quality/TESTING.md"
run_case "G14 TESTING.md の version を 01.0.0 へ" red "SemVer 形式"

make_fixture
perl -i -pe 's/^version: ".*"$/version: "1.02.3"/' "$TMP/root/docs-template/04-quality/TESTING.md"
run_case "G15 TESTING.md の version を 1.02.3 へ" red "SemVer 形式"

make_fixture
perl -i -pe 's/^version: ".*"$/version: "1.0.03"/' "$TMP/root/docs-template/04-quality/TESTING.md"
run_case "G16 TESTING.md の version を 1.0.03 へ" red "SemVer 形式"

make_fixture
perl -i -pe 's/^version: ".*"$/version: "0.0.0"/' "$TMP/root/docs-template/04-quality/TESTING.md"
assert_mutated "04-quality/TESTING.md" "G17" || true
run_case "G17 TESTING.md の version を 0.0.0 へ（単独ゼロは妥当）" green

echo "== G18. status 値域は 4 値（docs/specs/ の 6 値を混ぜない。Issue #526 AC-3） =="
make_fixture
perl -i -pe 's/^status: ".*"$/status: "implementing"/' "$TMP/root/docs-template/06-reference/DECISIONS.md"
run_case "G18 DECISIONS.md の status を implementing へ" red "status が値域"

echo "== G19〜G20. 日付プレースホルダー免除の境界 =="
make_fixture
# 免除するのは "YYYY-MM-DD" の完全一致だけ。他の未記入表現は通さない
perl -i -pe 's/^created: ".*"$/created: "TBD"/' "$TMP/root/docs-template/07-project-management/TASKS.md"
run_case "G19 TASKS.md の created を TBD へ" red "created が YYYY-MM-DD"

make_fixture
# 実日付が入っている文書では前後関係の検査が効く（プレースホルダー免除で無効化されない）
perl -i -pe 's/^created: ".*"$/created: "2026-01-02"/; s/^updated: ".*"$/updated: "2026-01-01"/' \
  "$TMP/root/docs-template/05-operations/DEPLOYMENT.md"
run_case "G20 DEPLOYMENT.md の updated が created より前" red "より前です"

echo "== G23〜G26. status 値域の全境界（正当 4 値 / 中間状態 2 値） =="
# `draft` は初期セット 20 文書すべてがその値なので G1 baseline が緑を測っている。
# 残る 3 値と、混ぜてはいけない中間状態 2 値をここで個別に固定する。
make_fixture
perl -i -pe 's/^status: ".*"$/status: "review"/' "$TMP/root/docs-template/01-context/PROJECT.md"
assert_mutated "01-context/PROJECT.md" "G23" || true
run_case "G23 PROJECT.md の status を review へ（正当値）" green

make_fixture
perl -i -pe 's/^status: ".*"$/status: "approved"/' "$TMP/root/docs-template/02-design/ARCHITECTURE.md"
assert_mutated "02-design/ARCHITECTURE.md" "G24" || true
run_case "G24 ARCHITECTURE.md の status を approved へ（正当値）" green

make_fixture
perl -i -pe 's/^status: ".*"$/status: "deprecated"/' "$TMP/root/docs-template/03-implementation/PATTERNS.md"
assert_mutated "03-implementation/PATTERNS.md" "G25" || true
run_case "G25 PATTERNS.md の status を deprecated へ（終端状態も正当値）" green

make_fixture
# `done` は `docs/specs/` の Spec Kit スキーマ側の値。コア文書の値域には無い
perl -i -pe 's/^status: ".*"$/status: "done"/' "$TMP/root/docs-template/03-implementation/FALLBACK.md"
run_case "G26 FALLBACK.md の status を done へ" red "status が値域"

echo "== G27. ## Changelog が Frontmatter 内（配置制約） =="
make_fixture
# 本物の節を潰し、`## Changelog` を Frontmatter の中へ置く。`#` 始まりは YAML の
# コメントとして成立するので、配置制約（Frontmatter より後ろ）が無いとこれで通る
perl -i -pe 's/^## Changelog$/## History/; s/^(title: ".*")$/$1\n## Changelog/' \
  "$TMP/root/docs-template/02-design/API.md"
run_case "G27 API.md の ## Changelog を Frontmatter 内へ移動" red "Changelog セクションがありません"

echo "== G21. 引用符付きキーの重複（キー名の正規化） =="
make_fixture
# `"version":` は YAML として `version:` と同じキー。完全前置の一致だけで数える実装は
# これを取り逃す（lib 側の正規化が効いていることの pin）
perl -i -pe 's/^(version: ".*")$/$1\n"version": "9.9.9"/' "$TMP/root/docs-template/06-reference/GLOSSARY.md"
run_case "G21 GLOSSARY.md の version キー重複（引用符付きキー）" red "重複キー"

echo "== G22. 片側だけプレースホルダー（前後比較のスキップ境界） =="
make_fixture
# created が雛形のまま・updated だけ実日付は docs-template の通常形。辞書順では
# "2026-.." < "YYYY-.." なので、免除を比較へも効かせないと偽陽性で赤くなる
perl -i -pe 's/^updated: ".*"$/updated: "2026-08-21"/' "$TMP/root/docs-template/07-project-management/ROADMAP.md"
assert_mutated "07-project-management/ROADMAP.md" "G22" || true
run_case "G22 ROADMAP.md の created のみ雛形・updated は実日付" green

echo "== 検査総数ガード =="
if [ "$CASES" -eq "$EXPECTED_G_CASES" ]; then
  ok "検査総数ガード: ${CASES} 件実行（期待どおり）"
else
  bad "検査総数ガード: ${CASES} 件実行（期待 ${EXPECTED_G_CASES} 件）— ケースの削除、または追加時の期待値未更新"
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
echo "✅ docs-template-frontmatter-selftest: all checks passed"
FF_REACHED_END=1
