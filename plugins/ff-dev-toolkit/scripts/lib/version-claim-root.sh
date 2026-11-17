# shellcheck shell=bash
# version claim の対象 repo を決める共有規則（source 専用。単体の入口は作らない）。
# `scripts/update-version-claim.sh`（claim の生成）と `scripts/check-version-claims.sh`（claim の検証）
# の両方がこの 1 関数で対象 repo を決める。生成と検証で別の repo を見ると、生成側は別の checkout の
# 文書を見て `CLAIM_UNCHANGED` を返し、検証側だけが不一致で止まる（OBS-130、Issue `#2818`）。
#
# ff_claim_resolve_root <明示した root（空なら未指定）> <起動したスクリプトの directory>
#   rc 0: 対象 repo の最上位（物理パス）を stdout へ 1 行で出す
#   rc 2: 決められない（理由と次の一手を stderr へ出す）
#
# 規則:
#   1. `--root` を明示した回は、その値だけで決める（cwd もスクリプトの位置も見ない）。値は repo の
#      最上位でなければ止める。下位の directory を受けると `.version-claims` の在否を取り違え、
#      検証側は「contract 未導入」のスキップ（緑）へ倒れる。呼び出し元から受け継いだ GIT_DIR /
#      GIT_WORK_TREE が別の repository を指している回も止める。以後の `git -C <root>` は --root では
#      なくその環境の repository を読むので、指定した worktree の文書に別の worktree の HEAD・index が
#      混ざる（同じ repository を指す値は通す。その repo の git hook の中など）。
#   2. 明示しない回は cwd の repo を対象にする（従来どおり）。ただし、起動したスクリプトの実体が
#      「同じリポジトリの別の worktree」にあるときは止めて、両方の最上位と `--root` を名指す。
#      worktree のスクリプトを絶対パスで呼んだのに cwd が別の checkout へ戻っている形（OBS-130）と、
#      このリポジトリの checkout から読み込んだプラグインを別の worktree で使う形は、呼び出しの形から
#      どちらを対象にしたいかを決められない。黙って cwd 側を対象にすると、前者では別の checkout の
#      文書を見た `CLAIM_UNCHANGED` が成功として返る。
#   3. スクリプトの実体を repo と判定できない回（repo の外にある導入先のプラグインのスナップショット、
#      safe.directory の拒否など）と、別のリポジトリにある回（marketplace の clone・テストの fixture を
#      cwd にした起動）は比べる相手が無いので、従来どおり cwd の repo を対象にする。導入先の通常の
#      起動はこの形である。
#
# パスはすべて物理パス（`cd -P` / `pwd -P`）で比べる。論理パスと `git rev-parse --show-toplevel` の
# 物理パスを混ぜると、symlink を挟む作業場所（macOS の /tmp など）で同じ repo を別物と読む（ACE-876-3）。
# `--git-common-dir` の相対・絶対の別は判定せず、問い合わせた directory へ移ってから `cd` で解決する
# （絶対パスの綴りがホストで違う Windows の Git Bash でも同じ式で通る）。

ff_claim_physical_dir() { # <directory> → 物理パスを stdout へ / 解決できなければ非 0
  (CDPATH='' cd -P -- "$1" 2>/dev/null && pwd -P)
}

# 呼び出し元の GIT_DIR などを外して問い合わせる。スクリプトの実体の側と、--root そのものの判定に使う
# （git hook の中から呼ばれた回に、環境の repo を問い合わせ先の repo と取り違えないため。cwd の側は
# 従来どおり環境に従う）。
ff_claim_script_git() { # <directory> <git の引数...>
  (
    unset GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR
    CDPATH='' cd -P -- "$1" 2>/dev/null || exit 128
    shift
    git "$@"
  )
}

ff_claim_common_dir_in() { # <directory> <git-common-dir の出力> → 物理パス
  (CDPATH='' cd -P -- "$1" 2>/dev/null && CDPATH='' cd -P -- "$2" 2>/dev/null && pwd -P)
}

ff_claim_resolve_root() {
  local explicit="$1" script_dir="$2" canonical top own_top env_git_dir own_git_dir cwd_top cwd_common script_top script_common
  if [[ -n "$explicit" ]]; then
    canonical="$(ff_claim_physical_dir "$explicit")" && [[ -n "$canonical" ]] || {
      echo "✗ --root の directory を解決できません: ${explicit}" >&2
      return 2
    }
    # 最上位は環境を外して判定する（GIT_DIR だけが立った環境では git が cwd を最上位とみなし、
    # 下位の directory でも最上位に見える）
    own_top="$(ff_claim_script_git "$canonical" rev-parse --show-toplevel 2>/dev/null)" && [[ -n "$own_top" ]] || {
      echo "✗ --root が git repository ではありません: ${canonical}" >&2
      return 2
    }
    own_top="$(ff_claim_physical_dir "$own_top")" && [[ -n "$own_top" ]] || {
      echo "✗ --root の repository 最上位を正規化できません: ${canonical}" >&2
      return 2
    }
    # 綴りでなく実体で比べる（大文字小文字を区別しない macOS の既定のディスクでは、綴りの違う
    # 指定も同じ directory を指す）。以後は git が返した綴りを使う
    [[ "$own_top" == "$canonical" || "$own_top" -ef "$canonical" ]] || {
      echo "✗ --root には repository の最上位を指定してください: 指定=${canonical} 最上位=${own_top}" >&2
      return 2
    }
    # 環境込み（以後の git -C <root> が読む repository）と環境抜き（--root そのもの）で、最上位と
    # git directory の両方を比べる
    top="$(git -C "$own_top" rev-parse --show-toplevel 2>/dev/null)" && [[ -n "$top" ]] \
      && top="$(ff_claim_physical_dir "$top")" && [[ -n "$top" ]] \
      && env_git_dir="$(git -C "$own_top" rev-parse --absolute-git-dir 2>/dev/null)" && [[ -n "$env_git_dir" ]] \
      && env_git_dir="$(ff_claim_physical_dir "$env_git_dir")" && [[ -n "$env_git_dir" ]] \
      && own_git_dir="$(ff_claim_script_git "$own_top" rev-parse --absolute-git-dir 2>/dev/null)" && [[ -n "$own_git_dir" ]] \
      && own_git_dir="$(ff_claim_physical_dir "$own_git_dir")" && [[ -n "$own_git_dir" ]] || {
      echo "✗ --root の git directory を判定できません: ${own_top}" >&2
      return 2
    }
    [[ "$top" == "$own_top" && "$env_git_dir" == "$own_git_dir" ]] || {
      {
        echo "✗ 環境変数 GIT_DIR / GIT_WORK_TREE が --root と別の repository を指しています（git hook などから受け継いだ値）"
        echo "   --root: ${own_top}（git directory: ${own_git_dir}）"
        echo "   環境変数が指す先: ${top}（git directory: ${env_git_dir}）"
        echo "   GIT_DIR / GIT_WORK_TREE を外して呼び直してください"
      } >&2
      return 2
    }
    printf '%s\n' "$own_top"
    return 0
  fi
  cwd_top="$(git rev-parse --show-toplevel 2>/dev/null)" && [[ -n "$cwd_top" ]] || {
    echo "✗ git repository root を解決できません（cwd: ${PWD}）。対象の repository を --root で指定してください" >&2
    return 2
  }
  cwd_top="$(ff_claim_physical_dir "$cwd_top")" && [[ -n "$cwd_top" ]] || {
    echo "✗ git repository root を正規化できません（cwd: ${PWD}）" >&2
    return 2
  }
  # スクリプトの実体を repo と判定できなければ比べる相手が無い（規則 3）
  if ! script_top="$(ff_claim_script_git "$script_dir" rev-parse --show-toplevel 2>/dev/null)" || [[ -z "$script_top" ]]; then
    printf '%s\n' "$cwd_top"
    return 0
  fi
  script_top="$(ff_claim_physical_dir "$script_top")" && [[ -n "$script_top" ]] || {
    echo "✗ 起動したスクリプトの repository 最上位を正規化できません: ${script_dir}" >&2
    return 2
  }
  if [[ "$script_top" == "$cwd_top" ]]; then
    printf '%s\n' "$cwd_top"
    return 0
  fi
  # 最上位が違う。同じリポジトリの別 worktree かどうかは common dir で決める。両方を repo と
  # 判定できたのに common dir を判定できない回は、cwd 側へ倒さず止める（取り違えたまま緑を返すのが、
  # この関数の防ぐ失敗そのもの）。
  cwd_common="$(git rev-parse --git-common-dir 2>/dev/null)" && [[ -n "$cwd_common" ]] \
    && cwd_common="$(ff_claim_common_dir_in "$PWD" "$cwd_common")" && [[ -n "$cwd_common" ]] || {
    echo "✗ cwd の repository の git common dir を判定できません（cwd の repo: ${cwd_top}）。対象の repository を --root で指定してください" >&2
    return 2
  }
  script_common="$(ff_claim_script_git "$script_dir" rev-parse --git-common-dir 2>/dev/null)" && [[ -n "$script_common" ]] \
    && script_common="$(ff_claim_common_dir_in "$script_dir" "$script_common")" && [[ -n "$script_common" ]] || {
    echo "✗ 起動したスクリプトの repository の git common dir を判定できません（スクリプトの repo: ${script_top}）。対象の repository を --root で指定してください" >&2
    return 2
  }
  if [[ "$script_common" != "$cwd_common" ]]; then
    printf '%s\n' "$cwd_top"
    return 0
  fi
  {
    echo "✗ 対象の repository を決められません: cwd と起動したスクリプトが、同じリポジトリの別の worktree にあります"
    echo "   cwd の repo: ${cwd_top}"
    echo "   スクリプトの repo: ${script_top}"
    echo "   対象にする worktree の最上位を --root で明示して呼び直してください"
    echo "   （cwd 側なら --root \"${cwd_top}\"、スクリプト側なら --root \"${script_top}\"）"
  } >&2
  return 2
}
