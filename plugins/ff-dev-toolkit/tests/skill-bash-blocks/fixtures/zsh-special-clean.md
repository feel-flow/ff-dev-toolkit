# 非検出 fixture（zsh 特殊パラメータの参照・別名・行頭コメント）

散文の注意: read -r path は zsh で PATH を壊す。代入しない言及は対象外。

```text
path=not-bash
read -r path
```

```
read -r path
for path in a; do echo x; done
```

```bash
# 行頭コメントは対象外: read -r path
git status
echo "$path"
pathname=foo
full-path="a"
ledger_status=ok
mypath=ok
for item in path status; do echo "$item"; done
[[ "$status" == ok ]]
read -r line
local other=1
printf '%s\n' --status
export LC_ALL=C; git status
read -r line; echo status
local x=1; git add path
while IFS= read -r n; do echo status; done
: "${path:=x}"
echo "git; status"
read -p "hello; world" line
EPUB_FILE="<引数で受け取ったパス>"
```

```zsh
print -l "$items"
```

例示用ラッパー内の bash ブロックは実行対象と見なさない:

````markdown
```bash
path=inside-example
read -r path
```
````
