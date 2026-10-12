"""Offline article metadata checks.

The Swift file owns historical counts and expired monitoringGeneration tokens.
This file checks old HTML/snapshot compatibility, Unicode excerpt text, and that an
extra cover is not added to body images. Cover redirect matrices belong to the other
candidate. No live platform requests.
"""
from __future__ import annotations
import asyncio, hashlib, io, json, struct, sys, tempfile, unittest, zlib
from pathlib import Path
import httpx

import article_worker as aw

LINK = "https://mp.weixin.qq.com/s/ArticleExample"
IMG = "https://mmbiz.qpic.cn/mmbiz_png/test/0?wx_fmt=png"
COVER = "https://mmbiz.qpic.cn/mmbiz_png/cover/0?wx_fmt=png"
FAMILY = "👨\u200d👩\u200d👧\u200d👦"
HTML = (
    "<html><h2 id=\"activity-name\">标题 &amp; 示例</h2><a id=\"js_name\">测试公众号</a>"
    "<div id=\"publish_time\">2026年10月10日</div><div id=\"js_content\"><h3>章节</h3>"
    "<p>正文<strong>重点</strong></p><img data-src=\"" + IMG + "\" src=\"data:image/png;base64,x\">"
    "<img data-src=\"" + IMG + "\"><table><tr><th>名称</th><th>内容</th></tr><tr><td>例子</td><td>示例</td></tr></table></div></html>"
)
UNICODE_DESC = FAMILY + ("文" * 51)
UNICODE_HTML = HTML.replace(
    "<html>",
    "<html><head><meta property=\"og:image\" content=\"" + COVER + "\">"
    "<meta property=\"og:description\" content=\"" + UNICODE_DESC + "\"></head>",
    1,
).replace("<p>正文", "<p>" + FAMILY + "正文", 1)

def png():
    def chunk(kind, data):
        return struct.pack("!I", len(data)) + kind + data + struct.pack("!I", zlib.crc32(kind + data) & 0xFFFFFFFF)
    return (
        b"\x89PNG\r\n\x1a\n"
        + chunk(b"IHDR", struct.pack("!IIBBBBB", 2, 2, 8, 2, 0, 0, 0))
        + chunk(b"IDAT", zlib.compress((b"\x00" + b"\xff\x00\x00" * 2) * 2))
        + chunk(b"IEND", b"")
    )

class ArticleMetadataTests(unittest.TestCase):
    def test_old_html_and_snapshot_accept_missing_cover_fields(self):
        article = aw.parse_article(HTML, LINK)
        self.assertEqual(article["images"], [IMG])
        self.assertEqual(article["imageCount"], 1)
        self.assertIn("coverURL", article)
        self.assertIn("coverSource", article)
        self.assertIn("excerpt", article)
        self.assertIn(article["coverURL"], (None, ""))
        raw = json.dumps({"links": [LINK, LINK], "snapshots": {LINK: {"html": HTML}}}).encode()
        links, snapshots = aw.read_request(io.BytesIO(raw))
        self.assertEqual(links, [LINK])
        again = aw.parse_article(snapshots[LINK]["html"], LINK, snapshots[LINK])
        self.assertEqual(again["images"], [IMG])
        self.assertNotIn(COVER, again["images"])

    def test_unicode_excerpt_and_cover_are_outside_body_images(self):
        article = aw.parse_article(UNICODE_HTML, LINK)
        self.assertEqual(article["images"], [IMG])
        self.assertNotIn(COVER, article["images"])
        self.assertEqual(article["imageCount"], 1)
        self.assertIsInstance(article["coverURL"], str)
        self.assertIn("qpic.cn", article["coverURL"])
        self.assertTrue(article["coverURL"].startswith("https://"))
        self.assertNotIn(article["coverURL"], article["images"])
        self.assertTrue(article.get("coverSource"))
        self.assertIsInstance(article["excerpt"], str)
        self.assertIn(FAMILY, article["excerpt"])
        self.assertNotIn("\ufffd", article["excerpt"])
        foreign = UNICODE_HTML.replace(COVER, "https://evil.example/secret.png")
        with self.assertRaises(aw.ArticleError) as rejected:
            aw.parse_article(foreign, LINK)
        self.assertEqual(rejected.exception.reason, "image_source")

    def test_export_cover_manifest_includes_cover_and_three_texts(self):
        article = aw.parse_article(UNICODE_HTML, LINK)
        image = png()
        calls = []
        def handler(request):
            calls.append(str(request.url))
            self.assertTrue(request.url.host.endswith("qpic.cn"))
            return httpx.Response(200, content=image)
        async def run(root):
            async with httpx.AsyncClient(transport=httpx.MockTransport(handler), follow_redirects=False) as client:
                return await aw.export_article(client, article, root)
        with tempfile.TemporaryDirectory() as root:
            dest, total = asyncio.run(run(root))
            self.assertTrue(any("/cover/" in url for url in calls))
            self.assertTrue(any("/test/" in url for url in calls))
            manifest = json.loads((dest / "来源.json").read_text(encoding="utf-8"))
            cover = manifest["cover"]
            for key in ("path", "bytes", "sha256", "source"):
                self.assertIn(key, cover)
            cover_file = dest / cover["path"]
            body_paths = [item["path"] for item in manifest["images"]]
            self.assertNotIn(cover["path"], body_paths)
            self.assertEqual(cover_file.read_bytes(), image)
            self.assertEqual(cover["bytes"], len(image))
            self.assertEqual(cover["sha256"], hashlib.sha256(image).hexdigest())
            self.assertIn(cover["source"], {article["coverURL"], article["coverSource"], COVER})
            resolved = cover_file.resolve()
            self.assertTrue(resolved.is_relative_to(dest.resolve()))
            texts = [dest / name for name in ("文章.md", "文章.html", "来源.json")]
            self.assertTrue(all(path.is_file() for path in texts))
            body_bytes = sum((dest / path).stat().st_size for path in body_paths)
            text_bytes = sum(path.stat().st_size for path in texts)
            self.assertEqual(total, body_bytes + cover["bytes"] + text_bytes)
            self.assertEqual(total, sum(path.stat().st_size for path in dest.rglob("*") if path.is_file()))
            self.assertIn(FAMILY, (dest / "文章.html").read_text(encoding="utf-8"))
            self.assertFalse(list(Path(root).glob(".shiying-article-*")))

    def test_export_failure_removes_staging_and_keeps_existing_bytes(self):
        article = aw.parse_article(UNICODE_HTML, LINK)
        def handler(request):
            if "/cover/" in request.url.path:
                return httpx.Response(503)
            return httpx.Response(200, content=png())
        async def run(root):
            async with httpx.AsyncClient(transport=httpx.MockTransport(handler), follow_redirects=False) as client:
                await aw.export_article(client, article, root)
        with tempfile.TemporaryDirectory() as root:
            keep = Path(root) / "keep.txt"
            keep.write_text("keep", encoding="utf-8")
            with self.assertRaises(aw.ArticleError):
                asyncio.run(run(root))
            self.assertEqual(keep.read_text(encoding="utf-8"), "keep")
            self.assertEqual([path.name for path in Path(root).iterdir()], ["keep.txt"])
            self.assertFalse(list(Path(root).glob(".shiying-article-*")))

if __name__ == "__main__":
    unittest.main()
