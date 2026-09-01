import io
p = "plugins/ff-dev-toolkit/scripts/check-issue-body-diff.sh"
s = io.open(p, encoding="utf-8").read()
a = 'if cmp -s "$OLD" "$NEW"; then'
assert a in s, "anchor not found"
s = s.replace(a, 'if false; then', 1)
s = s.replace('[ -s "$OLD" ] || die_unverifiable "変更前の本文が空です: ${OLD}"', ':', 1)
io.open(p, "w", encoding="utf-8").write(s)
