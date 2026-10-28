#!/usr/bin/env bash
#
# merge-cleanup.sh — PR マージ後のクリーンアップ一括実行
#
# 使い方: merge-cleanup.sh [--dry-run] <PR番号>
#         merge-cleanup.sh --help
#
# オプション:
#   --dry-run   何も削除せず、「実行時に削除されるもの」だけを一覧表示する
#   --help, -h  使い方を表示して終了する（PR 番号としては解釈しない）
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
#   5.4 worktree 未使用・マージ証拠・origin 同名 ref 不在を満たす worktree-agent-* の削除
#   5.5 削除した worktree のトランスクリプト回収（cwd 照合のうえ tar.gz へアーカイブ）
#   6. リモート取り残しブランチのガード付き自動削除（fail-closed）
#   7. 最終検証と結果サマリー
#   （--dry-run では 1〜7 の破壊的操作とネットワーク更新 — 削除 push・switch・pull・
#     fetch --prune・hook 実行・トランスクリプトのアーカイブ — をすべて見送り、判定
#     だけを実行時と同じ条件で行って「実行時に削除されるもの」を一覧表示する。
#     見送った prune とリモート削除の連鎖 — 削除 → prune → 新たに [gone] になる
#     ローカルブランチ → その worktree — は read-only の ls-remote で予測して
#     予告へ含める。ref は 1 つも書き換えない）
#
# 終了コード:
#   0 = 完全成功（--help もここ） / 1 = 致命的エラーで中断（引数なし・不正なオプション
#   を含む） / 2 = 完了したが一部失敗・要手動対応あり（PARTIAL）
#   --dry-run でも契約は同じで、実行時と同じ判定から出た結果をそのまま返す
#
# 安全原則:
#   - 保護ブランチは絶対に削除しない。develop / main / master / staging/* は
#     ハードコードで、どんな設定でも外せない。release/* は既定で保護するが、
#     FF_MERGE_CLEANUP_PROTECT_BRANCHES で運用に合わせて変更できる（Issue #1056）
#   - リモート削除は --force-with-lease=<ref>:<期待OID> で行い、照合と削除の間の
#     push 競合（TOCTOU）をサーバー側で原子的に拒否させる
#   - 削除 push はコード変更を運ばないため SKIP_SIMPLE_GIT_HOOKS=1 HUSKY=0 を付ける
#     （consumer の simple-git-hooks / husky のフルゲートを起動しない）。
#     core.hooksPath の一時無効化と --no-verify は他の guard まで落とすので使わない
#   - 対象 PR の head の削除 push は、dry-run と同じ判定（remote_delete_verdict の
#     read-only な ls-remote --exit-code）で ref の実在と OID 一致を確かめてから行う。
#     ref が無ければ push しない — 消えた ref への削除 push も pre-push を起動し、
#     git は空の stdin を渡すため consumer の「削除だけならスキップ」判定が効かない
#     （公開 ff-dev-toolkit#137。実測で約 10〜12 分のフルゲート）
#   - ローカル [gone] ブランチの -D（強制削除）は (名前, ローカル OID) が
#     MERGED PR の head と一致する場合に限定（[gone] だけではマージ済みの証明にならない）
#   - ガードに必要な情報の取得に失敗したら削除せずスキップ（fail-closed）
#   - dirty な worktree は削除しない。upstream なしの孤児ブランチも警告のみ。
#     例外は Step 5.4 の全条件で安全性を確認した worktree-agent-* だけ
#   - 未コミット変更ガードのパス除外（FF_MERGE_CLEANUP_IGNORE_PATHS）が効くのは
#     「中断しても何も消えない」ガードだけ（Step 1 / Step 3）。worktree 削除前の
#     clean 確認（Step 5）は対象外で、除外指定があっても dirty なら削除しない
#   - base を保持する別 worktree は clean の場合だけ detached へ退避し、
#     worktree と ignored ファイルを維持する。dirty なら変更せず中断する。
#     detached HEAD の linked worktree からは switch なし掃除モードで、退避しない
#   - 対象 PR のブランチを保持する linked worktree を cwd にして起動された場合は、
#     破壊的処理の前に中断する。その cwd では掃除対象である worktree 自身を削除できず、
#     base を別の worktree が保持していれば、その worktree を detached HEAD へ退避する
#     ことになる。main tree のパスが取れれば再実行コマンドを、取れない構成（bare
#     リポジトリ）では原因と対処を示す
#   - トランスクリプトの回収は「今回削除に成功した worktree の分」だけを対象にし、
#     jsonl の cwd がその worktree を指すことを照合してから処理する。既定は削除では
#     なく tar.gz へのアーカイブで、アーカイブに失敗したら元ディレクトリを残す
#   - --dry-run は「判定は実行時と同じ、副作用だけが無い」。保護ブランチ・dirty
#     worktree・fail-closed な縮退はすべて実行時と同じ条件で評価し、dry-run だけ
#     判定を緩めない。実行時の削除は --force-with-lease で OID を照合するので、
#     予告も read-only の ls-remote で「ref の実在と OID 一致」を確かめてから出す
#     （取れなければ予告しない = fail-closed）。判定の基準時点も実行時に合わせる:
#     -d 相当の判定と「呼び出し元がチェックアウト中」は、実行時に switch / pull した
#     後の base を基準にする（現在の HEAD ではない）。見送った prune と削除の連鎖も
#     予測して予告へ含める — **予告が実際の削除より少ないのは最も危険な壊れ方**で、
#     --dry-run の唯一の価値（何が壊れるかを先に見せる）がそこで失われるため
#   - --help の解析と早期終了は mktemp・gh / jq の存在確認より前に置く。依存の後ろに
#     置くと、使い方をいちばん知りたい環境（gh / jq 未導入・TMPDIR 書き込み不可）で
#     usage が出ないまま exit 1 になる

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
  # なら 1、判定不能は 2。linked worktree では --git-dir が <common>/worktrees/<name> を指し、
  # --git-common-dir と一致しない。判定不能を通常モードへ倒さない。
  local git_dir="" common_dir=""
  git_dir="$(git rev-parse --git-dir 2>/dev/null)" || return 2
  common_dir="$(git rev-parse --git-common-dir 2>/dev/null)" || return 2
  git_dir="$(resolved_dir "$git_dir")" || return 2
  common_dir="$(resolved_dir "$common_dir")" || return 2
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
  values="$( { find "$dir" -type f -name '*.jsonl' -exec grep -oh '"cwd":"[^"]*"' {} + | LC_ALL=C sort -u ; } 2>"$scan_err" )" || true
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

# ---- Step 0: 引数 -----------------------------------------------------------
#
# この Step は mktemp と gh / jq の存在確認より **前** に置く。--help は「何が消えるのか
# を副作用なしで知る」ための最も壊れにくい経路で、依存の後ろに置くと gh / jq 未導入や
# TMPDIR 書き込み不可の環境（= 使い方をいちばん知りたい環境）で usage が出ないまま
# exit 1 になる。引数の解析と早期終了は外部コマンドを一切使わないので、依存の前で完結する。

print_usage() {
  # 破壊的処理を持つツールなので、使い方には「何を消すのか」まで書く。
  # 変数展開は使わない（--help は最も壊れにくい経路であるべき）。
  cat <<'USAGE'
使い方:
  merge-cleanup.sh [--dry-run] <PR番号>   マージ済み PR のクリーンアップを実行する
  merge-cleanup.sh --help                 この使い方を表示する

引数:
  <PR番号>    マージ済み PR の番号（必須。例: 1234）。省略すると
              delete_branch_on_merge=false な repo でリモートブランチが残る。

オプション:
  --dry-run   何も削除せず、「実行時に削除されるもの」だけを一覧表示する。
              保護ブランチ・dirty worktree・fail-closed な縮退の判定は実行時と
              同じで、dry-run だけ緩むことはない。削除のほかに base への switch /
              pull / fetch --prune / hook の実行も行わないが、見送った prune と
              リモート削除の連鎖（削除 → prune → 新たに [gone] になるローカル
              ブランチ → その worktree）は read-only の ls-remote で予測して
              一覧へ含める。ref は 1 つも書き換えない。
  --help, -h  この使い方を表示して終了する（PR 番号としては解釈しない）。
  --github-input FILE  絶対パスの取得索引を読む。必須state/head/base不足は名指しrc2。

このスクリプトが削除するもの（--dry-run を付けない場合）:
  - 対象 PR のリモートブランチ（origin。--force-with-lease で OID 一致時のみ）
  - [gone] ローカルブランチと、それを保持する worktree（clean のときだけ）
  - worktree 未使用・マージ証拠・origin 同名 ref 不在を満たす worktree-agent-*
  - 削除した worktree だけが使っていた Claude Code のトランスクリプト
    （既定は削除ではなく tar.gz へのアーカイブ）
  - リモート取り残しのマージ済みブランチ（(名前, OID) 照合を通ったものだけ）

終了コード: 0 = 完全成功 / 1 = 中断（引数不正を含む） / 2 = PARTIAL（一部失敗）
file取得の必須不足もrc2だが、診断にoperation/fieldを出し、削除の前に停止する。
USAGE
}

# --help は「PR 番号として解釈しない」ことが要件。数値判定より前に、専用の分岐で
# 必ず終了させる（引数を 1 つずつ見る形にしないと、先頭以外に置かれた --help が
# 位置引数として素通りする）。
DRY_RUN=0
PR_NUM=""
github_input=""
ARG_ERROR=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --help|-h)
      print_usage
      exit 0
      ;;
    --dry-run)
      DRY_RUN=1
      ;;
    --github-input)
      [ "$#" -ge 2 ] && [ -n "$2" ] || { echo 'github-input: index argument missing' >&2; exit 2; }
      github_input="$2"
      shift
      ;;
    -*)
      ARG_ERROR="不明なオプションです: ${1}"
      break
      ;;
    *)
      # 2 つ目の位置引数を黙って捨てると、'merge-cleanup.sh 12 34' が 1 つ目の
      # 番号に対する破壊的処理として走る。打ち間違いを削除の前に止める。
      if [ -n "$PR_NUM" ]; then
        ARG_ERROR="PR 番号は 1 つだけ指定してください: '${PR_NUM}' と '${1}'"
        break
      fi
      PR_NUM="$1"
      ;;
  esac
  shift
done

if [ -n "$ARG_ERROR" ]; then
  echo "❌ ${ARG_ERROR}" >&2
  print_usage >&2
  exit 1
fi

if [ -z "$PR_NUM" ] || ! [[ "$PR_NUM" =~ ^[0-9]+$ ]]; then
  echo "❌ PR 番号を指定してください（例: merge-cleanup.sh 1234）" >&2
  echo "   PR 番号無しだと delete_branch_on_merge=false な repo でリモートブランチが残ります。" >&2
  print_usage >&2
  exit 1
fi

# temp はディレクトリ 1 つにまとめ、trap で確実に回収する
# （コマンド置換内で配列に追記する方式はサブシェルで消えるため使わない）
WORK_TMP="$(mktemp -d)" || die "mktemp -d に失敗しました"
trap 'rm -rf "$WORK_TMP"' EXIT

if [ -n "$github_input" ]; then
  mc_file_lib="$(CDPATH='' cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/lib/github-input.sh" || exit 2
  [ -f "$mc_file_lib" ] && [ -r "$mc_file_lib" ] || { echo 'github-input: helper missing' >&2; exit 2; }
  github_shebang=""
  IFS= read -r github_shebang <"$mc_file_lib" || true
  case "$github_shebang" in *$'\r') echo 'github-input: helper shebang must use LF' >&2; exit 2 ;; esac
  # shellcheck source=lib/github-input.sh
  . "$mc_file_lib" || exit 2
  github_input_is_absolute "$github_input" || { _github_input_error index '--github-input must be absolute'; exit 2; }
  github_repository="$(_github_input_repository)" || exit 2
  printf '{}\n' >"$WORK_TMP/github-position.json"
else
  command -v gh >/dev/null 2>&1 || die "gh CLI が必要です（https://cli.github.com/）"
fi
command -v jq >/dev/null 2>&1 || die "jq が必要です"

# リモート削除の共通関数: --force-with-lease で「期待 OID のときだけ」削除する。
# 削除 push はコード変更を運ばないため SKIP_SIMPLE_GIT_HOOKS=1 HUSKY=0 を付ける
# （consumer の simple-git-hooks / husky のフルゲートを起動しない。husky v9 の runner
# `.husky/_/h` は HUSKY=0 で本体を呼ばずに exit 0 する）。
# core.hooksPath の一時無効化と --no-verify は他の guard まで落とすので使わない。
# 戻り値 0=削除 / 2=既に無い / 3=lease 拒否（競合 push あり） / 1=その他失敗
delete_remote_branch_with_lease() {
  # $1: branch / $2: expected OID
  local branch="$1" expected="$2" out="" remote_out="" remote_err="" remote_stderr="" remote_oid=""
  # エラーメッセージの文言照合があるため LC_ALL=C でロケール固定
  if out="$(LC_ALL=C SKIP_SIMPLE_GIT_HOOKS=1 HUSKY=0 git push --force-with-lease="refs/heads/$branch:$expected" \
      origin ":refs/heads/$branch" 2>&1)"; then
    return 0
  fi
  if grep -qE 'remote ref does not exist' <<<"$out"; then
    return 2
  fi
  if grep -qE 'stale info|\[rejected\]' <<<"$out"; then
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

dry_run_skip() {
  # dry-run で見送った操作を 1 行で示す。**ガードの判定はこの関数を通さない** —
  # 通すと dry-run だけ判定が変わり、「実行時と同じ判定」という契約が壊れる。
  printf '  [dry-run] 実行しません: %s\n' "$*"
}

# 「削除 push したらこの ref は消えるのか」を副作用なしで判定する。
# 削除は --force-with-lease=<ref>:<PR head OID> なので、origin 側の ref が
# 無い / OID が違えば**push しても消えない**。headRefOid を取得できたことだけを根拠に
# 削除対象と書くと、再利用された同名ブランチや既に消えた ref まで「実行時は消える」と
# 過剰に予告することになる。判定基準はマージ後手順（skills/merge-cleanup/SKILL.md と
# docs-template/05-operations/deployment/git-workflow.md の「削除の前に、残っている ref が
# その PR の head と同一であることを確認する」）と同じで、実装をその規範へ揃える。
# read-only の ls-remote だけを使い、ref は 1 つも書き換えない。
# dry-run の予告と実行時の Step 4 の両方がこの関数を通る（実在判定を 1 つに保つ。
# 実行時は missing / mismatch なら push 自体を行わない — 公開 ff-dev-toolkit#137）。
# stdout: "match<TAB><現OID>" / "mismatch<TAB><現OID>" / "missing<TAB>" / "error<TAB><詳細>"
remote_delete_verdict() {
  # $1: branch / $2: 期待 OID
  local branch="$1" expected="$2" out="" rc=0 oid=""
  local err="$WORK_TMP/remote_delete_verdict_error"
  # --exit-code は「ref なし」を 2 で返す。通信・認証の失敗（128 等）と区別しないと、
  # 出力が空になるだけの失敗を「消えている」と読んでしまう。
  set +e
  out="$(LC_ALL=C git ls-remote --exit-code --heads origin "refs/heads/$branch" 2>"$err")"
  rc=$?
  set -e
  case "$rc" in
    0)
      oid="$(printf '%s\n' "$out" | awk 'NR == 1 { print $1 }')"
      if [ "$oid" = "$expected" ]; then
        printf 'match\t%s\n' "$oid"
      else
        printf 'mismatch\t%s\n' "$oid"
      fi
      ;;
    2) printf 'missing\t\n' ;;
    *) printf 'error\t%s\n' "$(tr '\n' ' ' < "$err")" ;;
  esac
}

# dry-run の仮想 prune。実行時は Step 3 / Step 4 の `fetch --prune` と Step 4 の
# リモート削除によって、**今は [gone] ではないローカルブランチが新たに [gone] になり、
# その worktree ごと Step 5 で消える**。dry-run は prune も削除もしないので、素の
# `upstream:track` だけを見ると連鎖の予告が実際の削除より少なくなる — --dry-run の
# 唯一の価値が「何が壊れるかを先に見せる」ことである以上、予告が実際より少ないのは
# 最も危険な壊れ方で、受け入れ条件（削除対象が一覧で出力される）も満たせない。
# 副作用なしで同じ集合を作る:
#   (a) Step 4 が削除する ref を追跡しているブランチ
#   (b) origin から既に消えている ref を追跡しているブランチ（実行時は prune で [gone]）
# ref は 1 つも書き換えない（read-only の ls-remote だけを使う）。
# stdout: 新たに [gone] になるブランチ名（1 行 1 本）。取得に失敗したら非 0 を返す。
dry_virtual_prune_gone_branches() {
  local origin_refs="$WORK_TMP/dry_origin_heads.list"
  local ls_out="" dbranch="" dupstream="" dtrack="" dremote=""
  if ! ls_out="$(LC_ALL=C git ls-remote --heads origin 2>&1)"; then
    printf '%s\n' "$ls_out" > "$WORK_TMP/dry_virtual_prune_error"
    return 1
  fi
  printf '%s\n' "$ls_out" | awk -F'\t' 'NF > 1 { print $2 }' | LC_ALL=C sort -u > "$origin_refs"
  while IFS="$(printf '\t')" read -r dbranch dupstream dtrack; do
    [ -n "$dbranch" ] || continue
    # 既に [gone] のものは呼び出し元の一覧に載っている（二重計上しない）
    [ "$dtrack" = "[gone]" ] && continue
    case "$dupstream" in
      refs/remotes/origin/*) ;;
      # upstream 無し / origin 以外の remote は `fetch --prune origin` の対象外
      *) continue ;;
    esac
    dremote="refs/heads/${dupstream#refs/remotes/origin/}"
    if [ "$PR_REMOTE_RESULT" = "would_delete" ] && [ "$dremote" = "refs/heads/$PR_HEAD" ]; then
      printf '%s\n' "$dbranch"
      continue
    fi
    if ! grep -qxF "$dremote" "$origin_refs"; then
      printf '%s\n' "$dbranch"
    fi
  done < <(git for-each-ref --format='%(refname:short)%09%(upstream)%09%(upstream:track)' refs/heads/)
  return 0
}

if [ "$DRY_RUN" = "1" ]; then
  echo "🔎 dry-run: 何も削除しません。削除・switch・pull・fetch --prune・hook 実行を見送り、判定だけを実行時と同じ条件で行います。"
fi

REPO_ROOT="$(git rev-parse --show-toplevel)" || die "git リポジトリ内で実行してください"

# 集計用（bash 3.2 の set -u では空配列の "${arr[@]}" 展開がエラーになるため、
# 参照時は必ず ${#arr[@]} でガードする）
DELETED_BRANCHES=()
DELETED_AGENT_BRANCHES=()
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

# 削除を含む処理（Step 0.6 から Step 7.5）は scripts/lib/merge-cleanup-*.sh が行う。
# 入口はここ（削除より前）で 1 回だけ source する。順序は分割前の Step 順。
# 読めないときは exit 1 で止まる（PARTIAL の 2 ではない）。この時点では何も削除していない。
_mc_dir="${BASH_SOURCE[0]%/*}/lib"
# shell-quote.sh は復旧コマンドの案内を組み立てる共有 helper（各 Step が使うので最初に読む）
MC_PARTS=(
  "${_mc_dir}/shell-quote.sh"
  "${_mc_dir}/merge-cleanup-pre.sh"
  "${_mc_dir}/merge-cleanup-remote.sh"
  "${_mc_dir}/merge-cleanup-local.sh"
)
mc_refuse_part() { # <理由> <対象のパス>
  {
    echo "❌ ff-dev-toolkit更新後にこのskillを再呼び出してください（merge-cleanup.sh の構成ファイル${1}）"
    echo "   対象: ${2}"
    echo "   cache を手で直さず、plugin を更新・再導入してから skill を呼び直してください。"
    echo "   別のインストール領域へ切り替えて実行しないこと — version混在と未リリースWIPの実行になります。"
    echo "   まだ何も削除していません。"
  } >&2
  exit 1
}
if [[ -L "${_mc_dir}" || ! -d "${_mc_dir}" ]]; then
  mc_refuse_part "の置き場が通常のディレクトリではないか symlink です" "${_mc_dir}"
fi
for _mc_part in "${MC_PARTS[@]}"; do
  if [[ -L "${_mc_part}" ]]; then
    mc_refuse_part "が symlink です" "${_mc_part}"
  elif [[ ! -f "${_mc_part}" ]]; then
    mc_refuse_part "がありません" "${_mc_part}"
  elif [[ ! -s "${_mc_part}" ]]; then
    mc_refuse_part "が 0 バイトです" "${_mc_part}"
  elif [[ ! -r "${_mc_part}" ]]; then
    mc_refuse_part "を読み取れません" "${_mc_part}"
  fi
  _mc_part_last="$(awk 'NF { l = $0 } END { print l }' "${_mc_part}" 2>/dev/null)" || _mc_part_last=""
  if [[ "${_mc_part_last}" != "_mc_part_loaded=\"${_mc_part##*/}\"" ]]; then
    mc_refuse_part "が末尾まで読めていません（最後の行が読み込み完了の印ではありません）" "${_mc_part}"
  fi
  _mc_part_loaded=""
  # shellcheck source=/dev/null
  source "${_mc_part}"
  if [[ "${_mc_part_loaded}" != "${_mc_part##*/}" ]]; then
    mc_refuse_part "が末尾まで読めていません（読み込み完了の印がありません）" "${_mc_part}"
  fi
done
unset _mc_dir _mc_part _mc_part_last _mc_part_loaded
unset -f mc_refuse_part

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
# dry-run では「削除した」と書けない。同じ行を両方で使い回すため動詞だけ差し替える
# （別の報告ブロックを書き起こすと、項目が片方にだけ足される形の乖離が起きる）。
DELETED_LABEL="削除した"
LEFTOVER_LABEL="自動削除した"
if [ "$DRY_RUN" = "1" ]; then
  DELETED_LABEL="削除対象の"
  LEFTOVER_LABEL="削除対象の"
  echo "**🔎 dry-run**: 以下は「実行した場合に削除されるもの」で、今回は 1 つも削除していません。"
  echo ""
fi
# 「リモートブランチを削除したか」は完了報告で必ず明示する（Issue #758。`gh pr merge`
# の成否と混同されると、delete_branch_on_merge=false のリポジトリで取り残しに気付けない）
case "$PR_REMOTE_RESULT" in
  deleted|deleted_by_leftover_retry) PR_REMOTE_HUMAN="削除した" ;;
  already_missing|already_missing_at_leftover_retry) PR_REMOTE_HUMAN="既に存在しない（今回の削除は不要）" ;;
  skipped_fork) PR_REMOTE_HUMAN="削除していない（fork PR のため origin 側は対象外）" ;;
  skipped_open_reuse|skipped_lease_rejected|skipped_lease_rejected_at_leftover_retry) PR_REMOTE_HUMAN="削除していない（保護。上の警告を参照）" ;;
  would_delete) PR_REMOTE_HUMAN="削除していない（dry-run。実行時は削除する）" ;;
  *) PR_REMOTE_HUMAN="削除していない（要確認。上の警告 / 失敗項目を参照）" ;;
esac
echo "- 対象 PR のリモートブランチ ($PR_HEAD): $PR_REMOTE_RESULT — リモートブランチの削除: ${PR_REMOTE_HUMAN}"
echo "- ${DELETED_LABEL}[gone] ローカルブランチ: ${#DELETED_BRANCHES[@]} 本${DELETED_BRANCHES[*]+ (${DELETED_BRANCHES[*]})}"
echo "- ${DELETED_LABEL}エージェントブランチ: ${#DELETED_AGENT_BRANCHES[@]} 本${DELETED_AGENT_BRANCHES[*]+ (${DELETED_AGENT_BRANCHES[*]})}"
echo "- ${DELETED_LABEL}worktree: ${#DELETED_WORKTREES[@]} 個${DELETED_WORKTREES[*]+ (${DELETED_WORKTREES[*]})}"
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
  echo "- ${LEFTOVER_LABEL}リモート取り残し: ${#DELETED_LEFTOVERS[@]} 本${DELETED_LEFTOVERS[*]+ (${DELETED_LEFTOVERS[*]})}"
else
  echo "- リモート取り残し検証: スキップ（ガード情報の取得失敗）"
fi
echo "- 現在のブランチ: $CURRENT_BRANCH"

if [ "$NO_SWITCH_MODE" = "1" ]; then
  # 掃除モードで意図的に見送った項目は、失敗（PARTIAL）ではなく名指しの未実施として
  # 報告する（#749: 中断せず完遂しつつ、やらなかったことを報告から欠落させない）
  echo ""
  echo "**ℹ️ switch なし掃除モードでの未実施項目（呼び出し元が '${CURRENT_BRANCH_BEFORE:-（detached HEAD）}' を保持）**:"
  echo "  - ${PR_BASE} への復帰と pull --ff-only（呼び出し元と別 worktree の HEAD を変更しないため）"
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
if [ "$DRY_RUN" = "1" ]; then
  echo "次のステップ: 上の一覧を確認し、問題なければ --dry-run を外して 'merge-cleanup.sh ${PR_NUM}' を実行する"
else
  echo "次のステップ: /ace-curate $PR_NUM で知見をプレイブックへ反映"
fi
exit "$EXIT_CODE"
