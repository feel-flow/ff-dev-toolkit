#!/usr/bin/env bash
# /pre-commit-check 手順 8 の種別 F: staged の *.sh が fixture lib の consumer かを判定する。
# git_fixture_consumer_scan REPO: rc 0=判定済み（run / none）、2=未検査。suite は実行しない。
# 判定は index の blob（削除なら HEAD の blob）と、変更・削除前の HEAD の blob の内容で行う。
# 追加・利用開始・利用停止・削除のどれでも consumer 名簿（git-fixture-isolation）がずれうるため。
# 針の語は自分自身が consumer 走査に当たらないよう、文字クラスで分けて書く。bash 3.2 対応。
_git_fixture_consumer_re='ff_git_fixture_[i]nit|lib/git-fixture[.]sh'

# _git_fixture_blob_hits REPO OBJECT TMP: 0=針あり、1=針なし、2=読めない
_git_fixture_blob_hits() {
  local rc=0
  git -C "$1" cat-file blob "$2" >"$3/blob" 2>"$3/err" || return 2
  grep -Eq "$_git_fixture_consumer_re" "$3/blob" || rc=$?
  [ "$rc" -le 1 ] || return 2
  return "$rc"
}

git_fixture_consumer_scan() {
  local repo="${1:-.}" tmp status path rc hits=0 in_head
  repo="$(git -C "$repo" rev-parse --show-toplevel 2>/dev/null)" || {
    echo 'git-fixture 未検査: リポジトリルートを取得できません' >&2; return 2;
  }
  if [ ! -d "$repo/plugins/ff-dev-toolkit/tests" ]; then
    echo 'git-fixture-isolation: none'; return 0
  fi
  tmp="$(mktemp -d)" || { echo 'git-fixture 未検査: 一時領域を作れません' >&2; return 2; }
  rc=0
  # pathspec を渡さない（GIT_GLOB_PATHSPECS / GIT_LITERAL_PATHSPECS で '*.sh' が 0 件になり、
  # 判定済みの none へ倒れる）。*.sh の絞り込みはループ内で行う。
  git -C "$repo" diff --cached --name-status -z --no-renames --no-relative \
    --diff-filter=ACDMRTU >"$tmp/list" 2>"$tmp/err" || rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "git-fixture 未検査: staged の一覧を取得できません: $(cat "$tmp/err")" >&2
    rm -rf "$tmp"; return 2
  fi
  in_head=0
  git -C "$repo" rev-parse -q --verify HEAD >/dev/null 2>&1 && in_head=1
  while IFS= read -r -d '' status; do
    if ! IFS= read -r -d '' path || [ -z "$path" ]; then
      echo 'git-fixture 未検査: staged のパス終端が不正です' >&2
      rm -rf "$tmp"; return 2
    fi
    case "$status" in
      U) case "$path" in *.sh) ;; *) continue ;; esac
         echo "git-fixture 未検査: 未解決の衝突があります: ${path}" >&2
         rm -rf "$tmp"; return 2 ;;
      A|C|D|M|R|T) ;;
      *) echo "git-fixture 未検査: staged の書式が不正です: ${status}" >&2
         rm -rf "$tmp"; return 2 ;;
    esac
    case "$path" in *.sh) ;; *) continue ;; esac
    rc=1
    # 判定器自身は針を持たない（自己一致を避けている）ので、内容ではなくパスで当てる。
    # 判定器の振る舞いを固定するケースは git-fixture-isolation にある。
    if [ "$path" = plugins/ff-dev-toolkit/tests/lib/precommit-git-fixture.sh ]; then
      rc=0
    elif [ "$status" != D ]; then
      rc=0; _git_fixture_blob_hits "$repo" ":${path}" "$tmp" || rc=$?
    fi
    # 変更・削除の回は HEAD 側も見る（利用をやめた・消した consumer も名簿をずらす）
    if [ "$rc" -eq 1 ] && [ "$in_head" -eq 1 ] && [ "$status" != A ]; then
      # A 以外は HEAD に在るはずなので、引けないのは異常（未検査）
      if git -C "$repo" cat-file -e "HEAD:${path}" 2>/dev/null; then
        rc=0; _git_fixture_blob_hits "$repo" "HEAD:${path}" "$tmp" || rc=$?
      else
        rc=2
      fi
    fi
    case "$rc" in
      0) hits=$((hits + 1)); printf 'git-fixture consumer: %s\n' "$path" ;;
      1) ;;
      *) echo "git-fixture 未検査: blob を読めません: ${path}" >&2
         rm -rf "$tmp"; return 2 ;;
    esac
  done <"$tmp/list"
  rm -rf "$tmp"
  if [ "$hits" -gt 0 ]; then
    printf 'git-fixture-isolation: run %s\n' "$hits"
  else
    echo 'git-fixture-isolation: none'
  fi
  return 0
}
