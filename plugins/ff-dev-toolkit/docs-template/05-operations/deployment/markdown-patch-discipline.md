# Markdown 文字列パッチ規律

Issue 本文・PR 本文・Playbook・観測台帳のような **Markdown 本文へ script で文字列パッチを当てる**ときの規律。escape を値として保存する本文・生成 script・TS/shell fixture の作成と再編集にも、下の「リテラル書き込みの既定経路」を適用する。パッチが実行されない形と、保存値だけが変わる形を分けて確認する。行末や複数行を含む一致は、対象ファイルの改行（LF / CRLF）が想定と違うと当たらないので、「改行をまたぐ一致」の節に従う。

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

次の 2 つの形は、危ない書き方を実行前に止めるガードの対象外で、保存値が変わっても書き込みは成功する（どちらもエージェントのホスト経由で書いたときの実測。bash 単体の挙動ではなく、どの層で変わったかは未特定）。上の照合で検出する。

- **ファイルへリダイレクトする heredoc**: `cat > patch.py <<'PY'` のように本文をファイルへ書いてから別の行で実行する形。インタプリタへ直接渡す heredoc と同じく、保存された本文ではバックスラッシュ 2 個が 1 個へ縮んでいた。TS の文字列へ「バックスラッシュ + n」を書き込むつもりの script が、実改行を書き込んだ。
- **ファイル編集機能の入力**: Edit などの入力に書いた JSON の Unicode escape（バックスラッシュ + u + 16 進 4 桁の 6 文字）が、保存時に 1 文字へ復号された。ファイル編集機能を使っても、入力から保存までの層で値は変わりうる。

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

## 一時ファイルの置き場所

本文・値用ファイル・script を一時ファイルに置き、Bash から起動するコマンドと、python / node のコードやホストのファイル編集機能（Write / Edit / Read）の両方から同じファイルを扱うときは、**全員へ同じ値のパスを渡す**。`/tmp` を直書きしない。

Windows の Git Bash では `/tmp` は MSYS の仮想パスである。Bash から起動したネイティブのコマンド（`gh` など）の引数としては `C:/Users/<user>/AppData/Local/Temp/…` へ読み替えられるが、python / node のコードに書いたパスと、ホストのファイル編集機能へ渡したパスは読み替えられず、ドライブ直下の `C:\tmp\…` を指す。`gh issue view … > /tmp/x` は成功するので、書き換えの段で初めて `FileNotFoundError` / `ENOENT` で落ちる（導入先の実測: Issue 本文の書き換えで 1 往復のやり直しが 3 回）。ホストのファイル編集機能で `/tmp/x` へ書いて `gh … --body-file /tmp/x` で送る順では、`gh` は Temp 側の別のファイルを読む。

作業を始めるときに一度だけ次を実行し、出力された `W=` の実値（変換後）を記録する。その同じ値を `gh`・同梱 script・python / node（`sys.argv` で渡す）・ホストのファイル編集機能のすべてに渡す:

```bash
W="$(mktemp -d "${TMPDIR:-/tmp}/<スキル名>-<Issue 番号>.XXXXXX")" || exit 2
[ -d "$W" ] && [ ! -L "$W" ] || exit 2
if command -v cygpath >/dev/null 2>&1; then W="$(cygpath -m "$W")" || exit 2; fi; echo "W=$W"
```

- `cygpath` が失敗したら止める（`W` が空のまま進むと、ルート直下の別の場所を読み書きする）。ホストのファイル編集機能へ渡す値は、`${TMPDIR:-/tmp}/…` から手で組み立てず、出力された `W=` の値をそのまま使う
- `cygpath -m` は区切りが `/` の `C:/…` を返す。この形は Bash・`gh`・python・node・ホストのファイル編集機能のどれからも同じ場所に見える（`TMPDIR` が `/tmp`・`C:\…`・未設定のどれでも同じ値になる）。`cygpath` が在るのは Windows の Git Bash（MSYS / Cygwin）だけで、macOS / Linux では何もしない
- `mktemp -d` が排他的に作った私有ディレクトリを使う。固定名への `mkdir -p` は使わない。呼び出しをまたぐとシェル変数は残らないため、次の呼び出しには記録済みの W の実値を明示して再設定する。名前を Issue 番号から再構築したり、後続の読み書きの前に mktemp を再実行したりしない
- 後続の呼び出しは `W="<記録済みの W の実値>"` を設定してから `[ -d "$W" ] && [ ! -L "$W" ] || exit 2` を通す。見つからない場合は外部送信せず、私有領域の確保と本文取得・編集を最初からやり直す。再利用するのはパスの実値であり、前のシェル変数の生存ではない
- POSIX では作成時の owner-only 権限を維持し、Windows ではユーザー専用 Temp の ACL を維持する。作業完了後は記録した自分の作業ディレクトリだけを削除する
- Bash が作ったファイル（`mktemp` の戻り値・展開先）をホストのファイル編集機能で読む逆向きも同じで、`cygpath -m` で変換した値を渡す。`/tmp/…` や `/c/…` の形をネイティブのツールへ直接渡さない

## 3. パッチと後続コマンドを同じ実行にまとめない

パッチ script の実行と、その生成物に依存する後続コマンド（`gh issue edit --body-file` / `git add` / `git commit` など）を 1 コマンドへ連結しない。連結すると、パッチが落ちても後続が走る。

実測では、パッチと `gh issue edit --title ... --body-file` を連結した結果、**タイトルだけ更新され本文は未編集のまま「成功」に見えた**（`--body-file` へ渡ったのは編集前のファイルで、差分が無いため気づきにくい）。同型で、落ちた script と独立に `git add` / `git commit` が走り、「記録した」と主張するコミットメッセージの下に記録の無いコミットができた。

**パッチ script が失敗したら後続へ到達させない。** 「失敗は `SyntaxError` で明示されるので silent ではない」は、後続を連結した時点で成り立たなくなる。

## 4. アンカーの実在を script 内でアサートする

置換の前に、アンカー文字列が本文に実在することを `assert` で確かめる。アンカーが一致しなければ**ファイルを未変更のまま停止**し、後続にも到達しない（実測: アサーション入りの script file にしたところ、アンカー不一致で停止して部分適用も起きなかった）。

次は値用ファイルのパスだけを引数にする例。バイトで読み書きし、元ファイルの改行や対象外の区間を変えない。空・0件一致・複数一致のアンカーは書き込み前に止める。書き込んだあとは最終ファイルを読み戻し、組み立てた本文と同じバイト列であることを確かめて、違えば非 0 で止める。

<!-- literal-patch-example:start -->

```python
# -*- coding: utf-8 -*-
from pathlib import Path
import sys

path, anchor_file, replacement_file = map(Path, sys.argv[1:])
anchor, replacement = anchor_file.read_bytes(), replacement_file.read_bytes()
text = path.read_bytes()
assert anchor and text.count(anchor) == 1, "アンカーが空か、一意に見つかりません"
assert text.find(anchor) == text.rfind(anchor), "アンカーが重なって複数回一致します"
patched = text.replace(anchor, replacement, 1)
path.write_bytes(patched)
assert path.read_bytes() == patched, "書き込んだバイト列を読み戻せません"
```

<!-- literal-patch-example:end -->

`count` は重ならない一致だけを数える。前後に改行を持つアンカーが同じ行の連続に当たると、2 か所に一致しても 1 件と数えるので、先頭の一致と末尾の一致が同じ位置であることも確かめる。

アンカーや置換値が実改行を含む文章・コードで、対象ファイルの改行が分からないときは、この例ではなく「改行をまたぐ一致」の例を使う。

## 4a. 複数ファイルは全部組み立てて検証してから書く

複数ファイルを 1 本の手書きスクリプトで更新するときは、§3 と §4 を置き換えない。§3（パッチと後続コマンドを分け、失敗したら後続へ到達させない）と §4（アンカーが空・0 件・複数ならそのファイルを未変更のまま止める）は、ファイルが 1 つのときの規定として残す。複数ファイルでは、それらを全対象へ広げる。

1. 全対象を読み込む。書き込み用に開くのは、この読み込みより後である。`open(path, "w")` を読み込みより先に評価しない。
2. 全対象の新しい本文をメモリ上で組み立てる。
3. アンカーの実在と一意性、ブロック境界、件数の assert を、最初の書き込みより前にすべて通す。後段の対象で検証が失敗したら、前段の対象も含めて書き込みを始めない。
4. 検証がすべて通ったあとで、まとめて書く。

書き込みを始めたあとの I/O 失敗と、後段の frontmatter 同期までを 1 つのトランザクションとしては保証しない。失敗したら stage、commit、push へ進まず、実差分と元処理の終了コードを記録する。適用後の確認は §5 の述語のままである。

## 改行をまたぐ一致

行末や複数行を含むアンカーは、対象ファイルの改行（LF / CRLF）が想定と違うと一致しない。`String.replace` や正規表現の置換は 0 件一致でも成功するので、件数を確かめない script は何も変えずに終わる。行末の一致は処理系で結果が割れる。Python の `re.M` の `$` は LF の直前にしか一致せず、CRLF の行では行末の手前に CR が残って外れる。JavaScript は `m` フラグ付きの `$` なら CR の直前にも一致するが、`m` なしの `$`、`endsWith`、LF を明示したパターンは CR で外れる（どちらも実測）。狙った行を外した置換が、別の行に当たって書き換えることもある（導入先の実測: 表の行を狙った置換が frontmatter の区切り行を書き換えた）。

### まず作業ツリーを LF に固定する

CRLF の作業ツリーの多くは、`core.autocrlf=true`（Git for Windows のインストーラの既定の選択）で checkout した結果である。リポジトリ側で改行を決めれば、checkout する環境によらず同じバイト列になり、下の手順が要る場面そのものが減る。

1. リポジトリ直下の `.gitattributes` に `* text=auto eol=lf` を置く。CRLF が要るファイル（`*.bat` など）は `eol=crlf` を、バイト列を固定したい fixture は `-text` を個別に指定する。
2. `git add --renormalize .` を実行し、`.gitattributes` と一緒にコミットする。index 側が CRLF（`i/crlf`）のファイルは、このコミットで LF になる。
3. `git status --porcelain` が空であることを確かめ、`git ls-files --eol` で、属性が `eol=lf` なのに作業ツリーが `w/crlf` のファイルを数える。手順 2 のコミットだけでは、checkout 済みのファイルは書き直されない（実測: コミットのあとも `w/crlf` のまま残った）。
4. 該当ファイルを削除して `git checkout -- .` で取り出し直す（実測: `w/lf` になり、`eol=crlf` を指定したファイルは CRLF のまま残った）。未コミットの変更があるファイルは消さない。

git を通らない書き込みでも CRLF はできる。Windows の Python は `open(path, "w")` の既定で LF を CRLF に変えて書き、CRLF を含む本文は CR が 2 個になる（実測）。書き込みは `write_bytes` か `newline=""` を使う。

LF に固定できない作業ツリー（導入先の方針、他ツールの生成物）では、次の 2 つの手順で当てる。

### 改行はバイトで判定する

テキスト系のツールは CR の見せ方が環境で割れる。Git Bash の実測では、`sed -n l` と awk は CR を落として見せ、`grep -c` は環境によって 0 件と実数の両方を返した。Python の `open(path)` は読み込みで CRLF を LF に変える。判定は次のどちらかで行う。

- 追跡ファイル: `git ls-files --eol <path>` の `w/` 欄を読む。
- それ以外: バイトで読み、CR LF の並び（13, 10）を調べる。有無だけなら Node の `fs.readFileSync(path)` が返す Buffer の `includes(Buffer.from([13, 10]))` で足りる。混在まで判定するときは、下の例のように CR LF・単独の LF・単独の CR を数える。

### 対象の改行に合わせて当てる

1. **ファイル本文は正規化しない。アンカーと置換値の側を対象の改行に合わせる。** 本文を LF にそろえてから書き戻す形は、改行が混在するファイルで対象外の行を書き換える。
2. CRLF と LF（または単独の CR）が混在する対象は、書き込み前に止める。混在のまま当てるときは、§4 の例でアンカーと置換値をバイト列のとおりに用意する。
3. 一致件数を確かめ、0 件・複数件なら未変更のまま止める（§4）。
4. バイトで書き、読み戻して、組み立てた本文と同じバイト列であることを確かめる。
5. 行単位で照合するとき（行末の一致、`endsWith`、正規表現の `$`）は、CR LF と LF の両方で分割した行に当てる。分割せずに行末を見る正規表現は、処理系によらず行末の手前の CR を許す形にする。ファイル末尾への追記は、末尾の区切りを CR LF と LF の両方で判定し、追記する本文を同じ改行にそろえる。

次は、アンカーと置換値の改行を対象に合わせる例。引数は §4 の例と同じで、値用ファイルの改行は LF・CRLF のどちらで保存されていてもよい。変えるのは実改行のバイトだけで、バックスラッシュを含む値（escape を文字として保存する literal）はそのまま通る。

<!-- eol-patch-example:start -->

```python
# -*- coding: utf-8 -*-
from pathlib import Path
import sys

path, anchor_file, replacement_file = map(Path, sys.argv[1:])
CR, LF, CRLF = bytes([13]), bytes([10]), bytes([13, 10])
text = path.read_bytes()
crlf = text.count(CRLF)
kinds = [crlf, text.count(LF) - crlf, text.count(CR) - crlf]
assert sum(1 for n in kinds if n) <= 1, "対象の改行が混在しています"
eol = CRLF if kinds[0] else CR if kinds[2] else LF
anchor, replacement = (
    f.read_bytes().replace(CRLF, LF).replace(CR, LF).replace(LF, eol)
    for f in (anchor_file, replacement_file)
)
assert anchor and text.count(anchor) == 1, "アンカーが空か、一意に見つかりません"
assert text.find(anchor) == text.rfind(anchor), "アンカーが重なって複数回一致します"
patched = text.replace(anchor, replacement, 1)
path.write_bytes(patched)
assert path.read_bytes() == patched, "書き込んだバイト列を読み戻せません"
```

<!-- eol-patch-example:end -->

この例は、値の中の CR LF・LF・単独の CR をすべて改行として扱い、対象の改行に書き換える。CR を値として残したいときは §4 の例を使う。改行を 1 つも含まない対象は LF のファイルとして扱う。

適用後は §5 に加えて、対象外の区間が不変であることと、改行の種類が適用前と同じ 1 種類のままであることを確かめる。

## 5. 適用後は目視ではなく述語で突き合わせる

パッチ後の確認で diff を眺めない。最終ファイルの対象リテラルが独立の期待バイト・出現数と一致し、前後の対象外区間が不変であることを述語で判定する。`git status --short` を使う場面では、意図しないファイルの混入確認に加えて、**主張（「〜へ追記した」「〜を更新した」と書く対象ファイル）が staged に現れているか**を突き合わせてから次へ進む。

## 適用範囲

Markdown 本文へ文字列パッチを当てうるスキルと、literal を含む生成物を作る実装入口は本文書を参照する。参照の実在は `plugins/ff-dev-toolkit/tests/markdown-patch-discipline-refs/verify.sh` が機械検査し、1 本でも参照が消えると赤になる。
