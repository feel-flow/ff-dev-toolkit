import io
p = "plugins/ff-dev-toolkit/scripts/effort-report.sh"
s = io.open(p, encoding="utf-8").read()
a = "    if (hp > 0) { hp_total += hp; pair_denom += aa; pair_n++ }"
assert a in s, "anchor not found"
s = s.replace(a, "    pair_denom += aa; pair_n++\n    if (hp > 0) { hp_total += hp }", 1)
io.open(p, "w", encoding="utf-8").write(s)
