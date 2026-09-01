import io
p = "plugins/ff-dev-toolkit/scripts/effort-report.sh"
s = io.open(p, encoding="utf-8").read()
a = '  if (s !~ /^[0-9]+(\\.[0-9]+)?d$/) return -2'
assert a in s, "anchor not found"
s = s.replace(a, '  if (s ~ /^[0-9]+(\\.[0-9]+)?h$/) { sub(/h$/, "", s); return s + 0 }\n' + a, 1)
io.open(p, "w", encoding="utf-8").write(s)
