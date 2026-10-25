# -*- coding: utf-8 -*-
"""Execute the documented byte check against saved-source counterexamples."""
from pathlib import Path
import os
import shutil
import subprocess
import sys
import tempfile

document = Path(sys.argv[1]).read_text(encoding="utf-8")
start, end = "<!-- literal-byte-check:start -->", "<!-- literal-byte-check:end -->"
if document.count(start) != 1 or document.count(end) != 1:
    raise SystemExit("literal-byte: 照合例の境界が一意ではありません")
block = document.split(start, 1)[1].split(end, 1)[0].strip()
lines = block.splitlines()
if not lines or lines[0] != "```python" or lines[-1] != "```" or len(lines) < 4:
    raise SystemExit("literal-byte: 照合例が空かPython fenceではありません")
source = os.linesep.join(lines[1:-1])
compile(source, "documented-byte-check.py", "exec")
# Fixture bytes are expressed independently of the documented numeric construction.
good = {
    "ts": bytes.fromhex("636f6e73742074657874203d20222320696e6465785c6e223b0a"),
    "printf": bytes.fromhex("23212f7573722f62696e2f656e7620626173680a7072696e7466202725735c6e272076616c75650a"),
    "unicode": bytes.fromhex("5c75323031340a"),
}
cases = [("保存した" + kind, kind, value, True) for kind, value in good.items()]
cases.extend([
    ("TSに実LF", "ts", good["ts"].replace(bytes([92, 110]), bytes([10])), False),
    ("TSに実CRLF", "ts", good["ts"].replace(bytes([92, 110]), bytes([13, 10])), False),
    ("printfに実LF", "printf", good["printf"].replace(bytes([92, 110]), bytes([10])), False),
    ("Unicode6文字が1文字", "unicode", bytes.fromhex("e280940a"), False),
])
with tempfile.TemporaryDirectory(prefix="ff-literal-bytes-") as directory:
    root = Path(directory)
    checker = root / "documented-byte-check.py"
    checker.write_text(source, encoding="utf-8", newline="\n")
    for index, (name, kind, value, succeeds) in enumerate(cases):
        fixture = root / (str(index) + ".source")
        fixture.write_bytes(value)
        result = subprocess.run([sys.executable, "-I", "-X", "utf8", str(checker), kind, str(fixture)], capture_output=True, timeout=30)
        if (result.returncode == 0) != succeeds:
            raise SystemExit("literal-byte: " + name + " の判定が不正です")
        if not succeeds and "保存バイトが期待値と異なる" not in result.stderr.decode("utf-8"):
            raise SystemExit("literal-byte: 不一致以外の失敗を混同しました: " + name)
        print("  ✓ literal-byte: " + name)
    missing = subprocess.run([sys.executable, "-I", "-X", "utf8", str(checker), "ts", str(root / "missing.source")], capture_output=True, timeout=30)
    if missing.returncode == 0:
        raise SystemExit("literal-byte: 対象不在を照合済みにしました")
    print("  ✓ literal-byte: 対象不在は未照合として停止")

    # Deliberately execute only the controlled printf counterexample, never log commands.
    bash = shutil.which("bash")
    if not bash:
        raise SystemExit("literal-byte: printfの対照に必要なbashがありません")
    normal, changed = root / "normal.sh", root / "changed.sh"
    normal.write_bytes(good["printf"])
    changed.write_bytes(good["printf"].replace(bytes([92, 110]), bytes([10])))
    syntax = subprocess.run([bash, "-n", changed.as_posix()], capture_output=True, timeout=30)
    outputs = [subprocess.run([bash, path.as_posix()], capture_output=True, timeout=30) for path in (normal, changed)]
    if syntax.returncode or any(result.returncode for result in outputs) or outputs[0].stdout != outputs[1].stdout:
        raise SystemExit("literal-byte: 構文/出力が正常でも保存ソースが異なる対照が成立しません")
    print("  ✓ literal-byte: printfは構文/出力が同じでも保存バイトで区別")

    # Execute the documented file-carrier patch without placing its values in argv.
    patch_start, patch_end = "<!-- literal-patch-example:start -->", "<!-- literal-patch-example:end -->"
    if document.count(patch_start) != 1 or document.count(patch_end) != 1:
        raise SystemExit("literal-patch: 値ファイルの照合例の境界が一意ではありません")
    patch_lines = document.split(patch_start, 1)[1].split(patch_end, 1)[0].strip().splitlines()
    if not patch_lines or patch_lines[0] != "```python" or patch_lines[-1] != "```" or len(patch_lines) < 4:
        raise SystemExit("literal-patch: 値ファイルの照合例が空かPython fenceではありません")
    patcher = root / "documented-patch.py"
    patcher.write_text(os.linesep.join(patch_lines[1:-1]), encoding="utf-8", newline="\n")
    target, anchor_file, replacement_file = root / "target.source", root / "anchor.data", root / "replacement.data"
    prefix, suffix = bytes.fromhex("7072656669780d0a"), bytes.fromhex("0d0a7375666669780d0a")
    original = prefix + b"TOKEN" + suffix
    anchor_file.write_bytes(b"TOKEN")
    replacement_file.write_bytes(good["ts"])
    target.write_bytes(original)
    patched = subprocess.run([sys.executable, "-I", "-X", "utf8", str(patcher), str(target), str(anchor_file), str(replacement_file)], capture_output=True, timeout=30)
    if patched.returncode or target.read_bytes() != prefix + good["ts"] + suffix:
        raise SystemExit("literal-patch: 値のbackslashまたは対象外のCRLFを保存できません")
    print("  ✓ literal-patch: 値はファイルから読み、対象リテラルと前後のCRLFを保持")
    for name, anchor, body in [("empty", b"", original), ("not-found", b"ABSENT", original), ("duplicate", b"TOKEN", original + b"TOKEN")]:
        anchor_file.write_bytes(anchor)
        target.write_bytes(body)
        failed = subprocess.run([sys.executable, "-I", "-X", "utf8", str(patcher), str(target), str(anchor_file), str(replacement_file)], capture_output=True, timeout=30)
        if failed.returncode == 0 or target.read_bytes() != body:
            raise SystemExit("literal-patch: " + name + " を書き込み前に止めていません")
        print("  ✓ literal-patch: " + name + " は対象を変更せず停止")
    anchor_file.write_bytes(b"TOKEN")
    target.write_bytes(original)
    replacement_file.unlink()
    missing_value = subprocess.run([sys.executable, "-I", "-X", "utf8", str(patcher), str(target), str(anchor_file), str(replacement_file)], capture_output=True, timeout=30)
    if missing_value.returncode == 0 or target.read_bytes() != original:
        raise SystemExit("literal-patch: 値ファイル不在を対象不変のまま止めていません")
    print("  ✓ literal-patch: 値ファイル不在は対象を変更せず停止")
