#!/usr/bin/env bash
#
# background Bash の cwd ガード（PreToolUse / Bash）。
#
# モノレポで `run_in_background: true` の Bash を起動するとき、先頭が絶対パスの
# `cd` でなければ警告する。background の Bash は直前の foreground 呼び出しの `cd` を
# 引き継がず**セッション cwd（worktree root）から始まる**ため、パッケージ配下で
# 走らせたつもりのテストが root で走り、無関係な失敗を「自分の変更の赤」として
# 読む手戻りになる（導入先の観測台帳で同一クラスを 3 回実測）。
#
# 出力は exit 0 + `systemMessage` の**警告のみ**で、コマンドはブロックしない。
# 同じ PreToolUse でも `guard-checkout-restore.sh` / `guard-pr-followup.sh` が
# 抜け道付き deny を選んでいるのは「実行させると失うものがある」ためで、本ガードは
# 誤警告のコストのほうが大きい（起動が止まるより、読み飛ばせる 1 行のほうが安い）。
# 受け入れ条件もブロックしない警告を要求しているため、deny 側へは倒さない。
#
# 既知の限界: `systemMessage` は利用者向けの表示チャネルで、エージェントのコンテキストには
# 入らない。この警告を読んで先頭に cd を書き足すのは人間であってエージェントではない。
# PreToolUse にエージェント可視の警告チャネル（`additionalContext`）が無いという制約は
# 上記 2 本のガードのヘッダーに記録済みで、本ガードでも変わっていない。それらが
# 抜け道付き deny でエージェントへ届かせているのに対し、本ガードは誤警告の頻度が高い側
# なので、届かないことを承知で表示のみに留める。
#
# 判定（すべて満たしたときだけ警告する）:
#   1. `tool_name` が Bash で、`tool_input.run_in_background` が真
#      - このキーが入力に無いハーネス（Codex 等）では判定材料が無いので無音
#   2. cwd の git リポジトリ root がモノレポ
#      - root 直下に `packages/` がある、または子ディレクトリ（root 自身を除く）に
#        `package.json` が 2 つ以上ある。走査は `-maxdepth 3` + `node_modules` /
#        `.git` の prune + 2 件見つけた時点で打ち切り（PreToolUse の timeout は 10 秒）
#      - git リポジトリでない・root を解決できない場合は fail-open（無音）
#   3. 先頭コマンドが「絶対パスへの `cd`」で始まらない
#
# 「先頭コマンド」の決め方と、絶対化イディオムの扱い（誤警告を出さないための線引き）:
#   - 先頭の空白・改行と、サブシェル `(` / グループ `{` の開き記号を剥がし、さらに
#     先頭の環境変数前置（`NAME=value`。名前は `[A-Za-z_][A-Za-z0-9_]*`）と `env` を
#     剥がしてから最初の語を見る。`(cd /abs && npm test) &` は `cd /abs`、
#     `FOO=bar cd /abs && ...` は `cd /abs` として扱う
#   - 最初の語が `cd` でなくても、次のいずれかなら無音にする:
#       絶対パスの実行          第 1 語（`/abs/bin/x`）か、その直後の第 1 引数
#                              （`bash /abs/script.sh`）が絶対パス。cwd に依存しない
#       cwd 非依存の allowlist  `gh` / `sleep` / `git` / `until` / `while` / `for`
#     allowlist の理由: background Bash の主要用途は CI 待ちと PR のポーリング
#     （`gh pr checks --watch` / `until gh ...; do sleep 30; done`）で、どの cwd から
#     走らせても結果が変わらない。`git` も同じくリポジトリ単位で動く。モノレポでは
#     これらが毎回鳴り、警告そのものが読み飛ばされるようになるため黙る
#   - それ以外で最初の語が `cd` でなければ警告する（`npm test` 等。これが主な発火ケース）
#   - `cd` の引数が次のいずれかなら「絶対」とみなして無音にする。開きクォートと、
#     引数の直前に 1 回だけ現れる `--`（`cd -- /abs`）は剥がす:
#       `/...`                絶対パス
#       `$(...)` / `` `...` `` コマンド置換。リポジトリの規約が許容している
#                             `cd "$(git rev-parse --show-toplevel)" && ...` を含む
#       `$VAR` / `${VAR}`     変数展開（`$CLAUDE_PROJECT_DIR` 等）
#       `~...`                チルダ展開
#     置換・展開の中身は hook では評価できない。ここで警告すると規約どおりに絶対化した
#     呼び出しまで毎回鳴り、警告そのものが読み飛ばされるようになるため、評価できない形は
#     沈黙側へ倒す。取りこぼす（相対に展開される変数）ことは許容する
#   - `cd packages/app && ...` のような、hook から見て明らかに相対な `cd` は警告する
#   - 残る既知の誤警告: 第 1 語が cwd 非依存で、絶対化がオプション側にある形
#     （`npm --prefix /abs/x test` / `make -C /abs/x`）は警告側に落ちる。ツールごとの
#     オプション解析を hook に持ち込むと維持できないため、線引きは第 1 語までに留める
#
# 設計原則:
#   - fail-open: 全 Bash 呼び出しに割り込むため、解析不能・jq 不在・壊れた stdin では
#     黙って許可（exit 0・無出力）に倒す
#   - 互換性: bash 3.2（stock macOS）互換。連想配列・readarray・=~ は使わない
#
# 環境変数:
#   FF_DEV_TOOLKIT_SKIP_BACKGROUND_CWD_GUARD=1  このガードを無効化する

# fail-open のため set -e / set -u は使わない。

# stdin は bash 組み込みの read で読み切る（外部コマンドに依存しない）。`cat` だと PATH が
# 空・壊れた環境で command not found → stdin 未読のまま exit 0 となり、書き手（ホスト /
# テストの printf）が EPIPE / SIGPIPE を受ける（Issue #1329。pipefail 下の suite では
# hook の exit 0 ではなく書き手の rc=141 が観測される）。fail-open の「黙って許可」は
# 「stdin を読み切ったうえで」成立させる。-d '' は NUL まで（JSON には無いので EOF まで）
# 読み、EOF では非 0 を返すが input には内容が入っている。
input=""
IFS= read -r -d '' input || true

# opt-out も stdin を読み切ってから抜ける（drain 前に exit すると同じ EPIPE を書き手へ返す）。
[ "${FF_DEV_TOOLKIT_SKIP_BACKGROUND_CWD_GUARD:-0}" = "1" ] && exit 0

# 安価な前置フィルタ: 判定キーを持たない入力は即終了
case "$input" in
  *run_in_background*) : ;;
  *) exit 0 ;;
esac

command -v jq >/dev/null 2>&1 || exit 0

tool="$(printf '%s' "$input" | jq -r '.tool_name // ""' 2>/dev/null)" || exit 0
[ "$tool" = "Bash" ] || exit 0

# 真のときだけ "true"。false・欠落・非 boolean はいずれも空文字になる
bg="$(printf '%s' "$input" | jq -r 'if (.tool_input.run_in_background // false) == true then "true" else "" end' 2>/dev/null)" || exit 0
[ "$bg" = "true" ] || exit 0

cmd="$(printf '%s' "$input" | jq -r '.tool_input.command // ""' 2>/dev/null)" || exit 0
[ -n "$cmd" ] || exit 0

CWD="$(printf '%s' "$input" | jq -r '.cwd // ""' 2>/dev/null)"
[ -d "$CWD" ] || CWD="$(pwd)"

# ---- 先頭コマンドが絶対パスの cd か -------------------------------------------
head_cmd="$cmd"
head_word=""
while :; do
  case "$head_cmd" in
    [[:space:]]*) head_cmd="${head_cmd#?}"; continue ;;
    "("*) head_cmd="${head_cmd#?}"; continue ;;
    "{"*) head_cmd="${head_cmd#?}"; continue ;;
  esac
  head_word="${head_cmd%%[[:space:]]*}"
  # `env` 前置を剥がす
  if [ "$head_word" = "env" ]; then
    head_cmd="${head_cmd#env}"
    continue
  fi
  # `NAME=value` 形式の環境変数前置を剥がす（名前が識別子のときだけ）
  case "$head_word" in
    [A-Za-z_]*=*)
      case "${head_word%%=*}" in
        *[!A-Za-z0-9_]*) ;;
        *)
          head_cmd="${head_cmd#"$head_word"}"
          continue
          ;;
      esac
      ;;
  esac
  break
done

# 第 1 語、またはその直後の第 1 引数が絶対パスなら cwd に依存しないので無音
# （`/abs/bin/x` / `bash /abs/script.sh`）
case "$head_word" in
  /*) exit 0 ;;
esac
head_rest="${head_cmd#"$head_word"}"
while :; do
  case "$head_rest" in
    [[:space:]]*) head_rest="${head_rest#?}" ;;
    *) break ;;
  esac
done
case "$head_rest" in
  /*) exit 0 ;;
esac

# cwd 非依存の allowlist（CI 待ち・PR ポーリングが background Bash の主要用途）
case "$head_word" in
  gh | sleep | git | until | while | for) exit 0 ;;
esac

starts_with_absolute_cd() {
  local s="$1" first arg
  first="${s%%[[:space:]]*}"
  [ "$first" = "cd" ] || return 1
  arg="${s#cd}"
  while :; do
    case "$arg" in
      [[:space:]]*) arg="${arg#?}" ;;
      *) break ;;
    esac
  done
  # 引数直前の `--` を 1 回だけ落とす（`cd -- /abs`。`--foo` は落とさない）
  case "$arg" in
    "--") arg="" ;;
    "--"[[:space:]]*)
      arg="${arg#--}"
      while :; do
        case "$arg" in
          [[:space:]]*) arg="${arg#?}" ;;
          *) break ;;
        esac
      done
      ;;
  esac
  # 開きクォートだけを剥がす（閉じ位置は解析しない）
  case "$arg" in
    \"* | \'*) arg="${arg#?}" ;;
  esac
  case "$arg" in
    /*) return 0 ;;                # 絶対パス
    '$('* | '`'*) return 0 ;;      # コマンド置換（git rev-parse --show-toplevel 等）
    '$'* | '~'*) return 0 ;;       # 変数展開・チルダ展開（hook では評価できない）
    *) return 1 ;;
  esac
}

starts_with_absolute_cd "$head_cmd" && exit 0

# ---- モノレポ判定（浅く速く。見つけた時点で打ち切る） --------------------------
root="$(git -C "$CWD" rev-parse --show-toplevel 2>/dev/null)" || exit 0
[ -n "$root" ] && [ -d "$root" ] || exit 0

is_monorepo=0
if [ -d "$root/packages" ]; then
  is_monorepo=1
else
  # root 自身の package.json は「子ディレクトリの 2 つ以上」に数えない
  found="$(find "$root" -maxdepth 3 \( -name node_modules -o -name .git \) -prune -o \
    -name package.json -type f -print 2>/dev/null |
    grep -v -x -F "$root/package.json" | head -n 2 | wc -l | tr -d '[:space:]')"
  case "$found" in
    '' | *[!0-9]*) found=0 ;;
  esac
  [ "$found" -ge 2 ] && is_monorepo=1
fi
[ "$is_monorepo" -eq 1 ] || exit 0

message="⚠️ ff-dev-toolkit guard（background Bash の cwd・警告）: モノレポで background の Bash を起動しますが、コマンドの先頭が絶対パスの cd ではありません。
background の Bash は直前の foreground 呼び出しの cd を引き継がず、セッション cwd（worktree root: ${root}）から始まります。パッケージ配下で実行するつもりなら、無関係なパッケージの結果を自分の変更の赤として読む前に、先頭で絶対パスの cd を書いてください。
  例: cd ${root}/packages/<pkg> && npm test
  リポジトリ規約どおり cd \"\$(git rev-parse --show-toplevel)\" のようにその場で絶対化する形も可です。
worktree root で走らせるのが意図どおりなら、そのまま実行して構いません（この警告はブロックしません）。
このガードを止める場合は環境変数 FF_DEV_TOOLKIT_SKIP_BACKGROUND_CWD_GUARD=1 を設定します。"

jq -n --arg m "$message" '{systemMessage: $m}' 2>/dev/null

exit 0
