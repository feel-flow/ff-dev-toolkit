# 母集団 0 件の (unmeasured) 分岐を外す（中央値 0 を過大側と報告する）。検査 4h の空入力が赤になる
import io
p = "plugins/ff-dev-toolkit/scripts/effort-report.sh"
s = io.open(p, encoding="utf-8").read()
a = '  if (vn == 0) vpos = "(unmeasured)"\n  else if (vmed > upper + 0)'
assert a in s, "anchor not found"
s = s.replace(a, '  if (vmed > upper + 0)', 1)
io.open(p, "w", encoding="utf-8").write(s)
