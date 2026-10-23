#!/usr/bin/env bash
# gh/file knowledge acquisition parity; no network or external write.
# run-all-required: yes — 任意取得のunknown/SKIPと必須不足/PLAN/read-back境界を検証する
# 空振り検出: case集合0・fixture欠落・source針消失を各 rc=1 で拒否する自己検査を含む。mandatory body欠落・別repo・不正JSONは effort.issues rc=2、正常[]はrc=0を別測定する。
# 空振り検出: 明示空値 --github-input "" の5入口は修正前に各期待違反、修正後は全rc2/gh呼出0を実測（2026-10-22）。
# 空振り検出: 2026-10-23 R1でuserinfo/local-bare originのadd/commitは旧wrapper4件rc2・direct4件rc0を実測。修正後default73件rc0、consumer-only38件はPARTIAL。必須identity停止・明示空/相対path拒否も維持。
set -euo pipefail
suite_dir="$(CDPATH='' cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
exec python3 "$suite_dir/verify.py" "$@"
