# --deploy-check の未閉鎖判定（inblock）を外す。検査 5b の「end の無いブロックは malformed」が赤になる
import io
p = "plugins/ff-dev-toolkit/scripts/effort-report.sh"
s = io.open(p, encoding="utf-8").read()
a = '      if (inblock || broken) { print "malformed"; exit }\n      if (!hasblock)'
assert a in s, "anchor not found"
s = s.replace(a, '      if (broken) { print "malformed"; exit }\n      if (!hasblock)', 1)
io.open(p, "w", encoding="utf-8").write(s)
