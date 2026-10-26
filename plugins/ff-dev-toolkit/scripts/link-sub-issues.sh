#!/usr/bin/env bash
#
# GitHub sub-issues の親子紐付けヘルパ（観測台帳 OBS-052 の対策）。
#
# `gh api` の `-f key=value` は値を常に文字列で送る。sub-issues API の
# `sub_issue_id` は integer なので、`-f` だとスキーマ検証で 422 になり、
# ループで回すと全件が同じエラーで落ちる。型付きは `-F`。この取り違えは
# 知識として 3 回記録しても、呼び出し口が無いとその場で組み立て直されて
# 再発した。本スクリプトがその呼び出し口であり、綴りを 1 箇所へ固定する。
#
# 使い方:
#   link-sub-issues.sh --repo OWNER/REPO <parent> <child> [child...]
#   link-sub-issues.sh --repo OWNER/REPO --dry-run <parent> <child>...
#   --github-input /absolute/index.json: file取得（originと--repo一致、PLAN/read-back待機rc2）。
#
#   <parent> / <child> は Issue 番号（`123` または `#123`）。database ID ではない。
#   ヘルパが `GET repos/.../issues/<n>` の `.id` を引いてから POST する。
#
#   --repo を省略したときは `git remote get-url origin` から owner/repo を取る。
#   cwd のパスや GH_REPO からは取らない（作業ディレクトリ名を owner と誤読して
#   全件 404 になる観測がある）。取れなければ使い方エラーで止まる。
#
# 失敗時:
#   HTTP 本文（ステータスと message）を stderr へ出す。`--silent` も
#   `2>/dev/null` も使わない。1 件目の失敗で止まり、残りは叩かない。
#
# 終了コード:
#   0  全件成功（既に紐付いている子は skip して成功扱い）
#   1  API 呼び出しの失敗（本文は stderr）
#   2  使い方の誤り / gh 不在 / repo を解決できない
#
# 実装上の制約:
#   - macOS 標準の bash 3.2 で動くこと（連想配列・readarray を使わない）
#   - 固定 root 経由（docs-template / ガード案内）で呼ばれる入口なので
#     plugin root ガードを置く。handoff 無しの直接起動は止めない。

set -euo pipefail

# ff-dev-toolkit-script-root-guard:start
# plugin root 固定ガード（script 側）。同じ停止を skill 本文の契約節も述べているが、
# ホストが実行部だけを解決済み絶対 path として注入し契約節が本文から落ちた経路では、
# 散文のガードはちょうどそのとき手元に無い（防御が守ろうとしている失敗と、防御が
# 失われる条件が同じ）。実行部と同じファイルへ置くことで、契約を読んでいない consumer
# でも止まる。**候補は探しに行かない** — cache / marketplace / 旧インストール領域の
# 走査も version 名の並べ替えによる選び直しもしない。それが本ガードの防ごうとしている
# 失敗そのもので、探索を足すと防御が防御対象を踏む。渡された handoff を canonical 化
# して自分の実体位置と比べるだけにする。handoff が 1 つも無い直接起動（端末・テスト・
# CI の pin 実行）は止めない — 比較対象が無い状態を不一致とみなすと、正規の直接起動が
# 全部止まる。
#
# 到達性は呼び出し側とセットで成り立つ。host は plugin root を Bash tool の環境へ
# export せず、実行部テキストへ解決済みの値を差し込むだけなので、handoff を運ぶのが
# skill 本文の resolver だけだと「本文が落ちた」ちょうどそのときに handoff も消え、
# ガードは比較対象なしで素通しになる。そこで固定 root 経由の実行部は
# `FF_DEV_TOOLKIT_ROOT="${FF_DEV_TOOLKIT_ROOT}" bash "${FF_DEV_TOOLKIT_ROOT}/scripts/<名>"`
# の形にして handoff を**同じ 1 行へ**載せる。実行するスクリプトの path だけを別領域へ
# 書き換える事故は、この 1 行の中の不一致として検出できる。
#
# 判定不能は素通しではなく停止に倒す（fail-closed）。更新中の部分的な消失では、
# 判定材料（別 plugin かどうかを言う manifest）そのものが壊れた領域の内側にある。
#
# 外部コマンドを使わない。PATH が壊れた環境はこのガードが最後の砦になる場面そのもので、
# dirname / grep / sed に依存すると「自分の位置を判定できないまま素通し」になる。
# その代わり builtin 側の環境依存を自分で閉じる: path の canonical 化はすべて
# `CDPATH= cd -P --` で行う。`cd` は CDPATH が効くと**別のdirectoryへ移動したうえで
# 移動先を stdout へ出す**ので、export された CDPATH に同名の subdirectory があると
# 相対起動（`bash scripts/<名>`）で自分の位置を取り違え、コマンド置換も 2 行になる。
# 「止めない」と明文で約束している端末・テスト・CI の直接起動が、正規の handoff 付き
# でも止まっていた。各 script の複製は byte 一致で、tests/plugin-root-contract が固定する。
ff_script_root_guard_manifest_field() { # <plugin.json> <キー> → 値をstdoutへ / 読めなければ非0
  # JSON を「文字列の外 / 中」に分けて走査し、**root object 直下（ネスト深さ 1）のキー**
  # だけを返す。行単位に最初の `"<キー>"` を拾う形だと、`author` のような入れ子 object が
  # top-level の `name` より前にある manifest で `author.name` を掴み、別 plugin と誤読して
  # 照合ごと飛ばす（= fail-open）。同じ判定を docs-template の resolver fence の awk も
  # 「`{` 直後の name marker」として要求しており、厳しさを揃える。fence と違って version も
  # 読むので「最初のキー」ではなく「深さ 1 のキー」に寄せる。
  local file="$1" key="$2" line="" rest="" seg="" tmp="" acc=""
  local depth=0 instr=0 expect=0 last="" bs=0
  # symlink・非通常ファイル・読めないものは「確認できない」に倒す（除外の根拠にしない）。
  [ -f "$file" ] && [ ! -L "$file" ] && [ -r "$file" ] || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    rest="$line"
    while [ -n "$rest" ]; do
      if [ "$instr" -eq 1 ]; then
        case "$rest" in
          *'"'*) seg="${rest%%'"'*}"; rest="${rest#*'"'}" ;;
          *) acc="${acc}${rest}"; rest=""; continue ;;
        esac
        # 直前が奇数個の backslash なら、その `"` は escape されていて文字列は続く。
        tmp="$seg"; bs=0
        while [ "${tmp%\\}" != "$tmp" ]; do bs=$((bs + 1)); tmp="${tmp%\\}"; done
        acc="${acc}${seg}"
        if [ $((bs % 2)) -eq 1 ]; then acc="${acc}\""; continue; fi
        instr=0
        if [ "$expect" -eq 1 ]; then printf '%s' "$acc"; return 0; fi
        last="$acc"; acc=""
        continue
      fi
      case "$rest" in
        *'"'*) seg="${rest%%'"'*}"; rest="${rest#*'"'}"; instr=1; acc="" ;;
        *) seg="$rest"; rest="" ;;
      esac
      # 深さは文字列の外に出た構造文字だけで数える（値の中の括弧に釣られない）。
      tmp="$seg"
      while [ "${tmp#*'{'}" != "$tmp" ]; do depth=$((depth + 1)); tmp="${tmp#*'{'}"; done
      tmp="$seg"
      while [ "${tmp#*'['}" != "$tmp" ]; do depth=$((depth + 1)); tmp="${tmp#*'['}"; done
      tmp="$seg"
      while [ "${tmp#*'}'}" != "$tmp" ]; do depth=$((depth - 1)); tmp="${tmp#*'}'}"; done
      tmp="$seg"
      while [ "${tmp#*']'}" != "$tmp" ]; do depth=$((depth - 1)); tmp="${tmp#*']'}"; done
      case "$seg" in
        *:*) if [ "$depth" -eq 1 ] && [ -n "$last" ] && [ "$last" = "$key" ]; then expect=1; fi ;;
      esac
      # 値が object / array なら、次に閉じる文字列はその中身であって値ではない。
      case "$seg" in
        *'{'*|*'['*|*,*) expect=0 ;;
      esac
      last=""
    done
  done < "$file"
  return 1
}
ff_assert_script_plugin_root() {
  local self="${1:-}" dir="" root="" var="" value="" canonical="" used="" skipped="" other="" version="" quiet=0
  [ -n "$self" ] || { echo "❌ 起動したスクリプトの実体位置を取得できません" >&2; return 1; }
  case "$self" in */*) dir="${self%/*}" ;; *) dir="." ;; esac
  dir="$(CDPATH= cd -P -- "$dir" 2>/dev/null && pwd -P)" || dir=""
  [ -n "$dir" ] || { echo "❌ 起動したスクリプトのdirectoryを解決できません: ${self}" >&2; return 1; }
  root="$(CDPATH= cd -P -- "${dir}/.." 2>/dev/null && pwd -P)" || root=""
  [ -n "$root" ] || { echo "❌ 自分のplugin rootを解決できません: ${dir}" >&2; return 1; }
  self="${dir}/${self##*/}"
  # スクリプト自身がsymlinkなら止める。親directoryしかcanonical化しないと、期待root内の
  # symlinkから別checkoutの実体を実行でき、「実体位置とhandoffの照合」の前提が崩れる。
  if [ -L "$self" ]; then
    {
      echo "❌ ff-dev-toolkit更新後にこのskillを再呼び出してください（起動したスクリプトがsymlinkです）"
      echo "   起動したスクリプト: ${self}"
      echo "   symlinkは期待rootの内側から別領域の実体を指せるため、実体位置の照合が成立しません。"
      echo "   別のインストール領域へ切り替えて実行しないこと — version混在と未リリースWIPの実行になります。"
      echo "   cacheや別checkoutを探さず、実体のパスで起動してください。"
    } >&2
    return 1
  fi
  for var in FF_DEV_TOOLKIT_ROOT CLAUDE_PLUGIN_ROOT GROK_PLUGIN_ROOT; do
    eval "value=\${${var}:-}"
    [ -n "$value" ] || continue
    canonical="$(CDPATH= cd -P -- "$value" 2>/dev/null && pwd -P)" || canonical=""
    # 正規形は plugin root だが、scripts/ を直接指す綴りも正規に受理されている
    # （templates/codex-review.sh の canonical_toolkit_root が両方を受ける）。同じ実体を
    # 指している限り一致として扱う。
    if [ -n "$canonical" ] && { [ "$canonical" = "$root" ] || [ "$canonical" = "$dir" ]; }; then
      [ -n "$used" ] || used="$var"
      continue
    fi
    # 実在する別 plugin の root は我々への handoff ではない（別 plugin 経由の正規呼び出し
    # まで殺さない）。ただし除外できるのは「manifestが通常ファイルとして読めて、名前が別だと
    # 確認できた」ときだけにする。消えているroot も、読めないmanifest も、誰のものか判定
    # できない点は同じ。
    other=""
    if [ -n "$canonical" ]; then
      other="$(ff_script_root_guard_manifest_field "${canonical}/.claude-plugin/plugin.json" name)" || other=""
    fi
    if [ -n "$other" ] && [ "$other" != "ff-dev-toolkit" ]; then
      skipped="${skipped:+${skipped} }${var}=別plugin(${other})"
      continue
    fi
    {
      echo "❌ ff-dev-toolkit更新後にこのskillを再呼び出してください（plugin rootが固定値と一致しません）"
      echo "   起動したスクリプト: ${self}"
      echo "   このスクリプトのplugin root: ${root}"
      echo "   hostが渡したroot（${var}）: ${value}"
      if [ -z "$canonical" ]; then
        echo "   不一致の内容: 指しているdirectoryが実在しません（plugin rootが消えています）"
      elif [ -z "$other" ]; then
        echo "   不一致の内容: 指す先のplugin manifestを読めず、誰のrootか判定できません（判定不能は停止に倒します）"
      else
        echo "   不一致の内容: このスクリプトは別のインストール領域の実体です"
      fi
      echo "   別のインストール領域へ切り替えて実行しないこと — version混在と未リリースWIPの実行になります。"
      echo "   cacheや別checkoutを探さず、pluginを再導入してからskillを呼び直してください。"
    } >&2
    return 1
  done
  # provenance（実体 path と version の 1 行）は「想定外の場所から起動された」ことを
  # agent にもログを読む人にも見せて診断コストを下げる。照合を飛ばした handoff も理由付きで
  # 出す — 渡っていた事実を「なし・直接起動」と報告すると、診断価値を損ない事実とも食い違う。
  # 出力そのものが契約になっている script（成功時は無出力・stderr を混ぜない等）では情報行が
  # 契約違反になるので、その basename だけを**この block 内の allowlist**で抑止する。
  # 外から env で抑止できる形にすると allowlist が実効的な制約にならないので、環境変数では
  # 抑止できない。抑止できるのは provenance だけで、停止の判定と案内は抑止できない。
  case "${self##*/}" in
    check-merge-freshness.sh|check-plugin-versions.sh) quiet=1 ;;
  esac
  if [ "$quiet" -ne 1 ]; then
    version="$(ff_script_root_guard_manifest_field "${root}/.claude-plugin/plugin.json" version)" || version=""
    echo "ℹ️  ff-dev-toolkit ${version:-version不明} — 実行実体: ${self}（handoff: ${used:-なし・直接起動}${skipped:+ / 照合対象外: ${skipped}}）" >&2
  fi
  return 0
}
ff_assert_script_plugin_root "${BASH_SOURCE[0]}" || exit 2
# ff-dev-toolkit-script-root-guard:end

usage() {
  cat >&2 <<'EOF'
Usage: link-sub-issues.sh --repo OWNER/REPO <parent> <child> [child...]
       link-sub-issues.sh --repo OWNER/REPO --dry-run <parent> <child>...

Link child issues as GitHub sub-issues of <parent>. Issue numbers only
(`123` or `#123`), not database IDs. The helper resolves `.id` and POSTs
with typed `-F sub_issue_id=` (never `-f`, which sends a string and 422s).

  --repo OWNER/REPO   target repository (required unless origin remote parses)
  --dry-run           resolve IDs and print the POST, do not POST
  -h, --help          show this help

On failure the HTTP body is printed to stderr and the script stops at the
first child (it does not keep looping). Exit 2 = usage / missing gh / repo.
EOF
}

REPO=""
DRY_RUN=0
github_input=""
POSITIONAL=()

while [ "$#" -gt 0 ]; do
  case "$1" in
    --github-input)
      [ "$#" -ge 2 ] && [ -n "$2" ] || { echo 'github-input: index argument missing' >&2; exit 2; }
      github_input="$2"; shift 2
      ;;
    --repo)
      if [ "$#" -lt 2 ]; then
        echo "link-sub-issues: --repo には OWNER/REPO が必要です" >&2
        exit 2
      fi
      REPO="$2"
      shift 2
      ;;
    --repo=*)
      REPO="${1#--repo=}"
      shift
      ;;
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    --)
      shift
      POSITIONAL+=("$@")
      break
      ;;
    -*)
      echo "link-sub-issues: 未知のオプション: $1" >&2
      usage
      exit 2
      ;;
    *)
      POSITIONAL+=("$1")
      shift
      ;;
  esac
done

normalize_number() { # <token> → digits or empty
  local n="$1"
  n="${n#\#}"
  case "$n" in
    ''|*[!0-9]*) printf '' ;;
    *) printf '%s' "$n" ;;
  esac
}

parse_origin_repo() {
  local url="$1"
  url="${url%.git}"
  url="${url%/}"
  case "$url" in
    git@github.com:*)
      printf '%s' "${url#git@github.com:}"
      ;;
    https://github.com/*|http://github.com/*|ssh://git@github.com/*)
      printf '%s' "${url#*github.com[:/]}"
      ;;
    *)
      return 1
      ;;
  esac
}

if [ -z "$REPO" ]; then
  origin_url=""
  origin_url="$(git remote get-url origin 2>/dev/null)" || origin_url=""
  if [ -n "$origin_url" ]; then
    REPO="$(parse_origin_repo "$origin_url")" || REPO=""
  fi
fi

case "$REPO" in
  [A-Za-z0-9_.-]*/[A-Za-z0-9_.-]*) : ;;
  *)
    echo "link-sub-issues: --repo OWNER/REPO を指定するか、origin が GitHub の owner/repo を指す git 作業ツリーで実行してください" >&2
    usage
    exit 2
    ;;
esac

if [ "${#POSITIONAL[@]}" -lt 2 ]; then
  echo "link-sub-issues: parent と child を 1 件以上指定してください" >&2
  usage
  exit 2
fi

PARENT="$(normalize_number "${POSITIONAL[0]}")"
if [ -z "$PARENT" ]; then
  echo "link-sub-issues: parent が Issue 番号ではありません: ${POSITIONAL[0]}" >&2
  exit 2
fi

CHILDREN=()
i=1
while [ "$i" -lt "${#POSITIONAL[@]}" ]; do
  child="$(normalize_number "${POSITIONAL[$i]}")"
  if [ -z "$child" ]; then
    echo "link-sub-issues: child が Issue 番号ではありません: ${POSITIONAL[$i]}" >&2
    exit 2
  fi
  if [ "$child" = "$PARENT" ]; then
    echo "link-sub-issues: parent と child が同じ番号です: #${child}" >&2
    exit 2
  fi
  CHILDREN+=("$child")
  i=$((i + 1))
done

if [ -n "$github_input" ]; then
  link_file_lib="$(CDPATH='' cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/github-input.sh" || exit 2
  [ -f "$link_file_lib" ] && [ -r "$link_file_lib" ] || { echo 'github-input: helper missing' >&2; exit 2; }
  github_shebang=""
  IFS= read -r github_shebang <"$link_file_lib" || true
  case "$github_shebang" in *$'\r') echo 'github-input: helper shebang must use LF' >&2; exit 2 ;; esac
  # shellcheck source=lib/github-input.sh
  . "$link_file_lib" || exit 2
  github_input_is_absolute "$github_input" || { _github_input_error index '--github-input must be absolute'; exit 2; }
  github_repository="$(_github_input_repository)" || exit 2
  [ "${github_repository#*://*/}" = "$REPO" ] || { _github_input_error link.membership 'origin/--repo mismatch'; exit 2; }
  link_file_tmp="$(mktemp -d)" || exit 2
  trap 'rm -rf "$link_file_tmp"' EXIT
  printf '{}\n' >"$link_file_tmp/position.json"
elif ! command -v gh >/dev/null 2>&1; then
  echo "link-sub-issues: gh が見つかりません" >&2
  exit 2
fi

# gh の stdout と stderr を合流して変数へ取る。成功なら stdout へ本文、失敗なら
# stderr へ本文を出して rc を返す。`--silent` も `2>/dev/null` も使わない。
run_gh() {
  local out rc
  out="$("$@" 2>&1)" && rc=0 || rc=$?
  if [ "$rc" -ne 0 ]; then
    printf '%s\n' "$out" >&2
    return "$rc"
  fi
  printf '%s' "$out"
  return 0
}

existing=""
existing_out=""
link_file_membership() { # phase -> numbers after complete, explicit terminal empty page
  local link_page=1 link_count
  : >"$link_file_tmp/numbers"
  jq -n --arg repository "$github_repository" --argjson parent "$PARENT" '{repository:$repository,parent:$parent}' >"$link_file_tmp/scope.json" || return 2
  while :; do
    jq -n --argjson page "$link_page" '{page:$page}' >"$link_file_tmp/page.json" || return 2
    github_file_read "$github_input" link.membership "$link_file_tmp/scope.json" "$1" "$link_file_tmp/page.json" >"$link_file_tmp/members.json" || return 2
    if ! jq -e 'type == "array" and all(.[]; .number | type == "number" and . > 0 and floor == .)' "$link_file_tmp/members.json" >/dev/null; then
      _github_input_error link.membership 'required field: [].number'; return 2
    fi
    link_count="$(jq length "$link_file_tmp/members.json")" || return 2
    case "$GITHUB_INPUT_LAST" in
      true) [ "$link_count" -eq 0 ] || { _github_input_error link.membership 'last page must be terminal []'; return 2; }; break ;;
      false) [ "$link_count" -gt 0 ] || { _github_input_error link.membership 'empty page without last=true'; return 2; } ;;
      *) _github_input_error link.membership "required page metadata: last (page=$link_page)"; return 2 ;;
    esac
    jq -r '.[].number' "$link_file_tmp/members.json" >>"$link_file_tmp/numbers" || return 2
    link_page=$((link_page + 1))
  done
  cat "$link_file_tmp/numbers"
}
if [ -n "$github_input" ]; then
  link_file_membership before-link >"$link_file_tmp/existing" || exit 2
  existing_out="$(cat "$link_file_tmp/existing")"
else
  existing_out="$(run_gh gh api --paginate "repos/${REPO}/issues/${PARENT}/sub_issues" --jq '.[].number')" || exit 1
fi
if [ -n "$existing_out" ]; then
  while IFS= read -r num || [ -n "$num" ]; do
    [ -n "$num" ] || continue
    existing="${existing} ${num}"
  done <<EOF
${existing_out}
EOF
  existing="${existing} "
fi

linked=0
skipped=0
child=""
child_id=""
post_out=""
post_rc=0

for child in "${CHILDREN[@]}"; do
  case "${existing}" in
    *" ${child} "*)
      echo "link-sub-issues: #${child} は既に #${PARENT} の sub-issue です（skip）"
      skipped=$((skipped + 1))
      continue
      ;;
  esac

  child_id=""
  if [ -n "$github_input" ]; then
    jq -n --arg repository "$github_repository" --argjson child "$child" '{repository:$repository,child:$child}' >"$link_file_tmp/scope.json" || exit 2
    github_file_read "$github_input" link.child-id "$link_file_tmp/scope.json" before-link-child "$link_file_tmp/position.json" >"$link_file_tmp/child.json" || exit 2
    if ! jq -e '.id | type == "number" and . > 0 and floor == .' "$link_file_tmp/child.json" >/dev/null; then
      _github_input_error link.child-id 'required field: id (integer database ID)'; exit 2
    fi
    child_id="$(jq -r '.id' "$link_file_tmp/child.json")"
  else
    child_id="$(run_gh gh api "repos/${REPO}/issues/${child}" --jq .id)" || {
      echo "link-sub-issues: #${child} の database ID を取得できませんでした" >&2
      exit 1
    }
  fi
  case "$child_id" in
    ''|*[!0-9]*)
      echo "link-sub-issues: #${child} の .id が整数ではありません: [${child_id}]" >&2
      exit 1
      ;;
  esac

  if [ "$DRY_RUN" -eq 1 ]; then
    echo "link-sub-issues: dry-run  gh api --method POST repos/${REPO}/issues/${PARENT}/sub_issues -F sub_issue_id=${child_id}  (#${child})"
    linked=$((linked + 1))
    existing="${existing} ${child} "
    continue
  fi

  if [ -n "$github_input" ]; then
    if link_file_membership "after-link-$child" >"$link_file_tmp/after" && grep -qxF "$child" "$link_file_tmp/after"; then
      echo "link-sub-issues: read-back verified #${child} -> #${PARENT}"
      linked=$((linked + 1)); existing="${existing} ${child} "
      continue
    fi
    jq -n --arg repository "$github_repository" --argjson parent "$PARENT" --argjson child "$child" '{repository:$repository,parent:$parent,child:$child}' >"$link_file_tmp/scope.json" || exit 2
    jq -n --argjson sub_issue_id "$child_id" '{sub_issue_id:$sub_issue_id}' >"$link_file_tmp/arguments.json" || exit 2
    jq -n --arg phase "after-link-$child" --argjson child "$child" '{operation:"link.membership",phase:$phase,expect:{contains_number:$child},pages:"page1 through terminal empty page"}' >"$link_file_tmp/readback.json" || exit 2
    github_file_plan link.write "$link_file_tmp/scope.json" "$link_file_tmp/arguments.json" "$link_file_tmp/readback.json" || exit 2
    exit 2
  fi

  # ここが OBS-052 の固定点。`-f` に変えると GitHub は
  # `Invalid property /sub_issue_id: "<id>" is not of type integer` を返す。
  post_out="$(gh api --method POST "repos/${REPO}/issues/${PARENT}/sub_issues" -F "sub_issue_id=${child_id}" 2>&1)" && post_rc=0 || post_rc=$?
  if [ "$post_rc" -ne 0 ]; then
    echo "link-sub-issues: #${child} (id=${child_id}) を #${PARENT} へ紐付けできませんでした" >&2
    printf '%s\n' "$post_out" >&2
    exit 1
  fi
  echo "link-sub-issues: linked #${child} (id=${child_id}) -> #${PARENT}"
  linked=$((linked + 1))
  existing="${existing} ${child} "
done

echo "link-sub-issues: done parent=#${PARENT} linked=${linked} skipped=${skipped} repo=${REPO}"
exit 0
