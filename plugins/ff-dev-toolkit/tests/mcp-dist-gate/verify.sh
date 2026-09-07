#!/usr/bin/env bash
#
# mcp-dist-gate: lockfile が全依存 edge を満たすこと、コミット済み dist/index.js が
# 現在の src + 依存から再現できること、および stdio-only 不変条件を fail-closed で検査する。
#
# 背景 (Issue #211): 利用者の Claude Code で実際に動くのはコミット済み
# dist/index.js だが、lockfile だけ更新して再ビルドを忘れた変更は「脆弱性を
# 修正した」と主張しつつ脆弱なバンドルを配布し続ける。verify:dist は手動実行
# のみで、この対応を自動で保証するゲートが無かった。
#
# 検査:
#   A0. package-lock.json とルートの依存宣言から依存木を組み（`npm ls --package-lock-only
#      --all`）、invalid / missing edge を node_modules に依存せず検出する。node_modules 不在の丸ごと skip より
#      前に走るので clean checkout でも赤になる。npm 不在では A0 だけ部分 skip。
#      node_modules が lockfile より古い状態は対象外（それは A の前提のまま）。
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
# shellcheck source=../lib/tree-state.sh
. "$SCRIPT_DIR/../lib/tree-state.sh"

# --- A0. lockfile が全依存 edge を満たす ------------------------------------
# `npm ls --package-lock-only --all` は node_modules を見ず、package-lock.json とルートの
# 依存宣言（package.json）から依存木を組み、満たされない edge（invalid / missing）が
# あれば非 0 で終わる（ネットワーク不要）。
# 不変条件: lockfile 内部の不整合は、それを許容する npm 版と `npm ci` で拒否する版が
# 混在すると「ローカル緑・CI 赤」の環境差になる。`npm ls --package-lock-only` は許容側の
# 版でも非 0 を返す（npm 10.9.8 / 11.16.0 で実測）ので、node_modules に依存せず早期に
# 検査するゲートにする。全 npm 版の `npm ci` 結果を保証するものではなく、npm 10 系の
# `npm ci` そのものは週次 CI（weekly-run-all の install step）が最終防衛線として担う。
# 発見経緯 (Issue #1325 / #1251): npm 11 の `npm install` が vitest 4 同梱 vite 8 の
# optional peer（esbuild ^0.27 || ^0.28）の入れ子 esbuild@0.28.2 を prune し、peer が
# root の esbuild 0.25.12 へ解決されて invalid になった。npm 11 では `npm ci` も vitest も
# 通るが、Node 22 同梱の npm 10.9 は edge を満たそうと再解決し「Missing: esbuild@0.28.2
# from lock file」(EUSAGE) で止まり、週次 CI で初めて赤になった。
# node_modules が lockfile より古い状態は対象外（それは A の前提のまま）。
# node_modules 不在の丸ごと skip より前に置く: lock だけを読む検査なので clean checkout
# でも走らせ、赤なら即 exit 1（後段が環境都合で skip する回でも lock の破れを緑にしない）。
# A のビルドは node と node_modules/.bin/esbuild、B は grep だけで完走できるため、npm
# 不在では A0 だけを部分 skip（インデントした `○ skip`。ランナーは checks-skipped へ
# 別集計し、suite 全体の skip とは区別する）にして A / B へ進む。
if ! command -v npm >/dev/null 2>&1; then
  echo "  ○ skip: npm が PATH に無いため lockfile 整合検査（A0）のみスキップ（A / B は実行する）"
elif [[ ! -f "$MCP_DIR/package-lock.json" ]]; then
  # npm ls は lockfile 不在も破損 JSON も ENOLOCK に畳む。不在はここで名指しし、
  # 後段の ENOLOCK を「lockfile はあるが読めない」に限定する。
  echo "✗ package-lock.json が無い: $MCP_DIR/package-lock.json（lockfile 整合を検査できない）" >&2
  exit 1
else
  # omit / depth は env・.npmrc で上書きされる（NODE_ENV=production は暗黙の omit=dev、
  # npm_config_depth=0 は --all を無効化）。どちらも dev 配下の invalid edge を見ずに
  # rc=0 を返す（実測）ので、CLI フラグで全 edge・全深さを固定する。--include=peer は
  # 付けない: 未充足の optional peer（vitest の browser/coverage 系など）まで UNMET として
  # 非 0 になり、整合した lockfile を赤にする（実測）。vite → esbuild のような peer edge は
  # --include=peer 無しでも invalid として検出される（実測）。
  set +e
  LS_OUT="$(cd "$MCP_DIR" && npm ls --package-lock-only --all --depth=Infinity --include=dev --include=optional 2>&1)"
  LS_RC=$?
  set -e
  if [[ $LS_RC -eq 0 ]]; then
    echo "✓ lockfile は全依存 edge を満たす（npm ls --package-lock-only --all）"
  elif [[ "$LS_OUT" == *ELSPROBLEMS* ]]; then
    echo "✗ lockfile が満たしていない依存 edge がある（npm ls --package-lock-only rc=${LS_RC}）— 旧 npm の npm ci は EUSAGE で止まる" >&2
    # 診断は invalid / missing / エラーコード行の先頭 20 行に絞る（依存木全体は長く原因行が
    # 埋もれる。`npm error A complete log ...` のログパス案内は除外）。抽出側が早期終了
    # すると上流 printf が SIGPIPE(141) で pipefail に落ちるため、行末の `|| true` は必須
    # （診断表示の失敗で対処案内まで失わせない）。
    printf '%s\n' "$LS_OUT" | awk '/ invalid: | missing: |ELSPROBLEMS|npm error (invalid|missing|code)/ { print; if (++n == 20) exit }' >&2 || true
    echo "  対処: root の devDependency 範囲を peer 範囲へ揃える等で不整合の元を消し、npm install → npm run build → dist をコミットする" >&2
    exit 1
  else
    # ENOLOCK（破損 JSON）・npm 自体の起動失敗など。edge 不整合と誤帰属すると「lockfile を
    # 直せ」と案内されて lockfile は正しい、という切り分け不能に陥るので別文言で止める。
    echo "✗ npm ls 自体が失敗し lockfile 整合を判定できない（rc=${LS_RC}、末尾 20 行）:" >&2
    printf '%s\n' "$LS_OUT" | tail -20 >&2
    exit 1
  fi
fi

if [[ ! -d "$MCP_DIR/node_modules" ]]; then
  echo "○ skip: $MCP_DIR/node_modules が無いためスキップ（本 suite の検査は1件も実行されていません。cd mcp && npm install で有効化）"
  FF_REACHED_END=1
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
# mktemp の stderr を捨てない。捨てると read-only 以外の失敗（TMPDIR が不正な
# パス・quota 超過など）まで「書き込み可能な環境で再実行してください」に
# 誤帰属し、恒常的に壊れた TMPDIR が suite を exit 0 で無効化し続ける。
# 2>&1 で受けると、成功時はパス・失敗時は理由が同じ変数に入る。
# rc=0 でも -d を検査する — 2>&1 の合流は「成功 + stderr 警告」の環境で変数へ
# 警告文が混入し、以後の処理が原因不明の失敗に化けるため。
if _ff_mktemp_out="$(mktemp -d "${TMPDIR:-/tmp}/mcp-dist-gate.XXXXXX" 2>&1)" && [ -d "$_ff_mktemp_out" ]; then
  TMP_DIR="$_ff_mktemp_out"
else
  echo "○ skip: 一時ディレクトリを作成できないためスキップ（本 suite の検査は1件も実行されていません。書き込み可能な環境で再実行してください）"
  printf '  mktemp: %s\n' "$_ff_mktemp_out"
  FF_REACHED_END=1
  exit 0
fi
# 途中死を沈黙させない。`set -u` 等で死んだとき、トラップ突入時の $? は **0** になるため、
# 終了ステータスを保存し直すだけでは足りない（実測）。「rc=0 なのに最後まで到達して
# いない」を中断として扱う。明示的な非 0 終了はそのまま通す。
FF_REACHED_END=0
_ff_exit_guard() {
  _ff_rc=$?
  rm -rf "$TMP_DIR"
  if [ "$_ff_rc" -eq 0 ] && [ "$FF_REACHED_END" -ne 1 ]; then
    echo "✗ mcp-dist-gate: 最後まで到達しませんでした（途中で中断）" >&2
    exit 1
  fi
  exit "$_ff_rc"
}
trap _ff_exit_guard EXIT
TMP_OUT="$TMP_DIR/index.js"

FAIL=0

# 事後条件の基準線: dist/ の状態を実行前に記録し、実行後は「変化」だけを検査する
# （dirty かどうかの絶対判定にすると、開発者の作業中変更を本 suite の書き込みと
# 誤帰属する）。git status は状態分類しか見ず「dirty なファイルへの上書き」を
# 見逃すため、内容ハッシュで比較する。
# 状態は 2 部構成: エントリ名の全一覧（種別を問わない。symlink やディレクトリの
# 増減を検出する）+ 通常ファイルの内容ハッシュ。ハッシュは cksum（POSIX、shasum と
# 違いどの環境にもある）を `-exec ... +` で取り、空白を含むパスでも分割しない。
# ハッシュ処理自体の失敗（走査不能・コマンド不在）は握りつぶさず非 0 で止める —
# 前後とも空文字なら比較は必ず一致し、read-only 契約の証明が黙って「検査 0 件」に
# 退化するため（Issue #370。mcp-typecheck suite の tree_state と同じ方針で、対象が
# dist/ に限られる点だけが異なる。同型の実装が mcp-vitest suite にもあり、直す
# ときは両方を揃える）。pipefail はサブシェル内で自己宣言し、呼び出し文脈に依存
# させない。検出対象は suite 自身による偶発的書き込み（非敵対モデル）— ファイル
# モードの変更と symlink の張り替え先は対象外。
dist_state() {
  ff_tree_state "$MCP_DIR" dist
}
if ! STATE_BEFORE="$(dist_state)"; then
  echo "✗ dist/ の内容ハッシュを取得できませんでした（read-only 事後条件を検査できません）" >&2
  exit 1
fi
if [[ -z "$STATE_BEFORE" ]]; then
  echo "✗ dist/ の内容ハッシュが空です（走査が壊れているか dist/ が空で、read-only 事後条件が空検査になります）" >&2
  exit 1
fi

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
# 扱う（changelog-contract と同じ規約 — 異常を「一致なし」と読まない）。
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
if ! STATE_AFTER="$(dist_state)"; then
  echo "✗ 実行後の dist/ 内容ハッシュを取得できませんでした（read-only 事後条件を検査できません）" >&2
  FAIL=1
elif [[ "$STATE_AFTER" != "$STATE_BEFORE" ]]; then
  echo "✗ 本 suite の実行が dist/ を書き換えた（read-only 契約違反）" >&2
  FAIL=1
fi

if [[ "$FAIL" != "0" ]]; then
  echo "✗ mcp-dist-gate verify: 失敗あり" >&2
  exit 1
fi
echo "✓ mcp-dist-gate verify: 全検査 pass"
FF_REACHED_END=1
