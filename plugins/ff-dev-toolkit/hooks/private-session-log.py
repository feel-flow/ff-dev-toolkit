#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Optional hook telemetry: descriptor-relative, private, no-follow append."""
import os
import stat
import sys
from contextlib import ExitStack


def append_record(parent, leaf, fields):
    required = ("O_DIRECTORY", "O_NOFOLLOW", "O_NONBLOCK", "geteuid", "fchmod")
    if not all(hasattr(os, key) for key in required):
        raise OSError("secure log operations unavailable")
    if os.open not in os.supports_dir_fd or os.mkdir not in os.supports_dir_fd:
        raise OSError("descriptor-relative operations unavailable")
    if not leaf or "/" in leaf or "\\" in leaf or leaf in (".", ".."):
        raise ValueError("invalid log leaf")
    parent = os.path.realpath(parent)
    with ExitStack() as resources:
        root_fd = os.open(parent, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
        resources.callback(os.close, root_fd)
        name = "ff-dev-toolkit-delegation-guard"
        try:
            os.mkdir(name, mode=0o700, dir_fd=root_fd)
        except FileExistsError:
            pass
        directory_fd = os.open(name, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=root_fd)
        resources.callback(os.close, directory_fd)
        info = os.fstat(directory_fd)
        if info.st_uid != os.geteuid() or info.st_mode & 0o300 != 0o300:
            raise OSError("unowned or unwritable log directory")
        # Upgrade our legacy0755 directory through its descriptor. Foreign entries
        # cannot be changed after this; the final leaf still needs no-follow checks.
        os.fchmod(directory_fd, 0o700)
        flags = os.O_WRONLY | os.O_APPEND | os.O_CREAT | os.O_NOFOLLOW | os.O_NONBLOCK
        log_fd = os.open(leaf, flags, 0o600, dir_fd=directory_fd)
        resources.callback(os.close, log_fd)
        info = os.fstat(log_fd)
        if not stat.S_ISREG(info.st_mode) or info.st_uid != os.geteuid() or info.st_nlink != 1:
            raise OSError("unowned, linked or nonregular log")
        os.fchmod(log_fd, 0o600)
        data = memoryview(("\t".join(fields) + "\n").encode("utf-8"))
        while data:
            count = os.write(log_fd, data)
            if count <= 0:
                raise OSError("short log write")
            data = data[count:]
    return os.path.join(parent, name, leaf)


def main(argv):
    if len(argv) != 8:
        return 1
    try:
        print(append_record(argv[1], argv[2], argv[3:]))
        return 0
    except (OSError, ValueError):
        return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
