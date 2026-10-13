"""Ordered Douyin image albums. Keep supplied image bytes; publish only a complete album."""
from __future__ import annotations
import ctypes, errno, json, os, re, subprocess, sys, tempfile, time
from pathlib import Path
import httpx
import worker

MAX_IMAGE_BYTES = 64 * 1024 * 1024
MAX_IMAGES = 500

def is_album(content):
    return bool(getattr(content.media, 'images', None))

def metadata(content):
    images = content.media.images
    if len(images) > MAX_IMAGES:
        raise ValueError(f'这条图文有 {len(images)} 张图片，超过单次 {MAX_IMAGES} 张上限，未截断下载。')
    return {'id': content.content_id, 'title': content.title[:180],
            'description': content.description or content.title, 'author': content.author.nickname,
            'mediaKind': 'image_album', 'duration': 0, 'width': images[0].width or 0,
            'height': images[0].height or 0, 'size': 0, 'cover': images[0].url,
            'images': [{'url': image.url, 'width': image.width, 'height': image.height} for image in images]}

def image_extension(header):
    if header.startswith(b'\xff\xd8\xff'): return '.jpg'
    if header.startswith(b'\x89PNG\r\n\x1a\n'): return '.png'
    if header.startswith(b'RIFF') and header[8:12] == b'WEBP': return '.webp'
    if header[:6] in (b'GIF87a', b'GIF89a'): return '.gif'
    raise ValueError('返回内容不是支持的图片文件（JPEG、PNG、WebP 或 GIF）。')

def run_media_check(arguments, timeout, message):
    with tempfile.TemporaryFile() as errors:
        process = subprocess.Popen(arguments, stdout=subprocess.PIPE, stderr=errors)
        worker.active_child = process
        try:
            output, _ = process.communicate(timeout=timeout)
            if process.returncode: raise ValueError(message)
            return output
        except subprocess.TimeoutExpired:
            raise ValueError(message + ' 图片检查超时。') from None
        finally:
            if process.poll() is None:
                process.terminate()
                try: process.wait(timeout=3)
                except subprocess.TimeoutExpired: process.kill(); process.wait()
            worker.active_child = None

def verify_image(path):
    output = run_media_check([worker.tool('ffprobe'), '-v', 'error', '-show_entries',
        'stream=codec_type,width,height', '-of', 'json', str(path)], 30, '图片尺寸检查失败，未保存不完整的图文。')
    streams = json.loads(output).get('streams', [])
    image = next((stream for stream in streams if stream.get('codec_type') == 'video'), {})
    width, height = int(image.get('width', 0)), int(image.get('height', 0))
    if width <= 0 or height <= 0 or width * height > 80_000_000:
        raise ValueError('图片尺寸无效或过大，未保存不完整的图文。')
    run_media_check([worker.tool('ffmpeg'), '-hide_banner', '-loglevel', 'error', '-nostdin',
        '-xerror', '-err_detect', 'explode', '-i', str(path), '-map', '0:v:0', '-f', 'null', '-'],
        60, '图片解码失败，未保存损坏的图片。')
    return width, height

def publish_directory(source, destination):
    """Atomically publish without replacing an existing folder on either OS."""
    if sys.platform == 'win32':
        # Windows rename refuses an existing destination, including empty folders.
        os.rename(source, destination)
        return
    library = ctypes.CDLL(None, use_errno=True)
    rename = library.renamex_np
    rename.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_uint]
    rename.restype = ctypes.c_int
    if rename(os.fsencode(source), os.fsencode(destination), 4) != 0:  # RENAME_EXCL
        code = ctypes.get_errno()
        if code == errno.EEXIST: raise FileExistsError(code, 'Destination exists')
        raise OSError(code, os.strerror(code))

async def download_image(client, image, path, index, count, received):
    failures = []
    for url in dict.fromkeys([image.url, *image.urls]):
        try:
            async with client.stream('GET', url) as response:
                response.raise_for_status()
                if not any(value in response.headers.get('content-type', '').lower() for value in ('image/', 'octet-stream')):
                    raise ValueError('服务器返回的内容类型不是图片。')
                total = int(response.headers.get('content-length') or 0)
                if total > MAX_IMAGE_BYTES: raise ValueError('单张图片超过 64 MiB 上限。')
                got = 0; started = time.monotonic(); last = 0
                with path.open('wb') as file:
                    async for chunk in response.aiter_bytes(256 * 1024):
                        got += len(chunk)
                        if got > MAX_IMAGE_BYTES: raise ValueError('单张图片超过 64 MiB 上限。')
                        file.write(chunk)
                        if time.monotonic() - last > .15:
                            last = time.monotonic()
                            worker.emit('progress', stage='download', progress=(index + (got / total if total else 0)) / count,
                                detail=f'正在下载图片 {index + 1}/{count}', received=received + got,
                                total=0, speed=got / max(time.monotonic() - started, .1))
            if not got or (total and total != got): raise ValueError('图片下载字节不完整。')
            with path.open('rb') as file: extension = image_extension(file.read(16))
            width, height = verify_image(path)
            return extension, width, height, got
        except (httpx.HTTPError, ValueError) as exc:
            path.unlink(missing_ok=True)
            if isinstance(exc, httpx.HTTPStatusError):
                status = exc.response.status_code
                if status in (401, 403, 429):
                    raise ValueError(f'第 {index + 1} 张图片返回 HTTP {status}，请检查作品访问权限或稍后重试。') from None
                failure = f'HTTP {status}'
            elif isinstance(exc, httpx.HTTPError): failure = '网络连接或传输失败'
            else: failure = str(exc)
            failures.append(failure)
    raise ValueError(f'第 {index + 1}/{count} 张图片下载失败：' + '；'.join(failures) + ' 整组未保存，请重试。')

async def download_album(content, folder):
    info = metadata(content)
    worker.emit('metadata', **info)
    out = Path(folder).expanduser()
    if not out.is_dir(): raise ValueError('保存文件夹不存在，请重新选择保存位置。')
    title = worker.file_component(content.title, 120) or content.content_id
    author = worker.file_component(content.author.nickname, 48)
    base = f'{author}_{title}_图文_{content.content_id}'
    with tempfile.TemporaryDirectory(prefix=worker.stage_prefix('photos'), dir=out) as temporary:
        staging = Path(temporary); album = staging / 'album'; album.mkdir()
        files = []; received = 0; dimensions = []
        async with httpx.AsyncClient(headers={'User-Agent': worker.UA, 'Referer': 'https://www.douyin.com/'},
                follow_redirects=True, timeout=40) as client:
            for index, image in enumerate(content.media.images):
                raw = album / 'image.download'
                extension, width, height, size = await download_image(client, image, raw, index, len(content.media.images), received)
                name = f'{index + 1:03d}' + extension; raw.rename(album / name)
                files.append(name); dimensions.append((width, height)); received += size
                worker.emit('progress', stage='download', progress=(index + 1) / len(content.media.images),
                    detail=f'图片 {index + 1}/{len(content.media.images)} 已校验')
        worker.emit('progress', stage='verify', progress=1, detail=f'{len(files)} 张图片检查通过，正在保存图文')
        for suffix in range(10000):
            destination = out / (base + (f'_{suffix}' if suffix else ''))
            try: publish_directory(album, destination); break
            except FileExistsError: continue
        else: raise ValueError('同名图文目录过多，请选择其他保存位置。')
        info.update(width=dimensions[0][0], height=dimensions[0][1], size=received)
        worker.emit('complete', path=str(destination), imagePaths=[str(destination / name) for name in files],
            mediaKind='image_album', width=dimensions[0][0], height=dimensions[0][1], duration=0,
            bytes=received, quality='images', video=info)
