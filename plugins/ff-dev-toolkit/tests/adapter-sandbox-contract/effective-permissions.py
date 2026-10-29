#!/usr/bin/env python3
"""Exercise real adapter entrypoints with argv/event stubs; no model or auth."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile


def stub(cli):
    args = sys.argv[1:]
    log = Path(os.environ["STUB_LOG"])
    with log.open("a") as f:
        f.write(json.dumps([cli, args]) + "\n")
    if cli == "codex":
        if args[:2] == ["exec", "--help"]:
            print("-C, --cd <DIR>\n--sandbox <SANDBOX_MODE>\n--add-dir <DIR>")
            return
        Path(os.environ["STUB_ARGV"]).write_bytes(b"\0".join(a.encode() for a in args))
    if cli == "copilot" and args == ["help", "permissions"]:
        if os.environ.get("STUB_UNSUPPORTED") != "true":
            print("--deny-tool --disallow-temp-dir\nDenial rules always take precedence over allow rules")
        return
    if cli == "grok":
        inspect = "inspect" in args
        home = Path(os.environ["GROK_HOME"])
        home.mkdir(parents=True, exist_ok=True)
        event = {"event_type": "ProfileApplied", "profile": args[args.index("--sandbox") + 1],
                 "workspace": str(Path.cwd()), "enforced": True}
        grants = os.environ.get("STUB_GRANTS", json.dumps([str(home), "/tmp"]))
        if not inspect:
            grants = os.environ.get("STUB_POST_GRANTS", grants)
            event["event_type"] = os.environ.get("STUB_POST_EVENT", "ProfileApplied")
        if grants not in ("missing", "no-events"):
            event["read_write_paths"] = json.loads(grants)
        if grants != "no-events":
            with (home / "sandbox-events.jsonl").open("a") as f:
                f.write(json.dumps(event, separators=(",", ":"), ensure_ascii=False) + "\n")
                if os.environ.get("STUB_EXTRA_GRANTS"):
                    event["read_write_paths"] = json.loads(os.environ["STUB_EXTRA_GRANTS"])
                    f.write(json.dumps(event, separators=(",", ":")) + "\n")
    print("- Suggestion: fixture output\n  - verdict: severity=suggestion failure_scenario=no confidence=50")


if Path(sys.argv[0]).name in ("grok", "codex", "copilot"):
    stub(Path(sys.argv[0]).name)
    sys.exit(0)

plugin = Path(__file__).resolve().parents[2]
repo = plugin.parents[1]
adapters = Path(sys.argv[1]) if len(sys.argv) == 2 else plugin / "scripts/adapters"
assert adapters.is_dir(), "adapter directory is missing"
passed = 0


def check(condition, label):
    global passed
    if not condition:
        raise AssertionError(label)
    passed += 1
    print("  PASS effective-permissions:", label, flush=True)


with tempfile.TemporaryDirectory(prefix=".ff-sandbox-probe.", dir=repo) as normal, tempfile.TemporaryDirectory(prefix="ff-effective-") as temp:
    normal = Path(normal).resolve()
    temp = Path(temp).resolve()
    subprocess.run(["git", "init", "-q", str(temp)], check=True)
    bin_dir = temp / "bin"
    bin_dir.mkdir()
    for cli in ("grok", "codex", "copilot"):
        (bin_dir / cli).symlink_to(Path(__file__).resolve())
    perspective = temp / "review.md"
    perspective.write_text("# Fixture\nReview this fixture only.\n")
    work = normal / "repo"
    work.mkdir()
    subprocess.run(["git", "init", "-q", str(work)], check=True)
    (work / "input.txt").write_text("before\n")
    subprocess.run(["git", "-C", str(work), "add", "input.txt"], check=True)
    subprocess.run(["git", "-C", str(work), "-c", "user.name=fixture", "-c", "user.email=fixture@example.invalid", "commit", "-qm", "fixture"], check=True)
    (work / "input.txt").write_text("after\n")
    log = temp / "calls.jsonl"
    argv_file = temp / "argv.bin"

    def invoke(cli, task="explore", inline=False, cwd=work, staging=None, **overrides):
        log.write_text("")
        argv_file.unlink(missing_ok=True)
        home = temp / "home"
        home.mkdir(exist_ok=True)
        env = {"PATH": str(bin_dir) + os.pathsep + os.environ["PATH"], "HOME": str(home),
               "TMPDIR": str(temp), "GROK_HOME": str(home / "grok"), "STUB_LOG": str(log),
               "STUB_ARGV": str(argv_file), "NO_COLOR": "1"}
        env.update(overrides)
        args = ["bash", str(adapters / (cli + "-cli-adapter.sh")), str(perspective), str(temp / "out.md"),
                "--base", "HEAD", "--task-type", task, "--description", "fixture", "--timeout", "15"]
        if inline:
            args += ["--inline-output"]
        elif task == "implement":
            staging = staging or work / "staging"
            staging.mkdir(parents=True, exist_ok=True)
            args += ["--staging-dir", str(staging)]
        result = subprocess.run(args, cwd=cwd, env=env, capture_output=True, text=True, timeout=30)
        calls = [json.loads(line) for line in log.read_text().splitlines()]
        return result, calls

    for profile in ("read-only", "fixture-custom"):
        settings = {} if profile == "read-only" else {"MULTI_AGENT_GROK_READONLY_PROFILE": profile}
        result, calls = invoke("grok", **settings)
        check(result.returncode == 0 and sum("--prompt-file" in a for _, a in calls) == 1, profile + " ordinary checkout succeeds")
        for grants in ([str(work)], [str(work.parent)], [str(work / "src")], ["/"], [], [None], ["relative"], "missing", "no-events"):
            encoded = grants if isinstance(grants, str) else json.dumps(grants)
            result, calls = invoke("grok", STUB_GRANTS=encoded, **settings)
            check(result.returncode != 0 and not any("--prompt-file" in a for _, a in calls), profile + " refuses prelaunch grants " + repr(grants))
        result, calls = invoke("grok", STUB_POST_GRANTS=json.dumps([str(work)]), **settings)
        check(result.returncode != 0 and any("--prompt-file" in a for _, a in calls), profile + " post-launch widening is rejected")
        result, calls = invoke("grok", STUB_EXTRA_GRANTS=json.dumps([str(work)]), **settings)
        check(result.returncode != 0 and not any("--prompt-file" in a for _, a in calls), profile + " checks every matching applied event")
    alias = temp / "checkout-alias"
    alias.symlink_to(work, target_is_directory=True)
    result, calls = invoke("grok", STUB_GRANTS=json.dumps([str(alias)]))
    check(result.returncode != 0 and not any("--prompt-file" in a for _, a in calls), "physical symlink grant rejected prelaunch")
    for cwd, overrides in ((temp, {}), (work, {"TMPDIR": str(normal)}), (work, {"GROK_HOME": str(work / "grok")})):
        result, calls = invoke("grok", cwd=cwd, **overrides)
        check(result.returncode != 0 and not calls and "preflight refused before reviewer launch: write-granted" in result.stderr,
              "known temp/home overlap never starts CLI")
    with tempfile.TemporaryDirectory(prefix="ff-effective-", dir="/var/tmp") as var_temp:
        subprocess.run(["git", "init", "-q", var_temp], check=True)
        result, calls = invoke("grok", cwd=var_temp)
        check(result.returncode != 0 and not calls and "preflight refused before reviewer launch: write-granted" in result.stderr,
              "/var/tmp checkout never starts CLI")
    temp_alias = normal / "temp-alias"
    temp_alias.symlink_to(temp, target_is_directory=True)
    result, calls = invoke("grok", cwd=temp_alias)
    check(result.returncode != 0 and not calls and "preflight refused before reviewer launch: write-granted" in result.stderr,
          "physical temp checkout through symlink never starts CLI")
    result, calls = invoke("grok", task="implement")
    check(result.returncode == 0 and any("workspace" in a for _, a in calls), "Grok staged implement remains workspace")
    event = json.dumps({"event_type": "ProfileApplied", "profile": "read-only", "workspace": str(work),
                        "enforced": True, "read_write_paths": ["/tmp"]})
    malformed = [event[:-1], event[:-1] + ',"read_write_paths":["/tmp"]}',
                 json.dumps({"event_type": "ProfileApplied", "profile": "read-only", "workspace": str(work),
                             "enforced": True, "nested": {"read_write_paths": ["/tmp"]}})]
    for text in malformed:
        result = subprocess.run(["bash", "-c", '. "$1"; ff_grok_readonly_verdict read-only "$2"', "fixture",
                                 str(adapters.parent / "lib/grok-cli-readonly-boundary.sh"), str(work)],
                                input=text, capture_output=True, text=True, timeout=10)
        check(result.returncode != 0 or result.stdout.strip() != "confirmed", "incomplete/duplicate/nested grant evidence is unknown")

    for changes, expected in (({"enforced": False}, "unconfirmed"),
                              ({"profile": "workspace"}, "unconfirmed"),
                              ({"event_type": "ApplyFailed"}, "unconfirmed"),
                              ({"event_type": "BypassGranted"}, "unconfirmed"),
                              ({"read_write_paths": None}, "grants-unknown"),
                              ({"read_write_paths": [None]}, "grants-unknown"),
                              (None, "unconfirmed")):
        record = json.loads(event)
        if changes is not None:
            record.update(changes)
        result = subprocess.run(["bash", "-c", '. "$1"; ff_grok_readonly_verdict read-only "$2"', "fixture",
                                 str(adapters.parent / "lib/grok-cli-readonly-boundary.sh"), str(work)],
                                input=json.dumps(record) if changes is not None else "", capture_output=True, text=True, timeout=10)
        check(result.returncode == 0 and result.stdout.strip() == expected, "distinct Grok refusal reason " + repr(changes))
    result, calls = invoke("grok", task="implement", STUB_POST_EVENT="ApplyFailed")
    check(result.returncode != 0 and "did not confirm" in result.stderr and "read_write_paths array" not in result.stderr,
          "workspace application failure is not mislabeled as missing read-only grants")
    result, calls = invoke("grok", STUB_GRANTS="no-events")
    check(result.returncode != 0 and "preflight refused before reviewer launch: inert" in result.stderr,
          "prelaunch preserves model-free inspect inert reason")

    for value in ("space 日本語", "line\n--add-dir\n/outside"):
        staging = work / value
        result, calls = invoke("codex", task="implement", staging=staging)
        args = argv_file.read_bytes().split(bytes([0])) if argv_file.exists() else []
        check(result.returncode == 0 and args.count(b"-C") == 1 and args[args.index(b"-C") + 1] == str(staging).encode()
              and b"--add-dir" not in args, "Codex single staging argv " + repr(value))

    for task, inline in (("review", False), ("explore", False), ("implement", True)):
        result, calls = invoke("copilot", task=task, inline=inline)
        runs = [a for _, a in calls if a[:1] == ["-p"]]
        args = runs[0] if len(runs) == 1 else []
        check(result.returncode == 0 and args.count("--deny-tool") == 2 and "write" in args and "shell" in args
              and "--disallow-temp-dir" in args, "Copilot deny argv " + task + str(inline))
        result, calls = invoke("copilot", task=task, inline=inline, STUB_UNSUPPORTED="true")
        check(result.returncode != 0 and not any(a[:1] == ["-p"] for _, a in calls), "Copilot unknown capability refuses before model " + task)
    result, calls = invoke("copilot", task="implement")
    check(result.returncode == 0 and len(calls) == 1 and "--deny-tool" not in calls[0][1], "Copilot staged implement unchanged")

check(passed == 52, "case census is nonempty and complete")
print("effective-permissions: PASS", passed)
