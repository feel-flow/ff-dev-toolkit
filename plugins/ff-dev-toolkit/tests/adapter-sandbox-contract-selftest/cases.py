"""Run the real suite entry with isolated Git fixtures and an early mktemp fence."""

import os
from pathlib import Path
import shlex
import shutil
import subprocess
import sys
import tempfile
from contextlib import ExitStack

EXPECTED_CASES = 27
GIT_TIMEOUT_SECONDS = 30
CASE_TIMEOUT_SECONDS = 10


def required(path):
    path = Path(path).resolve(strict=True)
    if not path.is_file() or not path.stat().st_mode & 0o444 or not path.read_bytes():
        raise ValueError(f"必須入力が空・読めません: {path}")
    return path


def script(path, body):
    path.write_text("#!/bin/bash\nset -eu\n" + body)
    path.chmod(0o755)


def clean_env():
    inherited = {"CASE_RAW_SET", "CASE_RAW", "CASE_CALLS", "BASH_ENV", "ENV"}
    env = {k: v for k, v in os.environ.items() if not k.startswith("GIT_") and k not in inherited}
    env.update(GIT_CONFIG_GLOBAL=os.devnull, GIT_CONFIG_NOSYSTEM="1")
    return env


def resources():
    source, helper = (required(p) for p in sys.argv[1:])
    git = shutil.which("git")
    dirname = shutil.which("dirname")
    if not git or not dirname:
        raise ValueError("git / dirname が必要です")
    # Home/tmp の推測を避け、suite と同じ checkout に専用 fixture を置く。
    checkout = Path(subprocess.check_output(
        [git, "-C", str(helper.parent), "rev-parse", "--show-toplevel"],
        env=clean_env(), text=True,
    ).strip()).resolve(strict=True)
    return source, helper, git, dirname, checkout


def prepare_paths(outside, system):
    temp = outside / "temp space"
    temp.mkdir()
    # CDPATH を中和しない退行では、同名の別ディレクトリが先に選ばれる。
    (system / temp.name).mkdir()
    unrelated = outside / "unrelated"
    unrelated.mkdir()
    temp_alias = outside / "temp-alias"
    temp_alias.symlink_to(temp, target_is_directory=True)
    missing = outside / "missing"
    file_temp = outside / "file"
    file_temp.write_text("file, not directory")
    broken = outside / "broken"
    broken.symlink_to(missing, target_is_directory=True)
    denied = outside / "unreadable"
    denied.mkdir()
    denied.chmod(0)
    return dict(temp=temp, unrelated=unrelated, temp_alias=temp_alias, missing=missing, file_temp=file_temp, broken=broken, denied=denied)


def make_cases(outside, system, paths):
    cases = []
    def add(name, repo, tmp, reject=False, *, cwd=None, raw=None, nongit=False, marker=None):
        cases.append(dict(name=name, repo=repo, tmp=tmp, reject=reject,
                          cwd=cwd or outside, raw=raw, nongit=nongit, marker=marker))
    basic_cases(add, outside, system, paths)
    invalid_cases(add, outside, system, paths)
    return cases


def basic_cases(add, outside, system, paths):
    temp, unrelated, temp_alias = (paths[k] for k in ("temp", "unrelated", "temp_alias"))
    add("system-tmp", system / "repo", str(unrelated), True)
    add("system-tmp-alias", Path("/tmp") / system.name / "alias-repo", str(unrelated), True)
    add("custom-equal", temp, str(temp), True)
    add("custom-child", temp / "child", str(temp), True)
    add("custom-deep", temp / "a" / "b", str(temp), True)
    add("trailing-slash", temp / "trailing", str(temp) + "///", True)
    add("dot-segments", temp / "dot", str(temp / ".." / temp.name), True)
    add("outside", outside / "repo", str(temp))
    add("prefix-neighbor", outside / "temp space-shadow", str(temp))
    add("unset", outside / "unset-repo", None)
    add("empty", outside / "empty-repo", "")
    add("root-temp", outside / "root-repo", "/", True)
    add("temp-alias-inside", temp / "alias-child", str(temp_alias), True)
    add("temp-alias-outside", outside / "alias-outside", str(temp_alias))
    alias_in = outside / "repo-alias"
    alias_in.symlink_to(system / "repo", target_is_directory=True)
    add("raw-repo-outside-physical-inside", system / "repo", str(temp), True, raw=str(alias_in))
    alias_out = system / "outside-alias"
    alias_out.symlink_to(outside / "repo", target_is_directory=True)
    add("raw-repo-inside-physical-outside", outside / "repo", str(temp), raw=str(alias_out))
    add("relative-inside", temp / "relative", temp.name, True)
    add("relative-outside", outside / "relative-outside", temp.name)
    add("relative-parent", outside / "relative-parent", "..", True, cwd=unrelated)


def invalid_cases(add, outside, system, paths):
    temp, missing, file_temp, broken, denied = (paths[k] for k in ("temp", "missing", "file_temp", "broken", "denied"))
    add("missing-temp", outside / "missing-temp", str(missing), True, marker="一時領域を物理パスへ解決できません")
    add("file-temp", outside / "file-temp", str(file_temp), True, marker="一時領域を物理パスへ解決できません")
    add("broken-temp", outside / "broken-temp", str(broken), True, marker="一時領域を物理パスへ解決できません")
    add("unreadable-temp", outside / "unreadable-temp", str(denied), True, marker="一時領域を物理パスへ解決できません")
    add("empty-git-root", outside / "empty-root", str(temp), True, raw="", marker="Git ルートを物理パスへ解決できません")
    add("missing-git-root", outside / "missing-root", str(temp), True, raw=str(missing), marker="Git ルートを物理パスへ解決できません")
    add("failed-git-root", outside / "failed-root", str(temp), True, raw="FAIL", marker="Git ルートを物理パスへ解決できません")
    add("nongit", system / "nongit", str(temp), nongit=True)


def install_entry(case, source, helper):
    repo = case["repo"]
    repo.mkdir(parents=True, exist_ok=True)
    if not case["nongit"]:
        subprocess.run(["/bin/bash", "-c", 'set -euo pipefail; . "$1"; ff_git_fixture_init "$2"',
                        "fixture", str(helper), str(repo)], env=clean_env(), check=True,
                       capture_output=True, timeout=GIT_TIMEOUT_SECONDS)
    plugin = repo / "plugins" / "ff-dev-toolkit"
    entry = plugin / "tests" / "adapter-sandbox-contract" / "verify.sh"
    entry.parent.mkdir(parents=True, exist_ok=True)
    entry.write_bytes(source.read_bytes())
    perspective = plugin / "scripts" / "perspectives" / "review" / "code-review.md"
    perspective.parent.mkdir(parents=True, exist_ok=True)
    perspective.write_text("fixture\n")
    return entry


def make_bin(outside, number, git, dirname):
    work = outside / f"case-{number}"
    work.mkdir()
    bin_dir = work / "bin"
    bin_dir.mkdir()
    calls = work / "calls"
    calls.write_text("")
    script(bin_dir / "mktemp", 'printf "mktemp\\n" >> "$CASE_CALLS"\necho SELFTEST_MKTEMP_FENCE >&2\nexit 1\n')
    script(bin_dir / "git", 'if [ "$#" = 4 ] && [ "$3" = rev-parse ] && [ "$4" = --show-toplevel ] && [ "${CASE_RAW_SET:-0}" = 1 ]; then\n  [ "$CASE_RAW" != FAIL ] || exit 99\n  printf "%s\\n" "$CASE_RAW"\n  exit 0\nfi\nexec ' + shlex.quote(git) + ' "$@"\n')
    (bin_dir / "dirname").symlink_to(dirname)
    for cli in ("codex", "claude", "grok", "copilot"):
        script(bin_dir / cli, f'printf "{cli}\\n" >> "$CASE_CALLS"\nexit 99\n')
    return bin_dir, calls


def run_case(case, entry, bin_dir, calls, system):
    env = clean_env()
    env.pop("TMPDIR", None)
    if case["tmp"] is not None:
        env["TMPDIR"] = case["tmp"]
    env.update(PATH=str(bin_dir), CASE_CALLS=str(calls), CDPATH=str(system))
    if case["raw"] is not None:
        env.update(CASE_RAW_SET="1", CASE_RAW=case["raw"])
    result = subprocess.run(["/bin/bash", str(entry)], cwd=case["cwd"], env=env,
                            capture_output=True, text=True, timeout=CASE_TIMEOUT_SECONDS)
    return result


def check_result(case, result, calls):
    output = result.stdout + result.stderr
    actual_calls = calls.read_text().splitlines()
    if case["nongit"]:
        good = result.returncode == 0 and "git リポジトリ外" in output and not actual_calls
    elif case["reject"]:
        marker = case["marker"] or "Git ルートが一時領域と同一または配下です"
        good = result.returncode == 2 and "検査不成立" in output and marker in output and not actual_calls
        expected_root = "<空>" if case["raw"] in ("", "FAIL") else case["raw"] or str(case["repo"].resolve())
        good = good and expected_root in output
        if not case["marker"]:
            good = good and "physical_repo=" in output and "physical_temp=" in output
    else:
        good = result.returncode == 0 and "検査不成立" not in output
        good = good and actual_calls == ["mktemp"] and "SELFTEST_MKTEMP_FENCE" in output
    good = good and "絞り込みの前提が崩れた（親への書き込み=" not in output
    if not good:
        raise AssertionError(f"{case['name']}: rc={result.returncode} calls={actual_calls}\n{output}")
    print(f"  ✓ {case['name']}", flush=True)


def main():
    source, helper, git, dirname, checkout = resources()
    with ExitStack() as stack:
        outside = Path(stack.enter_context(tempfile.TemporaryDirectory(
            prefix=".ff-sandbox-probe.selftest-", dir=checkout,
        )))
        system = Path(stack.enter_context(tempfile.TemporaryDirectory(
            prefix="ff-sandbox-selftest-", dir="/tmp",
        )))
        paths = prepare_paths(outside, system)
        stack.callback(paths["denied"].chmod, 0o700)
        cases = make_cases(outside, system, paths)
        if len(cases) != EXPECTED_CASES or len({c["name"] for c in cases}) != EXPECTED_CASES:
            raise ValueError("ケース集合が空・欠落・重複しています")
        for number, case in enumerate(cases):
            entry = install_entry(case, source, helper)
            bin_dir, calls = make_bin(outside, number, git, dirname)
            result = run_case(case, entry, bin_dir, calls, system)
            check_result(case, result, calls)
        print(f"adapter-sandbox-contract-selftest: {len(cases)} passed (real CLI calls: 0)")


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, AssertionError, subprocess.SubprocessError) as error:
        print(f"✗ adapter-sandbox-contract-selftest: {error}", file=sys.stderr)
        sys.exit(1)
