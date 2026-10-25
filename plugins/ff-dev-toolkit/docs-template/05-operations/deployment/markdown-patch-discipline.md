# Markdown 文字列パッチ規律

Issue 本文・PR 本文・Playbook・観測台帳のような **Markdown 本文へ script で文字列パッチを当てる**ときの規律。escape を値として保存する本文・生成 script・TS/shell fixture の作成と再編集にも、下の「リテラル書き込みの既定経路」を適用する。パッチが実行されない形と、保存値だけが変わる形を分けて確認する。

> **Parent**: [DEPLOYMENT.md](../DEPLOYMENT.md) | **Related**: [git-workflow.md](./git-workflow.md)

**本文書が規律の正本である。** 参照するスキルはここを指し、規律の本文を自分の側へ複製しない。複製すると、同じ規律が別文面で 2 本以上でき、片方だけ直っても機械が気づかない。

## 1. heredoc ではなく coding ヘッダー付きの script file にする

`python3` を既定にするが、`python3 - <<'PY'` のヒアドキュメントでは実行しない。scratchpad 等へ **script file として書き出し**、1 行目に `# -*- coding: utf-8 -*-` を置いて `python3 <file>` で実行する。ファイル I/O は `open(path, encoding="utf-8")` を明示する。

ヒアドキュメント形は環境により `SyntaxError: Non-UTF-8 code starting with '\xe5' ... but no encoding declared` で **1 行も実行されずに**落ちる。`PYTHONUTF8=1` だけでは不足だった（実測: `PYTHONUTF8=1` で通ったセッションの翌日に同じ変数で落ち、coding ヘッダー付き script file で通った。別セッションでは短いヒアドキュメントは通るが、長文になると途中の行で落ちた）。

Node のテンプレートリテラルはバックティックを構文として解釈するため、日本語 + バックティック混在の本文では `SyntaxError` になる（実測: 同型のパッチで node は 2 回失敗し、python3 は全成功）。

## リテラル書き込みの既定経路

バックスラッシュ等の escape を値として保存する場合は、Markdown 以外のコード・テスト fixture にも本節を適用する。**生成 script 自身の作成・再編集も同じ経路**にする。

1. Write / Edit / apply_patch など、利用中ホストのファイル編集機能で本文や script をファイル化する。Bash の heredoc / sed / node -e / python -c に本文を埋め込んで作成・再編集する経路を既定にしない。script file を実行するだけに変えても、その file を同じ heredoc で作っていたら対策にならない。ファイル編集機能が無い場合は、既存の検証済みファイルを使うか、文字コードから組み立てた値を保存して同じ照合を行う。
2. **期待値を生成物自身から作らない**。元の要求から、対象リテラルのバイト列・長さ・許す制御文字を独立に定める。保存した物の hash を計算するだけでは正しさの証明にならない。
3. **実行前に保存バイトを独立の期待値と照合**し、不一致・読取不能・期待値未確定なら、その生成物を実行・適用・公開へ渡さない。期待した backslash と n が実 LF/CR へ変わった形、6文字の Unicode escape が1文字になった形を区別する。Write / Edit の使用だけで正しい保存値になったとは判断しない。
4. 修正後も同じ照合をやり直す。`bash -n`、型検査、通常出力の一致、`isascii()` だけで保存ソースの一致を代用しない。printf の書式内に実改行が入った形は、構文も出力も正常なまま通る。

変化した層は、**意図した値 → 復号後の tool 引数 → 保存 script → 最終ファイル**を分けて調べる。JSON や言語の通常の escape 解釈と、ホスト固有の変換を混同せず、今回確認していない機序を原因として断定しない。

### 保存値の照合例

次は TS literal、printf のソース、6文字の Unicode escape の小片を照合する例。これ自体もファイル編集機能で script file として保存する。実ファイルでは元の要求から対象リテラルの区間・出現数と前後の不変区間を定め、その範囲を照合する（ファイル全体の期待値を作り直す必要はない）。期待する backslash と改行は数値から作り、同じ本文をもう一度ツールへ渡して期待値にする方法を避ける。

<!-- literal-byte-check:start -->

```python
# -*- coding: utf-8 -*-
from pathlib import Path
import sys

slash, lf = bytes([92]), bytes([10])
expected = {
    "ts": b'const text = "# index' + slash + b'n";' + lf,
    "printf": b"#!/usr/bin/env bash" + lf + b"printf '%s" + slash + b"n' value" + lf,
    "unicode": slash + b"u2014" + lf,
}
kind, path = sys.argv[1:]
if Path(path).read_bytes() != expected[kind]:
    raise SystemExit("保存バイトが期待値と異なるため実行しません")
```

<!-- literal-byte-check:end -->

保存した照合 script を `python3 <照合scriptの絶対パス> ts <対象の絶対パス>` の形で呼び、成功を確認してから、別の呼出しで対象を実行する。照合失敗と対象の実行を連結しない。

## 2. 値はシェル変数ではなく `sys.argv` で渡す

対象ファイルのパスなど、escape を含まない短い値は `sys.argv` で受け取る。`os.environ["SP"]` のようにシェル変数を読む形にしない — export していないシェル変数は子プロセスに存在せず `KeyError` で落ちる。

**escape を含むアンカー・置換値はコマンド引数へ直接埋め込まない**。値用のファイルをファイル編集機能で保存し、独立の期待バイトで照合してから、そのパスだけを `sys.argv` で渡す。script の照合だけでは引数の値の変化を検出できない。値用ファイルを読み込む例は次の §4。パッチ後の最終ファイルも、§5 の照合を通してから実行・適用・公開へ進める。

## 3. パッチと後続コマンドを同じ実行にまとめない

パッチ script の実行と、その生成物に依存する後続コマンド（`gh issue edit --body-file` / `git add` / `git commit` など）を 1 コマンドへ連結しない。連結すると、パッチが落ちても後続が走る。

実測では、パッチと `gh issue edit --title ... --body-file` を連結した結果、**タイトルだけ更新され本文は未編集のまま「成功」に見えた**（`--body-file` へ渡ったのは編集前のファイルで、差分が無いため気づきにくい）。同型で、落ちた script と独立に `git add` / `git commit` が走り、「記録した」と主張するコミットメッセージの下に記録の無いコミットができた。

**パッチ script が失敗したら後続へ到達させない。** 「失敗は `SyntaxError` で明示されるので silent ではない」は、後続を連結した時点で成り立たなくなる。

## 4. アンカーの実在を script 内でアサートする

置換の前に、アンカー文字列が本文に実在することを `assert` で確かめる。アンカーが一致しなければ**ファイルを未変更のまま停止**し、後続にも到達しない（実測: アサーション入りの script file にしたところ、アンカー不一致で停止して部分適用も起きなかった）。

次は値用ファイルのパスだけを引数にする例。バイトで読み書きし、元ファイルの改行や対象外の区間を変えない。空・0件一致・複数一致のアンカーは書き込み前に止める。

<!-- literal-patch-example:start -->

```python
# -*- coding: utf-8 -*-
from pathlib import Path
import sys

path, anchor_file, replacement_file = map(Path, sys.argv[1:])
anchor, replacement = anchor_file.read_bytes(), replacement_file.read_bytes()
text = path.read_bytes()
assert anchor and text.count(anchor) == 1, "アンカーが空か、一意に見つかりません"
path.write_bytes(text.replace(anchor, replacement, 1))
```

<!-- literal-patch-example:end -->

## 5. 適用後は目視ではなく述語で突き合わせる

パッチ後の確認で diff を眺めない。最終ファイルの対象リテラルが独立の期待バイト・出現数と一致し、前後の対象外区間が不変であることを述語で判定する。`git status --short` を使う場面では、意図しないファイルの混入確認に加えて、**主張（「〜へ追記した」「〜を更新した」と書く対象ファイル）が staged に現れているか**を突き合わせてから次へ進む。

## 適用範囲

Markdown 本文へ文字列パッチを当てうるスキルと、literal を含む生成物を作る実装入口は本文書を参照する。参照の実在は `plugins/ff-dev-toolkit/tests/markdown-patch-discipline-refs/verify.sh` が機械検査し、1 本でも参照が消えると赤になる。
