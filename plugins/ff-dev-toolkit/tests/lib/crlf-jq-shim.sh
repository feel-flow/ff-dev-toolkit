#!/usr/bin/env bash
#
# Windows の native jq.exe の出力を再現する jq シムを作る共有ヘルパ（Issue `#2017`）。
#
# 何を再現するか: jq.exe は stdout をテキストモードで書くので、出力の改行がすべて `\r\n`
# になる。hook が `$(jq -r …)` で取り込むと、Git Bash（MSYS）の `$(…)` は末尾の `\r\n` を
# 丸ごと落とすが、値の途中の改行には `\r` が残る。複数フィールドを改行で連結して取り出す
# hook では、先頭フィールドが `Bash\r` になって判定が外れ、ガードが黙って素通りしていた。
#
# なぜ「最後の改行以外」だけを `\r\n` にするか: Linux / macOS の bash の `$(…)` は末尾の
# `\n` しか落とさない。すべての改行を `\r\n` にすると、末尾に `\r` が残る分だけ実機より
# 厳しくなり、Windows では起きない失敗まで再現してしまう。最後の改行を素の `\n` のまま
# 残すと、`$(jq -r …)` で取り込む形では、どのホストでも Windows の Git Bash と同じ値になる。
#
# 既知の限界: `jq -j` の出力の後ろへ番兵を足して取り込む形（`$(jq -j …; printf x)`）では、
# 実機は jq の出力の最後の改行も `\r\n` になるが、このシムは最後の改行を素のまま残すので、
# その 1 箇所だけ実機より弱い（途中の改行の `\r` は再現する）。
# `while read` で 1 行ずつ読む形では、最終行だけ `\r` が付かない分、実機より
# 弱い（最終行以外の `\r` は再現する）。Windows のホストでこのシムを重ねると、jq.exe が
# 既に出した `\r\n` が `\r\r\n` になる。hook は `\r` をすべて落とすので判定は変わらない。
# 逆に、jq の出力を正規化せずに awk / grep / sed へ流す箇所では、Linux / macOS の方が実機より
# 厳しくなる。Git Bash の awk / grep / sed は読み込み時に `\r` を落とすが、GNU / BSD 版は
# 落とさないため。導入時（2026-10-04）に、hook / script 側にその形が無いことを読んで確かめ、
# WSL の Ubuntu 24.04（GNU 版の awk / grep / sed・jq 1.7）で修正後の全件緑と、修正前の hook で
# このシムの検査だけが赤になることを実測した。jq の出力をテキスト処理へ直接流す箇所を
# 足すときは、取り込んだ値と同じく `\r` を落としてから渡す。
#
# 使い方:
#   . "$SCRIPT_DIR/../lib/crlf-jq-shim.sh"
#   ff_crlf_jq_shim "$TEST_TMP/crlf-jq-bin" "$(command -v jq)" || exit 1
#   PATH="$TEST_TMP/crlf-jq-bin:$PATH"   # 以降の jq がシムになる（終わったら戻す）
#
# 変換には perl を使う（入力の終端を `eof` で判定できるため。awk では最後の行に改行が
# あったかを区別できない）。perl が無いときは 2 を返し、呼び出し側が skip を名指しする。

# ff_crlf_jq_shim <dir> <real-jq>
#   <dir>/jq を作る。終了コードは本物の jq のものをそのまま返す（pipefail）。
#   0 = 作成した / 1 = 作成できない / 2 = perl が無い
ff_crlf_jq_shim() {
  local dir="$1" real="$2"
  [ -n "$dir" ] && [ -n "$real" ] && [ -x "$real" ] || return 1
  command -v perl >/dev/null 2>&1 || return 2
  mkdir -p "$dir" || return 1
  {
    printf '%s\n' '#!/usr/bin/env bash'
    printf '%s\n' 'set -o pipefail'
    printf '%q "$@" | perl -pe %q\n' "$real" 's/\n\z/\r\n/ unless eof'
  } > "$dir/jq" || return 1
  chmod +x "$dir/jq" || return 1
}
