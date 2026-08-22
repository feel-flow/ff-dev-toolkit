#!/usr/bin/env bash
#
# docs 走査マスクの awk 版 / TS 版が同じ入力に同じ出力を返すことの機械照合（Issue #528）。
#
# Markdown の除外区間マスク（閉じたフェンス・閉じた HTML コメント）は 2 実装ある:
#   - awk: tests/lib/docs-scan.sh の ff_docs_mask_spans（docs 系 suite の共有実装）
#   - TS : mcp/src/utils.ts の maskClosedSpans（同梱 MCP の用語集索引が消費する）
# 「同じ意味論」とコメントで宣言してあるだけで、**一致を確かめる検査が無かった**。
# 実際に 2 回、片側だけが直った（Issue #517 / PR #523 が MCP 側を確定 → PR #524 が
# 共有 lib へ修正前の 2 パス版を移植 → レビュー指摘で単一パス化）。プレイブック
# docs/08-knowledge/playbook/coding.md はこの形を既に禁じている —
# 「両者の出力集合を照合して不一致なら非ゼロ終了する fail-loud ゲートを main に置く」。
#
# 本 suite はその常設ゲート。同型の先例は tests/ace-scripts-mirror /
# tests/agent-config-mirror（読まれない対応表を「検証されたミラー」へ格上げする型）。
#
# ── 方式 ──────────────────────────────────────────────────────────────────────
# fixtures/ の Markdown を **両実装が同じファイルから読む**（コーパスを 2 箇所へ
# 複製しない = AC-1）。TS 側は fixtures を読むだけのドライバ ts-mask.ts を
# mcp/node_modules の esbuild で一時領域へ束ねて node で実行する（src/utils.ts を
# そのまま消費するので、dist の鮮度に依存しない）。
#
# 照合は 2 段構えにする。相互一致（awk == TS）だけだと、**両実装が同じ誤りへ同時に
# 変化した共通退化**（共有 lib への移植ミス・同一の勘違いでの同時修正）を素通しする。
# fixtures/expected/<name>.masked に期待マスク出力を置き、awk / TS の**双方**を
# expected ともバイト比較する。3 点のうち 1 つでもずれたら赤になる。
#   期待値の更新手順（マスクの意味論を意図して変えたときだけ）:
#     f=<fixture 名>; . tests/lib/docs-scan.sh
#     ff_docs_mask_spans tests/docs-scan-mirror/fixtures/$f \
#       | awk '{ sub(/\r$/, ""); print }' \
#       > tests/docs-scan-mirror/fixtures/expected/${f%.md}.masked
#   生成物は必ず目視で確認する（実装の出力をそのまま祝福すると期待値の意味が消える）。
#
# ts-mask.ts は mcp/tsconfig.json の include（src / tests）の外にあり、**tsc の型検査
# 対象ではない**。専用の tsconfig は新設しない — 25 行のドライバ 1 本のために型検査
# ゲートをもう 1 系統増やす対価に見合わないため。契約は (1) esbuild の bundle が成功
# すること、(2) 出力が expected と一致すること の 2 つで担保する。maskClosedSpans の
# シグネチャが変わればドライバは bundle で落ちるか golden 差分として現れる。
#
# 姉妹の mirror ゲート（ace-scripts-mirror / agent-config-mirror）と違い、対になる
# `-selftest` suite は置かない。あちらの selftest が測る「ゲートの効き目」は、本 suite
# では expected 一致の検査そのものが毎回実測している（実装が変われば golden がずれる）。
# Issue #528 AC-3 の片側変異 8 種の実測結果は PR #729 に記録した。
#
# ── 正規化は 1 つだけ ─────────────────────────────────────────────────────────
# 各行の**末尾 CR 1 個**だけを両側から落とす。awk は RS="\n" で読むため CRLF ファイル
# では未マスク行に \r が残るが、TS 側の実消費者（buildGlossary）は `split(/\r?\n/)`
# 済みの行を受け取る。問うているのは「マスクするかどうかの判断」であって CR を保存
# するかではない。行末空白の除去や空行の畳み込みは**しない**（1 バイト違えば赤 = AC-2）。
#
# ── 対象外 ────────────────────────────────────────────────────────────────────
#   - ff_docs_mask_spans の `keep-fences` 引数には TS 側の対応物が無い。照合は既定
#     モードのみ（keep-fences のフェンス内保持は docs-fact-drift 側の関心事）。
#   - コーパスの行頭インデントは ASCII 空白に限る。awk 側は `[ \t]*`、TS 側は `\s*`
#     で、NBSP や垂直タブでは判定が割れる（実測済み。Issue #726）。**既知の未修正の
#     乖離**をこのコーパスへ入れると suite が常時赤になりゲートとして機能しないため、
#     #726 の修正と同時に fixture を足す前提で今は対象外にしている。
#
# ── 実行環境（AC-4） ─────────────────────────────────────────────────────────
# node / mcp/node_modules / 書き込み可能な一時領域のいずれかが無いと TS 側を 1 件も
# 実行できないため、行頭 `○ skip` + exit 0 で丸ごとスキップする（部分 skip はしない）。
# 検出力が環境都合で黙って消えないよう、run-all.sh の REQUIRED_SUITES に載せてある。
# node_modules はあるのに esbuild だけ無い場合は「install が不完全」なので fail-closed。

set -euo pipefail
# 名簿の展開（`for name in $REQUIRED_FIXTURES`）を単語分割だけに留め、パス名展開へ
# 晒さない。fixture 名に glob 文字が入った瞬間に、名簿が黙って別の集合になる。
set -f

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd -P)"
LIB="$PLUGIN_ROOT/tests/lib/docs-scan.sh"
MCP_DIR="$PLUGIN_ROOT/mcp"
FIXTURE_DIR="$SCRIPT_DIR/fixtures"
EXPECTED_DIR="$FIXTURE_DIR/expected"
DRIVER="$SCRIPT_DIR/ts-mask.ts"

for f in "$LIB" "$DRIVER"; do
  [ -f "$f" ] || { echo "✗ 検査対象が見つかりません: $f" >&2; exit 1; }
done
[ -d "$FIXTURE_DIR" ] || { echo "✗ fixture ディレクトリがありません: $FIXTURE_DIR" >&2; exit 1; }
[ -d "$EXPECTED_DIR" ] || { echo "✗ 期待出力ディレクトリがありません: $EXPECTED_DIR" >&2; exit 1; }

# AC-1 が列挙する境界ケース。**このコーパスから 1 件でも消えたら赤**にする
# （fixture を消せば照合は静かに緑のまま通るため、名簿を suite 側に持つ）。
# 追加は自由 — 名簿は下限であって上限ではない。
REQUIRED_FIXTURES="
closed-fence.md
unclosed-fence-opener.md
unclosed-comment-opener.md
inline-comments.md
fence-marker-mix.md
fence-comment-same-line.md
fence-length.md
indented-markers.md
arrow-before-opener.md
comment-wraps-fence.md
inline-code-span-quote.md
trailing-comment-opener.md
trailing-fence-opener.md
crlf.md
"

# 「閉じた span を 1 つも含まない」fixture の名簿。ここに載るものは masked == raw が
# **正しい**ので、下の「マスクが実際に効いている」検査を反転して適用する（ACE-725-1:
# 異常系だけでなく、変化しないのが正しい入力の green pin も対で置く）。
NOOP_FIXTURES="
trailing-comment-opener.md
trailing-fence-opener.md
"

CHECKS=0

# ── 実行環境の判定（skip / fail-closed） ─────────────────────────────────────
if ! command -v node >/dev/null 2>&1; then
  echo "○ skip: node が PATH に無いためスキップ（本 suite の検査は1件も実行されていません。node 22.12 以上を PATH へ通して有効化）"
  exit 0
fi
if [ ! -d "$MCP_DIR/node_modules" ]; then
  echo "○ skip: $MCP_DIR/node_modules が無いためスキップ（本 suite の検査は1件も実行されていません。cd mcp && npm install で有効化）"
  exit 0
fi
ESBUILD="$MCP_DIR/node_modules/.bin/esbuild"
if [ ! -x "$ESBUILD" ]; then
  echo "✗ node_modules はあるが esbuild が無い（npm install が不完全）: $ESBUILD" >&2
  exit 1
fi

# mktemp の stderr を捨てない。捨てると read-only 以外の失敗（TMPDIR が不正なパス・
# quota 超過など）まで「書き込み可能な環境で再実行してください」に誤帰属し、恒常的に
# 壊れた TMPDIR が suite を exit 0 で無効化し続ける。
if _mktemp_out="$(mktemp -d "${TMPDIR:-/tmp}/docs-scan-mirror.XXXXXX" 2>&1)"; then
  TMP="$_mktemp_out"
else
  echo "○ skip: 一時ディレクトリを作成できないためスキップ（本 suite の検査は1件も実行されていません。書き込み可能な環境で再実行してください）"
  printf '  mktemp: %s\n' "$_mktemp_out"
  exit 0
fi
# 途中死を沈黙させない。`set -u` 等で死んだときトラップ突入時の $? は 0 になり得るため、
# 素の `trap 'rm -rf ...' EXIT` だと「検査 0 件で pass」に見える（run-all case 12 の
# 再混入ガードが検出する形）。「rc=0 なのに最後まで到達していない」を中断として扱う。
FF_REACHED_END=0
_ff_exit_guard() {
  _ff_rc=$?
  rm -rf "$TMP"
  if [ "$_ff_rc" -eq 0 ] && [ "$FF_REACHED_END" -ne 1 ]; then
    echo "✗ docs-scan-mirror: 最後まで到達しませんでした（途中で中断）" >&2
    exit 1
  fi
  exit "$_ff_rc"
}
trap _ff_exit_guard EXIT

# TS 側ドライバを一時領域へ束ねる（作業ツリーへは 1 バイトも書かない）。
# src/utils.ts を直接束ねるので、コミット済み dist の鮮度には依存しない。
if ! BUNDLE_OUT="$("$ESBUILD" "$DRIVER" --bundle --platform=node --format=esm \
    --target=node22 --outfile="$TMP/ts-mask.mjs" 2>&1)"; then
  echo "✗ TS 側ドライバの bundle に失敗しました（node_modules はあるので環境都合ではない）" >&2
  printf '%s\n' "$BUNDLE_OUT" | tail -20 >&2
  exit 1
fi
[ -s "$TMP/ts-mask.mjs" ] || { echo "✗ bundle は成功したが出力が空です: $TMP/ts-mask.mjs" >&2; exit 1; }

# shellcheck source=../lib/docs-scan.sh
. "$LIB"

# 各行の末尾 CR 1 個だけを落とす（tr -d '\r' は行中の CR まで消すので使わない）。
# 正規表現の \r 解釈は awk の実装差があるため、printf で作った実バイトと比較する。
strip_trailing_cr() {
  awk -v cr="$(printf '\r')" '
    { if (length($0) > 0 && substr($0, length($0)) == cr) $0 = substr($0, 1, length($0) - 1); print }
  ' "$1"
}

fail() { echo "✗ $*" >&2; exit 1; }

# 行単位の差分報告（最大 10 件）。判定は呼び出し側が済ませてから使う診断専用で、
# 診断自体では絶対に落ちないようにする（`|| true`。ACE-700-2）。
# 引数: <fixture 名> <左のラベル> <右のラベル> <左ファイル> <右ファイル>
line_diff_report() {
  {
    awk -v name="$1" -v ll="$2" -v rl="$3" '
      NR == FNR { a[FNR] = $0; next }
      $0 != a[FNR] {
        bad++
        printf "    %s:%d\n      %-4s: [%s]\n      %-4s: [%s]\n", name, FNR, ll, a[FNR], rl, $0
        if (bad == 10) { print "    （以降の差分は省略）"; exit }
      }
    ' "$4" "$5" || true
  } >&2
}

# ── コーパスの実在ガード ─────────────────────────────────────────────────────
for name in $REQUIRED_FIXTURES; do
  [ -f "$FIXTURE_DIR/$name" ] || fail "AC-1 が要求する fixture がありません: $FIXTURE_DIR/$name"
  CHECKS=$((CHECKS + 1))
done
REQUIRED_COUNT="$(printf '%s\n' $REQUIRED_FIXTURES | wc -l | tr -d ' ')"

FIXTURES=""
FIXTURE_COUNT=0
while IFS= read -r path; do
  FIXTURES="$FIXTURES$path
"
  FIXTURE_COUNT=$((FIXTURE_COUNT + 1))
done <<EOF
$(find "$FIXTURE_DIR" -maxdepth 1 -type f -name '*.md' | LC_ALL=C sort)
EOF
[ "$FIXTURE_COUNT" -ge "$REQUIRED_COUNT" ] \
  || fail "fixture の実体が名簿より少ない（実体 ${FIXTURE_COUNT} 件 / 名簿 ${REQUIRED_COUNT} 件）"
CHECKS=$((CHECKS + 1))

# CRLF fixture が本当に CR を持っているか（チェックアウトの行末変換で \r が落ちると、
# CRLF ケースだけが黙って消える。fixtures/.gitattributes の `* -text` が効いている
# ことの実測でもある）。
if LC_ALL=C tr -d '\r' < "$FIXTURE_DIR/crlf.md" | cmp -s - "$FIXTURE_DIR/crlf.md"; then
  fail "crlf.md に CR がありません（行末変換で CRLF ケースの検出力が失われています）"
fi
CHECKS=$((CHECKS + 1))

# ── 本体: fixture ごとに awk 版 / TS 版 / 期待値をバイト比較する ─────────────
MISMATCH=0
GOLDEN_MISMATCH=0
while IFS= read -r fixture; do
  [ -n "$fixture" ] || continue
  name="$(basename "$fixture")"

  if ! ff_docs_mask_spans "$fixture" > "$TMP/awk.raw" 2> "$TMP/awk.err"; then
    echo "✗ ${name}: awk 版 (ff_docs_mask_spans) が非 0 で終了しました" >&2
    { tail -20 "$TMP/awk.err" || true; } >&2
    exit 1
  fi
  CHECKS=$((CHECKS + 1))

  if ! node "$TMP/ts-mask.mjs" "$fixture" > "$TMP/ts.raw" 2> "$TMP/ts.err"; then
    echo "✗ ${name}: TS 版 (maskClosedSpans ドライバ) が非 0 で終了しました" >&2
    { tail -20 "$TMP/ts.err" || true; } >&2
    exit 1
  fi
  CHECKS=$((CHECKS + 1))

  strip_trailing_cr "$TMP/awk.raw" > "$TMP/awk.norm"
  strip_trailing_cr "$TMP/ts.raw" > "$TMP/ts.norm"
  strip_trailing_cr "$fixture" > "$TMP/raw.norm"

  # 行数が入力と一致すること。どちらかが「入力を素通しする / 途中で打ち切る」形で
  # 壊れていても、両者が同時に壊れればバイト比較は緑になれる。行数の絶対値を入力から
  # 導出して固定し、照合が空回りしていないことを別軸で押さえる。
  in_lines="$(awk 'END { print NR }' "$fixture")"
  awk_lines="$(awk 'END { print NR }' "$TMP/awk.norm")"
  ts_lines="$(awk 'END { print NR }' "$TMP/ts.norm")"
  if [ "$awk_lines" != "$in_lines" ] || [ "$ts_lines" != "$in_lines" ]; then
    fail "${name}: 出力行数が入力と一致しません（入力 ${in_lines} / awk ${awk_lines} / ts ${ts_lines}）"
  fi
  CHECKS=$((CHECKS + 1))

  if ! cmp -s "$TMP/awk.norm" "$TMP/ts.norm"; then
    MISMATCH=$((MISMATCH + 1))
    echo "✗ ${name}: awk 版と TS 版の出力が一致しません" >&2
    line_diff_report "$name" awk ts "$TMP/awk.norm" "$TMP/ts.norm"
  fi
  CHECKS=$((CHECKS + 1))

  # golden（期待マスク出力）との照合。相互一致だけでは「両実装が同じ誤りへ同時に
  # 変化した共通退化」を検出できない（Codex レビュー指摘）。期待値を第三の固定点として
  # 置き、awk / TS の**双方**を expected とバイト比較する。
  expected="$EXPECTED_DIR/${name%.md}.masked"
  [ -f "$expected" ] || fail "${name}: 期待出力がありません: ${expected}（golden が消えると共通退化の検出力が失われます）"
  CHECKS=$((CHECKS + 1))

  if ! cmp -s "$TMP/awk.norm" "$expected"; then
    GOLDEN_MISMATCH=$((GOLDEN_MISMATCH + 1))
    echo "✗ ${name}: awk 版の出力が期待値 (${name%.md}.masked) と一致しません" >&2
    line_diff_report "$name" want awk "$expected" "$TMP/awk.norm"
  fi
  CHECKS=$((CHECKS + 1))

  if ! cmp -s "$TMP/ts.norm" "$expected"; then
    GOLDEN_MISMATCH=$((GOLDEN_MISMATCH + 1))
    echo "✗ ${name}: TS 版の出力が期待値 (${name%.md}.masked) と一致しません" >&2
    line_diff_report "$name" want ts "$expected" "$TMP/ts.norm"
  fi
  CHECKS=$((CHECKS + 1))

  # マスクが実際に効いていること（両側が同時に「何もしない」に退化すると、バイト
  # 比較は緑のまま何も検査しなくなる）。閉じた span を持たない fixture は逆に
  # 「変化しないのが正しい」ので、同じ比較を反転して固定する（ACE-725-1）。
  # 乖離検出のあとに置く: 片側だけが素通しへ退化した場合は、まず上の差分が出て
  # 原因（どちらがどう変わったか）が読める。
  case "$NOOP_FIXTURES" in
    *"
$name
"*)
      if ! cmp -s "$TMP/awk.norm" "$TMP/raw.norm" || ! cmp -s "$TMP/ts.norm" "$TMP/raw.norm"; then
        fail "${name}: 閉じた span が無い fixture なのに出力が入力と変わりました（過剰マスク）"
      fi
      ;;
    *)
      if cmp -s "$TMP/awk.norm" "$TMP/raw.norm" || cmp -s "$TMP/ts.norm" "$TMP/raw.norm"; then
        fail "${name}: マスクが 1 文字も効いていない側があります（素通しへの退化を疑ってください）"
      fi
      ;;
  esac
  CHECKS=$((CHECKS + 1))
done <<EOF
$FIXTURES
EOF

if [ "$MISMATCH" -ne 0 ]; then
  echo "✗ docs 走査マスクの awk 版 / TS 版が ${MISMATCH} 件の fixture で乖離しています" >&2
  echo "  awk: $LIB の ff_docs_mask_spans / TS: $MCP_DIR/src/utils.ts の maskClosedSpans" >&2
  echo "  片側だけ直すと再発します。両方を同時に直してください（Issue #528）" >&2
fi
if [ "$GOLDEN_MISMATCH" -ne 0 ]; then
  echo "✗ 期待マスク出力（${EXPECTED_DIR}）との不一致が ${GOLDEN_MISMATCH} 件あります" >&2
  echo "  マスクの意味論を意図して変えた場合のみ期待値を更新すること（更新手順は本 suite のヘッダー）" >&2
fi
[ "$MISMATCH" -eq 0 ] && [ "$GOLDEN_MISMATCH" -eq 0 ] || exit 1

# 検査総数のガード: ループが途中で飛んだり case が空振りしても、上の判定は 1 つも
# 赤にならずに「✓」へ到達できる。実行した検査の本数を fixture 数から導出した期待値と
# 突き合わせ、検査 0 件・部分実行の縮退を赤にする（ACE-542-1）。
EXPECTED_CHECKS=$((REQUIRED_COUNT + 2 + FIXTURE_COUNT * 8))
[ "$CHECKS" -eq "$EXPECTED_CHECKS" ] \
  || fail "実行した検査本数が期待値と一致しません（実測 ${CHECKS} / 期待 ${EXPECTED_CHECKS}）。ループの縮退を疑ってください"

echo "✓ docs-scan-mirror: fixture ${FIXTURE_COUNT} 件で awk 版 / TS 版 / 期待値が一致（検査 ${CHECKS} 件）"
FF_REACHED_END=1
