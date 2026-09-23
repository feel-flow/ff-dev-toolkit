import io
p = "plugins/ff-dev-toolkit/scripts/effort-report.sh"
s = io.open(p, encoding="utf-8").read()
# 空の単位宣言を旧ブロックとして読む（書式不正にしない）
a = '    if ((n in unit_raw) && unit != "h") { malformed++; continue }'
assert s.count(a) == 1, "anchor not found"
s = s.replace(a, '    if (unit != "" && unit != "h") { malformed++; continue }', 1)
io.open(p, "w", encoding="utf-8").write(s)
