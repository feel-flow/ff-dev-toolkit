# 違反 fixture（bash 系ブロックで同梱 lib を source する）

```bash
. "${FF_DEV_TOOLKIT_ROOT}/scripts/lib/playbook-changelog-functions.sh" || exit 2
source "${FF_DEV_TOOLKIT_ROOT}/scripts/lib/abs-path.sh"
  . scripts/lib/shell-quote.sh
x=1; . "$ROOT/lib/a.sh"
true && source '/opt/plugin/scripts/lib/b.sh'
if true; then . "$ROOT/scripts/lib/c.sh"; fi
( . lib/d.sh )
```

```sh
. "$ROOT/scripts/lib/e.sh"
```

```zsh
source "$ROOT/scripts/lib/f.sh"
```

```shell
{ . "$ROOT/scripts/lib/g.sh"; }
```

```bash
echo "x"; . "$R/scripts/lib/h.sh"
if . "$R/scripts/lib/i.sh"; then :; fi
! . "$R/scripts/lib/j.sh" || exit 2
while source "$R/lib/k.sh"; do :; done
command . "$R/lib/l.sh"
. "${FF_DEV_TOOLKIT_ROOT}"/scripts/lib/m.sh
. "$R/scripts/lib/n.sh">/dev/null 2>&1
```
