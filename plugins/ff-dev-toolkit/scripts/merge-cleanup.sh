#!/usr/bin/env bash
#
# merge-cleanup.sh — PR マージ後のクリーンアップ一括実行
#
# 使い方: merge-cleanup.sh <PR番号>
#
# やること:
#   0. plugin root 固定ガード（自分の実体位置と host handoff の不一致で中断。
#      別インストール領域の実体へ切り替えて実行しないための層）
#   1. 未コミット変更ガード（あれば中断。FF_MERGE_CLEANUP_IGNORE_PATHS で
#      パスを対象外にできる）
#   2. 対象 PR の情報取得（MERGED でなければ破壊的処理の前に中断）
#   3. base ブランチへ復帰 + fetch --prune + pull --ff-only
#   3.5 ガード情報の取得（MERGED / open PR 一覧。失敗時は後続の破壊的処理を fail-closed で縮退）
#   4. 対象 PR のリモートブランチ削除（same-repo かつ open PR 未使用、--force-with-lease で OID 一致時のみ）
#   5. [gone] ローカルブランチ + 関連 worktree の削除
#      （dirty worktree は保護。-D は MERGED PR head と OID 一致するブランチのみ）
#   5.5 削除した worktree のトランスクリプト回収（cwd 照合のうえ tar.gz へアーカイブ）
#   6. リモート取り残しブランチのガード付き自動削除（fail-closed）
#   7. 最終検証と結果サマリー
#
# 終了コード:
#   0 = 完全成功 / 1 = 致命的エラーで中断 / 2 = 完了したが一部失敗・要手動対応あり（PARTIAL）
#
# 安全原則:
#   - 保護ブランチは絶対に削除しない。develop / main / master / staging/* は
#     ハードコードで、どんな設定でも外せない。release/* は既定で保護するが、
#     FF_MERGE_CLEANUP_PROTECT_BRANCHES で運用に合わせて変更できる（Issue #1056）
#   - リモート削除は --force-with-lease=<ref>:<期待OID> で行い、照合と削除の間の
#     push 競合（TOCTOU）をサーバー側で原子的に拒否させる
#   - 削除 push はコード変更を運ばないため SKIP_SIMPLE_GIT_HOOKS=1 を付ける
#     （consumer の simple-git-hooks フルゲートを起動しない）。core.hooksPath の
#     一時無効化は他の guard まで落とすので使わない
#   - ローカル [gone] ブランチの -D（強制削除）は (名前, ローカル OID) が
#     MERGED PR の head と一致する場合に限定（[gone] だけではマージ済みの証明にならない）
#   - ガードに必要な情報の取得に失敗したら削除せずスキップ（fail-closed）
#   - dirty な worktree・upstream なしの孤児ブランチは削除しない（警告のみ）
#   - 未コミット変更ガードのパス除外（FF_MERGE_CLEANUP_IGNORE_PATHS）が効くのは
#     「中断しても何も消えない」ガードだけ（Step 1 / Step 3）。worktree 削除前の
#     clean 確認（Step 5）は対象外で、除外指定があっても dirty なら削除しない
#   - base を保持する別 worktree は clean の場合だけ detached へ退避し、
#     worktree と ignored ファイルを維持する。dirty なら変更せず中断する
#   - 対象 PR のブランチを保持する linked worktree を cwd にして起動された場合は、
#     破壊的処理の前に中断する。その cwd では掃除対象である worktree 自身を削除できず、
#     base を別の worktree が保持していれば、その worktree を detached HEAD へ退避する
#     ことになる。main tree のパスが取れれば再実行コマンドを、取れない構成（bare
#     リポジトリ）では原因と対処を示す
#   - トランスクリプトの回収は「今回削除に成功した worktree の分」だけを対象にし、
#     jsonl の cwd がその worktree を指すことを照合してから処理する。既定は削除では
#     なく tar.gz へのアーカイブで、アーカイブに失敗したら元ディレクトリを残す

set -Eeuo pipefail

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
ff_assert_script_plugin_root "${BASH_SOURCE[0]}" || exit 1
# ff-dev-toolkit-script-root-guard:end
# 中断コードが契約既定の 2 ではなく 1 なのは、本スクリプトの 2 が PARTIAL
# （完了したが一部失敗）だから。ガードの停止を 2 で返すと「掃除は走った」と誤読される。

# ---- 共通 -------------------------------------------------------------------

die() {
  echo "❌ $*" >&2
  exit 1
}

# 長命な統合ブランチのハードコード保護。develop / main / master / staging/* は
# Step 4 / 5 / 6 すべての最終防壁で、どんな設定でも外せない。
is_hardcoded_protected_branch() {
  case "$1" in
    develop|main|master|staging/*) return 0 ;;
    *) return 1 ;;
  esac
}

# 設定可能な保護パターン（既定 release/*）との照合。一致したパターンを stdout へ
# 返す（報告で「どの設定に止められたか」を名指しするため）。一致しなければ非 0。
matched_extra_protect_pattern() {
  local pat=""
  [ "${#PROTECT_EXTRA_PATTERNS[@]}" -gt 0 ] || return 1
  for pat in "${PROTECT_EXTRA_PATTERNS[@]}"; do
    # 非引用はパターンとして glob を効かせる意図的な形（引用すると文字列一致に退化する）
    # shellcheck disable=SC2254
    case "$1" in
      $pat) printf '%s\n' "$pat"; return 0 ;;
    esac
  done
  return 1
}

is_protected_branch() {
  is_hardcoded_protected_branch "$1" && return 0
  matched_extra_protect_pattern "$1" >/dev/null
}

find_worktree_for_branch() {
  # $1: branch name。見つかった worktree path を stdout へ返す。
  # `git worktree list --porcelain` は path に空白があっても 1 レコード 1 行なので、
  # 人間向けの整形済み出力を split せず block 単位で読む。
  local target_ref="refs/heads/$1" worktree_path="" line=""

  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      worktree\ *)
        worktree_path="${line#worktree }"
        ;;
      branch\ "$target_ref")
        printf '%s\n' "$worktree_path"
        return 0
        ;;
    esac
  done < <(git worktree list --porcelain)

  return 1
}

resolved_dir() {
  # $1: ディレクトリ。symlink を解決した絶対パスを stdout へ返す。比較する両辺を
  # 同じ方法で正規化するために使う（片側だけ生のパスだと /var と /private/var の
  # ような symlink の差でパス比較が誤判定する）。
  local dir=""
  dir="$(cd -- "$1" 2>/dev/null && pwd -P)" || return 1
  printf '%s\n' "$dir"
}

is_linked_worktree() {
  # cwd が linked worktree（`git worktree add` で作った側）なら 0、main worktree
  # なら非 0。linked worktree では --git-dir が <common>/worktrees/<name> を指し、
  # --git-common-dir と一致しない。判定できなければ「linked ではない」に倒す
  # （案内のためのガードであり、削除可否を決める安全ガードではない）。
  local git_dir="" common_dir=""
  git_dir="$(git rev-parse --git-dir 2>/dev/null)" || return 1
  common_dir="$(git rev-parse --git-common-dir 2>/dev/null)" || return 1
  git_dir="$(resolved_dir "$git_dir")" || return 1
  common_dir="$(resolved_dir "$common_dir")" || return 1
  [ "$git_dir" != "$common_dir" ]
}

main_worktree_path() {
  # main worktree のパスを stdout へ返す。`git worktree list --porcelain` の
  # **先頭レコード**が main worktree で、linked worktree はそのあとに並ぶ。
  # bare リポジトリ（先頭レコードに `bare` 行が付く）は cd 先として案内できない
  # ので非 0 を返し、呼び出し元に「案内しない」を選ばせる。
  local line="" path="" seen=0
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      worktree\ *)
        [ "$seen" = "0" ] || break
        path="${line#worktree }"
        seen=1
        ;;
      bare)
        [ "$seen" = "1" ] || continue
        return 1
        ;;
    esac
  done < <(git worktree list --porcelain)

  [ -n "$path" ] || return 1
  printf '%s\n' "$path"
}

script_self_path() {
  # 再実行コマンドへ載せる自分自身のパス。相対起動でも main tree へ cd したあとで
  # 通用するよう絶対パスへ直す（解決できなければ起動時の値をそのまま使う）。
  local src="${BASH_SOURCE[0]}" dir=""
  case "$src" in
    /*) printf '%s\n' "$src"; return 0 ;;
  esac
  dir="$(resolved_dir "$(dirname -- "$src")")" || { printf '%s\n' "$src"; return 0; }
  printf '%s/%s\n' "$dir" "$(basename -- "$src")"
}

worktree_lock_reason() {
  # $1: worktree path。ロックされていれば理由（理由なしロックは空行）を stdout へ
  # 返して 0、未ロックなら非 0。porcelain 出力は 1 worktree = 1 ブロックで、
  # ロック行は `locked` 単独または `locked <reason>`。
  local line="" in_block=0

  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      "worktree $1") in_block=1 ;;
      worktree\ *) in_block=0 ;;
      locked)
        if [ "$in_block" = "1" ]; then
          printf '\n'
          return 0
        fi
        ;;
      locked\ *)
        if [ "$in_block" = "1" ]; then
          printf '%s\n' "${line#locked }"
          return 0
        fi
        ;;
    esac
  done < <(git worktree list --porcelain)

  return 1
}

agent_disposable_status_only() {
  # $1: `git status --porcelain` の出力（非空前提）。全行が「既知の使い捨てパスの
  # untracked」なら 0。追跡ファイルの変更・未知の untracked が 1 行でもあれば非 0。
  #
  # 使い捨てと認めるのは .review-results/ だけ（マルチ AI レビューの成果物置き場。
  # Issue #914 の実測で毎回 PARTIAL の原因だったもの）。ここを広げるほど
  # 「clean 確認してから消す」という Step 5 の原則が痩せるので、実測で困った
  # パスだけを個別に足すこと。
  local line=""
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    case "$line" in
      '?? .review-results/'*|'?? .review-results') ;;
      *) return 1 ;;
    esac
  done <<< "$1"
  return 0
}

run_git_status_porcelain() {
  # $1: worktree path（空ならカレント）/ 以降: pathspec。
  # `git -C ""` は「カレントを変えない no-op」として仕様化されている（git 2.4 以降。
  # 本スクリプトは --force-with-lease=<ref>:<OID> で既に git 2.13 以上を要求する）。
  # したがって空かどうかで分岐する必要はない。
  local worktree="$1"
  shift
  git -C "$worktree" status --porcelain "$@"
}

guard_status_error_raw() {
  # $1: stderr を退避したファイル。非空白行だけを返す（無ければ何も出さない）。
  # `cat` は空ファイルでも成功し、何も出力せずに失敗した git が改行 1 バイトだけを
  # 残すこともあるため、中身の有無は -s ではなく非空白行で見る
  # （理由は last_push_error_text と同じ）。
  awk 'NF { print }' "$1" 2>/dev/null || true
}

guard_status_error_text() {
  # $1: stderr を退避したファイル。die のメッセージへ載せる原因テキスト。
  local text=""
  text="$(guard_status_error_raw "$1")"
  [ -n "$text" ] || text='詳細不明（git が stderr へ何も出さずに失敗しました。PATH 上の git・権限・一時ディレクトリの書き込み可否を確認してください）'
  printf '%s\n' "$text"
}

guarded_status() {
  # $1: worktree path（空ならカレント）
  # 未コミット変更ガードが見る status。FF_MERGE_CLEANUP_IGNORE_PATHS に
  # 一致するパスを除外して返す。除外指定が無ければ素の status と同じ。
  #
  # 全体に一致する :(top) を先頭に置いてから除外を重ねる。除外だけの pathspec が
  # 「何も一致しない」と解釈される形を避けるための防御で、git 2.49 では除外のみでも
  # 期待どおり動くことを実測している（= この 1 語を外しても現行 git では差が出ず、
  # 回帰テストでは固定できない）。:(top) は全体一致なので意味論は変えない。
  if [ "${#IGNORE_EXCLUDE_PATHSPECS[@]}" -eq 0 ]; then
    run_git_status_porcelain "$1"
  else
    run_git_status_porcelain "$1" -- ':(top)' "${IGNORE_EXCLUDE_PATHSPECS[@]}"
  fi
}

ignored_status() {
  # $1: worktree path（空ならカレント）
  # ガード対象外にした（= 除外指定に一致した）変更だけを返す。報告用。
  # 除外後の status との差分を文字列で取らず、同じパターンの肯定形で git に引き直す。
  if [ "${#IGNORE_MATCH_PATHSPECS[@]}" -eq 0 ]; then
    return 0
  fi
  run_git_status_porcelain "$1" -- "${IGNORE_MATCH_PATHSPECS[@]}"
}

report_ignored_changes() {
  # $1: worktree path（空ならカレント）/ $2: 表示用のラベル（空可）
  # 無視した変更を件数と一覧で出す。黙って無視すると、ガードが緩んだのか
  # 本当に clean なのかが実行ログから区別できなくなる。
  local worktree="$1" label="$2" ignored="" count=0
  local err_file="$WORK_TMP/guard_status_error.ignored"
  if [ "${#IGNORE_MATCH_PATHSPECS[@]}" -eq 0 ]; then
    return 0
  fi
  if ! ignored="$(ignored_status "$worktree" 2>"$err_file")"; then
    die "無視した未コミット変更の一覧取得に失敗しました${label}: $(guard_status_error_text "$err_file")"
  fi
  if [ -z "$ignored" ]; then
    # 指定はあるのに 1 件も一致しない = パターンの書き間違いが疑わしい。黙って
    # 従来どおり中断すると、利用者からは「設定したのに何も変わらない」にしか見えない。
    echo "ℹ️ FF_MERGE_CLEANUP_IGNORE_PATHS に一致する未コミット変更はありません${label}（パターンはリポジトリルート基準の glob: '${IGNORE_RAW}'）"
    return 0
  fi
  # set -e 下では、この代入や下の出力が失敗すると理由なしで終了する。
  # 他の全経路が die にメッセージを持たせている以上、ここだけ無言にしない。
  count="$(printf '%s\n' "$ignored" | wc -l | tr -d ' ')" \
    || die "無視した未コミット変更の件数集計に失敗しました${label}"
  echo "ℹ️ ガード対象外として無視した未コミット変更: ${count} 件（FF_MERGE_CLEANUP_IGNORE_PATHS）${label}"
  printf '%s\n' "$ignored" | sed 's/^/  - /' \
    || die "無視した未コミット変更の一覧出力に失敗しました${label}"
}

resolve_dir() {
  # $1: ディレクトリ。シンボリックリンクを解決した絶対パスを stdout へ返す。
  # realpath は環境によって無いため、サブシェルの cd + pwd -P で解決する。
  ( cd "$1" 2>/dev/null && pwd -P ) || return 1
}

transcript_dir_names_for() {
  # $1: worktree の絶対パス。対応するトランスクリプトディレクトリ名の候補を
  # 1 行 1 件で出力する（重複は除去）。
  #
  # Claude Code は絶対パスを機械的にサニタイズした名前を使うが、実データ上は
  # 2 系統が併存する:
  #   A: 英数字以外をすべて '-' に潰す  … セッショントランスクリプト本体
  #      (<sessionId>.jsonl と <sessionId>/tool-results/)
  #   B: '.' と '_' は保持して残りを '-' … プラグインが書く付随データ
  #      (<plugin>/skill-injections.jsonl 等。これらは cwd を持たない)
  # 片方だけを見ると取りこぼすため、両方を候補に出す（'.' も '_' も含まない
  # パスでは 2 つが同一になるため、重複は落とす）。
  {
    printf '%s\n' "$1" | sed 's/[^a-zA-Z0-9]/-/g'
    printf '%s\n' "$1" | sed 's/[^a-zA-Z0-9._]/-/g'
  } | awk '!seen[$0]++'
}

transcript_cwd_verdict() {
  # $1: 候補ディレクトリ / $2: 許容する worktree パス（改行区切り。symlink 解決前後）
  #
  # jsonl に記録された cwd が「削除した worktree（またはその配下）」を
  # 指しているかを照合する。名前一致だけを根拠にすると /a/b-c と /a/b/c が
  # 同じ名前へ潰れて別プロジェクトの履歴を巻き込むため、証拠で確認する。
  #
  # grep は「一致 0 件」でも非 0 を返すため、終了コードでは「証拠が無い」と
  # 「証拠を読めなかった」を区別できない。stderr が空かどうかで走査エラーを
  # 判定し、取得に失敗したケースを「証拠が無い」へ降格させない
  # （降格すると、後段の名前一致だけの回収へ落ちてしまう）。
  #
  # 判定は「記録された cwd の中に、削除した worktree（またはその配下）を指すものが
  # 1 つでもあるか」で行う。セッションは途中で親リポジトリや別 worktree へ移動でき、
  # その履歴も開始時の cwd から名付けられたディレクトリに残るため、「全ての cwd が
  # worktree 配下であること」を要求すると正当なディレクトリを取りこぼす
  # （実データでは cwd を持つ 71 件中 12 件が親リポジトリ等の cwd を併せ持っていた）。
  # 名前が衝突した別プロジェクトのディレクトリには、この worktree を指す cwd が
  # 1 つも無いので、衝突の検出力は保たれる。
  #
  # 戻り値:
  #   0 = この worktree を指す cwd が見つかった
  #   2 = cwd を記録した jsonl が無い（走査自体は正常に完了した）
  #   3 = cwd はあるが、この worktree を指すものが 1 つも無い
  #   4 = 走査・読み取りでエラーが出ており、証拠を取り切れていない
  local dir="$1" allowed="$2" values="" line="" value="" base="" matched="" found=""
  local scan_err="$WORK_TMP/transcript_scan_error"
  local foreign="$WORK_TMP/transcript_foreign_cwd"

  : > "$scan_err"
  : > "$foreign"

  # 判定材料は stderr の有無に一本化する。find / grep / sort のどれが失敗しても
  # 診断は stderr に出るので、辿れないディレクトリも読めないファイルも同じ経路で
  # 拾える。終了コードは使えない（grep は一致 0 件でも非 0 を返すため、
  # 「証拠が無い」と「証拠を読めなかった」が区別できない）。
  values="$( { find "$dir" -type f -name '*.jsonl' -exec grep -oh '"cwd":"[^"]*"' {} + | sort -u ; } 2>"$scan_err" )" || true
  if [ -s "$scan_err" ]; then
    return 4
  fi
  # jsonl が 1 つも無い場合と、jsonl はあるが cwd を含まない場合は同じ扱いにする
  # （どちらも「所有者を確認できない」で、名前一致での回収経路は持たない）
  [ -n "$values" ] || return 2

  found=0
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    value="${line#\"cwd\":\"}"
    value="${value%\"}"
    matched=0
    while IFS= read -r base; do
      [ -n "$base" ] || continue
      case "$value" in
        "$base"|"$base"/*) matched=1; break ;;
      esac
    done <<< "$allowed"
    if [ "$matched" = "1" ]; then
      found=1
    else
      # 一致したものがあっても、外を指す cwd が混ざっていた事実は残す。
      # 通常はセッションが親リポジトリへ移動しただけだが、名前が衝突した
      # 別プロジェクトと同居している可能性もあり、その場合アーカイブは
      # 相手の履歴も巻き込む。黙って進めず呼び出し元に伝える。
      printf '%s\n' "$value" >> "$foreign"
    fi
  done <<< "$values"

  [ "$found" = "1" ] || return 3
  return 0
}

# temp はディレクトリ 1 つにまとめ、trap で確実に回収する
# （コマンド置換内で配列に追記する方式はサブシェルで消えるため使わない）
WORK_TMP="$(mktemp -d)" || die "mktemp -d に失敗しました"
trap 'rm -rf "$WORK_TMP"' EXIT

command -v gh >/dev/null 2>&1 || die "gh CLI が必要です（https://cli.github.com/）"
command -v jq >/dev/null 2>&1 || die "jq が必要です"

# リモート削除の共通関数: --force-with-lease で「期待 OID のときだけ」削除する。
# 削除 push はコード変更を運ばないため SKIP_SIMPLE_GIT_HOOKS=1 を付ける
# （consumer の simple-git-hooks フルゲートを起動しない）。
# core.hooksPath の一時無効化は他の guard まで落とすので使わない。
# 戻り値 0=削除 / 2=既に無い / 3=lease 拒否（競合 push あり） / 1=その他失敗
delete_remote_branch_with_lease() {
  # $1: branch / $2: expected OID
  local branch="$1" expected="$2" out="" remote_out="" remote_err="" remote_stderr="" remote_oid=""
  # エラーメッセージの文言照合があるため LC_ALL=C でロケール固定
  if out="$(LC_ALL=C SKIP_SIMPLE_GIT_HOOKS=1 git push --force-with-lease="refs/heads/$branch:$expected" \
      origin ":refs/heads/$branch" 2>&1)"; then
    return 0
  fi
  if printf '%s' "$out" | grep -qE 'remote ref does not exist'; then
    return 2
  fi
  if printf '%s' "$out" | grep -qE 'stale info|\[rejected\]'; then
    # GitHub の merge 時削除などで ref が既に無い場合も、Git は `stale info` を
    # 返すことがある。ref を再取得し、真の競合 push と削除済みを区別する。
    remote_err="$WORK_TMP/remote_recheck_error"
    if remote_out="$(LC_ALL=C git ls-remote --heads origin "refs/heads/$branch" 2>"$remote_err")"; then
      remote_stderr="$(cat "$remote_err")"
      if [ -z "$remote_out" ]; then
        return 2
      fi
      remote_oid="$(printf '%s\n' "$remote_out" | awk 'NR == 1 { print $1 }')"
      if [ "$remote_oid" != "$expected" ]; then
        printf '%s\nremote re-check:\n%s\n%s\n' \
          "$out" "$remote_out" "$remote_stderr" > "$WORK_TMP/last_push_error"
        return 3
      fi
      printf '%s\nremote re-check returned the expected OID; deletion failed for an unknown reason:\n%s\n%s\n' \
        "$out" "$remote_out" "$remote_stderr" > "$WORK_TMP/last_push_error"
      return 1
    fi
    remote_stderr="$(cat "$remote_err")"
    printf '%s\nremote re-check failed:\n%s\n' "$out" "$remote_stderr" > "$WORK_TMP/last_push_error"
    return 1
  fi
  echo "$out" > "$WORK_TMP/last_push_error"
  return 1
}

# last_push_error の読み出し。`cat` は空ファイルでも成功するため、`|| echo 詳細不明`
# では「ファイルはあるが空」で原因欠落のメッセージになる。
# サイズ検査（-s）でも足りない: 何も出力せずに失敗した push では `echo "$out"` が
# 改行 1 バイトを書くため -s を通ってしまう。中身に非空白行があるかで判定する。
last_push_error_text() {
  if awk 'NF { found = 1 } END { exit !found }' "$WORK_TMP/last_push_error" 2>/dev/null; then
    cat "$WORK_TMP/last_push_error"
  else
    echo '詳細不明'
  fi
}

# Step 6 の取り残し掃除が「Step 4 で失敗した対象 PR の head」を再試行しているか。
# 名前だけでは同名別 OID の取り残しを取り違えるため、OID も照合する。
is_pr_head_retry() {
  # $1: branch / $2: OID
  [ "$1" = "$PR_HEAD" ] && [ "$2" = "$PR_HEAD_OID" ] && [ "$PR_REMOTE_RESULT" = "failed" ]
}

# 同上だが、`headRefOid` を取得できずスキップした場合（skipped_oid_unavailable）用。
# この状態では $PR_HEAD_OID が "null" なので上の関数は恒偽になり、Step 6 が同じ
# ブランチを削除してもサマリーが「削除未実施」のまま残って自己矛盾する。
# **名前だけの照合で安全**なのは、ここへ来る $2 が Step 6 のガード 1（取り残し一覧の
# (名前, OID) 完全一致）を既に通っているため。名前が一致する時点で「その OID は
# MERGED 済み PR の head である」ことが証明済みで、削除自体も照合済み OID を
# アンカーにした --force-with-lease で行われている。取り違えの余地は残らない。
is_pr_head_retry_no_oid() {
  # $1: branch
  [ "$1" = "$PR_HEAD" ] && [ "$PR_REMOTE_RESULT" = "skipped_oid_unavailable" ]
}

# サマリーの失敗項目は 1 行 1 件なので、原因は 1 行だけを改行なしで載せる。
# 先頭行ではなく「最初の非空白行」を採る（先頭が空行でも原因を落とさないため）。
last_push_error_head() {
  local line=""
  line="$(awk 'NF { print; exit }' "$WORK_TMP/last_push_error" 2>/dev/null | tr -d '\n')"
  [ -n "$line" ] || line='詳細不明'
  printf '%s' "$line"
}

# ---- Step 0: 引数 -----------------------------------------------------------

PR_NUM="${1:-}"
if [ -z "$PR_NUM" ] || ! [[ "$PR_NUM" =~ ^[0-9]+$ ]]; then
  echo "❌ PR 番号を指定してください（例: merge-cleanup.sh 1234）" >&2
  echo "   PR 番号無しだと delete_branch_on_merge=false な repo でリモートブランチが残ります。" >&2
  exit 1
fi

REPO_ROOT="$(git rev-parse --show-toplevel)" || die "git リポジトリ内で実行してください"

# 集計用（bash 3.2 の set -u では空配列の "${arr[@]}" 展開がエラーになるため、
# 参照時は必ず ${#arr[@]} でガードする）
DELETED_BRANCHES=()
DELETED_WORKTREES=()
DELETED_WORKTREE_REALS=()
DELETED_LEFTOVERS=()
SKIPPED_LEFTOVERS=()
FAILED_ITEMS=()
# 失敗でもスキップでもない補足（Step 6 が肩代わりして解消した事象など）。
# PARTIAL の判定には数えない
INFO_ITEMS=()
ARCHIVED_TRANSCRIPTS=()
SKIPPED_TRANSCRIPTS=()
ARCHIVED_TRANSCRIPT_KB=0
ARCHIVE_TOTAL_KB=0
TRANSCRIPT_STEP_NOTE=""

# headRefOid を取得できずリモート削除をスキップしたときの失敗行。Step 4 では
# FAILED_ITEMS へ積まず、Step 6 の取り残し掃除が同じブランチを消せなかった場合だけ
# Step 8 の冒頭で積む（消せた場合は「実際には失敗が起きていない」ため補足行にする）。
PR_OID_PENDING_FAILURE=""

# ---- Step 0.5: 未コミット変更ガードのパス除外 --------------------------------
#
# 常駐ツール（chat-ui 等）が特定ディレクトリを書き続けるリポジトリでは、作業ツリーが
# dirty なのが定常状態になる。そこでは Step 1 のガードは「異常の検出」ではなく
# 「毎回必ず発火する障害」で、cleanup の実体（OID 照合・lease 削除・取り残し回収）を
# 手作業で再現させてしまう。FF_MERGE_CLEANUP_IGNORE_PATHS に一致する変更だけを
# ガードの対象外にする（既定は空 = 従来どおり全ての変更で中断）。
#
#   FF_MERGE_CLEANUP_IGNORE_PATHS='videos/**:tmp/**'   ← ':' 区切り、glob
#
# 適用先は「中断しても何も消えない」ガードだけ（Step 1 の呼び出し元 / Step 3 の
# base 所有 worktree）。worktree 削除前の clean 確認（Step 5）は対象外で、
# あちらは通すとファイルが実際に消える。

IGNORE_EXCLUDE_PATHSPECS=()
IGNORE_MATCH_PATHSPECS=()
IGNORE_RAW="${FF_MERGE_CLEANUP_IGNORE_PATHS:-}"
if [ -n "$IGNORE_RAW" ]; then
  # 末尾の空要素も検出したいので、終端の ':' を足してから 1 要素ずつ剥がす
  IGNORE_REST="${IGNORE_RAW}:"
  while [ -n "$IGNORE_REST" ]; do
    IGNORE_ITEM="${IGNORE_REST%%:*}"
    IGNORE_REST="${IGNORE_REST#*:}"
    if [ -z "$IGNORE_ITEM" ]; then
      # 空パターンは pathspec として全パスに一致するため、除外すると status が
      # 常に空になり、dirty な作業ツリーでガードが素通りする（fail-open。実測済み）。
      # 先頭に ':' を持つ pathspec magic の直書き（:(exclude)... など）もここへ落ちる。
      # 中間位置の magic（a:(exclude)b）は空要素を作らないので、下のリテラル扱いになる。
      die "FF_MERGE_CLEANUP_IGNORE_PATHS に空のパターンがあります: '${IGNORE_RAW}' — 空パターンは全パスに一致してガードを無効化します（先頭・末尾・連続する ':' を確認）。':' は区切り文字なので pathspec magic は書けません（中間に書いた場合はリテラルとして扱われ、何にも一致しません）"
    fi
    case "$IGNORE_ITEM" in
      [[:space:]]*|*[[:space:]])
        # pathspec は前後の空白も含めて照合するため、この指定は何にも一致しない。
        # 何も起きないまま従来どおり中断するので、空パターンと同じく明示的に弾く。
        die "FF_MERGE_CLEANUP_IGNORE_PATHS のパターンに前後の空白があります: '${IGNORE_ITEM}' — pathspec は空白も含めて照合するため、この指定は何にも一致しません（':' の後に空白を入れていないか確認してください）"
        ;;
    esac
    case "$IGNORE_ITEM" in
      '**'|'*'|'.'|'/')
        # 空パターンと同じく全パスへ一致する。ただし明示的に書かれた選択でもありうるので、
        # 中断はせず「ガードは事実上無効」であることを実行ログに残す
        # （無視した変更は下の一覧に全件出るため、黙って消えるわけではない）。
        echo "⚠️ FF_MERGE_CLEANUP_IGNORE_PATHS のパターン '${IGNORE_ITEM}' は全パスに一致し、未コミット変更ガードを事実上無効化します。"
        ;;
    esac
    IGNORE_EXCLUDE_PATHSPECS+=(":(exclude,glob,top)${IGNORE_ITEM}")
    IGNORE_MATCH_PATHSPECS+=(":(glob,top)${IGNORE_ITEM}")
  done
fi

# ---- Step 0.6: 設定可能な保護ブランチパターン（Issue #1056） -------------------
#
# release/* は運用によって「長命な統合ブランチ」（保護が正しい）と「リリース単位の
# 作業ブランチ」（マージ後は用済み）に二分する。名前だけで前者と決めつけると、
# 後者の運用ではマージ済み release/* が永久に取り残される。既定は従来どおり
# release/* を保護し（後方互換）、FF_MERGE_CLEANUP_PROTECT_BRANCHES で変更できる:
#
#   FF_MERGE_CLEANUP_PROTECT_BRANCHES='release/*:lts/*'  ← ':' 区切りの glob
#   FF_MERGE_CLEANUP_PROTECT_BRANCHES='none'             ← 追加の保護なし
#
# develop / main / master / staging/* はハードコードのまま（設定でも外せない。
# Step 4 / 5 / 6 すべての最終防壁のため）。空文字列は未設定と同じ（既定を使う）。

PROTECT_EXTRA_PATTERNS=()
PROTECT_RAW="${FF_MERGE_CLEANUP_PROTECT_BRANCHES:-}"
if [ -z "$PROTECT_RAW" ]; then
  PROTECT_EXTRA_PATTERNS=('release/*')
elif [ "$PROTECT_RAW" = "none" ]; then
  : # 追加の保護なし（ハードコード分だけが残る）
else
  PROTECT_REST="${PROTECT_RAW}:"
  while [ -n "$PROTECT_REST" ]; do
    PROTECT_ITEM="${PROTECT_REST%%:*}"
    PROTECT_REST="${PROTECT_REST#*:}"
    if [ -z "$PROTECT_ITEM" ]; then
      # 空パターンを黙って落とすと「書いたのに保護されない」が起き、方向は逆でも
      # IGNORE_PATHS と同じ「指定と実挙動の乖離」なので同じく中断する（fail-closed）
      die "FF_MERGE_CLEANUP_PROTECT_BRANCHES に空のパターンがあります: '${PROTECT_RAW}'（先頭・末尾・連続する ':' を確認。追加の保護を無くす場合は 'none' を指定）"
    fi
    case "$PROTECT_ITEM" in
      [[:space:]]*|*[[:space:]])
        die "FF_MERGE_CLEANUP_PROTECT_BRANCHES のパターンに前後の空白があります: '${PROTECT_ITEM}' — ブランチ名は空白も含めて照合されるため、この指定は意図どおり保護しません"
        ;;
      *\[*|*\]*)
        # release/[[:digit:]]* のような文字クラスは、クラス内の ':' が区切り文字と
        # 衝突して黙って分断される（エラーにならないまま保護が消える fail-open）。
        # 分断後の破片は往々にして「何にも一致しない」正当そうな見た目になるため、
        # 検出できるここで明示的に拒否する。
        die "FF_MERGE_CLEANUP_PROTECT_BRANCHES に文字クラス（[...]）を含むパターンがあります: '${PROTECT_ITEM}' — 文字クラスは ':' 区切りと衝突して黙って分断されるため未対応です。プレフィックス glob（release/* など）を使ってください"
        ;;
    esac
    PROTECT_EXTRA_PATTERNS+=("$PROTECT_ITEM")
  done
fi

# ---- Step 0.7: マージ済み PR 照合上限（Issue #835） ---------------------------
#
# Step 5 の -D エスカレーションと Step 6 の取り残し照合が使う MERGED 一覧の
# 取得上限。大きめのリポジトリでは既定の 1000 件でも取得が長引くため設定可能に
# する。既定は従来どおり 1000（後方互換）。不正値は破壊的処理より前に中断する。

MERGED_PR_LIMIT="${FF_MERGE_CLEANUP_MERGED_PR_LIMIT:-1000}"
if ! [[ "$MERGED_PR_LIMIT" =~ ^[1-9][0-9]*$ ]]; then
  die "FF_MERGE_CLEANUP_MERGED_PR_LIMIT は正の整数で指定してください: '${MERGED_PR_LIMIT}'（既定 1000）"
fi

# ---- Step 1: 未コミット変更ガード -------------------------------------------

# git の失敗を「変更なし」と読み替えない。ここが fail-open だと、dirty な作業ツリーで
# ガードが素通りして worktree 削除まで進む。
GUARD_ERR_STEP1="$WORK_TMP/guard_status_error.step1"
DIRTY_STATUS=""
if ! DIRTY_STATUS="$(guarded_status "" 2>"$GUARD_ERR_STEP1")"; then
  die "未コミット変更の確認に失敗しました: $(guard_status_error_text "$GUARD_ERR_STEP1")"
fi

# exit 0 でも stderr に出力があれば、作業ツリーを完全には走査できていない可能性がある
# （`warning: could not open directory …: Permission denied` は、その配下の未追跡
# ファイルを列挙できないまま exit 0 になる）。旧実装では stderr が端末へ直接出ていて
# 少なくとも目に入ったので、判定は変えずに可視性だけ戻す。
DIRTY_STATUS_STDERR="$(guard_status_error_raw "$GUARD_ERR_STEP1")"
if [ -n "$DIRTY_STATUS_STDERR" ]; then
  echo "⚠️ git status が警告を出しました（作業ツリーを完全に走査できていない可能性があります）:"
  printf '%s\n' "$DIRTY_STATUS_STDERR" | sed 's/^/   /'
fi

report_ignored_changes "" ""

# dirty での中断判定は Step 2 の後まで保留する（Issue #758 / #749）。呼び出し元が
# base でも PR head でもないブランチ（= 他セッションの作業ブランチの可能性）を
# 保持している場合、本スクリプトはブランチを一切切り替えないモードで続行するため、
# dirty でも呼び出し元の作業ツリーには触れない。base / PR head を保持している
# 場合は従来どおり中断する。どちらかは PR 情報（base / head 名）が無いと決まらない。
CALLER_DIRTY=0
if [ -n "$DIRTY_STATUS" ]; then
  CALLER_DIRTY=1
fi

# ---- Step 2: 対象 PR の情報取得（MERGED でなければここで中断） -----------------

GH_OUT=""
GH_OUT="$(gh pr view "$PR_NUM" --json headRefName,headRefOid,state,baseRefName,title,isCrossRepository 2>&1)" \
  || die "gh pr view が失敗しました: ${GH_OUT}（ネットワーク / 認証 / gh CLI 設定を確認してください）"

PR_STATE="$(printf '%s' "$GH_OUT" | jq -r '.state')"
PR_HEAD="$(printf '%s' "$GH_OUT" | jq -r '.headRefName')"
PR_HEAD_OID="$(printf '%s' "$GH_OUT" | jq -r '.headRefOid')"
PR_BASE="$(printf '%s' "$GH_OUT" | jq -r '.baseRefName')"
PR_TITLE="$(printf '%s' "$GH_OUT" | jq -r '.title')"
PR_CROSS_REPO="$(printf '%s' "$GH_OUT" | jq -r '.isCrossRepository')"

[ -n "$PR_HEAD" ] && [ "$PR_HEAD" != "null" ] || die "PR #$PR_NUM の headRefName が取得できません: $GH_OUT"
[ -n "$PR_BASE" ] && [ "$PR_BASE" != "null" ] || die "PR #$PR_NUM の baseRefName が取得できません: $GH_OUT"

# headRefOid は Step 4 の --force-with-lease のアンカー。未検証のまま渡すと
# 「権限 / ネットワーク / ブランチ保護ルールを確認」という的外れな案内になる（真因は
# 「照合すべき OID が無い」ことで、どの選択肢にも含まれない）。壊れ方は 2 通りで、
# 実際に来るのは前者だけ:
#   - "null": jq -r が JSON null を文字列化した値。git が object name として解析できず
#     push は `stale info` にも `remote ref does not exist` にもマッチせず rc=1 になる
#   - 空文字列: --force-with-lease=<ref>: は「ref は存在しないはず」という別の意味に
#     なり、lease 拒否（= マージ後 push あり）として誤報される。jq -r が空を返す経路は
#     無いので実質到達不能だが、保険で同じ扱いにする
# ここでは die しない — 名前 / base と違い、これが欠けても止まるのは Step 4 の
# リモート削除だけで、[gone] 掃除・トランスクリプト回収・取り残し検証は成立する。
# Step 4 で `skipped_guard_unavailable` と同じ「ガード情報が構成できない → 削除だけ
# スキップして PARTIAL で続行」へ落とす（判断軸は ACE-166-1）。
PR_HEAD_OID_OK=1
if [ -z "$PR_HEAD_OID" ] || [ "$PR_HEAD_OID" = "null" ]; then
  PR_HEAD_OID_OK=0
fi

if [ "$PR_STATE" != "MERGED" ]; then
  die "PR #$PR_NUM は $PR_STATE 状態です（MERGED ではない）。番号の誤りの可能性があるため、破壊的処理に入る前に中断します。"
fi

if is_protected_branch "$PR_HEAD"; then
  die "PR #$PR_NUM のヘッドブランチが保護対象です ($PR_HEAD)。誤操作防止のため中断します。"
fi

# ---- Step 2.5: 呼び出し元ブランチの判定（switch なし掃除モード。#758 / #749） ---
#
# 呼び出し元が base でも PR head でもない名前付きブランチにいる場合、そのブランチは
# 他セッションの作業ブランチの可能性がある。Step 3 で base へ switch すると他人の
# 作業を勝手に切り替えることになるため、**切り替えを伴わない掃除モード**へ落とす:
#   - base への復帰・pull は行わない（base の最新化は checkout 不要な
#     `git fetch origin <base>:<base>` を試み、拒否されたらスキップして報告）
#   - リモート削除・[gone] 掃除・worktree 削除・取り残し検証は通常どおり実施
#   - 未実施の項目はサマリーで名指しする
# detached HEAD（空文字列）は従来どおり通常モード（switch して base へ復帰する）。

CURRENT_BRANCH_BEFORE="$(git branch --show-current)"
NO_SWITCH_MODE=0
BASE_FF_NOTE=""
if [ -n "$CURRENT_BRANCH_BEFORE" ] \
  && [ "$CURRENT_BRANCH_BEFORE" != "$PR_BASE" ] \
  && [ "$CURRENT_BRANCH_BEFORE" != "$PR_HEAD" ]; then
  NO_SWITCH_MODE=1
fi

# ---- Step 2.6: 対象 PR の worktree を cwd にした起動の検出 --------------------
#
# マージ直後に PR の worktree のまま cleanup を呼ぶ動線がある。この cwd では
# 本スクリプトの主目的が 2 つとも達成できない:
#   - 掃除対象であるこの worktree 自身は、そこに立っている以上 Step 5 で削除できない
#   - base を別の worktree（多くは main tree）が保持していれば、Step 3 が base を
#     取り戻すにはその worktree を detached HEAD へ退避することになる（呼び出し元を
#     優先して他方の checkout を崩す）。base を誰も保持していなければこちらは起きない
#     ので、案内では実際に保持している worktree を見つけたときだけ言及する
# 前者だけでも「気付きにくい未完了」に化けるため、破壊的処理へ入る前に止める。
# 案内は main tree のパスが取れれば再実行コマンド、取れない構成（bare リポジトリ）
# では原因と対処を出す。パスが取れないことを理由に素通しはしない。
#
# 検出は「cwd が linked worktree」かつ「その worktree が対象 PR の head を保持」に
# 限る。linked worktree からの実行そのものは正当な運用で、
#   - base でも PR head でもないブランチ = 切り替えを伴わない掃除モード（下記）
#   - detached / base 保持 = 従来どおり通常モード
# はいずれも完走できる。ここを「linked worktree なら一律中断」へ広げると、
# それらの経路まで巻き添えで止まる。
IN_PR_WORKTREE=0
MAIN_WORKTREE=""
PR_BASE_WORKTREE=""
if [ "$CURRENT_BRANCH_BEFORE" = "$PR_HEAD" ] && is_linked_worktree; then
  IN_PR_WORKTREE=1
  # main tree のパスは「どこでやり直せばよいか」の案内にだけ使う。取れなくても
  # （bare リポジトリの main レコードは cd 先にできない）中断は取り消さない。
  # ここを素通しさせると、下の 2 つの未完了を黙ったまま破壊的処理へ進むことになる。
  MAIN_WORKTREE="$(main_worktree_path || true)"
  PR_BASE_WORKTREE="$(find_worktree_for_branch "$PR_BASE" || true)"
fi
if [ "$IN_PR_WORKTREE" = "1" ]; then
  echo "❌ 対象 PR のワークツリーを cwd にして実行しています: ${REPO_ROOT}"
  echo "   このまま続けると、掃除対象であるこのワークツリー自身は削除できません。"
  if [ -n "$PR_BASE_WORKTREE" ]; then
    echo "   さらに base (${PR_BASE}) を別のワークツリー (${PR_BASE_WORKTREE}) が保持しているため、"
    echo "   base へ復帰するにはそのワークツリーを detached HEAD へ退避することになります。"
  fi
  echo "   破壊的処理の前に中断します（リモートブランチ・ローカルブランチ・worktree は何も削除していません）。"
  echo ""
  if [ -n "$MAIN_WORKTREE" ]; then
    echo "main tree で実行し直してください:"
    # パスに空白等が含まれていてもそのまま貼って実行できるよう %q で引用する。
    printf '  cd %q && bash %q %s\n' "$MAIN_WORKTREE" "$(script_self_path)" "$PR_NUM"
  else
    echo "別のワークツリーで実行し直してください（main tree のパスを特定できませんでした）:"
    echo "  原因: cwd が対象 PR のブランチ (${PR_HEAD}) を保持するリンクされたワークツリーです。"
    echo "  対処: bare リポジトリなど main tree が checkout を持たない構成のため、"
    echo "        'git worktree list' で対象 PR のブランチを保持しない作業ツリーを選び、そこで実行してください。"
  fi
  exit 1
fi

if [ "$CALLER_DIRTY" = "1" ]; then
  if [ "$NO_SWITCH_MODE" = "1" ]; then
    # このモードでは呼び出し元のブランチも作業ツリーも一切触らないため、dirty を
    # 理由に全体を止めない（止めると cleanup の実体を毎回手作業で再現することになる。
    # #749 の実測）。変更に触れないことと、base 復帰を行わないことだけ明示する。
    echo "⚠️ 未コミットの変更がありますが、呼び出し元は base でも PR head でもない '${CURRENT_BRANCH_BEFORE}' を保持しています。"
    echo "   ブランチ切り替えを伴わない掃除モードで続行します（下の変更には一切触れません）:"
    printf '%s\n' "$DIRTY_STATUS" | sed 's/^/   /'
  else
    echo "❌ 未コミットの変更があります。cleanup を中断します。"
    printf '%s\n' "$DIRTY_STATUS"
    echo ""
    echo "対応方針（ユーザーが分類して判断）:"
    echo "  1. 作業ブランチで commit し損ねた変更 → 元ブランチに戻して commit / 別 PR 化"
    echo "  2. ツール / 設定（.claude/, scripts/ 等） → chore PR or .gitignore 追記"
    echo "  3. ビルド成果物（dist/, .next/, target/, node_modules/） → .gitignore 追記提案"
    echo "勝手に git restore / git clean は実行しません。"
    if [ -z "$IGNORE_RAW" ]; then
      echo "常駐ツールが書き続けるパスなら FF_MERGE_CLEANUP_IGNORE_PATHS で対象外にできます。"
    else
      # 設定済みの利用者に「設定できます」と案内すると、効いていないのかと読める
      echo "現在の FF_MERGE_CLEANUP_IGNORE_PATHS: '${IGNORE_RAW}' — 上の変更はこの指定に一致していません。"
    fi
    exit 1
  fi
fi

# ---- Step 2.7: optional pre-merge-cleanup hook -------------------------------

HOOK="$REPO_ROOT/.claude/hooks/pre-merge-cleanup.sh"
if [ -f "$HOOK" ]; then
  if [ -x "$HOOK" ]; then
    echo "▶ running $HOOK"
    "$HOOK" || die "pre-merge-cleanup hook が失敗しました。cleanup を中断します。"
    if [ "$NO_SWITCH_MODE" = "1" ]; then
      # switch なし掃除モードの契約は「呼び出し元のブランチに触れない」。hook が
      # ブランチを切り替えていたら、この契約を以降のステップで守れないため中断する
      HOOK_BRANCH_NOW="$(git branch --show-current)"
      if [ "$HOOK_BRANCH_NOW" != "$CURRENT_BRANCH_BEFORE" ]; then
        die "pre-merge-cleanup hook が呼び出し元のブランチを '${CURRENT_BRANCH_BEFORE}' から '${HOOK_BRANCH_NOW:-（detached）}' へ切り替えました。switch なし掃除モードの契約（呼び出し元のブランチに触れない）を守れないため中断します。hook を修正するか、base か PR head のブランチから再実行してください。"
      fi
    fi
  else
    echo "⚠️ $HOOK は実行可能ではありません（chmod +x してください）。スキップします。"
  fi
fi

# ---- Step 3: base ブランチ復帰 + 最新化（prune 必須） -------------------------

# リモートブランチ削除より先に base を最新化すること。
# --prune が無いとリモート削除済みブランチに [gone] マーカーが付かず Step 5 で検出できない。

BASE_WORKTREE=""
BASE_WORKTREE_OID=""
BASE_WORKTREE_DETACHED=0

if [ "$NO_SWITCH_MODE" = "1" ]; then
  echo "ℹ️ 呼び出し元は '${CURRENT_BRANCH_BEFORE}' を保持しています（base=${PR_BASE} / PR head=${PR_HEAD} のいずれでもありません）。"
  echo "   他セッションの作業ブランチを切り替えないため、base への復帰・pull を行わない掃除モードで続行します。"

  # base を保持する worktree があれば報告だけする（detach も削除もしない。#758:
  # 他セッションの worktree は保持者パス・clean/dirty・最終更新を報告し、処分は
  # ユーザー判断に委ねる）。
  BASE_WORKTREE="$(find_worktree_for_branch "$PR_BASE" || true)"
  if [ -n "$BASE_WORKTREE" ]; then
    BASE_HOLDER_STATE="clean"
    if [ -n "$(git -C "$BASE_WORKTREE" status --porcelain 2>/dev/null)" ]; then
      BASE_HOLDER_STATE="dirty"
    fi
    BASE_HOLDER_LAST="$(git -C "$BASE_WORKTREE" log -1 --format='%cd' --date=iso 2>/dev/null || true)"
    echo "ℹ️ ${PR_BASE} は別の worktree が保持しています（削除も切り替えもしません。処分はユーザー判断）:"
    echo "   保持者: ${BASE_WORKTREE}（${BASE_HOLDER_STATE} / 最終コミット: ${BASE_HOLDER_LAST:-不明}）"
  fi

  git fetch --prune origin 2>&1 \
    || die "git fetch --prune が失敗しました。ネットワーク / 認証を確認してください。"

  # checkout せずに base を最新化できるなら行う。base がどこかの worktree に
  # checkout されていると git 自身が拒否する（#749 の実測）ので、その場合は
  # スキップして報告する（サマリーの未実施項目にも載せる）。
  BASE_FF_OUT=""
  if BASE_FF_OUT="$(git fetch origin "$PR_BASE:$PR_BASE" 2>&1)"; then
    BASE_FF_NOTE="実施済み（git fetch origin ${PR_BASE}:${PR_BASE} で checkout せずに更新）"
    echo "ℹ️ ${PR_BASE} は checkout せずに最新化しました（git fetch origin ${PR_BASE}:${PR_BASE}）。"
  else
    BASE_FF_NOTE="未実施（git fetch origin ${PR_BASE}:${PR_BASE} が拒否された。base を保持する worktree 側で pull すること）"
    echo "ℹ️ ${PR_BASE} の checkout なし最新化はできませんでした（base を保持する worktree 側で pull してください）:"
    printf '%s\n' "$BASE_FF_OUT" | sed 's/^/   /'
  fi
fi

if [ "$NO_SWITCH_MODE" != "1" ] && [ "$CURRENT_BRANCH_BEFORE" != "$PR_BASE" ]; then
  BASE_WORKTREE="$(find_worktree_for_branch "$PR_BASE" || true)"
fi

if [ "$NO_SWITCH_MODE" != "1" ] && [ -n "$BASE_WORKTREE" ] && [ "$BASE_WORKTREE" != "$REPO_ROOT" ]; then
  # ここも Step 1 と同じ除外指定を効かせる。退避は同一 OID への detach なので
  # 作業ツリーの中身は変わらず、中断しても何も消えない側のガードにあたる。
  # 片方だけ緩めると、除外を設定したユーザーが別の dirty ガードで止まる。
  GUARD_ERR_STEP3="$WORK_TMP/guard_status_error.step3"
  BASE_WORKTREE_STATUS=""
  if ! BASE_WORKTREE_STATUS="$(guarded_status "$BASE_WORKTREE" 2>"$GUARD_ERR_STEP3")"; then
    die "$PR_BASE を保持する worktree の状態取得に失敗しました: $BASE_WORKTREE — $(guard_status_error_text "$GUARD_ERR_STEP3")"
  fi

  # 旧実装は 2>&1 で stderr を status 出力へ合流させており、exit 0 でも警告が出れば
  # 「非空 = dirty」とみなして中断していた（メッセージは的外れだが fail-closed）。
  # stderr を分離するとその判定が消えるので、明示的に戻す。走査が不完全なまま
  # detach → リモート削除 → worktree 削除へ進ませない（Step 5 の clean 確認が
  # 2>&1 のままなのと同じ安全等級を保つ）。
  BASE_WORKTREE_STDERR="$(guard_status_error_raw "$GUARD_ERR_STEP3")"
  if [ -n "$BASE_WORKTREE_STDERR" ]; then
    echo "❌ $PR_BASE を保持する worktree の status が警告を出しました: $BASE_WORKTREE"
    printf '%s\n' "$BASE_WORKTREE_STDERR" | sed 's/^/   /'
    die "作業ツリーを完全に走査できていない可能性があるため中断します（権限・マウント状態を確認してください）。"
  fi

  report_ignored_changes "$BASE_WORKTREE" "（${BASE_WORKTREE}）"

  if [ -n "$BASE_WORKTREE_STATUS" ]; then
    echo "❌ $PR_BASE を保持する別 worktree に未コミット変更があります: $BASE_WORKTREE"
    printf '%s\n' "$BASE_WORKTREE_STATUS"
    die "変更を保護するため、base ブランチの退避と cleanup を中断します。"
  fi

  BASE_WORKTREE_OID="$(git -C "$BASE_WORKTREE" rev-parse HEAD 2>&1)" \
    || die "$PR_BASE を保持する worktree の HEAD 取得に失敗しました: $BASE_WORKTREE — $BASE_WORKTREE_OID"

  echo "ℹ️ $PR_BASE は別の clean worktree が保持しています。worktree を残して detached へ退避します:"
  echo "   $BASE_WORKTREE ($BASE_WORKTREE_OID)"
  git -C "$BASE_WORKTREE" switch --detach "$BASE_WORKTREE_OID" 2>&1 \
    || die "$PR_BASE を保持する worktree の detached 退避に失敗しました: $BASE_WORKTREE"
  BASE_WORKTREE_DETACHED=1
fi

if [ "$NO_SWITCH_MODE" != "1" ]; then
  SWITCH_OUT=""
  if ! SWITCH_OUT="$(git switch "$PR_BASE" 2>&1)"; then
    if [ "$BASE_WORKTREE_DETACHED" = "1" ]; then
      if git -C "$BASE_WORKTREE" switch "$PR_BASE" >/dev/null 2>&1; then
        echo "ℹ️ 呼び出し元の切り替え失敗に伴い、退避した worktree を $PR_BASE へ復旧しました。" >&2
      else
        die "$PR_BASE への切り替えに失敗し、退避した worktree の復旧にも失敗しました: ${SWITCH_OUT}（要手動確認: ${BASE_WORKTREE}）"
      fi
    fi
    die "$PR_BASE への切り替えに失敗しました: ${SWITCH_OUT}（'git worktree list' / 'git branch -a' を確認）。"
  fi
  printf '%s\n' "$SWITCH_OUT"

  git fetch --prune origin 2>&1 \
    || die "git fetch --prune が失敗しました。ネットワーク / 認証を確認してください。"

  git pull --ff-only origin "$PR_BASE" 2>&1 \
    || die "git pull --ff-only が失敗しました。$PR_BASE がローカルで分岐しているか、未コミット変更（FF_MERGE_CLEANUP_IGNORE_PATHS で除外したものを含む）が更新と競合しています（'git log $PR_BASE..origin/$PR_BASE' と 'git status' で確認し手動解消してください）。"
fi

# ---- Step 3.5: ガード情報の取得（Step 4/5/6 で共用、fail-closed） --------------

# MERGED 一覧: -D エスカレーション（Step 5）と取り残し照合（Step 6）の根拠
# open 一覧:   「同じ head を open PR が再利用していないか」ガード（Step 4/6）
GUARDS_OK=1
MERGED_LIST="$WORK_TMP/merged.list"   # "name<TAB>oid"（same-repo PR のみ）
OPEN_LIST="$WORK_TMP/open.list"       # "name"

# 大きめのリポジトリではこの取得が数分かかることがある（feelflow-website-2026 の
# 実測。Issue #835）。無出力のまま待たせると「ハング」と誤診されるため、取得の
# 前後で進捗を出す。上限は FF_MERGE_CLEANUP_MERGED_PR_LIMIT（Step 0.7、既定 1000）。
GH_MERGED_JSON=""
GH_OPEN_JSON=""
echo "⏳ ガード情報を取得しています: マージ済み PR 一覧（照合上限: ${MERGED_PR_LIMIT} 件）..."
if ! GH_MERGED_JSON="$(gh pr list --state merged --limit "$MERGED_PR_LIMIT" --json headRefName,headRefOid,isCrossRepository 2>&1)"; then
  echo "⚠️ マージ済み PR 一覧の取得に失敗しました（fail-closed で縮退）: $GH_MERGED_JSON"
  GUARDS_OK=0
else
  MERGED_FETCHED_COUNT="$(printf '%s' "$GH_MERGED_JSON" | jq 'length' 2>/dev/null)" || MERGED_FETCHED_COUNT=""
  echo "   … マージ済み PR 一覧を取得しました: ${MERGED_FETCHED_COUNT:-?} 件"
  if [ -n "$MERGED_FETCHED_COUNT" ] && [ "$MERGED_FETCHED_COUNT" -ge "$MERGED_PR_LIMIT" ]; then
    echo "ℹ️ マージ済み PR の照合は上限 ${MERGED_PR_LIMIT} 件で打ち切っています（これより古い MERGED PR は照合対象外。上限は FF_MERGE_CLEANUP_MERGED_PR_LIMIT で変更できます）"
  fi
  echo "⏳ ガード情報を取得しています: open PR 一覧..."
  if ! GH_OPEN_JSON="$(gh pr list --state open --limit 1000 --json headRefName 2>&1)"; then
    echo "⚠️ open PR 一覧の取得に失敗しました（fail-closed で縮退）: $GH_OPEN_JSON"
    GUARDS_OK=0
  else
    echo "   … open PR 一覧を取得しました"
    printf '%s' "$GH_MERGED_JSON" \
      | jq -r '.[] | select(.isCrossRepository | not) | "\(.headRefName)\t\(.headRefOid)"' \
      | sort -u > "$MERGED_LIST"
    printf '%s' "$GH_OPEN_JSON" | jq -r '.[].headRefName' | sort -u > "$OPEN_LIST"
  fi
fi

# ---- Step 4: 対象 PR のリモートブランチ削除 -----------------------------------

PR_REMOTE_RESULT="skipped"

if [ "$PR_CROSS_REPO" = "true" ]; then
  # fork PR の head は fork 側にある。origin の同名ブランチは別物の可能性があるため触らない
  echo "ℹ️  PR #$PR_NUM は fork からの PR です。origin 側のブランチ削除はスキップします。"
  PR_REMOTE_RESULT="skipped_fork"
elif [ "$GUARDS_OK" != "1" ]; then
  echo "⚠️ open PR ガードを構成できないため、対象 PR のリモートブランチ削除をスキップします（fail-closed）。"
  PR_REMOTE_RESULT="skipped_guard_unavailable"
  FAILED_ITEMS+=("$PR_HEAD: ガード情報取得失敗によりリモート削除未実施")
elif grep -qxF "$PR_HEAD" "$OPEN_LIST"; then
  echo "⚠️ $PR_HEAD は別の open PR の head として使用中です。リモート削除をスキップします。"
  PR_REMOTE_RESULT="skipped_open_reuse"
  SKIPPED_LEFTOVERS+=("$PR_HEAD: open PR の head として使用中")
elif [ "$PR_HEAD_OID_OK" != "1" ]; then
  # open PR ガードの後に置く。open PR で再利用中なら削除しないこと自体は正常系で、
  # OID が無いことを失敗として重ねると余計な PARTIAL になる。
  #
  # 削除を諦める前に ref の実在だけは確かめる。GitHub の merge 時削除などで
  # 既に消えている場合、「削除未実施」を積むと**毎回 PARTIAL が出続ける**
  # （消すものが無いので何度実行しても解消しない）。
  # --exit-code は「ref なし」を 2 で返す。通信・認証の失敗（128 等）と区別し、
  # 後者は「消えている」と断定せず fail-closed で失敗として扱う。
  PR_HEAD_LSREMOTE_ERR="$WORK_TMP/pr_head_lsremote_error"
  PR_HEAD_LSREMOTE_OUT=""
  set +e
  PR_HEAD_LSREMOTE_OUT="$(LC_ALL=C git ls-remote --exit-code --heads origin "refs/heads/$PR_HEAD" 2>"$PR_HEAD_LSREMOTE_ERR")"
  PR_HEAD_LSREMOTE_RC=$?
  set -e
  PR_REMOTE_RESULT="skipped_oid_unavailable"
  case "$PR_HEAD_LSREMOTE_RC" in
    0)
      PR_HEAD_REMOTE_OID="$(printf '%s\n' "$PR_HEAD_LSREMOTE_OUT" | awk 'NR == 1 { print $1 }')"
      echo "⚠️ PR #$PR_NUM の headRefOid を取得できませんでした（gh pr view の応答が null）。--force-with-lease の照合対象が無いため、リモートブランチ削除をスキップします（fail-closed）。"
      echo "   origin には $PR_HEAD が残っています（現在の OID: ${PR_HEAD_REMOTE_OID}）。"
      # 無条件の `push --delete` は案内しない。この時点で「その ref が対象 PR の
      # head である」ことは誰も確認していないため、確認と削除の間に入った push や
      # 同名ブランチの再利用ごと消してしまう。人間が OID を照合したうえで、
      # 照合した OID を lease に載せる形だけを案内する。
      echo "   復旧手順: 1) 上の OID が PR #$PR_NUM の head であることを PR ページ / コミット履歴で確認する"
      echo "             2) 確認できたら: git push origin --force-with-lease=refs/heads/$PR_HEAD:${PR_HEAD_REMOTE_OID} :refs/heads/$PR_HEAD"
      echo "             3) 確認できなければ削除しない（別の作業が push している可能性がある）"
      echo "             4) 削除できたら merge-cleanup を再実行してローカル資産を掃除する"
      # ここでは FAILED_ITEMS へ積まない。Step 6 の取り残し掃除が同じブランチを
      # （一覧側の正常な OID をアンカーに）消せる場合があり、その場合は実際の失敗が
      # 起きていないため。消せなかった場合だけ Step 8 の冒頭で失敗として積む。
      PR_OID_PENDING_FAILURE="$PR_HEAD: headRefOid を取得できずリモート削除未実施 — origin の現 OID ${PR_HEAD_REMOTE_OID} が PR #$PR_NUM の head だと確認できた場合のみ 'git push origin --force-with-lease=refs/heads/$PR_HEAD:${PR_HEAD_REMOTE_OID} :refs/heads/$PR_HEAD' で削除し merge-cleanup を再実行（確認できない場合は削除しない）"
      ;;
    2)
      # ref が無い = 削除すべきものが無い。失敗ではないので積まない
      echo "ℹ️  PR #$PR_NUM の headRefOid は取得できませんでしたが、origin に $PR_HEAD は既にありません（削除不要）。"
      PR_REMOTE_RESULT="already_missing"
      INFO_ITEMS+=("$PR_HEAD: headRefOid は gh pr view から取得できなかったが、origin 上の ref は既に存在しない")
      ;;
    *)
      echo "⚠️ PR #$PR_NUM の headRefOid を取得できず、origin 上の $PR_HEAD の実在確認にも失敗しました。リモートブランチ削除をスキップします（fail-closed）: $(cat "$PR_HEAD_LSREMOTE_ERR")"
      PR_OID_PENDING_FAILURE="$PR_HEAD: headRefOid の取得と ref の実在確認がどちらも失敗しリモート削除未実施 — ネットワーク / 認証を確認して merge-cleanup を再実行（実在と OID を確認できるまで削除しない）"
      ;;
  esac
else
  echo "🗑️  リモートブランチ削除: $PR_HEAD (PR #$PR_NUM: $PR_TITLE)"
  set +e
  delete_remote_branch_with_lease "$PR_HEAD" "$PR_HEAD_OID"
  rc=$?
  set -e
  case "$rc" in
    0)
      echo "  ✓ removed: $PR_HEAD"
      PR_REMOTE_RESULT="deleted"
      ;;
    2)
      echo "  ℹ️  リモートブランチは既に削除されていました（続行）"
      PR_REMOTE_RESULT="already_missing"
      ;;
    3)
      echo "  ⚠️ $PR_HEAD はマージ後に更新されています（lease 拒否 = 新しい push あり）。削除をスキップします。"
      PR_REMOTE_RESULT="skipped_lease_rejected"
      SKIPPED_LEFTOVERS+=("$PR_HEAD: マージ後 push あり（lease 拒否）")
      ;;
    *)
      # 削除できなかったこと自体は Step 5 以降の掃除と独立している。ここで die すると
      # 一過性のネットワーク断で [gone] ブランチ削除・トランスクリプト回収・取り残し
      # 掃除・最終検証が丸ごと未実施のまま終わるため、Step 6 と同じく失敗として記録し
      # PARTIAL で続行する（削除していない点は変わらない = 保護は維持）。
      echo "  ❌ リモートブランチ削除に失敗しました: $(last_push_error_text)（権限 / ネットワーク / ブランチ保護ルールを確認）"
      PR_REMOTE_RESULT="failed"
      # 原因をサマリーまで運ぶ。従来は die のメッセージが最終行に出ていたが、続行に
      # したことで診断行とサマリーの間に Step 5〜7 の出力が挟まるため。
      FAILED_ITEMS+=("$PR_HEAD: リモート削除失敗（$(last_push_error_head)）")
      ;;
  esac
fi

# 削除を反映して [gone] マーカーを付ける。
# ここで die すると、リモート削除の失敗で掃除全体を止めないという上の判断が 2 行先で
# 破れる（rc=1 の主要因であるネットワーク断は、この fetch も同時に失敗させる）。
# 失敗しても安全側にしか外れない: ref は Step 3 の fetch 時点まで新しく、prune が
# 飛ぶと「消えたはずのブランチが [gone] に見えない」= 処理対象が減るだけ。Step 5 の
# -D は MERGED PR との (名前, OID) 照合を維持し、Step 6 は自前の ls-remote で判定する。
git fetch --prune origin 2>&1 || {
  echo "⚠️ 削除反映の fetch --prune が失敗しました。[gone] 判定が不完全な可能性があります。"
  FAILED_ITEMS+=("削除反映の fetch --prune 失敗: [gone] 検出が不完全な可能性")
}

# ---- Step 5: [gone] ブランチ + 関連 worktree の削除 ---------------------------

# grep は「マッチ 0 件」で exit 1 を返すが、[gone] ゼロ件は正常系なので || true で許容する
GONE_BRANCHES="$(git for-each-ref \
  --format='%(if:equals=[gone])%(upstream:track)%(then)%(refname:short)%(end)' \
  refs/heads/ | grep -v '^$' || true)"

if [ -z "$GONE_BRANCHES" ]; then
  echo "✅ [gone] ブランチはありません。"
else
  echo "🧹 [gone] ブランチを処理します:"
  printf '%s\n' "$GONE_BRANCHES" | sed 's/^/  - /'

  # switch なし掃除モードでは呼び出し元のブランチが [gone] のこともある。checkout 中の
  # ブランチは git 自身が削除を拒否するが、失敗（PARTIAL）ではなく名指しのスキップにする
  CURRENT_BRANCH_STEP5="$(git branch --show-current)"

  while IFS= read -r branch; do
    [ -z "$branch" ] && continue
    echo ""
    echo "=== Processing: $branch ==="

    # [gone] に保護ブランチが現れるのは異常系だが、絶対に削除しない
    if is_protected_branch "$branch"; then
      echo "  ⚠️ skip (保護ブランチ): $branch"
      SKIPPED_LEFTOVERS+=("$branch: 保護ブランチ（ローカル [gone]）")
      continue
    fi

    if [ -n "$CURRENT_BRANCH_STEP5" ] && [ "$branch" = "$CURRENT_BRANCH_STEP5" ]; then
      echo "  ⚠️ skip (呼び出し元がチェックアウト中): $branch"
      SKIPPED_LEFTOVERS+=("$branch: 呼び出し元がチェックアウト中のためローカル削除せず")
      continue
    fi

    # worktree path を porcelain 出力から抽出（スペース含むパスにも対応）
    WORKTREE_PATH=""
    current_wt=""
    while IFS= read -r line; do
      case "$line" in
        "worktree "*) current_wt="${line#worktree }" ;;
        "branch refs/heads/$branch") WORKTREE_PATH="$current_wt"; break ;;
      esac
    done < <(git worktree list --porcelain)

    # optional post-branch-cleanup hook（DDEV stop など project 固有処理の差し込みポイント）
    HOOK="$REPO_ROOT/.claude/hooks/post-branch-cleanup.sh"
    if [ -f "$HOOK" ] && [ -x "$HOOK" ]; then
      echo "▶ running $HOOK ($branch)"
      if ! BRANCH="$branch" WORKTREE_PATH="$WORKTREE_PATH" "$HOOK"; then
        echo "  ⚠️ post-branch-cleanup hook が失敗。次のブランチへ進みます。"
        FAILED_ITEMS+=("$branch: post-branch-cleanup hook 失敗")
        continue
      fi
    elif [ -f "$HOOK" ]; then
      echo "  ⚠️ $HOOK は実行可能ではありません（chmod +x してください）。スキップします。"
    fi

    if [ -n "$WORKTREE_PATH" ] && [ "$WORKTREE_PATH" != "$REPO_ROOT" ]; then
      # dirty な worktree は削除しない（未コミット変更を握りつぶさない）
      WT_STATUS="$(git -C "$WORKTREE_PATH" status --porcelain 2>&1)" || {
        echo "  ❌ worktree の状態確認に失敗: $WT_STATUS"
        FAILED_ITEMS+=("$branch: worktree 状態確認失敗 ($WORKTREE_PATH)")
        continue
      }

      # マージ済みエージェント worktree の自動処理（Issue #914）。
      # サブエージェント並列開発の worktree はハーネスのロック（reason: claude agent）と
      # untracked の .review-results で毎回削除に失敗し、unlock → force remove の手動
      # 3 手を要して常に PARTIAL になっていた。次の **3 条件をすべて**満たす場合に限り
      # unlock + 使い捨てパスの除去 + 削除を自動で行う:
      #   1. (名前, ローカル OID) が MERGED PR の head と一致（-D エスカレーションと同じ証拠）
      #   2. ロックされていて、ロック理由に claude agent を含む（未ロックは対象外）
      #   3. dirty の内訳が既知の使い捨てパス（.review-results）の untracked だけ（clean も可）
      # 証拠が欠ける・未知の残置物がある・ロックが無い/理由が異なる場合は
      # 従来どおり削除せず保護する（fail-closed）。
      WT_LOCAL_OID="$(git rev-parse "refs/heads/$branch" 2>/dev/null || true)"
      WT_MERGED_MATCH=0
      if [ "$GUARDS_OK" = "1" ] && [ -n "$WT_LOCAL_OID" ] \
        && grep -qxF "$(printf '%s\t%s' "$branch" "$WT_LOCAL_OID")" "$MERGED_LIST"; then
        WT_MERGED_MATCH=1
      fi

      WT_LOCK_REASON=""
      WT_LOCKED=0
      if WT_LOCK_REASON="$(worktree_lock_reason "$WORKTREE_PATH")"; then
        WT_LOCKED=1
      fi
      WT_CLAUDE_LOCK=0
      if [ "$WT_LOCKED" = "1" ] && printf '%s' "$WT_LOCK_REASON" | grep -qi 'claude agent'; then
        WT_CLAUDE_LOCK=1
      fi

      WT_AGENT_PATH=0
      if [ "$WT_MERGED_MATCH" = "1" ] && [ "$WT_CLAUDE_LOCK" = "1" ] \
        && { [ -z "$WT_STATUS" ] || agent_disposable_status_only "$WT_STATUS"; }; then
        WT_AGENT_PATH=1
      fi

      # claude agent 以外のロックは、dirty かどうかによらずロックを理由に保護する
      # （ロックがある限り削除は成立せず、真の障害物はロックのため）
      if [ "$WT_LOCKED" = "1" ] && [ "$WT_CLAUDE_LOCK" != "1" ]; then
        echo "  ⚠️ worktree がロックされています（理由: ${WT_LOCK_REASON:-（記載なし）}）。削除をスキップします。"
        echo "     自動 unlock するのは「ロック理由が claude agent かつ (名前, OID) が MERGED PR の head と一致」の場合だけです。"
        FAILED_ITEMS+=("$branch: worktree がロックされており自動 unlock の条件外 ($WORKTREE_PATH)")
        continue
      fi

      if [ -n "$WT_STATUS" ] && [ "$WT_AGENT_PATH" != "1" ]; then
        echo "  ⚠️ worktree に未コミット変更があります。削除をスキップします: $WORKTREE_PATH"
        git -C "$WORKTREE_PATH" status --short | sed 's/^/     /'
        FAILED_ITEMS+=("$branch: worktree に未コミット変更あり ($WORKTREE_PATH)")
        continue
      fi

      if [ "$WT_LOCKED" = "1" ] && [ "$WT_AGENT_PATH" != "1" ]; then
        # claude agent ロックだが MERGED OID 照合が成立しない（clean だが unlock 条件外）
        echo "  ⚠️ worktree がロックされています（理由: ${WT_LOCK_REASON:-（記載なし）}）。削除をスキップします。"
        echo "     自動 unlock するのは「ロック理由が claude agent かつ (名前, OID) が MERGED PR の head と一致」の場合だけです。"
        FAILED_ITEMS+=("$branch: worktree がロックされており自動 unlock の条件外 ($WORKTREE_PATH)")
        continue
      fi

      WT_AGENT_NOTES=""
      if [ "$WT_AGENT_PATH" = "1" ]; then
        WT_UNLOCK_OUT=""
        if WT_UNLOCK_OUT="$(git worktree unlock "$WORKTREE_PATH" 2>&1)"; then
          echo "  ℹ️ claude agent ロックを解除しました（(名前, OID) が MERGED PR の head と一致）: ${WT_LOCK_REASON:-（理由の記載なし）}"
          WT_AGENT_NOTES="claude agent ロックを解除"
        else
          echo "  ❌ worktree の unlock に失敗: $WT_UNLOCK_OUT"
          FAILED_ITEMS+=("$branch: worktree unlock 失敗 ($WORKTREE_PATH)")
          continue
        fi
        if [ -n "$WT_STATUS" ]; then
          # --force での worktree ごと削除はしない。status 確認の後に入った変更まで
          # 巻き込むため（TOCTOU）。既知の使い捨てパスだけを個別に除去し、削除自体は
          # force なしの `git worktree remove` に委ねる — 確認後に別の変更が入っていれば
          # git 自身が拒否して fail-closed に戻る。
          echo "  ℹ️ worktree の残置物は既知の使い捨てパス（.review-results）だけで、(名前, OID) は MERGED PR の head と一致します。"
          echo "     使い捨てパス（.review-results）を除去してから worktree を削除します:"
          printf '%s\n' "$WT_STATUS" | sed 's/^/     /'
          if ! rm -rf "$WORKTREE_PATH/.review-results"; then
            echo "  ❌ 使い捨てパスの除去に失敗しました。ロックを元に戻して保護します: $WORKTREE_PATH"
            git worktree lock --reason "$WT_LOCK_REASON" "$WORKTREE_PATH" 2>&1 \
              || echo "  ⚠️ ロックの復元にも失敗しました（unlock されたまま残ります）: $WORKTREE_PATH"
            FAILED_ITEMS+=("$branch: 使い捨てパスの除去失敗 ($WORKTREE_PATH)")
            continue
          fi
          WT_AGENT_NOTES="${WT_AGENT_NOTES}、使い捨てパス（.review-results）を除去"
        fi
      fi

      echo "  worktree: $WORKTREE_PATH"
      # Claude Code はトランスクリプト格納先の名前を「symlink 解決済みの絶対パス」から
      # 導出する（macOS の /tmp は /private/tmp として記録される）。削除後は解決できない
      # ので Step 5.5 のためにここで控える。解決できなければ元のパスで代用するが、
      # その場合は候補名が総当たりで外れうるので黙って進めない。
      WORKTREE_REAL="$(resolve_dir "$WORKTREE_PATH" || true)"
      if [ -z "$WORKTREE_REAL" ]; then
        echo "  ⚠️ worktree パスを正規化できませんでした。トランスクリプトを取りこぼす可能性があります: $WORKTREE_PATH"
      fi
      # --force は付けない（エージェント経路を含む全経路）: 直前の clean 確認・
      # 使い捨てパス除去の後に変更が入った場合、git 自身が拒否するので TOCTOU の
      # 安全網になる。エージェント経路で拒否された場合は unlock 前の状態へ戻す
      # （元の理由で再ロック）。
      # 注意: .gitignore 対象のファイル（.env 等）は clean 扱いのまま削除される。
      # 惜しいファイルを worktree の ignored 領域にだけ置く運用は避けること（コマンド doc にも明記）
      WORKTREE_RM_OUT=""
      if ! WORKTREE_RM_OUT="$(git worktree remove "$WORKTREE_PATH" 2>&1)"; then
        echo "  ❌ worktree 削除に失敗: $WORKTREE_RM_OUT"
        echo "     ブランチ削除もスキップします。手動対応してください。"
        if [ "$WT_AGENT_PATH" = "1" ]; then
          if git worktree lock --reason "$WT_LOCK_REASON" "$WORKTREE_PATH" 2>&1; then
            echo "     解除していた claude agent ロックを元の理由で復元しました。"
          else
            echo "  ⚠️ ロックの復元にも失敗しました（unlock されたまま残ります）: $WORKTREE_PATH"
          fi
        fi
        FAILED_ITEMS+=("$branch: worktree 削除失敗 ($WORKTREE_PATH)")
        continue
      fi
      echo "  ✓ worktree removed: $WORKTREE_PATH"
      if [ -n "$WT_AGENT_NOTES" ]; then
        INFO_ITEMS+=("$branch: マージ済みエージェント worktree を自動処理（(名前, OID) が MERGED PR の head と一致。${WT_AGENT_NOTES}）")
      fi
      DELETED_WORKTREES+=("$WORKTREE_PATH")
      DELETED_WORKTREE_REALS+=("${WORKTREE_REAL:-$WORKTREE_PATH}")
    fi

    # まず -d（小文字）でマージ済みのみ削除を試す
    BRANCH_DEL_OUT=""
    if BRANCH_DEL_OUT="$(LC_ALL=C git branch -d "$branch" 2>&1)"; then
      echo "  ✓ branch deleted: $branch"
      DELETED_BRANCHES+=("$branch")
    elif printf '%s' "$BRANCH_DEL_OUT" | grep -qE 'not fully merged'; then
      # squash merge 由来は -d で消せない。ただし [gone] は「upstream が消えた」ことしか
      # 保証しないため、-D は (名前, ローカル OID) が MERGED PR の head と一致する
      # ブランチに限定する（手動でリモート削除された未マージ作業を消さないため）
      LOCAL_OID="$(git rev-parse "refs/heads/$branch")"
      if [ "$GUARDS_OK" = "1" ] && grep -qxF "$(printf '%s\t%s' "$branch" "$LOCAL_OID")" "$MERGED_LIST"; then
        if BRANCH_DEL_OUT="$(git branch -D "$branch" 2>&1)"; then
          echo "  ✓ branch deleted (forced, squash merge 済みを OID 照合で確認): $branch"
          DELETED_BRANCHES+=("$branch")
        else
          echo "  ❌ ブランチ削除に失敗: $BRANCH_DEL_OUT"
          FAILED_ITEMS+=("$branch: git branch -D 失敗")
        fi
      elif [ "$GUARDS_OK" = "1" ] && grep -qxF "$(printf '%s\tnull' "$branch")" "$MERGED_LIST"; then
        # MERGED 一覧に名前は載っているが、一覧側の headRefOid が null で返っている
        # （#570 / #703 の root cause）。このとき実際に無いのは**照合材料**であって
        # 未マージの証拠ではないため、「未マージの固有コミットの可能性」と誤帰属しない。
        # 利用者に存在しない未マージコミットを探させないことが目的で、削除しない点は同じ。
        echo "  ⚠️ $branch は MERGED PR の head 名として一覧に載っていますが、一覧側の OID が null で照合材料がありません。"
        echo "     未マージの可能性ではなく OID 照合が成立しないため、削除をスキップします。"
        echo "     マージ済みであることを PR ページで確認できた場合のみ、手動で 'git branch -D $branch' してください。"
        FAILED_ITEMS+=("$branch: [gone] だが MERGED 一覧側の OID が null で照合材料が無い（要手動確認）")
      else
        echo "  ⚠️ $branch はマージ済み PR の head と OID 一致しません（未マージの固有コミットの可能性）。"
        echo "     削除をスキップします。内容確認のうえ手動で 'git branch -D $branch' してください。"
        FAILED_ITEMS+=("$branch: [gone] だが MERGED PR と OID 不一致（要手動確認）")
      fi
    else
      echo "  ❌ ブランチ削除に失敗: $BRANCH_DEL_OUT"
      FAILED_ITEMS+=("$branch: git branch -d 失敗")
    fi
  done <<< "$GONE_BRANCHES"
fi

# ---- Step 5.5: 削除した worktree のトランスクリプト回収 -----------------------
#
# Claude Code は作業ディレクトリごとに独立したトランスクリプトディレクトリを
# <config>/projects/ 配下へ作る。worktree を消してもこれは残るため、二度と
# 参照されない履歴が無制限に溜まる（標準の cleanupPeriodDays は経過日数でしか
# 消さないので、期限内の孤児は残り続ける）。
#
# 「名前が一致したから消す」ことはしない。jsonl に記録された cwd が削除した
# worktree を指していることを照合してから処理する。リモート削除を
# --force-with-lease に、-D を OID 照合に限定しているのと同じ fail-closed の
# 考え方で、名前だけの一致では /a/b-c と /a/b/c を区別できない。
#
# 既定は削除ではなく tar.gz へのアーカイブ。履歴を失わずに容量を回収でき、
# 「未コミット変更を握りつぶさない」という本スクリプトの原則とも揃う。
#
# 環境変数:
#   FF_MERGE_CLEANUP_TRANSCRIPTS=off                … この Step を無効化（既定 archive）
#   FF_MERGE_CLEANUP_PROJECTS_DIR=<path>            … projects ディレクトリの上書き
#   FF_MERGE_CLEANUP_TRANSCRIPT_ARCHIVE_DIR=<path>  … アーカイブ先の上書き

TRANSCRIPT_MODE="${FF_MERGE_CLEANUP_TRANSCRIPTS:-archive}"

# 値の検証は「削除した worktree があったか」に依存させない。綴り違いで黙って
# 無効化されると「回収したはず」の誤解を生むため、実行のたびに必ず報告する。
if [ "$TRANSCRIPT_MODE" != "archive" ] && [ "$TRANSCRIPT_MODE" != "off" ]; then
  echo ""
  echo "⚠️ FF_MERGE_CLEANUP_TRANSCRIPTS の値が不正です: ${TRANSCRIPT_MODE}（archive / off のみ）"
  TRANSCRIPT_STEP_NOTE="スキップ（環境変数の値が不正: ${TRANSCRIPT_MODE}）"
  FAILED_ITEMS+=("トランスクリプト回収: FF_MERGE_CLEANUP_TRANSCRIPTS の値が不正 ($TRANSCRIPT_MODE)")
elif [ "$TRANSCRIPT_MODE" = "off" ]; then
  TRANSCRIPT_STEP_NOTE="無効（FF_MERGE_CLEANUP_TRANSCRIPTS=off）"
elif [ "${#DELETED_WORKTREES[@]}" -eq 0 ]; then
  : # 削除した worktree が無ければ対象も無い
else
  CLAUDE_HOME="${CLAUDE_CONFIG_DIR:-${HOME:-}/.claude}"
  PROJECTS_DIR="${FF_MERGE_CLEANUP_PROJECTS_DIR:-$CLAUDE_HOME/projects}"
  ARCHIVE_DIR="${FF_MERGE_CLEANUP_TRANSCRIPT_ARCHIVE_DIR:-$CLAUDE_HOME/transcript-archives}"
  PROJECTS_REAL=""
  ARCHIVE_DIR_READY=0
  PROCESSED_NAMES=""
  TRANSCRIPT_CANDIDATES=0

  if ! PROJECTS_REAL="$(resolve_dir "$PROJECTS_DIR")"; then
    # 既定パスが無いのは Claude Code 未使用というだけで異常ではない。一方、
    # 明示的に指定されたパスが解決できないのは設定ミスなので PARTIAL にする。
    TRANSCRIPT_STEP_NOTE="スキップ（projects ディレクトリを解決できません: ${PROJECTS_DIR}）"
    if [ -n "${FF_MERGE_CLEANUP_PROJECTS_DIR:-}" ] || [ -n "${CLAUDE_CONFIG_DIR:-}" ]; then
      echo ""
      echo "⚠️ 明示指定された projects ディレクトリを解決できません: ${PROJECTS_DIR}"
      FAILED_ITEMS+=("トランスクリプト回収: 指定された projects ディレクトリを解決できない ($PROJECTS_DIR)")
    fi
  else
    echo ""
    echo "🗂 削除した worktree のトランスクリプトを回収します（アーカイブ先: ${ARCHIVE_DIR}）"

    for WT_IDX in "${!DELETED_WORKTREES[@]}"; do
      # symlink 解決の前後どちらで記録されていても拾えるよう、両方を基準にする
      WT_BASES="$(printf '%s\n%s\n' \
        "${DELETED_WORKTREES[$WT_IDX]}" "${DELETED_WORKTREE_REALS[$WT_IDX]}" \
        | awk 'NF && !seen[$0]++')"

      while IFS= read -r WT_BASE; do
        [ -n "$WT_BASE" ] || continue

        while IFS= read -r CAND_NAME; do
          # 複数の基準パスや worktree が同じ名前へ潰れても 1 回だけ処理する
          case "$PROCESSED_NAMES" in
            *"<$CAND_NAME>"*) continue ;;
          esac
          case "$CAND_NAME" in
            ''|.|..|*/*) continue ;;
          esac
          PROCESSED_NAMES="$PROCESSED_NAMES<$CAND_NAME>"

          CAND_PATH="$PROJECTS_DIR/$CAND_NAME"
          [ -d "$CAND_PATH" ] || continue
          # 1 件でも候補を見たら「対象なし」とは言わない（保護・失敗で終わった
          # ものを「そもそも無かった」と報告すると、事実と食い違う）
          TRANSCRIPT_CANDIDATES=$((TRANSCRIPT_CANDIDATES + 1))
          # 候補そのものが symlink なら、リンク先が projects 内でも辿らない
          if [ -L "$CAND_PATH" ]; then
            echo "  ○ シンボリックリンクのため辿りません: $CAND_PATH"
            SKIPPED_TRANSCRIPTS+=("$CAND_NAME: シンボリックリンク")
            continue
          fi
          # 経路の途中に symlink があっても projects 直下へ着地することを確認する
          # （直前の -L と重なる保護だが、片方だけでは経路途中の差し替えを塞げない）
          CAND_REAL=""
          if ! CAND_REAL="$(resolve_dir "$CAND_PATH")" \
            || [ "$(dirname "$CAND_REAL")" != "$PROJECTS_REAL" ]; then
            echo "  ○ projects ディレクトリ直下に解決されないため残します: $CAND_PATH"
            SKIPPED_TRANSCRIPTS+=("$CAND_NAME: projects 直下へ解決されない")
            continue
          fi

          CWD_VERDICT=0
          transcript_cwd_verdict "$CAND_REAL" "$WT_BASES" || CWD_VERDICT=$?
          case "$CWD_VERDICT" in
            0)
              CAND_REASON="cwd 照合一致"
              if [ -s "$WORK_TMP/transcript_foreign_cwd" ]; then
                # 通常はセッションが親リポジトリ等へ移動しただけ。ただし名前が
                # 衝突した別プロジェクトと同居している可能性も残るため、
                # アーカイブごと回収する事実を見えるところに出す。
                CAND_REASON="cwd 照合一致（worktree 外の cwd も含む）"
                echo "  ℹ️ この履歴には worktree 外の作業ディレクトリも記録されています。まとめてアーカイブします:"
                sed 's/^/       /' "$WORK_TMP/transcript_foreign_cwd"
              fi
              ;;
            2)
              # cwd を記録した jsonl が無い。プラグインが書く付随データ
              # （skill-injections.jsonl 等）だけのディレクトリが常にこれに当たる。
              #
              # ここで「名前が worktree 由来に見えるから消す」と降格させない。候補名は
              # 削除した worktree のパスから導出したものなので、その名前を見ても
              # 「渡されたパスが worktree だった」以上のことは分からず、目の前の
              # ディレクトリが誰のものかという肝心の問いには答えていない。
              # 回収できない分は別途 sweep 側で扱う。
              SKIPPED_TRANSCRIPTS+=("$CAND_NAME: cwd を記録した jsonl が無く所有者を確認できない")
              echo "  ○ 所有者を確認できないため残します（cwd を記録した jsonl なし）: $CAND_NAME"
              continue
              ;;
            3)
              # 名前が衝突した別プロジェクトのディレクトリはここに来る。異常では
              # ないので PARTIAL にはせず、保護した事実だけ残す。
              SKIPPED_TRANSCRIPTS+=("$CAND_NAME: cwd がこの worktree を指していない")
              echo "  ○ この worktree を指す cwd が無いため残します: $CAND_NAME"
              continue
              ;;
            4)
              # 証拠の取得自体に失敗している。「証拠が無い」と同じ扱いにはできない
              # （読めなかっただけかもしれない）ので、手当が要る失敗として報告する。
              echo "  ⚠️ jsonl の走査でエラーが出たため処理しません（証拠を取り切れていない）: $CAND_NAME"
              FAILED_ITEMS+=("トランスクリプト回収: jsonl 走査エラーで保護 ($CAND_NAME)")
              continue
              ;;
            *)
              echo "  ⚠️ 想定外の照合結果のため処理しません（判定コード ${CWD_VERDICT}）: $CAND_NAME"
              FAILED_ITEMS+=("トランスクリプト回収: 想定外の照合結果で保護 ($CAND_NAME)")
              continue
              ;;
          esac

          if [ "$ARCHIVE_DIR_READY" != "1" ]; then
            if ! mkdir -p "$ARCHIVE_DIR" 2>/dev/null; then
              echo "  ❌ アーカイブ先を作成できません: $ARCHIVE_DIR"
              echo "     残りの候補も同じ理由で失敗するため、この Step を中断します。"
              FAILED_ITEMS+=("トランスクリプト回収: アーカイブ先を作成できない ($ARCHIVE_DIR)")
              # note を立てないと、この後のサマリーが「対象はありませんでした」と
              # 中断の事実に反する表示になる
              TRANSCRIPT_STEP_NOTE="中断（アーカイブ先を作成できない: ${ARCHIVE_DIR}）"
              break 3
            fi
            ARCHIVE_DIR_READY=1
          fi

          # 容量は付随情報。du の失敗で破壊的 Step 全体を落とさない
          # （pipefail + errexit の下では、代入内のパイプ失敗がそのまま致命傷になる）
          CAND_KB=""
          CAND_KB="$(du -sk "$CAND_REAL" 2>"$WORK_TMP/du_error" | awk 'NR == 1 { print $1 }')" || CAND_KB=""
          if [ -z "$CAND_KB" ]; then
            CAND_KB=0
            echo "  ⚠️ 容量を計測できませんでした（回収は続行します）: $CAND_NAME"
          fi

          # 同一秒に同名が来ても既存アーカイブを黙って上書きしない
          # （-e は壊れた symlink を見落とすので -L も見る）
          ARCHIVE_STAMP="$(date +%Y%m%d-%H%M%S)"
          ARCHIVE_FILE="$ARCHIVE_DIR/$CAND_NAME-$ARCHIVE_STAMP.tar.gz"
          ARCHIVE_SEQ=1
          while [ -e "$ARCHIVE_FILE" ] || [ -L "$ARCHIVE_FILE" ]; do
            ARCHIVE_FILE="$ARCHIVE_DIR/$CAND_NAME-$ARCHIVE_STAMP-$ARCHIVE_SEQ.tar.gz"
            ARCHIVE_SEQ=$((ARCHIVE_SEQ + 1))
          done

          # 完成するまで最終名を名乗らせない。作業ファイル名は予測させない
          # （予測できる名前だと、先回りして置かれた symlink のリンク先を
          #  tar が切り詰めうる）。mktemp なら常に新規の通常ファイルになる。
          ARCHIVE_TMP=""
          if ! ARCHIVE_TMP="$(mktemp "$ARCHIVE_DIR/.merge-cleanup-archive-XXXXXX")"; then
            FAILED_ITEMS+=("トランスクリプト回収: 作業ファイルを作成できない ($CAND_NAME)")
            echo "  ❌ アーカイブ用の作業ファイルを作成できません。元ディレクトリは残します: $CAND_NAME"
            continue
          fi
          ARCHIVE_LIST="$WORK_TMP/archive_list"
          ARCHIVE_ERR="$WORK_TMP/archive_error"
          ARCHIVE_VERIFY=""
          TAR_OUT=""
          ARCHIVE_FAIL=""

          # ディレクトリ名は '-' 始まりなので、-C + './名前' でオプション誤認を避ける
          if ! TAR_OUT="$(tar -czf "$ARCHIVE_TMP" -C "$PROJECTS_REAL" "./$CAND_NAME" 2>&1)"; then
            ARCHIVE_FAIL="tar が失敗しました"
          elif ! tar -tzf "$ARCHIVE_TMP" > "$ARCHIVE_LIST" 2>"$ARCHIVE_ERR"; then
            # 終了コードだけを信じない。読み直せないアーカイブを根拠に元を消すと
            # そのまま履歴の消失になる
            TAR_OUT="$(cat "$ARCHIVE_ERR")"
            ARCHIVE_FAIL="アーカイブを読み直せませんでした"
          else
            SRC_ENTRIES=""
            SRC_ENTRIES="$(find "$CAND_REAL" ! -type d 2>/dev/null | wc -l | tr -d ' ')" || SRC_ENTRIES=""
            # tar はディレクトリを末尾 '/' 付きで並べるので、それ以外を数える
            ARC_ENTRIES="$(grep -cv '/$' "$ARCHIVE_LIST" || true)"
            if [ -z "$SRC_ENTRIES" ] || [ "$SRC_ENTRIES" != "$ARC_ENTRIES" ]; then
              TAR_OUT="元 ${SRC_ENTRIES:-?} 件 / アーカイブ ${ARC_ENTRIES} 件"
              ARCHIVE_FAIL="アーカイブの件数が元と一致しません"
            elif ! ARCHIVE_VERIFY="$(mktemp -d "$WORK_TMP/archive-verify-XXXXXX")"; then
              TAR_OUT="検証用ディレクトリを作成できません"
              ARCHIVE_FAIL="アーカイブと元を比較できませんでした"
            elif ! tar -xzf "$ARCHIVE_TMP" -C "$ARCHIVE_VERIFY" > /dev/null 2> "$ARCHIVE_ERR"; then
              TAR_OUT="$(cat "$ARCHIVE_ERR")"
              ARCHIVE_FAIL="アーカイブを検証用に展開できませんでした"
            else
              # marker との mtime 比較は、時計補正や時刻分解能の境界で未変更ファイルを
              # 誤検出し、同一 mtime の追記を見逃しうる。作成済みアーカイブを展開して
              # バイト列を直接比較し、tar 実行後の追加・削除・内容変更を判定する。
              DIFF_RC=0
              diff -r --no-dereference "$CAND_REAL" "$ARCHIVE_VERIFY/$CAND_NAME" > "$ARCHIVE_ERR" 2>&1 || DIFF_RC=$?
              if [ "$DIFF_RC" -eq 1 ]; then
                TAR_OUT="$(cat "$ARCHIVE_ERR")"
                ARCHIVE_FAIL="アーカイブ中に元が変更されました"
              elif [ "$DIFF_RC" -ne 0 ]; then
                TAR_OUT="$(cat "$ARCHIVE_ERR")"
                ARCHIVE_FAIL="アーカイブと元を比較できませんでした"
              fi
            fi
          fi

          if [ -n "$ARCHIVE_FAIL" ]; then
            # 記録を先に積む。この後の出力や rm が失敗しても PARTIAL の主張を失わない
            FAILED_ITEMS+=("トランスクリプト回収: $ARCHIVE_FAIL ($CAND_NAME)")
            echo "  ❌ ${ARCHIVE_FAIL}。元ディレクトリは残します: $CAND_NAME"
            printf '%s\n' "$TAR_OUT" | sed 's/^/     /' || true
            rm -f "$ARCHIVE_TMP" || true
            continue
          fi

          if ! mv "$ARCHIVE_TMP" "$ARCHIVE_FILE"; then
            FAILED_ITEMS+=("トランスクリプト回収: アーカイブの確定に失敗 ($CAND_NAME)")
            echo "  ❌ アーカイブの確定に失敗しました。元ディレクトリは残します: $CAND_NAME"
            rm -f "$ARCHIVE_TMP" || true
            continue
          fi

          # 照合から削除までの隙間で候補が差し替えられていないか直前に確かめ直す。
          # bash では fd を握ったまま削除できないため窓を狭めるだけで、完全には
          # 閉じられない（残る窓は mv 直後から rm までの数ミリ秒）
          RECHECK_REAL=""
          if [ -L "$CAND_PATH" ] \
            || ! RECHECK_REAL="$(resolve_dir "$CAND_PATH")" \
            || [ "$RECHECK_REAL" != "$CAND_REAL" ] \
            || [ "$(dirname "$RECHECK_REAL")" != "$PROJECTS_REAL" ]; then
            FAILED_ITEMS+=("トランスクリプト回収: 削除直前の再確認に失敗したため保護 ($CAND_NAME)")
            echo "  ⚠️ 削除直前の再確認に失敗したため元ディレクトリは残します: $CAND_NAME"
            echo "     アーカイブは作成済みです: $ARCHIVE_FILE"
            continue
          fi

          if ! rm -rf "$CAND_REAL"; then
            FAILED_ITEMS+=("トランスクリプト回収: アーカイブ後の削除失敗 ($CAND_NAME)")
            echo "  ❌ アーカイブ後の削除に失敗しました（アーカイブと元が二重に残ります）: $CAND_REAL"
            continue
          fi

          ARCHIVE_KB=""
          ARCHIVE_KB="$(du -sk "$ARCHIVE_FILE" 2>/dev/null | awk 'NR == 1 { print $1 }')" || ARCHIVE_KB=""
          [ -n "$ARCHIVE_KB" ] || ARCHIVE_KB=0
          echo "  ✓ archived: $CAND_NAME (${CAND_KB} KB → ${ARCHIVE_KB} KB, $CAND_REASON)"
          ARCHIVED_TRANSCRIPTS+=("$CAND_NAME")
          ARCHIVED_TRANSCRIPT_KB=$((ARCHIVED_TRANSCRIPT_KB + CAND_KB))
          ARCHIVE_TOTAL_KB=$((ARCHIVE_TOTAL_KB + ARCHIVE_KB))
        done < <(transcript_dir_names_for "$WT_BASE")
      done <<< "$WT_BASES"
    done

    if [ "$TRANSCRIPT_CANDIDATES" -eq 0 ] && [ -z "$TRANSCRIPT_STEP_NOTE" ]; then
      echo "  対象のトランスクリプトはありませんでした。"
    fi
  fi
fi

# ---- Step 6: リモート取り残しのガード付き自動削除（fail-closed） ---------------

# delete_branch_on_merge=false の repo では UI 経由マージや cleanup スキップで
# マージ済みリモートブランチが累積する。以下の全ガードを通過したものだけ自動削除する:
#   1. (名前, OID) が MERGED 済み PR の head と完全一致（名前再利用・マージ後 push を除外）
#   2. fork PR 由来でない（origin の同名別ブランチを誤射しない）
#   3. 保護ブランチ名でない
#   4. open PR の head として再利用されていない
# 削除自体も --force-with-lease で「照合した OID のときだけ」実行する（TOCTOU 対策）。
# 削除は delete_remote_branch_with_lease（SKIP_SIMPLE_GIT_HOOKS=1）経由。
# ガード情報の取得に失敗している場合は Step 6 全体をスキップする（fail-closed）

echo ""
echo "=== リモート取り残し検証 ==="

LEFTOVER_CHECK_DONE=0

if [ "$GUARDS_OK" != "1" ]; then
  echo "⚠️ ガード情報（MERGED / open PR 一覧）が構成できていないため、取り残し検証をスキップします（fail-closed）。"
else
  echo "⏳ リモートブランチ一覧を取得しています（git ls-remote --heads origin）..."
  LS_REMOTE_OUT=""
  if ! LS_REMOTE_OUT="$(git ls-remote --heads origin 2>&1)"; then
    echo "⚠️ git ls-remote に失敗しました。取り残し検証をスキップします（fail-closed）: $LS_REMOTE_OUT"
  else
    LEFTOVER_CHECK_DONE=1

    REMOTE_LIST="$WORK_TMP/remote.list"   # "name<TAB>oid"
    printf '%s\n' "$LS_REMOTE_OUT" \
      | awk -F'\t' '{ sub("refs/heads/", "", $2); print $2 "\t" $1 }' \
      | sort -u > "$REMOTE_LIST"

    # (名前, OID) 完全一致のみ候補にする。OID も控えて lease 付き削除に使う
    LEFTOVER="$(comm -12 "$MERGED_LIST" "$REMOTE_LIST")"

    if [ -z "$LEFTOVER" ]; then
      # 対象 PR の削除をスキップしていた場合、その head は照合に一致しないまま
      # origin に残っている可能性がある。「取り残しなし」と断定すると、スキップの
      # 通知を読み飛ばした利用者に「掃除は完了した」と伝わるため、除外を添える。
      LEFTOVER_NONE_NOTE=""
      case "$PR_REMOTE_RESULT" in
        skipped*) LEFTOVER_NONE_NOTE="（今回スキップした ${PR_HEAD} を除く）" ;;
      esac
      echo "✅ リモート取り残しなし（直近 ${MERGED_PR_LIMIT} 件のマージ済み PR と (名前, OID) 照合）${LEFTOVER_NONE_NOTE}"
    else
      echo "🧹 リモート取り残しのマージ済みブランチを検出しました:"
      printf '%s\n' "$LEFTOVER" | cut -f1 | sed 's/^/  - /'
      echo ""

      while IFS="$(printf '\t')" read -r rbranch roid; do
        [ -z "$rbranch" ] && continue

        if is_hardcoded_protected_branch "$rbranch"; then
          echo "  ⚠️ skip (保護ブランチ): $rbranch"
          SKIPPED_LEFTOVERS+=("$rbranch: 保護ブランチ")
          continue
        fi

        if grep -qxF "$rbranch" "$OPEN_LIST"; then
          echo "  ⚠️ skip (open PR で再利用中): $rbranch"
          SKIPPED_LEFTOVERS+=("$rbranch: open PR の head として再利用中")
          continue
        fi

        # 設定可能な保護パターン（既定 release/*。Issue #1056）に止められたものは、
        # ここまでの全ガード（MERGED head と (名前, OID) 一致 / fork 由来でない /
        # open PR 未使用）を通過している = 「マージ済みで安全に消せる」ことが証明済みで、
        # 止めているのは名前パターンだけ。毎回同じ skip が無言で積み上がると本当に
        # 判断が要る skip がノイズに埋もれるため、手動判断の材料（削除コマンドと
        # 恒久設定）を添えて報告する。
        if PROTECT_HIT="$(matched_extra_protect_pattern "$rbranch")"; then
          echo "  ⚠️ skip (設定保護パターン '${PROTECT_HIT}' に一致): $rbranch"
          echo "     このブランチはマージ済みで他の全ガードを通過しています。長命ブランチでなければ手動で削除できます:"
          echo "       git push origin --force-with-lease=refs/heads/$rbranch:$roid :refs/heads/$rbranch"
          echo "     恒久対応は FF_MERGE_CLEANUP_PROTECT_BRANCHES の見直し（既定 'release/*'、'none' で追加保護なし。develop/main/master/staging/* は設定でも外れません）"
          SKIPPED_LEFTOVERS+=("$rbranch: 設定保護パターン '${PROTECT_HIT}' に一致（マージ済み・手動削除コマンドは実行ログ参照）")
          continue
        fi

        set +e
        delete_remote_branch_with_lease "$rbranch" "$roid"
        rc=$?
        set -e
        case "$rc" in
          0)
            echo "  ✓ removed: $rbranch"
            DELETED_LEFTOVERS+=("$rbranch")
            # Step 4 で削除に失敗した対象 PR の head をここで削除できた場合、サマリーの
            # 「対象 PR のリモートブランチ」を失敗のまま残すと実態と食い違う。
            # FAILED_ITEMS の記録は残す（実際に 1 回失敗しており PARTIAL が正しい）。
            # 名前だけでなく OID も照合する（同名別 OID の取り残しを消したときに
            # 対象 PR の行を書き換えないため）。
            if is_pr_head_retry "$rbranch" "$roid"; then
              PR_REMOTE_RESULT="deleted_by_leftover_retry"
            elif is_pr_head_retry_no_oid "$rbranch"; then
              # headRefOid が取れずスキップした対象を、一覧側の正常な OID を
              # アンカーにここで消せたケース。Step 4 の「失敗」は起きていない
              # （削除を見送っただけ）ので、保留していた失敗行は補足行へ落とす。
              PR_REMOTE_RESULT="deleted_by_leftover_retry"
              PR_OID_PENDING_FAILURE=""
              INFO_ITEMS+=("$rbranch: headRefOid は gh pr view から取得できなかったが、取り残し検証の (名前, OID) 照合で削除済み")
            fi
            ;;
          2)
            echo "  ℹ️  already removed: $rbranch"
            # 再試行の時点で消えていた場合も、Step 4 の failed を残すと最終状態と
            # 食い違う。消したのは自分ではないので deleted ではなく already 扱い。
            if is_pr_head_retry "$rbranch" "$roid"; then
              PR_REMOTE_RESULT="already_missing_at_leftover_retry"
            elif is_pr_head_retry_no_oid "$rbranch"; then
              PR_REMOTE_RESULT="already_missing_at_leftover_retry"
              PR_OID_PENDING_FAILURE=""
              INFO_ITEMS+=("$rbranch: headRefOid は gh pr view から取得できなかったが、取り残し検証の時点で既に削除済み")
            fi
            ;;
          3)
            echo "  ⚠️ skip (照合後に push あり・lease 拒否): $rbranch"
            SKIPPED_LEFTOVERS+=("$rbranch: 照合後に push あり（lease 拒否）")
            if is_pr_head_retry_no_oid "$rbranch"; then
              # headRefOid が取れずスキップした対象を Step 6 が拾い、照合の後に
              # push が入って lease に拒否されたケース。**削除しないのは保護**で
              # あって失敗ではない（Step 4 の skipped_lease_rejected と同格）ため、
              # 保留していた「削除未実施」の失敗行を落とす。残さないと、正常な
              # 保護に対して PARTIAL と誤った復旧手順を出すことになる。
              # 既知 OID 側（is_pr_head_retry）の rc=3 はここでは触らない。
              # あちらは Step 4 で実際に削除を試みて失敗しており、その失敗行が
              # 残るのは正当なため。
              PR_REMOTE_RESULT="skipped_lease_rejected_at_leftover_retry"
              PR_OID_PENDING_FAILURE=""
            fi
            ;;
          *)
            echo "  ❌ 削除失敗: $rbranch — $(last_push_error_text)"
            # 恒久的な失敗（ブランチ保護・権限など）では、Step 4 で失敗した head が
            # ここで必ず再試行されて再び失敗する。同じ文言を 2 行並べると「2 本
            # 失敗した」と読めるため、2 回目であることを文言で区別する。
            if is_pr_head_retry "$rbranch" "$roid"; then
              FAILED_ITEMS+=("$rbranch: リモート削除失敗（Step 6 の再試行も失敗: $(last_push_error_head)）")
            elif is_pr_head_retry_no_oid "$rbranch"; then
              # Step 4 は削除を試みていない（headRefOid が無くスキップ）ので「再試行」
              # ではなく最初の試行。保留していた「未実施」の行はここで消し、1 行に
              # 束ねる（「未実施」と「削除失敗」を 2 行並べると実態と食い違う）。
              PR_OID_PENDING_FAILURE=""
              # ここでの $roid は取り残し一覧との (名前, OID) 完全一致を通っており、
              # 「MERGED 済み PR の head」であることが確認済み。無条件の削除ではなく、
              # その OID を lease に載せた形を案内する（再試行までの間に push が
              # 入っていれば、この形なら拒否されて保護される）。
              FAILED_ITEMS+=("$rbranch: リモート削除失敗（headRefOid が無く Step 4 はスキップ / 取り残し検証での削除も失敗: $(last_push_error_head)）— 'git push origin --force-with-lease=refs/heads/$rbranch:$roid :refs/heads/$rbranch' で再試行し merge-cleanup を再実行")
            else
              FAILED_ITEMS+=("$rbranch: リモート削除失敗（$(last_push_error_head)）")
            fi
            ;;
        esac
      done <<< "$LEFTOVER"

      # 削除を反映（ここの失敗は最終検証の [gone] 表示が古くなるだけなので警告に留める）
      git fetch --prune origin 2>&1 || echo "⚠️ 最終 fetch --prune が失敗しました（表示が古い可能性があります）"
    fi
  fi
fi

# ---- Step 7: 最終検証 ---------------------------------------------------------

echo ""
echo "=== 最終状態 ==="
git branch -vv
echo ""
git worktree list
echo ""
git status

CURRENT_BRANCH="$(git branch --show-current)"
if [ "$CURRENT_BRANCH" != "$PR_BASE" ]; then
  if [ "$NO_SWITCH_MODE" = "1" ]; then
    echo "ℹ️ 呼び出し元のブランチを保持したままです: ${CURRENT_BRANCH}（switch なし掃除モードのため base への復帰は行っていません）"
  else
    echo "⚠️ 現在のブランチが $PR_BASE ではありません: $CURRENT_BRANCH"
  fi
fi

# upstream の存在を先に判定してから rev-list を無抑制で呼ぶ（エラーの丸め込みを避ける）
if git rev-parse --abbrev-ref '@{u}' >/dev/null 2>&1; then
  UPSTREAM_DIFF="$(git rev-list --left-right --count "HEAD...@{u}")"
  if [ "$UPSTREAM_DIFF" != "$(printf '0\t0')" ]; then
    echo "⚠️ $PR_BASE が origin/$PR_BASE に完全追従していません: ahead/behind = $UPSTREAM_DIFF"
  fi
fi

REMAINING_GONE="$(git for-each-ref \
  --format='%(if:equals=[gone])%(upstream:track)%(then)%(refname:short)%(end)' \
  refs/heads/ | grep -v '^$' || true)"
if [ -n "$REMAINING_GONE" ]; then
  echo "⚠️ まだ [gone] ブランチが残っています:"
  printf '%s\n' "$REMAINING_GONE" | sed 's/^/  - /'
fi

# upstream なしの孤児ブランチを警告のみ（削除しない）
ORPHANS="$(git for-each-ref \
  --format='%(if)%(upstream)%(then)%(else)%(refname:short)%(end)' \
  refs/heads/ | grep -v '^$' | grep -vE '^(develop|main|master)$' || true)"
if [ -n "$ORPHANS" ]; then
  echo ""
  echo "ℹ️ upstream なしの孤児ブランチ（中身確認後に手動削除）:"
  printf '%s\n' "$ORPHANS" | sed 's/^/  - /'
fi

# ---- Step 7.5: optional post-merge-cleanup hook -------------------------------

HOOK="$REPO_ROOT/.claude/hooks/post-merge-cleanup.sh"
if [ -f "$HOOK" ] && [ -x "$HOOK" ]; then
  echo ""
  echo "▶ running $HOOK"
  if ! "$HOOK"; then
    echo "⚠️ post-merge-cleanup hook が失敗しました（cleanup 自体は完了済み）。"
    FAILED_ITEMS+=("post-merge-cleanup hook 失敗")
  fi
elif [ -f "$HOOK" ]; then
  echo "⚠️ $HOOK は実行可能ではありません（chmod +x してください）。スキップします。"
fi

# ---- Step 8: 結果サマリー -----------------------------------------------------

# headRefOid が取れずスキップした対象が、Step 6 でも解消していない場合はここで
# 失敗として積む（解消した場合は Step 6 が空にし、補足行だけを残している）。
if [ -n "$PR_OID_PENDING_FAILURE" ]; then
  FAILED_ITEMS+=("$PR_OID_PENDING_FAILURE")
fi

echo ""
echo "## マージ後 Cleanup 結果"
echo ""
echo "**対象 PR**: #$PR_NUM"
echo ""
# 「リモートブランチを削除したか」は完了報告で必ず明示する（Issue #758。`gh pr merge`
# の成否と混同されると、delete_branch_on_merge=false のリポジトリで取り残しに気付けない）
case "$PR_REMOTE_RESULT" in
  deleted|deleted_by_leftover_retry) PR_REMOTE_HUMAN="削除した" ;;
  already_missing|already_missing_at_leftover_retry) PR_REMOTE_HUMAN="既に存在しない（今回の削除は不要）" ;;
  skipped_fork) PR_REMOTE_HUMAN="削除していない（fork PR のため origin 側は対象外）" ;;
  skipped_open_reuse|skipped_lease_rejected|skipped_lease_rejected_at_leftover_retry) PR_REMOTE_HUMAN="削除していない（保護。上の警告を参照）" ;;
  *) PR_REMOTE_HUMAN="削除していない（要確認。上の警告 / 失敗項目を参照）" ;;
esac
echo "- 対象 PR のリモートブランチ ($PR_HEAD): $PR_REMOTE_RESULT — リモートブランチの削除: ${PR_REMOTE_HUMAN}"
echo "- 削除した [gone] ローカルブランチ: ${#DELETED_BRANCHES[@]} 本${DELETED_BRANCHES[*]+ (${DELETED_BRANCHES[*]})}"
echo "- 削除した worktree: ${#DELETED_WORKTREES[@]} 個${DELETED_WORKTREES[*]+ (${DELETED_WORKTREES[*]})}"
if [ -n "$TRANSCRIPT_STEP_NOTE" ]; then
  echo "- worktree トランスクリプトの回収: $TRANSCRIPT_STEP_NOTE"
elif [ "${#ARCHIVED_TRANSCRIPTS[@]}" -gt 0 ]; then
  # 「回収」ではなく元サイズ→アーカイブサイズで書く。前者だけを回収量と呼ぶと、
  # アーカイブが占める分を引いていない過大な数字になる
  echo "- アーカイブした worktree トランスクリプト: ${#ARCHIVED_TRANSCRIPTS[@]} 件 / 元 ${ARCHIVED_TRANSCRIPT_KB} KB → アーカイブ ${ARCHIVE_TOTAL_KB} KB（${ARCHIVE_DIR:-}）"
else
  echo "- アーカイブした worktree トランスクリプト: 0 件"
fi
if [ "${#SKIPPED_TRANSCRIPTS[@]}" -gt 0 ]; then
  # 所有者を確認できず残したものは異常ではないので、PARTIAL とは別枠で並べる
  echo "- 所有者を確認できず残したトランスクリプト: ${#SKIPPED_TRANSCRIPTS[@]} 件"
  printf '  - %s\n' "${SKIPPED_TRANSCRIPTS[@]}"
fi
if [ "$LEFTOVER_CHECK_DONE" = "1" ]; then
  echo "- 自動削除したリモート取り残し: ${#DELETED_LEFTOVERS[@]} 本${DELETED_LEFTOVERS[*]+ (${DELETED_LEFTOVERS[*]})}"
else
  echo "- リモート取り残し検証: スキップ（ガード情報の取得失敗）"
fi
echo "- 現在のブランチ: $CURRENT_BRANCH"

if [ "$NO_SWITCH_MODE" = "1" ]; then
  # 掃除モードで意図的に見送った項目は、失敗（PARTIAL）ではなく名指しの未実施として
  # 報告する（#749: 中断せず完遂しつつ、やらなかったことを報告から欠落させない）
  echo ""
  echo "**ℹ️ switch なし掃除モードでの未実施項目（呼び出し元が '${CURRENT_BRANCH_BEFORE}' を保持）**:"
  echo "  - ${PR_BASE} への復帰と pull --ff-only（他セッションの作業ブランチを切り替えないため）"
  echo "  - ${PR_BASE} の最新化: ${BASE_FF_NOTE:-未実施}"
fi

if [ "${#SKIPPED_LEFTOVERS[@]}" -gt 0 ]; then
  echo ""
  echo "**⚠️ スキップした削除候補**:"
  printf '  - %s\n' "${SKIPPED_LEFTOVERS[@]}"
fi

if [ "${#INFO_ITEMS[@]}" -gt 0 ]; then
  # 実際の失敗は起きていないので PARTIAL には数えない。手当てが要らないことを
  # 明示するために、失敗項目とは別枠で出す
  echo ""
  echo "**ℹ️ 補足（手当て不要）**:"
  printf '  - %s\n' "${INFO_ITEMS[@]}"
fi

EXIT_CODE=0
if [ "${#FAILED_ITEMS[@]}" -gt 0 ]; then
  echo ""
  echo "**⚠️ 失敗・要手動対応の項目 — 結果: PARTIAL**:"
  printf '  - %s\n' "${FAILED_ITEMS[@]}"
  EXIT_CODE=2
elif [ "$LEFTOVER_CHECK_DONE" != "1" ]; then
  echo ""
  echo "**⚠️ 取り残し検証が未実施です — 結果: PARTIAL**"
  EXIT_CODE=2
fi

echo ""
echo "次のステップ: /ace-curate $PR_NUM で知見をプレイブックへ反映"
exit "$EXIT_CODE"
