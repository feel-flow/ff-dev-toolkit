# 帯の判定を閉区間から開区間へ変える変異（端ちょうどを閾値外に数える）。
# 較正で決めた下限・上限そのものを持つ Issue が「閾値超過」と報告されるようになる。
# fixture 上は out_of_band が 2 → 4 へ増える（検査 4e）。
import io
p = "plugins/ff-dev-toolkit/scripts/effort-report.sh"
s = io.open(p, encoding="utf-8").read()
a = "      if (v < lower + 0 || v > upper + 0) out_of_band++"
assert a in s, "anchor not found"
s = s.replace(a, "      if (v <= lower + 0 || v >= upper + 0) out_of_band++", 1)
io.open(p, "w", encoding="utf-8").write(s)
