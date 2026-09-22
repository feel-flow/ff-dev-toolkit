#!/usr/bin/env bash
#
# Jev 判定アダプタ（scripts/jev/jev-judge.sh）と offline 評価ハーネス（scripts/jev/jev-eval.sh）
# の契約検査。実網には出ない — PATH の先頭へ偽 `curl` を置き、呼び出しの形（`-K -` で
# 設定を stdin から渡す・argv にキーを載せない・本文はファイル経由）と応答計画（HTTP
# ステータスの列）に対する振る舞いを実測する。
#
# 固定する契約:
#   A. 有効化の二段構え。FF_JEV_ENABLED=1 が無ければキーがあっても通信せず exit 3、
#      有効でもキーが 3 経路のどれにも無ければ通信せず exit 4。どちらも「空を返す」形に
#      しない（判定不能を不一致なしへ倒さない）
#   B. キーは stdout / stderr / argv に出ない。設定は stdin（`-K -`）経由で渡る
#   C. HTTP ステータスの種別を終了コードで名乗る（401→5 / 422→6 / 429・529 疲弊→7 /
#      その他→8 / answers 欠落→9）。429 は Retry-After を優先した上限付きリトライ
#   D. 入力不正（questions が object でない・type 不正・state 空・バイト予算超過）は
#      通信せず exit 2
#   E. ハーネスは全行を先に検証し、空ファイル・空行・読めない行・expected の qid 不在は
#      1 件も送らず exit 2。判定に 1 件でも失敗したら集計せず、その終了コードを伝える。
#      成功時は一致率・質問 id 別・group 別・confidence 帯別・p50/p95・トークン・コストを出す
#   F. 同梱 fixture（日英 Choice probe）は en / ja 各 5 件で、expected が criteria に実在する
#   G. レビューで見つかった「判定不能が成功 / 不一致へ化ける」経路の固定: 応答の qid 欠落・
#      type 不一致・値の型不正は exit 9、キーの不正文字・読めないキーファイルは通信せず exit 4、
#      数値であるべき設定の非数値は exit 64、Retry-After はバックオフより優先し上限で頭打ち、
#      バイト予算は文字数でなくバイトで数える、ハーネスはラベル不正（criteria に無い option・
#      legend に無い文言・noul の非 boolean・null / 数値の state）を通信前に exit 2 で止め、
#      --out へ書けなければ exit 2、低 confidence の不一致は該当帯へ計上される
#   H. ACE 評価セット生成器（scripts/jev/build-ace-eval-sets.ts）は合成 Playbook（6 エントリ・2 版）
#      から期待値まで固定できる形で 3 セットを作る: 正例 = Helpful 行の参照先、負例 = 同カテゴリの
#      別エントリ、recent の近傍は版の日付より前（同日は Origin PR が小さい側）だけで未来のエントリ
#      は出ない、追加候補は全 false、Helpful 候補は参照先だけ true。決定性（バイト同一）。
#      判定不能は exit 2（ラベル欠落・candidates 不在・Playbook に無い候補・数値オプション不正・
#      Changelog 不在 / 見出し drift / 読めない Helpful 行・Date 欠落）。--summarize は評価時の
#      predicted で判定し、id 契約外の行と answers 欠落を拒否する。tsx ランナー（ace-run-ts.sh）が
#      起動できない環境はこの節だけ部分 skip、実 PLAYBOOK が無い配布先は H22 だけ部分 skip
#   I. 判断点評価セット生成器（scripts/jev/build-judgment-eval-sets.ts）は合成 cases（LOW / HIGH）と合成 cache
#      （AC 表あり・報告なし・AC 表なし）から期待値まで固定できる形で 2 セットを作る: assess-impact は Score(3) で
#      expected はレベル番号、close-issue は Choice(3) で state に PR 本文を入れず、post-merge 行は入れず、合成負例は
#      同じ Issue 内で根拠を 1 つずらして期待 unmet。gh を触るのは --fetch-closed-issues だけで、偽 gh で「1 Issue
#      1 JSON・報告の PR 番号だけ pr view・gh 失敗は exit 2 で cache を作らない」を固定。決定性（バイト同一）。
#      判定不能は exit 2（期待影響度の欠落・case 0 件・cache 空・判定セルが読めない・全 Issue が読めず 0 行・
#      cache 非 JSON / 形 drift・数値オプション不正・未知オプション・AC 見出しの下に無い判定表・表の途中の表以外の行・
#      判定が 2 列目でないヘッダ）。ファイル一覧が 100 件で切れた PR は skipped として数える。--summarize は過剰 / 過少と厳しい側 / 緩い側を分け、
#      契約外の結果行を拒否する。tsx ランナーが起動できない環境はこの節だけ部分 skip
#   J. 言語 A/B セット生成器（scripts/jev/build-lang-ab-sets.ts）は、生成済みセットへの後処理として
#      「判定対象の言語だけが違う対」を作る。動かすのは state の各フィールドと候補文
#      （questions.*.instructions.candidate）で、質問文（instructions.question）・criteria・expected・
#      識別子（ASCII の id・state.pr.files）は不変。合成セット（novelty 形 2 行 + close-issue 形 2 行 +
#      等間隔抽出用の 5 行）で固定するのは: --extract は group で絞って決定的に N 件（count < pool の
#      等間隔そのものを 5 件→3 件 = 添字 0/1/3 で固定。バイト同一）、--template は英訳対象を内容ハッシュで
#      畳んで列挙し日本語を含まない値を入れない、--translate は id を変えずに lang=en を付け許可パスの
#      日本語だけを置換する、--compare は全体・group 別・confidence 帯別（両側の帯外も出す）・不一致 id の
#      差集合・予測が変わった件数を出す。判定不能は緑へ倒さず exit 2:
#      許可パス外に残った日本語＝混在言語（state 直下 / state.pr 直下 / instructions 直下 / 配列要素の
#      4 か所と、ひらがな / カタカナ / 漢字 / 全角記号の 4 字種を別々に固定）・翻訳の無い原文・空の訳・
#      使われない fixture 項目（両方あるときは 1 回で両方報告）・重複キー・非文字列の項目・_meta の
#      翻訳日 / 翻訳者の欠落・未翻訳テンプレのままの適用・src とキーのハッシュ不一致・訳のコードスパン外に
#      残った日本語・バッククォート未閉鎖で境界を確定できない・母集団が --count に足りない・存在しない
#      group（「足りない」とは別の文言）・空ファイル・JSON として読めない行・id の無い行・元セットや結果
#      ファイルの重複 id・--count の 0 と非整数・--out へ書けない・比較の id 集合不一致・同じ id の
#      group / expected / qid が ja・en で違う・結果行の match / predicted / usage.input_tokens 欠落・
#      1 行に質問が 2 件以上・モード併用・未知オプション・同じフラグ 2 回・--with / --translations 欠落。
#      コードスパンの対応規則は CommonMark（長さ N の列は長さ N の列とだけ対にする）。
#      同梱の翻訳 fixture は SSOT 専用（docs/04-quality/jev-lang-ab/）なので、公開 checkout では
#      J38 / J39 だけ部分 skip。tsx ランナーが起動できない環境はこの節だけ部分 skip
#   K. 切替入口（scripts/jev/jev-decide.sh）の二段構え。FF_JEV_MODE が on でない・判定点が名簿に無い
#      （設定済みの空値は 0 件）ときは通信も記録もせず exit 12、on だけでは課金経路が開かない（FF_JEV_ENABLED
#      無しは exit 11 disabled で記録だけ残す）、全質問の confidence が閾値以上のときだけ exit 0 adopt、
#      未満は exit 10、Jev の失敗は exit 11（種別を保持）、記録先へ書けなければ採用条件を満たしても exit 11
#      log-unwritable、TYPESAFE_MODEL 未指定は jev-1.13.0 に固定、{{KEY}} は --fill で置換し残れば送らず exit 2、
#      未知の FF_JEV_MODE / 非数値の閾値は exit 64、--summarize は記録が無い・読めない行があれば exit 2、
#      --overturn は adopt した決定にだけ効く。同梱 fixture questions/same-action.json の質問文は生成器
#      （build-ace-eval-sets.ts）の novelty 質問と同一
#
# 空振り検出: 同梱 fixture を空ファイルに差し替えると (F1〜F4) の 4 件が赤になる（2026-09-20 実測。52 件中 4 件失敗。0 行を「件数どおり」へ倒さない）。
# 空振り検出: 同梱 fixture から ja 側の 5 行を削ると (F1〜F4) の 4 件が赤になる（2026-09-20 実測。52 件中 4 件失敗。片側の消失を通さない）。
# 空振り検出: jev-eval.sh の空セット検査を無効化すると (E1) が赤になる（2026-09-20 実測。後段の「有効な行なし」検査も exit 2 なので rc では見分けられず、E1 は「評価セットが空です」の文言一致で赤にしている）。
# 空振り検出: 合成 Playbook の Changelog 見出しを別綴りにすると (H14) が「行が 1 件も読めない」を要求して赤になる（2026-09-20 実測。0 件を「セット 0 件で成功」へ倒さない）。
# 空振り検出: 合成 Playbook の Helpful 行を契約外の括弧にすると (H15) が赤になる（2026-09-20 実測。読めない行を黙って落として母集団を縮めない）。
# 空振り検出: 判断点生成器の判定セル分類で読めない形を achieved へ倒すと (I11) が赤になる（2026-09-21 実測。150 件中 1 件失敗。読めない判定を達成にしない）。
# 空振り検出: 判断点生成器の「セット 0 行なら exit 2」を外すと (I10 / I29) が赤になる（2026-09-21 実測。150 件中 2 件失敗。全 Issue が読めないのを成功にしない）。
# 空振り検出: 同梱の assess-impact fixtures ディレクトリを空にすると (I26) が「case 0 件 = exit 2」側へ倒れて赤になる（2026-09-21 実測。150 件中 1 件失敗。fixture の消失を 0 件の緑にしない）。
# 空振り検出: 同梱の翻訳 fixture 2 本の entries を空配列にすると (J38 / J39) が赤になる（2026-09-22 実測。189 件中 2 件失敗。0 件を「件数どおり」へ倒さない）。
# 空振り検出: 同梱の翻訳 fixture を片方（close-issue 側）だけ消すと (J38 / J39) が赤になる（2026-09-22 実測。189 件中 2 件失敗。両方不在の公開 checkout だけが部分 skip で、片側の消失は配置 drift として赤にする — 実測前は skip へ倒れて緑だった）。
# 変異検出: TRANSLATABLE_PATHS へ state.* / state.pr.* / questions.*.instructions.* を足すと (J14 / J15) が赤になる（2026-09-22 実測。189 件中 2 件失敗）。
# 変異検出: pickEvenly を pool.slice(0, count)（head 取り）へ変えると (J2) が赤になる（2026-09-22 実測。等間隔ブランチが実行されない状態を通さない）。
# 変異検出: translationKey の桁を 8 桁 → 3 桁へ変えると (J39) が赤になる（2026-09-22 実測。同梱 fixture を readFixture へ通す針が無いと、276 件全部が key 不一致でも緑になる）。
# 変異検出: JA_RE からカタカナ域（\p{Script=Katakana}）を削ると (J15) が赤になる（2026-09-22 実測。字種ごとに単独の値を置いているので 1 域の欠落を検出する）。
# 変異検出: outsideCodeSpans の長さ一致（m === n）を m > 0 へ変えると (J26) が赤になる（2026-09-22 実測。nested-runs の 1 本だけがこの規則を測る — unequal-runs は未閉鎖側の判定でも同じ rc になる）。
# 変異検出: outsideCodeSpans の未閉鎖検出（unclosed = true）を削ると (J26) が赤になる（2026-09-22 実測。境界を確定できない形を「訳し忘れなし」へ倒さない）。
# 変異検出: readFixture の「コードスパン外に日本語」die を削ると (J26) が赤になる（2026-09-22 実測）。
# 変異検出: readSet の重複 id die を削ると (J8) が赤になる（2026-09-22 実測。対の一意キーが壊れたまま評価を流さない）。
# 変異検出: readMeasured の answers 2 件以上 die / predicted 欠落 die を削ると (J34) が赤になる（2026-09-22 実測、各 1 件）。
# 変異検出: compare の group / expected / qid 一致検査を削ると (J32) が赤になる（2026-09-22 実測。別条件の実行を言語差として集計しない）。
# 変異検出: writeOut の try/catch を外して例外を投げると (J10) が赤になる（2026-09-22 実測。--out へ書けない回を rc=1 で終わらせない）。
# 変異検出（赤にできない = 別の層が吸収している）: translate の置換後に置いていた「出力の再走査」は、readFixture が同じ検査を全 entry へ先に当てているため赤にできる入力が無く、検出力ゼロだったので削除した（2026-09-22 実測。189 件中 0 件失敗）。
# 空振り検出: 偽 curl の応答計画を空にすると (B1 / C1〜C4 / E7〜E11 / F4 / G 節) が「応答なし = exit 8」側へ倒れて赤になる（2026-09-20 実測。応答が無いのを成功へ倒さない）。
# 空振り検出: 同梱 fixture questions/same-action.json を `{}` に差し替えると (K19h / K29 / K30) が赤になる（2026-09-22 実測。250 件中 3 件失敗。質問が無い fixture を「契約どおり」へ倒さない — K30 は生成器が実際に出した質問と完全一致で比べるので null も部分一致も通さない）。
# 空振り検出: jev-decide.sh --summarize の「decision の行が 1 行も無ければ exit 2」を外すと (K27) が赤になる（2026-09-22 実測。250 件中 1 件失敗。overturn だけの記録を「採用率 0% の表」にしない）。
# 変異検出: jev-decide.sh の `FF_JEV_MODE != on → exit 12` を削ると (K1 / K2 / K4 / K28d) が赤になる（2026-09-22 実測。250 件中 4 件失敗。K1 は通信 1 回・記録あり・adopt まで進み、K4 は K1 / K2 が残した記録で赤になり、K28d は off が依存検査（jq 不在 = 69）へ進んでしまう形が見える）。
# 変異検出: 閾値検証の `> 0` を `>= 0` へ緩めると (K13h) が赤になる（2026-09-22 実測。250 件中 2 件失敗〔0 と 0.0〕。confidence 0 でも採る「全件採用」の設定を通さない）。
#
# 依存: bash 3.2 / jq / mktemp。一時領域を作れない環境は skip ではなく赤（suite 全体の
# skip 経路を持たない）。実作業ツリーには触れない（HOME・PATH・TMPDIR を隔離する）。
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
JUDGE="$PLUGIN_ROOT/scripts/jev/jev-judge.sh"
EVAL="$PLUGIN_ROOT/scripts/jev/jev-eval.sh"
DECIDE="$PLUGIN_ROOT/scripts/jev/jev-decide.sh"
SAME_ACTION_Q="$PLUGIN_ROOT/scripts/jev/questions/same-action.json"
ACE_GEN="$PLUGIN_ROOT/scripts/jev/build-ace-eval-sets.ts"
PROBE="$PLUGIN_ROOT/scripts/jev/fixtures/ja-en-choice-probe.jsonl"

PASS=0
FAIL=0
ok()  { echo "  ✓ $1"; PASS=$((PASS + 1)); }
bad() { echo "  ✗ $1" >&2; FAIL=$((FAIL + 1)); }

command -v jq >/dev/null 2>&1 || { echo "✗ jq がありません（本 suite は jq を要する。skip ではなく赤）" >&2; exit 1; }
for f in "$JUDGE" "$EVAL" "$PROBE" "$DECIDE" "$SAME_ACTION_Q" "$ACE_GEN"; do
  [ -f "$f" ] || { echo "✗ 対象がありません: $f" >&2; exit 1; }
done

if WORK="$(mktemp -d "${TMPDIR:-/tmp}/jev-adapter.XXXXXX" 2>&1)" && [ -d "$WORK" ]; then
  :
else
  echo "✗ 一時領域を作れません（skip ではなく赤）: ${WORK}" >&2
  exit 1
fi
# 途中死（set -u 等）で $? が 0 のまま抜ける形を rc=0 の pass にしない
FF_REACHED_END=0
_ff_exit_guard() {
  _ff_rc=$?
  rm -rf "$WORK"
  if [ "$_ff_rc" -eq 0 ] && [ "$FF_REACHED_END" -ne 1 ]; then
    echo "✗ jev-adapter: 最後まで到達しませんでした（途中で中断）" >&2
    exit 1
  fi
  exit "$_ff_rc"
}
trap _ff_exit_guard EXIT

# ---- 偽 curl -------------------------------------------------------------------
# 応答計画 $FAKE/plan は 1 行 1 ステータス。先頭行を消費して返す。本文は
# $FAKE/body.<status> があればそれ、無ければ既定の成功応答。`-D <file>` があれば
# ヘッダを書く（plan の行が `429 retry-after=0` の形なら Retry-After を付ける）。
# 呼び出しごとに stdin（設定）と argv を $FAKE/call.<n>.{config,args} へ残す。
FAKE="$WORK/fake"
mkdir -p "$FAKE/bin"
cat > "$FAKE/bin/curl" <<'EOF'
#!/usr/bin/env bash
set -u
FAKE="${FAKE_CURL_DIR:?}"
n=$(( $(ls "$FAKE" | grep -c '^call\.[0-9]*\.args$') + 1 ))
cat > "$FAKE/call.$n.config"
printf '%s\n' "$@" > "$FAKE/call.$n.args"
prev=""
for a in "$@"; do
  if [ "$prev" = "--data-binary" ]; then
    case "$a" in @*) cp "${a#@}" "$FAKE/call.$n.body" 2>/dev/null ;; esac
  fi
  prev="$a"
done
if [ ! -s "$FAKE/plan" ]; then
  echo "fake curl: no planned response" >&2
  exit 7
fi
line="$(head -n 1 "$FAKE/plan")"
tail -n +2 "$FAKE/plan" > "$FAKE/plan.next" && mv "$FAKE/plan.next" "$FAKE/plan"
status="${line%% *}"
extra="${line#* }"
[ "$extra" = "$line" ] && extra=""
hdr=""
prev=""
for a in "$@"; do
  if [ "$prev" = "-D" ]; then hdr="$a"; fi
  prev="$a"
done
if [ -n "$hdr" ]; then
  printf 'HTTP/1.1 %s X\r\n' "$status" > "$hdr"
  case "$extra" in
    retry-after=*) printf 'Retry-After: %s\r\n' "${extra#retry-after=}" >> "$hdr" ;;
  esac
  printf '\r\n' >> "$hdr"
fi
if [ -f "$FAKE/body.$status" ]; then
  cat "$FAKE/body.$status"
else
  printf '%s' '{"model":"jev-1.13.0","answers":{"dept":{"type":"choice","choice":"billing","probabilities":{"billing":0.88,"technical":0.12},"confidence":0.81},"urgent":{"type":"noul","noul":0.95},"level":{"type":"score","score":1.05,"legend":{"0":"Calm","1":"Frustrated","2":"Very angry"},"probabilities":{"0":0.0,"1":0.95,"2":0.05},"confidence":0.92}},"usage":{"input_tokens":300,"output_tokens":20}}'
fi
printf '\n%s' "$status"
exit 0
EOF
chmod +x "$FAKE/bin/curl"
# 偽 sleep: 受け取った秒数を記録して眠らない。Retry-After とバックオフの値を識別するため
cat > "$FAKE/bin/sleep" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$1" >> "${FAKE_CURL_DIR:?}/sleep.log"
exit 0
EOF
chmod +x "$FAKE/bin/sleep"

# 隔離: HOME（既定キーパス）・PATH（偽 curl）・TMPDIR。実 HOME のキーは読ませない。
ISO_HOME="$WORK/home"
mkdir -p "$ISO_HOME"
export FAKE_CURL_DIR="$FAKE"
run_judge() { # 偽 curl 配下で jev-judge.sh を実行。stdout→${OUT}、stderr→${ERR}、rc→${RC}
  OUT="$( env -i HOME="$ISO_HOME" PATH="$FAKE/bin:$PATH" TMPDIR="$WORK" FAKE_CURL_DIR="$FAKE" \
        "$@" bash "$JUDGE" 2>"$WORK/stderr" )"; RC=$?
  ERR="$(cat "$WORK/stderr")"
}
run_judge_args() { # $1..=環境（VAR=val）、-- の後がスクリプト引数
  local envs=()
  while [ $# -gt 0 ] && [ "$1" != "--" ]; do envs+=("$1"); shift; done
  [ "${1:-}" = "--" ] && shift
  OUT="$( env -i HOME="$ISO_HOME" PATH="$FAKE/bin:$PATH" TMPDIR="$WORK" FAKE_CURL_DIR="$FAKE" \
        ${envs[@]+"${envs[@]}"} bash "$JUDGE" "$@" 2>"$WORK/stderr" )"; RC=$?
  ERR="$(cat "$WORK/stderr")"
}
run_eval_args() {
  local envs=()
  while [ $# -gt 0 ] && [ "$1" != "--" ]; do envs+=("$1"); shift; done
  [ "${1:-}" = "--" ] && shift
  OUT="$( env -i HOME="$ISO_HOME" PATH="$FAKE/bin:$PATH" TMPDIR="$WORK" FAKE_CURL_DIR="$FAKE" \
        ${envs[@]+"${envs[@]}"} bash "$EVAL" "$@" 2>"$WORK/stderr" )"; RC=$?
  ERR="$(cat "$WORK/stderr")"
}
reset_fake() { # $1..=応答計画の行
  rm -f "$FAKE"/call.* "$FAKE"/body.* "$FAKE/plan" "$FAKE/sleep.log"
  : > "$FAKE/plan"
  local l
  for l in "$@"; do printf '%s\n' "$l" >> "$FAKE/plan"; done
}
calls() { # 偽 curl の呼び出し回数。$FAKE が消えていたら 0 ではなく 999 を返して「通信なし」判定を空振りさせない
  if [ -d "$FAKE" ]; then ls "$FAKE" | grep -c '^call\.[0-9]*\.args$'; else echo "fake dir missing: $FAKE" >&2; echo 999; fi
}

KEY_FILE="$WORK/key"
FAKE_KEY="fake-key-0123456789abcdef-DO-NOT-LEAK"
printf '%s\n' "$FAKE_KEY" > "$KEY_FILE"
Q="$WORK/questions.json"
cat > "$Q" <<'EOF'
{
  "dept":   { "type": "choice", "instructions": "Which team?", "criteria": { "billing": null, "technical": null } },
  "urgent": { "type": "noul",   "instructions": "Urgent?" },
  "level":  { "type": "score",  "instructions": "How frustrated?", "criteria": ["Calm", "Frustrated", "Very angry"] }
}
EOF
STATE="$WORK/state.txt"
printf '支払いが 3 日間失敗しています\n' > "$STATE"

# ================================================================================
echo "== A. 有効化の二段構え =="
reset_fake 200
run_judge_args TYPESAFE_API_KEY_FILE="$KEY_FILE" -- --questions "$Q" --state-file "$STATE"
if [ "$RC" -eq 3 ] && grep -q '^JEV_ERROR=disabled$' <<<"$OUT" && [ "$(calls)" -eq 0 ]; then
  ok "A1 FF_JEV_ENABLED 未設定はキーがあっても通信せず exit 3（disabled）"
else bad "A1 disabled: rc=$RC calls=$(calls) out=$OUT"; fi

reset_fake 200
run_judge_args FF_JEV_ENABLED=0 TYPESAFE_API_KEY_FILE="$KEY_FILE" -- --questions "$Q" --state-file "$STATE"
[ "$RC" -eq 3 ] && ok "A2 FF_JEV_ENABLED=0 も無効（1 以外は Off）" || bad "A2 rc=$RC"

reset_fake 200
run_judge_args FF_JEV_ENABLED=1 -- --questions "$Q" --state-file "$STATE"
if [ "$RC" -eq 4 ] && grep -q '^JEV_ERROR=key-missing$' <<<"$OUT" && [ "$(calls)" -eq 0 ] \
   && grep -q 'TYPESAFE_API_KEY' <<<"$ERR"; then
  ok "A3 有効でもキーが無ければ通信せず exit 4（key-missing。3 経路を名指し）"
else bad "A3 key-missing: rc=$RC calls=$(calls) err=$ERR"; fi

reset_fake 200
run_judge_args FF_JEV_ENABLED=1 -- --json --check
[ "$RC" -eq 4 ] && ok "A4 --check もキー未設定を exit 4 で名乗る" || bad "A4 rc=$RC"

reset_fake 200
run_judge_args FF_JEV_ENABLED=1 TYPESAFE_API_KEY_FILE="$KEY_FILE" -- --check
if [ "$RC" -eq 0 ] && grep -q '^JEV_CHECK=1$' <<<"$OUT" && [ "$(calls)" -eq 0 ]; then
  ok "A5 --check はキーがあれば通信せずに exit 0"
else bad "A5 check: rc=$RC calls=$(calls)"; fi

# 3 経路それぞれ
reset_fake 200
run_judge_args FF_JEV_ENABLED=1 TYPESAFE_API_KEY="$FAKE_KEY" -- --questions "$Q" --state-file "$STATE"
[ "$RC" -eq 0 ] && ok "A6 キー経路 1: TYPESAFE_API_KEY" || bad "A6 rc=$RC err=$ERR"
reset_fake 200
mkdir -p "$ISO_HOME/.config/ff-dev-toolkit"
printf '%s\n' "$FAKE_KEY" > "$ISO_HOME/.config/ff-dev-toolkit/typesafe_api_key"
run_judge_args FF_JEV_ENABLED=1 -- --questions "$Q" --state-file "$STATE"
[ "$RC" -eq 0 ] && ok "A7 キー経路 3: ~/.config/ff-dev-toolkit/typesafe_api_key" || bad "A7 rc=$RC err=$ERR"
rm -rf "$ISO_HOME/.config"

# ================================================================================
echo "== B. 呼び出しの形とキーの非露出 =="
reset_fake 200
run_judge_args FF_JEV_ENABLED=1 TYPESAFE_API_KEY_FILE="$KEY_FILE" -- --questions "$Q" --state-file "$STATE"
if [ "$RC" -eq 0 ] && grep -q '^JEV_OK=1$' <<<"$OUT"; then
  ok "B1 200 応答で exit 0 / JEV_OK=1"
else bad "B1 rc=$RC out=$OUT err=$ERR"; fi
if grep -qF "$FAKE_KEY" <<<"${OUT}${ERR}"; then
  bad "B2 キーが stdout / stderr に出ている"
else ok "B2 キーは stdout / stderr に出ない"; fi
if grep -qF "$FAKE_KEY" "$FAKE/call.1.args"; then
  bad "B3 キーが curl の argv に載っている"
else ok "B3 キーは curl の argv に載らない"; fi
if grep -q "^header = \"Authorization: Bearer ${FAKE_KEY}\"$" "$FAKE/call.1.config" \
   && grep -qx -- '-K' "$FAKE/call.1.args" && grep -qx -- '-' "$FAKE/call.1.args"; then
  ok "B4 設定は -K - で stdin から渡り、Authorization ヘッダはそこにだけある"
else bad "B4 config/args: $(cat "$FAKE/call.1.config" | sed 's/Bearer .*/Bearer <redacted>/') / $(tr '\n' ' ' < "$FAKE/call.1.args")"; fi
body_arg="$(grep -A1 -x -- '--data-binary' "$FAKE/call.1.args" | tail -n 1)"
if [[ "$body_arg" == @* ]] && jq -e '.model == "jev-latest" and (.questions | keys | length == 3) and (.state | type == "string")' "$FAKE/call.1.body" >/dev/null 2>&1; then
  ok "B5 本文はファイル経由（--data-binary @file）で model / questions / state を持つ"
else bad "B5 body arg: $body_arg"; fi
for k in JEV_MODEL=jev-1.13.0 JEV_INPUT_TOKENS=300 JEV_RETRIES=0 'ANSWER=dept|choice|billing|0.81' 'ANSWER=level|score|1.05|0.92'; do
  grep -qF "$k" <<<"$OUT" && ok "B6 出力行: $k" || bad "B6 出力行が無い: $k / $OUT"
done
if grep -q '^ANSWER=urgent|noul|0.95|0.9$' <<<"$OUT"; then
  ok "B7 noul の confidence は |p-0.5|*2 で派生（0.95 → 0.9）"
else bad "B7 noul confidence: $(printf '%s\n' "$OUT" | grep '^ANSWER=urgent')"; fi
cost="$(printf '%s\n' "$OUT" | sed -n 's/^JEV_COST_USD=//p')"
if [ -n "$cost" ] && jq -en --argjson c "$cost" '($c - 0.0000126 | if . < 0 then -. else . end) < 1e-12' >/dev/null 2>&1; then
  ok "B8 概算コスト = 300 tok × 0.042 / 1e6"
else bad "B8 cost: $(printf '%s\n' "$OUT" | grep '^JEV_COST')"; fi

reset_fake 200
run_judge_args FF_JEV_ENABLED=1 TYPESAFE_API_KEY_FILE="$KEY_FILE" -- --json --questions "$Q" --state-file "$STATE"
if [ "$RC" -eq 0 ] && printf '%s' "$OUT" | jq -e '
     .ok == true and .model == "jev-1.13.0" and (.latency_ms | type == "number")
     and .usage.input_tokens == 300 and .answers.dept.value == "billing"
     and .answers.dept.confidence == 0.81 and .answers.urgent.value == 0.95
     and (.input_bytes | type == "number") and .retries == 0' >/dev/null; then
  ok "B9 --json は 1 行 JSON（ok / model / answers.value / usage / latency_ms / retries / input_bytes）"
else bad "B9 json: rc=$RC out=$OUT"; fi
[ "$(printf '%s\n' "$OUT" | wc -l | tr -d ' ')" -eq 1 ] && ok "B10 --json は 1 行" || bad "B10 行数: $(printf '%s\n' "$OUT" | wc -l)"

# state が JSON object ならそのまま構造で渡す
reset_fake 200
printf '{"finding":"x","diff":"y"}' > "$WORK/state.json"
run_judge_args FF_JEV_ENABLED=1 TYPESAFE_API_KEY_FILE="$KEY_FILE" -- --questions "$Q" --state-file "$WORK/state.json"
body_arg="$(grep -A1 -x -- '--data-binary' "$FAKE/call.1.args" | tail -n 1)"
if [ "$RC" -eq 0 ] && jq -e '.state.finding == "x"' "$FAKE/call.1.body" >/dev/null 2>&1; then
  ok "B11 JSON の state は構造のまま渡る"
else bad "B11 rc=$RC"; fi
# stdin からの state
reset_fake 200
OUT="$( printf 'stdin state\n' | env -i HOME="$ISO_HOME" PATH="$FAKE/bin:$PATH" TMPDIR="$WORK" FAKE_CURL_DIR="$FAKE" \
        FF_JEV_ENABLED=1 TYPESAFE_API_KEY_FILE="$KEY_FILE" bash "$JUDGE" --questions "$Q" 2>/dev/null )"; RC=$?
[ "$RC" -eq 0 ] && ok "B12 state は stdin からも読める" || bad "B12 rc=$RC"

# ================================================================================
echo "== C. HTTP ステータスの種別と再試行 =="
for pair in "401:5:unauthorized" "422:6:unprocessable" "500:8:http-500"; do
  st="${pair%%:*}"; rest="${pair#*:}"; want="${rest%%:*}"; kind="${rest#*:}"
  reset_fake "$st"
  printf '{"error":"boom"}' > "$FAKE/body.$st"
  run_judge_args FF_JEV_ENABLED=1 TYPESAFE_API_KEY_FILE="$KEY_FILE" -- --questions "$Q" --state-file "$STATE"
  if [ "$RC" -eq "$want" ] && grep -q "^JEV_ERROR=${kind}$" <<<"$OUT" && [ "$(calls)" -eq 1 ]; then
    ok "C1 HTTP ${st} → exit ${want}（${kind}、再試行しない）"
  else bad "C1 HTTP $st: rc=$RC calls=$(calls) out=$OUT"; fi
done

reset_fake "429 retry-after=7" "529" "200"
run_judge_args FF_JEV_ENABLED=1 TYPESAFE_API_KEY_FILE="$KEY_FILE" FF_JEV_RETRY_BASE_SECONDS=1 -- --questions "$Q" --state-file "$STATE"
if [ "$RC" -eq 0 ] && grep -q '^JEV_RETRIES=2$' <<<"$OUT" && [ "$(calls)" -eq 3 ] \
   && [ "$(tr '\n' ' ' < "$FAKE/sleep.log")" = "7 2 " ]; then
  ok "C2 429(Retry-After 7) → 529 → 200: 待ちは 7 秒（ヘッダ優先）→ 2 秒（backoff 1<<1）で 2 回再試行して成功"
else bad "C2 retry: rc=$RC calls=$(calls) sleeps=$(tr '\n' ' ' < "$FAKE/sleep.log" 2>/dev/null) out=$OUT err=$ERR"; fi
reset_fake 429 429 429 200
run_judge_args FF_JEV_ENABLED=1 TYPESAFE_API_KEY_FILE="$KEY_FILE" FF_JEV_RETRY_BASE_SECONDS=1 -- --questions "$Q" --state-file "$STATE"
if [ "$RC" -eq 0 ] && [ "$(tr '\n' ' ' < "$FAKE/sleep.log")" = "1 2 4 " ]; then
  ok "C2b ヘッダ無しの連続 429 は 1, 2, 4 秒の指数バックオフ"
else bad "C2b sleeps=$(tr '\n' ' ' < "$FAKE/sleep.log" 2>/dev/null) rc=$RC"; fi
reset_fake "429 retry-after=999" 200
run_judge_args FF_JEV_ENABLED=1 TYPESAFE_API_KEY_FILE="$KEY_FILE" FF_JEV_MAX_RETRY_AFTER_SECONDS=5 -- --questions "$Q" --state-file "$STATE"
if [ "$RC" -eq 0 ] && [ "$(tr '\n' ' ' < "$FAKE/sleep.log")" = "5 " ]; then
  ok "C2c Retry-After 999 は FF_JEV_MAX_RETRY_AFTER_SECONDS=5 で頭打ち"
else bad "C2c sleeps=$(tr '\n' ' ' < "$FAKE/sleep.log" 2>/dev/null) rc=$RC"; fi

reset_fake 429 429 429 429 429 429 429
run_judge_args FF_JEV_ENABLED=1 TYPESAFE_API_KEY_FILE="$KEY_FILE" FF_JEV_RETRY_BASE_SECONDS=0 FF_JEV_MAX_RETRIES=2 -- --questions "$Q" --state-file "$STATE"
if [ "$RC" -eq 7 ] && grep -q '^JEV_ERROR=rate-limited$' <<<"$OUT" && [ "$(calls)" -eq 3 ]; then
  ok "C3 429 が続けば上限（FF_JEV_MAX_RETRIES=2 → 3 回呼んで）exit 7"
else bad "C3 exhaust: rc=$RC calls=$(calls) out=$OUT"; fi

reset_fake 200
printf '{"model":"jev-1.13.0","usage":{"input_tokens":1}}' > "$FAKE/body.200"
run_judge_args FF_JEV_ENABLED=1 TYPESAFE_API_KEY_FILE="$KEY_FILE" -- --questions "$Q" --state-file "$STATE"
if [ "$RC" -eq 9 ] && grep -q '^JEV_ERROR=bad-response$' <<<"$OUT"; then
  ok "C4 answers が無い 200 応答は exit 9（bad-response）"
else bad "C4 rc=$RC out=$OUT"; fi

reset_fake
run_judge_args FF_JEV_ENABLED=1 TYPESAFE_API_KEY_FILE="$KEY_FILE" -- --questions "$Q" --state-file "$STATE"
if [ "$RC" -eq 8 ] && grep -q '^JEV_ERROR=transport$' <<<"$OUT"; then
  ok "C5 curl 自体の失敗（応答なし）は exit 8（transport）"
else bad "C5 rc=$RC out=$OUT"; fi

# ================================================================================
echo "== D. 入力不正は通信しない =="
reset_fake 200
printf '[1,2]' > "$WORK/bad-q.json"
run_judge_args FF_JEV_ENABLED=1 TYPESAFE_API_KEY_FILE="$KEY_FILE" -- --questions "$WORK/bad-q.json" --state-file "$STATE"
[ "$RC" -eq 2 ] && [ "$(calls)" -eq 0 ] && ok "D1 questions が object でない → exit 2、通信なし" || bad "D1 rc=$RC calls=$(calls)"
reset_fake 200
printf '{"x":{"type":"essay","instructions":"?"}}' > "$WORK/bad-q.json"
run_judge_args FF_JEV_ENABLED=1 TYPESAFE_API_KEY_FILE="$KEY_FILE" -- --questions "$WORK/bad-q.json" --state-file "$STATE"
[ "$RC" -eq 2 ] && [ "$(calls)" -eq 0 ] && ok "D2 type が noul/choice/score 以外 → exit 2" || bad "D2 rc=$RC calls=$(calls)"
reset_fake 200
printf '   \n' > "$WORK/empty-state"
run_judge_args FF_JEV_ENABLED=1 TYPESAFE_API_KEY_FILE="$KEY_FILE" -- --questions "$Q" --state-file "$WORK/empty-state"
[ "$RC" -eq 2 ] && [ "$(calls)" -eq 0 ] && ok "D3 state が空白のみ → exit 2" || bad "D3 rc=$RC calls=$(calls)"
reset_fake 200
run_judge_args FF_JEV_ENABLED=1 TYPESAFE_API_KEY_FILE="$KEY_FILE" FF_JEV_MAX_STATE_BYTES=10 -- --questions "$Q" --state-file "$STATE"
if [ "$RC" -eq 2 ] && [ "$(calls)" -eq 0 ] && grep -q '^JEV_ERROR=over-budget$' <<<"$OUT" && grep -q 'FF_JEV_MAX_STATE_BYTES' <<<"$ERR"; then
  ok "D4 state + 最長 1 質問が予算超過 → exit 2（over-budget、上限の変数名を名乗る）"
else bad "D4 rc=$RC calls=$(calls) out=$OUT err=$ERR"; fi
reset_fake 200
run_judge_args FF_JEV_ENABLED=1 TYPESAFE_API_KEY_FILE="$KEY_FILE" FF_JEV_MAX_REQUEST_BYTES=10 -- --questions "$Q" --state-file "$STATE"
[ "$RC" -eq 2 ] && [ "$(calls)" -eq 0 ] && ok "D5 state + 全質問が予算超過 → exit 2" || bad "D5 rc=$RC calls=$(calls)"
run_judge_args FF_JEV_ENABLED=1 TYPESAFE_API_KEY_FILE="$KEY_FILE" -- --bogus
[ "$RC" -eq 64 ] && ok "D6 未知の引数 → exit 64" || bad "D6 rc=$RC"

# ================================================================================
echo "== E. 評価ハーネス =="
SET="$WORK/set.jsonl"
mk_case() { # $1=id $2=group $3=expected(JSON object)
  jq -cn --arg id "$1" --arg g "$2" --argjson exp "$3" --slurpfile q "$Q" \
    '{id:$id, group:$g, state:"case state", questions:$q[0], expected:$exp}'
}

: > "$WORK/empty.jsonl"
run_eval_args FF_JEV_ENABLED=1 TYPESAFE_API_KEY_FILE="$KEY_FILE" -- --set "$WORK/empty.jsonl"
if [ "$RC" -eq 2 ] && grep -q '評価セットが空です' <<<"$ERR"; then
  ok "E1 空の評価セット → exit 2（空を不一致なしへ倒さない。文言一致）"
else bad "E1 rc=$RC err=$ERR"; fi
run_eval_args FF_JEV_ENABLED=1 TYPESAFE_API_KEY_FILE="$KEY_FILE" -- --set "$WORK/nonexistent.jsonl"
[ "$RC" -eq 2 ] && ok "E1b 無いファイル → exit 2" || bad "E1b rc=$RC"

reset_fake 200 200 200
{ mk_case c1 en '{"dept":"billing"}'; echo 'this is not json'; mk_case c3 en '{"dept":"billing"}'; } > "$SET"
run_eval_args FF_JEV_ENABLED=1 TYPESAFE_API_KEY_FILE="$KEY_FILE" -- --set "$SET"
if [ "$RC" -eq 2 ] && grep -q '2 行目' <<<"$ERR" && [ "$(calls)" -eq 0 ]; then
  ok "E2 読めない行があれば行番号を名乗って 1 件も送らず exit 2"
else bad "E2 rc=$RC calls=$(calls) err=$ERR"; fi

reset_fake 200 200
{ mk_case c1 en '{"dept":"billing"}'; echo; mk_case c3 en '{"dept":"billing"}'; } > "$SET"
run_eval_args FF_JEV_ENABLED=1 TYPESAFE_API_KEY_FILE="$KEY_FILE" -- --set "$SET"
[ "$RC" -eq 2 ] && [ "$(calls)" -eq 0 ] && ok "E3 空行も exit 2（読み飛ばして 0 件を緑にしない）" || bad "E3 rc=$RC calls=$(calls)"

reset_fake 200
mk_case c1 en '{"nope":"billing"}' > "$SET"
run_eval_args FF_JEV_ENABLED=1 TYPESAFE_API_KEY_FILE="$KEY_FILE" -- --set "$SET"
[ "$RC" -eq 2 ] && [ "$(calls)" -eq 0 ] && ok "E4 expected の qid が questions に無い → exit 2" || bad "E4 rc=$RC calls=$(calls)"

mk_case c1 en '{"dept":"billing"}' > "$SET"
reset_fake 200
run_eval_args TYPESAFE_API_KEY_FILE="$KEY_FILE" -- --set "$SET"
[ "$RC" -eq 3 ] && [ "$(calls)" -eq 0 ] && ok "E5 無効（スイッチ Off）は exit 3 を伝える" || bad "E5 rc=$RC"
reset_fake 200
run_eval_args FF_JEV_ENABLED=1 -- --set "$SET"
[ "$RC" -eq 4 ] && [ "$(calls)" -eq 0 ] && ok "E6 キー未設定は exit 4 を伝える" || bad "E6 rc=$RC"

# 成功経路: 4 件（一致 / 不一致を混ぜる。score は文言 expected も含む）
{
  mk_case c1 en '{"dept":"billing","urgent":true,"level":1}'
  mk_case c2 en '{"dept":"technical"}'
  mk_case c3 ja '{"dept":"billing","level":"Frustrated"}'
  mk_case c4 ja '{"urgent":false}'
} > "$SET"
reset_fake 200 200 200 200
run_eval_args FF_JEV_ENABLED=1 TYPESAFE_API_KEY_FILE="$KEY_FILE" FF_JEV_INTERVAL_MS=0 -- --set "$SET" --out "$WORK/results.jsonl" --json
if [ "$RC" -eq 0 ] && [ "$(calls)" -eq 4 ] && printf '%s' "$OUT" | jq -e '
     .cases == 4 and .judgements == 7
     and .overall.matches == 5 and .overall.n == 7
     and (.by_group | map(select(.group == "en")) | .[0].n == 4 and .[0].matches == 3)
     and (.by_group | map(select(.group == "ja")) | .[0].n == 3 and .[0].matches == 2)
     and (.by_question | map(select(.qid == "dept")) | .[0].n == 3 and .[0].matches == 2)
     and (.by_confidence_band | map(select(.band == "[0.8,1.0]")) | .[0].n == 7)
     and (.by_confidence_band | length == 5)
     and .input_tokens == 1200 and (.latency_ms.p50 | type == "number") and (.latency_ms.p95 | type == "number")
     and (.cost_usd > 0) and .models == ["jev-1.13.0"]' >/dev/null; then
  ok "E7 --json 集計: 7 判定中 5 一致、group / 質問 id / confidence 帯別、p50/p95、トークン、コスト"
else bad "E7 rc=$RC calls=$(calls) out=$OUT err=$ERR"; fi
if [ "$(grep -c '' "$WORK/results.jsonl")" -eq 4 ] \
   && jq -e 'select(.id == "c2") | .answers[0].match == false and .answers[0].predicted == "billing" and .answers[0].expected == "technical"' "$WORK/results.jsonl" >/dev/null \
   && jq -e 'select(.id == "c3") | [.answers[] | select(.qid == "level")] | .[0].expected == 1 and .[0].match == true' "$WORK/results.jsonl" >/dev/null \
   && jq -e 'select(.id == "c4") | .answers[0].predicted == true and .answers[0].match == false' "$WORK/results.jsonl" >/dev/null; then
  ok "E8 --out は 1 件 1 行で expected / predicted / match を持つ（score の文言 expected は legend で番号へ）"
else bad "E8 results: $(cat "$WORK/results.jsonl")"; fi

reset_fake 200 200 200 200
run_eval_args FF_JEV_ENABLED=1 TYPESAFE_API_KEY_FILE="$KEY_FILE" FF_JEV_INTERVAL_MS=0 -- --set "$SET"
if [ "$RC" -eq 0 ] && grep -q '^- overall accuracy: 71.4% (5/7)$' <<<"$OUT" \
   && grep -q '^| \[0.8,1.0\] | 7 | 5 | 71.4% |$' <<<"$OUT" \
   && grep -q '^| ja | 3 | 2 | 66.7% |$' <<<"$OUT" \
   && grep -q '^- latency ms: p50 ' <<<"$OUT"; then
  ok "E9 既定出力は Markdown 表（overall / group 別 / confidence 帯別 / latency）"
else bad "E9 rc=$RC out=$OUT"; fi

reset_fake 200 401 200 200
run_eval_args FF_JEV_ENABLED=1 TYPESAFE_API_KEY_FILE="$KEY_FILE" FF_JEV_INTERVAL_MS=0 -- --set "$SET"
if [ "$RC" -eq 5 ] && ! grep -q 'overall accuracy' <<<"$OUT" && grep -q 'c2' <<<"$ERR"; then
  ok "E10 途中 1 件の判定失敗（401）は集計せず exit 5 を伝え、case id を名乗る"
else bad "E10 rc=$RC out=$OUT err=$ERR"; fi

reset_fake 200 200 200 200
run_eval_args FF_JEV_ENABLED=1 TYPESAFE_API_KEY_FILE="$KEY_FILE" FF_JEV_INTERVAL_MS=0 -- --set "$SET" --limit 2 --json
[ "$RC" -eq 0 ] && [ "$(calls)" -eq 2 ] && printf '%s' "$OUT" | jq -e '.cases == 2' >/dev/null && ok "E11 --limit 2 は 2 件だけ送る" || bad "E11 rc=$RC calls=$(calls)"


# ================================================================================
echo "== G. 判定不能が成功 / 不一致へ化ける経路（レビュー指摘の固定）=="
# G1〜G4: 応答の形が契約と違えば exit 9（要求 qid の欠落 / type 不一致 / 値の型不正）
for pair in \
  'G1 answers が空|{"model":"m","answers":{},"usage":{"input_tokens":1}}' \
  'G2 要求 qid の一部欠落|{"model":"m","answers":{"dept":{"type":"choice","choice":"billing","probabilities":{"billing":1},"confidence":1},"level":{"type":"score","score":1,"legend":{"0":"a","1":"b","2":"c"},"probabilities":{"1":1},"confidence":1}},"usage":{"input_tokens":1}}' \
  'G3 type 不一致（dept が noul）|{"model":"m","answers":{"dept":{"type":"noul","noul":0.5},"urgent":{"type":"noul","noul":0.5},"level":{"type":"score","score":1,"legend":{"0":"a","1":"b","2":"c"},"probabilities":{"1":1},"confidence":1}},"usage":{"input_tokens":1}}' \
  'G4 noul の値が文字列|{"model":"m","answers":{"dept":{"type":"choice","choice":"billing","probabilities":{"billing":1},"confidence":1},"urgent":{"type":"noul","noul":"bad"},"level":{"type":"score","score":1,"legend":{"0":"a","1":"b","2":"c"},"probabilities":{"1":1},"confidence":1}},"usage":{"input_tokens":1}}'; do
  label="${pair%%|*}"; body="${pair#*|}"
  reset_fake 200
  printf '%s' "$body" > "$FAKE/body.200"
  run_judge_args FF_JEV_ENABLED=1 TYPESAFE_API_KEY_FILE="$KEY_FILE" -- --json --questions "$Q" --state-file "$STATE"
  if [ "$RC" -eq 9 ] && printf '%s' "$OUT" | jq -e '.ok == false and .error == "bad-response"' >/dev/null 2>&1; then
    ok "${label} → exit 9（bad-response、--json でも ok:false）"
  else bad "${label}: rc=$RC out=$OUT"; fi
done

reset_fake 200
run_judge_args FF_JEV_ENABLED=1 TYPESAFE_API_KEY="k1
url = http://attacker.invalid/" -- --questions "$Q" --state-file "$STATE"
if [ "$RC" -eq 4 ] && grep -q '^JEV_ERROR=key-invalid$' <<<"$OUT" && [ "$(calls)" -eq 0 ]; then
  ok "G5 改行を含むキーは curl 設定へ差し込まず exit 4（key-invalid、通信なし）"
else bad "G5 rc=$RC calls=$(calls) out=$OUT"; fi
reset_fake 200
run_judge_args FF_JEV_ENABLED=1 TYPESAFE_API_KEY='k"1' -- --questions "$Q" --state-file "$STATE"
[ "$RC" -eq 4 ] && [ "$(calls)" -eq 0 ] && ok "G5b 引用符を含むキーも exit 4" || bad "G5b rc=$RC calls=$(calls)"

reset_fake 200
printf '  %s  \r\n' "$FAKE_KEY" > "$WORK/key-spaces"
run_judge_args FF_JEV_ENABLED=1 TYPESAFE_API_KEY_FILE="$WORK/key-spaces" -- --questions "$Q" --state-file "$STATE"
if [ "$RC" -eq 0 ] && grep -q "^header = \"Authorization: Bearer ${FAKE_KEY}\"$" "$FAKE/call.1.config"; then
  ok "G6 キーファイルの前後空白と CRLF は落として送る"
else bad "G6 rc=$RC config=$(sed 's/Bearer .*/Bearer <redacted>/' "$FAKE/call.1.config" 2>/dev/null)"; fi

reset_fake 200
printf '%s\n' "$FAKE_KEY" > "$WORK/key-000"; chmod 000 "$WORK/key-000"
run_judge_args FF_JEV_ENABLED=1 TYPESAFE_API_KEY_FILE="$WORK/key-000" -- --questions "$Q" --state-file "$STATE"
if [ "$RC" -eq 4 ] && grep -q '読めません' <<<"$ERR" && grep -q 'key-000' <<<"$ERR" && [ "$(calls)" -eq 0 ]; then
  ok "G7 読めないキーファイル（000）は「無い」ではなく「読めません」とパスを名指しして exit 4"
else bad "G7 rc=$RC err=$ERR"; fi
chmod 600 "$WORK/key-000"

reset_fake 200
mkdir -p "$ISO_HOME/.config/ff-dev-toolkit"
printf '%s\n' "$FAKE_KEY" > "$ISO_HOME/.config/ff-dev-toolkit/typesafe_api_key"
run_judge_args FF_JEV_ENABLED=1 TYPESAFE_API_KEY_FILE="$WORK/no-such-key" -- --questions "$Q" --state-file "$STATE"
if [ "$RC" -eq 4 ] && grep -q 'no-such-key' <<<"$ERR" && [ "$(calls)" -eq 0 ]; then
  ok "G8 TYPESAFE_API_KEY_FILE が無いときは既定パスへ落ちず、指定パスを名指しして exit 4"
else bad "G8 rc=$RC calls=$(calls) err=$ERR"; fi
rm -rf "$ISO_HOME/.config"

for v in FF_JEV_MAX_RETRIES=abc FF_JEV_RETRY_BASE_SECONDS=-1 FF_JEV_MAX_STATE_BYTES=1e5 FF_JEV_MAX_RETRY_AFTER_SECONDS=1.5; do
  reset_fake 200
  run_judge_args FF_JEV_ENABLED=1 TYPESAFE_API_KEY_FILE="$KEY_FILE" "$v" -- --questions "$Q" --state-file "$STATE"
  if [ "$RC" -eq 64 ] && grep -q '^JEV_ERROR=bad-config$' <<<"$OUT" && [ "$(calls)" -eq 0 ]; then
    ok "G9 ${v%%=*} が非数値 → exit 64（上限なしへ倒さない）"
  else bad "G9 $v: rc=$RC calls=$(calls)"; fi
done

# G10: バイト予算は文字数でなくバイト。日本語 40 文字（120 バイト）の質問 + 小さな state を
# 上限 100 バイトに掛けると、文字数（約 70）なら通り、バイト（約 150）なら赤になる
reset_fake 200
cat > "$WORK/q-ja.json" <<'EOF'
{ "sev": { "type": "choice", "instructions": "この指摘の重大度を四段階で分類してくださいこの指摘の重大度を四段階で分類", "criteria": { "a": null, "b": null } } }
EOF
printf 'x' > "$WORK/state-tiny"
run_judge_args FF_JEV_ENABLED=1 TYPESAFE_API_KEY_FILE="$KEY_FILE" FF_JEV_MAX_STATE_BYTES=100 FF_JEV_MAX_REQUEST_BYTES=100000 -- --questions "$WORK/q-ja.json" --state-file "$WORK/state-tiny"
if [ "$RC" -eq 2 ] && grep -q '^JEV_ERROR=over-budget$' <<<"$OUT" && [ "$(calls)" -eq 0 ]; then
  ok "G10 日本語の質問はバイトで数えて予算超過（文字数で数えると素通りする）"
else bad "G10 rc=$RC calls=$(calls) out=$OUT err=$ERR"; fi

reset_fake 200
printf '{"d":{"type":"choice","instructions":"?","criteria":{"a|b":null,"c":null}}}' > "$WORK/q-pipe.json"
run_judge_args FF_JEV_ENABLED=1 TYPESAFE_API_KEY_FILE="$KEY_FILE" -- --questions "$WORK/q-pipe.json" --state-file "$STATE"
[ "$RC" -eq 2 ] && [ "$(calls)" -eq 0 ] && ok "G11 option 名の | は ANSWER 行と衝突するため exit 2" || bad "G11 rc=$RC calls=$(calls)"

# ---- ハーネス側 ----
for pair in \
  'G12 choice の expected が criteria に無い|{"dept":"legal"}' \
  'G13 score の expected 文言が criteria に無い|{"level":"Furious"}' \
  'G14 noul の expected が boolean でない|{"urgent":1}' \
  'G15 score の expected が object|{"level":{}}' \
  'G16 score の expected がレベル範囲外|{"level":7}'; do
  label="${pair%%|*}"; exp="${pair#*|}"
  reset_fake 200
  mk_case c1 en "$exp" > "$SET"
  run_eval_args FF_JEV_ENABLED=1 TYPESAFE_API_KEY_FILE="$KEY_FILE" -- --set "$SET"
  if [ "$RC" -eq 2 ] && grep -q '1 行目' <<<"$ERR" && [ "$(calls)" -eq 0 ]; then
    ok "${label} → 通信前に exit 2（行番号を名乗る）"
  else bad "${label}: rc=$RC calls=$(calls) err=$ERR"; fi
done
for st in 'null' '42'; do
  reset_fake 200
  jq -cn --argjson st "$st" --slurpfile q "$Q" '{id:"c1", state:$st, questions:$q[0], expected:{dept:"billing"}}' > "$SET"
  run_eval_args FF_JEV_ENABLED=1 TYPESAFE_API_KEY_FILE="$KEY_FILE" -- --set "$SET"
  [ "$RC" -eq 2 ] && [ "$(calls)" -eq 0 ] && ok "G17 state が ${st} → 通信前に exit 2" || bad "G17 state=$st rc=$RC calls=$(calls)"
done
reset_fake 200 200
{ mk_case c1 en '{"dept":"billing"}'; printf '{"id":"c2","state":"s","questions":{"x":{"type":"essay","instructions":"?"}},"expected":{"x":"y"}}\n'; } > "$SET"
run_eval_args FF_JEV_ENABLED=1 TYPESAFE_API_KEY_FILE="$KEY_FILE" -- --set "$SET"
if [ "$RC" -eq 2 ] && grep -q '2 行目' <<<"$ERR" && [ "$(calls)" -eq 0 ]; then
  ok "G18 2 行目の questions 不正でも 1 行目を送らない（事前検証は全行）"
else bad "G18 rc=$RC calls=$(calls) err=$ERR"; fi

mk_case c1 en '{"dept":"billing"}' > "$SET"
reset_fake 200
run_eval_args FF_JEV_ENABLED=1 TYPESAFE_API_KEY_FILE="$KEY_FILE" FF_JEV_INTERVAL_MS=0 -- --set "$SET" --out "$WORK/no-such-dir/r.jsonl"
if [ "$RC" -eq 2 ] && ! grep -q 'overall accuracy' <<<"$OUT" && grep -q -- '--out' <<<"$ERR"; then
  ok "G19 --out へ書けなければ集計を出さず exit 2"
else bad "G19 rc=$RC out=$OUT err=$ERR"; fi
reset_fake 200
run_eval_args FF_JEV_ENABLED=1 TYPESAFE_API_KEY_FILE="$KEY_FILE" -- --set "$SET" --limit abc
[ "$RC" -eq 64 ] && [ "$(calls)" -eq 0 ] && ok "G20 --limit abc → exit 64（全件送信へ倒さない）" || bad "G20 rc=$RC calls=$(calls)"
reset_fake 200
run_eval_args FF_JEV_ENABLED=1 TYPESAFE_API_KEY_FILE="$KEY_FILE" FF_JEV_INTERVAL_MS=abc -- --set "$SET"
[ "$RC" -eq 64 ] && [ "$(calls)" -eq 0 ] && ok "G21 FF_JEV_INTERVAL_MS=abc → exit 64（レート制御を黙って無効化しない）" || bad "G21 rc=$RC calls=$(calls)"

# G22: 応答に expected の qid が無い形は判定側で exit 9 になり、ハーネスは集計せず 9 を伝える
reset_fake 200
printf '%s' '{"model":"m","answers":{"dept":{"type":"choice","choice":"billing","probabilities":{"billing":1},"confidence":1},"level":{"type":"score","score":1,"legend":{"0":"a","1":"b","2":"c"},"probabilities":{"1":1},"confidence":1}},"usage":{"input_tokens":1}}' > "$FAKE/body.200"
mk_case c1 en '{"urgent":true}' > "$SET"
run_eval_args FF_JEV_ENABLED=1 TYPESAFE_API_KEY_FILE="$KEY_FILE" FF_JEV_INTERVAL_MS=0 -- --set "$SET"
if [ "$RC" -eq 9 ] && ! grep -q 'overall accuracy' <<<"$OUT" && grep -q 'c1' <<<"$ERR"; then
  ok "G22 応答に expected の qid が無い → 集計せず exit 9（不一致に計上しない）"
else bad "G22 rc=$RC out=$OUT err=$ERR"; fi

# G23: 低 confidence の不一致は該当帯へ計上される（較正表の意味）
reset_fake 200 200
printf '%s' '{"model":"m","answers":{"dept":{"type":"choice","choice":"technical","probabilities":{"billing":0.35,"technical":0.65},"confidence":0.3},"urgent":{"type":"noul","noul":0.6},"level":{"type":"score","score":1,"legend":{"0":"Calm","1":"Frustrated","2":"Very angry"},"probabilities":{"1":1},"confidence":0.19}},"usage":{"input_tokens":10}}' > "$FAKE/body.200"
{ mk_case c1 en '{"dept":"billing","urgent":true,"level":1}'; } > "$SET"
run_eval_args FF_JEV_ENABLED=1 TYPESAFE_API_KEY_FILE="$KEY_FILE" FF_JEV_INTERVAL_MS=0 -- --set "$SET" --json
if [ "$RC" -eq 0 ] && printf '%s' "$OUT" | jq -e '
     (.by_confidence_band | map(select(.band == "[0.2,0.4)")) | .[0].n == 2 and .[0].matches == 1)
     and (.by_confidence_band | map(select(.band == "[0.0,0.2)")) | .[0].n == 1 and .[0].matches == 1)
     and .overall.n == 3 and .overall.matches == 2' >/dev/null; then
  ok "G23 confidence 0.3 の不一致と 0.2（noul 0.6）の一致は [0.2,0.4) へ、0.19 は [0.0,0.2) へ計上"
else bad "G23 rc=$RC out=$OUT err=$ERR"; fi


# ================================================================================
echo "== H. ACE 評価セット生成器（合成 fixture で期待値まで固定 + 実 PLAYBOOK の構造検査）=="
GEN="$PLUGIN_ROOT/scripts/jev/build-ace-eval-sets.ts"
RUNNER="$PLUGIN_ROOT/scripts/ace-run-ts.sh"
LABELS="$PLUGIN_ROOT/scripts/jev/fixtures/ace-abstraction-labels.json"
PLAYBOOK_REAL="$PLUGIN_ROOT/../../docs/08-knowledge/PLAYBOOK.md"
gen() { # $@=引数。stdout→${OUT} rc→${RC}（stderr は ${ERR}）
  OUT="$(FF_DEV_TOOLKIT_ROOT="$PLUGIN_ROOT" bash "$RUNNER" "$GEN" "$@" 2>"$WORK/gen.err")"; RC=$?
  ERR="$(cat "$WORK/gen.err")"
}
# 合成 Playbook: 5 compact（日付 D1<D2<D3<D4、同日の PR 差あり）+ legacy 1 + archive 1。
# Changelog は 2 版（新→旧）。版 A（D3 / PR 30）: 追加 ACE-30-1・Helpful ACE-10-1。版 B（D2 / PR 20）: 追加 ACE-20-1
SYN="$WORK/synth"; mkdir -p "$SYN/playbook/archive"
mk_entry() { # $1=id $2=date $3=pr $4=title $5=body
  printf '<a id="%s"></a>\n\n### %s: %s\n\n| Category | testing | Origin | PR #%s |\n| Date | %s |\n| Helpful | 0 | Harmful | 0 |\n| Status | active |\n\n%s\n\n---\n\n' "$(printf '%s' "$1" | tr 'A-Z' 'a-z')" "$1" "$4" "$3" "$2" "$5"
}
{
  printf '# testing\n\n'
  mk_entry ACE-10-1 2026-01-01 10 "針の変異は赤の件数まで数える" "変異を当てたら赤になった件数を針の本数と照合する。少なければ重複針を疑う。"
  mk_entry ACE-10-2 2026-01-01 10 "fixture は境界の両側を持つ" "閾値の端ちょうどと外側の 4 点を fixture に置き、片側だけの検査にしない。"
  mk_entry ACE-20-1 2026-02-01 20 "検査総数を baseline で縛る" "針ごとの変異は検査そのものの消失を検出できないので、実行検査数を baseline と照合する。"
  mk_entry ACE-30-1 2026-03-01 30 "赤の件数と針の本数の不一致は重複針を指す" "対象を丸ごと壊した変異の赤が針の本数より少ないなら、対象の外にも一致する針がある。"
  mk_entry ACE-40-1 2026-04-01 40 "未来のエントリ" "版 A より後に追加された語彙一致の高いエントリ。針 変異 赤 件数 重複針。"
  printf '### ACE-5-9: 旧形式のエントリ\n\n| フィールド | 値 |\n| --- | --- |\n| Category | testing |\n| Insight | 旧テーブル形式 |\n\n---\n'
} > "$SYN/playbook/testing.md"
mk_entry ACE-1-1 2025-12-01 1 "アーカイブ済み" "archive 配下は母集団に入らない。" > "$SYN/playbook/archive/testing.md"
# Issue / PR の番号短縮形は公開対象の追加行に書けない（sync-forbidden-patterns）ので、記号を printf の引数で差し込む
{
  printf '# PLAYBOOK\n\n## エントリ一覧\n\n| エントリID | タイトル | Category | 参照先 |\n| --- | --- | --- | --- |\n\n## Changelog\n\n'
  printf '### [1.2.0] - 2026-03-01\n\n#### 追加\n\n- ACE-30-1: 赤の件数と針の本数の不一致は重複針を指す（Issue %s29 / PR %s30）。ACE-9-9 を deprecated に変更\n\n' '#' '#'
  printf '#### カウンター更新\n\n- ACE-10-1: Helpful +1（変異で赤になった件数を針の本数と照合し、重複針を 1 本見つけた）\n\n'
  printf '### [1.1.0] - 2026-02-01\n\n#### 追加\n\n- ACE-20-1: 検査総数を baseline で縛る（Issue %s19 / PR %s20）\n' '#' '#'
} > "$SYN/PLAYBOOK.md"
if [ ! -f "$GEN" ] || [ ! -f "$LABELS" ]; then
  bad "H0 生成器またはラベル fixture がありません: $GEN / $LABELS"
else
  gen --playbook "$SYN/PLAYBOOK.md" --out "$WORK/syn1" --recent-versions 2 --neighbors 2
  if [ "$RC" -eq 3 ]; then
    echo "  ○ skip: tsx ランナーを起動できないため H 節を実行していません（${ERR}）"
  else
    if [ "$RC" -eq 0 ] && grep -q '^entries=6 legacy=1 versions=2 added=2 helpful=1 novelty=2 helpful_dropped=0 unpaired=0 recent=6 added_from_summary=0 recent_helpful_dropped=0 abstraction=0$' <<<"$OUT"; then
      ok "H1 合成 Playbook: entries 6（legacy 1・archive 除外）/ 版 2 / 追加 2 / Helpful 1 / novelty 2 / recent 6"
    else bad "H1 rc=$RC out=$OUT err=$ERR"; fi
    # novelty: 正例は ACE-10-1、負例は同カテゴリの別エントリ。pair ごとに pos / neg が 1 件ずつ
    if jq -e 'select(.group=="pos") | .state.id=="ACE-10-1" and .expected.same_action==true and (.questions.same_action.instructions.candidate|test("重複針"))' "$WORK/syn1/novelty-pairs.jsonl" >/dev/null 2>&1 \
       && jq -e 'select(.group=="neg") | .state.id!="ACE-10-1" and .state.category=="testing" and .expected.same_action==false' "$WORK/syn1/novelty-pairs.jsonl" >/dev/null 2>&1 \
       && [ "$(jq -r '[.pair,.group]|@tsv' "$WORK/syn1/novelty-pairs.jsonl" | sort | uniq | awk '{print $1}' | sort | uniq -c | awk '$1!=2' | wc -l | tr -d ' ')" -eq 0 ]; then
      ok "H2 novelty: 正例 = Helpful 行の参照先 + 理由文、負例 = 同カテゴリの別エントリ、各 pair に pos / neg が厳密に 1 件ずつ"
    else bad "H2 novelty の形: $(cat "$WORK/syn1/novelty-pairs.jsonl" | cut -c1-200)"; fi
    # recent: 版 A の追加（30-1）は D3 より前の 3 件から 2 近傍・全 false / Helpful（10-1）は参照先 true + 近傍 1 件 false /
    # 版 B の追加（20-1）は D2 より前の 2 件 / 未来の ACE-40-1 はどこにも出ない / 近傍の日付は版の日付以下
    if [ "$(jq -r 'select(.group=="added" and .expected.same_action==true) | .id' "$WORK/syn1/recent-candidates.jsonl" | wc -l | tr -d ' ')" -eq 0 ] \
       && [ "$(jq -r 'select(.candidate|startswith("helpful-ACE-10-1")) | select(.expected.same_action==true) | .neighbor' "$WORK/syn1/recent-candidates.jsonl" | tr '\n' ' ')" = "ACE-10-1 " ] \
       && [ "$(jq -r 'select(.candidate|startswith("helpful-ACE-10-1")) | select(.expected.same_action==false) | .neighbor' "$WORK/syn1/recent-candidates.jsonl" | grep -cE '^ACE-(10-2|20-1)$')" -eq 1 ] \
       && [ "$(jq -r 'select(.candidate=="ACE-30-1") | .neighbor' "$WORK/syn1/recent-candidates.jsonl" | wc -l | tr -d ' ')" -eq 2 ] \
       && [ "$(jq -r 'select(.candidate=="ACE-20-1") | .neighbor' "$WORK/syn1/recent-candidates.jsonl" | sort | tr '\n' ' ')" = "ACE-10-1 ACE-10-2 " ] \
       && ! grep -q 'ACE-40-1' "$WORK/syn1/recent-candidates.jsonl" \
       && [ "$(jq -r 'select(.neighbor_date > .version_date) | .id' "$WORK/syn1/recent-candidates.jsonl" | wc -l | tr -d ' ')" -eq 0 ] \
       && [ "$(jq -r '.candidate' "$WORK/syn1/recent-candidates.jsonl" | sort | uniq -c | awk '$1!=2' | wc -l | tr -d ' ')" -eq 0 ]; then
      ok "H3 recent: 追加は全 false・Helpful は参照先だけ true・近傍は版より前のエントリだけ（未来の ACE-40-1 は出ない）・各候補 K=2 件"
    else bad "H3 recent の形: $(jq -c '{c:.candidate,n:.neighbor,e:.expected}' "$WORK/syn1/recent-candidates.jsonl" | tr '\n' ' ')"; fi
    # 同日の境界: 版 B と同日（D2）の追加 ACE-20-1 自身は版 B の近傍に出ない（Origin PR 20 は versionPr 20 より小さくない）
    grep -q '"candidate":"ACE-20-1"' "$WORK/syn1/recent-candidates.jsonl" && [ -z "$(jq -r 'select(.version=="1.1.0") | select(.neighbor=="ACE-20-1") | .id' "$WORK/syn1/recent-candidates.jsonl")" ] \
      && ok "H4 同日のエントリは Origin PR が小さい側だけを「前」とみなす" || bad "H4 同日境界"
    gen --playbook "$SYN/PLAYBOOK.md" --out "$WORK/syn2" --recent-versions 2 --neighbors 2
    cmp -s "$WORK/syn1/novelty-pairs.jsonl" "$WORK/syn2/novelty-pairs.jsonl" && cmp -s "$WORK/syn1/recent-candidates.jsonl" "$WORK/syn2/recent-candidates.jsonl" \
      && ok "H5 同じ入力で 2 回生成してバイト同一（決定性）" || bad "H5 生成結果が実行ごとに変わる"
    # 抽象度: レポート（候補 = 10-1, 20-1）+ ラベル → candidate 2 / non-candidate 2、expected はラベルどおり、候補 ID は非候補に出ない
    printf '{"candidates":[{"id":"ACE-20-1","format":"compact"},{"id":"ACE-10-1","format":"compact"},{"id":"ACE-5-9","format":"legacy"}]}' > "$WORK/syn-report.json"
    printf '{"ACE-10-1":{"deficient":true},"ACE-20-1":{"deficient":false},"ACE-10-2":{"deficient":false},"ACE-30-1":{"deficient":true},"ACE-40-1":{"deficient":false}}' > "$WORK/syn-labels.json"
    gen --playbook "$SYN/PLAYBOOK.md" --out "$WORK/syn3" --recent-versions 2 --neighbors 2 --abstraction-report "$WORK/syn-report.json" --labels "$WORK/syn-labels.json" --candidates 5 --non-candidates 2
    if [ "$RC" -eq 0 ] && [ "$(jq -r '[.group,.state.id,.expected.abstraction_deficient]|@tsv' "$WORK/syn3/abstraction.jsonl" | sort | tr '\n' ' ')" = "candidate	ACE-10-1	true candidate	ACE-20-1	false non-candidate	ACE-10-2	false non-candidate	ACE-30-1	true " ]; then
      ok "H6 abstraction: compact 候補だけが candidate、非候補は候補集合の外から等間隔、expected はラベル fixture どおり"
    else bad "H6 rc=$RC rows=$(cat "$WORK/syn3/abstraction.jsonl" 2>/dev/null | jq -c '[.group,.state.id,.expected]' | tr '\n' ' ') err=$ERR"; fi
    gen --playbook "$SYN/PLAYBOOK.md" --out "$WORK/syn4" --recent-versions 2 --neighbors 2 --abstraction-report "$WORK/syn-report.json" --labels "$WORK/syn-labels.json" --candidates 5 --non-candidates 2
    cmp -s "$WORK/syn3/abstraction.jsonl" "$WORK/syn4/abstraction.jsonl" && ok "H7 abstraction も決定的" || bad "H7 abstraction が実行ごとに変わる"
    # fail-closed の経路
    printf '{"ACE-20-1":{"deficient":false}}' > "$WORK/syn-labels-short.json"
    gen --playbook "$SYN/PLAYBOOK.md" --out "$WORK/syn5" --abstraction-report "$WORK/syn-report.json" --labels "$WORK/syn-labels-short.json"
    [ "$RC" -eq 2 ] && grep -q 'ACE-10-1' <<<"$ERR" && ok "H8 精読ラベルの無い ID は exit 2 で名指し" || bad "H8 rc=$RC err=$ERR"
    printf '{}' > "$WORK/syn-report-bad.json"
    gen --playbook "$SYN/PLAYBOOK.md" --out "$WORK/syn5" --abstraction-report "$WORK/syn-report-bad.json" --labels "$WORK/syn-labels.json"
    [ "$RC" -eq 2 ] && grep -q 'candidates' <<<"$ERR" && ok "H9 candidates の無いレポートは exit 2（空候補で成功にしない）" || bad "H9 rc=$RC err=$ERR"
    printf '{"candidates":[{"id":"ACE-99-9","format":"compact"}]}' > "$WORK/syn-report-ghost.json"
    gen --playbook "$SYN/PLAYBOOK.md" --out "$WORK/syn5" --abstraction-report "$WORK/syn-report-ghost.json" --labels "$WORK/syn-labels.json"
    [ "$RC" -eq 2 ] && grep -q 'ACE-99-9' <<<"$ERR" && ok "H10 Playbook に無い候補 ID は exit 2 で名指し" || bad "H10 rc=$RC err=$ERR"
    gen --playbook "$SYN/PLAYBOOK.md" --out "$WORK/syn5" --abstraction-report "$WORK/syn-report.json"
    [ "$RC" -eq 2 ] && ok "H11 --abstraction-report だけ（--labels 無し）は exit 2" || bad "H11 rc=$RC"
    for v in "--neighbors x" "--recent-versions 0" "--novelty-sample -1"; do
      # shellcheck disable=SC2086
      gen --playbook "$SYN/PLAYBOOK.md" --out "$WORK/syn5" $v
      [ "$RC" -eq 2 ] && ok "H12 数値オプションの不正（${v}）は exit 2" || bad "H12 $v rc=$RC"
    done
    mkdir -p "$WORK/nochangelog/playbook"; printf '# PLAYBOOK\n' > "$WORK/nochangelog/PLAYBOOK.md"; cp "$SYN/playbook/testing.md" "$WORK/nochangelog/playbook/"
    gen --playbook "$WORK/nochangelog/PLAYBOOK.md" --out "$WORK/syn6"
    [ "$RC" -eq 2 ] && grep -q 'Changelog がありません' <<<"$ERR" && ok "H13 Changelog の無い PLAYBOOK → exit 2（文言一致）" || bad "H13 rc=$RC err=$ERR"
    mkdir -p "$WORK/drift/playbook"; cp "$SYN/playbook/testing.md" "$WORK/drift/playbook/"; sed 's/^#### 追加/#### Added/; s/^#### カウンター更新/#### Counters/' "$SYN/PLAYBOOK.md" > "$WORK/drift/PLAYBOOK.md"
    gen --playbook "$WORK/drift/PLAYBOOK.md" --out "$WORK/syn7"
    [ "$RC" -eq 2 ] && grep -q '1 件も読めません' <<<"$ERR" && ok "H14 Changelog の見出し形式が変わって行が 1 件も読めない → exit 2（0 件を成功にしない）" || bad "H14 rc=$RC err=$ERR"
    mkdir -p "$WORK/badhelp/playbook"; cp "$SYN/playbook/testing.md" "$WORK/badhelp/playbook/"; sed 's/^- ACE-10-1: Helpful +1（/- ACE-10-1: Helpful +1 (/' "$SYN/PLAYBOOK.md" > "$WORK/badhelp/PLAYBOOK.md"
    gen --playbook "$WORK/badhelp/PLAYBOOK.md" --out "$WORK/syn8"
    [ "$RC" -eq 2 ] && grep -q 'Helpful +1' <<<"$ERR" && ok "H15 Helpful +1 を含むのに契約の形で読めない行は exit 2（黙って落とさない）" || bad "H15 rc=$RC err=$ERR"
    mkdir -p "$WORK/nodate/playbook"; cp "$SYN/PLAYBOOK.md" "$WORK/nodate/"; sed '/^| Date | 2026-02-01 |$/d' "$SYN/playbook/testing.md" > "$WORK/nodate/playbook/testing.md"
    gen --playbook "$WORK/nodate/PLAYBOOK.md" --out "$WORK/syn9"
    [ "$RC" -eq 2 ] && grep -q 'Date' <<<"$ERR" && ok "H16 Date を読めない compact エントリは exit 2（時点境界の材料を欠いたまま近傍に使わない）" || bad "H16 rc=$RC err=$ERR"
    # --summarize（recent）: 一致 / 厳しい / 参照先違い / 緩い の 4 区分と、id 形式外の行・欠落 answers の拒否
    cat > "$WORK/rec-results.jsonl" <<'EOF'
{"id":"rec-1.0.0-ACE-9-1-vs-ACE-1-1","group":"added","answers":[{"qid":"same_action","expected":false,"predicted":false,"raw":0.1}]}
{"id":"rec-1.0.0-ACE-9-1-vs-ACE-2-1","group":"added","answers":[{"qid":"same_action","expected":false,"predicted":true,"raw":0.8}]}
{"id":"rec-1.0.0-helpful-ACE-3-1-ab-vs-ACE-3-1","group":"helpful","answers":[{"qid":"same_action","expected":true,"predicted":true,"raw":0.9}]}
{"id":"rec-1.0.0-helpful-ACE-3-1-ab-vs-ACE-4-1","group":"helpful","answers":[{"qid":"same_action","expected":false,"predicted":false,"raw":0.2}]}
{"id":"rec-1.0.0-helpful-ACE-5-1-cd-vs-ACE-5-1","group":"helpful","answers":[{"qid":"same_action","expected":true,"predicted":true,"raw":0.4}]}
{"id":"rec-1.0.0-helpful-ACE-5-1-cd-vs-ACE-6-1","group":"helpful","answers":[{"qid":"same_action","expected":false,"predicted":true,"raw":0.9}]}
{"id":"rec-1.0.0-helpful-ACE-i7-1-ef-vs-ACE-i7-1","group":"helpful","answers":[{"qid":"same_action","expected":true,"predicted":false,"raw":0.3}]}
EOF
    gen --summarize "$WORK/rec-results.jsonl" --kind recent
    if [ "$RC" -eq 0 ] && grep -q '候補 4 件 / 一致 1 / Jev が「同一」側に厳しい 1 / Jev が「新規」側に緩い 1 / 同一だが参照先が違う 1' <<<"$OUT" \
       && grep -q '| 1.0.0:helpful-ACE-5-1-cd | 同一（ACE-5-1） | 同一（0.90 → ACE-6-1） | ⚠️ |' <<<"$OUT"; then
      ok "H17 --summarize recent: 評価時の predicted で判定し、参照先違いを別区分に数える（i 接頭辞 ID も可）"
    else bad "H17 rc=$RC out=$OUT err=$ERR"; fi
    printf '{"id":"bogus","answers":[{"expected":false,"predicted":false,"raw":0.1}]}\n' >> "$WORK/rec-results.jsonl"
    gen --summarize "$WORK/rec-results.jsonl" --kind recent
    [ "$RC" -eq 2 ] && grep -q 'bogus' <<<"$ERR" && ok "H18 id の形が契約外の行は集計せず exit 2 で名指し" || bad "H18 rc=$RC err=$ERR"
    printf '{"id":"rec-1.0.0-ACE-9-1-vs-ACE-1-1"}\n' > "$WORK/rec-bad.jsonl"
    gen --summarize "$WORK/rec-bad.jsonl" --kind recent
    [ "$RC" -eq 2 ] && ok "H19 answers の無い結果行は exit 2（TypeError で落ちない）" || bad "H19 rc=$RC"
    cat > "$WORK/abs-results.jsonl" <<'EOF'
{"id":"abs-ACE-1","group":"candidate","answers":[{"qid":"abstraction_deficient","expected":true,"predicted":false}]}
{"id":"abs-ACE-2","group":"candidate","answers":[{"qid":"abstraction_deficient","expected":false,"predicted":false}]}
{"id":"abs-ACE-3","group":"non-candidate","answers":[{"qid":"abstraction_deficient","expected":true,"predicted":false}]}
EOF
    gen --summarize "$WORK/abs-results.jsonl" --kind abstraction
    if [ "$RC" -eq 0 ] && grep -q '| 機械シグナル（候補 = 抽象度不足） | 50.0% | 50.0% | 1 / 1 / 1 / 0 |' <<<"$OUT" && grep -q '| Jev Noul（評価時の閾値で predicted = 抽象度不足） | - | 0.0% | 0 / 0 / 2 / 1 |' <<<"$OUT"; then
      ok "H20 --summarize abstraction: 機械シグナルと Jev を同じ定義で並べ、予測陽性 0 件の precision は「-」"
    else bad "H20 rc=$RC out=$OUT"; fi
    gen --summarize "$WORK/abs-results.jsonl" --kind novelty
    [ "$RC" -eq 2 ] && ok "H21 --kind novelty は exit 2" || bad "H21 rc=$RC"
    # 実 PLAYBOOK（SSOT 配置でだけ在る）: 構造だけを見る。件数の主張は合成側で固定済み
    if [ -f "$PLAYBOOK_REAL" ]; then
      gen --playbook "$PLAYBOOK_REAL" --out "$WORK/real1"
      if [ "$RC" -eq 0 ] && grep -q '^entries=[1-9]' <<<"$OUT" \
         && [ "$(jq -r 'select(.neighbor_date > .version_date) | .id' "$WORK/real1/recent-candidates.jsonl" | wc -l | tr -d ' ')" -eq 0 ] \
         && [ "$(jq -r 'select(.group=="added" and .expected.same_action==true) | .id' "$WORK/real1/recent-candidates.jsonl" | wc -l | tr -d ' ')" -eq 0 ] \
         && [ "$(jq -r '.group' "$WORK/real1/novelty-pairs.jsonl" | sort | uniq -c | awk '{print $1}' | sort -u | wc -l | tr -d ' ')" -eq 1 ]; then
        ok "H22 実 PLAYBOOK: 生成でき、近傍は版より前、追加候補は全 false、pos / neg 同数（${OUT}）"
      else bad "H22 rc=$RC out=$OUT err=$ERR"; fi
    else
      echo "  ○ skip: リポジトリ側の docs/08-knowledge/PLAYBOOK.md が無いため H22 だけ実行していません（配布先 checkout。合成 fixture の H1〜H21 は実行済み）"
    fi
  fi
fi

# ================================================================================
echo "== I. 判断点評価セット生成器（assess-impact の Score / close-issue の Choice。合成 fixture + 偽 gh）=="
GEN2="$PLUGIN_ROOT/scripts/jev/build-judgment-eval-sets.ts"
CASES_REAL="$PLUGIN_ROOT/tests/assess-impact/fixtures/cases"
gen2() { # $@=引数。stdout→${OUT} rc→${RC}（stderr は ${ERR}）
  OUT="$(FF_DEV_TOOLKIT_ROOT="$PLUGIN_ROOT" bash "$RUNNER" "$GEN2" "$@" 2>"$WORK/gen2.err")"; RC=$?
  ERR="$(cat "$WORK/gen2.err")"
}
# 合成 cases: 2 件（LOW / HIGH）+ 期待影響度の無い 1 件は別ディレクトリ
SYNC="$WORK/cases"; mkdir -p "$SYNC/a-low" "$SYNC/b-high" "$WORK/cases-bad/c-none"
printf '# 依頼\n\ntypo を 1 箇所直す。\n' > "$SYNC/a-low/input.md"
printf '# expected\n\n- 期待分類: 文言修正\n- 期待影響度: LOW\n' > "$SYNC/a-low/expected.md"
printf '# 依頼\n\nDB スキーマを変えて移行を伴う。\n' > "$SYNC/b-high/input.md"
printf '# expected\n\n- 期待影響度: HIGH\n' > "$SYNC/b-high/expected.md"
printf '# 依頼\n\n何か。\n' > "$WORK/cases-bad/c-none/input.md"
printf '# expected\n\n- 期待分類: 文言修正\n' > "$WORK/cases-bad/c-none/expected.md"
# 合成 cache: 101 = AC 表あり（達成 2 + post-merge 1、区切り行は詰めた形）/ 102 = 報告なし / 103 = 報告はあるが AC 表なし（bundle の子）
SYNCACHE="$WORK/cache"; mkdir -p "$SYNCACHE"
mk_cache() { # $1=issue番号 $2=report（空 = null） $3=pr json（空 = null）
  jq -n --arg n "$1" --arg report "$2" --argjson pr "${3:-null}" \
    '{issue:{number:($n|tonumber),title:("issue " + $n),closedAt:"2026-01-01T00:00:00Z",checkboxes:{checked:3,unchecked:1}},report:(if $report=="" then null else $report end),pr:$pr}' \
    > "$SYNCACHE/issue-$1.json"
}
# 判定セルは正本テンプレ（close-issue SKILL.md）の形: ✅ 達成 / ➖ 対象外 / ⏳ post-merge 検証待ち + ❌ 未達。区切り行は詰めた形
REPORT_101="$(printf '<!-- close-issue-report:PR-77 -->\n## 完了報告\n\n### AC 検証結果\n\n| AC | 判定 | 根拠 |\n|---|---|---|\n| Given A When B Then C | ✅ 達成 | verify.sh の I1 が緑 |\n| DoD: 針を足す | ✅ 達成（注記あり） | 検査 3 件追加 |\n| DoD: 公開側で実測 | ⏳ post-merge 検証待ち | マージ後に実施 |\n| DoD: 旧案の実装 | ➖ 対象外 | 案 B 採用のため別 Issue へ |\n| DoD: 未実装の項目 | ❌ 未達 | 根拠なし |\n\n### 工数実績\n\n| 区分 | 予定 | 実績 |\n| --- | --- | --- |\n| AI | 0.5d | 0.3d |\n')"
PR_77='{"number":77,"title":"test: 針を足す","additions":10,"deletions":2,"files":[{"path":"a.sh","additions":8,"deletions":2},{"path":"b.md","additions":2,"deletions":0}]}'
mk_cache 101 "$REPORT_101" "$PR_77"
mk_cache 102 "" ""
mk_cache 103 "$(printf '<!-- close-issue-report:PR-78 -->\n## 完了報告\n\n本文だけ。\n')" "$PR_77"
if [ ! -f "$GEN2" ]; then
  bad "I0 生成器がありません: $GEN2"
else
  gen2 --assess-impact-cases "$SYNC" --close-issue-cache "$SYNCACHE" --out "$WORK/j1"
  if [ "$RC" -eq 3 ]; then
    echo "  ○ skip: tsx ランナーを起動できないため I 節を実行していません（${ERR}）"
  else
    if [ "$RC" -eq 0 ] && grep -q '^assess_impact=2 low=1 medium=0 high=1 close_issue=6 issues=3 skipped_no_report=1 skipped_no_table=1 skipped_no_pr=0 skipped_files_truncated=0 post_merge=1 achieved=2 unmet=1 out_of_scope=1 negatives=2 checked=9 unchecked=3$' <<<"$OUT"; then
      ok "I1 合成 cases 2 件 + cache 3 件: assess 2 / close 6（達成 2 + 未達 1 + 対象外 1 + 合成負例 2）、報告なし・AC 表なし・post-merge は skipped として数える"
    else bad "I1 rc=$RC out=$OUT err=$ERR"; fi
    if jq -e 'select(.id=="ai-a-low") | .questions.impact.type=="score" and (.questions.impact.criteria|length)==3 and .expected.impact==0 and .group=="LOW" and (.state|test("typo"))' "$WORK/j1/assess-impact.jsonl" >/dev/null 2>&1 \
       && jq -e 'select(.id=="ai-b-high") | .expected.impact==2 and .group=="HIGH"' "$WORK/j1/assess-impact.jsonl" >/dev/null 2>&1; then
      ok "I2 assess-impact: Score(3)・expected は LOW=0 / HIGH=2 のレベル番号・state は input.md 全文"
    else bad "I2 assess-impact の形: $(cut -c1-200 "$WORK/j1/assess-impact.jsonl")"; fi
    if jq -e 'select(.id=="ci-101-1") | .group=="original" and .questions.verdict.type=="choice" and (.questions.verdict.criteria|keys|sort)==["achieved","out_of_scope","unmet"] and .expected.verdict=="achieved" and .state.ac=="Given A When B Then C" and .state.evidence=="verify.sh の I1 が緑" and .state.pr.number==77 and (.state.pr.files|length)==2 and (.state.pr|has("body")|not)' "$WORK/j1/close-issue.jsonl" >/dev/null 2>&1 \
       && jq -e 'select(.id=="ci-101-2") | .expected.verdict=="achieved" and .state.evidence=="検査 3 件追加"' "$WORK/j1/close-issue.jsonl" >/dev/null 2>&1 \
       && [ "$(jq -r 'select(.id=="ci-101-3") | .id' "$WORK/j1/close-issue.jsonl" | wc -l | tr -d ' ')" -eq 0 ] \
       && jq -e 'select(.id=="ci-101-4") | .expected.verdict=="out_of_scope"' "$WORK/j1/close-issue.jsonl" >/dev/null 2>&1 \
       && jq -e 'select(.id=="ci-101-5") | .expected.verdict=="unmet"' "$WORK/j1/close-issue.jsonl" >/dev/null 2>&1 \
       && [ "$(jq -r 'select(.group=="shuffled") | .evidence_from' "$WORK/j1/close-issue.jsonl" | grep -c -E 'ci-101-(4|5)$')" -eq 0 ] \
       && [ "$(jq -r 'select(.id=="ci-101-4-shuffled" or .id=="ci-101-5-shuffled") | .id' "$WORK/j1/close-issue.jsonl" | wc -l | tr -d ' ')" -eq 0 ]; then
      ok "I3 close-issue: Choice(3)・state は AC + PR 要約（本文なし）+ 根拠・「✅ 達成（注記）」も達成・➖ 対象外 / ❌ 未達 を読む・post-merge 行は入らない・負例の donor は達成行だけ"
    else bad "I3 close-issue の形: $(cut -c1-300 "$WORK/j1/close-issue.jsonl")"; fi
    if jq -e 'select(.id=="ci-101-1-shuffled") | .group=="shuffled" and .expected.verdict=="unmet" and .evidence_from=="ci-101-2" and .state.ac=="Given A When B Then C" and .state.evidence=="検査 3 件追加"' "$WORK/j1/close-issue.jsonl" >/dev/null 2>&1 \
       && jq -e 'select(.id=="ci-101-2-shuffled") | .evidence_from=="ci-101-1" and .state.evidence=="verify.sh の I1 が緑"' "$WORK/j1/close-issue.jsonl" >/dev/null 2>&1; then
      ok "I4 合成負例: 同じ Issue 内で根拠を 1 つ後ろへずらし（最後は先頭へ）、AC はそのまま・期待は unmet・出所 id を持つ"
    else bad "I4 合成負例の形"; fi
    gen2 --assess-impact-cases "$SYNC" --close-issue-cache "$SYNCACHE" --out "$WORK/j1b" --negatives 0
    if [ "$RC" -eq 0 ] && grep -q 'close_issue=4 .* negatives=0 ' <<<"$OUT"; then ok "I5 --negatives 0 で合成負例を止められる"; else bad "I5 rc=$RC out=$OUT"; fi
    gen2 --assess-impact-cases "$SYNC" --close-issue-cache "$SYNCACHE" --out "$WORK/j2"
    if [ "$RC" -eq 0 ] && cmp -s "$WORK/j1/assess-impact.jsonl" "$WORK/j2/assess-impact.jsonl" && cmp -s "$WORK/j1/close-issue.jsonl" "$WORK/j2/close-issue.jsonl"; then
      ok "I6 決定性: 同じ入力で 2 セットともバイト同一"
    else bad "I6 rc=$RC"; fi
    # 空振り（判定不能を成功にしない）
    gen2 --assess-impact-cases "$WORK/cases-bad" --out "$WORK/j3"
    [ "$RC" -eq 2 ] && grep -q '期待影響度' <<<"$ERR" && ok "I7 expected.md に期待影響度が無い case は exit 2（文言一致）" || bad "I7 rc=$RC err=$ERR"
    mkdir -p "$WORK/cases-empty"
    gen2 --assess-impact-cases "$WORK/cases-empty" --out "$WORK/j3"
    [ "$RC" -eq 2 ] && grep -q '0 件' <<<"$ERR" && ok "I8 case が 0 件のディレクトリは exit 2（0 件を成功にしない）" || bad "I8 rc=$RC err=$ERR"
    mkdir -p "$WORK/cache-empty"
    gen2 --close-issue-cache "$WORK/cache-empty" --out "$WORK/j3"
    [ "$RC" -eq 2 ] && grep -q '0 件' <<<"$ERR" && ok "I9 cache が空なら exit 2" || bad "I9 rc=$RC err=$ERR"
    mkdir -p "$WORK/cache-unreadable"; cp "$SYNCACHE/issue-102.json" "$SYNCACHE/issue-103.json" "$WORK/cache-unreadable/"
    gen2 --close-issue-cache "$WORK/cache-unreadable" --out "$WORK/j3"
    [ "$RC" -eq 2 ] && grep -q '0 行' <<<"$ERR" && grep -q '報告なし 1' <<<"$ERR" && ok "I10 全 Issue が読めずセット 0 行なら exit 2（skipped の内訳を名乗る）" || bad "I10 rc=$RC err=$ERR"
    mkdir -p "$WORK/cache-verdict"; cp "$SYNCACHE/issue-101.json" "$WORK/cache-verdict/"
    jq '.report |= sub("✅ 達成（注記あり）"; "🤷 判断保留")' "$SYNCACHE/issue-101.json" > "$WORK/cache-verdict/issue-101.json"
    gen2 --close-issue-cache "$WORK/cache-verdict" --out "$WORK/j3"
    [ "$RC" -eq 2 ] && grep -q '判定を読めない' <<<"$ERR" && grep -q '101' <<<"$ERR" && ok "I11 判定セルが既知の形でない行があれば exit 2 で Issue を名指し（黙って落とさない）" || bad "I11 rc=$RC err=$ERR"
    printf 'not json\n' > "$WORK/cache-verdict/issue-101.json"
    gen2 --close-issue-cache "$WORK/cache-verdict" --out "$WORK/j3"
    [ "$RC" -eq 2 ] && grep -q 'JSON' <<<"$ERR" && ok "I12 cache が JSON として読めなければ exit 2" || bad "I12 rc=$RC err=$ERR"
    for args in "--negatives 2" "--fetch-closed-issues 0" "--fetch-closed-issues x"; do
      # shellcheck disable=SC2086
      gen2 --close-issue-cache "$SYNCACHE" --out "$WORK/j3" $args --repo o/r --cache "$WORK/c"
      [ "$RC" -eq 2 ] && ok "I13 数値オプションの不正（${args}）は exit 2" || bad "I13 $args rc=$RC"
    done
    gen2 --fetch-closed-issues 3 --cache "$WORK/c"
    [ "$RC" -eq 2 ] && ok "I14 --fetch-closed-issues に --repo が無ければ exit 2" || bad "I14 rc=$RC"
    gen2 --fetch-closed-issues 3 --repo 'bad repo' --cache "$WORK/c"
    [ "$RC" -eq 2 ] && grep -q 'owner/repo' <<<"$ERR" && ok "I15 --repo が owner/repo の形でなければ gh を呼ばず exit 2" || bad "I15 rc=$RC err=$ERR"
    gen2 --out "$WORK/j3"
    [ "$RC" -eq 2 ] && ok "I16 --out だけ（入力の指定なし）は exit 2" || bad "I16 rc=$RC"
    gen2 --close-issue-cache "$SYNCACHE" --out "$WORK/j3" --bogus 1
    [ "$RC" -eq 2 ] && grep -q 'bogus' <<<"$ERR" && ok "I17 未知のオプションは exit 2 で名指し" || bad "I17 rc=$RC err=$ERR"
    # 偽 gh: fetch は cache にだけ書き、報告コメントの PR 番号から pr view を引く
    FAKEGH="$WORK/fakegh"; mkdir -p "$FAKEGH"
    cat > "$FAKEGH/gh" <<'EOF'
#!/usr/bin/env bash
# 偽 gh: 呼び出しの形を記録し、固定応答を返す
printf '%s\n' "$*" >> "${FAKE_GH_LOG:?}"
case "$1 $2" in
  "issue list") printf '[{"number":201},{"number":202}]\n' ;;
  "issue view")
    if [ "$3" = "201" ]; then
      printf '{"number":201,"title":"t201","body":"- [x] a\\n- [ ] b\\n","closedAt":"2026-02-01T00:00:00Z","comments":[{"body":"first"},{"body":"<!-- close-issue-report:PR-301 -->\\n## 完了報告\\n\\n### AC 検証結果\\n\\n| AC | 判定 | 根拠 |\\n| --- | --- | --- |\\n| x | ✅ 達成 | y |\\n"}]}\n'
    else
      printf '{"number":202,"title":"t202","body":"","closedAt":"2026-02-02T00:00:00Z","comments":[]}\n'
    fi ;;
  "pr view") printf '{"number":301,"title":"p301","additions":1,"deletions":0,"files":[{"path":"f","additions":1,"deletions":0}]}\n' ;;
  *) echo "unexpected: $*" >&2; exit 9 ;;
esac
EOF
    chmod +x "$FAKEGH/gh"
    : > "$WORK/gh.log"
    OUT="$(FAKE_GH_LOG="$WORK/gh.log" PATH="$FAKEGH:$PATH" FF_DEV_TOOLKIT_ROOT="$PLUGIN_ROOT" bash "$RUNNER" "$GEN2" --fetch-closed-issues 2 --repo o/r --cache "$WORK/c2" 2>"$WORK/gen2.err")"; RC=$?; ERR="$(cat "$WORK/gen2.err")"
    if [ "$RC" -eq 0 ] && grep -q '^fetched=2 ' <<<"$OUT" \
       && jq -e '.issue.number==201 and .issue.checkboxes=={checked:1,unchecked:1} and (.report|test("close-issue-report:PR-301")) and .pr.number==301 and (.pr.files|length)==1' "$WORK/c2/issue-201.json" >/dev/null 2>&1 \
       && jq -e '.issue.number==202 and .report==null and .pr==null' "$WORK/c2/issue-202.json" >/dev/null 2>&1 \
       && [ "$(grep -c '^pr view 301 ' "$WORK/gh.log")" -eq 1 ] && [ "$(grep -c '^pr view' "$WORK/gh.log")" -eq 1 ]; then
      ok "I18 --fetch-closed-issues（偽 gh）: 1 Issue 1 JSON、報告コメントの PR 番号だけ pr view、報告の無い Issue は pr を引かない"
    else bad "I18 rc=$RC out=$OUT err=$ERR log=$(cat "$WORK/gh.log")"; fi
    gen2 --close-issue-cache "$WORK/c2" --out "$WORK/j4"
    [ "$RC" -eq 0 ] && grep -q '^close_issue=1 issues=2 skipped_no_report=1 skipped_no_table=0 skipped_no_pr=0 skipped_files_truncated=0 ' <<<"$OUT" && ok "I19 偽 gh で作った cache から生成できる（達成 1 件のみ・負例は 2 件未満なので 0）" || bad "I19 rc=$RC out=$OUT err=$ERR"
    cp "$FAKEGH/gh" "$FAKEGH/gh.ok"
    printf '#!/usr/bin/env bash\necho "gh: auth required" >&2; exit 4\n' > "$FAKEGH/gh"
    OUT="$(PATH="$FAKEGH:$PATH" FF_DEV_TOOLKIT_ROOT="$PLUGIN_ROOT" bash "$RUNNER" "$GEN2" --fetch-closed-issues 2 --repo o/r --cache "$WORK/c3" 2>"$WORK/gen2.err")"; RC=$?; ERR="$(cat "$WORK/gen2.err")"
    [ "$RC" -eq 2 ] && grep -q 'auth required' <<<"$ERR" && [ ! -d "$WORK/c3" ] && ok "I20 gh が失敗したら exit 2 で stderr を名乗り、cache を作らない" || bad "I20 rc=$RC err=$ERR"
    # 途中（2 件目の issue view）で失敗: 1 件目まで書いた部分 cache を残さない（部分 cache は「小さなセットで成功」の温床）
    sed 's|^  "issue view")$|  "issue view") if [ "$3" = "202" ]; then echo "gh: rate limited" >\&2; exit 4; fi|' "$FAKEGH/gh.ok" > "$FAKEGH/gh"; chmod +x "$FAKEGH/gh"
    : > "$WORK/gh.log"
    OUT="$(FAKE_GH_LOG="$WORK/gh.log" PATH="$FAKEGH:$PATH" FF_DEV_TOOLKIT_ROOT="$PLUGIN_ROOT" bash "$RUNNER" "$GEN2" --fetch-closed-issues 2 --repo o/r --cache "$WORK/c4" 2>"$WORK/gen2.err")"; RC=$?; ERR="$(cat "$WORK/gen2.err")"
    if [ "$RC" -eq 2 ] && grep -q 'rate limited' <<<"$ERR" && [ ! -d "$WORK/c4" ] && [ "$(ls -d "$WORK"/c4.tmp-* 2>/dev/null | wc -l | tr -d ' ')" -eq 0 ] && [ "$(grep -c '^issue view 201 ' "$WORK/gh.log")" -eq 1 ]; then
      ok "I20b 途中の gh 失敗でも cache を作らず一時ディレクトリも残さない（1 件目は取得済みだった）"
    else bad "I20b rc=$RC err=$ERR c4=$(ls -d "$WORK"/c4* 2>/dev/null | tr '\n' ' ')"; fi
    # 既存 cache がある状態で成功したら丸ごと置き換える（古い Issue の JSON を残さない）
    cp "$FAKEGH/gh.ok" "$FAKEGH/gh"; mkdir -p "$WORK/c5"; printf '{}\n' > "$WORK/c5/issue-999.json"
    OUT="$(FAKE_GH_LOG="$WORK/gh.log" PATH="$FAKEGH:$PATH" FF_DEV_TOOLKIT_ROOT="$PLUGIN_ROOT" bash "$RUNNER" "$GEN2" --fetch-closed-issues 2 --repo o/r --cache "$WORK/c5" 2>"$WORK/gen2.err")"; RC=$?
    [ "$RC" -eq 0 ] && [ ! -f "$WORK/c5/issue-999.json" ] && [ -f "$WORK/c5/issue-201.json" ] && ok "I20c 既存 cache は成功時に丸ごと置き換える" || bad "I20c rc=$RC ls=$(ls "$WORK/c5" | tr '\n' ' ')"
    # --summarize
    cat > "$WORK/ai-results.jsonl" <<'EOF'
{"id":"ai-a","group":"LOW","answers":[{"qid":"impact","expected":0,"predicted":0,"raw":0.2,"confidence":0.9}]}
{"id":"ai-b","group":"MEDIUM","answers":[{"qid":"impact","expected":1,"predicted":2,"raw":1.6,"confidence":0.5}]}
{"id":"ai-c","group":"HIGH","answers":[{"qid":"impact","expected":2,"predicted":1,"raw":1.4,"confidence":0.4}]}
EOF
    gen2 --summarize "$WORK/ai-results.jsonl" --kind assess-impact
    if [ "$RC" -eq 0 ] && grep -q '| ai-b | MEDIUM | HIGH（1.60） | 0.50 | ⬆️ 過剰 |' <<<"$OUT" && grep -q '3 件 / 一致 1 / 過剰（Jev が高い側） 1 / 過少（Jev が低い側） 1' <<<"$OUT"; then
      ok "I21 --summarize assess-impact: レベル名で並べ、過剰 / 過少を分けて数える"
    else bad "I21 rc=$RC out=$OUT err=$ERR"; fi
    cat > "$WORK/ci-results.jsonl" <<'EOF'
{"id":"ci-1-1","group":"original","answers":[{"qid":"verdict","expected":"achieved","predicted":"achieved","raw":"achieved","confidence":0.9}]}
{"id":"ci-1-2","group":"original","answers":[{"qid":"verdict","expected":"achieved","predicted":"unmet","raw":"unmet","confidence":0.6}]}
{"id":"ci-1-1-shuffled","group":"shuffled","answers":[{"qid":"verdict","expected":"unmet","predicted":"achieved","raw":"achieved","confidence":0.7}]}
{"id":"ci-1-2-shuffled","group":"shuffled","answers":[{"qid":"verdict","expected":"unmet","predicted":"out_of_scope","raw":"out_of_scope","confidence":0.3}]}
EOF
    gen2 --summarize "$WORK/ci-results.jsonl" --kind close-issue
    if [ "$RC" -eq 0 ] && grep -q '| original | 2 | 1（50.0%） | 1 | 0 | 0 |' <<<"$OUT" && grep -q '| shuffled | 2 | 0（0.0%） | 0 | 1 | 1 |' <<<"$OUT" \
       && grep -q '| ci-1-1-shuffled | unmet | achieved | 0.70 | \*\*緩い側\*\* |' <<<"$OUT"; then
      ok "I22 --summarize close-issue: group 別に厳しい側 / 緩い側 / 未達↔対象外を分け、不一致件を confidence 付きで列挙"
    else bad "I22 rc=$RC out=$OUT err=$ERR"; fi
    grep -q 'shuffled は同じ Issue 内で根拠をずらした合成負例' <<<"$OUT" && ok "I22b shuffled があれば合成の限界を表の下に併記する" || bad "I22b 併記なし"
    cp "$WORK/ci-results.jsonl" "$WORK/ci-results.ok.jsonl"
    printf '{"id":"ci-9-9","group":"original","answers":[{"qid":"verdict","expected":"maybe","predicted":"achieved"}]}\n' >> "$WORK/ci-results.jsonl"
    gen2 --summarize "$WORK/ci-results.jsonl" --kind close-issue
    [ "$RC" -eq 2 ] && grep -q 'ci-9-9' <<<"$ERR" && ok "I23 expected が契約外の結果行は集計せず exit 2 で名指し" || bad "I23 rc=$RC err=$ERR"
    { cat "$WORK/ci-results.ok.jsonl"; printf '{"id":"ci-9-8","group":"original","answers":[{"qid":"verdict","expected":"achieved","predicted":"Achieved"}]}\n'; } > "$WORK/ci-results.jsonl"
    gen2 --summarize "$WORK/ci-results.jsonl" --kind close-issue
    [ "$RC" -eq 2 ] && grep -q 'ci-9-8' <<<"$ERR" && ok "I23b predicted が契約外（大文字違い）の結果行も exit 2（未達↔対象外へ落とさない）" || bad "I23b rc=$RC err=$ERR"
    printf '{"id":"ai-z","group":"HIGH","answers":[{"qid":"impact","expected":1,"predicted":3,"raw":2.7}]}\n' > "$WORK/ai-bad.jsonl"
    gen2 --summarize "$WORK/ai-bad.jsonl" --kind assess-impact
    [ "$RC" -eq 2 ] && grep -q 'レベル範囲外' <<<"$ERR" && grep -q 'ai-z' <<<"$ERR" && ok "I23c score のレベル範囲外は exit 2 で名指し" || bad "I23c rc=$RC err=$ERR"
    gen2 --summarize "$WORK/ai-results.jsonl" --kind close-issue
    [ "$RC" -eq 2 ] && ok "I24 score の結果を --kind close-issue で読ませると exit 2（契約違反を混ぜて集計しない）" || bad "I24 rc=$RC"
    gen2 --summarize "$WORK/ai-results.jsonl" --kind novelty
    [ "$RC" -eq 2 ] && ok "I25 --kind novelty は exit 2" || bad "I25 rc=$RC"
    # 同梱の実 fixtures（tests/assess-impact/fixtures/cases）: 5 件がそのまま読める
    gen2 --assess-impact-cases "$CASES_REAL" --out "$WORK/real2"
    if [ "$RC" -eq 0 ] && grep -q '^assess_impact=5 low=1 medium=2 high=2$' <<<"$OUT"; then
      ok "I26 同梱の assess-impact fixtures 5 件（LOW 1 / MEDIUM 2 / HIGH 2）をそのまま評価セットにできる"
    else bad "I26 rc=$RC out=$OUT err=$ERR"; fi
    # 合成負例の回転（3 行）と同一根拠の donor 除外、表の読み取りの境界
    SYNCACHE2="$WORK/cache2"; mkdir -p "$SYNCACHE2"
    mk_cache2() { jq -n --arg n "$1" --arg report "$2" --argjson pr "${3:-null}" '{issue:{number:($n|tonumber),title:"t",closedAt:"2026-01-01T00:00:00Z",checkboxes:{checked:0,unchecked:0}},report:(if $report=="" then null else $report end),pr:$pr}' > "$SYNCACHE2/issue-$1.json"; }
    # 104: 達成 3 行、根拠は e1 / e2 / e2 → 1→2、2→1（3 は同じ e2 なので飛ばす）、3→1
    mk_cache2 104 "$(printf '<!-- close-issue-report:PR-77 -->\n### AC 検証結果\n\n| AC | 判定 | 根拠 |\n| --- | --- | --- |\n| a1 | ✅ 達成 | e1 |\n| a2 | ✅ 達成 | e2 |\n| a3 | ✅ 達成 | e2 |\n')" "$PR_77"
    # 105: 達成 2 行が同じ根拠 → 負例 0
    mk_cache2 105 "$(printf '<!-- close-issue-report:PR-77 -->\n### AC 検証結果\n\n| AC | 判定 | 根拠 |\n| --- | --- | --- |\n| b1 | ✅ 達成 | same |\n| b2 | ✅ 達成 | same |\n')" "$PR_77"
    gen2 --close-issue-cache "$SYNCACHE2" --out "$WORK/j5"
    if [ "$RC" -eq 0 ] && grep -q 'close_issue=8 .* achieved=5 .* negatives=3 ' <<<"$OUT" \
       && [ "$(jq -r 'select(.group=="shuffled") | "\(.id)<\(.evidence_from):\(.state.evidence)"' "$WORK/j5/close-issue.jsonl" | sort | tr '\n' ' ')" = "ci-104-1-shuffled<ci-104-2:e2 ci-104-2-shuffled<ci-104-1:e1 ci-104-3-shuffled<ci-104-1:e1 " ]; then
      ok "I27 合成負例: 3 行は 1→2 / 2→1（同一根拠の 3 を飛ばす）/ 3→1、全行同一根拠の Issue は負例 0"
    else bad "I27 rc=$RC out=$OUT $(jq -c 'select(.group=="shuffled") | {id,evidence_from,e:.state.evidence}' "$WORK/j5/close-issue.jsonl" 2>/dev/null | tr '\n' ' ')"; fi
    SYNCACHE3="$WORK/cache3"; mkdir -p "$SYNCACHE3"
    mk_cache3() { jq -n --arg n "$1" --arg report "$2" --argjson pr "${3:-null}" '{issue:{number:($n|tonumber),title:"t",closedAt:"2026-01-01T00:00:00Z",checkboxes:{checked:0,unchecked:0}},report:(if $report=="" then null else $report end),pr:$pr}' > "$SYNCACHE3/issue-$1.json"; }
    # 106: 「ACE メモ」の見出しが先にあっても AC 表を読む。AC セル・根拠セルのバッククォート内の | は区切らない。詰めた行 |a|b|c| も読む
    mk_cache3 106 "$(printf '<!-- close-issue-report:PR-77 -->\n### ACE メモ\n\n候補 2 件。\n\n### AC 検証結果\n\n| AC | 判定 | 根拠 |\n| --- | --- | --- |\n| 出力が `a | b` を含む | ✅ 達成 | `x | y` が緑 |\n|c2|✅ 達成|e2|\n')" "$PR_77"
    # 107: 見出しはあるが散文だけ（「AC 記載なし」の報告）→ 表なし
    mk_cache3 107 "$(printf '<!-- close-issue-report:PR-77 -->\n### AC 検証結果\n\nこの Issue には AC の記載がないため照合をスキップした。\n')" "$PR_77"
    # 108: 報告はあるが pr が null → PR なし
    mk_cache3 108 "$(printf '<!-- close-issue-report:PR-77 -->\n### AC 検証結果\n\n| AC | 判定 | 根拠 |\n| --- | --- | --- |\n| d1 | ✅ 達成 | e |\n')" ""
    gen2 --close-issue-cache "$SYNCACHE3" --out "$WORK/j6"
    if [ "$RC" -eq 0 ] && grep -q 'close_issue=4 issues=3 skipped_no_report=0 skipped_no_table=1 skipped_no_pr=1 skipped_files_truncated=0 ' <<<"$OUT" \
       && jq -e 'select(.id=="ci-106-1") | .state.ac=="出力が `a | b` を含む" and .state.evidence=="`x | y` が緑"' "$WORK/j6/close-issue.jsonl" >/dev/null 2>&1 \
       && jq -e 'select(.id=="ci-106-2") | .state.ac=="c2" and .state.evidence=="e2"' "$WORK/j6/close-issue.jsonl" >/dev/null 2>&1; then
      ok "I28 表の読み取り: 先行する「ACE …」見出しに当てない・バッククォート内の | は区切らない・詰めた行も読む・散文だけの見出しは表なし・pr null は PR なし"
    else bad "I28 rc=$RC out=$OUT err=$ERR $(cut -c1-200 "$WORK/j6/close-issue.jsonl" 2>/dev/null | tr '\n' ' ')"; fi
    mkdir -p "$WORK/cache-nopr"; cp "$SYNCACHE3/issue-108.json" "$WORK/cache-nopr/"
    gen2 --close-issue-cache "$WORK/cache-nopr" --out "$WORK/j7"
    [ "$RC" -eq 2 ] && grep -q 'PR なし 1' <<<"$ERR" && ok "I29 PR なしだけの cache はセット 0 行で exit 2（内訳を名乗る）" || bad "I29 rc=$RC err=$ERR"
    # 見出し・表の書式 drift は skipped に紛れさせない
    SYNCACHE4="$WORK/cache4"; mkdir -p "$SYNCACHE4"
    mk_cache4() { jq -n --arg n "$1" --arg report "$2" --argjson pr "${3:-null}" '{issue:{number:($n|tonumber),title:"t",closedAt:"2026-01-01T00:00:00Z",checkboxes:{checked:0,unchecked:0}},report:(if $report=="" then null else $report end),pr:$pr}' > "$SYNCACHE4/issue-$1.json"; }
    # 109: `### AC検証結果`（空白なし）と 4 段見出し・行頭に空白のある行 → 読める
    mk_cache4 109 "$(printf '<!-- close-issue-report:PR-77 -->\n#### AC検証結果\n\n| AC | 判定 | 根拠 |\n| --- | --- | --- |\n  | s1 | ✅ 達成 | e1 |\n| s2 | ✅ 達成 | e2 |\n')" "$PR_77"
    gen2 --close-issue-cache "$SYNCACHE4" --out "$WORK/j8"
    [ "$RC" -eq 0 ] && grep -q '^close_issue=4 issues=1 skipped_no_report=0 skipped_no_table=0 ' <<<"$OUT" && ok "I30 見出し「AC検証結果」（空白なし・4 段）と行頭空白の行を読む" || bad "I30 rc=$RC out=$OUT err=$ERR"
    # 110: 見出しが太字（見出し記法でない）のに判定表がある → 表なしに数えず exit 2
    rm -f "$SYNCACHE4"/issue-109.json
    mk_cache4 110 "$(printf '<!-- close-issue-report:PR-77 -->\n**AC 検証結果**\n\n| AC | 判定 | 根拠 |\n| --- | --- | --- |\n| t1 | ✅ 達成 | e1 |\n')" "$PR_77"
    gen2 --close-issue-cache "$SYNCACHE4" --out "$WORK/j8"
    [ "$RC" -eq 2 ] && grep -q '110' <<<"$ERR" && grep -q '見出し' <<<"$ERR" && ok "I31 判定表はあるが AC 見出しの下に無い（書式 drift）は表なしに数えず exit 2" || bad "I31 rc=$RC err=$ERR"
    # 111: 表の途中に表以外の行（折り返し）があり、その後にも行がある → 後続を落とさず exit 2
    rm -f "$SYNCACHE4"/issue-110.json
    mk_cache4 111 "$(printf '<!-- close-issue-report:PR-77 -->\n### AC 検証結果\n\n| AC | 判定 | 根拠 |\n| --- | --- | --- |\n| u1 | ✅ 達成 | e1 |\n折り返しの続き\n| u2 | ✅ 達成 | e2 |\n')" "$PR_77"
    gen2 --close-issue-cache "$SYNCACHE4" --out "$WORK/j8"
    [ "$RC" -eq 2 ] && grep -q '判定を読めない' <<<"$ERR" && grep -q '111' <<<"$ERR" && ok "I32 表の途中に表以外の行があれば後続の行を黙って落とさず exit 2" || bad "I32 rc=$RC err=$ERR"
    # 112: ヘッダの列順が違う（判定が 2 列目でない）→ exit 2
    rm -f "$SYNCACHE4"/issue-111.json
    mk_cache4 112 "$(printf '<!-- close-issue-report:PR-77 -->\n### AC 検証結果\n\n| # | AC | 判定 | 根拠 |\n| --- | --- | --- | --- |\n| 1 | v1 | ✅ 達成 | e1 |\n')" "$PR_77"
    gen2 --close-issue-cache "$SYNCACHE4" --out "$WORK/j8"
    [ "$RC" -eq 2 ] && grep -q '112' <<<"$ERR" && ok "I33 ヘッダの列順が契約（AC / 判定 / 根拠）と違えば exit 2" || bad "I33 rc=$RC err=$ERR"
    # 113: cache の形 drift（report が object）→ exit 2（TypeError で落ちない）。114: files_truncated の PR は skipped として数える
    rm -f "$SYNCACHE4"/issue-112.json
    jq -n '{issue:{number:113,title:"t",closedAt:"x",checkboxes:{checked:0,unchecked:0}},report:{},pr:null}' > "$SYNCACHE4/issue-113.json"
    gen2 --close-issue-cache "$SYNCACHE4" --out "$WORK/j8"
    [ "$RC" -eq 2 ] && grep -q '契約と違います' <<<"$ERR" && ok "I34 cache の report が文字列でも null でもなければ exit 2" || bad "I34 rc=$RC err=$ERR"
    rm -f "$SYNCACHE4"/issue-113.json
    mk_cache4 114 "$REPORT_101" "$(jq -c '. + {files_truncated:true}' <<<"$PR_77")"
    cp "$SYNCACHE/issue-101.json" "$SYNCACHE4/"
    gen2 --close-issue-cache "$SYNCACHE4" --out "$WORK/j8"
    [ "$RC" -eq 0 ] && grep -q 'issues=2 .* skipped_files_truncated=1 ' <<<"$OUT" && [ "$(jq -r 'select(.issue==114) | .id' "$WORK/j8/close-issue.jsonl" | wc -l | tr -d ' ')" -eq 0 ] && ok "I35 ファイル一覧が切れた PR の Issue は state に載せず skipped として数える" || bad "I35 rc=$RC out=$OUT"
    # 偽 gh: 完了報告が 2 件ある Issue は最後の 1 件、pr view の files が 100 件なら files_truncated、--cache の末尾 / でも既存 cache を置き換える
    cat > "$FAKEGH/gh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${FAKE_GH_LOG:?}"
case "$1 $2" in
  "issue list") printf '[{"number":301}]\n' ;;
  "issue view") printf '{"number":301,"title":"t","body":"","closedAt":"2026-02-01T00:00:00Z","comments":[{"body":"<!-- close-issue-report:PR-401 -->\\n### AC 検証結果\\n\\n| AC | 判定 | 根拠 |\\n| --- | --- | --- |\\n| old | ✅ 達成 | o |\\n"},{"body":"<!-- close-issue-report:PR-402 -->\\n### AC 検証結果\\n\\n| AC | 判定 | 根拠 |\\n| --- | --- | --- |\\n| new | ✅ 達成 | n |\\n"}]}\n' ;;
  "pr view") printf '{"number":402,"title":"p","additions":1,"deletions":0,"files":['; i=0; while [ $i -lt 100 ]; do [ $i -gt 0 ] && printf ','; printf '{"path":"f%d","additions":0,"deletions":0}' $i; i=$((i+1)); done; printf ']}\n' ;;
  *) echo "unexpected: $*" >&2; exit 9 ;;
esac
EOF
    chmod +x "$FAKEGH/gh"; mkdir -p "$WORK/c6"; printf '{}\n' > "$WORK/c6/issue-999.json"; : > "$WORK/gh.log"
    OUT="$(FAKE_GH_LOG="$WORK/gh.log" PATH="$FAKEGH:$PATH" FF_DEV_TOOLKIT_ROOT="$PLUGIN_ROOT" bash "$RUNNER" "$GEN2" --fetch-closed-issues 1 --repo o/r --cache "$WORK/c6/" 2>"$WORK/gen2.err")"; RC=$?; ERR="$(cat "$WORK/gen2.err")"
    if [ "$RC" -eq 0 ] && [ ! -f "$WORK/c6/issue-999.json" ] && [ "$(grep -c '^pr view 402 ' "$WORK/gh.log")" -eq 1 ] \
       && jq -e '(.report|test("PR-402")) and .pr.number==402 and .pr.files_truncated==true and (.pr.files|length)==100' "$WORK/c6/issue-301.json" >/dev/null 2>&1 \
       && [ "$(ls -d "$WORK"/c6.tmp-* 2>/dev/null | wc -l | tr -d ' ')" -eq 0 ]; then
      ok "I36 偽 gh: 完了報告 2 件は最後を採る・files 100 件は files_truncated・--cache 末尾 / でも既存 cache を置き換え一時ディレクトリを残さない"
    else bad "I36 rc=$RC err=$ERR ls=$(ls "$WORK"/c6* 2>/dev/null | tr '\n' ' ')"; fi
    cp "$FAKEGH/gh.ok" "$FAKEGH/gh"
    sed 's|"comments":\[|"commentz":[|' "$FAKEGH/gh.ok" > "$FAKEGH/gh"; chmod +x "$FAKEGH/gh"
    OUT="$(FAKE_GH_LOG="$WORK/gh.log" PATH="$FAKEGH:$PATH" FF_DEV_TOOLKIT_ROOT="$PLUGIN_ROOT" bash "$RUNNER" "$GEN2" --fetch-closed-issues 2 --repo o/r --cache "$WORK/c7" 2>"$WORK/gen2.err")"; RC=$?; ERR="$(cat "$WORK/gen2.err")"
    [ "$RC" -eq 2 ] && grep -q 'comments' <<<"$ERR" && grep -q '201' <<<"$ERR" && [ ! -d "$WORK/c7" ] && ok "I37 gh の JSON に comments が無ければ Issue 番号を名指しして exit 2（TypeError の文面にしない）" || bad "I37 rc=$RC err=$ERR"
    cp "$FAKEGH/gh.ok" "$FAKEGH/gh"
  fi
fi

# ================================================================================
echo "== F. 同梱 fixture（日英 Choice probe）=="
if [ "$(grep -c '' "$PROBE")" -eq 10 ] \
   && [ "$(jq -r 'select(.group == "en") | .id' "$PROBE" | wc -l | tr -d ' ')" -eq 5 ] \
   && [ "$(jq -r 'select(.group == "ja") | .id' "$PROBE" | wc -l | tr -d ' ')" -eq 5 ]; then
  ok "F1 en / ja 各 5 件（計 10 行）"
else bad "F1 行数: $(grep -c '' "$PROBE")"; fi
if jq -e '.questions.severity.type == "choice" and (.expected.severity as $e | .questions.severity.criteria | has($e))' "$PROBE" >/dev/null 2>&1 \
   && [ "$(jq -e '.questions.severity.type == "choice" and (.expected.severity as $e | .questions.severity.criteria | has($e))' "$PROBE" | grep -c true)" -eq 10 ]; then
  ok "F2 全行が Choice で、expected が criteria に実在する"
else bad "F2 expected が criteria に無い行がある"; fi
if [ "$(jq -r '.pair' "$PROBE" | sort | uniq -c | awk '$1 != 2' | wc -l | tr -d ' ')" -eq 0 ] \
   && [ "$(jq -r '.state' "$PROBE" | sort -u | wc -l | tr -d ' ')" -eq 5 ]; then
  ok "F3 各 pair は en / ja の 2 行で同じ state を共有する（質問だけが違う）"
else bad "F3 pair / state の対応が崩れている"; fi
reset_fake 200 200 200 200 200 200 200 200 200 200
printf '%s' '{"model":"jev-1.13.0","answers":{"severity":{"type":"choice","choice":"critical","probabilities":{"critical":0.7,"warning":0.2,"suggestion":0.1,"info":0.0},"confidence":0.6}},"usage":{"input_tokens":150,"output_tokens":10}}' > "$FAKE/body.200"
run_eval_args FF_JEV_ENABLED=1 TYPESAFE_API_KEY_FILE="$KEY_FILE" FF_JEV_INTERVAL_MS=0 -- --set "$PROBE" --json
if [ "$RC" -eq 0 ] && printf '%s' "$OUT" | jq -e '.cases == 10 and .overall.n == 10 and (.by_group | length == 2)' >/dev/null; then
  ok "F4 fixture はそのままハーネスに流せる（偽応答で 10 件・group 2 つ）"
else bad "F4 rc=$RC out=$OUT err=$ERR"; fi

# ================================================================================
echo "== J. 言語 A/B セット生成器（scripts/jev/build-lang-ab-sets.ts）=="
GEN3="$PLUGIN_ROOT/scripts/jev/build-lang-ab-sets.ts"
lab() { # $@=引数。stdout→${OUT} rc→${RC}（stderr は ${ERR}）
  OUT="$(FF_DEV_TOOLKIT_ROOT="$PLUGIN_ROOT" bash "$RUNNER" "$GEN3" "$@" 2>"$WORK/lab.err")"; RC=$?
  ERR="$(cat "$WORK/lab.err")"
}
# 合成セット: novelty 形（state.title / state.body / instructions.candidate）2 行と
# close-issue 形（state.ac / state.evidence / state.pr.title）2 行。候補文と PR タイトルは
# 行をまたいで共有し、内容ハッシュが 1 エントリへ畳まれることを測れるようにする。
# AC 文面は ASCII のままにして「日本語を含まない許可パスは英訳対象に入らない」も同時に測る。
# ファイル名・パスは ASCII のみ（ホスト固有の形を fixture へ持ち込まない）。
LABSET="$WORK/lab-set.jsonl"
NOVQ='{"same_action":{"type":"noul","instructions":{"candidate":"候補の一行要約","question":"Is it the same action?"},"criteria":{"true":"same action","false":"different action"}}}'
CIQ='{"verdict":{"type":"choice","instructions":"Decide the verdict.","criteria":{"achieved":"met","unmet":"not met"}}}'
LABPR='{"number":7,"title":"fix: ガードを足す","files":["a.sh (+1/-0)"]}'
{
  printf '{"id":"lab-1","group":"pos","state":{"id":"X-1","category":"testing","title":"針は主張ごとに張る","body":"行削除変異は句単位の drift に盲目。"},"questions":%s,"expected":{"same_action":true}}\n' "$NOVQ"
  printf '{"id":"lab-2","group":"neg","state":{"id":"X-2","category":"testing","title":"検査総数を baseline で縛る","body":"針ごとの変異は検査の消失を見ない。"},"questions":%s,"expected":{"same_action":false}}\n' "$NOVQ"
  printf '{"id":"lab-3","group":"original","state":{"ac":"Given A When B Then C","pr":%s,"evidence":"suite 9/9 pass"},"questions":%s,"expected":{"verdict":"achieved"}}\n' "$LABPR" "$CIQ"
  printf '{"id":"lab-4","group":"original","state":{"ac":"Given D When E Then F","pr":%s,"evidence":"上記の変更・実測"},"questions":%s,"expected":{"verdict":"unmet"}}\n' "$LABPR" "$CIQ"
} > "$LABSET"
# 等間隔抽出そのものを通す母集団（count < pool）。同一 group 5 行で、抽出される添字を固定する
LABSET5="$WORK/lab-set5.jsonl"
: > "$LABSET5"
for n in 1 2 3 4 5; do
  printf '{"id":"five-%s","group":"pos","state":{"id":"Y-%s","category":"testing","title":"見出し%s","body":"本文%s。"},"questions":%s,"expected":{"same_action":true}}\n' \
    "$n" "$n" "$n" "$n" "$NOVQ" >> "$LABSET5"
done
if [ ! -f "$GEN3" ]; then
  bad "J0 生成器がありません: $GEN3"
else
  lab --extract "$LABSET" --out "$WORK/lab-ja.jsonl" --count 2 --group original
  if [ "$RC" -eq 3 ]; then
    echo "  ○ skip: tsx ランナーを起動できないため J 節を実行していません（${ERR}）"
  else
    # ---- --extract -----------------------------------------------------------
    if [ "$RC" -eq 0 ] && [ "$OUT" = "extracted=2 pool=2 total=4 original=2" ] \
       && [ "$(jq -r '.id' "$WORK/lab-ja.jsonl" | tr '\n' ' ')" = "lab-3 lab-4 " ]; then
      ok "J1 --extract は group で母集団を絞り、件数と group 内訳を stdout で名乗る"
    else bad "J1 rc=$RC out=$OUT err=$ERR"; fi
    lab --extract "$LABSET5" --out "$WORK/five-3.jsonl" --count 3
    if [ "$RC" -eq 0 ] && [ "$(jq -r '.id' "$WORK/five-3.jsonl" | tr '\n' ' ')" = "five-1 five-2 five-4 " ]; then
      ok "J2 --extract は count < pool で等間隔に取る（5 件から 3 件 = 添字 0 / 1 / 3。head 取りでも全件返しでもない）"
    else bad "J2 等間隔抽出が効いていない: $(jq -r '.id' "$WORK/five-3.jsonl" 2>/dev/null | tr '\n' ' ') rc=$RC err=$ERR"; fi
    lab --extract "$LABSET5" --out "$WORK/five-1.jsonl" --count 1
    if [ "$RC" -eq 0 ] && [ "$(jq -r '.id' "$WORK/five-1.jsonl" | tr '\n' ' ')" = "five-1 " ]; then
      ok "J3 --extract は --count 1 でも 1 件だけ返す"
    else bad "J3 rc=$RC ids=$(jq -r '.id' "$WORK/five-1.jsonl" 2>/dev/null | tr '\n' ' ')"; fi
    lab --extract "$LABSET5" --out "$WORK/five-3b.jsonl" --count 3
    if [ "$RC" -eq 0 ] && cmp -s "$WORK/five-3.jsonl" "$WORK/five-3b.jsonl"; then
      ok "J4 --extract は決定的（count < pool の再実行でも出力がバイト同一）"
    else bad "J4 再実行で出力が変わった rc=$RC"; fi
    lab --extract "$LABSET" --out "$WORK/lab-x.jsonl" --count 3 --group original
    if [ "$RC" -eq 2 ] && grep -q '足りません' <<<"$ERR"; then
      ok "J5 母集団が --count に足りないときは exit 2（小さいセットを黙って成功にしない）"
    else bad "J5 rc=$RC err=$ERR"; fi
    lab --extract "$LABSET" --out "$WORK/lab-x.jsonl" --count 1 --group nosuch
    if [ "$RC" -eq 2 ] && grep -q '一致する行がありません' <<<"$ERR"; then
      ok "J6 存在しない group は exit 2（「母集団が足りない」とは別の文言で名乗る）"
    else bad "J6 rc=$RC err=$ERR"; fi
    : > "$WORK/lab-empty.jsonl"
    lab --extract "$WORK/lab-empty.jsonl" --out "$WORK/lab-x.jsonl" --count 1
    RC_EMPTY="$RC"
    printf '{"id":"broken"\n' > "$WORK/lab-broken.jsonl"
    lab --extract "$WORK/lab-broken.jsonl" --out "$WORK/lab-x.jsonl" --count 1
    if [ "$RC_EMPTY" -eq 2 ] && [ "$RC" -eq 2 ] && grep -q 'JSON として読めません' <<<"$ERR"; then
      ok "J7 空ファイルも JSON として読めない行も exit 2（読めない行を黙って落として母集団を縮めない）"
    else bad "J7 空=$RC_EMPTY 壊れた JSON=$RC err=$ERR"; fi
    printf '{"group":"pos","state":{"title":"id 無し"}}\n' > "$WORK/lab-noid.jsonl"
    lab --extract "$WORK/lab-noid.jsonl" --out "$WORK/lab-x.jsonl" --count 1
    RC_NOID="$RC"
    { head -1 "$LABSET"; head -1 "$LABSET"; } > "$WORK/lab-dup.jsonl"
    lab --extract "$WORK/lab-dup.jsonl" --out "$WORK/lab-x.jsonl" --count 2
    if [ "$RC_NOID" -eq 2 ] && [ "$RC" -eq 2 ] && grep -q '重複 id' <<<"$ERR"; then
      ok "J8 id の無い行も重複 id も exit 2（対の一意キーが壊れたまま評価を流さない）"
    else bad "J8 id無し=$RC_NOID 重複=$RC err=$ERR"; fi
    lab --extract "$LABSET" --out "$WORK/lab-x.jsonl" --count 0 --group original
    RC_ZERO="$RC"
    lab --extract "$LABSET" --out "$WORK/lab-x.jsonl" --count 1x --group original
    if [ "$RC_ZERO" -eq 2 ] && [ "$RC" -eq 2 ]; then
      ok "J9 --count の 0 と非整数は exit 2"
    else bad "J9 0=$RC_ZERO 非整数=$RC"; fi
    lab --extract "$LABSET" --out "$WORK/nodir/deep/out.jsonl" --count 2 --group original
    RC_OK_DIR="$RC"
    lab --extract "$LABSET" --out "/dev/null/impossible.jsonl" --count 2 --group original
    if [ "$RC_OK_DIR" -eq 0 ] && [ "$RC" -eq 2 ] && grep -q '\-\-out へ書けません' <<<"$ERR"; then
      ok "J10 --out は親ディレクトリを作るが、書けない先は exit 2（未捕捉例外の rc=1 で終わらない）"
    else bad "J10 作成=$RC_OK_DIR 書けない=$RC err=$ERR"; fi

    # ---- --template（許可パスと日本語検出）-----------------------------------
    lab --template "$LABSET" --out "$WORK/lab-tpl.json"
    TPL="$WORK/lab-tpl.json"
    if [ "$RC" -eq 0 ] && [ "$(jq -r '.entries | length' "$TPL" 2>/dev/null)" -eq 7 ] \
       && [ "$(jq -r '[.entries[] | select(.en == "")] | length' "$TPL")" -eq 7 ] \
       && [ "$(jq -r '._meta.translated_at' "$TPL")" = "(未翻訳)" ] \
       && [ "$(jq -r '._meta.source_ids | length' "$TPL")" -eq 4 ]; then
      ok "J11 --template は英訳対象を列挙し、en は空・_meta は未翻訳の印と原文 id を持つ（4 行 → 7 件）"
    else bad "J11 rc=$RC entries=$(jq -r '.entries | length' "$TPL" 2>/dev/null) err=$ERR"; fi
    if [ "$(jq -r '[.entries[] | select(.src == "候補の一行要約")] | length' "$TPL")" -eq 1 ] \
       && [ "$(jq -r '.entries[] | select(.src == "候補の一行要約") | .ids | length' "$TPL")" -eq 2 ] \
       && [ "$(jq -r '.entries[] | select(.src == "fix: ガードを足す") | .ids | length' "$TPL")" -eq 2 ]; then
      ok "J12 キーは内容ハッシュ: 同じ日本語は 1 件へ畳まれ、共有元の id が列挙される（pos / neg で訳が割れない）"
    else bad "J12 重複が畳まれていない: $(jq -c '[.entries[].src]' "$TPL" 2>/dev/null)"; fi
    if [ "$(jq -r '[.entries[].src] | index("a.sh (+1/-0)")' "$TPL")" = "null" ] \
       && [ "$(jq -r '[.entries[].src] | index("Is it the same action?")' "$TPL")" = "null" ] \
       && [ "$(jq -r '[.entries[].src] | index("Given A When B Then C")' "$TPL")" = "null" ] \
       && [ "$(jq -r '[.entries[].src] | index("X-1")' "$TPL")" = "null" ]; then
      ok "J13 日本語を含まない値（ASCII の識別子・既に英語の質問文と AC 文面）は英訳対象に入らない"
    else bad "J13 英語の値が英訳対象に混ざっている"; fi
    jq -c '._meta.translated_at = "2026-01-01" | ._meta.translator = "test"
           | .entries = [.entries[] | .en = ("EN:" + .key)]' "$TPL" > "$WORK/lab-fix.json"
    # 許可パス外の日本語 = 生成器のフィールド追加。state 直下 / state.pr 直下 / questions.*.instructions 直下 /
    # 配列要素の 4 か所へ別々に置き、TRANSLATABLE_PATHS へ広いパターンを足す変異が 1 か所ずつ赤くなるようにする
    drift_set() { # $1=出力 $2=sed 式
      sed "$2" "$LABSET" > "$1"
    }
    drift_set "$WORK/d-state.jsonl"  's|"category":"testing"|"category":"testing","note":"許可パス外の日本語"|'
    drift_set "$WORK/d-pr.jsonl"     's|"number":7|"number":7,"note":"許可パス外の日本語"|'
    drift_set "$WORK/d-instr.jsonl"  's|"question":"Is it the same action?"|"question":"Is it the same action?","note":"許可パス外の日本語"|'
    drift_set "$WORK/d-array.jsonl"  's|"a.sh (+1/-0)"|"a.sh (+1/-0)","docs/設計メモ.md (+1/-0)"|'
    DRIFT_OK=1
    DRIFT_DETAIL=""
    for d in d-state d-pr d-instr d-array; do
      lab --template "$WORK/$d.jsonl" --out "$WORK/lab-x.json"
      if [ "$RC" -eq 2 ] && grep -q '許可パス外' <<<"$ERR"; then :; else DRIFT_OK=0; DRIFT_DETAIL="$DRIFT_DETAIL $d(template:rc=$RC)"; fi
      lab --translate "$WORK/$d.jsonl" --translations "$WORK/lab-fix.json" --out "$WORK/lab-x.jsonl"
      if [ "$RC" -eq 2 ]; then :; else DRIFT_OK=0; DRIFT_DETAIL="$DRIFT_DETAIL $d(translate:rc=$RC)"; fi
    done
    if [ "$DRIFT_OK" -eq 1 ]; then
      ok "J14 許可パス外の日本語は state 直下 / state.pr 直下 / instructions 直下 / 配列要素のいずれでも exit 2（--template / --translate の両方）"
    else bad "J14 許可パス外の日本語を通した:$DRIFT_DETAIL"; fi
    # 日本語検出の字種。1 値に複数字種を混ぜると 1 域の欠落を検出できないので、字種ごとに単独の値を置く
    JA_OK=1
    JA_DETAIL=""
    for spec in "hira:てすと" "kata:テスト" "han:設計" "full:＃＄％"; do
      name="${spec%%:*}"; value="${spec#*:}"
      sed "s|\"category\":\"testing\"|\"category\":\"testing\",\"note\":\"$value\"|" "$LABSET" > "$WORK/ja-$name.jsonl"
      lab --template "$WORK/ja-$name.jsonl" --out "$WORK/lab-x.json"
      if [ "$RC" -eq 2 ] && grep -q '許可パス外' <<<"$ERR"; then :; else JA_OK=0; JA_DETAIL="$JA_DETAIL $name(rc=$RC)"; fi
    done
    if [ "$JA_OK" -eq 1 ]; then
      ok "J15 日本語検出はひらがな / カタカナ / 漢字 / 全角記号のそれぞれ単独で効く（1 域を落とす変異を通さない）"
    else bad "J15 検出できない字種がある:$JA_DETAIL"; fi
    printf '{"id":"cjk","group":"pos","state":{"id":"Z","category":"testing","title":"﨑","body":"𠮟"},"questions":%s,"expected":{"same_action":true}}\n' "$NOVQ" > "$WORK/lab-cjk.jsonl"
    lab --template "$WORK/lab-cjk.jsonl" --out "$WORK/lab-cjk.json"
    if [ "$RC" -eq 0 ] && [ "$(jq -r '.entries | length' "$WORK/lab-cjk.json")" -eq 3 ] \
       && [ "$(jq -r '[.entries[].src] | index("﨑")' "$WORK/lab-cjk.json")" != "null" ] \
       && [ "$(jq -r '[.entries[].src] | index("𠮟")' "$WORK/lab-cjk.json")" != "null" ]; then
      ok "J16 CJK 互換漢字（﨑）と拡張 B（𠮟）も日本語として英訳対象に入る（域の列挙漏れがない）"
    else bad "J16 rc=$RC srcs=$(jq -c '[.entries[].src]' "$WORK/lab-cjk.json" 2>/dev/null)"; fi

    # ---- --translate ---------------------------------------------------------
    lab --translate "$LABSET" --translations "$WORK/lab-fix.json" --out "$WORK/lab-en.jsonl"
    if [ "$RC" -eq 0 ] && [ "$OUT" = "translated=4 replaced=9 keys=7 out=$WORK/lab-en.jsonl" ] \
       && [ "$(jq -r '.id' "$WORK/lab-en.jsonl" | tr '\n' ' ')" = "lab-1 lab-2 lab-3 lab-4 " ] \
       && [ "$(jq -s -r '[.[] | select(.lang != "en")] | length' "$WORK/lab-en.jsonl")" -eq 0 ]; then
      ok "J17 --translate は id を変えずに lang=en を付け、許可パスの日本語だけを置換する"
    else bad "J17 rc=$RC out=$OUT err=$ERR"; fi
    if [ "$(jq -r 'select(.id=="lab-3") | .state.pr.files[0]' "$WORK/lab-en.jsonl")" = "a.sh (+1/-0)" ] \
       && [ "$(jq -r 'select(.id=="lab-3") | .state.pr.number' "$WORK/lab-en.jsonl")" = "7" ] \
       && [ "$(jq -r 'select(.id=="lab-3") | .state.evidence' "$WORK/lab-en.jsonl")" = "suite 9/9 pass" ] \
       && [ "$(jq -r 'select(.id=="lab-1") | .questions.same_action.instructions.question' "$WORK/lab-en.jsonl")" = "Is it the same action?" ] \
       && [ "$(jq -r 'select(.id=="lab-1") | .questions.same_action.criteria.true' "$WORK/lab-en.jsonl")" = "same action" ] \
       && [ "$(jq -r 'select(.id=="lab-1") | .expected.same_action' "$WORK/lab-en.jsonl")" = "true" ]; then
      ok "J18 識別子・質問文（instructions.question）・criteria・expected は不変（動かすのは判定対象の日本語だけ）"
    else bad "J18 判定対象以外が書き換わっている"; fi
    if [ "$(jq -r 'select(.id=="lab-1") | .questions.same_action.instructions.candidate' "$WORK/lab-en.jsonl")" \
       = "$(jq -r 'select(.id=="lab-2") | .questions.same_action.instructions.candidate' "$WORK/lab-en.jsonl")" ] \
       && [ "$(jq -r 'select(.id=="lab-1") | .questions.same_action.instructions.candidate' "$WORK/lab-en.jsonl")" != "候補の一行要約" ]; then
      ok "J19 候補文（instructions.candidate）も英訳され、行をまたいで共有する日本語には同じ英訳が当たる"
    else bad "J19 候補文が未置換、または pos / neg で訳が割れた"; fi
    lab --translate "$LABSET" --translations "$WORK/lab-fix.json" --out "$WORK/lab-en2.jsonl"
    if [ "$RC" -eq 0 ] && cmp -s "$WORK/lab-en.jsonl" "$WORK/lab-en2.jsonl"; then
      ok "J20 --translate は決定的（同じ入力で出力がバイト同一）"
    else bad "J20 再実行で出力が変わった rc=$RC"; fi
    jq -c '.entries = [.entries[] | select(.src != "候補の一行要約")]' "$WORK/lab-fix.json" > "$WORK/lab-miss.json"
    lab --translate "$LABSET" --translations "$WORK/lab-miss.json" --out "$WORK/lab-x.jsonl"
    RC_MISS="$RC"; ERR_MISS="$ERR"
    lab --translate "$WORK/lab-ja.jsonl" --translations "$WORK/lab-fix.json" --out "$WORK/lab-x.jsonl"
    if [ "$RC_MISS" -eq 2 ] && grep -q '翻訳の無い原文' <<<"$ERR_MISS" \
       && [ "$RC" -eq 2 ] && grep -q '使われない項目' <<<"$ERR"; then
      ok "J21 翻訳の無い原文も、使われない fixture 項目も exit 2（無翻訳のまま送らない / セットと fixture のずれを通さない）"
    else bad "J21 missing=$RC_MISS unused=$RC err=$ERR"; fi
    # 未使用項目は「キーが原文のハッシュと一致する本物」でないと readFixture の検証が先に当たる。
    # 別セット（LABSET5）の template から取り、両セットが共有する候補文だけ除いて重ねる
    lab --template "$LABSET5" --out "$WORK/five-tpl.json"
    jq -s -c '(((.[0].entries | map(select(.src != "候補の一行要約")))
                + (.[1].entries | map(select(.src != "候補の一行要約") | .en = ("EN5:" + .key)))) as $e
               | .[0] | .entries = $e)' "$WORK/lab-fix.json" "$WORK/five-tpl.json" > "$WORK/lab-both.json"
    lab --translate "$LABSET" --translations "$WORK/lab-both.json" --out "$WORK/lab-x.jsonl"
    if [ "$RC" -eq 2 ] && grep -q '翻訳の無い原文' <<<"$ERR" && grep -q '使われない項目' <<<"$ERR"; then
      ok "J22 missing と unused が同時にあるときは両方を 1 回で報告する（片方ずつ直す往復を作らない）"
    else bad "J22 rc=$RC err=$ERR"; fi
    jq -c '.entries = [.entries[] | if .src == "候補の一行要約" then .src = "書き換えた原文" else . end]' "$WORK/lab-fix.json" > "$WORK/lab-x.json"
    lab --translate "$LABSET" --translations "$WORK/lab-x.json" --out "$WORK/lab-x.jsonl"
    if [ "$RC" -eq 2 ] && grep -q 'ハッシュ' <<<"$ERR"; then
      ok "J23 src がキーのハッシュと一致しない fixture は exit 2（キーが原文と結び付いていない）"
    else bad "J23 rc=$RC err=$ERR"; fi
    FIXG_OK=1
    FIXG_DETAIL=""
    fixture_reject() { # $1=名前 $2=jq 式
      jq -c "$2" "$WORK/lab-fix.json" > "$WORK/fx-$1.json"
      lab --translate "$LABSET" --translations "$WORK/fx-$1.json" --out "$WORK/lab-x.jsonl"
      [ "$RC" -eq 2 ] || { FIXG_OK=0; FIXG_DETAIL="$FIXG_DETAIL $1(rc=$RC)"; }
    }
    fixture_reject empty-en '.entries = [.entries[] | if .src == "候補の一行要約" then .en = "" else . end]'
    fixture_reject entries-empty '.entries = []'
    fixture_reject dup-key '.entries = .entries + [.entries[0]]'
    fixture_reject non-string '.entries = [.entries[] | if .src == "候補の一行要約" then .en = 1 else . end]'
    fixture_reject no-translator 'del(._meta.translator)'
    fixture_reject no-date 'del(._meta.translated_at)'
    fixture_reject no-meta 'del(._meta)'
    if [ "$FIXG_OK" -eq 1 ]; then
      ok "J24 fixture の空の訳 / entries 空 / 重複キー / 非文字列 / _meta（translator・translated_at・全体）欠落はすべて exit 2"
    else bad "J24 通した fixture がある:$FIXG_DETAIL"; fi
    lab --translate "$LABSET" --translations "$TPL" --out "$WORK/lab-x.jsonl"
    if [ "$RC" -eq 2 ] && grep -q '未翻訳' <<<"$ERR"; then
      ok "J25 未翻訳テンプレのままの適用は exit 2（出所の無い訳を通さない）"
    else bad "J25 rc=$RC err=$ERR"; fi
    # 訳の中の日本語: 地の文に残れば訳し忘れ、コードスパン内なら訳さない識別子。境界を確定できない形は判定不能
    CS_OK=1
    CS_DETAIL=""
    code_span_case() { # $1=名前 $2=en の値 $3=期待 rc
      jq -c --arg en "$2" '.entries = [.entries[] | if .src == "候補の一行要約" then .en = $en else . end]' "$WORK/lab-fix.json" > "$WORK/cs-$1.json"
      lab --translate "$LABSET" --translations "$WORK/cs-$1.json" --out "$WORK/lab-x.jsonl"
      [ "$RC" -eq "$3" ] || { CS_OK=0; CS_DETAIL="$CS_DETAIL $1(rc=$RC want=$3)"; }
    }
    code_span_case plain        'the 一行要約 here' 2
    code_span_case in-span      'the marker `空振り検出` here' 0
    code_span_case two-spans    'the `a` and `b` and 一行要約' 2
    code_span_case unequal-runs '`identifier`` 一行要約 `other`' 2
    # 長さの違う列を対にすると span が内側で切れて日本語が地の文へ出てしまう形。
    # 同じ長さの列だけを対にする実装では 1 つの span に収まるので通る（この 1 本だけが
    # 「長さ一致」を測る — 上の unequal-runs は未閉鎖側の判定でも同じ rc になるため）
    code_span_case nested-runs  '``a` 一行要約 `b``' 0
    code_span_case unclosed     'the `open and 一行要約 here' 2
    code_span_case fenced       'the ```` ```ts ```` fence and `b` marker' 0
    code_span_case fenced-ja    'the ```` ```ts ```` fence 一行要約 here' 2
    if [ "$CS_OK" -eq 1 ]; then
      ok "J26 訳の日本語判定: 地の文は exit 2 / コードスパン内は通す / 2 個目以降のスパンも剥がす / 長さの違う列を対にしない / 未閉鎖は判定不能で exit 2"
    else bad "J26 コードスパン判定が誤っている:$CS_DETAIL"; fi

    # ---- --compare -----------------------------------------------------------
    mk_res() { # $1=出力ファイル $2..=「id:group:match:confidence」。expected は共通、predicted は match に従う
      local out="$1"; shift
      : > "$out"
      local spec rid rg rm rconf
      for spec in "$@"; do
        IFS=: read -r rid rg rm rconf <<<"$spec"
        printf '{"id":"%s","group":"%s","usage":{"input_tokens":100},"latency_ms":500,"cost_usd":0.00001,"answers":[{"qid":"q","type":"noul","expected":true,"predicted":%s,"raw":0.9,"match":%s,"confidence":%s}]}\n' \
          "$rid" "$rg" "$rm" "$rm" "$rconf" >> "$out"
      done
    }
    mk_res "$WORK/ra.jsonl" "a:pos:true:0.9" "b:pos:false:0.3" "c:neg:true:0.7" "d:neg:false:0.5"
    mk_res "$WORK/rb.jsonl" "a:pos:true:0.9" "b:pos:true:0.85" "c:neg:false:0.2" "d:neg:false:0.5"
    lab --compare "$WORK/ra.jsonl" --with "$WORK/rb.jsonl"
    if [ "$RC" -eq 0 ] \
       && grep -q '| ja | 4 | 2 | 50.0% | 400 | 100.0 |' <<<"$OUT" \
       && grep -q '| en | 4 | 2 | 50.0% | 400 | 100.0 |' <<<"$OUT" \
       && grep -q '入力トークンの差: +0（ja 比 0.0%）' <<<"$OUT" \
       && grep -q 'ja だけ外した（1）: b' <<<"$OUT" \
       && grep -q 'en だけ外した（1）: c' <<<"$OUT" \
       && grep -q '両方外した（1）: d' <<<"$OUT"; then
      ok "J27 --compare は全体一致率・入力トークンの差・不一致 id の差集合（ja だけ / en だけ / 両方）を表で出す"
    else bad "J27 rc=$RC out=$OUT err=$ERR"; fi
    if grep -q '| 予測が変わった（一致 / 不一致を問わず） | 2 |' <<<"$OUT" \
       && grep -q '| pos | 2 | 50.0% | 100.0% | +50.0 |' <<<"$OUT" \
       && grep -q '| neg | 2 | 50.0% | 0.0% | -50.0 |' <<<"$OUT" \
       && grep -qF '| [0.8, 1.0] | 1 | 100.0% | 2 | 100.0% |' <<<"$OUT"; then
      ok "J28 予測が変わった件数・group 別・confidence 帯別が各言語の自分の値で並ぶ"
    else bad "J28 group / 帯別 / flipped の行が出ていない: $OUT"; fi
    mk_res "$WORK/r10.jsonl" "a:pos:true:1.0"
    lab --compare "$WORK/r10.jsonl" --with "$WORK/r10.jsonl"
    if [ "$RC" -eq 0 ] && grep -qF '| [0.8, 1.0] | 1 | 100.0% | 1 | 100.0% |' <<<"$OUT"; then
      ok "J29 confidence がちょうど 1.0 の行は最上位帯に入る（上限が閉じている）"
    else bad "J29 rc=$RC out=$OUT"; fi
    printf '{"id":"a","group":"pos","usage":{"input_tokens":100},"answers":[{"qid":"q","expected":true,"predicted":true,"match":true}]}\n' > "$WORK/rnc.jsonl"
    printf '{"id":"a","group":"pos","usage":{"input_tokens":100},"answers":[{"qid":"q","expected":true,"predicted":false,"match":false,"confidence":0.9}]}\n' > "$WORK/rc9.jsonl"
    lab --compare "$WORK/rnc.jsonl" --with "$WORK/rc9.jsonl"
    RC_NB1="$RC"; OUT_NB1="$OUT"
    lab --compare "$WORK/rc9.jsonl" --with "$WORK/rnc.jsonl"
    if [ "$RC_NB1" -eq 0 ] && grep -q '| (confidence なし) | 1 | 100.0% | 0 | - |' <<<"$OUT_NB1" \
       && [ "$RC" -eq 0 ] && grep -q '| (confidence なし) | 0 | - | 1 | 100.0% |' <<<"$OUT"; then
      ok "J30 confidence の無い行は片側だけでも帯別表に出し、両側とも一致率を計算する（件数を表から落とさない）"
    else bad "J30 ja欠落=$RC_NB1 en欠落=$RC out=$OUT"; fi
    mk_res "$WORK/rid.jsonl" "a:pos:true:0.9" "z:pos:true:0.9"
    lab --compare "$WORK/ra.jsonl" --with "$WORK/rid.jsonl"
    if [ "$RC" -eq 2 ] && grep -q 'id 集合が一致しません' <<<"$ERR"; then
      ok "J31 id 集合が違う結果は exit 2（対になっていないものを比べない）"
    else bad "J31 rc=$RC err=$ERR"; fi
    mk_res "$WORK/rgrp.jsonl" "a:pos:true:0.9" "b:pos:true:0.85" "c:MUT:false:0.2" "d:neg:false:0.5"
    lab --compare "$WORK/ra.jsonl" --with "$WORK/rgrp.jsonl"
    RC_GRP="$RC"; ERR_GRP="$ERR"
    sed 's/"expected":true/"expected":false/' "$WORK/rb.jsonl" > "$WORK/rexp.jsonl"
    lab --compare "$WORK/ra.jsonl" --with "$WORK/rexp.jsonl"
    RC_EXP="$RC"
    sed 's/"qid":"q"/"qid":"other"/' "$WORK/rb.jsonl" > "$WORK/rqid.jsonl"
    lab --compare "$WORK/ra.jsonl" --with "$WORK/rqid.jsonl"
    if [ "$RC_GRP" -eq 2 ] && grep -q 'group' <<<"$ERR_GRP" && [ "$RC_EXP" -eq 2 ] && [ "$RC" -eq 2 ]; then
      ok "J32 同じ id の group / expected / qid が ja・en で違えば exit 2（別条件の実行を言語差として集計しない。NaN を出さない）"
    else bad "J32 group=$RC_GRP expected=$RC_EXP qid=$RC err=$ERR"; fi
    { cat "$WORK/ra.jsonl"; head -1 "$WORK/ra.jsonl"; } > "$WORK/rdup.jsonl"
    lab --compare "$WORK/rdup.jsonl" --with "$WORK/rdup.jsonl"
    if [ "$RC" -eq 2 ] && grep -q '重複 id' <<<"$ERR"; then
      ok "J33 結果ファイル内の重複 id は exit 2"
    else bad "J33 rc=$RC err=$ERR"; fi
    printf '{"id":"a","usage":{"input_tokens":100},"answers":[{"qid":"q","expected":true,"predicted":true}]}\n' > "$WORK/rd.jsonl"
    lab --compare "$WORK/rd.jsonl" --with "$WORK/rd.jsonl"
    RC_NOMATCH="$RC"
    printf '{"id":"a","answers":[{"qid":"q","expected":true,"predicted":true,"match":true}]}\n' > "$WORK/re.jsonl"
    lab --compare "$WORK/re.jsonl" --with "$WORK/re.jsonl"
    RC_NOUSAGE="$RC"
    printf '{"id":"a","usage":{"input_tokens":100},"answers":[{"qid":"q","expected":true,"match":true}]}\n' > "$WORK/rp.jsonl"
    lab --compare "$WORK/rp.jsonl" --with "$WORK/rp.jsonl"
    RC_NOPRED="$RC"
    printf '{"id":"a","usage":{"input_tokens":100},"answers":[{"qid":"q","expected":true,"predicted":true,"match":true},{"qid":"r","expected":true,"predicted":true,"match":true}]}\n' > "$WORK/r2.jsonl"
    lab --compare "$WORK/r2.jsonl" --with "$WORK/r2.jsonl"
    if [ "$RC_NOMATCH" -eq 2 ] && [ "$RC_NOUSAGE" -eq 2 ] && [ "$RC_NOPRED" -eq 2 ] && [ "$RC" -eq 2 ]; then
      ok "J34 結果行の match / usage.input_tokens / predicted の欠落と、1 行に 2 問以上ある形は exit 2"
    else bad "J34 match=$RC_NOMATCH usage=$RC_NOUSAGE predicted=$RC_NOPRED 複数問=$RC"; fi
    printf '{"id":"a","group":"pos","usage":{"input_tokens":0},"answers":[{"qid":"q","expected":true,"predicted":true,"match":true,"confidence":0.9}]}\n' > "$WORK/rz.jsonl"
    lab --compare "$WORK/rz.jsonl" --with "$WORK/rc9.jsonl"
    if [ "$RC" -eq 0 ] && grep -q '（ja 比 -）' <<<"$OUT" && ! grep -q 'Infinity' <<<"$OUT"; then
      ok "J35 ja 側の入力トークンが 0 でも Infinity% を出さない"
    else bad "J35 rc=$RC out=$OUT"; fi
    printf 'not json\n' > "$WORK/rbad.jsonl"
    lab --compare "$WORK/rbad.jsonl" --with "$WORK/rbad.jsonl"
    RC_BADJSON="$RC"
    lab --compare "$WORK/ra.jsonl" --out "$WORK/x"
    if [ "$RC_BADJSON" -eq 2 ] && [ "$RC" -eq 2 ] && grep -q '\-\-with が必要' <<<"$ERR"; then
      ok "J36 結果が JSON として読めない行と --with 欠落は exit 2"
    else bad "J36 壊れたJSON=$RC_BADJSON --with欠落=$RC err=$ERR"; fi
    lab --extract "$LABSET" --template "$LABSET" --out "$WORK/lab-x.json"
    RC_MODES="$RC"
    lab --extract "$LABSET" --out "$WORK/lab-x.jsonl" --count 1 --unknown x
    RC_UNKNOWN="$RC"
    lab --extract "$LABSET" --extract "$LABSET5" --out "$WORK/lab-x.jsonl" --count 1
    RC_DUPFLAG="$RC"
    lab --translate "$LABSET" --out "$WORK/lab-x.jsonl"
    if [ "$RC_MODES" -eq 2 ] && [ "$RC_UNKNOWN" -eq 2 ] && [ "$RC_DUPFLAG" -eq 2 ] && [ "$RC" -eq 2 ] \
       && grep -q '\-\-translations が必要' <<<"$ERR"; then
      ok "J37 モード併用 / 未知オプション / 同じフラグ 2 回 / --translations 欠落は exit 2"
    else bad "J37 併用=$RC_MODES 未知=$RC_UNKNOWN 二重=$RC_DUPFLAG --translations欠落=$RC"; fi

    # ---- 同梱の翻訳 fixture（SSOT 専用。公開 checkout には無いので部分 skip）----
    LANGFIX_DIR="$PLUGIN_ROOT/../../docs/04-quality/jev-lang-ab"
    LANGFIX_NOV="$LANGFIX_DIR/lang-ab-novelty-en.json"
    LANGFIX_CI="$LANGFIX_DIR/lang-ab-close-issue-en.json"
    # 公開 checkout には両方とも無い（SSOT 専用）ので、その回だけ部分 skip。
    # 片方だけ消えているのは配置 drift なので、skip へ倒さず赤にする
    if [ ! -f "$LANGFIX_NOV" ] && [ ! -f "$LANGFIX_CI" ]; then
      echo "  ○ skip: 翻訳 fixture は SSOT 専用のため J38 / J39 を実行していません（${LANGFIX_DIR}）"
    elif [ ! -f "$LANGFIX_NOV" ] || [ ! -f "$LANGFIX_CI" ]; then
      bad "J38 翻訳 fixture が片方しかありません（片側の消失を部分 skip へ倒さない）: $LANGFIX_DIR"
      bad "J39 翻訳 fixture が片方しかないため readFixture 経由の検査を実行できません: $LANGFIX_DIR"
    else
      FIXOK=1
      for f in "$LANGFIX_NOV" "$LANGFIX_CI"; do
        jq -e '(._meta.translated_at | type == "string") and (._meta.translated_at != "(未翻訳)")
               and (._meta.translator | type == "string") and (._meta.translator != "(未翻訳)")
               and ((._meta.source_ids | length) == 60)
               and ((.entries | length) > 0)
               and (([.entries[] | select((.src | explode | map(select(. > 12287)) | length) > 0)] | length) == (.entries | length))
               and ((.entries | map(.key) | unique | length) == (.entries | length))' "$f" >/dev/null 2>&1 || FIXOK=0
      done
      if [ "$FIXOK" -eq 1 ]; then
        ok "J38 同梱の翻訳 fixture 2 本は _meta（翻訳日 / 翻訳者 / 原文 id 60 件）を持ち、entries が空でなく key が一意で、全項目の src が日本語の原文"
      else bad "J38 翻訳 fixture が契約を満たしていない: $LANGFIX_DIR"; fi
      # 同梱 fixture を実際に readFixture へ通す。jq で形だけ見ると、翻訳キーの綴りが変わって
      # 全項目が key 不一致になっても緑のままになる（形は正しいが原文と結び付いていない状態）
      printf '{"id":"probe","group":"pos","state":{"id":"P","category":"testing","title":"この原文は fixture に無い","body":"照合用。"},"questions":%s,"expected":{"same_action":true}}\n' "$NOVQ" > "$WORK/probe.jsonl"
      LIVE_OK=1
      LIVE_DETAIL=""
      for f in "$LANGFIX_NOV" "$LANGFIX_CI"; do
        lab --translate "$WORK/probe.jsonl" --translations "$f" --out "$WORK/lab-x.jsonl"
        # 期待: fixture 自体は受理され、セットとのずれ（翻訳の無い原文 / 使われない項目）で止まる
        if [ "$RC" -eq 2 ] && grep -q '使われない項目' <<<"$ERR" \
           && ! grep -qE 'ハッシュ|_meta|重複キー|コードスパン|entries 配列|JSON として読めません' <<<"$ERR"; then :
        else LIVE_OK=0; LIVE_DETAIL="$LIVE_DETAIL $(basename "$f")(rc=$RC)"; fi
      done
      if [ "$LIVE_OK" -eq 1 ]; then
        ok "J39 同梱の翻訳 fixture 2 本は readFixture を通る（key が src のハッシュと一致し、訳に地の文の日本語が無い）"
      else bad "J39 同梱 fixture が readFixture を通らない:$LIVE_DETAIL err=$ERR"; fi
    fi
  fi
fi
# ================================================================================
echo "== K. 切替入口 jev-decide.sh（FF_JEV_MODE の二段構え）=="
DLOG="$WORK/decisions.jsonl"
run_decide_args() { # $1..=環境（VAR=val）、-- の後がスクリプト引数。FF_JEV_ENABLED / キー / 記録先は呼び出し側で与える
  local envs=()
  while [ $# -gt 0 ] && [ "$1" != "--" ]; do envs+=("$1"); shift; done
  [ "${1:-}" = "--" ] && shift
  OUT="$( env -i HOME="$ISO_HOME" PATH="$FAKE/bin:$PATH" TMPDIR="$WORK" FAKE_CURL_DIR="$FAKE" \
        ${envs[@]+"${envs[@]}"} bash "$DECIDE" "$@" 2>"$WORK/stderr" )"; RC=$?
  ERR="$(cat "$WORK/stderr")"
}
ON="FF_JEV_MODE=on FF_JEV_ENABLED=1 TYPESAFE_API_KEY_FILE=$KEY_FILE FF_JEV_DECISION_LOG=$DLOG FF_JEV_POINTS=probe,novelty,retro,dept-check"
last_body_model() { # 直近の偽 curl 呼び出しの request body の model
  local n; n="$(calls)"; jq -r '.model' "$FAKE/call.$n.body" 2>/dev/null
}

rm -f "$DLOG"; reset_fake 200
run_decide_args FF_JEV_ENABLED=1 TYPESAFE_API_KEY_FILE="$KEY_FILE" FF_JEV_DECISION_LOG="$DLOG" -- novelty --questions "$Q" --state-file "$STATE"
if [ "$RC" -eq 12 ] && grep -q '^JEV_DECISION=off$' <<<"$OUT" && grep -q '^JEV_REASON=mode-off$' <<<"$OUT" \
   && [ "$(calls)" -eq 0 ] && [ ! -e "$DLOG" ]; then
  ok "K1 FF_JEV_MODE 未設定はキーがあっても通信せず記録も書かず exit 12（mode-off）"
else bad "K1 rc=$RC calls=$(calls) log=$([ -e "$DLOG" ] && echo exists || echo none) out=$OUT"; fi

reset_fake 200
run_decide_args FF_JEV_MODE=off FF_JEV_ENABLED=1 TYPESAFE_API_KEY_FILE="$KEY_FILE" FF_JEV_DECISION_LOG="$DLOG" -- novelty --questions "$Q" --state-file "$STATE"
[ "$RC" -eq 12 ] && [ "$(calls)" -eq 0 ] && ok "K2 FF_JEV_MODE=off も exit 12 で通信しない" || bad "K2 rc=$RC calls=$(calls)"

reset_fake 200
run_decide_args FF_JEV_MODE=maybe FF_JEV_ENABLED=1 TYPESAFE_API_KEY_FILE="$KEY_FILE" FF_JEV_DECISION_LOG="$DLOG" -- novelty --questions "$Q" --state-file "$STATE"
[ "$RC" -eq 64 ] && [ "$(calls)" -eq 0 ] && ok "K3 未知の FF_JEV_MODE は off へ倒さず exit 64" || bad "K3 rc=$RC calls=$(calls)"

reset_fake 200
run_decide_args $ON FF_JEV_POINTS= -- novelty --questions "$Q" --state-file "$STATE"
if [ "$RC" -eq 12 ] && grep -q '^JEV_REASON=point-not-listed$' <<<"$OUT" && [ "$(calls)" -eq 0 ] && [ ! -e "$DLOG" ]; then
  ok "K4 設定済みの空 FF_JEV_POINTS は 0 件（既定へ戻らない）— exit 12 point-not-listed で通信も記録もしない"
else bad "K4 rc=$RC calls=$(calls) out=$OUT"; fi

reset_fake 200
run_decide_args $ON FF_JEV_POINTS="retro,other" -- novelty --questions "$Q" --state-file "$STATE"
[ "$RC" -eq 12 ] && [ "$(calls)" -eq 0 ] && ok "K5 名簿に無い判定点は exit 12（カンマ区切りも受ける）" || bad "K5 rc=$RC calls=$(calls)"

reset_fake 200
run_decide_args $ON FF_JEV_POINTS="retro,novelty" -- Novelty --questions "$Q" --state-file "$STATE"
[ "$RC" -eq 64 ] && [ "$(calls)" -eq 0 ] && ok "K6 判定点名は英小文字・数字・- だけ（大文字は exit 64。名簿照合を緩めない）" || bad "K6 rc=$RC calls=$(calls)"

rm -f "$DLOG"; reset_fake 200
run_decide_args FF_JEV_MODE=on TYPESAFE_API_KEY_FILE="$KEY_FILE" FF_JEV_DECISION_LOG="$DLOG" -- novelty --questions "$Q" --state-file "$STATE"
if [ "$RC" -eq 11 ] && grep -q '^JEV_REASON=disabled$' <<<"$OUT" && [ "$(calls)" -eq 0 ] \
   && [ "$(jq -r 'select(.event=="decision") | "\(.decision)/\(.reason)/\(.point)"' "$DLOG" 2>/dev/null)" = "fallback/disabled/novelty" ]; then
  ok "K7 on だけでは課金経路が開かない — FF_JEV_ENABLED 無しは通信せず exit 11 disabled、記録に fallback/disabled が残る"
else bad "K7 rc=$RC calls=$(calls) out=$OUT log=$(cat "$DLOG" 2>/dev/null)"; fi

rm -f "$DLOG"; reset_fake 200
run_decide_args $ON -- probe --questions "$Q" --state-file "$STATE"
if [ "$RC" -eq 10 ] && grep -q '^JEV_DECISION=fallback$' <<<"$OUT" && grep -q '^JEV_REASON=low-confidence$' <<<"$OUT" \
   && grep -q '^JEV_THRESHOLD=0.99$' <<<"$OUT" && grep -q '^ANSWER=dept|choice|billing|0.81$' <<<"$OUT" \
   && [ "$(calls)" -eq 1 ] \
   && [ "$(jq -r 'select(.event=="decision") | "\(.decision)/\(.reason)/\(.threshold)/\(.answers.dept.confidence)/\(.model)"' "$DLOG")" = "fallback/low-confidence/0.99/0.81/jev-1.13.0" ]; then
  ok "K8 共通既定 0.99（組み込み既定の無い判定点 probe）で最小 confidence 0.81 は exit 10 low-confidence（判定は出す・記録に閾値と confidence と model が残る）"
else bad "K8 rc=$RC calls=$(calls) out=$OUT log=$(cat "$DLOG" 2>/dev/null)"; fi
[ "$(last_body_model)" = "jev-1.13.0" ] && ok "K9 TYPESAFE_MODEL 未指定は request の model を jev-1.13.0 に固定する" || bad "K9 model=$(last_body_model)"

reset_fake 200
run_decide_args $ON TYPESAFE_MODEL=jev-latest FF_JEV_MIN_CONFIDENCE=0.8 -- probe --questions "$Q" --state-file "$STATE"
if [ "$RC" -eq 0 ] && grep -q '^JEV_DECISION=adopt$' <<<"$OUT" && grep -q '^JEV_DECISION_ID=' <<<"$OUT" \
   && [ "$(last_body_model)" = "jev-latest" ] \
   && [ "$(jq -r 'select(.event=="decision" and .decision=="adopt") | .reason' "$DLOG")" = "confident" ]; then
  ok "K10 全質問の confidence ≥ 閾値（0.8）なら exit 0 adopt。明示の TYPESAFE_MODEL はそのまま通る。記録に adopt/confident"
else bad "K10 rc=$RC out=$OUT model=$(last_body_model)"; fi
ADOPT_ID="$(sed -n 's/^JEV_DECISION_ID=//p' <<<"$OUT")"

reset_fake 200
PT_VAR="FF_JEV_MIN_CONFIDENCE_$(printf '%s' dept-check | tr 'a-z-' 'A-Z_')"
run_decide_args $ON FF_JEV_MIN_CONFIDENCE=0.99 "${PT_VAR}=0.8" -- dept-check --questions "$Q" --state-file "$STATE" --json
if [ "$RC" -eq 0 ] && [ "$(printf '%s' "$OUT" | jq -r '.decision + "/" + (.threshold|tostring)')" = "adopt/0.8" ]; then
  ok "K11 判定点別の閾値 FF_JEV_MIN_CONFIDENCE_<POINT>（- は _）が共通の閾値に勝つ（--json は decision / threshold を持つ）"
else bad "K11 rc=$RC out=$OUT"; fi

reset_fake 200
run_decide_args $ON FF_JEV_MIN_CONFIDENCE=abc -- probe --questions "$Q" --state-file "$STATE"
[ "$RC" -eq 64 ] && [ "$(calls)" -eq 0 ] && ok "K12 非数値の閾値は exit 64（通信しない）" || bad "K12 rc=$RC calls=$(calls)"
reset_fake 200
run_decide_args $ON FF_JEV_MIN_CONFIDENCE=1.5 -- probe --questions "$Q" --state-file "$STATE"
[ "$RC" -eq 64 ] && [ "$(calls)" -eq 0 ] && ok "K13 1 を超える閾値も exit 64（全件 fallback の設定を黙って通さない）" || bad "K13 rc=$RC calls=$(calls)"
reset_fake 200
run_decide_args $ON FF_JEV_MIN_CONFIDENCE=. -- probe --questions "$Q" --state-file "$STATE"
[ "$RC" -eq 64 ] && [ "$(calls)" -eq 0 ] && ok "K13e 数字を含まない \".\" は exit 64（文字種検査は通るが awk が 0 と読む形を「閾値 0 で全件採用」にしない）" || bad "K13e rc=$RC calls=$(calls) out=$OUT"
reset_fake 200
PT_VAR2="FF_JEV_MIN_CONFIDENCE_$(printf '%s' probe | tr 'a-z' 'A-Z')"
run_decide_args $ON "${PT_VAR2}=." -- probe --questions "$Q" --state-file "$STATE"
[ "$RC" -eq 64 ] && [ "$(calls)" -eq 0 ] && ok "K13f 判定点別の閾値でも \".\" は exit 64" || bad "K13f rc=$RC calls=$(calls)"
for v in .5 0.81 1; do
  reset_fake 200
  run_decide_args $ON FF_JEV_MIN_CONFIDENCE="$v" -- probe --questions "$Q" --state-file "$STATE"
  case "$v" in .5|0.81) want=0 ;; *) want=10 ;; esac
  [ "$RC" -eq "$want" ] || { bad "K13g 閾値 $v: rc=$RC (want $want) out=$OUT"; want=; }
done
[ -n "${want:-}" ] && ok "K13g 閾値 .5 / 0.81 / 1 は受理され記録行も組み立てられる（.5 と 0.81 は最小 confidence 0.81 で adopt、1 は exit 10）"
for v in 0 0.0 1.; do
  reset_fake 200
  run_decide_args $ON FF_JEV_MIN_CONFIDENCE="$v" -- probe --questions "$Q" --state-file "$STATE"
  [ "$RC" -eq 64 ] && [ "$(calls)" -eq 0 ] || { bad "K13h 閾値 $v: rc=$RC calls=$(calls)"; want=; }
done
[ -n "${want:-}" ] && ok "K13h 閾値 0 / 0.0（全件採用）と 1.（jq が読めない）は exit 64 で通信しない"
reset_fake 200
run_decide_args $ON FF_JEV_POINTS="Novelty,probe" -- probe --questions "$Q" --state-file "$STATE"
[ "$RC" -eq 64 ] && [ "$(calls)" -eq 0 ] && ok "K13i 名簿の綴り違い（Novelty）は exit 64（判定点を黙って off にしない）" || bad "K13i rc=$RC calls=$(calls)"
run_decide_args FF_JEV_MODE=off FF_JEV_POINTS="Novelty" -- --status
[ "$RC" -eq 64 ] && ok "K13j --status も名簿の綴り違いを exit 64 で名乗る" || bad "K13j rc=$RC out=$OUT"
reset_fake 200
run_decide_args $ON LC_ALL=ja_JP.UTF-8 LANG=ja_JP.UTF-8 -- Novelty --questions "$Q" --state-file "$STATE"
[ "$RC" -eq 64 ] && [ "$(calls)" -eq 0 ] && ok "K13k ja_JP.UTF-8 ロケールでも大文字の判定点名は exit 64（範囲照合の locale 依存を C で固定）" || bad "K13k rc=$RC calls=$(calls)"

# Noul の判定点 novelty / retro は組み込み既定 0.6（Noul の confidence は最大 0.94 で 0.99 帯が無い）。共通 env は組み込みに勝つ
reset_fake 200
run_decide_args $ON -- novelty --questions "$Q" --state-file "$STATE"
if [ "$RC" -eq 0 ] && grep -q '^JEV_THRESHOLD=0.6$' <<<"$OUT"; then
  ok "K13b novelty の組み込み既定は 0.6（最小 confidence 0.81 ≥ 0.6 で adopt）。共通既定 0.99 を Noul の判定点へ流用しない"
else bad "K13b rc=$RC out=$OUT"; fi
reset_fake 200
run_decide_args $ON FF_JEV_MIN_CONFIDENCE=0.9 -- retro --questions "$Q" --state-file "$STATE"
[ "$RC" -eq 10 ] && grep -q '^JEV_THRESHOLD=0.9$' <<<"$OUT" && ok "K13c 共通 env FF_JEV_MIN_CONFIDENCE は組み込み既定（retro 0.6）に勝つ" || bad "K13c rc=$RC out=$OUT"
run_decide_args FF_JEV_MODE=off FF_JEV_POINTS="novelty,retro,probe" -- --status
if [ "$RC" -eq 0 ] && grep -q '^JEV_THRESHOLD_NOVELTY=0.6$' <<<"$OUT" && grep -q '^JEV_THRESHOLD_RETRO=0.6$' <<<"$OUT" && grep -q '^JEV_THRESHOLD_PROBE=0.99$' <<<"$OUT"; then
  ok "K13d --status は名簿の判定点ごとの実効閾値を出す（novelty / retro 0.6、その他 0.99）"
else bad "K13d rc=$RC out=$OUT"; fi

reset_fake 401
run_decide_args $ON -- probe --questions "$Q" --state-file "$STATE"
if [ "$RC" -eq 11 ] && grep -q '^JEV_REASON=unauthorized$' <<<"$OUT" \
   && [ "$(jq -r 'select(.event=="decision" and .reason=="unauthorized") | .judge_rc' "$DLOG")" = "5" ]; then
  ok "K14 Jev の失敗は exit 11 で種別を保持する（401 → unauthorized、記録に judge_rc=5）"
else bad "K14 rc=$RC out=$OUT"; fi

# 記録先へ書けない: ディレクトリを指す
mkdir -p "$WORK/logdir"
reset_fake 200
run_decide_args $ON FF_JEV_MIN_CONFIDENCE=0.8 FF_JEV_DECISION_LOG="$WORK/logdir" -- probe --questions "$Q" --state-file "$STATE"
if [ "$RC" -eq 11 ] && grep -q '^JEV_DECISION=fallback$' <<<"$OUT" && grep -q '^JEV_REASON=log-unwritable$' <<<"$OUT"; then
  ok "K15 記録先へ書けなければ採用条件を満たしていても exit 11 log-unwritable（記録の無い採用を作らない）"
else bad "K15 rc=$RC out=$OUT"; fi
reset_fake 401
run_decide_args $ON FF_JEV_DECISION_LOG="$WORK/logdir" -- probe --questions "$Q" --state-file "$STATE"
[ "$RC" -eq 11 ] && grep -q '^JEV_REASON=log-unwritable$' <<<"$OUT" && grep -q '元の失敗: unauthorized' <<<"$ERR" \
  && ok "K15b Jev 失敗 + 記録先へ書けない回は log-unwritable を名乗りつつ元の失敗種別（unauthorized）を stderr に残す" || bad "K15b rc=$RC out=$OUT err=$ERR"

# --fill
QF="$WORK/questions-fill.json"
cat > "$QF" <<'EOF'
{ "same": { "type": "noul", "instructions": { "candidate": "{{CANDIDATE}}", "question": "Same?" } } }
EOF
printf '候補の一行要約\n' > "$WORK/cand.txt"
reset_fake 200
run_decide_args $ON -- novelty --questions "$QF" --state-file "$STATE"
[ "$RC" -eq 2 ] && [ "$(calls)" -eq 0 ] && grep -q 'プレースホルダ' <<<"$ERR" && ok "K16 置換されない {{KEY}} が残る questions は送らず exit 2" || bad "K16 rc=$RC calls=$(calls) err=$ERR"
reset_fake 200
printf '%s' '{"model":"jev-1.13.0","answers":{"same":{"type":"noul","noul":0.02}},"usage":{"input_tokens":10,"output_tokens":1}}' > "$FAKE/body.200"
run_decide_args $ON FF_JEV_MIN_CONFIDENCE=0.9 -- novelty --questions "$QF" --state-file "$STATE" --fill CANDIDATE="$WORK/cand.txt"
n="$(calls)"
if [ "$RC" -eq 0 ] && [ "$(jq -r '.questions.same.instructions.candidate' "$FAKE/call.$n.body")" = "候補の一行要約" ] \
   && grep -q '^ANSWER=same|noul|0.02|0.96$' <<<"$OUT"; then
  ok "K17 --fill KEY=<file> は {{KEY}} をファイル内容（末尾改行なし）で置換して送る。noul の confidence は |p-0.5|*2"
else bad "K17 rc=$RC body=$(cat "$FAKE/call.$n.body" 2>/dev/null) out=$OUT"; fi
reset_fake 200
run_decide_args $ON -- novelty --questions "$QF" --state-file "$STATE" --fill CANDIDATE="$WORK/no-such-file"
[ "$RC" -eq 2 ] && [ "$(calls)" -eq 0 ] && ok "K18 --fill のファイルが読めなければ送らず exit 2" || bad "K18 rc=$RC calls=$(calls)"
reset_fake 200
run_decide_args $ON -- novelty --questions "$QF" --state-file "$STATE" --fill candidate="$WORK/cand.txt"
[ "$RC" -eq 64 ] && ok "K19 --fill の KEY は英大文字・数字・_ だけ（小文字は exit 64）" || bad "K19 rc=$RC"
printf '{ "same": { "type": "noul", "instructions": { "candidate": "{{candidate}}", "question": "Same?" } } }\n' > "$WORK/questions-lower.json"
reset_fake 200
run_decide_args $ON -- probe --questions "$WORK/questions-lower.json" --state-file "$STATE"
[ "$RC" -eq 2 ] && [ "$(calls)" -eq 0 ] && ok "K19b 小文字のプレースホルダ {{candidate}} も「置換されていない」として送らず exit 2" || bad "K19b rc=$RC calls=$(calls)"
printf 'not json\n' > "$WORK/questions-bad.json"
reset_fake 200
run_decide_args $ON -- probe --questions "$WORK/questions-bad.json" --state-file "$STATE"
[ "$RC" -eq 2 ] && [ "$(calls)" -eq 0 ] && [ "$(jq -r 'select(.point=="probe" and .reason=="invalid-input") | .id' "$DLOG" 2>/dev/null | wc -l | tr -d ' ')" = "0" ] \
  && ok "K19c JSON でない questions は exit 2（jq の失敗を「プレースホルダ無し」へ読み替えて exit 11 + 記録にしない）" || bad "K19c rc=$RC calls=$(calls)"
printf '{ "same": { "type": "noul", "instructions": { "candidate": "Candidate: {{CANDIDATE}} (end)", "question": "Same?" } } }\n' > "$WORK/questions-mid.json"
reset_fake 200
printf '%s' '{"model":"jev-1.13.0","answers":{"same":{"type":"noul","noul":0.99}},"usage":{"input_tokens":10,"output_tokens":1}}' > "$FAKE/body.200"
run_decide_args $ON FF_JEV_MIN_CONFIDENCE=0.9 -- probe --questions "$WORK/questions-mid.json" --state-file "$STATE" --fill CANDIDATE="$WORK/cand.txt"
n="$(calls)"
[ "$RC" -eq 0 ] && [ "$(jq -r '.questions.same.instructions.candidate' "$FAKE/call.$n.body")" = "Candidate: 候補の一行要約 (end)" ] \
  && ok "K19d 文中のプレースホルダも置換される（値全体一致に限らない）" || bad "K19d rc=$RC body=$(cat "$FAKE/call.$n.body" 2>/dev/null)"
rm -f "$FAKE/body.200"
reset_fake 200
mkdir -p "$WORK/filldir"
run_decide_args $ON -- probe --questions "$QF" --state-file "$STATE" --fill CANDIDATE="$WORK/filldir"
[ "$RC" -eq 2 ] && [ "$(calls)" -eq 0 ] && grep -q -- '--fill CANDIDATE' <<<"$ERR" && ok "K19e --fill にディレクトリを渡すと exit 2 で --fill 側の誤りとして名乗る" || bad "K19e rc=$RC err=$ERR"
: > "$WORK/empty-fill.txt"
reset_fake 200
run_decide_args $ON -- probe --questions "$QF" --state-file "$STATE" --fill CANDIDATE="$WORK/empty-fill.txt"
[ "$RC" -eq 2 ] && [ "$(calls)" -eq 0 ] && ok "K19f 空の --fill ファイルは exit 2（空の候補文を送らない）" || bad "K19f rc=$RC calls=$(calls)"
printf '{ "a": { "type": "noul", "instructions": "{{X}} and {{Y}}" }, "b": { "type": "noul", "instructions": "{{Y}}" } }\n' > "$WORK/questions-two.json"
printf 'ex\n' > "$WORK/x.txt"; printf 'why\n' > "$WORK/y.txt"
reset_fake 200
printf '%s' '{"model":"jev-1.13.0","answers":{"a":{"type":"noul","noul":0.99},"b":{"type":"noul","noul":0.01}},"usage":{"input_tokens":10,"output_tokens":1}}' > "$FAKE/body.200"
run_decide_args $ON FF_JEV_MIN_CONFIDENCE=0.9 -- probe --questions "$WORK/questions-two.json" --state-file "$STATE" --fill X="$WORK/x.txt" --fill Y="$WORK/y.txt"
n="$(calls)"
[ "$RC" -eq 0 ] && [ "$(jq -r '.questions.a.instructions + "|" + .questions.b.instructions' "$FAKE/call.$n.body")" = "ex and why|why" ] \
  && ok "K19g 複数の --fill は全キーを全出現箇所で置換する" || bad "K19g rc=$RC body=$(cat "$FAKE/call.$n.body" 2>/dev/null)"
rm -f "$FAKE/body.200"
reset_fake 200
printf '%s' '{"model":"jev-1.13.0","answers":{"same_action":{"type":"noul","noul":0.93}},"usage":{"input_tokens":10,"output_tokens":1}}' > "$FAKE/body.200"
run_decide_args $ON -- novelty --questions "$SAME_ACTION_Q" --state-file "$STATE" --fill CANDIDATE="$WORK/cand.txt"
n="$(calls)"
if [ "$RC" -eq 0 ] && ! grep -q '{{' "$FAKE/call.$n.body" && grep -q '^ANSWER=same_action|noul|0.93|0.86$' <<<"$OUT" \
   && [ "$(jq -r '.questions.same_action.instructions.candidate' "$FAKE/call.$n.body")" = "候補の一行要約" ]; then
  ok "K19h 同梱 fixture same-action.json は decide 経由で候補が埋まり {{ が残らず、novelty の既定 0.6 で adopt する"
else bad "K19h rc=$RC out=$OUT body=$(cat "$FAKE/call.$n.body" 2>/dev/null)"; fi
rm -f "$FAKE/body.200"

# 複数質問: 1 つでも閾値未満なら採用しない（Q の最小は dept 0.81）
reset_fake 200
run_decide_args $ON FF_JEV_MIN_CONFIDENCE=0.85 -- probe --questions "$Q" --state-file "$STATE"
[ "$RC" -eq 10 ] && ok "K20 複数質問は最小 confidence で判定する（0.81 < 0.85 → exit 10。他の質問が 0.9 以上でも採用しない）" || bad "K20 rc=$RC out=$OUT"
reset_fake 200
OUT="$( env -i HOME="$ISO_HOME" PATH="$FAKE/bin:$PATH" TMPDIR="$WORK" FAKE_CURL_DIR="$FAKE" $ON bash "$DECIDE" probe --questions "$Q" --json < "$STATE" 2>"$WORK/stderr" )"; RC=$?
[ "$RC" -eq 10 ] && [ "$(calls)" -eq 1 ] && [ "$(printf '%s' "$OUT" | jq -r '.decision + "/" + .reason + "/" + (.id|type)')" = "fallback/low-confidence/string" ] \
  && ok "K20b state は stdin からも読める。--json の exit 10 は decision / reason / id を持つ" || bad "K20b rc=$RC calls=$(calls) out=$OUT"
reset_fake 200
: > "$WORK/empty-state.txt"
run_decide_args $ON -- probe --questions "$Q" --state-file "$WORK/empty-state.txt"
[ "$RC" -eq 2 ] && [ "$(calls)" -eq 0 ] && ok "K20c 空の state は送らず exit 2" || bad "K20c rc=$RC calls=$(calls)"
reset_fake "429 retry-after=0" "429 retry-after=0" "429 retry-after=0" "429 retry-after=0" "429 retry-after=0"
run_decide_args $ON -- probe --questions "$Q" --state-file "$STATE"
[ "$RC" -eq 11 ] && grep -q '^JEV_REASON=rate-limited$' <<<"$OUT" && grep -q '^JEV_DECISION_ID=' <<<"$OUT" && [ "$(calls)" -eq 5 ] \
  && [ "$(jq -r 'select(.event=="decision" and .reason=="rate-limited") | .judge_rc' "$DLOG")" = "7" ] \
  && ok "K20d 429 疲弊は exit 11 rate-limited（judge_rc 7）で、記録できた回は JEV_DECISION_ID も出す" || bad "K20d rc=$RC calls=$(calls) out=$OUT"

# --summarize / --overturn
run_decide_args -- --summarize --log "$DLOG"
if [ "$RC" -eq 0 ] && grep -q '^| probe | ' <<<"$OUT" && grep -q '^| dept-check | 1 | 1 |' <<<"$OUT"; then
  ok "K21 --summarize は判定点別に total / adopt / fallback / 帯別 / 覆した率の表を出す"
else bad "K21 rc=$RC out=$OUT"; fi
run_decide_args -- --summarize --log "$DLOG" --json
[ "$RC" -eq 0 ] && [ "$(printf '%s' "$OUT" | jq -r '[.[] | select(.point=="probe")][0] | .fallback["low-confidence"] >= 2 and .fallback.unauthorized == 1 and .adopt >= 1')" = "true" ] \
  && ok "K22 --summarize --json は fallback を理由別に数える" || bad "K22 rc=$RC out=$OUT"
run_decide_args -- --overturn "$ADOPT_ID" --log "$DLOG" --note "reader disagreed"
run_decide_args -- --summarize --log "$DLOG" --json
if [ "$(printf '%s' "$OUT" | jq -r '[.[] | select(.point=="probe")][0].overturned')" = "1" ]; then
  ok "K23 --overturn は adopt した決定を覆した記録を足し、集計の overturned に数える"
else bad "K23 out=$OUT"; fi
FB_ID="$(jq -r 'select(.event=="decision" and .decision=="fallback") | .id' "$DLOG" | head -n 1)"
run_decide_args -- --overturn "$FB_ID" --log "$DLOG"
[ "$RC" -eq 2 ] && ok "K24 fallback した決定は --overturn できない（exit 2。覆せるのは採用した判定だけ）" || bad "K24 rc=$RC"
run_decide_args -- --summarize --log "$WORK/no-log.jsonl"
[ "$RC" -eq 2 ] && ok "K25 記録が無い --summarize は空の表を出さず exit 2" || bad "K25 rc=$RC out=$OUT"
cp "$DLOG" "$WORK/broken.jsonl"; printf 'not json\n' >> "$WORK/broken.jsonl"
run_decide_args -- --summarize --log "$WORK/broken.jsonl"
[ "$RC" -eq 2 ] && ok "K26 読めない行を含む記録は集計せず exit 2" || bad "K26 rc=$RC"
{ printf '{"event":"x"}\n'; cat "$DLOG"; } > "$WORK/broken2.jsonl"
run_decide_args -- --summarize --log "$WORK/broken2.jsonl"
[ "$RC" -eq 2 ] && ok "K26b 先頭に不正な event の行があり末尾が正常でも集計せず exit 2（jq -e の「最後の出力」で判定しない）" || bad "K26b rc=$RC"
{ printf '{"event":"decision"}\n'; cat "$DLOG"; } > "$WORK/broken3.jsonl"
run_decide_args -- --summarize --log "$WORK/broken3.jsonl"
[ "$RC" -eq 2 ] && ok "K26c point / decision / answers を欠く decision 行も集計せず exit 2" || bad "K26c rc=$RC"
printf '{"event":"overturn","ref":"x","ts":"t","note":""}\n' > "$WORK/only-ov.jsonl"
run_decide_args -- --summarize --log "$WORK/only-ov.jsonl"
[ "$RC" -eq 2 ] && ok "K27 decision の行が 1 行も無い記録は集計せず exit 2" || bad "K27 rc=$RC"
{
  for c in 0.5 0.6 0.9 0.95 0.99; do
    printf '{"event":"decision","id":"b-%s","ts":"t","point":"band","decision":"adopt","reason":"confident","threshold":0.5,"model":"m","answers":{"q":{"type":"noul","value":0.9,"confidence":%s}}}\n' "$c" "$c"
  done
  printf '{"event":"decision","id":"b-err","ts":"t","point":"band","decision":"fallback","reason":"unauthorized","threshold":0.5,"model":"m","answers":{}}\n'
  printf '{"event":"overturn","ref":"b-0.99","ts":"t","note":""}\n'
  printf '{"event":"overturn","ref":"b-0.99","ts":"t","note":"twice"}\n'
} > "$WORK/bands.jsonl"
run_decide_args -- --summarize --log "$WORK/bands.jsonl" --json
if [ "$RC" -eq 0 ] && [ "$(printf '%s' "$OUT" | jq -c '.[0] | [.total,.adopt,.bands["ge_0.60"],.bands["ge_0.90"],.bands["ge_0.95"],.bands["ge_0.99"],.overturned]')" = "[6,5,4,3,2,1,1]" ]; then
  ok "K27b 帯は境界値を含む（0.6 → 4 / 0.9 → 3 / 0.95 → 2 / 0.99 → 1）、answers:{} は 0 扱い、同じ id の --overturn 2 回は 1 と数える"
else bad "K27b rc=$RC out=$OUT"; fi
run_decide_args -- --summarize --log "$WORK/bands.jsonl"
grep -q '^| band | 6 | 5 | 0 | 1 | 4 | 3 | 2 | 1 | 1/5 (20%) |$' <<<"$OUT" && ok "K27c 表形式も同じ値（覆した率 1/5 = 20%）" || bad "K27c out=$OUT"
mkdir -p "$WORK/repo/sub" && ( cd "$WORK/repo" && git init -q . ) && reset_fake 200
OUT="$( cd "$WORK/repo/sub" && env -i HOME="$ISO_HOME" PATH="$FAKE/bin:$PATH" TMPDIR="$WORK" FAKE_CURL_DIR="$FAKE" FF_JEV_MODE=on FF_JEV_ENABLED=1 TYPESAFE_API_KEY_FILE="$KEY_FILE" bash "$DECIDE" retro --questions "$Q" --state-file "$STATE" 2>"$WORK/stderr" )"; RC=$?
DEFLOG="$(ls "$ISO_HOME"/.local/state/ff-dev-toolkit/jev-decisions/repo-*.jsonl 2>/dev/null | head -n 1)"
if [ "$RC" -eq 0 ] && [ -n "$DEFLOG" ] && [ -s "$DEFLOG" ] && [ -z "$( cd "$WORK/repo" && git status --porcelain --untracked-files=all )" ]; then
  ok "K27d FF_JEV_DECISION_LOG 未指定は作業ツリーの外（XDG state/ff-dev-toolkit/jev-decisions/<repo>-<hash>.jsonl。ディレクトリは作る）へ記録し、リポジトリに untracked を残さない。既定の名簿に retro が含まれ、組み込み 0.6 で adopt"
else bad "K27d rc=$RC log=$DEFLOG status=$( cd "$WORK/repo" && git status --porcelain --untracked-files=all ) err=$(cat "$WORK/stderr")"; fi
mkdir -p "$WORK/nogit" && reset_fake 200
OUT="$( cd "$WORK/nogit" && env -i HOME="$ISO_HOME" PATH="$FAKE/bin:$PATH" TMPDIR="$WORK" FAKE_CURL_DIR="$FAKE" GIT_CEILING_DIRECTORIES="$WORK" FF_JEV_MODE=on FF_JEV_ENABLED=1 TYPESAFE_API_KEY_FILE="$KEY_FILE" bash "$DECIDE" novelty --questions "$Q" --state-file "$STATE" 2>"$WORK/stderr" )"; RC=$?
DEFLOG2="$(ls "$ISO_HOME"/.local/state/ff-dev-toolkit/jev-decisions/nogit-*.jsonl 2>/dev/null | head -n 1)"
[ "$RC" -eq 0 ] && [ -n "$DEFLOG2" ] && [ -s "$DEFLOG2" ] && [ ! -e "$WORK/nogit/.ff-dev-toolkit" ] && ok "K27e git 管理外の cwd は cwd の basename で XDG state 側に記録し、cwd には何も作らない" || bad "K27e rc=$RC log=$DEFLOG2 ls=$(ls -a "$WORK/nogit" 2>/dev/null)"

reset_fake 200
run_decide_args FF_JEV_MODE=off -- --status
[ "$RC" -eq 0 ] && grep -q '^JEV_MODE=off$' <<<"$OUT" && grep -q '^JEV_POINTS=novelty retro$' <<<"$OUT" && grep -q '^JEV_THRESHOLD=0.99$' <<<"$OUT" && grep -q '^JEV_MODEL=jev-1.13.0$' <<<"$OUT" && [ "$(calls)" -eq 0 ] \
  && ok "K28 --status は実効設定（mode / 既定の名簿 novelty retro / 閾値 / 固定 model）を通信せずに出す" || bad "K28 rc=$RC out=$OUT"
run_decide_args FF_JEV_MODE=off -- --status --json
[ "$RC" -eq 0 ] && [ "$(printf '%s' "$OUT" | jq -r '[.thresholds.novelty, .thresholds.retro, .threshold, .enabled, .points] | @tsv')" = "$(printf '0.6\t0.6\t0.99\tfalse\tnovelty retro')" ] \
  && ok "K28b --status --json は thresholds / threshold / enabled / points を持つ" || bad "K28b rc=$RC out=$OUT"
run_decide_args FF_JEV_MIN_CONFIDENCE=. -- --status --json
[ "$RC" -eq 64 ] && ok "K28c --status も \".\" の閾値を exit 64 で止める（JSON 組み立て失敗を exit 0 にしない）" || bad "K28c rc=$RC out=$OUT"
mkdir -p "$WORK/nojq"; for b in bash date env tr sed awk cat git dirname mkdir; do p="$(command -v "$b")" && ln -sf "$p" "$WORK/nojq/$b"; done
OUT="$( env -i HOME="$ISO_HOME" PATH="$WORK/nojq" TMPDIR="$WORK" bash "$DECIDE" novelty --questions "$Q" --state-file "$STATE" 2>"$WORK/stderr" )"; RC=$?
[ "$RC" -eq 12 ] && ok "K28d jq が無くても off は exit 12（off の経路は依存に触れない）" || bad "K28d rc=$RC err=$(cat "$WORK/stderr")"
OUT="$( env -i HOME="$ISO_HOME" PATH="$WORK/nojq" TMPDIR="$WORK" FF_JEV_MODE=on FF_JEV_DECISION_LOG="$DLOG" bash "$DECIDE" novelty --questions "$Q" --state-file "$STATE" 2>"$WORK/stderr" )"; RC=$?
[ "$RC" -eq 69 ] && ok "K28e on で jq が無ければ exit 69（従来経路へ黙って落とさない）" || bad "K28e rc=$RC"

# 同梱 fixture: 生成器の novelty 質問と同一文言
if jq -e '.same_action.type == "noul" and (.same_action.instructions.candidate == "{{CANDIDATE}}") and (.same_action.criteria | has("true") and has("false"))' "$SAME_ACTION_Q" >/dev/null 2>&1; then
  ok "K29 questions/same-action.json は noul / {{CANDIDATE}} / true・false の criteria を持つ"
else bad "K29 fixture の形が契約と違う: $SAME_ACTION_Q"; fi
# 生成器が実際に出した novelty 質問（H 節の合成 Playbook から生成した $WORK/syn1）と、fixture の
# question / criteria.true / criteria.false を**完全一致**で比べる。candidate だけが差し替え部分。
# 部分一致（文の一部を grep）では否定側の criteria を反転しても通るので、全文で比べる
if [ -s "$WORK/syn1/novelty-pairs.jsonl" ]; then
  GENQ="$(head -n 1 "$WORK/syn1/novelty-pairs.jsonl" | jq -c '.questions.same_action | .instructions.candidate = "{{CANDIDATE}}"')"
  FIXQ="$(jq -c '.same_action' "$SAME_ACTION_Q")"
  if [ -n "$GENQ" ] && [ "$GENQ" = "$FIXQ" ]; then
    ok "K30 fixture の質問（question / criteria.true / criteria.false / type）は生成器 build-ace-eval-sets.ts が実際に出す novelty 質問と完全一致（offline の帯別表がそのまま閾値の根拠になる）"
  else bad "K30 fixture と生成器の質問が食い違う: gen=$GENQ fix=$FIXQ"; fi
else
  # 生成器を起動できない環境（H 節 skip）では、TS 側の文字列定数と部分一致で照合する（弱い側の代替。skip ではなく赤）
  FIXQ="$(jq -r '.same_action.instructions.question' "$SAME_ACTION_Q")"
  FIXT="$(jq -r '.same_action.criteria.true' "$SAME_ACTION_Q")"
  FIXF="$(jev_q_false="$(jq -r '.same_action.criteria.false' "$SAME_ACTION_Q")"; printf '%s' "$jev_q_false")"
  case "$FIXQ" in *"Would a reader who acts on \`candidate\` take the same executable action as a reader of the existing entry?"*) FIXQ_OK=1 ;; *) FIXQ_OK=0 ;; esac
  if [ "$FIXQ_OK" -eq 1 ] && grep -qF -- "$FIXT" "$ACE_GEN" && grep -qF -- "$FIXF" "$ACE_GEN" \
     && grep -qF -- "answer no if the candidate leads to a different action." "$ACE_GEN"; then
    ok "K30 fixture の質問文と criteria（true / false）は生成器 build-ace-eval-sets.ts の文字列と一致（生成器を起動できない環境の代替照合）"
  else bad "K30 fixture の質問文が生成器と食い違う"; fi
fi
rm -f "$FAKE/body.200"

# ================================================================================
echo
echo "jev-adapter: ${PASS} passed, ${FAIL} failed"
FF_REACHED_END=1
[ "$FAIL" -eq 0 ]
