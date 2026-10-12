import Foundation

/// 捕获范围限于用户在内置官方网页实际加载的媒体，不代表作者作品全集。
enum PlatformWebCapture {
    static func acceptedMediaURL(_ text: String, platform: MediaPlatform) -> Bool {
        guard let url = URL(string: text), url.scheme == "https", url.user == nil, url.password == nil,
              url.port == nil || url.port == 443, let host = url.host?.lowercased() else { return false }
        switch platform {
        case .wechat:
            return host == "finder.video.qq.com" || host.hasSuffix(".video.qq.com")
                || host.hasSuffix(".wxapp.tc.qq.com") || host.hasSuffix(".qpic.cn")
        case .xiaohongshu:
            return host == "xhscdn.com" || host.hasSuffix(".xhscdn.com")
        default: return false
        }
    }

    static let script = #"""
    (() => {
      if (window.__shiyingCapture) return;
      const state = { source: location.href, posts: new Map(), encrypted: false };
      const platform = location.hostname.endsWith('xiaohongshu.com') ? 'xiaohongshu' : location.hostname.endsWith('bilibili.com') ? 'bilibili' : 'wechat';
      const pageKey = () => location.href.split('#shiying-capture-')[0];
      let key = pageKey();
      const reset = () => { if (key !== pageKey()) { key = pageKey(); state.posts.clear(); state.encrypted = false; } state.source = location.href; };
      const hash = s => { let h = 2166136261; for (let i=0;i<s.length;i++) h = Math.imul(h ^ s.charCodeAt(i), 16777619); return (h>>>0).toString(16); };
      const mediaAllowed = s => {
        try { const u=new URL(s); if(u.protocol!=='https:' || u.username || u.password) return false;
          return platform==='wechat' ? /(^|\.)video\.qq\.com$|\.wxapp\.tc\.qq\.com$|\.qpic\.cn$/.test(u.hostname) : /(^|\.)xhscdn\.com$/.test(u.hostname);
        } catch { return false; }
      };
      const save = (url, fields={}) => {
        reset(); if (!mediaAllowed(url) || state.posts.size >= 5000) return;
        const id=String(fields.id || 'web-'+hash(url.split('?')[0]));
        if(platform==='xiaohongshu') {
          const current=location.pathname.match(/^\/(?:explore|discovery\/item)\/([a-fA-F0-9]{24})/);
          // 只读取当前作品，避免把初始数据中的推荐流当成目标博主。
          if(!current || id!==current[1]) return;
        }
        let link=fields.link || location.href.split('#')[0]+'#shiying-capture-'+id;
        try { const h=new URL(link).hostname; if(platform==='wechat' ? !h.endsWith('.weixin.qq.com') : !h.endsWith('.xiaohongshu.com')) return; } catch { return; }
        state.posts.set(id, {id, link, title:String(fields.title || document.title || '网页视频').slice(0,1000),
          author:String(fields.author || '').slice(0,256), isVideo:true, mediaURL:url, platformRaw:platform,
          ...(fields.cover ? {cover:fields.cover} : {})});
      };
      const inspect = (root) => {
        let visits=0; const seen=new WeakSet();
        const walk=(o,depth=0) => {
          if(!o || typeof o!=='object' || depth>16 || ++visits>30000 || seen.has(o)) return; seen.add(o);
          const d=o.objectDesc || o.object_desc || o;
          const encrypted = o.decodeKey || o.decode_key || d.decodeKey || d.decode_key || o.encrypted===true || d.encrypted===true;
          if(encrypted) state.encrypted=true;
          const media = d.media || d.mediaList || d.video?.media?.stream?.h264 || d.video?.media?.stream?.h265;
          if(Array.isArray(media) && !encrypted) for(const m of media) {
            if(m.decodeKey || m.decode_key || m.encrypted===true) { state.encrypted=true; continue; }
            const url=m.masterUrl || m.master_url || m.url;
            if(typeof url==='string') save(url + (typeof m.urlToken==='string' ? m.urlToken : ''), {
              id:o.id || o.objectId || o.object_id || o.noteId || o.note_id,
              title:d.description || d.desc || d.title,
              author:o.nickname || o.contact?.nickname || o.user?.nickname || d.user?.nickname,
              cover:m.coverUrl || m.cover_url,
              link:platform==='xiaohongshu' && (o.noteId || o.note_id) ? 'https://www.xiaohongshu.com/explore/'+(o.noteId || o.note_id)+(o.xsecToken || o.xsec_token ? '?xsec_token='+encodeURIComponent(o.xsecToken || o.xsec_token)+'&xsec_source=pc_feed' : '') : undefined
            });
          }
          for(const v of Object.values(o)) if(v && typeof v==='object') walk(v,depth+1);
        }; walk(root);
      };
      const originalFetch=window.fetch;
      window.fetch=async function(...args) { const response=await originalFetch.apply(this,args);
        try { if((response.headers.get('content-type')||'').includes('json')) response.clone().json().then(inspect).catch(()=>{}); } catch {} return response; };
      const send=XMLHttpRequest.prototype.send;
      XMLHttpRequest.prototype.send=function(...args) { this.addEventListener('load',()=>{ try { if(this.responseType==='json') inspect(this.response); else if(this.responseType==='' || this.responseType==='text') { const t=this.responseText; if(t.length<8*1024*1024) inspect(JSON.parse(t)); } } catch {} }); return send.apply(this,args); };
      state.read=()=>{ reset();
        if(platform==='bilibili') for(const a of document.querySelectorAll('a[href]')) {
          try { const u=new URL(a.href,location.href); const m=u.pathname.match(/^\/video\/(BV[A-Za-z0-9]+|av[0-9]+)\/?$/);
            if(m && /(^|\.)bilibili\.com$/.test(u.hostname) && state.posts.size<5000) state.posts.set(m[1],{id:m[1],link:'https://www.bilibili.com/video/'+m[1],title:(a.title || a.textContent || m[1]).trim().slice(0,1000),author:'',isVideo:true,platformRaw:platform});
          } catch {}
        }
        inspect(window.__INITIAL_STATE__); for(const v of (state.encrypted ? [] : document.querySelectorAll('video'))) { const url=v.currentSrc || v.src; if(url && !url.startsWith('blob:')) save(url,{cover:v.poster}); } return {captureSource:state.source,capturedPosts:Array.from(state.posts.values()),capturePartial:true,encrypted:state.encrypted}; };
      window.__shiyingCapture=state;
    })();
    """#
}
