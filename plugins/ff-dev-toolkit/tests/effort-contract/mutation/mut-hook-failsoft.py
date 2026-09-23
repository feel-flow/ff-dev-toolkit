import io
p = "plugins/ff-dev-toolkit/hooks/record-effort-wallclock.sh"
s = io.open(p, encoding="utf-8").read()
# 記録置き場を作れないとき黙って通さず、非 0 で止める（fail-soft の反転）
a = 'mkdir -p "$METRICS_DIR" 2>/dev/null || exit 0\n'
assert s.count(a) == 1, "anchor not found"
s = s.replace(a, 'mkdir -p "$METRICS_DIR" 2>/dev/null || { echo "記録できません" ; exit 2; }\n', 1)
io.open(p, "w", encoding="utf-8").write(s)
