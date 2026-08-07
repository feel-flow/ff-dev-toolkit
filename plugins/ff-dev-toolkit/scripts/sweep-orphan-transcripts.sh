#!/usr/bin/env bash
# sweep-orphan-transcripts.sh — 既存の孤児 Claude Code トランスクリプトを回収する
#
# Issue #280 / 公開 feel-flow/ff-dev-toolkit#8 の残課題。
# /merge-cleanup Step 5.5 は「今回削除した worktree の分」だけを回収する。
# 本スクリプトは <config>/projects/ 全体を走査し、jsonl の cwd がすべて
# 現存しないディレクトリだけを候補にする（証拠が無いものは触らない）。
#
# 既定は dry-run（一覧と見込み容量のみ）。破壊は --apply を明示したときだけ。
#
# 使い方:
#   bash scripts/sweep-orphan-transcripts.sh              # dry-run
#   bash scripts/sweep-orphan-transcripts.sh --apply      # アーカイブ + 元削除
#   bash scripts/sweep-orphan-transcripts.sh --help
#
# 環境変数:
#   CLAUDE_CONFIG_DIR                 既定 ~/.claude
#   FF_SWEEP_PROJECTS_DIR             projects の上書き
#   FF_SWEEP_ARCHIVE_DIR              アーカイブ先（既定 <config>/transcript-archives）
#
# 終了コード:
#   0  成功（dry-run / 回収完了 / 候補 0）
#   1  失敗（走査エラー・アーカイブ失敗など 1 件以上）
#   2  用法エラー
#
# bash 3.2 互換（macOS 標準 /bin/bash）。

set -euo pipefail

MODE="dry-run"
while [ $# -gt 0 ]; do
  case "$1" in
    --apply) MODE="apply"; shift ;;
    --dry-run) MODE="dry-run"; shift ;;
    -h|--help)
      sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *)
      echo "ERROR: unknown argument: $1（--apply / --dry-run / --help のみ）" >&2
      exit 2
      ;;
  esac
done

resolve_dir() {
  ( cd "$1" 2>/dev/null && pwd -P ) || return 1
}

# $1: 候補ディレクトリ
# 戻り値:
#   0 = 孤児（cwd は 1 件以上あり、いずれも現存しない）
#   2 = cwd を記録した jsonl が無い（触らない）
#   3 = 現存する cwd がある（稼働中の可能性 → 触らない）
#   4 = 走査エラー（触らない + 失敗報告）
collect_cwds() {
  local dir="$1"
  local scan_err="$WORK_TMP/scan_err"
  local values="" line="" value=""

  : > "$scan_err"
  : > "$WORK_TMP/cwds"
  values="$( { find "$dir" -type f -name '*.jsonl' -exec grep -oh '"cwd":"[^"]*"' {} + | sort -u ; } 2>"$scan_err" )" || true
  if [ -s "$scan_err" ]; then
    return 4
  fi
  [ -n "$values" ] || return 2

  while IFS= read -r line; do
    [ -n "$line" ] || continue
    value="${line#\"cwd\":\"}"
    value="${value%\"}"
    [ -n "$value" ] || continue
    printf '%s\n' "$value" >> "$WORK_TMP/cwds"
  done <<< "$values"

  [ -s "$WORK_TMP/cwds" ] || return 2

  while IFS= read -r value; do
    [ -n "$value" ] || continue
    # 存在するディレクトリが 1 つでもあれば live
    if [ -d "$value" ]; then
      return 3
    fi
  done < "$WORK_TMP/cwds"

  return 0
}

dir_kb() {
  local kb=""
  kb="$(du -sk "$1" 2>/dev/null | awk 'NR == 1 { print $1 }')" || kb=""
  if [ -z "$kb" ]; then
    echo 0
  else
    echo "$kb"
  fi
}

archive_and_remove() {
  # $1: CAND_NAME  $2: CAND_PATH  $3: CAND_REAL  $4: PROJECTS_REAL  $5: ARCHIVE_DIR
  local CAND_NAME="$1" CAND_PATH="$2" CAND_REAL="$3" PROJECTS_REAL="$4" ARCHIVE_DIR="$5"
  local CAND_KB ARCHIVE_STAMP ARCHIVE_FILE ARCHIVE_SEQ ARCHIVE_TMP
  local ARCHIVE_LIST ARCHIVE_ERR ARCHIVE_MARKER TAR_OUT ARCHIVE_FAIL
  local SRC_ENTRIES ARC_ENTRIES RECHECK_REAL ARCHIVE_KB

  CAND_KB="$(dir_kb "$CAND_REAL")"

  ARCHIVE_STAMP="$(date +%Y%m%d-%H%M%S)"
  ARCHIVE_FILE="$ARCHIVE_DIR/$CAND_NAME-$ARCHIVE_STAMP.tar.gz"
  ARCHIVE_SEQ=1
  while [ -e "$ARCHIVE_FILE" ] || [ -L "$ARCHIVE_FILE" ]; do
    ARCHIVE_FILE="$ARCHIVE_DIR/$CAND_NAME-$ARCHIVE_STAMP-$ARCHIVE_SEQ.tar.gz"
    ARCHIVE_SEQ=$((ARCHIVE_SEQ + 1))
  done

  ARCHIVE_TMP=""
  if ! ARCHIVE_TMP="$(mktemp "$ARCHIVE_DIR/.sweep-orphan-archive-XXXXXX")"; then
    echo "  ❌ 作業ファイルを作成できません: $CAND_NAME" >&2
    return 1
  fi
  ARCHIVE_LIST="$WORK_TMP/archive_list"
  ARCHIVE_ERR="$WORK_TMP/archive_error"
  ARCHIVE_MARKER="$WORK_TMP/archive_marker"
  : > "$ARCHIVE_MARKER"
  TAR_OUT=""
  ARCHIVE_FAIL=""

  if ! TAR_OUT="$(tar -czf "$ARCHIVE_TMP" -C "$PROJECTS_REAL" "./$CAND_NAME" 2>&1)"; then
    ARCHIVE_FAIL="tar が失敗しました"
  elif ! tar -tzf "$ARCHIVE_TMP" > "$ARCHIVE_LIST" 2>"$ARCHIVE_ERR"; then
    TAR_OUT="$(cat "$ARCHIVE_ERR")"
    ARCHIVE_FAIL="アーカイブを読み直せませんでした"
  else
    SRC_ENTRIES=""
    SRC_ENTRIES="$(find "$CAND_REAL" ! -type d 2>/dev/null | wc -l | tr -d ' ')" || SRC_ENTRIES=""
    ARC_ENTRIES="$(grep -cv '/$' "$ARCHIVE_LIST" || true)"
    if [ -z "$SRC_ENTRIES" ] || [ "$SRC_ENTRIES" != "$ARC_ENTRIES" ]; then
      TAR_OUT="元 ${SRC_ENTRIES:-?} 件 / アーカイブ ${ARC_ENTRIES} 件"
      ARCHIVE_FAIL="アーカイブの件数が元と一致しません"
    elif [ -n "$(find "$CAND_REAL" ! -type d -newer "$ARCHIVE_MARKER" -print -quit 2>/dev/null)" ]; then
      TAR_OUT="アーカイブ中に更新されたファイルがあります"
      ARCHIVE_FAIL="アーカイブ中に元が変更されました"
    fi
  fi

  if [ -n "$ARCHIVE_FAIL" ]; then
    echo "  ❌ ${ARCHIVE_FAIL}。元は残します: $CAND_NAME" >&2
    printf '%s\n' "$TAR_OUT" | sed 's/^/     /' >&2 || true
    rm -f "$ARCHIVE_TMP" || true
    return 1
  fi

  if ! mv "$ARCHIVE_TMP" "$ARCHIVE_FILE"; then
    echo "  ❌ アーカイブの確定に失敗。元は残します: $CAND_NAME" >&2
    rm -f "$ARCHIVE_TMP" || true
    return 1
  fi

  RECHECK_REAL=""
  if [ -L "$CAND_PATH" ] \
    || ! RECHECK_REAL="$(resolve_dir "$CAND_PATH")" \
    || [ "$RECHECK_REAL" != "$CAND_REAL" ] \
    || [ "$(dirname "$RECHECK_REAL")" != "$PROJECTS_REAL" ]; then
    echo "  ⚠️ 削除直前の再確認に失敗したため元は残します: $CAND_NAME" >&2
    echo "     アーカイブは作成済み: $ARCHIVE_FILE" >&2
    return 1
  fi

  if ! rm -rf "$CAND_REAL"; then
    echo "  ❌ アーカイブ後の削除に失敗（二重残存）: $CAND_REAL" >&2
    return 1
  fi

  ARCHIVE_KB="$(dir_kb "$ARCHIVE_FILE")"
  echo "  ✓ archived: $CAND_NAME (${CAND_KB} KB → ${ARCHIVE_KB} KB)"
  ARCHIVED_KB=$((ARCHIVED_KB + CAND_KB))
  ARCHIVE_OUT_KB=$((ARCHIVE_OUT_KB + ARCHIVE_KB))
  ARCHIVED_COUNT=$((ARCHIVED_COUNT + 1))
  return 0
}

WORK_TMP=""
WORK_TMP="$(mktemp -d "${TMPDIR:-/tmp}/sweep-orphan-XXXXXX")" || {
  echo "ERROR: 一時ディレクトリを作成できません" >&2
  exit 1
}
trap 'rm -rf "$WORK_TMP"' EXIT

CLAUDE_HOME="${CLAUDE_CONFIG_DIR:-${HOME:-}/.claude}"
PROJECTS_DIR="${FF_SWEEP_PROJECTS_DIR:-$CLAUDE_HOME/projects}"
ARCHIVE_DIR="${FF_SWEEP_ARCHIVE_DIR:-$CLAUDE_HOME/transcript-archives}"

PROJECTS_REAL=""
if ! PROJECTS_REAL="$(resolve_dir "$PROJECTS_DIR")"; then
  echo "ERROR: projects ディレクトリを解決できません: $PROJECTS_DIR" >&2
  exit 1
fi

echo "🗂 孤児トランスクリプト sweep"
echo "   mode: $MODE"
echo "   projects: $PROJECTS_REAL"
echo "   archive: $ARCHIVE_DIR"
echo ""

ORPHAN_COUNT=0
ORPHAN_KB=0
SKIP_LIVE=0
SKIP_NO_CWD=0
SKIP_SYMLINK=0
SKIP_PATH=0
FAIL_COUNT=0
ARCHIVED_COUNT=0
ARCHIVED_KB=0
ARCHIVE_OUT_KB=0
ARCHIVE_DIR_READY=0

# projects 直下だけ（サブディレクトリの再帰は projects の構造上不要）
# bash 3.2: mapfile 無し。nullglob 相当は手動。
shopt -s nullglob
for CAND_PATH in "$PROJECTS_DIR"/*; do
  CAND_NAME="$(basename "$CAND_PATH")"
  case "$CAND_NAME" in
    ''|.|..) continue ;;
  esac

  if [ ! -d "$CAND_PATH" ]; then
    continue
  fi

  if [ -L "$CAND_PATH" ]; then
    SKIP_SYMLINK=$((SKIP_SYMLINK + 1))
    continue
  fi

  CAND_REAL=""
  if ! CAND_REAL="$(resolve_dir "$CAND_PATH")" \
    || [ "$(dirname "$CAND_REAL")" != "$PROJECTS_REAL" ]; then
    SKIP_PATH=$((SKIP_PATH + 1))
    echo "  ○ projects 直下へ解決されないためスキップ: $CAND_NAME"
    continue
  fi

  VERDICT=0
  collect_cwds "$CAND_REAL" || VERDICT=$?
  case "$VERDICT" in
    0)
      KB="$(dir_kb "$CAND_REAL")"
      ORPHAN_COUNT=$((ORPHAN_COUNT + 1))
      ORPHAN_KB=$((ORPHAN_KB + KB))
      SAMPLE="$(head -3 "$WORK_TMP/cwds" | tr '\n' ' ')"
      if [ "$MODE" = "dry-run" ]; then
        echo "  · orphan (${KB} KB): $CAND_NAME"
        echo "      cwd 例: $SAMPLE"
      else
        if [ "$ARCHIVE_DIR_READY" != "1" ]; then
          if ! mkdir -p "$ARCHIVE_DIR" 2>/dev/null; then
            echo "ERROR: アーカイブ先を作成できません: $ARCHIVE_DIR" >&2
            exit 1
          fi
          ARCHIVE_DIR_READY=1
        fi
        echo "  → 回収: $CAND_NAME (${KB} KB)"
        if ! archive_and_remove "$CAND_NAME" "$CAND_PATH" "$CAND_REAL" "$PROJECTS_REAL" "$ARCHIVE_DIR"; then
          FAIL_COUNT=$((FAIL_COUNT + 1))
        fi
      fi
      ;;
    2)
      SKIP_NO_CWD=$((SKIP_NO_CWD + 1))
      ;;
    3)
      SKIP_LIVE=$((SKIP_LIVE + 1))
      ;;
    4)
      FAIL_COUNT=$((FAIL_COUNT + 1))
      echo "  ⚠️ jsonl 走査エラーのため保護: $CAND_NAME" >&2
      ;;
    *)
      FAIL_COUNT=$((FAIL_COUNT + 1))
      echo "  ⚠️ 想定外の判定 ($VERDICT): $CAND_NAME" >&2
      ;;
  esac
done
shopt -u nullglob

echo ""
echo "=== サマリー ==="
echo "mode: $MODE"
echo "孤児候補: ${ORPHAN_COUNT} 件 / ${ORPHAN_KB} KB"
echo "スキップ live(cwd 現存): ${SKIP_LIVE}"
echo "スキップ cwd 無し: ${SKIP_NO_CWD}"
echo "スキップ symlink: ${SKIP_SYMLINK}"
echo "スキップ path 保護: ${SKIP_PATH}"
echo "失敗: ${FAIL_COUNT}"
if [ "$MODE" = "apply" ]; then
  echo "アーカイブ回収: ${ARCHIVED_COUNT} 件 / 元 ${ARCHIVED_KB} KB → 書庫 ${ARCHIVE_OUT_KB} KB"
else
  echo "（dry-run のため削除していません。回収するには --apply を付けて再実行）"
fi

# subagents 方針の短い注記（Issue #281）
echo ""
echo "注: 孤児と判定したプロジェクトディレクトリ全体（配下の subagents/ を含む）を回収します。"
echo "    稼働中プロジェクト内の subagents/ だけを年齢で消すことはしません（所有証拠が無いため）。"

if [ "$FAIL_COUNT" -gt 0 ]; then
  exit 1
fi
exit 0
