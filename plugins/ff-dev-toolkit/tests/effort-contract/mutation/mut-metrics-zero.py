import io
p = "plugins/ff-dev-toolkit/scripts/effort-report.sh"
s = io.open(p, encoding="utf-8").read()
# 記録不在（空振り）を (unmeasured) でなく 0 で出す
a = 'print "wallclock_end=(unmeasured)"; print "wallclock_actual_h=(unmeasured)"; exit 0'
assert s.count(a) == 1, "anchor not found"
s = s.replace(a, 'print "wallclock_end=(unmeasured)"; print "wallclock_actual_h=0"; exit 0', 1)
io.open(p, "w", encoding="utf-8").write(s)
