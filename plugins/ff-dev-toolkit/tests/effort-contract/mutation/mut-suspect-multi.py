# 「行全体が 1 個の HTML コメント」の内側ガードだけを外す。
#
# 残る `^<!--.*-->$` は貪欲なので、1 行に 2 個のコメントがある行（間の散文で
# ff-effort に言及しているだけ）も通り、コメントの外にある語を疑い始める。
# 変異 9b（限定そのものの撤去）より狭い、正規表現の性質に由来する単点の穴。
import io

p = "plugins/ff-dev-toolkit/scripts/effort-report.sh"
s = io.open(p, encoding="utf-8").read()

guard = '  t = substr(t, 5, length(t) - 7)   # 前後の <!-- と --> を外した中身\n  if (index(t, "-->") > 0) return 0\n'

assert guard in s, "anchor not found"
s = s.replace(guard, "", 1)
io.open(p, "w", encoding="utf-8").write(s)
