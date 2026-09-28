# Registry parsing and token overlap only; no model decisions here.
def glob_regex:
  [scan("\\*\\*/|\\*\\*|\\*|\\?|[^*?]") |
    if . == "**/" then "(?:.*/)?" elif . == "**" then ".*"
    elif . == "*" then "[^/]*" elif . == "?" then "[^/]"
    elif . as $c | ".[](){}+^$|\\" | contains($c) then "\\" + . else . end] | join("") | "^" + . + "$";
def entries($text; $source; $kind):
  reduce ($text | split("\n")[]) as $line
    ({items:[], current:null, fence:null};
     ($line | capture("^ {0,3}(?<run>`{3,}|~{3,})") // null) as $f |
     if $f != null then
       (if .fence == null then .fence = $f.run
        elif ($f.run[0:1] == .fence[0:1] and ($f.run|length) >= (.fence|length)) then .fence = null else . end) |
       if .current != null then .current.body += ($line + "\n") else . end
     elif .fence != null then
       if .current != null then .current.body += ($line + "\n") else . end
     elif ($line | test("^#{1,3} ")) then
       (if .current != null then .items += [.current] else . end) | .current = null |
       ($line | capture(if $kind == "principle" then "^### (?<id>P-[0-9]+): (?<title>.+)$"
                        else "^### (?<id>ACE-(?:i[0-9]+|[0-9]+)(?:-[0-9]+)?): (?<title>.+)$" end) // null) as $h |
       if $h != null then .current = ($h + {body:"", source:$source, kind:$kind}) else . end
     elif .current != null then .current.body += ($line + "\n") else . end) |
  .items + (if .current == null then [] else [.current] end) |
  map(select((.body | test("(?m)^\\|[ \\t]*Status[ \\t]*\\|[ \\t]*(deprecated|archived)[ \\t]*\\|")) | not));
# Same ASCII tokens and Japanese bigrams as build-ace-eval-sets.ts tokens().
def tokens:
  ascii_downcase as $text |
  ([$text | scan("[a-z0-9_][a-z0-9_.-]{2,}")] +
   [$text | gsub("[^\\p{Han}\\p{Hiragana}\\p{Katakana}ー]"; " ") | split(" ")[] |
    select(length >= 2) | . as $run | range(0; length-1) as $i | $run[$i:$i+2]]) | unique;
def similarity($a; $b):
  if ($a|length)==0 or ($b|length)==0 then 0
  else ([$a[] | . as $t | select($b | index($t))] | length) as $i |
    $i / (($a|length)+($b|length)-$i) end;
