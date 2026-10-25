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
  # Let the caller detect removal of this whole body, not just missing calls.
  SKILL_BYTE_CASES_REACHED=1
}
