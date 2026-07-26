#!/usr/bin/env bash
#
# CHANGELOG 末尾の比較リンクが公開タグに追従しているかの drift 検査（Issue #161）。
#
# 背景: PR #160（Issue #155）のレビューで、[Unreleased] の compare 起点が
# 6 リリース分古いタグを指したまま + 実在する 7 タグ分のリンク行が欠落している
# ことが判明した。本 suite はこの drift クラスを機械検査で固定する。
#
# 3検査（すべて公開リポジトリの実タグと突き合わせる fail-closed 検査）:
#   A. [Unreleased] の compare 起点が、公開リポジトリに実在する最新タグと一致する
#   B. 各リンク行を個別のレコード（ラベル・compare元・compare先）として解析し、
#      compare先（releases/tag 形式ならそのタグ）がラベルと一致すること、
#      compare元・先の両方が実タグとして実在すること、URL がどちらの形式にも
#      合致しない行が無いことを検査する（トークンを集合に潰さない。集合化すると
#      「他の行に有効なタグがあれば壊れた行を見逃す」drift を見逃す）
#   C. 実タグを持つ版（## [X.Y.Z] 見出し）に対応するラベルのリンク行が存在する
#      （行の中身が壊れていても「存在」自体は満たせば C は通る。中身の妥当性は B の担当）
#
# バージョン表記は changelog-version/verify.sh と同じ受理範囲
# （[0-9]+.[0-9]+.[0-9]+ + 任意の接尾辞）を見出し・ラベル側で使う。ここを
# CHANGELOG.md の実際の受理範囲より狭くすると、接尾辞付きの見出し/ラベルが
# 検査対象から静かに漏れる（過去に実際に再現した: 見出し用正規表現の閉じ
# `]` 欠如で `for` の unquoted word-splitting に巻き込まれ、実在タグと
# 一致せず continue で握り潰されていた）。
#
# ネットワーク依存: 公開リポジトリへの到達を git ls-remote で試み、失敗時は
# 標準エラー出力の内容で「接続不可（DNS・タイムアウト等）」と「それ以外
# （リポジトリ削除・認証失敗・プロトコルエラー等）」を分類する:
#   - 接続不可と判定できた場合のみ suite 全体を ○ skip する（run-all.sh の契約:
#     一部の検査だけを飛ばす「部分 skip」でこのマーカーを出すと、実際に走った
#     検査の結果まで suite 全体が skip 扱いに巻き込まれ report から消える。
#     本 suite は全検査がタグ取得結果に依存するため、丸ごと未実行が正しい
#     skip 粒度）
#   - それ以外（分類できないものを含む。未知のエラーを skip 側のデフォルトに
#     すると「ずっと skip のまま気づかれない」drift を再導入するため、
#     分類不能は fail 側にデフォルトする）は fail にする
#   - 到達できたのに v* タグが1件も取得できない場合も同様に fail（タグ命名
#     規則の変更などネットワーク要因ではない異常の検出）
#   注意: リポジトリの改名（例: dev-toolkit → ff-dev-toolkit のような URL
#   変更）は GitHub 側のリダイレクトが効くため、この検査だけでは検出できない
#   既知の限界。
#
# GIT_TERMINAL_PROMPT=0 は端末プロンプトを、GIT_ASKPASS=false は GUI askpass
# をそれぞれ即失敗にする（scripts/check-dev-toolkit-sync-drift.sh と同じ理由:
# GIT_TERMINAL_PROMPT だけでは GUI askpass 経由のハングを防げない）。
# http.lowSpeedLimit/lowSpeedTime は転送が始まってから停滞した場合の概ねの
# 上限であり、DNS/TCP接続自体のハングは縛れない（stock macOS に timeout(1)
# が無いため、外部コマンドでの厳密なハードタイムアウトは付けていない）。
#
# CHANGELOG.md の探索先が2箇所あるのは、本スクリプトが SSOT（このモノレポの
# oss/ff-dev-toolkit/CHANGELOG.md）と公開ミラー（sync-dev-toolkit-to-public.sh
# が oss/* を repo root へ展開するため、公開側では CHANGELOG.md が repo root
# に来る）の両方から実行され得るため。
#
# 既知の限界（恒久対応は Issue #163 で追跡）: sync-dev-toolkit 手順はタグ・
# Release の作成のみを行い、CHANGELOG の [Unreleased] 起点・リンク行の更新は
# 行わない。そのため新規タグが公開された直後は本 suite が必ず red になる。
# この red は #163 の手順が入るまでは想定内 — 検査自体を無効化しないこと
# （ACE-160-3: 既定で赤いゲートは「赤を無視する運用」を生み、ゲートとして
# 機能しなくなる）。
#
# 一時ファイル / heredoc・here-string は使わない（read-only 環境対応。ACE-86-2）。
#
# テスト用 env（通常は未設定のまま使う。設定時は ⚠ を stderr に出す）:
#   FF_CHANGELOG_LINKS_FILE       CHANGELOG.md の代わりに検査するファイル
#   FF_CHANGELOG_LINKS_REPO_URL   公開リポジトリの clone URL 上書き
#                                 （ローカルパスも可。tests/changelog-links-selftest/
#                                 が bare リポジトリ fixture で本 suite 自体を検証する）
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
REPO_ROOT="$(cd "$PLUGIN_ROOT/../.." && pwd)"

REMOTE_URL="${FF_CHANGELOG_LINKS_REPO_URL:-https://github.com/feel-flow/ff-dev-toolkit.git}"
if [[ -n "${FF_CHANGELOG_LINKS_REPO_URL:-}" ]]; then
  echo "⚠ FF_CHANGELOG_LINKS_REPO_URL で検査対象リポジトリを差し替えています: $REMOTE_URL" >&2
fi

CHANGELOG=""
if [[ -n "${FF_CHANGELOG_LINKS_FILE:-}" ]]; then
  CHANGELOG="$FF_CHANGELOG_LINKS_FILE"
  echo "⚠ FF_CHANGELOG_LINKS_FILE で検査対象を差し替えています: $CHANGELOG" >&2
elif [[ -f "$REPO_ROOT/oss/ff-dev-toolkit/CHANGELOG.md" ]]; then
  CHANGELOG="$REPO_ROOT/oss/ff-dev-toolkit/CHANGELOG.md"
elif [[ -f "$REPO_ROOT/CHANGELOG.md" ]]; then
  CHANGELOG="$REPO_ROOT/CHANGELOG.md"
else
  echo "✗ CHANGELOG.md not found (looked under oss/ff-dev-toolkit/ and repo root)" >&2
  exit 1
fi

[[ -f "$CHANGELOG" ]] || { echo "✗ CHANGELOG.md not found: $CHANGELOG" >&2; exit 1; }

# ---- 公開タグの取得（接続不可のみ suite 丸ごと skip、それ以外は fail） ----------
if ! RAW_TAGS="$(GIT_TERMINAL_PROMPT=0 GIT_ASKPASS=false git \
    -c http.lowSpeedLimit=1000 -c http.lowSpeedTime=10 \
    ls-remote --refs --tags "$REMOTE_URL" 2>&1)"; then
  if printf '%s' "$RAW_TAGS" | grep -qiE \
      'could not resolve host|could not connect to server|connection (timed out|refused)|network is unreachable|operation timed out|empty reply from server|ssl connect error|failed to connect'; then
    echo "○ skip: 公開リポジトリ ($REMOTE_URL) へのネットワーク到達に失敗したためスキップ（本 suite の検査は1件も実行されていません）"
    echo "  詳細: $(printf '%s' "$RAW_TAGS" | head -c 300 | tr '\n' ' ')"
    exit 0
  fi
  echo "✗ 公開リポジトリ ($REMOTE_URL) からのタグ取得に失敗しました。単純なネットワーク到達不可ではない可能性があります（リポジトリの削除・認証設定の変更・プロトコルエラー等。分類不能なエラーは fail 側にデフォルトしています）" >&2
  echo "  詳細: $(printf '%s' "$RAW_TAGS" | head -c 300 | tr '\n' ' ')" >&2
  exit 1
fi

REAL_TAGS="$(printf '%s\n' "$RAW_TAGS" \
  | awk -F/ '{print $NF}' \
  | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' \
  | sed 's/^v//' \
  | sort -t. -k1,1n -k2,2n -k3,3n || true)"

if [[ -z "$REAL_TAGS" ]]; then
  echo "✗ $REMOTE_URL から SemVer 形式のタグが1件も取得できませんでした（リポジトリのタグ命名規則変更等の可能性。到達はできているためネットワーク要因ではなく fail にする）" >&2
  echo "  取得できた refs（先頭5件）: $(printf '%s\n' "$RAW_TAGS" | head -n 5 | tr '\n' ' ')" >&2
  exit 1
fi

MAX_REAL_TAG="$(printf '%s\n' "$REAL_TAGS" | tail -n 1)"
TAG_COUNT="$(printf '%s\n' "$REAL_TAGS" | wc -l | tr -d ' ')"

is_real_tag() {
  [[ $'\n'"$REAL_TAGS"$'\n' == *$'\n'"$1"$'\n'* ]]
}

PASS=0
FAIL=0
ok()  { echo "  ✓ $1"; PASS=$((PASS + 1)); }
bad() { echo "  ✗ $1" >&2; FAIL=$((FAIL + 1)); }

echo "公開タグ最新: v${MAX_REAL_TAG}（${REMOTE_URL}、${TAG_COUNT} 件取得）"

# ---- 検査A: [Unreleased] の起点 = 実タグの最大値 ------------------------------
UNRELEASED_LINE="$(grep -E '^\[Unreleased\]:' "$CHANGELOG" || true)"
if [[ -z "$UNRELEASED_LINE" ]]; then
  bad "[Unreleased] のリンク行が見つかりません"
else
  UNRELEASED_BASE="$(printf '%s\n' "$UNRELEASED_LINE" \
    | sed -E 's#.*/compare/v([0-9]+\.[0-9]+\.[0-9]+)\.\.\.HEAD.*#\1#')"
  if [[ "$UNRELEASED_BASE" == "$UNRELEASED_LINE" ]]; then
    bad "[Unreleased] の行が compare/vX.Y.Z...HEAD 形式ではありません: $UNRELEASED_LINE"
  elif [[ "$UNRELEASED_BASE" == "$MAX_REAL_TAG" ]]; then
    ok "[Unreleased] の起点 (v$UNRELEASED_BASE) が公開リポジトリの最新タグと一致"
  else
    bad "[Unreleased] の起点 (v$UNRELEASED_BASE) が公開リポジトリの最新タグ (v$MAX_REAL_TAG) と不一致"
  fi
fi

# ---- リンク行を個別レコードとして解析（検査B・Cで共有） ------------------------
# ラベルは changelog-version/verify.sh と同じ受理範囲（接尾辞許容）。
LINK_LINES="$(grep -E '^\[(Unreleased|[0-9]+\.[0-9]+\.[0-9]+[^]]*)\]:' "$CHANGELOG" || true)"

LABELS_WITH_ROW=""
ROW_BAD=0
ROW_ERR_MSGS=""

add_row_error() {
  ROW_BAD=$((ROW_BAD + 1))
  ROW_ERR_MSGS="$ROW_ERR_MSGS
      - $1"
}

OLD_IFS="$IFS"
IFS=$'\n'
set -- $LINK_LINES
IFS="$OLD_IFS"

for line in "$@"; do
  [[ -z "$line" ]] && continue
  if [[ "$line" =~ ^\[([^]]+)\]:\ *(.*)$ ]]; then
    label="${BASH_REMATCH[1]}"
    url="${BASH_REMATCH[2]}"
  else
    add_row_error "行の形式を解釈できません: $line"
    continue
  fi

  [[ "$label" == "Unreleased" ]] && continue  # Unreleased の中身は検査Aが担当
  LABELS_WITH_ROW="$LABELS_WITH_ROW $label"

  if [[ "$url" =~ /compare/v([0-9]+\.[0-9]+\.[0-9]+[^./]*)\.\.\.v([0-9]+\.[0-9]+\.[0-9]+[^./]*)$ ]]; then
    from="${BASH_REMATCH[1]}"
    to="${BASH_REMATCH[2]}"
    [[ "$to" == "$label" ]] || add_row_error "[$label]: compare先 (v$to) がラベルと不一致"
    is_real_tag "$to"   || add_row_error "[$label]: compare先タグ v$to が公開リポジトリに実在しない"
    is_real_tag "$from" || add_row_error "[$label]: compare元タグ v$from が公開リポジトリに実在しない"
  elif [[ "$url" =~ /releases/tag/v([0-9]+\.[0-9]+\.[0-9]+[^./]*)$ ]]; then
    to="${BASH_REMATCH[1]}"
    [[ "$to" == "$label" ]] || add_row_error "[$label]: releases/tag のバージョン (v$to) がラベルと不一致"
    is_real_tag "$to"   || add_row_error "[$label]: タグ v$to が公開リポジトリに実在しない"
  else
    add_row_error "[$label]: 既知の URL 形式（compare/vX...vY または releases/tag/vX）に一致しません: $url"
  fi
done

# ---- 検査B: 各リンク行のラベル・compare元・compare先が正しい -------------------
if [[ -z "$LINK_LINES" ]]; then
  bad "リンク行を1件も抽出できませんでした"
elif [[ "$ROW_BAD" -gt 0 ]]; then
  bad "リンク行に不整合が${ROW_BAD}件あります:${ROW_ERR_MSGS}"
else
  ok "全リンク行のラベル・compare元・compare先が公開リポジトリの実タグと整合している"
fi

# ---- 検査C: 実タグを持つ版にリンク行が欠けていない -----------------------------
HEADING_VERSIONS="$(grep -E '^## \[[0-9]+\.[0-9]+\.[0-9]+[^]]*\]' "$CHANGELOG" \
  | sed -E 's/^## \[([0-9]+\.[0-9]+\.[0-9]+[^]]*)\].*/\1/' || true)"

if [[ -z "$HEADING_VERSIONS" ]]; then
  bad "## [X.Y.Z] 形式のリリース見出しを1件も抽出できませんでした"
else
  has_link_row() {
    [[ " $LABELS_WITH_ROW " == *" $1 "* ]]
  }

  MISSING_ROWS=""
  for ver in $HEADING_VERSIONS; do
    is_real_tag "$ver" || continue
    if ! has_link_row "$ver"; then
      MISSING_ROWS="$MISSING_ROWS v$ver"
    fi
  done

  if [[ -z "$MISSING_ROWS" ]]; then
    ok "実タグを持つ全版にリンク行がある"
  else
    bad "実タグは存在するがリンク行が無い版:$MISSING_ROWS"
  fi
fi

echo ""
if [[ "$FAIL" -gt 0 ]]; then
  echo "✗ changelog-links verify: $FAIL 件失敗" >&2
  exit 1
fi
echo "✓ changelog-links verify: 全 $PASS 件 pass"
exit 0
