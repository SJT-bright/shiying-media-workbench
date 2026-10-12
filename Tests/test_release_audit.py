import os, subprocess, sys, tempfile, unittest
from pathlib import Path
import yt_dlp

SCRIPT=Path(__file__).resolve().parents[1]/'Scripts/audit_release.py'
class ReleaseAuditTests(unittest.TestCase):
    def run_audit(self,folder):
        return subprocess.run([sys.executable,str(SCRIPT),str(folder)],env={**os.environ,'SHIYING_PRIVATE_IDENTIFIERS':'audit-test-user'},capture_output=True).returncode
    def test_only_exact_published_dependency_files_are_exempt(self):
        with tempfile.TemporaryDirectory() as root:
            f=Path(root)/'resources/worker/_internal/yt_dlp/extractor/listennotes.py';f.parent.mkdir(parents=True)
            original=(Path(yt_dlp.__file__).parent/'extractor/listennotes.py').read_bytes();f.write_bytes(original)
            self.assertEqual(self.run_audit(root),0)
            f.write_bytes(original+b'\n# '+b'sk-'+b'a'*40)
            self.assertNotEqual(self.run_audit(root),0)
    def test_secret_in_unrelated_file_is_rejected(self):
        with tempfile.TemporaryDirectory() as root:
            (Path(root)/'config.txt').write_bytes(b'sk-'+b'a'*40)
            self.assertNotEqual(self.run_audit(root),0)
    def test_private_path_is_rejected(self):
        with tempfile.TemporaryDirectory() as root:
            (Path(root)/'config.txt').write_text('/Users/audit-test-user/material')
            self.assertNotEqual(self.run_audit(root),0)
