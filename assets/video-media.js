(() => {
  'use strict';
  function parse(value) {
    try {
      const url = new URL(value.trim());
      if (!['https:', 'http:'].includes(url.protocol) || url.username || url.password || url.port) return null;
      const host = url.hostname.toLowerCase();
      let id;
      if (['youtube.com','www.youtube.com','m.youtube.com','youtu.be','www.youtu.be','www.youtube-nocookie.com'].includes(host)) {
        id = host.endsWith('youtu.be') ? url.pathname.slice(1) : url.pathname === '/watch' ? url.searchParams.get('v') : url.pathname.match(/^\/(?:embed|shorts|live)\/([^/]+)\/?$/)?.[1];
        if (!/^[\w-]{11}$/.test(id || '')) return null;
        return {url:`https://www.youtube.com/watch?v=${id}`,embed:`https://www.youtube-nocookie.com/embed/${id}?autoplay=1&playsinline=1`,thumbnail:`https://i.ytimg.com/vi/${id}/hqdefault.jpg`};
      }
      if (['vimeo.com','www.vimeo.com','player.vimeo.com'].includes(host)) {
        const match = url.pathname.match(/^\/(?:video\/)?(\d+)(?:\/([a-zA-Z0-9]+))?\/?$/);
        if (!match) return null;
        const hash = match[2] || url.searchParams.get('h') || '';
        if (hash && !/^[a-zA-Z0-9]+$/.test(hash)) return null;
        return {url:`https://vimeo.com/${match[1]}${hash ? '/' + hash : ''}`,embed:`https://player.vimeo.com/video/${match[1]}?autoplay=1${hash ? '&h=' + hash : ''}`};
      }
    } catch {}
    return null;
  }
  const thumbnails = new Map();
  async function thumbnail(video) {
    if (video.thumbnail) return video.thumbnail;
    if (!thumbnails.has(video.url)) thumbnails.set(video.url, (async () => {
      try {
        const response = await fetch('https://vimeo.com/api/oembed.json?url=' + encodeURIComponent(video.url), {signal:AbortSignal.timeout(8000)});
        if (!response.ok) return '';
        const result = await response.json();
        const url = new URL(result.thumbnail_url);
        return url.protocol === 'https:' && (url.hostname === 'vimeocdn.com' || url.hostname.endsWith('.vimeocdn.com')) ? url.href : '';
      } catch { return ''; }
    })());
    return thumbnails.get(video.url);
  }
  function mount(container, item) {
    const video = parse(item.videoUrl || '');
    if (!video) { container.textContent = '지원하지 않는 비디오 링크'; return; }
    container.classList.add('video-media');
    const button = document.createElement('button');
    button.type = 'button'; button.className = 'video-play';
    button.setAttribute('aria-label', `비디오 재생: ${item.alt || item.caption || '작품 영상'}`);
    const label = document.createElement('span'); label.className = 'video-play-label'; label.textContent = '▶ 비디오 재생';
    button.append(label); container.append(button);
    thumbnail(video).then(src => {
      if (!src || !button.isConnected) return;
      const img = document.createElement('img'); img.alt = ''; img.loading = 'lazy'; img.src = src;
      img.onerror = () => img.remove(); button.prepend(img);
    });
    button.addEventListener('click', () => {
      const iframe = document.createElement('iframe'); iframe.src = video.embed;
      iframe.title = item.alt || item.caption || '작품 영상';
      iframe.allow = 'autoplay; fullscreen; picture-in-picture'; iframe.allowFullscreen = true;
      iframe.referrerPolicy = 'strict-origin-when-cross-origin';
      const stop = document.createElement('button'); stop.type = 'button'; stop.className = 'video-stop'; stop.textContent = '재생 닫기 ×';
      stop.onclick = () => { container.replaceChildren(button); button.focus(); };
      container.replaceChildren(iframe, stop); iframe.focus();
    });
  }
  window.PortfolioVideo = {parse, mount};
})();