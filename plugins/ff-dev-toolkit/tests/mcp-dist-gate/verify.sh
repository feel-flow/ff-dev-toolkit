#!/usr/bin/env bash
#
# mcp-dist-gate: コミット済み dist/index.js が現在の src + 依存から再現できること、
# および stdio-only 不変条件を fail-closed で検査する。
#
# 背景 (Issue #211): 利用者の Claude Code で実際に動くのはコミット済み
# dist/index.js だが、lockfile だけ更新して再ビルドを忘れた変更は「脆弱性を
# 修正した」と主張しつつ脆弱なバンドルを配布し続ける。verify:dist は手動実行
# のみで、この対応を自動で保証するゲートが無かった。
#
# 検査:
#   A. 一時 outfile へフレッシュビルドし、コミット済み dist とバイト比較する。
#      作業ツリーの dist/ には書き込まない（run-all.sh の read-only 契約）。
#      前提: node_modules が現在の lockfile を反映していること（npm install 済み）。
#      lockfile を変えたのに npm install すら走っていない場合は検出できない —
#      その場合 vitest（mcp-vitest suite）も旧依存で走るため、二重に嘘をつく
#      状態は npm install の実行で初めて表面化する。
#   B. stdio-only 不変条件: 公開 CHANGELOG が「配布物に HTTP アダプタは含まれ
#      ない」と主張している。HTTP transport 系の識別子が dist に混入したら red。
#
# 決定性の注意: esbuild の出力は lockfile が固定する esbuild バージョンでのみ
# 安定する。lockfile 更新で esbuild が上がると、src 無変更でも A が red になり
# うる — それは「dist の再ビルド漏れ」と同じ対処（再ビルドしてコミット）で
# 解消するので、誤検知ではなく仕様である。
#
# node_modules が無い環境では検証本体を実行できないため、run-all.sh の契約
# どおり行頭 `○ skip` を出して exit 0 する。

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
MCP_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)/mcp"
DIST="$MCP_DIR/dist/index.js"

if [[ ! -d "$MCP_DIR/node_modules" ]]; then
  echo "○ skip: $MCP_DIR/node_modules が無いためスキップ（本 suite の検査は1件も実行されていません。cd mcp && npm install で有効化）"
  exit 0
fi

if [[ ! -f "$DIST" ]]; then
  echo "✗ コミット済み dist が存在しない: $DIST" >&2
  exit 1
fi

# 一時領域が書き込み不可の環境（read-only sandbox 等）では検証本体を実行でき
# ないため、契約どおり丸ごと skip する。実行開始後の失敗（esbuild エラー等）は
# 環境都合ではないので failed のまま。
# mktemp はテンプレート形式で呼ぶ（BSD/GNU/busybox すべてで有効）。`-t <prefix>`
# は GNU では XXXXXX 必須のためエラーになり、書き込み可能な Linux で「移植性バグ
# による skip」を「read-only 環境」と誤帰属させる（兄弟 suite docs-gates-runtime
# と同形に揃える）。
if ! TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/mcp-dist-gate.XXXXXX" 2>/dev/null)"; then
  echo "○ skip: 一時ディレクトリを作成できないためスキップ（本 suite の検査は1件も実行されていません。書き込み可能な環境で再実行してください）"
  exit 0
fi
trap 'rm -rf "$TMP_DIR"' EXIT
TMP_OUT="$TMP_DIR/index.js"

FAIL=0

# 事後条件の基準線: dist/ の状態を実行前に記録し、実行後は「変化」だけを検査する
# （dirty かどうかの絶対判定にすると、開発者の作業中変更を本 suite の書き込みと
# 誤帰属する）。git status は状態分類しか見ず「dirty なファイルへの上書き」を
# 見逃すため、内容ハッシュで比較する。
dist_state() {
  (cd "$MCP_DIR" && find dist -type f 2>/dev/null | LC_ALL=C sort | xargs shasum -a 256 2>/dev/null) || true
}
STATE_BEFORE="$(dist_state)"

# --- A. dist ↔ src+deps 一致 ---------------------------------------------
# ビルドコマンドは package.json の build スクリプトを正とし、outfile だけ
# 一時パスへ差し替える（フラグをここへ複製すると package.json 側の変更に
# 追従できず、ゲートが別物を検査するようになる）。差し替え先は環境変数参照に
# して、sh -c へ渡す文字列に一時パスを直接埋め込まない（TMPDIR に空白や
# メタ文字が含まれると引数分割・コマンド解釈が起きる）。
BUILD_CMD="$(node -pe 'require(process.argv[1] + "/package.json").scripts.build' "$MCP_DIR")"
case "$BUILD_CMD" in
  *"--outfile=dist/index.js"*) : ;;
  *)
    echo "✗ package.json の build スクリプトに --outfile=dist/index.js が見つからない（本 suite の差し替え前提が崩れた）: $BUILD_CMD" >&2
    exit 1
    ;;
esac
REBUILD_CMD="${BUILD_CMD//--outfile=dist\/index.js/--outfile=\"\$MCP_DIST_GATE_OUT\"}"

if [[ ! -x "$MCP_DIR/node_modules/.bin/esbuild" ]]; then
  echo "✗ node_modules はあるが esbuild が無い（npm install が不完全）: $MCP_DIR/node_modules/.bin/esbuild" >&2
  exit 1
fi

# ビルド失敗は FAIL に留めて検査 B へ進む（B はコミット済み dist の grep だけで
# ビルドに依存しない — 無関係な失敗で独立した検査を消さない）。出力は保持して
# 失敗時に見せる: ヘッダ既記のとおり esbuild bump 由来の red は設計上想定して
# おり、その診断材料を捨てない。
A_RAN=0
BUILD_OUT="$( (cd "$MCP_DIR" && PATH="$MCP_DIR/node_modules/.bin:$PATH" MCP_DIST_GATE_OUT="$TMP_OUT" sh -c "$REBUILD_CMD" 2>&1) )" && A_RAN=1 || true
if [[ "$A_RAN" != "1" ]]; then
  echo "✗ フレッシュビルドに失敗した（esbuild 実行エラー、末尾 20 行）:" >&2
  printf '%s\n' "$BUILD_OUT" | tail -20 >&2
  FAIL=1
fi

if [[ "$A_RAN" == "1" ]] && cmp -s "$TMP_OUT" "$DIST"; then
  echo "✓ dist/index.js は src + 現在の依存からのフレッシュビルドとバイト一致"
elif [[ "$A_RAN" == "1" ]]; then
  echo "✗ dist/index.js がフレッシュビルドと不一致 — src か lockfile を変えたのに dist を再ビルドしていない" >&2
  echo "  対処: cd plugins/ff-dev-toolkit/mcp && npm run build して dist をコミットする" >&2
  FAIL=1
fi

# --- B. stdio-only 不変条件 -----------------------------------------------
# 公開 CHANGELOG の主張（HTTP アダプタ非同梱）をコードで固定する。
# パターンは部分文字列の誤爆を避けるため具体的な識別子に限定する。
# grep の rc は 0（一致あり）/ 1（一致なし）/ 2 以上（grep 自体の異常）を分けて
# 扱う（changelog-public-references と同じ規約 — 異常を「一致なし」と読まない）。
B_FAIL=0
for PATTERN in 'serve-static' '@hono/node-server' 'StreamableHTTPServerTransport' 'SSEServerTransport'; do
  set +e
  COUNT="$(grep -c -F "$PATTERN" "$DIST")"
  GREP_RC=$?
  set -e
  if [[ $GREP_RC -ge 2 ]]; then
    echo "✗ stdio-only 検査で grep 自体が失敗した (rc=$GREP_RC, pattern='$PATTERN')" >&2
    B_FAIL=1
  elif [[ $GREP_RC -eq 0 ]]; then
    echo "✗ stdio-only 不変条件違反: dist に '$PATTERN' を含む行が $COUNT 行ある（HTTP 系の攻撃面が配布物に戻っている）" >&2
    B_FAIL=1
  fi
done
if [[ "$B_FAIL" == "0" ]]; then
  echo "✓ stdio-only 不変条件: HTTP transport 系識別子は dist に 0 件"
else
  FAIL=1
fi

# --- 事後条件: 作業ツリー（dist/）を書き換えていない ----------------------
STATE_AFTER="$(dist_state)"
if [[ "$STATE_AFTER" != "$STATE_BEFORE" ]]; then
  echo "✗ 本 suite の実行が dist/ を書き換えた（read-only 契約違反）" >&2
  FAIL=1
fi

if [[ "$FAIL" != "0" ]]; then
  echo "✗ mcp-dist-gate verify: 失敗あり" >&2
  exit 1
fi
echo "✓ mcp-dist-gate verify: 全検査 pass"
