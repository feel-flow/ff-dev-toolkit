#!/usr/bin/env bash

# ASDD 2.0: disabled optional hooks do not prompt, block, or mutate.
if ! source "${BASH_SOURCE[0]%/*}/asdd-hook-gate.sh"; then
  echo 'ff-dev-toolkit: ASDD Hook helper is unavailable; optional hook skipped' >&2
  exit 0
fi
asdd_hook_enabled hooks || exit 0
#
# 起票ラベル契約ガード（PreToolUse / Bash）。
#
# `out-of-scope-issue` / `create-issue` の verify-then-skip 契約（実在確認のうえ
# 種別 / 優先度 / `follow-up` を付与する）は SKILL.md に書かれた**手順**であり、
# 素の `gh issue create` を直接叩いた瞬間に丸ごと迂回される。迂回は外から見えず、
# backlog 側で「発生源が PR レビュー由来か」「優先度は何か」が失われる。本ガードは
# その迂回を起票の直前に機械で捕まえる。
#
# ── 二段の設計（非対称を潰さない）──────────────────────────────────────────
#   A) 種別（type）/ 優先度（priority）の欠落は**違反**として止める。
#      どちらの起票スキルでも必須なので、`--label` に 1 つも該当が無い起票は
#      経路によらず契約違反である。片系統だけの充足を「充足」と読まない
#      （type はあるが priority が無い形も止める）。
#   B) `follow-up` の欠落は止めない。起票が PR レビュー・実装由来かどうかは
#      コマンド文字列から機械的に読めず、`create-issue` は意図的に付けない
#      （着手前の起票ゲートであって派生発見の記録ではない）。一律に違反とすると
#      正しい起票まで止まるため、**表示のみの案内**（systemMessage）に留める。
#
# A を「抜け道付き deny」にするのは、PreToolUse に「実行を許しつつエージェントへ
# 警告文を見せる」チャネルが無いため（既存 3 ガードと同じ判断）。抜け道は deny の
# 文面自体に案内する。B が systemMessage なのは、止めるコストのほうが大きい側
# （利用者向け表示チャネルでエージェントのコンテキストには入らない、という制約は
# `guard-background-cwd.sh` と同じで、承知のうえで表示のみに留める）。
#
# ── ラベル名の正本 ────────────────────────────────────────────────────────
# **本ファイルはラベル名を列挙しない。** 実行時に
# `skills/setup-github-labels/SKILL.md` の軸別表（推奨ラベル構成の正本で、
# `tests/github-labels-setup/verify.sh` が抽出正規表現で他 4 箇所と照合している）を
# 読み、軸ごとに引く。抽出できなければ無音で通す（fail-open）。
#
# 種別（type）は**許可名簿を持たない**。起票スキル側が「具体的なラベル名は消費
# プロジェクトの分類に合わせる（代表例であり、この名前でなければならないという
# 意味ではない）」と定めているため、閉じた許可名簿を hook が持つと消費側の分類を
# 誤って違反にする。代わりに「バージョニング / 緊急度 / 優先度 / `follow-up` /
# 否定名簿の**いずれでもない**ラベルが 1 つでもあれば種別は充足」と判定する。
# 取りこぼす側（分類外のラベルを種別と読む）へ倒れるが、誤ブロックはしない。
#
# 否定名簿だけは持つ。GitHub デフォルトで在る非種別ラベル（重複・質問・対応しない
# など）まで種別として充足させると、否定形判定が素通しの箱になるため。名前は
# ここにも書かず、既存の正本 2 つ（docs-template のデフォルトラベル表 −
# `skills/create-issue/SKILL.md` 手順 5 の type 行）の差分から実行時に引く。
# 残る穴は「未知の名前空間ラベル（`area:*` など）1 個での種別充足」で、これは
# 消費プロジェクト固有の種別名を誤ブロックしないための意図的な穴。suite が現状を
# 固定しているので、後で締めたときに差分が見える。
#
# ── ラベル一覧を信用できないときは止めない ─────────────────────────────────
# 止める前に `gh label list` で**対象リポジトリに当該系統のラベルが実在するか**を
# 確かめる。照会失敗 / 空の出力 / 取得上限到達のいずれかなら「不在」と断定せず
# 素通しする（両 SKILL の「照会失敗」の扱いと同一）。存在しないラベル名を要求すると
# 起票そのものを不能にするため。
#
# ── 判定の流れ ────────────────────────────────────────────────────────────
#   0. tool_name が Bash（それ以外は無音）
#   1. heredoc 本文（`<<` / `<<-` のトークン以降、終端行まで）を落とし、行末 `\` の
#      行継続を次行と連結する。`cat <<'EOF' > note.md` の本文に `gh issue create ...`
#      と書いただけでは発火しない。終端行の直後に続く実コマンドは落とさない
#   2. **引用符の外**の連結演算子で分割し、**コマンド位置**の `gh issue create` を持つ
#      セグメントだけを対象にする（`echo 'gh issue create ...'` では発火しない）
#   3. セグメントを引用符を解いてトークン化し、`--label` / `-l`（`=` 形・カンマ区切りを
#      含む）を集める
#   4. 軸別表から系統を引き、欠落系統を出す
#   5. 欠落系統が対象リポジトリに実在するときだけ止める / 案内する
#
# 既知の限界（判定できず素通しする形）:
#   - `--label` を変数展開・コマンド置換で組み立てる形
#   - `gh issue create` を経ない起票（API 直叩き・Web UI）
#   - 未知の名前空間ラベル（`area:*` など）1 個での種別充足（意図的な穴。上記参照）
#
# 設計原則:
#   - fail-open: 全 Bash 呼び出しに割り込むため、解析不能・jq/gh 不在・抽出失敗では
#     黙って許可（exit 0・無出力）へ倒す
#   - 互換性: bash 3.2（stock macOS）互換。連想配列・readarray・=~ は使わない
#
# 環境変数:
#   FF_DEV_TOOLKIT_SKIP_ISSUE_LABEL_GUARD=1  このガードを無効化する。対象コマンド先頭の
#                                            環境代入としても効く（案内する抜け道）

# fail-open のため set -e / set -u は使わない。

# stdin は bash 組み込みの read で読み切る（外部コマンドに依存しない）。`cat` だと PATH が
# 空・壊れた環境で command not found → stdin 未読のまま exit 0 となり、書き手（ホスト）が
# EPIPE / SIGPIPE を受ける（既存ガードと同じ修正）。opt-out も stdin を読み切ってから
# 抜ける。-d '' は EOF で非 0 を返すが input には内容が入っている。
input=""
IFS= read -r -d '' input || true

[ "${FF_DEV_TOOLKIT_SKIP_ISSUE_LABEL_GUARD:-0}" = "1" ] && exit 0

# 安価な前置フィルタ（jq を起動する前に非該当を落とす）。語の連接ではなく 2 語の
# 共起で見るのは、`gh  issue  create` のような空白の揺れで取りこぼさないため。
case "$input" in
  *issue*) : ;;
  *) exit 0 ;;
esac
case "$input" in
  *create*) : ;;
  *) exit 0 ;;
esac

# jq / gh のどちらかが無ければ判定材料を作れない。stdin は上で読み切ってある。
command -v jq >/dev/null 2>&1 || exit 0
command -v gh >/dev/null 2>&1 || exit 0

tool="$(printf '%s' "$input" | jq -r '.tool_name // ""' 2>/dev/null)" || exit 0
[ "$tool" = "Bash" ] || exit 0

cmd="$(printf '%s' "$input" | jq -r '.tool_input.command // ""' 2>/dev/null)" || exit 0
[ -n "$cmd" ] || exit 0
case "$cmd" in
  *issue*) : ;;
  *) exit 0 ;;
esac
case "$cmd" in
  *create*) : ;;
  *) exit 0 ;;
esac

CWD="$(printf '%s' "$input" | jq -r '.cwd // ""' 2>/dev/null)"
[ -d "$CWD" ] || CWD="$(pwd)"

SKILL_MD="${BASH_SOURCE[0]%/*}/../skills/setup-github-labels/SKILL.md"
[ -f "$SKILL_MD" ] || exit 0

# 種別の否定名簿を作るための正本 2 つ（どちらも既存。hook 内へ名前は持たない）。
# 読めなければ名簿は空のまま = 種別判定を緩める側へ倒す。
DEFAULTS_MD="${BASH_SOURCE[0]%/*}/../docs-template/05-operations/deployment/github-setup.md"
TYPE_EXAMPLES_MD="${BASH_SOURCE[0]%/*}/../skills/create-issue/SKILL.md"

strip_quotes() {
  local s="$1"
  case "$s" in
    \"*\")
      s="${s#\"}"
      s="${s%\"}"
      ;;
    \'*\')
      s="${s#\'}"
      s="${s%\'}"
      ;;
  esac
  printf '%s' "$s"
}

# 改行区切りリストに完全一致の行があるか
list_has() { # <list> <needle>
  [ -n "$2" ] || return 1
  printf '%s\n' "$1" | grep -Fxq -- "$2" 2>/dev/null
}

# ---- 1) heredoc 本文を落とす -------------------------------------------------
# heredoc 本文は「コマンドの並び」ではなくデータなので、判定対象から外す。
# 解析に失敗したら元のコマンドへ倒す（fail-open ではなく検出側だが、抜け道は
# deny 文に出る）。実装は `guard-review-in-flight.sh` と同型。
code_only="$(printf '%s\n' "$cmd" | awk '
  function trim(s) { sub(/^[ \t]+/, "", s); sub(/[ \t]+$/, "", s); return s }
  # 行末に連なるバックスラッシュの数（奇数なら行継続、偶数ならエスケープ済みの `\`）
  function tailbs(s,   i, c) {
    c = 0
    for (i = length(s); i >= 1; i--) {
      if (substr(s, i, 1) == "\\") c++
      else break
    }
    return c
  }
  BEGIN {
    q = sprintf("%c", 39)
    re = "<<-?[ \t]*(\"[^\"]*\"|" q "[^" q "]*" q "|[A-Za-z_][A-Za-z0-9_]*)"
    nd = 0
    pend = ""
  }
  {
    if (nd > 0) {
      if (trim($0) == d[1]) { for (i = 1; i < nd; i++) d[i] = d[i + 1]; nd-- }
      next
    }
    scan = $0
    gsub(/<<</, "___", scan) # here-string は heredoc ではない（長さを保つ置換）
    pos = 1
    while (match(substr(scan, pos), re)) {
      st = pos + RSTART - 1
      tok = substr(scan, st, RLENGTH)
      sub(/^<<-?[ \t]*/, "", tok)
      gsub("[\"" q "]", "", tok)
      nd++
      d[nd] = tok
      pos = st + RLENGTH
    }
    # 行末 `\` は行継続。シェルと同じく `\` + 改行を丸ごと取り除いて次行へ連結する。
    # 両起票スキルの起票テンプレートは `--label` を継続行へ置くので、ここで繋がないと
    # 先頭行のトークンしか見えず、契約どおりラベルを付けた起票を止めてしまう。
    if (tailbs($0) % 2 == 1) {
      pend = pend substr($0, 1, length($0) - 1)
      next
    }
    print pend $0
    pend = ""
  }
  END { if (pend != "") print pend }
' 2>/dev/null)" || code_only="$cmd"
[ -n "$code_only" ] || exit 0
case "$code_only" in
  *issue*) : ;;
  *) exit 0 ;;
esac
case "$code_only" in
  *create*) : ;;
  *) exit 0 ;;
esac

# ---- 2) コマンド位置の `gh issue create` セグメントを特定する -----------------
GH_FOUND=0
GH_TOKS=()
INLINE_OVERRIDE=0

scan_segment() {
  local toks=("$@")
  local n=${#toks[@]} i=0 t seg_override=0
  while [ "$i" -lt "$n" ]; do
    t="$(strip_quotes "${toks[$i]}")"
    case "$t" in
      FF_DEV_TOOLKIT_SKIP_ISSUE_LABEL_GUARD=1)
        seg_override=1
        i=$((i + 1))
        ;;
      [A-Za-z_]*=*) i=$((i + 1)) ;;
      env | command | sudo | nohup) i=$((i + 1)) ;;
      *) break ;;
    esac
  done
  [ "$i" -lt "$n" ] || return 0
  case "$(strip_quotes "${toks[$i]}")" in
    gh | */gh) : ;;
    *) return 0 ;;
  esac
  [ $((i + 2)) -lt "$n" ] || return 0
  [ "$(strip_quotes "${toks[$((i + 1))]}")" = "issue" ] || return 0
  [ "$(strip_quotes "${toks[$((i + 2))]}")" = "create" ] || return 0
  GH_FOUND=1
  INLINE_OVERRIDE="$seg_override"
  GH_TOKS=("${toks[@]:$i}")
  return 0
}

# セグメントを引用符を解いたトークン列へ割る（結果は配列 TOKS）。素朴な空白分割では
# `--label "good first issue"` が 3 片に割れ、断片が種別として読まれてしまう。
TOKS=()
tokenize_segment() { # <segment>
  local raw t
  TOKS=()
  raw="$(printf '%s\n' "$1" | awk '
    BEGIN { q = sprintf("%c", 39) }
    {
      line = $0
      n = length(line)
      i = 1
      tok = ""
      has = 0
      while (i <= n) {
        c = substr(line, i, 1)
        if (c == " " || c == "\t") {
          if (has) { print tok; tok = ""; has = 0 }
          i++
          continue
        }
        has = 1
        if (c == q) { # 単一引用符の中はエスケープが効かない
          i++
          while (i <= n && substr(line, i, 1) != q) { tok = tok substr(line, i, 1); i++ }
          i++
          continue
        }
        if (c == "\"") { # 二重引用符の中で `\` が効くのは 4 文字だけ
          i++
          while (i <= n && substr(line, i, 1) != "\"") {
            if (substr(line, i, 1) == "\\" && i < n && index("$`\"\\", substr(line, i + 1, 1)) > 0) i++
            tok = tok substr(line, i, 1)
            i++
          }
          i++
          continue
        }
        if (c == "\\" && i < n) { i++; tok = tok substr(line, i, 1); i++; continue }
        tok = tok c
        i++
      }
      if (has) print tok
    }
  ' 2>/dev/null)" || raw=""
  if [ -z "$raw" ]; then
    # 解析できなければ素朴な空白分割へ戻す（判定材料をまるごと失わない側）
    set -f
    # shellcheck disable=SC2206 # 退避経路の空白トークン化（glob は set -f で抑止）
    TOKS=($1)
    set +f
    return 0
  fi
  while IFS= read -r t; do
    TOKS+=("$t")
  done <<TOKEOF
$raw
TOKEOF
}

# 連結演算子での分割は**引用符の外**だけで行う。既存の Bash ガード 2 本は素朴な
# gsub で足りるが、あちらは「本文に何かが在る」が発火条件なので取りこぼしは
# fail-open へ倒れる。本ガードは「ラベルが無い」が発火条件なので、同じ近道は
# `--title "A | B"` / `--body "a; b"` を誤 deny する fail-closed へ反転する。
segments="$(printf '%s\n' "$code_only" | awk '
  BEGIN { q = sprintf("%c", 39); sq = 0; dq = 0; out = "" }
  {
    line = $0
    n = length(line)
    i = 1
    while (i <= n) {
      c = substr(line, i, 1)
      if (sq) {
        if (c == q) sq = 0
        out = out c; i++; continue
      }
      if (dq) {
        if (c == "\\" && i < n) { out = out c substr(line, i + 1, 1); i += 2; continue }
        if (c == "\"") dq = 0
        out = out c; i++; continue
      }
      if (c == "\\" && i < n) { out = out c substr(line, i + 1, 1); i += 2; continue }
      if (c == q) { sq = 1; out = out c; i++; continue }
      if (c == "\"") { dq = 1; out = out c; i++; continue }
      if (c == ";") { out = out "\n"; i++; continue }
      if (c == "&" && substr(line, i + 1, 1) == "&") { out = out "\n"; i += 2; continue }
      if (c == "|") {
        if (substr(line, i + 1, 1) == "|") { out = out "\n"; i += 2; continue }
        out = out "\n"; i++; continue
      }
      out = out c; i++
    }
    # 引用符の中で行が終わったら改行は文字列の一部。セグメントを割らず空白へ潰す
    out = out ((sq || dq) ? " " : "\n")
  }
  END { printf "%s", out }
' 2>/dev/null)" || segments="$(printf '%s\n' "$code_only" | awk '{ gsub(/&&|\|\||;|\|/, "\n"); print }' 2>/dev/null)"

while IFS= read -r seg; do
  [ -n "$seg" ] || continue
  case "$seg" in
    *gh*) : ;;
    *) continue ;;
  esac
  [ "$GH_FOUND" -eq 1 ] && continue
  tokenize_segment "$seg"
  scan_segment "${TOKS[@]}"
done <<EOF
$segments
EOF

[ "$GH_FOUND" -eq 1 ] || exit 0
# 案内した抜け道（対象コマンド先頭の環境代入）を明示的に使った起票は止めない
[ "$INLINE_OVERRIDE" -eq 1 ] && exit 0

# ---- 3) `--label` の値と `--repo` を集める -----------------------------------
given_labels=""
repo_arg=""
n=${#GH_TOKS[@]}
i=0
while [ "$i" -lt "$n" ]; do
  t="$(strip_quotes "${GH_TOKS[$i]}")"
  val=""
  case "$t" in
    --label | -l)
      i=$((i + 1))
      [ "$i" -lt "$n" ] && val="$(strip_quotes "${GH_TOKS[$i]}")"
      ;;
    --label=*) val="$(strip_quotes "${t#--label=}")" ;;
    --repo | -R)
      i=$((i + 1))
      [ "$i" -lt "$n" ] && repo_arg="$(strip_quotes "${GH_TOKS[$i]}")"
      ;;
    --repo=*) repo_arg="$(strip_quotes "${t#--repo=}")" ;;
  esac
  if [ -n "$val" ]; then
    # `--label "bug,priority:high"` のカンマ区切りを展開する
    given_labels="${given_labels}$(printf '%s' "$val" | tr ',' '\n')
"
  fi
  i=$((i + 1))
done
given_labels="$(printf '%s' "$given_labels" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' | grep -v '^$' 2>/dev/null)"

# ---- 4) 軸別表（正本）から系統を引く ------------------------------------------
# `tests/github-labels-setup/verify.sh` の extract_skill_axis_names と同じ表・同じ
# トークン文法にスコープし、軸（行頭セル）で絞り込む点だけを足している。
extract_axis_labels() { # <軸名>
  awk -v want="$1" '
    /^\|[[:space:]]*軸[[:space:]]*\|/ { on = 1; next }
    on && !/^\|/ { on = 0 }
    on {
      row = $0
      sub(/^\|/, "", row)
      idx = index(row, "|")
      if (idx == 0) next
      axis = substr(row, 1, idx - 1)
      sub(/^[ \t]+/, "", axis)
      sub(/[ \t]+$/, "", axis)
      if (axis != want) next
      rest = substr(row, idx + 1)
      while (match(rest, /`[^`]+`/)) {
        tok = substr(rest, RSTART + 1, RLENGTH - 2)
        rest = substr(rest, RSTART + RLENGTH)
        if (tok ~ /^[a-z][a-z0-9:-]*$/) print tok
      }
    }
  ' "$SKILL_MD" 2>/dev/null
}

PRIORITY_NAMES="$(extract_axis_labels '優先度')"
VERSIONING_NAMES="$(extract_axis_labels 'バージョニング')"
URGENCY_NAMES="$(extract_axis_labels '緊急度')"
CLASSIFY_NAMES="$(extract_axis_labels '分類の補完')"

# 正本を読めなければ何も主張しない（名前を hook 内へ持たないので代替が無い）
[ -n "$PRIORITY_NAMES" ] || exit 0
[ -n "$CLASSIFY_NAMES" ] || exit 0

# 優先度の名前空間接頭辞も正本から導く（消費プロジェクト固有の `priority:*` を
# 「優先度あり」と読むための緩い網。厳格照合と二段構えにする）。
PRIORITY_PREFIX=""
first_priority="$(printf '%s\n' "$PRIORITY_NAMES" | head -1)"
case "$first_priority" in
  *:*) PRIORITY_PREFIX="${first_priority%%:*}:" ;;
esac

# `follow-up` は名前を書かず、分類の補完 軸から**選ぶ**（正本を 1 つに保つ）。
FOLLOWUP_NAME="$(printf '%s\n' "$CLASSIFY_NAMES" | grep -Ex 'follow[-_]?up' 2>/dev/null | head -1)"

# ---- 4b) 種別の否定名簿（GitHub デフォルトのうち種別でないもの）----------------
# 否定形判定（他の軸でなければ種別）は `wontfix` / `question` のような GitHub
# デフォルトラベルまで種別として充足させてしまう。名前は hook に持たず、既存の
# 正本 2 つの差分から実行時に引く:
#   (1) docs-template の「GitHubデフォルトラベル（そのまま使用）」表 = 既定で在る名前
#   (2) create-issue の手順 5 type 行 = そのうち種別として使う名前
# (1) − (2) が「既定で在るが種別ではない」名前。どちらかが抽出できなければ名簿は
# 空のまま（種別判定を緩める側 = 誤ブロックしない側）へ倒す。
extract_default_label_names() {
  [ -f "$DEFAULTS_MD" ] || return 0
  awk '
    /^#### / { on = ($0 ~ /デフォルトラベル/) ? 1 : 0; next }
    on && /^[[:space:]]*$/ { next }
    on && !/^\|/ { on = 0; next }
    on {
      line = $0
      while (match(line, /`[^`]+`/)) {
        tok = substr(line, RSTART + 1, RLENGTH - 2)
        line = substr(line, RSTART + RLENGTH)
        if (tok ~ /^[a-z][a-z0-9 _:-]*$/) { print tok; break } # 行頭セル（ラベル名）だけ
      }
    }
  ' "$DEFAULTS_MD" 2>/dev/null
}

extract_type_example_names() {
  [ -f "$TYPE_EXAMPLES_MD" ] || return 0
  awk '
    /^### / { insec = ($0 ~ /ラベルの決定/) ? 1 : 0 }
    insec && /^\|[[:space:]]*type[[:space:]]*\|/ {
      line = $0
      while (match(line, /`[^`]+`/)) {
        tok = substr(line, RSTART + 1, RLENGTH - 2)
        line = substr(line, RSTART + RLENGTH)
        # conventional-commit プレフィックス（末尾 `:`）はラベル名ではない
        if (tok ~ /^[a-z][a-z0-9_-]*$/) print tok
      }
    }
  ' "$TYPE_EXAMPLES_MD" 2>/dev/null
}

NON_TYPE_DEFAULTS=""
default_names="$(extract_default_label_names)"
type_example_names="$(extract_type_example_names)"
if [ -n "$default_names" ] && [ -n "$type_example_names" ]; then
  while IFS= read -r dn; do
    [ -n "$dn" ] || continue
    list_has "$type_example_names" "$dn" && continue
    NON_TYPE_DEFAULTS="${NON_TYPE_DEFAULTS}${dn}
"
  done <<EOF
$default_names
EOF
fi

is_priority_label() { # <name>
  [ -n "$1" ] || return 1
  list_has "$PRIORITY_NAMES" "$1" && return 0
  if [ -n "$PRIORITY_PREFIX" ]; then
    case "$1" in
      "$PRIORITY_PREFIX"?*) return 0 ;;
    esac
  fi
  return 1
}

# 種別は許可名簿を持たない: 他の 3 軸・follow-up・否定名簿の**いずれでもない**なら
# 種別とみなす。引用符を含むトークンはトークン化に失敗した断片なので候補にしない
# （空白を含むだけのトークンは `good first issue` のような正規のラベル名なので除かない）。
is_type_label() { # <name>
  [ -n "$1" ] || return 1
  case "$1" in
    *[\"\']*) return 1 ;;
  esac
  is_priority_label "$1" && return 1
  list_has "$VERSIONING_NAMES" "$1" && return 1
  list_has "$URGENCY_NAMES" "$1" && return 1
  list_has "$NON_TYPE_DEFAULTS" "$1" && return 1
  [ -n "$FOLLOWUP_NAME" ] && [ "$1" = "$FOLLOWUP_NAME" ] && return 1
  return 0
}

has_type=0
has_priority=0
has_followup=0
while IFS= read -r lb; do
  [ -n "$lb" ] || continue
  is_priority_label "$lb" && has_priority=1
  is_type_label "$lb" && has_type=1
  [ -n "$FOLLOWUP_NAME" ] && [ "$lb" = "$FOLLOWUP_NAME" ] && has_followup=1
done <<EOF
$given_labels
EOF

if [ "$has_type" -eq 1 ] && [ "$has_priority" -eq 1 ] && [ "$has_followup" -eq 1 ]; then
  exit 0
fi

# ---- 5) 対象リポジトリのラベル実在確認（信用できなければ止めない）-------------
LABEL_LIMIT=200
if [ -n "$repo_arg" ]; then
  repo_labels="$(gh label list --repo "$repo_arg" --limit "$LABEL_LIMIT" --json name --jq '.[].name' 2>/dev/null)" || exit 0
else
  repo_labels="$(cd "$CWD" 2>/dev/null && gh label list --limit "$LABEL_LIMIT" --json name --jq '.[].name' 2>/dev/null)" || exit 0
fi
# 空の出力（1 件も無いリポジトリと絞り込み不発を区別できない）と上限到達
# （その先にあるラベルの不在を主張できない）は「照会失敗」として扱う。
#
# **空の行は冗長な二重防御**: この行を削っても後段で `*_available` が全部 0 になり
# 結果は一致する（単独変異で suite は緑のまま = 振る舞いでは検出できない）。それでも
# 残すのは、両 SKILL.md が「失敗 / 空 / 上限到達」の 3 条件を並べて定めており、
# コード側でも 3 条件を並べて書いておかないと後段の実装を変えたときに「空」の扱いだけ
# 静かに落ちるため。suite の当該ラベルも「回帰の針ではない」と明記してある。
[ -n "$repo_labels" ] || exit 0
label_count="$(printf '%s\n' "$repo_labels" | grep -c '' 2>/dev/null)" || exit 0
[ "$label_count" -lt "$LABEL_LIMIT" ] || exit 0

priority_available=0
type_available=0
followup_available=0
type_example=""
priority_example=""
while IFS= read -r lb; do
  [ -n "$lb" ] || continue
  if is_priority_label "$lb"; then
    priority_available=1
    [ -n "$priority_example" ] || priority_example="$lb"
  elif is_type_label "$lb"; then
    type_available=1
    [ -n "$type_example" ] || type_example="$lb"
  fi
  [ -n "$FOLLOWUP_NAME" ] && [ "$lb" = "$FOLLOWUP_NAME" ] && followup_available=1
done <<EOF
$repo_labels
EOF

missing=""
add_missing() { missing="${missing:+$missing / }$1"; }
[ "$has_type" -eq 0 ] && [ "$type_available" -eq 1 ] && add_missing "種別（例: ${type_example}）"
[ "$has_priority" -eq 0 ] && [ "$priority_available" -eq 1 ] && add_missing "優先度（例: ${priority_example}）"

if [ -n "$missing" ]; then
  reason="⚠️ ff-dev-toolkit guard（起票ラベル契約・警告）: gh issue create に付ける --label に、次の系統が見つかりません: ${missing}
無ラベルの Issue は backlog 一覧で種別も優先度も読めず、「今どれを拾うべきか」を Issue を 1 件ずつ開かないと判断できなくなります。次のいずれかで再実行してください:
  1) 起票スキル経由にする（PR レビュー・実装から派生した発見なら /out-of-scope-issue、着手前の起票なら /create-issue。どちらも実在確認のうえラベルを付けます）
  2) 上の系統を --label で足す（対象リポジトリで実在を確認済みの例を上に添えています）
  3) 意図的にラベル無しで起票する場合は FF_DEV_TOOLKIT_SKIP_ISSUE_LABEL_GUARD=1 を先頭に置いて再実行する
このガード自体を止める場合も環境変数 FF_DEV_TOOLKIT_SKIP_ISSUE_LABEL_GUARD=1 を設定します。"
  jq -n --arg reason "$reason" \
    '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "deny", permissionDecisionReason: $reason}}' 2>/dev/null
  exit 0
fi

# follow-up は機械的に判定できないので止めない（表示のみの案内）。
if [ "$has_followup" -eq 0 ] && [ "$followup_available" -eq 1 ]; then
  # 文面で種別 / 優先度の充足を主張しない。ここへ来る経路には「付いている」場合と
  # 「対象リポジトリにその系統が実在せず要求しなかった」場合の両方がある。
  jq -n --arg m "ℹ️ ff-dev-toolkit guard（起票ラベル契約）: この起票が PR レビュー・実装から派生した発見なら、--label ${FOLLOWUP_NAME} も付けてください（out-of-scope-issue の契約）。着手前の起票（create-issue 相当）なら不要です。" \
    '{systemMessage: $m}' 2>/dev/null
  exit 0
fi

exit 0
