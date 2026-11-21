#!/usr/bin/env bash
# Shared private output namespaces for the orchestrator and review-lane hook.
# Cross-UID isolation relies on private directories and non-writable ancestors;
# an arbitrary hostile process using the same UID is not isolated by this helper.
# pipefail-inherited: multi-agent.sh inherits set -euo pipefail; hooks check rc.

ff_review_output_error() {
  echo "ERROR: unsafe review output boundary: $*" >&2
  echo '       Existing contents were left in place. Move old results aside manually or select a new empty --output-dir.' >&2
  return 1
}

# Commands the user can paste as-is after a refused existing root (Issue `#2514`).
# Neither suggestion leaves a new unignored path beside the root in the checkout.
ff_review_output_next_step() { # <refused-output-root> [marked:true|false]
  if [[ "${2:-false}" == true ]]; then
    if ff_review_output_windows; then
      printf '       Next: this root carries the ownership marker; chmod cannot change a Windows ACL. If a knowledge-read line above names a place and a SID, remove that access entry (folder Properties > Security); if none is named, the ACL helper could not answer. Then rerun unchanged: %q\n' "$1" >&2
      return 0
    fi
    printf '       Next: this root carries the ownership marker and only lost its owner-only mode; restore it, then rerun unchanged: chmod 700 %q\n' "$1" >&2
    return 0
  fi
  echo '       Next (either one; neither reads nor deletes the old results):' >&2
  echo '         - rerun with a new private directory outside the checkout: --output-dir "$(mktemp -d)/output"' >&2
  printf '         - or move the old directory out of the checkout (the OS may clean temp later), then rerun unchanged: mv -- %q "$(mktemp -d)/"\n' "$1" >&2
}

ff_review_output_stat() { # <path> <mode|uid>
  local result gnu bsd
  # BSD %Lp drops setuid/setgid/sticky; %Mp carries them. Without it the sticky
  # exemption below never fires on macOS and /private/tmp/... is refused.
  case "$2" in mode) gnu=%a; bsd=%Mp%Lp ;; uid) gnu=%u; bsd=%u ;; *) return 1 ;; esac
  result="$(stat -c "$gnu" "$1" 2>/dev/null)" || result="$(stat -f "$bsd" "$1" 2>/dev/null)" || return 1
  case "$result" in ''|*[!0-9]*) return 1 ;; esac
  # One spelling on both stats: 0700 -> 700, 01777 -> 1777.
  [[ "$2" != mode ]] || result="$(printf '%o' "$((8#$result))")"
  printf '%s\n' "$result"
}

# Git Bash cannot clear the group/other bits and stat reports 755, so on Windows the
# POSIX mode proves nothing (Issue `#2478`, ADR-078). The ACL helper of the knowledge
# read boundary answers instead. Only the orchestrator loads it, starting PowerShell
# once; the review-lane hook must not wait for that within its time limit, so there
# the check is refused, as the mode check refused it before.
ff_review_output_windows() {
  case "${OSTYPE:-}" in msys*|cygwin*) return 0 ;; esac
  return 1
}

# A refusal that names a place and a SID is a verdict on the ACL; anything else means
# the helper could not answer (PowerShell did not start, timed out or replied in
# another form), and the message must not send the user looking for access entries.
ff_review_output_acl_refusal() { # <diagnosis> <path> <what the verdict would mean>
  [[ -z "$1" ]] || printf '%s\n' "$1" >&2
  case "$1" in
    *'knowledge-read: 止めた場所: '*) ff_review_output_error "${3} (named above): ${2}" ;;
    *) ff_review_output_error "this directory could not be verified (no ACL verdict was given: the helper did not answer, or the chain was refused before it was asked; see the knowledge-read lines above): ${2}" ;;
  esac
}

ff_review_output_windows_acl() { # <private|inspect|private-staging> <canonical dir>
  local diagnosis
  [[ "$(type -t ff_knowledge_windows_acl 2>/dev/null)" == function ]] || {
    ff_review_output_error "cannot verify the Windows ACL here (the ACL helper is not loaded): ${2}"; return 1
  }
  diagnosis="$(ff_knowledge_windows_acl "$1" "$2" 2>&1)" && return 0
  ff_review_output_acl_refusal "$diagnosis" "$2" 'the Windows ACL does not keep this directory private'
  return 1
}

ff_review_output_private() { # <dir> [root:true|false]
  local path="$1" mode bits mask=$((8#022))
  [[ -d "$path" && ! -L "$path" && -O "$path" ]] || {
    ff_review_output_error "directory is not an owned real directory: ${path}"; return 1
  }
  if ff_review_output_windows; then
    # The root grants no right outside the trusted SIDs; below it, no write.
    if [[ "${2:-false}" == true ]]; then ff_review_output_windows_acl private "$path"
    else ff_review_output_windows_acl inspect "$path"; fi
    return
  fi
  mode="$(ff_review_output_stat "$path" mode)" || return 1
  bits=$((8#$mode))
  [[ "${2:-false}" != true ]] || mask=$((8#077))
  [[ $((bits & mask)) -eq 0 ]] || {
    ff_review_output_error "directory must be private (owner only; mode 700): ${path}"; return 1
  }
}

# Quiet probe. A suggestion must not call back into the line that prints the
# suggestion, or the refusal recurses. A nonempty directory also needs the
# ownership marker prepare will require, or the named path is refused on retry.
ff_review_output_dir_nonempty() { # <dir>
  local entry
  for entry in "$1"/* "$1"/.[!.]* "$1"/..?*; do
    [[ -e "$entry" || -L "$entry" ]] || continue
    return 0
  done
  return 1
}

ff_review_output_candidate_passes() { # <existing-dir> [repo]
  local marker
  [[ -n "$1" && "$1" != *$'\n'* && -d "$1" && ! -L "$1" ]] || return 1
  FF_REVIEW_OUTPUT_SUGGESTING=true ff_review_output_ancestors "$1" >/dev/null 2>&1 || return 1
  FF_REVIEW_OUTPUT_SUGGESTING=true ff_review_output_private "$1" true >/dev/null 2>&1 || return 1
  ff_review_output_dir_nonempty "$1" || return 0
  [[ -n "${2:-}" ]] || return 1
  marker="$1/.multi-agent-output-owner"
  ff_review_output_regular "$marker" || return 1
  ff_review_output_marker_matches "$marker" "$2" "$1"
}

# Create one component at a time, and only after the nearest existing parent
# already passes. Never mkdir under an ancestor the boundary refuses.
ff_review_output_try_create_private() { # <absolute-path>
  local path="$1" parent cur rest component
  [[ "$path" == /* && "$path" != *$'\n'* ]] || return 1
  [[ ! -e "$path" && ! -L "$path" ]] || return 1
  parent="$path"
  while [[ ! -d "$parent" || -L "$parent" ]]; do
    [[ "$parent" != / ]] || return 1
    parent="${parent%/*}"
    [[ -n "$parent" ]] || parent=/
  done
  FF_REVIEW_OUTPUT_SUGGESTING=true ff_review_output_ancestors "${parent%/}/placeholder" >/dev/null 2>&1 || return 1
  if [[ "$parent" == / ]]; then cur=""; rest="${path#/}"; else cur="$parent"; rest="${path#"$parent"/}"; fi
  while [[ -n "$rest" ]]; do
    component="${rest%%/*}"
    [[ "$rest" == */* ]] && rest="${rest#*/}" || rest=""
    [[ -n "$component" && "$component" != "." && "$component" != ".." ]] || return 1
    cur="${cur}/${component}"
    if [[ -d "$cur" && ! -L "$cur" ]]; then
      continue
    fi
    [[ ! -e "$cur" && ! -L "$cur" ]] || return 1
    (umask 077; mkdir -- "$cur") || return 1
    [[ -d "$cur" && ! -L "$cur" && -O "$cur" ]] || return 1
  done
  [[ "$cur" == "$path" ]] || return 1
  FF_REVIEW_OUTPUT_SUGGESTING=true ff_review_output_ancestors "$path" >/dev/null 2>&1 || return 1
  FF_REVIEW_OUTPUT_SUGGESTING=true ff_review_output_private "$path" true >/dev/null 2>&1
}

# Name a directory this same boundary has just accepted, including the
# ownership marker when the directory is not empty. May create an owner-only
# candidate so the named path exists. Print no path when every candidate fails.
# implement cannot use a path outside the repository, so the home candidate is
# not offered for that task.
ff_review_output_suggest_passing_dir() { # [repo] [task]
  [[ "${FF_REVIEW_OUTPUT_SUGGESTING:-}" == true ]] && return 0
  local repo="${1:-}" task="${2:-}" home_dir="${HOME:-}" chosen="" home_candidate=""
  if [[ -n "$repo" ]]; then
    repo="$(CDPATH='' cd -P -- "$repo" 2>/dev/null && pwd -P)" || repo=""
  fi
  if [[ -n "$repo" && -d "${repo}/.review-results" && ! -L "${repo}/.review-results" ]]; then
    ff_review_output_candidate_passes "${repo}/.review-results" "$repo" && chosen="${repo}/.review-results"
  fi
  if [[ "$task" != implement && -z "$chosen" && -n "$home_dir" && "$home_dir" != *$'\n'* ]]; then
    home_candidate="${home_dir}/.config/ff-dev-toolkit/tmp/review-output"
    if [[ -d "$home_candidate" && ! -L "$home_candidate" ]]; then
      ff_review_output_candidate_passes "$home_candidate" "$repo" && chosen="$home_candidate"
    elif [[ ! -e "$home_candidate" && ! -L "$home_candidate" ]]; then
      ff_review_output_try_create_private "$home_candidate" && chosen="$home_candidate"
    fi
  fi
  if [[ -z "$chosen" && -n "$repo" && ! -e "${repo}/.review-results" && ! -L "${repo}/.review-results" ]]; then
    ff_review_output_try_create_private "${repo}/.review-results" && chosen="${repo}/.review-results"
  fi
  if [[ -n "$chosen" ]]; then
    printf '       Next: --output-dir %s passes the output boundary (checked before this line was printed).\n' "$chosen" >&2
  else
    echo '       Next: no directory that passes the output boundary could be named. The checked candidates were refused. Do not use scratchpad or a shared temporary directory as --output-dir.' >&2
  fi
}

# An outer owner-only ancestor shields its descendants from other UIDs. Still
# inspect above it: an unprotected writable parent can rename that anchor.
ff_review_output_ancestors() { # <canonical-path> [repo] [task]
  local path="$1" parent mode bits uid unsafe='' diagnosis
  local write_mask=$((8#022)) private_mask=$((8#077)) sticky_bit=$((8#1000))
  if ff_review_output_windows; then
    # The knowledge read boundary walks the same chain: real directories, a trusted
    # owner and no write outside the trusted SIDs, in one helper request.
    parent="${path%/*}"; [[ -n "$parent" ]] || parent=/
    [[ "$(type -t ff_knowledge_storage 2>/dev/null)" == function ]] || {
      ff_review_output_error "cannot verify the Windows ACL of the ancestors here (the ACL helper is not loaded): ${parent}"; return 1
    }
    diagnosis="$(ff_knowledge_storage "$parent" dir 2>&1)" && return 0
    ff_review_output_acl_refusal "$diagnosis" "$parent" 'an ancestor is not owned by you, an administrator or SYSTEM, or others can write it' \
      || ff_review_output_suggest_passing_dir "${2:-}" "${3:-}"
    return 1
  fi
  while :; do
    parent="${path%/*}"; [[ -n "$parent" ]] || parent=/
    [[ -d "$parent" && ! -L "$parent" ]] || return 1
    mode="$(ff_review_output_stat "$parent" mode)" || return 1
    uid="$(ff_review_output_stat "$parent" uid)" || return 1
    [[ "$uid" == 0 || -O "$parent" ]] || {
      ff_review_output_error "ancestor is owned by another user: ${parent}"; return 1
    }
    bits=$((8#$mode))
    if [[ $((bits & write_mask)) -ne 0 ]]; then
      [[ $((bits & sticky_bit)) -ne 0 ]] || unsafe="$parent"
    fi
    # Clear only descendants' risk, never ownership failures or a later
    # writable ancestor above this private directory. Do not chmod old dirs.
    if [[ -O "$parent" && $((bits & private_mask)) -eq 0 ]]; then unsafe=''; fi
    [[ "$parent" != / ]] || break
    path="$parent"
  done
  [[ -z "$unsafe" ]] || {
    ff_review_output_error "ancestor is writable by another user: ${unsafe}" || true
    ff_review_output_suggest_passing_dir "${2:-}" "${3:-}"
    return 1
  }
}

ff_review_output_regular() { # <file> [missing-ok:true|false]
  local file="$1" links
  if [[ ! -e "$file" && ! -L "$file" ]]; then
    [[ "${2:-false}" == true ]]; return $?
  fi
  [[ -f "$file" && ! -L "$file" && -O "$file" ]] || {
    ff_review_output_error "symlink or nonregular output file: ${file}"; return 1
  }
  links="$(stat -c %h "$file" 2>/dev/null)" || links="$(stat -f %l "$file" 2>/dev/null)" || return 1
  [[ "$links" == 1 ]] || { ff_review_output_error "hardlinked output file: ${file}"; return 1; }
}

ff_review_output_marker() { # <canonical-repo> <canonical-output>
  printf 'format=1\nrepository=%s\noutput=%s\n' "$1" "$2"
}

ff_review_output_marker_matches() { # <marker> <repo> <output>
  local attempt
  # Another first-use hook may have opened the exclusive marker immediately
  # before our read. Only a fully matching ordinary file can complete bootstrap.
  for attempt in 1 2 3 4 5; do
    ff_review_output_regular "$1" || return 1
    cmp -s "$1" <(ff_review_output_marker "$2" "$3") && return 0
    [[ "$attempt" == 5 ]] || sleep 0.01
  done
  # Same directory under another spelling. Exact bytes stay the fast path.
  ff_review_output_marker_matches_identity "$1" "$2" "$3" || return 1
}

ff_review_output_host_path() { # <requested>
  local path="$1" scan
  case "${OSTYPE:-}" in msys*|cygwin*)
    # Inspect parent traversal before cygpath can erase it. On Windows all
    # backslashes are separators, including those in relative output paths.
    scan="${path//\\//}"
    case "/${scan}/" in */../*) ff_review_output_error 'parent traversal is not allowed in the output path'; return 1 ;; esac
    case "$scan" in [A-Za-z]:/*|//*)
      command -v cygpath >/dev/null 2>&1 || { ff_review_output_error 'native Windows output paths require cygpath; use a POSIX absolute path'; return 1; }
      path="$(cygpath -u -- "$path")" || { ff_review_output_error 'cannot convert native Windows output path with cygpath'; return 1; }
      [[ "$path" == /* ]] || return 1 ;;
      *) path="$scan" ;;
    esac ;;
  esac
  printf '%s\n' "$path"
}

ff_review_output_lexical_path() { # <absolute-posix-path>
  local path="$1" cur='' rest component prefix=''
  # Exactly two leading slashes can name a Windows UNC root. Keep that spelling.
  case "$path" in //[!/]*) prefix=/ ;; esac
  rest="${path#/}"
  while [[ -n "$rest" ]]; do
    component="${rest%%/*}"; [[ "$rest" == */* ]] && rest="${rest#*/}" || rest=''
    [[ -n "$component" && "$component" != . ]] || continue
    cur="${cur}/${component}"
  done
  printf '%s\n' "${prefix}${cur:-/}"
}

ff_review_output_admin_identity() { # <candidate> <gitdir> <common> [ancestors]
  local candidate="$1" administrative ancestor parent
  for administrative in "$2" "$3"; do
    [[ -n "$administrative" && -d "$administrative" ]] || continue
    ancestor="$administrative"
    while :; do
      if [[ "$candidate" -ef "$ancestor" ]]; then
        ff_review_output_error 'output overlaps Git administrative metadata or an ancestor by physical identity'; return 1
      fi
      [[ "${4:-false}" == true ]] || break
      parent="${ancestor%/*}"; [[ -n "$parent" ]] || parent=/
      [[ "$parent" != "$ancestor" ]] || break
      ancestor="$parent"
    done
  done
  return 0
}

# Resolve a requested output path to its canonical lexical POSIX path.
# Does not create the output directory. Case-fold detection may create and
# remove one probe file when a directory has no letter-bearing child, or when
# an existing child's other spelling is the same inode.
ff_review_output_resolve_path() { # <repo> <requested>
  local repo_arg="$1" requested="$2" repo path alias real suffix system_alias=''
  repo="$(CDPATH='' cd -P -- "$repo_arg" && pwd -P)" || return 1
  [[ -n "$requested" && "$requested" != *$'\n'* && "$repo" != *$'\n'* ]] || return 1
  requested="$(ff_review_output_host_path "$requested")" || return 1
  [[ -n "$requested" && "$requested" != *$'\n'* ]] || return 1
  case "/${requested}/" in */../*) ff_review_output_error 'parent traversal is not allowed in the output path'; return 1 ;; esac
  case "$requested" in /*) path="$requested" ;; *) path="$(pwd -P)/${requested}" ;; esac
  # Permit trusted spelling aliases for the checkout/cwd and system temp root.
  # A caller may replace TMPDIR after selecting an output under the native temp
  # root. Only recognize Darwin's standard identity, never an arbitrary /var link.
  case "${OSTYPE:-}" in
    darwin*)
      if [[ -L /var && -d /private/var && /var -ef /private/var ]]; then system_alias=/var; fi ;;
  esac
  # Suffix symlinks are not resolved or rejected here. ff_review_output_prepare
  # rejects them before mkdir.
  for alias in "${PWD:-}" "$repo_arg" "${TMPDIR:-/tmp}" /tmp "$system_alias"; do
    [[ -n "$alias" && -d "$alias" ]] || continue
    case "$path" in "$alias"|"${alias%/}"/*)
      real="$(CDPATH='' cd -P -- "$alias" && pwd -P)" || return 1
      suffix="${path#"${alias%/}"}"; path="${real%/}${suffix}"; break ;;
    esac
  done
  path="$(ff_review_output_lexical_path "$path")" || return 1
  path="$(ff_review_output_align_repo_prefix "$repo" "$path")" || return 1
  ff_review_output_canonicalize_builtin_spelling "$repo" "$path"
}

# multi-agent-advice.sh の recovery_command() が失敗レーン復旧のために生成する
# 初期化済み既定ルート直下の `.recovery-<YYYYMMDD>-<HHMMSS>-<PID>-<label>` だけを
# 特例として許容する（Issue `#2281` / `#2869`）。未初期化の既定ルート・任意名・2段以上
# の入れ子は引き続き拒否する。
ff_review_output_is_recovery_child() { # <canonical-repo> <default-dir> <canonical-lexical-path>
  local repo="${1%/}" default_dir="${2%/}" path="$3" rel
  case "$path" in
    "${default_dir}"/*) rel="${path#"${default_dir}/"}" ;;
    *) return 1 ;;
  esac
  [[ "$rel" != */* ]] || return 1
  ff_review_output_is_recovery_basename "$rel" || return 1
  [[ -d "$default_dir" && ! -L "$default_dir" ]] || return 1
  [[ -f "${default_dir}/.multi-agent-output-owner" && ! -L "${default_dir}/.multi-agent-output-owner" ]] || return 1
  ff_review_output_marker_matches_identity "${default_dir}/.multi-agent-output-owner" "$repo" "$default_dir"
}

# Exact marker bytes, or the same directory under another spelling (-ef, not a symlink).
ff_review_output_marker_matches_identity() { # <marker> <repo> <output>
  local marker="$1" repo="$2" output="${3%/}" line format='' got_repo='' got_output=''
  ff_review_output_regular "$marker" || return 1
  [[ -r "$marker" ]] || return 1
  cmp -s "$marker" <(ff_review_output_marker "$repo" "$output") && return 0
  [[ -d "$output" && ! -L "$output" ]] || return 1
  while IFS= read -r line || [[ -n "$line" ]]; do
    case "$line" in
      format=1) format=1 ;;
      repository=*) got_repo="${line#repository=}" ;;
      output=*) got_output="${line#output=}" ;;
      '') ;;
      *) return 1 ;;
    esac
  done < "$marker"
  [[ "$format" == 1 && "$got_repo" == "$repo" && -n "$got_output" ]] || return 1
  got_output="${got_output%/}"
  [[ -d "$got_output" && ! -L "$got_output" && "$got_output" -ef "$output" ]]
}

# Basename of a recovery output root from recovery_command (one level, fixed shape).
ff_review_output_is_recovery_basename() { # <basename>
  [[ "$1" =~ ^\.recovery-[0-9]{8}-[0-9]{6}-[0-9]+-[A-Za-z0-9][A-Za-z0-9_-]*$ ]]
}

# Create one probe file, compare its other ASCII spelling, then remove it.
# Create failure returns 1 so a case-sensitive filesystem is not blanket-rejected.
ff_review_output_casefold_probe() { # <dir>
  local dir="${1%/}" probe probe_folded
  probe="${dir}/.ffCaseProbe${$}_${RANDOM}"
  probe_folded="$(printf '%s' "${probe##*/}" | LC_ALL=C tr '[:lower:]' '[:upper:]')"
  probe_folded="${dir}/${probe_folded}"
  if ! (umask 077; set -C; : > "$probe") 2>/dev/null; then
    return 1
  fi
  if [[ -f "$probe" && ! -L "$probe" && -e "$probe_folded" && ! -L "$probe_folded" && "$probe" -ef "$probe_folded" ]]; then
    rm -f -- "$probe" || true
    return 0
  fi
  rm -f -- "$probe" || true
  return 1
}

# 0 when $1's filesystem folds case. A same-inode pair of different spellings
# is confirmed with a new probe so a hardlink cannot impersonate case folding.
# When no letter-bearing child exists, the probe is the only evidence. If that
# probe cannot be created, returns 1 (do not blanket-reject).
ff_review_output_fs_folds_case() { # <dir>
  local dir="$1" child base folded upper lower GLOBIGNORE=''
  [[ -d "$dir" && ! -L "$dir" ]] || return 1
  for child in "$dir"/* "$dir"/.[!.]* "$dir"/..?*; do
    [[ -e "$child" && ! -L "$child" ]] || continue
    base="${child##*/}"
    upper="$(printf '%s' "$base" | LC_ALL=C tr '[:lower:]' '[:upper:]')"
    lower="$(printf '%s' "$base" | LC_ALL=C tr '[:upper:]' '[:lower:]')"
    if [[ "$upper" != "$base" ]]; then
      folded="$upper"
    elif [[ "$lower" != "$base" ]]; then
      folded="$lower"
    else
      continue
    fi
    if [[ -e "${dir}/${folded}" && ! -L "${dir}/${folded}" && "$child" -ef "${dir}/${folded}" ]]; then
      if ff_review_output_casefold_probe "$dir"; then
        return 0
      fi
      return 1
    fi
    return 1
  done
  ff_review_output_casefold_probe "$dir"
}

# Rewrite a non-symlink ancestor that is the repository onto the canonical
# repo spelling. Stop at a symlink so prepare can still reject it.
ff_review_output_align_repo_prefix() { # <repo> <path>
  local repo="${1%/}" path="$2" anc parent suffix up
  case "$path" in
    "$repo"|"${repo}/"*) printf '%s\n' "$path"; return 0 ;;
  esac
  anc="$path"
  while [[ "$anc" == /* && "$anc" != / ]]; do
    parent="${anc%/*}"
    [[ -n "$parent" ]] || parent=/
    if [[ -L "$parent" ]]; then
      printf '%s\n' "$path"
      return 0
    fi
    if [[ -d "$parent" && "$parent" -ef "$repo" ]]; then
      up="$parent"
      while [[ -n "$up" && "$up" != / ]]; do
        if [[ -L "$up" ]]; then
          printf '%s\n' "$path"
          return 0
        fi
        up="${up%/*}"
      done
      suffix="${path#"$parent"}"
      printf '%s\n' "${repo}${suffix}"
      return 0
    fi
    [[ "$parent" != "$anc" ]] || break
    anc="$parent"
  done
  printf '%s\n' "$path"
}

# Built-in default names keep one spelling when the filesystem treats the
# other spelling as the same directory, including before that directory exists.
ff_review_output_canonicalize_builtin_spelling() { # <repo> <path>
  local repo="${1%/}" path="$2" rel first rest name canon variant lower_first lower_name
  case "$path" in
    "${repo}/"*) rel="${path#"${repo}/"}" ;;
    *) printf '%s\n' "$path"; return 0 ;;
  esac
  first="${rel%%/*}"
  rest=""
  [[ "$rel" == */* ]] && rest="${rel#*/}"
  for name in .review-results .explore-results .implement-results; do
    [[ "$first" == "$name" ]] && { printf '%s\n' "$path"; return 0; }
    lower_first="$(printf '%s' "$first" | LC_ALL=C tr '[:upper:]' '[:lower:]')"
    lower_name="$(printf '%s' "$name" | LC_ALL=C tr '[:upper:]' '[:lower:]')"
    [[ "$lower_first" == "$lower_name" ]] || continue
    canon="${repo}/${name}"
    variant="${repo}/${first}"
    if [[ -d "$canon" && ! -L "$canon" && -d "$variant" && ! -L "$variant" && "$variant" -ef "$canon" ]]; then
      :
    elif [[ ! -e "$canon" && ! -L "$canon" && ! -e "$variant" && ! -L "$variant" ]] && ff_review_output_fs_folds_case "$repo"; then
      :
    else
      printf '%s\n' "$path"
      return 0
    fi
    if [[ -n "$rest" ]]; then
      printf '%s/%s/%s\n' "$repo" "$name" "$rest"
    else
      printf '%s/%s\n' "$repo" "$name"
    fi
    return 0
  done
  printf '%s\n' "$path"
}

# 0 when $path is nested under a different spelling of $name and the filesystem
# folds case. The default directory itself is not nested.
ff_review_output_casefold_nested() { # <repo> <path> <default-name>
  local repo="${1%/}" path="$2" name="$3" rel first
  case "$path" in
    "${repo}"/*) rel="${path#"${repo}/"}" ;;
    *) return 1 ;;
  esac
  [[ "$rel" == */* ]] || return 1
  first="${rel%%/*}"
  [[ "$first" != "$name" ]] || return 1
  [[ "$(printf '%s' "$first" | LC_ALL=C tr '[:upper:]' '[:lower:]')" == "$(printf '%s' "$name" | LC_ALL=C tr '[:upper:]' '[:lower:]')" ]] || return 1
  ff_review_output_fs_folds_case "$repo"
}

# One-level child of a case-variant ancestor, rewritten onto the canonical root.
ff_review_output_canonical_child() { # <default-dir> <alias-ancestor> <full-path>
  local default_dir="${1%/}" anc="${2%/}" path="$3" suffix
  case "$path" in
    "${anc}"/*) suffix="${path#"${anc}/"}" ;;
    *) return 1 ;;
  esac
  [[ -n "$suffix" && "$suffix" != */* ]] || return 1
  printf '%s/%s\n' "$default_dir" "$suffix"
}

# A recovery child of a built-in default root anchors the next command at that
# root. Any other recovery-shaped directory stays the output root.
ff_review_output_recovery_anchor() { # <output-dir>
  local dir="${1%/}" base parent parent_base
  base="${dir##*/}"
  if ff_review_output_is_recovery_basename "$base"; then
    parent="${dir%/*}"
    parent_base="${parent##*/}"
    case "$parent_base" in
      .review-results|.explore-results|.implement-results)
        if [[ -n "$parent" && "$parent" != "$dir" ]]; then
          printf '%s\n' "$parent"
          return 0
        fi
        ;;
    esac
  fi
  printf '%s\n' "$dir"
}

# Reject output paths nested under a built-in default output directory (.review-results,
# .explore-results, .implement-results). archive_known_entry stops a later
# --archive-only / --fresh for unknown entries only. Known lane directories and
# .prev-* are not those entries. A one-level recovery child is allowed here.
# The parent archive leaves that child in place only when the child itself is
# an initialized recovery directory for this repository, not because of its name.
ff_review_output_check_nested_default() { # <canonical-repo> <canonical-lexical-path>
  local repo="${1%/}" path="$2" name default_dir anc next_anc matched='' canonical
  for name in .review-results .explore-results .implement-results; do
    default_dir="${repo}/${name}"
    case "$path" in
      "${default_dir}"/*)
        if ff_review_output_is_recovery_child "$repo" "$default_dir" "$path"; then
          return 0
        fi
        matched="$default_dir"; break ;;
    esac
    if [[ -d "$default_dir" && ! -L "$default_dir" && ! "$path" -ef "$default_dir" ]]; then
      anc="${path%/*}"
      while [[ -n "$anc" && "$anc" != / && "$anc" != "$repo" ]]; do
        if [[ -d "$anc" && ! -L "$anc" && "$anc" -ef "$default_dir" ]]; then
          canonical="$(ff_review_output_canonical_child "$default_dir" "$anc" "$path" 2>/dev/null || true)"
          if [[ -n "$canonical" ]] && ff_review_output_is_recovery_child "$repo" "$default_dir" "$canonical"; then
            return 0
          fi
          matched="$default_dir"
          break
        fi
        next_anc="${anc%/*}"
        [[ "$next_anc" != "$anc" ]] || break
        anc="$next_anc"
      done
      [[ -z "$matched" ]] || break
    elif [[ -L "$default_dir" || ! -d "$default_dir" ]] && ff_review_output_casefold_nested "$repo" "$path" "$name"; then
      matched="$default_dir"
      break
    fi
  done
  [[ -z "$matched" ]] || {
    local matched_name="${matched##*/}"
    echo "ERROR: --output-dir cannot be a subdirectory of the default output directory: ${path}" >&2
    echo "       default output directory: ${matched}" >&2
    echo "       Nothing was executed (no CLI was started; existing files under ${matched_name}/ were left untouched)." >&2
    echo "       A subdirectory inside ${matched_name}/ breaks subsequent --archive-only and --fresh runs (archive_known_entry rejects unknown entries)." >&2
    echo "       Use ${matched_name} itself, or choose a directory outside ${matched_name}/ (e.g. a sibling like ${matched_name}-round2 or a private directory under ~/.config/ff-dev-toolkit/tmp/)." >&2
    return 2
  }
  return 0
}

# Stable standalone hook interface. No orchestrator globals are required.
ff_review_output_prepare() { # <repo> <requested> <explicit:true|false> <task>
  local repo_arg="$1" requested="$2" explicit="$3" task="$4" repo path parent cur component rest
  local marker entry empty=true gitdir common rel tracked
  repo="$(CDPATH='' cd -P -- "$repo_arg" && pwd -P)" || return 1
  path="$(ff_review_output_resolve_path "$repo_arg" "$requested")" || return 1
  ff_review_output_check_nested_default "$repo" "$path" || return 1
  case "${path}/" in */.git/*) ff_review_output_error 'output directory overlaps Git administrative metadata'; return 1 ;; esac
  [[ "$path" != "$repo" && ! "$path" -ef "$repo" ]] || { ff_review_output_error 'the output dir must not be the repository root'; return 1; }
  case "$path" in "$repo"/*) : ;; *)
    [[ "$task" != implement ]] || { ff_review_output_error 'implement output dir is outside the CLI sandbox root'; return 1; }
    [[ "$explicit" == true ]] || { ff_review_output_error 'implicit output directory escapes the repository; use explicit --output-dir'; return 1; } ;;
  esac
  if gitdir="$(git -C "$repo" rev-parse --absolute-git-dir 2>/dev/null)"; then
    gitdir="$(CDPATH='' cd -P -- "$gitdir" && pwd -P)" || return 1
    common="$(git -C "$repo" rev-parse --git-common-dir)" || return 1
    # Git for Windows may return a native drive path for a linked worktree's
    # common directory. cd accepts that existing absolute path directly.
    case "$common" in
      /*) : ;;
      [A-Za-z]:/*|[A-Za-z]:\\*)
        case "${OSTYPE:-}" in msys*|cygwin*) : ;; *) common="${repo}/${common}" ;; esac ;;
      *) common="${repo}/${common}" ;;
    esac
    common="$(CDPATH='' cd -P -- "$common" && pwd -P)" || return 1
    for entry in "$gitdir" "$common"; do
      case "$path" in "$entry"|"$entry"/*) ff_review_output_error 'output overlaps Git administrative metadata'; return 1 ;; esac
      case "$entry" in "${path%/}/"*) ff_review_output_error 'output is an ancestor of Git administrative metadata'; return 1 ;; esac
    done
    case "$path" in "$repo"/*)
      rel="${path#"$repo"/}"
      tracked="$(git -C "$repo" ls-files -- ":(literal)${rel}")" || { ff_review_output_error 'cannot query tracked files for output boundary'; return 1; }
      [[ -z "$tracked" ]] || { ff_review_output_error "the output dir contains tracked files: ${path}"; return 1; } ;;
    esac
  elif [[ -e "${repo}/.git" || -L "${repo}/.git" || "${IN_GIT_REPO:-false}" == true ]]; then
    ff_review_output_error 'cannot query Git administrative metadata for output boundary'; return 1
  fi
  ff_review_output_admin_identity "$path" "${gitdir:-}" "${common:-}" true || return 1
  # Links within the output suffix are rejected before any mkdir.
  # Inspect all existing components before creating the first missing one.
  cur=''; rest="${path#/}"
  while [[ -n "$rest" ]]; do
    component="${rest%%/*}"; [[ "$rest" == */* ]] && rest="${rest#*/}" || rest=''
    cur="${cur}/${component}"
    [[ ! -L "$cur" ]] || { ff_review_output_error "output path is a symlink: ${cur}"; return 1; }
    [[ ! -e "$cur" || -d "$cur" ]] || { ff_review_output_error "output path is not a directory: ${cur}"; return 1; }
    # Case aliases can enter .git on a case-insensitive filesystem. Use physical
    # identity rather than blanket case folding (NTFS can be case-sensitive).
    ff_review_output_admin_identity "$cur" "${gitdir:-}" "${common:-}" || return 1
  done
  marker="${path}/.multi-agent-output-owner"
  if [[ -d "$path" ]]; then
    for entry in "$path"/* "$path"/.[!.]* "$path"/..?*; do
      [[ -e "$entry" || -L "$entry" ]] || continue
      empty=false; break
    done
    if [[ "$empty" != true ]]; then
      ff_review_output_private "$path" true || {
        if [[ -f "$marker" && ! -L "$marker" ]]; then ff_review_output_next_step "$path" true
        else ff_review_output_next_step "$path"; fi
        return 1
      }
      ff_review_output_regular "$marker" || {
        ff_review_output_error 'nonempty output directory has no matching ownership marker'
        ff_review_output_next_step "$path"; return 1
      }
      ff_review_output_marker_matches "$marker" "$repo" "$path" || { ff_review_output_error 'output ownership marker does not match repository and output root'; return 1; }
    fi
  fi
  parent="$path"
  while [[ ! -d "$parent" ]]; do parent="${parent%/*}"; [[ -n "$parent" ]] || parent=/; done
  ff_review_output_ancestors "${parent%/}/placeholder" "$repo" "$task" || return 1
  if [[ "$empty" == true ]]; then
    [[ ! -e "$path" || -O "$path" ]] || return 1
    # One component at a time, never mkdir -p: below a sticky shared parent another
    # UID can plant a symlink after the scan above, and -p (then chmod) would follow
    # it. A real directory a same-UID peer created first is accepted.
    if [[ ! -d "$path" ]]; then
      cur="${parent%/}"; rest="${path#"$cur"/}"
      while [[ -n "$rest" ]]; do
        component="${rest%%/*}"; [[ "$rest" == */* ]] && rest="${rest#*/}" || rest=''
        cur="${cur}/${component}"
        (umask 077; mkdir -- "$cur") 2>/dev/null || [[ -d "$cur" && ! -L "$cur" ]] || return 1
        [[ -d "$cur" && ! -L "$cur" && -O "$cur" ]] || { ff_review_output_error "output path changed while it was created: ${cur}"; return 1; }
      done
    fi
    [[ -d "$path" && ! -L "$path" && -O "$path" ]] || return 1
    if ff_review_output_windows; then
      # The ACL counterpart of chmod 700: owner, SYSTEM and administrators only.
      ff_review_output_windows_acl private-staging "$path" || return 1
    else
      chmod 700 "$path" || return 1
    fi
    ff_review_output_private "$path" true || return 1
    for entry in "$path"/* "$path"/.[!.]* "$path"/..?*; do
      [[ -e "$entry" || -L "$entry" ]] || continue
      if [[ "$entry" != "$marker" ]]; then
        # A first-use peer may already have finished initialization and acquired
        # its lane. This is now an ordinary marked root only when its exact
        # secure ownership record matches; unmarked changed roots still refuse.
        if ff_review_output_marker_matches "$marker" "$repo" "$path"; then empty=false; break; fi
        ff_review_output_error 'output changed before ownership initialization'; return 1
      fi
    done
    if [[ "$empty" == true ]] && ! (umask 077; set -C; ff_review_output_marker "$repo" "$path" > "$marker") 2>/dev/null; then
      # A concurrent first-use hook may have initialized this same empty root.
      # Accept its completed marker only after the same no-follow validation.
      ff_review_output_regular "$marker" || return 1
      ff_review_output_marker_matches "$marker" "$repo" "$path" || return 1
    fi
  fi
  ff_review_output_ancestors "$path" "$repo" "$task" || return 1
  printf '%s\n' "$path"
}

# A version from before the private boundary (`#2429`) left the built-in default
# root unmarked (typically mode 755), and prepare refuses it on every run
# (Issue `#2514`). Only the orchestrator — never a hook, an explicit --output-dir
# or a project-config output_dir — renames it whole to a sibling, so the next
# prepare starts a fresh private root. It is never read, chmodded or deleted.
# Anything else is left in place for prepare to refuse as before: another name,
# Git metadata, a marked root, a symlink, another owner, tracked content, a root
# an older run may still be writing (its lock/in-flight names exist), or an
# unsafe ancestor (refused here, before any move).
# Prints the sibling path when something was moved, nothing otherwise.
ff_review_output_set_aside_legacy() { # <repo> <built-in-default-output>
  local repo name legacy entry found=false tracked ts staging admin
  name="${2##*/}"
  case "$name" in .review-results|.explore-results|.implement-results) ;; *) return 0 ;; esac
  [[ "$2" == "${1%/}/${name}" ]] || return 0
  repo="$(CDPATH='' cd -P -- "$1" && pwd -P)" || return 1
  legacy="${repo}/${name}"
  [[ -d "$legacy" && ! -L "$legacy" && -O "$legacy" ]] || return 0
  for admin in "$(git -C "$repo" rev-parse --absolute-git-dir 2>/dev/null)" "$(git -C "$repo" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)"; do
    [[ -z "$admin" || ! "$legacy" -ef "$admin" ]] || return 0
  done
  for entry in .multi-agent-output-owner .multi-agent-run.lock .review-in-flight; do
    [[ ! -e "${legacy}/${entry}" && ! -L "${legacy}/${entry}" ]] || return 0
  done
  for entry in "$legacy"/* "$legacy"/.[!.]* "$legacy"/..?*; do
    [[ -e "$entry" || -L "$entry" ]] || continue
    found=true; break
  done
  [[ "$found" == true ]] || return 0
  tracked="$(git -C "$repo" ls-files -- ":(literal)${name}" 2>/dev/null)" || return 0
  [[ -z "$tracked" ]] || return 0
  ff_review_output_ancestors "$legacy" "$repo" || return 1
  ts="$(date -u +%Y%m%dT%H%M%SZ)" || { ff_review_output_error 'cannot read the clock to name the set-aside directory'; return 1; }
  staging="${legacy}.legacy-${ts}-$$"
  [[ ! -e "$staging" && ! -L "$staging" ]] || { ff_review_output_error "set-aside name already exists: ${staging}"; return 1; }
  # Claim the root with the run-lock name before moving it. A concurrent run (or
  # an older version still writing) then sees the lock and leaves it alone, and
  # the checks above are repeated under the claim: a peer may already have put
  # a new marked (or still empty) root at this name.
  (umask 077; mkdir -- "${legacy}/.multi-agent-run.lock") 2>/dev/null || return 0
  found=false
  for entry in "$legacy"/* "$legacy"/.[!.]* "$legacy"/..?*; do
    [[ -e "$entry" || -L "$entry" ]] || continue
    [[ "$entry" == "${legacy}/.multi-agent-run.lock" ]] || { found=true; break; }
  done
  if [[ "$found" != true || -e "${legacy}/.multi-agent-output-owner" || -L "${legacy}/.multi-agent-output-owner" ]] \
     || ! mv -- "$legacy" "$staging" 2>/dev/null; then
    rmdir -- "${legacy}/.multi-agent-run.lock" 2>/dev/null || true
    return 0
  fi
  printf '%s\n' "$staging"
}

# Undoes the set-aside when the new root could not be prepared, so the checkout
# is as it was (its ignore rule covers the original name, not the sibling).
ff_review_output_restore_legacy() { # <staging> <original>
  if [[ ! -e "$2" && ! -L "$2" ]] && mv -- "$1" "$2" 2>/dev/null; then
    rmdir -- "${2}/.multi-agent-run.lock" 2>/dev/null || true
    echo "       The previous results were put back unread at ${2}; nothing was run." >&2
    return 0
  fi
  echo "⚠️  output boundary: the previous results stay moved aside unread at ${1} (could not put them back at ${2}); they are not from this run. Move them by hand; nothing was run." >&2
}

# Puts the set-aside legacy root inside the new private root as .prev-<ts>-legacy/
# (the --fresh archive place, so the consumer's ignore rule for the root covers it).
ff_review_output_adopt_legacy() { # <staging> <prepared-output>
  local ts archive
  ts="${1##*.legacy-}"; ts="${ts%%-*}"
  archive="${2}/.prev-${ts}-legacy"
  [[ ! -e "$archive" && ! -L "$archive" ]] || archive="${archive}-$$"
  if [[ ! -e "$archive" && ! -L "$archive" ]] && mv -- "$1" "$archive" 2>/dev/null; then
    rmdir -- "${archive}/.multi-agent-run.lock" 2>/dev/null || true
    echo "🧹 output boundary: a previous version left ${2} without the owner-only marker; moved it unread to ${archive} and started a new private (mode 700) directory. Nothing in it is from this run." >&2
    return 0
  fi
  echo "⚠️  output boundary: previous results were moved aside unread to ${1} but could not be placed under ${2}; they are not from this run. Move or remove them by hand." >&2
}

prepare_output_namespace() {
  local legacy='' original="$OUTPUT_DIR"
  # Only the built-in default: no --output-dir and no output_dir from a config
  # other than the plugin's own default (a project value is implicit too).
  if [[ "$OUTPUT_DIR_EXPLICIT" != true && "${OUTPUT_DIR_SOURCE:-plugin default}" == "plugin default" \
        && "$OUTPUT_DIR" == "$(get_default_output_dir "$TASK_TYPE")" ]]; then
    legacy="$(ff_review_output_set_aside_legacy "$REPO_ROOT" "$OUTPUT_DIR")" || return 1
  fi
  OUTPUT_DIR="$(ff_review_output_prepare "$REPO_ROOT" "$OUTPUT_DIR" "$OUTPUT_DIR_EXPLICIT" "$TASK_TYPE")" || {
    [[ -z "$legacy" ]] || ff_review_output_restore_legacy "$legacy" "${legacy%.legacy-*}"
    OUTPUT_DIR="$original"
    return 1
  }
  [[ -z "$legacy" ]] || ff_review_output_adopt_legacy "$legacy" "$OUTPUT_DIR"
}

validate_output_dir_not_nested() {
  [[ -n "${OUTPUT_DIR:-}" && -n "${REPO_ROOT:-}" ]] || return 0
  local repo path
  repo="$(CDPATH='' cd -P -- "$REPO_ROOT" && pwd -P)" || return 1
  path="$(ff_review_output_resolve_path "$REPO_ROOT" "$OUTPUT_DIR")" || return $?
  ff_review_output_check_nested_default "$repo" "$path"
}

validate_output_artifact_paths() {
  local leaf
  for leaf in .fixed-diff .review-in-flight integrated-report.md; do
    ff_review_output_regular "${OUTPUT_DIR}/${leaf}" true || return 1
  done
}

output_artifact_parent() { # <relative-file-or-dir>
  local rel="$1" root="$OUTPUT_DIR" rest name current
  case "/${rel}/" in */../*) return 1 ;; esac
  [[ -n "$rel" && "$rel" != /* ]] || return 1
  ff_review_output_private "$root" true || return 1
  # prepare checked the immutable-to-other-UID ancestor chain before dispatch.
  # Only this UID can subsequently chmod/replace one of those safe components.
  current="$root"; rest="${rel%/*}"
  [[ "$rest" != "$rel" ]] || rest=''
  while [[ -n "$rest" ]]; do
    name="${rest%%/*}"; [[ "$rest" == */* ]] && rest="${rest#*/}" || rest=''
    [[ -n "$name" && "$name" != . ]] || return 1
    current="${current}/${name}"
    if [[ ! -e "$current" && ! -L "$current" ]]; then (umask 077; mkdir "$current") || return 1; fi
    ff_review_output_private "$current" || return 1
  done
  printf '%s\n' "$current"
}

output_artifact() { # <write|copy|capture|read|mkdir|validate> <relative-path> [source-relative|type|command argv...]
  local op="$1" rel="$2" parent target tmp source
  parent="$(output_artifact_parent "$rel")" || return 1
  target="${OUTPUT_DIR}/${rel}"
  case "$op" in
    mkdir)
      if [[ ! -e "$target" && ! -L "$target" ]]; then (umask 077; mkdir "$target") || return 1; fi
      ff_review_output_private "$target" ;;
    validate)
      if [[ "${3:-file}" == dir ]]; then ff_review_output_private "$target"; else ff_review_output_regular "$target"; fi ;;
    read) ff_review_output_regular "$target" && cat "$target" ;;
    write|copy|capture)
      ff_review_output_regular "$target" true || return 1
      if [[ "$op" == capture ]]; then [[ "$#" -ge 3 && -n "$3" ]] || return 1; fi
      if [[ "$op" == copy ]]; then
        source="${OUTPUT_DIR}/${3}"; output_artifact_parent "$3" >/dev/null || return 1
        ff_review_output_regular "$source" || return 1
      fi
      tmp="$(umask 077; mktemp "${parent}/.ff-output.XXXXXX")" || return 1
      ff_review_output_regular "$tmp" || return 1
      # A trusted producer runs as argv, with no eval. Its status is known
      # before publish, so partial bytes from a failed producer stay private.
      if { [[ "$op" == write ]] && cat > "$tmp"; } \
         || { [[ "$op" == copy ]] && cat "$source" > "$tmp"; } \
         || { [[ "$op" == capture ]] && "${@:3}" > "$tmp"; }; then
        if ff_review_output_regular "$target" true && mv -f "$tmp" "$target"; then return 0; fi
      fi
      rm -f "$tmp"; return 1 ;;
    *) return 1 ;;
  esac
}

_ma_part_loaded="multi-agent-boundary.sh"
