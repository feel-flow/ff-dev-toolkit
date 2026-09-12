#!/usr/bin/env bash

#
# 工数実績 未記入マージガード（PreToolUse / Bash）。
#
# `gh pr merge` が閉じようとしている Issue の本文に `ff-effort` ブロックが
# **あるのに** `effort_ai_actual` が未記入のままなら、マージ前に停止する。
# `/close-issue`（AC 照合 + 工数の書き戻し）を通らずに `Closes` / `Refs` 付きの
# PR をマージすると、Issue は閉じるが実績は未記入のままになり、集計器
# `scripts/effort-report.sh` の較正母集団から `excluded_planned_only` として
# 静かに落ちる。呼ばれなければ 1 行も実行されない散文のゲートを、マージ操作の
# 直前という実際に通る経路へ移すのがこの hook の役割。
#
# **`ff-effort` ブロックが無い Issue では止めない**。ブロック不在は
# skills/close-issue/SKILL.md 手順 5a の意図的な fail-open（遡及付与を強制すると
# 既存 Issue のマージが工数欄の記入待ちで止まる）で、この hook はその契約を
# 変えない。止めるのは「ブロックがあるのに未記入」だけで、この 2 状態の区別が
# ガードの本体である。
#
# 未記入の定義は集計器 `scripts/effort-report.sh` の分類（マーカー判定・キー解析・
# `as_days()`・`malformed` / `planned_only` への振り分け）と**同形**にする。止めるのは
# 「同じ本文を集計器が `planned_only` として母集団から落とす」状態だけ:
#   - マーカーは `<!-- ff-effort:begin -->` / `<!-- ff-effort:end -->` の**行全体の
#     完全一致**（行末 CR だけ落とす）。字下げ・行末空白つきのマーカーは集計器では
#     ブロック不在（noblock）扱いなので、この hook も止めない — 母集団の外に居る
#     Issue を止めても実績は永久に集計されず、停止に意味が無い
#   - ブロック不在 / 未閉鎖 / begin が 2 組 / end が begin より前 / キー重複は
#     集計器では noblock か malformed。どちらも素通しする
#   - `effort_human_planned` / `effort_ai_planned` / `effort_ai_actual` のいずれかが
#     `^[0-9]+(\.[0-9]+)?d$` でない（0 以下も含む）値なら集計器では malformed。
#     兄弟キーの書式不正でも素通しする（書式不正は集計器が名指しする担当）
#   - 止めるのは `effort_ai_actual` がキー不在 / 空 / `(未記入)` のときだけ
# 本文が CRLF でも同じ判定になるよう、集計器と同じく行末の CR を落としてから見る
# （落とさないとマーカーが一致せず、集計器が `planned_only` として静かに落とす
# 本文こそガードが素通ししてしまう）。
#
# PreToolUse には「実行を許しつつ agent に警告文を見せる」チャネルが無い
# （additionalContext 非対応）ため、停止は**抜け道付きの deny**として実装する。
# 抜け道は deny の本文で必ず案内する（案内の無い deny は詰まりになる）:
#   - 対象コマンドの先頭に環境代入 `FF_EFFORT_ACTUAL_ACK=1` を付ける
#     （文字列としてコマンド中に現れるだけでは無効。コマンド位置の
#     `gh pr merge` の直前に置いた場合だけ素通しする）
#   - ガードごと止めるなら環境変数 `FF_DEV_TOOLKIT_SKIP_EFFORT_ACTUAL_GUARD=1`
#
# 判定の流れ:
#   1. heredoc 本文（`<<` / `<<-` のトークン以降、終端行まで）を走査対象から落とし、
#      クォートの閉じていないセグメントを捨てたうえで、コマンド位置の `gh pr merge`
#      を含むセグメントを特定する（`echo 'gh pr merge ...'` では発火しない）
#   2. PR 指定（番号 / URL / ブランチ。省略時は現在のブランチ）と `--repo` を拾い、
#      `gh pr view --json number,body,url,closingIssuesReferences` で PR を読む
#   3. 閉じる Issue の集合は GitHub が解決済みの `closingIssuesReferences` を正本に取る。
#      それが空のときだけ PR 本文の closing keyword / `Refs` を走査する
#   4. 各 Issue を `gh issue view --json body,state` で読み、CLOSED は対象から外し、
#      上の未記入判定に当たるものを集めて deny する
#
# `Refs` を closing keyword と同じ基準で見る（このマージで閉じるかどうかに関わらず
# 実績は要る）一方、**閉じない参照**まで停止対象にすると、長命の tracking / Epic Issue
# を `Refs` で参照する運用のリポジトリでは、その配下の sub-PR のマージが恒常的に止まる。
# sub-PR は自分の Issue を closing keyword で閉じるので、閉じる集合が取れたときは
# 本文走査そのものを行わない。これで `Refs` 運用（closing keyword を書かない PR）の
# 判定は保ったまま、tracking Issue の巻き込みと Issue 個別照会の件数を同時に減らせる。
#
# CLOSED の Issue は対象から外す。deny 本文の第 1 選択肢である `/close-issue <PR番号>`
# は「Issue を閉じながら実績を書き戻す」手順なので、既に閉じた Issue には効かない。
# 外さないと、閉じた Issue を参照しただけの PR が恒久的に迂回手段でしか通らなくなる。
#
# 既知の限界（判定できず素通しする形）:
#   - `owner/repo` 修飾つきの完全修飾参照（別リポジトリの Issue を現リポジトリの
#     番号として引かないため、意図的に対象外にしている。`closingIssuesReferences`
#     から取る場合も、PR と同じリポジトリの Issue だけに絞る）
#   - `GH-` 接頭辞形式・Issue の完全 URL での参照
#   - PR 本文以外（コミット件名など）にだけ Issue 参照がある場合
#   - `gh` の認証切れ・オフライン・PR 指定を解決できない形（fail-open）
#   - `closingIssuesReferences` を返さない古い `gh`（PR 取得ごと失敗して素通しする）。
#     本文走査だけへ落とすフォールバックは置かない — 閉じる集合が取れない状態で `Refs` を
#     走査すると、上に書いた tracking Issue の恒常停止がそのまま戻るため
#   - heredoc 本文に書かれた `gh pr merge`（データであって実行されるコマンドではない）
#   - クォートの閉じていないセグメント。区切り記号（`;` / `&&` / `|`）をクォートの
#     内側に持つコマンドは、素朴な分割でセグメントが割れた証拠としてそのセグメントを
#     捨てる。`echo 'gh pr merge 42; gh pr merge 43'` はこれで素通しになるが、
#     同じ理由で実マージ側も取りこぼしうる（deny 側の誤検知を避けて fail-open へ倒す）
#   - 変数展開・コマンド置換の中で組み立てられる `gh pr merge`
#   - 上限（`FF_EFFORT_ACTUAL_GUARD_MAX_ISSUES`）を超えた分の Issue は照会しない。
#     打ち切りは fail-open（照会しなかった Issue は無かったものとして扱う）で、
#     上限に達したこと自体は deny の理由にしない
#
# 設計原則:
#   - fail-open: 全 Bash 呼び出しに割り込むため、自身の不具合や解析不能な形、
#     `gh` / `jq` 不在では黙って許可（exit 0・無出力）に倒す。検査不能を
#     「違反」と読み替えない。
#   - 互換性: bash 3.2（stock macOS）互換。連想配列・readarray を使わない。
#     大文字小文字の吸収と本文の走査は `LC_ALL=C awk` で行う（grep は不一致と
#     エラーの区別が実装依存で、fail-open が fail-closed へ反転しうる）。
#
# 環境変数:
#   FF_DEV_TOOLKIT_SKIP_EFFORT_ACTUAL_GUARD=1  このガードを無効化する
#   FF_EFFORT_ACTUAL_GUARD_MAX_ISSUES          1 回の判定で照会する Issue の上限
#     （既定 5。`0` / 空 / 数値でない値は既定へ正規化する。`0` をそのまま受けると
#     最初の 1 件も照会せずガードが全無効化され、無効化の経路が opt-out と 2 つに割れる）

# fail-open のため set -e / set -u は使わない。

# stdin は bash 組み込みの read で読み切る（外部コマンドに依存しない）。`cat` だと PATH が
# 空・壊れた環境で command not found → stdin 未読のまま exit 0 となり、書き手（ホスト）が
# EPIPE / SIGPIPE を受ける。opt-out も stdin を読み切ってから抜ける。
# -d '' は EOF で非 0 を返すが input には内容が入っている。
input=""
IFS= read -r -d '' input || true

# ASDD ゲートはこの drain より後に置く。ゲートの早期終了（.asdd 設定があり node が
# 無い / 当該 feature が無効 / ヘルパ自体が読めない）は exit 0 なので、ゲートを先頭へ
# 置くと stdin 未読のまま抜ける経路ができ、上の drain が守っている EPIPE / SIGPIPE が
# そこから漏れる。ゲート自身は stdin を消費しない（asdd-hook-gate.sh）ので、読み切って
# から呼んでも hook が受け取るペイロードは変わらない。
# ASDD 2.0: disabled optional hooks do not prompt, block, or mutate.
if ! source "${BASH_SOURCE[0]%/*}/asdd-hook-gate.sh"; then
  echo 'ff-dev-toolkit: ASDD Hook helper is unavailable; optional hook skipped' >&2
  exit 0
fi
asdd_hook_enabled hooks || exit 0

[ "${FF_DEV_TOOLKIT_SKIP_EFFORT_ACTUAL_GUARD:-0}" = "1" ] && exit 0

# 安価な前置フィルタ（jq / gh / awk を 1 度も起動せずに非該当を落とす）。
# 「素通しした」だけでは前置で落ちたのか後段の解析で落ちたのかを区別できないため、
# suite は jq / awk をログ付きスタブへ差し替えて**起動回数 0** で固定する
# （この前置を削る変異は、その起動回数で赤になる）。
case "$input" in
  *merge*) : ;;
  *) exit 0 ;;
esac
case "$input" in
  *gh*) : ;;
  *) exit 0 ;;
esac

command -v jq >/dev/null 2>&1 || exit 0
command -v gh >/dev/null 2>&1 || exit 0
command -v awk >/dev/null 2>&1 || exit 0

cmd="$(printf '%s' "$input" | jq -r 'if .tool_name == "Bash" then (.tool_input.command // "") else "" end' 2>/dev/null)" || exit 0
[ -n "$cmd" ] || exit 0
case "$cmd" in
  *merge*) : ;;
  *) exit 0 ;;
esac

CWD="$(printf '%s' "$input" | jq -r '.cwd // ""' 2>/dev/null)"
[ -d "$CWD" ] || CWD="$(pwd)"

# ---- heredoc 本文を走査対象から落とす ------------------------------------------
# heredoc 本文は実行されるコマンドではなくデータなので、`cat > note.md <<'EOF'` の
# 本文に書いた `gh pr merge 42 --squash` で停止すると、メモ書きがマージガードに
# 引っかかる。走査は guard-review-in-flight.sh と同じ awk（`<<` / `<<-` の直後の
# 区切り語を積み、終端行まで読み飛ばす。`<<<` の here-string は heredoc ではない）。
# 終端行の**直後**に続く実コマンドは落とさない。
# 解析に失敗したら素通しへ倒す（guard-review-in-flight.sh は走行中ロック側なので元の
# コマンドへ倒すが、本 hook は検査不能を「違反」と読み替えない fail-open 側）。
code_only="$(printf '%s\n' "$cmd" | LC_ALL=C awk '
  function trim(s) { sub(/^[ \t]+/, "", s); sub(/[ \t]+$/, "", s); return s }
  BEGIN {
    q = sprintf("%c", 39)
    re = "<<-?[ \t]*(\"[^\"]*\"|" q "[^" q "]*" q "|[A-Za-z_][A-Za-z0-9_]*)"
    nd = 0
  }
  {
    if (nd > 0) {
      if (trim($0) == d[1]) { for (i = 1; i < nd; i++) d[i] = d[i + 1]; nd-- }
      next
    }
    scan = $0
    gsub(/<<</, "___", scan) # here-string は heredoc ではない（長さを保つ置換）
    pos = 1
    while (match(substr(scan, pos), re)) {
      st = pos + RSTART - 1
      tok = substr(scan, st, RLENGTH)
      sub(/^<<-?[ \t]*/, "", tok)
      gsub("[\"" q "]", "", tok)
      nd++
      d[nd] = tok
      pos = st + RLENGTH
    }
    print
  }
' 2>/dev/null)" || exit 0
[ -n "$code_only" ] || exit 0
case "$code_only" in
  *merge*) : ;;
  *) exit 0 ;;
esac

# セグメント分割はクォート状態を解釈しない（完全なシェル構文解析は持ち込まない）。
# そのぶん `echo 'gh pr merge 42; gh pr merge 43'` のようにクォートの内側にある
# 区切り記号でもセグメントが割れ、文字列の一部が実コマンドに見える。割れたセグメントは
# 「クォートが閉じていない」という形で判別できるので、その場合は deny 側の誤検知を
# 避けてセグメントごと捨てる（fail-open）。バックスラッシュのエスケープはクォートの
# 外とダブルクォートの中だけで効く、というシェルの規則に合わせる。
quotes_balanced() {
  printf '%s\n' "$1" | LC_ALL=C awk '
    BEGIN { q = sprintf("%c", 39); bad = 0 }
    {
      st = 0 # 0=クォートの外 1=シングル 2=ダブル
      n = length($0)
      for (i = 1; i <= n; i++) {
        c = substr($0, i, 1)
        if (st == 0) {
          if (c == "\\") { i++ }
          else if (c == q) { st = 1 }
          else if (c == "\"") { st = 2 }
        } else if (st == 1) {
          if (c == q) { st = 0 }
        } else {
          if (c == "\\") { i++ }
          else if (c == "\"") { st = 0 }
        }
      }
      if (st != 0) bad = 1
    }
    END { exit (bad ? 1 : 0) }
  ' 2>/dev/null
}

strip_quotes() {
  local s="$1"
  case "$s" in
    \"*\")
      s="${s#\"}"
      s="${s%\"}"
      ;;
    \'*\')
      s="${s#\'}"
      s="${s%\'}"
      ;;
  esac
  printf '%s' "$s"
}

# ---- コマンド位置の `gh pr merge` を含むセグメントを特定する -------------------
# 見つかったら GH_TOKS に `merge` の後ろのトークン列を積む。
GH_FOUND=0
GH_BYPASS=0
GH_TOKS=()

find_gh_segment() {
  local toks=("$@")
  local n=${#toks[@]} i=0 t bypass=0
  while [ "$i" -lt "$n" ]; do
    t="$(strip_quotes "${toks[$i]}")"
    case "$t" in
      FF_EFFORT_ACTUAL_ACK=1)
        bypass=1
        i=$((i + 1))
        continue
        ;;
      [A-Za-z_]*=*)
        i=$((i + 1))
        continue
        ;;
      env | command | sudo | nohup)
        i=$((i + 1))
        while [ "$i" -lt "$n" ]; do
          case "${toks[$i]}" in
            -*) i=$((i + 1)) ;;
            *) break ;;
          esac
        done
        continue
        ;;
      *) break ;;
    esac
  done
  [ "$i" -lt "$n" ] || return 0
  t="$(strip_quotes "${toks[$i]}")"
  case "$t" in
    gh | */gh) : ;;
    *) return 0 ;;
  esac
  [ $((i + 2)) -lt "$n" ] || return 0
  [ "$(strip_quotes "${toks[$((i + 1))]}")" = "pr" ] || return 0
  [ "$(strip_quotes "${toks[$((i + 2))]}")" = "merge" ] || return 0
  GH_FOUND=1
  GH_BYPASS="$bypass"
  GH_TOKS=()
  local k=$((i + 3))
  while [ "$k" -lt "$n" ]; do
    GH_TOKS[${#GH_TOKS[@]}]="${toks[$k]}"
    k=$((k + 1))
  done
  return 0
}

segments="$(printf '%s\n' "$code_only" | awk '{ gsub(/&&|\|\||;|\|/, "\n"); print }')"
while IFS= read -r seg; do
  [ -n "$seg" ] || continue
  case "$seg" in
    *merge*) : ;;
    *) continue ;;
  esac
  quotes_balanced "$seg" || continue
  set -f
  # shellcheck disable=SC2206 # 素朴な空白トークン化（意図的。glob は set -f で抑止）
  toks=($seg)
  set +f
  [ "$GH_FOUND" -eq 1 ] || find_gh_segment "${toks[@]}"
done <<EOF
$segments
EOF

[ "$GH_FOUND" -eq 1 ] || exit 0
# 抜け道: 対象コマンドの先頭に置かれた環境代入だけを認める
[ "$GH_BYPASS" -eq 1 ] && exit 0

# ---- PR 指定と --repo を拾う --------------------------------------------------
SELECTOR=""
REPO=""
n=${#GH_TOKS[@]}
i=0
while [ "$i" -lt "$n" ]; do
  t="$(strip_quotes "${GH_TOKS[$i]}")"
  case "$t" in
    --repo | -R)
      i=$((i + 1))
      [ "$i" -lt "$n" ] && REPO="$(strip_quotes "${GH_TOKS[$i]}")"
      ;;
    --repo=*) REPO="${t#--repo=}" ;;
    # 値を取るフラグ（次のトークンを PR 指定と誤読しない）
    --body | -b | --body-file | -F | --subject | -t | --match-head-commit | --author-email)
      i=$((i + 1))
      ;;
    -*) : ;;
    *)
      [ -n "$SELECTOR" ] || SELECTOR="$t"
      ;;
  esac
  i=$((i + 1))
done

GH_ARGS=()
if [ -n "$REPO" ]; then
  GH_ARGS[0]="--repo"
  GH_ARGS[1]="$REPO"
fi

if [ -n "$SELECTOR" ]; then
  pr_json="$(cd "$CWD" 2>/dev/null && gh pr view "$SELECTOR" ${GH_ARGS[0]:+"${GH_ARGS[@]}"} --json number,body,url,closingIssuesReferences 2>/dev/null)" || exit 0
else
  pr_json="$(cd "$CWD" 2>/dev/null && gh pr view ${GH_ARGS[0]:+"${GH_ARGS[@]}"} --json number,body,url,closingIssuesReferences 2>/dev/null)" || exit 0
fi
[ -n "$pr_json" ] || exit 0

pr_number="$(printf '%s' "$pr_json" | jq -r '.number // empty' 2>/dev/null)" || exit 0
pr_body="$(printf '%s' "$pr_json" | jq -r '.body // ""' 2>/dev/null)" || exit 0
[ -n "$pr_number" ] || exit 0

# ---- 閉じる Issue の集合（GitHub が解決済みの参照を正本にする）----------------
# PR と同じリポジトリの Issue だけに絞る（別リポジトリの番号を現リポジトリの番号として
# 引かない、という上の限界を `closingIssuesReferences` 経由でも保つ）。
closing_numbers="$(printf '%s' "$pr_json" | jq -r '
  (.url // "") as $u
  | ($u | sub("/pull/[0-9]+$"; "")) as $base
  | if ($base == "") or ($base == $u) then empty
    else
      (.closingIssuesReferences // [])[]
      | select(.number != null and ((.url // "") | startswith($base + "/issues/")))
      | .number
    end' 2>/dev/null)" || closing_numbers=""

# ---- PR 本文から Issue 参照を集める（closing keyword を書かない `Refs` 運用の PR）--
# 閉じる集合が取れたときは本文を走査しない。走査すると長命の tracking / Epic Issue への
# `Refs` まで停止対象に入り、その配下の sub-PR が恒常的に止まる。
issue_numbers="$closing_numbers"
[ -n "$issue_numbers" ] || issue_numbers="$(printf '%s\n' "$pr_body" | LC_ALL=C awk '
{
  line = " " tolower($0)
  while (match(line, /[^a-z0-9_](close[sd]?|fix(es|ed)?|resolve[sd]?|refs?)[ \t]*:?[ \t]*#[0-9]+/)) {
    tok = substr(line, RSTART, RLENGTH)
    sub(/^[^#]*#/, "", tok)
    if (!(tok in seen)) { seen[tok] = 1; print tok }
    line = substr(line, RSTART + RLENGTH)
  }
}' 2>/dev/null)"
[ -n "$issue_numbers" ] || exit 0

# 上限は「PR 本文に大量の参照がある形で PreToolUse の timeout: 10 を使い切らない」ための
# 打ち切りで、無効化スイッチではない。`0` は数値なので文字種の正規化だけでは通り抜け、
# 最初のループで break してガードが全無効化されるため、下限 1 を保証する。
MAX_ISSUES="${FF_EFFORT_ACTUAL_GUARD_MAX_ISSUES:-5}"
case "$MAX_ISSUES" in
  '' | *[!0-9]*) MAX_ISSUES=5 ;;
esac
[ "$MAX_ISSUES" -ge 1 ] 2>/dev/null || MAX_ISSUES=5

# ブロックがあるのに未記入か（集計器の planned_only と同じ判定）。マーカーの一致条件・
# キーの解析・`as_days()` の書式・malformed への振り分けは集計器の実装と同形にする。
# 終了コード 0 = 未記入（= 集計器の planned_only）/ 1 = それ以外（ブロック不在・
# 記入済み・書式不正）。
is_effort_unfilled() {
  printf '%s\n' "$1" | LC_ALL=C awk '
    function trim(s) { sub(/^[ \t]+/, "", s); sub(/[ \t]+$/, "", s); return s }
    # 集計器 as_days(): 未記入は -1、単位違い・数値でない値・0 以下は -2（書式不正）
    function as_days(s,   v) {
      s = trim(s)
      if (s == "" || s == "(未記入)") return -1
      if (s !~ /^[0-9]+(\.[0-9]+)?d$/) return -2
      sub(/d$/, "", s)
      v = s + 0
      if (v <= 0) return -2
      return v
    }
    {
      line = $0
      sub(/\r$/, "", line)   # CRLF 本文でも集計器と同じ行に見えるようにする
      if (line == "<!-- ff-effort:begin -->") {
        if (hasblock) broken = 1   # 2 組目
        inblock = 1; hasblock = 1; next
      }
      if (line == "<!-- ff-effort:end -->") {
        if (inblock != 1) broken = 1   # begin より前 / 2 組目
        inblock = 0; closed = 1; next
      }
      if (inblock != 1) next
      if (line !~ /^-[ ]*[a-z_]+[ ]*:/) next
      colon = index(line, ":")
      key = substr(line, 1, colon - 1)
      val = substr(line, colon + 1)
      sub(/^-[ ]*/, "", key); key = trim(key)
      val = trim(val)
      if (key == "effort_human_planned") { if (hp_seen) broken = 1; hp_seen = 1; hp_raw = val }
      else if (key == "effort_ai_planned") { if (ap_seen) broken = 1; ap_seen = 1; ap_raw = val }
      else if (key == "effort_ai_actual") { if (aa_seen) broken = 1; aa_seen = 1; aa_raw = val }
    }
    END {
      # ブロック不在は close-issue 手順 5a の fail-open 契約どおり止めない
      if (!hasblock) exit 1
      if (!closed) broken = 1           # 未閉鎖ブロックは集計器でも malformed
      if (broken) exit 1
      hp = hp_seen ? as_days(hp_raw) : -1
      ap = ap_seen ? as_days(ap_raw) : -1
      aa = aa_seen ? as_days(aa_raw) : -1
      # 兄弟キーの書式不正は集計器では planned_only より先に malformed へ落ちる
      if (hp == -2 || ap == -2 || aa == -2) exit 1
      if (aa < 0) exit 0                # planned_only（= 止める唯一の状態）
      exit 1
    }
  ' 2>/dev/null
}

unfilled=""
count=0
while IFS= read -r num; do
  [ -n "$num" ] || continue
  count=$((count + 1))
  [ "$count" -gt "$MAX_ISSUES" ] && break
  issue_json="$(cd "$CWD" 2>/dev/null && gh issue view "$num" ${GH_ARGS[0]:+"${GH_ARGS[@]}"} --json body,state 2>/dev/null)" || continue
  [ -n "$issue_json" ] || continue
  # 既に CLOSED の Issue は対象外（`/close-issue <PR番号>` が効かず停止が恒久化する）
  issue_state="$(printf '%s' "$issue_json" | jq -r '.state // ""' 2>/dev/null)"
  [ "$issue_state" = "CLOSED" ] && continue
  issue_body="$(printf '%s' "$issue_json" | jq -r '.body // ""' 2>/dev/null)"
  [ -n "$issue_body" ] || continue
  if is_effort_unfilled "$issue_body"; then
    unfilled="${unfilled:+$unfilled, }#${num}"
  fi
done <<EOF
$issue_numbers
EOF

[ -n "$unfilled" ] || exit 0

reason="⛔ ff-dev-toolkit guard（工数実績が未記入のままのマージ）: この PR が閉じる Issue（${unfilled}）の本文には ff-effort ブロックがありますが、effort_ai_actual が未記入です。
このままマージすると Issue は閉じますが実績は空のままで、scripts/effort-report.sh の較正母集団から excluded_planned_only として静かに落ちます。
次のいずれかで再実行してください:
  1) AI エージェントへ /close-issue ${pr_number} を実行し、AC 照合と工数実績の書き戻しを済ませてから同じマージコマンドを実行する（推奨）
  2) 実績を書き戻さずに進める場合は、対象コマンドの先頭へ環境代入を付けて再実行する: FF_EFFORT_ACTUAL_ACK=1 gh pr merge ...
ff-effort ブロックが無い Issue はこのガードの対象外です（遡及付与は強制しません）。
このガード自体を止める場合は環境変数 FF_DEV_TOOLKIT_SKIP_EFFORT_ACTUAL_GUARD=1 を設定します。"

jq -n --arg reason "$reason" \
  '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "deny", permissionDecisionReason: $reason}}' 2>/dev/null

exit 0
