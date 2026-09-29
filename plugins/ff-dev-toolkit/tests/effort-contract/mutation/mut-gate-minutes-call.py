import io
p = "plugins/ff-dev-toolkit/tests/run-all.sh"
s = io.open(p, encoding="utf-8").read()
# ゲート分の記録呼び出しを消す（綴りは開始時刻・ブランチの代入とコメントに残るので、文字列一致だけの
# 検査では緑のまま「未配線」へ戻れる）
a = '  ff_record_gate_minutes "$status" "$(ff_gate_mode)"\n'
assert s.count(a) == 1, "anchor not found"
s = s.replace(a, "", 1)
io.open(p, "w", encoding="utf-8").write(s)
