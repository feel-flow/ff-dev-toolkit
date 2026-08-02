# 検出 fixture（違反あり）— 行番号は verify.sh の EXPECTED_VIOLATION_LINES と連動

散文中の言及は検出対象外: `| grep -q` はコードブロックの外にある。

```bash
printf '%s\n' "$labels" | grep -qxF -- "$candidate"
git branch -r | grep --fixed-strings -q "feature"
env | grep --quiet FOO
printf '%s\n' "$out" |
  grep -q pattern
some_cmd | command grep -xq foo
printf '%s\n' "$x" \
  | grep -q foo
some_cmd |& grep -q foo
some_cmd | egrep -q foo
some_cmd | LC_ALL=C grep -q foo
some_cmd | grep -q"pattern"
echo done  # 行末コメント内の言及も保守側で検出する: cmd | grep -q foo
```

```sh
cat file | grep -sq token
```

~~~zsh
print -l "$items" | grep --silent -- "$needle"
~~~

閉じ忘れフェンスは UNCLOSED_FENCE として構造違反にする（このブロックは意図的に閉じない）:

```text
このフェンスには閉じが無いまま EOF に達する
