#!/usr/bin/env bash
#
# 公開 CHANGELOG に、公開側から辿れない SSOT の Issue / PR 番号参照を残さない。
# SSOT モノレポと公開 checkout の両方から実行でき、read-only 環境でも動作する。
#
# テスト用 env（通常は未設定のまま使う。設定時は ⚠ を stderr に出す）:
#   FF_CHANGELOG_PUBLIC_REFERENCES_FILE  CHANGELOG.md の代わりに検査するファイル
#                                        （tests/changelog-public-references-selftest/
#                                        が fixture で本 suite 自体を検証する）

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
REPO_ROOT="$(cd "$PLUGIN_ROOT/../.." && pwd)"

CHANGELOG=""
if [[ -n "${FF_CHANGELOG_PUBLIC_REFERENCES_FILE:-}" ]]; then
  # テストシーム（selftest 専用。通常は未設定）。fixture を検査対象として渡す。
  # 差し替えは必ず可視化する（実 CHANGELOG を見ていない実行を緑と読み違えない）。
  CHANGELOG="$FF_CHANGELOG_PUBLIC_REFERENCES_FILE"
  echo "⚠ FF_CHANGELOG_PUBLIC_REFERENCES_FILE で検査対象を差し替えています: $CHANGELOG" >&2
  # 存在しないパスは「参照なし」ではなく失敗として扱う（fail-closed）。
  if [[ ! -f "$CHANGELOG" ]]; then
    echo "✗ FF_CHANGELOG_PUBLIC_REFERENCES_FILE が指すファイルがありません: $CHANGELOG" >&2
    exit 1
  fi
elif [[ -f "$REPO_ROOT/oss/ff-dev-toolkit/CHANGELOG.md" ]]; then
  CHANGELOG="$REPO_ROOT/oss/ff-dev-toolkit/CHANGELOG.md"
elif [[ -f "$REPO_ROOT/CHANGELOG.md" ]]; then
  CHANGELOG="$REPO_ROOT/CHANGELOG.md"
else
  echo "✗ CHANGELOG.md not found (looked under oss/ff-dev-toolkit/ and repo root)" >&2
  exit 1
fi

# 禁止形式:
#   - Issue / PR に続く番号（# の有無を問わない）
#   - # に続く番号（前に何が付いていても検出する）
# 2 つ目は前置の制限を持たない。以前は `#` の直前に非英数字を要求していたため、
# `example-org/example-repo#12` のような owner/repo#N 完全修飾参照が
# 「直前が英数字」で素通りしていた（`#` 自体が識別子文字ではないので、この制限は
# 短縮参照の検出には何も足していない）。既知のトレードオフとして、数字だけの
# URL フラグメント（`.../CHANGELOG.md#0440` 等）も検出対象に入る — 公開
# CHANGELOG に該当記載は無く、必要になった時点で除外を設計する。
# 1 つ目は `#` を伴わない `Issue 12` / `PR 12` の形のために残している。
# バージョン番号・公開タグ・compare URL は対象外。grep 自体の異常を「一致なし」と
# 読まないよう、rc=1 だけを参照なしとして扱う。
set +e
MATCHES="$(grep -En '(^|[^[:alnum:]_])(Issue|PR)[[:space:]]*#?[0-9]+|#[0-9]+' "$CHANGELOG")"
GREP_RC=$?
set -e

if [[ "$GREP_RC" -eq 0 ]]; then
  echo "✗ 公開 CHANGELOG に SSOT の Issue / PR 番号参照があります:" >&2
  printf '%s\n' "$MATCHES" >&2
  exit 1
fi
if [[ "$GREP_RC" -ne 1 ]]; then
  echo "✗ 公開 CHANGELOG の参照検査に失敗しました（grep rc=${GREP_RC}）: $CHANGELOG" >&2
  exit 1
fi

echo "✓ 公開 CHANGELOG に SSOT の Issue / PR 番号参照はありません"
echo "  CHANGELOG: $CHANGELOG"
