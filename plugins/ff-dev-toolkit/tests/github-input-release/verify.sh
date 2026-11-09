#!/usr/bin/env bash
# Isolated acquisition parity and mandatory-input boundaries; no network or service write.
# run-all-required: yes — SSOT release取得点の不足を停止し、公開Git rootのみ明示的適用外
# 空振り検出: case集合0・raw fixture消失・source針消失を各rc=1で測定。正常空run/warming-upと必須field/phase/page/log不足rc=2、任意sync取得不能SKIPを別測定する。
# 空振り検出: 2026-10-23 R1でmatching create-readbackの不要PLANとprepare-finalizeの非入力rc2誤分類2原因を旧runtimeで3件赤、修正後79件rc0。missing/mismatchはexact PLAN+rc2、complete時PLAN無し、必須不足と隣接phaseを別測定。
# 空振り検出: 2026-10-23 R2は正常/隣接phaseとも両rc0・空stderr・最終plan marker一意を確認。旧driver/marker欠落の逆変異は各2件だけ赤、正常79件rc0。閉じた3globalsの欠落/重複と空sourceは全7件rc1。
# 空振り検出: 2026-11-09 ADR-086（健全性判定は公開側の週次、gate段は週次を読まず毎回全件）。gh stubは公開側のweekly-public-run-all.ymlだけに応答し他名・他repoは404。複製木の変異で、WORKFLOWを非公開側へ戻す38件・健全性判定をADR-086前へ戻す41件・release本体をADR-086前へ戻す5件・gate段へweekly_health呼出とgate受理を戻す5件が各rc1、無変異96件rc0。
set -euo pipefail
suite_dir="$(CDPATH='' cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
exec python3 "$suite_dir/verify.py" "$@"
