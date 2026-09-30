# --deploy-check の排他を --issue-metrics / --unreached-leaves だけへ戻す（--input 等を黙って無視する）。検査 5b の --input 併用ケースが赤になる
import io
p = "plugins/ff-dev-toolkit/scripts/effort-report.sh"
s = io.open(p, encoding="utf-8").read()
a = '  if [ -n "$OTHER_OPTS" ]; then\n'
assert a in s, "anchor not found"
s = s.replace(a, '  if [ -n "$ISSUE_METRICS" ] || [ "$UNREACHED_LEAVES" -eq 1 ]; then\n', 1)
io.open(p, "w", encoding="utf-8").write(s)
