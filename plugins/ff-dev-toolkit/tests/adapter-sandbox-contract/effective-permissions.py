#!/usr/bin/env python3
"""Exercise real adapter entrypoints with argv/event stubs; no model or auth."""
import json
import os
from pathlib import Path
import shutil
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


if Path(sys.argv[0]).name in ("grok", "codex", "copilot", "agy"):
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
    for cli in ("grok", "codex", "copilot", "agy"):
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
               "USERPROFILE": "", "TMPDIR": str(temp), "GROK_HOME": str(home / "grok"),
               "STUB_LOG": str(log), "STUB_ARGV": str(argv_file), "NO_COLOR": "1"}
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

    home = temp / "home"
    def reset_agy():
        for d in (home / ".gemini", work / ".agents", work / ".agent", work / "_agents", work / "_agent", work / ".gemini"):
            if d.is_symlink():
                d.unlink()
            elif d.exists():
                shutil.rmtree(d)

    def invoke_agy(files=None, symlinks=None, task="explore", inline=False):
        reset_agy()
        try:
            for p, content in (files or {}).items():
                p.parent.mkdir(parents=True, exist_ok=True)
                p.write_text(content, encoding="utf-8")
            for link_path, target in (symlinks or {}).items():
                link_path.parent.mkdir(parents=True, exist_ok=True)
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_text("{}", encoding="utf-8")
                link_path.symlink_to(target)
            return invoke("antigravity", task=task, inline=inline)
        finally:
            reset_agy()

    agy_cli_cfg = home / ".gemini" / "antigravity-cli" / "settings.json"
    agy_shared_cfg = home / ".gemini" / "config" / "config.json"
    agy_ws_cfg = work / ".agents" / "settings.json"

    for task, inline in (("review", False), ("explore", False), ("implement", True)):
        result, calls = invoke_agy(task=task, inline=inline)
        args = calls[0][1] if len(calls) == 1 else []
        check(result.returncode == 0 and len(calls) == 1 and "--sandbox" in args
              and "--mode" in args and args[args.index("--mode") + 1] == "" and "--add-dir" not in args,
              "Antigravity clean read-only " + task + str(inline))

    for tp in ("request-review", "strict"):
        result, calls = invoke_agy({agy_cli_cfg: json.dumps({"toolPermission": tp})})
        check(result.returncode == 0 and len(calls) == 1, "Antigravity safe toolPermission " + tp)

    for tp in ("always-proceed", "proceed-in-sandbox", "unknown-mode"):
        result, calls = invoke_agy({agy_cli_cfg: json.dumps({"toolPermission": tp})})
        check(result.returncode != 0 and not calls, "Antigravity unsafe toolPermission refuses prelaunch " + tp)

    for rule in ("write_file(*)", "command(ls)", "unsandboxed(*)", "mcp(*)", "execute_url(*)", "download_url(*)", "future_tool(*)"):
        result, calls = invoke_agy({agy_cli_cfg: json.dumps({"permissions": {"allow": [rule]}})})
        check(result.returncode != 0 and not calls, "Antigravity unsafe allow refuses prelaunch " + rule)

    result, calls = invoke_agy({agy_cli_cfg: json.dumps({"permissions": {"allow": ["read_file(*)", "read_url(*)"]}})})
    check(result.returncode == 0 and len(calls) == 1, "Antigravity readonly allow rules pass")

    result, calls = invoke_agy({agy_cli_cfg: json.dumps({"permissions": {"allow": ["write_file(*)"], "deny": ["write_file(*)"]}})})
    check(result.returncode == 0 and len(calls) == 1, "Antigravity deny wildcard shadows allow")

    result, calls = invoke_agy({agy_cli_cfg: json.dumps({"permissions": {"allow": ["command(ls)"], "ask": ["command(*)"]}})})
    check(result.returncode == 0 and len(calls) == 1, "Antigravity ask wildcard shadows allow")

    result, calls = invoke_agy({agy_cli_cfg: json.dumps({"permissions": {"allow": ["command(*)"], "deny": ["command(rm *)"]}})})
    check(result.returncode != 0 and not calls, "Antigravity partial deny does not shadow command allow")

    result, calls = invoke_agy({agy_shared_cfg: json.dumps({"permissions": {"allow": ["command(*)"]}})})
    check(result.returncode != 0 and not calls, "Antigravity shared config command allow refuses prelaunch")

    result, calls = invoke_agy({agy_shared_cfg: json.dumps({"permissions": {"allow": ["command(*)"]}}),
                                agy_cli_cfg: json.dumps({"permissions": {"deny": ["command(*)"]}})})
    check(result.returncode == 0 and len(calls) == 1, "Antigravity shared config command allow shadowed by deny passes")

    result, calls = invoke_agy({agy_ws_cfg: json.dumps({"permissions": {"allow": ["write_file(*)"]}})})
    check(result.returncode != 0 and not calls, "Antigravity workspace .agents write_file allow refuses prelaunch")

    result, calls = invoke_agy({agy_cli_cfg: "{invalid"})
    check(result.returncode != 0 and not calls, "Antigravity malformed JSON refuses prelaunch")

    result, calls = invoke_agy({agy_cli_cfg: '{"toolPermission": "strict", "toolPermission": "strict"}'})
    check(result.returncode != 0 and not calls, "Antigravity duplicate key refuses prelaunch")

    result, calls = invoke_agy({agy_cli_cfg: '{"permissions":{"allow":["write\\u005ffile(*)"]}}'})
    check(result.returncode != 0 and not calls, "Antigravity unicode escape in allow refuses prelaunch")

    result, calls = invoke_agy(symlinks={agy_cli_cfg: temp / "symlink-target.json"})
    check(result.returncode != 0 and not calls, "Antigravity symlink settings.json refuses prelaunch")

    result, calls = invoke_agy({agy_cli_cfg: json.dumps({"toolPermission": "always-proceed"})}, task="implement", inline=False)
    args = calls[0][1] if len(calls) == 1 else []
    check(result.returncode == 0 and len(calls) == 1 and "--mode" in args and args[args.index("--mode") + 1] == "accept-edits"
          and "--add-dir" in args and "--sandbox" in args,
          "Antigravity staged implement ignores readonly boundary and passes accept-edits")

    # Project scope overlap, `.`/`..`/symlink resolution, Windows drive normalization, and parser crash guard
    proj_dir = home / ".gemini" / "config" / "projects"
    proj_match = proj_dir / "match.json"
    proj_nested = proj_dir / "group" / "nested.json"

    result, calls = invoke_agy({proj_match: json.dumps({"folders": [str(work)], "permissions": {"allow": ["write_file(*)"]}})})
    check(result.returncode != 0 and not calls, "Antigravity project matching folders write_file allow refuses prelaunch")

    result, calls = invoke_agy({proj_match: json.dumps({"folders": ["/some/other/repo"], "toolPermission": "always-proceed"})})
    check(result.returncode == 0 and len(calls) == 1, "Antigravity unrelated project folders always-proceed ignored")

    result, calls = invoke_agy({proj_match: json.dumps({"folders": ["/some/other/repo", str(work.parent)], "toolPermission": "always-proceed"})})
    check(result.returncode != 0 and not calls, "Antigravity multi-folder overlap refuses prelaunch")

    result, calls = invoke_agy({proj_match: json.dumps({"folders": [str(work.parent) + "/unrelated/../" + work.name], "toolPermission": "always-proceed"})})
    check(result.returncode != 0 and not calls, "Antigravity dotdot traversal folder refuses prelaunch")

    ws_alias = temp / "ws-alias"
    ws_alias.unlink(missing_ok=True)
    ws_alias.symlink_to(work)
    try:
        result, calls = invoke_agy({proj_match: json.dumps({"folders": [str(ws_alias)], "toolPermission": "always-proceed"})})
        check(result.returncode != 0 and not calls, "Antigravity symlink folder alias refuses prelaunch")
    finally:
        ws_alias.unlink(missing_ok=True)

    result, calls = invoke_agy({proj_match: json.dumps({"toolPermission": "always-proceed"})})
    check(result.returncode != 0 and not calls, "Antigravity project missing folders with always-proceed refuses prelaunch")

    result, calls = invoke_agy({proj_match: json.dumps({"folders": "oops", "permissions": {}})})
    check(result.returncode != 0 and not calls, "Antigravity project invalid folders with permissions refuses prelaunch")

    result, calls = invoke_agy({proj_nested: json.dumps({"folders": [str(work)], "permissions": {"allow": ["command(*)"]}})})
    check(result.returncode != 0 and not calls, "Antigravity nested project subdir command allow refuses prelaunch")

    deep_json = '{"toolPermission":"always-proceed","deep":' + ("[" * 50000) + "0" + ("]" * 50000) + "}"
    result, calls = invoke_agy({agy_cli_cfg: deep_json})
    check(result.returncode != 0 and not calls, "Antigravity deeply nested valid JSON refuses fail-closed")

    lib_path = Path(__file__).resolve().parents[2] / "scripts" / "lib" / "antigravity-cli-readonly-boundary.sh"
    probe_cmd = (
        f'. "{lib_path}" && '
        '_ff_agy_folder_overlaps "C:\\\\winhome\\\\fixture\\\\repo" "/c/winhome/fixture/repo" "/c/winhome/fixture/repo" "" && '
        '! _ff_agy_folder_overlaps "C:\\\\winhome\\\\fixture\\\\other" "/c/winhome/fixture/repo" "/c/winhome/fixture/repo" "" && '
        f'HOME="{home}" && mkdir -p "$HOME/.gemini/antigravity-cli" && echo "{{}}" > "$HOME/.gemini/antigravity-cli/settings.json" && '
        '_ff_agy_parse_json_file() { return 0; } && '
        'out1=$(ff_antigravity_readonly_preflight "' + str(work) + '"); rc1=$?; '
        '[ "$rc1" -ne 0 ] && [[ "$out1" == json_parse_incomplete:* ]] && '
        '_ff_agy_parse_json_file() { echo "PARSED_OK"; return 2; } && '
        'out2=$(ff_antigravity_readonly_preflight "' + str(work) + '"); rc2=$?; '
        '[ "$rc2" -ne 0 ] && [[ "$out2" == json_parse_failed:* ]] && '
        '_ff_agy_parse_json_file() { echo "PARSED_OK"; return 0; } && '
        'out3=$(ff_antigravity_readonly_preflight "' + str(work) + '") && [ "$out3" = "confirmed" ]'
    )
    probe_res = subprocess.run(["bash", "-c", probe_cmd], capture_output=True, text=True, timeout=15)
    check(probe_res.returncode == 0, "Antigravity Windows path overlap & independent parser failure modes refuse fail-closed")

check(passed == 89, "case census is nonempty and complete")
print("effective-permissions: PASS", passed)
