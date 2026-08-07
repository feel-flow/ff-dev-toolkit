# MBCS 検出 fixture（違反あり）— 行番号は verify.sh の EXPECTED_MBCS_VIOLATION_LINES と連動

散文中の `$name（` はコードブロック外なので検出対象外。

```bash
echo "ng1: $name（bad）"
echo "ok: ${name}（safe）"
echo "ng2: $repo）end"
printf '%s' "ng-cont: $var\
（continued）"
```

```text
echo "$name（text block — not scanned）"
```

```sh
echo "ng3: $x—dash"
```
