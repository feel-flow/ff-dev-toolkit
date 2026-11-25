import io
p = "plugins/ff-dev-toolkit/scripts/effort-report.sh"
s = io.open(p, encoding="utf-8").read()
# 加算行の値を単位宣言どおりに正規化しない（旧 d の ×8 と単位の食い違いの判定を外す）
a = "  return as_hours(tok, unit)\n"
assert s.count(a) == 1, "anchor not found"
b = "  sub(/[hd]$/, \"\", tok)\n  return tok + 0\n"
io.open(p, "w", encoding="utf-8").write(s.replace(a, b, 1))
