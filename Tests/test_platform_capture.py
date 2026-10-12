"""Run the shipped WKWebView script against synthetic DOM/JSON; no network/login."""
import json
from pathlib import Path
import subprocess
import unittest

SCRIPT = Path('Sources/PlatformWebCapture.swift').read_text().split('static let script = #"""', 1)[1].split('"""#', 1)[0]


class CaptureChecks(unittest.TestCase):
    def run_capture(self, url, initial=None, videos=None, anchors=None, navigate=None):
        harness = '''
        const vm=require('node:vm');
        const input=JSON.parse(require('node:fs').readFileSync(0,'utf8'));
        const loc=new URL(input.url);
        const fakeXHR=function(){}; fakeXHR.prototype.send=function(){};
        const context={URL, XMLHttpRequest:fakeXHR, location:loc,
          document:{title:'合成网页',querySelectorAll:s=>s==='video'?input.videos:input.anchors},
          window:{fetch:async()=>({headers:{get:()=>''}}),__INITIAL_STATE__:input.initial}};
        vm.createContext(context);vm.runInContext(input.script,context);
        const before=context.window.__shiyingCapture.read();
        if(input.navigate){context.location=new URL(input.navigate);context.window.__INITIAL_STATE__=null;context.document.querySelectorAll=()=>[];}
        process.stdout.write(JSON.stringify({before,after:context.window.__shiyingCapture.read()}));
        '''
        result = subprocess.run(['node', '-e', harness], input=json.dumps(dict(script=SCRIPT, url=url, initial=initial, videos=videos or [], anchors=anchors or [], navigate=navigate)), text=True, capture_output=True, check=True)
        return json.loads(result.stdout)

    def test_bilibili_visible_links_and_cross_host_rejection(self):
        result = self.run_capture('https://space.bilibili.com/1', anchors=[dict(href='https://www.bilibili.com/video/BV1xx411c7mD?from=space', title='可见作品', textContent=''), dict(href='https://bilibili.com.evil.example/video/BVfake', title='伪造主机', textContent='')])
        self.assertEqual([p['id'] for p in result['before']['capturedPosts']], ['BV1xx411c7mD'])
        self.assertNotIn('mediaURL', result['before']['capturedPosts'][0])

    def test_wechat_actual_src_and_blob_rejection(self):
        result = self.run_capture('https://channels.weixin.qq.com/platform', videos=[dict(currentSrc='https://finder.video.qq.com/fixture.mp4?token=synthetic', src='', poster=''), dict(currentSrc='blob:https://channels.weixin.qq.com/fake', src='', poster='')])
        posts = result['before']['capturedPosts']
        self.assertEqual(len(posts), 1)
        self.assertIn('#shiying-capture-', posts[0]['link'])
        self.assertEqual(posts[0]['author'], '')

    def test_encrypted_media_not_reclassified_by_dom(self):
        result = self.run_capture('https://channels.weixin.qq.com/platform', initial=dict(id='encrypted', objectDesc=dict(decodeKey='synthetic', media=[dict(url='https://finder.video.qq.com/encrypted.mp4')])), videos=[dict(currentSrc='https://finder.video.qq.com/encrypted.mp4', src='', poster='')])
        self.assertTrue(result['before']['encrypted'])
        self.assertEqual(result['before']['capturedPosts'], [])

    def test_cross_creator_navigation_discards_capture(self):
        result = self.run_capture('https://channels.weixin.qq.com/platform?author=one', videos=[dict(currentSrc='https://finder.video.qq.com/one.mp4', src='', poster='')], navigate='https://channels.weixin.qq.com/platform?author=two')
        self.assertEqual(len(result['before']['capturedPosts']), 1)
        self.assertEqual(result['after']['capturedPosts'], [])

    def test_xhs_video_id_title_and_token_stay_bound(self):
        result = self.run_capture('https://www.xiaohongshu.com/explore/abcdef123456789012345678', initial=dict(noteId='abcdef123456789012345678', xsecToken='SYNTHETIC_ONLY', desc='可见作品', user=dict(nickname='合成作者'), video=dict(media=dict(stream=dict(h264=[dict(masterUrl='https://sns-video-bd.xhscdn.com/fixture.mp4')])))))
        post = result['before']['capturedPosts'][0]
        self.assertEqual(post['id'], 'abcdef123456789012345678')
        self.assertEqual(post['title'], '可见作品')
        self.assertIn('xsec_token=SYNTHETIC_ONLY', post['link'])


if __name__ == '__main__':
    unittest.main()
