#!/usr/bin/env bash
set -euo pipefail

script_dir="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
toolkit_root="$(cd -- "$script_dir/../../.." && pwd -P)"
skill_file="$script_dir/../SKILL.md"
recorder="$toolkit_root/scripts/record-gate-head.sh"
path_helpers="$toolkit_root/scripts/lib/abs-path.sh"
manifest="$toolkit_root/.claude-plugin/plugin.json"

invalid_toolkit() {
  printf '%s。ff-dev-toolkit更新後にこのskillを再呼び出してください。\n' "$1" >&2
  exit 2
}

if [[ -L "$toolkit_root/scripts" || ! -f "$recorder" || ! -r "$recorder" ||
      ! -s "$recorder" || -L "$recorder" ||
      -L "$toolkit_root/scripts/lib" || -L "$path_helpers" ||
      ! -f "$path_helpers" || ! -r "$path_helpers" ]]; then
  invalid_toolkit '品質ゲートの記録器を確認できません'
fi

path_kind() (
  # shellcheck source=../../../scripts/lib/abs-path.sh
  . "$path_helpers" && declare -F ff_path_is_absolute >/dev/null || exit 2
  if ff_path_is_absolute "$1"; then
    printf '%s\n' absolute
  else
    printf '%s\n' relative
  fi
)

host_handoff=no
for host_root in "${CLAUDE_PLUGIN_ROOT:-}" "${GROK_PLUGIN_ROOT:-}"; do
  [[ -n "$host_root" ]] || continue
  if [[ "$(path_kind "$host_root")" != absolute ]] ||
     ! resolved_host_root="$(cd -P -- "$host_root" 2>/dev/null && pwd -P)" ||
     [[ "$resolved_host_root" != "$toolkit_root" ]]; then
    invalid_toolkit 'ホストが指定した実体と読み込んだスキルが一致しません'
  fi
  host_handoff=yes
done

loaded_skill="${FF_DEV_TOOLKIT_SKILL_FILE:-}"
if [[ -z "$loaded_skill" && "$host_handoff" == yes ]]; then
  loaded_skill="$toolkit_root/skills/verify-gate/SKILL.md"
fi
if [[ "$(path_kind "$loaded_skill")" != absolute ]] ||
   [[ -L "$loaded_skill" || ! -f "$skill_file" ||
      ! -r "$skill_file" || ! -s "$skill_file" || ! "$loaded_skill" -ef "$skill_file" ]]; then
  invalid_toolkit '読み込んだ品質ゲートスキルの実体を確認できません'
fi

if [[ -L "$toolkit_root/.claude-plugin" || -L "$manifest" ||
      ! -f "$manifest" || ! -r "$manifest" ]]; then
  invalid_toolkit 'ff-dev-toolkitのマニフェストを確認できません'
fi
if ! command -v perl >/dev/null 2>&1; then
  printf '%s\n' '品質ゲートの起動には Perl が必要です。Perl を利用できるシェルで再実行してください。' >&2
  exit 2
fi
if ! perl -MJSON::PP -0777 -e '
  my $manifest = eval { decode_json(<STDIN>) };
  exit !(ref($manifest) eq "HASH" && ($manifest->{name} // "") eq "ff-dev-toolkit");
' < "$manifest" 2>/dev/null; then
  invalid_toolkit 'ff-dev-toolkitのマニフェストを確認できません'
fi

export FF_DEV_TOOLKIT_ROOT="$toolkit_root"
export FF_DEV_TOOLKIT_SKILL_FILE="$loaded_skill"
if ! record_path="$(bash "$recorder" --print-path)" || [[ -z "$record_path" ]]; then
  invalid_toolkit '品質ゲートの記録先を確認できません'
fi
case "$(path_kind "$record_path")" in
  absolute) ;;
  relative) record_path="$(pwd -P)/$record_path" ;;
  *) invalid_toolkit '品質ゲートの記録先を判定する処理を確認できません' ;;
esac

probe_recorder() (
  git_env_names="$(git rev-parse --local-env-vars)" || exit 2
  while IFS= read -r git_env_name; do
    unset "$git_env_name"
  done <<< "$git_env_names"
  unset CDPATH FF_GATE_RECORD_FILE
  unset GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL GIT_AUTHOR_DATE
  unset GIT_COMMITTER_NAME GIT_COMMITTER_EMAIL GIT_COMMITTER_DATE
  export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null

  probe_dir="$(mktemp -d)" || exit 2
  probe_dir="$(cd -P -- "$probe_dir" && pwd -P)" || exit 2
  cleanup_probe() {
    cd -- "$probe_dir/.." && rm -rf -- "$probe_dir" || exit 2
    exit "$1"
  }
  trap 'cleanup_probe "$?"' EXIT

  probe_repo="$probe_dir/repo"
  git init -q --template= "$probe_repo" && cd -P -- "$probe_repo" || exit 2
  probe_git_dir="$(git rev-parse --absolute-git-dir)" || exit 2
  [[ "$(cd -P -- "$probe_git_dir" && pwd -P)" == "$probe_repo/.git" ]] || exit 2
  probe_record="$probe_repo/.git/ff-dev-toolkit/gate-record"
  git -c user.name=ff-dev-toolkit -c user.email=verify-gate@example.invalid \
    -c core.hooksPath=/dev/null -c commit.gpgSign=false \
    commit --allow-empty --quiet -m 'verify-gate recorder probe' || exit 2
  probe_head="$(git rev-parse HEAD)" || exit 2
  check_probe_record() {
    bash "$recorder" --gate verify-gate --status partial --mode selected \
      --suites diff --result preflight --expect-head "$probe_head" &&
      [[ -f "$probe_record" ]] &&
      grep -Fxq 'RECORD_VERSION=1' "$probe_record" &&
      grep -Fxq "COMMIT=$probe_head" "$probe_record" &&
      grep -Fxq "DIRTY=$1" "$probe_record" &&
      grep -Fxq 'STATUS=partial' "$probe_record" &&
      grep -Fxq 'SUITES=diff' "$probe_record"
  }
  check_probe_record no &&
    git config --local status.showUntrackedFiles no &&
    : > untracked &&
    check_probe_record yes
)
if ! probe_recorder; then
  invalid_toolkit '品質ゲートに対応する記録器を確認できません'
fi

# Preserve the gate's output and exit code while exposing the prior record for comparison.
record_before=missing
if [[ -e "$record_path" ]]; then
  record_before=unreadable
  if [[ -f "$record_path" && -r "$record_path" ]] &&
     record_metadata="$(LC_ALL=C TZ=UTC stat -c '%i %y %z' -- "$record_path" 2>/dev/null ||
                        LC_ALL=C TZ=UTC stat -f '%i %.9Fm %.9Fc' -- "$record_path" 2>/dev/null)" &&
     record_checksum="$(cksum < "$record_path")"; then
    record_before="$record_metadata | $record_checksum"
  fi
fi
printf 'GATE_RECORD_PATH=%s\nGATE_RECORD_BEFORE=%s\n' "$record_path" "$record_before" >&2
start_dirty=unverified
if start_status="$(git status --porcelain --untracked-files=normal 2>/dev/null)"; then
  if [[ -n "$start_status" ]]; then
    start_dirty=yes
  else
    start_dirty=no
  fi
fi
printf 'GATE_RECORD_START_DIRTY=%s\n' "$start_dirty" >&2

exec pnpm verify:gate "$@"
