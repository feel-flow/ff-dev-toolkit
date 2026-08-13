#!/usr/bin/env bash
#
# mcp-typecheck gate の検出力を mutation で実測する（Issue #360）。
# 作業ツリーは変更せず、一時領域へ「プラグイン tree の最小クローン」を作って poison する。
#
# クローンの形（gate が SCRIPT_DIR/../.. を PLUGIN_ROOT とみなすので、実物と同じ相対配置）:
#   $TMP/plugin/mcp/node_modules              → 実物への symlink（tsc / 型定義の借り先）
#   $TMP/plugin/mcp/{package.json,tsconfig.json} → コピー（実行コマンドと include の mutation 対象）
#   $TMP/plugin/mcp/{src,tests}/**/*.ts       → コピー（型エラー混入の対象）
#   $TMP/plugin/tests/mcp-typecheck/verify.sh → 検査対象のコピー
#
# `dist/` はクローンしない。gate の dist 事後条件は「実行前後で内容ハッシュが変わらない」
# ことしか見ないので、不在なら不在のまま一致する（--noEmit を外す mutation を当てても
# 出力先は tsconfig 由来で dist ではないため、この case は package.json の形の検査が拾う）。
#
# *.ts のコピーは gate の EXPECTED 導出と**同じ走査条件**（node_modules / dist を prune した
# 再帰）で行い、サブディレクトリ構造を保つ。片方だけ非再帰にすると、`src/<subdir>/x.ts` が
# 増えた瞬間にクローンが「テスト対象の模型」でなくなり、しかも壊れ方が紛らわしい
# （ゲートは正しく緑、selftest だけが件数アサーションで赤になる）。
#
# 検査対象の verify.sh を**そのまま**実行するので、測っているのは tsc 単体ではなく
# 「ゲート全体」（型エラーの検出・対象集合の照合・実行コマンドの形の検査）である。
#
# ace-scripts-typecheck-selftest との差分（両者を見比べる人向け）:
#   - `paths` 破壊の case は無い。ace は vitest の型を mcp/node_modules から借りるため
#     マッピングが load-bearing だったが、mcp は自前の node_modules を持ち paths を使わない
#   - 代わりに package.json の `scripts.typecheck` を壊す case がある（gate が実行コマンドを
#     そこから導出しているため、ace には存在しない失敗経路）。`--noEmit false` のように
#     「フラグはあるが無効化されている」形を含めるのは、部分一致では閉じないことが実測で
#     判明しているため（この形は tsconfig の noEmit を上書きし、src/tests の隣に .js を
#     撒きながら緑になった）
#   - skip / fail-closed の分水嶺そのもの（node_modules 不在 → skip、install 済みで tsc
#     だけ無い → fail）も case にしてある
#
# JSON の mutation は node で行う（perl を要求しない。tsc の実行に node は必須なので、
# 依存を増やしていない）。

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
MCP_DIR="$PLUGIN_ROOT/mcp"
SOURCE_VERIFY="$PLUGIN_ROOT/tests/mcp-typecheck/verify.sh"

[ -f "$SOURCE_VERIFY" ] || {
  echo "✗ 検査対象の verify.sh が見つかりません: $SOURCE_VERIFY" >&2
  exit 1
}

# skip のメッセージでは「どのゲートが未測定になるのか」を名指しする。suite 名だけだと、
# run-all.sh のサマリーを読んだ人が「型検査そのものが飛んだ」のか「検出力の測定だけが
# 飛んだ」のかを区別できない。
if [[ ! -d "$MCP_DIR/node_modules" ]]; then
  echo "○ skip: $MCP_DIR/node_modules が無いため mutation self-test をスキップ（tests/mcp-typecheck の検出力は未測定のままです。cd mcp && npm install で有効化）"
  FF_REACHED_END=1
  exit 0
fi
if [[ ! -x "$MCP_DIR/node_modules/.bin/tsc" ]]; then
  echo "✗ node_modules はあるが tsc が無い（npm install が不完全）: $MCP_DIR/node_modules/.bin/tsc" >&2
  exit 1
fi
if ! command -v node >/dev/null 2>&1; then
  echo "○ skip: node が PATH に無いため mutation self-test をスキップ（tests/mcp-typecheck の検出力は未測定のままです）"
  FF_REACHED_END=1
  exit 0
fi
# mktemp の失敗理由（ディスク満杯・TMPDIR の設定ミス等）は捨てずに skip 文言へ添える。
# 全部を「書き込み不可」に畳むと、原因の切り分けができない緑になる。stderr は一時ファイル
# ではなく command substitution で受ける（read-only 環境で自分が落ちないように）。
set +e
MKTEMP_OUT="$(mktemp -d "${TMPDIR:-/tmp}/mcp-typecheck-selftest.XXXXXX" 2>&1)"
MKTEMP_RC=$?
set -e
if [ "$MKTEMP_RC" -ne 0 ]; then
  echo "○ skip: 書き込み可能な一時領域を作れないため mutation self-test をスキップ（tests/mcp-typecheck の検出力は未測定のままです）${MKTEMP_OUT:+ / mktemp: $MKTEMP_OUT}"
  FF_REACHED_END=1
  exit 0
fi
TMP="$MKTEMP_OUT"
# 途中死を沈黙させない。`set -u` 等で死んだとき、トラップ突入時の $? は **0** になるため、
# 終了ステータスを保存し直すだけでは足りない（実測）。「rc=0 なのに最後まで到達して
# いない」を中断として扱う。明示的な非 0 終了はそのまま通す。
FF_REACHED_END=0
_ff_exit_guard() {
  _ff_rc=$?
  rm -rf "$TMP"
  if [ "$_ff_rc" -eq 0 ] && [ "$FF_REACHED_END" -ne 1 ]; then
    echo "✗ mcp-typecheck-selftest: 最後まで到達しませんでした（途中で中断）" >&2
    exit 1
  fi
  exit "$_ff_rc"
}
trap _ff_exit_guard EXIT
# 物理パスへ直す。macOS の $TMPDIR は /var → /private/var の symlink 配下にあり、
# gate は cwd を物理・設定由来の path を論理として扱うため、そのままだと path の
# 突き合わせが食い違う。
TMP="$(cd "$TMP" && pwd -P)"

# 期待件数は実ディレクトリから導出する（直書きすると *.ts を 1 本増やしただけで
# この suite が red になり、診断が「selftest が失敗した」というゲート側のバグに見える）。
# 走査条件は reset_fixture のコピーおよび gate の EXPECTED と同一。
MCP_TS_COUNT="$(cd "$MCP_DIR" && find . \( -name node_modules -o -name dist \) -prune -o \
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
  mkdir -p "$TMP/plugin/mcp" "$TMP/plugin/tests/mcp-typecheck" "$TMP/plugin/tests/lib"
  # node_modules は symlink で借りる（コピーすると数百 MB になる）。tsc は既定で
  # symlink を解決するので、型定義の解決先は実物と同じになる。
  ln -s "$MCP_DIR/node_modules" "$TMP/plugin/mcp/node_modules"
  FIXTURE_MCP="$TMP/plugin/mcp"
  cp "$MCP_DIR/package.json" "$FIXTURE_MCP/package.json"
  cp "$MCP_DIR/tsconfig.json" "$FIXTURE_MCP/tsconfig.json"
  # gate の EXPECTED 導出と同じ走査条件で、サブディレクトリを保って複製する。
  (cd "$MCP_DIR" && find . \( -name node_modules -o -name dist \) -prune -o \
    \( -name '*.ts' -o -name '*.mts' -o -name '*.cts' -o -name '*.tsx' \) -print) |
    while IFS= read -r rel; do
      mkdir -p "$FIXTURE_MCP/$(dirname "$rel")"
      cp "$MCP_DIR/$rel" "$FIXTURE_MCP/$rel"
    done
  cp "$SOURCE_VERIFY" "$TMP/plugin/tests/mcp-typecheck/verify.sh"
  cp "$SCRIPT_DIR/../lib/tree-state.sh" "$TMP/plugin/tests/lib/tree-state.sh"
  FIXTURE_VERIFY="$TMP/plugin/tests/mcp-typecheck/verify.sh"
  FIXTURE_PKG="$FIXTURE_MCP/package.json"
  FIXTURE_TSCONFIG="$FIXTURE_MCP/tsconfig.json"
  MUTATION_BEFORE="__unset__"
}

# package.json の scripts.typecheck を差し替える（JSON を壊さずに 1 キーだけ変える）。
set_typecheck_script() { # <command>
  node -e '
    const fs = require("fs");
    const [file, cmd] = process.argv.slice(1);
    const pkg = JSON.parse(fs.readFileSync(file, "utf8"));
    pkg.scripts.typecheck = cmd;
    fs.writeFileSync(file, JSON.stringify(pkg, null, 2) + "\n");
  ' "$FIXTURE_PKG" "$1"
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

echo "== mcp-typecheck mutation self-test =="

# 1. 健全なクローンはまず green。mutation runner 自体（symlink・コピー漏れ・相対パス）の
#    壊れを先に検出する。これが無いと、以降の「非 0 終了」がゲートの検出力ではなく
#    ハーネスの事故を数えていても区別できない。
reset_fixture
BASELINE_OK=0
BASELINE_FAIL_BEFORE="$FAIL"
if RUN_OUTPUT="$(/bin/bash "$FIXTURE_VERIFY" 2>&1)"; then
  assert_contains "baseline のクローンが green" "$RUN_OUTPUT" "✓ mcp-typecheck: pass"
  assert_contains "baseline が実物と同じ件数を検査" "$RUN_OUTPUT" "mcp の ${MCP_TS_COUNT} ファイル"
  # exit 0 だけでは control は成立しない（出力契約が壊れていれば、以降の「非 0 終了」も
  # ゲートの検出力の証拠にならない）。上の 2 つが通ったときだけ control 成立とみなす。
  [ "$FAIL" -eq "$BASELINE_FAIL_BEFORE" ] && BASELINE_OK=1
else
  # クローンは実物の *.ts をそのままコピーするので、**実物に型エラーがあるとき**も
  # ここで落ちる。原因の切り分け順を書いておかないと、隣の suite が既に名指しして
  # いる型エラーを「クローンの構成が壊れている」と読み違える（この suite は
  # mcp-typecheck の直後に並ぶため、2 つ同時に赤くなるのが通常の姿）。
  bad "baseline が失敗した（まず mcp-typecheck の出力を見る — 実物の型エラーならそちらが原因。実物が緑ならクローンの構成が実物と食い違っている）"
  printf '    %s\n' "$RUN_OUTPUT" >&2
fi

# control が倒れた実験の結果は読まない。baseline が赤い状態では、以降の「非 0 終了」は
# mutation ではなく既存のエラーで説明できてしまう。
if [ "$BASELINE_OK" -ne 1 ]; then
  echo >&2
  echo "✗ baseline（control）が緑でないため、以降の mutation 検出力は測定できません（測っていないものを pass として数えないため、ここで打ち切ります）" >&2
  echo "✗ mcp-typecheck self-test: $FAIL 件失敗（mutation は 1 件も測定していません）" >&2
  exit 1
fi

# 2. src の型エラー（Issue #360 の GWT 1 そのもの）。該当ファイルを名指しして落ちること。
reset_fixture
assert_target_exists "src の型エラー" "$FIXTURE_MCP/src/indexer.ts" && {
  printf '%s\n' 'const __selftestSrcError: number = "not a number";' >> "$FIXTURE_MCP/src/indexer.ts"
  if run_fixture "src の型エラー"; then
    assert_contains "型エラーのファイルを名指し" "$RUN_OUTPUT" "src/indexer.ts"
    assert_contains "代入不能として報告" "$RUN_OUTPUT" "error TS2322"
  fi
}

# 3. strict が効いていること。strict（strictNullChecks）を外すと通ってしまう形を撃つ。
#    tsconfig の strict を落とす mutation にすると「設定を消したら緑」しか測れず、
#    設定が残っていても検出力が無い状態を区別できない。
reset_fixture
assert_target_exists "strict 依存の型エラー（null 代入）" "$FIXTURE_MCP/src/utils.ts" && {
  printf '%s\n' 'const __selftestStrictNullCheck: string = null;' >> "$FIXTURE_MCP/src/utils.ts"
  if run_fixture "strict 依存の型エラー（null 代入）"; then
    assert_contains "strict 由来のエラーを名指し" "$RUN_OUTPUT" "src/utils.ts"
    assert_contains "null 代入を代入不能として報告" "$RUN_OUTPUT" "error TS2322"
  fi
}

# 4. tests/*.ts も検査対象であること（ADR-023 の決定 2 の固定）。テストを include から
#    外す変更が入ると、この 1 件と case 5 が red のまま残る。
reset_fixture
assert_target_exists "tests 内の型エラー" "$FIXTURE_MCP/tests/utils.test.ts" && {
  printf '%s\n' 'const __selftestInTestFile: number = "not a number";' >> "$FIXTURE_MCP/tests/utils.test.ts"
  if run_fixture "tests 内の型エラー"; then
    assert_contains "テストファイルのエラーを名指し" "$RUN_OUTPUT" "tests/utils.test.ts"
    assert_contains "テスト側も代入不能として報告" "$RUN_OUTPUT" "error TS2322"
  fi
}

# 5. 対象集合の照合（--listFiles 突き合わせ）が効いていること。include から tests を
#    落とすと、tests は**どこからも到達しなくなる**ので tsc は exit 0 になり
#    （tests → src の向きにしか import が無い）、集合照合だけが red にできる。
#    本 suite が防ぎたい「静かな部分カバレッジ」の直撃テスト。
reset_fixture
remember_file "$FIXTURE_TSCONFIG"
node -e '
  const fs = require("fs");
  const file = process.argv[1];
  const cfg = JSON.parse(fs.readFileSync(file, "utf8"));
  cfg.include = ["src/**/*.ts"];
  fs.writeFileSync(file, JSON.stringify(cfg, null, 2) + "\n");
' "$FIXTURE_TSCONFIG"
if assert_file_changed "include から tests を除外" "$FIXTURE_TSCONFIG" && run_fixture "include から tests を除外"; then
  assert_contains "対象集合の不一致として報告" "$RUN_OUTPUT" "型検査の対象集合が実ディレクトリと一致しません"
  assert_contains "取りこぼしたファイルを一覧で示す" "$RUN_OUTPUT" "tests/utils.test.ts"
fi

# 6. include の範囲外に新しい *.ts を置いた場合も red（EXPECTED を include の範囲では
#    なく mcp ツリー全体から導出している判断の固定）。新設ディレクトリの .ts が
#    「include に無いので静かに未検査」になる経路を塞ぐ。
reset_fixture
mkdir -p "$FIXTURE_MCP/scripts"
printf '%s\n' 'export const selftestOutsideInclude = 1;' > "$FIXTURE_MCP/scripts/selftest-outside.ts"
if run_fixture "include の範囲外に置かれた *.ts"; then
  assert_contains "未検査ファイルを対象集合の不一致として報告" "$RUN_OUTPUT" "型検査の対象集合が実ディレクトリと一致しません"
  assert_contains "未検査ファイルを名指し" "$RUN_OUTPUT" "scripts/selftest-outside.ts"
fi

# 7. ファイル内部から型検査を無効化する経路。`@ts-nocheck` はファイルを --listFiles に
#    残したまま検査だけを消すので、case 5 / 6 の集合照合では捕まらない（include を
#    狭める「外側」の経路と、ファイル内部の「内側」の経路は別物）。ゲートが
#    「エラー 0 件」という偽の証明を出さないことを固定する。
#    ディレクティブは**ファイル先頭**へ入れる — 末尾に置くと TypeScript が無視するので
#    tsc 自身が赤くなり、「走査が無ければ本当に緑になる」という前提を再現できない
#    （実測: 末尾配置では TS2322 が出る。先頭配置でのみ rc=0 になる）。
reset_fixture
assert_target_exists "@ts-nocheck による無効化" "$FIXTURE_MCP/src/utils.ts" && {
  {
    printf '%s\n' '// @ts-nocheck'
    cat "$FIXTURE_MCP/src/utils.ts"
    printf '%s\n' 'const __selftestSuppressed: string = null;'
  } > "$FIXTURE_MCP/src/utils.ts.new"
  mv "$FIXTURE_MCP/src/utils.ts.new" "$FIXTURE_MCP/src/utils.ts"
  if run_fixture "@ts-nocheck による無効化"; then
    assert_contains "抑制ディレクティブを名指しで拒否" "$RUN_OUTPUT" "型検査を無効化するディレクティブ"
    assert_contains "混入ファイルを示す" "$RUN_OUTPUT" "src/utils.ts"
  fi
}

# 7b. `@ts-ignore` 単独（行単位の無効化）も同じく拒否されること。走査パターンの片側だけを
#     残す退化を固定する。
reset_fixture
assert_target_exists "@ts-ignore による無効化" "$FIXTURE_MCP/tests/utils.test.ts" && {
  printf '%s\n' '// @ts-ignore' 'const __selftestIgnored: string = null;' \
    >> "$FIXTURE_MCP/tests/utils.test.ts"
  if run_fixture "@ts-ignore による無効化"; then
    assert_contains "行単位の抑制も拒否" "$RUN_OUTPUT" "型検査を無効化するディレクティブ"
    assert_contains "混入ファイルを示す（tests 側）" "$RUN_OUTPUT" "tests/utils.test.ts"
  fi
}

# 8. 実行コマンドの導出が load-bearing であること。ゲートは package.json の
#    `scripts.typecheck` を**許可形との完全一致**で借りるので、そこが「型検査をしない
#    コマンド」へ変わったら fail-closed で止まらなければならない。禁止リスト方式
#    （メタ文字を弾き、部分文字列で --noEmit の存在を見る）では閉じないことが実測で
#    判明しているため、無効化フラグを足す形（8d）も含めて 5 方向で塞ぐ。
mutate_typecheck_script() { # <label> <command> <expected-needle>
  local label="$1" cmd="$2" needle="$3"
  reset_fixture
  remember_file "$FIXTURE_PKG"
  set_typecheck_script "$cmd"
  if assert_file_changed "$label" "$FIXTURE_PKG" && run_fixture "$label"; then
    assert_contains "${label}: 許可形との不一致として拒否" "$RUN_OUTPUT" "$needle"
  fi
}

mutate_typecheck_script "typecheck スクリプトの空洞化" \
  'echo skipped' "許可形と一致しません"
mutate_typecheck_script "typecheck スクリプトの複合コマンド化" \
  'tsc --noEmit --project tsconfig.json && echo done' "許可形と一致しません"
mutate_typecheck_script "typecheck スクリプトから --noEmit を除去" \
  'tsc --project tsconfig.json' "許可形と一致しません"
# 8d. `--noEmit false` は「--noEmit を含む」部分一致を通り、CLI 側の明示 false が
#     tsconfig の noEmit: true を上書きする。実測ではゲートが緑を返しながら src/tests の
#     隣に .js を 9 本書いた（read-only 契約違反が赤にならない形）。
mutate_typecheck_script "typecheck スクリプトの --noEmit 無効化（--noEmit false）" \
  'tsc --noEmit false --project tsconfig.json' "許可形と一致しません"
# 8e. 別の tsconfig を指す形。集合照合が backstop になる場合もあるが、ここで止める。
mutate_typecheck_script "typecheck スクリプトの参照先 tsconfig 差し替え" \
  'tsc --noEmit --project tsconfig.build.json' "許可形と一致しません"

# 8f. `scripts.typecheck` そのものが消えた場合（ゲートが借りる先の消滅）。
reset_fixture
remember_file "$FIXTURE_PKG"
node -e '
  const fs = require("fs");
  const file = process.argv[1];
  const pkg = JSON.parse(fs.readFileSync(file, "utf8"));
  delete pkg.scripts.typecheck;
  fs.writeFileSync(file, JSON.stringify(pkg, null, 2) + "\n");
' "$FIXTURE_PKG"
if assert_file_changed "typecheck スクリプトの削除" "$FIXTURE_PKG" &&
  run_fixture "typecheck スクリプトの削除"; then
  assert_contains "借り先の消滅を名指しで拒否" "$RUN_OUTPUT" "typecheck スクリプトがありません"
fi

# 9. skip / fail-closed の分水嶺そのもの。node_modules 不在は行頭 `○ skip` + exit 0
#    （run-all.sh の契約）、install 済みで tsc だけ無い状態は fail-closed。ここが逆転
#    すると「install したのに検査 0 件」が緑になる、または未 install 環境が赤になる。
reset_fixture
rm -f "$FIXTURE_MCP/node_modules"
if RUN_OUTPUT="$(/bin/bash "$FIXTURE_VERIFY" 2>&1)"; then
  case $'\n'"$RUN_OUTPUT" in
    *$'\n○ skip'*) ok "node_modules 不在は行頭 ○ skip + exit 0" ;;
    *)
      bad "node_modules 不在で行頭 ○ skip マーカーが出ていない（run-all.sh が pass と数えてしまう）"
      printf '    %s\n' "$RUN_OUTPUT" >&2 ;;
  esac
else
  bad "node_modules 不在を red として報告した（環境都合の未実行は skip の契約）"
  printf '    %s\n' "$RUN_OUTPUT" >&2
fi

reset_fixture
rm -f "$FIXTURE_MCP/node_modules"
mkdir -p "$FIXTURE_MCP/node_modules/.bin"
if run_fixture "node_modules はあるが tsc が無い"; then
  assert_contains "不完全な install を fail-closed で拒否" "$RUN_OUTPUT" "node_modules はあるが tsc が無い"
fi

# 10. 逆向きの固定。TypeScript ソースを 1 本増やした正当な変更は green のままでなければ
#     ならない（対象集合の照合が固定リストへ退化すると、ここだけが red になる）。
reset_fixture
printf '%s\n' 'export const selftestAddedFile = 1;' > "$FIXTURE_MCP/src/selftest-added.ts"
if RUN_OUTPUT="$(/bin/bash "$FIXTURE_VERIFY" 2>&1)"; then
  assert_contains "新規 *.ts の追加後も green" "$RUN_OUTPUT" "✓ mcp-typecheck: pass"
  assert_contains "追加分を含めた件数で報告" "$RUN_OUTPUT" "mcp の $((MCP_TS_COUNT + 1)) ファイル"
else
  bad "正当な *.ts 追加を対象集合の不一致と誤検出した"
  printf '    %s\n' "$RUN_OUTPUT" >&2
fi

# 10b. `.ts` 以外の TypeScript 拡張子（ここでは `.mts`）も両側で見えていること。走査と
#      include のどちらかが `*.ts` 限定へ退化すると、そのファイルは EXPECTED にも
#      CHECKED にも現れず**照合は一致したまま緑**になる（件数が増えないことで検出する）。
reset_fixture
printf '%s\n' 'export const selftestAddedMts = 1;' > "$FIXTURE_MCP/src/selftest-added.mts"
if RUN_OUTPUT="$(/bin/bash "$FIXTURE_VERIFY" 2>&1)"; then
  assert_contains "新規 *.mts の追加後も green" "$RUN_OUTPUT" "✓ mcp-typecheck: pass"
  assert_contains ".mts を検査対象として数える" "$RUN_OUTPUT" "mcp の $((MCP_TS_COUNT + 1)) ファイル"
else
  bad "正当な *.mts 追加で red になった"
  printf '    %s\n' "$RUN_OUTPUT" >&2
fi

echo
if [ "$FAIL" -gt 0 ]; then
  echo "✗ mcp-typecheck self-test: $FAIL 件失敗" >&2
  exit 1
fi
echo "✓ mcp-typecheck self-test: 全 $PASS 件 pass"
FF_REACHED_END=1
