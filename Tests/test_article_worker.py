import asyncio, io, json, struct, tempfile, unittest, zlib
from pathlib import Path
from unittest import mock
import httpx, article_worker as aw

LINK='https://mp.weixin.qq.com/s/ArticleExample'; IMG='https://mmbiz.qpic.cn/mmbiz_png/test/0?wx_fmt=png'
HTML='<html><h2 id="activity-name">标题 &amp; 示例</h2><a id="js_name">测试公众号</a><div id="publish_time">2026年10月10日</div><div id="js_content"><h3>章节</h3><p>正文<strong>重点</strong></p><img data-src="'+IMG+'" src="data:image/png;base64,x"><img data-src="'+IMG+'"><table><tr><th>名称</th><th>内容</th></tr><tr><td>例子</td><td>示例</td></tr></table></div></html>'
def png():
    def chunk(kind,data):return struct.pack('!I',len(data))+kind+data+struct.pack('!I',zlib.crc32(kind+data)&0xffffffff)
    return b'\x89PNG\r\n\x1a\n'+chunk(b'IHDR',struct.pack('!IIBBBBB',2,2,8,2,0,0,0))+chunk(b'IDAT',zlib.compress((b'\x00'+b'\xff\x00\x00'*2)*2))+chunk(b'IEND',b'')

class ArticleWorkerTests(unittest.TestCase):
    def test_public_url_discards_authentication_parameters(self):
        value='http://mp.weixin.qq.com/s?__biz=QQ%3D%3D&mid=123&idx=1&sn='+'a'*32+'&key=SECRET&pass_ticket=SECRET'
        result=aw.article_url(value);self.assertNotIn('SECRET',result);self.assertTrue(result.startswith('https://'))
    def test_foreign_hosts_and_profiles_rejected(self):
        for value in ['https://mp.weixin.qq.com.evil/s/x','https://user:password@mp.weixin.qq.com/s/x','https://mp.weixin.qq.com:9000/s/x','https://mp.weixin.qq.com/mp/profile_ext?action=home']:
            with self.assertRaises(aw.ArticleError):aw.article_url(value)
    def test_request_deduplication_limit_and_snapshot_binding(self):
        links,_=aw.read_request(io.BytesIO(json.dumps({'links':[LINK,LINK]}).encode()));self.assertEqual(links,[LINK])
        with self.assertRaises(aw.ArticleError):aw.read_request(io.BytesIO(json.dumps({'links':[LINK]*201}).encode()))
        with self.assertRaises(aw.ArticleError):aw.read_request(io.BytesIO(json.dumps({'links':[LINK],'snapshots':{'https://mp.weixin.qq.com/s/Other':{'html':HTML}}}).encode()))
    def test_lazy_images_and_metadata_preserved(self):
        article=aw.parse_article(HTML,LINK);self.assertEqual(article['title'],'标题 & 示例');self.assertEqual(article['account'],'测试公众号')
        self.assertEqual(article['images'],[IMG]);self.assertEqual(article['imageCount'],1);self.assertGreater(article['characters'],0)
    def test_title_without_body_never_succeeds(self):
        for value in ['<title>微信验证</title>','<h2 id="activity-name">标题</h2><div id="js_content"></div>']:
            with self.assertRaises(aw.ArticleError):aw.parse_article(value,LINK)
    def test_large_site_scripts_do_not_hide_small_article_body(self):
        page=HTML.replace('</html>','<script>'+('x'*(aw.MAX_HTML+10))+'</script></html>')
        self.assertEqual(aw.parse_article(page,LINK)['imageCount'],1)
        huge=HTML.replace('正文','字'*(aw.MAX_HTML//3+1))
        with self.assertRaises(aw.ArticleError):aw.parse_article(huge,LINK)
    def test_scripts_events_and_hidden_trackers_removed(self):
        value=HTML.replace('<p>正文','<script>SECRET</script><a href="javascript:alert(1)" onclick="SECRET">链接</a><img data-src="'+IMG+'" style="display:none"><p onmouseover="SECRET">正文')
        body=aw.parse_article(value,LINK)['content'];self.assertNotIn('SECRET',body);self.assertNotIn('javascript:',body);self.assertNotIn('display:none',body)
    def test_foreign_image_source_fails_closed(self):
        with self.assertRaises(aw.ArticleError):aw.parse_article(HTML.replace(IMG,'https://127.0.0.1/private.png'),LINK)
    def test_embedded_video_controls_do_not_become_article_text(self):
        for media in ['<mp-common-videos><div>播放器倍速全屏按钮</div></mp-common-videos>',
                      '<div class="video_iframe rich_pages wx_video_iframe"><div>播放器倍速全屏按钮</div><video></video></div>',
                      '<iframe class="video_iframe rich_pages wx_video_iframe" data-mpvid="wxv_example"></iframe>']:
            raw=HTML.replace('<p>正文',media+'<p>正文')
            body=aw.parse_article(raw,LINK)['content']
            self.assertNotIn('播放器倍速全屏按钮',body);self.assertIn('原文含音视频',body);self.assertIn('正文',body)
    def test_offline_document_preserves_text_and_relative_images(self):
        article=aw.parse_article(HTML,LINK);md,page=aw.documents(article,{IMG:'images/001.png'})
        self.assertIn('**重点**',md);self.assertIn('images/001.png',md);self.assertIn('章节',md);self.assertIn('| 名称',md)
        self.assertNotIn(IMG,page);self.assertIn('Content-Security-Policy',page);self.assertIn(LINK,page)
    def test_cover_image_nested_in_heading_remains_in_markdown(self):
        raw=HTML.replace('<h3>章节</h3>','<h3><section><section><img data-src="'+IMG.replace('test','cover')+'"></section></section></h3>')
        article=aw.parse_article(raw,LINK)
        mapping={url:f'images/{i:03d}.png' for i,url in enumerate(article['images'],1)}
        md,page=aw.documents(article,mapping)
        self.assertTrue(all(path in md and path in page for path in mapping.values()))
    def test_real_image_decode_unique_publish_and_original_bytes(self):
        article=aw.parse_article(HTML,LINK);image=png()
        async def run(root):
            async with httpx.AsyncClient(transport=httpx.MockTransport(lambda r:httpx.Response(200,content=image))) as c:
                first,_=await aw.export_article(c,article,root);second,_=await aw.export_article(c,article,root);return first,second
        with tempfile.TemporaryDirectory() as root:
            first,second=asyncio.run(run(root));self.assertNotEqual(first,second)
            self.assertEqual((first/'images/001.png').read_bytes(),image);self.assertEqual((second/'images/001.png').read_bytes(),image)
            self.assertTrue((first/'文章.md').is_file());self.assertFalse(list(Path(root).glob('.shiying-article-*')))
    def test_partial_image_failure_never_publishes_article(self):
        article=aw.parse_article(HTML.replace('</div></html>','<img data-src="'+IMG.replace('test','second')+'"></div></html>'),LINK)
        async def run(root):
            async with httpx.AsyncClient(transport=httpx.MockTransport(lambda r:httpx.Response(503) if 'second' in r.url.path else httpx.Response(200,content=png()))) as c:
                await aw.export_article(c,article,root)
        with tempfile.TemporaryDirectory() as root:
            with self.assertRaises(aw.ArticleError):asyncio.run(run(root))
            self.assertFalse(list(Path(root).iterdir()))
    def test_corrupt_image_never_publishes_article(self):
        article=aw.parse_article(HTML,LINK)
        async def run(root):
            async with httpx.AsyncClient(transport=httpx.MockTransport(lambda r:httpx.Response(200,content=b'\x89PNG\r\n\x1a\nBROKEN'))) as c:await aw.export_article(c,article,root)
        with tempfile.TemporaryDirectory() as root:
            with self.assertRaises(aw.ArticleError):asyncio.run(run(root))
            self.assertFalse(list(Path(root).iterdir()))
    def test_verification_redirect_does_not_leave_official_domain(self):
        calls=[]
        async def run():
            def handler(r):calls.append(r);return httpx.Response(302,headers={'Location':'https://evil.example/SECRET'})
            async with httpx.AsyncClient(transport=httpx.MockTransport(handler)) as c:await aw.fetch_article(c,LINK)
        with self.assertRaises(aw.ArticleError):asyncio.run(run())
        self.assertEqual(len(calls),1)

    def test_complete_article_limit_counts_text_and_source_manifest(self):
        article=aw.parse_article(HTML,LINK);image=png();limit=len(image)+1
        async def run(root):
            async with httpx.AsyncClient(transport=httpx.MockTransport(lambda r:httpx.Response(200,content=image))) as c:
                with mock.patch.object(aw,'MAX_TOTAL',limit):return await aw.export_article(c,article,root)
        with tempfile.TemporaryDirectory() as root:
            with self.assertRaises(aw.ArticleError) as issue:asyncio.run(run(root))
            self.assertEqual(issue.exception.reason,'article_limit')
            self.assertFalse(list(Path(root).iterdir()))

    def test_complete_article_limit_includes_text_only_articles(self):
        article=aw.parse_article(HTML.replace('<img data-src="'+IMG+'" src="data:image/png;base64,x">','').replace('<img data-src="'+IMG+'">',''),LINK)
        async def run(root):
            async with httpx.AsyncClient(transport=httpx.MockTransport(lambda r:self.fail('text-only article must not request images'))) as c:
                with mock.patch.object(aw,'MAX_TOTAL',1):return await aw.export_article(c,article,root)
        with tempfile.TemporaryDirectory() as root:
            with self.assertRaises(aw.ArticleError) as issue:asyncio.run(run(root))
            self.assertEqual(issue.exception.reason,'article_limit')
            self.assertFalse(list(Path(root).iterdir()))

    def test_complete_article_limit_accepts_exact_boundary(self):
        article=aw.parse_article(HTML,LINK);image=png()
        async def export(root,limit=None):
            async with httpx.AsyncClient(transport=httpx.MockTransport(lambda r:httpx.Response(200,content=image))) as c:
                if limit is None:return await aw.export_article(c,article,root)
                with mock.patch.object(aw,'MAX_TOTAL',limit):return await aw.export_article(c,article,root)
        with tempfile.TemporaryDirectory() as root:
            first,size=asyncio.run(export(root));self.assertEqual(size,sum(p.stat().st_size for p in first.rglob('*') if p.is_file()))
            second,again=asyncio.run(export(root,size));self.assertEqual(again,size);self.assertNotEqual(first,second)
            with self.assertRaises(aw.ArticleError):asyncio.run(export(root,size-1))
            self.assertEqual(len(list((Path(root)/'公众号'/aw.safe_name(article['account'])).iterdir())),2)
            self.assertFalse(list(Path(root).glob('.shiying-article-*')))
