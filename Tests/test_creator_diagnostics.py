"""Faults must preserve results, identify the failed page, and never expose credentials."""
import io
import json
import sys
import unittest
import tempfile
from pathlib import Path
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
sys.path[:0] = [str(ROOT / 'Backend'), str(ROOT / 'Backend/upstream/src')]
import httpx
import creator_worker as scanner
from test_creator_session import SEC, HOME, SECRET, post


class DiagnosticsTests(unittest.IsolatedAsyncioTestCase):
    async def scan(self, response, *, count=2, **kwargs):
        events, calls = [], []
        def handler(request):
            if request.url.path == '/': return httpx.Response(200)
            if request.url.path.endswith('/profile/other/'):
                return httpx.Response(200, json={'status_code': 0, 'user': {'sec_uid': SEC, 'nickname': '合成', 'aweme_count': count}})
            calls.append(request.url.params.get('max_cursor', '0'))
            return response(request, calls)
        cookies = scanner.read_session(io.BytesIO(json.dumps([dict(name='sessionid', value=SECRET, domain='.douyin.com', path='/')]).encode()))
        with patch.object(scanner, 'emit_event', side_effect=lambda event, **kw: events.append(dict(event=event, **kw))):
            async with httpx.AsyncClient(transport=httpx.MockTransport(handler)) as client:
                code = await scanner.run_scan(HOME, client=client, session_cookies=cookies, pause_seconds=0, retry_delays=(0, 0), **kwargs)
        self.assertNotIn(SECRET, json.dumps(events) + json.dumps(scanner.last_notes))
        return code, events, calls

    async def test_second_page_status_only_has_precise_cause_and_retains_cursor(self):
        def response(request, calls):
            if calls[-1] == '0':
                return httpx.Response(200, json={'status_code': 0, 'aweme_list': [post(1)], 'has_more': 1, 'max_cursor': 50})
            return httpx.Response(200, json={'status_code': 0})
        code, events, calls = await self.scan(response)
        self.assertEqual(calls, ['0', '50', '50', '50'])
        end = events[-1]
        self.assertEqual((code, end['complete'], end['cursor'], end['received']), (1, False, '50', 1))
        self.assertEqual(end['diagnostic']['code'], 'missing_posts')
        self.assertEqual(end['diagnostic']['page'], 2)
        self.assertEqual(end['diagnostic']['attempts'], 3)
        self.assertEqual(end['diagnostic']['httpStatus'], 200)
        self.assertEqual(end['diagnostic']['missingFields'], ['aweme_list'])
        self.assertTrue(end['diagnostic']['sessionAttached'])
        self.assertIn('抖音未说明原因', end['message'])

    async def test_transient_status_only_retries_same_page_without_losing_posts(self):
        def response(request, calls):
            if len(calls) == 1: return httpx.Response(200, json={'status_code': 0})
            return httpx.Response(200, json={'status_code': 0, 'aweme_list': [post(1), post(2)], 'has_more': 0})
        code, events, calls = await self.scan(response)
        self.assertEqual(calls, ['0', '0'])
        self.assertEqual(code, 0)
        self.assertTrue(events[-1]['complete'])
        self.assertEqual(len([e for e in events if e['event'] == 'post']), 2)

    async def test_http_forbidden_is_not_retried_or_mislabelled_as_logout(self):
        code, events, calls = await self.scan(lambda req, calls: httpx.Response(403, text=SECRET))
        self.assertEqual(len(calls), 1)
        self.assertEqual(events[-1]['diagnostic']['httpStatus'], 403)
        self.assertEqual(events[-1]['diagnostic']['code'], 'http_status')
        self.assertNotEqual(events[-1]['reason'], 'login_required')

    async def test_html_response_identifies_format_without_echoing_body(self):
        code, events, calls = await self.scan(lambda req, calls: httpx.Response(200, text='<html>' + SECRET + '</html>'))
        self.assertEqual(len(calls), 1)
        self.assertEqual(events[-1]['diagnostic']['responseKind'], 'html')
        self.assertIn('HTML', events[-1]['message'])

    async def test_missing_next_cursor_is_explicit_and_does_not_retry(self):
        code, events, calls = await self.scan(lambda req, calls: httpx.Response(200, json={'aweme_list': [post(1)], 'has_more': 1}))
        self.assertEqual(len(calls), 1)
        self.assertEqual(events[-1]['diagnostic']['code'], 'missing_cursor')
        self.assertIn('max_cursor', events[-1]['message'])

    async def test_timeout_retries_boundedly_and_reports_page(self):
        def timeout(req, calls): raise httpx.ReadTimeout(SECRET, request=req)
        code, events, calls = await self.scan(timeout)
        self.assertEqual(len(calls), 3)
        self.assertEqual(events[-1]['diagnostic']['code'], 'timeout')
        self.assertEqual(events[-1]['diagnostic']['page'], 1)

    async def test_empty_and_temporary_http_failures_keep_first_page_and_retry_same_cursor(self):
        for status, expected in [(200, 'empty_response'), (429, 'http_status'), (503, 'http_status')]:
            with self.subTest(status=status):
                def response(request, calls):
                    if calls[-1] == '0':
                        return httpx.Response(200, json={'aweme_list': [post(1)], 'has_more': 1, 'max_cursor': 50})
                    return httpx.Response(status, content=b'' if status == 200 else SECRET.encode())
                code, events, calls = await self.scan(response)
                end = events[-1]
                self.assertEqual(calls, ['0', '50', '50', '50'])
                self.assertEqual((code, end['complete'], end['received'], end['cursor']), (1, False, 1, '50'))
                self.assertEqual((end['diagnostic']['code'], end['diagnostic']['httpStatus'], end['diagnostic']['page']), (expected, status, 2))

    async def test_missing_has_more_is_explicit_and_never_claims_complete(self):
        code, events, calls = await self.scan(lambda req, calls: httpx.Response(200, json={'aweme_list': [post(1)]}))
        self.assertEqual((code, len(calls), events[-1]['complete']), (1, 1, False))
        self.assertEqual(events[-1]['diagnostic']['code'], 'missing_pagination')
        self.assertEqual(events[-1]['diagnostic']['missingFields'], ['has_more'])

    async def test_resume_after_second_page_failure_recovers_without_duplicate_posts(self):
        def failure(request, calls):
            if calls[-1] == '0':
                return httpx.Response(200, json={'aweme_list': [post(1)], 'has_more': 1, 'max_cursor': 50})
            return httpx.Response(200, json={'status_code': 0})
        _, partial, _ = await self.scan(failure)
        code, recovered, calls = await self.scan(lambda req, calls: httpx.Response(200, json={
            'aweme_list': [post(1), post(2)], 'has_more': 0}),
            resume_cursor=partial[-1]['cursor'], seen_ids={post(1)['aweme_id']})
        self.assertEqual((code, calls, recovered[-1]['listedCount'], recovered[-1]['received']), (0, ['50'], 2, 1))
        self.assertTrue(recovered[-1]['complete'])
        self.assertEqual([e['post']['id'] for e in recovered if e['event'] == 'post'], [post(2)['aweme_id']])

    async def test_request_preparation_failure_is_not_retried_and_exposes_only_exception_type(self):
        original = scanner.signed_get
        async def fail_posts(client, url, params, path):
            if path.endswith('/post/'):
                with patch.object(scanner.NativeSigner, 'sign', side_effect=TypeError(SECRET)):
                    return await original(client, url, params, path)
            return await original(client, url, params, path)
        with patch.object(scanner, 'signed_get', side_effect=fail_posts):
            code, events, calls = await self.scan(lambda req, calls: httpx.Response(200, json={}))
        self.assertEqual((code, calls, events[-1]['diagnostic']['attempts']), (1, [], 1))
        self.assertEqual(events[-1]['diagnostic']['code'], 'request_preparation')
        self.assertEqual(events[-1]['diagnostic']['errorType'], 'TypeError')

    async def test_explicit_accepted_coauthor_is_preserved_and_counted_separately(self):
        shared = post(3)
        shared['author']['sec_uid'] = 'MS4wLjABAAAA_OTHER_PUBLISHER_0001'
        shared['author']['nickname'] = '原发布者'
        shared['cooperation_info'] = {'co_creators': [{'sec_uid': SEC, 'invite_status': 1}]}
        code, events, _ = await self.scan(lambda req, calls: httpx.Response(200, json={
            'aweme_list': [post(1), post(2), shared], 'has_more': 0}))
        self.assertEqual(code, 0)
        self.assertEqual((events[-1]['primaryCount'], events[-1]['coauthoredCount'], events[-1]['gap']), (2, 1, 0))
        shared_event = [e['post'] for e in events if e['event'] == 'post'][-1]
        self.assertTrue(shared_event['isCoauthored'])
        self.assertEqual(shared_event['author'], '原发布者')
        shared['cooperation_info']['co_creators'][0]['invite_status'] = 0
        page = scanner.interpret_posts({'aweme_list': [shared], 'has_more': 0}, SEC)
        self.assertEqual(page['author_skipped'], 1)

    async def test_resume_retains_coauthor_count_without_claiming_missing_primary_is_complete(self):
        code, events, _ = await self.scan(lambda req, calls: httpx.Response(200, json={
            'aweme_list': [post(2)], 'has_more': 0}), resume_cursor='50',
            seen_ids={post(1)['aweme_id'], post(3)['aweme_id']}, seen_coauthored_ids={post(3)['aweme_id']})
        self.assertEqual(code, 0)
        self.assertEqual(events[-1]['listedCount'], 3)
        self.assertEqual(events[-1]['primaryCount'], 2)

    def test_resume_file_provenance_validation(self):
        with tempfile.TemporaryDirectory() as root:
            path = Path(root) / 'state.json'
            path.write_text(json.dumps({'version': 2, 'ids': ['1', '2'], 'coauthoredIDs': ['2']}))
            self.assertEqual(scanner.load_seen_state(str(path)), ({'1', '2'}, {'2'}))
            path.write_text(json.dumps({'version': 2, 'ids': ['1'], 'coauthoredIDs': ['2']}))
            with self.assertRaises(ValueError): scanner.load_seen_state(str(path))


if __name__ == '__main__': unittest.main()
