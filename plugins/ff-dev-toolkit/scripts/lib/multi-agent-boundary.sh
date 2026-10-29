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

ff_review_output_private() { # <dir> [root:true|false]
  local path="$1" mode bits mask=$((8#022))
  [[ -d "$path" && ! -L "$path" && -O "$path" ]] || {
    ff_review_output_error "directory is not an owned real directory: ${path}"; return 1
  }
  mode="$(ff_review_output_stat "$path" mode)" || return 1
  bits=$((8#$mode))
  [[ "${2:-false}" != true ]] || mask=$((8#077))
  [[ $((bits & mask)) -eq 0 ]] || {
    ff_review_output_error "directory must be private (owner only; mode 700): ${path}"; return 1
  }
}

# An outer owner-only ancestor shields its descendants from other UIDs. Still
# inspect above it: an unprotected writable parent can rename that anchor.
ff_review_output_ancestors() { # <canonical-path>
  local path="$1" parent mode bits uid unsafe=''
  local write_mask=$((8#022)) private_mask=$((8#077)) sticky_bit=$((8#1000))
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
    ff_review_output_error "ancestor is writable by another user: ${unsafe}"
    echo '       Next: choose an --output-dir whose every ancestor other users cannot write or rename, e.g. --output-dir "$(mktemp -d)/output" (a private dir under a sticky temp root).' >&2
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
  return 1
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

# Stable standalone hook interface. No orchestrator globals are required.
ff_review_output_prepare() { # <repo> <requested> <explicit:true|false> <task>
  local repo_arg="$1" requested="$2" explicit="$3" task="$4" repo path alias real suffix parent cur component rest
  local marker entry empty=true gitdir common rel tracked system_alias=''
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
  # Links within the output suffix are still rejected before any mkdir.
  for alias in "${PWD:-}" "$repo_arg" "${TMPDIR:-/tmp}" /tmp "$system_alias"; do
    [[ -n "$alias" && -d "$alias" ]] || continue
    case "$path" in "$alias"|"${alias%/}"/*)
      real="$(CDPATH='' cd -P -- "$alias" && pwd -P)" || return 1
      suffix="${path#"${alias%/}"}"; path="${real%/}${suffix}"; break ;;
    esac
  done
  path="$(ff_review_output_lexical_path "$path")" || return 1
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
  ff_review_output_ancestors "${parent%/}/placeholder" || return 1
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
    chmod 700 "$path" || return 1
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
  ff_review_output_ancestors "$path" || return 1
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
  ff_review_output_ancestors "$legacy" || return 1
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
