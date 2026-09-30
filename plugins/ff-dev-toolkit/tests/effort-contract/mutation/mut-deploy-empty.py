# --deploy-check から空値の判定（val == ""）を外す。検査 5b の「値が空の配備の行は unfilled」が赤になる
import io
p = "plugins/ff-dev-toolkit/scripts/effort-report.sh"
s = io.open(p, encoding="utf-8").read()
a = 'if (val == "" || val == "(未記入)"'
assert a in s, "anchor not found"
s = s.replace(a, 'if (val == "(未記入)"', 1)
io.open(p, "w", encoding="utf-8").write(s)
