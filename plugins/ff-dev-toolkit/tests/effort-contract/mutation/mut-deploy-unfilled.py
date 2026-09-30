# --deploy-check から雛形のプレースホルダ（全体が [ … ]）の判定を外す。検査 5b の雛形のまま = unfilled が赤になる
import io
p = "plugins/ff-dev-toolkit/scripts/effort-report.sh"
s = io.open(p, encoding="utf-8").read()
a = ' || val ~ /^\\[.*\\]$/'
assert a in s, "anchor not found"
s = s.replace(a, '', 1)
io.open(p, "w", encoding="utf-8").write(s)
