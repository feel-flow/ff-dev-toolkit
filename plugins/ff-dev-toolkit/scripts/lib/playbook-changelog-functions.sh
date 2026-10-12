#!/usr/bin/env bash
#
# PLAYBOOK.md の Changelog「#### カウンター更新」配下の Helpful +1 行が、Jev の ACE 評価セット
# 生成器（scripts/jev/build-ace-eval-sets.ts の parseChangelog）が受理する契約の形かを、書き込み
# 時点で判定する共有関数（Issue `#2107`）。
#
# 契約の正本は parseChangelog で、ここはその shell 再現。両者が同じ入力で同じ判定になることは
# tests/jev-adapter/verify.sh（H23）が合成 fixture と実 PLAYBOOK で固定する。片方だけを直したら
# そこで赤になる。
#
# parseChangelog と同じ読み方:
#   - `## Changelog` 行（1 行目を除く行頭）より後だけを読む。無ければ判定不能
#   - `### [x.y.z] - YYYY-MM-DD` で版ブロックが始まる。版ブロックの外の行は読まない
#   - `#### 追加` → added 節、`#### カウンター更新` → helpful 節、それ以外の `#### ` → 節なし
#   - helpful 節の行は次の 1 行 1 ID だけを受理する:
#       `- ACE-X: Helpful +1（理由）` / `- ACE-X: Helpful +1 ×N（理由）` / `- ACE-X: Helpful +1 — 理由`
#     受理できず `Helpful +1` を含む行は「読めない Helpful 行」（複数 ID を 1 行へ束ねた
#     `- Helpful +1: ACE-A / ACE-B（理由）` はここに落ちる）
#   - added 節の `- ACE-X: …` 行を added として数える
#   - `#### 変更` / `#### 更新` など他の見出しの配下にある Helpful +1 行は読まない（対象外）
#   - added も helpful も 0 行なら「行が 1 件も読めない」（見出しの綴り変更を 0 件の緑へ倒さない）
#
# 公開関数:
#   ff_playbook_changelog_helpful_check <PLAYBOOK.md のパス>
#     stdout: 読めない Helpful 行を `<行番号>: <行>` で 1 行ずつ（rc 1 のとき）。rc 2 のときは理由 1 行
#     rc 0  契約の形で読めた（読めない Helpful 行なし、added / helpful の行が 1 件以上）
#     rc 1  読めない Helpful 行がある（stdout に行を列挙）
#     rc 2  判定不能（ファイルが読めない / `## Changelog` が無い / added も helpful も 0 行）
#     環境変数 FF_PLAYBOOK_CHANGELOG_VERDICT に ok / unreadable-helpful / unreadable-file /
#     no-changelog / no-rows を置く（呼び出し側が rc 2 の理由を分けて扱える）
#
# 既知の差: parseChangelog の `\s` は Unicode の空白（NBSP・全角空白）も受けるが、ここは
# `[[:space:]]`（ASCII + ロケールの空白）で判定する。契約の形は ASCII 空白だけで書く。
#
# source しても副作用は無い。bash 3.2 互換（連想配列・readarray を使わない）。awk の正規表現は
# 区間表現（`{n}`）を使わない（古い mawk / BSD awk が解釈しない）。

FF_PLAYBOOK_CHANGELOG_VERDICT=""

ff_playbook_changelog_helpful_check() {
  local file="${1:-}" out rc
  FF_PLAYBOOK_CHANGELOG_VERDICT=""
  if [ -z "$file" ] || [ ! -f "$file" ] || [ ! -r "$file" ]; then
    FF_PLAYBOOK_CHANGELOG_VERDICT="unreadable-file"
    printf '%s\n' "PLAYBOOK を読めません: ${file:-（空）}"
    return 2
  fi
  # awk は最後の行に VERDICT=<判定> を出す。読めない Helpful 行はその前に `<行番号>: <行>` で並ぶ
  # ロケールは呼び出し側のまま使う。多バイトのリテラル（（ ） × —）は C ロケールでもバイト列として
  # 一致し、区切りは ASCII だけなので、UTF-8 / C のどちらでも同じ判定になる（2026-10-11 両方で実測）
  out="$(awk '
    BEGIN { started = 0; cur = 0; sec = ""; added = 0; helpful = 0; bad = 0 }
    {
      line = $0
      sub(/\r$/, "", line)
      if (!started) {
        if (NR > 1 && line ~ /^## Changelog/) started = 1
        next
      }
      if (line ~ /^### \[[0-9.]+\] - [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]/) { cur = 1; sec = ""; next }
      if (line ~ /^#### 追加/) { sec = "added"; next }
      if (line ~ /^#### カウンター更新/) { sec = "helpful"; next }
      if (line ~ /^#### /) { sec = ""; next }
      if (!cur || sec == "") next
      if (sec == "helpful") {
        if (line ~ /^- ACE-[^:[:space:]]+: Helpful [+]1( ×[0-9]+)?(（.+）|[[:space:]]+—[[:space:]]+.+)[[:space:]]*$/) {
          helpful++
        } else if (line ~ /Helpful [+]1/) {
          bad++
          print NR ": " line
        }
        next
      }
      if (line ~ /^- ACE-[^:[:space:]]+: .+/) added++
    }
    END {
      if (!started) print "VERDICT=no-changelog"
      else if (bad > 0) print "VERDICT=unreadable-helpful"
      else if (added == 0 && helpful == 0) print "VERDICT=no-rows"
      else print "VERDICT=ok"
    }
  ' "$file" 2>/dev/null)" || out=""
  case "$out" in
    *VERDICT=ok) FF_PLAYBOOK_CHANGELOG_VERDICT="ok"; rc=0 ;;
    *VERDICT=unreadable-helpful) FF_PLAYBOOK_CHANGELOG_VERDICT="unreadable-helpful"; rc=1 ;;
    *VERDICT=no-changelog) FF_PLAYBOOK_CHANGELOG_VERDICT="no-changelog"; rc=2 ;;
    *VERDICT=no-rows) FF_PLAYBOOK_CHANGELOG_VERDICT="no-rows"; rc=2 ;;
    *)
      # awk が走らなかった・判定行が無い: 読めたことにしない
      FF_PLAYBOOK_CHANGELOG_VERDICT="unreadable-file"
      printf '%s\n' "PLAYBOOK の Changelog を走査できません（awk の判定行が無い）: ${file}"
      return 2
      ;;
  esac
  case "$rc" in
    1) printf '%s\n' "$out" | sed '$d' ;;
    2)
      if [ "$FF_PLAYBOOK_CHANGELOG_VERDICT" = "no-changelog" ]; then
        printf '%s\n' "PLAYBOOK.md に ## Changelog がありません（parseChangelog と同じく判定不能）: ${file}"
      else
        printf '%s\n' "Changelog の追加 / カウンター更新の行が 1 件も読めません（#### 追加 / #### カウンター更新 の見出しや行形式が変わった可能性）: ${file}"
      fi
      ;;
  esac
  return "$rc"
}
