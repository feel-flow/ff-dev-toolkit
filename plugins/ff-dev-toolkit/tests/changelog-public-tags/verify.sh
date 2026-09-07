#!/usr/bin/env bash
#
# CHANGELOG が公開リポジトリの実タグと整合しているかの検査（Issue #161 / #332 / ADR-020）。
# 旧 changelog-links と旧 changelog-attribution を 1 suite へ統合した（Issue #1021）。
# 両者は「公開リポジトリの実タグを引く」「ネットワーク不達で ○ skip + exit 0」という
# 同じ入力・同じ skip 経路を持ち、分かれている理由が無かった。統合で検査は減らさず、
# 到達判定（= suite 全体 skip の唯一の分岐点）だけを 1 箇所へ寄せている。
#
# ── 第 1 部: footer の比較リンクが公開タグに追従しているかの drift 検査（Issue #161）
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
# GitHub Actions（GITHUB_ACTIONS=true）では照合対象を「checkout 時点の footer が知る版まで」に
# 閉じる（Issue #1336）:
#   公開同期の手順は「タグ push → footer 追従 PR → 収束 sync」の順なので、タグ push から
#   footer マージまでの窓に走った CI run（週次 run-all と同期サイクルの重なり）は、live の
#   タグ列と checkout 時点の footer を突き合わせる限り構造的に赤になる。これはリポジトリの
#   実害ではなく走行中の並行操作との競合なので、CI では footer のリンク行ラベルの最大値
#   （FOOTER_MAX）より新しい公開タグ 1 つを「checkout より新しい公開タグ」としてインデント
#   付き部分 skip で報告し、検査 A の期待起点と検査 C の対象から外す。footer が知る版までの
#   整合（起点不一致・リンク行の不整合・欠落）は従来どおり赤にする。
#   2 つ以上新しいタグがあれば CI でも赤にする — 同期手順は 1 サイクルにタグ 1 つを push し
#   次のサイクル前に footer を追従させるので、2 版以上の遅れは窓ではなく drift（旧 Issue #161
#   の形）である。
#   ローカル（GITHUB_ACTIONS 未設定）ではこの skip を入れない。同期手順 8 はタグ push 直後に
#   本 suite を走らせ、赤の内容で footer 追従を判定する（消費側: sync-dev-toolkit SKILL.md）。
#   ローカルで skip にすると「✓ を含む = 追従済み」の分岐が誤って成立し footer 追従が永久に
#   走らない。切替条件を check-version-claims.sh と同じ GITHUB_ACTIONS=true に揃えている。
#
# バージョン表記は changelog-contract/verify.sh と同じ受理範囲
# （[0-9]+.[0-9]+.[0-9]+ + 任意の接尾辞）を見出し・ラベル側で使う。ここを
# CHANGELOG.md の実際の受理範囲より狭くすると、接尾辞付きの見出し/ラベルが
# 検査対象から静かに漏れる（過去に実際に再現した: 見出し用正規表現の閉じ
# `]` 欠如で `for` の unquoted word-splitting に巻き込まれ、実在タグと
# 一致せず continue で握り潰されていた）。
#
# ── 第 2 部: 最新の日付付き版節の path-like マーカーの帰属検査（Issue #332 / ADR-020）
#
# 背景: Issue #331 で [0.25.0] に公開タグ v0.24.1 出荷済みの 24 項目が誤帰属していた。
# 第 1 部と changelog-contract はリンク端点と version 見出しだけを見て、
# 節の項目がその compare 範囲に属するかは見ない。第 2 部はその死角の**一部**を埋める。
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
#      → **第 2 部だけをインデント付き部分 skip**。タグ前の正常な開発周期で常時赤に
#      しない。統合前は suite 丸ごと ○ skip だったが、統合後は第 1 部の検査が同じ
#      入力で成立するため、丸ごと skip にすると第 1 部の結果まで報告から消える
#   6. 一時ディレクトリを作れない環境（read-only）も同じ理由で第 2 部だけ部分 skip
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
# ── ネットワーク依存（suite 全体 skip の分岐は下記 1 箇所だけ）────────────────
# 公開リポジトリへの到達を git ls-remote で 1 回だけ試み、失敗時は標準エラー出力の
# 内容で「接続不可（DNS・タイムアウト等）」と「それ以外（リポジトリ削除・認証失敗・
# プロトコルエラー等）」を分類する:
#   - 接続不可と判定できた場合のみ suite 全体を ○ skip する（run-all.sh の契約:
#     一部の検査だけを飛ばす「部分 skip」で行頭のこのマーカーを出すと、実際に走った
#     検査の結果まで suite 全体が skip 扱いに巻き込まれ report から消える。
#     到達できなければ第 1 部・第 2 部のどちらも成立しないため、この 1 箇所だけが
#     丸ごと未実行の正しい skip 粒度）
#   - それ以外（分類できないものを含む。未知のエラーを skip 側のデフォルトに
#     すると「ずっと skip のまま気づかれない」drift を再導入するため、
#     分類不能は fail 側にデフォルトする）は fail にする
#   - 到達できたのに v* タグが1件も取得できない場合も同様に fail（タグ命名
#     規則の変更などネットワーク要因ではない異常の検出）
#   第 2 部の tag fetch は**この到達判定の後**に走るため、そこでの失敗はもう
#   「ネットワーク不達」ではない = fail に倒す（skip 判定を二重に持たない）。
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
# 第 1 部が drift を報告して red になったときの直し方（Issue #163 で手順化）:
# 新規タグが公開された直後は [Unreleased] 起点とリンク行が実タグに追従していない
# （ローカル実行で赤になる。CI ではこの窓を上記の部分 skip にしている）。
# footer（CHANGELOG 末尾のリンク行群）に次の 2 点を反映すれば green に戻る:
#   1. [Unreleased] の compare 起点を、実タグの最大値へ更新する
#   2. リンク行が欠けている実タグごとに
#      [X.Y.Z]: .../compare/v<直前の実タグ>...vX.Y.Z を追加する
#      「直前の実タグ」は実タグを数値順に並べた列で 1 つ手前のものであり、
#      CHANGELOG 上の直前見出しではない（タグを打っていない版は飛ばす）。
#      最古のタグだけは compare を作れないため .../releases/tag/vX.Y.Z 形式。
# 検査自体を無効化したり `|| true` で黙らせたりしないこと（ACE-160-3: 既定で
# 赤いゲートは「赤を無視する運用」を生み、ゲートとして機能しなくなる）。
#
# 上記で直るのは検査A/B/C の指摘（`✗ changelog-public-tags verify: N 件失敗`）だけ。
# タグ取得失敗・SemVer タグ 0 件・CHANGELOG 不在の fail は検査が 1 件も走って
# いない異常なので、footer を触らず原因を調べること。
#
# SSOT 側には、公開同期の一連の手順にこの追従ステップを組み込んだ運用手順書が
# あるが、それは公開リポジトリには同期されない。公開側の読者は上のレシピだけで
# 復旧できる。
#
# 一時ファイル / heredoc・here-string は使わない（read-only 環境対応。ACE-86-2）。
# 例外は第 2 部の tag fetch 用 bare clone だけで、作成できない環境は部分 skip。
#
# テスト用 env（通常は未設定のまま使う。設定時は ⚠ を stderr に出す）:
#   FF_CHANGELOG_PUBLIC_TAGS_FILE      CHANGELOG.md の代わりに検査するファイル
#   FF_CHANGELOG_PUBLIC_TAGS_REPO_URL  公開リポジトリの clone URL 上書き
#                                      （ローカルパスも可。tests/changelog-public-tags-selftest/
#                                      が bare リポジトリ fixture で本 suite 自体を検証する）
#
# run-all-required: no — 公開リポジトリへのネットワーク到達に依存する。到達不能は環境の外側の事情なので必須の赤にしない
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
REPO_ROOT="$(cd "$PLUGIN_ROOT/../.." && pwd)"

REMOTE_URL="${FF_CHANGELOG_PUBLIC_TAGS_REPO_URL:-https://github.com/feel-flow/ff-dev-toolkit.git}"
if [[ -n "${FF_CHANGELOG_PUBLIC_TAGS_REPO_URL:-}" ]]; then
  echo "⚠ FF_CHANGELOG_PUBLIC_TAGS_REPO_URL で検査対象リポジトリを差し替えています: $REMOTE_URL" >&2
fi

CHANGELOG=""
if [[ -n "${FF_CHANGELOG_PUBLIC_TAGS_FILE:-}" ]]; then
  CHANGELOG="$FF_CHANGELOG_PUBLIC_TAGS_FILE"
  echo "⚠ FF_CHANGELOG_PUBLIC_TAGS_FILE で検査対象を差し替えています: $CHANGELOG" >&2
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

# ---- 公開タグの取得（接続不可のみ suite 丸ごと skip、それ以外は fail） ----------
# 統合前は第 1 部（ls-remote）と第 2 部（fetch）が同じ分類 grep を各自持っていた。
# 到達判定はここ 1 箇所だけにし、以降のネットワーク失敗は fail に倒す。
if ! RAW_TAGS="$(GIT_TERMINAL_PROMPT=0 GIT_ASKPASS=false git \
    -c http.lowSpeedLimit=1000 -c http.lowSpeedTime=10 \
    ls-remote --refs --tags "$REMOTE_URL" 2>&1)"; then
  if printf '%s' "$RAW_TAGS" | grep -iE \
      'could not resolve host|could not connect to server|connection (timed out|refused)|network is unreachable|operation timed out|empty reply from server|ssl connect error|failed to connect' >/dev/null; then
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
SKIPPED=0
ok()  { echo "  ✓ $1"; PASS=$((PASS + 1)); }
bad() { echo "  ✗ $1" >&2; FAIL=$((FAIL + 1)); }
skip_one() { echo "  · skip: $1"; SKIPPED=$((SKIPPED + 1)); }
# 環境都合の部分 skip。行頭マーカーは suite 全体 skip の意味になるため必ずインデントする
# （run-all.sh 冒頭ヘッダーの契約。ランナーは checks-skipped へ別集計する）。
skip_part() { echo "  ○ skip: $1"; }

# ---- checkout 時点の footer が知る最新版（照合の上限。ヘッダコメント参照） ------------
# 接尾辞付きラベルは順序を定義できないため上限の算出からは外す（検査 B の対象には残る。検査 C は元々 SemVer 厳密の実タグだけを見る）。
ver_lt() {
  # $1 < $2 （X.Y.Z の数値比較。here-string 禁止のため parameter expansion で分解する）
  local a1 a2 a3 b1 b2 b3 ra rb
  a1="${1%%.*}"; ra="${1#*.}"; a2="${ra%%.*}"; a3="${ra#*.}"
  b1="${2%%.*}"; rb="${2#*.}"; b2="${rb%%.*}"; b3="${rb#*.}"
  # 10# 接頭辞: 先頭 0 の成分を 8 進として読ませない（SemVer は先頭 0 を禁じるが fail-closed に）
  [[ "10#$a1" -lt "10#$b1" ]] && return 0
  [[ "10#$a1" -gt "10#$b1" ]] && return 1
  [[ "10#$a2" -lt "10#$b2" ]] && return 0
  [[ "10#$a2" -gt "10#$b2" ]] && return 1
  [[ "10#$a3" -lt "10#$b3" ]]
}

# [Unreleased] の compare 起点も「footer が知る版」に含める。footer 修正レシピの手順 1（起点更新）
# だけ先に入った checkout で、起点が指す新タグを「footer より新しい」扱いにすると検査 A が
# 起点不一致で赤になる（変更前は緑だった状態）。
FOOTER_MAX="$( { grep -E '^\[[0-9]+\.[0-9]+\.[0-9]+\]:' "$CHANGELOG" \
      | sed -E 's/^\[([0-9]+\.[0-9]+\.[0-9]+)\]:.*/\1/';
    grep -E '^\[Unreleased\]:.*/compare/v[0-9]+\.[0-9]+\.[0-9]+\.\.\.HEAD' "$CHANGELOG" \
      | sed -E 's#.*/compare/v([0-9]+\.[0-9]+\.[0-9]+)\.\.\.HEAD.*#\1#'; } \
  | sort -t. -k1,1n -k2,2n -k3,3n \
  | tail -n 1 || true)"

# footer より新しい公開タグ（CI でのみ照合対象外）。footer が無い・footer が公開タグ以上・
# ローカル実行なら空のまま = 従来どおり live のタグ列全体と照合する。
NEWER_TAGS=""
NEWER_COUNT=0
if [[ "${GITHUB_ACTIONS:-}" == true && -n "$FOOTER_MAX" ]]; then
  for t in $REAL_TAGS; do
    if ver_lt "$FOOTER_MAX" "$t"; then
      NEWER_TAGS="$NEWER_TAGS v$t"
      NEWER_COUNT=$((NEWER_COUNT + 1))
    fi
  done
fi
if [[ "$NEWER_COUNT" -gt 1 ]]; then
  # 窓ではなく drift。skip にせず live 照合へ戻す（検査 A/C が赤にする）
  NEWER_TAGS=""
fi
if [[ -n "$NEWER_TAGS" ]]; then
  EXPECTED_UNRELEASED_BASE="$FOOTER_MAX"
else
  EXPECTED_UNRELEASED_BASE="$MAX_REAL_TAG"
fi

is_newer_than_footer() {
  [[ " $NEWER_TAGS " == *" v$1 "* ]]
}

echo "公開タグ最新: v${MAX_REAL_TAG}（${REMOTE_URL}、${TAG_COUNT} 件取得）"
echo "CHANGELOG: $CHANGELOG"
if [[ -n "$NEWER_TAGS" ]]; then
  echo "footer が知る最新版: v${FOOTER_MAX}"
  skip_part "checkout より新しい公開タグ${NEWER_TAGS} は照合対象外（CI 限定。タグ push から footer 追従までの窓。footer が知る v${FOOTER_MAX} までを検査する）"
elif [[ "$NEWER_COUNT" -gt 1 ]]; then
  echo "footer が知る最新版: v${FOOTER_MAX}（公開タグが ${NEWER_COUNT} 版先行 = 窓ではなく drift。CI でも live 照合で赤にする）"
fi

# ================================ 第 1 部 =====================================
# ---- 検査A: [Unreleased] の起点 = 実タグの最大値 ------------------------------
UNRELEASED_LINE="$(grep -E '^\[Unreleased\]:' "$CHANGELOG" || true)"
if [[ -z "$UNRELEASED_LINE" ]]; then
  bad "[Unreleased] のリンク行が見つかりません"
else
  UNRELEASED_BASE="$(printf '%s\n' "$UNRELEASED_LINE" \
    | sed -E 's#.*/compare/v([0-9]+\.[0-9]+\.[0-9]+)\.\.\.HEAD.*#\1#')"
  if [[ "$UNRELEASED_BASE" == "$UNRELEASED_LINE" ]]; then
    bad "[Unreleased] の行が compare/vX.Y.Z...HEAD 形式ではありません: $UNRELEASED_LINE"
  elif [[ "$UNRELEASED_BASE" == "$EXPECTED_UNRELEASED_BASE" ]]; then
    if [[ -n "$NEWER_TAGS" ]]; then
      ok "[Unreleased] の起点 (v$UNRELEASED_BASE) が footer が知る最新版と一致（公開タグ最新 v$MAX_REAL_TAG は照合対象外）"
    else
      ok "[Unreleased] の起点 (v$UNRELEASED_BASE) が公開リポジトリの最新タグと一致"
    fi
  elif [[ -n "$NEWER_TAGS" ]]; then
    bad "[Unreleased] の起点 (v$UNRELEASED_BASE) が footer が知る最新版 (v$EXPECTED_UNRELEASED_BASE) と不一致"
  else
    bad "[Unreleased] の起点 (v$UNRELEASED_BASE) が公開リポジトリの最新タグ (v$MAX_REAL_TAG) と不一致"
  fi
fi

# ---- リンク行を個別レコードとして解析（検査B・Cで共有） ------------------------
# ラベルは changelog-contract/verify.sh と同じ受理範囲（接尾辞許容）。
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
    is_newer_than_footer "$ver" && continue  # 冒頭の部分 skip で報告済み
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

# ================================ 第 2 部 =====================================
# 途中死を沈黙させない。`set -u` 等で死んだとき、トラップ突入時の $? は **0** になるため、
# 終了ステータスを保存し直すだけでは足りない（実測）。「rc=0 なのに最後まで到達して
# いない」を中断として扱う。明示的な非 0 終了はそのまま通す。
TMP=""
FF_REACHED_END=0
_ff_exit_guard() {
  _ff_rc=$?
  [ -n "$TMP" ] && rm -rf "$TMP"
  if [ "$_ff_rc" -eq 0 ] && [ "$FF_REACHED_END" -ne 1 ]; then
    echo "✗ changelog-public-tags: 最後まで到達しませんでした（途中で中断）" >&2
    exit 1
  fi
  exit "$_ff_rc"
}
trap _ff_exit_guard EXIT

attribution_part() {
  # ---- 最新の日付付き版見出しと本文 -------------------------------------------
  # 先頭から最初の ## [x.y.z] を最新節とする（Unreleased は飛ばす）。
  local line NEWEST_VER="" NEWEST_BODY="" IN_SECTION=0 SECTION_LINES=""
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
    bad "帰属検査: 日付付き版見出し ## [x.y.z] が見つかりません: $CHANGELOG"
    return 0
  fi
  NEWEST_BODY="$SECTION_LINES"

  # ---- 当該版の compare リンク -----------------------------------------------
  # [X.Y.Z]: .../compare/vFROM...vTO
  local COMPARE_LINE COMPARE_URL="" FROM_TAG="" TO_TAG=""
  COMPARE_LINE="$(grep -E "^\[${NEWEST_VER//./\\.}\]:" "$CHANGELOG" || true)"
  if [[ -z "$COMPARE_LINE" ]]; then
    skip_part "帰属検査: 最新節 [$NEWEST_VER] に対応する compare リンク行が無いためスキップ（公開タグ前の開発周期では正常。リンクが付いたあと本検査が走る）"
    return 0
  fi

  # URL 部分を切り出して末尾まで完全一致させる（…/compare/vX...vY/garbage を受理しない）
  if [[ "$COMPARE_LINE" =~ ^\[[^]]+\]:[[:space:]]*(.+)$ ]]; then
    COMPARE_URL="${BASH_REMATCH[1]}"
  fi
  if [[ "$COMPARE_URL" =~ /compare/v([0-9]+\.[0-9]+\.[0-9]+[^./]*)\.\.\.v([0-9]+\.[0-9]+\.[0-9]+[^./]*)$ ]]; then
    FROM_TAG="${BASH_REMATCH[1]}"
    TO_TAG="${BASH_REMATCH[2]}"
  else
    bad "帰属検査: [$NEWEST_VER] のリンクが compare/vX...vY 形式ではありません: $COMPARE_LINE"
    return 0
  fi

  if [[ "$TO_TAG" != "$NEWEST_VER" ]]; then
    bad "帰属検査: [$NEWEST_VER] の compare 先 (v$TO_TAG) がラベルと不一致です: $COMPARE_LINE"
    return 0
  fi

  # ---- path-like マーカー抽出 ------------------------------------------------
  # 抽出失敗（awk 異常等）と「正常に 0 件」を分離する。失敗を || true で握らない。
  local PATHS PATH_COUNT
  PATHS="$(extract_paths "$NEWEST_BODY")"
  if [[ -z "$PATHS" ]]; then
    echo "  · 最新節 [$NEWEST_VER] に path-like マーカー無し（帰属検査の対象 0、compare: v${FROM_TAG}...v${TO_TAG}）"
    return 0
  fi
  PATH_COUNT="$(printf '%s\n' "$PATHS" | grep -c . || true)"

  # ---- 公開タグ 2 点を fetch -------------------------------------------------
  # mktemp の stderr を捨てない。捨てると read-only 以外の失敗（TMPDIR が不正な
  # パス・quota 超過など）まで「書き込み可能な環境で再実行してください」に誤帰属し、
  # 恒常的に壊れた TMPDIR が検査を無効化し続ける。2>&1 で受けると
  # 成功時はパス・失敗時は理由が同じ変数に入る。
  local _ff_mktemp_out
  # rc=0 でも -d を検査する — 2>&1 の合流は「成功 + stderr 警告」の環境で変数へ
  # 警告文が混入し、以後の処理が原因不明の失敗に化けるため。
  if _ff_mktemp_out="$(mktemp -d 2>&1)" && [ -d "$_ff_mktemp_out" ]; then
    TMP="$_ff_mktemp_out"
  else
    skip_part "帰属検査: 一時ディレクトリを作成できない環境のためスキップ（mktemp: ${_ff_mktemp_out}）"
    return 0
  fi

  local BARE="$TMP/tags.git"
  git init --bare -q "$BARE"

  local FETCH_ERR FETCH_RC
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

  # 到達判定は冒頭の ls-remote で済んでいる。ここまで来て失敗するのは
  # 「到達できるのにタグが取れない」= ネットワーク要因ではない異常なので fail に倒す。
  if [[ "$FETCH_RC" -ne 0 ]]; then
    bad "帰属検査: タグ v${FROM_TAG} / v${TO_TAG} の取得に失敗しました（${REMOTE_URL}）: $(printf '%s' "$FETCH_ERR" | head -c 300 | tr '\n' ' ')"
    return 0
  fi

  if ! git -C "$BARE" rev-parse -q --verify "refs/tags/v${FROM_TAG}" >/dev/null \
    || ! git -C "$BARE" rev-parse -q --verify "refs/tags/v${TO_TAG}" >/dev/null; then
    bad "帰属検査: fetch 後もタグ v${FROM_TAG} / v${TO_TAG} が揃っていません（${REMOTE_URL}）"
    return 0
  fi

  echo "最新節: [$NEWEST_VER]  compare: v${FROM_TAG}...v${TO_TAG}  markers: ${PATH_COUNT}"

  path_in_tag() {
    # $1=tag version without v, $2=path
    git -C "$BARE" cat-file -e "v${1}:${2}" 2>/dev/null
  }

  resolve_path() {
    # $1=changelog path token. stdout=resolved repo path or empty.
    local token="$1"
    local cand
    while IFS= read -r cand; do
      if path_in_tag "$TO_TAG" "$cand" || path_in_tag "$FROM_TAG" "$cand"; then
        printf '%s\n' "$cand"
        return 0
      fi
    done < <(changelog_path_candidates "$token")
    return 1
  }

  blob_id() {
    # $1=tag version, $2=path → blob sha or empty
    git -C "$BARE" rev-parse "v${1}:${2}" 2>/dev/null || true
  }

  # ACE-86-2: here-string は使わず、既に確保した TMP 上のファイルへ書く
  local token resolved in_from in_to from_blob to_blob
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
}

# backtick トークンのうち、スラッシュを含み path らしいものだけ。
# 除外: 先頭 -（フラグ）、先頭 /（スキル slash-command）、http、空白、<> を含むもの。
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../../scripts/lib" && pwd -P)/changelog-attribution-functions.sh"

attribution_part

echo ""
if [[ "$FAIL" -gt 0 ]]; then
  echo "✗ changelog-public-tags verify: $FAIL 件失敗（pass=${PASS} skip=${SKIPPED}）" >&2
  echo "  直し方: footer は実タグ一覧へ収束させる。帰属の指摘は該当 path を正しい版節へ移すか、当該 compare で本当に変わった path に backtick を直す" >&2
  exit 1
fi
echo "✓ changelog-public-tags verify: 全 $PASS 件 pass（skip=${SKIPPED}）"
FF_REACHED_END=1
exit 0
