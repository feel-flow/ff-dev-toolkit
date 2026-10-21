#!/usr/bin/env bash
#
# adapter-common.sh の構成ファイル（入口 + scripts/lib/adapter-common-*.sh）を suite から列挙する
# （ADR-075）。
#
# 名簿の正本は入口の ADAPTER_COMMON_PARTS。本 lib はそれを読むだけで複製を持たない。
# 入口だけを読むと、構成ファイルへ移った行には針が当たらず、検査が黙って弱まる。
#
# 公開関数:
#   ac_sources_load <entry>
#     入口の ADAPTER_COMMON_PARTS を読み、グローバル配列 AC_SOURCES に入口・構成ファイルの
#     順で絶対パスを入れる。名簿が無い・空・書式が違う・ファイルが無いときは exit 1。
#   ac_sources_cat
#     AC_SOURCES を順に連結して stdout へ出す。
#   ac_source_holding <固定文字列>
#     その固定文字列を含むファイルを 1 つだけ選ぶ。0 件・複数なら exit 1。
#
# 書式の契約（入口側）: 名簿は `ADAPTER_COMMON_PARTS=(` から `)` だけの行までで、要素は
# 1 行 1 つの `  "${_ac_dir}/<名前>.sh"`。
#
# 運用注記: source される前提（実行ビット不要）。bash 3.2 互換。heredoc と一時ファイルを使わない。

ac_sources_load() {
  local entry="$1" line in_list=0 rel n=0 dir
  AC_SOURCES=()
  if [ ! -f "$entry" ]; then
    echo "✗ ac_sources_load: 入口がありません: ${entry}" >&2
    exit 1
  fi
  dir="$(cd "${entry%/*}/../lib" 2>/dev/null && pwd)" || {
    echo "✗ ac_sources_load: 構成ファイルの置き場がありません: ${entry%/*}/../lib" >&2
    exit 1
  }
  AC_SOURCES=("$entry")
  while IFS= read -r line || [ -n "$line" ]; do
    if [ "$in_list" -eq 0 ]; then
      [ "$line" = "ADAPTER_COMMON_PARTS=(" ] && in_list=1
      continue
    fi
    [ "$line" = ")" ] && { in_list=2; break; }
    case "$line" in
      '  "${_ac_dir}/'*'.sh"') rel="${line#  \"\$\{_ac_dir\}/}"; rel="${rel%\"}" ;;
      *)
        echo "✗ ac_sources_load: ADAPTER_COMMON_PARTS の要素の書式が違います: ${line}" >&2
        exit 1 ;;
    esac
    case "$rel" in
      adapter-common-*.sh) : ;;
      *)
        echo "✗ ac_sources_load: 構成ファイルの名前が adapter-common-*.sh ではありません: ${rel}" >&2
        exit 1 ;;
    esac
    if [ ! -f "${dir}/${rel}" ]; then
      echo "✗ ac_sources_load: 名簿の構成ファイルがありません: ${dir}/${rel}" >&2
      exit 1
    fi
    AC_SOURCES+=("${dir}/${rel}")
    n=$((n + 1))
  done < "$entry"
  if [ "$in_list" -ne 2 ] || [ "$n" -eq 0 ]; then
    echo "✗ ac_sources_load: ${entry} に ADAPTER_COMMON_PARTS の名簿（1 件以上）が見つかりません" >&2
    exit 1
  fi
}

ac_sources_cat() {
  if [ "${#AC_SOURCES[@]}" -lt 2 ]; then
    echo "✗ ac_sources_cat: ac_sources_load を先に呼んでください" >&2
    exit 1
  fi
  cat -- "${AC_SOURCES[@]}"
}

ac_source_holding() {
  local needle="$1" f found="" count=0
  if [ "${#AC_SOURCES[@]}" -lt 2 ]; then
    echo "✗ ac_source_holding: ac_sources_load を先に呼んでください" >&2
    exit 1
  fi
  for f in "${AC_SOURCES[@]}"; do
    if grep -qF -- "$needle" "$f"; then
      found="$f"
      count=$((count + 1))
    fi
  done
  if [ "$count" -ne 1 ]; then
    echo "✗ ac_source_holding: 「${needle}」を含むファイルが 1 つではありません（${count} 件）" >&2
    exit 1
  fi
  printf '%s\n' "$found"
}
