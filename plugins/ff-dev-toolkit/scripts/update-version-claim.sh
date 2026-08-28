#!/usr/bin/env bash
# 文書の base blob ID（新規時は ABSENT）と current blob ID から Git 表示設定に依存しない version claim を生成する。
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
exact_link_library="$script_dir/lib/exact-link-functions.sh"
[[ -f "$exact_link_library" && ! -L "$exact_link_library" ]] && source "$exact_link_library" || { echo "✗ exact link library が無いか読み込めません: $exact_link_library" >&2; exit 2; }

base=""
document=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --base) shift; [[ $# -gt 0 ]] || { echo "Usage: $0 --base <ref> --document <docs/path.md>" >&2; exit 2; }; base="$1" ;;
    --document) shift; [[ $# -gt 0 ]] || { echo "Usage: $0 --base <ref> --document <docs/path.md>" >&2; exit 2; }; document="$1" ;;
    *) echo "Usage: $0 --base <ref> --document <docs/path.md>" >&2; exit 2 ;;
  esac
  shift
done
[[ -n "$base" && -n "$document" ]] || { echo "Usage: $0 --base <ref> --document <docs/path.md>" >&2; exit 2; }
[[ "$document" =~ ^docs/[A-Za-z0-9._-]+(/[A-Za-z0-9._-]+)*\.md$ ]] || { echo "✗ document は docs/ 配下の相対 Markdown path にしてください: $document" >&2; exit 1; }
case "/$document/" in */./*|*/../*) echo "✗ document path に . または .. component は使えません: $document" >&2; exit 1 ;; esac

repo_root_raw="$(git rev-parse --show-toplevel 2>/dev/null)" || { echo "✗ git repository root を解決できません" >&2; exit 2; }
repo_root="$(cd "$repo_root_raw" && pwd -P)" || { echo "✗ git repository root を正規化できません: $repo_root_raw" >&2; exit 2; }
doc="$repo_root/$document"
[[ -f "$doc" && ! -L "$doc" ]] || { echo "✗ document が通常ファイルではありません: $document" >&2; exit 1; }
doc_parent="$(cd "$(dirname "$doc")" && pwd -P)" || { echo "✗ document の親 directory を解決できません" >&2; exit 2; }
canonical_doc="$doc_parent/$(basename "$doc")"
[[ "$canonical_doc" == "$doc" ]] || { echo "✗ document path は正規形にしてください: $document" >&2; exit 1; }
case "$doc_parent/" in "$repo_root/docs/"*) ;; *) echo "✗ document の親 directory が docs/ 外です: $document" >&2; exit 1 ;; esac

base_commit="$(git rev-parse --verify "${base}^{commit}" 2>/dev/null)" || { echo "✗ base commit を解決できません: $base" >&2; exit 2; }
base_entry="$(git ls-tree "$base_commit" -- "$document")" || { echo "✗ base blob を検査できません: $document" >&2; exit 2; }
if [[ -n "$base_entry" ]]; then
  base_type="$(printf '%s\n' "$base_entry" | awk '{print $2}')"
  base_blob="$(printf '%s\n' "$base_entry" | awk '{print $3}')"
  [[ "$base_type" == blob && "$base_blob" =~ ^[0-9a-f]{40,64}$ ]] || { echo "✗ base 側の document が blob ではありません: $document" >&2; exit 1; }
else
  base_blob="ABSENT"
fi
current_blob="$(git hash-object "$doc")" || { echo "✗ current blob を取得できません: $document" >&2; exit 2; }
if [[ "$base_blob" != ABSENT && "$current_blob" == "$base_blob" ]]; then
  unchanged_blob="$(git hash-object "$doc")" || { echo "✗ unchanged document を再検査できません: $document" >&2; exit 2; }
  [[ "$unchanged_blob" == "$current_blob" ]] || { echo "✗ claim 判定中に document が変更されました: $document" >&2; exit 2; }
  echo "CLAIM_UNCHANGED=$document"
  exit 0
fi

read_frontmatter_version() {
  awk '
    NR == 1 {
      if ($0 != "---") invalid=1
      next
    }
    !closed && $0 == "---" { closed=1; next }
    !closed && /^version:[[:space:]]*/ {
      count++
      value=$0
      sub(/^version:[[:space:]]*/, "", value)
      if (value ~ /^"[^"]*"$/) {
        sub(/^"/, "", value)
        sub(/"$/, "", value)
      }
      next
    }
    END {
      if (invalid || !closed || count != 1) exit 1
      print value
    }
  ' "$1"
}
set +e
version="$(read_frontmatter_version "$doc")"
version_rc=$?
set -e
case "$version_rc" in
  0) ;;
  1) echo "✗ frontmatter 内に version が正確に1件必要です: $document" >&2; exit 1 ;;
  *) echo "✗ version を読み取れません: $document" >&2; exit 2 ;;
esac
[[ "$version" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]] || { echo "✗ version が SemVer ではありません: $document" >&2; exit 1; }

change="$(printf '%s\n' "base=$base_blob" "current=$current_blob" | git hash-object --stdin)" || { echo "✗ claim hash を生成できません: $document" >&2; exit 2; }

claims_root="$repo_root/.version-claims"
[[ -d "$claims_root" && ! -L "$claims_root" ]] || { echo "✗ .version-claims が無いか symlink です" >&2; exit 1; }
claim_parent="$claims_root"
relative_parent="${document%/*}"
old_ifs="$IFS"
IFS=/
parts=($relative_parent)
IFS="$old_ifs"
for part in "${parts[@]}"; do
  claim_parent="$claim_parent/$part"
  if [[ -e "$claim_parent" || -L "$claim_parent" ]]; then
    [[ -d "$claim_parent" && ! -L "$claim_parent" ]] || { echo "✗ claim 親階層が directory ではないか symlink です: $claim_parent" >&2; exit 1; }
  else
    mkdir "$claim_parent" || { echo "✗ claim 親 directory を作成できません: $claim_parent" >&2; exit 2; }
  fi
done
claim="$claims_root/${document}.claim"
verify_claim_parent() {
  local current="$claims_root" component canonical
  for component in "${parts[@]}"; do
    current="$current/$component"
    [[ -d "$current" && ! -L "$current" ]] || return 1
    canonical="$(cd "$current" && pwd -P)" || return 2
    [[ "$canonical" == "$current" ]] || return 1
  done
}
verify_claim_parent || { echo "✗ claim 親階層が検査後に変更されました: $claim_parent" >&2; exit 2; }
[[ ! -e "$claim" && ! -L "$claim" ]] || [[ -f "$claim" && ! -L "$claim" ]] || { echo "✗ claim が通常ファイルではありません: $claim" >&2; exit 1; }
claim_tmp=""
cleanup_claim_tmp_early() {
  local early_rc=$? early_err
  trap - EXIT HUP INT TERM
  if [[ -n "$claim_tmp" && (-e "$claim_tmp" || -L "$claim_tmp") ]] && ! early_err="$(rm -f "$claim_tmp" 2>&1)"; then
    echo "✗ 初期化中の claim 一時ファイルを削除できません: $claim_tmp: ${early_err%%$'\n'*}" >&2
    early_rc=2
  fi
  exit "$early_rc"
}
trap cleanup_claim_tmp_early EXIT
trap 'exit 130' HUP INT TERM
claim_tmp="$(mktemp "$claims_root/.version-claim.XXXXXX")" || { echo "✗ claim 一時ファイルを作成できません" >&2; exit 2; }
verify_claim_parent || { echo "✗ claim 一時ファイル作成中に親階層が変更されました" >&2; exit 2; }
claim_snapshot=""
claim_old=""
claim_installed=0
preserve_claim_snapshot=0
preserve_claim_old=0
preserve_claim_tmp=0
cleanup_claim_path() {
  local path="$1" label="$2" err
  [[ -n "$path" && (-e "$path" || -L "$path") ]] || return 0
  if ! err="$(rm -f "$path" 2>&1)"; then
    echo "✗ ${label}を削除できません: $path: ${err%%$'\n'*}" >&2
    return 2
  fi
}
rollback_claim_install() {
  local failed=0
  if [[ "$claim_installed" -eq 1 && -e "$claim" && "$claim" -ef "$claim_tmp" ]]; then
    cleanup_claim_path "$claim" "install 済み claim " || failed=1
  elif [[ "$claim_installed" -eq 1 && (-e "$claim" || -L "$claim") ]]; then
    preserve_claim_old=1
  fi
  if [[ -n "$claim_old" && -e "$claim_old" && ! -e "$claim" && ! -L "$claim" ]]; then
    mv "$claim_old" "$claim" || { preserve_claim_old=1; failed=1; }
  elif [[ -n "$claim_old" && -e "$claim_old" ]]; then preserve_claim_old=1
  fi
  return "$failed"
}
cleanup_claim_artifacts() {
  local failed=0
  [[ "$preserve_claim_old" -eq 0 ]] || { echo "✗ 手動復旧用の旧 claim を保持します: $claim_old" >&2; failed=1; }
  [[ "$preserve_claim_old" -eq 1 ]] || cleanup_claim_path "$claim_old" "旧 claim " || failed=1
  [[ "$preserve_claim_snapshot" -eq 0 ]] || { echo "✗ 手動復旧用 claim snapshot を保持します: $claim_snapshot" >&2; failed=1; }
  [[ "$preserve_claim_snapshot" -eq 1 ]] || cleanup_claim_path "$claim_snapshot" "claim snapshot " || failed=1
  [[ "$preserve_claim_tmp" -eq 0 ]] || { echo "✗ 手動復旧用の生成済み claim を保持します: $claim_tmp" >&2; failed=1; }
  [[ "$preserve_claim_tmp" -eq 1 ]] || cleanup_claim_path "$claim_tmp" "claim 一時ファイル" || failed=1
  return "$failed"
}
verify_current_claim() {
  local require_inode="$1" verified_hash
  [[ -f "$claim" && ! -L "$claim" ]] || return 1
  verified_hash="$(git hash-object "$claim")" || return 2
  [[ "$verified_hash" == "$expected_hash" && "$(wc -l < "$claim" | tr -d ' ')" -eq 3 ]] || return 1
  [[ "$require_inode" -eq 0 || (-e "$claim_tmp" && "$claim" -ef "$claim_tmp") ]]
}
verify_current_document() {
  local verified_blob verified_version
  verified_blob="$(git hash-object "$doc")" || return 2
  verified_version="$(read_frontmatter_version "$doc")" || return 2
  [[ "$verified_blob" == "$current_blob" && "$verified_version" == "$version" ]]
}
verify_old_claim_snapshot() {
  local old_hash snapshot_hash
  [[ -n "$claim_snapshot" ]] || return 0
  [[ -e "$claim_old" && -e "$claim_snapshot" && "$claim_old" -ef "$claim_snapshot" ]] || return 1
  old_hash="$(git hash-object "$claim_old")" || return 2
  snapshot_hash="$(git hash-object "$claim_snapshot")" || return 2
  [[ "$old_hash" == "$original_claim_hash" && "$snapshot_hash" == "$original_claim_hash" ]]
}
finalize_claim_artifacts() {
  local current_claim_rc current_document_rc old_snapshot_rc
  claim_installed=0
  if verify_current_claim 1; then current_claim_rc=0; else current_claim_rc=$?; fi
  if verify_current_document; then current_document_rc=0; else current_document_rc=$?; fi
  if verify_old_claim_snapshot; then old_snapshot_rc=0; else old_snapshot_rc=$?; fi
  if [[ "$current_claim_rc" -eq 2 || "$current_document_rc" -eq 2 || "$old_snapshot_rc" -eq 2 ]]; then
    preserve_claim_old=1; preserve_claim_snapshot=1; preserve_claim_tmp=1
    echo "✗ claim 確定前の現在 claim・document・旧 snapshot を検査できません" >&2; return 2
  fi
  if [[ "$current_claim_rc" -ne 0 || "$current_document_rc" -ne 0 || "$old_snapshot_rc" -ne 0 ]]; then
    preserve_claim_old=1; preserve_claim_snapshot=1; preserve_claim_tmp=1
    echo "✗ claim 確定前の外部変更を検出しました" >&2; return 2
  fi
  cleanup_claim_path "$claim_old" "旧 claim " || return 2; claim_old=""
  if ! verify_current_claim 1 || ! verify_current_document; then preserve_claim_snapshot=1; preserve_claim_tmp=1; echo "✗ 旧 claim 削除中の外部変更を検出しました" >&2; return 2; fi
  cleanup_claim_path "$claim_snapshot" "claim snapshot " || return 2; claim_snapshot=""
  if ! verify_current_claim 1 || ! verify_current_document; then preserve_claim_tmp=1; echo "✗ claim snapshot 削除中の外部変更を検出しました" >&2; return 2; fi
  cleanup_claim_path "$claim_tmp" "claim 一時ファイル" || return 2; claim_tmp=""
  verify_current_claim 0 && verify_current_document || { echo "✗ claim cleanup 後の最終検証に失敗しました" >&2; return 2; }
}
cleanup_claim_exit() {
  claim_rc=$?
  trap - EXIT HUP INT TERM
  [[ "$claim_rc" -eq 0 ]] || rollback_claim_install || claim_rc=2
  cleanup_claim_artifacts || claim_rc=2
  exit "$claim_rc"
}
claim_signal_abort() {
  echo "✗ signal により claim 更新を中断しました" >&2
  exit 130
}
install_claim_no_replace() {
  link_in_canonical_directory "$claim_tmp" "$claim" "$claim_parent"
}
link_in_canonical_directory() {
  local source="$1" destination="$2" directory="$3" actual_directory
  (
    cd "$directory" || { echo "canonical directory へ移動できません: $directory" >&2; exit 2; }
    actual_directory="$(pwd -P)" || { echo "canonical directory を解決できません: $directory" >&2; exit 2; }
    [[ "$actual_directory" == "$directory" ]] || { echo "canonical directory が変化しました: expected=$directory actual=$actual_directory" >&2; exit 2; }
    exact_link_no_replace "$source" "./${destination##*/}"
  )
}
trap cleanup_claim_exit EXIT
trap claim_signal_abort HUP INT TERM
expected="$(printf '%s\n' "document=$document" "version=$version" "change=$change")"
printf '%s\n' "$expected" > "$claim_tmp" || { echo "✗ claim 一時ファイルへ書き込めません" >&2; exit 2; }
expected_hash="$(git hash-object "$claim_tmp")" || { echo "✗ claim 一時ファイルを検査できません" >&2; exit 2; }
if [[ -e "$claim" || -L "$claim" ]]; then
  claim_snapshot="$(mktemp "$claims_root/.version-claim-snapshot.XXXXXX")" || { echo "✗ claim snapshot path を作成できません" >&2; exit 2; }
  rm -f "$claim_snapshot" || { echo "✗ claim snapshot path を準備できません" >&2; exit 2; }
  verify_claim_parent || { echo "✗ claim snapshot 作成前に親階層が変更されました" >&2; exit 2; }
  link_in_canonical_directory "$claim" "$claim_snapshot" "$claims_root" || { echo "✗ claim snapshot を作成できません" >&2; exit 2; }
  original_claim_hash="$(git hash-object "$claim_snapshot")" || { echo "✗ 既存 claim を検査できません" >&2; exit 2; }
fi
preinstall_blob="$(git hash-object "$doc")" || { echo "✗ 保存前の document を検査できません: $document" >&2; exit 2; }
preinstall_version="$(read_frontmatter_version "$doc")" || { echo "✗ 保存前の version を検査できません: $document" >&2; exit 2; }
[[ "$preinstall_blob" == "$current_blob" && "$preinstall_version" == "$version" ]] || { echo "✗ claim 生成中に document が変更されました: $document" >&2; exit 2; }
if [[ -n "$claim_snapshot" ]]; then
  current_claim_hash="$(git hash-object "$claim")" || { echo "✗ 保存直前の claim を検査できません" >&2; exit 2; }
  [[ "$claim" -ef "$claim_snapshot" && "$current_claim_hash" == "$original_claim_hash" ]] || { preserve_claim_snapshot=1; echo "✗ 保存直前に claim の外部変更を検出しました" >&2; exit 2; }
  claim_old="$(mktemp "$claims_root/.version-claim-old.XXXXXX")" || { echo "✗ 旧 claim path を作成できません" >&2; exit 2; }
  rm -f "$claim_old" || { echo "✗ 旧 claim path を準備できません" >&2; exit 2; }
  verify_claim_parent || { echo "✗ claim 退避前に親階層が変更されました" >&2; exit 2; }
  mv "$claim" "$claim_old" || { echo "✗ 既存 claim を退避できません" >&2; exit 2; }
  if [[ ! "$claim_old" -ef "$claim_snapshot" ]]; then
    preserve_claim_snapshot=1
    [[ -e "$claim" || -L "$claim" ]] || mv "$claim_old" "$claim" || preserve_claim_old=1
    echo "✗ claim 退避直前の外部置換を検出しました" >&2
    exit 2
  fi
elif [[ -e "$claim" || -L "$claim" ]]; then
  echo "✗ claim 作成直前の外部作成を検出しました" >&2
  exit 2
fi
verify_claim_parent || { echo "✗ claim install 前に親階層が変更されました" >&2; exit 2; }
install_claim_no_replace || { [[ ! -e "$claim" && ! -L "$claim" ]] || preserve_claim_old=1; echo "✗ claim を検査済み directory へ上書き禁止で保存できません: $claim" >&2; exit 2; }
claim_installed=1
final_blob="$(git hash-object "$doc")" || { echo "✗ 保存後の document を検査できません: $document" >&2; exit 2; }
final_version="$(read_frontmatter_version "$doc")" || { echo "✗ 保存後の version を検査できません: $document" >&2; exit 2; }
final_claim_hash="$(git hash-object "$claim")" || { echo "✗ 保存後の claim を検査できません: $claim" >&2; exit 2; }
[[ "$final_blob" == "$current_blob" && "$final_version" == "$version" ]] || { echo "✗ claim 保存中に document が変更されました: $document" >&2; exit 2; }
[[ "$claim" -ef "$claim_tmp" && "$final_claim_hash" == "$expected_hash" && "$(wc -l < "$claim" | tr -d ' ')" -eq 3 ]] || { echo "✗ claim の最終検証に失敗: $claim" >&2; exit 2; }
finalize_claim_artifacts || exit 2
trap - EXIT HUP INT TERM
echo "CLAIM_UPDATED=.version-claims/${document}.claim"
