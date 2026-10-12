'use strict';
const mediaRoot = '../../../entry/src/main/resources/base/media/';
const grid = document.getElementById('grid');
const search = document.getElementById('search');
const category = document.getElementById('category');
let selectedName = 'ui_folder';
function selectIcon(icon) {
  selectedName = icon.name;
  document.getElementById('detail-title').textContent = icon.label;
  document.getElementById('usage').textContent = icon.usage;
  document.getElementById('source').textContent = '资源：' + icon.name + '.svg · ' + icon.batch;
  document.getElementById('snippet').value = "AppIcon({ source: $r('app.media." + icon.name + "'), size: 22 })";
  for (const tile of grid.children) tile.setAttribute('aria-pressed', String(tile.dataset.name === icon.name));
}
function render() {
  const query = search.value.trim().toLowerCase();
  const entries = iconCatalog.filter(icon => (!category.value || icon.category === category.value) &&
    [icon.name, icon.label, icon.usage, icon.batch].join(' ').toLowerCase().includes(query));
  grid.replaceChildren();
  for (const icon of entries) {
    const tile = document.createElement('button');
    tile.type = 'button'; tile.className = 'tile'; tile.dataset.name = icon.name;
    tile.setAttribute('aria-pressed', String(icon.name === selectedName));
    const swatch = document.createElement('span');
    swatch.className = 'swatch' + (icon.tone === 'inverse' ? ' inverse' : '');
    const image = document.createElement('img');
    image.src = mediaRoot + icon.name + '.svg'; image.alt = ''; swatch.append(image);
    const title = document.createElement('strong'); title.textContent = icon.label;
    const name = document.createElement('code'); name.textContent = icon.name;
    const badge = document.createElement('span'); badge.className = 'badge';
    badge.textContent = icon.category + ' · ' + icon.batch;
    tile.append(swatch, title, name, badge);
    tile.addEventListener('click', () => selectIcon(icon)); grid.append(tile);
  }
  document.getElementById('count').textContent = entries.length + ' / ' + iconCatalog.length + ' 个图标';
  document.getElementById('empty').hidden = entries.length !== 0;
}
search.addEventListener('input', render);
category.addEventListener('change', render);
document.getElementById('size').addEventListener('change', event => {
  document.documentElement.style.setProperty('--icon-size', event.target.value + 'px');
});
document.getElementById('snippet').addEventListener('click', event => event.target.select());
render();
selectIcon(iconCatalog.find(icon => icon.name === selectedName));
