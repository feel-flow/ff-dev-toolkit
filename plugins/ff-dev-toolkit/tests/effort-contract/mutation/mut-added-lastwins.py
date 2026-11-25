import io
p = "plugins/ff-dev-toolkit/scripts/effort-report.sh"
s = io.open(p, encoding="utf-8").read()
a = "  else if (key == \"effort_ai_planned_added\") { pa_raw[num, ++pa_n[num]] = val }\n"
assert s.count(a) == 1, "anchor not found"
b = "  else if (key == \"effort_ai_planned_added\") { pa_raw[num, 1] = val; pa_n[num] = 1 }\n"
io.open(p, "w", encoding="utf-8").write(s.replace(a, b, 1))
