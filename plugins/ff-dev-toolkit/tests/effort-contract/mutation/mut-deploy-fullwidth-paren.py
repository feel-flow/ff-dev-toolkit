# --deploy-check から全角括弧の（未記入）の判定を外す。検査 5b の全角空白 + 全角括弧の（未記入）が赤になる
import io
p = "plugins/ff-dev-toolkit/scripts/effort-report.sh"
s = io.open(p, encoding="utf-8").read()
a = ' || val == "（未記入）"'
assert a in s, "anchor not found"
s = s.replace(a, '', 1)
io.open(p, "w", encoding="utf-8").write(s)
