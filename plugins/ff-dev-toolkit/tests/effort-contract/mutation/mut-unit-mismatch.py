import io
p = "plugins/ff-dev-toolkit/scripts/effort-report.sh"
s = io.open(p, encoding="utf-8").read()
# effort_unit: h のブロックにある d 値を食い違いとして除外せず、×8 で黙って合流させる
a = '    if (unit == "h") return -3\n'
assert s.count(a) == 1, "anchor not found"
s = s.replace(a, "", 1)
io.open(p, "w", encoding="utf-8").write(s)
