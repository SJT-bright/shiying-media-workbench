import asyncio, io, json, unittest
from unittest.mock import patch
import httpx, metrics_worker as mw, platform_worker as pw, worker

DY='7000000000000000001'; BV='BV1yraa6jERQ'; SHARE='https://weixin.qq.com/sph/TestShare'
def row(platform):
    if platform=='douyin':return dict(id=DY,platform=platform,link='https://www.douyin.com/video/'+DY)
    if platform=='bilibili':return dict(id='bilibili:'+BV,platform=platform,link='https://www.bilibili.com/video/'+BV)
    return dict(id='wechat:share:TestShare',platform=platform,link=SHARE,videoID='same-id')
def request(works,sessions=None):return io.BytesIO(json.dumps(dict(version=2,works=works,sessions=sessions or {})).encode())

class PlatformStatisticsTests(unittest.TestCase):
    def test_platform_keys_and_cookies_are_separate(self):
        cookie=dict(name='hy_token',value='synthetic-secret',domain='yuanbao.tencent.com',path='/')
        works,sessions=mw.read_multi_request(request([row('douyin'),row('bilibili'),row('wechat')],
            {'wechat':dict(version=1,platform='wechat',cookies=[cookie])}))
        self.assertEqual(len(works),3);self.assertEqual(sessions['wechat']['cookies'],[cookie])
        self.assertFalse(list(sessions['douyin'].jar));self.assertEqual(sessions['bilibili']['cookies'],[])
    def test_cross_platform_session_rejected(self):
        bad=dict(version=1,platform='bilibili',cookies=[])
        with self.assertRaises(ValueError):mw.read_multi_request(request([row('wechat')],{'wechat':bad}))
        bad=dict(version=1,platform='wechat',cookies=[dict(name='x',value='private',domain='bilibili.com',path='/')])
        with self.assertRaises(ValueError):mw.read_multi_request(request([row('wechat')],{'wechat':bad}))
    def test_key_and_link_must_match(self):
        bad=row('wechat');bad['id']='wechat:share:Other'
        with self.assertRaises(ValueError):mw.read_multi_request(request([bad]))
        bad=row('bilibili');bad['link']='https://www.bilibili.com/video/BV1bK411W797'
        with self.assertRaises(ValueError):mw.read_multi_request(request([bad]))
    def test_legacy_request_remains_readable(self):
        works,sessions=mw.read_multi_request(io.BytesIO(json.dumps(dict(ids=[DY],cookies=[])).encode()))
        self.assertEqual(works[0]['id'],DY);self.assertIn('douyin',sessions)
    def test_maximum_not_silently_truncated(self):
        with self.assertRaises(ValueError):mw.read_multi_request(request([row('wechat')]*5001))
    def test_wechat_real_fmt_schema_and_metric_meaning(self):
        raw={'errCode':0,'data':{'feedInfo':{'likeCountFmt':'1504','favCountFmt':'3474','commentCountFmt':'198','forwardCountFmt':'2.1万'},'authorInfo':{}}}
        info=pw._wechat_feed_info(raw,SHARE,statistics_only=True)
        stats=mw.platform_statistics(info,'wechat')
        self.assertEqual((stats['likeCount'],stats['recommendCount'],stats['commentCount']),(1504,3474,198))
        self.assertIsNone(stats['collectCount']);self.assertIsNone(stats['viewCount']);self.assertIsNone(stats['shareCount'])
        self.assertEqual(stats['displayCounts']['share'],'2.1万');self.assertEqual(info['formats'],[])
    def test_wechat_zero_and_missing_are_distinct(self):
        stats=mw.platform_statistics({'like_count':0,'recommend_count':0,'comment_count':0},'wechat')
        self.assertEqual(stats['likeCount'],0);self.assertIsNone(stats['shareCount'])
        with self.assertRaises(ValueError):mw.platform_statistics({},'wechat')
    def test_bilibili_identity_and_public_zero(self):
        async def run(data):
            async with httpx.AsyncClient(transport=httpx.MockTransport(lambda req:httpx.Response(200,json={'code':0,'data':data}))) as client:
                return await mw.fetch_bilibili_statistics(row('bilibili'),client=client,retry_delays=())
        stats=asyncio.run(run({'bvid':BV,'stat':{'view':0,'like':1,'reply':2,'favorite':3}}))
        self.assertEqual(stats['viewCount'],0);self.assertTrue(stats['viewCountIsPublic']);self.assertEqual(stats['collectCount'],3)
        with self.assertRaisesRegex(ValueError,'ID'):asyncio.run(run({'bvid':'BV1bK411W797','stat':{'view':999}}))
    def test_multi_summary_only_emitted_once_and_no_media_urls(self):
        events=[]
        async def fake_wechat(link,session=None,**kw):return dict(id='same-id',like_count=1,comment_count=2,recommend_count=3)
        async def fake_bili(work,session=None,**kw):return mw.platform_statistics(dict(like_count=4,view_count=5),'bilibili')
        with patch.object(pw,'fetch_wechat_share_info',fake_wechat),patch.object(mw,'fetch_bilibili_statistics',fake_bili),patch.object(worker,'emit',lambda e,**d:events.append(dict(event=e,**d))):
            asyncio.run(mw.run_multi_metrics([row('wechat'),row('bilibili')],{},pause_seconds=0))
        terminal=[e for e in events if e['event']=='metrics_complete'];self.assertEqual(len(terminal),1)
        self.assertEqual((terminal[0]['total'],terminal[0]['succeeded'],terminal[0]['failed']),(2,2,0))
        self.assertEqual({e['id'] for e in events if e['event']=='metrics_value'},{'wechat:share:TestShare','bilibili:'+BV})
        self.assertNotIn('videoUrl',json.dumps(events));self.assertNotIn('cookies',json.dumps(events))
    def test_wechat_identity_failure_does_not_block_other_platform(self):
        events=[]
        async def fake(link,session=None,**kw):return dict(id='different',like_count=999)
        async def bili(*a,**kw):return mw.platform_statistics(dict(like_count=1),'bilibili')
        with patch.object(pw,'fetch_wechat_share_info',fake),patch.object(mw,'fetch_bilibili_statistics',bili),patch.object(worker,'emit',lambda e,**d:events.append(dict(event=e,**d))):
            asyncio.run(mw.run_multi_metrics([row('wechat'),row('bilibili')],{},pause_seconds=0))
        self.assertEqual(events[-1]['failed'],1);self.assertEqual(events[-1]['succeeded'],1)
        self.assertTrue(any(e['event']=='metrics_failure' and '不一致' in e['message'] for e in events))
