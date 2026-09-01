import io
p = "plugins/ff-dev-toolkit/scripts/effort-report.sh"
s = io.open(p, encoding="utf-8").read()
a = "  idx = int(0.9 * n)\n  if (idx < 0.9 * n) idx++"
assert a in s, "anchor not found"
s = s.replace(a, "  idx = n", 1)
io.open(p, "w", encoding="utf-8").write(s)
