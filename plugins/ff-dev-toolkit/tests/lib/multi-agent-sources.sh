#!/usr/bin/env bash
#
# multi-agent.sh の構成ファイル（入口 + scripts/lib/multi-agent-*.sh）を suite から列挙する
# （ADR-075）。
#
# multi-agent.sh は本体を責務ごとの構成ファイルへ分け、開始時に MULTI_AGENT_PARTS の順で
# source する。本文を読む suite（文字列の針・関数の切り出し・変異の注入・環境変数名の抽出）が
# 入口だけを読むと、構成ファイルへ移った行には針が当たらず、検査が黙って弱まる。名簿の正本は
# 入口の MULTI_AGENT_PARTS で、本 lib はそれを読むだけで複製を持たない（構成ファイルを足した・
# 分け直した回も suite 側は直さずに済む）。
#
# 公開関数:
#   ma_sources_load <scripts dir>
#     <scripts dir>/multi-agent.sh の MULTI_AGENT_PARTS を読み、グローバル配列 MA_SOURCES に
#     入口・構成ファイルの順で絶対パスを入れる。名簿の区間が無い・空・書式が違う・列挙した
#     ファイルが無いときは fail-closed で exit 1 にする（針が当たらない入力を緑にしない）。
#     <scripts dir> は実体の scripts/ でも、suite が作った写し（cp -R scripts）でもよい。
#   ma_sources_cat
#     MA_SOURCES を順に連結して stdout へ出す。関数の切り出しや「全体で N 件」の針は
#     ファイルごとではなく連結に掛ける（件数がファイル間で割れても数え漏らさない）。
#   ma_source_holding <固定文字列>
#     その固定文字列を含むファイルを MA_SOURCES から 1 つだけ選んで stdout へ出す。0 件・
#     複数ファイルなら exit 1（変異の注入先を取り違えたまま「注入できた」としない）。
#
# 書式の契約（入口側）: 名簿は `MULTI_AGENT_PARTS=(` の行から `)` だけの行までで、要素は
# 1 行 1 つの `  "${SCRIPT_DIR}/lib/<名前>.sh"`。入口の書式を変えたら本 lib も直す。
#
# 運用注記: 本ファイルは source される前提（実行ビット不要）。bash 3.2 互換。heredoc と
# 一時ファイルを使わない（read-only 環境でも suite の skip 判定まで届くようにする。
# adapter-env-isolation.sh の設計メモと同じ理由）。

ma_sources_load() {
  local scripts_dir="$1" entry line in_list=0 rel n=0
  entry="${scripts_dir}/multi-agent.sh"
  MA_SOURCES=()
  if [ ! -f "$entry" ]; then
    echo "✗ ma_sources_load: 入口がありません: ${entry}" >&2
    exit 1
  fi
  MA_SOURCES=("$entry")
  while IFS= read -r line || [ -n "$line" ]; do
    if [ "$in_list" -eq 0 ]; then
      [ "$line" = "MULTI_AGENT_PARTS=(" ] && in_list=1
      continue
    fi
    [ "$line" = ")" ] && { in_list=2; break; }
    case "$line" in
      '  "${SCRIPT_DIR}/'*'.sh"') rel="${line#  \"\$\{SCRIPT_DIR\}/}"; rel="${rel%\"}" ;;
      *)
        echo "✗ ma_sources_load: MULTI_AGENT_PARTS の要素の書式が違います: ${line}" >&2
        exit 1 ;;
    esac
    case "$rel" in
      lib/*.sh) : ;;
      *)
        echo "✗ ma_sources_load: 構成ファイルが scripts/lib/ の外を指しています: ${rel}" >&2
        exit 1 ;;
    esac
    if [ ! -f "${scripts_dir}/${rel}" ]; then
      echo "✗ ma_sources_load: 名簿の構成ファイルがありません: ${scripts_dir}/${rel}" >&2
      exit 1
    fi
    MA_SOURCES+=("${scripts_dir}/${rel}")
    n=$((n + 1))
  done < "$entry"
  if [ "$in_list" -ne 2 ] || [ "$n" -eq 0 ]; then
    echo "✗ ma_sources_load: ${entry} に MULTI_AGENT_PARTS の名簿（1 件以上）が見つかりません" >&2
    exit 1
  fi
}

ma_sources_cat() {
  if [ "${#MA_SOURCES[@]}" -lt 2 ]; then
    echo "✗ ma_sources_cat: ma_sources_load を先に呼んでください" >&2
    exit 1
  fi
  cat -- "${MA_SOURCES[@]}"
}

ma_source_holding() {
  local needle="$1" f found="" count=0
  if [ "${#MA_SOURCES[@]}" -lt 2 ]; then
    echo "✗ ma_source_holding: ma_sources_load を先に呼んでください" >&2
    exit 1
  fi
  for f in "${MA_SOURCES[@]}"; do
    if grep -qF -- "$needle" "$f"; then
      found="$f"
      count=$((count + 1))
    fi
  done
  if [ "$count" -ne 1 ]; then
    echo "✗ ma_source_holding: 「${needle}」を含むファイルが 1 つではありません（${count} 件）" >&2
    exit 1
  fi
  printf '%s\n' "$found"
}
