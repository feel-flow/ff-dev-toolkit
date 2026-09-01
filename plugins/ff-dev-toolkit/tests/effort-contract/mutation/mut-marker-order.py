# marker_sanity を修正前の「件数だけを数える」実装へ丸ごと戻す。
#
# 逆順マーカーの穴は【三重】に塞がれている:
#   (1) marker_sanity の順序判定  (2) marker_sanity の未閉鎖判定 (open == 1)
#   (3) mask() の END ガード (inblock が残っていたら非 0)
# どれか 1 つを外しても他の 2 つが捕まえるため、単点変異では原理的に穴が開かない。
# これはゲートの弱さではなく防御が多層であることの証拠だが、そのぶん「実際に
# 起こりうる退行」= この修正を丸ごと差し戻すこと、を変異として与える必要がある。
import io

p = "plugins/ff-dev-toolkit/scripts/check-issue-body-diff.sh"
s = io.open(p, encoding="utf-8").read()

new_impl = '''    {
      line = $(0); sub(/\\r$/, "", line)
      if (line == b) {
        if (nb > 0 || ne > 0) exit 1   # 2 組目、または end 先行
        nb++; open = 1
      } else if (line == e) {
        if (open != 1) exit 1          # begin より前、または 2 組目
        ne++; open = 0
      }
    }
    END { if (open == 1) exit 1        # 未閉鎖（begin のみ）
          if (nb != ne) exit 1
          exit 0 }'''

old_impl = '''    {
      line = $(0); sub(/\\r$/, "", line)
      if (line == b) nb++
      if (line == e) ne++
    }
    END { if (nb > 1 || ne > 1) exit 1
          if (nb != ne) exit 1
          exit 0 }'''

assert new_impl in s, "anchor not found"
s = s.replace(new_impl, old_impl, 1)

# (3) mask() の END ガードも外す（三層すべてを修正前へ戻す）
mask_guard = """    END { if (inblock) exit 1 }
  ' "$1"
}"""
assert mask_guard in s, "mask guard anchor not found"
s = s.replace(mask_guard, """  ' "$1"
}""", 1)

io.open(p, "w", encoding="utf-8").write(s)
