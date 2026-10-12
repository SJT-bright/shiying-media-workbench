"""Print the helper cache fingerprint. Backend/*.py, requirements, upstream HEAD."""
import hashlib
import pathlib
import subprocess
import sys

root = pathlib.Path(__file__).resolve().parent.parent
digest = hashlib.sha256()
digest.update(b"backend-py\0")
for path in sorted((root / "Backend").glob("*.py")):
    digest.update(path.name.encode())
    digest.update(b"\0")
    digest.update(path.read_bytes())
    digest.update(b"\0")
requirements = root / "requirements-build.txt"
digest.update(b"requirements\0")
digest.update(requirements.read_bytes() if requirements.is_file() else b"MISSING")
digest.update(b"\0upstream\0")
try:
    pin = subprocess.check_output(
        ["git", "-C", str(root / "Backend" / "upstream"), "rev-parse", "HEAD"],
        text=True,
    ).strip()
except (OSError, subprocess.CalledProcessError):
    pin = "NO-UPSTREAM"
digest.update(pin.encode())
sys.stdout.write(digest.hexdigest() + "\n")
