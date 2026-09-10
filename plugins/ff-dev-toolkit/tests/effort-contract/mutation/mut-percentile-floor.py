# nearest-rank の切り上げを切り捨てへ戻す変異。
# p10 / p90 は fixture 上 ceil と floor が一致するため、旧来の p90 だけの検査では
# 検出できない。p25 / p75 の検査（検査 4b）が効いていることの実証になる。
import io
p = "plugins/ff-dev-toolkit/scripts/effort-report.sh"
s = io.open(p, encoding="utf-8").read()
a = "  idx = int(q * n)\n  if (idx < q * n) idx++\n"
assert a in s, "anchor not found"
s = s.replace(a, "  idx = int(q * n)\n", 1)
io.open(p, "w", encoding="utf-8").write(s)
