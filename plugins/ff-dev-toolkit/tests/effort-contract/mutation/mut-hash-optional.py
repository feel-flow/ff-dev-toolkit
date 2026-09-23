import io
p = "plugins/ff-dev-toolkit/hooks/record-effort-wallclock.sh"
s = io.open(p, encoding="utf-8").read()
# Issue 番号抽出の # を任意に戻す（日付入りブランチを Issue と読む）
a = "  local re='^[A-Za-z0-9_.-]+/#([0-9]+)([-_/].*)?$'"
assert s.count(a) == 1, "anchor not found"
s = s.replace(a, "  local re='^[A-Za-z0-9_.-]+/#?([0-9]+)([-_/].*)?$'", 1)
io.open(p, "w", encoding="utf-8").write(s)
