import io
p = "plugins/ff-dev-toolkit/scripts/effort-report.sh"
s = io.open(p, encoding="utf-8").read()
# --issue-metrics のゲート分の記録不在を (unmeasured) でなく 0 で出す（未計測と 0 の合流）
a = '      else print "gate_runs=(unmeasured)\\ngate_minutes=(unmeasured)"\n'
assert s.count(a) == 1, "anchor not found"
s = s.replace(a, '      else print "gate_runs=0\\ngate_minutes=0"\n', 1)
io.open(p, "w", encoding="utf-8").write(s)
