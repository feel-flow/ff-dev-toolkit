# 非 ASCII 空白でインデントしたフェンス

 ```text
NBSP でインデントした行はフェンスを開かない（awk / TS とも本文として残る）
 ```

半角空白 3 個までのインデントは CommonMark 上も opener
   ```text
   この中身は消える
   ```

```text
垂直タブでインデントした行もフェンスを開かない
```

ASCII opener に非 ASCII 空白の closer は閉じない
```text
NBSP インデントの closer は closer と認めず本文として残す
 ```
本物の closer まで消える
```

末尾は残る
