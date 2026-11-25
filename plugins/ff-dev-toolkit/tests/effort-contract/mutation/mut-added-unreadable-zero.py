import io
p = "plugins/ff-dev-toolkit/scripts/effort-report.sh"
s = io.open(p, encoding="utf-8").read()
a = "        if (t < 0) added_bad = 1\n"
assert s.count(a) == 1, "anchor not found"
b = "        if (t < 0) added += 0\n"
io.open(p, "w", encoding="utf-8").write(s.replace(a, b, 1))
