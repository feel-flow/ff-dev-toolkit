import io
p = "plugins/ff-dev-toolkit/scripts/effort-report.sh"
s = io.open(p, encoding="utf-8").read()
# 読み込みバイトを wall-clock が実測済みの Issue だけで集計する（片側未計測で落ちる）
a = '    if (n in ib_raw) {\n'
assert s.count(a) == 1, "anchor not found"
s = s.replace(a, '    if ((n in ib_raw) && trim(wc_raw[n]) ~ /h$/) {\n', 1)
io.open(p, "w", encoding="utf-8").write(s)
