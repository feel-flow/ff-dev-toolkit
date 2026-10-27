# -*- coding: utf-8 -*-
"""Exercise shipped runbooks in isolated fixtures; never operate Docker."""
from pathlib import Path
import os
import re
import stat
import subprocess
import tempfile
import unittest

PLUGIN = Path(__file__).resolve().parents[2]
ROOT = PLUGIN.parent.parent if PLUGIN.parent.name == "plugins" else PLUGIN
NL, FENCE = chr(10), chr(96) * 3


def source(relative):
    prefix = "plugins/ff-dev-toolkit/"
    path = PLUGIN / relative.removeprefix(prefix) if relative.startswith(prefix) else ROOT / relative
    assert path.is_file() and path.stat().st_size, "missing or empty target: " + relative
    return path.read_text(encoding="utf-8")


def fence(text, heading):
    assert text.count(heading) == 1, "missing or ambiguous section"
    section = text.split(heading, 1)[1]
    assert FENCE + "bash" in section, "missing executable fence"
    return section.split(FENCE + "bash", 1)[1].split(FENCE, 1)[0].strip()


def docker_section(text):
    assert text.count("### Docker") == 1
    text = text.split("### Docker", 1)[1].split(NL + "---", 1)[0]
    blocks = text.split(FENCE + "bash")[1:]
    assert len(blocks) >= 3, "missing diagnostic procedures"
    commands = [block.split(FENCE, 1)[0] for block in blocks]
    assert not any(re.search(r"chmod.*(?:666|777|o[+]w|a[+]w)", block) for block in commands)
    assert "root 相当" in text and "rootless" in text and "Desktop" in text
    return text


class RunbookTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.tmp, self.bin = self.root / "tmp", self.root / "bin"
        self.tmp.mkdir()
        self.bin.mkdir()
        self.env = dict(os.environ, TMPDIR=str(self.tmp),
                        PATH=str(self.bin) + os.pathsep + os.environ["PATH"])

    def stub(self, name, lines):
        target = self.bin / name
        target.write_text(NL.join(["#!/bin/sh", *lines, ""]), encoding="utf-8")
        target.chmod(0o700)

    def run_shell(self, script):
        return subprocess.run(["/bin/bash", "-c", script], env=self.env,
                              cwd=self.root, text=True, capture_output=True, timeout=30)

    def allocator(self):
        text = source("plugins/ff-dev-toolkit/docs-template/05-operations/deployment/"
                      "markdown-patch-discipline.md")
        script = fence(text, "## 一時ファイルの置き場所")
        self.assertIn("mktemp -d", script)
        self.assertNotIn("mkdir -p", script)
        return script.replace("<スキル名>-<Issue 番号>", "close-issue-5")

    def test_private_workspace_ignores_preplanted_fixed_name(self):
        outside = self.root / "outside"
        outside.mkdir()
        sentinel = outside / "body.md"
        sentinel.write_text("unchanged", encoding="utf-8")
        (self.tmp / "close-issue-5").symlink_to(outside, target_is_directory=True)
        first = self.run_shell(self.allocator())
        self.assertEqual(first.returncode, 0, first.stderr)
        self.assertTrue(first.stdout.startswith("W="))
        actual = Path(first.stdout.strip().removeprefix("W="))
        self.assertNotEqual(actual, self.tmp / "close-issue-5")
        if os.name == "posix":
            self.assertEqual(stat.S_IMODE(actual.stat().st_mode), 0o700)
        (actual / "body.md").write_text("reviewed body", encoding="utf-8")
        self.env["W"] = str(actual)
        second = self.run_shell('test -d "$W" && test ! -L "$W" && cat "$W/body.md"')
        self.assertEqual(second.stdout, "reviewed body")
        self.assertEqual(sentinel.read_text(encoding="utf-8"), "unchanged")

    def test_allocator_failures_stop(self):
        script = self.allocator()
        self.stub("mktemp", ["exit 9"])
        self.assertNotEqual(self.run_shell(script).returncode, 0)
        (self.bin / "mktemp").unlink()
        self.stub("cygpath", ['echo "$2"', "exit 9"])
        self.assertNotEqual(self.run_shell(script).returncode, 0)

    def test_close_issue_requires_same_recorded_workspace(self):
        text = source("plugins/ff-dev-toolkit/skills/close-issue/SKILL.md")
        script = fence(text, "### 6. 完了報告コメントの投稿")
        self.assertNotIn("mktemp", script)
        self.assertNotIn("mkdir", script)
        self.stub("gh", ['while [ "$#" -gt 0 ]; do',
                         'if [ "$1" = --body-file ]; then shift; cat "$1"; exit; fi',
                         "shift", "done", "exit 9"])
        self.env.update(ISSUE_URL="synthetic", ISSUE_NUMBER="5")
        self.env.pop("W", None)
        self.assertNotEqual(self.run_shell(script).returncode, 0)
        allocated = self.run_shell(self.allocator())
        self.assertEqual(allocated.returncode, 0)
        actual = Path(allocated.stdout.strip().removeprefix("W="))
        (actual / "close-issue-report-5.md").write_text("approved report", encoding="utf-8")
        self.env["W"] = str(actual)
        sent = self.run_shell(script)
        self.assertEqual(sent.returncode, 0, sent.stderr)
        self.assertEqual(sent.stdout, "approved report")

    def test_docker_recovery_has_no_world_write_mutation(self):
        text = source("plugins/ff-dev-toolkit/docs-template/08-knowledge/TROUBLESHOOTING.md")
        docker_section(text)
        mutant = text.replace("ls -la /var/run/docker.sock",
                              "sudo chmod 666 /var/run/docker.sock")
        self.assertNotEqual(mutant, text)
        with self.assertRaises(AssertionError):
            docker_section(mutant)
        with self.assertRaises(AssertionError):
            docker_section("")

    def test_health_check_actual_fence_keeps_orphan_detection(self):
        text = source("plugins/ff-dev-toolkit/docs-template/05-operations/"
                      "organizational-rollout/health-check.md")
        script = fence(text, "## 4. 孤立文書の確認")
        self.assertNotRegex(script, r">[ ]*/tmp/")
        self.assertIn("mktemp -d", script)
        self.assertIn("trap ", script)
        docs = self.root / "docs"
        docs.mkdir()
        (docs / "MASTER.md").write_text("[linked](linked.md)", encoding="utf-8")
        (docs / "linked.md").write_text("linked", encoding="utf-8")
        (docs / "orphan.md").write_text("orphan", encoding="utf-8")
        self.stub("git", ["echo 2000-01-01"])
        run = self.run_shell(script)
        self.assertEqual(run.returncode, 0, run.stderr)
        self.assertIn("orphan.md", run.stdout, run.stderr)
        self.assertNotIn("linked.md", run.stdout)
        self.assertEqual(list(self.tmp.iterdir()), [])
        self.stub("mktemp", ["exit 9"])
        self.assertNotEqual(self.run_shell(script).returncode, 0)

    @unittest.skipUnless(os.name == "posix", "PID symlink fixture is POSIX")
    @unittest.skipUnless((ROOT / "plugins/ff-media-toolkit").is_dir(),
                         "separate media plugin is not in this distribution")
    def test_storyboard_checker_ignores_legacy_pid_symlink(self):
        script = ROOT / "plugins/ff-media-toolkit/tests/storyboard-schema/verify.sh"
        self.assertTrue(script.is_file())
        sentinel = self.root / "sentinel"
        sentinel.write_text("unchanged", encoding="utf-8")
        handshake = 'echo "$$"; read -r GO; exec /bin/bash "$1"'
        child = subprocess.Popen(["/bin/bash", "-c", handshake, "fixture", str(script)],
                                 env=self.env, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                 stderr=subprocess.PIPE, text=True)
        self.addCleanup(lambda: child.kill() if child.poll() is None else None)
        pid = child.stdout.readline().strip()
        self.assertTrue(pid.isdigit())
        leaf = Path("/tmp") / ("ffm-schema-err." + pid)
        self.assertFalse(leaf.exists() or leaf.is_symlink(), "refuse foreign fixture")
        leaf.symlink_to(sentinel)
        try:
            stdout, stderr = child.communicate(NL, timeout=30)
            self.assertEqual(child.returncode, 0, stdout + stderr)
            self.assertEqual(sentinel.read_text(encoding="utf-8"), "unchanged")
            self.assertTrue(leaf.is_symlink())
        finally:
            if leaf.is_symlink() and leaf.readlink() == sentinel:
                leaf.unlink()


if __name__ == "__main__":
    unittest.main()
