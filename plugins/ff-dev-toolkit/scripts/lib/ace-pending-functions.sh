#!/usr/bin/env bash
# ACE候補の永続store。採用済みエントリ/件数には混ぜない（Issue `#2040`）。

ff_ace_pending_validate() {
  local file="$1"
  if [ ! -f "$file" ] || [ ! -r "$file" ] || [ -L "$file" ]; then
    printf 'ACE pending: 候補ファイルを読めません: %s\n' "$file" >&2
    return 2
  fi
  awk '
    function bad(reason) {
      print "ACE pending: 不正な候補形式（line " NR "): " reason > "/dev/stderr"
      failed = 1; exit 2
    }
    function finish() {
      if (stage != 4 || !body) bad("必須metaまたは本文がありません")
      stage = 0; body = 0
    }
    NR == 1 {
      if ($0 != "<!-- ff-ace-pending:v1 -->") bad("format markerがありません")
      marker = 1; next
    }
    /[\r\034\035\036\037]/ { bad("構造を曖昧にする制御文字があります") }
    /\t/ && $0 !~ /^>( |$)/ { bad("metaのtabは使えません") }
    /^### / {
      if (stage) bad("前の候補が閉じられていません")
      rest = $0; sub(/^### /, "", rest)
      id = rest; sub(/:.*/, "", id)
      if (id !~ /^PENDING-(PR|ISSUE)-[1-9][0-9]*-[1-9][0-9]*$/) bad("候補IDが不正です")
      if (seen[id]++) bad("候補IDが重複しています")
      title = rest; sub(/^[^:]+: /, "", title)
      if (title == rest || title !~ /[^[:space:]]/) bad("タイトルがありません")
      stage = 1; next
    }
    stage == 1 {
      if ($0 !~ /^\| Category \| [a-z][a-z0-9-]* \|$/) bad("Categoryが不正です")
      stage = 2; next
    }
    stage == 2 {
      if ($0 !~ /^\| Origin \| [^|]+ \|$/) bad("Originが不正です")
      origin = $0; sub(/^\| Origin \| /, "", origin); sub(/ \|$/, "", origin)
      if (origin !~ /[^[:space:]]/) bad("Originが空です")
      stage = 3; next
    }
    stage == 3 {
      if ($0 != "| Status | pending |") bad("Statusはpendingだけです")
      stage = 4; next
    }
    stage == 4 {
      if ($0 == "---") { finish(); next }
      if ($0 == "") next
      # 空の引用行は `>` だけ（Markdown の空の引用行。旧版が書いた `> ` も読む）。行末の空白は
      # markdownlint の MD009 が拒否し、整形で消されやすいので、書く側は `>` に揃える（Issue `#2372`）
      if ($0 !~ /^>( |$)/) bad("本文は引用行で保存してください")
      if (substr($0, 3) ~ /[^[:space:]]/) body = 1
      next
    }
    $0 == "# ACE 保留候補" { heading++; next }
    $0 == "## エントリ一覧" { entries++; next }
    $0 == "" { next }
    { bad("認識できない行です") }
    END {
      if (failed) exit 2
      if (!marker || heading != 1 || entries != 1 || stage) {
        print "ACE pending: 不完全な候補ファイルです" > "/dev/stderr"; exit 2
      }
    }
  ' "$file"
}

ff_ace_pending_count() {
  awk '/^### PENDING-/ { n++ } END { print n + 0 }' "$1"
}

ff_ace_pending_entry() { # validated store / ID
  awk -v wanted="$2" '
    /^### / { id = $0; sub(/^### /, "", id); sub(/:.*/, "", id); selected = (id == wanted) }
    selected { print }
    selected && $0 == "---" { exit }
  ' "$1"
}

ff_ace_pending_capacity() { # report / category / proposed / rc → current limit
  local report="$1" category="$2" proposed="$3" gate_rc="$4"
  case "$gate_rc" in 0|1) ;; *) echo 'ACE pending: 件数検査が成立していません' >&2; return 2 ;; esac
  [ -f "$report" ] && [ -r "$report" ] || {
    echo 'ACE pending: 件数検査のreportを読めません' >&2; return 2;
  }
  awk -v category="$category" -v proposed="$proposed" '
    index($0, category ": ") == 1 {
      value = substr($0, length(category) + 3)
      if (value !~ /^[0-9]+$/) invalid = 1
      current = value; categories++
    }
    /^ブロック上限: / {
      if ($0 !~ /^ブロック上限: [1-9][0-9]* 件\/カテゴリ/) invalid = 1
      value = $0; sub(/^ブロック上限: /, "", value); sub(/ 件\/カテゴリ.*/, "", value)
      if (value !~ /^[1-9][0-9]*$/) invalid = 1
      limit = value; limits++
    }
    END {
      if (length(current) > 9 || length(limit) > 9 || length(proposed) > 9) invalid = 1
      if (invalid || categories != 1 || limits != 1) {
        print "ACE pending: 件数/上限を一意に読めません" > "/dev/stderr"; exit 2
      }
      print current, limit
    }
  ' "$report"
}
