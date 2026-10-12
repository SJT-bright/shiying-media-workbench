#!/usr/bin/env python3
"""原生 Store 的隔离会话桩；不联网、不记录会话值。"""
import json
import sys
import time

SEC = 'MS4wLjABAAAA_SYNTHETIC_DOUYIN_AUTHOR_0001'
def emit(event, **kw): print(json.dumps(dict(event=event, **kw)), flush=True)
def post(i):
    ident = str(7000000000000000000 + i)
    emit('post', post=dict(id=ident, link=f'https://www.douyin.com/video/{ident}',
                         title=f'更新作品{i}', author='合成作者', isVideo=True, diggCount=20))

if '--session-stdin' not in sys.argv:
    emit('error', message='missing stdin switch'); sys.exit(1)
session = json.loads(sys.stdin.buffer.read())
if isinstance(session, dict) and session.get('platform') == 'wechat':
    cookies = session.get('cookies', [])
    if {r['name'] for r in cookies} != {'hy_user', 'hy_token'} or any(r['domain'] != 'yuanbao.tencent.com' for r in cookies):
        emit('error', message='Yuanbao credentials were not restricted to parser host'); sys.exit(1)
    share = 'https://weixin.qq.com/sph/SYNTHETIC_ONLY'
    emit('creator', id='wechat-fixture', nickname='合成作者', homepage=share, platform='wechat')
    emit('post', post=dict(id='wechat-fixture', link=share + '#shiying-capture-wechat-fixture', title='合成分享', author='合成作者', isVideo=True, platform='wechat'))
    emit('scan_complete', complete=False, reason='share_resolved', received=1, pages=1, cursor=None)
    sys.exit(0)
wrong = session[0]['value'] == 'WRONG_AUTHOR'
author = SEC + '_OTHER' if wrong else SEC
emit('creator', id=author, nickname='合成作者', homepage=f'https://www.douyin.com/user/{author}', awemeCount=19)
time.sleep(0.15)
for i in range(19): post(i)
emit('scan_complete', complete=True, reason='complete', received=19, pages=2, cursor=None,
     awemeCount=19, listedCount=19, gap=0, tainted=False)
