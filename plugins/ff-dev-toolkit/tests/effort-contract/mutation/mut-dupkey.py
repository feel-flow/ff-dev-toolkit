import io
p = "plugins/ff-dev-toolkit/scripts/effort-report.sh"
s = io.open(p, encoding="utf-8").read()
a = "  if (key == \"effort_human_planned\") { if (num in hp_raw) broken[num] = 1; hp_raw[num] = val }\n  else if (key == \"effort_ai_planned\") { if (num in ap_raw) broken[num] = 1; ap_raw[num] = val }\n  else if (key == \"effort_ai_actual\")  { if (num in aa_raw) broken[num] = 1; aa_raw[num] = val }"
assert a in s, "anchor not found"
b = "  if (key == \"effort_human_planned\") hp_raw[num] = val\n  else if (key == \"effort_ai_planned\") ap_raw[num] = val\n  else if (key == \"effort_ai_actual\")  aa_raw[num] = val"
io.open(p, "w", encoding="utf-8").write(s.replace(a, b, 1))
