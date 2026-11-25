import io
p = "plugins/ff-dev-toolkit/scripts/effort-report.sh"
s = io.open(p, encoding="utf-8").read()
# 値の後ろの照合を外す（`+3.0h + 4.0h` や `+3.0h（…）、+4.0h（…）` を先頭の値だけで読む）
a = "  if (!added_note_ok(rest)) return -2\n"
assert s.count(a) == 1, "anchor not found"
io.open(p, "w", encoding="utf-8").write(s.replace(a, "", 1))
