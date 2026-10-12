import unittest,sys
from types import SimpleNamespace as N
sys.path.insert(0,'Backend')
from worker import input_link,choose_stream,dimensions,utf8_limit

def stream(w,h,rate=1,watermark=False): return N(width=w,height=h,bitrate=rate,watermark=watermark)
def content(*streams): return N(media=N(video=streams[0],streams=list(streams[1:])))
class Contracts(unittest.TestCase):
 def test_full_share_and_untrusted_hosts(self):
  self.assertEqual(input_link('8.23 Vibe 知识大赏 https://v.douyin.com/TrJh2pK0v14/ 复制此链接'), 'https://v.douyin.com/TrJh2pK0v14/')
  for link in ['https://douyin.com.attacker.test/video/7690337875291950345','file:///private/tmp/video','普通文案']:
   with self.assertRaises(ValueError): input_link(link)
 def test_quality_prefers_closest_sufficient_source(self):
  c=content(stream(3840,2160,800),stream(1280,720,500),stream(1024,576,450),stream(1280,720,100),stream(7680,4320,999,True))
  self.assertEqual(choose_stream(c,'highest').width,3840)
  self.assertEqual(choose_stream(c,'720').bitrate,500)
  self.assertEqual(choose_stream(c,'480').width,1024)
 def test_landscape_portrait_even_dimensions_and_no_upscale(self):
  self.assertEqual(dimensions(1920,1080,480),(854,480))
  self.assertEqual(dimensions(1080,1920,720),(720,1280))
  self.assertEqual(dimensions(640,360,720),(640,360))
 def test_utf8_filename_budget(self):
  title=utf8_limit('非常长的视频标题'*100,120)
  author=utf8_limit('作者'*100,48)
  self.assertLessEqual(len((author+'_'+title+'_最高画质_7690337875291950345_9999.mp4').encode()),255)
  self.assertNotIn('\ufffd',title)
if __name__=='__main__': unittest.main()
