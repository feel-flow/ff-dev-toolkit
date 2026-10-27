# -*- coding: utf-8 -*-
import importlib.util
import json
import os
from pathlib import Path
import signal
import stat
import subprocess
import sys
import tempfile
import time
import unittest
import uuid

SCRIPT = Path(__file__).resolve().parents[2] / "scripts/measurement/claude-measure.py"
sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location("measurement", SCRIPT)
measurement = importlib.util.module_from_spec(spec)
spec.loader.exec_module(measurement)
REPO = "example/project"


class MeasurementTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.store = self.root / "store"
        self.fake = self.root / "claude"
        self.fake.write_text('''#!/usr/bin/env python3
import json, os, subprocess, sys, time
from pathlib import Path
if "--version" in sys.argv:
    if Path(__file__).with_suffix(".slow-version").exists():
        Path(__file__).with_suffix(".version-pid").write_text(str(os.getpid()), encoding="utf-8")
        time.sleep(20)
    print("2.1.308 (Claude Code)")
    sys.exit(0)
assert "--no-session-persistence" in sys.argv
assert sys.argv[sys.argv.index("--tools")+1] == "Read,Glob,Grep"
assert sys.argv[sys.argv.index("--allowedTools")+1] == "Read,Glob,Grep"
assert "--strict-mcp-config" in sys.argv
assert json.loads(sys.argv[sys.argv.index("--mcp-config")+1]) == {"mcpServers": {}}
prompt = sys.stdin.read()
if prompt == "controls":
    assert "--safe-mode" in sys.argv
    assert sys.argv[sys.argv.index("--model")+1] == "test-model"
    assert sys.argv[sys.argv.index("--max-turns")+1] == "3"
if prompt == "sleep":
    Path(__file__).with_suffix(".pid").write_text(str(os.getpid()), encoding="utf-8")
    time.sleep(20)
if prompt == "descendant":
    code = "import signal,time; signal.signal(signal.SIGTERM, signal.SIG_IGN); time.sleep(20)"
    child = subprocess.Popen([sys.executable, "-c", code], stdout=subprocess.DEVNULL)
    Path(__file__).with_suffix(".child-pid").write_text(str(child.pid), encoding="utf-8")
    time.sleep(20)
session = sys.argv[sys.argv.index("--session-id")+1]
value = dict(type="result", subtype="success", is_error=False, session_id=session,
    result="response-secret", duration_ms=10, duration_api_ms=8, num_turns=1,
    total_cost_usd=0.25, usage=dict(input_tokens=3, output_tokens=4,
    cache_creation_input_tokens=0, cache_read_input_tokens=0, secret="source-secret"),
    modelUsage={"test-model": {}}, permission_denials=[], prompt="prompt-secret")
if prompt == "missing":
    del value["usage"]["output_tokens"]
if prompt == "denied":
    value["permission_denials"] = [dict(tool_input="source-secret")]
if prompt == "missing-denials":
    del value["permission_denials"]
if prompt == "wrong-session":
    value["session_id"] = "wrong"
if prompt == "error":
    value["is_error"] = True
if prompt == "max-turns":
    value["subtype"] = "error_max_turns"
if prompt == "stderr-only":
    print("error: unsupported CLI flag", file=sys.stderr)
    sys.exit(1)
if prompt == "malformed":
    print("not-json")
else:
    print(json.dumps(value))
if prompt == "exit-one":
    sys.exit(1)
''', encoding="utf-8")
        self.fake.chmod(0o700)

    def cli(self, command, *options, prompt="prompt-secret", expected=0):
        result = subprocess.run([sys.executable, str(SCRIPT), command, "--store", str(self.store),
                                 *options], input=prompt, text=True, capture_output=True, timeout=15)
        self.assertEqual(result.returncode, expected, result.stderr)
        return result

    def run_cli(self, prompt="prompt-secret", expected=0, *options):
        return self.cli("run", "--repo", REPO, "--issue", "1676", "--claude", str(self.fake),
                        *options, prompt=prompt, expected=expected)

    def report(self):
        return json.loads(self.cli("report", "--repo", REPO, "--issue", "1676").stdout)

    def fixture(self, left, right, issue=1676):
        identity = str(uuid.uuid4())
        directory = self.store / identity
        directory.mkdir(parents=True)
        value = dict(schema=1, run_id=identity, session_id=identity, repo=REPO, issue=issue,
                     state="success" if right is not None else "running", start_epoch=left,
                     end_epoch=right, process_seconds=right-left if right is not None else None,
                     cli_version="2.1.308 (Claude Code)", models=["test-model"])
        value.update({k: 0 for k in measurement.METRICS})
        if right is None:
            value.update({k: None for k in measurement.METRICS})
        measurement.write_json(directory / "record.json", value)
        return directory

    def test_real_process_sanitization_and_links(self):
        result = self.run_cli()
        self.assertEqual(result.stdout.strip(), "response-secret")
        records = list(self.store.glob("*/record.json"))
        self.assertEqual(len(records), 1)
        value = json.loads(records[0].read_text(encoding="utf-8"))
        self.assertEqual(value["state"], "success")
        self.assertEqual(value["input_tokens"], 3)
        self.assertEqual(stat.S_IMODE(records[0].stat().st_mode), 0o600)
        self.assertEqual(stat.S_IMODE(records[0].parent.stat().st_mode), 0o700)
        url = "https://github.com/example/project/pull/1"
        for _ in range(2):
            self.cli("link", "--run", value["run_id"], "--url", url)
        self.cli("link", "--run", value["run_id"], "--url", "https://evil.example/pull/1", expected=2)
        before = {p: p.read_bytes() for p in self.store.rglob("*.json")}
        report = self.report()
        self.assertEqual(report, self.report())
        self.assertEqual(report["artifacts"], [url])
        self.assertEqual(before, {p: p.read_bytes() for p in self.store.rglob("*.json")})
        for raw in before.values():
            for secret in (b"prompt-secret", b"response-secret", b"source-secret", b"tool_input", b"transcript"):
                self.assertNotIn(secret, raw)

    def test_sequential_gap_is_not_classified_as_wait(self):
        self.fixture(100, 110)
        self.fixture(120, 135)
        self.fixture(100, 999, issue=999)
        report = self.report()
        self.assertEqual(report["runs"], 2)
        self.assertEqual(report["cli_interval_union_seconds"], 25)
        self.assertEqual(report["elapsed_seconds"], 35)
        self.assertIsNone(report["wait_seconds"])
        self.assertIsNone(report["human_intervention_seconds"])
        self.assertIsNone(report["ai_active_seconds"])
        self.assertIsNone(report["billed_cost_usd"])

    def test_parallel_and_nested_intervals(self):
        self.fixture(100, 120)
        self.fixture(110, 130)
        self.fixture(112, 115)
        report = self.report()
        self.assertEqual(report["cli_interval_sum_seconds"], 43)
        self.assertEqual(report["cli_interval_union_seconds"], 30)
        self.assertEqual(report["elapsed_seconds"], 30)

    def test_empty_missing_and_observed_zero(self):
        self.assertEqual(self.report()["runs"], 0)
        self.assertIsNone(self.report()["cli_interval_union_seconds"])
        self.assertIsNone(self.report()["metrics"]["input_tokens"]["total"])
        self.run_cli()
        self.run_cli("missing")
        report = self.report()
        self.assertEqual(report["metrics"]["output_tokens"], dict(total=None, observed=4, missing=1))
        self.assertEqual(report["metrics"]["cache_read_input_tokens"]["total"], 0)
        self.fixture(100, None)
        report = self.report()
        self.assertEqual(report["incomplete"], 1)
        self.assertIsNone(report["cli_interval_union_seconds"])
        self.assertIsNotNone(report["observed_interval_union_seconds"])
        self.assertIsNone(report["metrics"]["cost_estimate_usd"]["total"])

    def test_error_json_and_session_mismatch(self):
        for prompt in ("malformed", "error", "denied", "wrong-session", "max-turns", "exit-one", "missing-denials"):
            self.run_cli(prompt, 1)
        report = self.report()
        self.assertEqual(report["failed"], 7)
        self.assertEqual(report["metrics"]["cost_estimate_usd"]["missing"], 2)
        records = [json.loads(p.read_text(encoding="utf-8")) for p in self.store.glob("*/record.json")]
        self.assertEqual(sum(r["state"] == "invalid_result" for r in records), 2)
        self.assertEqual(sum(r["state"] == "cli_error" for r in records), 5)
        self.assertEqual(sum(r["exit_code"] == 1 for r in records), 1)

    def test_control_flags_and_missing_clock_interval(self):
        self.run_cli("controls", 0, "--safe-mode", "--model", "test-model", "--max-turns", "3")
        record = next(self.store.glob("*/record.json"))
        value = json.loads(record.read_text(encoding="utf-8"))
        self.assertIs(value["safe_mode"], True)
        value["end_epoch"] = None
        measurement.write_json(record, value)
        report = self.report()
        self.assertEqual(report["incomplete"], 0)
        self.assertEqual(report["interval_missing"], 1)
        self.assertIsNone(report["cli_interval_union_seconds"])
        self.assertIsNotNone(report["metrics"]["process_seconds"]["total"])

    def test_actionable_diagnostics_without_storing_stderr(self):
        result = self.run_cli("stderr-only", 1)
        self.assertIn("unsupported CLI flag", result.stderr)
        for path in self.store.rglob("*.json"):
            self.assertNotIn(b"unsupported CLI flag", path.read_bytes())
        directory = self.fixture(100, 110)
        (directory / "record.json").write_text("secret broken payload", encoding="utf-8")
        result = self.cli("report", "--repo", REPO, "--issue", "1676", expected=2)
        self.assertIn(directory.name, result.stderr)
        self.assertIn("unreadable record", result.stderr)
        self.assertNotIn("secret broken payload", result.stderr)

    def test_version_probe_interrupt_does_not_publish_empty_run(self):
        self.fake.with_suffix(".slow-version").touch()
        command = [sys.executable, str(SCRIPT), "run", "--store", str(self.store), "--repo", REPO,
                   "--issue", "1676", "--claude", str(self.fake)]
        process = subprocess.Popen(command, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        try:
            process.stdin.close()
            process.stdin = None
            deadline = time.monotonic() + 5
            while not self.fake.with_suffix(".version-pid").exists():
                self.assertLess(time.monotonic(), deadline)
                time.sleep(0.01)
            self.assertEqual(self.report()["runs"], 0)
            process.send_signal(signal.SIGTERM)
            process.communicate(timeout=5)
            self.assertEqual(process.returncode, 130)
            self.assertEqual(self.report()["runs"], 0)
            with self.assertRaises(ProcessLookupError):
                os.kill(int(self.fake.with_suffix(".version-pid").read_text(encoding="utf-8")), 0)
        finally:
            if process.poll() is None:
                process.kill()
                process.communicate()

    def test_timeout_and_launch_failure(self):
        self.run_cli("sleep", 1, "--timeout", "1")
        with self.assertRaises(ProcessLookupError):
            os.kill(int(self.fake.with_suffix(".pid").read_text(encoding="utf-8")), 0)
        self.cli("run", "--repo", REPO, "--issue", "1676", "--claude", str(self.root / "absent"), expected=1)
        values = [json.loads(p.read_text(encoding="utf-8")) for p in self.store.glob("*/record.json")]
        self.assertEqual({v["state"] for v in values}, {"timeout", "launch_error"})
        self.assertTrue(all(v["end_epoch"] is not None for v in values))
        self.assertIsNone(self.report()["metrics"]["cost_estimate_usd"]["total"])

    def test_timeout_kills_descendant_even_after_stdout_eof(self):
        try:
            self.run_cli("descendant", 1, "--timeout", "1")
            child = int(self.fake.with_suffix(".child-pid").read_text(encoding="utf-8"))
            deadline = time.monotonic() + 3
            while True:
                status = subprocess.run(["ps", "-o", "stat=", "-p", str(child)],
                                        capture_output=True, text=True, timeout=2).stdout.strip()
                if not status or status.startswith("Z"):
                    break
                self.assertLess(time.monotonic(), deadline, "descendant is still running")
                time.sleep(0.01)
        finally:
            if self.fake.with_suffix(".child-pid").exists():
                child = int(self.fake.with_suffix(".child-pid").read_text(encoding="utf-8"))
                try:
                    os.kill(child, signal.SIGKILL)
                except ProcessLookupError:
                    pass

    def test_sigterm_stops_child_and_records_interruption(self):
        process = subprocess.Popen([sys.executable, str(SCRIPT), "run", "--store", str(self.store),
                                    "--repo", REPO, "--issue", "1676", "--claude", str(self.fake)],
                                   stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        try:
            process.stdin.write(b"sleep")
            process.stdin.close()
            process.stdin = None
            deadline = time.monotonic() + 5
            while not self.fake.with_suffix(".pid").exists():
                self.assertLess(time.monotonic(), deadline)
                time.sleep(0.01)
            child = int(self.fake.with_suffix(".pid").read_text(encoding="utf-8"))
            process.send_signal(signal.SIGTERM)
            process.communicate(timeout=5)
            self.assertEqual(process.returncode, 1)
            value = json.loads(next(self.store.glob("*/record.json")).read_text(encoding="utf-8"))
            self.assertEqual(value["state"], "interrupted")
            self.assertIsNotNone(value["end_epoch"])
            with self.assertRaises(ProcessLookupError):
                os.kill(child, 0)
        finally:
            if process.poll() is None:
                process.kill()
                process.communicate()

    def test_concurrent_writes_are_distinct_runs(self):
        command = [sys.executable, str(SCRIPT), "run", "--store", str(self.store), "--repo", REPO,
                   "--issue", "1676", "--claude", str(self.fake)]
        first = subprocess.Popen(command, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        second = subprocess.Popen(command, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        first.communicate(b"task-a", timeout=10)
        second.communicate(b"task-b", timeout=10)
        self.assertEqual((first.returncode, second.returncode), (0, 0))
        self.assertEqual(self.report()["runs"], 2)
        self.assertEqual(self.report()["metrics"]["cost_estimate_usd"]["total"], 0.5)

    def test_corruption_and_schema_changes_fail_closed(self):
        directory = self.fixture(100, 110)
        record = directory / "record.json"
        original = record.read_bytes()
        record.write_text("not-json", encoding="utf-8")
        self.cli("report", "--repo", REPO, "--issue", "1676", expected=2)
        for key, bad in (("schema", 99), ("output_tokens", -1), ("start_epoch", None),
                         ("repo", "bad"), ("session_id", "wrong"), ("models", [1]), ("end_epoch", 99)):
            value = json.loads(original)
            value[key] = bad
            measurement.write_json(record, value)
            self.cli("report", "--repo", REPO, "--issue", "1676", expected=2)

    def test_metric_types_do_not_become_zero(self):
        session = str(uuid.uuid4())
        raw = dict(type="result", subtype="success", is_error=False, session_id=session,
                   total_cost_usd=-1, duration_ms=True, duration_api_ms="2", usage=dict(input_tokens=1.5))
        value, _ = measurement.sanitize_result(json.dumps(raw), session)
        for key in ("cost_estimate_usd", "duration_ms", "duration_api_ms", "input_tokens", "output_tokens"):
            self.assertIsNone(value[key])


if __name__ == "__main__":
    unittest.main()
