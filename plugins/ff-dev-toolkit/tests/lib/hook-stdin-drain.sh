#!/usr/bin/env bash
#
# hooks/hooks.json に登録された全 hook が stdin を読み切る契約（正本は
# hooks/asdd-hook-gate.sh の "stdin contract" 節）を静的に検査する共有スキャナ。
#
# なぜ静的検査なのか: 契約 (b) は「読まない hook を許さない」で、これは**名簿ではなく
# 列挙**でしか守れない。免除リストを持つと、後から足した hook が無審査で通る（denylist は
# 未登録の名前を素通りさせる）。判定対象は hooks.json が実際に登録しているコマンドから
# 導出し、このファイル側に hook 名を書かない。
#
# なぜ実行検査ではないのか: 実行検査（大きなペイロードを書いて書き手の rc を見る）は
# 各 hook の suite が既に持っている。横断側が要るのは「新しく足した 1 本が契約から外れて
# いないか」で、それは実行しなくても形で分かる。静的なら hook を実際に起動しないので、
# 副作用（ネットワーク・キャッシュ書き込み）を踏まずに全件を見られる。
#
# **解釈できない入力は緑にしない。** 初版は「/hooks/ を含まない登録」「末尾が .sh でない
# 登録」を黙って continue しており、`bash "$ROOT/hooks/x.sh --flag"` や
# `bash "$ROOT/scripts/x.sh"` の形で登録した契約違反 hook が無審査で通った（レビューで実測）。
# 解釈できない登録は走査不成立（rc=2）として止める — 検査の届かない形を増やせば緑になる、
# という抜け道を残さないため。
#
# 検査する形:
#   1. drain がある（`read` に `-d ''` が付き、区切りが**空**である）
#      - 上限付き（`-t <値>`）は契約 (c) で許可されるので 1 を満たすものとして扱う
#      - `-d` の引数が空でない（`read -d x`）は最初の x で止まるので drain ではない
#      - 旗の順序・結合（`-rd ''` / `-d '' -r`）は同じ意味なので受ける
#      - リダイレクト付き（`< <(...)` / `done <`）の read は stdin を読んでいないので数えない
#      - heredoc 本文の行は実行されないので走査対象から外す
#   2. drain が ASDD ゲート（asdd-hook-gate.sh への言及行）より**前**にある
#      - ゲートを変数経由で source する形（`GATE=...; source "$GATE"`）でも位置を見失わないよう、
#        アンカーは「非コメント行で asdd-hook-gate.sh が最初に現れる行」まで広げる（保守側）
#      - ゲート言及が 1 行も無い hook は緑にしない（契約の適用対象かを判定できないため）
#   3. drain が `cat` ではない（PATH 破損で command not found → 未読のまま exit 0）
#      - この検査は drain 欠落の判定より**前**に置く。後ろに置くと `input="$(cat)"` だけの
#        hook は「drain がありません」で早期 continue され、cat の検査へ到達しない（実測）
#
# 公開関数:
#   ff_hook_stdin_drain_scan <plugin root>
#     違反を 1 行 1 件で stdout へ出し、違反があれば 1 を返す。走査不成立は 2。

# heredoc 本文とコメントを落とした「実行される行」だけを NR 付きで出す。
_ff_hook_effective_lines() { # <file>
  awk '
    inbody {
      if ($0 == marker || $0 == "\t" marker) { inbody = 0 }
      next
    }
    /^[[:space:]]*#/ { next }
    {
      line = $(0)
      if (match(line, /<<-?[[:space:]]*[\047"]?[A-Za-z_][A-Za-z_0-9]*[\047"]?/)) {
        m = substr(line, RSTART, RLENGTH)
        gsub(/^<<-?[[:space:]]*/, "", m); gsub(/[\047"]/, "", m)
        marker = m; inbody = 1
      }
      print NR "\t" line
    }
  ' "$1"
}

ff_hook_stdin_drain_scan() { # <plugin root>
  local root="${1:-}" hooks_json cmds rc=0 found=0
  [ -n "$root" ] && [ -d "$root" ] || { echo "SCAN-ERROR: plugin root を解決できません: ${root:-（空）}"; return 2; }
  hooks_json="$root/hooks/hooks.json"
  [ -f "$hooks_json" ] || { echo "SCAN-ERROR: hooks.json がありません: $hooks_json"; return 2; }
  command -v jq >/dev/null 2>&1 || { echo "SCAN-ERROR: jq が必要です"; return 2; }

  cmds="$(jq -r '
    .hooks // {} | to_entries[] | .value[]? | .hooks[]? | .command // empty
  ' "$hooks_json" 2>/dev/null)" || { echo "SCAN-ERROR: hooks.json を解析できません"; return 2; }
  [ -n "$cmds" ] || { echo "SCAN-ERROR: hooks.json に登録コマンドがありません（走査不成立）"; return 2; }

  local line file base seen="" eff
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    # 登録コマンドから hook ファイルを解決する。解決できない形は緑にしない。
    base="$(printf '%s\n' "$line" | awk '
      {
        line = $(0)
        gsub(/["\047]/, " ", line)
        n = split(line, w, /[[:space:]]+/)
        for (i = 1; i <= n; i++) {
          if (w[i] ~ /\.sh$/) { print w[i]; exit }
        }
      }')"
    if [ -z "$base" ]; then
      echo "SCAN-ERROR: 登録コマンドから hook ファイルを解決できません（解釈できない形を緑にしない）: $line"
      return 2
    fi
    base="${base##*/}"
    case " $seen " in *" $base "*) continue ;; esac
    seen="$seen $base"
    file="$root/hooks/$base"
    found=$((found + 1))
    if [ ! -f "$file" ]; then
      echo "SCAN-ERROR: hooks.json が登録しているファイルが実在しません: $base"
      return 2
    fi

    eff="$(_ff_hook_effective_lines "$file")"
    local gate_line drain_line cat_line
    gate_line="$(printf '%s\n' "$eff" | awk -F'\t' '$2 ~ /asdd-hook-gate\.sh/ { print $1; exit }')"
    # `-d ''` / `-d ""`（空の区切り）だけを drain と認める。リダイレクト付きの read は
    # stdin ではなく別の入力を読んでいるので数えない。
    drain_line="$(printf '%s\n' "$eff" | awk -F'\t' '
      $2 ~ /(^|[[:space:]])read([[:space:]]+-[A-Za-z]+)*[[:space:]]/ &&
      $2 ~ /-[A-Za-z]*d[[:space:]]*(\047\047|"")([[:space:]]|$)/ &&
      $2 !~ /<[[:space:]]*[(<]/ && $2 !~ /done[[:space:]]*</ && $2 !~ /[[:space:]]<[[:space:]]/ { print $1; exit }
    ')"
    cat_line="$(printf '%s\n' "$eff" | awk -F'\t' '$2 ~ /^[[:space:]]*[A-Za-z_][A-Za-z_0-9]*=.*\$\(cat([[:space:]]|\))/ { print $1; exit }')"

    if [ -z "$gate_line" ]; then
      echo "VIOLATION: $base — ASDD ゲートへの言及がありません（契約の適用位置を判定できないため緑にしません）"
      rc=1
      continue
    fi
    # cat の検査は drain 欠落の判定より前（後ろだと cat だけの hook に到達しない）
    if [ -n "$cat_line" ] && [ "$cat_line" -lt "$gate_line" ]; then
      echo "VIOLATION: $base — drain に cat を使っています（L${cat_line}。PATH 破損で未読のまま exit 0 します）"
      rc=1
      continue
    fi
    if [ -z "$drain_line" ]; then
      echo "VIOLATION: $base — stdin の drain がありません（契約 (b): 読まない hook は許可されません）"
      rc=1
      continue
    fi
    if [ "$drain_line" -gt "$gate_line" ]; then
      echo "VIOLATION: $base — drain (L${drain_line}) が ASDD ゲート (L${gate_line}) より後にあります（ゲートの早期終了で未読のまま exit 0 する経路が開きます）"
      rc=1
    fi
  done <<EOF
$cmds
EOF

  [ "$found" -gt 0 ] || { echo "SCAN-ERROR: 走査対象の hook を 1 本も抽出できませんでした（走査不成立）"; return 2; }
  echo "INSPECTED	$found"
  return "$rc"
}
