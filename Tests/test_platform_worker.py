import asyncio
import io
import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch
import httpx

sys.path.insert(0, 'Backend')
import platform_worker as platforms
import worker


def session(platform, **extra):
    return {'version': 1, 'platform': platform, 'cookies': [], **extra}


class PlatformContracts(unittest.TestCase):
    def test_wechat_official_share_protocol_and_cookie_scope(self):
        share = 'https://weixin.qq.com/sph/Example'
        cookies = [{'name': 'hy_user', 'value': 'user-private', 'domain': '.yuanbao.tencent.com', 'path': '/'},
                   {'name': 'hy_token', 'value': 'token-private', 'domain': '.yuanbao.tencent.com', 'path': '/'},
                   {'name': 'wechat_cookie', 'value': 'wechat-private', 'domain': '.weixin.qq.com', 'path': '/'}]
        data = platforms.read_session(io.BytesIO(json.dumps(session('wechat', cookies=cookies)).encode()), 'wechat')
        calls = []
        def handler(request):
            calls.append(request)
            body = json.loads(request.content)
            if request.url.host == 'yuanbao.tencent.com':
                self.assertEqual(body, {'type': 'video_channel_url', 'url': share, 'scene': 1})
                self.assertIn('hy_token=token-private', request.headers.get('cookie', ''))
                self.assertNotIn('wechat-private', request.headers.get('cookie', ''))
                return httpx.Response(200, json={'data': {'wx_export_id': 'export-1',
                    'playable_url': 'https://channels.weixin.qq.com/finder-preview/pages/feed?token=preview-secret&eid=export-1'}})
            self.assertEqual(request.url.host, 'channels.weixin.qq.com')
            self.assertEqual(body, {'baseReq': {'generalToken': 'preview-secret'}, 'exportId': 'export-1'})
            self.assertNotIn('hy_token', request.headers.get('cookie', ''))
            self.assertIn('wechat_cookie=wechat-private', request.headers.get('cookie', ''))
            return httpx.Response(201, json={'errCode': 0, 'data': {'authorInfo': {'nickname': '真实作者'},
                'feedInfo': {'id': 'post-1', 'description': '实际作品', 'createtime': 123456,
                    'h264VideoInfo': {'videoUrl': 'https://finder.video.qq.com/file.mp4?key=private', 'width': 1080, 'height': 1920}}}})
        async def execute():
            async with httpx.AsyncClient(cookies=platforms.cookie_jar(data), transport=httpx.MockTransport(handler)) as client:
                return await platforms.fetch_wechat_share_info(share + '#shiying-capture-post-1', data, client=client)
        info = asyncio.run(execute())
        self.assertEqual(len(calls), 2)
        self.assertEqual(info['uploader'], '真实作者')
        self.assertEqual((info['formats'][0]['width'], info['formats'][0]['height']), (1080, 1920))
        self.assertEqual(info['duration'], 0)
        self.assertEqual(info['webpage_url'], share)

    def test_wechat_share_scan_identity_can_reenter_download_route(self):
        link = 'https://weixin.qq.com/sph/Example'
        info = {'id': 'real-post-123', 'title': '视频', 'uploader': '作者',
                'formats': [{'url': 'https://finder.video.qq.com/file.mp4', 'vcodec': 'h264'}]}
        async def fake_fetch(share, session=None): return info
        events = []
        with patch.object(platforms, 'fetch_wechat_share_info', fake_fetch), \
             patch.object(worker, 'emit', lambda event, **data: events.append({'event': event, **data})):
            self.assertEqual(asyncio.run(platforms.run_scan(link, 'wechat')), 0)
            post = next(e['post'] for e in events if e['event'] == 'post')
            self.assertEqual(post['link'], link + '#shiying-capture-real-post-123')
            self.assertTrue(platforms.is_wechat_share(post['link']))
            self.assertNotIn('mediaURL', post)
            fetched, requested = asyncio.run(platforms.fetch_info(post['link'], 'wechat'))
            self.assertEqual(fetched['id'], post['id'])
            self.assertEqual(requested, post['link'])
            self.assertFalse(events[-1]['complete'])
            self.assertEqual(events[-1]['reason'], 'share_resolved')

    def test_wechat_unauthorized_and_foreign_playable_fail_closed(self):
        async def execute(payload, status=200):
            async with httpx.AsyncClient(transport=httpx.MockTransport(lambda req: httpx.Response(status, json=payload))) as client:
                return await platforms.fetch_wechat_share_info('https://weixin.qq.com/sph/Example', client=client)
        with self.assertRaises(platforms.PlatformAccessError) as exc:
            asyncio.run(execute({'error': 'private'}, status=401))
        self.assertEqual(exc.exception.reason, 'login_required')
        self.assertNotIn('private', str(exc.exception))
        self.assertEqual(exc.exception.diagnostic['httpStatus'], 401)
        self.assertEqual(exc.exception.diagnostic['stage'], '分享解析')
        with self.assertRaises(platforms.PlatformAccessError) as exc:
            asyncio.run(execute({'error': 'private'}, status=403))
        self.assertEqual(exc.exception.reason, 'restricted')
        self.assertEqual(exc.exception.diagnostic['httpStatus'], 403)
        self.assertNotIn('private', str(exc.exception))
        with self.assertRaises(platforms.PlatformAccessError) as exc:
            asyncio.run(execute({'data': {'wx_export_id': 'one', 'playable_url': 'https://evil.example/?token=secret&eid=one'}}))
        self.assertEqual(exc.exception.reason, 'bad_json')
        self.assertNotIn('secret', str(exc.exception))

    def test_wechat_preview_rejects_unavailable_nonvideo_and_encryption(self):
        for feed, reason in (({'picInfo': [{'url': 'https://qpic.cn/picture.jpg'}]}, 'non_video'),
                             ({'decodeKey': 'secret'}, 'encrypted')):
            with self.assertRaises(platforms.PlatformAccessError) as exc:
                platforms._wechat_feed_info({'errCode': 0, 'data': {'feedInfo': feed}}, 'https://weixin.qq.com/sph/Example')
            self.assertEqual(exc.exception.reason, reason)
        with self.assertRaises(platforms.PlatformAccessError) as exc:
            platforms._wechat_feed_info({'errCode': 0, 'data': {'errMsg': {'type': 1, 'title': 'private'}}}, 'https://weixin.qq.com/sph/Example')
        self.assertEqual(exc.exception.reason, 'restricted')

    def test_wechat_transient_server_failure_recovers_with_bounded_retries(self):
        requests, events, waits = [], [], []
        def handler(request):
            requests.append(request)
            if len(requests) < 3:
                return httpx.Response(503, json={'message': 'private server detail'})
            return httpx.Response(201, json={'errCode': 0})
        async def sleep(delay): waits.append(delay)
        async def execute():
            async with httpx.AsyncClient(transport=httpx.MockTransport(handler)) as client:
                return await platforms._wechat_post(client, 'https://channels.weixin.qq.com/finder-preview/api/feed/get_feed_info',
                    '官方预览', json={'baseReq': {'generalToken': 'private-preview'}})
        with patch.object(platforms.asyncio, 'sleep', sleep), patch.object(worker, 'emit', lambda event, **data: events.append(data)):
            response = asyncio.run(execute())
        self.assertEqual(response.status_code, 201)
        self.assertEqual(response.extensions['shiying_attempts'], 3)
        self.assertEqual(waits, [.5, 1.0])
        self.assertEqual(len(requests), 3)
        self.assertEqual(len(events), 2)
        self.assertNotIn('private', json.dumps(events))

    def test_wechat_transport_failure_stops_and_scrubs_credentials(self):
        calls = []
        def handler(request):
            calls.append(request)
            raise httpx.ReadTimeout('private-token-value', request=request)
        async def sleep(delay): pass
        async def execute():
            async with httpx.AsyncClient(transport=httpx.MockTransport(handler)) as client:
                return await platforms.fetch_wechat_share_info('https://weixin.qq.com/sph/Example', client=client)
        with patch.object(platforms.asyncio, 'sleep', sleep), patch.object(worker, 'emit'):
            with self.assertRaises(platforms.PlatformAccessError) as exc:
                asyncio.run(execute())
        self.assertEqual(len(calls), 3)
        self.assertEqual(exc.exception.reason, 'network')
        self.assertEqual(exc.exception.diagnostic['attempts'], 3)
        self.assertNotIn('private-token', str(exc.exception))
        self.assertNotIn('private-token', json.dumps(exc.exception.diagnostic))

    def test_wechat_auth_rate_limit_and_bad_payload_are_not_retried(self):
        for status, body in [(401, '{}'), (403, '{}'), (429, '{}'), (200, '<html>private-body</html>')]:
            calls = []
            def handler(request):
                calls.append(request)
                return httpx.Response(status, text=body)
            async def execute():
                async with httpx.AsyncClient(transport=httpx.MockTransport(handler)) as client:
                    return await platforms.fetch_wechat_share_info('https://weixin.qq.com/sph/Example', client=client)
            with patch.object(platforms.asyncio, 'sleep') as sleep:
                with self.assertRaises(platforms.PlatformAccessError) as exc:
                    asyncio.run(execute())
            self.assertEqual(len(calls), 1)
            sleep.assert_not_called()
            self.assertNotIn('private-body', str(exc.exception))

    def test_wechat_persistent_server_failure_reports_final_attempt(self):
        calls = []
        def handler(request):
            calls.append(request)
            return httpx.Response(502, json={'error': 'private-response'})
        async def sleep(delay): pass
        async def execute():
            async with httpx.AsyncClient(transport=httpx.MockTransport(handler)) as client:
                return await platforms.fetch_wechat_share_info('https://weixin.qq.com/sph/Example', client=client)
        with patch.object(platforms.asyncio, 'sleep', sleep), patch.object(worker, 'emit'):
            with self.assertRaises(platforms.PlatformAccessError) as exc:
                asyncio.run(execute())
        self.assertEqual(len(calls), 3)
        self.assertEqual(exc.exception.diagnostic['httpStatus'], 502)
        self.assertEqual(exc.exception.diagnostic['attempts'], 3)
        self.assertNotIn('private-response', str(exc.exception))

    def test_platform_hosts_tokens_and_capture_identity(self):
        link = 'https://www.xiaohongshu.com/explore/674051740000000007027a15?xsec_token=abc%2B%3D&xsec_source=pc_user'
        self.assertEqual(platforms.input_url('分享 ' + link), ('xiaohongshu', link))
        captured = 'https://channels.weixin.qq.com/platform#shiying-capture-abc_1'
        self.assertEqual(platforms.input_url(captured)[1], captured)
        self.assertEqual(platforms.input_url('douyin.com/user/MS4wLjAB12345678')[0], 'douyin')
        for bad in ('https://bilibili.com.evil.test/video/BV123', 'https://user:secret@www.bilibili.com/video/BV123',
                    'https://www.bilibili.com:8899/video/BV123', 'http://127.0.0.1/video', 'file:///tmp/video'):
            with self.assertRaises(ValueError): platforms.input_url(bad)
        with self.assertRaises(ValueError): platforms.input_url(link, 'bilibili')

    def test_session_isolation_and_secret_rejection(self):
        good = session('bilibili', cookies=[{'name': 'SESSDATA', 'value': 'opaque', 'domain': '.bilibili.com', 'path': '/'}])
        read = lambda value, platform='bilibili': platforms.read_session(io.BytesIO(json.dumps(value).encode()), platform)
        self.assertEqual(read(good)['cookies'][0]['name'], 'SESSDATA')
        for bad in (session('wechat'), {**good, 'version': 2},
                    {**good, 'cookies': [{**good['cookies'][0], 'domain': '.xiaohongshu.com'}]},
                    {**good, 'cookies': [{**good['cookies'][0], 'value': 'secret\nheader'}]}):
            with self.assertRaises(ValueError) as exc: read(bad)
            self.assertNotIn('secret', str(exc.exception))
        with self.assertRaises(ValueError): platforms.read_session(io.BytesIO(b' ' * (platforms.SESSION_MAX_BYTES + 1)), 'bilibili')

    def test_capture_is_bound_to_source_and_plain_media(self):
        page = 'https://channels.weixin.qq.com/platform?creator=abc'
        post = {'id': 'one', 'link': page + '#shiying-capture-one', 'mediaURL': 'https://finder.video.qq.com/video.mp4?token=secret',
                'title': '实际视频', 'author': '作者', 'isVideo': True, 'diggCount': None}
        data = session('wechat', captureSource=page, capturedPosts=[post, post])
        result = platforms.captured_posts(page, 'wechat', data)
        self.assertEqual(len(result), 1)
        self.assertIsNone(result[0]['diggCount'])
        self.assertEqual(result[0]['link'], post['link'])
        for raw in ('blob:actual', 'http://finder.video.qq.com/video.mp4', 'https://evil.qq.com/video.mp4',
                    'https://finder.video.qq.com.evil.test/video.mp4'):
            self.assertEqual(platforms.captured_posts(page, 'wechat', {**data, 'capturedPosts': [{**post, 'mediaURL': raw}]}), [])
        self.assertEqual(platforms.captured_posts(page, 'wechat', {**data, 'capturedPosts': [{**post, 'decodeKey': 'opaque'}]}), [])
        with self.assertRaises(ValueError): platforms.captured_posts(page.replace('abc', 'different'), 'wechat', data)

    def test_visible_scan_never_claims_full_account(self):
        link = 'https://channels.weixin.qq.com/platform'
        events = []
        with patch.object(worker, 'emit', lambda event, **data: events.append({'event': event, **data})):
            code = asyncio.run(platforms.run_scan(link, 'wechat'))
        self.assertEqual(code, 1)
        final = events[-1]
        self.assertFalse(final['complete'])
        self.assertEqual(final['reason'], 'login_required')

    def test_xhs_state_preserves_security_token_and_unknown_counts(self):
        identity = '674051740000000007027a15'
        state = {'user': {'userPageData': {'basicInfo': {'nickname': '博主'}}, 'notes': [[
            {'id': identity, 'xsecToken': 'ab+=', 'noteCard': {'type': 'video', 'displayTitle': '视频',
             'user': {'nickname': '博主'}, 'interactInfo': {'likedCount': '1.2万'}}}]]}}
        name, posts = platforms.xhs_state_posts(state)
        self.assertEqual(name, '博主')
        self.assertIn('xsec_token=ab%2B%3D', posts[0]['link'])
        self.assertIsNone(posts[0]['diggCount'])
        self.assertIsNone(posts[0]['createdAt'])
        self.assertTrue(posts[0]['isVideo'])

    def test_format_choice_pairs_dash_audio_and_respects_short_side(self):
        formats = [{'format_id': 'high', 'url': 'v', 'width': 1920, 'height': 1080, 'vcodec': 'h264', 'acodec': 'none'},
                   {'format_id': 'mid', 'url': 'v', 'width': 1280, 'height': 720, 'vcodec': 'h264', 'acodec': 'none'},
                   {'format_id': 'low', 'url': 'v', 'width': 640, 'height': 360, 'vcodec': 'h264', 'acodec': 'aac'},
                   {'format_id': 'audio', 'url': 'a', 'vcodec': 'none', 'acodec': 'aac', 'abr': 128}]
        chosen, audio = platforms.select_formats({'formats': formats}, '720')
        self.assertEqual(chosen['format_id'], 'mid')
        self.assertEqual(audio['format_id'], 'audio')
        self.assertEqual(platforms.select_formats({'formats': formats}, 'highest')[0]['format_id'], 'high')
        chosen, audio = platforms.select_formats({'formats': [formats[2]]}, '720')
        self.assertEqual((chosen['width'], chosen['height']), (640, 360))
        self.assertIsNone(audio)
        with self.assertRaises(ValueError): platforms.select_formats({'formats': formats[:1]}, 'highest')

    def test_bilibili_resume_counts_duplicate_pages_and_limit(self):
        events = []
        rows = [{'bvid': 'BV' + str(n), 'author': '作者', 'mid': 12, 'title': str(n), 'created': 123} for n in range(31)]
        class Downloader:
            def __enter__(self): return self
            def __exit__(self, *args): pass
        def api(adapter, url, uid, **kwargs):
            pn = kwargs['query']['pn']
            return {'code': 0, 'data': {'page': {'count': 31}, 'list': {'vlist': rows[:30] if pn == 1 else rows[30:]}}}
        from yt_dlp.extractor.bilibili import BilibiliSpaceVideoIE
        with patch.object(platforms, 'ydl', return_value=Downloader()), \
             patch.object(BilibiliSpaceVideoIE, 'initialize'), \
             patch.object(BilibiliSpaceVideoIE, '_download_json', api), \
             patch.object(BilibiliSpaceVideoIE, '_sign_wbi', lambda self, query, uid: query), \
             patch.object(worker, 'emit', lambda event, **data: events.append({'event': event, **data})):
            self.assertEqual(asyncio.run(platforms.run_scan('https://space.bilibili.com/12', 'bilibili', page_limit=1)), 1)
            self.assertEqual(events[-1]['reason'], 'limit')
            self.assertEqual(events[-1]['cursor'], '2')
            seen = {p['post']['id'] for p in events if p['event'] == 'post'}
            events.clear()
            self.assertEqual(asyncio.run(platforms.run_scan('https://space.bilibili.com/12', 'bilibili', resume_cursor='2', seen_ids=seen)), 0)
            self.assertTrue(events[-1]['complete'])
            self.assertEqual(events[-1]['listedCount'], 31)
            self.assertEqual(events[-1]['received'], 1)

    def test_download_remux_quality_collision_and_staging_cleanup(self):
        """Exercise real bundled FFmpeg while replacing only the network transfer."""
        with tempfile.TemporaryDirectory(prefix='shiying-platform-test-') as root:
            root = Path(root)
            fixture = root / 'fixture.mp4'
            subprocess.run([worker.tool('ffmpeg'), '-v', 'error', '-f', 'lavfi', '-i', 'color=c=blue:s=1280x720:r=10',
                '-f', 'lavfi', '-i', 'sine=frequency=440', '-t', '1', '-c:v', 'libx264', '-preset', 'ultrafast',
                '-c:a', 'aac', '-pix_fmt', 'yuv420p', str(fixture)], check=True)
            out = root / 'out'; out.mkdir()
            info = {'id': 'BVTest', 'title': '标题', 'uploader': '作者', 'duration': 1,
                    'formats': [{'url': 'https://example.test/v.mp4', 'width': 1280, 'height': 720,
                                 'vcodec': 'h264', 'acodec': 'aac', 'ext': 'mp4'}]}
            async def fake_fetch(*args): return info, 'https://www.bilibili.com/video/BVTest'
            class Downloader:
                params = {}
                def __enter__(self): return self
                def __exit__(self, *args): pass
                def process_info(self, item): shutil.copyfile(fixture, self.params['outtmpl']['default'])
            events = []
            with patch.object(platforms, 'fetch_info', fake_fetch), patch.object(platforms, 'ydl', return_value=Downloader()), \
                 patch.object(worker, 'emit', lambda event, **data: events.append({'event': event, **data})):
                for _ in range(2): asyncio.run(platforms.download('unused', 'bilibili', '480', str(out)))
                completed = [e for e in events if e['event'] == 'complete']
                self.assertEqual(len(completed), 2)
                self.assertNotEqual(completed[0]['path'], completed[1]['path'])
                self.assertEqual((completed[0]['width'], completed[0]['height']), (854, 480))
                self.assertEqual(len(list(out.glob('*.mp4'))), 2)
                self.assertEqual(list(out.glob('.shiying-*')), [])
                def aborted(self, item): raise worker.Cancelled()
                with patch.object(Downloader, 'process_info', aborted):
                    with self.assertRaises(worker.Cancelled): asyncio.run(platforms.download('unused', 'bilibili', '720', str(out)))
                self.assertEqual(list(out.glob('.shiying-*')), [])
                self.assertEqual(len(list(out.glob('*.mp4'))), 2)

    def test_cancel_terminates_owned_media_child(self):
        child = subprocess.Popen([sys.executable, '-c', 'import time; time.sleep(60)'])
        worker.active_child = child
        try:
            with self.assertRaises(worker.Cancelled): worker.cancel(15, None)
            self.assertIsNotNone(child.poll())
        finally:
            if child.poll() is None: child.kill(); child.wait()
            worker.active_child = None

    def test_wechat_complete_decode_rejects_corrupt_packets_without_publication(self):
        with tempfile.TemporaryDirectory(prefix='shiying-wechat-decode-') as root:
            root = Path(root)
            fixture = root / 'fixture.mp4'
            subprocess.run([worker.tool('ffmpeg'), '-v', 'error', '-f', 'lavfi', '-i', 'color=c=blue:s=160x90:r=10',
                '-f', 'lavfi', '-i', 'sine=frequency=440', '-t', '1', '-c:v', 'libx264', '-preset', 'ultrafast',
                '-c:a', 'aac', '-pix_fmt', 'yuv420p', str(fixture)], check=True)
            events = []
            with patch.object(worker, 'emit', lambda event, **data: events.append({'event': event, **data})):
                platforms.verify_complete_media(fixture, 1)
            self.assertEqual(events[-1]['progress'], 1)
            self.assertIsNone(worker.active_child)
            packets = json.loads(subprocess.run([worker.tool('ffprobe'), '-v', 'error', '-select_streams', 'v:0',
                '-show_entries', 'packet=pos,size', '-of', 'json', str(fixture)], capture_output=True, text=True, check=True).stdout)['packets']
            raw = bytearray(fixture.read_bytes())
            # Keep the MP4 index and early frames intact; damage a late video packet.
            packet = packets[-1]; offset, length = int(packet['pos']), int(packet['size'])
            raw[offset + 4:offset + length] = b'\x00' * (length - 4)
            damaged = root / 'damaged.mp4'; damaged.write_bytes(raw)
            # The intact MP4 index still passes ffprobe, so metadata alone is insufficient.
            self.assertEqual(worker.probe(damaged)[:2], (160, 90))
            info = {'id': 'one', 'title': '损坏媒体', 'uploader': '作者', 'duration': 1,
                    'formats': [{'url': 'https://finder.video.qq.com/file.mp4', 'vcodec': 'h264', 'acodec': 'aac', 'ext': 'mp4'}]}
            async def fetch(*args): return info, 'https://weixin.qq.com/sph/Example'
            class Downloader:
                params = {}
                def __enter__(self): return self
                def __exit__(self, *args): pass
                def process_info(self, item): shutil.copyfile(damaged, self.params['outtmpl']['default'])
            out = root / 'out'; out.mkdir(); events.clear()
            with patch.object(platforms, 'fetch_info', fetch), patch.object(platforms, 'ydl', return_value=Downloader()), \
                 patch.object(worker, 'emit', lambda event, **data: events.append({'event': event, **data})):
                with self.assertRaisesRegex(ValueError, '完整解码检查未通过'):
                    asyncio.run(platforms.download('unused', 'wechat', 'highest', str(out)))
            self.assertEqual(list(out.iterdir()), [])
            self.assertFalse(any(event['event'] == 'complete' for event in events))
            self.assertIsNone(worker.active_child)


if __name__ == '__main__': unittest.main()
