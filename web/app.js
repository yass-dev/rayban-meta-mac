'use strict';
// Lunettes: the page talks to the menu bar app on 127.0.0.1. State arrives over Server-Sent Events.

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
  const u = ['o', 'Ko', 'Mo', 'Go', 'To']; let i = 0; let v = Number(n);
  while (v >= 1000 && i < u.length - 1) { v /= 1000; i++; }
  return (i === 0 ? v : v.toFixed(v < 10 ? 1 : 0)).toString().replace('.', ',') + ' ' + u[i];
}
function fmtDate(iso, withTime = true) {
  if (!iso) return 'date inconnue';
  const d = new Date(iso);
  return d.toLocaleDateString('fr-FR', { day: 'numeric', month: 'short', year: 'numeric' }) + (withTime ? ' · ' + d.toLocaleTimeString('fr-FR', { hour: '2-digit', minute: '2-digit' }) : '');
}
function fmtDur(s) {
  if (!isFinite(s) || s < 0) return '';
  s = Math.round(s);
  return s >= 60 ? `${Math.floor(s / 60)} min ${String(s % 60).padStart(2, '0')} s` : `${s} s`;
}
const typeLabel = t => ({ video: 'Vidéo', photo: 'Photo', live: 'Photo animée' }[t] || t);
const typeIcon = t => ({ video: '▶', photo: '◻', live: '◎' }[t] || '•');

async function api(method, path, body) {
  const opt = { method, headers: {} };
  if (method !== 'GET') { opt.headers['X-Visor'] = '1'; opt.headers['Content-Type'] = 'application/json'; opt.body = JSON.stringify(body || {}); }
  let res;
  try { res = await fetch(path, opt); } catch (e) { toast("L'application ne répond pas.", true); throw e; }
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
    a.append(h('button', { class: 'ghost', onclick: () => close(false) }, 'Annuler'));
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
  $('#connText').textContent = { connected: 'Connecté', connecting: 'Connexion…', disconnected: 'Déconnecté' }[S.conn];
  $('#connectBtn').classList.toggle('hidden', S.conn === 'connected');
  $('#connectBtn').disabled = !!busy || !S.ownerKey;
  $('#refreshBtn').disabled = !!busy || !S.ownerKey;
  $('#disconnectBtn').classList.toggle('hidden', S.conn !== 'connected');
  $('#disconnectBtn').disabled = !!busy;
  $('#brandSub').textContent = S.device?.model ? modelName(S.device.model) : (S.owner ? 'Série ' + S.owner.serial : 'Ray-Ban Meta');
  $('#offline').classList.toggle('hidden', !S.offline);
  const ce = $('#connErr');
  ce.classList.toggle('hidden', !S.connError || S.conn === 'connected' || !!busy);
  ce.textContent = S.connError ? 'Connexion : ' + S.connError : '';

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
      $('#busyNums').textContent = `${fmtBytes(busy.done)} sur ${fmtBytes(busy.total)} · ${pct.toFixed(0)} %` + (busy.rate ? ` · ${fmtBytes(busy.rate)}/s · encore ~${fmtDur(eta)}` : '');
    } else $('#busyNums').textContent = '';
  }

  if (S.lastResult && S.lastResult.at !== lastResultAt) {
    if (lastResultAt !== null) { toast(S.lastResult.text, !S.lastResult.ok); if (tab === 'mac' || /Import|corbeille/i.test(S.lastResult.text)) loadLibrary(); }
    lastResultAt = S.lastResult.at;
  }

  renderHome(); renderGlasses(); renderControl(); renderAccount(); renderPrefs();
  if (tab === 'settings' && !catalog) loadCatalog(); else renderSettingsValues();
}

const modelName = m => /266|gen ?2/i.test(m) ? 'Ray-Ban Meta (Gen 2)' : m;

function kv(el, pairs) {
  el.innerHTML = '';
  for (const [k, v] of pairs) { if (v == null || v === '') continue; el.append(h('dt', {}, k), h('dd', {}, v)); }
  if (!el.children.length) el.append(h('dt', {}, '—'), h('dd', { class: 'muted' }, 'Pas encore lu'));
}

function renderHome() {
  const d = S.device;
  kv($('#homeDevice'), [
    ['Modèle', d?.model ? modelName(d.model) : null], ['Série', d?.serial || S.owner?.serial], ['Logiciel', d?.build],
    ['Bluetooth', d?.bluetooth || S.owner?.address], ['Propriétaire', S.ownerKey ? (S.owner ? 'ce Mac, depuis le ' + fmtDate(S.owner.pairedAt, false) : 'ce Mac') : "pas encore : voir Compte"],
  ]);
  const st = S.extras?.status;
  if (st && st.fields?.length) {
    const want = ['batteryPercent', 'charging', 'caseBattery', 'worn', 'hinge', 'storageFree', 'recording'];
    const picked = want.map(k => st.fields.find(f => f.key === k)).filter(Boolean);
    kv($('#homeStatus'), (picked.length ? picked : st.fields.slice(0, 6)).map(f => [frLabel(f), frValue(f.value)]));
  }
  const caps = S.captures || [];
  const missing = caps.filter(c => !c.onMac);
  $('#homeGallery').innerHTML = '';
  if (S.capturesAt) {
    $('#homeGallery').classList.remove('muted');
    $('#homeGallery').append(h('span', { class: 'big' }, caps.length), ' sur les lunettes · ',
      h('b', {}, missing.length), ' pas encore sur le Mac' + (missing.length ? ` (${fmtBytes(missing.reduce((a, c) => a + c.size, 0))})` : ''));
  } else $('#homeGallery').textContent = S.ownerKey ? 'Connecte les lunettes pour voir leur galerie.' : "Ce Mac n'est pas encore propriétaire des lunettes.";
  $('#homeImport').disabled = !!S.busy || !S.ownerKey || (S.capturesAt && !missing.length);
  $('#homeDeleteAfter').checked = $('#homeDeleteAfter').dataset.touched ? $('#homeDeleteAfter').checked : S.prefs.deleteAfterImport;
  $('#navGlasses').textContent = S.capturesAt ? caps.length : '';
}

function renderGlasses() {
  const caps = S.captures || [];
  for (const hd of [...selected]) if (!caps.some(c => c.handle === hd)) selected.delete(hd);
  $('#glassesSub').textContent = S.capturesAt
    ? `${caps.length} éléments · liste lue le ${fmtDate(S.capturesAt)} · ${caps.filter(c => c.onMac).length} déjà sur le Mac`
    : 'Pas encore lue : connecte les lunettes.';
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
          h('span', { class: 'muted' }, c.sizeText + (c.landscape ? ' · paysage' : '')),
          h('div', { class: 'badges' },
            c.onMac ? h('span', { class: 'badge ok' }, 'Sur le Mac') : h('span', { class: 'badge warn' }, 'Pas sur le Mac'),
            c.delivered ? h('span', { class: 'badge', title: "Les lunettes l'ont déjà envoyé à un téléphone" }, 'envoyé au tél.') : null)),
        c.onMac ? h('div', { class: 'actions' }, h('button', { class: 'small', onclick: e => { e.stopPropagation(); openViewer(c.macFiles[0]); } }, 'Voir')) : null);
      grid.append(tile);
    }
  }
  const empty = $('#glassesEmpty');
  empty.classList.toggle('hidden', caps.length > 0);
  empty.textContent = S.capturesAt ? 'Aucune photo ni vidéo sur les lunettes.' : 'Connecte les lunettes pour voir leur galerie.';
  const sel = caps.filter(c => selected.has(c.handle));
  $('#selInfo').textContent = sel.length ? `${sel.length} sélectionné(s) · ${fmtBytes(sel.reduce((a, c) => a + c.size, 0))}` : '';
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
      title: 'Importer puis supprimer des lunettes ?',
      body: h('p', {}, "Chaque élément n'est supprimé des lunettes qu'une fois sa copie sur le Mac vérifiée (somme de contrôle et taille). Ce qui échoue reste sur les lunettes."),
      actions: [{ label: 'Importer et supprimer', class: 'danger' }],
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
    h('p', {}, `Supprimer définitivement ${caps.length} élément(s) des lunettes. Ce n'est pas réversible.`),
    h('ul', {}, caps.map(c => h('li', {}, `${typeLabel(c.type)} du ${fmtDate(c.takenAt)} · ${c.sizeText}`, c.onMac ? h('span', { class: 'badge ok', style: 'margin-left:6px' }, 'copie sur le Mac') : h('span', { class: 'badge danger', style: 'margin-left:6px' }, 'PAS sur le Mac')))));
  let setOk = () => {};
  if (notOnMac.length) {
    const cb = h('input', { type: 'checkbox', onchange: e => setOk(e.target.checked) });
    box.append(h('p', { class: 'banner danger' }, `${notOnMac.length} élément(s) ne sont pas sur le Mac : ils seront perdus.`),
      h('label', { class: 'check' }, cb, " Je comprends qu'ils seront perdus"));
  }
  const ok = await modal({ title: 'Supprimer des lunettes ?', body: box, actions: [{ label: 'Supprimer', class: 'danger', disabledUntil: notOnMac.length ? f => (setOk = f) : null }] });
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
  $('#macSub').textContent = `${items.length} fichiers · ${fmtBytes(total)} · ${library.dir}`;
  $('#navMac').textContent = items.filter(i => i.kind !== 'other' && !i.live).length || '';
  $('#homeMac').classList.remove('muted');
  $('#homeMac').innerHTML = '';
  $('#homeMac').append(h('span', { class: 'big' }, items.filter(i => i.kind !== 'other' && !i.live).length), ` photos et vidéos · ${fmtBytes(total)}`,
    dupes.length ? h('span', {}, h('br'), h('span', { class: 'badge warn' }, `${dupes.length} doublon(s) identique(s), ${fmtBytes(dupes.reduce((a, i) => a + i.size, 0))}`)) : '');
  $('#homeDupes').classList.toggle('hidden', !dupes.length);
  const banner = $('#dupeBanner');
  banner.classList.toggle('hidden', !dupes.length);
  banner.innerHTML = '';
  if (dupes.length) banner.append(h('span', {}, `${dupes.length} fichier(s) sont des copies exactes, octet par octet, d'un autre fichier (${fmtBytes(dupes.reduce((a, i) => a + i.size, 0))}).`),
    h('button', { class: 'small', onclick: trashDupes }, 'Mettre les doublons à la corbeille'));
  const grid = $('#macGrid'); grid.innerHTML = '';
  const shown = items.filter(i => macFilter === 'all' ? i.kind !== 'other' || true : i.kind === macFilter);
  for (const it of shown) {
    const media = it.kind === 'video' || it.kind === 'photo';
    grid.append(h('div', { class: 'tile', onclick: () => media && openViewer(it.name) },
      h('div', { class: 'thumb' }, media ? h('img', { src: '/api/thumb?name=' + encodeURIComponent(it.name), loading: 'lazy', alt: '', onerror: e => e.target.replaceWith(typeIcon(it.kind)) }) : '▤'),
      h('span', { class: 'kind' }, it.live ? 'Clip animé' : (it.kind === 'video' ? 'Vidéo' : it.kind === 'photo' ? 'Photo' : 'Fichier')),
      h('div', { class: 'meta' },
        h('b', {}, fmtDate(it.date)),
        h('span', { class: 'muted', title: it.name }, it.sizeText + ' · ' + it.name.replace(/^Visor_/, '').slice(0, 28)),
        it.duplicateOf ? h('div', { class: 'badges' }, h('span', { class: 'badge warn', title: 'Copie de ' + it.duplicateOf }, 'doublon')) : null),
      h('div', { class: 'actions' },
        h('button', { class: 'small ghost', title: 'Afficher dans le Finder', onclick: e => { e.stopPropagation(); post('/api/library/reveal', { name: it.name }); } }, 'Finder'),
        h('button', { class: 'small ghost danger', onclick: e => { e.stopPropagation(); trash([it.name]); } }, 'Corbeille'))));
  }
  $('#macEmpty').classList.toggle('hidden', items.length > 0);
}
$$('[data-filter]').forEach(b => b.addEventListener('click', () => {
  macFilter = b.dataset.filter; $$('[data-filter]').forEach(x => x.classList.toggle('on', x === b)); renderLibrary();
}));
async function trash(names, title) {
  const ok = await modal({ title: title || 'Mettre à la corbeille ?', body: h('div', {}, h('p', {}, 'Ces fichiers vont dans la Corbeille du Mac : tu peux encore les récupérer depuis le Finder.'), h('ul', {}, names.map(n => h('li', {}, n)))), actions: [{ label: 'Mettre à la corbeille', class: 'danger' }] });
  if (!ok) return;
  await post('/api/library/trash', { names });
  await loadLibrary();
}
function trashDupes() { const d = library.items.filter(i => i.duplicateOf); trash(d.map(i => i.name), `Mettre ${d.length} doublon(s) à la corbeille ?`); }
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

const FR = {
  model: 'Modèle', serial: 'Série', firmwareVersion: 'Version du logiciel', build: 'Build', deviceUuid: 'Identifiant', bluetoothAddress: 'Adresse Bluetooth',
  batteryPercent: 'Batterie', charging: 'En charge', chargeState: 'État de charge', batteryHealth: 'Santé de la batterie', batteryVoltage: 'Tension batterie',
  batteryTemperature: 'Température batterie', casePresent: 'Dans l’étui', caseBattery: 'Batterie de l’étui', caseCharging: 'Étui en charge',
  caseHealth: 'Santé batterie étui', caseSerial: 'Série de l’étui', caseFirmware: 'Logiciel de l’étui', casePlatform: 'Modèle d’étui',
  caseIncompatibleCharger: 'Chargeur incompatible', caseLiquidDetected: 'Liquide détecté dans l’étui', worn: 'Portées', mount: 'Position',
  hinge: 'Branches', overhead: 'Relevées sur la tête', camera: 'Caméra', recording: 'Enregistrement', cameraSensing: 'Détection caméra',
  storageFree: 'Stockage libre', storageTotal: 'Stockage total', storageLevel: 'Niveau de stockage', thermalHealth: 'État thermique',
  thermalThrottling: 'Bridage thermique', thermalThrottleReason: 'Raison du bridage', thermalTemperature: 'Température (brute)',
  peakPower: 'Pics de consommation', hotCar: 'Voiture trop chaude', waterDetect: 'Eau', deepSleepPending: 'Veille profonde imminente',
  inDeepSleep: 'En veille profonde', lockState: 'Verrouillage', sessionVerified: 'Session vérifiée', volume: 'Volume', volumeLevel: 'Niveau de volume',
  volumeStream: 'Flux audio', audioActive: 'Audio actif', streamingActive: 'Diffusion active', assistantAttention: 'Assistant',
  callState: 'Appel', callingState: 'État d’appel', callPlatform: 'App d’appel', callStart: 'Début d’appel', bluetoothAncs: 'Notifications (ANCS)',
  bluetoothMap: 'Messages (MAP)', bluetoothPbap: 'Contacts (PBAP)', bluetoothBtc: 'Bluetooth classique', captureButton: 'Bouton capture',
  actionButton: 'Bouton action', captouch: 'Pavé tactile',
};
function frLabel(f) { return FR[f.key] || f.label || f.key; }
function frValue(v) {
  const s = String(v);
  const map = { true: 'oui', yes: 'oui', Yes: 'oui', false: 'non', no: 'non', No: 'non', Open: 'ouvertes', Folded: 'repliées' };
  return map[s] ?? s.replace(/^(\d+) MB$/, (_, n) => fmtBytes(Number(n) * 1e6));
}

function renderControl() {
  const f = S.extras?.features || {};
  const box = $('#shutterButtons'); 
  const actions = S.extras?.shutterActions || [];
  const key = JSON.stringify(actions) + f.shutter + S.conn + !!S.busy;
  if (box.dataset.key !== key) {
    box.dataset.key = key; box.innerHTML = '';
    if (!f.shutter) box.append(h('span', { class: 'muted' }, "Pas disponible dans cette version."));
    for (const a of actions) box.append(h('button', { class: a.primary ? 'primary' : '', disabled: !!S.busy || !S.ownerKey, onclick: () => post('/api/shutter', { action: a.action }) }, a.label));
  }
  $('#clockBtn').disabled = !f.clock || !!S.busy || !S.ownerKey;
  $('#statusReadBtn').disabled = !f.status || !!S.busy || !S.ownerKey;
  const st = S.extras?.status;
  const tb = $('#statusTable tbody');
  if (st?.fields?.length) {
    tb.innerHTML = '';
    for (const fl of st.fields) tb.append(h('tr', {}, h('th', {}, frLabel(fl)), h('td', {}, frValue(fl.value))));
    if (st.at) tb.append(h('tr', {}, h('th', {}, 'Lu le'), h('td', { class: 'muted' }, fmtDate(st.at))));
  }
  const d = S.device;
  kv($('#controlDevice'), [['Modèle', d?.model], ['Série', d?.serial || S.owner?.serial], ['Logiciel', d?.build], ['Bluetooth', d?.bluetooth || S.owner?.address], ['Identifiant', d?.uuid]]);
}
$('#clockBtn').addEventListener('click', () => post('/api/clock'));
$('#statusReadBtn').addEventListener('click', () => post('/api/status/read'));

// ---------- glasses settings

async function loadCatalog() {
  if (!S) return;  // the first state is not here yet: render() calls back once it is
  if (!S.extras?.features?.settings) { $('#settingsNote').textContent = "Les réglages des lunettes ne sont pas disponibles dans cette version."; $('#settingsReadBtn').disabled = true; return; }
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
  $('#settingsNote').textContent = at ? `Valeurs lues le ${fmtDate(at)}. Une modification est envoyée aux lunettes tout de suite.` : 'Valeurs pas encore lues : connecte les lunettes puis « Lire depuis les lunettes ».';
  const box = $('#settingsBox');
  const key = JSON.stringify(vals) + !!S.busy + at;
  if (box.dataset.key === key && !force) return;
  box.dataset.key = key; box.innerHTML = '';
  const groups = {};
  for (const d of catalog) (groups[d.category || 'Autres'] ||= []).push(d);
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
    h('div', {}, h('b', {}, d.label), !d.writable ? h('span', { class: 'badge', style: 'margin-left:6px' }, 'lecture seule') : null),
    h('div', { class: 'ctl' }, ctl),
    d.help ? h('div', { class: 'help' }, d.help) : h('div', { class: 'help' }));
}

// ---------- account

function renderAccount() {
  kv($('#accOwner'), [
    ['Clé de propriétaire', S.ownerKey ? 'présente sur ce Mac' : 'absente'],
    ['Série', S.owner?.serial], ['Appairé le', S.owner ? fmtDate(S.owner.pairedAt) : null], ['Adresse', S.owner?.address],
  ]);
  const l = S.login || {};
  kv($('#accLogin'), [
    ["Jetons de l'app", l.tokens ? 'présents' : 'absents'],
    ['Connexion Meta', l.frla ? 'enregistrée' : 'absente'],
    ['Dernière vérification', l.check ? (l.check.ok ? '✓ ' : '✗ ') + fmtDate(l.check.at) + (l.check.ok ? '' : ' · ' + l.check.detail) : 'jamais'],
  ]);
  $('#checkLoginBtn').disabled = !!S.busy || !l.tokens || !l.frla;
  $('#pairBtn').disabled = !!S.busy || $('#pairConfirm').value.trim() !== 'APPAIRER';
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
  $('#pCountry').value = p.country || 'FR';
  $('#pPreviews').checked = !!p.autoPreviews;
  $('#pDeleteAfter').checked = !!p.deleteAfterImport;
  $('#pKeepLogs').checked = !!p.keepLogs;
  prefsShown = true;
}
$('#prefsSave').addEventListener('click', async () => {
  const exp = $('#pExport').value.trim();
  await post('/api/prefs', {
    exportDir: exp && exp !== S.exportDir ? exp : (S.prefs.exportDir || null),
    country: ($('#pCountry').value.trim() || 'FR').toUpperCase(),
    autoPreviews: $('#pPreviews').checked, deleteAfterImport: $('#pDeleteAfter').checked, keepLogs: $('#pKeepLogs').checked,
  });
  toast('Réglages enregistrés');
  library = null; loadLibrary();
});

// ---------- log

function renderLog(full) {
  if (tab !== 'log') return;
  const box = $('#log');
  const debug = $('#logDebug').checked;
  const atBottom = box.scrollTop + box.clientHeight >= box.scrollHeight - 30;
  const line = l => h('div', { class: 'l ' + l.level }, h('span', { class: 't' }, new Date(l.at).toLocaleTimeString('fr-FR')), h('span', {}, l.text));
  if (full) { box.innerHTML = ''; for (const l of logs) if (debug || l.level !== 'debug') box.append(line(l)); }
  else { const l = logs[logs.length - 1]; if (l && (debug || l.level !== 'debug')) box.append(line(l)); }
  if (atBottom || full) box.scrollTop = box.scrollHeight;
}
$('#logDebug').addEventListener('change', () => renderLog(true));
$('#logCopy').addEventListener('click', async () => {
  const text = logs.filter(l => $('#logDebug').checked || l.level !== 'debug').map(l => `${l.at} [${l.level}] ${l.text}`).join('\n');
  try { await navigator.clipboard.writeText(text); toast('Journal copié'); } catch { toast('Copie impossible', true); }
});

// ---------- top bar

$('#connectBtn').addEventListener('click', () => post('/api/connect'));
$('#refreshBtn').addEventListener('click', () => post('/api/refresh'));
$('#disconnectBtn').addEventListener('click', () => post('/api/disconnect'));
$('#cancelBtn').addEventListener('click', () => post('/api/cancel'));
$('#quitBtn').addEventListener('click', async () => {
  const ok = await modal({ title: "Quitter l'application ?", body: h('p', {}, "L'interface ne répondra plus jusqu'à la prochaine ouverture de « Lunettes »."), actions: [{ label: 'Quitter', class: 'danger' }] });
  if (ok) { await post('/api/quit'); $('#dead').classList.remove('hidden'); }
});

try { const t = localStorage.getItem('tab'); if (t && document.getElementById('tab-' + t)) tab = t; } catch {}
showTab(tab);
connect();
loadLibrary();
