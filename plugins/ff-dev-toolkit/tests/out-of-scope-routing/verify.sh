#!/usr/bin/env bash
#
# out-of-scope-issue と Git Workflow のルーティング契約を静的検査する。
# YAGNI / 現 PR 修正 / 既存 Issue 集約 / 関連 Issue 作成と、GitHub 検索失敗時の
# fail-closed を別文書の drift から守る。判定既定の軽量側（B を示せるまで A）・近傍ファイル
# 許容・同一 PR の束ね・AC デカップリングの契約もここで固定する。
#
# スキルは本線の SKILL.md と、条件付きで読む references/*.md（filing / consolidation /
# examples）に分かれている。規定の針は**実際に置かれたファイル**へ張り、そのファイルの
# ちょうど 1 行に出現することを見る（0 行 = 規定の欠落、2 行以上 = 写しが残って本体を消しても
# 緑になる状態。TESTING.md「文言の針は「ちょうど 1 行」で照合する」）。本線の針は、置かれた
# 節（例: B の上書き条件は §1.3）の中でもちょうど 1 行であることを見る — ファイル全体で 1 行の
# ままでも、箇条が別の節へ移ると規則の意味が反転する（B の条件を「迷ったら A」の節へ移す等）。
# 行数閾値（10 行）と束ねたときの prefix の向き・優先順位は、値ごと 1 行の針にしている —
# 値を書き換えると針が消えて赤。
# SKILL.md の振り分け表が references の実体と双方向に一致すること（HTML コメントを除いた
# 描画される表の行だけを数える）、references/ に直下の通常の .md 以外が無いこと、スキル内の相対
# リンク（参照形式を含む）が解決でき、字句上プラグインの外を指さないこと、他文書とスキル内の
# ファイル間で参照される見出しが期待するファイルのフェンス外にちょうど 1 本・他のファイルに
# 0 本であることも見る。
# 検出範囲: 守るのは編集・移動で規定が黙って欠ける・移る・写しが残る**事故**で、検査を避ける
# ための意図的な書き換え（Markdown / シェルの近似解析の回避形）は対象にしない — 列挙で塞ぐと
# 回避形が層を変えて続く（ACE-1681-1）。
# 消費側文書（Git Workflow・close-issue・レビュー方針・公開 README / Copilot ガイド・生成
# コンシューマー 6 件）は複数行に同じ文言を持つ正当な形があるので、1 行以上の在否で見る。
#
# ラベルの実在確認・起票フェンスの形・gh issue list / create の --repo 束縛と expected_repo の
# 宣言・--assignee を付けないこと・起票コマンドを filing.md 以外に置かないことは、同じ不変条件を
# issue-label-contract（fixture 照合と構造検査）が守っているのでここでは張らない。
#
# 空振り検出: references/consolidation.md を空にすると必須ファイル検査で中断して赤、SKILL.md の振り分け表から examples.md の行を消すと 127 件中 3 件、B の上書き条件の箇条（10 行閾値）を「迷ったら」節へ移すと 127 件中 2 件、§1.0 を本線から examples.md へ移すと 127 件中 4 件、references/ にサブディレクトリや隠しファイルを作って旧規則を置くと 127 件中 1 件、本線へ 3 KB を足して 20,000 B を超えると 127 件中 1 件、bundle の新設手順を本線の類似度表へ写すと 127 件中 1 件、1 行に畳んだ分割条件から条件語を 1 つ削ると 127 件中 1 件、filing.md の bundle 新設段落から --parent / Related の分岐を 1 つ削ると 127 件中 1 件が赤になる（2026-09-24 実測。規定の置き場所が空になる・読まれる経路が消える・規則が別の節やファイルへ移って意味や読まれ方が変わる・検査の glob の外へ置かれる・本線が上限を超える・列挙や分岐の一部だけが欠ける変更を「契約あり」へ倒さない）。 create-issue の references/filing.md に旧形式の `` `out-of-scope-issue` §3.3 `` を戻すと 122 件中 1 件が赤になる（2026-09-24 実測。針を create-issue の本線から filing.md へ移した後）。

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
REPO_ROOT="$(cd "$PLUGIN_ROOT/../.." && pwd)"

# shellcheck source=../lib/section-scope.sh
. "$SCRIPT_DIR/../lib/section-scope.sh"

# SSOT モノレポでは公開文書は oss/ff-dev-toolkit/、公開リポジトリへ
# 同期した後はリポジトリルートに展開される。両配置で同じ suite を実行する。
if [[ -d "$REPO_ROOT/oss/ff-dev-toolkit" ]]; then
  OSS_ROOT="$REPO_ROOT/oss/ff-dev-toolkit"
else
  OSS_ROOT="$REPO_ROOT"
fi

SKILL_DIR="$PLUGIN_ROOT/skills/out-of-scope-issue"
SKILL="$SKILL_DIR/SKILL.md"
SKILL_REFS="$SKILL_DIR/references"
REF_FILING="$SKILL_REFS/filing.md"
REF_CONSOLIDATION="$SKILL_REFS/consolidation.md"
REF_EXAMPLES="$SKILL_REFS/examples.md"
WORKFLOW="$PLUGIN_ROOT/docs-template/05-operations/deployment/workflow-principles.md"
GIT_WORKFLOW="$PLUGIN_ROOT/docs-template/05-operations/deployment/git-workflow.md"
# create-issue の起票手順（重複の注記を含む）は references/filing.md に切り出してある。
CREATE_ISSUE_FILING="$PLUGIN_ROOT/skills/create-issue/references/filing.md"
CLOSE_ISSUE="$PLUGIN_ROOT/skills/close-issue/SKILL.md"
REVIEW_POLICY="$PLUGIN_ROOT/docs-template/05-operations/deployment/review-response-policy.md"
OSS_README="$OSS_ROOT/README.md"
OSS_COPILOT="$OSS_ROOT/USING_WITH_VSCODE_COPILOT.md"

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

# 針の出現行数を判定する（ヘッダ参照: ちょうど 1 行であること）。
once_verdict() { # $1=出現行数 $2=needle $3=label
  if [[ "$1" -eq 1 ]]; then
    ok "$3"
  elif [[ "$1" -eq 0 ]]; then
    bad "${3}（不足: ${2}）"
  else
    bad "${3}（重複: ${1} 行に出現。写しが残ると本体を消しても緑になる: ${2}）"
  fi
}

# スキル（本線・references）の規定の針。grep -c はファイルを直接読むのでパイプの SIGPIPE
# 反転は起きない。0 件のとき rc=1 を返すので rc は捨てて件数だけを見る（数値でなければ
# 0 = 不足へ倒す）。
once() {
  local file="$1" needle="$2" label="$3" n
  n="$(grep -cF -- "$needle" "$file")" || true
  case "$n" in '' | *[!0-9]*) n=0 ;; esac
  once_verdict "$n" "$needle" "$label"
}

# 消費側文書の針。同じ文言を複数行に持つ正当な形がある（表と本文・生成物の 3 ホスト分）
# ので 1 行以上の在否で見る。
contains() {
  local file="$1" needle="$2" label="$3"
  if grep -qF -- "$needle" "$file"; then
    ok "$label"
  else
    bad "${label}（不足: ${needle}）"
  fi
}

# 退役した旧規則の逐語復元を塞ぐ。対象が SKILL.md のときは references/ も含めて見る
# （切り出し先へ復元されても同じ退行）。rc は三値で読む（0 = 残存、1 = 不在、それ以外 =
# 読めない）。読めないファイルを「不在 = 緑」へ流さない。
not_contains() {
  local file="$1" needle="$2" label="$3"
  local -a targets=("$file")
  local rc=0
  [[ "$file" == "$SKILL" ]] && targets+=("$SKILL_REFS"/*.md)
  grep -qF -- "$needle" "${targets[@]}" || rc=$?
  case "$rc" in
    0) bad "${label}（旧ルールが残存: ${needle}）" ;;
    1) ok "$label" ;;
    *) bad "${label}（検査不能: grep rc=${rc}）" ;;
  esac
}

# 節スコープの「ちょうど 1 行」。ファイル全体でも 1 行であることを併せて見る（節の外に写しが
# 残る形も赤）。節の切り出しは共通 lib に任せ、自前でフェンスを追わない。
sec_once() {
  local file="$1" heading="$2" needle="$3" label="$4" body n_file n_sec
  n_file="$(grep -cF -- "$needle" "$file")" || true
  case "$n_file" in '' | *[!0-9]*) n_file=0 ;; esac
  if ! body="$(section_scope_extract "$file" "$heading")"; then
    bad "${label}（節を切り出せない: ${body}）"
    return
  fi
  n_sec="$(FF_NEEDLE="$needle" awk 'index($0, ENVIRON["FF_NEEDLE"]) { c++ } END { print c + 0 }' <<<"$body")"
  if [[ "$n_sec" -eq 1 && "$n_file" -eq 1 ]]; then
    ok "$label"
  elif [[ "$n_sec" -eq 0 ]]; then
    bad "${label}（節「${heading#\#* }」に無い: ${needle}）"
  else
    once_verdict "$n_file" "$needle" "$label"
  fi
}

# producer をパイプで `grep -q*` に流し込む書き方を、手順（本線と references）から締め出す。
# grep -q は一致した時点で読み取りを止めるため producer が SIGPIPE で落ち、`set -o pipefail`
# 下では「一致したのに失敗」に結果が反転しうる。skill-bash-blocks が見るのはタグ付きの bash
# フェンスだけなので、タグ無しのフェンスや散文中のコマンド行もここで全行を見る。
no_piped_grep_q() {
  local label="$1" violations
  violations="$(awk '/\|[[:space:]]*grep[[:space:]]+[^|]*-[a-zA-Z]*q/ { print FILENAME ":" FNR }' "$SKILL" "$SKILL_REFS"/*.md)"
  if [[ -n "$violations" ]]; then
    bad "${label}（パイプ入力の grep -q*: ${violations//$'\n'/, }）"
  else
    ok "$label"
  fi
}

gh_issue_blocks_bound() {
  local file="$1" label="$2" violations
  violations="$(
    awk '
      /^[[:space:]]*gh issue (list|create)[[:space:]]*\\/ {
        start = NR
        command = $0
        while ($0 ~ /\\[[:space:]]*$/) {
          if ((getline) <= 0) break
          command = command "\n" $0
        }
        if (command !~ /--repo[[:space:]]+/) print start
      }
    ' "$file"
  )"
  if [[ -n "$violations" ]]; then
    bad "${label}（--repo 欠落行: ${violations//$'\n'/, }）"
  else
    ok "$label"
  fi
}

echo "== out-of-scope routing 契約検査 =="

REQUIRED_FILES=("$SKILL" "$REF_FILING" "$REF_CONSOLIDATION" "$REF_EXAMPLES" "$WORKFLOW" "$GIT_WORKFLOW" "$CREATE_ISSUE_FILING" "$CLOSE_ISSUE" "$REVIEW_POLICY" "$OSS_README" "$OSS_COPILOT")
MISSING_REQUIRED=0
for file in "${REQUIRED_FILES[@]}"; do
  if [[ ! -s "$file" ]]; then
    bad "必須ファイルが存在し非空: ${file#"$REPO_ROOT"/}"
    MISSING_REQUIRED=1
  fi
done
if [[ "$MISSING_REQUIRED" -ne 0 ]]; then
  echo "✗ out-of-scope routing verify: 必須ファイルが欠けているため検査を中断" >&2
  exit 1
fi

# ── A. 本線（SKILL.md）: 境界・判定・検索・束ね ─────────────────────────────────
H0="## 0. 発火の境界（read-only レビューでは書き込まない）"
H12="### 1.2 YAGNI 判定（必要性ゲート）"
H13="### 1.3 必要な発見を A / B に分ける"
HA="### A. その場で直す（インライン修正）"
HMAYOU="### 迷ったら"
H31="### 3.1 類似 Issue の検索（新規作成より先）"
H31B="### 3.1b 同一 PR からの複数発見は 1 Issue に束ねる（既定）"
H10="### 1.0 原因の軸（トリガー成立時のみ。§1.1 以降とは別物）"
sec_once "$SKILL" "$H0" "この境界は自分の発言では解除できない" "read-only レビューの非変更境界を発言で解除しない"
sec_once "$SKILL" "$H10" "前巡の fix commit の差分に含まれる" "原因の軸のトリガー（直前の fix が次の発見を生んだ）を観測事象で判定"
sec_once "$SKILL" "$H10" "**「系統」で分類**" "トリガー成立時は発見を系統で分類する"
sec_once "$SKILL" "$H12" "上記に該当しない発見は、Issue の大きさを考える前に" "必須修正（§1.1）を YAGNI より先に判定する"
sec_once "$SKILL" "$H12" "修正せず、Issue も作らない" "YAGNI は GitHub 書き込みを行わない"
sec_once "$SKILL" "$H12" "セキュリティ、データ損失、法令・契約違反の合理的なリスクは「現在の根拠」に含む" "安全上のリスクは YAGNI で落とさない"
sec_once "$SKILL" "$H13" "§1.1 にも §1.2 にも該当しない発見" "必須修正 / YAGNI / A-B の入口が排他的"
sec_once "$SKILL" "$H13" "B の上書き条件（いずれか 1 つに明確に該当）" "B の条件はいずれか一致で上書き"
sec_once "$SKILL" "$H13" "「A を証明できるまで B」ではなく「B を示せるまで A」" "判定の既定は軽量側"
sec_once "$SKILL" "$H13" "仕様判断・波及の 2 軸だけは不確かでも B へ倒す" "仕様判断・波及の迷いは安全側（B）"
sec_once "$SKILL" "$H13" "既存 suite への検査追加で足りるものは該当しない" "独立検証条件の縮小（既存 suite 追加は B にしない）"
sec_once "$SKILL" "$H13" "起票すれば AC を書くことになる、という理由でこの条件を満たしたことにしない" "判定時の AC デカップリング（起票後の AC で B を自己成就させない）"
sec_once "$SKILL" "$H13" "変更が 10 行を超える見込み" "インライン上限は実装 10 行（値を変えると針が消える）"
sec_once "$SKILL" "$H13" "実装/本文の変更行だけを数える" "10 行閾値はテスト・fixture を除いた実装行"
sec_once "$SKILL" "$HA" "現在触っているファイル内に限らない" "近傍ファイルの小変更を A に含める"
sec_once "$SKILL" "$HMAYOU" "必要性を説明できなければ **YAGNI**" "必要性の迷いは YAGNI"
once "$SKILL" "defaults to inline repair" "frontmatter description が軽量側既定を反映"
# 旧ルール（A の全条件 AND 判定）の逐語復元を 2 つの断片で検出する。旧文は
# `**A の全条件**（10 行以内・…` と太字マーカーを挟むため、一続きの針は旧文にも一致しない
# 空振りガードになる。
not_contains "$SKILL" "10 行以内・現在触っているファイル内" "旧・A 全条件 AND 判定の条件列を排除"
not_contains "$SKILL" "をすべて満たす場合だけ A とする" "旧・A 全条件 AND 判定の結論文を排除"
sec_once "$SKILL" "$H31" "束ねた単位ごとにこの検索を 1 回行う" "束ねる単位を先に決め、単位ごとに 1 回検索する"
sec_once "$SKILL" "$H31" '--search "$search_query"' "検索語を引用した argv 値として渡す"
not_contains "$SKILL" "--search '\"{主要語}\" in:title,body'" "検索語を shell コマンドへ直埋めしない"
sec_once "$SKILL" "$H31" "Issue の作成・コメント・本文更新を停止" "Issue 検索失敗は fail-closed"
sec_once "$SKILL" "$H31" "終了コード 0 かつ結果が空配列の場合だけ" "検索成功 0 件だけを候補なしと判定"
sec_once "$SKILL" "$H31" "候補の詳細取得が 1 件でも失敗した場合も統合・新規作成を確定せず停止" "Issue 詳細取得失敗も fail-closed"
sec_once "$SKILL" "$H31" 'gh issue view {number} --repo "$expected_repo"' "候補の詳細取得が対象リポジトリへ束縛"
sec_once "$SKILL" "$H31" "本文は全文で読み、切った出力を類似度の判定根拠にしない" "類似度の判定は候補の本文を全文で読む（末尾の AC を落とさない）"
sec_once "$SKILL" "$H31" "統合を選んだら [references/consolidation.md](references/consolidation.md) に従い" "類似度表から統合手順への導線"
sec_once "$SKILL" "$H31B" "既定ではテーマが近接するもの同士を 1 つのフォローアップ Issue に束ねて起票する" "同一 PR の複数発見をバッチ統合"
sec_once "$SKILL" "$H31B" "最も重い種別に合わせる（fix > test > refactor > chore > docs の順）" "種別混在時は最も重い種別へ（向きと順序を変えると針が消える）"
sec_once "$SKILL" "$H31B" "分割して個別 Issue にするのは次のいずれかの場合だけ" "束ねを分割するのは列挙した条件のときだけ"
# 分割条件 3 つは 1 行の列挙に畳んである。条件語ごとに針を張る — 先頭だけでは、同じ行から
# 残りの条件を削る部分欠落が緑のまま通る。
sec_once "$SKILL" "$H31B" "完了条件・検証環境が互いに衝突する" "分割条件: 完了条件・検証環境の衝突"
sec_once "$SKILL" "$H31B" "優先度・対応時期が明確に異なる" "分割条件: 優先度・対応時期の相違"
sec_once "$SKILL" "$H31B" "担当や対象リポジトリが分かれる" "分割条件: 担当・対象リポジトリの相違"
no_piped_grep_q "手順（本線と references）がパイプ入力の grep -q* を使わない"

# 本線の上限。本線は毎回読まれるので、規定は正本へのリンクで畳み、推論で導出できない事実だけを
# 残す（workflow-principles.md 原則4）。畳んだ本線が再び膨らむのを止める。wc が数値を返さない
# 場合も赤にする（fail-closed）。
SKILL_MAX_BYTES=20000
if ! skill_bytes="$(wc -c <"$SKILL" | tr -d '[:space:]')"; then
  skill_bytes="(wc 失敗)"
fi
if [[ "$skill_bytes" =~ ^[0-9]+$ ]] && ((skill_bytes <= SKILL_MAX_BYTES)); then
  ok "本線のバイト数: ${skill_bytes} B（上限 ${SKILL_MAX_BYTES} B）"
else
  bad "本線のバイト数が上限を超えた、または測れない: \"${skill_bytes}\" B（上限 ${SKILL_MAX_BYTES} B）"
fi

# ── B. references/consolidation.md: 既存 Issue への統合 ─────────────────────────
once "$REF_CONSOLIDATION" "統合元・統合先の本文は全文取得する" "Issue 統合は本文を全文取得（head で切らない）"
once "$REF_CONSOLIDATION" '（`head` / `tail` で切った出力を統合の根拠にしない）' "head / tail 出力を統合根拠にしない"
once "$REF_CONSOLIDATION" "survivor への転記を機械的に確認する" "クローズ前に survivor 転記を実測確認"
once "$REF_CONSOLIDATION" "コメントだけを既定" "既存 Issue 統合はコメントが既定"
once "$REF_CONSOLIDATION" "本文の変更を明示的に許可" "Issue 本文更新は明示許可が必要"
once "$REF_CONSOLIDATION" '`body` と `updatedAt`' "Issue 本文更新前に競合を確認"
once "$REF_CONSOLIDATION" 'gh issue comment {number} --repo "$expected_repo"' "Issue コメントが対象リポジトリへ束縛"
once "$REF_CONSOLIDATION" 'gh issue edit {number} --repo "$expected_repo"' "Issue 本文更新が対象リポジトリへ束縛"
once "$REF_CONSOLIDATION" 'gh issue view {number} --repo "$expected_repo"' "統合元の全文取得が対象リポジトリへ束縛"

# ── C. references/filing.md: 新規起票 ─────────────────────────────────────────
H33="### 3.3 新規 Issue 作成（body-file + 単純コマンド分割）"
sec_once "$REF_FILING" "$H33" "起票は PR 作成より前に行う" "起票が PR 作成に先行する順序制約"
sec_once "$REF_FILING" "$H33" '<!-- follow-up issue: TBD -->' "後回し時のプレースホルダ運用"
sec_once "$REF_FILING" "$H33" "AC の分量・詳細度を SKILL.md §1.3 の A/B 判定へ逆流させない" "起票時の AC 記載を A/B 判定へ逆流させない"
sec_once "$REF_FILING" "#### 報告の書き分け（「不在」と「照会失敗」を混同しない）" "省略したラベル名" "省略したラベルを報告（黙って落とさない）"
# Epic の照会は散文中のインラインコードなので、issue-label-contract のフェンス走査には載らない。
sec_once "$REF_FILING" "#### Epic への紐付け（該当する場合のみ）" 'gh issue list --repo "$expected_repo" --label epic --state open' "Epic の照会が対象リポジトリへ束縛"
# bundle の新設手順は起票側（filing.md）へ移した。本線の類似度表は振り分けの結論だけを持つ —
# 手順が本線へ戻る・両方に写る変更を赤にする（本線の件数は grep -c の 0 件で見る）。
sec_once "$REF_FILING" "#### Epic への紐付け（該当する場合のみ）" '`/create-issue --bundle`' "bundle の新設手順が filing.md の Epic 紐付け節にある"
# 新設手順の 2 分岐（カテゴリ Epic があれば親を付ける / bundle ラベルが無ければ Related で関連付ける）。
sec_once "$REF_FILING" "#### Epic への紐付け（該当する場合のみ）" '（カテゴリ Epic があれば `--parent`）' "bundle の新設: カテゴリ Epic があれば --parent で親を付ける"
sec_once "$REF_FILING" "#### Epic への紐付け（該当する場合のみ）" '既存 Issue を `Related: #{number}` として関連付ける' "bundle の新設: bundle ラベルが無ければ Related で関連付ける"
n_bundle_create="$(grep -cF -- '/create-issue --bundle' "$SKILL")" || true
if [[ "$n_bundle_create" == 0 ]]; then
  ok "bundle の新設手順が本線に無い（振り分けの結論だけを持つ）"
else
  bad "bundle の新設手順が本線に無い（本線に ${n_bundle_create:-読めない} 行: /create-issue --bundle）"
fi

# ── D. 振り分け表と、スキル内の参照の解決 ───────────────────────────────────────
# 本線の SKILL.md は毎回読まれ、references/*.md は振り分け表の条件に当たったときだけ
# 読まれる。表の行が消えると、reference に置いた規定は存在しても**読まれる経路が無い**。
# 行ごとに「読む条件 + リンク」を針にし、描画される表の行として成立していることまで見る —
# 節から HTML コメント（1 行でも複数行でも）を除き、最初に連続する表（行頭がパイプ記号）の
# 行だけを数える。コメントへ退避した行や、表から離れた位置の写しを「在る」と数えない。
REF_ROUTES=(
  "filing.md|| §3.1 で統合できる既存 Issue が無く、新規に起票する（\`bundle\` の sub-issue を含む） | [references/filing.md](references/filing.md) |"
  "consolidation.md|| §3.1 の類似度表で既存 Issue・\`bundle\` への統合（コメント・本文への AC 追記）を選んだ | [references/consolidation.md](references/consolidation.md) |"
  "examples.md|| §1 の YAGNI / A / B の境界で迷う | [references/examples.md](references/examples.md) |"
)
strip_html_comments() { # stdin → stdout。閉じないコメントは以降をすべてコメントとして落とす
  awk '{
    line = $0; out = ""
    while (line != "") {
      if (in_c) {
        p = index(line, "-->"); if (p == 0) { line = ""; break }
        line = substr(line, p + 3); in_c = 0
      } else {
        p = index(line, "<!--"); if (p == 0) { out = out line; line = ""; break }
        out = out substr(line, 1, p - 1); line = substr(line, p + 4); in_c = 1
      }
    }
    print out
  }'
}

# 表に載らない reference は読まれる経路が無く、表のリンク先が無ければ条件に当たっても開けない。
# 実体（references/*.md）の各ファイルへのリンクが表の行のちょうど 1 行に現れること、表の行の
# リンク先がすべて実在することを両向きに見る。
ROUTING_HEADING="## 条件付きで読む references"
if ! ROUTING_SECTION="$(section_scope_extract_prose "$SKILL" "$ROUTING_HEADING")"; then
  bad "振り分け表: 節を切り出せる（不足: ${ROUTING_SECTION}）"
else
  ok "振り分け表: 節を切り出せる"
  ROUTING_ROWS="$(strip_html_comments <<<"$ROUTING_SECTION" | awk '/^\|/ { t = 1; print; next } t { exit }')"
  for route in "${REF_ROUTES[@]}"; do
    n="$(FF_NEEDLE="${route#*|}" awk 'index($0, ENVIRON["FF_NEEDLE"]) == 1 { c++ } END { print c + 0 }' <<<"$ROUTING_ROWS")"
    once_verdict "$n" "${route#*|}" "振り分け表: ${route%%|*} を読む条件とリンク（表の行として）"
  done
  REF_FILES_SEEN=0
  for ref_file in "$SKILL_REFS"/*.md; do
    [[ -e "$ref_file" ]] || continue
    REF_FILES_SEEN=$((REF_FILES_SEEN + 1))
    ref_name="${ref_file##*/}"
    n="$(FF_NEEDLE="](references/${ref_name})" awk 'index($0, ENVIRON["FF_NEEDLE"]) { c++ } END { print c + 0 }' <<<"$ROUTING_ROWS")"
    once_verdict "$n" "](references/${ref_name})" "振り分け表: references/${ref_name} が表の行に載っている"
  done
  if [[ "$REF_FILES_SEEN" -eq 0 ]]; then
    bad "振り分け表: references/ の実体を列挙できる（不足: references/*.md が 0 件）"
  fi
  ROUTE_TARGETS="$(awk '{ line = $0; while (match(line, /\]\(references\/[^)]*\)/)) { print substr(line, RSTART + 2, RLENGTH - 3); line = substr(line, RSTART + RLENGTH) } }' <<<"$ROUTING_ROWS")"
  ROUTE_MISSING=""
  while IFS= read -r target; do
    [[ -n "$target" ]] || continue
    [[ -s "$SKILL_DIR/$target" ]] || ROUTE_MISSING="${ROUTE_MISSING}${target} "
  done <<<"$ROUTE_TARGETS"
  if [[ -z "$ROUTE_TARGETS" ]]; then
    bad "振り分け表: リンク先がすべて実在する（不足: 表にリンクが 1 件も無い）"
  elif [[ -z "$ROUTE_MISSING" ]]; then
    ok "振り分け表: リンク先がすべて実在する"
  else
    bad "振り分け表: リンク先がすべて実在する（不足: ${ROUTE_MISSING% }）"
  fi
fi

# 以降の検査（旧規則の不在・リンク解決・見出し・ラベル抽出）は references/*.md を平らな glob で
# 数える。サブディレクトリ・隠しファイル（`.x.md` は glob に一致しない）・.md 以外のファイルは
# その全部から黙って外れるので、置かせない。
REFS_STRAY=""
while IFS= read -r entry; do
  rel="${entry#"$SKILL_REFS"/}"
  [[ "$rel" == .DS_Store ]] && continue  # Finder の生成物（gitignore 済み）
  if [[ "$rel" == */* || "$rel" == .* || "$rel" != *.md || -L "$entry" || ! -f "$entry" ]]; then
    REFS_STRAY="${REFS_STRAY}${rel} "
  fi
done < <(find "$SKILL_REFS" -mindepth 1)
if [[ -z "$REFS_STRAY" ]]; then
  ok "references/ は直下の通常の .md ファイルだけで構成される"
else
  bad "references/ は直下の通常の .md ファイルだけで構成される（対象外: ${REFS_STRAY% }）"
fi

# references/ は 1 階層深いので、SKILL.md から移した相対リンク（../../docs-template/…）は
# そのままでは壊れる。skill-references-existence は SKILL.md → references/ の 1 段目しか
# 見ないので、スキル内の全ファイルの相対リンクをここで解決する。対象はインライン形式
# `](相対パス)` と参照形式の定義 `[名前]: 相対パス`（URL・ページ内アンカー・脚注 `[^n]:` は除く）。
# `<…>` の囲みと ` "title"` を剥がし、`%20` を空白へ戻し、アンカー部を落としてから、末尾 `/` なら
# ディレクトリ、それ以外は通常ファイルとして実在を見る。プラグインの外かどうかは物理パスでなく
# 字句で判定する — ファイルのプラグイン内の深さから `..` ごとに 1 段上がり、ルートより上へ出たら外
# （モノレポでは一度外へ出て入り直すリンクも実在するが、配布先では版ディレクトリの外を指して壊れる）。
lexically_inside() { # $1=プラグインルートからのディレクトリ $2=相対パス
  local depth=0 seg
  local -a parts
  IFS=/ read -ra parts <<<"$1"
  for seg in "${parts[@]}"; do [[ -n "$seg" && "$seg" != . ]] && depth=$((depth + 1)); done
  IFS=/ read -ra parts <<<"$2"
  for seg in "${parts[@]}"; do
    case "$seg" in
      '' | .) ;;
      ..) depth=$((depth - 1)); [[ "$depth" -ge 0 ]] || return 1 ;;
      *) depth=$((depth + 1)) ;;
    esac
  done
  return 0
}
LINKS_SEEN=0
LINKS_BROKEN=""
for doc in "$SKILL" "$SKILL_REFS"/*.md; do
  [[ -e "$doc" ]] || continue
  doc_dir="$(dirname "$doc")"
  doc_rel="${doc#"$SKILL_DIR"/}"
  doc_plugin_dir="${doc_dir#"$PLUGIN_ROOT"/}"
  while IFS= read -r target; do
    [[ -n "$target" ]] || continue
    LINKS_SEEN=$((LINKS_SEEN + 1))
    t="${target%% \"*}"
    t="${t#<}"; t="${t%>}"
    t="${t//%20/ }"
    t="${t%%#*}"
    path="$doc_dir/$t"
    if ! lexically_inside "$doc_plugin_dir" "$t"; then
      LINKS_BROKEN="${LINKS_BROKEN}${doc_rel}→${target}（プラグイン外） "
    elif [[ "$t" == */ ]]; then
      [[ -d "$path" ]] || LINKS_BROKEN="${LINKS_BROKEN}${doc_rel}→${target} "
    else
      [[ -f "$path" ]] || LINKS_BROKEN="${LINKS_BROKEN}${doc_rel}→${target} "
    fi
  done < <(awk '
    { line = $0; while (match(line, /\]\([^)#][^)]*\)/)) { t = substr(line, RSTART + 2, RLENGTH - 3); if (t !~ /^[a-z]+:/) print t; line = substr(line, RSTART + RLENGTH) } }
    /^[[:space:]]*\[[^]^][^]]*\]:[[:space:]]*[^[:space:]]/ { t = $0; sub(/^[[:space:]]*\[[^]]+\]:[[:space:]]*/, "", t); sub(/[[:space:]].*$/, "", t); if (t !~ /^[a-z]+:/ && t !~ /^#/) print t }
  ' "$doc")
done
if [[ "$LINKS_SEEN" -eq 0 ]]; then
  bad "スキル内の相対リンクがすべて解決する（不足: 相対リンクを 1 件も抽出できない）"
elif [[ -z "$LINKS_BROKEN" ]]; then
  ok "スキル内の相対リンクがすべて解決し、プラグイン内を指す（${LINKS_SEEN} 件）"
else
  bad "スキル内の相対リンクがすべて解決し、プラグイン内を指す（解決不能: ${LINKS_BROKEN% }）"
fi

# 他文書やスキル内のファイル間は節番号・節名で参照している（ルートの AGENTS.md / CLAUDE.md と
# git-workflow の「§1.2〜§3.1」、create-issue の「§3.1」、workflow-principles の「§1.3「迷ったら」」、
# multi-review の「§1.0」、Playbook の「§4」、git-workflow / create-issue の filing.md「§3.3」、
# github-labels-setup の「Epic への紐付け」、references から本線への「SKILL.md §X」、本線から
# filing.md への「§3.4」など）。見出しは**期待するファイル**のフェンス外にちょうど 1 本、他の
# ファイルには 0 本であることを見る — 数える場所を問わないと、§1.0 を本線から examples.md へ
# 移しても緑になり、「§1〜§3.1b は本線だけで完結する」が黙って崩れる。
REFERENCED_HEADINGS=(
  "SKILL.md|## 1. 判定（順序を変えない）"
  "SKILL.md|$H10"
  "SKILL.md|$H12"
  "SKILL.md|$H13"
  "SKILL.md|$HMAYOU"
  "SKILL.md|## 3. Issue 化フロー"
  "SKILL.md|$H31"
  "SKILL.md|$H31B"
  "SKILL.md|## 4. Claude Code 以外から使う場合"
  "SKILL.md|## 5. ff-dev-toolkit 内での位置づけ"
  "references/filing.md|### 3.2 ラベルの決定（実在するものだけ付ける）"
  "references/filing.md|#### Epic への紐付け（該当する場合のみ）"
  "references/filing.md|$H33"
  "references/filing.md|### 3.4 Title prefix"
  "references/filing.md|### 3.5 Context 自動検出"
  "references/filing.md|### 3.6 戻り値"
)
for pair in "${REFERENCED_HEADINGS[@]}"; do
  home="${pair%%|*}"
  heading="${pair#*|}"
  label="外部参照される見出し: ${heading#\#* }（${home}）"
  if ! n_home="$(section_scope_heading_count "$SKILL_DIR/$home" "$heading")"; then
    bad "${label}（検査不能: ${n_home}）"
    continue
  fi
  if [[ "$n_home" -ne 1 ]]; then
    bad "${label}（${home} のフェンス外に ${n_home} 本。1 本であること）"
    continue
  fi
  # 他のファイルはフェンス内の例示も含めて 0 本（見出しの写しは移動の取り残しか退避の跡）。
  elsewhere=""
  for other in "$SKILL" "$SKILL_REFS"/*.md; do
    [[ "$other" == "$SKILL_DIR/$home" ]] && continue
    n="$(awk -v h="$heading" '{ sub(/\r$/, "") } $0 == h { c++ } END { print c + 0 }' "$other")"
    [[ "$n" -eq 0 ]] || elsewhere="${elsewhere}${other#"$SKILL_DIR"/} "
  done
  if [[ -z "$elsewhere" ]]; then
    ok "$label"
  else
    bad "${label}（別のファイルにもある: ${elsewhere% }）"
  fi
done

# 判定例は振り分け表が「判定例 6 件」と名指しする。件数と各例の判定行を数え、中身を消して
# 見出しだけ残した examples.md を「在る」と数えない。
EXAMPLE_HEADS="$(awk '/^## 例 [0-9]+: / { c++ } END { print c + 0 }' "$REF_EXAMPLES")"
EXAMPLE_VERDICTS="$(awk '/^判定: / { c++ } END { print c + 0 }' "$REF_EXAMPLES")"
if [[ "$EXAMPLE_HEADS" -eq 6 && "$EXAMPLE_VERDICTS" -eq 6 ]]; then
  ok "判定例が 6 件あり、各例に判定行がある（振り分け表の「判定例 6 件」と一致）"
else
  bad "判定例が 6 件あり、各例に判定行がある（例の見出し ${EXAMPLE_HEADS} 件・判定行 ${EXAMPLE_VERDICTS} 件。増減時は振り分け表の件数も直すこと）"
fi
once "$SKILL" "| 判定例 6 件 |" "振り分け表が判定例の件数を名指し"

# ファイルまで指す節参照は、節の移動で指す先が古くなる（見出しの一意性だけでは見えない）。
# §3.3 を旧ファイル（スキル名だけ = SKILL.md）で指す形の復元を塞ぐ。
not_contains "$CREATE_ISSUE_FILING" '`out-of-scope-issue` §3.3' "create-issue（references/filing.md）: 起票手順の複製元を旧ファイル（SKILL.md）で指していない"
not_contains "$GIT_WORKFLOW" '`out-of-scope-issue` スキル §3.3' "git-workflow: 起票順序の詳細を旧ファイル（SKILL.md）で指していない"

# ── E. 消費側文書 ─────────────────────────────────────────────────────────────
contains "$CLOSE_ISSUE" "Issue 本文は全文取得する" "close-issue も本文を全文取得（AC 照合の入力を切らない）"

contains "$WORKFLOW" "YAGNI → インライン修正 → Issue 化" "Git Workflow が三分岐を正本化"
contains "$WORKFLOW" "類似 Issue を検索" "Git Workflow が重複 Issue を抑制"
contains "$WORKFLOW" "同じ完了条件へ軽微に吸収できる場合" "既存 Issue へのコメント・AC 統合"
contains "$WORKFLOW" "既定は既存 Issue への発見元コメントだけ" "Git Workflow もコメント統合を既定化"
contains "$WORKFLOW" '編集直前に `body` / `updatedAt` の競合がない場合だけ' "Git Workflow の本文更新競合ゲート"
contains "$WORKFLOW" '--repo "$expected_repo"' "Git Workflow の Issue 作成先を固定"
gh_issue_blocks_bound "$WORKFLOW" "Git Workflow の全 Issue create コマンドを対象リポジトリへ束縛"
contains "$WORKFLOW" "完了条件が独立する場合" "独立時だけ関連 Issue を作成"
contains "$WORKFLOW" "同一 PR からの複数発見は既定で 1 Issue に束ねる" "Git Workflow もバッチ統合を既定化"
contains "$WORKFLOW" "規模・局所性・検証の重さの迷いはインラインへ倒す" "Git Workflow も軽量側既定を明記"
contains "$WORKFLOW" "不確かでも Issue 化へ倒し" "Git Workflow も仕様判断・波及の安全側を明記"

contains "$CLOSE_ISSUE" "現 Issue の AC はスコープ外発見ではない" "未達 AC を後続 Issue へ送らない"
not_contains "$CLOSE_ISSUE" "別 Issue を起票（\`gh issue create\`）して当該 AC を「対象外」" "未達 AC の自動先送りを禁止"

contains "$REVIEW_POLICY" "変更対象外という理由だけで一律に別 Issue へ送らない" "レビュー指摘も三分岐へ委譲"
contains "$REVIEW_POLICY" "レビューで Critical / Warning と確定した指摘は現 PR で解消" "Critical / Warning は必ず現 PR で解消"
not_contains "$REVIEW_POLICY" "既存ファイルの改善は別Issueで対応する" "変更対象外ファイルの一律 Issue 化を禁止"
not_contains "$REVIEW_POLICY" "棚卸しパーキング" "独立 Warning のパーキングを導入しない"
contains "$WORKFLOW" "スコープ外発見の三分岐" "原則2の見出しが三分岐のまま"
not_contains "$WORKFLOW" "スコープ外発見の優先度ルーティング" "原則2を優先度ルーティングへ再編しない"

contains "$OSS_README" "YAGNI（対応も Issue 化もしない）→ 軽微ならインライン修正 → Issue 化" "公開 README が三分岐"
not_contains "$OSS_README" "「同 PR でインライン修正」か「Issue 化して後送り」" "公開 README の旧二分岐を排除"
contains "$OSS_COPILOT" "次の5境界" "公開 Copilot ガイドが5境界"
contains "$OSS_COPILOT" "Issue 化前に類似 Issue を検索" "公開 Copilot ガイドが類似 Issue を検索"

# 軽微（インライン）判定の契約行。「全条件 AND」から「B 条件のいずれにも明確に該当しない」へ
# 反転した。旧契約文字列の残骸・復元は not_contains で塞ぐ（マージ解決ミスで新旧が併存しても
# contains だけでは緑のままになるため）。
INLINE_CONTRACT="仕様判断・別モジュール波及・独立検証・実装 10 行超（テスト・fixture は数えない）のいずれにも明確に該当しない"
# 近傍ファイル許容句は上の契約行の外に続くため別針で固定する（削除が黙って通るのを防ぐ）。
# 散文 5 ファイルは「。近傍…」、workflow-principles の表セルは「（近傍…）」と句読点が違うので、
# 両者に共通の部分文字列を針にする。
NEIGHBOR_CLAUSE="近傍の設定ファイルの小変更も含む"
OLD_INLINE_CONTRACT="10 行以内・同一ファイル・仕様判断不要"
# 対象ファイル数を明示して固定する。生成対象が減ったときにループが黙って縮み、検査して
# いないのに全 pass に見えるのを防ぐ。
EXPECTED_INLINE_CONSUMERS=6
INLINE_CONSUMERS_SEEN=0
for file in \
  "$PLUGIN_ROOT/skills/setup-ai-config/SKILL.md" \
  "$PLUGIN_ROOT/docs-template/SETUP_CLAUDE_CODE.md" \
  "$PLUGIN_ROOT/docs-template/05-operations/deployment/workflow-principles.md" \
  "$PLUGIN_ROOT/tests/setup-ai-config/fixtures/expected/CLAUDE.md" \
  "$PLUGIN_ROOT/tests/setup-ai-config/fixtures/expected/AGENTS.md" \
  "$PLUGIN_ROOT/tests/setup-ai-config/fixtures/expected/.github/copilot-instructions.md"; do
  contains "$file" "$INLINE_CONTRACT" "生成・公開コンシューマーが軽微判定の契約行を保持: ${file#$REPO_ROOT/}"
  contains "$file" "$NEIGHBOR_CLAUSE" "近傍ファイル許容句を保持: ${file#$REPO_ROOT/}"
  not_contains "$file" "$OLD_INLINE_CONTRACT" "旧契約行の残骸なし: ${file#$REPO_ROOT/}"
  INLINE_CONSUMERS_SEEN=$((INLINE_CONSUMERS_SEEN + 1))
done
if [[ "$INLINE_CONSUMERS_SEEN" -eq "$EXPECTED_INLINE_CONSUMERS" ]]; then
  PASS=$((PASS + 1)); echo "  ✓ 軽微判定の検査対象が ${EXPECTED_INLINE_CONSUMERS} 件（増減時は EXPECTED_INLINE_CONSUMERS も更新すること）"
else
  FAIL=$((FAIL + 1)); echo "  ✗ 軽微判定の検査対象が ${INLINE_CONSUMERS_SEEN} 件（期待 ${EXPECTED_INLINE_CONSUMERS} 件）— ループが黙って縮んでいる" >&2
fi

echo
if [[ "$FAIL" -gt 0 ]]; then
  echo "✗ out-of-scope routing verify: $FAIL 件失敗 / $PASS 件成功" >&2
  exit 1
fi

echo "✓ out-of-scope routing verify: 全 $PASS 件 pass"
