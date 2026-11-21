# shellcheck shell=bash
# Sourced by verify.sh after windows-acl.sh (Issue `#2648`). When the reader refuses the root of the
# lookup by an ACL verdict that names a place, knowledge-lookup.sh keeps the reader's lines and ends
# stderr with the common stop block (scripts/lib/stop-block.sh): a worktree in a place that passes the
# same check. The stub Windows of windows-acl-fixture.sh drives the real script on every platform; the
# printed command is run as printed. The caller provides ok / bad / TMP / TARGET / PLUGIN_ROOT / ROOT1,
# win_run and the git fixture helper.
guide_runs_before="$win_runs"
guide_lookup='env -u FF_DEV_TOOLKIT_ROOT -u CLAUDE_PLUGIN_ROOT -u GROK_PLUGIN_ROOT -u FF_DEV_TOOLKIT_SKILL_FILE -u ACE_PLAYBOOK_PATH bash "$GUIDE_TARGET" --root "$GUIDE_ROOT" --offline hydration'
# The script names its own running copy first (one ℹ️ line, by the plugin-root guard); the checks compare the rest.
guide_run() { win_run "$@"; guide_err="$(printf '%s\n' "$win_err" | awk 'NR == 1 && /^ℹ️ / { next } { print }')"; }
guide_quote="'"
guide_word() { printf "'%s'" "${1//$guide_quote/$guide_quote\\$guide_quote$guide_quote}"; } # the spelling the script must print
guide_command() { printf '%s\n' "$guide_err" | sed -n 's/^次の一手: \(git -C .*\) を実行し.*/\1/p'; }
guide_reason() { printf '止めた規則: knowledge-read-boundary（scripts/lib/knowledge-read-boundary.sh）— 読み取る対象の祖先 %s が読み取り境界の検査を通らないため、知見を読んでいません（境界は緩めません）' "$1"; }
guide_generic='次の一手: 本人・管理者・SYSTEM だけが変更できるフォルダーへ対象のリポジトリの worktree（または写し）を置き、そこを cwd（--root）にして同じ操作をやり直す'

mkdir -p "$win_root/gx"
guide_base="$(cd -P "$win_root/gx" && pwd -P)"
# A quote and a space: the printed command must still be one runnable line. On Git Bash the stub cygpath
# leaves the POSIX spelling, and Git Bash does not convert an argument that holds a quote, so git.exe could
# not even create the fixture there; that host keeps the space only (win_msys comes from windows-acl.sh).
guide_name="re'po 1"
[[ "${win_msys:-no}" != yes ]] || guide_name='repo 1'
guide_root="$guide_base/$guide_name"
guide_plain="$guide_base/plain"
mkdir -p "$guide_plain"
guide_head=""
if ff_git_fixture_init "$guide_root" >/dev/null 2>&1 \
  && git -C "$guide_root" commit -q --allow-empty -m fixture >/dev/null 2>&1; then
  guide_head="$(git -C "$guide_root" rev-parse HEAD 2>/dev/null)" || guide_head=""
fi
guide_target="$win_state/wt/$guide_name"

if [[ -z "$guide_head" ]]; then
  bad 'G1〜G12: 案内の fixture（commit を 1 つ持つリポジトリ）を作れない（検査不成立）'
else
  win_env=("GUIDE_TARGET=$TARGET" "GUIDE_ROOT=$guide_root")
  guide_run "$guide_lookup" "$guide_root"
  guide_expected="knowledge-read: read-unverifiable
knowledge-read: 止めた場所: ${guide_root} — 本人・管理者・SYSTEM 以外が書き込める（S-1-15-3-1024-2461）
止めた層: 環境
$(guide_reason "$guide_root")
次の一手: git -C $(guide_word "$guide_root") worktree add -f --detach $(guide_word "$guide_target") ${guide_head} を実行し、その worktree を cwd（--root）にして同じ操作をやり直す（コミット済みの内容だけが写る。/ace-curate・/retrospective の書き込みも同じ worktree で続ける。不要になったら git worktree remove）"
  [[ "$win_rc" -eq 2 && -z "$win_out" && "$guide_err" == "$guide_expected" ]] \
    && ok 'G1: root の祖先を ACL の判定で止めたとき、境界の 2 行をそのまま通し、stderr の末尾 3 行を停止文の共通形（安全な置き場へ worktree を作るコマンド）で終え、stdout には何も出さない' \
    || bad "G1: 停止文の共通形が付かない、境界の行が変わった、または stdout へ出た（rc=${win_rc} out=${win_out} err=${win_err}）"
  guide_rc=0; guide_cmd="$(guide_command)"
  [[ -n "$guide_cmd" ]] && ( eval "$guide_cmd" ) >/dev/null 2>&1 || guide_rc=$?
  [[ "$guide_rc" -eq 0 && "$(git -C "$guide_target" rev-parse HEAD 2>/dev/null)" == "$guide_head" ]] \
    && ok "G2: 出したコマンドは、空白や引用符を含むパス（この回の名前: ${guide_name}）でもそのまま実行でき、同じ commit の worktree が置き場にできる" \
    || bad "G2: 出したコマンドをそのまま実行できない（rc=${guide_rc} cmd=${guide_cmd}）"

  # The root moves on before the second stop, so the switch has a commit to move to.
  git -C "$guide_root" commit -q --allow-empty -m second >/dev/null 2>&1 || true
  guide_first="$guide_head"; guide_head="$(git -C "$guide_root" rev-parse HEAD 2>/dev/null)" || guide_head=""
  win_env=("GUIDE_TARGET=$TARGET" "GUIDE_ROOT=$guide_root")
  guide_run "$guide_lookup" "$guide_root"
  guide_rc=0; guide_cmd="$(guide_command)"
  [[ -n "$guide_head" && "$guide_head" != "$guide_first" && "$guide_cmd" == "git -C $(guide_word "$guide_target") switch --detach ${guide_head}" ]] && ( eval "$guide_cmd" ) >/dev/null 2>&1 || guide_rc=$?
  [[ "$win_rc" -eq 2 && "$guide_rc" -eq 0 && "$(git -C "$guide_target" rev-parse HEAD 2>/dev/null)" == "$guide_head" \
    && "$guide_err" == *'を実行し（前に作った worktree を同じ commit へ合わせる）、その worktree を cwd（--root）にして'* ]] \
    && ok 'G3: 前に作った worktree が置き場に残っている 2 回目は、作り直しではなく、その worktree を root の今の commit へ合わせるコマンドを出す（実行すると commit が進む）' \
    || bad "G3: 2 回目の発生で通らないコマンドを出した（rc=${win_rc} guide_rc=${guide_rc} cmd=${guide_cmd} err=${win_err}）"

  # Without --root the script resolves the project from the cwd (the form /ace-curate and /ace-refine call).
  win_env=("GUIDE_TARGET=$TARGET" "GUIDE_ROOT=$guide_root")
  guide_run "cd \"\$GUIDE_ROOT\" && ${guide_lookup/ --root \"\$GUIDE_ROOT\"/}" "$guide_root"
  [[ "$win_rc" -eq 2 && -z "$win_out" && "$(guide_command)" == "git -C $(guide_word "$guide_target") switch --detach ${guide_head}" \
    && "$guide_err" == *"$(guide_reason "$guide_root")"* ]] \
    && ok 'G10: --root を渡さず cwd から解決した回（/ace-curate の入口の形）も、同じ停止文と同じコマンドで終える' \
    || bad "G10: --root 無しの経路で案内が出ない（rc=${win_rc} out=${win_out} err=${win_err}）"

  # --root below the top of the repository: the worktree holds the top, so the guide names the same subdirectory in it.
  mkdir -p "$guide_root/docs kb"
  win_env=("GUIDE_TARGET=$TARGET" "GUIDE_ROOT=$guide_root/docs kb")
  guide_run "$guide_lookup" "$guide_root"
  [[ "$win_rc" -eq 2 && "$(guide_command)" == "git -C $(guide_word "$guide_target") switch --detach ${guide_head}" \
    && "$guide_err" == *"、その worktree の下の 'docs kb' を cwd（--root）にして"* ]] \
    && ok 'G11: --root がリポジトリの下位ディレクトリのときは、worktree の中の同じ下位ディレクトリを cwd（--root）として名指す' \
    || bad "G11: 下位ディレクトリの root で、worktree の最上位を指した（rc=${win_rc} err=${win_err}）"

  # The folder is gone but its registration stays (removed without git worktree remove): plain add is refused by git.
  rm -rf -- "$guide_target"
  win_env=("GUIDE_TARGET=$TARGET" "GUIDE_ROOT=$guide_root")
  guide_run "$guide_lookup" "$guide_root"
  guide_rc=0; guide_cmd="$(guide_command)"
  [[ "$guide_cmd" == "git -C $(guide_word "$guide_root") worktree add -f --detach $(guide_word "$guide_target") ${guide_head}" ]] && ( eval "$guide_cmd" ) >/dev/null 2>&1 || guide_rc=$?
  [[ "$win_rc" -eq 2 && "$guide_rc" -eq 0 && "$(git -C "$guide_target" rev-parse HEAD 2>/dev/null)" == "$guide_head" ]] \
    && ok 'G12: フォルダーだけ消されて登録が残った前の worktree でも、出したコマンド（add -f）はそのまま通る' \
    || bad "G12: 登録だけ残った worktree で通らないコマンドを出した（rc=${win_rc} guide_rc=${guide_rc} cmd=${guide_cmd} err=${win_err}）"

  git -C "$guide_root" worktree remove --force "$guide_target" >/dev/null 2>&1 || true
  rm -rf -- "$guide_target"; mkdir -p "$guide_target"
  win_env=("GUIDE_TARGET=$TARGET" "GUIDE_ROOT=$guide_root" "GIT_CEILING_DIRECTORIES=$win_root")
  guide_run "$guide_lookup" "$guide_root"
  [[ "$win_rc" -eq 2 && "$(guide_command)" == "git -C $(guide_word "$guide_root") worktree add -f --detach $(guide_word "${guide_target}-2") ${guide_head}" ]] \
    && ok 'G4: 同じ名前の場所が、この commit を持たない別物で埋まっているときは、番号を付けた隣を名指す（別物へ switch させない）' \
    || bad "G4: 別物が置かれた名前を避けない（rc=${win_rc} cmd=$(guide_command) err=${win_err}）"

  win_env=("GUIDE_TARGET=$TARGET" "GUIDE_ROOT=$guide_root")
  guide_run "$guide_lookup" "$guide_root" "$win_state"
  [[ "$win_rc" -eq 2 && -z "$(guide_command)" && "$guide_err" == *"止めた場所: ${guide_root} — "*"止めた場所: ${win_state} — "*"knowledge-read: 既定の置き場 ${win_state}/wt も同じ検査を通りません（上の行が理由）"* \
    && "$(printf '%s\n' "$guide_err" | tail -n 3)" == "止めた層: 環境
$(guide_reason "$guide_root")
${guide_generic}" ]] \
    && ok 'G5: 既定の置き場も同じ検査を通らないときは、その場所を約束せず、両方の止めた場所を名指して、置き場の条件だけを次の一手にする' \
    || bad "G5: 検査を通らない置き場を名指した（rc=${win_rc} err=${win_err}）"

  win_env=("GUIDE_TARGET=$TARGET" "GUIDE_ROOT=$guide_plain" "GIT_CEILING_DIRECTORIES=$win_root")
  guide_run "$guide_lookup" "$guide_plain"
  [[ "$win_rc" -eq 2 && -z "$win_out" && "$(printf '%s\n' "$guide_err" | tail -n 3)" == "止めた層: 環境
$(guide_reason "$guide_plain")
${guide_generic}" ]] \
    && ok 'G6: git リポジトリでない root を止めたときは、通らない git コマンドを出さず、置き場の条件だけを次の一手にする' \
    || bad "G6: リポジトリでない root へ git コマンドを案内した（rc=${win_rc} err=${win_err}）"

  # A refusal that names no place (the helper could not judge) gains nothing: the guide is for the ACL verdict only.
  win_error="$guide_root"
  win_env=("GUIDE_TARGET=$TARGET" "GUIDE_ROOT=$guide_root")
  guide_run "$guide_lookup"
  [[ "$win_rc" -eq 2 && -z "$win_out" && "$guide_err" == $'knowledge-read: read-unverifiable\nknowledge-read: 判定できない: Unverified path type' ]] \
    && ok 'G7: 場所の名指しが無い拒否（helper が判定できない）には停止文も worktree の案内も足さない' \
    || bad "G7: 場所の名指しが無い拒否へ案内を足した（rc=${win_rc} out=${win_out} err=${win_err}）"

  # Positive control: a root that passes is read as before, with no stop block.
  win_env=("GUIDE_TARGET=$TARGET" "GUIDE_ROOT=$ROOT1")
  guide_run "$guide_lookup"
  [[ "$win_rc" -eq 0 && "$win_out" == *'RECORD ace='* && "$guide_err" != *'止めた層:'* && "$guide_err" != *'knowledge-read:'* ]] \
    && ok 'G8: 検査を通る root（陽性の対照）は、stub の Windows でも従来どおり検索結果を返し、停止文を出さない' \
    || bad "G8: 検査を通る root で検索が成立しない、または停止文が出た（rc=${win_rc} err=${win_err}）"

  # The common form is unreadable: the script still ends with three lines of that form.
  mkdir -p "$win_root/copy/scripts"
  cp "$TARGET" "$win_root/copy/scripts/" && cp -R "$PLUGIN_ROOT/scripts/lib" "$win_root/copy/scripts/" && rm -f "$win_root/copy/scripts/lib/stop-block.sh"
  win_env=("GUIDE_TARGET=$win_root/copy/scripts/knowledge-lookup.sh" "GUIDE_ROOT=$guide_root")
  guide_run "$guide_lookup" "$guide_root"
  [[ "$win_rc" -eq 2 && "$(printf '%s\n' "$guide_err" | tail -n 3)" == '止めた層: 環境
止めた規則: stop-block-unavailable（scripts/lib/stop-block.sh）— 停止文の共通形を読み込めません（元の規則: knowledge-read-boundary）
次の一手: ff-dev-toolkit を更新・再インストールして scripts/lib/stop-block.sh を復旧する' ]] \
    && ok 'G9: stop-block.sh を読めない配布物でも、stop-block-unavailable の 3 行で止まる（黙って素の拒否へ戻さない）' \
    || bad "G9: 停止文の共通形を読めない回の 3 行が無い（rc=${win_rc} err=${win_err}）"
fi

# Every case ran: a dropped or emptied case must not leave the file green on what is left.
if [[ "$((win_runs - guide_runs_before))" -eq 11 ]]; then
  ok '案内（G1〜G12）の合成 case 11 回を実行した'
  guide_checks_finished=1
else
  bad "案内の case が欠落・空（expected=11 actual=$((win_runs - guide_runs_before))）"
fi
