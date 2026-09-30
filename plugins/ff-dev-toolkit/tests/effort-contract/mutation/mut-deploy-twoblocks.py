# --deploy-check から 2 組目のブロックの検出を外す。検査 5b の「2 組目のブロックは malformed」が赤になる
import io
p = "plugins/ff-dev-toolkit/scripts/effort-report.sh"
s = io.open(p, encoding="utf-8").read()
a = '{ if (hasblock) broken = 1; inblock = 1; hasblock = 1; next }'
assert a in s, "anchor not found"
s = s.replace(a, '{ inblock = 1; hasblock = 1; next }', 1)
io.open(p, "w", encoding="utf-8").write(s)
