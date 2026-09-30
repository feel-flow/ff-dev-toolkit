# --deploy-check の trim から全角空白（U+3000）を外す。検査 5b の全角空白 + 全角括弧の（未記入）が赤になる
import io
p = "plugins/ff-dev-toolkit/scripts/effort-report.sh"
s = io.open(p, encoding="utf-8").read()
a = 'function trim(s) { sub(/^([ \\t]|\u3000)+/, "", s); sub(/([ \\t]|\u3000)+$/, "", s); return s }'
assert a in s, "anchor not found"
s = s.replace(a, 'function trim(s) { sub(/^[ \\t]+/, "", s); sub(/[ \\t]+$/, "", s); return s }', 1)
io.open(p, "w", encoding="utf-8").write(s)
