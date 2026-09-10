# 近傍判定の限定を外し、ff-effort を含む行をすべて疑う修正前の実装へ戻す。
#
# この退行は「警告が増える」だけなので緑のままだと気づけない — 増えた分は
# ブロックの外でその語を説明しているだけの正しい Issue で、規定アクション
# 「本文を直す」をそのまま実行すると原文を検出器に合わせて劣化させる。
import io

p = "plugins/ff-dev-toolkit/scripts/effort-report.sh"
s = io.open(p, encoding="utf-8").read()

new_impl = "  if (inblock[num] != 1 && is_marker_shaped(line)) suspect[num] = 1"
old_impl = "  if (line ~ /ff-effort/ && inblock[num] != 1) suspect[num] = 1"

assert new_impl in s, "anchor not found"
s = s.replace(new_impl, old_impl, 1)
io.open(p, "w", encoding="utf-8").write(s)
