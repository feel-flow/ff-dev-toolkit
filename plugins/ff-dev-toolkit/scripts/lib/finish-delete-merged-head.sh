#!/usr/bin/env bash
# finish.sh が生成する MERGE_COMMAND へ本文を埋め込む。実行時は plugin の配置に依存しない。
# 引数は consumer の物理 root、PR head の名前、照合済み head OID。bash 3.2 互換。
set -uo pipefail

if [[ $# -ne 3 ]]; then
  echo "head 削除の引数が不正です（root / branch / OID が必要）" >&2
  exit 2
fi
repo_root="$1"; branch="$2"; expected="$3"
ref="refs/heads/$branch"
if ! git check-ref-format "$ref" || ! [[ "$expected" =~ ^([0-9a-fA-F]{40}|[0-9a-fA-F]{64})$ ]]; then
  echo "head 削除の ref / OID が不正です。削除しません" >&2
  exit 2
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

remote_oid=""; verdict=0
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
