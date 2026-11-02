# 非検出 fixture（lib の source に当たらない形）

散文の注意: `. "${FF_DEV_TOOLKIT_ROOT}/scripts/lib/playbook-changelog-functions.sh"` を fence に書かない。

```text
. "${FF_DEV_TOOLKIT_ROOT}/scripts/lib/playbook-changelog-functions.sh"
```

```
source scripts/lib/abs-path.sh
```

```bash
# 行頭コメントは対象外: . "${FF_DEV_TOOLKIT_ROOT}/scripts/lib/abs-path.sh"
bash "${FF_DEV_TOOLKIT_ROOT}/scripts/finish.sh" knowledge-commit add --source ace
echo ". scripts/lib/abs-path.sh"
printf '%s\n' 'source scripts/lib/abs-path.sh'
. "$HOME/.profile"
. ./env.sh
source "$ROOT/mylib/x.sh"
./scripts/lib/run.sh
bash scripts/lib/run.sh
cat "$ROOT/scripts/lib/abs-path.sh"
. "$ROOT/scripts/lib/readme.md"
echo 'example; source scripts/lib/abs-path.sh'
echo "a && . lib/x.sh"
gif . lib/x.sh
sourcex lib/x.sh
```
