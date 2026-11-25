import io
p = "plugins/ff-dev-toolkit/scripts/effort-report.sh"
s = io.open(p, encoding="utf-8").read()
a = "        v = aa / (ap + added)\n"
assert s.count(a) == 1, "anchor not found"
b = "        v = aa / ap\n"
io.open(p, "w", encoding="utf-8").write(s.replace(a, b, 1))
