#!/usr/bin/env bash
# Issue #1011: root-qualified command より前に、別文書からのクリック可能なMarkdown
# link、または正本文書自身の可視anchorで prerequisite が見えていることを検証する。

visible_root_prerequisite_anchor() {
  local target="$1"
  awk -v tag="$ROOT_PREREQUISITE_TAG" '
    /^[[:space:]]*(```|~~~)/ { in_fence = !in_fence; next }
    !in_fence && index($0, "<!--") { in_comment = 1 }
    !in_fence && !in_comment && $0 == tag { found = 1 }
    in_comment && index($0, "-->") { in_comment = 0 }
    END { exit(found ? 0 : 1) }
  ' "$target"
}

root_prerequisite_reachable_before_command() {
  local doc="$1" first_root_reference_line prerequisite_record prerequisite_line
  local prerequisite_link prerequisite_path prerequisite_dir prerequisite_target canonical_target

  # 実行例より前に現れる散文・表中のroot参照も含め、最初のroot参照より前に
  # prerequisiteへ到達できることを要求する。
  first_root_reference_line="$(awk -v needle='${FF_DEV_TOOLKIT_ROOT}/scripts/' \
    'index($0, needle) { print NR; exit }' "$doc")"
  [ -n "$first_root_reference_line" ] || return 1

  prerequisite_record="$(awk -v tag="$ROOT_PREREQUISITE_TAG" '
    /^[[:space:]]*(```|~~~)/ { in_fence = !in_fence; next }
    !in_fence && index($0, "<!--") { in_comment = 1 }
    !in_fence && !in_comment && $0 == tag { print NR "|" tag; exit }
    in_comment && index($0, "-->") { in_comment = 0 }
  ' "$doc")"
  if [ -n "$prerequisite_record" ]; then
    prerequisite_line="${prerequisite_record%%|*}"
    prerequisite_target="$doc"
  else
    prerequisite_record="$(awk -v anchor="$ROOT_PREREQUISITE_ANCHOR" '
      /^[[:space:]]*(```|~~~)/ { in_fence = !in_fence; next }
      !in_fence && index($0, "<!--") { in_comment = 1 }
      !in_fence && !in_comment {
        visible = $0
        gsub(/`[^`]*`/, "", visible)
        if (match(visible, "\\[[^]]+\\]\\([^()[:space:]]*#" anchor "\\)")) {
          print NR "|" substr(visible, RSTART, RLENGTH)
          exit
        }
      }
      in_comment && index($0, "-->") { in_comment = 0 }
    ' "$doc")"
    [ -n "$prerequisite_record" ] || return 1
    prerequisite_line="${prerequisite_record%%|*}"
    prerequisite_link="$(printf '%s\n' "${prerequisite_record#*|}" \
      | sed -E 's/^.*\(([^()]*)\)$/\1/')"
    prerequisite_path="${prerequisite_link%#${ROOT_PREREQUISITE_ANCHOR}}"
    [ -n "$prerequisite_path" ] || return 1
    case "$prerequisite_path" in /*) return 1 ;; esac
    prerequisite_dir="$(cd "$(dirname "$doc")/$(dirname "$prerequisite_path")" \
      2>/dev/null && pwd)" || return 1
    prerequisite_target="${prerequisite_dir}/$(basename "$prerequisite_path")"
  fi

  canonical_target="$(cd "$(dirname "$ROOT_PREREQUISITE_DOC")" && pwd -P)/$(basename "$ROOT_PREREQUISITE_DOC")"
  if [ -f "$prerequisite_target" ]; then
    prerequisite_target="$(cd "$(dirname "$prerequisite_target")" && pwd -P)/$(basename "$prerequisite_target")"
  fi
  [ "$prerequisite_line" -lt "$first_root_reference_line" ] \
    && [ -f "$prerequisite_target" ] \
    && [ "$prerequisite_target" = "$canonical_target" ] \
    && visible_root_prerequisite_anchor "$prerequisite_target"
}
