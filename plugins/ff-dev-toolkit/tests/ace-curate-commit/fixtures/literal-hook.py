#!/usr/bin/env python3
# -*- coding: utf-8 -*-
import json
import os
from pathlib import Path
import subprocess
import sys

if len(sys.argv) > 1 and sys.argv[1] == "assert":
    root, selected, mode = Path(sys.argv[2]), sys.argv[3], sys.argv[4]
    expected = {
        "GIT_LITERAL_PATHSPECS": "1" if mode == "literal" else None,
        "GIT_GLOB_PATHSPECS": "1" if mode == "glob" else None,
        "GIT_ICASE_PATHSPECS": "1" if mode == "icase" else None,
    }
    pre = json.loads((root / ".git/literal-pre-commit.json").read_text(encoding="utf-8"))
    assert pre["environment"] == expected, pre
    expected_files = [selected] if selected.endswith(".md") and mode != "literal" else []
    assert pre["files"] == expected_files, pre
    post = (root / ".git/literal-post-index-change.jsonl").read_text(encoding="utf-8").splitlines()
    assert post
    for line in post:
        assert json.loads(line)["environment"] == expected, line
else:
    environment = {name: os.environ.get(name) for name in (
        "GIT_LITERAL_PATHSPECS", "GIT_GLOB_PATHSPECS", "GIT_ICASE_PATHSPECS"
    )}
    files = subprocess.check_output(["git", "diff", "--cached", "--name-only", "-z", "--", "*.md"])
    value = dict(environment=environment, files=[p.decode("utf-8") for p in files.split(bytes([0])) if p])
    kind = Path(sys.argv[0]).name
    if kind == "post-index-change":
        with Path(".git/literal-post-index-change.jsonl").open("a", encoding="utf-8") as stream:
            stream.write(json.dumps(value) + chr(10))
    else:
        Path(".git/literal-pre-commit.json").write_text(json.dumps(value), encoding="utf-8")
