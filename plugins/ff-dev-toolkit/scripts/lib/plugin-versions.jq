# GitHub 以外へ gh の認証を送らない。source の文字列をコマンドとして評価しない。
def github_repo:
  sub("^https://github.com/"; "") | sub("^git@github.com:"; "")
  | sub("^ssh://git@github.com/"; "") | sub("\\.git$"; "")
  | if test("^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$") then . else error("unsupported repository") end;

def relative_path:
  sub("^\\./"; "") | sub("/$"; "")
  | if . == "." or . == "" then ""
    elif startswith("/") or (split("/") | any(. == ".." or . == "." or . == ""))
      or test("[\u0000-\u001f\u007f?#\\\\]") then error("unsafe path") else . end;

def source_location($parent; $root):
  if type == "string" then
    . as $source | ($root | relative_path) as $prefix
    | (if startswith("./") or $prefix == "" then $source else $prefix + "/" + $source end | relative_path) as $path
    | $parent + {path:(([ $parent.path // "", $path ] | map(select(. != "")) | join("/")) | relative_path)}
  elif .source == "github" or .source == "git" or .source == "url" or .source == "git-subdir" then
    {repo:((.repo // .url) | github_repo), path:((.path // "") | relative_path), ref:(.sha // .ref // "")}
  else error("unsupported source") end;

def semver:
  capture("^v?(?<major>0|[1-9][0-9]*)\\.(?<minor>0|[1-9][0-9]*)\\.(?<patch>0|[1-9][0-9]*)(?:-(?<pre>[0-9A-Za-z-]+(?:\\.[0-9A-Za-z-]+)*))?(?:\\+[0-9A-Za-z-]+(?:\\.[0-9A-Za-z-]+)*)?$")
  | .pre = ((.pre // "") | if . == "" then [] else split(".") end)
  | if any(.pre[]; test("^0[0-9]+$")) then error("invalid prerelease") else . end;

def cmp($a; $b): if $a == $b then 0 elif $a < $b then -1 else 1 end;
def numeric_key: [length, .];
def semver_compare($local; $remote):
  try (
    ($local | semver) as $a | ($remote | semver) as $b
    | cmp([$a.major,$a.minor,$a.patch] | map(numeric_key); [$b.major,$b.minor,$b.patch] | map(numeric_key)) as $core
    | if $core != 0 then $core
      elif $a.pre == $b.pre then 0
      elif $a.pre == [] then 1 elif $b.pre == [] then -1
      else reduce range(0; ([($a.pre|length), ($b.pre|length)] | max)) as $i (0;
        if . != 0 then .
        elif $a.pre[$i] == null then -1 elif $b.pre[$i] == null then 1
        else $a.pre[$i] as $x | $b.pre[$i] as $y
          | if ($x|test("^[0-9]+$")) and ($y|test("^[0-9]+$")) then cmp($x|numeric_key; $y|numeric_key)
            elif $x|test("^[0-9]+$") then -1 elif $y|test("^[0-9]+$") then 1
            else cmp($x; $y) end
        end)
      end
  ) catch null;
