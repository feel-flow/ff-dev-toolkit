#!/usr/bin/env bash
#
# changelog-digest.sh の回帰検査（Issue #947）。
#
# 固定する契約:
#   - 区間は from 排他・to 包含で、見出しと bullet 先頭 N 文字だけを出す
#   - to 省略時は最新の日付付き版を終端にする（[Unreleased] は選ばない）
#   - 存在しない版は「差分なし」ではなく非 0 で落ち、どちらの引数が解決
#     できなかったかを表示する（fail-closed）
#   - 逆区間（to が from より古い）も非 0 で落ちる
#   - 出力幅は FF_CHANGELOG_DIGEST_WIDTH で変更でき、切り詰めは UTF-8 の
#     文字境界で行う（多バイト文字の途中で切って文字化けさせない）
#   - 分類見出し（###）と本文散文は出力しない
#
# fixture は一時領域に組む（実 CHANGELOG に依存すると版が進むたびに壊れる）。
# bash 3.2 互換。

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DIGEST="$PLUGIN_ROOT/scripts/changelog-digest.sh"

if [[ ! -f "$DIGEST" ]]; then
  echo "✗ scripts/changelog-digest.sh が見つかりません（配布物に同梱されている前提）" >&2
  exit 1
fi

TMP="$(mktemp -d "${TMPDIR:-/tmp}/changelog-digest.XXXXXX")"

# 途中死が rc=0 に化けるのを防ぐ末尾到達センチネル（run-all case 12 の契約。
# 素の rm -rf トラップは途中死の exit code を握り潰す）。
REACHED_END=0
cleanup() {
  local rc=$?
  rm -rf "$TMP"
  if [[ "$REACHED_END" -ne 1 && "$rc" -eq 0 ]]; then
    rc=1
  fi
  exit "$rc"
}
trap cleanup EXIT
trap 'exit 130' HUP INT TERM

PASS=0
FAIL=0
ok()  { echo "  ✓ $1"; PASS=$((PASS + 1)); }
bad() { echo "  ✗ $1" >&2; FAIL=$((FAIL + 1)); }

FIX="$TMP/CHANGELOG.md"
cat > "$FIX" <<'FIXTURE'
# Changelog

## 運用

- 説明の散文は出力されない

## [Unreleased]

- 未リリースの bullet は to 省略時にも出力されない

## [0.3.0] - 2026-08-30

### 追加

- 短い bullet
- とても長い日本語の bullet で切り詰め境界の検査に使う一二三四五六七八九十一二三四五六七八九十

## [0.2.0] - 2026-08-20

### 修正

- 中間の版の bullet

## [0.1.0] - 2026-08-10

### 追加

- 最初の版の bullet（from 排他なので出力されない）
FIXTURE

run_digest() {
  set +e
  OUT="$(FF_CHANGELOG_DIGEST_FILE="$FIX" bash "$DIGEST" "$@" 2>&1)"
  RC=$?
  set -e
}

echo "== changelog-digest =="

# ---- 1. 基本区間（from 排他・to 包含） ----------------------------------------
run_digest 0.1.0 0.3.0
if [[ "$RC" -eq 0 ]] \
  && [[ "$OUT" == *"[0.3.0]"* && "$OUT" == *"[0.2.0]"* ]] \
  && [[ "$OUT" != *"[0.1.0]"* && "$OUT" != *"最初の版"* ]] \
  && [[ "$OUT" == *"中間の版の bullet"* ]]; then
  ok "from 排他・to 包含の区間で見出しと bullet を出力する"
else
  bad "基本区間の出力が不正（rc=${RC}）: ${OUT}"
fi

# ---- 2. 分類見出し・散文・Unreleased を含めない -------------------------------
if [[ "$OUT" != *"### "* && "$OUT" != *"散文は出力されない"* && "$OUT" != *"Unreleased"* ]]; then
  ok "分類見出し・散文・Unreleased は出力しない"
else
  bad "出力に余計な行が混ざる: ${OUT}"
fi

# ---- 3. to 省略は最新の日付付き版（Unreleased を選ばない） --------------------
run_digest 0.2.0
if [[ "$RC" -eq 0 && "$OUT" == *"[0.3.0]"* && "$OUT" != *"未リリース"* && "$OUT" != *"[0.2.0]"* ]]; then
  ok "to 省略時は最新の日付付き版が終端になる"
else
  bad "to 省略の挙動が不正（rc=${RC}）: ${OUT}"
fi

# ---- 4. 存在しない版は fail-closed（どちらの引数かを名指し） ------------------
run_digest 9.9.9 0.3.0
if [[ "$RC" -ne 0 && "$OUT" == *"from-version"* && "$OUT" == *"9.9.9"* ]]; then
  ok "存在しない from は非 0 + from-version を名指しして落ちる"
else
  bad "存在しない from の扱いが不正（rc=${RC}）: ${OUT}"
fi
run_digest 0.1.0 8.8.8
if [[ "$RC" -ne 0 && "$OUT" == *"to-version"* && "$OUT" == *"8.8.8"* ]]; then
  ok "存在しない to は非 0 + to-version を名指しして落ちる"
else
  bad "存在しない to の扱いが不正（rc=${RC}）: ${OUT}"
fi

# ---- 5. 逆区間は非 0 ----------------------------------------------------------
run_digest 0.3.0 0.1.0
if [[ "$RC" -ne 0 && "$OUT" == *"区間が逆"* ]]; then
  ok "逆区間は非 0 で落ちる"
else
  bad "逆区間の扱いが不正（rc=${RC}）: ${OUT}"
fi

# ---- 6. 幅の変更と UTF-8 文字境界の切り詰め -----------------------------------
set +e
OUT="$(FF_CHANGELOG_DIGEST_FILE="$FIX" FF_CHANGELOG_DIGEST_WIDTH=20 bash "$DIGEST" 0.2.0 0.3.0 2>&1)"
RC=$?
set -e
long_line="$(printf '%s\n' "$OUT" | grep "とても長い" || true)"
if [[ "$RC" -eq 0 && -n "$long_line" && "$long_line" == *"…"* ]]; then
  ok "FF_CHANGELOG_DIGEST_WIDTH で切り詰め幅を変更できる（超過時は … 付き）"
else
  bad "幅変更の挙動が不正（rc=${RC}）: ${OUT}"
fi
# 文字境界: 出力を UTF-8 として再解釈して不正バイトが無いこと
# （捨て先を /dev/null にしない — macOS 26 の BSD iconv は /dev/null 宛てだと
#   多バイト文字が 1024 バイト境界をまたぐ valid な入力で rc=1 を返す）
if printf '%s\n' "$OUT" | iconv -f UTF-8 -t UTF-8 >"$TMP/iconv-sink.bin" 2>&1; then
  ok "切り詰めが UTF-8 の文字境界を壊さない（iconv 再解釈が通る）"
else
  bad "切り詰めで不正な UTF-8 バイト列が生じている"
fi

# ---- 7. 引数なしは usage + 非 0 ------------------------------------------------
run_digest
if [[ "$RC" -ne 0 && "$OUT" == *"使い方"* ]]; then
  ok "引数なしは usage を出して非 0"
else
  bad "引数なしの扱いが不正（rc=${RC}）"
fi

# ---- 8. ERE メタ文字入りの版指定は形式エラーで落ちる ---------------------------
# VER_RE を末尾までアンカーしないと `0.1.0|0.3.0` が交代として grep -E へ混入し、
# 存在しない版でも別の見出しに当たって rc=0 になる（code-reviewer 実測の退行防止）
run_digest '0.1.0|0.3.0' 0.3.0
if [[ "$RC" -ne 0 && "$OUT" == *"形式が不正"* ]]; then
  ok "ERE メタ文字入りの版指定は形式エラーで落ちる（パターン混入を防ぐ）"
else
  bad "ERE メタ文字入りの版指定が通ってしまう（rc=${RC}）: ${OUT}"
fi

# ---- 9. CHANGELOG の自動解決（override なし・公開 checkout 配置） --------------
# 全ケースを FF_CHANGELOG_DIGEST_FILE で回すと候補チェーンが一度も走らない。
# 公開 checkout 配置（root に CHANGELOG.md / plugins/ff-dev-toolkit/scripts/ に
# スクリプト）を一時領域へ組み、override なしで解決できることを固定する
AUTO="$TMP/public-layout"
mkdir -p "$AUTO/plugins/ff-dev-toolkit/scripts"
cp "$DIGEST" "$AUTO/plugins/ff-dev-toolkit/scripts/changelog-digest.sh"
chmod +x "$AUTO/plugins/ff-dev-toolkit/scripts/changelog-digest.sh"
cp "$FIX" "$AUTO/CHANGELOG.md"
set +e
OUT="$(bash "$AUTO/plugins/ff-dev-toolkit/scripts/changelog-digest.sh" 0.1.0 0.3.0 2>&1)"
RC=$?
set -e
if [[ "$RC" -eq 0 && "$OUT" == *"[0.3.0]"* && "$OUT" == *"[0.2.0]"* ]]; then
  ok "公開 checkout 配置で override なしに CHANGELOG を自動解決する"
else
  bad "自動解決が失敗（rc=${RC}）: ${OUT}"
fi

echo
if [[ "$FAIL" -gt 0 ]]; then
  echo "✗ changelog-digest verify: ${FAIL} 件失敗 / ${PASS} 件成功" >&2
  REACHED_END=1
  exit 1
fi
echo "✓ changelog-digest verify: 全 ${PASS} 件 pass"
REACHED_END=1
exit 0
