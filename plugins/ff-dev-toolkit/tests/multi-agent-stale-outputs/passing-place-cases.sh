#!/usr/bin/env bash
# 空振り検出: 案内の検査を外して固定文に戻すと、通るパスの再検査か
# 案内不能の文言が赤。祖先を名乗らない拒否に戻すと祖先名の検査が赤。
# 所有 marker の一致を外すと、別リポジトリの marker を案内する。
# mktemp のパスを物理パスへ戻さないと、symlink の /tmp では祖先検査が無言で落ちる。
# pipefail-inherited: verify.sh が set -euo pipefail の下で source する。
run_passing_place_cases() {
  local work="$TMP/passing-place" bad_dir good_dir repo log suggested prepared
  local foreign foreign_repo home_candidate
  rm -rf "$work"
  mkdir -p "$work"
  # mktemp の 700 の下に 777 を置くと、上の本人専用ディレクトリが危険を打ち消す。
  # /tmp 直下の 777 だけが、上に本人専用の祖先を持たない拒否になる。
  # macOS の /tmp は /private/tmp への symlink なので、検査へ渡す前に物理パスへ戻す。
  bad_dir="$(mktemp -d /tmp/ff-boundary-bad.XXXXXX)"
  good_dir="$(mktemp -d /tmp/ff-boundary-good.XXXXXX)"
  bad_dir="$(CDPATH='' cd -P -- "$bad_dir" && pwd -P)"
  good_dir="$(CDPATH='' cd -P -- "$good_dir" && pwd -P)"
  repo="$bad_dir/repo"
  mkdir -p "$repo"
  repo="$(CDPATH='' cd -P -- "$repo" && pwd -P)"
  home_candidate="$good_dir/.config/ff-dev-toolkit/tmp/review-output"

  if ff_review_output_windows || [[ ! -d /tmp || ! -k /tmp || ! -w /tmp ]]; then
    ok "POSIX の共有一時領域の案内は、sticky で書ける /tmp があるときだけ測る"
  else
    chmod 777 "$bad_dir"
    log="$work/named.log"
    (
      HOME="$good_dir"
      ff_review_output_ancestors "$bad_dir/repo/out" "$repo"
    ) >"$log" 2>&1 || true
    suggested="$(sed -n 's/^       Next: --output-dir \(.*\) passes the output boundary (checked before this line was printed)\.$/\1/p' "$log")"
    prepared=""
    if [[ -n "$suggested" ]]; then
      prepared="$(IN_GIT_REPO=false ff_review_output_prepare "$repo" "$suggested" true review 2>"$work/prepare.err")" || prepared=""
    fi
    if grep -qF "ancestor is writable by another user: ${bad_dir}" "$log" \
      && [[ "$suggested" == "$home_candidate" ]] \
      && [[ -d "$suggested" && ! -e "$repo/.review-results" ]] \
      && [[ "$prepared" == "$suggested" ]] \
      && FF_REVIEW_OUTPUT_SUGGESTING=true ff_review_output_ancestors "$suggested" >/dev/null 2>&1 \
      && FF_REVIEW_OUTPUT_SUGGESTING=true ff_review_output_private "$suggested" true >/dev/null 2>&1; then
      ok "拒否文は危険な祖先と、検査を通ったディレクトリを名指しする"
    else
      bad "通る置き場の案内が検査と一致しない: ${suggested:-<none>}"
      sed 's/^/    | /' "$log" >&2
      [[ ! -s "$work/prepare.err" ]] || sed 's/^/    prep| /' "$work/prepare.err" >&2
    fi

    log="$work/implement.log"
    (
      HOME="$good_dir"
      ff_review_output_ancestors "$bad_dir/repo/out" "$repo" implement
    ) >"$log" 2>&1 || true
    if grep -qF 'no directory that passes the output boundary could be named' "$log" \
      && ! grep -qF "Next: --output-dir ${home_candidate}" "$log"; then
      ok "implement はリポジトリの外にある置き場を案内しない"
    else
      bad "implement がリポジトリの外を案内した"
      sed 's/^/    | /' "$log" >&2
    fi

    foreign="$bad_dir/foreign"
    mkdir -p "$foreign"
    foreign_repo="$(CDPATH='' cd -P -- "$foreign" && pwd -P)"
    ff_review_output_marker "$foreign_repo" "$home_candidate" > "$home_candidate/.multi-agent-output-owner"
    chmod 600 "$home_candidate/.multi-agent-output-owner"
    log="$work/foreign.log"
    (
      HOME="$good_dir"
      ff_review_output_ancestors "$bad_dir/repo/out" "$repo"
    ) >"$log" 2>&1 || true
    if grep -qF 'no directory that passes the output boundary could be named' "$log" \
      && ! grep -qF "Next: --output-dir ${home_candidate}" "$log" \
      && ! grep -qF "Next: --output-dir ${repo}/.review-results" "$log"; then
      ok "別リポジトリの所有 marker がある置き場は案内しない"
    else
      bad "所有 marker が一致しない置き場を案内した"
      sed 's/^/    | /' "$log" >&2
    fi

    # リポジトリ自体を消すと、祖先の検査が危険な親へ届く前に戻る。
    rm -rf "$good_dir/.config" "$repo/.review-results"
    chmod 777 "$good_dir"
    log="$work/unnamed.log"
    (
      HOME="$good_dir"
      ff_review_output_ancestors "$bad_dir/repo/out" "$repo"
    ) >"$log" 2>&1 || true
    if grep -qF 'no directory that passes the output boundary could be named' "$log" \
      && ! grep -qF 'Next: --output-dir ' "$log" \
      && [[ ! -e "$good_dir/.config" && ! -e "$repo/.review-results" ]]; then
      ok "通る置き場が無いときは、通らないパスを案内しない"
    else
      bad "通らない置き場を案内した、または案内不能を言っていない"
      sed 's/^/    | /' "$log" >&2
    fi
  fi

  log="$work/windows.log"
  (
    HOME="$good_dir"
    ff_knowledge_storage() {
      case "$1" in
        "$bad_dir"|"$bad_dir"/*)
          printf 'knowledge-read: 止めた場所: %s — stub\n' "$1" >&2
          return 2 ;;
      esac
      return 0
    }
    ff_knowledge_windows_acl() { return 0; }
    OSTYPE=msys ff_review_output_ancestors "$bad_dir/leaf" "$repo"
  ) >"$log" 2>&1 || true
  suggested="$(sed -n 's/^       Next: --output-dir \(.*\) passes the output boundary (checked before this line was printed)\.$/\1/p' "$log")"
  if grep -qF 'an ancestor is not owned' "$log" \
    && [[ "$suggested" == "$home_candidate" && -d "$suggested" ]]; then
    ok "Windows の祖先拒否は、検査を通った本人の置き場だけを名指しする"
  else
    bad "Windows の祖先拒否が通った置き場を名指ししない: ${suggested:-<none>}"
    sed 's/^/    | /' "$log" >&2
  fi

  log="$work/windows-unnamed.log"
  (
    HOME="$good_dir"
    ff_knowledge_storage() {
      printf 'knowledge-read: 止めた場所: %s — stub\n' "$1" >&2
      return 2
    }
    ff_knowledge_windows_acl() { return 0; }
    OSTYPE=msys ff_review_output_ancestors "$bad_dir/leaf" "$repo"
  ) >"$log" 2>&1 || true
  if grep -qF 'no directory that passes the output boundary could be named' "$log" \
    && ! grep -qF 'Next: --output-dir ' "$log"; then
    ok "Windows で通る置き場が無いときは、通らないパスを案内しない"
  else
    bad "Windows の祖先拒否が通らない置き場を案内した"
    sed 's/^/    | /' "$log" >&2
  fi
  rm -rf "$bad_dir" "$good_dir"
}
