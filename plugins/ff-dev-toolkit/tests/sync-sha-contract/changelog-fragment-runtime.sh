#!/usr/bin/env bash
# 同期提案 hook（.claude/hooks/post-merge-dev-toolkit-sync.sh）が、公開対象を変えたのに
# changelog.d 断片を含まない PR のマージを CHANGELOG_MISSING として通知するか（Issue `#2150` /
# OBS-099）を、一時 Git リポジトリと stub（gh・同期スクリプト・drift 検査）で検証する。
#
# 固定する振る舞い:
#   - 公開対象を変え断片の無い PR → 通知に CHANGELOG_MISSING と補い方（changelog.d/README.md。
#     bot PR なら断片キー用の Issue の起票）が出る
#   - 断片が揃っている・公開対象外・CHANGELOG 本体を変える（リリース準備）・メタ allowlist だけ・
#     同期スクリプトだけの PR → 断片についての通知は出ない
#   - 判定材料が取れない（変更ファイル取得・公開対象一覧・PR 照会の失敗）→「判定不能」と書き、
#     欠落なしの側へ倒さない
#   - hook のメタ allowlist が scripts/check-release-required.sh の META_ALLOWLIST と一致する
#
# 引数: $1 = 検査対象の hook / $2 = check-release-required.sh（allowlist の正本）
# 終了コード: 0 = 全件 pass / 1 = 退行（対象不在も 1。skip へ倒さない）
# gh は stub でネットワークへ出ない。bash 3.2 互換。

set -euo pipefail

HOOK="${1:-}"
CHECK="${2:-}"
[[ -n "$HOOK" && -f "$HOOK" ]] || { echo "✗ 検査対象の hook がありません: ${HOOK:-<未指定>}" >&2; exit 1; }
[[ -n "$CHECK" && -f "$CHECK" ]] || { echo "✗ allowlist の正本がありません: ${CHECK:-<未指定>}" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "✗ jq がありません（hook の前提）" >&2; exit 1; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/changelog-fragment-runtime.XXXXXX")"
REACHED_END=0
cleanup() {
  local rc=$?
  rm -rf "$TMP"
  if [[ "$REACHED_END" -ne 1 && "$rc" -eq 0 ]]; then rc=1; fi
  exit "$rc"
}
trap cleanup EXIT
trap 'exit 130' HUP INT TERM

PASS=0
FAIL=0
ok()  { echo "  ✓ $1"; PASS=$((PASS + 1)); }
bad() { echo "  ✗ $1" >&2; FAIL=$((FAIL + 1)); }

export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
unset GIT_DIR GIT_WORK_TREE 2>/dev/null || true
REPO="$TMP/repo"
STATE="$TMP/state"
STUB_BIN="$TMP/bin"
mkdir -p "$REPO/.claude/hooks" "$REPO/scripts" "$STATE" "$STUB_BIN"
git init -q "$REPO"
cp "$HOOK" "$REPO/.claude/hooks/post-merge-dev-toolkit-sync.sh"

write_stub() { # $1=path（中身は stdin）
  cat >"$1"
  chmod +x "$1"
}

# 同期スクリプト: 公開対象一覧だけを返す。list.fail があれば失敗する
write_stub "$REPO/scripts/sync-dev-toolkit-to-public.sh" <<'STUB'
#!/usr/bin/env bash
[[ "${1:-}" == --list-targets ]] || exit 64
[[ ! -f "$CF_RT_STATE/list.fail" ]] || exit 1
printf '%s\n' plugins/ff-dev-toolkit oss/ff-dev-toolkit
STUB
# drift 検査: 未同期 3 件を返す（同期提案まで到達させ、hook が最後まで走ったことを文面で確かめる）
write_stub "$REPO/scripts/check-dev-toolkit-sync-drift.sh" <<'STUB'
#!/usr/bin/env bash
echo "DRIFT_COUNT=3"
echo "LAST_SYNC_SHA=0123456789abcdef0123456789abcdef01234567"
STUB
# gh: PR 照会と変更ファイル一覧だけを受ける。想定外は大声で落ちる
write_stub "$STUB_BIN/gh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$CF_RT_STATE/gh.log"
case "$1 $2" in
  "pr view")
    case "$*" in
      *mergeCommit*) exit 0 ;;
    esac
    [[ ! -f "$CF_RT_STATE/view.fail" ]] || exit 1
    cat "$CF_RT_STATE/pr-view.json"
    exit 0 ;;
  "pr diff")
    [[ ! -f "$CF_RT_STATE/diff.fail" ]] || exit 1
    cat "$CF_RT_STATE/pr-files"
    exit 0 ;;
esac
echo "stub gh: 想定外の呼び出し: $*" >&2
exit 64
STUB

HUMAN_VIEW='{"state":"MERGED","number":77,"author":{"login":"someone","is_bot":false}}'
BOT_VIEW='{"state":"MERGED","number":77,"author":{"login":"app/dependabot","is_bot":true}}'

OUT=""
# $1=pr view の JSON、残り = 変更ファイル
run_hook() {
  local view="$1"
  shift
  printf '%s\n' "$view" >"$STATE/pr-view.json"
  if [[ $# -gt 0 ]]; then printf '%s\n' "$@" >"$STATE/pr-files"; else : >"$STATE/pr-files"; fi
  OUT="$(printf '%s' '{"tool_input":{"command":"gh pr merge 77 --squash"}}' \
    | CF_RT_STATE="$STATE" PATH="$STUB_BIN:$PATH" bash "$REPO/.claude/hooks/post-merge-dev-toolkit-sync.sh" 2>&1)" || true
  # 通知は JSON の additionalContext。読めなければ生の出力のまま照合する（壊れた出力は下の針で赤になる）
  local ctx
  if ctx="$(printf '%s' "$OUT" | jq -r '.hookSpecificOutput.additionalContext' 2>/dev/null)" && [[ -n "$ctx" && "$ctx" != null ]]; then
    OUT="$ctx"
  fi
}
has() { [[ "$OUT" == *"$1"* ]]; }
dump() { printf '%s\n' "$OUT" | sed 's/^/    | /' >&2; }
# 「hook が最後まで走って同期提案を出した」ことの確認（断片の通知が出ないケースの空振り除け）
reached_proposal() { has "リリース（同期）しますか"; }

echo "-- changelog 断片の欠落通知 --"

# 1. 公開対象を変え断片の無い人の PR → CHANGELOG_MISSING と補い方
run_hook "$HUMAN_VIEW" plugins/ff-dev-toolkit/scripts/foo.sh docs/notes.md
if has "CHANGELOG_MISSING" && has "changelog.d/README.md" && has "plugins/ff-dev-toolkit/scripts/foo.sh" \
  && has "元 Issue の番号をキーに" && reached_proposal; then
  ok "断片の無い公開対象の変更 → CHANGELOG_MISSING・名指しの path・changelog.d/README.md の手順を通知し、同期提案も残す"
else
  bad "断片の無い公開対象の変更を CHANGELOG_MISSING として通知しない"; dump
fi

# 2. bot PR → 断片キー用の Issue の起票を案内する
run_hook "$BOT_VIEW" oss/ff-dev-toolkit/.github/workflows/weekly-public-run-all.yml
if has "CHANGELOG_MISSING" && has "bot（app/dependabot）" && has "断片キー用の Issue を 1 件起票"; then
  ok "bot PR の断片欠落 → 断片キー用の Issue の起票を案内する（ACE-2149-1）"
else
  bad "bot PR の断片欠落で断片キー用の Issue を案内しない"; dump
fi

# 2b. author の login だけが bot 形（is_bot を返さない gh）でも bot と読む
run_hook '{"state":"MERGED","number":77,"author":{"login":"dependabot[bot]"}}' plugins/ff-dev-toolkit/tests/x/verify.sh
if has "CHANGELOG_MISSING" && has "断片キー用の Issue を 1 件起票"; then
  ok "login が [bot] 形なら is_bot が無くても bot PR として案内する"
else
  bad "login が [bot] 形の PR を bot として扱わない"; dump
fi

# 2b'. is_bot だけが bot を示す（login が bot 形でない）ときも bot と読む
run_hook '{"state":"MERGED","number":77,"author":{"login":"some-automation","is_bot":true}}' plugins/ff-dev-toolkit/tests/x/verify.sh
if has "CHANGELOG_MISSING" && has "bot（some-automation）"; then
  ok "author.is_bot が true なら login の形に依らず bot PR として案内する"
else
  bad "author.is_bot を見ていない"; dump
fi

# 2c. author が取れない（古い gh・stub）→ 判定は止めず、両方の手順を併記する
run_hook '{"state":"MERGED","number":77}' plugins/ff-dev-toolkit/skills/a/SKILL.md
if has "CHANGELOG_MISSING" && has "元 Issue の番号をキーに" && has "断片キー用の Issue を起票"; then
  ok "作成者が取れなくても欠落を通知し、人・bot 両方の手順を併記する"
else
  bad "作成者が取れないと欠落を通知しない"; dump
fi

# 3. 断片が揃っている → 断片の通知なし（同期提案までは到達）
run_hook "$HUMAN_VIEW" plugins/ff-dev-toolkit/scripts/foo.sh changelog.d/2150.added.post-merge.md
if ! has "CHANGELOG_MISSING" && ! has "判定不能" && reached_proposal; then
  ok "断片を含む PR → 断片についての通知を出さない"
else
  bad "断片を含む PR に断片の通知を出した"; dump
fi

# 4. 公開対象外の PR → 断片の通知なし（公開対象外の通知までは到達）
run_hook "$HUMAN_VIEW" docs/notes.md .claude/hooks/other.sh
if ! has "CHANGELOG_MISSING" && ! has "判定不能" && has "公開対象外"; then
  ok "公開対象外の PR → 断片についての通知を出さない"
else
  bad "公開対象外の PR に断片の通知を出した"; dump
fi

# 5. CHANGELOG 本体を変える形（リリース準備の bump・footer 追従）→ 断片の通知なし。
#    断片の消費（削除）を混ぜると断片の存在で緑になり CHANGELOG の例外を測れないので、混ぜない
run_hook "$HUMAN_VIEW" oss/ff-dev-toolkit/CHANGELOG.md plugins/ff-dev-toolkit/.claude-plugin/plugin.json
if ! has "CHANGELOG_MISSING" && reached_proposal; then
  ok "CHANGELOG 本体を変える PR（リリース準備・footer 追従）→ 断片の通知を出さない"
else
  bad "リリース準備の PR に断片の欠落を通知した"; dump
fi

# 6. メタ allowlist だけ・同期スクリプトだけ → 断片の通知なし
run_hook "$HUMAN_VIEW" oss/ff-dev-toolkit/README.md oss/ff-dev-toolkit/USING_WITH_VSCODE_COPILOT.md
if ! has "CHANGELOG_MISSING" && reached_proposal; then
  ok "告知不要のメタ変更だけの PR → 断片の通知を出さない"
else
  bad "メタ allowlist だけの PR に断片の欠落を通知した"; dump
fi
run_hook "$HUMAN_VIEW" scripts/sync-dev-toolkit-to-public.sh
if ! has "CHANGELOG_MISSING" && reached_proposal; then
  ok "同期スクリプトだけの PR（公開側に内容が出ない）→ 断片の通知を出さない"
else
  bad "同期スクリプトだけの PR に断片の欠落を通知した"; dump
fi

# 7. 断片の置き場の外（changelog.d の下位ディレクトリ・README）は断片に数えない（OBS-191）
run_hook "$HUMAN_VIEW" plugins/ff-dev-toolkit/scripts/foo.sh changelog.d/sub/2150.added.x.md changelog.d/README.md
if has "CHANGELOG_MISSING"; then
  ok "changelog.d の下位ディレクトリと README は断片に数えない"
else
  bad "正本外の changelog.d ファイルを断片として受理した"; dump
fi

# 8. 名指しは 5 件まで、件数は全数
run_hook "$HUMAN_VIEW" plugins/ff-dev-toolkit/a1 plugins/ff-dev-toolkit/a2 plugins/ff-dev-toolkit/a3 \
  plugins/ff-dev-toolkit/a4 plugins/ff-dev-toolkit/a5 plugins/ff-dev-toolkit/a6 plugins/ff-dev-toolkit/a7
if has "公開対象を 7 件変更していますが" && has "plugins/ff-dev-toolkit/a5 ほか" && ! has "plugins/ff-dev-toolkit/a6"; then
  ok "名指しは 5 件まで・件数は全数で出す"
else
  bad "名指しの打ち切り・件数が違う"; dump
fi

# 9. 判定不能: 変更ファイル取得・公開対象一覧・PR 照会の失敗 → 「判定不能」と書き、欠落なしへ倒さない
: >"$STATE/diff.fail"
run_hook "$HUMAN_VIEW" plugins/ff-dev-toolkit/scripts/foo.sh
rm -f "$STATE/diff.fail"
if has "changelog 断片の有無は判定不能" && has "欠落なしとは判定していません" && ! has "CHANGELOG_MISSING"; then
  ok "変更ファイルを取れない → 断片の有無を「判定不能」と書く"
else
  bad "変更ファイル取得の失敗で断片の判定不能を書かない"; dump
fi
: >"$STATE/list.fail"
run_hook "$HUMAN_VIEW" plugins/ff-dev-toolkit/scripts/foo.sh
rm -f "$STATE/list.fail"
if has "changelog 断片の有無は判定不能" && has "公開対象パターンの構築に失敗"; then
  ok "公開対象一覧を取れない → 断片の有無を「判定不能」と書く"
else
  bad "公開対象一覧の失敗で断片の判定不能を書かない"; dump
fi
: >"$STATE/view.fail"
run_hook "$HUMAN_VIEW" plugins/ff-dev-toolkit/scripts/foo.sh
rm -f "$STATE/view.fail"
if has "changelog 断片の有無は判定不能" && has "gh の認証状態を確認してください"; then
  ok "PR を照会できない → 断片の有無を「判定不能」と書く"
else
  bad "PR 照会の失敗で断片の判定不能を書かない"; dump
fi

# 10. メタ allowlist の正本との一致（片方だけ増減すると、hook が告知不要の変更に欠落を出すか、
#     告知の要る変更を黙って通す）。配列が読めない（0 件）ときは一致扱いにしない
extract_array() { # $1=ファイル $2=配列名
  awk -v name="$2" '
    $0 ~ "^" name "=\\(" { f = 1; next }
    f && /^\)/ { f = 0; next }
    f { gsub(/^[[:space:]]+|[[:space:]]+$/, ""); gsub(/"/, ""); if ($0 != "") print }
  ' "$1"
}
hook_list="$(extract_array "$HOOK" CHANGELOG_META_ALLOWLIST)"
check_list="$(extract_array "$CHECK" META_ALLOWLIST)"
if [[ -z "$hook_list" || -z "$check_list" ]]; then
  bad "メタ allowlist を読めない（hook=$(printf '%s' "$hook_list" | grep -c '' || true) 件 / 正本=$(printf '%s' "$check_list" | grep -c '' || true) 件）"
elif [[ "$hook_list" == "$check_list" ]]; then
  ok "hook のメタ allowlist が check-release-required.sh の META_ALLOWLIST と一致（$(printf '%s\n' "$hook_list" | grep -c '') 件）"
else
  bad "hook のメタ allowlist が正本と食い違う（hook: $(printf '%s' "$hook_list" | tr '\n' ' ')/ 正本: $(printf '%s' "$check_list" | tr '\n' ' ')）"
fi

# stub 経由で走ったこと（実 gh がネットワークへ出ていない）
if [[ -s "$STATE/gh.log" ]]; then
  ok "gh は stub 経由で呼ばれている"
else
  bad "gh stub が呼ばれていない（PATH 差し込みが効いていない疑い）"
fi

REACHED_END=1
echo "changelog-fragment-runtime: pass=${PASS} fail=${FAIL}"
[[ "$FAIL" -eq 0 ]]
