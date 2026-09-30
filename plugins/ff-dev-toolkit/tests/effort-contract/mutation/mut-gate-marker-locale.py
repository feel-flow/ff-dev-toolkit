import io
p = "plugins/ff-dev-toolkit/tests/run-all.sh"
s = io.open(p, encoding="utf-8").read()
# 書く側の開始時刻からロケール / TZ の固定を外す（利用者のロケールの表記で書かれ、
# env を隔離した子の C.UTF-8 の表記と一致しなくなる）
a = 'start="$(LC_ALL=C TZ=UTC0 ps -o lstart= -p "$$" 2>/dev/null)"'
assert s.count(a) == 1, "anchor not found"
s = s.replace(a, 'start="$(ps -o lstart= -p "$$" 2>/dev/null)"', 1)
io.open(p, "w", encoding="utf-8").write(s)
