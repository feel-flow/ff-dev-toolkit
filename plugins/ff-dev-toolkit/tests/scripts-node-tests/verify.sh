#!/usr/bin/env bash
# scripts-node-tests: 開発元（SSOT）の scripts/tests/ にある node テスト 3 本を、全件ゲートから回す。
# 空振り検出: 写しの木（3 本を 1 件ずつの合成テストに置き換えた root）で測った（2026-11-09 macOS / Bash 3.2.57 / Node 26.13.0）: 1 本を消す・名前だけ変える（.spec.mjs）・ディレクトリに置き換えるはいずれも N1 で rc 1、node を PATH から外すと N0 で rc 1、test() を 0 件にする・0 バイトにする・集計前に process.exit(0) するはいずれも node 自体は tests=1 / rc 0 を返すが N4 で rc 1（N4 を無効化した写しでは同じ 0 件ファイルが rc 0 の緑に倒れる）、失敗 1 件は N2・N3、skip 1 件と失敗する todo 1 件は N3、構文エラーは N2・N4、reporter を tap に変えた写しは集計行が読めず 3 本とも N3 で rc 1。対照（合成 3 本）と FORCE_COLOR=1 を渡した回は rc 0。
#
# 背景: 3 本（ff-work-toolkit の配布物・ff-privacy-check の SSOT と公開同期の契約・
# ff-privacy-check / ff-work-toolkit のリリーススクリプト）は、開発元の手動起動ワークフロー
# （.github/workflows/weekly-run-all.yml）の独立 step でだけ動いていた。定期実行は ADR-086 で
# やめたので、run-all の suite へ移し、全件ゲート（公開同期の gate 段は毎回全件）で回す。
#
# 検査（1 本ずつ別の node プロセスで、`node --test --test-reporter=spec` を開発元の root から起動する）:
#   N0. node が PATH に在る（全件ゲートの前提。無ければ赤。適用外として抜けない）
#   N1. 3 本がすべて通常ファイルとして在る（1 本でも欠ければ、どれも起動せずに赤）
#   N2. 各ファイルの終了コードが 0
#   N3. spec reporter の集計行 `ℹ tests N` / `ℹ pass N` / `ℹ fail N` が揃って読め、
#       tests が 1 以上・pass が tests と同数・fail / cancelled / skipped / todo が 0
#   N4. test() を 1 件も走らせなかったファイルではない。node はそのファイル自体を 1 件と数えて
#       tests=1・終了コード 0 で終えるので、終了コードと件数だけでは 0 件を見分けられない
#       （見分け方は file_as_test のコメント）
#
# 既知の限界: test() を走らせた後に途中で exit したファイルは、走った分だけの件数で緑になる
# （件数の下限は持たない。テストの増減のたびに本 suite を直す形を避けるため）。
#
# SSOT 専用 suite: scripts/tests/ は公開同期の対象外なので、公開 checkout では N1 で赤になる。
# 公開側の週次（oss/ff-dev-toolkit/.github/workflows/weekly-public-run-all.yml）は
# EXCLUDED_SSOT_SUITES でこの suite を外す。
#
# 色の制御文字が集計行へ混ざらないように、node は FORCE_COLOR を外し NO_COLOR=1 で起動する。
# 所要は 3 本で単独約 45 秒・他の検査と並走して約 85 秒（2026-11-09 macOS 実測）。テストは一時ディレクトリへ
# fixture を作り、作業ツリーを書き換えない（実行後の git status が空のままであることを確かめた）。
# bash 3.2 互換。パイプ入力の grep -q は使わない（集計行は awk で読む）。
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd -P)"
REPO_ROOT="$(cd "$PLUGIN_ROOT/../.." && pwd -P)"
TEST_DIR_REL="scripts/tests"
TEST_FILES="work-toolkit.test.mjs privacy-check-sync.test.mjs public-plugin-release.test.mjs"

PASS=0
FAIL=0
ok() { echo "  ✓ $1"; PASS=$((PASS + 1)); }
bad() { echo "  ✗ $1" >&2; FAIL=$((FAIL + 1)); }

echo "== scripts-node-tests: ${REPO_ROOT}/${TEST_DIR_REL} の node テスト =="

# N0. node の有無
if ! command -v node >/dev/null 2>&1; then
  echo "✗ scripts-node-tests: node が PATH にありません（全件ゲートの前提。検査は 1 件も実行されていません）" >&2
  exit 1
fi
ok "N0: node が在る（$(command -v node) / $(node --version 2>/dev/null || echo 'version 不明')）"

# N1. 3 本の実在（1 本でも欠ければ起動しない — 欠けた 1 本を残り 2 本の緑で覆わない）
missing=""
for f in $TEST_FILES; do
  if [ ! -f "$REPO_ROOT/$TEST_DIR_REL/$f" ]; then
    missing="$missing $TEST_DIR_REL/$f"
  fi
done
if [ -n "$missing" ]; then
  echo "✗ scripts-node-tests: node テストが見つかりません:${missing}（改名・削除なら本 suite の TEST_FILES を同時に直す。検査は 1 件も実行されていません）" >&2
  exit 1
fi
ok "N1: 3 本が在る（${TEST_FILES}）"

# 集計行 `ℹ <key> <N>` の N を返す（無ければ空）。最後の出現を採る。
summary_value() { # $1=出力 $2=key
  printf '%s\n' "$1" | awk -v k="$2" '$1 == "ℹ" && $2 == k && $3 ~ /^[0-9]+$/ { v = $3 } END { print v }'
}
# test() を 1 件も走らせなかったファイル（空・test() の消失・集計前の exit）を、node は
# 「ファイル自体を 1 件」と数えて pass にする（tests=1 / 終了コード 0。2026-11-09 Node 26 で実測）。
# そのとき結果行の名前は起動時に渡したパスそのものになるので、その行の有無で見分ける。
file_as_test() { # $1=出力 $2=起動時に渡したパス → 1 / 0
  printf '%s\n' "$1" | awk -v p="$2" '
    index($0, "✔ " p " (") == 1 || index($0, "✖ " p " (") == 1 { hit = 1 }
    END { print hit + 0 }'
}

for f in $TEST_FILES; do
  echo "-- node --test --test-reporter=spec ${TEST_DIR_REL}/${f}"
  rc=0
  out="$(cd "$REPO_ROOT" && env -u FORCE_COLOR NO_COLOR=1 node --test --test-reporter=spec "$TEST_DIR_REL/$f" 2>&1)" || rc=$?
  printf '%s\n' "$out" | sed 's/^/    /'

  if [ "$rc" -eq 0 ]; then
    ok "N2: ${f} の終了コードが 0"
  else
    bad "N2: ${f} の終了コードが ${rc}（失敗したテストは上の出力の ✖ 行）"
  fi

  tests="$(summary_value "$out" tests)"
  pass="$(summary_value "$out" pass)"
  fail="$(summary_value "$out" fail)"
  cancelled="$(summary_value "$out" cancelled)"
  skipped="$(summary_value "$out" skipped)"
  todo="$(summary_value "$out" todo)"
  if [ -z "$tests" ] || [ -z "$pass" ] || [ -z "$fail" ] || [ -z "$cancelled" ] || [ -z "$skipped" ] || [ -z "$todo" ]; then
    bad "N3: ${f} の集計行（ℹ tests / pass / fail / cancelled / skipped / todo）が揃って読めない（reporter の書式変更か途中終了。件数を確かめられない回を緑にしない）"
    continue
  fi
  if [ "$tests" -lt 1 ]; then
    bad "N3: ${f} で走ったテストが 0 件"
  elif [ "$(file_as_test "$out" "$TEST_DIR_REL/$f")" = 1 ]; then
    bad "N4: ${f} は test() を 1 件も走らせていない（node がファイル自体を 1 件と数えた結果行 \`${TEST_DIR_REL}/${f} (…)\` がある。空ファイル・test() の消失・集計前の exit）"
  elif [ "$pass" -ne "$tests" ] || [ "$fail" -ne 0 ] || [ "$cancelled" -ne 0 ] || [ "$skipped" -ne 0 ] || [ "$todo" -ne 0 ]; then
    bad "N3: ${f} の集計が全件 pass ではない（tests=${tests} pass=${pass} fail=${fail} cancelled=${cancelled} skipped=${skipped} todo=${todo}）"
  else
    ok "N3: ${f} は ${tests} 件すべて pass（fail / cancelled / skipped / todo は 0）"
  fi
done

echo
echo "scripts-node-tests: pass=${PASS} fail=${FAIL}"
if [ "$FAIL" -ne 0 ]; then
  exit 1
fi
echo "✓ scripts-node-tests: node テスト 3 本がすべて通った"
