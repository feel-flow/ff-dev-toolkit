import io
p = "plugins/ff-dev-toolkit/scripts/effort-report.sh"
s = io.open(p, encoding="utf-8").read()
a = "  idx = int(q * n)\n  if (idx < q * n) idx++"
assert a in s, "anchor not found"
s = s.replace(a, "  idx = n", 1)
io.open(p, "w", encoding="utf-8").write(s)
