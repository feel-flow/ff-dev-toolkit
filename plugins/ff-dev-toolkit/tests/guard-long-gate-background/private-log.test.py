# -*- coding: utf-8 -*-
import importlib.util
import os
from pathlib import Path
import shutil
import tempfile
import unittest
from unittest.mock import patch

HELPER = Path(__file__).resolve().parents[2] / "hooks" / "private-session-log.py"
if not HELPER.is_file():
    raise RuntimeError("private log implementation missing")
spec = importlib.util.spec_from_file_location("private_session_log", HELPER)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


@unittest.skipUnless(os.name == "posix", "descriptor-relative log implementation requires POSIX")
class PrivateLogTest(unittest.TestCase):
    def setUp(self):
        self.root = Path(tempfile.mkdtemp(prefix="ff-log-security-"))
        self.directory = self.root / "ff-dev-toolkit-delegation-guard"
        self.fields = ["time", "deny", "agent_type=test", "agent_id=test", "detail"]
        self.sentinel = self.root / "outside-sentinel"
        self.sentinel.write_text("sentinel", encoding="utf-8")

    def tearDown(self):
        shutil.rmtree(self.root)

    def test_normal_session_append_and_legacy_directory(self):
        self.directory.mkdir(mode=0o755)
        for _ in range(2):
            result = module.append_record(str(self.root), "session.log", self.fields)
        self.assertEqual(Path(result).read_text(encoding="utf-8").splitlines(),
                         [chr(9).join(self.fields)] * 2)
        self.assertEqual(self.directory.stat().st_mode & 0o777, 0o700)
        self.assertEqual(Path(result).stat().st_mode & 0o777, 0o600)

    def test_directory_symlink_is_refused(self):
        self.directory.symlink_to(self.root, target_is_directory=True)
        with self.assertRaises(OSError):
            module.append_record(str(self.root), "session.log", self.fields)
        self.assertFalse((self.root / "session.log").exists())

    def test_unsafe_leaf_objects_never_write_sentinel(self):
        self.directory.mkdir(mode=0o700)
        for kind in ("symlink", "hardlink", "directory", "fifo"):
            with self.subTest(kind=kind):
                leaf = self.directory / (kind + ".log")
                if kind == "symlink":
                    leaf.symlink_to(self.sentinel)
                elif kind == "hardlink":
                    os.link(self.sentinel, leaf)
                elif kind == "directory":
                    leaf.mkdir()
                else:
                    os.mkfifo(leaf)
                with self.assertRaises(OSError):
                    module.append_record(str(self.root), leaf.name, self.fields)
                self.assertEqual(self.sentinel.read_text(encoding="utf-8"), "sentinel")

    def test_owner_mismatch_is_refused_before_write(self):
        self.directory.mkdir(mode=0o700)
        actual_uid = os.geteuid()
        with patch.object(module.os, "geteuid", return_value=actual_uid + 1):
            with self.assertRaises(OSError):
                module.append_record(str(self.root), "session.log", self.fields)
        self.assertFalse((self.directory / "session.log").exists())

    def test_renamed_directory_does_not_redirect_open_descriptor(self):
        write = os.write
        moved = self.root / "moved-private"
        outside = self.root / "outside"
        outside.mkdir()
        redirected = False

        def replace_path(fd, data):
            nonlocal redirected
            if not redirected:
                self.directory.rename(moved)
                self.directory.symlink_to(outside, target_is_directory=True)
                redirected = True
            return write(fd, data)

        with patch.object(module.os, "write", side_effect=replace_path):
            module.append_record(str(self.root), "session.log", self.fields)
        self.assertTrue((moved / "session.log").is_file())
        self.assertFalse((outside / "session.log").exists())
        self.assertEqual(self.sentinel.read_text(encoding="utf-8"), "sentinel")

    def test_missing_secure_capability_fails(self):
        with patch.object(module.os, "supports_dir_fd", set()):
            with self.assertRaises(OSError):
                module.append_record(str(self.root), "session.log", self.fields)
        self.assertFalse(self.directory.exists())


if __name__ == "__main__":
    unittest.main()
