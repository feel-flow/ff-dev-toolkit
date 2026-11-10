#!/usr/bin/env bash

#
# zsh で必ず NOMATCH になる未引用 glob（`--flag=<glob>` 形・URL のクエリ文字列の形）を実行前に止めるガード
# （PreToolUse / Bash、Issue `#1774` / 公開 https://github.com/feel-flow/ff-dev-toolkit/issues/118。導入先の観測台帳
# hearing-realtime OBS-135 — Count 21 / jbta-hp OBS-028）。
#
# ## なぜ呼び出し面に置くのか
#
# zsh は既定で `NOMATCH` が有効なので、マッチ 0 件の未引用 glob を含むコマンドは
# **実行されない**（実測: `zsh -fc 'echo --a=*; echo after'` は rc=1 で after も出ない。
# Claude Code の Bash ツールと同じ `eval` 経由でも、その呼び出しの残りは走らない）。`grep -rn x docs --include=*.md` の `--include=*.md` は語全体が
# 1 つの glob として評価され、「`--include=` で始まるファイル名」を探しにいくので、
# cwd に `.md` があってもなくても 0 件になる（`--include=` で始まる名前のファイルが実在しない限り
# **必ず**。そういう名前のファイルは通常の作業ツリーに無い）（bash は 0 件の glob を語のまま
# 残すので通る）。手前のコマンドだけが走った状態で中断されるので、走査が静かに欠ける。
#
# 導入先は追跡ファイルの静的検査を実測して「入れない」と決着している（真陽性 0）—
# この壊れ方は zsh で実行される Bash ツール呼び出しに固有で、追跡下の shell スクリプトは
# bash / sh で書かれているからである。届くのは Bash ツールへ渡す文字列そのもので、
# そこは PreToolUse の担当範囲になる。文言（CLAUDE.md の規律）での対策は導入先で 6 回以上
# 再発しており上限に達している。
#
# ## 判定規則はこの hook に置かない
#
# どの語を NOMATCH と断定するかの述語・glob として評価されない文脈（引用・展開結果・
# `case` パターン・`[[ ]]`・`noglob`・コメント）の扱いは、共有ヘルパ
# `tests/lib/zsh-glob-nomatch.sh` が正本（OBS-225: 判定本体を最初から共有ライブラリへ
# 置く）。この hook が持つのは入力の取り出し・ホスト判定・抜け道・deny 文だけである。
# 述語は `-` で始まる語の `=` より右に未引用の `*` / `?` / `[` がある形だけに絞っており、
# cwd の状態に依存しないので呼び出し文字列だけで真陽性と断定できる。加えて URL のクエリ文字列の形
# （未引用の `?` の直後に `key=` が続く語。`gh api repos/o/r/contents/a.md?ref=main`。Issue `#2138`）も、
# その名前のファイルが実在しない限り必ず 0 件になるので対象に入れる。一般のパス glob
# （`ls *.md` / `ls a?.md`）は cwd 次第でマッチするので対象に入れない。
#
# ## 発火条件（zsh ホストだけ）
#
# Bash ツールを動かすシェルが zsh のときだけ発火する。判定は Claude Code がシェルを
# 選ぶのと同じ入力 — `CLAUDE_CODE_SHELL`（明示の上書き）、無ければ `SHELL` — の basename。
# bash ホスト（Linux の既定・Windows の Git Bash）では同じ記法が正しく動くので発火させない。
# どちらも未設定・zsh / bash 以外のときも発火させない（ホストのシェルを知らないまま
# 止めると、正しく動くコマンドを止める側へ倒れる）。
#
# ## 針が当たらない入力の既定（TESTING.md の同名節）
#
# fail-open（無音 exit 0）にする面 — 判定の対象外であることが入力から確定している:
#   - Bash 以外のツール / 空のコマンド / JSON でない入力（jq の rc=5）
#   - zsh ホストでない / `jq` 不在（コマンド本文を取り出せず、候補かどうかも決められない）
#   - 生の入力に `=` と glob 文字（`*` `?` `[`）が 1 つも無い、またはコマンドに `-…=` の右の glob 文字も
#     `?` の直後の `key=` も無い（候補でない）
#
# fail-closed（理由付き deny）にする面 — **候補コマンドに限る**。判定を完了できないのに
# 通すと、守ろうとしている失敗（コマンド全体が走らない）をそのまま通す:
#   - ASDD ゲートが検証不能を返す（`.asdd/config.json` があるのに node が無い等。無効の rc 3 は素通し）
#   - 引用・展開が閉じないまま入力が終わる（判定ヘルパの rc 4。走査が途中で止まっている）
#   - 判定ヘルパ・heredoc 除去ヘルパのファイルが無い / 読めない / source に失敗する /
#     関数が無い
#   - どちらかの awk が非 0 で終わる（不在 127・破損）
#   - jq のフィルタ実行が parse 以外で失敗する
# 候補に限るのは、ヘルパが壊れた瞬間に**すべての** Bash 呼び出しが止まって復旧作業が
# できなくなるのを避けるため（guard-exit-code.sh と同じ面の切り方）。
#
# 止めない通知の頻度（Issue `#2616`。notice_first）は、session_id が無い・記録のキーに使えない・
# 記録を作れないとき毎回出す側へ倒す（出し済みと判定できないまま黙らせない）。
#
# heredoc 本文はデータとして走査対象から落とす（`tests/lib/heredoc-strip.sh`。未終端の
# rc 3 は `<<` の誤検出とみなし、本文除去前の生コマンドを走査する）。
#
# ## 出力チャネルと抜け道
#
# glob / equals と同じ呼び出しの直前代入が示す一覧scalarは deny。値不明scalarは警告。
# systemMessage はエージェントへ届かないので、同じ hook を PostToolUse（Bash）にも登録し、
# scalar だけを `hookSpecificOutput.additionalContext` で実行後に返す（止めない）。
# 追加検出の契約は tests/lib/zsh-expansion-guard.sh。deny の JSON を組み立てる jq が失敗したら黙って許可に
# 落とさず、exit 2 + stderr のブロック経路へ落とす。
# 入力書き換えに対応した Claude hook 環境では、nomatch と equals（`=` だけの語）の書き換え案が
# 一意に決まる呼び出しに限り、deny の代わりに updatedInput（引用した語）と additionalContext を
# 1 つの JSON で返す（Issue `#2255`。条件は try_rewrite の注記、契約は guard-exit-code.sh の Issue `#2182` と同じ。公開 https://github.com/feel-flow/ff-dev-toolkit/issues/142）。
# 同じ環境で、hook 入力の permission_mode が bypassPermissions のときだけ、未引用の名前付き変数（scalar。一覧値の
# scalar-list を含む）を含む呼び出しの先頭へ `setopt SH_WORD_SPLIT; ` を付けて bash と同じ単語分割規則にそろえる
# （Issue `#2491`。他の権限モードでは、書き換え後の入力の各文に権限ルールが当たり、read-only の一覧に無い setopt が
# 承認待ち・拒否を増やすので付けない）。位置引数（`$1`）だけの呼び出しは既存の scalar 検出が数えないので付かない。書き換えた呼び出しの scalar は
# 警告せず、PostToolUse も scalar を返さない（最初の文が setopt SH_WORD_SPLIT の呼び出しは zsh-expansion-guard.sh が
# scalar の対象から外す）。入力書き換えに対応しない環境（Codex / grok / 対応前の Claude Code）は従来の警告・deny のまま。
# `bash <<'EOF'` へ包み直す案（Issue `#2491` の案 B）は採らない — 包んだ本文はホストの権限判定・安全確認が中身を
# 読めない形になり、同じ集約入口の終了コードガードの bash -c 書き換えがホストの安全確認で拒否された実測がある。
# 止めない通知（未引用 scalar の警告の systemMessage・PostToolUse の additionalContext・書き換えの通知）は、
# 種類ごとに同じセッション・同じエージェントで最初の 1 回だけ出す（Issue `#2616`。deny と updatedInput は毎回同じ）。
#   - この呼び出しだけ通す: Bash ツールへ渡すコマンドの**先頭の語**を環境代入 `FF_ZSH_GLOB_ACK=1`
#     にする（前に別の環境代入・文があると無効。引用値の中や途中の文に現れるだけでも無効）。
#     効く単位は Bash ツールの 1 呼び出しで、先頭に置けば改行で続く文にも効く（guard-exit-code.sh
#     の ACK と同じ単位。意図の表明であって文単位の許可ではない）。
#     `setopt nonomatch` 済みのシェルや、その名前のファイルが実在する場合の誤検知用
#   - ガードごと止める: 環境変数 `FF_DEV_TOOLKIT_SKIP=zsh-glob`（covers で zsh-expansion も止まる）
#
# ## 既知の限界（素通しする形）
#
#   - 一般のパス glob（`ls *.md` / `ls a*.ts b*.mts`）— 述語の対象外（上記）
#   - `$name:修飾子`。未引用 scalar と equals は zsh-expansion-guard.sh へ委ねる。
#   - 変数やコマンド置換の結果として組み立てられる語（`$flag` の中身は見えない）
#   - `nonomatch` / `null_glob` を設定済みのシェル（誤検知側。ACK で 1 手で通る）
#   - 区切り語を引用しない heredoc（`<<EOF`）の本文に書いた `$(…)` の中のコマンド。zsh は
#     その中身を実行時に glob するが、heredoc 本文はデータとして丸ごと落としている
#     （`tests/lib/heredoc-strip.sh` は区切り語の引用の有無を返さない）
#
# 互換性: bash 3.2（stock macOS）。連想配列・readarray を使わない。
# 環境変数:
#   FF_DEV_TOOLKIT_SKIP=zsh-glob       追加の equals/scalar 検出も含む全体を無効化する（鍵の名簿は
#                                      scripts/lib/l4-declarations.tsv）
#   FF_DEV_TOOLKIT_SKIP=zsh-expansion  equals/scalar の検出だけを無効化する

# fail-open の面を持つため set -e / set -u は使わない。

# stdin は bash 組み込みの read で読み切る（外部コマンドに依存しない）。opt-out や
# 早期終了の経路でも読み切ってから抜け、書き手（ホスト）に EPIPE / SIGPIPE を返さない。
input=""
IFS= read -r -d '' input || true

# ASDD ゲートは drain より後に置く（ゲートの早期終了で stdin 未読のまま抜けないため）。
if ! source "${BASH_SOURCE[0]%/*}/asdd-hook-gate.sh"; then
  echo 'ff-dev-toolkit: ASDD Hook helper is unavailable; optional hook skipped' >&2
  exit 0
fi
# rc を読む（`|| exit 0` にしない）。共有ヘルパの契約は 0=有効 / 3=無効 / それ以外=検証不能。
# 無効は無音で通し、検証不能は候補コマンドに限り下で fail-closed へ倒す（guard-exit-code.sh と
# 同じ扱い。Issue `#1684`）。
asdd_hook_enabled hooks
asdd_rc=$?
asdd_unverifiable=0
case "$asdd_rc" in
  0) : ;;
  3) exit 0 ;;
  *) asdd_unverifiable=1 ;;
esac

# 宣言の判定は共通関数 scripts/lib/l4-declarations.sh（ADR-087）。読めないときは止めない側に倒す。
# zsh-glob の宣言は covers で zsh-expansion も止める（名簿 scripts/lib/l4-declarations.tsv）。
# shellcheck source=../scripts/lib/l4-declarations.sh
{ [ -r "${BASH_SOURCE[0]%/*}/../scripts/lib/l4-declarations.sh" ] && . "${BASH_SOURCE[0]%/*}/../scripts/lib/l4-declarations.sh"; } 2>/dev/null || ff_l4_skipped() { return 1; }
if ff_l4_skipped 'zsh-glob'; then exit 0; fi
# equals / scalar の検出（zsh-expansion）の宣言は 3 か所（PostToolUse・PreToolUse・書き換え）で使うので 1 回だけ判定する
ff_zsh_exp_skipped=0
if ff_l4_skipped 'zsh-expansion'; then ff_zsh_exp_skipped=1; fi

# ---- ホスト判定（zsh のときだけ） -----------------------------------------------
host_shell="${CLAUDE_CODE_SHELL:-${SHELL:-}}"
case "${host_shell##*/}" in
  zsh | zsh-*) : ;;
  *) exit 0 ;;
esac

# ---- 止めない通知の頻度（Issue `#2616`） --------------------------------------------
# 止めない通知（未引用 scalar の警告・書き換えの通知）は、通知の種類ごとに同じセッション（hook 入力の
# session_id）で最初の 1 回だけ出す。PreToolUse の systemMessage も additionalContext も Claude Code の
# CLI と Remote Control の画面に出るので、呼び出しごとに出すと画面を埋めて読み飛ばされる（ACE-2615-1）。
# deny と updatedInput（書き換えそのもの）は頻度を絞らない。判定不能・helper 不在の通知（どれも
# 「zsh 展開ガード:」で始まる）は壊れていることを隠さないよう毎回出す。
# 出した記録は ${FF_DEV_TOOLKIT_STATE_DIR:-$HOME/.config/ff-dev-toolkit}/notices/<session_id>/<agent_id|main>/<種類>
# のディレクトリで、mkdir の成否で初回を決める（並行した呼び出しでも初回は 1 つに決まる）。サブエージェントは
# 親と session_id を共有するが文脈は別なので、hook 入力の agent_id ごとに数える。
# session_id が無い・記録のキーに使えない・記録を作れないときは、従来どおり毎回出す（黙らせる側へ倒さない）。
# 集約入口（run-bash-hooks.sh）から呼ばれた回は、作った記録を FF_BASH_HOOKS_NOTICE_LOG へ 1 行ずつ渡す。
# 集約入口は、通知を載せた JSON を deny 以外で出せなかった回（別のガードの deny・書き換えの競合・
# 再検査の失敗・打ち切り）にその記録を消し、次の呼び出しで改めて出させる。
# 同じプロセスで同じ種類をもう一度判定したとき（書き換えを諦めて deny・警告へ戻る経路）は同じ答えを返す。
notice_key=""
notice_key_read=0
notice_decided=" "
notice_first() { # <種類> — 0: 出す / 1: このセッション（とエージェント）で出し済み
  local base dir ids sid aid
  case "$notice_decided" in *" $1 "*) return 0 ;; esac
  if [ "$notice_key_read" -eq 0 ]; then
    notice_key_read=1
    ids="$(printf '%s' "$input" | jq -r '[(.session_id | strings) // "", (.agent_id | strings) // ""] | join("/")' 2>/dev/null)" || ids=""
    ids="${ids//$'\r'/}"  # Windows の jq.exe は改行を \r\n で出す（Issue `#2017`）
    sid="${ids%%/*}"
    aid="${ids#*/}"
    [ -n "$aid" ] || aid=main
    case "$sid" in '' | .* | *[!A-Za-z0-9._-]*) sid="" ;; esac
    case "$aid" in .* | *[!A-Za-z0-9._-]*) sid="" ;; esac
    [ -z "$sid" ] || notice_key="$sid/$aid"
  fi
  [ -n "$notice_key" ] || return 0
  if [ -n "${FF_DEV_TOOLKIT_STATE_DIR:-}" ]; then
    base="$FF_DEV_TOOLKIT_STATE_DIR"
  elif [ -n "${HOME:-}" ]; then
    base="$HOME/.config/ff-dev-toolkit"
  else
    return 0
  fi
  dir="$base/notices/$notice_key"
  mkdir -p "$dir" 2>/dev/null || return 0
  if mkdir "$dir/$1" 2>/dev/null; then
    # 集約入口へ渡せない記録は残さない（届かなかった回に取り消せないまま黙らせる側へ倒れる）
    if [ -n "${FF_BASH_HOOKS_NOTICE_LOG:-}" ] && ! printf '%s\n' "$dir/$1" >> "$FF_BASH_HOOKS_NOTICE_LOG" 2>/dev/null; then
      rmdir "$dir/$1" 2>/dev/null
    fi
    notice_decided="$notice_decided$1 "
    return 0
  fi
  [ -d "$dir/$1" ] && return 1
  return 0
}

# 同じホスト入口で equals/scalar も検出する。警告は既存 glob の deny と JSON を分断しない。
# equals の deny は入力書き換え（下の try_rewrite）を試すまで保留する（Issue `#2255`）。
expansion_warning=""
expansion_deny=""
expansion_helper="${BASH_SOURCE[0]%/*}/../tests/lib/zsh-expansion-guard.sh"

# ---- PostToolUse（Bash）: 未引用 scalar の警告をエージェントの文脈へ届ける ----------------
# PreToolUse の systemMessage は利用者の画面にしか出ずエージェントへ届かない。同じ判定
# （zsh-expansion-guard.sh。判定本体は二重化しない）を実行後に当て、scalar だけを
# hookSpecificOutput.additionalContext で返す。glob / equals の停止は PreToolUse の担当なので
# ここでは走らせない。実行は既に終わっているので、どの失敗経路でも止めない（fail-soft）:
# jq 不在・JSON でない入力・helper の異常終了は無音、helper 不在は `$` を含むコマンドに限り
# 未検査である旨を additionalContext で知らせる。scalar の検出はセッションで 1 回だけ返す（Issue `#2616`）。
case "$input" in
  *'"PostToolUse"'*)
    if command -v jq >/dev/null 2>&1 \
      && [ "$(printf '%s' "$input" | jq -r '.hook_event_name // empty' 2>/dev/null)" = PostToolUse ]; then
      [ "$ff_zsh_exp_skipped" = 1 ] && exit 0
      if [ -r "$expansion_helper" ]; then
        post_out="$(printf '%s' "$input" | bash "$expansion_helper" 2>/dev/null)" || true
        if [ -n "$post_out" ]; then
          post_context="$(printf '%s' "$post_out" | jq -r '.hookSpecificOutput.additionalContext // empty' 2>/dev/null)" || post_context=""
          case "$post_context" in
            '' | 'zsh 展開ガード:'*) : ;;
            *) notice_first zsh-scalar-agent || post_out="" ;;
          esac
          [ -z "$post_out" ] || printf '%s\n' "$post_out"
        fi
      else
        post_cmd="$(printf '%s' "$input" | jq -r 'select(.tool_name == "Bash") | .tool_input.command | select(type == "string")' 2>/dev/null)"
        post_cmd="${post_cmd//$'\r'/}"  # Windows の jq.exe は改行を \r\n で出す（Issue `#2017`）
        case "$post_cmd" in
          *'$'*) jq -n '{hookSpecificOutput: {hookEventName: "PostToolUse", additionalContext: "zsh 展開ガード: helper が不在で直前の Bash 呼び出しの未引用変数を未検査です。ff-dev-toolkit を更新・復旧してください。"}}' ;;
        esac
      fi
      exit 0
    fi
    ;;
esac
if [ "$ff_zsh_exp_skipped" = 1 ]; then
  :
elif [ -r "$expansion_helper" ]; then
  expansion_rc=0
  expansion_out="$(printf '%s' "$input" | bash "$expansion_helper")" || expansion_rc=$?
  [ "$expansion_rc" -eq 0 ] || exit "$expansion_rc"
  if [ -n "$expansion_out" ]; then
    if printf '%s' "$expansion_out" | jq -e '.hookSpecificOutput.permissionDecision == "deny"' >/dev/null 2>&1; then
      expansion_deny="$expansion_out"
    else
      expansion_warning="$(printf '%s' "$expansion_out" | jq -r '.systemMessage // empty' 2>/dev/null)"
      expansion_warning="${expansion_warning//$'\r'/}"  # Windows の jq.exe は改行を \r\n で出す（Issue `#2017`）
    fi
  fi
else
  # helper 不在を検出0と混同しない。scalar-only は停止しない。
  missing_cmd="$(printf '%s' "$input" | jq -r 'select(.tool_name == "Bash") | .tool_input.command | select(type == "string")' 2>/dev/null)"
  missing_cmd="${missing_cmd//$'\r'/}"  # Windows の jq.exe は改行を \r\n で出す（Issue `#2017`）
  case "$missing_cmd" in
    =?* | *' ='?* | *$'\t='?* | *$'\n='?*)
      missing_reason='zsh 展開ガード: 判定不能（helper 不在）。ff-dev-toolkit を更新・復旧するか FF_DEV_TOOLKIT_SKIP=zsh-expansion で無効化してください。'
      jq -n --arg m "$missing_reason" '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "deny", permissionDecisionReason: $m}}' || { printf '%s\n' "$missing_reason" >&2; exit 2; }
      exit 0 ;;
  esac
  case "$missing_cmd" in *'$'*) expansion_warning='zsh 展開ガード: helper が不在で未検査です。ff-dev-toolkit を更新・復旧してください。' ;; esac
fi
# 未引用 scalar の警告（判定不能の通知ではない systemMessage）を、このセッションで出し済みなら落とす（Issue `#2616`）。
# 呼ぶのは出力の直前だけにする — expansion_warning は単語分割の書き換えを試すかの合図も兼ねている。
drop_shown_scalar_warning() {
  case "$expansion_warning" in
    '' | 'zsh 展開ガード:'*) : ;;
    *) notice_first zsh-scalar-screen || expansion_warning="" ;;
  esac
}
emit_expansion_warning() {
  # 保留した equals の deny が未出力のまま抜ける経路があっても、無音の許可にしない。
  if [ -n "$expansion_deny" ]; then
    printf '%s\n' "$expansion_deny"
    return
  fi
  drop_shown_scalar_warning
  if [ -n "$expansion_warning" ]; then
    jq -n --arg m "$expansion_warning" '{systemMessage: $m}' || printf '%s\n' "$expansion_warning" >&2
  fi
}
trap emit_expansion_warning EXIT

# ---- 安価な前置フィルタ（候補でなければ何も読まずに抜ける） -------------------------
# equals の deny を保留している回は抜けない（`echo ====` は glob 文字を持たないので、ここで
# 抜けると書き換えを試さないまま deny も返さずに終わる）。glob の走査だけを飛ばす。
glob_candidate=1
case "$input" in
  *=*) : ;;
  *) glob_candidate=0 ;;
esac
case "$input" in
  *'*'* | *'?'* | *'['*) : ;;
  *) glob_candidate=0 ;;
esac
[ "$glob_candidate" -eq 1 ] || [ -n "$expansion_deny" ] || [ -n "$expansion_warning" ] || exit 0

command -v jq >/dev/null 2>&1 || exit 0

HELPER_DIR="${BASH_SOURCE[0]%/*}/../tests/lib"
HELPER_DIR_SHOWN="$HELPER_DIR"
case "$HELPER_DIR_SHOWN" in
  hooks/../*) HELPER_DIR_SHOWN="${HELPER_DIR_SHOWN#hooks/../}" ;;
  */hooks/../*) HELPER_DIR_SHOWN="${HELPER_DIR_SHOWN%%/hooks/../*}/${HELPER_DIR_SHOWN#*/hooks/../}" ;;
esac

deny() { # <reason>
  local out rc
  drop_shown_scalar_warning
  out="$(jq -n --arg reason "$1" --arg warning "$expansion_warning" \
    '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "deny", permissionDecisionReason: $reason}} + (if $warning != "" then {systemMessage: $warning} else {} end)' 2>/dev/null)"
  rc=$?
  if [ "$rc" -ne 0 ] || [ -z "$out" ]; then
    printf '%s\n' "$1" >&2
    printf 'ff-dev-toolkit guard-zsh-glob: deny の JSON を組み立てられませんでした（jq rc=%s）。exit 2 でブロックします。\n' "$rc" >&2
    exit 2
  fi
  expansion_warning=""
  expansion_deny=""
  printf '%s\n' "$out"
  exit 0
}

deny_unavailable() { # <理由>
  deny "⚠️ ff-dev-toolkit guard（zsh-nomatch-glob: 未引用 glob の NOMATCH）: **判定不能**のため停止しました（${1}）。
このコマンドは \`-…=\` の右側に glob 文字を含む、または URL のクエリ文字列の形（\`…?key=value\`）を含む可能性がある候補ですが、判定ヘルパ（${HELPER_DIR_SHOWN}/zsh-glob-nomatch.sh / heredoc-strip.sh）で走査を完了できませんでした。判定できないまま通すと、zsh の NOMATCH でコマンド全体が走らない形を素通しします。
対処:
  1) ff-dev-toolkit を更新・再インストールしてヘルパを復旧する
  2) = の右側を引用した形（例: --include=\"*.md\"）、クエリ文字列の形は語全体を引用した形（例: \"repos/o/r/contents/a.md?ref=main\"）で書き直して再実行する
  3) このコマンドに限って通す: コマンドの**先頭**へ環境代入 FF_ZSH_GLOB_ACK=1 を付けて再実行する
  4) ガードごと止める: 環境変数 FF_DEV_TOOLKIT_SKIP=zsh-glob を設定する"
}

tab='	'

# ---- 入力書き換え（Issue `#2255`。終了コードガードの Issue `#2182` と同じ契約） ----------------
# 書き換え案が一意に決まる形だけ、deny の代わりに updatedInput を返す。どれか 1 つでも
# 満たさなければ return 1 で従来の deny へ戻す（部分的には書き換えない）:
#   - 入力書き換えを確認した Claude hook 環境（guard-exit-code.sh と同じ判定）
#   - ASDD 設定を検証できている / heredoc が無い（本文を落とした文字列と元が一致する）
#   - 元のコマンドに CR が無い（判定用に CR を落とした文字列を実行入力へ戻さない）
#   - 一覧値の未引用 scalar（scalar-list の deny）が無い
#   - 検出した語すべてに書き換え案がある（引用・展開を含む語や `=cmd` は案 `-`）
#   - 語ごとに、出現回数が検出回数と一致する（引用の中・別の語の一部に同じ綴りがあると
#     置換が判定対象外まで書き換えるので、その回は書き換えない）。長い語から置換し、回数は
#     置換途中の文字列で数える（`--include=*.js` は `--include=*.json` の一部だが、長い方を
#     先に引用すると `=` の直後に `"` が入り、短い方の綴りは残らない）
#   - 書き換え後を同じ判定で再走査して 0 件になる
# 位置（オフセット）での差し替えはしない。awk と bash で文字数の数え方が揃わない環境が
# あるため（bash 3.2 の MBCS）、語の綴りそのものの置換と出現回数の照合で一意性を担保する。
# allow は返さず、採用・実行は集約入口の全ガード再検査と通常の権限判定に従う。
try_rewrite() {
  [ "${CLAUDECODE:-}" = 1 ] && [ -n "${CLAUDE_PROJECT_DIR:-}" ] && [ -z "${GROK_PLUGIN_ROOT:-}" ] || return 1
  printf '%s' "$input" | jq -e '.hook_event_name == "PreToolUse" and (has("model") | not)' >/dev/null 2>&1 || return 1
  # cmd は判定用に CR を除去してある。元のコマンドに CR があると、その値を実行入力へ戻すと
  # 引用の中の CR まで消えてデータが変わるので書き換えない。
  printf '%s' "$input" | jq -e '.tool_input.command | contains("\r") | not' >/dev/null 2>&1 || return 1
  [ "$asdd_unverifiable" -eq 0 ] || return 1
  local helper fn stripped eq_on exp_hits fixes glob_fix eq_fix line word fix total n rest rewritten listed ordered out split_on has_heredoc context permission_mode warning_out
  # 公式の hook 入力の共通フィールド（default / plan / acceptEdits / auto / dontAsk / bypassPermissions）。
  # 集約入口の再投入は tool_input だけを差し替えるので、再検査の入力にもそのまま残る。
  permission_mode="$(printf '%s' "$input" | jq -r '.permission_mode // empty | select(type == "string")' 2>/dev/null)" || permission_mode=""
  permission_mode="${permission_mode//$'\r'/}"  # Windows の jq.exe は改行を \r\n で出す（Issue `#2017`）
  for helper in heredoc-strip.sh zsh-glob-nomatch.sh; do
    [ -r "$HELPER_DIR/$helper" ] || return 1
    . "$HELPER_DIR/$helper" 2>/dev/null || return 1
  done
  for fn in ff_heredoc_strip ff_zsh_glob_scan ff_zsh_expansion_scan ff_zsh_equals_fix_scan ff_zsh_word_split_prefixed; do
    [ "$(type -t "$fn" 2>/dev/null)" = function ] || return 1
  done
  # heredoc の本文はデータとして落としてから走査する（未終端の rc 3 は書き換えない）。語の置換は本文の
  # 同じ綴りまで書き換えるので heredoc を含む呼び出しでは行わないが、先頭へ文を足すだけの単語分割の
  # 書き換えは本文に触れないので行う。
  stripped="$(ff_heredoc_strip "$cmd")" || return 1
  has_heredoc=0
  [ "$stripped" = "$cmd" ] || has_heredoc=1
  glob_fix="$(ff_zsh_glob_scan "$stripped")" || return 1
  eq_fix=""
  eq_on=0
  split_on=0
  # equals / scalar の検出を止めている回（無効化・ACK）は、equals の語にも単語分割にも触れない。
  if [ "$ff_zsh_exp_skipped" != 1 ] && [ "$ack_probe" = "${ack_probe#FF_ZSH_EXPANSION_ACK=1}" ]; then
    eq_on=1
    exp_hits="$(ff_zsh_expansion_scan "$stripped")" || return 1
    # 未引用の名前付き変数（scalar。一覧値の scalar-list を含む）を含む呼び出しは、先頭へ setopt SH_WORD_SPLIT を
    # 付けて bash と同じ分割規則にそろえる（Issue `#2491`）。ただし付けるのは hook 入力の permission_mode が
    # bypassPermissions のときだけ — Claude Code は書き換え後の入力に権限ルールを当て、`;` で区切った各文に許可を
    # 求めるので、read-only の一覧に無い setopt を前置すると、他のモードでは承認なしで通っていた呼び出し
    # （`ls -la $TMPDIR` など）が毎回の承認待ち（dontAsk / claude -p では拒否）に変わる。欠落・他の値は付けない
    # （従来の警告 / deny のまま。fail-safe）。既に付いている呼び出しと、別のガードの ACK（先頭の語であることが
    # 条件）を持つ呼び出しにも付けない — 前置すると ACK が先頭の語でなくなり、再検査でそのガードが止める。
    # 付けない回も glob / equals の引用の書き換えは続ける。
    case "$exp_hits" in *scalar*) split_on=1 ;; esac
    # 定義が読めない・空のときは前置しない。空文字を前置すると、引用の書き換えと同居した回に
    # 「先頭に付けた」と出て scalar の警告が消える。引用の書き換えは続ける（上の「付けない回」）。
    if [ "$split_on" -eq 1 ] && [ -z "${FF_ZSH_WORD_SPLIT_PREFIX-}" ]; then
      split_on=0
    fi
    if [ "$split_on" -eq 1 ]; then
      if ff_zsh_word_split_prefixed "$cmd"; then
        split_on=0
      elif [ "${cmd#"$FF_ZSH_WORD_SPLIT_PREFIX"}" != "$cmd" ]; then
        # この hook が前置した文で始まるのに有効と読めない（後ろで unsetopt する等）呼び出しへ重ねて付けない
        # （再検査のたびに書き換えを求めて集約入口の停止へ落ちるのを防ぐ）
        split_on=0
      elif [ "$permission_mode" != bypassPermissions ]; then
        split_on=0
      else
        case "$cmd" in *FF_*_ACK=*) split_on=0 ;; esac
      fi
    fi
    eq_fix="$(ff_zsh_equals_fix_scan "$stripped")" || return 1
  fi
  fixes="$glob_fix"
  [ -z "$eq_fix" ] || fixes="${fixes:+$fixes
}$eq_fix"
  [ -n "$fixes" ] || [ "$split_on" -eq 1 ] || return 1
  [ -z "$fixes" ] || [ "$has_heredoc" -eq 0 ] || return 1
  rewritten="$cmd"
  listed=""
  ordered=""
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    word="${line%%"${tab}"*}"
    fix="${line#*"${tab}"}"
    [ -n "$word" ] && [ "$fix" != "-" ] && [ "$fix" != "$line" ] || return 1
    ordered="${ordered}${#word}${tab}${line}
"
  done <<EOF
$fixes
EOF
  ordered="$(printf '%s' "$ordered" | sort -t "$tab" -k1,1nr)" || return 1
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    line="${line#*"${tab}"}"
    word="${line%%"${tab}"*}"
    fix="${line#*"${tab}"}"
    case "$listed" in *"
${word} → "*) continue ;; esac
    total=0
    while IFS= read -r n; do
      [ "${n%%"${tab}"*}" != "$word" ] || total=$((total + 1))
    done <<EOF
$fixes
EOF
    rest="${rewritten//"$word"/}"
    [ $(( (${#rewritten} - ${#rest}) / ${#word} )) -eq "$total" ] || return 1
    rewritten=${rewritten//"$word"/$fix}
    listed="${listed}
${word} → ${fix}"
  done <<EOF
$ordered
EOF
  [ "$split_on" -eq 0 ] || rewritten="${FF_ZSH_WORD_SPLIT_PREFIX}${rewritten}"
  [ "$rewritten" != "$cmd" ] || return 1
  stripped="$(ff_heredoc_strip "$rewritten")" || return 1
  [ -z "$(ff_zsh_glob_scan "$stripped")" ] || return 1
  if [ "$eq_on" -eq 1 ]; then
    [ -z "$(ff_zsh_equals_fix_scan "$stripped")" ] || return 1
    case "$(ff_zsh_expansion_scan "$stripped")" in *equals*) return 1 ;; esac
    # 単語分割を前置した回は scalar が解消済み（setopt で分割される）。前置していない回に一覧 scalar が残るなら書き換えない
    if ! ff_zsh_word_split_prefixed "$rewritten"; then
      case "$(ff_zsh_expansion_scan "$stripped")" in *scalar-list*) return 1 ;; esac
    fi
  fi
  # 書き換えの通知は種類ごとにセッションで 1 回だけ付ける（Issue `#2616`）。出し済みの回も updatedInput は同じ。
  context=""
  if [ -n "$listed" ] && notice_first zsh-rewrite-quote; then
    listed="${listed#?}"
    listed="${listed//
/、}"
    context="zsh ガード（zsh-nomatch-glob / equals 展開）: zsh で実行されない未引用の語を引用して書き換える候補を作成しました（${listed}）。次の呼び出しからは最初から引用して書いてください。"
  fi
  # 書き換えを出せたときだけ expansion_warning を消す（jq が失敗して deny・警告へ戻る回は従来の警告を残す）
  if [ "$split_on" -eq 1 ]; then
    # 前置で解消する未引用 scalar の警告は出さず、書き換えたことを利用者の画面へ知らせる
    warning_out=""
    if notice_first zsh-word-split; then
      context="${context}zsh 単語分割ガード: 未引用の名前付き変数（\${NAME} の形）を含む呼び出しを bash と同じ規則で単語分割させるため、呼び出しの先頭に ${FF_ZSH_WORD_SPLIT_PREFIX% } を付ける書き換え候補を作成しました（権限モードが bypassPermissions のときだけ付けます。位置引数の \$1 などだけを含む呼び出しには付きません。外す場合は先頭へ FF_ZSH_EXPANSION_ACK=1）。"
      warning_out="zsh 単語分割ガード: 未引用の変数を bash と同じ規則で単語分割させるため、呼び出しの先頭に ${FF_ZSH_WORD_SPLIT_PREFIX% } を付けました（書き換え候補。採用・実行は再検査と通常の権限判定に従います）。"
    fi
  else
    drop_shown_scalar_warning
    warning_out="$expansion_warning"
  fi
  out="$(printf '%s' "$input" | jq -c --arg command "$rewritten" --arg context "$context" --arg warning "$warning_out" '
    {hookSpecificOutput: ({hookEventName: "PreToolUse", updatedInput: (.tool_input + {command: $command})}
      + (if $context != "" then {additionalContext: ($context + "採用・実行は再検査と通常の権限判定に従います。")} else {} end))}
    + (if $warning != "" then {systemMessage: $warning} else {} end)' 2>/dev/null)" || return 1
  [ -n "$out" ] || return 1
  expansion_warning=""
  expansion_deny=""
  printf '%s\n' "$out"
  exit 0
}

jq_rc=0
cmd="$(printf '%s' "$input" | jq -r 'if (type == "object") and (.tool_name == "Bash") then ((.tool_input // {}) | if type == "object" then (.command // "") else "" end) else "" end | if type == "string" then . else "" end' 2>/dev/null)" || jq_rc=$?
cmd="${cmd//$'\r'/}"  # Windows の jq.exe は改行を \r\n で出す（Issue `#2017`）
if [ "$jq_rc" -ne 0 ]; then
  # rc=5 は入力が JSON でない（対象外として素通し）。それ以外はフィルタ自体の失敗。
  [ "$jq_rc" -eq 5 ] && exit 0
  deny_unavailable "コマンド本文の取り出し（jq）が失敗しました（rc=${jq_rc}）"
fi
[ -n "$cmd" ] || exit 0

# 候補は `-…=` の右に glob 文字がある形か、`?` の直後に `key=` が続く形（クエリ文字列。Issue `#2138`）。
# 後者を `?` の後ろのどこかの `=` まで広げると `rc=$?; [ "$rc" = 0 ]` も候補になり、ヘルパが
# 壊れた回に判定不能の deny で止まるので、判定ヘルパの述語と同じ並びに絞る。
query_re='[?][A-Za-z_][A-Za-z0-9_-]*='
if ! [[ $cmd =~ $query_re ]]; then
  case "$cmd" in
    *-*=*'*'* | *-*=*'?'* | *-*=*'['*) : ;;
    *) glob_candidate=0 ;;
  esac
fi
[ "$glob_candidate" -eq 1 ] || [ -n "$expansion_deny" ] || [ -n "$expansion_warning" ] || exit 0

# ---- 抜け道: コマンドの先頭（先頭の空白・タブ・改行だけを剥がす）の FF_ZSH_GLOB_ACK=1 --------
# 先頭の語そのものに限る（guard-exit-code.sh の ACK と同じリテラル判定）。先頭に連なる環境代入を
# 語単位で読み進める形は、`;` を含む語・引用値の中・改行で区切った前の文まで受理してしまう
# （セルフレビューで `X=1; FF_ZSH_GLOB_ACK=1 true; grep …` が通ることを実測した）。
ack_probe="$cmd"
while :; do
  case "$ack_probe" in
    " "* | "	"* | "
"*) ack_probe="${ack_probe#?}" ;;
    *) break ;;
  esac
done
case "$ack_probe" in
  'FF_ZSH_GLOB_ACK=1 '* | 'FF_ZSH_GLOB_ACK=1	'*) exit 0 ;;
esac

# ASDD ゲートが検証不能を返した回は、候補コマンドに限りここで止める（ACK の判定より後 —
# deny 文が案内する「先頭へ FF_ZSH_GLOB_ACK=1」が効く位置）。
# equals だけの候補（`echo ====`。glob の前置フィルタに当たらない）は、ヘルパが返した equals の
# deny（ASDD 検証不能の理由付き）を保留から出す。glob の判定不能 deny には置き換えない。
if [ "$asdd_unverifiable" -eq 1 ] && [ "$glob_candidate" -eq 0 ]; then
  exit 0
fi
if [ "$asdd_unverifiable" -eq 1 ]; then
  deny_unavailable "ASDD 設定を検証できません（asdd_hook_enabled rc=${asdd_rc}。.asdd/config.json があるのに node が無い・設定を読めない等）"
fi

hits=""
if [ "$glob_candidate" -eq 1 ]; then
# ---- heredoc 本文を落とす -----------------------------------------------------
HEREDOC_HELPER="$HELPER_DIR/heredoc-strip.sh"
[ -f "$HEREDOC_HELPER" ] && [ -r "$HEREDOC_HELPER" ] || deny_unavailable "heredoc 除去ヘルパのファイルが無いか読めません（${HELPER_DIR_SHOWN}/heredoc-strip.sh）"
# shellcheck source=../tests/lib/heredoc-strip.sh
. "$HEREDOC_HELPER" 2>/dev/null || deny_unavailable "heredoc 除去ヘルパの読み込みに失敗しました"
[ "$(type -t ff_heredoc_strip 2>/dev/null)" = "function" ] || deny_unavailable "heredoc 除去ヘルパに ff_heredoc_strip がありません"
strip_rc=0
code_only="$(ff_heredoc_strip "$cmd")" || strip_rc=$?
case "$strip_rc" in
  0 | 3) : ;;
  *) deny_unavailable "heredoc 除去（awk）が失敗しました（rc=${strip_rc}）" ;;
esac

# ---- 判定（共有ヘルパへ委ねる） ------------------------------------------------
SCAN_HELPER="$HELPER_DIR/zsh-glob-nomatch.sh"
[ -f "$SCAN_HELPER" ] && [ -r "$SCAN_HELPER" ] || deny_unavailable "判定ヘルパのファイルが無いか読めません（${HELPER_DIR_SHOWN}/zsh-glob-nomatch.sh）"
# shellcheck source=../tests/lib/zsh-glob-nomatch.sh
. "$SCAN_HELPER" 2>/dev/null || deny_unavailable "判定ヘルパの読み込みに失敗しました"
[ "$(type -t ff_zsh_glob_scan 2>/dev/null)" = "function" ] || deny_unavailable "判定ヘルパに ff_zsh_glob_scan がありません"
scan_rc=0
hits="$(ff_zsh_glob_scan "$code_only")" || scan_rc=$?
case "$scan_rc" in
  0) : ;;
  4) deny_unavailable "引用・展開（'…' / \"…\" / \${…} / \$(…) / バッククォート）が閉じないまま入力が終わったため、走査を完了できません" ;;
  *) deny_unavailable "判定ヘルパの走査（awk）が失敗しました（rc=${scan_rc}）" ;;
esac
fi
# 未引用 scalar の警告だけの呼び出しも、単語分割の書き換え（Issue `#2491`）を試すために先へ進める。
[ -n "$hits" ] || [ -n "$expansion_deny" ] || [ -n "$expansion_warning" ] || exit 0

try_rewrite || true
# 書き換えられなかった equals は、保留していた従来の deny をそのまま返す。
if [ -n "$expansion_deny" ]; then
  expansion_warning=""
  exit 0  # EXIT trap が保留した deny を出す
fi
# glob の検出が無い（scalar の警告だけの）呼び出しは、書き換えられなかったら従来どおり警告だけを出す。
[ -n "$hits" ] || exit 0  # EXIT trap が警告を出す

# ---- deny 文（検出した実値と書き換え案。最大 5 語） ---------------------------------
listed=""
hit_n=0
while IFS= read -r hit_line; do
  [ -n "$hit_line" ] || continue
  hit_n=$((hit_n + 1))
  [ "$hit_n" -le 5 ] || continue
  hit_word="${hit_line%%"${tab}"*}"
  hit_fix="${hit_line#*"${tab}"}"
  if [ "$hit_fix" = "-" ] || [ "$hit_fix" = "$hit_line" ]; then
    listed="${listed}
  ${hit_word}  →  = の右側（クエリ文字列の形は語全体）を引用する（引用・展開・brace を含む語、クエリ文字列の形では語頭の ~ / = や直後の & を含む語のいずれかなので、書き換え案は出していません）"
  else
    listed="${listed}
  ${hit_word}  →  ${hit_fix}"
  fi
done <<EOF
$hits
EOF
[ "$hit_n" -le 5 ] || listed="${listed}
  （ほか $((hit_n - 5)) 語）"

deny "⚠️ ff-dev-toolkit guard（zsh-nomatch-glob: 未引用 glob の NOMATCH）: このホストの Bash ツールは zsh で動きます（${host_shell}）。\`-\` で始まる語の \`=\` より右に未引用の glob 文字（\`*\` \`?\` \`[\`）があると、zsh は語全体を「その名前で始まるファイル」を探す glob として評価し、**cwd に \`.md\` などがあっても 0 件**になり（\`--include=\` で始まる名前のファイルが実在しない限り必ず）、\`no matches found\` でその位置から呼び出しが中断されます（その語を含むコマンドと、\`;\` / \`&&\` で続くそれ以降のコマンドは走りません。手前のコマンドは既に走っているので、結果が一部だけ欠けた形になります。\`2>/dev/null\` を付けてもエラーは消えません）。URL のクエリ文字列の形（\`gh api repos/o/r/contents/a.md?ref=main\` のように未引用の \`?\` の直後に \`key=\` が続く語）も同じで、\`?\` が 1 文字の glob になり、その名前のファイルが実在しない限り必ず 0 件になります。bash では同じ文字列が通るので、bash 前提で書いたコマンドがここでだけ落ちます。
検出した語（実値 → 書き換え案）:${listed}
次のいずれかで再実行してください:
  1) = の右側を引用する（上の書き換え案。例: --include=\"*.md\"。クエリ文字列の形は語全体を引用する: \"repos/o/r/contents/a.md?ref=main\"）
  2) bash 前提の複数行の手順は、bash <<'EOF' … EOF で bash に渡す
  3) 誤検知の場合（nonomatch を設定済み・その名前のファイルが実在する等）は、コマンドの**先頭**へ環境代入を付けて再実行する: FF_ZSH_GLOB_ACK=1 <コマンド>
このガードを止める場合は環境変数 FF_DEV_TOOLKIT_SKIP=zsh-glob を設定します。判定の正本は ${HELPER_DIR_SHOWN}/zsh-glob-nomatch.sh です。"
