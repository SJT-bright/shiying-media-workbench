"""登录受限分页、会话边界与凭据无日志回归。全部使用合成会话与 MockTransport。"""
import asyncio
import io
import json
import subprocess
import sys
import unittest
from pathlib import Path
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
sys.path[:0] = [str(ROOT / 'Backend'), str(ROOT / 'Backend/upstream/src')]
import httpx
import creator_worker as scanner

SEC = 'MS4wLjABAAAA_SYNTHETIC_DOUYIN_AUTHOR_0001'
HOME = f'https://www.douyin.com/user/{SEC}'
SECRET = 'SYNTHETIC_SESSION_ONLY_NOT_A_REAL_CREDENTIAL'


def post(number):
    return {'aweme_id': str(7000000000000000000 + number), 'desc': '合成作品', 'aweme_type': 0,
            'author': {'sec_uid': SEC, 'uid': '1', 'nickname': '合成作者'},
            'create_time': 1716200000, 'statistics': {'digg_count': 10, 'collect_count': 2},
            'video': {'play_addr': {'url_list': ['https://example.invalid/a.mp4'], 'width': 720, 'height': 1280},
                      'duration': 1000}, 'status': {'private_status': 0}}


def session(domain='.douyin.com', **changes):
    row = dict(name='sessionid', value=SECRET, domain=domain, path='/')
    row.update(changes)
    return scanner.read_session(io.BytesIO(json.dumps([row]).encode()))


class SessionTests(unittest.TestCase):
    def test_login_only_response_is_actionable_and_empty(self):
        result = scanner.interpret_posts({'status_code': 0,
            'not_login_module': {'guide_login_tip_exist': True}}, SEC)
        self.assertTrue(result['login_required'])
        self.assertEqual(result['posts'], [])
        self.assertFalse(result['has_more'])

    def test_cookie_scope_and_https(self):
        cookies = session()
        client = httpx.Client(cookies=cookies)
        self.assertIn(SECRET, client.build_request('GET', HOME).headers.get('cookie', ''))
        for url in ['http://www.douyin.com/', 'https://douyin.com.evil.test/', 'https://www.iesdouyin.com/']:
            self.assertNotIn(SECRET, client.build_request('GET', url).headers.get('cookie', ''))
        client.close()

    def test_rejects_bad_session_without_echo(self):
        for change in [dict(domain='.evil.test'), dict(domain='.douyin.com.evil.test'),
                       dict(name='bad\nname'), dict(value=SECRET + '\r\nInjected: value'), dict(path='bad'),
                       dict(value='x' * 8193)]:
            with self.subTest(change=list(change.keys())):
                with self.assertRaises(ValueError) as error: session(**change)
                self.assertNotIn(SECRET, str(error.exception))
        for data in [b'{bad', b'x' * 65537, b'{}', b'[true]', b'[null]']:
            with self.assertRaises(ValueError): scanner.read_session(io.BytesIO(data))

    def test_cli_invalid_session_does_not_leak(self):
        result = subprocess.run([sys.executable, str(ROOT / 'Backend/worker.py'), 'scan', '--link', HOME,
                                 '--session-stdin'], input=json.dumps([{'value': SECRET}]), text=True,
                                capture_output=True, timeout=10)
        self.assertEqual(result.returncode, 1)
        self.assertNotIn(SECRET, result.stdout + result.stderr)
        self.assertIn('登录状态无法读取', result.stdout)


class FlowTests(unittest.IsolatedAsyncioTestCase):
    async def run_flow(self, authenticated):
        events, calls = [], []
        def handler(request):
            path = request.url.path
            has_session = SECRET in request.headers.get('cookie', '')
            calls.append((path, has_session))
            if path == '/': return httpx.Response(200)
            if path == '/aweme/v1/web/user/profile/other/':
                return httpx.Response(200, json={'status_code': 0, 'user': {
                    'sec_uid': SEC, 'uid': '1', 'nickname': '合成作者', 'aweme_count': 19}})
            cursor = request.url.params.get('max_cursor', '0')
            if not has_session:
                return httpx.Response(200, json={'status_code': 0, 'aweme_list': [post(i) for i in range(4)],
                    'has_more': 0, 'max_cursor': 100, 'not_login_module': {'guide_login_tip_exist': True}})
            items = range(10) if cursor == '0' else range(9, 19)  # 翻页重复一条，必须去重
            return httpx.Response(200, json={'status_code': 0, 'aweme_list': [post(i) for i in items],
                'has_more': 1 if cursor == '0' else 0, 'max_cursor': 100})
        async with httpx.AsyncClient(transport=httpx.MockTransport(handler)) as client:
            with patch.object(scanner, 'emit_event', side_effect=lambda event, **kw: events.append(dict(event=event, **kw))):
                code = await scanner.run_scan(HOME, client=client, pause_seconds=0,
                                              session_cookies=session() if authenticated else None)
        blob = json.dumps(events) + json.dumps(scanner.last_notes)
        self.assertNotIn(SECRET, blob)
        return code, events, calls

    async def test_guest_four_of_nineteen_has_explicit_recovery_reason(self):
        code, events, calls = await self.run_flow(False)
        self.assertEqual(code, 1)
        end = events[-1]
        self.assertEqual((end['reason'], end['listedCount'], end['gap'], end['cursor']),
                         ('login_required', 4, 15, None))
        self.assertEqual(len([e for e in events if e['event'] == 'post']), 4)
        self.assertEqual(len([c for c in calls if c[0].endswith('/post/')]), 1)

    async def test_authenticated_pagination_recovers_nineteen(self):
        code, events, calls = await self.run_flow(True)
        self.assertEqual(code, 0)
        end = events[-1]
        self.assertEqual((end['reason'], end['listedCount'], end['gap']), ('complete', 19, 0))
        self.assertEqual(len([e for e in events if e['event'] == 'post']), 19)
        self.assertTrue(all(auth for _, auth in calls))


if __name__ == '__main__': unittest.main()
