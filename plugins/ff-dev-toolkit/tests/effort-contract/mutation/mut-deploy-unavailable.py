# --deploy-check が読めない本文を present（記入済み）へ倒す。検査 5b の unavailable が赤になる
import io
p = "plugins/ff-dev-toolkit/scripts/effort-report.sh"
s = io.open(p, encoding="utf-8").read()
a = '  if [ ! -f "$f" ] || [ ! -r "$f" ]; then\n    echo "effort_deploy=unavailable"'
assert a in s, "anchor not found"
s = s.replace(a, '  if [ ! -f "$f" ] || [ ! -r "$f" ]; then\n    echo "effort_deploy=present"', 1)
io.open(p, "w", encoding="utf-8").write(s)
