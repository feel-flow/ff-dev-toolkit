#!/usr/bin/env bash
#
# ace-scripts-typecheck gate の検出力を mutation で実測する（Issue #358）。
# 作業ツリーは変更せず、一時領域へ「プラグイン tree の最小クローン」を作って poison する。
#
# クローンの形（tsconfig の相対パスをそのまま生かすため、実物と同じ相対配置にする）:
#   $TMP/plugin/mcp/node_modules            → 実物への symlink（tsc / @types / vitest の借り先）
#   $TMP/plugin/docs-template/scripts/ace/  → *.ts のコピー（mutation の対象）
#   $TMP/plugin/tests/ace-scripts-typecheck/{verify.sh,tsconfig.json} → 検査対象のコピー
#
# *.ts のコピーは検査対象ゲートと**同じ走査条件**（node_modules を prune した再帰）で
# 行い、サブディレクトリ構造を保つ。片方だけ非再帰にすると、`ace/<subdir>/x.ts` が
# 増えた瞬間にクローンが「テスト対象の模型」でなくなり、しかも壊れ方が紛らわしい
# （ゲートは正しく緑、selftest だけが件数アサーションで赤になる）。
#
# 検査対象の verify.sh を**そのまま**実行するので、測っているのは tsc 単体ではなく
# 「ゲート全体」（型エラーの検出・対象集合の照合・診断の名指し）である。tsc を直接
# 叩く形に書き換えると、verify.sh 側の照合ロジックが壊れても selftest は緑のままになる。

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd -P)"
MCP_DIR="$PLUGIN_ROOT/mcp"
ACE_SCRIPTS_DIR="$PLUGIN_ROOT/docs-template/scripts/ace"
SOURCE_VERIFY="$PLUGIN_ROOT/tests/ace-scripts-typecheck/verify.sh"
SOURCE_TSCONFIG="$PLUGIN_ROOT/tests/ace-scripts-typecheck/tsconfig.json"

[ -f "$SOURCE_VERIFY" ] || {
  echo "✗ 検査対象の verify.sh が見つかりません: $SOURCE_VERIFY" >&2
  exit 1
}
[ -f "$SOURCE_TSCONFIG" ] || {
  echo "✗ 検査対象の tsconfig.json が見つかりません: $SOURCE_TSCONFIG" >&2
  exit 1
}

# skip のメッセージでは「どのゲートが未測定になるのか」を名指しする。suite 名だけだと、
# run-all.sh のサマリーを読んだ人が「型検査そのものが飛んだ」のか「検出力の測定だけが
# 飛んだ」のかを区別できない。
if [[ ! -d "$MCP_DIR/node_modules" ]]; then
  echo "○ skip: $MCP_DIR/node_modules が無いため mutation self-test をスキップ（tests/ace-scripts-typecheck の検出力は未測定のままです。cd mcp && npm install で有効化）"
  FF_REACHED_END=1
  exit 0
fi
if [[ ! -x "$MCP_DIR/node_modules/.bin/tsc" ]]; then
  echo "✗ node_modules はあるが tsc が無い（npm install が不完全）: $MCP_DIR/node_modules/.bin/tsc" >&2
  exit 1
fi
if ! command -v node >/dev/null 2>&1; then
  echo "○ skip: node が PATH に無いため mutation self-test をスキップ（tests/ace-scripts-typecheck の検出力は未測定のままです）"
  FF_REACHED_END=1
  exit 0
fi
if ! command -v perl >/dev/null 2>&1; then
  echo "○ skip: perl が見つからないため mutation self-test をスキップ（tests/ace-scripts-typecheck の検出力は未測定のままです）"
  FF_REACHED_END=1
  exit 0
fi
if ! TMP="$(mktemp -d "${TMPDIR:-/tmp}/ace-scripts-typecheck-selftest.XXXXXX" 2>/dev/null)"; then
  echo "○ skip: 書き込み可能な一時領域を作れないため mutation self-test をスキップ（tests/ace-scripts-typecheck の検出力は未測定のままです）"
  FF_REACHED_END=1
  exit 0
fi
# 途中死を沈黙させない。`set -u` 等で死んだとき、トラップ突入時の $? は **0** になるため、
# 終了ステータスを保存し直すだけでは足りない（実測）。「rc=0 なのに最後まで到達して
# いない」を中断として扱う。明示的な非 0 終了はそのまま通す。
FF_REACHED_END=0
_ff_exit_guard() {
  _ff_rc=$?
  rm -rf "$TMP"
  if [ "$_ff_rc" -eq 0 ] && [ "$FF_REACHED_END" -ne 1 ]; then
    echo "✗ ace-scripts-typecheck-selftest: 最後まで到達しませんでした（途中で中断）" >&2
    exit 1
  fi
  exit "$_ff_rc"
}
trap _ff_exit_guard EXIT
# 物理パスへ直す。macOS の $TMPDIR は /var → /private/var の symlink 配下にあり、
# tsc は cwd を物理・設定由来の path を論理として扱うため、そのままだと診断が
# `../../../../../../../../var/folders/...` という読めない相対パスで出る。
TMP="$(cd "$TMP" && pwd -P)"

# 期待件数は実ディレクトリから導出する（直書きすると *.ts を 1 本増やしただけで
# この suite が red になり、診断が「selftest が失敗した」というゲート側のバグに見える）。
# 走査条件は reset_fixture のコピーと同一。
ACE_TS_COUNT="$(cd "$ACE_SCRIPTS_DIR" && find . -name node_modules -prune -o \
  \( -name '*.ts' -o -name '*.mts' -o -name '*.cts' -o -name '*.tsx' \) -print | wc -l | tr -d ' ')"

PASS=0
FAIL=0
ok() { echo "  ✓ $1"; PASS=$((PASS + 1)); }
bad() { echo "  ✗ $1" >&2; FAIL=$((FAIL + 1)); }

assert_contains() { # <label> <haystack> <needle>
  local label="$1" haystack="$2" needle="$3"
  case "$haystack" in
    *"$needle"*) ok "$label" ;;
    *)
      bad "${label}（期待する診断が無い: ${needle}）"
      printf '    %s\n' "$haystack" >&2
      ;;
  esac
}

# mutation の対象ファイルが実在することを先に確かめる。`printf >>` は**ファイルが
# 無ければ作る**ので、対象が改名されると「既存ファイルを poison する」検査が黙って
# 「新規ファイルを 1 本足す」検査へ退化し、それでも ✓ が付く。
assert_target_exists() { # <label> <file>
  local label="$1" file="$2"
  [ -f "$file" ] && return 0
  bad "${label} の mutation 対象が存在しない（改名された？）: $file"
  return 1
}

MUTATION_BEFORE="__unset__"
remember_file() { # <file>
  MUTATION_BEFORE="$(cksum < "$1")"
}

assert_file_changed() { # <label> <file>
  local label="$1" file="$2" after
  if [ "$MUTATION_BEFORE" = "__unset__" ]; then
    # remember_file を伴わない assert_file_changed は、直前の別ファイルの checksum と
    # 比べて黙って通る。ペアで使う約束をコード側で確かめる。
    bad "${label}: remember_file を呼ばずに assert_file_changed を使っています（self-test のバグ）"
    return 1
  fi
  after="$(cksum < "$file")"
  if [ "$MUTATION_BEFORE" != "$after" ]; then
    return 0
  fi
  bad "${label} の置換対象が見つからず fixture が未変更"
  return 1
}

reset_fixture() {
  rm -rf "$TMP/plugin"
  mkdir -p "$TMP/plugin/mcp" "$TMP/plugin/docs-template/scripts/ace" \
    "$TMP/plugin/tests/ace-scripts-typecheck"
  # node_modules は symlink で借りる（コピーすると数百 MB になる）。tsc は既定で
  # symlink を解決するので、型定義の解決先は実物と同じになる。
  ln -s "$MCP_DIR/node_modules" "$TMP/plugin/mcp/node_modules"
  FIXTURE_ACE="$TMP/plugin/docs-template/scripts/ace"
  # ゲートの EXPECTED 導出と同じ走査条件で、サブディレクトリを保って複製する。
  (cd "$ACE_SCRIPTS_DIR" && find . -name node_modules -prune -o \
    \( -name '*.ts' -o -name '*.mts' -o -name '*.cts' -o -name '*.tsx' \) -print) |
    while IFS= read -r rel; do
      mkdir -p "$FIXTURE_ACE/$(dirname "$rel")"
      cp "$ACE_SCRIPTS_DIR/$rel" "$FIXTURE_ACE/$rel"
    done
  cp "$SOURCE_VERIFY" "$TMP/plugin/tests/ace-scripts-typecheck/verify.sh"
  cp "$SOURCE_TSCONFIG" "$TMP/plugin/tests/ace-scripts-typecheck/tsconfig.json"
  FIXTURE_VERIFY="$TMP/plugin/tests/ace-scripts-typecheck/verify.sh"
  FIXTURE_TSCONFIG="$TMP/plugin/tests/ace-scripts-typecheck/tsconfig.json"
  MUTATION_BEFORE="__unset__"
}

run_fixture() { # <label> — red を期待する実行
  local label="$1" output
  if output="$(/bin/bash "$FIXTURE_VERIFY" 2>&1)"; then
    RUN_OUTPUT="$output"
    # この分岐が立つのは「ゲートが検出力を失った」ときだけ — この suite が存在する
    # 理由そのもの。証拠を出さないと、検出力の喪失とハーネスの事故（symlink 切れで
    # `○ skip` + exit 0 になった等）を区別できない。どちらも「exit 0 + 出力あり」。
    bad "$label が red にならなかった"
    printf '    %s\n' "$output" >&2
    return 1
  fi
  RUN_OUTPUT="$output"
  ok "$label が非 0 終了"
  return 0
}

echo "== ace-scripts-typecheck mutation self-test =="

# 1. 健全なクローンはまず green。mutation runner 自体（symlink・コピー漏れ・相対パス）の
#    壊れを先に検出する。これが無いと、以降の「非 0 終了」がゲートの検出力ではなく
#    ハーネスの事故を数えていても区別できない。
reset_fixture
BASELINE_OK=0
if RUN_OUTPUT="$(/bin/bash "$FIXTURE_VERIFY" 2>&1)"; then
  assert_contains "baseline のクローンが green" "$RUN_OUTPUT" "✓ ace-scripts-typecheck: pass"
  BASELINE_OK=1
else
  # クローンは実物の *.ts をそのままコピーするので、**実物に型エラーがあるとき**も
  # ここで落ちる。原因の切り分け順を書いておかないと、隣の suite が既に名指しして
  # いる型エラーを「クローンの構成が壊れている」と読み違える（この suite は
  # ace-scripts-typecheck の直後に並ぶため、2 つ同時に赤くなるのが通常の姿）。
  bad "baseline が失敗した（まず ace-scripts-typecheck の出力を見る — 実物の型エラーならそちらが原因。実物が緑ならクローンの構成が実物と食い違っている）"
  printf '    %s\n' "$RUN_OUTPUT" >&2
fi

# control が倒れた実験の結果は読まない。baseline が赤い状態では、以降の「非 0 終了」は
# mutation ではなく既存のエラーで説明できてしまう（実測: tsconfig の strict を外すと
# case 3 が巻き添えエラーで赤くなり、null 代入を検出していないのに ✓ が付いた）。
if [ "$BASELINE_OK" -ne 1 ]; then
  echo >&2
  echo "✗ baseline（control）が緑でないため、以降の mutation 検出力は測定できません（測っていないものを pass として数えないため、ここで打ち切ります）" >&2
  echo "✗ ace-scripts-typecheck self-test: $FAIL 件失敗（mutation は 1 件も測定していません）" >&2
  exit 1
fi

# 2. Issue #354 / #356 の型強制そのもの。`if (exceptionTally.unclosedFence) return` の
#    return を落とすと絞り込みが消え、union のまま fileReports（ReliableBudgetExceptionTally）
#    へ push されるので**型検査だけ**が落ちる。この 1 件が「正しさがガードの位置ではなく
#    型で保たれている」という主張の実測になる（check 側限定。refine 側の同形 union は
#    実行時 backstop で、型では止まらない）。
reset_fixture
assert_target_exists "未閉フェンスガードの return 除去" "$FIXTURE_ACE/check-category-size.ts" && {
  remember_file "$FIXTURE_ACE/check-category-size.ts"
  perl -0pi -e 's/(if \(exceptionTally\.unclosedFence\) \{.*?)\n\s*return EXIT_USAGE_ERROR;/$1/s' \
    "$FIXTURE_ACE/check-category-size.ts"
  if assert_file_changed "未閉フェンスガードの return 除去" "$FIXTURE_ACE/check-category-size.ts" &&
    run_fixture "未閉フェンスガードの return 除去"; then
    assert_contains "型エラーのファイルを名指し" "$RUN_OUTPUT" "docs-template/scripts/ace/check-category-size.ts"
    assert_contains "代入不能として報告" "$RUN_OUTPUT" "error TS2322"
    assert_contains "絞り込みが消えたことを型で報告" "$RUN_OUTPUT" "unclosedFence"
  fi
}

# 3. strict が効いていること。strict（strictNullChecks）を外すと通ってしまう形を撃つ。
#    tsconfig の strict を落とす mutation にすると「設定を消したら緑」しか測れず、
#    設定が残っていても検出力が無い状態を区別できない。
reset_fixture
assert_target_exists "strict 依存の型エラー（null 代入）" "$FIXTURE_ACE/check-archive-links.ts" && {
  printf '%s\n' 'const __selftestStrictNullCheck: string = null;' >> "$FIXTURE_ACE/check-archive-links.ts"
  if run_fixture "strict 依存の型エラー（null 代入）"; then
    assert_contains "strict 由来のエラーを名指し" "$RUN_OUTPUT" "docs-template/scripts/ace/check-archive-links.ts"
    assert_contains "null 代入を代入不能として報告" "$RUN_OUTPUT" "error TS2322"
  fi
}

# 4. *.test.ts も検査対象であること（設計判断 2 の固定）。テストを対象から外す変更が
#    入ると、この 1 件だけが red のまま残る。
reset_fixture
assert_target_exists "*.test.ts 内の型エラー" "$FIXTURE_ACE/shell-hooks.test.ts" && {
  printf '%s\n' 'const __selftestInTestFile: number = "not a number";' >> "$FIXTURE_ACE/shell-hooks.test.ts"
  if run_fixture "*.test.ts 内の型エラー"; then
    assert_contains "テストファイルのエラーを名指し" "$RUN_OUTPUT" "docs-template/scripts/ace/shell-hooks.test.ts"
    assert_contains "テスト側も代入不能として報告" "$RUN_OUTPUT" "error TS2322"
  fi
}

# 5. 対象集合の照合（--listFiles 突き合わせ）が効いていること。include を狭めて
#    **どこからも到達しなくなった**ファイルを作ると、「検査したファイルにはエラーが
#    無い」ので tsc は exit 0 になり、集合照合だけが red にできる。本 suite が防ぎたい
#    「静かな部分カバレッジ」の直撃テスト。
#    （include から外れても import 経由で到達できるファイルは検査され続けるので、
#    そちらが緑のままなのは正しい判定。ここが固定しているのは到達不能化のほう。）
reset_fixture
remember_file "$FIXTURE_TSCONFIG"
perl -0pi -e 's{"include": \[[^\]]*\]}{"include": ["../../docs-template/scripts/ace/check-archive-links.ts"]}s' \
  "$FIXTURE_TSCONFIG"
if assert_file_changed "include の縮小" "$FIXTURE_TSCONFIG" && run_fixture "include の縮小"; then
  assert_contains "対象集合の不一致として報告" "$RUN_OUTPUT" "型検査の対象集合が実ディレクトリと一致しません"
  assert_contains "取りこぼしたファイルを一覧で示す" "$RUN_OUTPUT" "sync-playbook-frontmatter.ts"
fi

# 6. vitest の型解決が load-bearing であること。マッピング先を壊すと *.test.ts が
#    TS2307 で赤くなる（解決できないときに黙って any へ倒れて緑になる、の否定）。
#    着手時点の implicit any 7 件はこの any 化の下流症状だったので、ここが緑に倒れると
#    「テストを検査している」という主張が中身を失う。
reset_fixture
remember_file "$FIXTURE_TSCONFIG"
perl -0pi -e 's{"vitest": \["[^"]*"\]}{"vitest": ["./selftest-nonexistent-vitest"]}' "$FIXTURE_TSCONFIG"
if assert_file_changed "vitest の paths 破壊" "$FIXTURE_TSCONFIG" && run_fixture "vitest の paths 破壊"; then
  assert_contains "vitest 未解決を型エラーとして報告" "$RUN_OUTPUT" "Cannot find module 'vitest'"
fi

# 7. ファイル内部から型検査を無効化する経路。`@ts-nocheck` はファイルを --listFiles に
#    残したまま検査だけを消すので、case 5 の集合照合では捕まらない（include を狭める
#    「外側」の経路と、ファイル内部の「内側」の経路は別物）。ゲートが
#    「エラー 0 件」という偽の証明を出さないことを固定する。
reset_fixture
assert_target_exists "@ts-nocheck による無効化" "$FIXTURE_ACE/check-archive-links.ts" && {
  printf '%s\n' '// @ts-nocheck' 'const __selftestSuppressed: string = null;' \
    >> "$FIXTURE_ACE/check-archive-links.ts"
  if run_fixture "@ts-nocheck による無効化"; then
    assert_contains "抑制ディレクティブを名指しで拒否" "$RUN_OUTPUT" "型検査を無効化するディレクティブ"
    assert_contains "混入ファイルを示す" "$RUN_OUTPUT" "check-archive-links.ts"
  fi
}

# 8. 逆向きの固定。*.ts を 1 本増やした正当な変更は green のままでなければならない
#    （対象集合の照合が固定リストへ退化すると、ここだけが red になる）。
reset_fixture
printf '%s\n' 'export const selftestAddedFile = 1;' > "$FIXTURE_ACE/selftest-added.ts"
if RUN_OUTPUT="$(/bin/bash "$FIXTURE_VERIFY" 2>&1)"; then
  assert_contains "新規 *.ts の追加後も green" "$RUN_OUTPUT" "✓ ace-scripts-typecheck: pass"
  assert_contains "追加分を含めた件数で報告" "$RUN_OUTPUT" "の $((ACE_TS_COUNT + 1)) ファイル"
else
  bad "正当な *.ts 追加を対象集合の不一致と誤検出した"
  printf '    %s\n' "$RUN_OUTPUT" >&2
fi

# 9. 追加拡張子（.mts / .cts / .tsx）内の型エラーが検査対象に入ること（Issue #371 の
#    方向 3）。拡張子の走査が `*.ts` に退化すると、これらは find にも include にも
#    現れず**両側不可視のまま照合が一致**する — 型エラーが検出されず緑になるため、
#    退化がここで赤になる。3 拡張子を同じ run に入れるのは実行回数の節約で、tsc は
#    全ファイルの診断を 1 回で出すため名指しの照合は独立に成立する。
#    （.tsx は jsx オプション未設定のため JSX 構文は書けない — このゲートの目的は
#    「見落とさず検査対象にする」ことで、JSX のコンパイルではない。）
reset_fixture
printf '%s\n' 'export const selftestMts: string = 123;' > "$FIXTURE_ACE/selftest-poison.mts"
# .cts は CommonJS 扱いで verbatimModuleSyntax の下では ESM の export が書けない
# （TS1287）ため、モジュールにしないスクリプト形式で型エラーだけを仕込む。
printf '%s\n' 'const selftestCts: string = 123; void selftestCts;' > "$FIXTURE_ACE/selftest-poison.cts"
printf '%s\n' 'export const selftestTsx: string = 123;' > "$FIXTURE_ACE/selftest-poison.tsx"
if run_fixture "追加拡張子（.mts/.cts/.tsx）内の型エラー"; then
  assert_contains ".mts のエラーを名指し" "$RUN_OUTPUT" "docs-template/scripts/ace/selftest-poison.mts"
  assert_contains ".cts のエラーを名指し" "$RUN_OUTPUT" "docs-template/scripts/ace/selftest-poison.cts"
  assert_contains ".tsx のエラーを名指し" "$RUN_OUTPUT" "docs-template/scripts/ace/selftest-poison.tsx"
fi

# 10. 正当な .mts / .cts / .tsx 追加は green + 件数に乗る（方向 3 の逆向き）。件数
#     アサーションが要るのは、拡張子走査が `*.ts` に退化しても「エラーの無い追加
#     拡張子」は緑のままで、緑判定だけでは退化を検出できないため — 件数が N+3 に
#     ならないことが唯一の兆候。
reset_fixture
printf '%s\n' 'export const selftestMtsOk = 1;' > "$FIXTURE_ACE/selftest-added.mts"
printf '%s\n' 'const selftestCtsOk: number = 1; void selftestCtsOk;' > "$FIXTURE_ACE/selftest-added.cts"
printf '%s\n' 'export const selftestTsxOk = 1;' > "$FIXTURE_ACE/selftest-added.tsx"
if RUN_OUTPUT="$(/bin/bash "$FIXTURE_VERIFY" 2>&1)"; then
  assert_contains "新規 .mts/.cts/.tsx の追加後も green" "$RUN_OUTPUT" "✓ ace-scripts-typecheck: pass"
  assert_contains "追加した 3 拡張子を件数に含める" "$RUN_OUTPUT" "の $((ACE_TS_COUNT + 3)) ファイル"
else
  bad "正当な .mts/.cts/.tsx 追加を対象集合の不一致と誤検出した"
  printf '    %s\n' "$RUN_OUTPUT" >&2
fi

# 11. symlink 経由の起動が green のままであることの固定（互換カナリア）。
#     注意: これは方向 2（pwd -P → pwd）の退化検出器では**ない** — 本ゲートは tsconfig を
#     絶対パスで渡すため、論理パス実装でも prefix と listFiles が同源で一致し red を
#     再現できない（実測）。cwd 相対で tsconfig を渡す形へ変わったときに初めて分岐が
#     生まれるので、その将来の形に備えて green を常設で固定し、pwd -P の使用自体は
#     下の静的検査で縛る（振る舞いで測れない性質は形そのものを縛る — mbcs-guard と
#     同じ判断）。
reset_fixture
rm -f "$TMP/plugin-link"
LN_ERR="$(ln -s "$TMP/plugin" "$TMP/plugin-link" 2>&1)" || LN_ERR="${LN_ERR:-ln failed}"
if [ -L "$TMP/plugin-link" ]; then
  if RUN_OUTPUT="$(/bin/bash "$TMP/plugin-link/tests/ace-scripts-typecheck/verify.sh" 2>&1)"; then
    assert_contains "symlink 経由でも対象集合の照合が成立して green" "$RUN_OUTPUT" "✓ ace-scripts-typecheck: pass"
  else
    bad "symlink 経由の起動が red（論理パスと物理パスの突き合わせ退化を疑う）"
    printf '    %s\n' "$RUN_OUTPUT" >&2
  fi
else
  echo "  ○ skip: symlink を作れない環境のため symlink 経由ケースは未測定（${LN_ERR}）"
fi
# pwd -P の静的検査（上のコメント参照。SCRIPT_DIR / PLUGIN_ROOT の 2 箇所）。
PWD_P_COUNT="$(grep -c 'pwd -P' "$SOURCE_VERIFY")" || PWD_P_COUNT=0
if [ "$PWD_P_COUNT" -ge 2 ]; then
  ok "ゲートのパス解決が pwd -P（物理パス）を使っている"
else
  bad "ゲートのパス解決から pwd -P が消えている（論理パスへの退化。件数: ${PWD_P_COUNT}）"
fi

# 12. 抑制ディレクティブ走査の失敗を「該当なし」と読まないこと（Issue #371 の方向 1）。
#     読めないファイルを 1 本作ると grep が rc>=2 で落ちる。root で走ると mode 000 でも
#     読めるため、その環境では測定せず skip を明示する（測っていないものを ✓ にしない）。
#     判定は rc ではなく走査失敗メッセージの照合であることが load-bearing — mode 000 の
#     ファイルは旧実装でも tsc 自身が読めず非 0 になるため、「非 0 終了」だけでは
#     走査の fail-closed を測ったことにならない。
reset_fixture
assert_target_exists "抑制ディレクティブ走査の失敗" "$FIXTURE_ACE/check-archive-links.ts" && {
  chmod 000 "$FIXTURE_ACE/check-archive-links.ts"
  if [ -r "$FIXTURE_ACE/check-archive-links.ts" ]; then
    echo "  ○ skip: mode 000 でも読める環境（root 等）のため走査失敗ケースは未測定"
  else
    if run_fixture "抑制ディレクティブ走査の失敗"; then
      assert_contains "走査失敗を名指しで報告" "$RUN_OUTPUT" "抑制ディレクティブの走査が失敗しました"
      assert_contains "対象ファイルを示す" "$RUN_OUTPUT" "check-archive-links.ts"
    fi
  fi
  chmod 644 "$FIXTURE_ACE/check-archive-links.ts" 2>/dev/null || true
}

echo
if [ "$FAIL" -gt 0 ]; then
  echo "✗ ace-scripts-typecheck self-test: $FAIL 件失敗" >&2
  exit 1
fi
echo "✓ ace-scripts-typecheck self-test: 全 $PASS 件 pass"
FF_REACHED_END=1
