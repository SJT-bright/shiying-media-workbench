"""Temporary, original platform covers; never fetch or derive video frames."""
from __future__ import annotations

import json
import io
import hashlib
import os
import re
import stat
import tempfile
import time
import uuid
from pathlib import Path
from urllib.parse import urljoin, urlsplit, urlunsplit

import httpx

import photo_worker
import platform_worker
import worker

MAX_REQUEST_BYTES = 64 * 1024
MAX_METADATA_BYTES = 128 * 1024
MAX_IMAGE_BYTES = 64 * 1024 * 1024
MAX_REDIRECTS = 4
OWNER_MARKER = '.shiying-photo-owner'
# These are image networks, not a union of the platforms' video/page domains.
COVER_DOMAINS = {
    'douyin': ('douyinpic.com', 'byteimg.com', 'ibyteimg.com', 'pstatp.com',
               'douyinstatic.com', 'zjcdn.com', 'bytecdn.cn', 'amemv.com'),
    'bilibili': ('hdslb.com',),
    'xiaohongshu': ('xhscdn.com', 'xhsimg.com'),
    'wechat': ('qpic.cn', 'qlogo.cn'),
}
REFERERS = {'douyin': 'https://www.douyin.com/', **platform_worker.ORIGINS}


def owned_folder(folder):
    """Write only into the UUID job that PhotoDraftRepository has marked."""
    message = '封面临时目录无效或不属于本次任务，未写入未知目录。'
    try:
        candidate = Path(folder)
        if not candidate.is_absolute() or '..' in candidate.parts:
            raise ValueError()
        if str(uuid.UUID(candidate.name)) != candidate.name.lower():
            raise ValueError()
        if not stat.S_ISDIR(candidate.lstat().st_mode):
            raise ValueError()
        marker = candidate / OWNER_MARKER
        marked = marker.lstat()
        if not stat.S_ISREG(marked.st_mode) or marked.st_size > 64:
            raise ValueError()
        if marker.read_bytes() != candidate.name.encode('ascii'):
            raise ValueError()
        return candidate.resolve(strict=True)
    except (OSError, ValueError, TypeError):
        raise ValueError(message) from None


def cover_url(value, platform, *, allow_upgrade=False):
    """Check every CDN hop; credentials and non-HTTPS addresses are refused."""
    message = '平台封面地址无效或不在当前平台的公开图片地址范围内，未下载视频。'
    try:
        if not isinstance(value, str) or not value or len(value.encode('utf-8')) > 8192:
            raise ValueError()
        if any(ord(c) <= 32 or ord(c) == 127 for c in value):
            raise ValueError()
        parts = urlsplit(value)
        host = (parts.hostname or '').lower()
        domains = COVER_DOMAINS.get(platform, ())
        if (parts.username or parts.password or not parts.path
                or not any(host == d or host.endswith('.' + d) for d in domains)):
            raise ValueError()
        # Some official metadata (notably Bilibili) supplies legacy HTTP CDN
        # thumbnails. Upgrade that known image host in memory, before any I/O.
        # Redirects never enable this exception and are required to use HTTPS.
        if parts.scheme == 'http' and allow_upgrade and parts.port in (None, 80):
            return urlunsplit(('https', host, parts.path, parts.query, ''))
        if parts.scheme != 'https' or parts.port not in (None, 443): raise ValueError()
        return urlunsplit((parts.scheme, parts.netloc, parts.path, parts.query, ''))
    except (TypeError, ValueError, UnicodeError):
        raise ValueError(message) from None


def work_link(value, platform=None):
    """The direct handoff must identify one work, never a creator homepage."""
    if not isinstance(value, str) or len(value.encode('utf-8')) > 8192:
        raise ValueError('封面任务缺少有效的作品链接。')
    selected, checked = platform_worker.input_url(value, platform)
    parts = urlsplit(checked)
    if selected == 'douyin':
        valid = ((parts.hostname == 'v.douyin.com' and bool(parts.path.strip('/')))
                 or re.fullmatch(r'/(?:video|note)/\d{19}/?', parts.path))
    elif selected == 'bilibili':
        valid = ((parts.hostname == 'b23.tv' and bool(parts.path.strip('/')))
                 or re.fullmatch(r'/video/(?:BV[A-Za-z0-9]+|av\d+)/?', parts.path))
    elif selected == 'xiaohongshu':
        valid = ((parts.hostname in ('xhslink.com', 'www.xhslink.com') and bool(parts.path.strip('/')))
                 or re.fullmatch(r'/(?:explore|discovery/item)/[a-fA-F0-9]{24}/?', parts.path))
    else:
        # Besides sph shares, the app can hand off an actually captured official
        # Channels post. The page adapter retains its existing navigation rules.
        valid = platform_worker.is_wechat_share(checked) or (
            parts.hostname == 'channels.weixin.qq.com' and bool(parts.path.strip('/')))
    if not valid:
        raise ValueError('请提供单个作品的官方链接；博主主页需先采集作品再获取封面。')
    return selected, checked


def check_request_identity(identity, link, platform):
    path = urlsplit(link).path
    expected = None
    if platform == 'douyin':
        found = re.fullmatch(r'/(?:video|note)/(\d{19})/?', path)
        if found: expected = found.group(1)
    elif platform == 'bilibili':
        found = re.fullmatch(r'/video/(BV[A-Za-z0-9]+|av\d+)/?', path)
        if found:
            expected = found.group(1)
            # Bare aid and its literal av prefix express the same supplied ID;
            # do not guess a BV/av mapping that the request did not provide.
            if expected.startswith('av') and identity == expected[2:]: return
    elif platform == 'xiaohongshu':
        found = re.fullmatch(r'/(?:explore|discovery/item)/([a-fA-F0-9]{24})/?', path)
        if found:
            if identity.lower() == found.group(1).lower(): return
            expected = found.group(1)
    elif platform == 'wechat':
        fragment = urlsplit(link).fragment
        if fragment.startswith('shiying-capture-'):
            expected = fragment.removeprefix('shiying-capture-')
    if expected is not None and identity != expected:
        raise ValueError('封面任务的作品标识与作品链接不一致，未下载图片。')


def read_douyin_session(stream):
    """Match CreatorStore.acceptedSession's array/envelope, then reuse validation."""
    import creator_worker
    message = '登录状态无法读取，请重新打开登录窗口。'
    try:
        raw = stream.read(creator_worker.SESSION_MAX_BYTES + 1)
        if len(raw) > creator_worker.SESSION_MAX_BYTES: raise ValueError(message)
        payload = json.loads(raw)
        if isinstance(payload, dict):
            if (type(payload.get('version')) is not int or payload['version'] != 1
                    or payload.get('platform') != 'douyin' or not isinstance(payload.get('cookies'), list)):
                raise ValueError(message)
            payload = payload['cookies']
        if not isinstance(payload, list): raise ValueError(message)
        return creator_worker.read_session(io.BytesIO(json.dumps(payload, ensure_ascii=False).encode('utf-8')))
    except (ValueError, TypeError, UnicodeError, AttributeError):
        raise ValueError(message) from None


def parse_douyin_cover(payload, *, fetched_at):
    """Pinned real Content/Image models; relax only the playable-media requirement."""
    from dtk.core.errors import UpstreamChanged
    from dtk.platforms.douyin import parser as douyin
    try:
        return douyin.parse_content(payload, fetched_at=fetched_at)
    except UpstreamChanged as error:
        if error.path not in ('aweme_detail.video', 'aweme_detail.video.play_addr'):
            raise
    # Fixed upstream's public detail parser requires a play_addr. Cover-only
    # acquisition has no such requirement. Keep its original guard and required
    # work/status/author/statistics schema, and never mutate or falsify status.
    detail = douyin._guard(payload).child('aweme_detail')
    identity = detail.id('aweme_id')
    title, description = douyin.split_title(detail.text('desc'))
    status = detail.child('status')
    deleted = douyin.optional_bool(status.get('is_delete'))
    private = (douyin.optional_int(status.get('private_status')) or 0) != 0
    kind = douyin.ContentKind.IMAGE_ALBUM if detail.opt_children('images') else douyin.ContentKind.VIDEO
    video = detail.opt_child('video')
    duration = None
    if kind is douyin.ContentKind.VIDEO:
        duration = douyin.optional_positive_int(video.get('duration')) if video else None
        if duration is None: duration = douyin.optional_positive_int(detail.get('duration'))
    return douyin.Content(platform=douyin.Platform.DOUYIN, content_id=identity, kind=kind,
        web_url=douyin.content_web_url(identity, kind), title=title, description=description,
        created_at=douyin.epoch_to_datetime(detail.get('create_time')), duration_ms=duration,
        is_deleted=deleted, is_private=private, author=douyin.author_from_node(detail.child('author')),
        stats=douyin._stats(detail.child('statistics')),
        media=douyin._media(detail, kind, require_media=False), fetched_at=fetched_at,
        raw=detail.raw())


def _unique_fields(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError('封面任务包含重复字段。')
        result[key] = value
    return result


def _reject_number(value):
    raise ValueError('封面任务包含无效数字。')


def read_request(path, folder):
    """A bounded, plain JSON file directly inside this owned job; no sessions."""
    out = owned_folder(folder)
    message = '封面任务文件无法读取，请重新采集封面。'
    try:
        candidate = Path(path)
        meta = candidate.lstat()
        if (not candidate.is_absolute() or '..' in candidate.parts
                or candidate.parent.resolve(strict=True) != out
                or not stat.S_ISREG(meta.st_mode)):
            raise ValueError(message)
        if meta.st_size > MAX_REQUEST_BYTES:
            raise ValueError('封面任务超过 64 KiB 上限，未截断处理。')
        with candidate.open('rb') as source:
            raw = source.read(MAX_REQUEST_BYTES + 1)
        if len(raw) > MAX_REQUEST_BYTES:
            raise ValueError('封面任务超过 64 KiB 上限，未截断处理。')
        data = json.loads(raw, object_pairs_hook=_unique_fields, parse_constant=_reject_number)
    except (OSError, TypeError, UnicodeError, json.JSONDecodeError):
        raise ValueError(message) from None
    required = {'id', 'title', 'author', 'link', 'cover'}
    if not isinstance(data, dict) or not required <= data.keys() or data.keys() - (required | {'description'}):
        raise ValueError('封面任务字段无效，请重新采集封面。')
    if not isinstance(data['id'], str) or not re.fullmatch(r'[A-Za-z0-9_-]{1,180}', data['id']):
        raise ValueError('封面任务的作品标识无效。')
    for field, limit in (('title', 4000), ('author', 800), ('description', 32768)):
        value = data.get(field, '')
        if value is None and field == 'description': value = ''
        if not isinstance(value, str) or len(value.encode('utf-8')) > limit or '\x00' in value:
            raise ValueError('封面任务的作品文字无效或超过上限。')
        data[field] = value
    platform, link = work_link(data['link'])
    check_request_identity(data['id'], link, platform)
    data['link'] = link
    data['cover'] = cover_url(data['cover'], platform, allow_upgrade=True)
    return data, platform, out


def douyin_metadata(content):
    """Metadata remains about the original work; missing video streams are OK."""
    if photo_worker.is_album(content):
        return photo_worker.metadata(content)
    streams = [s for s in [getattr(content.media, 'video', None),
               *getattr(content.media, 'streams', [])] if s]
    best = max(streams, key=lambda s: (s.width or 0) * (s.height or 0), default=None)
    covers = getattr(content.media, 'covers', [])
    first = covers[0] if covers else None
    return {'id': content.content_id, 'title': content.title[:180],
            'description': content.description or content.title, 'author': content.author.nickname,
            'mediaKind': 'video', 'duration': (content.duration_ms or 0) / 1000,
            'width': (best.width or 0) if best else 0,
            'height': (best.height or 0) if best else 0,
            'size': (best.size_bytes or 0) if best else 0,
            'cover': first.url if first else None}


def _wechat_capture_cover(link, session):
    if not session or not session.get('capturedPosts'): return None
    source = session.get('captureSource')
    if not isinstance(source, str):
        raise ValueError('网页捕获缺少来源，请重新打开当前视频号页面。')
    platform_worker.input_url(source, 'wechat')
    matches = []
    for post in session['capturedPosts']:
        if not isinstance(post, dict) or not isinstance(post.get('link'), str): continue
        try: _, post_link = platform_worker.input_url(post['link'], 'wechat')
        except ValueError: continue
        if post_link == link: matches.append(post)
    if len(matches) != 1: return None
    post = matches[0]
    identity = post.get('id')
    if not isinstance(identity, str) or not re.fullmatch(r'[A-Za-z0-9_-]{1,180}', identity):
        raise ValueError('视频号捕获缺少有效作品标识，请重新读取目标页面。')
    return {'id': identity, 'title': str(post.get('title') or '')[:1000],
            'description': str(post.get('description') or post.get('title') or ''),
            'uploader': str(post.get('author') or ''), 'thumbnail': post.get('cover'),
            'duration': 0, 'formats': []}


async def fetch_platform_cover(text, platform, session=None):
    """Reuse official metadata/login adapters without their video availability gate."""
    _, link = work_link(text, platform)
    link = await platform_worker.resolve_url(link, platform, session)
    work_link(link, platform)
    if platform == 'wechat':
        info = _wechat_capture_cover(link, session)
        if info is None:
            if not platform_worker.is_wechat_share(link):
                raise ValueError('视频号需要先在内置窗口打开目标作品，再读取页面封面。')
            info = await platform_worker.fetch_wechat_share_info(link, session, statistics_only=True)
        return info, link
    if platform == 'xiaohongshu':
        parts = urlsplit(link)
        link = urlunsplit(('https', 'www.xiaohongshu.com', parts.path.rstrip('/'), parts.query, ''))
    try:
        # download=False and ignore_no_formats_error retain thumbnails even if
        # the extractor cannot select a playable video. No thumbnail cache/write.
        with platform_worker.ydl(session, ignore_no_formats_error=True, skip_download=True,
                                 writethumbnail=False) as downloader:
            info = downloader.extract_info(link, download=False)
        if not isinstance(info, dict) or info.get('_type') in ('playlist', 'multi_video'):
            raise ValueError('该链接不是单个作品，请复制具体作品链接。')
        return info, link
    except platform_worker.yt_dlp.utils.DownloadError:
        raise ValueError('平台未返回可读取的作品封面，请在内置窗口检查登录或验证后重试。') from None


def candidates_from_content(content, platform):
    if platform == 'douyin':
        covers = list(getattr(content.media, 'covers', []))
        if not covers and photo_worker.is_album(content):
            covers = content.media.images[:1]
        values = [url for image in covers for url in [image.url, *image.urls]]
    else:
        values = [content.get('thumbnail')]
        values += [item.get('url') for item in reversed(content.get('thumbnails') or [])
                   if isinstance(item, dict)]
    kept = []
    for value in values:
        if not value: continue
        try: checked = cover_url(value, platform, allow_upgrade=True)
        except ValueError: continue
        if checked not in kept: kept.append(checked)
    if not kept:
        raise ValueError('该作品未提供可读取的平台封面，未下载或转换视频。请重新采集作品信息。')
    # Metadata remains complete; the bounded fallback set avoids endless retries.
    return kept[:16]


def checked_metadata(info):
    # The native reader bounds each JSON line. Keep complete original metadata
    # inside that contract rather than silently cutting a large description.
    try:
        encoded = json.dumps(info, ensure_ascii=False, allow_nan=False).encode('utf-8')
    except (TypeError, ValueError, UnicodeError):
        raise ValueError('平台作品信息格式无效，未保存封面。') from None
    if len(encoded) > MAX_METADATA_BYTES:
        raise ValueError('平台作品信息超过封面预览上限，未截断处理或保存。')
    return info


async def _download_one(client, url, platform, raw):
    for redirect in range(MAX_REDIRECTS + 1):
        url = cover_url(url, platform)
        # Never propagate Set-Cookie or account credentials between CDN hops.
        client.cookies.clear()
        async with client.stream('GET', url) as response:
            if response.is_redirect:
                if redirect >= MAX_REDIRECTS:
                    raise ValueError('封面地址重定向过多，未保存图片。')
                location = response.headers.get('location')
                if not location: raise ValueError('封面重定向缺少图片地址。')
                url = cover_url(urljoin(url, location), platform)
                continue
            response.raise_for_status()
            kind = response.headers.get('content-type', '').split(';', 1)[0].lower().strip()
            if not (kind.startswith('image/') or kind == 'application/octet-stream'):
                raise ValueError('封面服务器返回的内容类型不是图片。')
            length = response.headers.get('content-length', '')
            if length and not re.fullmatch(r'\d{1,20}', length):
                raise ValueError('封面服务器返回的图片字节信息无效。')
            total = int(length or 0)
            if total > MAX_IMAGE_BYTES: raise ValueError('封面图片超过 64 MiB 上限，未截断保存。')
            got = 0; started = time.monotonic(); last = 0; digest = hashlib.sha256()
            with raw.open('xb') as target:
                async for chunk in response.aiter_bytes(256 * 1024):
                    got += len(chunk)
                    if got > MAX_IMAGE_BYTES:
                        raise ValueError('封面图片超过 64 MiB 上限，未截断保存。')
                    target.write(chunk)
                    digest.update(chunk)
                    if time.monotonic() - last > .15:
                        last = time.monotonic()
                        worker.emit('progress', stage='download', progress=got / total if total else 0,
                                    detail='正在临时下载平台封面', received=got, total=total,
                                    speed=got / max(time.monotonic() - started, .1))
            if not got or (total and got != total):
                raise ValueError('封面图片下载字节不完整，未保存。')
        with raw.open('rb') as image: extension = photo_worker.image_extension(image.read(16))
        worker.emit('progress', stage='verify', progress=0, detail='正在检查封面图片')
        width, height = photo_worker.verify_image(raw)
        image_sha = digest.hexdigest()
        if sha256_file(raw) != image_sha:
            raise ValueError('下载的封面原图在检查期间发生变化，未保存。')
        return extension, width, height, got, image_sha
    raise ValueError('封面地址无法读取。')


def sha256_file(path):
    with path.open('rb') as image:
        return hashlib.file_digest(image, 'sha256').hexdigest()


def _discard_publication(folder, name, signature):
    """Only undo our exact just-published file; an external change is preserved."""
    try:
        image = folder / name
        meta = image.lstat()
        if (stat.S_ISREG(meta.st_mode) and (meta.st_dev, meta.st_ino, meta.st_size) == signature[:3]
                and sorted(p.name for p in folder.iterdir()) == [name]
                and sha256_file(image) == signature[3]):
            image.unlink()
            folder.rmdir()
    except OSError: pass


async def download_cover(info, urls, platform, folder, *, emit_metadata=True):
    out = owned_folder(folder)
    checked_metadata(info)
    if emit_metadata: worker.emit('metadata', **info)
    checked_urls = list(dict.fromkeys(cover_url(url, platform) for url in urls))
    if not checked_urls:
        raise ValueError('该作品未提供可读取的平台封面，未下载视频。')
    title = worker.file_component(info.get('title') or '', 100) or worker.file_component(str(info['id']), 80)
    author = worker.file_component(info.get('author') or '', 48)
    identity = worker.file_component(str(info['id']), 80)
    base = f'{author}_{title}_封面_{identity}'
    published = None; signature = None; name = None
    try:
        with tempfile.TemporaryDirectory(prefix=worker.stage_prefix('cover'), dir=out) as temporary:
            staging = Path(temporary); album = staging / 'cover'; album.mkdir(mode=0o700)
            raw = album / 'image.download'
            failures = []
            async with httpx.AsyncClient(headers={'User-Agent': worker.UA, 'Referer': REFERERS[platform]},
                                         follow_redirects=False, timeout=40) as client:
                for url in checked_urls:
                    try:
                        extension, width, height, received, image_sha = await _download_one(client, url, platform, raw)
                        break
                    except (httpx.HTTPError, ValueError) as exc:
                        raw.unlink(missing_ok=True)
                        if isinstance(exc, httpx.HTTPStatusError):
                            status = exc.response.status_code
                            if status in (401, 403, 429):
                                raise ValueError(f'封面图片返回 HTTP {status}，请检查作品访问权限或稍后重试。') from None
                            failure = f'HTTP {status}'
                        elif isinstance(exc, httpx.HTTPError): failure = '网络连接或图片传输失败'
                        else: failure = str(exc)
                        failures.append(failure)
                else:
                    raise ValueError('封面下载失败：' + '；'.join(failures) + ' 未保存图片，未下载视频。')
            name = '001' + extension
            raw.rename(album / name)
            # Recheck ownership after asynchronous I/O before exclusive publish.
            if owned_folder(folder) != out: raise ValueError('封面临时目录在下载期间发生变化，未保存。')
            worker.emit('progress', stage='verify', progress=1, detail='封面已校验，等待确认保存')
            for suffix in range(10000):
                destination = out / (base + (f'_{suffix}' if suffix else ''))
                try: photo_worker.publish_directory(album, destination); break
                except FileExistsError: continue
            else: raise ValueError('同名封面目录过多，请重新开始封面采集。')
            published = destination
            meta = (destination / name).lstat()
            signature = (meta.st_dev, meta.st_ino, meta.st_size, image_sha)
            if sha256_file(destination / name) != image_sha:
                raise ValueError('封面临时原图在发布期间发生变化，未确认保存；修改后的文件保留。')
            worker.emit('complete', path=str(destination), imagePaths=[str(destination / name)],
                        mediaKind='video_cover', width=width, height=height, duration=0,
                        bytes=received, quality='cover', video=info, imageSHA256=image_sha)
    except BaseException:
        if published is not None and signature is not None:
            _discard_publication(published, name, signature)
        raise


async def preview_cover(text, folder, platform=None, session=None):
    out = owned_folder(folder)
    selected, _ = work_link(text, platform)
    worker.emit('progress', stage='parse', progress=0, detail='正在读取作品封面信息')
    if selected == 'douyin':
        content, _ = await worker.fetch(text, session=session, cover_only=True)
        info = douyin_metadata(content)
    else:
        content, _ = await fetch_platform_cover(text, selected, session)
        info = platform_worker.metadata(content)
        info['mediaKind'] = 'video'
    checked_metadata(info)
    worker.emit('metadata', **info)
    urls = candidates_from_content(content, selected)
    await download_cover(info, urls, selected, out, emit_metadata=False)


async def run_cover(path, folder):
    data, platform, out = read_request(path, folder)
    info = {'id': data['id'], 'title': data['title'][:180], 'author': data['author'],
            'description': data['description'] or data['title'], 'mediaKind': 'video',
            'duration': 0, 'width': 0, 'height': 0, 'size': 0, 'cover': data['cover']}
    await download_cover(info, [data['cover']], platform, out)
