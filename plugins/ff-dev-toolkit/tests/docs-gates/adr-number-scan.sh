#!/usr/bin/env bash
# DECISIONS.md の ADR 番号整合検査（観測台帳 OBS-066 の昇格）。
#
# ADR 番号は共有台帳のグローバル連番なので、並行セッションが同日に採番すると衝突する。
# rebase 競合で気付けるのは挿入位置がたまたま重なったときだけで、別位置へ挿入されていれば
# 機械マージが通り同番号の ADR が 2 本並ぶ（2026-09 実測、3 回）。既存の対策は手順側だけ
# （採番根拠を見出し行の数値順最大値にする）で、重複そのものを検出する機械ゲートは無かった。
#
# 固定する不変条件は 2 つ:
#   1. 見出し `^## ADR-N:` の番号に重複が無い。決定ログ表の `| ADR-N |` にも重複が無い
#   2. 見出しの番号集合と決定ログ表の番号集合が一致する（片側だけの追加・削除を許さない）
#
# 抽出規則:
#   - コードフェンス（``` / ~~~）の中は読まない。DECISIONS.md は決定記録テンプレートと
#     採番手順の例をフェンスで持っており、雛形 `## ADR-XXX` や採番コマンド例の
#     `^## ADR-[0-9]+` のような行を拾うと名簿が汚れる
#   - 番号は数値へ正規化してから比較し `ADR-%03d` の形で名指しする（`ADR-48` と `ADR-048`
#     を別番号として二重計上しない）
#   - 表は `## 決定ログ` 節に限定する。文書内の別の表が第 1 列へ ADR 番号を書いても
#     決定サマリの名簿と混ざらない
#   - `\s` `\d` などの GNU 拡張は使わない（BSD awk / grep で無効なため POSIX クラスで書く）
#
# 単体でも実行できる（導入先リポジトリからそのまま呼べる形）:
#   bash adr-number-scan.sh <DECISIONS.md>
#   rc=0 整合 / rc=1 不整合（内訳を stdout へ列挙）/ rc=2 抽出不能（fail-closed）

# 見出しの ADR 番号を出現順に 1 行 1 件で出す。
ff_adr_heading_numbers() {
  awk '
    /^[[:space:]]*(```|~~~)/ { in_fence = !in_fence; next }
    in_fence { next }
    /^##[[:space:]]+ADR-[0-9]+/ {
      n = $0
      sub(/^##[[:space:]]+ADR-/, "", n)
      sub(/[^0-9].*$/, "", n)
      if (n != "") printf("ADR-%03d\n", n + 0)
    }
  ' "$1"
}

# 決定ログ表（`## 決定ログ` 節の `| ADR-N |` 行）の ADR 番号を出現順に出す。
ff_adr_table_numbers() {
  awk '
    /^[[:space:]]*(```|~~~)/ { in_fence = !in_fence; next }
    in_fence { next }
    /^##[[:space:]]+決定ログ[[:space:]]*$/ { in_log = 1; next }
    in_log && /^##[[:space:]]/ { exit }
    in_log && /^\|[[:space:]]*ADR-[0-9]+[[:space:]]*\|/ {
      n = $0
      sub(/^\|[[:space:]]*ADR-/, "", n)
      sub(/[^0-9].*$/, "", n)
      if (n != "") printf("ADR-%03d\n", n + 0)
    }
  ' "$1"
}

# $1: DECISIONS.md のパス。不整合の内訳を stdout へ出し、rc で結果を返す。
ff_adr_number_scan() {
  local file="$1"
  local headings table dup_headings dup_table only_heading only_table
  local findings=0 number

  if [ ! -f "$file" ]; then
    printf 'read-error: %s を読み取れません\n' "$file"
    return 2
  fi

  headings="$(ff_adr_heading_numbers "$file")" || return 2
  table="$(ff_adr_table_numbers "$file")" || return 2

  if [ -z "$headings" ]; then
    printf 'extract-empty: %s から ADR 見出し（^## ADR-N:）を 1 件も抽出できません\n' "$file"
    return 2
  fi
  if [ -z "$table" ]; then
    printf 'extract-empty: %s の決定ログ表（## 決定ログ 節の ADR 行）を 1 件も抽出できません\n' "$file"
    return 2
  fi

  dup_headings="$(printf '%s\n' "$headings" | LC_ALL=C sort | LC_ALL=C uniq -d)"
  dup_table="$(printf '%s\n' "$table" | LC_ALL=C sort | LC_ALL=C uniq -d)"
  only_heading="$(LC_ALL=C comm -23 \
    <(printf '%s\n' "$headings" | LC_ALL=C sort -u) \
    <(printf '%s\n' "$table" | LC_ALL=C sort -u))"
  only_table="$(LC_ALL=C comm -13 \
    <(printf '%s\n' "$headings" | LC_ALL=C sort -u) \
    <(printf '%s\n' "$table" | LC_ALL=C sort -u))"

  while IFS= read -r number; do
    [ -n "$number" ] || continue
    printf 'duplicate-heading: %s の見出しが複数あります（並行採番の衝突）\n' "$number"
    findings=$((findings + 1))
  done <<< "$dup_headings"

  while IFS= read -r number; do
    [ -n "$number" ] || continue
    printf 'duplicate-table: %s の行が決定ログ表に複数あります（並行採番の衝突）\n' "$number"
    findings=$((findings + 1))
  done <<< "$dup_table"

  while IFS= read -r number; do
    [ -n "$number" ] || continue
    printf 'heading-only: %s は見出しにありますが決定ログ表にありません\n' "$number"
    findings=$((findings + 1))
  done <<< "$only_heading"

  while IFS= read -r number; do
    [ -n "$number" ] || continue
    printf 'table-only: %s は決定ログ表にありますが見出しがありません\n' "$number"
    findings=$((findings + 1))
  done <<< "$only_table"

  [ "$findings" -eq 0 ] || return 1
  return 0
}

# 単体実行の入口。source されたときは何もしない。
if [ "${BASH_SOURCE[0]:-$0}" = "$0" ]; then
  if [ "$#" -ne 1 ]; then
    echo "usage: bash adr-number-scan.sh <DECISIONS.md>" >&2
    exit 2
  fi
  ff_adr_scan_rc=0
  ff_adr_number_scan "$1" || ff_adr_scan_rc=$?
  if [ "$ff_adr_scan_rc" -eq 0 ]; then
    printf 'ok: %s の ADR 番号は重複無し・見出しと決定ログ表が一致\n' "$1"
  fi
  exit "$ff_adr_scan_rc"
fi
