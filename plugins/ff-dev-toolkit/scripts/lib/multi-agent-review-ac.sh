#!/usr/bin/env bash
# Optional AC acquisition for multi-review only. Source once with the other pinned parts.
# No model/API client here: gh or the existing raw-file provider supplies the bytes.
# Fixture-only: tests export MULTI_AGENT_AC_FIXTURE. Production does not read it.
# pipefail-inherited: multi-agent.sh が set -euo pipefail の下で source する

# Parts must not start a line with source. Load helpers from a function so a missing
# or empty file stops before any model, including when automatic acquisition is off.
review_ac_load_helper() { # <path>
  if [[ ! -s "$1" ]]; then
    echo "ERROR: 依存 helper が読めません: $1" >&2
    exit 2
  fi
  if ! . "$1"; then
    echo "ERROR: 依存 helper が読めません: $1" >&2
    exit 2
  fi
}
# check-closing-keywords.sh は source しない。--list-keywords の実行時だけ使い、
# 無い・空・失敗でもレビュー起動は止めない（サイズ検査のみ。AC は理由を出して省く）。
review_ac_load_helper "${SCRIPT_DIR}/lib/github-input.sh"
review_ac_load_helper "${SCRIPT_DIR}/lib/merge-message.sh"

review_ac_note() {
  printf 'ℹ️ review AC: %s\n' "$*" >> "$REVIEW_AC_DIAGNOSTICS"
}

review_ac_fetch_detail() {
  [[ -f "$REVIEW_AC_TMP/fetch.err" ]] || return 0
  # ロケールのバイト切りは多バイト文字の途中で切れ、後段の UTF-8 読取がレビュー全体を止める。
  python3 -I - "$REVIEW_AC_TMP/fetch.err" <<'PY' || true
import pathlib, sys
raw = pathlib.Path(sys.argv[1]).read_bytes().split(b"\n", 1)[0]
text = raw.decode("utf-8", "replace")
sys.stdout.write("".join(ch for ch in text if ord(ch) >= 32)[:160])
PY
}

review_ac_failed_note() { # <operation> <target> <continuation>
  local detail
  detail="$(review_ac_fetch_detail)"
  if [[ -n "$detail" ]]; then
    review_ac_note "$1 $2: acquisition failed (${detail}); $3"
  else
    review_ac_note "$1 $2: acquisition failed; $3"
  fi
}

review_ac_fetch() { # operation repository selector output
  local op="$1" repo="$2" selector="$3" output="$4"
  if [[ -n "$REVIEW_AC_GITHUB_INPUT" ]]; then
    if [[ "$op" == review.ac.pr ]]; then
      jq -n --arg repository "$repo" --arg branch "$selector" \
        '{repository:$repository,branch:$branch}' > "$REVIEW_AC_TMP/scope.json" || return 2
    else
      jq -n --arg repository "$repo" --argjson issue "$selector" \
        '{repository:$repository,issue:$issue}' > "$REVIEW_AC_TMP/scope.json" || return 2
    fi
    github_file_read "$REVIEW_AC_GITHUB_INPUT" "$op" "$REVIEW_AC_TMP/scope.json" initial \
      "$REVIEW_AC_TMP/position.json" > "$output" 2> "$REVIEW_AC_TMP/fetch.err"
  elif [[ "$op" == review.ac.pr ]]; then
    gh pr view "$selector" --repo "$repo" \
      --json number,url,headRefName,body,closingIssuesReferences > "$output" 2> "$REVIEW_AC_TMP/fetch.err"
  else
    gh issue view "$selector" --repo "$repo" --json number,url,body \
      > "$output" 2> "$REVIEW_AC_TMP/fetch.err"
  fi
}

review_ac_sections() { # issue JSON → exact selected Markdown spans
  python3 -I - "$1" <<'PY'
import json, re, sys
body = json.load(open(sys.argv[1], encoding='utf-8'))['body']
lines = body.splitlines(keepends=True)
headings, fence, comment = [], None, False
for i, line in enumerate(lines):
    if fence:
        mark = re.match(r'^ {0,3}(`{3,}|~{3,})(.*)$', line)
        if mark and mark[1][0] == fence[0] and len(mark[1]) >= fence[1] and not mark[2].strip():
            fence = None
        continue
    if not comment:
        opening = re.match(r'^ {0,3}(`{3,}|~{3,})(.*)$', line)
        if opening:
            fence = (opening[1][0], len(opening[1]))
            continue
    # Comments can begin/end mid-line; their text cannot create a heading.
    visible, at = '', 0
    while at < len(line):
        if comment:
            end = line.find('-->', at)
            if end < 0:
                break
            comment, at = False, end + 3
        else:
            start = line.find('<!--', at)
            if start < 0:
                visible += line[at:]
                break
            visible += line[at:start]
            comment, at = True, start + 4
    mark = re.match(r'^ {0,3}(`{3,}|~{3,})(.*)$', visible)
    if mark:
        fence = (mark[1][0], len(mark[1]))
        continue
    h = re.match(r'^ {0,3}(#{1,6})[ \t]+(.+?)\s*$', visible)
    if h:
        title = re.sub(r'[ \t]+#+[ \t]*$', '', h[2]).strip()
        title = re.sub(r'\s*[（(][^()（）]*[）)]\s*$', '', title).strip().casefold()
        headings.append((i, len(h[1]), title))
names = {'受け入れ条件', '受け入れ基準', 'acceptance criteria', 'definition of done', 'dod', '完了条件'}
covered = set()
for pos, (start, level, title) in enumerate(headings):
    if title not in names:
        continue
    end = next((j for j, depth, _ in headings[pos+1:] if depth <= level), len(lines))
    # Empty headings alone are not usable acceptance context.
    if not ''.join(lines[start+1:end]).strip():
        continue
    for n in range(start, end):
        if n not in covered:
            sys.stdout.buffer.write(lines[n].encode('utf-8'))
            covered.add(n)
PY
}

review_ac_acquire() {
  local raw="$REVIEW_AC_TMP/pr.json" repo_path host tokens keywords body token issue_repo number url
  if ! command -v jq >/dev/null 2>&1; then
    review_ac_note 'review.ac.pr: jq unavailable; AC なしで継続'; return 0
  fi
  if [[ -z "$REVIEW_AC_GITHUB_INPUT" ]] && ! command -v gh >/dev/null 2>&1; then
    review_ac_note 'review.ac.pr: gh unavailable; AC なしで継続'; return 0
  fi
  if [[ -z "$REVIEW_AC_REPOSITORY" || -z "$REVIEW_AC_BRANCH" ]]; then
    review_ac_note 'review.ac.pr: configured origin / current branch unavailable; AC なしで継続'; return 0
  fi
  printf '{}\n' > "$REVIEW_AC_TMP/position.json" || return 1
  if ! review_ac_fetch review.ac.pr "$REVIEW_AC_REPOSITORY" "$REVIEW_AC_BRANCH" "$raw"; then
    review_ac_failed_note "review.ac.pr" "${REVIEW_AC_REPOSITORY} branch ${REVIEW_AC_BRANCH}" "AC なしで継続"
    return 0
  fi
  if ! jq -e --arg branch "$REVIEW_AC_BRANCH" --arg prefix "$REVIEW_AC_REPOSITORY/pull/" '
    type == "object" and (.number | type == "number" and . > 0 and floor == .)
    and (.body | type == "string" and (contains("\u0000") | not)) and .headRefName == $branch
    and (.url | type == "string")
    and ((.url | ascii_downcase) == (($prefix + (.number|tostring)) | ascii_downcase))
    and (.closingIssuesReferences | type == "array")
    and all(.closingIssuesReferences[]; (.url | type == "string"))
  ' "$raw" >/dev/null 2>&1; then
    review_ac_note "review.ac.pr ${REVIEW_AC_REPOSITORY}: missing / invalid fields or PR identity; AC なしで継続"; return 0
  fi
  host="${REVIEW_AC_REPOSITORY%/*/*}"
  repo_path="${REVIEW_AC_REPOSITORY#"$host/"}"
  if ! tokens="$(jq -er --arg prefix "$host/" '
    [.closingIssuesReferences[].url
      | if startswith($prefix) then ltrimstr($prefix) else error("foreign host") end
      | if test("^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+/issues/[1-9][0-9]*$")
        then sub("/issues/"; "#") else error("invalid issue URL") end] | join("\n")
    ' "$raw" 2>/dev/null)"; then
    review_ac_note "review.ac.pr ${REVIEW_AC_REPOSITORY}: invalid closing reference identity; AC なしで継続"; return 0
  fi
  body="$(jq -r '.body' "$raw")" || return 1
  if [[ ! -s "$SCRIPT_DIR/check-closing-keywords.sh" ]] \
    || ! keywords="$(bash "$SCRIPT_DIR/check-closing-keywords.sh" --list-keywords)"; then
    review_ac_note 'review.ac.pr: check-closing-keywords.sh unavailable; AC なしで継続'
    return 0
  fi
  if ! ff_merge_issue_sets "$repo_path" "$body" "$tokens" "$keywords"; then
    review_ac_note 'review.ac.pr: closing keyword set unavailable; AC なしで継続'
    return 0
  fi
  tokens="$(printf '%s\n' "$CLOSES_UNION" "$REFS_ONLY" | LC_ALL=C sort -u)" || return 1
  if [[ -z "$tokens" ]]; then review_ac_note "review.ac.pr ${REVIEW_AC_REPOSITORY}: referenced Issue なし; AC なしで継続"; fi
  while IFS= read -r token; do
    [[ -n "$token" ]] || continue
    issue_repo="${token%#*}"; number="${token##*#}"; url="$host/$issue_repo"
    if ! review_ac_fetch review.ac.issue "$url" "$number" "$REVIEW_AC_TMP/issue.json"; then
      review_ac_failed_note "review.ac.issue" "$token" "この Issue の AC なしで継続"
      continue
    fi
    if ! jq -e --argjson n "$number" --arg url "$url/issues/$number" '
      type == "object" and .number == $n and (.url | type == "string")
      and ((.url | ascii_downcase) == ($url | ascii_downcase))
      and (.body | type == "string" and (contains("\u0000") | not))
      ' "$REVIEW_AC_TMP/issue.json" >/dev/null 2>&1; then
      review_ac_note "review.ac.issue ${token}: missing / invalid fields or Issue identity; この Issue の AC なしで継続"; continue
    fi
    if ! review_ac_sections "$REVIEW_AC_TMP/issue.json" > "$REVIEW_AC_TMP/sections.md"; then
      review_ac_note "review.ac.issue ${token}: section extraction failed; この Issue の AC なしで継続"; continue
    fi
    if [[ ! -s "$REVIEW_AC_TMP/sections.md" ]]; then
      review_ac_note "review.ac.issue ${token}: AC / DoD section なし; この Issue の AC なしで継続"; continue
    fi
    if grep -qF '<<<FF-PRIOR-REVIEW-CONTEXT-END>>>' "$REVIEW_AC_TMP/sections.md"; then
      review_ac_note "review.ac.issue ${token}: reserved context delimiter; この Issue の AC なしで継続"; continue
    fi
    printf '\n## Issue %s (#%s) — acceptance context\n\n' "$issue_repo" "$number" >> "$REVIEW_AC_TMP/context.txt" || return 1
    cat "$REVIEW_AC_TMP/sections.md" >> "$REVIEW_AC_TMP/context.txt" || return 1
    printf '\n' >> "$REVIEW_AC_TMP/context.txt" || return 1
    review_ac_note "AC を事前投入した（#${number}） ${issue_repo}"
  done <<< "$tokens"
}

prepare_review_ac() {
  [[ "$REVIEW_AC_AUTO" == true && "$DESCRIPTION_EXPLICIT" != true ]] || return 0
  local head pending='' reuse=false snapshot="$OUTPUT_DIR/.review-ac.json" previous_auto=false prior=''
  head="$(git -C "$REPO_ROOT" rev-parse HEAD)" || return 1
  REVIEW_AC_BRANCH="$(git -C "$REPO_ROOT" symbolic-ref --quiet --short HEAD 2>/dev/null)" || REVIEW_AC_BRANCH=''
  REVIEW_AC_REPOSITORY="$(_github_input_repository 2>/dev/null)" || REVIEW_AC_REPOSITORY=''
  if [[ -n "$DELEGATION_PREVIOUS_GENERATION" && "$head" == "$DELEGATION_PREVIOUS_HEAD" ]]; then
    pending="$(delegation_pending_entries "$DELEGATION_PREVIOUS_GENERATION")" || return 1
    if [[ -n "$pending" ]]; then prior="$DELEGATION_PREVIOUS_MANIFEST"; fi
  fi
  if [[ -z "$prior" && "$RESUME" == true && -f "$OUTPUT_DIR/.resume-cache/last-inputs" \
    && ! -L "$OUTPUT_DIR/.resume-cache" && ! -L "$OUTPUT_DIR/.resume-cache/last-inputs" ]]; then
    prior="$(cat "$OUTPUT_DIR/.resume-cache/last-inputs")" || return 1
    case $'\n'"$prior"$'\n' in *$'\n'"head=$head"$'\n'*) ;; *) prior='' ;; esac
  fi
  case $'\n'"$prior"$'\n' in *$'\nreview-ac=auto\n'*) previous_auto=true ;; esac
  # 前回が AC なしで続行した回（review-ac=unavailable）の同じ HEAD の再開は、AC なしのまま揃える。
  # 前回の description は空なので、後から python3 が入っても取得し直すと入力が変わり再開できない。
  case $'\n'"$prior"$'\n' in
    *$'\nreview-ac=unavailable\n'*)
      if [[ "$RESUME" == true || -n "$pending" ]]; then
        REVIEW_AC_UNAVAILABLE=true
        echo "ℹ️ review AC: review.ac.pr: 前回は AC なしで継続した回のため、再開も AC なしで継続" >&2
        return 0
      fi
      ;;
  esac
  # An omitted explicit description is an input mismatch, not a missing AC receipt.
  # Leave it to the existing delegation guard, before fetching or writing anything.
  if [[ "$RESUME" == true && -n "$pending" && "$previous_auto" != true ]]; then return 0; fi
  if [[ "$previous_auto" == true && ( "$RESUME" == true || -n "$pending" ) ]]; then reuse=true; fi
  # 取得できないときは理由を出して継続する。python3 が無いホストで説明文なしの
  # 既定起動を止めない。同じ HEAD の再利用は元の入力を失わないよう拒否したまま。
  # 続行した回は review-ac=unavailable として記録し、再開を上の分岐で AC なしに揃える。
  if ! command -v python3 >/dev/null 2>&1; then
    if [[ "$reuse" == true ]]; then
      echo "ERROR: review AC: python3 unavailable; refusing to resume without the original snapshot" >&2
      return 1
    fi
    REVIEW_AC_UNAVAILABLE=true
    echo "ℹ️ review AC: review.ac.pr: python3 unavailable; AC なしで継続" >&2
    return 0
  fi
  REVIEW_AC_TMP="$(mktemp -d "${TMPDIR:-/tmp}/ff-review-ac.XXXXXX")" || return 1
  REVIEW_AC_DIAGNOSTICS="$REVIEW_AC_TMP/diagnostics.txt"
  : > "$REVIEW_AC_TMP/context.txt"; : > "$REVIEW_AC_DIAGNOSTICS"
  # Read/validate first. A same-HEAD resume may never erase its original context.
  if ! python3 -I - "$snapshot" "$head" "$REVIEW_AC_REPOSITORY" "$REVIEW_AC_BRANCH" "$reuse" "$REVIEW_AC_TMP" <<'PY'
import hashlib, json, pathlib, sys
path, head, repo, branch, reuse, tmp = sys.argv[1:]
p = pathlib.Path(path)
try:
    if not p.exists():
        if reuse == 'true':
            raise ValueError('snapshot missing; restore original output-dir or start a new round')
        sys.exit(0)
    if reuse != 'true':
        sys.exit(0)
    saved = json.loads(p.read_text(encoding='utf-8'))
    payload = saved['payload']
    digest = hashlib.sha256(json.dumps(payload, ensure_ascii=False, sort_keys=True).encode()).hexdigest()
    if saved['sha256'] != digest or payload['version'] != 1:
        raise ValueError('snapshot corrupt')
    if payload['head'] != head:
        sys.exit(0)  # New HEAD: existing resume identity invalidates old results too.
    if (payload['repository'], payload['branch']) != (repo, branch):
        raise ValueError('snapshot repository / branch mismatch')
    for key in ('context', 'diagnostics'):
        if not isinstance(payload[key], str):
            raise ValueError('snapshot invalid field: ' + key)
        pathlib.Path(tmp, key + '.txt').write_bytes(payload[key].encode('utf-8'))
    pathlib.Path(tmp, 'reused').touch()
except (OSError, ValueError, KeyError, TypeError) as e:
    print('ERROR: review AC: ' + str(e), file=sys.stderr)
    sys.exit(1)
PY
  then
    rm -rf "$REVIEW_AC_TMP"
    REVIEW_AC_TMP=''
    if [[ "$reuse" == true ]]; then return 1; fi
    REVIEW_AC_UNAVAILABLE=true
    echo "ℹ️ review AC: review.ac.pr: python3 failed to check the snapshot; AC なしで継続" >&2
    return 0
  fi
  if [[ ! -f "$REVIEW_AC_TMP/reused" ]]; then
    review_ac_acquire || { rm -rf "$REVIEW_AC_TMP"; return 1; }
  fi
  DESCRIPTION="$(cat "$REVIEW_AC_TMP/context.txt" && printf X)" || return 1
  DESCRIPTION="${DESCRIPTION%X}"
  cat "$REVIEW_AC_DIAGNOSTICS" >&2
}

discard_review_ac() {
  if [[ -n "$REVIEW_AC_TMP" ]]; then
    rm -rf "$REVIEW_AC_TMP"
    REVIEW_AC_TMP=''
  fi
}

commit_review_ac() {
  [[ -n "$REVIEW_AC_TMP" ]] || return 0
  # Called only after the unchanged delegation-input guard has accepted this input.
  python3 -I - "$OUTPUT_DIR" "$REVIEW_AC_TMP" "$REVIEW_AC_REPOSITORY" "$REVIEW_AC_BRANCH" <<'PY'
import hashlib, json, os, pathlib, subprocess, sys, tempfile
out, tmp, repo, branch = map(str, sys.argv[1:])
head = subprocess.check_output(['git', 'rev-parse', 'HEAD'], text=True).strip()
payload = dict(version=1, head=head, repository=repo, branch=branch,
               context=pathlib.Path(tmp, 'context.txt').read_bytes().decode('utf-8'),
               diagnostics=pathlib.Path(tmp, 'diagnostics.txt').read_bytes().decode('utf-8', 'replace'))
data = dict(payload=payload, sha256=hashlib.sha256(json.dumps(payload, ensure_ascii=False, sort_keys=True).encode()).hexdigest())
for name, content in (('.review-ac.json', json.dumps(data, ensure_ascii=False)), ('.review-ac-context.txt', payload['context'])):
    fd, temp = tempfile.mkstemp(prefix='.ac-save.', dir=out)
    try:
        with os.fdopen(fd, 'wb') as f:
            f.write(content.encode('utf-8'))
        os.replace(temp, pathlib.Path(out, name))
    finally:
        if os.path.exists(temp):
            os.unlink(temp)
PY
  local rc=$?
  rm -rf "$REVIEW_AC_TMP"; REVIEW_AC_TMP=''
  [[ "$rc" -eq 0 ]] || return "$rc"
  DESCRIPTION_FILE="$OUTPUT_DIR/.review-ac-context.txt"
}

_ma_part_loaded="multi-agent-review-ac.sh"
