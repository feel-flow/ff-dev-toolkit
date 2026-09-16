#!/usr/bin/env bash
#
# HOST-PARITY.md の 4 表（hosts / routes / asymmetries / contracts）を読む共有リーダー。
#
# 正本表は開発元リポジトリの docs/06-reference/HOST-PARITY.md で、HTML コメントの
# sentinel で各表を切り出す。**この表形式を知っているコードを 2 箇所へ写さない** —
# 写すと sentinel の形・列の並び・バッククォート囲みの扱いが片方だけ変わり、
# 「同じ表を読んでいるはずの 2 つの検査が別のものを読む」形でドリフトする。
# 現在の consumer は host-route-parity と root-instructions-parity の 2 suite。
#
# 依存は awk のみ。渡す正規表現は ASCII だけで、表の中身（日本語を含む）は
# 文字列比較か固定文字列でしか扱わないのでロケールに依存しない。
#
# 使い方:
#   . "$PLUGIN_ROOT/tests/lib/host-parity-tables.sh"
#   ff_parity_set_registry "$REPO_ROOT/docs/06-reference/HOST-PARITY.md"
#   ff_parity_rows routes | while IFS= read -r row; do ...; done

# 読み取り対象の正本表を固定する。呼び出し側が解決したパスを受ける（このライブラリは
# リポジトリ構造を推測しない — suite ごとに REPO_ROOT の導出が違うため）。
ff_parity_set_registry() { # <正本表のパス>
  FF_PARITY_REGISTRY="$1"
}

# sentinel は開始・終了が各1件で正順であることまで見る。重複・欠落・逆順を黙って
# 「0 行」へ畳むと、表を丸ごと消した変更が全 pass のまま緑になる。
ff_parity_block() { # <ブロック名> : 区間内の生の行
  awk -v s="<!-- host-parity:$1:start -->" -v e="<!-- host-parity:$1:end -->" '
    $0 == s { if (inb) bad = 1; inb = 1; ns++; next }
    $0 == e { if (!inb) bad = 1; inb = 0; ne++; next }
    inb { print }
    END { if (ns != 1 || ne != 1 || inb || bad) exit 3 }
  ' "${FF_PARITY_REGISTRY:?ff_parity_set_registry を先に呼ぶこと}"
}

# 表の本文行だけを返す（ヘッダー行と区切り行を落とす）。
ff_parity_rows() { # <ブロック名>
  ff_parity_block "$1" | awk '
    substr($0, 1, 1) != "|" { next }
    { body = $0; gsub(/[ \t|:-]/, "", body); if (body == "") next }
    !seen_header { seen_header = 1; next }
    { print }
  '
}

# `exit` で 1 行目だけ読んで抜けない。reader が先に落ちると writer（ff_parity_block の
# awk）が SIGPIPE で死に、`set -euo pipefail` のもとで裸代入ごと rc=141 で落ちる —
# 診断を 1 行も出さない死に方。ブロックがパイプバッファ（macOS 64KB）を超えたときだけ
# 起きるので、表が育つまで気付けない。
ff_parity_header() { # <ブロック名>
  ff_parity_block "$1" | awk 'substr($0, 1, 1) == "|" && !seen { seen = 1; print }'
}

# `| a | b | c |` の n 番目のセル。前後の空白を落とす。
ff_parity_row_cell() { # <行> <n>
  printf '%s\n' "$1" | awk -F'|' -v n="$2" '
    { c = $(n + 1); gsub(/^[ \t]+/, "", c); gsub(/[ \t]+$/, "", c); print c }
  '
}

ff_parity_row_cell_count() { # <行>
  printf '%s\n' "$1" | awk -F'|' '{ print NF - 2 }'
}

# セル内のバッククォート囲みトークンを 1 行 1 件で返す。
ff_parity_bt_tokens() { # <セル>
  printf '%s\n' "$1" | awk '
    { n = split($0, a, "`"); for (i = 2; i <= n; i += 2) if (a[i] != "") print a[i] }
  '
}

ff_parity_bt_one() { # <セル> : ちょうど1件ならそれを返す。それ以外は非 0
  local toks count
  toks="$(ff_parity_bt_tokens "$1")"
  count="$(printf '%s\n' "$toks" | awk 'NF { n++ } END { print n + 0 }')"
  [ "$count" = "1" ] || return 1
  printf '%s' "$toks"
}

ff_parity_route_paths() { # <経路 ID> : その経路の届け先を空白区切りで返す
  local want="$1" rrow rid out=""
  while IFS= read -r rrow; do
    [ -n "$rrow" ] || continue
    rid="$(ff_parity_bt_one "$(ff_parity_row_cell "$rrow" 1)" || true)"
    [ "$rid" = "$want" ] || continue
    out="$(ff_parity_bt_tokens "$(ff_parity_row_cell "$rrow" 2)" | tr '\n' ' ')"
  done <<EOF
$(ff_parity_rows routes)
EOF
  printf '%s' "$out"
}

ff_parity_route_hosts() { # <経路 ID> : その経路の対象ホストを空白区切りで返す
  local want="$1" rrow rid out=""
  while IFS= read -r rrow; do
    [ -n "$rrow" ] || continue
    rid="$(ff_parity_bt_one "$(ff_parity_row_cell "$rrow" 1)" || true)"
    [ "$rid" = "$want" ] || continue
    out="$(ff_parity_bt_tokens "$(ff_parity_row_cell "$rrow" 3)" | tr '\n' ' ')"
  done <<EOF
$(ff_parity_rows routes)
EOF
  printf '%s' "$out"
}

# asymmetries 表の <ID> 行が挙げる一次情報パスを空白区切りで返す。
# 一次情報列は末尾から 2 列目（最終列は「判明した経緯」）。
ff_parity_asym_sources() { # <非対称 ID>
  local want="$1" arow aid n out=""
  while IFS= read -r arow; do
    [ -n "$arow" ] || continue
    aid="$(ff_parity_bt_one "$(ff_parity_row_cell "$arow" 1)" || true)"
    [ "$aid" = "$want" ] || continue
    n="$(ff_parity_row_cell_count "$arow")"
    [ "$n" -ge 2 ] || continue
    out="$(ff_parity_bt_tokens "$(ff_parity_row_cell "$arow" $((n - 1)))" | tr '\n' ' ')"
  done <<EOF
$(ff_parity_rows asymmetries)
EOF
  printf '%s' "$out"
}
