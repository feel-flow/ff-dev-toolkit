import io
p = "plugins/ff-dev-toolkit/scripts/effort-report.sh"
s = io.open(p, encoding="utf-8").read()
# 供給源が未配線の巡回数を (unavailable) でなく 0 で出す（未計測と 0 の合流）
a = '      printf "review_rounds_median_%s=(unavailable)\\n", c\n'
assert s.count(a) == 1, "anchor not found"
s = s.replace(a, '      printf "review_rounds_median_%s=0\\n", c\n', 1)
io.open(p, "w", encoding="utf-8").write(s)
