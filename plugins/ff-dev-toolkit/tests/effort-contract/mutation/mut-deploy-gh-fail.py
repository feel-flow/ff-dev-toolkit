# close-issue の照合手順で gh の取得失敗時に unavailable を報告しない形へ戻す。検査 5b の gh 失敗ケースが赤になる
import io
p = "plugins/ff-dev-toolkit/skills/close-issue/references/effort.md"
s = io.open(p, encoding="utf-8").read()
a = '  rm -f "${BODY_ORIG}.part"\n  echo "effort_deploy=unavailable"\n'
assert a in s, "anchor not found"
s = s.replace(a, '  rm -f "${BODY_ORIG}.part"\n', 1)
io.open(p, "w", encoding="utf-8").write(s)
