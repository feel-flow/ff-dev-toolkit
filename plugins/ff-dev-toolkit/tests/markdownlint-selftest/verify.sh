#!/usr/bin/env bash
#
# repository Markdown lint が新規違反を非 0・ファイル名付きで検出することを隔離 fixture で固定する。
# 同じ設定・同じ実行ファイル（scripts/lib/markdownlint-functions.sh）を使う knowledge-commit の
# commit 前検査が、違反で止まり・未検査を違反なしと扱わず・導入先では従来どおりであることも固定する。
# 変異検出: knowledge-commit.sh の commit から ff_markdownlint_check_paths の呼び出しを外す・終了コードを `|| true` で捨てると「MD037・MD009 で commit せず exit 1」が赤、lib の実行ファイル不在を return 0 にすると「未検査と復帰手段を名指して exit 2」が赤、lib のゲートの有無の判定を外すと「導入先は従来どおり commit」が rc=2 で赤、判定からルートの設定の条件を外すと「公開リポジトリの配置は従来どおり commit」が rc=2 で赤（2026-11-07 実測。Issue `#2671`）。
# 空振り検出: lib の検査件数（`Linting: N file(s)`）の照合を外すと、0 件を検査して rc 0 を返す stub の回が未検査にならず「渡した件数を検査していない rc 0 は未検査」が赤。rc 1 の検査件数と違反件数（`Summary: N issue(s)`）の照合を外すと、モジュールを読めずに rc 1 で終わる stub の回が違反と読まれ「検査件数と違反件数を伴わない rc 1 は未検査」が赤（2026-11-07 実測）。

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd -P)"
REPO_ROOT="$(cd "$PLUGIN_ROOT/../.." && pwd -P)"
# fixture リポジトリの identity を呼び出し元へ漏らさない（Issue #1348 / #1368）
# fixture リポジトリの identity を呼び出し元へ漏らさない（Issue #1348 / #1368）
# shellcheck source=../lib/git-fixture.sh
. "$SCRIPT_DIR/../lib/git-fixture.sh"

SOURCE_VERIFY="$PLUGIN_ROOT/tests/markdownlint/verify.sh"
SOURCE_LIB="$PLUGIN_ROOT/scripts/lib/markdownlint-functions.sh"
SOURCE_CONFIG="$REPO_ROOT/.markdownlint.json"
SOURCE_PACKAGE_JSON="$PLUGIN_ROOT/mcp/package.json"
SOURCE_PACKAGE_LOCK="$PLUGIN_ROOT/mcp/package-lock.json"
SOURCE_NODE_MODULES="$PLUGIN_ROOT/mcp/node_modules"

if [[ ! -d "$SOURCE_NODE_MODULES" ]]; then
  echo "○ skip: $SOURCE_NODE_MODULES が無いため markdownlint mutation self-test をスキップ（cd plugins/ff-dev-toolkit/mcp && npm ci で有効化）"
  exit 0
fi
[[ -x "$SOURCE_NODE_MODULES/.bin/markdownlint-cli2" ]] || {
  echo "✗ node_modules はあるが markdownlint-cli2 がありません（npm ci が不完全）" >&2
  exit 1
}

# rc=0 でも -d を検査する — 2>&1 の合流は「成功 + stderr 警告」の環境で変数へ
# 警告文が混入し、以後の処理が原因不明の失敗に化けるため。
if _ff_mktemp_out="$(mktemp -d "${TMPDIR:-/tmp}/markdownlint-selftest.XXXXXX" 2>&1)" && [ -d "$_ff_mktemp_out" ]; then
  TMP="$_ff_mktemp_out"
else
  echo "○ skip: 一時ディレクトリを作成できないため markdownlint mutation self-test をスキップ（検査は1件も実行されていません）"
  printf '  mktemp: %s\n' "$_ff_mktemp_out"
  exit 0
fi
FF_REACHED_END=0
cleanup() {
  local rc=$?
  rm -rf "$TMP"
  if [[ "$FF_REACHED_END" -ne 1 ]]; then
    echo "✗ repository Markdown lint self-test: スイートが最後まで到達しませんでした" >&2
    exit 1
  fi
  exit "$rc"
}
trap cleanup EXIT
FIXTURE="$TMP/repo"
mkdir -p "$FIXTURE/plugins/ff-dev-toolkit/tests/markdownlint" "$FIXTURE/plugins/ff-dev-toolkit/mcp" "$FIXTURE/plugins/ff-dev-toolkit/scripts/lib"
cp "$SOURCE_VERIFY" "$FIXTURE/plugins/ff-dev-toolkit/tests/markdownlint/verify.sh"
cp "$SOURCE_LIB" "$FIXTURE/plugins/ff-dev-toolkit/scripts/lib/markdownlint-functions.sh"
cp "$SOURCE_CONFIG" "$FIXTURE/.markdownlint.json"
cp "$SOURCE_PACKAGE_JSON" "$FIXTURE/plugins/ff-dev-toolkit/mcp/package.json"
cp "$SOURCE_PACKAGE_LOCK" "$FIXTURE/plugins/ff-dev-toolkit/mcp/package-lock.json"
ln -s "$SOURCE_NODE_MODULES" "$FIXTURE/plugins/ff-dev-toolkit/mcp/node_modules"

ff_git_fixture_init "$FIXTURE" "markdownlint-selftest" "selftest@example.com"
printf '# Fixture\n' > "$FIXTURE/README.md"
git -C "$FIXTURE" add .
git -C "$FIXTURE" commit -qm baseline

baseline_output="$(bash "$FIXTURE/plugins/ff-dev-toolkit/tests/markdownlint/verify.sh" 2>&1)" || {
  echo "✗ 健全な fixture が失敗しました:" >&2
  printf '%s\n' "$baseline_output" >&2
  exit 1
}
case "$baseline_output" in
  *"tracked 1 files / 0 errors"*) echo "  ✓ 健全な fixture は 1 file / 0 errors" ;;
  *) echo "✗ baseline の件数契約がありません" >&2; printf '%s\n' "$baseline_output" >&2; exit 1 ;;
esac

printf '# Fixture \n' > "$FIXTURE/markdownlint-poison.md"
git -C "$FIXTURE" add markdownlint-poison.md
set +e
poison_output="$(bash "$FIXTURE/plugins/ff-dev-toolkit/tests/markdownlint/verify.sh" 2>&1)"
poison_rc=$?
set -e
[[ "$poison_rc" -ne 0 ]] || {
  echo "✗ Markdown 違反が exit 0 で素通りしました" >&2
  printf '%s\n' "$poison_output" >&2
  exit 1
}
echo "  ✓ Markdown 違反は非 0 終了"
case "$poison_output" in
  *"markdownlint-poison.md:1"*) echo "  ✓ 違反ファイルと行を名指し" ;;
  *) echo "✗ 違反ファイルの名指しがありません" >&2; printf '%s\n' "$poison_output" >&2; exit 1 ;;
esac
case "$poison_output" in
  *"MD009/no-trailing-spaces"*) echo "  ✓ 違反ルールを名指し" ;;
  *) echo "✗ 違反ルールの名指しがありません" >&2; printf '%s\n' "$poison_output" >&2; exit 1 ;;
esac

# knowledge-commit の commit 前検査（Issue `#2671`）。knowledge の直 push は全件ゲートを通らないので、
# 記録した Markdown を上と同じ設定・同じ実行ファイルで commit の前に検査する。ここまでの FIXTURE は
# 全件ゲートの suite を持ち、違反入りの markdownlint-poison.md を stage したままなので、記録したパス
# だけを検査することも同じ fixture で見る。
KC="$PLUGIN_ROOT/scripts/knowledge-commit.sh"
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
kc() { # <repo> <引数>... → KC_RC / KC_OUT / KC_ERR
  local repo="$1"; shift
  KC_RC=0
  (cd "$repo" && env -u FF_DEV_TOOLKIT_ROOT -u CLAUDE_PLUGIN_ROOT -u GROK_PLUGIN_ROOT bash "$KC" "$@") \
    >"$TMP/kc.out" 2>"$TMP/kc.err" || KC_RC=$?
  KC_OUT="$(cat "$TMP/kc.out")"
  KC_ERR="$(cat "$TMP/kc.err")"
}
kc_fail() { echo "✗ $1（rc=${KC_RC}）" >&2; printf '%s\n' "$KC_OUT" "$KC_ERR" >&2; exit 1; }
gate_repo() { # <dir> — 全件ゲートの suite と設定を持ち、node_modules は持たない repo
  mkdir -p "$1/plugins/ff-dev-toolkit/tests/markdownlint" "$1/docs/08-knowledge"
  cp "$SOURCE_VERIFY" "$1/plugins/ff-dev-toolkit/tests/markdownlint/verify.sh"
  cp "$SOURCE_CONFIG" "$1/.markdownlint.json"
  ff_git_fixture_init "$1" "markdownlint-selftest" "selftest@example.com"
  printf '# obs\n' >"$1/docs/08-knowledge/OBSERVATIONS.md"
  printf 'x\n' >"$1/notes.txt"
  git -C "$1" add -A
  git -C "$1" commit -qm baseline
}
OBS_REL="docs/08-knowledge/OBSERVATIONS.md"
mkdir -p "$FIXTURE/docs/08-knowledge"
printf '%s\n' '# obs' '' '- 2026-11-07: GIT_AUTHOR_* / GIT_COMMITTER_* を外す' '- 末尾に空白 ' >"$FIXTURE/$OBS_REL"
head_before="$(git -C "$FIXTURE" rev-parse HEAD)"
kc "$FIXTURE" add --source obs --id OBS-1 --summary 要約 -- "$OBS_REL"
[[ "$KC_RC" -eq 0 ]] || kc_fail "knowledge-commit add が通りません"
kc "$FIXTURE" commit
[[ "$KC_RC" -eq 1 ]] || kc_fail "記録した Markdown の違反で commit が exit 1 にならない"
case "$KC_ERR" in
  *"$OBS_REL:3:"*"MD037/no-space-in-emphasis"*"$OBS_REL:4:"*"MD009/no-trailing-spaces"*) ;;
  *) kc_fail "違反を ファイル:行 規則 で名指ししていない" ;;
esac
case "$KC_ERR" in *markdownlint-poison.md*) kc_fail "記録していない stage 済みのパスまで検査した" ;; esac
case "$KC_OUT" in *KNOWLEDGE_COMMIT=*) kc_fail "違反で止めたのに KNOWLEDGE_COMMIT を出した" ;; esac
[[ "$(git -C "$FIXTURE" rev-parse HEAD)" == "$head_before" ]] || kc_fail "違反で止めたのに commit した"
kc "$FIXTURE" status
case "$KC_OUT" in *KNOWLEDGE_PENDING=1*) ;; *) kc_fail "違反で止めた後に保留記録が残っていない" ;; esac
echo "  ✓ knowledge-commit: 記録した Markdown の MD037・MD009 で commit せず exit 1（ファイル:行 規則・保留は残る）"

printf '%s\n' '# obs' '' '- 2026-11-07: `GIT_AUTHOR_*` / `GIT_COMMITTER_*` を外す' >"$FIXTURE/$OBS_REL"
kc "$FIXTURE" add --source obs --id OBS-1 --summary 要約 -- "$OBS_REL"
[[ "$KC_RC" -eq 0 ]] || kc_fail "直した後の add が通りません"
kc "$FIXTURE" commit
[[ "$KC_RC" -eq 0 ]] || kc_fail "違反の無い Markdown の commit が通らない（stage 済みの markdownlint-poison.md は記録外）"
expected_keys="KNOWLEDGE_COMMIT=$(git -C "$FIXTURE" rev-parse HEAD)
KNOWLEDGE_SUBJECT=knowledge: OBS-1 要約
KNOWLEDGE_ENTRIES=1"
[[ "$(printf '%s\n' "$KC_OUT" | grep '^KNOWLEDGE_')" == "$expected_keys" ]] \
  || kc_fail "違反の無い commit の KNOWLEDGE_ 行が従来の 3 行と違う"
case "$KC_OUT$KC_ERR" in *markdownlint*) kc_fail "違反の無い commit の出力へ検査の行を足した" ;; esac
[[ "$(git -C "$FIXTURE" diff-tree --no-commit-id --name-only -r HEAD)" == "$OBS_REL" ]] \
  || kc_fail "commit に記録外のパスが入った"
echo "  ✓ knowledge-commit: 違反の無い Markdown は従来どおり commit し、出力の行も変わらない（記録外の違反は検査しない）"

NOMOD="$TMP/no-modules"
gate_repo "$NOMOD"
printf '%s\n' '# obs' '' '- 違反の無い追記' >"$NOMOD/$OBS_REL"
head_before="$(git -C "$NOMOD" rev-parse HEAD)"
kc "$NOMOD" add --source obs --id OBS-1 --summary 要約 -- "$OBS_REL"
[[ "$KC_RC" -eq 0 ]] || kc_fail "依存の無い fixture で add が通りません"
kc "$NOMOD" commit
[[ "$KC_RC" -eq 2 ]] || kc_fail "markdownlint を実行できない回の commit が exit 2 にならない（違反なしと扱った）"
case "$KC_ERR" in
  *"未検査"*"npm ci --prefix"*) ;;
  *) kc_fail "未検査であることと復帰手段（npm ci）を名指ししていない" ;;
esac
[[ "$(git -C "$NOMOD" rev-parse HEAD)" == "$head_before" ]] || kc_fail "未検査なのに commit した"
echo "  ✓ knowledge-commit: markdownlint を実行できない回は違反なしと扱わず、未検査と復帰手段を名指して exit 2"

kc "$NOMOD" discard
printf 'y\n' >"$NOMOD/notes.txt"
kc "$NOMOD" add --source obs --id OBS-2 --summary 要約2 -- notes.txt
[[ "$KC_RC" -eq 0 ]] || kc_fail "Markdown 以外の add が通りません"
kc "$NOMOD" commit
[[ "$KC_RC" -eq 0 ]] || kc_fail "Markdown を記録していない commit まで markdownlint の依存を要求した"
echo "  ✓ knowledge-commit: Markdown を記録していない commit は markdownlint を実行しない"

NOGATE="$TMP/no-gate"
mkdir -p "$NOGATE/docs/08-knowledge"
cp "$SOURCE_CONFIG" "$NOGATE/.markdownlint.json"
ff_git_fixture_init "$NOGATE" "markdownlint-selftest" "selftest@example.com"
printf '# obs\n' >"$NOGATE/$OBS_REL"
git -C "$NOGATE" add -A
git -C "$NOGATE" commit -qm baseline
printf '%s\n' '# obs' '' '- 末尾に空白 ' >"$NOGATE/$OBS_REL"
kc "$NOGATE" add --source obs --id OBS-1 --summary 要約 -- "$OBS_REL"
kc "$NOGATE" commit
[[ "$KC_RC" -eq 0 && "$(printf '%s\n' "$KC_OUT" | grep '^KNOWLEDGE_COMMIT=')" == "KNOWLEDGE_COMMIT=$(git -C "$NOGATE" rev-parse HEAD)" ]] \
  || kc_fail "全件ゲートの suite を持たないリポジトリ（導入先）の commit が従来どおり通らない"
echo "  ✓ knowledge-commit: 全件ゲートの suite を持たないリポジトリ（導入先）は検査の対象外で従来どおり commit"

# 公開リポジトリの配置: 同期で suite を受け取るがルートの設定を受け取らず、全件ゲートでも markdownlint を回さない
NOCFG="$TMP/no-config"
gate_repo "$NOCFG"
git -C "$NOCFG" rm -q -- .markdownlint.json
git -C "$NOCFG" commit -qm "no config"
printf '%s\n' '# obs' '' '- 末尾に空白 ' >"$NOCFG/$OBS_REL"
kc "$NOCFG" add --source obs --id OBS-1 --summary 要約 -- "$OBS_REL"
kc "$NOCFG" commit
[[ "$KC_RC" -eq 0 && "$(printf '%s\n' "$KC_OUT" | grep '^KNOWLEDGE_COMMIT=')" == "KNOWLEDGE_COMMIT=$(git -C "$NOCFG" rev-parse HEAD)" ]] \
  || kc_fail "suite だけでルートの設定を持たないリポジトリ（公開リポジトリの配置）の commit が従来どおり通らない"
echo "  ✓ knowledge-commit: suite だけを持ち設定の無いリポジトリ（公開リポジトリの配置）も検査の対象外で従来どおり commit"

# 実行ファイルが 0 件を検査して rc 0 を返す・想定外の rc で止まる回を、stub で lib へ直接当てる
STUB="$TMP/stub"
gate_repo "$STUB"
mkdir -p "$STUB/plugins/ff-dev-toolkit/mcp/node_modules/.bin"
STUB_BIN="$STUB/plugins/ff-dev-toolkit/mcp/node_modules/.bin/markdownlint-cli2"
stub_rc() { # <stub が返す rc> <stub の出力> → STUB_RC / STUB_ERR
  printf '#!/usr/bin/env bash\nprintf "%%s\\n" "%s"\nexit %s\n' "$2" "$1" >"$STUB_BIN"
  chmod +x "$STUB_BIN"
  STUB_RC=0
  STUB_ERR="$( (. "$SOURCE_LIB"; ff_markdownlint_check_paths "$STUB" "$OBS_REL") 2>&1 >/dev/null)" || STUB_RC=$?
}
stub_rc 0 "Linting: 0 files"
[[ "$STUB_RC" -eq 2 ]] || { echo "✗ 0 件を検査して rc 0 の回を未検査にしない（rc=${STUB_RC}）: ${STUB_ERR}" >&2; exit 1; }
case "$STUB_ERR" in *"検査した件数"*) ;; *) echo "✗ 件数の不一致を名指ししていない: ${STUB_ERR}" >&2; exit 1 ;; esac
echo "  ✓ markdownlint-functions: 渡した件数を検査していない rc 0 は未検査（rc 2）"
stub_rc 3 "boom"
[[ "$STUB_RC" -eq 2 ]] || { echo "✗ 想定外の rc 3 を未検査にしない（rc=${STUB_RC}）: ${STUB_ERR}" >&2; exit 1; }
case "$STUB_ERR" in *"rc=3"*) ;; *) echo "✗ 想定外の rc を名指ししていない: ${STUB_ERR}" >&2; exit 1 ;; esac
echo "  ✓ markdownlint-functions: 想定外の rc は未検査（rc 2）として rc を名指す"
# node はモジュールを読めない回も rc 1 で終わる（違反の rc と同じ）。検査件数と違反件数が無ければ違反と読まない
stub_rc 1 "Error: Cannot find module 'markdownlint'"
[[ "$STUB_RC" -eq 2 ]] || { echo "✗ 検査の結果を伴わない rc 1 を未検査にしない（rc=${STUB_RC}）: ${STUB_ERR}" >&2; exit 1; }
case "$STUB_ERR" in *"未検査"*"npm ci --prefix"*) ;; *) echo "✗ 検査の結果を伴わない rc 1 で未検査と復帰手段を名指していない: ${STUB_ERR}" >&2; exit 1 ;; esac
echo "  ✓ markdownlint-functions: 検査件数と違反件数を伴わない rc 1（モジュールを読めない等）は違反ではなく未検査（rc 2）"

FF_REACHED_END=1
echo "✓ repository Markdown lint self-test: 全 13 件 pass"
