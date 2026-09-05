#!/usr/bin/env bash
#
# docs-version-changelog/verify.sh 自身の検出力検証（Issue #884）。
#
# fixture を mktemp に組み立て、FF_DOCS_REPO_ROOT で本体を駆動して以下を実測する:
#   G1.  実リポジトリの docs/ をそのまま写した baseline が緑
#   G2.  frontmatter のみ bump（エントリ不在の版へ）→ 赤（#884 の事象 1）
#   G3.  Changelog にのみ新エントリを追加（frontmatter 未 bump）→ 赤（事象 2）
#   G4.  version 行を frontmatter から削除 → 赤
#   G5.  version 行の重複（有効 + 不正の併記）→ 赤
#   G6.  version が "x.y.z" 以外（"1.0"）→ 赤 / G6b. 先頭ゼロ（"01.0.0"）→ 赤
#   G7.  Changelog 節から版エントリを全て除去 → 赤
#   G8.  版エントリとして解析できない ### 見出し（`]garbage`）→ 赤（スキップして
#        次の有効エントリで判定しない）
#   G9.  Frontmatter の閉じ --- を破損（本文に水平線を持たない文書）→ 赤
#   G9b. Frontmatter の閉じ --- を破損（本文に水平線 --- を持つ DECISIONS 型の
#        文書）→ 赤。「最初の ^---$」を閉じ行と採る実装だと本文の水平線が閉じ行に
#        化けて緑のまま通る（fail-open。3 巡目レビューで検出、修正前コードで実測）
#   G10. 対象 0 件（全 .md を除去）→ 赤（抽出の空振りを緑にしない）
#   G11. docs/ 不在 → 行頭 `○ skip` を出して緑
#   G12. Changelog 節のフェンス内・コメント内に置いた偽エントリ（[9.9.9]）を
#        無視して緑（マスクが効いていること）
#   G13. 対象文書の読み取り失敗（chmod 000）→ 赤（無言スキップにしない）。
#        chmod 000 でも読めてしまう環境（root 実行等）では、実装が正常でも
#        「読めない状態」を作れず検証が成立しないため、このケースだけ理由付きで
#        見送る（行頭 `○ skip` は suite 全体の契約マーカーなので使わない）
#   G14. 昇順 Changelog（最大版が末尾）の文書 → 緑（最大版比較が並び順に依存しない
#        こと。同梱テンプレート DECISION_TREE.md が昇順で積む形の正例）
#   G15. 昇順 Changelog で frontmatter が古い版のまま → 赤（並び順が変わっても
#        両方向の乖離検出が保たれること）
#   G16. PLAYBOOK.md の frontmatter version を壊しても緑（ACE 側ゲートの担当で、
#        本 suite が対象にしていないことの固定）
#   G17. 書き込み不可の TMPDIR でも完走する（指定 TMPDIR に依存しないこと）。
#        chmod 500 が効かない環境（root 実行等）は G13 と同様に理由付きで見送る
#   G18. Changelog 節の**後続**に置いた別節（## Appendix）配下の ### [9.9.9] を
#        エントリと数えない → 緑（節終端の境界が効いていること）
#   G19. 実在する `## Changelog` 節を2件にする → 赤（後続節を無視しない）
#   G20. 見出しを `##  Changelog`（空白 2 個）にして frontmatter のみ bump → 赤
#        （共有 helper が受理する空白ゆれを本体 suite が対象外へ落とさないこと。
#        見出し正規表現が厳密なままだと changelog_n=0 で黙って対象外になり緑）
#   G21. 見出しを末尾空白付きにして frontmatter のみ bump → 赤（G20 の対）
#
# 変異はすべて ASCII 行への perl / ファイル操作で行う（多バイト文字クラス不使用）。
# 一時ディレクトリを作成できない環境では skip して成功扱いにする
# （fixture の組み立て自体が成立しないため。checkout が read-only でも、書ける
# TMPDIR があれば完走する）。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TESTS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
TARGET="$TESTS_DIR/docs-version-changelog/verify.sh"

# リポジトリルートの導出は本体 suite・兄弟 selftest と同一の方式（固定段数 +
# FF_DOCS_REPO_ROOT 上書き）。モノレポ / 公開リポジトリはどちらも
# plugins/ff-dev-toolkit/tests/<suite>/ のパス構造を保ち、インストール済み
# キャッシュ配置（docs/ 無し）は下の ○ skip が受ける。
DEFAULT_ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"
REPO_ROOT="${FF_DOCS_REPO_ROOT:-$DEFAULT_ROOT}"

[ -f "$TARGET" ] || { echo "✗ docs-version-changelog/verify.sh が見つかりません: $TARGET" >&2; exit 1; }
[ -d "$REPO_ROOT/docs" ] || {
  echo "○ skip: $REPO_ROOT/docs が無いためスキップ（fixture の元になる docs/ が必要）"
  exit 0
}

command -v perl >/dev/null 2>&1 || {
  echo "○ skip: perl が無い環境のためスキップ（変異注入に必要）"
  exit 0
}

# rc=0 でも -d を検査する — 2>&1 の合流は「成功 + stderr 警告」の環境で変数へ
# 警告文が混入し、以後の処理が原因不明の失敗に化けるため。
if _ff_mktemp_out="$(mktemp -d 2>&1)" && [ -d "$_ff_mktemp_out" ]; then
  TMP="$_ff_mktemp_out"
else
  echo "○ skip: 一時ディレクトリを作成できない環境のためスキップ"
  printf '  mktemp: %s\n' "$_ff_mktemp_out"
  exit 0
fi
FF_REACHED_END=0
_ff_exit_guard() {
  _ff_rc=$?
  chmod -R u+rwX "$TMP" 2>/dev/null || true
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
ENV_SKIPPED=0
ok()  { echo "  ✓ $1"; PASS=$((PASS + 1)); }
bad() { echo "  ✗ $1" >&2; FAIL=$((FAIL + 1)); }
env_skip() { echo "  ○ $1"; ENV_SKIPPED=$((ENV_SKIPPED + 1)); }

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
# 変異が別の検査を偶発的に壊したケースを検出力ありと数えないため。
run_case() {
  local name="$1" expect="$2" why="${3:-}" rc=0
  case "$expect" in
    green|red) ;;
    *) bad "$name: expect の値が不正です（${expect}）— selftest 自体のバグ"; return ;;
  esac
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

# 変異が実際に入ったことを確かめる。赤ケースは理由 ERE が空振りを捕まえるが、
# 緑ケースは何も測らずに緑になるため、原本との差分で no-op 変異を検出する。
assert_mutated() { # $1=docs/ 起点の相対パス $2=ケース名
  if cmp -s "$REPO_ROOT/$1" "$TMP/root/$1"; then
    bad "$2: 変異が入っていません（${1} が原本と同一）。対象文書の表現が変わった可能性があります"
    return 1
  fi
  return 0
}

VICTIM="docs/07-project-management/RISKS.md"
# 本文に水平線 --- を持つ文書（G9b 用）。閉じ欠落が本文の水平線で隠れる
# fail-open は、この型の文書でしか再現しない。
VICTIM_HR="docs/06-reference/DECISIONS.md"

echo "== G1. baseline =="
make_fixture
run_case "G1 baseline（実 docs/ の写し）" green

echo "== G2〜G3. 両方向の乖離 =="
make_fixture
perl -i -pe 's/^version: "[0-9.]+"$/version: "9.9.8"/ if $. < 10' "$TMP/root/$VICTIM"
run_case "G2 frontmatter のみ bump（エントリ不在の 9.9.8 へ）" red 'version=9\.9\.8 が Changelog 内の最大版'

make_fixture
perl -i -pe 's/^## Changelog$/$&\n\n### [9.9.9] - 2099-01-01\n\n- エントリのみ追加の変異/' "$TMP/root/$VICTIM"
run_case "G3 Changelog にのみエントリ追加（frontmatter 未 bump）" red '最大版 \[9\.9\.9\] と一致しません'

echo "== G4〜G6b. frontmatter version 行の欠落 / 重複 / 不正形式 =="
make_fixture
perl -i -ne 'print unless ($. < 10 && /^version: /)' "$TMP/root/$VICTIM"
run_case "G4 version 行の削除" red "version 行がありません"

make_fixture
perl -i -pe 's/^(version: "[0-9.]+")$/$1\nversion: "invalid"/ if $. < 10' "$TMP/root/$VICTIM"
run_case "G5 version 行の重複（有効 + 不正の併記）" red "version 行が複数あります"

make_fixture
perl -i -pe 's/^version: "[0-9.]+"$/version: "1.0"/ if $. < 10' "$TMP/root/$VICTIM"
run_case "G6 version が x.y.z 以外（1.0）" red 'version が "x\.y\.z" 形式'

make_fixture
perl -i -pe 's/^version: "[0-9.]+"$/version: "01.0.0"/ if $. < 10' "$TMP/root/$VICTIM"
run_case "G6b version の先頭ゼロ（01.0.0）" red 'version が "x\.y\.z" 形式'

echo "== G7〜G8. Changelog 側の版エントリ =="
make_fixture
perl -i -pe 's/^### \[/#### [/' "$TMP/root/$VICTIM"
run_case "G7 版エントリを全て除去" red "版エントリ.*1 件もありません"

make_fixture
perl -i -pe 'if (!$ff_done and s/^### \[([0-9.]+)\] /### [$1]garbage /) { $ff_done = 1 }' "$TMP/root/$VICTIM"
assert_mutated "$VICTIM" "G8" || true
run_case "G8 解析できない ### 見出し（]garbage）" red "解析できない ### 見出し"

echo "== G9〜G9b. Frontmatter 未閉鎖 =="
make_fixture
perl -i -pe 'if (/^---$/) { $ff_n++; $_ = "-  -\n" if $ff_n == 2 }' "$TMP/root/$VICTIM"
run_case "G9 閉じ --- の破損（本文に水平線なし）" red "Frontmatter が閉じていません"

# 「2 行目以降で最初の ^---$」を閉じ行と採る実装だと、本文の水平線が閉じ行に
# 化けて G9b は緑のまま通る（修正前コードで実測した fail-open）。
make_fixture
perl -i -pe 'if (/^---$/) { $ff_n++; $_ = "-  -\n" if $ff_n == 2 }' "$TMP/root/$VICTIM_HR"
assert_mutated "$VICTIM_HR" "G9b" || true
run_case "G9b 閉じ --- の破損（本文に水平線を持つ DECISIONS 型）" red "本文らしい行が混在"

echo "== G10〜G11. 対象 0 件と docs/ 不在 =="
make_fixture
find "$TMP/root/docs" -name '*.md' -type f -exec rm -f {} +
run_case "G10 対象 0 件（全 .md を除去）" red "1 件も導出できません"

rm -rf "$TMP/root"
mkdir -p "$TMP/root"
rc=0
FF_DOCS_REPO_ROOT="$TMP/root" bash "$TARGET" > "$TMP/out.log" 2>&1 || rc=$?
# grep -q はファイル入力なので SIGPIPE の罠（run-all case 10）に当たらない
if [ "$rc" -eq 0 ] && grep -q '^○ skip' "$TMP/out.log"; then
  ok "G11 docs/ 不在: 行頭 ○ skip を出して緑"
else
  bad "G11 docs/ 不在: rc=${rc} / skip マーカーを確認できません"
  sed 's/^/    /' "$TMP/out.log" | tail -6 >&2
fi

echo "== G12. マスク（フェンス / コメント内の偽エントリ）=="
make_fixture
# Changelog 節の中にフェンス内・コメント内の偽エントリ [9.9.9] を置く。
# マスクが外れていれば最大版が 9.9.9 になり frontmatter と食い違って赤くなる。
perl -i -pe 's/^## Changelog$/$&\n\n```markdown\n## Changelog\n### [9.9.9] - 2099-01-01\n```\n\n<!--\n## Changelog\n### [9.9.9] - 2099-01-01\n-->/' "$TMP/root/$VICTIM"
assert_mutated "$VICTIM" "G12" || true
run_case "G12 フェンス・コメント内の偽エントリ [9.9.9] を無視" green

echo "== G13. 読み取り失敗の fail-closed =="
make_fixture
chmod 000 "$TMP/root/$VICTIM"
# 前提確認: chmod 000 で実際に読めなくなっていること。root 実行等では権限を
# 無視して読めてしまい、「読めない状態」を fixture に作れない — その場合は
# 実装が正常でも赤にならないため、このケースだけ理由付きで見送る
# （行頭 `○ skip` は suite 全体の契約マーカーなので、ここでは字下げして出す）。
if head -n 1 "$TMP/root/$VICTIM" >/dev/null 2>&1; then
  env_skip "G13 skip: chmod 000 でも読める環境（root 実行等）のため、読み取り失敗を再現できず検証対象外"
else
  run_case "G13 対象文書の読み取り失敗（chmod 000）" red "先頭行を読み取れません"
fi
chmod 644 "$TMP/root/$VICTIM"

echo "== G14〜G15. 昇順 Changelog（並び順非依存）=="
make_fixture
printf -- '---\ntitle: "ASCENDING"\nversion: "1.1.0"\nstatus: "draft"\nowner: "@ff"\ncreated: "2026-08-26"\nupdated: "2026-08-26"\n---\n\n# 昇順 Changelog の文書\n\n## Changelog\n\n### [1.0.0] - 2026-08-25\n\n- 初版\n\n### [1.1.0] - 2026-08-26\n\n- 昇順で末尾に最新版を積む形（docs-template/03-implementation/DECISION_TREE.md と同型）\n' \
  > "$TMP/root/docs/ascending-probe.md"
run_case "G14 昇順 Changelog（frontmatter = 最大版 1.1.0）" green

perl -i -pe 's/^version: "1\.1\.0"$/version: "1.0.0"/' "$TMP/root/docs/ascending-probe.md"
run_case "G15 昇順 Changelog で frontmatter が古い版のまま" red 'version=1\.0\.0 が Changelog 内の最大版 \[1\.1\.0\]'

echo "== G16. PLAYBOOK.md は対象外（ACE 側ゲートの担当）=="
make_fixture
if [ -f "$TMP/root/docs/08-knowledge/PLAYBOOK.md" ]; then
  perl -i -pe 's/^version: "?[0-9.]+"?$/version: "9.9.9"/ if $. < 10' "$TMP/root/docs/08-knowledge/PLAYBOOK.md"
  assert_mutated "docs/08-knowledge/PLAYBOOK.md" "G16" || true
  run_case "G16 PLAYBOOK.md の version を壊しても緑（担当ゲートは別）" green
else
  bad "G16: fixture に docs/08-knowledge/PLAYBOOK.md がありません（除外契約を検証できない）"
fi

echo "== G17. 書き込み不可の TMPDIR でも完走する =="
make_fixture
RO_DIR="$TMP/ro"
mkdir -p "$RO_DIR" && chmod 500 "$RO_DIR"
# 前提確認: chmod 500 が実効であること（root 実行等では書けてしまい、
# 「書き込み不可の TMPDIR」を fixture に作れない）。
if touch "$RO_DIR/.probe" 2>/dev/null; then
  rm -f "$RO_DIR/.probe"
  env_skip "G17 skip: chmod 500 でも書ける環境（root 実行等）のため、書き込み不可 TMPDIR を再現できず検証対象外"
else
  rc=0
  TMPDIR="$RO_DIR" FF_DOCS_REPO_ROOT="$TMP/root" bash "$TARGET" > "$TMP/out.log" 2>&1 || rc=$?
  if [ "$rc" -eq 0 ]; then
    ok "G17 書き込み不可の TMPDIR で完走（指定 TMPDIR に依存せず完走することを検証）"
  else
    bad "G17 書き込み不可の TMPDIR で rc=${rc}（一時ファイルを要求する構文が混入した可能性）"
    sed 's/^/    /' "$TMP/out.log" | tail -6 >&2
  fi
fi
chmod 700 "$RO_DIR"

echo "== G18. Changelog 節終端の境界 =="
make_fixture
# Changelog 節の後ろに別節を置き、その配下の ### [9.9.9] をエントリと数えない
# こと（節終端の ^## 境界が消えると最大版 9.9.9 で赤くなる）。
printf '\n## Appendix\n\n### [9.9.9] - 2099-01-01\n\n- 別節に置いたエントリ様の見出し（数えてはいけない）\n' >> "$TMP/root/$VICTIM"
assert_mutated "$VICTIM" "G18" || true
run_case "G18 後続の別節（## Appendix）配下の [9.9.9] を数えない" green

echo "== G19. Changelog 節の重複を fail-closed =="
make_fixture
printf '\n## Changelog\n\n### [9.9.9] - 2099-01-01\n\n- 重複節へ隠した版エントリ\n' >> "$TMP/root/$VICTIM"
assert_mutated "$VICTIM" "G19" || true
run_case "G19 実在する ## Changelog 節が2件" red "## Changelog 節が 2 件あります"

echo "== G20〜G21. 見出しの空白ゆれでも対象から外れない =="
# 共有 helper（tests/lib/docs-scan.sh）は `##  Changelog`（空白 2 個）と末尾空白付き
# を正規の Changelog 見出しとして受理する。本体 suite の見出し正規表現だけが
# 「空白ちょうど 1 個・末尾空白なし」に留まると、これらの文書は changelog_n=0 で
# TARGETS に数えられず、version 照合が**黙って**消える（fail-open）。変異は
# 「見出しの空白ゆれ + frontmatter のみ bump」の 2 段で、正規表現が厳密なままだと
# 緑（検出力なし）に落ちることでしか区別できない。
make_fixture
perl -i -pe 's/^## Changelog$/##  Changelog/' "$TMP/root/$VICTIM"
perl -i -pe 's/^version: "[0-9.]+"$/version: "9.9.8"/ if $. < 10' "$TMP/root/$VICTIM"
assert_mutated "$VICTIM" "G20" || true
run_case "G20 見出しが '##  Changelog'（空白 2 個）でも version 乖離を検出" red 'version=9\.9\.8 が Changelog 内の最大版'

make_fixture
perl -i -pe 's/^## Changelog$/## Changelog /' "$TMP/root/$VICTIM"
perl -i -pe 's/^version: "[0-9.]+"$/version: "9.9.8"/ if $. < 10' "$TMP/root/$VICTIM"
assert_mutated "$VICTIM" "G21" || true
run_case "G21 見出しが末尾空白付きでも version 乖離を検出" red 'version=9\.9\.8 が Changelog 内の最大版'

echo ""
echo "結果: pass=${PASS} fail=${FAIL} env-skip=${ENV_SKIPPED}"
if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
# 件数会計に依存しない床: 検査が 1 件も走らないランと、env_skip の暴走（skip 条件の
# 誤発火で検査が skip へ雪崩れる形）を緑にしない。env_skip の正常な発生源は
# G13 / G17 の 2 件だけ（perl 系の環境都合）。
if [ "$PASS" -eq 0 ]; then
  echo "✗ 検査が 1 件も成功していない（全 skip / 全空振り）— 緑として扱わない" >&2
  exit 1
fi
if [ "$ENV_SKIPPED" -gt 2 ]; then
  echo "✗ env-skip が ${ENV_SKIPPED} 件（正常な発生源は G13/G17 の 2 件まで）— skip 条件の誤発火を疑う" >&2
  exit 1
fi
FF_REACHED_END=1
echo "✅ docs-version-changelog-selftest: all checks passed"
