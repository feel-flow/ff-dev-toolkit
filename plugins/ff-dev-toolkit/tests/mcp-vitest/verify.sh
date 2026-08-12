#!/usr/bin/env bash
#
# mcp-vitest: 同梱 spec-docs MCP サーバーの vitest スイートを run-all.sh へ配線する。
#
# 背景 (Issue #217): MCP の vitest（indexer / utils / server / transport-errors）は
# `npm test` の手動実行でしか走らず、run-all.sh の suite からも CI（存在しない）
# からも呼ばれていなかった。SDK バンプ等の回帰が「誰かが手で叩くまで」隠れる。
#
# 実行は `vitest run` のみで build を含めない（npm test は build で dist/ に書き
# 込むため read-only 契約に反する）。テストはコミット済み dist/index.js を実プロセス
# 起動して検証する — dist が src と一致していることは mcp-dist-gate suite が別途
# 保証するので、この分担で「stale な dist をテストして green」は成立しない。
#
# node_modules が無い環境では検証本体を実行できないため、run-all.sh の契約
# どおり行頭 `○ skip` を出して exit 0 する。

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
MCP_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)/mcp"

if [[ ! -d "$MCP_DIR/node_modules" ]]; then
  echo "○ skip: $MCP_DIR/node_modules が無いためスキップ（本 suite の検査は1件も実行されていません。cd mcp && npm install で有効化）"
  exit 0
fi
if [[ ! -x "$MCP_DIR/node_modules/.bin/vitest" ]]; then
  echo "✗ node_modules はあるが vitest が無い（npm install が不完全）: $MCP_DIR/node_modules/.bin/vitest" >&2
  exit 1
fi
if [[ ! -f "$MCP_DIR/dist/index.js" ]]; then
  echo "✗ コミット済み dist が存在しない（server/transport テストの前提）: $MCP_DIR/dist/index.js" >&2
  exit 1
fi

# 一時領域が書き込み不可の環境では vitest 自体が一時ディレクトリ作成で落ちる
# （検証本体を環境都合で実行できない）ため、契約どおり丸ごと skip する。
# mktemp はテンプレート形式で呼ぶ（BSD/GNU/busybox すべてで有効。`-t <prefix>` は
# GNU では XXXXXX 必須のためエラーになり、移植性バグを環境都合と誤帰属させる）。
# mktemp の stderr を捨てない。捨てると read-only 以外の失敗（TMPDIR が不正な
# パス・quota 超過など）まで「書き込み可能な環境で再実行してください」に
# 誤帰属し、恒常的に壊れた TMPDIR が suite を exit 0 で無効化し続ける。
# 2>&1 で受けると、成功時はパス・失敗時は理由が同じ変数に入る。
if _ff_mktemp_out="$(mktemp -d "${TMPDIR:-/tmp}/mcp-vitest.XXXXXX" 2>&1)"; then
  PROBE_DIR="$_ff_mktemp_out"
else
  echo "○ skip: 一時ディレクトリを作成できないためスキップ（本 suite の検査は1件も実行されていません。書き込み可能な環境で再実行してください）"
  printf '  mktemp: %s\n' "$_ff_mktemp_out"
  exit 0
fi
rm -rf "$PROBE_DIR"

# 事後条件の基準線: dist/ の状態を実行前に記録し、実行後は「変化」だけを検査する
# （絶対判定だと開発者の作業中変更を本 suite の書き込みと誤帰属する）。git status の
# 状態分類は dirty なファイルへの上書きを見逃すため、内容ハッシュで比較する。
# 状態は 2 部構成: エントリ名の全一覧（種別を問わない。symlink やディレクトリの
# 増減を検出する）+ 通常ファイルの内容ハッシュ。ハッシュは cksum（POSIX、shasum と
# 違いどの環境にもある）を `-exec ... +` で取り、空白を含むパスでも分割しない。
# ハッシュ処理自体の失敗（走査不能・コマンド不在）は握りつぶさず非 0 で止める —
# 前後とも空文字なら比較は必ず一致し、read-only 契約の証明が黙って「検査 0 件」に
# 退化するため（Issue #370。mcp-typecheck suite の tree_state と同じ方針で、対象が
# dist/ に限られる点だけが異なる。同型の実装が mcp-dist-gate suite にもあり、直す
# ときは両方を揃える）。pipefail はサブシェル内で自己宣言し、呼び出し文脈に依存
# させない。検出対象は suite 自身による偶発的書き込み（非敵対モデル）— ファイル
# モードの変更と symlink の張り替え先は対象外。
dist_state() {
  (
    set -o pipefail
    cd "$MCP_DIR" &&
      find dist | LC_ALL=C sort &&
      find dist -type f -exec cksum {} + | LC_ALL=C sort
  )
}
if ! STATE_BEFORE="$(dist_state)"; then
  echo "✗ dist/ の内容ハッシュを取得できませんでした（read-only 事後条件を検査できません）" >&2
  exit 1
fi
if [[ -z "$STATE_BEFORE" ]]; then
  echo "✗ dist/ の内容ハッシュが空です（走査が壊れているか dist/ が空で、read-only 事後条件が空検査になります）" >&2
  exit 1
fi

# 出力は丸ごと受けてから判定する（vitest の exit code に加えて、成功サマリー行の
# 実在も確認する fail-closed。exit 0 + 0 tests のような縮退を green にしない）。
set +e
OUTPUT="$(cd "$MCP_DIR" && ./node_modules/.bin/vitest run 2>&1)"
RC=$?
set -e

# サマリー行の抽出は rc を三分する（mcp-dist-gate suite の B 検査と同じ規約）:
# rc=1（一致なし）は後段の「検査 0 件の縮退」判定に委ね、rc>=2（grep 自体の異常）を
# 「一致なし」と読まない — 誤帰属すると診断が誤った原因（縮退疑い）を指す。
set +e
SUMMARY="$(printf '%s\n' "$OUTPUT" | grep -E '^[[:space:]]*Tests[[:space:]]')"
SUMMARY_RC=$?
set -e
if [[ $SUMMARY_RC -ge 2 ]]; then
  echo "✗ 成功サマリー行の抽出に失敗した（grep rc=${SUMMARY_RC}）。異常を「一致なし」と読まずに停止する" >&2
  exit 1
fi

if [[ $RC -ne 0 ]]; then
  echo "✗ mcp vitest が失敗した (exit $RC)" >&2
  # 診断の抽出は awk 1 段で行う（grep|head は pipefail 下で「該当なしの rc=1」や
  # head 早期終了の SIGPIPE により、後続の案内と exit 1 へ到達しなくなる）。
  printf '%s\n' "$OUTPUT" | awk '/×|✗|FAIL|AssertionError|Error:/ { print; if (++n == 20) exit }' >&2 || true
  echo "  再現: cd plugins/ff-dev-toolkit/mcp && npm test" >&2
  exit 1
fi

case "$SUMMARY" in
  *passed*)
    : ;;
  *)
    echo "✗ vitest は exit 0 だが成功サマリー行が見つからない（検査 0 件の縮退を疑う）" >&2
    printf '%s\n' "$OUTPUT" | tail -10 >&2
    exit 1
    ;;
esac
case "$SUMMARY" in
  *failed*)
    echo "✗ vitest サマリーに failed が含まれる: $SUMMARY" >&2
    exit 1
    ;;
esac

# 事後条件: dist/ を書き換えていない（vitest run は build を含まないため
# 本来書き込まない。書き込まれたら構成が変わった合図）。
if ! STATE_AFTER="$(dist_state)"; then
  echo "✗ 実行後の dist/ 内容ハッシュを取得できませんでした（read-only 事後条件を検査できません）" >&2
  exit 1
fi
if [[ "$STATE_AFTER" != "$STATE_BEFORE" ]]; then
  echo "✗ 本 suite の実行が dist/ を書き換えた（read-only 契約違反）" >&2
  exit 1
fi

echo "✓ mcp-vitest verify:${SUMMARY# }"
