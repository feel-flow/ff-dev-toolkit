# 中央値の位置の下限側を開区間へ倒す（下限ちょうどの中央値を過大側へ数える）。検査 4h の median-lower-edge が赤になる
import io
p = "plugins/ff-dev-toolkit/scripts/effort-report.sh"
s = io.open(p, encoding="utf-8").read()
a = '  else if (vmed < lower + 0) vpos = "overestimate"'
assert a in s, "anchor not found"
s = s.replace(a, '  else if (vmed <= lower + 0) vpos = "overestimate"', 1)
io.open(p, "w", encoding="utf-8").write(s)
