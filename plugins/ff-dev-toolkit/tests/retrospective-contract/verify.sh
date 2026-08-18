#!/usr/bin/env bash
#
# /retrospective の規定と、ワークフローチェーン記載の相互整合を静的検査する（Issue #540）。
#
# PR #539（Issue #538）で `/retrospective` を新設したが、規定を固定する回帰ゲートが
# 無かった。既存 suite は隣接するが対象が違う:
#   - skill-count-consistency: スキルの**件数**だけ（SKILL.md の中身は読まない）
#   - docs-fact-drift: docs/ に手書きされた**数値**だけ（docs-template / skills は対象外）
# そのため「チェーン記載が片側だけ消える」「提案上限や承認境界の文言が SKILL.md から
# 落ちる」といった変更は、既存のどの suite にも当たらない。実際に PR #539 のレビューでは
# 標準チェックリストが ACE で終わったまま（`/retrospective` を省略する導線）という
# Critical が人手で見つかっており、機械化されていないことが実測されている。
#
# 検査:
#   A. チェーン記載サイト（`/merge-cleanup` → `/ace-curate` → `/retrospective`）が
#      全導線に存在する。サイトごとに固定針を持ち、**ループが黙って縮まない**よう
#      ファイル数・針数の両方を明示の期待値で縛る
#   B. SKILL.md の規定マーカー（提案閾値・実測限定・提案の構造と出力形式・承認境界・
#      read-only 境界・ask モードの 2 経路・trigger 語）が存在する。提案上限（最大 N 件）
#      と 1 行報告の文面は **SKILL.md から導出**し、抽出できなければ赤にする
#      （fail-closed）。上限は SKILL.md 内で一意であることまで見る
#   C. 導出した上限・1 行報告・承認境界が消費側文書（git-workflow / DEPLOYMENT /
#      workflow-principles / README）へ同じ値で伝播している（片側書き換えの検出）
#   D. `/ace-curate` との責務分離の記述が双方向に残っている
#
# **契約値（提案上限・1 行報告の文面）はこのファイルに書かない**（SKILL.md から
# 導出する）。一方、針数・ファイル数の期待値は「ループが黙って縮む」ことを捕まえる
# ための機械アサートなので直書きし、導線を増減したら同時に更新する。
# 契約**文言**も針として持つ: 表現を変えたら本 suite も同時に更新する運用で、
# 更新漏れは空振り = 赤として現れる（docs-fact-drift のヘッダと同じ方針）。
#
# 検出範囲の限界（意図的）: 本ゲートは `contains` だけで構成され、**契約行を残した
# まま矛盾する文を追記する**変更は検出できない。out-of-scope-routing が使う
# `not_contains` は「退役した旧規則の逐語復元」を塞ぐためのもので、本スキルには
# 退役した規則文言が存在しないため同じ手が使えない（禁止すべき固定文字列が無い）。
# 追記型の矛盾はレビューで見る前提とし、ここでは主張しない。
#
# 検出力の実測は tests/retrospective-contract-selftest/（同 Issue）が変異注入で行う。
#
# 外部コマンド・一時領域は不要。read-only。

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
REPO_ROOT="$(cd "$PLUGIN_ROOT/../.." && pwd)"

# SSOT モノレポでは公開文書は oss/ff-dev-toolkit/、公開リポジトリへ同期した後は
# リポジトリルートへ展開される。両配置で同じ suite を実行する。
# ルート README はモノレポ側だけの成果物（公開側では oss/ の README がルートに来て
# 同一ファイルになる）ため、モノレポでのみ検査対象に加える。
if [[ -d "$REPO_ROOT/oss/ff-dev-toolkit" ]]; then
  OSS_ROOT="$REPO_ROOT/oss/ff-dev-toolkit"
  IS_MONOREPO=1
else
  OSS_ROOT="$REPO_ROOT"
  IS_MONOREPO=0
fi

SKILL="$PLUGIN_ROOT/skills/retrospective/SKILL.md"
ACE_CURATE="$PLUGIN_ROOT/skills/ace-curate/SKILL.md"
GIT_WORKFLOW="$PLUGIN_ROOT/docs-template/05-operations/deployment/git-workflow.md"
WORKFLOW_PRINCIPLES="$PLUGIN_ROOT/docs-template/05-operations/deployment/workflow-principles.md"
DEPLOYMENT="$PLUGIN_ROOT/docs-template/05-operations/DEPLOYMENT.md"
ROOT_README="$REPO_ROOT/README.md"
OSS_README="$OSS_ROOT/README.md"

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

contains() {
  local file="$1" needle="$2" label="$3"
  if grep -qF -- "$needle" "$file"; then
    ok "$label"
  else
    bad "${label}（不足: ${needle}）"
  fi
}

echo "== retrospective 契約検査 =="

REQUIRED_FILES=("$SKILL" "$ACE_CURATE" "$GIT_WORKFLOW" "$WORKFLOW_PRINCIPLES" "$DEPLOYMENT" "$OSS_README")
if [[ "$IS_MONOREPO" -eq 1 ]]; then
  REQUIRED_FILES+=("$ROOT_README")
fi
MISSING_INPUTS=0
for file in "${REQUIRED_FILES[@]}"; do
  if [[ ! -s "$file" ]]; then
    bad "必須ファイルが無いか空です: $file"
    MISSING_INPUTS=1
  fi
done
# 入力が欠けたまま続けると、以降の contains が同じファイルへ grep をかけて
# `No such file or directory` を 30 行ばらまき、原因行が埋もれる。ここで止める。
if [[ "$MISSING_INPUTS" -ne 0 ]]; then
  echo "✗ retrospective contract verify: 入力が欠落しているため検査を中断しました" >&2
  exit 1
fi

# ── A. チェーン記載の相互整合 ────────────────────────────────────────────────
# 同じチェーンでも導線ごとに表記が違う（バッククォート付きの 3 トークン / 「ACE」を
# 中間トークンに使う原則ブロック / チェーン末尾だけを述べる DEPLOYMENT / 括弧で
# 説明が挟まる README のメンテ導線）。共通の緩い判定へ寄せると識別力が落ちるため、
# **サイトごとに固定針を持つ**。
CHAIN="\`/merge-cleanup\` → \`/ace-curate\` → \`/retrospective\`"

CHAIN_SITES=(
  "${SKILL}|ワークフローチェーンの末尾に位置する: ${CHAIN}|retrospective SKILL の位置づけ"
  # git-workflow の冒頭サマリは読み手・エージェントが最初に当たる導線で、ここだけ
  # 裸の `Retrospective` 表記（スラッシュ無し）。他の針とは形が違うので専用に持つ。
  "${GIT_WORKFLOW}|→ Cleanup → ACE → Retrospective|git-workflow のコアサイクル要約"
  "${WORKFLOW_PRINCIPLES}|cleanup / ACE / \`/retrospective\` の実施を含む|原則1 のルール本文"
  "${ACE_CURATE}|ACE 完了後、ワークフローチェーンの末尾として \`/retrospective\`|ace-curate 完了案内からの導線"
  "${ACE_CURATE}|（${CHAIN}）|ace-curate 完了案内のチェーン表記"
  "${GIT_WORKFLOW}|### チェーン末尾: セッション振り返り（/retrospective）|git-workflow のチェーン末尾セクション"
  "${GIT_WORKFLOW}|ACE 完了後、チェーンの末尾として \`/retrospective\` を毎回実行する（${CHAIN}）|git-workflow のチェーン表記"
  "${WORKFLOW_PRINCIPLES}|→ /merge-cleanup → ACE → /retrospective（セッション振り返り）|原則1 のフロー図"
  "${WORKFLOW_PRINCIPLES}|12. [ ] /retrospective（セッション振り返り）|標準チェックリストの末尾項目"
  "${DEPLOYMENT}|ステップ 10 の後、チェーン末尾として \`/retrospective\`（セッション振り返り）を毎回実行する|DEPLOYMENT の主要ステップ末尾"
  "${OSS_README}|ワークフローチェーン末尾（${CHAIN}）のセッション振り返り|公開 README のスキル表"
)
if [[ "$IS_MONOREPO" -eq 1 ]]; then
  CHAIN_SITES+=(
    "${ROOT_README}|ワークフローチェーン末尾（${CHAIN}）のセッション振り返り|ルート README のスキル表"
    "${ROOT_README}|→ \`/ace-curate\`（ナレッジ蓄積）→ \`/retrospective\`（セッション振り返り・プロセス改善提案）|ルート README のメンテ導線"
  )
fi

# 期待値はモノレポ/公開の 2 配置で違う。導線が減ったときにループが黙って縮み、
# 検査していないのに全 pass に見えるのを防ぐ（out-of-scope-routing の
# EXPECTED_INLINE_CONSUMERS と同じ趣旨）。
if [[ "$IS_MONOREPO" -eq 1 ]]; then
  EXPECTED_CHAIN_FILES=7
  EXPECTED_CHAIN_NEEDLES=13
else
  EXPECTED_CHAIN_FILES=6
  EXPECTED_CHAIN_NEEDLES=11
fi

CHAIN_NEEDLES_SEEN=0
CHAIN_FILES_SEEN=0
SEEN_FILES=""
for site in "${CHAIN_SITES[@]}"; do
  site_file="${site%%|*}"
  site_rest="${site#*|}"
  site_needle="${site_rest%|*}"
  site_label="${site_rest##*|}"
  contains "$site_file" "$site_needle" "チェーン記載: ${site_label}"
  CHAIN_NEEDLES_SEEN=$((CHAIN_NEEDLES_SEEN + 1))
  case "$SEEN_FILES" in
    *"[${site_file}]"*) ;;
    *)
      SEEN_FILES="${SEEN_FILES}[${site_file}]"
      CHAIN_FILES_SEEN=$((CHAIN_FILES_SEEN + 1))
      ;;
  esac
done

if [[ "$CHAIN_FILES_SEEN" -eq "$EXPECTED_CHAIN_FILES" ]]; then
  ok "チェーン記載の検査対象が ${EXPECTED_CHAIN_FILES} ファイル（増減時は EXPECTED_CHAIN_FILES も更新すること）"
else
  bad "チェーン記載の検査対象が ${CHAIN_FILES_SEEN} ファイル（期待 ${EXPECTED_CHAIN_FILES} ファイル）— ループが黙って縮んでいる"
fi
if [[ "$CHAIN_NEEDLES_SEEN" -eq "$EXPECTED_CHAIN_NEEDLES" ]]; then
  ok "チェーン記載の針が ${EXPECTED_CHAIN_NEEDLES} 件（増減時は EXPECTED_CHAIN_NEEDLES も更新すること）"
else
  bad "チェーン記載の針が ${CHAIN_NEEDLES_SEEN} 件（期待 ${EXPECTED_CHAIN_NEEDLES} 件）— ループが黙って縮んでいる"
fi

# ── B. SKILL.md の規定マーカーと導出値 ───────────────────────────────────────
# 提案上限は SKILL.md の**最初の出現**（frontmatter description）から導出する。
# 本文との一致は下の `**最大 N 件**` 針が担保する。抽出できない形（漢数字化・
# 節ごと削除）へ変わったら「上限が無い」ではなく赤にする（fail-closed）。
# awk はファイルを直接読むので、head で早期終了させる形の SIGPIPE 反転が起きない。
CAP="$(awk 'match($0, /最大 [0-9]+ 件/) { s = substr($0, RSTART, RLENGTH); gsub(/[^0-9]/, "", s); print s; exit }' "$SKILL")"
if [[ -n "$CAP" ]]; then
  ok "提案上限を SKILL.md から導出: 最大 ${CAP} 件"
else
  bad "提案上限（最大 N 件）を SKILL.md から抽出できません（節の削除か表記変更。fail-closed）"
fi

# 導出は最初の一致だけを採るので、SKILL.md 内に異なる上限が併存しても素通りする。
# 「最大 3 件」と「最大 5 件」が同居した状態は、読み手ごとに違う上限で運用される
# ので、値が一意であることまで検査する（消費側の照合は導出値としか比べられない）。
if [[ -n "$CAP" ]]; then
  CAP_VARIANTS="$(awk '
    { line = $0
      while (match(line, /最大 [0-9]+ 件/)) {
        s = substr(line, RSTART, RLENGTH)
        gsub(/[^0-9]/, "", s)
        print s
        line = substr(line, RSTART + RLENGTH)
      }
    }
  ' "$SKILL" | sort -u | tr '\n' ' ')"
  if [[ "$CAP_VARIANTS" == "${CAP} " ]]; then
    ok "提案上限が SKILL.md 内で一意（${CAP}）"
  else
    bad "提案上限が SKILL.md 内で一意でありません（検出値: ${CAP_VARIANTS}）— 併存した上限は読み手ごとに違う運用を生む"
  fi
fi

# 1 行報告の文面も SKILL.md の text フェンスから導出する（文面変更が消費側と
# 片側だけずれるのを検出するため、針を直書きしない）。
REPORT_TEXT="$(awk '
  /^```text$/ { inblock = 1; next }
  inblock && /^```$/ { inblock = 0; next }
  inblock && /^振り返り/ { print; exit }
' "$SKILL")"
if [[ -n "$REPORT_TEXT" ]]; then
  ok "改善候補なしの 1 行報告を SKILL.md から導出: ${REPORT_TEXT}"
else
  bad "改善候補なしの 1 行報告を SKILL.md の text フェンスから抽出できません（fail-closed）"
fi

if [[ -n "$CAP" ]]; then
  # CAP は SKILL.md の最初の一致（frontmatter description）から導出しているので、
  # frontmatter と本文が一致することを実際に担保しているのは**本文側**のこの針。
  contains "$SKILL" "**最大 ${CAP} 件**" "提案閾値: 本文の上限が frontmatter と一致"
  # 一方こちらは導出元の行そのものなので、不一致の検出力は持たない（表記の残存だけを見る）。
  contains "$SKILL" "改善提案を最大 ${CAP} 件出す" "提案閾値: frontmatter description の上限表記が残存"
  # 超過時の絞り込みの一文にも同じ上限が入る。ここだけ数値を直書きすると、上限を
  # 変えたときにこの一文だけ古い値のまま残った状態を緑にしてしまう。
  contains "$SKILL" "${CAP} 件を超える候補がある場合は効果の大きい順に絞る" "提案閾値: 超過時は効果順に絞る"
fi
contains "$SKILL" "**このセッションで実測した**手戻り・無駄時間に限る" "提案閾値: 実測したものに限定"
contains "$SKILL" "一般論・仮説だけの提案は禁止" "提案閾値: 一般論・仮説を禁止"
contains "$SKILL" "該当する候補が無ければ、次の 1 行だけで終了する" "提案閾値: 候補なしは 1 行で終了"

contains "$SKILL" "**ユーザー承認を待つ**（承認なしに起票しない" "承認境界: 起票前にユーザー承認を待つ"
contains "$SKILL" "フルオート運用でもこの確認は省略しない" "承認境界: フルオートの例外であることを明示"
contains "$SKILL" "振り返り工程ではファイル編集・コミット・Issue 作成を行わない" "承認境界: 振り返り工程は read-only"
contains "$SKILL" "書き込みが発生するのは、提案をユーザーが承認して起票する段だけ" "承認境界: 書き込みは承認後の起票のみ"

# 提案 1 件の構造。実測欄が出力形式から消えれば、閾値の文言が残っていても
# 「実測を添えずに一般論を提案する」退化が起きる（閾値と出力形式は対で効く）。
contains "$SKILL" "各提案に **起票先 repo** と **期待効果**" "提案の構造: 起票先と期待効果を必須にする"
contains "$SKILL" "- 実測: " "出力形式: 実測欄"
contains "$SKILL" "- 起票先: " "出力形式: 起票先欄"
contains "$SKILL" "- 期待効果: " "出力形式: 期待効果欄"

# スキルの自動起動を左右する trigger 語。skill-frontmatter suite は形式しか見ない
# ので、trigger 語が消えてもどこも赤くならない。
contains "$SKILL" "「振り返り」「retrospective」「セッション振り返り」「プロセス改善の提案」と言われたとき" "frontmatter: trigger 語"

contains "$SKILL" "**振り返りに入る前に、必ず最初にモードを判定する**" "ask モード: 判定を先頭で行う"
contains "$SKILL" "引数に \`ask\` が指定されている（\`/retrospective ask\`）" "ask モード: 引数による指定"
contains "$SKILL" "printenv RETROSPECTIVE_MODE" "ask モード: 環境変数を実測するコマンド"
contains "$SKILL" "出力が \`ask\` なら ask モード。未設定（空）・それ以外の値なら既定モード" "ask モード: 判定結果の値域"
contains "$SKILL" "**毎回実施・問いかけなし**" "既定モード: 問いかけなしで毎回実施"

# ── C. 消費側文書への伝播 ────────────────────────────────────────────────────
# 上限・1 行報告・承認境界が片側だけ書き換わるのを検出する。
if [[ -n "$CAP" ]]; then
  CAP_CONSUMERS=("$GIT_WORKFLOW" "$DEPLOYMENT" "$OSS_README")
  if [[ "$IS_MONOREPO" -eq 1 ]]; then
    CAP_CONSUMERS+=("$ROOT_README")
  fi
  for file in "${CAP_CONSUMERS[@]}"; do
    # `#` の右辺はパターン文脈。クォートしないと REPO_ROOT に含まれる [ * ? が
    # パターンとして解釈され、前置き除去が効かずラベルが変わる（fixture の
    # REPO_ROOT は TMPDIR 由来なので実際に踏みうる）。
    contains "$file" "最大 ${CAP} 件" "提案上限が伝播: ${file#"$REPO_ROOT"/}"
  done
fi

if [[ -n "$REPORT_TEXT" ]]; then
  contains "$GIT_WORKFLOW" "$REPORT_TEXT" "1 行報告の文面が git-workflow へ伝播"
fi

contains "$GIT_WORKFLOW" "承認なしには起票しない" "承認境界が git-workflow へ伝播"
contains "$WORKFLOW_PRINCIPLES" "ユーザー承認を待ってから行う" "承認境界が workflow-principles へ伝播"
# 適用タイミング表は「どこまでがノンストップか」を読む 3 つ目の導線。ここだけ
# 落ちると「振り返りも起票までノンストップ」と読める表が残る。
contains "$WORKFLOW_PRINCIPLES" "\`/retrospective\` の起票のみ承認待ち" "承認境界が適用タイミング表へ伝播"
contains "$WORKFLOW_PRINCIPLES" "ノンストップの範囲が**実施（振り返り + 提案の提示）まで**" "ノンストップ範囲の終端が明示"
contains "$DEPLOYMENT" "起票はユーザー承認後のみ" "承認境界が DEPLOYMENT へ伝播"
contains "$OSS_README" "起票はユーザー承認後のみ" "承認境界が公開 README へ伝播"
if [[ "$IS_MONOREPO" -eq 1 ]]; then
  contains "$ROOT_README" "起票はユーザー承認後のみ" "承認境界がルート README へ伝播"
fi

# ── D. /ace-curate との責務分離 ──────────────────────────────────────────────
contains "$ACE_CURATE" "ACE Playbook ではなく \`/retrospective\` の提案経路で扱う" "責務分離: ACE 側からの送り先明示"
contains "$SKILL" "本スキルで扱わず、\`/ace-curate\`（または ACE Playbook への追記）へ回す" "責務分離: retrospective 側からの送り先明示"

echo
if [[ "$FAIL" -gt 0 ]]; then
  echo "✗ retrospective contract verify: $FAIL 件失敗 / $PASS 件成功" >&2
  exit 1
fi

echo "✓ retrospective contract verify: 全 $PASS 件 pass"
