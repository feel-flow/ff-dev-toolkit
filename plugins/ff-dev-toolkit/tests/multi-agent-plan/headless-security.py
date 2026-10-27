#!/usr/bin/env python3
"""headless-security: execute isolated plans and the actual recovery commands, with no real AI CLI."""
import hashlib
import os
from pathlib import Path
import shlex
import shutil
import stat
import subprocess
import sys
import tempfile

root = Path(sys.argv[1]).resolve()
runner = root / "scripts/multi-agent.sh"
for name in ["multi-agent.sh", "lib/multi-agent-plan.sh", "lib/multi-agent-advice.sh"]:
    source = root / "scripts" / name
    assert source.is_file() and os.access(source, os.R_OK) and source.stat().st_size, name
passed = 0


def check(condition, message):
    global passed
    assert condition, message
    passed += 1
    print("  ✓ headless-security " + message, flush=True)


def snapshot(directory):
    return {
        str(p.relative_to(directory)): (
            stat.S_IMODE(p.lstat().st_mode),
            os.readlink(p) if p.is_symlink() else hashlib.sha256(p.read_bytes()).hexdigest()
            if p.is_file() else "directory",
        )
        for p in directory.rglob("*")
    }


def original_snapshot(directory):
    return {k: v for k, v in snapshot(directory).items()
            if not Path(k).parts[0].startswith(".recovery-")}


with tempfile.TemporaryDirectory(prefix="ff-2281-") as temp:
    work = Path(temp)
    repo, bins, home, tools = (work / n for n in ["repo", "bin", "home", "tools"])
    for d in [repo, bins, home, tools]:
        d.mkdir()
    yq = shutil.which("yq")
    assert yq, "yq is required for the real config exclusion path"
    (tools / "yq").symlink_to(Path(yq).resolve())
    env = {"PATH": str(bins) + ":" + str(tools) + ":/usr/bin:/bin:/usr/sbin:/sbin", "HOME": str(home),
           "LANG": "ja_JP.UTF-8", "LC_ALL": "ja_JP.UTF-8", "TMPDIR": str(work),
           "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null",
           "FF_DEV_TOOLKIT_ROOT": str(root), "NO_COLOR": "1"}
    # Use the existing fixture identity helper; every child inherits only this isolated env.
    init = '. "$1"; ff_git_fixture_init "$2" "ff-2281" "test@example.com"; git -C "$2" checkout -qb develop; printf base > "$2/app"; git -C "$2" add app; git -C "$2" -c commit.gpgsign=false commit -qm base; git -C "$2" checkout -qb feature/test; printf change > "$2/app"'
    subprocess.run(["bash", "-euc", init, "fixture", str(root / "tests/lib/git-fixture.sh"), str(repo)], env=env, check=True, capture_output=True)
    valid = "## Fixture Review\n\nFixture result.\n\n### Summary\n- Critical: 0\n- verdict: none\n"
    stub = '''#!/bin/bash
for a in "$@"; do
  if [[ "$a" == --help ]]; then echo '  -C, --cd <DIR>'; exit 0; fi
done
if [[ -n "${STUB_FAIL_ONCE:-}" && -f "$STUB_FAIL_ONCE" && "${0##*/}" == "${STUB_FAIL_CLI:-codex}" ]]; then
  rm "$STUB_FAIL_ONCE"
  case "${STUB_FAIL_KIND:-permission}" in
    permission) echo 'permission required: headless run cannot ask for approval' >&2; exit 1 ;;
    empty) exit 0 ;;
    timeout) exit 124 ;;
    billing) echo 'credit balance is too low' >&2; exit 1 ;;
  esac
fi
if [[ "${0##*/}" == grok ]]; then
  profile=""
  previous=""
  for a in "$@"; do
    [[ "$previous" != --sandbox ]] || profile="$a"
    previous="$a"
  done
  mkdir -p "$HOME/.grok/sessions"
  printf '{"event_type":"ProfileApplied","profile":"%s","enforced":true,"workspace":"%s"}\\n' \\
    "$profile" "$(pwd -P)" >> "$HOME/.grok/sessions/sandbox-events.jsonl"
fi
cat >/dev/null
printf '%s\\n' '## Fixture Review' '' 'Fixture result.' '' '### Summary' '- Critical: 0' '- verdict: none'
'''

    def install(names):
        for p in bins.iterdir():
            p.unlink()
        for name in names:
            p = bins / name
            p.write_text(stub)
            p.chmod(0o755)

    def run(args, extra=None, command=None):
        result = subprocess.run(command or ["bash", str(runner), "--task", "review", "--mode", "distributed", "--base", "develop", *args],
                                cwd=repo, env={**env, **(extra or {})}, text=True,
                                stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=90)
        return result.returncode, result.stdout

    def tasks(log):
        cli, result = None, []
        for line in log.splitlines():
            if line.startswith("   ") and " [" in line and line.endswith(":"):
                cli = line.strip().split()[0]
            elif line.startswith("     - "):
                result.append((cli, line[len("     - "):]))
        return result

    plan_src = (root / "scripts/lib/multi-agent-plan.sh").read_text()
    marker = "headless-unreliable-review-perspectives"
    start = plan_src.find("# " + marker + ": start")
    end = plan_src.find("# " + marker + ": end")
    check(start != -1 and end > start, "plan-time roster is marked in one place")
    roster_block = plan_src[start:end]
    roster_echo = [line for line in roster_block.splitlines() if "echo \"" in line]
    check(len(roster_echo) == 1, "plan-time roster has exactly one echo list")
    source_roster = tuple(roster_echo[0].split("echo \"", 1)[1].rstrip("\"").split())
    expected_roster = ("error-handler-hunt", "security-analysis")
    check(source_roster == expected_roster,
          "plan-time roster is the command-requiring hunting perspectives")
    # Expected tuples are independent of registry ownership. Empty/no-roster plans fail.
    cases = [
        ("default", ["codex", "claude", "grok"], [], "codex-cli", 0),
        ("minimize", ["codex", "claude", "grok"], ["--strategy", "minimize_cost"], "codex-cli", 0),
        ("fallback", ["claude", "grok"], [], "claude-code", 0),
        ("only-grok", ["grok"], [], None, 1),
        ("explicit-grok", ["codex", "claude", "grok"], ["--cli", "grok-cli"], None, 1),
        ("filtered-fallback", ["codex", "claude", "grok"], ["--cli", "grok-cli", "--cli", "claude-code"], "claude-code", 0),
        ("excluded-codex", ["codex", "claude", "grok"], ["--exclude-cli", "codex-cli"], "claude-code", 0),
        ("excluded-alternatives", ["codex", "claude", "grok"], ["--exclude-cli", "codex-cli", "--exclude-cli", "claude-code"], None, 1),
        ("native-grok", ["grok"], ["--cli", "grok-cli", "--delegate-to-host=grok-cli"], "grok-cli", 0),
    ]
    required_cases = {"default", "minimize", "fallback", "only-grok", "explicit-grok",
                      "filtered-fallback", "excluded-codex", "excluded-alternatives", "native-grok"}
    check({case[0] for case in cases} == required_cases and len(cases) == len(required_cases),
          "planner input cases contain every required scenario exactly once")
    roster_filter = ",".join(expected_roster + ("type-design-analysis", "test-analysis"))
    for name, names, args, owner, expected_rc in cases:
        install(names)
        rc, log = run(["--dry-run", "--perspective", roster_filter, *args])
        check(rc == expected_rc, name + " rc=" + str(rc) + "\n" + log if rc != expected_rc else name + " status")
        if owner:
            for persp in expected_roster:
                assigned = [(c, p) for c, p in tasks(log) if p == persp]
                check(assigned == [(owner, persp)], name + " " + persp + " is assigned exactly once")
            if owner != "grok-cli":
                check("headless" in log and "grok-cli" in log, name + " discloses the reason")
        else:
            check("headless" in log and "unsupported on headless grok-cli" in log and "--cli" in log
                  and any(p in log for p in expected_roster),
                  name + " diagnoses an unsupported plan with an alternative")
    install(["codex", "claude", "grok"])
    for persp in expected_roster:
        rc, log = run(["--dry-run", "--perspective", persp])
        assigned = [(c, p) for c, p in tasks(log) if p == persp]
        check(rc == 0 and assigned == [("codex-cli", persp)] and "plan-time alternative" in log,
              persp + " dry-run shows the plan-time alternative")
    install(["grok"])
    rc, log = run(["--dry-run", "--perspective", "comment-analysis"])
    check(rc == 0 and ("grok-cli", "comment-analysis") in tasks(log),
          "non-roster Grok perspectives remain available")
    rc, log = run(["--dry-run", "--perspective", "code-review"])
    check(rc == 0 and ("grok-cli", "code-review") in tasks(log),
          "non-roster fallback onto grok-cli is not reassigned")
    exclude_args = []
    for persp in expected_roster:
        exclude_args += ["--exclude-perspective", persp]
    rc, log = run(["--dry-run", *exclude_args])
    check(rc == 0 and tasks(log) and all(p not in expected_roster for _, p in tasks(log)),
          "explicit exclusion of the whole roster remains valid")
    rc, log = run(["--dry-run", "--exclude-perspective", "security-analysis"])
    check(rc != 0 and "error-handler-hunt" in log and "unsupported on headless grok-cli" in log,
          "excluding only security-analysis still diagnoses error-handler-hunt")
    config = repo / "exclude.yaml"
    config.write_text('version: "2.0"\nexclude_clis: "codex-cli"\n')
    install(["codex", "claude", "grok"])
    for persp in expected_roster:
        rc, log = run(["--dry-run", "--config", str(config), "--perspective", persp])
        check(rc == 0 and [(c, p) for c, p in tasks(log) if p == persp] == [("claude-code", persp)],
              "config exclusion also constrains plan-time alternatives for " + persp)
    install(["codex", "grok"])
    for persp in expected_roster:
        for mode in ["pair", "cross-model"]:
            rc, log = run(["--dry-run", "--mode", mode, "--perspective", persp],
                          {"MULTI_AGENT_REVIEW_MAIN": "grok-cli", "MULTI_AGENT_REVIEW_SUB": "codex-cli"})
            check(rc == 0 and ("grok-cli", persp) in tasks(log),
                  mode + " explicit model selection is not silently replaced for " + persp)

    # Advice must not offer the headless Grok/roster combination rejected by the plan.
    # Keep Grok substitutes for unrelated perspectives and supported roster substitutes.
    advice_cases = {}
    for persp in expected_roster:
        advice_cases["codex-" + persp] = (["codex", "grok"], "codex", "codex-cli", persp, None)
        advice_cases["claude-" + persp] = (["claude", "grok"], "claude", "claude-code", persp, None)
        advice_cases["supported-" + persp] = (["codex", "claude", "grok"], "codex", "codex-cli", persp, "claude-code")
    advice_cases["other-perspective"] = (["codex", "grok"], "codex", "codex-cli", "code-review", "grok-cli")
    required_advice = {"other-perspective"}
    for persp in expected_roster:
        required_advice.update({"codex-" + persp, "claude-" + persp, "supported-" + persp})
    check(set(advice_cases) == required_advice,
          "advice input cases include supported, unsupported and unrelated combinations")
    for index, (names, binary, cli, perspective, substitute) in enumerate(advice_cases.values()):
        install(names)
        once = work / ("advice-once-" + str(index))
        once.touch()
        out = repo / ("advice-" + str(index))
        rc, log = run(["--sequential", "--perspective", perspective, "--output-dir", str(out)],
                      {"STUB_FAIL_ONCE": str(once), "STUB_FAIL_CLI": binary})
        check(rc != 0 and (out / cli / (perspective + ".md")).is_file(), "substitute fixture reaches its failed lane")
        commands = [line.strip() for line in log.splitlines()
                    if line.startswith("       ") and " --cli " in line and "multi-agent.sh" in line]
        destinations = [shlex.split(command)[shlex.split(command).index("--cli") + 1] for command in commands]
        check(destinations == [cli] + ([substitute] if substitute else []),
              "advice offers exactly the supported retry and substitute: " + str(destinations))
        before = original_snapshot(out)
        for command in commands:
            rc, recovered = run([], command=["bash", "-c", command])
            check(rc == 0 and original_snapshot(out) == before,
                  "every advertised substitute command executes and preserves the original\n" + recovered if rc else "advertised command executes and preserves the original")

    # Real orchestrator -> real advice -> execute the displayed commands. The CLI stubs
    # fail once and return a typed review thereafter; no production CLI is on PATH.
    install(["codex", "claude"])
    recovery_cases = {
        "default-permission": (False, False, "permission"),
        "explicit-empty": (True, False, "empty"),
        "explicit-timeout": (True, False, "timeout"),
        "pending-delegation": (True, True, "permission"),
    }
    check(set(recovery_cases) == {"default-permission", "explicit-empty", "explicit-timeout", "pending-delegation"},
          "recovery inputs contain every required failure scenario")
    for index, (explicit, delegated, failure) in enumerate(recovery_cases.values()):
        out = repo / ("出力 'quoted' " + str(index)) if explicit else repo / ".review-results"
        once = work / ("fail-once-" + str(index))
        once.touch()
        args = ["--sequential", "--timeout", "3", "--cli", "codex-cli",
                "--perspective", "code-review,test-analysis", "--description", "境界 'quoted' $(touch NEVER_EXECUTE)"]
        if explicit:
            args += ["--output-dir", str(out)]
        if delegated:
            args += ["--cli", "claude-code", "--perspective", "type-design-analysis", "--delegate-to-host"]
        rc, log = run(args, {"STUB_FAIL_ONCE": str(once), "STUB_FAIL_KIND": failure})
        check(rc != 0 and (out / "codex-cli/test-analysis.md").is_file()
              and "Status: complete" in (out / "codex-cli/test-analysis.md").read_text(),
              "recovery fixture has a failed lane and a genuinely completed sibling " + str(index))
        check((out / "integrated-report.md").is_file()
              and any(p.is_file() for p in (out / ".resume-cache").rglob("*")),
              "recovery fixture contains a real report and cache")
        if delegated:
            requests = list(out.glob("claude-code/.delegated/generations/*/*.request"))
            check(requests and all(not p.with_name(p.name.replace(".request", ".response.md")).exists() for p in requests),
                  "original round genuinely contains pending delegated requests")
        (repo / ".gitignore").write_text(".review-results/\n出力*/\n委譲*/\n")
        before = original_snapshot(out)
        commands = [line.strip() for line in log.splitlines()
                    if line.startswith("       ") and " --cli " in line and "multi-agent.sh" in line
                    and "--delegate-to-host" not in line]
        check(len(commands) >= 2, "same/substitute recovery commands were emitted " + str(index))
        recoveries = {}
        for command in commands:
            argv = shlex.split(command)
            check("--output-dir" in argv, "every recovery command explicitly selects a fresh output")
            recovery = Path(argv[argv.index("--output-dir") + 1])
            check(recovery.parent.resolve() == out.resolve() and recovery.name.startswith(".recovery-")
                  and not recovery.exists(), "recovery output is an unused hidden child")
            ignored = subprocess.run(["git", "check-ignore", "-q", str(recovery / "result")], cwd=repo, env=env)
            check(ignored.returncode == 0, "recovery stays inside the original ignore boundary")
            recovered_rc, recovered_log = run([], command=["bash", "-c", command])
            check(recovered_rc == 0, "displayed recovery executes successfully\n" + recovered_log if recovered_rc else "displayed recovery executes successfully")
            check(original_snapshot(out) == before, "all original paths/modes/bytes including cache/report/delegation are unchanged")
            check((recovery / "integrated-report.md").is_file(), "recovery result is stored separately")
            for previous, saved in recoveries.items():
                check(snapshot(previous) == saved, "consecutive commands preserve every earlier recovery artifact")
            recoveries[recovery] = snapshot(recovery)
        check(len(recoveries) == len(commands), "each independent command has a distinct recovery output")
        rc, resumed = run([*args, "--resume"], {"GLOBIGNORE": "unmatched-fixture-name"})
        check(rc == (3 if delegated else 0) and "📄 Report:" in resumed
              and "Status: complete" in (out / "codex-cli/code-review.md").read_text(),
              "original resume reaches report generation and completes its failed CLI lane\n" + resumed)
        check(all(snapshot(d) == saved for d, saved in recoveries.items()),
              "original resume leaves hidden recovery artifacts untouched")
        check(not any(d.name + "/" in line for d in recoveries for line in resumed.splitlines()
                      if "Not part of this run" in line), "hidden recovery directories are not reported as unplanned CLI results")
        check(not (repo / "NEVER_EXECUTE").exists(), "description survives shell quoting without execution")

    # Billing advice in a Claude host must preserve the original round across
    # the printed handoff + identical-argv resume pair, not just a single retry.
    out = repo / "委譲 'original'"
    once = work / "billing-once"
    once.touch()
    extra = {"STUB_FAIL_ONCE": str(once), "STUB_FAIL_CLI": "claude", "STUB_FAIL_KIND": "billing", "CLAUDECODE": "1"}
    rc, log = run(["--sequential", "--cli", "claude-code", "--cli", "codex-cli", "--perspective", "type-design-analysis,test-analysis", "--output-dir", str(out)], extra)
    check(rc != 0 and "Status: complete" in (out / "codex-cli/test-analysis.md").read_text(), "native recovery fixture has a completed sibling")
    before = original_snapshot(out)
    commands = [line.strip() for line in log.splitlines() if line.startswith("       ") and "multi-agent.sh" in line and " --cli " in line and "--delegate-to-host" in line]
    check(len(commands) == 2 and shlex.split(commands[1]) == shlex.split(commands[0]) + ["--resume"], "native recovery retains the exact initial argv plus resume" + ("\n" + log if len(commands) != 2 else ""))
    argv = shlex.split(commands[0])
    recovery = Path(argv[argv.index("--output-dir") + 1])
    check(recovery.parent.resolve() == out.resolve() and recovery.name.startswith(".recovery-")
          and not recovery.exists(), "native recovery selects an unused hidden child")
    ignored = subprocess.run(["git", "check-ignore", "-q", str(recovery / "result")], cwd=repo, env=env)
    check(ignored.returncode == 0, "native recovery stays inside the original ignore boundary")
    rc, handoff = run([], extra, command=["bash", "-c", commands[0]])
    check(rc == 3 and original_snapshot(out) == before, "handoff preserves every original artifact")
    requests = list(recovery.glob("claude-code/.delegated/generations/*/*.request"))
    check(len(requests) == 1, "native recovery creates its own request generation")
    requests[0].with_name(requests[0].name.replace(".request", ".response.md")).write_text(valid)
    rc, result = run([], extra, command=["bash", "-c", commands[1]])
    check(rc == 0 and original_snapshot(out) == before, "native resume accepts the new response without changing the original round\n" + result if rc else "native resume preserves the original round")
    print("headless-security contract verified")
    print("headless-security checks passed:", passed)
