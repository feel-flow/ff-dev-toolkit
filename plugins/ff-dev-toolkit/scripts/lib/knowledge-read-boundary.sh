#!/usr/bin/env bash
# ADR-078: protected-parent, bounded snapshots; Bash 3.2, no Node/Python.
# Callers supply independent authority and a private job workspace. This library
# never treats a discovered path as a grant and never prints source bytes.
ff_knowledge_acl_resource="${BASH_SOURCE[0]%/*}/knowledge-read-acl.ps1"
case "$ff_knowledge_acl_resource" in /*) ;; *) ff_knowledge_acl_resource="$PWD/$ff_knowledge_acl_resource" ;; esac # a later cd keeps it
# Process starts cost about 0.1 s each on Git Bash, so the platform is read once
# and per-path tools run once per chain, not once per ancestor.
ff_knowledge_os="$(uname -s 2>/dev/null)" || ff_knowledge_os=""

ff_knowledge_refuse() { printf 'knowledge-read: %s\n' "$1" >&2; return 2; }

ff_knowledge_clean_path() {
  local LC_ALL=C
  [[ -n "$1" ]] || return 2
  # Reject framing/control bytes, including controls hidden in link targets.
  case "$1" in *[[:cntrl:]]*) return 2 ;; esac
}

ff_knowledge_canonical_dir() {
  local directory="$1" resolved
  ff_knowledge_clean_path "$directory" || { ff_knowledge_refuse invalid-path; return 2; }
  # Windows names cannot hold : or \, so only a native spelling needs cygpath.
  case "$ff_knowledge_os:$directory" in
    MSYS*:*[:\\]*|MINGW*:*[:\\]*|CYGWIN*:*[:\\]*) directory="$(cygpath -u "$directory" 2>/dev/null)" || { ff_knowledge_refuse read-unverifiable; return 2; } ;;
  esac
  resolved="$(CDPATH= cd -P -- "$directory" 2>/dev/null && pwd -P && printf '.')" || { ff_knowledge_refuse unresolvable-input; return 2; }
  resolved="${resolved%.}"; resolved="${resolved%$'\n'}"
  ff_knowledge_clean_path "$resolved" || { ff_knowledge_refuse invalid-path; return 2; }
  printf '%s\n' "$resolved"
}

ff_knowledge_canonical_file() { # <literal file>
  local file="$1" parent leaf link count=0
  ff_knowledge_clean_path "$file" || { ff_knowledge_refuse invalid-path; return 2; }
  case "$ff_knowledge_os:$file" in
    MSYS*:*[:\\]*|MINGW*:*[:\\]*|CYGWIN*:*[:\\]*) file="$(cygpath -u "$file" 2>/dev/null)" || { ff_knowledge_refuse read-unverifiable; return 2; } ;;
  esac
  case "$file" in /*) ;; *) file="$PWD/$file" ;; esac
  while :; do
    parent="${file%/*}"; [[ -n "$parent" ]] || parent=/
    leaf="${file##*/}"
    parent="$(ff_knowledge_canonical_dir "$parent")" || return 2
    file="${parent%/}/$leaf"
    ff_knowledge_clean_path "$file" || { ff_knowledge_refuse invalid-path; return 2; }
    [[ -L "$file" ]] || break
    count=$((count + 1)); [[ "$count" -le 64 ]] || { ff_knowledge_refuse unresolvable-input; return 2; }
    link="$(readlink "$file" 2>/dev/null && printf '.')" || { ff_knowledge_refuse read-unverifiable; return 2; }
    link="${link%.}"; link="${link%$'\n'}"
    ff_knowledge_clean_path "$link" || { ff_knowledge_refuse invalid-path; return 2; }
    case "$link" in /*) file="$link" ;; *) file="$parent/$link" ;; esac
  done
  printf '%s\n' "$file"
}

ff_knowledge_meta() { # dev:ino:bytes:mtime:ctime:mode:uid:nlink (all numeric)
  local value
  value="$(LC_ALL=C stat -c '%d:%i:%s:%Y:%Z:%a:%u:%h' -- "$1" 2>/dev/null)" \
    || value="$(LC_ALL=C stat -f '%d:%i:%z:%m:%c:%Lp:%u:%l' -- "$1" 2>/dev/null)" \
    || { ff_knowledge_refuse metadata-unavailable; return 2; }
  ff_knowledge_meta_valid "$value" || return 2
  printf '%s\n' "$value"
}

ff_knowledge_meta_chain() { # <paths...>; one stat per chain, else ff_knowledge_meta_count=0
  local output line count=0
  ff_knowledge_meta_count=0; ff_knowledge_metas=()
  # GNU stat -f reads the file system, not the file, so each dialect keeps its own flag.
  if [[ "$ff_knowledge_os" == Darwin ]]; then
    output="$(LC_ALL=C stat -f '%d:%i:%z:%m:%c:%Lp:%u:%l' -- "$@" 2>/dev/null)" || return 0
  else
    output="$(LC_ALL=C stat -c '%d:%i:%s:%Y:%Z:%a:%u:%h' -- "$@" 2>/dev/null)" || return 0
  fi
  while IFS= read -r line; do ff_knowledge_metas[count]="$line"; count=$((count + 1)); done <<< "$output"
  [[ "$count" -ne $# ]] || ff_knowledge_meta_count="$count"
}

ff_knowledge_meta_valid() { # <dev:ino:bytes:mtime:ctime:mode:uid:nlink>
  local value="$1" separators dev inode bytes modified changed mode owner links
  separators="${value//[0-9]/}"
  [[ "$separators" == ':::::::' ]] || { ff_knowledge_refuse metadata-unavailable; return 2; }
  IFS=: read -r dev inode bytes modified changed mode owner links <<< "$value"
  for separators in "$dev" "$inode" "$bytes" "$modified" "$changed" "$mode" "$owner" "$links"; do
    [[ -n "$separators" ]] || { ff_knowledge_refuse metadata-unavailable; return 2; }
  done
  case "$mode" in *[!0-7]*) ff_knowledge_refuse metadata-unavailable; return 2 ;; esac
}

ff_knowledge_darwin_acl() { # <canonical path> -> 0/1 (additional allow)
  local output result rc=0
  output="$(LC_ALL=C LANG=C /bin/ls -ldeb -- "$1" 2>/dev/null)" || { ff_knowledge_refuse read-unverifiable; return 2; }
  result="$(printf '%s\n' "$output" | LC_ALL=C awk '
    NR==1 {
      if ($0 !~ /^[-d][-rwxstST]{9}[+@ ]/) { bad=1; next }
      header=1; plus=(substr($0,11,1)=="+"); next
    }
    {
      if ($0 !~ /^[ ]+[0-9]+: .+ (allow|deny) [a-z_,]+$/) { bad=1; next }
      entries++
      if ($(NF-1)=="allow") {
        allowed=1; n=split($NF,rights,",")
        for(i=1;i<=n;i++) if (rights[i] !~ /^(list|search|read|readattr|readextattr|readsecurity|synchronize|file_inherit|directory_inherit|limit_inherit|only_inherit)$/) bad=1
      }
    }
    END { if (!header || bad || (plus && !entries)) exit 2; print allowed+0 }
  ')" || rc=$?
  [[ "$rc" -eq 0 && ( "$result" == 0 || "$result" == 1 ) ]] || { ff_knowledge_refuse read-unverifiable; return 2; }
  printf '%s\n' "$result"
}

# Locate the helper from the Windows directory itself: Git Bash may pass the
# variable only as SYSTEMROOT, and Bash names are case-sensitive.
ff_knowledge_acl_command() { # sets ff_knowledge_acl_program / ff_knowledge_acl_native
  local system
  [[ -f "$ff_knowledge_acl_resource" && ! -L "$ff_knowledge_acl_resource" ]] || return 2
  [[ "${ff_knowledge_acl_for:-}" != "$ff_knowledge_acl_resource" ]] || return 0
  command -v cygpath >/dev/null 2>&1 || return 2
  system="$(cygpath -W 2>/dev/null)" && [[ "$system" == /* ]] || return 2
  ff_knowledge_acl_program="$system/System32/WindowsPowerShell/v1.0/powershell.exe"
  [[ -f "$ff_knowledge_acl_program" ]] || return 2
  ff_knowledge_acl_native="$(cygpath -am "$ff_knowledge_acl_resource")" || return 2
  ff_knowledge_acl_for="$ff_knowledge_acl_resource"
}

# Starting powershell.exe takes seconds, so one helper per shell answers every
# request; each request still inspects its whole chain afresh. eval keeps coproc
# and {fd} redirections away from the Bash 3.2 parser; the duplicated
# descriptors stay open in subshells, unlike the coproc's own, which are closed.
# disown keeps a caller's bare wait from waiting on the helper.
ff_knowledge_acl_service_start() {
  [[ -z "${ff_knowledge_acl_state:-}" ]] || return 0
  ff_knowledge_acl_state=off
  ff_knowledge_acl_command || return 0
  eval 'coproc ff_knowledge_acl_service { MSYS2_ARG_CONV_EXCL="*" exec "$ff_knowledge_acl_program" -NoProfile -NonInteractive -File "$ff_knowledge_acl_native" 2>/dev/null; }' 2>/dev/null || return 0
  eval 'exec {ff_knowledge_acl_in}<&"${ff_knowledge_acl_service[0]}" {ff_knowledge_acl_out}>&"${ff_knowledge_acl_service[1]}"' 2>/dev/null || return 0
  eval 'ff_knowledge_acl_pid="$ff_knowledge_acl_service_PID"'
  case "${ff_knowledge_acl_service[0]:-}:${ff_knowledge_acl_service[1]:-}" in
    *[!0-9:]*|:*|*:) ;; # never let an empty number close the shell's own stdin / stdout
    *) eval "exec ${ff_knowledge_acl_service[0]}<&- ${ff_knowledge_acl_service[1]}>&-" 2>/dev/null ;;
  esac
  disown "$ff_knowledge_acl_pid" 2>/dev/null
  ff_knowledge_acl_state=on
}

# Killing the helper also tells the parent shell, which checks it before writing,
# that a reply abandoned in a subshell will not answer its next request.
ff_knowledge_acl_service_stop() {
  [[ "${ff_knowledge_acl_state:-}" == on ]] || return 0
  kill "${ff_knowledge_acl_pid:-}" 2>/dev/null
  eval 'exec {ff_knowledge_acl_in}<&- {ff_knowledge_acl_out}>&-' 2>/dev/null
  ff_knowledge_acl_state=off
}

ff_knowledge_acl_explain() { # <refused verdict> <native paths...>; names the place, never file bytes
  local position owned danger owner writer path temporary reason=""
  case "$1" in E\|*) printf 'knowledge-read: 判定できない: %s\n' "${1#E|}" >&2; return 0 ;; esac
  IFS='|' read -r position owned danger owner writer <<< "$1"
  shift
  case "$position" in ''|*[!0-9]*) return 0 ;; esac
  [[ "$position" -lt $# ]] || return 0
  path="${@:$((position + 1)):1}"
  [[ "$owned" != 0 ]] || reason="所有者が本人・管理者・SYSTEM のどれでもない（${owner:-SID 不明}）"
  [[ "$danger" != 1 ]] || reason="${reason:+${reason}、}本人・管理者・SYSTEM 以外が書き込める（${writer:-SID 不明}）"
  printf 'knowledge-read: 止めた場所: %s — %s\n' "$path" "${reason:-ACL を照合できない}" >&2
  temporary="$(cygpath -am "${TMPDIR:-/tmp}" 2>/dev/null)" || temporary=""
  case "$temporary/" in
    "${path%/}/"*) printf 'knowledge-read: 作業用の一時フォルダー（TMPDIR）の祖先です。TMPDIR を、祖先の ACL がこの検査を通るフォルダーへ向けると置き場を変えられます（境界は自動では緩めません）\n' >&2 ;;
  esac
}

ff_knowledge_windows_acl() { # <inspect|private-staging> <canonical paths...>
  local operation="$1" file converted request="" tag output="" line index=0 count=0 cr=$'\r' answered=0 deadline left
  local native=()
  shift
  [[ $# -gt 0 ]] || { ff_knowledge_refuse read-unverifiable; return 2; }
  ff_knowledge_acl_command || { ff_knowledge_refuse read-unverifiable; return 2; }
  converted="$(cygpath -am "$@")" || { ff_knowledge_refuse read-unverifiable; return 2; }
  while IFS= read -r file; do
    ff_knowledge_clean_path "$file" || { ff_knowledge_refuse invalid-path; return 2; }
    native[count]="$file"; count=$((count + 1)); request="$request$file"$'\n'
  done <<< "$converted"
  [[ "$count" -eq $# ]] || { ff_knowledge_refuse read-unverifiable; return 2; }
  ff_knowledge_acl_serial=$((${ff_knowledge_acl_serial:-0} + 1))
  tag="${BASHPID:-$$}-$ff_knowledge_acl_serial-$RANDOM$RANDOM"
  request="$operation $tag"$'\n'"$request."$'\n'
  # A dead helper sends this call to its own process; the subshell takes the
  # SIGPIPE of one that dies between the check and the write. One deadline
  # bounds the whole reply, as timeout(1) bounds the one-shot process.
  if [[ "${ff_knowledge_acl_state:-}" == on ]] && kill -0 "${ff_knowledge_acl_pid:-}" 2>/dev/null \
    && ( printf '%s' "$request" >&"$ff_knowledge_acl_out" ) 2>/dev/null; then
    # Every reply line carries its request's tag, so lines of an abandoned or a
    # concurrent request are never read as this request's verdicts.
    deadline=$((SECONDS + 10))
    while left=$((deadline - SECONDS)); [[ "$left" -gt 0 ]] && IFS= read -r -t "$left" -u "$ff_knowledge_acl_in" line; do
      line="${line%"$cr"}"
      case "$line" in
        ".$tag") answered=1; break ;;
        "$tag|"*) output="$output${line#"$tag|"}"$'\n' ;;
      esac
    done
    [[ "$answered" -eq 1 ]] || { ff_knowledge_acl_service_stop; ff_knowledge_refuse read-unverifiable; return 2; }
  else
    command -v timeout >/dev/null 2>&1 || { ff_knowledge_refuse read-unverifiable; return 2; }
    converted="$(set -o pipefail; printf '%s' "$request" | MSYS2_ARG_CONV_EXCL='*' timeout --foreground 10 "$ff_knowledge_acl_program" -NoProfile -NonInteractive -File "$ff_knowledge_acl_native" 2>/dev/null)" \
      || { ff_knowledge_refuse read-unverifiable; return 2; }
    while IFS= read -r line; do
      line="${line%"$cr"}"
      case "$answered:$line" in
        "0:.$tag") answered=1 ;;
        "0:$tag|"*) output="$output${line#"$tag|"}"$'\n' ;;
        *) ff_knowledge_refuse read-unverifiable; return 2 ;;
      esac
    done <<< "$converted"
    [[ "$answered" -eq 1 ]] || { ff_knowledge_refuse read-unverifiable; return 2; }
  fi
  output="${output%$'\n'}"
  while IFS= read -r line; do
    if [[ "$line" != "$index|1|0" ]]; then
      printf 'knowledge-read: %s\n' read-unverifiable >&2 # the code line stays first for callers
      ff_knowledge_acl_explain "$line" "${native[@]}"
      return 2
    fi
    index=$((index + 1))
  done <<< "$output"
  [[ "$index" -eq $# ]] || { ff_knowledge_refuse read-unverifiable; return 2; }
}

ff_knowledge_storage() { # <canonical path> <file|dir>
  local cursor="$1" kind="$2" first=1 unsafe=0 meta dev inode bytes modified changed mode owner links bits allow parent platform position=0
  local native_paths=() chain=()
  platform="$ff_knowledge_os"
  case "$platform" in Darwin|Linux|MSYS*|MINGW*|CYGWIN*) ;; *) ff_knowledge_refuse read-unverifiable; return 2 ;; esac
  while :; do
    chain+=("$cursor")
    [[ "$cursor" != / ]] || break
    parent="${cursor%/*}"; [[ -n "$parent" ]] || parent=/
    [[ "$parent" != "$cursor" ]] || break # a relative spelling never reaches /; refused below
    cursor="$parent"
  done
  ff_knowledge_meta_chain "${chain[@]}"
  for cursor in "${chain[@]}"; do
    [[ ! -L "$cursor" ]] || { ff_knowledge_refuse nonregular-input; return 2; }
    if [[ "$first" -eq 1 && "$kind" == file ]]; then
      [[ -f "$cursor" ]] || { ff_knowledge_refuse nonregular-input; return 2; }
    else
      [[ -d "$cursor" ]] || { ff_knowledge_refuse nonregular-input; return 2; }
    fi
    if [[ "$ff_knowledge_meta_count" -gt 0 ]]; then
      meta="${ff_knowledge_metas[position]}"; ff_knowledge_meta_valid "$meta" || return 2
    else
      meta="$(ff_knowledge_meta "$cursor")" || return 2
    fi
    IFS=: read -r dev inode bytes modified changed mode owner links <<< "$meta"
    if [[ "$first" -eq 1 && "$kind" == file && "$links" != 1 ]]; then ff_knowledge_refuse hardlinked-input; return 2; fi
    case "$platform" in Darwin|Linux)
      if [[ "$first" -eq 1 && "$kind" == file && $((8#$mode & 8#444)) -eq 0 ]]; then ff_knowledge_refuse unreadable-input; return 2; fi ;;
    esac
    case "$platform" in
      MSYS*|MINGW*|CYGWIN*) native_paths+=("$cursor") ;;
      *)
        [[ "$owner" == 0 || "$owner" == "$EUID" ]] || { ff_knowledge_refuse foreign-owner; return 2; }
        bits=$((8#$mode)); allow=0
        if [[ "$platform" == Darwin ]]; then allow="$(ff_knowledge_darwin_acl "$cursor")" || return 2; fi
        if [[ $((bits & 8#022)) -ne 0 ]]; then
          [[ -d "$cursor" && $((bits & 8#1000)) -ne 0 ]] || unsafe=1
        fi
        if [[ -d "$cursor" && "$owner" == "$EUID" && $((bits & 8#077)) -eq 0 && "$allow" == 0 ]]; then unsafe=0; fi
        ;;
    esac
    first=0; position=$((position + 1))
  done
  [[ "$cursor" == / ]] || { ff_knowledge_refuse invalid-path; return 2; }
  if [[ ${#native_paths[@]} -gt 0 ]]; then ff_knowledge_windows_acl inspect "${native_paths[@]}" || return 2; fi
  [[ "$unsafe" -eq 0 ]] || { ff_knowledge_refuse replaceable-storage; return 2; }
}

ff_knowledge_private_fresh_directory() { # Only a newly created, empty owned job/staging directory.
  local directory="$1" parent platform meta dev inode bytes modified changed mode owner links
  [[ -d "$directory" && ! -L "$directory" && -O "$directory" ]] || { ff_knowledge_refuse foreign-workspace; return 2; }
  directory="$(ff_knowledge_canonical_dir "$directory")" || return 2
  parent="${directory%/*}"; [[ -n "$parent" ]] || parent=/
  ff_knowledge_storage "$parent" dir || return 2
  platform="$ff_knowledge_os"
  case "$platform" in
    Darwin) /bin/chmod 700 "$directory" && /bin/chmod -N "$directory" || { ff_knowledge_refuse read-unverifiable; return 2; } ;;
    MSYS*|MINGW*|CYGWIN*) ff_knowledge_windows_acl private-staging "$directory" || return 2 ;;
    Linux) chmod 700 "$directory" || { ff_knowledge_refuse read-unverifiable; return 2; } ;;
    *) ff_knowledge_refuse read-unverifiable; return 2 ;;
  esac
  ff_knowledge_storage "$directory" dir || return 2
  case "$platform" in
    Darwin|Linux)
      meta="$(ff_knowledge_meta "$directory")" || return 2
      IFS=: read -r dev inode bytes modified changed mode owner links <<< "$meta"
      [[ "$owner" == "$EUID" && $((8#$mode & 8#077)) -eq 0 ]] || { ff_knowledge_refuse foreign-workspace; return 2; }
      ;;
  esac
}

# A caller's job directory, returned in its canonical spelling. On Windows an app
# or sandbox account may hold write access to the ancestors of TMPDIR; only for
# that ACL verdict is the toolkit state directory tried instead, under the same
# checks. The move is announced, and a refusal there names both places.
ff_knowledge_job_directory() { # <label> -> a new private directory
  local base="${TMPDIR:-/tmp}" refusal="" fallback job canonical line
  case "$ff_knowledge_os" in
    MSYS*|MINGW*|CYGWIN*)
      if ! refusal="$( { job="$(ff_knowledge_canonical_dir "$base")" && ff_knowledge_storage "$job" dir; } 2>&1 )"; then
        fallback="${FF_DEV_TOOLKIT_STATE_DIR:-${HOME:-}/.config/ff-dev-toolkit}/tmp"
        case "$refusal" in *'knowledge-read: 止めた場所: '*) ;; *) printf '%s\n' "$refusal" >&2; return 2 ;; esac
        if [[ -n "${HOME:-}${FF_DEV_TOOLKIT_STATE_DIR:-}" && "$fallback" == /* ]] && ( umask 077 && mkdir -p -- "$fallback" ) 2>/dev/null; then
          base="$fallback"
        else printf '%s\n' "$refusal" >&2; return 2
        fi
      else refusal=""
      fi ;;
  esac
  job="$(mktemp -d "$base/$1.XXXXXX")" || { # mktemp names its own cause (full disk, unwritable base)
    [[ -z "$refusal" ]] || printf '%s\n' "$refusal" >&2
    ff_knowledge_refuse workspace-unavailable; return 2
  }
  if ! ff_knowledge_private_fresh_directory "$job"; then
    rm -rf -- "$job"
    [[ -z "$refusal" ]] || printf '%s\n' "$refusal" >&2
    return 2
  fi
  canonical="$(ff_knowledge_canonical_dir "$job")" || { rm -rf -- "$job"; return 2; }
  if [[ -n "$refusal" ]]; then
    printf 'knowledge-read: 作業場所を %s の下へ移しました（TMPDIR の祖先が検査を通らないため）\n' "$base" >&2
    while IFS= read -r line; do
      case "$line" in 'knowledge-read: 止めた場所: '*) printf '%s\n' "$line" >&2 ;; esac
    done <<< "$refusal"
  fi
  printf '%s\n' "$canonical"
}

ff_knowledge_project_context() { # Independent cwd/Git context; preserve controls until rejection.
  local current project
  current="$(ff_knowledge_canonical_dir .)" || return 2
  if project="$(git rev-parse --show-toplevel 2>/dev/null && printf '.')"; then
    project="${project%.}"; project="${project%$'\n'}"
    project="$(ff_knowledge_canonical_dir "$project")" || return 2
    case "$current" in "$project"|"${project%/}"/*) ;; *) project="$current" ;; esac
  else project="$current"
  fi
  ff_knowledge_storage "$project" dir || return 2
  printf '%s\n' "$project"
}

ff_knowledge_lexical_path() { # Normalize operator spelling without following repository links.
  local value="$1" part joined=""; local parts=() components=()
  ff_knowledge_clean_path "$value" || return 2
  case "$ff_knowledge_os:$value" in
    MSYS*:*[:\\]*|MINGW*:*[:\\]*|CYGWIN*:*[:\\]*) value="$(cygpath -u "$value" 2>/dev/null)" || return 2 ;;
  esac
  case "$value" in /*) ;; *) joined="$(ff_knowledge_canonical_dir .)" || return 2; value="$joined/$value"; joined="" ;; esac
  IFS=/ read -r -a parts <<< "$value"
  for part in ${parts[@]+"${parts[@]}"}; do
    case "$part" in
      ''|.) ;;
      ..) if [[ ${#components[@]} -gt 0 ]]; then unset "components[$((${#components[@]} - 1))]"; fi ;;
      *) components+=("$part") ;;
    esac
  done
  for part in ${components[@]+"${components[@]}"}; do joined="$joined/$part"; done
  printf '%s\n' "${joined:-/}"
}

ff_knowledge_project_operand() { # 0 means an operand in the independently selected project.
  local cursor resolved
  cursor="$(ff_knowledge_lexical_path "$1")" || return 2
  while :; do
    [[ "$cursor" != "$2" ]] || return 0
    if resolved="$(ff_knowledge_canonical_dir "$cursor" 2>/dev/null)" && [[ "$resolved" == "$2" ]]; then return 0; fi
    [[ "$cursor" != / ]] || return 1
    cursor="${cursor%/*}"; [[ -n "$cursor" ]] || cursor=/
  done
}

ff_knowledge_authorize() { # <literal file> <operator-selected root/file> [root|file]
  local real authority
  real="$(ff_knowledge_canonical_file "$1")" || return 2
  if [[ "${3:-root}" == file ]]; then
    authority="$(ff_knowledge_canonical_file "$2")" || return 2
    [[ "$real" == "$authority" ]] || { ff_knowledge_refuse outside-authority; return 2; }
  else
    ff_knowledge_clean_path "$2" || { ff_knowledge_refuse invalid-path; return 2; }
    authority="$(ff_knowledge_canonical_dir "$2")" || return 2
    case "$real" in "${authority%/}"/*) ;; *) ff_knowledge_refuse outside-authority; return 2 ;; esac
  fi
  ff_knowledge_storage "$real" file || return 2
  printf '%s\n' "$real"
}

ff_knowledge_valid_utf8() { # stdin is already bounded accepted bytes; never print them.
  LC_ALL=C awk '
    !/^([\001-\177]|[\302-\337][\200-\277]|\340[\240-\277][\200-\277]|[\341-\354\356-\357][\200-\277][\200-\277]|\355[\200-\237][\200-\277]|\360[\220-\277][\200-\277][\200-\277]|[\361-\363][\200-\277][\200-\277][\200-\277]|\364[\200-\217][\200-\277][\200-\277])*$/ { exit 2 }
  '
}

ff_knowledge_snapshot() ( # <literal file> <independent authority> <private workspace> [root|file]
  set -uo pipefail
  export LC_ALL=C
  local source="$1" authority="$2" workspace="$3" kind="${4:-root}" real before after current stage="" accepted=0
  local dev inode bytes modified changed mode owner links data="" rc=0 limit=4194304
  trap 'if [[ "$accepted" -eq 0 && -n "$stage" && -d "$stage" && ! -L "$stage" && -O "$stage" ]]; then rm -rf -- "$stage"; fi' EXIT
  real="$(ff_knowledge_authorize "$source" "$authority" "$kind")" || return 2
  ff_knowledge_clean_path "$workspace" || { ff_knowledge_refuse invalid-path; return 2; }
  workspace="$(ff_knowledge_canonical_dir "$workspace")" || return 2
  ff_knowledge_storage "$workspace" dir || return 2
  [[ -O "$workspace" ]] || { ff_knowledge_refuse foreign-workspace; return 2; }
  stage="$(mktemp -d "$workspace/.ff-knowledge-read.XXXXXX")" || { ff_knowledge_refuse read-unverifiable; return 2; }
  ff_knowledge_private_fresh_directory "$stage" || return 2
  before="$(ff_knowledge_meta "$real")" || return 2
  IFS=: read -r dev inode bytes modified changed mode owner links <<< "$before"
  [[ $((10#$bytes)) -le "$limit" ]] || { ff_knowledge_refuse input-too-large; return 2; }
  exec 3< "$real" || { ff_knowledge_refuse read-unverifiable; return 2; }
  [[ -f /dev/fd/3 ]] || { ff_knowledge_refuse read-unverifiable; return 2; }
  IFS= read -r -d '' -n "$((limit + 1))" -u 3 data 2> "$stage/read-error" || rc=$?
  exec 3<&-
  [[ "$rc" -eq 1 && ! -s "$stage/read-error" && "${#data}" -eq $((10#$bytes)) && "${#data}" -le "$limit" ]] \
    || { ff_knowledge_refuse incomplete-input; return 2; }
  after="$(ff_knowledge_meta "$real")" || return 2
  current="$(ff_knowledge_authorize "$source" "$authority" "$kind")" || return 2
  [[ "$before" == "$after" && "$current" == "$real" ]] || { ff_knowledge_refuse input-changed; return 2; }
  printf '%s' "$data" | ff_knowledge_valid_utf8 || { ff_knowledge_refuse invalid-text; return 2; }
  ( set -C; printf '%s' "$data" > "$stage/input" ) || { ff_knowledge_refuse read-unverifiable; return 2; }
  accepted=1
  printf '%s\n' "$stage/input"
)

# Start the Windows helper in the sourcing shell, so command substitutions share it.
case "$ff_knowledge_os" in MSYS*|MINGW*|CYGWIN*) ff_knowledge_acl_service_start ;; esac
