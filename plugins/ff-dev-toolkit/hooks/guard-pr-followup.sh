#!/usr/bin/env bash
#
# PR フォローアップ宣言ガード（PreToolUse / Bash、Issue #771）。
#
# `gh pr create` / `gh pr edit` が渡そうとする PR 本文に「スコープ外」等の
# フォローアップ宣言マーカーがあるのに、Issue 参照（`#<数字>` または Issue URL）が
# 無い場合に警告する。宣言だけ残して起票しないまま PR を作る手戻り
# （実測: tabi-concierge-tokyo PR #227 → 起票がレビュー後の #228 まで遅延）を
# 機械的に検出する。
#
# 判定は単純な共起（マーカーあり かつ Issue 参照なし）なので誤検出はありうる。
# したがってブロックではなく警告が趣旨だが、PreToolUse には「実行を許しつつ
# agent に警告文を見せる」チャネルが無い（additionalContext 非対応）ため、
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
# 設計原則:
#   - fail-open: 全 Bash 呼び出しに割り込むため、自身の不具合や解析不能な形では
#     黙って許可（exit 0・無出力）に倒す。jq が無い環境も同様。
#   - 互換性: bash 3.2（stock macOS）互換。perl は本文抽出の精度向上にだけ使い、
#     無ければ全文フォールバックで動く。
#
# 環境変数:
#   FF_DEV_TOOLKIT_SKIP_PR_FOLLOWUP_GUARD=1  このガードを無効化する

# fail-open のため set -e / set -u は使わない。

[ "${FF_DEV_TOOLKIT_SKIP_PR_FOLLOWUP_GUARD:-0}" = "1" ] && exit 0

input="$(cat 2>/dev/null)" || exit 0

# 安価な前置フィルタ
case "$input" in
  *gh*) : ;;
  *) exit 0 ;;
esac

command -v jq >/dev/null 2>&1 || exit 0

cmd="$(printf '%s' "$input" | jq -r 'if .tool_name == "Bash" then (.tool_input.command // "") else "" end' 2>/dev/null)" || exit 0
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
GH_TOKS=()

find_gh_segment() {
  local toks=("$@")
  local n=${#toks[@]} i=0 t
  while [ "$i" -lt "$n" ]; do
    t="$(strip_quotes "${toks[$i]}")"
    case "$t" in
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
  case "$(strip_quotes "${toks[$((i + 2))]}")" in
    create | edit) : ;;
    *) return 0 ;;
  esac
  GH_FOUND=1
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
  body_file="$(strip_quotes "$body_file")"
  if [ "$body_file" != "-" ]; then
    case "$body_file" in
      /*) : ;;
      *) [ -d "$CWD" ] && body_file="$CWD/$body_file" ;;
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

# 抜け道: 理由付きの明示マーカー（起票不要の正当な判断。理由は必須）
printf '%s' "$text" | grep -Eq '<!--[[:space:]]*no-followup:[[:space:]]*[^[:space:]].*-->' && exit 0

# 宣言マーカーの検出（見つかったものを警告文へ列挙する）
found=""
add_found() {
  found="${found:+$found / }$1"
}
printf '%s' "$text" | grep -q 'スコープ外' && add_found 'スコープ外'
printf '%s' "$text" | grep -Eq '別[[:space:]]?[Ii]ssue' && add_found '別Issue'
printf '%s' "$text" | grep -q '別対応' && add_found '別対応'
printf '%s' "$text" | grep -q '後で対応' && add_found '後で対応'
printf '%s' "$text" | grep -q '別途' && add_found '別途'
printf '%s' "$text" | grep -Eiq 'follow[- ]?up' && add_found 'follow-up'
printf '%s' "$text" | grep -Eiq 'out of scope' && add_found 'out of scope'

[ -n "$found" ] || exit 0

# Issue 参照があれば宣言は起票に結びついているとみなす
printf '%s' "$text" | grep -Eq '#[0-9]+' && exit 0
printf '%s' "$text" | grep -Eq 'https?://[^[:space:]]+/issues/[0-9]+' && exit 0

reason="⚠️ ff-dev-toolkit guard（フォローアップ宣言の起票漏れ・警告）: PR 本文にフォローアップ宣言（検出マーカー: ${found}）がありますが、Issue 参照（#<番号> または Issue URL）が見つかりません。
宣言だけ残して起票しないと、あとから気づいて起票する手戻りになります。次のいずれかで再実行してください:
  1) 先に gh issue create で起票し、発行された Issue 番号（#NNN）を PR 本文に記載する
  2) 起票不要と判断した場合は、本文に <!-- no-followup: 理由 --> を追記する（理由は必須）
  3) 宣言自体が不要なら本文から外す
このガードを止める場合は環境変数 FF_DEV_TOOLKIT_SKIP_PR_FOLLOWUP_GUARD=1 を設定します。"

jq -n --arg reason "$reason" \
  '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "deny", permissionDecisionReason: $reason}}' 2>/dev/null

exit 0
