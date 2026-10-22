#!/usr/bin/env bash
# Sourced by verify.sh after the triage section. M section: build-dedupe-eval-sets.ts / N section: review-dedupe.sh and
# the multi-review entry fence (fake curl only, no real review data).
echo "== M. 重複 finding の評価セット生成器（build-dedupe-eval-sets.ts。合成 .review-results）=="
DD_GEN="$PLUGIN_ROOT/scripts/jev/build-dedupe-eval-sets.ts"
DD_Q="$PLUGIN_ROOT/scripts/jev/questions/dedupe.json"
DD_REPORT_BODY="$PLUGIN_ROOT/scripts/lib/multi-agent-report-body.sh"
for f in "$DD_GEN" "$DD_Q" "$DD_REPORT_BODY"; do
  [ -r "$f" ] || { bad "M target missing: $f"; return 1; }
done
gend() { # $@=引数。stdout→${OUT} rc→${RC}（stderr は ${ERR}）
  OUT="$(FF_DEV_TOOLKIT_ROOT="$PLUGIN_ROOT" bash "$RUNNER" "$DD_GEN" "$@" 2>"$WORK/gend.err")"; RC=$?
  ERR="$(cat "$WORK/gend.err")"
}
dd_tsv() { # $1=出力先、残り=行（\t を含む printf %b の書式）。1 行目は契約どおりのヘッダ
  local f="$1"; shift
  mkdir -p "$(dirname "$f")" || return 1
  { printf 'cli\tperspective\tseverity\tfailure_scenario\tconfidence\tfile\tline\tsummary\tdemoted_from\n'
    for r in "$@"; do printf '%b\n' "$r"; done; } > "$f"
}
dd_report() { # $1=run ディレクトリ、残り=節を持つレーン（cli:perspective）
  local d="$1"; shift
  mkdir -p "$d" || return 1
  { printf '# Multi-CLI Review — Integrated Report\n\n'
    for l in "$@"; do printf '## %s — %s [premium]\n\n本文\n\n' "${l%%:*}" "${l#*:}"; done; } > "$d/integrated-report.md"
}
dd_run1() { # 合成 run（3 レーン・3 書式）。$1=.review-results ディレクトリ
  local R="$1"
  dd_report "$R" claude-code:code-review claude-code:test-analysis codex-cli:comprehensive-review
  # code-review: 判定行が親の箇条書きの子に置かれ、理由が判定行の後ろへ続く書式
  dd_tsv "$R/claude-code/code-review.findings.tsv" \
    'claude-code\tcode-review\twarning\tyes\t85\tsrc/a.ts\t10\t[src/a.ts:10] **null 要素で一覧が 500 になる**\t' \
    'claude-code\tcode-review\tsuggestion\tno\t60\tsrc/a.ts\t40\t[src/a.ts:40] **ログが出ない**\t' \
    'claude-code\tcode-review\tsuggestion\tno\t55\tsrc/b.ts\t5\t[src/b.ts:5] **名前が曖昧**\t'
  cat > "$R/claude-code/code-review.md" <<'MD'
<!-- Multi-CLI Review Result -->
## Code Review Results

### Important Issues
- [src/a.ts:10] **null 要素で一覧が 500 になる**
  - verdict: severity=warning failure_scenario=yes confidence=85 file=src/a.ts line=10
  - 理由: rechecks の要素を検査していない。
  - 修正提案: 要素で絞る。
- [src/a.ts:40] **ログが出ない**
  - verdict: severity=suggestion failure_scenario=no confidence=60 file=src/a.ts line=40
  - 理由: catch で握り潰す。

### Suggestions
- [src/b.ts:5] **名前が曖昧**
  - verdict: severity=suggestion failure_scenario=no confidence=55 file=src/b.ts line=5
MD
  # test-analysis: #### 見出しから判定行（0 桁目）までが 1 件。行の無い finding は対に入れない
  dd_tsv "$R/claude-code/test-analysis.findings.tsv" \
    'claude-code\ttest-analysis\tsuggestion\tno\t65\tsrc/a.ts\t12\t**優先度:** 5\t' \
    'claude-code\ttest-analysis\tsuggestion\tno\t50\tsrc/a.ts\t\t本文。\t'
  cat > "$R/claude-code/test-analysis.md" <<'MD'
## Test Analysis

#### 一覧の null 要素
**ファイル:** src/a.ts
**テストされていない動作:** rechecks に null があると 500。
**優先度:** 5
- verdict: severity=suggestion failure_scenario=no confidence=65 file=src/a.ts line=12

#### 行の無い指摘
**ファイル:** src/a.ts
本文。
- verdict: severity=suggestion failure_scenario=no confidence=50 file=src/a.ts
MD
  # codex: 判定行が指摘と同じ深さ。.md は降格前（critical）、TSV は降格後（warning + demoted_from）
  dd_tsv "$R/codex-cli/comprehensive-review.findings.tsv" \
    'codex-cli\tcomprehensive-review\twarning\tno\t99\tsrc/a.ts\t11\t**一覧全体が失敗する**（`src/a.ts:11`）\tcritical' \
    'codex-cli\tcomprehensive-review\tsuggestion\tno\t90\tsrc/a.ts\t30\t**遠い行**（`src/a.ts:30`）\t'
  cat > "$R/codex-cli/comprehensive-review.md" <<'MD'
## 総合レビュー

### Warning

- **一覧全体が失敗する**（`src/a.ts:11`）
  null 要素で例外になる。
- verdict: severity=critical failure_scenario=no confidence=99 file=src/a.ts line=11

### Suggestion

- **遠い行**（`src/a.ts:30`）
  別の話。
- verdict: severity=suggestion failure_scenario=no confidence=90 file=src/a.ts line=30
MD
  # プラン外の退避（<cli>/previous/）は読まない — 読めばヘッダ違反で exit 2 になる
  mkdir -p "$R/claude-code/previous" && printf 'cli\tperspective\n' > "$R/claude-code/previous/code-review.findings.tsv"
  mkdir -p "$R/.resume-cache/abc"
}
DDS="$WORK/dd/scan"
dd_run1 "$DDS/repo1/.review-results" || bad "M fixture R1"
# .prev の入れ子 run: claude-code のレーンが報告に無い（プラン外の古い結果）→ mixed
DD_PREV="$DDS/repo1/.review-results/.prev-20260101T000000Z"
dd_report "$DD_PREV" codex-cli:comprehensive-review
dd_tsv "$DD_PREV/claude-code/code-review.findings.tsv" 'claude-code\tcode-review\tsuggestion\tno\t70\tsrc/c.ts\t7\t[src/c.ts:7] **古い指摘**\t'
printf '### Suggestions\n- [src/c.ts:7] **古い指摘**\n  - verdict: severity=suggestion failure_scenario=no confidence=70 file=src/c.ts line=7\n' > "$DD_PREV/claude-code/code-review.md"
dd_tsv "$DD_PREV/codex-cli/comprehensive-review.findings.tsv" 'codex-cli\tcomprehensive-review\tsuggestion\tno\t80\tsrc/c.ts\t8\t**新しい指摘**\t'
printf '### Suggestion\n\n- **新しい指摘**\n  本文。\n- verdict: severity=suggestion failure_scenario=no confidence=80 file=src/c.ts line=8\n' > "$DD_PREV/codex-cli/comprehensive-review.md"
# worktree のコピー（同じ対は内容ハッシュで 1 件に畳む）と、node_modules 配下（辿らない — 読めばヘッダ違反で exit 2）
dd_run1 "$DDS/repo1/.claude/worktrees/copy/.review-results" || bad "M fixture copy"
mkdir -p "$DDS/repo1/node_modules/x/.review-results/claude-code" && printf 'bad\n' > "$DDS/repo1/node_modules/x/.review-results/claude-code/code-review.findings.tsv"

gend --scan "$DDS" --out "$WORK/dd/o1"
if [ "$RC" -eq 3 ]; then
  echo "  ○ skip: tsx ランナーを起動できないため M 節を実行していません（${ERR}）"
  return 0
fi
DD_LINE='runs=3 multi_lane_runs=3 findings=16 pairs=4 cross_cli=3 same_cli=1 same_report=3 mixed=1 source_runs=1 unrecovered=0 duplicates=3 skipped_dirs=0 max_line_delta=5'
[ "$RC" -eq 0 ] && [ "$OUT" = "$DD_LINE" ] \
  && ok "M1 合成 run 3 件（3 レーン + .prev の入れ子 + worktree コピー）: 対 4（cross 3 / same 1）、mixed 1、コピー 3 対を畳み、previous / node_modules / 行の無い finding / 行差 > 5 は対にしない" \
  || bad "M1 rc=$RC out=$OUT err=$ERR"
C1="$WORK/dd/o1/dedupe-candidates.jsonl"
dd_state() { jq -rs --arg loc "$1" '[.[] | .state.finding_a, .state.finding_b | select(startswith($loc + "\n"))][0] // ""' "$C1"; }
S10="$(dd_state src/a.ts:10)"; S11="$(dd_state src/a.ts:11)"; S12="$(dd_state src/a.ts:12)"
case "$S10" in *'理由: rechecks の要素を検査していない。'*) m2a=1 ;; *) m2a=0 ;; esac
case "$S10" in *'ログが出ない'*|*'verdict:'*|*'### '*) m2b=0 ;; *) m2b=1 ;; esac
[ "$m2a" -eq 1 ] && [ "$m2b" -eq 1 ] \
  && ok "M2 親の箇条書きの書式は、判定行の後ろの理由まで本文に含め、次の指摘・判定行・節見出しは含めない" \
  || bad "M2 code-review の本文: $S10"
case "$S11" in *'null 要素で例外になる。'*) m3a=1 ;; *) m3a=0 ;; esac
case "$S11" in *'### Warning'*|*'verdict:'*) m3b=0 ;; *) m3b=1 ;; esac
[ "$m3a" -eq 1 ] && [ "$m3b" -eq 1 ] \
  && ok "M3 判定行が同じ深さの書式は直前の見出しから復元し、降格前の重大度（demoted_from）で .md と照合する。節見出しは除く" \
  || bad "M3 codex の本文: $S11"
case "$S12" in *'#### 一覧の null 要素'*'**優先度:** 5'*) ok "M4 #### 見出しの書式は見出しから判定行の手前までを本文にする（指摘の見出しは残す）" ;; *) bad "M4 test-analysis の本文: $S12" ;; esac
jq -e -s 'map(select(.validity=="same-report")) | length==3 and all(.[]; (.lanes|length)==2 and (.lanes[0] != .lanes[1]) and (.id|test("^dd-[0-9a-f]{16}$")))' "$C1" >/dev/null 2>&1 \
  && jq -e -s 'map(select(.validity=="mixed")) | length==1 and .[0].stratum=="cross-cli" and .[0].delta==1' "$C1" >/dev/null 2>&1 \
  && ok "M5 候補は ID（内容ハッシュ）・別レーン 2 つ・層・有効性・行差を持つ" || bad "M5 候補の形: $(head -c 300 "$C1")"
gend --scan "$DDS" --out "$WORK/dd/o2"
cmp -s "$C1" "$WORK/dd/o2/dedupe-candidates.jsonl" && ok "M6 同じ入力なら候補はバイト同一" || bad "M6 生成が決定的でない"
# 各指摘の参照（<cli>/<観点>.md:<行番号>）は、その指摘の判定行そのものを指す
dd_refs_ok=1; dd_refs_n=0
while IFS='|' read -r dd_run dd_ref dd_loc; do
  dd_refs_n=$((dd_refs_n + 1))
  dd_line="$(sed -n "${dd_ref##*:}p" "$dd_run/${dd_ref%:*}")"
  case "$dd_line" in *verdict:*"file=${dd_loc%:*} line=${dd_loc##*:}"*) ;; *) dd_refs_ok=0 ;; esac
done < <(jq -r '.run as $r | [[.refs[0], (.state.finding_a|split("\n")[0])], [.refs[1], (.state.finding_b|split("\n")[0])]][] | $r + "|" + .[0] + "|" + .[1]' "$C1")
[ "$dd_refs_n" -eq 8 ] && [ "$dd_refs_ok" -eq 1 ] && ok "M6b 候補の refs は各指摘の判定行（<cli>/<観点>.md:<行番号>）を指す（畳む指示で同じ題名の別の指摘を取り違えない）" || bad "M6b refs n=$dd_refs_n ok=$dd_refs_ok"
# 判定行が指摘と同じ深さの書式で、判定行の後ろへ書かれた前の指摘の理由を次の指摘へ混ぜない
DD_BND="$WORK/dd/bnd/r/.review-results"
dd_report "$DD_BND" codex-cli:comprehensive-review claude-code:code-review
dd_tsv "$DD_BND/codex-cli/comprehensive-review.findings.tsv" \
  'codex-cli\tcomprehensive-review\tsuggestion\tno\t90\tsrc/e.ts\t1\t**A の指摘**\t' \
  'codex-cli\tcomprehensive-review\tsuggestion\tno\t91\tsrc/e.ts\t20\t**B の指摘**\t'
printf '### Suggestion\n\n- **A の指摘**\n- verdict: severity=suggestion failure_scenario=no confidence=90 file=src/e.ts line=1\n  A の理由（判定行の後ろ）。\n- **B の指摘**\n  B の本文。\n- verdict: severity=suggestion failure_scenario=no confidence=91 file=src/e.ts line=20\n' > "$DD_BND/codex-cli/comprehensive-review.md"
dd_tsv "$DD_BND/claude-code/code-review.findings.tsv" 'claude-code\tcode-review\tsuggestion\tno\t60\tsrc/e.ts\t21\t[src/e.ts:21] **B と同じ話**\t'
printf '### Suggestions\n- [src/e.ts:21] **B と同じ話**\n  - verdict: severity=suggestion failure_scenario=no confidence=60 file=src/e.ts line=21\n' > "$DD_BND/claude-code/code-review.md"
gend --scan "$WORK/dd/bnd" --out "$WORK/dd/o-bnd"
DD_SB="$(jq -rs '[.[] | .state.finding_a, .state.finding_b | select(startswith("src/e.ts:20\n"))][0] // ""' "$WORK/dd/o-bnd/dedupe-candidates.jsonl" 2>/dev/null)"
[ "$RC" -eq 0 ] && [[ "$DD_SB" == *'B の本文。'* ]] && [[ "$DD_SB" != *'A の理由'* ]] \
  && ok "M6c 判定行の後ろへ書かれた前の指摘の理由（より深い字下げ）は次の指摘の本文へ混ぜない" || bad "M6c rc=$RC state=$DD_SB"
gend --scan "$DDS" --out "$WORK/dd/o3" --max-line-delta 1
[ "$RC" -eq 0 ] && [[ "$OUT" == *' pairs=3 '* ]] && ok "M7 --max-line-delta 1 は行差 2 の対を落とす" || bad "M7 rc=$RC out=$OUT"
# 生成器の TSV ヘッダは記録側（multi-agent-report-body.sh の REVIEW_FINDINGS_TSV_HEADER）と同一
DD_HDR="$(eval "$(/usr/bin/grep '^REVIEW_FINDINGS_TSV_HEADER=' "$DD_REPORT_BODY")"; printf '%s' "$REVIEW_FINDINGS_TSV_HEADER")"
DD_HDR_TS="${DD_HDR//$'\t'/\\t}"
if [ -n "$DD_HDR" ] && grep -qF -- "export const TSV_HEADER = \"$DD_HDR_TS\";" "$DD_GEN"; then
  ok "M8 生成器の TSV_HEADER は記録側の REVIEW_FINDINGS_TSV_HEADER と同一（列を足した記録側の変更を見落とさない）"
else bad "M8 TSV ヘッダが記録側と食い違う: [$DD_HDR]"; fi
# same-report の判定は記録側の節見出し（multi-agent-report-body.sh の echo 行）と生成器の REPORT_SECTION の結合に依る
if grep -qF 'echo "## ${cli_name} — ${perspective_name} [${tier}]"' "$DD_REPORT_BODY" \
   && grep -qF 'const REPORT_SECTION = /^## ([A-Za-z0-9._-]+) — ([A-Za-z0-9._-]+)(?:\s|$)/u;' "$DD_GEN"; then
  ok "M8b 記録側の節見出し（## <cli> — <観点> [<tier>]）と生成器の REPORT_SECTION が同じ書式（見出しが変わって全対が mixed になる drift を見落とさない）"
else bad "M8b 記録側の節見出しと生成器の REPORT_SECTION が食い違う"; fi
# 同じ対のコピーのうち、報告の節を欠くコピーが辞書順で先に来ても same-report 側を残す
dd_run1 "$WORK/dd/dup/a-copy/.review-results" && rm -f "$WORK/dd/dup/a-copy/.review-results/integrated-report.md"
dd_run1 "$WORK/dd/dup/b-main/.review-results"
gend --scan "$WORK/dd/dup" --out "$WORK/dd/o-dup"
[ "$RC" -eq 0 ] && [[ "$OUT" == *' pairs=3 '* ]] && [[ "$OUT" == *' same_report=3 mixed=0 '* ]] && [[ "$OUT" == *' duplicates=3 '* ]] \
  && ok "M8c 報告の節を欠くコピーが先に来ても、同じ対の same-report 側を残す（有効な評価候補を黙って消さない）" || bad "M8c rc=$RC out=$OUT"
# <cli>/ の直下に TSV が無く previous/ にだけ前回の TSV が残った回でも、previous を cli 名として読まない
dd_run1 "$WORK/dd/prevonly/r/.review-results"
dd_tsv "$WORK/dd/prevonly/r/.review-results/grok-cli/previous/code-review.findings.tsv" 'grok-cli\tcode-review\tsuggestion\tno\t50\tsrc/a.ts\t10\tx\t'
gend --scan "$WORK/dd/prevonly" --out "$WORK/dd/o-prevonly"
[ "$RC" -eq 0 ] && [[ "$OUT" == 'runs=1 '* ]] && [[ "$OUT" == *' pairs=3 '* ]] \
  && ok "M8d previous/ にだけ TSV が残ったレーンは辿らない（cli 名 previous として読んで走査全体を止めない）" || bad "M8d rc=$RC out=$OUT err=$ERR"

# ラベル: ID → 真偽値（多数決と一致する票）。same-report の対ぜんぶに要る
VALID_IDS="$(jq -r 'select(.validity=="same-report") | .id' "$C1")"
jq -n --arg ids "$VALID_IDS" '{_meta:{note:"synthetic"}} + ($ids | split("\n") | map(select(. != "")) | to_entries | map({key:.value, value:(if .key==0 then {same:false,votes:[false,false,true]} else {same:true,votes:[true,true,true]} end)}) | from_entries)' > "$WORK/dd/labels.json"
gend --scan "$DDS" --out "$WORK/dd/o4" --labels "$WORK/dd/labels.json"
if [ "$RC" -eq 0 ] && [[ "$OUT" == *' labeled=3 labels_unused=0'* ]] \
   && jq -e -s 'length==3 and all(.[]; (.group|test("^(cross-cli|same-cli)/(unanimous|majority)/(same|different)$")) and (.expected.same_defect|type)=="boolean" and (.state.finding_a|type)=="string") and (map(select(.group|endswith("/majority/different")))|length)==1' "$WORK/dd/o4/dedupe.jsonl" >/dev/null 2>&1; then
  ok "M9 --labels: same-report の 3 対を評価セットへ出し、group に層・票の一致・ラベルを載せる（mixed は出さない）"
else bad "M9 rc=$RC out=$OUT err=$ERR"; fi
# 質問 fixture は生成器が実際に出した質問と完全一致（ADR-059 決定 6）
if [ -s "$WORK/dd/o4/dedupe.jsonl" ] && [ "$(head -n 1 "$WORK/dd/o4/dedupe.jsonl" | jq -cS '.questions.same_defect')" = "$(jq -cS '.same_defect' "$DD_Q")" ] \
   && [ "$(jq -r 'keys|join(",")' "$DD_Q")" = "same_defect" ] && [ "$(jq -r '.same_defect.type' "$DD_Q")" = "noul" ]; then
  ok "M10 questions/dedupe.json は生成器の質問（noul same_defect）と完全一致"
else bad "M10 fixture と生成器の質問が食い違う"; fi
jq 'del(.[keys_unsorted[1]])' "$WORK/dd/labels.json" > "$WORK/dd/labels-missing.json"
gend --scan "$DDS" --out "$WORK/dd/o5" --labels "$WORK/dd/labels-missing.json"
[ "$RC" -eq 2 ] && [[ "$ERR" == *'ラベルがありません'* ]] && ok "M11 same-report の対にラベルが無ければ exit 2（小さなセットで成功にしない）" || bad "M11 rc=$RC err=$ERR"
printf '{"dd-XYZ":{"same":true}}\n' > "$WORK/dd/labels-badkey.json"
gend --scan "$DDS" --out "$WORK/dd/o6" --labels "$WORK/dd/labels-badkey.json"
[ "$RC" -eq 2 ] && [[ "$ERR" == *'dd-<16 桁の 16 進>'* ]] && ok "M12 ラベルの ID の形が違えば exit 2" || bad "M12 rc=$RC err=$ERR"
jq '(.[keys_unsorted[1]]) = {same:true,votes:[false,false,true]}' "$WORK/dd/labels.json" > "$WORK/dd/labels-vote.json"
gend --scan "$DDS" --out "$WORK/dd/o7" --labels "$WORK/dd/labels-vote.json"
[ "$RC" -eq 2 ] && [[ "$ERR" == *'多数決'* ]] && ok "M13 same が票の多数決と食い違えば exit 2" || bad "M13 rc=$RC err=$ERR"
# --candidates: ラベルを付けた時点の候補から作る（走査し直さない）。ID は state から計算し直す
gend --candidates "$C1" --labels "$WORK/dd/labels.json" --out "$WORK/dd/o-cand"
[ "$RC" -eq 0 ] && [ "$OUT" = 'candidates=4 same_report=3 labeled=3 labels_unused=0' ] && cmp -s "$WORK/dd/o-cand/dedupe.jsonl" "$WORK/dd/o4/dedupe.jsonl" \
  && ok "M13b --candidates は保存した候補から --scan --labels とバイト同一の評価セットを作る" || bad "M13b rc=$RC out=$OUT err=$ERR"
jq -c 'if .validity=="same-report" then .state.finding_a |= (. + "改変") else . end' "$C1" > "$WORK/dd/cand-tampered.jsonl"
gend --candidates "$WORK/dd/cand-tampered.jsonl" --labels "$WORK/dd/labels.json" --out "$WORK/dd/o-cand2"
[ "$RC" -eq 2 ] && [[ "$ERR" == *'内容ハッシュと一致しません'* ]] && ok "M13c 改変・切れた候補行（ID と state の不一致）は exit 2" || bad "M13c rc=$RC err=$ERR"
gend --candidates "$C1" --labels "$WORK/dd/labels.json" --out "$WORK/dd/o-cand3" --scan "$DDS"
[ "$RC" -eq 2 ] && [[ "$ERR" == *'併用できません'* ]] && ok "M13d --candidates と --scan の併用は exit 2" || bad "M13d rc=$RC err=$ERR"

# 判定不能は exit 2
mkdir -p "$WORK/dd/empty"
gend --scan "$WORK/dd/empty" --out "$WORK/dd/o8"
[ "$RC" -eq 2 ] && [[ "$ERR" == *'1 件もありません'* ]] && ok "M14 型付きレコードが 1 件も無ければ exit 2" || bad "M14 rc=$RC err=$ERR"
DD_HDIR="$WORK/dd/hdr/r/.review-results/claude-code"; mkdir -p "$DD_HDIR"
printf 'cli\tperspective\tseverity\tfailure_scenario\tconfidence\tfile\tline\tsummary\tdemoted_from\textra\n' > "$DD_HDIR/code-review.findings.tsv"
gend --scan "$WORK/dd/hdr" --out "$WORK/dd/o9"
[ "$RC" -eq 2 ] && [[ "$ERR" == *'ヘッダが契約と違います'* ]] && ok "M15 ヘッダに列が足された findings.tsv は exit 2" || bad "M15 rc=$RC err=$ERR"
dd_tsv "$WORK/dd/cols/r/.review-results/claude-code/code-review.findings.tsv" 'claude-code\tcode-review\tsuggestion'
gend --scan "$WORK/dd/cols" --out "$WORK/dd/o10"
[ "$RC" -eq 2 ] && [[ "$ERR" == *'9 列ではありません'* ]] && ok "M16 9 列でない行は exit 2" || bad "M16 rc=$RC err=$ERR"
dd_tsv "$WORK/dd/name/r/.review-results/claude-code/code-review.findings.tsv" 'codex-cli\tcode-review\tsuggestion\tno\t50\ta\t1\ts\t'
gend --scan "$WORK/dd/name" --out "$WORK/dd/o11"
[ "$RC" -eq 2 ] && [[ "$ERR" == *'置き場'* ]] && ok "M17 cli 列と置き場のディレクトリ名が違えば exit 2" || bad "M17 rc=$RC err=$ERR"
# 判定行の照合が割れて summary でも絞れない finding は推測で選ばず、対ごと捨てて数える（対が 0 件なら exit 2）
DD_AMB="$WORK/dd/amb/r/.review-results"
dd_report "$DD_AMB" claude-code:code-review codex-cli:comprehensive-review
dd_tsv "$DD_AMB/claude-code/code-review.findings.tsv" 'claude-code\tcode-review\tsuggestion\tno\t60\tsrc/d.ts\t3\tzzz\t'
printf '### Suggestions\n- 本文 1\n  - verdict: severity=suggestion failure_scenario=no confidence=60 file=src/d.ts line=3\n- 本文 2\n  - verdict: severity=suggestion failure_scenario=no confidence=60 file=src/d.ts line=3\n' > "$DD_AMB/claude-code/code-review.md"
dd_tsv "$DD_AMB/codex-cli/comprehensive-review.findings.tsv" 'codex-cli\tcomprehensive-review\tsuggestion\tno\t80\tsrc/d.ts\t4\t**x**\t'
printf '### Suggestion\n\n- **x**\n  本文。\n- verdict: severity=suggestion failure_scenario=no confidence=80 file=src/d.ts line=4\n' > "$DD_AMB/codex-cli/comprehensive-review.md"
gend --scan "$WORK/dd/amb" --out "$WORK/dd/o12"
[ "$RC" -eq 2 ] && [[ "$ERR" == *'本文を復元できない対 1'* ]] && ok "M18 本文の照合が一意に決まらない finding は推測で選ばず、対ごと捨てて数える（0 対なら exit 2）" || bad "M18 rc=$RC err=$ERR"
dd_tsv "$DD_AMB/claude-code/code-review.findings.tsv" 'claude-code\tcode-review\tsuggestion\tno\t60\tsrc/d.ts\t3\t本文 2\t'
gend --scan "$WORK/dd/amb" --out "$WORK/dd/o12b"
DD_S3="$(jq -rs '[.[] | .state.finding_a, .state.finding_b | select(startswith("src/d.ts:3\n"))][0] // ""' "$WORK/dd/o12b/dedupe-candidates.jsonl" 2>/dev/null)"
[ "$RC" -eq 0 ] && [[ "$OUT" == *' pairs=1 '* ]] && [[ "$DD_S3" == *'本文 2'* ]] && [[ "$DD_S3" != *'本文 1'* ]] \
  && ok "M18b 照合が割れても summary で 1 つに絞れれば、その本文で対を作る" || bad "M18b rc=$RC out=$OUT state=$DD_S3"
gend --scan "$DDS" --out "$WORK/dd/o13" --bogus x
[ "$RC" -eq 2 ] && [[ "$ERR" == *'未知のオプション'* ]] && ok "M19 未知のオプションは exit 2" || bad "M19 rc=$RC err=$ERR"
gend --scan "$DDS" --out "$WORK/dd/o14" --max-line-delta abc
[ "$RC" -eq 2 ] && [[ "$ERR" == *'非負整数'* ]] && ok "M20 --max-line-delta が非数なら exit 2" || bad "M20 rc=$RC err=$ERR"
printf 'x\n' > "$WORK/dd/notadir"
gend --scan "$DDS" --out "$WORK/dd/notadir/sub"
[ "$RC" -eq 2 ] && [[ "$ERR" == *'--out へ書けません'* ]] && ok "M21 --out へ書けなければ exit 2（rc=1 の例外で終わらせない）" || bad "M21 rc=$RC err=$ERR"
# 重大度（判断メモ）: 判定行・節見出し・重大度ラベルを state から除く
gend --scan "$DDS" --out "$WORK/dd/o15" --severity-sample 50
DD_SEVN="$(printf '%s\n' "$OUT" | sed -n 's/.* severity=\([0-9]*\)$/\1/p')"
if [ "$RC" -eq 0 ] && [ "${DD_SEVN:-0}" -ge 9 ] && [ "$(grep -c . "$WORK/dd/o15/severity.jsonl")" -eq "$DD_SEVN" ] \
   && jq -e -s 'all(.[]; .questions.severity.type=="choice" and (.questions.severity.criteria|has("none")) and (.state|test("verdict:|(^|\\n)#{1,3} |\\*\\*優先度")|not) and (.expected.severity as $s | ["critical","warning","suggestion","info"] | index($s) != null))' "$WORK/dd/o15/severity.jsonl" >/dev/null 2>&1 \
   && jq -e -s 'map(select(.state|test("一覧の null 要素"))) | length==1' "$WORK/dd/o15/severity.jsonl" >/dev/null 2>&1; then
  ok "M22 --severity-sample（件数以上なら全件）: Choice（none 付き）。優先度ラベルを持つ finding も含めて、state に判定行・節見出し・優先度ラベルを残さない"
else bad "M22 rc=$RC out=$OUT"; fi

# summarize: 事前登録した採否規則（Jev=同じ の採用対が 30 件以上かつ誤り 0 の最小の帯）
mk_dd_res() { # $1=件数 $2=group $3=expected $4=predicted $5=confidence
  local i=0
  while [ "$i" -lt "$1" ]; do
    jq -cn --arg id "dd-$i-$2" --arg g "$2" --argjson e "$3" --argjson p "$4" --argjson c "$5" '{id:$id,group:$g,answers:[{qid:"same_defect",type:"noul",expected:$e,predicted:$p,raw:0.9,match:($e==$p),confidence:$c}]}'
    i=$((i + 1))
  done
}
# 0.80 と 0.95 の両方が規則を満たす（最小の帯を採るので 0.80）。Jev=別 の誤り 2 件は採否に使わない
{ mk_dd_res 30 cross-cli/unanimous/same true true 0.85; mk_dd_res 30 cross-cli/unanimous/same true true 0.95
  mk_dd_res 1 same-cli/majority/different false true 0.75; mk_dd_res 2 same-cli/unanimous/same true false 0.85; } > "$WORK/dd/res.jsonl"
gend --summarize "$WORK/dd/res.jsonl" --kind dedupe
if [ "$RC" -eq 0 ] && grep -qxF 'DEDUPE_ADOPT_THRESHOLD=0.80' <<<"$OUT" && grep -qF '| 0.70 | 63 | 100.0% | 95.2% | 61 | 1 | 2 | 2 |' <<<"$OUT" \
   && grep -qF '| 0.80 | 62 | 98.4% | 96.8% | 60 | 0 | 2 | 2 |' <<<"$OUT" && grep -qF '| 0.99 | 0 | 0.0% | - | 0 | 0 | 0 | 0 |' <<<"$OUT"; then
  ok "M23 summarize dedupe: 帯別表（占有率・方向別の誤り）を出し、規則を満たす帯のうち最小の 0.80 を閾値にする（誤りを含む 0.70 は採らず、Jev=別 の誤りは採否に使わない）。0.99 帯も 0 件の行として残す"
else bad "M23 rc=$RC out=$OUT err=$ERR"; fi
mk_dd_res 29 cross-cli/unanimous/same true true 0.95 > "$WORK/dd/res29.jsonl"
gend --summarize "$WORK/dd/res29.jsonl" --kind dedupe
[ "$RC" -eq 0 ] && grep -qxF 'DEDUPE_ADOPT_THRESHOLD=none' <<<"$OUT" && ok "M24 採用対が 30 件に届かなければ閾値なし（不採用）" || bad "M24 rc=$RC out=$OUT"
printf '{"id":"a","group":"x","answers":[{"expected":true,"predicted":true,"confidence":0.9}]}\n' > "$WORK/dd/res-badgroup.jsonl"
gend --summarize "$WORK/dd/res-badgroup.jsonl" --kind dedupe
[ "$RC" -eq 2 ] && [[ "$ERR" == *'group'* ]] && ok "M25 group が <stratum>/<agreement>/<label> でない結果は exit 2" || bad "M25 rc=$RC err=$ERR"
printf '{"id":"a","group":"cross-cli/unanimous/same","answers":[{"expected":true,"predicted":true}]}\n' > "$WORK/dd/res-noconf.jsonl"
gend --summarize "$WORK/dd/res-noconf.jsonl" --kind dedupe
[ "$RC" -eq 2 ] && [[ "$ERR" == *'confidence'* ]] && ok "M26 confidence の無い結果行は帯から黙って落とさず exit 2" || bad "M26 rc=$RC err=$ERR"
printf '{"id":"a","group":"cross-cli/unanimous/different","answers":[{"expected":true,"predicted":true,"confidence":0.9}]}\n' > "$WORK/dd/res-mismatch.jsonl"
gend --summarize "$WORK/dd/res-mismatch.jsonl" --kind dedupe
[ "$RC" -eq 2 ] && [[ "$ERR" == *'group のラベルと一致しません'* ]] && ok "M27 expected と group のラベルが食い違う結果行は exit 2" || bad "M27 rc=$RC err=$ERR"
printf '{"id":"s","answers":[{"expected":"warning","predicted":"warning","confidence":0.995}]}\n{"id":"t","answers":[{"expected":"suggestion","predicted":"warning","confidence":0.5}]}\n' > "$WORK/dd/res-sev.jsonl"
gend --summarize "$WORK/dd/res-sev.jsonl" --kind severity
[ "$RC" -eq 0 ] && grep -qxF 'SEVERITY_BAND_099=1' <<<"$OUT" && grep -qF '| suggestion | 0 | 1 | 0 | 0 | 0 |' <<<"$OUT" \
  && ok "M28 summarize severity: 0.99 帯の件数と混同表を出す" || bad "M28 rc=$RC out=$OUT"
gend --summarize "$WORK/dd/res.jsonl" --kind other
[ "$RC" -eq 2 ] && ok "M29 --kind が dedupe | severity 以外は exit 2" || bad "M29 rc=$RC"

echo "== N. 判定点 dedupe の本番経路（scripts/jev/review-dedupe.sh と multi-review の入口フェンス）=="
DD_REVIEW="$PLUGIN_ROOT/scripts/jev/review-dedupe.sh"
DD_REF="$PLUGIN_ROOT/skills/multi-review/references/jev-dedupe.md"
DD_LOG="$WORK/dedupe-log.jsonl"
DD_RUN="$DDS/repo1/.review-results"
for f in "$DD_REVIEW" "$DD_REF"; do
  [ -r "$f" ] || { bad "N target missing: $f"; return 1; }
done
run_dedupe() { # $1..=環境（VAR=val）、-- の後がスクリプト引数。stdout→${OUT} stderr→${ERR} rc→${RC}
  local envs=()
  while [ $# -gt 0 ] && [ "$1" != "--" ]; do envs+=("$1"); shift; done
  [ "${1:-}" = "--" ] && shift
  OUT="$( env -i HOME="$ISO_HOME" PATH="$FAKE/bin:$PATH" TMPDIR="$WORK" FAKE_CURL_DIR="$FAKE" FF_ACE_TS_RUNNER=tsx \
        TYPESAFE_API_KEY=test-only FF_JEV_MAX_RETRIES=0 FF_JEV_DECISION_LOG="$DD_LOG" \
        ${envs[@]+"${envs[@]}"} bash "$DD_REVIEW" "$@" 2>"$WORK/dedupe.err" )"; RC=$?
  ERR="$(cat "$WORK/dedupe.err")"
}
dd_snapshot() { find "$DD_RUN" -type f | LC_ALL=C sort; }
dd_snapshot > "$WORK/dd-before.txt"
reset_fake; rm -f "$DD_LOG"
run_dedupe -- "$DD_RUN"
[ "$RC" -eq 12 ] && [ -z "$OUT" ] && [ "$(calls)" -eq 0 ] && [ ! -f "$DD_LOG" ] \
  && ok "N1 FF_JEV_MODE 未設定（off）は exit 12・stdout 空・通信 0・記録なし" || bad "N1 rc=$RC out=$OUT calls=$(calls)"
run_dedupe FF_JEV_MODE=on FF_JEV_ENABLED=1 FF_JEV_POINTS=novelty,retro -- "$DD_RUN"
[ "$RC" -eq 12 ] && [ -z "$OUT" ] && [ "$(calls)" -eq 0 ] && [ ! -f "$DD_LOG" ] \
  && ok "N2 on でも dedupe が FF_JEV_POINTS に無ければ exit 12・stdout 空・通信 0・記録なし（既定の名簿に入れない）" || bad "N2 rc=$RC out=$OUT calls=$(calls)"
# on: 3 対へ「同じ（p=0.95）」「別（p=0.1、confidence 0.8 = 閾値ちょうど）」「閾値未満（p=0.6）」を 1 つずつ返す
reset_fake; rm -f "$DD_LOG"
plan_noul 1 same_defect 0.95; plan_noul 2 same_defect 0.1; plan_noul 3 same_defect 0.6
run_dedupe FF_JEV_MODE=on FF_JEV_ENABLED=1 FF_JEV_POINTS=dedupe -- "$DD_RUN"
dd_folds="$(printf '%s\n' "$OUT" | grep -c '^- ')"
if [ "$RC" -eq 0 ] && [ "$(calls)" -eq 3 ] && [ "$dd_folds" -eq 1 ] \
   && [[ "$OUT" == 'Jev の判定点 dedupe（閾値 0.8）が同じ欠陥と判定した対です。'* ]] && [[ "$OUT" == *'（confidence 0.9）'* ]] \
   && [[ "$ERR" == *'review-dedupe: pairs=3 same=1 different=1 fallback=1'* ]] \
   && jq -e -s 'length==3 and all(.[]; .point=="dedupe")' "$DD_LOG" >/dev/null 2>&1; then
  ok "N3 on + dedupe: 1 対 1 回ずつ判定し、閾値（組み込み 0.8）以上で「同じ」の対だけを畳む指示として出す（別・閾値未満は出さない）"
else bad "N3 rc=$RC calls=$(calls) folds=$dd_folds out=$OUT err=$ERR"; fi
if [ -f "$FAKE/call.1.body" ] && jq -e '(.state|keys)==["finding_a","finding_b"] and (.state.finding_a|startswith("src/a.ts:")) and (.state.finding_b|startswith("src/a.ts:"))' "$FAKE/call.1.body" >/dev/null 2>&1 \
   && [ "$(jq -cS '.questions' "$FAKE/call.1.body")" = "$(jq -cS '.' "$DD_Q")" ] \
   && printf '%s\n' "$OUT" | grep '^- ' | grep -E '^- [a-z-]+:[a-z-]+ の src/a\.ts:[0-9]+（[a-z-]+/[a-z-]+\.md:[0-9]+ の判定行）「.+」 と [a-z-]+:[a-z-]+ の src/a\.ts:[0-9]+（[a-z-]+/[a-z-]+\.md:[0-9]+ の判定行）「.+」（confidence ' >/dev/null; then
  ok "N3b 送るのは --run の state（finding_a / finding_b だけ）と questions/dedupe.json そのもの。指示の行は両レーンと file:line・判定行の位置・題名を持つ"
else bad "N3b 送信内容か指示の行の形が違う: $(head -c 300 "$FAKE/call.1.body" 2>/dev/null)"; fi
dd_snapshot > "$WORK/dd-after.txt"
cmp -s "$WORK/dd-before.txt" "$WORK/dd-after.txt" && ok "N4 本番経路はレビュー結果の置き場へファイルを作らない（記録は作業ツリーの外だけ）" || bad "N4 run ディレクトリが変わった"
reset_fake 401; rm -f "$DD_LOG"
run_dedupe FF_JEV_MODE=on FF_JEV_ENABLED=1 FF_JEV_POINTS=dedupe -- "$DD_RUN"
[ "$RC" -eq 11 ] && [ -z "$OUT" ] && [ "$(calls)" -eq 1 ] && [[ "$ERR" == *'stopped=unauthorized'* ]] \
  && ok "N5 Jev の設定の失敗（401）は残りの対を呼ばず exit 11・stdout 空（呼び出し元は従来経路で続行）" || bad "N5 rc=$RC out=$OUT calls=$(calls) err=$ERR"
reset_fake 429 429 429; rm -f "$DD_LOG"
run_dedupe FF_JEV_MODE=on FF_JEV_ENABLED=1 FF_JEV_POINTS=dedupe -- "$DD_RUN"
[ "$RC" -eq 0 ] && [ -z "$OUT" ] && [ "$(calls)" -eq 3 ] && [[ "$ERR" == *'pairs=3 same=0 different=0 fallback=3'* ]] \
  && ok "N6 対ごとの失敗（429 の使い切り）は止めずに残りの対も判定し、畳む対が無ければ stdout 空" || bad "N6 rc=$RC out=$OUT calls=$(calls) err=$ERR"
reset_fake
run_dedupe FF_JEV_MODE=on FF_JEV_ENABLED=1 FF_JEV_POINTS=dedupe -- "$WORK/dd/no-such-dir"
[ "$RC" -eq 2 ] && [ "$(calls)" -eq 0 ] && ok "N7 出力先が無ければ exit 2（従来経路へ黙って落とさない）" || bad "N7 rc=$RC"
run_dedupe FF_JEV_MODE=yes -- "$DD_RUN"
[ "$RC" -eq 64 ] && ok "N8 FF_JEV_MODE の未知の値は exit 64" || bad "N8 rc=$RC"
# 名簿の判定は依存・引数の検査より前（dedupe を使わない on の利用者を jq 不在・出力先の指定漏れで止めない）
mkdir -p "$WORK/dd/nojq-bin" && ln -sf "$(command -v dirname)" "$WORK/dd/nojq-bin/dirname"
reset_fake
OUT="$(env -i HOME="$ISO_HOME" PATH="$WORK/dd/nojq-bin" FF_JEV_MODE=on FF_JEV_POINTS=novelty,retro "$BASH" "$DD_REVIEW" "$DD_RUN" 2>"$WORK/dedupe.err")"; RC=$?
[ "$RC" -eq 12 ] && [ -z "$OUT" ] && [ "$(calls)" -eq 0 ] && ok "N8b dedupe が名簿に無ければ jq が無くても exit 12（依存不在で呼び出し元を止めない）" || bad "N8b rc=$RC out=$OUT err=$(cat "$WORK/dedupe.err")"
run_dedupe FF_JEV_MODE=on FF_JEV_POINTS=novelty -- "$WORK/dd/no-such-dir"
[ "$RC" -eq 12 ] && [ -z "$OUT" ] && ok "N8c dedupe が名簿に無ければ出力先が無くても exit 12" || bad "N8c rc=$RC err=$ERR"
run_dedupe FF_JEV_MODE=on -- "$DD_RUN"
DD_DEFAULT_POINTS="$(env -i HOME="$ISO_HOME" PATH="$PATH" FF_JEV_MODE=on bash "$PLUGIN_ROOT/scripts/jev/jev-decide.sh" --status 2>/dev/null | sed -n 's/^JEV_POINTS=//p')"
case " $DD_DEFAULT_POINTS " in *' dedupe '*) dd_default_has=1 ;; *) dd_default_has=0 ;; esac
[ "$RC" -eq 12 ] && [ -z "$OUT" ] && [ -n "$DD_DEFAULT_POINTS" ] && [ "$dd_default_has" -eq 0 ] \
  && ok "N8d FF_JEV_POINTS 未設定は既定の名簿（jev-decide.sh の既定 = ${DD_DEFAULT_POINTS}。dedupe を含まない）として exit 12" || bad "N8d rc=$RC default=[$DD_DEFAULT_POINTS]"
run_dedupe FF_JEV_MODE=on FF_JEV_POINTS=Bad,dedupe -- "$DD_RUN"
[ "$RC" -eq 64 ] && ok "N8e FF_JEV_POINTS の不正な判定点名は exit 64" || bad "N8e rc=$RC"
# 止める側の経路: 閾値の設定誤りは jev-decide の 64 を素通しし、対を作れない回は exit 11 で原因を名指す
reset_fake
run_dedupe FF_JEV_MODE=on FF_JEV_ENABLED=1 FF_JEV_POINTS=dedupe FF_JEV_MIN_CONFIDENCE_DEDUPE=abc -- "$DD_RUN"
[ "$RC" -eq 64 ] && [ "$(calls)" -eq 0 ] && ok "N8f 閾値の設定誤り（jev-decide の exit 64）は従来経路へ落とさずそのまま返す" || bad "N8f rc=$RC calls=$(calls)"
DD_BADRUN="$WORK/dd/badrun/.review-results"
mkdir -p "$DD_BADRUN/claude-code" && printf 'cli\tperspective\n' > "$DD_BADRUN/claude-code/code-review.findings.tsv"
run_dedupe FF_JEV_MODE=on FF_JEV_ENABLED=1 FF_JEV_POINTS=dedupe -- "$DD_BADRUN"
[ "$RC" -eq 11 ] && [ -z "$OUT" ] && [[ "$ERR" == *'cannot build pairs'*'build-dedupe-eval-sets:'*'ヘッダが契約と違います'* ]] \
  && ok "N8g 対を作れない回（findings.tsv の書式違反）は exit 11・stdout 空で、生成器の診断行を名指す" || bad "N8g rc=$RC err=$ERR"
reset_fake; rm -f "$DD_LOG"
plan_noul 1 same_defect 0.95; printf '401\n' >> "$FAKE/plan"
run_dedupe FF_JEV_MODE=on FF_JEV_ENABLED=1 FF_JEV_POINTS=dedupe -- "$DD_RUN"
[ "$RC" -eq 0 ] && [ "$(calls)" -eq 2 ] && [ "$(printf '%s\n' "$OUT" | grep -c '^- ')" -eq 1 ] && [[ "$ERR" == *'same=1 different=0 fallback=2 stopped=unauthorized'* ]] \
  && ok "N8h 途中で設定の失敗が出たら残りは呼ばず、それまでに採用した対だけを出して exit 0" || bad "N8h rc=$RC calls=$(calls) out=$OUT err=$ERR"
mkdir -p "$WORK/dd/empty-run"
OUT="$(FF_DEV_TOOLKIT_ROOT="$PLUGIN_ROOT" bash "$RUNNER" "$DD_GEN" --run "$WORK/dd/empty-run" 2>"$WORK/gend.err")"; RC=$?
[ "$RC" -eq 0 ] && [ -z "$OUT" ] && grep -q '^run: lanes=0 ' "$WORK/gend.err" && ok "N9 --run は型付きレコードの無い回で何も出さず exit 0（0 対の理由は stderr の run: 行）" || bad "N9 rc=$RC out=$OUT"
# --run は 1 回分だけを読む: 両レーンの節を持つ入れ子の .prev（前回の回）の対を今回の対に混ぜない
DD_NRUN="$WORK/dd/nrun/.review-results"
dd_run1 "$DD_NRUN" || bad "N fixture nrun"
dd_report "$DD_NRUN/.prev-20260102T000000Z" claude-code:code-review codex-cli:comprehensive-review
dd_tsv "$DD_NRUN/.prev-20260102T000000Z/claude-code/code-review.findings.tsv" 'claude-code\tcode-review\tsuggestion\tno\t70\tsrc/nested.ts\t7\t[src/nested.ts:7] **前回の指摘**\t'
printf '### Suggestions\n- [src/nested.ts:7] **前回の指摘**\n  - verdict: severity=suggestion failure_scenario=no confidence=70 file=src/nested.ts line=7\n' > "$DD_NRUN/.prev-20260102T000000Z/claude-code/code-review.md"
dd_tsv "$DD_NRUN/.prev-20260102T000000Z/codex-cli/comprehensive-review.findings.tsv" 'codex-cli\tcomprehensive-review\tsuggestion\tno\t80\tsrc/nested.ts\t8\t**前回の別の指摘**\t'
printf '### Suggestion\n\n- **前回の別の指摘**\n  本文。\n- verdict: severity=suggestion failure_scenario=no confidence=80 file=src/nested.ts line=8\n' > "$DD_NRUN/.prev-20260102T000000Z/codex-cli/comprehensive-review.md"
OUT="$(FF_DEV_TOOLKIT_ROOT="$PLUGIN_ROOT" bash "$RUNNER" "$DD_GEN" --scan "$WORK/dd/nrun" --out "$WORK/dd/o-nrun" 2>/dev/null)"
dd_nested_scan="$(jq -r 'select(.validity=="same-report") | .state.finding_a' "$WORK/dd/o-nrun/dedupe-candidates.jsonl" 2>/dev/null | grep -c '^src/nested.ts:')"
OUT="$(FF_DEV_TOOLKIT_ROOT="$PLUGIN_ROOT" bash "$RUNNER" "$DD_GEN" --run "$DD_NRUN" 2>"$WORK/gend.err")"; RC=$?
[ "$RC" -eq 0 ] && [ "$dd_nested_scan" -eq 1 ] && [ "$(printf '%s\n' "$OUT" | grep -c '"validity":"same-report"')" -eq 3 ] && [ "$(printf '%s\n' "$OUT" | grep -c .)" -eq 3 ] \
   && [ "$(printf '%s\n' "$OUT" | grep -c 'src/nested.ts')" -eq 0 ] \
  && ok "N10 --run は 1 回分だけを読み、same-report の入れ子 .prev（--scan では対になる）を今回の対に混ぜない" || bad "N10 rc=$RC nested_scan=$dd_nested_scan out=$(printf '%s' "$OUT" | head -c 200)"
# 入口フェンスを書かれたまま抜き出して実行する（stdout がそのままホストへ返る）
awk '/<!-- ff-jev-dedupe-entry:start -->/{on=1;next} /<!-- ff-jev-dedupe-entry:end -->/{on=0} on && !/^```/{print}' "$DD_REF" > "$WORK/dedupe-entry.sh"
if [ ! -s "$WORK/dedupe-entry.sh" ]; then
  bad "N11 入口フェンスがありません: $DD_REF"
else
  dd_fence() { # $1..=環境（VAR=val）。フェンスを書かれたまま実行し stdout→${OUT} rc→${RC}
    OUT="$(env -i HOME="$ISO_HOME" PATH="$FAKE/bin:$PATH" TMPDIR="$WORK" FAKE_CURL_DIR="$FAKE" FF_DEV_TOOLKIT_ROOT="$PLUGIN_ROOT" FF_ACE_TS_RUNNER=tsx \
      TYPESAFE_API_KEY=test-only FF_JEV_MAX_RETRIES=0 FF_JEV_DECISION_LOG="$DD_LOG" "$@" bash "$WORK/dedupe-entry.sh" 2>/dev/null)"; RC=$?
  }
  reset_fake
  dd_fence REVIEW_OUTPUT_DIR="$DD_RUN"
  [ "$RC" -eq 0 ] && [ -z "$OUT" ] && [ "$(calls)" -eq 0 ] && ok "N11 入口フェンスは off で何も出さず通信もしない（委譲プロンプトはバイト同一）" || bad "N11 rc=$RC out=$OUT calls=$(calls)"
  reset_fake; rm -f "$DD_LOG"
  plan_noul 1 same_defect 0.95; plan_noul 2 same_defect 0.95; plan_noul 3 same_defect 0.95
  dd_fence REVIEW_OUTPUT_DIR="$DD_RUN" FF_JEV_MODE=on FF_JEV_ENABLED=1 FF_JEV_POINTS=dedupe
  [ "$RC" -eq 0 ] && [ "$(printf '%s\n' "$OUT" | grep -c '^- ')" -eq 3 ] && ok "N12 入口フェンスは書かれたままで、on + dedupe の畳む指示を stdout からホストへ返す" || bad "N12 rc=$RC out=$OUT"
  reset_fake 401
  dd_fence REVIEW_OUTPUT_DIR="$DD_RUN" FF_JEV_MODE=on FF_JEV_ENABLED=1 FF_JEV_POINTS=dedupe
  [ "$RC" -eq 0 ] && [ -z "$OUT" ] && ok "N13 入口フェンスは Jev の失敗（exit 11）で止まらず、何も足さずに続行する" || bad "N13 rc=$RC out=$OUT"
  reset_fake
  dd_fence FF_JEV_MODE=on FF_JEV_ENABLED=1 FF_JEV_POINTS=dedupe
  [ "$RC" -eq 2 ] && [ -z "$OUT" ] && [ "$(calls)" -eq 0 ] && ok "N13b dedupe を名簿に入れて出力先を渡し忘れたら止まる（既定の置き場の別の回を判定しない）" || bad "N13b rc=$RC out=$OUT"
  dd_fence FF_JEV_MODE=on FF_JEV_POINTS=novelty
  [ "$RC" -eq 0 ] && [ -z "$OUT" ] && ok "N13c dedupe を使わない on の利用者は出力先が無くても止まらない" || bad "N13c rc=$RC out=$OUT"
  dd_fence REVIEW_OUTPUT_DIR="$DD_RUN" FF_JEV_MODE=on FF_JEV_ENABLED=1 FF_JEV_POINTS=dedupe FF_JEV_MIN_CONFIDENCE_DEDUPE=abc
  [ "$RC" -eq 64 ] && ok "N13d 入口フェンスは設定誤り（exit 64）で止まる（従来経路へ黙って落とさない）" || bad "N13d rc=$RC"
fi
grep -qF '[重複判定](references/jev-dedupe.md)' "$PLUGIN_ROOT/skills/multi-review/SKILL.md" \
  && ok "N14 multi-review SKILL.md §3-1 から入口の reference へ辿れる" || bad "N14 SKILL.md に reference への導線がありません"
OUT="$(env -i HOME="$ISO_HOME" PATH="$PATH" FF_JEV_MODE=on FF_JEV_POINTS=dedupe bash "$PLUGIN_ROOT/scripts/jev/jev-decide.sh" --status 2>/dev/null)"
grep -qx 'JEV_THRESHOLD_DEDUPE=0.8' <<<"$OUT" && ok "N15 判定点 dedupe の組み込み閾値は 0.8（事前登録した採否規則が帯別表から選んだ値）" || bad "N15 status: $OUT"
