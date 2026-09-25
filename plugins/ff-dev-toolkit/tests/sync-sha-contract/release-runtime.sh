#!/usr/bin/env bash
# リリースのオーケストレータ（SSOT の scripts/release-dev-toolkit.sh）の振る舞いを、一時 Git
# リポジトリ（疑似 SSOT + 疑似公開 clone + それぞれの bare origin）で検証する。
#
# オーケストレータが呼ぶ既存スクリプト（リリース要否判定・drift・断片集約・週次 CI 判定・同期・
# footer helper・run-all・CHANGELOG 検査）は fixture 側の stub に差し替える — 本 runtime が
# 固定するのは「順序・分岐・再開（冪等）・外向き操作の有無」で、各スクリプトの判定そのものは
# それぞれの suite が持つ。gh も stub（Release 一覧・作成・公開時刻・PR 照会）で、ネットワークへ
# 出ない。version bump と版節昇格はオーケストレータ自身の処理なので実物で検証する。
#
# 引数: $1 = 検査対象のオーケストレータ / $2 = 同期提案 hook（無ければ hook のケースを省く）
# 終了コード: 0 = 全件 pass / 1 = 退行
# bash 3.2 互換。

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
# shellcheck source=../lib/git-fixture.sh
. "$SCRIPT_DIR/../lib/git-fixture.sh"

ORCH="${1:-}"
HOOK="${2:-}"
[[ -n "$ORCH" && -f "$ORCH" ]] || { echo "✗ オーケストレータがありません: ${ORCH:-<未指定>}" >&2; exit 1; }
ORCH_DIR="$(cd "$(dirname "$ORCH")" && pwd -P)"
REPO_ROOT="$(cd "$ORCH_DIR/.." && pwd -P)"
for need in "$REPO_ROOT/scripts/lib/release-in-flight-functions.sh" \
  "$REPO_ROOT/plugins/ff-dev-toolkit/scripts/lib/commit-identity-functions.sh"; do
  [[ -f "$need" ]] || { echo "✗ オーケストレータの依存 lib がありません: $need" >&2; exit 1; }
done
command -v jq >/dev/null 2>&1 || { echo "✗ jq がありません（オーケストレータの前提）" >&2; exit 1; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/release-runtime.XXXXXX")"
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

# 実行者のグローバル / システム設定（commit.gpgsign・core.hooksPath 等）を fixture へ継承させない
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
SSOT_NAME="$(printf '%s%s' 'feelflow-' 'plugins')"
ID_NAME="Release Runtime"
ID_MAIL="release-runtime@example.com"
STATE="$TMP/state"
SSOT="$TMP/ssot"
SSOT_ORIGIN="$TMP/ssot-origin.git"
PUB_SEED="$TMP/public-seed"
PUB_ORIGIN="$TMP/public-origin.git"
PUB="$TMP/public"
STUB_BIN="$TMP/bin"
mkdir -p "$STATE" "$STUB_BIN"

# ── stub の生成 ──────────────────────────────────────────────────────────────
write_stub() { # $1=path（中身は stdin）
  mkdir -p "$(dirname "$1")"
  cat >"$1"
  chmod +x "$1"
}

# gh: Release 一覧・作成・最新・公開時刻と、同期提案 hook の PR 照会だけを受ける。想定外は大声で落ちる。
write_stub "$STUB_BIN/gh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$RELEASE_RT_STATE/gh.log"
case "$1 $2" in
  "api --paginate") cat "$RELEASE_RT_STATE/releases" 2>/dev/null; exit 0 ;;
  "release create")
    tag="$3"
    printf '%s\n' "$tag" >>"$RELEASE_RT_STATE/releases"
    while [[ $# -gt 0 ]]; do
      if [[ "$1" == --notes-file ]]; then cp "$2" "$RELEASE_RT_STATE/notes-$tag"; fi
      if [[ "$1" == -t ]]; then printf '%s\n' "$2" >"$RELEASE_RT_STATE/title-$tag"; fi
      shift
    done
    exit 0 ;;
  "pr view")
    case "$*" in
      *mergeCommit*) exit 0 ;;
      *) printf '{"state":"MERGED","number":%s}\n' "$3"; exit 0 ;;
    esac ;;
  "pr diff") cat "$RELEASE_RT_STATE/pr-files"; exit 0 ;;
esac
if [[ "$1" == api ]]; then
  case "$*" in
    *releases/latest*published_at*) cat "$RELEASE_RT_STATE/published_at" 2>/dev/null; exit 0 ;;
    *releases/latest*) tail -n 1 "$RELEASE_RT_STATE/releases"; exit 0 ;;
  esac
fi
echo "stub gh: 想定外の呼び出し: $*" >&2
exit 64
STUB

build_ssot_stubs() { # $1=SSOT root
  local r="$1"
  write_stub "$r/scripts/check-release-required.sh" <<'STUB'
#!/usr/bin/env bash
cd "$(git -C "$(dirname "$0")" rev-parse --show-toplevel)" || exit 2
if [[ -f "$RELEASE_RT_STATE/check.force" ]]; then
  cat "$RELEASE_RT_STATE/check.force"
  exit "$(cat "$RELEASE_RT_STATE/check.force.rc")"
fi
ver="$(jq -r .version plugins/ff-dev-toolkit/.claude-plugin/plugin.json)"
latest="$(git -C "$RELEASE_RT_PUBLIC" ls-remote --refs --tags origin | awk -F/ '{print $NF}' | sed 's/^v//' | sort -t. -k1,1n -k2,2n -k3,3n | tail -1)"
frag=0
for f in changelog.d/*.md; do [[ -f "$f" && "${f##*/}" != README.md ]] && frag=$((frag + 1)); done
# 昇格後の再判定（版が進んだ後）だけが帰属の疑いを出す（前版と同一内容の path を版節が参照している回）
if [[ -f "$RELEASE_RT_STATE/check.attr" && "$ver" != "$latest" ]] && grep -qF '`scripts/stale.sh`' oss/ff-dev-toolkit/CHANGELOG.md; then
  echo "ATTRIBUTION_PATH=scripts/stale.sh -> plugins/ff-dev-toolkit/scripts/stale.sh (v${latest} と同一 object)"
  echo "RELEASE_CHECK=ATTRIBUTION_DRIFT"; echo "REASON=stub: 新版節の 1 path が公開側最新タグと同一"; exit 1
fi
if [[ "$ver" == "$latest" && "$frag" -gt 0 ]]; then
  echo "RELEASE_CHECK=RELEASE_REQUIRED"; echo "REASON=stub: 未消費断片 ${frag} 件"; exit 1
fi
echo "RELEASE_CHECK=OK"; echo "REASON=stub: 準備不要"; exit 0
STUB
  write_stub "$r/scripts/check-dev-toolkit-sync-drift.sh" <<STUB
#!/usr/bin/env bash
cd "\$(git -C "\$(dirname "\$0")" rev-parse --show-toplevel)" || exit 1
echo called >>"\$RELEASE_RT_STATE/drift.log"
git fetch -q origin "+refs/heads/develop:refs/remotes/origin/develop" || { echo "SKIP_REASON=fetch"; exit 1; }
base="\$(git -C "\$RELEASE_RT_PUBLIC" log -30 --format=%s origin/main | grep -oE '^sync: ${SSOT_NAME} [0-9a-f]{7,40}' | head -1 | awk '{print \$3}')"
base="\$(git rev-parse "\${base}^{commit}")" || { echo "SKIP_REASON=base"; exit 1; }
echo "DRIFT_COUNT=\$(git rev-list --count "\${base}..origin/develop" -- plugins/ff-dev-toolkit oss/ff-dev-toolkit)"
echo "LAST_SYNC_SHA=\$base"
[[ ! -f "\$RELEASE_RT_STATE/drift.stale" ]] || echo "STALE_TIP=1"
STUB
  write_stub "$r/scripts/materialize-dev-toolkit-changelog.sh" <<'STUB'
#!/usr/bin/env bash
cd "$(git -C "$(dirname "$0")" rev-parse --show-toplevel)" || exit 2
case "$1" in
  --check)
    n=0; for f in changelog.d/*.md; do [[ -f "$f" && "${f##*/}" != README.md ]] && n=$((n + 1)); done
    echo "FRAGMENTS=$n"; exit 0 ;;
  --write)
    cl=oss/ff-dev-toolkit/CHANGELOG.md
    {
      awk '{ print } $0 == "## [Unreleased]" { exit }' "$cl"
      for f in changelog.d/*.md; do
        [[ -f "$f" && "${f##*/}" != README.md ]] || continue
        t="${f##*/}"; t="${t#*.}"; t="${t%%.*}"
        case "$t" in added) h=追加 ;; fixed) h=修正 ;; changed) h=変更 ;; *) h=ドキュメント ;; esac
        printf '\n### %s\n\n' "$h"
        cat "$f"
      done
      awk 'f { print } $0 == "## [Unreleased]" { f = 1 }' "$cl"
    } >"$cl.new"
    mv "$cl.new" "$cl"
    for f in changelog.d/*.md; do [[ -f "$f" && "${f##*/}" != README.md ]] && rm -f "$f"; done
    exit 0 ;;
esac
exit 2
STUB
  write_stub "$r/scripts/check-weekly-run-all-health.sh" <<'STUB'
#!/usr/bin/env bash
if [[ -f "$RELEASE_RT_STATE/health.bad" ]]; then printf '%s\n' "HEALTH=failed" "CRON=alive" "EVIDENCE=failed"; exit 1; fi
printf '%s\n' "HEALTH=healthy" "CRON=alive" "EVIDENCE=satisfied"
STUB
  write_stub "$r/scripts/sync-dev-toolkit-to-public.sh" <<'STUB'
#!/usr/bin/env bash
if [[ "${1:-}" == --list-targets ]]; then printf '%s\n' plugins/ff-dev-toolkit oss/ff-dev-toolkit; exit 0; fi
root="$(git -C "$(dirname "$0")" rev-parse --show-toplevel)"
target="$2"
if [[ "${3:-}" == --dry-run ]]; then echo "ℹ️  禁止パターン検査: クリア"; exit 0; fi
if [[ -f "$RELEASE_RT_STATE/sync.fail-once" ]]; then rm -f "$RELEASE_RT_STATE/sync.fail-once"; echo "stub: 同期失敗" >&2; exit 1; fi
rec="$(git -C "$target" rev-parse --absolute-git-dir)/ff-sync-src-sha"
rm -f "$rec"
mkdir -p "$target/plugins" && rm -rf "$target/plugins/ff-dev-toolkit"
cp -R "$root/plugins/ff-dev-toolkit" "$target/plugins/"
cp "$root/oss/ff-dev-toolkit/CHANGELOG.md" "$target/CHANGELOG.md"
if [[ -f "$RELEASE_RT_STATE/sync.fail-after-write-once" ]]; then rm -f "$RELEASE_RT_STATE/sync.fail-after-write-once"; echo "stub: 書き込み後に失敗" >&2; exit 1; fi
echo "ℹ️  禁止パターン検査: クリア"
git -C "$root" rev-parse HEAD >"$rec"
STUB
  write_stub "$r/scripts/update-dev-toolkit-changelog-footer.sh" <<'STUB'
#!/usr/bin/env bash
cd "$(git -C "$(dirname "$0")" rev-parse --show-toplevel)" || exit 2
latest="$(git -C "$2" tag -l 'v*' | sed 's/^v//' | sort -t. -k1,1n -k2,2n -k3,3n | tail -1)"
grep -q "^\[${latest}\]: " oss/ff-dev-toolkit/CHANGELOG.md \
  || printf '[%s]: https://github.com/feel-flow/ff-dev-toolkit/releases/tag/v%s\n' "$latest" "$latest" >>oss/ff-dev-toolkit/CHANGELOG.md
STUB
  write_stub "$r/plugins/ff-dev-toolkit/scripts/changelog-digest.sh" <<'STUB'
#!/usr/bin/env bash
echo "stub digest $1..$2"
STUB
  write_stub "$r/plugins/ff-dev-toolkit/tests/run-all.sh" <<'STUB'
#!/usr/bin/env bash
echo "run ${FF_RUN_ALL_FULL:-0}" >>"$RELEASE_RT_STATE/runall.log"
[[ ! -f "$RELEASE_RT_STATE/runall.empty" ]] || exit 0
m="$(git -C "$(dirname "$0")" rev-parse --absolute-git-dir)/ff-release-in-flight/info"
[[ ! -f "$m" ]] || cp "$m" "$RELEASE_RT_STATE/marker-seen"
echo "  ○ skip: estimation カテゴリファイルは未作成（stub）"
if [[ -f "$RELEASE_RT_STATE/runall.unknown-skip" ]]; then echo "  ○ skip: codex が無いため live probe を省略（stub）"; fi
echo "suites: total=3 run=3 passed=3 failed=0 skipped=0 not-run=0"
[[ -f "$RELEASE_RT_STATE/runall.no-skipline" ]] || echo "checks-skipped: total=1 suites=1"
exit 0
STUB
  write_stub "$r/plugins/ff-dev-toolkit/tests/changelog-public-tags/verify.sh" <<'STUB'
#!/usr/bin/env bash
cd "$(git -C "$(dirname "$0")" rev-parse --show-toplevel)" || exit 1
n=$(( $(cat "$RELEASE_RT_STATE/tags.calls" 2>/dev/null || echo 0) + 1 )); echo "$n" >"$RELEASE_RT_STATE/tags.calls"
if [[ "$n" == "$(cat "$RELEASE_RT_STATE/tags.skip-at" 2>/dev/null)" ]]; then echo "○ skip: stub（ネットワーク不達）"; exit 0; fi
latest="$(git -C "$RELEASE_RT_PUBLIC" ls-remote --refs --tags origin | awk -F/ '{print $NF}' | sed 's/^v//' | sort -t. -k1,1n -k2,2n -k3,3n | tail -1)"
if grep -q "^\[${latest}\]: " oss/ff-dev-toolkit/CHANGELOG.md; then echo "✓ changelog-public-tags verify: 全 1 件 pass（skip=0）"; exit 0; fi
echo "  ✗ 実タグは存在するがリンク行が無い版: v${latest}" >&2
echo "✗ changelog-public-tags verify: 1 件失敗（pass=0 skip=0）" >&2
exit 1
STUB
  write_stub "$r/plugins/ff-dev-toolkit/tests/changelog-contract/verify.sh" <<'STUB'
#!/usr/bin/env bash
n=$(( $(cat "$RELEASE_RT_STATE/contract.calls" 2>/dev/null || echo 0) + 1 )); echo "$n" >"$RELEASE_RT_STATE/contract.calls"
if [[ "$n" == "$(cat "$RELEASE_RT_STATE/contract.fail-at" 2>/dev/null)" ]]; then echo "✗ changelog-contract verify: stub 失敗" >&2; exit 1; fi
echo "✓ changelog-contract verify"
STUB
  write_stub "$r/plugins/ff-dev-toolkit/tests/changelog-fragments/verify.sh" <<'STUB'
#!/usr/bin/env bash
if [[ -f "$RELEASE_RT_STATE/fragments.fail-once" ]]; then rm -f "$RELEASE_RT_STATE/fragments.fail-once"; echo "✗ changelog-fragments verify: stub 失敗" >&2; exit 1; fi
echo "✓ changelog-fragments verify"
STUB
}

# ── fixture: 疑似 SSOT ───────────────────────────────────────────────────────
mkdir -p "$SSOT/scripts/lib" "$SSOT/plugins/ff-dev-toolkit/.claude-plugin" "$SSOT/plugins/ff-dev-toolkit/scripts/lib" \
  "$SSOT/plugins/ff-dev-toolkit/skills/demo" "$SSOT/plugins/ff-dev-toolkit/docs-template" "$SSOT/oss/ff-dev-toolkit" "$SSOT/changelog.d"
cp "$ORCH" "$SSOT/scripts/release-dev-toolkit.sh"
chmod +x "$SSOT/scripts/release-dev-toolkit.sh"
cp "$REPO_ROOT/scripts/lib/release-in-flight-functions.sh" "$SSOT/scripts/lib/"
cp "$REPO_ROOT/plugins/ff-dev-toolkit/scripts/lib/commit-identity-functions.sh" "$SSOT/plugins/ff-dev-toolkit/scripts/lib/"
build_ssot_stubs "$SSOT"
printf '{\n  "name": "ff-dev-toolkit",\n  "version": "0.31.0",\n  "description": "fixture"\n}\n' \
  >"$SSOT/plugins/ff-dev-toolkit/.claude-plugin/plugin.json"
printf '%s\n' '# config' 'toolkit_version: "0.31.0"' >"$SSOT/plugins/ff-dev-toolkit/scripts/agent-config.yaml"
printf '%s\n' '---' 'name: demo' 'description: demo skill' '---' '' '# demo' >"$SSOT/plugins/ff-dev-toolkit/skills/demo/SKILL.md"
printf '%s\n' '# template' >"$SSOT/plugins/ff-dev-toolkit/docs-template/README.md"
printf '%s\n' '# fragments' >"$SSOT/changelog.d/README.md"
{
  printf '%s\n' '# Changelog' '' '## [Unreleased]' '' '## [0.31.0] - 2026-08-01' '' '### 追加' '' '- 初期リリース' ''
  printf '%s\n' '[Unreleased]: https://github.com/feel-flow/ff-dev-toolkit/compare/v0.31.0...HEAD'
  printf '%s\n' '[0.31.0]: https://github.com/feel-flow/ff-dev-toolkit/releases/tag/v0.31.0'
} >"$SSOT/oss/ff-dev-toolkit/CHANGELOG.md"
# 書き込み先ファイルと接頭辞だけ共有する追跡済みファイル（--resume-with-edits の境界判定の針）
printf '%s\n' '# backup' >"$SSOT/oss/ff-dev-toolkit/CHANGELOG.md.bak"
ff_git_fixture_init "$SSOT" "$ID_NAME" "$ID_MAIL"
git -C "$SSOT" add -A
git -C "$SSOT" commit -qm baseline
git -C "$SSOT" branch -M develop
BASE_SHORT="$(git -C "$SSOT" rev-parse --short HEAD)"
git init -q --bare "$SSOT_ORIGIN"
git -C "$SSOT" remote add origin "$SSOT_ORIGIN"
git -C "$SSOT" push -q origin develop
git -C "$SSOT" branch -q --set-upstream-to=origin/develop develop

# ── fixture: 疑似公開 clone ───────────────────────────────────────────────────
mkdir -p "$PUB_SEED/plugins/ff-dev-toolkit/.claude-plugin"
cp "$SSOT/plugins/ff-dev-toolkit/.claude-plugin/plugin.json" "$PUB_SEED/plugins/ff-dev-toolkit/.claude-plugin/plugin.json"
cp "$SSOT/oss/ff-dev-toolkit/CHANGELOG.md" "$PUB_SEED/CHANGELOG.md"
ff_git_fixture_init "$PUB_SEED" "$ID_NAME" "$ID_MAIL"
git -C "$PUB_SEED" add -A
git -C "$PUB_SEED" commit -qm "sync: ${SSOT_NAME} ${BASE_SHORT} を反映"
git -C "$PUB_SEED" branch -M main
git -C "$PUB_SEED" tag v0.31.0
git init -q --bare "$PUB_ORIGIN"
git -C "$PUB_SEED" remote add origin "$PUB_ORIGIN"
git -C "$PUB_SEED" push -q origin main v0.31.0
ff_git_fixture_init "$PUB" "$ID_NAME" "$ID_MAIL"
git -C "$PUB" remote add origin "$PUB_ORIGIN"
git -C "$PUB" fetch -q --tags origin "+refs/heads/main:refs/remotes/origin/main"
git -C "$PUB" checkout -q -b main origin/main
printf '%s\n' v0.31.0 >"$STATE/releases"

export RELEASE_RT_STATE="$STATE" RELEASE_RT_PUBLIC="$PUB"
export PATH="$STUB_BIN:$PATH"

OUT="" RC=0
run_orch() { # 引数はオーケストレータへ
  RC=0
  OUT="$(bash "$SSOT/scripts/release-dev-toolkit.sh" --public "$PUB" "$@" 2>&1)" || RC=$?
}
has() { [[ "$OUT" == *"$1"* ]]; }
stage_order() { printf '%s\n' "$OUT" | awk '/^RELEASE_STAGE=/ { sub(/^RELEASE_STAGE=/, ""); sub(/ .*/, ""); printf "%s%s", (n++ ? " " : ""), $0 }'; }
dump() { printf '%s\n' "$OUT" | sed 's/^/    | /' >&2; }
count_runall() { if [[ -f "$STATE/runall.log" ]]; then grep -c . "$STATE/runall.log"; else echo 0; fi; }
origin_subjects() { git -C "$SSOT_ORIGIN" log --format=%s develop; }
# パイプ + grep -q は pipefail 下で一致時に反転しうるので、出力を受けてから行単位で照合する
origin_has_subject() { local s; s="$(origin_subjects)"; [[ $'\n'"$s"$'\n' == *$'\n'"$1"$'\n'* ]]; }
drift_calls() { if [[ -f "$STATE/drift.log" ]]; then grep -c . "$STATE/drift.log"; else echo 0; fi; }
iso_ago() { # $1=秒前 → ISO8601 UTC（BSD / GNU date）
  local e=$(( $(date -u +%s) - $1 ))
  date -u -r "$e" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d "@$e" +%Y-%m-%dT%H:%M:%SZ
}
next_minor() { jq -r .version "$SSOT/plugins/ff-dev-toolkit/.claude-plugin/plugin.json" | awk -F. '{ print $1 "." ($2 + 1) ".0" }'; }
commit_push() { # $1=メッセージ（作業ツリーの変更を develop へ push する）
  # 公開対象の実変更も 1 行足す（断片だけのコミットは公開側に出る差分を作らない）
  printf '%s\n' "$1" >>"$SSOT/plugins/ff-dev-toolkit/scripts/changes.txt"
  git -C "$SSOT" add -A
  git -C "$SSOT" commit -qm "$1"
  git -C "$SSOT" push -q origin develop
}

echo "-- release: 段の一覧 --"
run_orch --list-stages
if [[ "$RC" -eq 0 && "$(printf '%s' "$OUT" | tr '\n' ' ')" == "preflight check prepare gate sync tag release footer report" ]]; then
  ok "--list-stages が 9 段を実行順に出す"
else
  bad "--list-stages の出力が期待と違う (rc=$RC)"; dump
fi

echo "-- release: dry-run（準備が必要な回） --"
printf '%s\n' '- デモ機能を追加した' >"$SSOT/changelog.d/101.added.demo.md"
commit_push "feat: demo fragment"
head_before="$(git -C "$SSOT" rev-parse HEAD)"
pub_before="$(git -C "$PUB_ORIGIN" rev-parse main)"
run_orch --dry-run
if [[ "$RC" -eq 0 ]] && has "RELEASE_RESULT=dry-run"; then ok "dry-run は全段を回して exit 0 / RELEASE_RESULT=dry-run"; else bad "dry-run が完走しない (rc=$RC)"; dump; fi
if [[ "$(stage_order)" == "preflight check prepare gate sync tag release footer report" ]]; then
  ok "dry-run の段の順序: preflight → check → prepare → gate → sync → tag → release → footer → report"
else
  bad "dry-run の段の順序が違う: $(stage_order)"; dump
fi
if has "PLAN: version 0.31.0 → 0.32.0（minor" && has "PLAN: git push origin HEAD:refs/heads/develop" \
  && has "PLAN: git -C \"${PUB}\" tag v0.32.0" && has "PLAN: gh release create v0.32.0"; then
  ok "dry-run が bump（minor）・develop 直 push・タグ・Release を実行予定コマンドとして出す"
else
  bad "dry-run の PLAN 行が不足"; dump
fi
if has "一時 clone で集約・昇格を模擬した再判定: RELEASE_CHECK=OK（rc=0）"; then
  ok "dry-run の prepare は一時 clone で集約・昇格を模擬し、再判定の実値（RELEASE_CHECK=OK）を PLAN に出す"
else
  bad "dry-run が昇格後の再判定の実値を出さない"; dump
fi
if [[ "$(git -C "$SSOT" rev-parse HEAD)" == "$head_before" && -z "$(git -C "$SSOT" status --porcelain)" \
  && "$(git -C "$PUB_ORIGIN" rev-parse main)" == "$pub_before" && "$(count_runall)" -eq 0 \
  && -f "$SSOT/changelog.d/101.added.demo.md" && ! -d "$SSOT/.git/ff-release-in-flight" ]] \
  && ! grep -q '^release create' "$STATE/gh.log" 2>/dev/null; then
  ok "dry-run は書き込み・外向き操作・run-all・in-flight 印の取得をしない"
else
  bad "dry-run が何かを書き換えた"; dump
fi

echo "-- release: 本実行（準備 → 同期 → タグ → Release → footer → 収束） --"
run_orch --summary "デモ"
if [[ "$RC" -eq 0 ]] && has "RELEASE_RESULT=released" && has "RELEASE_VERSION=0.32.0"; then
  ok "本実行が released / v0.32.0 で完了する"
else
  bad "本実行が完了しない (rc=$RC)"; dump
fi
if origin_has_subject "release: ff-dev-toolkit v0.32.0" \
  && origin_has_subject "release: CHANGELOG 比較リンクを v0.32.0 へ追従"; then
  ok "準備と footer 追従が release: の単独コミットとして develop へ直 push される（定型 PR を作らない）"
else
  bad "develop に release コミットが無い"; origin_subjects | sed 's/^/    | /' >&2
fi
if ! grep -q '^pr create' "$STATE/gh.log" 2>/dev/null; then ok "PR を作らない（gh pr create を呼ばない）"; else bad "gh pr create を呼んだ"; fi
if [[ "$(jq -r .version "$SSOT/plugins/ff-dev-toolkit/.claude-plugin/plugin.json")" == 0.32.0 ]] \
  && grep -qx 'toolkit_version: "0.32.0"' "$SSOT/plugins/ff-dev-toolkit/scripts/agent-config.yaml" \
  && grep -qx "## \[0.32.0\] - $(date +%F)" "$SSOT/oss/ff-dev-toolkit/CHANGELOG.md" \
  && [[ ! -f "$SSOT/changelog.d/101.added.demo.md" ]] \
  && [[ -z "$(awk '/^## \[Unreleased\]$/{f=1;next} /^## \[/{f=0} f && /^- /' "$SSOT/oss/ff-dev-toolkit/CHANGELOG.md")" ]]; then
  ok "bump（plugin.json / agent-config.yaml）と [Unreleased] → [0.32.0] - 今日 の昇格・断片消費"
else
  bad "bump / 昇格の結果が違う"; dump
fi
if git -C "$PUB_ORIGIN" rev-parse --verify --quiet refs/tags/v0.32.0 >/dev/null \
  && grep -qx v0.32.0 "$STATE/releases" && [[ "$(cat "$STATE/title-v0.32.0" 2>/dev/null)" == "v0.32.0 — デモ" ]] \
  && grep -q "compare/v0.31.0...v0.32.0" "$STATE/notes-v0.32.0" 2>/dev/null; then
  ok "公開側へタグ v0.32.0 を push し、Release（件名 --summary・compare リンク付き）を作る"
else
  bad "タグ / Release が期待どおりでない"; dump
fi
pub_syncs="$(git -C "$PUB_ORIGIN" log --format=%s main | grep -c "^sync: ${SSOT_NAME} " || true)"
if [[ "$pub_syncs" -eq 3 && "$(git -C "$PUB_ORIGIN" log -1 --format=%s main)" == "sync: ${SSOT_NAME} $(git -C "$SSOT" rev-parse --short HEAD) を反映" ]]; then
  ok "footer 追従の後にもう 1 周同期して収束する（公開側の最新 sync commit = SSOT HEAD）"
else
  bad "収束の同期が期待どおりでない（sync commit ${pub_syncs} 件）"; git -C "$PUB_ORIGIN" log --format=%s main | sed 's/^/    | /' >&2
fi
if has "POST_HEALTH=healthy" && has "POST_FOOTER=green" && has "stub digest 0.31.0..0.32.0"; then
  ok "report 段が週次 CI の健全性判定・footer 検査・要約をジョブ出力に残す"
else
  bad "report 段の出力が不足"; dump
fi
if [[ ! -d "$SSOT/.git/ff-release-in-flight" ]]; then ok "完了後に in-flight 印を片付ける"; else bad "in-flight 印が残った"; fi

if [[ -f "$STATE/marker-seen" ]] && grep -q '^token=.' "$STATE/marker-seen" && grep -q "^pid=[0-9]" "$STATE/marker-seen" \
  && grep -q '^version=0.31.0$' "$STATE/marker-seen"; then
  ok "本実行中（ゲートの走行中）は in-flight 印が token・pid・版付きで置かれている"
else
  bad "本実行中に in-flight 印が見えない（$(cat "$STATE/marker-seen" 2>/dev/null | tr '\n' ' ')）"
fi

echo "-- release: 不要（公開対象に未同期の変更が無い） --"
subjects_before="$(origin_subjects)"
run_orch
if [[ "$RC" -eq 0 ]] && has "RELEASE_RESULT=not-needed" && [[ "$(origin_subjects)" == "$subjects_before" ]]; then
  ok "未同期の変更が無く版のタグ・Release・footer が揃っていれば何もせず exit 0 / not-needed"
else
  bad "不要の判定にならない (rc=$RC)"; dump
fi

echo "-- release: 途中で止まったら再実行で続きから（冪等） --"
printf '%s\n' '- 不具合を直した' >"$SSOT/changelog.d/102.fixed.bug.md"
commit_push "fix: bug fragment"
: >"$STATE/sync.fail-once"
runs_before="$(count_runall)"
run_orch
if [[ "$RC" -eq 1 ]] && has "NG: [sync]" && origin_has_subject "release: ff-dev-toolkit v0.32.1"; then
  ok "同期段の失敗で exit 1（NG: [sync]）。patch の準備（v0.32.1）は push 済み"
else
  bad "同期段の失敗の扱いが違う (rc=$RC)"; dump
fi
runs_mid="$(count_runall)"
run_orch
runs_after="$(count_runall)"
if [[ "$RC" -eq 0 ]] && has "RELEASE_VERSION=0.32.1" && has "RELEASE_STAGE=gate STATUS=skip" \
  && [[ "$(jq -r .version "$SSOT/plugins/ff-dev-toolkit/.claude-plugin/plugin.json")" == 0.32.1 ]] \
  && [[ "$((runs_mid - runs_before))" -eq 1 && "$((runs_after - runs_mid))" -eq 1 ]] \
  && git -C "$PUB_ORIGIN" rev-parse --verify --quiet refs/tags/v0.32.1 >/dev/null; then
  ok "再実行は二重 bump せず、同じ HEAD のゲートを回し直さずに（footer 後の 1 回だけ）続きから完了する"
else
  bad "再実行が続きから進まない (rc=$RC run-all: ${runs_before}→${runs_mid}→${runs_after})"; dump
fi

echo "-- release: 止まるべき状態 --"
printf '%s\n' "RELEASE_CHECK=CHANGELOG_MISSING" "REASON=stub: 断片なし" >"$STATE/check.force"
printf '1\n' >"$STATE/check.force.rc"
run_orch --dry-run
if [[ "$RC" -eq 1 ]] && has "NG: [check] CHANGELOG 記載漏れの疑い"; then ok "CHANGELOG_MISSING は exit 1 で止まる"; else bad "CHANGELOG_MISSING で止まらない (rc=$RC)"; dump; fi
printf '%s\n' "RELEASE_CHECK=UNAVAILABLE" "SKIP_REASON=stub: 不達" >"$STATE/check.force"
printf '2\n' >"$STATE/check.force.rc"
run_orch --dry-run
if [[ "$RC" -eq 2 ]] && has "RELEASE_RESULT=unavailable"; then ok "UNAVAILABLE は exit 2（判定不能）で止まる"; else bad "UNAVAILABLE の扱いが違う (rc=$RC)"; dump; fi
printf '%s\n' "RELEASE_CHECK=OK" >"$STATE/check.force"
printf '1\n' >"$STATE/check.force.rc"
run_orch --dry-run
if [[ "$RC" -eq 1 ]] && has "が不一致"; then ok "終了コードと RELEASE_CHECK= の不一致は止まる"; else bad "不一致で止まらない (rc=$RC)"; dump; fi
rm -f "$STATE/check.force" "$STATE/check.force.rc"

RC=0
OUT="$(GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=user.email GIT_CONFIG_VALUE_0=leak@example.invalid \
  bash "$SSOT/scripts/release-dev-toolkit.sh" --public "$PUB" --dry-run 2>&1)" || RC=$?
if [[ "$RC" -eq 1 ]] && has "合成 identity"; then ok "合成 identity（*@example.invalid）では preflight で止まる"; else bad "合成 identity で止まらない (rc=$RC)"; dump; fi

printf '%s\n' '- 追加' >"$SSOT/changelog.d/103.added.more.md"
commit_push "feat: more"
: >"$STATE/runall.unknown-skip"
run_orch
if [[ "$RC" -eq 1 ]] && has "NG: [gate] 許容表に無い部分 skip がある" \
  && [[ "$(git -C "$PUB_ORIGIN" log -1 --format=%s main)" != *"$(git -C "$SSOT" rev-parse --short HEAD)"* ]]; then
  ok "許容表に無い部分 skip はゲートで止まり、同期しない"
else
  bad "未知の部分 skip で止まらない (rc=$RC)"; dump
fi
rm -f "$STATE/runall.unknown-skip"
run_orch
if [[ "$RC" -eq 0 ]] && has "RELEASE_VERSION=0.33.0"; then ok "原因を取り除いた再実行で v0.33.0 まで完了する"; else bad "再実行で完了しない (rc=$RC)"; dump; fi

echo "-- release: 進行中のサイクル（in-flight 印） --"
MARKER="$SSOT/.git/ff-release-in-flight"
mkdir -p "$MARKER"
printf 'pid=%s\nhost=%s\nstarted=%s\nversion=0.33.0\n' "$$" "$(hostname)" "$(date +%s)" >"$MARKER/info"
printf '%s\n' '- さらに追加' >"$SSOT/changelog.d/104.added.again.md"
commit_push "feat: again"
printf 'token=other-owner\npid=%s\nhost=%s\nstarted=%s\nversion=0.33.0\n' "$$" "$(hostname)" "$(date +%s)" >"$MARKER/info"
printf '%s\n' '# 利用者の書きかけ' >>"$SSOT/oss/ff-dev-toolkit/CHANGELOG.md"
printf 'stage=footer\nrepo=%s\nhead=%s\nssot_head=%s\n' "$(cd "$SSOT" && pwd -P)" "$(git -C "$SSOT" rev-parse HEAD)" "$(git -C "$SSOT" rev-parse HEAD)" >"$SSOT/.git/ff-release-writing"
run_orch
if [[ "$RC" -eq 1 ]] && has "別のリリースサイクルが進行中" && [[ "$(awk -F= '$1 == "token" { print $2 }' "$MARKER/info" 2>/dev/null)" == other-owner ]] \
  && [[ "$(tail -n 1 "$SSOT/oss/ff-dev-toolkit/CHANGELOG.md")" == "# 利用者の書きかけ" ]]; then
  ok "生きている他の取得者の印があれば、書きかけの復旧より先に止まり、作業ツリーにも印にも触らない（二重起動の防止）"
else
  bad "進行中でも止まらない、または作業ツリー / 他の取得者の印に触った (rc=$RC)"; dump
fi
git -C "$SSOT" checkout -q -- oss/ff-dev-toolkit/CHANGELOG.md
rm -f "$SSOT/.git/ff-release-writing"
run_orch --due
if [[ "$RC" -eq 0 ]] && has "RELEASE_DUE=in-flight"; then ok "--due は進行中のサイクルを in-flight で返す"; else bad "--due が in-flight を返さない (rc=$RC)"; dump; fi
sleep 0 & dead_pid=$!
wait "$dead_pid" || true
printf 'pid=%s\nhost=%s\nstarted=%s\nversion=0.33.0\n' "$dead_pid" "$(hostname)" "$(date +%s)" >"$MARKER/info"
run_orch
if [[ "$RC" -eq 0 ]] && has "残骸の in-flight 印を回収しました" && has "RELEASE_VERSION=0.34.0" && [[ ! -d "$MARKER" ]]; then
  ok "死んだプロセスの印は残骸として回収し、本実行が完了する"
else
  bad "残骸の印で止まる、または完了しない (rc=$RC)"; dump
fi
# 判定と回収の間に別の取得者が入ると、回収は失敗して新しい印を残す（CAS）
(
  . "$SSOT/scripts/lib/release-in-flight-functions.sh"
  M2="$TMP/cas-marker"
  mkdir -p "$M2"
  printf 'token=stale-a\npid=%s\nhost=%s\nstarted=%s\nversion=x\n' "$dead_pid" "$(hostname)" "$(date +%s)" >"$M2/info"
  snap="$(cat "$M2/info")"
  [[ "$(ff_release_marker_state "$M2" "$snap")" == stale ]] || exit 3
  printf 'token=live-b\npid=%s\nhost=%s\nstarted=%s\nversion=x\n' "$$" "$(hostname)" "$(date +%s)" >"$M2/info"
  ff_release_marker_reclaim "$M2" stale-a && exit 4
  [[ "$(ff_release_marker_field "$M2" token)" == live-b ]] || exit 5
  rc=0; ff_release_marker_try_reclaim "$M2" || rc=$?
  [[ "$rc" -eq 1 && -d "$M2" ]] || exit 6
  exit 0
) && cas_rc=0 || cas_rc=$?
if [[ "$cas_rc" -eq 0 ]]; then
  ok "残骸と判定した後に別の取得者が印を取り直すと、回収は失敗して生きている印を残す（判定と回収は同じ token）"
else
  bad "印の回収が別の取得者の印を消した（ケース rc=${cas_rc}）"
fi

echo "-- release: 書きかけで止まった段からの再開 --"
printf '%s\n' '- 修正と文書' >"$SSOT/changelog.d/105.fixed.mix.md"
printf '%s\n' '- 文書' >"$SSOT/changelog.d/106.docs.mix.md"
commit_push "fix: mixed"
run_orch --dry-run
if [[ "$RC" -eq 0 ]] && has "PLAN: version 0.34.0 → 0.35.0（minor"; then
  ok "版幅: 「修正」に「ドキュメント」が混ざる回は patch ではなく minor（patch は修正のみ）"
else
  bad "混在分類の版幅が minor にならない (rc=$RC)"; dump
fi
: >"$STATE/fragments.fail-once"
run_orch
if [[ "$RC" -eq 1 ]] && has "NG: [prepare]" && [[ -n "$(git -C "$SSOT" status --porcelain)" ]]; then
  run_orch
  if [[ "$RC" -eq 0 ]] && has "書きかけで止まった変更（記録と一致）を戻し" && has "RELEASE_VERSION=0.35.0" \
    && [[ "$(jq -r .version "$SSOT/plugins/ff-dev-toolkit/.claude-plugin/plugin.json")" == 0.35.0 ]]; then
    ok "bump・昇格の後に止まった準備は、再実行が巻き戻してやり直す（二重 bump しない）"
  else
    bad "書きかけの準備から再開できない (rc=$RC)"; dump
  fi
else
  bad "準備段の途中失敗が再現しない (rc=$RC)"; dump
fi
printf '%s\n' '- さらに' >"$SSOT/changelog.d/107.added.more2.md"
commit_push "feat: more2"
echo $(( $(cat "$STATE/contract.calls" 2>/dev/null || echo 0) + 2 )) >"$STATE/contract.fail-at"
run_orch
if [[ "$RC" -eq 1 ]] && has "NG: [footer]" && [[ -n "$(git -C "$SSOT" status --porcelain)" ]]; then
  rm -f "$STATE/contract.fail-at"
  run_orch
  if [[ "$RC" -eq 0 ]] && has "書きかけで止まった変更（記録と一致）を戻し" && has "RELEASE_VERSION=0.36.0" \
    && [[ "$(git -C "$PUB_ORIGIN" log -1 --format=%s main)" == "sync: ${SSOT_NAME} $(git -C "$SSOT" rev-parse --short HEAD) を反映" ]]; then
    ok "footer 更新の後に止まった回は、再実行が巻き戻して footer 段からやり直し収束する"
  else
    bad "書きかけの footer から再開できない (rc=$RC)"; dump
  fi
else
  bad "footer 段の途中失敗が再現しない (rc=$RC)"; dump
fi
rm -f "$STATE/contract.fail-at"
printf '%s\n' '- 公開側' >"$SSOT/changelog.d/108.added.pub.md"
commit_push "feat: pub"
: >"$STATE/sync.fail-after-write-once"
run_orch
if [[ "$RC" -eq 1 ]] && has "NG: [sync]" && [[ -n "$(git -C "$PUB" status --porcelain)" ]]; then
  run_orch
  if [[ "$RC" -eq 0 ]] && has "前回の sync 段が書きかけで止まった変更（記録と一致）を戻し" && has "RELEASE_VERSION=0.37.0"; then
    ok "公開側 clone へ書いた後に止まった同期は、再実行が巻き戻して同期からやり直す"
  else
    bad "公開側の書きかけから再開できない (rc=$RC)"; dump
  fi
else
  bad "公開側書き込み後の失敗が再現しない (rc=$RC)"; dump
fi

echo "-- release: 記録と一致しない書きかけは戻さない --"
printf '%s\n' '- 利用者が直す' >"$SSOT/changelog.d/111.added.user.md"
commit_push "feat: user"
: >"$STATE/fragments.fail-once"
run_orch
if [[ "$RC" -eq 1 ]] && has "NG: [prepare]"; then
  printf '%s\n' '- 利用者が足した行' >>"$SSOT/oss/ff-dev-toolkit/CHANGELOG.md"
  run_orch
  if [[ "$RC" -eq 1 ]] && has "自動では戻さない" && has "FF_DISCARD_UNCOMMITTED=1" && grep -q '^- 利用者が足した行$' "$SSOT/oss/ff-dev-toolkit/CHANGELOG.md"; then
    ok "書きかけの後に利用者が触った回は戻さずに止まり、手で戻す手順を出す（利用者の編集は残る）"
  else
    bad "利用者の編集を戻した、または止まらない (rc=$RC)"; dump
  fi
else
  bad "準備段の途中失敗が再現しない (rc=$RC)"; dump
fi
git -C "$SSOT" checkout -q -- oss/ff-dev-toolkit/CHANGELOG.md plugins/ff-dev-toolkit/.claude-plugin/plugin.json plugins/ff-dev-toolkit/scripts/agent-config.yaml changelog.d
rm -f "$SSOT/.git/ff-release-writing"
: >"$STATE/sync.fail-after-write-once"
run_orch
if [[ "$RC" -eq 1 ]] && has "NG: [sync]"; then
  printf '%s\n' 'x' >"$PUB/stray-untracked.txt"
  run_orch
  if [[ "$RC" -eq 1 ]] && has "自動では戻さない" && [[ -f "$PUB/stray-untracked.txt" ]] && [[ -n "$(git -C "$PUB" diff --name-only)" ]]; then
    ok "公開側 clone に未追跡のファイルが増えた書きかけは reset / clean せずに止まる（公開側の内容は消さない）"
  else
    bad "公開側 clone の書きかけを消した、または止まらない (rc=$RC)"; dump
  fi
else
  bad "公開側書き込み後の失敗が再現しない (rc=$RC)"; dump
fi
rm -f "$PUB/stray-untracked.txt"
git -C "$PUB" checkout -q -- .
rm -f "$SSOT/.git/ff-release-public-writing"
run_orch
[[ "$RC" -eq 0 ]] || { bad "手で戻した後の再実行が完了しない (rc=$RC)"; dump; }

echo "-- release: 昇格後の再判定で止まる回（dry-run の模擬・直した内容の採用） --"
CL="$SSOT/oss/ff-dev-toolkit/CHANGELOG.md"
WRITING="$SSOT/.git/ff-release-writing"
PATCHV="$(jq -r .version "$SSOT/plugins/ff-dev-toolkit/.claude-plugin/plugin.json" | awk -F. '{ print $1 "." $2 "." ($3 + 1) }')"
printf '%s\n' '- 判定を直した（`scripts/stale.sh`）' >"$SSOT/changelog.d/114.fixed.stale.md"
commit_push "fix: stale ref"
: >"$STATE/check.attr"
head_before="$(git -C "$SSOT" rev-parse HEAD)"
mkdir -p "$TMP/orch-tmp"
RC=0
OUT="$(TMPDIR="$TMP/orch-tmp" bash "$SSOT/scripts/release-dev-toolkit.sh" --public "$PUB" --dry-run 2>&1)" || RC=$?
sim_left="$(find "$TMP/orch-tmp" -mindepth 1 -maxdepth 1 -name 'release-*' | head -n 1)"
if [[ "$RC" -eq 1 ]] && has "模擬した再判定: RELEASE_CHECK=ATTRIBUTION_DRIFT（rc=1）" && has "ATTRIBUTION_PATH=scripts/stale.sh" \
  && has "NG: [prepare] 昇格後の再判定が OK にならない（dry-run の模擬" \
  && [[ "$(git -C "$SSOT" rev-parse HEAD)" == "$head_before" && -z "$(git -C "$SSOT" status --porcelain)" ]] \
  && [[ -f "$SSOT/changelog.d/114.fixed.stale.md" && ! -f "$WRITING" && -z "$sim_left" ]]; then
  ok "dry-run は一時 clone で集約・昇格を模擬し、再判定の実値（ATTRIBUTION_DRIFT）を PLAN に出して非 0 で止まる（SSOT は無傷・一時 clone は残さない）"
else
  bad "dry-run が昇格後の再判定の赤を予測しない、または何かを残した (rc=$RC left=${sim_left:-なし})"; dump
fi
run_orch
if [[ "$RC" -eq 1 ]] && has "NG: [prepare] 昇格後の再判定が OK にならない" && has "--resume-with-edits で直した内容を採用して再開する" \
  && ! has "rm \"" && [[ -f "$WRITING" ]]; then
  ok "本実行の停止文は、直した内容を採用して再開する入口（--resume-with-edits）を案内する（記録ファイルを手で消す抜け道を案内しない）"
else
  bad "昇格後の再判定の停止文が再開の設計と噛み合わない (rc=$RC)"; dump
fi
awk '{ gsub(/（`scripts\/stale\.sh`）/, "（判定ヘルパ）"); print }' "$CL" >"$TMP/cl.fixed" && mv "$TMP/cl.fixed" "$CL"
run_orch
if [[ "$RC" -eq 1 ]] && has "自動では戻さない" && has "--resume-with-edits" && grep -qF '（判定ヘルパ）' "$CL"; then
  ok "直した後に付けずに再実行すると、直した内容を戻さずに止まり --resume-with-edits を案内する"
else
  bad "直した内容を戻した、または案内が無い (rc=$RC)"; dump
fi
printf '%s\n' '無関係な編集' >>"$SSOT/plugins/ff-dev-toolkit/skills/demo/SKILL.md"
run_orch --resume-with-edits
if [[ "$RC" -eq 1 ]] && has "prepare 段の書き込み先ではないパスが変わっている" && grep -qF '（判定ヘルパ）' "$CL" \
  && ! grep -q '^adopted=1$' "$WRITING"; then
  ok "--resume-with-edits は prepare の書き込み先以外が変わっていれば何も変えずに止まる（判別できない状態は採用しない）"
else
  bad "書き込み先以外の変更があるのに採用した (rc=$RC)"; dump
fi
git -C "$SSOT" checkout -q -- plugins/ff-dev-toolkit/skills/demo/SKILL.md
printf '%s\n' '接頭辞だけ同じファイルの編集' >>"$SSOT/oss/ff-dev-toolkit/CHANGELOG.md.bak"
run_orch --resume-with-edits
if [[ "$RC" -eq 1 ]] && has "prepare 段の書き込み先ではないパスが変わっている（oss/ff-dev-toolkit/CHANGELOG.md.bak）" \
  && ! grep -q '^adopted=1$' "$WRITING"; then
  ok "--resume-with-edits は書き込み先ファイルと接頭辞だけ同じパス（CHANGELOG.md.bak）を書き込み先と見なさない（ファイルは完全一致）"
else
  bad "接頭辞だけ同じパスの変更を採用した (rc=$RC)"; dump
fi
git -C "$SSOT" checkout -q -- oss/ff-dev-toolkit/CHANGELOG.md.bak
run_orch --resume-with-edits --dry-run
if [[ "$RC" -eq 0 ]] && has "採用した作業ツリーの再判定: RELEASE_CHECK=OK（rc=0）" && has "RELEASE_RESULT=dry-run" \
  && [[ "$(git -C "$SSOT" rev-parse HEAD)" == "$head_before" ]] && ! grep -q '^adopted=1$' "$WRITING"; then
  ok "--resume-with-edits --dry-run は直した内容の再判定（RELEASE_CHECK=OK）を出し、記録も作業ツリーも変えない"
else
  bad "--resume-with-edits --dry-run が違う (rc=$RC)"; dump
fi
echo $(( $(cat "$STATE/contract.calls" 2>/dev/null || echo 0) + 1 )) >"$STATE/contract.fail-at"
run_orch --resume-with-edits
first_rc="$RC"
run_orch
if [[ "$first_rc" -eq 1 && "$RC" -eq 1 ]] && has "自動では戻さない" && has "--resume-with-edits で採用した書きかけ" && grep -qF '（判定ヘルパ）' "$CL"; then
  ok "採用した後に止まった書きかけは、付けない再実行でも自動では戻さない（直した内容を消さない）"
else
  bad "採用した書きかけを付けない再実行が戻した、または止まらない (rc=${first_rc}→${RC})"; dump
fi
rm -f "$STATE/contract.fail-at"
run_orch --resume-with-edits
rel_sha="$(git -C "$SSOT_ORIGIN" log --format='%H %s' develop | awk -v s="release: ff-dev-toolkit v${PATCHV}" '!f && substr($0, 42) == s { print $1; f = 1 }')"
rel_cl="$(git -C "$SSOT" show "${rel_sha:-none}:oss/ff-dev-toolkit/CHANGELOG.md" 2>/dev/null || true)"
if [[ "$RC" -eq 0 ]] && has "RELEASE_RESULT=released" && has "RELEASE_VERSION=${PATCHV}" \
  && [[ "$rel_cl" == *'（判定ヘルパ）'* && "$rel_cl" != *'`scripts/stale.sh`'* ]] \
  && [[ ! -f "$WRITING" && ! -f "$SSOT/changelog.d/114.fixed.stale.md" ]]; then
  ok "--resume-with-edits は直した作業ツリーを採用し、再判定 → release コミット → 同期まで続ける（直した版節がコミットに入る）"
else
  bad "--resume-with-edits で直した内容から再開できない (rc=$RC)"; dump
fi
rm -f "$STATE/check.attr"

echo "-- release: dry-run の同期差分（fetch 済み origin/main 基準・内容差分だけ） --"
git -C "$PUB" reset -q --hard HEAD~1
pub_head_before="$(git -C "$PUB" rev-parse HEAD)"
printf '%s\n' '- 差分' >"$SSOT/changelog.d/115.added.preview.md"
commit_push "feat: preview"
run_orch --dry-run
changed_line="$(printf 'M\tplugins/ff-dev-toolkit/scripts/changes.txt')"
if [[ "$RC" -eq 0 ]] && has "同期差分（公開側 origin/main" && has "タイムスタンプだけの差は出さない）: 1 件" && has "$changed_line" \
  && [[ "$OUT" != *">f"* ]] \
  && [[ "$(git -C "$PUB" rev-parse HEAD)" == "$pub_head_before" && -z "$(git -C "$PUB" status --porcelain)" ]]; then
  ok "dry-run の同期差分は古い公開側 clone の作業ツリーではなく fetch 済み origin/main と比べ、内容が変わるファイルだけを出す（公開側 clone は書き換えない）"
else
  bad "dry-run の同期差分が違う (rc=$RC)"; dump
fi
run_orch
[[ "$RC" -eq 0 ]] || { bad "同期差分の確認の後の本実行が完了しない (rc=$RC)"; dump; }

echo "-- release: ゲートの完走証拠と週次 CI の再評価 --"
printf '%s\n' '- ゲート' >"$SSOT/changelog.d/112.added.gate.md"
commit_push "feat: gate"
: >"$STATE/runall.empty"
run_orch
if [[ "$RC" -eq 1 ]] && has "完走サマリー"; then ok "run-all の出力が空（早期 exit 0）なら緑と読まない"; else bad "空の run-all 出力を緑と読んだ (rc=$RC)"; dump; fi
rm -f "$STATE/runall.empty"
: >"$STATE/runall.no-skipline"
run_orch
if [[ "$RC" -eq 1 ]] && has "完走サマリー"; then ok "部分 skip の会計行（checks-skipped）が無ければ緑と読まない"; else bad "会計行の無い run-all を緑と読んだ (rc=$RC)"; dump; fi
rm -f "$STATE/runall.no-skipline"
: >"$STATE/sync.fail-once"
run_orch
: >"$STATE/health.bad"
run_orch
rm -f "$STATE/health.bad"
if [[ "$RC" -eq 0 ]] && [[ "$(tail -n 2 "$STATE/runall.log" | head -n 1)" == "run 1" ]]; then
  ok "同じ HEAD で fast のゲートが緑でも、週次 CI が healthy でなくなった再実行は全件で回し直す"
else
  bad "週次 CI の悪化を見ずにゲートを省いた (rc=$RC / $(tr '\n' ' ' <"$STATE/runall.log"))"; dump
fi

echo "-- release: ローカルにだけある古いタグ --"
printf '%s\n' '- タグ' >"$SSOT/changelog.d/113.added.tag.md"
commit_push "feat: tag"
NEXTV="$(next_minor)"
git -C "$PUB" tag "v$NEXTV"
run_orch
if [[ "$RC" -eq 1 ]] && has "NG: [tag]" && has "違う commit を指している" && ! git -C "$PUB_ORIGIN" rev-parse --verify --quiet "refs/tags/v$NEXTV" >/dev/null; then
  ok "リモートに無くローカルにだけある同名タグが公開側 HEAD と違えば push しない"
else
  bad "古いローカルタグを公開した、または止まらない (rc=$RC)"; dump
fi
git -C "$PUB" tag -d "v$NEXTV" >/dev/null
run_orch
[[ "$RC" -eq 0 ]] || { bad "古いタグを消した後の再実行が完了しない (rc=$RC)"; dump; }

echo "-- release: 公開側 push の失敗からの再開 --"
mkdir -p "$PUB_ORIGIN/hooks"
cat >"$PUB_ORIGIN/hooks/pre-receive" <<'HK'
#!/usr/bin/env bash
while read -r old new ref; do
  if [[ "$ref" == refs/heads/main && -f "$RELEASE_RT_STATE/reject-main" ]]; then rm -f "$RELEASE_RT_STATE/reject-main"; echo "rejected once" >&2; exit 1; fi
done
exit 0
HK
chmod +x "$PUB_ORIGIN/hooks/pre-receive"
printf '%s\n' '- 拒否' >"$SSOT/changelog.d/109.added.reject.md"
commit_push "feat: reject"
NEXTV="$(next_minor)"
: >"$STATE/reject-main"
run_orch
first_rc="$RC"
run_orch
if [[ "$first_rc" -eq 1 && "$RC" -eq 0 ]] && has "push し損ねた sync commit" \
  && [[ "$(git -C "$PUB_ORIGIN" show main:plugins/ff-dev-toolkit/.claude-plugin/plugin.json | jq -r .version)" == "$NEXTV" ]] \
  && git -C "$PUB_ORIGIN" merge-base --is-ancestor "v$NEXTV" main; then
  ok "公開側 main の push が拒否された後の再実行は、未 push の sync commit を先に push してからタグを main 上に打つ"
else
  bad "公開 push の失敗から回復しない (rc=${first_rc}→${RC})"; dump
fi
rm -f "$PUB_ORIGIN/hooks/pre-receive"

echo "-- release: --only の結果と gate を通らない同期 --"
printf '%s\n' '- only' >"$SSOT/changelog.d/110.added.only.md"
commit_push "feat: only"
state_file="$SSOT/.git/ff-release-state"
awk -F= '$1 != "GATE_OK"' "$state_file" >"$state_file.tmp" && mv "$state_file.tmp" "$state_file"
run_orch --only sync
if [[ "$RC" -eq 1 ]] && has "定期実行点ゲートを通っていない" && has "--only gate"; then
  ok "--only sync は同じ HEAD で gate が緑だった記録が無ければ公開 push しない"
else
  bad "--only sync が gate を素通りした (rc=$RC)"; dump
fi
run_orch --only tag
if [[ "$RC" -eq 1 ]] && has "定期実行点ゲートを通っていない"; then ok "--only tag も gate 緑の記録が無ければタグを打たない"; else bad "--only tag が gate を素通りした (rc=$RC)"; dump; fi
run_orch --only report
if [[ "$RC" -eq 0 ]] && has "RELEASE_RESULT=stage-done" && ! has "RELEASE_RESULT=released"; then
  ok "--only で 1 段だけ走らせた回は released ではなく stage-done を返す"
else
  bad "--only の結果が stage-done にならない (rc=$RC)"; dump
fi
run_orch
[[ "$RC" -eq 0 ]] || { bad "--only の後の全段実行が完了しない (rc=$RC)"; dump; }
CURV="$(jq -r .version "$SSOT/plugins/ff-dev-toolkit/.claude-plugin/plugin.json")"
awk -v v="[$CURV]: " 'index($0, v) != 1' "$SSOT/oss/ff-dev-toolkit/CHANGELOG.md" >"$TMP/cl" && mv "$TMP/cl" "$SSOT/oss/ff-dev-toolkit/CHANGELOG.md"
commit_push "docs: drop footer line"
run_orch --only footer
if [[ "$RC" -eq 1 ]] && has "RELEASE_RESULT=stage-done-unsynced" && has "全段を再実行する"; then
  ok "--only footer が footer を push した回は、公開側へ未反映として rc=1 で全段の再実行を求める"
else
  bad "--only footer の結果が違う (rc=$RC)"; dump
fi
run_orch
[[ "$RC" -eq 0 ]] || { bad "footer の後の全段実行が完了しない (rc=$RC)"; dump; }

echo "-- release: report 段の footer 検査 --"
printf '%s\n' '- 本文だけ' >>"$SSOT/plugins/ff-dev-toolkit/skills/demo/SKILL.md"
commit_push "docs: body before report"
echo $(( $(cat "$STATE/tags.calls" 2>/dev/null || echo 0) + 2 )) >"$STATE/tags.skip-at"
run_orch
if [[ "$RC" -eq 1 ]] && has "NG: [report]" && ! has "RELEASE_RESULT=released"; then
  ok "リリース後の footer 検査が green でなければ released にせず止まる"
else
  bad "report 段の非 green を released にした (rc=$RC)"; dump
fi
rm -f "$STATE/tags.skip-at"

echo "-- release: 粒度（--due） --"
run_orch --due
if [[ "$RC" -eq 0 ]] && has "RELEASE_DUE=no" && has "未同期の公開対象コミットが無い"; then ok "--due: 未同期が無ければ no"; else bad "--due（未同期なし）が違う (rc=$RC)"; dump; fi
printf '%s\n' '' '本文だけの変更' >>"$SSOT/plugins/ff-dev-toolkit/skills/demo/SKILL.md"
commit_push "docs: skill body"
iso_ago 3600 >"$STATE/published_at"
run_orch --due
if [[ "$RC" -eq 0 ]] && has "RELEASE_DUE=no" && has "次の日次リリース"; then ok "--due: 契約変更を含まず最終リリースから 24 時間未満なら no（マージごとの即時リリースをしない）"; else bad "--due（日次待ち）が違う (rc=$RC)"; dump; fi
iso_ago 90000 >"$STATE/published_at"
run_orch --due
if [[ "$RC" -eq 0 ]] && has "RELEASE_DUE=yes" && has "日次リリースの時期"; then ok "--due: 最終リリースから 24 時間を超えたら yes（日次）"; else bad "--due（日次）が違う (rc=$RC)"; dump; fi
iso_ago 3600 >"$STATE/published_at"
awk 'NR == 3 { print "description: demo skill（改訂）"; next } { print }' "$SSOT/plugins/ff-dev-toolkit/skills/demo/SKILL.md" >"$TMP/skill.new"
mv "$TMP/skill.new" "$SSOT/plugins/ff-dev-toolkit/skills/demo/SKILL.md"
commit_push "feat: skill frontmatter"
run_orch --due
if [[ "$RC" -eq 0 ]] && has "RELEASE_DUE=yes" && has "CONTRACT_PATH=plugins/ff-dev-toolkit/skills/demo/SKILL.md"; then
  ok "--due: SKILL.md の frontmatter 変更は契約変更として即時（yes）"
else
  bad "--due（frontmatter）が違う (rc=$RC)"; dump
fi
drift_base="$(git -C "$SSOT" rev-parse HEAD~1)"
calls_before="$(drift_calls)"
run_orch --due --drift-count 1 --last-sync-sha "$drift_base"
if [[ "$RC" -eq 0 ]] && has "RELEASE_DUE=yes" && [[ "$(drift_calls)" -eq "$calls_before" ]]; then
  ok "--due: hook が渡した drift の結果（--drift-count / --last-sync-sha）で判定できる"
else
  bad "--due の引数渡しが効かない (rc=$RC)"; dump
fi
run_orch --due --drift-count x --last-sync-sha "$drift_base"
if [[ "$RC" -eq 2 ]] && has "RELEASE_DUE=unknown"; then ok "--due: 数値でない件数は unknown（exit 2）"; else bad "--due の不正件数を受理した (rc=$RC)"; dump; fi

# ── 同期提案 hook（進行中のサイクル / 粒度） ─────────────────────────────────
if [[ -n "$HOOK" && -f "$HOOK" ]]; then
  echo "-- 同期提案 hook --"
  mkdir -p "$SSOT/.claude/hooks"
  cp "$HOOK" "$SSOT/.claude/hooks/post-merge-dev-toolkit-sync.sh"
  git -C "$SSOT" add -A
  git -C "$SSOT" commit -qm "chore: hook"
  git -C "$SSOT" push -q origin develop
  hook_out() { printf '%s' '{"tool_input":{"command":"gh pr merge 77 --squash"}}' | bash "$SSOT/.claude/hooks/post-merge-dev-toolkit-sync.sh" 2>&1 || true; }
  printf '%s\n' plugins/ff-dev-toolkit/skills/demo/SKILL.md >"$STATE/pr-files"
  mkdir -p "$MARKER"
  printf 'pid=%s\nhost=%s\nstarted=%s\nversion=0.35.0\n' "$$" "$(hostname)" "$(date +%s)" >"$MARKER/info"
  OUT="$(hook_out)"
  if has "リリースサイクルが進行中" && ! has "しますか"; then
    ok "hook: 進行中のサイクルでは同期の再確認を出さない（OBS-270）"
  else
    bad "hook: 進行中なのに再確認を出す"; dump
  fi
  rm -rf "$MARKER"
  OUT="$(hook_out)"
  if has "リリース（同期）しますか"; then ok "hook: 契約変更を含む未同期があれば提案する"; else bad "hook: 契約変更で提案しない"; dump; fi
  run_orch
  [[ "$RC" -eq 0 ]] || { bad "hook 用の前提リリースが完了しない (rc=$RC)"; dump; }
  printf '%s\n' '' '本文だけ' >>"$SSOT/plugins/ff-dev-toolkit/skills/demo/SKILL.md"
  commit_push "docs: body only"
  iso_ago 3600 >"$STATE/published_at"
  OUT="$(hook_out)"
  if has "次の日次リリースで反映" && ! has "しますか"; then
    ok "hook: 契約変更を含まず日次の時期でもなければ承認を求めない"
  else
    bad "hook: 日次待ちなのに提案する"; dump
  fi
  : >"$STATE/drift.stale"
  OUT="$(hook_out)"
  if has "しますか" && ! has "次の日次リリースで反映"; then
    ok "hook: drift が stale（fetch 失敗）のときは「日次待ち」を受理せず提案する"
  else
    bad "hook: stale な drift で日次待ちに倒れた"; dump
  fi
  rm -f "$STATE/drift.stale"
fi

REACHED_END=1
echo "release-runtime: pass=${PASS} fail=${FAIL}"
[[ "$FAIL" -eq 0 ]]
