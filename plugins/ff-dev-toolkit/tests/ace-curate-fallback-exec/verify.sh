#!/usr/bin/env bash
#
# /ace-curate 手順 4-f の未導入 fallback が「実際に動く」ことの挙動検査（Issue #614）。
#
# tests/ace-curate-commit/ は SKILL.md に正しい文字列が書かれていることしか見ない。
# 文字列が正しくてもスクリプトが移動・改名・破損すれば、未導入プロジェクトの必須ゲートは
# 静かに到達不能へ戻る。ここでは scripts/ace/ を持たない一時プロジェクトを作り、
# SKILL.md に書かれた形のコマンドを実際に走らせて exit code を確認する。
#
# FF_DEV_TOOLKIT_ROOT は SKILL.md 冒頭「プラグインルートの解決」の手順どおり
# 「読み込んだ SKILL.md の絶対パスから ../.. を解決する」で導出する（ハードコードしない）。
# 導出した root 配下の実パスと、SKILL.md に書かれた文字列が一致することも併せて固定する
# ため、片方だけ直した drift はここで赤くなる。
#
# 実行系の選択: live-ace-gates は同梱 esbuild で bundle して node で走らせるが、本 suite が
# 固定したい契約は「SKILL.md が案内する `npx --yes tsx <同梱パス>` がそのまま通ること」
# なので、documented な呼び出し形をそのまま使う。tsx の取得はネットワーク（初回のみ。以降は
# npm cache）に依存するため、事前の smoke test が通らない環境は suite 丸ごと ○ skip する
# （部分 skip はしない）。smoke test が通った後の失敗は環境要因ではなく実際の退行として扱う。
#
# 使い方: bash plugins/ff-dev-toolkit/tests/ace-curate-fallback-exec/verify.sh
# ACE-86-2: here-string / heredoc を使わない。

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TESTS_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
PLUGIN_ROOT="$(cd "${TESTS_DIR}/.." && pwd)"
SKILL_MD="${PLUGIN_ROOT}/skills/ace-curate/SKILL.md"
FIXTURES="${SCRIPT_DIR}/fixtures"

# 同梱スクリプトの相対パス（SSOT）。ここを起点に「実在検査」「SKILL.md の記述照合」
# 「実行」の 3 つを同じ文字列から組み立てる。
REL_SYNC="docs-template/scripts/ace/sync-playbook-frontmatter.ts"
REL_FORMAT="docs-template/scripts/ace/check-entry-format.ts"
REL_SIZE="docs-template/scripts/ace/check-category-size.ts"

PLAYBOOK_ARG="docs/08-knowledge/PLAYBOOK.md"

if [ ! -s "${SKILL_MD}" ]; then
  echo "✗ ace-curate/SKILL.md が存在しないか空です: ${SKILL_MD}" >&2
  exit 1
fi

# ── 環境前提（部分 skip 禁止・落とすなら丸ごと落とす）─────────────────────────
if ! command -v node >/dev/null 2>&1; then
  echo "○ skip: node が無いため同梱スクリプトの実行検査をスキップ（検査は1件も実行されていません）"
  exit 0
fi
if ! command -v npx >/dev/null 2>&1; then
  echo "○ skip: npx が無いため同梱スクリプトの実行検査をスキップ（検査は1件も実行されていません）"
  exit 0
fi
if ! _ff_mktemp_out="$(mktemp -d "${TMPDIR:-/tmp}/ace-curate-fallback-exec.XXXXXX" 2>&1)"; then
  echo "○ skip: 一時ディレクトリを作成できないため同梱スクリプトの実行検査をスキップ（検査は1件も実行されていません）"
  printf '  mktemp: %s\n' "${_ff_mktemp_out}"
  exit 0
fi
SANDBOX="${_ff_mktemp_out}"
cleanup() {
  local rc=$?
  rm -rf "${SANDBOX}"
  exit "${rc}"
}
trap cleanup EXIT
trap 'exit 130' HUP INT TERM

# tsx が取得できるか（初回はネットワーク）。ここが通らない環境は丸ごと skip し、
# 通った後の非 0 は実際の退行として扱う。
if ! npx --yes tsx --version >/dev/null 2>&1; then
  echo "○ skip: npx --yes tsx を解決できないため同梱スクリプトの実行検査をスキップ（オフライン環境。検査は1件も実行されていません）"
  exit 0
fi

PASS=0
FAIL=0
ok()  { echo "  ✓ $1"; PASS=$((PASS + 1)); }
bad() { echo "  ✗ $1" >&2; FAIL=$((FAIL + 1)); }

# ── FF_DEV_TOOLKIT_ROOT の解決（SKILL.md L12 の手順を写す）───────────────────
# 「読み込んだ SKILL.md の絶対パスから ../.. を解決する」= skills/<name>/ の 2 つ上。
FF_DEV_TOOLKIT_ROOT="$(cd "$(dirname "${SKILL_MD}")/../.." && pwd)"

echo "== FF_DEV_TOOLKIT_ROOT の解決 =="
if [ "${FF_DEV_TOOLKIT_ROOT}" = "${PLUGIN_ROOT}" ]; then
  ok "SKILL.md の絶対パスから ../.. でプラグインルートへ解決できる"
else
  bad "SKILL.md からの ../.. がプラグインルートと一致しません（解決=${FF_DEV_TOOLKIT_ROOT} / 期待=${PLUGIN_ROOT}）"
fi

echo
echo "== 同梱スクリプトの実在と SKILL.md 記述の一致 =="
# 実在（読み取り可能）と、SKILL.md が同じパスを案内していることを対で固定する。
# 実体だけ動く / 記述だけ動く のどちらの片側 drift もここで赤くなる。
assert_bundled() {
  local rel="$1" label="$2" abs="${FF_DEV_TOOLKIT_ROOT}/$1"
  if [ -r "${abs}" ] && [ -s "${abs}" ]; then
    ok "${label}: 解決した root 配下に実在し読み取れる"
  else
    bad "${label}: 読み取れないか空です（${abs}）"
  fi
  if grep -Fq -- "\"\${FF_DEV_TOOLKIT_ROOT}/${rel}\"" "${SKILL_MD}"; then
    ok "${label}: SKILL.md が同じ相対パスを案内している"
  else
    bad "${label}: SKILL.md の案内パスが実体と一致しません（${rel}）"
  fi
}
assert_bundled "${REL_SYNC}" "sync-playbook-frontmatter"
assert_bundled "${REL_FORMAT}" "check-entry-format"
assert_bundled "${REL_SIZE}" "check-category-size"

# ── scripts/ace/ を持たない一時プロジェクト ──────────────────────────────────
# ディレクトリ名に空白を含め、引用が外れた実装を赤くする。
PROJECT="${SANDBOX}/ace fallback project"
mkdir -p "${PROJECT}/docs/08-knowledge"
cp "${FIXTURES}/playbook-valid.md" "${PROJECT}/${PLAYBOOK_ARG}"

echo
echo "== 未導入プロジェクトでの実行（正常系は exit 0）=="
if [ -d "${PROJECT}/scripts/ace" ]; then
  bad "一時プロジェクトに scripts/ace/ が存在します（未導入の前提が崩れています）"
else
  ok "一時プロジェクトは scripts/ace/ を持たない（未導入の前提）"
fi

run_bundled() {
  local rel="$1" label="$2" expected="$3"
  shift 3
  local rc=0
  ( cd "${PROJECT}" && npx --yes tsx "${FF_DEV_TOOLKIT_ROOT}/${rel}" "$@" ) >/dev/null 2>&1 || rc=$?
  if [ "${rc}" -eq "${expected}" ]; then
    ok "${label}（rc=${rc}）"
  else
    bad "${label} — expected rc=${expected} actual rc=${rc}"
  fi
}

run_bundled "${REL_SYNC}" "同期検証 fallback が exit 0" 0 "${PLAYBOOK_ARG}" --check
run_bundled "${REL_FORMAT}" "形式ゲート fallback が exit 0" 0 "${PLAYBOOK_ARG}"
run_bundled "${REL_SIZE}" "肥大化チェック fallback が exit 0" 0 "${PLAYBOOK_ARG}"

echo
echo "== 負側（不正 PLAYBOOK でゲートが赤くなる）=="
# 正常系だけだと「常に 0 を返すだけの実装」でも緑になる。旧形式エントリを 1 件だけ持つ
# fixture へ差し替え、形式ゲートが非 0 で落ちることを実測する。
cp "${FIXTURES}/playbook-legacy.md" "${PROJECT}/${PLAYBOOK_ARG}"
run_bundled "${REL_FORMAT}" "旧テーブル形式のエントリで形式ゲートが exit 1" 1 "${PLAYBOOK_ARG}"

echo
# 検査総数の固定。検査の削除侵食（検査だけが消えて緑のまま通る）を赤くする。
# 針の増減時は EXPECTED_TOTAL も同時に更新すること。
EXPECTED_TOTAL=12
TOTAL=$((PASS + FAIL))
if [ "${TOTAL}" -eq "${EXPECTED_TOTAL}" ]; then
  ok "検査総数が ${EXPECTED_TOTAL} 件（増減時は EXPECTED_TOTAL も更新すること）"
else
  bad "検査総数が想定と異なります（実測: ${TOTAL} / 期待: ${EXPECTED_TOTAL}）"
fi

echo
if [ "${FAIL}" -gt 0 ]; then
  echo "✗ ace-curate fallback exec verify: ${FAIL} 件失敗" >&2
  exit 1
fi
echo "✓ ace-curate fallback exec verify: 全 ${PASS} 件 pass"
