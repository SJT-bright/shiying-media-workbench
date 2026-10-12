import asyncio, hashlib, io, json, tempfile, unittest
from pathlib import Path
from unittest import mock
import httpx, article_worker as aw
from test_article_worker import HTML, IMG, LINK, png

COVER = 'https://mmbiz.qpic.cn/mmbiz_png/cover/0?wx_fmt=png'
PAGE = HTML.replace('</html>', '<meta property="og:image" content="' + COVER + '"></html>')

def text_only(extra=''):
    return HTML.replace('<img data-src="' + IMG + '" src="data:image/png;base64,x">', '').replace('<img data-src="' + IMG + '">', '') + extra

class ArticleCoverTests(unittest.TestCase):
    def test_missing_cover_is_null_and_excerpt_is_clean_body(self):
        article = aw.parse_article(HTML, LINK)
        self.assertIsNone(article['coverURL'])
        self.assertIsNone(article['coverSource'])
        self.assertEqual(article['images'], [IMG])
        self.assertEqual(article['imageCount'], 1)
        self.assertNotIn('<', article['excerpt'])
        self.assertNotIn('标题', article['excerpt'])
        self.assertIn('重点', article['excerpt'])
        self.assertLessEqual(len(article['excerpt']), 2000)
        secret = HTML.replace('<p>正文', '<script>SECRET</script><p>正文')
        self.assertNotIn('SECRET', aw.parse_article(secret, LINK)['excerpt'])

    def test_excerpt_keeps_two_thousand_characters_for_the_card(self):
        article = aw.parse_article(HTML.replace('正文', '正' * 2500), LINK)
        self.assertEqual(len(article['excerpt']), 2000)
        self.assertGreater(article['characters'], 2000)
        self.assertEqual(article['imageCount'], 1)

    def test_cover_comes_from_provided_url_or_og_image_only(self):
        provided = aw.parse_article(PAGE, LINK, {'coverURL': '  ' + IMG + '  ', 'title': '来自快照'})
        self.assertEqual(provided['title'], '来自快照')
        self.assertEqual(provided['coverURL'], IMG)
        self.assertEqual(provided['coverSource'], 'provided')
        fallback = aw.parse_article(PAGE, LINK, {'coverURL': '   '})
        self.assertEqual(fallback['coverURL'], COVER)
        self.assertEqual(fallback['coverSource'], 'og:image')
        self.assertEqual(fallback['images'], [IMG])
        self.assertNotIn(COVER, fallback['images'])
        with self.assertRaises(aw.ArticleError) as issue:
            aw.parse_article(PAGE, LINK, {'coverURL': {'url': IMG}})
        self.assertEqual(issue.exception.reason, 'image_source')
        with self.assertRaises(aw.ArticleError) as foreign:
            aw.parse_article(HTML.replace('</html>', '<meta property="og:image" content="https://evil.example/a.png"></html>'), LINK)
        self.assertEqual(foreign.exception.reason, 'image_source')

    def test_saved_source_cover_is_null_when_page_has_no_formal_cover(self):
        article = aw.parse_article(HTML, LINK)
        async def run(root):
            async with httpx.AsyncClient(transport=httpx.MockTransport(lambda r: httpx.Response(200, content=png()))) as client:
                return await aw.export_article(client, article, root)
        with tempfile.TemporaryDirectory() as root:
            dest, size = asyncio.run(run(root))
            meta = json.loads((dest / '来源.json').read_text())
            self.assertIsNone(meta['cover'])
            self.assertIsNone(article['coverRelative'])
            self.assertEqual(len(list((dest / 'images').iterdir())), 1)
            self.assertEqual(size, sum(p.stat().st_size for p in dest.rglob('*') if p.is_file()))

    def test_body_image_is_reused_and_counted_once(self):
        article = aw.parse_article(HTML.replace('</html>', '<meta property="og:image" content="' + IMG + '"></html>'), LINK)
        image = png(); calls = []
        def handler(request):
            calls.append(str(request.url)); return httpx.Response(200, content=image)
        async def run(root, limit=None):
            async with httpx.AsyncClient(transport=httpx.MockTransport(handler)) as client:
                if limit is None: return await aw.export_article(client, article, root)
                with mock.patch.object(aw, 'MAX_TOTAL', limit): return await aw.export_article(client, article, root)
        with tempfile.TemporaryDirectory() as root:
            dest, size = asyncio.run(run(root))
            self.assertEqual(calls, [IMG])
            self.assertEqual(article['imageCount'], 1)
            self.assertEqual(article['coverRelative'], 'images/001.png')
            self.assertFalse((dest / 'images' / 'cover.png').exists())
            meta = json.loads((dest / '来源.json').read_text())
            self.assertEqual(meta['cover']['source'], 'content')
            self.assertEqual(meta['cover']['path'], 'images/001.png')
            self.assertEqual(meta['cover']['bytes'], len(image))
            self.assertEqual(meta['cover']['sha256'], hashlib.sha256(image).hexdigest())
            self.assertEqual(meta['images'], [{'path': 'images/001.png', 'bytes': len(image), 'sha256': meta['cover']['sha256']}])
            self.assertEqual(set(meta['cover']), {'path', 'bytes', 'sha256', 'source'})
            self.assertEqual(size, sum(p.stat().st_size for p in dest.rglob('*') if p.is_file()))
            _, again = asyncio.run(run(root, size))
            self.assertEqual(again, size)

    def test_extra_cover_is_downloaded_decoded_and_included_in_total(self):
        article = aw.parse_article(PAGE, LINK); image = png(); calls = []
        def handler(request):
            calls.append(request.url.path); return httpx.Response(200, content=image)
        async def run(root, limit=None):
            async with httpx.AsyncClient(transport=httpx.MockTransport(handler)) as client:
                if limit is None: return await aw.export_article(client, article, root)
                with mock.patch.object(aw, 'MAX_TOTAL', limit): return await aw.export_article(client, article, root)
        with tempfile.TemporaryDirectory() as root:
            dest, size = asyncio.run(run(root))
            self.assertEqual(sorted(calls), sorted(['/mmbiz_png/test/0', '/mmbiz_png/cover/0']))
            self.assertEqual(article['imageCount'], 1)
            self.assertEqual(len(json.loads((dest / '来源.json').read_text())['images']), 1)
            meta = json.loads((dest / '来源.json').read_text())['cover']
            self.assertEqual(meta['path'], 'images/cover.png')
            self.assertEqual(meta['source'], 'og:image')
            self.assertEqual((dest / 'images' / 'cover.png').read_bytes(), image)
            self.assertEqual(size, sum(p.stat().st_size for p in dest.rglob('*') if p.is_file()))
            _, again = asyncio.run(run(root, size))
            self.assertEqual(again, size)
            with self.assertRaises(aw.ArticleError) as issue: asyncio.run(run(root, size - 1))
            self.assertEqual(issue.exception.reason, 'article_limit')
            self.assertFalse(list(Path(root).glob('.shiying-article-*')))

    def test_cover_only_article_still_checks_cover_and_three_texts(self):
        raw = text_only().replace('</html>', '<meta property="og:image" content="' + COVER + '"></html>')
        article = aw.parse_article(raw, LINK); image = png()
        self.assertEqual(article['images'], [])
        self.assertEqual(article['imageCount'], 0)
        self.assertEqual(article['coverURL'], COVER)
        async def run(root, limit=None):
            async with httpx.AsyncClient(transport=httpx.MockTransport(lambda r: httpx.Response(200, content=image))) as client:
                if limit is None: return await aw.export_article(client, article, root)
                with mock.patch.object(aw, 'MAX_TOTAL', limit): return await aw.export_article(client, article, root)
        with tempfile.TemporaryDirectory() as root:
            dest, size = asyncio.run(run(root))
            self.assertEqual([p.name for p in (dest / 'images').iterdir()], ['cover.png'])
            self.assertEqual(size, sum(p.stat().st_size for p in dest.rglob('*') if p.is_file()))
            with self.assertRaises(aw.ArticleError) as issue: asyncio.run(run(root, len(image) - 1))
            self.assertEqual(issue.exception.reason, 'image_limit')
            self.assertEqual(len(list((Path(root) / '公众号').rglob('文章.md'))), 1)

    def test_cover_failure_publishes_nothing(self):
        article = aw.parse_article(PAGE, LINK)
        def handler(request):
            if request.url.path.endswith('/cover/0'): return httpx.Response(503)
            return httpx.Response(200, content=png())
        async def run(root):
            async with httpx.AsyncClient(transport=httpx.MockTransport(handler)) as client:
                await aw.export_article(client, article, root)
        with tempfile.TemporaryDirectory() as root:
            with self.assertRaises(aw.ArticleError) as issue: asyncio.run(run(root))
            self.assertEqual(issue.exception.reason, 'image_http')
            self.assertFalse(list(Path(root).iterdir()))
        article = aw.parse_article(PAGE, LINK)
        async def corrupt(root):
            async with httpx.AsyncClient(transport=httpx.MockTransport(lambda r: httpx.Response(200, content=png() if 'test' in r.url.path else b'not-an-image'))) as client:
                await aw.export_article(client, article, root)
        with tempfile.TemporaryDirectory() as root:
            with self.assertRaises(aw.ArticleError) as issue: asyncio.run(corrupt(root))
            self.assertEqual(issue.exception.reason, 'invalid_image')
            self.assertFalse(list(Path(root).iterdir()))

    def test_events_return_cover_fields_without_downloading_preview(self):
        events = []
        calls = []
        def emit(event, **data): events.append((event, data))
        def handler(request):
            calls.append(str(request.url)); return httpx.Response(200, content=png())
        original = httpx.AsyncClient
        def factory(*args, **kwargs):
            kwargs['transport'] = httpx.MockTransport(handler)
            return original(*args, **kwargs)
        snapshot = {LINK: {'html': PAGE, 'coverURL': COVER, 'excerpt': '不应采用这段快照摘要'}}
        async def run(root, action):
            with mock.patch('worker.emit', emit), mock.patch('httpx.AsyncClient', factory):
                return await aw.run_articles([LINK], snapshot, root, action)
        with tempfile.TemporaryDirectory() as root:
            self.assertEqual(asyncio.run(run(root, 'preview')), 0)
            preview = events[-2][1]['article']
            self.assertEqual(events[-2][0], 'article_preview')
            self.assertEqual(preview['coverURL'], COVER)
            self.assertIsNone(preview['coverPath'])
            self.assertIn('重点', preview['excerpt'])
            self.assertNotIn('不应采用', preview['excerpt'])
            self.assertEqual(calls, [])
            events.clear()
            self.assertEqual(asyncio.run(run(root, 'download')), 0)
            saved = next(data['article'] for name, data in events if name == 'article_saved')
            self.assertEqual(saved['coverURL'], COVER)
            self.assertTrue(saved['coverPath'].endswith('images/cover.png'))
            self.assertTrue(Path(saved['coverPath']).is_file())
            self.assertEqual(saved['imageCount'], 1)
            self.assertLessEqual(len(saved['excerpt']), 2000)
            meta = json.loads((Path(saved['path']) / '来源.json').read_text())['cover']
            self.assertEqual(meta['source'], 'provided')
            self.assertEqual(hashlib.sha256((Path(saved['path']) / meta['path']).read_bytes()).hexdigest(), meta['sha256'])

    def test_snapshot_request_still_rejects_unrelated_html(self):
        payload = {'links': [LINK], 'snapshots': {LINK: {'html': HTML, 'coverURL': COVER, 'excerpt': 'x' * 3000}}}
        links, snapshots = aw.read_request(io.BytesIO(json.dumps(payload).encode()))
        self.assertEqual(links, [LINK])
        self.assertEqual(snapshots[LINK]['coverURL'], COVER)
        with self.assertRaises(aw.ArticleError):
            aw.read_request(io.BytesIO(json.dumps({'links': [LINK] * 201}).encode()))

if __name__ == '__main__':
    unittest.main()
