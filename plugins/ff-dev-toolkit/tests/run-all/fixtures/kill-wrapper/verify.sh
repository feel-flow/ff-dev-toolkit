#!/usr/bin/env bash
#
# 並列実行のラッパー subshell を SIGKILL し、「終了コードを残さず子が消えた」経路を
# 作る疑似 suite（tests/run-all/verify.sh 専用の fixture。Issue #595）。
#
# run-all.sh の並列経路は各 suite を `( bash "$script" >out; echo $? >rc.part; mv ... ) &`
# で起動するので、この fixture の親プロセス（${PPID}）はそのラッパー subshell である。
# ラッパーを SIGKILL すると rc が置かれないまま消え、ランナー側の gone 判定
# （pass にも fail にも倒さず「未実行」へ数える）が発火する。
#
# 安全弁: FF_FIXTURE_KILL_PARENT=1 のときだけ発火する。素で `bash verify.sh` した
# ときの $PPID は呼び出し元のシェルなので、無条件に撃つと利用者のシェルを殺す。
# 環境変数が無ければ何もせず skip として振る舞い、単独実行しても無害にする。

set -euo pipefail

if [[ "${FF_FIXTURE_KILL_PARENT:-0}" != "1" ]]; then
  echo "○ skip: FF_FIXTURE_KILL_PARENT=1 が無いため親を撃たない（この fixture は run-all の並列ラッパーを殺すためのもの）"
  exit 0
fi

kill -9 "$PPID"

# ここへ到達するのは親を撃ち損ねた場合。ランナー側の期待（rc が置かれない）が
# 崩れているので、成功として終わらせない。
echo "✗ 親プロセス（並列ラッパー）を撃てなかった: PPID=${PPID}" >&2
exit 1
