#!/usr/bin/env bash
#
# /ace-refine（grow-and-refine）の契約検査（Issue #223）。
#
# refine は既存エントリ本文の書き換え・削除（アーカイブ移動）を含む唯一の経路であり、
# 安全弁（承認前書き換え禁止・原文 verbatim 保全・ID/anchor 不変・カウンター非減算・
# knowledge: 件名）が SKILL.md から脱落すると、Playbook の監査可能性と reuse 計測が
# 静かに壊れる。本 suite は固定文言 grep でこれらの安全弁を fail-closed で検証する。
# 併せて、ace-curate 側の書き込み時ゲート（行数バジェット・叙述の記録先分離・
# 索引タイトルのみ・refine 専権）と、テンプレート・スクリプトの案内文言も固定する。

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
REFINE_FILE="$PLUGIN_ROOT/skills/ace-refine/SKILL.md"
CURATE_FILE="$PLUGIN_ROOT/skills/ace-curate/SKILL.md"
PLAYBOOK_TEMPLATE="$PLUGIN_ROOT/docs-template/08-knowledge/PLAYBOOK.md"
PATTERNS_TEMPLATE="$PLUGIN_ROOT/docs-template/03-implementation/PATTERNS.md"
ACE_CYCLE_TEMPLATE="$PLUGIN_ROOT/docs-template/05-operations/deployment/ace-cycle.md"
CHECK_SIZE_SCRIPT="$PLUGIN_ROOT/docs-template/scripts/ace/check-category-size.ts"
REFINE_REPORT_SCRIPT="$PLUGIN_ROOT/docs-template/scripts/ace/ace-refine-report.ts"
FORMAT_GATE_SCRIPT="$PLUGIN_ROOT/docs-template/scripts/ace/check-entry-format.ts"
LEGACY_ALLOWLIST_TEMPLATE="$PLUGIN_ROOT/docs-template/08-knowledge/legacy-format-allowlist.txt"
ESBUILD_BIN="$PLUGIN_ROOT/mcp/node_modules/.bin/esbuild"

for f in "$REFINE_FILE" "$CURATE_FILE" "$PLAYBOOK_TEMPLATE" "$PATTERNS_TEMPLATE" \
         "$ACE_CYCLE_TEMPLATE" "$CHECK_SIZE_SCRIPT" "$REFINE_REPORT_SCRIPT" \
         "$FORMAT_GATE_SCRIPT"; do
  [ -s "$f" ] || {
    echo "✗ 検査対象が存在しないか空です: $f" >&2
    exit 1
  }
done

# 後半の check-entry-format 統合検査は一時領域を必要とする。静的検査だけを先に
# pass として数えてから環境都合で落ちると本物の回帰と区別できないため、suite 全体の
# 開始前に同じ TMPDIR を probe し、使えない場合は検査 0 件の明示 skip にする。
if _ff_tmp_probe="$(mktemp -d "${TMPDIR:-/tmp}/ace-refine-preflight.XXXXXX" 2>&1)"; then
  rmdir "$_ff_tmp_probe" || {
    echo "✗ ace-refine: 一時領域 probe を後片付けできません: $_ff_tmp_probe" >&2
    exit 1
  }
else
  echo "○ skip: 一時ディレクトリを作成できないため ace-refine の検査をスキップ（検査は1件も実行されていません）"
  printf '  mktemp: %s\n' "$_ff_tmp_probe"
  exit 0
fi

PASS=0
FAIL=0
ok()  { echo "  ✓ $1"; PASS=$((PASS + 1)); }
bad() { echo "  ✗ $1" >&2; FAIL=$((FAIL + 1)); }

contains() {
  local file="$1" needle="$2" label="$3"
  if grep -Fq -- "$needle" "$file"; then
    ok "$label"
  else
    bad "${label} — '$needle' が見つかりません（$(basename "$file")）"
  fi
}

echo "== ace-refine ハードルール（安全弁の固定文言） =="

contains "$REFINE_FILE" \
  "dry-run レポートの提示とユーザー承認より前に、いかなるファイルも書き換えない" \
  "承認前書き換え禁止"
contains "$REFINE_FILE" \
  "原文はアーカイブへ verbatim で保全する。保全なしの削除・要約は禁止" \
  "原文 verbatim 保全"
contains "$REFINE_FILE" \
  "エントリ ID と anchor は live・アーカイブの双方で改名しない" \
  "ID・anchor 不変"
contains "$REFINE_FILE" \
  "カウンターは統合時の合算以外変更しない（減算・リセット禁止）" \
  "カウンター非減算"
contains "$REFINE_FILE" \
  "既存エントリ本文の書き換えは本スキル実行中のみ許可（/ace-curate は append-only のまま）" \
  "書き換え許可の refine 限定"
contains "$REFINE_FILE" \
  "コミット件名と PR タイトルは \`knowledge:\` で始める" \
  "knowledge: 件名の強制（reuse 計測の汚染防止）"
contains "$REFINE_FILE" \
  "playbook/archive/<category>.md" \
  "アーカイブ先パスの明示"
contains "$REFINE_FILE" \
  "アーカイブ書き込みの検証（必須）" \
  "アーカイブ write の grep 検証ステップ（文言ルールの機械化）"
contains "$REFINE_FILE" \
  "エントリ保全の一括検証（必須）" \
  "コミット前の全 ID 保全 grep 検証"

echo
echo "== archive / provenance 契約の 3 穴（Issue #288） =="

# 穴 1: provenance 注記が「再整形のみ」を表現できず、実際にしていない要約を記録していた。
# 2 変種と判定条件の両方を固定する（片方だけ残ると再び文言の孤島が生まれる）。
contains "$REFINE_FILE" \
  "> Compacted: YYYY-MM-DD（live 側を要約済み。本文の原文は本エントリが正）" \
  "provenance 注記 第1変種（本文を意味保存要約した場合）"
contains "$REFINE_FILE" \
  "> Compacted: YYYY-MM-DD（live 側はメタ表のみ正準フォーマットへ再整形。本文は逐語同一で無改変。本エントリが原文）" \
  "provenance 注記 第2変種（メタ表の再整形のみ・本文は逐語同一）"
contains "$REFINE_FILE" \
  "live 側の本文文字列が原文と逐語同一かどうか" \
  "2 変種の判定条件"
contains "$REFINE_FILE" \
  "provenance 注記は実際に行った操作に対応する変種を使う" \
  "ハードルール: 実際にしていない操作を注記に書かない"

# 穴 2: 保全本文内の相対リンクは verbatim 保全のため書き換えられない。
# 「書き換えない」と「注記が必須」は対で意味を持つ（片方だけでは行動が決まらない）。
contains "$REFINE_FILE" \
  "保全本文内の相対リンクは live 基準" \
  "archive 冒頭注記のテンプレート文言（機械ゲートの判定キー）"
contains "$REFINE_FILE" \
  "保全本文内の相対リンクは書き換えない" \
  "保全本文内リンクの非書き換え契約"
contains "$REFINE_FILE" \
  "check-archive-links" \
  "注記の存在を強制する機械ゲートへの導線"

# 穴 3: 統合された側が archive で active のまま残り、grep した人に有効と誤読される。
contains "$REFINE_FILE" \
  "archive 側のコピーの \`Status\` を \`merged\` に変える" \
  "統合される側の Status を merged にする手順"
contains "$PLAYBOOK_TEMPLATE" \
  "\`merged\`" \
  "PLAYBOOK テンプレの §ステータス定義に merged がある"

echo
echo "== ace-curate 書き込み時ゲート =="

contains "$CURATE_FILE" \
  "一回性のインシデント叙述は Playbook に書かない" \
  "インシデント叙述の記録先分離（TROUBLESHOOTING/runbook）"
contains "$CURATE_FILE" \
  "行数バジェット自己チェック（必須・ブロッキング）" \
  "15 行バジェットの自己チェック"
contains "$CURATE_FILE" \
  "ace-line-budget-exception" \
  "行数バジェット例外マーカーの案内"
contains "$CURATE_FILE" \
  "索引行はタイトルのみ" \
  "索引タイトルのみルール"
contains "$CURATE_FILE" \
  "既存エントリの要約・アーカイブ・統合は \`/ace-refine\` のみが行う" \
  "refine 専権の明示（curate は grow 専用）"
contains "$CURATE_FILE" \
  "| Helpful | 0 | Harmful | 0 |" \
  "コンパクト正準フォーマットのカウンター行（スクリプト互換の行頭パイプ）"
contains "$CURATE_FILE" \
  "既存エントリの本文（新形式の本文 / 旧形式の Insight/Context/Action）の書き換えは禁止" \
  "curate 側の append-only ハードルールが残っている"

echo
echo "== テンプレート（PLAYBOOK / PATTERNS / ace-cycle） =="

contains "$PLAYBOOK_TEMPLATE" \
  "| Helpful | 0 | Harmful | 0 |" \
  "PLAYBOOK テンプレの正準フォーマット"
contains "$PLAYBOOK_TEMPLATE" \
  "playbook/archive/" \
  "PLAYBOOK テンプレの archive 運用ルール"
contains "$PLAYBOOK_TEMPLATE" \
  "ace-line-budget-exception" \
  "PLAYBOOK テンプレの行数バジェット例外"
contains "$PATTERNS_TEMPLATE" \
  "実証済みパターン（ACE 昇格）" \
  "PATTERNS テンプレの昇格先セクション"
contains "$ACE_CYCLE_TEMPLATE" \
  "定期 Refine（grow-and-refine）" \
  "ace-cycle テンプレの Refine 節"

echo
echo "== スクリプト（案内文言・存在） =="

contains "$CHECK_SIZE_SCRIPT" \
  "/ace-refine" \
  "check-category-size の超過時案内が /ace-refine を指す"
contains "$REFINE_REPORT_SCRIPT" \
  "ACE_MAX_ENTRY_LINES" \
  "ace-refine-report の行数バジェット環境変数"
contains "$REFINE_REPORT_SCRIPT" \
  "ACE_PROMOTE_HELPFUL_MIN" \
  "ace-refine-report の昇格閾値環境変数"

echo
echo "== エントリ形式ゲート（Issue #286） =="

[ -s "$FORMAT_GATE_SCRIPT" ] || {
  echo "  ✗ 形式ゲートスクリプトが存在しないか空です: $FORMAT_GATE_SCRIPT" >&2
  FAIL=$((FAIL + 1))
}
# allowlist テンプレートの実在は検査しない。docs-template は旧テーブル形式のエントリを
# 1 件も同梱しないので、allowlist が無い状態が正しい既定である（check-entry-format は
# allowlist 不在時に strict へ倒す）。下の contains 検査は**ゲートスクリプト側**が
# allowlist を判定軸にし続けていることを固定するもので、こちらは残す。

# 判定軸（allowlist）と fail-closed の設計をスクリプト側で固定する。Date 閾値へ
# 差し替えられると「著者が手で書くフィールド」が判定軸になり偶然通せるようになる。
contains "$FORMAT_GATE_SCRIPT" \
  "legacy-format-allowlist.txt" \
  "判定軸が allowlist ファイルであること"
contains "$FORMAT_GATE_SCRIPT" \
  "fail-open にすると、allowlist を" \
  "allowlist 不在時に strict へ倒す（fail-closed）理由の明示"
contains "$FORMAT_GATE_SCRIPT" \
  "playbook/archive/" \
  "archive を走査対象外にする旨"

# allowlist を新規追記の抜け道にしない、という運用の意図は 3 箇所に複製されている。
# 1 箇所だけ残ると「allowlist に足せば通る」と読まれてゲートが空洞化する。
contains "$CURATE_FILE" \
  "check-entry-format" \
  "curate の同期検証に形式ゲートが配線されている"
contains "$CURATE_FILE" \
  "新規 ID を足して通すことはしない" \
  "curate 側: allowlist を抜け道にしない"
contains "$REFINE_FILE" \
  "check-entry-format" \
  "refine の検証ゲートに形式ゲートが配線されている"
contains "$REFINE_FILE" \
  "正準化後の allowlist 操作は変種で分岐する" \
  "refine 側: allowlist 操作が変種分岐であること"
# 変種を書き分けないと、第 2 変種（ハイブリッド）まで allowlist から外して
# insight-block 判定で exit 1 になる（Issue #493）。見出しだけでは分岐が落ちる。
# 「allowlist から削除しない」単体は「削除しないと警告…なので削除する」の接頭辞に
# 一致するため、exit 1 条項まで含めて第 2 変種専用にする。
contains "$REFINE_FILE" \
  "\`insight-block\` マーカーで legacy 判定が継続する" \
  "refine 側: 第 2 変種が insight-block で legacy 判定を継続すること"
contains "$REFINE_FILE" \
  "**allowlist から削除しない**（削除すると allowlist に無い旧形式として exit 1" \
  "refine 側: 第 2 変種は allowlist 残置（exit 1 のため削除しない）"
contains "$REFINE_FILE" \
  "ハイブリッド残置" \
  "refine 側: 第 2 変種をハイブリッド残置として名指し"
contains "$PLAYBOOK_TEMPLATE" \
  "新規追記のために allowlist へ ID を足さない" \
  "PLAYBOOK テンプレ: allowlist を抜け道にしない"
contains "$PLAYBOOK_TEMPLATE" \
  "ハイブリッド残置なら削除しない" \
  "PLAYBOOK テンプレ: 第 2 変種は allowlist 残置"
LIVE_PLAYBOOK="$(cd "$PLUGIN_ROOT/../.." && pwd)/docs/08-knowledge/PLAYBOOK.md"
if [ -s "$LIVE_PLAYBOOK" ]; then
  contains "$LIVE_PLAYBOOK" \
    "ハイブリッド残置なら削除しない" \
    "live PLAYBOOK: 第 2 変種は allowlist 残置"
else
  ok "live PLAYBOOK 不在（公開 checkout）— テンプレート側のみ検査"
fi
# 配布物の自己整合（Issue #344 で不変条件を反転した）。
# 旧: 同梱シード（131 件の旧形式）が allowlist で網羅されていること。
# 新: **同梱シードに旧テーブル形式が 1 件も無く、allowlist も同梱しないこと**。
# check-entry-format は allowlist 不在時に strict へ倒すので、旧形式シードを
# allowlist 無しで配ると利用者のコピー直後にゲートが赤くなる。逆に allowlist を
# 同梱すると「新規追記の抜け道」を配ることになる。両方を fail-loud に固定する。
if [ -e "$LEGACY_ALLOWLIST_TEMPLATE" ]; then
  bad "allowlist テンプレートを同梱しない（旧形式シードが 0 件なので不要。同梱すると新規追記の抜け道を配ることになる）: $LEGACY_ALLOWLIST_TEMPLATE"
else
  ok "allowlist テンプレートを同梱していない（旧形式シード 0 件・strict が既定）"
fi

TEMPLATE_PLAYBOOK_DIR="$PLUGIN_ROOT/docs-template/08-knowledge/playbook"
# ディレクトリ不在を skip にしない。`if [ -d ]` だけだと見本ごと消しても suite が緑になり、
# 「同梱物が消えた」を検出できない（検査 0 件の silent green）。
if [ ! -d "$TEMPLATE_PLAYBOOK_DIR" ]; then
  bad "docs-template の playbook ディレクトリが存在しない（見本エントリを同梱しないと分割レイアウトの実例が消える）: $TEMPLATE_PLAYBOOK_DIR"
else
  # 見出しと旧形式マーカーの認識は shell に再実装せず、
  # check-entry-format の機械可読 CLI へ委譲する（Issue #336）。
  # esbuild / node が無い場合は「旧形式 0 件」を検査したことにできないので、
  # 部分 skip にせず fail-closed で名指しする。
  if [ ! -x "$ESBUILD_BIN" ]; then
    bad "check-entry-format の CLI 実行に必要な esbuild が見つからない（cd mcp && npm install を実行）: $ESBUILD_BIN"
  elif ! command -v node >/dev/null 2>&1; then
    bad "check-entry-format の CLI 実行に必要な node が PATH に見つからない"
  else
    BUNDLE_DIR=""
    if ! BUNDLE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/ace-refine-format.XXXXXX")"; then
      bad "check-entry-format の検証用一時ディレクトリを作成できない: ${TMPDIR:-/tmp}"
    fi
    if [ -n "$BUNDLE_DIR" ]; then
    BUNDLE_PATH="$BUNDLE_DIR/check-entry-format.mjs"
    set +e
    # bundle すると import 先の `import.meta.url` も同じ出力ファイルを
    # 指し、check-category-size の direct-execution guard まで誤爆する。
    # 2 ファイルを個別 transpile し、extensionless import は type=module で解決する。
    BUILD_OUTPUT="$(
      set -e
      printf '%s\n' '{"type":"module"}' > "$BUNDLE_DIR/package.json"
      "$ESBUILD_BIN" "$CHECK_SIZE_SCRIPT" --platform=node --format=esm \
        --log-level=error --outfile="$BUNDLE_DIR/check-category-size"
      "$ESBUILD_BIN" "$FORMAT_GATE_SCRIPT" --platform=node --format=esm \
        --log-level=error --outfile="$BUNDLE_PATH"
    2>&1)"
    BUILD_RC=$?
    if [ "$BUILD_RC" -eq 0 ]; then
      SEED_IDS="$(node "$BUNDLE_PATH" --list-entry-ids "$TEMPLATE_PLAYBOOK_DIR" 2>&1)"
      SEED_LIST_RC=$?
      SEED_LEGACY_IDS="$(node "$BUNDLE_PATH" --list-legacy "$TEMPLATE_PLAYBOOK_DIR" 2>&1)"
      LIST_RC=$?
      FIXTURE_DIR="$BUNDLE_DIR/fixture"
      mkdir "$FIXTURE_DIR"
      {
        printf '%s%s\n\n' '### ' 'ACE-XXX: placeholder'
        printf '%s\n\n' '**Insight**: placeholder'
        printf '%s%s\n\n' '### ' 'ACE-2-1:タイトル'
        printf '%s\n\n' '**Insight**: legacy'
        printf '%s%s\n\n' '### ' 'ACE-1-1: first'
        printf '%s\n' '**Insight**: legacy'
      } > "$FIXTURE_DIR/a.md"
      {
        printf '%s%s\n\n' '### ' 'ACE-1-1: duplicate'
        printf '%s\n' '**Insight**: legacy'
      } > "$FIXTURE_DIR/b.md"
      FIXTURE_IDS="$(node "$BUNDLE_PATH" --list-legacy "$FIXTURE_DIR" 2>&1)"
      FIXTURE_RC=$?
      ERROR_FIXTURE_DIR="$BUNDLE_DIR/error-fixture"
      mkdir "$ERROR_FIXTURE_DIR"
      {
        printf '%s%s\n\n' '### ' 'ACE-1-1: before error'
        printf '%s\n' '**Insight**: legacy'
      } > "$ERROR_FIXTURE_DIR/a.md"
      printf '%s\n' '```markdown' > "$ERROR_FIXTURE_DIR/b.md"
      ERROR_STDOUT="$BUNDLE_DIR/error.stdout"
      ERROR_STDERR="$BUNDLE_DIR/error.stderr"
      node "$BUNDLE_PATH" --list-legacy "$ERROR_FIXTURE_DIR" \
        > "$ERROR_STDOUT" 2> "$ERROR_STDERR"
      ERROR_FIXTURE_RC=$?
      ERROR_STDOUT_CONTENT="$(cat "$ERROR_STDOUT")"
      ERROR_STDERR_CONTENT="$(cat "$ERROR_STDERR")"
    fi
    set -e
    case "$BUNDLE_DIR" in
      "${TMPDIR:-/tmp}"/ace-refine-format.*) rm -rf "$BUNDLE_DIR" ;;
      *) bad "mktemp が想定外のパスを返したため一時バンドルを消去しない: $BUNDLE_DIR" ;;
    esac
    if [ "$BUILD_RC" -ne 0 ]; then
      bad "check-entry-format の一時バンドル生成が失敗（rc=${BUILD_RC}）: $BUILD_OUTPUT"
    elif [ "$SEED_LIST_RC" -ne 0 ]; then
      bad "check-entry-format --list-entry-ids が失敗（rc=${SEED_LIST_RC}）: $SEED_IDS"
    elif [ "$SEED_IDS" != $'ACE-000-1\nACE-000-2\nACE-000-3' ]; then
      bad "docs-template の見本 ID 集合が期待と違う: $SEED_IDS"
    elif [ "$LIST_RC" -ne 0 ]; then
      bad "check-entry-format --list-legacy が失敗（rc=${LIST_RC}）: $SEED_LEGACY_IDS"
    elif [ "$FIXTURE_RC" -ne 0 ]; then
      bad "check-entry-format --list-legacy の統合 fixture が失敗（rc=${FIXTURE_RC}）: $FIXTURE_IDS"
    elif [ "$FIXTURE_IDS" != $'ACE-1-1\nACE-2-1' ]; then
      bad "check-entry-format --list-legacy が placeholder 除外・空白なし見出し・重複除去の契約と不一致: $FIXTURE_IDS"
    elif [ "$ERROR_FIXTURE_RC" -ne 2 ]; then
      bad "check-entry-format --list-legacy の入力エラーが exit 2 でない（rc=${ERROR_FIXTURE_RC}）"
    elif [ -n "$ERROR_STDOUT_CONTENT" ]; then
      bad "check-entry-format --list-legacy が入力エラー時に stdout へ部分結果を出した"
    elif ! grep -Fq 'b.md' <<< "$ERROR_STDERR_CONTENT" || ! grep -Fq '閉じていません' <<< "$ERROR_STDERR_CONTENT"; then
      bad "check-entry-format --list-legacy の入力エラー診断が対象ファイルと理由を stderr へ出していない"
    elif [ -n "$SEED_LEGACY_IDS" ]; then
      bad "docs-template のシードに旧テーブル形式が残っている（allowlist 不在では利用者のコピー直後にゲートが赤くなる）: $(printf '%s' "$SEED_LEGACY_IDS" | tr '\n' ' ')"
    else
      ok "check-entry-format の単一源判定で placeholder 除外・空白なし ID ・重複除去が一致し、docs-template の旧形式シードが 0 件"
    fi
    fi
  fi
fi

echo
if [ "$FAIL" -gt 0 ]; then
  echo "✗ ace-refine verify: $FAIL 件失敗" >&2
  exit 1
fi
echo "✓ ace-refine verify: 全 $PASS 件 pass"
