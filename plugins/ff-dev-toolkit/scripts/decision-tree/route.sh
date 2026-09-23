#!/usr/bin/env bash
#
# route.sh — 決定木 v0 のルータ（根の経路分岐 fast / full / none）と、木データの静的検査。
#
# 使い方:
#   route.sh [--git [--base <ref>]]                    … 差分から判定（既定。cwd の git リポジトリ）
#   route.sh --files <path> [<path> ...]               … 渡した path 一覧で判定
#   route.sh --files-from <file|->  [--lines <n>]      … 1 行 1 path（`-` は stdin）。--lines は変更行数
#   route.sh --issue-body <file>                       … Issue 本文（FF_JEV_MODE=on の state に載せる）
#   route.sh --check                                   … 木データの静的検査（到達性 suite が呼ぶ）
#   route.sh --leaves                                  … 葉の一覧（kind <tab> name <tab> target）
#   route.sh --walk <答え> [<答え> ...]                … root から答えを順に辿って行き先を出す
#   共通: --tree <file>（既定 同ディレクトリの tree.tsv）/ --plugin-root <dir> / --jev-decide <path>
#
# 何のためにあるか:
#   27 スキル + 16 hook の「いつ何が走るか」を散文ではなく木データ（tree.tsv）に置き、根だけを
#   機械判定する。根の出力（fast / full / none）はレビュー経路の bundle が読む契約で、
#   下記の出力プロトコルを変えるときはそちらも追随する。LLM を経由せず bash + awk だけで
#   ミリ秒で返り、UserPromptSubmit hook（hooks/decision-tree.sh）から呼ばれる。
#
# 根の規則（FF_JEV_MODE=off の既定。tree.tsv の `rule root` 3 行が値を持つ）:
#   評価順は固定。上から最初に当たったものを採る。
#   1. none  … 判定材料（変更ファイル）が 0 件（no-files）
#   2. full  … contract-path のパターンに当たる path を 1 つでも含む（contract-change）
#   3. fast  … 全 path が docs-glob のパターンに当たる（docs-only）
#   4. fast  … 変更行数（追加 + 削除）が fast-max-lines 以下（small-diff）。行数が取れない回は当たらない
#   5. full  … 上記以外（implementation）
#   パターンは bash の glob（`case` の pattern。`*` は `/` にも当たる）で、空白区切り。
#   off では Jev を呼ばず記録も書かない — 既存の発火（SKILL.md の description・hook の matcher）
#   に対して何も足さないのが契約で、ルータ自身は経路を出力するだけで発火を変えない。
#
# FF_JEV_MODE=on（ADR-059 の二段構え。判定点名 `route`）:
#   choice 型のノード（v0 では root だけ）は先に jev-decide.sh へ criteria（scripts/jev/questions/
#   <ノード id>.json。答えの集合と同じ option を持つことを --check が固定する）と state（変更ファイル
#   一覧・行数・Issue 本文）を渡す。exit 0（confidence ≥ 閾値）のときだけその答えを採り、
#   exit 10（閾値未満）/ 11（Jev の失敗）は `none`（ホスト判定へ）、exit 12（判定点が名簿に無い
#   = FF_JEV_POINTS に `route` が無い）は off と同じ規則判定へ落ちる。入力不正（exit 2 / 64 / 69）は
#   none を出して exit 2 で止める（従来経路へ黙って落とさない）。Choice の閾値は jev-decide.sh の
#   共通既定（0.99）で、判定点別の上書きは FF_JEV_MIN_CONFIDENCE の判定点別形（jev-decide.sh のヘッダ。
#   判定点名 route の大文字を後置する）。
#
# 出力プロトコル（stdout。行頭一致で機械可読。**契約**）:
#   DT_ROUTE=fast|full|none          … 根の答え（none はホスト判定へ）
#   DT_REASON=<理由>                 … no-files / contract-change:<path> / docs-only / small-diff /
#                                      implementation / jev-adopt / jev-low-confidence /
#                                      jev-fallback:<種別> / error:<内容>
#   DT_SOURCE=rules|jev|none         … 何が決めたか（none は判定していない）
#   DT_FILES=<n>                     … 判定に使った path 件数
#   DT_LINES=<n|->                   … 変更行数（取れなければ `-`）
#   DT_TARGET=node:fast|node:full|none … 根の答えの行き先（木の次ノード）
#   終了コード: 0 = 判定した（none を含む） / 2 = 判定不能（木データ・Jev 入力の不正、git の失敗）
#   / 64 = 使い方の誤り。--check は 0 = 違反なし / 1 = 違反あり / 2 = 検査不能。
#
# 制約: bash 3.2 互換（連想配列・mapfile 禁止）。外部コマンドは awk・grep・sort・git（--git のみ）・
#       jq（--check の choice fixture 照合と FF_JEV_MODE=on の応答解釈だけ。off の経路は jq に触れない）。
set -uo pipefail

SCRIPT_DIR="$(CDPATH= cd -P -- "$(dirname "$0")" && pwd -P)"
PLUGIN_ROOT_DEFAULT="$(CDPATH= cd -P -- "$SCRIPT_DIR/../.." && pwd -P)"
TREE="$SCRIPT_DIR/tree.tsv"
PLUGIN_ROOT="$PLUGIN_ROOT_DEFAULT"
JEV_DECIDE=""
MAX_DEPTH=4
MAX_LEAVES=50

MODE="route"
FILES_FROM=""
FILE_ARGS=()
USE_GIT=0
BASE=""
LINES="-"
ISSUE_BODY=""
WALK_ARGS=()

usage() {
  sed -n '2,/^set -uo pipefail/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'
}
die_usage() { echo "✗ route: $1" >&2; usage >&2; exit 64; }

emit_route() { # $1=route $2=reason $3=source $4=files $5=lines
  local target="none"
  case "$1" in
    fast) target="node:fast" ;;
    full) target="node:full" ;;
  esac
  echo "DT_ROUTE=$1"
  echo "DT_REASON=$2"
  echo "DT_SOURCE=$3"
  echo "DT_FILES=$4"
  echo "DT_LINES=$5"
  echo "DT_TARGET=${target}"
}
# 判定不能は none を出したうえで exit 2（DT_ROUTE= 行を出さない形にしない — 読む側が
# 「行が無い = 判定していない」と「none」を区別できる）。
undecidable() { # $1=理由 $2=files $3=lines
  emit_route none "error:$1" none "${2:-0}" "${3:--}"
  echo "✗ route: $1" >&2
  exit 2
}

while [ $# -gt 0 ]; do
  case "$1" in
    --check) MODE="check"; shift ;;
    --leaves) MODE="leaves"; shift ;;
    --walk) MODE="walk"; shift; while [ $# -gt 0 ]; do case "$1" in --*) break ;; esac; WALK_ARGS+=("$1"); shift; done ;;
    --git) USE_GIT=1; shift ;;
    --base) [ $# -ge 2 ] || die_usage "--base に値がありません"; BASE="$2"; shift 2 ;;
    --files) shift; while [ $# -gt 0 ]; do case "$1" in --*) break ;; esac; FILE_ARGS+=("$1"); shift; done ;;
    --files-from) [ $# -ge 2 ] || die_usage "--files-from に値がありません"; FILES_FROM="$2"; shift 2 ;;
    --lines) [ $# -ge 2 ] || die_usage "--lines に値がありません"; LINES="$2"; shift 2 ;;
    --issue-body) [ $# -ge 2 ] || die_usage "--issue-body に値がありません"; ISSUE_BODY="$2"; shift 2 ;;
    --tree) [ $# -ge 2 ] || die_usage "--tree に値がありません"; TREE="$2"; shift 2 ;;
    --plugin-root) [ $# -ge 2 ] || die_usage "--plugin-root に値がありません"; PLUGIN_ROOT="$2"; shift 2 ;;
    --jev-decide) [ $# -ge 2 ] || die_usage "--jev-decide に値がありません"; JEV_DECIDE="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) die_usage "不明な引数: $1" ;;
  esac
done
[ -n "$JEV_DECIDE" ] || JEV_DECIDE="$PLUGIN_ROOT/scripts/jev/jev-decide.sh"

# ---- 木データの読み込み（共通）-------------------------------------------------------
# 木は 1 回 awk で正規化して `TYPE<TAB>...` の行列に落とし、以後の処理はこの行列だけを読む。
# 書式違反（フィールド数・未知の行種）はここで名指しし、black-box に「0 ノード」へ倒さない。
tree_is_readable() {
  [ -n "$TREE" ] && [ -f "$TREE" ] && [ -r "$TREE" ] && [ -s "$TREE" ]
}
tree_rows() { # 正規化行: node<TAB>id<TAB>kind<TAB>question / answer<TAB>node<TAB>ans<TAB>target / rule<TAB>node<TAB>key<TAB>value / BAD<TAB>行番号<TAB>理由
  awk -F'\t' '
    /^[[:space:]]*#/ { next }
    /^[[:space:]]*$/ { next }
    {
      if (NF != 4) { print "BAD\t" NR "\tフィールド数が 4 ではありません（" NF "）"; next }
      if ($1 != "node" && $1 != "answer" && $1 != "rule") { print "BAD\t" NR "\t未知の行種: " $1; next }
      print $1 "\t" $2 "\t" $3 "\t" $4
    }
  ' "$TREE"
}

# ---- --check: 静的検査 ---------------------------------------------------------------
check_tree() {
  local rows bad n_violations=0 line
  local nl='
'
  local skills_dir="$PLUGIN_ROOT/skills" hooks_dir="$PLUGIN_ROOT/hooks" hooks_json="$PLUGIN_ROOT/hooks/hooks.json"
  if ! tree_is_readable; then
    echo "✗ route --check: 木データを読めません（不在・空・読み取り不可）: ${TREE}" >&2
    return 2
  fi
  command -v jq >/dev/null 2>&1 || { echo "✗ route --check: jq が必要です（choice fixture の照合）" >&2; return 2; }
  [ -f "$hooks_json" ] || { echo "✗ route --check: hooks.json がありません: ${hooks_json}" >&2; return 2; }
  rows="$(tree_rows)" || { echo "✗ route --check: 木データの正規化に失敗しました" >&2; return 2; }
  [ -n "$rows" ] || { echo "✗ route --check: 木データに行が 1 つもありません（コメント・空行だけ）: ${TREE}" >&2; return 2; }

  # 構造検査（awk 1 本）。違反は 1 行 1 件で stdout へ。END で SUMMARY 行を出す。
  local structural
  structural="$(printf '%s\n' "$rows" | awk -F'\t' -v max_depth="$MAX_DEPTH" -v max_leaves="$MAX_LEAVES" '
    $1 == "BAD" { print "違反: L" $2 " " $3; bad++; next }
    $1 == "node" {
      id = $2
      if (id !~ /^[a-z][a-z0-9-]*$/) { print "違反: node の id が英小文字・数字・- ではありません: " id; bad++ }
      if (id in kind) { print "違反: node の id が重複しています: " id; bad++ }
      kind[id] = $3; question[id] = $4; norder[++nn] = id
      if ($3 != "choice" && $3 != "select") { print "違反: node " id " の kind が choice / select ではありません: " $3; bad++ }
      if ($4 == "") { print "違反: node " id " に問いがありません"; bad++ }
      next
    }
    $1 == "answer" {
      node = $2; ans = $3; tgt = $4
      key = node SUBSEP ans
      if (ans !~ /^[a-z][a-z0-9-]*$/) { print "違反: answer の答えが英小文字・数字・- ではありません: " node "/" ans; bad++ }
      if (key in target) { print "違反: node " node " の答え " ans " が重複しています"; bad++ }
      target[key] = tgt
      acount[node]++
      alist[node] = (node in alist) ? alist[node] "\n" ans : ans
      if (ans == "none") { nonecount[node]++; if (tgt != "none") { print "違反: node " node " の none の行き先が none ではありません: " tgt; bad++ } }
      else if (tgt == "none") { print "違反: node " node " の答え " ans " が none へ落ちています（none 以外の答えは葉かノードを指す）"; bad++ }
      else if (tgt !~ /^(node:[a-z][a-z0-9-]*|skill:[a-z][a-z0-9-]*|hook:[a-z][a-z0-9-]*|doc:[^#]+#.+)$/) { print "違反: node " node " の答え " ans " の行き先の形が不正です: " tgt; bad++ }
      next
    }
    $1 == "rule" {
      # 同じ (node, key) の重複は赤 — 最後の行を採る検査と最初の行を採る判定が食い違うと、
      # 前に置いた行で判定を緩めたまま検査を通せる。キーは choice ノードの規則名簿に閉じる
      if (($2 SUBSEP $3) in rule) { print "違反: rule " $2 " / " $3 " が重複しています"; bad++ }
      if ($3 != "docs-glob" && $3 != "contract-path" && $3 != "fast-max-lines") { print "違反: rule " $2 " の未知のキー: " $3; bad++ }
      rule[$2 SUBSEP $3] = $4; rnode[$2]++; next
    }
    function walk(id, depth, path,   i, n, arr, ans, tgt, child) {
      if (depth > max_depth) { print "違反: node " id " が深さ " depth " で到達しています（上限 " max_depth "）: " path; bad++; return }
      if (id in onstack) { print "違反: 循環があります: " path " -> " id; bad++; return }
      onstack[id] = 1; reached[id] = 1
      n = split(alist[id], arr, "\n")
      for (i = 1; i <= n; i++) {
        ans = arr[i]; tgt = target[id SUBSEP ans]
        if (tgt == "none") continue
        if (tgt ~ /^node:/) {
          child = substr(tgt, 6)
          if (!(child in kind)) { print "違反: node " id " の答え " ans " が実在しないノードを指しています: " child; bad++; continue }
          walk(child, depth + 1, path "/" ans)
        } else {
          if (depth + 1 > max_depth) { print "違反: 葉 " tgt " が深さ " (depth + 1) " で到達しています（上限 " max_depth "）: " path "/" ans; bad++ }
          if (!(tgt in leaf)) { leaf[tgt] = 1; nleaves++ }
          if (depth + 1 > leafdepth[tgt]) leafdepth[tgt] = depth + 1
        }
      }
      delete onstack[id]
    }
    END {
      if (!("root" in kind)) { print "違反: root ノードがありません"; bad++ }
      else {
        if (kind["root"] != "choice") { print "違反: root の kind は choice でなければなりません: " kind["root"]; bad++ }
        # 根の出力契約（DT_ROUTE / DT_TARGET）は答えの集合と行き先を固定する
        if (!(("root" SUBSEP "fast") in target) || target["root" SUBSEP "fast"] != "node:fast") { print "違反: root の答え fast は node:fast を指さなければなりません"; bad++ }
        if (!(("root" SUBSEP "full") in target) || target["root" SUBSEP "full"] != "node:full") { print "違反: root の答え full は node:full を指さなければなりません"; bad++ }
        if (!(("root" SUBSEP "none") in target)) { print "違反: root に none がありません"; bad++ }
        if (acount["root"] != 3) { print "違反: root の答えは fast / full / none の 3 つに限ります（" acount["root"] + 0 " 件）"; bad++ }
      }
      for (i = 1; i <= nn; i++) {
        id = norder[i]
        if (!(id in acount)) { print "違反: node " id " に答えがありません"; bad++ }
        if (nonecount[id] != 1) { print "違反: node " id " の none がちょうど 1 本ではありません（" nonecount[id] + 0 " 本）"; bad++ }
        if (acount[id] - nonecount[id] < 1) { print "違反: node " id " に none 以外の答えがありません（問いになっていません）"; bad++ }
        if (kind[id] == "choice") {
          if (!((id SUBSEP "docs-glob") in rule)) { print "違反: choice node " id " に rule docs-glob がありません"; bad++ }
          if (!((id SUBSEP "contract-path") in rule)) { print "違反: choice node " id " に rule contract-path がありません"; bad++ }
          if (!((id SUBSEP "fast-max-lines") in rule)) { print "違反: choice node " id " に rule fast-max-lines がありません"; bad++ }
          else if (rule[id SUBSEP "fast-max-lines"] !~ /^[1-9][0-9]*$/) { print "違反: choice node " id " の fast-max-lines が正の整数ではありません: " rule[id SUBSEP "fast-max-lines"]; bad++ }
        }
      }
      for (id in rnode) if (!(id in kind)) { print "違反: rule が実在しないノードを指しています: " id; bad++ }
      for (n in acount) if (!(n in kind)) { print "違反: answer が実在しないノードを指しています: " n; bad++ }
      if ("root" in kind) walk("root", 0, "root")
      for (i = 1; i <= nn; i++) { id = norder[i]; if (!(id in reached)) { print "違反: node " id " は root から到達できません"; bad++ } }
      if (nleaves > max_leaves) { print "違反: 葉が " nleaves " 件で上限 " max_leaves " を超えています"; bad++ }
      if (nleaves == 0) { print "違反: 葉が 0 件です（木が葉を持っていません）"; bad++ }
      maxd = 0
      for (t in leafdepth) { if (leafdepth[t] > maxd) maxd = leafdepth[t]; print "LEAF\t" t }
      for (i = 1; i <= nn; i++) if (kind[norder[i]] == "choice") {
        # option は空白区切りの 1 行で出す（改行区切りだと呼び出し側の行読みが 2 件目以降を落とす）
        n = split(alist[norder[i]], arr, "\n"); opts = ""
        for (j = 1; j <= n; j++) if (arr[j] != "none") opts = (opts == "") ? arr[j] : opts " " arr[j]
        print "CHOICE\t" norder[i] "\t" opts
      }
      print "SUMMARY\t" nn "\t" nleaves "\t" maxd "\t" bad + 0
    }
  ')"
  # 違反行を出す
  while IFS= read -r line; do
    case "$line" in
      "違反: "*) echo "  ✗ ${line#違反: }" >&2; n_violations=$((n_violations + 1)) ;;
    esac
  done <<EOF
$structural
EOF

  # 葉の実在（skill / hook / doc）と hook の登録。登録は hooks.json の **command フィールドだけ**から
  # 引く（全文 grep だと description にパスが残っている限り command を消しても検出できない）。
  local leaf kindname name path anchor registered
  registered="$(jq -r '.hooks // {} | to_entries[] | .value[]? | .hooks[]? | .command // empty' "$hooks_json" 2>/dev/null | grep -oE 'hooks/[A-Za-z0-9_.-]+\.sh' | LC_ALL=C sort -u)"
  local reg_set="${nl}${registered}${nl}"
  while IFS= read -r line; do
    case "$line" in
      "LEAF	"*) ;;
      *) continue ;;
    esac
    leaf="${line#LEAF	}"
    kindname="${leaf%%:*}"
    name="${leaf#*:}"
    case "$kindname" in
      skill)
        [ -f "$skills_dir/$name/SKILL.md" ] || { echo "  ✗ 実在しない葉（skill）: skills/${name}/SKILL.md" >&2; n_violations=$((n_violations + 1)); }
        ;;
      hook)
        if [ ! -f "$hooks_dir/$name.sh" ]; then
          echo "  ✗ 実在しない葉（hook）: hooks/${name}.sh" >&2; n_violations=$((n_violations + 1))
        else
          case "$reg_set" in
            *"${nl}hooks/${name}.sh${nl}"*) ;;
            *) echo "  ✗ hooks.json の command に登録されていない葉（hook）: hooks/${name}.sh（登録の無い hook は走らない）" >&2; n_violations=$((n_violations + 1)) ;;
          esac
        fi
        ;;
      doc)
        # 見出し行（`#` 始まり）として実在することを要求する。固定文字列の有無だけだと、見出しが
        # 本文へ降格しても同じ語が残る限り「実在」に見える
        path="${name%%#*}"; anchor="${name#*#}"
        if [ ! -f "$PLUGIN_ROOT/$path" ]; then
          echo "  ✗ 実在しない葉（doc）: ${path}" >&2; n_violations=$((n_violations + 1))
        elif ! awk -v a="$anchor" 'substr($0, 1, 1) == "#" && index($0, a) > 0 && $0 ~ /^#+ / { f = 1 } END { exit f ? 0 : 1 }' "$PLUGIN_ROOT/$path"; then
          echo "  ✗ doc の葉の見出しが Markdown 見出し行として本文にありません: ${path} の「${anchor}」" >&2; n_violations=$((n_violations + 1))
        fi
        ;;
    esac
  done <<EOF
$structural
EOF

  # 木に載っていないスキル / hook（母集団は実体と hooks.json の command から導出する。名簿は持たない）。
  # 照合は行全体（前後に改行を付けた完全一致）で行う — 部分一致だと `skill:ace` が
  # `skill:ace-curate` の接頭辞として通り、木から落ちたスキルが緑になる。
  local leaf_set skill_dir sname
  leaf_set="$(printf '%s\n' "$structural" | awk -F'\t' '$1 == "LEAF" { print $2 }')"
  leaf_set="${nl}${leaf_set}${nl}"
  local found_skills=0
  for skill_dir in "$skills_dir"/*/; do
    [ -f "${skill_dir}SKILL.md" ] || continue
    found_skills=$((found_skills + 1))
    sname="$(basename "$skill_dir")"
    case "$leaf_set" in
      *"${nl}skill:${sname}${nl}"*) ;;
      *) echo "  ✗ 木に載っていないスキル: ${sname}" >&2; n_violations=$((n_violations + 1)) ;;
    esac
  done
  [ "$found_skills" -gt 0 ] || { echo "  ✗ skills/ に SKILL.md が 1 件もありません（母集団が空 — 検査が空振りしています）" >&2; n_violations=$((n_violations + 1)); }
  local hname found_hooks=0
  [ -n "$registered" ] || { echo "  ✗ hooks.json の command から登録 hook を 1 件も抽出できません（母集団が空 — 検査が空振りしています）" >&2; n_violations=$((n_violations + 1)); }
  while IFS= read -r hname; do
    [ -n "$hname" ] || continue
    found_hooks=$((found_hooks + 1))
    hname="${hname#hooks/}"; hname="${hname%.sh}"
    case "$leaf_set" in
      *"${nl}hook:${hname}${nl}"*) ;;
      *) echo "  ✗ 木に載っていない hook: hooks/${hname}.sh" >&2; n_violations=$((n_violations + 1)) ;;
    esac
  done <<EOF
$registered
EOF

  # choice ノードの criteria fixture（scripts/jev/questions/<id>.json）: option の集合 = none 以外の答え
  local qfile opts jopts cid
  while IFS= read -r line; do
    case "$line" in
      "CHOICE	"*) ;;
      *) continue ;;
    esac
    line="${line#CHOICE	}"
    cid="${line%%	*}"
    opts="$(printf '%s\n' "${line#*	}" | tr ' ' '\n' | LC_ALL=C sort)"
    qfile="$PLUGIN_ROOT/scripts/jev/questions/${cid}.json"
    if [ ! -f "$qfile" ]; then
      echo "  ✗ choice node ${cid} の criteria fixture がありません: scripts/jev/questions/${cid}.json" >&2; n_violations=$((n_violations + 1)); continue
    fi
    if ! jopts="$(jq -r --arg id "$cid" '.[$id] | select(.type == "choice") | .criteria | keys[]' "$qfile" 2>/dev/null | LC_ALL=C sort)" || [ -z "$jopts" ]; then
      echo "  ✗ choice node ${cid} の fixture が choice 型の criteria を持っていません: scripts/jev/questions/${cid}.json" >&2; n_violations=$((n_violations + 1)); continue
    fi
    if [ "$opts" != "$jopts" ]; then
      echo "  ✗ choice node ${cid} の答えの集合と fixture の option が一致しません（木: $(printf '%s' "$opts" | tr '\n' ' ') / fixture: $(printf '%s' "$jopts" | tr '\n' ' ')）" >&2; n_violations=$((n_violations + 1))
    fi
  done <<EOF
$structural
EOF

  local summary
  summary="$(printf '%s\n' "$structural" | awk -F'\t' '$1 == "SUMMARY" { print $2 "\t" $3 "\t" $4 }')"
  if [ "$n_violations" -gt 0 ]; then
    echo "✗ route --check: 違反 ${n_violations} 件（${TREE}）" >&2
    return 1
  fi
  echo "✓ route --check: ノード $(printf '%s' "$summary" | cut -f1) / 葉 $(printf '%s' "$summary" | cut -f2)（上限 ${MAX_LEAVES}）/ 最大深さ $(printf '%s' "$summary" | cut -f3)（上限 ${MAX_DEPTH}）"
  return 0
}

# ---- --leaves ------------------------------------------------------------------------
list_leaves() {
  tree_is_readable || { echo "✗ route --leaves: 木データを読めません: ${TREE}" >&2; return 2; }
  tree_rows | awk -F'\t' '
    $1 == "BAD" { bad = 1 }
    $1 == "answer" && $4 != "none" && $4 !~ /^node:/ {
      kind = $4; sub(/:.*/, "", kind); name = substr($4, length(kind) + 2)
      print kind "\t" name "\t" $4
    }
    END { if (bad) exit 2 }
  ' | LC_ALL=C sort -u
}

# ---- --walk --------------------------------------------------------------------------
walk_tree() {
  local node="root" ans tgt path="root" rows
  tree_is_readable || { echo "✗ route --walk: 木データを読めません: ${TREE}" >&2; return 2; }
  rows="$(tree_rows)"
  [ ${#WALK_ARGS[@]} -gt 0 ] || die_usage "--walk には答えを 1 つ以上渡します"
  for ans in "${WALK_ARGS[@]}"; do
    tgt="$(printf '%s\n' "$rows" | awk -F'\t' -v n="$node" -v a="$ans" '$1 == "answer" && $2 == n && $3 == a { print $4; exit }')"
    if [ -z "$tgt" ]; then
      echo "PATH=${path}"
      echo "✗ route --walk: node ${node} に答え ${ans} はありません" >&2
      return 2
    fi
    path="${path}/${ans}"
    case "$tgt" in
      node:*) node="${tgt#node:}" ;;
      *) echo "PATH=${path}"; echo "TARGET=${tgt}"; return 0 ;;
    esac
  done
  echo "PATH=${path}"
  echo "TARGET=node:${node}"
  echo "QUESTION=$(printf '%s\n' "$rows" | awk -F'\t' -v n="$node" '$1 == "node" && $2 == n { print $4; exit }')"
  echo "ANSWERS=$(printf '%s\n' "$rows" | awk -F'\t' -v n="$node" '$1 == "answer" && $2 == n { printf "%s%s", (c++ ? " " : ""), $3 }')"
}

# ---- 判定材料の収集 ------------------------------------------------------------------
# 読めない入力の判定（undecidable）はコマンド置換の外で行う — 置換の中で exit すると
# DT_ROUTE= 行が置換結果へ吸われ、呼び出し側には届かない。
collect_files() { # stdout: 1 行 1 path（--files-from / --files のとき）
  if [ -n "$FILES_FROM" ]; then
    if [ "$FILES_FROM" = "-" ]; then cat; else cat "$FILES_FROM"; fi
    return 0
  fi
  printf '%s\n' "${FILE_ARGS[@]}"
}

route_rules() { # $1=files（改行区切り） $2=lines → stdout: route<TAB>reason
  local files="$1" lines="$2" docs_glob contract max_lines f pat docs_only=1 contract_hit=""
  docs_glob="$(tree_rows | awk -F'\t' '$1 == "rule" && $2 == "root" && $3 == "docs-glob" { print $4; exit }')"
  contract="$(tree_rows | awk -F'\t' '$1 == "rule" && $2 == "root" && $3 == "contract-path" { print $4; exit }')"
  max_lines="$(tree_rows | awk -F'\t' '$1 == "rule" && $2 == "root" && $3 == "fast-max-lines" { print $4; exit }')"
  [ -n "$docs_glob" ] && [ -n "$contract" ] && [ -n "$max_lines" ] || return 2
  case "$max_lines" in ''|*[!0-9]*) return 2 ;; esac
  set -f
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    for pat in $contract; do
      case "$f" in $pat) contract_hit="$f"; break ;; esac
    done
    [ -z "$contract_hit" ] || break
    local matched=0
    for pat in $docs_glob; do
      case "$f" in $pat) matched=1; break ;; esac
    done
    [ "$matched" -eq 1 ] || docs_only=0
  done <<EOF
$files
EOF
  set +f
  if [ -n "$contract_hit" ]; then printf 'full\tcontract-change:%s\n' "$contract_hit"; return 0; fi
  if [ "$docs_only" -eq 1 ]; then printf 'fast\tdocs-only\n'; return 0; fi
  case "$lines" in
    ''|-|*[!0-9]*) ;;
    *) if [ "$lines" -le "$max_lines" ]; then printf 'fast\tsmall-diff\n'; return 0; fi ;;
  esac
  printf 'full\timplementation\n'
}

route_jev() { # $1=files $2=lines $3=nfiles → stdout: route<TAB>reason<TAB>source。rc 0 = 決めた / 12 = 規則へ / 2 = 入力不正
  local files="$1" lines="$2" nfiles="$3" state out rc decision reason value
  # fixture はノード id で引く（質問 id もノード id）。判定点名（FF_JEV_POINTS の名簿）は `route`
  local qfile="$PLUGIN_ROOT/scripts/jev/questions/root.json"
  [ -x "$JEV_DECIDE" ] || [ -f "$JEV_DECIDE" ] || { echo "✗ route: jev-decide.sh がありません: ${JEV_DECIDE}" >&2; return 2; }
  [ -f "$qfile" ] || { echo "✗ route: criteria fixture がありません: ${qfile}" >&2; return 2; }
  if ! state="$(mktemp "${TMPDIR:-/tmp}/ff-decision-tree-state.XXXXXX" 2>&1)" || [ ! -f "$state" ]; then
    echo "✗ route: state の一時ファイルを作れません: ${state}" >&2; return 2
  fi
  {
    printf 'Change request routing. Changed files (%s):\n%s\nChanged lines (added + deleted): %s\n' "$nfiles" "$files" "$lines"
    if [ -n "$ISSUE_BODY" ] && [ -r "$ISSUE_BODY" ]; then printf 'Issue body:\n'; cat "$ISSUE_BODY"; fi
  } > "$state"
  out="$(bash "$JEV_DECIDE" route --questions "$qfile" --state-file "$state" 2>/dev/null)"; rc=$?
  rm -f "$state"
  case "$rc" in
    0)
      value="$(printf '%s\n' "$out" | awk -F'|' '/^ANSWER=root\|choice\|/ { print $3; exit }')"
      case "$value" in
        fast|full) printf '%s\tjev-adopt\tjev\n' "$value"; return 0 ;;
        *) printf 'none\tjev-unknown-answer:%s\tjev\n' "${value:-empty}"; return 0 ;;
      esac ;;
    10) printf 'none\tjev-low-confidence\tjev\n'; return 0 ;;
    11)
      reason="$(printf '%s\n' "$out" | awk -F= '/^JEV_REASON=/ { print $2; exit }')"
      printf 'none\tjev-fallback:%s\tjev\n' "${reason:-unknown}"; return 0 ;;
    12) return 12 ;;
    *) echo "✗ route: jev-decide.sh が入力不正・使い方の誤りで止まりました（rc=${rc}）" >&2; return 2 ;;
  esac
}

route_request() {
  local files nfiles lines="$LINES" verdict route reason source="rules" rc
  tree_is_readable || undecidable "木データを読めません: ${TREE}"
  if [ -n "$FILES_FROM" ] || [ ${#FILE_ARGS[@]} -gt 0 ]; then
    if [ -n "$FILES_FROM" ] && [ "$FILES_FROM" != "-" ] && [ ! -r "$FILES_FROM" ]; then
      undecidable "path 一覧が読めません: ${FILES_FROM}"
    fi
    files="$(collect_files)" || undecidable "path 一覧の読み出しに失敗しました"
    USE_GIT=0
  else
    USE_GIT=1
    files=""
  fi
  if [ "$USE_GIT" -eq 1 ]; then
    git rev-parse --git-dir >/dev/null 2>&1 || undecidable "git リポジトリの外で実行されました"
    if [ -z "$BASE" ]; then
      BASE="${WORKFLOW_TIER_BASE:-}"
      if [ -z "$BASE" ]; then
        BASE="$(git symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || true)"
        [ -n "$BASE" ] || BASE="origin/develop"
      fi
    fi
    git rev-parse --verify --quiet "$BASE" >/dev/null 2>&1 || undecidable "base ref を解決できません: ${BASE}（--base か WORKFLOW_TIER_BASE で指定）"
    # コミット済み差分 + 作業ツリーの差分（未コミットの編集も判定材料）+ untracked。rename は分割して
    # 両側を出す。git コマンドは 1 本ずつ終了コードを見る — まとめて `;` で並べると最後のコマンドの
    # rc しか見えず、共通祖先の無い base（orphan）で diff が黙って失敗した回が「差分なし」に化けて
    # fast へ倒れる（レビューで再現）。
    local diff_committed diff_wt untracked numstat untracked_lines f rc_ns
    diff_committed="$(git -c core.quotepath=false diff --no-renames --name-only "${BASE}...HEAD" 2>/dev/null)" \
      || undecidable "git diff ${BASE}...HEAD が失敗しました（共通祖先が無い等。--base を確認）"
    diff_wt="$(git -c core.quotepath=false diff --no-renames --name-only HEAD 2>/dev/null)" \
      || undecidable "git diff HEAD が失敗しました（コミットが無いリポジトリ等）"
    untracked="$(git -c core.quotepath=false ls-files --others --exclude-standard 2>/dev/null)" \
      || undecidable "git ls-files --others が失敗しました"
    files="$(printf '%s\n%s\n%s\n' "$diff_committed" "$diff_wt" "$untracked" | awk 'NF && !seen[$0]++')"
    if [ "$lines" = "-" ]; then
      # 変更行数 = numstat の追加 + 削除。numstat が `-`（バイナリ）を 1 行でも含めば行数は取れない
      # ものとして `-` にし、small-diff の規則に当たらないようにする（0 に丸めると fast へ倒れる）。
      # untracked は numstat に出ないので、ファイルごとに `git diff --no-index --numstat /dev/null`
      # で足す（同じ形でバイナリを `-` として扱える。差分ありは rc 1 で正常）。
      numstat="$(git diff --no-renames --numstat "${BASE}...HEAD" 2>/dev/null)" \
        || undecidable "git diff --numstat ${BASE}...HEAD が失敗しました"
      numstat="${numstat}
$(git diff --no-renames --numstat HEAD 2>/dev/null)" || undecidable "git diff --numstat HEAD が失敗しました"
      while IFS= read -r f; do
        [ -n "$f" ] || continue
        [ -f "$f" ] || continue
        untracked_lines="$(git diff --no-index --numstat /dev/null -- "$f" 2>/dev/null)"; rc_ns=$?
        [ "$rc_ns" -le 1 ] || undecidable "untracked ファイルの行数を取れません: ${f}"
        numstat="${numstat}
${untracked_lines}"
      done <<EOF
$untracked
EOF
      lines="$(printf '%s\n' "$numstat" | awk -F'\t' '
        NF < 2 { next }
        $1 == "-" || $2 == "-" { binary = 1; next }
        $1 ~ /^[0-9]+$/ && $2 ~ /^[0-9]+$/ { n += $1 + $2 }
        END { if (binary) print "-"; else print n + 0 }')"
    fi
  fi
  files="$(printf '%s\n' "$files" | awk 'NF')"
  nfiles="$(printf '%s\n' "$files" | awk 'NF { n++ } END { print n + 0 }')"
  case "$lines" in ''|-) lines="-" ;; *[!0-9]*) undecidable "--lines が整数ではありません: ${lines}" "$nfiles" ;; esac

  if [ "$nfiles" -eq 0 ]; then
    emit_route none no-files none 0 "$lines"
    exit 0
  fi

  case "${FF_JEV_MODE:-off}" in
    on)
      verdict="$(route_jev "$files" "$lines" "$nfiles")"; rc=$?
      case "$rc" in
        0) route="${verdict%%	*}"; reason="$(printf '%s' "$verdict" | cut -f2)"; source="$(printf '%s' "$verdict" | cut -f3)"
           emit_route "$route" "$reason" "$source" "$nfiles" "$lines"; exit 0 ;;
        12) ;;  # 判定点が名簿に無い → 規則へ
        *) undecidable "Jev の呼び出しが判定不能で止まりました（rc=${rc}）" "$nfiles" "$lines" ;;
      esac ;;
    off) ;;
    *) undecidable "FF_JEV_MODE は on か off です（未知の値）" "$nfiles" "$lines" ;;
  esac

  verdict="$(route_rules "$files" "$lines")" || undecidable "root の rule（docs-glob / contract-path / fast-max-lines）が木データにありません" "$nfiles" "$lines"
  route="${verdict%%	*}"; reason="${verdict#*	}"
  emit_route "$route" "$reason" rules "$nfiles" "$lines"
  exit 0
}

case "$MODE" in
  check) check_tree; exit $? ;;
  leaves) list_leaves; exit $? ;;
  walk) walk_tree; exit $? ;;
  route) route_request ;;
esac
