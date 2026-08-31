#!/usr/bin/env bash
#
# changelog-digest.sh — バージョン区間の CHANGELOG 要約を出す（Issue #947）
#
# 複数版をまたいで更新した導入先が「何が変わったか」を読める粒度へ落とすためのヘルパー。
# 素の bullet 全文は数十 KB 規模になりエージェントのコンテキストにも載らないため、
# 指定区間の `## [x.y.z]` 見出しと、その配下の bullet 先頭 N 文字だけを出力する。
#
# 使い方:
#   scripts/changelog-digest.sh <from-version> [<to-version>]
#     <from-version>: 更新前の版（この版自体は出力に含めない = from 排他）
#     <to-version>  : 更新後の版（含める）。省略時は CHANGELOG の最新の日付付き版
#   環境変数:
#     FF_CHANGELOG_DIGEST_WIDTH: bullet の切り詰め幅（文字数。既定 95）
#     FF_CHANGELOG_DIGEST_FILE : CHANGELOG のパス（既定は自動解決 — 下記）
#
# CHANGELOG の自動解決: スクリプト自身の配置から、配布先（公開リポジトリ checkout:
# リポジトリ root の CHANGELOG.md）と SSOT（oss/ff-dev-toolkit/CHANGELOG.md）の
# 両配置を試す。どちらにも無ければ明示指定を促して終了する。
#
# fail-closed: 指定した版が CHANGELOG の見出しとして見つからない場合は「差分なし」
# ではなくエラーで落とし、どちらの引数が解決できなかったかを表示する
# （バージョン表記の揺れを黙って握り潰さない）。
#
# bash 3.2 互換。切り詰めは文字単位（awk の substr。CHANGELOG は正常な UTF-8 前提）。

set -euo pipefail

usage() {
  echo "使い方: $0 <from-version> [<to-version>]   （例: $0 0.41.0 0.57.0）" >&2
  echo "  <from-version> の版自体は含めず、それより新しい版から <to-version>（省略時は最新版）までを要約します" >&2
  exit 2
}

[[ $# -ge 1 && $# -le 2 ]] || usage
FROM="$1"
TO="${2:-}"
# 末尾までアンカーする: 前方一致だけだと `0.1.0|0.3.0` のような ERE メタ文字入りが
# 通り、grep -E パターンへ交代として混入して「存在しない版が別の見出しに当たって
# rc=0」になる（fail-closed 契約が破れる）。-rc1 等の接尾辞は許可する
VER_RE='^[0-9]+\.[0-9]+\.[0-9]+([-+][0-9A-Za-z.-]+)?$'
[[ "$FROM" =~ $VER_RE ]] || { echo "✗ from-version の形式が不正です: $FROM" >&2; exit 2; }
[[ -z "$TO" || "$TO" =~ $VER_RE ]] || { echo "✗ to-version の形式が不正です: $TO" >&2; exit 2; }

WIDTH="${FF_CHANGELOG_DIGEST_WIDTH:-95}"
[[ "$WIDTH" =~ ^[0-9]+$ && "$WIDTH" -ge 1 ]] || { echo "✗ FF_CHANGELOG_DIGEST_WIDTH は正の整数で指定してください: $WIDTH" >&2; exit 2; }

# ---- CHANGELOG の解決 ----------------------------------------------------------
if [[ -n "${FF_CHANGELOG_DIGEST_FILE:-}" ]]; then
  CHANGELOG="$FF_CHANGELOG_DIGEST_FILE"
  [[ -f "$CHANGELOG" ]] || { echo "✗ FF_CHANGELOG_DIGEST_FILE が存在しません: $CHANGELOG" >&2; exit 2; }
else
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
  CHANGELOG=""
  for cand in \
    "$script_dir/../../../CHANGELOG.md" \
    "$script_dir/../../../oss/ff-dev-toolkit/CHANGELOG.md"; do
    if [[ -f "$cand" ]]; then CHANGELOG="$cand"; break; fi
  done
  [[ -n "$CHANGELOG" ]] || { echo "✗ CHANGELOG.md を自動解決できません。FF_CHANGELOG_DIGEST_FILE で明示してください" >&2; exit 2; }
fi

# ---- to 省略時は最新の日付付き版を採る ----------------------------------------
if [[ -z "$TO" ]]; then
  TO="$(grep -oE '^## \[[0-9]+\.[0-9]+\.[0-9]+[^]]*\]' "$CHANGELOG" | head -1 | sed -E 's/^## \[|\]$//g')" || TO=""
  [[ -n "$TO" ]] || { echo "✗ CHANGELOG に日付付き版見出しが見つかりません: $CHANGELOG" >&2; exit 1; }
fi

# ---- 版見出しの実在を fail-closed で確認 ---------------------------------------
grep -qE "^## \[$(printf '%s' "$FROM" | sed 's/\./\\./g')\]" "$CHANGELOG" \
  || { echo "✗ from-version が CHANGELOG の版見出しに見つかりません: ${FROM}（表記の揺れを確認してください）" >&2; exit 1; }
grep -qE "^## \[$(printf '%s' "$TO" | sed 's/\./\\./g')\]" "$CHANGELOG" \
  || { echo "✗ to-version が CHANGELOG の版見出しに見つかりません: ${TO}（表記の揺れを確認してください）" >&2; exit 1; }

# ---- 区間の妥当性（CHANGELOG は新しい順 = to が from より先に現れること） ------
TO_LINE="$(grep -nE "^## \[$(printf '%s' "$TO" | sed 's/\./\\./g')\]" "$CHANGELOG" | head -1 | cut -d: -f1)"
FROM_LINE="$(grep -nE "^## \[$(printf '%s' "$FROM" | sed 's/\./\\./g')\]" "$CHANGELOG" | head -1 | cut -d: -f1)"
[[ "$TO_LINE" -lt "$FROM_LINE" ]] \
  || { echo "✗ 区間が逆です: to（${TO}）は from（${FROM}）より新しい版を指定してください" >&2; exit 1; }

# ---- 要約の出力 ----------------------------------------------------------------
# from 見出しは含めない（from 排他・to 包含）。見出しはそのまま、bullet は
# 先頭 WIDTH 文字 + 超過時は … を付けて出力する。分類見出し（###）は省く。
# 切り詰めは LC_ALL=C のバイト走査で UTF-8 の文字境界を数える（locale 依存の
# length/substr に任せると、mawk 等のバイト単位実装で多バイト文字の途中を
# 切って文字化けする — 継続バイト 0x80-0xBF 以外を文字の先頭として数える）。
LC_ALL=C awk -v to_line="$TO_LINE" -v from_line="$FROM_LINE" -v width="$WIDTH" '
  function chartrunc(s, w,   i, n, cnt, ch) {
    n = length(s); cnt = 0; i = 1
    while (i <= n) {
      ch = substr(s, i, 1)
      if (ch < "\200" || ch >= "\300") {   # 継続バイト以外 = 文字の先頭
        cnt++
        if (cnt > w) return substr(s, 1, i - 1) "…"
      }
      i++
    }
    return s
  }
  NR < to_line { next }
  NR >= from_line { exit }
  /^## \[/ { print; next }
  /^- / { print chartrunc($0, width) }
' "$CHANGELOG"
