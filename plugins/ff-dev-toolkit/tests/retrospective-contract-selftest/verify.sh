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

# ゲートが検査を何件実行するかの期待値。**検査そのものが削除される侵食**（文言変更で
# 赤くなった針を更新せず消して緑に戻す、という実運用で最も起こりやすい退化）は、
# 針ごとの変異では原理的に検出できない — 消えた針は変異しても赤くならないからだ。
# baseline の総数を縛ることでその 1 方向を塞ぐ。ゲートに検査を足したらここも上げる。
EXPECTED_GATE_CHECKS_MONOREPO=94
EXPECTED_GATE_CHECKS_PUBLIC=83

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

cp "$SRC_GATE" "$GATE"
chmod +x "$GATE"
cp "$SRC_SKILL" "$FIX_SKILL"
cp "$SRC_ACE_CURATE" "$FIX_ACE_CURATE"
cp "$SRC_GIT_WORKFLOW" "$FIX_GIT_WORKFLOW"
cp "$SRC_WORKFLOW_PRINCIPLES" "$FIX_WORKFLOW_PRINCIPLES"
cp "$SRC_DEPLOYMENT" "$FIX_DEPLOYMENT"

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
cp "$FIX_OSS_README" "$PRISTINE/oss-README.md"
[[ "$IS_MONOREPO" -eq 0 ]] || cp "$FIX_ROOT_README" "$PRISTINE/root-README.md"

restore_all() {
  cp "$PRISTINE/retrospective-SKILL.md" "$FIX_SKILL"
  cp "$PRISTINE/ace-curate-SKILL.md" "$FIX_ACE_CURATE"
  cp "$PRISTINE/git-workflow.md" "$FIX_GIT_WORKFLOW"
  cp "$PRISTINE/workflow-principles.md" "$FIX_WORKFLOW_PRINCIPLES"
  cp "$PRISTINE/DEPLOYMENT.md" "$FIX_DEPLOYMENT"
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
  if [[ "$GATE_RC" -eq 0 ]]; then
    bad "${label}: 変異が検出されず緑のまま"
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
  "${FIX_SKILL}|retrospective-SKILL.md|**このセッションで実測した**手戻り・無駄時間に限る|提案閾値: 実測したものに限定|2"
  "${FIX_SKILL}|retrospective-SKILL.md|該当する候補が無ければ、次の 1 行だけで終了する|提案閾値: 候補なしは 1 行で終了|1"
  "${FIX_SKILL}|retrospective-SKILL.md|**機微情報を提案本文へ引用しない**|提案閾値: 機微情報を引用しない|1"
  "${FIX_SKILL}|retrospective-SKILL.md|各提案に **起票先 repo** と **期待効果**|提案の構造: 起票先と期待効果を必須にする|1"
  "${FIX_SKILL}|retrospective-SKILL.md|   - 実測: |出力形式: 実測欄|1"
  "${FIX_SKILL}|retrospective-SKILL.md|   - 起票先: |出力形式: 起票先欄|1"
  "${FIX_SKILL}|retrospective-SKILL.md|   - 期待効果: |出力形式: 期待効果欄|1"
  "${FIX_SKILL}|retrospective-SKILL.md|「振り返り」「retrospective」「セッション振り返り」「プロセス改善の提案」と言われたとき|frontmatter: trigger 語|2"
  "${FIX_SKILL}|retrospective-SKILL.md|**ユーザー承認を待つ**（承認なしに起票しない|承認境界: 起票前にユーザー承認を待つ|2"
  "${FIX_SKILL}|retrospective-SKILL.md|振り返り工程ではファイル編集・コミット・Issue 作成を行わない|承認境界: 振り返り工程は read-only|2"
  "${FIX_SKILL}|retrospective-SKILL.md|**振り返りに入る前に、必ず最初にモードを判定する**|ask モード: 判定を先頭で行う|1"
  "${FIX_SKILL}|retrospective-SKILL.md|利用者が本スキルを明示指定した → 環境変数に関係なく実施する|ask/off モード: 明示指定は環境変数を上書き|1"
  "${FIX_SKILL}|retrospective-SKILL.md|printenv RETROSPECTIVE_MODE|ask モード: 環境変数を実測するコマンド|1"
  "${FIX_SKILL}|retrospective-SKILL.md|出力が \`ask\` なら ask モード|ask/off モード: 判定結果の値域|1"
  "${FIX_SKILL}|retrospective-SKILL.md|**off モード**: Stop hook は継続せず|off モード: 自動振り返りを無効化|1"
  "${FIX_SKILL}|retrospective-SKILL.md|**毎回実施・問いかけなし**|既定モード: 問いかけなしで毎回実施|1"
  "${FIX_SKILL}|retrospective-SKILL.md|## 自動発火（Stop hook）|自動発火: Stop hook 節|1"
  "${FIX_SKILL}|retrospective-SKILL.md|ユーザー依頼の作業がこの応答で完了する|自動発火: 完了時は振り返りを実施|1"
  "${FIX_SKILL}|retrospective-SKILL.md|質問・承認待ち・外部状態待ち・作業途中である|自動発火: 未完了時は対象外|1"
  "${FIX_SKILL}|retrospective-SKILL.md|自分で hook を再実行したり marker を作ったりしない|自動発火: 再実行と marker を禁止|1"
  "${FIX_SKILL}|retrospective-SKILL.md|本スキルで扱わず、\`/ace-curate\`（または ACE Playbook への追記）へ回す|責務分離: retrospective 側からの送り先明示|1"
  "${FIX_ACE_CURATE}|ace-curate-SKILL.md|ACE Playbook ではなく \`/retrospective\` の提案経路で扱う|責務分離: ACE 側からの送り先明示|3"
  "${FIX_GIT_WORKFLOW}|git-workflow.md|承認なしには起票しない|承認境界が git-workflow へ伝播|4"
  "${FIX_WORKFLOW_PRINCIPLES}|workflow-principles.md|ユーザー承認を待ってから行う|承認境界が workflow-principles へ伝播|2"
  "${FIX_WORKFLOW_PRINCIPLES}|workflow-principles.md|\`/retrospective\` の起票のみ承認待ち|承認境界が適用タイミング表へ伝播|1"
  "${FIX_DEPLOYMENT}|DEPLOYMENT.md|起票はユーザー承認後のみ|承認境界が DEPLOYMENT へ伝播|3"
  "${FIX_OSS_README}|oss-README.md|起票はユーザー承認後のみ|承認境界が公開 README へ伝播|3"
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
    "${FIX_ROOT_README}|root-README.md|起票はユーザー承認後のみ|承認境界がルート README へ伝播|3"
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
    "$PUB_PLUGIN/docs-template/05-operations/deployment"
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
