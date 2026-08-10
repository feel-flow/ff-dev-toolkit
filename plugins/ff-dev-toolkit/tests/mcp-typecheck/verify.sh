#!/usr/bin/env bash
#
# mcp-typecheck: 同梱 spec-docs MCP サーバーの型検査を run-all.sh へ配線する。
#
# 背景 (Issue #360): `mcp/package.json` の `typecheck` スクリプトはどの suite からも
# 呼ばれておらず、型エラーは `tests/run-all.sh` では検出できなかった。隣の mcp-vitest が
# 走らせる vitest は esbuild による transpile のみで**型を一切見ない**（配布物を作る
# `npm run build` も同じく esbuild なので、型検査はどのビルド経路にも入っていない）。
# `docs-template/scripts/ace/` について ADR-022 が塞いだのと同型の穴で、対象ツリーが
# 違うだけである。着手時点の実測では `src` も `tests` もエラー 0 件だったので、
# 本 suite の追加コストはゲートの配線だけで済んでいる。
#
# ---- 設計判断 1: tsconfig は mcp/ 側の既存ファイルを使う --------------------
# ADR-022 は ace 側の tsconfig を **tests/ の suite ディレクトリ**へ置いたが、本 suite は
# 逆に `mcp/tsconfig.json` をそのまま使い、必要な変更（include に tests を追加）もそちらへ
# 入れる。ADR-022 の理由は「`docs-template/` は利用者プロジェクトへコピーされる場所で、
# コピー先には存在しない `../../mcp/node_modules` を指す設定が配られてしまう」ことだった。
# `mcp/` は自前の package.json と node_modules を持つ独立パッケージで、どこへもコピー
# されず、include も package 相対で閉じている。したがって ADR-022 の理由は移らない。
# 加えて本 Issue が塞ごうとしているのは「package.json の typecheck が呼ばれていない」
# ことそのものなので、別の tsconfig を作るとゲートと `npm run typecheck` が別の集合を
# 検査する状態（まさに閉じようとしている drift）を新たに作ることになる。詳細は ADR-023。
#
# ---- 設計判断 2: 検査対象に tests/*.ts を含める ----------------------------
# `mcp/tsconfig.json` の include へ `tests` を足した。ADR-022 が ace で同じ判断を
# したときの根拠は実測（テスト側に本物の型エラーが 2 件あり、内容は「production の型に
# 存在しない形を fixture が組み立てていた」= アサーションが空振りしていた証拠）だったが、
# **mcp では src / tests のどちらもエラー 0 件**で、その証拠は借りられない。ここでの根拠は
# (a) `../src/*.js` からの named import が実体とずれたら赤くなること、(b) `npm run typecheck`
# とゲートの検査範囲を一致させること、(c) 今なら 0 件なので配線コストがゼロであること。
# 逆向きの事実も記録しておく: `tests/server.test.ts` は stdio e2e の戻り値を `any` で
# 受けており、テスト側の検出力は ace ほど強くない（ADR-023 の「代替案」参照）。
#
# include はディレクトリ指定なので `tests/fixtures/` 配下も対象に入る（下の期待集合の
# 導出も同じ集合を見るので、両者は一致したままになる）。現在の fixture は Markdown と
# package.json だけだが、**意図的に壊した TypeScript を fixture として置くとここが赤くなる**。
# その必要が出たら `mcp/tsconfig.json` の exclude と下の EXPECTED の導出を**両方**直すこと。
#
# ---- 実行系: package.json の typecheck スクリプトを「完全一致で」借りる -----
# 実行するコマンドは `mcp/package.json` の `scripts.typecheck` から導出する（フラグを
# ここへ複製すると package.json 側の変更に追従できず、ゲートが別物を検査するようになる
# — mcp-dist-gate が build スクリプトについて同じことをしている）。ただし借り方は
# **許可した形との完全一致**で、シェルへは一切渡さない:
#
#   1. 読み出した文字列を空白で分割し、許可トークン列（`tsc --noEmit --project
#      tsconfig.json` / `-p` 版）と**完全一致**するときだけ実行する
#   2. 実行は `node_modules/.bin/tsc` を argv 配列で直接起動する（`sh -c` を通さない）
#
# 禁止リスト方式（メタ文字を弾き、部分文字列で `--noEmit` の存在を見る）では閉じない。
# 実測で `--noEmit false` は「`--noEmit` を含む」判定を通り、CLI 側の明示 false が
# tsconfig の `noEmit: true` を上書きして **src/tests の隣に .js を撒きながら緑**になった。
# `--noCheck` / `--listFilesOnly` も同様に「型検査をせずに 0 件・exit 0」を作れる。
# 追加フラグを個別に禁止していく方針は取らない（漏れる側に倒れるため）。
#
# スクリプトを変える必要が出たら、本 suite の許可形も同じ変更で更新すること。更新漏れは
# fail-closed の red として出る（緑のまま別物を検査する状態にはならない）。
#
# cwd は `npm run typecheck` と同じ mcp/ にするので、診断は `src/indexer.ts(12,7): error …`
# のようにパッケージ相対で出る（リポジトリ root から貼るときは
# `plugins/ff-dev-toolkit/mcp/` を前置すること）。
#
# node_modules が無い環境、および node が PATH に無い環境では run-all.sh の契約どおり
# 行頭 `○ skip` を出して exit 0 する。install 済みで tsc だけ無い状態は不完全な install
# なので fail-closed（skip に倒すと「install したのに検査 0 件」が緑になる）。
#
# 検出力の実測は tests/mcp-typecheck-selftest/ が隔離クローンへの mutation で固定する。
#
# Keep this read-only friendly: 実行するのは --noEmit の tsc だけ。事後条件として
# mcp/ ツリー（node_modules を除く）の内容ハッシュが変わっていないことも確認する
# — dist/ だけを見張ると、noEmit が外れたときの出力先（src/tests の隣）を見逃す。

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd -P)"
MCP_DIR="$PLUGIN_ROOT/mcp"

# path は物理パスで持つ。tsc（node）は cwd を symlink 解決後の物理パスとして扱うため、
# 論理パスのまま `--listFiles` の絶対パスと突き合わせると、symlink 配下に置かれた
# チェックアウト（worktree・macOS の /tmp → /private/tmp 等）で prefix が 1 件も一致せず、
# 「対象集合が実ディレクトリと一致しません（実際: 空）」という原因の読めない red になる。
[ -d "$MCP_DIR" ] || {
  echo "✗ mcp ディレクトリが見つかりません: $MCP_DIR" >&2
  exit 1
}
MCP_DIR="$(cd "$MCP_DIR" && pwd -P)"

[ -d "$MCP_DIR/src" ] || {
  echo "✗ mcp の src ディレクトリが見つかりません: $MCP_DIR/src" >&2
  exit 1
}
[ -f "$MCP_DIR/package.json" ] || {
  echo "✗ mcp の package.json が見つかりません: $MCP_DIR/package.json" >&2
  exit 1
}
[ -f "$MCP_DIR/tsconfig.json" ] || {
  echo "✗ mcp の tsconfig.json が見つかりません: $MCP_DIR/tsconfig.json" >&2
  exit 1
}

if [[ ! -d "$MCP_DIR/node_modules" ]]; then
  echo "○ skip: $MCP_DIR/node_modules が無いためスキップ（本 suite の検査は1件も実行されていません。cd mcp && npm install で有効化）"
  exit 0
fi
if [[ ! -x "$MCP_DIR/node_modules/.bin/tsc" ]]; then
  echo "✗ node_modules はあるが tsc が無い（npm install が不完全）: $MCP_DIR/node_modules/.bin/tsc" >&2
  exit 1
fi
# tsc の shebang は node を要求するので、node 不在ではゲート本体を実行できない。
# 本物の型エラーと環境都合の失敗を混ぜないため、丸ごと skip する（node_modules がある
# 以上ほぼ起きないが、install 時と実行時で PATH が違う環境がありうる）。
if ! command -v node >/dev/null 2>&1; then
  echo "○ skip: node が PATH に無いためスキップ（本 suite の検査は1件も実行されていません。node >= 22 を PATH へ通して再実行してください）"
  exit 0
fi

# ---- 実行コマンドを package.json から導出し、許可形と完全一致させる --------
# scripts キー自体が無い package.json でも、TypeError のスタックトレースではなく下の
# 診断へ落とす（`(x||{}).typecheck` で吸収する）。
TYPECHECK_CMD="$(node -pe '((require(process.argv[1] + "/package.json").scripts) || {}).typecheck || ""' "$MCP_DIR")"
if [[ -z "$TYPECHECK_CMD" ]]; then
  echo "✗ mcp/package.json に typecheck スクリプトがありません（本 suite が配線している対象そのものが消えています）" >&2
  exit 1
fi

# 空白（改行・タブを含む）で分割する。glob 展開は抑止する（`*` を含む形を、実行前に
# カレントディレクトリのファイル名へ化けさせないため）。
set -f
# shellcheck disable=SC2206
TYPECHECK_ARGS=($TYPECHECK_CMD)
set +f
OLD_IFS="$IFS"
IFS=' '
TYPECHECK_JOINED="${TYPECHECK_ARGS[*]}"
IFS="$OLD_IFS"

case "$TYPECHECK_JOINED" in
  'tsc --noEmit --project tsconfig.json'|'tsc --noEmit -p tsconfig.json') : ;;
  *)
    echo "✗ typecheck スクリプトが本 suite の許可形と一致しません（型検査をしない形へ静かに変わるのを防ぐため、完全一致で借りています）" >&2
    echo "  実際: $TYPECHECK_CMD" >&2
    echo "  許可形: 'tsc --noEmit --project tsconfig.json' または 'tsc --noEmit -p tsconfig.json'" >&2
    echo "  スクリプトを変える場合は、本 suite の許可形も同じ変更で更新してください" >&2
    echo "  （部分一致で許すと --noEmit false / --noCheck / --listFilesOnly のように、" >&2
    echo "    型検査をせず exit 0 になる形や作業ツリーへ .js を書き出す形が素通りします）" >&2
    exit 1 ;;
esac

# ---- 事後条件の基準線 ------------------------------------------------------
# mcp/ ツリー（node_modules を除く）の内容ハッシュを実行前後で比較する。dist/ だけを
# 見張ると、`noEmit` が外れたときの出力先（src/tests の隣）を見逃す。ハッシュ処理自体の
# 失敗（走査不能・cksum 不在）は握りつぶさず非 0 で止める — 前後とも空文字なら比較は
# 必ず一致し、事後条件が黙って空検査になるため。
tree_state() {
  (cd "$MCP_DIR" && find . -name node_modules -prune -o -type f -exec cksum {} + | LC_ALL=C sort)
}
if ! STATE_BEFORE="$(tree_state)"; then
  echo "✗ mcp ツリーの内容ハッシュを取得できませんでした（read-only 事後条件を検査できません）" >&2
  exit 1
fi
if [[ -z "$STATE_BEFORE" ]]; then
  echo "✗ mcp ツリーの内容ハッシュが空です（走査が壊れており、read-only 事後条件が空検査になります）" >&2
  exit 1
fi

# ---- 検査対象の期待集合 ----------------------------------------------------
# mcp/ 配下の TypeScript ソースすべて（node_modules と dist を除く）を期待集合とする。
# include の範囲に一致させるのではなく**ツリー全体**から導出するのは、新しい
# ディレクトリにソースが増えたときに「include に入っていないので静かに未検査」を
# 作らせないため。意図して検査対象外にしたいファイルが出てきた場合は、tsconfig の
# exclude と本 suite の導出の両方を明示的に更新する（黙って外れる経路を残さない）。
# 拡張子は tsc が既定で拾う形（.ts / .mts / .cts / .tsx）を並べる — `*.ts` だけに
# すると `foo.mts` が find にも include の glob にも現れず、両側で不可視のまま
# 集合照合が一致してしまう。
EXPECTED="$(cd "$MCP_DIR" && find . \( -name node_modules -o -name dist \) -prune -o \
  \( -name '*.ts' -o -name '*.mts' -o -name '*.cts' -o -name '*.tsx' \) -print |
  sed 's|^\./||' | LC_ALL=C sort)"
if [[ -z "$EXPECTED" ]]; then
  echo "✗ $MCP_DIR に TypeScript ソースが 1 件もありません（検査対象の導出が壊れています）" >&2
  exit 1
fi

# ---- 型検査を無効化するディレクティブの禁止 --------------------------------
# `// @ts-nocheck` はファイル全体の型検査を止めるが、そのファイルは --listFiles に
# **残り続ける**。したがって下の対象集合の照合は一致したままで、ゲートは
# 「N ファイル・エラー 0 件」という**偽の証明**を出す（include を狭める経路は集合照合が
# 捕まえるが、ファイル内部から無効化する経路は素通りする）。`@ts-ignore` は同じことを
# 行単位で行う。どちらも現在 0 件なので、混入を fail-closed で止める。
# `@ts-expect-error` は禁止しない — 抑制対象のエラーが実在しないとそれ自体がエラーに
# なるため自己監視が効く（黙って検査を消す上の 2 つとは性質が違う）。
#
# 判定は**素のテキスト一致**で、TypeScript の文法は解さない。したがって散文コメントで
# 語に言及しただけでも赤くなる。この向きは意図的で、緩めない — 偽陽性は大声で出て
# 1 編集で直せるが、偽陰性はこのゲートが塞ごうとしているものそのもの。
# **したがってこの規則自体を、走査対象のソースの中に書かないこと。** 書く場所は本
# ヘッダか `tests/` 配下、または `mcp/README.md`。
#
# grep の rc は 0（一致あり）/ 1（一致なし）/ 2 以上（grep 自体の異常）を分けて扱う。
# `|| true` で畳むと、走査できなかったファイルが黙って合格になり、上の「偽の証明」が
# ここからも出る（docs/08-knowledge/playbook/tooling.md の規約）。
#
# ループは command substitution の中で回す（here-doc / here-string は一時ファイルを
# 要求し read-only 環境で落ちるため使わない — ACE-86-2）。走査エラーは終了コード 9 を
# サブシェルから返して外へ伝える。分岐に case を使わないのは bash 3.2（macOS 既定）の
# 制約で、`$( … )` の中の case はパターンの `)` が command substitution の終端と誤解
# されて構文エラーになる（実測）。
set +e
SUPPRESSORS="$(printf '%s\n' "$EXPECTED" | while IFS= read -r rel; do
  [ -n "$rel" ] || continue
  hits="$(cd "$MCP_DIR" && grep -nE '@ts-nocheck|@ts-ignore' /dev/null -- "$rel")"
  grep_rc=$?
  if [ "$grep_rc" -eq 0 ]; then
    printf '%s\n' "$hits"
  elif [ "$grep_rc" -ne 1 ]; then
    echo "✗ 抑制ディレクティブの走査が失敗しました（grep rc=${grep_rc}）: $rel" >&2
    echo "  走査できないファイルを「該当なし」として通すと、このゲートの「エラー 0 件」が偽になります" >&2
    exit 9
  fi
done)"
SCAN_RC=$?
set -e
if [[ $SCAN_RC -ne 0 ]]; then
  echo "✗ 抑制ディレクティブの走査を完了できませんでした（rc=${SCAN_RC}）" >&2
  exit 1
fi
if [[ -n "$SUPPRESSORS" ]]; then
  echo "✗ 型検査を無効化するディレクティブが混入しています（このゲートの「エラー 0 件」が偽になります）" >&2
  printf '%s\n' "$SUPPRESSORS" | sed 's/^/     /' >&2
  echo "  抑制が必要なら @ts-expect-error を使ってください（抑制対象が消えたら自分が赤くなるため、腐りません）" >&2
  echo "  判定は素のテキスト一致なので、散文で語に言及しただけでもここに出ます（意図的な fail-closed）。" >&2
  echo "  規則の説明を書きたい場合は、走査対象のソースではなく tests/ 側か mcp/README.md へ置いてください" >&2
  exit 1
fi

# ---- 型検査本体 ------------------------------------------------------------
# --listFiles を後置して 1 回で実行する（診断と検査対象の一覧を同じ実行から取る。2 回に
# 分けると「診断を出した実行」と「対象を数えた実行」が別物になり、対象集合の主張が
# 実際に検査された集合の主張でなくなる）。argv は配列で渡し、シェルを経由しない。
set +e
OUTPUT="$(cd "$MCP_DIR" && "$MCP_DIR/node_modules/.bin/tsc" "${TYPECHECK_ARGS[@]:1}" --listFiles 2>&1)"
RC=$?
set -e

# 検査対象の一覧（--listFiles は絶対パスを出す）と診断（cwd 相対の path で始まる）を
# 分離する。CHECKED 側の prefix は正規表現ではなく awk の index() で突き合わせる
# （チェックアウト先の path に正規表現メタ文字が含まれても壊れないように）。
# node_modules 配下（typescript/lib/*.d.ts・@types・SDK の型定義）は対象外。
#
# DIAGNOSTICS 側は「mcp 配下でない行はすべて診断」ではいけない。--listFiles は数百件の
# .d.ts を列挙するので、その定義だと失敗時に本物のエラー 1 行がその中に埋もれる。
# 絶対パスで始まる行を落とし、ただし診断の形（`): error TSxxxx:`）を含む行は残す
# （tsc は cwd 相対で診断を出すので通常は該当しないが、落とす側に倒すと本物の診断を
# 消しうる。消える側ではなく残る側へ倒す）。
CHECKED="$(printf '%s\n' "$OUTPUT" | awk -v prefix="$MCP_DIR/" '
  index($0, prefix) == 1 && $0 ~ /\.(ts|mts|cts|tsx)$/ {
    rel = substr($0, length(prefix) + 1)
    if (index(rel, "node_modules/") == 1) next
    print rel
  }
' | LC_ALL=C sort)"
DIAGNOSTICS="$(printf '%s\n' "$OUTPUT" | awk '
  index($0, "/") == 1 && $0 !~ /\): error TS[0-9]+:/ { next }
  { print }
')"

if [[ $RC -ne 0 ]]; then
  # 診断が 1 行も残らない形（無出力での異常終了、絶対パスだけの出力）でも rc しか
  # 手掛かりが無い状態にはしない。落とした分を含む生の出力を末尾から見せる。
  if [[ -n "${DIAGNOSTICS//[$'\n ']/}" ]]; then
    printf '%s\n' "$DIAGNOSTICS"
  else
    echo "-- tsc の生出力（末尾 20 行。診断の形の行が 1 つも無かったため）:" >&2
    printf '%s\n' "$OUTPUT" | tail -20 >&2
  fi
  echo "✗ mcp の型検査が失敗しました（rc=${RC}）" >&2
  echo "  診断の path は mcp/ 相対です（リポジトリ root から見るときは plugins/ff-dev-toolkit/mcp/ を前置）" >&2
  echo "  再現: cd plugins/ff-dev-toolkit/mcp && npm run typecheck" >&2
  exit 1
fi

# 期待する検査対象を実ディレクトリから導出して**名前で**照合する。exit 0 は「検査した
# 全ファイルにエラーが無い」しか意味せず、include の glob が一部を静かに取りこぼした
# 状態（tsc が落ちるのは対象 0 件の TS18003 のときだけ）も緑になる。件数ではなく集合で
# 比べるのは、1 本増えて 1 本落ちた形を件数一致で見逃さないため。
#
# なお include から外れても import 経由で到達できるファイルは --listFiles に残り、
# tsc も完全に型検査する。したがってこの照合が捕まえるのは「**どこからも到達
# しなくなった**ファイル」で、それが本当のカバレッジ喪失にあたる。
if [[ "$CHECKED" != "$EXPECTED" ]]; then
  echo "✗ 型検査の対象集合が実ディレクトリと一致しません（mcp/tsconfig.json の include/exclude を確認）" >&2
  echo "-- 期待（$MCP_DIR の TypeScript ソース。node_modules / dist を除く）:" >&2
  printf '%s\n' "$EXPECTED" | sed 's/^/     /' >&2
  echo "-- 実際（tsc --listFiles）:" >&2
  printf '%s\n' "$CHECKED" | sed 's/^/     /' >&2
  exit 1
fi

# 事後条件: mcp/ ツリーを書き換えていない（--noEmit なので本来書き込まない。
# 書き込まれたら typecheck スクリプトか tsconfig の構成が変わった合図）。
if ! STATE_AFTER="$(tree_state)"; then
  echo "✗ 実行後の mcp ツリーの内容ハッシュを取得できませんでした（read-only 事後条件を検査できません）" >&2
  exit 1
fi
if [[ "$STATE_AFTER" != "$STATE_BEFORE" ]]; then
  echo "✗ 本 suite の実行が mcp/ ツリーを書き換えた（read-only 契約違反）" >&2
  exit 1
fi

COUNT="$(printf '%s\n' "$CHECKED" | wc -l | tr -d ' ')"
echo "  ✓ mcp の ${COUNT} ファイル（tests/*.test.ts を含む）がエラー 0 件"
echo "✓ mcp-typecheck: pass"
