# MBCS 非検出 fixture

散文: `$name（` は bash 3.2 で危険、と書くだけなら検出しない（コードブロック外）。

```bash
echo "safe: ${name}（braced）"
echo "ascii only: $name-ok"
# コメント内も case 11 と同様 ${VAR} 形式に統一する運用
echo "braced close: ${repo}）"
```

```python
print("$name（not bash）")
```
