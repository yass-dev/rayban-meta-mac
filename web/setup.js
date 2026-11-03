'use strict';
// The guided setup. The page draws the state the setup server derives from setup.sh, and sends the answers
// to its questions back. All the work is setup.sh's: this is only its face.

const $ = (s, el = document) => el.querySelector(s);
const $$ = (s, el = document) => [...el.querySelectorAll(s)];
const h = (tag, attrs = {}, ...kids) => {
  const el = document.createElement(tag);
  for (const [k, v] of Object.entries(attrs)) {
    if (v == null || v === false) continue;
    if (k === 'class') el.className = v;
    else if (k.startsWith('on')) el.addEventListener(k.slice(2), v);
    else el.setAttribute(k, v === true ? '' : v);
  }
  for (const kid of kids.flat()) if (kid != null && kid !== false) el.append(kid instanceof Node ? kid : String(kid));
  return el;
};

// ---------- words

const T = {
  title: 'Set up Ray-Ban Meta for Mac',
  subtitle: 'Your photos and videos, straight from the glasses to this Mac',
  dead: 'This page lost the setup. If you closed its Terminal window, double-click Install.command again.',
  intro: 'This page installs everything on this Mac and pairs your glasses with it. The first time takes about 30 minutes, mostly downloads. You can follow every step here, and the page tells you when it needs you.',
  needTitle: 'Before you start',
  need1: 'Your Ray-Ban Meta glasses, charged, and the Meta account they are set up with.',
  need2: 'About 12 GB of free disk space. You get most of it back at the end.',
  need3: 'Your phone nearby: you will turn its Bluetooth off for a minute.',
  unofficial: 'Unofficial: not made by Meta. Your Mac becomes the owner of the glasses, so the Meta AI app on your phone loses them until you set them up there again. This may be against Meta\'s terms of use.',
  start: 'Start the setup',
  alreadyTitle: 'This Mac is already set up',
  alreadyText: (s) => `This Mac owns your glasses${s ? ` (serial ${s})` : ''} and is logged in to Meta. Open Glasses to import and control them.`,
  partialText: 'A previous setup did not finish. Start it again: what is done is skipped.',
  openApp: 'Open Glasses',
  recheck: 'Check everything again',
  advanced: 'More options',
  relogin: 'Log in to Meta again',
  repair: 'Pair the glasses again',
  cleanupOnly: 'Free the space used by the Android tools',
  stop: 'Stop',
  details: 'Technical details',
  showLog: 'Show the log file in Finder',
  copy: 'Copy',
  copied: 'Copied',
  running: 'Setting up…',
  finished: 'Setup finished',
  stoppedTitle: 'Setup stopped',
  failedTitle: 'Setup stopped on an error',
  elapsed: (t) => `· ${t}`,
  steps: {
    mac: ['Checking this Mac', 'macOS version and Apple\'s developer tools.'],
    build: ['Building the app', 'Compiles the Mac app from its source code.'],
    tokens: ['Meta app tokens', 'Reads the identifiers the Meta AI app uses, from Visor\'s public release.'],
    login: ['Meta login', 'You log in to your Meta account, in an Android window.'],
    pair: ['Pairing the glasses', 'Your Mac becomes the owner of the glasses.'],
    app: ['Installing Glasses', 'The menu bar app you will use to import and control.'],
    cleanup: ['Cleaning up', 'Frees the space the Android tools took.'],
  },
  status: { pending: 'Waiting', running: 'In progress', done: 'Done', skipped: 'Already done', failed: 'Failed' },
  loginConsentTitle: 'Download the Android tools?',
  loginConsent: 'Meta gives its login only to its own Android login screen. To get it, the setup downloads Java and Google\'s Android tools (about 10 GB in all), builds Visor, an open-source app for these glasses, and opens it in an Android window where you log in. Allow 15 to 30 minutes. Continuing accepts the Android SDK licenses.',
  continue: 'Continue',
  notNow: 'Not now',
  loginWaitTitle: 'Your turn: log in to Meta',
  loginWait: 'An Android window has opened with the Visor app. Log in there with the Meta account your glasses use. Your password goes to Meta only: this page just waits for the result. Your Mac\'s keyboard works in that window.',
  waiting: (t) => `Waiting for you… ${t}`,
  pairConsentTitle: 'Make this Mac the owner of the glasses?',
  pairConsent: 'The glasses accept one owner. From now on it will be this Mac: the Meta AI app on your phone loses the glasses until you set them up there again, which takes them back. This is not an official Meta feature.',
  pairYes: 'Yes, pair them',
  pairReadyTitle: 'Get the glasses ready',
  pair1: 'Turn Bluetooth off on your phone.',
  pair2: 'Take the glasses out of the case and open the arms, next to the Mac.',
  pair3: 'Hold the capture button until the light blinks blue: that is pairing mode.',
  pair4: 'On the Mac, accept what macOS asks: let Terminal use Bluetooth, then click Connect.',
  pairRetry: 'That did not work. Put the glasses back in pairing mode, then try again.',
  pairGo: 'The light is blinking blue: pair now',
  pairingNow: 'Pairing… Keep the glasses next to the Mac, and click Connect if macOS asks.',
  cleanupTitle: (gb) => `Free ${gb}?`,
  cleanupText: 'The Android tools were only needed for the Meta login. Remove them now? If you ever need to log in again, the setup downloads them again.',
  remove: 'Remove',
  keep: 'Keep',
  doneText: (dir) => `Glasses is in your menu bar: the glasses icon. Your photos and videos will go to ${dir}.`,
  doneNoDir: 'Glasses is in your menu bar: the glasses icon.',
  openingApp: 'Opening Glasses…',
  failedHint: 'Fix what the message says, then try again: the steps already done are skipped.',
  stoppedHint: 'Nothing is lost: start again and the setup continues where it stopped.',
  retry: 'Try again',
  resume: 'Continue the setup',
  stopConfirmTitle: 'Stop the setup?',
  stopConfirm: 'The current step stops. You can continue later: what is done is kept.',
  cancel: 'Cancel',
};

const t = (k, ...a) => { const v = T[k]; return typeof v === 'function' ? v(...a) : v; };
const fillWords = () => $$('[data-t]').forEach(el => { el.textContent = t(el.dataset.t); });

// ---------- helpers

let S = null;
const fmt = (s) => { s = Math.max(0, Math.round(s)); return s >= 60 ? `${Math.floor(s / 60)} min ${String(s % 60).padStart(2, '0')} s` : `${s} s`; };

async function post(path, body) {
  const res = await fetch(path, { method: 'POST', headers: { 'X-Visor': '1', 'Content-Type': 'application/json' }, body: JSON.stringify(body || {}) });
  if (!res.ok) { let m = res.statusText; try { m = (await res.json()).error || m; } catch {} throw new Error(m); }
  return res.json().catch(() => ({}));
}

function modal(title, body, actions) {
  return new Promise(resolve => {
    $('#modalTitle').textContent = title;
    $('#modalBody').textContent = body;
    const a = $('#modalActions'); a.innerHTML = '';
    const close = v => { $('#modal').classList.add('hidden'); resolve(v); };
    a.append(h('button', { class: 'ghost', onclick: () => close(false) }, t('cancel')));
    for (const act of actions) a.append(h('button', { class: act.class || 'primary', onclick: () => close(true) }, act.label));
    $('#modal').classList.remove('hidden');
  });
}

const answer = (key, value) => post('/api/setup/answer', { key, value }).catch(e => alertLine(e.message));
const start = (opts) => post('/api/setup/start', opts || {}).catch(e => alertLine(e.message));
function alertLine(msg) { console.log('[setup]', msg); }

// ---------- live state

let clockStart = null;
function connect() {
  const es = new EventSource('/api/setup/events');
  es.addEventListener('state', e => { $('#dead').classList.add('hidden'); S = JSON.parse(e.data); render(); });
  es.onerror = () => setTimeout(async () => {
    try { await fetch('/api/setup/state'); } catch { $('#dead').classList.remove('hidden'); }
  }, 2500);
}
setInterval(() => { if (S && S.phase === 'running') renderClock(); }, 1000);

function renderClock() {
  if (!S?.startedAt) return;
  $('#runElapsed').textContent = t('elapsed', fmt((Date.now() - new Date(S.startedAt)) / 1000));
}

// ---------- drawing

function render() {
  if (!S) return;
  const idle = S.phase === 'idle';
  const ex = S.existing;
  const setUp = ex.paired && ex.login && ex.app;
  $('#welcome').classList.toggle('hidden', !idle || setUp);
  $('#already').classList.toggle('hidden', !idle || !setUp);
  $('#run').classList.toggle('hidden', idle);
  if (idle && setUp) $('#alreadyText').textContent = t('alreadyText', ex.serial);
  if (idle) return;

  $('#runTitle').textContent = S.phase === 'running' ? t('running') : S.phase === 'done' ? t('finished') : S.phase === 'stopped' ? t('stoppedTitle') : t('failedTitle');
  $('#stopBtn').classList.toggle('hidden', S.phase !== 'running');
  renderClock();
  renderResult();

  const list = $('#steps');
  list.innerHTML = '';
  for (const st of S.steps) list.append(stepCard(st));
  if ($('#detailsBox').open) loadDetails();
  // Bring the step that needs attention into view when it changes, or when it starts asking something.
  const focus = `${S.current}|${S.prompt?.key || ''}|${S.action || ''}|${S.phase}`;
  if (focus !== lastFocus) {
    lastFocus = focus;
    const el = S.phase === 'running' ? $('.step.running') : $('#result');
    el?.scrollIntoView({ behavior: 'smooth', block: S.phase === 'running' ? 'center' : 'start' });
  }
}
let lastFocus = '';

function stepCard(st) {
  const [title, desc] = (T.steps[st.key] || [st.title, '']);
  const icon = { done: '✓', skipped: '✓', failed: '✗', running: '', pending: String(S.steps.indexOf(st) + 1) }[st.status];
  const card = h('li', { class: `step ${st.status}` },
    h('div', { class: 'step-head' },
      h('span', { class: 'step-icon' }, icon),
      h('div', {}, h('div', { class: 'step-title' }, title), h('div', { class: 'step-desc' }, desc)),
      h('span', { class: 'step-state' }, t('status')[st.status] || st.status)));
  const live = st.key === S.current && S.phase === 'running';
  // A finished step is one line: its title and its state. The rest is in the technical details.
  if (!live && st.status !== 'failed') return card;
  const body = h('div', { class: 'step-body' });
  // The running step shows its progress; a failed one, what went wrong. The cards explain the rest.
  const retrying = S.prompt?.key === 'pairing-ready';
  const shown = st.status === 'failed'
    ? st.lines.filter(l => l.kind !== 'info' && l.kind !== 'skip')
    : st.lines.filter(l => l.kind === 'ok' || (!retrying && (l.kind === 'warn' || l.kind === 'error')));
  const keep = st.status === 'failed' ? shown.slice(-30) : shown.slice(-6);
  if (keep.length) body.append(h('div', { class: 'step-lines' }, keep.map(l => h('div', { class: 'l-' + l.kind }, l.text))));
  if (live) {
    const card2 = youCard(st);
    if (card2) body.append(card2);
    if (S.activity && !S.prompt && S.action !== 'login-wait') {
      body.append(h('div', { class: 'activity' },
        h('span', { class: 'what' }, `${S.activity.what} · ${fmt(S.activity.secs)}`),
        S.activity.detail ? h('span', { class: 'detail', title: S.activity.detail }, S.activity.detail) : null));
    }
  }
  if (body.children.length) card.append(body);
  return card;
}

/// What the person has to do now: a question, an instruction, or both.
function youCard(st) {
  const p = S.prompt;
  const btns = (...b) => h('div', { class: 'row' }, b);
  if (p && p.key === 'login-consent') {
    return h('div', { class: 'you' }, h('h4', {}, t('loginConsentTitle')), h('p', {}, t('loginConsent')),
      btns(h('button', { class: 'primary', onclick: () => answer(p.key, 'yes') }, t('continue')), h('button', { onclick: () => answer(p.key, 'no') }, t('notNow'))));
  }
  if (p && p.key === 'pair-consent') {
    return h('div', { class: 'you warning' }, h('h4', {}, t('pairConsentTitle')), h('p', {}, t('pairConsent')),
      btns(h('button', { class: 'primary', onclick: () => answer(p.key, 'yes') }, t('pairYes')), h('button', { onclick: () => answer(p.key, 'no') }, t('notNow'))));
  }
  if (p && p.key === 'pairing-ready') {
    const retry = st.lines.some(l => l.kind === 'error');
    return h('div', { class: 'you' }, h('h4', {}, t('pairReadyTitle')),
      retry ? h('p', { class: 'l-warn' }, t('pairRetry')) : null,
      h('ol', {}, h('li', {}, t('pair1')), h('li', {}, t('pair2')), h('li', {}, t('pair3')), h('li', {}, t('pair4'))),
      btns(h('button', { class: 'primary', onclick: () => answer(p.key, 'go') }, t('pairGo'))));
  }
  if (p && p.key === 'cleanup') {
    const gb = (p.text.match(/\(([\d.,]+ GB)\)/) || [])[1] || '';
    return h('div', { class: 'you' }, h('h4', {}, t('cleanupTitle', gb)), h('p', {}, t('cleanupText')),
      btns(h('button', { class: 'primary', onclick: () => answer(p.key, 'yes') }, t('remove')), h('button', { onclick: () => answer(p.key, 'no') }, t('keep'))));
  }
  if (p) {
    // A question this page has no words for: the script's own.
    return h('div', { class: 'you' }, h('p', {}, p.text),
      p.kind === 'ask'
        ? btns(h('button', { class: 'primary', onclick: () => answer(p.key, 'yes') }, t('continue')), h('button', { onclick: () => answer(p.key, 'no') }, t('notNow')))
        : btns(h('button', { class: 'primary', onclick: () => answer(p.key, 'go') }, t('continue'))));
  }
  if (S.action === 'login-wait') {
    return h('div', { class: 'you' }, h('h4', {}, t('loginWaitTitle')), h('p', {}, t('loginWait')),
      S.activity ? h('div', { class: 'waiting' }, t('waiting', fmt(S.activity.secs))) : null);
  }
  if (S.action === 'pairing-help' && S.activity) {
    return h('div', { class: 'you' }, h('p', {}, t('pairingNow')));
  }
  return null;
}

function renderResult() {
  const box = $('#result');
  box.innerHTML = '';
  box.className = 'hidden';
  if (S.phase === 'running') return;
  box.className = 'result ' + S.phase;
  if (S.phase === 'done') {
    box.append(h('h2', {}, '✓ ' + t('finished')),
      h('p', {}, S.exportDir ? t('doneText', S.exportDir) : t('doneNoDir')),
      h('div', { class: 'row' }, h('button', { class: 'primary big-btn', onclick: openApp }, t('openApp'))));
  } else if (S.phase === 'stopped') {
    box.append(h('h2', {}, t('stoppedTitle')), S.failure && S.failure !== 'Stopped.' ? h('p', {}, h('b', {}, S.failure)) : null, h('p', {}, t('stoppedHint')),
      h('div', { class: 'row' }, h('button', { class: 'primary', onclick: () => start() }, t('resume'))));
  } else {
    box.append(h('h2', {}, t('failedTitle')), h('p', {}, h('b', {}, S.failure || '')), h('p', {}, t('failedHint')),
      h('div', { class: 'row' },
        h('button', { class: 'primary', onclick: () => start() }, t('retry')),
        h('button', { class: 'ghost', onclick: () => post('/api/setup/log') }, t('showLog'))));
  }
}

// ---------- the end: hand over to Glasses

async function openApp(e) {
  const btn = e?.target;
  if (btn) { btn.disabled = true; btn.textContent = t('openingApp'); }
  // Glasses answers on its own port once started; the setup server then leaves.
  for (let i = 0; i < 60; i++) {
    try {
      await fetch('http://127.0.0.1:47392/api/state', { mode: 'no-cors', cache: 'no-store' });
      post('/api/setup/quit').catch(() => {});
      location.href = 'http://127.0.0.1:47392/';
      return;
    } catch {}
    if (i === 0) post('/api/setup/open-app').catch(() => {});
    await new Promise(r => setTimeout(r, 1000));
  }
  if (btn) { btn.disabled = false; btn.textContent = t('openApp'); }
}

// ---------- details

async function loadDetails() {
  try {
    const lines = await (await fetch('/api/setup/details')).json();
    const pre = $('#details');
    const atBottom = pre.scrollTop + pre.clientHeight >= pre.scrollHeight - 20;
    pre.textContent = lines.join('\n');
    if (atBottom) pre.scrollTop = pre.scrollHeight;
  } catch {}
}
$('#detailsBox').addEventListener('toggle', () => { if ($('#detailsBox').open) loadDetails(); });
setInterval(() => { if ($('#detailsBox').open && S?.phase === 'running') loadDetails(); }, 3000);
$('#logBtn').addEventListener('click', () => post('/api/setup/log'));
$('#copyBtn').addEventListener('click', async () => {
  try { await navigator.clipboard.writeText($('#details').textContent); $('#copyBtn').textContent = t('copied'); setTimeout(() => $('#copyBtn').textContent = t('copy'), 1500); } catch {}
});

// ---------- buttons

$('#startBtn').addEventListener('click', () => start());
$('#recheckBtn').addEventListener('click', () => start());
$('#reloginBtn').addEventListener('click', () => start({ relogin: true }));
$('#repairBtn').addEventListener('click', () => start({ repair: true }));
$('#cleanupBtn').addEventListener('click', () => start({ cleanup: true }));
$('#openAppBtn2').addEventListener('click', openApp);
$('#stopBtn').addEventListener('click', async () => {
  if (await modal(t('stopConfirmTitle'), t('stopConfirm'), [{ label: t('stop'), class: 'danger' }])) post('/api/setup/stop').catch(() => {});
});
document.addEventListener('keydown', e => { if (e.key === 'Escape') $('#modal').classList.add('hidden'); });

fillWords();
connect();
