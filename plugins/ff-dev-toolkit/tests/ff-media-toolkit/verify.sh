#!/usr/bin/env bash
#
# ff-media-toolkit プラグインの suite（plugins/ff-media-toolkit/tests/run-all.sh）を本 run-all の
# 1 suite として回すラッパー（ff-media-toolkit 導入時に追加）。
#
# プラグイン側の runner は book-toolkit と同形で単独実行できるが、それだけだと CI と既定 run-all から
# 呼ばれず、壊れても週次で見えない。本 suite が呼び出し、runner の集約行を読んで結果を写す。
# 検査対象の実体（各 verify.sh の内容）はプラグイン側にあり、ここでは複製しない。
#
# 検査:
#   (0) 前提: marketplace.json に ff-media-toolkit が掲載されている木でだけ動く（公開 checkout は skip）。
#       掲載されているのに runner が無ければ赤。node は「見つからない」だけ skip、誤指定・古い版は赤
#   (1) runner が exit 0
#   (2) 集約行 `ff-media-toolkit suites: total=N passed=N failed=0` があり、N が 3 以上
#       （runner の SUITES が空になった・集約行の書式が変わった形を緑にしない）
#
# 空振り検出: runner の SUITES 配列を空にした写しを与えると (2) が「total=0」で赤になる（2026-09-25 実測:
#   `[[ "$passed" -gt 0 ]]` で runner 自体も非 0 になり (1) も赤。2 件中 2 件失敗）。集約行を
#   `ff-media-toolkit suites:` から別名へ変えた写しを与えると (2) が赤になる（同日実測）。
#   marketplace.json に掲載したまま runner を退避した写しを与えると (0) が赤になる（同日実測）。
# run-all-required: no — node 20 以上が無い環境と、ff-media-toolkit を含まない木（公開 checkout）では丸ごと skip を許容する（node は CI セットアップに含まれるので CI では走る）
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../../.." && pwd -P)"
PLUGIN_ROOT="${REPO_ROOT}/plugins/ff-media-toolkit"
RUNNER="${PLUGIN_ROOT}/tests/run-all.sh"

MARKETPLACE="${REPO_ROOT}/.claude-plugin/marketplace.json"
# 公開 checkout（配布物 ff-dev-toolkit だけの木）にはこのプラグインが無い。marketplace.json に
# ff-media-toolkit が掲載されていない木では対象外として skip し、掲載されているのに runner が無い
# （SSOT で消えた）ときだけ赤にする
if [ ! -f "${MARKETPLACE}" ] || ! /usr/bin/grep -q '"name": "ff-media-toolkit"' "${MARKETPLACE}"; then
  echo "○ skip: この木の marketplace.json に ff-media-toolkit が無い（公開 checkout 等）ため対象外です（検査は1件も実行されていません）"
  exit 0
fi
if [ ! -f "${RUNNER}" ]; then
  echo "✗ ${RUNNER} がありません（marketplace.json には掲載されているのに runner が消えている）" >&2
  exit 1
fi
# shellcheck source=../../../ff-media-toolkit/scripts/lib/node-bin.sh
. "${PLUGIN_ROOT}/scripts/lib/node-bin.sh"
# node の解決失敗は「見つからない」だけを skip にし、明示指定の誤り・古い版・起動不能は赤にする
node_err="$(ff_media_node 2>&1 >/dev/null)"; node_rc=$?
if [ "${node_rc}" -ne 0 ]; then
  case "${node_err}" in
    *見つかりません*)
      echo "○ skip: node 20 以上が見つからないため ff-media-toolkit の suite を回せません（検査は1件も実行されていません）"
      exit 0
      ;;
    *)
      echo "✗ node を解決できません: ${node_err}" >&2
      exit 1
      ;;
  esac
fi

pass=0
fail=0
ok() { pass=$((pass + 1)); echo "  ✓ $*"; }
bad() { fail=$((fail + 1)); echo "  ✗ $*" >&2; }

echo "== ff-media-toolkit（プラグイン側 runner） =="
out="$(bash "${RUNNER}" 2>&1)"; rc=$?
printf '%s\n' "${out}" | sed 's/^/    /'
if [ "${rc}" -eq 0 ]; then ok "(1) runner exit 0"; else bad "(1) runner exit ${rc}"; fi

summary="$(printf '%s\n' "${out}" | /usr/bin/grep -E '^ff-media-toolkit suites: total=[0-9]+ passed=[0-9]+ failed=[0-9]+$' | tail -1)"
total="$(printf '%s' "${summary}" | sed -n 's/.*total=\([0-9]*\).*/\1/p')"
failed="$(printf '%s' "${summary}" | sed -n 's/.*failed=\([0-9]*\).*/\1/p')"
if [ -n "${summary}" ] && [ "${total:-0}" -ge 3 ] && [ "${failed:-1}" -eq 0 ]; then
  ok "(2) 集約行: ${summary}"
else
  bad "(2) 集約行が無い・total が 3 未満・failed が 0 でない: '${summary}'"
fi

echo "ff-media-toolkit: passed=${pass} failed=${fail}"
[ "${fail}" -eq 0 ]
