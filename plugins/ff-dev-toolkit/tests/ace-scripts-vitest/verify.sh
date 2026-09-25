#!/usr/bin/env bash
#
# ace-scripts-vitest: docs-template と本体 mirror の ace vitest スイートを run-all.sh へ配線する。
#
# 背景 (Issue #223): ace スクリプト群（check-category-size / ace-reuse-report /
# sync-playbook-frontmatter / shell-hooks / ace-refine-report）の vitest は
# 手動実行でしか走らず、run-all.sh の suite から呼ばれていなかった（Issue #217 で
# MCP に対して塞いだのと同型の穴）。コンパクト正準フォーマットのパース互換や
# playbook/archive/ の集計除外はこれらのテストが唯一のロックであり、未配線のままだと
# 回帰が「誰かが手で叩くまで」隠れる。
#
# 導入先の配置（報告: https://github.com/feel-flow/ff-dev-toolkit/issues/121 ）: README の案内どおり scripts/ace/ だけを逐語コピーした配置では、
# 開発元の見本（docs-template の hook・Playbook・記入例）を読む 3 ファイルが skip へ倒れる。
# 開発元の 2 配置では skip を 0 件に固定し（skip 条件が開発元でも真になって検査が消える退行を
# 赤にする）、導入先配置は一時ディレクトリへ合成して「失敗 0・skip あり・理由が出力に出る」を
# 確かめる。合成できない回は検査不成立として赤にする（緑へ倒さない）。
#
# vitest 本体は mcp/node_modules のものを再利用する（docs-template はテンプレート
# 配布物なので自前の node_modules を持たない）。node_modules が無い環境では
# run-all.sh の契約どおり行頭 `○ skip` を出して exit 0 する。

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
REPOSITORY_ROOT="$(cd "$PLUGIN_ROOT/../.." && pwd)"
MCP_DIR="$PLUGIN_ROOT/mcp"
ACE_SCRIPTS_DIR="$PLUGIN_ROOT/docs-template/scripts/ace"
ACE_SCRIPTS_MIRROR_DIR="$REPOSITORY_ROOT/scripts/ace"

[ -d "$ACE_SCRIPTS_DIR" ] || {
  echo "✗ ace スクリプトディレクトリが見つかりません: $ACE_SCRIPTS_DIR" >&2
  exit 1
}
[ -d "$ACE_SCRIPTS_MIRROR_DIR" ] || {
  echo "✗ ace スクリプトの本体 mirror が見つかりません: $ACE_SCRIPTS_MIRROR_DIR" >&2
  exit 1
}

if [[ ! -d "$MCP_DIR/node_modules" ]]; then
  echo "○ skip: $MCP_DIR/node_modules が無いためスキップ（本 suite の検査は1件も実行されていません。cd mcp && npm install で有効化）"
  exit 0
fi
if [[ ! -x "$MCP_DIR/node_modules/.bin/vitest" ]]; then
  echo "✗ node_modules はあるが vitest が無い（npm install が不完全）: $MCP_DIR/node_modules/.bin/vitest" >&2
  exit 1
fi

# 一時領域が書き込み不可の環境では vitest 自体が一時ディレクトリ作成で落ちる
# （検証本体を環境都合で実行できない）ため、契約どおり丸ごと skip する。
# mktemp の stderr を捨てない。捨てると read-only 以外の失敗（TMPDIR が不正な
# パス・quota 超過など）まで「書き込み可能な環境で再実行してください」に
# 誤帰属し、恒常的に壊れた TMPDIR が suite を exit 0 で無効化し続ける。
# 2>&1 で受けると、成功時はパス・失敗時は理由が同じ変数に入る。
# rc=0 でも -d を検査する — 2>&1 の合流は「成功 + stderr 警告」の環境で変数へ
# 警告文が混入し、以後の処理が原因不明の失敗に化けるため。
if _ff_mktemp_out="$(mktemp -d "${TMPDIR:-/tmp}/ace-scripts-vitest.XXXXXX" 2>&1)" && [ -d "$_ff_mktemp_out" ]; then
  PROBE_DIR="$_ff_mktemp_out"
else
  echo "○ skip: 一時ディレクトリを作成できないためスキップ（本 suite の検査は1件も実行されていません。書き込み可能な環境で再実行してください）"
  printf '  mktemp: %s\n' "$_ff_mktemp_out"
  exit 0
fi
rm -rf "$PROBE_DIR"

run_vitest_dir() {
  local label="$1"
  local target_dir="$2"
  local output rc summary

  # 出力は丸ごと受けてから判定する（vitest の exit code に加えて、成功サマリー行の
  # 実在も確認する fail-closed。exit 0 + 0 tests のような縮退を green にしない）。
  # GitHub Actions でもサマリー行の先頭に ANSI 装飾が付かないよう固定する。
  if output="$(cd "$MCP_DIR" && NO_COLOR=1 ./node_modules/.bin/vitest run --dir "$target_dir" 2>&1)"; then
    rc=0
  else
    rc=$?
  fi

  summary="$(printf '%s\n' "$output" | grep -E '^[[:space:]]*Tests[[:space:]]' || true)"

  if [[ $rc -ne 0 ]]; then
    printf '%s\n' "$output"
    echo "✗ ace-scripts vitest が失敗しました（配置=${label}, rc=${rc}）" >&2
    return 1
  fi
  # 判定はシェル内の文字列マッチで行い、パイプを使わない（`printf | grep -q` は
  # grep の早期終了で printf が SIGPIPE 死し、pipefail の下で判定が反転する）。
  if [[ -z "$summary" || "$summary" != *passed* ]]; then
    printf '%s\n' "$output"
    echo "✗ vitest は exit 0 だが成功サマリーを確認できません（配置=${label}）" >&2
    return 1
  fi

  # 開発元の配置では skip 0 件（導入先向けの skip 条件が開発元で真になると検査が黙って消える）
  if [[ "$summary" == *skipped* ]]; then
    printf '%s\n' "$output"
    echo "✗ 開発元の配置で skip されたテストがあります（配置=${label}）: ${summary}" >&2
    return 1
  fi

  printf '%s\n' "$summary" | sed "s/^[[:space:]]*/  ✓ ${label}: /"
}

# 導入先の配置を合成して回す。期待する skip 理由は 3 ファイル分（shell-hooks /
# ace-domain / check-entry-format）。理由の件数を下限でなく一致で見るのは、skip へ倒れる
# ファイルが黙って増える（開発元前提の検査が新たに混入した）ことも検出するため。
EXPECTED_CONSUMER_SKIP_REASONS=3
run_vitest_consumer_layout() {
  local work output rc summary reasons
  if ! work="$(mktemp -d "${TMPDIR:-/tmp}/ace-scripts-consumer.XXXXXX" 2>&1)" || [ ! -d "$work" ]; then
    echo "✗ 導入先の配置を合成できません（一時ディレクトリ: ${work}）。検査不成立" >&2
    return 1
  fi
  if ! mkdir -p "$work/scripts" || ! cp -R "$ACE_SCRIPTS_DIR" "$work/scripts/ace" \
    || [ -e "$work/plugins" ] || [ ! -f "$work/scripts/ace/shell-hooks.test.ts" ]; then
    rm -rf "$work"
    echo "✗ 導入先の配置を合成できません（scripts/ace/ のコピーに失敗、または plugins/ が存在する）。検査不成立" >&2
    return 1
  fi
  if output="$(cd "$MCP_DIR" && NO_COLOR=1 ./node_modules/.bin/vitest run --reporter=verbose --dir "$work/scripts/ace" 2>&1)"; then
    rc=0
  else
    rc=$?
  fi
  rm -rf "$work"
  summary="$(printf '%s\n' "$output" | grep -E '^[[:space:]]*Tests[[:space:]]' || true)"
  reasons="$(printf '%s\n' "$output" | grep -c '^\[skip\] 開発元の配置' || true)"
  if [[ $rc -ne 0 || -z "$summary" || "$summary" != *passed* ]]; then
    printf '%s\n' "$output" | tail -40
    echo "✗ 導入先の配置（scripts/ace/ だけを逐語コピー）で vitest が失敗しました（rc=${rc}）" >&2
    return 1
  fi
  if [[ "$summary" != *skipped* || "$reasons" != "$EXPECTED_CONSUMER_SKIP_REASONS" ]]; then
    printf '%s\n' "$output" | tail -40
    echo "✗ 導入先の配置で skip 理由の出力が期待と違います（理由行 ${reasons} 件 / 期待 ${EXPECTED_CONSUMER_SKIP_REASONS} 件: ${summary}）" >&2
    return 1
  fi
  printf '%s\n' "$summary" | sed "s/^[[:space:]]*/  ✓ 導入先の配置（skip 理由 ${reasons} 件）: /"
}

run_vitest_dir "docs-template" "$ACE_SCRIPTS_DIR"
run_vitest_dir "repository mirror" "$ACE_SCRIPTS_MIRROR_DIR"
run_vitest_consumer_layout
echo "✓ ace-scripts vitest: 開発元 2 配置 + 導入先配置 pass"
