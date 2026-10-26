#!/usr/bin/env bash
#
# ff-agent-press プラグインの suite（plugins/ff-agent-press/tests/run-all.sh）を本 run-all の
# 1 suite として回すラッパー（ff-agent-press 導入時に追加。ff-media-toolkit のラッパーと同形）。
#
# プラグイン側の runner は単独実行できるが、それだけだと CI と既定 run-all から呼ばれず、壊れても
# 週次で見えない。本 suite が呼び出し、runner の集約行を読んで結果を写す。検査対象の実体（各 verify.sh の
# 内容）はプラグイン側にあり、ここでは複製しない。
#
# 検査:
#   (0) 前提: marketplace.json に ff-agent-press が掲載されている木でだけ動く（公開 checkout は skip）。
#       掲載されているのに runner が無ければ赤。node は「見つからない」だけ skip、誤指定・古い版は赤
#   (1) runner が exit 0
#   (2) 集約行 `ff-agent-press suites: total=N passed=N failed=0` があり、N が 8 以上（現行の必須本数。runner の
#       SUITES が空になった・1 本でも外れた・集約行の書式が変わった形を緑にしない。suite を足しても赤にはならない）
#
# 空振り検出: runner の SUITES 配列を空にした写しを与えると (1)(2) とも赤になる（2026-10-20 実測: runner が
#   集約行を出す前に非 0 で終わり、2 件中 2 件失敗）。集約行を
#   `ff-agent-press suites:` から別名へ変えた写しを与えると (2) が赤になる（同日実測）。
#   marketplace.json に掲載したまま runner を退避した写しを与えると (0) が赤になる（同日実測）。runner の SUITES から
#   1 本（export-mock）だけ外した写しを与えると (2) が「total=3」で赤になる（同日実測）。
#   統合後の必須8本はtotal=8/passed=8/failed=0で緑、production-packだけを外した複製木は
#   total=7/passed=7/failed=0でも(2)が赤となることを実測した（2026-10-26）。
# run-all-required: no — node 20 以上が無い環境と、ff-agent-press を含まない木（公開 checkout）では丸ごと skip を許容する（node は CI セットアップに含まれるので CI では走る）
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../../.." && pwd -P)"
PLUGIN_ROOT="${REPO_ROOT}/plugins/ff-agent-press"
RUNNER="${PLUGIN_ROOT}/tests/run-all.sh"

MARKETPLACE="${REPO_ROOT}/.claude-plugin/marketplace.json"
# 公開 checkout（配布物 ff-dev-toolkit だけの木）にはこのプラグインが無い。marketplace.json に
# ff-agent-press が掲載されていない木では対象外として skip し、掲載されているのに runner が無い
# （SSOT で消えた）ときだけ赤にする
if [ ! -f "${MARKETPLACE}" ] || ! /usr/bin/grep -q '"name": "ff-agent-press"' "${MARKETPLACE}"; then
  echo "○ skip: この木の marketplace.json に ff-agent-press が無い（公開 checkout 等）ため対象外です（検査は1件も実行されていません）"
  exit 0
fi
if [ ! -f "${RUNNER}" ]; then
  echo "✗ ${RUNNER} がありません（marketplace.json には掲載されているのに runner が消えている）" >&2
  exit 1
fi
# shellcheck source=../../../ff-agent-press/scripts/lib/node-bin.sh
. "${PLUGIN_ROOT}/scripts/lib/node-bin.sh"
# node の解決失敗は「見つからない」だけを skip にし、明示指定の誤り・古い版・起動不能は赤にする
node_err="$(ff_agent_press_node 2>&1 >/dev/null)"; node_rc=$?
if [ "${node_rc}" -ne 0 ]; then
  case "${node_err}" in
    *見つかりません*)
      echo "○ skip: node 20 以上が見つからないため ff-agent-press の suite を回せません（検査は1件も実行されていません）"
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

echo "== ff-agent-press（プラグイン側 runner） =="
out="$(bash "${RUNNER}" 2>&1)"; rc=$?
printf '%s\n' "${out}" | sed 's/^/    /'
if [ "${rc}" -eq 0 ]; then ok "(1) runner exit 0"; else bad "(1) runner exit ${rc}"; fi

summary="$(printf '%s\n' "${out}" | /usr/bin/grep -E '^ff-agent-press suites: total=[0-9]+ passed=[0-9]+ failed=[0-9]+$' | tail -1)"
total="$(printf '%s' "${summary}" | sed -n 's/.*total=\([0-9]*\).*/\1/p')"
failed="$(printf '%s' "${summary}" | sed -n 's/.*failed=\([0-9]*\).*/\1/p')"
if [ -n "${summary}" ] && [ "${total:-0}" -ge 8 ] && [ "${failed:-1}" -eq 0 ]; then
  ok "(2) 集約行: ${summary}"
else
  bad "(2) 集約行が無い・total が 8 未満・failed が 0 でない: '${summary}'"
fi

echo "ff-agent-press: passed=${pass} failed=${fail}"
[ "${fail}" -eq 0 ]
