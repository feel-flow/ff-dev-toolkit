#!/usr/bin/env bash
#
# /ace-curate 手順 4-f の未導入 fallback が「実際に動く」ことの挙動検査（Issue #614）。
#
# tests/ace-curate-commit/ は SKILL.md に正しい文字列が書かれていることしか見ない。
# 文字列が正しくてもスクリプトが移動・改名・破損すれば、未導入プロジェクトの必須ゲートは
# 静かに到達不能へ戻る。ここでは scripts/ace/ を持たない一時プロジェクトを作り、
# SKILL.md に書かれた形のコマンドを実際に走らせて exit code を確認する。
#
# FF_DEV_TOOLKIT_ROOT は SKILL.md 冒頭「プラグインルートの固定（必須）」の手順どおり
# 「読み込んだ SKILL.md の絶対パスから ../.. を解決する」で導出する（ハードコードしない）。
# 導出した root 配下の実パスと、SKILL.md に書かれた文字列が一致することも併せて固定する
# ため、片方だけ直した drift はここで赤くなる。
#
# 実行系の選択: live-ace-gates は同梱 esbuild で bundle して node で走らせるが、本 suite が
# 固定したい契約は「SKILL.md が案内する形（runner 解決層 `scripts/ace-run-ts.sh` 経由）が
# そのまま通ること」なので、documented な呼び出し形をそのまま使う。TypeScript runner の
# 取得はネットワーク（初回のみ。以降は npm cache）に依存するため、解決層が runner を
# 見つけられない環境（exit 3）は suite 丸ごと ○ skip する（部分 skip はしない）。
# skip 判定も本番同形で行う — フラグ応答（`--version`）を根拠にしない（Issue #932）。
# 解決層が runner を見つけた後の失敗は、環境要因ではなく実際の退行として扱う。
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
# runner 解決層（Issue #879）。同梱ゲートはすべてこれを経由して起動する。
REL_RUNNER="scripts/ace-run-ts.sh"
# 解決層が候補判定に使う probe（Issue #932）。実 runner での実行契約をここで実測する。
REL_PROBE="scripts/ace-run-ts-probe.ts"

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

# TypeScript を実行できる runner があるか（初回はネットワーク）。ここが通らない環境は
# 丸ごと skip し、通った後の非 0 は実際の退行として扱う。
#
# 判定は**本番と同じ形**で行う（Issue #932）。かつては `npx --yes tsx --version` の成否を
# 見ていたが、本 suite が固定している契約は「スクリプトを実行できること」であって
# 「フラグに応答できること」ではない。フラグは外側のラッパーに消費されうるし、
# `--version` が通っても実行が通るとは限らない — その論法で偽陽性が生まれたのが #932 で
# あり、同じ論法を skip 判定に残すと**16 件が 1 件も実行されないまま緑**になりうる。
# 解決層自身を 1 回走らせ、runner 全滅（exit 3）のときだけ skip する。
_ff_resolve_rc=0
( cd "${SANDBOX}" && bash "${PLUGIN_ROOT}/${REL_RUNNER}" "${PLUGIN_ROOT}/${REL_PROBE}" ) \
  >/dev/null 2>&1 || _ff_resolve_rc=$?
if [ "${_ff_resolve_rc}" -eq 3 ]; then
  echo "○ skip: TypeScript を実行できる runner が無いため同梱スクリプトの実行検査をスキップ（オフライン環境。検査は1件も実行されていません）"
  exit 0
fi

PASS=0
FAIL=0
ok()  { echo "  ✓ $1"; PASS=$((PASS + 1)); }
bad() { echo "  ✗ $1" >&2; FAIL=$((FAIL + 1)); }

# ── FF_DEV_TOOLKIT_ROOT の解決（SKILL.md「プラグインルートの固定（必須）」節の手順を写す）───────────────────
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
  local rel="$1" label="$2" expected="$3" evidence="$4"
  shift 4
  local rc=0 out
  # SKILL.md が案内する形（runner 解決層を通す）で起動する。ここで npx を直書きすると、
  # SKILL.md と検査の経路が割れて「案内どおりに実行すると落ちるのに緑」が作れる。
  #
  # 終了コードだけで判定してはならない（Issue #932 で実測）。偽陽性で採用された
  # `yarn exec tsx <script>` は yarn 1.x で **rc=1** を返すため、**rc=1 を期待する負側 case が
  # 「正しい理由でないまま」通った**（runner 不在の rc=3 とは衝突しないので、あらゆる失敗が
  # 通るわけではない — 衝突したのは 1 という具体値である）。そこで期待する出力も渡し、
  # ケースごとに「何が起きた証拠か」を指定する。既定は 3 ゲート共通の `Playbook: <path>`
  # だが、負側は違反の具体名まで要求して「別の違反クラスが偶然発火した」形も弾く。
  out="$( ( cd "${PROJECT}" && bash "${FF_DEV_TOOLKIT_ROOT}/${REL_RUNNER}" "${FF_DEV_TOOLKIT_ROOT}/${rel}" "$@" ) 2>&1 )" || rc=$?
  if [ "${rc}" -eq "${expected}" ]; then
    ok "${label}（rc=${rc}）"
  else
    bad "${label} — expected rc=${expected} actual rc=${rc}"
  fi
  case "${out}" in
    *"${evidence}"*)
      ok "${label}: 期待した出力が出ている（${evidence}）" ;;
    *)
      bad "${label}: 出力に実行の証跡がありません（runner 解決層で止まった可能性）。期待: ${evidence} / 実際: ${out}" ;;
  esac
}

run_bundled "${REL_SYNC}" "同期検証 fallback が exit 0" 0 "Playbook: " "${PLAYBOOK_ARG}" --check
run_bundled "${REL_FORMAT}" "形式ゲート fallback が exit 0" 0 "Playbook: " "${PLAYBOOK_ARG}"
run_bundled "${REL_SIZE}" "肥大化チェック fallback が exit 0" 0 "Playbook: " "${PLAYBOOK_ARG}"

echo
echo "== 負側（不正 PLAYBOOK でゲートが赤くなる）=="
# 正常系だけだと「常に 0 を返すだけの実装」でも緑になる。旧形式エントリを 1 件だけ持つ
# fixture へ差し替え、形式ゲートが非 0 で落ちることを実測する。
cp "${FIXTURES}/playbook-legacy.md" "${PROJECT}/${PLAYBOOK_ARG}"
# 証拠は違反の具体名（fixture が仕込んだエントリ ID）まで要求する。`Playbook: ` だけだと
# 「別の違反クラスが偶然発火して exit 1 になった」形も通る（形式ゲートは 5 種の違反で
# 同じ 1 を返す）。
run_bundled "${REL_FORMAT}" "旧テーブル形式のエントリで形式ゲートが exit 1" 1 "ACE-002-1" "${PLAYBOOK_ARG}"

echo
echo "== probe の実行契約（実 runner で実測）=="
# tests/ace-run-ts/ の偽 shim は成功行を**自前で組み立てて**出すため、probe 側がこの形を
# 出せなくなった drift はあちらでは緑のまま通る（Issue #932 のレビュー指摘）。そのとき
# 本番は全環境で候補が全滅し、exit 3 で ACE の必須 3 ゲートがまとめて到達不能になる。
# ここだけが実 runner に通して「解決層が期待する 1 行」を実測できる場所である。
NL=$'\n'   # 行一致に使う（部分一致では他の出力へ紛れた文字列を証拠に数えてしまう）
PROBE_ABS="${FF_DEV_TOOLKIT_ROOT}/${REL_PROBE}"
# 期待する sentinel は解決層から採る（テスト側へ複製しない。片側だけ変えた drift を
# 「一致しない」ではなく「取得できない」として赤に倒す）。
PROBE_SENTINEL="$(awk -F'"' '/^PROBE_SENTINEL=/ {print $2; exit}' "${FF_DEV_TOOLKIT_ROOT}/${REL_RUNNER}")"
PROBE_TOKEN_FIXTURE="probe-token-$$-${RANDOM}"
if [ -z "${PROBE_SENTINEL}" ]; then
  bad "解決層から sentinel を取得できません（probe の実行契約を検査できません）"
else
  PROBE_OUT="$(ACE_RUN_TS_PROBE_TOKEN="${PROBE_TOKEN_FIXTURE}" \
    bash "${FF_DEV_TOOLKIT_ROOT}/${REL_RUNNER}" "${PROBE_ABS}" 2>/dev/null)"
  PROBE_OUT="${PROBE_OUT//$'\r'/}"
  case "${NL}${PROBE_OUT}${NL}" in
    *"${NL}${PROBE_SENTINEL}:${PROBE_TOKEN_FIXTURE}${NL}"*)
      ok "probe が実 runner で ${PROBE_SENTINEL}:<トークン> を stdout の独立行に出す" ;;
    *)
      bad "probe の実行契約が壊れています（解決層の判定と不一致 = 全候補が不採用になり exit 3。出力: ${PROBE_OUT}）" ;;
  esac
fi

echo
# 検査総数の固定。検査の削除侵食（検査だけが消えて緑のまま通る）を赤くする。
# 針の増減時は EXPECTED_TOTAL も同時に更新すること。
EXPECTED_TOTAL=17
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
