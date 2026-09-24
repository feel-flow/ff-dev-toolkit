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
#
# 変異検出（承認待ちの窓を覆う照合・OBS-004）:
#           `merge-base --is-ancestor` の引数を逆転させると 2 件が赤。
#           clean tree の検査を削ると 2 件が赤（R3 と同じ集合を見ないと、承認前は通って
#           R3 で止まる形が残る）。
#           fetch 失敗の停止を削ると 1 件が赤。**当初この変異は生存した** — fetch 失敗の
#           検査を remote 先行より後ろに置いていたため、先行した remote-tracking ref のせいで
#           別の理由（先行判定）で止まっており、fetch 失敗の停止を測れていなかった。
#           「stale だが通る値」の状態で fetch を失敗させる順序へ組み替えて解消。
#           節ごと移動させる（配置を失う）と 7 件が赤（針は節スコープで張ってある。
#           節スコープ針 6 本 + フェンス抽出の空振り 1 件。針を増減したらこの数も更新すること）。
#           `retrospective` が自前の base 先行ガードを持つ、という相互参照を削ると 1 件が赤
#           （2026-09-15 実測。実体側は tests/retrospective-contract が固定する）。
#
# 変異検出（本線の 20 KB 化・操作別手順の references/operations.md への移設。2026-09-24 実測）:
#           R3 開始前ガードの fence を消して「承認前の fence を再実行する」形へ畳んだ後も、承認前 fence の
#           `merge-base --is-ancestor` の引数を逆転させると 2 件が赤（節スコープ針 + 抽出実行）。
#           operations.md の R3-a から「ちょうど 1 件」の一文を削ると 1 件が赤（付け替え先で当たる）。
#           R3 の「fence をもう一度実行する」一文を削ると 2 件、R3 から operations.md への経路を削ると
#           1 件、operations.md の R3-a 見出しを崩すと 2 件が赤。
#
# 空振り検出: 本線 SKILL.md を 20,001 B にすると 1 件が赤、references/operations.md を空にすると検査対象の
#             存在検査で中断して赤になる（2026-09-24 実測。本線が上限を超える・操作別手順の置き場所が
#             空になる変更を「契約あり」へ倒さない）。
#
# 変異検出（curate の追記前予測・完了報告の契約）:
#           上限以上のとき「追記したうえでフォローアップに記録する」へ書き換えると 1 件が赤。
#           **当初この変異は生存した** — 条件（上限以上なら）と帰結（停止する）を別々の針で
#           張っており、帰結の語が上のフェンスの診断文にも在るため吸収されていた。条件と帰結を
#           同じ 1 文として固定して解消。
#           方針を反転（超えてから直す）すると 1 件が赤。
#           「記録した」で完了にしない、を削ると 1 件が赤。
#           予測節を**見出しごと**追記手順の後ろへ移すと 1 件が赤（節スコープの針は移動を
#           検出できないため、見出しの前後関係そのものを検査している）。
#           上限を警告行から読む形へ戻すと 1 件が赤。
#           fence の `case` を丸ごと `|| true` へ差し替えると 4 件が赤。**当初この変異は生存した**
#           — 針が散文（「rc を || true で捨てない」）にしか当たっておらず、実行される側が
#           無防備だった。fence 本体へ針を張り、握り潰しの形を否定側からも見て解消。
#           警告行に依存すると fail-open になる、という説明を反転すると 1 件が赤。
#           catch-all を rc=2 限定へ狭める（rc 3 が素通り）と 1 件が赤。
#           実体の選択を同梱固定へ戻す（プロジェクトの閾値上書きを取りこぼす）と 1 件が赤。
#           停止条件を「上限以上」へ戻す（ゲートは count > max なので 1 件早く止まる）と 1 件が赤。
#           報告契約が参照する検証の出所を実体と不一致にすると 1 件が赤。
#           非 0 を返さない 4-e を機械的検証の列挙へ戻すと 1 件が赤（その除外理由を削っても 1 件が赤）。
#           check-category-size から常時出力のブロック上限行を削ると 1 件が赤
#           （実出力に対する behavioural 検査。文言検査では見えない）。
#           良性: 節の配置要件を述べた一文を削っても緑（配置は上の順序検査が機械的に守る）。

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
REFINE_FILE="$PLUGIN_ROOT/skills/ace-refine/SKILL.md"
# 操作別の手順（R3-a〜R3-d）は本線から references へ移した。本線が「承認された操作の節だけを読む」
# と案内する先なので、そこに在ることが要件の針はこのファイルへ張る。
REFINE_OPERATIONS_FILE="$PLUGIN_ROOT/skills/ace-refine/references/operations.md"
CURATE_FILE="$PLUGIN_ROOT/skills/ace-curate/SKILL.md"
# curate 側のハードルール（append-only・refine 専権・行数バジェット・allowlist の抜け道禁止）は
# 本線から条件付き reference へ移した。針はその reference へ張る。
CURATE_RULES="$PLUGIN_ROOT/skills/ace-curate/references/curate.md"
PLAYBOOK_TEMPLATE="$PLUGIN_ROOT/docs-template/08-knowledge/PLAYBOOK.md"
PATTERNS_TEMPLATE="$PLUGIN_ROOT/docs-template/03-implementation/PATTERNS.md"
ACE_CYCLE_TEMPLATE="$PLUGIN_ROOT/docs-template/05-operations/deployment/ace-cycle.md"
CHECK_SIZE_SCRIPT="$PLUGIN_ROOT/docs-template/scripts/ace/check-category-size.ts"
REFINE_REPORT_SCRIPT="$PLUGIN_ROOT/docs-template/scripts/ace/ace-refine-report.ts"
FORMAT_GATE_SCRIPT="$PLUGIN_ROOT/docs-template/scripts/ace/check-entry-format.ts"
INVARIANTS_GATE_SCRIPT="$PLUGIN_ROOT/docs-template/scripts/ace/check-refine-invariants.ts"
LEGACY_ALLOWLIST_TEMPLATE="$PLUGIN_ROOT/docs-template/08-knowledge/legacy-format-allowlist.txt"
ESBUILD_BIN="$PLUGIN_ROOT/mcp/node_modules/.bin/esbuild"

# shellcheck source=../lib/section-scope.sh
. "$SCRIPT_DIR/../lib/section-scope.sh"

for f in "$REFINE_FILE" "$REFINE_OPERATIONS_FILE" "$CURATE_FILE" "$PLAYBOOK_TEMPLATE" "$PATTERNS_TEMPLATE" \
         "$ACE_CYCLE_TEMPLATE" "$CHECK_SIZE_SCRIPT" "$REFINE_REPORT_SCRIPT" \
         "$FORMAT_GATE_SCRIPT" "$INVARIANTS_GATE_SCRIPT"; do
  [ -s "$f" ] || {
    echo "✗ 検査対象が存在しないか空です: $f" >&2
    exit 1
  }
done

# 後半の check-entry-format 統合検査は一時領域を必要とする。静的検査だけを先に
# pass として数えてから環境都合で落ちると本物の回帰と区別できないため、suite 全体の
# 開始前に同じ TMPDIR を probe し、使えない場合は検査 0 件の明示 skip にする。
# rc=0 でも -d を検査する — 2>&1 の合流は「成功 + stderr 警告」の環境で変数へ
# 警告文が混入し、以後の処理が原因不明の失敗に化けるため。
if _ff_tmp_probe="$(mktemp -d "${TMPDIR:-/tmp}/ace-refine-preflight.XXXXXX" 2>&1)" && [ -d "$_ff_tmp_probe" ]; then
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

# 節スコープの固定文言検査。文書全体の grep だけだと、同じ文をハードルール節へ
# 書き写した時点で手順側から消えても緑のままになる（本 suite で実測: R3-0 の
# 一意性の一文を存在検証へ戻してもハードルールの写しに一致し、全件 pass だった）。
# 手順の分岐は「その節に在ること」自体が要件なので、節を切り出してから照合する。
# 実装の正本は tests/lib/section-scope.sh（Issue #812 で本 suite から切り出した）。
# 判断基準（どの検査を節スコープへ寄せるか）はそのヘッダーコメントを見ること。
section_contains() {
  local file="$1" heading="$2" needle="$3" label="$4" reason
  if reason="$(section_scope_contains "$file" "$heading" "$needle")"; then
    ok "$label"
  else
    bad "${label} — ${reason}"
  fi
}

echo "== ace-refine 本線の上限 =="

# 本線は毎回読まれる骨格だけを持ち、操作別・domain・コミットの手順は references へ置いた。
# 本線が再び膨らむのを止める。wc が数値を返さない場合も赤にする（fail-closed）。
REFINE_MAX_BYTES=20000
if ! refine_bytes="$(wc -c < "$REFINE_FILE" | tr -d '[:space:]')"; then
  refine_bytes="(wc 失敗)"
fi
if [[ "$refine_bytes" =~ ^[0-9]+$ ]] && (( refine_bytes <= REFINE_MAX_BYTES )); then
  ok "本線のバイト数: ${refine_bytes} B（上限 ${REFINE_MAX_BYTES} B）"
else
  bad "本線のバイト数が上限を超えた、または測れない: \"${refine_bytes}\" B（上限 ${REFINE_MAX_BYTES} B）"
fi

echo ""
echo "== ace-refine ハードルール（安全弁の固定文言） =="

contains "$REFINE_FILE" \
  "dry-run レポートの提示とユーザー承認より前に、いかなるファイルも書き換えない" \
  "承認前書き換え禁止"
# 承認待ちで空く窓の照合（OBS-004 の 3 回目で閾値到達）。R3 開始前ガードは**適用の直前**に
# 在るが、窓はその手前に開く。針は **節スコープ**で張る — 全文 grep だと、ハードルール節への
# 写しや R3 への移動で「承認より前に在る」という要件を失ったまま緑になる。
REFINE_PREGATE_SECTION="#### 承認を求める前に base の先行を照合する"
section_contains "$REFINE_FILE" "$REFINE_PREGATE_SECTION" \
  "レポートを提示する直前に照合する" \
  "承認を求める前の照合点（窓を実際に狭める唯一の検出点）"
section_contains "$REFINE_FILE" "$REFINE_PREGATE_SECTION" \
  "承認のやり直しが発生しない" \
  "承認前に照合する目的（手戻りを dry-run の作り直しに留める）"
section_contains "$REFINE_FILE" "$REFINE_PREGATE_SECTION" \
  'git merge-base --is-ancestor "origin/${default_branch}" HEAD' \
  "承認前の照合が base 先行を見る"
section_contains "$REFINE_FILE" "$REFINE_PREGATE_SECTION" \
  'git status --porcelain --untracked-files=all' \
  "承認前の照合が clean tree も見る（R3 と同じ集合。片方だけだと承認後に止まる）"
section_contains "$REFINE_FILE" "$REFINE_PREGATE_SECTION" \
  "承認待ちの窓の後段に default ブランチの共有文書への" \
  "対象範囲を閉じた理由（窓の後段に共有文書への書き込みがあるか）"
# `retrospective` は同じ共有文書（OBS 台帳）へ直接 push するので、本規定の対象外にした
# 理由は「承認待ちの窓を持たない」であって「照合が要らない」ではない。相互参照が
# 片側だけ腐ると、`retrospective` のガードを外しても本節の注記は「持つ」と言い続ける
# （その実体は tests/retrospective-contract が固定している）。
section_contains "$REFINE_FILE" "$REFINE_PREGATE_SECTION" \
  "**記録内容を作る前**（同一性判定・\`Count\`・OBS ID 採番より前）の照合を自前で持つ" \
  "retrospective が自前の base 先行ガードを持つと相互参照している"
section_contains "$REFINE_FILE" "### Phase R3: 適用" \
  "同じ集合" \
  "R3 開始前ガードが承認前の照合と同じ集合を見ると明記している"
section_contains "$REFINE_FILE" "### Phase R3: 適用" \
  "承認の直後に 3 つめの検出点は置かない" \
  "承認直後に検出点を置かない理由（時間窓が縮まらない）"
section_contains "$REFINE_FILE" "### Phase R3: 適用" \
  "適用後にも 2 度目の先行が起きうる" \
  "適用後（claim 生成時）の 2 度目の先行に触れている"
section_contains "$REFINE_FILE" "### Phase R3: 適用" \
  "適用済みの成果は**捨てない**" \
  "2 度目の先行からの復帰手順（成果を捨てない）"
# R3 開始前ガードは承認前の fence と同じ中身だったので、fence を 1 本に畳んで再実行を指示する形に
# した。この一文が消えると R3 の開始時に base を照合する手順そのものが本線から無くなる。
section_contains "$REFINE_FILE" "### Phase R3: 適用" \
  "の fence をもう一度実行する" \
  "R3 開始の直前に承認前の照合 fence を再実行する"
# 操作別の手順は references/operations.md にだけ在る。本線から読む経路が消えると、承認された
# 操作の手順（archive の冒頭注記・一意性検証・provenance の変種）に実行者が届かない。
section_contains "$REFINE_FILE" "### Phase R3: 適用" \
  "[references/operations.md](references/operations.md)" \
  "R3 が操作別の手順（references/operations.md）を読む経路を案内する"

# 固定文言の針は「文言が在る」ことしか見ない。引数を逆転させても fetch 失敗の停止を削っても
# 通るので、**SKILL.md からガードのフェンスを抽出して実際に動かす**。
echo ""
echo "== base 鮮度ガードの振る舞い（SKILL.md から抽出して実行） =="

if ! command -v git >/dev/null 2>&1; then
  echo "  ○ skip: git が無いため base 鮮度ガードの実測をスキップ（この検査は 1 件も実行していません）"
elif ! _bf_tmp="$(mktemp -d "${TMPDIR:-/tmp}/ace-refine-basefresh.XXXXXX" 2>&1)" || [ ! -d "$_bf_tmp" ]; then
  # 診断を捨てると不正 TMPDIR と read-only を区別できないため、成功時のパスと失敗時の理由を
  # 同じ変数へ受ける。rc=0 でも -d を検査する — 2>&1 の合流は「成功 + stderr 警告」の環境で
  # 変数へ警告文が混入し、以後の処理が原因不明の失敗に化けるため。
  echo "  ○ skip: 一時ディレクトリを作成できないため base 鮮度ガードの実測をスキップ"
  printf '    mktemp: %s\n' "$_bf_tmp"
else
  # 承認前の照合フェンスを節から取り出す。抽出できなければ空振りなので止める。
  _bf_fn="$_bf_tmp/guard.sh"
  awk -v sec="$REFINE_PREGATE_SECTION" '
    $0 == sec { in_sec = 1; next }
    in_sec && /^#### |^### / { in_sec = 0 }
    in_sec && /^```bash$/ { in_fence = 1; next }
    in_fence && /^```$/ { in_fence = 0; exit }
    in_fence { print }
  ' "$REFINE_FILE" > "$_bf_fn"
  if ! /usr/bin/grep -qF 'merge-base --is-ancestor' "$_bf_fn"; then
    bad "SKILL.md から承認前の照合フェンスを抽出できない（この検査は空振りします）"
  else
    _bf_git() { git -c commit.gpgsign=false -c user.email=t@example.invalid -c user.name=T -c init.defaultBranch=main "$@"; }
    _bf_setup=0
    _bf_git init -q --bare "$_bf_tmp/remote.git" >/dev/null 2>&1 || _bf_setup=1
    _bf_git clone -q "$_bf_tmp/remote.git" "$_bf_tmp/work" >/dev/null 2>&1 || _bf_setup=1
    ( cd "$_bf_tmp/work" 2>/dev/null \
      && printf 'seed\n' > seed.txt \
      && _bf_git add -A >/dev/null 2>&1 \
      && _bf_git commit -qm seed >/dev/null 2>&1 \
      && _bf_git push -q origin main >/dev/null 2>&1 ) || _bf_setup=1
    _bf_git -C "$_bf_tmp/work" remote set-head origin main >/dev/null 2>&1 || _bf_setup=1
    if [ "$_bf_setup" -ne 0 ]; then
      bad "base 鮮度ガードの git fixture を作れない（実測が成立していない）"
    else
      _bf_run() { ( cd "$_bf_tmp/work" && bash "$_bf_fn" >/dev/null 2>&1 ); }
      if _bf_run; then ok "base 鮮度ガード: 同一 HEAD・clean tree は通す"; else bad "base 鮮度ガードが正常系を止める"; fi
      ( cd "$_bf_tmp/work" && printf 'local\n' > local.txt && _bf_git add -A >/dev/null 2>&1 && _bf_git commit -qm local >/dev/null 2>&1 ) || true
      if _bf_run; then ok "base 鮮度ガード: ローカル先行（未 push）は通す"; else bad "base 鮮度ガードが正常なローカル先行を拒否する（引数の向きが逆）"; fi
      ( cd "$_bf_tmp/work" && printf 'dirty\n' > dirty.txt ) || true
      if _bf_run; then bad "base 鮮度ガードが dirty tree を通す（R3 で初めて止まる形が残る）"; else ok "base 鮮度ガード: dirty tree を止める（R3 と同じ集合）"; fi
      rm -f "$_bf_tmp/work/dirty.txt"
      # fetch 失敗の検査を **remote 先行より先に**置く。順序を逆にすると、先行した origin/main が
      # remote-tracking ref に残っているせいで先行判定の側で止まり、fetch 失敗の停止を削る変異が
      # 素通りする（実測で生存した）。ここでは remote-tracking ref が **stale だが通る値**の状態で
      # fetch を失敗させ、停止するのが fetch 失敗の停止だけである状況を作る。
      _bf_git -C "$_bf_tmp/work" remote set-url origin "$_bf_tmp/does-not-exist.git" >/dev/null 2>&1 || true
      _bf_git clone -q "$_bf_tmp/remote.git" "$_bf_tmp/other" >/dev/null 2>&1 || true
      ( cd "$_bf_tmp/other" && printf 'remote\n' > remote.txt && _bf_git add -A >/dev/null 2>&1 && _bf_git commit -qm remote >/dev/null 2>&1 && _bf_git push -q origin main >/dev/null 2>&1 ) || true
      if _bf_run; then bad "base 鮮度ガードが fetch 失敗時に stale な ref で通す（fail-open）"; else ok "base 鮮度ガード: fetch できない回は stale 値へ fallback せず止める"; fi
      # URL を戻すと、今度は fetch が成功して remote 先行そのものを検出する。
      _bf_git -C "$_bf_tmp/work" remote set-url origin "$_bf_tmp/remote.git" >/dev/null 2>&1 || true
      if _bf_run; then bad "base 鮮度ガードが remote 先行を通す（古い対象を承認させてしまう）"; else ok "base 鮮度ガード: remote 先行を検出して止める"; fi
    fi
  fi
  rm -rf "$_bf_tmp"
fi

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
contains "$REFINE_OPERATIONS_FILE" \
  "アーカイブ書き込みの検証（必須）" \
  "アーカイブ write の grep 検証ステップ（文言ルールの機械化）"
contains "$REFINE_FILE" \
  "エントリ保全の一括検証（必須）" \
  "コミット前の全 ID 保全 grep 検証"

echo
echo "== 同梱スクリプトへの到達可能性検査（Issue #694） =="

# ゲートの実行例が `path/to/` 等のプレースホルダのままだと、scripts/ace/ 未導入の
# プロジェクトでは「必須」と書かれたゲートが素通りする（Issue #614 と同一クラス）。
# 同梱テンプレートへの解決可能なパスを fail-closed で固定する。
REFINE_ALL_FILES=("$REFINE_FILE" "$PLUGIN_ROOT"/skills/ace-refine/references/*.md)
if grep -Fq -- 'path/to/' "${REFINE_ALL_FILES[@]}"; then
  bad "実行例に未解決のプレースホルダ path/to/ が残っています"
else
  ok "実行例に未解決のプレースホルダ path/to/ が無い"
fi

# 同梱テンプレート経路は ace-run-ts.sh 経由が正（Issue #879）。root package に tsx が
# 無い workspace では npx 直書きが command not found で全ゲート到達不能になる。
if grep -Fq -- 'npx --yes tsx "${FF_DEV_TOOLKIT_ROOT}' "${REFINE_ALL_FILES[@]}"; then
  bad "同梱テンプレート経路が npx --yes tsx 直書きへ戻っています（Issue #879 の退行）"
else
  ok "同梱テンプレート経路に npx --yes tsx 直書きが無い（ace-run-ts.sh 経由）"
fi

# 検証ゲート 5 本 + R1 の dry-run レポートすべてに、未導入プロジェクト向け fallback
#（同梱テンプレートの絶対パス）が実在するスクリプトへ向いていることを固定する。
for gate in ace-refine-report sync-playbook-frontmatter check-category-size \
  check-archive-links check-refine-invariants check-entry-format; do
  contains "$REFINE_FILE" \
    "\"\${FF_DEV_TOOLKIT_ROOT}/docs-template/scripts/ace/${gate}.ts\"" \
    "検証ゲート ${gate} の未導入 fallback パス"
  if [ -f "$PLUGIN_ROOT/docs-template/scripts/ace/${gate}.ts" ]; then
    ok "同梱テンプレート ${gate}.ts が実在する"
  else
    bad "同梱テンプレート ${gate}.ts が存在しません（fallback が到達不能）"
  fi
done

# 配布テンプレート ace-cycle.md のチェックリスト側にも同系統の到達不能が居た（Issue #694
# 発見 (3)）。fallback 導線と、変数解決の注記の両方を固定する。
ACE_CYCLE_TEMPLATE="$PLUGIN_ROOT/docs-template/05-operations/deployment/ace-cycle.md"
contains "$ACE_CYCLE_TEMPLATE" \
  '"${FF_DEV_TOOLKIT_ROOT}/scripts/ace-run-ts.sh" "${FF_DEV_TOOLKIT_ROOT}/docs-template/scripts/ace/sync-playbook-frontmatter.ts"' \
  "ace-cycle.md 同期検証チェック項目の未導入 fallback"
contains "$ACE_CYCLE_TEMPLATE" \
  '"${FF_DEV_TOOLKIT_ROOT}/scripts/ace-run-ts.sh" "${FF_DEV_TOOLKIT_ROOT}/docs-template/scripts/ace/ace-refine-report.ts"' \
  "ace-cycle.md dry-run チェック項目の未導入 fallback"
contains "$ACE_CYCLE_TEMPLATE" \
  'この変数を実パスへ解決しておくこと' \
  "ace-cycle.md に FF_DEV_TOOLKIT_ROOT の解決注記がある"

echo
echo "== archive / provenance 契約の 3 穴（Issue #288） =="

# 穴 1: provenance 注記が「再整形のみ」を表現できず、実際にしていない要約を記録していた。
# 2 変種と判定条件の両方を固定する（片方だけ残ると再び文言の孤島が生まれる）。
contains "$REFINE_OPERATIONS_FILE" \
  "> Compacted: YYYY-MM-DD（live 側を要約済み。本文の原文は本エントリが正）" \
  "provenance 注記 第1変種（本文を意味保存要約した場合）"
contains "$REFINE_OPERATIONS_FILE" \
  "> Compacted: YYYY-MM-DD（live 側はメタ表のみ正準フォーマットへ再整形。本文は逐語同一で無改変。本エントリが原文）" \
  "provenance 注記 第2変種（メタ表の再整形のみ・本文は逐語同一）"
contains "$REFINE_OPERATIONS_FILE" \
  "live 側の本文文字列が原文と逐語同一かどうか" \
  "2 変種の判定条件"
contains "$REFINE_FILE" \
  "provenance 注記は実際に行った操作に対応する変種を使う" \
  "ハードルール: 実際にしていない操作を注記に書かない"

# 穴 2: 保全本文内の相対リンクは verbatim 保全のため書き換えられない。
# 「書き換えない」と「注記が必須」は対で意味を持つ（片方だけでは行動が決まらない）。
contains "$REFINE_OPERATIONS_FILE" \
  "保全本文内の相対リンクは live 基準" \
  "archive 冒頭注記のテンプレート文言（機械ゲートの判定キー）"
contains "$REFINE_OPERATIONS_FILE" \
  "保全本文内の相対リンクは書き換えない" \
  "保全本文内リンクの非書き換え契約"
# check-archive-links / check-refine-invariants への導線は、下の「検証ゲートの未導入 fallback
# パス」の針（ゲートの実行行そのもの）が同じ語を含んでより強く固定している。

# 穴 3: 統合された側が archive で active のまま残り、grep した人に有効と誤読される。
contains "$REFINE_FILE" \
  "archive 側のコピーの \`Status\` を \`merged\` に変える" \
  "統合される側の Status を merged にする手順"
contains "$PLAYBOOK_TEMPLATE" \
  "\`merged\`" \
  "PLAYBOOK テンプレの §ステータス定義に merged がある"

echo
echo "== archive 追記前の共通規則（保全済み ID の分岐 / Issue #796） =="

# 過去の圧縮（R3-b）は原文を archive に残したまま live へ要約を置くので、live と
# archive の双方に同じ ID が在るのが正常な状態である。その ID を後から R3-a/R3-c で
# 「手順どおり」verbatim コピーすると同一 anchor が 2 つでき、アンカーは先勝ちなので
# 後から足したブロックへは到達できない（着地だけが静かに分裂する）。分岐（数える →
# 0 / 1 / 2 件以上）と一意性検証が SKILL.md から落ちると、実行者は毎回この穴を踏む。
# 同型は ACE-490-2 に記録済みだったが手順へ反映されておらず、再発した。
R30_HEADING="#### R3-0. archive へ追記する前の共通規則"
R3A_HEADING="## R3-a. stale エントリのアーカイブ"
R3B_HEADING="## R3-b. 長大エントリの圧縮"
R3C_HEADING="## R3-c. 近似重複の統合"
R3E_HEADING="#### R3-e. 索引・Frontmatter・Changelog の整合"
HARD_RULES_HEADING="## ハードルール"

contains "$REFINE_FILE" \
  "$R30_HEADING" \
  "保全済み ID の分岐が独立節として存在する"
section_contains "$REFINE_FILE" "$R30_HEADING" \
  'grep -c "^### <ID>:"' \
  "R3-0: archive の既存出現数を数えるコマンド（分岐の起点）"
section_contains "$REFINE_FILE" "$R30_HEADING" \
  "既に保全済みの ID へ原文を再コピーしない" \
  "R3-0: 保全済み ID には原文を再コピーしない分岐"
section_contains "$REFINE_FILE" "$R30_HEADING" \
  "2 件以上なら live に触れず中断する" \
  "R3-0: 既に分裂している場合は live を消さず中断する"
section_contains "$REFINE_FILE" "$R30_HEADING" \
  "保全検証は「存在（≥1）」ではなく「一意（=1）」で行う" \
  "R3-0: 保全検証が存在ではなく一意で書かれている"
section_contains "$REFINE_FILE" "$R30_HEADING" \
  "ACE-490-2" \
  "R3-0: 同型を記録した知見（ACE-490-2）への参照"
section_contains "$REFINE_OPERATIONS_FILE" "$R3A_HEADING" \
  "保全済み（1 件）なら**原文を再コピーせず**" \
  "R3-a: 保全済みなら既存ブロックへ Archived 注記を追記する"
section_contains "$REFINE_OPERATIONS_FILE" "$R3A_HEADING" \
  "**ちょうど 1 件**あることを確認してから live 側を削除する" \
  "R3-a: 保全検証が一意（=1）で書かれている"
section_contains "$REFINE_OPERATIONS_FILE" "$R3B_HEADING" \
  "保全済みなら原文を再コピーせず、既存ブロックへ今回の \`> Compacted:\` 行だけを追記する" \
  "R3-b: 保全済みなら既存ブロックへ Compacted 注記を追記する"
section_contains "$REFINE_OPERATIONS_FILE" "$R3B_HEADING" \
  "**ちょうど 1 件**であることを確認してから live 側を書き換える" \
  "R3-b: 保全検証が一意（=1）で書かれている"
section_contains "$REFINE_OPERATIONS_FILE" "$R3C_HEADING" \
  "既存の archive レコードへ \`> Merged into:\` を追記して \`Status\` を \`merged\` に変える" \
  "R3-c: 保全済みなら既存レコードへ Merged into 追記と Status=merged を行う"
section_contains "$REFINE_OPERATIONS_FILE" "$R3C_HEADING" \
  "0 件でも 2 件以上でも live 側に触れず中断する" \
  "R3-c: 保全検証が一意（=1）で書かれている"
section_contains "$REFINE_FILE" "$R3E_HEADING" \
  "見出しが**ちょうど 1 件**（存在ではなく一意）" \
  "R3-e: 一括検証が一意性で書かれている"
section_contains "$REFINE_FILE" "$HARD_RULES_HEADING" \
  "archive へ追記する前に既存出現数を数え、保全済み ID には原文を再コピーしない" \
  "ハードルール: 保全済み ID への再コピー禁止"

echo
echo "== ace-curate 書き込み時ゲート =="

contains "$CURATE_FILE" \
  "一回性のインシデント叙述は Playbook に書かない" \
  "インシデント叙述の記録先分離（TROUBLESHOOTING/runbook）"

# 追記前の超過予測（OBS 由来）。curate は増やす操作しか持たないのに、増やした結果がブロック
# ゲートに当たりうる — 自分が壊した状態を自分では直せない。針は**節スコープ**で張る
# （全文 grep だと、注意事項へ写して停止点としての位置を失っても緑になる）。
CURATE_PREDICT_SECTION="#### 4-b-0. 追記前にブロック上限の超過を予測する（必須・停止点）"
CURATE_APPEND_SECTION="#### 4-b. playbook/category.md への追記 + PLAYBOOK.md 索引の更新"
# 節スコープの針は「その節に在ること」しか見ないので、**見出しごと**追記手順の後ろへ動かす変異は
# 全件緑のまま通る（レビュー実測）。停止点の本体は「追記より前に在ること」なので、節の前後関係
# そのものを検査する。見出しの一致本数まで見るのは、複製で順序検査を骨抜きにさせないため。
CURATE_ORDER_REPORT="$(awk -v predict="$CURATE_PREDICT_SECTION" -v append="$CURATE_APPEND_SECTION" '
  index($0, predict) == 1 { p_n++; if (p_line == 0) p_line = NR }
  index($0, append)  == 1 { a_n++; if (a_line == 0) a_line = NR }
  END { printf "%d %d %d %d", p_n + 0, p_line + 0, a_n + 0, a_line + 0 }
' "$CURATE_FILE")"
# 位置パラメータ（set --）へ流さない。suite の後段が "$@" を読む形へ変わったときに、
# ここで上書きした値を拾う遠隔の壊れ方になるため。
IFS=' ' read -r PREDICT_N PREDICT_LINE APPEND_N APPEND_LINE <<< "$CURATE_ORDER_REPORT"
if [ "$PREDICT_N" -ne 1 ] || [ "$APPEND_N" -ne 1 ]; then
  bad "追記前予測/追記の見出しが 1 本ずつでない（予測 ${PREDICT_N} 本 / 追記 ${APPEND_N} 本）— 順序検査が成立しない"
elif [ "$PREDICT_LINE" -ge "$APPEND_LINE" ]; then
  bad "追記前予測の節が追記手順より後ろにある（予測 L${PREDICT_LINE} / 追記 L${APPEND_LINE}）— 追記してから気づく形へ戻っている"
else
  ok "追記前予測の節が 4-b の追記手順より前に置かれている（停止点の位置）"
fi
section_contains "$CURATE_FILE" "$CURATE_PREDICT_SECTION" \
  "超える前に止める" \
  "超えてから直すのではなく超える前に止める、という方針"
# 「上限以上なら」という**条件**だけを固定すると、後続を「追記したうえでフォローアップに記録する」
# へ書き換えても緑で通る（レビュー実測。この skill が起票された事故そのものの挙動）。帰結の語だけを
# 別に張るのも効かない — 同じ語が上のフェンスの診断文にも在るため吸収される（本 suite で実測）。
# 条件と帰結を**同じ 1 文**として固定する。
# ゲートは `count > maxAllowed` で落ちる（件数 == 上限は緑）。「以上」で止めると 1 件早く
# 止まり、承認の往復を無駄に要求したうえで「何件超えるか」が 0 件になる。
section_contains "$CURATE_FILE" "$CURATE_PREDICT_SECTION" \
  "ブロック上限を超えるなら追記せず、その時点で停止する" \
  "上限を超える回は追記せず停止する（条件と帰結を 1 本の針で固定する）"
section_contains "$CURATE_FILE" "$CURATE_PREDICT_SECTION" \
  "「フォローアップとして記録した」で完了にしない" \
  "ゲートの赤をフォローアップ記録へ振り替えて完了にしない"
section_contains "$CURATE_FILE" "$CURATE_PREDICT_SECTION" \
  "先に必要な refine の範囲" \
  "停止時に refine の範囲を名指しする（ユーザーの往復を 1 回にする）"
section_contains "$CURATE_FILE" "$CURATE_PREDICT_SECTION" \
  "承認必須は正しく、変えない" \
  "refine の 3 フェーズ承認契約を壊さないことの明記"
section_contains "$CURATE_FILE" "$CURATE_PREDICT_SECTION" \
  "閾値も件数の数え方も二重に持たない" \
  "判定は check-category-size の出力を読むだけ（閾値を二重に持たない）"
# fail-open の 2 経路。(1) rc を捨てると「既に超過」も「runner 不在」も素通りする。
# (2) 上限を警告行から読むと、refine 目安以下のカテゴリでは読む対象が存在せず、
#     読めなかった回が「超過なし」に化ける。
section_contains "$CURATE_FILE" "$CURATE_PREDICT_SECTION" \
  'rc を `|| true` で捨てない' \
  "rc 1 / 2 / 3 を握り潰さない（判定が行われなかった回を通さない）"
section_contains "$CURATE_FILE" "$CURATE_PREDICT_SECTION" \
  "読めなかった回が「超過なし」に化ける" \
  "警告行を上限の取得元にすると fail-open になることの明記"
section_contains "$CURATE_FILE" "$CURATE_PREDICT_SECTION" \
  "ブロック上限: <N> 件/カテゴリ" \
  "常に出る 1 行から上限を読む（警告行に依存しない）"

# ここまでの針はすべて**散文**に当たる。散文を残したまま fence の `case` を丸ごと
# `printf '%s\n' "${SIZE_OUT}" || true` へ差し替える変異は、全件緑のまま通った（レビューで実測）。
# 実行される側（fence 本体）にも針を張り、握り潰しの形が入っていないことを否定側から確かめる。
CURATE_PREDICT_BODY=""
if ! CURATE_PREDICT_BODY="$(section_scope_extract "$CURATE_FILE" "$CURATE_PREDICT_SECTION")"; then
  bad "追記前予測の節を切り出せない — fence の検査が成立しない: $CURATE_PREDICT_BODY"
else
  CURATE_PREDICT_FENCE="$(printf '%s\n' "$CURATE_PREDICT_BODY" | awk '
    /^```/ { in_fence = !in_fence; next }
    in_fence { print }
  ')"
  if [ -z "$CURATE_PREDICT_FENCE" ]; then
    bad "追記前予測の節に実行可能な fence が無い（散文だけでは手順が実行されない）"
  else
    fence_has() {
      case "$CURATE_PREDICT_FENCE" in
        *"$1"*) ok "$2" ;;
        *) bad "${2} — fence に '$1' がありません" ;;
      esac
    }
    fence_has 'SIZE_RC=$?' "fence が check-category-size の終了コードを捕まえている"
    fence_has 'case "${SIZE_RC}" in' "fence が終了コードで分岐している"
    fence_has '  1) printf' "fence が rc 1（既に超過）で停止する分岐を持つ"
    fence_has '  *) printf' "fence が rc 1 以外の非 0（判定不成立）を捕まえる catch-all を持つ"
    # プロジェクト側の実体があればそれを使う（4-f と同じ順）。同梱固定だと、プロジェクトが
    # 閾値を環境変数で変えている場合に予測だけが既定値を読む別方向の fail-open になる。
    fence_has 'if [ -f scripts/ace/check-category-size.ts ]; then' \
      "fence が実体をプロジェクト側 → 同梱の順で選ぶ（閾値の上書きを取りこぼさない）"
    case "$CURATE_PREDICT_FENCE" in
      *"|| true"*|*"|| :"*)
        bad "fence が check-category-size の rc を握り潰している（|| true / || : が在る）" ;;
      *) ok "fence に rc の握り潰し（|| true / || :）が無い" ;;
    esac
  fi
fi

CURATE_REPORT_SECTION="#### 4-g. 完了報告の契約（機械的検証が非 0 なら「停止」）"
section_contains "$CURATE_FILE" "$CURATE_REPORT_SECTION" \
  "非 0 を返したまま「完了」と報告しない" \
  "非 0 を残したまま完了と報告しない契約"
section_contains "$CURATE_FILE" "$CURATE_REPORT_SECTION" \
  "報告は**停止**であり" \
  "非 0 が残る回は完了ではなく停止として報告する"
section_contains "$CURATE_FILE" "$CURATE_REPORT_SECTION" \
  "live-ace-gates" \
  "どの default ブランチのゲートが赤になるかを名指しする"
# 列挙した検証の出所が実体と一致していること。4-e / 4-f は件数を見ないので、
# カテゴリ件数の出所は 4-b-0 でなければならない（かつて 4-e / 4-f と書いていた）。
section_contains "$CURATE_FILE" "$CURATE_REPORT_SECTION" \
  "4-b-0 / 4-f の機械的検証" \
  "報告契約が参照する検証の出所が実体（件数は 4-b-0）と一致している"
# 4-e の行数バジェットは警告しか出さず終了コードを動かさないので、「非 0 が無い＝完了」の
# 根拠に使えない。列挙へ戻すと、15 行超のエントリが「全ゲート 0」を満たしてしまう。
section_contains "$CURATE_FILE" "$CURATE_REPORT_SECTION" \
  "4-e（行数バジェット）はこの列挙に入れない" \
  "非 0 を返さない 4-e を機械的検証の列挙に混ぜない"
contains "$CURATE_RULES" \
  "行数バジェット自己チェック（必須・ブロッキング）" \
  "15 行バジェットの自己チェック"
contains "$CURATE_FILE" \
  "ace-line-budget-exception" \
  "行数バジェット例外マーカーの案内"
contains "$CURATE_FILE" \
  "索引行はタイトルのみ" \
  "索引タイトルのみルール"
contains "$CURATE_RULES" \
  "既存エントリの要約・アーカイブ・統合は \`/ace-refine\` のみが行う" \
  "refine 専権の明示（curate は grow 専用）"
contains "$CURATE_FILE" \
  "| Helpful | 0 | Harmful | 0 |" \
  "コンパクト正準フォーマットのカウンター行（スクリプト互換の行頭パイプ）"
contains "$CURATE_RULES" \
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
# 統合先（archive の `> Merged into:` の着地先）を Archive 候補として出すと、承認 →
# 適用 → check-refine-invariants が exit 1 → 巻き戻し、の手戻りになる（Issue #917）。
# 除外は黙って落とすのではなく理由付きの別枠にする、という設計まで固定する。
contains "$REFINE_REPORT_SCRIPT" \
  "## Archive 候補から除外（他エントリの統合先、" \
  "ace-refine-report が統合先を理由付きの別枠へ回す"
contains "$REFINE_REPORT_SCRIPT" \
  "Merged into:" \
  "ace-refine-report が archive の Merged into を統合先の判定源にしている"
contains "$REFINE_FILE" \
  "除外枠は R3-a の対象にしない" \
  "SKILL.md R1: 統合先の除外枠を R3-a の対象にしない案内"

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
contains "$CURATE_RULES" \
  "新規 ID を足して通すことはしない" \
  "curate 側: allowlist を抜け道にしない"
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
      "$ESBUILD_BIN" "$PLUGIN_ROOT/docs-template/scripts/ace/ace-domain.ts" --platform=node --format=esm \
        --log-level=error --outfile="$BUNDLE_DIR/ace-domain"
      "$ESBUILD_BIN" "$FORMAT_GATE_SCRIPT" --platform=node --format=esm \
        --log-level=error --outfile="$BUNDLE_PATH"
    2>&1)"
    BUILD_RC=$?
    if [ "$BUILD_RC" -eq 0 ]; then
      # 追記前予測（4-b-0）が読む「ブロック上限:」行が、**警告が 1 件も出ない回でも**出ること。
      # 上限は長らく refine 目安を超えたカテゴリの警告行にしか現れず、目安以下のカテゴリへ
      # 追記する回は読む対象が存在しなかった（読めなかった回が「超過なし」に化ける fail-open。
      # 本 suite のレビューで実測）。SKILL.md の文言検査ではこの不一致は見えないので、実出力で固定する。
      LIMIT_FIXTURE_DIR="$BUNDLE_DIR/limit-fixture"
      mkdir "$LIMIT_FIXTURE_DIR"
      {
        printf '%s\n' '---'
        printf '%s\n' 'version: 1.0.0'
        printf '%s\n' 'ace_entry_count: 1'
        printf '%s\n' '---'
        printf '\n%s\n\n' '# Playbook'
        printf '%s%s\n\n' '<a id=' '"ace-1-1"></a>'
        printf '%s%s\n\n' '### ' 'ACE-1-1: サンプル'
        printf '%s\n' '| Category | coding | Origin | ローカル fixture |'
        printf '%s\n' '| Date | 2026-09-13 |'
        printf '%s\n' '| Helpful | 0 | Harmful | 0 |'
        printf '%s\n\n' '| Status | active |'
        printf '%s\n\n' '本文。'
        printf '%s\n' '---'
      } > "$LIMIT_FIXTURE_DIR/PLAYBOOK.md"
      LIMIT_OUT="$(node "$BUNDLE_DIR/check-category-size" "$LIMIT_FIXTURE_DIR/PLAYBOOK.md" 2>&1)"
      LIMIT_RC=$?
      # 閾値の実値はここに書かない（二重に持つと本体の既定値を変えたとき静かにずれる）。
      # 見るのは「警告が出ていない回（= 読む対象が警告行に無い回）に、上限の行が出ること」。
      LIMIT_LINE_OK="$(printf '%s\n' "$LIMIT_OUT" | awk '
        /^ブロック上限: [0-9]+ 件\/カテゴリ（refine 目安: [0-9]+ 件\/カテゴリ）$/ { found = 1 }
        /refine 目安を超えています/ { warned = 1 }
        END { print (found && !warned) ? "ok" : ((warned) ? "warned" : "missing") }
      ')"
      if [ "$LIMIT_RC" -ne 0 ]; then
        bad "check-category-size が目安以下の fixture で非 0（rc=${LIMIT_RC}）: $LIMIT_OUT"
      elif [ "$LIMIT_LINE_OK" = "warned" ]; then
        bad "ブロック上限行の検査 fixture が refine 目安を超えている（検査が「警告が出ない回」を測れていない）"
      elif [ "$LIMIT_LINE_OK" != "ok" ]; then
        bad "警告が出ない回に「ブロック上限: <N> 件/カテゴリ（refine 目安: <M> 件/カテゴリ）」行が出ない — 4-b-0 の予測が読む対象を失う（fail-open）: $LIMIT_OUT"
      else
        ok "check-category-size が警告の有無に関わらずブロック上限を 1 行で出す（4-b-0 が読む対象）"
      fi
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
