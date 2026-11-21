#!/usr/bin/env bash
# Issue `#2869`: reject --output-dir (and config output_dir) nested under a
# built-in default output directory (.review-results / .explore-results /
# .implement-results) before CLI dispatch and --dry-run, while keeping the
# default root itself, sibling names, and external paths working.
# pipefail-inherited: verify.sh が set -euo pipefail の下で source する。

run_nested_default_cases() {
  echo ""
  echo "== 既定出力ディレクトリ配下のネスト拒否 =="

  local work="$TMP/nested-default" nrepo
  local yqbin="$TMP/nested-default/yqbin"
  local before rc report_hash after_hash archive_dir log
  local recovery_anchor plain_anchor canonical_child
  local review_skill="$PLUGIN_ROOT/skills/multi-review/SKILL.md"
  local orch_doc="$PLUGIN_ROOT/docs-template/05-operations/deployment/multi-cli-review-orchestration.md"
  local multi_review="$PLUGIN_ROOT/scripts/multi-review.sh"

  nrepo="$(CDPATH='' cd -P -- "$REPO" && pwd -P)"
  rm -rf "$work" \
    "$nrepo/.review-results" \
    "$nrepo/.explore-results" \
    "$nrepo/.implement-results" \
    "$nrepo/.review-results-round2" \
    "$nrepo/.REVIEW-RESULTS" \
    "$nrepo/.claude"
  mkdir -p "$yqbin"

  nd_run() { # <cwd> <log> [env/cmd...]
    local cwd="$1" run_log="$2" run_rc=0
    shift 2
    set +e
    (
      cd "$cwd"
      run_isolated PATH="$STUB:$PATH" FF_REVIEW_ROUND_LIMIT=0 "$@"
    ) >"$run_log" 2>&1
    run_rc=$?
    set -e
    return "$run_rc"
  }

  nd_assert_rejected() { # <label> <rc> <before_count> <log> <default_name> [forbidden_path]
    local label="$1" got_rc="$2" prior_count="$3" err_log="$4" def_name="$5" forbidden="${6:-}"
    if [[ "$got_rc" -eq 2 ]] \
      && [[ "$(count_invocations)" == "$prior_count" ]] \
      && grep -qF 'cannot be a subdirectory of the default output directory' "$err_log" \
      && grep -qF 'Nothing was executed (no CLI was started' "$err_log" \
      && grep -qF -- "outside ${def_name}/" "$err_log" \
      && [[ -z "$forbidden" || ! -e "$forbidden" ]]; then
      ok "$label"
    else
      bad "$label (rc=${got_rc}, before=${prior_count}, after=$(count_invocations), forbidden=${forbidden})"
      tail -15 "$err_log" | sed 's/^/    | /' >&2 || true
    fi
  }

  # 1. Cold repository (.review-results does not exist yet)
  before="$(count_invocations)"
  log="$work/case01-cold.log"
  rc=0
  nd_run "$nrepo" "$log" bash "$MULTI_AGENT" --task review --base develop \
    --cli codex-cli --perspective code-review --output-dir .review-results/round2 || rc=$?
  nd_assert_rejected "冷状態での .review-results/round2 指定は rc=2・CLI未起動・ディレクトリ未作成で拒否" \
    "$rc" "$before" "$log" ".review-results" "$nrepo/.review-results"

  # 1b. Cold repository: even canonical .recovery-* name must be rejected when default root is uninitialized
  before="$(count_invocations)"
  log="$work/case01b-cold-recovery.log"
  rc=0
  nd_run "$nrepo" "$log" bash "$MULTI_AGENT" --task review --base develop \
    --cli codex-cli --perspective code-review \
    --output-dir .review-results/.recovery-20261119-212641-97787-codex-cli-code-review-retry || rc=$?
  nd_assert_rejected "冷状態での .review-results/.recovery-* 指定は rc=2・CLI未起動・ディレクトリ未作成で拒否" \
    "$rc" "$before" "$log" ".review-results" "$nrepo/.review-results"

  # Seed existing .review-results for cases 2-7, 10, 13
  log="$work/seed.log"
  if nd_run "$nrepo" "$log" bash "$MULTI_AGENT" --task review --mode distributed --sequential \
    --cli codex-cli --perspective code-review --base develop --timeout 60; then
    report_hash="$(git hash-object "$nrepo/.review-results/integrated-report.md")"
  else
    bad "seed review in .review-results failed"
    tail -15 "$log" | sed 's/^/    | /' >&2 || true
    return
  fi

  # 2. Existing .review-results via multi-review.sh
  before="$(count_invocations)"
  log="$work/case02-multi-review.log"
  rc=0
  nd_run "$nrepo" "$log" bash "$multi_review" --route none --base develop \
    --cli codex-cli --perspective code-review --output-dir .review-results/round2 || rc=$?
  after_hash="$(git hash-object "$nrepo/.review-results/integrated-report.md")"
  if [[ "$after_hash" == "$report_hash" ]]; then
    nd_assert_rejected "既存結果がある状態で multi-review.sh の .review-results/round2 は rc=2 で拒否し既存レポートを保全" \
      "$rc" "$before" "$log" ".review-results" "$nrepo/.review-results/round2"
  else
    bad "既存レポートが破壊された: before=$report_hash after=$after_hash"
  fi

  # 3. --dry-run must also exit 2
  before="$(count_invocations)"
  log="$work/case03-dry-run.log"
  rc=0
  nd_run "$nrepo" "$log" bash "$multi_review" --dry-run --route none --base develop \
    --cli codex-cli --perspective code-review --output-dir .review-results/round2 || rc=$?
  nd_assert_rejected "--dry-run でも .review-results/round2 は rc=2 で拒否" \
    "$rc" "$before" "$log" ".review-results" "$nrepo/.review-results/round2"

  # 4. Absolute nested path a/b
  before="$(count_invocations)"
  log="$work/case04-abs-nested.log"
  rc=0
  nd_run "$nrepo" "$log" bash "$MULTI_AGENT" --task review --base develop \
    --cli codex-cli --perspective code-review --output-dir "$nrepo/.review-results/a/b" || rc=$?
  nd_assert_rejected "絶対パス多段ネスト (.review-results/a/b) は rc=2 で拒否" \
    "$rc" "$before" "$log" ".review-results" "$nrepo/.review-results/a"

  # 5. Hidden subpath
  before="$(count_invocations)"
  log="$work/case05-hidden.log"
  rc=0
  nd_run "$nrepo" "$log" bash "$MULTI_AGENT" --task review --base develop \
    --cli codex-cli --perspective code-review --output-dir .review-results/.hidden || rc=$?
  nd_assert_rejected "ドット始まりサブパス (.review-results/.hidden) は rc=2 で拒否" \
    "$rc" "$before" "$log" ".review-results" "$nrepo/.review-results/.hidden"

  # 6. Trailing slash
  before="$(count_invocations)"
  log="$work/case06-trailing-slash.log"
  rc=0
  nd_run "$nrepo" "$log" bash "$MULTI_AGENT" --task review --base develop \
    --cli codex-cli --perspective code-review --output-dir .review-results/round2/ || rc=$?
  nd_assert_rejected "末尾スラッシュ付き (.review-results/round2/) は rc=2 で拒否" \
    "$rc" "$before" "$log" ".review-results" "$nrepo/.review-results/round2"

  # 7. --archive-only with nested subpath
  before="$(count_invocations)"
  log="$work/case07-archive-only.log"
  rc=0
  nd_run "$nrepo" "$log" bash "$MULTI_AGENT" --task review --base develop \
    --archive-only --output-dir .review-results/round2 || rc=$?
  if [[ -f "$nrepo/.review-results/integrated-report.md" ]]; then
    nd_assert_rejected "--archive-only でも .review-results/round2 は rc=2 で拒否し既存レポートを退避しない" \
      "$rc" "$before" "$log" ".review-results" "$nrepo/.review-results/round2"
  else
    bad "--archive-only 拒否前に既存レポートが失われた"
  fi

  # 8. explore task under .explore-results/sub
  before="$(count_invocations)"
  log="$work/case08-explore.log"
  rc=0
  nd_run "$nrepo" "$log" bash "$MULTI_AGENT" --task explore --description probe \
    --cli codex-cli --output-dir .explore-results/sub || rc=$?
  nd_assert_rejected "explore タスクの .explore-results/sub は rc=2 で拒否" \
    "$rc" "$before" "$log" ".explore-results" "$nrepo/.explore-results"

  # 9. implement task under .implement-results/sub
  before="$(count_invocations)"
  log="$work/case09-implement.log"
  rc=0
  nd_run "$nrepo" "$log" bash "$MULTI_AGENT" --task implement --description probe \
    --cli codex-cli --output-dir .implement-results/sub || rc=$?
  nd_assert_rejected "implement タスクの .implement-results/sub は rc=2 で拒否" \
    "$rc" "$before" "$log" ".implement-results" "$nrepo/.implement-results"

  # 10. cwd inside .review-results with relative --output-dir round2
  before="$(count_invocations)"
  log="$work/case10-cwd-inside.log"
  rc=0
  nd_run "$nrepo/.review-results" "$log" bash "$MULTI_AGENT" --task review --base develop \
    --cli codex-cli --perspective code-review --output-dir round2 || rc=$?
  nd_assert_rejected ".review-results を cwd とした相対 --output-dir round2 は rc=2 で拒否" \
    "$rc" "$before" "$log" ".review-results" "$nrepo/.review-results/round2"

  # 11. Project config output_dir: .review-results/from-config
  mkdir -p "$nrepo/.claude"
  printf 'version: "2.0"\n' > "$nrepo/.claude/agent-config.yaml"
  cat > "$yqbin/yq" <<'YQ'
#!/usr/bin/env bash
case "$*" in *output_dir*) echo .review-results/from-config ;; *version*) echo 2.0 ;; *) : ;; esac
YQ
  chmod +x "$yqbin/yq"
  before="$(count_invocations)"
  log="$work/case11-config.log"
  rc=0
  nd_run "$nrepo" "$log" PATH="$yqbin:$STUB:$PATH" bash "$MULTI_AGENT" --task review --base develop \
    --cli codex-cli --perspective code-review || rc=$?
  rm -rf "$nrepo/.claude" "$yqbin/yq"
  nd_assert_rejected "project config の output_dir: .review-results/from-config は rc=2 で拒否" \
    "$rc" "$before" "$log" ".review-results" "$nrepo/.review-results/from-config"

  # 12. Direct call to ff_review_output_prepare
  log="$work/case12-prepare.log"
  rc=0
  ( ff_review_output_prepare "$nrepo" "$nrepo/.review-results/direct" true review ) >"$log" 2>&1 || rc=$?
  if [[ "$rc" -ne 0 && ! -e "$nrepo/.review-results/direct" ]] \
    && grep -qF 'cannot be a subdirectory of the default output directory' "$log"; then
    ok "ff_review_output_prepare の直接呼び出しもネストパスを非0で拒否し作成しない"
  else
    bad "ff_review_output_prepare がネストパスを通したまたは作成した (rc=${rc})"
    tail -10 "$log" | sed 's/^/    | /' >&2 || true
  fi

  # 13. Case-insensitive filesystem alias probe
  mkdir -p "$work/case-probe/Lower"
  if [[ -d "$work/case-probe/lower" && "$work/case-probe/Lower" -ef "$work/case-probe/lower" ]]; then
    mv "$nrepo/.review-results" "$work/case13-saved-results"
    before="$(count_invocations)"
    log="$work/case13-ci-cold.log"
    rc=0
    nd_run "$nrepo" "$log" bash "$MULTI_AGENT" --task review --base develop \
      --cli codex-cli --perspective code-review --output-dir .REVIEW-RESULTS/round2 || rc=$?
    nd_assert_rejected "大文字小文字非区別FSの冷状態でも .REVIEW-RESULTS/round2 は rc=2 で拒否" \
      "$rc" "$before" "$log" ".review-results" "$nrepo/.review-results/round2"
    mv "$work/case13-saved-results" "$nrepo/.review-results"

    before="$(count_invocations)"
    log="$work/case13-ci-reject.log"
    rc=0
    nd_run "$nrepo" "$log" bash "$MULTI_AGENT" --task review --base develop \
      --cli codex-cli --perspective code-review --output-dir .REVIEW-RESULTS/round2 || rc=$?
    nd_assert_rejected "大文字小文字非区別FSでの .REVIEW-RESULTS/round2 は rc=2 で拒否" \
      "$rc" "$before" "$log" ".review-results" "$nrepo/.review-results/round2"

    log="$work/case13-ci-self.log"
    rc=0
    nd_run "$nrepo" "$log" bash "$MULTI_AGENT" --task review --mode distributed --dry-run \
      --cli codex-cli --perspective code-review --base develop --output-dir .REVIEW-RESULTS || rc=$?
    if [[ "$rc" -eq 0 ]]; then
      ok "大文字小文字非区別FSでの .REVIEW-RESULTS 自身は --dry-run でネストと誤判定されず rc=0"
    else
      bad "大文字小文字非区別FSでの .REVIEW-RESULTS 自身がネスト誤判定等で失敗した (rc=${rc})"
      tail -10 "$log" | sed 's/^/    | /' >&2 || true
    fi
  else
    log="$work/case13-cs-upper.log"
    rc=0
    nd_run "$nrepo" "$log" bash "$MULTI_AGENT" --task review --mode distributed --dry-run \
      --cli codex-cli --perspective code-review --base develop --output-dir .REVIEW-RESULTS/round2 || rc=$?
    if [[ "$rc" -eq 0 ]]; then
      ok "大文字小文字区別FSでの .REVIEW-RESULTS/round2 は無差別 case-folding で誤拒否されず rc=0"
    else
      bad "大文字小文字区別FSでの .REVIEW-RESULTS/round2 が誤拒否された (rc=${rc})"
      tail -10 "$log" | sed 's/^/    | /' >&2 || true
    fi
  fi

  # 13a. Empty-directory case probe, spelling canonicalization, symlink prefix.
  local empty_dir="$work/empty-fold" empty_rc=0 resolved link id_rc=0 folds=1
  mkdir -p "$empty_dir" "$work/case-probe"
  if [[ -d "$work/case-probe/lower" && "$work/case-probe/Lower" -ef "$work/case-probe/lower" ]]; then
    folds=0
  fi
  ff_review_output_fs_folds_case "$empty_dir" || empty_rc=$?
  if [[ "$empty_rc" -eq "$folds" && -z "$(find "$empty_dir" -mindepth 1 -print)" ]]; then
    ok "空ディレクトリの大小判定は実ファイルシステムと一致し、探査ファイルを残さない"
  else
    bad "空ディレクトリの大小判定が不一致または探査ファイルが残った (rc=${empty_rc}, folds=${folds})"
  fi
  local link_dir="$work/hardlink-fold" link_rc=0
  mkdir -p "$link_dir"
  printf 'x\n' > "$link_dir/A"
  if ln "$link_dir/A" "$link_dir/a" 2>/dev/null; then
    ff_review_output_fs_folds_case "$link_dir" || link_rc=$?
    if [[ "$link_rc" -eq "$folds" && -z "$(find "$link_dir" -name '.ffCaseProbe*' -print)" ]]; then
      ok "大小が違うハードリンクだけでは大小を畳んだことにしない"
    else
      bad "ハードリンクの大小判定が不一致または探査ファイルが残った (rc=${link_rc}, folds=${folds})"
    fi
  else
    ok "大小が違うハードリンクは作れない（このファイルシステムでは別名が同じ項目）"
  fi
  resolved="$(ff_review_output_resolve_path "$nrepo" "$nrepo/.REVIEW-RESULTS/round2")"
  if [[ "$folds" -eq 0 && "$resolved" == "$nrepo/.review-results/round2" ]] \
    || [[ "$folds" -eq 1 && "$resolved" == "$nrepo/.REVIEW-RESULTS/round2" ]]; then
    ok "既定ルートの別名は、同じディレクトリのときだけ正規綴りへ書き戻す"
  else
    bad "既定ルートの別名の書き戻しが不一致 (resolved=${resolved}, folds=${folds})"
  fi
  link="$work/repo-link"
  ln -s "$nrepo" "$link"
  resolved="$(ff_review_output_resolve_path "$nrepo" "$link/.review-results/round2")"
  if [[ "$resolved" == "$link/.review-results/round2" ]]; then
    ok "リポジトリへのシンボリックリンク経由のパスは実パスへ書き換えない"
  else
    bad "シンボリックリンク経由のパスを実パスへ書き換えた (resolved=${resolved})"
  fi
  local anc_work anc_real anc_repo anc_sym anc_prep_rc=0
  anc_work="$(CDPATH='' cd -P -- "$work" && pwd -P)"
  anc_real="${anc_work}/anc-real"
  anc_repo="${anc_real}/inner-repo"
  anc_sym="${anc_work}/anc-sym"
  mkdir -p "$anc_repo"
  git -C "$anc_repo" init -q
  ln -s "$anc_real" "$anc_sym"
  resolved="$(ff_review_output_resolve_path "$anc_repo" "${anc_sym}/inner-repo/custom-out")"
  if [[ "$resolved" == "${anc_sym}/inner-repo/custom-out" ]]; then
    ok "親ディレクトリがシンボリックリンク経由のパスも実パスへ書き換えない"
  else
    bad "親ディレクトリ symlink 経由のパスを実パスへ書き換えた (resolved=${resolved})"
  fi
  (
    ff_review_output_prepare "$anc_repo" "${anc_sym}/inner-repo/custom-out" true review >/dev/null 2>&1
  ) || anc_prep_rc=$?
  if [[ "$anc_prep_rc" -ne 0 && ! -e "${anc_repo}/custom-out" ]]; then
    ok "親ディレクトリがシンボリックリンク経由の出力先は prepare で拒否され作成されない"
  else
    bad "親ディレクトリ symlink 経由の出力先が prepare で拒否されなかった (rc=${anc_prep_rc})"
  fi
  id_rc=0
  ff_review_output_marker_matches_identity \
    "$nrepo/.review-results/.multi-agent-output-owner" "$nrepo" "$nrepo/.review-results/." || id_rc=$?
  if [[ "$id_rc" -eq 0 ]]; then
    ok "所有マーカーは同じディレクトリの別表記（末尾 /.）でも一致する"
  else
    bad "同じディレクトリの別表記を所有マーカーが拒否した (rc=${id_rc})"
  fi
  id_rc=0
  ff_review_output_marker_matches_identity \
    "$nrepo/.review-results/.multi-agent-output-owner" "$nrepo" "$nrepo/.REVIEW-RESULTS" || id_rc=$?
  if [[ "$folds" -eq 0 && "$id_rc" -eq 0 ]] || [[ "$folds" -eq 1 && "$id_rc" -ne 0 ]]; then
    ok "大文字の既定ルートは、同じディレクトリのときだけ所有マーカーと一致する"
  else
    bad "大文字の既定ルートと所有マーカーの一致が不一致 (rc=${id_rc}, folds=${folds})"
  fi
  id_rc=0
  ff_review_output_marker_matches \
    "$nrepo/.review-results/.multi-agent-output-owner" "$nrepo" "$nrepo/.review-results/." || id_rc=$?
  if [[ "$id_rc" -eq 0 ]]; then
    ok "準備時の照合も同じディレクトリの別表記（末尾 /.）を受け付ける"
  else
    bad "準備時の照合が同じディレクトリの別表記を拒否した (rc=${id_rc})"
  fi
  id_rc=0
  ff_review_output_marker_matches \
    "$nrepo/.review-results/.multi-agent-output-owner" "$nrepo" "$work/empty-fold" || id_rc=$?
  if [[ "$id_rc" -ne 0 ]]; then
    ok "準備時の照合は別ディレクトリの所有マーカーを拒否する"
  else
    bad "準備時の照合が別ディレクトリの所有マーカーを通した"
  fi

  # 13b. Recovery child boundaries under initialized .review-results
  before="$(count_invocations)"
  log="$work/case13b-arbitrary-recovery.log"
  rc=0
  nd_run "$nrepo" "$log" bash "$MULTI_AGENT" --task review --base develop \
    --cli codex-cli --perspective code-review --output-dir .review-results/.recovery-round2 || rc=$?
  nd_assert_rejected "既存 .review-results 下の任意名 .recovery-round2 は rc=2 で拒否" \
    "$rc" "$before" "$log" ".review-results" "$nrepo/.review-results/.recovery-round2"

  before="$(count_invocations)"
  log="$work/case13c-nested-under-recovery.log"
  rc=0
  nd_run "$nrepo" "$log" bash "$MULTI_AGENT" --task review --base develop \
    --cli codex-cli --perspective code-review \
    --output-dir .review-results/.recovery-20261119-212641-97787-codex-cli-code-review-retry/sub || rc=$?
  nd_assert_rejected "既存 .review-results 下の正規 .recovery-* 配下2段ネストは rc=2 で拒否" \
    "$rc" "$before" "$log" ".review-results" \
    "$nrepo/.review-results/.recovery-20261119-212641-97787-codex-cli-code-review-retry"

  before="$(count_invocations)"
  log="$work/case13d-valid-recovery.log"
  rc=0
  nd_run "$nrepo" "$log" bash "$MULTI_AGENT" --task review --mode distributed --sequential \
    --cli codex-cli --perspective code-review --base develop --timeout 60 \
    --output-dir .review-results/.recovery-20261119-212641-97787-codex-cli-code-review-retry || rc=$?
  after_hash="$(git hash-object "$nrepo/.review-results/integrated-report.md")"
  if [[ "$rc" -eq 0 && "$(count_invocations)" -gt "$before" \
    && -f "$nrepo/.review-results/.recovery-20261119-212641-97787-codex-cli-code-review-retry/integrated-report.md" \
    && "$after_hash" == "$report_hash" ]]; then
    ok "初期化済み .review-results 直下の正規 .recovery-* は許容され復旧レポート生成・親レポート保全"
  else
    bad "初期化済み .review-results 直下の正規 .recovery-* 許容に失敗 (rc=${rc})"
    tail -15 "$log" | sed 's/^/    | /' >&2 || true
  fi

  mkdir -p "$nrepo/.review-results/.recovery-20261120-101112-124-unmarked"
  log="$work/case13d1-unmarked-recovery-archive.log"
  rc=0
  nd_run "$nrepo" "$log" bash "$multi_review" --route none --base develop --archive-only || rc=$?
  if [[ "$rc" -ne 0 ]] \
    && grep -qF 'unrelated or unknown archive entry' "$log" \
    && [[ -f "$nrepo/.review-results/integrated-report.md" ]] \
    && [[ -d "$nrepo/.review-results/.recovery-20261120-101112-124-unmarked" ]]; then
    ok "所有マーカーの無い復旧名ディレクトリは親の --archive-only を未知エントリで止める"
  else
    bad "所有マーカーの無い復旧名ディレクトリが親の --archive-only を止めなかった (rc=${rc})"
    tail -15 "$log" | sed 's/^/    | /' >&2 || true
  fi
  rm -rf "$nrepo/.review-results/.recovery-20261120-101112-124-unmarked"

  printf 'notes\n' > "$nrepo/.review-results/.recovery-20261120-101112-123-notes"
  log="$work/case13d2-recovery-file-archive.log"
  rc=0
  nd_run "$nrepo" "$log" bash "$multi_review" --route none --base develop --archive-only || rc=$?
  if [[ "$rc" -ne 0 ]] \
    && grep -qF 'unrelated or unknown archive entry' "$log" \
    && [[ -f "$nrepo/.review-results/integrated-report.md" ]] \
    && [[ -f "$nrepo/.review-results/.recovery-20261120-101112-123-notes" ]] \
    && [[ -f "$nrepo/.review-results/.recovery-20261119-212641-97787-codex-cli-code-review-retry/integrated-report.md" ]]; then
    ok "復旧名の通常ファイルは親の --archive-only を未知エントリで止める"
  else
    bad "復旧名の通常ファイルが親の --archive-only を止めなかった (rc=${rc})"
    tail -15 "$log" | sed 's/^/    | /' >&2 || true
  fi
  rm -f "$nrepo/.review-results/.recovery-20261120-101112-123-notes"

  log="$work/case13e-recovery-archive.log"
  rc=0
  nd_run "$nrepo" "$log" bash "$multi_review" --route none --base develop --archive-only || rc=$?
  if [[ "$rc" -eq 0 \
    && -f "$nrepo/.review-results/.recovery-20261119-212641-97787-codex-cli-code-review-retry/integrated-report.md" \
    && ! -e "$nrepo/.review-results/integrated-report.md" ]] \
    && ! grep -qF 'unrelated or unknown archive entry' "$log"; then
    ok "正規 .recovery-* が残っていても親の --archive-only は停止せず復旧出力を動かさない"
  else
    bad "正規 .recovery-* 残留時の親 --archive-only が失敗した (rc=${rc})"
    tail -15 "$log" | sed 's/^/    | /' >&2 || true
  fi
  recovery_anchor="$(ff_review_output_recovery_anchor "$nrepo/.review-results/.recovery-20261119-212641-97787-codex-cli-code-review-retry")"
  plain_anchor="$(ff_review_output_recovery_anchor "$nrepo/.review-results")"
  local custom_anchor
  custom_anchor="$(ff_review_output_recovery_anchor "$nrepo/.recovery-20261120-101112-124-custom")"
  canonical_child="$(ff_review_output_canonical_child "$nrepo/.review-results" "$nrepo/.REVIEW-RESULTS" "$nrepo/.REVIEW-RESULTS/.recovery-20261119-212641-97787-codex-cli-code-review-retry")"
  if [[ "$recovery_anchor" == "$nrepo/.review-results" && "$plain_anchor" == "$nrepo/.review-results" \
    && "$custom_anchor" == "$nrepo/.recovery-20261120-101112-124-custom" \
    && "$canonical_child" == "$nrepo/.review-results/.recovery-20261119-212641-97787-codex-cli-code-review-retry" ]]; then
    ok "復旧の再案内は既定ルート直下だけ親へ戻り、それ以外の復旧名は動かさない"
  else
    bad "復旧アンカーの書き戻しが一致しない (recovery=${recovery_anchor}, plain=${plain_anchor}, custom=${custom_anchor}, child=${canonical_child})"
  fi
  rm -rf "$nrepo/.review-results/.recovery-20261119-212641-97787-codex-cli-code-review-retry"

  log="$work/case13f-parent-traversal-dry-run.log"
  rc=0
  nd_run "$nrepo" "$log" bash "$MULTI_AGENT" --task review --mode distributed --dry-run \
    --cli codex-cli --perspective code-review --base develop \
    --output-dir '.review-results/../.review-results/round2' || rc=$?
  if [[ "$rc" -ne 0 ]] && grep -qF 'parent traversal is not allowed' "$log" \
    && ! grep -qF 'Dry run complete' "$log"; then
    ok "親参照を含む --output-dir の --dry-run は成功に畳まず解決エラーで止まる"
  else
    bad "親参照を含む --output-dir の --dry-run が成功扱いになった (rc=${rc})"
    tail -15 "$log" | sed 's/^/    | /' >&2 || true
  fi

  # 13g. Symlinked default root with uppercase subpath on case-insensitive FS (pre-check --dry-run)
  mkdir -p "$work/sym-default-target"
  rm -rf "$nrepo/.review-results"
  ln -s "$work/sym-default-target" "$nrepo/.review-results"
  before="$(count_invocations)"
  log="$work/case13g-symlink-default-upper.log"
  rc=0
  nd_run "$nrepo" "$log" bash "$MULTI_AGENT" --task review --mode distributed --dry-run \
    --cli codex-cli --perspective code-review --base develop \
    --output-dir .REVIEW-RESULTS/round2 || rc=$?
  if [[ "$folds" -eq 0 ]]; then
    nd_assert_rejected "大文字小文字非区別FSで .review-results が symlink でも .REVIEW-RESULTS/round2 の --dry-run は rc=2 で拒否" \
      "$rc" "$before" "$log" ".review-results" "$work/sym-default-target/round2"
  else
    if [[ "$rc" -eq 0 ]]; then
      ok "大文字小文字区別FSで .review-results が symlink の場合 .REVIEW-RESULTS/round2 の --dry-run は誤拒否されない"
    else
      bad "大文字小文字区別FSで .review-results が symlink の .REVIEW-RESULTS/round2 が誤拒否された (rc=${rc})"
      tail -15 "$log" | sed 's/^/    | /' >&2 || true
    fi
  fi
  log="$work/case13g-symlink-default-self.log"
  rc=0
  nd_run "$nrepo" "$log" bash "$MULTI_AGENT" --task review --mode distributed --dry-run \
    --cli codex-cli --perspective code-review --base develop \
    --output-dir .REVIEW-RESULTS || rc=$?
  if [[ "$rc" -eq 0 ]]; then
    ok ".review-results が symlink でも .REVIEW-RESULTS 自身の --dry-run はネストと誤判定されない"
  else
    bad ".review-results が symlink のとき .REVIEW-RESULTS 自身の --dry-run が失敗した (rc=${rc})"
    tail -15 "$log" | sed 's/^/    | /' >&2 || true
  fi
  rm -f "$nrepo/.review-results"

  # 14. End-to-end nested default output scenario (Issue `#2869`): default -> nested rejected -> sibling ok -> archive-only ok
  rm -rf "$nrepo/.review-results" "$nrepo/.review-results-round2"
  log="$work/case14-e2e-default.log"
  rc=0
  nd_run "$nrepo" "$log" bash "$multi_review" --route none --base develop --cli codex-cli --perspective code-review || rc=$?
  if [[ "$rc" -eq 0 && -f "$nrepo/.review-results/integrated-report.md" ]]; then
    ok "E2E: 既定 .review-results でのレビューが成功する"
  else
    bad "E2E: 既定 .review-results でのレビューが失敗した (rc=${rc})"
    tail -10 "$log" | sed 's/^/    | /' >&2 || true
  fi

  before="$(count_invocations)"
  log="$work/case14-e2e-nested.log"
  rc=0
  nd_run "$nrepo" "$log" bash "$multi_review" --route none --base develop --cli codex-cli --perspective code-review --output-dir .review-results/round2 || rc=$?
  nd_assert_rejected "E2E: 2巡目で .review-results/round2 指定は起動前に rc=2 で拒否" \
    "$rc" "$before" "$log" ".review-results" "$nrepo/.review-results/round2"

  log="$work/case14-e2e-sibling.log"
  rc=0
  nd_run "$nrepo" "$log" bash "$multi_review" --route none --base develop --cli codex-cli --perspective code-review --output-dir .review-results-round2 || rc=$?
  if [[ "$rc" -eq 0 && -f "$nrepo/.review-results-round2/integrated-report.md" ]]; then
    ok "E2E: 外側の兄弟ディレクトリ .review-results-round2 での再検証が成功する"
  else
    bad "E2E: .review-results-round2 での再検証が失敗した (rc=${rc})"
    tail -10 "$log" | sed 's/^/    | /' >&2 || true
  fi

  log="$work/case14-e2e-archive.log"
  rc=0
  nd_run "$nrepo" "$log" bash "$multi_review" --route none --base develop --archive-only || rc=$?
  archive_dir="$(find "$nrepo/.review-results" -maxdepth 1 -type d -name '.prev-*' 2>/dev/null | head -n 1 || true)"
  if [[ "$rc" -eq 0 && -n "$archive_dir" && -f "$archive_dir/integrated-report.md" && ! -e "$nrepo/.review-results/integrated-report.md" ]] \
    && ! grep -qF 'unrelated or unknown archive entry' "$log"; then
    ok "E2E: 後続の --archive-only が unrelated or unknown archive entry で停止せず退避に成功する"
  else
    bad "E2E: 後続の --archive-only が失敗した (rc=${rc}, archive=${archive_dir})"
    tail -15 "$log" | sed 's/^/    | /' >&2 || true
  fi

  # Positive controls (allowed paths)
  rm -rf "$nrepo/.review-results" "$nrepo/.review-results-round2"
  local ctrl_spec ctrl_label ctrl_dir
  for ctrl_spec in \
    "既定と同値の相対パス (.review-results)|.review-results" \
    "末尾スラッシュ付き (.review-results/)|.review-results/" \
    "ドットセグメント付き (./.review-results/.)|./.review-results/." \
    "絶対パス (\$REPO/.review-results)|${nrepo}/.review-results" \
    "接頭辞一致の兄弟ディレクトリ (.review-results-round2)|.review-results-round2" \
    "リポジトリ外の出力先|${work}/external-review-round2" \
    "リポジトリ外で .review-results/round2 名を含むパス|${work}/external-parent/.review-results/round2"; do
    ctrl_label="${ctrl_spec%%|*}"
    ctrl_dir="${ctrl_spec#*|}"
    before="$(count_invocations)"
    log="$work/ctrl-$(printf '%s' "$ctrl_label" | cksum | awk '{print $1}').log"
    rc=0
    nd_run "$nrepo" "$log" bash "$MULTI_AGENT" --task review --mode distributed --sequential \
      --cli codex-cli --perspective code-review --base develop --timeout 60 --output-dir "$ctrl_dir" || rc=$?
    if [[ "$rc" -eq 0 && "$(count_invocations)" -gt "$before" ]]; then
      ok "正対照(許容): ${ctrl_label}"
    else
      bad "正対照(許容)が失敗した: ${ctrl_label} (rc=${rc})"
      tail -15 "$log" | sed 's/^/    | /' >&2 || true
    fi
  done

  if ! grep -nE "tr '\\[:(upper|lower):]'" "$PLUGIN_ROOT/scripts/lib/multi-agent-boundary.sh" | grep -v 'LC_ALL=C' >/dev/null; then
    ok "大小比較の tr は C ロケールに固定している"
  else
    bad "大小比較の tr に C ロケール固定の無い呼び出しがある"
  fi

  # Documentation contract checks
  # shellcheck disable=SC2016
  if grep -qF '`.review-results/` の外に置く' "$review_skill" \
    && grep -qF 'を除き、配下は exit 2 で拒否' "$review_skill"; then
    ok "文書契約: skills/multi-review/SKILL.md が --output-dir を .review-results/ の外に置くことと exit 2 拒否を明記"
  else
    bad "文書契約: skills/multi-review/SKILL.md に .review-results/ 外の明記が不足"
  fi

  # shellcheck disable=SC2016
  if grep -qF '`.review-results/` の外に置く' "$orch_doc" \
    && grep -qF 'exit 2 で拒否される' "$orch_doc" \
    && grep -qF '名前だけが一致する通常ファイル' "$orch_doc"; then
    ok "文書契約: multi-cli-review-orchestration.md が --output-dir を .review-results/ の外に置くことと exit 2 拒否を明記"
  else
    bad "文書契約: multi-cli-review-orchestration.md に .review-results/ 外の明記が不足"
  fi

  if ! grep -qF '.review-results/precheck' "$orch_doc"; then
    ok "文書契約: 先行レビュー案内は .review-results/precheck を出力先に残していない"
  else
    bad "文書契約: 先行レビュー案内が .review-results/precheck を出力先として残している"
  fi

  rm -rf "$work" "$nrepo/.review-results-round2" "$nrepo/.REVIEW-RESULTS" "$nrepo/.claude"
}
