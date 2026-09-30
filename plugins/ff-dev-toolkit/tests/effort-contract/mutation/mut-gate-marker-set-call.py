import io
p = "plugins/ff-dev-toolkit/tests/run-all.sh"
s = io.open(p, encoding="utf-8").read()
# 走行中マーカーの書き手の呼び出しを消す（関数定義は残るので、抽出ブロック単独の検査では
# 緑のまま「マーカーを置かない」状態へ戻れる）
a = '# <<< ff-gate-marker-block\nff_gate_marker_set\n'
assert s.count(a) == 1, "anchor not found"
s = s.replace(a, '# <<< ff-gate-marker-block\n', 1)
io.open(p, "w", encoding="utf-8").write(s)
