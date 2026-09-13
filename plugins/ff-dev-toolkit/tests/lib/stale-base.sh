# shellcheck shell=bash
#
# ff_report_stale_base — base の鮮度が原因の赤を、変更起因の赤と区別できる形で出す。
#
# 並行して default branch が進む環境では、ブランチが古くなった瞬間に「base が HEAD の祖先である
# こと」を要求する検査が落ちる。その赤は変更の是非を何も語らないのに、従来は内容の欠陥と
# 同じ形（しばしば「claim が不足・stale・orphan」のような**内容を断定する文言**）で出ていた。
# 読み手は存在しない不整合を探しに行かされ、逆に本物の赤が「どうせ鮮度だろう」と読まれる。
#
# ここが出すのは**行頭**の FF_STALE_MARKER で、tests/run-all.sh がこれを見て suite を鮮度
# バケットへ分類する（`○ skip` の行頭マーカーと同じ仕組み）。**赤であることは変えない** —
# 古い base で「断片が揃っている」「版が収束している」と判定するのは誤りなので、分類を
# 変えても判定を諦めてはいけない（skip へ倒すのは fail-open）。呼び出し側は本関数の後に
# 従来どおり `bad` を呼ぶ。rc=0 のまま本マーカーだけを出した suite は run-all が fail-loud する。
#
# マーカーの実体はここ 1 箇所だけに置く。照合側（run-all.sh）が同じリテラルを持つことは
# tests/run-all/verify.sh が fail-closed で確かめる — 二重定義を放置すると、片方を変えた
# 瞬間に分類が**無警告で死ぬ**（本ヘルパを改名した変異が 3 suite とも緑のまま通った実測がある）。
FF_STALE_MARKER='✗ 鮮度:'

# 使い方: ff_report_stale_base "<何の判定が成立しないか>" [<判定対象のリポジトリ root>]
#
# root を渡すのは、呼び出し側が祖先検査を掛けたのと**同じリポジトリ**の既定ブランチ名を案内する
# ため。裸の `git symbolic-ref`（cwd 依存）だと、別リポジトリの中から起動した回に無関係な
# ブランチ名を出す。
ff_report_stale_base() {
  local context="${1:-この suite の判定}"
  local root="${2:-}"
  local default_ref=""
  if [ -n "$root" ]; then
    default_ref="$(git -C "$root" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null)" || default_ref=""
  else
    default_ref="$(git symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null)" || default_ref=""
  fi
  echo "${FF_STALE_MARKER} base が先行しているため${context}が成立しません（変更起因の赤ではありません）" >&2
  if [ -n "$default_ref" ]; then
    echo "    取り込んでから回し直してください: git merge ${default_ref}（履歴を畳んでよいなら git rebase ${default_ref}）" >&2
  else
    # 既定ブランチ名を解決できない回に `origin/<default-branch>` のような擬似値を**コマンド行へ
    # 埋めない** — コピペすると `<` `>` がリダイレクトとして解釈され、案内が案内として働かない。
    echo "    既定ブランチ名を解決できませんでした（origin/HEAD 未設定）。取り込み先を確認してから git merge / git rebase してください" >&2
  fi
}
