#!/usr/bin/env bash
#
# 共通ライブラリ tests/lib/section-scope.sh のフェンス状態機械を、fixture 文書で直接叩く。
#
# lib は多数の契約 suite が source するが、consumer 文書はチルダフェンス（`~~~`）と未閉じ
# フェンスを踏まない（2026-09-23 実測）。その分岐と見出し本数のガード（0 本・2 本）は実文書経由
# では一度も実行されず、退行しても consumer suite は緑のままなので、ここで直接の fixture として
# 固定する。散文モード（`section_scope_extract_prose`）がフェンスの区切り行と中身を
# 除くことも、4 連の中の 3 連・バッククォートの中の `~~~` を含めてここで見る。
# fixture のフェンス内に置く見出しは行頭に置く（字下げした見出しは lib がそもそも
# 見出しと見なさないので、フェンスを追跡しなくても節が切れず、検査の識別力が無くなる）。lib の変異は一時領域へ写した
# コピーにだけ当て、実作業ツリーには触れない。
#
# 経緯: もとは retrospective-contract-selftest の系統 6 として置かれていた。同 selftest を
# 撤去したとき（Issue `#1824`）、lib を直接叩く検査はここにしか無かったので独立させた。
# 対の selftest を持たない高速 suite として既定モードで毎回走る。
#
# 空振り検出: lib の公開関数 `section_scope_contains` / `section_scope_extract_prose` / `section_scope_heading_count` を別名へ改名した写しを与えると、18 件中 17 件が赤になる（2026-09-23 実測。残る 1 件は散文モード無効化の変異の判定で、入口が無い回も「散文だけが返らない」側＝赤の側へ倒れるので緑のまま。lib の入口が消えた状態を「検査なしの緑」へ倒さない）。
#
# 一時領域が作れない回は skip せず赤で止める（lib の検査が丸ごと消える経路を残さない）。

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SRC_SECTION_SCOPE="$PLUGIN_ROOT/tests/lib/section-scope.sh"

if [[ ! -s "$SRC_SECTION_SCOPE" ]]; then
  echo "✗ section-scope-lib: 検査対象の lib が存在しないか空です: $SRC_SECTION_SCOPE" >&2
  exit 1
fi
if ! command -v perl >/dev/null 2>&1; then
  echo "✗ section-scope-lib: perl が無いため lib への変異を適用できません（検査は 1 件も実行されていません）" >&2
  exit 1
fi
# mktemp の診断を捨てると不正 TMPDIR と read-only を区別できないため、成功時のパスと
# 失敗時の理由を同じ変数へ受ける。rc=0 でも -d を検査する（警告文の混入対策）。
if _ff_mktemp_out="$(mktemp -d "${TMPDIR:-/tmp}/section-scope-lib.XXXXXX" 2>&1)" && [ -d "$_ff_mktemp_out" ]; then
  FIXTURE_ROOT="$_ff_mktemp_out"
else
  echo "✗ section-scope-lib: 一時ディレクトリを作成できません（検査は 1 件も実行されていません）: $_ff_mktemp_out" >&2
  exit 1
fi

# trap の最終コマンドの終了ステータスが suite の rc を上書きし、途中死が pass に
# 化けるのを防ぐ末尾到達センチネル。
REACHED_END=0
cleanup() {
  local rc=$?
  rm -rf "$FIXTURE_ROOT"
  if [[ "$REACHED_END" -ne 1 && "$rc" -eq 0 ]]; then
    rc=1
  fi
  exit "$rc"
}
trap cleanup EXIT
trap 'exit 130' HUP INT TERM

PASS=0
FAIL=0
ok() {
  echo "  ✓ $1"
  PASS=$((PASS + 1))
}
bad() {
  echo "  ✗ $1" >&2
  FAIL=$((FAIL + 1))
}

# 変異が実際にファイルへ適用されたことを確認する（置換の空振りを検出力の喪失と誤診しない）。
assert_mutated() {
  local mutated="$1" pristine="$2" label="$3"
  if cmp -s "$mutated" "$pristine"; then
    bad "${label}: 変異が適用されていない（置換パターンの空振り — lib の変更に追従が必要）"
    return 1
  fi
  return 0
}

drop_lines_containing() {
  local file="$1" needle="$2"
  FF_NEEDLE="$needle" perl -ni -e 'print unless index($_, $ENV{FF_NEEDLE}) >= 0' "$file"
}

echo "== section-scope lib の状態機械（fixture 直叩き） =="

mkdir -p "$FIXTURE_ROOT/lib"
SS_LIB="$FIXTURE_ROOT/lib/section-scope.sh"
cp "$SRC_SECTION_SCOPE" "$SS_LIB"
SS_FENCED="$FIXTURE_ROOT/section-scope-fenced.md"
SS_UNCLOSED_AFTER="$FIXTURE_ROOT/section-scope-unclosed-after.md"
SS_UNCLOSED_BEFORE="$FIXTURE_ROOT/section-scope-unclosed-before.md"
SS_PROBE="$FIXTURE_ROOT/section-scope-probe.sh"
SS_PROSE_PROBE="$FIXTURE_ROOT/section-scope-prose-probe.sh"
SS_COUNT_PROBE="$FIXTURE_ROOT/section-scope-count-probe.sh"
SS_DUP="$FIXTURE_ROOT/section-scope-duplicate-heading.md"
SS_NOHEAD="$FIXTURE_ROOT/section-scope-no-heading.md"

# 同名見出しが 2 本ある文書。針は 2 本目の節にだけ置く — ガードが緩むと 2 つの節が連結され、
# 1 本目の節から針が消えても緑になる（写しの節版）。
cat >"$SS_DUP" <<'SS_DUP_DOC'
## 節A

- 針1

## 節A

- 針2
SS_DUP_DOC

cat >"$SS_NOHEAD" <<'SS_NOHEAD_DOC'
## 節B

- 針B
SS_NOHEAD_DOC

cat >"$SS_FENCED" <<'SS_FENCED_DOC'
## 節A

- 針A

```bash
## フェンス内の見出し例示
# フェンス内のコメント
fenced-backtick
```

    ~~~
## 字下げチルダの内側
fenced-tilde
    ~~~

````text
```
## 4 連の内側（3 連では閉じない）
```
fenced-quad
````

```text
~~~
## バッククォート内のチルダ行（文字種の違う行では閉じない）
fenced-mixed
```

## 節B

- 針B
SS_FENCED_DOC

cat >"$SS_UNCLOSED_AFTER" <<'SS_UNCLOSED_AFTER_DOC'
## 節A

- 針A

```bash
echo "閉じフェンスを 1 本落とした形"

## 節B

- 針B
SS_UNCLOSED_AFTER_DOC

cat >"$SS_UNCLOSED_BEFORE" <<'SS_UNCLOSED_BEFORE_DOC'
```bash
echo "見出しより前で開いたまま"

## 節A

- 針A
SS_UNCLOSED_BEFORE_DOC

cat >"$SS_PROBE" <<'SS_PROBE_SH'
#!/usr/bin/env bash
# $1=lib $2=文書 $3=見出し $4=needle。rc と理由行をそのまま返す。
set -euo pipefail
. "$1"
section_scope_contains "$2" "$3" "$4"
SS_PROBE_SH

cat >"$SS_PROSE_PROBE" <<'SS_PROSE_PROBE_SH'
#!/usr/bin/env bash
# $1=lib $2=文書 $3=見出し。散文モードの節本文をそのまま返す。
set -euo pipefail
. "$1"
section_scope_extract_prose "$2" "$3"
SS_PROSE_PROBE_SH

cat >"$SS_COUNT_PROBE" <<'SS_COUNT_PROBE_SH'
#!/usr/bin/env bash
# $1=lib $2=文書 $3=見出し。フェンス外の見出し本数をそのまま返す。
set -euo pipefail
. "$1"
section_scope_heading_count "$2" "$3"
SS_COUNT_PROBE_SH

SS_OUT=""
SS_RC=0
run_section_scope() { # $1=文書 $2=見出し $3=needle
  set +e
  SS_OUT="$(bash "$SS_PROBE" "$SS_LIB" "$1" "$2" "$3" 2>&1)"
  SS_RC=$?
  set -e
}

run_section_scope_count() { # $1=文書 $2=見出し
  set +e
  SS_OUT="$(bash "$SS_COUNT_PROBE" "$SS_LIB" "$1" "$2" 2>&1)"
  SS_RC=$?
  set -e
}

expect_heading_count() { # $1=文書 $2=見出し $3=期待 rc $4=期待する出力（rc=0 なら本数と完全一致、それ以外は理由の断片） $5=ラベル
  run_section_scope_count "$1" "$2"
  local matched=0
  if [[ "$3" -eq 0 ]]; then
    [[ "$SS_OUT" == "$4" ]] && matched=1
  else
    [[ "$SS_OUT" == *"$4"* ]] && matched=1
  fi
  if [[ "$SS_RC" -eq "$3" && "$matched" -eq 1 ]]; then
    ok "$5"
  else
    bad "${5}（rc=${SS_RC} / 期待 ${3}、出力: ${SS_OUT}）"
  fi
}

run_section_scope_prose() { # $1=文書 $2=見出し
  set +e
  SS_OUT="$(bash "$SS_PROSE_PROBE" "$SS_LIB" "$1" "$2" 2>&1)"
  SS_RC=$?
  set -e
}

# 散文モードの判定。散文（針A）が残り、4 種のフェンス（バッククォート・字下げチルダ・4 連の中の
# 3 連・バッククォートの中の ~~~）の中身と区切り行がどれも出てこないこと。
prose_is_clean() {
  [[ "$SS_RC" -eq 0 && "$SS_OUT" == *"針A"* && "$SS_OUT" != *"fenced-"* \
    && "$SS_OUT" != *'```'* && "$SS_OUT" != *"~~~"* ]]
}

expect_section_scope() { # $1=文書 $2=見出し $3=needle $4=期待 rc $5=ラベル $6=期待する理由の断片（任意）
  run_section_scope "$1" "$2" "$3"
  if [[ "$SS_RC" -ne "$4" ]]; then
    bad "${5}（rc=${SS_RC} / 期待 ${4}: ${SS_OUT}）"
    return
  fi
  if [[ -n "${6:-}" && "$SS_OUT" != *"${6}"* ]]; then
    bad "${5}（理由が期待と異なる: ${SS_OUT}）"
    return
  fi
  ok "$5"
}


expect_section_scope "$SS_FENCED" "## 節A" "fenced-backtick" 0 \
  "lib 回帰: フェンス内の見出し例示・コメントで節が切れない"
expect_section_scope "$SS_FENCED" "## 節A" "fenced-tilde" 0 \
  "lib 回帰: 字下げ + チルダフェンスを追跡する"
expect_section_scope "$SS_FENCED" "## 節A" "fenced-quad" 0 \
  "lib 回帰: 4 連バッククォートは内側の 3 連で閉じない"
expect_section_scope "$SS_FENCED" "## 節A" "fenced-mixed" 0 \
  "lib 回帰: バッククォートのフェンスは文字種の違う ~~~ 行では閉じない"
expect_section_scope "$SS_DUP" "## 節A" "針2" 1 \
  "lib 回帰: 同名見出しが 2 本なら検査不能（節を連結しない）" "2 本あります"
expect_section_scope "$SS_NOHEAD" "## 節A" "針B" 1 \
  "lib 回帰: 見出しが 0 本なら検査不能" "0 本あります"
run_section_scope_prose "$SS_FENCED" "## 節A"
if prose_is_clean; then
  ok "lib 回帰: 散文モードは 4 種のフェンスの区切り行と中身を除き散文だけを返す"
else
  bad "lib 回帰: 散文モードは 4 種のフェンスの区切り行と中身を除き散文だけを返す（rc=${SS_RC}: ${SS_OUT}）"
fi
expect_section_scope "$SS_FENCED" "## 節A" "針B" 1 \
  "lib 回帰: 閉じたフェンスの後は次の見出しで節が終わる" "がありません"
expect_section_scope "$SS_UNCLOSED_AFTER" "## 節A" "針B" 1 \
  "lib 回帰: 見出しより後の未閉じフェンスは検査不能（節が文書末尾まで伸びない）" "検査不能"
expect_section_scope "$SS_UNCLOSED_BEFORE" "## 節A" "針A" 1 \
  "lib 回帰: 見出しより前の未閉じフェンスも検査不能" "検査不能"
expect_heading_count "$SS_FENCED" "## フェンス内の見出し例示" 0 "0" \
  "lib 回帰: 見出し本数はフェンス内の見出し例示を数えない"
expect_heading_count "$SS_DUP" "## 節A" 0 "2" \
  "lib 回帰: 見出し本数は同名見出しを 2 本と数える"
expect_heading_count "$SS_UNCLOSED_AFTER" "## 節B" 1 "検査不能" \
  "lib 回帰: 見出し本数も未閉じフェンスでは検査不能"

# 変異 1: フェンス開始で状態を立てない（状態機械を 1 箇所だけ壊す）。
perl -pi -e 's{^(\s*)in_fence = 1$}{$1 . "in_fence = 0"}e' "$SS_LIB"
if assert_mutated "$SS_LIB" "$SRC_SECTION_SCOPE" "lib 変異: フェンス開始の無効化"; then
  run_section_scope "$SS_FENCED" "## 節A" "fenced-backtick"
  if [[ "$SS_RC" -eq 1 ]]; then
    ok "lib 変異: フェンス追跡を壊すとフェンス内の見出し例示で節が切れて赤（rc=1）"
  else
    bad "lib 変異: フェンス追跡を壊しても緑のまま（rc=${SS_RC}）— 状態機械の回帰が効いていない"
  fi
  run_section_scope_count "$SS_FENCED" "## フェンス内の見出し例示"
  if [[ "$SS_RC" -eq 0 && "$SS_OUT" == "1" ]]; then
    ok "lib 変異: フェンス追跡を壊すと見出し本数がフェンス内の例示を 1 本と数えて赤"
  else
    bad "lib 変異: フェンス追跡を壊しても見出し本数が変わらない（rc=${SS_RC}: ${SS_OUT}）"
  fi
fi
cp "$SRC_SECTION_SCOPE" "$SS_LIB"

# 変異 2: EOF の未閉じフェンス検査を落とす（fail-open への復帰）。
drop_lines_containing "$SS_LIB" 'print "UNCLOSED_FENCE"'
if assert_mutated "$SS_LIB" "$SRC_SECTION_SCOPE" "lib 変異: 未閉じフェンス検査の削除"; then
  run_section_scope "$SS_UNCLOSED_AFTER" "## 節A" "針B"
  if [[ "$SS_RC" -eq 0 ]]; then
    ok "lib 変異: 未閉じフェンス検査を外すと別節の針を拾って緑になる（fail-open の再現。rc=0）"
  else
    bad "lib 変異: 未閉じフェンス検査を外しても rc=${SS_RC}（期待 0）— 変異が意図した経路に当たっていない"
  fi
fi
cp "$SRC_SECTION_SCOPE" "$SS_LIB"

# 変異 4: 散文モードの指定を無視する（フェンスを本文へ含めたまま返す）。
perl -pi -e 's{ && prose != 1\)}{)}g' "$SS_LIB"
if assert_mutated "$SS_LIB" "$SRC_SECTION_SCOPE" "lib 変異: 散文モードの無効化"; then
  run_section_scope_prose "$SS_FENCED" "## 節A"
  if prose_is_clean; then
    bad "lib 変異: 散文モードを無効にしても散文だけが返る — 検査が効いていない"
  else
    ok "lib 変異: 散文モードを無効にするとフェンスの中身が混ざって赤"
  fi
fi
cp "$SRC_SECTION_SCOPE" "$SS_LIB"

# 変異 3: 見出し本数のガードを「0 本だけ拒否」へ緩める（2 本以上を通す）。
perl -pi -e 's{\[ "\$heading_hits" -ne 1 \]}{[ "\$heading_hits" -lt 1 ]}' "$SS_LIB"
if assert_mutated "$SS_LIB" "$SRC_SECTION_SCOPE" "lib 変異: 見出し本数ガードの緩和"; then
  run_section_scope "$SS_DUP" "## 節A" "針2"
  if [[ "$SS_RC" -eq 0 ]]; then
    ok "lib 変異: 見出し本数ガードを緩めると同名見出しの節が連結されて緑になる（rc=0）"
  else
    bad "lib 変異: 見出し本数ガードを緩めても rc=${SS_RC}（期待 0）— 変異が意図した経路に当たっていない"
  fi
fi
cp "$SRC_SECTION_SCOPE" "$SS_LIB"

echo
if [[ "$FAIL" -gt 0 ]]; then
  echo "✗ section-scope-lib verify: $FAIL 件失敗 / $PASS 件成功" >&2
  REACHED_END=1
  exit 1
fi

echo "✓ section-scope-lib verify: 全 $PASS 件 pass"
REACHED_END=1
