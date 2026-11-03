'use strict';
// Glasses: the page talks to the menu bar app on 127.0.0.1. State arrives over Server-Sent Events.

const $ = (s, el = document) => el.querySelector(s);
const $$ = (s, el = document) => [...el.querySelectorAll(s)];
const h = (tag, attrs = {}, ...kids) => {
  const el = document.createElement(tag);
  for (const [k, v] of Object.entries(attrs)) {
    if (v == null || v === false) continue;
    if (k === 'class') el.className = v;
    else if (k.startsWith('on')) el.addEventListener(k.slice(2), v);
    else if (k === 'html') el.innerHTML = v;
    else el.setAttribute(k, v === true ? '' : v);
  }
  for (const kid of kids.flat()) if (kid != null && kid !== false) el.append(kid instanceof Node ? kid : String(kid));
  return el;
};

let S = null;               // the last state from the app
let selected = new Set();   // capture handles picked in the glasses gallery
let library = null;         // the export folder listing
let macFilter = 'all';
let logs = [];
let catalog = null;         // the glasses settings the app knows
let catalogLoading = false;
let lastResultAt = null;
let tab = 'home';

// ---------- helpers

function fmtBytes(n) {
  if (n == null) return '—';
  const u = ['B', 'KB', 'MB', 'GB', 'TB']; let i = 0; let v = Number(n);
  while (v >= 1000 && i < u.length - 1) { v /= 1000; i++; }
  return (i === 0 ? v : v.toFixed(v < 10 ? 1 : 0)).toString() + ' ' + u[i];
}
function fmtDate(iso, withTime = true) {
  if (!iso) return 'unknown date';
  const d = new Date(iso);
  return d.toLocaleDateString('en-GB', { day: 'numeric', month: 'short', year: 'numeric' }) + (withTime ? ' · ' + d.toLocaleTimeString('en-GB', { hour: '2-digit', minute: '2-digit' }) : '');
}
function fmtDur(s) {
  if (!isFinite(s) || s < 0) return '';
  s = Math.round(s);
  return s >= 60 ? `${Math.floor(s / 60)} min ${String(s % 60).padStart(2, '0')} s` : `${s} s`;
}
const typeLabel = t => ({ video: 'Video', photo: 'Photo', live: 'Live photo' }[t] || t);
const typeIcon = t => ({ video: '▶', photo: '◻', live: '◎' }[t] || '•');

async function api(method, path, body) {
  const opt = { method, headers: {} };
  if (method !== 'GET') { opt.headers['X-Visor'] = '1'; opt.headers['Content-Type'] = 'application/json'; opt.body = JSON.stringify(body || {}); }
  let res;
  try { res = await fetch(path, opt); } catch (e) { toast('The app is not responding.', true); throw e; }
  const type = res.headers.get('Content-Type') || '';
  const data = type.includes('json') ? await res.json() : await res.text();
  if (!res.ok) { const msg = (data && data.error) || data || res.statusText; toast(msg, true); throw new Error(msg); }
  return data;
}
const post = (p, b) => api('POST', p, b);

let toastTimer;
function toast(text, err = false) {
  const t = $('#toast');
  t.textContent = text; t.className = 'toast' + (err ? ' err' : '');
  clearTimeout(toastTimer); toastTimer = setTimeout(() => t.classList.add('hidden'), err ? 9000 : 5000);
}

function modal({ title, body, actions }) {
  return new Promise(resolve => {
    $('#modalTitle').textContent = title;
    const b = $('#modalBody'); b.innerHTML = ''; b.append(body);
    const a = $('#modalActions'); a.innerHTML = '';
    const close = v => { $('#modal').classList.add('hidden'); resolve(v); };
    a.append(h('button', { class: 'ghost', onclick: () => close(false) }, 'Cancel'));
    for (const act of actions) {
      const btn = h('button', { class: act.class || 'primary', onclick: () => close(act.value ?? true) }, act.label);
      if (act.disabledUntil) { btn.disabled = true; act.disabledUntil(ok => btn.disabled = !ok); }
      a.append(btn);
    }
    $('#modal').classList.remove('hidden');
  });
}

// ---------- tabs

function showTab(name) {
  tab = name;
  $$('#nav a').forEach(a => a.classList.toggle('on', a.dataset.tab === name));
  $$('.tab').forEach(s => s.classList.toggle('hidden', s.id !== 'tab-' + name));
  if (name === 'mac') loadLibrary();
  if (name === 'settings') loadCatalog();
  if (name === 'log') renderLog(true);
  try { localStorage.setItem('tab', name); } catch {}
}
$$('#nav a').forEach(a => a.addEventListener('click', () => showTab(a.dataset.tab)));

// ---------- live state

function connect() {
  const es = new EventSource('/api/events');
  // The first state waits on the disk; a privacy prompt from macOS holds it until answered.
  const permTimer = setTimeout(() => { if (!S) $('#perm').classList.remove('hidden'); }, 2500);
  es.addEventListener('state', e => { clearTimeout(permTimer); $('#perm').classList.add('hidden'); $('#dead').classList.add('hidden'); S = JSON.parse(e.data); render(); });
  es.addEventListener('logs', e => { logs = JSON.parse(e.data); renderLog(true); });
  es.addEventListener('log', e => { logs.push(JSON.parse(e.data)); if (logs.length > 3000) logs.splice(0, logs.length - 3000); renderLog(false); });
  es.onerror = () => { $('#dead').classList.toggle('hidden', !!S && navigator.onLine === false ? true : false); setTimeout(checkAlive, 3000); };
}
async function checkAlive() {
  try { await fetch('/api/state'); $('#dead').classList.add('hidden'); } catch { $('#dead').classList.remove('hidden'); }
}

function render() {
  if (!S) return;
  const busy = S.busy;
  // connection pill and buttons
  const c = $('#conn'); c.className = 'conn ' + S.conn;
  $('#connText').textContent = { connected: 'Connected', connecting: 'Connecting…', disconnected: 'Disconnected' }[S.conn];
  $('#connectBtn').classList.toggle('hidden', S.conn === 'connected');
  $('#connectBtn').disabled = !!busy || !S.ownerKey;
  $('#refreshBtn').disabled = !!busy || !S.ownerKey;
  $('#disconnectBtn').classList.toggle('hidden', S.conn !== 'connected');
  $('#disconnectBtn').disabled = !!busy;
  $('#brandSub').textContent = S.device?.model ? modelName(S.device.model) : (S.owner ? 'Serial ' + S.owner.serial : 'Ray-Ban Meta');
  $('#offline').classList.toggle('hidden', !S.offline);
  const ce = $('#connErr');
  ce.classList.toggle('hidden', !S.connError || S.conn === 'connected' || !!busy);
  ce.textContent = S.connError ? 'Connection: ' + S.connError : '';

  // busy panel
  $('#busy').classList.toggle('hidden', !busy);
  if (busy) {
    $('#busyLabel').textContent = busy.label;
    $('#busyDetail').textContent = busy.detail || '';
    $('#cancelBtn').classList.toggle('hidden', !busy.cancellable);
    const has = busy.total > 0;
    $('#busyBarWrap').classList.toggle('hidden', !has);
    if (has) {
      const pct = Math.min(100, (busy.done || 0) * 100 / busy.total);
      $('#busyBar').style.width = pct.toFixed(1) + '%';
      const eta = busy.rate ? (busy.total - busy.done) / busy.rate : NaN;
      $('#busyNums').textContent = `${fmtBytes(busy.done)} of ${fmtBytes(busy.total)} · ${pct.toFixed(0)}%` + (busy.rate ? ` · ${fmtBytes(busy.rate)}/s · about ${fmtDur(eta)} left` : '');
    } else $('#busyNums').textContent = '';
  }

  if (S.lastResult && S.lastResult.at !== lastResultAt) {
    if (lastResultAt !== null) { toast(S.lastResult.text, !S.lastResult.ok); if (tab === 'mac' || /Import|Trash/i.test(S.lastResult.text)) loadLibrary(); }
    lastResultAt = S.lastResult.at;
  }

  renderHome(); renderGlasses(); renderControl(); renderAccount(); renderPrefs();
  if (tab === 'settings' && !catalog) loadCatalog(); else renderSettingsValues();
}

const modelName = m => /266|gen ?2/i.test(m) ? 'Ray-Ban Meta (Gen 2)' : m;

function kv(el, pairs) {
  el.innerHTML = '';
  for (const [k, v] of pairs) { if (v == null || v === '') continue; el.append(h('dt', {}, k), h('dd', {}, v)); }
  if (!el.children.length) el.append(h('dt', {}, '—'), h('dd', { class: 'muted' }, 'Not read yet'));
}

function renderHome() {
  const d = S.device;
  kv($('#homeDevice'), [
    ['Model', d?.model ? modelName(d.model) : null], ['Serial', d?.serial || S.owner?.serial], ['Software', d?.build],
    ['Bluetooth', d?.bluetooth || S.owner?.address], ['Owner', S.ownerKey ? (S.owner ? 'this Mac, since ' + fmtDate(S.owner.pairedAt, false) : 'this Mac') : 'not yet: see Account'],
  ]);
  const st = S.extras?.status;
  if (st && st.fields?.length) {
    const want = ['batteryPercent', 'charging', 'caseBattery', 'worn', 'hinge', 'storageFree', 'recording'];
    const picked = want.map(k => st.fields.find(f => f.key === k)).filter(Boolean);
    kv($('#homeStatus'), (picked.length ? picked : st.fields.slice(0, 6)).map(f => [statusLabel(f), statusValue(f.value)]));
  }
  const caps = S.captures || [];
  const missing = caps.filter(c => !c.onMac);
  $('#homeGallery').innerHTML = '';
  if (S.capturesAt) {
    $('#homeGallery').classList.remove('muted');
    $('#homeGallery').append(h('span', { class: 'big' }, caps.length), ' on the glasses · ',
      h('b', {}, missing.length), ' not on the Mac yet' + (missing.length ? ` (${fmtBytes(missing.reduce((a, c) => a + c.size, 0))})` : ''));
  } else $('#homeGallery').textContent = S.ownerKey ? 'Connect the glasses to see their gallery.' : 'This Mac does not own the glasses yet.';
  $('#homeImport').disabled = !!S.busy || !S.ownerKey || (S.capturesAt && !missing.length);
  $('#homeDeleteAfter').checked = $('#homeDeleteAfter').dataset.touched ? $('#homeDeleteAfter').checked : S.prefs.deleteAfterImport;
  $('#navGlasses').textContent = S.capturesAt ? caps.length : '';
}

function renderGlasses() {
  const caps = S.captures || [];
  for (const hd of [...selected]) if (!caps.some(c => c.handle === hd)) selected.delete(hd);
  $('#glassesSub').textContent = S.capturesAt
    ? `${caps.length} items · list read ${fmtDate(S.capturesAt)} · ${caps.filter(c => c.onMac).length} already on the Mac`
    : 'Not read yet: connect the glasses.';
  const grid = $('#glassesGrid');
  const key = JSON.stringify(caps.map(c => [c.handle, c.onMac, c.hasPreview])) + [...selected].join();
  if (grid.dataset.key !== key) {
    grid.dataset.key = key; grid.innerHTML = '';
    for (const c of caps) {
      const thumb = c.hasPreview ? h('img', { src: `/api/preview/${encodeURIComponent(c.handle)}`, loading: 'lazy', alt: '' }) : typeIcon(c.type);
      const tile = h('div', { class: 'tile' + (selected.has(c.handle) ? ' sel' : ''), onclick: () => { selected.has(c.handle) ? selected.delete(c.handle) : selected.add(c.handle); renderGlasses(); } },
        h('div', { class: 'thumb' }, thumb),
        h('span', { class: 'pick' }, selected.has(c.handle) ? '✓' : ''),
        h('span', { class: 'kind' }, typeLabel(c.type)),
        h('div', { class: 'meta' },
          h('b', {}, fmtDate(c.takenAt)),
          h('span', { class: 'muted' }, c.sizeText + (c.landscape ? ' · landscape' : '')),
          h('div', { class: 'badges' },
            c.onMac ? h('span', { class: 'badge ok' }, 'On the Mac') : h('span', { class: 'badge warn' }, 'Not on the Mac'),
            c.delivered ? h('span', { class: 'badge', title: 'The glasses already sent it to a phone' }, 'sent to a phone') : null)),
        c.onMac ? h('div', { class: 'actions' }, h('button', { class: 'small', onclick: e => { e.stopPropagation(); openViewer(c.macFiles[0]); } }, 'View')) : null);
      grid.append(tile);
    }
  }
  const empty = $('#glassesEmpty');
  empty.classList.toggle('hidden', caps.length > 0);
  empty.textContent = S.capturesAt ? 'No photos or videos on the glasses.' : 'Connect the glasses to see their gallery.';
  const sel = caps.filter(c => selected.has(c.handle));
  $('#selInfo').textContent = sel.length ? `${sel.length} selected · ${fmtBytes(sel.reduce((a, c) => a + c.size, 0))}` : '';
  const busy = !!S.busy;
  $('#importSelBtn').disabled = busy || !sel.length;
  $('#deleteSelBtn').disabled = busy || !sel.length;
  $('#importMissingBtn').disabled = busy || !S.ownerKey;
  $('#previewsBtn').disabled = busy || !S.ownerKey;
  if (!$('#glDeleteAfter').dataset.touched) $('#glDeleteAfter').checked = S.prefs.deleteAfterImport;
}

$$('[data-sel]').forEach(b => b.addEventListener('click', () => {
  const caps = S?.captures || [];
  const m = b.dataset.sel;
  selected = new Set(caps.filter(c => m === 'all' || (m === 'missing' && !c.onMac) || (m === 'onmac' && c.onMac)).map(c => c.handle));
  renderGlasses();
}));
for (const id of ['#homeDeleteAfter', '#glDeleteAfter']) $(id).addEventListener('change', e => e.target.dataset.touched = '1');

async function startImport(mode, handles, deleteAfter) {
  if (deleteAfter) {
    const ok = await modal({
      title: 'Import, then delete from the glasses?',
      body: h('p', {}, 'Each item is deleted from the glasses only once its copy on the Mac is verified (checksum and size). Whatever fails stays on the glasses.'),
      actions: [{ label: 'Import and delete', class: 'danger' }],
    });
    if (!ok) return;
  }
  await post('/api/import', { mode, handles, deleteAfter });
}
$('#homeImport').addEventListener('click', () => startImport('missing', null, $('#homeDeleteAfter').checked));
$('#importMissingBtn').addEventListener('click', () => startImport('missing', null, $('#glDeleteAfter').checked));
$('#importSelBtn').addEventListener('click', () => startImport('selected', [...selected], $('#glDeleteAfter').checked));
$('#previewsBtn').addEventListener('click', () => post('/api/previews'));

$('#deleteSelBtn').addEventListener('click', async () => {
  const caps = (S.captures || []).filter(c => selected.has(c.handle));
  const notOnMac = caps.filter(c => !c.onMac);
  const box = h('div', {},
    h('p', {}, `Permanently delete ${caps.length} item(s) from the glasses. This cannot be undone.`),
    h('ul', {}, caps.map(c => h('li', {}, `${typeLabel(c.type)} from ${fmtDate(c.takenAt)} · ${c.sizeText}`, c.onMac ? h('span', { class: 'badge ok', style: 'margin-left:6px' }, 'copy on the Mac') : h('span', { class: 'badge danger', style: 'margin-left:6px' }, 'NOT on the Mac')))));
  let setOk = () => {};
  if (notOnMac.length) {
    const cb = h('input', { type: 'checkbox', onchange: e => setOk(e.target.checked) });
    box.append(h('p', { class: 'banner danger' }, `${notOnMac.length} item(s) are not on the Mac: they will be lost.`),
      h('label', { class: 'check' }, cb, ' I understand they will be lost'));
  }
  const ok = await modal({ title: 'Delete from the glasses?', body: box, actions: [{ label: 'Delete', class: 'danger', disabledUntil: notOnMac.length ? f => (setOk = f) : null }] });
  if (ok) { await post('/api/delete', { handles: caps.map(c => c.handle), confirm: true }); selected.clear(); }
});

// ---------- the Mac library

async function loadLibrary() {
  try { library = await api('GET', '/api/library'); } catch { return; }
  renderLibrary();
}
function renderLibrary() {
  if (!library) return;
  const items = library.items;
  const dupes = items.filter(i => i.duplicateOf);
  const total = items.reduce((a, i) => a + i.size, 0);
  $('#macSub').textContent = `${items.length} files · ${fmtBytes(total)} · ${library.dir}`;
  $('#navMac').textContent = items.filter(i => i.kind !== 'other' && !i.live).length || '';
  $('#homeMac').classList.remove('muted');
  $('#homeMac').innerHTML = '';
  $('#homeMac').append(h('span', { class: 'big' }, items.filter(i => i.kind !== 'other' && !i.live).length), ` photos and videos · ${fmtBytes(total)}`,
    dupes.length ? h('span', {}, h('br'), h('span', { class: 'badge warn' }, `${dupes.length} identical duplicate(s), ${fmtBytes(dupes.reduce((a, i) => a + i.size, 0))}`)) : '');
  $('#homeDupes').classList.toggle('hidden', !dupes.length);
  const banner = $('#dupeBanner');
  banner.classList.toggle('hidden', !dupes.length);
  banner.innerHTML = '';
  if (dupes.length) banner.append(h('span', {}, `${dupes.length} file(s) are byte-for-byte copies of another file (${fmtBytes(dupes.reduce((a, i) => a + i.size, 0))}).`),
    h('button', { class: 'small', onclick: trashDupes }, 'Move the duplicates to the Trash'));
  const grid = $('#macGrid'); grid.innerHTML = '';
  const shown = items.filter(i => macFilter === 'all' ? i.kind !== 'other' || true : i.kind === macFilter);
  for (const it of shown) {
    const media = it.kind === 'video' || it.kind === 'photo';
    grid.append(h('div', { class: 'tile', onclick: () => media && openViewer(it.name) },
      h('div', { class: 'thumb' }, media ? h('img', { src: '/api/thumb?name=' + encodeURIComponent(it.name), loading: 'lazy', alt: '', onerror: e => e.target.replaceWith(typeIcon(it.kind)) }) : '▤'),
      h('span', { class: 'kind' }, it.live ? 'Live clip' : (it.kind === 'video' ? 'Video' : it.kind === 'photo' ? 'Photo' : 'File')),
      h('div', { class: 'meta' },
        h('b', {}, fmtDate(it.date)),
        h('span', { class: 'muted', title: it.name }, it.sizeText + ' · ' + it.name.replace(/^Visor_/, '').slice(0, 28)),
        it.duplicateOf ? h('div', { class: 'badges' }, h('span', { class: 'badge warn', title: 'Copy of ' + it.duplicateOf }, 'duplicate')) : null),
      h('div', { class: 'actions' },
        h('button', { class: 'small ghost', title: 'Show in Finder', onclick: e => { e.stopPropagation(); post('/api/library/reveal', { name: it.name }); } }, 'Finder'),
        h('button', { class: 'small ghost danger', onclick: e => { e.stopPropagation(); trash([it.name]); } }, 'Trash'))));
  }
  $('#macEmpty').classList.toggle('hidden', items.length > 0);
}
$$('[data-filter]').forEach(b => b.addEventListener('click', () => {
  macFilter = b.dataset.filter; $$('[data-filter]').forEach(x => x.classList.toggle('on', x === b)); renderLibrary();
}));
async function trash(names, title) {
  const ok = await modal({ title: title || 'Move to the Trash?', body: h('div', {}, h('p', {}, "These files go to the Mac's Trash: you can still get them back from the Finder."), h('ul', {}, names.map(n => h('li', {}, n)))), actions: [{ label: 'Move to the Trash', class: 'danger' }] });
  if (!ok) return;
  await post('/api/library/trash', { names });
  await loadLibrary();
}
function trashDupes() { const d = library.items.filter(i => i.duplicateOf); trash(d.map(i => i.name), `Move ${d.length} duplicate(s) to the Trash?`); }
$('#homeDupes').addEventListener('click', trashDupes);
$('#macReload').addEventListener('click', loadLibrary);
$('#macOpenFolder').addEventListener('click', () => post('/api/library/reveal', {}));
$('#homeOpenFolder').addEventListener('click', () => post('/api/library/reveal', {}));

function openViewer(name) {
  if (!name) return;
  const body = $('#viewerBody'); body.innerHTML = '';
  const isVideo = /\.(mp4|mov|m4v)$/i.test(name);
  body.append(isVideo ? h('video', { src: '/media?name=' + encodeURIComponent(name), controls: true, autoplay: true, playsinline: true }) : h('img', { src: '/api/view?name=' + encodeURIComponent(name), alt: name }));
  $('#viewerName').textContent = name;
  $('#viewerDl').href = '/media?dl=1&name=' + encodeURIComponent(name);
  $('#viewerReveal').onclick = () => post('/api/library/reveal', { name });
  $('#viewer').classList.remove('hidden');
}
function closeViewer() { $('#viewerBody').innerHTML = ''; $('#viewer').classList.add('hidden'); }
$('#viewerClose').addEventListener('click', closeViewer);
document.addEventListener('keydown', e => { if (e.key === 'Escape') { closeViewer(); $('#modal').classList.add('hidden'); } });

// ---------- control and status

// The app names each status field; sizes read better in the page's own units.
function statusLabel(f) { return f.label || f.key; }
function statusValue(v) {
  const s = String(v);
  return ({ true: 'Yes', false: 'No' })[s] ?? s.replace(/^(\d+) MB$/, (_, n) => fmtBytes(Number(n) * 1e6));
}

function renderControl() {
  const f = S.extras?.features || {};
  const box = $('#shutterButtons'); 
  const actions = S.extras?.shutterActions || [];
  const key = JSON.stringify(actions) + f.shutter + S.conn + !!S.busy;
  if (box.dataset.key !== key) {
    box.dataset.key = key; box.innerHTML = '';
    if (!f.shutter) box.append(h('span', { class: 'muted' }, 'Not available in this version.'));
    for (const a of actions) box.append(h('button', { class: a.primary ? 'primary' : '', disabled: !!S.busy || !S.ownerKey, onclick: () => post('/api/shutter', { action: a.action }) }, a.label));
  }
  $('#clockBtn').disabled = !f.clock || !!S.busy || !S.ownerKey;
  $('#statusReadBtn').disabled = !f.status || !!S.busy || !S.ownerKey;
  const st = S.extras?.status;
  const tb = $('#statusTable tbody');
  if (st?.fields?.length) {
    tb.innerHTML = '';
    for (const fl of st.fields) tb.append(h('tr', {}, h('th', {}, statusLabel(fl)), h('td', {}, statusValue(fl.value))));
    if (st.at) tb.append(h('tr', {}, h('th', {}, 'Read'), h('td', { class: 'muted' }, fmtDate(st.at))));
  }
  const d = S.device;
  kv($('#controlDevice'), [['Model', d?.model], ['Serial', d?.serial || S.owner?.serial], ['Software', d?.build], ['Bluetooth', d?.bluetooth || S.owner?.address], ['Identifier', d?.uuid]]);
}
$('#clockBtn').addEventListener('click', () => post('/api/clock'));
$('#statusReadBtn').addEventListener('click', () => post('/api/status/read'));

// ---------- glasses settings

async function loadCatalog() {
  if (!S) return;  // the first state is not here yet: render() calls back once it is
  if (!S.extras?.features?.settings) { $('#settingsNote').textContent = 'The glasses settings are not available in this version.'; $('#settingsReadBtn').disabled = true; return; }
  if (!catalog) {
    if (catalogLoading) return;
    catalogLoading = true;
    try { catalog = await api('GET', '/api/settings/catalog'); } catch { return; } finally { catalogLoading = false; }
  }
  renderSettingsValues(true);
}
$('#settingsReadBtn').addEventListener('click', () => post('/api/settings/read'));

function renderSettingsValues(force) {
  if (!catalog || (tab !== 'settings' && !force)) return;
  const vals = S.extras?.settings?.values || {};
  const at = S.extras?.settings?.at;
  $('#settingsReadBtn').disabled = !!S.busy || !S.ownerKey;
  $('#settingsNote').textContent = at ? `Values read ${fmtDate(at)}. A change is sent to the glasses right away.` : 'Values not read yet: connect the glasses, then click “Read from the glasses”.';
  const box = $('#settingsBox');
  const key = JSON.stringify(vals) + !!S.busy + at;
  if (box.dataset.key === key && !force) return;
  box.dataset.key = key; box.innerHTML = '';
  const groups = {};
  for (const d of catalog) (groups[d.category || 'Other'] ||= []).push(d);
  for (const [cat, list] of Object.entries(groups)) {
    const g = h('div', { class: 'setting-group' }, h('h4', {}, cat));
    for (const d of list) g.append(settingRow(d, vals[d.key]));
    box.append(g);
  }
}

function settingRow(d, v) {
  const known = v !== undefined && v !== null;
  const can = d.writable && known && !S.busy && S.ownerKey;
  const send = value => post('/api/settings/write', { key: d.key, value });
  let ctl;
  if (d.kind === 'bool') {
    const input = h('input', { type: 'checkbox', disabled: !can, onchange: e => send(e.target.checked) });
    input.checked = v === true;
    ctl = h('label', { class: 'switch' }, input, h('span'));
  } else if (d.kind === 'enum') {
    const sel = h('select', { disabled: !can, onchange: e => { const o = d.options[e.target.selectedIndex - (known ? 0 : 1)]; if (o) send(o.value); } });
    if (!known) sel.append(h('option', {}, '—'));
    for (const o of d.options || []) { const op = h('option', {}, o.label); if (known && String(o.value) === String(v)) op.selected = true; sel.append(op); }
    ctl = sel;
  } else if (d.kind === 'int' || d.kind === 'double') {
    const out = h('span', { class: 'state' }, known ? `${v}${d.unit ? ' ' + d.unit : ''}` : '—');
    if (d.min != null && d.max != null) {
      const r = h('input', { type: 'range', min: d.min, max: d.max, step: d.step || 1, disabled: !can, oninput: e => out.textContent = e.target.value + (d.unit ? ' ' + d.unit : ''), onchange: e => send(Number(e.target.value)) });
      r.value = known ? v : d.min;
      ctl = h('span', {}, r, out);
    } else {
      const n = h('input', { type: 'number', disabled: !can, style: 'width:7em', onchange: e => send(Number(e.target.value)) }); n.value = known ? v : '';
      ctl = h('span', {}, n, d.unit ? h('span', { class: 'state' }, d.unit) : null);
    }
  } else {
    const t = h('input', { type: 'text', disabled: !can, onchange: e => send(e.target.value) }); t.value = known ? v : '';
    ctl = t;
  }
  return h('div', { class: 'setting' },
    h('div', {}, h('b', {}, d.label), !d.writable ? h('span', { class: 'badge', style: 'margin-left:6px' }, 'read-only') : null),
    h('div', { class: 'ctl' }, ctl),
    d.help ? h('div', { class: 'help' }, d.help) : h('div', { class: 'help' }));
}

// ---------- account

function renderAccount() {
  kv($('#accOwner'), [
    ['Owner key', S.ownerKey ? 'on this Mac' : 'missing'],
    ['Serial', S.owner?.serial], ['Paired', S.owner ? fmtDate(S.owner.pairedAt) : null], ['Address', S.owner?.address],
  ]);
  const l = S.login || {};
  kv($('#accLogin'), [
    ['App tokens', l.tokens ? 'present' : 'missing'],
    ['Meta login', l.frla ? 'saved' : 'missing'],
    ['Last check', l.check ? (l.check.ok ? '✓ ' : '✗ ') + fmtDate(l.check.at) + (l.check.ok ? '' : ' · ' + l.check.detail) : 'never'],
  ]);
  $('#checkLoginBtn').disabled = !!S.busy || !l.tokens || !l.frla;
  $('#pairBtn').disabled = !!S.busy || $('#pairConfirm').value.trim() !== 'PAIR';
}
$('#pairConfirm').addEventListener('input', () => S && renderAccount());
$('#checkLoginBtn').addEventListener('click', () => post('/api/check-login'));
$('#pairBtn').addEventListener('click', async () => {
  await post('/api/pair', { confirm: $('#pairConfirm').value.trim() });
  $('#pairConfirm').value = '';
});

// ---------- app preferences

let prefsShown = false;
function renderPrefs() {
  if (prefsShown && document.activeElement?.closest('#tab-settings .form')) return;
  const p = S.prefs;
  $('#pExport').value = p.exportDir || S.exportDir;
  $('#pCountry').value = p.country || '';
  $('#pPreviews').checked = !!p.autoPreviews;
  $('#pDeleteAfter').checked = !!p.deleteAfterImport;
  $('#pKeepLogs').checked = !!p.keepLogs;
  prefsShown = true;
}
$('#prefsSave').addEventListener('click', async () => {
  const exp = $('#pExport').value.trim();
  await post('/api/prefs', {
    exportDir: exp && exp !== S.exportDir ? exp : (S.prefs.exportDir || null),
    country: ($('#pCountry').value.trim() || S.prefs.country || 'US').toUpperCase(),
    autoPreviews: $('#pPreviews').checked, deleteAfterImport: $('#pDeleteAfter').checked, keepLogs: $('#pKeepLogs').checked,
  });
  toast('Settings saved');
  library = null; loadLibrary();
});

// ---------- log

function renderLog(full) {
  if (tab !== 'log') return;
  const box = $('#log');
  const debug = $('#logDebug').checked;
  const atBottom = box.scrollTop + box.clientHeight >= box.scrollHeight - 30;
  const line = l => h('div', { class: 'l ' + l.level }, h('span', { class: 't' }, new Date(l.at).toLocaleTimeString('en-GB')), h('span', {}, l.text));
  if (full) { box.innerHTML = ''; for (const l of logs) if (debug || l.level !== 'debug') box.append(line(l)); }
  else { const l = logs[logs.length - 1]; if (l && (debug || l.level !== 'debug')) box.append(line(l)); }
  if (atBottom || full) box.scrollTop = box.scrollHeight;
}
$('#logDebug').addEventListener('change', () => renderLog(true));
$('#logCopy').addEventListener('click', async () => {
  const text = logs.filter(l => $('#logDebug').checked || l.level !== 'debug').map(l => `${l.at} [${l.level}] ${l.text}`).join('\n');
  try { await navigator.clipboard.writeText(text); toast('Log copied'); } catch { toast('Could not copy', true); }
});

// ---------- top bar

$('#connectBtn').addEventListener('click', () => post('/api/connect'));
$('#refreshBtn').addEventListener('click', () => post('/api/refresh'));
$('#disconnectBtn').addEventListener('click', () => post('/api/disconnect'));
$('#cancelBtn').addEventListener('click', () => post('/api/cancel'));
$('#quitBtn').addEventListener('click', async () => {
  const ok = await modal({ title: 'Quit the app?', body: h('p', {}, 'This page stops working until you open “Glasses” again.'), actions: [{ label: 'Quit', class: 'danger' }] });
  if (ok) { await post('/api/quit'); $('#dead').classList.remove('hidden'); }
});

try { const t = localStorage.getItem('tab'); if (t && document.getElementById('tab-' + t)) tab = t; } catch {}
showTab(tab);
connect();
loadLibrary();
