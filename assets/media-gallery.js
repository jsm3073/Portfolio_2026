/* One image list powers the homepage, standalone projects, and unsaved editor previews. */
(() => {
  const siteRoot = new URL('../', document.currentScript.src);
  const element = (tag, className, text) => {
    const node = document.createElement(tag);
    if (className) node.className = className;
    if (text !== undefined) node.textContent = text;
    return node;
  };
  function setImage(img, src, alt) {
    img.alt = alt || '';
    const placeholder = img.parentElement.querySelector('.placeholder, .cover-empty');
    img.onload = () => { img.style.display = ''; img.classList.add('is-loaded'); if (placeholder) placeholder.hidden = true; };
    img.onerror = () => { img.style.display = 'none'; if (placeholder) placeholder.hidden = false; };
    img.src = new URL(src, siteRoot).href;
    img.style.display = '';
  }
  window.renderPortfolioMedia = function(data) {
    if (!Array.isArray(data?.projects)) return;
    for (const project of data.projects) {
      document.querySelectorAll(`[data-cover-project="${project.id}"]`).forEach(img => {
        const index = Number(img.dataset.coverIndex || 0);
        const cover = index === 0 ? project.cover : project.additionalCovers?.[index - 1];
        if (cover?.src) {
          setImage(img, cover.src, cover.alt || project.title);
          img.closest('.project-additional')?.removeAttribute('hidden');
        }
      });
      const gallery = document.querySelector(`[data-project-gallery="${project.id}"]`);
      if (!gallery) continue;
      gallery.replaceChildren();
      const toc = document.querySelector('.project-toc');
      toc.replaceChildren();
      const overview = element('a', '', 'Overview'); overview.href = '#overview'; toc.append(overview);
      let count = 0;
      project.sections.forEach((group, groupIndex) => {
        const section = element('section', 'plate-section'); section.id = `drawing-section-${groupIndex + 1}`;
        const link = element('a', '', group.label || group.title); link.href = '#' + section.id; toc.append(link);
        const header = element('header', 'plate-section-header');
        const title = element('h2', 'plate-section-title', group.title); title.id = section.id + '-title';
        section.setAttribute('aria-labelledby', title.id);
        header.append(element('div', 'plate-section-index', group.label), title, element('div', 'plate-section-count', `${group.images.length} plates`));
        const grid = element('div', 'plate-grid');
        group.images.forEach(item => {
          count++;
          const figure = element('figure', `plate${item.layout === 'wide' ? ' plate-wide' : ''}`);
          const frame = element('div', 'plate-frame');
          if (item.src) {
            const button = element('button', 'image-zoom'); button.type = 'button';
            button.setAttribute('aria-label', `Enlarge ${item.alt || item.caption || 'image ' + count}`);
            button.setAttribute('aria-haspopup', 'dialog');
            const img = element('img', 'plate-img'); img.loading = 'lazy'; img.decoding = 'async'; img.style.objectFit = item.fit;
            button.append(img, element('span', 'zoom-hint', 'View detail ↗')); frame.append(button);
            setImage(img, item.src, item.alt || item.caption);
          } else frame.append(element('span', 'plate-id-watermark', String(count).padStart(2, '0')));
          const caption = element('figcaption');
          caption.append(element('span', 'plate-id', String(count).padStart(2, '0')), element('span', 'plate-caption', item.caption));
          figure.append(frame, caption); grid.append(figure);
        });
        section.append(header, grid); gallery.append(section);
      });
      const countLabel = document.querySelector('[data-plate-count]');
      if (countLabel) countLabel.textContent = `${count} plates · End of project`;
    }
    window.dispatchEvent(new Event('portfolio:media-rendered'));
  };
  window.renderPortfolioMedia(window.PORTFOLIO_MEDIA);
  window.addEventListener('message', event => {
    if (window.parent === window || event.source !== window.parent || event.origin !== location.origin || event.data?.type !== 'portfolio-preview') return;
    if (event.data.projectId !== document.body.dataset.projectId) return;
    window.renderPortfolioMedia(event.data.data);
  });
})();
