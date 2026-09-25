#!/usr/bin/env bash
#
# public-layout: 公開リポジトリ単体の checkout を開発ツリーで合成し、公開 CI と同じ実行
# ロジックで公開 suite セットを回す（ADR-068）。
#
# 回帰スイートが開発元（SSOT）のリポジトリ構成を前提にしていても、開発ツリーの run-all は
# 常に SSOT 配置で走るので前提が成立してしまい、赤にならない。露出する経路は週次の
# `weekly-public-run-all`（公開同期の後にしか回せない）だけで、混入から検出まで最大 1 週間 +
# 同期 1 サイクル遅れた。本 suite は公開同期の前に、同じ配置・同じ suite 選定で先に回す。
#
# 合成の手順（公開 checkout との差を詰めるための条件つき）:
#   1. 一時 git リポジトリを作り、origin を公開リポジトリの URL にする（同期スクリプトの
#      target ガードが origin を照合する。push はしない）
#   2. scripts/sync-dev-toolkit-to-public.sh で HEAD のコミット済み内容を展開してコミットする。
#      作業ツリーではなく HEAD を展開するので、run-all が要求する clean な作業ツリーの下では
#      「検査した内容 = コミットした内容」になる
#   3. origin をローカルの bare リポジトリへ差し替え、origin/HEAD を張る（公開 workflow の
#      「Point origin/HEAD at the remote default branch」step と同じ状態。ネットワークに出ない）
#   4. mcp/node_modules はコピーで置く（symlink にすると bundler が realpath で解決して
#      mcp-dist-gate が赤になる）
#   5. 合成した配置の中の `.github/workflows/weekly-public-run-all.yml` から
#      「Run public suite set」step の本文を取り出してそのまま実行する（除外名簿・サマリー検証を
#      二重に持たない）
#
# 合成先は $TMPDIR と /tmp の**外**（${XDG_CACHE_HOME:-$HOME/.cache}/ff-dev-toolkit/）に置く。
# codex の workspace-write sandbox は $TMPDIR / /tmp を常に書けるまま残すので、その配下に
# 合成すると adapter-sandbox-contract の「親ディレクトリへ書けない」前提が崩れて偽陽性になる
# （実測: $TMPDIR 配下の合成で adapter-sandbox-contract と ace-curate-fallback-exec が赤、
# 置き場所を移すと両方緑）。
#
# 実行するのは FF_RUN_PUBLIC_LAYOUT=1 か、下の FF_PUBLIC_LAYOUT_SUITES を明示したときだけ。
# 公開 suite セット 1 周は全件ゲートとほぼ同じ規模（macOS 実測で単体約 19 分・全件ゲート内の並列実行で約 36 分）なので、
# run-all の既定・全件モードのどちらでも回さない（全件ゲートが倍になる）。明示起動するのは公開同期の
# 直前 1 回だけ — scripts/release-dev-toolkit.sh の gate 段が run-all の緑の後に呼ぶ。
# CI（GITHUB_ACTIONS=true）でも skip する — SSOT 側 CI の run-all step は上限 45 分で、予算を超えうる。Linux（GNU coreutils）固有の差は、公開側の
# 週次 CI が引き続き拾う（本 suite は macOS の開発ツリーで回る限り、その型は検出できない）。
#
# FF_PUBLIC_LAYOUT_SUITES（内部の差し替え口）: 空白区切りの suite 名を渡すと、workflow の
# 選定の代わりにそれだけを合成配置で回す（変異注入の負の対照を 1 周 19 分かけずに取るため）。
#
# 空振り検出: 開発元の配置（docs/ がある）で同期スクリプト・yq・mcp/node_modules・公開 workflow の該当 step のいずれかが無い回は skip ではなく非 0（検査不成立）。公開 checkout（docs/ も同期スクリプトも無い）では適用外として skip。合成配置で SSOT の root scripts/ を前提にする suite を 1 本混入させた HEAD では赤（ADR-068 の負の対照）。
# run-all-required: no — run-all からは常に意図して丸ごと skip する（明示起動はリリースの gate 段。skip 理由を 1 行出す）
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
REPO_ROOT="$(cd "$PLUGIN_ROOT/../.." && pwd)"
SYNC_SCRIPT="$REPO_ROOT/scripts/sync-dev-toolkit-to-public.sh"
WORKFLOW_REL=".github/workflows/weekly-public-run-all.yml"
STEP_NAME="Run public suite set"

if [[ "${FF_RUN_PUBLIC_LAYOUT:-}" != "1" && -z "${FF_PUBLIC_LAYOUT_SUITES:-}" ]]; then
  echo "○ skip: 公開同期の直前に明示起動する suite です（本 suite の検査は1件も実行されていません。公開 suite セット 1 周は全件ゲートと同規模のため run-all では回さず、scripts/release-dev-toolkit.sh の gate 段が FF_RUN_PUBLIC_LAYOUT=1 で呼びます）"
  exit 0
fi
if [[ "${GITHUB_ACTIONS:-}" == "true" ]]; then
  echo "○ skip: CI では回しません（本 suite の検査は1件も実行されていません。run-all step の上限 45 分に対し、全件 + 本 suite は予算を超えうるため。公開単体の検査は公開側の週次 CI が担う）"
  exit 0
fi

fail() { echo "✗ public-layout: $*（検査不成立）" >&2; exit 1; }

# 公開 checkout（同期スクリプトも docs/ も同期されない）では前提がそもそも無いので適用外。
# 開発元の配置（docs/ がある）で同期スクリプトだけが無い回は前提の破損として fail に残す
if [[ ! -f "$SYNC_SCRIPT" && ! -d "$REPO_ROOT/docs" ]]; then
  echo "○ skip: 公開 checkout では適用外です（本 suite の検査は1件も実行されていません。開発元の同期スクリプトで公開配置を合成する suite のため）"
  exit 0
fi
[[ -f "$SYNC_SCRIPT" ]] || fail "同期スクリプトがありません: ${SYNC_SCRIPT}（開発元リポジトリでのみ成立する suite。公開 CI の除外名簿に載っているか確認すること）"
command -v yq >/dev/null 2>&1 || fail "yq（mikefarah v4）がありません。公開 workflow の step を取り出せません"
[[ -d "$PLUGIN_ROOT/mcp/node_modules" ]] || fail "mcp/node_modules がありません（npm ci --prefix $PLUGIN_ROOT/mcp を先に実行）"

BASE="${XDG_CACHE_HOME:-$HOME/.cache}/ff-dev-toolkit"
mkdir -p "$BASE" || fail "合成先の親ディレクトリを作れません: $BASE"
case "$BASE/" in
  "${TMPDIR:-/nonexistent-tmpdir}"*|/tmp/*|/private/tmp/*)
    fail "合成先 $BASE が \$TMPDIR か /tmp の配下です。sandbox の境界を検査する suite が偽陽性になるため、XDG_CACHE_HOME を別の場所へ向けてください" ;;
esac
WORK="$(mktemp -d "$BASE/public-layout.XXXXXX")" || fail "合成先を作れません: $BASE"
# 素の `trap 'rm -rf …' EXIT` は途中死（set -u 含む）の終了ステータスを 0 へ上書きするので、
# 最終行のセンチネルで到達を確かめる（run-all/verify.sh case 12 が再混入を検出する）
FF_REACHED_END=0
_cleanup() {
  rm -rf "$WORK"
  if [[ "$FF_REACHED_END" -ne 1 ]]; then
    echo "✗ public-layout: 最後まで到達しませんでした（途中で中断）" >&2
    exit 1
  fi
}
trap _cleanup EXIT
TARGET="$WORK/public"
ORIGIN="$WORK/origin.git"

git init -q -b main "$TARGET" || fail "一時リポジトリを作れません"
git -C "$TARGET" remote add origin https://github.com/feel-flow/ff-dev-toolkit.git
if ! sync_out="$(bash "$SYNC_SCRIPT" --target "$TARGET" 2>&1)"; then
  printf '%s\n' "$sync_out" | tail -20 >&2
  fail "同期スクリプトで公開配置を展開できません"
fi
git -C "$TARGET" add -A
GIT_AUTHOR_NAME=public-layout GIT_AUTHOR_EMAIL=public-layout@localhost \
GIT_COMMITTER_NAME=public-layout GIT_COMMITTER_EMAIL=public-layout@localhost \
  git -C "$TARGET" commit -q -m "public layout" || fail "合成した配置をコミットできません"
git clone -q --bare "$TARGET" "$ORIGIN" || fail "origin 用の bare リポジトリを作れません"
git -C "$TARGET" remote set-url origin "$ORIGIN"
git -C "$TARGET" fetch -q origin || fail "合成 origin を fetch できません"
git -C "$TARGET" remote set-head origin main
[[ "$(git -C "$TARGET" symbolic-ref --quiet --short refs/remotes/origin/HEAD)" == "origin/main" ]] \
  || fail "origin/HEAD を張れません"
cp -R "$PLUGIN_ROOT/mcp/node_modules" "$TARGET/plugins/ff-dev-toolkit/mcp/node_modules" \
  || fail "mcp/node_modules を合成配置へコピーできません"

cd "$TARGET/plugins/ff-dev-toolkit"
# 外側の run-all のモード指定を公開 CI の実行へ持ち込まない（公開 CI はいずれも設定しない）
if [[ -n "${FF_PUBLIC_LAYOUT_SUITES:-}" ]]; then
  suites=()
  for s in $FF_PUBLIC_LAYOUT_SUITES; do
    [[ -f "tests/$s/verify.sh" ]] || fail "FF_PUBLIC_LAYOUT_SUITES の suite が合成配置にありません: $s"
    suites+=("tests/$s/verify.sh")
  done
  echo "public-layout: 合成配置で ${#suites[@]} suite を回します（FF_PUBLIC_LAYOUT_SUITES）"
  env -u FF_RUN_ALL_FULL -u FF_RUN_ALL_FAST -u FF_RUN_ALL_CHANGED bash tests/run-all.sh "${suites[@]}" \
    || { echo "✗ public-layout: 合成した公開配置で suite が赤です" >&2; exit 1; }
else
  n_steps="$(yq "[.jobs[].steps[] | select(.name == \"$STEP_NAME\")] | length" "$TARGET/$WORKFLOW_REL")" \
    || fail "公開 workflow を読めません: $WORKFLOW_REL"
  [[ "$n_steps" == "1" ]] || fail "公開 workflow の「${STEP_NAME}」step が ${n_steps} 件あります（1 件のときだけ本文を一意に取り出せる。改名・複製した場合は本 suite も更新すること）"
  step="$(yq ".jobs[].steps[] | select(.name == \"$STEP_NAME\") | .run" "$TARGET/$WORKFLOW_REL")" \
    || fail "公開 workflow を読めません: $WORKFLOW_REL"
  [[ -n "$step" && "$step" != "null" ]] || fail "公開 workflow の「${STEP_NAME}」step に run 本文がありません"
  # step の working-directory へ追従する（未指定ならリポジトリ root で走る）
  step_wd="$(yq ".jobs[].steps[] | select(.name == \"$STEP_NAME\") | .working-directory // \"\"" "$TARGET/$WORKFLOW_REL")" \
    || fail "公開 workflow の working-directory を読めません"
  cd "$TARGET/${step_wd}" || fail "step の working-directory へ移れません: ${step_wd}"
  printf '%s\n' "$step" > "$WORK/run-public.sh"
  echo "public-layout: 合成した公開配置で「${STEP_NAME}」を実行します（${WORK}）"
  # step 本文は Actions が用意するファイルへ要約を書く。ローカルには無いので合成先に置く
  # （GITHUB_ACTIONS は設定しない — 中の suite が CI 用の挙動へ切り替わるため）
  : > "$WORK/step-summary.md"
  env -u FF_RUN_ALL_FULL -u FF_RUN_ALL_FAST -u FF_RUN_ALL_CHANGED RUNNER_TEMP="$WORK" \
    GITHUB_STEP_SUMMARY="$WORK/step-summary.md" \
    bash -eo pipefail "$WORK/run-public.sh" \
    || { echo "✗ public-layout: 合成した公開配置で公開 suite セットが赤です（公開同期後の週次 CI で同じ赤になる）" >&2; exit 1; }
fi
echo "✓ public-layout: 合成した公開配置で緑"
FF_REACHED_END=1
