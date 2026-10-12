"""Manual public statistics and cover metadata; no media-stream downloads or credential logs."""
from __future__ import annotations
import asyncio, io, json, re, time
from urllib.parse import urlsplit, urlunsplit
import httpx
import creator_worker as cw
from dtk.platforms.douyin.params import content_detail_params, DEFAULT_PROFILE
MAX_INPUT = 1_048_576
MAX_WORKS = 5000

def count(value):
    if isinstance(value, bool): return None
    if isinstance(value, int): return value if 0 <= value <= 2**63 - 1 else None
    if isinstance(value, str) and re.fullmatch(r'\d{1,19}', value):
        number = int(value)
        return number if number <= 2**63 - 1 else None
    return None

def approved_cover_url(candidate):
    if not isinstance(candidate, str) or len(candidate) > 2048:
        return None
    try:
        parts = urlsplit(candidate)
        host = parts.hostname or ''
        if parts.scheme not in ('http', 'https') or parts.username is not None or parts.password is not None:
            return None
        if parts.port not in (None, 80, 443) or not any(host == suffix or host.endswith('.' + suffix)
                for suffix in ('douyinpic.com', 'byteimg.com', 'zjcdn.com', 'hdslb.com', 'qpic.cn')):
            return None
        return urlunsplit(('https', parts.netloc, parts.path, parts.query, ''))
    except ValueError:
        return None

def cover_url(raw):
    """Platform-uploaded cover only; never a media stream and never logged."""
    video = raw.get('video') if isinstance(raw, dict) else None
    if not isinstance(video, dict): return None
    for field in ('cover', 'origin_cover'):
        node = video.get(field)
        urls = node.get('url_list') if isinstance(node, dict) else None
        if isinstance(urls, list):
            for candidate in urls:
                if approved := approved_cover_url(candidate):
                    return approved
    return None

def statistics(raw, observed_at=None):
    source = raw.get('statistics')
    if not isinstance(source, dict):
        raise cw.ScanFailure('schema', '作品响应缺少 statistics 统计字段。', code='missing_statistics')
    views = count(source.get('play_count'))
    return dict(likeCount=count(source.get('digg_count')), commentCount=count(source.get('comment_count')),
                collectCount=count(source.get('collect_count')), viewCount=views if views and views > 0 else None,
                viewsNote=None if views and views > 0 else '抖音公开网页未提供真实浏览量，0占位值不作为播放量。',
                observedAt=observed_at or int(time.time()), source='抖音公开作品接口',
                coverURL=cover_url(raw))

def read_request(stream):
    data = stream.read(MAX_INPUT + 1)
    if len(data) > MAX_INPUT: raise ValueError('更新请求超过1 MiB，未开始查询。')
    try: request = json.loads(data)
    except (ValueError, UnicodeError): raise ValueError('更新请求不是有效JSON，未开始查询。') from None
    if not isinstance(request, dict): raise ValueError('更新请求格式无效。')
    ids = request.get('ids')
    if not isinstance(ids, list) or not 1 <= len(ids) <= MAX_WORKS:
        raise ValueError('单次更新支持1至5000个作品，超量请分文件夹更新；不截断。')
    if any(not isinstance(x, str) or not re.fullmatch(r'\d{19}', x) for x in ids):
        raise ValueError('更新请求包含无效的抖音作品ID，未开始查询。')
    cookies = cw.read_session(io.BytesIO(json.dumps(request.get('cookies', []), ensure_ascii=False).encode()))
    homes = request.get('homepages', {})
    if not isinstance(homes, dict) or any(key not in ids or not isinstance(value, str) for key, value in homes.items()):
        raise ValueError('统计更新的作品与主页对应关系无效，未开始查询。')
    canonical = {}
    for key, value in homes.items():
        try: sec = cw.sec_from_url(value)
        except ValueError: raise ValueError('统计更新包含无效博主主页，未开始查询。') from None
        if not sec: raise ValueError('统计更新需要完整博主主页，不接受未解析短链。')
        canonical[key] = 'https://www.douyin.com/user/' + sec
    return list(dict.fromkeys(ids)), cookies, canonical

async def run_metrics(ids, cookies, *, homepages=None, client=None, pause_seconds=1.0, retry_delays=(.8,), page_limit=cw.MAX_PAGES, emitter=None):
    from worker import UA, emit
    emit = emitter or emit
    owned = client is None
    if owned: client = httpx.AsyncClient(headers={'User-Agent': UA, 'Referer': cw.ORIGIN}, timeout=cw.REQUEST_TIMEOUT, cookies=cookies)
    start = time.monotonic(); succeeded = failed = 0; handled = set()
    def failure(vid, message):
        nonlocal failed
        if vid not in handled:
            emit('metrics_failure', id=vid, message=message); failed += 1; handled.add(vid)
    def success(vid, snapshot):
        nonlocal succeeded
        if vid not in handled:
            emit('metrics_value', id=vid, statistics=snapshot); succeeded += 1; handled.add(vid)
    def message(exc, location):
        suffix = ''.join(f' {k}={exc.diagnostic[k]}' for k in ['httpStatus','apiStatus','code','attempts'] if exc.diagnostic.get(k) is not None)
        return f'{location}：{exc.detail}{suffix}。上次数据保留；可手动重试。'
    async def request(url, params, path, parse=None):
        for attempt in range(len(retry_delays) + 1):
            try:
                result = await cw.signed_get(client, url, params, path)
                return parse(result) if parse else result
            except cw.ScanFailure as exc:
                exc.diagnostic['attempts'] = attempt + 1
                if not exc.diagnostic['retryable'] or attempt >= len(retry_delays): raise
                await asyncio.sleep(retry_delays[attempt])
    try:
        if owned: await cw._seed_visitor(client)
        groups = {}
        for vid in ids:
            if (home := (homepages or {}).get(vid)): groups.setdefault(home, []).append(vid)
        for home, group_ids in groups.items():
            pending = set(group_ids); cursor = None; seen_cursors = set(); page_number = 0
            try:
                sec = cw.sec_from_url(home)
                for page_number in range(1, page_limit + 1):
                    key = cursor or '0'
                    if key in seen_cursors: raise cw.ScanFailure('schema', '分页游标重复，停止统计更新。', code='duplicate_cursor')
                    seen_cursors.add(key)
                    emit('metrics_progress', done=len(handled), total=len(ids), detail=f'正在读取博主作品第{page_number}页，只更新已保存作品。')
                    page = await request(cw.DouyinAPIEndpoints.USER_POST,
                        cw.author_posts_params(sec_user_id=sec, cursor=cursor, count=cw.DEFAULT_PAGE_SIZE, profile=DEFAULT_PROFILE), '/aweme/v1/web/aweme/post/',
                        parse=lambda payload: cw.interpret_posts(payload, sec))
                    for post in page['posts']:
                        vid = post['id']; snapshot = post.get('statistics')
                        if vid not in pending: continue
                        if not isinstance(snapshot, dict) or all(snapshot[k] is None for k in ['likeCount','commentCount','collectCount','viewCount']):
                            failure(vid, f'作品{vid}：本次主页响应没有有效统计字段，保留上次数据。 code=missing_statistics')
                        else:
                            snapshot = dict(snapshot)
                            cover = approved_cover_url(post.get('cover'))
                            if cover:
                                snapshot['coverURL'] = cover
                            success(vid, snapshot)
                        pending.remove(vid)
                    if not pending: break
                    if page['login_required']: raise cw.ScanFailure('login_required', '平台要求登录或验证，请检查拾影内置抖音网页。', code='login_required')
                    if not page['has_more']:
                        for vid in pending: failure(vid, f'作品{vid}：已读取主页末页，但没有返回此作品；可能已删除、私密、作者来源变化或列表不可访问。上次数据保留。 code=work_not_in_homepage')
                        pending.clear(); break
                    cursor = page['cursor']
                    if pause_seconds > 0: await asyncio.sleep(min(pause_seconds, cw.PAGE_PAUSE_SECONDS))
                if pending: raise cw.ScanFailure('limit', f'已达{page_limit}页上限，仍有作品未返回，请分文件夹更新。', code='page_limit')
            except cw.ScanFailure as exc:
                for vid in pending: failure(vid, message(exc, f'作品{vid}，主页第{page_number}页'))
                if exc.reason in {'restricted','login_required'}:
                    for vid in ids: failure(vid, '因平台登录或访问限制停止本轮查询，尚未请求此作品。上次数据保留；请检查内置抖音网页后重试。')
                    break
        for index, vid in enumerate(ids):
            if vid in handled: continue
            emit('metrics_progress', done=index, total=len(ids), id=vid)
            try:
                for attempt in range(len(retry_delays) + 1):
                    try:
                        payload = await cw.signed_get(client, 'https://www.douyin.com/aweme/v1/web/aweme/detail/',
                            content_detail_params(aweme_id=vid, profile=DEFAULT_PROFILE), '/aweme/v1/web/aweme/detail/')
                        if cw.requires_login(payload): raise cw.ScanFailure('login_required', '平台要求登录或验证，请检查拾影内置抖音网页。', code='login_required')
                        raw = payload.get('aweme_detail')
                        if not isinstance(raw, dict): raise cw.ScanFailure('unavailable', '作品详情未返回，作品可能已删除、设为私密或受访问限制。', code='missing_aweme_detail')
                        if str(raw.get('aweme_id')) != vid: raise cw.ScanFailure('identity', '接口作品ID与请求不一致，未更新数据。', code='identity_mismatch')
                        snapshot = statistics(raw)
                        if all(snapshot[k] is None for k in ['likeCount','commentCount','collectCount','viewCount']):
                            raise cw.ScanFailure('schema', '四项统计均未返回有效数字，保留上次数据。', code='all_statistics_missing')
                        break
                    except cw.ScanFailure as exc:
                        exc.diagnostic['attempts'] = attempt + 1
                        if not exc.diagnostic['retryable'] or attempt >= len(retry_delays): raise
                        await asyncio.sleep(retry_delays[attempt])
                success(vid, snapshot)
            except cw.ScanFailure as exc:
                failure(vid, message(exc, f'作品{vid}'))
                if exc.reason in {'restricted','login_required'}:
                    for remaining in ids[index+1:]:
                        failure(remaining, '因平台登录或访问限制停止本轮查询，尚未请求此作品。上次数据保留；请检查内置抖音网页后重试。')
                    break
            if index + 1 < len(ids): await asyncio.sleep(pause_seconds)
        emit('metrics_complete', total=len(ids), succeeded=succeeded, failed=failed, seconds=round(time.monotonic()-start, 2))
        return 0
    finally:
        if owned: await client.aclose()


def read_multi_request(stream):
    """V2 keys include the platform; sessions never cross platform boundaries."""
    import platform_worker as pw
    data = stream.read(MAX_INPUT + 1)
    if len(data) > MAX_INPUT: raise ValueError('更新请求超过1 MiB，未开始查询。')
    try: request = json.loads(data)
    except (ValueError, UnicodeError): raise ValueError('更新请求不是有效JSON，未开始查询。') from None
    if not isinstance(request, dict): raise ValueError('更新请求格式无效。')
    if 'works' not in request:
        ids, cookies, homes = read_request(io.BytesIO(data))
        return [{'id': x, 'platform': 'douyin', 'link': 'https://www.douyin.com/video/' + x,
                 'homepage': homes.get(x)} for x in ids], {'douyin': cookies}
    works = request.get('works')
    if request.get('version') != 2 or not isinstance(works, list) or not 1 <= len(works) <= MAX_WORKS:
        raise ValueError('单次更新支持1至5000个作品，超量请分文件夹更新；不截断。')
    checked = {}
    for work in works:
        if not isinstance(work, dict) or work.get('platform') not in ('douyin', 'bilibili', 'wechat'):
            raise ValueError('统计请求包含未知平台，未开始查询。')
        platform, key = work['platform'], work.get('id')
        if not isinstance(key, str) or not isinstance(work.get('link'), str): raise ValueError('统计作品标识无效。')
        _, link = pw.input_url(work['link'], platform)
        path = pw.urlsplit(link).path
        if platform == 'douyin':
            if not re.fullmatch(r'\d{19}', key) or not re.fullmatch(r'/(?:video|note)/' + key + '/?', path):
                raise ValueError('抖音统计ID与链接不一致。')
        elif platform == 'bilibili':
            if not re.fullmatch(r'bilibili:(?:BV[A-Za-z0-9]{10}|av\d{1,20})', key): raise ValueError('B站统计标识无效。')
            found = re.fullmatch(r'/video/(BV[A-Za-z0-9]{10}|av\d{1,20})/?', path)
            if not found and pw.urlsplit(link).hostname != 'b23.tv': raise ValueError('B站统计需要单个视频链接。')
            if found and found[1].startswith('BV') and found[1] != key.split(':',1)[1]:
                raise ValueError('B站统计ID与链接不一致。')
        else:
            match = re.fullmatch(r'/sph/([A-Za-z0-9_-]{1,180})/?', path)
            if match:
                if key != 'wechat:share:' + match[1]: raise ValueError('视频号统计标识与分享链接不一致。')
            elif not re.fullmatch(r'wechat:object:[A-Za-z0-9_-]{1,180}', key): raise ValueError('视频号统计标识无效。')
        home = work.get('homepage')
        if home is not None:
            if platform != 'douyin' or not isinstance(home,str) or not (sec := cw.sec_from_url(home)):
                raise ValueError('统计更新的主页来源无效。')
            home = 'https://www.douyin.com/user/' + sec
        video_id = work.get('videoID')
        if video_id is not None and (not isinstance(video_id,str) or not re.fullmatch(r'[A-Za-z0-9_-]{1,180}',video_id)):
            raise ValueError('统计更新的原作品标识无效。')
        row = dict(id=key, platform=platform, link=link, homepage=home, videoID=video_id)
        if key in checked and checked[key] != row: raise ValueError('同一统计标识对应多个来源，未开始查询。')
        checked[key] = row
    raw_sessions = request.get('sessions', {})
    if not isinstance(raw_sessions,dict) or any(k not in {w['platform'] for w in checked.values()} for k in raw_sessions):
        raise ValueError('统计登录与请求平台不一致。')
    sessions = {}
    for platform in {w['platform'] for w in checked.values()}:
        raw = raw_sessions.get(platform, [] if platform == 'douyin' else {'version':1,'platform':platform,'cookies':[]})
        encoded = io.BytesIO(json.dumps(raw,ensure_ascii=False).encode())
        if platform == 'douyin': sessions[platform] = cw.read_session(encoded)
        else:
            parsed = pw.read_session(encoded,platform)
            sessions[platform] = {'version':1,'platform':platform,'cookies':parsed['cookies']}
    return list(checked.values()), sessions


def platform_statistics(info, platform):
    snapshot = dict(likeCount=count(info.get('like_count')), commentCount=count(info.get('comment_count')),
        collectCount=count(info.get('favorite_count')), viewCount=count(info.get('view_count')),
        observedAt=int(time.time()), source='视频号官方预览' if platform == 'wechat' else 'B站公开作品接口',
        viewsNote='视频号官方预览未提供浏览量。' if platform == 'wechat' else None,
        recommendCount=count(info.get('recommend_count')), shareCount=count(info.get('share_count')),
        viewCountIsPublic=platform == 'bilibili')
    if platform == 'wechat':
        snapshot['collectCount'] = snapshot['viewCount'] = None
        displays = info.get('statistics_display') or {}
        snapshot['displayCounts'] = {k:v for k,v in displays.items() if k in ('like','recommend','comment','share')
            and isinstance(v,str) and count(v) is None and re.fullmatch(r'[0-9]{1,19}(?:\.[0-9]{1,3})?[万亿wWkK]?\+?',v)}
        snapshot['metricsNote'] = '喜欢与推荐按视频号官方含义分别显示；收藏、浏览未公开。万/亿等数值沿用平台显示，不推算精确计数。'
    if not any(snapshot.get(k) is not None for k in ('likeCount','commentCount','collectCount','viewCount','recommendCount','shareCount')) and not snapshot.get('displayCounts'):
        raise ValueError('作品接口没有返回有效统计；保留上次数据。')
    return snapshot


async def fetch_bilibili_statistics(work, session=None, *, client=None, retry_delays=(.8,1.5)):
    import platform_worker as pw
    from worker import UA
    owned = client is None
    if owned: client = httpx.AsyncClient(cookies=pw.cookie_jar(session), timeout=25, follow_redirects=False)
    try:
        identity = work['id'].split(':',1)[1]
        params = {'bvid':identity} if identity.startswith('BV') else {'aid':identity[2:]}
        for attempt in range(len(retry_delays) + 1):
            response = await client.get('https://api.bilibili.com/x/web-interface/view', params=params,
                headers={'User-Agent':UA,'Referer':'https://www.bilibili.com/'})
            if response.status_code in (408,500,502,503,504) and attempt < len(retry_delays):
                await asyncio.sleep(retry_delays[attempt]); continue
            if response.status_code in (401,403,412,429):
                raise pw.PlatformAccessError('restricted', f'B站作品接口限制访问（HTTP {response.status_code}）；请检查内置B站网页后手动重试。')
            if not response.is_success or len(response.content) > 8*1024*1024:
                raise ValueError(f'B站作品接口未成功返回（HTTP {response.status_code}）。')
            try: payload = response.json()
            except ValueError: raise ValueError('B站作品接口没有返回有效JSON。') from None
            if not isinstance(payload,dict) or payload.get('code') != 0:
                code = payload.get('code') if isinstance(payload,dict) else None
                raise pw.PlatformAccessError('restricted' if code in (-101,-352,-412) else 'unavailable', f'B站作品不可用（业务码{code}），保留上次数据。')
            data = payload.get('data')
            if not isinstance(data,dict) or (data.get('bvid') != identity if identity.startswith('BV') else str(data.get('aid')) != identity[2:]):
                raise ValueError('B站响应作品ID与请求不一致，未更新数据。')
            stat = data.get('stat')
            if not isinstance(stat,dict): raise ValueError('B站响应缺少统计字段。')
            return platform_statistics({'like_count':stat.get('like'),'comment_count':stat.get('reply'),
                'favorite_count':stat.get('favorite'),'view_count':stat.get('view'),'share_count':stat.get('share')},'bilibili')
    finally:
        if owned: await client.aclose()


async def run_multi_metrics(works, sessions, *, pause_seconds=1):
    import platform_worker as pw
    from worker import emit
    started = time.monotonic(); handled = {}; total = len(works)
    def relay(event, **data):
        if event in ('metrics_value','metrics_failure'):
            key = data.get('id')
            if key in handled: return
            handled[key] = event; emit(event,**data)
        elif event == 'metrics_progress': emit(event,detail=data.get('detail',''))
    douyin = [w for w in works if w['platform']=='douyin']
    if douyin:
        await run_metrics([w['id'] for w in douyin],sessions.get('douyin'),
            homepages={w['id']:w['homepage'] for w in douyin if w.get('homepage')}, emitter=relay, pause_seconds=pause_seconds)
    for platform in ('wechat','bilibili'):
        stopped = None
        for index, work in enumerate(w for w in works if w['platform']==platform):
            emit('metrics_progress',detail=f'已处理{len(handled)}/{total}个作品，正在读取'+('视频号' if platform=='wechat' else 'B站')+'数据。')
            try:
                if stopped: raise ValueError(stopped)
                if platform == 'wechat':
                    if not pw.is_wechat_share(work['link']): raise ValueError('此视频号记录缺少官方分享短链，请重新复制 weixin.qq.com/sph/ 分享链接后保存；原记录和统计保留。')
                    info = await pw.fetch_wechat_share_info(work['link'],sessions.get(platform),statistics_only=True)
                    if work.get('videoID') and info['id'] != work['videoID']:
                        raise ValueError('视频号响应作品ID与保存记录不一致，未更新数据。')
                    snapshot = platform_statistics(info,platform)
                else: snapshot = await fetch_bilibili_statistics(work,sessions.get(platform))
                relay('metrics_value',id=work['id'],statistics=snapshot)
            except pw.PlatformAccessError as exc:
                relay('metrics_failure',id=work['id'],message=str(exc)+' 上次数据保留；可手动重试。')
                if exc.reason in ('restricted','login_required'):
                    stopped = '因该平台登录或访问限制，尚未请求此作品；检查拾影内置网页登录后重试。'
            except httpx.HTTPError:
                relay('metrics_failure',id=work['id'],message='作品网络请求失败，请检查网络后重试；上次数据保留。')
            except ValueError as exc: relay('metrics_failure',id=work['id'],message=str(exc))
            if index + 1 < sum(w['platform']==platform for w in works): await asyncio.sleep(pause_seconds)
    failed = sum(x=='metrics_failure' for x in handled.values())
    emit('metrics_complete',total=total,succeeded=len(handled)-failed,failed=failed,seconds=round(time.monotonic()-started,2))
    return 0
