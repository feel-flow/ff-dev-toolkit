#!/usr/bin/env bash
#
# tests/retrospective-contract/ の検出力を、隔離 fixture への変異注入で実測する（Issue #540）。
#
# 契約文言ゲートは「針が本当に噛んでいるか」を規律だけで保つと、表現変更に追従した
# つもりの空振り（needle が 1 件も一致しないのに、別の検査が緑なので気付かない）へ
# 静かに退化する。ここで常設化する。
#
# 変異の系統:
#   1. チェーン記載サイトごとに `/retrospective` を削除し、対応する検査が赤化する
#      ことを全針で実測する（1 針でも死んでいれば代表 1 件の変異では分からないため、
#      per-site で回す）
#   2. 規定マーカーと消費側への伝播を、契約行の削除で 1 契約行ずつ実測する
#      （同一行に複数の針が乗る箇所は、宣言した複数件の赤化を照合する）
#   3. 導出値（提案上限・1 行報告）の片側書き換え・抽出不能化・併存という、
#      削除では再現できない壊れ方
#   4. ゲート自身の件数ガード（黙って縮む形）と、検査そのものが削除される侵食、
#      および本 suite 側の網羅ガード（針を増やして変異を増やし忘れた形）
#   5. 公開リポジトリ配置の分岐（モノレポ側でのみ、配置を模した第 2 fixture で）
#
# 各変異では**赤化した検査の数**まで照合する。「狙った検査**だけ**が赤化する」とは
# 主張しない — 実ファイルには 1 行に複数の針が乗る箇所があり（例: ace-curate の
# SKILL.md:252 はチェーン導線・チェーン表記・責務分離の 3 針を 1 行に含む）、そこでは
# 巻き添えが正常である。宣言した期待件数と実際の ✗ 件数が一致することを見ることで、
# 「1 変異で無関係な検査まで広く壊れる粗いゲート」への退化を検出する。
#
# **fixture は実行環境の配置を写す。** SSOT モノレポでは root README と
# oss/ff-dev-toolkit/README.md が別物だが、公開リポジトリでは後者がルートへ展開されて
# 同一ファイルになる。fixture を常にモノレポ形にすると、公開側では存在しない
# 「ルート README のメンテ導線」を要求して baseline が恒常的に赤くなり、本 suite が
# fail して run-all ごと落ちる（REQUIRED_SUITES 登録は skip を許さないための宣言で、
# fail の伝播とは別の話）。モノレポ側では、公開配置を模した第 2 fixture でその分岐も
# 実測する。
#
# 実作業ツリーは変更しない。perl / 一時領域が無い場合だけ suite 全体を ○ skip する。

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
REPO_ROOT="$(cd "$PLUGIN_ROOT/../.." && pwd)"

SRC_GATE="$PLUGIN_ROOT/tests/retrospective-contract/verify.sh"
SRC_SKILL="$PLUGIN_ROOT/skills/retrospective/SKILL.md"
SRC_ACE_CURATE="$PLUGIN_ROOT/skills/ace-curate/SKILL.md"
SRC_GIT_WORKFLOW="$PLUGIN_ROOT/docs-template/05-operations/deployment/git-workflow.md"
SRC_WORKFLOW_PRINCIPLES="$PLUGIN_ROOT/docs-template/05-operations/deployment/workflow-principles.md"
SRC_DEPLOYMENT="$PLUGIN_ROOT/docs-template/05-operations/DEPLOYMENT.md"
SRC_LEDGER_TEMPLATE="$PLUGIN_ROOT/docs-template/08-knowledge/OBSERVATIONS.md"

# ゲートが検査を何件実行するかの期待値。**検査そのものが削除される侵食**（文言変更で
# 赤くなった針を更新せず消して緑に戻す、という実運用で最も起こりやすい退化）は、
# 針ごとの変異では原理的に検出できない — 消えた針は変異しても赤くならないからだ。
# baseline の総数を縛ることでその 1 方向を塞ぐ。ゲートに検査を足したらここも上げる。
EXPECTED_GATE_CHECKS_MONOREPO=172
EXPECTED_GATE_CHECKS_PUBLIC=158

# 実行環境の配置を判定する（ゲート側と同じ判定を使う）。
if [[ -d "$REPO_ROOT/oss/ff-dev-toolkit" ]]; then
  IS_MONOREPO=1
  SRC_OSS_README="$REPO_ROOT/oss/ff-dev-toolkit/README.md"
  SRC_ROOT_README="$REPO_ROOT/README.md"
  EXPECTED_GATE_CHECKS="$EXPECTED_GATE_CHECKS_MONOREPO"
else
  IS_MONOREPO=0
  SRC_OSS_README="$REPO_ROOT/README.md"
  SRC_ROOT_README=""
  EXPECTED_GATE_CHECKS="$EXPECTED_GATE_CHECKS_PUBLIC"
fi

REQUIRED_SRC=(
  "$SRC_GATE"
  "$SRC_SKILL"
  "$SRC_ACE_CURATE"
  "$SRC_GIT_WORKFLOW"
  "$SRC_WORKFLOW_PRINCIPLES"
  "$SRC_DEPLOYMENT"
  "$SRC_OSS_README"
)
if [[ "$IS_MONOREPO" -eq 1 ]]; then
  REQUIRED_SRC+=("$SRC_ROOT_README")
fi
for file in "${REQUIRED_SRC[@]}"; do
  if [[ ! -s "$file" ]]; then
    echo "✗ retrospective-contract-selftest の入力が存在しないか空です: $file" >&2
    exit 1
  fi
done

if ! command -v perl >/dev/null 2>&1; then
  echo "○ skip: perl が無いため retrospective-contract-selftest の変異注入を実行できません（検査は1件も実行されていません）"
  exit 0
fi
# mktemp の診断を捨てると不正 TMPDIR と read-only を区別できないため、成功時のパスと
# 失敗時の理由を同じ変数へ受ける。
if _ff_mktemp_out="$(mktemp -d "${TMPDIR:-/tmp}/retrospective-contract-selftest.XXXXXX" 2>&1)"; then
  FIXTURE_ROOT="$_ff_mktemp_out"
else
  echo "○ skip: 一時ディレクトリを作成できないため retrospective-contract-selftest を実行できません（検査は1件も実行されていません）"
  printf '  mktemp: %s\n' "$_ff_mktemp_out"
  exit 0
fi

# trap の最終コマンドの終了ステータスが suite の rc を上書きし、途中死が pass に
# 化けるのを防ぐ末尾到達センチネル（ACE-352-1 / ACE-399-5）。
REACHED_END=0
cleanup() {
  local rc=$?
  rm -rf "$FIXTURE_ROOT"
  if [[ "$REACHED_END" -ne 1 && "$rc" -eq 0 ]]; then
    rc=1
  fi
  exit "$rc"
}
trap cleanup EXIT
trap 'exit 130' HUP INT TERM

# ── fixture 構築（実行環境と同じ相対配置） ────────────────────────────────────

FIX_REPO="$FIXTURE_ROOT/repo"
FIX_PLUGIN="$FIX_REPO/plugins/ff-dev-toolkit"
mkdir -p \
  "$FIX_PLUGIN/tests/retrospective-contract" \
  "$FIX_PLUGIN/skills/retrospective" \
  "$FIX_PLUGIN/skills/ace-curate" \
  "$FIX_PLUGIN/docs-template/05-operations/deployment"

GATE="$FIX_PLUGIN/tests/retrospective-contract/verify.sh"
FIX_SKILL="$FIX_PLUGIN/skills/retrospective/SKILL.md"
FIX_ACE_CURATE="$FIX_PLUGIN/skills/ace-curate/SKILL.md"
FIX_GIT_WORKFLOW="$FIX_PLUGIN/docs-template/05-operations/deployment/git-workflow.md"
FIX_WORKFLOW_PRINCIPLES="$FIX_PLUGIN/docs-template/05-operations/deployment/workflow-principles.md"
FIX_DEPLOYMENT="$FIX_PLUGIN/docs-template/05-operations/DEPLOYMENT.md"
FIX_LEDGER_TEMPLATE="$FIX_PLUGIN/docs-template/08-knowledge/OBSERVATIONS.md"
FIX_LEDGER_REPO="$FIX_REPO/docs/08-knowledge/OBSERVATIONS.md"

cp "$SRC_GATE" "$GATE"
chmod +x "$GATE"
cp "$SRC_SKILL" "$FIX_SKILL"
cp "$SRC_ACE_CURATE" "$FIX_ACE_CURATE"
cp "$SRC_GIT_WORKFLOW" "$FIX_GIT_WORKFLOW"
cp "$SRC_WORKFLOW_PRINCIPLES" "$FIX_WORKFLOW_PRINCIPLES"
cp "$SRC_DEPLOYMENT" "$FIX_DEPLOYMENT"
mkdir -p "$(dirname "$FIX_LEDGER_TEMPLATE")" "$(dirname "$FIX_LEDGER_REPO")"
cp "$SRC_LEDGER_TEMPLATE" "$FIX_LEDGER_TEMPLATE"
cp "$SRC_LEDGER_TEMPLATE" "$FIX_LEDGER_REPO"

# 公開配置では oss/ を作らない（作るとゲートがモノレポと誤認する）。
if [[ "$IS_MONOREPO" -eq 1 ]]; then
  mkdir -p "$FIX_REPO/oss/ff-dev-toolkit"
  FIX_OSS_README="$FIX_REPO/oss/ff-dev-toolkit/README.md"
  FIX_ROOT_README="$FIX_REPO/README.md"
  cp "$SRC_OSS_README" "$FIX_OSS_README"
  cp "$SRC_ROOT_README" "$FIX_ROOT_README"
else
  FIX_OSS_README="$FIX_REPO/README.md"
  FIX_ROOT_README=""
  cp "$SRC_OSS_README" "$FIX_OSS_README"
fi

PRISTINE="$FIXTURE_ROOT/pristine"
mkdir -p "$PRISTINE"
cp "$FIX_SKILL" "$PRISTINE/retrospective-SKILL.md"
cp "$FIX_ACE_CURATE" "$PRISTINE/ace-curate-SKILL.md"
cp "$FIX_GIT_WORKFLOW" "$PRISTINE/git-workflow.md"
cp "$FIX_WORKFLOW_PRINCIPLES" "$PRISTINE/workflow-principles.md"
cp "$FIX_DEPLOYMENT" "$PRISTINE/DEPLOYMENT.md"
cp "$FIX_LEDGER_TEMPLATE" "$PRISTINE/observations-template.md"
cp "$FIX_LEDGER_REPO" "$PRISTINE/observations-repo.md"
cp "$FIX_OSS_README" "$PRISTINE/oss-README.md"
[[ "$IS_MONOREPO" -eq 0 ]] || cp "$FIX_ROOT_README" "$PRISTINE/root-README.md"

restore_all() {
  cp "$PRISTINE/retrospective-SKILL.md" "$FIX_SKILL"
  cp "$PRISTINE/ace-curate-SKILL.md" "$FIX_ACE_CURATE"
  cp "$PRISTINE/git-workflow.md" "$FIX_GIT_WORKFLOW"
  cp "$PRISTINE/workflow-principles.md" "$FIX_WORKFLOW_PRINCIPLES"
  cp "$PRISTINE/DEPLOYMENT.md" "$FIX_DEPLOYMENT"
  cp "$SRC_LEDGER_TEMPLATE" "$FIX_LEDGER_TEMPLATE"
  cp "$SRC_LEDGER_TEMPLATE" "$FIX_LEDGER_REPO"
  cp "$PRISTINE/oss-README.md" "$FIX_OSS_README"
  [[ "$IS_MONOREPO" -eq 0 ]] || cp "$PRISTINE/root-README.md" "$FIX_ROOT_README"
}

PASS=0
FAIL=0
ok() {
  echo "  ✓ $1"
  PASS=$((PASS + 1))
}
bad() {
  echo "  ✗ $1" >&2
  FAIL=$((FAIL + 1))
}

GATE_OUT=""
GATE_RC=0
run_gate() { # $1=ゲートのパス
  set +e
  GATE_OUT="$(bash "$1" 2>&1)"
  GATE_RC=$?
  set -e
}

# ゲート出力から 1 つの数値を取り出す（見つからなければ空 = 呼び出し側で赤にする）。
gate_number() { # $1=sed の抽出式
  printf '%s\n' "$GATE_OUT" | sed -n "$1" | sed -n '1p'
}

# 成否で変わる診断部分だけを除き、baseline と変異を同じ検査ラベルへ戻す。
# contains のラベルは完全一致で扱う。任意の括弧や接頭辞を丸ごと落とさない。
gate_labels() { # $1=✓ または ✗。stdin=ゲートの実出力
  awk -v mark="$1" '
    index($0, "  " mark " ") == 1 {
      label = substr($0, length("  " mark " ") + 1)
      sub(/（不足: .*$/, "", label)
      sub(/（旧ルールが残存: .*$/, "", label)
      if (label ~ /^チェーン記載の検査対象が /) label = "チェーン記載の検査対象数"
      else if (label ~ /^チェーン記載の針が /) label = "チェーン記載の針数"
      else if (label ~ /^フォールバック針が /) label = "フォールバック針数"
      else if (label ~ /^提案上限を SKILL.md から導出: / || label ~ /^提案上限（最大 N 件）を SKILL.md から抽出できません/) label = "提案上限の導出"
      else if (label ~ /^提案上限が SKILL.md 内で一意/) label = "提案上限の一意性"
      else if (label ~ /^改善候補なしの 1 行報告を SKILL.md /) label = "1 行報告の導出"
      print label
    }
  '
}

# 例外は設けない。baseline の全ラベルを実測した赤で覆う。
# 空の observed でも FNR/NR の一致に依存せず、全 baseline を未実測にする。
check_label_coverage() { # $1=baseline ラベル $2=成功した変異の失敗ラベル
  local baseline="$1" observed="$2" missing duplicates
  if [[ ! -s "$baseline" ]]; then
    echo "ラベル被覆: baseline が空です" >&2
    return 1
  fi
  duplicates="$(LC_ALL=C sort "$baseline" | uniq -d)" || return 1
  if [[ -n "$duplicates" ]] || grep '^$' "$baseline" >/dev/null; then
    printf 'ラベル被覆: baseline の空または重複ラベル: %s\n' "$duplicates" >&2
    return 1
  fi
  missing="$(awk 'FILENAME == ARGV[1] { seen[$0] = 1; next } !($0 in seen) { print }' "$observed" "$baseline")" || return 1
  if [[ -n "$missing" ]]; then
    printf 'ラベル被覆: 未実測の検査名:\n%s\n' "$missing" >&2
    return 1
  fi
  return 0
}

BASELINE_LABELS="$FIXTURE_ROOT/baseline-labels"
OBSERVED_LABELS="$FIXTURE_ROOT/observed-labels"
: >"$OBSERVED_LABELS"

# 変異が実際にファイルへ適用されたことを確認する。針の空振り（対象文言の変更に
# 追従できていない）を「ゲートの検出力喪失」と誤診しないための分離。
assert_mutated() {
  local mutated="$1" pristine="$2" label="$3"
  if cmp -s "$mutated" "$pristine"; then
    bad "${label}: 変異が適用されていない（置換パターンの空振り — 対象文言の変更に追従が必要）"
    return 1
  fi
  return 0
}

# 変異後のゲート: 非 0 終了 + 狙った検査行（needle）が失敗として出力され、かつ
# 失敗した検査が宣言どおりの件数であること。rc だけを見ると「無関係な理由で赤い」を
# 検出成功と誤認し、件数を見ないと「1 変異で広く巻き添えに壊れる」を見逃す。
expect_red() {
  local label="$1" needle="$2" expected_fails="$3" gate="${4:-$GATE}" actual_fails
  run_gate "$gate"
  if [[ "$GATE_RC" -ne 1 ]]; then
    bad "${label}: 期待する exit 1 ではありません（exit ${GATE_RC}）"
    return
  fi
  if [[ "$GATE_OUT" != *"$needle"* ]]; then
    bad "${label}: 赤化したが狙った検査ではない（不足: ${needle}）"
    printf '%s\n' "$GATE_OUT" | sed -n '1,60p' >&2
    return
  fi
  # grep -c は入力を最後まで読むので、パイプ上流を SIGPIPE で殺さない（case 10）。
  # 一致 0 件のとき grep は rc=1 を返し、pipefail + set -e が suite ごと落とすため
  # `|| true` で無害化する（0 件は「巻き添え無し」であって実行時エラーではない）。
  actual_fails="$(printf '%s\n' "$GATE_OUT" | grep -c '^  ✗ ' || true)"
  if [[ "$actual_fails" -eq "$expected_fails" ]]; then
    if [[ "$gate" == "$GATE" ]]; then
      printf '%s\n' "$GATE_OUT" | gate_labels '✗' >>"$OBSERVED_LABELS"
    fi
    ok "${label}: 狙った検査が赤化（✗ ${actual_fails} 件）"
  else
    bad "${label}: 赤化した検査が ${actual_fails} 件（期待 ${expected_fails} 件）— 巻き添えの範囲が変わった（検査対象の文書を整形して 1 行を分割・結合した場合は、期待件数を実測し直すこと）"
    # 診断出力。0 件一致でも suite を落とさないよう rc を無害化する。
    printf '%s\n' "$GATE_OUT" | { grep '^  ✗ ' || true; } >&2
  fi
}

# 対象行からチェーン内のコマンド表記だけを取り除く（行そのものは残す）。AC が要求する
# 「チェーン記載 1 箇所からの削除」を、周辺の文脈を壊さずに再現する。
# mode=slash は `/retrospective`、mode=bare は git-workflow 冒頭サマリの裸表記
# `→ Retrospective` を対象にする（同じ導線でも表記が違うため）。
drop_chain_token() {
  local file="$1" needle="$2" mode="$3"
  if [[ "$mode" == "bare" ]]; then
    FF_NEEDLE="$needle" perl -pi -e 's{ → Retrospective}{}g if index($_, $ENV{FF_NEEDLE}) >= 0' "$file"
  else
    FF_NEEDLE="$needle" perl -pi -e 's{/retrospective}{}g if index($_, $ENV{FF_NEEDLE}) >= 0' "$file"
  fi
}

drop_lines_containing() {
  local file="$1" needle="$2"
  FF_NEEDLE="$needle" perl -ni -e 'print unless index($_, $ENV{FF_NEEDLE}) >= 0' "$file"
}

echo "== retrospective-contract 検出力 selftest =="
if [[ "$IS_MONOREPO" -eq 1 ]]; then
  echo "  (fixture 配置: SSOT モノレポ)"
else
  echo "  (fixture 配置: 公開リポジトリ)"
fi

# ── baseline: fixture 上でゲートが緑（崩れていたら変異の実測は無意味） ────────
run_gate "$GATE"
if [[ "$GATE_RC" -eq 0 ]]; then
  ok "baseline: ゲートが fixture 上で緑"
else
  bad "baseline: ゲートが fixture 上で赤（変異の実測は成立しない）"
  printf '%s\n' "$GATE_OUT" | sed -n '1,60p' >&2
fi

printf '%s\n' "$GATE_OUT" | gate_labels '✓' >"$BASELINE_LABELS"

# 侵食ガード: ゲートが実行した検査の総数を縛る（上の EXPECTED_GATE_CHECKS_* 参照）。
GATE_CHECKS_SEEN="$(gate_number 's/^✓ retrospective contract verify: 全 \([0-9]*\) 件 pass$/\1/p')"
if [[ -z "$GATE_CHECKS_SEEN" ]]; then
  bad "ゲートの検査総数を出力から読めません（サマリー行の書式変更。fail-closed）"
elif [[ "$GATE_CHECKS_SEEN" -eq "$EXPECTED_GATE_CHECKS" ]]; then
  ok "侵食ガード: ゲートの検査が ${GATE_CHECKS_SEEN} 件（期待どおり）"
else
  bad "侵食ガード: ゲートの検査が ${GATE_CHECKS_SEEN} 件（期待 ${EXPECTED_GATE_CHECKS} 件）— 検査の削除、または追加時の期待値未更新"
fi

# ゲートが自ら宣言するチェーン針数。source を正規表現で数えると、書式を変えた
# 針（波括弧なしの変数展開など）が数から漏れて「変異で実測されていない針」が
# 静かに増える。宣言値を出力から取れば書式に依存しない。
CHAIN_NEEDLES_DECLARED="$(gate_number 's/^  ✓ チェーン記載の針が \([0-9]*\) 件.*/\1/p')"

# 同じくフォールバック針の宣言値（Issue #640）。句単位変異（M-K〜M-Q）の実行数と
# 突き合わせる。GATE_OUT は後続の run_gate で毎回上書きされるので、baseline の
# 出力が残っているこの位置で取る。
FALLBACK_NEEDLES_DECLARED="$(gate_number 's/^  ✓ フォールバック針が \([0-9]*\) 件.*/\1/p')"

# ── 系統 1: チェーン記載サイトごとのコマンド削除 ─────────────────────────────
# 表の各行は「fixture ファイル|原本|針|ゲートが出す検査名|期待 ✗ 件数|変異モード」。
# 針はゲート側の CHAIN_SITES と同じ文字列を使う（片方だけ変えたら assert_mutated が
# 空振りとして赤にする）。ace-curate の SKILL.md:252 はチェーン導線・チェーン表記・
# D の責務分離という 3 針を 1 行に含むため、どちらの変異でも 3 件落ちる。
CHAIN="\`/merge-cleanup\` → \`/ace-curate\` → \`/retrospective\`"
CHAIN_MUTATIONS=(
  "${FIX_SKILL}|retrospective-SKILL.md|ワークフローチェーンの末尾に位置する: ${CHAIN}|retrospective SKILL の位置づけ|1|slash"
  "${FIX_GIT_WORKFLOW}|git-workflow.md|→ Cleanup → ACE → Retrospective|git-workflow のコアサイクル要約|1|bare"
  "${FIX_WORKFLOW_PRINCIPLES}|workflow-principles.md|cleanup / ACE / \`/retrospective\` の実施を含む|原則1 のルール本文|1|slash"
  "${FIX_ACE_CURATE}|ace-curate-SKILL.md|ACE 完了後、ワークフローチェーンの末尾として \`/retrospective\`|ace-curate 完了案内からの導線|3|slash"
  "${FIX_ACE_CURATE}|ace-curate-SKILL.md|（${CHAIN}）|ace-curate 完了案内のチェーン表記|3|slash"
  "${FIX_GIT_WORKFLOW}|git-workflow.md|### チェーン末尾: セッション振り返り（/retrospective）|git-workflow のチェーン末尾セクション|1|slash"
  "${FIX_GIT_WORKFLOW}|git-workflow.md|ACE 完了後、チェーンの末尾として \`/retrospective\` を毎回実行する（${CHAIN}）|git-workflow のチェーン表記|1|slash"
  "${FIX_WORKFLOW_PRINCIPLES}|workflow-principles.md|→ /merge-cleanup → ACE → /retrospective（セッション振り返り）|原則1 のフロー図|1|slash"
  "${FIX_WORKFLOW_PRINCIPLES}|workflow-principles.md|12. [ ] /retrospective（セッション振り返り）|標準チェックリストの末尾項目|1|slash"
  "${FIX_DEPLOYMENT}|DEPLOYMENT.md|ステップ 10 の後、チェーン末尾として \`/retrospective\`（セッション振り返り）を毎回実行する|DEPLOYMENT の主要ステップ末尾|1|slash"
  "${FIX_OSS_README}|oss-README.md|ワークフローチェーン末尾（${CHAIN}）のセッション振り返り|公開 README のスキル表|1|slash"
)
if [[ "$IS_MONOREPO" -eq 1 ]]; then
  CHAIN_MUTATIONS+=(
    "${FIX_ROOT_README}|root-README.md|ワークフローチェーン末尾（${CHAIN}）のセッション振り返り|ルート README のスキル表|1|slash"
    "${FIX_ROOT_README}|root-README.md|→ \`/ace-curate\`（ナレッジ蓄積）→ \`/retrospective\`（セッション振り返り・プロセス改善提案）|ルート README のメンテ導線|1|slash"
  )
fi

# 網羅ガードは**件数**しか見ないため、既存の変異を複製して数だけ合わせれば、新しい
# 針を一度も実測しないまま緑にできる。狙う検査名が表の中で一意であることを併せて縛り、
# その抜け道を塞ぐ（チェーン針・フォールバック針の両方で使う共通判定）。
# 空出力 = 一意。判定を関数へ出してあるのは、下でこのガード自身を合成入力で実測するため。
duplicate_names() { # $@=表の各行が狙う検査名
  local seen="" dups="" name
  for name in "$@"; do
    case "$seen" in
      *"[${name}]"*) dups="${dups}${name} " ;;
      *) seen="${seen}[${name}]" ;;
    esac
  done
  printf '%s' "$dups"
}

CHAIN_MUTATIONS_RUN=0
CHAIN_CHECK_NAMES=()
for mutation in "${CHAIN_MUTATIONS[@]}"; do
  m_file="${mutation%%|*}"
  m_rest="${mutation#*|}"
  m_pristine="${m_rest%%|*}"
  m_rest="${m_rest#*|}"
  m_needle="${m_rest%%|*}"
  m_rest="${m_rest#*|}"
  m_label="${m_rest%%|*}"
  m_rest="${m_rest#*|}"
  m_fails="${m_rest%%|*}"
  m_mode="${m_rest##*|}"
  drop_chain_token "$m_file" "$m_needle" "$m_mode"
  if assert_mutated "$m_file" "$PRISTINE/${m_pristine}" "チェーン削除: ${m_label}"; then
    expect_red "チェーン削除: ${m_label}" "✗ チェーン記載: ${m_label}" "$m_fails"
  fi
  CHAIN_MUTATIONS_RUN=$((CHAIN_MUTATIONS_RUN + 1))
  CHAIN_CHECK_NAMES+=("$m_label")
  restore_all
done

# ゲート側の針が増えたのに変異が追加されていない（= 実測されていない針がある）
# 状態を検出する。比較相手はゲートが baseline で宣言した針数。
if [[ -z "$CHAIN_NEEDLES_DECLARED" ]]; then
  bad "ゲートが宣言するチェーン針数を出力から読めません（検査名の書式変更。fail-closed）"
elif [[ "$CHAIN_MUTATIONS_RUN" -eq "$CHAIN_NEEDLES_DECLARED" ]]; then
  ok "チェーン変異 ${CHAIN_MUTATIONS_RUN} 件がゲートの針 ${CHAIN_NEEDLES_DECLARED} 件をすべて覆っている"
else
  bad "チェーン変異 ${CHAIN_MUTATIONS_RUN} 件に対しゲートの針は ${CHAIN_NEEDLES_DECLARED} 件（実測されていない針がある / 表が古い）"
fi

CHAIN_DUPLICATE_CHECKS="$(duplicate_names "${CHAIN_CHECK_NAMES[@]}")"
if [[ -z "$CHAIN_DUPLICATE_CHECKS" ]]; then
  ok "チェーン変異が狙う検査名は ${CHAIN_MUTATIONS_RUN} 件とも相異なる"
else
  bad "チェーン変異が同じ検査名を複数回狙っています（${CHAIN_DUPLICATE_CHECKS}）— 件数だけ合わせて実測されない針が残る"
fi

# ── 系統 2: 規定マーカーと消費側伝播の契約行削除 ─────────────────────────────
# ゲートの `contains` 針を 1 件ずつ落とし、対応する検査が赤化することを見る。
# 表の各行は「fixture ファイル|原本|削除する契約行|ゲートが出す検査名|期待 ✗ 件数」。
# 同一行に複数の針が乗っているものは期待件数を 2 以上にしてある（例: 実測限定と
# 一般論禁止は SKILL.md の同じ箇条書き行）。
MARKER_MUTATIONS=(
  "${FIX_SKILL}|retrospective-SKILL.md|gh repo view \"<SSOT owner/repo>\" --json defaultBranchRef --jq '.defaultBranchRef.name'|SSOT 照合: 既定ブランチ名を取得|1"
  "${FIX_SKILL}|retrospective-SKILL.md|git -C \"<SSOT clone>\" show \"<取得した SHA>:<対象 path>\"|SSOT 照合: clone は SHA と path を指定して読む|2"
  "${FIX_SKILL}|retrospective-SKILL.md|gh api \"repos/<SSOT owner/repo>/git/ref/heads/<既定ブランチ>\" --jq '.object.sha'|SSOT 照合: API は既定ブランチの SHA を取得|2"
  "${FIX_SKILL}|retrospective-SKILL.md|開発元が非公開・非開示で SSOT 関係を確認できない場合も、存在確認済みの配布元へ|起票先解決: 公開利用者の配布元 fallback を維持|1"
  "${FIX_SKILL}|retrospective-SKILL.md|git -C \"<marketplace checkout>\" remote get-url origin|起票先解決: marketplace の実在 remote を読む|1"
  "${FIX_SKILL}|retrospective-SKILL.md|**作業対象リポジトリの owner から類推しない**|起票先解決: owner を類推しない|1"
  "${FIX_SKILL}|retrospective-SKILL.md|**配布元と SSOT を区別する**|起票先解決: 開発元と配布ミラーの関係を確認|1"
  "${FIX_SKILL}|retrospective-SKILL.md|gh repo view \"<候補 owner/repo>\" --json nameWithOwner|起票先解決: repo の存在と正規名を確認|1"
  "${FIX_SKILL}|retrospective-SKILL.md|到達可能な SSOT。配布ミラーへ新規起票しない|起票先解決: 変更要求は SSOT へ|1"
  "${FIX_SKILL}|retrospective-SKILL.md|その公開 Issue へ返信。実装修正の管理先は SSOT|起票先解決: 公開報告への応答先を維持|1"
  "${FIX_SKILL}|retrospective-SKILL.md|そのプロジェクトで実測した remote の repo|起票先解決: プロジェクト固有課題の行先|1"
  "${FIX_SKILL}|retrospective-SKILL.md|**解決不能なら起票しない**|起票先解決: 未確定なら推測で起票しない|1"
  "${FIX_SKILL}|retrospective-SKILL.md|SSOT の既定ブランチで当該記述を照合する|SSOT 照合: 既定ブランチの実体を確認|1"
  "${FIX_SKILL}|retrospective-SKILL.md|git -C \"<SSOT clone>\" fetch \"<確認済み remote>\" \"refs/heads/<既定ブランチ>\"|SSOT 照合: clone は fetch した実体を確認|2"
  "${FIX_SKILL}|retrospective-SKILL.md|gh api -H \"Accept: application/vnd.github.raw+json\" \"repos/<SSOT owner/repo>/contents/<対象 path>?ref=<取得した SHA>\"|SSOT 照合: clone 不在でも API で確認|2"
  "${FIX_SKILL}|retrospective-SKILL.md|「SSOT では対応済み（該当コミット/該当箇所）」として提案を取り下げる|SSOT 照合: 修正済みは起票せず取り下げ|1"
  "${FIX_SKILL}|retrospective-SKILL.md|未修正の残余だけに絞った提案を提示|SSOT 照合: 一部修正は残余だけ提案|1"
  "${FIX_SKILL}|retrospective-SKILL.md|「照合不能」と記録し、「修正済みでない」と扱わない|SSOT 照合: 確認不能を未対応と混同しない|1"
  "${FIX_SKILL}|retrospective-SKILL.md|\`既存確認:\` 行へ SSOT の repo・既定ブランチ・確認した SHA/path|SSOT 照合: 結果と参照先を既存確認へ記録|1"
  "${FIX_SKILL}|retrospective-SKILL.md|**実測に限る**: このセッションで実測した手戻り・無駄時間、または台帳に実測として積まれた観測履歴|提案閾値: 実測したものに限定|2"
  "${FIX_SKILL}|retrospective-SKILL.md|該当する候補が無ければ、次の 1 行だけで終了する|提案閾値: 候補なしは 1 行で終了|1"
  "${FIX_SKILL}|retrospective-SKILL.md|**機微情報を提案本文へ引用しない**|提案閾値: 機微情報を引用しない|1"
  "${FIX_SKILL}|retrospective-SKILL.md|各提案に **起票先 repo** と **期待効果**|提案の構造: 必須 4 欄を列挙する|1"
  "${FIX_SKILL}|retrospective-SKILL.md|   - 実測: |出力形式: 実測欄|1"
  "${FIX_SKILL}|retrospective-SKILL.md|   - 既存確認: |出力形式: 既存確認欄|2"
  "${FIX_SKILL}|retrospective-SKILL.md|重複・方針矛盾なしと判断したか|出力形式: 既存確認欄は重複と方針矛盾の両方を判定して書く|2"
  "${FIX_SKILL}|retrospective-SKILL.md|   - 起票先: |出力形式: 起票先欄|1"
  "${FIX_SKILL}|retrospective-SKILL.md|   - 付与予定ラベル: |出力形式: 付与予定ラベル欄|1"
  "${FIX_SKILL}|retrospective-SKILL.md|   - 期待効果: |出力形式: 期待効果欄|1"
  "${FIX_SKILL}|retrospective-SKILL.md|### 起票前の既存確認（必須）|起票前の既存確認: 節が存在する|22"
  "${FIX_SKILL}|retrospective-SKILL.md|この行を書けない提案は提示しない|起票前の既存確認: 既存確認を書けない提案は提示しない|1"
  "${FIX_SKILL}|retrospective-SKILL.md|--state all --limit 200|起票前の既存確認: 既存 Issue 検索は state 非限定 + 取得上限を明示|1"
  # Issue #865: 確認の**タイミング**（閾値側）は単独の行に乗るため巻き添え無し。
  "${FIX_SKILL}|retrospective-SKILL.md|起票先 repo の既存 Issue 検索まで済ませてから提示する|提案閾値: 提示前に既存 Issue 検索を済ませる|1"
  # 「全文読み」と「明示か取り下げ」は同一行、「提示前に確認」と「確認不能時の向き」も
  # 同一行（節冒頭の段落）。どちらの組も行削除で 2 針が同時に落ちるので期待 ✗ は 2 件。
  "${FIX_SKILL}|retrospective-SKILL.md|矛盾する提案はそのまま出さず、方針側の変更提案であることを明示するか取り下げる|起票前の既存確認: 方針に矛盾する提案は明示か取り下げ|2"
  "${FIX_SKILL}|retrospective-SKILL.md|本文を**全文**読み（先頭だけで切らない）|起票前の既存確認: ヒットした Issue の本文を全文読む|2"
  "${FIX_SKILL}|retrospective-SKILL.md|提案を提示する**前**に、各提案について次を確認する|起票前の既存確認: 確認は提示前に行う（正本側）|2"
  "${FIX_SKILL}|retrospective-SKILL.md|は「重複なし」と扱わない|起票前の既存確認: 確認不能時は重複なしと扱わない|2"
  "${FIX_SKILL}|retrospective-SKILL.md|「振り返り」「retrospective」「セッション振り返り」「プロセス改善の提案」と言われたとき|frontmatter: trigger 語|2"
  "${FIX_SKILL}|retrospective-SKILL.md|**ユーザー承認を待つ**（承認なしに起票しない|承認境界: 起票前にユーザー承認を待つ|2"
  # read-only 行には read-only 針 + 定型記録針 + 起票承認針の 3 本が乗る（観測台帳の導入で
  # 書き込み境界が 2 系統へ分かれたため。行削除で 3 件赤化する）。
  "${FIX_SKILL}|retrospective-SKILL.md|振り返り工程ではファイル編集・コミット・Issue 作成を行わない|承認境界: 振り返り工程は read-only|3"
  "${FIX_SKILL}|retrospective-SKILL.md|**振り返りに入る前に、必ず最初にモードを判定する**|ask モード: 判定を先頭で行う|1"
  "${FIX_SKILL}|retrospective-SKILL.md|利用者が本スキルを明示指定した → 環境変数に関係なく実施する|ask/off モード: 明示指定は環境変数を上書き|1"
  "${FIX_SKILL}|retrospective-SKILL.md|printenv RETROSPECTIVE_MODE|ask モード: 環境変数を実測するコマンド|1"
  "${FIX_SKILL}|retrospective-SKILL.md|出力が \`ask\` なら ask モード|ask/off モード: 判定結果の値域|1"
  "${FIX_SKILL}|retrospective-SKILL.md|**off モード**: 事前注入と Stop fallback はどちらも動作せず|off モード: 自動振り返りを無効化|1"
  "${FIX_SKILL}|retrospective-SKILL.md|**毎回実施・問いかけなし**|既定モード: 問いかけなしで毎回実施|1"
  "${FIX_SKILL}|retrospective-SKILL.md|## 自動発火（事前注入 + Stop fallback）|自動発火: 事前注入と Stop fallback 節|1"
  "${FIX_SKILL}|retrospective-SKILL.md|ユーザー依頼の作業がこの応答で完了する|自動発火: 完了時は振り返りを実施|1"
  "${FIX_SKILL}|retrospective-SKILL.md|質問・承認待ち・外部状態待ち・作業途中である|自動発火: 未完了時は対象外|1"
  "${FIX_SKILL}|retrospective-SKILL.md|UserPromptSubmit の \`additionalContext\`|自動発火: 応答生成前に振り返り契約を注入|1"
  # Issue #840: 非対話単発実行のスキップ規定は判定リスト項目 5 の単独行に乗る。
  "${FIX_SKILL}|retrospective-SKILL.md|Codex の非対話の単発実行（UserPromptSubmit 入力に \`model\` があり|自動発火: 非対話の単発実行には事前注入しない|1"
  "${FIX_SKILL}|retrospective-SKILL.md|本スキルで扱わず、\`/ace-curate\`（または ACE Playbook への追記）へ回す|責務分離: retrospective 側からの送り先明示|1"
  # 観測台帳（起票の前段バッファ・KPT 拡張・ADR-046 の分散台帳）の針。同一行に 2 針が乗る
  # 箇所（節冒頭の段落・起票先分岐の bullet）だけ期待 ✗ を 2 にしてある（下の注記）。
  "${FIX_SKILL}|retrospective-SKILL.md|## 観測の記録 — 観測台帳（起票の前段バッファ）|観測台帳: 節が存在する|1"
  # 節冒頭の段落には「まず台帳へ記録」と「作業中リポジトリの台帳」の 2 針が乗る（ADR-046）。
  "${FIX_SKILL}|retrospective-SKILL.md|まず**観測台帳**へ記録する|観測台帳: 起票前にまず台帳へ記録|2"
  "${FIX_SKILL}|retrospective-SKILL.md|台帳は**作業中のリポジトリ**の \`docs/08-knowledge/OBSERVATIONS.md\`|観測台帳: 作業中リポジトリの台帳へ記録|2"
  "${FIX_SKILL}|retrospective-SKILL.md|**累計 3 回**に到達し、対応 Issue が未リンク|観測台帳: Issue 昇格の閾値|1"
  "${FIX_SKILL}|retrospective-SKILL.md|**特急レーン**|観測台帳: 重大観測の特急レーン|1"
  "${FIX_SKILL}|retrospective-SKILL.md|アクションに繋がらない Keep は記録しない|観測台帳: Keep はアクションに繋がるものだけ記録|1"
  "${FIX_SKILL}|retrospective-SKILL.md|\`\${FF_DEV_TOOLKIT_ROOT}/docs-template/08-knowledge/OBSERVATIONS.md\` をコピーして作成する|観測台帳: 不在時はテンプレートから作成|1"
  "${FIX_SKILL}|retrospective-SKILL.md|受け渡し便）は**廃止**した|観測台帳: 受け渡し便の廃止を明記|1"
  # 起票先分岐の bullet には「改善対象で分岐」と「プロジェクト固有はそのリポジトリへ」の 2 針が乗る。
  "${FIX_SKILL}|retrospective-SKILL.md|**昇格の起票先は改善対象で分岐する**|観測台帳: 起票先は改善対象で分岐|2"
  "${FIX_SKILL}|retrospective-SKILL.md|作業中プロジェクト固有のプロセス・手順なら**作業中リポジトリ自身**の Issue|観測台帳: プロジェクト固有はそのリポジトリへ|2"
  "${FIX_SKILL}|retrospective-SKILL.md|検索対象は **SSOT と配布ミラーの両方**で|観測台帳: 旧経路残件は両リポジトリを検索|1"
  "${FIX_SKILL}|retrospective-SKILL.md|\`（owner/repo#N より取り込み）\` マーカー|観測台帳: 取り込みマーカーはリポジトリ修飾|1"
  "${FIX_SKILL}|retrospective-SKILL.md|そのリポジトリで ACE Playbook の直コミットに使っている経路（PR 化等）に揃える|観測台帳: 直 push 不可のリポジトリは Playbook 直コミットの経路に揃える|1"
  "${FIX_SKILL}|retrospective-SKILL.md|**台帳へ書き込めないリポジトリ**|観測台帳: 書き込めないリポジトリの扱いを定義|1"
  "${FIX_SKILL}|retrospective-SKILL.md|台帳へ書き込めないリポジトリだけがこの限定の対象外|提案閾値: 書き込めないリポジトリだけが閾値限定の対象外|1"
  "${FIX_SKILL}|retrospective-SKILL.md|**SSOT リポジトリで本スキルを実行するとき**に SSOT の台帳へ取り込む|観測台帳: 旧経路残件の取り込みは SSOT 実行時に限る|1"
  "${FIX_SKILL}|retrospective-SKILL.md|昇格の判定と提案は、台帳を更新したリポジトリで|観測台帳: 昇格判定は台帳を更新したリポジトリで行う|1"
  # mitigated（対策済み）の終端状態（Issue #1138）。値域・所在の書式・判定からの除外・
  # 復帰条件はそれぞれ独立の bullet に乗るので、期待 ✗ はいずれも 1 件。
  "${FIX_SKILL}|retrospective-SKILL.md|**昇格閾値の判定対象は \`Status\` が \`active\` のエントリに限る**|観測台帳: 閾値判定の対象は active に限る|1"
  "${FIX_SKILL}|retrospective-SKILL.md|**\`mitigated\`（対策済み）**|観測台帳: mitigated（対策済み）の定義|1"
  "${FIX_SKILL}|retrospective-SKILL.md|\`skill:<スキル名>\`、文書なら \`doc:<path>#<アンカー>\`|観測台帳: 対策の所在は接頭辞付きの書式で書く|1"
  "${FIX_SKILL}|retrospective-SKILL.md|**昇格提案は再演しない**|観測台帳: mitigated の再発で昇格提案を再演しない|1"
  "${FIX_SKILL}|retrospective-SKILL.md|**\`active\` への復帰条件**|観測台帳: mitigated から active への復帰条件|1"
  "${FIX_SKILL}|retrospective-SKILL.md|(a) **対策が失われた**|観測台帳: 復帰条件 (a) 対策の消失|1"
  "${FIX_SKILL}|retrospective-SKILL.md|(b) **対策が効いていない**|観測台帳: 復帰条件 (b) 対策が効いていない|1"
  "${FIX_SKILL}|retrospective-SKILL.md|\`archived\` との違いは**再発しているか**|観測台帳: archived / promoted との違いを併記|1"
  "${FIX_SKILL}|retrospective-SKILL.md|代わりに \`Status\` を \`mitigated\`、\`Issue\` を対策の所在へ更新する|承認と起票: 見送りは mitigated へ書き戻す|1"
  "${FIX_SKILL}|retrospective-SKILL.md|**閾値は発火点であり、発火時に取った判断は状態として台帳へ書き戻す。**|提案閾値: 閾値到達時の判断を状態として書き戻す|1"
  # レビュー指摘 1〜3（復帰の完全性・参照先の確認・取り下げ経路からの書き戻し）の針。
  # いずれも独立の行に乗るので期待 ✗ は 1 件。
  "${FIX_SKILL}|retrospective-SKILL.md|戻すときは **\`Issue\` 列も \`なし\` へ戻す**|観測台帳: 復帰時は Issue 列も なし へ戻す|1"
  "${FIX_SKILL}|retrospective-SKILL.md|**\`mitigated\` の再発を記録するときは \`Issue\` 列の参照先を確認する**|観測台帳: mitigated の再発時に参照先を確認する|1"
  "${FIX_SKILL}|retrospective-SKILL.md|**取り下げても台帳は書き戻す**|SSOT 照合: 取り下げた閾値到達エントリは mitigated へ書き戻す|1"
  "${FIX_SKILL}|retrospective-SKILL.md|**恒久対策の Issue を指していて新規起票を見送った**|知見ストア: 起票を見送った閾値到達エントリは mitigated へ書き戻す|1"
  # 本体台帳側の値域行を落とす。テンプレは無傷なので、照合分岐だけが赤化する
  # （公開 fixture では実行されない分岐を、モノレポ fixture の変異で担保する）。
  "${FIX_LEDGER_REPO}|observations-repo.md|- \`Status\` の値域: |観測台帳: 本体台帳の Status 値域行が配布テンプレと一致|1"
  # 値域行そのものの削除は導出の fail-closed 経路（下流 3 針は導出できず実行されない）。
  "${FIX_LEDGER_TEMPLATE}|observations-template.md|- \`Status\` の値域: |観測台帳: Status 値域行を配布テンプレから導出|1"
  "${FIX_GIT_WORKFLOW}|git-workflow.md|観測は起票の前に**作業中リポジトリ**の観測台帳|分散台帳が git-workflow へ伝播|1"
  # workflow-principles の承認境界行には「承認待ち」「実施まで」「分散台帳」の 3 針が乗る。
  "${FIX_WORKFLOW_PRINCIPLES}|workflow-principles.md|観測記録は作業中リポジトリの観測台帳への定型書き込み|分散台帳が workflow-principles へ伝播|3"
  "${FIX_SKILL}|retrospective-SKILL.md|**再現価値のある成功パターン（Keep）**|観察チェックリスト: Keep レンズ|1"
  "${FIX_SKILL}|retrospective-SKILL.md|**過剰動作**|観察チェックリスト: 過剰動作レンズ|1"
  "${FIX_ACE_CURATE}|ace-curate-SKILL.md|ACE Playbook ではなく \`/retrospective\` の提案経路で扱う|責務分離: ACE 側からの送り先明示|3"
  "${FIX_GIT_WORKFLOW}|git-workflow.md|承認なしには起票しない|承認境界が git-workflow へ伝播|4"
  "${FIX_WORKFLOW_PRINCIPLES}|workflow-principles.md|ユーザー承認を待ってから行う|承認境界が workflow-principles へ伝播|3"
  "${FIX_WORKFLOW_PRINCIPLES}|workflow-principles.md|\`/retrospective\` の起票のみ承認待ち|承認境界が適用タイミング表へ伝播|1"
  "${FIX_DEPLOYMENT}|DEPLOYMENT.md|起票はユーザー承認後のみ|承認境界が DEPLOYMENT へ伝播|3"
  "${FIX_OSS_README}|oss-README.md|起票はユーザー承認後のみ|承認境界が公開 README へ伝播|4"
  "${FIX_OSS_README}|oss-README.md|作業中リポジトリの観測台帳（無ければテンプレートから作成）へ記録し|分散台帳が公開 README へ伝播|4"
  # フォールバック行には 7 針（フォールバック本体・スキル名の確認手順・プレフィックス
  # 両試行・別レジストリの区別・分割インストールの原因/実体突き合わせ/結論ガード、
  # Issue #574 / #607 / #630）が同一行に乗るため、行削除で 7 件赤化する。
  "${FIX_GIT_WORKFLOW}|git-workflow.md|**スキル未解決時のフォールバック**|スキル未解決時のフォールバック: plugins/ff-dev-toolkit/docs-template/05-operations/deployment/git-workflow.md|7"
  "${FIX_WORKFLOW_PRINCIPLES}|workflow-principles.md|**スキル未解決時のフォールバック**|スキル未解決時のフォールバック: plugins/ff-dev-toolkit/docs-template/05-operations/deployment/workflow-principles.md|7"
  "${FIX_DEPLOYMENT}|DEPLOYMENT.md|**スキル未解決時のフォールバック**|スキル未解決時のフォールバック: plugins/ff-dev-toolkit/docs-template/05-operations/DEPLOYMENT.md|7"
  # oss README のラベルは配置で変わる（モノレポ: oss/ff-dev-toolkit/README.md /
  # 公開: README.md）ため、両配置で一致する接頭辞だけを針にする（M-G と同じ扱い）。
  "${FIX_OSS_README}|oss-README.md|**スキル未解決時のフォールバック**|スキル未解決時のフォールバック:|7"
)
if [[ "$IS_MONOREPO" -eq 1 ]]; then
  MARKER_MUTATIONS+=(
    "${FIX_ROOT_README}|root-README.md|起票はユーザー承認後のみ|承認境界がルート README へ伝播|4"
    "${FIX_ROOT_README}|root-README.md|作業中リポジトリの観測台帳（無ければテンプレートから作成）へ記録し|分散台帳がルート README へ伝播|4"
    "${FIX_ROOT_README}|root-README.md|**スキル未解決時のフォールバック**|スキル未解決時のフォールバック: README.md|7"
  )
fi

for mutation in "${MARKER_MUTATIONS[@]}"; do
  m_file="${mutation%%|*}"
  m_rest="${mutation#*|}"
  m_pristine="${m_rest%%|*}"
  m_rest="${m_rest#*|}"
  m_needle="${m_rest%%|*}"
  m_rest="${m_rest#*|}"
  m_label="${m_rest%|*}"
  m_fails="${m_rest##*|}"
  drop_lines_containing "$m_file" "$m_needle"
  if assert_mutated "$m_file" "$PRISTINE/${m_pristine}" "契約行削除: ${m_label}"; then
    expect_red "契約行削除: ${m_label}" "✗ ${m_label}" "$m_fails"
  fi
  restore_all
done

# 見出しや行を残したまま実操作だけが消える退化を検出する（レビュー指摘）。
# 行削除だけでは fetch/show と ref/contents の片方だけの欠落を実測できない。
SSOT_OPERATION_MUTATIONS=(
  "gh repo view \"<SSOT owner/repo>\" --json defaultBranchRef --jq '.defaultBranchRef.name'|SSOT 照合: 既定ブランチ名を取得"
  "git -C \"<SSOT clone>\" fetch \"<確認済み remote>\" \"refs/heads/<既定ブランチ>\"|SSOT 照合: clone は fetch した実体を確認"
  "git -C \"<SSOT clone>\" show \"<取得した SHA>:<対象 path>\"|SSOT 照合: clone は SHA と path を指定して読む"
  "gh api \"repos/<SSOT owner/repo>/git/ref/heads/<既定ブランチ>\" --jq '.object.sha'|SSOT 照合: API は既定ブランチの SHA を取得"
  "gh api -H \"Accept: application/vnd.github.raw+json\" \"repos/<SSOT owner/repo>/contents/<対象 path>?ref=<取得した SHA>\"|SSOT 照合: clone 不在でも API で確認"
)
for mutation in "${SSOT_OPERATION_MUTATIONS[@]}"; do
  m_clause="${mutation%|*}"
  m_label="${mutation##*|}"
  FF_CLAUSE="$m_clause" perl -pi -e 's{\Q$ENV{FF_CLAUSE}\E}{}' "$FIX_SKILL"
  if assert_mutated "$FIX_SKILL" "$PRISTINE/retrospective-SKILL.md" "SSOT 操作句削除: ${m_label}"; then
    expect_red "SSOT 操作句削除: ${m_label}" "✗ ${m_label}" 1
  fi
  restore_all
done

# ── 系統 3: 導出値の壊し方（削除では再現できないもの） ───────────────────────

# M-A: 提案上限の本文値だけを書き換える（frontmatter は 3 のまま = 片側書き換え）。
# 併存した上限を一意性検査も拾うため、赤化は 2 件になる。
perl -pi -e 's/\Q**最大 3 件**\E/**最大 5 件**/' "$FIX_SKILL"
if assert_mutated "$FIX_SKILL" "$PRISTINE/retrospective-SKILL.md" "M-A 提案上限の片側書き換え"; then
  expect_red "M-A 提案上限の片側書き換え（本文 3→5）" "✗ 提案閾値: 本文の上限が frontmatter と一致" 2
fi
restore_all

# M-B: frontmatter の上限表記だけを言い換える（数値は 3 のまま）。導出値・本文・
# 消費側をすべて無傷にしたまま、frontmatter 側の針だけを落とす隔離変異。
perl -pi -e 's/\Q改善提案を最大 3 件出す\E/改善提案は最大 3 件までとする/' "$FIX_SKILL"
if assert_mutated "$FIX_SKILL" "$PRISTINE/retrospective-SKILL.md" "M-B frontmatter の上限表記の言い換え"; then
  expect_red "M-B frontmatter の上限表記の言い換え" "✗ 提案閾値: frontmatter description の上限表記が残存" 1
fi
restore_all

# M-C: 提案上限を抽出できない形へ（漢数字化）— fail-closed 経路の実測
perl -pi -e 's/最大 3 件/最大三件/g' "$FIX_SKILL"
if assert_mutated "$FIX_SKILL" "$PRISTINE/retrospective-SKILL.md" "M-C 提案上限の抽出不能化"; then
  expect_red "M-C 提案上限の抽出不能化（漢数字）" "提案上限（最大 N 件）を SKILL.md から抽出できません" 1
fi
restore_all

# M-D: 超過時の絞り込みの一文だけ古い上限が残る（上限を変えたときの追従漏れ）
perl -pi -e 's/\Q3 件を超える候補がある場合\E/2 件を超える候補がある場合/' "$FIX_SKILL"
if assert_mutated "$FIX_SKILL" "$PRISTINE/retrospective-SKILL.md" "M-D 絞り込み文の上限だけ変更"; then
  expect_red "M-D 絞り込み文の上限だけ変更（3→2）" "✗ 提案閾値: 超過時は効果順に絞る" 1
fi
restore_all

# M-E: 異なる上限の併存（正しい値を残したまま別の値を追記）
printf '\n%s\n' '補足: 状況によっては最大 5 件まで出してよい。' >>"$FIX_SKILL"
if assert_mutated "$FIX_SKILL" "$PRISTINE/retrospective-SKILL.md" "M-E 上限の併存"; then
  expect_red "M-E 上限の併存（3 と 5 が同居）" "✗ 提案上限が SKILL.md 内で一意でありません" 1
fi
restore_all

# M-T: 退役した observation 受け渡し便の起票規則（ADR-046）を逐語復元する — not_contains
# 針の実測。契約行は全て無傷のまま、旧規則の 1 文だけを末尾へ追記する。
printf '\n%s\n' '- **SSOT 以外のリポジトリで作業中**: 台帳へ直接書かず、観測を SSOT リポジトリへ `[observation]` 接頭辞の Issue として受け渡す' >>"$FIX_SKILL"
if assert_mutated "$FIX_SKILL" "$PRISTINE/retrospective-SKILL.md" "M-T 旧受け渡し便の逐語復元"; then
  expect_red "M-T 旧受け渡し便の逐語復元（not_contains）" "✗ 観測台帳: 旧受け渡し便の起票規則が復元されていない" 1
fi
restore_all

# M-U: テンプレートの削除 — 記録手順 0 のコピー元が消えたことを実在検査が捕まえる。
# 値域行の導出元でもあるため、実在検査と導出の fail-closed が同時に赤化する（✗ 2 件）。
rm -f "$FIX_LEDGER_TEMPLATE"
if [[ ! -f "$FIX_LEDGER_TEMPLATE" ]]; then
  expect_red "M-U 台帳テンプレートの削除" "✗ 観測台帳: テンプレート docs-template/08-knowledge/OBSERVATIONS.md が実在する" 2
else
  bad "M-U 台帳テンプレートの削除: 変異が適用されていない"
fi
restore_all

# M-Y: 配布テンプレの Status 値域から mitigated を落とす。値域の欠落（下流の針）と、
# 本体台帳との片側 drift（一致の針）が同時に赤化する = 期待 ✗ は 2 件。
perl -pi -e 's/\Q`mitigated`（対策済み\E/`deprecated`（対策済み/' "$FIX_LEDGER_TEMPLATE"
if assert_mutated "$FIX_LEDGER_TEMPLATE" "$PRISTINE/observations-template.md" "M-Y テンプレ値域から mitigated を落とす"; then
  expect_red "M-Y 配布テンプレの Status 値域から mitigated を落とす" "✗ 観測台帳: 配布テンプレの Status 値域に mitigated がある" 2
fi
restore_all

# M-Z: 配布テンプレの値域行の所在接頭辞だけを SKILL.md に無いものへ差し替える。
# 接頭辞の一致（片側 drift）と本体台帳との一致が同時に赤化する = 期待 ✗ は 2 件。
perl -pi -e 's/\Q`skill:\E/`plugin:/' "$FIX_LEDGER_TEMPLATE"
if assert_mutated "$FIX_LEDGER_TEMPLATE" "$PRISTINE/observations-template.md" "M-Z 値域行の所在接頭辞の差し替え"; then
  expect_red "M-Z 値域行の所在接頭辞を SKILL.md に無いものへ差し替え" "✗ 観測台帳: 所在の接頭辞が値域行と SKILL.md で一致" 2
fi
restore_all

# M-V〜M-X: 消費側文書へ旧規則（SSOT 台帳 / observation Issue 起票）を逐語復元する — not_contains 針の実測。
printf '\n%s\n' '> 観測記録は SSOT の観測台帳への定型書き込み（SSOT 以外のリポジトリからの observation Issue 起票は観測記録に含まれず、承認後に行う）。' >>"$FIX_WORKFLOW_PRINCIPLES"
if assert_mutated "$FIX_WORKFLOW_PRINCIPLES" "$PRISTINE/workflow-principles.md" "M-V workflow-principles の旧受け渡し便復元"; then
  expect_red "M-V workflow-principles の旧受け渡し便復元（not_contains）" "✗ workflow-principles: 旧受け渡し便の記述が復元されていない" 1
fi
restore_all

printf '\n%s\n' '実測した手戻りを SSOT の観測台帳へ記録し、閾値到達で提案する。' >>"$FIX_OSS_README"
if assert_mutated "$FIX_OSS_README" "$PRISTINE/oss-README.md" "M-W 公開 README の旧 SSOT 台帳復元"; then
  expect_red "M-W 公開 README の旧 SSOT 台帳復元（not_contains）" "✗ 公開 README: 旧 SSOT 台帳の記述が復元されていない" 1
fi
restore_all

if [[ "$IS_MONOREPO" -eq 1 ]]; then
  printf '\n%s\n' '実測した手戻りを SSOT の観測台帳へ記録し、閾値到達で提案する。' >>"$FIX_ROOT_README"
  if assert_mutated "$FIX_ROOT_README" "$PRISTINE/root-README.md" "M-X ルート README の旧 SSOT 台帳復元"; then
    expect_red "M-X ルート README の旧 SSOT 台帳復元（not_contains）" "✗ ルート README: 旧 SSOT 台帳の記述が復元されていない" 1
  fi
  restore_all
fi

# M-F: 消費側（DEPLOYMENT）の上限だけを書き換える
perl -pi -e 's/最大 3 件/最大 5 件/g' "$FIX_DEPLOYMENT"
if assert_mutated "$FIX_DEPLOYMENT" "$PRISTINE/DEPLOYMENT.md" "M-F 消費側の上限書き換え"; then
  expect_red "M-F 消費側の上限書き換え（DEPLOYMENT 3→5）" "✗ 提案上限が伝播: plugins/ff-dev-toolkit/docs-template/05-operations/DEPLOYMENT.md" 1
fi
restore_all

# M-G: 消費側（公開 README）の上限だけを書き換える
perl -pi -e 's/最大 3 件/最大 5 件/g' "$FIX_OSS_README"
if assert_mutated "$FIX_OSS_README" "$PRISTINE/oss-README.md" "M-G 公開 README の上限書き換え"; then
  expect_red "M-G 公開 README の上限書き換え（3→5）" "✗ 提案上限が伝播:" 1
fi
restore_all

# M-H: 1 行報告の文面変更（SKILL.md 側だけ）— 導出値と消費側の drift を測る。
# SKILL.md 側の出現は text フェンス内の 1 箇所だけなので、全置換で足りる。
perl -pi -e 's/\Q振り返り: 改善候補なし\E/振り返り: 特になし/g' "$FIX_SKILL"
if assert_mutated "$FIX_SKILL" "$PRISTINE/retrospective-SKILL.md" "M-H 1 行報告の片側変更"; then
  expect_red "M-H 1 行報告の片側変更（SKILL.md のみ）" "✗ 1 行報告の文面が git-workflow へ伝播" 1
fi
restore_all

# M-I: 1 行報告のフェンス内容を空にする — 抽出の fail-closed 経路
drop_lines_containing "$FIX_SKILL" "振り返り: 改善候補なし"
if assert_mutated "$FIX_SKILL" "$PRISTINE/retrospective-SKILL.md" "M-I 1 行報告の抽出不能化"; then
  expect_red "M-I 1 行報告の抽出不能化" "改善候補なしの 1 行報告を SKILL.md の text フェンスから抽出できません" 1
fi
restore_all

# M-K〜M-Q: フォールバック行の部分改変（Issue #574 の本体針 + Issue #607 の 3 新針 +
# Issue #630 の 3 新針の個別空振り実測）。行削除変異は 7 針同時の赤化しか見ないため、
# 「行は残るが 1 句だけ消える」drift で各針が単独で噛むことを、句単位の削除で 1 針ずつ
# 実測する（代表 1 サイトで足りる — 針は全サイト共通の定数で、サイトごとの差は
# contains の対象ファイルだけ）。
# 表の各行は「変異ラベル|削除する句|ゲートが出す検査名の接頭辞」。対象は git-workflow
# 固定、期待 ✗ は 1 件固定（句削除は 1 サイトの 1 針だけを落とす）。
# 切り出しは最初と最後の `|` で行うので、**変異ラベルと検査名に `|` を含めないこと**
# （中央の句だけは `|` を含んでよい）。検査名は表の中で一意にする（下の一意性ガード）。
# 句は改行なしの 1 行に乗り、`/` や `<>` を含むため、perl へは env 経由で渡して
# `\Q…\E` で literal 化する（区切り文字と衝突させない）。
GW_LABEL_PREFIX="plugins/ff-dev-toolkit/docs-template/05-operations/deployment/git-workflow.md"
FALLBACK_CLAUSE_MUTATIONS=(
  "M-K 名前確認手順の句削除|セッションの利用可能スキル一覧をキーワードで検索して実名を確認し、|スキル名の確認手順"
  "M-L プレフィックス両試行の句削除|プレフィックス付き（\`<プラグイン名>:<スキル名>\`）と無しの両方を試す（両者は別名として共存しうる）。|プレフィックス両試行"
  "M-M 別レジストリ区別の句削除|\`ListSkills\` が返すのは claude.ai 側の別レジストリであり、その空振りを不在の根拠にしない。|別レジストリの区別"
  "M-N 分割インストール原因句の削除|プラグインが複数ディレクトリへ分割インストールされ、一部スキルが当該セッションのレジストリに載っていないことがある。|分割インストールの突き合わせ"
  "M-O 実体突き合わせ操作句の削除|とインストール済みプラグインディレクトリの中身を突き合わせる|分割インストールの実体突き合わせ操作"
  "M-P 結論ガード句の削除|その場合はリポジトリ側の SKILL.md を読んで手順に従う（スキルが存在しないと結論しない）。|分割インストール時の結論ガード"
  "M-Q フォールバック本体句の削除|プラグインを更新するか、インストール済みプラグインの \`skills/<スキル名>/SKILL.md\` を直接 Read して手順に従う|スキル未解決時のフォールバック"
)

FALLBACK_MUTATIONS_RUN=0
FALLBACK_CHECK_NAMES=()
for mutation in "${FALLBACK_CLAUSE_MUTATIONS[@]}"; do
  m_label="${mutation%%|*}"
  m_rest="${mutation#*|}"
  m_clause="${m_rest%|*}"
  m_check="${m_rest##*|}"
  FF_CLAUSE="$m_clause" perl -pi -e 's{\Q$ENV{FF_CLAUSE}\E}{}' "$FIX_GIT_WORKFLOW"
  if assert_mutated "$FIX_GIT_WORKFLOW" "$PRISTINE/git-workflow.md" "$m_label"; then
    expect_red "${m_label}（git-workflow）" "✗ ${m_check}: ${GW_LABEL_PREFIX}" 1
  fi
  FALLBACK_MUTATIONS_RUN=$((FALLBACK_MUTATIONS_RUN + 1))
  FALLBACK_CHECK_NAMES+=("$m_check")
  restore_all
done

# 一意性ガード（本体）。実表で重複が無いこと自体が、下の M-S に対する green pin を兼ねる。
FALLBACK_DUPLICATE_CHECKS="$(duplicate_names "${FALLBACK_CHECK_NAMES[@]}")"
if [[ -z "$FALLBACK_DUPLICATE_CHECKS" ]]; then
  ok "フォールバック句変異が狙う検査名は ${FALLBACK_MUTATIONS_RUN} 件とも相異なる"
else
  bad "フォールバック句変異が同じ検査名を複数回狙っています（${FALLBACK_DUPLICATE_CHECKS}）— 件数だけ合わせて実測されない針が残る"
fi

# 網羅ガードの判定本体（Issue #640）。チェーン針の CHAIN_MUTATIONS_RUN 照合と同型で、
# 「ゲートに針を足したのに句単位変異を足し忘れた」状態を機械的に赤にする。
# 判定を関数へ出してあるのは、下でこのガード自身の赤化を実測するため。
# 戻り値 0 = 覆えている（緑）/ 1 = 不足・宣言値が読めない（赤）。
fallback_coverage_ok() { # $1=句単位変異の実行数 $2=ゲートが宣言した針数
  local run="$1" declared="$2"
  [[ -n "$declared" ]] || return 1
  [[ "$run" -eq "$declared" ]] || return 1
  return 0
}

if [[ -z "$FALLBACK_NEEDLES_DECLARED" ]]; then
  bad "ゲートが宣言するフォールバック針数を出力から読めません（検査名の書式変更。fail-closed）"
elif fallback_coverage_ok "$FALLBACK_MUTATIONS_RUN" "$FALLBACK_NEEDLES_DECLARED"; then
  ok "フォールバック句変異 ${FALLBACK_MUTATIONS_RUN} 件がゲートの針 ${FALLBACK_NEEDLES_DECLARED} 件をすべて覆っている"
else
  bad "フォールバック句変異 ${FALLBACK_MUTATIONS_RUN} 件に対しゲートの針は ${FALLBACK_NEEDLES_DECLARED} 件（実測されていない針がある / 表が古い）"
fi

# 網羅ガード自身の検出力を実測する。fixture のゲートへ「針だけ 1 件増やし、宣言値も
# 併せて上げる」（= 句単位変異を足し忘れた状態）を注入し、宣言値が N+1 で読めることを
# 確認したうえで、判定が赤へ倒れることを見る。宣言値が N+1 で読めない場合は、注入の
# 片肺（片方の置換だけ成立）で fail-closed 経路に落ちた可能性があるため、赤判定を
# 成果として数えずここで止める（「間違った理由で赤い」を検出成功と誤認しないため）。
if [[ -n "$FALLBACK_NEEDLES_DECLARED" ]]; then
  # 針の表へ 1 件足し、宣言値も併せて上げる（ゲート側の本数アサートは緑のまま、
  # 宣言だけが N+1 になる = 句単位変異の追加漏れそのものの再現）。
  FF_DECL="$FALLBACK_NEEDLES_DECLARED" perl -pi -e 's{^EXPECTED_FALLBACK_NEEDLES=\Q$ENV{FF_DECL}\E$}{"EXPECTED_FALLBACK_NEEDLES=" . ($ENV{FF_DECL} + 1)}e' "$GATE"
  perl -pi -e 's{^FALLBACK_NEEDLES=\($}{FALLBACK_NEEDLES=(\n  "実測されていない針|この針に対応する句単位変異は存在しない"}' "$GATE"
  if assert_mutated "$GATE" "$SRC_GATE" "M-R 針だけ増やして変異を増やさない状態の注入"; then
    run_gate "$GATE"
    INFLATED_DECLARED="$(gate_number 's/^  ✓ フォールバック針が \([0-9]*\) 件.*/\1/p')"
    if [[ "$INFLATED_DECLARED" != "$((FALLBACK_NEEDLES_DECLARED + 1))" ]]; then
      bad "M-R: 注入後の宣言値が ${INFLATED_DECLARED:-読めない}（期待 $((FALLBACK_NEEDLES_DECLARED + 1))）— 注入が片肺のため網羅ガードの実測を中止しました"
    elif fallback_coverage_ok "$FALLBACK_MUTATIONS_RUN" "$INFLATED_DECLARED"; then
      bad "M-R 針だけ増やして変異を増やさない状態: 網羅ガードが緑のまま（針の追加を強制できていない）"
    else
      ok "M-R 針だけ増やして変異を増やさない状態: 網羅ガードが赤化（変異 ${FALLBACK_MUTATIONS_RUN} 件 / 宣言 ${INFLATED_DECLARED} 件）"
      # green pin: **同じ注入下で**変異数が宣言値と等しければ緑であること（ACE-725-1）。
      # 上の赤が「件数の不一致」由来であることを分離する — 判定が常に赤を返す実装へ
      # 退化すればここが赤くなる。実状態（変異表とゲート）の一致は上の網羅ガード本体が
      # 見ているので、変異表が壊れているときに同じ赤を二重計上しないよう、ここは
      # 宣言値そのものを両辺に置く。
      if fallback_coverage_ok "$INFLATED_DECLARED" "$INFLATED_DECLARED"; then
        ok "green pin: 同じ注入下でも変異数が宣言値と等しければ緑（赤化の原因が件数不一致であることの分離）"
      else
        bad "green pin: 変異数と宣言値が等しくても赤（判定が過剰検出へ倒れている）"
      fi
    fi
  fi
  cp "$SRC_GATE" "$GATE"
  chmod +x "$GATE"
fi

# M-S: 一意性ガード自身の検出力。表の 1 件を「別の変異と同じ検査名を狙う複製」へ
# 差し替えた合成入力を判定へ渡し、(a) 件数照合はこの入力でも緑のまま（= 件数だけでは
# 塞げない穴であることの固定）、(b) 一意性ガードだけが赤くなることを見る。
# 合成入力を使うのは、実表そのものを書き換える変異が本 suite の実行中には打てない
# ため（表はこのスクリプトの source であり、変異を打つ相手は fixture 側だけ）。
# green pin は上の「実表では重複が無い」判定が兼ねる（同じ関数を無傷の入力で通す）。
if [[ "${#FALLBACK_CHECK_NAMES[@]}" -ge 2 ]]; then
  DUP_CHECK_NAMES=("${FALLBACK_CHECK_NAMES[@]}")
  DUP_CHECK_NAMES[$(( ${#DUP_CHECK_NAMES[@]} - 1 ))]="${DUP_CHECK_NAMES[0]}"
  MS_DUPES="$(duplicate_names "${DUP_CHECK_NAMES[@]}")"
  if fallback_coverage_ok "${#DUP_CHECK_NAMES[@]}" "$FALLBACK_NEEDLES_DECLARED"; then
    ok "M-S 複製の注入: 件数照合は緑のまま（${#DUP_CHECK_NAMES[@]} 件 = 宣言 ${FALLBACK_NEEDLES_DECLARED} 件）"
  else
    bad "M-S 複製の注入: 件数照合が赤（複製は件数を変えないはず — 合成入力の作り方が壊れている）"
  fi
  if [[ -n "$MS_DUPES" ]]; then
    ok "M-S 複製の注入: 一意性ガードが赤化（重複: ${MS_DUPES}）"
  else
    bad "M-S 複製の注入: 一意性ガードが緑のまま（複製で件数合わせできる穴が塞げていない）"
  fi
fi

# 同型の合成入力でチェーン側の一意性ガードも実測する（判定関数は共通だが、呼び出し側の
# 配線 — ループが検査名を集めているか — は別物なので、両方で 1 本ずつ見る）。
if [[ "${#CHAIN_CHECK_NAMES[@]}" -ge 2 ]]; then
  DUP_CHAIN_NAMES=("${CHAIN_CHECK_NAMES[@]}")
  DUP_CHAIN_NAMES[$(( ${#DUP_CHAIN_NAMES[@]} - 1 ))]="${DUP_CHAIN_NAMES[0]}"
  if [[ -n "$(duplicate_names "${DUP_CHAIN_NAMES[@]}")" ]]; then
    ok "M-S チェーン側: 複製を注入すると一意性ガードが赤化"
  else
    bad "M-S チェーン側: 複製を注入しても一意性ガードが緑のまま"
  fi
fi

# ── 系統 4: ゲート自身の「黙って縮む」ガード ─────────────────────────────────
# 針を 1 件削除した状態でも、削除された導線が実際に消えていれば残りの検査は緑に
# なりうる。件数ガードがその縮みを赤にすることを、ゲート本体への変異で実測する。
# 対象はモノレポ限定ブロックの針（公開配置ではそのブロックが無いので基本ブロック
# の針を使う。後者は当該ファイルの唯一の針なので、ファイル数ガードも道連れになる）。
if [[ "$IS_MONOREPO" -eq 1 ]]; then
  GATE_SHRINK_TARGET="ルート README のメンテ導線"
  GATE_SHRINK_FAILS=1
else
  GATE_SHRINK_TARGET="公開 README のスキル表"
  GATE_SHRINK_FAILS=2
fi
if [[ -n "$CHAIN_NEEDLES_DECLARED" ]]; then
  GATE_SHRINK_NEEDLE="✗ チェーン記載の針が $((CHAIN_NEEDLES_DECLARED - 1)) 件（期待 ${CHAIN_NEEDLES_DECLARED} 件）"
  FF_NEEDLE="$GATE_SHRINK_TARGET" perl -ni -e 'print unless index($_, $ENV{FF_NEEDLE}) >= 0' "$GATE"
  if assert_mutated "$GATE" "$SRC_GATE" "M-J 針の削除（ゲート本体）"; then
    expect_red "M-J ゲートの針を 1 件削除" "$GATE_SHRINK_NEEDLE" "$GATE_SHRINK_FAILS"
  fi
  cp "$SRC_GATE" "$GATE"
  chmod +x "$GATE"
else
  bad "M-J: 針数を読めなかったため件数ガードの実測をスキップしました"
fi

# 件数宣言のガードも baseline のラベルなので、それぞれ実際に赤化させる。
for guard in EXPECTED_CHAIN_FILES EXPECTED_FALLBACK_NEEDLES; do
  FF_GUARD="$guard" perl -pi -e 's{^(\s*\Q$ENV{FF_GUARD}\E=)([0-9]+)$}{$1 . ($2 + 1)}e' "$GATE"
  case "$guard" in
    EXPECTED_CHAIN_FILES) guard_label="チェーン記載の検査対象が" ;;
    *) guard_label="フォールバック針が" ;;
  esac
  if assert_mutated "$GATE" "$SRC_GATE" "件数宣言の変更: $guard"; then
    expect_red "件数宣言の変更: $guard" "✗ $guard_label" 1
  fi
  cp "$SRC_GATE" "$GATE"
done

# この本番呼び出し自体を下の小さな probe にも読み込む。呼び出しを削除しても
# 負の対照が緑へ倒れるため、関数だけを検査して配線が消える穴を残さない。
# coverage-assertion:start
if check_label_coverage "$BASELINE_LABELS" "$OBSERVED_LABELS"; then
  ok "ラベル被覆: baseline の全検査を変異で実測"
else
  bad "ラベル被覆: 未実測または不正な baseline"
fi
# coverage-assertion:end

# 自己検証は suite 全体を再帰実行せず、実際の本番呼び出しと判定関数を使う。
run_coverage_probe() { # $1=baseline $2=observed $3=正常/アサート削除/無条件除外
  local baseline="$1" observed="$2" mode="${3:-normal}" script="$FIXTURE_ROOT/coverage-probe.sh"
  {
    printf '%s\n' '#!/usr/bin/env bash' 'set -euo pipefail' 'PASS=0' 'FAIL=0'
    declare -f ok bad check_label_coverage
    printf '%s\n' 'BASELINE_LABELS="$1"' 'OBSERVED_LABELS="$2"'
    if [[ "$mode" == "exclude-all" ]]; then
      # 全ラベルの allowlist 追加と等価な無条件除外。
      printf '%s\n' 'check_label_coverage() { return 0; }'
    fi
    if [[ "$mode" != "drop-assertion" ]]; then
      awk '/^# coverage-assertion:start$/ { active = 1; next }
           /^# coverage-assertion:end$/ { active = 0 }
           active { print }' "$SCRIPT_DIR/verify.sh"
    fi
    printf '%s\n' 'exit "$FAIL"'
  } >"$script"
  run_gate_probe_rc=0
  bash "$script" "$baseline" "$observed" >"$FIXTURE_ROOT/coverage-probe.log" 2>&1 || run_gate_probe_rc=$?
  COVERAGE_PROBE_OUT="$(cat "$FIXTURE_ROOT/coverage-probe.log")"
  COVERAGE_PROBE_RC="$run_gate_probe_rc"
}

probe_rejected_missing_label() {
  [[ "$COVERAGE_PROBE_RC" -eq 1 && "$COVERAGE_PROBE_OUT" == *"ラベル被覆: 未実測の検査名:"* && "$COVERAGE_PROBE_OUT" == *"$PROBE_LABEL"* ]]
}

PROBE_LABEL="網羅 probe: 追加したマーカー針"
PROBE_NEEDLE="selftest-only-retrospective-marker"
PROBE_BASELINE="$FIXTURE_ROOT/probe-baseline"
PROBE_OBSERVED="$FIXTURE_ROOT/probe-observed"
cp "$OBSERVED_LABELS" "$PROBE_OBSERVED"
printf '\n%s\n' "$PROBE_NEEDLE" >>"$FIX_SKILL"
FF_PROBE_LINE='contains "$SKILL" "selftest-only-retrospective-marker" "網羅 probe: 追加したマーカー針"' \
  perl -pi -e 'print "$ENV{FF_PROBE_LINE}\n" if /^# ── D\./' "$GATE"
run_gate "$GATE"
PROBE_CHECKS="$(gate_number 's/^✓ retrospective contract verify: 全 \([0-9]*\) 件 pass$/\1/p')"
# EXPECTED_GATE_CHECKS_* を +1 しても通る baseline であることを先に実測する。
if [[ "$GATE_RC" -eq 0 && "$PROBE_CHECKS" == "$((EXPECTED_GATE_CHECKS + 1))" ]]; then
  ok "被覆 probe: 針追加と期待総数 +1 の baseline は緑"
  printf '%s\n' "$GATE_OUT" | gate_labels '✓' >"$PROBE_BASELINE"
  run_coverage_probe "$PROBE_BASELINE" "$PROBE_OBSERVED"
  if probe_rejected_missing_label; then
    ok "被覆 probe: 変異なしの追加針を名前付きで拒否"
  else
    bad "被覆 probe: 変異なしの追加針を拒否できない（${PROBE_LABEL}）"
    printf '%s\n' "$COVERAGE_PROBE_OUT" >&2
  fi
  # ガードが無効な実装でも自己検証の負の対照は成功してはならない。
  for mode in drop-assertion exclude-all; do
    run_coverage_probe "$PROBE_BASELINE" "$PROBE_OBSERVED" "$mode"
    if [[ "$COVERAGE_PROBE_RC" -eq 0 ]] && ! probe_rejected_missing_label; then
      ok "被覆 probe: $mode は負の対照で検出される"
    else
      bad "被覆 probe: $mode の注入が期待どおりに成立しない"
    fi
  done
  drop_lines_containing "$FIX_SKILL" "$PROBE_NEEDLE"
  expect_red "被覆 probe: 追加針の対応変異" "✗ $PROBE_LABEL" 1
  if [[ "$GATE_RC" -eq 1 ]]; then
    printf '%s\n' "$GATE_OUT" | gate_labels '✗' >>"$PROBE_OBSERVED"
  fi
  run_coverage_probe "$PROBE_BASELINE" "$PROBE_OBSERVED"
  if [[ "$COVERAGE_PROBE_RC" -eq 0 && "$COVERAGE_PROBE_OUT" == *"ラベル被覆: baseline の全検査を変異で実測"* ]]; then
    ok "被覆 probe: 対応変異の追加後は緑（同一行の複数針も集合で照合）"
  else
    bad "被覆 probe: 対応変異を追加しても緑にならない"
    printf '%s\n' "$COVERAGE_PROBE_OUT" >&2
  fi
else
  bad "被覆 probe: 針追加後の baseline が成立しない（exit ${GATE_RC} / 検査 ${PROBE_CHECKS}）"
fi
cp "$SRC_GATE" "$GATE"
restore_all

# ── 系統 5: 公開リポジトリ配置の分岐（モノレポ側でのみ実測） ─────────────────
# 公開側では root README が oss README と同一ファイルになり、ゲートの期待値が
# 縮む。この分岐はモノレポでの通常実行では一度も通らないので、配置を模した
# 第 2 fixture で baseline と針数の切り替え、チェーン削除の検出を実測する。
if [[ "$IS_MONOREPO" -eq 1 ]]; then
  PUB_REPO="$FIXTURE_ROOT/public"
  PUB_PLUGIN="$PUB_REPO/plugins/ff-dev-toolkit"
  mkdir -p \
    "$PUB_PLUGIN/tests/retrospective-contract" \
    "$PUB_PLUGIN/skills/retrospective" \
    "$PUB_PLUGIN/skills/ace-curate" \
    "$PUB_PLUGIN/docs-template/05-operations/deployment" \
    "$PUB_PLUGIN/docs-template/08-knowledge"
  PUB_GATE="$PUB_PLUGIN/tests/retrospective-contract/verify.sh"
  PUB_README="$PUB_REPO/README.md"
  cp "$SRC_GATE" "$PUB_GATE"
  chmod +x "$PUB_GATE"
  cp "$SRC_SKILL" "$PUB_PLUGIN/skills/retrospective/SKILL.md"
  cp "$SRC_ACE_CURATE" "$PUB_PLUGIN/skills/ace-curate/SKILL.md"
  cp "$SRC_GIT_WORKFLOW" "$PUB_PLUGIN/docs-template/05-operations/deployment/git-workflow.md"
  cp "$SRC_WORKFLOW_PRINCIPLES" "$PUB_PLUGIN/docs-template/05-operations/deployment/workflow-principles.md"
  cp "$SRC_DEPLOYMENT" "$PUB_PLUGIN/docs-template/05-operations/DEPLOYMENT.md"
  cp "$SRC_OSS_README" "$PUB_README"
  cp "$SRC_LEDGER_TEMPLATE" "$PUB_PLUGIN/docs-template/08-knowledge/OBSERVATIONS.md"
  # 公開リポジトリには本体台帳が無い（台帳はリポジトリごとの成果物。実測:
  # feel-flow/ff-dev-toolkit に docs/ が存在しない）。fixture へ置くと、実リポジトリでは
  # 通らない照合分岐を期待値に含めてしまう。ここに置かないことで「台帳を持たない配置では
  # 照合をスキップする」経路そのものを公開 fixture が実測する。

  run_gate "$PUB_GATE"
  if [[ "$GATE_RC" -eq 0 ]]; then
    ok "公開配置: ゲートが緑（root README を要求しない）"
  else
    bad "公開配置: ゲートが赤（公開同期後に run-all が恒常的に落ちる）"
    printf '%s\n' "$GATE_OUT" | { grep '^  ✗ ' || true; } >&2
  fi

  PUB_NEEDLES="$(gate_number 's/^  ✓ チェーン記載の針が \([0-9]*\) 件.*/\1/p')"
  PUB_CHECKS="$(gate_number 's/^✓ retrospective contract verify: 全 \([0-9]*\) 件 pass$/\1/p')"
  if [[ -n "$PUB_NEEDLES" && -n "$CHAIN_NEEDLES_DECLARED" && "$PUB_NEEDLES" -lt "$CHAIN_NEEDLES_DECLARED" ]]; then
    ok "公開配置: 針数がモノレポの ${CHAIN_NEEDLES_DECLARED} 件から ${PUB_NEEDLES} 件へ切り替わる"
  else
    bad "公開配置: 針数が切り替わっていません（公開 ${PUB_NEEDLES:-不明} / モノレポ ${CHAIN_NEEDLES_DECLARED:-不明}）"
  fi
  if [[ -n "$PUB_CHECKS" && "$PUB_CHECKS" -eq "$EXPECTED_GATE_CHECKS_PUBLIC" ]]; then
    ok "公開配置: 侵食ガードの期待値と一致（${PUB_CHECKS} 件）"
  else
    bad "公開配置: 検査が ${PUB_CHECKS:-不明} 件（期待 ${EXPECTED_GATE_CHECKS_PUBLIC} 件）— 公開側の期待値が古い"
  fi

  # 公開 fixture への変異はここが最後なので復元しない。後ろに変異を追加するときは
  # 汚染を引き継がないよう、モノレポ側の restore_all と同じ復元を先に入れること。
  drop_chain_token "$PUB_README" "ワークフローチェーン末尾（${CHAIN}）のセッション振り返り" "slash"
  if assert_mutated "$PUB_README" "$PRISTINE/oss-README.md" "公開配置: チェーン削除"; then
    expect_red "公開配置: 公開 README からのチェーン削除" "✗ チェーン記載: 公開 README のスキル表" 1 "$PUB_GATE"
  fi
fi

echo
if [[ "$FAIL" -gt 0 ]]; then
  echo "✗ retrospective contract selftest: $FAIL 件失敗 / $PASS 件成功" >&2
  REACHED_END=1
  exit 1
fi

echo "✓ retrospective contract selftest: 全 $PASS 件 pass"
REACHED_END=1
