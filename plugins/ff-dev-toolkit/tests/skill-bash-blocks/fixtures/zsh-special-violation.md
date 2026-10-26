# zsh 特殊パラメータを代入・read・for・宣言の対象にした違反 fixture

```bash
path=docs/a.md
cdpath+=/tmp/x
for fpath in a b; do echo x; done
while IFS= read -r mailpath; do echo x; done
manpath=$(printf x)
read -r module_path
local watch
declare -a psvar
typeset fignore=x
export status=1
readonly argv
echo "read -r path"
echo x # for path in
read -d '' argv
read -ra path
read -apath
read -r -- status
export LC_ALL=C; status=1
read -r line; read -r argv
```

```sh
read status
```

```zsh
path+=extra
```

```shell
status=1
```

```bash
echo x \
  && read -r path
```

```bash
read -p "hello; world" path
export MESSAGE="hello; world" path
```
