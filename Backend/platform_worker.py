"""Explicit platform adapters; only the app's own stdin session is accepted.

Bilibili uses the pinned yt-dlp WBI implementation. Xiaohongshu profiles expose
only their currently rendered notes. Channels supports official share previews
through the app's Yuanbao login and actual WKWebView captures; neither route
claims an account's complete archive or an empty successful scan.
"""
from __future__ import annotations

import asyncio
import hashlib
import json
import os
import re
import subprocess
import tempfile
import secrets
import time
from http.cookiejar import Cookie
from pathlib import Path
from urllib.parse import parse_qs, urlencode, urlsplit, urlunsplit

import httpx
import yt_dlp
from yt_dlp.utils import js_to_json

HOSTS = {
    'douyin': {'douyin.com', 'www.douyin.com', 'v.douyin.com', 'iesdouyin.com', 'www.iesdouyin.com'},
    'bilibili': {'bilibili.com', 'www.bilibili.com', 'space.bilibili.com', 'b23.tv'},
    'xiaohongshu': {'xiaohongshu.com', 'www.xiaohongshu.com', 'xhslink.com', 'www.xhslink.com'},
    'wechat': {'channels.weixin.qq.com', 'weixin.qq.com', 'www.weixin.qq.com'},
}
COOKIE_ROOTS = {'bilibili': ('bilibili.com', 'b23.tv'), 'xiaohongshu': ('xiaohongshu.com', 'xhslink.com'), 'wechat': ('weixin.qq.com', 'yuanbao.tencent.com')}
ORIGINS = {'bilibili': 'https://www.bilibili.com/', 'xiaohongshu': 'https://www.xiaohongshu.com/', 'wechat': 'https://channels.weixin.qq.com/'}
SESSION_MAX_BYTES = 1024 * 1024


class PlatformAccessError(ValueError):
    def __init__(self, reason, message, *, diagnostic=None):
        super().__init__(message)
        self.reason = reason
        self.diagnostic = diagnostic or {}


def input_url(text: str, platform: str | None = None) -> tuple[str, str]:
    """Exact host allowlist, standard ports and no URL credentials."""
    if platform and platform not in HOSTS:
        raise ValueError('未知平台，请重新选择平台。')
    raw_urls = re.findall(r'https?://[^\s<>"\u3000]+', text or '', re.I)
    if not raw_urls:
        bare = re.search(r'(?<![\w@/.-])((?:v\.douyin\.com|www\.douyin\.com|douyin\.com|www\.iesdouyin\.com|iesdouyin\.com)/[^\s<>"\u3000]+)', text or '', re.I)
        if bare: raw_urls = ['https://' + bare.group(1)]
    for raw in raw_urls:
        link = raw.rstrip('，。！!；;）)]}>\'".,')
        try:
            parts = urlsplit(link)
            host = (parts.hostname or '').lower()
            if parts.username or parts.password or parts.port not in (None, 80, 443):
                continue
        except ValueError:
            continue
        for candidate, allowed in HOSTS.items():
            if host in allowed and (not platform or platform == candidate):
                # Account cookies must never be sent over HTTP.
                fragment = parts.fragment if candidate == 'wechat' and re.fullmatch(r'shiying-capture-[A-Za-z0-9_-]+', parts.fragment) else ''
                return candidate, urlunsplit(('https', parts.netloc, parts.path, parts.query, fragment))
    if re.fullmatch(r'\d{19}', (text or '').strip()) and platform in (None, 'douyin'):
        return 'douyin', 'https://www.douyin.com/video/' + text.strip()
    raise ValueError('请粘贴当前平台的官方分享链接或博主主页。')


def read_session(stream, platform: str) -> dict:
    message = '登录状态无法读取，请重新打开当前平台的登录窗口。'
    try:
        raw = stream.read(SESSION_MAX_BYTES + 1)
        if len(raw) > SESSION_MAX_BYTES:
            raise ValueError(message)
        data = json.loads(raw)
        # Naked cookie arrays are accepted for backwards compatibility.
        if isinstance(data, list):
            data = {'version': 1, 'platform': platform, 'cookies': data}
        if not isinstance(data, dict) or data.get('version') != 1 or data.get('platform') != platform:
            raise ValueError(message)
        rows = data.get('cookies', [])
        if not isinstance(rows, list) or len(rows) > 256:
            raise ValueError(message)
        checked = []
        for row in rows:
            if not isinstance(row, dict):
                raise ValueError(message)
            name, value, domain, path = (row.get(k) for k in ('name', 'value', 'domain', 'path'))
            if not all(isinstance(v, str) for v in (name, value, domain, path)):
                raise ValueError(message)
            root = domain.lower().lstrip('.')
            if not any(root == d or root.endswith('.' + d) for d in COOKIE_ROOTS[platform]):
                raise ValueError(message)
            if not re.fullmatch(r'[A-Za-z0-9_!#$%&*+.^`|~-]{1,128}', name):
                raise ValueError(message)
            if len(value) > 8192 or any(ord(c) < 32 or ord(c) == 127 for c in value):
                raise ValueError(message)
            if not path.startswith('/') or len(path) > 2048 or any(ord(c) < 32 for c in path):
                raise ValueError(message)
            checked.append({'name': name, 'value': value, 'domain': domain.lower(), 'path': path})
        captures = data.get('capturedPosts', [])
        if not isinstance(captures, list) or len(captures) > 5000 or not all(isinstance(p, dict) for p in captures):
            raise ValueError(message)
        return {**data, 'cookies': checked, 'capturedPosts': captures}
    except (ValueError, TypeError, UnicodeError, AttributeError, KeyError):
        raise ValueError(message) from None


def cookie_jar(session: dict | None):
    cookies = httpx.Cookies()
    for row in (session or {}).get('cookies', []):
        domain = row['domain']
        cookies.jar.set_cookie(Cookie(0, row['name'], row['value'], None, False, domain,
            domain.startswith('.'), domain.startswith('.'), row['path'], True, True,
            None, True, None, None, {}, False))
    return cookies


class QuietLogger:
    """Extractor exceptions can contain signed URLs; never forward their text."""
    def debug(self, *args, **kwargs): pass
    def warning(self, *args, **kwargs): pass
    def error(self, *args, **kwargs): pass


def ydl(session=None, **extra):
    from worker import UA, tool
    options = {'quiet': True, 'no_warnings': True, 'logger': QuietLogger(),
               'noplaylist': True, 'socket_timeout': 25, 'retries': 2,
               'cachedir': False, 'fixup': 'never', 'ffmpeg_location': str(Path(tool('ffmpeg')).parent),
               'http_headers': {'User-Agent': UA}, **extra}
    instance = yt_dlp.YoutubeDL(options)
    for cookie in cookie_jar(session).jar:
        instance.cookiejar.set_cookie(cookie)
    return instance


async def resolve_url(link, platform, session=None):
    from worker import UA
    async with httpx.AsyncClient(headers={'User-Agent': UA, 'Referer': ORIGINS[platform]},
            cookies=cookie_jar(session), follow_redirects=False, timeout=25) as client:
        for _ in range(6):
            input_url(link, platform)
            if urlsplit(link).hostname not in {'b23.tv', 'xhslink.com', 'www.xhslink.com'}:
                return link
            response = await client.get(link)
            if response.status_code not in (301, 302, 303, 307, 308):
                raise ValueError('短链未返回官方作品地址，请复制完整的作品链接。')
            location = response.headers.get('location', '')
            from urllib.parse import urljoin
            _, link = input_url(urljoin(link, location), platform)
    raise ValueError('短链重定向次数过多。')


def numeric(value):
    if isinstance(value, bool): return None
    if isinstance(value, int) and value >= 0: return value
    if isinstance(value, str) and value.isdigit(): return int(value)
    return None


def load_seen_ids_file(path):
    """Same exclusive app-owned handoff checks, broader platform identities."""
    import stat
    try:
        candidate = Path(path)
        metadata = candidate.lstat()
        if not stat.S_ISREG(metadata.st_mode) or metadata.st_size > 2 * 1024 * 1024:
            raise ValueError()
        data = json.loads(candidate.read_bytes())
        if not isinstance(data, list) or len(data) > 100000:
            raise ValueError()
        if not all(isinstance(s, str) and re.fullmatch(r'[A-Za-z0-9_-]{1,180}', s) for s in data):
            raise ValueError()
        if len(set(data)) != len(data): raise ValueError()
        return set(data)
    except (ValueError, OSError, UnicodeError):
        raise ValueError('续采作品标识无法读取，请从主页重新采集。') from None


def post_from_info(info, platform, link=None):
    return {'id': str(info['id']), 'link': link or info.get('webpage_url') or info.get('url'),
            'title': info.get('title') or '', 'author': info.get('uploader') or info.get('creator') or '',
            'createdAt': numeric(info.get('timestamp')), 'diggCount': numeric(info.get('like_count')),
            'collectCount': numeric(info.get('favorite_count')), 'cover': info.get('thumbnail'),
            'isVideo': True, 'platform': platform}


def metadata(info):
    formats = [f for f in info.get('formats', []) if f.get('vcodec') != 'none']
    best = max(formats, key=lambda f: (f.get('width') or 0) * (f.get('height') or 0), default=info)
    return {'id': str(info['id']), 'title': (info.get('title') or '')[:180],
            'description': info.get('description') or info.get('title') or '',
            'author': info.get('uploader') or info.get('creator') or '',
            'duration': info.get('duration') or 0, 'width': best.get('width') or 0,
            'height': best.get('height') or 0, 'size': best.get('filesize') or 0,
            'cover': info.get('thumbnail')}


def wechat_media_url(url):
    try:
        parts = urlsplit(url)
        host = (parts.hostname or '').lower()
        allowed = any(host == root or host.endswith('.' + root)
                      for root in ('video.qq.com', 'wxapp.tc.qq.com', 'qpic.cn'))
        if parts.scheme != 'https' or not allowed or parts.username or parts.password or parts.port not in (None, 443):
            raise ValueError()
        return url
    except (TypeError, ValueError):
        raise ValueError('未捕获到可用的视频号媒体地址，请在内置窗口打开并播放视频。') from None


def captured_posts(link, platform, session):
    """Preserve unknown counters; captures represent only actual visible content."""
    if not session or not session.get('capturedPosts'): return []
    source = session.get('captureSource')
    if not isinstance(source, str): raise ValueError('网页捕获缺少来源，请重新采集当前页面。')
    _, checked_source = input_url(source, platform)
    a, b = urlsplit(link), urlsplit(checked_source)
    if (a.hostname, a.path.rstrip('/'), a.query) != (b.hostname, b.path.rstrip('/'), b.query):
        raise ValueError('捕获页面与本次主页不一致，请重新打开当前博主页面。')
    result, seen = [], set()
    for raw in session['capturedPosts']:
        if raw.get('encrypted') or raw.get('decodeKey'):
            # Channels encryption is not plaintext MP4. No proxy/certificate or
            # unsupported decoder is silently installed by this adapter.
            continue
        if not isinstance(raw.get('link'), str): continue
        try: _, post_link = input_url(raw['link'], platform)
        except ValueError: continue
        path = urlsplit(post_link).path
        if platform == 'bilibili' and not re.fullmatch(r'/video/(?:BV[A-Za-z0-9]+|av\d+)/?', path): continue
        if platform == 'xiaohongshu' and not re.fullmatch(r'/(?:explore|discovery/item)/[a-fA-F0-9]{24}/?', path): continue
        identity = str(raw.get('id') or '')
        if not identity or len(identity) > 180 or not re.fullmatch(r'[A-Za-z0-9_-]+', identity):
            identity = hashlib.sha256(post_link.encode()).hexdigest()[:32]
        if identity in seen: continue
        is_video = raw.get('isVideo') is True
        media = raw.get('mediaURL')
        if platform == 'wechat':
            if not isinstance(media, str): continue
            try: media = wechat_media_url(media)
            except ValueError: continue
            is_video = True
        else:
            media = None
        post = {'id': identity, 'link': post_link, 'title': str(raw.get('title') or '')[:1000],
                'author': str(raw.get('author') or '')[:200], 'isVideo': is_video,
                'createdAt': numeric(raw.get('createdAt')), 'diggCount': numeric(raw.get('diggCount')),
                'collectCount': numeric(raw.get('collectCount')), 'cover': raw.get('cover'), 'platform': platform}
        if media: post['mediaURL'] = media
        seen.add(identity)
        result.append(post)
    return result


async def fetch_info(text, platform, session=None):
    _, link = input_url(text, platform)
    link = await resolve_url(link, platform, session)
    if platform == 'wechat':
        captures = captured_posts(session.get('captureSource', link) if session else link, platform, session)
        matches = [p for p in captures if p['link'] == link]
        if len(matches) != 1:
            if is_wechat_share(link):
                return await fetch_wechat_share_info(link, session), link
            raise ValueError('视频号需要先在内置网页登录并播放目标视频，再采集网页中的视频。')
        p = matches[0]
        return {'id': p['id'], 'title': p['title'], 'uploader': p['author'],
                'thumbnail': p.get('cover'), 'url': p['mediaURL'], 'duration': 0,
                'formats': [{'url': p['mediaURL'], 'format_id': 'captured', 'ext': 'mp4',
                             'vcodec': None, 'acodec': None, 'http_headers': {'Referer': link}}]}, link
    if platform == 'bilibili' and not re.fullmatch(r'/video/(?:BV[A-Za-z0-9]+|av\d+)/?', urlsplit(link).path):
        raise ValueError('请粘贴B站单个视频的分享链接；博主主页请在博主采集里使用。')
    if platform == 'xiaohongshu':
        parts = urlsplit(link)
        if not re.fullmatch(r'/(?:explore|discovery/item)/[a-fA-F0-9]+/?', parts.path):
            raise ValueError('请粘贴小红书单条视频笔记链接，并保留原分享链接中的验证参数。')
        link = urlunsplit(('https', 'www.xiaohongshu.com', parts.path.rstrip('/'), parts.query, ''))
    try:
        with ydl(session) as downloader:
            info = downloader.extract_info(link, download=False)
        if not info or info.get('_type') in ('playlist', 'multi_video'):
            raise ValueError('该链接包含多个分P，请复制要下载的具体分P链接。')
        if not info.get('formats') and not info.get('url'):
            raise ValueError('该作品没有可访问的视频，图文笔记无法下载为视频。')
        return info, link
    except yt_dlp.utils.DownloadError:
        raise ValueError('平台未返回可访问的视频，请在内置窗口登录或验证后重试，并保留完整分享链接。') from None


def is_wechat_share(link):
    parts = urlsplit(link)
    return parts.hostname in ('weixin.qq.com', 'www.weixin.qq.com') and bool(re.fullmatch(r'/sph/[A-Za-z0-9_-]+/?', parts.path))


def _wechat_feed_info(payload, share_link, *, statistics_only=False):
    """Official preview reply, distinct from the encrypted desktop media path."""
    if not isinstance(payload, dict) or payload.get('errCode') not in (0, '0'):
        raise PlatformAccessError('restricted', '视频号官方预览暂时不可用，请重新打开分享链接或稍后重试。')
    data = payload.get('data')
    if isinstance(data, dict) and isinstance(data.get('data'), dict): data = data['data']
    if not isinstance(data, dict):
        raise PlatformAccessError('bad_json', '视频号官方预览未返回作品信息。')
    error = data.get('errMsg')
    if isinstance(error, dict) and (error.get('type') not in (None, 0, '0') or error.get('title') or error.get('content')):
        raise PlatformAccessError('restricted', '该视频号作品无法公开播放，可能已删除或限制访问。')
    feed, author = data.get('feedInfo'), data.get('authorInfo') or {}
    if not isinstance(feed, dict) or not isinstance(author, dict):
        raise PlatformAccessError('bad_json', '视频号作品信息格式无法识别。')
    if not statistics_only and (feed.get('decodeKey') or feed.get('decode_key') or feed.get('encrypted')):
        raise PlatformAccessError('encrypted', '这条视频号媒体需要解密，当前分享预览未提供可直接保存的视频。')
    formats = []
    for codec, key in (() if statistics_only else (('h264', 'h264VideoInfo'), ('hevc', 'h265VideoInfo'), (None, None))):
        row = feed.get(key) if key else feed
        if not isinstance(row, dict) or not isinstance(row.get('videoUrl'), str): continue
        if row.get('decodeKey') or row.get('encrypted'): continue
        try: media_url = wechat_media_url(row['videoUrl'])
        except ValueError: continue
        formats.append({'url': media_url, 'format_id': key or 'preview', 'ext': 'mp4',
                        'protocol': 'https', 'vcodec': codec, 'acodec': None,
                        'width': numeric(row.get('width') or feed.get('width')),
                        'height': numeric(row.get('height') or feed.get('height')),
                        'http_headers': {'Referer': 'https://channels.weixin.qq.com/'}})
    if not formats and not statistics_only:
        raise PlatformAccessError('non_video', '这条分享没有可直接播放的视频，图文或受限作品不能保存为视频。')
    identity = str(feed.get('id') or feed.get('objectId') or '')
    if not re.fullmatch(r'[A-Za-z0-9_-]{1,180}', identity): identity = hashlib.sha256(share_link.encode()).hexdigest()[:32]
    # Do not guess duration units or extract numbers from formatted 万 strings.
    return {'id': identity, 'title': str(feed.get('description') or '视频号视频')[:1000],
            'description': str(feed.get('description') or ''), 'uploader': str(author.get('nickname') or ''),
            'uploader_id': str(author.get('username') or author.get('userName') or ''),
            'thumbnail': feed.get('coverUrl'), 'timestamp': numeric(feed.get('createtime')),
            # Official preview: like = heart (喜欢), fav = thumb (推荐).
            # fav is not a public collection/favourite count.
            'like_count': numeric(feed.get('likeCount')) if numeric(feed.get('likeCount')) is not None else numeric(feed.get('likeCountFmt')),
            'recommend_count': numeric(feed.get('favCount')) if numeric(feed.get('favCount')) is not None else numeric(feed.get('favCountFmt')),
            'comment_count': numeric(feed.get('commentCount')) if numeric(feed.get('commentCount')) is not None else numeric(feed.get('commentCountFmt')),
            'share_count': numeric(feed.get('forwardCount')) if numeric(feed.get('forwardCount')) is not None else numeric(feed.get('forwardCountFmt')),
            'favorite_count': None,
            'statistics_display': {key: value for key, field in [('like','likeCountFmt'), ('recommend','favCountFmt'), ('comment','commentCountFmt'), ('share','forwardCountFmt')]
                if isinstance(value := feed.get(field), str) and re.fullmatch(r'[0-9]{1,19}(?:\.[0-9]{1,3})?[万亿wWkK]?\+?', value)},
            'duration': 0, 'formats': formats, 'webpage_url': share_link}


async def fetch_wechat_share_info(link, session=None, *, client=None, statistics_only=False):
    """Resolve a share through the app's independently logged-in Yuanbao session.

    Source protocol: ltaoo/wx_channels_download internal/workers/sph/worker.js.
    Never use its sample account/device headers or a third-party proxy service.
    Credentials remain domain-scoped cookies, preview tokens stay in memory.
    """
    from worker import UA
    _, link = input_url(link, 'wechat')
    if not is_wechat_share(link): raise ValueError('请提供 weixin.qq.com/sph/ 开头的视频号分享链接。')
    # Queue identity is carried in a local fragment. The official parser receives
    # the original share URL, and fallback IDs stay stable across scan/download.
    parts = urlsplit(link)
    link = urlunsplit((parts.scheme, parts.netloc, parts.path, parts.query, ''))
    owned = client is None
    if owned:
        client = httpx.AsyncClient(cookies=cookie_jar(session), timeout=30, follow_redirects=False)
    parse_headers = {'User-Agent': UA, 'Accept': 'application/json, text/plain, */*',
                     'Origin': 'https://yuanbao.tencent.com', 'Referer': 'https://yuanbao.tencent.com/',
                     'Content-Type': 'application/json'}
    async def checked_json(response, step):
        context = {'stage': step, 'httpStatus': response.status_code,
                   'responseBytes': len(response.content), 'endpoint': response.request.url.path}
        context['attempts'] = response.extensions.get('shiying_attempts', 1)
        if response.status_code == 401:
            raise PlatformAccessError('login_required', f'视频号{step}接口尚未通过登录验证（HTTP 401）。请检查内置元宝登录；现有网页登录保留。', diagnostic=context)
        if response.status_code == 403:
            raise PlatformAccessError('restricted', f'视频号{step}接口拒绝访问（HTTP 403），请在官方网页检查权限或验证；现有登录保留。', diagnostic=context)
        # The official preview currently returns HTTP 201 with errCode=0.
        # A valid success response must not be mistaken for an expired login.
        if not response.is_success:
            raise PlatformAccessError('restricted', f'视频号{step}暂时不可用（HTTP {response.status_code}），请稍后重试。', diagnostic=context)
        if len(response.content) > 8 * 1024 * 1024:
            raise PlatformAccessError('bad_json', '视频号响应过大，已停止解析。', diagnostic=context)
        try:
            payload = response.json()
        except ValueError:
            raise PlatformAccessError('bad_json', f'视频号{step}没有返回可读取的作品信息。', diagnostic=context) from None
        if not isinstance(payload, dict): raise PlatformAccessError('bad_json', '视频号响应格式无法识别。', diagnostic=context)
        return payload
    try:
        response = await _wechat_post(client, 'https://yuanbao.tencent.com/api/weixin/get_parse_result', '分享解析',
            headers=parse_headers, json={'type': 'video_channel_url', 'url': link, 'scene': 1})
        parsed = await checked_json(response, '分享解析')
        data = parsed.get('data')
        if not isinstance(data, dict) or not data.get('wx_export_id') or not isinstance(data.get('playable_url'), str):
            names = {r.get('name') for r in (session or {}).get('cookies', [])
                     if str(r.get('domain', '')).lstrip('.') == 'yuanbao.tencent.com'}
            reason = 'login_required' if not {'hy_user', 'hy_token'} <= names else 'restricted'
            context = {'stage': '分享解析', 'httpStatus': response.status_code,
                       'responseBytes': len(response.content), 'endpoint': response.request.url.path,
                       'missingFields': ['wx_export_id', 'playable_url']}
            code = parsed.get('code')
            if isinstance(code, int) and not isinstance(code, bool): context['apiStatus'] = code
            raise PlatformAccessError(reason, '元宝没有返回视频号可播放信息，请在内置窗口检查登录或验证后重试；现有登录保留。', diagnostic=context)
        playable = urlsplit(data['playable_url'])
        if playable.scheme != 'https' or playable.hostname != 'channels.weixin.qq.com' or playable.username or playable.password or playable.port not in (None, 443):
            raise PlatformAccessError('bad_json', '官方解析返回了非视频号播放地址，已停止请求。')
        params = parse_qs(playable.query)
        token, export = (params.get('token') or [''])[0], (params.get('eid') or [''])[0]
        if not token or not export or max(len(token), len(export)) > 8192 or any(ord(c) < 32 for c in token + export):
            raise PlatformAccessError('bad_json', '视频号播放信息缺少有效预览凭据，请重新解析分享。')
        origin = 'https://channels.weixin.qq.com'
        referer = origin + '/finder-preview/pages/feed?' + urlencode({'entry_card_type': 48, 'comment_scene': 39,
                    'appid': 0, 'token': token, 'entry_scene': 0, 'eid': export})
        headers = {'User-Agent': UA, 'Accept': 'application/json, text/plain, */*',
                   'Content-Type': 'application/json', 'Origin': origin, 'Referer': referer}
        response = await _wechat_post(client, origin + '/finder-preview/api/feed/get_feed_info', '官方预览', headers=headers,
            params={'_rid': f'{int(time.time()):x}-{secrets.token_hex(4)}', '_pageUrl': origin + '/finder-preview/pages/feed'},
            json={'baseReq': {'generalToken': token}, 'exportId': export})
        preview = await checked_json(response, '官方预览')
        try:
            return _wechat_feed_info(preview, link, statistics_only=statistics_only)
        except PlatformAccessError as exc:
            context = {'stage': '官方预览', 'httpStatus': response.status_code,
                       'responseBytes': len(response.content), 'endpoint': response.request.url.path}
            code = preview.get('errCode')
            if isinstance(code, int) and not isinstance(code, bool): context['apiStatus'] = code
            exc.diagnostic = context
            raise
    except httpx.HTTPError:
        raise PlatformAccessError('network', '视频号网络请求失败，请检查网络后重试。') from None
    finally:
        if owned: await client.aclose()


async def _wechat_post(client, url, step, **kwargs):
    """Retry only transient transport/server failures of read-only share requests.

    Login, verification, rate limits and invalid payloads are never retried.
    Response/error details may include credentials, so emit only a fixed message.
    """
    from worker import emit
    for attempt in range(3):
        try:
            response = await client.post(url, **kwargs)
        except httpx.TransportError:
            if attempt == 2:
                raise PlatformAccessError('network', f'视频号{step}网络连接失败，已重试2次；请检查网络后再试，现有登录保留。',
                    diagnostic={'stage': step, 'endpoint': urlsplit(url).path, 'attempts': 3}) from None
        else:
            response.extensions['shiying_attempts'] = attempt + 1
            if response.status_code not in (408, 500, 502, 503, 504) or attempt == 2:
                return response
        emit('progress', stage='parse', progress=0,
             detail=f'视频号{step}暂时中断，正在重试（{attempt + 1}/2）')
        await asyncio.sleep(.5 * (attempt + 1))


async def run_bilibili_scan(link, session, page_limit, resume_cursor, seen_ids, prior_partial):
    from worker import emit
    _, link = input_url(link, 'bilibili')
    parts = urlsplit(link)
    match = re.fullmatch(r'/(\d+)(?:/(?:upload/)?video)?/?', parts.path)
    if parts.hostname != 'space.bilibili.com' or not match:
        raise ValueError('B站博主采集请使用 space.bilibili.com/数字UID 的主页链接。')
    uid = match.group(1)
    page_number = int(resume_cursor or '1')
    if page_number < 1 or page_number > 100000: raise ValueError('无效的B站分页游标。')
    seen = set(seen_ids or ())
    received, pages, total = 0, 0, None
    tainted = bool(prior_partial)
    with ydl(session) as downloader:
        from yt_dlp.extractor.bilibili import BilibiliSpaceVideoIE
        adapter = BilibiliSpaceVideoIE(downloader)
        adapter.initialize()
        try:
            while pages < page_limit:
                query = {'mid': uid, 'pn': page_number, 'ps': 30, 'order': 'pubdate',
                         'order_avoided': 'true', 'platform': 'web', 'tid': 0,
                         'web_location': '333.1387', **adapter._dm_params}
                payload = adapter._download_json('https://api.bilibili.com/x/space/wbi/arc/search', uid,
                    query=adapter._sign_wbi(query, uid), headers={'Referer': link, 'Origin': 'https://space.bilibili.com'})
                if not isinstance(payload, dict) or payload.get('code') != 0:
                    reason = 'login_required' if isinstance(payload, dict) and payload.get('code') == -101 else 'restricted'
                    emit('scan_complete', complete=False, reason=reason, received=received, pages=pages,
                         cursor=str(page_number), tainted=tainted)
                    return 1
                data = payload.get('data') or {}
                rows = (data.get('list') or {}).get('vlist')
                count = numeric((data.get('page') or {}).get('count'))
                if not isinstance(rows, list): raise ValueError('B站作品列表格式无法识别。')
                if total is None:
                    total = count
                    name = next((str(r['author']) for r in rows if r.get('author')), f'B站 UP主 {uid}')
                    emit('creator', id=uid, nickname=name, homepage=f'https://space.bilibili.com/{uid}',
                         avatar=None, awemeCount=total, platform='bilibili')
                elif count != total:
                    tainted = True  # Content changed during pagination.
                pages += 1
                fresh = 0
                for row in rows:
                    identity = row.get('bvid')
                    if not isinstance(identity, str) or not re.fullmatch(r'BV[A-Za-z0-9]+', identity):
                        tainted = True
                        continue
                    # Hidden-mode collections are not a downloadable video row.
                    if (row.get('meta') or {}).get('attribute') == 156:
                        tainted = True
                        continue
                    mid = row.get('mid')
                    if mid is not None and str(mid) != uid:
                        tainted = True
                        continue
                    if identity in seen: continue
                    seen.add(identity)
                    emit('post', post={'id': identity, 'link': f'https://www.bilibili.com/video/{identity}',
                         'title': str(row.get('title') or ''), 'author': str(row.get('author') or ''),
                         'createdAt': numeric(row.get('created')), 'diggCount': numeric(row.get('like')),
                         'collectCount': numeric(row.get('favorites')), 'cover': row.get('pic'),
                         'isVideo': True, 'platform': 'bilibili'})
                    received += 1; fresh += 1
                ended = total is not None and page_number * 30 >= total
                page_number += 1
                emit('scan_progress', pages=pages, received=received, cursor=None if ended else str(page_number),
                     detail=f'已采集 {received} 条本批作品；B站主页计数 {total if total is not None else "未知"}', tainted=tainted)
                if ended or not rows:
                    complete = ended and not tainted and len(seen) == total
                    emit('scan_complete', complete=complete, reason='complete' if complete else 'count_mismatch',
                         cursor=None, received=received, pages=pages, awemeCount=total,
                         listedCount=len(seen), gap=total - len(seen) if total is not None else None, tainted=tainted)
                    return 0 if complete else 1
            emit('scan_complete', complete=False, reason='limit', cursor=str(page_number),
                 received=received, pages=pages, tainted=tainted)
            return 1
        except yt_dlp.utils.ExtractorError:
            emit('scan_complete', complete=False, reason='restricted', cursor=str(page_number),
                 received=received, pages=pages, tainted=tainted,
                 detail='B站接口暂时拒绝请求，请在内置窗口登录、完成验证或稍后重试。')
            return 1


def xhs_state_posts(state):
    """Parse known user notes scopes, without guessing unrelated recommendations."""
    user = state.get('user') or {}
    profile = user.get('userPageData') or user.get('userInfo') or {}
    basic = profile.get('basicInfo') or profile
    nickname = basic.get('nickname') or basic.get('nickName') or ''
    notes = user.get('notes') or user.get('noteList') or []
    flattened = []
    for row in notes:
        flattened.extend(row if isinstance(row, list) else [row])
    posts = []
    for raw in flattened:
        if not isinstance(raw, dict): continue
        card = raw.get('noteCard') or raw.get('note_card') or raw
        identity = raw.get('id') or raw.get('noteId') or card.get('noteId') or card.get('id')
        if not isinstance(identity, str) or not re.fullmatch(r'[a-fA-F0-9]{24}', identity): continue
        token = raw.get('xsecToken') or raw.get('xsec_token') or card.get('xsecToken')
        query = urlencode({'xsec_token': token, 'xsec_source': 'pc_user'}) if isinstance(token, str) and token else ''
        author = card.get('user') or {}
        interact = card.get('interactInfo') or {}
        cover = card.get('cover') or {}
        posts.append({'id': identity, 'link': 'https://www.xiaohongshu.com/explore/' + identity + ('?' + query if query else ''),
                      'title': card.get('displayTitle') or card.get('title') or '',
                      'author': author.get('nickname') or nickname, 'isVideo': card.get('type') == 'video',
                      'createdAt': None, 'diggCount': numeric(interact.get('likedCount')),
                      'collectCount': numeric(interact.get('collectedCount')), 'cover': cover.get('urlDefault'),
                      'platform': 'xiaohongshu'})
    return nickname, posts


async def run_visible_scan(link, platform, session, seen_ids):
    from worker import UA, emit
    _, link = input_url(link, platform)
    link = await resolve_url(link, platform, session)
    captures = captured_posts(link, platform, session)
    nickname, posts = '', list(captures)
    share_resolved = False
    parts = urlsplit(link)
    if platform == 'wechat' and not captures and is_wechat_share(link):
        try:
            info = await fetch_wechat_share_info(link, session)
            parts = urlsplit(link)
            canonical = urlunsplit((parts.scheme, parts.netloc, parts.path, parts.query, 'shiying-capture-' + str(info['id'])))
            posts = [post_from_info(info, platform, canonical)]
            nickname = info.get('uploader') or '视频号作者'
            share_resolved = True
        except PlatformAccessError as exc:
            emit('scan_complete', complete=False, reason=exc.reason, received=0, pages=0,
                 cursor=None, tainted=False, detail=str(exc), diagnostic=exc.diagnostic)
            return 1
    if platform == 'xiaohongshu':
        match = re.fullmatch(r'/user/profile/([a-fA-F0-9]{24})/?', parts.path)
        if not match and not captures: raise ValueError('小红书博主采集请使用 /user/profile/ 开头的官方主页链接。')
        identity = match.group(1) if match else hashlib.sha256(link.encode()).hexdigest()[:32]
        nickname = next((p['author'] for p in captures if p['author']), '')
        if not captures:
            async with httpx.AsyncClient(headers={'User-Agent': UA, 'Referer': ORIGINS[platform]},
                    cookies=cookie_jar(session), timeout=25, follow_redirects=False) as client:
                response = await client.get(link)
                if response.status_code != 200:
                    emit('scan_complete', complete=False, reason='login_required', pages=0, received=0, cursor=None)
                    return 1
                if len(response.content) > 8 * 1024 * 1024: raise ValueError('小红书主页响应过大，请重新打开内置窗口。')
                match_state = re.search(r'window\.__INITIAL_STATE__\s*=\s*', response.text)
                if match_state:
                    try:
                        state, _ = json.JSONDecoder().raw_decode(js_to_json(response.text[match_state.end():].split('</script>', 1)[0]).strip())
                        nickname, posts = xhs_state_posts(state)
                    except (ValueError, TypeError, AttributeError):
                        raise ValueError('小红书主页数据格式无法识别，请使用内置窗口采集当前网页。') from None
    else:
        identity = hashlib.sha256(link.encode()).hexdigest()[:32]
        nickname = next((p['author'] for p in posts if p['author']), 'B站当前网页' if platform == 'bilibili' else '视频号当前网页')
    emit('creator', id=identity, nickname=nickname or '当前博主', homepage=link,
         avatar=None, awemeCount=None, platform=platform)
    seen = set(seen_ids or ())
    received = 0
    for post in posts:
        if post['id'] in seen: continue
        emit('post', post=post); seen.add(post['id']); received += 1
    reason = 'share_resolved' if share_resolved else ('partial' if posts else 'login_required')
    detail = ('仅列出当前网页实际加载的作品；可在内置窗口继续浏览后再次采集。'
              if posts else '请在内置窗口登录并浏览博主作品；视频号需要实际播放视频后采集。')
    emit('scan_progress', pages=1 if posts else 0, received=received, cursor=None, tainted=True, detail=detail)
    emit('scan_complete', complete=False, reason=reason, received=received, pages=1 if posts else 0,
         cursor=None, tainted=True, detail=detail, listedCount=len(seen))
    return 0 if share_resolved else 1


async def run_scan(link, platform, *, session=None, page_limit=500, resume_cursor=None,
                   seen_ids=None, prior_partial=False):
    if not isinstance(page_limit, int) or isinstance(page_limit, bool) or not 1 <= page_limit <= 500:
        raise ValueError('单批页数必须在 1 到 500 之间。')
    if platform == 'bilibili':
        if session and session.get('capturedPosts'):
            return await run_visible_scan(link, platform, session, seen_ids)
        return await run_bilibili_scan(link, session, page_limit, resume_cursor, seen_ids, prior_partial)
    return await run_visible_scan(link, platform, session, seen_ids)


def select_formats(info, quality):
    def direct_stream(fmt):
        return fmt.get('protocol', 'https') in ('http', 'https', 'http_dash_segments') and not fmt.get('has_drm')
    formats = [f for f in info.get('formats', [info]) if f.get('url') and f.get('vcodec') != 'none' and direct_stream(f)]
    if not formats: raise ValueError('该作品没有可访问的视频源。')
    def rank(f): return ((f.get('width') or 0) * (f.get('height') or 0), f.get('tbr') or 0)
    if quality != 'highest':
        sized = [f for f in formats if f.get('width') and f.get('height') and min(f['width'], f['height']) >= int(quality)]
        if sized:
            short = min(min(f['width'], f['height']) for f in sized)
            formats = [f for f in sized if min(f['width'], f['height']) == short]
    video = max(formats, key=rank)
    audios = [f for f in info.get('formats', []) if f.get('vcodec') == 'none' and f.get('acodec') != 'none' and f.get('url') and direct_stream(f)]
    audio = max(audios, key=lambda f: f.get('abr') or f.get('tbr') or 0, default=None) if video.get('acodec') == 'none' else None
    if video.get('acodec') == 'none' and audio is None:
        raise ValueError('平台没有返回配套音频流，请登录或稍后重试。')
    return video, audio


def verify_complete_media(path, duration):
    """Decode the whole downloaded Channels file before atomic publication.

    ffprobe/remux alone can accept damaged media packets. FFmpeg errors must
    leave no successful file/record, and its child stays in the cancel path.
    """
    import worker
    worker.emit('progress', stage='verify', progress=0, detail='正在逐帧检查视频与音频')
    args = [worker.tool('ffmpeg'), '-hide_banner', '-loglevel', 'error', '-nostdin',
            '-xerror', '-err_detect', 'explode', '-i', str(path), '-map', '0:v:0',
            '-map', '0:a:0?', '-f', 'null', '-progress', 'pipe:1', '-nostats', '-']
    with tempfile.TemporaryFile() as errors:
        child = subprocess.Popen(args, stdout=subprocess.PIPE, stderr=errors, text=True)
        worker.active_child = child
        try:
            for line in child.stdout:
                if line.startswith('out_time_us='):
                    try:
                        fraction = min(.99, max(0, int(line.partition('=')[2]) / 1e6 / max(duration, .001)))
                    except ValueError:
                        continue
                    worker.emit('progress', stage='verify', progress=fraction, detail='正在逐帧检查视频与音频')
            code = child.wait()
        finally:
            child.stdout.close()
            if child.poll() is None:
                child.terminate()
                child.wait()
            if worker.active_child is child:
                worker.active_child = None
    if code:
        raise ValueError('视频或音频完整解码检查未通过，文件未保存；请重新解析后下载。')
    worker.emit('progress', stage='verify', progress=1, detail='视频与音频检查通过，正在保存')


async def download(text, platform, quality, folder, session=None):
    from worker import emit, probe, tool, transcode, utf8_limit
    import worker
    emit('progress', stage='parse', progress=0, detail='正在获取视频信息')
    info, link = await fetch_info(text, platform, session)
    video_info = metadata(info)
    emit('metadata', **video_info)
    out = Path(folder).expanduser()
    if not out.is_dir(): raise ValueError('保存文件夹不存在，请重新选择保存位置。')
    selected, audio = select_formats(info, quality)
    def progress(data):
        if data.get('status') == 'downloading':
            total = data.get('total_bytes') or data.get('total_bytes_estimate') or 0
            got = data.get('downloaded_bytes') or 0
            emit('progress', stage='download', progress=min(.99, got / total) if total else 0,
                 received=got, total=total, speed=data.get('speed') or 0, detail='正在下载视频')
    with tempfile.TemporaryDirectory(prefix=worker.stage_prefix('download'), dir=out) as stage:
        stage = Path(stage)
        source, final = stage / 'source.mp4', stage / 'output.mp4'
        try:
            with ydl(session, progress_hooks=[progress], outtmpl=str(stage / 'stream.%(ext)s')) as downloader:
                # Download streams independently so all FFmpeg children are owned
                # by worker.active_child and terminated by the existing cancel path.
                paths = []
                for index, fmt in enumerate([selected] + ([audio] if audio else [])):
                    target = stage / ('video.mp4' if index == 0 else 'audio.m4a')
                    item = {k: v for k, v in info.items() if k not in ('formats', 'requested_downloads', 'requested_formats')}
                    item.update(fmt)
                    downloader.params['outtmpl'] = {'default': str(target)}
                    downloader.process_info(item)
                    if not target.is_file(): raise ValueError('视频媒体流下载未完成。')
                    paths.append(target)
            # Remux even a single stream: B站旧FLV/DASH must have an actual MP4 container.
            args = [tool('ffmpeg'), '-hide_banner', '-loglevel', 'error', '-nostdin', '-i', str(paths[0])]
            if len(paths) > 1: args += ['-i', str(paths[1]), '-map', '0:v:0', '-map', '1:a:0']
            else: args += ['-map', '0:v:0', '-map', '0:a:0?']
            args += ['-c', 'copy', '-movflags', '+faststart', str(source)]
            with tempfile.TemporaryFile() as errors:
                worker.active_child = subprocess.Popen(args, stdout=subprocess.DEVNULL, stderr=errors)
                code = worker.active_child.wait(); worker.active_child = None
            if code:
                raise ValueError('媒体无法解码，可能是加密视频或地址已过期，请重新播放后采集。')
            probe(source)
            emit('progress', stage='export', progress=0, detail='正在整理视频' if quality == 'highest' else f'正在导出 {quality}P')
            if quality == 'highest': source.rename(final)
            else: transcode(source, final, int(quality))
            w, h, duration = probe(final)
            expected = info.get('duration') or 0
            if expected and abs(duration - expected) > max(2, expected * .01):
                raise ValueError('视频时长不完整，请重新下载。')
            if platform == 'wechat':
                verify_complete_media(final, duration)
            title = worker.file_component(video_info['title'], 100) or '视频'
            author = worker.file_component(video_info['author'], 40) or '博主'
            identity = utf8_limit(re.sub(r'[^A-Za-z0-9_-]', '_', str(info['id'])), 48)
            label = '最高画质' if quality == 'highest' else quality + 'P'
            base = f'{author}_{title}_{label}_{identity}'
            for number in range(10000):
                dest = out / (base + (f'_{number}' if number else '') + '.mp4')
                try: os.link(final, dest); break
                except FileExistsError: continue
            else: raise ValueError('同名文件过多，请选择其他保存位置。')
            emit('complete', path=str(dest), width=w, height=h, duration=duration,
                 bytes=dest.stat().st_size, quality=quality, video=video_info)
        except yt_dlp.utils.DownloadError:
            raise ValueError('视频下载失败，请在内置窗口重新登录或播放后重试。') from None
