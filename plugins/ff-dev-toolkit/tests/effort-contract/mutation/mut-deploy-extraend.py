# --deploy-check からブロック外の end（余分な end・begin より前の end）の検出を外す。検査 5b の余分な end・end だけの本文が赤になる
import io
p = "plugins/ff-dev-toolkit/scripts/effort-report.sh"
s = io.open(p, encoding="utf-8").read()
a = '{ if (!inblock) broken = 1; inblock = 0; next }'
assert a in s, "anchor not found"
s = s.replace(a, '{ inblock = 0; next }', 1)
io.open(p, "w", encoding="utf-8").write(s)
