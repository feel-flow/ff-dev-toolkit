#!/usr/bin/env bash
# antigravity-cli-readonly-boundary.sh: Inspect effective Antigravity CLI permissions before launching a read-only run.
#
# In headless `-p "" --mode ""` mode, `agy` resets agentMode to default (`Ask`), EXCEPT:
#   1. `toolPermission` set to `"always-proceed"` or `"proceed-in-sandbox"` bypasses Ask.
#   2. `permissions.allow` rules permit specific tools unless overridden by `<action>(*)` in `deny` or `ask`.
#
# This preflight scans CLI Global, Shared, Workspace, and matching Project JSON configs and
# fails closed on symlinks, unreadable files, malformed JSON, duplicate keys, escape obfuscation,
# disallowed `toolPermission`, or non-read-only `permissions.allow` rules.

# Normalize Windows-style drive paths to slash form and strip trailing slashes (except root `/`).
_ff_agy_normalize_path() {
  local p="$1"
  if [[ "$p" =~ ^[A-Za-z]: ]]; then
    p="${p//\\//}"
  fi
  while [[ ${#p} -gt 1 && "${p%/}" != "$p" ]]; do
    p="${p%/}"
  done
  printf '%s\n' "$p"
}

# Resolve a home root safely without accepting symlinks or missing directories.
# Echoes the resolved physical directory path, or an error token and returns 1.
_ff_agy_resolve_home_dir() {
  local label="$1"
  local raw="$2"
  local norm phys

  if [[ -z "$raw" ]]; then
    echo "${label}_unset"
    return 1
  fi
  norm=$(_ff_agy_normalize_path "$raw")
  if [[ -L "$norm" ]]; then
    echo "${label}_symlink:${norm}"
    return 1
  fi
  if [[ ! -e "$norm" ]]; then
    echo "${label}_missing:${norm}"
    return 1
  fi
  if [[ ! -d "$norm" ]]; then
    echo "${label}_not_dir:${norm}"
    return 1
  fi
  phys=$(cd "$norm" 2>/dev/null && pwd -P) || {
    echo "${label}_unresolvable:${norm}"
    return 1
  }
  printf '%s\n' "$phys"
  return 0
}

# Check each subpath component beneath `$base_phys` for symlinks, permissions, and file type.
# Returns: 0 = present regular readable file, 2 = absent (safe), 1 = unsafe/error (reason echoed).
_ff_agy_check_rel_path() {
  local base_phys="$1"
  local rel_path="$2"
  local kind="$3" # "file" or "dir"
  local cur="$base_phys"
  local IFS='/'
  local parts=()
  read -r -a parts <<< "$rel_path"
  local total=${#parts[@]}
  local idx=0
  local part

  for part in "${parts[@]}"; do
    idx=$((idx + 1))
    [[ -z "$part" ]] && continue
    cur="${cur}/${part}"

    # Check symlink BEFORE existence so broken symlinks always fail closed.
    if [[ -L "$cur" ]]; then
      echo "symlink_path:${cur}"
      return 1
    fi
    if [[ ! -e "$cur" ]]; then
      return 2
    fi

    if [[ $idx -lt $total || "$kind" == "dir" ]]; then
      if [[ ! -d "$cur" ]]; then
        echo "not_dir:${cur}"
        return 1
      fi
      if [[ ! -r "$cur" || ! -x "$cur" ]]; then
        echo "unreadable_dir:${cur}"
        return 1
      fi
    else
      if [[ ! -f "$cur" ]]; then
        echo "non_regular_file:${cur}"
        return 1
      fi
      if [[ ! -r "$cur" ]]; then
        echo "unreadable_file:${cur}"
        return 1
      fi
    fi
  done
  return 0
}

# Inspect a single JSON settings file using strict RFC 8259 parsing in LC_ALL=C awk.
# Prints structured records (`TOOL_PERMISSION`, `ALLOW`, `ASK`, `DENY`, `FOLDER`, `HAS_PERM_OR_TP`,
# `FOLDERS_PRESENT`, `FOLDERS_INVALID`, or `ERR <reason>`).
_ff_agy_parse_json_file() {
  local file_path="$1"

  # Reject NUL bytes (awk stops strings at NUL).
  local raw_bytes stripped_bytes
  raw_bytes=$(wc -c < "$file_path" 2>/dev/null) || { echo "ERR unreadable_file:${file_path}"; return 1; }
  stripped_bytes=$(LC_ALL=C tr -d '\000' < "$file_path" 2>/dev/null | wc -c) || { echo "ERR unreadable_file:${file_path}"; return 1; }
  if [[ "$raw_bytes" -ne "$stripped_bytes" ]]; then
    echo "ERR nul_byte_in_json:${file_path}"
    return 1
  fi

  LC_ALL=C awk -v file_label="$file_path" '
    BEGIN {
      for (i = 1; i <= 255; i++) {
        ch = sprintf("%c", i)
        ord[ch] = i
      }
      hex_pat = "^[0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F]$"
      rule_pat = "^[a-z_]+\\(.+\\)$"
      buf = ""
      saw_line = 0
    }
    {
      buf = buf (saw_line ? "\n" : "") $0
      saw_line = 1
    }
    END {
      if (!saw_line) {
        print "ERR empty_file:" file_label
        exit 0
      }
      src = buf
      slen = length(src)
      pos = 1
      err = ""
      obj_seq = 0
      tp_seen = 0
      tp_val = ""
      perm_seen = 0
      folders_seen = 0
      folders_invalid = 0
      allow_n = 0
      ask_n = 0
      deny_n = 0
      folder_n = 0

      skip_ws()
      if (pos > slen || substr(src, pos, 1) != "{") {
        set_err("invalid_root_type")
      } else {
        parse_value("root")
        if (err == "") {
          skip_ws()
          if (pos <= slen) {
            set_err("trailing_garbage")
          }
        }
      }

      if (err != "") {
        print "ERR " err ":" file_label
        exit 0
      }

      if (tp_seen || perm_seen) print "HAS_PERM_OR_TP"
      if (tp_seen) print "TOOL_PERMISSION " tp_val
      if (folders_seen) print "FOLDERS_PRESENT"
      if (folders_invalid) print "FOLDERS_INVALID"
      for (i = 1; i <= allow_n; i++) print "ALLOW " allow_rules[i]
      for (i = 1; i <= ask_n; i++) print "ASK " ask_rules[i]
      for (i = 1; i <= deny_n; i++) print "DENY " deny_rules[i]
      for (i = 1; i <= folder_n; i++) print "FOLDER " folder_list[i]
      print "PARSED_OK"
    }

    function set_err(msg) {
      if (err == "") err = msg
    }

    function skip_ws(    c) {
      while (pos <= slen) {
        c = substr(src, pos, 1)
        if (c == " " || c == "\t" || c == "\n" || c == "\r") {
          pos++
        } else {
          break
        }
      }
    }

    function parse_string(    c, esc, hex, val, has_ctrl_or_u) {
      val = ""
      has_ctrl_or_u = 0
      if (pos > slen || substr(src, pos, 1) != "\"") {
        set_err("expected_string")
        return ""
      }
      pos++
      while (pos <= slen) {
        c = substr(src, pos, 1)
        if (c == "\"") {
          pos++
          str_val = val
          str_obscured = has_ctrl_or_u
          return "str"
        }
        if (c == "\\") {
          pos++
          if (pos > slen) {
            set_err("unterminated_escape")
            return ""
          }
          esc = substr(src, pos, 1)
          if (esc == "\"" || esc == "\\" || esc == "/") {
            val = val esc
            pos++
          } else if (esc == "b" || esc == "f" || esc == "n" || esc == "r" || esc == "t") {
            has_ctrl_or_u = 1
            val = val "\\" esc
            pos++
          } else if (esc == "u") {
            has_ctrl_or_u = 1
            if (pos + 4 > slen) {
              set_err("bad_unicode_escape")
              return ""
            }
            hex = substr(src, pos + 1, 4)
            if (hex !~ hex_pat) {
              set_err("bad_unicode_escape")
              return ""
            }
            val = val "\\u" hex
            pos += 5
          } else {
            set_err("bad_escape")
            return ""
          }
        } else {
          if (ord[c] < 32) {
            set_err("raw_control_char")
            return ""
          }
          val = val c
          pos++
        }
      }
      set_err("unterminated_string")
      return ""
    }

    function parse_number(    c, start) {
      start = pos
      if (substr(src, pos, 1) == "-") pos++
      if (pos > slen) { set_err("invalid_number"); return "" }
      c = substr(src, pos, 1)
      if (c == "0") {
        pos++
      } else if (c >= "1" && c <= "9") {
        pos++
        while (pos <= slen) {
          c = substr(src, pos, 1)
          if (c >= "0" && c <= "9") pos++
          else break
        }
      } else {
        set_err("invalid_number")
        return ""
      }
      if (pos <= slen && substr(src, pos, 1) == ".") {
        pos++
        if (pos > slen || substr(src, pos, 1) < "0" || substr(src, pos, 1) > "9") {
          set_err("invalid_number")
          return ""
        }
        while (pos <= slen) {
          c = substr(src, pos, 1)
          if (c >= "0" && c <= "9") pos++
          else break
        }
      }
      if (pos <= slen && (substr(src, pos, 1) == "e" || substr(src, pos, 1) == "E")) {
        pos++
        if (pos <= slen && (substr(src, pos, 1) == "+" || substr(src, pos, 1) == "-")) pos++
        if (pos > slen || substr(src, pos, 1) < "0" || substr(src, pos, 1) > "9") {
          set_err("invalid_number")
          return ""
        }
        while (pos <= slen) {
          c = substr(src, pos, 1)
          if (c >= "0" && c <= "9") pos++
          else break
        }
      }
      return "num"
    }

    function parse_value(ctx,    c, vtype) {
      if (err != "") return ""
      skip_ws()
      if (pos > slen) {
        set_err("unexpected_eof")
        return ""
      }
      c = substr(src, pos, 1)
      if (c == "{") return parse_object(ctx)
      if (c == "[") return parse_array(ctx)
      if (c == "\"") return parse_string()
      if (c == "-" || (c >= "0" && c <= "9")) return parse_number()
      if (substr(src, pos, 4) == "true") { pos += 4; return "bool" }
      if (substr(src, pos, 5) == "false") { pos += 5; return "bool" }
      if (substr(src, pos, 4) == "null") { pos += 4; return "null" }
      set_err("unexpected_token")
      return ""
    }

    function parse_array(ctx,    c, elem_type) {
      pos++ # skip "["
      skip_ws()
      if (pos <= slen && substr(src, pos, 1) == "]") {
        pos++
        return "arr"
      }
      while (err == "") {
        elem_type = parse_value(ctx == "folders" || substr(ctx, 1, 5) == "perm_" ? ctx "_elem" : "other")
        if (err != "") return ""
        if (ctx == "folders") {
          if (elem_type != "str" || str_obscured) {
            folders_invalid = 1
          } else {
            folder_n++
            folder_list[folder_n] = str_val
          }
        } else if (ctx == "perm_allow" || ctx == "perm_ask" || ctx == "perm_deny") {
          if (elem_type != "str") {
            set_err("non_string_permission_rule")
            return ""
          }
          if (str_obscured) {
            set_err("obscured_permission_rule")
            return ""
          }
          if (str_val !~ rule_pat) {
            set_err("malformed_permission_rule")
            return ""
          }
          if (ctx == "perm_allow") {
            allow_n++
            allow_rules[allow_n] = str_val
          } else if (ctx == "perm_ask") {
            ask_n++
            ask_rules[ask_n] = str_val
          } else {
            deny_n++
            deny_rules[deny_n] = str_val
          }
        }
        skip_ws()
        if (pos > slen) { set_err("unterminated_array"); return "" }
        c = substr(src, pos, 1)
        if (c == "]") {
          pos++
          return "arr"
        }
        if (c != ",") {
          set_err("expected_comma_or_rbracket")
          return ""
        }
        pos++
      }
      return ""
    }

    function parse_object(ctx,    id, key, key_obscured, child_ctx, vtype, c) {
      id = ++obj_seq
      pos++ # skip "{"
      skip_ws()
      if (pos <= slen && substr(src, pos, 1) == "}") {
        pos++
        return "obj"
      }
      while (err == "") {
        skip_ws()
        if (pos > slen || substr(src, pos, 1) != "\"") {
          set_err("expected_object_key")
          return ""
        }
        parse_string()
        if (err != "") return ""
        key = str_val
        key_obscured = str_obscured

        if ((id SUBSEP key) in seen_keys) {
          set_err("duplicate_key")
          return ""
        }
        seen_keys[id SUBSEP key] = 1

        # Reject escaped/control-character keys inside root or permissions scopes to prevent key smuggling.
        if ((ctx == "root" || ctx == "permissions") && key_obscured) {
          set_err("obscured_key")
          return ""
        }

        skip_ws()
        if (pos > slen || substr(src, pos, 1) != ":") {
          set_err("expected_colon")
          return ""
        }
        pos++

        child_ctx = "other"
        if (ctx == "root") {
          if (key == "toolPermission") child_ctx = "toolPermission"
          else if (key == "permissions") child_ctx = "permissions"
          else if (key == "folders") child_ctx = "folders"
        } else if (ctx == "permissions") {
          if (key == "allow") child_ctx = "perm_allow"
          else if (key == "ask") child_ctx = "perm_ask"
          else if (key == "deny") child_ctx = "perm_deny"
          else {
            set_err("unknown_permissions_key")
            return ""
          }
        }

        vtype = parse_value(child_ctx)
        if (err != "") return ""

        if (child_ctx == "toolPermission") {
          tp_seen = 1
          if (vtype != "str") {
            set_err("non_string_tool_permission")
            return ""
          }
          if (str_obscured) {
            set_err("obscured_tool_permission")
            return ""
          }
          tp_val = str_val
        } else if (child_ctx == "permissions") {
          perm_seen = 1
          if (vtype != "obj") {
            set_err("non_object_permissions")
            return ""
          }
        } else if (child_ctx == "folders") {
          folders_seen = 1
          if (vtype != "arr") {
            folders_invalid = 1
          }
        } else if (child_ctx == "perm_allow" || child_ctx == "perm_ask" || child_ctx == "perm_deny") {
          if (vtype != "arr") {
            set_err("non_array_permissions_list")
            return ""
          }
        }

        skip_ws()
        if (pos > slen) { set_err("unterminated_object"); return "" }
        c = substr(src, pos, 1)
        if (c == "}") {
          pos++
          return "obj"
        }
        if (c != ",") {
          set_err("expected_comma_or_rbrace")
          return ""
        }
        pos++
      }
      return ""
    }
  ' "$file_path"
}

# Canonicalize Windows drive-letter / MSYS / cygdrive paths (`C:\foo`, `/c/foo`, `/cygdrive/c/foo`)
# to lowercase `<drive>:/<rest>` so host-side path syntax differences still compare identically.
_ff_agy_win_drive_canon() {
  local p="$1"
  local drive="" rest=""

  if [[ "$p" =~ ^([A-Za-z]):(/.*)?$ ]]; then
    drive="${BASH_REMATCH[1]}"
    rest="${BASH_REMATCH[2]:-/}"
  elif [[ "$p" =~ ^/[Cc]ygdrive/([A-Za-z])(/.*)?$ ]]; then
    drive="${BASH_REMATCH[1]}"
    rest="${BASH_REMATCH[2]:-/}"
  elif [[ "$p" =~ ^/([A-Za-z])(/.*)?$ ]]; then
    drive="${BASH_REMATCH[1]}"
    rest="${BASH_REMATCH[2]:-/}"
  else
    return 1
  fi

  printf '%s:/%s\n' "$drive" "${rest#/}" | LC_ALL=C tr 'ABCDEFGHIJKLMNOPQRSTUVWXYZ' 'abcdefghijklmnopqrstuvwxyz'
}

# Check whether two canonicalized paths match or nest (handling `/` and `c:/` roots safely).
_ff_agy_paths_overlap_pair() {
  local p1="$1"
  local p2="$2"

  [[ -z "$p1" || -z "$p2" ]] && return 1
  if [[ "$p1" == "/" || "$p2" == "/" || "$p1" == "$p2" ]]; then
    return 0
  fi
  if [[ "$p1" =~ ^[a-z]:/$ && "$p2" == "${p1}"* ]]; then
    return 0
  fi
  if [[ "$p2" =~ ^[a-z]:/$ && "$p1" == "${p2}"* ]]; then
    return 0
  fi
  if [[ "$p2" == "${p1}/"* || "$p1" == "${p2}/"* ]]; then
    return 0
  fi
  return 1
}

# Check whether any path in workspace/git root matches or overlaps a project folder entry.
_ff_agy_folder_overlaps() {
  local folder_raw="$1"
  local ws_phys="$2"
  local ws_norm="$3"
  local git_root="$4"
  local f f_phys="" target cf ct

  f=$(_ff_agy_normalize_path "$folder_raw")
  # Reject relative folder patterns, tilde expansions, or empty strings conservatively as overlapping.
  if [[ -z "$f" ]]; then
    return 0
  fi
  if [[ "$f" != /* && ! "$f" =~ ^[A-Za-z]:(/|$) ]]; then
    return 0
  fi

  # Normalize bare drive root (`C:` -> `C:/`)
  if [[ "$f" =~ ^[A-Za-z]:$ ]]; then
    f="${f}/"
  fi

  # Resolve existing directories to physical path (handles symlinked dirs and `.`/`..` segments);
  # fail conservatively as overlapping if unresolvable `.` or `..` segments remain.
  if [[ -d "$f" ]]; then
    f_phys=$(cd "$f" 2>/dev/null && pwd -P) || return 0
  elif [[ "$f" == *"/./"* || "$f" == *"/../"* || "$f" == *"/." || "$f" == *"/.." || "$f" == "." || "$f" == ".." ]]; then
    return 0
  fi

  for target in "$ws_phys" "$ws_norm" "$git_root"; do
    [[ -z "$target" ]] && continue
    _ff_agy_paths_overlap_pair "$f" "$target" && return 0
    if [[ -n "$f_phys" ]]; then
      _ff_agy_paths_overlap_pair "$f_phys" "$target" && return 0
    fi
    if cf=$(_ff_agy_win_drive_canon "$f") && ct=$(_ff_agy_win_drive_canon "$target"); then
      _ff_agy_paths_overlap_pair "$cf" "$ct" && return 0
    fi
  done
  return 1
}

# Inspect all Antigravity CLI config scopes and confirm read-only safety.
# Usage: ff_antigravity_readonly_preflight [workspace_dir]
# Echoes `confirmed` (rc=0) if safe, or `<reason>` (rc=1) if unsafe/unverifiable.
ff_antigravity_readonly_preflight() {
  local ws_arg="${1:-$PWD}"
  local ws_norm ws_phys
  ws_norm=$(_ff_agy_normalize_path "$ws_arg")
  if [[ -L "$ws_norm" ]]; then
    echo "workspace_symlink:${ws_norm}"
    return 1
  fi
  if [[ ! -d "$ws_norm" ]]; then
    echo "workspace_not_dir:${ws_norm}"
    return 1
  fi
  ws_phys=$(cd "$ws_norm" 2>/dev/null && pwd -P) || {
    echo "workspace_unresolvable:${ws_norm}"
    return 1
  }

  # Resolve HOME (required) and USERPROFILE (optional, if distinct).
  local home_phys up_phys home_list=()
  local check_out
  check_out=$(_ff_agy_resolve_home_dir "home" "${HOME:-}") || {
    echo "$check_out"
    return 1
  }
  home_phys="$check_out"
  home_list+=("$home_phys")

  if [[ -n "${USERPROFILE:-}" ]]; then
    check_out=$(_ff_agy_resolve_home_dir "userprofile" "$USERPROFILE") || {
      echo "$check_out"
      return 1
    }
    up_phys="$check_out"
    if [[ "$up_phys" != "$home_phys" ]]; then
      home_list+=("$up_phys")
    fi
  fi

  # Collect workspace directory chain up to git root (or workspace dir alone if not inside a repo).
  local ws_chain=() ancestor="$ws_phys" git_root=""
  while true; do
    ws_chain+=("$ancestor")
    if [[ -e "${ancestor}/.git" || -L "${ancestor}/.git" ]]; then
      git_root="$ancestor"
      break
    fi
    if [[ "$ancestor" == "/" ]]; then
      ws_chain=("$ws_phys")
      break
    fi
    local parent
    parent="${ancestor%/*}"
    [[ -z "$parent" ]] && parent="/"
    ancestor="$parent"
  done

  # Collect candidate config files (`active` scope list).
  local candidate_files=()
  local h d rel rc

  for h in "${home_list[@]}"; do
    for rel in ".gemini/antigravity-cli/settings.json" ".gemini/config/config.json"; do
      check_out=$(_ff_agy_check_rel_path "$h" "$rel" "file")
      rc=$?
      if [[ $rc -eq 1 ]]; then
        echo "$check_out"
        return 1
      elif [[ $rc -eq 0 ]]; then
        candidate_files+=("${h}/${rel}")
      fi
    done

    # Check projects directory + `.json` files (max depth 2: *.json and */*.json).
    check_out=$(_ff_agy_check_rel_path "$h" ".gemini/config/projects" "dir")
    rc=$?
    if [[ $rc -eq 1 ]]; then
      echo "$check_out"
      return 1
    elif [[ $rc -eq 0 ]]; then
      local proj_dir="${h}/.gemini/config/projects"
      local entry subentry
      for entry in "${proj_dir}"/* "${proj_dir}"/.*; do
        local base="${entry##*/}"
        [[ "$base" == "." || "$base" == ".." || "$base" == "*" || "$base" == ".*" ]] && continue
        if [[ ! -e "$entry" && ! -L "$entry" ]]; then
          continue
        fi
        if [[ -L "$entry" ]]; then
          if [[ -d "$entry" || "$entry" == *.json ]]; then
            echo "symlink_path:${entry}"
            return 1
          fi
          continue
        fi
        if [[ -f "$entry" && "$entry" == *.json ]]; then
          if [[ ! -r "$entry" ]]; then
            echo "unreadable_file:${entry}"
            return 1
          fi
          candidate_files+=("PROJECT:${entry}")
        elif [[ -d "$entry" ]]; then
          if [[ ! -r "$entry" || ! -x "$entry" ]]; then
            echo "unreadable_dir:${entry}"
            return 1
          fi
          for subentry in "${entry}"/*.json "${entry}"/.*.json; do
            local subbase="${subentry##*/}"
            [[ "$subbase" == "*.json" || "$subbase" == ".*.json" ]] && continue
            if [[ ! -e "$subentry" && ! -L "$subentry" ]]; then
              continue
            fi
            if [[ -L "$subentry" ]]; then
              echo "symlink_path:${subentry}"
              return 1
            fi
            if [[ ! -f "$subentry" ]]; then
              echo "non_regular_file:${subentry}"
              return 1
            fi
            if [[ ! -r "$subentry" ]]; then
              echo "unreadable_file:${subentry}"
              return 1
            fi
            candidate_files+=("PROJECT:${subentry}")
          done
        elif [[ "$entry" == *.json ]]; then
          echo "non_regular_file:${entry}"
          return 1
        fi
      done
    fi
  done

  for d in "${ws_chain[@]}"; do
    for rel in \
      ".agents/settings.json" ".agents/permissions.json" \
      ".agent/settings.json" ".agent/permissions.json" \
      "_agents/settings.json" "_agents/permissions.json" \
      "_agent/settings.json" "_agent/permissions.json" \
      ".gemini/settings.json" ".gemini/antigravity-cli/settings.json"; do
      check_out=$(_ff_agy_check_rel_path "$d" "$rel" "file")
      rc=$?
      if [[ $rc -eq 1 ]]; then
        echo "$check_out"
        return 1
      elif [[ $rc -eq 0 ]]; then
        candidate_files+=("${d}/${rel}")
      fi
    done
  done

  # Parse candidate files and aggregate rules across all active scopes.
  local all_allow=()
  local all_shadow=()
  local item is_proj file_path parsed line parse_rc
  local has_perm_or_tp folders_present folders_invalid overlap saw_parsed_ok
  local tp_seen tp_val
  local file_allow=() file_shadow=() file_folders=()

  for item in "${candidate_files[@]+"${candidate_files[@]}"}"; do
    if [[ "$item" == PROJECT:* ]]; then
      is_proj=1
      file_path="${item#PROJECT:}"
    else
      is_proj=0
      file_path="$item"
    fi

    parse_rc=0
    parsed=$(_ff_agy_parse_json_file "$file_path") || parse_rc=$?
    has_perm_or_tp=0
    folders_present=0
    folders_invalid=0
    saw_parsed_ok=0
    tp_seen=0
    tp_val=""
    file_allow=()
    file_shadow=()
    file_folders=()

    while IFS= read -r line; do
      [[ -z "$line" ]] && continue
      case "$line" in
        ERR\ *)
          echo "${line#ERR }"
          return 1
          ;;
        HAS_PERM_OR_TP)
          has_perm_or_tp=1
          ;;
        TOOL_PERMISSION\ *)
          tp_seen=1
          tp_val="${line#TOOL_PERMISSION }"
          ;;
        FOLDERS_PRESENT)
          folders_present=1
          ;;
        FOLDERS_INVALID)
          folders_invalid=1
          ;;
        ALLOW\ *)
          file_allow+=("${line#ALLOW }")
          ;;
        ASK\ *)
          local ask_rule="${line#ASK }"
          if [[ "$ask_rule" == *"(*)" ]]; then
            file_shadow+=("${ask_rule%(*)}")
          fi
          ;;
        DENY\ *)
          local deny_rule="${line#DENY }"
          if [[ "$deny_rule" == *"(*)" ]]; then
            file_shadow+=("${deny_rule%(*)}")
          fi
          ;;
        FOLDER\ *)
          file_folders+=("${line#FOLDER }")
          ;;
        PARSED_OK)
          saw_parsed_ok=1
          ;;
      esac
    done <<< "$parsed"

    if [[ $parse_rc -ne 0 ]]; then
      echo "json_parse_failed:${file_path}"
      return 1
    fi
    if [[ $saw_parsed_ok -ne 1 ]]; then
      echo "json_parse_incomplete:${file_path}"
      return 1
    fi

    if [[ $is_proj -eq 1 ]]; then
      if [[ $folders_invalid -eq 1 && $has_perm_or_tp -eq 1 ]]; then
        echo "project_folders_invalid:${file_path}"
        return 1
      fi
      if [[ $folders_present -eq 1 ]]; then
        overlap=0
        local fld
        for fld in "${file_folders[@]+"${file_folders[@]}"}"; do
          if _ff_agy_folder_overlaps "$fld" "$ws_phys" "$ws_norm" "$git_root"; then
            overlap=1
            break
          fi
        done
        if [[ $overlap -eq 0 ]]; then
          continue
        fi
      else
        # Project file without folders cannot be proved non-matching; skip only if it defines no permission controls.
        if [[ $has_perm_or_tp -eq 0 ]]; then
          continue
        fi
      fi
    fi

    # Empty `""` matches `--mode ""` (resets toolPermission to default `Ask`); only explicit read-only modes pass.
    if [[ $tp_seen -eq 1 && -n "$tp_val" && "$tp_val" != "request-review" && "$tp_val" != "strict" ]]; then
      echo "disallowed_tool_permission:${tp_val}:${file_path}"
      return 1
    fi

    local r
    for r in "${file_allow[@]+"${file_allow[@]}"}"; do
      all_allow+=("$r")
    done
    for r in "${file_shadow[@]+"${file_shadow[@]}"}"; do
      all_shadow+=("$r")
    done
  done

  # Verify every effective permissions.allow rule is strictly read-only or shadowed by `<action>(*)` in deny/ask.
  local rule action shadowed s
  for rule in "${all_allow[@]+"${all_allow[@]}"}"; do
    action="${rule%%(*}"
    if [[ "$action" == "read_file" || "$action" == "read_url" ]]; then
      continue
    fi
    shadowed=0
    for s in "${all_shadow[@]+"${all_shadow[@]}"}"; do
      if [[ "$s" == "$action" ]]; then
        shadowed=1
        break
      fi
    done
    if [[ $shadowed -eq 0 ]]; then
      echo "disallowed_allow_rule:${rule}"
      return 1
    fi
  done

  echo "confirmed"
  return 0
}
