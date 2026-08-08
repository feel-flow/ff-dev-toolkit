#!/usr/bin/env bash
#
# CHANGELOG 最新の日付付き版節に現れる path-like マーカーが、その節の
# compare リンク範囲で実際に追加・変更されているかを限定検査する（Issue #332 / ADR-020）。
#
# 背景: Issue #331 で [0.25.0] に公開タグ v0.24.1 出荷済みの 24 項目が誤帰属していた。
# changelog-links / changelog-version はリンク端点と version 見出しだけを見て、
# 節の項目がその compare 範囲に属するかは見ない。本 suite はその死角の**一部**を埋める。
#
# 設計（限定的・fail-closed だが常時赤にしない — ACE-172-2）:
#   1. 対象は**最新の日付付き版節だけ**（履歴全版は見ない。誤検知コストと運用負荷の抑止）
#   2. 検査するのは backtick 内の path-like トークンだけ
#      （`skills/...` / `scripts/...` / `tests/...` 等。スラッシュを含み、
#      フラグ・URL・スキル slash-command は除外）。散文 bullet 全体の意味理解はしない
#   3. 各 path が compare 元タグの tree に同一 blob のまま残っている（範囲で未変更）
#      なら misattribution として fail。追加・変更されていれば pass
#   4. path が from/to どちらの tree にも無い → 散文上の例示とみなしスキップ
#      （マーカー強制はしない。無い bullet は検査対象外 = 緑のまま）
#   5. 最新節に compare リンクが無い（未タグの plugin version だけ進んでいる等）
#      → suite 丸ごと ○ skip。タグ前の正常な開発周期で常時赤にしない
#
# red の直し方（同じ単位で設計 — ACE-172-2）:
#   - 指摘 path を、実際にその変更が入った版の節へ移す（#331 の手順）
#   - または backtick の path を、当該 compare 範囲で本当に変わった path に直す
#   - ゲート自体を無効化したり `|| true` で黙らせたりしないこと
#
# 公開リポジトリの path 解決:
#   CHANGELOG は読者向けに `scripts/foo.sh` のように短く書くことが多いが、
#   公開 git tree では `plugins/ff-dev-toolkit/scripts/foo.sh` に置かれる。
#   候補を順に試し、from または to に存在する最初の path を採用する。
#
# ネットワーク: 公開リポジトリから compare 端点の 2 タグを fetch する。
#   - 接続不可と判定できた場合のみ suite 丸ごと ○ skip
#   - それ以外（認証失敗・分類不能等）と、到達できたのにタグが取れない場合は fail
#   changelog-links と同じ分類方針（未知エラーを skip 側にデフォルトしない）。
#
# テスト用 env（通常は未設定。設定時は ⚠ を stderr に出す）:
#   FF_CHANGELOG_ATTRIBUTION_FILE      CHANGELOG.md の代わりに検査するファイル
#   FF_CHANGELOG_ATTRIBUTION_REPO_URL  公開リポジトリ URL / ローカル bare パス
#                                      （selftest が fixture で本 suite を検証する）
#
# 一時ファイルは read-only 環境を壊さないよう、タグ fetch 用の bare clone だけ
# mktemp する。作成できない環境は ○ skip。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
REPO_ROOT="$(cd "$PLUGIN_ROOT/../.." && pwd)"

REMOTE_URL="${FF_CHANGELOG_ATTRIBUTION_REPO_URL:-https://github.com/feel-flow/ff-dev-toolkit.git}"
if [[ -n "${FF_CHANGELOG_ATTRIBUTION_REPO_URL:-}" ]]; then
  echo "⚠ FF_CHANGELOG_ATTRIBUTION_REPO_URL で検査対象リポジトリを差し替えています: $REMOTE_URL" >&2
fi

CHANGELOG=""
if [[ -n "${FF_CHANGELOG_ATTRIBUTION_FILE:-}" ]]; then
  CHANGELOG="$FF_CHANGELOG_ATTRIBUTION_FILE"
  echo "⚠ FF_CHANGELOG_ATTRIBUTION_FILE で検査対象を差し替えています: $CHANGELOG" >&2
elif [[ -f "$REPO_ROOT/oss/ff-dev-toolkit/CHANGELOG.md" ]]; then
  CHANGELOG="$REPO_ROOT/oss/ff-dev-toolkit/CHANGELOG.md"
elif [[ -f "$REPO_ROOT/CHANGELOG.md" ]]; then
  CHANGELOG="$REPO_ROOT/CHANGELOG.md"
else
  echo "✗ CHANGELOG.md not found (looked under oss/ff-dev-toolkit/ and repo root)" >&2
  exit 1
fi
[[ -f "$CHANGELOG" ]] || { echo "✗ CHANGELOG.md not found: $CHANGELOG" >&2; exit 1; }

command -v git >/dev/null 2>&1 || { echo "✗ git が必要です" >&2; exit 1; }

# ---- 最新の日付付き版見出しと本文 ---------------------------------------------
# 先頭から最初の ## [x.y.z] を最新節とする（Unreleased は飛ばす）。
NEWEST_VER=""
NEWEST_BODY=""
IN_SECTION=0
SECTION_LINES=""
while IFS= read -r line || [[ -n "$line" ]]; do
  if [[ "$line" =~ ^##\ \[Unreleased\] ]]; then
    continue
  fi
  if [[ "$line" =~ ^##\ \[([0-9]+\.[0-9]+\.[0-9]+[^]]*)\] ]]; then
    if [[ -n "$NEWEST_VER" ]]; then
      break
    fi
    NEWEST_VER="${BASH_REMATCH[1]}"
    IN_SECTION=1
    SECTION_LINES=""
    continue
  fi
  if [[ "$IN_SECTION" -eq 1 ]]; then
    if [[ "$line" =~ ^\[Unreleased\]: ]] || [[ "$line" =~ ^\[[0-9]+\.[0-9]+\.[0-9]+ ]]; then
      # footer リンク行に入ったら節終了
      break
    fi
    SECTION_LINES="${SECTION_LINES}${line}"$'\n'
  fi
done < "$CHANGELOG"

if [[ -z "$NEWEST_VER" ]]; then
  echo "✗ 日付付き版見出し ## [x.y.z] が見つかりません: $CHANGELOG" >&2
  exit 1
fi
NEWEST_BODY="$SECTION_LINES"

# ---- 当該版の compare リンク -------------------------------------------------
# [X.Y.Z]: .../compare/vFROM...vTO
COMPARE_LINE="$(grep -E "^\[${NEWEST_VER//./\\.}\]:" "$CHANGELOG" || true)"
if [[ -z "$COMPARE_LINE" ]]; then
  echo "○ skip: 最新節 [$NEWEST_VER] に対応する compare リンク行が無いためスキップ"
  echo "  （公開タグ前の開発周期では正常。リンクが付いたあと本検査が走る）"
  echo "  CHANGELOG: $CHANGELOG"
  exit 0
fi

FROM_TAG=""
TO_TAG=""
# URL 部分を切り出して末尾まで完全一致させる（…/compare/vX...vY/garbage を受理しない）
COMPARE_URL=""
if [[ "$COMPARE_LINE" =~ ^\[[^]]+\]:[[:space:]]*(.+)$ ]]; then
  COMPARE_URL="${BASH_REMATCH[1]}"
fi
if [[ "$COMPARE_URL" =~ /compare/v([0-9]+\.[0-9]+\.[0-9]+[^./]*)\.\.\.v([0-9]+\.[0-9]+\.[0-9]+[^./]*)$ ]]; then
  FROM_TAG="${BASH_REMATCH[1]}"
  TO_TAG="${BASH_REMATCH[2]}"
else
  echo "✗ [$NEWEST_VER] のリンクが compare/vX...vY 形式ではありません: $COMPARE_LINE" >&2
  exit 1
fi

if [[ "$TO_TAG" != "$NEWEST_VER" ]]; then
  echo "✗ [$NEWEST_VER] の compare 先 (v$TO_TAG) がラベルと不一致です: $COMPARE_LINE" >&2
  exit 1
fi

# ---- path-like マーカー抽出 --------------------------------------------------
# backtick トークンのうち、スラッシュを含み path らしいものだけ。
# 除外: 先頭 -（フラグ）、先頭 /（スキル slash-command）、http、空白、<> を含むもの。
extract_paths() {
  # $1 = body text. stdout = one path per line, unique order-preserving.
  # awk の /.../ 区切りは class 内の / を終端と誤認するため、文字列マッチを使う。
  printf '%s' "$1" | awk '
    {
      s = $0
      while (match(s, /`[^`]+`/)) {
        tok = substr(s, RSTART + 1, RLENGTH - 2)
        s = substr(s, RSTART + RLENGTH)
        if (tok ~ /[[:space:]]/) continue
        if (tok ~ /^-/) continue
        if (tok ~ /^\//) continue
        if (tok ~ /^https?:/) continue
        if (tok ~ /[<>]/) continue
        if (index(tok, "/") == 0) continue
        if (tok !~ "^[A-Za-z0-9_./@+-]+$") continue
        if (!(tok in seen)) {
          seen[tok] = 1
          print tok
        }
      }
    }
  '
}

# 抽出失敗（awk 異常等）と「正常に 0 件」を分離する。失敗を || true で握らない。
PATHS="$(extract_paths "$NEWEST_BODY")"
if [[ -z "$PATHS" ]]; then
  echo "✓ changelog-attribution: 最新節 [$NEWEST_VER] に path-like マーカー無し（検査対象 0）"
  echo "  compare: v${FROM_TAG}...v${TO_TAG}"
  echo "  CHANGELOG: $CHANGELOG"
  exit 0
fi

PATH_COUNT="$(printf '%s\n' "$PATHS" | grep -c . || true)"

# ---- 公開タグ 2 点を fetch ---------------------------------------------------
if ! TMP="$(mktemp -d 2>/dev/null)"; then
  echo "○ skip: 一時ディレクトリを作成できない環境（read-only）のためスキップ"
  exit 0
fi
trap 'rm -rf "$TMP"' EXIT

BARE="$TMP/tags.git"
git init --bare -q "$BARE"

set +e
FETCH_ERR="$(
  GIT_TERMINAL_PROMPT=0 GIT_ASKPASS=false git -C "$BARE" \
    -c http.lowSpeedLimit=1000 -c http.lowSpeedTime=20 \
    fetch --depth 1 "$REMOTE_URL" \
    "refs/tags/v${FROM_TAG}:refs/tags/v${FROM_TAG}" \
    "refs/tags/v${TO_TAG}:refs/tags/v${TO_TAG}" 2>&1
)"
FETCH_RC=$?
set -e

if [[ "$FETCH_RC" -ne 0 ]]; then
  # changelog-links と同型: 真の接続不可だけ skip。
  # `unable to access` は Git の HTTP 403/401/404 等の共通 prefix なので入れない（ACE-164-1）。
  if printf '%s' "$FETCH_ERR" | grep -iE \
      'could not resolve host|could not connect to server|connection (timed out|refused)|network is unreachable|operation timed out|empty reply from server|ssl connect error|failed to connect' >/dev/null; then
    echo "○ skip: 公開リポジトリ ($REMOTE_URL) へのネットワーク到達に失敗したためスキップ"
    echo "  詳細: $(printf '%s' "$FETCH_ERR" | head -c 300 | tr '\n' ' ')"
    exit 0
  fi
  echo "✗ タグ v${FROM_TAG} / v${TO_TAG} の取得に失敗しました（${REMOTE_URL}）" >&2
  echo "  詳細: $(printf '%s' "$FETCH_ERR" | head -c 300 | tr '\n' ' ')" >&2
  echo "  （単純な接続不可ではない可能性があります。分類不能エラーは fail 側にデフォルトしています）" >&2
  exit 1
fi

# ローカル path のときもタグが揃っていることを確認
if ! git -C "$BARE" rev-parse -q --verify "refs/tags/v${FROM_TAG}" >/dev/null \
  || ! git -C "$BARE" rev-parse -q --verify "refs/tags/v${TO_TAG}" >/dev/null; then
  echo "✗ fetch 後もタグ v${FROM_TAG} / v${TO_TAG} が揃っていません（${REMOTE_URL}）" >&2
  exit 1
fi

# ---- path 解決と帰属判定 -----------------------------------------------------
path_in_tag() {
  # $1=tag version without v, $2=path
  git -C "$BARE" cat-file -e "v${1}:${2}" 2>/dev/null
}

resolve_path() {
  # $1=changelog path token. stdout=resolved repo path or empty.
  local token="$1"
  local cand
  for cand in \
    "$token" \
    "plugins/ff-dev-toolkit/${token}" \
    "plugins/ff-dev-toolkit/${token#./}"
  do
    if path_in_tag "$TO_TAG" "$cand" || path_in_tag "$FROM_TAG" "$cand"; then
      printf '%s\n' "$cand"
      return 0
    fi
  done
  return 1
}

blob_id() {
  # $1=tag version, $2=path → blob sha or empty
  git -C "$BARE" rev-parse "v${1}:${2}" 2>/dev/null || true
}

PASS=0
FAIL=0
SKIPPED=0
ok()  { echo "  ✓ $1"; PASS=$((PASS + 1)); }
bad() { echo "  ✗ $1" >&2; FAIL=$((FAIL + 1)); }
skip_one() { echo "  · skip: $1"; SKIPPED=$((SKIPPED + 1)); }

echo "最新節: [$NEWEST_VER]  compare: v${FROM_TAG}...v${TO_TAG}  markers: ${PATH_COUNT}"
echo "リポジトリ: $REMOTE_URL"
echo "CHANGELOG: $CHANGELOG"

# ACE-86-2: here-string は使わず、既に確保した TMP 上のファイルへ書く
printf '%s\n' "$PATHS" > "$TMP/paths.txt"
while IFS= read -r token || [[ -n "$token" ]]; do
  [[ -z "$token" ]] && continue
  resolved=""
  if ! resolved="$(resolve_path "$token")"; then
    skip_one "\`${token}\` は v${FROM_TAG}/v${TO_TAG} の tree に無い（例示扱いで検査しない）"
    continue
  fi

  in_from=0
  in_to=0
  path_in_tag "$FROM_TAG" "$resolved" && in_from=1
  path_in_tag "$TO_TAG" "$resolved" && in_to=1

  if [[ "$in_to" -eq 0 && "$in_from" -eq 1 ]]; then
    # 削除は「この版で変わった」ので帰属としては許容
    ok "\`${token}\` → ${resolved}: v${FROM_TAG} から削除（範囲内の変更）"
    continue
  fi

  # resolve_path は from/to のどちらかに存在する path だけ返す。
  # in_to==0 かつ in_from==0 は不変条件違反（到達しない想定）だが fail-closed にする。
  if [[ "$in_to" -eq 0 ]]; then
    bad "\`${token}\` → ${resolved}: to タグに存在せず from にも無い（解決後の不整合）"
    continue
  fi

  if [[ "$in_from" -eq 0 ]]; then
    ok "\`${token}\` → ${resolved}: v${TO_TAG} で新規追加"
    continue
  fi

  from_blob="$(blob_id "$FROM_TAG" "$resolved")"
  to_blob="$(blob_id "$TO_TAG" "$resolved")"
  if [[ -z "$from_blob" || -z "$to_blob" ]]; then
    bad "\`${token}\` → ${resolved}: blob 取得に失敗（検査不能を pass にしない）"
  elif [[ "$from_blob" == "$to_blob" ]]; then
    bad "\`${token}\` → ${resolved}: v${FROM_TAG} と v${TO_TAG} で同一 blob（compare 範囲で未変更 = 誤帰属の疑い）"
  else
    ok "\`${token}\` → ${resolved}: compare 範囲で内容が変更されている"
  fi
done < "$TMP/paths.txt"

echo ""
if [[ "$FAIL" -gt 0 ]]; then
  echo "✗ changelog-attribution verify: ${FAIL} 件失敗（pass=${PASS} skip=${SKIPPED}）" >&2
  echo "  直し方: 指摘 path を正しい版節へ移すか、当該 compare で本当に変わった path に backtick を直す" >&2
  exit 1
fi
echo "✓ changelog-attribution verify: 全 ${PASS} 件 pass（skip=${SKIPPED}）"
exit 0
