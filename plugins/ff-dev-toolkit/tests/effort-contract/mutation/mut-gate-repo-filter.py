import io
p = "plugins/ff-dev-toolkit/scripts/effort-report.sh"
s = io.open(p, encoding="utf-8").read()
# ゲート分の読み手から repo 列の絞り込みを外す（別リポジトリの同じ番号が混ざる）
a = '    $1 == want && $2 == "gate" && $9 == repo && $5 ~ /^[0-9]+$/ { total += $5; n++ }\n'
assert s.count(a) == 1, "anchor not found"
s = s.replace(a, '    $1 == want && $2 == "gate" && $5 ~ /^[0-9]+$/ { total += $5; n++ }\n', 1)
io.open(p, "w", encoding="utf-8").write(s)
