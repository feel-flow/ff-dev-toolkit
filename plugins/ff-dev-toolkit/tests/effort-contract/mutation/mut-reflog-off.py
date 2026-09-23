import io
p = "plugins/ff-dev-toolkit/scripts/effort-report.sh"
s = io.open(p, encoding="utf-8").read()
# start が無いときの reflog からの補いを外す
a = '    fb="$(metrics_reflog_start "$repo_dir" "$issue")"\n'
assert s.count(a) == 1, "anchor not found"
s = s.replace(a, '    fb=""\n', 1)
io.open(p, "w", encoding="utf-8").write(s)
