#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Opt-in Claude Code measurement. Only allowlisted metadata reaches disk."""
import argparse
import json
import math
import os
from pathlib import Path
import re
import signal
import subprocess
import sys
import tempfile
import time
from urllib.parse import urlsplit
import uuid

SCHEMA = 1
TOKENS = ("input_tokens", "output_tokens", "cache_creation_input_tokens", "cache_read_input_tokens")
METRICS = ("duration_ms", "duration_api_ms", "num_turns", "cost_estimate_usd") + TOKENS
STATES = {"running", "success", "cli_error", "invalid_result", "timeout", "interrupted", "launch_error"}
DEFAULT_STORE = Path.home() / ".local/state/ff-dev-toolkit/claude-measurement"


class MeasurementError(Exception):
    """A controlled diagnostic containing no user payload."""


def number(value, integer=False):
    if type(value) not in (int, float) or not math.isfinite(value) or value < 0:
        return None
    if integer and type(value) is not int:
        return None
    return value


def positive(value):
    parsed = int(value)
    if parsed <= 0:
        raise argparse.ArgumentTypeError("must be positive")
    return parsed


def repo_name(value):
    if not re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", value):
        raise argparse.ArgumentTypeError("expected owner/repository")
    return value


def run_id(value):
    try:
        if str(uuid.UUID(value)) == value:
            return value
    except ValueError:
        pass
    raise MeasurementError("invalid run UUID")


def artifact_url(value, repo):
    url = urlsplit(value)
    pattern = "/" + re.escape(repo) + r"/(?:pull/[1-9][0-9]*|issues/[1-9][0-9]*|commit/[a-f0-9]{40})"
    if (url.scheme != "https" or url.netloc != "github.com" or url.query or url.fragment
            or not re.fullmatch(pattern, url.path)):
        raise MeasurementError("expected a GitHub issue, PR or full commit URL in the recorded repository")
    return value


def write_json(path, data):
    """Atomic snapshots; unique run directories avoid concurrent append corruption."""
    fd, temporary = tempfile.mkstemp(prefix=".snapshot-", dir=path.parent)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as stream:
            json.dump(data, stream, ensure_ascii=False, allow_nan=False, sort_keys=True)
            stream.write(chr(10))
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def read_record(directory):
    data = json.loads((directory / "record.json").read_text(encoding="utf-8"))
    if (not isinstance(data, dict) or data.get("schema") != SCHEMA
            or data.get("run_id") != run_id(directory.name)
            or data.get("state") not in STATES):
        raise MeasurementError("invalid measurement schema")
    try:
        repo_name(data["repo"])
    except argparse.ArgumentTypeError:
        raise MeasurementError("invalid repository") from None
    if data.get("session_id") != data["run_id"]:
        raise MeasurementError("invalid session identity")
    if (not isinstance(data.get("models"), list)
            or any(not isinstance(m, str) or not re.fullmatch(r"[A-Za-z0-9_.:-]{1,120}", m) for m in data["models"])):
        raise MeasurementError("invalid models")
    if data.get("cli_version") is not None and not isinstance(data["cli_version"], str):
        raise MeasurementError("invalid CLI version")
    if type(data["issue"]) is not int or data["issue"] <= 0:
        raise MeasurementError("invalid issue")
    if number(data.get("start_epoch")) is None:
        raise MeasurementError("invalid start")
    for key in ("end_epoch", "process_seconds") + METRICS:
        if key not in data or (data[key] is not None and number(data[key], key in TOKENS + ("num_turns",)) is None):
            raise MeasurementError("invalid numeric metric: " + key)
    if data["end_epoch"] is not None and data["end_epoch"] < data["start_epoch"]:
        raise MeasurementError("reversed interval")
    if data["state"] == "running" and data["end_epoch"] is not None:
        raise MeasurementError("invalid open interval")
    return data


def load_record(directory):
    identity = run_id(directory.name)
    try:
        return read_record(directory)
    except MeasurementError as error:
        raise MeasurementError("run=" + identity + " " + str(error)) from None
    except (OSError, ValueError, KeyError, TypeError, OverflowError) as error:
        raise MeasurementError("run=" + identity + " unreadable record (" + type(error).__name__ + ")") from None


def sanitize_result(raw, session):
    """Allowlist stored metrics; return response text separately for stdout only."""
    try:
        result = json.loads(raw)
    except (ValueError, UnicodeDecodeError):
        return None, None
    if not isinstance(result, dict) or result.get("type") != "result" or result.get("session_id") != session:
        return None, None
    usage = result.get("usage")
    usage = usage if isinstance(usage, dict) else {}
    metrics = {k: number(result.get(k), k == "num_turns") for k in ("duration_ms", "duration_api_ms", "num_turns")}
    metrics["cost_estimate_usd"] = number(result.get("total_cost_usd"))
    metrics.update({k: number(usage.get(k), integer=True) for k in TOKENS})
    models = result.get("modelUsage")
    metrics["models"] = sorted(k for k in models if re.fullmatch(r"[A-Za-z0-9_.:-]{1,120}", k)) if isinstance(models, dict) else []
    ok = result.get("is_error") is False and result.get("subtype") == "success"
    denials = result.get("permission_denials")
    metrics["permission_denials"] = len(denials) if isinstance(denials, list) else None
    metrics["result_ok"] = ok and denials == []
    return metrics, result.get("result") if isinstance(result.get("result"), str) else None


def stop_process(process):
    # SIGTERM, wait up to 3s, then SIGKILL the process group.
    try:
        os.killpg(process.pid, signal.SIGTERM)
    except ProcessLookupError:
        pass
    try:
        output = process.communicate(timeout=3)[0]
    except subprocess.TimeoutExpired:
        output = None
    # Pipe EOF only proves the leader is done; descendants can close stdout and ignore TERM.
    try:
        os.killpg(process.pid, signal.SIGKILL)
    except ProcessLookupError:
        pass
    if output is not None:
        return output
    try:
        return process.communicate(timeout=3)[0]
    except subprocess.TimeoutExpired:
        # A detached descendant may hold stdout. Close our pipe and keep usage missing.
        process.stdout.close()
        process.wait(timeout=3)
        return b""


def interrupt_run(signum, frame):
    raise KeyboardInterrupt


def run(args):
    prompt = sys.stdin.buffer.read()
    session = str(uuid.uuid4())
    try:
        probe = subprocess.run([args.claude, "--version"], capture_output=True, timeout=15, check=True)
        version = probe.stdout.decode("utf-8").strip()
        if not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+ \(Claude Code\)", version):
            version = None
    except (OSError, subprocess.SubprocessError, UnicodeDecodeError):
        version = None
    # An interrupted version probe must not publish an empty run directory.
    args.store.mkdir(parents=True, exist_ok=True, mode=0o700)
    directory = args.store / session
    record = dict(schema=SCHEMA, run_id=session, session_id=session, repo=args.repo, issue=args.issue,
                  cli_version=version, safe_mode=args.safe_mode, state="running", start_epoch=time.time(), end_epoch=None,
                  process_seconds=None, exit_code=None, models=[], permission_denials=None)
    record.update({k: None for k in METRICS})
    # Publish a complete start snapshot atomically; abandoned staging is outside the store.
    with tempfile.TemporaryDirectory(prefix=".claude-measure-start-", dir=args.store.parent) as pending:
        write_json(Path(pending) / "record.json", record)
        os.rename(pending, directory)
    command = [args.claude, "-p", "--output-format", "json", "--session-id", session,
               "--no-session-persistence", "--max-turns", str(args.max_turns),
               "--tools", "Read,Glob,Grep", "--allowedTools", "Read,Glob,Grep",
               "--strict-mcp-config", "--mcp-config", '{"mcpServers":{}}']
    if args.model:
        command.extend(["--model", args.model])
    if args.safe_mode:
        command.append("--safe-mode")
    start = time.monotonic()
    output, response = b"", None
    process = None
    try:
        process = subprocess.Popen(command, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                   stderr=None, start_new_session=True)
        try:
            output = process.communicate(prompt, timeout=args.timeout)[0]
            record["state"] = "success" if process.returncode == 0 else "cli_error"
        except subprocess.TimeoutExpired:
            record["state"] = "timeout"
            output = stop_process(process)
        except KeyboardInterrupt:
            record["state"] = "interrupted"
            output = stop_process(process)
        record["exit_code"] = process.returncode
    except OSError:
        record["state"] = "launch_error"
    except KeyboardInterrupt:
        if process is not None:
            output = stop_process(process)
            record["exit_code"] = process.returncode
        record["state"] = "interrupted"
    finally:
        record["process_seconds"] = time.monotonic() - start
        end = time.time()
        # Clock jumps invalidate the comparable epoch interval, not monotonic duration.
        if end >= record["start_epoch"] and abs((end - record["start_epoch"]) - record["process_seconds"]) <= 1:
            record["end_epoch"] = end
        metrics, response = sanitize_result(output, session)
        if metrics is not None:
            ok = metrics.pop("result_ok")
            record.update(metrics)
            if record["state"] == "success" and not ok:
                record["state"] = "cli_error"
        elif record["state"] == "success":
            record["state"] = "invalid_result"
        write_json(directory / "record.json", record)
    print("measurement run=" + session + " state=" + record["state"], file=sys.stderr)
    if response is not None:
        print(response)
    return 0 if record["state"] == "success" else 1


def union_seconds(intervals):
    end, total = None, 0.0
    for left, right in sorted(intervals):
        total += max(0, right - max(left, end if end is not None else left))
        end = max(right, end if end is not None else right)
    return total


def report(args):
    records = []
    links = set()
    if args.store.exists():
        if not args.store.is_dir():
            raise MeasurementError("store is not a directory")
        for directory in sorted(args.store.iterdir()):
            # Unknown entries must not disappear from an apparently complete report.
            if not directory.is_dir():
                raise MeasurementError("unexpected store entry (expected run UUID directory)")
            data = load_record(directory)
            if data["repo"] != args.repo or data["issue"] != args.issue:
                continue
            records.append(data)
            for link in directory.glob("link-*.json"):
                try:
                    links.add(artifact_url(json.loads(link.read_text(encoding="utf-8"))["url"], args.repo))
                except (OSError, ValueError, KeyError, TypeError, MeasurementError):
                    raise MeasurementError("run=" + data["run_id"] + " invalid artifact link") from None
    intervals = [(r["start_epoch"], r["end_epoch"]) for r in records if r["end_epoch"] is not None]
    union = union_seconds(intervals)
    elapsed = max(r for _, r in intervals) - min(l for l, _ in intervals) if intervals else None
    complete = bool(records) and len(intervals) == len(records)
    metrics = {}
    for key in METRICS + ("process_seconds",):
        values = [r[key] for r in records if r[key] is not None]
        metrics[key] = {"total": sum(values) if records and len(values) == len(records) else None,
                        "observed": sum(values) if values else None, "missing": len(records) - len(values)}
    summary = dict(schema=SCHEMA, repo=args.repo, issue=args.issue, runs=len(records),
                   incomplete=sum(r["state"] == "running" for r in records),
                   interval_missing=len(records) - len(intervals),
                   failed=sum(r["state"] not in ("running", "success") for r in records),
                   sessions=[r["session_id"] for r in records],
                   cli_versions=sorted({r["cli_version"] for r in records if r["cli_version"]}),
                   models=sorted({m for r in records for m in r["models"]}),
                   cli_interval_sum_seconds=sum(r-l for l, r in intervals) if complete else None,
                   cli_interval_union_seconds=union if complete else None,
                   elapsed_seconds=elapsed if complete else None,
                   observed_interval_union_seconds=union if intervals else None,
                   metrics=metrics, artifacts=sorted(links),
                   human_intervention_seconds=None, ai_active_seconds=None, wait_seconds=None,
                   billed_cost_usd=None)
    print(json.dumps(summary, ensure_ascii=False, allow_nan=False, indent=2, sort_keys=True))
    return 0


def link(args):
    directory = args.store / run_id(args.run)
    data = load_record(directory)
    url = artifact_url(args.url, data["repo"])
    write_json(directory / ("link-" + str(uuid.uuid4()) + ".json"), {"url": url})
    return 0


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    for name in ("run", "report", "link"):
        cmd = commands.add_parser(name)
        cmd.add_argument("--store", type=Path, default=DEFAULT_STORE)
        if name in ("run", "report"):
            cmd.add_argument("--repo", type=repo_name, required=True)
            cmd.add_argument("--issue", type=positive, required=True)
        if name == "run":
            cmd.add_argument("--claude", default="claude")
            cmd.add_argument("--model")
            cmd.add_argument("--safe-mode", action="store_true", help="disable CLI customizations for a controlled read-only pilot")
            cmd.add_argument("--timeout", type=positive, default=300)
            cmd.add_argument("--max-turns", type=positive, default=5)
        if name == "link":
            cmd.add_argument("--run", required=True)
            cmd.add_argument("--url", required=True)
    args = parser.parse_args()
    previous_term = None
    try:
        if args.command == "run" and os.name != "posix":
            raise MeasurementError("run requires POSIX process groups (macOS/Linux)")
        if args.command == "run":
            previous_term = signal.signal(signal.SIGTERM, interrupt_run)
        return {"run": run, "report": report, "link": link}[args.command](args)
    except MeasurementError as error:
        print("measurement failed: " + str(error), file=sys.stderr)
        return 2
    except (OSError, ValueError, KeyError, TypeError) as error:
        # Do not echo raw JSON, command arguments or source content from exceptions.
        print("measurement failed: " + type(error).__name__, file=sys.stderr)
        return 2
    except KeyboardInterrupt:
        print("measurement cancelled before start", file=sys.stderr)
        return 130
    finally:
        if previous_term is not None:
            signal.signal(signal.SIGTERM, previous_term)


if __name__ == "__main__":
    sys.exit(main())
