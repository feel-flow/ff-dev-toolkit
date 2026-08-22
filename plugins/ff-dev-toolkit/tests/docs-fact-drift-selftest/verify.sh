#!/usr/bin/env bash
#
# docs-fact-drift/verify.sh 自身の検出力検証（Issue #519）。
#
# fixture を mktemp に組み立て、FF_DOCS_REPO_ROOT で本体を駆動して以下を実測する:
#   G1. 実リポジトリの写しが baseline として緑
#   G2. docs 側の suite 数を 1 つずらす → 赤（記載 ≠ 実体）
#   G3. docs 側のプラグイン数をずらす → 赤
#   G4. docs 側の総スキル数（計 N スキル）をずらす → 赤
#   G5. docs 側の ACE refine 目安をずらす → 赤
#   G6. 実体側（marketplace.json）のプラグインを 1 件増やす → 赤（逆方向の drift）
#   G7. 正準表現に一致する記載を docs から全部消す → 赤（抽出の空振りを緑にしない）
#   G8. 導出元（check-category-size.ts の定数名）を壊す → 赤（fail-closed）
#   G9. ACE 分割ファイル（08-knowledge/playbook/**）に不一致の数値を書く → 緑
#       （追記型の歴史記録は対象外。ここが赤になると走査範囲が広すぎる）
#   G10. Changelog 節に不一致の数値を書く → 緑（その時点の記録なので対象外）
#   G12. 行内コメント付きの記載（`N suite <!-- note -->`）も走査対象 → 赤
#        （行全体を消すと、記載のある行が走査から落ちてドリフトを見逃す）
#   G13. 未検査 claim（総スキル数の第 2 形式 / ff スキル数 / MCP ツール数 / 初期セット
#        件数 / ACE ブロック上限 / エントリ行数 / 昇格 Helpful）を 1 件ずつずらす → 赤
#   G14〜G16. claim の narrowing（`後続 N suite` / spec-docs 無しの `N ツール` /
#        `昇格` 無しの `Helpful >= N`）は照合しない → 緑
#   G22. `調査時点` を含む歴史スナップショット行（DECISIONS.md ADR-024）は照合しない → 緑
#   G17. 未閉鎖コメント開始行に書いた件数も走査対象 → 赤（契約の固定）
#   G18. 散文中の `` `<!--` ``（インラインコードスパン内）は後続の `-->`（mermaid の
#        矢印を含む）と対にならず、間の件数記載も走査される → 赤（Issue #527）。
#        G18b は同じ挿入をマーカー無しで行っても赤になることを見て、G18 の赤が
#        「マーカーの有無に関係なく赤」= 判別力ゼロではないことの対照になる
#        （G26 がマスク出力を直接見て、マーカー行が保持されることを固定する）
#   G26. ff_docs_mask_spans をマスク出力で直接検査する（Issue #527 AC-1）: 対になった
#        コードスパン内の `<!--` は開始として扱わず、後続のフェンス（mermaid）だけが
#        マスクされる。コードスパン外の `<!--` は従来どおり開始として扱う。
#        最終行は合成ケース（1 行に複数 span + 実コメント同居。実コメント除去後の
#        同一行再検査で、引用のマーカーが開始にならないこと）
#   G27. CRLF 改行でも閉じたフェンスをマスクする（Issue #527 AC-3）。awk は RS="\n" で
#        読むため行末に \r が残り、`[ \t]*$` の閉じ判定だけが CRLF で空振りしていた
#        （`/\r?\n/` で分割する同梱 MCP 側とは結果が食い違う非対称）
#   G19. 導出元（`tests/` / `skills/`）を削除 → 赤、しかも理由が「導出できません」で
#        あること。`find | wc -l` は 0 を出すため、0 を実体値として受理すると導出元の
#        消失が「実体は 0 件」に化ける（終了コードだけでは区別できない = 実測で確認）
#   G20. 書き込み不可の TMPDIR でも完走し、claim の照合まで実行される
#   G21. 実体側にスキル / suite / MCP ツールを 1 件足す → 赤（Issue #519 AC-2。
#        docs 側をずらす変異と対になる逆方向で、運用上いちばん起こる形）
#   G23. 図（フェンス内）に手書きした件数をずらす → 赤（Issue #525。```text の構成図と
#        ```mermaid の依存図の両方。claim の走査はフェンスの中身を含む =
#        ff_docs_claim_body。ここが緑のままだと図の件数が静かにドリフトする）
#   G24. フェンス内に例示した `## Changelog` で claim 走査が打ち切られないこと → 赤
#        （Changelog 境界の判定はフェンスを消したマスクで行う。生テキストの見出し検索で
#        境界を決める実装だと、例示以降の本文が走査から落ちてこのケースが緑になる）
#   G25. keep-fences がフェンス内のマーカーを検査しないこと → 赤（不変条件の固定。
#        「マスクしないならフェンス検出自体を省く」素通し実装だと、フェンス内の `<!--` が
#        後続の mermaid 矢印 `-->` と対になり、間の claim 記載が落ちて緑になる）
#   G11. docs/MASTER.md が無いツリー → 行頭 `○ skip` で緑
#
# 「1 一致に数値が 2 つ以上」の claim 定義誤りは fixture から到達できない（claim の
# ERE はゲート側に固定されており、いずれも 1 一致 1 数値）。将来 claim を追加した際の
# 歯止めとしてゲート側に残してある検査で、ここでは測らない。
#
# 変異はすべて ASCII 行への perl / ファイル操作で行う。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TESTS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
PLUGIN_ROOT="$(cd "$TESTS_DIR/.." && pwd)"
REPO_ROOT="$(cd "$PLUGIN_ROOT/../.." && pwd)"
TARGET="$TESTS_DIR/docs-fact-drift/verify.sh"

[ -f "$TARGET" ] || { echo "✗ docs-fact-drift/verify.sh が見つかりません: $TARGET" >&2; exit 1; }

# fixture ファイルの前提検証（assert_fence_only）に ff_docs_body を使う
# shellcheck source=../lib/docs-scan.sh
. "$TESTS_DIR/lib/docs-scan.sh"
[ -f "$REPO_ROOT/docs/MASTER.md" ] || {
  echo "○ skip: $REPO_ROOT/docs/MASTER.md が無いためスキップ（fixture の元になる docs/ が必要）"
  exit 0
}
command -v perl >/dev/null 2>&1 || {
  echo "○ skip: perl が無い環境のためスキップ（変異注入に必要）"
  exit 0
}
command -v jq >/dev/null 2>&1 || {
  echo "○ skip: jq が無い環境のためスキップ（本体がプラグイン数の導出に使う）"
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

# fixture: docs/ と、導出元（marketplace.json / plugins ツリー）を写す。
# plugins/ 配下は SKILL.md / verify.sh / 導出に使うファイルだけを写して軽くする。
make_fixture() {
  rm -rf "$TMP/root"
  mkdir -p "$TMP/root/.claude-plugin"
  cp -R "$REPO_ROOT/docs" "$TMP/root/docs"
  cp "$REPO_ROOT/.claude-plugin/marketplace.json" "$TMP/root/.claude-plugin/marketplace.json"
  # SKILL.md（総スキル数・ff スキル数の導出元）
  local rel dir
  while IFS= read -r rel; do
    dir="$(dirname "${rel#"$REPO_ROOT"/}")"
    mkdir -p "$TMP/root/$dir"
    cp "$rel" "$TMP/root/${rel#"$REPO_ROOT"/}"
  done < <(find "$REPO_ROOT/plugins" -mindepth 4 -maxdepth 4 -name SKILL.md -type f | LC_ALL=C sort)
  # verify.sh（suite 数の導出元）は空ファイルで数だけ揃える
  while IFS= read -r rel; do
    dir="$(dirname "${rel#"$REPO_ROOT"/}")"
    mkdir -p "$TMP/root/$dir"
    : > "$TMP/root/${rel#"$REPO_ROOT"/}"
  done < <(find "$TESTS_DIR" -mindepth 2 -maxdepth 2 -name verify.sh -type f | LC_ALL=C sort)
  # その他の導出元（MCP / init-docs / ACE 定数）
  for rel in \
    "plugins/ff-dev-toolkit/mcp/src/index.ts" \
    "plugins/ff-dev-toolkit/skills/init-docs/SKILL.md" \
    "plugins/ff-dev-toolkit/docs-template/scripts/ace/check-category-size.ts" \
    "plugins/ff-dev-toolkit/docs-template/scripts/ace/ace-refine-report.ts" \
  ; do
    mkdir -p "$TMP/root/$(dirname "$rel")"
    cp "$REPO_ROOT/$rel" "$TMP/root/$rel"
  done
}

# $1=ケース名 $2=期待（green / red）$3=赤のとき出力に必要な理由（ERE、省略可）
#
# 第 3 引数は「狙った claim で赤くなったか」を見る。これは検出力の確認そのもので、
# 変異が走査対象外の場所（Changelog 節内・ACE 分割ファイルなど）に落ちて別の理由で
# 赤くなったケースを検出力ありと数えないための歯止め（レビュー指摘 + Issue #525 の実例。
# 図＝フェンス内は #525 の修正で走査対象になった）。
run_case() {
  local name="$1" expect="$2" why="${3:-}" rc=0
  FF_DOCS_REPO_ROOT="$TMP/root" bash "$TARGET" > "$TMP/out.log" 2>&1 || rc=$?
  if [ "$expect" = "green" ]; then
    if [ "$rc" -eq 0 ]; then
      ok "$name: 緑（期待どおり）"
    else
      bad "$name: 緑を期待しましたが rc=${rc} で赤でした"
      grep '✗' "$TMP/out.log" | sed 's/^/    /' | head -6 >&2
    fi
    return
  fi
  if [ "$rc" -eq 0 ]; then
    bad "$name: 赤を期待しましたが緑のまま通りました（検出力なし）"
    sed 's/^/    /' "$TMP/out.log" | tail -8 >&2
  elif [ -n "$why" ] && ! grep -qE "$why" "$TMP/out.log"; then
    bad "$name: 赤になりましたが理由が違います（期待: ${why}）"
    grep '✗' "$TMP/out.log" | sed 's/^/    /' | head -6 >&2
  else
    ok "$name: 赤（期待どおり）"
  fi
}

# 変異が実際に入ったことを確かめる。narrowing の緑ケースは「対象文書の表現が変わって
# 変異が no-op になった」場合も緑になり、何も測らないまま通ってしまう（G18b と同じ動機）。
assert_present() { # $1=ファイル $2=期待する文字列 $3=ケース名
  if grep -qF -- "$2" "$1"; then return 0; fi
  bad "$3: 変異が入っていません（期待: ${2}）。対象文書の表現が変わった可能性があります"
  return 1
}

# 既存の本文を書き換える変異は「ファイルが変化したこと」で確かめる。期待文字列に
# 件数リテラルを焼き込むと、対象の数値が変わっただけで「変異が入っていません」という
# 事実に反するメッセージで赤くなる（この suite が排除したい件数への結合そのもの）。
assert_changed() { # $1=変異前の写し $2=変異後のファイル $3=ケース名
  if ! cmp -s "$1" "$2"; then return 0; fi
  bad "$3: 変異が入っていません（ファイルが変化していません）。対象文書の表現が変わった可能性があります"
  return 1
}

# 判別力の前提の自己検証（G23 用）: 対象表現が**フェンス外に存在しない**ことを確かめる。
# G23 の判別力は「記載が図＝フェンス内にのみある」ことに乗っている。散文へ同じ表現が
# 転記されると、変異が散文側にも入り、フェンスを走査しない旧実装でも赤になって
# ケースが何も測らずに通る（run_case 第 3 引数や G18b と同じ動機の歯止め）。
assert_fence_only() { # $1=fixture ファイル $2=対象 ERE $3=ケース名
  local hits
  hits="$(ff_docs_body "$1" | grep -cE "$2" || true)"
  if [ "${hits:-0}" -ne 0 ]; then
    bad "$3: 判別力の前提が崩れています（${2} がフェンス外に ${hits} 行あります。散文へ転記されるとこのケースはフェンス走査を測れません）"
    return 1
  fi
  return 0
}

echo "== G1. baseline =="
make_fixture
run_case "G1 baseline（実リポジトリの写し）" green

echo "== G2〜G5. docs 側の記載をずらす =="
make_fixture
perl -i -pe 's/([0-9]+) suite/($1 + 1) . " suite"/ge' "$TMP/root/docs/02-design/ARCHITECTURE.md"
run_case "G2 suite 数の記載を +1" red "suite 数: [0-9]+ 件が実体"

make_fixture
perl -i -pe 's/([0-9]+) プラグイン/($1 + 1) . " プラグイン"/ge' "$TMP/root/docs/01-context/PROJECT.md"
run_case "G3 プラグイン数の記載を +1" red "プラグイン数: [0-9]+ 件が実体"

make_fixture
perl -i -pe 's/計 ([0-9]+) スキル/"計 " . ($1 + 1) . " スキル"/ge' "$TMP/root/docs/02-design/ARCHITECTURE.md"
run_case "G4 総スキル数（計 N スキル）の記載を +1" red "総スキル数（計 N スキル）: [0-9]+ 件が実体"

make_fixture
perl -i -pe 's/refine 目安 ([0-9]+)/"refine 目安 " . ($1 + 1)/ge' "$TMP/root/docs/07-project-management/RISKS.md"
run_case "G5 ACE refine 目安の記載を +1" red "ACE refine 目安: [0-9]+ 件が実体"

echo "== G6. 実体側をずらす（逆方向の drift）=="
make_fixture
jq '.plugins += [{"name":"extra-plugin","description":"x","source":"./plugins/extra-plugin"}]' \
  "$TMP/root/.claude-plugin/marketplace.json" > "$TMP/mp.json" && mv "$TMP/mp.json" "$TMP/root/.claude-plugin/marketplace.json"
run_case "G6 marketplace.json のプラグインを 1 件追加" red "プラグイン数: [0-9]+ 件が実体"

echo "== G7. 抽出の空振り =="
make_fixture
# 1 文書だけ書き換えても他の文書に残っていれば hits は 0 にならない。
# 「表現を変えた」ケースを再現するには対象文書すべてから消す必要がある。
find "$TMP/root/docs" -name '*.md' -type f -exec perl -i -pe 's/初期セット [0-9]+ ファイル/初期セットの各ファイル/g' {} +
run_case "G7 正準表現に一致する記載を全部消す" red "初期セット件数: 正準表現に 1 件も一致しません"

echo "== G8. 導出元の破損 =="
make_fixture
perl -i -pe 's/DEFAULT_WARN_ENTRIES_PER_CATEGORY/WARN_PER_CATEGORY_RENAMED/g' \
  "$TMP/root/plugins/ff-dev-toolkit/docs-template/scripts/ace/check-category-size.ts"
run_case "G8 導出元の定数名を改名（fail-closed）" red "導出できていない"

echo "== G9〜G10. 対象外の範囲 =="
make_fixture
printf '\n過去の実測では 999 suite が緑だった。\n' >> "$TMP/root/docs/08-knowledge/playbook/testing.md"
run_case "G9 ACE 分割ファイルに不一致の数値" green

make_fixture
printf '\n### [9.9.9] - 2026-01-01\n\n#### 変更\n\n- 当時は 999 suite だった\n' >> "$TMP/root/docs/02-design/ARCHITECTURE.md"
run_case "G10 Changelog 節に不一致の数値" green

echo "== G12. 行内コメント付きの記載（PR #524 レビュー 2 巡目）=="
# 1 文書だけをずらす。他の文書（ARCHITECTURE.md）に一致行が残るので hits は 0 に
# ならず、「抽出の空振り」ではなく「行内コメント付きの行を読めているか」だけを測れる。
# 対象は散文（フェンス外）に記載がある PROJECT.md を使う — このケースが測るのは
# 行内コメントの扱いであって、フェンス走査（そちらは G23）ではないため。
make_fixture
perl -i -pe 's/([0-9]+) suite/($1 + 1) . " suite <!-- note -->"/ge' "$TMP/root/docs/01-context/PROJECT.md"
run_case "G12 行内コメント付きの記載もずれを検出する" red "suite 数: [0-9]+ 件が実体"

echo "== G13. 未検査 claim を 1 件ずつずらす（claim ごとの検出力）=="
# 走査対象すべての文書へ変異を入れる（対象文書をここに書かない = 記載が別の文書へ
# 移動しても追随不要）。理由 ERE を渡すので、変異が走査対象外の場所にしか落ちなければ
# 「赤にはなったが理由が違う」で落ちる。
# name|perl 置換式|期待する理由（ERE）
# 要素は**シングルクォート**で括る（$1 が位置パラメータへ展開されないように）。
# `cut -d'|'` で分解するので、置換式と理由 ERE に `|`（選択）は書けない
CLAIM_MUTATIONS=(
  '総スキル数（N プラグイン・N スキル）|s/プラグイン・([0-9]+) スキル/"プラグイン・" . ($1 + 1) . " スキル"/ge|総スキル数（N プラグイン・N スキル）: [0-9]+ 件が実体'
  'ff-dev-toolkit スキル数|s/ff-dev-toolkit（([0-9]+) スキル/"ff-dev-toolkit（" . ($1 + 1) . " スキル"/ge|ff-dev-toolkit スキル数: [0-9]+ 件が実体'
  'MCP ツール数|s/([0-9]+) ツール/($1 + 1) . " ツール"/ge|MCP ツール数: [0-9]+ 件が実体'
  '初期セット件数|s/初期セット ([0-9]+) ファイル/"初期セット " . ($1 + 1) . " ファイル"/ge|初期セット件数: [0-9]+ 件が実体'
  'ACE ブロック上限|s/ブロック上限 ([0-9]+)/"ブロック上限 " . ($1 + 1)/ge|ACE ブロック上限: [0-9]+ 件が実体'
  'ACE 1 エントリ行数|s/エントリ ([0-9]+) 行/"エントリ " . ($1 + 1) . " 行"/ge|ACE 1 エントリ行数: [0-9]+ 件が実体'
  'ACE 昇格 Helpful|s/Helpful >= ([0-9]+)/"Helpful >= " . ($1 + 1)/ge|ACE 昇格 Helpful: [0-9]+ 件が実体'
)
for cm in "${CLAIM_MUTATIONS[@]}"; do
  cm_name="$(printf '%s' "${cm}" | cut -d'|' -f1)"
  cm_mut="$(printf '%s' "${cm}" | cut -d'|' -f2)"
  cm_why="$(printf '%s' "${cm}" | cut -d'|' -f3)"
  make_fixture
  find "$TMP/root/docs" -name '*.md' -type f -exec perl -i -pe "${cm_mut}" {} +
  run_case "G13 ${cm_name} の記載を +1" red "${cm_why}"
done

echo "== G14〜G16. claim の narrowing（別概念を拾わない）=="
# suite 数 claim は「後続 N suite」（実行を止めた本数）を除外する
make_fixture
cp "$TMP/root/docs/07-project-management/RISKS.md" "$TMP/g14-before.md"
perl -i -pe 's/後続 ([0-9]+) suite/"後続 " . ($1 + 1) . " suite"/ge' "$TMP/root/docs/07-project-management/RISKS.md"
# 判別力は RISKS.md の散文リテラル「後続 N suite」1 箇所だけに乗っている。表現が
# 変われば置換は no-op になり、このケースは何も測らずに緑になる
assert_changed "$TMP/g14-before.md" "$TMP/root/docs/07-project-management/RISKS.md" "G14" || true
run_case "G14 後続 N suite（別概念）は照合しない" green

# MCP ツール数 claim は spec-docs を含む行だけを見る（本文へ挿入する位置は
# `## Changelog` の直前 = 走査対象の末尾。挿入位置を行番号で決めると文書編集で崩れる）
make_fixture
perl -i -pe 's/^## Changelog$/本文に無関係な 99 ツール の記載を置く。\n\n$&/' \
  "$TMP/root/docs/02-design/ARCHITECTURE.md"
assert_present "$TMP/root/docs/02-design/ARCHITECTURE.md" "無関係な 99 ツール" "G15" || true
run_case "G15 spec-docs を含まない N ツール は照合しない" green

# ACE 昇格 Helpful claim は「昇格」を含む行だけを見る
make_fixture
perl -i -pe 's/^## Changelog$/カウンターの例として Helpful >= 99 を挙げる。\n\n$&/' \
  "$TMP/root/docs/07-project-management/RISKS.md"
assert_present "$TMP/root/docs/07-project-management/RISKS.md" "Helpful >= 99" "G16" || true
run_case "G16 昇格 を含まない Helpful >= N は照合しない" green

# プラグイン数・総スキル数（N プラグイン・N スキル）claim は「調査時点」を含む
# 歴史スナップショット行（DECISIONS.md ADR-024）を除外する。スナップショットの
# 数値だけを現在値からずらし、除外が効いて緑のままであることを測る
make_fixture
cp "$TMP/root/docs/06-reference/DECISIONS.md" "$TMP/g22-before.md"
perl -i -pe 's/([0-9]+) プラグイン・([0-9]+) スキル/($1 + 1) . " プラグイン・" . ($2 + 1) . " スキル"/ge if /調査時点/' \
  "$TMP/root/docs/06-reference/DECISIONS.md"
# 判別力は DECISIONS.md の「調査時点（…、N プラグイン・N スキル）」1 箇所に乗っている。
# 表現が変われば置換は no-op になり、このケースは何も測らずに緑になる
assert_changed "$TMP/g22-before.md" "$TMP/root/docs/06-reference/DECISIONS.md" "G22" || true
run_case "G22 調査時点 を含む歴史スナップショット行は照合しない" green

echo "== G17. 未閉鎖コメント開始行の記載も走査する（契約の固定）=="
# 未閉鎖 opener は「対応探索を打ち切るだけ」で、その行の文字は本文に残る規則。
# したがって未閉鎖コメント行に書いた古い件数もドリフトとして赤になる。
# CommonMark（閉じ忘れは文書末尾まで）とは意図的に異なり、同梱 MCP の maskCommentAt と同型。
make_fixture
perl -i -pe 's/^## Changelog$/<!-- 999 suite unclosed opener\n\n$&/' "$TMP/root/docs/02-design/ARCHITECTURE.md"
run_case "G17 未閉鎖コメント開始行の件数記載もずれを検出する" red "suite 数: [0-9]+ 件が実体"

echo "== G18. 散文中の コードスパン内 <!-- は後続の --> と対にならない（Issue #527）=="
# コメント開始の探索はインラインコードスパンを区別する。散文中の `` `<!--` `` は
# 後続の `-->`（ここでは mermaid の矢印）と対にならず、間の件数記載も走査される。
# 区別しない実装へ戻すと、間の `999 suite` がマスクされてこのケースが緑になる。
make_fixture
perl -i -pe 's/^## Changelog$/マーカーは `<!--` と書く。\n\n本文に 999 suite と書く。\n\n```mermaid\ngraph TD\n    A[x] --> B[y]\n```\n\n$&/' \
  "$TMP/root/docs/01-context/PROJECT.md"
assert_present "$TMP/root/docs/01-context/PROJECT.md" "999 suite" "G18" || true
run_case "G18 コードスパン内の <!-- を挟んでも間の記載を検出する" red "suite 数: [0-9]+ 件が実体"

# 対照。同じ挿入からマーカー行と mermaid を外しても赤になる = G18 の赤は「マーカーを
# 置いたせいで赤くなった」のではない。どちらが原因かの切り分けは G26（マスク出力を
# 直接見て、マーカー行と間の本文が保持されることを確かめる）が担う。
make_fixture
perl -i -pe 's/^## Changelog$/本文に 999 suite と書く。\n\n$&/' \
  "$TMP/root/docs/01-context/PROJECT.md"
run_case "G18b 同じ挿入をマーカー無しで行っても検出する（対照）" red "suite 数: [0-9]+ 件が実体"

echo "== G23. 図（フェンス内）の件数をずらす（Issue #525）=="
# DOMAIN.md の ```text 構成図と ROADMAP.md の ```mermaid 依存図は、suite 数を
# `tests/ N suite` の形でフェンス内にのみ持つ。走査がフェンスを除外する実装
# （ff_docs_body）へ戻ると、この 2 ケースだけが「緑のまま通りました」で赤くなる。
# 判別力は各図の `tests/ N suite` がフェンス内にのみあることに乗っているため、
# 2 つのガードで前提を自己検証する: assert_fence_only（散文への転記が起きていない）と
# assert_changed（変異の実在。表現が変われば置換は no-op になり何も測らずに通る）。
make_fixture
cp "$TMP/root/docs/02-design/DOMAIN.md" "$TMP/g23-before.md"
assert_fence_only "$TMP/g23-before.md" 'tests/ [0-9]+ suite' "G23a" || true
perl -i -pe 's/tests\/ ([0-9]+) suite/"tests\/ " . ($1 + 1) . " suite"/ge' \
  "$TMP/root/docs/02-design/DOMAIN.md"
assert_changed "$TMP/g23-before.md" "$TMP/root/docs/02-design/DOMAIN.md" "G23a" || true
run_case "G23a text 構成図（DOMAIN.md）内の suite 数をずらす" red "suite 数: [0-9]+ 件が実体"

make_fixture
cp "$TMP/root/docs/07-project-management/ROADMAP.md" "$TMP/g23b-before.md"
assert_fence_only "$TMP/g23b-before.md" 'tests/ [0-9]+ suite' "G23b" || true
perl -i -pe 's/tests\/ ([0-9]+) suite/"tests\/ " . ($1 + 1) . " suite"/ge' \
  "$TMP/root/docs/07-project-management/ROADMAP.md"
assert_changed "$TMP/g23b-before.md" "$TMP/root/docs/07-project-management/ROADMAP.md" "G23b" || true
run_case "G23b mermaid 依存図（ROADMAP.md）内の suite 数をずらす" red "suite 数: [0-9]+ 件が実体"

echo "== G24. フェンス内の Changelog 例示で走査が打ち切られないこと =="
# claim 走査はフェンスの中身を含む（G23）が、`## Changelog` 境界の判定は
# フェンスを消したマスクで行う。境界を生テキストの見出し検索で決める実装だと、
# フェンス内の例示 `## Changelog` を本物の節と取り違え、それ以降の本文
# （ここでは直後に置いた不一致の suite 数）が走査から落ちて緑になる。
make_fixture
perl -i -pe 's/^## Changelog$/```text\n## Changelog\n```\n\n本文に 999 suite と書く。\n\n$&/' \
  "$TMP/root/docs/02-design/ARCHITECTURE.md"
assert_present "$TMP/root/docs/02-design/ARCHITECTURE.md" "999 suite" "G24" || true
run_case "G24 フェンス内の Changelog 例示より後ろの記載も走査する" red "suite 数: [0-9]+ 件が実体"

echo "== G25. keep-fences はフェンス内のマーカーを検査しない（不変条件の固定）=="
# keep-fences モードは「消すかどうか」だけが既定モードと違い、フェンスの対応探索と
# 優先順位は共有する（docs-scan.sh の契約）。これを「マスクしないならフェンス検出
# 自体を省く」素通し実装へ単純化すると、フェンス内の裸の `<!--` が後続の mermaid
# 矢印 `-->` と対になり、間の claim 記載が落ちて緑のまま通る（Issue #525 が潰した
# 「静かなドリフト」の再発形。M1/M2 のどちらの変異クラスとも別で、この 1 本が固定する）。
make_fixture
perl -i -pe 's/^## Changelog$/```text\n<!-- 図中の注記例\n```\n\n本文に 999 suite と書く。\n\n```mermaid\ngraph TD\n    A[x] --> B[y]\n```\n\n$&/' \
  "$TMP/root/docs/01-context/PROJECT.md"
assert_present "$TMP/root/docs/01-context/PROJECT.md" "999 suite" "G25" || true
run_case "G25 フェンス内の <!-- が外のマーカーと対にならず、間の記載を走査する" red "suite 数: [0-9]+ 件が実体"

echo "== G26. マスク出力の直接検査: コードスパン内の <!-- は開始でない（Issue #527 AC-1）=="
# G18 は「間の記載が走査される」を本体経由で見るが、赤の理由がマーカーの有無に
# よらないため、マスクそのものの判別力はここで固定する。fixture は here-doc を使わず
# printf で組む（read-only TMPDIR 契約）。
printf '%s\n' \
  'マーカーは `<!--` と書く' \
  '- 回帰ゲート（69 suite）' \
  '```mermaid' \
  'graph TD' \
  '    A[x] --> B[y]' \
  '```' \
  'KEEP-AFTER' \
  '本文 <!-- 注 --> 続き' \
  '`a` <!-- x --> `<!--`' \
  > "$TMP/mask-inline.md"
printf '%s\n' \
  'マーカーは `<!--` と書く' \
  '- 回帰ゲート（69 suite）' \
  '' '' '' '' \
  'KEEP-AFTER' \
  '本文  続き' \
  '`a`  `<!--`' \
  > "$TMP/mask-inline.expected"
rc=0
ff_docs_mask_spans "$TMP/mask-inline.md" > "$TMP/mask-inline.actual" || rc=$?
if [ "$rc" -eq 0 ] && cmp -s "$TMP/mask-inline.expected" "$TMP/mask-inline.actual"; then
  ok "G26 コードスパン内の <!-- は開始にならず、スパン外の <!-- は従来どおり除去される"
else
  bad "G26 マスク出力が期待と違います（rc=${rc}）"
  # 診断出力に `|| true` を付ける（G18 系の run_case と同型）。diff は差分ありで
  # rc=1 を返し、`set -e` + `pipefail` の下では**このケースが落ちた瞬間に selftest 全体が
  # 中断**して G27 以降が未実行のまま終わる（サマリも出ない）。
  diff "$TMP/mask-inline.expected" "$TMP/mask-inline.actual" 2>&1 | sed 's/^/    /' | head -12 >&2 || true
fi

echo "== G27. CRLF 改行でも閉じたフェンスをマスクする（Issue #527 AC-3）=="
# awk は RS="\n" で読むため行末に \r が残る。閉じ判定が \r を空白として許さないと、
# CRLF ファイルだけフェンスが 1 つも閉じられず、`/\r?\n/` で分割する同梱 MCP 側
# （maskClosedSpans）と結果が食い違う。マスクしない行の \r は保持する。
printf '```text\r\n' > "$TMP/mask-crlf.md"
printf '%s\r\n' '中身' >> "$TMP/mask-crlf.md"
printf '```\r\n' >> "$TMP/mask-crlf.md"
printf 'KEEP\r\n' >> "$TMP/mask-crlf.md"
printf '\n\n\nKEEP\r\n' > "$TMP/mask-crlf.expected"
rc=0
ff_docs_mask_spans "$TMP/mask-crlf.md" > "$TMP/mask-crlf.actual" || rc=$?
if [ "$rc" -eq 0 ] && cmp -s "$TMP/mask-crlf.expected" "$TMP/mask-crlf.actual"; then
  ok "G27 CRLF のフェンスもマスクする（TS 版と同じ判断）"
else
  bad "G27 CRLF のマスク出力が期待と違います（rc=${rc}）"
  # G26 と同じ理由で `|| true`（診断出力の非 0 で selftest 全体を中断させない）
  cat -A "$TMP/mask-crlf.actual" 2>/dev/null | sed 's/^/    /' | head -8 >&2 || true
fi

echo "== G21. 実体側を 1 件増やす（Issue #519 AC-2 の逆方向）=="
# docs 側をずらす変異（G2 / G4 / G13）と対になる、**実体側**の変異。スキル・suite・
# MCP ツールを 1 件足すと、docs の記載が古くなって赤になる（運用上いちばん起こる形）。
make_fixture
mkdir -p "$TMP/root/plugins/probe-plugin/skills/probe-skill"
printf -- '---\nname: probe-skill\ndescription: probe\n---\n' \
  > "$TMP/root/plugins/probe-plugin/skills/probe-skill/SKILL.md"
run_case "G21 スキルを 1 件追加" red "総スキル数（計 N スキル）: [0-9]+ 件が実体"

make_fixture
mkdir -p "$TMP/root/plugins/ff-dev-toolkit/tests/probe-suite"
: > "$TMP/root/plugins/ff-dev-toolkit/tests/probe-suite/verify.sh"
run_case "G21 suite を 1 件追加" red "suite 数: [0-9]+ 件が実体"

make_fixture
printf '\nserver.registerTool(\n' >> "$TMP/root/plugins/ff-dev-toolkit/mcp/src/index.ts"
run_case "G21 MCP ツールを 1 件追加" red "MCP ツール数: [0-9]+ 件が実体"

echo "== G19. 導出元の消失（0 を実体値として受理しないこと）=="
# `find <消えたディレクトリ> | wc -l` は find がエラー終了しても 0 を出すので、導出元の
# 消失が「実体は 0 件」に化ける。健全なチェックアウトでは全 claim が 1 以上なので、
# 0 は導出失敗として扱う。
#
# **理由 ERE は「導出できません」まで見る。** 0 を受理する実装でも「記載 69 ≠ 実体 0」で
# 赤にはなるので、終了コードだけを見ると 0 拒否の検出力を測れない（実測で確認済み）。
# **分離しているのは理由 ERE であって fixture ではない。** `skills/` を消すと
# ff スキル数（0 → 導出失敗）だけでなく、初期セット件数（導出元の SKILL.md が消えて
# 空文字 → 既存の fail-closed 経路）と総スキル数（98 → 78 で不一致）も同時に赤くなる。
# 0 の経路だけが出す文字列を理由に要求することで、その 1 本を切り分けている。
make_fixture
rm -rf "$TMP/root/plugins/ff-dev-toolkit/tests"
run_case "G19 導出元 tests/ を削除（suite 数が 0 になる）" red "suite 数 を実体から導出できません"

make_fixture
rm -rf "$TMP/root/plugins/ff-dev-toolkit/skills"
run_case "G19 導出元 skills/ を削除（ff スキル数が 0 になる）" red "ff-dev-toolkit スキル数 を実体から導出できません"

echo "== G20. 書き込み不可の TMPDIR でも完走する =="
# CHANGELOG で「両ゲートは read-only TMPDIR で完走する」と書いているので、
# こちら側でも固定する（Frontmatter 側は G18 で固定済み）。
make_fixture
RO_DIR="$TMP/ro"
mkdir -p "$RO_DIR" && chmod 500 "$RO_DIR"
rc=0
TMPDIR="$RO_DIR" FF_DOCS_REPO_ROOT="$TMP/root" bash "$TARGET" > "$TMP/out.log" 2>&1 || rc=$?
chmod 700 "$RO_DIR"
if [ "$rc" -eq 0 ] && grep -q '件すべてが実体' "$TMP/out.log"; then
  ok "G20 書き込み不可の TMPDIR で完走し、claim の照合も実行された"
else
  bad "G20 書き込み不可の TMPDIR で rc=${rc}（here-doc / here-string が一時ファイルを要求している可能性）"
  sed 's/^/    /' "$TMP/out.log" | tail -6 >&2
fi

echo "== G11. 検査対象が無いツリー =="
rm -rf "$TMP/root"
mkdir -p "$TMP/root"
rc=0
FF_DOCS_REPO_ROOT="$TMP/root" bash "$TARGET" > "$TMP/out.log" 2>&1 || rc=$?
skips="$(grep -c '^○ skip' "$TMP/out.log" || true)"
if [ "$rc" -eq 0 ] && [ "${skips:-0}" -ge 1 ]; then
  ok "G11 docs/MASTER.md が無いツリー: 行頭 ○ skip を出して緑"
else
  bad "G11 docs/MASTER.md が無いツリー: rc=${rc} / skip マーカーを確認できません"
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
echo "✅ docs-fact-drift-selftest: all checks passed"
