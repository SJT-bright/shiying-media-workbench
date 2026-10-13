"""离线分页与入口测试。不访问网络，不写 Cookie 或签名 URL。"""
from __future__ import annotations

import json
import os
import subprocess
import sys
import tempfile
import unittest
import uuid
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
WT = ROOT
PY = sys.executable
sys.path.insert(0, str(ROOT / "Backend/upstream/src"))
sys.path.insert(0, str(WT / "Backend"))

import httpx

import creator_worker
from creator_worker import SEC_RE

SEC = "MS4wLjABAAAA_SYNTHETIC_DOUYIN_AUTHOR_0001"
ENV = os.environ.copy()
ENV["PYTHONPATH"] = str(ROOT / "Backend/upstream/src")


OTHER = "MS4wLjABAAAA_SYNTHETIC_DOUYIN_AUTHOR_0002"


def aweme(aweme_id, *, digg=10, collect=2, aweme_type=0, images=None, deleted=False,
          private=False, with_digg=True, with_collect=True, with_time=True, desc="海边标题",
          sec_uid=SEC, include_author=True):
    stats = {}
    if with_digg:
        stats["digg_count"] = digg
    if with_collect:
        stats["collect_count"] = collect
    item = {
        "aweme_id": aweme_id,
        "desc": desc,
        "aweme_type": aweme_type,
        "statistics": stats,
        "status": {"is_delete": deleted, "private_status": 1 if private else 0},
    }
    if include_author:
        author = {"nickname": "合成作者", "uid": "1"}
        if sec_uid is not None:
            author["sec_uid"] = sec_uid
        item["author"] = author
    if with_time:
        item["create_time"] = 1716200000
    if images is not None:
        item["images"] = images
    elif not deleted:
        item["video"] = {
            "play_addr": {"url_list": ["https://example.invalid/a.mp4"], "width": 720, "height": 1280},
            "cover": {"url_list": ["https://example.invalid/c.jpg"]},
            "duration": 1000,
        }
    return item


def profile(aweme_count=2, include_count=True):
    user = {
        "sec_uid": SEC,
        "nickname": "合成作者",
        "avatar_thumb": {"url_list": ["https://example.invalid/avatar.jpg"]},
        "follower_count": 1,
        "following_count": 1,
        "total_favorited": 1,
    }
    if include_count:
        user["aweme_count"] = aweme_count
    return {"status_code": 0, "user": user}


def page(items, has_more, cursor):
    body = {"status_code": 0, "aweme_list": items, "has_more": 1 if has_more else 0}
    if cursor is not None:
        body["max_cursor"] = cursor
    return body


class ScanTests(unittest.IsolatedAsyncioTestCase):
    def setUp(self):
        self.events = []
        self.seen = []
        self.routes = {}
        creator_worker.emit_event = self.capture
        creator_worker.last_notes = []

    def capture(self, event, **data):
        self.events.append({"event": event, **data})

    def handler(self, request: httpx.Request) -> httpx.Response:
        host = request.url.host or ""
        path = request.url.path
        self.seen.append((request.method, host, path))
        if host not in creator_worker.ALLOWED_HOSTS:
            return httpx.Response(599)
        route = self.routes.get((request.method, path))
        if route is None and request.method == "GET":
            route = self.routes.get(("GET", path))
        if route is None and request.method == "HEAD" and path == "/":
            return httpx.Response(200)
        if callable(route):
            return route(request)
        if isinstance(route, httpx.Response):
            return route
        return httpx.Response(404, json={"missing": path})

    async def scan(self, link, **kwargs):
        transport = httpx.MockTransport(self.handler)
        async with httpx.AsyncClient(transport=transport, follow_redirects=False, timeout=5) as client:
            code = await creator_worker.run_scan(link, client=client, pause_seconds=0, **kwargs)
        blob = json.dumps(self.events, ensure_ascii=False) + json.dumps(creator_worker.last_notes, ensure_ascii=False)
        self.assertNotIn("a_bogus", blob)
        self.assertNotIn("msToken", blob)
        self.assertNotIn("UIFID", blob)
        return code

    async def test_rejects_non_homepage(self):
        samples = [
            "https://www.douyin.com/video/7000000000000000001",
            "https://www.douyin.com/note/7000000000000000001",
            "https://www.douyin.com/user/%s?modal_id=7000000000000000001" % SEC,
            "https://user:secret@www.douyin.com/user/%s" % SEC,
            "http://127.0.0.1/user/%s" % SEC,
            "https://127.0.0.1/user/%s" % SEC,
            "http://localhost/user/%s" % SEC,
            "file:///etc/passwd",
            "https://douyin.com.evil.test/user/%s" % SEC,
            "7000000000000000001",
            "https://www.douyin.com:8443/user/%s" % SEC,
        ]
        for sample in samples:
            self.events.clear()
            self.seen.clear()
            with self.subTest(sample=sample):
                code = await self.scan(sample, page_limit=1)
                self.assertEqual(code, 1)
                self.assertEqual(self.seen, [])
                self.assertTrue(self.events)
                self.assertEqual(self.events[-1]["event"], "error")
                self.assertNotIn('"complete": true', json.dumps(self.events))
                self.assertNotIn("secret", self.events[-1]["message"])

    async def test_two_pages_dedupe_and_complete_only_when_has_more_false(self):
        self.routes[("HEAD", "/")] = httpx.Response(200)
        self.routes[("GET", "/aweme/v1/web/user/profile/other/")] = httpx.Response(200, json=profile(3))

        def posts(request):
            cursor = request.url.params.get("max_cursor")
            if cursor in (None, "0"):
                items = [
                    aweme("7000000000000000001", digg=0, collect=5),
                    aweme("7000000000000000002", with_digg=False, images=[{"url_list": ["https://example.invalid/i.jpg"]}]),
                ]
                return httpx.Response(200, json=page(items, True, "50"))
            items = [
                aweme("7000000000000000002", images=[{"url_list": ["https://example.invalid/i.jpg"]}]),
                aweme("7000000000000000003", deleted=True),
            ]
            return httpx.Response(200, json=page(items, False, "80"))

        self.routes[("GET", "/aweme/v1/web/aweme/post/")] = posts
        code = await self.scan("https://www.douyin.com/user/" + SEC, page_limit=5)
        self.assertEqual(code, 0)
        kinds = [event["event"] for event in self.events]
        self.assertEqual(kinds[0], "creator")
        self.assertEqual(self.events[0]["id"], SEC)
        self.assertEqual(self.events[0]["awemeCount"], 3)
        self.assertTrue(str(self.events[0]["avatar"]).startswith("https://example.invalid/"))
        posts_out = [event["post"] for event in self.events if event["event"] == "post"]
        self.assertEqual([post["id"] for post in posts_out], [
            "7000000000000000001", "7000000000000000002", "7000000000000000003",
        ])
        self.assertEqual(posts_out[0]["diggCount"], 0)
        self.assertIsNone(posts_out[1]["diggCount"])
        self.assertFalse(posts_out[1]["isVideo"])
        self.assertFalse(posts_out[2]["isVideo"])
        self.assertTrue(posts_out[0]["isVideo"])
        self.assertTrue(all(post["link"] == "https://www.douyin.com/video/" + post["id"] for post in posts_out))
        done = self.events[-1]
        self.assertEqual(done["event"], "scan_complete")
        self.assertTrue(done["complete"])
        self.assertEqual(done["reason"], "complete")
        self.assertIsNone(done["cursor"])
        self.assertEqual(done["received"], 3)
        paths = [item[2] for item in self.seen]
        self.assertNotIn("/user/" + SEC, paths)
        self.assertIn("/aweme/v1/web/aweme/post/", paths)
        self.assertIn("/aweme/v1/web/user/profile/other/", paths)

    def _arm(self, posts_route, body=None):
        self.routes[("HEAD", "/")] = httpx.Response(200)
        self.routes[("GET", "/aweme/v1/web/user/profile/other/")] = httpx.Response(200, json=body if body is not None else profile())
        self.routes[("GET", "/aweme/v1/web/aweme/post/")] = posts_route

    def _posted_ids(self):
        return [event["post"]["id"] for event in self.events if event["event"] == "post"]

    async def test_foreign_author_on_final_page_is_partial(self):
        items = [
            aweme("7000000000000000011"),
            aweme("7000000000000000012", sec_uid=OTHER),
        ]
        self._arm(lambda request: httpx.Response(200, json=page(items, False, None)))
        code = await self.scan("https://www.douyin.com/user/" + SEC, page_limit=2)
        self.assertEqual(code, 1)
        self.assertEqual(self._posted_ids(), ["7000000000000000011"])
        done = self.events[-1]
        self.assertEqual(done["reason"], "partial")
        self.assertFalse(done["complete"])
        self.assertIsNone(done["cursor"])
        progress = [event for event in self.events if event["event"] == "scan_progress" and event["pages"] == 1][-1]
        self.assertIn("作者跳过 1", progress["detail"])
        self.assertIn("无法解析 0", progress["detail"])

    async def test_missing_author_keeps_valid_video_and_is_partial(self):
        no_author = aweme("7000000000000000021", include_author=False)
        no_sec = aweme("7000000000000000022", sec_uid=None)
        self._arm(lambda request: httpx.Response(200, json=page([
            aweme("7000000000000000020"),
            no_author,
            no_sec,
        ], False, None)))
        code = await self.scan("https://www.douyin.com/user/" + SEC, page_limit=2)
        self.assertEqual(code, 1)
        self.assertEqual(self._posted_ids(), ["7000000000000000020"])
        done = self.events[-1]
        self.assertEqual(done["reason"], "partial")
        self.assertFalse(done["complete"])
        self.assertEqual(done["received"], 1)
        progress = [event for event in self.events if event["event"] == "scan_progress" and event["pages"] == 1][-1]
        self.assertIn("作者跳过 2", progress["detail"])

    async def test_bad_row_on_final_page_is_partial(self):
        broken = {"author": {"sec_uid": SEC, "nickname": "合成作者"}, "aweme_type": 0, "desc": "缺编号"}
        self._arm(lambda request: httpx.Response(200, json=page([
            aweme("7000000000000000030"),
            [],
            broken,
        ], False, None)))
        code = await self.scan("https://www.douyin.com/user/" + SEC, page_limit=2)
        self.assertEqual(code, 1)
        self.assertEqual(self._posted_ids(), ["7000000000000000030"])
        posts_out = [event["post"] for event in self.events if event["event"] == "post"]
        self.assertTrue(posts_out[0]["isVideo"])
        done = self.events[-1]
        self.assertEqual(done["reason"], "partial")
        self.assertFalse(done["complete"])
        progress = [event for event in self.events if event["event"] == "scan_progress" and event["pages"] == 1][-1]
        self.assertIn("无法解析 2", progress["detail"])
        self.assertIn("作者跳过 0", progress["detail"])

    async def test_matching_non_video_final_page_can_complete(self):
        album = aweme(
            "7000000000000000040",
            aweme_type=68,
            images=[{"url_list": ["https://example.invalid/i.jpg"]}],
        )
        self._arm(lambda request: httpx.Response(200, json=page([album], False, None)), body=profile(1))
        code = await self.scan("https://www.douyin.com/user/" + SEC, page_limit=2)
        self.assertEqual(code, 0)
        posts_out = [event["post"] for event in self.events if event["event"] == "post"]
        self.assertEqual([post["id"] for post in posts_out], ["7000000000000000040"])
        self.assertFalse(posts_out[0]["isVideo"])
        done = self.events[-1]
        self.assertTrue(done["complete"])
        self.assertEqual(done["reason"], "complete")
        progress = [event for event in self.events if event["event"] == "scan_progress" and event["pages"] == 1][-1]
        self.assertIn("无法解析 0", progress["detail"])
        self.assertIn("作者跳过 0", progress["detail"])
        self.assertNotIn("本次不能视为全部采完", progress["detail"])

    async def test_later_clean_page_does_not_wash_partial(self):
        def posts(request):
            cursor = request.url.params.get("max_cursor") or "0"
            if cursor == "0":
                return httpx.Response(200, json=page([
                    aweme("7000000000000000050"),
                    aweme("7000000000000000051", sec_uid=OTHER),
                ], True, "60"))
            return httpx.Response(200, json=page([aweme("7000000000000000052")], False, None))

        self._arm(posts)
        code = await self.scan("https://www.douyin.com/user/" + SEC, page_limit=5)
        self.assertEqual(code, 1)
        self.assertEqual(self._posted_ids(), ["7000000000000000050", "7000000000000000052"])
        done = self.events[-1]
        self.assertEqual(done["reason"], "partial")
        self.assertFalse(done["complete"])
        self.assertIsNone(done["cursor"])
        last_progress = [event for event in self.events if event["event"] == "scan_progress"][-1]
        self.assertIn("累计无法解析 0，作者跳过 1", last_progress["detail"])

    async def test_count_mismatch_when_listed_differs_from_aweme_count(self):
        items = [
            aweme("7000000000000000060"),
            aweme("7000000000000000061", aweme_type=68, images=[{"url_list": ["https://example.invalid/i.jpg"]}]),
            aweme("7000000000000000062"),
            aweme("7000000000000000063"),
        ]
        self._arm(lambda request: httpx.Response(200, json=page(items, False, None)), body=profile(7))
        code = await self.scan("https://www.douyin.com/user/" + SEC, page_limit=2)
        self.assertEqual(code, 1)
        self.assertEqual(self._posted_ids(), [
            "7000000000000000060",
            "7000000000000000061",
            "7000000000000000062",
            "7000000000000000063",
        ])
        done = self.events[-1]
        self.assertEqual(done["reason"], "count_mismatch")
        self.assertFalse(done["complete"])
        self.assertEqual(done["awemeCount"], 7)
        self.assertEqual(done["listedCount"], 4)
        self.assertEqual(done["received"], 4)
        self.assertEqual(done["gap"], 3)
        self.assertNotEqual(done["received"], done["awemeCount"])
        self.assertIs(done["tainted"], False)
        self.assertIsNone(done["cursor"])
        progress = [event for event in self.events if event["event"] == "scan_progress" and event["pages"] == 1][-1]
        self.assertIn("主页计数 7", progress["detail"])
        self.assertIn("本人发布 4", progress["detail"])
        self.assertIn("差额 3", progress["detail"])

    async def test_seen_ids_accumulate_across_resume(self):
        self._arm(
            lambda request: httpx.Response(200, json=page([aweme("7000000000000000072")], False, None)),
            body=profile(3),
        )
        code = await self.scan(
            "https://www.douyin.com/user/" + SEC,
            page_limit=2,
            seen_ids={"7000000000000000070", "7000000000000000071"},
        )
        self.assertEqual(code, 0)
        self.assertEqual(self._posted_ids(), ["7000000000000000072"])
        done = self.events[-1]
        self.assertTrue(done["complete"])
        self.assertEqual(done["reason"], "complete")
        self.assertEqual(done["received"], 1)
        self.assertEqual(done["listedCount"], 3)
        self.assertEqual(done["gap"], 0)
        self.assertNotEqual(done["received"], done["awemeCount"])
        progress = [event for event in self.events if event["event"] == "scan_progress" and event["pages"] == 1][-1]
        self.assertIn("本人发布 3", progress["detail"])
        self.assertIn("差额 0", progress["detail"])

    async def test_missing_or_unreliable_count_is_not_complete(self):
        samples = [None, True, False, -1, 7.5, "7.0", "", "07"]

        async def run(raw, include_count=True):
            self.events.clear()
            self.seen.clear()
            body = profile(1, include_count=include_count)
            if include_count:
                body["user"]["aweme_count"] = raw
            self._arm(
                lambda request: httpx.Response(200, json=page([aweme("7000000000000000080")], False, None)),
                body=body,
            )
            code = await self.scan("https://www.douyin.com/user/" + SEC, page_limit=2)
            done = self.events[-1]
            self.assertEqual(code, 1, raw)
            self.assertEqual(done["reason"], "unknown_count", raw)
            self.assertFalse(done["complete"])
            self.assertNotIn("gap", done)
            self.assertNotIn("listedCount", done)
            self.assertIsNone(self.events[0]["awemeCount"])
            progress = [event for event in self.events if event["event"] == "scan_progress" and event["pages"] == 1][-1]
            self.assertNotIn("差额", progress["detail"])
            self.assertNotIn("主页计数", progress["detail"])
            self.assertNotEqual(done["reason"], "count_mismatch")

        await run(None, include_count=False)
        for raw in samples:
            await run(raw)

    async def test_numeric_string_count_still_mismatches(self):
        body = profile(4)
        body["user"]["aweme_count"] = "7"
        items = [aweme("700000000000000012%d" % index) for index in range(4)]
        self._arm(lambda request: httpx.Response(200, json=page(items, False, None)), body=body)
        code = await self.scan("https://www.douyin.com/user/" + SEC, page_limit=2)
        self.assertEqual(code, 1)
        done = self.events[-1]
        self.assertEqual(done["reason"], "count_mismatch")
        self.assertEqual(done["awemeCount"], 7)
        self.assertEqual(done["listedCount"], 4)
        self.assertEqual(done["gap"], 3)
        self.assertEqual(done["received"], 4)

    async def test_prior_partial_is_not_washed_when_later_counts_match(self):
        self._arm(
            lambda request: httpx.Response(200, json=page([aweme("7000000000000000141")], False, None)),
            body=profile(2),
        )
        code = await self.scan(
            "https://www.douyin.com/user/" + SEC,
            page_limit=2,
            seen_ids={"7000000000000000140"},
            prior_partial=True,
        )
        self.assertEqual(code, 1)
        done = self.events[-1]
        self.assertEqual(done["reason"], "partial")
        self.assertFalse(done["complete"])
        self.assertIs(done["tainted"], True)
        self.assertEqual(done["received"], 1)
        self.assertEqual(done["listedCount"], 2)
        self.assertNotEqual(done["received"], done["awemeCount"])

        self.events.clear()
        code = await self.scan(
            "https://www.douyin.com/user/" + SEC,
            page_limit=2,
            seen_ids={"7000000000000000140"},
            prior_partial=False,
        )
        self.assertEqual(code, 0)
        self.assertEqual(self.events[-1]["reason"], "complete")
        self.assertIs(self.events[-1]["tainted"], False)

    async def test_limit_keeps_tainted_for_the_next_batch(self):
        self._arm(
            lambda request: httpx.Response(200, json=page([
                aweme("7000000000000000150"),
                aweme("7000000000000000151", sec_uid=OTHER),
            ], True, "61")),
            body=profile(3),
        )
        code = await self.scan("https://www.douyin.com/user/" + SEC, page_limit=1)
        self.assertEqual(code, 1)
        done = self.events[-1]
        self.assertEqual(done["reason"], "limit")
        self.assertFalse(done["complete"])
        self.assertIs(done["tainted"], True)
        self.assertEqual(done["cursor"], "61")
        self.assertEqual(done["received"], 1)

    async def test_pinned_out_of_order_does_not_stop_pagination(self):
        def posts(request):
            cursor = request.url.params.get("max_cursor") or "0"
            if cursor == "0":
                pinned = aweme("7000000000000000110")
                pinned["create_time"] = 1893456000
                pinned["is_top"] = 1
                return httpx.Response(200, json=page([pinned], True, "40"))
            older = aweme("7000000000000000111")
            older["create_time"] = 1600000000
            return httpx.Response(200, json=page([older], False, None))

        self._arm(posts, body=profile(2))
        code = await self.scan("https://www.douyin.com/user/" + SEC, page_limit=5)
        self.assertEqual(code, 0, self.events[-1])
        self.assertEqual(self._posted_ids(), ["7000000000000000110", "7000000000000000111"])
        self.assertEqual(sum(1 for item in self.seen if item[2] == "/aweme/v1/web/aweme/post/"), 2)

    async def test_zero_count_empty_page_is_not_complete(self):
        self._arm(lambda request: httpx.Response(200, json=page([], False, None)), body=profile(0))
        code = await self.scan("https://www.douyin.com/user/" + SEC, page_limit=2)
        self.assertEqual(code, 1)
        done = self.events[-1]
        self.assertEqual(done["reason"], "empty")
        self.assertFalse(done["complete"])
        self.assertEqual(done["received"], 0)
        self.assertEqual(done["pages"], 1)

    async def test_partial_wins_over_count_mismatch(self):
        self._arm(
            lambda request: httpx.Response(200, json=page([
                aweme("7000000000000000090"),
                aweme("7000000000000000091", sec_uid=OTHER),
            ], False, None)),
            body=profile(7),
        )
        code = await self.scan("https://www.douyin.com/user/" + SEC, page_limit=2)
        self.assertEqual(code, 1)
        self.assertEqual(self._posted_ids(), ["7000000000000000090"])
        done = self.events[-1]
        self.assertEqual(done["reason"], "partial")
        self.assertFalse(done["complete"])

    async def test_sibling_aweme_list_is_merged_and_deduped(self):
        pinned = aweme("7000000000000000101")
        body = page([aweme("7000000000000000100"), pinned], False, None)
        body["top_aweme_list"] = [pinned, aweme("7000000000000000102")]
        self._arm(lambda request: httpx.Response(200, json=body), body=profile(3))
        code = await self.scan("https://www.douyin.com/user/" + SEC, page_limit=2)
        self.assertEqual(code, 0)
        self.assertEqual(self._posted_ids(), [
            "7000000000000000100",
            "7000000000000000101",
            "7000000000000000102",
        ])
        self.assertEqual(self.events[-1]["reason"], "complete")

    async def test_empty_first_page_is_not_complete(self):
        self.routes[("HEAD", "/")] = httpx.Response(200)
        self.routes[("GET", "/aweme/v1/web/user/profile/other/")] = httpx.Response(200, json=profile())
        self.routes[("GET", "/aweme/v1/web/aweme/post/")] = httpx.Response(200, json=page([], False, None))
        code = await self.scan("https://www.iesdouyin.com/share/user/?sec_uid=" + SEC, page_limit=3)
        self.assertEqual(code, 1)
        done = self.events[-1]
        self.assertEqual(done["reason"], "empty")
        self.assertFalse(done["complete"])
        self.assertEqual(done["received"], 0)

    async def test_limit_duplicate_http_and_bad_json(self):
        cases = {
            "limit": lambda request: httpx.Response(200, json=page([aweme("7000000000000000001")], True, "77")),
            "duplicate": None,
            "http": lambda request: httpx.Response(503, content=b"nope"),
            "bad": lambda request: httpx.Response(200, content=b"<html>login</html>"),
            "restricted": lambda request: httpx.Response(200, json={"status_code": 2154}),
        }

        async def run(name, route, limit=2):
            self.events.clear()
            self.seen.clear()
            self.routes = {
                ("HEAD", "/"): httpx.Response(200),
                ("GET", "/aweme/v1/web/user/profile/other/"): httpx.Response(200, json=profile()),
                ("GET", "/aweme/v1/web/aweme/post/"): route,
            }
            return await self.scan("https://www.douyin.com/user/" + SEC, page_limit=limit)

        code = await run("limit", cases["limit"], limit=1)
        self.assertEqual(code, 1)
        self.assertEqual(self.events[-1]["reason"], "limit")
        self.assertFalse(self.events[-1]["complete"])
        self.assertEqual(self.events[-1]["cursor"], "77")
        self.assertEqual(sum(1 for item in self.seen if item[2] == "/aweme/v1/web/aweme/post/"), 1)

        def duplicate(request):
            return httpx.Response(200, json=page([aweme("7000000000000000004")], True, request.url.params.get("max_cursor") or "0"))

        # 第一页 cursor 与请求的 0 不同，第二页把 max_cursor 设回已请求过的值。
        def looping(request):
            cursor = request.url.params.get("max_cursor") or "0"
            if cursor == "0":
                return httpx.Response(200, json=page([aweme("7000000000000000004")], True, "55"))
            return httpx.Response(200, json=page([aweme("7000000000000000005")], True, "55"))

        code = await run("duplicate", looping, limit=5)
        self.assertEqual(self.events[-1]["reason"], "duplicate_cursor")
        self.assertFalse(self.events[-1]["complete"])
        self.assertGreaterEqual(self.events[-1]["received"], 1)

        code = await run("http", cases["http"])
        self.assertEqual(self.events[-1]["reason"], "http")
        self.assertFalse(self.events[-1]["complete"])

        code = await run("bad", cases["bad"])
        self.assertEqual(self.events[-1]["reason"], "bad_json")
        self.assertFalse(self.events[-1]["complete"])

        code = await run("restricted", cases["restricted"])
        self.assertEqual(self.events[-1]["reason"], "restricted")
        self.assertFalse(self.events[-1]["complete"])

    async def test_short_link_whitelist_and_redirect_cap(self):
        self.routes[("GET", "/abc/")] = httpx.Response(302, headers={"location": "https://evil.example/steal"})
        code = await self.scan("https://v.douyin.com/abc/", page_limit=1)
        self.assertEqual(code, 1)
        self.assertEqual(self.events[-1]["event"], "error")
        self.assertNotIn("evil.example", [host for _, host, _ in self.seen])

        self.events.clear()
        self.seen.clear()
        self.routes = {
            ("GET", "/abc/"): httpx.Response(302, headers={"location": "https://v.douyin.com/r1"}),
            ("GET", "/r1"): httpx.Response(302, headers={"location": "https://v.douyin.com/r2"}),
            ("GET", "/r2"): httpx.Response(302, headers={"location": "https://v.douyin.com/r3"}),
            ("GET", "/r3"): httpx.Response(302, headers={"location": "https://v.douyin.com/r4"}),
            ("GET", "/r4"): httpx.Response(302, headers={"location": "https://www.douyin.com/video/7000000000000000001"}),
        }
        code = await self.scan("https://v.douyin.com/abc/", page_limit=1)
        self.assertEqual(code, 1)
        self.assertNotIn("/video/7000000000000000001", [path for _, _, path in self.seen])

        self.events.clear()
        self.seen.clear()
        self.routes = {
            ("GET", "/abc/"): httpx.Response(302, headers={"location": "https://v.douyin.com/r1"}),
            ("GET", "/r1"): httpx.Response(302, headers={"location": "https://v.douyin.com/r2"}),
            ("GET", "/r2"): httpx.Response(302, headers={"location": "https://v.douyin.com/r3"}),
            ("GET", "/r3"): httpx.Response(302, headers={"location": "https://v.douyin.com/r4"}),
            ("GET", "/r4"): httpx.Response(302, headers={"location": "https://www.douyin.com/user/" + SEC}),
            ("GET", "/r5"): httpx.Response(302, headers={"location": "https://www.douyin.com/user/" + SEC}),
            ("HEAD", "/"): httpx.Response(200),
            ("GET", "/aweme/v1/web/user/profile/other/"): httpx.Response(200, json=profile(1)),
            ("GET", "/aweme/v1/web/aweme/post/"): httpx.Response(200, json=page([aweme("7000000000000000008")], False, None)),
        }
        code = await self.scan("https://v.douyin.com/abc/", page_limit=1)
        self.assertEqual(code, 0, self.events[-1])
        self.assertNotIn("/r5", [path for _, _, path in self.seen])

    def test_sec_shape(self):
        self.assertTrue(SEC_RE.fullmatch(SEC))
        self.assertFalse(SEC_RE.fullmatch("../etc/passwd"))
        self.assertFalse(SEC_RE.fullmatch("12345"))


class WorkerCliTests(unittest.TestCase):
    def setUp(self):
        (WT / 'build').mkdir(exist_ok=True)
        temporary = tempfile.TemporaryDirectory(prefix='shiying-seen-check-', dir=WT / 'build')
        self.qa_root = Path(temporary.name)
        self.addCleanup(temporary.cleanup)
    def run_worker(self, *args):
        return subprocess.run(
            [PY, str(WT / "Backend/worker.py"), *args],
            cwd=WT,
            env=ENV,
            capture_output=True,
            text=True,
        )

    def test_sys_path_line_unchanged(self):
        text = (WT / "Backend/worker.py").read_text()
        self.assertIn("sys.path.insert(0, str(Path(__file__).parent / 'upstream' / 'src'))", text)

    def test_info_and_download_still_reject_foreign_hosts(self):
        for command in ("info", "download"):
            result = self.run_worker(command, "--link", "https://evil.example/video/1")
            self.assertEqual(result.returncode, 1, result.stderr)
            event = json.loads(result.stdout.strip().splitlines()[-1])
            self.assertEqual(event["event"], "error")
            self.assertIn("请粘贴当前平台的官方分享链接", event["message"])

    def test_page_limit_bounds_and_help(self):
        low = self.run_worker("scan", "--page-limit", "0", "--link", "https://www.douyin.com/user/" + SEC)
        self.assertEqual(low.returncode, 1)
        self.assertIn("1 到 500", json.loads(low.stdout)["message"])
        high = self.run_worker("scan", "--page-limit", "501", "--link", "https://www.douyin.com/user/" + SEC)
        self.assertEqual(high.returncode, 1)
        self.assertEqual(json.loads(high.stdout)["event"], "error")
        bad = self.run_worker("scan", "--page-limit", "abc", "--link", "https://www.douyin.com/user/" + SEC)
        self.assertEqual(bad.returncode, 2)
        help_text = self.run_worker("--help")
        self.assertEqual(help_text.returncode, 0)
        for word in ("info", "download", "convert", "scan", "resume-cursor", "page-limit", "seen-ids-file", "prior-partial"):
            self.assertIn(word, help_text.stdout)
        self.assertNotIn("--seen-ids ", help_text.stdout)

    def test_seen_ids_argv_is_rejected(self):
        legacy = self.run_worker("scan", "--seen-ids", "7000000000000000001", "--link", "https://www.douyin.com/user/" + SEC)
        self.assertEqual(legacy.returncode, 2)
        self.assertNotIn('"complete": true', legacy.stdout)

    def _private_seen(self, payload):
        path = Path(tempfile.gettempdir()) / ("shiying-seen-%s.json" % uuid.uuid4())
        path.write_text(payload if isinstance(payload, str) else json.dumps(payload), encoding="utf-8")
        return path

    def test_bad_seen_file_fails_and_is_deleted(self):
        path = self._private_seen("[1, true]")
        result = self.run_worker(
            "scan",
            "--page-limit",
            "1",
            "--seen-ids-file",
            str(path),
            "--link",
            "https://www.douyin.com/user/" + SEC,
        )
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertFalse(path.exists())
        event = json.loads(result.stdout.strip().splitlines()[-1])
        self.assertEqual(event["event"], "error")
        self.assertIn("非法", event["message"])
        self.assertNotIn('"complete": true', result.stdout)

    def test_duplicate_seen_ids_fail_the_count_check(self):
        path = self._private_seen(["7000000000000000001", "7000000000000000001"])
        result = self.run_worker("scan", "--seen-ids-file", str(path), "--link", "https://www.douyin.com/user/" + SEC)
        self.assertEqual(result.returncode, 1)
        self.assertFalse(path.exists())
        event = json.loads(result.stdout.strip().splitlines()[-1])
        self.assertIn("数量", event["message"])

    def test_seen_file_outside_temp_is_not_deleted(self):
        foreign = self.qa_root / "not-seen.json"
        foreign.write_text("[]", encoding="utf-8")
        try:
            result = self.run_worker("scan", "--seen-ids-file", str(foreign), "--link", "https://evil.example/user/x")
            self.assertEqual(result.returncode, 1)
            self.assertTrue(foreign.exists())
            self.assertNotIn('"complete": true', result.stdout)
        finally:
            foreign.unlink(missing_ok=True)

    def test_valid_seen_file_is_deleted_when_scan_fails(self):
        path = self._private_seen(["7000000000000000001"])
        result = self.run_worker("scan", "--seen-ids-file", str(path), "--link", "https://evil.example/user/x")
        self.assertEqual(result.returncode, 1)
        self.assertFalse(path.exists())
        event = json.loads(result.stdout.strip().splitlines()[-1])
        self.assertEqual(event["event"], "error")

    def test_page_limit_failure_still_deletes_seen_file(self):
        path = self._private_seen(["7000000000000000001"])
        result = self.run_worker(
            "scan",
            "--page-limit",
            "0",
            "--seen-ids-file",
            str(path),
            "--link",
            "https://www.douyin.com/user/" + SEC,
        )
        self.assertEqual(result.returncode, 1)
        self.assertFalse(path.exists())
        self.assertIn("1 到 500", json.loads(result.stdout)["message"])

    def test_load_seen_ids_file_checks_shape_and_count(self):
        path = self.qa_root / "sample-seen.json"
        path.write_text(json.dumps(["7000000000000000002", "7000000000000000001"]), encoding="utf-8")
        try:
            found = creator_worker.load_seen_ids_file(str(path))
            self.assertEqual(found, {"7000000000000000001", "7000000000000000002"})
            path.write_text(json.dumps({"ids": ["1"]}), encoding="utf-8")
            with self.assertRaises(ValueError):
                creator_worker.load_seen_ids_file(str(path))
        finally:
            path.unlink(missing_ok=True)
        kept = self.qa_root / "keep-me.json"
        kept.write_text("[]", encoding="utf-8")
        try:
            creator_worker.discard_seen_file(str(kept))
            self.assertTrue(kept.exists())
        finally:
            kept.unlink(missing_ok=True)

    def test_import_file_is_root_upstream(self):
        import dtk
        self.assertTrue(dtk.__file__.startswith(str(ROOT / "Backend/upstream/src")))


if __name__ == "__main__":
    unittest.main()
