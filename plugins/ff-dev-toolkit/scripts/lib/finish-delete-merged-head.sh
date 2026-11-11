#!/usr/bin/env bash
# finish.sh が生成する MERGE_COMMAND へ本文を埋め込む。実行時は plugin の配置に依存しない。
# 引数は consumer の物理 root、PR head の名前、照合済み head OID。bash 3.2 互換。
#
# source された回は保護判定の関数だけを定義する。直接実行と bash -c 埋め込みは削除を行う。
# bash -c では BASH_SOURCE[0] が未設定になる。set -u の下では ${BASH_SOURCE[0]-} を使う。
# 保護のハードコードと既定の追加パターンは merge-cleanup.sh / merge-cleanup-pre.sh と同じ文字列に固定する。

ff_is_hardcoded_protected_branch() {
  case "$1" in
    develop|main|master|staging/*) return 0 ;;
    *) return 1 ;;
  esac
}

# 一致したパターンを stdout へ返す。一致しなければ非 0。空配列は展開しない。
ff_matched_extra_protect_pattern() {
  local pat=""
  [ "${#ff_protect_extra_patterns[@]}" -gt 0 ] || return 1
  for pat in "${ff_protect_extra_patterns[@]}"; do
    # 非引用はパターンとして glob を効かせる意図的な形（引用すると文字列一致に退化する）
    # shellcheck disable=SC2254
    case "$1" in
      $pat) printf '%s\n' "$pat"; return 0 ;;
    esac
  done
  return 1
}

# 前提: 先に ff_protect_branch_prepare を呼び、追加パターンの配列を作っておく（呼ばないと追加分を見ない）。
ff_is_protected_branch() {
  ff_is_hardcoded_protected_branch "$1" && return 0
  ff_matched_extra_protect_pattern "$1" >/dev/null
}

# 0 = 解釈できた。2 = 設定が不正（削除も skipped-protected も出さない）。
# 空・未設定は release/*。none は追加なし。develop / main / master / staging/* はここでは外さない。
ff_protect_branch_prepare() {
  local raw="${FF_MERGE_CLEANUP_PROTECT_BRANCHES:-}" item="" rest=""
  ff_protect_extra_patterns=()
  if [ -z "$raw" ]; then
    ff_protect_extra_patterns=('release/*')
    return 0
  fi
  if [ "$raw" = "none" ]; then
    return 0
  fi
  rest="${raw}:"
  while [ -n "$rest" ]; do
    item="${rest%%:*}"
    rest="${rest#*:}"
    if [ -z "$item" ]; then
      echo "FF_MERGE_CLEANUP_PROTECT_BRANCHES に空のパターンがあります: '${raw}'（先頭・末尾・連続する ':' を確認。追加の保護を無くす場合は 'none' を指定）" >&2
      return 2
    fi
    case "$item" in
      [[:space:]]*|*[[:space:]])
        echo "FF_MERGE_CLEANUP_PROTECT_BRANCHES のパターンに前後の空白があります: '${item}' — ブランチ名は空白も含めて照合されるため、この指定は意図どおり保護しません" >&2
        return 2
        ;;
      *\[*|*\]*)
        echo "FF_MERGE_CLEANUP_PROTECT_BRANCHES に文字クラス（[...]）を含むパターンがあります: '${item}' — 文字クラスは ':' 区切りと衝突して黙って分断されるため未対応です。プレフィックス glob（release/* など）を使ってください" >&2
        return 2
        ;;
    esac
    ff_protect_extra_patterns+=("$item")
  done
  return 0
}

ff_delete_merged_head_main() {
  set -uo pipefail
  if [[ $# -ne 3 ]]; then
    echo "head 削除の引数が不正です（root / branch / OID が必要）" >&2
    exit 2
  fi
  local repo_root="$1"
  local branch="$2"
  local expected="$3"
  local ref="refs/heads/${branch}"
  local remote_oid=""
  local verdict=0
  if ! git check-ref-format "$ref" || ! [[ "$expected" =~ ^([0-9a-fA-F]{40}|[0-9a-fA-F]{64})$ ]]; then
    echo "head 削除の ref / OID が不正です。削除しません" >&2
    exit 2
  fi
  ff_protect_branch_prepare || exit 2
  if ff_is_protected_branch "$branch"; then
    echo "HEAD_DELETE_RESULT=skipped-protected"
    echo "head は保護ブランチのため削除しません（${ref}）" >&2
    exit 0
  fi

  # rc 0=期待 OID、2=ref 不在、3=別 OID、1=照会失敗・応答不正。
  # --exit-code の 2 だけを不在とし、空出力の通信失敗を成功へ倒さない。
  read_remote_head() {
    local out="" rc=0 actual_ref="" extra=""
    if out="$(LC_ALL=C git -C "$repo_root" ls-remote --exit-code --heads origin "$ref")"; then
      rc=0
    else
      rc=$?
    fi
    case "$rc" in
      0)
        # exact ref を 1 行だけ読む。空・複数行・別 ref・不正 OID は判定不能。
        case "$out" in ''|*$'\n'*) echo "head の照会応答が空か複数行です。削除しません" >&2; return 1 ;; esac
        IFS=$'\t' read -r remote_oid actual_ref extra <<<"$out"
        if [[ "$actual_ref" != "$ref" || -n "$extra" ]] \
          || ! [[ "$remote_oid" =~ ^([0-9a-fA-F]{40}|[0-9a-fA-F]{64})$ ]]; then
          echo "head の照会応答が不正です。削除しません" >&2
          return 1
        fi
        [[ "$remote_oid" == "$expected" ]] || return 3
        return 0 ;;
      2)
        if [[ -n "$out" ]]; then
          echo "head の不在応答に ref が含まれています。削除しません" >&2
          return 1
        fi
        return 2 ;;
      *) echo "head を照会できません（git ls-remote rc=${rc}）。削除しません" >&2; return 1 ;;
    esac
  }

  read_remote_head || verdict=$?
  case "$verdict" in
    2) echo "HEAD_DELETE_RESULT=already-missing"; exit 0 ;;
    3)
      echo "HEAD_DELETE_RESULT=preserved-different-oid"
      echo "head は別 OID へ進んでいます（${ref}: ${remote_oid}）。削除せず保全します" >&2
      exit 0 ;;
    1) exit 1 ;;
  esac

  # 削除 push だけに hook skip を付ける。merge や照会の環境へは export しない。
  if SKIP_SIMPLE_GIT_HOOKS=1 HUSKY=0 git -C "$repo_root" push origin \
    "--force-with-lease=$ref:$expected" ":$ref"; then
    echo "HEAD_DELETE_RESULT=deleted"
    exit 0
  fi

  # 読み取り後に GitHub が自動削除した race と、同名 ref の再利用を実測で区別する。
  # 期待 OID が残る失敗や再照会不能は、merge 成功だけを理由に成功扱いしない。
  verdict=0
  read_remote_head || verdict=$?
  case "$verdict" in
    2) echo "HEAD_DELETE_RESULT=already-missing"; exit 0 ;;
    3)
      echo "HEAD_DELETE_RESULT=preserved-different-oid"
      echo "削除 push の間に head が別 OID へ進みました（${ref}: ${remote_oid}）。保全しました" >&2
      exit 0 ;;
    *) echo "head の削除を完了できません。merge の結果と残存 ref を確認してください" >&2; exit 1 ;;
  esac
}

# source は呼び出し元がパス付き（`. <dir>/finish-delete-merged-head.sh`）で行う前提。末尾一致まで見るのは、
# 別名の script から本文を source した回や bash -c 埋め込み（BASH_SOURCE が空）を main の側へ倒すため。
# スラッシュの無い `. finish-delete-merged-head.sh`（PATH 経由）では main が走り、呼び出し元が exit する。
_ff_dmh_src="${BASH_SOURCE[0]-}"
if [[ -n "$_ff_dmh_src" && "$_ff_dmh_src" != "$0" && "$_ff_dmh_src" == */finish-delete-merged-head.sh ]]; then
  unset _ff_dmh_src
else
  unset _ff_dmh_src
  ff_delete_merged_head_main "$@"
fi
