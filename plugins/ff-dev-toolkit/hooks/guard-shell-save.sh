#!/usr/bin/env bash

#
# shell ファイルの保存時ガード（PreToolUse / Write|Edit、観測台帳 OBS-042 の対策。Issue `#1801`）。
#
# ## なぜ保存時なのか
#
# `$VAR` 直付けのマルチバイト展開（OBS-042）・`pipefail` 配下の `| grep -q`・パイプ終端の
# 終了コード誤読は、どれも静的検出器が既に在る（正本は下の 3 ライブラリ）。検出器を呼ぶ入口は
# `/pre-commit-check`（staged 走査）と全件ゲートの横断メタ検査で、どちらも**書き手が手順を
# 踏んだ回にしか効かない**。対策 4 世代（`#1340` / `#1431` / `#1747` / `#1759`）はすべて「手順に
# 呼び出しを足す」型で、closed の後も再発が続いた。本 hook は判定を書き手の手順から外し、
# 編集ツールの境界（保存の直前）で同じ検出器を当てる。
#
# ## 判定規則を持たない（走査面だけを足す）
#
# 判定は次の 3 ライブラリを source して公開関数を呼ぶだけで、どの形を違反とみなすかを
# 1 つも持たない（guard-exit-code.sh と同じ分担。判定の複製は OBS-225 の分割圧力も生む）:
#
#   tests/lib/mbcs-guard.sh       mbcs_scan            出力「開始行:論理行」
#   tests/lib/pipefail-grep-q.sh  pipefail_grep_q_scan 出力「開始行:pipefail-grep-q:論理行」
#   tests/lib/exit-code-guard.sh  exit_code_scan       出力「開始行:タグ:論理行」
#
# ## 何を走査するか（保存後のファイル全体 × 新規の違反だけ）
#
# 書き込み内容の断片（Edit の `new_string`）だけを走査すると、検出器が単位（ファイル）全体を
# 前提にしている判定を誤る — `pipefail` の設定行が断片に無ければ `| grep -q` を 1 件も報告
# しない、`gate-exit-dropped` は断片の末尾を単位の終端と読む。そこで**保存後のファイル全体を
# 組み立てて**走査する（Write は `content`、Edit は現在のファイルへ `old_string` →
# `new_string` の置換を当てた結果。`replace_all` も同じ規則で当てる）。
#
# 組み立てた全体を走査すると、編集していない箇所の既存違反まで止めることになる。そこで
# **保存前の内容にも同じ走査を当て、保存前に無かった違反だけ**を deny の対象にする
# （比較の鍵は行番号を落とした「タグ:論理行」で、**件数で**突き合わせる。行の移動で既存違反を
# 新規と誤認せず、既存違反と同じ綴りの行を複製した分は新規として数える）。
# 追跡対象の `*.sh` は全件ゲートがすべて違反 0 件を要求するので、既存違反の持ち越しを
# 許しても素通しにはならない。
#
# ## 対象と fail-open / fail-closed
#
# 対象は `tool_input.file_path` が `.sh` で終わる Write / Edit だけ（場所は問わない — 全件
# ゲートの横断走査が git 管理下の `*.sh` を全部見るのと同じ集合）。次は**無音で通す**（fail-open）:
#   - 対象外（ツール名が Write / Edit でない・パスが `.sh` で終わらない・パスが空）
#   - stdin が JSON として読めない（jq rc=5。フィルタは実行時エラーを出さない形にしてあるので、
#     rc=5 は parse 失敗に限られる）・jq が無い（対象かどうかすら決められない）
#   - Edit の対象ファイルが無いのに `old_string` が空でない / 空でないファイルへの空の
#     `old_string`（どちらも Edit ツール自体が失敗し、保存は起きない）
#   - ASDD の設定で hooks が無効（asdd_hook_enabled rc=3）
# Edit の `old_string` が空（新規作成・空ファイルへの書き込み）は `new_string` を全体として走査する。
# `old_string` がバイト一致しないときは CR を除いて再照合し（Edit ツールは CRLF / LF の差を
# 吸収する）、それでも一致しなければ判定不能として止める（下記）。
#
# 対象なのに**判定を完了できない**ときは、素通しせず理由付きで deny する（fail-closed。
# docs/04-quality/TESTING.md「針が当たらない入力の既定」— 判定不能を緑へ倒さない）:
#   - ライブラリのファイルが無い / 読めない / source に失敗する / 公開関数が無い
#   - 走査（awk）が非 0 で終わる・新規違反の突き合わせ（awk）が失敗する
#   - jq のフィルタ実行が usage(2) / compile(3) で失敗する
#   - Edit の対象ファイルが在るのに読めない・NUL を含んで全体を読めない
#   - Edit の `old_string` が CR 除去後もバイト一致しない（Edit ツールは引用符の正規化でも一致
#     させるため保存されうるが、その対応をバイト列で再現すると引用符の意味が変わる）
#   - ASDD ゲートが検証不能を返す・ASDD ヘルパ自体を読めない（.asdd/config.json があるのに
#     node が無い等）
#   - 検出器が違反を報告したのに、その出力を「開始行:…」として解釈できない
# fail-closed の面は `.sh` への保存に限るので、検出器が壊れても他のファイルの編集は止まらない。
# Write の対象ファイルが在るのに読めないときは、保存前を空として扱う（全体を新規として走査
# する。判定は厳しい側へ寄り、判定不能にはならない）。
#
# ## 抜け道
#
# Write / Edit には Bash のような「コマンド先頭の環境代入」が無い。抜け道はこの hook の
# プロセス環境で受ける:
#   - `FF_SHELL_SAVE_ACK=1`（ホストの env 設定・起動時の export）で、この hook を素通しにする
# 行単位の除外は各ライブラリの規定に従う（`| grep -q` は同じ論理行の行末へ
# `# pipefail-safe: <根拠>`）。直すのが正しい形（`${VAR}` 形 / here-string / `rc=$?; exit $rc`）
# は deny 本文が実値で案内する。
#
# ## 既知の限界（届かない経路。fail-open 側）
#
#   - Bash 経由の書き込み（heredoc・`python3` の文字列置換・`sed -i`）は Write / Edit ではない
#     ので、この hook は発火しない。Issue `#1801` のコメントに同経路での再発実測が複数ある。
#     その経路の最後の砦は `/pre-commit-check` の staged 走査と全件ゲートのまま変わらない
#   - MultiEdit / NotebookEdit は対象外（matcher を `Write|Edit` に限っている）
#   - パスが `.sh` で終わらない shell スクリプト（拡張子なし・`.bash`・大文字の `.SH`）は対象外
#   - 検出器のテストシーム（FF_MBCS_AWK / FF_PIPEFAIL_GREP_Q_AWK / FF_EXIT_CODE_AWK）は hook の
#     中で unset する（セッション環境に残った差し替えで走査が空振りしないため）
#   - Claude Code 以外のホストへの届き方は docs/06-reference/HOST-PARITY.md の `plugin-hooks`
#     と `shell-save-guard` の行が正本
#
# 設計原則:
#   - 互換性: bash 3.2（stock macOS）互換。連想配列・readarray・=~ は使わない
#   - 文字列処理はバイト単位（LC_ALL=C）。`old_string` の置換をロケールに左右させない

# set -e / set -u は使わない（判定の途中終了を自前で扱うため）。

# stdin は bash 組み込みの read で読み切る（契約の正本は hooks/asdd-hook-gate.sh の
# "stdin contract" 節）。-d '' は EOF で非 0 を返すが input には内容が入っている。
input=""
IFS= read -r -d '' input || true

# ASDD 2.0: disabled optional hooks do not prompt, block, or mutate.
# ヘルパが読めないときも無音で抜けない — 検証不能として記録し、`.sh` の保存と確定した後で
# 判定不能の deny へ流す（兄弟の fail-open hook は exit 0 だが、本 hook は fail-closed 側）。
asdd_unverifiable=0
asdd_rc=0
case "${BASH_SOURCE[0]}" in
  */*) HOOK_DIR="${BASH_SOURCE[0]%/*}" ;;
  *) HOOK_DIR="." ;;
esac
if source "${HOOK_DIR}/asdd-hook-gate.sh" 2>/dev/null && [ "$(type -t asdd_hook_enabled 2>/dev/null)" = "function" ]; then
  # rc を読む（`|| exit 0` にしない）。0=有効 / 3=無効 / それ以外=検証不能。
  asdd_hook_enabled hooks
  asdd_rc=$?
  case "$asdd_rc" in
    0) : ;;
    3) exit 0 ;;
    *) asdd_unverifiable=1 ;;
  esac
else
  asdd_rc=helper-unavailable
  asdd_unverifiable=1
fi

[ "${FF_SHELL_SAVE_ACK:-0}" = "1" ] && exit 0

# 安価な前置フィルタ。`.sh` への保存でなければライブラリを読まずに通す
# （fail-closed の面を `.sh` の保存に限るため）。
case "$input" in
  *'.sh'*) : ;;
  *) exit 0 ;;
esac
command -v jq >/dev/null 2>&1 || exit 0

export LC_ALL=C
# 検出器のテストシーム（awk の差し替え）はセッション環境から継承させない。`FF_MBCS_AWK=true`
# のような値が残っていると走査が空出力 rc=0 になり「違反なし」と読まれる。抜け道は
# FF_SHELL_SAVE_ACK だけにする。
unset FF_MBCS_AWK FF_PIPEFAIL_GREP_Q_AWK FF_EXIT_CODE_AWK
LIB_DIR="${HOOK_DIR}/../tests/lib"
LIB_SHOWN="$LIB_DIR"
case "$LIB_SHOWN" in
  */hooks/../*) LIB_SHOWN="${LIB_SHOWN%%/hooks/../*}/${LIB_SHOWN#*/hooks/../}" ;;
esac

# deny の JSON を組み立てて出す。jq が失敗したら黙って許可に落ちず、exit 2 + stderr へ落とす
# （guard-exit-code.sh の「出力チャネル」節と同じ扱い）。
deny() { # <reason>
  local out rc
  out="$(jq -n --arg reason "$1" \
    '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "deny", permissionDecisionReason: $reason}}' 2>/dev/null)"
  rc=$?
  if [ "$rc" -ne 0 ] || [ -z "$out" ]; then
    printf '%s\n' "$1" >&2
    printf 'ff-dev-toolkit guard-shell-save: deny の JSON を組み立てられませんでした（jq rc=%s）。exit 2 でブロックします。\n' "$rc" >&2
    exit 2
  fi
  printf '%s\n' "$out"
  exit 0
}

deny_unavailable() { # <理由>
  deny "⚠️ ff-dev-toolkit guard（shell 保存時の静的検査）: **判定不能**のため保存を止めました（$1）。
対象: ${file_path:-（未取得）}
判定できないものを緑として通すと、このガードが止めようとしている失敗（検査したつもりの無検査）をガード自身が実演することになるため、ここは素通ししません。
検出器の置き場所: ${LIB_SHOWN}
次のいずれかで進めてください:
  1) 判定できる状態に戻す（検出器が読めない・awk / jq が壊れている場合はその環境を直す。配布物が壊れているならプラグインを再インストールする）
  2) このガードを素通しにする: hook の環境へ FF_SHELL_SAVE_ACK=1 を設定する（Write / Edit にはコマンド先頭の環境代入が無いため、ホストの env 設定か起動時の export で渡す）"
}

# ---- 入力の取り出し -------------------------------------------------------------
# 取り出す値は改行・末尾改行を含みうる。`$(…)` は末尾改行を落とすので、値の後ろへ番兵 `x` を
# 付けて取り出し、番兵が無ければ jq の失敗として扱う。
jq_field() { # <filter>
  local v rc
  v="$(printf '%s' "$input" | jq -j "$1" 2>/dev/null && printf x)"
  rc=$?
  JQ_VALUE="${v%x}"
  case "$v" in
    *x) return 0 ;;
  esac
  [ "$rc" -ne 0 ] || rc=1
  return "$rc"
}

# フィルタは実行時エラーを出さない形にする（`tool_input` が文字列・`file_path` が数値などでも
# 例外にならない）。jq は parse 失敗と実行時エラーをどちらも rc=5 で返すため、実行時エラーが
# 起きうる形だと「JSON でない」と同じ fail-open へ紛れる。
jq_field '((.tool_name // "") | tostring) + "\n" + (((.tool_input | objects | .file_path) // "") | tostring)'
jq_rc=$?
if [ "$jq_rc" -ne 0 ]; then
  # rc=5 は「入力が JSON として読めない」= 設計上の fail-open。
  [ "$jq_rc" -eq 5 ] && exit 0
  file_path=""
  deny_unavailable "入力を取り出せませんでした（jq rc=${jq_rc}）"
fi
nl='
'
tool_name="${JQ_VALUE%%"$nl"*}"
file_path="${JQ_VALUE#*"$nl"}"
case "$tool_name" in
  Write|Edit) : ;;
  *) exit 0 ;;
esac
case "$file_path" in
  *.sh) : ;;
  *) exit 0 ;;
esac

if [ "$asdd_unverifiable" -eq 1 ]; then
  deny_unavailable "ASDD 設定を検証できません（asdd_hook_enabled rc=${asdd_rc}。.asdd/config.json があるのに node が無い・設定を読めない等）"
fi

# 保存前の内容（無ければ空）。
# `read -d ''` は NUL で止まるので、読めた長さを実ファイルのバイト数と突き合わせる
# （食い違い = 全体を読めていない）。
before=""
before_readable=1
if [ -e "$file_path" ]; then
  if [ -f "$file_path" ] && [ -r "$file_path" ]; then
    IFS= read -r -d '' before < "$file_path" || true
    size="$(wc -c < "$file_path" 2>/dev/null)" || size=""
    size="${size//[!0-9]/}"
    if [ -z "$size" ] || [ "$size" -ne "${#before}" ]; then
      before_readable=0
    fi
  else
    before_readable=0
  fi
fi

# 保存後の内容を組み立てる。
if [ "$tool_name" = "Write" ]; then
  jq_field '((.tool_input | objects | .content) // "") | tostring' || deny_unavailable "content を取り出せませんでした（jq rc=$?）"
  after="$JQ_VALUE"
else
  jq_field '((.tool_input | objects | .old_string) // "") | tostring' || deny_unavailable "old_string を取り出せませんでした（jq rc=$?）"
  old="$JQ_VALUE"
  jq_field '((.tool_input | objects | .new_string) // "") | tostring' || deny_unavailable "new_string を取り出せませんでした（jq rc=$?）"
  new="$JQ_VALUE"
  jq_field 'if (.tool_input | objects | .replace_all) == true then "1" else "0" end' || deny_unavailable "replace_all を取り出せませんでした（jq rc=$?）"
  replace_all="$JQ_VALUE"
  [ -e "$file_path" ] || [ -z "$old" ] || exit 0
  [ "$before_readable" -eq 1 ] || deny_unavailable "Edit の対象ファイルを全体として読めないため（読み取り不可、または NUL を含む）、保存後の全体を組み立てられません"
  if [ -z "$old" ]; then
    # 空の old_string は新規作成・空ファイルへの書き込み。空でないファイルへの空 old_string は
    # Edit ツール自体が失敗する（保存は起きない）。
    [ -z "$before" ] || exit 0
    old_found=1
  else
    old_found=0
    case "$before" in
      *"$old"*) old_found=1 ;;
    esac
    if [ "$old_found" -eq 0 ]; then
      # Edit ツールは CRLF / LF の差を吸収して一致させる。同じ正規化（CR の除去）を 3 者へ
      # 当てて再照合し、以降の走査も正規化後の内容で行う（CR は検出器の判定に影響しない）。
      cr="$(printf '\r')"
      case "${before}${old}" in
        *"$cr"*)
          before="${before//"$cr"/}"
          old="${old//"$cr"/}"
          new="${new//"$cr"/}"
          case "$before" in
            *"$old"*) old_found=1 ;;
          esac
          ;;
      esac
    fi
    if [ "$old_found" -eq 0 ]; then
      # バイト一致しない old_string でも、Edit ツールは引用符の正規化（曲引用符 ↔ 直引用符）で
      # 一致させて保存することがある。その対応をバイト列の上で再現すると引用符の意味（検出器の
      # マスク）を変えてしまうので、ここは素通しせず判定不能として止める。
      deny_unavailable "old_string が現在の内容にバイト一致しません（Edit ツールが引用符などを正規化して一致させる場合、保存後の全体を同じ形で組み立てられません）。ファイルの現在の内容から old_string を写し直してください"
    fi
  fi
  # `${before/"$old"/"$new"}` は使わない。bash 3.2 は置換側の二重引用符を文字として残し
  # （実測: 置換結果が `"new"` になる）、5.2 は引用符を外すと patsub_replacement で `&` を
  # 一致文字列へ展開する。先頭一致の前後を切り出して繋ぐ形はどちらの版でも字義どおりになる。
  after=""
  rest="$before"
  [ -n "$old" ] || { after="$new"; rest=""; }
  while [ -n "$old" ]; do
    case "$rest" in
      *"$old"*) : ;;
      *) break ;;
    esac
    after="${after}${rest%%"$old"*}${new}"
    rest="${rest#*"$old"}"
    [ "$replace_all" = "1" ] || break
  done
  after="${after}${rest}"
fi
[ "$before_readable" -eq 1 ] || before=""

# ---- 判定（3 ライブラリの再利用） ------------------------------------------------

load_lib() { # <file> <function>
  local f="${LIB_DIR}/$1"
  [ -f "$f" ] && [ -r "$f" ] || deny_unavailable "検出器 $1 が無いか読めません"
  # shellcheck disable=SC1090
  . "$f" 2>/dev/null || deny_unavailable "検出器 $1 の読み込みに失敗しました"
  [ "$(type -t "$2" 2>/dev/null)" = "function" ] || deny_unavailable "検出器 $1 に $2 がありません"
}
load_lib mbcs-guard.sh mbcs_scan
load_lib pipefail-grep-q.sh pipefail_grep_q_scan
load_lib exit-code-guard.sh exit_code_scan

# 1 つの検出器を保存前 / 保存後に当て、保存前に無かった違反だけを「開始行:鍵」で返す。
# 鍵は開始行を落とした残り（mbcs は論理行、他の 2 つは「タグ:論理行」）。
new_hits() { # <function>
  local fn="$1" pre post rc out
  pre="$(printf '%s' "$before" | "$fn" 2>/dev/null)"
  rc=$?
  [ "$rc" -eq 0 ] || deny_unavailable "${fn} の走査（保存前）が失敗しました（rc=${rc}）"
  post="$(printf '%s' "$after" | "$fn" 2>/dev/null)"
  rc=$?
  [ "$rc" -eq 0 ] || deny_unavailable "${fn} の走査（保存後）が失敗しました（rc=${rc}）"
  [ -n "$post" ] || return 0
  out="$(awk '
    NR == FNR { if ($0 != "") { k = $0; sub(/^[0-9]+:/, "", k); seen[k]++ }; next }
    $0 == "" { next }
    !/^[0-9]+:/ { bad = 1; next }
    { k = $0; sub(/^[0-9]+:/, "", k); if (seen[k] > 0) { seen[k]--; next }; print }
    END { if (bad) exit 3 }
  ' <(printf '%s\n' "$pre") <(printf '%s\n' "$post") 2>/dev/null)"
  rc=$?
  if [ "$rc" -eq 3 ]; then
    deny_unavailable "${fn} の出力を解釈できませんでした（期待する形式: 開始行:…）"
  fi
  [ "$rc" -eq 0 ] || deny_unavailable "${fn} の新規違反の突き合わせ（awk）が失敗しました（rc=${rc}）"
  printf '%s' "$out"
}

mbcs_hits="$(new_hits mbcs_scan)" || exit "$?"
pipefail_hits="$(new_hits pipefail_grep_q_scan)" || exit "$?"
exit_hits="$(new_hits exit_code_scan)" || exit "$?"

# new_hits の中の deny はサブシェルで走るので、stdout に JSON が出ていればそれをそのまま返す。
for h in "$mbcs_hits" "$pipefail_hits" "$exit_hits"; do
  case "$h" in
    '{'*'"permissionDecision"'*) printf '%s\n' "$h"; exit 0 ;;
  esac
done

[ -n "${mbcs_hits}${pipefail_hits}${exit_hits}" ] || exit 0

# ---- deny 本文（実値で案内する。各検出器とも先頭 3 件まで） ---------------------

first3() { printf '%s\n' "$1" | awk 'NF && n < 3 { print "    | " $0; n++ }'; }

reason="⚠️ ff-dev-toolkit guard（shell 保存時の静的検査）: 保存しようとしている ${file_path} に、保存前には無かった違反が入ります。保存前に直してください（全件ゲートの横断メタ検査が同じ検出器で赤にします）。"
if [ -n "$mbcs_hits" ]; then
  reason="${reason}

■ \$VAR 直後のマルチバイト（tests/lib/mbcs-guard.sh / OBS-042）
bash 3.2 と一部のロケールは、\$VAR の直後のマルチバイト文字の先頭バイトを変数名に取り込みます（set -u 下では unbound variable で落ち、それ以外では空に展開されます）。変数を \${VAR} 形で書いてください（例: \$rc の直後に全角の閉じ括弧を続けるなら \${rc} と書く）。
$(first3 "$mbcs_hits")"
fi
if [ -n "$pipefail_hits" ]; then
  reason="${reason}

■ pipefail 配下の | grep -q（tests/lib/pipefail-grep-q.sh）
grep -q は一致した時点で読むのをやめ、上流の printf / echo / cat が EPIPE で死ぬと pipefail が一致を不一致へ反転させます。grep -q <<<\"\$s\"（here-string）/ case / ファイルを直接 grep -q へ渡す形へ書き換えてください。payload が原理的に小さいことが自明な行だけ、その論理行の行末へ「# pipefail-safe: <根拠>」を書いて除外できます。
$(first3 "$pipefail_hits")"
fi
if [ -n "$exit_hits" ]; then
  reason="${reason}

■ 終了コードの誤読・握り潰し（tests/lib/exit-code-guard.sh / OBS-003）
出力整形フィルタ（head / tail / cat / tee / wc 等）で終わるパイプの直後の \$? はフィルタの終了コードです。PIPESTATUS は zsh では機能しません。ゲート起動を ; / || / パイプで終端すると成否が消えます。出力をファイルへ受けてから rc=\$? で受け、exit \$rc まで書いて伝播させてください。
$(first3 "$exit_hits")"
fi
reason="${reason}

（行頭の数字は保存後のファイルの開始行。判定の正本は ${LIB_SHOWN} の 3 ライブラリで、この hook は判定を持ちません）
どうしてもこの形で保存する必要がある場合は、hook の環境へ FF_SHELL_SAVE_ACK=1 を設定してください（Write / Edit にはコマンド先頭の環境代入が無いため、ホストの env 設定か起動時の export で渡します）。"

deny "$reason"
