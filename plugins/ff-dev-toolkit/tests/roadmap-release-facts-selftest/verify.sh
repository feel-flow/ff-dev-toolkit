#!/usr/bin/env bash
#
# tests/roadmap-release-facts/ の検出力を、隔離 fixture への変異注入で実測する（Issue #841）。
#
# 本体 suite はライブの docs/ を読むため「今は緑」しか言えない。ゲートを足した意味は
# 「壊れた記述を実際に落とせること」なので、壊し方ごとに赤を確認する。
#
# 固定する契約:
#   - 正常 fixture → exit 0
#   - 表の日付が CHANGELOG と違う → exit 1 / 「日付が CHANGELOG と食い違って」
#   - CHANGELOG に無い版が表にある → exit 1 / 「存在しない版」
#   - 表の中に現在値マーカー（← 現行）がある → exit 1 / 「現在値マーカー」
#   - 節見出し・フェンスが変わって抽出 0 件 → exit 1 / 「1 件も抽出できません」（fail-closed）
#   - ROADMAP が無い → 行頭 `○ skip` + exit 0（公開リポジトリ側の checkout）
#   - ROADMAP はあるが CHANGELOG が無い → exit 1（判定材料の欠落を緑にしない）
#   - **散文（フェンス外）のマーカー言及は緑**。禁止事項を説明する文が自分で赤を出さない
#     ことは、本体 suite の検出範囲を表の中へ限定した設計判断そのものなので固定する
#
# 検査本体が読むのは FF_DOCS_REPO_ROOT 配下だけで、ライブリポジトリは一切参照しない。

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
TESTS_DIR="$(cd "$SCRIPT_DIR/.." && pwd -P)"
TARGET="$TESTS_DIR/roadmap-release-facts/verify.sh"

if [ ! -f "$TARGET" ]; then
  echo "✗ 検査対象が見つかりません: $TARGET" >&2
  exit 1
fi

# mktemp の診断を捨てない（run-all case 15）。
# rc=0 でも -d を検査する — 2>&1 の合流は「成功 + stderr 警告」の環境で変数へ
# 警告文が混入し、以後の処理が原因不明の失敗に化けるため。
if _mktemp_out="$(mktemp -d "${TMPDIR:-/tmp}/roadmap-release-facts-selftest.XXXXXX" 2>&1)" && [ -d "$_mktemp_out" ]; then
  TMP="$_mktemp_out"
else
  echo "○ skip: 一時ディレクトリを作成できないため実行できません（検査は1件も実行されていません）"
  printf '  mktemp: %s\n' "$_mktemp_out"
  exit 0
fi

# 途中死が rc=0 に化けるのを防ぐ末尾到達センチネル。
REACHED_END=0
cleanup() {
  local rc=$?
  rm -rf "$TMP"
  if [ "$REACHED_END" -ne 1 ] && [ "$rc" -eq 0 ]; then
    echo "✗ selftest が末尾へ到達せずに終了しました（rc=0 への化けを防止）" >&2
    rc=1
  fi
  exit "$rc"
}
trap cleanup EXIT

PASS=0
FAIL=0
ok()  { echo "  ✓ $1"; PASS=$((PASS + 1)); }
bad() { echo "  ✗ $1" >&2; FAIL=$((FAIL + 1)); }

# ---- fixture ----------------------------------------------------------------
# $1=fixture ルート
build_fixture() {
  local root="$1"
  mkdir -p "$root/docs/07-project-management" "$root/oss/ff-dev-toolkit"

  cat > "$root/oss/ff-dev-toolkit/CHANGELOG.md" <<'CHANGELOG'
# Changelog

## [Unreleased]

## [0.3.0] - 2026-08-20

- third

## [0.2.0] - 2026-08-10

- second

## [0.1.0] - 2026-08-01

- first
CHANGELOG

  cat > "$root/docs/07-project-management/ROADMAP.md" <<'ROADMAP'
# ROADMAP

## 3. リリース計画

### バージョンロードマップ

主要版の抜粋（履歴）。現在どの版かはここに書かない。

```text
sample-plugin
├── v0.1.0  2026-08-01  first
├── v0.2.0  2026-08-10  second
└── v0.3.0  2026-08-20  third
```

### リリース手順の制約

- 省略
ROADMAP
}

# $1=説明 $2=期待 exit $3=期待メッセージ（空なら照合しない） $4=fixture ルート
expect_run() {
  local label="$1" want_rc="$2" want_msg="$3" root="$4"
  local out rc=0
  out="$(FF_DOCS_REPO_ROOT="$root" bash "$TARGET" 2>&1)" || rc=$?
  if [ "$rc" -ne "$want_rc" ]; then
    bad "$label: exit=${rc}（期待 ${want_rc}）"
    printf '%s\n' "$out" | sed 's/^/      /' >&2
    return
  fi
  # パイプ + `grep -q` は使わない（早期終了で上流が SIGPIPE を受ける既知の欠陥クラス。
  # run-all case 10 のガード対象）。部分一致は case のパターンマッチで済む。
  if [ -n "$want_msg" ]; then
    case "$out" in
      *"$want_msg"*) : ;;
      *)
        bad "$label: exit は期待どおりだが、メッセージに「${want_msg}」が含まれません"
        printf '%s\n' "$out" | sed 's/^/      /' >&2
        return
        ;;
    esac
  fi
  ok "$label"
}

echo "== A. 正常 fixture =="
A="$TMP/a"; build_fixture "$A"
expect_run "正常な表 → 緑" 0 "" "$A"

echo "== B. 変異注入（赤になること）=="

B1="$TMP/b1"; build_fixture "$B1"
perl -i -pe 's/v0\.2\.0  2026-08-10/v0.2.0  2026-08-11/' "$B1/docs/07-project-management/ROADMAP.md"
expect_run "日付のズレを検出" 1 "日付が CHANGELOG と食い違って" "$B1"

B2="$TMP/b2"; build_fixture "$B2"
perl -i -pe 's/^└── v0\.3\.0.*$/├── v0.3.0  2026-08-20  third\n└── v9.9.9  2026-08-30  ghost/' "$B2/docs/07-project-management/ROADMAP.md"
expect_run "CHANGELOG に無い版を検出" 1 "存在しない版" "$B2"

B3="$TMP/b3"; build_fixture "$B3"
perl -i -pe 's/(v0\.3\.0  2026-08-20  third)/$1 ← 現行/' "$B3/docs/07-project-management/ROADMAP.md"
expect_run "表の中の現在値マーカーを検出" 1 "現在値マーカー" "$B3"

B4="$TMP/b4"; build_fixture "$B4"
perl -i -pe 's/^### バージョンロードマップ$/### リリース一覧/' "$B4/docs/07-project-management/ROADMAP.md"
expect_run "節見出しの変更で抽出 0 件 → fail-closed" 1 "1 件も抽出できません" "$B4"

B5="$TMP/b5"; build_fixture "$B5"
perl -i -pe 's/^```text$/    text/' "$B5/docs/07-project-management/ROADMAP.md"
expect_run "フェンスの消失で抽出 0 件 → fail-closed" 1 "1 件も抽出できません" "$B5"

B6="$TMP/b6"; build_fixture "$B6"
rm -f "$B6/oss/ff-dev-toolkit/CHANGELOG.md"
expect_run "CHANGELOG 欠落を緑にしない" 1 "SSOT レイアウトなのに" "$B6"

# SSOT レイアウトで oss/ 側が欠けているとき、リポジトリ直下の別 CHANGELOG で
# 代替して緑になってはいけない（欠落を隠す経路）。
B7="$TMP/b7"; build_fixture "$B7"
rm -f "$B7/oss/ff-dev-toolkit/CHANGELOG.md"
cat > "$B7/CHANGELOG.md" <<'ROOTCL'
# Changelog

## [0.3.0] - 2026-08-20

- third

## [0.2.0] - 2026-08-10

- second

## [0.1.0] - 2026-08-01

- first
ROOTCL
expect_run "oss 欠落を直下の CHANGELOG で埋めない" 1 "SSOT レイアウトなのに" "$B7"

# 版を含む行が 1 行だけ壊れても、他行が拾えるので「抽出 0 件」の fail-closed は効かない。
# 行単位で解析漏れを赤にできているかを測る。
B8="$TMP/b8"; build_fixture "$B8"
perl -i -pe 's{v0\.2\.0  2026-08-10}{v0.2.0  2026/08/10}' "$B8/docs/07-project-management/ROADMAP.md"
expect_run "1 行だけの書式破損を未検査のまま緑にしない" 1 "解析できない行" "$B8"

# マーカーの言い換え。`← 現行` の 2 表記だけを弾く実装では素通りする形。
B9="$TMP/b9"; build_fixture "$B9"
perl -i -pe 's/(v0\.3\.0  2026-08-20  third)/$1（現行）/' "$B9/docs/07-project-management/ROADMAP.md"
expect_run "言い換えマーカー（現行）を検出" 1 "現在値マーカー" "$B9"

# 節内にフェンスが 2 つあると「どれが表か」が決まらない。連結して読むと、
# 表を消しても別フェンスの版で緑になれる。
B10="$TMP/b10"; build_fixture "$B10"
perl -i -pe 's{^### リリース手順の制約$}{```text\n補足のフェンス\n```\n\n### リリース手順の制約}' "$B10/docs/07-project-management/ROADMAP.md"
expect_run "節内の複数フェンスを曖昧なまま通さない" 1 "コードフェンスが" "$B10"

echo "== C. 検出範囲の限定（誤検知しないこと）=="

C1="$TMP/c1"; build_fixture "$C1"
rm -rf "$C1/docs"
expect_run "ROADMAP 不在 → skip" 0 "○ skip" "$C1"

C2="$TMP/c2"; build_fixture "$C2"
perl -i -pe 's/^主要版の抜粋（履歴）。現在どの版かはここに書かない。$/主要版の抜粋（履歴）。`← 現行` のような現在値マーカーは書かない（腐るため）。/' "$C2/docs/07-project-management/ROADMAP.md"
expect_run "散文でのマーカー言及は緑（検出範囲は表の中だけ）" 0 "" "$C2"

C3="$TMP/c3"; build_fixture "$C3"
cat >> "$C3/docs/07-project-management/ROADMAP.md" <<'EXTRA'

### 別の節

```text
├── v9.9.9  2026-12-31  ここは別節なので照合対象外
```
EXTRA
expect_run "別節（同レベル見出し）のフェンスは照合対象外" 0 "" "$C3"

# 節の終端を `### ` だけで判定していると、次章が `## ` のときに走査が止まらず、
# 無関係なフェンスをリリース表として読む（Issue #841 レビューで実測された誤検知）。
C4="$TMP/c4"; build_fixture "$C4"
perl -i -pe 's{^### リリース手順の制約$}{## 4. リソース計画}' "$C4/docs/07-project-management/ROADMAP.md"
cat >> "$C4/docs/07-project-management/ROADMAP.md" <<'EXTRA'

```text
├── v9.9.9  2026-12-31  別章のフェンス ← 現行
```
EXTRA
expect_run "上位レベル（## ）の次章で走査が止まる" 0 "" "$C4"

echo
echo "結果: pass=${PASS} fail=${FAIL}"
REACHED_END=1
[ "$FAIL" -eq 0 ] || exit 1
