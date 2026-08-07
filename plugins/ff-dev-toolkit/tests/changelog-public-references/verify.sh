#!/usr/bin/env bash
#
# 公開 CHANGELOG に、公開側から辿れない SSOT の Issue / PR 番号参照を残さない。
# SSOT モノレポと公開 checkout の両方から実行でき、read-only 環境でも動作する。

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
REPO_ROOT="$(cd "$PLUGIN_ROOT/../.." && pwd)"

CHANGELOG=""
if [[ -f "$REPO_ROOT/oss/ff-dev-toolkit/CHANGELOG.md" ]]; then
  CHANGELOG="$REPO_ROOT/oss/ff-dev-toolkit/CHANGELOG.md"
elif [[ -f "$REPO_ROOT/CHANGELOG.md" ]]; then
  CHANGELOG="$REPO_ROOT/CHANGELOG.md"
else
  echo "✗ CHANGELOG.md not found (looked under oss/ff-dev-toolkit/ and repo root)" >&2
  exit 1
fi

# 禁止形式:
#   - Issue / PR に続く番号（# の有無を問わない）
#   - # に続く番号だけの短縮参照
# バージョン番号・公開タグ・compare URL は対象外。grep 自体の異常を「一致なし」と
# 読まないよう、rc=1 だけを参照なしとして扱う。
set +e
MATCHES="$(grep -En '(^|[^[:alnum:]_])(Issue|PR)[[:space:]]*#?[0-9]+|(^|[^[:alnum:]_])#[0-9]+' "$CHANGELOG")"
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
