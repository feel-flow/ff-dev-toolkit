#!/usr/bin/env python3
"""Fake GitHub Issue API for the release fixture."""
import json
import os
import sys
import time
from pathlib import Path
from urllib.parse import urlsplit

state = Path(os.environ["RELEASE_RT_STATE"])
file = state / "release-issues.json"
args = sys.argv[1:]
base = "repos/" + "feel-flow/feelflow-" + "plugins"
if args[:3] != ["api", "--hostname", "github.com"]:
    legacy = str(Path(sys.argv[0]).with_name("gh-legacy"))
    os.execv(legacy, [legacy, *args])

method = args[args.index("-X") + 1] if "-X" in args else "GET"
route = next(arg for arg in args if arg.startswith(base))
if (state / "issue-denied").exists():
    sys.exit(1)
rows = json.loads(file.read_text()) if file.exists() else []
path = urlsplit(route).path
if path == base:
    print(json.dumps({"full_name": base[6:], "private": True, "visibility": "private"}))
    sys.exit(0)
if path == base + "/issues" and method == "GET":
    print(json.dumps([[row for row in rows if row["state"] == "open"]]))
    sys.exit(0)
if path == base + "/issues" and method == "POST":
    if (state / "issue-race").exists():
        time.sleep(1)
        rows = json.loads(file.read_text()) if file.exists() else []
    payload = json.load(sys.stdin)
    row = {"body": payload["body"], "number": len(rows) + 1, "state": "open",
           "labels": [{"name": "release"}], "comments": []}
    rows.append(row)
else:
    number = int(path.split("/")[4])
    row = rows[number - 1]
    if method == "GET":
        if (state / "issue-readback-mismatch").exists():
            row = dict(row, body=row["body"].replace('"token":"', '"token":"replaced-'))
        print(json.dumps(row))
        sys.exit(0)
    if method == "PATCH":
        if "--input" in args:
            row["body"] = json.load(sys.stdin)["body"]
        else:
            assert "state=closed" in args
            row["state"] = "closed"
    elif method == "POST":
        row["comments"].append(args[args.index("-f") + 1].removeprefix("body="))
    else:
        sys.exit(64)
temporary = file.with_suffix(".tmp")
temporary.write_text(json.dumps(rows))
temporary.replace(file)
print(json.dumps(row))
