# POSIX awk. Caller fixes LC_ALL=C for byte comparisons.
BEGIN { mode=""; section=""; version=0; added=0; helpful=0; bad=0; invalid=0; stopped=0; hint=0 }
function date_version(line) { return line ~ /^### \[[0-9]+\.[0-9]+\.[0-9]+\] - [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]/ }
function legacy_version(line) { return line ~ /^## v[0-9]+\.[0-9]+\.[0-9]+ \([0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]\)[ \t]*$/ }
function helpful_row(line) { return line ~ /^- ACE-[A-Za-z0-9][A-Za-z0-9._-]*: Helpful [+]1( ×[1-9][0-9]*)?(（.+）|[[:space:]]+—[[:space:]]+.+)[[:space:]]*$/ }
function comment_padding(size) { return sprintf("%*s", size, "") }
{
  line=$0; sub(/\r$/, "", line)
  if (NR==1 && line=="---") { frontmatter=1; next }
  if (frontmatter) { if (line=="---") frontmatter=0; next }
  trimmed=line; sub(/^[ \t]*/, "", trimmed)
  if (fence) {
    closer=trimmed; sub(/[ \t]*$/, "", closer)
    if (closer ~ /^(`+|~+)$/ && substr(closer,1,1)==fence_char && length(closer)>=fence_len) fence=0
    next
  }
  if (!comment && trimmed ~ /^(```|~~~)/) {
    fence_char=substr(trimmed,1,1); fence_len=0
    while (substr(trimmed,fence_len+1,1)==fence_char) fence_len++
    if (!(fence_char=="`" && index(substr(trimmed,fence_len+1),"`")>0)) { fence=1; next }
  }
  visible=""
  while (length(line)) {
    if (comment) {
      comment_end=index(line,"-->")
      if (!comment_end) { visible=visible comment_padding(length(line)); line=""; break }
      visible=visible comment_padding(comment_end+2)
      line=substr(line,comment_end+3); comment=0
    } else {
      comment_start=index(line,"<!--")
      if (!comment_start) { visible=visible line; line=""; break }
      visible=visible substr(line,1,comment_start-1) comment_padding(4); line=substr(line,comment_start+4); comment=1
    }
  }
  line=visible
  if (stopped) next
  if (mode=="") {
    if (line ~ /^##[ \t]+Changelog[ \t]*$/) { mode="canonical"; next }
    if (legacy_version(line)) { mode="legacy"; version++; next }
    next
  }
  if (mode=="legacy" && legacy_version(line)) { version++; next }
  if (line ~ /^##[ \t]+/) { stopped=1; next }
  if (mode=="canonical") {
    if (date_version(line)) { version++; section=""; next }
    if (line ~ /^#### 追加/) { section="added"; next }
    if (line ~ /^#### カウンター更新/) { section="helpful"; next }
    if (line ~ /^#### /) { section=""; next }
    if (!version) { if (line !~ /^[ \t]*$/ && line !~ /^[ \t]*\[[^]]+\]\([^)]+\)[ \t]*$/) hint=1; next }
    if (section=="helpful") {
      if (helpful_row(line)) helpful++
      else if (line ~ /Helpful [+]1/) { bad++; print FILENAME ":" NR ": " line }
    } else if (section=="added" && line ~ /^- ACE-[^:[:space:]]+: .+/) added++
    next
  }
  if (line ~ /^- 更新:/) {
    normalized=line; sub(/^- 更新: /,"- ",normalized); sub(/ Helpful [+]1/,": Helpful +1",normalized)
    if (helpful_row(normalized)) helpful++
    else { bad++; print FILENAME ":" NR ": " line }
    next
  }
  if (line ~ /^- 追加:/) {
    body=line; sub(/^- 追加: /,"",body); count=split(body,parts,"、"); valid=(count>0)
    for (part=1; part<=count; part++) {
      item=parts[part]; sub(/^[[:space:]]+/,"",item); sub(/[[:space:]]+$/,"",item)
      if (item !~ /^ACE-[A-Za-z0-9][A-Za-z0-9._-]*（.+）$/) valid=0
    }
    if (valid) added+=count
    else { invalid++; print FILENAME ":" NR ": " line }
  }
}
END {
  if (frontmatter || fence) print "VERDICT=unreadable-format"
  else if (mode=="") print "VERDICT=no-changelog"
  else if (bad) print "VERDICT=unreadable-helpful"
  else if (invalid) print "VERDICT=unreadable-format"
  else if (!version && !hint) print "VERDICT=empty-stub"
  else if (!added && !helpful) print "VERDICT=no-rows"
  else print "VERDICT=ok"
}
