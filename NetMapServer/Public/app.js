'use strict';

const WEB_VERSION = '1.0.23';

// ─── Auth state ────────────────────────────────────────────────────────────────────────────────
const AUTH = { token: null, username: null, role: null,
  get isAdmin() { return this.role === 'admin'; } };

function normalizeRole(role) {
  return role === 'admin' ? 'admin' : 'user';
}

function saveAuth(data) {
  AUTH.token = null; // Browser UI uses HttpOnly session cookie, not JS-readable tokens.
  AUTH.username = data.username;
  AUTH.role = data.role;
  sessionStorage.setItem('netmap-auth', JSON.stringify({ username: AUTH.username, role: AUTH.role }));
}
function clearAuth() {
  AUTH.token = null; AUTH.username = null; AUTH.role = null;
  sessionStorage.removeItem('netmap-auth');
}
function applyAuthUI() {
  const badge  = $('user-badge');
  const addBtn = $('add-vehicle-btn');
  const adminBtn = $('admin-btn');
  if (AUTH.username) {
    $('user-name').textContent = AUTH.username;
    const roleEl = $('user-role');
    const roleSafe = normalizeRole(AUTH.role);
    roleEl.textContent = roleSafe;
    roleEl.className   = `role-badge ${roleSafe}`;
    badge.style.display = 'flex';
    if (addBtn)   addBtn.style.display   = AUTH.isAdmin ? '' : 'none';
    if (adminBtn) adminBtn.style.display = AUTH.isAdmin ? '' : 'none';
    const logsBtn = $('logs-btn');
    if (logsBtn) logsBtn.style.display = AUTH.isAdmin ? '' : 'none';
  } else {
    badge.style.display = 'none';
    if (addBtn)   addBtn.style.display   = 'none';
    if (adminBtn) adminBtn.style.display = 'none';
    const logsBtn = $('logs-btn');
    if (logsBtn) logsBtn.style.display = 'none';
  }
}

// Auth overlay helpers
let _authResolve = null;
function waitForAuth() { return new Promise(r => { _authResolve = r; }); }
function resolveAuth() { if (_authResolve) { _authResolve(); _authResolve = null; } }

function showAuthOverlay(mode) {
  $('auth-overlay').dataset.mode = mode;
  $('auth-title').textContent     = mode === 'setup' ? 'Create Admin Account' : 'Sign in to NetMap';
  $('auth-subtitle').textContent  = mode === 'setup' ? 'First-run setup: choose your admin credentials.' : '';
  $('auth-submit-btn').textContent = mode === 'setup' ? 'Create Account' : 'Sign in';
  $('auth-error').style.display   = 'none';
  $('auth-overlay').style.display = 'flex';
}

async function checkAuth() {
  const statusData = await fetch('/api/auth/status').then(r => r.json());
  if (statusData.needsSetup) { showAuthOverlay('setup'); await waitForAuth(); return; }
  try {
    const me = await fetch('/api/auth/me');
    if (me.ok) {
      const d = await me.json();
      saveAuth({ username: d.email, role: d.role });
      applyAuthUI();
      return;
    }
  } catch {}
  clearAuth();
  showAuthOverlay('login'); await waitForAuth();
}

// ─── Vehicle / Asset modal ────────────────────────────────────────────────────
let _editingVehicleID = null;

function isVehicleType(typeID) {
  const t = S.assetTypes.find(x => x.id === typeID);
  return !t || t.name.toLowerCase() === 'vehicle' || typeID === 'vehicle';
}

function updateModalFields(typeID) {
  const isVeh = isVehicleType(typeID);
  $('vf-vehicle-fields').style.display = isVeh ? '' : 'none';
  $('vf-tool-fields').style.display    = isVeh ? 'none' : '';
}

function openVehicleModal(vehicle = null) {
  _editingVehicleID = vehicle?.id ?? null;
  $('modal-title').textContent = vehicle ? 'Edit Asset' : 'New Asset';

  // Populate type selector
  const currentTypeID = vehicle?.assetTypeID ?? 'vehicle';
  const sel = $('vf-type');
  if (S.assetTypes.length) {
    sel.innerHTML = S.assetTypes.map(t =>
      `<option value="${escAttr(t.id)}"${t.id === currentTypeID ? ' selected' : ''}>${escHTML(t.name)}</option>`
    ).join('');
    // Fallback: if no exact match, select by name
    if (!S.assetTypes.find(t => t.id === currentTypeID)) {
      const byName = S.assetTypes.find(t => t.name.toLowerCase() === currentTypeID.toLowerCase());
      if (byName) sel.value = byName.id;
    }
  }
  // Always show type selector (admins can change the type)
  $('vf-type-row').style.display = '';
  updateModalFields(sel.value || currentTypeID);

  // Populate fields
  $('vf-name').value       = vehicle?.name         ?? '';
  $('vf-brand').value      = vehicle?.brand        ?? '';
  $('vf-model').value      = vehicle?.modelName    ?? '';
  $('vf-year').value       = vehicle?.year         ?? '';
  $('vf-vrn').value        = vehicle?.vrn          ?? '';
  $('vf-vin').value        = vehicle?.vin          ?? '';
  $('vf-serial').value     = vehicle?.serialNumber ?? '';
  $('vf-tool-type').value  = vehicle?.toolType     ?? '';
  $('vf-icon-key').value   = vehicle?.iconKey      ?? '';
  renderPictoGrid(vehicle?.iconKey ?? null);

  $('modal-delete-btn').style.display = vehicle ? '' : 'none';
  $('modal-error').style.display = 'none';
  $('vehicle-modal').style.display = 'flex';
}
function closeVehicleModal() {
  $('vehicle-modal').style.display = 'none';
  _editingVehicleID = null;
}

async function saveVehicle(payload) {
  const headers = { 'Content-Type': 'application/json', ...authHeaders() };
  const url     = _editingVehicleID ? `/api/vehicles/${_editingVehicleID}` : '/api/vehicles';
  const method  = _editingVehicleID ? 'PATCH' : 'POST';
  const res     = await fetch(url, { method, headers, body: JSON.stringify(payload) });
  if (!res.ok) { const e = await res.json().catch(() => ({})); throw new Error(e.reason || `HTTP ${res.status}`); }
  return res.status === 200 || res.status === 201 ? res.json() : null;
}
async function deleteVehicle(id) {
  const res = await fetch(`/api/vehicles/${id}`, { method: 'DELETE', headers: authHeaders() });
  if (!res.ok) { const e = await res.json().catch(() => ({})); throw new Error(e.reason || `HTTP ${res.status}`); }
}

async function loadServerVehicles() {
  try { S.serverVehicles = await apiFetch('/api/vehicles'); } catch { S.serverVehicles = []; }
}
async function loadAssetTypes() {
  try { S.assetTypes = await apiFetch('/api/asset-types'); } catch { S.assetTypes = []; }
}

// ─── Constants ────────────────────────────────────────────────────────────────
const REFRESH_MS     = 30_000;
const WS_RECONNECT_MS = 5_000;   // WebSocket reconnect delay after unexpected close
const HOURS = { '1H': 1, '24H': 24, '7D': 168, '30D': 720 };
const WHEEL_LABELS  = { FL: 'Front Left', FR: 'Front Right', RL: 'Rear Left', RR: 'Rear Right' };
const BRAND_LABELS  = { michelin: 'Michelin TMS', stihl: 'STIHL', ela: 'ELA Innovation', airtag: 'AirTag', tracker: 'GPS Tracker' };
const GPS_FIX_LABELS = {
  0: { icon: '–',  label: 'No fix',   color: '#6b7280' },
  2: { icon: '○',  label: '2D',       color: '#fbbf24' },
  3: { icon: '●',  label: '3D',       color: '#34d399' },
  4: { icon: '●',  label: 'GNSS+DR', color: '#60a5fa' },
};
function gpsFixBadge(fixType) {
  const f = fixType != null
    ? (GPS_FIX_LABELS[fixType] ?? { icon: '?', label: String(fixType), color: 'var(--fg2)' })
    : { icon: '–', label: 'No fix', color: '#6b7280' };
  const c = safeCssColor(f.color) || 'var(--fg2)';
  return `<span class="ev-badge" style="--ev-color:${c};font-size:10px">${escHTML(f.icon)} ${escHTML(f.label)}</span>`;
}
function gpsCell(e) {
  const badge = gpsFixBadge(e.gpsFixType);
  const href = osmHref(e.latitude, e.longitude);
  const link  = href
    ? `<a href="${href}" target="_blank" rel="noopener noreferrer" style="color:var(--m-blue);font-size:2em;line-height:1">⌖</a> `
    : '';
  return link + badge;
}
const PRODUCT_VARIANT_LABELS = { coin: 'ELA Blue Coin', puck: 'ELA Blue Puck', unknown: 'ELA Beacon' };

// ─── Pictogram icon library (Tabler Icons — tabler.io) ──────────────────────
const _SVG = (inner) => `<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">${inner}</svg>`;
const PICTO_ICONS = {
  car:       _SVG(`<path d="M5 17a2 2 0 1 0 4 0a2 2 0 1 0 -4 0"/><path d="M15 17a2 2 0 1 0 4 0a2 2 0 1 0 -4 0"/><path d="M5 17h-2v-6l2 -5h9l4 5h1a2 2 0 0 1 2 2v4h-2m-4 0h-6m-6 -6h15m-6 0v-5"/>`),
  suv:       _SVG(`<path d="M5 17a2 2 0 1 0 4 0a2 2 0 0 0 -4 0"/><path d="M16 17a2 2 0 1 0 4 0a2 2 0 0 0 -4 0"/><path d="M5 9l2 -4h7.438a2 2 0 0 1 1.94 1.515l.622 2.485h3a2 2 0 0 1 2 2v3"/><path d="M10 9v-4"/><path d="M2 7v4"/><path d="M22.001 14.001a4.992 4.992 0 0 0 -4.001 -2.001a4.992 4.992 0 0 0 -4 2h-3a4.998 4.998 0 0 0 -8.003 .003"/><path d="M5 12v-3h13"/>`),
  pickup:    _SVG(`<path d="M5 17a2 2 0 1 0 4 0a2 2 0 1 0 -4 0"/><path d="M15 17a2 2 0 1 0 4 0a2 2 0 1 0 -4 0"/><path d="M5 17h-2v-11a1 1 0 0 1 1 -1h9v12m-4 0h6m4 0h2v-6h-8m0 -5h5l3 5"/>`),
  van:       _SVG(`<path d="M5 17a2 2 0 1 0 4 0a2 2 0 1 0 -4 0"/><path d="M15 17a2 2 0 1 0 4 0a2 2 0 1 0 -4 0"/><path d="M5 17h-2v-4m-1 -8h11v12m-4 0h6m4 0h2v-6h-8m0 -5h5l3 5"/><path d="M3 9l4 0"/>`),
  lcv:       _SVG(`<path d="M5 17a2 2 0 1 0 4 0a2 2 0 1 0 -4 0"/><path d="M15 17a2 2 0 1 0 4 0a2 2 0 1 0 -4 0"/><path d="M5 17h-2v-4m-1 -8h11v12m-4 0h6m4 0h2v-6h-8m0 -5h5l3 5"/><path d="M3 9l4 0"/><path d="M10 5v4"/>`),
  hgv:       _SVG(`<path d="M5 17a2 2 0 1 0 4 0a2 2 0 1 0 -4 0"/><path d="M15 17a2 2 0 1 0 4 0a2 2 0 1 0 -4 0"/><path d="M5 17h-2v-11a1 1 0 0 1 1 -1h9v12m-4 0h6m4 0h2v-6h-8m0 -5h5l3 5"/><path d="M12 7h4"/>`),
  trailer:   _SVG(`<path d="M7 18a2 2 0 1 0 4 0a2 2 0 0 0 -4 0"/><path d="M11 18h7a2 2 0 0 0 2 -2v-7a2 2 0 0 0 -2 -2h-9.5a5.5 5.5 0 0 0 -5.5 5.5v3.5a2 2 0 0 0 2 2h2"/><path d="M8 7l7 -3l1 3"/><path d="M13 11.5a.5 .5 0 0 1 .5 -.5h2a.5 .5 0 0 1 .5 .5v2a.5 .5 0 0 1 -.5 .5h-2a.5 .5 0 0 1 -.5 -.5l0 -2"/><path d="M20 16h2"/>`),
  bus:       _SVG(`<path d="M4 17a2 2 0 1 0 4 0a2 2 0 1 0 -4 0"/><path d="M16 17a2 2 0 1 0 4 0a2 2 0 1 0 -4 0"/><path d="M4 17h-2v-11a1 1 0 0 1 1 -1h14a5 7 0 0 1 5 7v5h-2m-4 0h-8"/><path d="M16 5l1.5 7l4.5 0"/><path d="M2 10l15 0"/><path d="M7 5l0 5"/><path d="M12 5l0 5"/>`),
  motorbike: _SVG(`<path d="M2 16a3 3 0 1 0 6 0a3 3 0 1 0 -6 0"/><path d="M16 16a3 3 0 1 0 6 0a3 3 0 1 0 -6 0"/><path d="M7.5 14h5l4 -4h-10.5m1.5 4l4 -4"/><path d="M13 6h2l1.5 3l2 4"/>`),
  scooter:   _SVG(`<path d="M16 17a2 2 0 1 0 4 0a2 2 0 1 0 -4 0"/><path d="M4 17a2 2 0 1 0 4 0a2 2 0 1 0 -4 0"/><path d="M8 17h5a6 6 0 0 1 5 -5v-5a2 2 0 0 0 -2 -2h-1"/>`),
  bike:      _SVG(`<path d="M2 18a3 3 0 1 0 6 0a3 3 0 1 0 -6 0"/><path d="M16 18a3 3 0 1 0 6 0a3 3 0 1 0 -6 0"/><path d="M12 19l0 -4l-3 -3l5 -4l2 3l3 0"/><path d="M16 5a1 1 0 1 0 2 0a1 1 0 1 0 -2 0"/>`),
  atv:       _SVG(`<path d="M5 5a2 2 0 0 1 2 -2a2 2 0 0 1 2 2v2a2 2 0 0 1 -2 2a2 2 0 0 1 -2 -2l0 -2"/><path d="M5 17a2 2 0 0 1 2 -2a2 2 0 0 1 2 2v2a2 2 0 0 1 -2 2a2 2 0 0 1 -2 -2l0 -2"/><path d="M15 5a2 2 0 0 1 2 -2a2 2 0 0 1 2 2v2a2 2 0 0 1 -2 2a2 2 0 0 1 -2 -2l0 -2"/><path d="M15 17a2 2 0 0 1 2 -2a2 2 0 0 1 2 2v2a2 2 0 0 1 -2 2a2 2 0 0 1 -2 -2l0 -2"/><path d="M9 18h6"/><path d="M9 6h6"/><path d="M12 6.5v-.5v12"/>`),
  tractor:   _SVG(`<path d="M3 15a4 4 0 1 0 8 0a4 4 0 1 0 -8 0"/><path d="M7 15l0 .01"/><path d="M17 17a2 2 0 1 0 4 0a2 2 0 1 0 -4 0"/><path d="M10.5 17l6.5 0"/><path d="M20 15.2v-4.2a1 1 0 0 0 -1 -1h-6l-2 -5h-6v6.5"/><path d="M18 5h-1a1 1 0 0 0 -1 1v4"/>`),
  boat:      _SVG(`<path d="M2 20a2.4 2.4 0 0 0 2 1a2.4 2.4 0 0 0 2 -1a2.4 2.4 0 0 1 2 -1a2.4 2.4 0 0 1 2 1a2.4 2.4 0 0 0 2 1a2.4 2.4 0 0 0 2 -1a2.4 2.4 0 0 1 2 -1a2.4 2.4 0 0 1 2 1a2.4 2.4 0 0 0 2 1a2.4 2.4 0 0 0 2 -1"/><path d="M4 18l-1 -3h18l-1 3"/><path d="M11 12h7l-7 -9v9"/><path d="M8 7l-2 5"/>`),
  forklift:  _SVG(`<path d="M3 17a2 2 0 1 0 4 0a2 2 0 1 0 -4 0"/><path d="M12 17a2 2 0 1 0 4 0a2 2 0 1 0 -4 0"/><path d="M7 17l5 0"/><path d="M3 17v-6h13v6"/><path d="M5 11v-4h4"/><path d="M9 11v-6h4l3 6"/><path d="M22 15h-3v-10"/><path d="M16 13l3 0"/>`),
  tool:      _SVG(`<path d="M7 10h3v-3l-3.5 -3.5a6 6 0 0 1 8 8l6 6a2 2 0 0 1 -3 3l-6 -6a6 6 0 0 1 -8 -8l3.5 3.5"/>`),
  equipment: _SVG(`<path d="M10.325 4.317c.426 -1.756 2.924 -1.756 3.35 0a1.724 1.724 0 0 0 2.573 1.066c1.543 -.94 3.31 .826 2.37 2.37a1.724 1.724 0 0 0 1.065 2.572c1.756 .426 1.756 2.924 0 3.35a1.724 1.724 0 0 0 -1.066 2.573c.94 1.543 -.826 3.31 -2.37 2.37a1.724 1.724 0 0 0 -2.572 1.065c-.426 1.756 -2.924 1.756 -3.35 0a1.724 1.724 0 0 0 -2.573 -1.066c-1.543 .94 -3.31 -.826 -2.37 -2.37a1.724 1.724 0 0 0 -1.065 -2.572c-1.756 -.426 -1.756 -2.924 0 -3.35a1.724 1.724 0 0 0 1.066 -2.573c-.94 -1.543 .826 -3.31 2.37 -2.37c1 .608 2.296 .07 2.572 -1.065"/><path d="M9 12a3 3 0 1 0 6 0a3 3 0 0 0 -6 0"/>`),
};
const PICTO_LABELS = {
  car: 'Car', suv: 'SUV', pickup: 'Pickup', van: 'Van', lcv: 'LCV', hgv: 'HGV',
  trailer: 'Trailer', bus: 'Bus', motorbike: 'Moto', scooter: 'Scooter',
  bike: 'Bike', atv: 'ATV', tractor: 'Tractor', boat: 'Boat',
  forklift: 'Forklift', tool: 'Tool', equipment: 'Equipment',
};

function renderPictoGrid(currentKey) {
  const grid = $('vf-picto-grid');
  if (!grid) return;
  grid.innerHTML = Object.entries(PICTO_ICONS).map(([key, svg]) =>
    `<button type="button" class="picto-btn${key === currentKey ? ' picto-sel' : ''}" data-key="${escAttr(key)}" title="${escAttr(PICTO_LABELS[key] ?? key)}">${svg}<span>${escHTML(PICTO_LABELS[key] ?? key)}</span></button>`
  ).join('');
  grid.querySelectorAll('.picto-btn').forEach(btn => {
    btn.addEventListener('click', () => {
      grid.querySelectorAll('.picto-btn').forEach(b => b.classList.remove('picto-sel'));
      btn.classList.add('picto-sel');
      $('vf-icon-key').value = btn.dataset.key;
    });
  });
}
const SC = { ok: '#34d399', warn: '#fbbf24', danger: '#f87171', unknown: '#55556a' };
const SC_BG = { ok: 'rgba(52,211,153,0.15)', warn: 'rgba(251,191,36,0.15)', danger: 'rgba(248,113,113,0.15)', unknown: 'rgba(85,85,106,0.15)' };

function isTpms(s)    { return !!s && (s.brand === 'michelin' || s.wheelPosition != null); }
function isBattery(s) { return !!s && (s.brand === 'stihl' || s.brand === 'ela' || s.brand === 'airtag'); }
function isTracker(s) { return !!s && s.brand === 'tracker'; }

/** Format seconds as "Xd Xh Xm" (omits leading zero units) */
function fmtDuration(secs) {
  if (secs == null || secs < 0) return '–';
  const d = Math.floor(secs / 86400);
  const h = Math.floor((secs % 86400) / 3600);
  const m = Math.floor((secs % 3600) / 60);
  if (d > 0) return `${d}d ${h}h ${m}m`;
  if (h > 0) return `${h}h ${m}m`;
  return `${m}m`;
}

/** Compact timestamp: time only today, weekday+time within 7d, date+time otherwise */
function fmtTs(dateVal) {
  const d = dateVal instanceof Date ? dateVal : new Date(dateVal);
  const now = new Date();
  if (d.toDateString() === now.toDateString())
    return d.toLocaleTimeString([], { hour: '2-digit', minute: '2-digit', second: '2-digit' });
  if ((now - d) < 7 * 864e5)
    return d.toLocaleDateString([], { weekday: 'short' }) + ' ' + d.toLocaleTimeString([], { hour: '2-digit', minute: '2-digit', second: '2-digit' });
  return d.toLocaleDateString([], { day: 'numeric', month: 'short' }) + ' ' + d.toLocaleTimeString([], { hour: '2-digit', minute: '2-digit', second: '2-digit' });
}

// Escape helpers to prevent HTML injection when rendering server-provided strings.
function escHTML(value) {
  return String(value ?? '')
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;')
    .replace(/'/g, '&#39;');
}

function escAttr(value) {
  return escHTML(value).replace(/`/g, '&#96;');
}

function toFiniteNumber(value) {
  const n = typeof value === 'number' ? value : Number(value);
  return Number.isFinite(n) ? n : null;
}

function osmHref(lat, lon) {
  const la = toFiniteNumber(lat);
  const lo = toFiniteNumber(lon);
  if (la == null || lo == null) return null;
  return `https://www.openstreetmap.org/?mlat=${encodeURIComponent(la)}&mlon=${encodeURIComponent(lo)}&zoom=16`;
}

function safeCssColor(value) {
  if (typeof value !== 'string') return '';
  const v = value.trim();
  if (/^#[0-9a-fA-F]{3,8}$/.test(v)) return v;
  if (/^rgb(a)?\(\s*[\d.\s,%]+\)$/.test(v)) return v;
  if (/^var\(--[a-z0-9-]+\)$/i.test(v)) return v;
  return '';
}

/** Transient toast notification (bottom-right) */
function showToast(msg, type = 'success') {
  const cont = $('toast-container');
  if (!cont) return;
  const t = document.createElement('div');
  t.className = `toast toast-${type}`;
  t.textContent = String(msg ?? '');
  cont.appendChild(t);
  requestAnimationFrame(() => requestAnimationFrame(() => t.classList.add('toast-visible')));
  setTimeout(() => {
    t.classList.remove('toast-visible');
    t.addEventListener('transitionend', () => t.remove(), { once: true });
  }, 3200);
}

/** Branded delete confirmation modal (replaces browser confirm()) */
function showDeleteModal({ title, body, confirmLabel = 'Delete', onConfirm }) {
  const modal = $('del-modal');
  if (!modal) { if (confirm(title + '\n\n' + body)) onConfirm(); return; }
  $('del-modal-title').textContent = title;
  $('del-modal-body').textContent  = body;
  $('del-modal-ok').textContent    = confirmLabel;
  modal.classList.add('del-modal-open');
  const close = () => modal.classList.remove('del-modal-open');
  $('del-modal-backdrop').onclick = close;
  $('del-modal-cancel').onclick   = close;
  $('del-modal-ok').onclick       = () => { close(); onConfirm(); };
}

/** Animated skeleton rows for loading states */
function skeletonRows(cols, n = 6) {
  const cell = '<td><span class="skel-cell"></span></td>';
  return Array(n).fill(`<tr class="skel-row">${cell.repeat(cols)}</tr>`).join('');
}

function pStatus(pressure, target) {
  if (pressure == null) return 'unknown';
  if (pressure < 1.0)   return 'danger';
  if (!target)          return 'unknown';
  const d = Math.abs(pressure - target);
  return d <= 0.2 ? 'ok' : d <= 0.5 ? 'warn' : 'danger';
}

// ─── State ────────────────────────────────────────────────────────────────────
const S = {
  sensors: [], serverVehicles: [], assetTypes: [], selected: null, vehicleFilter: null,
  period: '24H', customFrom: null, customTo: null,
  mode: 'chart', records: [],
  loading: false, timer: null,
  ws: null, wsConnected: false,
  pChart: null, tChart: null, wovChart: null, wovTChart: null, leafletMap: null,
  mapMatchEnabled: false,
  allJourneysMode: false,
  secAudit: { limit: 50, offset: 0, total: 0, action: '', actor: '' },
  otaUpgrades: { limit: 50, offset: 0, total: 0, imeiFilter: '', statusFilter: '' },
  profiles: [],   // cached TrackerConfigProfile list
};

// ─── DOM helpers ──────────────────────────────────────────────────────────────
const $ = id => document.getElementById(id);
const D = {
  vehicleSelect: $('vehicle-select'),
  assetCard:     $('asset-card'),
  sensorList:   $('sensor-list'),
  lastUpdated:  $('last-updated'),
  livePill:     $('live-pill'),
  liveLabel:    $('live-label'),
  breadcrumb:   $('breadcrumb'),

  statMin:      $('stat-min'),
  statAvg:      $('stat-avg'),
  statMax:      $('stat-max'),

  statMinLbl:   $('stat-min')?.closest('.stat-cell')?.querySelector('.stat-label'),
  statAvgLbl:   $('stat-avg')?.closest('.stat-cell')?.querySelector('.stat-label'),
  statMaxLbl:   $('stat-max')?.closest('.stat-cell')?.querySelector('.stat-label'),
  chartCont:    $('chart-container'),
  mapCont:      $('map-container'),
  tableCont:    $('table-container'),
  alertsCont:   $('alerts-container'),
  deviceCont:   $('device-container'),
  errorsCont:   $('errors-container'),
  wheelsCont:   $('wheels-container'),
  fleetCont:    $('fleet-container'),
  fleetSummary: $('fleet-summary'),
  emptyState:   $('empty-state'),
  tableBody:    $('table-body'),
  tempCard:     $('temp-card'),
  presCanvas:   $('pressure-canvas'),
  tempCanvas:   $('temp-canvas'),
  customRange:  $('custom-range'),
  customFrom:   $('custom-from'),
  customTo:     $('custom-to'),
  content:      $('content'),
};

// ─── URL hash state (Phase 2.1) ─────────────────────────────────────────────
function pushHash() {
  const parts = [
    S.vehicleFilter ?? '',
    S.selected      ?? '',
    S.mode          ?? 'chart',
    S.period        ?? '24H',
  ].map(encodeURIComponent);
  history.replaceState(null, '', '#' + parts.join('/'));
}

function restoreFromHash() {
  const hash = location.hash.slice(1);
  if (!hash) return false;
  const parts = hash.split('/').map(p => { try { return decodeURIComponent(p); } catch { return p; } });
  const [vid, sid, mode, period] = parts;
  let restored = false;
  if (vid) { S.vehicleFilter = vid; restored = true; }
  if (sid) { S.selected = sid; restored = true; }
  const validModes   = ['chart','map','table','alerts','device','wheels','errors','fleet'];
  const validPeriods = ['1H','24H','7D','30D','custom'];
  if (mode   && validModes.includes(mode))     S.mode   = mode;
  if (period && validPeriods.includes(period)) S.period = period;
  return restored;
}

function syncPeriodUI() {
  document.querySelectorAll('.period-btn').forEach(b =>
    b.classList.toggle('active', b.dataset.period === S.period)
  );
  D.customRange.style.display = S.period === 'custom' ? 'flex' : 'none';
}

// ─── Time helpers ─────────────────────────────────────────────────────────────
function getRange() {
  const now = new Date();
  if (S.period !== 'custom') {
    const h = HOURS[S.period] ?? 24;
    return { from: new Date(now - h * 3_600_000), to: now };
  }
  return { from: S.customFrom || new Date(now - 86_400_000), to: S.customTo || now };
}

function fmtDT(iso) {
  return new Date(iso).toLocaleString([], { month: 'short', day: 'numeric', hour: '2-digit', minute: '2-digit' });
}

function toDatetimeLocal(d) {
  const p = n => String(n).padStart(2, '0');
  return `${d.getFullYear()}-${p(d.getMonth()+1)}-${p(d.getDate())}T${p(d.getHours())}:${p(d.getMinutes())}`;
}

// Stale thresholds per brand (minutes).
// AirTags only report when the iPhone is nearby — hours of silence is normal.
// Trackers send GPS pings every ~1 min but may lose signal for longer.
// Active sensors (TPMS, Stihl, ELA) send every few seconds when in range.
const STALE_MINS = {
  airtag:  24 * 60,   // 24 h — passive, only seen when phone is nearby
  tracker: 60,        // 1 h  — GPS ping may drop in tunnels / garages
};
function staleMins(brand) {
  return STALE_MINS[brand] ?? 10;   // default: 10 min for active sensors
}
function isStale(iso, minsOrBrand = 10) {
  const mins = typeof minsOrBrand === 'string' ? staleMins(minsOrBrand) : minsOrBrand;
  return !iso || (Date.now() - new Date(iso)) > mins * 60_000;
}

function fmtAgo(iso) {
  if (!iso) return 'never';
  const s = Math.floor((Date.now() - new Date(iso)) / 1000);
  if (s <    60) return `${s}s ago`;
  if (s <  3600) return `${Math.floor(s / 60)}min ago`;
  if (s < 86400) return `${Math.floor(s / 3600)}h ago`;
  return `${Math.floor(s / 86400)}d ago`;
}

function guessTimeUnit(recs) {
  if (!recs.length) return 'hour';
  const h = (new Date(recs.at(-1).timestamp) - new Date(recs[0].timestamp)) / 3_600_000;
  return h <= 2 ? 'minute' : h <= 48 ? 'hour' : h <= 336 ? 'day' : 'week';
}

// ─── API ──────────────────────────────────────────────────────────────────────
function authHeaders() {
  return AUTH.token ? { 'Authorization': `Bearer ${AUTH.token}` } : {};
}
async function apiFetch(path) {
  const res = await fetch(path, { headers: authHeaders() });
  if (!res.ok) throw new Error(`HTTP ${res.status}: ${path}`);
  return res.json();
}

async function loadSensors() {
  S.sensors = await apiFetch('/api/sensors/latest');
}

async function loadRecords() {
  if (!S.selected) { S.records = []; return; }
  const { from, to } = getRange();
  const url = `/api/records/by-sensor/${S.selected}?from=${encodeURIComponent(from.toISOString())}&to=${encodeURIComponent(to.toISOString())}`;
  const data = await apiFetch(url);
  S.records = data.sort((a, b) => new Date(a.timestamp) - new Date(b.timestamp));
}

// ─── Sidebar ──────────────────────────────────────────────────────────────────

// Merge server vehicles + sensor groups into one map keyed by vehicleID.
// Server vehicles are matched by UUID first, then by name.
function groupByVehicle() {
  const groups = {};
  for (const s of S.sensors) {
    if (!groups[s.vehicleID]) groups[s.vehicleID] = { id: s.vehicleID, name: s.vehicleName, sensors: [], serverVehicle: null };
    groups[s.vehicleID].sensors.push(s);
  }
  for (const sv of S.serverVehicles) {
    if (groups[sv.id]) {
      groups[sv.id].serverVehicle = sv;
    } else {
      const byName = Object.values(groups).find(g => g.name.toLowerCase() === sv.name.toLowerCase() && !g.serverVehicle);
      if (byName) { byName.serverVehicle = sv; }
      else { groups[`srv-${sv.id}`] = { id: `srv-${sv.id}`, name: sv.name, sensors: [], serverVehicle: sv }; }
    }
  }
  return groups;
}

function renderVehicles() {
  const groups = groupByVehicle();
  const ids    = Object.keys(groups);
  D.vehicleSelect.innerHTML =
    '<option value="">— Pick an asset —</option>' +
    ids.map(vid => {
      const g     = groups[vid];
      const name  = g.serverVehicle?.name ?? g.name;
      const label = g.sensors.length ? name : `${name} \u2014 no sensors`;
      return `<option value="${escAttr(vid)}"${S.vehicleFilter === vid ? ' selected' : ''}>${escHTML(label)}</option>`;
    }).join('');
  // Edit button is rendered inside the asset card (see renderSensors)
}

function renderSensors() {
  const groups  = groupByVehicle();
  const entry   = S.vehicleFilter ? groups[S.vehicleFilter] : null;
  const sensors = entry ? entry.sensors : [];
  // ──── Asset card ──────────────────────────────────────────────────────────
  if (!entry) {
    D.assetCard.innerHTML = '';
    D.sensorList.innerHTML = '<div class="sidebar-hint sidebar-hint-arrow">↑ Pick an asset from the dropdown above</div>';
    return;
  }
  const sv      = entry.serverVehicle;
  const S_CAR       = `<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"><path d="M4 11.5 L6.5 6.5 Q7 6 8 6 h8 q1 0 1.5.5 L20 11.5"/><rect x="2" y="11.5" width="20" height="5" rx="1.2"/><circle cx="7" cy="18" r="1.7"/><circle cx="17" cy="18" r="1.7"/><path d="M2 14h1M21 14h1"/></svg>`;
  const S_TRUCK     = `<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"><rect x="1" y="8" width="13" height="8" rx="1"/><path d="M14 10.5 L18.5 10.5 L22 14.5 V16.5 H14 Z"/><circle cx="5" cy="18" r="1.7"/><circle cx="11" cy="18" r="1.7"/><circle cx="19" cy="18" r="1.7"/><path d="M17 12h2.5"/></svg>`;
  const S_MOTO      = `<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"><circle cx="5" cy="16" r="3"/><circle cx="19" cy="16" r="3"/><path d="M8 16 L10.5 9.5 h4 L17.5 14"/><path d="M12 9.5 L13 6.5 h3.5"/><path d="M5 16 L8 13"/></svg>`;
  const S_VAN       = `<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"><rect x="1" y="7" width="15" height="9" rx="1"/><path d="M16 9.5 L20.5 9.5 L22.5 13.5 V16 H16 Z"/><circle cx="5.5" cy="17.5" r="1.7"/><circle cx="12.5" cy="17.5" r="1.7"/><circle cx="20" cy="17.5" r="1.7"/><rect x="3" y="9" width="4.5" height="3" rx="0.5"/><rect x="9" y="9" width="4.5" height="3" rx="0.5"/></svg>`;
  const S_EQUIPMENT = `<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"><circle cx="12" cy="12" r="3"/><path d="M12 2v3M12 19v3M4.22 4.22l2.12 2.12M17.66 17.66l2.12 2.12M2 12h3M19 12h3M4.22 19.78l2.12-2.12M17.66 6.34l2.12-2.12"/></svg>`;
  const S_TOOL      = `<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"><path d="M14.7 6.3a1 1 0 0 0 0 1.4l1.6 1.6a1 1 0 0 0 1.4 0l3.77-3.77a6 6 0 0 1-7.94 7.94l-6.91 6.91a2.12 2.12 0 0 1-3-3l6.91-6.91a6 6 0 0 1 7.94-7.94l-3.77 3.77z"/></svg>`;
  const ASSET_SVG = { truck: S_TRUCK, moto: S_MOTO, bike: S_MOTO, tool: S_TOOL, equipment: S_EQUIPMENT, trailer: S_VAN, van: S_VAN };
  const typeName = S.assetTypes.find(t => t.id === sv?.assetTypeID)?.name?.toLowerCase() ?? '';
  const typeIcon = (sv?.iconKey && PICTO_ICONS[sv.iconKey])
    ? PICTO_ICONS[sv.iconKey]
    : (Object.entries(ASSET_SVG).find(([k]) => typeName.includes(k))?.[1] ?? S_CAR);
  const assetName   = escHTML(sv?.name ?? entry.name);
  const subParts    = [sv?.brand, sv?.modelName, sv?.year].filter(Boolean);
  const subText     = escHTML(subParts.join('\u00a0· '));
  const vrnBadge    = sv?.vrn  ? `<span class="ac-badge ac-vrn">${escHTML(sv.vrn)}</span>`  : '';
  const vinBadge    = sv?.vin  ? `<span class="ac-badge ac-vin" title="${escAttr(sv.vin)}">${escHTML(sv.vin)}</span>` : '';
  const sCount      = sensors.length;
  const sLabel      = `${sCount} sensor${sCount !== 1 ? 's' : ''}`;
  const editBtn     = AUTH.isAdmin && sv
    ? `<button id="edit-vehicle-btn" class="ac-edit-btn" title="Edit asset"><svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path stroke="none" d="M0 0h24v24H0z" fill="none"/><path d="M4 20h4l10.5 -10.5a2.828 2.828 0 1 0 -4 -4l-10.5 10.5v4"/><path d="M13.5 6.5l4 4"/></svg></button>` : '';
  D.assetCard.innerHTML = `
    <div class="asset-card">
      <div class="ac-left">
        ${vrnBadge}
        ${sv?.vin ? `<span class="ac-badge ac-vin">${escHTML(sv.vin)}</span>` : ''}
        <span class="ac-badge ac-count">${sLabel}</span>
      </div>
      <div class="ac-right">
        <div class="ac-icon">${typeIcon}</div>
        <div class="ac-name">${assetName}${editBtn}</div>
        ${subText ? `<div class="ac-sub">${subText}</div>` : ''}
      </div>
    </div>`;
  if (AUTH.isAdmin && sv) {
    D.assetCard.querySelector('#edit-vehicle-btn')?.addEventListener('click', () => openVehicleModal(sv));
  }
  if (!sensors.length) {
    D.sensorList.innerHTML = '<div class="sidebar-hint">No sensors</div>';
    return;
  }

  const WHEEL_ORDER    = ['FL', 'FR', 'RL', 'RR'];
  const tpmsSensors    = sensors.filter(s => isTpms(s));
  // Trackers first, then everything else (excluding TPMS)
  const nonTpmsSensors = [
    ...sensors.filter(s => !isTpms(s) && s.brand === 'tracker'),
    ...sensors.filter(s => !isTpms(s) && s.brand !== 'tracker'),
  ];
  let html = '';

  // ──── Non-TPMS tracker rows rendered first ───────────────────────────────
  html += nonTpmsSensors.filter(s => s.brand === 'tracker').map(s => {
    const stale  = isStale(s.latestTimestamp, s.brand);
    const label  = escHTML(s.sensorName ?? s.vehicleName ?? BRAND_LABELS[s.brand] ?? s.brand);
    const sel    = s.sensorID === S.selected;
    const dotCol = stale ? SC.unknown : SC.ok;
    const parts  = [];
    if (s.latestGpsSatellites != null)
      parts.push(`<span style="color:#34d399;font-weight:600">\u{1F6F0}\uFE0E ${s.latestGpsSatellites} sats</span>`);
    if (s.latestLatitude != null && s.latestLongitude != null)
      parts.push(`<span style="color:#60a5fa;font-weight:600">${s.latestLatitude.toFixed(4)}, ${s.latestLongitude.toFixed(4)}</span>`);
    const valueSpan = parts.length ? ' \u00b7 ' + parts.join(' \u00b7 ') : '';
    return `<div class="sensor-row${sel ? ' selected' : ''}" data-sid="${escAttr(s.sensorID)}">
      <div class="s-dot" style="background:${dotCol}"></div>
      <div class="s-info">
        <div class="s-name">${label}</div>
        <div class="s-sub"><span class="s-brand" data-brand="${escAttr(s.brand)}">${escHTML(BRAND_LABELS[s.brand] ?? s.brand)}</span>${valueSpan}</div>
      </div>
    </div>`;
  }).join('');

  // ──── TPMS group card ────────────────────────────────────────────────────
  if (tpmsSensors.length) {
    // Worst status
    let worstStatus = 'ok';
    for (const s of tpmsSensors) {
      const st = pStatus(s.latestPressureBar, s.targetPressureBar);
      if (st === 'critical') { worstStatus = 'critical'; break; }
      if (st === 'low') worstStatus = 'low';
    }
    const anyStale   = tpmsSensors.some(s => isStale(s.latestTimestamp, s.brand));
    const worstDot   = anyStale ? SC.unknown : SC[worstStatus];
    const brandLabel = BRAND_LABELS[tpmsSensors[0].brand] ?? tpmsSensors[0].brand;
    const anySelected = tpmsSensors.some(s => s.sensorID === S.selected);

    // Sort by wheel position
    const byPos = {};
    const unpositioned = [];
    for (const s of tpmsSensors) {
      if (s.wheelPosition) byPos[s.wheelPosition] = s;
      else unpositioned.push(s);
    }

    // Wheel chip builder
    const chip = (s, pos) => {
      if (!s) return `<div class="tpms-chip tpms-chip-empty"><div class="tpms-chip-pos">${pos ?? ''}</div></div>`;
      const stale  = isStale(s.latestTimestamp, s.brand);
      const status = pStatus(s.latestPressureBar, s.targetPressureBar);
      const pCol   = stale ? SC.unknown : SC[status];
      const bgCol  = stale ? 'rgba(255,255,255,.04)' : SC_BG[status];
      const sel    = s.sensorID === S.selected;
      const pText  = s.latestPressureBar != null ? s.latestPressureBar.toFixed(2) : '\u2013';
      const cp     = s.wheelPosition ?? '?';
      return `<div class="tpms-chip${sel ? ' tpms-chip-sel' : ''}" data-sid="${escAttr(s.sensorID)}" style="--chip-col:${pCol};--chip-bg:${bgCol}" title="${escAttr(WHEEL_LABELS[cp] ?? cp)}">
        <div class="tpms-chip-pos">${cp}</div>
        <div class="tpms-chip-pres" style="color:var(--chip-col)">${pText}</div>
        <div class="tpms-chip-unit">bar</div>
      </div>`;
    };

    const hasPositioned = WHEEL_ORDER.some(p => byPos[p]);
    const gridHtml = hasPositioned
      ? `<div class="tpms-wheel-grid">
          <div class="tpms-axle">
            ${chip(byPos['FL'], 'FL')}
            <div class="tpms-axle-line"></div>
            ${chip(byPos['FR'], 'FR')}
          </div>
          <div class="tpms-axle">
            ${chip(byPos['RL'], 'RL')}
            <div class="tpms-axle-line"></div>
            ${chip(byPos['RR'], 'RR')}
          </div>
        </div>` : '';

    // Extra positions (e.g. spare) + unpositioned
    const extraPos = Object.keys(byPos).filter(p => !WHEEL_ORDER.includes(p));
    const extrasHtml = [...extraPos.map(p => chip(byPos[p], p)), ...unpositioned.map(s => chip(s))].join('');
    const extraGrid  = extrasHtml ? `<div class="tpms-wheel-grid tpms-extra-grid">${extrasHtml}</div>` : '';

    html += `<div class="sensor-row tpms-group-card${anySelected ? ' selected' : ''}" data-sid="${escAttr(tpmsSensors[0].sensorID)}" data-tpms-card="1">
      <div class="tpms-row-top">
        <div class="s-dot" style="background:${worstDot}"></div>
        <div class="s-info">
          <div class="s-name"><span class="s-brand" data-brand="${escAttr(tpmsSensors[0].brand)}">${escHTML(brandLabel)}</span></div>
          <div class="s-sub">${tpmsSensors.length} sensor${tpmsSensors.length > 1 ? 's' : ''}${anyStale ? ' \u00b7 <span style="color:var(--fg3)">stale</span>' : ''}</div>
        </div>
      </div>
      ${gridHtml}${extraGrid}
    </div>`;
  }

  // ──── Other non-TPMS rows (non-tracker) ──────────────────────────────────
  html += nonTpmsSensors.filter(s => s.brand !== 'tracker').map(s => {
    const stale  = isStale(s.latestTimestamp, s.brand);
    const label  = escHTML(s.sensorName ?? (s.brand === 'tracker' ? s.vehicleName : null) ?? BRAND_LABELS[s.brand] ?? s.brand);
    const sel    = s.sensorID === S.selected;
    const dotCol = stale ? SC.unknown : SC.ok;
    let valueSpan = '';
    if (s.brand === 'tracker') {
      const parts = [];
      if (s.latestGpsSatellites != null)
        parts.push(`<span style="color:#34d399;font-weight:600">\u{1F6F0}\uFE0E ${s.latestGpsSatellites} sats</span>`);
      if (s.latestLatitude != null && s.latestLongitude != null)
        parts.push(`<span style="color:#60a5fa;font-weight:600">${s.latestLatitude.toFixed(4)}, ${s.latestLongitude.toFixed(4)}</span>`);
      if (parts.length) valueSpan = ' \u00b7 ' + parts.join(' \u00b7 ');
    } else if (s.latestBatteryPct != null || s.latestChargeState) {
      const pct  = s.latestBatteryPct ?? 0;
      const bCol = pct > 50 ? '#34d399' : pct > 20 ? '#fbbf24' : '#f87171';
      valueSpan  = ` \u00b7 <span style="color:${bCol};font-weight:600">${pct}%${s.latestChargeState ? ' \u00b7 ' + escHTML(s.latestChargeState) : ''}</span>`;
    } else if (s.latestTemperatureC != null) {
      valueSpan = ` \u00b7 <span style="color:#60a5fa;font-weight:600">${s.latestTemperatureC.toFixed(1)}\u00b0C</span>`;
    }
    const brandLabel = BRAND_LABELS[s.brand] ?? s.brand;
    return `<div class="sensor-row${sel ? ' selected' : ''}" data-sid="${escAttr(s.sensorID)}">
      <div class="s-dot" style="background:${dotCol}"></div>
      <div class="s-info">
        <div class="s-name">${label}</div>
        <div class="s-sub"><span class="s-brand" data-brand="${escAttr(s.brand)}">${escHTML(brandLabel)}</span>${valueSpan}</div>
      </div>
    </div>`;
  }).join('');

  D.sensorList.innerHTML = html;
}

// ─── Fleet summary bar ───────────────────────────────────────────────────────
function renderFleetSummary() {
  const el = D.fleetSummary;
  if (!el) return;
  const groups  = groupByVehicle();
  const entry   = S.vehicleFilter ? groups[S.vehicleFilter] : null;
  const sensors = entry?.sensors ?? [];
  if (!sensors.length) { el.style.display = 'none'; return; }

  let ok = 0, warn = 0, danger = 0, stale = 0, lowBat = 0;
  for (const s of sensors) {
    if (isStale(s.latestTimestamp, s.brand)) { stale++; continue; }
    if (isTpms(s)) {
      const st = pStatus(s.latestPressureBar, s.targetPressureBar);
      if (st === 'ok') ok++;
      else if (st === 'warn') warn++;
      else danger++;
    } else if (s.latestBatteryPct != null && s.latestBatteryPct < 20) {
      lowBat++;
    } else {
      ok++;
    }
  }

  const pills = [];
  if (ok)     pills.push(`<span class="fsb-pill fsb-ok">${ok} ok</span>`);
  if (warn)   pills.push(`<span class="fsb-pill fsb-warn">${warn} warn</span>`);
  if (danger) pills.push(`<span class="fsb-pill fsb-danger">${danger} alert</span>`);
  if (lowBat) pills.push(`<span class="fsb-pill fsb-bat">${lowBat} low bat</span>`);
  if (stale)  pills.push(`<span class="fsb-pill fsb-stale">${stale} stale</span>`);

  el.innerHTML = pills.join('');
  el.style.display = pills.length ? 'flex' : 'none';
}

function renderSidebar() {
  renderVehicles();
  renderSensors();
  renderFleetSummary();
  D.lastUpdated.textContent = new Date().toLocaleTimeString();
  const hasLive = S.sensors.some(s => !isStale(s.latestTimestamp, s.brand));
  D.livePill.className  = 'status-pill' + (hasLive ? ' live' : '');
  D.liveLabel.textContent = S.sensors.length
    ? `${S.sensors.length} sensor${S.sensors.length > 1 ? 's' : ''}`
    : 'No sensors';
}

// ─── Breadcrumb ───────────────────────────────────────────────────────────────
function renderBreadcrumb() {
  const s = S.sensors.find(x => x.sensorID === S.selected);
  if (!s) { D.breadcrumb.innerHTML = '&ndash;'; return; }
  // Vehicle part: prefer the server-registered asset name (avoids tracker
  // overwriting vehicleName with its own label on push)
  const groups       = groupByVehicle();
  const group        = Object.values(groups).find(g => g.sensors.some(x => x.sensorID === s.sensorID));
  const vehicleLabel = group?.serverVehicle?.name ?? s.vehicleName;
  // Sensor part: wheel position > sensorName > tracker vehicleName > brand label
  const sensorLabel  = s.wheelPosition
    ? (WHEEL_LABELS[s.wheelPosition] ?? s.wheelPosition)
    : (s.sensorName ?? (s.brand === 'tracker' ? s.vehicleName : null) ?? (BRAND_LABELS[s.brand] ?? s.brand));
  D.breadcrumb.innerHTML = '';
  D.breadcrumb.style.display = 'none';
}

// ─── Sensor info card ─────────────────────────────────────────────────────────
function renderSensorInfoCard() {
  const el = $('sensor-info-card');
  if (!el) return;
  const s = S.sensors.find(x => x.sensorID === S.selected);
  if (!s) { el.innerHTML = ''; el.style.display = 'none'; el.className = ''; return; }
  el.style.display = '';
  el.className = s.brand === 'tracker' ? 'si-tracker' : '';
  const rawBrandLabel = BRAND_LABELS[s.brand] ?? s.brand;
  const brandLabel = escHTML(rawBrandLabel);
  const stale = isStale(s.latestTimestamp, s.brand);
  const rawMainLabel =
    s.wheelPosition
      ? (WHEEL_LABELS[s.wheelPosition] ?? s.wheelPosition)
      : (s.sensorName ?? (s.brand === 'tracker' ? s.vehicleName : null) ?? rawBrandLabel);
  const mainLabel = escHTML(rawMainLabel);
  const rows = [];
  if (isTpms(s)) {
    const status = pStatus(s.latestPressureBar, s.targetPressureBar);
    if (s.latestPressureBar != null)
      rows.push(siRow('Pressure', `${s.latestPressureBar.toFixed(2)} bar`, SC[status]));
    if (s.targetPressureBar != null)
      rows.push(siRow('Target', `${s.targetPressureBar.toFixed(2)} bar`));
    if (s.latestTemperatureC != null)
      rows.push(siRow('Temperature', `${s.latestTemperatureC.toFixed(1)} \u00b0C`, '#60a5fa'));
    if (s.latestVbattVolts != null) {
      const bPct = s.latestBatteryPct != null ? ` (\u224a${s.latestBatteryPct}%)` : '';
      const bCol = (s.latestBatteryPct ?? 100) < 20 ? '#f87171' : '';
      rows.push(siRow('Battery', `${s.latestVbattVolts.toFixed(2)} V${bPct}`, bCol));
    }
    if (s.wheelPosition) rows.push(siRow('Position', WHEEL_LABELS[s.wheelPosition] ?? s.wheelPosition));
    if (s.sensorName)    rows.push(siRow('Label', s.sensorName));
  } else if (s.brand === 'stihl') {
    const bPct = s.latestBatteryPct ?? 0;
    const bCol = bPct > 50 ? '#34d399' : bPct > 20 ? '#fbbf24' : '#f87171';
    if (s.latestBatteryPct != null) {
      const v = s.latestVbattVolts != null ? ` \u00b7 ${s.latestVbattVolts.toFixed(2)} V` : '';
      rows.push(siRow('Battery', `${bPct}%${v}`, bCol));
    }
    if (s.latestChargeState) rows.push(siRow('State', s.latestChargeState, chargeStateColor(s.latestChargeState)));
    if (s.latestTemperatureC != null) rows.push(siRow('Temperature', `${s.latestTemperatureC.toFixed(1)} \u00b0C`, '#60a5fa'));
    // Smart Battery-specific fields
    if (s.latestHealthPct != null) {
      const hCol = s.latestHealthPct > 70 ? '#34d399' : s.latestHealthPct > 40 ? '#fbbf24' : '#f87171';
      rows.push(siRow('Health', `${s.latestHealthPct}%`, hCol));
    }
    if (s.latestChargingCycles != null) rows.push(siRow('Cycles', s.latestChargingCycles.toLocaleString()));
    if (s.latestTotalSeconds   != null) rows.push(siRow('Total time', fmtDuration(s.latestTotalSeconds)));
    if (s.sensorID.startsWith('STIHL-')) {
      const hex = s.sensorID.slice(6);
      const mac = hex.match(/.{2}/g).join(':').toUpperCase();
      rows.push(siRow('MAC', mac));
    } else if (s.sensorID.startsWith('STIHLBATT-')) {
      rows.push(siRow('Serial', s.sensorID.slice(10)));
    }
    rows.push(siRow('Sensor ID', s.sensorID));
  } else if (s.brand === 'ela') {
    if (s.latestProductVariant) {
      const variantLabel = PRODUCT_VARIANT_LABELS[s.latestProductVariant] ?? 'ELA Beacon';
      rows.push(siRow('Product', variantLabel, '#22d3ee'));
    }
    if (s.latestTemperatureC != null) rows.push(siRow('Temperature', `${s.latestTemperatureC.toFixed(1)} \u00b0C`, '#60a5fa'));
    if (s.latestBatteryPct  != null) {
      const bPct = s.latestBatteryPct;
      const bCol = bPct > 50 ? '#34d399' : bPct > 20 ? '#fbbf24' : '#f87171';
      rows.push(siRow('Battery', `${bPct}%`, bCol));
    }
    rows.push(siRow('Sensor ID', s.sensorID));
  } else if (s.brand === 'airtag') {
    if (s.sensorName && s.sensorName !== s.sensorID)
      rows.push(siRow('Name', s.sensorName));
    if (s.latestBatteryPct != null) {
      const atBPct   = s.latestBatteryPct;
      const atBLabel = atBPct >= 100 ? 'Full' : atBPct >= 60 ? 'Medium' : atBPct >= 25 ? 'Low' : 'Critical';
      const atBCol   = atBPct >= 60 ? '#34d399' : atBPct >= 25 ? '#fbbf24' : '#f87171';
      rows.push(siRow('Battery', `${atBLabel} (\u224a${atBPct}%)`, atBCol));
    }
    const separated = s.latestChargeState === 'Separated';
    rows.push(siRow('Status',
      separated ? '\u26a0\uFE0E Separated from owner' : '\u25cf Near owner',
      separated ? '#f87171' : '#34d399'));
    if (s.latestLatitude != null && s.latestLongitude != null)
      rows.push(siRow('GPS', `${s.latestLatitude.toFixed(5)}, ${s.latestLongitude.toFixed(5)}`));
    rows.push(siRow('Sensor ID', s.sensorID));
  } else if (s.brand === 'tracker') {
    rows.push(siRow('IMEI', s.sensorID));
    if (s.latestGpsSatellites != null)
      rows.push(siRow('Satellites', `${s.latestGpsSatellites}`, '#34d399'));
    if (s.latestLatitude != null && s.latestLongitude != null)
      rows.push(siRow('Position', `${s.latestLatitude.toFixed(5)}, ${s.latestLongitude.toFixed(5)}`));
    if (s.latestSpeedKmh != null)
      rows.push(siRow('Speed', `${s.latestSpeedKmh.toFixed(0)} km/h`, '#60a5fa'));
    if (s.latestTemperatureC != null)
      rows.push(siRow('Engine temp', `${s.latestTemperatureC.toFixed(1)} \u00b0C`, '#fbbf24'));
    if (s.latestBatteryPct != null) {
      const bCol = s.latestBatteryPct > 50 ? '#34d399' : s.latestBatteryPct > 20 ? '#fbbf24' : '#f87171';
      rows.push(siRow('Fuel level', `${s.latestBatteryPct}%`, bCol));
    }
    if (s.trackerAppliedConfigVersion != null || s.trackerServerConfigVersion != null) {
      const dv = s.trackerAppliedConfigVersion;  // null = never received by tracker
      const sv = s.trackerServerConfigVersion;    // null = no config saved on server
      let label, color;
      if (dv == null) {
        label = sv != null ? `v${sv} \u23f3 pending` : 'none';
        color = sv != null ? '#fbbf24' : '#6b7280';
      } else if (sv == null || dv >= sv) {
        label = `v${dv} \u2713`;
        color = '#34d399';
      } else {
        label = `v${dv} \u2192 v${sv} pending`;
        color = '#fbbf24';
      }
      rows.push(siRow('Config', label, color));
    }
  }
  if (s.latestTimestamp) rows.unshift(siRow('Last seen', fmtDT(s.latestTimestamp), stale ? '#f87171' : '#34d399'));
  if (s.readingCount != null) rows.push(siRow('Readings', s.readingCount.toLocaleString()));
  const liveBadge = stale ? '' : `<span class="si-live">\u25cf Live</span>`;
  const status = pStatus(s.latestPressureBar, s.targetPressureBar);
  const gaugeIcon = `<svg width="11" height="11" viewBox="0 0 11 11" fill="none" style="vertical-align:-1px"><circle cx="5.5" cy="5.5" r="4.5" stroke="currentColor" stroke-width="1.2"/><path d="M5.5 5.5L8 2.5" stroke="currentColor" stroke-width="1.2" stroke-linecap="round"/><circle cx="5.5" cy="5.5" r="1" fill="currentColor"/></svg>`;
  const tgtBadge = s.targetPressureBar != null
    ? `<span class="si-badge si-badge-tgt" style="background:${SC_BG[status]};color:${SC[status]}">${gaugeIcon} ${s.targetPressureBar.toFixed(2)} bar</span>` : '';
  if (s.latestBatteryPct != null) {
    const bp = s.latestBatteryPct;
    const bCol = bp > 50 ? '#34d399' : bp > 20 ? '#fbbf24' : '#f87171';
    const fillW = Math.round((bp / 100) * 12);
    const battIcon = `<svg width="16" height="10" viewBox="0 0 16 10" fill="none" style="vertical-align:-1px"><rect x="0.6" y="0.6" width="13.8" height="8.8" rx="1.8" stroke="currentColor" stroke-width="1.2"/><rect x="14.4" y="3" width="1.6" height="4" rx="0.8" fill="currentColor"/><rect x="2" y="2" width="${fillW}" height="6" rx="1" fill="currentColor"/></svg>`;
    var battBadge = `<span class="si-badge si-badge-batt" style="background:rgba(52,211,153,.1);color:${bCol}">${battIcon} ${bp}%${ s.latestChargeState ? ' \u00b7 ' + escHTML(s.latestChargeState) : ''}</span>`;
  } else {
    var battBadge = '';
  }
  const inlineActions = AUTH.isAdmin ? `<span class="si-inline-actions">
    <button class="si-rename-action-btn" title="Rename"><svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path stroke="none" d="M0 0h24v24H0z" fill="none"/><path d="M4 20h4l10.5 -10.5a2.828 2.828 0 1 0 -4 -4l-10.5 10.5v4"/><path d="M13.5 6.5l4 4"/></svg></button>
    ${s.brand === 'tracker' ? `<button class="si-config-btn" title="Config"><svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path stroke="none" d="M0 0h24v24H0z" fill="none"/><path d="M10.325 4.317c.426 -1.756 2.924 -1.756 3.35 0a1.724 1.724 0 0 0 2.573 1.066c1.543 -.94 3.31 .826 2.37 2.37a1.724 1.724 0 0 0 1.065 2.572c1.756 .426 1.756 2.924 0 3.35a1.724 1.724 0 0 0 -1.066 2.573c.94 1.543 -.826 3.31 -2.37 2.37a1.724 1.724 0 0 0 -2.572 1.065c-.426 1.756 -2.924 1.756 -3.35 0a1.724 1.724 0 0 0 -2.573 -1.066c-1.543 .94 -3.31 -.826 -2.37 -2.37a1.724 1.724 0 0 0 -1.065 -2.572c-1.756 -.426 -1.756 -2.924 0 -3.35a1.724 1.724 0 0 0 1.066 -2.573c-.94 -1.543 .826 -3.31 2.37 -2.37c1 .608 2.296 .07 2.572 -1.065z"/><path d="M9 12a3 3 0 1 0 6 0a3 3 0 0 0 -6 0"/></svg></button>` : ''}
    <button class="si-unpair-btn modal-btn-danger si-unpair-inline" data-sid="${escAttr(s.sensorID)}">Unpair</button>
  </span>` : '';
  el.innerHTML = `<div class="si-header">
    <span class="si-brand" data-brand="${escAttr(s.brand)}">${brandLabel}</span>
    <span class="si-name">${mainLabel}</span>
    ${liveBadge}
    <span class="si-badges">${tgtBadge}${battBadge}</span>
    ${inlineActions}
  </div>
  <div class="si-rows">${rows.join('')}</div>
  <form class="si-rename-form" style="display:none">
    <input class="si-rename-input" type="text" value="${escAttr(rawMainLabel)}" maxlength="64" placeholder="Sensor name">
    <button type="submit" class="si-rename-save">Save</button>
    <button type="button" class="si-rename-cancel">Cancel</button>
  </form>
  <div id="threshold-editor"></div>`;
  renderThresholdEditor(s.sensorID);

  el.querySelector('.si-rename-action-btn')?.addEventListener('click', () => {
    const form = el.querySelector('.si-rename-form');
    el.querySelector('.si-inline-actions').style.display = 'none';
    form.style.display = '';
    form.querySelector('.si-rename-input').select();
  });
  el.querySelector('.si-rename-cancel')?.addEventListener('click', () => {
    el.querySelector('.si-rename-form').style.display = 'none';
    el.querySelector('.si-inline-actions').style.display = '';
  });
  el.querySelector('.si-rename-form')?.addEventListener('submit', async (e) => {
    e.preventDefault();
    const newName = el.querySelector('.si-rename-input').value.trim();
    const saveBtn = el.querySelector('.si-rename-save');
    saveBtn.disabled = true;
    try {
      if (s.brand === 'tracker') {
        await adminUpdateTracker(s.sensorID, newName);
      } else {
        await adminRenameSensor(s.sensorID, newName);
      }
      s.sensorName = newName || null;
      await loadSensors();
      renderBreadcrumb();
      renderSensorInfoCard();
      showToast('Sensor renamed.');
    } catch (err) {
      alert(`Failed to rename: ${err.message}`);
      saveBtn.disabled = false;
    }
  });

  el.querySelector('.si-unpair-btn')?.addEventListener('click', async () => {
    if (!confirm(`Remove sensor "${rawMainLabel}" from server? This will delete all its readings.`)) return;
    try {
      if (s.brand === 'tracker') {
        await adminUnpairTracker(s.sensorID);
      } else {
        const res = await fetch(`/api/sensors/pair/${encodeURIComponent(s.sensorID)}`, { method: 'DELETE', headers: authHeaders() });
        if (!res.ok && res.status !== 204) {
          const msg = await res.text().catch(() => res.status);
          throw new Error(msg);
        }
      }
      S.selected = null;
      await loadSensors();
      renderAll();
      showToast('Sensor removed from server.');
    } catch (err) {
      alert(`Failed to unpair sensor: ${err.message}`);
    }
  });

  el.querySelector('.si-config-btn')?.addEventListener('click', () => openTrackerConfigModal(s.sensorID));
}

function siRow(label, value, color = '') {
  const safeColor = safeCssColor(color);
  const style = safeColor ? ` style="color:${safeColor}"` : '';
  return `<div class="si-row"><span class="si-label">${escHTML(label)}</span><span class="si-val"${style}>${escHTML(value)}</span></div>`;
}

function chargeStateColor(state) {
  if (!state) return '';
  const s = state.toLowerCase();
  if (s.includes('charg')) return '#fbbf24';
  if (s.includes('full') || s.includes('idle')) return '#34d399';
  if (s.includes('disch')) return '#60a5fa';
  return '';
}

// ─── Stats bar ────────────────────────────────────────────────────────────────
function setStatLabels(min, avg, max) {
  if (D.statMinLbl) D.statMinLbl.textContent = min;
  if (D.statAvgLbl) D.statAvgLbl.textContent = avg;
  if (D.statMaxLbl) D.statMaxLbl.textContent = max;
}
function showStatCells(show) {
  [D.statMin, D.statAvg, D.statMax].forEach(el => {
    if (el) el.closest('.stat-cell').style.display = show ? '' : 'none';
  });
}
function renderStats() {
  document.querySelectorAll('.stat-cell').forEach(c => { c.className = 'stat-cell'; });
  showStatCells(false);
  const sensor = S.sensors.find(s => s.sensorID === S.selected);
  if (!sensor) return;

  if (isTpms(sensor)) {
    const target    = sensor.targetPressureBar;
    const pressures = S.records.map(r => r.pressureBar).filter(v => v != null);
    if (pressures.length) {
      const minP = Math.min(...pressures);
      const avgP = pressures.reduce((a, b) => a + b, 0) / pressures.length;
      const maxP = Math.max(...pressures);
      D.statMin.textContent = minP.toFixed(3);
      D.statAvg.textContent = avgP.toFixed(3);
      D.statMax.textContent = maxP.toFixed(3);
      setStatLabels('Min (bar)', 'Avg (bar)', 'Max (bar)');
      showStatCells(true);
      if (D.statMin) D.statMin.closest('.stat-cell').classList.add(pStatus(minP, target));
      if (D.statAvg) D.statAvg.closest('.stat-cell').classList.add(pStatus(avgP, target));
      if (D.statMax) D.statMax.closest('.stat-cell').classList.add(pStatus(maxP, target));
    }
    return;
  }
}

// ─── Show/hide content areas ──────────────────────────────────────────────────
function showMode(mode) {
  S.mode = mode;
  // 'alerts' is a sub-mode of the Events (table) tab — keep its button active
  document.querySelectorAll('.mode-btn').forEach(b => b.classList.toggle('active',
    b.dataset.mode === mode || (mode === 'alerts' && b.dataset.mode === 'table')
  ));
  const noData = S.records.length === 0;
  D.chartCont.style.display  = mode === 'chart'  && !noData ? 'flex'  : 'none';
  D.mapCont.style.display    = mode === 'map'    && !noData ? 'flex'  : 'none';
  D.tableCont.style.display  = mode === 'table'  && !noData ? 'flex'  : 'none';
  D.alertsCont.style.display = mode === 'alerts'            ? 'block' : 'none';
  D.deviceCont.style.display  = mode === 'device'            ? 'block' : 'none';
  D.wheelsCont.style.display  = mode === 'wheels'            ? 'block' : 'none';
  D.errorsCont.style.display  = mode === 'errors'            ? 'block' : 'none';
  D.fleetCont.style.display   = mode === 'fleet'             ? 'block' : 'none';
  D.emptyState.style.display = noData && !['alerts','device','wheels','errors','fleet'].includes(mode) ? 'flex' : 'none';
  // Period bar: hide for modes that don't use a time range
  $('period-bar').style.display = ['fleet', 'device', 'errors'].includes(mode) ? 'none' : '';
  // Hide top toolbar + stats bar when nothing meaningful to show
  // (still visible in fleet mode which works without a sensor selection)
  const _fleetOrSpecial = ['fleet'].includes(mode);
  $('top-toolbar').style.display = (S.selected || _fleetOrSpecial) ? '' : 'none';
  $('stats-bar').style.display   = S.selected ? '' : 'none';
  // Contextual empty state messaging
  const _vsEl = $('vehicle-select');
  if (D.emptyState.style.display === 'flex') {
    const _noAssets = !S.sensors.length && !S.serverVehicles.length;
    if (_noAssets) {
      D.emptyState.innerHTML =
        `<div class="empty-icon"><svg width="52" height="52" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.25" stroke-linecap="round" stroke-linejoin="round"><path stroke="none" d="M0 0h24v24H0z" fill="none"/><path d="M12 3l8 4.5l0 9l-8 4.5l-8 -4.5l0 -9l8 -4.5"/><path d="M12 12l8 -4.5"/><path d="M12 12l0 9"/><path d="M12 12l-8 -4.5"/><path d="M16 5.25l-8 4.5"/></svg></div>` +
        `<p>Welcome to NetMap</p>` +
        `<small>Get started: click the <strong>Administration</strong> button (top-right ⚙) to add your first asset and pair sensors.</small>`;
    } else if (!S.vehicleFilter) {
      D.emptyState.innerHTML =
        `<div class="empty-icon"><svg width="52" height="52" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.25" stroke-linecap="round" stroke-linejoin="round"><path stroke="none" d="M0 0h24v24H0z" fill="none"/><path d="M3 5a2 2 0 0 1 2 -2h14a2 2 0 0 1 2 2v14a2 2 0 0 1 -2 2h-14a2 2 0 0 1 -2 -2v-14z"/><path d="M9 11l3 3l3 -3"/></svg></div>` +
        `<p>Select an asset to get started</p>` +
        `<small>Use the dropdown at the top-left to choose an asset, then click a sensor in the list to view its data.</small>` +
        `<span class="empty-select-hint">← Pick an asset from the left panel</span>`;
      if (_vsEl) _vsEl.classList.add('select-pulse');
    } else {
      D.emptyState.innerHTML =
        `<div class="empty-icon"><svg width="52" height="52" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.25" stroke-linecap="round" stroke-linejoin="round"><path stroke="none" d="M0 0h24v24H0z" fill="none"/><path d="M4 7a2 2 0 0 1 2 -2h12a2 2 0 0 1 2 2v12a2 2 0 0 1 -2 2h-12a2 2 0 0 1 -2 -2v-12z"/><path d="M16 3v4"/><path d="M8 3v4"/><path d="M4 11h16"/></svg></div>` +
        `<p>No data for this period</p>` +
        `<small>Try a wider time range using the period buttons above — or check that the sensor is actively recording data.</small>`;
    }
  } else {
    if (_vsEl) _vsEl.classList.remove('select-pulse');
  }
}

// ─── Chart ────────────────────────────────────────────────────────────────────
function renderChart() {
  const sensor = S.sensors.find(s => s.sensorID === S.selected);
  resetChartCards();
  if (isTpms(sensor)) { renderChartTpms(sensor); }
  else if (sensor?.brand === 'airtag') { renderChartAirtag(); }
  else { renderChartBatteryTemp(sensor); }
}

// ─── Wheels overview (all TPMS combined) ─────────────────────────────────────
async function renderWheels() {
  const groups = groupByVehicle();
  const entry  = S.vehicleFilter ? groups[S.vehicleFilter] : null;
  const tpmsAll = (entry?.sensors ?? []).filter(s => isTpms(s));
  if (!tpmsAll.length) { D.wheelsCont.innerHTML = '<div class="bat-loading-full">No TPMS sensors</div>'; return; }

  // Show skeleton immediately
  D.wheelsCont.innerHTML = `<div class="wov-wrap"><div style="padding:16px">${skeletonRows(4, 4)}</div></div>`;

  // Fetch records for all TPMS sensors in parallel
  const { from, to } = getRange();
  const allData = await Promise.all(tpmsAll.map(s =>
    apiFetch(`/api/records/by-sensor/${s.sensorID}?from=${encodeURIComponent(from.toISOString())}&to=${encodeURIComponent(to.toISOString())}`)
      .then(recs => ({ sensor: s, records: Array.isArray(recs) ? recs.sort((a,b) => new Date(a.timestamp)-new Date(b.timestamp)) : [] }))
      .catch(() => ({ sensor: s, records: [] }))
  ));

  // Sort by wheel position order
  const WHEEL_ORDER  = ['FL', 'FR', 'RL', 'RR'];
  const WHEEL_COLORS = { FL: '#60a5fa', FR: '#34d399', RL: '#fbbf24', RR: '#f87171' };
  const sorted = [
    ...WHEEL_ORDER.map(p => allData.find(d => d.sensor.wheelPosition === p)).filter(Boolean),
    ...allData.filter(d => !WHEEL_ORDER.includes(d.sensor.wheelPosition)),
  ];

  const target = tpmsAll.find(s => s.targetPressureBar != null)?.targetPressureBar ?? null;

  // Balance: current pressures across wheels
  const curPressures = sorted.map(d => d.sensor.latestPressureBar).filter(v => v != null);
  const spread = curPressures.length > 1 ? Math.max(...curPressures) - Math.min(...curPressures) : null;
  const spreadCol = spread == null ? '#8A8D9E' : spread < 0.10 ? '#34d399' : spread < 0.20 ? '#fbbf24' : '#f87171';
  const _icoCheck = `<svg width="11" height="11" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round" style="vertical-align:-1px"><path stroke="none" d="M0 0h24v24H0z" fill="none"/><path d="M5 12l5 5l10 -10"/></svg>`;
  const _icoWarn  = `<svg width="11" height="11" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" style="vertical-align:-1px"><path stroke="none" d="M0 0h24v24H0z" fill="none"/><path d="M12 9v4"/><path d="M10.363 3.591l-8.106 13.534a1.914 1.914 0 0 0 1.636 2.871h16.214a1.914 1.914 0 0 0 1.636 -2.87l-8.106 -13.536a1.914 1.914 0 0 0 -3.274 0"/><path d="M12 16h.01"/></svg>`;
  const spreadLabel = spread == null ? '–' : spread < 0.10 ? `${_icoCheck} Balanced` : spread < 0.20 ? `${_icoWarn} Monitor` : `${_icoWarn} Check tyres`;

  // SVG semicircle gauge
  const gauge = (pressure, tgt, color) => {
    const R = 27, cx = 35, cy = 35;
    const ratio = tgt && pressure != null ? Math.min(Math.max(pressure / tgt, 0), 1.1) : 0;
    const r = Math.min(ratio, 1);
    const ex = cx - R * Math.cos(r * Math.PI);
    const ey = cy - R * Math.sin(r * Math.PI);
    const trackPath = `M ${cx-R} ${cy} A ${R} ${R} 0 0 1 ${cx+R} ${cy}`;
    const fillPath  = r > 0.005 ? `M ${cx-R} ${cy} A ${R} ${R} 0 0 1 ${ex.toFixed(1)} ${ey.toFixed(1)}` : '';
    const valTxt    = pressure != null ? pressure.toFixed(2) : '–';
    const valColor  = pressure != null ? color : 'rgba(255,255,255,.25)';
    return `<svg width="70" height="44" viewBox="0 0 70 44">
      <path d="${trackPath}" stroke="rgba(255,255,255,.07)" stroke-width="7" fill="none" stroke-linecap="round"/>
      ${fillPath ? `<path d="${fillPath}" stroke="${color}" stroke-width="7" fill="none" stroke-linecap="round"/>` : ''}
      <text x="${cx}" y="29" text-anchor="middle" fill="${valColor}" font-size="16" font-weight="700" font-family="-apple-system,sans-serif">${valTxt}</text>
      <text x="${cx}" y="40" text-anchor="middle" fill="rgba(255,255,255,.3)" font-size="9" font-family="-apple-system,sans-serif">bar</text>
    </svg>`;
  };

  // Wheel cards
  const cardsHTML = sorted.map(({ sensor: s }) => {
    const pos    = s.wheelPosition ?? '?';
    const color  = WHEEL_COLORS[pos] ?? '#a78bfa';
    const sTgt   = s.targetPressureBar ?? target;
    const status = pStatus(s.latestPressureBar, sTgt);
    const stale  = isStale(s.latestTimestamp, s.brand);
    const bCol   = s.latestBatteryPct != null
      ? (s.latestBatteryPct > 50 ? '#34d399' : s.latestBatteryPct > 20 ? '#fbbf24' : '#f87171') : '';
    const isSelected = s.sensorID === S.selected;
    const statusDot  = `<span class="wov-status-dot" style="background:${stale ? SC.unknown : SC[status]}"></span>`;
    const brandLabel = BRAND_LABELS[s.brand] ?? s.brand ?? '';
    const nameLabel  = s.sensorName ? s.sensorName : '';
    const subLabel   = [brandLabel, nameLabel].filter(Boolean).join(' · ');
    return `<div class="wov-wheel-card${isSelected ? ' wov-sel' : ''}" data-sid="${escAttr(s.sensorID)}" style="--wov-col:${safeCssColor(color) || '#a78bfa'}">
      <div class="wov-card-header">
        ${statusDot}<span class="wov-pos">${pos}</span>
        ${stale ? '<span class="wov-stale">stale</span>' : ''}
      </div>
      <div class="wov-card-namerow">
        <span class="wov-card-brand">${escHTML(subLabel)}</span>
        <span class="wov-card-meta">
          ${sTgt   != null ? `<span class="wov-target-inline">${sTgt.toFixed(2)} bar</span>` : ''}
          ${s.latestBatteryPct != null ? `<span style="color:${bCol}">${s.latestBatteryPct}%</span>` : ''}
        </span>
      </div>
      <div class="wov-gauge">${gauge(s.latestPressureBar, sTgt, stale ? SC.unknown : SC[status])}</div>
      <div class="wov-subrow">
        ${s.latestTemperatureC != null ? `<span style="color:#60a5fa">${s.latestTemperatureC.toFixed(1)}\u00b0C</span>` : ''}
      </div>
    </div>`;
  }).join('');

  // Balance bar
  const balHTML = `<div class="wov-balance">
    <span class="wov-balance-label">Pressure spread</span>
    <span class="wov-balance-val" style="color:${spreadCol}">${spread != null ? spread.toFixed(3)+' bar' : '–'}</span>
    <span class="wov-balance-status" style="color:${spreadCol}">${spreadLabel}</span>
  </div>`;

  D.wheelsCont.innerHTML = `
    <div class="wov-wrap">
      <div class="wov-cards">${cardsHTML}</div>
      ${balHTML}
      <div class="wov-chart-section">
        <div class="wov-chart-title">Pressure history — all tires</div>
        <div class="wov-chart-wrap"><canvas id="wov-chart-canvas"></canvas></div>
      </div>
      <div class="wov-chart-section" id="wov-temp-section" style="display:none">
        <div class="wov-chart-title">Temperature history — all tires</div>
        <div class="wov-chart-wrap"><canvas id="wov-temp-canvas"></canvas></div>
      </div>
    </div>`;

  // Click wheel card → select that sensor
  D.wheelsCont.querySelectorAll('.wov-wheel-card[data-sid]').forEach(card => {
    card.addEventListener('click', () => selectSensor(card.dataset.sid));
  });

  // Build Chart.js multi-dataset chart
  if (S.wovChart) { S.wovChart.destroy(); S.wovChart = null; }
  const datasets = sorted.map(({ sensor: s, records }) => {
    const pos   = s.wheelPosition ?? '?';
    const color = WHEEL_COLORS[pos] ?? '#a78bfa';
    return {
      label: `${pos} — ${WHEEL_LABELS[pos] ?? pos}`,
      data: records.map(r => ({ x: new Date(r.timestamp), y: r.pressureBar ?? null })),
      borderColor: color,
      backgroundColor: 'transparent',
      fill: false, tension: 0.35,
      pointRadius: 0, pointHoverRadius: 5,
      borderWidth: 2,
    };
  });
  // Target reference line
  const allTimes = sorted.flatMap(d => d.records.map(r => new Date(r.timestamp).getTime())).filter(Boolean);
  if (target != null && allTimes.length) {
    datasets.push({
      label: `Target (${target.toFixed(2)} bar)`,
      data: [{ x: new Date(Math.min(...allTimes)), y: target }, { x: new Date(Math.max(...allTimes)), y: target }],
      borderColor: 'rgba(255,255,255,.2)', borderDash: [5, 4],
      borderWidth: 1.5, pointRadius: 0, fill: false,
    });
  }
  const allPVals = sorted.flatMap(d => d.records.map(r => r.pressureBar)).filter(v => v != null);
  const yMin = allPVals.length ? Math.max(0, Math.min(...allPVals, target ?? Infinity) - 0.2) : 0;
  const yMax = allPVals.length ? Math.max(...allPVals, target ?? 0) + 0.2 : 4;
  const scaleCommon = {
    ticks: { color: '#8A8D9E', font: { size: 11 } },
    grid:  { color: 'rgba(255,255,255,.04)' },
  };
  const cvs = document.getElementById('wov-chart-canvas');
  if (cvs) {
    S.wovChart = new Chart(cvs, {
      type: 'line',
      data: { datasets },
      options: {
        responsive: true, maintainAspectRatio: false,
        interaction: { mode: 'index', intersect: false },
        plugins: {
          legend: { display: true, labels: { color: '#8A8D9E', font: { size: 11 }, boxWidth: 12, padding: 12 } },
          tooltip: { callbacks: { label: ctx => ` ${ctx.dataset.label}: ${ctx.raw?.y != null ? ctx.raw.y.toFixed(3)+' bar' : '–'}` } },
        },
        scales: {
          x: { type: 'time', time: { unit: guessTimeUnit(sorted[0]?.records ?? []) }, ...scaleCommon, ticks: { ...scaleCommon.ticks, maxTicksLimit: 8 } },
          y: { min: yMin, max: yMax, ...scaleCommon, ticks: { ...scaleCommon.ticks, callback: v => v.toFixed(2)+' b' } },
        },
      },
    });
  }

  // Temperature chart
  if (S.wovTChart) { S.wovTChart.destroy(); S.wovTChart = null; }
  const tDatasets = sorted
    .filter(({ records }) => records.some(r => r.temperatureC != null))
    .map(({ sensor: s, records }) => {
      const pos   = s.wheelPosition ?? '?';
      const color = WHEEL_COLORS[pos] ?? '#a78bfa';
      return {
        label: `${pos} — ${WHEEL_LABELS[pos] ?? pos}`,
        data: records.map(r => ({ x: new Date(r.timestamp), y: r.temperatureC ?? null })),
        borderColor: color,
        backgroundColor: 'transparent',
        fill: false, tension: 0.35,
        pointRadius: 0, pointHoverRadius: 5,
        borderWidth: 2,
      };
    });
  const tempSection = document.getElementById('wov-temp-section');
  const tcvs = document.getElementById('wov-temp-canvas');
  if (tDatasets.length && tempSection && tcvs) {
    tempSection.style.display = '';
    S.wovTChart = new Chart(tcvs, {
      type: 'line',
      data: { datasets: tDatasets },
      options: {
        responsive: true, maintainAspectRatio: false,
        interaction: { mode: 'index', intersect: false },
        plugins: {
          legend: { display: true, labels: { color: '#8A8D9E', font: { size: 11 }, boxWidth: 12, padding: 12 } },
          tooltip: { callbacks: { label: ctx => ` ${ctx.dataset.label}: ${ctx.raw?.y != null ? ctx.raw.y.toFixed(1)+'°C' : '–'}` } },
        },
        scales: {
          x: { type: 'time', time: { unit: guessTimeUnit(sorted[0]?.records ?? []) }, ...scaleCommon, ticks: { ...scaleCommon.ticks, maxTicksLimit: 8 } },
          y: { ...scaleCommon, ticks: { ...scaleCommon.ticks, callback: v => v.toFixed(0)+'°C' } },
        },
      },
    });
  }
}

function renderChartTpms(sensor) {
  const recs   = S.records;
  const target = sensor?.targetPressureBar ?? null;
  const labels = recs.map(r => new Date(r.timestamp));
  const pVals  = recs.map(r => r.pressureBar ?? null);
  const tVals  = recs.map(r => r.temperatureC ?? null);
  const hasT   = tVals.some(v => v != null);

  const pts   = pVals.filter(v => v != null);
  const yMin  = pts.length ? Math.max(0, Math.min(...pts, target ?? Infinity) - 0.3) : 0;
  const yMax  = pts.length ? Math.max(...pts, target ?? 0) + 0.3 : 4;
  const ptColors = recs.length <= 600 ? pVals.map(p => SC[pStatus(p, target)]) : undefined;

  $('chart-title-primary').textContent = 'Pressure (bar)';
  if (S.pChart) { S.pChart.destroy(); S.pChart = null; }
  const pDatasets = [{
    data: pVals,
    borderColor: '#6366F1',
    backgroundColor: 'rgba(99,102,241,0.10)',
    fill: true, tension: 0.4,
    pointRadius: ptColors ? 3 : 0, pointHoverRadius: 5,
    pointBackgroundColor: ptColors,
    borderWidth: 2, label: 'Pressure',
  }];
  if (target != null) {
    pDatasets.push({
      data: Array(recs.length).fill(target),
      borderColor: 'rgba(184,98,0,0.70)', borderDash: [6, 4],
      borderWidth: 1.5, pointRadius: 0, fill: false, label: 'Target',
    });
  }
  const scaleCommon = {
    ticks: { color: '#8A8D9E', font: { size: 11 } },
    grid:  { color: 'rgba(0,32,91,0.07)' },
  };

  // Annotation: vertical lines at pressure-threshold transitions (ok → warn/danger)
  const annotations = {};
  let _prevSt = null;
  recs.forEach((r, i) => {
    const st = pStatus(r.pressureBar, target);
    if ((st === 'warn' || st === 'danger') && st !== _prevSt) {
      annotations[`thr_${i}`] = {
        type: 'line', scaleID: 'x', value: labels[i],
        borderColor: st === 'danger' ? 'rgba(192,57,43,0.55)' : 'rgba(184,98,0,0.55)',
        borderWidth: 1.5, borderDash: [4, 3],
      };
    }
    _prevSt = st;
  });

  S.pChart = new Chart(D.presCanvas, {
    type: 'line', data: { labels, datasets: pDatasets },
    options: {
      responsive: true, maintainAspectRatio: false,
      interaction: { mode: 'index', intersect: false },
      plugins: {
        legend: { display: target != null, labels: { color: '#4A4D5E', font: { size: 11 } } },
        tooltip: { callbacks: { label: ctx => ctx.datasetIndex === 0
          ? ` ${ctx.raw?.toFixed(3) ?? '\u2013'} bar`
          : ` ${ctx.raw?.toFixed(2)} bar (target)` } },
        annotation: { annotations },
      },
      scales: {
        x: { type: 'time', time: { unit: guessTimeUnit(recs) }, ...scaleCommon, ticks: { ...scaleCommon.ticks, maxTicksLimit: 6 } },
        y: { min: yMin, max: yMax,
          title: { display: true, text: 'bar', color: '#8A8D9E', font: { size: 10 } },
          ...scaleCommon, ticks: { ...scaleCommon.ticks, callback: v => v.toFixed(2) + ' bar' } },
      }
    }
  });

  D.tempCard.style.display = hasT ? 'block' : 'none';
  if (hasT) {
    $('chart-container').querySelector('.chart-card:last-child .chart-title').textContent = 'Temperature (\u00b0C)';
    if (S.tChart) { S.tChart.destroy(); S.tChart = null; }
    S.tChart = new Chart(D.tempCanvas, {
      type: 'line',
      data: { labels, datasets: [{
        data: tVals, borderColor: '#B86200', backgroundColor: 'rgba(184,98,0,0.07)',
        fill: true, tension: 0.4, pointRadius: 0, borderWidth: 1.5,
      }] },
      options: {
        responsive: true, maintainAspectRatio: false,
        plugins: { legend: { display: false } },
        scales: {
          x: { type: 'time', time: { unit: guessTimeUnit(recs) }, ...scaleCommon, ticks: { ...scaleCommon.ticks, maxTicksLimit: 6 } },
          y: { title: { display: true, text: '\u00b0C', color: '#8A8D9E', font: { size: 10 } },
            ...scaleCommon, ticks: { ...scaleCommon.ticks, callback: v => v.toFixed(0) + '\u00b0C' } },
        }
      }
    });
  }
}

function renderChartBatteryTemp(sensor) {
  const recs   = S.records;
  const labels = recs.map(r => new Date(r.timestamp));
  const bVals  = recs.map(r => r.batteryPct ?? null);
  const tVals  = recs.map(r => r.temperatureC ?? null);
  const hasB   = bVals.some(v => v != null);
  const hasT   = tVals.some(v => v != null);
  const scaleCommon = {
    ticks: { color: '#8A8D9E', font: { size: 11 } },
    grid:  { color: 'rgba(0,32,91,0.07)' },
  };
  const bCol = (v) => v > 50 ? '#34d399' : v > 20 ? '#fbbf24' : '#f87171';

  if (S.pChart) { S.pChart.destroy(); S.pChart = null; }
  D.tempCard.style.display = 'none';
  if (S.tChart) { S.tChart.destroy(); S.tChart = null; }

  if (hasB) {
    $('chart-title-primary').textContent = 'Battery (%)';
    const ptColors = recs.length <= 600 ? bVals.map(v => v != null ? bCol(v) : '#55556a') : undefined;
    S.pChart = new Chart(D.presCanvas, {
      type: 'line',
      data: { labels, datasets: [{
        data: bVals,
        borderColor: '#34d399', backgroundColor: 'rgba(52,211,153,0.10)',
        fill: true, tension: 0.3,
        pointRadius: ptColors ? 2 : 0, pointHoverRadius: 4,
        pointBackgroundColor: ptColors,
        borderWidth: 2, label: 'Battery %',
      }] },
      options: {
        responsive: true, maintainAspectRatio: false,
        interaction: { mode: 'index', intersect: false },
        plugins: {
          legend: { display: false },
          tooltip: { callbacks: { label: ctx => ` ${ctx.raw ?? '\u2013'}%` } }
        },
        scales: {
          x: { type: 'time', time: { unit: guessTimeUnit(recs) }, ...scaleCommon, ticks: { ...scaleCommon.ticks, maxTicksLimit: 6 } },
          y: { min: 0, max: 100,
            title: { display: true, text: '%', color: '#8A8D9E', font: { size: 10 } },
            ...scaleCommon, ticks: { ...scaleCommon.ticks, callback: v => v + '%' } },
        }
      }
    });
  } else if (hasT) {
    // ELA: temperature as primary chart
    $('chart-title-primary').textContent = 'Temperature (\u00b0C)';
    S.pChart = new Chart(D.presCanvas, {
      type: 'line',
      data: { labels, datasets: [{
        data: tVals, borderColor: '#60a5fa', backgroundColor: 'rgba(96,165,250,0.10)',
        fill: true, tension: 0.4, pointRadius: 0, borderWidth: 2, label: 'Temperature',
      }] },
      options: {
        responsive: true, maintainAspectRatio: false,
        interaction: { mode: 'index', intersect: false },
        plugins: {
          legend: { display: false },
          tooltip: { callbacks: { label: ctx => ` ${ctx.raw?.toFixed(1) ?? '\u2013'}\u00b0C` } }
        },
        scales: {
          x: { type: 'time', time: { unit: guessTimeUnit(recs) }, ...scaleCommon, ticks: { ...scaleCommon.ticks, maxTicksLimit: 6 } },
          y: { title: { display: true, text: '\u00b0C', color: '#8A8D9E', font: { size: 10 } },
            ...scaleCommon, ticks: { ...scaleCommon.ticks, callback: v => v.toFixed(0) + '\u00b0C' } },
        }
      }
    });
  }

  // If battery AND temperature: show temp as secondary
  if (hasB && hasT) {
    $('chart-container').querySelector('.chart-card:last-child .chart-title').textContent = 'Temperature (\u00b0C)';
    D.tempCard.style.display = 'block';
    S.tChart = new Chart(D.tempCanvas, {
      type: 'line',
      data: { labels, datasets: [{
        data: tVals, borderColor: '#60a5fa', backgroundColor: 'rgba(96,165,250,0.07)',
        fill: true, tension: 0.4, pointRadius: 0, borderWidth: 1.5,
      }] },
      options: {
        responsive: true, maintainAspectRatio: false,
        plugins: { legend: { display: false } },
        scales: {
          x: { type: 'time', time: { unit: guessTimeUnit(recs) }, ...scaleCommon, ticks: { ...scaleCommon.ticks, maxTicksLimit: 6 } },
          y: { title: { display: true, text: '\u00b0C', color: '#8A8D9E', font: { size: 10 } },
            ...scaleCommon, ticks: { ...scaleCommon.ticks, callback: v => v.toFixed(0) + '\u00b0C' } },
        }
      }
    });
  }
}

function renderChartAirtag() {
  if (S.pChart) { S.pChart.destroy(); S.pChart = null; }
  if (S.tChart) { S.tChart.destroy(); S.tChart = null; }
  D.tempCard.style.display = 'none';
  document.querySelector('.chart-card').style.display = 'none';
  $('chart-gps-only').style.display = 'flex';
}

function resetChartCards() {
  document.querySelector('.chart-card').style.display = '';
  $('chart-gps-only').style.display = 'none';
}

// ─── Tracker journey map ──────────────────────────────────────────────────────
async function loadJourneys(vehicleID, from, to) {
  let url = `/api/vehicle-events/journeys?vehicle=${encodeURIComponent(vehicleID)}&limit=200`;
  if (from) url += `&from=${encodeURIComponent(from.toISOString())}`;
  if (to)   url += `&to=${encodeURIComponent(to.toISOString())}`;
  return apiFetch(url);
}

async function loadJourneyTrack(journeyID) {
  return apiFetch(`/api/vehicle-events?journey=${encodeURIComponent(journeyID)}&limit=2000`);
}

async function loadDriverBehavior(journeyID) {
  try { return await apiFetch(`/api/driver-behavior?journey=${encodeURIComponent(journeyID)}&limit=500`); }
  catch (e) { console.warn('Driver behavior fetch failed:', e); return []; }
}

// Fetch all journey tracks with a concurrency cap of 5
async function fetchAllTracks(journeys, onProgress) {
  const LIMIT = 5;
  const results = new Array(journeys.length).fill(null);
  let cursor = 0, done = 0;
  async function worker() {
    while (cursor < journeys.length) {
      const i = cursor++;
      try { results[i] = await loadJourneyTrack(journeys[i].journeyID); }
      catch(e) { console.warn('fetchAllTracks: failed', journeys[i].journeyID, e); results[i] = []; }
      onProgress?.(++done, journeys.length);
    }
  }
  await Promise.all(Array.from({ length: Math.min(LIMIT, journeys.length) }, worker));
  return results;
}

// Driver behavior icon config — Tabler.io SVG icons (currentColor, consistent with event badges)
const BEHAVIOR_SVG = {
  // arrow-big-up-lines = harsh acceleration
  acceleration: '<svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path stroke="none" d="M0 0h24v24H0z" fill="none"/><path d="M9 12h-3.586a1 1 0 0 1 -.707 -1.707l6.586 -6.586a1 1 0 0 1 1.414 0l6.586 6.586a1 1 0 0 1 -.707 1.707h-3.586v3h-6v-3"/><path d="M9 21h6"/><path d="M9 18h6"/></svg>',
  // arrow-big-down-lines = harsh braking
  braking:      '<svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path stroke="none" d="M0 0h24v24H0z" fill="none"/><path d="M15 12h3.586a1 1 0 0 1 .707 1.707l-6.586 6.586a1 1 0 0 1 -1.414 0l-6.586 -6.586a1 1 0 0 1 .707 -1.707h3.586v-3h6v3"/><path d="M15 3h-6"/><path d="M15 6h-6"/></svg>',
  // corner-right-down = cornering
  cornering:    '<svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path stroke="none" d="M0 0h24v24H0z" fill="none"/><path d="M6 6h6a3 3 0 0 1 3 3v10l-4 -4m8 0l-4 4"/></svg>',
  // gauge = overspeed
  overspeed:    '<svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path stroke="none" d="M0 0h24v24H0z" fill="none"/><path d="M3 12a9 9 0 1 0 18 0a9 9 0 1 0 -18 0"/><path d="M11 12a1 1 0 1 0 2 0a1 1 0 1 0 -2 0"/><path d="M13.41 10.59l2.59 -2.59"/><path d="M7 12a5 5 0 0 1 5 -5"/></svg>',
  // activity (ECG pulse) = over-rev
  revving:      '<svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path stroke="none" d="M0 0h24v24H0z" fill="none"/><path d="M3 12h4l3 8l4 -16l3 8h4"/></svg>',
  // hourglass = idling (same as events)
  idling:       '<svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path stroke="none" d="M0 0h24v24H0z" fill="none"/><path d="M6.5 7h11"/><path d="M6.5 17h11"/><path d="M6 20v-2a6 6 0 1 1 12 0v2a1 1 0 0 1 -1 1h-10a1 1 0 0 1 -1 -1"/><path d="M6 4v2a6 6 0 1 0 12 0v-2a1 1 0 0 0 -1 -1h-10a1 1 0 0 0 -1 1"/></svg>',
  // alert-triangle = unknown
  unknown:      '<svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path stroke="none" d="M0 0h24v24H0z" fill="none"/><path d="M12 9v4"/><path d="M10.363 3.591l-8.106 13.534a1.914 1.914 0 0 0 1.636 2.871h16.214a1.914 1.914 0 0 0 1.636 -2.87l-8.106 -13.536a1.914 1.914 0 0 0 -3.274 0"/><path d="M12 16h.01"/></svg>',
};

const BEHAVIOR_CONFIG = {
  acceleration: { label: 'Harsh Accel.',  color: '#fb923c', unit: 'm/s²' },
  braking:      { label: 'Harsh Braking', color: '#f87171', unit: 'm/s²' },
  cornering:    { label: 'Cornering',     color: '#818cf8', unit: 'm/s²' },
  overspeed:    { label: 'Overspeed',     color: '#facc15', unit: 'km/h' },
  revving:      { label: 'Over-Rev',      color: '#f472b6', unit: 'RPM'  },
  idling:       { label: 'Idling',        color: '#60a5fa', unit: 's'    },
  unknown:      { label: 'Alert',         color: '#94a3b8', unit: ''     },
};

// Palette for multi-journey overview mode — 10 visually distinct colors
const JOURNEY_PALETTE = [
  '#3b82f6', // blue
  '#f59e0b', // amber
  '#10b981', // emerald
  '#f87171', // rose
  '#a78bfa', // violet
  '#fb923c', // orange
  '#67e8f9', // cyan
  '#4ade80', // green
  '#f472b6', // pink
  '#facc15', // yellow
];

function behaviorIcon(alertType) {
  const c   = BEHAVIOR_CONFIG[alertType] || BEHAVIOR_CONFIG.unknown;
  const svg = BEHAVIOR_SVG[alertType] || BEHAVIOR_SVG.unknown;
  const color = safeCssColor(c.color) || '#94a3b8';
  return L.divIcon({
    className:  '',
    iconSize:   [32, 28],
    iconAnchor: [16, 14],
    popupAnchor:[0, -18],
    html: `<div style="padding:6px 8px;border-radius:99px;background:color-mix(in srgb,${color} 18%,#fff);border:1.5px solid color-mix(in srgb,${color} 45%,transparent);color:${color};display:inline-flex;align-items:center;justify-content:center;box-shadow:0 2px 8px rgba(0,0,0,.18);cursor:pointer">${svg}</div>`,
  });
}

// ─── OSRM Map Matching ────────────────────────────────────────────────────────
const OSRM_BASE        = 'https://router.project-osrm.org/match/v1/driving/';
const OSRM_CHUNK       = 9;   // public demo server hard limit: 10 coords per match request
const _osrmCache       = new Map(); // journeyID -> matched lls

async function osrmMatchChunk(lls, attempt = 0) {
  // lls: [[lat, lon], ...]  — OSRM expects lon,lat order
  // Filter invalid coords and deduplicate consecutive identical points
  const deduped = [];
  for (const [lat, lon] of lls) {
    if (!isFinite(lat) || !isFinite(lon) || (lat === 0 && lon === 0)) continue;
    const prev = deduped.at(-1);
    if (prev && prev[0] === lat && prev[1] === lon) continue;
    deduped.push([lat, lon]);
  }
  const valid = deduped;
  if (valid.length < 2) throw new Error('not enough valid points');
  const coords  = valid.map(([lat, lon]) => `${lon},${lat}`).join(';');
  const url     = `${OSRM_BASE}${coords}?overview=full&geometries=geojson&gaps=ignore`;
  let res;
  try {
    res = await fetch(url);
  } catch (networkErr) {
    if (attempt < 3) {
      await new Promise(r => setTimeout(r, 500 * (attempt + 1)));
      return osrmMatchChunk(lls, attempt + 1);
    }
    throw networkErr;
  }
  if (!res.ok) {
    const body = await res.text().catch(() => '');
    throw new Error(`OSRM HTTP ${res.status}: ${body.slice(0, 120)}`);
  }
  const data    = await res.json();
  if (data.code !== 'Ok') throw new Error(`OSRM code=${data.code}`);
  const matched = [];
  for (const m of data.matchings)
    for (const [lon, lat] of m.geometry.coordinates)
      matched.push([lat, lon]);
  return matched;
}

async function mapMatchTrack(lls, journeyID) {
  if (lls.length < 2) return null;
  if (journeyID != null && _osrmCache.has(journeyID)) return _osrmCache.get(journeyID);

  // Build chunks (overlap of 1 point for continuity)
  const chunks = [];
  for (let i = 0; i < lls.length; i += OSRM_CHUNK) {
    const chunk = lls.slice(i, i + OSRM_CHUNK + 1);
    if (chunk.length < 2) break;
    chunks.push({ index: chunks.length, chunk });
  }

  // Fire all chunk requests in parallel
  const settled = await Promise.allSettled(chunks.map(({ chunk }) => osrmMatchChunk(chunk)));

  // Assemble results in order
  const results = [];
  let anyMatched = false;
  settled.forEach(({ status, value, reason }, i) => {
    const rawChunk = chunks[i].chunk;
    if (status === 'fulfilled') {
      results.push(...(results.length > 0 ? value.slice(1) : value));
      anyMatched = true;
    } else {
      console.warn('[OSRM] chunk failed:', reason?.message);
      results.push(...(results.length > 0 ? rawChunk.slice(1) : rawChunk));
    }
  });

  const out = anyMatched ? results : null;
  if (journeyID != null && out !== null) _osrmCache.set(journeyID, out);
  if (!anyMatched) console.warn('[OSRM] no chunk matched — unavailable');
  return out;
}

async function renderTrackerMap(sensor) {
  D.mapCont.innerHTML = '';
  S.allJourneysMode = false;

  // ── Delete-period toolbar ────────────────────────────────────────────────
  const toolbar = document.createElement('div');
  toolbar.id = 'tracker-toolbar';
  const { from, to } = getRange();
  const dfShort = new Intl.DateTimeFormat([], { month: 'short', day: 'numeric', hour: '2-digit', minute: '2-digit' });
  const periodLabel = `${dfShort.format(from)} – ${dfShort.format(to)}`;
  toolbar.innerHTML = `
    <span class="tracker-toolbar-label">Period: <b>${periodLabel}</b></span>
    <button id="tracker-delete-period-btn" class="modal-btn-danger admin-small-btn" title="Delete all tracker events for this period">
      \uD83D\uDDD1\uFE0E Delete period data
    </button>`;
  D.mapCont.appendChild(toolbar);
  toolbar.querySelector('#tracker-delete-period-btn').addEventListener('click', async () => {
    const { from, to } = getRange();
    if (!confirm(`Delete all tracker data for ${periodLabel}?\nThis cannot be undone.`)) return;
    try {
      const res = await fetch(
        `/api/vehicle-events?imei=${encodeURIComponent(sensor.sensorID)}&from=${from.toISOString()}&to=${to.toISOString()}`,
        { method: 'DELETE', headers: authHeaders() }
      );
      if (!res.ok) throw new Error(await res.text());
      const { deleted } = await res.json();
      alert(`Deleted ${deleted} event${deleted !== 1 ? 's' : ''}.`);
      renderTrackerMap(sensor);  // refresh
    } catch (e) { alert(e.message); }
  });

  // ── Build map shell ──────────────────────────────────────────────────────
  const wrapper = document.createElement('div');
  wrapper.id = 'tracker-map-wrapper';
  D.mapCont.appendChild(wrapper);

  // Column wrapper: leaflet map stacked above load chart
  const mapColWrap = document.createElement('div');
  mapColWrap.id = 'map-col-wrap';
  wrapper.appendChild(mapColWrap);

  const mapDiv = document.createElement('div');
  mapDiv.id = 'leaflet-map';
  mapColWrap.appendChild(mapDiv);

  // ── Load estimation chart (below map) ─────────────────────────
  // ── Journey telemetry chart panel (Speed / Fuel / Load tabs) ─────────────
  const telemetryWrap = document.createElement('div');
  telemetryWrap.id = 'jlp-telemetry-wrap';
  telemetryWrap.style.display = 'none';
  telemetryWrap.innerHTML =
    `<div class="jlp-telemetry-header">`+
    `<div class="jlp-tab-pills">`+
    `<button class="jlp-tab-pill active" data-tab="speed">&#9654; Speed</button>`+
    `<button class="jlp-tab-pill" data-tab="fuel">&#9651; Fuel</button>`+
    `<button class="jlp-tab-pill" data-tab="load">&#9647; Load</button>`+
    `</div>`+
    `<span id="jlp-telemetry-badge" class="jlp-telemetry-badge"></span>`+
    `</div>`+
    `<div class="jlp-telemetry-body"><canvas id="jlp-telemetry-canvas"></canvas></div>`;
  mapColWrap.appendChild(telemetryWrap);

  // Tab pill clicks
  telemetryWrap.querySelectorAll('.jlp-tab-pill').forEach(btn =>
    btn.addEventListener('click', () => {
      if (_telemetryEvents) {
        _telemetryTab = btn.dataset.tab;
        telemetryWrap.querySelectorAll('.jlp-tab-pill').forEach(p => p.classList.toggle('active', p === btn));
        _drawTelemetryChart();
      }
    })
  );

  let _telemetryChart = null;
  let _telemetryEvents = null;
  let _telemetryTab = 'speed';

  // Shared x-axis config and base Chart.js options
  const _txScale = {
    type: 'time',
    time: { unit: 'minute', displayFormats: { minute: 'HH:mm' } },
    ticks: { color: '#64748b', font: { size: 9 }, maxRotation: 0, autoSkip: true, maxTicksLimit: 8 },
    grid: { color: 'rgba(255,255,255,0.04)' },
  };
  const _baseOpts = {
    animation: false, responsive: true, maintainAspectRatio: false,
    interaction: { mode: 'index', intersect: false },
    plugins: {
      tooltip: {
        backgroundColor: '#1e293b', titleColor: '#94a3b8', bodyColor: '#e2e8f0',
        callbacks: { title: items => new Date(items[0].parsed.x).toLocaleTimeString([], { hour: '2-digit', minute: '2-digit', second: '2-digit' }) },
      },
    },
  };

  function _drawTelemetryChart() {
    if (_telemetryChart) { _telemetryChart.destroy(); _telemetryChart = null; }
    const cvs   = document.getElementById('jlp-telemetry-canvas');
    const badge = document.getElementById('jlp-telemetry-badge');
    if (!cvs || !_telemetryEvents) return;
    const events = _telemetryEvents;

    if (_telemetryTab === 'speed') {
      const pts = events.filter(e => e.speedKmh != null).sort((a, b) => new Date(a.timestamp) - new Date(b.timestamp));
      if (!pts.length) return;
      const maxSpd = Math.max(...pts.map(e => e.speedKmh));
      if (badge) { badge.textContent = `max\u00a0${maxSpd.toFixed(0)}\u00a0km/h`; badge.style.cssText = 'color:#60a5fa'; badge.className = 'jlp-telemetry-badge'; }
      _telemetryChart = new Chart(cvs, {
        type: 'line',
        data: { labels: pts.map(e => new Date(e.timestamp)), datasets: [{
          label: 'Speed (km/h)', data: pts.map(e => +e.speedKmh.toFixed(1)),
          borderColor: '#60a5fa', backgroundColor: 'rgba(96,165,250,0.12)',
          fill: true, tension: 0.35, pointRadius: 0, pointHoverRadius: 4, spanGaps: true,
        }] },
        options: { ..._baseOpts,
          plugins: { ..._baseOpts.plugins, legend: { display: false },
            tooltip: { ..._baseOpts.plugins.tooltip, callbacks: { ..._baseOpts.plugins.tooltip.callbacks,
              label: item => `\u00a0${item.parsed.y != null ? item.parsed.y + ' km/h' : '\u2014'}` } } },
          scales: { x: _txScale, y: {
            title: { display: true, text: 'km/h', color: '#64748b', font: { size: 10 } },
            ticks: { color: '#64748b', font: { size: 9 } }, grid: { color: 'rgba(255,255,255,0.06)' }, beginAtZero: true } },
        },
      });

    } else if (_telemetryTab === 'fuel') {
      const fPts = events.filter(e => e.journeyFuelConsumedL != null).sort((a, b) => new Date(a.timestamp) - new Date(b.timestamp));
      const lPts = events.filter(e => e.fuelLevelPct      != null).sort((a, b) => new Date(a.timestamp) - new Date(b.timestamp));
      if (!fPts.length && !lPts.length) return;
      const lastFuel = fPts.length ? fPts[fPts.length - 1].journeyFuelConsumedL : null;
      if (badge) { badge.textContent = lastFuel != null ? `${lastFuel.toFixed(2)}\u00a0L consumed` : ''; badge.style.cssText = 'color:#f59e0b'; badge.className = 'jlp-telemetry-badge'; }
      const refPts = fPts.length ? fPts : lPts;
      const datasets = [];
      if (fPts.length) datasets.push({
        label: 'Journey fuel (L)', yAxisID: 'yL', data: fPts.map(e => +e.journeyFuelConsumedL.toFixed(3)),
        borderColor: '#f59e0b', backgroundColor: 'rgba(245,158,11,0.10)',
        fill: true, tension: 0.3, pointRadius: 0, pointHoverRadius: 4, spanGaps: true,
      });
      if (lPts.length) datasets.push({
        label: 'Fuel level (%)', yAxisID: 'yPct', data: lPts.map(e => e.fuelLevelPct),
        borderColor: '#34d399', backgroundColor: 'rgba(52,211,153,0.05)',
        fill: false, tension: 0.3, pointRadius: 0, pointHoverRadius: 4, borderDash: [4, 3], spanGaps: true,
      });
      const yScales = {};
      if (fPts.length) yScales.yL   = { type: 'linear', position: 'left',  title: { display: true, text: 'L',  color: '#64748b', font: { size: 10 } }, ticks: { color: '#64748b', font: { size: 9 } }, grid: { color: 'rgba(255,255,255,0.06)' }, beginAtZero: true };
      if (lPts.length) yScales.yPct = { type: 'linear', position: 'right', title: { display: true, text: '%',  color: '#64748b', font: { size: 10 } }, ticks: { color: '#64748b', font: { size: 9 } }, grid: { display: !fPts.length }, min: 0, max: 100 };
      _telemetryChart = new Chart(cvs, {
        type: 'line',
        data: { labels: refPts.map(e => new Date(e.timestamp)), datasets },
        options: { ..._baseOpts,
          plugins: { ..._baseOpts.plugins,
            legend: { display: fPts.length > 0 && lPts.length > 0, labels: { color: '#94a3b8', font: { size: 10 }, boxWidth: 16, padding: 10 } } },
          scales: { x: _txScale, ...yScales },
        },
      });

    } else if (_telemetryTab === 'load') {
      const pts = events.filter(e => e.loadMLoadKg != null || e.loadMTotalKg != null).sort((a, b) => new Date(a.timestamp) - new Date(b.timestamp));
      if (!pts.length) return;
      const last = pts[pts.length - 1];
      const conf = last.loadConfidence || '';
      const kg   = last.loadMLoadKg != null ? `~${Math.round(last.loadMLoadKg)}\u00a0kg payload` : last.loadMTotalKg != null ? `~${Math.round(last.loadMTotalKg)}\u00a0kg total` : '';
      if (badge) { badge.textContent = kg ? `${kg}${conf ? ` (${conf})` : ''}` : ''; badge.className = `jlp-telemetry-badge jlp-load-${conf}`; badge.style.cssText = ''; }
      const loadData = pts.map(e => e.loadMLoadKg  != null ? +e.loadMLoadKg.toFixed(1)  : null);
      const totData  = pts.map(e => e.loadMTotalKg != null ? +e.loadMTotalKg.toFixed(1) : null);
      const hasTot   = totData.some(v => v != null);
      const datasets = [{ label: 'Payload (kg)', data: loadData, borderColor: '#34d399', backgroundColor: 'rgba(52,211,153,0.10)', fill: true, tension: 0.3, pointRadius: 2, pointHoverRadius: 5, spanGaps: true }];
      if (hasTot) datasets.push({ label: 'Total mass (kg)', data: totData, borderColor: '#60a5fa', backgroundColor: 'rgba(96,165,250,0.06)', fill: false, tension: 0.3, pointRadius: 2, pointHoverRadius: 5, borderDash: [4, 3], spanGaps: true });
      _telemetryChart = new Chart(cvs, {
        type: 'line',
        data: { labels: pts.map(e => new Date(e.timestamp)), datasets },
        options: { ..._baseOpts,
          plugins: { ..._baseOpts.plugins,
            legend: { display: hasTot, labels: { color: '#94a3b8', font: { size: 10 }, boxWidth: 16, padding: 10 } },
            tooltip: { ..._baseOpts.plugins.tooltip, callbacks: { ..._baseOpts.plugins.tooltip.callbacks,
              label: item => ` ${item.dataset.label}: ${item.parsed.y != null ? item.parsed.y + ' kg' : '\u2014'}` } } },
          scales: { x: _txScale, y: { title: { display: true, text: 'kg', color: '#64748b', font: { size: 10 } }, ticks: { color: '#64748b', font: { size: 9 } }, grid: { color: 'rgba(255,255,255,0.06)' }, beginAtZero: false } },
        },
      });
    }
  }

  function renderLoadChart(events) {
    const wrap = document.getElementById('jlp-telemetry-wrap');
    if (!wrap) return;
    const hasSpeed = events.some(e => e.speedKmh != null);
    const hasFuel  = events.some(e => e.journeyFuelConsumedL != null || e.fuelLevelPct != null);
    const hasLoad  = events.some(e => e.loadMLoadKg != null || e.loadMTotalKg != null);
    if (!hasSpeed && !hasFuel && !hasLoad) { wrap.style.display = 'none'; return; }
    // Show/hide individual tab pills based on available data
    wrap.querySelectorAll('.jlp-tab-pill').forEach(p => {
      const t = p.dataset.tab;
      p.style.display = (t === 'speed' && hasSpeed) || (t === 'fuel' && hasFuel) || (t === 'load' && hasLoad) ? '' : 'none';
    });
    _telemetryTab = hasSpeed ? 'speed' : hasFuel ? 'fuel' : 'load';
    wrap.querySelectorAll('.jlp-tab-pill').forEach(p => p.classList.toggle('active', p.dataset.tab === _telemetryTab));
    _telemetryEvents = events;
    wrap.style.display = 'flex';
    _drawTelemetryChart();
  }

  const panel = document.createElement('div');
  panel.id = 'journey-list-panel';
  const trackerDisplayName = sensor.sensorName || sensor.vehicleName || 'GPS Tracker';
  const isAdmin = !!AUTH.username;   // any logged-in user; server APIs enforce admin-only
  panel.innerHTML =
    `<div class="jlp-header">`+
    `<span class="jlp-header-title">Journeys</span>`+
    `</div>`+
    `<label id="jlp-all-wrap" class="jlp-overview-bar"><input type="checkbox" id="jlp-all-cb"><span class="mm-toggle-track"><span class="mm-toggle-thumb"></span></span><span class="jlp-all-label">Show\u00a0all\u00a0on\u00a0map</span></label>`+
    `<div class="jlp-body"><div class="jlp-loading">Loading\u2026</div></div>`;
  wrapper.appendChild(panel);

  if (S.leafletMap) { S.leafletMap.remove(); S.leafletMap = null; }
  const defaultLL = sensor.latestLatitude != null ? [sensor.latestLatitude, sensor.latestLongitude] : [48.8566, 2.3522];
  const map = S.leafletMap = L.map('leaflet-map', { preferCanvas: true })
    .setView(defaultLL, sensor.latestLatitude != null ? 14 : 5);

  L.tileLayer('https://{s}.tile.openstreetmap.org/{z}/{x}/{y}.png', {
    attribution: '&copy; <a href="https://openstreetmap.org/copyright">OpenStreetMap</a>',
    maxZoom: 19,
  }).addTo(map);

  // ── Behavior alert legend ────────────────────────────────────────────────
  const BehaviorLegend = L.Control.extend({
    options: { position: 'bottomright' },
    onAdd() {
      const div = L.DomUtil.create('div', 'behavior-legend leaflet-control');
      let html = '<div class="behavior-legend-title">Driver Alerts</div>';
      Object.entries(BEHAVIOR_CONFIG).filter(([k]) => k !== 'unknown').forEach(([k, c]) => {
        const svg = BEHAVIOR_SVG[k] || BEHAVIOR_SVG.unknown;
        const color = safeCssColor(c.color) || '#94a3b8';
        html += `<div class="behavior-legend-row"><span class="behavior-legend-icon" style="border-color:${color};color:${color}">${svg}</span><span style="color:${color}">${escHTML(c.label)}</span></div>`;
      });
      div.innerHTML = html;
      L.DomEvent.disableClickPropagation(div);
      return div;
    }
  });
  let behaviorLegendCtrl = new BehaviorLegend().addTo(map);

  // Reposition the legend to whichever corner is furthest from both start and end markers
  function repositionLegend(startLL, endLL) {
    const bounds = map.getBounds();
    if (!bounds || !bounds.isValid()) return;
    const corners = {
      topleft:     bounds.getNorthWest(),
      topright:    bounds.getNorthEast(),
      bottomleft:  bounds.getSouthWest(),
      bottomright: bounds.getSouthEast(),
    };
    let best = 'bottomright', bestDist = -1;
    for (const [pos, corner] of Object.entries(corners)) {
      const d = Math.min(corner.distanceTo(startLL), corner.distanceTo(endLL));
      if (d > bestDist) { bestDist = d; best = pos; }
    }
    if (best !== behaviorLegendCtrl.getPosition()) {
      behaviorLegendCtrl.remove();
      behaviorLegendCtrl = new BehaviorLegend({ position: best }).addTo(map);
    }
  }

  // Show latest position pin
  let latestMarker = null;
  if (sensor.latestLatitude != null) {
    latestMarker = L.circleMarker([sensor.latestLatitude, sensor.latestLongitude], {
      radius: 10, fillColor: '#30d158', color: '#fff', weight: 2,
      fillOpacity: 1, opacity: 1,
    }).bindPopup('<b>Latest position</b>').addTo(map);
  }

  // ── Map-match toggle (native checkbox, zero Leaflet interference) ─────
  let matchDrawFn = null;
  const mmLabel = document.createElement('label');
  mmLabel.id = 'mm-toggle-wrap';
  mmLabel.innerHTML = `<input type="checkbox" id="mm-checkbox"${S.mapMatchEnabled ? ' checked' : ''}><span class="mm-toggle-track"><span class="mm-toggle-thumb"></span></span><span class="mm-toggle-text">Map match</span>`;
  L.DomEvent.disableClickPropagation(mmLabel);
  mapDiv.appendChild(mmLabel);

  document.getElementById('mm-checkbox').addEventListener('change', async function() {
    S.mapMatchEnabled = this.checked;
    if (this.checked && currentRawLls && !_osrmCache.has(currentJourneyID)) {
      matchCtrl.setAvailable(false);
      try {
        await mapMatchTrack(currentRawLls, currentJourneyID);
      } catch(e) {
        console.warn('Map matching unavailable:', e);
      }
      matchCtrl.setAvailable(_osrmCache.has(currentJourneyID) ? true : null);
    }
    if (matchDrawFn) matchDrawFn();
  });

  // Shared state for lazy OSRM
  let currentRawLls    = null;
  let currentJourneyID = null;
  function drawCurrentTrack() {
    const matchedLls = _osrmCache.get(currentJourneyID) ?? null;
    drawLayersFn?.(
      (S.mapMatchEnabled && matchedLls) ? matchedLls : currentRawLls,
      !!(S.mapMatchEnabled && matchedLls)
    );
  }
  let drawLayersFn = null;

  const matchCtrl = {
    setAvailable(ok) {
      const cb   = document.getElementById('mm-checkbox');
      const txt  = document.querySelector('.mm-toggle-text');
      if (cb)  cb.disabled = false; // always clickable
      if (txt) txt.textContent = ok ? 'Map match ✓' : (ok === false && currentJourneyID ? 'Map match (unavailable)' : 'Map match');
    },
    reset() {
      const cb  = document.getElementById('mm-checkbox');
      const txt = document.querySelector('.mm-toggle-text');
      if (cb)  cb.disabled = false;
      if (txt) txt.textContent = 'Map match';
    }
  };

  // Track layers for current journey
  let trackLayers    = [];   // route + speed dots — cleared on map-match toggle
  let behaviorLayers = [];   // behavior markers   — survive map-match toggles
  // Overview mode: all-journeys polylines + behavior markers for selected journey
  const allPolylines      = new Map(); // journeyID → { polyline, color, lls }
  let   allBehaviorLayers = [];

  // Clear route lines/dots and then re-add stored behavior markers on top
  function clearTrack() {
    trackLayers.forEach(l => map.removeLayer(l));
    trackLayers = [];
    behaviorLayers.forEach(l => map.removeLayer(l)); // temporarily remove
    // behaviorLayers array is NOT reset here — reAddBehaviorLayers will re-add them
  }
  // Clear everything including behavior markers (new journey selected)
  function clearAll() {
    trackLayers.forEach(l => map.removeLayer(l));
    trackLayers = [];
    behaviorLayers.forEach(l => map.removeLayer(l));
    behaviorLayers = [];
    // Destroy telemetry chart if visible
    if (_telemetryChart) { _telemetryChart.destroy(); _telemetryChart = null; }
    _telemetryEvents = null;
    const lcw = document.getElementById('jlp-telemetry-wrap');
    if (lcw) lcw.style.display = 'none';
  }
  function reAddBehaviorLayers() {
    behaviorLayers.forEach(l => { trackLayers.push(l); l.addTo(map); });
  }

  const df = new Intl.DateTimeFormat([], { month: 'short', day: 'numeric', hour: '2-digit', minute: '2-digit' });

  async function selectJourney(journey, rowEl) {
    panel.querySelectorAll('.jlp-row').forEach(r => r.classList.remove('active'));
    rowEl.classList.add('active');

    // ── Overview mode: highlight selected route + load behavior markers ───────
    if (S.allJourneysMode) {
      const jData = allPolylines.get(journey.journeyID);
      if (jData) {
        // Journey has a polyline — highlight it and dim the rest
        allPolylines.forEach(({ polyline }, jid) => polyline.setStyle({
          weight:  jid === journey.journeyID ? 4.5 : 2,
          opacity: jid === journey.journeyID ? 1.0 : 0.28,
        }));
        try { map.fitBounds(jData.lls, { padding: [30, 30], maxZoom: 16 }); } catch(_) {}
      }
      // else: journey has no GPS track in overview — leave all polylines as-is
      allBehaviorLayers.forEach(l => map.removeLayer(l));
      allBehaviorLayers = [];
      try {
        const behaviors = await loadDriverBehavior(journey.journeyID);
        const alertBadge = rowEl.querySelector('.jlp-alert-badge');
        const alertCount = behaviors.length;
        if (alertBadge) alertBadge.innerHTML = alertCount > 0 ? `<svg width="10" height="10" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" style="vertical-align:-1px"><path stroke="none" d="M0 0h24v24H0z" fill="none"/><path d="M12 9v4"/><path d="M10.363 3.591l-8.106 13.534a1.914 1.914 0 0 0 1.636 2.871h16.214a1.914 1.914 0 0 0 1.636 -2.87l-8.106 -13.536a1.914 1.914 0 0 0 -3.274 0"/><path d="M12 16h.01"/></svg> ${alertCount}` : '';
        behaviors.forEach(b => {
          if (b.latitude == null || b.longitude == null) return;
          const cfg = BEHAVIOR_CONFIG[b.alertType] || BEHAVIOR_CONFIG.unknown;
          const cfgColor = safeCssColor(cfg.color) || '#94a3b8';
          const ts = fmtTs(b.timestamp);
          const durS = b.alertDurationMs != null ? (b.alertDurationMs / 1000).toFixed(1) : '?';
          const val = b.alertValueMax != null ? b.alertValueMax : null;
          const valStr = val != null ? (cfg.unit ? `${val.toFixed(2)} ${cfg.unit}` : val.toFixed(2)) : '\u2014';
          const spdStr = b.speedKmh != null ? `<br><span style="color:#94a3b8">${b.speedKmh.toFixed(0)} km/h</span>` : '';
          const popup = `<div style="font-size:13px;min-width:140px"><div style="font-weight:700;margin-bottom:4px;display:flex;align-items:center;gap:6px"><span style="display:inline-block;width:10px;height:10px;border-radius:50%;background:${cfgColor};flex-shrink:0"></span>${escHTML(cfg.label)}</div><div style="color:#94a3b8;font-size:11px">${escHTML(ts)}</div><hr style="border:none;border-top:1px solid rgba(255,255,255,.1);margin:6px 0"><div>Peak: <b>${escHTML(valStr)}</b></div><div>Duration: <b>${escHTML(durS)}s</b></div>${spdStr}</div>`;
          const m = L.marker([b.latitude, b.longitude], { icon: behaviorIcon(b.alertType) }).bindPopup(popup, { maxWidth: 220 });
          allBehaviorLayers.push(m);
          m.addTo(map);
        });
      } catch(e) { console.warn('overview behavior markers:', e); }
      return;
    }

    clearAll();   // new journey: remove everything
    matchDrawFn = null;
    matchCtrl.reset();

    try {
      const events  = await loadJourneyTrack(journey.journeyID);
      const pts     = events.filter(e => e.latitude != null && e.longitude != null);
      if (!pts.length) return;
      const rawLls  = pts
        .map(e => [e.latitude, e.longitude])
        .filter(([lat, lon]) => isFinite(lat) && isFinite(lon) && !(lat === 0 && lon === 0))
        .filter(([lat, lon], i, arr) => i === 0 || lat !== arr[i-1][0] || lon !== arr[i-1][1]);

      const _mkJourneyIcon = (svgPaths, fillIcon, color) => L.divIcon({
        className: '', iconSize: [32, 28], iconAnchor: [16, 14], popupAnchor: [0, -20],
        html: (() => {
          const safeColor = safeCssColor(color) || '#94a3b8';
          return `<div style="padding:6px 8px;border-radius:99px;background:color-mix(in srgb,${safeColor} 18%,#fff);border:1.5px solid color-mix(in srgb,${safeColor} 45%,transparent);color:${safeColor};display:inline-flex;align-items:center;justify-content:center;box-shadow:0 2px 8px rgba(0,0,0,.18)"><svg width="15" height="15" viewBox="0 0 24 24" fill="${fillIcon ? 'currentColor' : 'none'}" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path stroke="none" d="M0 0h24v24H0z" fill="none"/>${svgPaths}</svg></div>`;
        })(),
      });
      const _flagPaths = '<path d="M5 14h14v-9h-14v16"/>';
      const startIcon = _mkJourneyIcon(_flagPaths, false, '#34d399');
      const endIcon   = _mkJourneyIcon(_flagPaths, true,  '#f87171');

      function drawLayers(displayLls, isMatched) {
        clearTrack();
        const lineColor = isMatched ? '#3b82f6' : '#f59e0b';
        // Raw GPS underlay when showing matched route
        if (isMatched) {
          const rawLine = L.polyline(rawLls, { color: '#94a3b8', weight: 2, opacity: 0.4, dashArray: '5 6' });
          trackLayers.push(rawLine);
          rawLine.addTo(map);
        }
        const line = L.polyline(displayLls, { color: lineColor, weight: 3.5, opacity: 0.9 });
        trackLayers.push(line);
        line.addTo(map);
        // Start / End markers always on raw GPS positions
        const sm = L.marker(rawLls[0],      { icon: startIcon }).bindPopup('<b>Start</b>');
        const em = L.marker(rawLls.at(-1),  { icon: endIcon   }).bindPopup('<b>End</b>');
        trackLayers.push(sm, em);
        sm.addTo(map); em.addTo(map);
        // Speed dot markers on raw positions
        pts.forEach(e => {
          if (e.speedKmh == null) return;
          const m = L.circleMarker([e.latitude, e.longitude], { radius: 4, fillColor: lineColor, color: 'transparent', fillOpacity: 0.5 });
          m.bindPopup(`${new Date(e.timestamp).toLocaleTimeString()} \u2013 ${e.speedKmh.toFixed(0)} km/h`);
          trackLayers.push(m);
          m.addTo(map);
        });
        // Re-add behavior markers on top (persisted across map-match toggles)
        reAddBehaviorLayers();
        // Reposition legend away from start/end flags (after fitBounds settles)
        requestAnimationFrame(() => repositionLegend(L.latLng(rawLls[0]), L.latLng(rawLls.at(-1))));
      }

      // Draw raw GPS immediately
      currentRawLls    = rawLls;
      currentJourneyID = journey.journeyID;
      drawLayersFn     = drawLayers;
      matchDrawFn = () => drawCurrentTrack();
      matchCtrl.setAvailable(false);
      matchDrawFn();
      try { map.fitBounds(rawLls, { padding: [30, 30], maxZoom: 16 }); } catch(_) {}

      // If map match is already enabled, trigger OSRM now
      if (S.mapMatchEnabled) {
        let matchedLls = null;
        try {
          matchedLls = await mapMatchTrack(rawLls, journey.journeyID);
        } catch(e) {
          console.warn('Map matching unavailable:', e);
        }
        matchCtrl.setAvailable(!!matchedLls);
        matchDrawFn();
      }

      // ── Driver behavior markers ─────────────────────────────────────────
      const behaviors = await loadDriverBehavior(journey.journeyID);
      behaviorLayers = []; // fresh list for this journey

      // Count alerts for the badge and update the row
      const alertCount = behaviors.length;
      const alertBadge = rowEl.querySelector('.jlp-alert-badge');
      if (alertBadge) alertBadge.innerHTML = alertCount > 0 ? `<svg width="10" height="10" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" style="vertical-align:-1px"><path stroke="none" d="M0 0h24v24H0z" fill="none"/><path d="M12 9v4"/><path d="M10.363 3.591l-8.106 13.534a1.914 1.914 0 0 0 1.636 2.871h16.214a1.914 1.914 0 0 0 1.636 -2.87l-8.106 -13.536a1.914 1.914 0 0 0 -3.274 0"/><path d="M12 16h.01"/></svg> ${alertCount}` : '';

      behaviors.forEach(b => {
        if (b.latitude == null || b.longitude == null) return;
        const cfg  = BEHAVIOR_CONFIG[b.alertType] || BEHAVIOR_CONFIG.unknown;
        const icon = behaviorIcon(b.alertType);
        const ts   = fmtTs(b.timestamp);
        const durS = b.alertDurationMs != null ? (b.alertDurationMs / 1000).toFixed(1) : '?';
        const val  = b.alertValueMax != null ? b.alertValueMax : null;
        const valStr = val != null ? (cfg.unit ? `${val.toFixed(2)} ${cfg.unit}` : val.toFixed(2)) : '—';
        const spdStr = b.speedKmh != null ? `<br><span style="color:#94a3b8">${b.speedKmh.toFixed(0)} km/h</span>` : '';
        const cfgColor = safeCssColor(cfg.color) || '#94a3b8';
        const popup = `<div style="font-size:13px;min-width:140px">
          <div style="font-weight:700;margin-bottom:4px;display:flex;align-items:center;gap:6px"><span style="display:inline-block;width:10px;height:10px;border-radius:50%;background:${cfgColor};flex-shrink:0"></span>${escHTML(cfg.label)}</div>
          <div style="color:#94a3b8;font-size:11px">${escHTML(ts)}</div>
          <hr style="border:none;border-top:1px solid rgba(255,255,255,.1);margin:6px 0">
          <div>Peak: <b>${escHTML(valStr)}</b></div>
          <div>Duration: <b>${escHTML(durS)}s</b></div>
          ${spdStr}
        </div>`;
        const m = L.marker([b.latitude, b.longitude], { icon }).bindPopup(popup, { maxWidth: 220 });
        behaviorLayers.push(m);
        trackLayers.push(m);
        m.addTo(map);
      });

      // Warn about GPS-less alerts in console (not silent)
      const noGps = behaviors.filter(b => b.latitude == null || b.longitude == null);
      if (noGps.length) console.debug(`[behavior] ${noGps.length} alert(s) have no GPS position — not shown on map.`);

      // ── Load estimation chart ───────────────────────────────────────────
      renderLoadChart(events);
    } catch(e) { console.error('selectJourney:', e); }
  }

  // ── Fetch journeys and render panel ─────────────────────────────────────
  try {
    const { from: jFrom, to: jTo } = getRange();
    const journeys = await loadJourneys(sensor.vehicleID ?? sensor.sensorID, jFrom, jTo);
    const body = panel.querySelector('.jlp-body');
    if (!journeys.length) {
      body.innerHTML = '<div class="jlp-empty">No journeys recorded yet.</div>';
      return;
    }
    body.innerHTML = '';
    journeys.forEach((j, idx) => {
      const row = document.createElement('div');
      row.className = 'jlp-row';
      const date   = j.startedAt ? df.format(new Date(j.startedAt)) : 'Unknown date';
      const dist   = j.totalDistanceKm != null && j.totalDistanceKm > 0 ? `${j.totalDistanceKm.toFixed(1)} km` : '';
      const fuelL  = j.totalFuelConsumedL;
      let fuel = '';
      if (fuelL != null && fuelL > 0) {
        fuel = `${fuelL.toFixed(2)} L`;
        if (j.totalDistanceKm > 0)
          fuel += ` <span style="color:var(--fg3)">(${(fuelL / j.totalDistanceKm * 100).toFixed(1)} L/100km)</span>`;
      }
      let dur = '';
      if (j.startedAt && j.endedAt) {
        const secs = Math.round((new Date(j.endedAt) - new Date(j.startedAt)) / 1000);
        const h = Math.floor(secs / 3600);
        const m = Math.floor((secs % 3600) / 60);
        const s = secs % 60;
        dur = h > 0 ? `${h}h\u00a0${m}m` : m > 0 ? `${m}m\u00a0${s}s` : `${s}s`;
      }
      const spd    = j.maxSpeedKmh != null && j.maxSpeedKmh > 0 ? `max\u00a0${j.maxSpeedKmh.toFixed(0)}\u00a0km/h` : '';
      const pts    = j.eventCount > 0 ? `${j.eventCount}\u00a0pts` : '';
      // Load estimation badge
      let loadStr = '';
      if (j.loadConfidence && j.loadConfidence !== 'not_ready') {
        if (j.loadMLoadKg != null && j.loadMLoadKg >= 0) {
          loadStr = `<span class="jlp-load jlp-load-${escHTML(j.loadConfidence)}">~${Math.round(j.loadMLoadKg)}\u00a0kg payload</span>`;
        } else if (j.loadMTotalKg != null && j.loadMTotalKg > 0) {
          loadStr = `<span class="jlp-load jlp-load-${escHTML(j.loadConfidence)}">~${Math.round(j.loadMTotalKg)}\u00a0kg total mass</span>`;
        }
      }
      const driver  = j.driverID ? `<span class="jlp-driver">${escHTML(j.driverID)}</span>` : '';
      const meta    = [dist, fuel, dur, spd, pts].filter(Boolean).join(' · ');
      const ongoing = !j.endedAt;
      if (ongoing) row.classList.add('jlp-row-ongoing');
      row.innerHTML = `
        <div class="jlp-row-main">
          <span class="jlp-row-color"></span>
          <div class="jlp-row-info">
            <div class="jlp-row-date">${escHTML(date)}${driver}${ongoing ? ' <span class="jlp-ongoing-badge">● Live</span>' : ''}</div>
            ${meta ? `<div class="jlp-row-meta">${meta}</div>` : ''}
            ${loadStr ? `<div class="jlp-load-line">${loadStr}</div>` : ''}
          </div>
          <span class="jlp-alert-badge"></span>
          <button class="jlp-delete-btn" title="Delete this journey">\uD83D\uDDD1\uFE0E</button>
        </div>`;
      row.querySelector('.jlp-delete-btn').addEventListener('click', async (e) => {
        e.stopPropagation();
        const label = date + (dist ? ` · ${dist}` : '');
        if (!confirm(`Delete journey "${label}"?\nThis cannot be undone.`)) return;
        try {
          const res = await fetch(`/api/vehicle-events/journeys/${encodeURIComponent(j.journeyID)}`,
            { method: 'DELETE', headers: authHeaders() });
          if (!res.ok) throw new Error(await res.text());
          row.remove();
          // Remove from overview polylines if shown
          if (allPolylines.has(j.journeyID)) {
            map.removeLayer(allPolylines.get(j.journeyID).polyline);
            allPolylines.delete(j.journeyID);
          }
          clearTrack();
          // If deleted row was selected, auto-select next remaining row
          const rows = [...body.querySelectorAll('.jlp-row')];
          if (!rows.length) { clearTrack(); return; }
          const next = rows[Math.min(idx, rows.length - 1)];
          next?.click();
        } catch (err) { alert(err.message); }
      });
      row.addEventListener('click', () => selectJourney(j, row));
      body.appendChild(row);
      // Auto-select first journey
      if (idx === 0) selectJourney(j, row);
    });

    // ── Overview toggle ──────────────────────────────────────────────────────
    document.getElementById('jlp-all-cb').addEventListener('change', async function() {
      if (this.checked) {
        // Show progress overlay
        const overlay = document.createElement('div');
        overlay.className = 'jlp-all-loading';
        overlay.innerHTML = `<div>Loading tracks\u2026</div><div class="jlp-all-loading-bar"><div class="jlp-all-loading-fill" id="jlp-all-progress" style="width:0%"></div></div><div id="jlp-all-progress-txt" style="font-size:10px;opacity:.7">0\u00a0/\u00a0${journeys.length}</div>`;
        panel.appendChild(overlay);
        // Disable map-match during overview
        const mmCb = document.getElementById('mm-checkbox');
        if (mmCb) { mmCb.disabled = true; mmCb.checked = false; S.mapMatchEnabled = false; }
        // Fetch all tracks
        const allTracks = await fetchAllTracks(journeys, (done, total) => {
          const fill = document.getElementById('jlp-all-progress');
          const txt  = document.getElementById('jlp-all-progress-txt');
          if (fill) fill.style.width = `${Math.round(done / total * 100)}%`;
          if (txt)  txt.textContent  = `${done}\u00a0/\u00a0${total}`;
        });
        overlay.remove();
        // Build polylines first — only switch to overview if we have tracks to show
        const allBounds = [];
        const pendingPolylines = [];
        journeys.forEach((j, idx) => {
          const events = allTracks[idx] || [];
          const lls = events
            .filter(e => e.latitude != null && e.longitude != null)
            .map(e => [e.latitude, e.longitude])
            .filter(([lat, lon]) => isFinite(lat) && isFinite(lon) && !(lat === 0 && lon === 0))
            .filter(([lat, lon], i, arr) => i === 0 || lat !== arr[i-1][0] || lon !== arr[i-1][1]);
          if (lls.length < 2) return;
          const color = JOURNEY_PALETTE[idx % JOURNEY_PALETTE.length];
          const pl = L.polyline(lls, { color, weight: 2.5, opacity: 0.75 });
          pendingPolylines.push({ jid: j.journeyID, polyline: pl, color, lls, idx });
          allBounds.push(...lls);
        });
        // If nothing drawable, abort — keep current single-journey view
        if (!pendingPolylines.length) {
          const cb = panel.querySelector('#jlp-all-cb');
          if (cb) cb.checked = false;
          return;
        }
        // Commit: clear existing track and switch to overview mode
        clearAll();
        pendingPolylines.forEach(({ jid, polyline, color, lls, idx: pidx }) => {
          polyline.addTo(map);
          allPolylines.set(jid, { polyline, color, lls });
          const listRow = body.querySelectorAll('.jlp-row')[pidx];
          if (listRow) { const dot = listRow.querySelector('.jlp-row-color'); if (dot) { dot.style.background = color; dot.style.display = 'block'; } }
        });
        body.classList.add('jlp-overview-mode');
        if (allBounds.length > 1) {
          try { map.fitBounds(allBounds, { padding: [20, 20], maxZoom: 14 }); } catch(_) {}
        }
        S.allJourneysMode = true;
        // Highlight the current active journey
        const activeRow = body.querySelector('.jlp-row.active');
        const activeIdx = activeRow ? [...body.querySelectorAll('.jlp-row')].indexOf(activeRow) : -1;
        if (activeIdx >= 0 && journeys[activeIdx]) {
          allPolylines.forEach(({ polyline }) => polyline.setStyle({ weight: 2, opacity: 0.28 }));
          const jData = allPolylines.get(journeys[activeIdx].journeyID);
          if (jData) jData.polyline.setStyle({ weight: 4.5, opacity: 1.0 });
        }
      } else {
        // Tear down overview mode
        allPolylines.forEach(({ polyline }) => map.removeLayer(polyline));
        allPolylines.clear();
        allBehaviorLayers.forEach(l => map.removeLayer(l));
        allBehaviorLayers = [];
        body.querySelectorAll('.jlp-row-color').forEach(dot => { dot.style.display = 'none'; });
        body.classList.remove('jlp-overview-mode');
        const mmCb = document.getElementById('mm-checkbox');
        if (mmCb) mmCb.disabled = false;
        S.allJourneysMode = false;
        const activeRow = body.querySelector('.jlp-row.active') || body.querySelector('.jlp-row');
        const activeIdx = activeRow ? [...body.querySelectorAll('.jlp-row')].indexOf(activeRow) : 0;
        if (activeRow && journeys[activeIdx]) selectJourney(journeys[activeIdx], activeRow);
      }
    });
  } catch(e) {
    panel.querySelector('.jlp-body').innerHTML = '<div class="jlp-empty">Failed to load journeys.</div>';
    console.error('renderTrackerMap:', e);
  }
}

// ─── Map ──────────────────────────────────────────────────────────────────────
function renderMap() {
  const sensor = S.sensors.find(s => s.sensorID === S.selected);
  if (isTracker(sensor)) { renderTrackerMap(sensor); return; }

  D.mapCont.innerHTML = '';
  const target = sensor?.targetPressureBar ?? null;
  const gps    = S.records.filter(r => r.latitude != null && r.longitude != null);

  if (!gps.length) {
    const isAirtagSensor = sensor?.brand === 'airtag';
    D.mapCont.innerHTML = `
      <div class="map-nodata">
        <div class="nodata-icon">${isAirtagSensor
          ? '<svg width="48" height="48" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.25" stroke-linecap="round" stroke-linejoin="round"><path stroke="none" d="M0 0h24v24H0z" fill="none"/><path d="M18.364 19.364a9 9 0 1 0 -12.728 0"/><path d="M15.536 16.536a5 5 0 1 0 -7.072 0"/><path d="M12 13m-1 0a1 1 0 1 0 2 0a1 1 0 1 0 -2 0"/></svg>'
          : '<svg width="48" height="48" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.25" stroke-linecap="round" stroke-linejoin="round"><path stroke="none" d="M0 0h24v24H0z" fill="none"/><path d="M3.707 6.293l2.586 -2.586a1 1 0 0 1 1.414 0l5 5a1 1 0 0 1 0 1.414l-2.586 2.586a1 1 0 0 1 -1.414 0l-5 -5a1 1 0 0 1 0 -1.414z"/><path d="M6 10l-3 3l3 3l3 -3"/><path d="M10 6l3 -3l3 3l-3 3"/><path d="M12 12l1.5 1.5"/><path d="M14.5 17a2.5 2.5 0 0 0 2.5 -2.5"/><path d="M15 20a5 5 0 0 0 5 -5"/></svg>'
        }</div>
        <p>${isAirtagSensor ? 'No GPS-stamped readings in this period' : 'No GPS data in this period'}</p>
        <small>${isAirtagSensor
          ? 'Proximity and battery readings are in the <b>Events</b> tab. GPS stamps appear when the NetMap app has Location Services access.'
          : 'Enable Location Services in the NetMap app settings and keep scanning.'}</small>
      </div>`;
    return;
  }

  const mapDiv = document.createElement('div');
  mapDiv.id = 'leaflet-map';
  D.mapCont.appendChild(mapDiv);

  if (S.leafletMap) { S.leafletMap.remove(); S.leafletMap = null; }
  const map = S.leafletMap = L.map('leaflet-map', { preferCanvas: false })
    .setView([gps[0].latitude, gps[0].longitude], 14);

  L.tileLayer('https://{s}.tile.openstreetmap.org/{z}/{x}/{y}.png', {
    attribution: '&copy; <a href="https://openstreetmap.org/copyright">OpenStreetMap</a>',
    maxZoom: 19,
  }).addTo(map);

  // ── Travel path ──────────────────────────────────────────────────────────
  const lls = gps.map(r => [r.latitude, r.longitude]);
  if (lls.length > 1) {
    L.polyline(lls, { color: '#636366', weight: 2, opacity: 0.55, dashArray: '5 4' }).addTo(map);
  }

  // ── Cluster nearby points (grid-snap at ~25 m resolution) ────────────────
  const GRID = 0.00025; // ~25 m in lat/lng degrees
  const cellMap = new Map();
  const df = new Intl.DateTimeFormat([], { month: 'short', day: 'numeric', hour: '2-digit', minute: '2-digit', second: '2-digit' });

  gps.forEach((r, idx) => {
    const ck = `${Math.round(r.latitude / GRID)}_${Math.round(r.longitude / GRID)}`;
    if (!cellMap.has(ck)) cellMap.set(ck, { records: [], latSum: 0, lngSum: 0, lastIdx: -1 });
    const c = cellMap.get(ck);
    c.records.push(r);
    c.latSum += r.latitude;
    c.lngSum += r.longitude;
    if (idx > c.lastIdx) c.lastIdx = idx;
  });

  const lastGlobalIdx = gps.length - 1;

  cellMap.forEach(cell => {
    const count   = cell.records.length;
    const lat     = cell.latSum / count;
    const lng     = cell.lngSum / count;
    const isLast  = cell.lastIdx === lastGlobalIdx;
    const recs    = cell.records;
    // Dominant pressure status in this cluster
    const statuses = recs.map(r => pStatus(r.pressureBar, target));
    const priority = ['danger','warn','ok','unknown'];
    const dominant = priority.find(s => statuses.includes(s)) ?? 'unknown';
    const color    = SC[dominant];

    if (count === 1 && !isLast) {
      // Single point — simple circle marker
      const r = recs[0];
      const m = L.circleMarker([lat, lng], {
        radius: 5, fillColor: color, color: '#1c1c1e',
        weight: 1, fillOpacity: 0.85, opacity: 1,
      });
      m.bindPopup(`<div style="font:13px/1.65 system-ui,sans-serif;min-width:140px">
        <b>${df.format(new Date(r.timestamp))}</b><br>
        <svg width="11" height="11" viewBox="0 0 24 24" fill="none" stroke="#60a5fa" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" style="vertical-align:-1px"><path stroke="none" d="M0 0h24v24H0z" fill="none"/><path d="M6.8 11a6 6 0 1 0 10.396 0l-5.197 -8l-5.199 8z"/></svg> <b>${r.pressureBar?.toFixed(3) ?? '–'} bar</b>
        ${r.temperatureC != null ? `<br><svg width="11" height="11" viewBox="0 0 24 24" fill="none" stroke="#fb923c" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" style="vertical-align:-1px"><path stroke="none" d="M0 0h24v24H0z" fill="none"/><path d="M10 13.5a4 4 0 1 0 4 0v-8.5a2 2 0 0 0 -4 0v8.5"/><path d="M10 9l4 0"/></svg> ${r.temperatureC.toFixed(1)} °C` : ''}
        ${r.vbattVolts   != null ? `<br><svg width="11" height="11" viewBox="0 0 24 24" fill="none" stroke="#34d399" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" style="vertical-align:-1px"><path stroke="none" d="M0 0h24v24H0z" fill="none"/><path d="M6 7h11a2 2 0 0 1 2 2v.5a.5 .5 0 0 0 .5 .5a.5 .5 0 0 1 .5 .5v3a.5 .5 0 0 1 -.5 .5a.5 .5 0 0 0 -.5 .5v.5a2 2 0 0 1 -2 2h-11a2 2 0 0 1 -2 -2v-6a2 2 0 0 1 2 -2"/></svg> ${r.vbattVolts.toFixed(2)} V` : ''}
      </div>`).addTo(map);
      return;
    }

    // Cluster bubble — radius grows logarithmically with count
    const bubbleR  = isLast ? 14 : Math.round(10 + Math.log2(count) * 3.5);
    const fontSize = bubbleR < 14 ? 10 : bubbleR < 18 ? 11 : 13;
    const label    = isLast ? '<svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="white" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path stroke="none" d="M0 0h24v24H0z" fill="none"/><path d="M12 11m-3 0a3 3 0 1 0 6 0a3 3 0 0 0 -6 0"/><path d="M17.657 16.657l-4.243 4.243a2 2 0 0 1 -2.827 0l-4.244 -4.243a8 8 0 1 1 11.314 0z"/></svg>' : count;
    const bg       = isLast ? '#30d158' : color;
    const border   = isLast ? '#ffffff' : 'rgba(255,255,255,0.35)';
    const size     = bubbleR * 2;

    const icon = L.divIcon({
      className: '',
      html: `<div style="
        width:${size}px;height:${size}px;border-radius:50%;
        background:${bg};border:2px solid ${border};
        display:flex;align-items:center;justify-content:center;
        font:700 ${fontSize}px system-ui,sans-serif;color:#fff;
        box-shadow:0 2px 8px rgba(0,0,0,.45);
        cursor:pointer;
      ">${label}</div>`,
      iconSize: [size, size],
      iconAnchor: [bubbleR, bubbleR],
      popupAnchor: [0, -bubbleR],
    });

    // Summary popup for cluster
    const pressures = recs.map(r => r.pressureBar).filter(v => v != null);
    const avgP = pressures.length ? (pressures.reduce((a,b)=>a+b,0)/pressures.length).toFixed(3) : '–';
    const minP = pressures.length ? Math.min(...pressures).toFixed(3) : '–';
    const maxP = pressures.length ? Math.max(...pressures).toFixed(3) : '–';
    const first = recs[0], last = recs.at(-1);
    const popup = `<div style="font:13px/1.65 system-ui,sans-serif;min-width:160px">
      ${isLast ? '<span style="color:#1A8C4E;font-weight:700">● Latest position</span><br>' : ''}
      <b>${count} reading${count > 1 ? 's' : ''}</b><br>
      <svg width="11" height="11" viewBox="0 0 24 24" fill="none" stroke="#8a8d9e" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" style="vertical-align:-1px"><path stroke="none" d="M0 0h24v24H0z" fill="none"/><path d="M3 12a9 9 0 1 0 18 0a9 9 0 0 0 -18 0"/><path d="M12 7v5l3 3"/></svg> ${df.format(new Date(first.timestamp))}${count > 1 ? `<br>&nbsp;&nbsp;&nbsp;&nbsp;→ ${df.format(new Date(last.timestamp))}` : ''}<br>
      <svg width="11" height="11" viewBox="0 0 24 24" fill="none" stroke="#60a5fa" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" style="vertical-align:-1px"><path stroke="none" d="M0 0h24v24H0z" fill="none"/><path d="M6.8 11a6 6 0 1 0 10.396 0l-5.197 -8l-5.199 8z"/></svg> avg <b>${avgP} bar</b> · min ${minP} · max ${maxP}
      ${last.temperatureC != null ? `<br><svg width="11" height="11" viewBox="0 0 24 24" fill="none" stroke="#fb923c" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" style="vertical-align:-1px"><path stroke="none" d="M0 0h24v24H0z" fill="none"/><path d="M10 13.5a4 4 0 1 0 4 0v-8.5a2 2 0 0 0 -4 0v8.5"/><path d="M10 9l4 0"/></svg> ${last.temperatureC.toFixed(1)} °C` : ''}
      ${last.vbattVolts   != null ? `<br><svg width="11" height="11" viewBox="0 0 24 24" fill="none" stroke="#34d399" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" style="vertical-align:-1px"><path stroke="none" d="M0 0h24v24H0z" fill="none"/><path d="M6 7h11a2 2 0 0 1 2 2v.5a.5 .5 0 0 0 .5 .5a.5 .5 0 0 1 .5 .5v3a.5 .5 0 0 1 -.5 .5a.5 .5 0 0 0 -.5 .5v.5a2 2 0 0 1 -2 2h-11a2 2 0 0 1 -2 -2v-6a2 2 0 0 1 2 -2"/></svg> ${last.vbattVolts.toFixed(2)} V` : ''}
    </div>`;

    L.marker([lat, lng], { icon }).bindPopup(popup).addTo(map);
  });

  try { map.fitBounds(lls, { padding: [30, 30], maxZoom: 16 }); } catch (_) {}
}

// ─── Table ────────────────────────────────────────────────────────────────────
async function renderTable() {
  const sensor = S.sensors.find(s => s.sensorID === S.selected);
  document.getElementById('data-table')?.classList.toggle('ev-compact', !!isTracker(sensor));
  const target = sensor?.targetPressureBar ?? null;
  const df     = new Intl.DateTimeFormat([], { dateStyle: 'short', timeStyle: 'medium' });
  const rows   = [...S.records].reverse().slice(0, 2000);
  const tblToolbar = D.tableCont.querySelector('.table-toolbar');
  if (tblToolbar) tblToolbar.style.display = '';

  if (isTracker(sensor)) {
    // Skeleton while loading
    $('table-head').innerHTML = '<tr><th colspan="11"></th></tr>';
    D.tableBody.innerHTML = skeletonRows(11);

    let events = [];
    let allEvents = [];
    let lifecycleEvents = [];
    let alertEvents     = [];
    const GPS_TYPES = ['gps_acquired', 'gps_lost'];
    const showSysEvents = () => localStorage.getItem('ev_show_system') === '1';
    const showErrors    = () => localStorage.getItem('ev_show_errors')  === '1';
    const showAlerts    = () => localStorage.getItem('ev_show_alerts')  === '1';
    try {
      const { from, to } = getRange();
      events = await apiFetch(`/api/vehicle-events?imei=${encodeURIComponent(sensor.sensorID)}&from=${encodeURIComponent(from.toISOString())}&to=${encodeURIComponent(to.toISOString())}&limit=2000`);
      allEvents = events.sort((a, b) => new Date(a.timestamp) - new Date(b.timestamp)).reverse();
      if (showSysEvents()) {
        const lc = await apiFetch(`/api/device-lifecycle?imei=${encodeURIComponent(sensor.sensorID)}&since=${encodeURIComponent(from.toISOString())}&limit=500`).catch(() => []);
        lifecycleEvents = lc.filter(e => new Date(e.timestamp) <= to).map(e => ({ ...e, _src: 'lifecycle' }));
      }
      if (showAlerts()) {
        const al = await apiFetch(`/api/driver-behavior?imei=${encodeURIComponent(sensor.sensorID)}&limit=1000`).catch(() => []);
        alertEvents = al.map(b => ({ ...b, _src: 'alert' }));
      }
      let evBase = showSysEvents() ? [...allEvents, ...lifecycleEvents] : allEvents.filter(e => !GPS_TYPES.includes(e.eventType));
      if (showAlerts()) evBase = [...evBase, ...alertEvents];
      events = evBase.sort((a, b) => new Date(b.timestamp) - new Date(a.timestamp));
    } catch(err) {
      D.tableBody.innerHTML = `<tr><td colspan="11" style="color:var(--danger)">${escHTML(err.message)}</td></tr>`;
      return;
    }

    {
      const EVENT_LABELS = {
        journey_start:  { icon: '<svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path stroke="none" d="M0 0h24v24H0z" fill="none"/><path d="M5 14h14v-9h-14v16"/></svg>',   label: 'Journey start', color: '#34d399' },
        driving:        { icon: '<svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path stroke="none" d="M0 0h24v24H0z" fill="none"/><path d="M3 12a9 9 0 1 0 18 0a9 9 0 1 0 -18 0"/><path d="M10 12a2 2 0 1 0 4 0a2 2 0 1 0 -4 0"/><path d="M12 14l0 7"/><path d="M10 12l-6.75 -2"/><path d="M14 12l6.75 -2"/></svg>', label: 'Driving',       color: '#60a5fa' },
        journey_end:    { icon: '<svg width="14" height="14" viewBox="0 0 24 24" fill="currentColor" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path stroke="none" d="M0 0h24v24H0z" fill="none"/><path d="M5 14h14v-9h-14v16"/></svg>',    label: 'Journey end',   color: '#f87171' },
        idle_start:     { icon: '<svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path stroke="none" d="M0 0h24v24H0z" fill="none"/><path d="M6.5 7h11"/><path d="M6.5 17h11"/><path d="M6 20v-2a6 6 0 1 1 12 0v2a1 1 0 0 1 -1 1h-10a1 1 0 0 1 -1 -1"/><path d="M6 4v2a6 6 0 1 0 12 0v-2a1 1 0 0 0 -1 -1h-10a1 1 0 0 0 -1 1"/></svg>',      label: 'Idle start',    color: '#a78bfa' },
        idle_end:       { icon: '<svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path stroke="none" d="M0 0h24v24H0z" fill="none"/><path d="M6.5 7h11"/><path d="M6.5 17h11"/><path d="M6 20v-2a6 6 0 1 1 12 0v2a1 1 0 0 1 -1 1h-10a1 1 0 0 1 -1 -1"/><path d="M6 4v2a6 6 0 1 0 12 0v-2a1 1 0 0 0 -1 -1h-10a1 1 0 0 0 -1 1"/></svg>',      label: 'Idle end',      color: '#a78bfa' },
        stopped:        { icon: '<svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path stroke="none" d="M0 0h24v24H0z" fill="none"/><rect x="4" y="4" width="16" height="16" rx="2"/></svg>',                                   label: 'Stopped',       color: '#fb923c' },
        gps_acquired:   { icon: '<svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path stroke="none" d="M0 0h24v24H0z" fill="none"/><path d="M3.707 6.293l2.586 -2.586a1 1 0 0 1 1.414 0l5 5a1 1 0 0 1 0 1.414l-2.586 2.586a1 1 0 0 1 -1.414 0l-5 -5a1 1 0 0 1 0 -1.414z"/><path d="M6 10l-3 3l3 3l3 -3"/><path d="M10 6l3 -3l3 3l-3 3"/><path d="M12 20l4 -4"/><path d="M14 20l5 -5"/></svg>',  label: 'GPS acquired',  color: '#34d399' },
        gps_lost:       { icon: '<svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path stroke="none" d="M0 0h24v24H0z" fill="none"/><path d="M3.707 6.293l2.586 -2.586a1 1 0 0 1 1.414 0l5 5a1 1 0 0 1 0 1.414l-2.586 2.586a1 1 0 0 1 -1.414 0l-5 -5a1 1 0 0 1 0 -1.414z"/><path d="M6 10l-3 3l3 3l3 -3"/><path d="M10 6l3 -3l3 3l-3 3"/><path d="M12 20l4 -4"/><path d="M14 20l5 -5"/><path d="M3 3l18 18"/></svg>',      label: 'GPS lost',      color: '#f87171' },
        ping:           { icon: '<svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path stroke="none" d="M0 0h24v24H0z" fill="none"/><path d="M18.364 5.636a9 9 0 0 1 0 12.728"/><path d="M15.536 8.464a5 5 0 0 1 0 7.072"/><path d="M12 11m-1 0a1 1 0 1 0 2 0a1 1 0 1 0 -2 0"/><path d="M5.636 5.636a9 9 0 0 0 0 12.728"/><path d="M8.464 8.464a5 5 0 0 0 0 7.072"/></svg>', label: 'Ping',          color: '#22d3ee' },
        boot:           { icon: '<svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path stroke="none" d="M0 0h24v24H0z" fill="none"/><path d="M7 6a7.75 7.75 0 1 0 10 0"/><path d="M12 4l0 8"/></svg>',   label: 'Boot',          color: '#a78bfa' },
        sleep:          { icon: '<svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path stroke="none" d="M0 0h24v24H0z" fill="none"/><path d="M4 12h6l-6 8h6"/><path d="M14 4h6l-6 8h6"/></svg>',     label: 'Sleep',         color: '#94a3b8' },
        wake_up:        { icon: '<svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path stroke="none" d="M0 0h24v24H0z" fill="none"/><path d="M3 17h1m16 0h1m-15.4 -6.4l.7 .7m12.1 -.7l-.7 .7m-9.7 5.7a4 4 0 0 1 8 0"/><path d="M3 21l18 0"/><path d="M12 9v-6l3 3m-6 0l3 -3"/></svg>', label: 'Wake up',       color: '#fbbf24' },
        config_pushed:  { icon: '<svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path stroke="none" d="M0 0h24v24H0z" fill="none"/><path d="M4 17v2a2 2 0 0 0 2 2h12a2 2 0 0 0 2 -2v-2"/><path d="M7 11l5 5l5 -5"/><path d="M12 4l0 12"/></svg>', label: 'Config sent',   color: '#818cf8' },
        config_acked:   { icon: '<svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path stroke="none" d="M0 0h24v24H0z" fill="none"/><path d="M5 12l5 5l10 -10"/></svg>', label: 'Config acked',  color: '#34d399' },
      };
      const SYS_EVENT_TYPES_WITH_DETAIL = new Set(['config_pushed', 'config_acked']);
      const SYS_EVENT_DETAIL_ICONS = {
        config_pushed: `<svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path stroke="none" d="M0 0h24v24H0z" fill="none"/><path d="M14 6m-2 0a2 2 0 1 0 4 0a2 2 0 1 0 -4 0"/><path d="M4 6l8 0"/><path d="M16 6l4 0"/><path d="M8 12m-2 0a2 2 0 1 0 4 0a2 2 0 1 0 -4 0"/><path d="M4 12l2 0"/><path d="M10 12l10 0"/><path d="M17 18m-2 0a2 2 0 1 0 4 0a2 2 0 1 0 -4 0"/><path d="M4 18l11 0"/><path d="M19 18l1 0"/></svg>`,
        config_acked:  `<svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path stroke="none" d="M0 0h24v24H0z" fill="none"/><path d="M3.5 5.5l1.5 1.5l2.5 -2.5"/><path d="M3.5 11.5l1.5 1.5l2.5 -2.5"/><path d="M3.5 17.5l1.5 1.5l2.5 -2.5"/><path d="M11 6l9 0"/><path d="M11 12l9 0"/><path d="M11 18l9 0"/></svg>`,
      };

      function fmtDelay(sec) {
        if (sec < 60)   return sec + 's';
        if (sec < 3600) return Math.round(sec / 60) + 'm';
        if (sec < 86400) return Math.round(sec / 3600) + 'h';
        return Math.round(sec / 86400) + 'd';
      }
      function delayCell(e) {
        if (!e.receivedAt) return `<td class="td-delay" title="No reception timestamp">–</td>`;
        const sec = (new Date(e.receivedAt) - new Date(e.timestamp)) / 1000;
        if (sec < -5)  return `<td class="td-delay td-delay-bad" title="Event timestamp is AFTER reception (device clock issue): ${fmtDelay(Math.abs(sec))}">⚠ invalid</td>`;
        let cls, tip;
        if      (sec <  30)   { cls = 'td-delay-rt';  tip = 'Real-time (< 30 s)'; }
        else if (sec <  300)  { cls = 'td-delay-ok';  tip = 'Near real-time (< 5 min)'; }
        else if (sec < 3600)  { cls = 'td-delay-mid'; tip = 'Delayed (< 1 h)'; }
        else if (sec < 86400) { cls = 'td-delay-hi';  tip = 'Highly delayed (< 24 h)'; }
        else                  { cls = 'td-delay-off';  tip = 'Offline batch (> 24 h)'; }
        return `<td class="td-delay ${cls}" title="${escAttr(tip)} — received ${fmtDelay(sec)} after generation">${fmtDelay(sec)}</td>`;
      }

      function renderEventRows(evList) {
        const hasSatsL    = evList.some(e => e.gpsSatellites != null);
        const hasSpeedL   = evList.some(e => e.speedKmh != null);
        const hasOdoL     = evList.some(e => e.odometerKm != null);
        const hasDistL    = evList.some(e => e.journeyDistanceKm != null);
        const hasRpmL     = evList.some(e => e.engineRpm != null);
        const hasJFuelL   = evList.some(e => e.journeyFuelConsumedL != null);
        const hasFuelL    = evList.some(e => e.fuelLevelPct != null);
        const hasObfcmD   = true;  // always show OBFCM lifetime columns
        const hasObfcmF   = true;

        const hdrs2 = ['Time', 'Delay', 'Event', 'GPS'];
        if (hasSatsL)    hdrs2.push('Sats');
        if (hasSpeedL)   hdrs2.push('Speed');
        if (hasOdoL)     hdrs2.push('Odometer');
        if (hasDistL)    hdrs2.push('Trip dist.');
        if (hasRpmL)     hdrs2.push('RPM');
        if (hasJFuelL)   hdrs2.push('Trip fuel');
        if (hasFuelL)    hdrs2.push('Fuel %');
        if (hasObfcmD)   hdrs2.push('OBFCM dist.');
        if (hasObfcmF)   hdrs2.push('OBFCM fuel');
        hdrs2.push('');
        const colCount2 = hdrs2.length;
        $('table-head').innerHTML = `<tr>${hdrs2.map(h => `<th>${h}</th>`).join('')}</tr>`;

        let lastJID2 = null;
        D.tableBody.innerHTML = evList.map((e, idx) => {
          let sep = '';
          if (e.journeyID && e.journeyID !== lastJID2) {
            if (idx > 0) sep = `<tr class="journey-sep-row"><td colspan="${colCount2}"></td></tr>`;
            lastJID2 = e.journeyID;
          }
          if (e._src === 'alert') {
            const cfg    = BEHAVIOR_CONFIG[e.alertType] || BEHAVIOR_CONFIG.unknown;
            const svgIco = BEHAVIOR_SVG[e.alertType]   || BEHAVIOR_SVG.unknown;
            const evColor = safeCssColor(cfg.color) || 'var(--fg2)';
            const fuelCol = e.fuelLevelPct != null
              ? (e.fuelLevelPct > 50 ? '#34d399' : e.fuelLevelPct > 20 ? '#fbbf24' : '#f87171') : '';
            let cells = `<td class="td-ts-compact">${fmtTs(e.timestamp)}</td>`;
            cells += delayCell(e);
            cells += `<td><span style="display:inline-flex;align-items:center;gap:4px"><span class="ev-badge" style="--ev-color:${evColor}">${svgIco} ${escHTML(cfg.label)}</span><button class="row-alert-detail-btn" data-alert-id="${escAttr(e.id)}" title="Alert details"><svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path stroke="none" d="M0 0h24v24H0z" fill="none"/><path d="M12 9h.01"/><path d="M11 12h1v4h1"/><path d="M12 3c7.2 0 9 1.8 9 9s-1.8 9 -9 9s-9 -1.8 -9 -9s1.8 -9 9 -9z"/></svg></button></span></td>`;
            cells += `<td>${gpsCell(e)}</td>`;
            if (hasSatsL)  cells += `<td>${e.gpsSatellites != null ? e.gpsSatellites : '–'}</td>`;
            if (hasSpeedL) cells += `<td>${e.speedKmh != null ? e.speedKmh.toFixed(0) + '\u00a0km/h' : '–'}</td>`;
            if (hasOdoL)   cells += `<td>${e.odometerKm != null ? e.odometerKm.toFixed(1) + '\u00a0km' : '–'}</td>`;
            if (hasDistL)  cells += `<td>${e.journeyDistanceKm != null ? e.journeyDistanceKm.toFixed(2) + '\u00a0km' : '–'}</td>`;
            if (hasRpmL)   cells += `<td>${e.engineRpm != null ? e.engineRpm.toLocaleString() + '\u00a0rpm' : '–'}</td>`;
            if (hasJFuelL) cells += `<td>${e.journeyFuelConsumedL != null ? e.journeyFuelConsumedL.toFixed(3) + '\u00a0L' : '–'}</td>`;
            if (hasFuelL)  cells += `<td${fuelCol ? ` style="color:${fuelCol}"` : ''}>${e.fuelLevelPct != null ? e.fuelLevelPct + '%' : '–'}</td>`;
            if (hasObfcmD) cells += `<td>${e.obfcmDistanceKm != null ? e.obfcmDistanceKm.toFixed(1) + '\u00a0km' : '–'}</td>`;
            if (hasObfcmF) cells += `<td>${e.obfcmFuelL != null ? e.obfcmFuelL.toFixed(2) + '\u00a0L' : '–'}</td>`;
            cells += `<td><button class="row-delete-btn" data-id="${escAttr(e.id)}" data-src="alert" title="Delete"><svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path stroke="none" d="M0 0h24v24H0z" fill="none"/><path d="M4 7l16 0"/><path d="M10 11l0 6"/><path d="M14 11l0 6"/><path d="M5 7l1 12a2 2 0 0 0 2 2h8a2 2 0 0 0 2 -2l1 -12"/><path d="M9 7v-3a1 1 0 0 1 1 -1h4a1 1 0 0 1 1 1v3"/></svg></button></td>`;
            return sep + `<tr class="ev-alert-row" data-alert-id="${escAttr(e.id)}">${cells}</tr>`;
          }
          const ev2     = EVENT_LABELS[e.eventType] ?? { icon: '○', label: e.eventType ?? '–', color: 'var(--fg2)' };
          const fuelCol = e.fuelLevelPct != null
            ? (e.fuelLevelPct > 50 ? '#34d399' : e.fuelLevelPct > 20 ? '#fbbf24' : '#f87171') : '';
          const evColor = safeCssColor(ev2.color) || 'var(--fg2)';
          const hasSysDetail = SYS_EVENT_TYPES_WITH_DETAIL.has(e.eventType) && e.metadataJSON;
          let cells = `<td class="td-ts-compact">${fmtTs(e.timestamp)}</td>`;
          cells += delayCell(e);
          if (hasSysDetail) {
            const detailIcon = SYS_EVENT_DETAIL_ICONS[e.eventType] ?? '';
            cells += `<td><span style="display:inline-flex;align-items:center;gap:4px"><span class="ev-badge" style="--ev-color:${evColor}">${ev2.icon} ${escHTML(ev2.label)}</span><button class="row-sysev-detail-btn" data-ev-id="${escAttr(e.id)}" title="View details">${detailIcon}</button></span></td>`;
          } else {
            cells += `<td><span class="ev-badge" style="--ev-color:${evColor}">${ev2.icon} ${escHTML(ev2.label)}</span></td>`;
          }
          cells += `<td>${gpsCell(e)}</td>`;
          if (hasSatsL)    cells += `<td>${e.gpsSatellites != null ? e.gpsSatellites : '–'}</td>`;
          if (hasSpeedL)   cells += `<td>${e.speedKmh != null ? e.speedKmh.toFixed(0) + ' km/h' : '–'}</td>`;
          if (hasOdoL)     cells += `<td>${e.odometerKm != null ? e.odometerKm.toFixed(1) + ' km' : '–'}</td>`;
          if (hasDistL)    cells += `<td>${e.journeyDistanceKm != null ? e.journeyDistanceKm.toFixed(2) + ' km' : '–'}</td>`;
          if (hasRpmL)     cells += `<td>${e.engineRpm != null ? e.engineRpm.toLocaleString() + ' rpm' : '–'}</td>`;
          if (hasJFuelL)   cells += `<td>${e.journeyFuelConsumedL != null ? e.journeyFuelConsumedL.toFixed(3) + ' L' : '–'}</td>`;
          if (hasFuelL)    cells += `<td${fuelCol ? ` style="color:${fuelCol}"` : ''}>${e.fuelLevelPct != null ? e.fuelLevelPct + '%' : '–'}</td>`;
          if (hasObfcmD)   cells += `<td>${e.obfcmDistanceKm != null ? e.obfcmDistanceKm.toFixed(1) + ' km' : '–'}</td>`;
          if (hasObfcmF)   cells += `<td>${e.obfcmFuelL != null ? e.obfcmFuelL.toFixed(2) + ' L' : '–'}</td>`;
          cells += `<td><button class="row-delete-btn" data-id="${escAttr(e.id)}" data-src="${e._src === 'lifecycle' ? 'lifecycle' : 'vehicle'}" title="Delete"><svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path stroke="none" d="M0 0h24v24H0z" fill="none"/><path d="M4 7l16 0"/><path d="M10 11l0 6"/><path d="M14 11l0 6"/><path d="M5 7l1 12a2 2 0 0 0 2 2h8a2 2 0 0 0 2 -2l1 -12"/><path d="M9 7v-3a1 1 0 0 1 1 -1h4a1 1 0 0 1 1 1v3"/></svg></button></td>`;
          return sep + `<tr data-ev-id="${escAttr(e.id)}">${cells}</tr>`;
        }).join('');

        D.tableBody.querySelectorAll('.row-delete-btn').forEach(btn => {
          btn.addEventListener('click', async evClick => {
            const row = evClick.target.closest('tr');
            const id  = btn.dataset.id;
            if (!id) return;
            let url;
            if (btn.dataset.src === 'lifecycle') url = `/api/device-lifecycle/${id}`;
            else if (btn.dataset.src === 'alert') url = `/api/driver-behavior/${id}`;
            else url = `/api/vehicle-events/${id}`;
            const res = await fetch(url, { method: 'DELETE', headers: authHeaders() });
            if (res.ok || res.status === 204) {
              // also remove expanded detail row if present
              row.nextElementSibling?.classList.contains('ev-alert-detail-expanded') && row.nextElementSibling.remove();
              row.remove(); showToast('Event deleted');
            }
            else showToast('Delete failed', 'error');
          });
        });

        // System event detail expand (config_pushed / config_acked)
        D.tableBody.querySelectorAll('.row-sysev-detail-btn').forEach(btn => {
          btn.addEventListener('click', () => {
            const tr = btn.closest('tr');
            const existing = tr.nextElementSibling;
            if (existing?.classList.contains('ev-alert-detail-expanded')) {
              existing.remove(); btn.classList.remove('active'); return;
            }
            btn.classList.add('active');
            const evId = btn.dataset.evId;
            const ev = [...lifecycleEvents].find(e => String(e.id) === String(evId));
            if (!ev?.metadataJSON) return;
            let meta;
            try { meta = JSON.parse(ev.metadataJSON); } catch { meta = {}; }
            const chips = [];
            if (meta.config_version   != null) chips.push(`<span class="ev-alerts-detail-chip"><b>Version:</b> ${escHTML(String(meta.config_version))}</span>`);
            if (meta.server_version   != null) chips.push(`<span class="ev-alerts-detail-chip"><b>Server v:</b> ${escHTML(String(meta.server_version))}</span>`);
            if (meta.status           != null) {
              const ok = meta.status === 'ok';
              chips.push(`<span class="ev-alerts-detail-chip" style="color:${ok ? 'var(--ok)' : '#fbbf24'}"><b>Status:</b> ${escHTML(meta.status)}</span>`);
            }
            if (meta.ping_interval_min  != null) chips.push(`<span class="ev-alerts-detail-chip"><b>Ping:</b> ${escHTML(String(meta.ping_interval_min))} min</span>`);
            if (meta.sleep_delay_min    != null) chips.push(`<span class="ev-alerts-detail-chip"><b>Sleep:</b> ${escHTML(String(meta.sleep_delay_min))} min</span>`);
            if (Array.isArray(meta.wake_sources) && meta.wake_sources.length) chips.push(`<span class="ev-alerts-detail-chip"><b>Wake:</b> ${escHTML(meta.wake_sources.join(', '))}</span>`);
            if (meta.th_harsh_braking   != null) chips.push(`<span class="ev-alerts-detail-chip"><b>Braking:</b> ${escHTML(String(meta.th_harsh_braking))}</span>`);
            if (meta.th_harsh_accel     != null) chips.push(`<span class="ev-alerts-detail-chip"><b>Accel:</b> ${escHTML(String(meta.th_harsh_accel))}</span>`);
            if (meta.th_harsh_cornering != null) chips.push(`<span class="ev-alerts-detail-chip"><b>Cornering:</b> ${escHTML(String(meta.th_harsh_cornering))}</span>`);
            if (meta.th_overspeed_kmh   != null) chips.push(`<span class="ev-alerts-detail-chip"><b>Overspeed:</b> ${escHTML(String(meta.th_overspeed_kmh))} km/h</span>`);
            if (meta.min_speed_kmh      != null) chips.push(`<span class="ev-alerts-detail-chip"><b>Min speed:</b> ${escHTML(String(meta.min_speed_kmh))} km/h</span>`);
            if (meta.beep_enabled       != null) chips.push(`<span class="ev-alerts-detail-chip"><b>Beep:</b> ${meta.beep_enabled ? 'on' : 'off'}</span>`);
            const colCount = $('table-head').querySelectorAll('th').length;
            const detailTr = document.createElement('tr');
            detailTr.className = 'ev-alert-detail-expanded';
            detailTr.innerHTML = `<td class="ev-alert-detail-cell" colspan="${colCount}"><div class="ev-alert-detail-content">${chips.join('') || 'No details'}</div></td>`;
            tr.insertAdjacentElement('afterend', detailTr);
          });
        });

        D.tableBody.querySelectorAll('.row-alert-detail-btn').forEach(btn => {
          btn.addEventListener('click', () => {
            const tr = btn.closest('tr');
            const existing = tr.nextElementSibling;
            if (existing?.classList.contains('ev-alert-detail-expanded')) {
              existing.remove();
              btn.classList.remove('active');
              return;
            }
            btn.classList.add('active');
            const alertId = btn.dataset.alertId;
            const b = alertEvents.find(a => String(a.id) === String(alertId));
            if (!b) return;
            const cfg    = BEHAVIOR_CONFIG[b.alertType] || BEHAVIOR_CONFIG.unknown;
            const durS   = b.alertDurationMs != null ? (b.alertDurationMs / 1000).toFixed(1) + '\u00a0s' : null;
            const val    = b.alertValueMax   != null ? b.alertValueMax : null;
            const valStr = val != null ? (cfg.unit ? `${val.toFixed(2)}\u00a0${cfg.unit}` : val.toFixed(2)) : null;
            const spd    = b.speedKmh        != null ? `${b.speedKmh.toFixed(0)}\u00a0km/h` : null;
            const hdg    = b.headingDeg      != null ? `${Math.round(b.headingDeg)}\u00b0` : null;
            const chips  = [
              valStr ? `<span class="ev-alerts-detail-chip"><b>Peak:</b> ${escHTML(valStr)}</span>` : '',
              durS   ? `<span class="ev-alerts-detail-chip"><b>Duration:</b> ${escHTML(durS)}</span>` : '',
              spd    ? `<span class="ev-alerts-detail-chip"><b>Speed:</b> ${escHTML(spd)}</span>` : '',
            ].filter(Boolean).join('');
            const colCount = $('table-head').querySelectorAll('th').length;
            const detailTr = document.createElement('tr');
            detailTr.className = 'ev-alert-detail-expanded';
            detailTr.innerHTML = `<td class="ev-alert-detail-cell" colspan="${colCount}"><div class="ev-alert-detail-content">${chips || 'No additional details available'}</div></td>`;
            tr.insertAdjacentElement('afterend', detailTr);
          });
        });
      }

      // Delete period toolbar + system-events toggle + event-type filter
      D.tableCont.querySelector('#events-period-toolbar')?.remove();
      const evToolbar = document.createElement('div');
      evToolbar.id = 'events-period-toolbar';
      evToolbar.className = 'tab-action-toolbar';
      const { from: evFrom, to: evTo } = getRange();
      const dfShortEv = new Intl.DateTimeFormat([], { month: 'short', day: 'numeric', hour: '2-digit', minute: '2-digit' });

      // Unique event types from loaded events (GPS events excluded)
      const uniqueEvTypes = [...new Set(allEvents.map(e => e.eventType).filter(Boolean))]
        .filter(t => !GPS_TYPES.includes(t)).sort();
      const typeCheckboxesHtml = uniqueEvTypes.map(t => {
        const lbl = EVENT_LABELS[t]?.label ?? t;
        return `<label class="ev-type-cb-row"><input type="checkbox" class="ev-type-cb" value="${escAttr(t)}" checked> ${escHTML(lbl)}</label>`;
      }).join('');

      evToolbar.innerHTML =
        `<span id="ev-toolbar-info"></span>` +
        (uniqueEvTypes.length
          ? `<div class="ev-type-filter-wrap" id="ev-type-filter-wrap"><button type="button" id="ev-type-filter-btn" class="admin-small-btn">All types <svg width="10" height="10" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="3" stroke-linecap="round" stroke-linejoin="round" style="vertical-align:-1px"><path d="M6 9l6 6 6-6"/></svg></button><div id="ev-type-dropdown" class="ev-type-dropdown" style="display:none">${typeCheckboxesHtml}</div></div>`
          : '') +
        `<div class="ev-pill-toggles">` +
        `<button type="button" id="ev-show-system" class="ev-pill-toggle${showSysEvents() ? ' active' : ''}" title="Lifecycle events: boot / sleep / wake / ping"><svg width="13" height="13" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path stroke="none" d="M0 0h24v24H0z" fill="none"/><path d="M10.325 4.317c.426 -1.756 2.924 -1.756 3.35 0a1.724 1.724 0 0 0 2.573 1.066c1.543 -.94 3.31 .826 2.37 2.37a1.724 1.724 0 0 0 1.065 2.572c1.756 .426 1.756 2.924 0 3.35a1.724 1.724 0 0 0 -1.066 2.573c.94 1.543 -.826 3.31 -2.37 2.37a1.724 1.724 0 0 0 -2.572 1.065c-.426 1.756 -2.924 1.756 -3.35 0a1.724 1.724 0 0 0 -2.573 -1.066c-1.543 .94 -3.31 -.826 -2.37 -2.37a1.724 1.724 0 0 0 -1.065 -2.572c-1.756 -.426 -1.756 -2.924 0 -3.35a1.724 1.724 0 0 0 1.066 -2.573c-.94 -1.543 .826 -3.31 2.37 -2.37a1.724 1.724 0 0 0 2.573 -1.066z"/><path d="M9 12a3 3 0 1 0 6 0a3 3 0 0 0 -6 0"/></svg> System</button>` +
        `<button type="button" id="ev-show-errors" class="ev-pill-toggle ev-pill-errors${showErrors() ? ' active' : ''}" title="Events with invalid timestamp (device clock issue)"><svg width="13" height="13" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path stroke="none" d="M0 0h24v24H0z" fill="none"/><path d="M12 9v4"/><path d="M10.363 3.591l-8.106 13.534a1.914 1.914 0 0 0 1.636 2.871h16.214a1.914 1.914 0 0 0 1.636 -2.87l-8.106 -13.536a1.914 1.914 0 0 0 -3.274 0"/><path d="M12 16h.01"/></svg> Errors</button>` +
        `<button type="button" id="ev-show-alerts" class="ev-pill-toggle ev-pill-alerts${showAlerts() ? ' active' : ''}" title="Driver behaviour alerts"><svg width="13" height="13" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path stroke="none" d="M0 0h24v24H0z" fill="none"/><path d="M12 9v4"/><path d="M10.363 3.591l-8.106 13.534a1.914 1.914 0 0 0 1.636 2.871h16.214a1.914 1.914 0 0 0 1.636 -2.87l-8.106 -13.536a1.914 1.914 0 0 0 -3.274 0"/><path d="M12 16h.01"/></svg> Alerts</button>` +
        `</div>` +
        `<button class="modal-btn-danger admin-small-btn"><svg width="13" height="13" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" style="vertical-align:-1px"><path stroke="none" d="M0 0h24v24H0z" fill="none"/><path d="M4 7l16 0"/><path d="M10 11l0 6"/><path d="M14 11l0 6"/><path d="M5 7l1 12a2 2 0 0 0 2 2h8a2 2 0 0 0 2 -2l1 -12"/><path d="M9 7v-3a1 1 0 0 1 1 -1h4a1 1 0 0 1 1 1v3"/></svg> Delete all</button>` +
        `<button class="ev-export-csv-btn modal-btn admin-small-btn"><svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" style="vertical-align:-1px"><path stroke="none" d="M0 0h24v24H0z" fill="none"/><path d="M4 17v2a2 2 0 0 0 2 2h12a2 2 0 0 0 2 -2v-2"/><path d="M7 11l5 5l5 -5"/><path d="M12 4l0 12"/></svg> Export CSV</button>`;
      D.tableCont.prepend(evToolbar);
      if (tblToolbar) tblToolbar.style.display = 'none';
      evToolbar.querySelector('.ev-export-csv-btn')?.addEventListener('click', exportCSV);

      function getSelectedTypes() {
        const allCbs = [...evToolbar.querySelectorAll('.ev-type-cb')];
        if (!allCbs.length) return null;
        const checked = allCbs.filter(cb => cb.checked).map(cb => cb.value);
        return checked.length === allCbs.length ? null : checked;
      }

      function updateTypeBtn() {
        const allCbs = [...evToolbar.querySelectorAll('.ev-type-cb')];
        if (!allCbs.length) return;
        const checked = allCbs.filter(cb => cb.checked);
        const btn = evToolbar.querySelector('#ev-type-filter-btn');
        if (!btn) return;
        const chevron = `<svg width="10" height="10" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="3" stroke-linecap="round" stroke-linejoin="round" style="vertical-align:-1px"><path d="M6 9l6 6 6-6"/></svg>`;
        btn.innerHTML = (checked.length === allCbs.length ? 'All types' : `${checked.length} type${checked.length !== 1 ? 's' : ''}`) + ' ' + chevron;
      }

      async function getBaseEvents() {
        if (showSysEvents() && !lifecycleEvents.length) {
          const lc = await apiFetch(`/api/device-lifecycle?imei=${encodeURIComponent(sensor.sensorID)}&since=${encodeURIComponent(evFrom.toISOString())}&limit=500`).catch(() => []);
          lifecycleEvents = lc.filter(e => new Date(e.timestamp) <= evTo).map(e => ({ ...e, _src: 'lifecycle' }));
        }
        if (showAlerts() && !alertEvents.length) {
          const al = await apiFetch(`/api/driver-behavior?imei=${encodeURIComponent(sensor.sensorID)}&limit=1000`).catch(() => []);
          alertEvents = al.map(b => ({ ...b, _src: 'alert' }));
        }
        let base = showSysEvents() ? [...allEvents, ...lifecycleEvents] : allEvents.filter(e => !GPS_TYPES.includes(e.eventType));
        if (showAlerts()) base = [...base, ...alertEvents];
        return base.sort((a, b) => new Date(b.timestamp) - new Date(a.timestamp));
      }

      function applyFilters(base) {
        const selectedTypes = getSelectedTypes();
        const filtered = selectedTypes ? base.filter(e => selectedTypes.includes(e.eventType)) : base;
        if (!filtered.length) {
          $('table-head').innerHTML = '<tr><th>Time</th><th>Delay</th><th>Event</th><th>GPS</th></tr>';
          D.tableBody.innerHTML = '<tr><td colspan="4" class="tbl-empty-cell"><svg width="28" height="28" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"><path stroke="none" d="M0 0h24v24H0z" fill="none"/><path d="M4 7a2 2 0 0 1 2 -2h12a2 2 0 0 1 2 2v12a2 2 0 0 1 -2 2h-12a2 2 0 0 1 -2 -2v-12z"/><path d="M16 3v4"/><path d="M8 3v4"/><path d="M4 11h16"/></svg>No events in this period</td></tr>';
        } else {
          renderEventRows(filtered);
        }
        const count = filtered.length;
        evToolbar.querySelector('#ev-toolbar-info').innerHTML =
          `Period: <b>${dfShortEv.format(evFrom)} – ${dfShortEv.format(evTo)}</b> · ${count} event${count !== 1 ? 's' : ''}`;
      }

      // Initial render
      applyFilters(events);

      // Type filter dropdown – toggle + close on outside click
      evToolbar.querySelector('#ev-type-filter-btn')?.addEventListener('click', ev => {
        ev.stopPropagation();
        const dd = $('ev-type-dropdown');
        if (dd) dd.style.display = dd.style.display === 'none' ? 'block' : 'none';
      });
      function closeEvTypeDD(e) {
        const wrap = $('ev-type-filter-wrap');
        if (!wrap) { document.removeEventListener('click', closeEvTypeDD); return; }
        if (!wrap.contains(e.target)) $('ev-type-dropdown').style.display = 'none';
      }
      document.addEventListener('click', closeEvTypeDD);

      evToolbar.querySelectorAll('.ev-type-cb').forEach(cb => {
        cb.addEventListener('change', async () => {
          updateTypeBtn();
          applyFilters(await getBaseEvents());
        });
      });

      evToolbar.querySelector('#ev-show-system').addEventListener('click', async function() {
        this.classList.toggle('active');
        localStorage.setItem('ev_show_system', this.classList.contains('active') ? '1' : '0');
        applyFilters(await getBaseEvents());
      });
      evToolbar.querySelector('#ev-show-errors').addEventListener('click', function() {
        this.classList.toggle('active');
        const on = this.classList.contains('active');
        localStorage.setItem('ev_show_errors', on ? '1' : '0');
        renderErrorsInline(sensor, on);
      });
      if (showErrors()) renderErrorsInline(sensor, true);
      evToolbar.querySelector('#ev-show-alerts').addEventListener('click', async function() {
        this.classList.toggle('active');
        localStorage.setItem('ev_show_alerts', this.classList.contains('active') ? '1' : '0');
        applyFilters(await getBaseEvents());
      });

      evToolbar.querySelector('.modal-btn-danger').addEventListener('click', () => {
        showDeleteModal({
          title: 'Delete all events?',
          body: `Permanently delete <b>${allEvents.length} event${allEvents.length !== 1 ? 's' : ''}</b> for this period.<br><span style="color:var(--fg3);font-size:11px">${dfShortEv.format(evFrom)} – ${dfShortEv.format(evTo)}</span>`,
          confirmLabel: `Delete ${allEvents.length} events`,
          onConfirm: async () => {
            const res = await fetch(`/api/vehicle-events?imei=${encodeURIComponent(sensor.sensorID)}&from=${evFrom.toISOString()}&to=${evTo.toISOString()}`, { method: 'DELETE', headers: authHeaders() });
            if (res.ok) {
              const data = await res.json().catch(() => ({}));
              showToast(`Deleted ${data.deleted ?? allEvents.length} events`);
              D.tableCont.querySelector('#events-period-toolbar')?.remove();
              renderTable();
            } else showToast('Delete failed', 'error');
          }
        });
      });
    }

    return;
  }

  if (isTpms(sensor)) {
    $('table-head').innerHTML = '<tr><th>Time</th><th>Pressure</th><th>Status</th><th>Target</th><th>Temp</th><th>Battery</th><th>Wheel</th><th>GPS</th></tr>';
    D.tableBody.innerHTML = rows.map(r => {
      const status = pStatus(r.pressureBar, target);
      const color  = SC[status];
      const href = osmHref(r.latitude, r.longitude);
      const gpsLink = href
        ? `<a href="${href}" target="_blank" rel="noopener noreferrer" style="color:var(--m-blue);font-size:2em;line-height:1">⌖</a>` : '–';
      return `<tr>
        <td class="td-ts">${df.format(new Date(r.timestamp))}</td>
        <td class="td-pres" style="color:${color}">${r.pressureBar?.toFixed(3) ?? '–'} bar</td>
        <td><span class="status-badge" style="background:${SC_BG[status]};color:${color}">${status.toUpperCase()}</span></td>
        <td>${r.targetPressureBar != null ? r.targetPressureBar.toFixed(2) + ' bar' : '–'}</td>
        <td>${r.temperatureC  != null ? r.temperatureC.toFixed(1) + ' °C' : '–'}</td>
        <td>${r.vbattVolts    != null ? r.vbattVolts.toFixed(2) + ' V' : '–'}</td>
        <td>${escHTML(r.wheelPosition ?? '–')}</td>
        <td>${gpsLink}</td>
      </tr>`;
    }).join('');
  } else if (sensor?.brand === 'airtag') {
    $('table-head').innerHTML = '<tr><th>Time</th><th>Battery</th><th>Status</th><th>GPS</th></tr>';
    D.tableBody.innerHTML = rows.map(r => {
      const bPct   = r.batteryPct;
      const bLabel = bPct != null ? (bPct >= 100 ? 'Full' : bPct >= 60 ? 'Medium' : bPct >= 25 ? 'Low' : 'Critical') : '\u2013';
      const bCol   = bPct != null ? (bPct >= 60 ? '#34d399' : bPct >= 25 ? '#fbbf24' : '#f87171') : '';
      const stateCell = r.chargeState === 'Separated' ? `<span style="color:#f87171">Separated</span>` : '\u2013';
      const href = osmHref(r.latitude, r.longitude);
      const lat = toFiniteNumber(r.latitude);
      const lon = toFiniteNumber(r.longitude);
      const gpsLink = href
        ? `<a href="${href}" target="_blank" rel="noopener noreferrer" style="color:var(--m-blue)">${lat?.toFixed(5)}, ${lon?.toFixed(5)}</a>` : '–';
      return `<tr><td class="td-ts">${df.format(new Date(r.timestamp))}</td><td style="color:${bCol}">${bLabel}</td><td>${stateCell}</td><td>${gpsLink}</td></tr>`;
    }).join('');
  } else {
    // STIHL Connector: STIHL-XXXX  →  batteryPct (vbatt), vbattVolts, temp, totalSeconds — no chargeState/health/cycles
    // STIHL Battery:   STIHLBATT-X →  batteryPct (chargePercent), chargeState, healthPct, chargingCycles, totalSeconds
    // ELA / autres: mixed
    const isStihlConnector = sensor?.sensorID?.startsWith('STIHL-') && !sensor?.sensorID?.startsWith('STIHLBATT-');
    const isStihlBattery   = sensor?.sensorID?.startsWith('STIHLBATT-');

    if (isStihlConnector) {
      $('table-head').innerHTML = '<tr><th>Time</th><th>Battery</th><th>Total time</th><th>Temp</th><th>Vbatt</th><th>GPS</th></tr>';
      D.tableBody.innerHTML = rows.map(r => {
        const bPct = r.batteryPct;
        const bCol = bPct != null ? (bPct > 50 ? '#34d399' : bPct > 20 ? '#fbbf24' : '#f87171') : '';
        const href = osmHref(r.latitude, r.longitude);
        const gpsLink = href
          ? `<a href="${href}" target="_blank" rel="noopener noreferrer" style="color:var(--m-blue);font-size:2em;line-height:1">⌖</a>` : '–';
        return `<tr>
          <td class="td-ts">${df.format(new Date(r.timestamp))}</td>
          <td style="color:${bCol}">${bPct != null ? bPct + '%' : '–'}</td>
          <td>${fmtDuration(r.totalSeconds)}</td>
          <td>${r.temperatureC != null ? r.temperatureC.toFixed(1) + ' °C' : '–'}</td>
          <td>${r.vbattVolts   != null ? r.vbattVolts.toFixed(2) + ' V' : '–'}</td>
          <td>${gpsLink}</td>
        </tr>`;
      }).join('');
    } else if (isStihlBattery) {
      $('table-head').innerHTML = '<tr><th>Time</th><th>Charge</th><th>State</th><th>Health</th><th>Cycles</th><th>Total discharge</th><th>GPS</th></tr>';
      D.tableBody.innerHTML = rows.map(r => {
        const bPct = r.batteryPct;
        const bCol = bPct != null ? (bPct > 50 ? '#34d399' : bPct > 20 ? '#fbbf24' : '#f87171') : '';
        const hPct = r.healthPct;
        const hCol = hPct != null ? (hPct > 70 ? '#34d399' : hPct > 40 ? '#fbbf24' : '#f87171') : '';
        const href = osmHref(r.latitude, r.longitude);
        const gpsLink = href
          ? `<a href="${href}" target="_blank" rel="noopener noreferrer" style="color:var(--m-blue);font-size:2em;line-height:1">⌖</a>` : '–';
        return `<tr>
          <td class="td-ts">${df.format(new Date(r.timestamp))}</td>
          <td style="color:${bCol}">${bPct != null ? bPct + '%' : '–'}</td>
          <td>${r.chargeState ? `<span style="color:${chargeStateColor(r.chargeState)}">${escHTML(r.chargeState)}</span>` : '–'}</td>
          <td style="color:${hCol}">${hPct != null ? hPct + '%' : '–'}</td>
          <td>${r.chargingCycles != null ? r.chargingCycles.toLocaleString() : '–'}</td>
          <td>${fmtDuration(r.totalSeconds)}</td>
          <td>${gpsLink}</td>
        </tr>`;
      }).join('');
    } else {
      // ELA / autres
      $('table-head').innerHTML = '<tr><th>Time</th><th>Battery</th><th>State</th><th>Total time</th><th>Temp</th><th>GPS</th></tr>';
      D.tableBody.innerHTML = rows.map(r => {
        const bPct = r.batteryPct;
        const bCol = bPct != null ? (bPct > 50 ? '#34d399' : bPct > 20 ? '#fbbf24' : '#f87171') : '';
        const href = osmHref(r.latitude, r.longitude);
        const gpsLink = href
          ? `<a href="${href}" target="_blank" rel="noopener noreferrer" style="color:var(--m-blue);font-size:2em;line-height:1">⌖</a>` : '–';
        return `<tr>
          <td class="td-ts">${df.format(new Date(r.timestamp))}</td>
          <td style="color:${bCol}">${bPct != null ? bPct + '%' : '–'}</td>
          <td>${escHTML(r.chargeState ?? '–')}</td>
          <td>${fmtDuration(r.totalSeconds)}</td>
          <td>${r.temperatureC != null ? r.temperatureC.toFixed(1) + ' °C' : '–'}</td>
          <td>${gpsLink}</td>
        </tr>`;
      }).join('');
    }
  }
}

// ─── Alerts inline: renders a card inside the Events tab ─────────────────────
async function renderAlertsInline(sensor, show) {
  D.tableCont.querySelector('#ev-alerts-inline')?.remove();
  if (!show) return;

  const card = document.createElement('div');
  card.id = 'ev-alerts-inline';
  card.className = 'ev-alerts-card';
  card.innerHTML = `<div class="ev-alerts-card-loading">Loading driver alerts…</div>`;
  const toolbar = D.tableCont.querySelector('#events-period-toolbar');
  if (toolbar) toolbar.after(card); else D.tableCont.prepend(card);

  let behaviors = [];
  try {
    behaviors = await apiFetch(`/api/driver-behavior?imei=${encodeURIComponent(sensor.sensorID)}&limit=1000`);
  } catch (e) {
    card.innerHTML = `<div class="ev-alerts-card-loading" style="color:var(--danger)">Failed to load alerts.</div>`;
    return;
  }
  behaviors.reverse(); // most recent first

  if (!behaviors.length) {
    card.innerHTML = `<div class="ev-alerts-card-empty"><svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="#34d399" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path stroke="none" d="M0 0h24v24H0z" fill="none"/><path d="M12 12m-9 0a9 9 0 1 0 18 0a9 9 0 0 0 -18 0"/><path d="M9 12l2 2l4 -4"/></svg> No driver alerts recorded</div>`;
    return;
  }

  const df2 = new Intl.DateTimeFormat([], { dateStyle: 'short', timeStyle: 'short' });
  card.innerHTML =
    `<div class="ev-alerts-card-header">` +
    `<span><svg width="13" height="13" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" style="vertical-align:-1px"><path stroke="none" d="M0 0h24v24H0z" fill="none"/><path d="M12 9v4"/><path d="M10.363 3.591l-8.106 13.534a1.914 1.914 0 0 0 1.636 2.871h16.214a1.914 1.914 0 0 0 1.636 -2.87l-8.106 -13.536a1.914 1.914 0 0 0 -3.274 0"/><path d="M12 16h.01"/></svg> ${behaviors.length} driver alert${behaviors.length !== 1 ? 's' : ''}</span>` +
    `<button class="modal-btn-danger admin-small-btn ev-alerts-delete-btn"><svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" style="vertical-align:-1px"><path stroke="none" d="M0 0h24v24H0z" fill="none"/><path d="M4 7l16 0"/><path d="M10 11l0 6"/><path d="M14 11l0 6"/><path d="M5 7l1 12a2 2 0 0 0 2 2h8a2 2 0 0 0 2 -2l1 -12"/><path d="M9 7v-3a1 1 0 0 1 1 -1h4a1 1 0 0 1 1 1v3"/></svg> Delete all</button>` +
    `</div>` +
    `<div class="ev-alerts-card-rows">` +
    behaviors.map(b => {
      const cfg    = BEHAVIOR_CONFIG[b.alertType] || BEHAVIOR_CONFIG.unknown;
      const svgIco = BEHAVIOR_SVG[b.alertType]   || BEHAVIOR_SVG.unknown;
      const durS   = b.alertDurationMs != null ? (b.alertDurationMs / 1000).toFixed(1) + '\u00a0s' : null;
      const val    = b.alertValueMax != null ? b.alertValueMax : null;
      const valStr = val != null ? (cfg.unit ? `${val.toFixed(2)}\u00a0${cfg.unit}` : val.toFixed(2)) : null;
      const spd    = b.speedKmh != null ? `${b.speedKmh.toFixed(0)}\u00a0km/h` : null;
      const href   = osmHref(b.latitude, b.longitude);
      const gpsLink = href ? `<a href="${href}" target="_blank" rel="noopener noreferrer" class="bat-gps-yes">\ud83d\udccd</a>` : null;
      const details = [
        valStr  ? `<span class="ev-alerts-detail-chip"><b>Peak:</b> ${escHTML(valStr)}</span>` : '',
        durS    ? `<span class="ev-alerts-detail-chip"><b>Duration:</b> ${escHTML(durS)}</span>` : '',
        spd     ? `<span class="ev-alerts-detail-chip"><b>Speed:</b> ${escHTML(spd)}</span>` : '',
        b.journeyID ? `<span class="ev-alerts-detail-chip"><b>Journey:</b> <span style="font-family:monospace;font-size:10px">${escHTML(b.journeyID.slice(0,8))}\u2026</span></span>` : '',
        gpsLink ? `<span class="ev-alerts-detail-chip">${gpsLink}</span>` : '',
      ].filter(Boolean).join('');
      return `<div class="ev-alerts-card-row" data-id="${escAttr(b.id)}">` +
        `<span class="ev-alerts-ts">${escHTML(df2.format(new Date(b.timestamp)))}</span>` +
        `<span class="ev-badge" style="--ev-color:${safeCssColor(cfg.color) || 'var(--fg2)'}">${svgIco} ${escHTML(cfg.label)}</span>` +
        `<span class="ev-alerts-detail-row">${details}</span>` +
        `<button class="ev-alerts-delete-row-btn" title="Delete alert"><svg width="11" height="11" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path stroke="none" d="M0 0h24v24H0z" fill="none"/><path d="M4 7l16 0"/><path d="M10 11l0 6"/><path d="M14 11l0 6"/><path d="M5 7l1 12a2 2 0 0 0 2 2h8a2 2 0 0 0 2 -2l1 -12"/><path d="M9 7v-3a1 1 0 0 1 1 -1h4a1 1 0 0 1 1 1v3"/></svg></button>` +
        `</div>`;
    }).join('') +
    (behaviors.length > 50 ? `<div class="ev-alerts-card-more">\u2026 and ${behaviors.length - 50} more</div>` : '') +
    `</div>`;

  // Delete all button
  card.querySelector('.ev-alerts-delete-btn').addEventListener('click', () => {
    const { from: alFrom, to: alTo } = getRange();
    const dfLbl = new Intl.DateTimeFormat([], { month: 'short', day: 'numeric', hour: '2-digit', minute: '2-digit' });
    showDeleteModal({
      title: 'Delete all alerts?',
      body: `Permanently delete <b>${behaviors.length} alert${behaviors.length !== 1 ? 's' : ''}</b> for this period.<br><span style="color:var(--fg3);font-size:11px">${dfLbl.format(alFrom)} – ${dfLbl.format(alTo)}</span>`,
      confirmLabel: `Delete ${behaviors.length} alerts`,
      onConfirm: async () => {
        const res = await fetch(`/api/driver-behavior?imei=${encodeURIComponent(sensor.sensorID)}&from=${alFrom.toISOString()}&to=${alTo.toISOString()}`, { method: 'DELETE', headers: authHeaders() });
        if (res.ok) {
          showToast('Alerts deleted');
          card.remove();
          const alertsBtn = D.tableCont.querySelector('#ev-show-alerts');
          if (alertsBtn) { alertsBtn.classList.remove('active'); localStorage.removeItem('ev_show_alerts'); }
        } else showToast('Delete failed', 'error');
      }
    });
  });

  // Per-row delete buttons
  card.querySelectorAll('.ev-alerts-delete-row-btn').forEach(btn => {
    btn.addEventListener('click', async () => {
      const row = btn.closest('.ev-alerts-card-row');
      const id  = row?.dataset.id;
      if (!id) return;
      const res = await fetch(`/api/driver-behavior/${id}`, { method: 'DELETE', headers: authHeaders() });
      if (res.ok || res.status === 204) { row.remove(); showToast('Alert deleted'); }
      else showToast('Delete failed', 'error');
    });
  });

  // Show only first 50 initially, more rows already in DOM (they render all)
}

// ─── Errors inline: renders a card inside the Events tab ─────────────────────
async function renderErrorsInline(sensor, show) {
  D.tableCont.querySelector('#ev-errors-inline')?.remove();
  if (!show) return;

  const card = document.createElement('div');
  card.id = 'ev-errors-inline';
  card.className = 'ev-errors-card';
  card.innerHTML = `<div class="ev-errors-card-loading">Checking for timing errors…</div>`;
  const toolbar = D.tableCont.querySelector('#events-period-toolbar');
  if (toolbar) toolbar.after(card); else D.tableCont.prepend(card);

  const THRESHOLD = new Date('2026-01-01T00:00:00Z').getTime();
  const df2 = new Intl.DateTimeFormat([], { dateStyle: 'short', timeStyle: 'short' });
  try {
    const events = await apiFetch(`/api/device-lifecycle?imei=${encodeURIComponent(sensor.sensorID)}&limit=2000`);
    const invalid = events.filter(e => new Date(e.timestamp).getTime() < THRESHOLD);
    if (!invalid.length) {
      card.innerHTML = `<div class="ev-errors-card-ok"><svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path stroke="none" d="M0 0h24v24H0z" fill="none"/><path d="M12 12m-9 0a9 9 0 1 0 18 0a9 9 0 0 0 -18 0"/><path d="M9 12l2 2l4 -4"/></svg> No timing errors found</div>`;
      return;
    }
    card.innerHTML =
      `<div class="ev-errors-card-header"><span>⚠ ${invalid.length} event${invalid.length !== 1 ? 's' : ''} with invalid timestamp</span>` +
      `<button class="modal-btn-danger admin-small-btn ev-errors-delete-btn"><svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" style="vertical-align:-1px"><path stroke="none" d="M0 0h24v24H0z" fill="none"/><path d="M4 7l16 0"/><path d="M10 11l0 6"/><path d="M14 11l0 6"/><path d="M5 7l1 12a2 2 0 0 0 2 2h8a2 2 0 0 0 2 -2l1 -12"/><path d="M9 7v-3a1 1 0 0 1 1 -1h4a1 1 0 0 1 1 1v3"/></svg> Delete all</button></div>` +
      `<div class="ev-errors-card-rows">` +
      invalid.slice(0, 50).map(e =>
        `<div class="ev-errors-card-row">` +
        `<span class="ev-errors-bad-ts" title="Bad device timestamp">${escHTML(df2.format(new Date(e.timestamp)))}</span>` +
        `<span class="ev-errors-received" title="Actual received time">→ ${escHTML(df2.format(new Date(e.receivedAt)))}</span>` +
        `<span class="ev-badge" style="--ev-color:#f87171">${escHTML(e.eventType)}</span>` +
        `</div>`
      ).join('') +
      (invalid.length > 50 ? `<div class="ev-errors-card-more">… and ${invalid.length - 50} more</div>` : '') +
      `</div>`;
    card.querySelector('.ev-errors-delete-btn').addEventListener('click', () => {
      showDeleteModal({
        title: 'Delete timing errors?',
        body: `Permanently delete <b>${invalid.length}</b> lifecycle event${invalid.length !== 1 ? 's' : ''} with timestamps before 2026 (device clock issue).`,
        confirmLabel: `Delete ${invalid.length} events`,
        onConfirm: async () => {
          const res = await fetch(
            `/api/device-lifecycle?imei=${encodeURIComponent(sensor.sensorID)}&from=1970-01-01T00:00:00Z&to=2025-12-31T23:59:59Z`,
            { method: 'DELETE', headers: authHeaders() }
          );
          if (res.ok) {
            showToast('Timing errors deleted');
            card.remove();
            const errBtn = D.tableCont.querySelector('#ev-show-errors');
            if (errBtn) { errBtn.classList.remove('active'); localStorage.removeItem('ev_show_errors'); }
          } else showToast('Delete failed', 'error');
        }
      });
    });
  } catch (err) {
    card.innerHTML = `<div class="ev-errors-card-loading" style="color:var(--danger)">Failed to load lifecycle events.</div>`;
  }
}

// ─── Errors: lifecycle events with invalid timestamp (< 2026) ─────────────────
async function renderErrors() {
  const sensor = S.sensors.find(s => s.sensorID === S.selected);
  if (!sensor) return;

  const THRESHOLD = new Date('2026-01-01T00:00:00Z').getTime();
  const LIFECYCLE_LABELS = {
    boot:    { icon: '<svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path stroke="none" d="M0 0h24v24H0z" fill="none"/><path d="M7 6a7.75 7.75 0 1 0 10 0"/><path d="M12 4l0 8"/></svg>',   label: 'Boot',    color: '#a78bfa' },
    sleep:   { icon: '<svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path stroke="none" d="M0 0h24v24H0z" fill="none"/><path d="M4 12h6l-6 8h6"/><path d="M14 4h6l-6 8h6"/></svg>',     label: 'Sleep',   color: '#94a3b8' },
    wake_up: { icon: '<svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path stroke="none" d="M0 0h24v24H0z" fill="none"/><path d="M3 17h1m16 0h1m-15.4 -6.4l.7 .7m12.1 -.7l-.7 .7m-9.7 5.7a4 4 0 0 1 8 0"/><path d="M3 21l18 0"/><path d="M12 9v-6l3 3m-6 0l3 -3"/></svg>', label: 'Wake up', color: '#fbbf24' },
    ping:    { icon: '<svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path stroke="none" d="M0 0h24v24H0z" fill="none"/><path d="M18.364 5.636a9 9 0 0 1 0 12.728"/><path d="M15.536 8.464a5 5 0 0 1 0 7.072"/><path d="M12 11m-1 0a1 1 0 1 0 2 0a1 1 0 1 0 -2 0"/><path d="M5.636 5.636a9 9 0 0 0 0 12.728"/><path d="M8.464 8.464a5 5 0 0 0 0 7.072"/></svg>', label: 'Ping',     color: '#22d3ee' },
  };

  D.errorsCont.innerHTML = `<div class="bat-box"><div class="bat-header">Events with invalid timestamp</div><table class="bat-table"><thead><tr><th>Bad timestamp (from device)</th><th>Received at (real time)</th><th>Event</th><th>Reset reason</th></tr></thead><tbody>${skeletonRows(5)}</tbody></table></div>`;

  let events = [];
  try {
    events = await apiFetch(`/api/device-lifecycle?imei=${encodeURIComponent(sensor.sensorID)}&limit=2000`);
  } catch (err) {
    D.errorsCont.innerHTML = `<div class="bat-loading-full" style="color:var(--danger)">Failed to load device events.</div>`;
    return;
  }

  const invalid = events.filter(e => new Date(e.timestamp).getTime() < THRESHOLD);

  if (!invalid.length) {
    D.errorsCont.innerHTML = '<div class="bat-loading-full"><svg width="36" height="36" viewBox="0 0 24 24" fill="none" stroke="#34d399" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"><path stroke="none" d="M0 0h24v24H0z" fill="none"/><path d="M12 12m-9 0a9 9 0 1 0 18 0a9 9 0 0 0 -18 0"/><path d="M9 12l2 2l4 -4"/></svg><br>No invalid timestamps found.</div>';
    return;
  }

  D.errorsCont.innerHTML = `
    <div class="bat-box">
      <div class="bat-header">Events with invalid timestamp <span class="bat-count">${invalid.length}</span></div>
      <table class="bat-table">
        <thead><tr><th>Bad timestamp (from device)</th><th>Received at (real time)</th><th>Event</th><th>Reset reason</th></tr></thead>
        <tbody>${invalid.map(e => {
          const ev = LIFECYCLE_LABELS[e.eventType] ?? { icon: '○', label: e.eventType, color: 'var(--fg2)' };
          return `<tr>
            <td class="td-ts-compact" style="color:var(--danger)">${fmtTs(e.timestamp)}</td>
            <td class="td-ts-compact">${fmtTs(e.receivedAt)}</td>
            <td><span class="ev-badge" style="--ev-color:${safeCssColor(ev.color) || 'var(--fg2)'}">${ev.icon} ${escHTML(ev.label)}</span></td>
            <td>${escHTML(e.resetReason ?? '–')}</td>
          </tr>`;
        }).join('')}</tbody>
      </table>
    </div>`;

  // Delete-all toolbar
  const errToolbar = document.createElement('div');
  errToolbar.className = 'tab-action-toolbar';
  errToolbar.innerHTML = `<span>${invalid.length} invalid event${invalid.length !== 1 ? 's' : ''} (timestamp before 2026)</span><button class="modal-btn-danger admin-small-btn"><svg width="13" height="13" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" style="vertical-align:-1px"><path stroke="none" d="M0 0h24v24H0z" fill="none"/><path d="M4 7l16 0"/><path d="M10 11l0 6"/><path d="M14 11l0 6"/><path d="M5 7l1 12a2 2 0 0 0 2 2h8a2 2 0 0 0 2 -2l1 -12"/><path d="M9 7v-3a1 1 0 0 1 1 -1h4a1 1 0 0 1 1 1v3"/></svg> Delete all</button>`;
  D.errorsCont.prepend(errToolbar);
  errToolbar.querySelector('button').addEventListener('click', () => {
    showDeleteModal({
      title: 'Delete all invalid events?',
      body: `Permanently delete <b>${invalid.length} event${invalid.length !== 1 ? 's' : ''}</b> with invalid timestamps (before 2026).`,
      confirmLabel: `Delete ${invalid.length} events`,
      onConfirm: async () => {
        const res = await fetch(
          `/api/device-lifecycle?imei=${encodeURIComponent(sensor.sensorID)}&from=1970-01-01T00:00:00Z&to=2025-12-31T23:59:59Z`,
          { method: 'DELETE', headers: authHeaders() }
        );
        if (res.ok) {
          const data = await res.json().catch(() => ({}));
          showToast(`Deleted ${data.deleted ?? invalid.length} events`);
          renderErrors();
        } else showToast('Delete failed', 'error');
      }
    });
  });
}

// ─── Alerts ───────────────────────────────────────────────────────────────────
// ─── Device lifecycle ────────────────────────────────────────────────────────
async function renderDevice() {
  const sensor = S.sensors.find(s => s.sensorID === S.selected);
  if (!sensor) return;
  const LIFECYCLE_LABELS = {
    boot:         { icon: '<svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path stroke="none" d="M0 0h24v24H0z" fill="none"/><path d="M7 6a7.75 7.75 0 1 0 10 0"/><path d="M12 4l0 8"/></svg>',   label: 'Boot',         color: '#a78bfa' },
    sleep:        { icon: '<svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path stroke="none" d="M0 0h24v24H0z" fill="none"/><path d="M4 12h6l-6 8h6"/><path d="M14 4h6l-6 8h6"/></svg>',     label: 'Sleep',        color: '#94a3b8' },
    wake_up:      { icon: '<svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path stroke="none" d="M3 17h1m16 0h1m-15.4 -6.4l.7 .7m12.1 -.7l-.7 .7m-9.7 5.7a4 4 0 0 1 8 0"/><path d="M3 21l18 0"/><path d="M12 9v-6l3 3m-6 0l3 -3"/></svg>', label: 'Wake up',      color: '#fbbf24' },
    ping:         { icon: '<svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path stroke="none" d="M0 0h24v24H0z" fill="none"/><path d="M18.364 5.636a9 9 0 0 1 0 12.728"/><path d="M15.536 8.464a5 5 0 0 1 0 7.072"/><path d="M12 11m-1 0a1 1 0 1 0 2 0a1 1 0 1 0 -2 0"/><path d="M5.636 5.636a9 9 0 0 0 0 12.728"/><path d="M8.464 8.464a5 5 0 0 0 0 7.072"/></svg>', label: 'Ping',          color: '#22d3ee' },
    gps_acquired: { icon: '<svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path stroke="none" d="M0 0h24v24H0z" fill="none"/><path d="M3.707 6.293l2.586 -2.586a1 1 0 0 1 1.414 0l5 5a1 1 0 0 1 0 1.414l-2.586 2.586a1 1 0 0 1 -1.414 0l-5 -5a1 1 0 0 1 0 -1.414z"/><path d="M6 10l-3 3l3 3l3 -3"/><path d="M10 6l3 -3l3 3l-3 3"/><path d="M12 20l4 -4"/><path d="M14 20l5 -5"/></svg>',  label: 'GPS acquired',  color: '#34d399' },
    gps_lost:     { icon: '<svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path stroke="none" d="M0 0h24v24H0z" fill="none"/><path d="M3.707 6.293l2.586 -2.586a1 1 0 0 1 1.414 0l5 5a1 1 0 0 1 0 1.414l-2.586 2.586a1 1 0 0 1 -1.414 0l-5 -5a1 1 0 0 1 0 -1.414z"/><path d="M6 10l-3 3l3 3l3 -3"/><path d="M10 6l3 -3l3 3l-3 3"/><path d="M12 20l4 -4"/><path d="M14 20l5 -5"/><path d="M3 3l18 18"/></svg>',     label: 'GPS lost',      color: '#f87171' },
  };

  D.deviceCont.innerHTML = `<div class="bat-box"><div class="bat-header">Device events</div><table class="bat-table"><thead><tr><th>Time</th><th>Event</th><th>Reset reason</th><th>Wake source</th><th>Battery</th><th>GPS</th><th></th></tr></thead><tbody>${skeletonRows(6)}</tbody></table></div>`;

  let events = [];
  let lifecycle_summary = null;
  try {
    [events, lifecycle_summary] = await Promise.all([
      apiFetch(`/api/device-lifecycle?imei=${encodeURIComponent(sensor.sensorID)}&limit=500`),
      apiFetch(`/api/device-lifecycle/summary?imei=${encodeURIComponent(sensor.sensorID)}`).catch(() => null),
    ]);
  } catch (err) {
    D.deviceCont.innerHTML = `<div class="bat-loading-full" style="color:var(--danger)">Failed to load device events.</div>`;
    return;
  }

  events.forEach(e => e._src = 'lifecycle');

  // Sort descending by timestamp
  const allEvents = [...events].sort((a, b) => new Date(b.timestamp) - new Date(a.timestamp));

  // ── Lifecycle summary cards ──────────────────────────────────────────────
  let summaryHtml = '';
  if (lifecycle_summary) {
    const ls = lifecycle_summary;
    const dfS = new Intl.DateTimeFormat([], { month: 'short', day: 'numeric', hour: '2-digit', minute: '2-digit' });
    const fmtD = iso => iso ? dfS.format(new Date(iso)) : '–';
    // Wake source breakdown
    const wakeBreakdown = ls.wakeUp?.sourceBreakdown ? Object.entries(ls.wakeUp.sourceBreakdown)
      .sort((a, b) => b[1] - a[1])
      .map(([src, n]) => `<span style="color:var(--fg3)">${escHTML(src)}:</span>\u00a0${n}`)
      .join('\u00a0\u00b7\u00a0') : '';
    summaryHtml = `<div class="bat-box lc-summary-box">
      <div class="bat-header">Device summary</div>
      <div class="lc-summary-grid">
        <div class="lc-summary-card">
          <div class="lc-summary-val">${ls.boot?.count ?? 0}</div>
          <div class="lc-summary-label">Boots</div>
          ${ls.boot?.lastAt     ? `<div class="lc-summary-sub">${fmtD(ls.boot.lastAt)}</div>` : ''}
          ${ls.boot?.lastReason ? `<div class="lc-summary-sub" style="color:var(--fg3)">${escHTML(ls.boot.lastReason)}</div>` : ''}
        </div>
        <div class="lc-summary-card">
          <div class="lc-summary-val">${ls.sleep?.count ?? 0}</div>
          <div class="lc-summary-label">Sleeps</div>
          ${ls.sleep?.lastAt       ? `<div class="lc-summary-sub">${fmtD(ls.sleep.lastAt)}</div>` : ''}
          ${ls.sleep?.lastVoltageV != null ? `<div class="lc-summary-sub" style="color:var(--fg3)">${ls.sleep.lastVoltageV.toFixed(2)}\u00a0V</div>` : ''}
        </div>
        <div class="lc-summary-card">
          <div class="lc-summary-val">${ls.wakeUp?.count ?? 0}</div>
          <div class="lc-summary-label">Wake-ups</div>
          ${ls.wakeUp?.lastAt     ? `<div class="lc-summary-sub">${fmtD(ls.wakeUp.lastAt)}</div>` : ''}
          ${wakeBreakdown         ? `<div class="lc-summary-sub" style="font-size:10px">${wakeBreakdown}</div>` : ''}
        </div>
      </div>
    </div>`;
  }

  if (!allEvents.length) {
    D.deviceCont.innerHTML = summaryHtml + '<div class="bat-loading-full"><svg width="36" height="36" viewBox="0 0 24 24" fill="none" stroke="#34d399" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"><path stroke="none" d="M0 0h24v24H0z" fill="none"/><path d="M12 12m-9 0a9 9 0 1 0 18 0a9 9 0 0 0 -18 0"/><path d="M9 12l2 2l4 -4"/></svg><br>No device lifecycle events recorded.</div>';
    return;
  }

  D.deviceCont.innerHTML = summaryHtml + `
    <div class="bat-box">
      <div class="bat-header">Device events <span class="bat-count">${allEvents.length}</span></div>
      <table class="bat-table">
        <thead><tr><th>Time</th><th>Event</th><th>Reset reason</th><th>Wake source</th><th>Battery</th><th>GPS</th><th></th></tr></thead>
        <tbody>${allEvents.map(e => {
          const ev = LIFECYCLE_LABELS[e.eventType] ?? { icon: '○', label: e.eventType, color: 'var(--fg2)' };
          return `<tr data-id="${escAttr(e.id)}" data-src="${e._src}">
            <td class="td-ts-compact">${fmtTs(e.timestamp)}</td>
            <td><span class="ev-badge" style="--ev-color:${safeCssColor(ev.color) || 'var(--fg2)'}">${ev.icon} ${escHTML(ev.label)}</span></td>
            <td>${escHTML(e.resetReason  ?? '–')}</td>
            <td>${escHTML(e.wakeupSource ?? '–')}</td>
            <td>${e.batteryVoltageV != null ? e.batteryVoltageV.toFixed(2) + ' V' : '–'}</td>
            <td>${gpsCell(e)}</td>
            <td><button class="row-delete-btn" title="Delete"><svg width="13" height="13" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path stroke="none" d="M0 0h24v24H0z" fill="none"/><path d="M4 7l16 0"/><path d="M10 11l0 6"/><path d="M14 11l0 6"/><path d="M5 7l1 12a2 2 0 0 0 2 2h8a2 2 0 0 0 2 -2l1 -12"/><path d="M9 7v-3a1 1 0 0 1 1 -1h4a1 1 0 0 1 1 1v3"/></svg></button></td>
          </tr>`;
        }).join('')}</tbody>
      </table>
    </div>`;

  D.deviceCont.querySelectorAll('.row-delete-btn').forEach(btn => {
    btn.addEventListener('click', async evClick => {
      const row = evClick.target.closest('tr');
      const id  = row?.dataset.id;
      if (!id) return;
      const url = `/api/device-lifecycle/${id}`;
      const res = await fetch(url, { method: 'DELETE', headers: authHeaders() });
      if (res.ok || res.status === 204) { row.remove(); showToast('Event deleted'); }
      else showToast('Delete failed', 'error');
    });
  });

  // Delete period toolbar
  const { from: dvFrom, to: dvTo } = getRange();
  const dfShortDv = new Intl.DateTimeFormat([], { month: 'short', day: 'numeric', hour: '2-digit', minute: '2-digit' });
  const dvToolbar = document.createElement('div');
  dvToolbar.className = 'tab-action-toolbar';
  dvToolbar.innerHTML = `<span>Period: <b>${dfShortDv.format(dvFrom)} – ${dfShortDv.format(dvTo)}</b> · ${events.length} event${events.length !== 1 ? 's' : ''}</span><button class="modal-btn-danger admin-small-btn"><svg width="13" height="13" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" style="vertical-align:-1px"><path stroke="none" d="M0 0h24v24H0z" fill="none"/><path d="M4 7l16 0"/><path d="M10 11l0 6"/><path d="M14 11l0 6"/><path d="M5 7l1 12a2 2 0 0 0 2 2h8a2 2 0 0 0 2 -2l1 -12"/><path d="M9 7v-3a1 1 0 0 1 1 -1h4a1 1 0 0 1 1 1v3"/></svg> Delete all</button>`;
  D.deviceCont.prepend(dvToolbar);
  dvToolbar.querySelector('button').addEventListener('click', () => {
    showDeleteModal({
      title: 'Delete all device events?',
      body: `Permanently delete <b>${events.length} event${events.length !== 1 ? 's' : ''}</b> for this period.<br><span style="color:var(--fg3);font-size:11px">${dfShortDv.format(dvFrom)} – ${dfShortDv.format(dvTo)}</span>`,
      confirmLabel: `Delete ${events.length} events`,
      onConfirm: async () => {
        const res = await fetch(`/api/device-lifecycle?imei=${encodeURIComponent(sensor.sensorID)}&from=${dvFrom.toISOString()}&to=${dvTo.toISOString()}`, { method: 'DELETE', headers: authHeaders() });
        if (res.ok) {
          const data = await res.json().catch(() => ({}));
          showToast(`Deleted ${data.deleted ?? events.length} events`);
          renderDevice();
        } else showToast('Delete failed', 'error');
      }
    });
  });
}

async function renderAlerts() {
  const sensor = S.sensors.find(s => s.sensorID === S.selected);
  if (!sensor) return;

  D.alertsCont.innerHTML = `<div class="bat-box"><div class="bat-header">Driver behaviour alerts</div><table class="bat-table"><thead><tr><th>Time</th><th>Type</th><th>Peak</th><th>Duration</th><th>Speed</th><th>Journey</th><th>Position</th><th></th></tr></thead><tbody>${skeletonRows(8)}</tbody></table></div>`;

  let behaviors = [];
  try { behaviors = await apiFetch(`/api/driver-behavior?imei=${encodeURIComponent(sensor.sensorID)}&limit=1000`); }
  catch(e) {
    D.alertsCont.innerHTML = `<div class="bat-loading-full" style="color:var(--danger)">Failed to load alerts.</div>`;
    console.warn('behavior fetch:', e);
    return;
  }

  behaviors.reverse(); // most recent first

  if (!behaviors.length) {
    D.alertsCont.innerHTML = `<div class="bat-loading-full"><svg width="36" height="36" viewBox="0 0 24 24" fill="none" stroke="#34d399" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"><path stroke="none" d="M0 0h24v24H0z" fill="none"/><path d="M12 12m-9 0a9 9 0 1 0 18 0a9 9 0 0 0 -18 0"/><path d="M9 12l2 2l4 -4"/></svg><br>No driver behaviour alerts recorded.</div>`;
    return;
  }

  const alHasRpm    = behaviors.some(b => b.engineRpm          != null);
  const alHasFuel   = behaviors.some(b => b.fuelLevelPct       != null);
  const alHasOdo    = behaviors.some(b => b.odometerKm         != null);
  const alHasDist   = behaviors.some(b => b.journeyDistanceKm  != null);
  const alHasJFuel  = behaviors.some(b => b.journeyFuelConsumedL != null);
  const alHasSats   = behaviors.some(b => b.gpsSatellites      != null);

  const alHdrs = ['Time','Type','Peak','Duration','Speed'];
  if (alHasRpm)   alHdrs.push('RPM');
  if (alHasFuel)  alHdrs.push('Fuel');
  if (alHasOdo)   alHdrs.push('Odometer');
  if (alHasDist)  alHdrs.push('Journey dist.');
  if (alHasJFuel) alHdrs.push('Journey fuel');
  if (alHasSats)  alHdrs.push('Sats');
  alHdrs.push('Journey', 'Position', '');

  D.alertsCont.innerHTML = `
    <div class="bat-box">
      <div class="bat-header">Driver behaviour alerts <span class="bat-count">${behaviors.length}</span></div>
      <table class="bat-table">
        <thead><tr>${alHdrs.map(h => `<th>${h}</th>`).join('')}</tr></thead>
        <tbody>${behaviors.map(b => {
        const cfg    = BEHAVIOR_CONFIG[b.alertType] || BEHAVIOR_CONFIG.unknown;
        const durS   = b.alertDurationMs != null ? (b.alertDurationMs / 1000).toFixed(1) + ' s' : '\u2014';
        const val    = b.alertValueMax != null ? b.alertValueMax : null;
        const valStr = val != null ? (cfg.unit ? `${val.toFixed(2)}\u00a0${cfg.unit}` : val.toFixed(2)) : '\u2014';
        const spd    = b.speedKmh != null ? `${b.speedKmh.toFixed(0)}\u00a0km/h` : '\u2014';
        const journey = b.journeyID ? `<span style="font-family:monospace;font-size:10px;color:var(--fg3)">${escHTML(b.journeyID.slice(0,8))}\u2026</span>` : '\u2014';
        const href = osmHref(b.latitude, b.longitude);
        const gps    = href
          ? `<a href="${href}" target="_blank" rel="noopener noreferrer" class="bat-gps-yes">\ud83d\udccd map</a>`
          : `<span class="bat-gps-no">no GPS</span>`;
        const svgIco = BEHAVIOR_SVG[b.alertType] || BEHAVIOR_SVG.unknown;
        const fuelCol = b.fuelLevelPct != null
          ? (b.fuelLevelPct > 50 ? '#34d399' : b.fuelLevelPct > 20 ? '#fbbf24' : '#f87171') : '';
        let cells = `<td class="td-ts-compact">${fmtTs(b.timestamp)}</td>`;
        cells += `<td><span class="ev-badge" style="--ev-color:${safeCssColor(cfg.color) || 'var(--fg2)'}">${svgIco} ${escHTML(cfg.label)}</span></td>`;
        cells += `<td>${valStr}</td>`;
        cells += `<td>${durS}</td>`;
        cells += `<td>${spd}</td>`;
        if (alHasRpm)   cells += `<td>${b.engineRpm != null ? b.engineRpm.toLocaleString() + '\u00a0rpm' : '\u2013'}</td>`;
        if (alHasFuel)  cells += `<td${fuelCol ? ` style="color:${fuelCol}"` : ''}>${b.fuelLevelPct != null ? b.fuelLevelPct + '%' : '\u2013'}</td>`;
        if (alHasOdo)   cells += `<td>${b.odometerKm != null ? b.odometerKm.toFixed(1) + '\u00a0km' : '\u2013'}</td>`;
        if (alHasDist)  cells += `<td>${b.journeyDistanceKm != null ? b.journeyDistanceKm.toFixed(2) + '\u00a0km' : '\u2013'}</td>`;
        if (alHasJFuel) cells += `<td>${b.journeyFuelConsumedL != null ? b.journeyFuelConsumedL.toFixed(3) + '\u00a0L' : '\u2013'}</td>`;
        if (alHasSats)  cells += `<td>${b.gpsSatellites != null ? b.gpsSatellites : '\u2013'}</td>`;
        cells += `<td>${journey}</td>`;
        cells += `<td>${gps}</td>`;
        cells += `<td><button class="row-delete-btn" title="Delete"><svg width="13" height="13" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path stroke="none" d="M0 0h24v24H0z" fill="none"/><path d="M4 7l16 0"/><path d="M10 11l0 6"/><path d="M14 11l0 6"/><path d="M5 7l1 12a2 2 0 0 0 2 2h8a2 2 0 0 0 2 -2l1 -12"/><path d="M9 7v-3a1 1 0 0 1 1 -1h4a1 1 0 0 1 1 1v3"/></svg></button></td>`;
        return `<tr data-id="${escAttr(b.id)}">${cells}</tr>`;
      }).join('')}</tbody>
      </table>
    </div>`;

  D.alertsCont.querySelectorAll('.row-delete-btn').forEach(btn => {
    btn.addEventListener('click', async evClick => {
      const row = evClick.target.closest('tr');
      const id  = row?.dataset.id;
      if (!id) return;
      const res = await fetch(`/api/driver-behavior/${id}`, { method: 'DELETE', headers: authHeaders() });
      if (res.ok || res.status === 204) { row.remove(); showToast('Alert deleted'); }
      else showToast('Delete failed', 'error');
    });
  });

  // Delete period toolbar
  const { from: alFrom, to: alTo } = getRange();
  const dfShortAl = new Intl.DateTimeFormat([], { month: 'short', day: 'numeric', hour: '2-digit', minute: '2-digit' });
  const alToolbar = document.createElement('div');
  alToolbar.className = 'tab-action-toolbar';
  alToolbar.innerHTML = `<span>Period: <b>${dfShortAl.format(alFrom)} – ${dfShortAl.format(alTo)}</b> · ${behaviors.length} alert${behaviors.length !== 1 ? 's' : ''}</span><button class="modal-btn-danger admin-small-btn"><svg width="13" height="13" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" style="vertical-align:-1px"><path stroke="none" d="M0 0h24v24H0z" fill="none"/><path d="M4 7l16 0"/><path d="M10 11l0 6"/><path d="M14 11l0 6"/><path d="M5 7l1 12a2 2 0 0 0 2 2h8a2 2 0 0 0 2 -2l1 -12"/><path d="M9 7v-3a1 1 0 0 1 1 -1h4a1 1 0 0 1 1 1v3"/></svg> Delete all</button>`;
  D.alertsCont.prepend(alToolbar);
  alToolbar.querySelector('button').addEventListener('click', () => {
    showDeleteModal({
      title: 'Delete all alerts?',
      body: `Permanently delete <b>${behaviors.length} alert${behaviors.length !== 1 ? 's' : ''}</b> for this period.<br><span style="color:var(--fg3);font-size:11px">${dfShortAl.format(alFrom)} – ${dfShortAl.format(alTo)}</span>`,
      confirmLabel: `Delete ${behaviors.length} alerts`,
      onConfirm: async () => {
        const res = await fetch(`/api/driver-behavior?imei=${encodeURIComponent(sensor.sensorID)}&from=${alFrom.toISOString()}&to=${alTo.toISOString()}`, { method: 'DELETE', headers: authHeaders() });
        if (res.ok) {
          const data = await res.json().catch(() => ({}));
          showToast(`Deleted ${data.deleted ?? behaviors.length} alerts`);
          renderAlerts();
        } else showToast('Delete failed', 'error');
      }
    });
  });
  // Sub-tab nav: Events | Driver Alerts
  D.alertsCont.querySelector('#alerts-sub-tabs')?.remove();
  const subTabsAl = document.createElement('div');
  subTabsAl.id = 'alerts-sub-tabs';
  subTabsAl.className = 'events-sub-tabs';
  subTabsAl.innerHTML =
    `<button class="events-sub-tab" data-sub="events"><svg width="13" height="13" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" style="vertical-align:-1px"><path stroke="none" d="M0 0h24v24H0z" fill="none"/><path d="M13 5h8"/><path d="M13 9h5"/><path d="M13 15h8"/><path d="M13 19h5"/><path d="M3 5a1 1 0 0 1 1 -1h4a1 1 0 0 1 1 1v4a1 1 0 0 1 -1 1h-4a1 1 0 0 1 -1 -1l0 -4"/><path d="M3 15a1 1 0 0 1 1 -1h4a1 1 0 0 1 1 1v4a1 1 0 0 1 -1 1h-4a1 1 0 0 1 -1 -1l0 -4"/></svg> Events</button>` +
    `<button class="events-sub-tab active" data-sub="alerts"><svg width="13" height="13" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" style="vertical-align:-1px"><path stroke="none" d="M0 0h24v24H0z" fill="none"/><path d="M12 9v4"/><path d="M10.363 3.591l-8.106 13.534a1.914 1.914 0 0 0 1.636 2.871h16.214a1.914 1.914 0 0 0 1.636 -2.87l-8.106 -13.536a1.914 1.914 0 0 0 -3.274 0"/><path d="M12 16h.01"/></svg> Driver Alerts</button>`;
  D.alertsCont.prepend(subTabsAl);
  subTabsAl.querySelector('[data-sub="events"]').addEventListener('click', () => {
    showMode('table');
    renderTable();
  });
}

// ─── Master render ────────────────────────────────────────────────────────────
function renderAll() {
  renderBreadcrumb();
  renderSensorInfoCard();
  renderStats();

  // Show/hide Chart tab depending on sensor brand
  const sensor = S.sensors.find(s => s.sensorID === S.selected);
  const hasChart   = sensor && sensor.brand !== 'airtag' && sensor.brand !== 'tracker';
  const hasAlerts  = isTracker(sensor);
  // Has wheels overview: current selected sensor is TPMS and vehicle has ≥2 TPMS
  const _wovGroups = groupByVehicle();
  const _wovEntry  = S.vehicleFilter ? _wovGroups[S.vehicleFilter] : null;
  const hasWheels  = isTpms(sensor) && (_wovEntry?.sensors ?? []).filter(s => isTpms(s)).length >= 2;
  const chartBtn   = document.querySelector('.mode-btn[data-mode="chart"]');
  const wheelsBtn  = document.querySelector('.mode-btn[data-mode="wheels"]');
  if (chartBtn)  chartBtn.style.display  = hasChart  ? '' : 'none';
  if (wheelsBtn) wheelsBtn.style.display = hasWheels ? '' : 'none';
  // Fallback if current mode is no longer valid
  // AirTag: prefer the Events (table) tab since readings rarely carry GPS
  if (!hasChart  && S.mode === 'chart')  { S.mode = sensor?.brand === 'airtag' ? 'table' : 'map'; _fixModeBtn(); }
  if (!hasWheels && S.mode === 'wheels') { S.mode = 'map'; _fixModeBtn(); }
  if (!hasAlerts && (S.mode === 'alerts' || S.mode === 'device')) { S.mode = 'map'; _fixModeBtn(); }
  function _fixModeBtn() {
    document.querySelectorAll('.mode-btn').forEach(b => b.classList.remove('active'));
    const btn = document.querySelector(`.mode-btn[data-mode="${S.mode}"]`);
    if (btn) btn.classList.add('active');
  }

  showMode(S.mode);
  if (!S.records.length && S.mode !== 'alerts' && S.mode !== 'device' && S.mode !== 'errors') return;
  if (S.mode === 'chart')  renderChart();
  if (S.mode === 'map')    renderMap();
  if (S.mode === 'table')  renderTable();
  if (S.mode === 'alerts') renderAlerts();
  if (S.mode === 'device') renderDevice();
  if (S.mode === 'wheels') renderWheels();
  if (S.mode === 'errors') renderErrors();
  if (S.mode === 'fleet')  renderFleet();
  checkCurrentSensorAlerts();
}

// ─── Fleet grid view ─────────────────────────────────────────────────────────
function renderFleet() {
  const groups  = groupByVehicle();
  const entry   = S.vehicleFilter ? groups[S.vehicleFilter] : null;
  const sensors = entry?.sensors ?? [];
  if (!sensors.length) {
    D.fleetCont.innerHTML = '<div class="bat-loading-full"><p>No sensors for this vehicle.</p></div>';
    return;
  }

  const cards = sensors.map(s => {
    const stale   = isStale(s.latestTimestamp, s.brand);
    const sel     = s.sensorID === S.selected;
    let statusCol   = stale ? SC.unknown : SC.ok;
    let statusLabel = stale ? 'stale' : 'ok';
    let mainValue = '', unit = '', sub = '';

    if (isTpms(s)) {
      const st    = pStatus(s.latestPressureBar, s.targetPressureBar);
      statusCol   = stale ? SC.unknown : SC[st];
      statusLabel = stale ? 'stale' : st;
      mainValue   = s.latestPressureBar != null ? s.latestPressureBar.toFixed(2) : '';
      unit        = 'bar';
      if (s.latestTemperatureC != null) sub = `${s.latestTemperatureC.toFixed(1)}\u00b0C`;
    } else if (s.brand === 'tracker') {
      statusLabel = stale ? 'stale' : 'live';
      statusCol   = stale ? SC.unknown : '#34d399';
      if (s.latestGpsSatellites != null) { mainValue = String(s.latestGpsSatellites); unit = 'sats'; }
      if (s.latestLatitude != null && s.latestLongitude != null)
        sub = `${s.latestLatitude.toFixed(4)}, ${s.latestLongitude.toFixed(4)}`;
    } else if (s.latestBatteryPct != null) {
      const pct   = s.latestBatteryPct;
      statusCol   = stale ? SC.unknown : (pct > 50 ? SC.ok : pct > 20 ? SC.warn : SC.danger);
      statusLabel = stale ? 'stale' : (pct > 50 ? 'ok' : pct > 20 ? 'low' : 'critical');
      mainValue   = String(pct);
      unit        = '%';
      if (s.latestTemperatureC != null) sub = `${s.latestTemperatureC.toFixed(1)}\u00b0C`;
    } else if (s.latestTemperatureC != null) {
      mainValue = s.latestTemperatureC.toFixed(1);
      unit      = '\u00b0C';
    }

    const rawName  = s.wheelPosition
      ? (WHEEL_LABELS[s.wheelPosition] ?? s.wheelPosition)
      : (s.sensorName ?? (s.brand === 'tracker' ? s.vehicleName : null) ?? (BRAND_LABELS[s.brand] ?? s.brand));
    const name       = escHTML(rawName);
    const brandLabel = escHTML(BRAND_LABELS[s.brand] ?? s.brand);
    const ago        = fmtAgo(s.latestTimestamp);
    const valueHtml  = mainValue
      ? `<div class="fc-value">${mainValue}<span class="fc-unit">${escHTML(unit)}</span></div>`
      : `<div class="fc-value fc-no-data">\u2013</div>`;

    return `<div class="fleet-card${sel ? ' fc-selected' : ''}" data-sid="${escAttr(s.sensorID)}">
      <div class="fc-header">
        <div class="fc-status-dot" style="background:${statusCol}"></div>
        <div class="fc-name" title="${escAttr(rawName)}">${name}</div>
      </div>
      <div class="fc-brand">${brandLabel}</div>
      ${valueHtml}
      ${sub ? `<div class="fc-sub">${escHTML(sub)}</div>` : ''}
      <div class="fc-badge" style="background:${statusCol}22;color:${statusCol}">${statusLabel}</div>
      <div class="fc-last">${ago}</div>
    </div>`;
  }).join('');

  D.fleetCont.innerHTML = `<div class="fleet-grid">${cards}</div>`;
  D.fleetCont.querySelectorAll('.fleet-card[data-sid]').forEach(card => {
    card.addEventListener('click', () => {
      const sid = card.dataset.sid;
      selectSensor(sid).then(() => {
        const picked = S.sensors.find(s => s.sensorID === sid);
        const mode = (picked && picked.brand !== 'airtag' && picked.brand !== 'tracker')
          ? 'chart' : 'map';
        showMode(mode);
        pushHash();
      });
    });
  });
}

// ─── Threshold alerts (5.2) ───────────────────────────────────────────────────
//
// Thresholds stored in localStorage key 'netmap-thresholds':
//   { [sensorID]: { minBar?, maxBar?, maxTempC?, minBatPct? } }
//
const THRESH_KEY = 'netmap-thresholds';

function loadThresholds() {
  try { return JSON.parse(localStorage.getItem(THRESH_KEY) ?? '{}'); } catch { return {}; }
}
function saveThresholds(obj) { localStorage.setItem(THRESH_KEY, JSON.stringify(obj)); }
function getThreshold(sensorID) { return loadThresholds()[sensorID] ?? {}; }
function setThreshold(sensorID, patch) {
  const all = loadThresholds();
  all[sensorID] = { ...(all[sensorID] ?? {}), ...patch };
  saveThresholds(all);
}
function clearThreshold(sensorID) {
  const all = loadThresholds(); delete all[sensorID]; saveThresholds(all);
}

const _alerted = new Map(); // sensorID → last alert key (de-duplication)

function checkThresholdAlert(sensor) {
  const t = getThreshold(sensor.sensorID);
  if (!Object.keys(t).length) return;
  const msgs = [], key = [];
  if (t.minBar   != null && sensor.latestPressureBar  != null && sensor.latestPressureBar  < t.minBar)
    { msgs.push(`Low pressure: ${sensor.latestPressureBar.toFixed(2)} bar (≥ ${t.minBar} bar)`);  key.push(`p<${t.minBar}`);    }
  if (t.maxBar   != null && sensor.latestPressureBar  != null && sensor.latestPressureBar  > t.maxBar)
    { msgs.push(`High pressure: ${sensor.latestPressureBar.toFixed(2)} bar (≤ ${t.maxBar} bar)`); key.push(`p>${t.maxBar}`);    }
  if (t.maxTempC != null && sensor.latestTemperatureC != null && sensor.latestTemperatureC > t.maxTempC)
    { msgs.push(`High temp: ${sensor.latestTemperatureC.toFixed(1)} °C (≤ ${t.maxTempC} °C)`);    key.push(`t>${t.maxTempC}`);  }
  if (t.minBatPct!= null && sensor.latestBatteryPct   != null && sensor.latestBatteryPct   < t.minBatPct)
    { msgs.push(`Low battery: ${sensor.latestBatteryPct}% (≥ ${t.minBatPct}%)`);                  key.push(`b<${t.minBatPct}`); }
  if (!msgs.length) { _alerted.delete(sensor.sensorID); return; }
  const alertKey = key.join('|');
  if (_alerted.get(sensor.sensorID) === alertKey) return;
  _alerted.set(sensor.sensorID, alertKey);
  const label = sensor.sensorName ?? sensor.wheelPosition ?? sensor.sensorID;
  showToast(`${label}: ${msgs.join(' · ')}`, 'warn');
  if (Notification.permission === 'granted')
    new Notification(`NetMap — ${label}`, { body: msgs.join('\n'), icon: '/favicon.ico' });
}

function checkCurrentSensorAlerts() {
  const s = S.sensors.find(x => x.sensorID === S.selected);
  if (s) checkThresholdAlert(s);
}

function renderThresholdEditor(sensorID) {
  const el = $('threshold-editor');
  if (!el) return;
  const s = S.sensors.find(x => x.sensorID === sensorID);
  if (!s) { el.innerHTML = ''; return; }
  const t = getThreshold(sensorID);
  const hasPressure = isTpms(s);
  const hasBattery  = s.latestBatteryPct != null;
  const hasTemp     = s.latestTemperatureC != null;
  if (!hasPressure && !hasBattery && !hasTemp) { el.innerHTML = ''; return; }

  el.innerHTML = `
    <div class="thresh-editor">
      <div class="thresh-inline">
        <span class="thresh-title"><svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" style="vertical-align:-1px"><path stroke="none" d="M0 0h24v24H0z" fill="none"/><path d="M12 9v4"/><path d="M10.363 3.591l-8.106 13.534a1.914 1.914 0 0 0 1.636 2.871h16.214a1.914 1.914 0 0 0 1.636 -2.87l-8.106 -13.536a1.914 1.914 0 0 0 -3.274 0"/><path d="M12 16h.01"/></svg> Alerts</span>
        ${hasPressure ? `<label class="thresh-field"><span class="thresh-lbl">P≥</span><input class="thresh-input" id="th-min-bar" type="number" step="0.05" placeholder="–" value="${t.minBar != null ? t.minBar : ''}"><span class="thresh-unit">bar</span></label>` : ''}
        ${hasPressure ? `<label class="thresh-field"><span class="thresh-lbl">P≤</span><input class="thresh-input" id="th-max-bar" type="number" step="0.05" placeholder="–" value="${t.maxBar != null ? t.maxBar : ''}"><span class="thresh-unit">bar</span></label>` : ''}
        ${hasTemp     ? `<label class="thresh-field"><span class="thresh-lbl">T≤</span><input class="thresh-input" id="th-max-temp" type="number" step="1" placeholder="–" value="${t.maxTempC != null ? t.maxTempC : ''}"><span class="thresh-unit">°C</span></label>` : ''}
        ${hasBattery  ? `<label class="thresh-field"><span class="thresh-lbl">Bat≥</span><input class="thresh-input" id="th-min-bat" type="number" step="1" min="0" max="100" placeholder="–" value="${t.minBatPct != null ? t.minBatPct : ''}"><span class="thresh-unit">%</span></label>` : ''}
        <button class="modal-btn admin-small-btn" id="th-save-btn">Save</button>
        <button class="modal-btn admin-small-btn" id="th-clear-btn" style="background:transparent;color:var(--fg3)">Clear</button>
        <button class="modal-btn admin-small-btn" id="th-notif-btn">${
          Notification.permission === 'granted'
            ? `<svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" style="vertical-align:-1px"><path stroke="none" d="M0 0h24v24H0z" fill="none"/><path d="M5 12l5 5l10 -10"/></svg>`
            : Notification.permission === 'denied'
            ? `<svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="#f87171" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" style="vertical-align:-1px"><path stroke="none" d="M0 0h24v24H0z" fill="none"/><path d="M18 6l-12 12"/><path d="M6 6l12 12"/></svg>`
            : `<svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" style="vertical-align:-1px"><path stroke="none" d="M0 0h24v24H0z" fill="none"/><path d="M10 5a2 2 0 0 1 4 0a7 7 0 0 1 4 6v3a4 4 0 0 0 2 3h-16a4 4 0 0 0 2 -3v-3a7 7 0 0 1 4 -6"/><path d="M9 17v1a3 3 0 0 0 6 0v-1"/></svg>`}</button>
      </div>
    </div>`;

  $('th-save-btn')?.addEventListener('click', () => {
    const patch = {};
    const minBar  = parseFloat($('th-min-bar')?.value  ?? '');
    const maxBar  = parseFloat($('th-max-bar')?.value  ?? '');
    const maxTemp = parseFloat($('th-max-temp')?.value ?? '');
    const minBat  = parseFloat($('th-min-bat')?.value  ?? '');
    if (!isNaN(minBar))  patch.minBar    = minBar;
    if (!isNaN(maxBar))  patch.maxBar    = maxBar;
    if (!isNaN(maxTemp)) patch.maxTempC  = maxTemp;
    if (!isNaN(minBat))  patch.minBatPct = minBat;
    setThreshold(sensorID, patch);
    showToast('Thresholds saved');
  });
  $('th-clear-btn')?.addEventListener('click', () => {
    clearThreshold(sensorID); _alerted.delete(sensorID);
    renderThresholdEditor(sensorID); showToast('Thresholds cleared');
  });
  $('th-notif-btn')?.addEventListener('click', async () => {
    if (Notification.permission !== 'granted') {
      const p = await Notification.requestPermission();
      if (p === 'granted') showToast('Browser notifications enabled');
      else showToast('Notifications blocked by browser', 'error');
    }
    renderThresholdEditor(sensorID);
  });
}

// ─── Select sensor ────────────────────────────────────────────────────────────
async function selectSensor(sensorID) {
  if (!sensorID) return;
  S.selected = sensorID;
  renderSidebar();
  pushHash();
  D.content.classList.add('loading');
  try {
    await loadRecords();
    renderAll();
  } catch (e) {
    console.error('selectSensor:', e);
  } finally {
    D.content.classList.remove('loading');
  }
}

// ─── Refresh ──────────────────────────────────────────────────────────────────
async function refresh() {
  if (S.loading) return;           // prevent concurrent refresh calls
  S.loading = true;
  try {
    await Promise.all([loadSensors(), loadServerVehicles()]);
    renderSidebar();
    if (S.selected) { await loadRecords(); renderAll(); }
  } catch (e) { console.error('refresh:', e); }
  finally { S.loading = false; }
}

// ─── WebSocket live push (5.1) ────────────────────────────────────────────────
function _wsConnect() {
  if (S.ws && S.ws.readyState <= WebSocket.OPEN) return; // already connecting or open
  const proto = location.protocol === 'https:' ? 'wss:' : 'ws:';
  const ws    = new WebSocket(`${proto}//${location.host}/api/ws`);
  S.ws = ws;

  ws.addEventListener('open', () => {
    const wasPolling = !!S.timer;
    S.wsConnected = true;
    // WebSocket connected — stop polling timer; the push channel handles refresh
    if (S.timer) { clearInterval(S.timer); S.timer = null; }
    _setWsIndicator(true);
    // If we were polling (i.e. reconnecting after a server restart / disconnect),
    // do a full refresh immediately so stale timestamps are cleared.
    if (wasPolling) refresh();
  });

  ws.addEventListener('message', e => {
    let msg;
    try { msg = JSON.parse(e.data); } catch { return; }
    if (!msg) return;

    if (msg.type === 'new_event') {
      // Refresh the event table if the pushed tracker is currently displayed
      if (msg.imei === S.selected && S.mode === 'table') renderTable();
      return;
    }

    if (msg.type !== 'record') return;

    // Update the matching sensor's latest values in S.sensors
    const s = S.sensors.find(x => x.sensorID === msg.sensorID);
    if (s) {
      if (msg.pressureBar  != null) s.latestPressureBar  = msg.pressureBar;
      if (msg.temperatureC != null) s.latestTemperatureC = msg.temperatureC;
      if (msg.batteryPct   != null) s.latestBatteryPct   = msg.batteryPct;
      s.latestTimestamp = msg.timestamp ?? s.latestTimestamp;
    }

    // Re-render sidebar status dots + fleet summary without a full round-trip
    renderSidebar();

    // If the pushed sensor is currently selected, do a full reload of its records
    if (msg.sensorID === S.selected) {
      loadRecords().then(() => renderAll());
    }

    // Check threshold alerts on incoming live data (5.2)
    if (s) checkThresholdAlert(s);
  });

  ws.addEventListener('close', e => {
    S.wsConnected = false;
    S.ws = null;
    _setWsIndicator(false);
    // Unexpected close — fall back to polling until WS reconnects
    if (!S.timer) S.timer = setInterval(refresh, REFRESH_MS);
    if (!e.wasClean) setTimeout(_wsConnect, WS_RECONNECT_MS);
  });

  ws.addEventListener('error', () => {
    ws.close();
  });
}

function _setWsIndicator(connected) {
  const pill  = D.livePill;
  const label = D.liveLabel;
  if (!pill) return;
  if (connected) {
    pill.classList.add('ws-live');
    pill.title = 'Live push — WebSocket connected';
  } else {
    pill.classList.remove('ws-live');
    pill.title = '';
  }
}

// ─── Event setup ──────────────────────────────────────────────────────────────
function setup() {
  // Sidebar collapse toggle
  $('sidebar-toggle').addEventListener('click', () => {
    const collapsed = $('main').classList.toggle('sidebar-collapsed');
    const btn = $('sidebar-toggle');
    btn.title        = collapsed ? 'Expand sidebar' : 'Collapse sidebar';
    btn.setAttribute('aria-label', collapsed ? 'Expand sidebar' : 'Collapse sidebar');
  });

  // Asset type selector change (show/hide vehicle vs tool fields)
  $('vf-type').addEventListener('change', () => updateModalFields($('vf-type').value));

  // Admin drawer
  const adminBtn = $('admin-btn');
  if (adminBtn) adminBtn.addEventListener('click', () => openAdminPanel());
  $('admin-drawer-close').addEventListener('click', closeAdminPanel);
  $('admin-backdrop').addEventListener('click', closeAdminPanel);
  document.querySelectorAll('.admin-nav-btn').forEach(btn =>
    btn.addEventListener('click', () => switchAdminTab(btn.dataset.tab))
  );
  document.addEventListener('keydown', e => {
    if (e.key === 'Escape' && $('logs-overlay').style.display !== 'none') { closeLogsViewer(); return; }
    if (e.key === 'Escape' && $('admin-drawer').classList.contains('open')) closeAdminPanel();
  });
  // Logs viewer
  const logsBtn = $('logs-btn');
  if (logsBtn) logsBtn.addEventListener('click', openLogsViewer);
  $('logs-close-btn')?.addEventListener('click', closeLogsViewer);
  $('logs-overlay')?.addEventListener('click', e => { if (e.target === $('logs-overlay')) closeLogsViewer(); });
  $('logs-clear-btn')?.addEventListener('click', () => { $('logs-output').innerHTML = ''; /* _logsLastIndex unchanged: only fetch new lines from this point */ });
  document.querySelectorAll('.logs-filter-btn').forEach(btn => {
    btn.addEventListener('click', () => _toggleLogFilter(btn.dataset.cat));
  });
  // Tab action buttons
  $('admin-add-user-btn').addEventListener('click',  () => $('new-user-modal').style.display = 'flex');
  $('admin-add-asset-btn').addEventListener('click', () => openVehicleModal());
  $('ota-refresh-btn')?.addEventListener('click', () => renderOtaPanel());
  $('admin-add-profile-btn')?.addEventListener('click', () => openProfileModal(null));
  $('new-user-modal-close').addEventListener('click', () => $('new-user-modal').style.display = 'none');
  $('new-user-cancel-btn').addEventListener('click',  () => $('new-user-modal').style.display = 'none');
  $('new-user-modal').addEventListener('click', e => { if (e.target === $('new-user-modal')) $('new-user-modal').style.display = 'none'; });
  $('new-user-form').addEventListener('submit', async e => {
    e.preventDefault();
    const errEl = $('nu-error');
    const btn   = $('nu-save-btn');
    errEl.style.display = 'none'; btn.disabled = true;
    try {
      const result = await adminCreateUser({
        email: $('nu-email').value.trim(),
        role:  $('nu-role').value,
      });
      $('new-user-modal').style.display = 'none';
      $('nu-email').value = ''; $('nu-role').value = 'user';
      alert(`User created!
Email: ${result.email}
Temporary password: ${result.password}

Share this with the user — it is only shown once.`);
      await renderUsersPanel(); renderAdminPanel();
    } catch (err) {
      errEl.textContent = err.message; errEl.style.display = 'block';
    } finally { btn.disabled = false; }
  });

  // Vehicle dropdown
  D.vehicleSelect.addEventListener('change', () => {
    S.vehicleFilter = D.vehicleSelect.value || null;
    renderSensors();
    // Auto-select first sensor of chosen vehicle
    const first = S.sensors.find(s => s.vehicleID === S.vehicleFilter);
    if (first) selectSensor(first.sensorID);
    else { S.selected = null; S.records = []; renderAll(); pushHash(); }
  });

  // Add / edit vehicle buttons
  const addVBtn = $('add-vehicle-btn');
  if (addVBtn) addVBtn.addEventListener('click', () => openVehicleModal());
  const closeVBtn = $('vehicle-modal-close');
  if (closeVBtn) closeVBtn.addEventListener('click', closeVehicleModal);
  const cancelBtn = $('modal-cancel-btn');
  if (cancelBtn) cancelBtn.addEventListener('click', closeVehicleModal);
  $('vehicle-modal').addEventListener('click', e => { if (e.target === $('vehicle-modal')) closeVehicleModal(); });

  // Vehicle form submit
  $('vehicle-form').addEventListener('submit', async e => {
    e.preventDefault();
    const payload = {
      name:         $('vf-name').value.trim(),
      assetTypeID:  $('vf-type').style && $('vf-type-row').style.display !== 'none'
                      ? ($('vf-type').value || 'vehicle') : undefined,
      brand:        $('vf-brand').value.trim()     || null,
      modelName:    $('vf-model').value.trim()     || null,
      year:         $('vf-year').value  ? Number($('vf-year').value) : null,
      vrn:          $('vf-vrn').value.trim()       || null,
      vin:          $('vf-vin').value.trim()        || null,
      serialNumber: $('vf-serial').value.trim()    || null,
      toolType:     $('vf-tool-type').value.trim() || null,
      iconKey:      $('vf-icon-key').value              || null,
    };
    const errEl = $('modal-error');
    const saveB = $('modal-save-btn');
    errEl.style.display = 'none'; saveB.disabled = true;
    try {
      await saveVehicle(payload);
      closeVehicleModal();
      await loadServerVehicles();
      renderSidebar();
      if ($('admin-drawer').classList.contains('open')) { await renderAssetsPanel(); renderAdminPanel(); }
    } catch (err) {
      errEl.textContent = err.message; errEl.style.display = 'block';
    } finally { saveB.disabled = false; }
  });

  // Vehicle delete button
  $('modal-delete-btn').addEventListener('click', async () => {
    if (!_editingVehicleID || !confirm('Delete this vehicle from the server? Sensor data is kept.')) return;
    const errEl = $('modal-error');
    try {
      await deleteVehicle(_editingVehicleID);
      closeVehicleModal();
      await loadServerVehicles();
      S.vehicleFilter = null; S.selected = null; S.records = [];
      renderSidebar(); renderAll();
      if ($('admin-drawer').classList.contains('open')) { await renderAssetsPanel(); renderAdminPanel(); }
    } catch (err) { errEl.textContent = err.message; errEl.style.display = 'block'; }
  });

  // Auth overlay form
  $('auth-form').addEventListener('submit', async e => {
    e.preventDefault();
    const mode   = $('auth-overlay').dataset.mode;
    const usernm = $('auth-email').value.trim();
    const passwd = $('auth-password').value;
    const errEl  = $('auth-error');
    const btn    = $('auth-submit-btn');
    errEl.style.display = 'none'; btn.disabled = true; btn.textContent = '…';
    try {
      const endpoint = mode === 'setup' ? '/api/auth/setup' : '/api/auth/login';
      const res = await fetch(endpoint, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ email: usernm, password: passwd }),
      });
      if (!res.ok) { const e2 = await res.json().catch(() => ({})); throw new Error(e2.reason || `HTTP ${res.status}`); }
      const data = await res.json();
      saveAuth({ username: data.email, role: data.role }); applyAuthUI();
      $('auth-overlay').style.display = 'none';
      resolveAuth();
    } catch (err) {
      errEl.textContent = err.message; errEl.style.display = 'block';
      btn.disabled = false; btn.textContent = mode === 'setup' ? 'Create Account' : 'Sign in';
    }
  });

  // Logout
  const logoutBtn = $('logout-btn');
  if (logoutBtn) logoutBtn.addEventListener('click', async () => {
    await fetch('/api/auth/logout', { method: 'POST', headers: authHeaders() }).catch(() => {});
    clearAuth(); location.reload();
  });

  // Sensor click
  D.sensorList.addEventListener('click', e => {
    const row = e.target.closest('[data-sid]');
    if (!row) return;
    const fromTpmsCard = !!e.target.closest('.tpms-group-card');
    if (fromTpmsCard) S.mode = 'wheels';
    selectSensor(row.dataset.sid);
  });

  // Period buttons
  $('period-bar').addEventListener('click', e => {
    const btn = e.target.closest('.period-btn');
    if (!btn) return;
    document.querySelectorAll('.period-btn').forEach(b => b.classList.remove('active'));
    btn.classList.add('active');
    S.period = btn.dataset.period;
    D.customRange.style.display = S.period === 'custom' ? 'flex' : 'none';
    if (S.period !== 'custom') selectSensor(S.selected);
    else pushHash();
  });

  // Custom date pickers
  D.customFrom.addEventListener('change', () => { S.customFrom = new Date(D.customFrom.value); if (S.period === 'custom') selectSensor(S.selected); });
  D.customTo.addEventListener('change',   () => { S.customTo   = new Date(D.customTo.value);   if (S.period === 'custom') selectSensor(S.selected); });

  // Mode tabs
  $('mode-bar').addEventListener('click', e => {
    const btn = e.target.closest('.mode-btn');
    if (!btn) return;
    document.querySelectorAll('.mode-btn').forEach(b => b.classList.remove('active'));
    btn.classList.add('active');
    S.mode = btn.dataset.mode;
    showMode(S.mode);
    if (S.mode === 'chart')  renderChart();
    if (S.mode === 'map')    renderMap();
    if (S.mode === 'table')  renderTable();
    if (S.mode === 'alerts') renderAlerts();
    if (S.mode === 'device') renderDevice();
    if (S.mode === 'wheels') renderWheels();
    if (S.mode === 'errors') renderErrors();
    pushHash();
  });

  $('export-csv-btn')?.addEventListener('click', exportCSV);

  $('refresh-btn').addEventListener('click', refresh);

  // Theme toggle
  $('theme-btn').addEventListener('click', () => {
    const isDark = document.documentElement.getAttribute('data-theme') !== 'dark';
    if (isDark) {
      document.documentElement.setAttribute('data-theme', 'dark');
    } else {
      document.documentElement.removeAttribute('data-theme');
    }
    localStorage.setItem('netmap-theme', isDark ? 'dark' : 'light');
  });

  // Init custom date inputs
  const now = new Date();
  D.customTo.value   = toDatetimeLocal(now);
  D.customFrom.value = toDatetimeLocal(new Date(now - 86_400_000));
}
// ─── Admin panel ───────────────────────────────────────────────────────────────
async function adminCreateUser(payload) {
  const res = await fetch('/api/admin/users', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', ...authHeaders() },
    body: JSON.stringify(payload),
  });
  if (!res.ok) { const e = await res.json().catch(() => ({})); throw new Error(e.reason || `HTTP ${res.status}`); }
  return res.json();
}
async function adminDeleteUser(id) {
  const res = await fetch(`/api/admin/users/${id}`, { method: 'DELETE', headers: authHeaders() });
  if (!res.ok) { const e = await res.json().catch(() => ({})); throw new Error(e.reason || `HTTP ${res.status}`); }
}
async function adminDeleteVehicle(id) {
  const res = await fetch(`/api/vehicles/${id}`, { method: 'DELETE', headers: authHeaders() });
  if (!res.ok) { const e = await res.json().catch(() => ({})); throw new Error(e.reason || `HTTP ${res.status}`); }
}
async function adminCreateTracker(imei, vehicleID, sensorName) {
  const res = await fetch('/api/admin/trackers', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', ...authHeaders() },
    body: JSON.stringify({ imei, vehicleID, sensorName: sensorName || undefined }),
  });
  if (!res.ok) { const e = await res.json().catch(() => ({})); throw new Error(e.reason || `HTTP ${res.status}`); }
}
async function adminDeleteTracker(imei) {
  const res = await fetch(`/api/admin/trackers/${encodeURIComponent(imei)}`, {
    method: 'DELETE', headers: authHeaders(),
  });
  if (!res.ok) { const e = await res.json().catch(() => ({})); throw new Error(e.reason || `HTTP ${res.status}`); }
}
async function adminPairTracker(imei, vehicleID) {
  const res = await fetch('/api/admin/trackers/pair', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', ...authHeaders() },
    body: JSON.stringify({ imei, vehicleID }),
  });
  if (!res.ok) { const e = await res.json().catch(() => ({})); throw new Error(e.reason || `HTTP ${res.status}`); }
}
async function adminUpdateTracker(imei, sensorName) {
  const res = await fetch(`/api/admin/trackers/${encodeURIComponent(imei)}`, {
    method: 'PATCH',
    headers: { ...authHeaders(), 'Content-Type': 'application/json' },
    body: JSON.stringify({ sensorName: sensorName || null }),
  });
  if (!res.ok) throw new Error(await res.text());
}

async function adminRenameSensor(sensorID, sensorName) {
  const res = await fetch(`/api/admin/sensors/${encodeURIComponent(sensorID)}`, {
    method: 'PATCH',
    headers: { ...authHeaders(), 'Content-Type': 'application/json' },
    body: JSON.stringify({ sensorName: sensorName || null }),
  });
  if (!res.ok) throw new Error(await res.text());
}
async function openTrackerConfigModal(imei) {
  const modal = $('tracker-config-modal');
  const body  = $('tracker-config-modal-body');
  // Must match wakeup_cause_to_str() values in firmware (netmap_reporter.c) — uppercase
  const WAKE_SOURCES = ['VOLTAGE_RISE', 'CAN_ACTIVITY', 'TIMER_BACKUP', 'ESPNOW_HMI', 'IMU_MOTION'];

  const close = () => { modal.style.display = 'none'; };
  $('tracker-config-modal-close').onclick = close;
  modal.onclick = e => { if (e.target === modal) close(); };
  modal.style.display = 'flex';
  body.innerHTML = '<p style="color:var(--fg3);font-size:12px">Loading\u2026</p>';

  let cfg, profiles;
  try {
    [cfg, profiles] = await Promise.all([
      adminGetTrackerConfig(imei),
      adminGetProfiles().catch(() => []),
    ]);
  } catch (err) {
    body.innerHTML = `<p style="color:#f87171;font-size:12px">${escHTML(err.message)}</p>`;
    return;
  }

  const renderModal = (cfg, profiles) => {
    const sys = cfg.system; const db = cfg.driverBehavior; const dbT = db.thresholds;
    const wakes = sys.wakeUpSourcesEnabled ?? [];
    const wakeRows = WAKE_SOURCES.map(src =>
      `<label style="display:flex;align-items:center;gap:8px;font-size:12px;cursor:pointer;margin-bottom:4px">` +
      `<input type="checkbox" name="tcm-wake-${src}"${wakes.includes(src) ? ' checked' : ''}> ` +
      escHTML(src.replace(/_/g, ' ')) + `</label>`
    ).join('');

    const currentProfile = profiles.find(p => p.id === cfg.profileID);
    const profileOptions = [
      `<option value="">Custom</option>`,
      ...profiles.map(p => `<option value="${escAttr(p.id)}"${p.id === cfg.profileID ? ' selected' : ''}>${escHTML(p.name)}</option>`)
    ].join('');

    body.innerHTML =
      // ── Profile selector ──
      `<div class="tcm-profile-row">` +
      `<label style="font-size:11px;color:var(--fg3);white-space:nowrap">Based on profile</label>` +
      `<select id="tcm-profile-select" class="tcm-input" style="flex:1;min-width:0">${profileOptions}</select>` +
      `<button type="button" id="tcm-apply-profile" class="modal-btn-secondary admin-small-btn" style="white-space:nowrap">Apply profile</button>` +
      `</div>` +
      `<div style="margin-bottom:12px;font-size:11px;color:var(--fg3)">Config version: <strong style="color:var(--fg2)">${cfg.schemaVersion ?? 1}</strong></div>` +
      `<div style="display:grid;grid-template-columns:1fr 1fr;gap:0 24px">` +
      // ── System ──
      `<div>` +
      `<div class="tcm-section-title">System</div>` +
      `<div class="modal-field"><label>Ping interval (min)</label>` +
      `<input class="tcm-input" type="number" id="tcm-ping" min="1" max="60" value="${sys.pingIntervalMin}"></div>` +
      `<div class="modal-field"><label>Sleep delay (min)</label>` +
      `<input class="tcm-input" type="number" id="tcm-sleep" min="1" max="120" value="${sys.sleepDelayMin}"></div>` +
      `<div class="modal-field"><label>Wake sources</label>${wakeRows}</div>` +
      `</div>` +
      // ── Driver Behavior ──
      `<div>` +
      `<div class="tcm-section-title">Driver Behavior</div>` +
      `<div class="modal-field"><label>Harsh braking (m/s²)</label>` +
      `<input class="tcm-input" type="number" id="tcm-hbrk" min="0.1" max="10" step="0.1" value="${dbT.harshBraking}"></div>` +
      `<div class="modal-field"><label>Harsh accel. (m/s²)</label>` +
      `<input class="tcm-input" type="number" id="tcm-hacc" min="0.1" max="10" step="0.1" value="${dbT.harshAcceleration}"></div>` +
      `<div class="modal-field"><label>Cornering (m/s²)</label>` +
      `<input class="tcm-input" type="number" id="tcm-hcor" min="0.1" max="10" step="0.1" value="${dbT.harshCornering}"></div>` +
      `<div class="modal-field"><label>Overspeed (km/h)</label>` +
      `<input class="tcm-input" type="number" id="tcm-ovspd" min="50" max="300" value="${dbT.overspeed}"></div>` +
      `<div class="modal-field"><label>Min. speed (km/h)</label>` +
      `<input class="tcm-input" type="number" id="tcm-minspd" min="0" max="50" value="${db.minimumSpeedKmh}"></div>` +
      `<label style="display:flex;align-items:center;gap:8px;font-size:12px;cursor:pointer;margin-bottom:12px">` +
      `<input type="checkbox" id="tcm-beep"${db.beepEnabled ? ' checked' : ''}> Beep alerts</label>` +
      `</div>` +
      `</div>` +
      `<div id="tcm-error" class="auth-error" style="display:none;margin-top:8px"></div>` +
      `<div class="modal-actions">` +
      `<button type="button" id="tcm-cancel" class="modal-btn-secondary">Cancel</button>` +
      `<button type="button" id="tcm-save" class="modal-btn-primary">Save</button>` +
      `</div>`;

    body.querySelector('#tcm-cancel').addEventListener('click', close);

    // Apply profile → stamp profile fields onto tracker via server, then refresh form
    body.querySelector('#tcm-apply-profile')?.addEventListener('click', async () => {
      const selectedProfileID = body.querySelector('#tcm-profile-select')?.value;
      if (!selectedProfileID) { showToast('Select a profile first.'); return; }
      const applyBtn = body.querySelector('#tcm-apply-profile');
      applyBtn.disabled = true;
      try {
        const updatedCfg = await adminApplyProfile(imei, selectedProfileID);
        renderModal(updatedCfg, profiles);
        showToast('Profile applied. Review and save if needed.');
      } catch (err) {
        const errEl = body.querySelector('#tcm-error');
        if (errEl) { errEl.textContent = err.message; errEl.style.display = 'block'; }
      } finally { applyBtn.disabled = false; }
    });

    body.querySelector('#tcm-save').addEventListener('click', async () => {
      const errEl  = body.querySelector('#tcm-error');
      const saveEl = body.querySelector('#tcm-save');
      const getNum = id => parseFloat(body.querySelector(`#${id}`)?.value) || 0;
      const getInt = id => parseInt(body.querySelector(`#${id}`)?.value, 10) || 0;
      const selectedWakes = WAKE_SOURCES.filter(src => body.querySelector(`[name="tcm-wake-${src}"]`)?.checked);
      const payload = {
        imei,
        system: { pingIntervalMin: getInt('tcm-ping'), sleepDelayMin: getInt('tcm-sleep'), wakeUpSourcesEnabled: selectedWakes },
        driverBehavior: {
          thresholds: { harshBraking: getNum('tcm-hbrk'), harshAcceleration: getNum('tcm-hacc'), harshCornering: getNum('tcm-hcor'), overspeed: getNum('tcm-ovspd') },
          minimumSpeedKmh: getInt('tcm-minspd'),
          beepEnabled: !!(body.querySelector('#tcm-beep')?.checked),
        },
      };
      saveEl.disabled = true; errEl.style.display = 'none';
      try {
        await adminPutTrackerConfig(imei, payload);
        close();
        showToast('Tracker configuration saved.');
        await loadSensors();
        renderSensorInfoCard();
      } catch (err) {
        errEl.textContent = err.message; errEl.style.display = 'block';
      } finally { saveEl.disabled = false; }
    });
  };

  renderModal(cfg, profiles);
}

async function adminGetTrackerConfig(imei) {
  const res = await fetch(`/api/admin/trackers/${encodeURIComponent(imei)}/config`, {
    headers: authHeaders(),
  });
  if (!res.ok) { const e = await res.json().catch(() => ({})); throw new Error(e.reason || `HTTP ${res.status}`); }
  return res.json();
}
async function adminPutTrackerConfig(imei, payload) {
  const res = await fetch(`/api/admin/trackers/${encodeURIComponent(imei)}/config`, {
    method: 'PUT',
    headers: { 'Content-Type': 'application/json', ...authHeaders() },
    body: JSON.stringify(payload),
  });
  if (!res.ok) { const e = await res.json().catch(() => ({})); throw new Error(e.reason || `HTTP ${res.status}`); }
  return res.json();
}

async function adminUnpairTracker(imei) {
  const res = await fetch(`/api/admin/trackers/${encodeURIComponent(imei)}/pair`, {
    method: 'DELETE', headers: authHeaders(),
  });
  if (!res.ok) { const e = await res.json().catch(() => ({})); throw new Error(e.reason || `HTTP ${res.status}`); }
}
async function adminLinkAsset(userID, assetID) {
  const res = await fetch(`/api/admin/users/${userID}/assets`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', ...authHeaders() },
    body: JSON.stringify({ assetID }),
  });
  if (!res.ok) { const e = await res.json().catch(() => ({})); throw new Error(e.reason || `HTTP ${res.status}`); }
}
async function adminUnlinkAsset(userID, assetID) {
  const res = await fetch(`/api/admin/users/${userID}/assets/${assetID}`, { method: 'DELETE', headers: authHeaders() });
  if (!res.ok) { const e = await res.json().catch(() => ({})); throw new Error(e.reason || `HTTP ${res.status}`); }
}
async function adminFetchSecurityEvents({ limit = 50, offset = 0, action = '', actor = '' } = {}) {
  const qs = new URLSearchParams();
  qs.set('limit', String(limit));
  qs.set('offset', String(offset));
  if (action) qs.set('action', action);
  if (actor)  qs.set('actor_email', actor);
  const res = await fetch(`/api/admin/security-events?${qs.toString()}`, { headers: authHeaders() });
  if (!res.ok) { const e = await res.json().catch(() => ({})); throw new Error(e.reason || `HTTP ${res.status}`); }
  return res.json();
}

// ─── Tracker Config Profiles API ─────────────────────────────────────────────
async function adminGetProfiles() {
  const res = await fetch('/api/admin/tracker-config-profiles', { headers: authHeaders() });
  if (!res.ok) return [];
  return res.json();
}
async function adminCreateProfile(payload) {
  const res = await fetch('/api/admin/tracker-config-profiles', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', ...authHeaders() },
    body: JSON.stringify(payload),
  });
  if (!res.ok) { const e = await res.json().catch(() => ({})); throw new Error(e.reason || `HTTP ${res.status}`); }
  return res.json();
}
async function adminUpdateProfile(id, payload) {
  const res = await fetch(`/api/admin/tracker-config-profiles/${encodeURIComponent(id)}`, {
    method: 'PUT',
    headers: { 'Content-Type': 'application/json', ...authHeaders() },
    body: JSON.stringify(payload),
  });
  if (!res.ok) { const e = await res.json().catch(() => ({})); throw new Error(e.reason || `HTTP ${res.status}`); }
  return res.json();
}
async function adminDeleteProfile(id) {
  const res = await fetch(`/api/admin/tracker-config-profiles/${encodeURIComponent(id)}`, {
    method: 'DELETE', headers: authHeaders(),
  });
  if (!res.ok) { const e = await res.json().catch(() => ({})); throw new Error(e.reason || `HTTP ${res.status}`); }
}
async function adminApplyProfile(imei, profileID) {
  const res = await fetch(`/api/admin/trackers/${encodeURIComponent(imei)}/apply-profile/${encodeURIComponent(profileID)}`, {
    method: 'POST', headers: authHeaders(),
  });
  if (!res.ok) { const e = await res.json().catch(() => ({})); throw new Error(e.reason || `HTTP ${res.status}`); }
  return res.json();
}

// ─── Profile modal (create / edit) ───────────────────────────────────────────
const WAKE_SOURCES_ALL = ['VOLTAGE_RISE', 'CAN_ACTIVITY', 'TIMER_BACKUP', 'ESPNOW_HMI', 'IMU_MOTION'];

function openProfileModal(profile) {
  const isEdit  = !!profile;
  const wakes   = profile?.system?.wakeUpSourcesEnabled ?? ['VOLTAGE_RISE', 'CAN_ACTIVITY'];
  const sys     = profile?.system     ?? { pingIntervalMin: 5, sleepDelayMin: 15 };
  const db      = profile?.driverBehavior ?? { thresholds: { harshBraking: 3.2, harshAcceleration: 3.0, harshCornering: 2.8, overspeed: 120 }, minimumSpeedKmh: 20, beepEnabled: true };
  const dbT     = db.thresholds;

  const wakeRows = WAKE_SOURCES_ALL.map(src =>
    `<label class="pm-wake-label"><input type="checkbox" name="pm-wake-${src}"${wakes.includes(src) ? ' checked' : ''}> ${escHTML(src.replace(/_/g, ' '))}</label>`
  ).join('');

  // Build modal DOM
  const overlay = document.createElement('div');
  overlay.className = 'modal-overlay';
  overlay.style.cssText = 'display:flex;z-index:9999';
  overlay.innerHTML = `
    <div class="modal-card" style="max-width:560px;width:100%">
      <div class="modal-header">
        <h3>${isEdit ? 'Edit Profile' : 'New Config Profile'}</h3>
        <button class="modal-close" id="pm-close">&#x2715;</button>
      </div>
      <div class="modal-field">
        <label>Name *</label>
        <input class="tcm-input" type="text" id="pm-name" maxlength="80" value="${escAttr(profile?.name ?? '')}" placeholder="e.g. Highway truck, Urban delivery…">
      </div>
      <div class="modal-field">
        <label>Description</label>
        <input class="tcm-input" type="text" id="pm-desc" value="${escAttr(profile?.description ?? '')}" placeholder="Optional notes…">
      </div>
      <div style="display:grid;grid-template-columns:1fr 1fr;gap:0 24px;margin-top:4px">
        <div>
          <div class="tcm-section-title">System</div>
          <div class="modal-field"><label>Ping interval (min)</label>
            <input class="tcm-input" type="number" id="pm-ping" min="1" max="1440" value="${sys.pingIntervalMin}"></div>
          <div class="modal-field"><label>Sleep delay (min)</label>
            <input class="tcm-input" type="number" id="pm-sleep" min="1" max="10080" value="${sys.sleepDelayMin}"></div>
          <div class="modal-field"><label>Wake sources</label>${wakeRows}</div>
        </div>
        <div>
          <div class="tcm-section-title">Driver Behavior</div>
          <div class="modal-field"><label>Harsh braking (m/s²)</label>
            <input class="tcm-input" type="number" id="pm-hbrk" min="0.1" max="10" step="0.1" value="${dbT.harshBraking}"></div>
          <div class="modal-field"><label>Harsh accel. (m/s²)</label>
            <input class="tcm-input" type="number" id="pm-hacc" min="0.1" max="10" step="0.1" value="${dbT.harshAcceleration}"></div>
          <div class="modal-field"><label>Cornering (m/s²)</label>
            <input class="tcm-input" type="number" id="pm-hcor" min="0.1" max="10" step="0.1" value="${dbT.harshCornering}"></div>
          <div class="modal-field"><label>Overspeed (km/h)</label>
            <input class="tcm-input" type="number" id="pm-ovspd" min="1" max="300" value="${dbT.overspeed}"></div>
          <div class="modal-field"><label>Min. speed (km/h)</label>
            <input class="tcm-input" type="number" id="pm-minspd" min="0" max="250" value="${db.minimumSpeedKmh}"></div>
          <label class="pm-beep-label"><input type="checkbox" id="pm-beep"${db.beepEnabled ? ' checked' : ''}> Beep alerts</label>
        </div>
      </div>
      <div id="pm-error" class="auth-error" style="display:none;margin-top:8px"></div>
      <div class="modal-actions">
        <button type="button" id="pm-cancel" class="modal-btn-secondary">Cancel</button>
        <button type="button" id="pm-save" class="modal-btn-primary">${isEdit ? 'Save changes' : 'Create Profile'}</button>
      </div>
    </div>`;

  document.body.appendChild(overlay);
  const get  = id => overlay.querySelector(`#${id}`);
  const num  = id => parseFloat(get(id)?.value) || 0;
  const int  = id => parseInt(get(id)?.value, 10) || 0;
  const close = () => document.body.removeChild(overlay);
  get('pm-close').addEventListener('click', close);
  get('pm-cancel').addEventListener('click', close);
  overlay.addEventListener('click', e => { if (e.target === overlay) close(); });

  get('pm-save').addEventListener('click', async () => {
    const errEl = get('pm-error');
    const btn   = get('pm-save');
    const selectedWakes = WAKE_SOURCES_ALL.filter(src => overlay.querySelector(`[name="pm-wake-${src}"]`)?.checked);
    const payload = {
      name:        get('pm-name').value.trim(),
      description: get('pm-desc').value.trim() || null,
      system: {
        pingIntervalMin:      int('pm-ping'),
        sleepDelayMin:        int('pm-sleep'),
        wakeUpSourcesEnabled: selectedWakes,
      },
      driverBehavior: {
        thresholds: {
          harshBraking:      num('pm-hbrk'),
          harshAcceleration: num('pm-hacc'),
          harshCornering:    num('pm-hcor'),
          overspeed:         num('pm-ovspd'),
        },
        minimumSpeedKmh: int('pm-minspd'),
        beepEnabled:     !!get('pm-beep')?.checked,
      },
    };
    btn.disabled = true; errEl.style.display = 'none';
    try {
      if (isEdit) await adminUpdateProfile(profile.id, payload);
      else        await adminCreateProfile(payload);
      close();
      showToast(isEdit ? 'Profile updated.' : 'Profile created.');
      await renderProfilesPanel();
      renderAdminPanel();
    } catch (err) {
      errEl.textContent = err.message; errEl.style.display = 'block';
    } finally { btn.disabled = false; }
  });
}

// ─── Profiles Panel ───────────────────────────────────────────────────────────
async function renderProfilesPanel() {
  const container = $('admin-profiles-list');
  if (!container) return;

  container.innerHTML = '<p class="admin-loading">Loading\u2026</p>';
  let profiles, trackers;
  try {
    [profiles, trackers] = await Promise.all([
      adminGetProfiles(),
      apiFetch('/api/admin/trackers'),
    ]);
    S.profiles = profiles;
  } catch (err) {
    container.innerHTML = `<p class="auth-error">${escHTML(err.message)}</p>`;
    return;
  }

  if (!profiles.length) {
    container.innerHTML = '<p class="sidebar-hint">No profiles yet. Click \u00ab + New Profile \u00bb to create one.</p>';
    return;
  }

  const trackerOptions = trackers.length
    ? trackers.map(t => `<option value="${escAttr(t.imei)}">${escHTML(t.sensorName ?? t.imei)}</option>`).join('')
    : '<option value="">No trackers</option>';

  container.innerHTML = profiles.map(p => {
    const wakes = (p.system?.wakeUpSourcesEnabled ?? []).map(s => s.replace(/_/g, '\u202F')).join(', ');
    const t = p.driverBehavior?.thresholds ?? {};
    const sys = p.system ?? {};
    const db  = p.driverBehavior ?? {};
    return `
      <div class="admin-profile-row" data-profile-id="${escAttr(p.id)}">
        <div class="admin-profile-header">
          <div class="admin-profile-meta">
            <span class="admin-profile-name">${escHTML(p.name)}</span>
            ${p.description ? `<span class="admin-profile-desc">${escHTML(p.description)}</span>` : ''}
          </div>
          <div class="admin-profile-actions">
            <button class="modal-btn-secondary admin-small-btn profile-edit-btn" title="Edit">\u270E</button>
            <button class="modal-btn-danger admin-small-btn profile-delete-btn" title="Delete">\uD83D\uDDD1</button>
          </div>
        </div>
        <div class="admin-profile-fields">
          <span>Ping&nbsp;${sys.pingIntervalMin}min</span>
          <span>Sleep&nbsp;${sys.sleepDelayMin}min</span>
          <span>Brake&nbsp;${t.harshBraking}m/s\u00B2</span>
          <span>Accel&nbsp;${t.harshAcceleration}m/s\u00B2</span>
          <span>Corner&nbsp;${t.harshCornering}m/s\u00B2</span>
          <span>Overspd&nbsp;${t.overspeed}km/h</span>
          ${db.beepEnabled ? '<span class="profile-chip">Beep ON</span>' : ''}
        </div>
        <div class="admin-profile-apply">
          <label class="admin-profile-apply-label">Apply to tracker:</label>
          <select class="profile-tracker-select">${trackerOptions}</select>
          <button class="modal-btn-primary admin-small-btn profile-apply-btn">Apply</button>
          <span class="profile-apply-status"></span>
        </div>
      </div>`;
  }).join('');

  container.querySelectorAll('.profile-edit-btn').forEach(btn => {
    btn.addEventListener('click', () => {
      const row = btn.closest('[data-profile-id]');
      const p   = profiles.find(x => x.id === row?.dataset.profileId);
      if (p) openProfileModal(p);
    });
  });

  container.querySelectorAll('.profile-delete-btn').forEach(btn => {
    btn.addEventListener('click', async () => {
      const row = btn.closest('[data-profile-id]');
      const p   = profiles.find(x => x.id === row?.dataset.profileId);
      if (!p) return;
      if (!confirm(`Delete profile "${p.name}"? Trackers using it will not be affected.`)) return;
      try {
        await adminDeleteProfile(p.id);
        showToast('Profile deleted.');
        await renderProfilesPanel();
        renderAdminPanel();
      } catch (err) { alert(err.message); }
    });
  });

  container.querySelectorAll('.profile-apply-btn').forEach(btn => {
    btn.addEventListener('click', async () => {
      const row    = btn.closest('[data-profile-id]');
      const p      = profiles.find(x => x.id === row?.dataset.profileId);
      const imei   = row?.querySelector('.profile-tracker-select')?.value;
      const status = row?.querySelector('.profile-apply-status');
      if (!p || !imei) return;
      btn.disabled = true;
      if (status) { status.textContent = ''; status.className = 'profile-apply-status'; }
      try {
        await adminApplyProfile(imei, p.id);
        if (status) { status.textContent = '\u2714 Applied'; status.className = 'profile-apply-status ok'; }
        showToast(`Profile "${p.name}" applied to ${imei}.`);
      } catch (err) {
        if (status) { status.textContent = err.message; status.className = 'profile-apply-status err'; }
      } finally { btn.disabled = false; }
    });
  });
}

async function renderAdminPanel() {
  // Hub: just update count badges
  try {
    const [users, assets, trackers, sec, profiles] = await Promise.all([
      apiFetch('/api/admin/users'),
      apiFetch('/api/vehicles'),
      apiFetch('/api/admin/trackers'),
      adminFetchSecurityEvents({ limit: 1, offset: 0, action: S.secAudit.action, actor: S.secAudit.actor }),
      adminGetProfiles(),
    ]);
    const cu = $('admin-count-users');    if (cu) cu.textContent = users.length;
    const ca = $('admin-count-assets');   if (ca) ca.textContent = assets.length;
    const ct = $('admin-count-trackers'); if (ct) ct.textContent = trackers.length;
    const cs = $('admin-count-security'); if (cs) cs.textContent = sec.total ?? 0;
    const cp = $('admin-count-profiles'); if (cp) cp.textContent = profiles.length;
    S.profiles = profiles;
  } catch (_) { /* counts unavailable */ }
}

async function renderSecurityPanel() {
  const list = $('admin-security-list');
  if (!list) return;
  const applyBtn = $('sec-filter-apply');
  const clearBtn = $('sec-filter-clear');
  const prevBtn  = $('sec-prev-btn');
  const nextBtn  = $('sec-next-btn');
  const actionEl = $('sec-filter-action');
  const actorEl  = $('sec-filter-actor');
  const pageLbl  = $('sec-page-label');
  if (!applyBtn._wired) {
    applyBtn._wired = true;
    applyBtn.addEventListener('click', async () => {
      S.secAudit.action = actionEl.value.trim();
      S.secAudit.actor  = actorEl.value.trim();
      S.secAudit.offset = 0;
      await renderSecurityPanel();
      renderAdminPanel();
    });
    clearBtn.addEventListener('click', async () => {
      actionEl.value = '';
      actorEl.value = '';
      S.secAudit.action = '';
      S.secAudit.actor = '';
      S.secAudit.offset = 0;
      await renderSecurityPanel();
      renderAdminPanel();
    });
    prevBtn.addEventListener('click', async () => {
      S.secAudit.offset = Math.max(0, S.secAudit.offset - S.secAudit.limit);
      await renderSecurityPanel();
    });
    nextBtn.addEventListener('click', async () => {
      const nextOffset = S.secAudit.offset + S.secAudit.limit;
      if (nextOffset >= S.secAudit.total) return;
      S.secAudit.offset = nextOffset;
      await renderSecurityPanel();
    });
  }

  actionEl.value = S.secAudit.action;
  actorEl.value = S.secAudit.actor;
  list.innerHTML = '<p class="admin-loading">Loading…</p>';
  try {
    const data = await adminFetchSecurityEvents({
      limit: S.secAudit.limit,
      offset: S.secAudit.offset,
      action: S.secAudit.action,
      actor: S.secAudit.actor,
    });
    const items = Array.isArray(data.items) ? data.items : [];
    S.secAudit.total = Number.isFinite(data.total) ? data.total : items.length;
    const page = Math.floor(S.secAudit.offset / S.secAudit.limit) + 1;
    const pages = Math.max(1, Math.ceil(S.secAudit.total / S.secAudit.limit));
    pageLbl.textContent = `Page ${page} / ${pages} · ${S.secAudit.total} event${S.secAudit.total !== 1 ? 's' : ''}`;
    prevBtn.disabled = S.secAudit.offset <= 0;
    nextBtn.disabled = (S.secAudit.offset + S.secAudit.limit) >= S.secAudit.total;
    if (!items.length) {
      list.innerHTML = '<p class="sidebar-hint">No security events for this filter.</p>';
      return;
    }
    list.innerHTML = items.map(ev => {
      const when = ev.createdAt ? fmtTs(ev.createdAt) : '–';
      const actor = ev.actorEmail ? escHTML(ev.actorEmail) : '<span style="opacity:.6">system</span>';
      const target = ev.targetType
        ? `<span class="admin-sec-target">${escHTML(ev.targetType)}${ev.targetID ? ' · ' + escHTML(ev.targetID) : ''}</span>`
        : '<span class="admin-sec-target" style="opacity:.6">—</span>';
      const ip = ev.ipAddress ? escHTML(ev.ipAddress) : '—';
      const meta = ev.metadataJSON ? escHTML(ev.metadataJSON) : '';
      return `<div class="admin-sec-row">
        <div class="admin-sec-head">
          <span class="admin-sec-action">${escHTML(ev.action)}</span>
          <span class="admin-sec-when">${when}</span>
        </div>
        <div class="admin-sec-sub">
          <span class="admin-sec-actor">${actor}</span>
          ${target}
          <span class="admin-sec-ip">${ip}</span>
        </div>
        ${meta ? `<pre class="admin-sec-meta">${meta}</pre>` : ''}
      </div>`;
    }).join('');
  } catch (err) {
    list.innerHTML = `<p class="auth-error">${escHTML(err.message)}</p>`;
    pageLbl.textContent = 'Page –';
    prevBtn.disabled = true;
    nextBtn.disabled = true;
  }
}

async function renderUsersPanel() {
  const list = $('admin-users-list');
  if (!list) return;
  list.innerHTML = '<p class="admin-loading">Loading\u2026</p>';
  try {
    const [users, assets] = await Promise.all([
      apiFetch('/api/admin/users'),
      apiFetch('/api/vehicles'),
    ]);
    if (!users.length) { list.innerHTML = '<p class="sidebar-hint">No users.</p>'; return; }
    list.innerHTML = users.map(u => {
      const linked = new Set(u.assetIDs || []);
      const checks = assets.length
        ? assets.map(a => `
          <label class="admin-asset-check">
            <input type="checkbox" data-user="${escAttr(u.id)}" data-asset="${escAttr(a.id)}"${linked.has(a.id) ? ' checked' : ''}>
            ${escHTML(a.name)}
          </label>`).join('')
        : '<span class="sidebar-hint">No assets</span>';
      return `
        <div class="admin-user-row" data-uid="${escAttr(u.id)}">
          <div class="admin-user-header">
            <div class="admin-user-info">
              <span class="admin-user-email">${escHTML(u.email)}</span>
              ${u.displayName ? `<span class="admin-user-dname">${escHTML(u.displayName)}</span>` : ''}
              <span class="role-badge ${normalizeRole(u.role)}">${escHTML(normalizeRole(u.role))}</span>
            </div>
            <button class="modal-btn-danger admin-small-btn" data-delete-user="${escAttr(u.id)}" title="Delete user">\uD83D\uDDD1</button>
          </div>
          <div class="admin-user-assets">${checks}</div>
        </div>`;
    }).join('');
    list.querySelectorAll('input[type=checkbox][data-user]').forEach(cb => {
      cb.addEventListener('change', async () => {
        try {
          if (cb.checked) await adminLinkAsset(cb.dataset.user, cb.dataset.asset);
          else            await adminUnlinkAsset(cb.dataset.user, cb.dataset.asset);
        } catch (err) { alert(err.message); cb.checked = !cb.checked; }
      });
    });
    list.querySelectorAll('[data-delete-user]').forEach(btn => {
      btn.addEventListener('click', async () => {
        const uid = btn.dataset.deleteUser;
        const usr = users.find(u => u.id === uid);
        if (!confirm(`Delete user ${usr?.email}? This action is irreversible.`)) return;
        try { await adminDeleteUser(uid); await renderUsersPanel(); renderAdminPanel(); }
        catch (err) { alert(err.message); }
      });
    });
  } catch (err) { list.innerHTML = `<p class="auth-error">${escHTML(err.message)}</p>`; }
}

async function renderAssetsPanel() {
  const assetsList = $('admin-assets-list');
  if (!assetsList) return;
  assetsList.innerHTML = '<p class="admin-loading">Loading\u2026</p>';
  try {
    const assets = await apiFetch('/api/vehicles');
    if (!assets.length) {
      assetsList.innerHTML = '<p class="sidebar-hint">No assets yet. Click \u00ab + New Asset \u00bb to create one.</p>';
      return;
    }
    assetsList.innerHTML = assets.map(a => {
      const atype = S.assetTypes.find(t => t.id === a.assetTypeID)
                 ?? S.assetTypes.find(t => t.name.toLowerCase() === a.assetTypeID?.toLowerCase());
      const typeName = atype?.name ?? (a.assetTypeID === 'tool' ? 'Tool' : 'Vehicle');
      const pictoSvg = (a.iconKey && PICTO_ICONS[a.iconKey])
        ? PICTO_ICONS[a.iconKey]
        : ((atype?.systemImage ?? '').includes('wrench') || typeName.toLowerCase() === 'tool' ? PICTO_ICONS.tool : PICTO_ICONS.car);
      const sub = [a.brand, a.modelName, a.year, a.vrn].filter(Boolean).join(' \u00b7 ');
      return `
        <div class="admin-asset-row" data-asset-id="${escAttr(a.id)}">
          <div class="admin-asset-picto">${pictoSvg}</div>
          <div class="admin-asset-info">
            <span class="admin-asset-name">${escHTML(a.name)}</span>
            <span class="admin-asset-meta">${escHTML(typeName)}${sub ? ' \u00b7 ' + escHTML(sub) : ''}</span>
          </div>
          <div class="admin-asset-controls">
            <button class="modal-btn-secondary admin-small-btn" data-edit-asset="${escAttr(a.id)}" title="Edit">\u270e</button>
            <button class="modal-btn-danger admin-small-btn" data-delete-asset="${escAttr(a.id)}" title="Delete">\uD83D\uDDD1</button>
          </div>
        </div>`;
    }).join('');
    assetsList.querySelectorAll('[data-edit-asset]').forEach(btn => {
      btn.addEventListener('click', () => {
        const asset = assets.find(a => a.id === btn.dataset.editAsset);
        if (asset) openVehicleModal(asset);
      });
    });
    assetsList.querySelectorAll('[data-delete-asset]').forEach(btn => {
      btn.addEventListener('click', async () => {
        const asset = assets.find(a => a.id === btn.dataset.deleteAsset);
        if (!confirm(`Delete asset "${asset?.name}"? This cannot be undone.`)) return;
        try {
          await deleteVehicle(btn.dataset.deleteAsset);
          await Promise.all([loadServerVehicles(), loadAssetTypes()]);
          renderSidebar();
          await renderAssetsPanel(); renderAdminPanel();
        } catch (err) { alert(err.message); }
      });
    });
  } catch (err) { assetsList.innerHTML = `<p class="auth-error">${escHTML(err.message)}</p>`; }
}

async function renderTrackersPanel() {
  const container = $('admin-trackers-list');
  if (!container) return;

  const addBtn    = $('admin-add-tracker-btn');
  const formEl    = $('admin-new-tracker-form');
  const imeiEl    = $('nt-imei');
  const vehicleEl = $('nt-vehicle');
  const nameEl    = $('nt-name');
  const saveBtn   = $('nt-save-btn');
  const cancelBt  = $('nt-cancel-btn');
  const errEl     = $('nt-error');

  const assets = await apiFetch('/api/vehicles').catch(() => []);
  vehicleEl.innerHTML = assets.length
    ? assets.map(a => `<option value="${escAttr(a.id)}">${escHTML(a.name)}</option>`).join('')
    : '<option value="">No assets</option>';

  if (addBtn && !addBtn._wired) {
    addBtn._wired = true;
    addBtn.addEventListener('click', () => {
      const shown = formEl.style.display !== 'none';
      formEl.style.display = shown ? 'none' : 'flex';
      if (!shown) { imeiEl.value = ''; nameEl.value = ''; errEl.style.display = 'none'; imeiEl.focus(); }
    });
    cancelBt.addEventListener('click', () => { formEl.style.display = 'none'; });
    saveBtn.addEventListener('click', async () => {
      const imei = imeiEl.value.trim();
      const vid  = vehicleEl.value;
      const name = nameEl.value.trim();
      errEl.style.display = 'none';
      if (!imei) { errEl.textContent = 'IMEI is required.'; errEl.style.display = 'block'; return; }
      if (!vid)  { errEl.textContent = 'Select a vehicle.'; errEl.style.display = 'block'; return; }
      saveBtn.disabled = true;
      try {
        await adminCreateTracker(imei, vid, name || null);
        formEl.style.display = 'none';
        await loadSensors();
        await renderTrackersPanel(); renderAdminPanel();
      } catch (err) {
        errEl.textContent = err.message; errEl.style.display = 'block';
      } finally { saveBtn.disabled = false; }
    });
  }

  container.innerHTML = '<p class="admin-loading">Loading\u2026</p>';
  try {
    const trackers = await apiFetch('/api/admin/trackers');
    if (!trackers.length) {
      container.innerHTML = '<p class="sidebar-hint">No trackers yet. Click \u00ab + New Tracker \u00bb to register one.</p>';
      return;
    }
    const vehicleOptions = assets.map(a => `<option value="${escAttr(a.id)}">${escHTML(a.name)}</option>`).join('');
    container.innerHTML = trackers.map(t => {
      const pairedVehicle = assets.find(a => a.id?.toUpperCase() === t.vehicleID?.toUpperCase());
      const selectedOptions = assets.map(a =>
        `<option value="${escAttr(a.id)}"${a.id?.toUpperCase() === t.vehicleID?.toUpperCase() ? ' selected' : ''}>${escHTML(a.name)}</option>`
      ).join('');
      return `<div class="admin-tracker-row" data-imei="${escAttr(t.imei)}">
        <div class="admin-tracker-info">
          <div class="admin-tracker-top">
            <span class="admin-tracker-imei">${escHTML(t.imei)}</span>
            <button class="admin-tracker-edit-btn" title="Edit name">&#x270F;&#xFE0E;</button>
          </div>
          <div class="admin-tracker-display">
            ${t.sensorName ? `<span class="admin-tracker-sname">${escHTML(t.sensorName)}</span>` : '<span class="admin-tracker-sname" style="opacity:.4">No name</span>'}
            ${pairedVehicle
              ? `<span class="admin-tracker-paired">\u2713 ${escHTML(pairedVehicle.name)}</span>`
              : `<span class="admin-tracker-unpaired">Unpaired</span>`}
          </div>
          <div class="admin-tracker-edit-form" style="display:none">
            <input class="tracker-name-input" type="text" placeholder="Tracker name\u2026" value="${escAttr(t.sensorName ?? '')}">
            <button class="modal-btn-primary admin-small-btn tracker-name-save-btn">Save</button>
            <button class="modal-btn admin-small-btn tracker-name-cancel-btn">Cancel</button>
          </div>
        </div>
        <div class="admin-tracker-controls">
          <select class="tracker-vehicle-select">${selectedOptions || vehicleOptions}</select>
          <button class="modal-btn-primary admin-small-btn tracker-pair-btn">Pair</button>
          ${pairedVehicle ? '<button class="modal-btn-danger admin-small-btn tracker-unpair-btn">Unlink</button>' : ''}
          <button class="modal-btn-danger admin-small-btn tracker-delete-btn" title="Delete tracker">\uD83D\uDDD1</button>
        </div>
      </div>`;
    }).join('');

    container.querySelectorAll('.admin-tracker-edit-btn').forEach(btn => {
      btn.addEventListener('click', () => {
        const row  = btn.closest('[data-imei]');
        const disp = row.querySelector('.admin-tracker-display');
        const form = row.querySelector('.admin-tracker-edit-form');
        disp.style.display = 'none';
        form.style.display = 'flex';
        form.querySelector('.tracker-name-input').focus();
      });
    });
    container.querySelectorAll('.tracker-name-cancel-btn').forEach(btn => {
      btn.addEventListener('click', () => {
        const row  = btn.closest('[data-imei]');
        row.querySelector('.admin-tracker-display').style.display = '';
        row.querySelector('.admin-tracker-edit-form').style.display = 'none';
      });
    });
    container.querySelectorAll('.tracker-name-save-btn').forEach(btn => {
      btn.addEventListener('click', async () => {
        const row  = btn.closest('[data-imei]');
        const imei = row.dataset.imei;
        const name = row.querySelector('.tracker-name-input').value.trim();
        btn.disabled = true;
        try {
          await adminUpdateTracker(imei, name || null);
          await loadSensors();
          await renderTrackersPanel(); renderAdminPanel();
        } catch (err) { alert(err.message); btn.disabled = false; }
      });
    });

    container.querySelectorAll('.tracker-pair-btn').forEach(btn => {
      btn.addEventListener('click', async () => {
        const row = btn.closest('[data-imei]');
        const imei = row.dataset.imei;
        const vehicleID = row.querySelector('.tracker-vehicle-select').value;
        if (!vehicleID) { alert('Select a vehicle first.'); return; }
        try {
          btn.disabled = true;
          await adminPairTracker(imei, vehicleID);
          await loadSensors();
          await renderTrackersPanel(); renderAdminPanel();
        } catch (err) { alert(err.message); btn.disabled = false; }
      });
    });
    container.querySelectorAll('.tracker-unpair-btn').forEach(btn => {
      btn.addEventListener('click', async () => {
        const row = btn.closest('[data-imei]');
        const imei = row.dataset.imei;
        if (!confirm(`Unlink tracker ${imei} from its vehicle?`)) return;
        try {
          btn.disabled = true;
          await adminUnpairTracker(imei);
          await loadSensors();
          await renderTrackersPanel(); renderAdminPanel();
        } catch (err) { alert(err.message); btn.disabled = false; }
      });
    });
    container.querySelectorAll('.tracker-delete-btn').forEach(btn => {
      btn.addEventListener('click', async () => {
        const row = btn.closest('[data-imei]');
        const imei = row.dataset.imei;
        if (!confirm(`Delete tracker ${imei}?`)) return;
        try {
          btn.disabled = true;
          await adminDeleteTracker(imei);
          await loadSensors();
          await renderTrackersPanel(); renderAdminPanel();
        } catch (err) { alert(err.message); btn.disabled = false; }
      });
    });
  } catch (err) {
    container.innerHTML = `<p class="auth-error">${escHTML(err.message)}</p>`;
  }
}

function switchAdminTab(tab) {
  // Diagnostic views live in the main pane, not in the drawer
  if (tab === 'errors') { closeAdminPanel(); showMode('errors'); renderErrors(); return; }
  document.querySelectorAll('.admin-nav-btn').forEach(b => b.classList.toggle('active', b.dataset.tab === tab));
  document.querySelectorAll('.admin-tab-pane').forEach(p => p.classList.toggle('active', p.id === 'admin-tab-' + tab));
  if (tab === 'users')    renderUsersPanel();
  if (tab === 'assets')   renderAssetsPanel();
  if (tab === 'trackers') renderTrackersPanel();
  if (tab === 'profiles') renderProfilesPanel();
  if (tab === 'security') renderSecurityPanel();
  if (tab === 'stats')    renderStatsPanel();
  if (tab === 'ota')      renderOtaPanel();
}
function openAdminPanel(tab = 'users') {
  $('admin-backdrop').style.display = '';
  $('admin-drawer').classList.add('open');
  switchAdminTab(tab);
  renderAdminPanel();
}
function closeAdminPanel()    { $('admin-backdrop').style.display = 'none'; $('admin-drawer').classList.remove('open'); }
function openUsersPanel()    { openAdminPanel('users');    }
function closeUsersPanel()   {}
function openAssetsPanel()   { openAdminPanel('assets');   }
function closeAssetsPanel()  {}
function openTrackersPanel() { openAdminPanel('trackers'); }
function closeTrackersPanel(){}

// ─── CSV Export ───────────────────────────────────────────────────────────────
function exportCSV() {
  const sensor = S.sensors.find(s => s.sensorID === S.selected);
  if (!S.records.length) return;
  const name = (sensor?.sensorName ?? sensor?.sensorID ?? 'export').replace(/[^\w-]/g, '_');
  const header = ['timestamp', 'pressureBar', 'temperatureC', 'batteryPct', 'wheelPosition'];
  const rows = S.records.map(r => [
    r.timestamp, r.pressureBar ?? '', r.temperatureC ?? '', r.batteryPct ?? '', r.wheelPosition ?? '',
  ]);
  const csv = [header, ...rows].map(r => r.join(',')).join('\n');
  const a = Object.assign(document.createElement('a'), {
    download: `netmap-${name}.csv`,
    href: 'data:text/csv;charset=utf-8,' + encodeURIComponent(csv),
  });
  a.click();
}

// ─── Log viewer ───────────────────────────────────────────────────────────────
let _logsInterval  = null;
let _logsLastIndex = 0;
let _logsHiddenCats = new Set(); // categories toggled OFF
let _logWs         = null;

function _logCategory(text) {
  const t = text.toLowerCase();
  if (/\[airtag\]/.test(t)) return 'airtag';
  if (/\[tms\]/.test(t))    return 'tms';
  if (/\[tracker\]|\[behavior\]|\[lifecycle\]|\[ping\]/.test(t)) return 'tracker';
  // Vapor framework / server internals: request logs, routing, boot, DB...
  if (/vapor|post \/api|get \/api|request|response|routing|middleware|application|migrat|server started|listening|boot/.test(t)) return 'internal';
  return 'other';
}

function _applyLogFilters() {
  const out = $('logs-output');
  for (const el of out.querySelectorAll('.log-line')) {
    const cat = el.dataset.cat || 'other';
    el.style.display = _logsHiddenCats.has(cat) ? 'none' : '';
  }
}

function _toggleLogFilter(cat) {
  if (_logsHiddenCats.has(cat)) {
    _logsHiddenCats.delete(cat);
  } else {
    _logsHiddenCats.add(cat);
  }
  // sync button states
  document.querySelectorAll('.logs-filter-btn').forEach(btn => {
    btn.classList.toggle('active', !_logsHiddenCats.has(btn.dataset.cat));
  });
  _applyLogFilters();
}

function openLogsViewer() {
  $('logs-overlay').style.display = 'flex';
  _logsLastIndex = 0;
  $('logs-output').innerHTML = '';
  _startLogWs();
}
function closeLogsViewer() {
  $('logs-overlay').style.display = 'none';
  _stopLogWs();
  _stopLogPolling();
}
function _startLogWs() {
  _stopLogWs();
  _stopLogPolling();
  // Fetch existing buffered lines first (since=0), then switch to live push
  pollLogs().then(() => {
    const proto = location.protocol === 'https:' ? 'wss:' : 'ws:';
    const ws = new WebSocket(`${proto}//${location.host}/api/admin/ws/logs`);
    _logWs = ws;
    ws.addEventListener('message', e => {
      let msg; try { msg = JSON.parse(e.data); } catch { return; }
      if (!msg || typeof msg.index !== 'number') return;
      _appendLogLine(msg);
    });
    ws.addEventListener('close', e => {
      _logWs = null;
      // Viewer still open? Fall back to polling + retry WS
      if ($('logs-overlay').style.display !== 'none') {
        _startLogPolling();
        if (!e.wasClean) setTimeout(_startLogWs, 5000);
      }
    });
    ws.addEventListener('error', () => ws.close());
  });
}
function _stopLogWs() {
  if (_logWs) { _logWs.close(); _logWs = null; }
}
function _startLogPolling() {
  _stopLogPolling();
  pollLogs();
  _logsInterval = setInterval(pollLogs, 1500);
}
function _stopLogPolling() {
  if (_logsInterval) { clearInterval(_logsInterval); _logsInterval = null; }
}
function _appendLogLine({ index, text }) {
  _logsLastIndex = index;
  const out = $('logs-output');
  if (!out) return;
  const atBottom = out.scrollHeight - out.scrollTop - out.clientHeight < 60;
  const el = document.createElement('span');
  const cat = _logCategory(text);
  el.className = 'log-line ' + _logLevel(text);
  el.dataset.cat = cat;
  if (_logsHiddenCats.has(cat)) el.style.display = 'none';
  el.textContent = text;
  out.appendChild(el);
  out.appendChild(document.createTextNode('\n'));
  // Keep last 2000 lines rendered
  while (out.children.length > 4000) out.removeChild(out.firstChild);
  if ($('logs-autoscroll').checked && atBottom) out.scrollTop = out.scrollHeight;
  $('logs-status').textContent = `${_logsLastIndex} lines`;
}
async function pollLogs() {
  try {
    const lines = await apiFetch(`/api/admin/logs?since=${_logsLastIndex}`);
    if (!lines.length) return;
    lines.forEach(line => _appendLogLine(line));
  } catch(e) { console.warn('log poll:', e); }
}
function _logLevel(text) {
  if (/\bCRITICAL\b/.test(text)) return 'log-critical';
  if (/\bERROR\b/.test(text))    return 'log-error';
  if (/\bWARNING\b/.test(text))  return 'log-warning';
  if (/\bNOTICE\b/.test(text))   return 'log-notice';
  if (/\bDEBUG\b/.test(text))    return 'log-debug';
  return 'log-info';
}

// ─── Init ─────────────────────────────────────────────────────────────────────
async function main() {
  if (localStorage.getItem('netmap-theme') === 'dark') {
    document.documentElement.setAttribute('data-theme', 'dark');
  }

  // Show server + web version in sidebar footer (no auth required)
  fetch('/health').then(r => r.json()).then(h => {
    const el = $('server-version');
    if (el) el.textContent = h?.version ? `Server v${h.version} · Web v${WEB_VERSION}` : `Web v${WEB_VERSION}`;
  }).catch(() => {
    const el = $('server-version');
    if (el) el.textContent = `Web v${WEB_VERSION}`;
  });

  setup();  // register all event listeners first (auth form needs to be live)

  try {
    await checkAuth();
    await Promise.all([loadSensors(), loadServerVehicles(), loadAssetTypes()]);
    const groups = groupByVehicle();

    // Restore state from URL hash, or fall back to auto-select defaults
    const hashRestored = restoreFromHash();
    if (hashRestored) {
      syncPeriodUI();
      const sensor = S.sensors.find(s => s.sensorID === S.selected);
      if (sensor && !S.vehicleFilter) S.vehicleFilter = sensor.vehicleID;
      if (!sensor) {
        // Hash sensor no longer exists — fall back to first available
        const firstVehicle = Object.keys(groups)[0];
        S.vehicleFilter = firstVehicle ?? null;
        S.selected      = firstVehicle ? (groups[firstVehicle].sensors[0]?.sensorID ?? null) : null;
      }
    } else {
      // Default: auto-select first vehicle and sensor
      const firstVehicle = Object.keys(groups)[0];
      if (firstVehicle) {
        S.vehicleFilter = firstVehicle;
        S.selected      = groups[firstVehicle].sensors[0]?.sensorID ?? null;
      }
    }
    if (S.selected) await loadRecords();
    renderSidebar();
    renderAll();
    _wsConnect();
  } catch (e) {
    console.error('Init error:', e);
    D.sensorList.innerHTML = `<div class="sidebar-hint" style="color:var(--danger)">
      Error: ${escHTML(e.message)}<br>
      <small>Is NetMapServer running?<br>Start with: <code>swift run App</code></small>
    </div>`;
  }
}

main();

// ─── OTA Firmware Panel ────────────────────────────────────────────────────────

async function otaFetchVersions() {
  const res = await fetch('/api/admin/ota/versions', { headers: authHeaders() });
  if (!res.ok) return { versions: [], latest: null };
  return res.json().catch(() => ({ versions: [], latest: null }));
}
async function otaFetchTrackers() {
  const res = await fetch('/api/admin/ota/trackers', { headers: authHeaders() });
  if (!res.ok) throw new Error(`HTTP ${res.status}`);
  return res.json();
}
async function otaFetchUpgrades({ limit = 50, offset = 0, imei = '', status = '' } = {}) {
  const qs = new URLSearchParams({ limit, offset });
  if (imei)   qs.set('imei',   imei);
  if (status) qs.set('status', status);
  const res = await fetch(`/api/admin/ota/upgrades?${qs}`, { headers: authHeaders() });
  if (!res.ok) throw new Error(`HTTP ${res.status}`);
  return res.json();
}
async function otaFetchSettings() {
  const res = await fetch('/api/admin/ota/settings', { headers: authHeaders() });
  if (!res.ok) return { otaServerUrl: '' };
  return res.json().catch(() => ({ otaServerUrl: '' }));
}
async function otaSaveSettings(otaServerUrl) {
  const res = await fetch('/api/admin/ota/settings', {
    method: 'PUT',
    headers: { 'Content-Type': 'application/json', ...authHeaders() },
    body: JSON.stringify({ otaServerUrl }),
  });
  if (!res.ok) { const e = await res.json().catch(() => ({})); throw new Error(e.reason || `HTTP ${res.status}`); }
}
async function otaRequestUpgrade(imei, targetVersion) {
  const res = await fetch(`/api/admin/ota/trackers/${encodeURIComponent(imei)}/upgrade`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', ...authHeaders() },
    body: JSON.stringify({ targetVersion }),
  });
  if (!res.ok) { const e = await res.json().catch(() => ({})); throw new Error(e.reason || `HTTP ${res.status}`); }
}
async function otaCancelUpgrade(requestId) {
  const res = await fetch(`/api/admin/ota/upgrades/${encodeURIComponent(requestId)}`, {
    method: 'PATCH',
    headers: { 'Content-Type': 'application/json', ...authHeaders() },
    body: JSON.stringify({ status: 'cancelled' }),
  });
  if (!res.ok) { const e = await res.json().catch(() => ({})); throw new Error(e.reason || `HTTP ${res.status}`); }
}

function otaStatusBadge(status) {
  const map = {
    pending:   'background:rgba(251,191,36,.18);color:#f59e0b;',
    delivered: 'background:rgba(96,165,250,.18);color:#60a5fa;',
    completed: 'background:rgba(52,211,153,.18);color:#34d399;',
    failed:    'background:rgba(239,68,68,.18);color:#f87171;',
    cancelled: 'background:rgba(100,116,139,.15);color:#94a3b8;',
  };
  const style = map[status] ?? map.pending;
  return `<span class="role-badge" style="${style}">${escHTML(status)}</span>`;
}

async function renderOtaPanel() {
  const cont = $('admin-ota-content');
  if (!cont) return;
  cont.innerHTML = '<p class="admin-loading">Loading\u2026</p>';

  try {
    const [versionsData, trackers, settings] = await Promise.all([
      otaFetchVersions(),
      otaFetchTrackers(),
      otaFetchSettings(),
    ]);

    const versions = Array.isArray(versionsData.versions) ? versionsData.versions : [];
    const latestVersion = versionsData.latest ?? (versions.length ? versions[0].version : null);

    const versionOptions = versions.map(v =>
      `<option value="${escAttr(String(v.version))}">${escHTML(String(v.version))} — ${escHTML(v.filename)}${v.size ? ' (' + (v.size / 1024).toFixed(1) + ' KB)' : ''}</option>`
    ).join('');

    // ── Settings section ────────────────────────────────────────────────
    const settingsHtml = `
      <div class="stats-breakdown-box" style="margin-bottom:14px">
        <div class="stats-chart-title">OTA Server Settings</div>
        <div style="display:flex;gap:8px;align-items:center;margin-top:8px">
          <input type="text" id="ota-server-url-input" value="${escAttr(settings.otaServerUrl)}"
            placeholder="https://track.netmap.fr:9443" style="flex:1;padding:6px 10px;background:var(--bg2);border:1px solid var(--border);border-radius:6px;color:var(--fg);font-size:12px">
          <button id="ota-save-settings-btn" class="modal-btn-primary admin-small-btn">Save</button>
        </div>
        <div id="ota-settings-error" class="auth-error" style="display:none;margin-top:6px"></div>
      </div>`;

    // ── Available firmware versions ─────────────────────────────────────
    const versionsHtml = `
      <div class="stats-breakdown-box" style="margin-bottom:14px">
        <div class="stats-chart-title">Available Firmware Versions</div>
        ${versions.length ? `
        <table class="bat-table" style="margin-top:8px">
          <thead><tr><th style="text-align:left">Version</th><th style="text-align:left">File</th><th style="text-align:right">Size</th><th style="text-align:left">Uploaded</th></tr></thead>
          <tbody>${versions.map(v => `
            <tr${v.version === latestVersion ? ' style="color:var(--accent-hi)"' : ''}>
              <td style="font-family:monospace">${escHTML(String(v.version))}${v.version === latestVersion ? ' <span style="font-size:10px;opacity:.7">latest</span>' : ''}</td>
              <td>${escHTML(v.filename)}</td>
              <td style="text-align:right">${v.size ? (v.size / 1024).toFixed(1) + ' KB' : '–'}</td>
              <td style="color:var(--fg3)">${v.uploadedAt ? fmtTs(v.uploadedAt) : '–'}</td>
            </tr>`).join('')}
          </tbody>
        </table>` : '<div style="color:var(--fg3);font-size:12px;margin-top:6px">OTA server unreachable or no firmware files found.</div>'}
      </div>`;

    // ── Trackers table ─────────────────────────────────────────────────
    const trackersHtml = `
      <div class="stats-breakdown-box" style="margin-bottom:14px">
        <div class="stats-chart-title">Trackers</div>
        ${trackers.length ? `
        <table class="bat-table" style="margin-top:8px">
          <thead><tr><th>IMEI</th><th>Vehicle</th><th>Current FW</th><th>Pending Upgrade</th><th></th></tr></thead>
          <tbody id="ota-trackers-tbody">
            ${trackers.map(t => {
              const hasPending = !!t.pendingUpgradeVersion;
              return `<tr data-imei="${escAttr(t.imei)}">
                <td style="font-family:monospace;font-size:11px">${escHTML(t.imei)}</td>
                <td>${escHTML(t.sensorName || t.vehicleName)}</td>
                <td style="font-family:monospace">${t.firmwareVersion ? escHTML(t.firmwareVersion) : '<span style="color:var(--fg3)">unknown</span>'}</td>
                <td>${hasPending ? `<span style="color:#f59e0b;font-family:monospace">${escHTML(t.pendingUpgradeVersion)}</span>` : '<span style="color:var(--fg3)">—</span>'}</td>
                <td>
                  <div style="display:flex;gap:6px;align-items:center">
                    <select class="ota-version-sel" style="font-size:11px;padding:3px 6px;background:var(--bg2);border:1px solid var(--border);border-radius:5px;color:var(--fg)">
                      <option value="">Select version…</option>
                      ${versionOptions}
                    </select>
                    <button class="modal-btn-primary admin-small-btn ota-push-btn" style="white-space:nowrap"${hasPending ? ' disabled title="Upgrade already pending"' : ''}>Push OTA</button>
                  </div>
                </td>
              </tr>`;
            }).join('')}
          </tbody>
        </table>` : '<div style="color:var(--fg3);font-size:12px;margin-top:6px">No trackers found.</div>'}
      </div>`;

    // ── Upgrade history ─────────────────────────────────────────────────
    const histHtml = `
      <div class="stats-breakdown-box">
        <div class="stats-chart-title" style="display:flex;align-items:center;justify-content:space-between">
          <span>Upgrade Request History</span>
          <div style="display:flex;gap:6px">
            <input type="text" id="ota-hist-imei" placeholder="IMEI filter…" value="${escAttr(S.otaUpgrades.imeiFilter)}"
              style="font-size:11px;padding:3px 8px;background:var(--bg2);border:1px solid var(--border);border-radius:5px;color:var(--fg);width:160px">
            <select id="ota-hist-status" style="font-size:11px;padding:3px 8px;background:var(--bg2);border:1px solid var(--border);border-radius:5px;color:var(--fg)">
              <option value="">All statuses</option>
              <option value="pending"${S.otaUpgrades.statusFilter==='pending'?' selected':''}>Pending</option>
              <option value="delivered"${S.otaUpgrades.statusFilter==='delivered'?' selected':''}>Delivered</option>
              <option value="completed"${S.otaUpgrades.statusFilter==='completed'?' selected':''}>Completed</option>
              <option value="failed"${S.otaUpgrades.statusFilter==='failed'?' selected':''}>Failed</option>
              <option value="cancelled"${S.otaUpgrades.statusFilter==='cancelled'?' selected':''}>Cancelled</option>
            </select>
            <button id="ota-hist-filter-btn" class="modal-btn admin-small-btn">Filter</button>
          </div>
        </div>
        <div id="ota-hist-list" style="margin-top:8px"><p class="admin-loading">Loading…</p></div>
        <div class="admin-security-pager" style="margin-top:8px">
          <button id="ota-hist-prev" class="modal-btn admin-small-btn">Prev</button>
          <span id="ota-hist-page-label">Page 1</span>
          <button id="ota-hist-next" class="modal-btn admin-small-btn">Next</button>
        </div>
      </div>`;

    cont.innerHTML = settingsHtml + versionsHtml + trackersHtml + histHtml;

    // Wire settings save
    $('ota-save-settings-btn').addEventListener('click', async () => {
      const urlVal = $('ota-server-url-input').value.trim();
      const errEl  = $('ota-settings-error');
      errEl.style.display = 'none';
      try {
        await otaSaveSettings(urlVal);
        showToast('OTA server URL saved.');
      } catch (err) {
        errEl.textContent = err.message; errEl.style.display = 'block';
      }
    });

    // Wire push OTA buttons on each tracker row
    cont.querySelectorAll('#ota-trackers-tbody tr[data-imei]').forEach(row => {
      const imei = row.dataset.imei;
      const sel  = row.querySelector('.ota-version-sel');
      const btn  = row.querySelector('.ota-push-btn');
      if (!btn) return;
      btn.addEventListener('click', async () => {
        const targetVersion = sel?.value;
        if (!targetVersion) { showToast('Select a firmware version first.', 'warn'); return; }
        if (!confirm(`Push OTA firmware ${targetVersion} to tracker ${imei}?\nThe upgrade will be delivered on the tracker's next check-in.`)) return;
        btn.disabled = true;
        try {
          await otaRequestUpgrade(imei, targetVersion);
          showToast(`Upgrade to ${targetVersion} scheduled for ${imei}.`);
          renderOtaPanel();
        } catch (err) {
          showToast(err.message, 'error');
          btn.disabled = false;
        }
      });
    });

    // Wire upgrade history
    await _renderOtaHistory();
    const filterBtn = $('ota-hist-filter-btn');
    const prevBtn   = $('ota-hist-prev');
    const nextBtn   = $('ota-hist-next');
    if (filterBtn && !filterBtn._wired) {
      filterBtn._wired = true;
      filterBtn.addEventListener('click', () => {
        S.otaUpgrades.imeiFilter   = $('ota-hist-imei')?.value.trim() ?? '';
        S.otaUpgrades.statusFilter = $('ota-hist-status')?.value ?? '';
        S.otaUpgrades.offset = 0;
        _renderOtaHistory();
      });
      prevBtn?.addEventListener('click', () => {
        S.otaUpgrades.offset = Math.max(0, S.otaUpgrades.offset - S.otaUpgrades.limit);
        _renderOtaHistory();
      });
      nextBtn?.addEventListener('click', () => {
        const next = S.otaUpgrades.offset + S.otaUpgrades.limit;
        if (next >= S.otaUpgrades.total) return;
        S.otaUpgrades.offset = next;
        _renderOtaHistory();
      });
    }
  } catch (err) {
    cont.innerHTML = `<p class="auth-error">${escHTML(err.message)}</p>`;
  }
}

async function _renderOtaHistory() {
  const list     = $('ota-hist-list');
  const pageLbl  = $('ota-hist-page-label');
  const prevBtn  = $('ota-hist-prev');
  const nextBtn  = $('ota-hist-next');
  if (!list) return;
  list.innerHTML = '<p class="admin-loading">Loading\u2026</p>';
  try {
    const data  = await otaFetchUpgrades({
      limit:  S.otaUpgrades.limit,
      offset: S.otaUpgrades.offset,
      imei:   S.otaUpgrades.imeiFilter,
      status: S.otaUpgrades.statusFilter,
    });
    const items = Array.isArray(data.items) ? data.items : [];
    S.otaUpgrades.total = data.total ?? items.length;
    const page  = Math.floor(S.otaUpgrades.offset / S.otaUpgrades.limit) + 1;
    const pages = Math.max(1, Math.ceil(S.otaUpgrades.total / S.otaUpgrades.limit));
    if (pageLbl) pageLbl.textContent = `Page ${page} / ${pages} · ${S.otaUpgrades.total} request${S.otaUpgrades.total !== 1 ? 's' : ''}`;
    if (prevBtn) prevBtn.disabled = S.otaUpgrades.offset <= 0;
    if (nextBtn) nextBtn.disabled = (S.otaUpgrades.offset + S.otaUpgrades.limit) >= S.otaUpgrades.total;
    if (!items.length) {
      list.innerHTML = '<p class="sidebar-hint">No upgrade requests for this filter.</p>';
      return;
    }
    const df = new Intl.DateTimeFormat([], { dateStyle: 'short', timeStyle: 'short' });
    const fmtD = d => d ? df.format(new Date(d)) : '–';
    list.innerHTML = `
      <table class="bat-table">
        <thead><tr>
          <th>IMEI</th><th>Target</th><th>Requested by</th>
          <th>Requested at</th><th>Status</th><th>Completed at</th><th></th>
        </tr></thead>
        <tbody>
          ${items.map(r => `
            <tr>
              <td style="font-family:monospace;font-size:11px">${escHTML(r.imei)}</td>
              <td style="font-family:monospace">${escHTML(r.targetVersion)}</td>
              <td>${escHTML(r.requestedBy)}</td>
              <td style="color:var(--fg3)">${fmtD(r.createdAt)}</td>
              <td>${otaStatusBadge(r.status)}</td>
              <td style="color:var(--fg3)">${fmtD(r.completedAt)}</td>
              <td>
                ${(r.status === 'pending' || r.status === 'delivered')
                  ? `<button class="modal-btn admin-small-btn ota-cancel-btn" data-id="${escAttr(r.id)}" style="color:#f87171;border-color:rgba(248,113,113,.3)">Cancel</button>`
                  : ''}
              </td>
            </tr>`).join('')}
        </tbody>
      </table>`;
    list.querySelectorAll('.ota-cancel-btn').forEach(btn => {
      btn.addEventListener('click', async () => {
        if (!confirm('Cancel this upgrade request?')) return;
        btn.disabled = true;
        try {
          await otaCancelUpgrade(btn.dataset.id);
          showToast('Upgrade request cancelled.');
          _renderOtaHistory();
        } catch (err) {
          showToast(err.message, 'error');
          btn.disabled = false;
        }
      });
    });
  } catch (err) {
    if (list) list.innerHTML = `<p class="auth-error">${escHTML(err.message)}</p>`;
    if (pageLbl) pageLbl.textContent = 'Page –';
    if (prevBtn) prevBtn.disabled = true;
    if (nextBtn) nextBtn.disabled = true;
  }
}

// ─── Admin Stats Panel ─────────────────────────────────────────────────────────
async function renderStatsPanel() {
  const cont = $('admin-stats-cont');
  if (!cont) return;
  cont.innerHTML = `<div style="color:var(--fg3);font-size:13px;padding:16px 8px">Loading statistics…</div>`;

  let s;
  try {
    s = await apiFetch('/api/admin/stats');
  } catch (err) {
    cont.innerHTML = `<div style="color:var(--danger);font-size:13px;padding:16px 8px">${escHTML(err.message)}</div>`;
    return;
  }

  const df = new Intl.DateTimeFormat([], { dateStyle: 'medium', timeStyle: 'short' });
  const fmtD = iso => iso ? df.format(new Date(iso)) : '–';
  const fmtN = n => n?.toLocaleString() ?? '–';
  function fmtBytes(b) {
    if (b == null) return '–';
    if (b < 1024) return b + ' B';
    if (b < 1024 * 1024) return (b / 1024).toFixed(1) + ' KB';
    if (b < 1024 * 1024 * 1024) return (b / (1024 * 1024)).toFixed(2) + ' MB';
    return (b / (1024 * 1024 * 1024)).toFixed(2) + ' GB';
  }

  // ── KPI cards ──
  function kpiCard(label, value, sub = '') {
    return `<div class="stats-kpi-card">
      <div class="stats-kpi-value">${value}</div>
      <div class="stats-kpi-label">${label}</div>
      ${sub ? `<div class="stats-kpi-sub">${sub}</div>` : ''}
    </div>`;
  }

  // ── Sparkline bar chart (Chart.js) ──
  function barChart(title, data, canvasId) {
    if (!data.length) return `<div class="stats-chart-box"><div class="stats-chart-title">${title}</div><div style="color:var(--fg3);font-size:12px;padding:8px 0">No data</div></div>`;
    return `<div class="stats-chart-box">
      <div class="stats-chart-title">${title} <span class="stats-chart-range">(last 30 days)</span></div>
      <div style="position:relative;height:80px"><canvas id="${canvasId}"></canvas></div>
    </div>`;
  }

  // ── Horizontal breakdown bars ──
  function breakdownChart(title, items) {
    if (!items.length) return '';
    const max = Math.max(...items.map(i => i.count), 1);
    const rows = items.map(i => {
      const pct = Math.max(2, Math.round((i.count / max) * 100));
      return `<div class="stats-hbar-row">
        <div class="stats-hbar-label">${escHTML(i.type)}</div>
        <div class="stats-hbar-track"><div class="stats-hbar-fill" style="width:${pct}%"></div></div>
        <div class="stats-hbar-count">${fmtN(i.count)}</div>
      </div>`;
    }).join('');
    return `<div class="stats-breakdown-box"><div class="stats-chart-title">${title}</div>${rows}</div>`;
  }

  // ── Top trackers table ──
  function topTrackersTable(trackers) {
    if (!trackers.length) return '';
    const rows = trackers.map(t =>
      `<tr>
        <td style="font-family:monospace;font-size:11px">${escHTML(t.imei)}</td>
        <td>${escHTML(t.name ?? '–')}</td>
        <td style="text-align:right">${fmtN(t.events7d)}</td>
        <td style="color:var(--fg3)">${t.lastSeenAt ? df.format(new Date(t.lastSeenAt)) : '–'}</td>
      </tr>`
    ).join('');
    return `<div class="stats-breakdown-box" style="margin-bottom:12px">
      <div class="stats-chart-title">Most active trackers <span class="stats-chart-range">(last 7 days)</span></div>
      <table class="bat-table" style="margin-top:8px">
        <thead><tr><th>IMEI</th><th>Name</th><th style="text-align:right">Events</th><th>Last seen</th></tr></thead>
        <tbody>${rows}</tbody>
      </table>
    </div>`;
  }

  cont.innerHTML = `
    <div class="stats-kpi-row">
      ${kpiCard('Sensor readings', fmtN(s.totalReadings), `${fmtN(s.readingsLast30d)} last 30 d`)}
      ${kpiCard('Tracker events', fmtN(s.totalVehicleEvents), `${fmtN(s.vehicleEventsLast30d)} last 30 d`)}
      ${kpiCard('Lifecycle events', fmtN(s.totalLifecycleEvents), `${fmtN(s.lifecycleEventsLast30d)} last 30 d`)}
      ${kpiCard('Driver behavior', fmtN(s.totalDriverBehaviorEvents), `${fmtN(s.driverBehaviorEventsLast30d ?? 0)} last 30 d`)}
      ${kpiCard('Assets', fmtN(s.totalVehicles), '')}
      ${kpiCard('Users', fmtN(s.totalUsers), '')}
    </div>
    <div class="stats-charts-row">
      ${barChart('Sensor readings / day', s.readingsPerDay, 'stats-canvas-readings')}
      ${barChart('Tracker events / day', s.vehicleEventsPerDay, 'stats-canvas-events')}
      ${barChart('Lifecycle events / day', s.lifecyclePerDay, 'stats-canvas-lifecycle')}
      ${(s.driverBehaviorPerDay?.length ?? 0) > 0 ? barChart('Driver behavior / day', s.driverBehaviorPerDay, 'stats-canvas-behavior') : ''}
    </div>
    <div class="stats-charts-row">
      ${breakdownChart('Tracker event types (all time)', s.vehicleEventsByType)}
      ${breakdownChart('Lifecycle event types (all time)', s.lifecycleByType)}
    </div>
    ${topTrackersTable(s.topTrackers)}
    <div class="stats-breakdown-box" style="margin-bottom:12px">
      <div class="stats-chart-title">Database</div>
      <div class="stats-info-row"><span>Oldest reading</span><span>${fmtD(s.oldestReading)}</span></div>
      <div class="stats-info-row"><span>Newest reading</span><span>${fmtD(s.newestReading)}</span></div>
      <div class="stats-info-row"><span>Total sensor readings</span><span>${fmtN(s.totalReadings)}</span></div>
      <div class="stats-info-row"><span>Total tracker events</span><span>${fmtN(s.totalVehicleEvents)}</span></div>
      <div class="stats-info-row"><span>Total lifecycle events</span><span>${fmtN(s.totalLifecycleEvents)}</span></div>
      <div class="stats-info-row"><span>Total driver behavior</span><span>${fmtN(s.totalDriverBehaviorEvents)}</span></div>
      <div class="stats-info-row"><span>Size on disk</span><span>${s.dbSizeBytes != null ? fmtBytes(s.dbSizeBytes) : '–'}</span></div>
    </div>`;

  // ── Initialize Chart.js sparklines for per-day bars ──────────────────
  const STATS_CHART_COLORS = {
    'stats-canvas-readings':  'rgba(96,165,250,0.75)',
    'stats-canvas-events':    'rgba(52,211,153,0.75)',
    'stats-canvas-lifecycle': 'rgba(167,139,250,0.75)',
    'stats-canvas-behavior':  'rgba(251,146,60,0.75)',
  };
  [
    { id: 'stats-canvas-readings',  data: s.readingsPerDay },
    { id: 'stats-canvas-events',    data: s.vehicleEventsPerDay },
    { id: 'stats-canvas-lifecycle', data: s.lifecyclePerDay },
    { id: 'stats-canvas-behavior',  data: s.driverBehaviorPerDay },
  ].forEach(({ id, data }) => {
    if (!data?.length) return;
    const cvs = document.getElementById(id);
    if (!cvs) return;
    new Chart(cvs, {
      type: 'bar',
      data: {
        labels: data.map(d => d.date),
        datasets: [{
          data: data.map(d => d.count),
          backgroundColor: STATS_CHART_COLORS[id] ?? 'rgba(96,165,250,0.75)',
          borderRadius: 3,
          borderSkipped: false,
        }]
      },
      options: {
        responsive: true,
        maintainAspectRatio: false,
        plugins: {
          legend: { display: false },
          tooltip: { callbacks: {
            title: items => items[0].label,
            label: item => item.raw.toLocaleString(),
          }}
        },
        scales: {
          x: { display: false },
          y: { display: false, beginAtZero: true }
        }
      }
    });
  });
}
