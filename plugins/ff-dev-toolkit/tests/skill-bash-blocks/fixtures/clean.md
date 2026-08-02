# 非検出 fixture（違反なし）— 1 件でも検出されたら誤検出

散文の注意書きは検出しない: パイプ入力の `grep -q*` は使わないこと。
コードブロック外の生テキスト行も対象外: printf '%s\n' "$x" | grep -q foo

```text
出力例テキスト: some_cmd | grep -q foo（bash 以外のブロックは対象外）
```

```
untagged_block | grep -q foo（言語タグ無しブロックは実行対象と見なさない）
```

```bash
# 行頭コメントは対象外: printf | grep -q は禁止、という注意書きを書ける
grep -q pattern file.txt
if grep -Fx "x" file >/dev/null; then :; fi
count="$(printf '%s\n' "$x" | grep -c foo)"
case "$hay" in *"$needle"*) : ;; esac
printf '%s\n' "$x" | grep -F foo >/dev/null
git log --oneline | grep -E 'quick' >/dev/null
test -f /tmp/x || grep -q pattern file.txt
[ -n "$v" ] || grep --quiet p f.txt
```

```zsh
print -l "$items" | grep -F -- "$needle" >/dev/null
```

例示用ラッパー（4 連フェンス）内の bash ブロックは実行対象と見なさない:

````markdown
```bash
wrapped_cmd | grep -q foo
```
````
