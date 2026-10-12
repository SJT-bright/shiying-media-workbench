import io, json, unittest, asyncio
from unittest.mock import patch, AsyncMock
import httpx, metrics_worker as mw, creator_worker as cw
A='7000000000000000001'; B='7000000000000000002'
def raw(vid=A, **stats): return dict(aweme_id=vid,statistics=dict(digg_count=11,comment_count=2,collect_count=3,play_count=0,**stats))
class MetricsTests(unittest.TestCase):
 def test_zero_views_is_not_a_count(self):
  s=mw.statistics(raw(),123);self.assertIsNone(s['viewCount']);self.assertEqual(s['commentCount'],2);self.assertEqual(s['observedAt'],123)
 def test_positive_views_preserved(self):
  r=raw();r['statistics']['play_count']=17;self.assertEqual(mw.statistics(r)['viewCount'],17)
 def test_real_zero_engagement_is_preserved(self):
  s=mw.statistics(dict(statistics=dict(digg_count=0,comment_count=0,collect_count=0)));self.assertEqual(s['likeCount'],0);self.assertEqual(s['commentCount'],0)
 def test_platform_cover_extracted_from_detail(self):
  r=raw();r['video']=dict(cover=dict(url_list=['https://p3-sign.douyinpic.com/x.jpg']));self.assertEqual(mw.statistics(r)['coverURL'],'https://p3-sign.douyinpic.com/x.jpg')
 def test_cover_falls_back_to_origin_and_rejects_invalid(self):
  r=raw();r['video']=dict(cover=dict(url_list=[]),origin_cover=dict(url_list=['https://p26-sign.douyinpic.com/o.jpeg']));self.assertEqual(mw.statistics(r)['coverURL'],'https://p26-sign.douyinpic.com/o.jpeg')
  bad=raw();bad['video']=dict(cover=dict(url_list=['ftp://bad',None,'https://'+'a'*3000]));self.assertIsNone(mw.statistics(bad)['coverURL'])
  self.assertIsNone(mw.statistics(raw())['coverURL'])
 def test_invalid_numbers_never_become_zero(self):
  for x in [True,-1,1.5,'1.5',2**63,'-1',None]:self.assertIsNone(mw.count(x))
 def test_cover_metadata_never_blocks_valid_statistics(self):
  for url in ['http-not-a-url','https://bad.example/x.jpg','https://user:pass@p3.douyinpic.com/x.jpg','https://p3.douyinpic.com:999/x.jpg']:
   r=raw();r['video']=dict(cover=dict(url_list=[url]));s=mw.statistics(r)
   self.assertEqual(s['likeCount'],11);self.assertIsNone(s['coverURL'])
  self.assertEqual(mw.approved_cover_url('http://p3.douyinpic.com/x.jpg#fragment'),'https://p3.douyinpic.com/x.jpg')
 def test_homepage_refresh_preserves_platform_cover_metadata(self):
  from test_creator_regression import aweme,page,SEC
  item=aweme(A);item['video']['cover']={'url_list':['https://p3.douyinpic.com/cover.jpg']}
  events,_=self.run_batch([page([item],False,None)],ids=[A],homes={A:'https://www.douyin.com/user/'+SEC})
  self.assertEqual(next(x['statistics']['coverURL'] for x in events if x['event']=='metrics_value'),'https://p3.douyinpic.com/cover.jpg')
 def test_missing_statistics_is_specific(self):
  with self.assertRaises(cw.ScanFailure) as c:mw.statistics({})
  self.assertEqual(c.exception.diagnostic['code'],'missing_statistics')
 def test_request_deduplication(self):
  ids,_,_=mw.read_request(io.BytesIO(json.dumps(dict(ids=[A,A,B],cookies=[])).encode()));self.assertEqual(ids,[A,B])
 def test_request_limits_no_truncation(self):
  for ids in [[],[A]*5001,['../bad']]:
   with self.assertRaises(ValueError):mw.read_request(io.BytesIO(json.dumps(dict(ids=ids)).encode()))
 def test_credential_error_does_not_echo_value(self):
  with self.assertRaises(ValueError) as c:mw.read_request(io.BytesIO(json.dumps(dict(ids=[A],cookies=[dict(name='x',value='PRIVATE',domain='evil.example',path='/')])).encode()))
  self.assertNotIn('PRIVATE',str(c.exception))
 def run_batch(self,side,ids=[A,B],delays=(),homes=None):
  events=[]
  with patch.object(cw,'signed_get',new=AsyncMock(side_effect=side)) as get,patch('worker.emit',side_effect=lambda e,**k:events.append(dict(event=e,**k))):
   asyncio.run(mw.run_metrics(ids,httpx.Cookies(),client=object(),pause_seconds=0,retry_delays=delays,homepages=homes))
  return events,get.await_count
 def test_identity_mismatch_does_not_stop_next_work(self):
  events,n=self.run_batch([dict(aweme_detail=raw(B)),dict(aweme_detail=raw(B))]);self.assertEqual(n,2)
  self.assertIn('identity_mismatch',next(x['message'] for x in events if x['event']=='metrics_failure'))
  self.assertEqual([x['id'] for x in events if x['event']=='metrics_value'],[B])
 def test_http_failure_is_specific_and_retains_others(self):
  events,n=self.run_batch([cw.ScanFailure('http','HTTP失败',code='http_status',httpStatus=503),dict(aweme_detail=raw(B))])
  self.assertIn('httpStatus=503',next(x['message'] for x in events if x['event']=='metrics_failure'));self.assertEqual(events[-1]['failed'],1)
 def test_auth_challenge_stops_remaining_requests(self):
  events,n=self.run_batch([dict(not_login_module=dict(guide_login_tip_exist=True))]);self.assertEqual(n,1);self.assertEqual(events[-1]['failed'],2)
 def test_transient_fault_has_bounded_retry(self):
  events,n=self.run_batch([cw.ScanFailure('timeout','超时',retryable=True),dict(aweme_detail=raw(A))],ids=[A],delays=(0,))
  self.assertEqual(n,2);self.assertEqual(events[-1]['succeeded'],1)
 def test_homepage_groups_reduce_requests_and_filter_unrequested(self):
  from test_creator_regression import aweme,page,SEC
  homes={A:'https://www.douyin.com/user/'+SEC,B:'https://www.douyin.com/user/'+SEC}
  events,n=self.run_batch([page([aweme(A),aweme(B),aweme('7000000000000000003')],True,40)],homes=homes)
  self.assertEqual(n,1);self.assertEqual(events[-1]['succeeded'],2)
  self.assertEqual({x['id'] for x in events if x['event']=='metrics_value'},{A,B})
 def test_homepage_second_page_fault_preserves_first_and_reports_page(self):
  from test_creator_regression import aweme,page,SEC
  homes=dict.fromkeys([A,B],'https://www.douyin.com/user/'+SEC)
  events,n=self.run_batch([page([aweme(A)],True,40),cw.ScanFailure('http','HTTP 503',httpStatus=503,code='http_status')],homes=homes)
  self.assertEqual(n,2);self.assertEqual(events[-1]['succeeded'],1)
  self.assertIn('主页第2页',next(x['message'] for x in events if x['event']=='metrics_failure'));self.assertEqual(events[-1]['failed'],1)
 def test_homepage_missing_work_is_not_false_success(self):
  from test_creator_regression import aweme,page,SEC
  events,n=self.run_batch([page([aweme(A)],False,None)],homes=dict.fromkeys([A,B],'https://www.douyin.com/user/'+SEC))
  self.assertEqual(n,1);self.assertEqual(events[-1]['failed'],1);self.assertIn('work_not_in_homepage',next(x['message'] for x in events if x['event']=='metrics_failure'))
 def test_homepage_foreign_author_never_updates_work(self):
  from test_creator_regression import aweme,page,SEC,OTHER
  events,_=self.run_batch([page([aweme(A,sec_uid=OTHER)],False,None)],ids=[A],homes={A:'https://www.douyin.com/user/'+SEC})
  self.assertEqual(events[-1]['succeeded'],0)
 def test_homepage_login_challenge_stops_detail_fallback(self):
  from test_creator_regression import SEC
  events,n=self.run_batch([dict(not_login_module=dict(guide_login_tip_exist=True))],homes={A:'https://www.douyin.com/user/'+SEC})
  self.assertEqual(n,1);self.assertEqual(events[-1]['failed'],2)
 def test_invalid_or_unrequested_homepage_rejected(self):
  for homes in [{A:'https://evil.example/user/MS4wX'},{B:'https://www.douyin.com/user/MS4wX'}]:
   with self.assertRaises(ValueError):mw.read_request(io.BytesIO(json.dumps(dict(ids=[A],cookies=[],homepages=homes)).encode()))
 def test_homepage_temporary_status_only_retries_same_page(self):
  from test_creator_regression import aweme,page,SEC
  events,n=self.run_batch([dict(status_code=0),page([aweme(A),aweme(B)],False,None)],homes=dict.fromkeys([A,B],'https://www.douyin.com/user/'+SEC),delays=(0,))
  self.assertEqual(n,2);self.assertEqual(events[-1]['succeeded'],2)
if __name__=='__main__':unittest.main()
