"""博主主页扫描：访客签名、主页解析、按平台 cursor 分页，逐行 JSON 事件。

不读取其它浏览器 Cookie，不把 Cookie、签名 URL 或凭据写入日志。
可由 App 自己的临时登录窗口经 stdin 显式传入会话；只留在本次进程内存。
"""
from __future__ import annotations

import asyncio
import ipaddress
import json
import re
import tempfile
from datetime import datetime, timezone
from pathlib import Path
from urllib.parse import unquote, urljoin, urlsplit

import httpx

from dtk.core.errors import UpstreamChanged, UpstreamRiskControl
from dtk.core.types import ContentKind, Platform
from dtk.platforms.common import Node
from dtk.platforms.douyin.endpoints import DouyinAPIEndpoints
from dtk.platforms.douyin.params import (
    DEFAULT_PAGE_SIZE,
    DEFAULT_PROFILE,
    author_posts_params,
    author_profile_params,
)
from dtk.platforms.douyin.parser import content_from_node, detect_risk_control, parse_author
from dtk.signing.base import RequestSpec, SigningSession, StaticFingerprint
from dtk.signing.native.signer import NativeSigner

ALLOWED_HOSTS = frozenset({
    'douyin.com',
    'www.douyin.com',
    'v.douyin.com',
    'iesdouyin.com',
    'www.iesdouyin.com',
})
MAX_REDIRECTS = 5
MAX_PAGES = 500
PAGE_PAUSE_SECONDS = 0.45
REQUEST_TIMEOUT = httpx.Timeout(20.0, connect=10.0)
ORIGIN = 'https://www.douyin.com/'
SEC_RE = re.compile(r'^MS4wLjAB[A-Za-z0-9_-]{8,}={0,2}$')
USER_PATH_RE = re.compile(r'^/(?:share/)?user/([^/?#]+)$')
VIDEO_PATH_RE = re.compile(r'/(?:share/)?(?:video|note|slides)(?:/|$)')
LIVE_PATH_RE = re.compile(r'/(?:share/)?live(?:/|$)')
SEC_QUERY_RE = re.compile(r'(?:^|&)sec_(?:uid|user_id)=([^&#]+)')
MODAL_QUERY_RE = re.compile(r'(?:^|&)(?:modal_id|vid)=')
HTTP_URL_RE = re.compile(r'https?://[^\s<>"\u3000]+', re.IGNORECASE)
BARE_URL_RE = re.compile(
    r'(?<![\w@/.-])((?:v\.douyin\.com|www\.douyin\.com|douyin\.com|www\.iesdouyin\.com|iesdouyin\.com)/[^\s<>"\u3000]+)',
    re.IGNORECASE,
)
TRAILING_JUNK = '，。！!；;）)]}>\'".,'
# 图文 / 实况图 / 直播间。普通视频是 0（以及解析后确有播放地址的其它类型）。
NON_VIDEO_AWEME_TYPES = frozenset({2, 68, 150, 101})
REDIRECT_STATUSES = frozenset({301, 302, 303, 307, 308})

# 探测脚本读取。只有路径模板、状态码和字段有无，没有 Cookie 或签名 URL。
last_notes: list[dict] = []

SESSION_MAX_BYTES = 65536


def read_session(stream) -> httpx.Cookies:
    """只接收 App 显式提供的临时会话。凭据不出现在 argv、文件或异常文本。"""
    message = '登录状态无法读取，请重新打开登录窗口。'
    try:
        data = stream.read(SESSION_MAX_BYTES + 1)
        if len(data) > SESSION_MAX_BYTES:
            raise ValueError(message)
        rows = json.loads(data)
        if not isinstance(rows, list) or len(rows) > 256:
            raise ValueError(message)
        cookies = httpx.Cookies()
        for row in rows:
            if not isinstance(row, dict):
                raise ValueError(message)
            name, value = row.get('name'), row.get('value')
            domain, path = row.get('domain'), row.get('path')
            if not all(isinstance(x, str) for x in (name, value, domain, path)):
                raise ValueError(message)
            host = domain.lstrip('.').lower()
            if host != 'douyin.com' and not host.endswith('.douyin.com'):
                raise ValueError(message)
            if not re.fullmatch(r'[A-Za-z0-9_!#$%&*+.^`|~-]{1,128}', name):
                raise ValueError(message)
            if len(value) > 8192 or any(ord(c) < 32 or ord(c) == 127 for c in value):
                raise ValueError(message)
            if not path.startswith('/') or len(path) > 2048 or any(ord(c) < 32 for c in path):
                raise ValueError(message)
            # 永远不发送到 HTTP 或其它域名。会话只用于本进程的 Douyin HTTPS 请求。
            from http.cookiejar import Cookie
            cookies.jar.set_cookie(Cookie(0, name, value, None, False, domain.lower(),
                domain.startswith('.'), domain.startswith('.'), path, True, True,
                None, True, None, None, {}, False))
        return cookies
    except (ValueError, TypeError, UnicodeError, AttributeError):
        raise ValueError(message) from None


def requires_login(payload: dict) -> bool:
    module = payload.get('not_login_module')
    return isinstance(module, dict) and module.get('guide_login_tip_exist') is True


class ScanFailure(Exception):
    def __init__(self, reason: str, detail: str, *, code: str | None = None,
                 retryable: bool = False, **context):
        super().__init__(detail)
        self.reason = reason
        self.detail = detail
        self.diagnostic = {'code': code or reason, 'retryable': retryable, **context}


def emit_event(event: str, **data) -> None:
    from worker import emit
    emit(event, **data)


def _note(path: str, **data) -> None:
    item = {'path': path}
    item.update(data)
    last_notes.append(item)


def extract_homepage_url(text: str) -> str:
    raw = (text or '').strip()
    if not raw:
        raise ValueError('请粘贴博主主页链接。')
    if re.fullmatch(r'\d{15,}', raw):
        raise ValueError('这是作品编号，不是博主主页。')
    match = HTTP_URL_RE.search(raw)
    if match:
        return match.group(0).rstrip(TRAILING_JUNK)
    bare = BARE_URL_RE.search(raw)
    if bare:
        return 'https://' + bare.group(1).rstrip(TRAILING_JUNK)
    raise ValueError('请粘贴抖音博主主页或主页短链。')


def _reject_host(url: str) -> str:
    parts = urlsplit(url)
    if parts.scheme not in {'http', 'https'}:
        raise ValueError('只接受 http 或 https 的抖音主页链接。')
    if parts.username or parts.password or '@' in parts.netloc:
        raise ValueError('链接里不能带账号或口令。')
    host = (parts.hostname or '').lower().rstrip('.')
    if not host:
        raise ValueError('链接没有主机名。')
    if host in {'localhost', 'localhost.localdomain'} or host.endswith(('.localhost', '.local')):
        raise ValueError('不接受本机地址。')
    try:
        ipaddress.ip_address(host)
    except ValueError:
        pass
    else:
        raise ValueError('不接受 IP 地址。')
    if host not in ALLOWED_HOSTS:
        raise ValueError('只接受抖音主页或主页短链。')
    if parts.port not in (None, 80, 443):
        raise ValueError('不接受带非标准端口的链接。')
    return host


def _require_sec(value: str) -> str:
    sec = unquote(value).strip()
    if not SEC_RE.fullmatch(sec):
        raise ValueError('主页里没有可用的作者标识。')
    return sec


def sec_from_url(url: str) -> str | None:
    """主页 URL 里的 sec_uid。短链返回 None，表示还要跟一次重定向。"""
    parts = urlsplit(url)
    host = _reject_host(url)
    path = parts.path or '/'
    query = parts.query or ''
    if MODAL_QUERY_RE.search(query) or VIDEO_PATH_RE.search(path) or LIVE_PATH_RE.search(path):
        raise ValueError('这是视频、图文或直播链接，不是博主主页。')
    user = USER_PATH_RE.match(path)
    if user:
        return _require_sec(user.group(1))
    found = SEC_QUERY_RE.search(query)
    if found and path.rstrip('/') in {'/share/user', '/user'}:
        return _require_sec(found.group(1))
    if host == 'v.douyin.com' and path not in {'', '/'}:
        return None
    raise ValueError('请粘贴博主主页链接，而不是视频、搜索或话题链接。')


async def resolve_sec_uid(client: httpx.AsyncClient, text: str) -> str:
    current = extract_homepage_url(text)
    followed = 0
    while True:
        sec = sec_from_url(current)
        if sec:
            return sec
        if followed >= MAX_REDIRECTS:
            raise ValueError('主页短链重定向超过 5 次。')
        host = _reject_host(current)
        path = urlsplit(current).path or '/'
        try:
            async with client.stream('GET', current) as response:
                status = response.status_code
                location = response.headers.get('location')
        except httpx.TimeoutException as exc:
            _note(path, host=host, error='timeout', kind='redirect')
            raise ScanFailure('timeout', '主页短链请求超时。') from exc
        except httpx.HTTPError as exc:
            _note(path, host=host, error='http', kind='redirect')
            raise ScanFailure('http', '主页短链请求失败。') from exc
        _note(path, host=host, status=status, kind='redirect')
        followed += 1
        if status not in REDIRECT_STATUSES or not location:
            raise ValueError('主页短链没有跳转到博主主页。')
        current = urljoin(current, location)


def _business_blocked(payload: dict) -> str | None:
    signal = detect_risk_control(payload)
    if signal:
        return signal
    code = payload.get('status_code')
    if code is None or code in (0, '0'):
        return None
    return f'status_code:{code}'


def _json_payload(response: httpx.Response, path: str) -> dict:
    context = {'endpoint': path, 'httpStatus': response.status_code, 'responseBytes': len(response.content)}
    if response.status_code != 200:
        raise ScanFailure('http', f'接口返回 HTTP {response.status_code}。', code='http_status',
                          retryable=response.status_code == 429 or response.status_code >= 500, **context)
    if not response.content:
        raise ScanFailure('empty', '接口返回了空响应（0 字节）。', code='empty_response', retryable=True, **context)
    try:
        payload = response.json()
    except Exception as exc:
        kind = 'html' if response.content.lstrip()[:1] == b'<' else 'text'
        _note(path, status=response.status_code, bytes=len(response.content), body=kind)
        description = '网页 HTML，未返回作品 JSON' if kind == 'html' else '无法解析的 JSON 文本'
        raise ScanFailure('bad_json', f'接口返回{description}。', code='invalid_json', responseKind=kind, **context) from exc
    if not isinstance(payload, dict):
        raise ScanFailure('bad_json', '接口 JSON 顶层不是对象。', code='invalid_object', **context)
    return payload


async def signed_get(client: httpx.AsyncClient, url: str, params: dict[str, str], path: str) -> dict:
    from worker import UA
    spec = RequestSpec.get(url, params)
    cookies = {c.name: c.value for c in client.cookies.jar}
    from worker import Cancelled
    try:
        signed = await NativeSigner(Platform.DOUYIN).sign(
            spec,
            StaticFingerprint(UA, 'Win32', 1920, 1080),
            SigningSession(cookies),
        )
        response = await client.get(signed.signed_url(spec.url), headers=dict(signed.headers))
    except Cancelled:
        raise
    except httpx.TimeoutException as exc:
        _note(path, error='timeout', kind='api')
        raise ScanFailure('timeout', '连接或读取接口超时。', retryable=True, endpoint=path) from exc
    except httpx.HTTPError as exc:
        _note(path, error='http', kind='api')
        raise ScanFailure('http', '网络连接或传输中断。', code='network_error', retryable=True,
                          endpoint=path, errorType=type(exc).__name__) from exc
    except Exception as exc:
        _note(path, error=type(exc).__name__, kind='api')
        raise ScanFailure('http', '本地签名或请求准备失败。', code='request_preparation',
                          endpoint=path, errorType=type(exc).__name__) from exc
    _note(path, status=response.status_code, bytes=len(response.content), kind='api')
    payload = _json_payload(response, path)
    blocked = _business_blocked(payload)
    if blocked:
        reason = 'empty' if blocked == 'empty_body' else 'restricted'
        # Do not forward arbitrary server text, cookies or signed URLs.
        code = payload.get('status_code')
        safe_code = str(code) if isinstance(code, (int, str)) and re.fullmatch(r'-?\d{1,12}', str(code)) else None
        raise ScanFailure(reason, '抖音接口明确返回访问限制。', code='upstream_restricted',
                          endpoint=path, httpStatus=response.status_code, apiStatus=safe_code)
    return payload


def _missing_count(items: list, dotted: str) -> int:
    missing = 0
    for item in items:
        if not isinstance(item, dict):
            missing += 1
            continue
        node = item
        ok = True
        for key in dotted.split('.'):
            if not isinstance(node, dict) or key not in node or node[key] is None:
                ok = False
                break
            node = node[key]
        if not ok:
            missing += 1
    return missing


def _is_video(content, raw: dict) -> bool:
    if content.is_deleted or content.is_private:
        return False
    if content.kind is not ContentKind.VIDEO:
        return False
    if content.media.video is None:
        return False
    if raw.get('images'):
        return False
    aweme_type = raw.get('aweme_type')
    if isinstance(aweme_type, int) and aweme_type in NON_VIDEO_AWEME_TYPES:
        return False
    if raw.get('is_live') in (1, True, '1'):
        return False
    if isinstance(raw.get('cell_room'), dict) or isinstance(raw.get('live_info'), dict):
        return False
    return True


def _post_event(content, raw: dict) -> dict:
    from metrics_worker import statistics
    created = None
    if content.created_at is not None:
        created = int(content.created_at.timestamp())
    cover = None
    if content.media.covers and content.media.covers[0].urls:
        cover = content.media.covers[0].urls[0]
    return {
        'id': content.content_id,
        'link': f'https://www.douyin.com/video/{content.content_id}',
        'title': content.title or '',
        'author': content.author.nickname or '',
        'createdAt': created,
        'diggCount': content.stats.digg_count,
        'collectCount': content.stats.collect_count,
        'cover': cover,
        'isVideo': _is_video(content, raw),
        'statistics': statistics(raw) if isinstance(raw.get('statistics'), dict) else None,
    }


def _read_has_more(payload: dict) -> bool | None:
    if 'has_more' not in payload or payload['has_more'] is None:
        return None
    value = payload['has_more']
    if isinstance(value, bool):
        return value
    if isinstance(value, int) and not isinstance(value, bool) and value in (0, 1):
        return bool(value)
    if isinstance(value, str) and value in {'0', '1'}:
        return value == '1'
    return None


def _read_cursor(payload: dict) -> str | None:
    if 'max_cursor' not in payload or payload['max_cursor'] is None:
        return None
    value = payload['max_cursor']
    if isinstance(value, bool) or isinstance(value, float):
        return None
    if isinstance(value, int):
        text = str(value)
    elif isinstance(value, str):
        text = value.strip()
    else:
        return None
    if not text or text == '0':
        return None
    return text


def _item_sec_uid(raw: dict) -> str | None:
    author = raw.get('author')
    if not isinstance(author, dict):
        return None
    value = author.get('sec_uid')
    if not isinstance(value, str):
        return None
    value = value.strip()
    return value or None


def _accepted_coauthor(raw: dict, sec_uid: str) -> bool:
    """Only an explicit, accepted co-creator relationship establishes provenance."""
    info = raw.get('cooperation_info')
    rows = info.get('co_creators') if isinstance(info, dict) else None
    return isinstance(rows, list) and any(
        isinstance(row, dict) and row.get('sec_uid') == sec_uid
        and not isinstance(row.get('invite_status'), bool) and row.get('invite_status') in (1, '1')
        for row in rows)


_SEEN_ID_RE = re.compile(r'^[0-9]{1,24}$')
_COUNT_TEXT_RE = re.compile(r'[0-9]{1,18}')
_MAX_AWEME_COUNT = 2**63 - 1
_SEEN_FILE_PREFIX = 'shiying-seen-'


def reliable_aweme_count(value) -> int | None:
    """主页作品数。只接受非负整数；布尔、负数、小数和缺失都不可靠。"""
    if value is None or isinstance(value, bool):
        return None
    if isinstance(value, int):
        if 0 <= value <= _MAX_AWEME_COUNT:
            return value
        return None
    if isinstance(value, float):
        if not value.is_integer() or value < 0 or value > _MAX_AWEME_COUNT:
            return None
        return int(value)
    if isinstance(value, str):
        text = value.strip()
        if _COUNT_TEXT_RE.fullmatch(text) is None:
            return None
        if len(text) > 1 and text.startswith('0'):
            return None
        number = int(text)
        if number > _MAX_AWEME_COUNT:
            return None
        return number
    return None


def load_seen_ids_file(path: str) -> set[str]:
    return load_seen_state(path)[0]


def load_seen_state(path: str) -> tuple[set[str], set[str]]:
    """Read legacy ID arrays or v2 state retaining verified coauthor provenance."""
    try:
        raw = Path(path).read_bytes()
    except OSError as exc:
        raise ValueError('已见作品文件无法读取。') from exc
    if len(raw) > 32 * 1024 * 1024:
        raise ValueError('已见作品文件过大。')
    try:
        data = json.loads(raw.decode('utf-8'))
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise ValueError('已见作品文件不是 JSON 数组。') from exc
    coauthored = []
    if isinstance(data, dict) and type(data.get('version')) is int and data['version'] == 2:
        coauthored = data.get('coauthoredIDs')
        data = data.get('ids')
    if not isinstance(data, list) or not isinstance(coauthored, list):
        raise ValueError('已见作品文件必须是字符串编号数组。')
    found: list[str] = []
    for item in data:
        if isinstance(item, bool) or not isinstance(item, str) or _SEEN_ID_RE.fullmatch(item) is None:
            raise ValueError('已见作品文件里有非法编号。')
        found.append(item)
    unique = set(found)
    if len(unique) != len(found):
        raise ValueError('已见作品数量和去重后不一致。')
    if any(not isinstance(item, str) or item not in unique for item in coauthored) or len(set(coauthored)) != len(coauthored):
        raise ValueError('共创作品编号必须是已见作品的无重复子集。')
    return unique, set(coauthored)


def discard_seen_file(path: str | None) -> None:
    """只删除本任务在临时目录里的 shiying-seen- 文件，不碰其它路径。"""
    if not path:
        return
    try:
        folder = Path(tempfile.gettempdir()).resolve()
        target = Path(path).expanduser().resolve()
    except OSError:
        return
    if target.parent != folder or target.suffix != '.json':
        return
    if not target.name.startswith(_SEEN_FILE_PREFIX):
        return
    try:
        target.unlink(missing_ok=True)
    except OSError:
        pass


def _collect_aweme_rows(payload: dict) -> list:
    """同一页公开响应里，aweme_list 之外若还有整列作品，按 ID 并入。上游没有单独的置顶接口。"""
    primary = payload.get('aweme_list')
    rows = list(primary) if isinstance(primary, list) else []
    seen: set[str] = set()
    for item in rows:
        if isinstance(item, dict) and item.get('aweme_id') is not None:
            seen.add(str(item.get('aweme_id')))
    for key, value in payload.items():
        if key == 'aweme_list' or not isinstance(value, list) or not value:
            continue
        if not all(isinstance(item, dict) and item.get('aweme_id') is not None for item in value):
            continue
        for item in value:
            marker = str(item.get('aweme_id'))
            if marker in seen:
                continue
            seen.add(marker)
            rows.append(item)
    return rows


def interpret_posts(payload: dict, sec_uid: str) -> dict:
    """Require the requested author, or an explicit accepted co-creator relationship."""
    if not isinstance(payload, dict):
        raise ScanFailure('bad_json', '作品列表不是 JSON 对象')
    blocked = _business_blocked(payload)
    if blocked:
        reason = 'empty' if blocked == 'empty_body' else 'restricted'
        raise ScanFailure(reason, f'作品列表受限（{blocked}）')
    login_limited = requires_login(payload)
    if not isinstance(payload.get('aweme_list'), list) and not login_limited:
        status = payload.get('status_code')
        only_status = set(payload) == {'status_code'}
        detail = '接口只返回状态码 0，没有作品列表；抖音未说明原因。' if only_status and status in (0, '0') else '响应缺少作品列表 aweme_list，或该字段不是数组。'
        raise ScanFailure('bad_json', detail, code='missing_posts',
                          retryable=only_status and status in (0, '0'),
                          missingFields=['aweme_list'], apiStatus=0 if status in (0, '0') else None)
    items = _collect_aweme_rows(payload)
    has_more = False if login_limited else _read_has_more(payload)
    if has_more is None:
        raise ScanFailure('bad_json', '响应缺少有效的 has_more，无法判断是否还有下一页。',
                          code='missing_pagination', missingFields=['has_more'])
    cursor = _read_cursor(payload)
    if has_more and cursor is None:
        raise ScanFailure('bad_json', '接口表示还有下一页，却没有有效的 max_cursor，无法安全翻页。',
                          code='missing_cursor', missingFields=['max_cursor'])
    fetched_at = datetime.now(timezone.utc)
    posts = []
    unparsed = 0
    author_skipped = 0
    non_video = 0
    types: dict[str, int] = {}
    for index, raw in enumerate(items):
        if not isinstance(raw, dict):
            unparsed += 1
            continue
        kind = str(raw.get('aweme_type'))
        types[kind] = types.get(kind, 0) + 1
        coauthored = _item_sec_uid(raw) != sec_uid and _accepted_coauthor(raw, sec_uid)
        if _item_sec_uid(raw) != sec_uid and not coauthored:
            author_skipped += 1
            continue
        try:
            content = content_from_node(Node(raw, f'aweme_list[{index}]', 'douyin'), fetched_at=fetched_at)
        except Exception:
            unparsed += 1
            continue
        if content.author.sec_uid != sec_uid and not coauthored:
            author_skipped += 1
            continue
        post = _post_event(content, raw)
        if coauthored: post['isCoauthored'] = True
        if not post['isVideo']:
            non_video += 1
        posts.append(post)
    return {
        'posts': posts,
        'login_required': login_limited,
        'has_more': has_more,
        'cursor': cursor,
        'listed': len(items),
        'unparsed': unparsed,
        'author_skipped': author_skipped,
        'non_video': non_video,
        'types': types,
        'missing_create_time': _missing_count(items, 'create_time'),
        'missing_digg_count': _missing_count(items, 'statistics.digg_count'),
        'missing_collect_count': _missing_count(items, 'statistics.collect_count'),
        'missing_sec_uid': _missing_count(items, 'author.sec_uid'),
    }


def _complete(
    complete: bool,
    reason: str,
    cursor: str | None,
    received: int,
    pages: int,
    *,
    aweme_count: int | None = None,
    listed_count: int | None = None,
    tainted: bool = False,
    diagnostic: dict | None = None,
    message: str | None = None,
    coauthored_count: int = 0,
) -> None:
    extra: dict = {'tainted': bool(tainted)}
    if diagnostic is not None:
        extra['diagnostic'] = diagnostic
    if message:
        extra['message'] = message
    if aweme_count is not None:
        extra['awemeCount'] = aweme_count
    if listed_count is not None:
        extra['listedCount'] = listed_count
        extra['coauthoredCount'] = coauthored_count
        extra['primaryCount'] = listed_count - coauthored_count
    if aweme_count is not None and listed_count is not None:
        extra['gap'] = aweme_count - (listed_count - coauthored_count)
    emit_event(
        'scan_complete',
        complete=complete,
        cursor=cursor,
        reason=reason,
        received=received,
        pages=pages,
        **extra,
    )


def _check_limit(page_limit: int) -> None:
    if not isinstance(page_limit, int) or isinstance(page_limit, bool) or page_limit < 1 or page_limit > MAX_PAGES:
        raise ValueError('单批页数必须在 1 到 500 之间。')


async def _seed_visitor(client: httpx.AsyncClient) -> None:
    """HEAD 已知首页拿同域公开访客 Cookie。不读正文，不把响应写进日志。

    实测 GET 首页会拿到约 70KB 正文，随后作者接口变成 HTTP 200 且正文为空。
    与现有视频详情相同，只用 HEAD。
    """
    try:
        response = await client.head(ORIGIN)
        status = response.status_code
    except httpx.HTTPError:
        _note('/', error='seed', kind='seed')
        return
    _note('/', status=status, kind='seed')


async def run_scan(
    link: str,
    resume_cursor: str | None = None,
    page_limit: int = MAX_PAGES,
    *,
    client: httpx.AsyncClient | None = None,
    pause_seconds: float = PAGE_PAUSE_SECONDS,
    seen_ids: set[str] | None = None,
    seen_coauthored_ids: set[str] | None = None,
    prior_partial: bool = False,
    session_cookies: httpx.Cookies | None = None,
    retry_delays: tuple[float, ...] = (1.0, 2.0),
) -> int:
    """扫描一个博主主页。返回进程退出码：0 全部采完，1 不完整，取消则抛出 worker.Cancelled。"""
    global last_notes
    last_notes = []
    from worker import Cancelled, UA
    owned = client is None
    if owned:
        client = httpx.AsyncClient(
            headers={'User-Agent': UA, 'Referer': ORIGIN},
            follow_redirects=False,
            timeout=REQUEST_TIMEOUT,
        )
    assert client is not None
    if session_cookies is not None:
        for cookie in session_cookies.jar:
            client.cookies.jar.set_cookie(cookie)
    pages = 0
    received = 0
    listed_ids = {item for item in (seen_ids or set()) if isinstance(item, str) and item.isdigit() and not isinstance(item, bool)}
    seen_post_ids = set(listed_ids)
    coauthored_ids = set(seen_coauthored_ids or ()) & listed_ids
    seen_cursors: set[str] = set()
    cursor = (resume_cursor or '').strip() or None
    # 本进程或上次续扫里出现过无法解析、作者错配时，干净的后续页也不能标成全部。
    tainted = prior_partial is True
    unparsed_total = 0
    author_skip_total = 0
    aweme_count: int | None = None
    stage = 'resolve_homepage'
    failure: ScanFailure | None = None
    session_attached = bool(session_cookies and any(c.name in {'sessionid', 'sessionid_ss', 'sid_guard'} and c.value for c in session_cookies.jar))

    def _finish(ok: bool, reason: str, end_cursor: str | None) -> None:
        extra = {}
        if reason == 'partial':
            extra = {'message': f'已翻到末页，保留 {len(listed_ids)} 条作品；另有 {unparsed_total} 条无法解析、{author_skip_total} 条作者未匹配，已跳过。此前续采遗留异常：{"是" if prior_partial else "否"}。本次不标为全部采完。',
                     'diagnostic': {'code': 'partial_rows', 'stage': 'posts', 'unparsedCount': unparsed_total,
                                    'authorSkippedCount': author_skip_total, 'priorPartial': prior_partial}}
        if failure:
            diagnostic = dict(failure.diagnostic, stage=stage, page=pages + 1 if stage == 'posts' else None,
                              sessionAttached=session_attached)
            if stage == 'posts' and last_notes:
                note = last_notes[-1]
                for source, target in [('status', 'httpStatus'), ('bytes', 'responseBytes')]:
                    if source in note: diagnostic.setdefault(target, note[source])
            action = ('打开内置抖音网页，确认账号能正常浏览后重试。' if session_attached else
                      '打开「登录抖音」完成登录，采集时会自动同步；随后重试。')
            if diagnostic['code'] in {'timeout', 'network_error'}: action = '检查网络后继续采集。'
            elif diagnostic['code'] == 'http_status': action = '稍后重试；如官方网页要求验证，请在内置窗口手动完成。'
            elif diagnostic['code'] in {'missing_pagination', 'missing_cursor', 'invalid_json', 'invalid_object', 'request_preparation'}:
                action = '可复制问题详情用于排查；已采作品保留。'
            diagnostic['nextAction'] = action
            prefix = f'第 {pages + 1} 页采集失败：' if stage == 'posts' else ('读取博主资料失败：' if stage == 'profile' else '解析主页链接失败：')
            attempts = diagnostic.get('attempts', 1)
            retry_text = f'已尝试 {attempts} 次。' if attempts > 1 else ''
            login_text = '本次已携带登录。' if session_attached else '本次未取得采集登录。'
            extra = {'diagnostic': diagnostic, 'message': f'{prefix}{failure.detail}{retry_text}{login_text}已保留 {len(listed_ids)} 条作品。{action}'}
        # received 只计本批新发出的作品，不能换成主页总数。对账用累计去重的 listed_ids。
        if aweme_count is None:
            _complete(ok, reason, end_cursor, received, pages, tainted=tainted, **extra)
            return
        listed_count = len(listed_ids)
        _complete(
            ok,
            reason,
            end_cursor,
            received,
            pages,
            aweme_count=aweme_count,
            listed_count=listed_count,
            tainted=tainted,
            coauthored_count=len(coauthored_ids),
            **extra,
        )

    try:
        _check_limit(page_limit)
        sec_uid = await resolve_sec_uid(client, link)
        await _seed_visitor(client)
        stage = 'profile'
        profile = await signed_get(
            client,
            DouyinAPIEndpoints.USER_DETAIL,
            author_profile_params(sec_user_id=sec_uid, profile=DEFAULT_PROFILE),
            '/aweme/v1/web/user/profile/other/',
        )
        try:
            author = parse_author(profile)
        except UpstreamRiskControl as exc:
            raise ScanFailure('restricted', '作者主页受限。') from exc
        except UpstreamChanged as exc:
            raise ScanFailure('bad_json', '作者主页格式无法识别。') from exc
        if author.sec_uid != sec_uid:
            raise ScanFailure('bad_json', '作者标识与主页不一致。')
        avatar = author.avatar.url if author.avatar is not None else None
        user = profile.get('user') if isinstance(profile, dict) else None
        raw_count = user.get('aweme_count') if isinstance(user, dict) and 'aweme_count' in user else None
        aweme_count = reliable_aweme_count(raw_count)
        emit_event(
            'creator',
            id=sec_uid,
            nickname=author.nickname,
            homepage=f'https://www.douyin.com/user/{sec_uid}',
            avatar=avatar,
            awemeCount=aweme_count,
        )
        emit_event(
            'scan_progress',
            pages=0,
            received=0,
            cursor=cursor,
            detail='已解析博主主页，开始采集作品',
            tainted=tainted,
        )

        def _end_page(has_more: bool, listed_on_page: int) -> int | None:
            """平台还有下一页就继续。置顶或日期无序不能在这里停。返回 None 表示继续翻页。"""
            fresh_empty = received == 0 and not resume_cursor and not listed_ids
            if listed_on_page == 0 and (has_more or fresh_empty):
                _finish(False, 'empty', next_cursor if has_more else None)
                return 1
            if has_more:
                return None
            if tainted:
                _finish(False, 'partial', None)
                return 1
            # 缺失或不可靠的主页计数不能编成差额，也不能当成已经对齐。
            if aweme_count is None:
                _finish(False, 'unknown_count', None)
                return 1
            if len(listed_ids) - len(coauthored_ids) != aweme_count:
                _finish(False, 'count_mismatch', None)
                return 1
            _finish(True, 'complete', None)
            return 0

        while True:
            stage = 'posts'
            request_key = cursor or '0'
            if request_key in seen_cursors:
                _finish(False, 'duplicate_cursor', cursor)
                return 1
            if pages >= page_limit:
                _finish(False, 'limit', cursor)
                return 1
            seen_cursors.add(request_key)
            for attempt in range(len(retry_delays) + 1):
                try:
                    payload = await signed_get(
                        client,
                        DouyinAPIEndpoints.USER_POST,
                        author_posts_params(sec_user_id=sec_uid, cursor=cursor, count=DEFAULT_PAGE_SIZE, profile=DEFAULT_PROFILE),
                        '/aweme/v1/web/aweme/post/',
                    )
                    page = interpret_posts(payload, sec_uid)
                    break
                except ScanFailure as exc:
                    exc.diagnostic['attempts'] = attempt + 1
                    if not exc.diagnostic['retryable'] or attempt >= len(retry_delays): raise
                    emit_event('scan_progress', pages=pages, received=received, cursor=cursor,
                               detail=f'第 {pages + 1} 页：{exc.detail}准备重试（{attempt + 1}/{len(retry_delays)}），已采结果保留。', tainted=tainted)
                    await asyncio.sleep(retry_delays[attempt])
            pages += 1
            if page['unparsed'] or page['author_skipped']:
                tainted = True
            unparsed_total += page['unparsed']
            author_skip_total += page['author_skipped']
            fresh = 0
            for post in page['posts']:
                if post.get('isCoauthored'): coauthored_ids.add(post['id'])
                else: coauthored_ids.discard(post['id'])
                if post['id'] in seen_post_ids:
                    continue
                seen_post_ids.add(post['id'])
                listed_ids.add(post['id'])
                emit_event('post', post=post)
                received += 1
                fresh += 1
            next_cursor = page['cursor'] if page['has_more'] else None
            videos = sum(1 for post in page['posts'] if post['isVideo'])
            type_text = '、'.join(f'{key}×{value}' for key, value in sorted(page['types'].items())) or '无'
            detail = (
                f'第 {pages} 页 /aweme/v1/web/aweme/post/ ：'
                f'列出 {page["listed"]}，新增 {fresh}，本页可下载视频 {videos}，'
                f'图文/直播/不可下载 {page["non_video"]}，无法解析 {page["unparsed"]}，'
                f'作者跳过 {page["author_skipped"]}；'
                f'缺失 create_time {page["missing_create_time"]}、digg_count {page["missing_digg_count"]}、'
                f'collect_count {page["missing_collect_count"]}、sec_uid {page["missing_sec_uid"]}；'
                f'类型 {type_text}'
            )
            if page['non_video'] or page['unparsed']:
                detail += '（这些不是已下载视频）'
            if page['author_skipped']:
                detail += '（作者缺失或不一致的条目未发出）'
            if tainted:
                detail += f'（累计无法解析 {unparsed_total}，作者跳过 {author_skip_total}，本次不能视为全部采完）'
            if aweme_count is not None:
                listed_count = len(listed_ids)
                detail += f'（主页计数 {aweme_count}，本人发布 {listed_count - len(coauthored_ids)}，另有共创 {len(coauthored_ids)}，差额 {aweme_count - (listed_count - len(coauthored_ids))}）'
            emit_event(
                'scan_progress',
                pages=pages,
                received=received,
                cursor=next_cursor or cursor,
                detail=detail,
                tainted=tainted,
            )
            last_notes[-1].update({
                'listed': page['listed'],
                'has_more': page['has_more'],
                'cursor': next_cursor,
                'requested_cursor': request_key,
                'missing_create_time': page['missing_create_time'],
                'missing_digg_count': page['missing_digg_count'],
                'missing_collect_count': page['missing_collect_count'],
                'missing_sec_uid': page['missing_sec_uid'],
                'non_video': page['non_video'],
                'unparsed': page['unparsed'],
                'author_skipped': page['author_skipped'],
                'login_required': page['login_required'],
            })
            # 平台明确要求登录时停止访客翻页，保留这一页的作品。不靠猜游标绕过。
            if page['login_required']:
                _finish(False, 'login_required', None)
                return 1
            ended = _end_page(page['has_more'], page['listed'])
            if ended is not None:
                return ended
            if not next_cursor or next_cursor in seen_cursors or next_cursor == request_key:
                _finish(False, 'duplicate_cursor', next_cursor or cursor)
                return 1
            cursor = next_cursor
            if pause_seconds > 0:
                await asyncio.sleep(pause_seconds)
    except ScanFailure as exc:
        failure = exc
        _finish(False, exc.reason, cursor)
        return 1
    except Cancelled:
        _finish(False, 'cancelled', cursor)
        raise
    except ValueError as exc:
        emit_event('error', message=str(exc))
        return 1
    finally:
        if owned:
            await client.aclose()
