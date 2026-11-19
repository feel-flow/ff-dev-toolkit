#!/usr/bin/env bash
# /pre-commit-check 手順 8 の種別 H: staged のテストや許容表が skip 理由行・許容設定を変えたかを判定する。
# skip_line_precommit_scan REPO: rc 0=判定済み（run / none）、2=未検査。suite 自体は実行しない。
# 判定は index の blob（削除は空）と HEAD の blob に対する ff_skip_line_scan_files --reasons の結果
# （行番号差を正規化して比較）および全件 skip 行の増減と、許容表・skip 検査関連ファイルの staged で行う。
# bash 3.2 対応。

_skip_line_is_direct_path() {
  case "$1" in
    plugins/ff-dev-toolkit/tests/lib/release-skip-profile.tsv | \
    plugins/ff-dev-toolkit/tests/lib/release-skip-profile.sh | \
    plugins/ff-dev-toolkit/tests/lib/skip-line-contract.sh | \
    plugins/ff-dev-toolkit/tests/lib/relay-skip-lines.sh | \
    plugins/ff-dev-toolkit/tests/lib/precommit-skip-line.sh | \
    plugins/ff-dev-toolkit/tests/skip-line-contract/verify.sh | \
    plugins/ff-dev-toolkit/tests/public-layout/resident-skip-allow.sh | \
    plugins/ff-dev-toolkit/tests/public-layout/verify.sh | \
    oss/ff-dev-toolkit/.github/workflows/weekly-public-run-all.yml | \
    .github/workflows/weekly-public-run-all.yml)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

_skip_line_is_emitter_path() {
  case "$1" in
    plugins/*/tests/*)
      case "$1" in
        *.sh | *.bash | *.py | *.mjs)
          return 0
          ;;
      esac
      ;;
  esac
  return 1
}

_skip_line_normalize_sig() {
  local blob_file="$1" scan_out="$2" sig_raw="$3" sig_sorted="$4" circle="$5" path="$6" meta_file="$7"
  if ! printf '%s\n%s\n%s\n' "$scan_out" "$blob_file" "$circle" >"$meta_file"; then
    printf 'skip-line 未検査: 正規化メタ情報を書けません: %s\n' "$path" >&2
    return 2
  fi
  if ! LC_ALL=C awk '
    FNR == NR {
      if (FNR == 1) scan_file = $0
      else if (FNR == 2) bf = $0
      else if (FNR == 3) {
        c = $0
        bflen = length(bf)
        while ((getline l < scan_file) > 0) {
          if (substr(l, 1, bflen + 1) == bf ":") {
            rest = substr(l, bflen + 2)
            if (sub(/^[0-9]+\t/, "", rest)) {
              print "reason\t" rest
              continue
            }
            if (sub(/^[0-9]+:[ \t]*/, "", rest)) {
              print "violation\t" rest
              continue
            }
          }
          if (l != "") {
            print "raw\t" l
          }
        }
        close(scan_file)
      }
      next
    }
    {
      sub(/\r$/, "")
      if ($0 ~ /^[ \t]*#/) next
      if (index($0, c " skip") > 0) print "line\t" $0
    }
  ' "$meta_file" "$blob_file" >"$sig_raw"; then
    printf 'skip-line 未検査: 署名を正規化できません: %s\n' "$path" >&2
    return 2
  fi
  if ! LC_ALL=C sort "$sig_raw" >"$sig_sorted"; then
    printf 'skip-line 未検査: 署名を整列できません: %s\n' "$path" >&2
    return 2
  fi
  return 0
}

# _skip_line_blob_sig REPO SPEC REL_PATH PATH_SPEC STATUS MODE_SOURCE TMP OUT_SIG OUT_RC CIRCLE
# MODE_SOURCE: "index" または "head"。戻り値 0=署名作成、2=読取/走査不成立。
_skip_line_blob_sig() {
  local repo="$1" spec="$2" rel_path="$3" path_spec="$4" status="$5" mode_source="$6" tmp="$7" out_sig="$8" out_rc_file="$9" circle="${10}"
  local mode_line="" blob_file scan_rc=0 err_msg=""
  case "/$rel_path/" in
    */../* | */./* | *//* | *$'\n'*)
      printf 'skip-line 未検査: パスが不正です: %s\n' "$rel_path" >&2
      return 2
      ;;
  esac
  if [ "$mode_source" = "index" ]; then
    if ! mode_line="$(git -C "$repo" ls-files --stage -- "$path_spec" 2>"$tmp/ls.err")"; then
      err_msg="$(cat "$tmp/ls.err")"
      printf 'skip-line 未検査: index の mode を読めません (%s): %s\n' "$rel_path" "$err_msg" >&2
      return 2
    fi
    case "$mode_line" in
      100644\ * | 100755\ *) ;;
      120000\ *)
        if ! { : >"$out_sig" && printf '0\n' >"$out_rc_file"; }; then
          printf 'skip-line 未検査: index 署名を書けません: %s\n' "$rel_path" >&2
          return 2
        fi
        return 0
        ;;
      *)
        printf 'skip-line 未検査: index が通常ファイルではありません: %s\n' "$rel_path" >&2
        return 2
        ;;
    esac
  else
    if ! mode_line="$(git -C "$repo" ls-tree HEAD -- "$path_spec" 2>"$tmp/tree.err")"; then
      err_msg="$(cat "$tmp/tree.err")"
      printf 'skip-line 未検査: HEAD の mode を読めません (%s): %s\n' "$rel_path" "$err_msg" >&2
      return 2
    fi
    if [ -z "$mode_line" ]; then
      case "$status" in
        M | D | T)
          printf 'skip-line 未検査: HEAD に存在しません: %s\n' "$rel_path" >&2
          return 2
          ;;
        *)
          if ! { : >"$out_sig" && printf '0\n' >"$out_rc_file"; }; then
            printf 'skip-line 未検査: HEAD 署名を書けません: %s\n' "$rel_path" >&2
            return 2
          fi
          return 0
          ;;
      esac
    fi
    case "$mode_line" in
      100644\ * | 100755\ *) ;;
      120000\ *)
        if ! { : >"$out_sig" && printf '0\n' >"$out_rc_file"; }; then
          printf 'skip-line 未検査: HEAD 署名を書けません: %s\n' "$rel_path" >&2
          return 2
        fi
        return 0
        ;;
      *)
        printf 'skip-line 未検査: HEAD が通常ファイルではありません: %s\n' "$rel_path" >&2
        return 2
        ;;
    esac
  fi

  blob_file="$tmp/blobroot/$mode_source/$rel_path"
  if ! mkdir -p "$(dirname "$blob_file")"; then
    printf 'skip-line 未検査: 作業ディレクトリを作れません: %s\n' "$rel_path" >&2
    return 2
  fi
  if ! git -C "$repo" cat-file blob "$spec" >"$blob_file" 2>"$tmp/cat.err"; then
    err_msg="$(cat "$tmp/cat.err")"
    printf 'skip-line 未検査: blob を読めません (%s): %s\n' "$rel_path" "$err_msg" >&2
    return 2
  fi

  scan_rc=0
  ff_skip_line_scan_files --reasons "$blob_file" >"$tmp/scan.out" 2>"$tmp/scan.err" || scan_rc=$?
  if [ "$scan_rc" -gt 1 ]; then
    err_msg="$(cat "$tmp/scan.out" "$tmp/scan.err")"
    printf 'skip-line 未検査: 書式走査に失敗しました (%s): %s\n' "$rel_path" "$err_msg" >&2
    return 2
  fi
  if ! printf '%s\n' "$scan_rc" >"$out_rc_file"; then
    printf 'skip-line 未検査: 書式走査の終了コードを書けません: %s\n' "$rel_path" >&2
    return 2
  fi
  _skip_line_normalize_sig "$blob_file" "$tmp/scan.out" "$tmp/sig.raw" "$out_sig" "$circle" "$rel_path" "$tmp/norm.meta" || return 2
  return 0
}

skip_line_precommit_scan() (
  set -o pipefail
  local repo="${1:-.}" tmp="" tool lib rc=0 in_head=0 hits=0 status="" path="" idx_rc=0 circle="" err_msg="" literal_mode="" path_spec=""
  for tool in git awk sort cmp mktemp rm mkdir dirname cat printf; do
    if ! command -v "$tool" >/dev/null 2>&1; then
      printf 'skip-line 未検査: %s がありません\n' "$tool" >&2
      return 2
    fi
  done
  repo="$(git -C "$repo" rev-parse --show-toplevel 2>/dev/null)" || {
    printf 'skip-line 未検査: リポジトリルートを取得できません\n' >&2
    return 2
  }
  if [ ! -d "$repo/plugins/ff-dev-toolkit/tests" ]; then
    printf 'skip-line-contract: none\n'
    return 0
  fi
  lib="$repo/plugins/ff-dev-toolkit/tests/lib/skip-line-contract.sh"
  if [ ! -f "$lib" ] || [ ! -s "$lib" ] || [ ! -r "$lib" ]; then
    printf 'skip-line 未検査: %s がありません/読めません\n' "$lib" >&2
    return 2
  fi
  # shellcheck source=skip-line-contract.sh
  . "$lib" || {
    printf 'skip-line 未検査: %s を読み込めません\n' "$lib" >&2
    return 2
  }
  declare -F ff_skip_line_scan_files >/dev/null || {
    printf 'skip-line 未検査: ff_skip_line_scan_files が定義されていません\n' >&2
    return 2
  }
  if ! tmp="$(mktemp -d 2>/dev/null)" || [ -z "$tmp" ] || [ ! -d "$tmp" ]; then
    printf 'skip-line 未検査: 一時領域を作れません\n' >&2
    return 2
  fi
  trap 'exit_rc=$?; [ -n "$tmp" ] && rm -rf -- "$tmp"; exit "$exit_rc"' EXIT

  literal_mode="$(git -C "$repo" -c "ff.skipLiteral=${GIT_LITERAL_PATHSPECS:-0}" config --type=bool --get ff.skipLiteral 2>"$tmp/lit.err")" || {
    err_msg="$(cat "$tmp/lit.err")"
    printf 'skip-line 未検査: pathspec 設定を取得できません: %s\n' "$err_msg" >&2
    return 2
  }

  circle="$(printf '\342\227\213')"
  rc=0
  git -C "$repo" diff --cached --name-status -z --no-renames --no-relative \
    --diff-filter=ACDMRTU >"$tmp/list" 2>"$tmp/err" || rc=$?
  if [ "$rc" -ne 0 ]; then
    err_msg="$(cat "$tmp/err")"
    printf 'skip-line 未検査: staged の一覧を取得できません: %s\n' "$err_msg" >&2
    return 2
  fi

  git -C "$repo" rev-parse -q --verify HEAD >/dev/null 2>&1 && in_head=1

  while :; do
    status=""
    if IFS= read -r -d '' status; then
      if [ -z "$status" ]; then
        printf 'skip-line 未検査: staged の状態が空です\n' >&2
        return 2
      fi
    elif [ -n "$status" ]; then
      printf 'skip-line 未検査: staged のNUL終端がありません\n' >&2
      return 2
    else
      break
    fi
    path=""
    if ! IFS= read -r -d '' path || [ -z "$path" ]; then
      printf 'skip-line 未検査: staged のパス終端が不正です\n' >&2
      return 2
    fi
    case "$status" in
      U)
        if _skip_line_is_direct_path "$path" || _skip_line_is_emitter_path "$path"; then
          printf 'skip-line 未検査: 未解決の衝突があります: %s\n' "$path" >&2
          return 2
        fi
        continue
        ;;
      A | C | D | M | R | T) ;;
      *)
        printf 'skip-line 未検査: staged の書式が不正です: %s\n' "$status" >&2
        return 2
        ;;
    esac

    if _skip_line_is_direct_path "$path"; then
      hits=$((hits + 1))
      printf 'skip-line target: %s\n' "$path"
      continue
    fi
    if ! _skip_line_is_emitter_path "$path"; then
      continue
    fi

    if [ "$literal_mode" = "true" ]; then
      path_spec="$path"
    else
      path_spec=":(literal)${path}"
    fi

    rm -rf -- "$tmp/blobroot" "$tmp/idx.sig" "$tmp/head.sig" "$tmp/idx.rc" "$tmp/head.rc" "$tmp/norm.meta"
    if [ "$status" != "D" ]; then
      _skip_line_blob_sig "$repo" ":0:${path}" "$path" "$path_spec" "$status" index "$tmp" "$tmp/idx.sig" "$tmp/idx.rc" "$circle" || return 2
      idx_rc="$(cat "$tmp/idx.rc" 2>/dev/null || true)"
      case "$idx_rc" in
        0 | 1) ;;
        *)
          printf 'skip-line 未検査: 走査結果の終了コードが不正です (%s): %s\n' "$path" "$idx_rc" >&2
          return 2
          ;;
      esac
    else
      : >"$tmp/idx.sig"
      idx_rc=0
    fi
    if [ "$in_head" -eq 1 ] && [ "$status" != "A" ]; then
      _skip_line_blob_sig "$repo" "HEAD:${path}" "$path" "$path_spec" "$status" head "$tmp" "$tmp/head.sig" "$tmp/head.rc" "$circle" || return 2
    else
      : >"$tmp/head.sig"
    fi

    if [ "$idx_rc" -ne 0 ] || ! cmp -s "$tmp/head.sig" "$tmp/idx.sig"; then
      hits=$((hits + 1))
      printf 'skip-line target: %s\n' "$path"
    fi
  done <"$tmp/list"

  if [ "$hits" -gt 0 ]; then
    printf 'skip-line-contract: run %s\n' "$hits"
  else
    printf 'skip-line-contract: none\n'
  fi
  return 0
)
