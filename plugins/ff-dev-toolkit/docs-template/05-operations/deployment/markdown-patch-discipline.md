# Markdown 文字列パッチ規律

Issue 本文・PR 本文・Playbook・観測台帳のような **Markdown 本文へ script で文字列パッチを当てる**ときの規律。日本語とインラインコード（バックティック）が混在する本文で、パッチが 1 行も実行されないまま後続だけが走る事故を潰す。

> **Parent**: [DEPLOYMENT.md](../DEPLOYMENT.md) | **Related**: [git-workflow.md](./git-workflow.md)

**本文書が規律の正本である。** 参照するスキルはここを指し、規律の本文を自分の側へ複製しない。複製すると、同じ規律が別文面で 2 本以上でき、片方だけ直っても機械が気づかない。

## 1. heredoc ではなく coding ヘッダー付きの script file にする

`python3` を既定にするが、`python3 - <<'PY'` のヒアドキュメントでは実行しない。scratchpad 等へ **script file として書き出し**、1 行目に `# -*- coding: utf-8 -*-` を置いて `python3 <file>` で実行する。ファイル I/O は `open(path, encoding="utf-8")` を明示する。

ヒアドキュメント形は環境により `SyntaxError: Non-UTF-8 code starting with '\xe5' ... but no encoding declared` で **1 行も実行されずに**落ちる。`PYTHONUTF8=1` だけでは不足だった（実測: `PYTHONUTF8=1` で通ったセッションの翌日に同じ変数で落ち、coding ヘッダー付き script file で通った。別セッションでは短いヒアドキュメントは通るが、長文になると途中の行で落ちた）。

Node のテンプレートリテラルはバックティックを構文として解釈するため、日本語 + バックティック混在の本文では `SyntaxError` になる（実測: 同型のパッチで node は 2 回失敗し、python3 は全成功）。

## 2. 値はシェル変数ではなく `sys.argv` で渡す

パッチ script へ渡す値（対象ファイルのパス・アンカー文字列・置換文字列）は `sys.argv` で受け取る。`os.environ["SP"]` のようにシェル変数を読む形にしない — export していないシェル変数は子プロセスに存在せず `KeyError` で落ちる。script file 化すると値を引数で渡すのが自然になり、この失敗モード自体が消える。

## 3. パッチと後続コマンドを同じ実行にまとめない

パッチ script の実行と、その生成物に依存する後続コマンド（`gh issue edit --body-file` / `git add` / `git commit` など）を 1 コマンドへ連結しない。連結すると、パッチが落ちても後続が走る。

実測では、パッチと `gh issue edit --title ... --body-file` を連結した結果、**タイトルだけ更新され本文は未編集のまま「成功」に見えた**（`--body-file` へ渡ったのは編集前のファイルで、差分が無いため気づきにくい）。同型で、落ちた script と独立に `git add` / `git commit` が走り、「記録した」と主張するコミットメッセージの下に記録の無いコミットができた。

**パッチ script が失敗したら後続へ到達させない。** 「失敗は `SyntaxError` で明示されるので silent ではない」は、後続を連結した時点で成り立たなくなる。

## 4. アンカーの実在を script 内でアサートする

置換の前に、アンカー文字列が本文に実在することを `assert` で確かめる。アンカーが一致しなければ**ファイルを未変更のまま停止**し、後続にも到達しない（実測: アサーション入りの script file にしたところ、アンカー不一致で停止して部分適用も起きなかった）。

```python
# -*- coding: utf-8 -*-
import sys

path, anchor, replacement = sys.argv[1], sys.argv[2], sys.argv[3]
with open(path, encoding="utf-8") as f:
    text = f.read()
assert anchor in text, "アンカーが見つかりません: " + anchor
with open(path, "w", encoding="utf-8") as f:
    f.write(text.replace(anchor, replacement, 1))
```

## 5. 適用後は目視ではなく述語で突き合わせる

パッチ後の確認で diff を眺めない。変更行が意図した集合（書き換えるつもりだった行だけ）に収まっているかを述語で判定する。`git status --short` を使う場面では、意図しないファイルの混入確認に加えて、**主張（「〜へ追記した」「〜を更新した」と書く対象ファイル）が staged に現れているか**を突き合わせてから次へ進む。

## 適用範囲

Markdown 本文へ文字列パッチを当てうるスキルはすべて本文書を参照する。参照の実在は `plugins/ff-dev-toolkit/tests/markdown-patch-discipline-refs/verify.sh` が機械検査し、1 本でも参照が消えると赤になる。
