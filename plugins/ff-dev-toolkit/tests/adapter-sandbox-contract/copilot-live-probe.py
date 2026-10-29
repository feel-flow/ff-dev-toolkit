"""Actual installed CLI + loopback synthetic provider, no auth or external model."""
import http.server
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import threading
import time


def run_case(base, deny):
    root = base / ("deny" if deny else "allow")
    root.mkdir()
    home = root / "home"
    home.mkdir()
    work = root / "work"
    work.mkdir()
    config = home / "copilot"
    config.mkdir()
    (config / "permissions-config.json").write_text(json.dumps({"locations": {str(work): {
        "tool_approvals": [{"kind": "write"}, {"kind": "commands", "commandIdentifiers": ["printf:*"]}]
    }}}))
    requests = []
    failures = []

    class Handler(http.server.BaseHTTPRequestHandler):
        def log_message(self, *args):
            pass

        def do_POST(self):
            body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
            requests.append(body)
            tools = {t["function"]["name"]: t["function"] for t in body.get("tools", []) if "function" in t}
            calls = []
            if len(requests) == 1:
                print("TOOLS", sorted(tools), flush=True)
                create = next((n for n in ("create", "create_file", "write_file") if n in tools), None)
                patch = any(t.get("custom", {}).get("name") == "apply_patch" for t in body.get("tools", []))
                shell = next((n for n in ("bash", "shell", "run_terminal_cmd") if n in tools), None)
                if not (create or patch) or not shell:
                    failures.append("missing create/shell tool schemas")
                else:
                    p = str(work / "write-proof.txt")
                    props = tools[create]["parameters"]["properties"] if create else {}
                    values = {"path": p, "file_path": p, "content": "write-proof", "file_text": "write-proof"}
                    args = {k: v for k, v in values.items() if k in props}
                    shell_props = tools[shell]["parameters"]["properties"]
                    shell_args = {"command": "printf shell-proof > shell-proof.txt", "description": "fixture write"}
                    shell_args = {k: v for k, v in shell_args.items() if k in shell_props}
                    write_call = {"id": "call_write", "type": "function", "function": {"name": create, "arguments": json.dumps(args)}} if create else {"id": "call_write", "type": "custom", "custom": {"name": "apply_patch", "input": "*** Begin Patch\n*** Add File: " + p + "\n+write-proof\n*** End Patch\n"}}
                    calls = [write_call,
                             {"id": "call_shell", "type": "function", "function": {"name": shell, "arguments": json.dumps(shell_args)}}]
            text = "fixture complete"
            choice = {"index": 0, "delta": {"role": "assistant", "content": text}, "finish_reason": "stop"}
            if calls:
                for i, call in enumerate(calls):
                    call["index"] = i
                choice = {"index": 0, "delta": {"role": "assistant", "tool_calls": calls}, "finish_reason": "tool_calls"}
            chunk = {"id": "chatcmpl-fixture", "object": "chat.completion.chunk", "created": int(time.time()), "model": "fixture", "choices": [choice]}
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            self.end_headers()
            self.wfile.write(("data: " + json.dumps(chunk) + "\n\ndata: [DONE]\n\n").encode())

    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    env = {"PATH": os.environ["PATH"], "HOME": str(home), "TMPDIR": str(home), "COPILOT_HOME": str(config),
           "XDG_CONFIG_HOME": str(home / "config"), "XDG_CACHE_HOME": str(home / "cache"),
           "COPILOT_PROVIDER_BASE_URL": f"http://127.0.0.1:{server.server_port}/v1",
           "COPILOT_PROVIDER_TYPE": "openai", "COPILOT_MODEL": "gpt-4",
           "COPILOT_PROVIDER_WIRE_API": "completions", "NO_COLOR": "1"}
    args = [sys.argv[1], "-p", "Run the two requested fixture tools and finish.",
            "--disable-builtin-mcps", "--no-custom-instructions", "--no-auto-update",
            "--disable-client-telemetry", "--no-ask-user", "--silent"]
    if deny:
        args += ["--deny-tool", "write", "--deny-tool", "shell", "--disallow-temp-dir"]
    try:
        result = subprocess.run(args, env=env, cwd=work, text=True, capture_output=True, timeout=90)
    finally:
        server.shutdown()
        server.server_close()
    (root / "stdout.txt").write_text(result.stdout)
    (root / "stderr.txt").write_text(result.stderr)
    (root / "provider-requests.json").write_text(json.dumps(requests, indent=2))
    files = [(work / "write-proof.txt").exists(), (work / "shell-proof.txt").exists()]
    tool_results = [m for req in requests[1:] for m in req.get("messages", []) if m.get("role") == "tool"]
    print(json.dumps({"deny": deny, "rc": result.returncode, "requests": len(requests), "files": files,
                      "tool_results": tool_results, "errors": failures, "stderr": result.stderr[-1000:]}), flush=True)
    assert result.returncode == 0 and not failures and len(requests) >= 2 and len(tool_results) >= 2
    assert files == ([False, False] if deny else [True, True])
    if deny:
        assert all("Permission to run this tool was denied" in m.get("content", "") for m in tool_results)


if len(sys.argv) != 2:
    raise SystemExit("usage: python3 copilot-live-probe.py /absolute/path/to/copilot")
base = Path(tempfile.mkdtemp(prefix="copilot-local-permission-")).resolve()
print("ARTIFACTS", base, flush=True)
run_case(base, False)
run_case(base, True)
