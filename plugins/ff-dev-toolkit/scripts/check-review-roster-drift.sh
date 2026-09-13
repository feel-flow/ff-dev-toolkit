#!/usr/bin/env bash
# ============================================================================
# check-review-roster-drift.sh — レビュー凍結レーンの名簿が実体へ追随しているか
# ============================================================================
#
# `hooks/guard-review-in-flight.sh` は、レーンを取る subagent_type を**列挙**で持つ
# （`FF_REVIEW_SUBAGENT_LOCK_TYPES` の既定値）。列挙先の実体は**別プラグイン**の
# レビュアー群なので、そちらにレビュアーが増えても列挙は自動では追随しない。
# 「名簿から落ちているだけで契約は満たしている」形（= レーンを取らないレビュアーが
# 静かに増える）を検出するために、実体のディレクトリと列挙を突き合わせる。
#
# **なぜ hook 側で導出しないのか**: この hook は `Agent` 起動のたびに走る。実体の所在は
# ホストのプラグイン配置に依存し（cache / marketplace / 版ごとのディレクトリ）、走査は
# 毎回のコストと host 依存の失敗経路を持ち込む。実行時は列挙を持ち、**追随の検査だけを
# ここへ出す**分業にしている。
#
# 使い方:
#   bash check-review-roster-drift.sh --agents-dir <レビュアー実体のディレクトリ>
#                                     [--hook <guard-review-in-flight.sh のパス>]
#
# 終了コード:
#   0 = 一致（名簿 == 実体 − 除外）
#   1 = drift（増えた / 減った名前を列挙して報告）
#   2 = 判定不能（ディレクトリが無い・名簿を抽出できない・実体が 0 件）。
#       **「一致」へは倒さない** — 判定できないことを一致と読むと、この検査は名簿が
#       どれだけ腐っても緑を出し続ける
#
# 除外（名簿に載せない実体）は下の EXCLUDED_AGENTS に理由付きで持つ。実体側に在るのに
# 名簿に無い名前は、ここに載っていなければ drift として報告される。
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
HOOK_PATH="${SCRIPT_DIR}/../hooks/guard-review-in-flight.sh"
AGENTS_DIR=""
AGENT_PREFIX="pr-review-toolkit:"

# 共有ツリーを編集する前提のレビュアーは名簿から外す（自分のロックで自分の編集を
# 止めてしまうため。hook 本体の「レビュアー自身の編集は止めない」節と対になる）。
EXCLUDED_AGENTS="code-simplifier"

# 改行 1 文字。`$(printf '\n')` は command substitution が末尾改行を落として**空文字**に
# なり、`*""*` がすべての名前に一致する（実測: 正常なディレクトリが判定不能になった）。
NL=$'\n'

while [ $# -gt 0 ]; do
  case "$1" in
    --agents-dir)
      [ $# -ge 2 ] || { echo "ERROR: --agents-dir にはパスが必要です。" >&2; exit 2; }
      AGENTS_DIR="$2"; shift 2 ;;
    --agents-dir=*) AGENTS_DIR="${1#*=}"; shift ;;
    --hook)
      [ $# -ge 2 ] || { echo "ERROR: --hook にはパスが必要です。" >&2; exit 2; }
      HOOK_PATH="$2"; shift 2 ;;
    --hook=*) HOOK_PATH="${1#*=}"; shift ;;
    --prefix)
      [ $# -ge 2 ] || { echo "ERROR: --prefix には接頭辞が必要です。" >&2; exit 2; }
      AGENT_PREFIX="$2"; shift 2 ;;
    --prefix=*) AGENT_PREFIX="${1#*=}"; shift ;;
    -h | --help)
      sed -n '2,30p' "$0"; exit 0 ;;
    *)
      echo "ERROR: 未対応のオプション: $1" >&2; exit 2 ;;
  esac
done

if [ -z "$AGENTS_DIR" ]; then
  echo "ROSTER_CHECK=UNDETERMINED" >&2
  echo "REASON=--agents-dir が指定されていません（レビュアー実体の所在はホスト依存なので既定値を推測しない）" >&2
  exit 2
fi
if [ ! -d "$AGENTS_DIR" ]; then
  echo "ROSTER_CHECK=UNDETERMINED" >&2
  echo "REASON=レビュアー実体のディレクトリがありません: ${AGENTS_DIR}" >&2
  exit 2
fi
if [ ! -r "$HOOK_PATH" ]; then
  echo "ROSTER_CHECK=UNDETERMINED" >&2
  echo "REASON=hook を読めません: ${HOOK_PATH}" >&2
  exit 2
fi

# 名簿は hook の既定値から**抽出**する（ここへ書き写すと、hook を直したときにこの検査
# だけが古い名簿に対して緑を出す）。抽出できない形になったら判定不能で止める。
roster_line="$(sed -n 's/^REVIEW_LOCK_TYPES="\${FF_REVIEW_SUBAGENT_LOCK_TYPES:-\(.*\)}"$/\1/p' "$HOOK_PATH" | head -n 1)"
if [ -z "$roster_line" ]; then
  echo "ROSTER_CHECK=UNDETERMINED" >&2
  echo "REASON=hook から名簿の既定値を抽出できません（REVIEW_LOCK_TYPES の書き方が変わった可能性）: ${HOOK_PATH}" >&2
  exit 2
fi

# 名簿は glob を書ける契約（hook 側は set -f 付きで意図的に展開する）。ここで素のまま
# 分割すると、呼び出し元の cwd に在るファイル名が名簿の一員として読まれ、**cwd 次第で
# 判定が反転する**（実測: `pr-review-toolkit:*` の名簿 + cwd の同名ファイルで偽の DRIFT）。
set -f
roster="$(printf '%s\n' $roster_line | LC_ALL=C sort -u)" || roster=""
set +f
if [ -z "$roster" ]; then
  echo "ROSTER_CHECK=UNDETERMINED" >&2
  echo "REASON=名簿の整列に失敗しました（sort が使えない等）。読めない入力を「一致」と読まない" >&2
  exit 2
fi

# 実体は *.md のファイル名から導く。隠しファイル・サブディレクトリは対象外。
actual=""
found=0
for f in "$AGENTS_DIR"/*.md; do
  [ -f "$f" ] || continue
  found=$((found + 1))
  base="${f##*/}"
  base="${base%.md}"
  # 改行を含む名前は 1 件が複数行へ化け、行志向の突き合わせが別々のレビュアーとして
  # 数える（1 件の実体で名簿 2 件を満たせてしまう）。判定不能で止める。
  case "$base" in
    *"$NL"*)
      echo "ROSTER_CHECK=UNDETERMINED" >&2
      echo "REASON=レビュアー実体のファイル名に改行が含まれます: ${AGENTS_DIR}（行として突き合わせられない）" >&2
      exit 2
      ;;
  esac
  excluded=0
  for ex in $EXCLUDED_AGENTS; do
    [ "$base" = "$ex" ] && excluded=1
  done
  [ "$excluded" -eq 1 ] && continue
  actual="${actual}${AGENT_PREFIX}${base}
"
done
if [ "$found" -eq 0 ]; then
  echo "ROSTER_CHECK=UNDETERMINED" >&2
  echo "REASON=レビュアー実体が 1 件も見つかりません: ${AGENTS_DIR}/*.md（空ディレクトリを「名簿と一致」と読まない）" >&2
  exit 2
fi
actual="$(printf '%s' "$actual" | LC_ALL=C sort -u)" || actual=""
if [ -z "$actual" ]; then
  echo "ROSTER_CHECK=UNDETERMINED" >&2
  echo "REASON=実体の整列に失敗しました（sort が使えない等）。読めない入力を「一致」と読まない" >&2
  exit 2
fi

# comm も LC_ALL=C で回す。sort だけを C にすると、ロケールによっては整列済みの入力が
# disorder と判定され、一致している要素まで差分へ混ざる。
missing="$(LC_ALL=C comm -13 <(printf '%s\n' "$roster") <(printf '%s\n' "$actual"))" || missing="__ERROR__"
extra="$(LC_ALL=C comm -23 <(printf '%s\n' "$roster") <(printf '%s\n' "$actual"))" || extra="__ERROR__"
if [ "$missing" = "__ERROR__" ] || [ "$extra" = "__ERROR__" ]; then
  echo "ROSTER_CHECK=UNDETERMINED" >&2
  echo "REASON=突き合わせに失敗しました（comm が使えない等）。読めない入力を「一致」と読まない" >&2
  exit 2
fi

if [ -z "$missing" ] && [ -z "$extra" ]; then
  echo "ROSTER_CHECK=OK"
  echo "ROSTER_COUNT=$(printf '%s\n' "$roster" | grep -c .)"
  exit 0
fi

echo "ROSTER_CHECK=DRIFT" >&2
[ -n "$missing" ] && printf 'MISSING=%s\n' "$(printf '%s' "$missing" | tr '\n' ' ')" >&2
[ -n "$extra" ] && printf 'EXTRA=%s\n' "$(printf '%s' "$extra" | tr '\n' ' ')" >&2
echo "REASON=名簿（hook の REVIEW_LOCK_TYPES 既定値）が実体と食い違います。MISSING は名簿に足す候補、EXTRA は実体から消えた名前です（意図的に外すなら本スクリプトの EXCLUDED_AGENTS へ理由付きで足してください）" >&2
exit 1
