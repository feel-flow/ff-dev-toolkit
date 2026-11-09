#!/usr/bin/env bash
#
# 公開面の一覧（plugins/ff-dev-toolkit/PUBLIC-SURFACE.md）を読む共有実装。
#
# 同じ文書を 2 つの suite が別々の関心で読むので、節の切り出しと token の抽出を 1 か所に置く。
# 片方だけ直される drift がそのまま検出漏れになるため、抽出規則を複製しない。現在の消費者:
#   skill-count-consistency: 一覧と実体（skills / hooks.json / 配布物に現れる FF_* と宣言系統の非 FF_ 環境変数）の集合一致
#   changelog-fragments:     base との差分で契約側の要素が消えたとき breaking 断片を要求する
#
# 抽出は「節見出しでスコープし、その中の backtick token を集合として取る」形で統一する。
# 見出しを変えると抽出が空振りするので、**呼び出し側は必ず空集合を fail-closed で赤にする**
# こと（空振りを「違反ゼロ」と読むと、見出しの改稿ひとつで検査が黙って無効化する）。
#
# grep の 0 件一致（rc=1）はここで吸収する。set -euo pipefail 下の呼び出し側でそのまま
# 返すと、代入式が suite ごと落ちて呼び出し側の空判定へ到達できない。
#
# bash 3.2 互換。外部コマンドは awk / grep / sed / sort のみ。

# 見出しで囲まれた節の本文を stdout へ。$1=文書 $2=開始見出しの ERE $3=終了見出しの ERE
ff_surface_section() {
  awk -v start="$2" -v stop="$3" '
    !inside && $0 ~ start { inside = 1; next }
    inside && $0 ~ stop { inside = 0 }
    inside { print }
  ' "$1"
}

# 節の本文から backtick で囲まれた token を集合として stdout へ。
# $1=節本文 $2=backtick を含む grep -oE パターン $3=token だけを残す sed -E パターン
ff_surface_tokens() {
  printf '%s\n' "$1" | { grep -oE "$2" || true; } | sed -E "$3" | LC_ALL=C sort -u
}

# 公開面 1: skill の起動名（すべて契約）
ff_surface_skills() {
  ff_surface_tokens "$(ff_surface_section "$1" '^## 公開面 1: Skills$' '^## ')" '`[a-z][a-z0-9-]*`' 's/`//g'
}

# 2-1: hook の「発火イベント :: matcher :: 実体」の三つ組（契約）。
# ファイル名だけを見ると、同じ実体を別イベントへ付け替える変更（PUBLIC-SURFACE.md が
# 破壊的変更と定義している）が集合として不変になり検出できない。
ff_surface_hook_triples() {
  ff_surface_tokens "$(ff_surface_section "$1" '^### 2-1\.' '^### ')" '`[A-Za-z]+ :: [^`]+ :: hooks/[A-Za-z0-9_.-]+`' 's/`//g'
}

# 2-2: 登録されていない hooks/ の実体（内部）
ff_surface_hook_internal() {
  ff_surface_tokens "$(ff_surface_section "$1" '^### 2-2\.' '^## ')" '`hooks/[A-Za-z0-9_.-]+`' 's#`##g; s#^hooks/##'
}

# 公開面 3: 導入先へ配置されるパス（契約）。表のデータ行の**先頭セル**だけを採る
# （「置く主体」「役割」の列にも backtick token があり、主体の書き換えを削除と誤読するため）。
ff_surface_paths() {
  ff_surface_section "$1" '^## 公開面 3: 導入先に配置されるパス$' '^## ' \
    | { grep -oE '^\| `[^`]+`' || true; } | sed -E 's/^\| `//; s/`$//' | LC_ALL=C sort -u
}

# 4-1 / 4-2: FF_* の契約 / 内部
ff_surface_env_contract() {
  ff_surface_tokens "$(ff_surface_section "$1" '^### 4-1\.' '^### ')" '`FF_[A-Z0-9_]+`' 's/`//g'
}
ff_surface_env_internal() {
  # 4-2 の小節は `####`。次の `###`（4-3）か `##` で止める（4-3 の旧名の列を内部へ数えない）。
  ff_surface_tokens "$(ff_surface_section "$1" '^### 4-2\.' '^##(#)? ')" '`FF_[A-Z0-9_]+`' 's/`//g'
}

# 4-3: L4 宣言の鍵（契約）。表のデータ行の**先頭セル**だけを採る（担当する実体・包含・旧名の列にも
# backtick token があるため）。鍵の正本は scripts/lib/l4-declarations.tsv で、4-3 との一致は
# tests/l4-declarations が見る。
ff_surface_l4_keys() {
  ff_surface_section "$1" '^### 4-3\.' '^##(#)? ' \
    | { grep -oE '^\| `[a-z0-9]+(-[a-z0-9]+)*`' || true; } | sed -E 's/^\| `//; s/`$//' | LC_ALL=C sort -u
}

# 公開面 5: FF_ で始まらない環境変数。
# 5-0 は母集団の決め方（接頭辞系統 `PREFIX_*` と系統外の単独名）、5-1 / 5-2 は契約 / 内部。
# FF_ の 4-1 / 4-2 と節を分けているのは、FF_* の等式（4-1 = 公開 ∩ 実行）へ非 FF_ の名前を
# 混ぜないため。token 形は FF_ 始まりを除外する — 5 節へ FF_* を書いても 4 節の検査から
# 抜け落ちないよう、こちらでは拾わない。
ff_surface_nonff_families() {
  ff_surface_tokens "$(ff_surface_section "$1" '^### 5-0\.' '^### ')" '`[A-Z][A-Z0-9]*(_[A-Z0-9]+)*_\*`' 's/`//g; s/_\*$//' \
    | { grep -v '^FF$' || true; }
}
ff_surface_nonff_singles() {
  ff_surface_tokens "$(ff_surface_section "$1" '^### 5-0\.' '^### ')" '`[A-Z][A-Z0-9]*_[A-Z0-9_]*[A-Z0-9]`' 's/`//g' \
    | { grep -v '^FF_' || true; }
}
ff_surface_nonff_contract() {
  ff_surface_tokens "$(ff_surface_section "$1" '^### 5-1\.' '^### ')" '`[A-Z][A-Z0-9]*_[A-Z0-9_]*[A-Z0-9]`' 's/`//g' \
    | { grep -v '^FF_' || true; }
}
ff_surface_nonff_internal() {
  ff_surface_tokens "$(ff_surface_section "$1" '^### 5-2\.' '^## ')" '`[A-Z][A-Z0-9]*_[A-Z0-9_]*[A-Z0-9]`' 's/`//g' \
    | { grep -v '^FF_' || true; }
}

# 契約側の全要素を 1 つの集合として stdout へ（種別ごとに接頭辞を付けて衝突を防ぐ）。
# base との差分で「契約から消えた要素」を出すために使う。
ff_surface_contract_tokens() {
  local doc="$1"
  ff_surface_skills "$doc" | sed 's#^#skill:#'
  ff_surface_hook_triples "$doc" | sed 's#^#hook:#'
  ff_surface_paths "$doc" | sed 's#^#path:#'
  ff_surface_env_contract "$doc" | sed 's#^#env:#'
  ff_surface_nonff_contract "$doc" | sed 's#^#env:#'
  ff_surface_l4_keys "$doc" | sed 's#^#skip:#'
}

# 契約トークン（種別の接頭辞付き）を、breaking 断片の本文で探す語へ写す。
# hook の三つ組は実体（hooks/<名>）を、ほかは接頭辞を外した名前をそのまま探す。
ff_surface_token_needle() {
  case "$1" in
    hook:*) printf '%s\n' "${1##* :: }" ;;
    *:*) printf '%s\n' "${1#*:}" ;;
    *) printf '%s\n' "$1" ;;
  esac
}

# 語がファイル群のどれかに、前後を [A-Za-z0-9_-] 以外（行頭・行末を含む）で区切って現れるか。
# $1=語 $2...=ファイル。rc 0: 現れる / 1: 現れない（ファイルが 0 件なら 1。stdin は読まない）。
ff_surface_names_token() {
  local needle="$1"
  shift
  [ "$#" -gt 0 ] || return 1
  awk -v n="$needle" '
    function sep(c) { return c == "" || c !~ /[A-Za-z0-9_-]/ }
    {
      p = 0
      while ((i = index(substr($0, p + 1), n)) > 0) {
        pos = p + i
        pre = (pos > 1) ? substr($0, pos - 1, 1) : ""
        post = substr($0, pos + length(n), 1)
        if (sep(pre) && sep(post)) { found = 1; exit }
        p = pos
      }
    }
    END { exit found ? 0 : 1 }
  ' "$@"
}
