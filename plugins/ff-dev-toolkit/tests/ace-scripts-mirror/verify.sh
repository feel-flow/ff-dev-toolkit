#!/usr/bin/env bash
#
# docs-template/scripts/ace/*.ts と repository root scripts/ace/*.ts の
# byte-identical、および entryHeadingSource の単一源利用を検査する（Issue #338）。
#
# ADR-016 決定 4 により docs-template 側が SSOT、root 側は実行用ミラーである。
# Issue #338 の byte-identical 契約はトップレベルの .ts だけである。README.md は
# 配置先に応じてリンク先が意図的に異なり、run-subagent.sh 等を含む他の非 .ts も
# 本ゲートの契約外。root 側の Vitest 実行可否（Issue #290）も本 suite の対象外。
#
# 一時ファイル・node_modules・ネットワークを使わない読み取り専用の静的ゲートなので、
# 環境都合の skip 経路は持たない。検査対象を読めない場合は fail-closed にする。

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
REPO_ROOT="$(cd "$PLUGIN_ROOT/../.." && pwd)"
SSOT_DIR="$PLUGIN_ROOT/docs-template/scripts/ace"
MIRROR_DIR="$REPO_ROOT/scripts/ace"

PASS=0
FAIL=0
ok()  { echo "  ✓ $1"; PASS=$((PASS + 1)); }
bad() { echo "  ✗ $1" >&2; FAIL=$((FAIL + 1)); }

for dir in "$SSOT_DIR" "$MIRROR_DIR"; do
  if [ ! -d "$dir" ]; then
    echo "✗ ACE scripts ディレクトリが見つかりません: $dir" >&2
    exit 1
  fi
done

collect_ts_names() {
  find "$1" -maxdepth 1 -type f -name '*.ts' -exec basename {} \; | LC_ALL=C sort
}

if ! SSOT_NAMES="$(collect_ts_names "$SSOT_DIR")"; then
  echo "✗ SSOT 側の .ts 一覧を取得できません: $SSOT_DIR" >&2
  exit 1
fi
if ! MIRROR_NAMES="$(collect_ts_names "$MIRROR_DIR")"; then
  echo "✗ mirror 側の .ts 一覧を取得できません: $MIRROR_DIR" >&2
  exit 1
fi
if [ -z "$SSOT_NAMES" ] || [ -z "$MIRROR_NAMES" ]; then
  echo "✗ ACE scripts の .ts 一覧が空です（検査が成立しません）" >&2
  echo "  SSOT: $SSOT_DIR" >&2
  echo "  mirror: $MIRROR_DIR" >&2
  exit 1
fi

# 以降で安全に名前を扱えるよう、改行単位で読んで現在のファイル名契約へ限定する。
# word splitting より先に検査するため、空白や glob 文字も名指しで fail-loud になる。
while IFS= read -r name; do
  case "$name" in
    ''|*[!A-Za-z0-9._-]*)
      echo "✗ ACE script のファイル名が安全な token ではありません: $name" >&2
      exit 1
      ;;
  esac
done < <(printf '%s\n%s\n' "$SSOT_NAMES" "$MIRROR_NAMES")

echo "== ace-scripts mirror gate =="

while IFS= read -r name; do
  if [ ! -f "$MIRROR_DIR/$name" ]; then
    bad "片側だけの .ts: SSOT=$SSOT_DIR/$name / mirror に無し=$MIRROR_DIR/$name"
  fi
done < <(printf '%s\n' "$SSOT_NAMES")
while IFS= read -r name; do
  if [ ! -f "$SSOT_DIR/$name" ]; then
    bad "片側だけの .ts: mirror=$MIRROR_DIR/$name / SSOT に無し=$SSOT_DIR/$name"
  fi
done < <(printf '%s\n' "$MIRROR_NAMES")

TS_COUNT=0
while IFS= read -r name; do
  [ -f "$MIRROR_DIR/$name" ] || continue
  TS_COUNT=$((TS_COUNT + 1))
  CMP_RC=0
  cmp -s "$SSOT_DIR/$name" "$MIRROR_DIR/$name" || CMP_RC=$?
  case "$CMP_RC" in
    0) ok "byte-identical: $name" ;;
    1) bad "内容 drift: SSOT=$SSOT_DIR/$name / mirror=$MIRROR_DIR/$name" ;;
    *)
      echo "✗ cmp が成立しませんでした（rc=${CMP_RC}）: $SSOT_DIR/$name / $MIRROR_DIR/$name" >&2
      exit 1
      ;;
  esac
done < <(printf '%s\n' "$SSOT_NAMES")

if [ "$SSOT_NAMES" = "$MIRROR_NAMES" ]; then
  ok ".ts のファイル集合が一致"
else
  bad ".ts のファイル集合が不一致"
fi

if [ -f "$SSOT_DIR/check-category-size.ts" ] && [ -f "$MIRROR_DIR/check-category-size.ts" ]; then
  ok "entryHeadingSource の単一源が両配置に存在"
else
  bad "entryHeadingSource の単一源が見つかりません: $SSOT_DIR/check-category-size.ts / $MIRROR_DIR/check-category-size.ts"
fi

# #317 が統合した stale 日数の既定値。behavioral test は両 main への適用を測るが、
# 同値のローカル定数を書き戻すだけなら挙動は変わらない。mirror gate で依存構造も固定し、
# 「今は同値だが次の変更で drift する」形を green のまま残さない。
REUSE_REPORT="$SSOT_DIR/ace-reuse-report.ts"
REFINE_REPORT="$SSOT_DIR/ace-refine-report.ts"

stale_export_rc=0
awk '
  /^export const DEFAULT_STALE_DAYS = [1-9][0-9]*;$/ { count++ }
  END { exit(count == 1 ? 0 : 1) }
' "$REUSE_REPORT" || stale_export_rc=$?
case "$stale_export_rc" in
  0) ok "DEFAULT_STALE_DAYS の export 単一源: ace-reuse-report.ts" ;;
  1) bad "DEFAULT_STALE_DAYS の export 単一源がありません: $REUSE_REPORT" ;;
  *)
    echo "✗ DEFAULT_STALE_DAYS の export 検査が成立しませんでした（rc=${stale_export_rc}）: $REUSE_REPORT" >&2
    exit 1
    ;;
esac

stale_import_rc=0
awk '
  BEGIN { in_target = 0; found_symbol = 0; matched = 0 }
  /^import[[:space:]]*\{/ { in_target = 1; found_symbol = 0 }
  in_target && /^[[:space:]]*DEFAULT_STALE_DAYS,[[:space:]]*$/ { found_symbol = 1 }
  in_target && /\}[[:space:]]+from[[:space:]]+"\.\/ace-reuse-report(\.js)?";[[:space:]]*$/ {
    if (found_symbol) matched = 1
    in_target = 0
    found_symbol = 0
  }
  END { exit(matched ? 0 : 1) }
' "$REFINE_REPORT" || stale_import_rc=$?
case "$stale_import_rc" in
  0) ok "DEFAULT_STALE_DAYS の共有 import: ace-refine-report.ts" ;;
  1) bad "DEFAULT_STALE_DAYS を ace-reuse-report から import していません: $REFINE_REPORT" ;;
  *)
    echo "✗ DEFAULT_STALE_DAYS の import 検査が成立しませんでした（rc=${stale_import_rc}）: $REFINE_REPORT" >&2
    exit 1
    ;;
esac

stale_local_rc=0
awk '
  /^(export )?const DEFAULT_STALE_DAYS([[:space:]]|=)/ { found = 1 }
  END { exit(found ? 1 : 0) }
' "$REFINE_REPORT" || stale_local_rc=$?
case "$stale_local_rc" in
  0) ok "DEFAULT_STALE_DAYS のローカル定義無し: ace-refine-report.ts" ;;
  1) bad "DEFAULT_STALE_DAYS のローカル定義を検出: $REFINE_REPORT" ;;
  *)
    echo "✗ DEFAULT_STALE_DAYS のローカル定義検査が成立しませんでした（rc=${stale_local_rc}）: $REFINE_REPORT" >&2
    exit 1
    ;;
esac

# #318 が統合した entryHeadingSource の既知 consumer。期待ファイルを明示することで、
# 共有 import を削って同値 regex をローカルへ戻す退行を、挙動が同じでも検出する。
# byte-identical は上で検査済みなので import graph は SSOT 側だけを読めば両配置を覆う。
has_shared_import() { # <file>
  awk '
    BEGIN { in_target = 0; found_symbol = 0; matched = 0 }
    /^import[[:space:]]*\{/ { in_target = 1; found_symbol = 0 }
    in_target && /^[[:space:]]*entryHeadingSource,[[:space:]]*$/ { found_symbol = 1 }
    in_target && /\}[[:space:]]+from[[:space:]]+"\.\/check-category-size(\.js)?";[[:space:]]*$/ {
      if (found_symbol) matched = 1
      in_target = 0
      found_symbol = 0
    }
    END { exit(matched ? 0 : 1) }
  ' "$1"
}

check_consumer() { # <basename> <construction-regex>
  local name="$1" construction="$2" file="$SSOT_DIR/$1" import_rc=0 grep_rc=0
  if [ ! -f "$file" ]; then
    bad "entryHeadingSource consumer が見つかりません: $file"
    return
  fi
  has_shared_import "$file" || import_rc=$?
  case "$import_rc" in
    0) ok "共有 import: $name" ;;
    1) bad "entryHeadingSource を check-category-size から import していません: $file" ;;
    *)
      echo "✗ import 検査が成立しませんでした（rc=${import_rc}）: $file" >&2
      exit 1
      ;;
  esac
  grep -E "$construction" "$file" >/dev/null || grep_rc=$?
  case "$grep_rc" in
    0) ok "共有 source の構築式: $name" ;;
    1) bad "entryHeadingSource を使う既知の構築式がありません: $file" ;;
    *)
      echo "✗ 構築式の検査が成立しませんでした（rc=${grep_rc}）: $file" >&2
      exit 1
      ;;
  esac
}

check_consumer \
  "ace-refine-report.ts" \
  '^[[:space:]]*const ENTRY_HEADER_LINE_PATTERN = new RegExp\(entryHeadingSource\("capture-id"\), "u"\);[[:space:]]*$'
# shellcheck disable=SC2016 # regex 内の `$` は行末アンカーとして grep -E へ渡す
check_consumer \
  "ace-reuse-report.ts" \
  '^[[:space:]]*entryHeadingSource\("capture-id"\) \+ String\.raw`\(\.\*\)\$`,[[:space:]]*$'
check_consumer \
  "check-entry-format.ts" \
  '^[[:space:]]*const ACE_ENTRY_HEADER_LINE = new RegExp\(entryHeadingSource\("capture-id"\), "u"\);[[:space:]]*$'

# import/call のピンに加え、既知 consumer へ ACE 見出し regex を直書きする典型的な
# 書き戻しも名指しする。同一行に regex 構築 token と `ACE-` が共存すればコメントでも
# fail-loud 側へ倒すヒューリスティックであり、散文の `### ACE-...` だけなら拾わない。
for name in ace-refine-report.ts ace-reuse-report.ts check-entry-format.ts; do
  file="$SSOT_DIR/$name"
  if awk '
    index($0, "String.raw`") && index($0, "ACE-") { found = 1 }
    index($0, "new RegExp(") && index($0, "ACE-") { found = 1 }
    /\/\^### .*ACE-/ { found = 1 }
    END { exit(found ? 0 : 1) }
  ' "$file"; then
    bad "ローカル ACE 見出し regex を検出（entryHeadingSource を利用してください）: $file"
  else
    ok "ローカル ACE 見出し regex 無し: $name"
  fi
done

if [ "$FAIL" -gt 0 ]; then
  echo "ace-scripts-mirror verify: $FAIL 件失敗 / $PASS 件 pass" >&2
  exit 1
fi

echo "ace-scripts-mirror verify: 全 $PASS 件 pass（.ts $TS_COUNT ファイル、非 .ts は契約外）"
