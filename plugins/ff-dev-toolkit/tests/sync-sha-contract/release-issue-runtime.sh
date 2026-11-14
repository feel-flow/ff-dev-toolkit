# shellcheck shell=bash
# Sourced by release-runtime.sh after the stage fixtures finish.
# $1=Issue index: the announcement heading appears exactly once (CR at the line end is the same line)
release_notice_once() {
  jq -e --argjson i "$1" --arg h '## リリース後の X 告知（最後に実施）' \
    '.[$i].body | split("\n") | map(select(rtrimstr("\r") == $h)) | length == 1' "$STATE/release-issues.json" >/dev/null
}
# $1=Issue index: the lines after the end marker, verbatim
release_issue_tail() {
  jq -r --argjson i "$1" '.[$i].body | split("\n") | .[((index("<!-- ff-release-state:end -->") // -1) + 1):] | join("\n")' \
    "$STATE/release-issues.json"
}
# A not-needed close cannot be reached here once a version is published, so the
# real lib and the real finish() are read and only the Issue I/O is replaced: the
# close comment and the RELEASE_NOTICE line must tell a released run from a
# not-needed one, also when recording the end on the Issue fails.
release_notice_finish_probe() {
  local released not_needed repo
  repo="$(printf '%s%s' 'feel-flow/feelflow-' 'plugins')"
  cat >"$STATE/notice-probe.sh" <<'PROBE'
set -u
. "$1/scripts/lib/release-issue-functions.sh" || exit 3
RELEASE_ISSUE_NUMBER=7
MARKER_TOKEN=probe-token
VER=9.9.9
PUBLIC_URL=https://github.com/feel-flow/ff-dev-toolkit
ISSUE_RUNNING='{"number":7,"data":{"owner":{"token":"probe-token"}}}'
issue_lock() { :; }
issue_load() { :; }
issue_unlock() { RELEASE_ISSUE_LOCK=""; }
issue_comment() { printf 'COMMENT=%s\n' "$2"; }
issue_api() { printf '%s\n' '{"state":"closed"}'; }
case "${3:-}" in
  close-fail) issue_api() { case "$*" in *PATCH*) return 1 ;; *) printf '%s\n' '{"state":"closed"}' ;; esac; } ;;
  unlock-fail) issue_unlock() { return 1; } ;;
esac
CURRENT_STAGE=release
# The real finish() of release-dev-toolkit.sh, not a copy of its order
eval "$(sed -n '/^finish() {/,/^}/p' "$1/scripts/release-dev-toolkit.sh")"
declare -F finish >/dev/null || { echo "finish() を読めない"; exit 3; }
finish "$2" 0 "未同期の変更が無い"
PROBE
  released="$("$ENV_BIN" bash "$STATE/notice-probe.sh" "$REPO_ROOT" released 2>&1)" || released="rc=$?: $released"
  not_needed="$("$ENV_BIN" bash "$STATE/notice-probe.sh" "$REPO_ROOT" not-needed 2>&1)" || not_needed="rc=$?: $not_needed"
  if [[ "$not_needed" == "COMMENT=not-needed: 未同期の変更が無い。この実行では新しい版を公開していないので、この実行の X 告知は不要（前に公開した版の告知はその版の release Issue で確かめる）"$'\n'"RELEASE_NOTICE=not-needed"$'\n'"RELEASE_RESULT=not-needed"$'\n'"RELEASE_VERSION=9.9.9" &&
    "$released" == "COMMENT=released: v9.9.9 https://github.com/feel-flow/ff-dev-toolkit/releases/tag/v9.9.9。公開処理は完了。X 告知（@feelflow_ai）は未投稿で、本文末尾「リリース後の X 告知（最後に実施）」のチェック項目を最後の作業として行い、投稿 URL をこの Issue に記録する"$'\n'"RELEASE_NOTICE=pending https://github.com/$repo/issues/7"$'\n'"RELEASE_RESULT=released"$'\n'"RELEASE_VERSION=9.9.9" ]]; then
    ok "not-needed の close は告知不要と記録して投稿を求めず、released の close だけが告知を未投稿の作業として残す"
  else
    bad "release Issue の close が released と not-needed の告知の扱いを区別しない"
    printf '    | released → %s\n    | not-needed → %s\n' "$released" "$not_needed" >&2
  fi
  # A version is public once release finished; losing the Issue record (close
  # or lock release) must still leave exactly one pending notice, never one
  # beside a failure from inside issue_finish, and none for not-needed.
  local mode out pending unrecorded ok_all=1
  pending="RELEASE_NOTICE=pending https://github.com/$repo/issues/7"
  unrecorded="NG: [release] release Issue $(printf '#%s' 7) に終了を記録できない"
  for mode in close-fail unlock-fail; do
    out="$("$ENV_BIN" bash "$STATE/notice-probe.sh" "$REPO_ROOT" released "$mode" 2>&1)" || out="rc=$?: $out"
    if [[ "$out" != "rc=2: "*$'\n'"$unrecorded"$'\n'"NG: Release v9.9.9 は公開済みで、X 告知（@feelflow_ai）は未投稿"*$'\n'"$pending"$'\n'"RELEASE_RESULT=unavailable"$'\n'"RELEASE_VERSION=9.9.9" ]] ||
      [[ "$(grep -c '^RELEASE_NOTICE=' <<<"$out")" != 1 ]]; then
      ok_all=0; printf '    | released %s → %s\n' "$mode" "$out" >&2
    fi
    out="$("$ENV_BIN" bash "$STATE/notice-probe.sh" "$REPO_ROOT" not-needed "$mode" 2>&1)" || out="rc=$?: $out"
    if [[ "$out" != "rc=2: "*$'\n'"RELEASE_RESULT=unavailable"$'\n'"RELEASE_VERSION=9.9.9" || "$out" == *RELEASE_NOTICE=* ]]; then
      ok_all=0; printf '    | not-needed %s → %s\n' "$mode" "$out" >&2
    fi
  done
  if [[ "$ok_all" -eq 1 ]]; then
    ok "公開後に close や解放だけが失敗しても RELEASE_NOTICE=pending を 1 行だけ出し、not-needed の失敗では出さない"
  else bad "Issue への終了の記録に失敗した回の告知の扱いが違う"; fi
}
# CRLF in a release Issue body, at the two places the fixture cannot reach:
# the owner check that reads a running Issue, and a host whose jq prints CRLF
# (Windows jq.exe) while issue_write renders, sends and reads back the body.
release_crlf_probe() {
  local guard write
  cat >"$STATE/crlf-probe.sh" <<'PROBE'
set -u
. "$1/scripts/lib/release-issue-functions.sh" || exit 3
RELEASE_ISSUE_NUMBER=7
MARKER_TOKEN=probe-token
RELEASE_PIN=""
stop() { echo "STOP: $1"; exit 1; }
unavailable() { echo "UNAVAILABLE: $1"; exit 2; }
case "$2" in
  guard)
    now="$(date +%s)"
    body="$(printf '%s\r\n\r\n%s' "${RELEASE_ISSUE_PREFIX}{\"owner\":{\"token\":\"probe-token\",\"started\":${now}}} -->" '<!-- ff-release-state:end -->')"
    issue_api() { jq -n --arg body "$body" '{state:"open",body:$body}'; }
    issue_guard
    echo "GUARD=ok" ;;
  write)
    store="$3"
    jq() {
      local out rc=0
      out="$(command jq "$@")" || rc=$?
      [ -z "$out" ] || printf '%s\n' "$out" | awk '{ printf "%s\r\n", $0 }'
      return "$rc"
    }
    issue_api() {
      case "$*" in
        *$'\r'*) echo "CR in the API arguments" >&2; return 9 ;;
        *"-X POST"*) command jq -c '{body:.body}' >"$store"; printf '%s\n' '{"number":7}' ;;
        *"-X PATCH"*) command jq -c '{body:.body}' >"$store"; printf '%s\n' '{"number":7}' ;;
        *) command jq -n --slurpfile s "$store" '{number:7,state:"open",labels:[{name:"release"}],body:$s[0].body}' ;;
      esac
    }
    data='{"schema":1,"status":"queued","head":"0123456789abcdef0123456789abcdef01234567","due":"no","reason":"probe","drift":1,"fragments":0,"fixed_head":null,"owner":null}'
    if issue_write "$data" ""; then echo "WRITE=ok"; else echo "WRITE=failed"; fi
    # The update path: an existing Issue whose stored body is CRLF.
    row="$(command jq -c '{number:7, body:(.body | split("\n") | map(. + "\r") | join("\n"))}' "$store")"
    data="$(command jq -c '.drift = 2' <<<"$data")"
    if issue_write "$data" "$row"; then echo "PATCH=ok"; else echo "PATCH=failed"; fi ;;
esac
PROBE
  guard="$("$ENV_BIN" bash "$STATE/crlf-probe.sh" "$REPO_ROOT" guard 2>&1)" || guard="rc=$?: $guard"
  rm -f "$STATE/crlf-store.json"
  write="$("$ENV_BIN" bash "$STATE/crlf-probe.sh" "$REPO_ROOT" write "$STATE/crlf-store.json" 2>&1)" || write="rc=$?: $write"
  if [[ "$guard" == "GUARD=ok" && "$write" == "WRITE=ok"$'\n'"PATCH=ok" ]] &&
    jq -e '.body | (contains("\r") | not) and contains("- DRIFT_COUNT: 2") and (split("\n") | length > 10)' "$STATE/crlf-store.json" >/dev/null 2>&1; then
    ok "担当の照合は CRLF の本文を LF と同じに読み、jq が CRLF を出すホストでも issue_write の作成・更新は本文と API の引数（更新・読み戻しの URL の番号）に CR を入れない"
  else
    bad "CRLF の本文で担当の照合が止まる、または CR の入った本文を送った"
    printf '    | guard → %s\n    | write → %s\n' "$guard" "$write" >&2
  fi
}
# PATH 先頭の jq が jq -nr の各行末にだけ CR を付ける（Windows jq の生出力）。
# issue_body は CR を除いた LF を返し、告知欄は 1 回のまま。担当照合は CRLF の本文でも止まらない。
release_issue_jq_cr_probe() {
  local out started sha state
  started="$(date +%s)"
  sha="0123456789abcdef0123456789abcdef01234567"
  state="$(jq -nc --arg head "$sha" --argjson started "$started" \
    '{schema:1,status:"running",head:$head,due:"yes",reason:"probe",drift:0,fragments:0,fixed_head:null,owner:{executor:"probe",host:"probe",token:"probe-token",started:$started,expect_version:"1.2.3",approved_head:$head}}')"
  cat >"$STATE/jq-cr-probe.sh" <<'PROBE'
set -u
repo="$1"
state_dir="$2"
state_json="$3"
# Both shims below take their directory from $0 as PATH spelled it. Resolving it
# with cd/pwd turns "T//x" (the macOS TMPDIR ends in "/") into "T/x", the PATH
# prefix then fails to strip, and the shim runs itself until fork fails. A shim
# that cannot strip its own directory stops with 97 instead.
mkdir -p "$state_dir/crlf-jq"
cat >"$state_dir/crlf-jq/jq" <<'JQ'
#!/usr/bin/env bash
set -o pipefail
self="${0%/*}"
rest="${PATH#"$self:"}"
if [[ "$rest" == "$PATH" ]]; then
  echo "jq shim: own directory is not the PATH head, so the real jq is unreachable: $self" >&2
  exit 97
fi
PATH="$rest"
if [[ "${1:-}" == "-nr" ]]; then
  jq "$@" | sed $'s/$/\r/'
  exit $?
fi
exec jq "$@"
JQ
chmod +x "$state_dir/crlf-jq/jq"
export PATH="$state_dir/crlf-jq:$PATH"
# shellcheck source=/dev/null
. "$repo/scripts/lib/release-issue-functions.sh" || exit 3
GITHUB_INPUT=""
RELEASE_PIN=""
MARKER_TOKEN=probe-token
RELEASE_ISSUE_NUMBER=7
prefix='<!-- ff-release-state '
endmark='<!-- ff-release-state:end -->'
heading='## リリース後の X 告知（最後に実施）'
url='公開ポスト https://x.com/feelflow_ai/status/1'
# Keep the trailing LF. A bare command substitution would drop it, and that is
# the byte the sentinel in issue_body exists to preserve.
old_lf="$(printf '%s\n\n## 走行中\n\n%s\n%s\n%s\n' "${prefix}${state_json} -->" "$endmark" "$heading" "$url"; printf x)"
old_lf="${old_lf%x}"
old_crlf="${old_lf//$'\n'/$'\r\n'}"
plain_path="${PATH#"$state_dir/crlf-jq:"}"
# Keep trailing LFs. $(issue_body) alone drops them, so a CR that only protects
# a trailing LF would compare equal and the sentinel would not be tested.
body="$(issue_body "$state_json" "$old_crlf"; rc=$?; printf x; exit "$rc")" || { echo "BODY_RC=$?"; exit 1; }
body="${body%x}"
body_plain="$(PATH="$plain_path" issue_body "$state_json" "$old_crlf"; rc=$?; printf x; exit "$rc")" || { echo "PLAIN_RC=$?"; exit 1; }
body_plain="${body_plain%x}"
trail_lfs() {
  local s="$1" n=0
  while [[ "$s" == *$'\n' ]]; do s="${s%$'\n'}"; n=$((n + 1)); done
  printf '%s' "$n"
}
caller_body() {
  local s="$1"
  while [[ "$s" == *$'\n' ]]; do s="${s%$'\n'}"; done
  printf '%s' "$s"
}
line_trail="$(trail_lfs "$body")"
plain_trail="$(trail_lfs "$body_plain")"
if [[ "$(caller_body "$body")" == "$(caller_body "$body_plain")" && "$line_trail" -eq $((plain_trail + 1)) ]]; then
  echo LINE_CR_MATCH=yes
else
  echo "LINE_CR_MATCH=no line=$line_trail plain=$plain_trail"
fi
if [[ "$body" == *$'\r'* ]]; then echo BODY_HAS_CR=yes; else echo BODY_HAS_CR=no; fi
heading_count="$(printf '%s\n' "$body" | grep -c -F "$heading" || true)"
echo "HEADING_COUNT=$heading_count"
if [[ "$body" == *"$url"* ]]; then echo TAIL_URL=yes; else echo TAIL_URL=no; fi
# A second jq appends one CR after the whole -nr output, so the raw bytes end
# in LF CR. The rendered body must still match the real jq.
mkdir -p "$state_dir/end-cr-jq"
cat >"$state_dir/end-cr-jq/jq" <<'JQ'
#!/usr/bin/env bash
set -o pipefail
self="${0%/*}"
rest="${PATH#"$self:"}"
if [[ "$rest" == "$PATH" ]]; then
  echo "jq shim: own directory is not the PATH head, so the real jq is unreachable: $self" >&2
  exit 97
fi
PATH="$rest"
if [[ "${1:-}" == "-nr" ]]; then
  jq "$@"
  rc=$?
  printf '\r'
  exit "$rc"
fi
exec jq "$@"
JQ
chmod +x "$state_dir/end-cr-jq/jq"
body_end="$(PATH="$state_dir/end-cr-jq:$plain_path" issue_body "$state_json" "$old_lf"; rc=$?; printf x; exit "$rc")" || { echo "END_RC=$?"; exit 1; }
body_end="${body_end%x}"
body_end_plain="$(PATH="$plain_path" issue_body "$state_json" "$old_lf"; rc=$?; printf x; exit "$rc")" || { echo "END_PLAIN_RC=$?"; exit 1; }
body_end_plain="${body_end_plain%x}"
end_trail="$(trail_lfs "$body_end")"
end_plain_trail="$(trail_lfs "$body_end_plain")"
# LF then CR keeps two trailing LFs that $(jq) would have dropped, then printf
# adds one. The no-CR render has only that one added LF (measured 3 vs 1).
if [[ "$(caller_body "$body_end")" == "$(caller_body "$body_end_plain")" && "$end_trail" -eq $((end_plain_trail + 2)) ]]; then
  echo END_CR_MATCH=yes
else
  echo "END_CR_MATCH=no end=$end_trail plain=$end_plain_trail"
fi
issue_api() { jq -nc --arg body "$old_crlf" '{number:7,state:"open",body:$body,labels:[{name:"release"}]}'; }
stop() { echo "STOP:$*"; return 1; }
unavailable() { echo "UNAVAILABLE:$*"; return 2; }
guard_rc=0
issue_guard || guard_rc=$?
echo "GUARD_RC=$guard_rc"
PROBE
  out="$("$ENV_BIN" bash "$STATE/jq-cr-probe.sh" "$REPO_ROOT" "$STATE" "$state" 2>&1)" || out="rc=$?: $out"
  if [[ "$out" == *"BODY_HAS_CR=no"* && "$out" == *"HEADING_COUNT=1"* && "$out" == *"TAIL_URL=yes"* && "$out" == *"GUARD_RC=0"* && "$out" == *"LINE_CR_MATCH=yes"* && "$out" == *"END_CR_MATCH=yes"* ]]; then
    ok "jq の生出力に CR が付いても組み立てた本文は LF で告知欄を 1 回だけ残し、CRLF の本文でも担当を照合できる"
  else
    bad "jq の生出力に付けた CR の組み立てか、CRLF の本文での担当の照合が違う"
    printf '    | %s\n' "$out" >&2
  fi
}
release_issue_cases() {
  echo "-- release: private Issue handoff and fixed HEAD --"
  local issue_db="$STATE/release-issues.json" approved version before pub_before saved first second private_repo dry_plan forged pinned other tail_before notice_order crlf_dry_rc
  cp "$REPO_ROOT/scripts/lib/release-issue-functions.sh" "$SSOT/scripts/lib/"
  mv "$STUB_BIN/gh" "$STUB_BIN/gh-legacy"
  cp "$SCRIPT_DIR/fixtures/release-issue-gh.py" "$STUB_BIN/gh.py"
  write_stub "$STUB_BIN/gh" <<'STUB'
#!/usr/bin/env bash
exec "$RELEASE_RT_REAL_PYTHON" "$0.py" "$@"
STUB
  # The actual clone transports remain local; only URL identification is stubbed.
  export RELEASE_RT_GIT RELEASE_RT_REAL_PYTHON
  RELEASE_RT_GIT="$(command -v git)"
  write_stub "$STUB_BIN/git" <<'STUB'
#!/usr/bin/env bash
case "$*" in
  "config --local --get-all remote.origin.url"|"remote get-url --push --all origin")
    printf '%s/%s/%s%s\n' 'https://github.com' 'feel-flow' 'feelflow-' 'plugins.git' ;;
  *) exec "$RELEASE_RT_GIT" "$@" ;;
esac
STUB
  printf '%s\n' '- 受付中のリリース' >"$SSOT/changelog.d/2649.fixed.release-issue.md"
  commit_push "fix: release handoff fixture"
  iso_ago 3600 >"$STATE/published_at"
  run_orch --update-release-issue --dry-run
  if [[ "$RC" -eq 0 && ! -e "$issue_db" ]] && has "PLAN: release Issue を作成"; then
    ok "受付 dry-run は作成予定だけを出す"
  else bad "受付 dry-run が書き込んだ、または作成予定が無い (rc=$RC)"; dump; fi
  dry_plan="$OUT"
  private_repo="$(printf '%s%s' 'feel-flow/feelflow-' 'plugins')"
  jq -n --arg repo "$private_repo" '{full_name:$repo,private:true,visibility:"private"}' >"$STATE/issue-repo.json"
  printf '[]\n' >"$STATE/issue-list.json"
  jq -n --arg published "$(cat "$STATE/published_at")" '{published_at:$published}' >"$STATE/issue-due.json"
  jq -n --arg path "$STATE" --arg repo "https://github.com/$private_repo" '
    {version:1,responses:[
      {operation:"release.issue-repo",scope:{repository:$repo},phase:"queue",body:($path+"/issue-repo.json")},
      {operation:"release.issue-list",scope:{repository:$repo},phase:"queue",body:($path+"/issue-list.json"),last:true},
      {operation:"release.latest-due",scope:{repository:"https://github.com/feel-flow/ff-dev-toolkit"},phase:"due",body:($path+"/issue-due.json")}
    ]}' >"$STATE/issue-index.json"
  : >"$STATE/issue-denied"
  run_orch --update-release-issue --dry-run --github-input "$STATE/issue-index.json"
  rm "$STATE/issue-denied"
  if [[ "$RC" -eq 0 && "$OUT" == "$dry_plan" && ! -e "$issue_db" ]]; then
    ok "raw-file と gh は受付 dry-run の判定・出力が同じ"
  else bad "raw-file と gh の受付 dry-run の判定が違う"; dump; fi
  git clone -q -b develop "$SSOT_ORIGIN" "$TMP/other-releaser"
  release_case_init_clone "$TMP/other-releaser"
  : >"$STATE/issue-race"
  bash "$SSOT/scripts/release-dev-toolkit.sh" --update-release-issue >"$STATE/first-issue.log" 2>&1 &
  first=$!
  bash "$TMP/other-releaser/scripts/release-dev-toolkit.sh" --update-release-issue >"$STATE/second-issue.log" 2>&1 &
  second=$!
  wait "$first" || true
  wait "$second" || true
  rm "$STATE/issue-race"
  OUT="$(cat "$STATE/first-issue.log" "$STATE/second-issue.log")"
  if has "RELEASE_ISSUE_URL=" && jq -e 'length == 1 and .[0].comments == []' "$issue_db" >/dev/null; then
    ok "別 clone から同時に更新しても受付中 Issue は 1 件"
  else bad "同時更新で受付中 Issue が 1 件にならない"; dump; return; fi
  if release_notice_once 0 && jq -e '.[0].body | split("\n") | (.[-4:] | all(startswith("- [ ] "))) and (.[-2] | contains("@feelflow_ai"))' "$issue_db" >/dev/null; then
    ok "新規の受付 Issue は本文末尾に @feelflow_ai の告知チェック項目を 1 回だけ持つ"
  else bad "新規の受付 Issue の末尾に告知チェック項目が無い、または重複"; dump; fi

  # The announcement is done by a person on the Issue page: a checked box and
  # the post URL must survive every later rewrite of the machine-owned part.
  jq '.[0].body |= (sub("- \\[ \\] "; "- [x] ") + "\n\n公開ポスト https://x.com/feelflow_ai/status/1")' "$issue_db" >"$STATE/notice-edit.json"
  cp "$STATE/notice-edit.json" "$issue_db"
  tail_before="$(release_issue_tail 0)"
  git -C "$SSOT" commit -qm "docs: latest neutral commit" --allow-empty
  git -C "$SSOT" push -q origin develop
  run_orch --update-release-issue
  approved="$(git -C "$SSOT" rev-parse HEAD)"
  if [[ "$RC" -eq 0 ]] && jq -e --arg sha "$approved" 'length == 1 and .[0].comments == [] and (.[0].body | contains($sha))' "$issue_db" >/dev/null; then
    ok "既存の受付中 Issue を同じ番号・コメントなしで更新"
  else bad "既存の受付中 Issue を更新できない"; dump; fi
  if [[ -n "$tail_before" && "$(release_issue_tail 0)" == "$tail_before" ]] && release_notice_once 0; then
    ok "受付の更新は末尾のチェック状態・投稿 URL をそのまま保ち、告知欄を重複追加しない"
  else bad "受付の更新が末尾の告知欄を変えた、または重複追加した"; dump; fi

  # An Issue created before this section existed gets it once, then stays put.
  saved="$(cat "$issue_db")"
  jq '.[0].body |= (split("\n") | .[0:(index("<!-- ff-release-state:end -->") + 1)] | join("\n"))' <<<"$saved" >"$issue_db"
  run_orch --update-release-issue
  first="$(jq -r '.[0].body' "$issue_db")"
  run_orch --update-release-issue
  if [[ "$RC" -eq 0 ]] && release_notice_once 0 && [[ "$(jq -r '.[0].body' "$issue_db")" == "$first" ]] &&
    jq -e '.[0].comments == []' "$issue_db" >/dev/null; then
    ok "告知欄の無い旧 Issue には受付の更新で 1 回だけ足し、次の更新では本文を変えない"
  else bad "旧 Issue への告知欄の追加が 1 回にならない"; dump; fi
  # The shape that stopped a release: CRLF on every line but the last one,
  # which has no line break. It is read as the same state and rewritten once
  # without CR; the dry-run only plans that rewrite.
  jq '.[0].body |= (split("\n") | (.[0:-1] | map(. + "\r")) + .[-1:] | join("\n"))' <<<"$saved" >"$issue_db"
  run_orch --update-release-issue --dry-run
  crlf_dry_rc="$RC"
  if [[ "$RC" -eq 0 ]] && has "を更新（HEAD=" && jq -e '.[0].body | contains("\r")' "$issue_db" >/dev/null; then
    crlf_dry_rc=0
  else crlf_dry_rc="${RC}-wrote-or-no-plan"; fi
  run_orch --update-release-issue
  if [[ "$crlf_dry_rc" == 0 && "$RC" -eq 0 ]] && jq -e '(.[0].body | contains("\r") | not) and .[0].comments == []' "$issue_db" >/dev/null &&
    [[ "$(jq -r '.[0].body' "$issue_db")" == "$(jq -r '.[0].body' <<<"$saved")" ]] && release_notice_once 0; then
    ok "CRLF の受付本文（最終行だけ改行なし）も LF と同じ状態として読み、更新で CR の無い本文へ書き直して末尾を保つ"
  else bad "CRLF の受付本文を読めない、または書き直しで CR・末尾が残らない (dry-run rc=$crlf_dry_rc)"; dump; fi
  printf '%s\n' "$saved" >"$issue_db"

  # HEAD が変わる更新。本文全体が CRLF でも終端行を見つけ、告知欄を残した LF へ書く。
  # 読み戻しはその書き込みを CRLF で返す（既に CR がある本文は重ねて変換しない）。
  jq '.[0].body |= gsub("\n"; "\r\n")' "$issue_db" >"$STATE/crlf-body.json"
  cp "$STATE/crlf-body.json" "$issue_db"
  : >"$STATE/issue-readback-crlf"
  commit_push "docs: crlf body rewrite"
  run_orch --update-release-issue
  rm -f "$STATE/issue-readback-crlf"
  approved="$(git -C "$SSOT" rev-parse HEAD)"
  if [[ "$RC" -eq 0 ]] && jq -e --arg sha "$approved" 'length == 1 and (.[0].body | contains($sha) and (contains("\r") | not))' "$issue_db" >/dev/null &&
    [[ "$(release_issue_tail 0)" == *"公開ポスト https://x.com/feelflow_ai/status/1"* ]] && release_notice_once 0; then
    ok "CRLF の本文でも終端行を見つけ、告知欄を残した LF の本文へ更新する"
  else bad "CRLF の本文の更新が止まる、または告知欄か CR の扱いが違う"; dump; fi

  saved="$(cat "$issue_db")"
  jq '. + [.[0] | .number = 2]' <<<"$saved" >"$issue_db"
  run_orch --update-release-issue
  if [[ "$RC" -eq 1 ]] && has "$(printf '#%s, #%s' 1 2)"; then ok "受付中の重複は全番号を示して停止"; else bad "重複した受付を更新した"; dump; fi
  printf '%s\n' "$saved" >"$issue_db"

  version="$(jq -r .version "$SSOT/plugins/ff-dev-toolkit/.claude-plugin/plugin.json" | awk -F. '{ print $1 "." $2 "." ($3 + 1) }')"
  before="$(count_runall)"
  pub_before="$(git -C "$PUB_ORIGIN" rev-parse main)"
  other="$TMP/other-releaser"
  git -C "$other" pull -q --ff-only origin develop
  printf '%s\n' 'outside approval' >"$other/plugins/ff-dev-toolkit/scripts/unapproved.txt"
  jq --arg version "$version" '.version = $version' "$other/plugins/ff-dev-toolkit/.claude-plugin/plugin.json" >"$STATE/forged-version.json"
  cp "$STATE/forged-version.json" "$other/plugins/ff-dev-toolkit/.claude-plugin/plugin.json"
  awk -v v="$version" '/^## \[Unreleased\]$/ {print; print ""; print "## [" v "] - 2026-11-06"; print ""; print "### 修正"; print ""; print "- Unapproved payload."; next} {print}' \
    "$other/oss/ff-dev-toolkit/CHANGELOG.md" >"$STATE/forged-changelog.md"
  cp "$STATE/forged-changelog.md" "$other/oss/ff-dev-toolkit/CHANGELOG.md"
  git -C "$other" add -A
  git -C "$other" commit -qm "release: ff-dev-toolkit v$version" -m "Release-Issue: $(printf '#%s' 1)"
  forged="$(git -C "$other" rev-parse HEAD)"
  git -C "$other" push -q origin develop
  run_orch --executor first --expect-version "$version" --approved-head "$approved"
  if [[ "$RC" -eq 1 && "$(git -C "$SSOT" rev-parse HEAD)" == "$approved" ]] && has "ADVANCE=public" && ! has "RELEASE_STAGE=gate"; then
    ok "件名と Issue 番号を似せた未承認コミットは checkout と検査より前に停止"
  else bad "件名と Issue 番号だけで未承認コミットを受け入れた"; dump; fi
  git -C "$SSOT_ORIGIN" update-ref refs/heads/develop "$approved" "$forged"
  : >"$STATE/issue-denied"
  run_orch --executor first --expect-version "$version" --approved-head "$approved"
  rm "$STATE/issue-denied"
  if [[ "$RC" -eq 2 ]] && has "RELEASE_RESULT=unavailable" && ! has "RELEASE_STAGE=prepare"; then
    ok "private リポジトリを確認できない実行は prepare 前に停止"
  else bad "private リポジトリを確認せずに進んだ"; dump; fi

  : >"$STATE/issue-readback-mismatch"
  run_orch --executor first --expect-version "$version" --approved-head "$approved"
  rm "$STATE/issue-readback-mismatch"
  if [[ "$RC" -eq 1 ]] && has "読み戻し" && ! has "RELEASE_STAGE=prepare"; then
    ok "担当 token の読み戻し不一致は prepare 前に停止"
  else bad "担当 token の読み戻し不一致で停止しない"; dump; fi
  run_orch --executor second --expect-version "$version" --approved-head "$approved"
  if [[ "$RC" -eq 1 ]] && has "first が走行中" && ! has "RELEASE_STAGE=prepare"; then
    ok "別 token の担当が走行中なら prepare 前に停止"
  else bad "走行中の担当を上書きした"; dump; fi
  [[ "$(count_runall)" == "$before" && "$(git -C "$PUB_ORIGIN" rev-parse main)" == "$pub_before" ]] || bad "担当を取得できない回が公開へ進んだ"
  # Expire the simulated abandoned owner without wall-clock sleeps.
  saved="$(jq -c '.[0].body |= sub("\"started\":[0-9]+"; "\"started\":1")' "$issue_db")"
  printf '%s\n' "$saved" >"$issue_db"
  : >"$STATE/public-layout.red"
  run_orch --executor second --take-over --expect-version "$version" --approved-head "$approved"
  rm "$STATE/public-layout.red"
  if [[ "$RC" -eq 1 ]] && has "RELEASE_FIXED_HEAD=" && has "RELEASE_RESULT=stopped" &&
    jq -e '.[0] | (.state == "open") and (.body | contains("\"owner\":null")) and (.comments | any(contains("stopped (gate)")))' "$issue_db" >/dev/null; then
    ok "固定後の停止は担当欄を空にし、走行中 Issue に停止段と再開方法を記録"
  else bad "固定後の停止を再開できる形で記録できない"; dump; fi
  if [[ "$(release_issue_tail 0)" == "$tail_before" ]] && release_notice_once 0; then
    ok "担当の取得・固定・停止の書き込みも末尾の告知欄をそのまま保つ"
  else bad "担当情報の更新が末尾の告知欄を変えた"; dump; fi
  if ! has "RELEASE_NOTICE=" && [[ "$dry_plan" != *"RELEASE_NOTICE="* ]]; then
    ok "停止した本実行と dry-run は RELEASE_NOTICE= を出さない"
  else bad "停止または dry-run が RELEASE_NOTICE= を出した"; dump; fi
  pinned="$(git -C "$SSOT_ORIGIN" rev-parse develop)"
  git -C "$other" fetch -q origin develop
  git -C "$other" checkout -q --detach "$pinned"
  cp -R "$SSOT/plugins/ff-media-toolkit/node_modules" "$other/plugins/ff-media-toolkit/"
  saved="$(cat "$issue_db")"
  RC=0
  OUT="$(RELEASE_RT_MEDIA="$(cd "$other/plugins/ff-media-toolkit" && pwd -P)" \
    bash "$other/scripts/release-dev-toolkit.sh" --public "$PUB" --dry-run 2>&1)" || RC=$?
  if [[ "$RC" -eq 0 && "$(release_head)" == "$pinned" && "$(cat "$issue_db")" == "$saved" ]] && has "RELEASE_RESULT=dry-run"; then
    ok "別 clone で固定 SHA の dry-run ができる"
  else bad "別 clone で固定 SHA の承認を取り直せない"; dump; fi
  printf '%s\n' pinned >"$STATE/runall.advance"
  run_orch --public ../public --executor second --expect-version "$version" --approved-head "$approved"
  if [[ "$RC" -eq 0 ]] && has "RELEASE_RESULT=released" &&
    [[ "$(count_runall)" -eq "$((before + 2))" ]] &&
    git -C "$SSOT_ORIGIN" cat-file -e develop:plugins/ff-dev-toolkit/scripts/next-release.txt &&
    ! git -C "$PUB_ORIGIN" cat-file -e main:plugins/ff-dev-toolkit/scripts/next-release.txt 2>/dev/null &&
    jq -e 'length == 2 and .[0].state == "closed" and .[1].state == "open" and (.[0].comments | any(contains("から引き継ぎ"))) and (.[0].comments | any(contains("released:")))' "$issue_db" >/dev/null; then
    ok "別 clone の前進は次の Issue へ回し、固定した版だけ公開して走行中 Issue を閉じる"
  else bad "固定リリースの公開・比較リンク・次の受付の分離に失敗 (rc=$RC)"; dump; fi
  # Closing means publication is done; the X announcement is still open work.
  notice_order="$(printf '%s\n' "$OUT" | awk '/^RELEASE_NOTICE=/ { n = NR } /^RELEASE_RESULT=/ { r = NR } END { print (n && r && n < r) ? "before" : "other" }')"
  if [[ "$notice_order" == before ]] && has "RELEASE_NOTICE=pending https://github.com/$private_repo/issues/1" &&
    jq -e '.[0].comments | any(startswith("released:") and contains("公開処理は完了") and contains("X 告知（@feelflow_ai）は未投稿"))' "$issue_db" >/dev/null &&
    [[ "$(release_issue_tail 0)" == "$tail_before" ]] && release_notice_once 1; then
    ok "公開完了の close は X 告知を未投稿の別作業としてコメントと RELEASE_NOTICE=pending で残し、次の受付にも告知欄を付ける"
  else bad "公開完了の close が X 告知の残りを示さない (order=$notice_order)"; dump; fi
  release_notice_finish_probe
  release_crlf_probe
  release_issue_jq_cr_probe

  if [[ -n "$HOOK" && -f "$HOOK" ]]; then
    mkdir -p "$SSOT/.claude/hooks"
    cp "$HOOK" "$SSOT/.claude/hooks/post-merge-dev-toolkit-sync.sh"
    cp "$REPO_ROOT/.claude/hooks/session-start-sync-drift.sh" "$SSOT/.claude/hooks/"
    printf '%s\n' plugins/ff-dev-toolkit/skills/demo/SKILL.md changelog.d/2649.fixed.release-issue.md >"$STATE/pr-files"
    OUT="$(printf '%s' '{"tool_input":{"command":"gh pr merge 77 --squash"}}' | bash "$SSOT/.claude/hooks/post-merge-dev-toolkit-sync.sh" 2>&1)"
    if has "issues/2 RELEASE_DUE=" && ! has "しますか"; then ok "PostToolUse は受付 URL と時期だけ通知"; else bad "PostToolUse の受付通知"; dump; fi
    : >"$STATE/drift.stale"
    OUT="$(bash "$SSOT/.claude/hooks/session-start-sync-drift.sh" </dev/null 2>&1)"
    rm "$STATE/drift.stale"
    if has "最新の未同期件数を確かめられない" && ! has "しますか"; then ok "SessionStart の受付失敗は理由だけ通知"; else bad "SessionStart の失敗通知"; dump; fi
  fi
}
