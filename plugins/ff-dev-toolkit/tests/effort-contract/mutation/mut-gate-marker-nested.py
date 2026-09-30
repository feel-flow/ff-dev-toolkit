import io
p = "plugins/ff-dev-toolkit/tests/run-all.sh"
s = io.open(p, encoding="utf-8").read()
# ゲート分の記録から走行中マーカーによる入れ子判定を外す（env を隔離した入れ子が
# 1 回ずつ gate.tsv へ積まれる状態へ戻る。環境変数の判定は残る）
a = '  ! ff_gate_marker_nested || return 0\n'
assert s.count(a) == 1, "anchor not found"
s = s.replace(a, "", 1)
io.open(p, "w", encoding="utf-8").write(s)
