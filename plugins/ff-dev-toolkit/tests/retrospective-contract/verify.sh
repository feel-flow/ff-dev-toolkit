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
#      read-only 境界・ask/off モード・trigger 語）が存在する。提案上限（最大 N 件）
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
contains "$SKILL" "**実測に限る**: このセッションで実測した手戻り・無駄時間、または台帳に実測として積まれた観測履歴" "提案閾値: 実測したものに限定"
contains "$SKILL" "一般論・仮説だけの提案は禁止" "提案閾値: 一般論・仮説を禁止"
contains "$SKILL" "該当する候補が無ければ、次の 1 行だけで終了する" "提案閾値: 候補なしは 1 行で終了"
contains "$SKILL" "**機微情報を提案本文へ引用しない**" "提案閾値: 機微情報を引用しない"

# Issue #865: 既存確認の**タイミング**を閾値側にも置く。提示前の規定は「起票前の既存確認」節と
# 出力形式の直後にもあるが、閾値は「提案として出すのは以下をすべて満たすものだけ」という前置きの
# フィルタで、提案の取捨はここで決まる — 閾値だけを読んで提案を組み立てる経路には届かない。
# 欄の存在を見る針（検査名「出力形式: 既存確認欄」）と、確認を提示前に済ませる規律は別物なので
# 対で持つ。実測（出典は本スキルの改善 Issue #865 の本文。当該節の導入前の版で観測）: 別プロジェクト
# の 1 セッション・複数回の振り返りで提示した計 5 件のうち 2 件が、既存 Issue と重複または矛盾した
# まま下流（承認・起票）へ流れていた。
# 針は文頭から文末（句点）までを含める。末尾だけを見る針だと `…提示する**のが望ましい**。` の
# ような文中へのモダリティ差し替えが部分一致で素通りし、義務が推奨へ緑のまま落ちる。
contains "$SKILL" "- **提示する前に**下の「起票前の既存確認」を実施し、起票先 repo の既存 Issue 検索まで済ませてから提示する。" "提案閾値: 提示前に既存 Issue 検索を済ませる"

contains "$SKILL" "**ユーザー承認を待つ**（承認なしに起票しない" "承認境界: 起票前にユーザー承認を待つ"
contains "$SKILL" "フルオート運用でもこの確認は省略しない" "承認境界: フルオートの例外であることを明示"
contains "$SKILL" "振り返り工程ではファイル編集・コミット・Issue 作成を行わない" "承認境界: 振り返り工程は read-only"
# 観測台帳の導入で書き込みは 2 系統に分かれた: 定型記録（SSOT 内・承認不要）と
# Issue 起票（承認後）。どちらか一方だけが残る退化を両針で検出する（同一行に乗る）。
contains "$SKILL" "書き込みが発生するのは、観測台帳への定型記録" "承認境界: 定型記録の書き込み範囲を明示"
contains "$SKILL" "と、提案をユーザーが承認して起票する段だけ" "承認境界: Issue 起票の書き込みは承認後のみ"

# 提案 1 件の構造。実測欄が出力形式から消えれば、閾値の文言が残っていても
# 「実測を添えずに一般論を提案する」退化が起きる（閾値と出力形式は対で効く）。
contains "$SKILL" "各提案に **起票先 repo** と **期待効果**（何が速く/正確になるか）に加え、**既存確認**（重複していないことの根拠）と **付与予定ラベル** を添える" "提案の構造: 必須 4 欄を列挙する"
contains "$SKILL" "- 実測: " "出力形式: 実測欄"
contains "$SKILL" "- 既存確認: " "出力形式: 既存確認欄"
# 欄の接頭辞だけだと `- 既存確認: [なし]` へ縮めても緑になる。角括弧の中身は出力形式側で
# 「方針矛盾」に言及する唯一の箇所でもあるので、判定軸（重複 + 方針矛盾）まで固定する。
contains "$SKILL" "重複・方針矛盾なしと判断したか" "出力形式: 既存確認欄は重複と方針矛盾の両方を判定して書く"
contains "$SKILL" "- 起票先: " "出力形式: 起票先欄"
contains "$SKILL" "- 付与予定ラベル: " "出力形式: 付与予定ラベル欄"
contains "$SKILL" "- 期待効果: " "出力形式: 期待効果欄"

# Issue #606: 起票前の既存確認。欄（`- 既存確認: `）だけ残って節が消えると、書く場所は
# あるのに何を確認するかが消えるため、節の見出し・記入を強制する一文・検索の取得上限を
# 対で持つ。特に `--limit` は、消えても症状が「重複 Issue が増える」だけで原因へ辿れない
# （既定 30 件の打ち切りをその先の不在と誤判定する fail-open）ので針の価値が高い。
contains "$SKILL" "### 起票前の既存確認（必須）" "起票前の既存確認: 節が存在する"
contains "$SKILL" "この行を書けない提案は提示しない" "起票前の既存確認: 既存確認を書けない提案は提示しない"
contains "$SKILL" "--state all --limit 200" "起票前の既存確認: 既存 Issue 検索は state 非限定 + 取得上限を明示"
# Issue #865: 重複していなくても、既存 Issue が提案の方針を否定・制約していることがある
# （実測: 別プロジェクトで、並列レビュー不可を実測付きで結論した Issue が既にあるのに並列化を
# 提案していた。出典は同 Issue の本文）。この分岐が落ちると「重複なし = 提示してよい」に縮退する
# ため、明示か取り下げの一文を独立の針で持つ。前半の「全文読み」はその前提条件で、先頭だけで
# 打ち切れば矛盾は見つからず、分岐は実行されたまま空回りする（同一行なので巻き添えは正常）。
contains "$SKILL" "矛盾する提案はそのまま出さず、方針側の変更提案であることを明示するか取り下げる" "起票前の既存確認: 方針に矛盾する提案は明示か取り下げ"
contains "$SKILL" "本文を**全文**読み（先頭だけで切らない）" "起票前の既存確認: ヒットした Issue の本文を全文読む"
# 節の冒頭にある 2 規定。Issue #865 の争点そのものが「確認のタイミング」なので、閾値側
# （上の針）だけでなく正本側の順序も固定する。もう 1 本は確認自体が実行できなかったときの
# 向きで、これが落ちると「検索できなかった = 重複なし」へ倒れ（fail-open）、症状は「重複 Issue が
# 増える」だけで原因へ辿れない。2 針とも同じ 1 行に乗る。
contains "$SKILL" "提案を提示する**前**に、各提案について次を確認する" "起票前の既存確認: 確認は提示前に行う（正本側）"
contains "$SKILL" "は「重複なし」と扱わない" "起票前の既存確認: 確認不能時は重複なしと扱わない"

# 観測台帳（起票の前段バッファ・KPT 拡張）: Issue トラッカーを観測の蓄積に使うと
# 一回性の観測まで Issue になり重複起票が構造化する（Issue #606 の実測が背景）。
# 「まず台帳へ記録 → 閾値到達で昇格」の経路と、Keep / 過剰動作の観察レンズが SKILL.md
# から落ちると、閾値の文言だけ残して直接起票へ縮退しても他の針は緑のままなので、
# 経路の要素を個別の針で固定する。
contains "$SKILL" "## 観測の記録 — 観測台帳（起票の前段バッファ）" "観測台帳: 節が存在する"
contains "$SKILL" "まず**観測台帳**へ記録する" "観測台帳: 起票前にまず台帳へ記録"
contains "$SKILL" "**累計 3 回**に到達し、対応 Issue が未リンク" "観測台帳: Issue 昇格の閾値"
contains "$SKILL" "**特急レーン**" "観測台帳: 重大観測の特急レーン"
contains "$SKILL" "アクションに繋がらない Keep は記録しない" "観測台帳: Keep はアクションに繋がるものだけ記録"
contains "$SKILL" "\`[observation]\` 接頭辞の Issue として受け渡す" "観測台帳: 導入先からは observation Issue で受け渡す"
contains "$SKILL" "open な \`observation\` Issue" "観測台帳: SSOT での inbox 取り込み"
contains "$SKILL" "**再現価値のある成功パターン（Keep）**" "観察チェックリスト: Keep レンズ"
contains "$SKILL" "**過剰動作**" "観察チェックリスト: 過剰動作レンズ"

# スキルの自動起動を左右する trigger 語。skill-frontmatter suite は形式しか見ない
# ので、trigger 語が消えてもどこも赤くならない。
contains "$SKILL" "「振り返り」「retrospective」「セッション振り返り」「プロセス改善の提案」と言われたとき" "frontmatter: trigger 語"

contains "$SKILL" "**振り返りに入る前に、必ず最初にモードを判定する**" "ask モード: 判定を先頭で行う"
contains "$SKILL" "利用者が本スキルを明示指定した → 環境変数に関係なく実施する" "ask/off モード: 明示指定は環境変数を上書き"
contains "$SKILL" "printenv RETROSPECTIVE_MODE" "ask モード: 環境変数を実測するコマンド"
contains "$SKILL" "出力が \`ask\` なら ask モード、\`off\` または上記の別名なら自動発火のみ無効" "ask/off モード: 判定結果の値域"
contains "$SKILL" "**off モード**: 事前注入と Stop fallback はどちらも動作せず" "off モード: 自動振り返りを無効化"
contains "$SKILL" "**毎回実施・問いかけなし**" "既定モード: 問いかけなしで毎回実施"

contains "$SKILL" "## 自動発火（事前注入 + Stop fallback）" "自動発火: 事前注入と Stop fallback 節"
contains "$SKILL" "ユーザー依頼の作業がこの応答で完了する" "自動発火: 完了時は振り返りを実施"
contains "$SKILL" "質問・承認待ち・外部状態待ち・作業途中である" "自動発火: 未完了時は対象外"
contains "$SKILL" "UserPromptSubmit の \`additionalContext\`" "自動発火: 応答生成前に振り返り契約を注入"

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
contains "$WORKFLOW_PRINCIPLES" "ノンストップの範囲が**実施（振り返り + 観測記録 + 提案の提示）まで**" "ノンストップ範囲の終端が明示"
contains "$DEPLOYMENT" "起票はユーザー承認後のみ" "承認境界が DEPLOYMENT へ伝播"
contains "$OSS_README" "起票はユーザー承認後のみ" "承認境界が公開 README へ伝播"
if [[ "$IS_MONOREPO" -eq 1 ]]; then
  contains "$ROOT_README" "起票はユーザー承認後のみ" "承認境界がルート README へ伝播"
fi

# スキル未解決時のフォールバック（Issue #574）。チェーン手順は文書側がプラグインより
# 新しくなりうる（docs-template は展開先プロジェクトに残る）ため、旧版プラグインの
# 利用者が手順書どおりに実行して `Unknown skill` で止まる。全消費側文書に同一の
# フォールバック 1 行があることを縛る（片側 drift の検出。文言は全サイト同一）。
# Issue #607: `Unknown skill` を「スキル不在」と誤結論しないための 3 針を追加 —
# 名前確認の手順（利用可能スキル一覧の検索）、プレフィックス付き / 無しの両試行、
# `ListSkills`（claude.ai 側の別レジストリ）の空振りを不在の根拠にしない旨。
# Issue #630: プラグインが複数ディレクトリへ分割インストールされ、一部スキルが
# 当該セッションのレジストリに載っていない場合の突き合わせ手順を 3 針で固定する
# （原因の説明・実体突き合わせの操作・「不在と結論しない」の結論ガード。原因句
# だけを守ると、操作と結論を消しても緑のまま手順が骨抜きになる）。
# 7 針とも同一の 1 行に乗る。
#
# 針は `ラベル|針` の表で持ち、本数を EXPECTED_FALLBACK_NEEDLES で宣言する（Issue #640）。
# 表は行頭側の最初の `|` で切るので、**ラベルに `|` を含めないこと**（針側は残り全部を
# 採るため `|` を含んでよい）。
# 宣言値は selftest 側が出力から読み、句単位変異（M-K〜M-Q）の実行数と突き合わせる
# 網羅ガードの比較相手になる。**針を増減したら 4 箇所が同時に動く**:
#   1. この表と EXPECTED_FALLBACK_NEEDLES
#   2. selftest の FALLBACK_CLAUSE_MUTATIONS（句単位変異を 1 件追加する。狙う検査名は
#      表の中で一意でなければならない — 複製で件数だけ合わせるのを selftest が弾く）
#   3. selftest の MARKER_MUTATIONS にある「フォールバック行の削除」4〜5 件の期待 ✗ 件数
#   4. selftest の EXPECTED_GATE_CHECKS_MONOREPO / _PUBLIC（針 1 件につき消費側の
#      ファイル数ぶん増える = モノレポ +5 / 公開 +4）
FALLBACK_NEEDLES=(
  "スキル未解決時のフォールバック|プラグインを更新するか、インストール済みプラグインの \`skills/<スキル名>/SKILL.md\` を直接 Read して手順に従う"
  "スキル名の確認手順|セッションの利用可能スキル一覧をキーワードで検索して実名を確認"
  "プレフィックス両試行|プレフィックス付き（\`<プラグイン名>:<スキル名>\`）と無しの両方を試す"
  "別レジストリの区別|\`ListSkills\` が返すのは claude.ai 側の別レジストリであり、その空振りを不在の根拠にしない"
  "分割インストールの突き合わせ|プラグインが複数ディレクトリへ分割インストールされ、一部スキルが当該セッションのレジストリに載っていないことがある"
  "分割インストールの実体突き合わせ操作|インストール済みプラグインディレクトリの中身を突き合わせる"
  "分割インストール時の結論ガード|その場合はリポジトリ側の SKILL.md を読んで手順に従う（スキルが存在しないと結論しない）"
)
EXPECTED_FALLBACK_NEEDLES=7

FALLBACK_CONSUMERS=("$GIT_WORKFLOW" "$WORKFLOW_PRINCIPLES" "$DEPLOYMENT" "$OSS_README")
if [[ "$IS_MONOREPO" -eq 1 ]]; then
  FALLBACK_CONSUMERS+=("$ROOT_README")
fi
for file in "${FALLBACK_CONSUMERS[@]}"; do
  for entry in "${FALLBACK_NEEDLES[@]}"; do
    # `#` の右辺はパターン文脈。クォートしないと REPO_ROOT に含まれる [ * ? が
    # パターンとして解釈され、前置き除去が効かずラベルが変わる（fixture の
    # REPO_ROOT は TMPDIR 由来なので実際に踏みうる）。
    contains "$file" "${entry#*|}" "${entry%%|*}: ${file#"$REPO_ROOT"/}"
  done
done

# 針の本数を宣言する。selftest 側の句単位変異がこの本数を覆っていることを、あちらが
# この行の値と突き合わせる（針だけ増やして変異を増やさない状態の検出）。
if [[ "${#FALLBACK_NEEDLES[@]}" -eq "$EXPECTED_FALLBACK_NEEDLES" ]]; then
  ok "フォールバック針が ${EXPECTED_FALLBACK_NEEDLES} 件（増減時は EXPECTED_FALLBACK_NEEDLES も更新すること）"
else
  bad "フォールバック針が ${#FALLBACK_NEEDLES[@]} 件（期待 ${EXPECTED_FALLBACK_NEEDLES} 件）— 針の増減に宣言値が追従していない"
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
