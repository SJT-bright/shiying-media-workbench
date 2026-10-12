import asyncio
import json
import struct
import sys
import tempfile
import unittest
import zlib
from pathlib import Path
from types import SimpleNamespace as N
from unittest.mock import patch, AsyncMock

sys.path[:0] = ['Backend', 'Backend/upstream/src']
import httpx
import photo_worker as photos
import worker

def png(width=2, height=3):
    def chunk(kind, data):
        return struct.pack('>I', len(data)) + kind + data + struct.pack('>I', zlib.crc32(kind + data))
    rows = b''.join(b'\0' + b'\x80\x40\x20' * width for _ in range(height))
    return b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', width, height, 8, 2, 0, 0, 0)) + chunk(b'IDAT', zlib.compress(rows)) + chunk(b'IEND', b'')

def album(count=2):
    return N(content_id='7000000000000000001', title='合成图文', description='原始说明',
             author=N(nickname='测试作者'), media=N(images=[N(url=f'https://images.example/{i}', urls=[], width=2, height=3) for i in range(count)]))

class PhotoDownloadContracts(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='shiying-photo-tests-')
        self.root = Path(self.temporary.name)
        self.events = []
        self.real_client = httpx.AsyncClient
    def tearDown(self):
        self.temporary.cleanup()
    def run_download(self, handler, content=None):
        transport = httpx.MockTransport(handler)
        with patch.object(photos.httpx, 'AsyncClient', side_effect=lambda *a, **kw: self.real_client(*a, transport=transport, **kw)), \
             patch.object(worker, 'emit', side_effect=lambda event, **data: self.events.append(dict(event=event, **data))):
            asyncio.run(photos.download_album(content or album(), str(self.root)))
    def success(self, request):
        return httpx.Response(200, headers={'content-type':'image/png'}, content=png())
    def test_worker_info_recognizes_album_without_video_stream(self):
        info = worker.summary(album())
        self.assertEqual(info['mediaKind'], 'image_album')
        self.assertEqual(len(info['images']), 2)
        self.assertEqual(info['duration'], 0)
    def test_info_preview_automatically_downloads_album_to_owned_folder(self):
        content = album()
        with patch.object(worker, 'fetch', new=AsyncMock(return_value=(content, 'https://www.douyin.com/note/7000000000000000001'))), \
             patch.object(photos, 'download_album', new=AsyncMock()) as download, \
             patch.object(sys, 'argv', ['worker', 'info', '--link', 'https://www.douyin.com/note/7000000000000000001', '--preview-images', '--folder', str(self.root)]):
            worker.main()
            download.assert_awaited_once_with(content, str(self.root))
    def test_video_only_download_cannot_permanently_save_changed_album(self):
        with patch.object(worker, 'fetch', new=AsyncMock(return_value=(album(), 'https://www.douyin.com/note/7000000000000000001'))), \
             patch.object(photos, 'download_album', new=AsyncMock()) as download, patch.object(worker, 'emit'):
            with self.assertRaisesRegex(ValueError, '重新解析'):
                asyncio.run(worker.download('https://www.douyin.com/note/7000000000000000001', 'highest', str(self.root), video_only=True))
            download.assert_not_awaited()
            self.assertEqual(list(self.root.iterdir()), [])
    def test_full_download_keeps_image_bytes_order_and_original_dimensions(self):
        self.run_download(self.success)
        result = self.events[-1]
        self.assertEqual(result['event'], 'complete')
        self.assertEqual([Path(p).name for p in result['imagePaths']], ['001.png', '002.png'])
        self.assertEqual((result['width'], result['height']), (2, 3))
        self.assertEqual(result['bytes'], len(png()) * 2)
        self.assertTrue(all(Path(p).read_bytes() == png() for p in result['imagePaths']))
        self.assertFalse(list(self.root.glob('.shiying-*')))
    def test_existing_empty_album_directory_is_never_replaced(self):
        target = self.root / '测试作者_合成图文_图文_7000000000000000001'
        target.mkdir()
        self.run_download(self.success)
        self.assertEqual(list(target.iterdir()), [])
        self.assertEqual(Path(self.events[-1]['path']).name, target.name + '_1')
    def test_repeat_download_preserves_existing_album(self):
        self.run_download(self.success)
        original = Path(self.events[-1]['path'])
        self.run_download(self.success)
        self.assertNotEqual(original, Path(self.events[-1]['path']))
        self.assertEqual((original/'001.png').read_bytes(), png())
    def test_later_image_failure_publishes_no_partial_album(self):
        def handler(request):
            return self.success(request) if request.url.path == '/0' else httpx.Response(404)
        with self.assertRaisesRegex(ValueError, '第 2/2'):
            self.run_download(handler)
        self.assertEqual(list(self.root.iterdir()), [])
        self.assertFalse(any(e['event'] == 'complete' for e in self.events))
    def test_cancellation_discards_all_staging_and_preserves_user_file(self):
        sentinel = self.root/'用户原片.png'; sentinel.write_bytes(png())
        def handler(request):
            if request.url.path == '/1': raise worker.Cancelled()
            return self.success(request)
        with self.assertRaises(worker.Cancelled): self.run_download(handler)
        self.assertEqual(list(self.root.iterdir()), [sentinel])
        self.assertEqual(sentinel.read_bytes(), png())
    def test_fake_image_html_is_rejected(self):
        with self.assertRaisesRegex(ValueError, '不是支持的图片'):
            self.run_download(lambda request: httpx.Response(200, headers={'content-type':'image/jpeg'}, content=b'<html>login</html>'))
        self.assertEqual(list(self.root.iterdir()), [])
    def test_truncated_image_is_not_published(self):
        with self.assertRaises(ValueError):
            self.run_download(lambda request: httpx.Response(200, headers={'content-type':'image/png'}, content=png()[:40]))
        self.assertEqual(list(self.root.iterdir()), [])
    def test_auth_and_rate_limit_are_not_retried_on_other_mirrors(self):
        for status in [401, 403, 429]:
            content = album(1); content.media.images[0].urls = ['https://images.example/other']
            requests = []
            def handler(request): requests.append(request); return httpx.Response(status)
            with self.assertRaisesRegex(ValueError, f'HTTP {status}'): self.run_download(handler, content)
            self.assertEqual(len(requests), 1)
    def test_expired_cdn_mirror_uses_alternate_url(self):
        content = album(1); content.media.images[0].urls = ['https://images.example/alternate']
        self.run_download(lambda request: self.success(request) if request.url.path == '/alternate' else httpx.Response(404), content)
        self.assertEqual(len(self.events[-1]['imagePaths']), 1)
    def test_image_size_and_album_count_limits_do_not_truncate(self):
        with patch.object(photos, 'MAX_IMAGE_BYTES', 16), self.assertRaisesRegex(ValueError, '64 MiB'):
            self.run_download(self.success)
        with self.assertRaisesRegex(ValueError, '未截断'): photos.metadata(album(501))
        self.assertEqual(list(self.root.iterdir()), [])
    def test_real_decoder_reports_dimensions_and_releases_owned_child(self):
        image = self.root/'fixture.png'; image.write_bytes(png(4, 5))
        self.assertEqual(photos.verify_image(image), (4, 5))
        self.assertIsNone(worker.active_child)

if __name__ == '__main__': unittest.main()
