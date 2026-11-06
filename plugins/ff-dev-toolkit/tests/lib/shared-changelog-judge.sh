# shellcheck shell=bash
# 共有 CHANGELOG（oss/ff-dev-toolkit/CHANGELOG.md）の直接編集の判定。changelog-fragments の
# cases/footer.sh から判定の本体だけを切り出した（Issue `#2619`）。判定表の分類は切り出す前と同じで、release-prep の
# 行だけを base と作業ツリーの version を両方読めた回に絞った（作業ツリーの version を読めない回を「版が違う」と読まない）:
#
#   base と CHANGELOG に差分が無い                         → unchanged    （許容）
#   plugin.json の version を base と作業ツリーの両方で読めて、
#   互いに違う                                              → release-prep （許容。リリース準備）
#   check-full-gate-reuse.sh が CHANGELOG_FOOTER_ONLY を返す → footer-only  （許容。比較リンクの footer 追従）
#   それ以外                                                → direct-edit  （通常 PR の直接編集）
#
# 呼び出し側が base の ref の解決・fetch・鮮度（base が HEAD の祖先か）の確認を済ませてから呼ぶ。
# 呼び出し元は cases/footer.sh と、リリースの模擬検査（sync-sha-contract/release-runtime.sh）の
# changelog-fragments の stub。stub が実物より緩いと、本番では通らない経路を模擬が緑で通すので、
# 模擬も判定はこの関数を呼ぶ。
#
# 結果は stdout ではなく SHARED_CHANGELOG_VERDICT へ入れる（呼び出し側の set -e を $(...) の中へ
# 持ち込まないため）。終了コードは 0 = 許容 / 1 = 直接編集。bash 3.2 互換。

SHARED_CHANGELOG_VERDICT=""
# shellcheck disable=SC2034  # SHARED_CHANGELOG_VERDICT は呼び出し側（cases/footer.sh・release-runtime の stub）が読む
ff_shared_changelog_judge() { # $1=リポジトリのルート $2=base の ref
  local root="$1" ref="$2" base_version current_version base_sha footer_out footer_rc
  SHARED_CHANGELOG_VERDICT=""
  if git -C "$root" diff --quiet "$ref" -- oss/ff-dev-toolkit/CHANGELOG.md; then
    SHARED_CHANGELOG_VERDICT=unchanged
    return 0
  fi
  base_version="$(git -C "$root" show "$ref:plugins/ff-dev-toolkit/.claude-plugin/plugin.json" | sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)"
  current_version="$(sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$root/plugins/ff-dev-toolkit/.claude-plugin/plugin.json" | head -1)"
  base_sha="$(git -C "$root" rev-parse "${ref}^{commit}")"
  footer_out="$(bash "$root/scripts/check-full-gate-reuse.sh" --green-sha "$base_sha" 2>&1)" && footer_rc=0 || footer_rc=$?
  # 作業ツリーの version を読めない回（plugin.json の不在・読めない）を「版が違う」と読まない（許容へ倒さない）
  if [[ -n "$base_version" && -n "$current_version" && "$current_version" != "$base_version" ]]; then
    SHARED_CHANGELOG_VERDICT=release-prep
    return 0
  elif [[ "$footer_rc" -eq 0 && "$footer_out" == *"FULL_GATE_REUSE=CHANGELOG_FOOTER_ONLY"* ]]; then
    SHARED_CHANGELOG_VERDICT=footer-only
    return 0
  fi
  SHARED_CHANGELOG_VERDICT=direct-edit
  return 1
}
