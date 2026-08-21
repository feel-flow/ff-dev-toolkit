#!/usr/bin/env bash
#
# 推奨ラベル・セットアップの契約検査（Issue #298）。
#
# `docs-template/scripts/setup-github-labels.sh` はラベル定義の正本（SSOT）を
# `LABEL_DEFS` ブロックに持ち、`docs-template/05-operations/deployment/github-setup.md`
# は同じ定義を「カスタムラベル（追加が必要）」表と手動セットアップ例の 2 箇所に
# 人間向けの写しとして持つ。写しは共有できない（文書は表、スクリプトはデータ行と
# 形が違う）ので、ドリフト対策は照合で行う: 3 箇所の name / color / description が
# 一致しなければ red にする。Issue #625 でさらに、名前の正本（EXPECTED_LABEL_NAMES）
# との位置比較・setup-github-labels SKILL.md 軸別表（名前のみの 4 箇所目）・
# `gh label delete` 案内との交差・実行検査数の侵食ガードを追加した。
#
# あわせて振る舞いも実測する。静的な照合は「定義がそう書いてある」までしか言えず、
#   - 不足分だけが作成され、既存ラベルに一切触れないこと（冪等）
#   - 照会を信用できないとき（失敗・空・上限到達）に 1 件も作成せず非 0 で
#     終了すること（fail-closed。「存在しない」と誤断定して作成に進まない）
# は実行しないと分からない。`gh` の stub の下でスクリプトを走らせて確かめる。
# 安全弁: `gh` が stub に解決されることを確認してからでないと実行しない
# （取り違えると本物のリポジトリにラベルを作ってしまう）。
#
# 一時ファイルは作らないので、書き込み不可の環境でも完走する。
#
# 使い方: bash plugins/ff-dev-toolkit/tests/github-labels-setup/verify.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SETUP_SCRIPT="$PLUGIN_ROOT/docs-template/scripts/setup-github-labels.sh"
GITHUB_SETUP="$PLUGIN_ROOT/docs-template/05-operations/deployment/github-setup.md"
SKILL="$PLUGIN_ROOT/skills/setup-github-labels/SKILL.md"
STUB_DIR="$SCRIPT_DIR/fixtures/gh-stub"

# ラベル名の正本（本 verify.sh 内で唯一の列挙。Issue #625）。ラベルを増減するときは
# この 1 行と LABEL_DEFS・github-setup.md（表 / 手動例）・SKILL.md 軸別表・
# stub の allexist の 5 系統を直す（件数と behavioral の期待文字列はここから導出）。
# LABEL_DEFS とは**順序込み**で照合する。位置比較の固有の検出力は**並べ替え**
# （純粋な並べ替えは compare_defs の集合照合も wc -l の件数も通す）。重複は、
# 正本を触らない形なら導出件数との不一致が、正本まで同時に触る形なら下の
# 一意性自己検査が赤にする — 3 経路の組で全パターンを閉じている。
EXPECTED_LABEL_NAMES='major minor patch hotfix urgent priority:critical priority:high priority:medium priority:low follow-up refactor chore testing epic'
# 件数は正本から導出する（表・手動例の件数固定に使う）。
EXPECTED_LABEL_COUNT=$(printf '%s\n' $EXPECTED_LABEL_NAMES | wc -l | tr -d '[:space:]')

# 正本から除外付きの空白区切り列を導出する（partial 系の期待に使う。順序保存）。
derive_without() { # $1: 除外する名前（空白区切り）
  local out="" w x skip
  for w in $EXPECTED_LABEL_NAMES; do
    skip=0
    for x in $1; do [ "$w" = "$x" ] && skip=1; done
    [ "$skip" -eq 0 ] && out="${out:+$out }$w"
  done
  printf '%s' "$out"
}
# partial / casevariant モードの期待（major / minor が既存としてスキップされる）。
CREATED_WITHOUT_MAJOR_MINOR="$(derive_without 'major minor')"

PASS=0
FAIL=0
ok()  { echo "  ✓ $1"; PASS=$((PASS + 1)); }
bad() { echo "  ✗ $1" >&2; FAIL=$((FAIL + 1)); }

echo "== 推奨ラベル・セットアップの契約検査（SSOT 照合 + 振る舞い実測） =="

for file in "$SETUP_SCRIPT" "$GITHUB_SETUP" "$SKILL" "$STUB_DIR/gh"; do
  [ -s "$file" ] || { echo "✗ 必須ファイルが無いか空です: $file" >&2; exit 1; }
done

if syntax_err="$(bash -n "$SETUP_SCRIPT" 2>&1)"; then
  ok "setup-github-labels.sh が bash として構文的に妥当（bash -n）"
else
  bad "setup-github-labels.sh が bash -n を通らない"
  printf '%s\n' "$syntax_err" | sed 's/^/    | /' >&2
fi

# ---- 抽出器 3 種 ---------------------------------------------------------------
# いずれも `name|color|description`（color は # なし 6 桁 hex）へ正規化して出力する。

# スクリプトの LABEL_DEFS ブロック（SSOT）。sentinel の間の定義行だけを読む。
extract_script_defs() {
  awk '
    /^# LABEL_DEFS_BEGIN$/ { on = 1; next }
    /^# LABEL_DEFS_END$/   { on = 0 }
    on {
      line = $0
      sub(/^LABEL_DEFS='\''/, "", line)
      sub(/'\''$/, "", line)
      # `priority:critical` のような名前空間付きの名前があるため、コロンも通す。
      # ここを [a-z-] へ戻すと priority:* だけが抽出から落ちる。直接のガードは下の
      # 正の対照（コロン入りを拾えることの自己検証）で、そちらが先に赤くなり本検査
      # へ進まない。probe が無かった頃は「件数が合わない」という遠い症状でしか
      # 現れなかった — この 2 つは対なので、片方だけ消さないこと。
      if (line ~ /^[a-z][a-z:-]*\|[0-9A-Fa-f]{6}\|/) print line
    }
  ' "$1"
}

# github-setup.md の「カスタムラベル（追加が必要）」表。デフォルトラベル表と
# 区別するため、見出しから次の見出しまでの区間だけを読む。
extract_table_defs() {
  awk -F'|' '
    /^#### カスタムラベル/ { on = 1; next }
    on && /^#/ { on = 0 }
    on && $0 ~ /^\|[[:space:]]*`/ {
      name = $2; desc = $3; color = $4
      gsub(/[[:space:]`]/, "", name)
      gsub(/^[[:space:]]+/, "", desc); gsub(/[[:space:]]+$/, "", desc)
      gsub(/[[:space:]#]/, "", color)
      print name "|" color "|" desc
    }
  ' "$1"
}

# github-setup.md の手動セットアップ例（`gh label create ...` 行）。
# 表側の抽出器と同じく「### 手動セットアップ」節にスコープする（Issue #625）。
# スコープしないと、節から 1 件消えても別の節にある `gh label create` の例 1 行で
# 件数が維持され、照合も通ってしまう。節の終端は見出し（## 以上）のみ —
# 節内の bash フェンスには `# 分類の補完` のような単一 # のコメント行があるため、
# /^#/ で閉じると節が最初のコメントで途切れて抽出が静かに欠ける。
extract_manual_defs() {
  awk '
    /^### 手動セットアップ/ { on = 1; next }
    on && /^##/ { on = 0 }
    on && /^gh label create "/ {
      name = ""; desc = ""
      line = $0
      if (match(line, /create "[^"]+"/)) name = substr(line, RSTART + 8, RLENGTH - 9)
      if (match(line, /--description "[^"]+"/)) desc = substr(line, RSTART + 15, RLENGTH - 16)
      next_needs_color = 1
      # color は行継続（\）の次行にある形と同一行の形の両方を許す
      if (match(line, /--color "[^"]+"/)) {
        color = substr(line, RSTART + 9, RLENGTH - 10)
        print name "|" color "|" desc
        next_needs_color = 0
      }
      next
    }
    on && next_needs_color && match($0, /--color "[^"]+"/) {
      color = substr($0, RSTART + 9, RLENGTH - 10)
      print name "|" color "|" desc
      next_needs_color = 0
    }
  ' "$1"
}

# github-setup.md の `gh label delete "X"` 案内の対象名（Issue #625）。
# 削除案内と SSOT の交差は「文書が削除を勧めるラベルを、起票側が付けようとする」
# 矛盾（PR #622 が手で直した形）なので、機械で空集合を主張する。
extract_delete_targets() {
  awk '/^gh label delete "/ { if (match($0, /delete "[^"]+"/)) print substr($0, RSTART + 8, RLENGTH - 9) }' "$1"
}

# setup-github-labels SKILL.md の軸別ラベル表の名前（Issue #625。PR #662 で
# この表だけが 13 件のまま取り残される実欠落が起き、照合の 4 箇所目として追加）。
# ヘッダ先頭セルが「軸」の表にスコープし、バックティック内のラベル名文法だけを拾う。
extract_skill_axis_names() {
  awk '
    /^\|[[:space:]]*軸[[:space:]]*\|/ { on = 1; next }
    on && !/^\|/ { on = 0 }
    on {
      line = $0
      while (match(line, /`[^`]+`/)) {
        tok = substr(line, RSTART + 1, RLENGTH - 2)
        line = substr(line, RSTART + RLENGTH)
        if (tok ~ /^[a-z][a-z0-9:-]*$/) print tok
      }
    }
  ' "$1"
}

# ---- 自己検証（抽出器が本当に見ているかを先に確かめる） -------------------------
# 負の対照: sentinel / 見出しを持たないファイルからは 1 行も採れないこと。
if [ -n "$(extract_script_defs "$GITHUB_SETUP")" ]; then
  bad "自己検証: sentinel の無いファイルから SSOT を抽出できてしまった"
else
  ok "自己検証: sentinel の無いファイルからは SSOT を抽出しない"
fi
if [ -n "$(extract_table_defs "$SETUP_SCRIPT")" ]; then
  bad "自己検証: 見出しの無いファイルから表を抽出できてしまった"
else
  ok "自己検証: 見出しの無いファイルからは表を抽出しない"
fi
# setup スクリプトには「### 手動セットアップ」見出しが無いため、節スコープが
# 一度も開かず 1 行も採れないこと（負の対照。インデント行を拾わない行頭マッチの
# 検証は、節スコープ化に伴い下の scope_probe が節内のインデント行で担う）。
if [ -n "$(extract_manual_defs "$SETUP_SCRIPT")" ]; then
  bad "自己検証: 手動例の無いファイルから gh label create 定義を抽出できてしまった"
else
  ok "自己検証: 手動例の無いファイルからは gh label create 定義を抽出しない"
fi

# 正の対照: 名前空間付き（コロン入り）の名前を SSOT 抽出が拾えること。
# 抽出正規表現からコロンを落とす変異は、これが無いと「件数が合わない」としか出ない。
colon_probe="$(extract_script_defs <(printf '# LABEL_DEFS_BEGIN\nLABEL_DEFS=%spriority:critical|B60205|probe%s\n# LABEL_DEFS_END\n' "'" "'"))"
if [ "$colon_probe" = "priority:critical|B60205|probe" ]; then
  ok "自己検証: SSOT 抽出がコロン入りのラベル名を拾える"
else
  bad "自己検証: SSOT 抽出がコロン入りのラベル名を拾えない（実際: ${colon_probe:-なし}）"
fi

# 手動例の節スコープの対照: 節の前後にある gh label create は拾わず、節内だけを拾い、
# 節内の bash コメント（単一 #）で節が途切れず、節内でもインデント付きの行は
# 拾わない（行頭マッチ）こと（Issue #625）。
scope_probe="$(extract_manual_defs <(printf '## x\ngh label create "outside" --description "d" --color "111111"\n### 手動セットアップ\n# 分類の補完\ngh label create "inside" --description "d" --color "222222"\n  gh label create "indented" --description "d" --color "444444"\n### 次節\ngh label create "after" --description "d" --color "333333"\n'))"
if [ "$scope_probe" = "inside|222222|d" ]; then
  ok "自己検証: 手動例の抽出が節にスコープされ、行頭のコマンドだけを拾う"
else
  bad "自己検証: 手動例の節スコープが期待と違う（実際: $(printf '%s' "$scope_probe" | tr '\n' ' ')）"
fi

# delete 案内抽出の対照: 行頭の gh label delete から対象名を拾い、
# 行頭でない言及（インデント・散文）は拾わないこと。
delete_probe="$(extract_delete_targets <(printf 'gh label delete "feature" --yes\n  gh label delete "indented" --yes\n'))"
if [ "$delete_probe" = "feature" ]; then
  ok "自己検証: delete 案内の抽出が行頭コマンドだけを拾う"
else
  bad "自己検証: delete 案内の抽出が期待と違う（実際: $(printf '%s' "$delete_probe" | tr '\n' ' ')）"
fi

# 軸別表抽出の対照: 「軸」ヘッダの無いファイルからは 1 行も採れないこと。
if [ -n "$(extract_skill_axis_names "$SETUP_SCRIPT")" ]; then
  bad "自己検証: 軸ヘッダの無いファイルから軸別表を抽出できてしまった"
else
  ok "自己検証: 軸ヘッダの無いファイルからは軸別表を抽出しない"
fi

# 正本自身の一意性: 重複が正本を含む全系統へ同時に写されると、導出件数も位置比較も
# そろって通る（自己参照）。正本の重複フリーはここだけが主張できる。
if [ -z "$(printf '%s\n' $EXPECTED_LABEL_NAMES | sort | uniq -d)" ]; then
  ok "自己検証: 名前の正本に重複が無い（全系統へ同時に写った重複はここだけが検出する）"
else
  bad "自己検証: 名前の正本に重複がある: $(printf '%s\n' $EXPECTED_LABEL_NAMES | sort | uniq -d | tr '\n' ' ')"
fi

# 導出器の対照: derive_without の結果が期待の語数を持つこと。behavioral の期待は
# 前方一致（case の末尾 *）なので、導出結果が正しい列の**接頭辞に縮む**退化は
# 検査を空虚な緑にする — 特に「最初の除外要素で打ち切る」退化の出力は、
# createfailone が捕まえるべき変異（最初の失敗で試行が止まる）の実出力と一致する。
derive_probe="$(derive_without 'major minor')"
set -- $derive_probe
if [ "$#" -eq $((EXPECTED_LABEL_COUNT - 2)) ]; then
  ok "自己検証: derive_without が除外 2 件でちょうど $((EXPECTED_LABEL_COUNT - 2)) 語を返す（縮み退化の検出）"
else
  bad "自己検証: derive_without の語数が $# （期待 $((EXPECTED_LABEL_COUNT - 2))）— 導出が縮んでいる"
fi
case " $derive_probe " in
  *' major '*|*' minor '*) bad "自己検証: derive_without が除外対象を残している" ;;
  *) ok "自己検証: derive_without が除外対象（major / minor）を含まない" ;;
esac

# createfailone（§4）の失敗対象 urgent が正本の末尾に居ないこと。末尾だと
# 「後続の試行が継続される」ことを検査できず、最初の失敗で止まる変異が緑で通る。
# 位置比較は LABEL_DEFS と同時の並べ替えを**許す**設計なので、この不変条件は
# ここで独立に固定する。
case "$EXPECTED_LABEL_NAMES" in
  *' urgent')
    bad "自己検証: createfailone の失敗対象（urgent）が正本の末尾にある — 継続試行の検査が空虚になる" ;;
  *' urgent '*)
    ok "自己検証: createfailone の失敗対象（urgent）に後続ラベルがある（継続試行を検査できる）" ;;
  *)
    bad "自己検証: 正本に urgent が無い — createfailone の失敗対象を差し替えること" ;;
esac

# 比較器の対照: 1 行違いを本当に検出できること（常に「一致」を返す退化の検出）。
compare_defs() { # $1: 正本 / $2: 対象 → 差分行を出力（空なら一致）
  printf '%s\n' "$1" | sort | awk '
    NR == FNR { want[$0] = 1; next }
    !($0 in want) { print "正本に無い: " $0 }
    { got[$0] = 1 }
    END { for (w in want) if (!(w in got)) print "対象に無い: " w }
  ' - <(printf '%s\n' "$2" | sort)
}
if [ -n "$(compare_defs "a|111111|x" "a|222222|x")" ]; then
  ok "自己検証: 比較器が 1 行の差分を検出できる"
else
  bad "自己検証: 比較器が差分を検出できない — 常に一致を返している"
fi

if [ "$FAIL" -gt 0 ]; then
  echo ""
  echo "✗ github-labels-setup verify: 検出器の自己検証に失敗（本検査は実行しない）" >&2
  exit 1
fi

# ---- 1. SSOT の 3 箇所照合 ------------------------------------------------------
script_defs="$(extract_script_defs "$SETUP_SCRIPT")"
table_defs="$(extract_table_defs "$GITHUB_SETUP")"
manual_defs="$(extract_manual_defs "$GITHUB_SETUP")"

count_of() { [ -z "$1" ] && echo 0 || printf '%s\n' "$1" | wc -l | tr -d '[:space:]'; }

for pair in "SSOT（スクリプト）:$(count_of "$script_defs")" \
            "推奨ラベル表:$(count_of "$table_defs")" \
            "手動セットアップ例:$(count_of "$manual_defs")"; do
  name="${pair%%:*}"; count="${pair##*:}"
  if [ "$count" -eq "$EXPECTED_LABEL_COUNT" ]; then
    ok "${name} の定義が ${EXPECTED_LABEL_COUNT} 件（増減時は EXPECTED_LABEL_NAMES を更新すること。件数は導出）"
  else
    bad "${name} の定義が ${count} 件（期待 ${EXPECTED_LABEL_COUNT} 件）— 抽出が壊れているか定義が黙って増減している"
  fi
done

check_sync() { # $1: 対象名 / $2: 対象 defs
  local diff
  diff="$(compare_defs "$script_defs" "$2")"
  if [ -z "$diff" ]; then
    ok "${1} が SSOT と一致（name / color / description）"
  else
    bad "${1} が SSOT と不一致"
    printf '%s\n' "$diff" | sed 's/^/    | /' >&2
  fi
}
check_sync "github-setup.md の推奨ラベル表" "$table_defs"
check_sync "github-setup.md の手動セットアップ例" "$manual_defs"

# 名前の正本（EXPECTED_LABEL_NAMES）と LABEL_DEFS の名前列を**位置比較**する。
# 集合比較（compare_defs）と件数（wc -l）では、3 箇所すべてに同じ重複行が入った
# 場合に緑のまま通る — 位置比較は重複で以降の行がずれるため必ず赤になる。
script_names="$(printf '%s\n' "$script_defs" | sed 's/|.*$//')"
canonical_mismatch="$(printf '%s\n' $EXPECTED_LABEL_NAMES | awk '
  NR == FNR { want[FNR] = $0; want_n = FNR; next }
  { got[FNR] = $0; got_n = FNR }
  END {
    n = (want_n > got_n) ? want_n : got_n
    for (i = 1; i <= n; i++) {
      if (i > want_n)           { print i ": 正本に無い行 → " got[i]; continue }
      if (i > got_n)            { print i ": LABEL_DEFS に無い ← " want[i]; continue }
      if (want[i] != got[i])    { print i ": 不一致（正本 " want[i] " / 実際 " got[i] "）" }
    }
  }
' - <(printf '%s\n' "$script_names"))"
if [ -z "$canonical_mismatch" ]; then
  ok "名前の正本と LABEL_DEFS の名前列が順序込みで一致（重複・並べ替えも検出）"
else
  bad "名前の正本と LABEL_DEFS の名前列が食い違う（EXPECTED_LABEL_NAMES と LABEL_DEFS を同時に更新すること）"
  printf '%s\n' "$canonical_mismatch" | sed 's/^/    | /' >&2
fi

# ---- 1b. delete 案内 ∩ SSOT = ∅（Issue #625） -----------------------------------
# 期待集合を固定するのは、抽出の 0 件退化（= 交差検査の空虚な緑）だけでなく、
# 対象の誤字・重複・意図しない置換も赤にするため。削除案内を増減したらここも更新する。
EXPECTED_DELETE_TARGETS='feature
fix
docs'
delete_targets="$(extract_delete_targets "$GITHUB_SETUP")"
if [ "$delete_targets" = "$EXPECTED_DELETE_TARGETS" ]; then
  ok "delete 案内の対象が期待集合（feature / fix / docs）と完全一致（増減時は EXPECTED_DELETE_TARGETS も更新すること）"
else
  bad "delete 案内の対象が期待集合と食い違う（実際: $(printf '%s' "$delete_targets" | tr '\n' ' ')）— 抽出が壊れているか案内が黙って変わっている"
fi
# heredoc は実行時に一時ファイルを要求し read-only 完走の前提を破るため、
# プロセス置換（/dev/fd）+ awk で交差を求める。GitHub のラベル名一意制約は
# case-insensitive（§4 casevariant と同じ根拠）なので、両辺を小文字化してから交わす —
# `gh label delete "Major"` は実リポジトリでは major を消す。
delete_overlap="$(printf '%s\n' "$script_names" | tr '[:upper:]' '[:lower:]' | awk '
  NR == FNR { ssot[$0] = 1; next }
  NF && ($0 in ssot) { print }
' - <(printf '%s\n' "$delete_targets" | tr '[:upper:]' '[:lower:]') | tr '\n' ' ')"
delete_overlap="${delete_overlap% }"
if [ -z "$delete_overlap" ]; then
  ok "delete 案内の対象と SSOT のラベル名が交わらない（削除を勧めるラベルを起票側が付けない）"
else
  bad "delete 案内が SSOT のラベルの削除を勧めている（文書とスキルの矛盾。対象: ${delete_overlap}）"
fi

# ---- 1c. SKILL.md 軸別表 = SSOT の名前集合（照合の 4 箇所目。Issue #625） --------
# PR #662 で LABEL_DEFS の 14 件化に対しこの表だけが 13 件のまま取り残され、
# 当時の 3 箇所照合の検査対象外だったため全ゲート緑で通過した。ソート後の位置比較で
# 欠落・過剰・重複のすべてを赤にする（表は軸ごとのグループ表示なので順序は縛らない）。
skill_axis_names="$(extract_skill_axis_names "$SKILL")"
skill_axis_mismatch="$(printf '%s\n' "$script_names" | sort | awk '
  NR == FNR { want[FNR] = $0; want_n = FNR; next }
  { got[FNR] = $0; got_n = FNR }
  END {
    n = (want_n > got_n) ? want_n : got_n
    for (i = 1; i <= n; i++) {
      if (i > want_n)        { print "SSOT に無い: " got[i]; continue }
      if (i > got_n)         { print "軸別表に無い: " want[i]; continue }
      if (want[i] != got[i]) { print "不一致: SSOT " want[i] " / 軸別表 " got[i] }
    }
  }
' - <(printf '%s\n' "$skill_axis_names" | sort))"
if [ -z "$skill_axis_mismatch" ]; then
  ok "SKILL.md 軸別表のラベル名集合が SSOT と一致（照合の 4 箇所目）"
else
  bad "SKILL.md 軸別表のラベル名集合が SSOT と食い違う"
  printf '%s\n' "$skill_axis_mismatch" | sed 's/^/    | /' >&2
fi

# ---- 2. スクリプトの静的契約 ----------------------------------------------------
# 既存ラベルへ触れないこと: --force（不在時 create / 既存時 update の両対応）と
# `gh label edit` をコマンド行に持たない。散文・コメントでの言及（「--force は
# 使わない」等）は違反ではないので、コメント行を除いた行だけを見る。
force_violations="$(awk '
  /^[[:space:]]*#/ { next }
  /gh label create/ && /--force/ { print NR }
  /^[[:space:]]*gh label edit([[:space:]]|$)/ { print NR }
  /[[:space:]]gh label edit([[:space:]]|$)/ { print NR }
' "$SETUP_SCRIPT")"
if [ -z "$force_violations" ]; then
  ok "スクリプトは既存ラベルを変更しない（--force / gh label edit をコマンド行に持たない）"
else
  bad "既存ラベルを変更しうるコマンド行がある（行: ${force_violations//$'\n'/, }）"
fi

# fail-closed の宣言が実体として残っていること（--limit 明示・照会失敗/空/上限の 3 分岐）。
contains() {
  local label="$1" needle="$2"
  if grep -qF -- "$needle" "$SETUP_SCRIPT"; then ok "$label"; else bad "${label}（不足: ${needle}）"; fi
}
# この契約文字列は実装の生テキストとの完全一致（`$repo` 直後は ASCII 空白なので
# マルチバイト直付けの対象外）。実装側を `${repo}` へ揃えるリファクタはここも同時に更新する。
contains "ラベル一覧の取得が --limit を明示する" 'gh label list --repo "$repo" --limit "$label_limit"'
contains "照会失敗で作成せず終了する" '実在を確認できないため作成しません'
contains "空の一覧を「不在」と誤断定しない" '取得が機能しなかった場合と区別できないため作成しません'
contains "上限到達を「不在」と誤断定しない" '不在を確認できないため作成しません'
# 件数不確定の case ガード（wc の失敗を fail-open へ反転させないための分岐）が実体として
# 残っていること。この経路は stub gh からは踏めない（wc の失敗が必要）ため、静的に固定する。
contains "件数不確定を「不在」と誤断定しない（fail-open 反転ガード）" '件数を確定できませんでした'

# ---- 2b. 静的検査: $VAR 直付けのマルチバイト展開（bash 3.2 回帰ガード） ----------
# bash 3.2（macOS 標準 /bin/bash）は $VAR 直後のマルチバイト文字の先頭バイトを変数名へ
# 取り込み、set -u 下では失敗を報告しようとした瞬間だけ unbound variable で落ちる
# （Issue #300）。後段の振る舞い検査は PATH の bash とロケールを継承するため、bash 5 や
# LC_ALL=C の環境ではこの回帰を再現できない — 環境非依存の静的検査で固定する。
# 検出器は merge-cleanup/verify.sh と同型: LC_ALL=C では [:print:] も [:space:] も
# ASCII に限られるため、「印字可能でも空白でもないバイト」= マルチバイト先頭バイトを拾える。
MBCS_RE='\$[A-Za-z_][A-Za-z0-9_]*[^[:print:][:space:]]'
mbcs_file_hits()  { LC_ALL=C grep -nE "$MBCS_RE" "$1" || true; }
mbcs_probe_hits() { printf '%s\n' "$1" | LC_ALL=C grep -E "$MBCS_RE" || true; }

# 検出器の自己検証（空振りの fail-closed）。違反 probe は 2 分割で組み立てる —
# 1 行に直書きすると、この verify.sh 自身も検査対象なので probe が違反として検出される。
mbcs_probe_bad='echo "失敗しました: $name'
mbcs_probe_bad="${mbcs_probe_bad}（原因不明）\""
mbcs_probe_good='echo "失敗しました: ${name}（原因不明）"'
if [ -n "$(mbcs_probe_hits "$mbcs_probe_bad")" ]; then
  ok "MBCS 検出器が違反を検出できる（self-test）"
else
  bad "MBCS 検出器が違反を検出できない — 以降の静的検査は空振りしている"
fi
if [ -z "$(mbcs_probe_hits "$mbcs_probe_good")" ]; then
  ok "MBCS 検出器が \${VAR} 形式を誤検出しない（self-test）"
else
  bad "MBCS 検出器が \${VAR} 形式を誤検出する"
fi

# 対象はスクリプト本体と、この verify.sh 自身（テストハーネスの失敗報告パスも
# 同じバグクラスで落ちた実績があるため）。
for mbcs_target in "$SETUP_SCRIPT" "$0"; do
  mbcs_hits="$(mbcs_file_hits "$mbcs_target")"
  if [ -z "$mbcs_hits" ]; then
    ok "$(basename "$mbcs_target") に \$VAR 直付けのマルチバイト展開が無い"
  else
    bad "$(basename "$mbcs_target") に \$VAR 直付けのマルチバイト展開がある（\${VAR} 形式にすること）"
    printf '%s\n' "$mbcs_hits" | sed 's/^/    | /' >&2
  fi
done

# ---- 3. SKILL.md の発動トリガーと導線 -------------------------------------------
description_line="$(awk '{ sub(/\r$/, "") } /^---$/ { n++; next } n == 1 && /^description:/ { print; exit } n == 2 { exit }' "$SKILL")"
description_has() {
  local needle="$1" label="$2"
  case "$description_line" in
    *"$needle"*) ok "$label" ;;
    *) bad "${label}（description に不足: ${needle}）" ;;
  esac
}
if [ -z "$description_line" ]; then
  bad "setup-github-labels の frontmatter から description 行を取り出せない"
else
  description_has "Use when setting up recommended GitHub labels" "description が発動条件から始まる"
  description_has "「ラベルを整備して」" "description に日本語のトリガーがある"
  description_has "set up labels" "description に英語のトリガーがある"
  description_has "create-issue" "description が付与側（create-issue）との棲み分けを示す"
fi
skill_contains() {
  local label="$1" needle="$2"
  if grep -qF -- "$needle" "$SKILL"; then ok "$label"; else bad "${label}（不足: ${needle}）"; fi
}
skill_contains "SKILL.md が同梱スクリプトを実行する" 'docs-template/scripts/setup-github-labels.sh'
skill_contains "SKILL.md が報告を出力の写しに限定する" 'そのまま読んで'

# create-issue の完了報告に整備側への案内導線があること（Issue #298 AC4）。
# 「不在」のときだけ案内し「照会失敗」では案内しない、という条件付きの導線なので、
# 条件の核になる文言まで含めて固定する。
CREATE_ISSUE="$PLUGIN_ROOT/skills/create-issue/SKILL.md"
if grep -qF -- '省略理由が「不在」のラベルがある場合は、`/setup-github-labels`' "$CREATE_ISSUE"; then
  ok "create-issue の完了報告が「不在」時に /setup-github-labels を案内する"
else
  bad "create-issue の完了報告に /setup-github-labels への案内が無い"
fi
if grep -qF -- '「照会失敗」のときは添えない' "$CREATE_ISSUE"; then
  ok "create-issue の案内は「照会失敗」時には出さない（誤断定の再発防止）"
else
  bad "create-issue の案内に「照会失敗では出さない」条件が無い"
fi

# epic の副作用（ラベルの実在が out-of-scope-issue の分岐を開く）は、スクリプト・
# github-setup.md・SKILL.md の 3 箇所に警告として書かれている。参照先が変わると
# その 3 箇所が黙って嘘になるため、参照先の記述そのものをピン留めする。
OUT_OF_SCOPE="$PLUGIN_ROOT/skills/out-of-scope-issue/SKILL.md"
if [ ! -s "$OUT_OF_SCOPE" ]; then
  bad "out-of-scope-issue の SKILL.md が見つからない（epic 副作用の参照先）"
elif ! grep -qF -- '#### Epic への紐付け' "$OUT_OF_SCOPE"; then
  bad "out-of-scope-issue に Epic 紐付けの節が無い（3 箇所の epic 警告文が嘘になる）"
elif ! grep -qF -- '--label epic' "$OUT_OF_SCOPE"; then
  bad "out-of-scope-issue が epic ラベルで open Epic を照会していない（3 箇所の epic 警告文が嘘になる）"
else
  # 散文の一致ではなく節の存在と照会コマンドで見る。文言の言い換えで赤にすると
  # 「直し方が嘘のゲート」になるが、分岐そのものが消える退化はこの 2 つで拾える。
  ok "epic 副作用の警告が参照先（out-of-scope-issue）の分岐と対応している"
fi

# github-setup.md の自動セットアップ手順が、配布実体への入手経路を示していること
# （`./scripts/setup-github-labels.sh` の参照だけでは、スクリプトがどこから来るのか
# 消費プロジェクトには分からない — Issue #298 の「壊れた参照」の再発防止）。
if grep -qF -- 'docs-template/scripts/setup-github-labels.sh' "$GITHUB_SETUP"; then
  ok "github-setup.md がスクリプトの入手経路（配布実体のパス）を示す"
else
  bad "github-setup.md が配布実体のパスを示していない（./scripts/ 参照だけでは入手経路が無い）"
fi

# ---- 4. 振る舞いの実測（stub gh の下で実行） ------------------------------------
resolved_gh="$(PATH="$STUB_DIR:$PATH" command -v gh || true)"
if [ ! -x "$STUB_DIR/gh" ]; then
  bad "behavioral 検査: stub gh が実行可能でない（$STUB_DIR/gh）"
elif [ "$resolved_gh" != "$STUB_DIR/gh" ]; then
  bad "behavioral 検査: gh が stub に解決されない（${resolved_gh}）— 実リポジトリへラベルを作る危険があるので実行しない"
else
  ok "behavioral 検査: gh が stub に解決される（実 API を叩かない）"

  run_script() { # $1: GH_STUB_MODE / $2...: スクリプト引数。stdout/stderr を合流して返す（argv は stderr に出る）
    local mode="$1"; shift
    PATH="$STUB_DIR:$PATH" GH_STUB_MODE="$mode" bash "$SETUP_SCRIPT" "$@" 2>&1
  }
  run_repo() { run_script "$1" --repo "stub-owner/stub-repo"; } # 既定形（--repo 明示）

  # 出力を 1 行へ畳む（case 照合・診断表示用）。tr はロケール依存で、captured 出力に
  # 不正なバイト列（bash 3.2 が変数名へ取り込んだマルチバイト先頭バイトなど。Issue #300）が
  # 混ざると "Illegal byte sequence" で畳み込みが途切れ、失敗診断そのものが読めなくなる。
  # 改行→縦棒はバイト単位の置換で足りるため LC_ALL=C に固定する。
  fold_lines() { printf '%s' "$1" | LC_ALL=C tr '\n' '|'; }

  # fold_lines の自己検証: 不正バイト（マルチバイト先頭バイト単独）が混ざっても畳み込みが
  # 途切れないこと。LC_ALL=C が外れて locale 依存へ退化すると、正常な出力では緑のまま
  # 「診断が必要な瞬間にだけ」壊れる — その退化をここで先に赤くする。
  fold_probe_in="$(printf 'x\357y\nz')"
  fold_probe_want="$(printf 'x\357y|z')"
  if [ "$(fold_lines "$fold_probe_in")" = "$fold_probe_want" ]; then
    ok "fold_lines が不正バイト入りの出力でも途切れず畳める（LC_ALL=C 固定・self-test）"
  else
    bad "fold_lines が不正バイト入りの出力で途切れる（LC_ALL=C が外れている疑い）"
  fi

  expect_success() { # $1: モード / $2: 期待する部分列（| 区切りへ畳んだ出力に対する） / $3: 検査名
    local out
    if ! out="$(run_repo "$1")"; then
      bad "${3}（非 0 で終了した）"
      return
    fi
    case "$(fold_lines "$out")" in
      *"$2"*) ok "$3" ;;
      *) bad "${3}（期待: ${2} / 実際: $(fold_lines "$out")）" ;;
    esac
  }

  # 非 0 終了・label create ゼロ・期待する診断文言、の 3 点で fail-closed を固定する。
  # 文言まで見るのは、空一覧と上限到達の診断が入れ替わる変異（原因の取り違え）を
  # 検出するため — SKILL.md の完了報告は原因の書き分けをこの文言に依存している。
  expect_failclosed() { # $1: モード / $2: 期待する診断の部分文字列 / $3: 検査名
    local out rc=0
    out="$(run_repo "$1")" || rc=$?
    if [ "$rc" -eq 0 ]; then
      bad "${3}（成功として終了した）"
      return
    fi
    case "$out" in
      *GH_LABEL_CREATE_ARGV*) bad "${3}（照会を信用できないのに label create が実行された）"; return ;;
    esac
    case "$out" in
      *"$2"*) ok "$3" ;;
      *) bad "${3}（診断文言が期待と違う。期待: ${2} / 実際: $(fold_lines "$out")）" ;;
    esac
  }

  # 不足分だけが作成され、作成が argv に載る（報告用の文字列だけではない）。
  # stub の一覧には near-miss の毒餌が混ざっている（実体と一覧は fixtures/gh-stub/gh
  # 冒頭のコメントが正本。ここに件数や名前を写すと片側だけ増えて drift する）。
  # membership 判定が部分一致へ退化すると、対応する名前が CREATED から消えて赤くなる。
  expect_success normal "CREATED=${EXPECTED_LABEL_NAMES}|" \
    "不足しているカスタムラベル ${EXPECTED_LABEL_COUNT} 件がすべて作成される（near-miss 既存名に部分一致しない）"
  out_normal="$(run_repo normal)" || true
  case "$out_normal" in
    *'GH_LABEL_CREATE_ARGV: label create major --repo stub-owner/stub-repo'*'--color D93F0B'*)
      ok "作成が報告用の文字列だけでなく gh の argv に載っている（--repo / --color 込み）" ;;
    *) bad "gh へ渡った argv に作成内容が載っていない（報告と実際の乖離）" ;;
  esac

  # 報告行は標準出力に出ること（SKILL.md の完了報告はこの行のパースに依存する。
  # 合流キャプチャだけだと printf が stderr へ移る変異が素通りする）
  out_stdout="$(PATH="$STUB_DIR:$PATH" GH_STUB_MODE=normal bash "$SETUP_SCRIPT" --repo "stub-owner/stub-repo" 2>/dev/null)" || true
  case "$(fold_lines "$out_stdout")" in
    *"CREATED=${EXPECTED_LABEL_NAMES}|"*) ok "CREATED= の報告行が標準出力側に出る" ;;
    *) bad "CREATED= の報告行が標準出力に無い（stderr へ逃げると完了報告が読めない）" ;;
  esac

  # 一部だけ既存: 既存はスキップされ、作成コマンドの対象にならない。終了コードも見る
  rc_partial=0
  out_partial="$(run_repo partial)" || rc_partial=$?
  if [ "$rc_partial" -ne 0 ]; then
    bad "一部既存の整備が非 0 で終了した"
  fi
  case "$(fold_lines "$out_partial")" in
    *"CREATED=${CREATED_WITHOUT_MAJOR_MINOR}"'|SKIPPED_EXISTING=major minor|'*)
      ok "既存ラベルはスキップされ、不足分だけが作成される" ;;
    *) bad "既存/不足の振り分けが期待と違う（実際: $(fold_lines "$out_partial")）" ;;
  esac
  case "$out_partial" in
    *'GH_LABEL_CREATE_ARGV: label create major'*|*'GH_LABEL_CREATE_ARGV: label create minor'*)
      bad "既存ラベルに対して label create が実行された（既存へ触れない契約に違反）" ;;
    *) ok "既存ラベルへは label create を実行しない" ;;
  esac

  # 大文字小文字違いの既存（Major / MINOR）: GitHub のラベル名一意制約は
  # case-insensitive なので、作りにいくと already exists で毎回失敗し冪等が破れる。
  # 既存側（スキップ）へ倒れることを固定する
  out_cv="$(run_repo casevariant)" || { bad "case 違い既存で非 0 終了した（冪等でない）"; out_cv=""; }
  if [ -n "$out_cv" ]; then
    case "$(fold_lines "$out_cv")" in
      *"CREATED=${CREATED_WITHOUT_MAJOR_MINOR}"'|SKIPPED_EXISTING=major minor|'*)
        ok "大文字小文字違いの既存ラベルはスキップへ倒れる（case-insensitive 照合）" ;;
      *) bad "case 違い既存の振り分けが期待と違う（実際: $(fold_lines "$out_cv")）" ;;
    esac
  fi

  # 全部既存: 何も作成せず成功（冪等）。全件スキップの報告内容まで固定する
  out_all="$(run_repo allexist)" || { bad "全ラベル既存で非 0 終了した（冪等でない）"; out_all=""; }
  if [ -n "$out_all" ]; then
    case "$out_all" in
      *GH_LABEL_CREATE_ARGV*) bad "全ラベル既存なのに label create が実行された" ;;
      *) ok "全ラベル既存なら 1 件も作成せず成功する（冪等）" ;;
    esac
    case "$(fold_lines "$out_all")" in
      *'CREATED=|'*"SKIPPED_EXISTING=${EXPECTED_LABEL_NAMES}|"*)
        ok "全件スキップが報告に列挙される（CREATED は空）" ;;
      *) bad "全件スキップの報告内容が期待と違う（実際: $(fold_lines "$out_all")）" ;;
    esac
  fi

  # --repo 省略時はカレントリポジトリ（gh repo view）で確定する経路が生きていること
  out_norepo="$(run_script normal)" || { bad "--repo 省略時に非 0 終了した"; out_norepo=""; }
  if [ -n "$out_norepo" ]; then
    case "$(fold_lines "$out_norepo")" in
      *'REPO=stub-owner/stub-repo'*) ok "--repo 省略時は gh repo view で対象を確定する" ;;
      *) bad "--repo 省略時の対象確定が期待と違う（実際: $(fold_lines "$out_norepo")）" ;;
    esac
  fi

  # 対象リポジトリを確定できなければ作成に進まない
  rc_nrv=0
  out_nrv="$(run_script norepoview)" || rc_nrv=$?
  if [ "$rc_nrv" -eq 0 ]; then
    bad "gh repo view が失敗しても成功として終了した"
  else
    case "$out_nrv" in
      *GH_LABEL_CREATE_ARGV*) bad "対象リポジトリ未確定のまま label create が実行された" ;;
      *) ok "対象リポジトリを確定できなければ 1 件も作成せず非 0 で終了する" ;;
    esac
  fi

  # 引数の fail-closed: 未知の余剰引数・値なし --repo は書き込みに進まず拒否する
  rc_extra=0
  out_extra="$(run_script normal --repo "stub-owner/stub-repo" --dry-run)" || rc_extra=$?
  if [ "$rc_extra" -ne 0 ] && [[ "$out_extra" != *GH_LABEL_CREATE_ARGV* ]]; then
    ok "未知の余剰引数（--dry-run 等）は黙って無視せず拒否する"
  else
    bad "未知の余剰引数が黙殺された（dry-run したつもりの本番書き込みを許す）"
  fi
  rc_noval=0
  out_noval="$(run_script normal --repo)" || rc_noval=$?
  if [ "$rc_noval" -ne 0 ] && [[ "$out_noval" != *GH_LABEL_CREATE_ARGV* ]]; then
    ok "値の無い --repo は拒否する"
  else
    bad "値の無い --repo が拒否されない"
  fi

  # 照会を信用できない 3 経路はすべて fail-closed（作成ゼロ + 非 0 + 原因どおりの診断）。
  # 期待部分列に対象リポジトリ名の埋め込みまで含める — set -u が外れた状態で変数が
  # 黙って空展開される変異（診断から repo 名が消える）もここで検出する。
  expect_failclosed fail "取得できませんでした（stub-owner/stub-repo）" "照会失敗では 1 件も作成せず非 0 で終了する（fail-closed）"
  expect_failclosed empty "空でした（stub-owner/stub-repo）" "空の一覧では 1 件も作成せず非 0 で終了する"
  expect_failclosed truncated "取得上限（200 件）に達しました（stub-owner/stub-repo）" "取得上限に達した一覧では 1 件も作成せず非 0 で終了する"

  # 作成失敗は握り潰さない
  out_cf=""
  rc_cf=0
  out_cf="$(run_repo createfail)" || rc_cf=$?
  if [ "$rc_cf" -ne 0 ]; then
    case "$(fold_lines "$out_cf")" in
      *"FAILED=${EXPECTED_LABEL_NAMES}"*) ok "作成失敗は FAILED= に列挙され非 0 で終了する" ;;
      *) bad "作成失敗が FAILED= に載っていない（実際: $(fold_lines "$out_cf")）" ;;
    esac
  else
    bad "label create が失敗しても成功として終了した（silent failure）"
  fi

  # 途中 1 件だけの作成失敗（Issue #625）: 成功分は CREATED、失敗分は FAILED に
  # 振り分け、失敗後も残りの試行を継続し、全体は非 0 で終了する。urgent（5 番目）を
  # 落とすので、CREATED が「urgent を除く全件」に完全一致することが「最初の失敗で
  # 蓄積・試行が止まる変異」の検出になる（urgent より後の 9 件が載らなくなる）。
  CREATED_WITHOUT_URGENT="$(derive_without 'urgent')"
  rc_cfo=0
  out_cfo="$(run_repo createfailone)" || rc_cfo=$?
  if [ "$rc_cfo" -eq 0 ]; then
    bad "1 件だけの作成失敗を成功として終了した（部分失敗の握りつぶし）"
  else
    case "$(fold_lines "$out_cfo")" in
      *"CREATED=${CREATED_WITHOUT_URGENT}"'|SKIPPED_EXISTING=|FAILED=urgent'*)
        ok "途中 1 件の失敗は FAILED へ振り分け、残りの試行を継続して非 0 で終了する" ;;
      *) bad "部分失敗の振り分け・継続が期待と違う（実際: $(fold_lines "$out_cfo")）" ;;
    esac
  fi
fi

# ---- 実行検査数の侵食ガード（Issue #625） ---------------------------------------
# 検査（ok 呼び出し）が丸ごと消えても、この suite には baseline が無く静かに緑の
# まま通る。全検査 green のランに限って総数の完全一致を要求する（fail-closed）。
# 条件付きにするのは flaky 回避のため: §4 の out_cv / out_all / out_norepo などは
# 失敗時に後続検査を落とすが、その失敗自体が FAIL を立てて suite を赤にするので、
# FAIL=0 のランでは実行される検査集合が常に同一になる。検査を増減したら更新する。
EXPECTED_CHECKS=61
echo ""
if [ "$FAIL" -gt 0 ]; then
  echo "✗ github-labels-setup verify: $FAIL 件失敗 / $PASS 件成功" >&2
  exit 1
fi
if [ "$PASS" -ne "$EXPECTED_CHECKS" ]; then
  echo "✗ github-labels-setup verify: 実行検査数が ${PASS} 件（期待 ${EXPECTED_CHECKS} 件）— 検査が黙って増減している（増減時は EXPECTED_CHECKS も更新すること）" >&2
  exit 1
fi
echo "✓ github-labels-setup verify: 全 $PASS 件 pass"
