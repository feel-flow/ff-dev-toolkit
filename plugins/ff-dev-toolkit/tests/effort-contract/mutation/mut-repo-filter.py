import io
p = "plugins/ff-dev-toolkit/scripts/effort-report.sh"
s = io.open(p, encoding="utf-8").read()
# wall-clock の start を repo 列で絞らない（別リポジトリ・repo 列なしの同じ番号が混ざる）
a = '$1 == want && $7 == repo && $2 == "start" && $3 ~ /^[0-9]+$/ {'
assert s.count(a) == 1, "anchor not found"
s = s.replace(a, '$1 == want && $2 == "start" && $3 ~ /^[0-9]+$/ {', 1)
io.open(p, "w", encoding="utf-8").write(s)
