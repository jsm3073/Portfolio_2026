/* The project remains a normal document: native URLs, reload, and browser history. */
(() => {
  const copy = document.getElementById('copy-project-link');
  const status = document.getElementById('copy-status');
  copy?.addEventListener('click', async () => {
    const url = new URL(location.href); url.hash = ''; url.search = '';
    try { await navigator.clipboard.writeText(url.href); status.textContent = 'Link copied'; }
    catch { status.textContent = 'Copy this page’s address from your browser.'; }
  });
  // Old gallery fragments resolve to the new page via the homepage compatibility handler.
  const viewer = document.createElement('dialog');
  viewer.className = 'image-viewer';
  viewer.setAttribute('aria-label','Project image detail');
  viewer.innerHTML = '<div class="viewer-toolbar"><span class="viewer-count" aria-live="polite"></span><a class="viewer-original" target="_blank" rel="noopener">Open original ↗</a><button class="viewer-close" type="button" autofocus>Close ×</button></div><img class="viewer-image" alt=""><div class="viewer-bottom"><p class="viewer-caption"></p><div class="viewer-controls"><button type="button" class="viewer-prev" aria-label="Previous image">←</button><button type="button" class="viewer-next" aria-label="Next image">→</button></div></div>';
  document.body.append(viewer);
  let current = 0, returnFocus = null;
  const images = () => [...document.querySelectorAll('.image-zoom')];
  function show(index) {
    const all = images();
    if (!all[index]) return;
    current = index;
    const image = all[index].querySelector('img');
    const full = viewer.querySelector('.viewer-image');
    full.src = image.dataset.full || image.currentSrc || image.src;
    full.alt = image.alt;
    viewer.querySelector('.viewer-original').href = full.src;
    viewer.querySelector('.viewer-caption').textContent = all[index].closest('figure').querySelector('.plate-caption')?.textContent || image.alt;
    viewer.querySelector('.viewer-count').textContent = `${index + 1} / ${all.length}`;
    viewer.querySelector('.viewer-prev').disabled = index === 0;
    viewer.querySelector('.viewer-next').disabled = index === all.length - 1;
  }
  document.addEventListener('click', event => {
    const button = event.target.closest('.image-zoom');
    if (!button) return;
    returnFocus = button; show(images().indexOf(button));
    viewer.showModal(); document.body.classList.add('viewer-open');
  });
  viewer.querySelector('.viewer-close').addEventListener('click', () => viewer.close());
  viewer.querySelector('.viewer-prev').addEventListener('click', () => show(current - 1));
  viewer.querySelector('.viewer-next').addEventListener('click', () => show(current + 1));
  viewer.addEventListener('keydown', event => {
    if (event.key === 'ArrowLeft') { event.preventDefault(); show(current - 1); }
    if (event.key === 'ArrowRight') { event.preventDefault(); show(current + 1); }
  });
  viewer.addEventListener('click', event => { if (event.target === viewer) viewer.close(); });
  viewer.addEventListener('close', () => {
    document.body.classList.remove('viewer-open');
    viewer.querySelector('.viewer-image').removeAttribute('src');
    if (returnFocus?.isConnected) returnFocus.focus({preventScroll:true});
  });
  window.addEventListener('portfolio:media-rendered', () => { if (viewer.open) viewer.close(); });
})();
