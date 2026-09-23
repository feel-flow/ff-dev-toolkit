import io
p = "plugins/ff-dev-toolkit/scripts/effort-report.sh"
s = io.open(p, encoding="utf-8").read()
# 旧 d ブロックの ×8 正規化を外す（人日の値が人時の母集団へ 1/8 の重みで混ざる）
a = "    return (v <= 0) ? -2 : v * 8\n"
assert s.count(a) == 1, "anchor not found"
s = s.replace(a, "    return (v <= 0) ? -2 : v\n", 1)
io.open(p, "w", encoding="utf-8").write(s)
