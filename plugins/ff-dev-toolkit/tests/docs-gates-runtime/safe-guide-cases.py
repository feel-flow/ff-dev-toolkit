# -*- coding: utf-8 -*-
"""Execute the security-sensitive guide examples with synthetic inputs only."""
import base64
import json
import os
from pathlib import Path
import shlex
import subprocess
import sys
import tempfile
import unittest

DOCS = Path(sys.argv.pop(1))
NL = chr(10)


def bash_fence(text, heading):
    lines = text.splitlines()
    if lines.count(heading) != 1:
        raise AssertionError("guide heading is missing or ambiguous")
    body = []
    opened = False
    for line in lines[lines.index(heading) + 1:]:
        if line.strip() == "```bash" and not opened:
            opened = True
            continue
        if opened and line.strip() == "```":
            if not body:
                raise AssertionError("guide bash example is empty")
            return NL.join(body) + NL
        if opened:
            body.append(line[3:] if line.startswith("   ") else line)
        elif line.startswith("#"):
            break
    raise AssertionError("guide bash example is missing or incomplete")


class SafeGuideExamples(unittest.TestCase):
    def test_encryption_example_does_not_display_secret(self):
        source = (DOCS / "08-knowledge/TROUBLESHOOTING.md").read_text(encoding="utf-8")
        script = bash_fence(source, '#### エラー: "Data encryption failed"')
        raw = bytes(range(32, 64))
        self.assertEqual(len(raw), 32)
        encoded = base64.b64encode(raw).decode("ascii")
        invalid = [None, "", encoded[:-1], encoded + "!", encoded + NL,
                   base64.b64encode(raw[:-1]).decode("ascii"),
                   base64.b64encode(raw + b"x").decode("ascii"),
                   encoded[:-2] + "B="]
        for key in [encoded] + invalid:
            with self.subTest(key_kind="valid" if key == encoded else "invalid"):
                env = dict(os.environ)
                env.pop("ENCRYPTION_KEY", None)
                if key is not None:
                    env["ENCRYPTION_KEY"] = key
                result = subprocess.run(["bash", "-x", "-c", script], env=env,
                                        capture_output=True, encoding="utf-8", timeout=10)
                self.assertEqual(result.returncode, 0 if key == encoded else 1)
                combined = result.stdout + result.stderr
                for secret in [encoded, raw.decode("ascii"), raw.hex()]:
                    self.assertNotIn(secret, combined)
                if key and len(key) > 16:
                    self.assertNotIn(key, combined)
                if key == encoded:
                    self.assertEqual(result.stdout, "暗号化キー: Base64 形式・32 bytesを確認しました" + NL)
                else:
                    self.assertEqual(result.stdout, "")
                    self.assertIn("Base64 形式または32 bytesの長さが不正です", result.stderr)
                    self.assertNotIn("TypeError", result.stderr)

    def test_copilot_example_denies_write_and_shell(self):
        source = (DOCS / "06-reference/REVIEW_AGENT_CREATION_GUIDE.md").read_text(encoding="utf-8")
        self.assertNotIn("--allow-all-tools", source)
        self.assertNotIn("--yolo", source)
        checklist = [line for line in source.splitlines()
                     if line.startswith("- [ ] 書込み・shellを拒否する権限")]
        self.assertEqual(len(checklist), 1, "read-only checklist must be present")
        self.assertIn("確認不能ならレビューを起動しない", checklist[0])
        self.assertIn("全ツールの自動承認は使わない", checklist[0])
        rows = [line for line in source.splitlines()
                if line.startswith("| Copilot CLI |")]
        # The command table and entrypoint table both name the CLI. The command
        # row must uniquely identify the executable rather than the host label.
        rows = [line for line in rows if line.split("|")[2].strip() == "`copilot`"]
        self.assertEqual(len(rows), 1, "Copilot command row must be present")
        flags = shlex.split(rows[0].split("|")[3].strip().strip("`"))
        expected = ["-p", "", "--silent", "--deny-tool", "write",
                    "--deny-tool", "shell", "--disallow-temp-dir"]
        self.assertEqual(flags, expected)
        script = bash_fence(source, "<!-- copilot-read-only-example:start -->")
        help_cases = ["--deny-tool --disallow-temp-dir Denial rules always take precedence",
                      "--deny-tool --disallow-temp-dir",
                      "--disallow-temp-dir Denial rules always take precedence",
                      "--deny-tool Denial rules always take precedence", "", "FAIL"]
        with tempfile.TemporaryDirectory(prefix="safe-guide-examples-") as temp:
            root = Path(temp)
            stub = root / "copilot"
            stub.write_text(NL.join([
                "#!/usr/bin/env python3",
                "import json, os, sys",
                'with open(os.environ["COPILOT_TEST_LOG"], "a", encoding="utf-8") as stream:',
                '    stream.write(json.dumps(sys.argv[1:]) + chr(10))',
                'if sys.argv[1:] == ["help", "permissions"]:',
                '    assert sys.stdin.read() == ""',
                '    if os.environ["COPILOT_TEST_HELP"] == "FAIL":',
                "        sys.exit(1)",
                '    print(os.environ["COPILOT_TEST_HELP"])',
                "else:",
                '    assert sys.stdin.read() == "synthetic review prompt"',
                '    print("review completed")',
            ]) + NL, encoding="utf-8")
            stub.chmod(0o700)
            log = root / "argv.jsonl"
            for index, help_text in enumerate(help_cases):
                with self.subTest(permission_help=index):
                    log.write_text("", encoding="utf-8")
                    env = dict(os.environ, PATH=str(root) + os.pathsep + os.environ["PATH"],
                               COPILOT_TEST_LOG=str(log), COPILOT_TEST_HELP=help_text)
                    result = subprocess.run(["bash", "-c", script], env=env,
                                            input="synthetic review prompt", capture_output=True,
                                            encoding="utf-8", timeout=10)
                    calls = [json.loads(line) for line in log.read_text(encoding="utf-8").splitlines()]
                    self.assertEqual(result.returncode, 0 if index == 0 else 1)
                    self.assertEqual(calls, [["help", "permissions"], expected]
                                     if index == 0 else [["help", "permissions"]])
                    self.assertEqual(result.stdout, "review completed" + NL if index == 0 else "")


if __name__ == "__main__":
    unittest.main()
