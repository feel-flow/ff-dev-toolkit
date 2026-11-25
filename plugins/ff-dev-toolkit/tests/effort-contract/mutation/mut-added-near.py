import io
p = "plugins/ff-dev-toolkit/scripts/effort-report.sh"
s = io.open(p, encoding="utf-8").read()
# 加算行に似ているのに読めない行（字下げ・全角コロン・ブロックの外・`*` の箇条）を覚えない
a = "      added = 0; added_bad = (n in pa_near) ? 1 : 0\n"
assert s.count(a) == 1, "anchor not found"
io.open(p, "w", encoding="utf-8").write(s.replace(a, "      added = 0; added_bad = 0\n", 1))
