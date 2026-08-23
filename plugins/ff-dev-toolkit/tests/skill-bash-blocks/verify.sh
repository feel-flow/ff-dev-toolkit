#!/usr/bin/env bash
#
# SKILL.md の bash コードブロックに対する「パイプ入力の grep -q*」横断検査（Issue #234）。
#
# SKILL.md の bash ブロックはエージェントがそのまま実行する。`set -euo pipefail` の
# もとでパイプの下流に早期終了する grep -q* を置くと、一致した時点で grep が終了して
# 上流 producer が SIGPIPE (141) で死に、パイプライン全体が失敗扱いになる —
# つまり「一致したのに失敗」へ反転する fail-silent 事故になる（実例: out-of-scope-issue
# のラベル判定に混入し、レビューで検出された）。
#
# 検査範囲の分担:
#   - tests/**/*.sh のパイプ入力 grep -q* → tests/run-all/verify.sh case 10
#   - tracked shell の $VAR+マルチバイト → tests/run-all/verify.sh case 11
#     （実装: tests/lib/mbcs-guard.sh。fail-closed 自動回帰: mbcs-guard-failclosed）
#   - SKILL.md の bash 系コードブロック → 本 suite（grep -q* と MBCS。裸の $0 検査
#     も本 suite だが、対象はブロックではなくファイル全文 + commands/*.md）。対象は
#     plugins/*/skills/*/SKILL.md（全プラグインのスキル）、
#     plugins/*/docs-template/.github/skills/*/SKILL.md（配布テンプレートのスキル）、
#     リポジトリローカルの .claude/skills/*/SKILL.md（存在する場合のみ。公開 checkout
#     には無いので nullglob で自然に空になる）
#
# 検出はコードブロック内に限定する。散文中の注意書き（「パイプ入力の grep -q* は
# 使わないこと」等）や bash 以外のブロック（出力例の text ブロック等）は違反ではない。
# ファイルを直接読む grep -q*（上流 producer が無い）と `||` 直後の grep -q* も対象外。
# パイプ形は `|` に加えて `|&`（stderr 込み）、grep の別名 egrep / fgrep、
# `command` / `env` / `sudo` / 変数代入（`LC_ALL=C` 等）のプレフィックス、`--quiet` /
# `--silent` も検出する。
#
# 裸の $0 検査（Issue #776）: SKILL.md はスキル読み込み時に引数展開を受けるため、
# 本文中の裸の $0 は引数値へ置換される（実測: close-issue の awk の `line = $0` が
# `line = 774` に化け、Refs 抽出が 0 件のまま rc=0 → closing keyword ガードが丸ごと
# スキップされる fail-open）。awk の現在行は $(0)、shell のスクリプト名参照が要る
# 場合も $0 を直接書かない形へ退避する。説明文で言及するときは「ドル記号 + 0」の
# ように崩して書く（literal に書くと置換で文章側が壊れる）。
# 置換はフェンスの内外・言語タグ・コメント行のいずれにも依存しないため、この検査は
# **ファイル全文の全行**を対象にする（grep -q* / MBCS 検査と違いブロック抽出を
# しない）。braced 形 ${0} は置換されるか未実測だが、fail-closed 側に倒して検出
# 対象に含める。対象ファイルも SKILL.md に加えて plugins/*/commands/*.md（引数展開
# の本来の面。存在する checkout でのみ）を含める。
# 置換の実測記録（cache 0.41.0 の close-issue を引数 987654 で読み込み）: 置換された
# のは $ARGUMENTS と裸の $0 のみで、$1 / $2 は原文のまま残った。よって $1-$9 は本
# 検査の対象外（SKILL.md 内の shell/awk の $1 等は通常どおり書いてよい）。
#
# 既知の限界（保守側に倒す・変更時はこの一覧と fixture を更新すること）:
#   - オペランドの後ろに置いた -q（`grep -e "$pat" -q` 形）は非検出
#   - bash ブロック内の文字列リテラル・行末コメント内の言及は検出する（誤検出側。
#     禁止例を書くときは行頭コメントに置くこと）
#   - 言語タグは小文字完全一致（bash / sh / shell / zsh）。タグ無しブロックは対象外
#     （grep -q* / MBCS 検査のみ。$0 検査はフェンス抽出をせず全行を見る）
#   - 閉じられないままファイル末尾に達したフェンスは UNCLOSED_FENCE として構造違反に
#     する（後続の bash ブロックが静かに未検査になるのを防ぐ）
#
# 検出力は fixtures/ の変異 fixture で毎回実測する（違反 fixture が期待行で赤くならなければ
# 検査自体を fail-closed で落とす）。fixture の行番号を変えたら EXPECTED_VIOLATION_LINES も
# 併せて更新すること。
#
# 一時ディレクトリも jq / gh などの追加ツールも要らない（awk / sed / paste の POSIX
# 標準ユーティリティのみで動く）純粋なファイル検査なので、書き込み不可の環境でも
# 完走する。

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
PLUGINS_DIR="$(cd "$PLUGIN_ROOT/.." && pwd)"
REPO_ROOT="$(cd "$PLUGINS_DIR/.." && pwd)"
FIXTURES_DIR="$SCRIPT_DIR/fixtures"
# shellcheck source=../lib/mbcs-guard.sh
. "$SCRIPT_DIR/../lib/mbcs-guard.sh"

PASS=0
FAIL=0
ok()  { echo "  ✓ $1"; PASS=$((PASS + 1)); }
bad() { echo "  ✗ $1" >&2; FAIL=$((FAIL + 1)); }

# Markdown のコードフェンス（``` / ~~~、3 連以上、インデント許容、閉じは同種・同長以上）を
# 状態機械で追跡し、言語タグが bash / sh / shell / zsh のブロック内だけを検査する。
# 行末が `\` またはパイプで終わる行は次行と論理行として結合する（tests/run-all/verify.sh
# case 10 と同じ扱い）。行頭コメントは対象外。`||` は短絡演算子でありパイプではないので
# 照合前に潰す（awk の ERE に lookbehind が無いため）。violation は「開始行番号:論理行」、
# 閉じ忘れフェンスは「開始行番号:UNCLOSED_FENCE」で出力する。
scan_skill_bash_blocks() {
  awk '
    function check_logical(line, start,    work) {
      if (line ~ /^[[:space:]]*#/) return
      work = line
      gsub(/[|][|]/, " ", work)
      if (work ~ /[|]&?[[:space:]]*((command|env|sudo)[[:space:]]+|[A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*[[:space:]]+)*([ef])?grep([[:space:]]+--?[A-Za-z][A-Za-z0-9=_-]*)*[[:space:]]+(-[A-Za-z]*q[A-Za-z]*|--quiet|--silent)([^A-Za-z0-9_=-]|$)/) {
        print start ":" line
      }
    }
    { sub(/\r$/, "") }
    in_block == 0 {
      if ($0 ~ /^[[:space:]]*(```|~~~)/) {
        fence = $0
        sub(/^[[:space:]]*/, "", fence)
        fence_char = substr(fence, 1, 1)
        fence_len = 0
        while (substr(fence, fence_len + 1, 1) == fence_char) fence_len++
        info = substr(fence, fence_len + 1)
        sub(/^[[:space:]]*/, "", info)
        sub(/[[:space:]].*$/, "", info)
        in_block = 1
        open_line = FNR
        is_bash = (info ~ /^(bash|sh|shell|zsh)$/) ? 1 : 0
        logical = ""
      }
      next
    }
    {
      stripped = $0
      sub(/^[[:space:]]*/, "", stripped)
      sub(/[[:space:]]*$/, "", stripped)
      if (stripped ~ /^(`+|~+)$/ && substr(stripped, 1, 1) == fence_char && length(stripped) >= fence_len) {
        if (logical != "") { check_logical(logical, start_line); logical = "" }
        in_block = 0
        next
      }
      if (is_bash == 0) next
      if (logical == "") { logical = $0; start_line = FNR } else { logical = logical " " $0 }
      if ($0 ~ /\\[[:space:]]*$/) { sub(/\\[[:space:]]*$/, " ", logical); next }
      if ($0 ~ /[|]&?[[:space:]]*$/) next
      check_logical(logical, start_line)
      logical = ""
    }
    END {
      if (in_block == 1) {
        if (logical != "") check_logical(logical, start_line)
        # 閉じ忘れフェンスは以降の全ブロックを飲み込み、bash ブロックが静かに
        # 未検査になる（負の主張の検査対象が無言で縮む）ため構造違反として報告する。
        print open_line ":UNCLOSED_FENCE フェンスが EOF まで閉じられていない"
      }
    }
  ' "$1"
}

# ファイル全文の行に現れる裸の $0（braced 形 ${0} 含む）を「行番号:行」で出力する。
# 置換はフェンスの内外を問わないため、フェンス追跡をせず全行を素通しで見る（論理行
# 結合も不要 — $0 は行をまたげない）。$(0) は $ の直後に 0 が続かないので一致しない。
scan_skill_dollar0() {
  awk '
    { sub(/\r$/, "") }
    /\$0|\$\{0/ { print FNR ":" $0 }
  ' "$1"
}

echo "== SKILL.md bash ブロックのパイプ入力 grep -q* 検査 =="

# ---- 自己検証（変異試験の恒久化） --------------------------------------------
# 違反 fixture が期待どおり赤くならない = 検出器が壊れている状態で本検査を先へ
# 進めない。負の主張（違反ゼロ）の検査は、検出力の正の主張を先に通す。
[ -f "$FIXTURES_DIR/violation.md" ] || { echo "✗ fixture がありません: $FIXTURES_DIR/violation.md" >&2; exit 1; }
[ -f "$FIXTURES_DIR/clean.md" ] || { echo "✗ fixture がありません: $FIXTURES_DIR/clean.md" >&2; exit 1; }

EXPECTED_VIOLATION_LINES="6 7 8 9 11 12 14 15 16 17 18 22 26 31"
actual_lines="$(scan_skill_bash_blocks "$FIXTURES_DIR/violation.md" | awk -F: '{ print $1 }' | paste -sd' ' -)" \
  || { echo "✗ 自己検証の scan パイプラインが失敗しました（violation.md）" >&2; exit 1; }
if [ "$actual_lines" = "$EXPECTED_VIOLATION_LINES" ]; then
  ok "違反 fixture の全違反を期待行で検出（${EXPECTED_VIOLATION_LINES}）"
else
  bad "違反 fixture の検出結果が期待と不一致（expected: '${EXPECTED_VIOLATION_LINES}' / actual: '${actual_lines}'）"
fi

clean_hits="$(scan_skill_bash_blocks "$FIXTURES_DIR/clean.md")" \
  || { echo "✗ 自己検証の scan が失敗しました（clean.md）" >&2; exit 1; }
if [ -z "$clean_hits" ]; then
  ok "非検出 fixture（散文言及・非 bash ブロック・行頭コメント・非パイプ・|| 右辺・ネストフェンス）を誤検出しない"
else
  bad "非検出 fixture を誤検出した:"
  printf '%s\n' "$clean_hits" | sed 's/^/    | /' >&2
fi

# ---- 自己検証: MBCS（Issue #311） --------------------------------------------
[ -f "$FIXTURES_DIR/mbcs-violation.md" ] || { echo "✗ fixture がありません: $FIXTURES_DIR/mbcs-violation.md" >&2; exit 1; }
[ -f "$FIXTURES_DIR/mbcs-clean.md" ] || { echo "✗ fixture がありません: $FIXTURES_DIR/mbcs-clean.md" >&2; exit 1; }

# 行番号: bash ブロック内の ng1 / ng2 / ng-cont 開始 / ng3（sh）
EXPECTED_MBCS_VIOLATION_LINES="6 8 9 18"
actual_mbcs_lines="$(mbcs_scan_bash_blocks "$FIXTURES_DIR/mbcs-violation.md" | awk -F: '{ print $1 }' | paste -sd' ' -)" \
  || { echo "✗ MBCS 自己検証の scan が失敗しました（mbcs-violation.md）" >&2; exit 1; }
if [ "$actual_mbcs_lines" = "$EXPECTED_MBCS_VIOLATION_LINES" ]; then
  ok "MBCS 違反 fixture の全違反を期待行で検出（${EXPECTED_MBCS_VIOLATION_LINES}）"
else
  bad "MBCS 違反 fixture の検出結果が期待と不一致（expected: '${EXPECTED_MBCS_VIOLATION_LINES}' / actual: '${actual_mbcs_lines}'）"
fi

mbcs_clean_hits="$(mbcs_scan_bash_blocks "$FIXTURES_DIR/mbcs-clean.md")" \
  || { echo "✗ MBCS 自己検証の scan が失敗しました（mbcs-clean.md）" >&2; exit 1; }
if [ -z "$mbcs_clean_hits" ]; then
  ok "MBCS 非検出 fixture（braced・ASCII 隣接・非 bash ブロック）を誤検出しない"
else
  bad "MBCS 非検出 fixture を誤検出した:"
  printf '%s\n' "$mbcs_clean_hits" | sed 's/^/    | /' >&2
fi

# ---- 自己検証: 裸の $0（Issue #776） ------------------------------------------
[ -f "$FIXTURES_DIR/dollar0-violation.md" ] || { echo "✗ fixture がありません: $FIXTURES_DIR/dollar0-violation.md" >&2; exit 1; }
[ -f "$FIXTURES_DIR/dollar0-clean.md" ] || { echo "✗ fixture がありません: $FIXTURES_DIR/dollar0-clean.md" >&2; exit 1; }

# 行番号: 散文 $0 / bash ブロック 3 行（コメント行含む）/ text ブロック /
# インライン code / braced 形 ${0}
EXPECTED_DOLLAR0_VIOLATION_LINES="3 6 7 8 12 15 17"
actual_dollar0_lines="$(scan_skill_dollar0 "$FIXTURES_DIR/dollar0-violation.md" | awk -F: '{ print $1 }' | paste -sd' ' -)" \
  || { echo "✗ \$0 自己検証の scan が失敗しました（dollar0-violation.md）" >&2; exit 1; }
if [ "$actual_dollar0_lines" = "$EXPECTED_DOLLAR0_VIOLATION_LINES" ]; then
  ok "\$0 違反 fixture の全違反を期待行で検出（${EXPECTED_DOLLAR0_VIOLATION_LINES}）"
else
  bad "\$0 違反 fixture の検出結果が期待と不一致（expected: '${EXPECTED_DOLLAR0_VIOLATION_LINES}' / actual: '${actual_dollar0_lines}'）"
fi

dollar0_clean_hits="$(scan_skill_dollar0 "$FIXTURES_DIR/dollar0-clean.md")" \
  || { echo "✗ \$0 自己検証の scan が失敗しました（dollar0-clean.md）" >&2; exit 1; }
if [ -z "$dollar0_clean_hits" ]; then
  ok "\$0 非検出 fixture（\$(0) 形式・崩した言及・\$1）を誤検出しない"
else
  bad "\$0 非検出 fixture を誤検出した:"
  printf '%s\n' "$dollar0_clean_hits" | sed 's/^/    | /' >&2
fi

# 非検出主張のデコイ実在確認: clean fixture から負荷担体（$(0) と $1）が消えると
# 「誤検出しない」が空主張になる。文字列の存在自体を正の主張として固定する。
if grep -F 'line = $(0)' "$FIXTURES_DIR/dollar0-clean.md" >/dev/null \
   && grep -F 'POS="$1"' "$FIXTURES_DIR/dollar0-clean.md" >/dev/null; then
  ok "\$0 非検出 fixture のデコイ（\$(0) / \$1）が実在する"
else
  bad "\$0 非検出 fixture のデコイが欠落しています（dollar0-clean.md を確認）"
fi

if [ "$FAIL" -gt 0 ]; then
  echo ""
  echo "✗ skill-bash-blocks verify: 検出器の自己検証に失敗（横断検査は実行しない）" >&2
  exit 1
fi

# ---- 全 SKILL.md 横断検査 ------------------------------------------------------
shopt -s nullglob
SKILL_FILES=(
  "$PLUGINS_DIR"/*/skills/*/SKILL.md
  "$PLUGINS_DIR"/*/docs-template/.github/skills/*/SKILL.md
  "$REPO_ROOT"/.claude/skills/*/SKILL.md
)
shopt -u nullglob

if [ "${#SKILL_FILES[@]}" -eq 0 ]; then
  echo "✗ SKILL.md が 1 件も見つかりません（検査対象ゼロは異常）: $PLUGINS_DIR" >&2
  exit 1
fi

# 正の主張: 混入実績のある skill（out-of-scope-issue）と配布テンプレート側のスキルが
# 検査対象に入っている。グロブの起点がずれて対象が静かに空振りする事故を防ぐ。
# （.claude/skills は私有 checkout 限定の任意対象なのでコントロールにしない）
control_skill=0
control_template=0
for file in "${SKILL_FILES[@]}"; do
  case "$file" in
    */ff-dev-toolkit/skills/out-of-scope-issue/SKILL.md) control_skill=1 ;;
    */ff-dev-toolkit/docs-template/.github/skills/skill-authoring-safety/SKILL.md) control_template=1 ;;
  esac
done
if [ "$control_skill" -eq 1 ]; then
  ok "検査対象に out-of-scope-issue/SKILL.md を含む（skills グロブの妥当性）"
else
  bad "検査対象に out-of-scope-issue/SKILL.md が含まれていません（skills グロブがずれている可能性）"
fi
if [ "$control_template" -eq 1 ]; then
  ok "検査対象に docs-template の skill-authoring-safety/SKILL.md を含む（テンプレート側グロブの妥当性）"
else
  bad "検査対象に docs-template/.github/skills/skill-authoring-safety/SKILL.md が含まれていません"
fi

violation_files=0
mbcs_violation_files=0
dollar0_violation_files=0
for file in "${SKILL_FILES[@]}"; do
  hits="$(scan_skill_bash_blocks "$file")" \
    || { echo "✗ scanner 自体が失敗しました: $file" >&2; exit 1; }
  if [ -n "$hits" ]; then
    violation_files=$((violation_files + 1))
    bad "${file#"$REPO_ROOT"/} の bash ブロックにパイプ入力の grep -q* か構造違反がある:"
    printf '%s\n' "$hits" | sed 's/^/    | /' >&2
    echo "    shell のパターンマッチ（case / [[ == ]]）、grep >/dev/null、grep -c のいずれかへ置換してください" >&2
  fi
  mbcs_hits="$(mbcs_scan_bash_blocks "$file")" \
    || { echo "✗ MBCS scanner 自体が失敗しました: $file" >&2; exit 1; }
  if [ -n "$mbcs_hits" ]; then
    mbcs_violation_files=$((mbcs_violation_files + 1))
    bad "${file#"$REPO_ROOT"/} の bash ブロックに \$VAR 直付けマルチバイトがある:"
    printf '%s\n' "$mbcs_hits" | sed 's/^/    | /' >&2
    echo "    \${VAR} 形式に置換してください（bash 3.2 + set -u で unbound variable になる）" >&2
  fi
done

# ---- $0 検査（対象は SKILL.md + commands/*.md、ファイル全文） -----------------
# commands/*.md はスラッシュコマンドの本文で、引数展開の本来の面。ff-dev-toolkit
# 自体は commands を持たず公開 checkout に存在保証が無いため、.claude/skills と
# 同じく「存在する checkout でのみ対象」とし、コントロールにはしない。
shopt -s nullglob
DOLLAR0_EXTRA_FILES=(
  "$PLUGINS_DIR"/*/commands/*.md
  "$REPO_ROOT"/.claude/commands/*.md
)
shopt -u nullglob
DOLLAR0_FILES=("${SKILL_FILES[@]}" ${DOLLAR0_EXTRA_FILES[@]+"${DOLLAR0_EXTRA_FILES[@]}"})

for file in "${DOLLAR0_FILES[@]}"; do
  dollar0_hits="$(scan_skill_dollar0 "$file")" \
    || { echo "✗ \$0 scanner 自体が失敗しました: $file" >&2; exit 1; }
  if [ -n "$dollar0_hits" ]; then
    dollar0_violation_files=$((dollar0_violation_files + 1))
    bad "${file#"$REPO_ROOT"/} に裸の \$0（または \${0}）がある（スキル読み込み時に引数値へ置換される）:"
    printf '%s\n' "$dollar0_hits" | sed 's/^/    | /' >&2
    echo "    コードでは awk の現在行を \$(0) にする等 \$0 を直接書かない形へ、説明文では「ドル記号 + 0」のように崩してください（Issue #776）" >&2
  fi
done

if [ "$violation_files" -eq 0 ]; then
  ok "全 ${#SKILL_FILES[@]} 件の SKILL.md の bash ブロックにパイプ入力の grep -q* が無い"
fi
if [ "$mbcs_violation_files" -eq 0 ]; then
  ok "全 ${#SKILL_FILES[@]} 件の SKILL.md の bash ブロックに \$VAR 直付けマルチバイトが無い"
fi
if [ "$dollar0_violation_files" -eq 0 ]; then
  ok "全 ${#DOLLAR0_FILES[@]} 件の SKILL.md / commands の全文に裸の \$0 が無い"
fi

echo ""
if [ "$FAIL" -gt 0 ]; then
  echo "✗ skill-bash-blocks verify: $FAIL 件失敗" >&2
  exit 1
fi
echo "✓ skill-bash-blocks verify: 全 $PASS 件 pass"
