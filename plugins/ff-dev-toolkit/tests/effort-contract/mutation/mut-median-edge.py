# 中央値の位置の判定を開区間へ倒す（上限ちょうどの中央値を過小側へ数える）。検査 4h の median-edge が赤になる
import io
p = "plugins/ff-dev-toolkit/scripts/effort-report.sh"
s = io.open(p, encoding="utf-8").read()
a = '  else if (vmed > upper + 0) vpos = "underestimate"'
assert a in s, "anchor not found"
s = s.replace(a, '  else if (vmed >= upper + 0) vpos = "underestimate"', 1)
io.open(p, "w", encoding="utf-8").write(s)
