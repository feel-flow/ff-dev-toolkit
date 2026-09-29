import io
p = "plugins/ff-dev-toolkit/scripts/effort-report.sh"
s = io.open(p, encoding="utf-8").read()
# 巡回記録の置き場走査を外す（削除済みブランチの記録が累積から落ちる）
a = '''    [ -d "$store" ] && find "$store" -maxdepth 1 -type f -name '*.tsv' 2>/dev/null \\
      | awk -v n="$issue" -F/ '$NF ~ ("^[A-Za-z_]+" n "-.*\\\\.tsv$")'
'''
assert s.count(a) == 1, "anchor not found"
s = s.replace(a, "    :\n", 1)
io.open(p, "w", encoding="utf-8").write(s)
