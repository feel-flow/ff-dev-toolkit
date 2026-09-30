# --deploy-check が配備の行のキー名を読まなくなる（どの本文も missing）。検査 5b の「なし」・記入済みが赤になる
import io
p = "plugins/ff-dev-toolkit/scripts/effort-report.sh"
s = io.open(p, encoding="utf-8").read()
a = '      if (key != "effort_deploy") next\n'
assert a in s, "anchor not found"
s = s.replace(a, '      if (key != "effort_deploy_") next\n', 1)
io.open(p, "w", encoding="utf-8").write(s)
