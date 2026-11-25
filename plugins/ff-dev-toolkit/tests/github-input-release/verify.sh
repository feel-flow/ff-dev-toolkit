#!/usr/bin/env bash
# Isolated acquisition parity and mandatory-input boundaries; no network or service write.
# run-all-required: yes — SSOT release取得点の不足を停止し、公開Git rootのみ明示的適用外
# 空振り検出: case集合0・raw fixture消失・source針消失を各rc=1で測定。正常空run/warming-upと必須field/phase/page/log不足rc=2、任意sync取得不能SKIPを別測定する。
# 空振り検出: 2026-10-23 R1でmatching create-readbackの不要PLANとprepare-finalizeの非入力rc2誤分類2原因を旧runtimeで3件赤、修正後79件rc0。missing/mismatchはexact PLAN+rc2、complete時PLAN無し、必須不足と隣接phaseを別測定。
# 空振り検出: 2026-10-23 R2は正常/隣接phaseとも両rc0・空stderr・最終plan marker一意を確認。旧driver/marker欠落の逆変異は各2件だけ赤、正常79件rc0。閉じた3globalsの欠落/重複と空sourceは全7件rc1。
# 空振り検出: 2026-11-09 ADR-086（健全性判定は公開側の週次、gate段は週次を読まず毎回全件）。gh stubは公開側のweekly-public-run-all.ymlだけに応答し他名・他repoは404。複製木の変異で、WORKFLOWを非公開側へ戻す38件・健全性判定をADR-086前へ戻す41件・release本体をADR-086前へ戻す5件・gate段へweekly_health呼出とgate受理を戻す5件が各rc1、無変異96件rc0。
#
# 依存の宣言（変更ベースの部分ゲートが、この suite を選ぶ変更）:
# run-all-depends: /scripts/release-dev-toolkit.sh /scripts/check-release-required.sh /scripts/check-dev-toolkit-sync-drift.sh /scripts/check-weekly-run-all-health.sh
# run-all-depends: /scripts/sync-dev-toolkit-to-public.sh /scripts/scan-unreachable-repo-refs.sh /scripts/materialize-dev-toolkit-changelog.sh
# run-all-depends: /scripts/lib/ scripts/lib/
# run-all-depends: /plugins/ff-media-toolkit/scripts/lib/node-bin*.sh tests/lib/git-fixture*.sh
# run-all-depends: /oss/ff-dev-toolkit/.github/workflows/weekly-public-run-all.yml
# run-all-not-depends: .claude-plugin/plugin.json 公開 Git root の判定にだけ読む（私有リポジトリでは toplevel が一致せず結果に効かない。検査用の plugin.json は fixture に書く）
# run-all-not-depends: tests/github-input/fixtures/cases.json 自 suite の fixtures/cases.json と同じ綴りの別 suite の fixture
# run-all-not-depends: tests/github-input-knowledge/fixtures/cases.json 自 suite の fixtures/cases.json と同じ綴りの別 suite の fixture
# run-all-not-depends: tests/github-input-precheck/fixtures/cases.json 自 suite の fixtures/cases.json と同じ綴りの別 suite の fixture
# run-all-not-depends: tests/github-input/fixtures/index.json 一時ディレクトリに書く index.json と同名の別 suite の fixture
# run-all-not-depends: /oss/ff-dev-toolkit/CHANGELOG.md fixture に書く CHANGELOG
# run-all-not-depends: /changelog.d/README.md fixture に書くファイル
# run-all-not-depends: /README.md fixture の公開 clone に書くファイル
# run-all-not-depends: /.github/workflows/weekly-run-all.yml gh stub の呼び出しに旧 workflow 名が出ないことを見る文字列
set -euo pipefail
suite_dir="$(CDPATH='' cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
exec python3 "$suite_dir/verify.py" "$@"
