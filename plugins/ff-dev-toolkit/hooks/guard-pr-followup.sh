#!/usr/bin/env bash

#
# PR フォローアップ宣言ガード（PreToolUse / Bash・GitHub MCP、Issue `#771`）。
#
# `gh pr create` / `gh pr edit` が渡そうとする PR 本文に「スコープ外」等の
# フォローアップ宣言マーカーがあるのに、Issue 参照（`#<数字>` または Issue URL）が
# 無い場合に警告する。宣言だけ残して起票しないまま PR を作る手戻り
# （実測: tabi-concierge-tokyo PR #227 → 起票がレビュー後の #228 まで遅延）を
# 機械的に検出する。
#
# 判定は単純な共起（マーカーあり かつ Issue 参照なし）なので誤検出はありうる。
# したがってブロックではなく警告が趣旨だが、PreToolUse には「実行を許しつつ
# agent に警告文を見せる」チャネル（`additionalContext`）は無い。届くのは
# `permissionDecision: "deny"` の `permissionDecisionReason` だけなので、警告は
# 抜け道付きの deny（= 再実行可能な警告）として実装する。抜け道:
#   - 本文に Issue 参照（`#<数字>` / GitHub Issue URL）を書く
#   - 起票不要の正当な判断は `<!-- no-followup: 理由 -->`（理由は必須）を本文へ書く
#
# 判定対象テキスト（優先順）:
#   1. `--body "..."` / `-b '...'` / `--body=...` のクォート済み引数値を抽出できた
#      場合はその本文（perl で抽出。`--title` 等の本文以外に Issue 参照があっても
#      判定を抑止しない）。heredoc `--body "$(cat <<'EOF' ...)"` も引用内に本文が
#      現れるため抽出できる
#   2. 抽出できない形（クォート無しの単語 body 等）はコマンド文字列全体へ
#      フォールバックする（既知の限界: 本文以外の文字列も判定に混ざる）
#   3. `--body-file <path>` / `-F <path>` は hook 実行時点でファイルが読めれば
#      その内容を判定へ加える
#
# 対象コマンドの特定は「コマンド位置」の gh だけを見る（先頭の環境代入・
# env/command/sudo/nohup ラッパーを剥がした位置）。`echo 'gh pr create ...'` の
# ような文字列出力では発火しない。
#
# 既知の限界（判定できず素通しする渡し方）:
#   - `--body-file -`（stdin）、プロセス置換 `--body-file <(...)`、同一コマンド内で
#     生成される一時ファイル（hook 実行時点で未作成）
#   - `--fill` / インタラクティブ入力 / web での本文入力（body 系フラグ無し）
#   - コマンド文字列と body-file 内容以外の場所に本文が組み立てられる場合
#
# Draft PR の作成（Issue `#2089`）: 同じコマンド位置の判定を再利用し、`gh pr create --draft` / `-d` / `--draft=true` と
# `gh pr ready --undo`（通常 PR を Draft へ戻す）も抜け道付き deny で止める。契約は「通常 PR として作る
# （Draft にしない）」（docs-template の git-workflow.md ステップ5 / ADR-053・ADR-054）で、入口文書の旧規定や
# 手癖で Draft のまま残る事象が導入先で出ていた。Draft はあとから `gh pr ready` で戻せるので取り返せない
# 損失ではないが、Draft のままだとマージまで進むノンストップフローが止まる。止める理由と次の一手を
# エージェントへ届ける経路が deny の理由文しか無いので、警告ではなく抜け道付き deny にする。
# 抜け道: gh より前の環境代入 `FF_PR_DRAFT_ACK=1`（引数の中の同じ文字列では通さない。ACE の自律フローのように、人の確認待ちという理由がある
# Draft だけに使う）。素朴な空白分割なので、`--title "x -d y"` のように引用内に単独の `-d` がある形は
# 誤って止まりうる（そのときも同じ抜け道で通す）。
#
# GitHub MCP 経路（PreToolUse / `create_pull_request` / `update_pull_request`）:
#   hooks.json は MCP のツール名を matcher に持つエントリからも本ガードを起動する。
#   `draft: true` は Draft PR の作成（create）・Draft への戻し（update。`gh pr ready --undo` 相当）として
#   同じ deny で止め、`body` には Bash 経路と同じフォローアップ宣言の判定を当てる（判定と deny 文は
#   関数で共有する）。gh は使わない。振り分けは共有ヘルパ tests/lib/github-mcp-route.sh の
#   ff_github_mcp_route_input。Draft の抜け道は hook の環境変数 `FF_PR_DRAFT_ACK=1`（MCP の呼び出しには
#   コマンド先頭の環境代入を付けられないため）で、hook の環境は Claude Code の起動時に決まるので、
#   その 1 回ではなくセッション全体の GitHub MCP 呼び出しに効く。フォローアップ宣言の抜け道は本文の
#   Issue 参照 / `<!-- no-followup: 理由 -->` のまま。抜け道で通したとき・判定できない入力（判定表に
#   ないツール名・オブジェクトでない tool_input・文字列でない body・jq 不在）のときは素通しせず、
#   理由を systemMessage（利用者）と additionalContext（エージェントの文脈）に出して通す。
#
# 設計原則:
#   - fail-open: 全 Bash 呼び出しに割り込むため、自身の不具合や解析不能な形では
#     黙って許可（exit 0・無出力）に倒す。jq が無い環境も同様。GitHub MCP 経路だけは、
#     判定を省略した理由を出して通す（無出力にしない）。
#   - 互換性: bash 3.2（stock macOS）互換。perl は本文抽出の精度向上にだけ使い、
#     無ければ全文フォールバックで動く。
#
# 環境変数:
#   FF_DEV_TOOLKIT_SKIP_PR_FOLLOWUP_GUARD=1  このガードを無効化する（Draft PR の検出も含む）
#   FF_PR_DRAFT_ACK=1（コマンド先頭の環境代入）  Draft PR の検出だけをその 1 回通す
#     （GitHub MCP 経路では hook の環境変数として読み、セッション全体の GitHub MCP 呼び出しに効く。
#     hook の環境の値は MCP 経路だけが読み、Bash 経路は通さない）

# fail-open のため set -e / set -u は使わない。

# stdin は bash 組み込みの read で読み切る（外部コマンドに依存しない）。`cat` だと PATH が
# 空・壊れた環境で command not found → stdin 未読のまま exit 0 となり、書き手（ホスト）が
# EPIPE / SIGPIPE を受ける（Issue #1329。guard-background-cwd と同じ修正）。opt-out も
# stdin を読み切ってから抜ける。-d '' は EOF で非 0 を返すが input には内容が入っている。
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

[ "${FF_DEV_TOOLKIT_SKIP_PR_FOLLOWUP_GUARD:-0}" = "1" ] && exit 0

# Draft PR の deny（Bash 経路と GitHub MCP 経路で共有。違うのは対象の表示と 2 つの選択肢だけ）。
deny_draft() { # <対象の表示> <選択肢 1> <選択肢 2>
  local reason
  reason="⚠️ ff-dev-toolkit guard（Draft PR）: \`${1}\` は PR を Draft にします。契約は「通常 PR として作る（Draft にしない）」です（docs-template/05-operations/deployment/git-workflow.md ステップ5・ADR-053 / ADR-054）。Draft のままだと、マージまで続くフローがそこで止まります。
次のいずれかで再実行してください:
  1) ${2}
  2) ${3}
既に Draft の PR は gh pr ready <番号> で通常 PR へ戻せます。入口文書（CLAUDE.md / AGENTS.md）に Draft の指示が残っていないかは /workflow-doctor の検査 8 で確かめられます。
このガードを止める場合は環境変数 FF_DEV_TOOLKIT_SKIP_PR_FOLLOWUP_GUARD=1 を設定します（フォローアップ宣言の検出も止まります）。"
  jq -n --arg reason "$reason" \
    '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "deny", permissionDecisionReason: $reason}}' 2>/dev/null
  exit 0
}

# フォローアップ宣言の判定（Bash 経路と GitHub MCP 経路で共有）。止めるときは deny を出して
# exit し、止めないときは何も出さずに呼び出し元へ戻る（後始末と終了は呼び出し元が持つ）。
judge_followup_text() { # <判定対象テキスト>
  local text="$1" declarations found="" reason
  # 抜け道: 理由付きの明示マーカー（起票不要の正当な判断。理由は必須）
  printf '%s' "$text" | grep -Eq '<!--[[:space:]]*no-followup:[[:space:]]*[^[:space:]].*-->' && return 0

  # ATX 見出しは欄の名前なので、宣言マーカーの照合からだけ除く。
  # Issue 参照と no-followup は見出し内でも有効なので元の text で照合する。
  declarations="$(printf '%s\n' "$text" | sed -E '/^ {0,3}#{1,6}([[:blank:]]|$)/d')"
  # 宣言マーカーの検出（見つかったものを警告文へ列挙する）
  printf '%s' "$declarations" | grep -q 'スコープ外' && found="${found:+$found / }スコープ外"
  printf '%s' "$declarations" | grep -Eq '別[[:space:]]?[Ii]ssue' && found="${found:+$found / }別Issue"
  printf '%s' "$declarations" | grep -q '別対応' && found="${found:+$found / }別対応"
  printf '%s' "$declarations" | grep -q '後で対応' && found="${found:+$found / }後で対応"
  printf '%s' "$declarations" | grep -q '別途' && found="${found:+$found / }別途"
  printf '%s' "$declarations" | grep -Eiq 'follow[- ]?up' && found="${found:+$found / }follow-up"
  printf '%s' "$declarations" | grep -Eiq 'out of scope' && found="${found:+$found / }out of scope"

  [ -n "$found" ] || return 0

  # Issue 参照があれば宣言は起票に結びついているとみなす
  printf '%s' "$text" | grep -Eq '#[0-9]+' && return 0
  printf '%s' "$text" | grep -Eq 'https?://[^[:space:]]+/issues/[0-9]+' && return 0

  reason="⚠️ ff-dev-toolkit guard（フォローアップ宣言の起票漏れ・警告）: PR 本文にフォローアップ宣言（検出マーカー: ${found}）がありますが、Issue 参照（#<番号> または Issue URL）が見つかりません。
宣言だけ残して起票しないと、あとから気づいて起票する手戻りになります。次のいずれかで再実行してください:
  1) 先に gh issue create で起票し、発行された Issue 番号（#NNN）を PR 本文に記載する
  2) 起票不要と判断した場合は、本文に <!-- no-followup: 理由 --> を追記する（理由は必須）
  3) 宣言自体が不要なら本文から外す
このガードを止める場合は環境変数 FF_DEV_TOOLKIT_SKIP_PR_FOLLOWUP_GUARD=1 を設定します。"

  jq -n --arg reason "$reason" \
    '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "deny", permissionDecisionReason: $reason}}' 2>/dev/null
  exit 0
}

# ---- GitHub MCP 経路（create_pull_request / update_pull_request）---------------
# 振り分け（tool_name の読み取り・判定表の照合）は共有ヘルパの ff_github_mcp_route_input。ここは
# 受け持つツールの tool_input の判定だけを持ち、判定して必ず exit する。PR 本文は
# tool_input.body にそのまま入っているので、コマンド文字列からの抽出は要らず、gh も使わない。
guard_mcp_route() {
  local draft body ack_note=""
  if ! printf '%s' "$input" | jq -e '.tool_input | type == "object"' >/dev/null 2>&1; then
    ff_github_mcp_note "PR 作成" "${MCP_TOOL_NAME} の tool_input がオブジェクトとして読めないため、Draft とフォローアップ宣言を検査せずに通しました。"
    exit 0
  fi
  # `draft: true` は create では Draft で作る、update では通常 PR を Draft へ戻す（gh pr ready --undo 相当）。
  # draft: false（update で Draft から戻す）と省略は止めない。
  draft="$(printf '%s' "$input" | jq -r '.tool_input.draft | if . == true or . == "true" then "true" else "" end' 2>/dev/null)" || draft=""
  draft="${draft//$'\r'/}"
  if [ "$draft" = "true" ]; then
    if [ "${FF_PR_DRAFT_ACK:-0}" != "1" ]; then
      deny_draft "${MCP_TOOL}（draft: true）" \
        'draft を外す（false にするか省略する）。通常 PR を Draft へ戻す update_pull_request（draft: true）なら実行しない' \
        '人の確認待ちという理由がある Draft（ACE の自律フロー等）だけは、hook の環境変数 FF_PR_DRAFT_ACK=1 を設定してから再実行する（GitHub MCP の呼び出しにはコマンド先頭の環境代入を付けられないため。Claude Code を起動するシェルで export し、再起動する。その 1 回ではなくセッション全体の GitHub MCP 呼び出しに効くので、済んだら外して再起動する）'
    fi
    # 抜け道で通した通知は、本文の判定が止めなかったときだけ出す（hook の出力は JSON 1 つ）
    ack_note="hook の環境変数 FF_PR_DRAFT_ACK=1 により、${MCP_TOOL_NAME} の draft: true を止めずに通しました。この設定は Claude Code のセッション全体（GitHub MCP の呼び出しすべて）に効くので、済んだら外して再起動してください。"
  fi
  if ! printf '%s' "$input" | jq -e '.tool_input.body | type == "string" or type == "null"' >/dev/null 2>&1; then
    ff_github_mcp_note "PR 作成" "${ack_note:+${ack_note} }${MCP_TOOL_NAME} の tool_input.body が文字列でないため、フォローアップ宣言を検査せずに通しました。"
    exit 0
  fi
  body="$(printf '%s' "$input" | jq -r '.tool_input.body // "" | strings' 2>/dev/null)" || body=""
  body="${body//$'\r'/}"
  # 本文を渡さない呼び出し（タイトルだけの更新など）は判定するものが無い
  [ -z "$body" ] || judge_followup_text "$body"
  [ -z "$ack_note" ] || ff_github_mcp_note "PR 作成" "$ack_note"
  exit 0
}

# MCP の入力は `gh` を含まないので、下の Bash 用の前置フィルタ（*gh*）より前で振り分ける
# （後ろに置くと MCP の入力が jq を起動する前に素通しで落ちる）。
case "$input" in
  *mcp__*)
    # shellcheck source=../tests/lib/github-mcp-route.sh
    if . "${BASH_SOURCE[0]%/*}/../tests/lib/github-mcp-route.sh" 2>/dev/null; then
      ff_github_mcp_route_input "PR 作成" create_pull_request update_pull_request
      [ "$GUARD_ROUTE" = "mcp" ] && guard_mcp_route
    else
      case "$input" in
        *'"tool_name":"mcp__'* | *'"tool_name": "mcp__'*)
          printf '%s\n' '{"systemMessage":"ℹ️ ff-dev-toolkit guard（PR 作成・GitHub MCP）: 判定ヘルパ tests/lib/github-mcp-route.sh を読めないため、GitHub MCP の呼び出しを検査せずに通しました。"}'
          exit 0
          ;;
      esac
    fi
    ;;
esac

# 安価な前置フィルタ
case "$input" in
  *gh*) : ;;
  *) exit 0 ;;
esac

command -v jq >/dev/null 2>&1 || exit 0

cmd="$(printf '%s' "$input" | jq -r 'if .tool_name == "Bash" then (.tool_input.command // "") else "" end' 2>/dev/null)" || exit 0
cmd="${cmd//$'\r'/}"  # Windows の jq.exe は改行を \r\n で出す（Issue `#2017`）
[ -n "$cmd" ] || exit 0
case "$cmd" in
  *gh*) : ;;
  *) exit 0 ;;
esac

CWD="$(printf '%s' "$input" | jq -r '.cwd // ""' 2>/dev/null)"

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

# ---- コマンド位置の `gh pr create|edit` を含むセグメントを特定する -------------
# 見つかったら GH_TOKS にそのセグメントのトークン列を積む。
GH_FOUND=0
GH_SUB=""
GH_ACK=0
GH_TOKS=()

find_gh_segment() {
  local toks=("$@")
  local n=${#toks[@]} i=0 t ack=0 j
  while [ "$i" -lt "$n" ]; do
    t="$(strip_quotes "${toks[$i]}")"
    case "$t" in
      [A-Za-z_]*=*)
        # Draft の抜け道は gh より前の環境代入だけで受ける（引数の中の同じ文字列では通さない）
        [ "$t" = "FF_PR_DRAFT_ACK=1" ] && ack=1
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
  case "$(strip_quotes "${toks[$((i + 2))]}")" in
    create | edit) GH_SUB="$(strip_quotes "${toks[$((i + 2))]}")" ;;
    ready)
      # ready は --undo（Draft へ戻す）のときだけ確定させる。素の ready で確定させると、最初に見つかった
      # セグメントで判定が終わり、`gh pr ready 12 && gh pr create --draft` の後段を検査しなくなる
      j=$((i + 3))
      while [ "$j" -lt "$n" ]; do
        [ "$(strip_quotes "${toks[$j]}")" = "--undo" ] && break
        j=$((j + 1))
      done
      [ "$j" -lt "$n" ] || return 0
      GH_SUB=ready
      ;;
    *) return 0 ;;
  esac
  GH_FOUND=1
  GH_ACK="$ack"
  GH_TOKS=("${toks[@]}")
  return 0
}

segments="$(printf '%s\n' "$cmd" | awk '{ gsub(/&&|\|\||;|\|/, "\n"); print }')"
while IFS= read -r seg; do
  [ -n "$seg" ] || continue
  case "$seg" in
    *gh*) : ;;
    *) continue ;;
  esac
  set -f
  # shellcheck disable=SC2206 # 素朴な空白トークン化（意図的。glob は set -f で抑止）
  toks=($seg)
  set +f
  [ "$GH_FOUND" -eq 1 ] || find_gh_segment "${toks[@]}"
done <<EOF
$segments
EOF

[ "$GH_FOUND" -eq 1 ] || exit 0

# ---- Draft PR の作成・Draft への戻し（Issue `#2089`） ------------------------------
draft_flag=""
for t in "${GH_TOKS[@]}"; do
  t="$(strip_quotes "$t")"
  case "$GH_SUB:$t" in
    create:--draft | create:-d | create:--draft=true) draft_flag="gh pr create $t" ;;
    ready:--undo) draft_flag="gh pr ready --undo" ;;
  esac
done
if [ -n "$draft_flag" ] && [ "$GH_ACK" -eq 0 ]; then
  deny_draft "$draft_flag" \
    'Draft のフラグを外して通常 PR として作る（gh pr ready --undo なら実行しない）' \
    '人の確認待ちという理由がある Draft（ACE の自律フロー等）だけは、コマンドの**先頭**へ FF_PR_DRAFT_ACK=1 を付けて再実行する'
fi
# ready（--undo）は本文フラグを持たないので、下の body フラグ判定で素通しになる（フォローアップ宣言の判定は create / edit だけ）

# 本文を渡すフラグが無い形（--fill / インタラクティブ / web）は判定できない
has_body_flag=0
body_file=""
n=${#GH_TOKS[@]}
i=0
while [ "$i" -lt "$n" ]; do
  t="${GH_TOKS[$i]}"
  case "$t" in
    --body | -b | --body=*) has_body_flag=1 ;;
    --body-file | -F)
      has_body_flag=1
      j=$((i + 1))
      [ "$j" -lt "$n" ] && body_file="${GH_TOKS[$j]}"
      ;;
    --body-file=*)
      has_body_flag=1
      body_file="${t#--body-file=}"
      ;;
  esac
  i=$((i + 1))
done
[ "$has_body_flag" -eq 1 ] || exit 0

# ---- 判定対象テキストの決定 ---------------------------------------------------
# クォート済みの --body / -b 引数値を抽出できればそれを使う（--title 等の
# 本文以外を判定に混ぜない）。抽出できなければコマンド全文へフォールバック。
text=""
if command -v perl >/dev/null 2>&1; then
  text="$(printf '%s' "$cmd" | perl -0777 -ne '
    if (/(?:--body|(?<![-\w])-b)(?:=|\s+)"((?:\\.|[^"\\])*)"/s) { print $1; exit }
    if (/(?:--body|(?<![-\w])-b)(?:=|\s+)\x27([^\x27]*)\x27/s) { print $1; exit }
  ' 2>/dev/null)"
fi

if [ -n "$body_file" ]; then
  body_file_raw="$body_file"
  body_file="$(strip_quotes "$body_file")"
  if [ "$body_file" != "-" ]; then
    # Windows のドライブ付き絶対パス（Git Bash / Cygwin のときだけ。Issue `#2018`）。引用符付きと `/` 区切りは
    # 絶対パス。引用符なしの `C:\x` は bash がバックスラッシュを落とした `C:x`（cwd からの相対）を gh へ渡す
    win_drive=0
    case "${OSTYPE:-}" in
      msys* | cygwin*)
        case "$body_file_raw" in
          [A-Za-z]:\\*) body_file="${body_file//\\/}" ;;
          *) case "$body_file" in [A-Za-z]:\\* | [A-Za-z]:/*) body_file="${body_file//\\//}"; win_drive=1 ;; esac ;;
        esac
        ;;
    esac
    case "$body_file" in
      /*) : ;;
      *) [ "$win_drive" -eq 1 ] || { [ -d "$CWD" ] && body_file="$CWD/$body_file"; } ;;
    esac
    if [ -f "$body_file" ] && [ -r "$body_file" ]; then
      file_text="$(cat "$body_file" 2>/dev/null)" || file_text=""
      text="$text
$file_text"
    fi
  fi
fi

# 本文をどこからも抽出できなければコマンド全文へフォールバックする
[ -n "$text" ] || text="$cmd"

judge_followup_text "$text"
exit 0
