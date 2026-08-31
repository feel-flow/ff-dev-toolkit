#!/usr/bin/env bash
#
# 未コミット変更ガード（PreToolUse / Bash、Issue #673）。
#
# Bash ツールが実行しようとするコマンドを PreToolUse で検査し、
# 「未コミット変更のあるファイル」への `git checkout [--] <path>` /
# `git restore <path>` を検出したら permissionDecision "deny" +
# 代替手段（cp バックアップ / git stash push → pop）の案内で止める。
# PreToolUse には「実行を許しつつ agent に警告文を見せる」チャネルが無い
# （additionalContext 非対応）ため、警告は再実行可能な deny として実装する。
# 意図的な破棄は、対象 git コマンドの先頭に環境代入 FF_DISCARD_UNCOMMITTED=1 を
# 付ければ素通しする（文字列としてコマンド中に現れるだけでは無効）。
#
# 発火しない（誤爆させない）ケース:
#   - ブランチ切り替え（`git checkout <branch>` / `git checkout -b <new>` /
#     `git switch ...`）— 引数が「未コミット変更を持つパス」に解決されない限り
#     発火しない（dirty 判定そのものが曖昧さを解決する）。dirty なファイルと
#     同名のローカルブランチがある場合も、`--` 無しの形はブランチ切り替えとして
#     扱い発火しない
#   - clean なファイル・untracked（`??`）なファイルへの復元
#   - `git restore --staged <path>`（--worktree / -W 併用なし）— worktree に触れない
#   - コマンド位置に無い git（`echo git restore ...` のような文字列出力）
#   - git リポジトリ外、git 以外のコマンド
#
# 設計原則:
#   - fail-open: この hook は全 Bash 呼び出しに割り込む。自身の不具合・解析不能な
#     コマンド形（クォート内の空白パス、--pathspec-from-file、`cd` 後の相対パス等）
#     ではユーザーの作業を壊さず黙って許可（exit 0・無出力）に倒す。ガードとしての
#     取りこぼしは許容し、誤ブロックだけを避ける。
#   - 互換性: bash 3.2（stock macOS）互換。連想配列・readarray・=~ は使わない。
#     JSON の解析・生成には jq を使う（無ければ fail-open）。
#   - `git -C <dir>` は dirty 判定にも同じ <dir> を用いる（hook 入力の cwd 基準で
#     相対解決する）。
#
# 環境変数:
#   FF_DEV_TOOLKIT_SKIP_CHECKOUT_GUARD=1  このガードを無効化する

# fail-open のため set -e / set -u は使わない。

[ "${FF_DEV_TOOLKIT_SKIP_CHECKOUT_GUARD:-0}" = "1" ] && exit 0

input="$(cat 2>/dev/null)" || exit 0

# 安価な前置フィルタ: git かつ checkout/restore を含まない入力は即終了
case "$input" in
  *git*) : ;;
  *) exit 0 ;;
esac
case "$input" in
  *checkout* | *restore*) : ;;
  *) exit 0 ;;
esac

command -v jq >/dev/null 2>&1 || exit 0

cmd="$(printf '%s' "$input" | jq -r 'if .tool_name == "Bash" then (.tool_input.command // "") else "" end' 2>/dev/null)" || exit 0
[ -n "$cmd" ] || exit 0
case "$cmd" in
  *git*) : ;;
  *) exit 0 ;;
esac

CWD="$(printf '%s' "$input" | jq -r '.cwd // ""' 2>/dev/null)"
[ -d "$CWD" ] || CWD="$(pwd)"

# 前後の単純クォートを剥がす（"file" / 'file' → file）。空白入りパスの
# トークン分断は既知の限界（dirty 判定が成立せず fail-open になる）。
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

# 対象パスに untracked（??）以外の未コミット変更があるか。
# $1=パス $2=実行ディレクトリ $3=1 なら `-` 始まりも実パスとして許可（`--` 後の引数）
is_dirty() {
  local p="$1" dir="$2" allow_dash="${3:-0}" out
  p="$(strip_quotes "$p")"
  [ -n "$p" ] || return 1
  if [ "$allow_dash" != "1" ]; then
    case "$p" in
      -*) return 1 ;; # 取り漏れたフラグ類はパスとして扱わない
    esac
  fi
  out="$(git -C "$dir" status --porcelain -- "$p" 2>/dev/null)" || return 1
  printf '%s\n' "$out" | grep -v '^??' | grep -q .
}

# ローカルブランチ名として解決できるか（`--` 無しの checkout 引数の曖昧性解決）
is_local_branch() {
  local name dir="$2"
  name="$(strip_quotes "$1")"
  [ -n "$name" ] || return 1
  git -C "$dir" rev-parse --verify --quiet "refs/heads/$name" >/dev/null 2>&1
}

DIRTY_LIST=""

add_dirty() {
  local p
  p="$(strip_quotes "$1")"
  case " $DIRTY_LIST " in
    *" $p "*) : ;;
    *) DIRTY_LIST="${DIRTY_LIST:+$DIRTY_LIST }$p" ;;
  esac
}

# 1 セグメント（連結演算子で区切った単位）を解析し、dirty なパスがあれば
# DIRTY_LIST へ積む。git は「コマンド位置」（先頭の環境代入・env/command/sudo/
# nohup ラッパーを剥がした位置）にある場合だけ解析する — `echo git restore ...`
# のような文字列出力を deny しないため。
analyze_segment() {
  local toks=("$@")
  local n=${#toks[@]}
  local i=0 t sub="" bypass=0 gitdir="$CWD"

  # 先頭の環境代入とラッパーコマンドを剥がす
  while [ "$i" -lt "$n" ]; do
    t="$(strip_quotes "${toks[$i]}")"
    case "$t" in
      FF_DISCARD_UNCOMMITTED=1)
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
        # ラッパー自身のオプションを飛ばす（値を取る形は解析せず、続きが
        # コマンド名に見えなければ fail-open で抜ける）
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
    git | */git) : ;;
    *) return 0 ;;
  esac
  # 対象 git コマンド先頭の環境代入としてのバイパスだけを認める
  [ "$bypass" -eq 1 ] && return 0

  # git のグローバルオプションを飛ばしてサブコマンドを特定する。
  # -C は dirty 判定の実行ディレクトリにも反映する（相対は cwd 基準）。
  i=$((i + 1))
  while [ "$i" -lt "$n" ]; do
    t="${toks[$i]}"
    case "$t" in
      -C)
        i=$((i + 1))
        if [ "$i" -lt "$n" ]; then
          local cdir
          cdir="$(strip_quotes "${toks[$i]}")"
          case "$cdir" in
            /*) gitdir="$cdir" ;;
            ?*) gitdir="$gitdir/$cdir" ;;
          esac
        fi
        i=$((i + 1))
        ;;
      -c | --git-dir | --work-tree | --namespace | --exec-path)
        i=$((i + 2))
        ;;
      -*) i=$((i + 1)) ;;
      *)
        sub="$t"
        break
        ;;
    esac
  done
  [ -n "$sub" ] || return 0
  [ -d "$gitdir" ] || return 0
  git -C "$gitdir" rev-parse --git-dir >/dev/null 2>&1 || return 0

  local k=$((i + 1)) seen_dashdash=0
  case "$sub" in
    checkout)
      local before="" after=""
      while [ "$k" -lt "$n" ]; do
        t="${toks[$k]}"
        if [ "$seen_dashdash" -eq 1 ]; then
          after="${after:+$after }$t"
          k=$((k + 1))
          continue
        fi
        case "$t" in
          --) seen_dashdash=1 ;;
          # ブランチ作成・切り替え系はファイル復元ではない
          -b | -B | --orphan | -t | --track | --detach) return 0 ;;
          # パス集合をファイルから読む形は解析できない（fail-open）
          --pathspec-from-file | --pathspec-from-file=*) return 0 ;;
          # 値を取るオプション
          --conflict) k=$((k + 1)) ;;
          -*) : ;;
          *) before="${before:+$before }$t" ;;
        esac
        k=$((k + 1))
      done
      if [ "$seen_dashdash" -eq 1 ]; then
        # `git checkout [<ref>] -- <paths>` の <paths>（`-` 始まりの実ファイルも対象）
        for t in $after; do
          is_dirty "$t" "$gitdir" 1 && add_dirty "$t"
        done
      else
        # `git checkout <arg>...` — ローカルブランチに解決できる引数は
        # ブランチ切り替えとして扱い、それ以外だけ dirty 判定する
        for t in $before; do
          is_local_branch "$t" "$gitdir" && continue
          is_dirty "$t" "$gitdir" 0 && add_dirty "$t"
        done
      fi
      ;;
    restore)
      local staged=0 worktree=0 paths="" dash_paths=""
      while [ "$k" -lt "$n" ]; do
        t="${toks[$k]}"
        if [ "$seen_dashdash" -eq 1 ]; then
          dash_paths="${dash_paths:+$dash_paths }$t"
          k=$((k + 1))
          continue
        fi
        case "$t" in
          --) seen_dashdash=1 ;;
          --staged | -S) staged=1 ;;
          --worktree | -W) worktree=1 ;;
          -s | --source) k=$((k + 1)) ;;
          --pathspec-from-file | --pathspec-from-file=*) return 0 ;;
          -*) : ;;
          *) paths="${paths:+$paths }$t" ;;
        esac
        k=$((k + 1))
      done
      # --staged 単独は index のみの操作で worktree の編集を消さない
      if [ "$staged" -eq 1 ] && [ "$worktree" -eq 0 ]; then
        return 0
      fi
      for t in $paths; do
        is_dirty "$t" "$gitdir" 0 && add_dirty "$t"
      done
      for t in $dash_paths; do
        is_dirty "$t" "$gitdir" 1 && add_dirty "$t"
      done
      ;;
  esac
  return 0
}

# 連結演算子（&& || ; | と改行）でセグメントへ分解する。クォート内の演算子も
# 分割される既知の限界があるが、分割過多は「git がコマンド位置に来ず非発火」に
# 倒れるだけで誤ブロックにはならない。
segments="$(printf '%s\n' "$cmd" | awk '{ gsub(/&&|\|\||;|\|/, "\n"); print }')"

while IFS= read -r seg; do
  [ -n "$seg" ] || continue
  case "$seg" in
    *git*) : ;;
    *) continue ;;
  esac
  set -f
  # shellcheck disable=SC2206 # 素朴な空白トークン化（意図的。glob は set -f で抑止）
  toks=($seg)
  set +f
  analyze_segment "${toks[@]}"
done <<EOF
$segments
EOF

[ -n "$DIRTY_LIST" ] || exit 0

reason="⚠️ ff-dev-toolkit guard（未コミット変更の消失防止・警告）: 未コミット変更のあるファイルへの git checkout/restore を検出しました。
対象: $DIRTY_LIST
このまま実行すると、同じファイルに積んである未コミットの変更（本修正を含む）が巻き戻ります。
代替手段:
  1) 復元前にバックアップ: cp <file> <file>.bak （復元後に必要箇所を書き戻す）
  2) 退避で復元: git stash push -- <file> （ファイルは HEAD の状態になり、git stash pop で変更を戻せます）
意図的に未コミット変更を破棄する場合は、コマンド先頭に FF_DISCARD_UNCOMMITTED=1 を付けて再実行してください。
このガードを止める場合は環境変数 FF_DEV_TOOLKIT_SKIP_CHECKOUT_GUARD=1 を設定します。"

jq -n --arg reason "$reason" \
  '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "deny", permissionDecisionReason: $reason}}' 2>/dev/null

exit 0
