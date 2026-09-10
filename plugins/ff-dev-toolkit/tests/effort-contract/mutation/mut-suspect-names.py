# 警告を「件数だけ」へ戻す（text の列挙と kv の suspect_marker_issues を落とす）。
#
# 件数だけの警告は読み手が直す対象を特定できず、実測では同じ 1 行を 3 回受け取り、
# 3 回目に全 Issue 本文を総当たりしてようやく該当を特定した。件数は正しいままなので
# 数値を見る検査では捕まらない — 名指しそのものを固定した検査でだけ落ちる。
import io

p = "plugins/ff-dev-toolkit/scripts/effort-report.sh"
s = io.open(p, encoding="utf-8").read()

kv_line = (
    '    # 0 件でもキーは出す。存在しないキーと空値を消費側に区別させる\n'
    '    printf "suspect_marker_issues=%s\\n", suspect_kv\n'
)
assert kv_line in s, "kv anchor not found"
s = s.replace(kv_line, "", 1)

txt_new = (
    '    printf "  ⚠️ ff-effort に似た行があるのにマーカーとして認識されなかった Issue が %d 件あります: %s'
)
assert txt_new in s, "text anchor not found"
txt_old = txt_new.replace(": %s", "")
s = s.replace(txt_new, txt_old, 1)
s = s.replace(
    "（綴り・字下げ・行末空白を確認すること）\\n\", suspect_n, suspect_txt",
    "（綴り・字下げ・行末空白を確認すること）\\n\", suspect_n",
    1,
)
io.open(p, "w", encoding="utf-8").write(s)
