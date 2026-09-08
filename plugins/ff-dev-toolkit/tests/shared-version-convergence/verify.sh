#!/usr/bin/env bash
# 共有版境界の optimistic retry 契約と 2 clone 実測（ADR-038 / Issue #764）。
set -euo pipefail
# check-version-claims.sh は GITHUB_ACTIONS=true で「fetch せず job 開始時点の remote-tracking ref を
# 基準にする」CI 分岐へ入る（Issue #1336）。fixture ベースの検査はランナーの環境変数に左右されず
# ローカル分岐（fetch あり）を測るべきなので、ここで空へ固定し、CI 分岐を測るケースだけ
# GITHUB_ACTIONS=true を明示する。本リポジトリ自身の live 検査だけは環境の値を引き継ぐ
# （週次 CI では checkout SHA に閉じた判定が必要 = まさにこの Issue の修正対象）。
FF_AMBIENT_GITHUB_ACTIONS="${GITHUB_ACTIONS-}"
export GITHUB_ACTIONS=

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd -P)"
# fixture リポジトリの identity を呼び出し元へ漏らさない（Issue #1348 / #1368）
# fixture リポジトリの identity を呼び出し元へ漏らさない（Issue #1348 / #1368）
# shellcheck source=../lib/git-fixture.sh
. "$SCRIPT_DIR/../lib/git-fixture.sh"

# rc=0 でも -d を検査する — 2>&1 の合流は「成功 + stderr 警告」の環境で変数へ
# 警告文が混入し、以後の処理が原因不明の失敗に化けるため。
if ! tmp_out="$(mktemp -d "${TMPDIR:-/tmp}/shared-version-convergence.XXXXXX" 2>&1)" || [ ! -d "$tmp_out" ]; then
  echo "○ skip: 一時ディレクトリを作成できないため shared-version-convergence を実行できません（検査は1件も実行されていません）"
  printf '  mktemp: %s\n' "$tmp_out"
  exit 0
fi
TMP="$tmp_out"
REACHED_END=0
cleanup() {
  rc=$?
  rm -rf "$TMP"
  if [[ "$rc" -eq 0 && "$REACHED_END" -ne 1 ]]; then rc=1; fi
  exit "$rc"
}
trap cleanup EXIT
trap 'exit 130' HUP INT TERM

PASS=0
FAIL=0
ok() { echo "  ✓ $1"; PASS=$((PASS + 1)); }
bad() { echo "  ✗ $1" >&2; FAIL=$((FAIL + 1)); }
contains() {
  local file="$1" needle="$2" label="$3"
  if grep -Fq -- "$needle" "$file"; then ok "$label"; else bad "$label"; fi
}
not_contains() {
  local file="$1" needle="$2" label="$3"
  if grep -Fq -- "$needle" "$file"; then bad "$label"; else ok "$label"; fi
}
stable_claim_change() {
  local root="$1" base="$2" doc="$3" entry base_blob current_blob
  entry="$(git -C "$root" ls-tree "$base" -- "$doc")" || return 1
  if [[ -n "$entry" ]]; then base_blob="$(printf '%s\n' "$entry" | awk '{print $3}')"; else base_blob=ABSENT; fi
  current_blob="$(git -C "$root" hash-object "$root/$doc")" || return 1
  printf '%s\n' "base=$base_blob" "current=$current_blob" | git -C "$root" hash-object --stdin
}
read_frontmatter_version() {
  awk '
    NR == 1 { if ($0 != "---") malformed=1; next }
    !closed && $0 == "---" { closed=1; next }
    !closed && /^version:[[:space:]]*/ {
      count++
      value=$0
      sub(/^version:[[:space:]]*/, "", value)
      if (value ~ /^"[^"]*"$/) { sub(/^"/, "", value); sub(/"$/, "", value) }
      next
    }
    END {
      if (malformed || !closed || count > 1) exit 2
      if (count == 0) exit 1
      print value
    }
  ' "$1"
}

ACE_CURATE="$PLUGIN_ROOT/skills/ace-curate/SKILL.md"
ACE_REFINE="$PLUGIN_ROOT/skills/ace-refine/SKILL.md"
SPEC="$PLUGIN_ROOT/skills/spec-driven/SKILL.md"
ACE_CYCLE="$PLUGIN_ROOT/docs-template/05-operations/deployment/ace-cycle.md"
CLAIM_HELPER="$PLUGIN_ROOT/scripts/update-version-claim.sh"
CLAIM_VALIDATOR="$PLUGIN_ROOT/scripts/check-version-claims.sh"

echo "== shared version contract =="
contains "$ACE_CURATE" 'git fetch origin "+refs/heads/${default_branch}:refs/remotes/origin/${default_branch}"' "ace-curate は明示 refspec で fetch"
contains "$ACE_CURATE" 'git status --porcelain --untracked-files=all' "ace-curate は dirty tree を拒否"
contains "$ACE_CURATE" 'stale 値で版を確定しない' "ace-curate は fetch 失敗を fail-closed"
contains "$ACE_CURATE" 'merged tree の live エントリ実数から再計算' "ace_entry_count は派生実数"
contains "$ACE_CURATE" '最大 3 回' "ace-curate retry は bounded"
contains "$ACE_CURATE" 'git merge-base --is-ancestor "origin/${default_branch}" HEAD' "ace-curate は default branch 祖先を検査"
contains "$ACE_CURATE" '`--force` / `--force-with-lease` で先行セッションを上書きしない' "ace-curate は force push を禁止"
contains "$ACE_REFINE" '最大 3 回' "ace-refine retry は bounded"
contains "$ACE_REFINE" 'git fetch origin "+refs/heads/${default_branch}:refs/remotes/origin/${default_branch}"' "ace-refine は明示 refspec で fetch"
contains "$ACE_REFINE" 'git status --porcelain --untracked-files=all' "ace-refine は dirty tree を拒否"
contains "$ACE_REFINE" 'git merge-base --is-ancestor "origin/${default_branch}" HEAD' "ace-refine は default branch 祖先を検査"
contains "$ACE_REFINE" 'stale 値へ fallback せず停止' "ace-refine は取得不能を fail-closed"
contains "$SPEC" 'git status --porcelain --untracked-files=all' "spec-driven は dirty tree を拒否"
contains "$SPEC" 'git fetch origin "+refs/heads/${default_branch}:refs/remotes/origin/${default_branch}"' "spec-driven は明示 refspec で fetch"
contains "$SPEC" 'git merge-base --is-ancestor "origin/${default_branch}" HEAD' "spec-driven は default branch 祖先を検査"
contains "$SPEC" '最大3回' "spec-driven retry は bounded"
contains "$SPEC" '`--force` / `--force-with-lease` で上書きしない' "spec-driven は force 系 push を禁止"
contains "$SPEC" '.version-claims/' "spec-driven は文書別 version claim を要求"
contains "$SPEC" '`.version-claims/` が無い利用先ではこの手順だけを省略する' "spec-driven は claim contract 未導入先を停止させない"
contains "$ACE_CURATE" '.version-claims/docs/08-knowledge/PLAYBOOK.md.claim' "ace-curate は PLAYBOOK claim を要求"
contains "$ACE_REFINE" '.version-claims/' "ace-refine は変更文書 claim を要求"
contains "$ACE_CURATE" '[[ -f .version-claims/docs/08-knowledge/PLAYBOOK.md.claim ]] ||' "ace-curate PR は claim 不在を拒否"
ace_curate_pr_block="$(sed -n '/\*\*任意エスカレーション — chore PR\*\*/,/gh pr create/p' "$ACE_CURATE")"
if [[ "$ace_curate_pr_block" == *'scripts/update-version-claim.sh'* ]]; then ok "ace-curate PR は最新 base から claim を生成"; else bad "ace-curate PR が既存 claim を再利用"; fi
contains "$ACE_REFINE" '[[ -f .version-claims/docs/08-knowledge/PLAYBOOK.md.claim ]] ||' "ace-refine PR は PLAYBOOK claim 不在を拒否"
contains "$ACE_REFINE" '[[ -f .version-claims/docs/03-implementation/PATTERNS.md.claim ]] ||' "ace-refine は PATTERNS 変更時の claim 不在を拒否"
contains "$ACE_CURATE" 'scripts/update-version-claim.sh' "ace-curate は共通 claim helper を実行"
contains "$ACE_REFINE" 'scripts/update-version-claim.sh' "ace-refine は共通 claim helper を実行"
contains "$SPEC" 'scripts/update-version-claim.sh' "spec-driven は共通 claim helper を実行"
contains "$SPEC" 'scripts/check-version-claims.sh' "spec-driven は stage 後の claim validator を実行"
contains "$ACE_CURATE" 'scripts/check-version-claims.sh' "ace-curate は stage 後の claim validator を実行"
contains "$ACE_REFINE" 'scripts/check-version-claims.sh' "ace-refine は stage 後の claim validator を実行"
if [[ -x "$CLAIM_HELPER" ]]; then ok "claim helper は実行可能"; else bad "claim helper が実行可能でない"; fi
if [[ -x "$CLAIM_VALIDATOR" ]]; then ok "claim validator は通常ゲートから実行可能"; else bad "claim validator が実行可能でない"; fi
contains "$CLAIM_VALIDATOR" 'ls-files --stage -z' "claim validator の index snapshot は staged entry を read-only 列挙"
not_contains "$CLAIM_VALIDATOR" 'git -C "$root" write-tree' "claim validator は実リポジトリの index lock を取得しない"
contains "$CLAIM_HELPER" 'base=$base_blob' "claim helper は base blob ID を正規化"
contains "$CLAIM_HELPER" 'current=$current_blob' "claim helper は current blob ID を正規化"
contains "$CLAIM_HELPER" '! -L "$claim_parent"' "claim helper は symlink 親階層を拒否"
contains "$CLAIM_HELPER" 'claim の最終検証に失敗' "claim helper は保存後 claim を完全検証"
contains "$ACE_CURATE" 'default_ref="$(git symbolic-ref' "ace-curate claim block は default branch を自己解決"
contains "$ACE_REFINE" 'default_ref="$(git symbolic-ref' "ace-refine claim block は default branch を自己解決"
contains "$ACE_REFINE" 'if [[ -d .version-claims ]]; then' "ace-refine は claim contract がある repository だけで生成"
contains "$ACE_CURATE" '**各再試行で**上の commit block と同じ claim 生成' "ace-curate は retry ごとに claim を再生成"
contains "$ACE_REFINE" '**各再試行で**上の claim block と同じ claim 生成' "ace-refine は retry ごとに claim を再生成"
refine_gate_line="$(grep -nF 'npx --yes tsx scripts/ace/check-entry-format.ts' "$ACE_REFINE" | head -1 | cut -d: -f1 || true)"
refine_claim_line="$(grep -nF '全編集後に claim を最終生成する' "$ACE_REFINE" | head -1 | cut -d: -f1 || true)"
if [[ -n "$refine_gate_line" && -n "$refine_claim_line" && "$refine_gate_line" -lt "$refine_claim_line" ]]; then ok "ace-refine は全編集・ゲート後に claim を生成"; else bad "ace-refine claim が最終文書より先に生成される"; fi
not_contains "$SPEC" 'push が non-fast-forward なら' "spec-driven は feature push を default branch CAS と誤認しない"
contains "$ACE_CYCLE" '最大 3 回' "配布 ace-cycle も収束規則を案内"
contains "$ACE_CYCLE" '.version-claims/docs/08-knowledge/PLAYBOOK.md.claim' "配布 ace-cycle も PR race を閉じる"
contains "$ACE_CYCLE" 'scripts/update-version-claim.sh' "配布 ace-cycle も共通 claim helper を案内"
contains "$ACE_CURATE" '直 push / PR のどちらでも' "ace-curate は直 push でも PLAYBOOK claim を更新"
contains "$ACE_REFINE" '直 push / PR のどちらでも' "ace-refine は直 push でも変更文書 claim を更新"
contains "$ACE_CYCLE" '直 push / PR のどちらでも' "配布 ace-cycle も直 push と PR の交差を閉じる"

HELPER_FIX="$TMP/claim-helper"
HELPER_EXTERNAL="$TMP/claim-helper-external"
mkdir -p "$HELPER_FIX/docs/04-quality" "$HELPER_FIX/.version-claims" "$HELPER_EXTERNAL"
ff_git_fixture_init "$HELPER_FIX" "claims-test" "claims@example.com"
printf '%s\n' '---' 'version: "1.1.0"' '---' '# Testing' > "$HELPER_FIX/docs/04-quality/TESTING.md"
printf '%s\n' '# claims' > "$HELPER_FIX/.version-claims/README.md"
git -C "$HELPER_FIX" add -A && git -C "$HELPER_FIX" commit -qm baseline
printf '%s\n' '' 'changed' >> "$HELPER_FIX/docs/04-quality/TESTING.md"
git -C "$HELPER_FIX" config core.abbrev 4
(cd "$HELPER_FIX" && "$CLAIM_HELPER" --base HEAD --document docs/04-quality/TESTING.md) >/dev/null
claim_abbrev4="$(cat "$HELPER_FIX/.version-claims/docs/04-quality/TESTING.md.claim")"
rm "$HELPER_FIX/.version-claims/docs/04-quality/TESTING.md.claim"
git -C "$HELPER_FIX" config core.abbrev 40
(cd "$HELPER_FIX" && "$CLAIM_HELPER" --base HEAD --document docs/04-quality/TESTING.md) >/dev/null
claim_abbrev40="$(cat "$HELPER_FIX/.version-claims/docs/04-quality/TESTING.md.claim")"
if [[ "$claim_abbrev4" == "$claim_abbrev40" ]]; then ok "claim helper は core.abbrev に依存せず同じ hash"; else bad "claim hash が Git 表示設定で変化"; fi
rm -rf "$HELPER_FIX/.version-claims/docs"
ln -s "$HELPER_EXTERNAL" "$HELPER_FIX/.version-claims/docs"
set +e
helper_symlink_out="$(cd "$HELPER_FIX" && "$CLAIM_HELPER" --base HEAD --document docs/04-quality/TESTING.md 2>&1)"
helper_symlink_rc=$?
set -e
if [[ "$helper_symlink_rc" -ne 0 && "$helper_symlink_out" == *"symlink"* && ! -e "$HELPER_EXTERNAL/04-quality/TESTING.md.claim" ]]; then ok "claim helper は repository 外へ向く symlink 親階層を拒否"; else bad "claim helper が symlink 経由で repository 外へ書き込み"; fi
rm "$HELPER_FIX/.version-claims/docs"
mkdir -p "$HELPER_FIX/.version-claims/docs/04-quality"
printf '%s\n' '---' 'title: Testing' '---' '# Testing' '' 'version: "9.9.9"' > "$HELPER_FIX/docs/04-quality/TESTING.md"
if ! helper_body_out="$(cd "$HELPER_FIX" && "$CLAIM_HELPER" --base HEAD --document docs/04-quality/TESTING.md 2>&1)" && [[ "$helper_body_out" == *"frontmatter"* ]]; then ok "claim helper は本文中の version を採用しない"; else bad "claim helper が frontmatter 外の version を採用"; fi
printf '%s\n' '---' 'version: "1.1.0"' 'version: "1.2.0"' '---' '# Testing' > "$HELPER_FIX/docs/04-quality/TESTING.md"
if ! helper_duplicate_out="$(cd "$HELPER_FIX" && "$CLAIM_HELPER" --base HEAD --document docs/04-quality/TESTING.md 2>&1)" && [[ "$helper_duplicate_out" == *"正確に1件"* ]]; then ok "claim helper は重複 frontmatter version を拒否"; else bad "claim helper が重複 version を許可"; fi
if ! helper_parent_out="$(cd "$HELPER_FIX" && "$CLAIM_HELPER" --base HEAD --document docs/../README.md 2>&1)" && [[ "$helper_parent_out" == *"component"* ]]; then ok "claim helper は親 directory component を拒否"; else bad "claim helper が docs/ 外への traversal を許可"; fi
if ! helper_dot_out="$(cd "$HELPER_FIX" && "$CLAIM_HELPER" --base HEAD --document docs/./04-quality/TESTING.md 2>&1)" && [[ "$helper_dot_out" == *"component"* ]]; then ok "claim helper は dot component の別名 path を拒否"; else bad "claim helper が非正規 path を許可"; fi

validate_live_claims() {
  local validation_root="${1:-$REPO_ROOT}"
  [[ "$validation_root" == "$REPO_ROOT" ]] || git -C "$validation_root" add -A
  "$CLAIM_VALIDATOR" --root "$validation_root"
}
source "$SCRIPT_DIR/cases/claim-helper-failures.sh"
REPO_ROOT="$(git -C "$PLUGIN_ROOT" rev-parse --show-toplevel)"
if GITHUB_ACTIONS="$FF_AMBIENT_GITHUB_ACTIONS" validate_live_claims; then
  ok "変更した version 文書の claim が差分と一致"
  ok "変更した claim は version 変更文書へ逆参照できる"
else
  bad "version claim が不足・stale・orphan"
  bad "claim と version 文書の双方向対応が不正"
fi

STALE_SEED="$TMP/stale-seed"
STALE_BARE="$TMP/stale-origin.git"
STALE_CHECKER="$TMP/stale-checker"
STALE_WRITER="$TMP/stale-writer"
mkdir -p "$STALE_SEED/docs/04-quality" "$STALE_SEED/.version-claims/docs/04-quality"
ff_git_fixture_init "$STALE_SEED" "claims-test" "claims@example.com"
printf '%s\n' '---' 'version: "1.0.0"' '---' '# Testing' > "$STALE_SEED/docs/04-quality/TESTING.md"
printf '%s\n' '# claims' > "$STALE_SEED/.version-claims/README.md"
printf '%s\n' 'document=docs/04-quality/TESTING.md' 'version=1.0.0' 'change=baseline' > "$STALE_SEED/.version-claims/docs/04-quality/TESTING.md.claim"
git -C "$STALE_SEED" add -A
git -C "$STALE_SEED" commit -qm baseline
git -C "$STALE_SEED" branch -M develop
git clone -q --bare "$STALE_SEED" "$STALE_BARE"
git -C "$STALE_BARE" symbolic-ref HEAD refs/heads/develop
git clone -q "$STALE_BARE" "$STALE_CHECKER"
git clone -q "$STALE_BARE" "$STALE_WRITER"
ff_git_fixture_init "$STALE_WRITER" "claims-test" "claims@example.com"
printf '%s\n' '' 'remote advance' >> "$STALE_WRITER/docs/04-quality/TESTING.md"
git -C "$STALE_WRITER" add -A
git -C "$STALE_WRITER" commit -qm advance
git -C "$STALE_WRITER" push -q origin develop
# ローカル条件（GITHUB_ACTIONS 空）とCI 条件（GITHUB_ACTIONS=true）で先行ガードの挙動が分かれる
# （Issue #1336）。CI 条件を先に測る — ローカル条件の検証は fetch で remote-tracking ref を
# 進めるため、順序を逆にすると CI 条件で「job 開始時点の ref」が既に先行後の値になり、
# 「fetch しない」ことを検証できなくなる。
STALE_BASELINE="$(git -C "$STALE_CHECKER" rev-parse origin/develop)"
set +e
stale_ci_out="$(GITHUB_ACTIONS=true validate_live_claims "$STALE_CHECKER" 2>&1)"
stale_ci_rc=$?
set -e
if [[ "$stale_ci_rc" -eq 0 ]] &&
   [[ "$(git -C "$STALE_CHECKER" rev-parse origin/develop)" == "$STALE_BASELINE" ]]; then
  ok "CI 条件では走行中に先行した origin/<default> を fetch せず job 開始時点の ref で検査を完了"
else
  bad "CI 条件で走行中の origin/<default> 先行が赤になる、または fetch で ref が動いた（rc=${stale_ci_rc}）"
  printf '%s\n' "$stale_ci_out" | sed 's/^/    | /' >&2
fi
set +e
stale_out="$(GITHUB_ACTIONS= validate_live_claims "$STALE_CHECKER" 2>&1)"
stale_rc=$?
set -e
if [[ "$stale_rc" -ne 0 && "$stale_out" == *"HEAD より先行"* ]] &&
   [[ "$(git -C "$STALE_CHECKER" rev-parse origin/develop)" == "$(git -C "$STALE_WRITER" rev-parse HEAD)" ]]; then
  ok "ローカル条件では stale な remote-tracking ref でも fetch 後の先行 default branch を検出"
else
  bad "差分空の stale ref が live claim 検証を素通り"
fi
# ローカル条件の fetch で remote-tracking ref が checkout より先へ進んだ状態 = CI で「job 開始時点の
# ref が checkout より先行」に相当する。CI 条件でも先行ガードは残る（fetch を省くだけで緩めない）。
set +e
stale_ci_ahead_out="$(GITHUB_ACTIONS=true validate_live_claims "$STALE_CHECKER" 2>&1)"
stale_ci_ahead_rc=$?
set -e
if [[ "$stale_ci_ahead_rc" -eq 2 && "$stale_ci_ahead_out" == *"job 開始時点の remote-tracking ref）が checkout より先行"* ]]; then
  ok "CI 条件でも job 開始時点の ref が checkout より先行していれば exit 2（先行ガードは緩めない）"
else
  bad "CI 条件で先行した remote-tracking ref を素通り、または診断文が違う（rc=${stale_ci_ahead_rc}）"
  printf '%s\n' "$stale_ci_ahead_out" | sed 's/^/    | /' >&2
fi
# CI 条件で remote-tracking ref が無い（workflow の fetch step が抜けた）: fetch で補完せず exit 2
STALE_NOREF="$TMP/stale-noref"
git clone -q "$STALE_BARE" "$STALE_NOREF"
git -C "$STALE_NOREF" update-ref -d refs/remotes/origin/develop
set +e
stale_ci_noref_out="$(GITHUB_ACTIONS=true validate_live_claims "$STALE_NOREF" 2>&1)"
stale_ci_noref_rc=$?
set -e
if [[ "$stale_ci_noref_rc" -eq 2 && "$stale_ci_noref_out" == *"job 開始時点に fetch 済み"* ]] &&
   ! git -C "$STALE_NOREF" rev-parse --verify --quiet refs/remotes/origin/develop >/dev/null; then
  ok "CI 条件で remote-tracking ref が無ければ fetch で補完せず exit 2"
else
  bad "CI 条件で remote-tracking ref 不在を fetch で補完した、または診断文が違う（rc=${stale_ci_noref_rc}）"
  printf '%s\n' "$stale_ci_noref_out" | sed 's/^/    | /' >&2
fi

echo "== ordinary versioned documents require exact helper claims =="
NORMAL_SEED="$TMP/normal-seed"
NORMAL_BARE="$TMP/normal-origin.git"
NORMAL_WORK="$TMP/normal-work"
NORMAL_NEW="$TMP/normal-new"
mkdir -p "$NORMAL_SEED/docs" "$NORMAL_SEED/.version-claims"
ff_git_fixture_init "$NORMAL_SEED" "claims-test" "claims@example.com"
printf '%s\n' '---' 'version: "1.0.0"' '---' '# Ordinary' > "$NORMAL_SEED/docs/TEST.md"
printf '%s\n' '# claims' > "$NORMAL_SEED/.version-claims/README.md"
git -C "$NORMAL_SEED" add -A && git -C "$NORMAL_SEED" commit -qm baseline
git -C "$NORMAL_SEED" branch -M develop
git clone -q --bare "$NORMAL_SEED" "$NORMAL_BARE"
git -C "$NORMAL_BARE" symbolic-ref HEAD refs/heads/develop
git clone -q "$NORMAL_BARE" "$NORMAL_WORK"
ff_git_fixture_init "$NORMAL_WORK" "claims-test" "claims@example.com"
CONTRACT_DELETE="$TMP/contract-delete"
git clone -q "$NORMAL_BARE" "$CONTRACT_DELETE"
rm -rf "$CONTRACT_DELETE/.version-claims"
git -C "$CONTRACT_DELETE" add -A
if contract_delete_out="$("$CLAIM_VALIDATOR" --root "$CONTRACT_DELETE" 2>&1)"; then contract_delete_rc=0; else contract_delete_rc=$?; fi
if [[ "$contract_delete_rc" -eq 1 && "$contract_delete_out" == *"directory ごと削除"* ]]; then ok "導入済み claim contract の directory 削除を拒否"; else bad "claim contract 全削除で検査を回避"; printf '%s\n' "$contract_delete_out" | sed 's/^/    | /' >&2; fi
contract_git_bin="$TMP/contract-git-bin"
mkdir -p "$contract_git_bin"
cp "$SCRIPT_DIR/fixtures/bin/git" "$contract_git_bin/git"
chmod +x "$contract_git_bin/git"
if contract_origin_out="$(PATH="$contract_git_bin:$PATH" FAKE_CLAIM_GIT_FAIL_ORIGIN_CONFIG=1 FAKE_CLAIM_REAL_GIT="$(command -v git)" "$CLAIM_VALIDATOR" --root "$CONTRACT_DELETE" 2>&1)"; then contract_origin_rc=0; else contract_origin_rc=$?; fi
if [[ "$contract_origin_rc" -eq 2 && "$contract_origin_out" == *"origin 設定を検査できません"* ]]; then ok "origin 設定取得障害を no-origin と誤認しない"; else bad "origin 設定取得障害で履歴 fallback を実行"; printf '%s\n' "$contract_origin_out" | sed 's/^/    | /' >&2; fi
README_DELETE="$TMP/readme-delete"
git clone -q "$NORMAL_BARE" "$README_DELETE"
rm "$README_DELETE/.version-claims/README.md"
git -C "$README_DELETE" add -A
if readme_delete_out="$("$CLAIM_VALIDATOR" --root "$README_DELETE" 2>&1)"; then readme_delete_rc=0; else readme_delete_rc=$?; fi
if [[ "$readme_delete_rc" -eq 1 && "$readme_delete_out" == *"README.md を削除"* ]]; then ok "claim contract README の段階的削除を拒否"; else bad "README の先行削除で claim contract を無効化"; printf '%s\n' "$readme_delete_out" | sed 's/^/    | /' >&2; fi
PLAIN_DOC="$TMP/plain-doc"
git clone -q "$NORMAL_BARE" "$PLAIN_DOC"
printf '%s\n' '# Plain document' '' 'No version frontmatter.' > "$PLAIN_DOC/docs/PLAIN.md"
git -C "$PLAIN_DOC" add docs/PLAIN.md
if "$CLAIM_VALIDATOR" --root "$PLAIN_DOC" >/dev/null 2>&1; then ok "frontmatter の無い新規文書は version 対象外"; else bad "非 version 文書を malformed と誤分類"; fi
if contract_tree_out="$(PATH="$contract_git_bin:$PATH" FAKE_CLAIM_GIT_FAIL_CONTRACT_TREE=1 FAKE_CLAIM_REAL_GIT="$(command -v git)" "$CLAIM_VALIDATOR" --root "$NORMAL_WORK" 2>&1)"; then contract_tree_rc=0; else contract_tree_rc=$?; fi
if [[ "$contract_tree_rc" -eq 2 && "$contract_tree_out" == *"contract を検査できません"* ]]; then ok "contract tree 読み取り障害を未導入と誤認しない"; else bad "contract tree 検査不能を skip"; printf '%s\n' "$contract_tree_out" | sed 's/^/    | /' >&2; fi
sed -i.bak 's/version: "1.0.0"/version: "1.1.0"/' "$NORMAL_WORK/docs/TEST.md" && rm "$NORMAL_WORK/docs/TEST.md.bak"
if ! validate_live_claims "$NORMAL_WORK" >/dev/null 2>&1; then ok "通常文書の version 変更も claim 欠落を拒否"; else bad "通常文書の version 変更が claim 無しで通過"; fi
(cd "$NORMAL_WORK" && "$CLAIM_HELPER" --base origin/develop --document docs/TEST.md) >/dev/null
if validate_live_claims "$NORMAL_WORK" >/dev/null 2>&1; then ok "通常文書は helper 生成 claim で収束"; else bad "helper 生成した通常文書 claim を拒否"; fi
sed -i.bak 's/version: "1.1.0"/version: "1.2.0"/' "$NORMAL_WORK/docs/TEST.md" && rm "$NORMAL_WORK/docs/TEST.md.bak"
if ! validate_live_claims "$NORMAL_WORK" >/dev/null 2>&1; then ok "通常文書の stale version/hash claim を拒否"; else bad "通常文書の stale claim を許可"; fi
printf '%s\n' '---' 'title: Ordinary' '---' '# Ordinary' > "$NORMAL_WORK/docs/TEST.md"
if normal_removed_out="$(validate_live_claims "$NORMAL_WORK" 2>&1)"; then normal_removed_rc=0; else normal_removed_rc=$?; fi
if [[ "$normal_removed_rc" -ne 0 && "$normal_removed_out" == *"version が削除"* ]]; then ok "versioned 文書からの version 削除を拒否"; else bad "version 削除で claim 検証を迂回"; fi
printf '%s\n' '---' 'version: "1.1.0"' 'version: "1.2.0"' '---' '# Ordinary' > "$NORMAL_WORK/docs/TEST.md"
if normal_malformed_out="$(validate_live_claims "$NORMAL_WORK" 2>&1)"; then normal_malformed_rc=0; else normal_malformed_rc=$?; fi
if [[ "$normal_malformed_rc" -ne 0 && "$normal_malformed_out" == *"frontmatter version が不正"* ]]; then ok "重複 version の malformed frontmatter を拒否"; else bad "malformed frontmatter で claim 検証を迂回"; fi
git clone -q "$NORMAL_BARE" "$NORMAL_NEW"
printf '%s\n' '---' 'version: "1.0.0"' '---' '# New' > "$NORMAL_NEW/docs/NEW.md"
(cd "$NORMAL_NEW" && "$CLAIM_HELPER" --base origin/develop --document docs/NEW.md) >/dev/null
new_base_change="$(printf '%s\n' 'base=ABSENT' "current=$(git -C "$NORMAL_NEW" hash-object "$NORMAL_NEW/docs/NEW.md")" | git -C "$NORMAL_NEW" hash-object --stdin)"
if validate_live_claims "$NORMAL_NEW" >/dev/null 2>&1 && grep -Fqx "change=$new_base_change" "$NORMAL_NEW/.version-claims/docs/NEW.md.claim"; then ok "新規文書 claim は ABSENT base から helper 生成"; else bad "新規文書 claim が ABSENT base と一致しない"; fi

STAGED_WORK="$TMP/staged-work"
SPECIAL_PATH_WORK="$TMP/special-path-work"
git clone -q "$NORMAL_BARE" "$STAGED_WORK"
sed -i.bak 's/version: "1.0.0"/version: "1.1.0"/' "$STAGED_WORK/docs/TEST.md" && rm "$STAGED_WORK/docs/TEST.md.bak"
git -C "$STAGED_WORK" add docs/TEST.md
(cd "$STAGED_WORK" && "$CLAIM_HELPER" --base origin/develop --document docs/TEST.md) >/dev/null
if ! "$CLAIM_VALIDATOR" --root "$STAGED_WORK" >/dev/null 2>&1; then ok "文書だけ stage して claim が未追跡なら拒否"; else bad "未追跡 claim を同一 commit の sentinel と誤認"; fi
git -C "$STAGED_WORK" add .version-claims/docs/TEST.md.claim
printf '\n' >> "$STAGED_WORK/.version-claims/docs/TEST.md.claim"
git -C "$STAGED_WORK" add .version-claims/docs/TEST.md.claim
if ! "$CLAIM_VALIDATOR" --root "$STAGED_WORK" >/dev/null 2>&1; then ok "index claim の末尾空行を byte 検証で拒否"; else bad "末尾空行付き claim を正確な3行と誤認"; fi
(cd "$STAGED_WORK" && "$CLAIM_HELPER" --base origin/develop --document docs/TEST.md) >/dev/null
git -C "$STAGED_WORK" add .version-claims/docs/TEST.md.claim
printf '%s\n' 'document=docs/TEST.md' 'version=1.1.0' 'change=stale' > "$STAGED_WORK/.version-claims/docs/TEST.md.claim"
if ! "$CLAIM_VALIDATOR" --root "$STAGED_WORK" >/dev/null 2>&1; then ok "index の stale claim を working tree の正しい値で隠せない"; else bad "working tree claim が stale index を隠した"; fi
git -C "$STAGED_WORK" add .version-claims/docs/TEST.md.claim
claim_index_blob="$(printf '%s\n' 'external index replacement' | git -C "$STAGED_WORK" hash-object -w --stdin)"
claim_git_bin="$TMP/claim-git-bin"
mkdir -p "$claim_git_bin"
cp "$SCRIPT_DIR/fixtures/bin/git" "$claim_git_bin/git"
chmod +x "$claim_git_bin/git"
if claim_index_out="$(PATH="$claim_git_bin:$PATH" FAKE_CLAIM_GIT_MUTATE_INDEX=1 FAKE_CLAIM_GIT_MARKER="$TMP/claim-index-marker" FAKE_CLAIM_REAL_GIT="$(command -v git)" FAKE_CLAIM_GIT_ROOT="$STAGED_WORK" FAKE_CLAIM_GIT_BLOB="$claim_index_blob" FAKE_CLAIM_GIT_PATH='.version-claims/docs/TEST.md.claim' "$CLAIM_VALIDATOR" --root "$STAGED_WORK" 2>&1)"; then claim_index_rc=0; else claim_index_rc=$?; fi
if [[ "$claim_index_rc" -eq 2 && "$claim_index_out" == *"index tree が変更"* ]]; then ok "検査中の index 変更を成功扱いせず再実行要求"; else bad "検査途中の index tree 競合を見逃す"; printf '%s\n' "$claim_index_out" | sed 's/^/    | /' >&2; fi
git -C "$STAGED_WORK" add .version-claims/docs/TEST.md.claim
if claim_lookup_out="$(PATH="$claim_git_bin:$PATH" FAKE_CLAIM_GIT_FAIL_INDEX_LOOKUP=1 FAKE_CLAIM_REAL_GIT="$(command -v git)" "$CLAIM_VALIDATOR" --root "$STAGED_WORK" 2>&1)"; then claim_lookup_rc=0; else claim_lookup_rc=$?; fi
if [[ "$claim_lookup_rc" -eq 2 && "$claim_lookup_out" == *"index entry を検査できません"* ]]; then ok "index 読み取り障害を path 不在と誤認せず検査不能"; else bad "index 障害を文書・claim 同時削除として成功扱い"; printf '%s\n' "$claim_lookup_out" | sed 's/^/    | /' >&2; fi
BASE_PIN_WORK="$TMP/base-pin-work"
git clone -q "$NORMAL_BARE" "$BASE_PIN_WORK"
ff_git_fixture_init "$BASE_PIN_WORK" "claims-test" "claims@example.com"
sed -i.bak 's/version: "1.0.0"/version: "1.1.0"/' "$BASE_PIN_WORK/docs/TEST.md" && rm "$BASE_PIN_WORK/docs/TEST.md.bak"
(cd "$BASE_PIN_WORK" && "$CLAIM_HELPER" --base origin/develop --document docs/TEST.md) >/dev/null
git -C "$BASE_PIN_WORK" add -A
base_pin_tree="$(git -C "$BASE_PIN_WORK" write-tree)"
base_pin_moved="$(printf '%s\n' 'concurrent remote ref move' | git -C "$BASE_PIN_WORK" commit-tree "$base_pin_tree" -p origin/develop)"
if base_pin_out="$(PATH="$claim_git_bin:$PATH" FAKE_CLAIM_GIT_MOVE_BASE=1 FAKE_CLAIM_GIT_BASE_MARKER="$TMP/base-pin-marker" FAKE_CLAIM_REAL_GIT="$(command -v git)" FAKE_CLAIM_GIT_ROOT="$BASE_PIN_WORK" FAKE_CLAIM_GIT_NEW_BASE="$base_pin_moved" "$CLAIM_VALIDATOR" --root "$BASE_PIN_WORK" 2>&1)"; then base_pin_rc=0; else base_pin_rc=$?; fi
if [[ "$base_pin_rc" -eq 0 && "$base_pin_out" == *"差分に一致"* ]]; then ok "fetch 後の default base commit を検査終了まで固定"; else bad "検査途中の remote-tracking ref 更新で base が混在"; printf '%s\n' "$base_pin_out" | sed 's/^/    | /' >&2; fi
git clone -q "$NORMAL_BARE" "$SPECIAL_PATH_WORK"
special_doc="$SPECIAL_PATH_WORK/docs/$(printf 'unsafe\nname.md')"
printf '%s\n' '---' 'version: "1.0.0"' '---' '# Unsafe path' > "$special_doc"
git -C "$SPECIAL_PATH_WORK" add -A
if ! "$CLAIM_VALIDATOR" --root "$SPECIAL_PATH_WORK" >/dev/null 2>&1; then ok "改行を含む version 文書 path を明示拒否"; else bad "特殊文字 path の claim 欠落を許可"; fi

MODE_DOC_WORK="$TMP/mode-doc-work"
MODE_CLAIM_WORK="$TMP/mode-claim-work"
git clone -q "$NORMAL_BARE" "$MODE_DOC_WORK"
rm "$MODE_DOC_WORK/docs/TEST.md"
ln -s target.md "$MODE_DOC_WORK/docs/TEST.md"
git -C "$MODE_DOC_WORK" add docs/TEST.md
if mode_doc_out="$("$CLAIM_VALIDATOR" --root "$MODE_DOC_WORK" 2>&1)"; then mode_doc_rc=0; else mode_doc_rc=$?; fi
if [[ "$mode_doc_rc" -eq 2 && "$mode_doc_out" == *"単一の通常ファイルではありません: docs/TEST.md"* ]]; then ok "index 上の symlink 文書を通常ファイルと誤認しない"; else bad "symlink mode の version 文書を許可"; fi
git clone -q "$NORMAL_BARE" "$MODE_CLAIM_WORK"
sed -i.bak 's/version: "1.0.0"/version: "1.1.0"/' "$MODE_CLAIM_WORK/docs/TEST.md" && rm "$MODE_CLAIM_WORK/docs/TEST.md.bak"
(cd "$MODE_CLAIM_WORK" && "$CLAIM_HELPER" --base origin/develop --document docs/TEST.md) >/dev/null
mv "$MODE_CLAIM_WORK/.version-claims/docs/TEST.md.claim" "$MODE_CLAIM_WORK/.version-claims/docs/TEST.claim-target"
ln -s TEST.claim-target "$MODE_CLAIM_WORK/.version-claims/docs/TEST.md.claim"
git -C "$MODE_CLAIM_WORK" add docs/TEST.md .version-claims/docs/TEST.md.claim
if mode_claim_out="$("$CLAIM_VALIDATOR" --root "$MODE_CLAIM_WORK" 2>&1)"; then mode_claim_rc=0; else mode_claim_rc=$?; fi
if [[ "$mode_claim_rc" -eq 2 && "$mode_claim_out" == *"単一の通常ファイルではありません: .version-claims/docs/TEST.md.claim"* ]]; then ok "index 上の symlink claim を sentinel と誤認しない"; else bad "symlink mode の claim を許可"; fi

NO_HEAD_WORK="$TMP/no-head-work"
BAD_HEAD_WORK="$TMP/bad-head-work"
FETCH_FAIL_WORK="$TMP/fetch-fail-work"
git clone -q "$NORMAL_BARE" "$NO_HEAD_WORK"; git -C "$NO_HEAD_WORK" symbolic-ref -d refs/remotes/origin/HEAD
if ! "$CLAIM_VALIDATOR" --root "$NO_HEAD_WORK" >/dev/null 2>&1; then ok "origin/HEAD 不在を検査不能で拒否"; else bad "origin/HEAD 不在で claim 検証を続行"; fi
git clone -q "$NORMAL_BARE" "$BAD_HEAD_WORK"; git -C "$BAD_HEAD_WORK" symbolic-ref refs/remotes/origin/HEAD refs/heads/develop
if ! "$CLAIM_VALIDATOR" --root "$BAD_HEAD_WORK" >/dev/null 2>&1; then ok "origin 外を向く default ref を拒否"; else bad "不正 default ref で claim 検証を続行"; fi
git clone -q "$NORMAL_BARE" "$FETCH_FAIL_WORK"; git -C "$FETCH_FAIL_WORK" remote set-url origin "$TMP/missing-origin.git"
if ! "$CLAIM_VALIDATOR" --root "$FETCH_FAIL_WORK" >/dev/null 2>&1; then ok "default branch fetch 失敗を検査不能で拒否"; else bad "fetch 失敗を stale ref で代替"; fi

OPT_OUT_SEED="$TMP/opt-out-seed"
OPT_OUT_BARE="$TMP/opt-out-origin.git"
OPT_OUT_WORK="$TMP/opt-out-work"
mkdir -p "$OPT_OUT_SEED/docs"
ff_git_fixture_init "$OPT_OUT_SEED" "claims-test" "claims@example.com"
printf '%s\n' '---' 'version: "1.0.0"' '---' '# Optional claim contract' > "$OPT_OUT_SEED/docs/TEST.md"
git -C "$OPT_OUT_SEED" add -A && git -C "$OPT_OUT_SEED" commit -qm baseline
git -C "$OPT_OUT_SEED" branch -M develop
git clone -q --bare "$OPT_OUT_SEED" "$OPT_OUT_BARE"
git -C "$OPT_OUT_BARE" symbolic-ref HEAD refs/heads/develop
git clone -q "$OPT_OUT_BARE" "$OPT_OUT_WORK"
sed -i.bak 's/version: "1.0.0"/version: "1.1.0"/' "$OPT_OUT_WORK/docs/TEST.md" && rm "$OPT_OUT_WORK/docs/TEST.md.bak"
git -C "$OPT_OUT_WORK" add docs/TEST.md
if opt_out_out="$("$CLAIM_VALIDATOR" --root "$OPT_OUT_WORK" 2>&1)" && [[ "$opt_out_out" == *"未導入"* ]]; then ok "claim contract 未導入 repository は明示 skip"; else bad "未導入 repository に claim を誤強制"; fi
INTRO_NO_README="$TMP/intro-no-readme"
git clone -q "$OPT_OUT_BARE" "$INTRO_NO_README"
mkdir -p "$INTRO_NO_README/.version-claims"
sed -i.bak 's/version: "1.0.0"/version: "1.1.0"/' "$INTRO_NO_README/docs/TEST.md" && rm "$INTRO_NO_README/docs/TEST.md.bak"
(cd "$INTRO_NO_README" && "$CLAIM_HELPER" --base origin/develop --document docs/TEST.md) >/dev/null
if intro_out="$(validate_live_claims "$INTRO_NO_README" 2>&1)"; then intro_rc=0; else intro_rc=$?; fi
if [[ "$intro_rc" -eq 1 && "$intro_out" == *"README.md"* ]]; then ok "claim contract 初回導入にも README を必須化"; else bad "README 無しの claim contract 初回導入を許可"; fi

REQUIRED_SEED="$TMP/required-seed"
REQUIRED_BARE="$TMP/required-origin.git"
REQUIRED_WORK="$TMP/required-work"
mkdir -p "$REQUIRED_SEED/docs/08-knowledge" "$REQUIRED_SEED/docs/03-implementation" "$REQUIRED_SEED/.version-claims"
ff_git_fixture_init "$REQUIRED_SEED" "claims-test" "claims@example.com"
printf '%s\n' '---' 'version: "1.0.0"' '---' '# PLAYBOOK' > "$REQUIRED_SEED/docs/08-knowledge/PLAYBOOK.md"
printf '%s\n' '---' 'version: "1.0.0"' '---' '# PATTERNS' > "$REQUIRED_SEED/docs/03-implementation/PATTERNS.md"
printf '%s\n' '# claims' > "$REQUIRED_SEED/.version-claims/README.md"
git -C "$REQUIRED_SEED" add -A
git -C "$REQUIRED_SEED" commit -qm baseline
git -C "$REQUIRED_SEED" branch -M develop
git clone -q --bare "$REQUIRED_SEED" "$REQUIRED_BARE"
git -C "$REQUIRED_BARE" symbolic-ref HEAD refs/heads/develop
git clone -q "$REQUIRED_BARE" "$REQUIRED_WORK"
printf '%s\n' '' 'counter-only update' >> "$REQUIRED_WORK/docs/08-knowledge/PLAYBOOK.md"
printf '%s\n' '' 'content-only update' >> "$REQUIRED_WORK/docs/03-implementation/PATTERNS.md"
if ! validate_live_claims "$REQUIRED_WORK" >/dev/null 2>&1; then ok "version 不変 PLAYBOOK 更新も claim を必須化"; else bad "version 不変 PLAYBOOK の claim 欠落を許可"; fi
playbook_change="$(stable_claim_change "$REQUIRED_WORK" origin/develop docs/08-knowledge/PLAYBOOK.md)"
mkdir -p "$REQUIRED_WORK/.version-claims/docs/08-knowledge"
printf '%s\n' 'document=docs/08-knowledge/PLAYBOOK.md' 'version=1.0.0' "change=$playbook_change" > "$REQUIRED_WORK/.version-claims/docs/08-knowledge/PLAYBOOK.md.claim"
if ! validate_live_claims "$REQUIRED_WORK" >/dev/null 2>&1; then ok "version 不変 PATTERNS 更新も claim を必須化"; else bad "version 不変 PATTERNS の claim 欠落を許可"; fi
patterns_change="$(stable_claim_change "$REQUIRED_WORK" origin/develop docs/03-implementation/PATTERNS.md)"
mkdir -p "$REQUIRED_WORK/.version-claims/docs/03-implementation"
printf '%s\n' 'document=docs/03-implementation/PATTERNS.md' 'version=1.0.0' "change=$patterns_change" > "$REQUIRED_WORK/.version-claims/docs/03-implementation/PATTERNS.md.claim"
if validate_live_claims "$REQUIRED_WORK" >/dev/null 2>&1; then ok "version 不変の管理対象2文書も正しい claim で収束"; else bad "正しい version 不変 claim を拒否"; fi
printf '%s\n' 'document=docs/03-implementation/PATTERNS.md' 'version=1.0.0' 'change=stale' > "$REQUIRED_WORK/.version-claims/docs/03-implementation/PATTERNS.md.claim"
if ! validate_live_claims "$REQUIRED_WORK" >/dev/null 2>&1; then ok "version 不変 claim の stale hash を拒否"; else bad "version 不変 claim の stale hash を許可"; fi

DELETE_SEED="$TMP/delete-seed"
DELETE_BARE="$TMP/delete-origin.git"
DELETE_BOTH="$TMP/delete-both"
DELETE_DOC_ONLY="$TMP/delete-doc-only"
DELETE_CLAIM_ONLY="$TMP/delete-claim-only"
CHANGE_CLAIM_ONLY="$TMP/change-claim-only"
mkdir -p "$DELETE_SEED/docs/04-quality" "$DELETE_SEED/.version-claims/docs/04-quality"
ff_git_fixture_init "$DELETE_SEED" "claims-test" "claims@example.com"
printf '%s\n' '---' 'version: "1.0.0"' '---' '# Legacy' > "$DELETE_SEED/docs/04-quality/LEGACY.md"
printf '%s\n' '# claims' > "$DELETE_SEED/.version-claims/README.md"
printf '%s\n' 'document=docs/04-quality/LEGACY.md' 'version=1.0.0' 'change=baseline' > "$DELETE_SEED/.version-claims/docs/04-quality/LEGACY.md.claim"
git -C "$DELETE_SEED" add -A
git -C "$DELETE_SEED" commit -qm baseline
git -C "$DELETE_SEED" branch -M develop
git clone -q --bare "$DELETE_SEED" "$DELETE_BARE"
git -C "$DELETE_BARE" symbolic-ref HEAD refs/heads/develop
git clone -q "$DELETE_BARE" "$DELETE_BOTH"
git clone -q "$DELETE_BARE" "$DELETE_DOC_ONLY"
git clone -q "$DELETE_BARE" "$DELETE_CLAIM_ONLY"
git clone -q "$DELETE_BARE" "$CHANGE_CLAIM_ONLY"
RENAME_ORPHAN="$TMP/rename-orphan"
git clone -q "$DELETE_BARE" "$RENAME_ORPHAN"
git -C "$RENAME_ORPHAN" mv docs/04-quality/LEGACY.md docs/04-quality/RENAMED.md
(cd "$RENAME_ORPHAN" && "$CLAIM_HELPER" --base origin/develop --document docs/04-quality/RENAMED.md) >/dev/null
if rename_orphan_out="$(validate_live_claims "$RENAME_ORPHAN" 2>&1)"; then rename_orphan_rc=0; else rename_orphan_rc=$?; fi
if [[ "$rename_orphan_rc" -eq 1 && "$rename_orphan_out" == *"削除文書の claim が残っています"* ]]; then ok "rename 元文書の orphan claim を検出"; else bad "rename 検出で削除元 orphan claim を見逃す"; fi
rm "$DELETE_BOTH/docs/04-quality/LEGACY.md" "$DELETE_BOTH/.version-claims/docs/04-quality/LEGACY.md.claim"
if validate_live_claims "$DELETE_BOTH" >/dev/null 2>&1; then ok "文書と claim の同時削除を受理"; else bad "正しい文書・claim 削除を拒否"; fi
rm "$DELETE_DOC_ONLY/docs/04-quality/LEGACY.md"
if ! validate_live_claims "$DELETE_DOC_ONLY" >/dev/null 2>&1; then ok "文書削除時の orphan claim を拒否"; else bad "削除文書の orphan claim を許可"; fi
rm "$DELETE_CLAIM_ONLY/.version-claims/docs/04-quality/LEGACY.md.claim"
if ! validate_live_claims "$DELETE_CLAIM_ONLY" >/dev/null 2>&1; then ok "文書を残した claim 単独削除を拒否"; else bad "claim sentinel の単独削除を許可"; fi
printf '%s\n' 'document=docs/04-quality/LEGACY.md' 'version=9.9.9' 'change=stale' > "$CHANGE_CLAIM_ONLY/.version-claims/docs/04-quality/LEGACY.md.claim"
if ! validate_live_claims "$CHANGE_CLAIM_ONLY" >/dev/null 2>&1; then ok "文書未変更の claim 単独改変を拒否"; else bad "claim sentinel の単独改変を許可"; fi

write_playbook() { # $1=path $2=version $3=count $4=index lines $5=latest changelog
  out="$1" ver="$2" count="$3" indexes="$4" latest="$5"
  {
    printf '%s\n' '---' "version: \"$ver\"" "ace_entry_count: $count" 'updated: "2026-08-28"' 'changeImpact: medium' '---'
    printf '%s\n' '# PLAYBOOK' '' '## エントリ一覧' '' '| ID | Title | Category | Link |' '| --- | --- | --- | --- |'
    [[ -n "$indexes" ]] && printf '%b\n' "$indexes"
    printf '%s\n' '' '## Changelog' ''
    [[ -n "$latest" ]] && printf '%b\n' "$latest"
    printf '%s\n' '### [1.0.0] - 2026-08-01' '' '- 初版'
  } > "$out"
}

SEED="$TMP/seed"
BARE="$TMP/origin.git"
mkdir -p "$SEED/docs/08-knowledge/playbook"
ff_git_fixture_init "$SEED" "version-test" "version@example.com"
write_playbook "$SEED/docs/08-knowledge/PLAYBOOK.md" '1.0.0' 0 '' ''
git -C "$SEED" add -A
git -C "$SEED" commit -qm baseline
git -C "$SEED" branch -M develop
git clone -q --bare "$SEED" "$BARE"

for name in a b; do
  git clone -q "$BARE" "$TMP/$name"
  ff_git_fixture_init "$TMP/$name" "version-test" "version@example.com"
done

mkdir -p "$TMP/a/docs/08-knowledge/playbook" "$TMP/b/docs/08-knowledge/playbook"

printf '%s\n' '### ACE-100-1: A' > "$TMP/a/docs/08-knowledge/playbook/a.md"
write_playbook "$TMP/a/docs/08-knowledge/PLAYBOOK.md" '1.1.0' 1 '| ACE-100-1 | A | process | a |' '### [1.1.0] - 2026-08-28\n\n- ACE-100-1'
git -C "$TMP/a" add -A
git -C "$TMP/a" commit -qm session-a

printf '%s\n' '### ACE-101-1: B' > "$TMP/b/docs/08-knowledge/playbook/b.md"
write_playbook "$TMP/b/docs/08-knowledge/PLAYBOOK.md" '1.1.0' 1 '| ACE-101-1 | B | process | b |' '### [1.1.0] - 2026-08-28\n\n- ACE-101-1'
git -C "$TMP/b" add -A
git -C "$TMP/b" commit -qm session-b

git -C "$TMP/a" push -q origin HEAD:develop
set +e
B_PUSH_OUT="$(git -C "$TMP/b" push origin HEAD:develop 2>&1)"
B_PUSH_RC=$?
set -e
if [[ "$B_PUSH_RC" -ne 0 && "$B_PUSH_OUT" == *"rejected"* ]]; then ok "同時採番の後発 push を CAS が拒否"; else bad "後発 push が拒否されない"; fi

cp "$TMP/b/docs/08-knowledge/playbook/b.md" "$TMP/b-entry.md"
git -C "$TMP/b" fetch -q origin '+refs/heads/develop:refs/remotes/origin/develop'
git -C "$TMP/b" reset -q --hard origin/develop
cp "$TMP/b-entry.md" "$TMP/b/docs/08-knowledge/playbook/b.md"
write_playbook "$TMP/b/docs/08-knowledge/PLAYBOOK.md" '1.2.0' 2 '| ACE-100-1 | A | process | a |\n| ACE-101-1 | B | process | b |' '### [1.2.0] - 2026-08-28\n\n- ACE-101-1\n\n### [1.1.0] - 2026-08-28\n\n- ACE-100-1'
git -C "$TMP/b" add -A
git -C "$TMP/b" commit -qm session-b-reconciled
if git -C "$TMP/b" push -q origin HEAD:develop; then ok "最新 tree から再生成後に通常 push が収束"; else bad "再生成後の push が失敗"; fi

git clone -q "$BARE" "$TMP/final"
FINAL="$TMP/final/docs/08-knowledge/PLAYBOOK.md"
if grep -Fq 'version: "1.2.0"' "$FINAL"; then ok "後発 session は別版へ繰り上がる"; else bad "version が一意に収束しない"; fi
if grep -Fq 'ace_entry_count: 2' "$FINAL"; then ok "ace_entry_count は merged tree の実数"; else bad "ace_entry_count が実数でない"; fi
if grep -Fq 'ACE-100-1' "$FINAL" && grep -Fq 'ACE-101-1' "$FINAL"; then ok "両 session の索引を保全"; else bad "索引から先行変更が欠落"; fi
if grep -Fq '### [1.2.0]' "$FINAL" && grep -Fq '### [1.1.0]' "$FINAL"; then ok "両版ブロックを保全"; else bad "版ブロックが上書きされた"; fi

source "$SCRIPT_DIR/cases/merge-races.sh"
echo "shared-version-convergence: pass=$PASS fail=$FAIL total=$((PASS + FAIL))"
if [[ "$FAIL" -ne 0 ]]; then exit 1; fi
REACHED_END=1
echo "✓ shared-version-convergence: 全 $PASS 件 pass"
