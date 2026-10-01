(() => {
  'use strict';
  const $ = id => document.getElementById(id);
  let data, version, token, dirty = false, busy = false;
  let projectIndex = 0, sectionIndex = 0, coverIndex = 0, replacement = null;
  const removed = [];
  const project = () => data.projects[projectIndex];
  const section = () => project().sections[sectionIndex];
  const notice = (text, error = false) => {
    $('status').textContent = text;
    $('status').dataset.error = String(error);
  };
  function controls() {
    document.querySelectorAll('button, input, select').forEach(el => { el.disabled = busy || !data; });
    $('save').disabled = busy || !dirty;
    $('undo-remove').disabled = busy || !removed.length;
  }
  function changed() { dirty = true; controls(); notice('저장하지 않은 변경 사항이 있습니다.'); }
  async function api(path, payload) {
    const response = await fetch(path, payload === undefined ? {} : {
      method: 'POST', headers: {'Content-Type': 'application/json', 'X-Editor-Token': token}, body: JSON.stringify(payload)
    });
    const result = await response.json();
    if (!response.ok) {
      if (response.status === 409) throw new Error('다른 창 또는 프로그램에서 변경했습니다. 현재 편집 내용을 확인한 뒤 새로고침해 주세요. 덮어쓰지 않았습니다.');
      throw new Error(result.error || '요청을 완료하지 못했습니다.');
    }
    return result;
  }
  function node(tag, cls, text) {
    const el = document.createElement(tag);
    if (cls) el.className = cls;
    if (text !== undefined) el.textContent = text;
    return el;
  }
  function button(text, action, cls) {
    const el = node('button', cls, text); el.type = 'button'; el.addEventListener('click', action); return el;
  }
  function field(title, item, key, options) {
    const label = node('label', '', title);
    const input = node(options ? 'select' : 'input');
    if (options) options.forEach(([value, text]) => input.add(new Option(text, value)));
    else input.maxLength = key === 'caption' ? 2000 : 500;
    input.value = item[key];
    input.addEventListener('input', () => { item[key] = input.value; changed(); });
    label.append(input); return label;
  }
  const currentCover = () => coverIndex === 0 ? project().cover : project().additionalCovers[coverIndex - 1];
  function drawCover() {
    const covers = [project().cover, ...(project().additionalCovers || [])];
    $('cover-slot-label').hidden = covers.length < 2;
    $('cover-slot').replaceChildren();
    covers.forEach((cover, index) => $('cover-slot').add(new Option(index === 0 ? '대표 이미지 · 메인 + 작품 목록' : `상세 추가 이미지 ${index + 1}`, index)));
    $('cover-slot').value = coverIndex;
    $('cover').replaceChildren();
    if (currentCover().src) {
      const img = node('img'); img.src = '/' + currentCover().src.replace(/^\.\//, ''); img.alt = currentCover().alt;
      $('cover').append(img);
    } else $('cover').textContent = '이미지 미지정';
  }
  function move(from, to) {
    const images = section().images;
    if (busy || from < 0 || to < 0 || from >= images.length || to >= images.length || from === to) return;
    images.splice(to, 0, images.splice(from, 1)[0]); changed(); drawCards();
  }
  function drawCards() {
    $('cards').replaceChildren(); $('count').textContent = `${section().images.length}개 프레임`;
    if (!section().images.length) $('cards').append(node('div', 'empty', '위에서 사진을 추가하면 프레임이 자동으로 만들어집니다.'));
    section().images.forEach((item, index) => {
      const card = node('article', 'card');
      const top = node('div', 'card-top');
      const handle = button('↕', () => {}, 'handle');
      handle.setAttribute('aria-label', `${index + 1}번 사진 드래그 핸들. 옆의 위아래 버튼으로도 순서를 바꿀 수 있습니다.`);
      handle.draggable = true;
      handle.addEventListener('dragstart', event => {
        if (busy) { event.preventDefault(); return; }
        event.dataTransfer.setData('application/x-folio-image', item.id); event.dataTransfer.effectAllowed = 'move';
      });
      const order = node('div');
      const up = button('↑', () => move(index, index - 1)); up.setAttribute('aria-label', `${index + 1}번 사진 위로`);
      const down = button('↓', () => move(index, index + 1)); down.setAttribute('aria-label', `${index + 1}번 사진 아래로`);
      order.append(up, down); top.append(handle, node('span', '', `FRAME ${String(index + 1).padStart(2, '0')}`), order);
      card.addEventListener('dragover', event => {
        if (event.dataTransfer.types.includes('application/x-folio-image')) { event.preventDefault(); card.classList.add('drag-over'); }
      });
      card.addEventListener('dragleave', () => card.classList.remove('drag-over'));
      card.addEventListener('drop', event => {
        card.classList.remove('drag-over');
        const id = event.dataTransfer.getData('application/x-folio-image');
        if (!id) return;
        event.preventDefault(); move(section().images.findIndex(image => image.id === id), index);
      });
      const picture = node('div', 'card-image');
      if (item.src) {
        const img = node('img'); img.src = '/' + item.src.replace(/^\.\//, ''); img.alt = item.alt || item.caption; img.loading = 'lazy'; picture.append(img);
      } else picture.textContent = '사진을 넣을 빈 프레임';
      const fields = node('div', 'card-fields');
      fields.append(field('캡션', item, 'caption'), field('이미지 설명 (접근성)', item, 'alt'));
      const layout = node('div', 'two-up');
      layout.append(field('배치', item, 'layout', [['wide','한 줄 전체'],['half','반 너비 · 두 장 나란히']]), field('표시', item, 'fit', [['contain','전체 보이기 · 도면 권장'],['cover','프레임 채우기 · 크롭']])); fields.append(layout);
      const actions = node('div', 'card-actions');
      actions.append(button(item.src ? '사진 교체' : '사진 넣기', () => { replacement = item; $('replace-file').click(); }));
      if (item.src) actions.append(button('대표 이미지로', () => { project().cover = {src:item.src, alt:item.alt || item.caption || project().title}; coverIndex = 0; drawCover(); changed(); }));
      actions.append(button('목록에서 제거', () => {
        removed.push({projectId:project().id, sectionIndex, index, item}); section().images.splice(index, 1); changed(); drawCards();
        notice('목록에서 제거했습니다. 원본은 남아 있습니다. ‘제거 취소’로 되돌릴 수 있습니다.');
      }, 'danger'));
      card.append(top, picture, fields, actions); $('cards').append(card);
    });
    controls();
  }
  function drawSection() { $('section-title').value = section().title; $('section-label').value = section().label; drawCards(); }
  function drawProject() {
    $('section').replaceChildren(); project().sections.forEach((group, i) => $('section').add(new Option(group.title, i)));
    $('section').value = sectionIndex; drawCover(); drawSection();
  }
  function readBase64(file) {
    return new Promise((resolve, reject) => {
      const reader = new FileReader(); reader.onload = () => resolve(reader.result.split(',')[1]);
      reader.onerror = () => reject(new Error('사진을 읽지 못했습니다.')); reader.readAsDataURL(file);
    });
  }
  async function upload(files, target) {
    if (busy || !files.length) return;
    busy = true; controls(); let completed = 0;
    try {
      for (const file of files) {
        notice(`사진 추가 중 ${completed + 1}/${files.length} · ${file.name}`);
        if (!/\.(jpe?g|png|webp)$/i.test(file.name) || file.size > 20000000) throw new Error(`${file.name}: JPG·PNG·WebP, 한 장당 20 MB 이하만 가능합니다.`);
        const result = await api('/api/upload', {projectId:project().id, name:file.name, base64:await readBase64(file)});
        if (target === 'cover') Object.assign(currentCover(), {src:result.src, alt:project().title});
        else if (target) {
          if (target.src) [project().cover, ...(project().additionalCovers || [])].forEach(cover => { if (cover.src === target.src) cover.src = result.src; });
          target.src = result.src;
        } else section().images.push({id:crypto.randomUUID(), src:result.src, caption:'', alt:'', layout:'wide', fit:'contain'});
        dirty = true; completed++;
      }
      notice(`${completed}장 추가했습니다. 미리보기 후 저장하세요.`);
    } catch (error) { notice(`${error.message}${completed ? ` 앞의 ${completed}장은 추가되어 있습니다.` : ''}`, true); }
    finally { busy = false; drawCover(); drawCards(); }
  }
  $('project').addEventListener('change', () => { projectIndex = Number($('project').value); sectionIndex = 0; coverIndex = 0; drawProject(); });
  $('section').addEventListener('change', () => { sectionIndex = Number($('section').value); drawSection(); });
  $('section-title').addEventListener('input', () => { section().title = $('section-title').value; $('section').selectedOptions[0].textContent = section().title; changed(); });
  $('section-label').addEventListener('input', () => { section().label = $('section-label').value; changed(); });
  $('dropzone').addEventListener('click', () => $('files').click());
  $('files').addEventListener('change', () => { upload([...$('files').files], null); $('files').value = ''; });
  $('cover-slot').addEventListener('change', () => { coverIndex = Number($('cover-slot').value); drawCover(); });
  $('cover-upload').addEventListener('click', () => { replacement = 'cover'; $('replace-file').click(); });
  $('replace-file').addEventListener('change', () => { upload([...$('replace-file').files], replacement); $('replace-file').value = ''; });
  $('dropzone').addEventListener('dragover', event => { event.preventDefault(); if (!busy) $('dropzone').classList.add('over'); });
  $('dropzone').addEventListener('dragleave', () => $('dropzone').classList.remove('over'));
  $('dropzone').addEventListener('drop', event => { event.preventDefault(); $('dropzone').classList.remove('over'); upload([...event.dataTransfer.files], null); });
  window.addEventListener('dragover', event => { if (event.dataTransfer.types.includes('Files')) event.preventDefault(); });
  window.addEventListener('drop', event => { if (event.dataTransfer.types.includes('Files')) event.preventDefault(); });
  $('undo-remove').addEventListener('click', () => {
    const last = removed.pop(); if (!last) return;
    data.projects.find(p => p.id === last.projectId).sections[last.sectionIndex].images.splice(last.index, 0, last.item); changed(); drawCards();
  });
  $('save').addEventListener('click', async () => {
    busy = true; controls(); notice('저장 중…');
    try { const result = await api('/api/save', {data, version}); version = result.version; dirty = false; notice('저장했습니다. 로컬 홈페이지를 새로고침하면 반영됩니다.'); }
    catch (error) { notice(error.message, true); }
    finally { busy = false; controls(); }
  });
  function sendPreview() {
    if (!data || !$('preview-dialog').open) return;
    $('preview-frame').contentWindow.postMessage({type:'portfolio-preview', data, projectId:project().id}, location.origin);
  }
  $('preview').addEventListener('click', () => { $('preview-dialog').showModal(); $('preview-frame').src = '/' + window.PORTFOLIO_ROUTES[project().id] + '?editor-preview=1'; });
  $('preview-frame').addEventListener('load', sendPreview);
  $('preview-refresh').addEventListener('click', sendPreview);
  $('preview-close').addEventListener('click', () => $('preview-dialog').close());
  $('preview-dialog').addEventListener('close', () => { $('preview-frame').removeAttribute('src'); });
  window.addEventListener('beforeunload', event => { if (dirty || busy) { event.preventDefault(); event.returnValue = ''; } });
  api('/api/data').then(result => {
    ({data, version, token} = result); data.projects.forEach((p, i) => $('project').add(new Option(p.title, i)));
    drawProject(); controls(); notice('준비되었습니다. 프로젝트와 갤러리 구획을 선택하세요.');
  }).catch(error => { notice(`연결 실패: Start-Media-Editor.cmd를 실행한 뒤 http://localhost:8765/editor/ 에서 열어주세요. ${error.message}`, true); });
})();
