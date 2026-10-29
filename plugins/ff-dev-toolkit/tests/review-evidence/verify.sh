#!/usr/bin/env bash
# 空振り検出: 私有fixtureの旧パス化（evidence/run-all/shim）・GROK_HOME不在・shell入力空の6変異は全て赤。先取りした旧名のsentinelは正常対照2testで不変（2026-10-29 macOS実測）。shell入力不在も読取失敗で赤、cases入力の不在/空とprivacy test名の脱落は起動前に拒否する。
# 空振り検出: retained-cacheの正常対照2testは通過。保存木の退避除外を外すと旧report参照がFileNotFound、保存木検査を空にするとunsafe6組と下限が7failure、入力case集合を空にすると下限1failure（全変異syntax0、2026-10-28実測）。UUID reportの保持と未知名・親/leafリンク・directory/FIFO・hardlinkの移動前拒否を実producer/archiverで測る。
# 空振り検出: evidence/schema/plan/task/report/required perspectives 不在は赤（cases.py で実測）。stub が root を消さなかった回（消去の印が無い）も赤。
#   test_continued_host_delegation_adopts_all_from_the_advertised_command を単独実行し、
#   report 分岐だけを旧 with --resume へ戻す変異と pending 案内を空にする変異は各 1 failure / 0 errors。
#   test_continued_host_delegation_missing_response_is_not_complete を単独実行し、2 回目の明示
#   --output-dir を無視する変異は新しい出力先での再委譲時に 1 failure / 0 errors（初回 handoff は通過）。
# 非 UTF-8 の既定 encoding（python3 -I -X utf8=0 かつ LC_ALL=C）で、1 行目に U+2014 を含む
# 統合レポートの prior / parent を begin と verify できる。証跡 JSON に入れた U+2014 は
# begin の書き込みと finish の読み戻しを通り、結果ファイル中の U+2014 は finish が読む。
# 統合レポート読み、証跡 JSON の読み書き、結果読みの encoding 指定をそれぞれ外すと、この検査が赤になる。
# 変異検出: HEAD/base/branch/remotes/report path/digest/prior order/partial lineage の改変を拒否。
#   continuation + ホスト委譲は複数観点の handoff 件数・集合を固定し、表示コマンドを実行して系譜・coverage を照合する。
#   handoff / task / response が空・不足の回を完了扱いしない。先行・継続証跡と resume/fresh の拒否は維持する。
#   report と stderr の合法な再実行案内を照合し、一部受理後は新しい空の出力先へ全観点を再委譲して収束する。
#   旧出力の保全・既定上限 2 の同 HEAD 巡数不変・prior/parent の保持と通常委譲の部分 resume も照合する。
#   producer の開始時固定: 最後の CLI 呼び出し中に root が消えても・同じパスのまま書き換わっても finish が
#   開始時のバイト列で出す・開始時に読めない（不在 / symlink / 空 / 読めない）なら CLI 前に rc 2・
#   finish は plan 外の結果・生成後のレポート改変・producer digest の不一致・開始記録の改変と型崩れを拒否。
# run-all-required: yes — consumer ready の証跡束縛を検証する唯一の suite
set -euo pipefail
PLUGIN_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
. "$PLUGIN_ROOT/tests/lib/git-fixture.sh"
command -v python3 >/dev/null || { echo 'ERROR: python3 required' >&2; exit 1; }
CASES="$PLUGIN_ROOT/tests/review-evidence/cases.py"
[ -r "$CASES" ] && [ -s "$CASES" ] || { echo 'ERROR: evidence cases missing/unreadable/empty' >&2; exit 1; }
for _privacy_case in test_installed_fixture_ignores_precreated_shared_siblings test_shell_fixtures_ignore_precreated_shared_paths; do
  grep -F "    def ${_privacy_case}(self):" "$CASES" >/dev/null || {
    echo "ERROR: privacy regression case missing: $_privacy_case" >&2
    exit 1
  }
done
python3 "$CASES"
