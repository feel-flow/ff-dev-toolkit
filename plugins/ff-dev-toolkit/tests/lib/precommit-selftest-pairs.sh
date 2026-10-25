#!/usr/bin/env bash
# /pre-commit-check の変更 suite に対する selftest を名指し・単体実行する。
# selftest_pairs_scan REPO: 0=全件成功/none、1=失敗、2=未検査。
# 対は run-all.sh の高速除外と同じ「-selftest 接尾辞と consumer の実在」で導出する。
# tests/lib や suite 内の fixture からの依存推測は行わない。bash 3.2 対応。
selftest_pairs_scan() {
  local repo="${1:-.}" tmp meta path status name pair indexed_pair rc skip_rc hit=0 result=0
  repo="$(git -C "$repo" rev-parse --show-toplevel 2>/dev/null)" || {
    echo 'selftest 未検査: リポジトリルートを取得できません' >&2; return 2;
  }
  tmp="$(mktemp -d)" || { echo 'selftest 未検査: 一時領域を作れません' >&2; return 2; }
  rc=0
  git -C "$repo" diff --cached --raw -z --no-abbrev --no-relative --no-renames \
    --diff-filter=ACMRTU >"$tmp/raw" 2>"$tmp/err" || rc=$?
  if [ "$rc" -ne 0 ]; then
    echo 'selftest 未検査: staged の一覧を取得できません' >&2
    rm -rf "$tmp"; return 2
  fi
  : >"$tmp/pairs"
  while IFS= read -r -d '' meta || [ -n "$meta" ]; do
    path=''
    if ! IFS= read -r -d '' path; then
      echo 'selftest 未検査: staged のパス終端が不正です' >&2
      rm -rf "$tmp"; return 2
    fi
    if [[ ! "$meta" =~ ^:[0-7]{6}\ [0-7]{6}\ [[:xdigit:]]+\ [[:xdigit:]]+\ [ACMRTU]$ ]] || [ -z "$path" ]; then
      echo 'selftest 未検査: staged の書式が不正です' >&2
      rm -rf "$tmp"; return 2
    fi
    status="${meta##* }"
    if [ "$status" = U ]; then
      echo 'selftest 未検査: 未解決の衝突があります' >&2
      rm -rf "$tmp"; return 2
    fi
    case "$path" in
      plugins/ff-dev-toolkit/tests/*/verify.sh)
        name="${path#plugins/ff-dev-toolkit/tests/}"; name="${name%/verify.sh}"
        case "$name" in */*) continue ;; esac ;;
      *) continue ;;
    esac
    pair="plugins/ff-dev-toolkit/tests/${name}-selftest/verify.sh"
    # 逆向きに -selftest を落とすと staged consumer に戻り、両 verify が実在する。
    if [ -f "$repo/$path" ] && [ -f "$repo/$pair" ]; then
      printf '%s\0%s\0' "$path" "$pair" >>"$tmp/pairs"
    else
      # 未 stage の削除も拾う。HEAD ではなく index を見るので、stage 済みの削除は対象なし。
      indexed_pair="$(git --literal-pathspecs -C "$repo" ls-files --stage -- "$pair" 2>"$tmp/err")" || {
        echo "selftest 未検査: 対の index を読めません: ${pair}" >&2
        rm -rf "$tmp"; return 2
      }
      if [ -n "$indexed_pair" ] || [ -e "$repo/$pair" ] || [ -L "$repo/$pair" ]; then
        echo "selftest 未検査: 対の verify.sh を読めません: ${pair}" >&2
        rm -rf "$tmp"; return 2
      fi
    fi
  done <"$tmp/raw"
  while IFS= read -r -d '' path && IFS= read -r -d '' pair; do
    hit=$((hit + 1))
    printf 'selftest command: bash %q\n' "$repo/$pair"
    # 対が未追跡/未stageの修正だと、commit 後に同じ成功を再現できない。
    if ! git --literal-pathspecs -C "$repo" ls-files --error-unmatch -- "$pair" >/dev/null 2>&1 \
      || ! git --literal-pathspecs -C "$repo" diff --quiet -- "$path" "$pair" \
      || [ ! -r "$repo/$pair" ]; then
      printf 'selftest 未検査: index と一致する対を読めません: %s\n' "$pair" >&2
      result=2; continue
    fi
    rc=0
    ( cd "$repo" || exit 2; bash "$repo/$pair" ) >"$tmp/out" 2>"$tmp/err" || rc=$?
    cat "$tmp/out"; cat "$tmp/err" >&2
    if [ "$rc" -ne 0 ]; then
      printf 'selftest result: FAIL rc=%s %s\n' "$rc" "$pair"
      if [ "$result" -eq 0 ]; then result=1; fi
    else
      skip_rc=0
      grep -Eq '^[[:space:]]*○[[:space:]]+skip([[:space:]:]|$)' "$tmp/out" "$tmp/err" || skip_rc=$?
      if [ "$skip_rc" -ne 1 ] || ! git --literal-pathspecs -C "$repo" diff --quiet -- "$path" "$pair"; then
        printf 'selftest 未検査: SKIP・結果読み取り失敗・実行中の内容変更: %s\n' "$pair" >&2
        result=2
      else
        printf 'selftest result: PASS %s\n' "$pair"
      fi
    fi
  done <"$tmp/pairs"
  rm -rf "$tmp"
  if [ "$hit" -eq 0 ]; then echo 'selftest-pairs: none';
  elif [ "$result" -eq 0 ]; then printf 'selftest-pairs: ok %s\n' "$hit"; fi
  return "$result"
}
