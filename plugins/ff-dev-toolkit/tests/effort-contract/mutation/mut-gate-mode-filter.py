import io
p = "plugins/ff-dev-toolkit/scripts/effort-report.sh"
s = io.open(p, encoding="utf-8").read()
# ゲート分の読み手から mode 列（fast / full / changed）の絞り込みを外す（explicit 行が合算される）
a = '    $1 == want && $2 == "gate" && $9 == repo && ($6 == "fast" || $6 == "full" || $6 == "changed") && $5 ~ /^[0-9]+$/ { total += $5; n++ }\n'
assert s.count(a) == 1, "anchor not found"
s = s.replace(a, '    $1 == want && $2 == "gate" && $9 == repo && $5 ~ /^[0-9]+$/ { total += $5; n++ }\n', 1)
io.open(p, "w", encoding="utf-8").write(s)
