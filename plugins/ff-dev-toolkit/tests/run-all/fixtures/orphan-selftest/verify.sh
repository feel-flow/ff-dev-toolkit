#!/usr/bin/env bash
#
# 対になる本体 suite を持たない `-selftest` 名の疑似 suite（tests/run-all/verify.sh 専用の
# fixture）。高速モード（**引数なしの既定**。ADR-034）が「`-selftest` 終端 **かつ** 対の本体
# suite が実在する」ものだけを除外し、対を持たない selftest は実行することを実測する
# （ADR-031）。
#
# **`fixtures/orphan/` を作らないこと。** 作った瞬間にこの fixture は除外側へ移り、
# 検査が裏返る（対の不在は tests/run-all/verify.sh の前提アサーションが実測する）。
# 目印文字列は tests/run-all/verify.sh が探すので変更しないこと。

set -euo pipefail

echo "FIXTURE-ORPHAN-SELFTEST-EXECUTED"
exit 0
