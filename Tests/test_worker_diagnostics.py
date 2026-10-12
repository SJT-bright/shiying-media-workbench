import errno
import json
import sys
import unittest
from pathlib import Path
from unittest.mock import AsyncMock, patch

ROOT = Path(__file__).resolve().parents[1]
sys.path[:0] = [str(ROOT / 'Backend'), str(ROOT / 'Backend/upstream/src')]
import httpx
import worker


class WorkerDiagnosticTests(unittest.TestCase):
    def test_failures_report_specific_category_without_raw_exception_or_credentials(self):
        secret = 'SYNTHETIC_SECRET_MUST_NOT_APPEAR'
        request = httpx.Request('GET', 'https://www.douyin.com/?token=' + secret)
        cases = [
            (OSError(errno.ENOSPC, secret), '磁盘空间不足'),
            (httpx.ReadTimeout(secret, request=request), '超时'),
            (httpx.HTTPStatusError(secret, request=request, response=httpx.Response(403, request=request)), 'HTTP 403'),
            (TypeError(secret), '内部错误（TypeError）'),
        ]
        for error, expected in cases:
            with self.subTest(error=type(error).__name__):
                events = []
                with patch.object(sys, 'argv', ['worker', 'info', '--link', 'https://www.douyin.com/video/7000000000000000001']), \
                     patch.object(worker, 'fetch', new=AsyncMock(side_effect=error)), \
                     patch.object(worker.signal, 'signal'), \
                     patch.object(worker, 'emit', side_effect=lambda event, **kw: events.append(dict(event=event, **kw))):
                    self.assertEqual(worker.main(), 1)
                self.assertIn(expected, events[-1]['message'])
                self.assertEqual(events[-1]['diagnostic']['stage'], 'info')
                self.assertNotIn(secret, json.dumps(events))


if __name__ == '__main__': unittest.main()
