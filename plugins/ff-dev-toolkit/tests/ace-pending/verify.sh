#!/usr/bin/env bash
# ACE候補の保存・再評価・lookup統合（Issue `#2040`）。
# run-all-required: yes 候補の保全・解決・検索が未検証のまま完了させない
# 空振り検出: CLI不在/空、候補台帳の空ファイル/不正schema、件数report不在/0件一致/重複/書式変更を赤とする。認識済schemaの候補0件・容量内の無書込は正常として実測する。
set -euo pipefail
HERE="$(CDPATH='' cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
PLUGIN="$(CDPATH='' cd -P -- "$HERE/../.." && pwd -P)"
# shellcheck source=../lib/git-fixture.sh
. "$PLUGIN/tests/lib/git-fixture.sh"
CLI="$PLUGIN/scripts/ace-pending.sh"
LOOKUP="$PLUGIN/scripts/knowledge-lookup.sh"
for file in "$CLI" "$LOOKUP" "$PLUGIN/scripts/lib/ace-pending-functions.sh"; do
  if [ ! -f "$file" ] || [ ! -s "$file" ] || [ ! -r "$file" ]; then
    printf '✗ ace-pending: 対象を読めません: %s\n' "$file" >&2; exit 1
  fi
done
TMP="$(mktemp -d "${TMPDIR:-/tmp}/ace-pending-test.XXXXXX")"
cleanup() {
  local rc=$?
  if [ "$rc" -ne 0 ] && [ -f "$TMP/count-err" ]; then cat "$TMP/count-err" >&2; fi
  rm -rf -- "$TMP"
}
trap cleanup EXIT
PASS=0; FAIL=0
ok() { PASS=$((PASS + 1)); printf '✓ %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '✗ %s\n' "$1"; }
expect_rc() {
  local label="$1" expected="$2" rc=0; shift 2
  "$@" >"$TMP/out" 2>"$TMP/err" || rc=$?
  if [ "$rc" -eq "$expected" ]; then ok "$label (rc=$rc)"; else bad "$label: expected=$expected actual=$rc"; cat "$TMP/out" "$TMP/err"; fi
}
contains() { if grep -Fq -- "$2" "$1"; then ok "$3"; else bad "$3"; cat "$1"; fi; }
same() { if cmp -s "$1" "$2"; then ok "$3"; else bad "$3"; fi; }
absent() { if [ ! -e "$1" ]; then ok "$2"; else bad "$2"; fi; }
BOOK="$TMP/project/custom docs/PLAYBOOK.md"
PENDING="${BOOK%/*}/PENDING_CANDIDATES.md"
mkdir -p -- "${BOOK%/*}"
cat >"$BOOK" <<'BOOK'
---
title: ACE Playbook
version: 1.0.0
status: draft
owner: fixture
created: 2026-10-23
updated: 2026-10-23
changeImpact: medium
ace_entry_count: 1
---

# ACE Playbook

## エントリ一覧

### ACE-1-1: existing needle

| Category | testing | Origin | fixture PR 1 |
| Date | 2026-10-23 |
| Helpful | 0 | Harmful | 0 |
| Status | active |

existing needle body.

---

## Changelog

### [1.0.0] - 2026-10-23

#### 追加

- ACE-1-1: seed
BOOK
BODY="$TMP/body.md"; REPORT="$TMP/capacity.txt"
printf 'needle body\n\n### ACE-999: quoted heading\n| Category | architecture |\n---\n' >"$BODY"
printf 'testing: 1\nブロック上限: 1 件/カテゴリ\n' >"$REPORT"
defer() {
  bash "$CLI" defer --playbook "$BOOK" --id PENDING-PR-900-1 --category testing \
    --origin 'fixture PR 900' --title 'needle pending' --body-file "$BODY" \
    --capacity-report "$REPORT" --capacity-rc 0 --proposed 1 "$@"
}
lookup() { bash "$LOOKUP" --root "$TMP/project" --playbook "$BOOK" --offline "$@"; }

expect_rc '初期statusは不在を0件として返す' 0 bash "$CLI" status --playbook "$BOOK"
contains "$TMP/out" 'PENDING_COUNT=0' '初期0件'
absent "$PENDING" 'statusはstoreを作らない'
lookup needle >"$TMP/baseline-text"
lookup --format tsv --all needle body >"$TMP/baseline-tsv"
same "$HERE/fixtures/lookup-without-pending.txt" "$TMP/baseline-text" '不在のtextは変更前の固定出力と一致'
same "$HERE/fixtures/lookup-without-pending.tsv" "$TMP/baseline-tsv" '不在のTSVは変更前の固定出力と一致'
printf 'testing: 0\nブロック上限: 1 件/カテゴリ\n' >"$REPORT"
expect_rc '容量内は従来の追記へ戻す' 0 defer
contains "$TMP/out" 'PENDING_REASON=capacity-available' '容量内の明示'
absent "$PENDING" '容量内はstoreへ書かない'
lookup needle >"$TMP/after-text"
lookup --format tsv --all needle body >"$TMP/after-tsv"
same "$TMP/baseline-text" "$TMP/after-text" '不在のtext出力は同一'
same "$TMP/baseline-tsv" "$TMP/after-tsv" '不在のTSV出力は同一'

printf 'testing: 1\nブロック上限: 1 件/カテゴリ\n' >"$REPORT"
expect_rc '上限で候補を保存' 0 defer
contains "$TMP/out" 'PENDING_COUNT=1' '保存後1件'
cp "$PENDING" "$TMP/saved"
expect_rc '同ID同内容の再送は冪等' 0 defer
same "$PENDING" "$TMP/saved" '再送で重複しない'
expect_rc '同ID異内容は拒否' 1 defer --title changed
same "$PENDING" "$TMP/saved" '拒否後に元候補を保全'
printf 'testing: 1\ncoding: 0\nブロック上限: 1 件/カテゴリ\n' >"$REPORT"
expect_rc '混在: 停止根拠なしの容量内カテゴリは保存しない' 0 defer --id PENDING-PR-900-2 --category coding
same "$PENDING" "$TMP/saved" '停止根拠なしでは元候補だけ'
expect_rc '混在: testingの停止を根拠にcoding候補も保存' 0 defer --id PENDING-PR-900-2 --category coding --capacity-category testing
contains "$TMP/out" 'PENDING_COUNT=2' '混在する全2候補を保全'
expect_rc '混在: codingもpendingとして引ける' 0 lookup needle
contains "$TMP/out" 'PENDING-PR-900-2' '容量内カテゴリの候補も失わない'
expect_rc '混在: 停止カテゴリがreportに無ければ赤' 2 defer --capacity-category missing
printf 'testing: 2\ncoding: 0\nブロック上限: 1 件/カテゴリ\n' >"$REPORT"
expect_rc '既に超過: 原因カテゴリの追加予定0でも他候補を保全' 0 defer --id PENDING-PR-900-3 --category coding --capacity-category testing --capacity-rc 1 --proposed 0
contains "$TMP/out" 'PENDING_COUNT=3' '既存超過で全3候補を保持'
expect_rc '既存超過fixtureの候補を解決' 0 bash "$CLI" resolve --playbook "$BOOK" --id PENDING-PR-900-3 --decision rejected --result fixture-cleanup
expect_rc '混在fixtureのcoding候補を解決' 0 bash "$CLI" resolve --playbook "$BOOK" --id PENDING-PR-900-2 --decision rejected --result fixture-cleanup
same "$PENDING" "$TMP/saved" '他カテゴリの除去後も元候補を保全'
printf 'testing: 1\nブロック上限: 1 件/カテゴリ\n' >"$REPORT"
expect_rc '独自配置から保留を本文検索' 0 lookup 'quoted heading'
contains "$TMP/out" 'PENDING-PR-900-1' '本文にだけある語もヒット'
contains "$TMP/out" '保留（pending。採用前の候補' '採用前の状態を明示'
expect_rc 'AND検索/TSV' 0 lookup --format tsv --all needle body
contains "$TMP/out" $'pending\tPENDING-PR-900-1\tpending\tCategory=testing Origin=fixture PR 900' 'TSVは専用store/status'
awk -F '\t' '$1=="pending" { n++; if (NF != 6 || $3 != "pending" || $4 != "Category=testing Origin=fixture PR 900" || $5 != "needle pending" || $6 !~ /PENDING_CANDIDATES.md#/) exit 1 } END { if(n!=1) exit 1 }' "$TMP/out" && ok 'TSV6列' || bad 'TSV6列'
expect_rc 'AND不一致は0件' 0 lookup --all needle absentword
contains "$TMP/out" 'pending=0' '候補の空一致を明示'
expect_rc '再評価しても容量不足なら保持' 0 defer
same "$PENDING" "$TMP/saved" '再満杯の候補を保全'
expect_rc 'promoted-openへ混ぜない' 2 bash "$LOOKUP" --root "$TMP/project" --playbook "$BOOK" --promoted-open --offline
if grep -Fq 'PENDING-PR-900-1' "$TMP/out"; then bad 'promoted-openは候補を出さない'; else ok 'promoted-openは観測台帳だけ'; fi

expect_rc '件数検査rc2を容量不足に置換しない' 2 defer --capacity-rc 2
same "$PENDING" "$TMP/saved" '検査不成立は保全'
expect_rc 'report不在は赤' 2 defer --capacity-report "$TMP/missing"
for fixture in empty no-limit no-category duplicate changed no-unit huge; do
  case "$fixture" in
    empty) : >"$REPORT" ;;
    no-limit) printf 'testing: 1\n' >"$REPORT" ;;
    no-category) printf 'coding: 1\nブロック上限: 1 件/カテゴリ\n' >"$REPORT" ;;
    duplicate) printf 'testing: 1\ntesting: 1\nブロック上限: 1 件/カテゴリ\n' >"$REPORT" ;;
    no-unit) printf 'testing: 1\nブロック上限: 1\n' >"$REPORT" ;;
    changed) printf 'testing = 1\nブロック上限: 1 件/カテゴリ\n' >"$REPORT" ;;
    huge) printf 'testing: 999999999999999999999999\nブロック上限: 1 件/カテゴリ\n' >"$REPORT" ;;
  esac
  expect_rc "不正report: $fixture" 2 defer
  same "$PENDING" "$TMP/saved" "不正reportの保全: $fixture"
done
printf 'testing: 1\nブロック上限: 1 件/カテゴリ\n' >"$REPORT"
expect_rc '本文不在は赤' 2 defer --body-file "$TMP/missing"
: >"$TMP/empty-body"
expect_rc '空の通常ファイルの本文は赤' 2 defer --body-file "$TMP/empty-body"
same "$PENDING" "$TMP/saved" '本文不成立でも保全'
chmod 000 "$REPORT"
if [ ! -r "$REPORT" ]; then expect_rc '読めないreportは赤' 2 defer; else printf '  ○ skip: このfilesystem/権限ではreportの読取拒否を再現できません\n'; fi
chmod 600 "$REPORT"
chmod 000 "$PENDING"
if [ ! -r "$PENDING" ]; then expect_rc '読めない候補storeは赤' 2 lookup needle; else printf '  ○ skip: このfilesystem/権限ではstoreの読取拒否を再現できません\n'; fi
chmod 600 "$PENDING"
mkdir "$PENDING.lock"
expect_rc '同じstoreの更新中は拒否' 2 defer
rmdir "$PENDING.lock"
same "$PENDING" "$TMP/saved" '並走の候補を壊さない'

for fixture in empty malformed duplicate; do
  case "$fixture" in
    empty) : >"$PENDING" ;;
    malformed) printf '# wrong schema\n' >"$PENDING" ;;
    duplicate) cat "$TMP/saved" >"$PENDING"; awk '/^### / { keep=1 } keep {print}' "$TMP/saved" >>"$PENDING" ;;
  esac
  cp "$PENDING" "$TMP/broken"
  expect_rc "不正storeを0件にしない: $fixture" 2 lookup needle
  expect_rc "不正storeを上書きしない: $fixture" 2 defer
  same "$PENDING" "$TMP/broken" "不正storeの保全: $fixture"
done
cp "$TMP/saved" "$PENDING"
expect_rc '解決対象ID不在は拒否' 1 bash "$CLI" resolve --playbook "$BOOK" --id PENDING-PR-901-1 --decision rejected --result reason
same "$PENDING" "$TMP/saved" '不在IDで他の候補を削除しない'
expect_rc '実在しないACEへ解決しない' 1 bash "$CLI" resolve --playbook "$BOOK" --id PENDING-PR-900-1 --decision added --result ACE-9999-1
same "$PENDING" "$TMP/saved" '解決先不在は保留を保持'
for decision in added reused rejected; do
  if [ "$decision" = rejected ]; then result='novelty rejected'; else result=ACE-1-1; fi
  expect_rc "解決: $decision" 0 bash "$CLI" resolve --playbook "$BOOK" --id PENDING-PR-900-1 --decision "$decision" --result "$result"
  contains "$TMP/out" 'PENDING_COUNT=0' "$decision: 空storeを認識"
  expect_rc "$decision: lookupは有効な空候補storeを検索" 0 lookup needle
  contains "$TMP/out" 'pending=0' "$decision: 0候補"
  if [ "$decision" != rejected ]; then defer >"$TMP/out"; fi
done

cp "$BOOK" "$TMP/book-before-id-cases"
awk '/^## Changelog/ { exit } { print }' "$BOOK" >"$TMP/book-with-ids"
for target in ACE-1-2-3 ACE-i425-1-2; do
  printf '### %s: nested canonical ID\n\n| Category | testing | Origin | fixture PR 1 |\n| Helpful | 0 | Harmful | 0 |\n| Status | active |\n\nbody.\n\n---\n\n' "$target" >>"$TMP/book-with-ids"
done
awk '/^## Changelog/ { emit=1 } emit { print }' "$BOOK" >>"$TMP/book-with-ids"
cp "$TMP/book-with-ids" "$BOOK"
for target in ACE-1-2-3 ACE-i425-1-2; do
  for decision in added reused; do
    defer >"$TMP/out"
    expect_rc "多段ID: $target / $decision" 0 bash "$CLI" resolve --playbook "$BOOK" --id PENDING-PR-900-1 --decision "$decision" --result "$target"
    contains "$TMP/out" 'PENDING_COUNT=0' '多段IDへの解決で保留を除去'
  done
done
cp "$TMP/book-before-id-cases" "$BOOK"

echo '== 同じknowledge commitへ反映と保留削除を含める =='
REPO="$TMP/git-project"; mkdir "$REPO"
ff_git_fixture_init "$REPO" ace-pending-test ace-pending@example.invalid
git -C "$REPO" config core.hooksPath /dev/null
mkdir -p "$REPO/docs/08-knowledge"
cp "$BOOK" "$REPO/docs/08-knowledge/PLAYBOOK.md"
BOOK="$REPO/docs/08-knowledge/PLAYBOOK.md"; PENDING="${BOOK%/*}/PENDING_CANDIDATES.md"
defer >"$TMP/out"
git -C "$REPO" add .
git -C "$REPO" commit -qm seed
git -C "$REPO" branch -M develop
git init --bare -q "$TMP/remote.git"
git -C "$REPO" remote add origin "$TMP/remote.git"
git -C "$REPO" push -q -u origin develop
git -C "$REPO" remote set-head origin develop
seed_sha="$(git -C "$REPO" rev-parse HEAD)"
sed 's/| Helpful | 0 |/| Helpful | 1 |/' "$BOOK" >"$TMP/updated-book"
cp "$TMP/updated-book" "$BOOK"
bash "$CLI" resolve --playbook "$BOOK" --id PENDING-PR-900-1 --decision reused --result ACE-1-1 >"$TMP/out"
(
  CDPATH='' cd -P -- "$REPO" || exit 1
  bash "$PLUGIN/scripts/knowledge-commit.sh" add --source ace --id ACE-900 --summary pending-fixture -- docs/08-knowledge/PLAYBOOK.md docs/08-knowledge/PENDING_CANDIDATES.md || exit $?
  FF_DEV_TOOLKIT_SKIP_COMMIT_IDENTITY_GUARD=1 bash "$PLUGIN/scripts/knowledge-commit.sh" commit --type knowledge || exit $?
) >"$TMP/commit-out" 2>"$TMP/commit-err" || { cat "$TMP/commit-out" "$TMP/commit-err"; bad 'knowledge commit'; }
if [ "$(git -C "$REPO" rev-parse HEAD)" != "$seed_sha" ] && [ -z "$(git -C "$REPO" status --porcelain)" ]; then ok '正式ACE変更と保留除去を実commitした'; else bad 'knowledge commitが未実行か差分が残っている'; fi
git -C "$REPO" show --pretty=format: --name-only HEAD >"$TMP/paths"
contains "$TMP/paths" 'docs/08-knowledge/PLAYBOOK.md' 'Helpful更新が同じcommitに入る'
contains "$TMP/paths" 'docs/08-knowledge/PENDING_CANDIDATES.md' '保留削除が同じcommitに入る'
# 保留だけの保存: 既存claimのある導入先で両経路を実行する。
mkdir -p "$REPO/.version-claims/docs/08-knowledge"
printf '# Version claim fixture\n\nTracks document/version/change using the bundled helper.\n' >"$REPO/.version-claims/README.md"
claim="$REPO/.version-claims/docs/08-knowledge/PLAYBOOK.md.claim"
(
  CDPATH='' cd -P -- "$REPO" || exit 1
  bash "$PLUGIN/scripts/update-version-claim.sh" --base origin/develop --document docs/08-knowledge/PLAYBOOK.md || exit $?
) >"$TMP/claim-seed-out" 2>"$TMP/claim-seed-err" || { cat "$TMP/claim-seed-out" "$TMP/claim-seed-err"; bad '既存claimのseed'; }
[ -s "$claim" ] || { bad 'claim seedが空'; exit 1; }
cp "$claim" "$TMP/original-claim"
git -C "$REPO" add .version-claims
git -C "$REPO" commit -qm claim-seed
# 常時--claimを渡す退行は、更新不要の既存claimを再生成/検証してここを赤にする。
defer >"$TMP/out"
(
  CDPATH='' cd -P -- "$REPO" || exit 1
  # 実際の両経路のadd直前フェンスをBash 3.2 + nounsetで実行する。
  for route in "$PLUGIN/skills/ace-curate/SKILL.md" "$PLUGIN/skills/ace-curate/references/curate.md"; do
    awk '
      /^ACE_KNOWLEDGE_PATHS=/ { emit=1 }
      emit { print }
      emit && /knowledge-commit add / { done=1; exit }
      END { if (!done) exit 1 }
    ' "$route" >"$TMP/add-snippet.sh" || exit 1
    FF_DEV_TOOLKIT_ROOT="$PLUGIN" ACE_ID=ACE-pending-PR-900-1 ACE_SUMMARY='保留保存 PENDING-PR-900-1' commit_type=knowledge \
      /bin/bash -u "$TMP/add-snippet.sh" || exit $?
  done
  FF_DEV_TOOLKIT_SKIP_COMMIT_IDENTITY_GUARD=1 bash "$PLUGIN/scripts/knowledge-commit.sh" commit --type knowledge || exit $?
) >"$TMP/pending-only-out" 2>"$TMP/pending-only-err" || { cat "$TMP/pending-only-out" "$TMP/pending-only-err"; bad '保留だけのknowledge commit'; }
git -C "$REPO" show --pretty=format: --name-only HEAD >"$TMP/pending-only-paths"
printf 'docs/08-knowledge/PENDING_CANDIDATES.md\n' >"$TMP/expected-paths"
same "$TMP/expected-paths" "$TMP/pending-only-paths" '保留だけのcommitはPLAYBOOK/claimを変更しない'
same "$TMP/original-claim" "$claim" '既存claimのbytesを保全'
if grep -Fq 'CLAIM_UPDATED=' "$TMP/pending-only-out"; then bad '保留だけなのにclaimを再生成した'; else ok '保留だけの回はclaimを再生成しない'; fi


echo '== 実件数ゲートと同じ容量で保留を分離する =='
BOOK="$TMP/live-count/PLAYBOOK.md"; mkdir -p "${BOOK%/*}"
printf '# ACE Playbook\n\n## エントリ一覧\n\n' >"$BOOK"
printf '### ACE-901-1: seed\n\n| Category | testing | Origin | fixture PR 901 |\n| Date | 2026-10-23 |\n| Helpful | 0 | Harmful | 0 |\n| Status | active |\n\nbody.\n\n---\n\n' >>"$BOOK"
GATE="$PLUGIN/docs-template/scripts/ace/check-category-size.ts"
bash "$PLUGIN/scripts/ace-run-ts.sh" "$GATE" "$BOOK" >"$TMP/initial-report" 2>"$TMP/count-err"
LIMIT="$(awk '/^ブロック上限: / { print $2 }' "$TMP/initial-report")"
[[ "$LIMIT" =~ ^[1-9][0-9]*$ ]] || { echo '✗ real gate limit missing'; exit 1; }
i=2
while [ "$i" -le "$LIMIT" ]; do
  printf '### ACE-901-%s: count fixture\n\n| Category | testing | Origin | fixture PR 901 |\n| Date | 2026-10-23 |\n| Helpful | 0 | Harmful | 0 |\n| Status | active |\n\nbody.\n\n---\n\n' "$i" >>"$BOOK"
  i=$((i + 1))
done
bash "$PLUGIN/scripts/ace-run-ts.sh" "$GATE" "$BOOK" >"$REPORT" 2>"$TMP/count-err"
expect_rc '実reportで上限到達候補を保存' 0 defer
contains "$TMP/out" 'PENDING_COUNT=1' '実上限で1候補'
bash "$PLUGIN/scripts/ace-run-ts.sh" "$GATE" "$BOOK" >"$TMP/count-after" 2>"$TMP/count-err"
same "$REPORT" "$TMP/count-after" '保留ファイルはlive件数へ入らない'

echo '== スキルの保存/再評価/同一commit導線 =='
contains "$PLUGIN/skills/ace-curate/SKILL.md" '新規PRの候補が0件でも保留を同じ新規性ゲートへ掛け直す' '候補0でもPhase 2が再評価する'
contains "$PLUGIN/skills/ace-curate/SKILL.md" '通常の追記を止めたまま[保留候補の保存]' '容量停止後に保存経路へ進む'
for route in "$PLUGIN/skills/ace-curate/SKILL.md" "$PLUGIN/skills/ace-curate/references/curate.md"; do
  contains "$route" 'ACE_KNOWLEDGE_PATHS+=(docs/08-knowledge/PENDING_CANDIDATES.md)' '両commit経路が保留を同梱する'
done
contains "$PLUGIN/skills/ace-curate/references/pending.md" '正式ACEの変更・Helpful更新と候補の除去を同じknowledge commitへ含める' '再評価結果と保留除去のcommit境界'

printf 'ace-pending: passed=%s failed=%s\n' "$PASS" "$FAIL"
[ "$PASS" -gt 0 ] && [ "$FAIL" -eq 0 ]
