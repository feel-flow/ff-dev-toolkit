#!/usr/bin/env bash

#
# 工数実績 未記入マージガード（PreToolUse / Bash・GitHub MCP）。
#
# `gh pr merge` が閉じようとしている Issue の本文に `ff-effort` ブロックが
# **あるのに** `effort_ai_actual` が未記入のままなら、マージ前に停止する。
# `/close-issue`（AC 照合 + 工数の書き戻し）を通らずに closing keyword 付きの
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
# `as_hours()`・`malformed` / `unit_mismatch` / `planned_only` への振り分け）と**同形**にする。止めるのは
# 「同じ本文を集計器が `planned_only` として母集団から落とす」状態だけ:
#   - マーカーは `<!-- ff-effort:begin -->` / `<!-- ff-effort:end -->` の**行全体の
#     完全一致**（行末 CR だけ落とす）。字下げ・行末空白つきのマーカーは集計器では
#     ブロック不在（noblock）扱いなので、この hook も止めない — 母集団の外に居る
#     Issue を止めても実績は永久に集計されず、停止に意味が無い
#   - ブロック不在 / 未閉鎖 / begin が 2 組 / end が begin より前 / キー重複は
#     集計器では noblock か malformed。どちらも素通しする
#   - `effort_human_planned` / `effort_ai_planned` / `effort_ai_actual` のいずれかが
#     `^[0-9]+(\.[0-9]+)?[dh]$` でない（0 以下も含む）値、または未知の `effort_unit` なら
#     集計器では malformed。単位が `effort_unit` の宣言と食い違う値（`effort_unit: h` なのに
#     `d` 付き・宣言が無いのに `h` 付き）なら unit_mismatch。どちらも兄弟キーでも素通しする
#     （書式不正・単位の食い違いは集計器が名指しする担当）
#   - 止めるのは `effort_ai_actual` がキー不在 / 空 / `(未記入)` のときだけ
# 本文が CRLF でも同じ判定になるよう、集計器と同じく行末の CR を落としてから見る
# （落とさないとマーカーが一致せず、集計器が `planned_only` として静かに落とす
# 本文こそガードが素通ししてしまう）。
#
# 停止は**抜け道付きの deny**（`permissionDecision: "deny"` の `permissionDecisionReason`）として
# 実装する。PreToolUse の `additionalContext` はエージェントへ届くが、Claude Code の CLI と
# Remote Control の画面にも表示される（2026-11-04 実測。Issue `#2614`）ので、止める判断の
# 代わりにはしない。
# 抜け道は deny の本文で必ず案内する（案内の無い deny は詰まりになる）:
#   - 対象コマンドの先頭に環境代入 `FF_EFFORT_ACTUAL_ACK=1` を付ける
#     （文字列としてコマンド中に現れるだけでは無効。コマンド位置の
#     `gh pr merge` の直前に置いた場合だけ素通しする）
#   - ガードごと止めるなら環境変数 `FF_DEV_TOOLKIT_SKIP=effort-actual`
#
# 判定の流れ:
#   1. heredoc 本文（`<<` / `<<-` のトークン以降、終端行まで）を走査対象から落とし、
#      シェル準拠の単一パーサ `parse_gh_pr_merge`（クォート状態・`\` 継続行・隣接引用連結・
#      `$'…'`・コメント・リダイレクト・前置代入・ラッパーを考慮）で、最初に実行される
#      コマンド位置の `gh pr merge` とその PR 指定・`--repo`・`FF_EFFORT_ACTUAL_ACK=1`・
#      `--subject` / `--body` / `--body-file`（`-t` / `-b` / `-F`）を抽出する
#      （`echo 'gh pr merge …'` や後続コマンドの引数では発火しない）。クォートや置換が
#      閉じていないときは解析を諦めて素通し（fail-open）する
#   2. PR 指定（番号 / URL / ブランチ。省略時は現在のブランチ）と `--repo` を拾い、
#      `gh pr view --json number,body,url,closingIssuesReferences` で PR を読む
#   3. 閉じる Issue の集合は GitHub が解決済みの `closingIssuesReferences` を正本に取る。
#      それが空のときだけ PR 本文を走査し、closing keyword と `Refs` を分けて集める。
#      実行する `gh pr merge` の `--subject` / `--body`（`-t` / `-b` と、`--flag=...` や
#      複数行文字列を含む）および読める通常ファイルの `--body-file`（`-F`、8 KiB 上限）、
#      ならびに GitHub MCP の `commit_title` / `commit_message` に closing keyword があれば、
#      その Issue は本文が `Refs` でも閉じる側に上げる
#   4. 各 Issue を `gh issue view --json body,state` で読む。CLOSED は対象外。
#      closing keyword（または closingIssuesReferences、またはマージメッセージ）
#      で拾った Issue は、未記入なら deny する。コメントの照会が失敗しても、本文と状態は
#      既に読めているので閉じる側の判定は素通しにしない。
#      `Refs` だけから拾った未記入 Issue だけコメントを別に読む。その PR 番号の完了報告
#      （コメント本文に `close-issue-report:PR-` とその PR 番号が完全一致する印）が
#      あれば通す。印が無ければ deny し、Issue は閉じない前提で `/close-issue` を案内する
#
# `Refs` だけの PR はこのマージでは Issue を閉じない。未記入を理由に止める代わりに、
# `/close-issue` の報告印があるかで判定する（報告があれば、継続中として実績を空のまま
# 残す判断が済んでいる）。印が無いときは止め、`/close-issue` を案内する。
# closing keyword で閉じる Issue は従来どおり実績の記入を求める。報告印があっても
# 未記入なら止める（印は `Refs` だけの免除であり、閉じる Issue の記入を代替しない）。
# 閉じる集合が取れたときは本文を走査しない。走査すると長命の tracking / Epic Issue
# への `Refs` まで停止対象に入り、その配下の sub-PR が恒常的に止まる。
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
#   - `--subject` / `--body` を付けないマージで、GitHub が既定の squash メッセージ
#     （コミット件名だけに参照がある形を含む）から閉じる場合。この hook からは見えない
#   - `gh` の認証切れ・オフライン・PR 指定を解決できない形（fail-open）
#   - `closingIssuesReferences` を返さない古い `gh`（PR 取得ごと失敗して素通しする）。
#     本文走査だけへ落とすフォールバックは置かない — 閉じる集合が取れない状態で `Refs` を
#     走査すると、上に書いた tracking Issue の恒常停止がそのまま戻るため
#   - heredoc 本文に書かれた `gh pr merge`（データであって実行されるコマンドではない）
#   - クォート・`$()`・`` `...` `` が閉じていない呼び出し（解析不能として fail-open へ倒す）
#   - `--body-file -`（stdin）・読めない / 8 KiB 超 / 通常ファイル以外の `--body-file`、
#     および同一コマンド内の先行 `cd` に依存する相対パスの `--body-file`
#   - 変数展開・コマンド置換の中で組み立てられる `gh pr merge` や、マージメッセージ引数中の
#     未展開のパラメータ展開（`${var:-…}`）・`$'…'` の 16 進 / 8 進 / Unicode エスケープ（`\xHH` 等）
#     はシェル展開を評価しないため実値とずれうる（fail-open / 字面どおりの走査）
#   - 上限（`FF_EFFORT_ACTUAL_GUARD_MAX_ISSUES`）を超えた分の Issue は照会しない。
#     打ち切りは fail-open（照会しなかった Issue は無かったものとして扱う）で、
#     上限に達したこと自体は deny の理由にしない
#   - `Refs` だけの未記入 Issue のコメントは `gh issue view --json comments` の 1 応答で
#     読む（ページ送りはしない。閉じる Issue にはコメントを要求しない）。
#     `comments` が無い、配列でない、要素の本文が文字列でない、照会そのものが
#     失敗したときは、完了報告を読めなかったものとして止めない（fail-open）。
#     空の配列は「報告が無い」と読み、`Refs` だけの未記入は止める。応答に入り切らなかった
#     印は「無い」と読む（その形だけ fail-closed）
#   （なお、ベースブランチが既定ブランチかどうかの比較は行わず、closing keyword が閉じる側に
#     入ればマージ先を問わず実績の記入を求める）
#
# GitHub MCP 経路（PreToolUse / `merge_pull_request`）:
#   hooks.json は MCP のツール名を matcher に持つエントリからも本ガードを起動する。tool_input の
#   owner / repo / pullNumber を `gh pr merge <番号> --repo <owner>/<repo>` へ写し、
#   `commit_title` / `commit_message` はマージメッセージとして引き継いで上の判定へ流すので、
#   閉じる Issue の解決・未記入の定義・deny 文は Bash 経路と同じ（違うのは抜け道の案内 1 行だけ。
#   `Refs` だけの拒否文も同じで、経路差はその 1 行に限る）。
#   PR / Issue の本文を読むのは gh のままなので、gh が無い・照会に失敗した・照会上限を超えた・
#   tool_input を読めない・判定表にないツール名・jq 不在のときは止めずに通し、省略した理由を
#   systemMessage（利用者）と additionalContext（エージェントの文脈）に出す（黙って通さない）。
#   振り分けは共有ヘルパ tests/lib/github-mcp-route.sh の ff_github_mcp_route_input。
#   抜け道は hook の環境変数 `FF_EFFORT_ACTUAL_ACK=1`（MCP の呼び出しにはコマンド先頭の環境代入を
#   付けられないため）。hook の環境は Claude Code の起動時に決まるので、その 1 回ではなくセッション
#   全体の GitHub MCP 呼び出しに効く。通したときも毎回知らせる。
#
# 設計原則:
#   - fail-open: 全 Bash 呼び出しに割り込むため、自身の不具合や解析不能な形、
#     `gh` / `jq` 不在では黙って許可（exit 0・無出力）に倒す。検査不能を
#     「違反」と読み替えない。GitHub MCP 経路だけは、判定を省略した理由を出して通す
#     （無出力にしない）。
#   - 互換性: bash 3.2（stock macOS）互換。連想配列・readarray を使わない。
#     大文字小文字の吸収と本文の走査は `LC_ALL=C awk` で行う（grep は不一致と
#     エラーの区別が実装依存で、fail-open が fail-closed へ反転しうる）。
#
# 環境変数:
#   FF_DEV_TOOLKIT_SKIP=effort-actual  このガードを無効化する（鍵の名簿は scripts/lib/l4-declarations.tsv）
#   FF_EFFORT_ACTUAL_ACK=1  Bash 経路ではコマンド先頭の環境代入（その 1 回だけ）、GitHub MCP 経路では
#                           hook の環境変数（セッション全体）として読む抜け道。hook の環境の値は
#                           MCP 経路だけが読み、Bash 経路は通さない
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

# L4 宣言（ADR-087）。lib を読めない配置では止めない側（ガードは効いたまま）に倒し、stderr も汚さない
{ [ -r "${BASH_SOURCE[0]%/*}/../scripts/lib/l4-declarations.sh" ] && . "${BASH_SOURCE[0]%/*}/../scripts/lib/l4-declarations.sh"; } 2>/dev/null || ff_l4_skipped() { return 1; }
if ff_l4_skipped 'effort-actual'; then exit 0; fi

# ---- GitHub MCP 経路（merge_pull_request）------------------------------------
# MCP の呼び出しにはコマンド文字列が無い。tool_input の owner / repo / pullNumber を同じ意味の
# `gh pr merge <番号> --repo <owner>/<repo>` へ写し、下の Bash 経路の判定へそのまま流す
# （閉じる Issue の解決・未記入の定義を 2 系統へ複製しない）。写すのは数字と英数記号だけに
# 限った値なので、組み立てた文字列の解釈が入力でずれることはない（実行もしない）。
# Bash 経路と違うのは、判定を省略した理由を systemMessage で必ず出すこと（gh 不在・gh の照会
# 失敗・tool_input を読めない）。Bash 経路では gh を叩くのは利用者のコマンド自身なので失敗が
# 目に見えるが、MCP 経路では gh を使えなくてもマージが通るため、黙って通すとガードが効いて
# いないことに誰も気づけない。
GUARD_ROUTE=bash
MCP_MERGE_TEXT=""
mcp_skip() { # <理由>  MCP 経路では省略した理由を出して通す。Bash 経路は従来どおり無音で通す
  [ "$GUARD_ROUTE" = "mcp" ] && ff_github_mcp_note "工数実績" "$1"
  exit 0
}
# MCP の入力は `gh` を含まないので、下の前置フィルタより前で振り分ける（後ろに置くと MCP の
# 入力が jq を起動する前に素通しで落ちる）。振り分け（tool_name の読み取り・判定表の照合）は
# 共有ヘルパの ff_github_mcp_route_input。
case "$input" in
  *mcp__*)
    # shellcheck source=../tests/lib/github-mcp-route.sh
    if . "${BASH_SOURCE[0]%/*}/../tests/lib/github-mcp-route.sh" 2>/dev/null; then
      ff_github_mcp_route_input "工数実績" merge_pull_request
    else
      case "$input" in
        *'"tool_name":"mcp__'* | *'"tool_name": "mcp__'*)
          printf '%s\n' '{"systemMessage":"ℹ️ ff-dev-toolkit guard（工数実績・GitHub MCP）: 判定ヘルパ tests/lib/github-mcp-route.sh を読めないため、GitHub MCP の呼び出しを検査せずに通しました。"}'
          exit 0
          ;;
      esac
    fi
    ;;
esac
if [ "$GUARD_ROUTE" = "mcp" ]; then
  # 抜け道: MCP の呼び出しにはコマンド先頭の環境代入を付けられないので、hook の環境変数で受ける。
  # セッション全体に効くので、通したことは毎回知らせる。
  if [ "${FF_EFFORT_ACTUAL_ACK:-0}" = "1" ]; then
    mcp_skip "hook の環境変数 FF_EFFORT_ACTUAL_ACK=1 により、${MCP_TOOL_NAME} が閉じる Issue の工数実績を確認せずに通しました。この設定は Claude Code のセッション全体（GitHub MCP の呼び出しすべて）に効くので、済んだら外して再起動してください。"
  fi
  mcp_target="$(printf '%s' "$input" | jq -r '
    .tool_input | select(type == "object")
    | [(.owner | strings), (.repo | strings), (.pullNumber | if type == "number" then tostring else strings end)]
    | select(length == 3) | join(" ")' 2>/dev/null)" || mcp_target=""
  mcp_target="${mcp_target//$'\r'/}"
  mcp_owner="${mcp_target%% *}"
  mcp_rest="${mcp_target#* }"
  mcp_repo="${mcp_rest%% *}"
  mcp_pr="${mcp_rest#* }"
  case "$mcp_owner:$mcp_repo:$mcp_pr" in
    *[!A-Za-z0-9._:-]* | :* | *::* | *: | *:*:*:*) mcp_pr="" ;;
  esac
  case "$mcp_pr" in
    '' | *[!0-9]*)
      mcp_skip "${MCP_TOOL_NAME} の tool_input から owner / repo / pullNumber を読めないため、閉じる Issue の工数実績を検査せずに通しました。"
      ;;
  esac
  command -v gh >/dev/null 2>&1 \
    || mcp_skip "gh が PATH に無いため、${mcp_owner}/${mcp_repo} の PR ${mcp_pr} が閉じる Issue の工数実績（ff-effort ブロックの effort_ai_actual）を確認せずに通しました。PR と Issue の本文は gh でしか読めません。"
  command -v awk >/dev/null 2>&1 \
    || mcp_skip "awk が PATH に無いため、${mcp_owner}/${mcp_repo} の PR ${mcp_pr} が閉じる Issue の工数実績を確認せずに通しました。"
  MCP_MERGE_TEXT="$(printf '%s' "$input" | jq -r '
    .tool_input | select(type == "object")
    | [(.commit_title | strings), (.commit_message | strings)]
    | join("\n")' 2>/dev/null)" || MCP_MERGE_TEXT=""
  MCP_MERGE_TEXT="${MCP_MERGE_TEXT//$'\r'/}"
  input="$(printf '%s' "$input" | jq -c --arg c "gh pr merge ${mcp_pr} --repo ${mcp_owner}/${mcp_repo}" \
    '{tool_name: "Bash", tool_input: {command: $c}, cwd: (.cwd // "")}' 2>/dev/null)" \
    || mcp_skip "${MCP_TOOL_NAME} の入力を判定用に組み立てられないため、閉じる Issue の工数実績を検査せずに通しました。"
fi

# 安価な前置フィルタ（jq / gh / awk を 1 度も起動せずに非該当を落とす。例外は `mcp__` を含む入力で、
# 上の振り分けが tool_name を読むために jq を 1 回起動する）。
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
cmd="${cmd//$'\r'/}"  # Windows の jq.exe は改行を \r\n で出す（Issue `#2017`）
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
# 引っかかる。走査は共有ヘルパ `tests/lib/heredoc-strip.sh`（`<<` / `<<-` の直後の
# 区切り語を積み、終端行まで読み飛ばす。`<<<` の here-string は heredoc ではない。
# 終端行の**直後**に続く実コマンドは落とさない。判定規則の正本はヘルパのヘッダ）。
# ヘルパが読めない・awk が失敗したら素通しへ倒す（本 hook は検査不能を「違反」と
# 読み替えない fail-open 側）。未終端（rc 3）はヘルパが生コマンドを返すので、行を
# 捨てずにそのまま走査する。
HEREDOC_HELPER="${BASH_SOURCE[0]%/*}/../tests/lib/heredoc-strip.sh"
# shellcheck source=../tests/lib/heredoc-strip.sh
. "$HEREDOC_HELPER" 2>/dev/null || mcp_skip "判定ヘルパ tests/lib/heredoc-strip.sh を読めないため、閉じる Issue の工数実績を検査せずに通しました。"
code_only="$(ff_heredoc_strip "$cmd")"
case $? in
  0 | 3) : ;;
  *) mcp_skip "判定ヘルパ tests/lib/heredoc-strip.sh の走査が失敗したため、閉じる Issue の工数実績を検査せずに通しました。" ;;
esac
[ -n "$code_only" ] || exit 0
case "$code_only" in
  *merge*) : ;;
  *) exit 0 ;;
esac

# ---- コマンド位置の `gh pr merge` とオプション・メッセージを解析する ---------------
# heredoc 除去済みコマンド列を受け取り、最初に実行される `gh pr merge` について
# FOUND / BYPASS / SEL / REPO / MSG / FILE 行を返す。未閉鎖のクォート・置換等は rc 2。
parse_gh_pr_merge() {
  LC_ALL=C awk '
    BEGIN {
      sq = sprintf("%c", 39)
      bt = sprintf("%c", 96)
    }
    function is_sep_ch(c) {
      return (c == " " || c == "\t" || c == "\n" || c == ";" || c == "|" || c == "&" || c == "(" || c == ")" || c == "<" || c == ">")
    }
    function add_msg(val,   nparts, parts, k) {
      gsub(/\r/, "", val)
      if (val == "") return
      nparts = split(val, parts, "\n")
      for (k = 1; k <= nparts; k++) {
        nmsg++
        msg_lines[nmsg] = parts[k]
      }
    }
    function add_file(p) {
      gsub(/\r/, "", p)
      if (p != "" && index(p, "\n") == 0) {
        nfiles++
        files[nfiles] = p
      }
    }
    function read_word(   val, c, ch, nx, esc, depth, closed) {
      TOK_ASSIGN = match(substr(s, pos), /^[A-Za-z_][A-Za-z0-9_]*=/) ? 1 : 0
      val = ""
      while (pos <= slen) {
        c = substr(s, pos, 1)
        if (is_sep_ch(c)) break
        if (c == "$" && substr(s, pos + 1, 1) == sq) {
          pos += 2
          closed = 0
          while (pos <= slen) {
            ch = substr(s, pos, 1)
            if (ch == sq) { closed = 1; pos++; break }
            if (ch == "\\") {
              pos++
              if (pos > slen) return -1
              esc = substr(s, pos, 1)
              pos++
              if (esc == "n") val = val "\n"
              else if (esc == "r") val = val "\r"
              else if (esc == "t") val = val "\t"
              else if (esc == sq || esc == "\"" || esc == "\\") val = val esc
              else val = val "\\" esc
            } else {
              val = val ch
              pos++
            }
          }
          if (!closed) return -1
          continue
        }
        if (c == "$" && substr(s, pos + 1, 1) == "(") {
          val = val "$("
          pos += 2
          depth = 1
          while (pos <= slen && depth > 0) {
            ch = substr(s, pos, 1)
            if (ch == "\\") {
              if (pos + 1 > slen) return -1
              val = val substr(s, pos, 2)
              pos += 2
            } else if (ch == sq) {
              val = val sq
              pos++
              closed = 0
              while (pos <= slen) {
                nx = substr(s, pos, 1)
                if (nx == sq) { closed = 1; val = val sq; pos++; break }
                val = val nx
                pos++
              }
              if (!closed) return -1
            } else if (ch == "\"") {
              val = val "\""
              pos++
              closed = 0
              while (pos <= slen) {
                nx = substr(s, pos, 1)
                if (nx == "\"") { closed = 1; val = val "\""; pos++; break }
                if (nx == "\\") {
                  if (pos + 1 > slen) return -1
                  val = val substr(s, pos, 2)
                  pos += 2
                } else {
                  val = val nx
                  pos++
                }
              }
              if (!closed) return -1
            } else if (ch == "(") {
              depth++; val = val ch; pos++
            } else if (ch == ")") {
              depth--; val = val ch; pos++
            } else {
              val = val ch; pos++
            }
          }
          if (depth != 0) return -1
          continue
        }
        if (c == bt) {
          val = val bt
          pos++
          closed = 0
          while (pos <= slen) {
            ch = substr(s, pos, 1)
            if (ch == bt) { closed = 1; val = val bt; pos++; break }
            if (ch == "\\") {
              if (pos + 1 > slen) return -1
              val = val substr(s, pos, 2)
              pos += 2
            } else {
              val = val ch
              pos++
            }
          }
          if (!closed) return -1
          continue
        }
        if (c == sq) {
          pos++
          closed = 0
          while (pos <= slen) {
            ch = substr(s, pos, 1)
            if (ch == sq) { closed = 1; pos++; break }
            val = val ch
            pos++
          }
          if (!closed) return -1
          continue
        }
        if (c == "\"") {
          pos++
          closed = 0
          while (pos <= slen) {
            ch = substr(s, pos, 1)
            if (ch == "\"") { closed = 1; pos++; break }
            if (ch == "\\") {
              pos++
              if (pos > slen) return -1
              esc = substr(s, pos, 1)
              pos++
              if (esc == "\n") {
              } else if (esc == "\"" || esc == "\\" || esc == "$" || esc == bt) {
                val = val esc
              } else {
                val = val "\\" esc
              }
            } else {
              val = val ch
              pos++
            }
          }
          if (!closed) return -1
          continue
        }
        if (c == "\\") {
          pos++
          if (pos > slen) return -1
          esc = substr(s, pos, 1)
          pos++
          if (esc != "\n") val = val esc
          continue
        }
        val = val c
        pos++
      }
      TOK_VAL = val
      return 0
    }
    function next_tok(   c, c2, p2, r1, r2, r3) {
      TOK_VAL = ""
      TOK_ASSIGN = 0
      while (pos <= slen) {
        c = substr(s, pos, 1)
        if (c == " " || c == "\t") { pos++; continue }
        if (c == "\\" && substr(s, pos + 1, 1) == "\n") { pos += 2; continue }
        if (c == "#") {
          while (pos <= slen && substr(s, pos, 1) != "\n") pos++
          continue
        }
        c2 = substr(s, pos, 2)
        if (c2 == "&&" || c2 == "||" || c2 == "|&") { pos += 2; TOK_KIND = "SEP"; return }
        if (substr(s, pos, 3) == "&>>") { pos += 3; TOK_KIND = "REDIR"; return }
        if (c2 == "&>") {
          if (substr(s, pos + 2, 1) == "-") { pos += 3; TOK_KIND = "REDIR_DONE"; return }
          pos += 2; TOK_KIND = "REDIR"; return
        }
        if (c == "\n" || c == ";" || c == "|" || c == "&" || c == "(" || c == ")") {
          pos++; TOK_KIND = "SEP"; return
        }
        if (match(substr(s, pos), /^[0-9]*[<>]/)) {
          p2 = pos + RLENGTH - 1
          r1 = substr(s, p2, 1)
          r2 = substr(s, p2 + 1, 1)
          r3 = substr(s, p2 + 2, 1)
          if (r1 == "<" && r2 == "<" && (r3 == "-" || r3 == "<")) {
            pos = p2 + 3; TOK_KIND = "REDIR"; return
          }
          if ((r1 == "<" && (r2 == "<" || r2 == ">")) || (r1 == ">" && (r2 == ">" || r2 == "|"))) {
            pos = p2 + 2; TOK_KIND = "REDIR"; return
          }
          if ((r1 == "<" || r1 == ">") && r2 == "&") {
            pos = p2 + 2
            if (match(substr(s, pos), /^([0-9]+|-)([ \t\n;|&()<>#]|$)/)) {
              match(substr(s, pos), /^([0-9]+|-)/)
              pos += RLENGTH
              TOK_KIND = "REDIR_DONE"
              return
            }
            TOK_KIND = "REDIR"
            return
          }
          pos = p2 + 1
          TOK_KIND = "REDIR"
          return
        }
        if (read_word() != 0) { TOK_KIND = "ERR"; return }
        TOK_KIND = "WORD"
        return
      }
      TOK_KIND = "EOF"
    }
    { s = s (NR > 1 ? "\n" : "") $0 }
    END {
      slen = length(s)
      pos = 1
      st = "PREFIX"
      bypass = 0
      wrap = ""
      wrap_arg = 0
      redir_skip = 0
      gh_opt = ""
      opt_need = ""
      end_opts = 0
      found = 0
      selector = ""
      repo = ""
      nmsg = 0
      nfiles = 0
      err = 0
      while (1) {
        next_tok()
        if (TOK_KIND == "EOF") break
        if (TOK_KIND == "ERR") { err = 1; break }
        if (TOK_KIND == "REDIR_DONE") continue
        if (TOK_KIND == "REDIR") { redir_skip = 1; continue }
        if (TOK_KIND == "SEP") {
          redir_skip = 0
          if (st == "MERGE") break
          st = "PREFIX"
          bypass = 0
          wrap = ""
          wrap_arg = 0
          gh_opt = ""
          continue
        }
        if (redir_skip) { redir_skip = 0; continue }
        if (st == "SKIP_CMD") continue
        if (st == "PREFIX") {
          if (wrap_arg) { wrap_arg = 0; continue }
          if (wrap != "") {
            if (wrap == "timeout_dur") { wrap = ""; continue }
            if (wrap == "timeout") {
              if (TOK_VAL == "--") { wrap = "timeout_dur"; continue }
              if (TOK_VAL == "-k" || TOK_VAL == "-s" || TOK_VAL == "--kill-after" || TOK_VAL == "--signal") { wrap_arg = 1; continue }
              if (TOK_VAL ~ /^-/) continue
              wrap = ""; continue
            }
            if (wrap == "command") {
              if (TOK_VAL == "--") { wrap = ""; continue }
              if (TOK_VAL ~ /^-[pP]+$/) continue
              if (TOK_VAL ~ /^-/) { st = "SKIP_CMD"; wrap = ""; continue }
              wrap = ""
            } else if (wrap == "env") {
              if (TOK_VAL == "--") { wrap = ""; continue }
              if (TOK_VAL == "-u" || TOK_VAL == "--unset" || TOK_VAL == "-C" || TOK_VAL == "--chdir" || TOK_VAL == "-S" || TOK_VAL == "--split-string") { wrap_arg = 1; continue }
              if (TOK_ASSIGN || TOK_VAL ~ /^[A-Za-z_][A-Za-z0-9_]*=/) {
                if (index(TOK_VAL, "FF_EFFORT_ACTUAL_ACK=") == 1) bypass = (TOK_VAL == "FF_EFFORT_ACTUAL_ACK=1" ? 1 : 0)
                continue
              }
              if (TOK_VAL ~ /^-/) continue
              wrap = ""
            } else if (wrap == "sudo") {
              if (TOK_VAL == "--") { wrap = ""; continue }
              if (TOK_VAL == "-u" || TOK_VAL == "-g" || TOK_VAL == "-p" || TOK_VAL == "-C" || TOK_VAL == "-D" || TOK_VAL == "-R" || TOK_VAL == "-T" || TOK_VAL == "-h" ||
                  TOK_VAL == "--user" || TOK_VAL == "--group" || TOK_VAL == "--prompt" || TOK_VAL == "--close-from" || TOK_VAL == "--chdir" || TOK_VAL == "--role" ||
                  TOK_VAL == "--other-user" || TOK_VAL == "--command-timeout" || TOK_VAL == "--chroot" || TOK_VAL == "--host") { wrap_arg = 1; continue }
              if (TOK_VAL ~ /^-/) continue
              wrap = ""
            } else if (wrap == "nice") {
              if (TOK_VAL == "--") { wrap = ""; continue }
              if (TOK_VAL == "-n" || TOK_VAL == "--adjustment") { wrap_arg = 1; continue }
              if (TOK_VAL ~ /^-/) continue
              wrap = ""
            } else if (wrap == "exec") {
              if (TOK_VAL == "--") { wrap = ""; continue }
              if (TOK_VAL == "-a") { wrap_arg = 1; continue }
              if (TOK_VAL ~ /^-/) continue
              wrap = ""
            } else {
              if (TOK_VAL == "--") { wrap = ""; continue }
              if (TOK_VAL ~ /^-/) continue
              wrap = ""
            }
          }
          if (TOK_VAL == "!" || TOK_VAL == "{" || TOK_VAL == "}" || TOK_VAL == "if" || TOK_VAL == "then" || TOK_VAL == "elif" || TOK_VAL == "else" || TOK_VAL == "while" || TOK_VAL == "until" || TOK_VAL == "do") continue
          if (TOK_ASSIGN) {
            if (index(TOK_VAL, "FF_EFFORT_ACTUAL_ACK=") == 1) bypass = (TOK_VAL == "FF_EFFORT_ACTUAL_ACK=1" ? 1 : 0)
            continue
          }
          if (TOK_VAL == "env" || TOK_VAL == "command" || TOK_VAL == "sudo" || TOK_VAL == "nohup" || TOK_VAL == "exec" || TOK_VAL == "time" || TOK_VAL == "nice" || TOK_VAL == "timeout" || TOK_VAL == "builtin" || TOK_VAL == "noglob") {
            wrap = TOK_VAL; continue
          }
          if (TOK_VAL == "gh" || TOK_VAL == "gh.exe" || TOK_VAL ~ /\/gh(\.exe)?$/) {
            st = "GH"; repo = ""; gh_opt = ""; continue
          }
          st = "SKIP_CMD"; continue
        }
        if (st == "GH") {
          if (gh_opt != "") {
            if (gh_opt == "repo") repo = TOK_VAL
            gh_opt = ""
            continue
          }
          if (TOK_VAL == "pr") { st = "GH_PR"; continue }
          if (TOK_VAL == "--repo" || TOK_VAL == "-R") { gh_opt = "repo"; continue }
          if (index(TOK_VAL, "--repo=") == 1) { repo = substr(TOK_VAL, 8); continue }
          if (TOK_VAL ~ /^-R./) { repo = substr(TOK_VAL, 3); continue }
          if (TOK_VAL == "--hostname") { gh_opt = "skip"; continue }
          if (index(TOK_VAL, "--hostname=") == 1) continue
          st = "SKIP_CMD"; continue
        }
        if (st == "GH_PR") {
          if (TOK_VAL == "merge") {
            st = "MERGE"; found = 1; opt_need = ""; end_opts = 0; continue
          }
          st = "SKIP_CMD"; continue
        }
        if (st == "MERGE") {
          if (opt_need != "") {
            if (opt_need == "msg") add_msg(TOK_VAL)
            else if (opt_need == "file") add_file(TOK_VAL)
            else if (opt_need == "repo") repo = TOK_VAL
            opt_need = ""
            continue
          }
          if (!end_opts) {
            if (TOK_VAL == "--") { end_opts = 1; continue }
            if (TOK_VAL == "--body" || TOK_VAL == "--subject") { opt_need = "msg"; continue }
            if (index(TOK_VAL, "--body=") == 1) { add_msg(substr(TOK_VAL, 8)); continue }
            if (index(TOK_VAL, "--subject=") == 1) { add_msg(substr(TOK_VAL, 11)); continue }
            if (TOK_VAL == "--body-file") { opt_need = "file"; continue }
            if (index(TOK_VAL, "--body-file=") == 1) { add_file(substr(TOK_VAL, 13)); continue }
            if (TOK_VAL == "--repo") { opt_need = "repo"; continue }
            if (index(TOK_VAL, "--repo=") == 1) { repo = substr(TOK_VAL, 8); continue }
            if (TOK_VAL == "--match-head-commit" || TOK_VAL == "--author-email") { opt_need = "skip"; continue }
            if (TOK_VAL ~ /^--/) continue
            if (TOK_VAL ~ /^-[^-]/) {
              for (k = 2; k <= length(TOK_VAL); k++) {
                fch = substr(TOK_VAL, k, 1)
                frest = substr(TOK_VAL, k + 1)
                if (fch == "b" || fch == "t") {
                  if (frest != "") add_msg(frest)
                  else opt_need = "msg"
                  break
                } else if (fch == "F") {
                  if (frest != "") add_file(frest)
                  else opt_need = "file"
                  break
                } else if (fch == "R") {
                  if (frest != "") repo = frest
                  else opt_need = "repo"
                  break
                } else if (fch == "A") {
                  if (frest == "") opt_need = "skip"
                  break
                }
              }
              continue
            }
          }
          if (selector == "") selector = TOK_VAL
        }
      }
      if (err) exit 2
      if (!found) exit 0
      gsub(/\r/, "", selector); gsub(/\n/, " ", selector)
      gsub(/\r/, "", repo); gsub(/\n/, " ", repo)
      print "FOUND 1"
      print "BYPASS " bypass
      print "SEL " selector
      print "REPO " repo
      for (j = 1; j <= nmsg; j++) print "MSG " msg_lines[j]
      for (j = 1; j <= nfiles; j++) print "FILE " files[j]
    }
  '
}

GH_FOUND=0
GH_BYPASS=0
SELECTOR=""
REPO=""
merge_text=""
BODY_FILES=()
parsed_merge="$(printf '%s\n' "$code_only" | parse_gh_pr_merge 2>/dev/null)" || parsed_merge=""
if [ -n "$parsed_merge" ]; then
  pm_rest="${parsed_merge}"$'\n'
  while [ -n "$pm_rest" ]; do
    pm_line="${pm_rest%%$'\n'*}"
    pm_rest="${pm_rest#*$'\n'}"
    pm_line="${pm_line//$'\r'/}"
    case "$pm_line" in
      FOUND\ 1) GH_FOUND=1 ;;
      BYPASS\ 1) GH_BYPASS=1 ;;
      BYPASS\ 0) GH_BYPASS=0 ;;
      SEL\ *) SELECTOR="${pm_line#SEL }" ;;
      REPO\ *) REPO="${pm_line#REPO }" ;;
      MSG\ *)
        pm_msg="${pm_line#MSG }"
        if [ -n "$merge_text" ]; then
          merge_text="${merge_text}"$'\n'"${pm_msg}"
        else
          merge_text="$pm_msg"
        fi
        ;;
      FILE\ *)
        pm_file="${pm_line#FILE }"
        [ -n "$pm_file" ] && BODY_FILES[${#BODY_FILES[@]}]="$pm_file"
        ;;
    esac
  done
fi

[ "$GH_FOUND" -eq 1 ] || exit 0
# 抜け道: 対象コマンドの先頭に置かれた環境代入だけを認める
[ "$GH_BYPASS" -eq 1 ] && exit 0

GH_ARGS=()
if [ -n "$REPO" ]; then
  GH_ARGS[0]="--repo"
  GH_ARGS[1]="$REPO"
fi

if [ -n "$SELECTOR" ]; then
  pr_json="$(cd "$CWD" 2>/dev/null && gh pr view "$SELECTOR" ${GH_ARGS[0]:+"${GH_ARGS[@]}"} --json number,body,url,closingIssuesReferences 2>/dev/null)" \
    || mcp_skip "${REPO} の PR ${SELECTOR} を gh で読めない（認証切れ・オフライン・PR が見つからない）ため、閉じる Issue の工数実績を確認せずに通しました。"
else
  pr_json="$(cd "$CWD" 2>/dev/null && gh pr view ${GH_ARGS[0]:+"${GH_ARGS[@]}"} --json number,body,url,closingIssuesReferences 2>/dev/null)" \
    || mcp_skip "${REPO} の PR ${SELECTOR} を gh で読めない（認証切れ・オフライン・PR が見つからない）ため、閉じる Issue の工数実績を確認せずに通しました。"
fi
[ -n "$pr_json" ] || mcp_skip "${REPO} の PR ${SELECTOR} を gh で読めない（認証切れ・オフライン・PR が見つからない）ため、閉じる Issue の工数実績を確認せずに通しました。"

pr_unparsed="${REPO} の PR ${SELECTOR} を gh で読めたが内容を解釈できないため、閉じる Issue の工数実績を確認せずに通しました。"
pr_number="$(printf '%s' "$pr_json" | jq -r '.number // empty' 2>/dev/null)" || mcp_skip "$pr_unparsed"
pr_number="${pr_number//$'\r'/}"  # Windows の jq.exe は改行を \r\n で出す（Issue `#2017`）
pr_body="$(printf '%s' "$pr_json" | jq -r '.body // ""' 2>/dev/null)" || mcp_skip "$pr_unparsed"
pr_body="${pr_body//$'\r'/}"  # Windows の jq.exe は改行を \r\n で出す（Issue `#2017`）
[ -n "$pr_number" ] || mcp_skip "$pr_unparsed"

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
closing_numbers="${closing_numbers//$'\r'/}"  # Windows の jq.exe は改行を \r\n で出す（Issue `#2017`）

# ---- PR 本文から Issue 参照を集める（closing keyword を書かない `Refs` 運用の PR）--
# 閉じる集合が取れたときは本文を走査しない。走査すると長命の tracking / Epic Issue への
# `Refs` まで停止対象に入り、その配下の sub-PR が恒常的に止まる。
# キューの 1 行は `C <番号>`（閉じる）か `R <番号>`（Refs だけ）。同じ番号が両方に
# 出たときは閉じる側（C）に倒す。出現順は本文の左から。番号の正規表現は字句を
# 連結して書く（公開同期の追加行検査が、ハッシュの直後の数字を参照として拾うため）。
# 本文の 1 行を `C <番号>` / `R <番号>` に分ける。同じ番号が両方なら C。
classify_issue_refs() {
  LC_ALL=C awk '
  {
    line = " " tolower($0)
    refpat = "[#]" "[0-9]+"
    while (match(line, "[^a-z0-9_](close[sd]?|fix(es|ed)?|resolve[sd]?|refs?)[ \t]*:?[ \t]*" refpat)) {
      raw = substr(line, RSTART, RLENGTH)
      kw = raw
      sub(/[ \t]*:?[ \t]*#.*/, "", kw)
      sub(/^[^a-z]+/, "", kw)
      num = raw
      sub(/^[^#]*#/, "", num)
      if (!(num in seen_at)) {
        n = n + 1
        seen_at[num] = n
        seq[n] = num
        tag[num] = "R"
        if (kw !~ /^refs?$/) tag[num] = "C"
      } else if (kw !~ /^refs?$/) {
        tag[num] = "C"
      }
      line = substr(line, RSTART + RLENGTH)
    }
  }
  END {
    for (i = 1; i <= n; i++) print tag[seq[i]] " " seq[i]
  }
  '
}

if [ -n "$closing_numbers" ]; then
  queue="$(printf '%s\n' "$closing_numbers" | LC_ALL=C awk 'NF { print "C " $0 }' 2>/dev/null)" || queue=""
else
  queue="$(printf '%s\n' "$pr_body" | classify_issue_refs 2>/dev/null)" || queue=""
fi

# マージコマンド（--subject / --body / --body-file）および GitHub MCP（commit_title /
# commit_message）が閉じる Issue は、本文の Refs と報告印より閉じる側を優先する。
if [ "$GUARD_ROUTE" = "mcp" ] && [ -n "$MCP_MERGE_TEXT" ]; then
  merge_text="$MCP_MERGE_TEXT"
elif [ "${#BODY_FILES[@]}" -gt 0 ]; then
  ABS_PATH_HELPER="${BASH_SOURCE[0]%/*}/../scripts/lib/abs-path.sh"
  # shellcheck source=../scripts/lib/abs-path.sh
  if [ -r "$ABS_PATH_HELPER" ] && . "$ABS_PATH_HELPER" 2>/dev/null && [ "$(type -t ff_path_is_absolute)" = "function" ]; then
    for bf in "${BODY_FILES[@]}"; do
      [ -n "$bf" ] || continue
      [ "$bf" != "-" ] || continue
      ff_path_is_absolute "$bf" || bf="${CWD}/${bf}"
      if [ -f "$bf" ] && [ -r "$bf" ]; then
        bf_size="$(LC_ALL=C wc -c < "$bf" 2>/dev/null)" || bf_size=""
        bf_size="${bf_size// /}"
        bf_size="${bf_size//$'\t'/}"
        bf_size="${bf_size//$'\n'/}"
        bf_size="${bf_size//$'\r'/}"
        case "$bf_size" in
          '' | *[!0-9]*) continue ;;
        esac
        if [ "$bf_size" -le 8192 ] 2>/dev/null; then
          bf_content="$(cat "$bf" 2>/dev/null; printf X)" || bf_content=""
          bf_content="${bf_content%X}"
          bf_content="${bf_content//$'\r'/}"
          if [ -n "$bf_content" ]; then
            if [ -n "$merge_text" ]; then
              merge_text="${merge_text}"$'\n'"${bf_content}"
            else
              merge_text="$bf_content"
            fi
          fi
        fi
      fi
    done
  fi
fi
if [ -n "$merge_text" ]; then
  merge_c="$(printf '%s\n' "$merge_text" | classify_issue_refs 2>/dev/null | LC_ALL=C awk '$1 == "C" { print $2 }')" || merge_c=""
  if [ -n "$merge_c" ]; then
    queue="$(
      {
        printf '%s\n' "$queue"
        printf '%s\n' "$merge_c" | LC_ALL=C awk 'NF { print "M " $0 }'
      } | LC_ALL=C awk '
        $1 == "M" {
          if (!($2 in kind)) { n++; order[n] = $2 }
          kind[$2] = "C"
          next
        }
        $1 == "C" || $1 == "R" {
          if (!($2 in kind)) { n++; order[n] = $2; kind[$2] = $1 }
          next
        }
        END {
          for (i = 1; i <= n; i++) if (kind[order[i]] == "C") print "C " order[i]
          for (i = 1; i <= n; i++) if (kind[order[i]] == "R") print "R " order[i]
        }
      '
    )" || queue=""
  fi
fi
[ -n "$queue" ] || exit 0

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
# scripts/lib/finish-precheck.sh の ff_precheck_effort_actual_missing と同じ判定（変えるときは両方同時に直す）。
# 終了コード 0 = 未記入（= 集計器の planned_only）/ 1 = それ以外（ブロック不在・
# 記入済み・書式不正）。
is_effort_unfilled() {
  printf '%s\n' "$1" | LC_ALL=C awk '
    function trim(s) { sub(/^[ \t]+/, "", s); sub(/[ \t]+$/, "", s); return s }
    # 集計器 as_hours(): 未記入は -1、数値でない値・0 以下は -2（書式不正）、
    # `effort_unit` の宣言と値の単位の食い違いは -3（unit_mismatch）
    function as_hours(s, unit,   v) {
      s = trim(s)
      if (s == "" || s == "(未記入)") return -1
      if (s ~ /^[0-9]+(\.[0-9]+)?h$/) {
        if (unit != "h") return -3
        sub(/h$/, "", s); v = s + 0
        return (v <= 0) ? -2 : v
      }
      if (s ~ /^[0-9]+(\.[0-9]+)?d$/) {
        if (unit == "h") return -3
        sub(/d$/, "", s); v = s + 0
        return (v <= 0) ? -2 : v * 8
      }
      return -2
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
      else if (key == "effort_unit") { if (un_seen) broken = 1; un_seen = 1; unit = val }
    }
    END {
      # ブロック不在は close-issue 手順 5a の fail-open 契約どおり止めない
      if (!hasblock) exit 1
      if (!closed) broken = 1           # 未閉鎖ブロックは集計器でも malformed
      if (broken) exit 1
      # 未知の単位宣言は集計器では malformed
      if (un_seen && unit != "h") exit 1
      hp = hp_seen ? as_hours(hp_raw, unit) : -1
      ap = ap_seen ? as_hours(ap_raw, unit) : -1
      aa = aa_seen ? as_hours(aa_raw, unit) : -1
      # 兄弟キーの書式不正・単位の食い違いは集計器では planned_only より先に
      # malformed / unit_mismatch へ落ちる
      if (hp == -2 || ap == -2 || aa == -2) exit 1
      if (hp == -3 || ap == -3 || aa == -3) exit 1
      if (aa < 0) exit 0                # planned_only（= 止める唯一の状態）
      exit 1
    }
  ' 2>/dev/null
}

# Refs だけの未記入 Issue について、この PR の完了報告がコメントにあるか。
# hit = 印がある / miss = 読めたが印が無い / unread = comments を解釈できない。
# 印は `<!-- close-issue-report:PR-<この PR 番号> -->` の完全な部分文字列
# （末尾の空白と閉じまで含める。番号の前方一致で隣の PR を拾わない）。
refs_report_state() {
  local state
  state="$(printf '%s' "$1" | jq -r --arg marker "$2" '
    if (.comments | type) != "array" then "unread"
    elif any(.comments[]; (type != "object") or ((.body != null) and ((.body | type) != "string"))) then "unread"
    elif any(.comments[]; ((.body // "") | contains($marker))) then "hit"
    else "miss"
    end
  ' 2>/dev/null)" || state="unread"
  state="${state//$'\r'/}"
  case "$state" in
    hit | miss | unread) printf '%s\n' "$state" ;;
    *) printf '%s\n' unread ;;
  esac
}

unfilled=""
refs_blocked=""
# MCP 経路だけが使う: gh で読めなかった Issue（Bash 経路は従来どおり読み飛ばすだけ）
unread=""
refs_fetch_unread=""
refs_comments_unread=""
truncated=0
count=0
report_marker="<!-- close-issue-report:PR-${pr_number} -->"
while IFS= read -r row; do
  [ -n "$row" ] || continue
  kind="${row%% *}"
  num="${row#* }"
  num="${num//$'\r'/}"
  case "$kind" in
    C | R) ;;
    *) continue ;;
  esac
  case "$num" in
    '' | *[!0-9]*) continue ;;
  esac
  count=$((count + 1))
  if [ "$count" -gt "$MAX_ISSUES" ]; then
    truncated=1
    break
  fi
  issue_json="$(cd "$CWD" 2>/dev/null && gh issue view "$num" ${GH_ARGS[0]:+"${GH_ARGS[@]}"} --json body,state 2>/dev/null)" || issue_json=""
  if [ -z "$issue_json" ]; then
    if [ "$kind" = "C" ]; then
      unread="${unread:+$unread, }#${num}"
    else
      refs_fetch_unread="${refs_fetch_unread:+$refs_fetch_unread, }#${num}"
    fi
    continue
  fi
  # 既に CLOSED の Issue は対象外（`/close-issue <PR番号>` が効かず停止が恒久化する）
  issue_state="$(printf '%s' "$issue_json" | jq -r '.state // ""' 2>/dev/null)"
  issue_state="${issue_state//$'\r'/}"
  [ "$issue_state" = "CLOSED" ] && continue
  issue_body="$(printf '%s' "$issue_json" | jq -r '.body // ""' 2>/dev/null)"
  issue_body="${issue_body//$'\r'/}"  # Windows の jq.exe は改行を \r\n で出す（Issue `#2017`）
  [ -n "$issue_body" ] || continue
  if is_effort_unfilled "$issue_body"; then
    if [ "$kind" = "C" ]; then
      # 閉じる Issue の記入は報告印で代替しない
      unfilled="${unfilled:+$unfilled, }#${num}"
    else
      comments_json="$(cd "$CWD" 2>/dev/null && gh issue view "$num" ${GH_ARGS[0]:+"${GH_ARGS[@]}"} --json comments 2>/dev/null)" || comments_json=""
      if [ -z "$comments_json" ]; then
        refs_comments_unread="${refs_comments_unread:+$refs_comments_unread, }#${num}"
      else
        report_state="$(refs_report_state "$comments_json" "$report_marker")"
        case "$report_state" in
          hit) ;;
          miss) refs_blocked="${refs_blocked:+$refs_blocked, }#${num}" ;;
          *) refs_comments_unread="${refs_comments_unread:+$refs_comments_unread, }#${num}" ;;
        esac
      fi
    fi
  fi
done <<EOF
$queue
EOF

if [ -z "$unfilled" ] && [ -z "$refs_blocked" ]; then
  [ -z "$unread" ] || mcp_skip "${REPO} の PR ${pr_number} が閉じる Issue（${unread}）を gh で読めないため、その Issue の工数実績を確認せずに通しました。"
  [ -z "$refs_fetch_unread" ] || mcp_skip "${REPO} の PR ${pr_number} の Refs 先 Issue（${refs_fetch_unread}）を gh で読めないため、その Issue の工数実績を確認せずに通しました。"
  [ -z "$refs_comments_unread" ] || mcp_skip "${REPO} の PR ${pr_number} の Refs 先 Issue（${refs_comments_unread}）のコメントを読めないため、完了報告の有無を確認せずに通しました。"
  [ "$truncated" -eq 0 ] || mcp_skip "${REPO} の PR ${pr_number} が閉じる Issue が照会上限（${MAX_ISSUES} 件）を超えたため、上限より後の Issue の工数実績を確認せずに通しました。"
  exit 0
fi

# 抜け道の案内だけが経路で違う（MCP の呼び出しにはコマンド先頭の環境代入を付けられない）
if [ "$GUARD_ROUTE" = "mcp" ]; then
  bypass_line="2) 実績を書き戻さずに進める場合は、gh で FF_EFFORT_ACTUAL_ACK=1 gh pr merge ${pr_number} --repo ${REPO} を実行する（その 1 回だけ通る）。gh を使えないなら、hook の環境変数 FF_EFFORT_ACTUAL_ACK=1 を設定してから同じ呼び出しを再実行する（GitHub MCP の呼び出しにはコマンド先頭の環境代入を付けられないため。Claude Code を起動するシェルで export し、再起動する。その 1 回ではなくセッション全体の GitHub MCP 呼び出しに効くので、済んだら外して再起動する）"
else
  bypass_line="2) 実績を書き戻さずに進める場合は、対象コマンドの先頭へ環境代入を付けて再実行する: FF_EFFORT_ACTUAL_ACK=1 gh pr merge ..."
fi

reason=""
if [ -n "$unfilled" ]; then
  reason="⛔ ff-dev-toolkit guard（工数実績が未記入のままのマージ）: この PR が閉じる Issue（${unfilled}）の本文には ff-effort ブロックがありますが、effort_ai_actual が未記入です。
このままマージすると Issue は閉じますが実績は空のままで、scripts/effort-report.sh の較正母集団から excluded_planned_only として静かに落ちます。
次のいずれかで再実行してください:
  1) AI エージェントへ /close-issue ${pr_number} を実行し、AC 照合と工数実績の書き戻しを済ませてから同じマージコマンドを実行する（推奨）
  ${bypass_line}
ff-effort ブロックが無い Issue はこのガードの対象外です（遡及付与は強制しません）。
このガード自体を止める場合は環境変数 FF_DEV_TOOLKIT_SKIP=effort-actual を設定します（ほかの鍵と並べるときはカンマ区切り）。"
fi
if [ -n "$refs_blocked" ]; then
  refs_reason="⛔ ff-dev-toolkit guard（工数実績が未記入のままのマージ）: この PR は Issue（${refs_blocked}）を閉じません（本文の Refs だけで、closing keyword も GitHub の closingIssuesReferences も、実行中のマージコマンドの subject / body も、この Issue を閉じていません）。対象の本文には ff-effort ブロックがありますが、effort_ai_actual が未記入で、この PR の /close-issue 報告（${report_marker}）がコメントにありません。
このままマージしても Issue は閉じません。実績を空のまま残すのは、/close-issue が継続中として報告したあとに限って通ります。
次のいずれかで再実行してください:
  1) AI エージェントへ /close-issue ${pr_number} を実行し、報告コメントを残してから同じマージコマンドを実行する（推奨）。継続中の Issue では実績を未記入のまま残してよい
  ${bypass_line}
ff-effort ブロックが無い Issue はこのガードの対象外です（遡及付与は強制しません）。
このガード自体を止める場合は環境変数 FF_DEV_TOOLKIT_SKIP=effort-actual を設定します（ほかの鍵と並べるときはカンマ区切り）。"
  if [ -n "$reason" ]; then
    reason="${reason}
${refs_reason}"
  else
    reason="$refs_reason"
  fi
fi

jq -n --arg reason "$reason" \
  '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "deny", permissionDecisionReason: $reason}}' 2>/dev/null

exit 0
