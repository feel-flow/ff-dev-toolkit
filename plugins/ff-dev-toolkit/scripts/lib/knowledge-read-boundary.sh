#!/usr/bin/env bash
# ADR-078: protected-parent, bounded snapshots; Bash 3.2, no Node/Python.
# Callers supply independent authority and a private job workspace. This library
# never treats a discovered path as a grant and never prints source bytes.
ff_knowledge_acl_resource="${BASH_SOURCE[0]%/*}/knowledge-read-acl.ps1"

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
  case "$(uname -s 2>/dev/null)" in
    MSYS*|MINGW*|CYGWIN*) directory="$(cygpath -u "$directory" 2>/dev/null)" || { ff_knowledge_refuse read-unverifiable; return 2; } ;;
  esac
  resolved="$(CDPATH= cd -P -- "$directory" 2>/dev/null && pwd -P && printf '.')" || { ff_knowledge_refuse unresolvable-input; return 2; }
  resolved="${resolved%.}"; resolved="${resolved%$'\n'}"
  ff_knowledge_clean_path "$resolved" || { ff_knowledge_refuse invalid-path; return 2; }
  printf '%s\n' "$resolved"
}

ff_knowledge_canonical_file() { # <literal file>
  local file="$1" parent leaf link count=0
  ff_knowledge_clean_path "$file" || { ff_knowledge_refuse invalid-path; return 2; }
  case "$(uname -s 2>/dev/null)" in
    MSYS*|MINGW*|CYGWIN*) file="$(cygpath -u "$file" 2>/dev/null)" || { ff_knowledge_refuse read-unverifiable; return 2; } ;;
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
  local value separators dev inode bytes modified changed mode owner links
  value="$(LC_ALL=C stat -c '%d:%i:%s:%Y:%Z:%a:%u:%h' -- "$1" 2>/dev/null)" \
    || value="$(LC_ALL=C stat -f '%d:%i:%z:%m:%c:%Lp:%u:%l' -- "$1" 2>/dev/null)" \
    || { ff_knowledge_refuse metadata-unavailable; return 2; }
  separators="${value//[0-9]/}"
  [[ "$separators" == ':::::::' ]] || { ff_knowledge_refuse metadata-unavailable; return 2; }
  IFS=: read -r dev inode bytes modified changed mode owner links <<< "$value"
  for separators in "$dev" "$inode" "$bytes" "$modified" "$changed" "$mode" "$owner" "$links"; do
    [[ -n "$separators" ]] || { ff_knowledge_refuse metadata-unavailable; return 2; }
  done
  case "$mode" in *[!0-7]*) ff_knowledge_refuse metadata-unavailable; return 2 ;; esac
  printf '%s\n' "$value"
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

ff_knowledge_windows_acl() { # <inspect|private-staging> <canonical paths...>
  local operation="$1" system program resource file converted input output index=0 line cr=$'\r'
  shift
  [[ $# -gt 0 ]] || { ff_knowledge_refuse read-unverifiable; return 2; }
  command -v cygpath >/dev/null 2>&1 && command -v timeout >/dev/null 2>&1 \
    || { ff_knowledge_refuse read-unverifiable; return 2; }
  [[ -n "${SystemRoot:-}" && -f "$ff_knowledge_acl_resource" && ! -L "$ff_knowledge_acl_resource" ]] \
    || { ff_knowledge_refuse read-unverifiable; return 2; }
  system="$(cygpath -u "$SystemRoot")" || { ff_knowledge_refuse read-unverifiable; return 2; }
  program="$system/System32/WindowsPowerShell/v1.0/powershell.exe"
  resource="$(cygpath -am "$ff_knowledge_acl_resource")" || { ff_knowledge_refuse read-unverifiable; return 2; }
  [[ -f "$program" ]] || { ff_knowledge_refuse read-unverifiable; return 2; }
  input="$operation"
  for file in "$@"; do
    converted="$(cygpath -am "$file")" || { ff_knowledge_refuse read-unverifiable; return 2; }
    ff_knowledge_clean_path "$converted" || { ff_knowledge_refuse invalid-path; return 2; }
    input="$input"$'\n'"$converted"
  done
  output="$(set -o pipefail; printf '%s\n' "$input" | MSYS2_ARG_CONV_EXCL='*' timeout --foreground 10 "$program" -NoProfile -NonInteractive -File "$resource" 2>/dev/null)" \
    || { ff_knowledge_refuse read-unverifiable; return 2; }
  output="${output//"$cr"/}"
  while IFS= read -r line; do
    [[ "$line" == "$index|1|0" ]] || { ff_knowledge_refuse read-unverifiable; return 2; }
    index=$((index + 1))
  done <<< "$output"
  [[ "$index" -eq $# ]] || { ff_knowledge_refuse read-unverifiable; return 2; }
}

ff_knowledge_storage() { # <canonical path> <file|dir>
  local cursor="$1" kind="$2" first=1 unsafe=0 meta dev inode bytes modified changed mode owner links bits allow parent platform
  local native_paths=()
  platform="$(uname -s 2>/dev/null)" || { ff_knowledge_refuse read-unverifiable; return 2; }
  case "$platform" in Darwin|Linux|MSYS*|MINGW*|CYGWIN*) ;; *) ff_knowledge_refuse read-unverifiable; return 2 ;; esac
  while :; do
    [[ ! -L "$cursor" ]] || { ff_knowledge_refuse nonregular-input; return 2; }
    if [[ "$first" -eq 1 && "$kind" == file ]]; then
      [[ -f "$cursor" ]] || { ff_knowledge_refuse nonregular-input; return 2; }
    else
      [[ -d "$cursor" ]] || { ff_knowledge_refuse nonregular-input; return 2; }
    fi
    meta="$(ff_knowledge_meta "$cursor")" || return 2
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
    [[ "$cursor" != / ]] || break
    parent="${cursor%/*}"; [[ -n "$parent" ]] || parent=/
    cursor="$parent"; first=0
  done
  if [[ ${#native_paths[@]} -gt 0 ]]; then ff_knowledge_windows_acl inspect "${native_paths[@]}" || return 2; fi
  [[ "$unsafe" -eq 0 ]] || { ff_knowledge_refuse replaceable-storage; return 2; }
}

ff_knowledge_private_fresh_directory() { # Only a newly created, empty owned job/staging directory.
  local directory="$1" parent platform meta dev inode bytes modified changed mode owner links
  [[ -d "$directory" && ! -L "$directory" && -O "$directory" ]] || { ff_knowledge_refuse foreign-workspace; return 2; }
  directory="$(ff_knowledge_canonical_dir "$directory")" || return 2
  parent="${directory%/*}"; [[ -n "$parent" ]] || parent=/
  ff_knowledge_storage "$parent" dir || return 2
  platform="$(uname -s)" || return 2
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
  case "$(uname -s 2>/dev/null)" in
    MSYS*|MINGW*|CYGWIN*) value="$(cygpath -u "$value" 2>/dev/null)" || return 2 ;;
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
