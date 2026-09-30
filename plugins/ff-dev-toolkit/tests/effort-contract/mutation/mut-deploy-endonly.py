# --deploy-check の判定順を「不在 → 破損」へ戻す。検査 5b の「end だけの本文は malformed」が赤になる
import io
p = "plugins/ff-dev-toolkit/scripts/effort-report.sh"
s = io.open(p, encoding="utf-8").read()
a = '      if (inblock || broken) { print "malformed"; exit }\n      if (!hasblock) { print "noblock"; exit }\n'
assert a in s, "anchor not found"
s = s.replace(a, '      if (!hasblock) { print "noblock"; exit }\n      if (inblock || broken) { print "malformed"; exit }\n', 1)
io.open(p, "w", encoding="utf-8").write(s)
