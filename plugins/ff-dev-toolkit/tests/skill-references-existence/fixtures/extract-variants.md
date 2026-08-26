# フェンス変種 fixture（CRLF・4 連バッククォート・タグ違い）

CRLF 行のトークン `references/crlf.md` は抽出される。

````markdown
4 連フェンス内の `references/in-four.md` は抽出されない。
```
内側の 3 連は閉じとみなされない（同種・同長以上が必要）: `../still-in-fence.md`
```
````

~~~zsh
タグ違いフェンス内の `references/in-zsh.md` も抽出されない。
~~~

リンク形式 [w](../w/workflow.md) は CRLF でも抽出される。
