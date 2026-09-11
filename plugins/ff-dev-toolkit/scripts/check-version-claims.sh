#!/usr/bin/env bash
# 最新 origin/default branch の固定 commit と index の差分を検査し、対象の未stage・未追跡変更を拒否する。
#
# 比較基準（origin/<default>）の取り方は実行環境で切り替える:
#   - ローカル（GITHUB_ACTIONS 未設定）: origin/<default> を fetch で最新化し、それが HEAD より
#     先行していれば「rebase 後に再実行」で exit 2。作業者には rebase という対処が存在するため、
#     stale な remote-tracking ref のまま測って古い base で緑を出す誤りを fail-closed で防ぐ
#   - GitHub Actions（GITHUB_ACTIONS=true）: fetch せず、job 開始時点で fetch 済みの remote-tracking
#     ref をそのまま基準にする。CI の checkout は特定 SHA に固定されており rebase という対処が
#     存在しないので、走行中に origin/<default> が先へ進んだ（並行セッションの knowledge 直 push・
#     リリース準備 PR のマージ）ことを理由に赤にしても実害と対応しない。検査入力を checkout SHA と
#     job 開始時点の ref に閉じ、走行中の外向き操作に左右されないようにする（週次 run-all の
#     shared-version-convergence suite が本スクリプトを呼ぶ）。先行ガード自体は残す — checkout が
#     job 開始時点の origin/<default> より古い場合（既定ブランチ以外からの dispatch、checkout〜fetch
#     step の間に入った push）は従来どおり exit 2 にする（fetch を省くだけで判定は緩めない）
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

root=""
path_list=""
cleanup() { [[ -z "$path_list" ]] || rm -f "$path_list"; }
trap cleanup EXIT
trap 'exit 130' HUP INT TERM
while [[ $# -gt 0 ]]; do
  case "$1" in
    --root) shift; [[ $# -gt 0 ]] || { echo "Usage: $0 [--root <repository>]" >&2; exit 2; }; root="$1" ;;
    *) echo "Usage: $0 [--root <repository>]" >&2; exit 2 ;;
  esac
  shift
done
[[ -n "$root" ]] || root="$(git rev-parse --show-toplevel 2>/dev/null)" || { echo "✗ repository root を解決できません" >&2; exit 2; }
root="$(cd "$root" && pwd -P)" || { echo "✗ repository root を正規化できません" >&2; exit 2; }
contract_missing=0
if [[ ! -e "$root/.version-claims" && ! -L "$root/.version-claims" ]]; then contract_missing=1
else [[ -d "$root/.version-claims" && ! -L "$root/.version-claims" ]] || { echo "✗ .version-claims が directory ではないか symlink です" >&2; exit 2; }
fi

read_version() {
  awk '
    NR == 1 { if ($0 != "---") { no_frontmatter=1; exit }; next }
    !closed && $0 == "---" { closed=1; next }
    !closed && /^version:[[:space:]]*/ {
      count++; value=$0; sub(/^version:[[:space:]]*/, "", value)
      if (value ~ /^"[^"]*"$/) { sub(/^"/, "", value); sub(/"$/, "", value) }
    }
    END {
      if (no_frontmatter) exit 1
      if (!closed || count > 1) exit 2
      if (count == 0) exit 1
      print value
    }
  ' "$1"
}

resolve_fresh_base() {
  default_ref="$(git -C "$root" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null)" || { echo "✗ origin/HEAD を解決できません" >&2; return 2; }
  [[ "$default_ref" == origin/* ]] || { echo "✗ origin/HEAD が不正です" >&2; return 2; }
  default_branch="${default_ref#origin/}"
  if [[ "${GITHUB_ACTIONS:-}" == true ]]; then
    # CI: job 開始時点の remote-tracking ref を基準に固定する（ヘッダコメント参照）。fetch すると
    # 走行中に進んだ live の origin/<default> を取り込み、checkout SHA に閉じた検査でなくなる。
    default_base="$(git -C "$root" rev-parse --verify "${default_ref}^{commit}")" || { echo "✗ $default_ref の commit を固定できません（CI では job 開始時点に fetch 済みの remote-tracking ref が必要です）" >&2; return 2; }
    git -C "$root" merge-base --is-ancestor "$default_base" HEAD || { echo "✗ ${default_ref}（job 開始時点の remote-tracking ref）が checkout より先行しています。既定ブランチの最新 SHA で dispatch し直してください" >&2; return 2; }
    return 0
  fi
  git -C "$root" fetch origin "+refs/heads/${default_branch}:refs/remotes/origin/${default_branch}" >/dev/null 2>&1 || { echo "✗ $default_ref を最新化できません" >&2; return 2; }
  default_base="$(git -C "$root" rev-parse --verify "${default_ref}^{commit}")" || { echo "✗ $default_ref の commit を固定できません" >&2; return 2; }
  git -C "$root" merge-base --is-ancestor "$default_base" HEAD || { echo "✗ $default_ref が HEAD より先行しています。rebase 後に再実行してください" >&2; return 2; }
}

path_is_canonical() {
  [[ "$1" =~ ^docs/[A-Za-z0-9._-]+(/[A-Za-z0-9._-]+)*\.md$ || "$1" =~ ^\.version-claims/docs/[A-Za-z0-9._-]+(/[A-Za-z0-9._-]+)*\.md\.claim$ ]]
}

reject_unsafe_or_unstaged_paths() {
  local path unsafe=0 unstaged untracked
  path_list="$(mktemp "${TMPDIR:-/tmp}/version-claim-paths.XXXXXX")" || { echo "✗ path 検査用一時ファイルを作成できません" >&2; return 2; }
  git -C "$root" ls-files -co --exclude-standard -z -- 'docs/*.md' 'docs/**/*.md' '.version-claims/*.claim' '.version-claims/**/*.claim' > "$path_list" || { echo "✗ version 文書 path を列挙できません" >&2; return 2; }
  while IFS= read -r -d '' path; do
    path_is_canonical "$path" || { echo "✗ version claim 対象外の特殊 path です: $path" >&2; unsafe=1; }
  done < "$path_list"
  rm -f "$path_list"; path_list=""
  [[ "$unsafe" -eq 0 ]] || return 1
  if ! unstaged="$(git -C "$root" -c core.quotePath=false diff --name-only -- 'docs/*.md' 'docs/**/*.md' '.version-claims/*.claim' '.version-claims/**/*.claim' 2>&1)"; then echo "✗ version 文書の未stage差分を取得できません: ${unstaged%%$'\n'*}" >&2; return 2; fi
  if ! untracked="$(git -C "$root" -c core.quotePath=false ls-files --others --exclude-standard -- 'docs/*.md' 'docs/**/*.md' '.version-claims/*.claim' '.version-claims/**/*.claim' 2>&1)"; then echo "✗ version 文書の未追跡 path を列挙できません: ${untracked%%$'\n'*}" >&2; return 2; fi
  [[ -z "$unstaged" && -z "$untracked" ]] || { echo "✗ version 文書と claim はマージ対象の同じ index/tree に stage してから検査してください" >&2; return 1; }
}

index_has() {
  local entry entry_count signature
  entry="$(git -C "$root" ls-files --stage -- "$1")" || { echo "✗ index entry を検査できません: $1" >&2; return 2; }
  [[ -n "$entry" ]] || return 1
  entry_count="$(printf '%s\n' "$entry" | grep -c '')"
  signature="$(printf '%s\n' "$entry" | awk '{print $1 ":" $3}')"
  [[ "$entry_count" -eq 1 && "$signature" == "100644:0" ]] || { echo "✗ index entry が単一の通常ファイルではありません: $1 ($signature)" >&2; return 3; }
}
read_index_version() {
  local index_document
  index_document="$(git -C "$root" show ":$1" 2>&1)" || { echo "✗ index 文書を読み込めません: $1: ${index_document%%$'\n'*}" >&2; return 3; }
  read_version - <<< "$index_document"
}

read_current_version() {
  local doc="$1" base_entry_for_version base_version_rc
  if version="$(read_index_version "$doc")"; then return 0; else version_rc=$?; fi
  case "$version_rc" in
    1) ;;
    2) echo "✗ frontmatter version が不正です: $doc" >&2; return 1 ;;
    *) return 2 ;;
  esac
  base_entry_for_version="$(git -C "$root" ls-tree "$default_base" -- "$doc")" || { echo "✗ base 文書を検査できません: $doc" >&2; return 2; }
  [[ -n "$base_entry_for_version" ]] || return 3
  if git -C "$root" show "$default_base:$doc" | read_version - >/dev/null 2>&1; then base_version_rc=0; else base_version_rc=$?; fi
  case "$base_version_rc" in
    0) echo "✗ versioned 文書から version が削除されました: $doc" >&2; return 1 ;;
    1) return 3 ;;
    *) echo "✗ base 文書の version を検査できません: $doc" >&2; return 2 ;;
  esac
}

claim_is_required() {
  local doc="$1" base_entry="$2" base_version base_version_rc
  if [[ -z "$base_entry" ]]; then return 0; fi
  if base_version="$(git -C "$root" show "$default_base:$doc" | read_version -)"; then base_version_rc=0; else base_version_rc=$?; fi
  [[ "$base_version_rc" -le 1 ]] || { echo "✗ base version を検査できません: $doc" >&2; return 2; }
  [[ "$base_version_rc" -eq 0 && "$base_version" == "$version" ]] || return 0
  case "$doc" in docs/08-knowledge/PLAYBOOK.md|docs/03-implementation/PATTERNS.md) return 0 ;; esac
  return 1
}

validate_claim_record() {
  local doc="$1" base_entry="$2" claim_rel base_blob current_blob change expected_blob actual_blob index_rc
  claim_rel=".version-claims/${doc}.claim"
  if index_has "$claim_rel"; then index_rc=0; else index_rc=$?; fi
  [[ "$index_rc" -le 1 ]] || return 2
  [[ "$index_rc" -eq 0 ]] || { echo "✗ claim がマージ対象の同じ index/tree にありません: $claim_rel" >&2; return 1; }
  [[ "$version" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]] || { echo "✗ version が SemVer ではありません: $doc" >&2; return 1; }
  if [[ -n "$base_entry" ]]; then base_blob="$(printf '%s\n' "$base_entry" | awk '{print $3}')"; else base_blob=ABSENT; fi
  current_blob="$(git -C "$root" rev-parse ":$doc")" || { echo "✗ index blob を取得できません: $doc" >&2; return 2; }
  change="$(printf '%s\n' "base=$base_blob" "current=$current_blob" | git -C "$root" hash-object --stdin)" || { echo "✗ claim digest を生成できません: $doc" >&2; return 2; }
  expected_blob="$(printf '%s\n' "document=$doc" "version=$version" "change=$change" | git -C "$root" hash-object --stdin)" || { echo "✗ claim 期待 blob を生成できません: $doc" >&2; return 2; }
  actual_blob="$(git -C "$root" rev-parse ":$claim_rel")" || { echo "✗ index claim blob を読めません: $claim_rel" >&2; return 2; }
  [[ "$actual_blob" == "$expected_blob" ]] || { echo "✗ claim が文書差分と byte 一致しません: $claim_rel" >&2; return 1; }
}

validate_changed_document() {
  local doc="$1" claim_rel base_entry version_rc required_rc doc_index_rc claim_index_rc
  claim_rel=".version-claims/${doc}.claim"
  if index_has "$doc"; then doc_index_rc=0; else doc_index_rc=$?; fi
  [[ "$doc_index_rc" -le 1 ]] || return 2
  if [[ "$doc_index_rc" -eq 1 ]]; then
    if index_has "$claim_rel"; then claim_index_rc=0; else claim_index_rc=$?; fi
    [[ "$claim_index_rc" -le 1 ]] || return 2
    [[ "$claim_index_rc" -eq 1 ]] || { echo "✗ 削除文書の claim が残っています: $claim_rel" >&2; return 1; }
    return 0
  fi
  if read_current_version "$doc"; then version_rc=0; else version_rc=$?; fi
  [[ "$version_rc" -ne 3 ]] || return 0
  [[ "$version_rc" -eq 0 ]] || return "$version_rc"
  base_entry="$(git -C "$root" ls-tree "$default_base" -- "$doc")" || { echo "✗ base blob を取得できません: $doc" >&2; return 2; }
  if claim_is_required "$doc" "$base_entry"; then required_rc=0; else required_rc=$?; fi
  [[ "$required_rc" -ne 2 ]] || return 2
  [[ "$required_rc" -eq 0 ]] || return 0
  validate_claim_record "$doc" "$base_entry"
}

validate_changed_claim() {
  local claim_rel="$1" doc expected_claim_rel diff_rc old_claim base_entry claim_index_rc doc_index_rc
  if index_has "$claim_rel"; then claim_index_rc=0; else claim_index_rc=$?; fi
  [[ "$claim_index_rc" -le 1 ]] || return 2
  if [[ "$claim_index_rc" -eq 1 ]]; then
    old_claim="$(git -C "$root" show "$default_base:$claim_rel" 2>/dev/null)" || { echo "✗ 削除 claim の base を読めません: $claim_rel" >&2; return 1; }
    doc="$(printf '%s\n' "$old_claim" | sed -n 's/^document=//p')"
    if index_has "$doc"; then doc_index_rc=0; else doc_index_rc=$?; fi
    [[ "$doc_index_rc" -le 1 ]] || return 2
    [[ "$doc_index_rc" -eq 1 ]] || { echo "✗ 文書を残した claim 削除です: $claim_rel" >&2; return 1; }
  else
    doc="$(git -C "$root" show ":$claim_rel" | sed -n 's/^document=//p')" || { echo "✗ claim から document= を読めません: $claim_rel" >&2; return 2; }
    if git -C "$root" diff --cached --quiet "$default_base" -- "$doc"; then diff_rc=0; else diff_rc=$?; fi
    case "$diff_rc" in
      0) echo "✗ 文書変更を伴わない claim 変更です: $claim_rel" >&2; return 1 ;;
      1) ;;
      *) echo "✗ claim 対象文書の差分を検査できません: $doc" >&2; return 2 ;;
    esac
  fi
  expected_claim_rel=".version-claims/${doc}.claim"
  [[ -n "$doc" && "$claim_rel" == "$expected_claim_rel" ]] || { echo "✗ claim path と document が一致しません: $claim_rel" >&2; return 1; }
  if [[ "$claim_index_rc" -eq 0 ]]; then
    if version="$(read_index_version "$doc")"; then version_rc=0; else version_rc=$?; fi
    case "$version_rc" in 0) ;; 1|2) echo "✗ claim 対象文書の version が不正です: $doc" >&2; return 1 ;; *) return 2 ;; esac
    base_entry="$(git -C "$root" ls-tree "$default_base" -- "$doc")" || { echo "✗ claim 対象の base blob を取得できません: $doc" >&2; return 2; }
    validate_claim_record "$doc" "$base_entry"
  fi
}

if [[ "$contract_missing" -eq 1 ]]; then
  if origin_url="$(git -C "$root" config --get remote.origin.url 2>&1)"; then origin_rc=0; else origin_rc=$?; fi
  case "$origin_rc" in
  0)
    resolve_fresh_base
    base_contract_entry="$(git -C "$root" ls-tree "$default_base" -- .version-claims 2>&1)" || { echo "✗ default branch の version claim contract を検査できません: ${base_contract_entry%%$'\n'*}" >&2; exit 2; }
    if [[ -n "$base_contract_entry" ]]; then
      echo "✗ default branch に導入済みの .version-claims を directory ごと削除しています" >&2
      exit 1
    fi
    ;;
  1)
    contract_history="$(git -C "$root" log --all --format=%H -- .version-claims/README.md 2>&1)" || { echo "✗ version claim contract の履歴を検査できません: ${contract_history%%$'\n'*}" >&2; exit 2; }
    if [[ -n "$contract_history" ]]; then echo "✗ 導入済みの .version-claims を directory ごと削除しています" >&2; exit 1; fi
    ;;
  *) echo "✗ origin 設定を検査できません: ${origin_url%%$'\n'*}" >&2; exit 2 ;;
  esac
  echo "○ version claim contract 未導入のため検査をスキップします"
  exit 0
fi
resolve_fresh_base
base_contract_entry="$(git -C "$root" ls-tree "$default_base" -- .version-claims 2>&1)" || { echo "✗ default branch の version claim contract を検査できません: ${base_contract_entry%%$'\n'*}" >&2; exit 2; }
if [[ -n "$base_contract_entry" || -d "$root/.version-claims" ]]; then
  if index_has .version-claims/README.md; then contract_readme_rc=0; else contract_readme_rc=$?; fi
  [[ "$contract_readme_rc" -le 1 ]] || exit 2
  [[ "$contract_readme_rc" -eq 0 ]] || { echo "✗ 導入済み version claim contract の README.md を削除しています" >&2; exit 1; }
fi
unmerged_entries="$(git -C "$root" -c core.quotePath=false ls-files --unmerged -- 'docs/*.md' 'docs/**/*.md' '.version-claims/*.claim' '.version-claims/**/*.claim' 2>&1)" || { echo "✗ unmerged index を検査できません: ${unmerged_entries%%$'\n'*}" >&2; exit 2; }
[[ -z "$unmerged_entries" ]] || { echo "✗ version 文書または claim に unmerged index entry があります" >&2; exit 2; }
reject_unsafe_or_unstaged_paths
index_tree_fingerprint() {
  git -C "$root" -c core.quotePath=false ls-files --stage -z |
    git -C "$root" hash-object --stdin
}
initial_index_tree="$(index_tree_fingerprint)" || { echo "✗ 検査開始時の index tree を確定できません" >&2; exit 2; }
docs_changed="$(git -C "$root" -c core.quotePath=false diff --cached --no-renames --name-only "$default_base" -- 'docs/*.md' 'docs/**/*.md')" || { echo "✗ 変更文書を列挙できません" >&2; exit 2; }
claims_changed="$(git -C "$root" -c core.quotePath=false diff --cached --no-renames --name-only "$default_base" -- '.version-claims/*.claim' '.version-claims/**/*.claim')" || { echo "✗ 変更 claim を列挙できません" >&2; exit 2; }
listed_index_tree="$(index_tree_fingerprint)" || { echo "✗ 差分列挙後の index tree を確定できません" >&2; exit 2; }
[[ "$listed_index_tree" == "$initial_index_tree" ]] || { echo "✗ 検査中に index tree が変更されました。再実行してください" >&2; exit 2; }
while IFS= read -r doc; do [[ -z "$doc" ]] || validate_changed_document "$doc"; done < <(printf '%s\n' "$docs_changed")
while IFS= read -r claim_rel; do [[ -z "$claim_rel" ]] || validate_changed_claim "$claim_rel"; done < <(printf '%s\n' "$claims_changed")
final_index_tree="$(index_tree_fingerprint)" || { echo "✗ 検査終了時の index tree を確定できません" >&2; exit 2; }
[[ "$final_index_tree" == "$initial_index_tree" ]] || { echo "✗ 検査中に index tree が変更されました。再実行してください" >&2; exit 2; }
echo "✓ version claim は default branch とマージ対象 index/tree の差分に一致しています"
