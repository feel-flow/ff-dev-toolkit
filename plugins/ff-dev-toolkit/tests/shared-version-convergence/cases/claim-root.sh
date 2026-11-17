# shellcheck shell=bash
# version claim の対象 repo の解決規則（scripts/lib/version-claim-root.sh、Issue `#2818`）の fixture テスト。
# shared-version-convergence/verify.sh から source して使う。単体では実行しない。
#
# 同じリポジトリの 2 つの worktree（clone した主 checkout と、そこから足した linked worktree）を
# fixture の中に作り、同梱スクリプトの写しを seed へ commit して両方へ置く。実リポジトリへは
# git worktree add しない。写したスクリプトは plugin root ガードの handoff（FF_DEV_TOOLKIT_ROOT 等）を
# 外して起動する — 残すとガードが先に rc 2 で止まり、「rc ≠ 0」の検査が別の理由で通る。
#
# 判別の作り: linked worktree は文書の version を上げて commit してあり、主 checkout とは HEAD も文書も
# 違う。cwd を主 checkout に置いて linked を対象にした回、helper の rev-parse が cwd の repo を読むと
# 結果（CLAIM_UNCHANGED / CLAIM_UPDATED）が変わる。cwd を repo の外に置く回は、cwd の repo を読む
# rev-parse / ls-tree がそもそも失敗する。hash-object は repo の外でも成功するので、core.autocrlf=true の
# 別の repo を cwd にして、改行の混ざった文書の blob（claim の change）が変わることで測る。

echo "== version claim の対象 repo（--root・同じリポジトリの別 worktree） =="

CR_TMP="$TMP/claim-root"
CR_SEED="$CR_TMP/seed"
CR_BARE="$CR_TMP/origin.git"
CR_MAIN="$CR_TMP/main"
CR_LINKED="$CR_TMP/linked"
CR_SNAPSHOT="$CR_TMP/snapshot"
CR_OUTSIDE="$CR_TMP/outside"
CR_REL_SCRIPTS="plugins/ff-dev-toolkit/scripts"
mkdir -p "$CR_SEED/docs" "$CR_SEED/.version-claims" "$CR_SEED/$CR_REL_SCRIPTS" "$CR_SNAPSHOT/scripts" "$CR_OUTSIDE"
ff_git_fixture_init "$CR_SEED" "claims-test" "claims@example.com"
printf '%s\n' '---' 'version: "1.0.0"' '---' '# Root' > "$CR_SEED/docs/TEST.md"
printf '%s\n' '# claims' > "$CR_SEED/.version-claims/README.md"
cp "$CLAIM_HELPER" "$CLAIM_VALIDATOR" "$CR_SEED/$CR_REL_SCRIPTS/"
cp -R "$PLUGIN_ROOT/scripts/lib" "$CR_SEED/$CR_REL_SCRIPTS/lib"
cp "$CLAIM_HELPER" "$CLAIM_VALIDATOR" "$CR_SNAPSHOT/scripts/"
cp -R "$PLUGIN_ROOT/scripts/lib" "$CR_SNAPSHOT/scripts/lib"
git -C "$CR_SEED" add -A && git -C "$CR_SEED" commit -qm baseline
git -C "$CR_SEED" branch -M develop
git clone -q --bare "$CR_SEED" "$CR_BARE"
git -C "$CR_BARE" symbolic-ref HEAD refs/heads/develop
git clone -q "$CR_BARE" "$CR_MAIN"
ff_git_fixture_init "$CR_MAIN" "claims-test" "claims@example.com"
git -C "$CR_MAIN" worktree add -q -b feature "$CR_LINKED" origin/develop
sed -i.bak 's/version: "1.0.0"/version: "1.1.0"/' "$CR_LINKED/docs/TEST.md" && rm "$CR_LINKED/docs/TEST.md.bak"
git -C "$CR_LINKED" commit -qam bump
CR_MAIN_P="$(cd "$CR_MAIN" && pwd -P)"
CR_LINKED_P="$(cd "$CR_LINKED" && pwd -P)"
CR_CLAIM_REL=".version-claims/docs/TEST.md.claim"
CR_LINKED_HELPER="$CR_LINKED/$CR_REL_SCRIPTS/update-version-claim.sh"
CR_LINKED_VALIDATOR="$CR_LINKED/$CR_REL_SCRIPTS/check-version-claims.sh"

cr_run() { # <cwd> <script> <args...> → CR_RC / CR_OUT / CR_ERR
  local cwd="$1"
  shift
  CR_RC=0
  CR_OUT="$(cd "$cwd" && env -u FF_DEV_TOOLKIT_ROOT -u CLAUDE_PLUGIN_ROOT -u GROK_PLUGIN_ROOT bash "$@" 2>"$CR_TMP/err")" || CR_RC=$?
  CR_ERR="$(cat "$CR_TMP/err")"
}
cr_run_env() { # <cwd> <NAME=value> <script> <args...> → 呼び出し元から受け継いだ環境変数を 1 つ足して起動する
  local cwd="$1" assign="$2"
  shift 2
  CR_RC=0
  CR_OUT="$(cd "$cwd" && env -u FF_DEV_TOOLKIT_ROOT -u CLAUDE_PLUGIN_ROOT -u GROK_PLUGIN_ROOT "$assign" bash "$@" 2>"$CR_TMP/err")" || CR_RC=$?
  CR_ERR="$(cat "$CR_TMP/err")"
}
cr_dump() { printf '    | rc=%s\n' "$CR_RC" >&2; printf '%s\n' "$CR_OUT" "$CR_ERR" | sed 's/^/    | /' >&2; }
cr_names_both() { # 食い違いの停止が、両方の最上位と --root を名指しているか
  [[ "$CR_RC" -eq 2 && "$CR_ERR" == *"同じリポジトリの別の worktree"* && "$CR_ERR" == *"cwd の repo: ${CR_MAIN_P}"* \
    && "$CR_ERR" == *"スクリプトの repo: ${CR_LINKED_P}"* && "$CR_ERR" == *"--root"* \
    && "$CR_OUT" != *"CLAIM_UNCHANGED"* && "$CR_OUT" != *"CLAIM_UPDATED"* && "$CR_OUT" != *"✓ version claim"* ]]
}

# AC2: cwd が主 checkout・linked のスクリプトを絶対パスで呼び、root を明示しない → 黙って主 checkout の
# 文書を見た CLAIM_UNCHANGED を返さず、両方を名指して止める（OBS-130 の形そのもの）
cr_run "$CR_MAIN" "$CR_LINKED_HELPER" --base origin/develop --document docs/TEST.md
if cr_names_both && [[ ! -e "$CR_MAIN/$CR_CLAIM_REL" && ! -e "$CR_LINKED/$CR_CLAIM_REL" ]]; then
  ok "claim root: root を明示せず別 worktree のスクリプトを呼ぶと、両方の repo と --root を名指して止める（claim は書かない）"
else
  bad "claim root: cwd と別 worktree のスクリプトの食い違いを止めていない"; cr_dump
fi
# AC3: 検証側も同じ規則で同じ判定をする
cr_run "$CR_MAIN" "$CR_LINKED_VALIDATOR"
if cr_names_both; then
  ok "claim root: 検証側も root を明示しない別 worktree の起動を同じ名指しで止める"
else
  bad "claim root: 検証側が別 worktree の起動を止めていない（生成側と規則が揃っていない）"; cr_dump
fi

# AC1: root を明示すれば cwd がどこでも、その worktree の HEAD と文書を対象にする。--base HEAD は linked の
# HEAD（version を上げた commit）なので文書と一致して CLAIM_UNCHANGED になる。cwd の主 checkout の HEAD を
# 読むと base が seed になり CLAIM_UPDATED へ変わる
cr_run "$CR_MAIN" "$CR_LINKED_HELPER" --root "$CR_LINKED" --base HEAD --document docs/TEST.md
if [[ "$CR_RC" -eq 0 && "$CR_OUT" == *"CLAIM_ROOT=${CR_LINKED_P}"* && "$CR_OUT" == *"CLAIM_UNCHANGED=docs/TEST.md"* && ! -e "$CR_LINKED/$CR_CLAIM_REL" ]]; then
  ok "claim root: --root の base（HEAD）は対象 worktree で解決し、出力に対象 repo を示す"
else
  bad "claim root: --root を渡しても base を cwd の repo で解決した"; cr_dump
fi
cr_run "$CR_MAIN" "$CR_LINKED_HELPER" --root "$CR_LINKED" --base origin/develop --document docs/TEST.md
cr_expected_change="$(stable_claim_change "$CR_LINKED" origin/develop docs/TEST.md)"
if [[ "$CR_RC" -eq 0 && "$CR_OUT" == *"CLAIM_ROOT=${CR_LINKED_P}"* && "$CR_OUT" == *"CLAIM_UPDATED=${CR_CLAIM_REL}"* && ! -e "$CR_MAIN/$CR_CLAIM_REL" ]] \
  && grep -Fqx 'version=1.1.0' "$CR_LINKED/$CR_CLAIM_REL" && grep -Fqx "change=${cr_expected_change}" "$CR_LINKED/$CR_CLAIM_REL"; then
  ok "claim root: cwd が別の checkout でも --root の worktree の文書から claim を作る（cwd 側には書かない）"
else
  bad "claim root: --root の worktree の claim を作れていない"; cr_dump
fi
rm -f "$CR_LINKED/$CR_CLAIM_REL"
cr_run "$CR_OUTSIDE" "$CR_LINKED_HELPER" --root "$CR_LINKED" --base origin/develop --document docs/TEST.md
if [[ "$CR_RC" -eq 0 && "$CR_OUT" == *"CLAIM_ROOT=${CR_LINKED_P}"* ]] && grep -Fqx "change=${cr_expected_change}" "$CR_LINKED/$CR_CLAIM_REL"; then
  ok "claim root: cwd が repo の外でも --root の worktree だけを読んで claim を作る"
else
  bad "claim root: cwd が repo の外だと --root を渡しても claim を作れない（cwd の repo を読む git が残っている）"; cr_dump
fi

# hash-object も --root の repo で呼ぶ: cwd の repo（core.autocrlf=true）の変換を受けると、改行の混ざった
# 新規文書の blob が変わり claim の change がずれる
CR_CRLF_CWD="$CR_TMP/crlf-cwd"
ff_git_fixture_init "$CR_CRLF_CWD" "claims-test" "claims@example.com"
git -C "$CR_CRLF_CWD" config core.autocrlf true
printf -- '---\nversion: "1.0.0"\n---\n# CRLF\r\nbody\r\n' > "$CR_LINKED/docs/CRLF.md"
cr_run "$CR_CRLF_CWD" "$CR_LINKED_HELPER" --root "$CR_LINKED" --base origin/develop --document docs/CRLF.md
cr_crlf_change="$(stable_claim_change "$CR_LINKED" origin/develop docs/CRLF.md)"
if [[ "$CR_RC" -eq 0 ]] && grep -Fqx "change=${cr_crlf_change}" "$CR_LINKED/.version-claims/docs/CRLF.md.claim"; then
  ok "claim root: 文書の blob も --root の repo の設定で作る（cwd の repo の core.autocrlf を受けない）"
else
  bad "claim root: 文書の blob を cwd の repo の設定で作った（hash-object が cwd の repo を読む）"; cr_dump
fi
rm -f "$CR_LINKED/docs/CRLF.md" "$CR_LINKED/.version-claims/docs/CRLF.md.claim"

# git hook などから受け継いだ GIT_DIR が別の worktree を指すと、git -C <root> は --root ではなくそちらを読む。
# 黙って混ぜずに止める（同じ repository を指す GIT_DIR は通す）
cr_run_env "$CR_MAIN" "GIT_DIR=$CR_MAIN/.git" "$CR_LINKED_HELPER" --root "$CR_LINKED" --base HEAD --document docs/TEST.md
if [[ "$CR_RC" -eq 2 && "$CR_ERR" == *"GIT_DIR"* && "$CR_OUT" != *"CLAIM_UNCHANGED"* && "$CR_OUT" != *"CLAIM_UPDATED"* ]]; then
  ok "claim root: 受け継いだ GIT_DIR が --root と別の worktree を指すと止める（別の HEAD を混ぜない）"
else
  bad "claim root: GIT_DIR が別の worktree を指したまま --root の claim を作った"; cr_dump
fi
cr_linked_git_dir="$(git -C "$CR_LINKED" rev-parse --absolute-git-dir)"
cr_run_env "$CR_LINKED" "GIT_DIR=$cr_linked_git_dir" "$CR_LINKED_HELPER" --root "$CR_LINKED" --base HEAD --document docs/TEST.md
if [[ "$CR_RC" -eq 0 && "$CR_OUT" == *"CLAIM_ROOT=${CR_LINKED_P}"* && "$CR_OUT" == *"CLAIM_UNCHANGED=docs/TEST.md"* ]]; then
  ok "claim root: 同じ repository を指す GIT_DIR（その repo の hook の中）は --root と並べても止めない"
else
  bad "claim root: 同じ repository を指す GIT_DIR で --root の起動を止めた"; cr_dump
fi
cr_run_env "$CR_LINKED/docs" "GIT_DIR=$cr_linked_git_dir" "$CR_LINKED_HELPER" --root "$CR_LINKED/docs" --base HEAD --document docs/TEST.md
if [[ "$CR_RC" -eq 2 && "$CR_ERR" == *"最上位"* ]]; then
  ok "claim root: GIT_DIR が立った環境でも --root の下位 directory を最上位と取り違えない"
else
  bad "claim root: GIT_DIR が立った環境で --root の下位 directory を受けた"; cr_dump
fi
# スクリプト側の判定は受け継いだ GIT_DIR を外して行う（外さないとスクリプトの directory を最上位と読む）
cr_run_env "$CR_MAIN" "GIT_DIR=$CR_MAIN/.git" "$CR_LINKED_HELPER" --base origin/develop --document docs/TEST.md
if [[ "$CR_RC" -eq 2 ]] && printf '%s\n' "$CR_ERR" | grep -Fqx "   スクリプトの repo: ${CR_LINKED_P}"; then
  ok "claim root: GIT_DIR が立った hook の中でも、スクリプト側の repo を worktree の最上位で名指す"
else
  bad "claim root: GIT_DIR が立った環境でスクリプト側の repo を取り違えた"; cr_dump
fi

# AC3: 検証側も --root の worktree を対象にする（cwd は主 checkout のまま）
if ! git -C "$CR_LINKED" add -- docs/TEST.md "$CR_CLAIM_REL" 2>/dev/null; then bad "claim root: linked の文書と claim を stage できない（前段で claim が作られていない）"; fi
cr_run "$CR_MAIN" "$CR_LINKED_VALIDATOR" --root "$CR_LINKED"
if [[ "$CR_RC" -eq 0 && "$CR_OUT" == *"CLAIM_ROOT=${CR_LINKED_P}"* && "$CR_OUT" == *"✓ version claim"* ]]; then
  ok "claim root: 検証側は --root の worktree の index を検証し、出力に対象 repo を示す"
else
  bad "claim root: 検証側が --root の worktree を検証していない"; cr_dump
fi
cr_run "$CR_MAIN" "$CR_LINKED_VALIDATOR" --root "$CR_LINKED/docs"
if [[ "$CR_RC" -eq 2 && "$CR_ERR" == *"最上位"* && "$CR_OUT" != *"✓ version claim"* && "$CR_OUT" != *"未導入"* ]]; then
  ok "claim root: --root に repo の下位 directory を渡すと止める（contract 未導入のスキップへ倒さない）"
else
  bad "claim root: --root の下位 directory を受けた"; cr_dump
fi
cr_run "$CR_OUTSIDE" "$CR_LINKED_VALIDATOR" --root "$CR_LINKED"
if [[ "$CR_RC" -eq 0 && "$CR_OUT" == *"CLAIM_ROOT=${CR_LINKED_P}"* && "$CR_OUT" == *"✓ version claim"* ]]; then
  ok "claim root: 検証側も cwd が repo の外のまま --root の worktree を検証する"
else
  bad "claim root: 検証側が cwd が repo の外だと --root の worktree を検証できない"; cr_dump
fi
# /pre-commit-check の起動形（cwd = repo の最上位・相対パスの起動）は cwd の worktree を対象にする（規則 2 の
# 同じ最上位の分岐）
cr_run "$CR_LINKED" "$CR_REL_SCRIPTS/check-version-claims.sh"
if [[ "$CR_RC" -eq 0 && "$CR_OUT" == *"CLAIM_ROOT=${CR_LINKED_P}"* && "$CR_OUT" == *"✓ version claim"* ]]; then
  ok "claim root: /pre-commit-check と同じ相対パスの起動は cwd の worktree を対象にする"
else
  bad "claim root: 相対パスの起動が cwd の worktree を対象にしていない"; cr_dump
fi

# 規則 2 の同じ最上位の分岐: スクリプトと同じ worktree の下位 directory からの起動は、その worktree を対象にする
cr_run "$CR_LINKED/docs" "$CR_LINKED_HELPER" --base origin/develop --document docs/TEST.md
if [[ "$CR_RC" -eq 0 && "$CR_OUT" == *"CLAIM_ROOT=${CR_LINKED_P}"* && "$CR_OUT" == *"CLAIM_UPDATED=${CR_CLAIM_REL}"* ]]; then
  ok "claim root: cwd がスクリプトと同じ worktree の下位なら、その worktree を対象にする"
else
  bad "claim root: 同じ worktree の下位 directory からの起動を止めた"; cr_dump
fi
# 規則 3: 比べる相手が無い起動は従来どおり cwd の repo を対象にする（導入先の通常の起動を止めない）
cr_run "$CR_MAIN" "$CR_SNAPSHOT/scripts/update-version-claim.sh" --base origin/develop --document docs/TEST.md
if [[ "$CR_RC" -eq 0 && "$CR_OUT" == *"CLAIM_ROOT=${CR_MAIN_P}"* && "$CR_OUT" == *"CLAIM_UNCHANGED=docs/TEST.md"* ]]; then
  ok "claim root: repo の外のスクリプト（導入先のスナップショット）は cwd の repo を対象にする"
else
  bad "claim root: repo の外のスクリプトの起動を止めたか、cwd の repo を対象にしていない"; cr_dump
fi
cr_run "$CR_MAIN" "$CLAIM_HELPER" --base origin/develop --document docs/TEST.md
if [[ "$CR_RC" -eq 0 && "$CR_OUT" == *"CLAIM_ROOT=${CR_MAIN_P}"* && "$CR_OUT" == *"CLAIM_UNCHANGED=docs/TEST.md"* ]]; then
  ok "claim root: 別のリポジトリにあるスクリプト（marketplace の clone 等）は cwd の repo を対象にする"
else
  bad "claim root: 別のリポジトリにあるスクリプトの起動を止めた（toplevel の違いだけで止めている）"; cr_dump
fi
cr_run "$CR_LINKED" "$CR_SNAPSHOT/scripts/check-version-claims.sh"
if [[ "$CR_RC" -eq 0 && "$CR_OUT" == *"CLAIM_ROOT=${CR_LINKED_P}"* && "$CR_OUT" == *"✓ version claim"* ]]; then
  ok "claim root: 検証側も repo の外のスクリプトからの起動は cwd の repo を検証する"
else
  bad "claim root: 検証側が repo の外のスクリプトからの起動を止めたか、cwd の repo を検証していない"; cr_dump
fi
