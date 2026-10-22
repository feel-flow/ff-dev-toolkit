#!/usr/bin/env bash
# finish/verify.sh から呼ぶ、生成 MERGE_COMMAND の real Git 回帰検査。
# gh の merge 成否だけを stub にし、ref の照会・lease 削除・拒否・race は bare Git で測る。

_ff_finish_merge_delete_cases() {
  local e_dir="$TMP/merge-delete" e_work e_origin e_decoy_origin e_decoy e_hooks e_ref
  local e_head e_alt e_json e_cmd e_case e_cases e_rows=0 e_rc e_after e_pushes e_expected_rc e_expected_ref e_expected_pushes
  local e_output e_log e_restore_root e_precheck_rc e_upload_pack e_upload_command e_result
  local e_message e_context e_run_cwd e_inherited_repo e_inherited_host e_pin_rows=0 e_host_rows=0
  e_work="$e_dir/consumer It's 日本語"
  e_origin="$e_dir/origin.git"
  e_decoy_origin="$e_dir/toolkit-origin.git"
  e_decoy="$e_dir/toolkit-checkout"
  e_hooks="$e_dir/hooks"
  e_ref='refs/heads/feature/引用-It'"'"'s-$HOME-`x`-;semi'
  mkdir -p "$e_dir" "$e_hooks" "$e_dir/bin"
  g init -q --bare "$e_origin"
  ff_git_fixture_init "$e_work"
  g -C "$e_work" checkout -q -B develop
  printf 'seed\n' >"$e_work/seed.txt"
  g -C "$e_work" add seed.txt
  g -C "$e_work" commit -qm seed
  g -C "$e_work" remote add origin "$e_origin"
  g -C "$e_work" push -q origin develop
  g -C "$e_work" checkout -q -b "${e_ref#refs/heads/}"
  printf 'head\n' >"$e_work/head.txt"
  g -C "$e_work" add head.txt
  g -C "$e_work" commit -qm 'feat: fixture head'
  g -C "$e_work" push -q -u origin "${e_ref#refs/heads/}"
  e_head="$(g -C "$e_work" rev-parse HEAD)"
  e_alt="$(printf 'alternate\n' | g -C "$e_work" commit-tree HEAD^{tree} -p "$e_head")"
  g -C "$e_work" push -q origin "$e_alt:refs/heads/fixture-alternate"
  g -C "$e_work" remote set-head origin develop
  g -C "$e_work" worktree add -q "$e_dir/held-develop" develop
  g clone -q --bare "$e_origin" "$e_decoy_origin"
  g clone -q "$e_decoy_origin" "$e_decoy"
  g -C "$e_work" config --local core.hooksPath "$e_hooks"
  g --git-dir="$e_origin" config --local core.hooksPath "$e_dir/remote-hooks"
  mkdir -p "$e_dir/remote-hooks"

  # refs の変更は Git の hook 内で実際に行う。pre-push は照会後、push 受信前に走る。
  cat >"$e_hooks/pre-push" <<'HOOK'
#!/usr/bin/env bash
set -eu
printf '%s|%s\n' "${SKIP_SIMPLE_GIT_HOOKS-unset}" "${HUSKY-unset}" >>"$E_DELETE_LOG.push"
cat >>"$E_DELETE_LOG.refs"
case "$E_DELETE_CASE" in
  race-missing) env -u GIT_DIR -u GIT_WORK_TREE git --git-dir="$E_DELETE_ORIGIN" update-ref -d "$E_DELETE_REF" "$E_DELETE_HEAD" ;;
  race-changed) env -u GIT_DIR -u GIT_WORK_TREE git --git-dir="$E_DELETE_ORIGIN" update-ref "$E_DELETE_REF" "$E_DELETE_ALT" "$E_DELETE_HEAD" ;;
esac
HOOK
  cat >"$e_dir/remote-hooks/pre-receive" <<'HOOK'
#!/usr/bin/env bash
set -eu
while read -r old new ref; do
  printf '%s %s %s\n' "$old" "$new" "$ref" >>"$E_DELETE_LOG.receive"
  if [ "$E_DELETE_CASE" = reject-delete ] && [ "$new" = 0000000000000000000000000000000000000000 ]; then
    echo 'fixture: reject deletion' >&2
    exit 1
  fi
done
HOOK
  cat >"$e_dir/bin/gh" <<'GH'
#!/usr/bin/env bash
set -eu
[ "${1:-} ${2:-}" = 'pr merge' ] || { echo 'fixture: expected pr merge' >&2; exit 91; }
printf '%s\n' "$*" >>"$E_DELETE_LOG.gh"
shift 2
[ "${1:-}" = "$E_DELETE_PRN" ] || { echo 'fixture: unexpected PR number' >&2; exit 92; }
shift
selected_repo=''; selected_source=''; match_head=''
while [ "$#" -gt 0 ]; do
  case "$1" in
    --repo|-R) selected_repo="$2"; selected_source=explicit; shift 2 ;;
    --match-head-commit) match_head="$2"; shift 2 ;;
    --subject|--body) shift 2 ;;
    *) shift ;;
  esac
done
[ "$match_head" = "$E_DELETE_HEAD" ] || { echo 'fixture: unexpected head OID' >&2; exit 93; }
if [ -z "$selected_repo" ]; then
  if [ -n "${GH_REPO:-}" ]; then
    selected_repo="$GH_REPO"; selected_source=env
  elif [ "$(git rev-parse --show-toplevel)" = "$(git -C "$E_DELETE_WORK" rev-parse --show-toplevel)" ]; then
    selected_repo=https://github.com/owner/repo; selected_source=cwd
  else
    selected_repo=https://mirror.example.test/owner/repo; selected_source=cwd
  fi
fi
# ghrepo.FromFullName: URL/HOST/OWNER/REPO はhostを持ち、OWNER/REPOだけがDefaultHostへ委ねる。
case "$selected_repo" in
  http://*|https://*) selected_identity="${selected_repo#*://}"; selected_host="${selected_identity%%/*}"; selected_nwo="${selected_identity#*/}"; host_source=explicit ;;
  */*/*) selected_host="${selected_repo%%/*}"; selected_nwo="${selected_repo#*/}"; host_source=explicit ;;
  */*) selected_host="${GH_HOST:-github.com}"; selected_nwo="$selected_repo"; host_source=default; [ -z "${GH_HOST:-}" ] || host_source=GH_HOST ;;
  *) echo 'fixture: invalid repository identity' >&2; exit 94 ;;
esac
# Overrideなしのremote解決はGH_HOSTでfilterされる。別hostのremoteを勝手に発明しない。
if [ "$selected_source" = cwd ] && [ -n "${GH_HOST:-}" ] && [ "$selected_host" != "$GH_HOST" ]; then
  echo 'fixture: cwd remote does not match GH_HOST' >&2
  exit 95
fi
selected_repo="https://$selected_host/$selected_nwo"
case "$selected_repo" in
  https://github.com/owner/repo) selected_origin="$E_DELETE_ORIGIN"; selected_marker=A ;;
  https://mirror.example.test/owner/repo) selected_origin="$E_DELETE_DECOY_ORIGIN"; selected_marker=B ;;
  *) echo 'fixture: unknown repository' >&2; exit 94 ;;
esac
printf '%s\n' "$selected_host" >"$E_DELETE_LOG.selected-host"
printf '%s\n' "$selected_nwo" >"$E_DELETE_LOG.selected-nwo"
printf '%s\n' "$host_source" >"$E_DELETE_LOG.host-source"
printf '%s\n' "$selected_repo" >"$E_DELETE_LOG.selected"
printf '%s\n' "$selected_source" >"$E_DELETE_LOG.selection-source"
[ "$E_DELETE_CASE" != merge-failed ] || exit 7
printf '%s\n' "$selected_repo" >"$E_DELETE_LOG.merged-$selected_marker"
case "$E_DELETE_CASE" in
  already-missing) git --git-dir="$selected_origin" update-ref -d "$E_DELETE_REF" "$E_DELETE_HEAD" ;;
  changed) git --git-dir="$selected_origin" update-ref "$E_DELETE_REF" "$E_DELETE_ALT" "$E_DELETE_HEAD" ;;
  query-failed) mv "$selected_origin" "$selected_origin.away" ;;
esac
GH
  # upload-pack が照会結果を返した直後、push の広告を読む前に同名 ref を再利用する。
  # pre-push だけの race は受信側の CAS でも守られるため、lease 自体を外す退行の針はここで測る。
  cat >"$e_dir/bin/upload-pack" <<'UPLOAD'
#!/usr/bin/env bash
set -eu
"${E_DELETE_UPLOAD_PACK:?}" "$@"
if [ "${E_DELETE_CASE:-}" = lease-before-push ] && [ ! -f "$E_DELETE_LOG.transport" ]; then
  env -u GIT_DIR -u GIT_WORK_TREE git --git-dir="$E_DELETE_ORIGIN" update-ref "$E_DELETE_REF" "$E_DELETE_ALT" "$E_DELETE_HEAD"
  printf '%s\n' "$E_DELETE_HEAD $E_DELETE_ALT" >"$E_DELETE_LOG.transport"
fi
UPLOAD
  chmod +x "$e_hooks/pre-push" "$e_dir/remote-hooks/pre-receive" "$e_dir/bin/gh" "$e_dir/bin/upload-pack"
  e_upload_pack="$(git --exec-path)/git-upload-pack"
  [ -x "$e_upload_pack" ] || { bad 'E4 fixture: git-upload-pack を実行できません'; return 0; }
  e_upload_command="$(jq -nr --arg path "$e_dir/bin/upload-pack" '$path | @sh')"
  e_json="$e_dir/pr.json"
  jq --arg ref "${e_ref#refs/heads/}" --arg head "$e_head" \
    '.headRefName=$ref | .headRefOid=$head | .commits=[{oid:$head,messageHeadline:"feat: fixture head",messageBody:"body"}]' \
    "$TMP/pr.json" >"$e_json"
  (cd "$e_work" && env -u FF_DEV_TOOLKIT_ROOT -u CLAUDE_PLUGIN_ROOT -u GROK_PLUGIN_ROOT \
    bash "$PLUGIN_ROOT/scripts/record-gate-head.sh" --gate tests/run-all.sh --status pass --mode fast >/dev/null)
  STUB_PR_JSON="$e_json" run_finish "$e_work" precheck "$PRN"
  e_precheck_rc="$RC"
  e_cmd="$(printf '%s\n' "$OUT" | awk '/^MERGE_COMMAND_BEGIN$/ { c=1; next } /^MERGE_COMMAND_END$/ { c=0 } c')"
  if [ "$e_precheck_rc" -eq 0 ] && has_line "$OUT" 'DELETE_BRANCH_MODE=separate-push' \
    && has_line "$OUT" 'HEAD_DELETE=lease' && [ -n "$e_cmd" ]; then
    ok 'E4 fixture: quoted consumer と合法な引用付き branch の MERGE_COMMAND を実 precheck が生成する'
  else
    bad "E4 fixture: 実 precheck の生成が成立しない（rc=${e_precheck_rc}）: ${OUT} / ${ERR}"
    g -C "$e_work" worktree remove --force "$e_dir/held-develop" >/dev/null 2>&1 || true
    return 0
  fi

  e_cases='already-missing expected changed merge-failed query-failed race-missing race-changed reject-delete plugin-gone lease-before-push'
  for e_case in $e_cases; do
    e_rows=$((e_rows + 1))
    e_log="$e_dir/$e_case"
    e_output="$e_log.output"
    : >"$e_log.push"; : >"$e_log.refs"; : >"$e_log.receive"; : >"$e_log.gh"
    g --git-dir="$e_origin" update-ref "$e_ref" "$e_head"
    g --git-dir="$e_decoy_origin" update-ref "$e_ref" "$e_head"
    if [ "$e_case" = lease-before-push ]; then
      g -C "$e_work" config --local remote.origin.uploadpack "$e_upload_command"
    else
      g -C "$e_work" config --local --unset remote.origin.uploadpack >/dev/null 2>&1 || true
    fi
    e_restore_root=0
    if [ "$e_case" = plugin-gone ]; then
      mv "$ROOT" "$ROOT.removed"
      e_restore_root=1
    fi
    e_rc=0
    # consumer で生成後に別 checkout へ移動しても、mergeと削除は保存済みconsumerを向く。
    # 呼出元の hook 抑止 env を除去し、生成コマンド自身が付けた値だけを測る。
    (cd "$e_decoy" && env -u SKIP_SIMPLE_GIT_HOOKS -u HUSKY \
      E_DELETE_CASE="$e_case" E_DELETE_LOG="$e_log" E_DELETE_ORIGIN="$e_origin" \
      E_DELETE_WORK="$e_work" E_DELETE_DECOY_ORIGIN="$e_decoy_origin" E_DELETE_PRN="$PRN" \
      E_DELETE_REF="$e_ref" E_DELETE_HEAD="$e_head" E_DELETE_ALT="$e_alt" E_DELETE_UPLOAD_PACK="$e_upload_pack" \
      PATH="$e_dir/bin:$PATH" LC_ALL=C bash -c "$e_cmd") >"$e_output" 2>&1 || e_rc=$?
    [ "$e_restore_root" -eq 0 ] || mv "$ROOT.removed" "$ROOT"
    [ ! -d "$e_origin.away" ] || mv "$e_origin.away" "$e_origin"
    [ ! -d "$e_decoy_origin.away" ] || mv "$e_decoy_origin.away" "$e_decoy_origin"
    e_after="$(g --git-dir="$e_origin" rev-parse --verify "$e_ref" 2>/dev/null || true)"
    e_pushes="$(awk 'END { print NR+0 }' "$e_log.push")"
    e_expected_rc=0; e_expected_ref=''; e_expected_pushes=0
    case "$e_case" in
      expected|plugin-gone|race-missing) e_expected_pushes=1 ;;
      changed) e_expected_ref="$e_alt" ;;
      lease-before-push) e_expected_ref="$e_alt"; e_expected_pushes=1 ;;
      race-changed) e_expected_ref="$e_alt"; e_expected_pushes=1 ;;
      merge-failed) e_expected_rc=7; e_expected_ref="$e_head" ;;
      query-failed) e_expected_rc=nonzero; e_expected_ref="$e_head" ;;
      reject-delete) e_expected_rc=nonzero; e_expected_ref="$e_head"; e_expected_pushes=1 ;;
    esac
    if { [ "$e_expected_rc" = nonzero ] && [ "$e_rc" -ne 0 ]; } \
      || { [ "$e_expected_rc" != nonzero ] && [ "$e_rc" = "$e_expected_rc" ]; }; then
      ok "E4/$e_case: 生成コマンドの終了コード（rc=${e_rc}）"
    else
      bad "E4/$e_case: 終了コードが違う（expected=${e_expected_rc} rc=${e_rc}）: $(cat "$e_output")"
    fi
    if [ "$e_after" = "$e_expected_ref" ] && [ "$e_pushes" = "$e_expected_pushes" ] \
      && [ "$(awk 'END {print NR+0}' "$e_log.gh")" -eq 1 ]; then
      ok "E4/$e_case: remote ref と実 pre-push 到達数が一致（push=${e_pushes}）"
    else
      bad "E4/$e_case: ref/到達数が違う（ref=${e_after} pushes=${e_pushes}）: $(cat "$e_output")"
    fi
    if [ "$e_expected_pushes" -eq 1 ]; then
      if [ "$(cat "$e_log.push")" = '1|0' ] \
        && { { [ "$e_case" = lease-before-push ] && [ ! -s "$e_log.refs" ] && [ ! -s "$e_log.receive" ]; } \
          || { [ "$e_case" != lease-before-push ] && has_text "$(cat "$e_log.refs")" "0000000000000000000000000000000000000000 $e_ref $e_head"; }; }; then
        ok "E4b/$e_case: hook 抑止 env と expected OID の削除 refspec が実 Git へ届く"
      else
        bad "E4b/$e_case: env または削除対象が違う: $(cat "$e_log.push" "$e_log.refs")"
      fi
    fi
    e_result=''
    case "$e_case" in
      already-missing|race-missing) e_result=already-missing ;;
      expected|plugin-gone) e_result=deleted ;;
      changed|race-changed|lease-before-push) e_result=preserved-different-oid ;;
    esac
    if [ -n "$e_result" ]; then
      if has_line "$(cat "$e_output")" "HEAD_DELETE_RESULT=$e_result"; then
        ok "E4/$e_case: 実測した削除結果を報告する（${e_result}）"
      else
        bad "E4/$e_case: 削除結果を報告しない: $(cat "$e_output")"
      fi
    fi
    if [ "$e_case" = lease-before-push ]; then
      if [ -f "$e_log.transport" ] && [ "$(cat "$e_log.transport")" = "$e_head $e_alt" ]; then
        ok 'E4/lease-before-push: 照会後・push広告前の ref 再利用を実 Git で到達確認した'
      else
        bad 'E4/lease-before-push: ref 再利用の注入が成立していない'
      fi
    fi
    if [ "$(cat "$e_log.selected")" = https://github.com/owner/repo ] && [ "$(cat "$e_log.selection-source")" = explicit ] \
      && [ ! -f "$e_log.merged-B" ]; then
      ok "E4/$e_case: merge は生成元 A を明示し、別 checkout B を merge しない"
    else
      bad "E4/$e_case: merge が別 repository を選択した: $(cat "$e_log.selected" "$e_log.selection-source")"
    fi
    if [ "$(g --git-dir="$e_decoy_origin" rev-parse --verify "$e_ref")" = "$e_head" ]; then
      ok "E4/$e_case: 別 checkout の origin は同名 ref を保全する"
    else
      bad "E4/$e_case: 別 checkout の origin の同名 ref を変更した"
    fi
  done
  if [ "$e_rows" -eq 10 ]; then
    ok 'E4 matrix: 10 行を実行した（空集合や一部欠落を緑にしない）'
  else
    bad "E4 matrix: 実行数が違う（${e_rows}/10）"
  fi
  # 別hostの同じ owner/repo・PR番号・head OID のBがあっても、Aの生成物はAのmergeに限る。
  # --subject/--body有無と、cwd/GH_REPO/GH_HOSTの別repository選択を独立に測る。
  g -C "$e_work" config --local --unset remote.origin.uploadpack >/dev/null 2>&1 || true
  for e_message in plain message; do
    g --git-dir="$e_origin" update-ref "$e_ref" "$e_head"
    g --git-dir="$e_decoy_origin" update-ref "$e_ref" "$e_head"
    if [ "$e_message" = message ]; then
      STUB_PR_JSON="$e_json" run_finish "$e_work" precheck "$PRN" --subject 'chore: approved message' --body "Closes #${PRN}"
    else
      STUB_PR_JSON="$e_json" run_finish "$e_work" precheck "$PRN"
    fi
    e_cmd="$(printf '%s\n' "$OUT" | awk '/^MERGE_COMMAND_BEGIN$/ { c=1; next } /^MERGE_COMMAND_END$/ { c=0 } c')"
    if [ "$RC" -ne 0 ] || [ -z "$e_cmd" ]; then
      bad "E4c/$e_message: A のコマンド生成が成立しない（rc=${RC}）"
      continue
    fi
    for e_context in cwd env host; do
      e_pin_rows=$((e_pin_rows + 1))
      e_run_cwd="$e_decoy"; e_inherited_repo=''; e_inherited_host=''
      if [ "$e_context" = env ]; then e_run_cwd="$e_work"; e_inherited_repo=https://mirror.example.test/owner/repo; fi
      if [ "$e_context" = host ]; then e_run_cwd="$e_work"; e_inherited_host=mirror.example.test; e_host_rows=$((e_host_rows + 1)); fi
      e_log="$e_dir/pin-$e_message-$e_context"
      g --git-dir="$e_origin" update-ref "$e_ref" "$e_head"
      g --git-dir="$e_decoy_origin" update-ref "$e_ref" "$e_head"
      e_rc=0
      (cd "$e_run_cwd" && env -u SKIP_SIMPLE_GIT_HOOKS -u HUSKY \
        GH_REPO="$e_inherited_repo" GH_HOST="$e_inherited_host" E_DELETE_CASE=expected E_DELETE_LOG="$e_log" E_DELETE_ORIGIN="$e_origin" \
        E_DELETE_WORK="$e_work" E_DELETE_DECOY_ORIGIN="$e_decoy_origin" E_DELETE_PRN="$PRN" \
        E_DELETE_REF="$e_ref" E_DELETE_HEAD="$e_head" E_DELETE_ALT="$e_alt" \
        PATH="$e_dir/bin:$PATH" LC_ALL=C bash -c "$e_cmd") >"$e_log.output" 2>&1 || e_rc=$?
      if [ "$e_rc" -eq 0 ] && [ "$(cat "$e_log.selected")" = https://github.com/owner/repo ] \
        && [ "$(cat "$e_log.selection-source")" = explicit ] \
        && [ "$(cat "$e_log.merged-A")" = https://github.com/owner/repo ] && [ ! -f "$e_log.merged-B" ]; then
        ok "E4c/$e_message/$e_context: 生成元 A だけを merge し、同番号・同 OID の B は merge しない"
      else
        bad "E4c/$e_message/$e_context: merge の repository が固定されていない（rc=${e_rc} selected=$(cat "$e_log.selected") source=$(cat "$e_log.selection-source")）: $(cat "$e_log.output")"
      fi
      e_after="$(g --git-dir="$e_origin" rev-parse --verify "$e_ref" 2>/dev/null || true)"
      if [ -z "$e_after" ] && [ "$(g --git-dir="$e_decoy_origin" rev-parse --verify "$e_ref")" = "$e_head" ]; then
        ok "E4c/$e_message/$e_context: merge 後の削除も A の ref だけに届く"
      else
        bad "E4c/$e_message/$e_context: merge と ref 削除の対象が一致しない"
      fi
    done
  done
  if [ "$e_pin_rows" -eq 6 ]; then
    ok 'E4c matrix: メッセージ有無×cwd/env/host の6組を実行した'
  else
    bad "E4c matrix: repository 固定のケースが欠けた（${e_pin_rows}/6）"
  fi
  if [ "$e_host_rows" -eq 2 ]; then
    ok 'E4c host: GH_HOST の2組を実行した（旧4組だけで緑にしない）'
  else
    bad "E4c host: host のケースが欠けた（${e_host_rows}/2）"
  fi
  g -C "$e_work" worktree remove --force "$e_dir/held-develop" >/dev/null 2>&1 || true
}

_ff_finish_precheck_guards() {
  local guard_lib="$ROOT/scripts/lib/finish-precheck.sh" guard_kind guard_rows=0
  cp "$guard_lib" "$TMP/precheck.saved"
  for guard_kind in missing empty incomplete; do
    guard_rows=$((guard_rows + 1))
    cp "$TMP/precheck.saved" "$guard_lib"
    case "$guard_kind" in
      missing) rm "$guard_lib" ;;
      empty) : >"$guard_lib" ;;
      incomplete) sed 's/^_finish_precheck_loaded=1$/_finish_precheck_loaded=0/' "$TMP/precheck.saved" >"$guard_lib" ;;
    esac
    : >"$STUB_LOG"
    run_finish "$WORK" precheck "$PRN"
    if [ "$RC" -eq 2 ] && [ ! -s "$STUB_LOG" ] && ! has_text "$OUT" MERGE_COMMAND_BEGIN \
      && has_text "$ERR" '復帰:'; then
      ok "S11/$guard_kind: precheck 構成ファイルの不在・空・不完全を gh より前に rc2 で止める"
    else
      bad "S11/$guard_kind: 読込み不成立が停止しない（rc=${RC}）: ${OUT} / ${ERR}"
    fi
  done
  cp "$TMP/precheck.saved" "$guard_lib"
  if [ "$guard_rows" -eq 3 ]; then
    ok 'S11 matrix: 構成ファイルの異常3ケースを実行した'
  else
    bad "S11 matrix: 異常ケースが欠けた（${guard_rows}/3）"
  fi
}

_ff_finish_repository_url_guards() {
  local url_case url_rows=0 url_json="$TMP/repo-url.json"
  write_pr_json "Closes #${PRN}" '[]'
  for url_case in missing empty null type host path query; do
    url_rows=$((url_rows + 1))
    case "$url_case" in
      missing) printf '%s\n' '{"nameWithOwner":"owner/repo"}' >"$url_json" ;;
      empty) printf '%s\n' '{"nameWithOwner":"owner/repo","url":""}' >"$url_json" ;;
      null) printf '%s\n' '{"nameWithOwner":"owner/repo","url":null}' >"$url_json" ;;
      type) printf '%s\n' '{"nameWithOwner":"owner/repo","url":17}' >"$url_json" ;;
      host) printf '%s\n' '{"nameWithOwner":"owner/repo","url":"https:///owner/repo"}' >"$url_json" ;;
      path) printf '%s\n' '{"nameWithOwner":"owner/repo","url":"https://github.com/other/repo"}' >"$url_json" ;;
      query) printf '%s\n' '{"nameWithOwner":"owner/repo","url":"https://github.com/owner/repo?x=1"}' >"$url_json" ;;
    esac
    STUB_REPO_JSON="$url_json" GH_HOST=mirror.example.test run_finish "$WORK" precheck "$PRN"
    if [ "$RC" -eq 2 ] && ! has_text "$OUT" MERGE_COMMAND_BEGIN && ! has_text "$OUT" MERGE_COMMAND_END \
      && has_text "$ERR" 'ホストを含むリポジトリ URL を解決できません'; then
      ok "U1/$url_case: 不正URLをGH_HOSTで補完せずBEGIN前にrc2で止める"
    else
      bad "U1/$url_case: URLの解決不能を止めない（rc=${RC}）: ${OUT} / ${ERR}"
    fi
  done
  if [ "$url_rows" -eq 7 ]; then
    ok 'U1 matrix: URL missing/empty/null/type/host/path/query の7組を実行した'
  else
    bad "U1 matrix: URL検査のケースが欠けた（${url_rows}/7）"
  fi
}
