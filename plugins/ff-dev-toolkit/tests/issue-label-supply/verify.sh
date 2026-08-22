#!/usr/bin/env bash
#
# 起票スキルが参照するラベル名と供給の照合ゲート（Issue #624）。
#
# `create-issue` / `out-of-scope-issue` が付与を試みるラベル名は verify-then-skip
# （実在するものだけ付ける）で処理されるため、供給側（`setup-github-labels.sh` の
# `LABEL_DEFS`）に無い名前を参照しても **起票は成功したままラベルだけ黙って落ちる**
# （Issue #621 / PR #622 で実際に起きた形。fail-soft の構造上、失敗として観測されない）。
# 既存の `issue-label-contract` は起票・refine スキル間で複製された契約テキストの
# 同期（ラベル付与手順・粒度チェック項目リスト）を照合するだけで、供給側との
# 包含関係は見ていない。本 suite がその主張を持つ:
#
#   参照ラベル ⊆ (LABEL_DEFS ∪ GitHub デフォルト allowlist)
#
# 単純な部分集合検査にできない理由: `bug` / `enhancement` / `documentation` は
# 「GitHub デフォルトをそのまま使う」方針で意図的に LABEL_DEFS に無い。allowlist の
# 正本は github-setup.md の「GitHubデフォルトラベル（そのまま使用）」表から導出する
# （本 suite に名前を直書きすると 4 箇所目の写しが生まれる）。
#
# 参照ラベルの抽出は 3 経路（ラベル名が散文の表とシェル代入に散っているため）:
#   1. ラベル系統表の行（`| type |` / `| priority |` / `| follow-up |`）の
#      バックティック内トークン。`feat:` のような conventional-commit プレフィックス
#      （末尾コロン）は除外する
#   2. `*_label="..."` 代入の非空リテラル（変数参照・空文字は除外）
#   3. `--label <素の名前>`（`--label "$var"` のような変数渡しは除外）
#
# 抽出が 0 件へ退化すると部分集合検査は空虚に緑になるため、ファイルごとの参照数を
# 固定し、抽出器は正・負の対照で先に自己検証する。供給側の抽出が 0 件へ退化した
# 場合は、参照側の全ラベルが「供給に無い」となって赤くなる（fail-closed）。
#
# 一時ファイルも jq / gh / yq も要らない純粋な静的検査。書き込み不可の環境でも完走する。
#
# 使い方: bash plugins/ff-dev-toolkit/tests/issue-label-supply/verify.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

CREATE_ISSUE="$PLUGIN_ROOT/skills/create-issue/SKILL.md"
OUT_OF_SCOPE="$PLUGIN_ROOT/skills/out-of-scope-issue/SKILL.md"
SETUP_SCRIPT="$PLUGIN_ROOT/docs-template/scripts/setup-github-labels.sh"
GITHUB_SETUP="$PLUGIN_ROOT/docs-template/05-operations/deployment/github-setup.md"

# ファイルごとの参照ラベル数（重複除去後）。スキルの参照を増減したときは必ず
# ここも直す。固定しないと、抽出が壊れて 0 件になっても「全参照が供給済み」で
# 緑になる。
EXPECTED_REFS_CREATE=9
EXPECTED_REFS_SCOPE=12
# GitHub デフォルトラベルは 9 件で安定している（GitHub 側の仕様）。github-setup.md の
# 表が黙って縮む・別の表を誤って読む退化をここで検出する。
EXPECTED_ALLOWLIST=9

PASS=0
FAIL=0
ok()  { echo "  ✓ $1"; PASS=$((PASS + 1)); }
bad() { echo "  ✗ $1" >&2; FAIL=$((FAIL + 1)); }

echo "== 起票スキルの参照ラベルと供給（LABEL_DEFS ∪ デフォルト allowlist）の照合 =="

for file in "$CREATE_ISSUE" "$OUT_OF_SCOPE" "$SETUP_SCRIPT" "$GITHUB_SETUP"; do
  [ -s "$file" ] || { echo "✗ 必須ファイルが無いか空です: $file" >&2; exit 1; }
done

# ---- 抽出器 3 種 ---------------------------------------------------------------

# 参照ラベルの抽出（3 経路）。重複あり・未ソートの改行区切りで返す。
extract_referenced() {
  awk '
    # 1) ラベル系統表の行。系統名（先頭セル）でアンカーし、他の表を拾わない。
    /^\|[[:space:]]*(type|priority|follow-up)[[:space:]]*\|/ {
      line = $0
      while (match(line, /`[^`]+`/)) {
        tok = substr(line, RSTART + 1, RLENGTH - 2)
        line = substr(line, RSTART + RLENGTH)
        # ラベル名の文法に一致し、かつ末尾コロン（`feat:` 等のプレフィックス例示）
        # でないものだけ。`priority:*` のようなワイルドカードは文法で落ちる。
        if (tok ~ /^[a-z][a-z0-9:-]*$/ && tok !~ /:$/) print tok
      }
      next
    }
    # 2) *_label="..." 代入の非空リテラル。値に $ を含む（変数参照）行は対象外。
    /^[[:space:]]*[a-z_]*_label="[^"$]+"[[:space:]]*$/ {
      line = $0
      sub(/^[[:space:]]*[a-z_]*_label="/, "", line)
      sub(/"[[:space:]]*$/, "", line)
      if (line ~ /^[a-z][a-z0-9:-]*$/) print line
      next
    }
    # 3) --label <素の名前>。--label "$var" は [a-z] 始まりでないため一致しない。
    {
      line = $0
      while (match(line, /--label [a-z][a-z0-9:-]*/)) {
        print substr(line, RSTART + 8, RLENGTH - 8)
        line = substr(line, RSTART + RLENGTH)
      }
    }
  ' "$1"
}

# 供給側（SSOT）: LABEL_DEFS ブロックからラベル名だけを取り出す。
# 正規表現は github-labels-setup/verify.sh の extract_script_defs と同じ制約
# （コロン入りの名前空間を通す）を持つ。
extract_supply_names() {
  awk '
    /^# LABEL_DEFS_BEGIN$/ { on = 1; next }
    /^# LABEL_DEFS_END$/   { on = 0 }
    on {
      line = $0
      sub(/^LABEL_DEFS='\''/, "", line)
      sub(/'\''$/, "", line)
      if (line ~ /^[a-z][a-z:-]*\|[0-9A-Fa-f]{6}\|/) {
        sub(/\|.*$/, "", line)
        print line
      }
    }
  ' "$1"
}

# allowlist: github-setup.md の「GitHubデフォルトラベル（そのまま使用）」表の
# ラベル名。次の見出しまでにスコープする（カスタムラベル表を混ぜない —
# 混ざると LABEL_DEFS の欠落が allowlist 側で吸収され、検査が空洞化する）。
extract_default_allowlist() {
  awk -F'|' '
    /^#### GitHubデフォルトラベル/ { on = 1; next }
    on && /^#/ { on = 0 }
    on && $0 ~ /^\|[[:space:]]*`/ {
      name = $2
      gsub(/`/, "", name)
      gsub(/^[[:space:]]+/, "", name); gsub(/[[:space:]]+$/, "", name)
      print name
    }
  ' "$1"
}

sort_unique() { printf '%s\n' "$1" | awk 'NF' | sort -u; }
count_lines() { [ -z "$1" ] && echo 0 || printf '%s\n' "$1" | wc -l | tr -d '[:space:]'; }

# 改行区切り集合への行単位の含有判定。`printf | grep -q` は一致時点で上流が
# SIGPIPE で落ち、pipefail 下で「一致したのに失敗」へ反転しうるため使わない
# （run-all の case 10 が再混入をガードしている）。
has_member() { [[ $'\n'"$1"$'\n' == *$'\n'"$2"$'\n'* ]]; }

# 供給集合に無い参照ラベルを列挙する（空なら包含成立）。
missing_from_supply() { # $1: 参照（改行区切り） / $2: 供給（改行区切り）
  printf '%s\n' "$2" | awk '
    NR == FNR { supply[$0] = 1; next }
    NF && !($0 in supply) { print $0 }
  ' - <(printf '%s\n' "$1")
}

# ラベル系統表（ヘッダ先頭セルが「系統」の表）のデータ行のうち、抽出アンカー
# （type / priority / follow-up）に無い系統名を列挙する。スキルに新しい系統行が
# 増えると、その行の参照は抽出の外へ出て包含検査が素通りするため、未知の系統名を
# 赤にする（run-all の登録漏れゲートと同型の侵食ガード）。
unknown_lineage_rows() {
  awk '
    /^\|[[:space:]]*系統[[:space:]]*\|/ { in_t = 1; next }
    in_t && /^\|[[:space:]:-]*\|/ { next }
    in_t && /^\|/ {
      cell = $0
      sub(/^\|[[:space:]]*/, "", cell)
      sub(/[[:space:]]*\|.*$/, "", cell)
      if (cell != "type" && cell != "priority" && cell != "follow-up") print FNR ": " cell
      next
    }
    in_t { in_t = 0 }
  ' "$1"
}

# ---- 自己検証（抽出器・比較器が本当に見ているかを先に確かめる） -----------------

# 正の対照 1: 表の行からラベル名（数字入り含む）を拾い、末尾コロンのプレフィックス
# 例示を除外する。`p1` は数字を落とす文法退化（[a-z0-9] → [a-z]）の canary。
table_probe="$(extract_referenced <(printf '| type | x（例: `bug` ↔ `fix:`） | `foo-label` / `priority:probe` / `p1` |\n'))"
if [ "$(sort_unique "$table_probe")" = "$(printf 'bug\nfoo-label\np1\npriority:probe')" ]; then
  ok '自己検証: 表の行からラベル名（数字入り含む）を拾い、`fix:` 形式のプレフィックスを除外する'
else
  bad "自己検証: 表の抽出が期待と違う（実際: $(printf '%s' "$table_probe" | tr '\n' ' ')）"
fi

# 正の対照 2: 代入の非空リテラルを拾い、空文字・変数参照を除外する。
assign_probe="$(extract_referenced <(printf 'followup_label="follow-up"\ntype_label=""\nx_label="$var"\n'))"
if [ "$assign_probe" = "follow-up" ]; then
  ok "自己検証: 代入の非空リテラルだけを拾う（空文字・変数参照は除外）"
else
  bad "自己検証: 代入の抽出が期待と違う（実際: $(printf '%s' "$assign_probe" | tr '\n' ' ')）"
fi

# 正の対照 3: --label の素の名前を拾い、変数渡しを除外する。
label_probe="$(extract_referenced <(printf 'x `gh issue list --label epic --state open` y\nlabel_args+=(--label "$candidate")\n'))"
if [ "$label_probe" = "epic" ]; then
  ok "自己検証: --label の素の名前だけを拾う（変数渡しは除外）"
else
  bad "自己検証: --label の抽出が期待と違う（実際: $(printf '%s' "$label_probe" | tr '\n' ' ')）"
fi

# 負の対照 1: アンカーを持たないファイルからは 1 行も採れないこと。setup スクリプトは
# ラベル名を大量に含むが、表アンカー・*_label= 代入・素の --label のいずれも持たない。
if [ -n "$(extract_referenced "$SETUP_SCRIPT")" ]; then
  bad "自己検証: アンカーの無いファイルから参照を抽出できてしまった"
else
  ok "自己検証: アンカーの無いファイル（setup スクリプト）からは参照を抽出しない"
fi

# 負の対照 2: 抽出しない引用形式を意図として固定する。単引用の代入・`--label=` 形式・
# 引用付き `--label "name"` は現行スキルに存在せず、抽出対象外（拾えないのは仕様）。
# スキル側がこれらの形式へ書き換わると参照が検査の外へ出るため、この対照が
# 「意図した除外」と「抽出器の退化」を区別する記録になる。
quote_probe="$(extract_referenced <(printf 'followup_label='"'"'follow-up'"'"'\ngh issue edit --label=epic\ngh issue edit --label "epic"\n'))"
if [ -z "$quote_probe" ]; then
  ok '自己検証: 単引用代入・--label= 形式・引用付き --label は抽出しない（意図した除外の固定）'
else
  bad "自己検証: 除外対象の引用形式から抽出された（実際: $(printf '%s' "$quote_probe" | tr '\n' ' ')）"
fi

# 比較器の対照: 供給に無い参照を本当に検出できること（常に空を返す退化の検出）。
if [ -n "$(missing_from_supply 'zzz-not-supplied' 'bug')" ]; then
  ok "自己検証: 比較器が供給に無い参照を検出できる"
else
  bad "自己検証: 比較器が欠落を検出できない — 常に包含成立を返している"
fi
# near-miss の対照: 部分一致への退化（follow ⊆ follow-up で包含成立と誤認）を検出する。
if [ -n "$(missing_from_supply 'follow' 'follow-up')" ]; then
  ok "自己検証: 比較器が near-miss（follow vs follow-up）を包含と誤認しない（行単位一致）"
else
  bad "自己検証: 比較器が部分一致へ退化している（follow が follow-up で充足された）"
fi

# 侵食ガードの対照: 未知の系統行を検出でき、既知の系統行と区切り行は素通りしないこと。
lineage_probe="$(unknown_lineage_rows <(printf '| 系統 | 役割 |\n|------|------|\n| type | x |\n| scope | y |\n'))"
if [ "$lineage_probe" = "4: scope" ]; then
  ok "自己検証: 系統表の未知の行（scope）を検出し、既知の行・区切り行を誤検出しない"
else
  bad "自己検証: 系統表ガードの検出が期待と違う（実際: $(printf '%s' "$lineage_probe" | tr '\n' ' ')）"
fi

if [ "$FAIL" -gt 0 ]; then
  echo ""
  echo "✗ issue-label-supply verify: 検出器の自己検証に失敗（本検査は実行しない）" >&2
  exit 1
fi

# ---- 1. 供給側の導出 ------------------------------------------------------------
supply="$(extract_supply_names "$SETUP_SCRIPT")"
allowlist="$(extract_default_allowlist "$GITHUB_SETUP")"

# 供給の抽出が壊れていないことの canary。コロン入り（priority:*）の欠落は抽出正規表現
# からコロンを落とす変異で起きる（github-labels-setup の colon_probe と同じ理由）。
for canary in follow-up priority:critical; do
  if has_member "$supply" "$canary"; then
    ok "供給（LABEL_DEFS）の抽出が ${canary} を含む（canary）"
  else
    bad "供給（LABEL_DEFS）の抽出に ${canary} が無い — 抽出が壊れているか定義が黙って消えている"
  fi
done

allowlist_count="$(count_lines "$allowlist")"
if [ "$allowlist_count" -eq "$EXPECTED_ALLOWLIST" ]; then
  ok "デフォルト allowlist が ${EXPECTED_ALLOWLIST} 件（github-setup.md のデフォルト表から導出）"
else
  bad "デフォルト allowlist が ${allowlist_count} 件（期待 ${EXPECTED_ALLOWLIST} 件）— 表の抽出が壊れているか表が変わっている"
fi
if has_member "$allowlist" "bug"; then
  ok "デフォルト allowlist が bug を含む（canary）"
else
  bad "デフォルト allowlist に bug が無い — 別の表を読んでいる疑い"
fi

supply_union="$(printf '%s\n%s\n' "$supply" "$allowlist" | awk 'NF' | sort -u)"

# ---- 2. 参照側の抽出と件数固定 ---------------------------------------------------
refs_create="$(sort_unique "$(extract_referenced "$CREATE_ISSUE")")"
refs_scope="$(sort_unique "$(extract_referenced "$OUT_OF_SCOPE")")"

for pair in "create-issue:$EXPECTED_REFS_CREATE:$(count_lines "$refs_create")" \
            "out-of-scope-issue:$EXPECTED_REFS_SCOPE:$(count_lines "$refs_scope")"; do
  name="${pair%%:*}"; rest="${pair#*:}"
  want="${rest%%:*}"; got="${rest##*:}"
  if [ "$got" -eq "$want" ]; then
    ok "${name} の参照ラベルが ${want} 件（増減時は EXPECTED_REFS_* も更新すること）"
  else
    bad "${name} の参照ラベルが ${got} 件（期待 ${want} 件）— 抽出が壊れているか参照が黙って増減している"
  fi
done

# 系統表の侵食ガード: 未知の系統行が増えていないこと（増えるとその行の参照が
# 抽出の外へ出て、包含検査が素通りする）。
for pair in "create-issue:$CREATE_ISSUE" "out-of-scope-issue:$OUT_OF_SCOPE"; do
  name="${pair%%:*}"; file="${pair#*:}"
  unknown="$(unknown_lineage_rows "$file")"
  if [ -z "$unknown" ]; then
    ok "${name} の系統表に抽出アンカー外の系統行が無い"
  else
    bad "${name} の系統表に未知の系統行がある（抽出されず包含検査の外に出る。行: ${unknown//$'\n'/, }）— アンカーと EXPECTED_REFS_* を同時に更新すること"
  fi
done

# ---- 3. 包含の主張: 参照 ⊆ (LABEL_DEFS ∪ allowlist) -----------------------------
for pair in "create-issue:$refs_create" "out-of-scope-issue:$refs_scope"; do
  name="${pair%%:*}"; refs="${pair#*:}"
  missing="$(missing_from_supply "$refs" "$supply_union")"
  if [ -z "$missing" ]; then
    ok "${name} の全参照ラベルが供給されている（LABEL_DEFS ∪ デフォルト allowlist）"
  else
    bad "${name} が供給されていないラベルを参照している（起票は成功するがラベルだけ黙って落ちる）:"
    printf '%s\n' "$missing" | sed 's/^/    | /' >&2
  fi
done

# ---- 4. Issue #621 / #624 の残件だった testing の供給を名指しで固定 ----------------
# 包含検査（上）に含意されるが、この 1 件は「参照されているのに供給ゼロ」が
# PR #622 の後も残っていた実例なので、退行時に原因が直読みできるよう名指しする。
if has_member "$refs_scope" "testing"; then
  ok 'out-of-scope-issue が testing を参照している（type 系統の `test:` 対応）'
else
  bad "out-of-scope-issue の参照から testing が消えている（参照を落とす変更は EXPECTED_REFS_SCOPE と同時に見直すこと）"
fi
if has_member "$supply" "testing"; then
  ok "testing が LABEL_DEFS に供給されている（Issue #624 で 13 → 14 件へ追加）"
else
  bad "testing が LABEL_DEFS に無い（参照だけが残ると Issue #621 の黙落が再発する）"
fi

echo ""
if [ "$FAIL" -gt 0 ]; then
  echo "✗ issue-label-supply verify: $FAIL 件失敗 / $PASS 件成功" >&2
  exit 1
fi
echo "✓ issue-label-supply verify: 全 $PASS 件 pass"
