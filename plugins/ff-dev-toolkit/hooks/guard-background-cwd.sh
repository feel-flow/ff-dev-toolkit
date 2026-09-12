#!/usr/bin/env bash

#
# Bash の cwd ガード（PreToolUse / Bash）。
#
# 先頭が絶対パスの `cd` でない Bash 呼び出しを、次の 2 経路のいずれかに当たるときだけ警告する。
#
#   経路 A（background × モノレポ）: モノレポで `run_in_background: true` の Bash を起動する
#     とき。background の Bash は直前の foreground 呼び出しの `cd` を引き継がず**セッション
#     cwd（worktree root）から始まる**ため、パッケージ配下で走らせたつもりのテストが root で
#     走り、無関係な失敗を「自分の変更の赤」として読む手戻りになる（導入先の観測台帳で同一
#     クラスを 3 回実測）。
#   経路 B（linked worktree あり）: `git worktree list` が 2 本以上のツリーを返すリポジトリ。
#     foreground でも警告する。Bash の cwd は「前の呼び出しの `cd` が残っている」か
#     「セッション cwd から始まる」かが呼び出しごとに変わるため、相対パスの編集スクリプトや
#     `npm run <script>` が**利用者の稼働中ツリー**へ着弾する。実測 4 回目（2026-09-07）は
#     書き換えが成功してしまい、復旧に 4 往復 + 別コミットの巻き戻しを要した。1〜3 回目は
#     即座に失敗する（0 件 / 404 / AssertionError）ため安いが、4 回目は実害。
#
# 経路 B を「絶対パスの `cd` で始まらない Bash 全般」まで広げない理由: linked worktree が
# 無く単一パッケージのリポジトリでは、cwd 残留で解決される `npm run <script>` は圧倒的多数が
# 意図どおりに動く。そこまで広げると誤警告が常態化して警告そのものが読み飛ばされ、経路 A / B
# の実害ケースまで無効化する。worktree の本数は「どのツリーで走るかが曖昧になっている」ことの
# 機械的な証拠なので、そこを発火の線とする。
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
# 判定:
#   0. `tool_name` が Bash（それ以外は無音）
#   1. 先頭コマンドが「絶対パスへの `cd`」で始まらない（両経路の共通前提）
#   2. cwd の git リポジトリ root を解決できる
#      - git リポジトリでない・root を解決できない場合は fail-open（無音）
#   3. 経路 B: `git worktree list --porcelain` の live なレコードが 2 つ以上
#      - `$root/.git` がファイル（cwd が linked worktree の中）か `$root/.git/worktrees/`
#        があるときだけ `git worktree list` を起動する。どちらでもなければ 0 本
#      - 実体が消えた登録（`prunable` 行を持つレコード）は数えない
#      - `git worktree list` が失敗する環境では 0 本として扱い、この経路では鳴らさない
#        （fail-open）
#   4. 経路 A: `tool_input.run_in_background` が真、かつ repo root がモノレポ
#      - `run_in_background` が入力に無いハーネス（Codex 等）では偽として扱う
#      - モノレポ = root 直下に `packages/` がある、または子ディレクトリ（root 自身を除く）に
#        `package.json` が 2 つ以上ある。走査は `-maxdepth 3` + `node_modules` /
#        `.git` の prune + 2 件見つけた時点で打ち切り（PreToolUse の timeout は 10 秒）。
#        foreground では走らせない（全 Bash 呼び出しに割り込むため）
#   3 と 4 のどちらかが立てば警告する（両方立てば経路 B の文面に経路 A の補足を足す）
#
# 「先頭コマンド」の決め方と、絶対化イディオムの扱い（誤警告を出さないための線引き）:
#   判定は 1 → 2 → 3 の順に見て、どこかで無音が立てばそこで終わる。
#   1. コマンド全体の先頭が絶対パスの `cd`（以降のセグメントも同じツリーで走る）
#   2. heredoc（`bash -e <<'EOF' … EOF`）なら**本文の最初の実効行**を 1 と同じ判定に通す
#   3. 演算子（`&&` / `||` / `|` / `;` / 改行）で分割した**各セグメント**の先頭語が
#      cwd 非依存か。1 つでも該当しなければ警告側
#
#   - 先頭の空白・改行と、サブシェル `(` / グループ `{` の開き記号を剥がし、さらに
#     先頭の環境変数前置（`NAME=value`。名前は `[A-Za-z_][A-Za-z0-9_]*`）と `env`、
#     制御構文の前置（`do` / `then` / `else` / `elif`）を剥がしてから最初の語を見る。
#     `(cd /abs && npm test) &` は `cd /abs`、`FOO=bar cd /abs && ...` は `cd /abs`、
#     `until gh ...; do sleep 30; done` の `do sleep 30` は `sleep` として扱う
#   - 最初の語が `cd` でなくても、次のいずれかならそのセグメントを cwd 非依存とみなす:
#       絶対パスの実行          第 1 語（`/abs/bin/x`）か、その直後の第 1 引数
#                              （`bash /abs/script.sh`）が絶対パス。cwd に依存しない
#       cwd 非依存の allowlist  `gh` / `sleep` / `git` / `until` / `while` / `for` と、
#                              相対パスでは書き込めない読み取り専用の head
#                              （`echo` / `printf` / `cat` / `ls` / `jq` / `head` /
#                              `tail` / `wc` / `date` / `command` / `which` / `:` /
#                              `true` / `grep`、および `sed -n`。`sed -i` は除く）
#     allowlist の理由: background Bash の主要用途は CI 待ちと PR のポーリング
#     （`gh pr checks --watch` / `until gh ...; do sleep 30; done`）で、どの cwd から
#     走らせても結果が変わらない。`git` も同じくリポジトリ単位で動く。読み取り専用の
#     head も、どのツリーで走っても**壊れない**（読む対象が変わるだけ）。モノレポや
#     worktree のあるリポジトリではこれらが毎回鳴り、警告そのものが読み飛ばされる
#     ようになるため黙る
#   - allowlist は**セグメント単位**で見る。先頭語だけを見て無音にすると
#     `git status && npm test` / `gh pr view | npm test` が素通りするため、
#     1 つでも cwd 依存のセグメントがあれば警告する
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
#     オプション解析を hook に持ち込むと維持できないため、線引きは第 1 語までに留める。
#     セグメント分割はクォート状態を解釈しない。クォート内の演算子も区切りとして数えるため
#     `echo 'a|b'` は `echo 'a` / `b'` に割れて警告側に落ちる（本ガードは警告のみで
#     ブロックしないので、非対称は警告側へ倒し、分割器にクォート状態を持ち込まない）
#   - リダイレクト（`echo x > file`）は解析しない。allowlist は head だけを見るという
#     上の線引きと同じ理由で、リダイレクト先の相対パスまでは追わない
#
# 設計原則:
#   - fail-open: 全 Bash 呼び出しに割り込むため、解析不能・jq 不在・壊れた stdin では
#     黙って許可（exit 0・無出力）に倒す
#   - 互換性: bash 3.2（stock macOS）互換。連想配列・readarray・=~ は使わない
#
# 環境変数:
#   FF_DEV_TOOLKIT_SKIP_BACKGROUND_CWD_GUARD=1  このガードを無効化する
#     - 経路 B を足して foreground も対象になったが、既に設定している利用者の opt-out を
#       壊さないため名前は変えない（別名を足すと opt-out が 2 つに割れる）

# fail-open のため set -e / set -u は使わない。

# stdin は bash 組み込みの read で読み切る（外部コマンドに依存しない）。`cat` だと PATH が
# 空・壊れた環境で command not found → stdin 未読のまま exit 0 となり、書き手（ホスト /
# テストの printf）が EPIPE / SIGPIPE を受ける（Issue #1329。pipefail 下の suite では
# hook の exit 0 ではなく書き手の rc=141 が観測される）。fail-open の「黙って許可」は
# 「stdin を読み切ったうえで」成立させる。-d '' は NUL まで（JSON には無いので EOF まで）
# 読み、EOF では非 0 を返すが input には内容が入っている。
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

# opt-out も stdin を読み切ってから抜ける（drain 前に exit すると同じ EPIPE を書き手へ返す）。
[ "${FF_DEV_TOOLKIT_SKIP_BACKGROUND_CWD_GUARD:-0}" = "1" ] && exit 0

# 安価な前置フィルタ: Bash 以外の入力は即終了（`tool_name` の値を素の文字列で見るだけ）
case "$input" in
  *'"Bash"'*) : ;;
  *) exit 0 ;;
esac

command -v jq >/dev/null 2>&1 || exit 0

nl='
'

# 必要な 4 フィールドを 1 回の jq で取り出す。jq の起動は 1 回あたり実測 3〜4 ms で、
# PreToolUse は全 Bash 呼び出しに乗るため 4 回起動はそのまま体感コストになる。
# 行区切りで受け取り、改行を含み得る `command` を最後に置いて「残り全部」として拾う。
meta="$(printf '%s' "$input" | jq -r '
  (.tool_name // ""),
  (if (.tool_input.run_in_background // false) == true then "true" else "" end),
  (.cwd // ""),
  (.tool_input.command // "")' 2>/dev/null)" || exit 0

meta_rest="$meta"
FIELD=""
pop_field() {
  case "$meta_rest" in
    *"$nl"*)
      FIELD="${meta_rest%%"$nl"*}"
      meta_rest="${meta_rest#*"$nl"}"
      ;;
    *)
      FIELD="$meta_rest"
      meta_rest=""
      ;;
  esac
}

pop_field
tool="$FIELD"
[ "$tool" = "Bash" ] || exit 0

# 真のときだけ "true"。false・欠落・非 boolean はいずれも空文字になる
# （経路 A の条件。ここでは exit せず、経路 B（linked worktree）の判定へ進む）
pop_field
bg="$FIELD"

pop_field
CWD="$FIELD"
[ -d "$CWD" ] || CWD="$(pwd)"

cmd="$meta_rest"
[ -n "$cmd" ] || exit 0

# ---- 先頭語の切り出し（共通ヘルパー） -----------------------------------------
# 空白・改行、サブシェル `(` / グループ `{` の開き記号、`env` 前置、制御構文の前置
# （`do` / `then` / `else` / `elif`。複合コマンドを分割すると各セグメントの先頭に残る）、
# `NAME=value` の環境変数前置を剥がしてから最初の語を取る。
HEAD_CMD=""
HEAD_WORD=""
HEAD_REST=""
parse_head() { # <command string>
  local s="$1" w=""
  while :; do
    case "$s" in
      [[:space:]]*) s="${s#?}"; continue ;;
      "("*) s="${s#?}"; continue ;;
      "{"*) s="${s#?}"; continue ;;
    esac
    w="${s%%[[:space:]]*}"
    case "$w" in
      env | do | then | else | elif)
        s="${s#"$w"}"
        continue
        ;;
    esac
    case "$w" in
      [A-Za-z_]*=*)
        case "${w%%=*}" in
          *[!A-Za-z0-9_]*) ;;
          *)
            s="${s#"$w"}"
            continue
            ;;
        esac
        ;;
    esac
    break
  done
  HEAD_CMD="$s"
  HEAD_WORD="$w"
  HEAD_REST="${s#"$w"}"
  while :; do
    case "$HEAD_REST" in
      [[:space:]]*) HEAD_REST="${HEAD_REST#?}" ;;
      *) break ;;
    esac
  done
}

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

# cwd 非依存のセグメントか（複合コマンドの 1 区間、または単独コマンド全体）
segment_is_cwd_independent() { # <segment>
  parse_head "$1"
  case "$HEAD_WORD" in
    # 空セグメントと、分割で残る制御構文の閉じ
    "" | "done" | "fi" | "esac" | "}" | ")") return 0 ;;
    /*) return 0 ;; # 絶対パスの実行（`/abs/bin/x`）
  esac
  # 第 1 引数が絶対パス（`bash /abs/script.sh`）
  case "$HEAD_REST" in
    /*) return 0 ;;
  esac
  starts_with_absolute_cd "$HEAD_CMD" && return 0
  case "$HEAD_WORD" in
    gh | sleep | git | until | while | for) return 0 ;;
    # 相対パスでは書き込めない読み取り専用の head（誤警告の主因だった側）
    echo | printf | cat | ls | jq | head | tail | wc | date | command | which | : | true | grep) return 0 ;;
    # `sed -n` は読み取り専用。`sed -i` は書き込むので黙らない
    sed)
      case "$HEAD_REST" in
        -n | -n[[:space:]]*) return 0 ;;
      esac
      ;;
  esac
  return 1
}

# ---- 判定 1: コマンド全体の先頭が絶対パスの cd か -------------------------------
# 以降のセグメントも同じツリーで走るので、ここで無音にする。
parse_head "$cmd"
head_cmd="$HEAD_CMD"
head_word="$HEAD_WORD"

starts_with_absolute_cd "$head_cmd" && exit 0

# ---- 判定 2: heredoc の本文で判定する -------------------------------------------
# リポジトリ規約（状態を変える複数行の手順は `bash -e <<'EOF' … EOF` で渡す）に沿った
# 呼び出しは、ラッパー行（`bash -e <<'EOF'`）だけを見ると必ず「先頭が cd でない」に
# 落ちて毎回鳴る。規約準拠の手順が全部警告される状態は、警告そのものを読み飛ばさせる。
# そこで先頭語がシェル / インタプリタで heredoc を開いているときは、**本文の最初の実効行**
# を判定 1 と同じ `starts_with_absolute_cd` に通す。cwd を変えない行（空行・コメント・
# `NAME=value` の代入・`set` / `export`）は読み飛ばす。`ROOT="$(git rev-parse --show-toplevel)"`
# の次の行が `cd "$ROOT"` という規約どおりの形もこれで無音になる。
# heredoc 本文は「コマンドの並び」ではないので、判定 3 のセグメント分割からは外す。
case "$head_cmd" in
  *"$nl"*)
    heredoc_first_line="${head_cmd%%"$nl"*}"
    heredoc_body="${head_cmd#*"$nl"}"
    ;;
  *)
    heredoc_first_line="$head_cmd"
    heredoc_body=""
    ;;
esac
scan_target="$head_cmd"
case "$heredoc_first_line" in
  *'<<'*)
    scan_target="$heredoc_first_line"
    case "$head_word" in
      bash | sh | zsh | ksh | dash | python3 | python | node | perl | ruby | awk)
        body_line=""
        while [ -n "$heredoc_body" ]; do
          case "$heredoc_body" in
            *"$nl"*)
              body_line="${heredoc_body%%"$nl"*}"
              heredoc_body="${heredoc_body#*"$nl"}"
              ;;
            *)
              body_line="$heredoc_body"
              heredoc_body=""
              ;;
          esac
          while :; do
            case "$body_line" in
              [[:space:]]*) body_line="${body_line#?}" ;;
              *) break ;;
            esac
          done
          [ -n "$body_line" ] || continue
          body_word="${body_line%%[[:space:]]*}"
          case "$body_word" in
            '#'*)
              body_line=""
              continue
              ;;
            set | export)
              body_line=""
              continue
              ;;
            [A-Za-z_]*=*)
              case "${body_word%%=*}" in
                *[!A-Za-z0-9_]*) ;;
                *)
                  body_line=""
                  continue
                  ;;
              esac
              ;;
          esac
          break
        done
        if [ -n "$body_line" ]; then
          starts_with_absolute_cd "$body_line" && exit 0
        fi
        ;;
    esac
    ;;
esac

# ---- 判定 3: 各セグメントの先頭語が cwd 非依存か --------------------------------
# 先頭語だけを見て無音にすると `git status && npm test` のような複合コマンドが
# allowlist を素通りする。演算子（`&&` / `||` / `|` / `;` / 改行）で分割し、1 つでも
# cwd 依存のセグメントがあれば警告側に倒す。
# 既知の限界: クォート状態は解釈しないので、クォート内の演算子も区切りとして数える
# （`echo 'a|b'` は `echo 'a` / `b'` に割れて警告側に落ちる）。ガードは警告のみなので
# 非対称は警告側へ倒す。
seg_src="$scan_target"
seg_src="${seg_src//&&/$nl}"
seg_src="${seg_src//||/$nl}"
seg_src="${seg_src//|/$nl}"
seg_src="${seg_src//;/$nl}"
all_cwd_independent=1
while IFS= read -r seg; do
  segment_is_cwd_independent "$seg" && continue
  all_cwd_independent=0
  break
done <<< "$seg_src"
[ "$all_cwd_independent" -eq 1 ] && exit 0

# ---- repo root の解決（両経路の共通前提） --------------------------------------
root="$(git -C "$CWD" rev-parse --show-toplevel 2>/dev/null)" || exit 0
[ -n "$root" ] && [ -d "$root" ] || exit 0

# ---- 経路 B: linked worktree があるか ------------------------------------------
# レコード（`worktree ` 行で始まる塊）が 2 つ以上なら main + linked が並んでいる。
# `git worktree list` が使えない環境（失敗・空出力）は 0 本として扱い、この経路では
# 鳴らさない（fail-open）。
#
# 先にファイルシステムで絞る: `git worktree list` は登録本数に比例して重く（実測で
# このガードの支配的コスト）、PreToolUse は全 foreground Bash 呼び出しに乗る。
# linked worktree があり得るのは次のどちらかだけなので、それ以外は git を起動しない。
#   - `$root/.git` がファイル … cwd 自体が linked worktree の中にある
#   - `$root/.git/worktrees/` がディレクトリ … main tree 側に登録がある
#
# 実体が消えた登録（`prunable` 行を持つレコード）は live と数えない。`rm -rf` しただけで
# `git worktree prune` を打っていないツリーが残っているだけの repo は、実際には
# 「どのツリーで走るか」が曖昧ではないため鳴らす理由が無い。
worktree_count=0
if [ -f "$root/.git" ] || [ -d "$root/.git/worktrees" ]; then
  wt_list="$(git -C "$CWD" worktree list --porcelain 2>/dev/null)" || wt_list=""
  if [ -n "$wt_list" ]; then
    wt_in_record=0
    wt_prunable=0
    while IFS= read -r wt_line; do
      case "$wt_line" in
        "worktree "*)
          if [ "$wt_in_record" -eq 1 ] && [ "$wt_prunable" -eq 0 ]; then
            worktree_count=$((worktree_count + 1))
          fi
          wt_in_record=1
          wt_prunable=0
          ;;
        prunable*)
          if [ "$wt_in_record" -eq 1 ]; then
            wt_prunable=1
          fi
          ;;
      esac
    done <<< "$wt_list"
    if [ "$wt_in_record" -eq 1 ] && [ "$wt_prunable" -eq 0 ]; then
      worktree_count=$((worktree_count + 1))
    fi
  fi
fi
has_linked_worktree=0
[ "$worktree_count" -ge 2 ] && has_linked_worktree=1

# ---- 経路 A: モノレポ判定（浅く速く。見つけた時点で打ち切る） --------------------
# background のときだけ走らせる（find は全 foreground Bash 呼び出しに乗せるには重い）。
is_monorepo=0
if [ "$bg" = "true" ]; then
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
fi

message=""
if [ "$has_linked_worktree" -eq 1 ]; then
  message="⚠️ ff-dev-toolkit guard（Bash の cwd・警告）: このリポジトリには linked worktree があります（合計 ${worktree_count} 本のツリー）。どのツリーで走るかを固定するため、コマンドの先頭で絶対パスの cd を書いてください。
Bash の cwd は「前の呼び出しの cd が残っている」か「セッション cwd から始まる」かが呼び出しごとに変わります。相対パスの編集や npm run が、利用者の稼働中のツリーへ着弾することがあります（現在の cwd の repo root: ${root}）。
  例: cd ${root}/path/to/dir && npm test
  リポジトリ規約どおり cd \"\$(git rev-parse --show-toplevel)\" のようにその場で絶対化する形も可です。"
  if [ "$is_monorepo" -eq 1 ]; then
    message="${message}
加えてこのリポジトリはモノレポで、background の Bash は直前の foreground 呼び出しの cd を引き継がずセッション cwd から始まります。パッケージ配下で実行するつもりなら、無関係なパッケージの結果を自分の変更の赤として読む前に絶対パスの cd を書いてください。"
  fi
  message="${message}
このツリーで走らせるのが意図どおりなら、そのまま実行して構いません（この警告はブロックしません）。
このガードを止める場合は環境変数 FF_DEV_TOOLKIT_SKIP_BACKGROUND_CWD_GUARD=1 を設定します。"
elif [ "$is_monorepo" -eq 1 ]; then
  message="⚠️ ff-dev-toolkit guard（background Bash の cwd・警告）: モノレポで background の Bash を起動しますが、コマンドの先頭が絶対パスの cd ではありません。
background の Bash は直前の foreground 呼び出しの cd を引き継がず、セッション cwd（worktree root: ${root}）から始まります。パッケージ配下で実行するつもりなら、無関係なパッケージの結果を自分の変更の赤として読む前に、先頭で絶対パスの cd を書いてください。
  例: cd ${root}/packages/<pkg> && npm test
  リポジトリ規約どおり cd \"\$(git rev-parse --show-toplevel)\" のようにその場で絶対化する形も可です。
worktree root で走らせるのが意図どおりなら、そのまま実行して構いません（この警告はブロックしません）。
このガードを止める場合は環境変数 FF_DEV_TOOLKIT_SKIP_BACKGROUND_CWD_GUARD=1 を設定します。"
else
  exit 0
fi

jq -n --arg m "$message" '{systemMessage: $m}' 2>/dev/null

exit 0
