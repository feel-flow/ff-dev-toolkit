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
#   - tests/**/*.sh → tests/run-all/verify.sh case 10
#   - SKILL.md の bash 系コードブロック → 本 suite。対象は
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
# 既知の限界（保守側に倒す・変更時はこの一覧と fixture を更新すること）:
#   - オペランドの後ろに置いた -q（`grep -e "$pat" -q` 形）は非検出
#   - bash ブロック内の文字列リテラル・行末コメント内の言及は検出する（誤検出側。
#     禁止例を書くときは行頭コメントに置くこと）
#   - 言語タグは小文字完全一致（bash / sh / shell / zsh）。タグ無しブロックは対象外
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
for file in "${SKILL_FILES[@]}"; do
  hits="$(scan_skill_bash_blocks "$file")" \
    || { echo "✗ scanner 自体が失敗しました: $file" >&2; exit 1; }
  if [ -n "$hits" ]; then
    violation_files=$((violation_files + 1))
    bad "${file#"$REPO_ROOT"/} の bash ブロックにパイプ入力の grep -q* か構造違反がある:"
    printf '%s\n' "$hits" | sed 's/^/    | /' >&2
    echo "    shell のパターンマッチ（case / [[ == ]]）、grep >/dev/null、grep -c のいずれかへ置換してください" >&2
  fi
done

if [ "$violation_files" -eq 0 ]; then
  ok "全 ${#SKILL_FILES[@]} 件の SKILL.md の bash ブロックにパイプ入力の grep -q* が無い"
fi

echo ""
if [ "$FAIL" -gt 0 ]; then
  echo "✗ skill-bash-blocks verify: $FAIL 件失敗" >&2
  exit 1
fi
echo "✓ skill-bash-blocks verify: 全 $PASS 件 pass"
