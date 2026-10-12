"""A failed check must stop the real packaging entry before bundle changes."""
import os
import sys
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


@unittest.skipUnless(sys.platform == "darwin", "Mac SwiftUI packaging gate; validated by native Mac build checks")
class CreatorBuildGateTests(unittest.TestCase):
    def assert_gate_blocks(self, phase, expected):
        with tempfile.TemporaryDirectory(prefix='shiying-gate-fault-') as temporary:
            root = Path(temporary)
            (root / 'Scripts').mkdir()
            for name in ['build.sh', 'check_creator_regressions.sh']:
                shutil.copy2(ROOT / 'Scripts' / name, root / 'Scripts' / name)
            python = root / '.venv/bin/python'
            python.parent.mkdir(parents=True)
            python.write_text('''#!/bin/sh
if [ "$SHIYING_GATE_TEST_PHASE" = backend ]; then
 echo 'Injected backend test failure' >&2
 exit 42
fi
exit 0
''')
            python.chmod(0o755)
            swift = root / 'fake-tools/swiftc'
            swift.parent.mkdir()
            swift.write_text('''#!/bin/sh
touch "$SHIYING_GATE_MARKER"
if [ "$SHIYING_GATE_TEST_PHASE" = compile ]; then
 echo 'Injected native compile failure' >&2
 exit 43
fi
while [ "$#" -gt 0 ]; do
 if [ "$1" = -o ]; then shift; output="$1"; break; fi
 shift
done
printf '#!/bin/sh\necho "Injected native assertion failure" >&2\nexit 44\n' > "$output"
chmod +x "$output"
''')
            swift.chmod(0o755)
            marker = root / 'native-compile-attempted'
            environment = dict(os.environ, SHIYING_GATE_TEST_PHASE=phase,
                               SHIYING_GATE_MARKER=str(marker),
                               PATH=str(swift.parent) + os.pathsep + os.environ['PATH'])
            result = subprocess.run(['zsh', str(root / 'Scripts/build.sh')],
                                    capture_output=True, text=True, env=environment, timeout=10)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn(expected, result.stdout + result.stderr)
            self.assertFalse((root / 'dist').exists(), 'failed gate must not begin bundle creation')
            self.assertFalse((root / 'build/拾影').exists())
            self.assertEqual(marker.exists(), phase != 'backend')
            self.assertEqual(list(root.glob('build/creator-regression/run.*/native-checks')), [])

    def test_backend_failure_blocks_packaging_before_swift(self):
        self.assert_gate_blocks('backend', '后端检查未通过，打包已停止')

    def test_native_compile_failure_blocks_packaging(self):
        self.assert_gate_blocks('compile', '原生检查编译失败，打包已停止')

    def test_native_assertion_failure_blocks_packaging(self):
        self.assert_gate_blocks('native', '原生登录与状态检查未通过，打包已停止')


if __name__ == '__main__': unittest.main()
