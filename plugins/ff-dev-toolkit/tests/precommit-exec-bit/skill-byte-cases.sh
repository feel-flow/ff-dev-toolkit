#!/usr/bin/env bash
# Sourced by verify.sh; isolated git inputs exercise the actual precommit lib.
run_skill_byte_cases() {
  local r p limit review_limit out rc err candidate fixture finish review source_finish source_review
  local stub="${TMP}/byte-bin"
  # shellcheck source=../lib/skill-byte-guard.sh
  . "$TESTS_DIR/lib/skill-byte-guard.sh"
  r="$(new_repo skill-bytes)"
  fixture=plugins/ff-dev-toolkit
  finish="$fixture/tests/finish/verify.sh"
  review="$fixture/tests/review-rejection-discipline/verify.sh"
  source_finish="$TESTS_DIR/finish/verify.sh"
  source_review="$TESTS_DIR/review-rejection-discipline/verify.sh"
  mkdir -p "$r/$fixture/tests/finish" "$r/$fixture/tests/review-rejection-discipline"
  cp "$source_finish" "$r/$finish"
  cp "$source_review" "$r/$review"
  git -C "$r" add .; git -C "$r" commit -qm definitions
  limit="$(awk -F= '/^SKILL_BYTE_LIMIT=/{print $2}' "$source_finish")"
  review_limit="$(awk -F= '/^SKILL_MAX_BYTES=/{print $2}' "$source_review")"
  p="$fixture/skills/close-issue/SKILL.md"

  byte_expect() {
    local label="$1" expected="$2" needle="$3"
    rc=0; out="$(skill_byte_scan "$r" 2>"$TMP/byte-err")" || rc=$?
    err="$(cat "$TMP/byte-err")"
    if [ "$rc" -eq "$expected" ] && [[ "$out$err" == *"$needle"* ]]; then
      ok "SB ${label}"
    else
      bad "SB ${label} (rc=${rc} out=${out} err=${err})"
    fi
  }
  byte_stage() {
    mkdir -p "$(dirname "$r/$1")"
    if [ "$2" -eq 0 ]; then : >"$r/$1"; else head -c "$2" /dev/zero | tr '\0' a >"$r/$1"; fi
    git -C "$r" add -- "$1"
  }
  byte_expect 'empty index is none' 0 'skill-byte: none'
  printf '\n# WIP\n' >>"$r/$finish"
  byte_expect 'empty index ignores worktree-only definition WIP' 0 'skill-byte: none'
  printf 'readme change\n' >"$r/README.md"; git -C "$r" add README.md
  byte_expect 'README-only staged change ignores definition WIP' 0 'skill-byte: none'
  git -C "$r" reset -q HEAD -- README.md
  byte_stage "$fixture/skills/unlisted/SKILL.md" "$((limit + 1))"
  byte_expect 'unlisted skill ignores definition WIP' 0 'skill-byte: none'
  cp "$source_finish" "$r/$finish"
  byte_stage "$p" "$limit"
  byte_expect 'exact boundary passes' 0 'skill-byte: ok 1'
  byte_stage "$p" "$((limit + 1))"
  byte_expect 'over limit names path / bytes / bound' 1 "${p}: $((limit + 1)) B > ${limit} B"
  printf small >"$r/$p"
  byte_expect 'worktree-only repair cannot hide staged violation' 1 "${p}: $((limit + 1)) B > ${limit} B"
  git -C "$r" add -- "$p"
  byte_expect 'restaging repair passes' 0 'skill-byte: ok 1'
  byte_stage "$fixture/skills/multi-review/SKILL.md" "$((review_limit + 1))"
  byte_expect 'multi-review has its own existing bound' 1 "multi-review/SKILL.md: $((review_limit + 1)) B > ${review_limit} B"
  git -C "$r" reset -q HEAD
  # Values and roster are live inputs: a new roster member and changed limits
  # must affect the guard without adding constants or names to its code.
  printf '%s\n' 'SKILL_BYTE_LIMIT=31' 'SKILL_ROSTER="fixture-skill"' >"$r/$finish"
  printf '%s\n' 'SKILL_MAX_BYTES=37' >"$r/$review"
  git -C "$r" add -- "$finish" "$review"
  byte_stage "$fixture/skills/fixture-skill/SKILL.md" 32
  byte_expect 'changed roster and bound are read from suite' 1 'fixture-skill/SKILL.md: 32 B > 31 B'
  byte_stage "$fixture/skills/fixture-skill/SKILL.md" 31
  byte_expect 'changed exact bound passes' 0 'skill-byte: ok 1'
  byte_stage "$fixture/skills/multi-review/SKILL.md" 38
  byte_expect 'changed review bound is read from suite' 1 'multi-review/SKILL.md: 38 B > 37 B'
  byte_stage "$fixture/skills/multi-review/SKILL.md" 37
  byte_stage "$fixture/skills/fixture-skill/SKILL.md" 32
  printf '%s\n' 'SKILL_BYTE_LIMIT=999' 'SKILL_ROSTER="fixture-skill"' >"$r/$finish"
  byte_expect 'unstaged definition cannot mask index contract' 1 'fixture-skill/SKILL.md: 32 B > 31 B'
  for candidate in empty missing-limit duplicate malformed empty-roster duplicate-roster; do
    case "$candidate" in
      empty) : >"$r/$finish" ;;
      missing-limit) printf '%s\n' 'SKILL_ROSTER="fixture-skill"' >"$r/$finish" ;;
      duplicate) printf '%s\n' 'SKILL_BYTE_LIMIT=31' 'SKILL_BYTE_LIMIT=99' 'SKILL_ROSTER="fixture-skill"' >"$r/$finish" ;;
      malformed) printf '%s\n' 'SKILL_BYTE_LIMIT=$((31))' 'SKILL_ROSTER="fixture-skill"' >"$r/$finish" ;;
      empty-roster) printf '%s\n' 'SKILL_BYTE_LIMIT=31' 'SKILL_ROSTER=""' >"$r/$finish" ;;
      duplicate-roster) printf '%s\n' 'SKILL_BYTE_LIMIT=31' 'SKILL_ROSTER="fixture-skill fixture-skill"' >"$r/$finish" ;;
    esac
    git -C "$r" add -- "$finish"
    byte_expect "invalid definition ${candidate} is unmeasured" 2 'SKILL容量未検査'
  done
  rm "$r/$review"; git -C "$r" add -u -- "$review"
  byte_expect 'missing review definition is unmeasured' 2 'SKILL容量未検査'
  cp "$source_finish" "$r/$finish"; cp "$source_review" "$r/$review"
  git -C "$r" add -- "$finish" "$review"
  byte_stage "$p" 0
  byte_expect 'empty index blob is unmeasured' 2 'index内容が空'
  byte_stage "$p" 10
  # A symlink must not measure its short target text as a SKILL document.
  out="$(printf target | git -C "$r" hash-object -w --stdin)"
  git -C "$r" update-index --cacheinfo "120000,${out},${p}"
  byte_expect 'non-regular index entry is unmeasured' 2 '通常ファイルではありません'
  byte_stage "$p" 10
  git -C "$r" commit -qm before-delete
  git -C "$r" rm -q -- "$p"
  byte_expect 'deleted roster member is unmeasured' 2 '通常ファイルではありません'
  git -C "$r" reset -q HEAD -- "$p"; git -C "$r" checkout -- "$p"
  byte_stage "$p" 11
  byte_expect 'modified roster member is measured before failure stubs' 0 'skill-byte: ok 1'
  mkdir -p "$stub"
  cat >"$stub/git" <<'STUB'
#!/usr/bin/env bash
case " $* " in
  *' diff --cached '*)
    case "$BYTE_STUB" in
      fail) exit 7 ;;
      malformed) printf 'plugins/ff-dev-toolkit/skills/close-issue/SKILL.md'; exit 0 ;;
    esac ;;
  *' show :plugins/ff-dev-toolkit/tests/'*) [ "$BYTE_STUB" != definition-fail ] || exit 7 ;;
  *' show :plugins/ff-dev-toolkit/skills/'*) [ "$BYTE_STUB" != show-fail ] || exit 7 ;;
  *' ls-files --unmerged '*) [ "$BYTE_STUB" != conflict ] || { echo conflict; exit 0; } ;;
esac
exec "$BYTE_REAL_GIT" "$@"
STUB
  chmod +x "$stub/git"
  for candidate in fail malformed show-fail definition-fail conflict; do
    BYTE_STUB="$candidate" BYTE_REAL_GIT="$REAL_GIT" PATH="$stub:$PATH" byte_expect "git ${candidate} is unmeasured" 2 'SKILL容量未検査'
  done
  cat >"$stub/wc" <<'STUB'
#!/usr/bin/env bash
printf 12
exit 7
STUB
  chmod +x "$stub/wc"
  BYTE_STUB=pass BYTE_REAL_GIT="$REAL_GIT" PATH="$stub:$PATH" byte_expect 'wc failure is unmeasured even with numeric output' 2 'バイト数を測れません'

  # --- Shortening candidate suggestions & fail-closed behavior ---
  local rcand p_cand p_cand2 cand_out cand_err cand_rc pos_long pos_mid pos_short sym_oid
  rcand="$(new_repo skill-byte-candidates)"
  mkdir -p "$rcand/$fixture/tests/finish" \
           "$rcand/$fixture/tests/review-rejection-discipline" \
           "$rcand/$fixture/tests/alpha-suite" \
           "$rcand/$fixture/tests/beta-suite" \
           "$rcand/$fixture/skills/cand-skill" \
           "$rcand/$fixture/skills/multi-review"
  printf '%s\n' 'SKILL_BYTE_LIMIT=120' 'SKILL_ROSTER="cand-skill"' >"$rcand/$finish"
  printf '%s\n' 'SKILL_MAX_BYTES=120' >"$rcand/$review"
  cat >"$rcand/$fixture/tests/alpha-suite/verify.sh" <<'ALPHA'
#!/usr/bin/env bash
contains() { grep -qF -- "$2" "$1"; }
needle=const-var-needle-keep
contains "$SKILL" "alpha-needle-one" "label 1"
contains "$SKILL" 'OK' 'short 2-byte marker'
not_contains "$SKILL" "alpha-forbid-two" "label 2"
contains "$SKILL" \
  "alpha-multiline-needle" \
  "label multiline"
contains "$SKILL" "$needle" "const var needle"
contains "two-arg-needle-keep" "label two-arg"
true && contains "$SKILL" "chained-and-needle" "label chained"
ALPHA
  cat >"$rcand/$fixture/tests/beta-suite/verify.sh" <<'BETA'
#!/usr/bin/env bash
section_contains "$SKILL" "## Guarded Section" "beta-section-needle" "label 3"
section_not_contains "$SKILL" "beta-sec-forbid" "label 4"
doc_has "$SKILL" "disp" "beta-dochas-needle" "label 5"
section_has "$SEC" "disp" "beta-sechas-needle" "label 6"
if [ -f "$SKILL" ] && grep -q -e 'gamma-grep-needle' -- "$SKILL"; then
  echo ok
fi
grep -qF '^fixed-caret-needle$' "$SKILL"
BETA
  git -C "$rcand" add .
  git -C "$rcand" commit -qm cand-setup
  p_cand="$fixture/skills/cand-skill/SKILL.md"
  p_cand2="$fixture/skills/multi-review/SKILL.md"
  cat >"$rcand/$p_cand" <<'SKILL'
---
name: cand-skill
description: frontmatter-should-not-appear-in-candidates-even-when-very-long-line
---
<!-- ff-dev-toolkit-plugin-root-guard:start -->
GUARD_BLOCK_LINE_SHOULD_NOT_BE_SUGGESTED_EVEN_IF_VERY_LONG_012345678901234567890123456789
<!-- ff-dev-toolkit-plugin-root-guard:end -->
PINNED_ALPHA_LINE_WITH_alpha-needle-one_PADDING_0123456789012345678901234567890123456789
PINNED_NOTCONTAINS_alpha-forbid-two_PADDING_012345678901234567890123456789
PINNED_MULTILINE_alpha-multiline-needle_PADDING_012345678901234567890123456789
PINNED_CONSTVAR_const-var-needle-keep_PADDING_012345678901234567890123456789
PINNED_TWOARG_two-arg-needle-keep_PADDING_01234567890123456789
PINNED_CHAINED_chained-and-needle_PADDING_01234567890123456789
PINNED_BETA_LINE_beta-section-needle_AND_gamma-grep-needle_PADDING_0123456789
PINNED_BETA_EXTRA_beta-sec-forbid_beta-dochas-needle_beta-sechas-needle_PADDING_0123456789
PINNED_SHORT_2B_MARKER_OK_PADDING_01234567890123456789012345678901234567890123456789
PINNED_FIXED_CARET_^fixed-caret-needle$_PADDING_0123456789012345678901234567890123456789
FREE_SHORT_20B_XXXXX
FREE_LONGEST_LINE_日本語バイト計測テスト_0123456789012345678901234567890123456789
FREE_SECOND_LINE_MIDDLE_BYTES_01234567890123456789
SKILL
  git -C "$rcand" add -- "$p_cand"
  cand_rc=0
  cand_out="$(skill_byte_scan "$rcand" 2>"$TMP/cand-err")" || cand_rc=$?
  cand_err="$(cat "$TMP/cand-err")"
  printf '%s\n' "$cand_out" >"$TMP/cand-out"
  pos_long="$(awk '/FREE_LONGEST_LINE_/{print NR; exit}' "$TMP/cand-out")"
  pos_mid="$(awk '/FREE_SECOND_LINE_/{print NR; exit}' "$TMP/cand-out")"
  pos_short="$(awk '/FREE_SHORT_20B_XXXXX/{print NR; exit}' "$TMP/cand-out")"
  if [ "$cand_rc" -eq 1 ] \
    && grep -qF -- '短縮候補（針なし・バイト数降順' "$TMP/cand-out" \
    && [ -n "$pos_long" ] && [ -n "$pos_mid" ] && [ -n "$pos_short" ] \
    && [ "$pos_long" -lt "$pos_mid" ] && [ "$pos_mid" -lt "$pos_short" ]; then
    ok 'SB over limit lists non-needle candidates in descending byte order'
  else
    bad "SB candidate order failed (rc=${cand_rc} pos=${pos_long}/${pos_mid}/${pos_short} out=${cand_out} err=${cand_err})"
  fi
  if ! grep -qF -- 'PINNED_ALPHA_LINE_' "$TMP/cand-out" \
    && ! grep -qF -- 'PINNED_NOTCONTAINS_' "$TMP/cand-out" \
    && ! grep -qF -- 'PINNED_MULTILINE_' "$TMP/cand-out" \
    && ! grep -qF -- 'PINNED_CONSTVAR_' "$TMP/cand-out" \
    && ! grep -qF -- 'PINNED_TWOARG_' "$TMP/cand-out" \
    && ! grep -qF -- 'PINNED_CHAINED_' "$TMP/cand-out" \
    && ! grep -qF -- 'PINNED_BETA_LINE_' "$TMP/cand-out" \
    && ! grep -qF -- 'PINNED_BETA_EXTRA_' "$TMP/cand-out" \
    && ! grep -qF -- 'PINNED_SHORT_2B_MARKER_' "$TMP/cand-out" \
    && ! grep -qF -- 'PINNED_FIXED_CARET_' "$TMP/cand-out" \
    && ! grep -qF -- 'GUARD_BLOCK_LINE_' "$TMP/cand-out" \
    && ! grep -qF -- 'frontmatter-should-not-appear' "$TMP/cand-out" \
    && grep -qF -- '針あり（alpha-suite）' "$TMP/cand-out" \
    && grep -qF -- '針あり（beta-suite）' "$TMP/cand-out"; then
    ok 'SB pinned lines (including const var, chained, doc_has, section_has, grep -e) and protected blocks are excluded'
  else
    bad "SB pinned/protected exclusion failed (out=${cand_out})"
  fi

  # Index vs worktree: removing needle in worktree without staging must NOT expose index-pinned line as candidate
  printf '%s\n' '#!/usr/bin/env bash' 'contains "$SKILL" "only-unrelated-wt" "wt"' >"$rcand/$fixture/tests/alpha-suite/verify.sh"
  cand_rc=0
  cand_out="$(skill_byte_scan "$rcand" 2>"$TMP/cand-err")" || cand_rc=$?
  printf '%s\n' "$cand_out" >"$TMP/cand-out"
  if [ "$cand_rc" -eq 1 ] \
    && ! grep -qF -- 'PINNED_ALPHA_LINE_' "$TMP/cand-out" \
    && grep -qF -- 'FREE_LONGEST_LINE_' "$TMP/cand-out"; then
    ok 'SB reads needles from git index and ignores unstaged worktree edits to verify.sh'
  else
    bad "SB index needle isolation failed (rc=${cand_rc} out=${cand_out})"
  fi
  git -C "$rcand" checkout -- "$fixture/tests/alpha-suite/verify.sh"

  # Multiple over-limit skills reuse cached needle extraction and emit candidates for both
  cat >"$rcand/$p_cand2" <<'SKILL2'
PINNED_SECOND_FILE_alpha-needle-one_0123456789012345678901234567890123456789
FREE_MULTI_REVIEW_CANDIDATE_LINE_01234567890123456789012345678901234567890123456789
SKILL2
  git -C "$rcand" add -- "$p_cand2"
  cand_rc=0
  cand_out="$(skill_byte_scan "$rcand" 2>"$TMP/cand-err")" || cand_rc=$?
  printf '%s\n' "$cand_out" >"$TMP/cand-out"
  if [ "$cand_rc" -eq 1 ] \
    && grep -qF -- 'FREE_LONGEST_LINE_' "$TMP/cand-out" \
    && grep -qF -- 'FREE_MULTI_REVIEW_CANDIDATE_LINE_' "$TMP/cand-out" \
    && ! grep -qF -- 'PINNED_SECOND_FILE_' "$TMP/cand-out"; then
    ok 'SB multiple over-limit skills reuse extracted needles and suggest candidates for each'
  else
    bad "SB multiple over-limit skills failed (rc=${cand_rc} out=${cand_out})"
  fi
  git -C "$rcand" reset -q HEAD -- "$p_cand2"
  rm -f "$rcand/$p_cand2"

  # Within limit: output and rc remain completely unchanged
  printf 'short body under limit\n' >"$rcand/$p_cand"
  git -C "$rcand" add -- "$p_cand"
  cand_rc=0
  cand_out="$(skill_byte_scan "$rcand" 2>"$TMP/cand-err")" || cand_rc=$?
  if [ "$cand_rc" -eq 0 ] && [ "$cand_out" = 'skill-byte: ok 1' ]; then
    ok 'SB within limit keeps exact ok output and rc=0'
  else
    bad "SB within limit changed output (rc=${cand_rc} out=${cand_out})"
  fi

  # Over limit where every non-empty line is pinned -> no candidates (distinct from extraction error)
  cat >"$rcand/$p_cand" <<'ALLPIN'
PINNED_ONLY_1_alpha-needle-one_01234567890123456789012345678901234567890123456789
PINNED_ONLY_2_gamma-grep-needle_01234567890123456789012345678901234567890123456789
ALLPIN
  git -C "$rcand" add -- "$p_cand"
  cand_rc=0
  cand_out="$(skill_byte_scan "$rcand" 2>"$TMP/cand-err")" || cand_rc=$?
  printf '%s\n' "$cand_out" >"$TMP/cand-out"
  if [ "$cand_rc" -eq 1 ] \
    && grep -qF -- '短縮候補: なし（針を持たない行がありません' "$TMP/cand-out" \
    && ! grep -qF -- 'PINNED_ONLY_1_' "$TMP/cand-out"; then
    ok 'SB all-pinned over-limit reports no free candidates without listing pinned lines'
  else
    bad "SB all-pinned handling failed (rc=${cand_rc} out=${cand_out})"
  fi

  # Fail-closed (1): dynamic/unresolved variable needle mixed with fixed literal needle -> no candidates, prints suite:line reason
  cat >"$rcand/$p_cand" <<'OVER'
FREE_CANDIDATE_MUST_NOT_APPEAR_WHEN_EXTRACTION_FAILS_0123456789012345678901234567890123456789
FREE_CANDIDATE_SECOND_LINE_0123456789012345678901234567890123456789
OVER
  git -C "$rcand" add -- "$p_cand"
  cat >"$rcand/$fixture/tests/alpha-suite/verify.sh" <<'DYNVAR'
#!/usr/bin/env bash
contains "$SKILL" "fixed-needle-ok" "fixed"
dyn="$(printf keep-this-line)"
contains "$SKILL" "$dyn" "dynamic"
DYNVAR
  git -C "$rcand" add -- "$fixture/tests/alpha-suite/verify.sh"
  cand_rc=0
  cand_out="$(skill_byte_scan "$rcand" 2>"$TMP/cand-err")" || cand_rc=$?
  printf '%s\n' "$cand_out" >"$TMP/cand-out"
  if [ "$cand_rc" -eq 1 ] \
    && grep -qF -- '短縮候補なし（針の抽出に失敗:' "$TMP/cand-out" \
    && grep -qF -- '未解決の変数を含む針を静的抽出できません（alpha-suite:4）' "$TMP/cand-out" \
    && ! grep -qF -- 'FREE_CANDIDATE_MUST_NOT_APPEAR' "$TMP/cand-out"; then
    ok 'SB fail-closed on unresolved dynamic variable needle omits candidates and names suite:line'
  else
    bad "SB fail-closed unresolved dynamic variable failed (rc=${cand_rc} out=${cand_out})"
  fi

  # Fail-closed (2): regex grep pattern without -F -> no candidates, prints suite:line reason
  cat >"$rcand/$fixture/tests/alpha-suite/verify.sh" <<'GREPREGEX'
#!/usr/bin/env bash
contains "$SKILL" "fixed-needle-ok" "fixed"
grep -qE '^Required completion marker$' "$SKILL"
GREPREGEX
  git -C "$rcand" add -- "$fixture/tests/alpha-suite/verify.sh"
  cand_rc=0
  cand_out="$(skill_byte_scan "$rcand" 2>"$TMP/cand-err")" || cand_rc=$?
  printf '%s\n' "$cand_out" >"$TMP/cand-out"
  if [ "$cand_rc" -eq 1 ] \
    && grep -qF -- '短縮候補なし（針の抽出に失敗:' "$TMP/cand-out" \
    && grep -qF -- '固定文字列として解釈できない grep パターン（alpha-suite:3）' "$TMP/cand-out" \
    && ! grep -qF -- 'FREE_CANDIDATE_MUST_NOT_APPEAR' "$TMP/cand-out"; then
    ok 'SB fail-closed on regex grep pattern without -F omits candidates and names suite:line'
  else
    bad "SB fail-closed regex grep failed (rc=${cand_rc} out=${cand_out})"
  fi

  # Fail-closed (3): malformed quote in chained helper call -> no candidates, prints reason
  printf '%s\n' '#!/usr/bin/env bash' 'true && contains "$SKILL" "unterminated-needle' >"$rcand/$fixture/tests/alpha-suite/verify.sh"
  git -C "$rcand" add -- "$fixture/tests/alpha-suite/verify.sh"
  cand_rc=0
  cand_out="$(skill_byte_scan "$rcand" 2>"$TMP/cand-err")" || cand_rc=$?
  printf '%s\n' "$cand_out" >"$TMP/cand-out"
  if [ "$cand_rc" -eq 1 ] \
    && grep -qF -- '短縮候補なし（針の抽出に失敗:' "$TMP/cand-out" \
    && grep -qF -- '引用符が閉じていません（alpha-suite:2）' "$TMP/cand-out" \
    && ! grep -qF -- 'FREE_CANDIDATE_MUST_NOT_APPEAR' "$TMP/cand-out"; then
    ok 'SB fail-closed on unterminated quote in helper call omits candidates and explains reason'
  else
    bad "SB fail-closed unterminated quote failed (rc=${cand_rc} out=${cand_out})"
  fi

  # Fail-closed (3): non-regular verify.sh entry in index (120000 symlink) -> no candidates, prints reason
  git -C "$rcand" checkout HEAD -- "$fixture/tests/alpha-suite/verify.sh"
  sym_oid="$(printf 'target' | git -C "$rcand" hash-object -w --stdin)"
  git -C "$rcand" update-index --add --cacheinfo "120000,${sym_oid},${fixture}/tests/bad-link/verify.sh"
  cand_rc=0
  cand_out="$(skill_byte_scan "$rcand" 2>"$TMP/cand-err")" || cand_rc=$?
  printf '%s\n' "$cand_out" >"$TMP/cand-out"
  if [ "$cand_rc" -eq 1 ] \
    && grep -qF -- '短縮候補なし（針の抽出に失敗:' "$TMP/cand-out" \
    && grep -qF -- '通常ファイルではありません' "$TMP/cand-out" \
    && ! grep -qF -- 'FREE_CANDIDATE_MUST_NOT_APPEAR' "$TMP/cand-out"; then
    ok 'SB fail-closed on non-regular verify.sh in index omits candidates and explains reason'
  else
    bad "SB fail-closed non-regular verify.sh failed (rc=${cand_rc} out=${cand_out})"
  fi
  git -C "$rcand" rm -q --cached -- "$fixture/tests/bad-link/verify.sh"

  # Fail-closed (4): zero extracted needles in index -> no candidates, prints reason
  git -C "$rcand" rm -q -r -- "$fixture/tests/alpha-suite" "$fixture/tests/beta-suite"
  cand_rc=0
  cand_out="$(skill_byte_scan "$rcand" 2>"$TMP/cand-err")" || cand_rc=$?
  printf '%s\n' "$cand_out" >"$TMP/cand-out"
  if [ "$cand_rc" -eq 1 ] \
    && grep -qF -- '短縮候補なし（針の抽出に失敗:' "$TMP/cand-out" \
    && grep -qF -- '針を 1 件も抽出できませんでした' "$TMP/cand-out" \
    && ! grep -qF -- 'FREE_CANDIDATE_MUST_NOT_APPEAR' "$TMP/cand-out"; then
    ok 'SB fail-closed on zero extracted needles omits candidates and explains reason'
  else
    bad "SB fail-closed zero needles failed (rc=${cand_rc} out=${cand_out})"
  fi

  # Let the caller detect removal of this whole body, not just missing calls.
  SKILL_BYTE_CASES_REACHED=1
}
