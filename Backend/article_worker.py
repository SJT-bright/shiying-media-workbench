"""Local public-account articles, isolated from video history and login sessions."""
from __future__ import annotations
import asyncio, hashlib, html, json, os, re, shutil, signal, tempfile, time
from pathlib import Path
from urllib.parse import parse_qs, urlencode, urljoin, urlsplit, urlunsplit
import httpx
from bs4 import BeautifulSoup
from markdownify import markdownify

MAX_LINKS = 200
MAX_HTML = 2 * 1024 * 1024
MAX_PAGE = 8 * 1024 * 1024
MAX_INPUT = 3 * 1024 * 1024
MAX_IMAGE = 32 * 1024 * 1024
MAX_TOTAL = 256 * 1024 * 1024
MAX_IMAGES = 500
PUBLIC_PARAMS = ('__biz', 'mid', 'idx', 'sn')
HTML_TAGS = {'p','div','section','span','br','h1','h2','h3','h4','h5','h6','strong','b','em','i','u','s','del','blockquote','pre','code','ul','ol','li','hr','img','a','table','thead','tbody','tr','th','td','figure','figcaption','sub','sup'}
UA = 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15'

class ArticleError(ValueError):
    def __init__(self, reason, message): super().__init__(message); self.reason = reason

def article_url(value):
    try:
        p = urlsplit(value.strip().rstrip('，。！!；;）)]}>\'".,'))
        if p.scheme not in ('https','http') or p.hostname != 'mp.weixin.qq.com' or p.username or p.password or p.port not in (None,80,443): raise ValueError()
        if re.fullmatch(r'/s/[A-Za-z0-9_-]{1,180}/?',p.path): return urlunsplit(('https','mp.weixin.qq.com',p.path.rstrip('/'),'',''))
        q = parse_qs(p.query)
        if p.path not in ('/s','/s/') or not all(q.get(k) for k in PUBLIC_PARAMS): raise ValueError()
        values = {k:q[k][0] for k in PUBLIC_PARAMS}
        if any(len(x)>256 or any(ord(c)<32 for c in x) for x in values.values()): raise ValueError()
        if not values['mid'].isdigit() or not values['idx'].isdigit() or not re.fullmatch(r'[a-fA-F0-9]{32}',values['sn']): raise ValueError()
        return 'https://mp.weixin.qq.com/s?' + urlencode(values)
    except (ValueError,AttributeError,TypeError):
        raise ArticleError('invalid_input','请粘贴 mp.weixin.qq.com/s/ 开头的公众号文章链接；不接受公众号主页或其它平台链接。') from None

def image_url(value):
    try:
        p=urlsplit(urljoin('https://mp.weixin.qq.com/',value))
        host=(p.hostname or '').lower()
        if p.scheme not in ('http','https') or p.username or p.password or p.port not in (None,80,443): raise ValueError()
        if not any(host==root or host.endswith('.'+root) for root in ('qpic.cn','qlogo.cn')): raise ValueError()
        return urlunsplit(('https',host,p.path,p.query,''))
    except (ValueError,TypeError): raise ArticleError('image_source','文章包含非微信图片地址，未保存不完整文章。请在原文检查图片来源。') from None

def plain_excerpt(node):
    # UI shows 50 characters; keep the first 2000 of the cleaned body for that snippet.
    return ' '.join(node.get_text(' ', strip=True).split())[:2000]

def official_cover(provided, meta):
    """Formal cover is the supplied coverURL, otherwise og:image. Never the first body image."""
    raw=provided.get('coverURL') if isinstance(provided, dict) else None
    source='provided'
    if isinstance(raw, str): raw=raw.strip()
    elif raw is not None: raise ArticleError('image_source','封面不是微信图片地址，未保存不完整文章。请在原文检查封面来源。')
    if not raw:
        raw=meta('og:image'); source='og:image'
    if not raw: return None, None
    return image_url(raw), source

def read_request(stream):
    raw=stream.read(MAX_INPUT+1)
    if len(raw)>MAX_INPUT: raise ArticleError('input_limit','公众号请求超过3 MiB，未开始采集。')
    try: data=json.loads(raw)
    except (ValueError,UnicodeError): raise ArticleError('invalid_input','公众号采集请求不是有效JSON。') from None
    links=data.get('links') if isinstance(data,dict) else None
    if not isinstance(links,list) or not 1<=len(links)<=MAX_LINKS or not all(isinstance(x,str) for x in links):
        raise ArticleError('input_limit','一次支持1至200篇文章，请分批保存；不会截断链接。')
    checked=list(dict.fromkeys(article_url(x) for x in links))
    snapshots=data.get('snapshots',{})
    if not isinstance(snapshots,dict) or any(k not in checked or not isinstance(v,dict) or not isinstance(v.get('html'),str)
        or len(v['html'].encode())>MAX_HTML for k,v in snapshots.items()):
        raise ArticleError('snapshot','内置网页正文与本次文章链接不一致或过大，未开始保存。')
    return checked,snapshots

def parse_article(raw,link,metadata=None):
    if len(raw.encode())>MAX_PAGE: raise ArticleError('html_limit','文章网页超过8 MiB，请单独打开原文检查。')
    soup=BeautifulSoup(raw,'html.parser');content=soup.select_one('#js_content')
    if content is None:
        raise ArticleError('verification','网页没有返回文章正文，可能需要微信验证、文章已删除或链接失效。请在内置网页打开后读取正文。')
    def text(selector):
        el=soup.select_one(selector);return el.get_text(' ',strip=True) if el else ''
    def meta(name):
        el=soup.find('meta',attrs={'property':name}) or soup.find('meta',attrs={'name':name})
        return str(el.get('content','')).strip() if el else ''
    provided=metadata or {}
    title=str(provided.get('title') or text('#activity-name') or meta('og:title') or '').strip()[:1000]
    account=str(provided.get('account') or text('#js_name') or '').strip()[:200]
    author=str(provided.get('author') or text('#js_author_name') or meta('author') or account).strip()[:200]
    published=str(provided.get('published') or text('#publish_time') or '').strip()[:100]
    if not title: raise ArticleError('missing_title','网页缺少文章标题，未把页面当作有效文章保存。')
    for el in content.select('.video_iframe,.wx_video_iframe,mp-common-videos,mp-video,mpvoice,qqmusic,video'):
        if el.parent is not None:
            note=soup.new_tag('p');note.string='【原文含音视频，本次保存正文和图片。】';el.replace_with(note)
    for el in content.select('script,style,noscript,iframe,object,embed,form,input,button,template,svg'):
        if el.parent is not None: el.decompose()
    images=[]
    for img in list(content.find_all('img')):
        if re.search(r'(?:display\s*:\s*none|visibility\s*:\s*hidden)',str(img.get('style','')),re.I) or img.get('width')=='0' or img.get('height')=='0':
            img.decompose();continue
        src=img.get('data-src') or img.get('src')
        if not src or str(src).startswith('data:'): img.decompose();continue
        url=image_url(str(src));img.attrs={'src':url,'alt':str(img.get('alt') or '')[:300]}
        if url not in images: images.append(url)
    if len(images)>MAX_IMAGES: raise ArticleError('image_limit','正文图片超过500张，未保存不完整文章。')
    for el in list(content.find_all(True)):
        if el.parent is None: continue
        if el.name not in HTML_TAGS: el.unwrap();continue
        if el.name=='img':continue
        attrs={}
        if el.name=='a':
            href=str(el.get('href') or '')
            try:
                p=urlsplit(href)
                if p.scheme in ('https','http') and p.hostname and not p.username and not p.password:
                    # Authenticated URLs are never included in saved article metadata/links.
                    if not any(k in parse_qs(p.query) for k in ('key','pass_ticket','uin','wxtoken','token')):attrs['href']=href
            except ValueError:pass
        for k in ('colspan','rowspan'):
            if el.name in ('td','th') and str(el.get(k,'')).isdigit():attrs[k]=str(el[k])
        el.attrs=attrs
    content.attrs={}
    body=str(content);characters=len(content.get_text('',strip=True))
    if len(body.encode())>MAX_HTML:raise ArticleError('html_limit','文章正文超过2 MiB，未保存不完整文章。')
    if characters==0 and not images: raise ArticleError('empty_content','文章正文和图片均为空，未保存。')
    cover,cover_source=official_cover(provided, meta)
    excerpt=plain_excerpt(content)
    return dict(id=hashlib.sha256(link.encode()).hexdigest()[:32],title=title,account=account or '未知公众号',
        author=author,published=published,link=link,content=body,images=images,imageCount=len(images),characters=characters,
        coverURL=cover,coverSource=cover_source,excerpt=excerpt)

async def fetch_article(client,link):
    current=link
    for _ in range(4):
        async with client.stream('GET',current,headers={'User-Agent':UA,'Referer':'https://mp.weixin.qq.com/'}) as response:
            if response.status_code in (301,302,303,307,308):
                target=urljoin(current,response.headers.get('location',''))
                try: current=article_url(target)
                except ArticleError: raise ArticleError('verification','微信转入验证或提示页面，请在内置网页打开后读取正文。') from None
                continue
            if response.status_code!=200: raise ArticleError('http',f'微信文章未成功返回（HTTP {response.status_code}），请在内置网页检查。')
            buffer=bytearray()
            async for part in response.aiter_bytes():
                buffer.extend(part)
                if len(buffer)>MAX_PAGE:raise ArticleError('html_limit','文章网页超过8 MiB，未保存。')
            return parse_article(buffer.decode('utf-8',errors='replace'),link)
    raise ArticleError('redirect','文章重定向超过限制，未保存。')

def image_extension(data):
    if data.startswith(b'\x89PNG\r\n\x1a\n'):return '.png'
    if data.startswith(b'\xff\xd8\xff'):return '.jpg'
    if data[:6] in (b'GIF87a',b'GIF89a'):return '.gif'
    if data[:4]==b'RIFF' and data[8:12]==b'WEBP':return '.webp'
    if len(data)>16 and data[4:8]==b'ftyp' and data[8:12] in (b'avif',b'avis'):return '.avif'
    raise ArticleError('invalid_image','图片接口返回了非图片内容，未保存不完整文章。')

def safe_name(value):
    from worker import file_component
    clean=file_component(value,180)[:75]
    return clean or '公众号文章'

def documents(article,mapping):
    soup=BeautifulSoup(article['content'],'html.parser')
    for img in soup.find_all('img'):img['src']=mapping.get(img['src'],img['src'])
    body=str(soup)
    fields={k:article[k] for k in ('title','account','author','published','link')}
    front='---\n'+'\n'.join(k+': '+json.dumps(v,ensure_ascii=False) for k,v in fields.items())+'\n---\n\n'
    md=front+'# '+article['title']+'\n\n'+markdownify(body,heading_style='ATX',strip=['div','section','span'],keep_inline_images_in=HTML_TAGS)+'\n'
    page='<!doctype html><html lang="zh-CN"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><meta http-equiv="Content-Security-Policy" content="default-src \'none\'; img-src \'self\' https://*.qpic.cn https://*.qlogo.cn; style-src \'unsafe-inline\';"><title>'+html.escape(article['title'])+'</title><style>body{max-width:780px;margin:36px auto;padding:0 24px;color:#20242c;background:#fff;font:17px/1.9 -apple-system,system-ui}h1{font-size:28px;line-height:1.5}.meta{font-size:14px;color:#727681}img{max-width:100%;height:auto}pre{overflow:auto;background:#f3f4f5;padding:14px}table{border-collapse:collapse;width:100%}td,th{border:1px solid #ddd;padding:8px}blockquote{border-left:3px solid #ccc;margin-left:0;padding-left:16px}a{color:#327ec8}</style></head><body><h1>'+html.escape(article['title'])+'</h1><p class="meta">'+html.escape(' · '.join(x for x in [article['account'],article['author'] if article['author']!=article['account'] else '',article['published']] if x))+'</p>'+body+'<hr><p class="meta">原文：'+html.escape(article['link'])+'</p></body></html>'
    return md,page

def cover_file(path, blob, source):
    return dict(path=path, bytes=len(blob), sha256=hashlib.sha256(blob).hexdigest(), source=source)

async def read_image(client, url, referer, total, rejected):
    checked=image_url(url)
    async with client.stream('GET', checked, headers={'User-Agent':UA,'Referer':referer}) as response:
        if response.status_code!=200: raise ArticleError('image_http', rejected(response.status_code))
        blob=bytearray()
        async for part in response.aiter_bytes():
            blob.extend(part)
            if len(blob)>MAX_IMAGE or total+len(blob)>MAX_TOTAL:
                raise ArticleError('image_limit','图片超过单张32 MiB或每篇256 MiB上限，未保存不完整文章。')
    return bytes(blob)

async def export_article(client,article,folder,*,preview=False,progress=None):
    from photo_worker import publish_directory, verify_image
    base=Path(folder).expanduser().resolve(strict=True)
    if not base.is_dir():raise ArticleError('folder','保存位置不是文件夹。')
    article['coverRelative']=None
    if preview:
        dest=base/article['id'];dest.mkdir(exist_ok=False)
        md,page=documents(article,{})
        (dest/'文章.md').write_text(md,encoding='utf-8');(dest/'文章.html').write_text(page,encoding='utf-8')
        return dest,0
    from worker import stage_prefix
    staging=Path(tempfile.mkdtemp(prefix=stage_prefix('article'),dir=base))
    try:
        work=staging/'article';work.mkdir();assets=work/'images';assets.mkdir();mapping={};total=0;manifest=[]
        for index,url in enumerate(article['images'],1):
            blob=await read_image(client, url, article['link'], total, lambda status, index=index: f'第{index}张图片未成功返回（HTTP {status}），未保存不完整文章。')
            name=f'{index:03d}'+image_extension(blob);(assets/name).write_bytes(blob)
            try: verify_image(assets/name)
            except ValueError: raise ArticleError('invalid_image',f'第{index}张图片尺寸或解码检查失败，未保存不完整文章。') from None
            total+=len(blob);mapping[url]='images/'+name
            manifest.append(dict(path=mapping[url],bytes=len(blob),sha256=hashlib.sha256(blob).hexdigest()))
            if progress:progress(index,len(article['images']))
        cover=None
        cover_url=article.get('coverURL')
        if cover_url:
            if cover_url in mapping:
                item=next(item for item in manifest if item['path']==mapping[cover_url])
                cover=dict(path=item['path'], bytes=item['bytes'], sha256=item['sha256'], source='content')
            else:
                try:
                    blob=await read_image(client, cover_url, article['link'], total, lambda status: f'封面图片未成功返回（HTTP {status}），未保存不完整文章。')
                    name='cover'+image_extension(blob)
                except ArticleError as exc:
                    if exc.reason=='image_limit': raise ArticleError('image_limit','封面图片超过单张32 MiB或每篇256 MiB上限，未保存不完整文章。') from None
                    if exc.reason=='invalid_image': raise ArticleError('invalid_image','封面图片不是受支持的图片，未保存不完整文章。') from None
                    raise
                (assets/name).write_bytes(blob)
                try: verify_image(assets/name)
                except ValueError: raise ArticleError('invalid_image','封面图片尺寸或解码检查失败，未保存不完整文章。') from None
                total+=len(blob)
                cover=cover_file('images/'+name, blob, article.get('coverSource') or 'og:image')
            article['coverRelative']=cover['path']
        md,page=documents(article,mapping)
        source=json.dumps({**{k:article[k] for k in ('title','account','author','published','link','characters')},'images':manifest,'cover':cover},ensure_ascii=False,indent=2)+'\n'
        text_files={'文章.md':md.encode('utf-8'),'文章.html':page.encode('utf-8'),'来源.json':source.encode('utf-8')}
        total+=sum(len(data) for data in text_files.values())
        if total>MAX_TOTAL:raise ArticleError('article_limit','正文、图片和来源清单合计超过每篇256 MiB上限，未保存不完整文章。')
        for name,data in text_files.items():(work/name).write_bytes(data)
        parent=base/'公众号'/safe_name(article['account']);parent.mkdir(parents=True,exist_ok=True)
        stem=safe_name(article['title'])+'_'+article['id'][:8]
        for suffix in range(10000):
            dest=parent/(stem+(f'_{suffix}' if suffix else ''))
            try:publish_directory(work,dest);break
            except FileExistsError:continue
        else:raise ArticleError('name_limit','同名目录过多，未覆盖任何文件。')
        return dest,total
    finally:shutil.rmtree(staging,ignore_errors=True)

async def run_articles(links,snapshots,folder,action):
    from worker import emit
    def stop(*_):raise KeyboardInterrupt()
    prior=signal.signal(signal.SIGTERM,stop);succeeded=failed=0
    try:
        async with httpx.AsyncClient(timeout=30,follow_redirects=False) as client:
            for index,link in enumerate(links):
                emit('article_progress',link=link,detail=f'正在读取第{index+1}/{len(links)}篇文章。')
                try:
                    snapshot=snapshots.get(link)
                    article=parse_article(snapshot['html'],link,snapshot) if snapshot else await fetch_article(client,link)
                    dest,size=await export_article(client,article,folder,preview=action=='preview',progress=lambda done,total:emit('article_progress',link=link,detail=f'正在保存图片 {done}/{total}…'))
                    relative=article.get('coverRelative')
                    emit('article_saved' if action=='download' else 'article_preview',link=link,
                        article={**{k:article[k] for k in ('title','account','author','published','imageCount','characters','coverURL','excerpt')},
                            'path':str(dest),'bytes':size,'coverPath':str(dest/relative) if relative else None})
                    succeeded+=1
                except ArticleError as exc:emit('article_failure',link=link,reason=exc.reason,message=str(exc));failed+=1
                except httpx.HTTPError:emit('article_failure',link=link,reason='network',message='公众号网络请求失败，请检查网络后重试。');failed+=1
                except OSError:emit('article_failure',link=link,reason='filesystem',message='文章文件无法完整保存，请检查保存目录的权限或剩余空间。');failed+=1
                if index+1<len(links):await asyncio.sleep(1)
        emit('articles_complete',total=len(links),succeeded=succeeded,failed=failed)
        return 0 if failed==0 else 7
    finally:signal.signal(signal.SIGTERM,prior)
