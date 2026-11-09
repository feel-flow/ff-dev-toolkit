# shellcheck shell=bash
# 振る舞いの表（tests/l4-declarations/verify.sh の N10〜N12）の fixture が使う道具。
#
# verify.sh は 1 回の起動ごとに env -i で新しい /bin/bash を立て、このファイル → fixture の順に
# source してから fx_setup / fx_run / fx_judge（ACK の fixture は fx_input も）を呼ぶ。環境に残るのは
# HOME / PATH / LANG / TMPDIR と次の小文字の変数、それに表の行が足す宣言（FF_DEV_TOOLKIT_SKIP=<鍵>・
# 旧名・ACK の名前）だけで、利用者の環境の宣言は表に混ざらない。
#   fx_wk      この起動の作業ディレクトリ（HOME と TMPDIR もこの中。起動ごとに新しい）
#   fx_plugin  プラグイン root（plugins/ff-dev-toolkit）
#   fx_root    リポジトリ root
#
# fixture の書き方（skip/<鍵>.sh・ack/<鍵>.sh・notice/<鍵>.sh。1 ファイル 1 鍵）:
#   fx_owners='<owner> …'  名簿の owner 列と同じ集合を空白区切りの単引用リテラルで書く（verify.sh が照合する）
#   fx_setup               入力・一時リポジトリ・stub を作業ディレクトリの中に作る（ネットワークを使わない）
#   fx_run                 owner を起動する。stdout を out、stderr を err、rc を rc（どれも作業ディレクトリ）に置く
#   fx_judge               skip / notice: 「STOP <根拠>」（ガード・通知・記録が効いた）か「PASS <根拠>」
#                          （素通し）を 1 行出す。それ以外の語で始まる行は判定不能として表が赤にする
#   fx_forms='<形> …'      ack だけ: 前置の形の一覧。hookenv は hook の環境に置く形、それ以外は区間の先頭の前置
#   fx_input <形>          ack だけ: 変数 fx_ack_prefix（`<名前>=1 ` か空）を前置した入力を in.json に書く
# 関数・変数は fx_ で始める（verify.sh と他の fixture の名前を壊さない）。

fx_bash_input() { # <command> <cwd> [<tool_input へ足す JSON>] — PreToolUse(Bash) の stdin を stdout へ
  local fx_x="${3-}"
  [ -n "$fx_x" ] || fx_x='{}'
  jq -nc --arg c "$1" --arg d "$2" --argjson x "$fx_x" \
    '{hook_event_name: "PreToolUse", tool_name: "Bash", tool_input: ({command: $c} + $x), cwd: $d, session_id: "l4-table"}'
}

fx_session_start() { # SessionStart の stdin を in.json へ
  printf '%s\n' '{"hook_event_name":"SessionStart","source":"startup","session_id":"l4-table"}' > "$fx_wk/in.json"
}

fx_git_repo() { # <dir> — 空のコミットが 1 つある main ブランチのリポジトリ（identity は試験の合成値）
  # 初期化と identity は試験の共通の道具 tests/lib/git-fixture.sh で行う（呼び出し元のリポジトリへ identity が
  # 漏れる経路を塞いだ初期化）。初期ブランチは master なので、最初のコミットの前に main へ付け替える。
  # 読み込みは呼ばれたときだけ行う（selftest の合成 root はこの道具を持たず、この関数も呼ばない）
  # shellcheck source=../../lib/git-fixture.sh
  . "${BASH_SOURCE[0]%/*}/../../lib/git-fixture.sh" || return 1
  ff_git_fixture_init "$1" || return 1
  git -C "$1" symbolic-ref HEAD refs/heads/main || return 1
  git -C "$1" commit -q --allow-empty -m init
}

fx_dirty_repo() { # <dir> — コミット済みの dirty.txt に未コミットの変更がある
  fx_git_repo "$1" || return 1
  printf 'a\n' > "$1/dirty.txt"
  git -C "$1" add dirty.txt && git -C "$1" commit -q -m dirty || return 1
  printf 'b\n' > "$1/dirty.txt"
}

fx_lock_repo() { # <dir> — レビュー走行中ロックを持つリポジトリ（pid はこの起動のシェル = owner の起動中は生存）
  fx_git_repo "$1" || return 1
  # 出力先の準備は配布物の関数で行う（ロックの置き場所の規則を fixture へ複製しない）
  ( . "$fx_plugin/scripts/lib/multi-agent-boundary.sh" && ff_review_output_prepare "$1" "$1/.review-results" false review ) > /dev/null 2>&1 || return 1
  printf 'pid=%s\ntask=review\nhead=abcdef1234567890\nstarted=2026-11-09T00:00:00Z\nstarted_epoch=%s\nperspectives=code-review\n' \
    "$$" "$(($(date -u +%s) - 42))" > "$1/.review-results/.review-in-flight"
  printf 'x\n' > "$1/README.md"
}

fx_hook() { # <owner（プラグイン root 相対）> [<stdin のファイル>] — 起動して out / err / rc を置く
  /bin/bash "$fx_plugin/$1" < "${2:-$fx_wk/in.json}" > "$fx_wk/out" 2> "$fx_wk/err"
  echo "$?" > "$fx_wk/rc"
}

fx_decision() { # [<出力のファイル>] — permissionDecision（出力が空・欄が無いは none、JSON でないは unparsable）
  local fx_o="${1:-$fx_wk/out}" fx_d
  [ -s "$fx_o" ] || { echo none; return 0; }
  fx_d="$(jq -r '.hookSpecificOutput.permissionDecision // "none"' < "$fx_o" 2>/dev/null)" || fx_d=unparsable
  printf '%s\n' "${fx_d:-none}"
}

fx_rc() { cat "${1:-$fx_wk/rc}" 2>/dev/null || echo '?'; }

fx_judge_deny() { # rc 0 かつ deny → STOP / rc 0 かつ deny でない → PASS / それ以外 → ERROR
  local fx_r fx_d
  fx_r="$(fx_rc)"
  fx_d="$(fx_decision)"
  if [ "$fx_r" != 0 ]; then echo "ERROR rc=${fx_r}・decision=${fx_d}"; return 0; fi
  case "$fx_d" in
    deny) echo "STOP permissionDecision=deny" ;;
    unparsable) echo "ERROR stdout が JSON でない" ;;
    *) echo "PASS permissionDecision=${fx_d}・stdout $(wc -c < "$fx_wk/out" | tr -d ' ') バイト" ;;
  esac
}

fx_judge_notice() { # SessionStart の通知: rc 0 かつ systemMessage と additionalContext の JSON → STOP / rc 0 かつ無出力 → PASS
  local fx_r
  fx_r="$(fx_rc)"
  [ "$fx_r" = 0 ] || { echo "ERROR rc=${fx_r}"; return 0; }
  if [ ! -s "$fx_wk/out" ]; then echo "PASS 無出力"; return 0; fi
  if jq -e '(.systemMessage | type == "string") and (.hookSpecificOutput.additionalContext | type == "string")' < "$fx_wk/out" > /dev/null 2>&1; then
    echo "STOP 通知の JSON を出した"
  else
    echo "ERROR 出力はあるが通知の JSON でない: $(head -c 120 "$fx_wk/out" | tr '\n' ' ')"
  fi
}

fx_lines() { # <ファイル> — 空でない行の数（ファイルが無ければ 0）
  if [ -f "$1" ]; then grep -c . "$1" || true; else echo 0; fi
}
