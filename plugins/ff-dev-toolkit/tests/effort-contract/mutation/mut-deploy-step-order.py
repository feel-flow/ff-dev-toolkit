# close-issue の照合手順から取得した本文の確定（mv）を外す（5b の 1) が作る .orig.md を待つ形へ戻す）。検査 5b の統合ケースが赤になる
import io
p = "plugins/ff-dev-toolkit/skills/close-issue/references/effort.md"
s = io.open(p, encoding="utf-8").read()
a = '  mv "${BODY_ORIG}.part" "$BODY_ORIG"\n'
assert a in s, "anchor not found"
s = s.replace(a, '', 1)
io.open(p, "w", encoding="utf-8").write(s)
