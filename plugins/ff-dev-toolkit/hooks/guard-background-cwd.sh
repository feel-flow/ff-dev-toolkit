#!/usr/bin/env bash

#
# Bash の cwd ガード（PreToolUse / Bash）。
#
# linked worktree のあるリポジトリで、先頭が**相対パスの `cd`** で始まる Bash 呼び出しを
# 再実行可能な deny で止める。それ以外の呼び出しには何も出さない（exit 0・無出力）。
#
# 止める理由: `git worktree list` が 2 本以上のツリーを返すリポジトリでは、Bash の cwd が
# 「前の呼び出しの `cd` が残っている」か「セッション cwd から始まる」かが呼び出しごとに
# 変わる。相対パスの `cd` で始まる呼び出しは、どのツリーで走るかが直前の呼び出し次第で
# 変わる確定的な取り違えで、相対パスの編集スクリプトや `npm run <script>` が**利用者の
# 稼働中ツリー**へ着弾する（導入先の実測 4 回目（2026-09-07）は書き換えが成功してしまい、
# 復旧に 4 往復 + 別コミットの巻き戻しを要した）。先頭を絶対パスの `cd` へ書き換えれば
# 直るので、エージェントへ届く唯一の止めるチャネル（`permissionDecision: "deny"` の
# `permissionDecisionReason`）で返す。兄弟ガード（`guard-checkout-restore.sh` /
# `guard-pr-followup.sh` / `guard-effort-actual.sh`）と同じ形。
#
# 止めない警告は出さない（Issue `#2614`）。以前は deny に当たらない呼び出し（`cd` を含まない
# `npm test` 等・モノレポでの background 実行）にも `systemMessage` の警告を出していたが、
# 次の 2 点で廃止した:
#   - `systemMessage` は利用者の画面にだけ出て、コマンドを書くエージェントの文脈には
#     入らない。linked worktree はデスクトップアプリがセッションごとに作るので常態に近く、
#     絶対パスの `cd` で始まらない Bash のたびに 7 行が画面へ出て、誰の行動も変えなかった
#   - `hookSpecificOutput.additionalContext` へ移す案も採らない。PreToolUse の
#     `additionalContext` はエージェントへ届く一方、Claude Code の CLI と Remote Control の
#     画面にも表示される（2026-11-04 実測。デスクトップアプリでは表示されない）。呼び出し
#     ごとに出す限り、チャネルを替えても同じ洪水になる
# 別ツリーへの着弾を実際に止めてきたのは deny 側で、警告側を消して失うのは誰も行動できない
# 表示だけ。
#
# 判定:
#   0. `tool_name` が Bash（それ以外は無音）
#   1. 先頭コマンドが相対パスの `cd` で始まる（下の「先頭コマンドの決め方」）。そうでなければ
#      git を起動せずに無音で終わる（全 Bash 呼び出しに乗る hook の通常経路を軽く保つ）
#   2. cwd の git リポジトリ root を解決できる
#      - git リポジトリでない・root を解決できない場合は fail-open（無音）
#   3. `git worktree list --porcelain` の live なレコードが 2 つ以上
#      - `$root/.git` がファイル（cwd が linked worktree の中）か `$root/.git/worktrees/`
#        があるときだけ `git worktree list` を起動する。どちらでもなければ 0 本
#      - 実体が消えた登録（`prunable` 行を持つレコード）は数えない
#      - `git worktree list` が失敗する環境では 0 本として扱い、鳴らさない（fail-open）
#   1〜3 がすべて立てば deny する。`tool_input.run_in_background` が真で、かつ repo root が
#   モノレポ（root 直下に `packages/` がある、または子ディレクトリ（root 自身を除く）に
#   `package.json` が 2 つ以上ある）なら、deny の理由文に「background の Bash はセッション
#   cwd から始まる」補足を足す。モノレポ判定の走査は `-maxdepth 3` + `node_modules` /
#   `.git` の prune + 2 件見つけた時点で打ち切り（PreToolUse の timeout は 10 秒）で、deny が
#   確定した呼び出しでだけ走らせる。
#
# 「先頭コマンド」の決め方:
#   - 先頭の `setopt <オプション名…>;`（または改行で終わる文）は cwd を変えないので読み飛ばす
#     （下の判定 1 の直前の注記）
#   - 先頭の空白・改行と、サブシェル `(` / グループ `{` の開き記号を剥がし、さらに
#     先頭の環境変数前置（`NAME=value`。名前は `[A-Za-z_][A-Za-z0-9_]*`）と `env`、
#     制御構文の前置（`do` / `then` / `else` / `elif`）を剥がしてから最初の語を見る。
#     `(cd sub && npm test) &` と `FOO=bar cd sub && ...` はどちらも `cd sub` として扱う
#   - deny へ倒す「相対パスの `cd`」は狭く取る。誤検知のコストが deny では桁違いに高いので、
#     迷ったら降りる:
#       - `cd` の引数が絶対パス（`/...`・Windows のドライブ付き `C:/x` / `C:\x`）、
#         コマンド置換（`$(...)` / `` `...` ``。リポジトリの規約が許容している
#         `cd "$(git rev-parse --show-toplevel)" && ...` を含む）、変数展開（`$VAR` /
#         `${VAR}`）、チルダ展開（`~...`）なら対象外。置換・展開の中身は hook では評価
#         できないので沈黙側へ倒す（相対に展開される変数は取りこぼす）
#       - 引数なしの `cd`（$HOME へ）、区切りや改行を挟んで引数が無い形、`cd -`（OLDPWD へ）、
#         オプションが 1 つでも付く形（`cd -P sub` を含む）は対象外
#       - 開きクォートと、引数の直前に 1 回だけ現れる `--`（`cd -- sub`）は剥がしてから見る
#       - `cd` の直後はシェルの語区切り（空白・タブ）に限る。`cd<FF>/abs` や `cd<全角空白>/abs` は
#         シェルが語全体をコマンド名と読む（`cd` ではない）ので対象外
#   - 理由文は、意図どおりのツリーで走らせたい場合の通し方を「repo root から始まる絶対パスの
#     `cd`」として示す。opt-out の環境変数はこの hook 自身の環境から読むので、コマンドへ前置しても
#     効かない。前置を促すと同じ deny の再実行か、別の起動へ変数を載せる迂回を誘う（OBS-189）
#
# 設計原則:
#   - fail-open: 全 Bash 呼び出しに割り込むため、解析不能・jq 不在・壊れた stdin では
#     黙って許可（exit 0・無出力）に倒す
#   - 互換性: bash 3.2（stock macOS）互換。連想配列・readarray・=~ は使わない
#
# 環境変数:
#   FF_DEV_TOOLKIT_SKIP=background-cwd  このガードを無効化する（鍵の名簿は scripts/lib/l4-declarations.tsv）
#     - 鍵は当初の対象（background の Bash）の名前のまま。対象を広げても鍵を足さない
#       （鍵を足すと opt-out が 2 つに割れる）

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
# 宣言の判定は共通関数 scripts/lib/l4-declarations.sh（ADR-087）。読めないときは止めない側に倒す。
# shellcheck source=../scripts/lib/l4-declarations.sh
{ [ -r "${BASH_SOURCE[0]%/*}/../scripts/lib/l4-declarations.sh" ] && . "${BASH_SOURCE[0]%/*}/../scripts/lib/l4-declarations.sh"; } 2>/dev/null || ff_l4_skipped() { return 1; }
if ff_l4_skipped 'background-cwd'; then exit 0; fi

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
# Windows の jq.exe は改行を \r\n で出す。`$(…)` が落とすのは末尾だけなので、値の区切りと
# command 内の改行に残る \r を落とす（落とさないと tool が `Bash\r` になり、ガードが
# 黙って素通りする。Issue `#2017`）。
meta="${meta//$'\r'/}"

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
# （deny の理由文へモノレポの補足を足すかどうかにだけ使う）
pop_field
bg="$FIELD"

pop_field
CWD="$FIELD"
[ -d "$CWD" ] || CWD="$(pwd)"

cmd="$meta_rest"
[ -n "$cmd" ] || exit 0

# ---- 先頭語の切り出し（共通ヘルパー） -----------------------------------------
# 空白・改行、サブシェル `(` / グループ `{` の開き記号、`env` 前置、制御構文の前置
# （`do` / `then` / `else` / `elif`）、`NAME=value` の環境変数前置を剥がしてから
# 最初の語を取る。
HEAD_CMD=""
HEAD_WORD=""
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
}

# `cd` の引数取り出し。「cd」の直後の文字列を渡すと、先頭の空白と `cd` のオプション
# （`-L` / `-P` / `-e` / `-@` とその結合形 `-LP` 等。bash 組み込み `cd` に長いオプションは
# 無いので `-` 始まりの語はすべてオプション扱い）を読み飛ばした残り（パス引数以降の文字列。
# 以降のセグメントも含む生の残余）を `CD_ARG` へ、オプションを 1 つ以上読み飛ばしたら
# `CD_HAD_OPT=1` を立てる。`--` はオプションの数には数えない。`--` はオプションの終端なので、
# 消費した時点で走査を終え、以降（`-P` のような語を含む）はそのままパス引数として `CD_ARG` に
# 残す。`cd -`（OLDPWD へ）の単独 `-` はオプションと同じ扱い（`CD_HAD_OPT=1`、`CD_ARG` は
# 残余）にする — 相対パス指定ではないので、呼び出し側は `CD_HAD_OPT` で降りればよい。
cd_arg_after_options() { # <text right after "cd">
  local s="$1" word
  CD_ARG=""
  CD_HAD_OPT=""
  while :; do
    while :; do
      case "$s" in
        " "* | "	"*) s="${s#?}" ;;
        *) break ;;
      esac
    done
    word="${s%%[[:space:]]*}"
    case "$word" in
      "--")
        s="${s#--}"
        while :; do
          case "$s" in
            " "* | "	"*) s="${s#?}" ;;
            *) break ;;
          esac
        done
        break
        ;;
      "-" | -*)
        s="${s#"$word"}"
        CD_HAD_OPT=1
        continue
        ;;
    esac
    break
  done
  CD_ARG="$s"
}

# 先頭コマンドが「相対パスの `cd`」で始まるか。deny へ倒す面はここで絞る条件そのもの。
# 引数なしの `cd`（$HOME へ行く）は対象外にする — 相対パス指定による取り違えとは別の形で、
# deny の面を必要以上に広げない。オプションが 1 つでも付く形（`cd -P sub` を含む）も
# 対象外にする（`cd -`（OLDPWD へ）の単独 `-` も同じ経路で降りる）— `cd -P /abs` を相対と
# 誤判定して deny へ巻き込まないため（誤検知のコストが高い側なので、迷ったら降りる）。
starts_with_relative_cd() {
  local s="$1" first arg word nl
  first="${s%%[[:space:]]*}"
  [ "$first" = "cd" ] || return 1
  arg="${s#cd}"
  # `cdfoo` のような別コマンドを弾く。cd の直後はシェルの語区切り（空白かタブ）でなければ
  # ならない。`[[:space:]]` で受けると、bash / zsh が `cd` と読まない `cd<FF>/abs` や
  # `cd<全角空白>/abs`（語全体がコマンド名になり rc=127）を相対 cd と読んで deny する。
  case "$arg" in
    " "* | "	"*) ;;
    *) return 1 ;;
  esac
  # 改行以降は別コマンド。`cd` と次行の間に引数は無いので、ここで切らないと
  # 次行の先頭語をパス引数と読み違える（`cd<改行>npm test` が相対 cd に化ける）。
  nl='
'
  arg="${arg%%"$nl"*}"
  cd_arg_after_options "$arg"
  [ -n "$CD_HAD_OPT" ] && return 1
  word="$CD_ARG"
  case "$word" in
    # 引数なしの cd（$HOME へ）。区切りが続く形も「パス引数が無い」側。
    "") return 1 ;;
    ";"* | "&"* | "|"* | ")"* | "}"* | "#"* | "<"* | ">"*) return 1 ;;
  esac
  # 開きクォートだけを剥がす（閉じ位置は解析しない）
  case "$word" in
    \"* | \'*) word="${word#?}" ;;
  esac
  case "$word" in
    "") return 1 ;;
    # 絶対（Windows のドライブ付きを含む。Git Bash では cd がそのまま受け付ける。
    # Issue `#2017` / `#2018`）・コマンド置換・変数展開・チルダ展開は対象外
    /* | [A-Za-z]:/* | [A-Za-z]:\\* | '$('* | '`'* | '$'* | '~'*) return 1 ;;
    *) return 0 ;;
  esac
}

# ---- 判定 1: 先頭コマンドが相対パスの cd か -------------------------------------
# 先頭の `setopt <オプション名…>;`（または改行で終わる文）は cwd を変えないので読み飛ばす。guard-zsh-glob.sh の
# 単語分割の書き換え（Issue `#2491`）が `setopt SH_WORD_SPLIT; ` を前置するため、前置後の `cd sub && …` を
# 「先頭が cd でない」と読んで取りこぼさないように。読み飛ばすのは語がオプション名だけの setopt に限る
# （引用・展開・区切り記号を含む文、setopt 以外の先頭文は従来どおり）。
case "$cmd" in
  setopt[[:space:]]*)
    setopt_stmt="${cmd%%[;${nl}]*}"
    if [ "$setopt_stmt" != "$cmd" ]; then
      case "$setopt_stmt" in
        *[!A-Za-z0-9_[:blank:]]*) : ;;
        *) cmd="${cmd#"$setopt_stmt"}"; cmd="${cmd#?}" ;;
      esac
    fi
    unset setopt_stmt
    ;;
esac
parse_head "$cmd"
head_cmd="$HEAD_CMD"

# 相対パスの cd で始まらない呼び出しは、git を起動せずにここで終える（無音）。
starts_with_relative_cd "$head_cmd" || exit 0

# ---- 判定 2: repo root の解決 ----------------------------------------------------
root="$(git -C "$CWD" rev-parse --show-toplevel 2>/dev/null)" || exit 0
[ -n "$root" ] && [ -d "$root" ] || exit 0

# ---- 判定 3: linked worktree があるか --------------------------------------------
# レコード（`worktree ` 行で始まる塊）が 2 つ以上なら main + linked が並んでいる。
# `git worktree list` が使えない環境（失敗・空出力）は 0 本として扱い、鳴らさない
# （fail-open）。
#
# 先にファイルシステムで絞る: `git worktree list` は登録本数に比例して重い。
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
[ "$worktree_count" -ge 2 ] || exit 0

# ---- 理由文の補足: background × モノレポ（浅く速く。見つけた時点で打ち切る） ----------
# deny が確定した background 呼び出しでだけ走らせる。
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

# ---- deny ------------------------------------------------------------------------
# ラベルは「拒否」と名乗る。理由文の中で「ブロックしません／そのまま実行して構いません」と
# 自称すると、読んだエージェントは「止まっていない」と解釈して同じ呼び出しを再実行する。
reason="🛑 ff-dev-toolkit guard（Bash の cwd・拒否）: このリポジトリには linked worktree があります（合計 ${worktree_count} 本のツリー）。どのツリーで走るかを固定するため、コマンドの先頭で絶対パスの cd を書いてください。
Bash の cwd は「前の呼び出しの cd が残っている」か「セッション cwd から始まる」かが呼び出しごとに変わります。相対パスの編集や npm run が、利用者の稼働中のツリーへ着弾することがあります（現在の cwd の repo root: ${root}）。
  例: cd ${root}/path/to/dir && npm test
  リポジトリ規約どおり cd \"\$(git rev-parse --show-toplevel)\" のようにその場で絶対化する形も可です。"
if [ "$is_monorepo" -eq 1 ]; then
  reason="${reason}
加えてこのリポジトリはモノレポで、background の Bash は直前の foreground 呼び出しの cd を引き継がずセッション cwd から始まります。パッケージ配下で実行するつもりなら、無関係なパッケージの結果を自分の変更の赤として読む前に絶対パスの cd を書いてください。"
fi
reason="${reason}

この呼び出しは先頭が相対パスの cd なので、どのツリーで走るかが直前の呼び出し次第で変わります。
**この呼び出しはブロックしました。** 先頭を絶対パスの cd へ書き換えて再実行してください（上の例を参照）。
このツリー（${root}）で走らせるのが意図どおりなら、${root} から始まる絶対パスで cd を書けば通ります（このガードの無効化は利用者の設定の環境変数 FF_DEV_TOOLKIT_SKIP=background-cwd で行うもので、コマンドの前置では効きません）。"
jq -n --arg reason "$reason" \
  '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "deny", permissionDecisionReason: $reason}}' 2>/dev/null

exit 0
