import io
p = "plugins/ff-dev-toolkit/scripts/effort-report.sh"
s = io.open(p, encoding="utf-8").read()
# 1 ファイル目の判定を FNR == NR へ戻す（wallclock.tsv 不在でバイトを読み落とす）
a = '      FILENAME == first {\n'
assert s.count(a) == 1, "anchor not found"
s = s.replace(a, '      FNR == NR {\n', 1)
io.open(p, "w", encoding="utf-8").write(s)
