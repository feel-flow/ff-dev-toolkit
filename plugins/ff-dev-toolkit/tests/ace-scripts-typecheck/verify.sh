#!/usr/bin/env bash
#
# ace-scripts-typecheck: docs-template/scripts/ace/*.ts の型検査を run-all.sh へ配線する。
#
# 背景 (Issue #358): 隣の ace-scripts-vitest suite が走らせる vitest は esbuild による
# transpile のみで、**型検査を一切行わない**。したがって型エラーは CI（tests/run-all.sh）
# では素通りし、エディタを開いた人だけが気づく状態だった。PR #356 は
# `BudgetExceptionTally` をリテラル判別子つきの union にして「ゲートを外すと型検査が
# 通らない」構造を作ったが、その強制は CI に届いていなかった（正しさを型で保つ設計が、
# 機械が確認しない場所にしか存在しない）。
#
# なお、その型による強制が成立しているのは `check-category-size.ts` の
# `BudgetExceptionTally` 側だけである。`ace-refine-report.ts` の同形 union
# （`EntryLineMeasurementResult`）は消費側が union をそのまま受け取り実行時 throw で
# 弾く backstop で、main のゲートを削除しても型検査は緑のまま通る（実測）。
# ace-refine-report.ts 自身の JSDoc がそう自己申告している。
#
# ---- 設計判断 1: tsconfig の置き場所 ---------------------------------------
# 本 suite のディレクトリに置く（`tests/ace-scripts-typecheck/tsconfig.json`）。
# 検査対象の `docs-template/scripts/ace/` 側には置かない。docs-template は利用者
# プロジェクトへ配る想定のテンプレートで、`/ace-setup` は ACE の subagent 自動化を
# 使う場合に限り `docs-template/scripts/ace/` を**ディレクトリ単位でコピーする手順を
# 案内する**（既定の導入手順が配置するのは PLAYBOOK.md と ace-cycle.md の 2 つだけ
# なので、「必ず配られる」とまでは言えない — ADR-021 参照）。それでもこの任意手順を
# 通った利用者には tsconfig ごと届き、(a) エディタ／LSP が対象ファイルについて
# 利用者プロジェクトの root tsconfig ではなくこちらを最も近い設定として選び、
# (b) `../../mcp/node_modules` という**コピー先には存在しないパス**を指す設定が
# 残る。ゲートの設定はゲートを実行する側の持ち物として扱う（各 suite が自分の
# fixture を own する既存の構成にも合う）。
#
# 非目標: エディタでの体験は本 suite では変えない。`docs-template/scripts/ace/*.ts` を
# 単体で開いたエディタは上位に tsconfig.json を見つけられず推論プロジェクトで解釈するため、
# `node:fs` / `vitest` が未解決の赤として出る（本 suite の導入前からの状態）。CI の検出力と
# エディタの表示は別の問題なので、ここでは前者だけを塞ぐ。
#
# ---- 設計判断 2: 検査対象は *.test.ts を含む -------------------------------
# 非テストの 6 本だけに絞る案もあったが、テストを外さない。着手時点の実測で
# `ace-refine-report.test.ts` に**本物の代入不能エラー 2 件**があり、内容は
# 「production の判別 union に存在しない形（`unclosedFence: true` かつ行番号なし）を
# fixture が組み立てて汚染入力の検証をしていた」ものだった。つまりテスト側の型エラーは
# 「テストが起こり得ない形を検証している = そのアサーションが空振りしている」証拠になる。
# 検出したいのはまさにこの種類なので、テストを対象から外すと本 suite の価値が半分になる。
# （Issue #358 の GWT 1 は「`docs-template/scripts/ace/` の**いずれか**に型エラーを
# 入れたら名指しして落ちる」と書いており、非テストのみの範囲では字義どおりには
# 満たせない。DoD の但し書きが緩い読みも許してはいるが、広い側が条件文に忠実。）
#
# なお着手時点に見えていた implicit any 7 件は独立した負債ではなく、`vitest` の型解決に
# 失敗して `vi` が any になった**下流の症状**だった（tsconfig で解決を通した時点で 0 件に
# なる）。`: any` 注釈で潰すべきものではない。
#
# ---- 実行系 ----------------------------------------------------------------
# tsc は mcp/node_modules のものを再利用する。docs-template は自前の依存を持たない
# 設計で package.json も無い（作業ツリーに見える `scripts/ace/node_modules/` は
# vitest が作る .vite キャッシュだけで、gitignore 済み。tsconfig の exclude と下の
# find の prune はこれを対象から外すために要る）。vitest を同じ場所から借りている
# ace-scripts-vitest と同じ方式。node_modules が無い環境では run-all.sh の契約どおり
# 行頭 `○ skip` を出して exit 0 する。
#
# 検出力の実測（意図的な型エラーを入れて赤くなること）は tests/ace-scripts-typecheck-selftest/
# が隔離クローンへの mutation で固定する。
#
# Keep this read-only friendly: tsc は --noEmit なので何も書き込まない。

set -euo pipefail

# path は物理パスで持つ（pwd -P）。本ゲートは tsconfig を絶対パスで渡すため、実測では
# 論理パスのままでも prefix と --listFiles の展開が同源で一致し red にはならない。
# それでも物理パスへ揃えるのは、cwd 相対で tsconfig を渡す mcp-typecheck suite で
# 「symlink 配下のチェックアウトで対象集合が空になる red」が実測されており（tsc は cwd を
# 物理パスとして扱う）、呼び出し形の変更 1 つで同じ分岐がここでも成立するため — 多層防御
# として参照実装と同型に固定する（Issue #371。pwd -P の使用は selftest が静的に確認する）。
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd -P)"
MCP_DIR="$PLUGIN_ROOT/mcp"
ACE_SCRIPTS_DIR="$PLUGIN_ROOT/docs-template/scripts/ace"
TSCONFIG="$SCRIPT_DIR/tsconfig.json"

[ -d "$ACE_SCRIPTS_DIR" ] || {
  echo "✗ ace スクリプトディレクトリが見つかりません: $ACE_SCRIPTS_DIR" >&2
  exit 1
}
[ -f "$TSCONFIG" ] || {
  echo "✗ 型検査の tsconfig が見つかりません: $TSCONFIG" >&2
  exit 1
}

if [[ ! -d "$MCP_DIR/node_modules" ]]; then
  echo "○ skip: $MCP_DIR/node_modules が無いためスキップ（本 suite の検査は1件も実行されていません。cd mcp && npm install で有効化）"
  exit 0
fi
# node 本体が無い環境も skip（mcp-typecheck suite と同じ分水嶺）。ここを見ないと
# tsc の shebang が rc=127 で落ち、「型検査が失敗しました」という誤誘導の hard red になる。
if ! command -v node >/dev/null 2>&1; then
  echo "○ skip: node が PATH に無いためスキップ（本 suite の検査は1件も実行されていません）"
  exit 0
fi
# node_modules はあるのに tsc が無いのは不完全な install。ここを skip に倒すと
# 「install したのに検査 0 件」が緑として通るので fail-closed で止める。
if [[ ! -x "$MCP_DIR/node_modules/.bin/tsc" ]]; then
  echo "✗ node_modules はあるが tsc が無い（npm install が不完全）: $MCP_DIR/node_modules/.bin/tsc" >&2
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
# 語に言及しただけでも赤くなる（実測）。この向きは意図的で、緩めない — 偽陽性は
# 大声で出て 1 編集で直せるが、偽陰性はこのゲートが塞ごうとしているものそのもの。
# 判定を markdown / TS 対応にしにいくと、例示と宣言を取り違える種類のバグを持ち込む
# （同型の失敗が Issue #343 / #347 で実際に起きている）。
# **したがってこの規則自体を、走査対象のソースの中に書かないこと。** 書く場所は本
# ヘッダか `tests/` 配下、または `docs-template/scripts/ace/README.md`。

# ---- 検査対象の期待集合 -----------------------------------------------------
# 期待する検査対象は実ディレクトリから導出する（後段の集合照合にも上の抑制走査にも
# 同じ集合を使う — 走査した集合と照合した集合が乖離する経路を作らない）。
# 拡張子を `.ts` に絞らないのは、`foo.mts` が `*.ts` の glob にも `find -name '*.ts'`
# にも現れず、**両側で不可視のまま照合が一致してしまう**ため（Issue #371。tsc が対応する
# ソース拡張子 .ts / .mts / .cts / .tsx を列挙する）。prune の条件は tsconfig の
# exclude（`**/node_modules`）と対応させてある。
EXPECTED="$(cd "$ACE_SCRIPTS_DIR" && find . -name node_modules -prune -o \
  \( -name '*.ts' -o -name '*.mts' -o -name '*.cts' -o -name '*.tsx' \) -print |
  sed 's|^\./||' | LC_ALL=C sort)"
if [[ -z "$EXPECTED" ]]; then
  echo "✗ $ACE_SCRIPTS_DIR に TypeScript ソースが 1 件もありません（検査対象の導出が壊れています）" >&2
  exit 1
fi

# 走査は EXPECTED をファイル単位で回し、grep の rc を三分する（0=該当あり /
# 1=該当なし / >=2=走査失敗）。`find -exec grep ... + || true` の形は「該当なし
# (rc=1)」と「grep 自体の異常 (rc>=2)」を同じ扱いにし、走査できなかったファイルが
# 黙って合格になる（Issue #371。playbook の規約: grep は exit 1 のみを「該当なし」と
# し 2 以上は fail-closed）。失敗はサブシェルから exit 9 で外へ伝える。分岐に case を
# 使わないのは bash 3.2 の制約で、`$( … )` の中の case はパターンの `)` が command
# substitution の終端と誤解されて構文エラーになる（mcp-typecheck suite で実測）。
# cd はループ外で 1 回だけ行い、失敗を専用 rc で外へ出す。ループ内の
# `cd ... && grep ...` の形だと cd 失敗がコマンド置換 rc=1 になり、grep の
# 「該当なし」と区別できず走査ゼロのまま静かに合格する（rc 三分が破れる）。
set +e
SUPPRESSORS="$(cd "$ACE_SCRIPTS_DIR" || exit 9
  printf '%s\n' "$EXPECTED" | while IFS= read -r rel; do
    [ -n "$rel" ] || continue
    hits="$(grep -nE '@ts-nocheck|@ts-ignore' /dev/null -- "$rel")"
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
  echo "✗ 抑制ディレクティブの走査を完了できませんでした（rc=${SCAN_RC}。9=cd 失敗またはループ内で名指し済みの走査失敗 / それ以外はパイプ上流の失敗）" >&2
  exit 1
fi
if [[ -n "$SUPPRESSORS" ]]; then
  echo "✗ 型検査を無効化するディレクティブが混入しています（このゲートの「エラー 0 件」が偽になります）" >&2
  printf '%s\n' "$SUPPRESSORS" | sed 's/^/     /' >&2
  echo "  抑制が必要なら @ts-expect-error を使ってください（抑制対象が消えたら自分が赤くなるため、腐りません）" >&2
  echo "  判定は素のテキスト一致なので、散文で語に言及しただけでもここに出ます（意図的な fail-closed）。" >&2
  echo "  規則の説明を書きたい場合は、走査対象の .ts ではなく tests/ 側か scripts/ace/README.md へ置いてください" >&2
  exit 1
fi

# --listFiles を付けて 1 回で実行する（診断と検査対象の一覧を同じ実行から取る。2 回に
# 分けると「診断を出した実行」と「対象を数えた実行」が別物になり、対象集合の主張が
# 実際に検査された集合の主張でなくなる）。cwd を PLUGIN_ROOT にするのは診断の path を
# プラグインルート相対（`docs-template/scripts/ace/...`）で読める形にするため
# — リポジトリ root から見た path ではないので、貼り付ける前に
# `plugins/ff-dev-toolkit/` を前置すること。
set +e
OUTPUT="$(cd "$PLUGIN_ROOT" && ./mcp/node_modules/.bin/tsc --noEmit --listFiles -p "$TSCONFIG" 2>&1)"
RC=$?
set -e

# 検査対象の一覧（--listFiles は絶対パスを出す）と診断（cwd 相対の path で始まる）を
# 分離する。CHECKED 側の prefix は正規表現ではなく awk の index() で突き合わせる
# （チェックアウト先の path に正規表現メタ文字が含まれても壊れないように）。
#
# DIAGNOSTICS 側は「ace 配下でない行はすべて診断」ではいけない。--listFiles は
# typescript/lib/*.d.ts と @types/node/*.d.ts も列挙するので、その定義だと失敗時に
# 200 行超の絶対パスが診断として出て、本物のエラー 1 行がその中に埋もれる。
# 絶対パスで始まる行を落とし、ただし診断の形（`): error TSxxxx:`）を含む行は残す
# （tsc は cwd 相対で診断を出すので通常は該当しないが、落とす側に倒すと本物の診断を
# 消しうる。消える側ではなく残る側へ倒す）。
CHECKED="$(printf '%s\n' "$OUTPUT" | awk -v prefix="$ACE_SCRIPTS_DIR/" '
  index($0, prefix) == 1 && $0 ~ /\.(ts|mts|cts|tsx)$/ { print substr($0, length(prefix) + 1) }
' | LC_ALL=C sort)"
DIAGNOSTICS="$(printf '%s\n' "$OUTPUT" | awk '
  index($0, "/") == 1 && $0 !~ /\): error TS[0-9]+:/ { next }
  { print }
')"

if [[ $RC -ne 0 ]]; then
  printf '%s\n' "$DIAGNOSTICS"
  echo "✗ docs-template/scripts/ace の型検査が失敗しました（rc=${RC}）" >&2
  echo "  再現: cd plugins/ff-dev-toolkit && ./mcp/node_modules/.bin/tsc --noEmit -p tests/ace-scripts-typecheck/tsconfig.json" >&2
  exit 1
fi

# EXPECTED（冒頭で導出済み）と**名前で**照合する。exit 0 は「検査した全ファイルに
# エラーが無い」しか意味せず、include の glob が一部を静かに取りこぼした状態
# （tsc が落ちるのは対象 0 件の TS18003 のときだけ）も緑になる。件数ではなく集合で
# 比べるのは、1 本増えて 1 本落ちた形を件数一致で見逃さないため。
#
# なお include から外れても import 経由で到達できるファイルは --listFiles に残り、
# tsc も完全に型検査する。したがってこの照合が捕まえるのは「**どこからも到達
# しなくなった**ファイル」で、それが本当のカバレッジ喪失にあたる。逆に
# `docs-template/scripts/ace/node_modules/` 配下の .d.ts が import 経由でプログラムに
# 入ると CHECKED 側にだけ現れて赤くなる（現状そのような依存は無い）。
if [[ "$CHECKED" != "$EXPECTED" ]]; then
  echo "✗ 型検査の対象集合が実ディレクトリと一致しません（tsconfig の include/exclude を確認）" >&2
  echo "-- 期待（$ACE_SCRIPTS_DIR の TypeScript ソース）:" >&2
  printf '%s\n' "$EXPECTED" | sed 's/^/     /' >&2
  echo "-- 実際（tsc --listFiles）:" >&2
  printf '%s\n' "$CHECKED" | sed 's/^/     /' >&2
  exit 1
fi

COUNT="$(printf '%s\n' "$CHECKED" | wc -l | tr -d ' ')"
echo "  ✓ docs-template/scripts/ace の ${COUNT} ファイル（*.test.ts を含む）がエラー 0 件"
echo "✓ ace-scripts-typecheck: pass"
