import asyncio
import hashlib
import io
import json
import struct
import sys
import tempfile
import unittest
import uuid
import zlib
from datetime import datetime, timezone
from pathlib import Path
from types import SimpleNamespace as N
from unittest.mock import AsyncMock, patch

sys.path[:0] = ['Backend', 'Backend/upstream/src']
import httpx
import cover_worker as covers
import photo_worker as photos
import platform_worker as platforms
import worker
from dtk.core.errors import UpstreamChanged, UpstreamRiskControl
from dtk.models import Content, Image

DOUYIN_LINK = 'https://www.douyin.com/video/7000000000000000001'
DOUYIN_COVER = 'https://p3-sign.douyinpic.com/cover.png?public-signature=fixture'


def png(width=2, height=3):
    def chunk(kind, data):
        return struct.pack('>I', len(data)) + kind + data + struct.pack('>I', zlib.crc32(kind + data))
    rows = b''.join(b'\0' + b'\x80\x40\x20' * width for _ in range(height))
    return b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', width, height, 8, 2, 0, 0, 0)) + chunk(b'IDAT', zlib.compress(rows)) + chunk(b'IEND', b'')


def content(*, cover=True, streams=False):
    stream = N(url='https://video-only.example/video.mp4', urls=[], width=720, height=1280,
               size_bytes=99999, bitrate=500000, watermark=False) if streams else None
    return N(content_id='7000000000000000001', title='平台封面', description='原始作品说明',
             duration_ms=6000, author=N(nickname='测试作者'),
             media=N(video=stream, streams=[], images=[],
                     covers=[N(url=DOUYIN_COVER, urls=[], width=2, height=3)] if cover else []))


def detail_payload(*, playable=False):
    video = {'cover': {'url_list': [DOUYIN_COVER, 'https://p9.douyinpic.com/mirror.png'],
                       'width': 2, 'height': 3}, 'duration': 6000}
    if playable:
        video['play_addr'] = {'url_list': ['https://video-only.example/video.mp4'], 'width': 720, 'height': 1280}
    return {'status_code': 0, 'aweme_detail': {'aweme_id': '7000000000000000001', 'desc': '真实模型封面\n完整说明',
            'create_time': 1700000000, 'status': {'is_delete': False, 'private_status': 0}, 'video': video,
            'author': {'sec_uid': 'MS4wLjABAAAA_SYNTHETIC_COVER_AUTHOR', 'nickname': '合成作者'}, 'statistics': {}}}


class Chunks(httpx.AsyncByteStream):
    def __init__(self, data): self.data = data
    async def __aiter__(self):
        yield self.data[:20]
        yield self.data[20:]


class CoverDownloadContracts(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='shiying-cover-tests-')
        self.root = Path(self.temporary.name).resolve()
        self.job = self.root / str(uuid.uuid4()).upper()
        self.job.mkdir(mode=0o700)
        (self.job / covers.OWNER_MARKER).write_text(self.job.name, encoding='utf-8')
        self.request = self.job / 'input.json'
        self.events = []; self.requests = []
        self.real_client = httpx.AsyncClient

    def tearDown(self): self.temporary.cleanup()

    def write_request(self, **overrides):
        data = {'id': '7000000000000000001', 'title': '平台封面', 'author': '测试作者',
                'description': '原始作品说明', 'link': DOUYIN_LINK, 'cover': DOUYIN_COVER, **overrides}
        self.request.write_text(json.dumps(data, ensure_ascii=False), encoding='utf-8')
        return self.request

    def handler(self, request):
        self.requests.append(request)
        return httpx.Response(200, headers={'content-type': 'image/png'}, content=png())

    def patched_client(self, handler):
        transport = httpx.MockTransport(handler)
        return patch.object(covers.httpx, 'AsyncClient',
            side_effect=lambda *a, **kw: self.real_client(*a, transport=transport, **kw))

    def patched_emit(self):
        return patch.object(worker, 'emit', side_effect=lambda event, **data:
                            self.events.append({'event': event, **data}))

    def run_direct(self, handler=None, **overrides):
        path = self.write_request(**overrides)
        with self.patched_client(handler or self.handler), self.patched_emit():
            asyncio.run(covers.run_cover(str(path), str(self.job)))

    def image_folders(self): return [p for p in self.job.iterdir() if p.is_dir()]

    def test_direct_cover_keeps_original_bytes_and_uses_no_video_or_detail_requests(self):
        with patch.object(worker, 'fetch', new=AsyncMock()) as fetch, \
             patch.object(platforms, 'fetch_info', new=AsyncMock()) as info, \
             patch.object(worker, 'choose_stream', side_effect=AssertionError('video selection')), \
             patch.object(worker, 'transcode', side_effect=AssertionError('video conversion')):
            self.run_direct()
        fetch.assert_not_awaited(); info.assert_not_awaited()
        self.assertEqual([str(r.url) for r in self.requests], [DOUYIN_COVER])
        self.assertNotIn('cookie', self.requests[0].headers)
        self.assertNotIn('authorization', self.requests[0].headers)
        result = self.events[-1]
        self.assertEqual((result['event'], result['mediaKind']), ('complete', 'video_cover'))
        self.assertEqual(result['video']['mediaKind'], 'video')
        self.assertEqual((result['width'], result['height'], result['duration']), (2, 3, 0))
        self.assertEqual(result['bytes'], len(png()))
        self.assertEqual(result['imageSHA256'], hashlib.sha256(png()).hexdigest())
        album = Path(result['path'])
        self.assertEqual(album.parent, self.job)
        self.assertEqual(list(album.iterdir()), [album / '001.png'])
        self.assertEqual(result['imagePaths'], [str(album / '001.png')])
        self.assertEqual((album / '001.png').read_bytes(), png())
        self.assertFalse(list(self.job.glob('.shiying-cover-*')))

    def test_douyin_preview_has_metadata_and_cover_even_without_a_video_stream(self):
        original = content(streams=False)
        with patch.object(worker, 'fetch', new=AsyncMock(return_value=(original, DOUYIN_LINK))), \
             patch.object(worker, 'choose_stream', side_effect=AssertionError('no streams needed')), \
             self.patched_client(self.handler), self.patched_emit():
            asyncio.run(covers.preview_cover(DOUYIN_LINK, str(self.job)))
        metadata = next(event for event in self.events if event['event'] == 'metadata')
        self.assertEqual(metadata['mediaKind'], 'video')
        self.assertEqual((metadata['width'], metadata['height']), (0, 0))
        self.assertEqual(metadata['description'], original.description)
        self.assertEqual(len(self.requests), 1)

    def test_douyin_preview_never_fetches_its_available_video_stream(self):
        original = content(streams=True)
        with patch.object(worker, 'fetch', new=AsyncMock(return_value=(original, DOUYIN_LINK))), \
             self.patched_client(self.handler), self.patched_emit():
            asyncio.run(covers.preview_cover(DOUYIN_LINK, str(self.job)))
        metadata = next(event for event in self.events if event['event'] == 'metadata')
        self.assertEqual((metadata['width'], metadata['height']), (720, 1280))
        self.assertEqual([r.url.host for r in self.requests], ['p3-sign.douyinpic.com'])

    def test_album_cover_is_one_image_and_metadata_remains_album(self):
        original = content()
        original.media.covers = []
        original.media.images = [N(url=DOUYIN_COVER, urls=[], width=2, height=3),
                                 N(url='https://p3-sign.douyinpic.com/unused.png', urls=[], width=2, height=3)]
        with patch.object(worker, 'fetch', new=AsyncMock(return_value=(original, DOUYIN_LINK))), \
             patch.object(photos, 'download_album', new=AsyncMock()) as album, \
             self.patched_client(self.handler), self.patched_emit():
            asyncio.run(covers.preview_cover(DOUYIN_LINK, str(self.job)))
        album.assert_not_awaited()
        self.assertEqual(self.events[-1]['video']['mediaKind'], 'image_album')
        self.assertEqual(len(self.events[-1]['imagePaths']), 1)
        self.assertEqual(len(self.requests), 1)

    def test_missing_cover_is_explicit_and_does_not_fallback_to_video(self):
        original = content(cover=False, streams=True)
        with patch.object(worker, 'fetch', new=AsyncMock(return_value=(original, DOUYIN_LINK))), \
             self.patched_client(self.handler), self.patched_emit():
            with self.assertRaisesRegex(ValueError, '未下载或转换视频'):
                asyncio.run(covers.preview_cover(DOUYIN_LINK, str(self.job)))
        self.assertFalse(self.requests)
        self.assertFalse(self.image_folders())
        self.assertTrue(any(e['event'] == 'metadata' for e in self.events))

    def test_bilibili_and_xiaohongshu_metadata_only_extractors_allow_no_formats(self):
        for platform, link, image in [('bilibili', 'https://www.bilibili.com/video/BVFixture', 'https://i0.hdslb.com/image.png'),
                                     ('xiaohongshu', 'https://www.xiaohongshu.com/explore/' + 'a' * 24, 'https://sns-img.xhscdn.com/image.png')]:
            with self.subTest(platform=platform):
                class Downloader:
                    def __enter__(self): return self
                    def __exit__(self, *args): pass
                    def extract_info(self, requested, *, download):
                        self_requested.append((requested, download))
                        return {'id': 'work', 'title': '作品封面', 'uploader': '作者', 'thumbnail': image}
                self_requested = []
                with patch.object(platforms, 'ydl', return_value=Downloader()) as extractor, \
                     patch.object(platforms, 'fetch_info', new=AsyncMock()) as video_fetch, \
                     self.patched_client(self.handler), self.patched_emit():
                    asyncio.run(covers.preview_cover(link, str(self.job), platform))
                video_fetch.assert_not_awaited()
                self.assertEqual(self_requested, [(link, False)])
                self.assertTrue(extractor.call_args.kwargs['ignore_no_formats_error'])
                self.assertTrue(extractor.call_args.kwargs['skip_download'])
                self.assertFalse(extractor.call_args.kwargs['writethumbnail'])
                self.assertEqual(self.events[-1]['mediaKind'], 'video_cover')
                self.assertEqual(self.requests[-1].url.host, httpx.URL(image).host)

    def test_wechat_official_metadata_cover_accepts_encrypted_or_missing_video(self):
        share = 'https://weixin.qq.com/sph/Fixture'
        def handler(request):
            self.requests.append(request)
            if request.url.host == 'yuanbao.tencent.com':
                return httpx.Response(201, json={'data': {'wx_export_id': 'fixture-export',
                    'playable_url': 'https://channels.weixin.qq.com/finder-preview/pages/feed?token=fixture&eid=fixture-export'}})
            if request.url.host == 'channels.weixin.qq.com':
                return httpx.Response(201, json={'errCode': 0, 'data': {'authorInfo': {'nickname': '视频号作者'},
                    'feedInfo': {'id': 'fixture', 'description': '加密视频的公开封面', 'decodeKey': 'fixture-key',
                                 'coverUrl': 'https://wx.qpic.cn/cover.png'}}})
            self.assertEqual(request.url.host, 'wx.qpic.cn')
            self.assertNotIn('cookie', request.headers)
            return httpx.Response(200, headers={'content-type': 'image/png'}, content=png())
        session = {'version': 1, 'platform': 'wechat', 'cookies': [], 'capturedPosts': []}
        with self.patched_client(handler), self.patched_emit():
            asyncio.run(covers.preview_cover(share, str(self.job), 'wechat', session))
        self.assertEqual([r.method for r in self.requests], ['POST', 'POST', 'GET'])
        self.assertEqual(self.events[-1]['video']['author'], '视频号作者')
        self.assertEqual(self.events[-1]['mediaKind'], 'video_cover')

    def test_wechat_page_cover_does_not_need_captured_media_url(self):
        link = 'https://channels.weixin.qq.com/finder-preview/pages/feed?eid=fixture'
        session = {'captureSource': link, 'capturedPosts': [{'id': 'fixture', 'title': '页面封面',
                   'author': '作者', 'link': link, 'cover': 'https://wx.qpic.cn/cover.png'}]}
        with self.patched_client(self.handler), self.patched_emit(), \
             patch.object(platforms, 'fetch_wechat_share_info', new=AsyncMock()) as share:
            asyncio.run(covers.preview_cover(link, str(self.job), 'wechat', session))
        share.assert_not_awaited()
        self.assertEqual(len(self.requests), 1)

    def test_all_direct_platforms_accept_only_their_own_image_domains(self):
        pairs = [('douyin', DOUYIN_LINK, DOUYIN_COVER),
                 ('bilibili', 'https://www.bilibili.com/video/BVFixture', 'https://i0.hdslb.com/image.png'),
                 ('xiaohongshu', 'https://www.xiaohongshu.com/explore/' + 'a' * 24, 'https://sns-img.xhscdn.com/image.png'),
                 ('wechat', 'https://weixin.qq.com/sph/Fixture', 'https://wx.qpic.cn/cover.png')]
        for platform, link, image in pairs:
            with self.subTest(platform=platform):
                identity = 'BVFixture' if platform == 'bilibili' else 'a' * 24 if platform == 'xiaohongshu' else '7000000000000000001'
                self.run_direct(id=identity, link=link, cover=image)
                with self.assertRaisesRegex(ValueError, '当前平台'):
                    self.run_direct(id=identity, link=link, cover='https://evil.example/image.png')
                other = 'https://i0.hdslb.com/image.png' if platform != 'bilibili' else DOUYIN_COVER
                with self.assertRaisesRegex(ValueError, '当前平台'):
                    self.run_direct(id=identity, link=link, cover=other)

    def test_cover_url_rejects_plain_http_credentials_private_hosts_ports_and_spoofs(self):
        for value in ['http://p3.douyinpic.com/image.png', 'https://user:password@p3.douyinpic.com/image.png',
                      'https://127.0.0.1/image.png', 'https://localhost/image.png',
                      'https://p3.douyinpic.com:80/image.png', 'https://p3.douyinpic.com.evil.example/image.png',
                      'https://evildouyinpic.com/image.png', 'https://p3.douyinpic.com/\nimage.png']:
            with self.subTest(value=value), self.assertRaises(ValueError):
                covers.cover_url(value, 'douyin')
        self.assertEqual(covers.cover_url(DOUYIN_COVER + '#ignored', 'douyin'), DOUYIN_COVER)

    def test_official_legacy_http_cover_is_upgraded_before_its_only_request(self):
        self.run_direct(id='BVFixture', link='https://www.bilibili.com/video/BVFixture', cover='http://i0.hdslb.com/legacy.png')
        self.assertEqual([str(r.url) for r in self.requests], ['https://i0.hdslb.com/legacy.png'])
        self.assertEqual(self.events[-1]['video']['cover'], 'https://i0.hdslb.com/legacy.png')
        self.assertNotIn('cookie', self.requests[0].headers)
        for value in ['http://evil.example/legacy.png', 'http://127.0.0.1/legacy.png',
                      'http://user:password@i0.hdslb.com/legacy.png', 'http://i0.hdslb.com:8080/legacy.png']:
            with self.subTest(value=value), self.assertRaises(ValueError):
                self.run_direct(id='BVFixture', link='https://www.bilibili.com/video/BVFixture', cover=value)
        self.assertEqual(len(self.requests), 1)

    def test_preview_metadata_too_large_is_rejected_without_truncation_or_download(self):
        original = content()
        original.description = '大' * covers.MAX_METADATA_BYTES
        with patch.object(worker, 'fetch', new=AsyncMock(return_value=(original, DOUYIN_LINK))), \
             self.patched_client(self.handler), self.patched_emit():
            with self.assertRaisesRegex(ValueError, '未截断'):
                asyncio.run(covers.preview_cover(DOUYIN_LINK, str(self.job)))
        self.assertFalse(self.requests)
        self.assertFalse(any(e['event'] == 'metadata' for e in self.events))

    def test_safe_redirect_is_rechecked_and_set_cookie_is_never_forwarded(self):
        def handler(request):
            self.requests.append(request)
            if request.url.path == '/cover.png':
                return httpx.Response(302, headers={'location': 'https://p9.douyinpic.com/final.png',
                                                   'set-cookie': 'secret=fixture; Domain=.douyinpic.com'})
            self.assertNotIn('cookie', request.headers)
            return httpx.Response(200, headers={'content-type': 'image/png'}, content=png())
        self.run_direct(handler)
        self.assertEqual(len(self.requests), 2)
        self.assertEqual(self.requests[-1].url.host, 'p9.douyinpic.com')

    def test_foreign_or_private_redirect_is_not_requested(self):
        for redirect in ['https://evil.example/private', 'http://p3.douyinpic.com/private', 'https://127.0.0.1/private']:
            self.requests = []
            def handler(request):
                self.requests.append(request)
                return httpx.Response(302, headers={'location': redirect})
            with self.assertRaises(ValueError): self.run_direct(handler)
            self.assertEqual(len(self.requests), 1)
            self.assertFalse(self.image_folders())

    def test_redirect_loop_is_bounded(self):
        def handler(request):
            self.requests.append(request)
            return httpx.Response(302, headers={'location': DOUYIN_COVER})
        with self.assertRaisesRegex(ValueError, '重定向过多'): self.run_direct(handler)
        self.assertEqual(len(self.requests), covers.MAX_REDIRECTS + 1)
        self.assertFalse(self.image_folders())

    def test_auth_and_rate_limit_stop_before_other_cover_mirrors(self):
        for status in [401, 403, 429]:
            self.requests = []
            original = content()
            original.media.covers[0].urls = ['https://p9.douyinpic.com/other.png']
            def handler(request): self.requests.append(request); return httpx.Response(status)
            with patch.object(worker, 'fetch', new=AsyncMock(return_value=(original, DOUYIN_LINK))), \
                 self.patched_client(handler), self.patched_emit():
                with self.assertRaisesRegex(ValueError, f'HTTP {status}'):
                    asyncio.run(covers.preview_cover(DOUYIN_LINK, str(self.job)))
            self.assertEqual(len(self.requests), 1)
            self.assertFalse(self.image_folders())

    def test_expired_primary_cover_can_use_one_public_image_mirror(self):
        original = content()
        original.media.covers[0].urls = ['https://p9.douyinpic.com/other.png']
        def handler(request):
            self.requests.append(request)
            return httpx.Response(404) if request.url.host.startswith('p3') else httpx.Response(200, headers={'content-type': 'image/png'}, content=png())
        with patch.object(worker, 'fetch', new=AsyncMock(return_value=(original, DOUYIN_LINK))), \
             self.patched_client(handler), self.patched_emit():
            asyncio.run(covers.preview_cover(DOUYIN_LINK, str(self.job)))
        self.assertEqual(len(self.requests), 2)
        self.assertEqual(self.events[-1]['mediaKind'], 'video_cover')

    def test_html_fake_image_wrong_mime_and_truncated_image_do_not_publish(self):
        for kind, payload in [('image/jpeg', b'<html>login</html>'), ('video/mp4', png()),
                              ('image/png', png()[:40]), ('image/png', b'')]:
            with self.subTest(kind=kind, payloadBytes=len(payload)):
                with self.assertRaises(ValueError):
                    self.run_direct(lambda r: httpx.Response(200, headers={'content-type': kind}, content=payload))
                self.assertFalse(self.image_folders())

    def test_content_length_mismatch_and_invalid_length_do_not_publish(self):
        for length in [str(len(png()) + 5), '-1', 'broken']:
            with self.assertRaises(ValueError):
                self.run_direct(lambda r: httpx.Response(200, headers={'content-type': 'image/png', 'content-length': length}, content=png()))
        self.assertFalse(self.image_folders())

    def test_declared_and_streamed_image_limits_do_not_truncate_or_publish(self):
        with patch.object(covers, 'MAX_IMAGE_BYTES', 16):
            with self.assertRaisesRegex(ValueError, '64 MiB'): self.run_direct()
            with self.assertRaisesRegex(ValueError, '64 MiB'):
                self.run_direct(lambda r: httpx.Response(200, headers={'content-type': 'image/png'}, stream=Chunks(png())))
        self.assertFalse(self.image_folders())

    def test_image_pixel_limit_uses_existing_decoder_before_full_decode(self):
        with patch.object(photos, 'run_media_check', return_value=json.dumps({'streams': [
            {'codec_type': 'video', 'width': 20000, 'height': 20000}]}).encode()) as decoder:
            with self.assertRaisesRegex(ValueError, '尺寸无效或过大'): self.run_direct()
        self.assertEqual(decoder.call_count, 1)
        self.assertFalse(self.image_folders())

    def test_cancel_during_transfer_or_decode_cleans_only_this_staging(self):
        sentinel = self.job / '原有文件.txt'; sentinel.write_bytes(b'preserve')
        for step in ['download', 'decode']:
            with self.subTest(step=step):
                with patch.object(photos, 'verify_image', side_effect=worker.Cancelled() if step == 'decode' else photos.verify_image):
                    def handler(request):
                        if step == 'download': raise worker.Cancelled()
                        return httpx.Response(200, headers={'content-type': 'image/png'}, content=png())
                    with self.assertRaises(worker.Cancelled): self.run_direct(handler)
                self.assertEqual(sentinel.read_bytes(), b'preserve')
                self.assertFalse(self.image_folders())
        self.assertIsNone(worker.active_child)

    def test_cancel_before_complete_undoes_only_its_just_published_cover(self):
        path = self.write_request()
        def emit(event, **data):
            if event == 'complete': raise worker.Cancelled()
        with self.patched_client(self.handler), patch.object(worker, 'emit', side_effect=emit):
            with self.assertRaises(worker.Cancelled): asyncio.run(covers.run_cover(str(path), str(self.job)))
        self.assertFalse(self.image_folders())

    def test_cover_changed_after_decode_is_rejected_against_download_byte_hash(self):
        actual_verify = photos.verify_image
        def replace_during_verify(path):
            dimensions = actual_verify(path)
            path.write_bytes(png(3, 2))
            return dimensions
        with patch.object(photos, 'verify_image', side_effect=replace_during_verify):
            with self.assertRaisesRegex(ValueError, '检查期间发生变化'): self.run_direct()
        self.assertFalse(self.image_folders())
        self.assertFalse(any(e['event'] == 'complete' for e in self.events))

    def test_cancel_does_not_delete_external_same_size_replacement_in_publication(self):
        path = self.write_request()
        changed = []
        def emit(event, **data):
            if event == 'complete':
                image = Path(data['imagePaths'][0])
                original = image.read_bytes()
                replacement = b'x' * len(original)
                image.write_bytes(replacement)
                changed.append((image, replacement))
                raise worker.Cancelled()
        with self.patched_client(self.handler), patch.object(worker, 'emit', side_effect=emit):
            with self.assertRaises(worker.Cancelled): asyncio.run(covers.run_cover(str(path), str(self.job)))
        self.assertEqual(changed[0][0].read_bytes(), changed[0][1])

    def test_existing_empty_or_populated_cover_directory_is_never_replaced(self):
        target = self.job / '测试作者_平台封面_封面_7000000000000000001'
        target.mkdir()
        self.run_direct()
        self.assertEqual(list(target.iterdir()), [])
        second = Path(self.events[-1]['path'])
        self.run_direct()
        self.assertEqual((second / '001.png').read_bytes(), png())
        self.assertNotEqual(second, Path(self.events[-1]['path']))

    def test_unowned_folder_and_symlink_job_or_marker_are_rejected_before_network(self):
        for directory in [self.root, Path('relative'), self.root / str(uuid.uuid4())]:
            with self.assertRaises(ValueError): covers.owned_folder(directory)
        marker = self.job / covers.OWNER_MARKER
        marker.write_text('wrong', encoding='utf-8')
        with self.assertRaises(ValueError): covers.owned_folder(self.job)
        marker.unlink()
        original = self.root / 'marker'; original.write_text(self.job.name, encoding='utf-8')
        marker.symlink_to(original)
        with self.assertRaises(ValueError): covers.owned_folder(self.job)
        marker.unlink(); marker.write_text(self.job.name, encoding='utf-8')
        shortcut = self.root / str(uuid.uuid4()).upper(); shortcut.symlink_to(self.job, target_is_directory=True)
        with self.assertRaises(ValueError): covers.owned_folder(shortcut)

    def test_request_must_be_bounded_regular_file_inside_same_owned_job(self):
        self.write_request()
        outside = self.root / 'outside.json'; outside.write_bytes(self.request.read_bytes())
        with self.assertRaises(ValueError): covers.read_request(outside, self.job)
        self.request.unlink(); self.request.symlink_to(outside)
        with self.assertRaises(ValueError): covers.read_request(self.request, self.job)
        self.request.unlink(); self.request.write_bytes(b' ' * (covers.MAX_REQUEST_BYTES + 1))
        with self.assertRaisesRegex(ValueError, '64 KiB'): covers.read_request(self.request, self.job)

    def test_request_rejects_lists_duplicates_extra_fields_bad_identity_and_homepages(self):
        for raw in [b'[]', b'{"id":"first","id":"second"}', b'{broken']:
            self.request.write_bytes(raw)
            with self.assertRaises(ValueError): covers.read_request(self.request, self.job)
        for change in [{'cookies': []}, {'id': '../escape'}, {'author': 123}, {'title': 'x' * 4001},
                       {'cover': None}, {'link': 'https://www.douyin.com/user/creator'},
                       {'link': 'https://www.bilibili.com/video/BVFixture', 'cover': DOUYIN_COVER}]:
            self.write_request(**change)
            with self.assertRaises(ValueError): covers.read_request(self.request, self.job)

    def test_canonical_link_identity_must_match_before_a_cover_request(self):
        for change in [{'id': '7000000000000000002'},
                       {'id': 'BVWrong', 'link': 'https://www.bilibili.com/video/BVFixture', 'cover': 'https://i0.hdslb.com/image.png'},
                       {'id': '123', 'link': 'https://www.bilibili.com/video/av456', 'cover': 'https://i0.hdslb.com/image.png'},
                       {'id': 'b' * 24, 'link': 'https://www.xiaohongshu.com/explore/' + 'a' * 24, 'cover': 'https://sns-img.xhscdn.com/image.png'},
                       {'id': 'other', 'link': 'https://weixin.qq.com/sph/Short#shiying-capture-captured', 'cover': 'https://wx.qpic.cn/image.png'}]:
            with self.subTest(change=change), self.assertRaisesRegex(ValueError, '标识与作品链接不一致'):
                self.run_direct(**change)
        self.assertFalse(self.requests)
        self.assertFalse(self.image_folders())
        for change in [{'id': 'av456', 'link': 'https://www.bilibili.com/video/av456', 'cover': 'https://i0.hdslb.com/image.png'},
                       {'id': '456', 'link': 'https://www.bilibili.com/video/av456', 'cover': 'https://i0.hdslb.com/image.png'},
                       {'id': 'A' * 24, 'link': 'https://www.xiaohongshu.com/explore/' + 'a' * 24, 'cover': 'https://sns-img.xhscdn.com/image.png'},
                       {'id': 'opaque-api-id', 'link': 'https://weixin.qq.com/sph/UnrelatedShortCode', 'cover': 'https://wx.qpic.cn/image.png'}]:
            self.write_request(**change)
            data, _, _ = covers.read_request(self.request, self.job)
            self.assertEqual(data['id'], change['id'])

    def test_pinned_parser_real_content_and_image_model_can_read_cover_without_play_addr(self):
        payload = detail_payload()
        with self.assertRaises(UpstreamChanged): worker.parse_content(payload, fetched_at=datetime.now(timezone.utc))
        parsed = covers.parse_douyin_cover(payload, fetched_at=datetime.now(timezone.utc))
        self.assertIsInstance(parsed, Content)
        self.assertIsInstance(parsed.media.covers[0], Image)
        self.assertEqual(parsed.media.covers[0].url, DOUYIN_COVER)
        self.assertEqual(parsed.media.covers[0].urls, [DOUYIN_COVER, 'https://p9.douyinpic.com/mirror.png'])
        self.assertIsNone(parsed.media.video)
        self.assertFalse(parsed.is_deleted)
        self.assertFalse(parsed.is_private)
        self.assertEqual(covers.candidates_from_content(parsed, 'douyin'), parsed.media.covers[0].urls)

    def test_cover_parser_keeps_risk_controls_and_other_required_schema(self):
        with self.assertRaises(UpstreamRiskControl):
            covers.parse_douyin_cover({'status_code': 10000}, fetched_at=datetime.now(timezone.utc))
        malformed = detail_payload(); del malformed['aweme_detail']['author']
        with self.assertRaises(UpstreamChanged) as error:
            covers.parse_douyin_cover(malformed, fetched_at=datetime.now(timezone.utc))
        self.assertEqual(error.exception.path, 'aweme_detail.author')

    def test_app_douyin_session_is_used_only_in_detail_signature_and_request_not_cover(self):
        secret = 'SYNTHETIC_APP_SESSION_DO_NOT_LOG'
        session = covers.read_douyin_session(io.BytesIO(json.dumps([
            {'name': 'sessionid', 'value': secret, 'domain': '.douyin.com', 'path': '/'}]).encode()))
        signing_session = []
        async def sign(spec, fingerprint, login):
            signing_session.append(login)
            return N(headers={}, signed_url=lambda url: url)
        def handler(request):
            self.requests.append(request)
            if request.method == 'HEAD':
                self.assertNotIn('cookie', request.headers)
                return httpx.Response(200)
            if request.url.host == 'www.douyin.com':
                self.assertEqual(request.url.path, '/aweme/v1/web/aweme/detail/')
                self.assertIn('sessionid=' + secret, request.headers.get('cookie', ''))
                return httpx.Response(200, json=detail_payload())
            self.assertEqual(request.url.host, 'p3-sign.douyinpic.com')
            self.assertNotIn('cookie', request.headers)
            self.assertNotIn('authorization', request.headers)
            return httpx.Response(200, headers={'content-type': 'image/png'}, content=png())
        with self.patched_client(handler), self.patched_emit(), \
             patch.object(worker, 'NativeSigner', return_value=N(sign=sign)):
            asyncio.run(covers.preview_cover(DOUYIN_LINK, str(self.job), 'douyin', session))
        self.assertEqual(signing_session[0].cookies['sessionid'], secret)
        self.assertEqual([r.method for r in self.requests], ['HEAD', 'GET', 'GET'])
        self.assertEqual(self.events[-1]['mediaKind'], 'video_cover')
        self.assertNotIn(secret, json.dumps(self.events))

    def test_detail_session_redirect_is_not_followed_to_foreign_host(self):
        secret = 'SYNTHETIC_APP_SESSION_DO_NOT_LOG'
        session = covers.read_douyin_session(io.BytesIO(json.dumps([
            {'name': 'sessionid', 'value': secret, 'domain': '.douyin.com', 'path': '/'}]).encode()))
        async def sign(spec, fingerprint, login): return N(headers={}, signed_url=lambda url: url)
        def handler(request):
            self.requests.append(request)
            if request.method == 'HEAD': return httpx.Response(200)
            return httpx.Response(302, headers={'location': 'https://evil.example/collect'})
        with self.patched_client(handler), self.patched_emit(), \
             patch.object(worker, 'NativeSigner', return_value=N(sign=sign)):
            with self.assertRaisesRegex(ValueError, 'HTTP 302'):
                asyncio.run(covers.preview_cover(DOUYIN_LINK, str(self.job), 'douyin', session))
        self.assertEqual(len(self.requests), 2)
        self.assertFalse(any(r.url.host == 'evil.example' for r in self.requests))
        self.assertFalse(self.image_folders())

    def test_cover_session_matches_native_array_and_envelope_and_scrubs_rejection(self):
        secret = 'SYNTHETIC_APP_SESSION_DO_NOT_LOG'
        rows = [{'name': 'sessionid', 'value': secret, 'domain': '.douyin.com', 'path': '/'}]
        for message in [rows, {'version': 1, 'platform': 'douyin', 'cookies': rows}]:
            session = covers.read_douyin_session(io.BytesIO(json.dumps(message).encode()))
            self.assertEqual(next(c.value for c in session.jar if c.name == 'sessionid'), secret)
        bad = [{'version': True, 'platform': 'douyin', 'cookies': rows},
               {'version': 1, 'platform': 'wechat', 'cookies': rows},
               [{'name': 'sessionid', 'value': secret, 'domain': '.evil.example', 'path': '/'}]]
        for message in bad:
            with self.assertRaises(ValueError) as error:
                covers.read_douyin_session(io.BytesIO(json.dumps(message).encode()))
            self.assertNotIn(secret, str(error.exception))

    def test_real_packaged_decoder_reads_full_original_image_and_releases_child(self):
        image = self.job / 'decoder.png'; image.write_bytes(png(4, 5))
        self.assertEqual(photos.verify_image(image), (4, 5))
        self.assertIsNone(worker.active_child)


class CoverEntrypointContracts(unittest.TestCase):
    def run_main(self, arguments, *contexts):
        events = []
        with patch.object(sys, 'argv', ['worker', *arguments]), \
             patch.object(worker, 'emit', side_effect=lambda event, **data: events.append({'event': event, **data})):
            result = worker.main()
        return result, events

    def test_cover_command_is_dispatched_without_requiring_link_or_platform_lookup(self):
        with patch.object(covers, 'run_cover', new=AsyncMock()) as run, \
             patch.object(platforms, 'input_url', side_effect=AssertionError('no detail lookup')):
            result, _ = self.run_main(['cover', '--input', '/job/input.json', '--folder', '/job'])
        self.assertEqual(result, 0)
        run.assert_awaited_once_with('/job/input.json', '/job')

    def test_preview_cover_routes_douyin_to_independent_cover_flow(self):
        with patch.object(covers, 'preview_cover', new=AsyncMock()) as run, \
             patch.object(worker, 'fetch', new=AsyncMock()) as video:
            result, _ = self.run_main(['info', '--link', DOUYIN_LINK, '--preview-cover', '--folder', '/job'])
        self.assertEqual(result, 0)
        run.assert_awaited_once_with(DOUYIN_LINK, '/job', 'douyin', None)
        video.assert_not_awaited()

    def test_preview_cover_reads_only_current_platform_stdin_session(self):
        link = 'https://weixin.qq.com/sph/Fixture'
        session = {'version': 1, 'platform': 'wechat', 'cookies': [], 'capturedPosts': []}
        with patch.object(covers, 'preview_cover', new=AsyncMock()) as run, \
             patch.object(platforms, 'read_session', return_value=session) as read, \
             patch.object(platforms, 'fetch_info', new=AsyncMock()) as video:
            result, _ = self.run_main(['info', '--link', link, '--preview-cover', '--folder', '/job', '--session-stdin'])
        self.assertEqual(result, 0)
        read.assert_called_once_with(sys.stdin.buffer, 'wechat')
        run.assert_awaited_once_with(link, '/job', 'wechat', session)
        video.assert_not_awaited()

    def test_preview_cover_main_reads_douyin_array_session_and_passes_validated_cookies(self):
        rows = [{'name': 'sessionid', 'value': 'SYNTHETIC', 'domain': '.douyin.com', 'path': '/'}]
        stdin = N(buffer=io.BytesIO(json.dumps(rows).encode()))
        with patch.object(covers, 'preview_cover', new=AsyncMock()) as run, patch.object(sys, 'stdin', stdin):
            result, _ = self.run_main(['info', '--link', DOUYIN_LINK, '--preview-cover', '--folder', '/job', '--session-stdin'])
        self.assertEqual(result, 0)
        self.assertEqual(run.call_args.args[:3], (DOUYIN_LINK, '/job', 'douyin'))
        self.assertIsInstance(run.call_args.args[3], httpx.Cookies)

    def test_conflicting_preview_flags_or_cover_session_are_explicit_errors(self):
        for arguments in [['info', '--link', DOUYIN_LINK, '--preview-cover', '--preview-images'],
                          ['download', '--link', DOUYIN_LINK, '--preview-cover'],
                          ['cover', '--input', '/job/input.json', '--folder', '/job', '--session-stdin']]:
            result, events = self.run_main(arguments)
            self.assertEqual(result, 1)
            self.assertEqual(events[-1]['event'], 'error')

    def test_default_info_download_and_album_preview_still_use_original_routes(self):
        original = content(streams=True)
        with patch.object(worker, 'fetch', new=AsyncMock(return_value=(original, DOUYIN_LINK))), \
             patch.object(covers, 'preview_cover', new=AsyncMock()) as cover:
            result, events = self.run_main(['info', '--link', DOUYIN_LINK])
        self.assertEqual(result, 0)
        self.assertEqual(events[-1]['event'], 'metadata')
        self.assertEqual(events[-1]['width'], 720)
        cover.assert_not_awaited()
        with patch.object(worker, 'download', new=AsyncMock()) as video, \
             patch.object(covers, 'preview_cover', new=AsyncMock()) as cover:
            result, _ = self.run_main(['download', '--link', DOUYIN_LINK, '--video-only', '--folder', '/destination', '--quality', '480'])
        self.assertEqual(result, 0)
        video.assert_awaited_once_with(DOUYIN_LINK, '480', '/destination', video_only=True)
        cover.assert_not_awaited()
        original.media.images = [N(url=DOUYIN_COVER, urls=[], width=2, height=3)]
        with patch.object(worker, 'fetch', new=AsyncMock(return_value=(original, DOUYIN_LINK))), \
             patch.object(photos, 'download_album', new=AsyncMock()) as album, \
             patch.object(covers, 'preview_cover', new=AsyncMock()) as cover:
            result, _ = self.run_main(['info', '--link', DOUYIN_LINK, '--preview-images', '--folder', '/job'])
        self.assertEqual(result, 0)
        album.assert_awaited_once_with(original, '/job')
        cover.assert_not_awaited()


if __name__ == '__main__': unittest.main()
