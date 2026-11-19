#!/usr/bin/env bash
# Sourced by verify.sh; isolated git fixtures exercise precommit-skip-line.sh (skip_line_precommit_scan).
run_skip_line_cases() {
  local r circle profile out err rc rc2 out2 rel_base
  # shellcheck source=../lib/precommit-skip-line.sh
  . "$TESTS_DIR/lib/precommit-skip-line.sh"
  # shellcheck source=../lib/skip-line-contract.sh
  . "$TESTS_DIR/lib/skip-line-contract.sh"

  circle="$(printf '\342\227\213')"
  rel_base='plugins/ff-dev-toolkit/tests'

  sl_write() {
    mkdir -p "$(dirname "$1")"
    sed "s/@C@/${circle}/g" >"$1"
  }

  sl_expect() {
    local label="$1" repo="$2" want_rc="$3" want_out="$4" want_err="$5"
    rc=0
    out="$(skip_line_precommit_scan "$repo" 2>"$TMP/sl-err")" || rc=$?
    err="$(cat "$TMP/sl-err")"
    if [ "$rc" -eq "$want_rc" ] \
      && { [ -z "$want_out" ] || [[ "$out" == *"$want_out"* ]]; } \
      && { [ -z "$want_err" ] || [[ "$err" == *"$want_err"* ]]; }; then
      ok "SL ${label}"
    else
      bad "SL ${label}"
      printf '    rc=%s out=[%s] err=[%s]\n' "$rc" "$out" "$err" >&2
    fi
  }

  r="$(new_repo skip-line)"
  mkdir -p "$r/$rel_base/lib" "$r/plugins/ff-dev-toolkit/scripts/lib"
  cp "$TESTS_DIR/lib/skip-line-contract.sh" "$TESTS_DIR/lib/relay-skip-lines.sh" \
    "$TESTS_DIR/lib/release-skip-profile.sh" \
    "$r/$rel_base/lib/"
  cat >"$r/$rel_base/lib/release-skip-profile.tsv" <<'EOF'
# Literal reason discriminator, then Windows / Darwin / Linux (tab-separated).
perl が無いため P1〜P4 は未検査	stop	stop	stop
EOF
  cp "$TESTS_DIR/../scripts/lib/stop-block.sh" "$r/plugins/ff-dev-toolkit/scripts/lib/"
  git -C "$r" add .
  git -C "$r" commit -qm "baseline"

  # SL1: empty staged index -> none
  sl_expect '空の staged index は skip-line-contract: none' "$r" 0 'skip-line-contract: none' ''

  # SL2 (AC3): unrelated *.sh outside tests/ -> none
  sl_write "$r/plugins/ff-dev-toolkit/scripts/helper.sh" <<'EOF'
#!/usr/bin/env bash
echo "@C@ skip: scripts/ helper は走査対象外"
EOF
  git -C "$r" add plugins/ff-dev-toolkit/scripts/helper.sh
  sl_expect 'tests 外の *.sh は対象なし（none）' "$r" 0 'skip-line-contract: none' ''
  git -C "$r" reset -q HEAD -- plugins/ff-dev-toolkit/scripts/helper.sh
  rm -f "$r/plugins/ff-dev-toolkit/scripts/helper.sh"

  # SL3 (AC3): test *.sh with existing skipped() helper + unrelated edits shifting line numbers -> none
  sl_write "$r/$rel_base/existing/verify.sh" <<'EOF'
#!/usr/bin/env bash
skipped() { echo "  @C@ skip: $1"; }
skipped "perl が無いため P1〜P4 は未検査"
echo "  ✓ existing assertion"
EOF
  chmod +x "$r/$rel_base/existing/verify.sh"
  git -C "$r" add "$rel_base/existing/verify.sh"
  git -C "$r" commit -qm "add existing skip test"

  sl_write "$r/$rel_base/existing/verify.sh" <<'EOF'
#!/usr/bin/env bash
# line shift 1
# line shift 2
# line shift 3
echo "  ✓ new assertion without skip"
skipped() { echo "  @C@ skip: $1"; }
skipped "perl が無いため P1〜P4 は未検査"
echo "  ✓ existing assertion"
EOF
  git -C "$r" add "$rel_base/existing/verify.sh"
  sl_expect '既存 skip 箇所の行番号だけずらす無関係編集は none（AC3）' "$r" 0 'skip-line-contract: none' ''
  git -C "$r" reset -q HEAD -- "$rel_base/existing/verify.sh"
  git -C "$r" checkout -q -- "$rel_base/existing/verify.sh"

  # SL4 (AC1): new partial skip literal triggers run + lint identifies file:line
  sl_write "$r/$rel_base/new-partial/verify.sh" <<'EOF'
#!/usr/bin/env bash
echo "  @C@ skip: unregistered reason for ac1"
EOF
  git -C "$r" add "$rel_base/new-partial/verify.sh"
  sl_expect '新規の未登録部分 skip 行で target 名指し + run 1（AC1）' \
    "$r" 0 "skip-line target: $rel_base/new-partial/verify.sh" ''
  rc2=0
  profile="$r/$rel_base/lib/release-skip-profile.sh"
  if ff_skip_line_scan_tree "$r" --reasons >"$TMP/sl-reasons"; then
    out2="$(bash "$profile" --lint "$TMP/sl-reasons" 2>&1)" || rc2=$?
  else
    rc2=2
    out2="scan failed"
  fi
  if [ "$rc2" -eq 1 ] && [[ "$out2" == *"new-partial/verify.sh:2: 未分類の部分 skip: unregistered reason for ac1"* ]]; then
    ok "SL AC1 連動 lint が未登録理由を ファイル:行 で名指し停止する"
  else
    bad "SL AC1 連動 lint が期待どおり停止しない"
    printf '    rc=%s out=[%s]\n' "$rc2" "$out2" >&2
  fi

  # SL5 (AC2): registering the reason in release-skip-profile.tsv makes lint pass
  printf 'unregistered reason for ac1\tstop\tstop\tstop\n' >>"$r/$rel_base/lib/release-skip-profile.tsv"
  git -C "$r" add "$rel_base/lib/release-skip-profile.tsv"
  sl_expect '許容表へ登録して stage し直すと run 2（許容表 + 新規 skip）' "$r" 0 'skip-line-contract: run 2' ''
  rc2=0
  out2=""
  if ff_skip_line_scan_tree "$r" --reasons >"$TMP/sl-reasons"; then
    out2="$(bash "$profile" --lint "$TMP/sl-reasons" 2>&1)" || rc2=$?
  else
    rc2=2
  fi
  if [ "$rc2" -eq 0 ] && [ -z "$out2" ]; then
    ok "SL AC2 許容表へ登録後は static lint が緑になる"
  else
    bad "SL AC2 登録後の static lint が失敗した"
    printf '    rc=%s out=[%s]\n' "$rc2" "$out2" >&2
  fi
  git -C "$r" reset -q HEAD
  git -C "$r" checkout -q -- "$rel_base/lib/release-skip-profile.tsv"
  rm -rf "$r/$rel_base/new-partial"

  # SL6: adding a helper call to already-defined skipped() in modified suite
  sl_write "$r/$rel_base/existing/verify.sh" <<'EOF'
#!/usr/bin/env bash
skipped() { echo "  @C@ skip: $1"; }
skipped "perl が無いため P1〜P4 は未検査"
skipped "added helper call reason"
echo "  ✓ existing assertion"
EOF
  git -C "$r" add "$rel_base/existing/verify.sh"
  sl_expect '既存ヘルパー経由の新規 skip 呼び出し追加を run 1 で検出する' \
    "$r" 0 "skip-line target: $rel_base/existing/verify.sh" ''
  git -C "$r" reset -q HEAD -- "$rel_base/existing/verify.sh"
  git -C "$r" checkout -q -- "$rel_base/existing/verify.sh"

  # SL7: asdd-runtime/*.mjs skipWith addition
  sl_write "$r/$rel_base/asdd-runtime/runtime.test.mjs" <<'EOF'
skipWith(t, 'novel mjs skip reason');
EOF
  git -C "$r" add "$rel_base/asdd-runtime/runtime.test.mjs"
  sl_expect 'runtime.test.mjs の skipWith 追加を run 1 で検出する' \
    "$r" 0 "skip-line target: $rel_base/asdd-runtime/runtime.test.mjs" ''
  git -C "$r" reset -q HEAD -- "$rel_base/asdd-runtime/runtime.test.mjs"
  rm -rf "$r/$rel_base/asdd-runtime"

  # SL8: noncanonical violation + pre-existing violation stays flagged even on comment edit
  sl_write "$r/$rel_base/bad-noncanon/verify.sh" <<'EOF'
#!/usr/bin/env bash
ok "  @C@ yq 不在のため未検証"
EOF
  git -C "$r" add "$rel_base/bad-noncanon/verify.sh"
  sl_expect '非正準 skip（ok 内の丸印）の追加を run 1 で検出する' \
    "$r" 0 "skip-line target: $rel_base/bad-noncanon/verify.sh" ''
  git -C "$r" commit -qm "commit noncanonical baseline"
  printf '# harmless comment\n' >>"$r/$rel_base/bad-noncanon/verify.sh"
  git -C "$r" add "$rel_base/bad-noncanon/verify.sh"
  sl_expect '既存の非正準違反が残るファイルの変更も run 1 を保つ' \
    "$r" 0 "skip-line target: $rel_base/bad-noncanon/verify.sh" ''
  git -C "$r" reset -q HEAD -- "$rel_base/bad-noncanon/verify.sh"
  git -C "$r" checkout -q -- "$rel_base/bad-noncanon/verify.sh"

  # SL9: deletion-only commits (without skip -> none / with skip -> run 1)
  sl_write "$r/$rel_base/with-skip/verify.sh" <<'EOF'
#!/usr/bin/env bash
echo "  @C@ skip: deleted later"
EOF
  sl_write "$r/$rel_base/no-skip/verify.sh" <<'EOF'
#!/usr/bin/env bash
echo "  ✓ clean"
EOF
  git -C "$r" add "$rel_base/with-skip/verify.sh" "$rel_base/no-skip/verify.sh"
  git -C "$r" commit -qm "add deletion fixtures"

  git -C "$r" rm -q "$rel_base/no-skip/verify.sh"
  sl_expect 'skip の無い test の削除だけ（D）は none' "$r" 0 'skip-line-contract: none' ''
  git -C "$r" reset -q HEAD -- "$rel_base/no-skip/verify.sh"
  git -C "$r" checkout -q -- "$rel_base/no-skip/verify.sh"

  git -C "$r" rm -q "$rel_base/with-skip/verify.sh"
  sl_expect 'skip を含む test の削除だけ（D）は target 名指し + run 1' \
    "$r" 0 "skip-line target: $rel_base/with-skip/verify.sh" ''
  git -C "$r" reset -q HEAD -- "$rel_base/with-skip/verify.sh"
  git -C "$r" checkout -q -- "$rel_base/with-skip/verify.sh"

  # SL10: direct edit to release-skip-profile.tsv + diff.relative=true from subdir
  printf '\n# note\n' >>"$r/$rel_base/lib/release-skip-profile.tsv"
  git -C "$r" add "$rel_base/lib/release-skip-profile.tsv"
  git -C "$r" config --local diff.relative true
  sl_expect '許容表変更 + diff.relative=true 下の subdir 指定でも run 1' \
    "$r/plugins" 0 "skip-line target: $rel_base/lib/release-skip-profile.tsv" ''
  git -C "$r" config --local --unset diff.relative
  git -C "$r" reset -q HEAD -- "$rel_base/lib/release-skip-profile.tsv"
  git -C "$r" checkout -q -- "$rel_base/lib/release-skip-profile.tsv"

  # SL11: consumer repo without plugins/ff-dev-toolkit/tests -> none
  local consumer
  consumer="$(new_repo skip-line-consumer)"
  printf 'hello\n' >"$consumer/app.sh"
  git -C "$consumer" add app.sh
  sl_expect 'tests ディレクトリを持たない消費側リポジトリでは none' "$consumer" 0 'skip-line-contract: none' ''

  # SL12: fail-closed rc=2 paths (non-git, missing lib, git error, merge conflict U)
  mkdir -p "$TMP/not-a-git-repo"
  sl_expect 'git リポジトリでない場所は rc=2（skip-line 未検査）' \
    "$TMP/not-a-git-repo" 2 '' 'skip-line 未検査: リポジトリルートを取得できません'

  local broken
  broken="$(new_repo skip-line-broken)"
  mkdir -p "$broken/$rel_base"
  sl_expect 'skip-line-contract.sh 不在は rc=2（skip-line 未検査）' \
    "$broken" 2 '' 'skip-line 未検査:'

  mkdir -p "$TMP/sl-git-fail"
  cat >"$TMP/sl-git-fail/git" <<'EOF'
#!/usr/bin/env bash
if [ "$1" = "-C" ] && [ "$3" = "diff" ]; then
  echo "fatal: stub diff error" >&2
  exit 128
fi
exec "$REAL_GIT" "$@"
EOF
  chmod +x "$TMP/sl-git-fail/git"
  rc=0
  out="$(PATH="$TMP/sl-git-fail:$PATH" REAL_GIT="$REAL_GIT" skip_line_precommit_scan "$r" 2>"$TMP/sl-err")" || rc=$?
  err="$(cat "$TMP/sl-err")"
  if [ "$rc" -eq 2 ] && [[ "$err" == *'skip-line 未検査: staged の一覧を取得できません'* ]]; then
    ok "SL git diff 失敗時は rc=2 で「skip-line 未検査」と報告する"
  else
    bad "SL git diff 失敗時の処理が不正"
    printf '    rc=%s out=[%s] err=[%s]\n' "$rc" "$out" "$err" >&2
  fi

  local conflict
  conflict="$(new_repo skip-line-conflict)"
  mkdir -p "$conflict/$rel_base/lib" "$conflict/$rel_base/c"
  cp "$TESTS_DIR/lib/skip-line-contract.sh" "$conflict/$rel_base/lib/"
  printf 'base\n' >"$conflict/$rel_base/c/verify.sh"
  git -C "$conflict" add .
  git -C "$conflict" commit -qm base
  git -C "$conflict" checkout -qb side
  printf 'side\n' >"$conflict/$rel_base/c/verify.sh"
  git -C "$conflict" commit -qam side
  git -C "$conflict" checkout -q -
  printf 'main\n' >"$conflict/$rel_base/c/verify.sh"
  git -C "$conflict" commit -qam main
  git -C "$conflict" merge side >/dev/null 2>&1 || true
  sl_expect '未解決の衝突（U）は rc=2（skip-line 未検査）' \
    "$conflict" 2 '' 'skip-line 未検査: 未解決の衝突があります:'

  # SL13 (Suggest 1): GIT_LITERAL_PATHSPECS=1 and GIT_GLOB_PATHSPECS=1
  sl_write "$r/$rel_base/existing/verify.sh" <<'EOF'
#!/usr/bin/env bash
# line shift for literal pathspec check
skipped() { echo "  @C@ skip: $1"; }
skipped "perl が無いため P1〜P4 は未検査"
EOF
  git -C "$r" add "$rel_base/existing/verify.sh"
  rc=0
  out="$(GIT_LITERAL_PATHSPECS=1 skip_line_precommit_scan "$r" 2>"$TMP/sl-err")" || rc=$?
  err="$(cat "$TMP/sl-err")"
  if [ "$rc" -eq 0 ] && [ "$out" = "skip-line-contract: none" ] && [ -z "$err" ]; then
    ok "SL GIT_LITERAL_PATHSPECS=1 下の無関係行移動は rc=0（none）"
  else
    bad "SL GIT_LITERAL_PATHSPECS=1 下の無関係行移動が不正"
    printf '    rc=%s out=[%s] err=[%s]\n' "$rc" "$out" "$err" >&2
  fi
  sl_write "$r/$rel_base/existing/verify.sh" <<'EOF'
#!/usr/bin/env bash
skipped() { echo "  @C@ skip: $1"; }
skipped "perl が無いため P1〜P4 は未検査"
skipped "added under literal and glob pathspecs"
EOF
  git -C "$r" add "$rel_base/existing/verify.sh"
  rc=0
  out="$(GIT_LITERAL_PATHSPECS=1 skip_line_precommit_scan "$r" 2>"$TMP/sl-err")" || rc=$?
  err="$(cat "$TMP/sl-err")"
  if [ "$rc" -eq 0 ] && [[ "$out" == *"skip-line-contract: run 1"* ]] && [ -z "$err" ]; then
    ok "SL GIT_LITERAL_PATHSPECS=1 下の skip 追加を run 1 で検出する"
  else
    bad "SL GIT_LITERAL_PATHSPECS=1 下の skip 追加が不正"
    printf '    rc=%s out=[%s] err=[%s]\n' "$rc" "$out" "$err" >&2
  fi
  rc=0
  out="$(GIT_GLOB_PATHSPECS=1 skip_line_precommit_scan "$r" 2>"$TMP/sl-err")" || rc=$?
  err="$(cat "$TMP/sl-err")"
  if [ "$rc" -eq 0 ] && [[ "$out" == *"skip-line-contract: run 1"* ]] && [ -z "$err" ]; then
    ok "SL GIT_GLOB_PATHSPECS=1 下の skip 追加を run 1 で検出する"
  else
    bad "SL GIT_GLOB_PATHSPECS=1 下の skip 追加が不正"
    printf '    rc=%s out=[%s] err=[%s]\n' "$rc" "$out" "$err" >&2
  fi
  git -C "$r" reset -q HEAD -- "$rel_base/existing/verify.sh"
  git -C "$r" checkout -q -- "$rel_base/existing/verify.sh"

  # SL14 (Suggest 2): additional direct paths (self & weekly workflow)
  sl_write "$r/$rel_base/lib/precommit-skip-line.sh" <<'EOF'
# direct self trigger
EOF
  git -C "$r" add "$rel_base/lib/precommit-skip-line.sh"
  sl_expect '判定器自身の変更は skip-line target で run 1' \
    "$r" 0 "skip-line target: $rel_base/lib/precommit-skip-line.sh" ''
  git -C "$r" reset -q HEAD -- "$rel_base/lib/precommit-skip-line.sh"
  rm -f "$r/$rel_base/lib/precommit-skip-line.sh"

  sl_write "$r/.github/workflows/weekly-public-run-all.yml" <<'EOF'
name: weekly
EOF
  git -C "$r" add .github/workflows/weekly-public-run-all.yml
  sl_expect '公開週次ワークフロー変更は skip-line target で run 1' \
    "$r" 0 "skip-line target: .github/workflows/weekly-public-run-all.yml" ''
  git -C "$r" reset -q HEAD -- .github/workflows/weekly-public-run-all.yml
  rm -rf "$r/.github"

  # SL15 (Suggest 2): column-0 whole-suite skip
  sl_write "$r/$rel_base/whole-suite/verify.sh" <<'EOF'
#!/usr/bin/env bash
echo "@C@ skip: whole suite skipped"
exit 0
EOF
  git -C "$r" add "$rel_base/whole-suite/verify.sh"
  sl_expect '列 0 の suite 全体 skip 追加を run 1 で検出する' \
    "$r" 0 "skip-line target: $rel_base/whole-suite/verify.sh" ''
  git -C "$r" reset -q HEAD -- "$rel_base/whole-suite/verify.sh"
  rm -rf "$r/$rel_base/whole-suite"

  # SL16 (Suggest 2): rename (--no-renames splits into D + A)
  git -C "$r" mv "$rel_base/no-skip/verify.sh" "$rel_base/no-skip/renamed.sh"
  sl_expect 'skip 無し test の git mv は none' "$r" 0 'skip-line-contract: none' ''
  git -C "$r" reset -q HEAD
  git -C "$r" checkout -q -- "$rel_base/no-skip/verify.sh"
  rm -f "$r/$rel_base/no-skip/renamed.sh"

  git -C "$r" mv "$rel_base/with-skip/verify.sh" "$rel_base/with-skip/renamed.sh"
  sl_expect 'skip 有り test の git mv は D+A の run 2' "$r" 0 'skip-line-contract: run 2' ''
  git -C "$r" reset -q HEAD
  git -C "$r" checkout -q -- "$rel_base/with-skip/verify.sh"
  rm -f "$r/$rel_base/with-skip/renamed.sh"

  # SL17 (Suggest 2): symlink 120000 and typechange T removing skip
  ln -s "verify.sh" "$r/$rel_base/with-skip/link.sh"
  git -C "$r" add "$rel_base/with-skip/link.sh"
  sl_expect 'symlink 120000 の新規追加は none' "$r" 0 'skip-line-contract: none' ''
  git -C "$r" reset -q HEAD -- "$rel_base/with-skip/link.sh"
  rm -f "$r/$rel_base/with-skip/link.sh"

  rm -f "$r/$rel_base/with-skip/verify.sh"
  ln -s "../no-skip/verify.sh" "$r/$rel_base/with-skip/verify.sh"
  git -C "$r" add "$rel_base/with-skip/verify.sh"
  sl_expect 'skip 有り通常ファイルから symlink への種別変更 T は run 1' \
    "$r" 0 "skip-line target: $rel_base/with-skip/verify.sh" ''
  git -C "$r" reset -q HEAD -- "$rel_base/with-skip/verify.sh"
  git -C "$r" checkout -q -- "$rel_base/with-skip/verify.sh"

  # SL18 (Suggest 2): other plugin .py emitter and path with colon/spaces
  sl_write "$r/plugins/ff-media-toolkit/tests/with space/a:b.py" <<'EOF'
print("  @C@ skip: python emitter skip")
EOF
  git -C "$r" add "plugins/ff-media-toolkit/tests/with space/a:b.py"
  sl_expect '他プラグイン .py の空白とコロンを含むパスでも skip を検出する' \
    "$r" 0 "skip-line target: plugins/ff-media-toolkit/tests/with space/a:b.py" ''
  git -C "$r" commit -qm "add py with colon and space"
  sl_write "$r/plugins/ff-media-toolkit/tests/with space/a:b.py" <<'EOF'
# shifted line
print("  @C@ skip: python emitter skip")
EOF
  git -C "$r" add "plugins/ff-media-toolkit/tests/with space/a:b.py"
  sl_expect '空白とコロンを含むパスの無関係行移動も none（行ずれ耐性）' \
    "$r" 0 'skip-line-contract: none' ''
  git -C "$r" reset -q HEAD -- "plugins/ff-media-toolkit/tests/with space/a:b.py"
  git -C "$r" checkout -q -- "plugins/ff-media-toolkit/tests/with space/a:b.py"

  # SL19 (Suggest 2): unborn HEAD
  local unborn
  unborn="$(new_repo skip-line-unborn)"
  mkdir -p "$unborn/$rel_base/lib"
  cp "$TESTS_DIR/lib/skip-line-contract.sh" "$unborn/$rel_base/lib/"
  sl_write "$unborn/$rel_base/clean/verify.sh" <<'EOF'
#!/usr/bin/env bash
echo "  ✓ unborn clean"
EOF
  git -C "$unborn" add "$rel_base/clean/verify.sh"
  sl_expect 'unborn HEAD で skip 無しは none' "$unborn" 0 'skip-line-contract: none' ''
  sl_write "$unborn/$rel_base/has-skip/verify.sh" <<'EOF'
#!/usr/bin/env bash
echo "  @C@ skip: unborn skip"
EOF
  git -C "$unborn" add "$rel_base/has-skip/verify.sh"
  sl_expect 'unborn HEAD で skip 追加は run 1' "$unborn" 0 "skip-line target: $rel_base/has-skip/verify.sh" ''

  # SL20 (Suggest 2): ff_skip_line_scan_files scan_rc > 1 fail-closed
  local scan_fail
  scan_fail="$(new_repo skip-line-scanfail)"
  mkdir -p "$scan_fail/$rel_base/lib"
  cat >"$scan_fail/$rel_base/lib/skip-line-contract.sh" <<'EOF'
ff_skip_line_scan_files() { echo "simulated scan boom" >&2; return 2; }
EOF
  mkdir -p "$scan_fail/$rel_base/a"
  printf '#!/usr/bin/env bash\necho ok\n' >"$scan_fail/$rel_base/a/verify.sh"
  git -C "$scan_fail" add "$rel_base/a/verify.sh"
  sl_expect '走査器が rc=2 で失敗したら skip-line 未検査 で停止する' \
    "$scan_fail" 2 '' 'skip-line 未検査: 書式走査に失敗しました'

  SKIP_LINE_CASES_REACHED=1
}
