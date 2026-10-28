#!/usr/bin/env bash
# gh/file knowledge acquisition parity; no network or external write.
# run-all-required: yes — 任意取得のunknown/SKIPと必須不足/PLAN/read-back境界を検証する
# 空振り検出: case集合0・fixture欠落・source針消失を各 rc=1 で拒否する自己検査を含む。mandatory body欠落・別repo・不正JSONは effort.issues rc=2、正常[]はrc=0を別測定する。
# 空振り検出: 明示空値 --github-input "" の5入口は修正前に各期待違反、修正後は全rc2/gh呼出0を実測（2026-10-22）。
# 空振り検出: 2026-10-23 R1でuserinfo/local-bare originのadd/commitは旧wrapper4件rc2・direct4件rc0を実測。修正後default73件rc0、consumer-only38件はPARTIAL。必須identity停止・明示空/相対path拒否も維持。
# 空振り検出: 2026-10-28 WSLで、空白・単引用・$(...)・;を含むディレクトリのfixtureと一時領域を旧verify.py（パスをgh stubのbash本文へ連結）へ渡すと、stubがsentinelを作りconsumer-onlyもrc1になることを実測。修正後はsentinel無しでconsumer-onlyがrc0。
set -euo pipefail
suite_dir="$(CDPATH='' cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# 引数付きの呼び出し（--consumer-only / --fixtures など）は従来どおりその1回だけを回す
[ "$#" -eq 0 ] || exec python3 "$suite_dir/verify.py" "$@"
python3 "$suite_dir/verify.py"

# fixtureのパスはgh stubの本文へ入る。シェルの構文に見える名前のディレクトリへ置いても、
# パスはデータのまま渡り、名前の中のコマンドが実行されないこと。
# 一時領域（TMPDIR）も同じ名前の下へ置き、stub が参照する一時ファイルのパスも同じ条件にする。
outer="$(mktemp -d)"
cleanup() {
  local rc=$?
  rm -rf "$outer"
  exit "$rc"
}
trap cleanup EXIT
odd="$outer/fx 'q' \$(touch \"\$TMPDIR\"-f16);x"
mkdir -p "$odd/tmp"
cp -R "$suite_dir/fixtures" "$odd/fixtures"
if ! TMPDIR="$odd/tmp" python3 "$suite_dir/verify.py" --consumer-only --fixtures "$odd/fixtures" >"$outer/odd.log" 2>&1; then
  cat "$outer/odd.log" >&2
  echo "  ✗ シェルの構文に見える名前のディレクトリのfixtureで consumer-only が失敗しました" >&2
  exit 1
fi
sentinels="$(find "$outer" -name '*-f16' -print)"
if [ -n "$sentinels" ]; then
  echo "  ✗ fixtureのパスがgh stubでコマンドとして実行されました: $sentinels" >&2
  exit 1
fi
echo "  ✓ シェルの構文に見える名前のディレクトリのfixtureでも、パスをデータとして扱いconsumer-onlyが通る（sentinel無し）"
