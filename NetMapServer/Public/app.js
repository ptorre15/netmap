'use strict';

// ─── Auth state ────────────────────────────────────────────────────────────────────────────────
const AUTH = { token: null, username: null, role: null,
  get isAdmin() { return this.role === 'admin'; } };

function saveAuth(data) {
  AUTH.token = data.token; AUTH.username = data.username; AUTH.role = data.role;
  localStorage.setItem('netmap-auth', JSON.stringify(data));
}
function clearAuth() {
  AUTH.token = null; AUTH.username = null; AUTH.role = null;
  localStorage.removeItem('netmap-auth');
}
function applyAuthUI() {
  const badge  = $('user-badge');
  const addBtn = $('add-vehicle-btn');
  const editBt = $('edit-vehicle-btn');
  const adminBtn = $('admin-btn');
  if (AUTH.token) {
    $('user-name').textContent = AUTH.username;
    const roleEl = $('user-role');
    roleEl.textContent = AUTH.role;
    roleEl.className   = `role-badge ${AUTH.role}`;
    badge.style.display = 'flex';
    if (addBtn)   addBtn.style.display   = AUTH.isAdmin ? '' : 'none';
    if (adminBtn) adminBtn.style.display = AUTH.isAdmin ? '' : 'none';
  } else {
    badge.style.display = 'none';
    if (addBtn)   addBtn.style.display   = 'none';
    if (editBt)   editBt.style.display   = 'none';
    if (adminBtn) adminBtn.style.display = 'none';
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
  const stored = localStorage.getItem('netmap-auth');
  if (stored) {
    try {
      const p = JSON.parse(stored);
      AUTH.token = p.token;
      const me = await fetch('/api/auth/me', { headers: { 'Authorization': `Bearer ${p.token}` } });
      if (me.ok) { const d = await me.json(); saveAuth({ token: p.token, username: d.email, role: d.role }); applyAuthUI(); return; }
    } catch {}
    clearAuth();
  }
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
      `<option value="${t.id}"${t.id === currentTypeID ? ' selected' : ''}>${t.name}</option>`
    ).join('');
    // Fallback: if no exact match, select by name
    if (!S.assetTypes.find(t => t.id === currentTypeID)) {
      const byName = S.assetTypes.find(t => t.name.toLowerCase() === currentTypeID.toLowerCase());
      if (byName) sel.value = byName.id;
    }
  }
  // Hide type row when editing (type cannot change)
  $('vf-type-row').style.display = vehicle ? 'none' : '';
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

  $('modal-delete-btn').style.display = vehicle ? '' : 'none';
  $('modal-error').style.display = 'none';
  $('vehicle-modal').style.display = 'flex';
}
function closeVehicleModal() {
  $('vehicle-modal').style.display = 'none';
  _editingVehicleID = null;
}

async function saveVehicle(payload) {
  const headers = { 'Content-Type': 'application/json', 'Authorization': `Bearer ${AUTH.token}` };
  const url     = _editingVehicleID ? `/api/vehicles/${_editingVehicleID}` : '/api/vehicles';
  const method  = _editingVehicleID ? 'PATCH' : 'POST';
  const res     = await fetch(url, { method, headers, body: JSON.stringify(payload) });
  if (!res.ok) { const e = await res.json().catch(() => ({})); throw new Error(e.reason || `HTTP ${res.status}`); }
  return res.status === 200 || res.status === 201 ? res.json() : null;
}
async function deleteVehicle(id) {
  const res = await fetch(`/api/vehicles/${id}`, { method: 'DELETE', headers: { 'Authorization': `Bearer ${AUTH.token}` } });
  if (!res.ok) { const e = await res.json().catch(() => ({})); throw new Error(e.reason || `HTTP ${res.status}`); }
}

async function loadServerVehicles() {
  try { S.serverVehicles = await apiFetch('/api/vehicles'); } catch { S.serverVehicles = []; }
}
async function loadAssetTypes() {
  try { S.assetTypes = await apiFetch('/api/asset-types'); } catch { S.assetTypes = []; }
}

// ─── Constants ────────────────────────────────────────────────────────────────
const REFRESH_MS = 30_000;
const HOURS = { '1H': 1, '24H': 24, '7D': 168, '30D': 720 };
const WHEEL_LABELS  = { FL: 'Front Left', FR: 'Front Right', RL: 'Rear Left', RR: 'Rear Right' };
const BRAND_LABELS  = { michelin: 'Michelin', stihl: 'STIHL', ela: 'ELA', airtag: 'AirTag' };
const PRODUCT_VARIANT_LABELS = { coin: 'ELA Blue Coin', puck: 'ELA Blue Puck', unknown: 'ELA Beacon' };
const SC = { ok: '#34d399', warn: '#fbbf24', danger: '#f87171', unknown: '#55556a' };
const SC_BG = { ok: 'rgba(52,211,153,0.15)', warn: 'rgba(251,191,36,0.15)', danger: 'rgba(248,113,113,0.15)', unknown: 'rgba(85,85,106,0.15)' };

function isTpms(s)   { return s.brand === 'michelin' || s.wheelPosition != null; }
function isBattery(s){ return s.brand === 'stihl' || s.brand === 'ela'; }

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
  loading: false, autoRefresh: false, timer: null,
  pChart: null, tChart: null, leafletMap: null,
};

// ─── DOM helpers ──────────────────────────────────────────────────────────────
const $ = id => document.getElementById(id);
const D = {
  vehicleSelect: $('vehicle-select'),
  sensorsHeader: $('sensors-header'),
  sensorList:   $('sensor-list'),
  lastUpdated:  $('last-updated'),
  livePill:     $('live-pill'),
  liveLabel:    $('live-label'),
  breadcrumb:   $('breadcrumb'),
  statCount:    $('stat-count'),
  statMin:      $('stat-min'),
  statAvg:      $('stat-avg'),
  statMax:      $('stat-max'),
  statLast:     $('stat-last'),
  statMinLbl:   $('stat-min')?.closest('.stat-cell')?.querySelector('.stat-label'),
  statAvgLbl:   $('stat-avg')?.closest('.stat-cell')?.querySelector('.stat-label'),
  statMaxLbl:   $('stat-max')?.closest('.stat-cell')?.querySelector('.stat-label'),
  chartCont:    $('chart-container'),
  mapCont:      $('map-container'),
  tableCont:    $('table-container'),
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

function isStale(iso, mins = 5) {
  return !iso || (Date.now() - new Date(iso)) > mins * 60_000;
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
      const label = g.sensors.length ? g.name : `${g.name} \u2014 no sensors`;
      return `<option value="${vid}"${S.vehicleFilter === vid ? ' selected' : ''}>${label}</option>`;
    }).join('');
  // Admin edit button: show when selected vehicle has a server entry
  const editBtn = $('edit-vehicle-btn');
  if (editBtn) {
    const g = S.vehicleFilter ? groups[S.vehicleFilter] : null;
    const sv = g?.serverVehicle;
    editBtn.style.display = (AUTH.isAdmin && sv) ? '' : 'none';
    editBtn.onclick = sv ? () => openVehicleModal(sv) : null;
  }
}

function renderSensors() {
  const groups  = groupByVehicle();
  const entry   = S.vehicleFilter ? groups[S.vehicleFilter] : null;
  const sensors = entry ? entry.sensors : [];
  const vName   = entry ? entry.name : null;
  D.sensorsHeader.textContent = vName ? vName + ' — Sensors' : 'Sensors';
  if (!sensors.length) {
    D.sensorList.innerHTML = `<div class="sidebar-hint">${S.vehicleFilter ? 'No sensors' : 'Select a vehicle'}</div>`;
    return;
  }
  D.sensorList.innerHTML = sensors.map(s => {
    const isPressure = isTpms(s);
    const status = pStatus(s.latestPressureBar, s.targetPressureBar);
    const color  = SC[status];
    const stale  = isStale(s.latestTimestamp);
    const label  = s.wheelPosition
      ? (WHEEL_LABELS[s.wheelPosition] ?? s.wheelPosition)
      : (s.sensorName ?? BRAND_LABELS[s.brand] ?? s.brand);
    const sel    = s.sensorID === S.selected;
    const dotCol = stale ? SC.unknown : (isPressure ? color : SC.ok);

    // Value display
    let valueHtml, barPct;
    if (isPressure) {
      valueHtml = `<div class="s-pres" style="color:${dotCol}">${s.latestPressureBar != null ? s.latestPressureBar.toFixed(2) : '\u2013'}</div>`;
      barPct = s.latestPressureBar != null ? Math.min(100, (s.latestPressureBar / 5) * 100) : 0;
    } else if (s.latestBatteryPct != null || s.latestChargeState) {
      const pct = s.latestBatteryPct ?? 0;
      const bCol = pct > 50 ? '#34d399' : pct > 20 ? '#fbbf24' : '#f87171';
      const state = s.latestChargeState ? ` \u00b7 ${s.latestChargeState}` : '';
      valueHtml = `<div class="s-pres" style="color:${bCol}">${pct}%${state}</div>`;
      barPct = pct;
    } else if (s.latestTemperatureC != null) {
      valueHtml = `<div class="s-pres" style="color:${dotCol}">${s.latestTemperatureC.toFixed(1)}\u00b0C</div>`;
      barPct = Math.min(100, Math.max(0, ((s.latestTemperatureC + 20) / 80) * 100));
    } else {
      valueHtml = `<div class="s-pres" style="color:${dotCol}">\u2013</div>`;
      barPct = 0;
    }

    const brandLabel = BRAND_LABELS[s.brand] ?? s.brand;
    const subExtra = s.wheelPosition && s.sensorName ? ` \u00b7 ${s.sensorName}` : '';

    return `<div class="sensor-row${sel ? ' selected' : ''}" data-sid="${s.sensorID}">
      <div class="s-dot" style="background:${dotCol};color:${dotCol}"></div>
      <div class="s-info">
        <div class="s-name">${label}</div>
        <div class="s-sub">${brandLabel}${subExtra} \u00b7 ${s.readingCount.toLocaleString()} readings${stale ? ' \u00b7 offline' : ''}</div>
      </div>
      <div class="s-right">
        ${valueHtml}
        <div class="s-bar"><div class="s-bar-fill" style="width:${barPct}%;background:${dotCol}"></div></div>
      </div>
    </div>`;
  }).join('');
}

function renderSidebar() {
  renderVehicles();
  renderSensors();
  D.lastUpdated.textContent = new Date().toLocaleTimeString();
  const hasLive = S.sensors.some(s => !isStale(s.latestTimestamp, 2));
  D.livePill.className  = 'status-pill' + (hasLive ? ' live' : '');
  D.liveLabel.textContent = S.sensors.length
    ? `${S.sensors.length} sensor${S.sensors.length > 1 ? 's' : ''}`
    : 'No sensors';
}

// ─── Breadcrumb ───────────────────────────────────────────────────────────────
function renderBreadcrumb() {
  const s = S.sensors.find(x => x.sensorID === S.selected);
  if (!s) { D.breadcrumb.innerHTML = '&ndash;'; return; }
  const sensorLabel = s.sensorName
    ?? (s.wheelPosition ? (WHEEL_LABELS[s.wheelPosition] ?? s.wheelPosition) : (BRAND_LABELS[s.brand] ?? s.brand));
  const status = pStatus(s.latestPressureBar, s.targetPressureBar);
  const badgeStyle = `background:${SC_BG[status]};color:${SC[status]}`;
  D.breadcrumb.innerHTML =
    `<span class="bc-vehicle">${s.vehicleName}</span>` +
    `<span class="bc-sep">›</span>` +
    `<span class="bc-sensor">${sensorLabel}</span>` +
    (s.targetPressureBar ? `<span class="bc-badge" style="${badgeStyle}">target ${s.targetPressureBar.toFixed(2)} bar</span>` : '') +
    (s.latestBatteryPct != null ? `<span class="bc-badge" style="background:rgba(52,211,153,.15);color:#34d399">🔋 ${s.latestBatteryPct}%${ s.latestChargeState ? ' · ' + s.latestChargeState : ''}</span>` : '');
}

// ─── Sensor info card ─────────────────────────────────────────────────────────
function renderSensorInfoCard() {
  const el = $('sensor-info-card');
  if (!el) return;
  const s = S.sensors.find(x => x.sensorID === S.selected);
  if (!s) { el.innerHTML = ''; el.style.display = 'none'; return; }
  el.style.display = '';
  const brandLabel = BRAND_LABELS[s.brand] ?? s.brand;
  const stale = isStale(s.latestTimestamp);
  const mainLabel = s.wheelPosition
    ? (WHEEL_LABELS[s.wheelPosition] ?? s.wheelPosition)
    : (s.sensorName ?? brandLabel);
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
    rows.push(siRow('Last seen', fmtDT(s.latestTimestamp), stale ? '#f87171' : '#34d399'));
    if (s.latestLatitude != null && s.latestLongitude != null)
      rows.push(siRow('Location', `${s.latestLatitude.toFixed(5)}, ${s.latestLongitude.toFixed(5)}`));
    rows.push(siRow('ID', s.sensorID));
  }
  rows.push(siRow('Readings', s.readingCount.toLocaleString()));
  const liveBadge = stale ? '' : `<span class="si-live">\u25cf Live</span>`;
  el.innerHTML = `<div class="si-header">
    <span class="si-brand" data-brand="${s.brand}">${brandLabel}</span>
    <span class="si-name">${mainLabel}</span>
    ${liveBadge}
  </div>
  <div class="si-rows">${rows.join('')}</div>`;
}

function siRow(label, value, color = '') {
  const style = color ? ` style="color:${color}"` : '';
  return `<div class="si-row"><span class="si-label">${label}</span><span class="si-val"${style}>${value}</span></div>`;
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
  showStatCells(true);
  const sensor = S.sensors.find(s => s.sensorID === S.selected);

  if (isTpms(sensor)) {
    setStatLabels('Min', 'Avg', 'Max');
    const ps     = S.records.map(r => r.pressureBar).filter(v => v != null);
    const target = sensor?.targetPressureBar ?? null;
    if (!ps.length) {
      ['stat-min','stat-avg','stat-max'].forEach(id => $(id).textContent = '–');
      D.statCount.textContent = S.records.length ? S.records.length.toLocaleString() : '–';
      D.statLast.textContent  = S.records.length ? fmtDT(S.records.at(-1).timestamp) : '–';
      return;
    }
    const min = Math.min(...ps), max = Math.max(...ps);
    const avg = ps.reduce((a, b) => a + b, 0) / ps.length;
    D.statCount.textContent = S.records.length.toLocaleString();
    D.statMin.textContent   = min.toFixed(2) + ' bar';
    D.statAvg.textContent   = avg.toFixed(2) + ' bar';
    D.statMax.textContent   = max.toFixed(2) + ' bar';
    D.statLast.textContent  = S.records.length ? fmtDT(S.records.at(-1).timestamp) : '–';
    D.statAvg.closest('.stat-cell')?.classList.add(pStatus(avg, target));
    D.statMin.closest('.stat-cell')?.classList.add(pStatus(min, target));
    D.statMax.closest('.stat-cell')?.classList.add(pStatus(max, target));

  } else if (sensor?.brand === 'stihl') {
    showStatCells(false);
    D.statCount.textContent = S.records.length.toLocaleString();
    D.statLast.textContent = S.records.length ? fmtDT(S.records.at(-1).timestamp) : '–';

  } else if (sensor?.brand === 'ela') {
    showStatCells(false);
    D.statCount.textContent = S.records.length.toLocaleString();
    D.statLast.textContent = S.records.length ? fmtDT(S.records.at(-1).timestamp) : '–';

  } else {
    // AirTag ou autre : pas de min/avg/max
    showStatCells(false);
    D.statCount.textContent = S.records.length.toLocaleString();
    D.statLast.textContent = S.records.length ? fmtDT(S.records.at(-1).timestamp) : '–';
  }
}

// ─── Show/hide content areas ──────────────────────────────────────────────────
function showMode(mode) {
  const noData = S.records.length === 0;
  D.chartCont.style.display = mode === 'chart' && !noData ? 'flex' : 'none';
  D.mapCont.style.display   = mode === 'map'   && !noData ? 'flex' : 'none';
  D.tableCont.style.display = mode === 'table' && !noData ? 'block': 'none';
  D.emptyState.style.display = noData ? 'flex' : 'none';
}

// ─── Chart ────────────────────────────────────────────────────────────────────
function renderChart() {
  const sensor = S.sensors.find(s => s.sensorID === S.selected);
  resetChartCards();
  if (isTpms(sensor)) { renderChartTpms(sensor); }
  else if (sensor?.brand === 'airtag') { renderChartAirtag(); }
  else { renderChartBatteryTemp(sensor); }
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
    borderColor: '#009FE3',
    backgroundColor: 'rgba(0,159,227,0.10)',
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
  S.pChart = new Chart(D.presCanvas, {
    type: 'line', data: { labels, datasets: pDatasets },
    options: {
      responsive: true, maintainAspectRatio: false,
      interaction: { mode: 'index', intersect: false },
      plugins: {
        legend: { display: target != null, labels: { color: '#4A4D5E', font: { size: 11 } } },
        tooltip: { callbacks: { label: ctx => ctx.datasetIndex === 0
          ? ` ${ctx.raw?.toFixed(3) ?? '\u2013'} bar`
          : ` ${ctx.raw?.toFixed(2)} bar (target)` } }
      },
      scales: {
        x: { type: 'time', time: { unit: guessTimeUnit(recs) }, ...scaleCommon, ticks: { ...scaleCommon.ticks, maxTicksLimit: 6 } },
        y: { min: yMin, max: yMax, ...scaleCommon, ticks: { ...scaleCommon.ticks, callback: v => v.toFixed(2) + ' bar' } },
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
          y: { ...scaleCommon, ticks: { ...scaleCommon.ticks, callback: v => v.toFixed(0) + '\u00b0C' } },
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
          y: { min: 0, max: 100, ...scaleCommon, ticks: { ...scaleCommon.ticks, callback: v => v + '%' } },
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
          y: { ...scaleCommon, ticks: { ...scaleCommon.ticks, callback: v => v.toFixed(0) + '\u00b0C' } },
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
          y: { ...scaleCommon, ticks: { ...scaleCommon.ticks, callback: v => v.toFixed(0) + '\u00b0C' } },
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

// ─── Map ──────────────────────────────────────────────────────────────────────
function renderMap() {
  D.mapCont.innerHTML = '';
  const sensor = S.sensors.find(s => s.sensorID === S.selected);
  const target = sensor?.targetPressureBar ?? null;
  const gps    = S.records.filter(r => r.latitude != null && r.longitude != null);

  if (!gps.length) {
    D.mapCont.innerHTML = `
      <div class="map-nodata">
        <div class="nodata-icon">🛰</div>
        <p>No GPS data in this period</p>
        <small>Enable Location Services in the NetMap app settings and keep scanning.</small>
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
        🔵 <b>${r.pressureBar?.toFixed(3) ?? '–'} bar</b>
        ${r.temperatureC != null ? `<br>🌡 ${r.temperatureC.toFixed(1)} °C` : ''}
        ${r.vbattVolts   != null ? `<br>🔋 ${r.vbattVolts.toFixed(2)} V`   : ''}
      </div>`).addTo(map);
      return;
    }

    // Cluster bubble — radius grows logarithmically with count
    const bubbleR  = isLast ? 14 : Math.round(10 + Math.log2(count) * 3.5);
    const fontSize = bubbleR < 14 ? 10 : bubbleR < 18 ? 11 : 13;
    const label    = isLast ? '📍' : count;
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
      🕐 ${df.format(new Date(first.timestamp))}${count > 1 ? `<br>&nbsp;&nbsp;&nbsp;&nbsp;→ ${df.format(new Date(last.timestamp))}` : ''}<br>
      🔵 avg <b>${avgP} bar</b> · min ${minP} · max ${maxP}
      ${last.temperatureC != null ? `<br>🌡 ${last.temperatureC.toFixed(1)} °C` : ''}
      ${last.vbattVolts   != null ? `<br>🔋 ${last.vbattVolts.toFixed(2)} V`   : ''}
    </div>`;

    L.marker([lat, lng], { icon }).bindPopup(popup).addTo(map);
  });

  try { map.fitBounds(lls, { padding: [30, 30], maxZoom: 16 }); } catch (_) {}
}

// ─── Table ────────────────────────────────────────────────────────────────────
function renderTable() {
  const sensor = S.sensors.find(s => s.sensorID === S.selected);
  const target = sensor?.targetPressureBar ?? null;
  const df     = new Intl.DateTimeFormat([], { dateStyle: 'short', timeStyle: 'medium' });
  const rows   = [...S.records].reverse().slice(0, 2000);

  if (isTpms(sensor)) {
    $('table-head').innerHTML = '<tr><th>Time</th><th>Pressure</th><th>Status</th><th>Target</th><th>Temp</th><th>Battery</th><th>Wheel</th><th>GPS</th></tr>';
    D.tableBody.innerHTML = rows.map(r => {
      const status = pStatus(r.pressureBar, target);
      const color  = SC[status];
      const gpsLink = r.latitude != null
        ? `<a href="https://www.openstreetmap.org/?mlat=${r.latitude}&mlon=${r.longitude}&zoom=16" target="_blank" style="color:var(--m-blue)">📍</a>` : '–';
      return `<tr>
        <td class="td-ts">${df.format(new Date(r.timestamp))}</td>
        <td class="td-pres" style="color:${color}">${r.pressureBar?.toFixed(3) ?? '–'} bar</td>
        <td><span class="status-badge" style="background:${SC_BG[status]};color:${color}">${status.toUpperCase()}</span></td>
        <td>${r.targetPressureBar != null ? r.targetPressureBar.toFixed(2) + ' bar' : '–'}</td>
        <td>${r.temperatureC  != null ? r.temperatureC.toFixed(1) + ' °C' : '–'}</td>
        <td>${r.vbattVolts    != null ? r.vbattVolts.toFixed(2) + ' V' : '–'}</td>
        <td>${r.wheelPosition ?? '–'}</td>
        <td>${gpsLink}</td>
      </tr>`;
    }).join('');
  } else if (sensor?.brand === 'airtag') {
    $('table-head').innerHTML = '<tr><th>Time</th><th>GPS</th></tr>';
    D.tableBody.innerHTML = rows.map(r => {
      const gpsLink = r.latitude != null
        ? `<a href="https://www.openstreetmap.org/?mlat=${r.latitude}&mlon=${r.longitude}&zoom=16" target="_blank" style="color:var(--m-blue)">${r.latitude.toFixed(5)}, ${r.longitude.toFixed(5)}</a>` : '–';
      return `<tr><td class="td-ts">${df.format(new Date(r.timestamp))}</td><td>${gpsLink}</td></tr>`;
    }).join('');
  } else {
    // STIHL / ELA / autres
    $('table-head').innerHTML = '<tr><th>Time</th><th>Battery</th><th>State</th><th>Health</th><th>Total time</th><th>Temp</th><th>Vbatt</th><th>GPS</th></tr>';
    D.tableBody.innerHTML = rows.map(r => {
      const bPct = r.batteryPct;
      const bCol = bPct != null ? (bPct > 50 ? '#34d399' : bPct > 20 ? '#fbbf24' : '#f87171') : '';
      const hPct = r.healthPct;
      const hCol = hPct != null ? (hPct > 70 ? '#34d399' : hPct > 40 ? '#fbbf24' : '#f87171') : '';
      const gpsLink = r.latitude != null
        ? `<a href="https://www.openstreetmap.org/?mlat=${r.latitude}&mlon=${r.longitude}&zoom=16" target="_blank" style="color:var(--m-blue)">📍</a>` : '–';
      return `<tr>
        <td class="td-ts">${df.format(new Date(r.timestamp))}</td>
        <td style="color:${bCol}">${bPct != null ? bPct + '%' : '–'}</td>
        <td>${r.chargeState ?? '–'}</td>
        <td style="color:${hCol}">${hPct != null ? hPct + '%' : '–'}</td>
        <td>${fmtDuration(r.totalSeconds)}</td>
        <td>${r.temperatureC != null ? r.temperatureC.toFixed(1) + ' °C' : '–'}</td>
        <td>${r.vbattVolts   != null ? r.vbattVolts.toFixed(2) + ' V' : '–'}</td>
        <td>${gpsLink}</td>
      </tr>`;
    }).join('');
  }
}

// ─── Master render ────────────────────────────────────────────────────────────
function renderAll() {
  renderBreadcrumb();
  renderSensorInfoCard();
  renderStats();

  // Show/hide Chart tab depending on sensor brand
  const sensor = S.sensors.find(s => s.sensorID === S.selected);
  const hasChart = sensor && sensor.brand !== 'airtag';
  const chartBtn = document.querySelector('.mode-btn[data-mode="chart"]');
  if (chartBtn) chartBtn.style.display = hasChart ? '' : 'none';
  // If current mode is chart but no chart available, switch to map
  if (!hasChart && S.mode === 'chart') {
    S.mode = 'map';
    document.querySelectorAll('.mode-btn').forEach(b => b.classList.remove('active'));
    const mapBtn = document.querySelector('.mode-btn[data-mode="map"]');
    if (mapBtn) mapBtn.classList.add('active');
  }

  showMode(S.mode);
  if (!S.records.length) return;
  if (S.mode === 'chart') renderChart();
  if (S.mode === 'map')   renderMap();
  if (S.mode === 'table') renderTable();
}

// ─── Select sensor ────────────────────────────────────────────────────────────
async function selectSensor(sensorID) {
  if (!sensorID) return;
  S.selected = sensorID;
  renderSidebar();
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
  try {
    await Promise.all([loadSensors(), loadServerVehicles()]);
    renderSidebar();
    if (S.selected) { await loadRecords(); renderAll(); }
  } catch (e) { console.error('refresh:', e); }
}

function setAutoRefresh(on) {
  S.autoRefresh = on;
  if (S.timer) { clearInterval(S.timer); S.timer = null; }
  if (on) S.timer = setInterval(refresh, REFRESH_MS);
  $('autorefresh-btn').classList.toggle('active', on);
  $('autorefresh-btn').title = on ? 'Auto-refresh ON (30 s) — click to stop' : 'Auto-refresh OFF — click to enable';
}

// ─── Event setup ──────────────────────────────────────────────────────────────
function setup() {
  // Asset type selector change (show/hide vehicle vs tool fields)
  $('vf-type').addEventListener('change', () => updateModalFields($('vf-type').value));

  // Admin panel
  const adminBtn = $('admin-btn');
  if (adminBtn) adminBtn.addEventListener('click', openAdminPanel);
  $('admin-modal-close').addEventListener('click', closeAdminPanel);
  $('admin-modal').addEventListener('click', e => { if (e.target === $('admin-modal')) closeAdminPanel(); });
  $('admin-add-user-btn').addEventListener('click', () => $('new-user-modal').style.display = 'flex');
  $('admin-add-asset-btn').addEventListener('click', () => openVehicleModal());
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
      await renderAdminPanel();
    } catch (err) {
      errEl.textContent = err.message; errEl.style.display = 'block';
    } finally { btn.disabled = false; }
  });

  // Vehicle dropdown
  D.vehicleSelect.addEventListener('change', () => {
    S.vehicleFilter = D.vehicleSelect.value || null;
    // Refresh edit button visibility
    const editBtn = $('edit-vehicle-btn');
    if (editBtn) {
      const groups = groupByVehicle();
      const g  = S.vehicleFilter ? groups[S.vehicleFilter] : null;
      const sv = g?.serverVehicle;
      editBtn.style.display = (AUTH.isAdmin && sv) ? '' : 'none';
      editBtn.onclick = sv ? () => openVehicleModal(sv) : null;
    }
    renderSensors();
    // Auto-select first sensor of chosen vehicle
    const first = S.sensors.find(s => s.vehicleID === S.vehicleFilter);
    if (first) selectSensor(first.sensorID);
    else { S.selected = null; S.records = []; renderAll(); }
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
    };
    const errEl = $('modal-error');
    const saveB = $('modal-save-btn');
    errEl.style.display = 'none'; saveB.disabled = true;
    try {
      await saveVehicle(payload);
      closeVehicleModal();
      await loadServerVehicles();
      renderSidebar();
      if ($('admin-modal').style.display !== 'none') await renderAdminPanel();
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
      if ($('admin-modal').style.display !== 'none') await renderAdminPanel();
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
      saveAuth({ token: data.token, username: data.email, role: data.role }); applyAuthUI();
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
    if (AUTH.token) await fetch('/api/auth/logout', { method: 'POST', headers: authHeaders() }).catch(() => {});
    clearAuth(); location.reload();
  });

  // Sensor click
  D.sensorList.addEventListener('click', e => {
    const row = e.target.closest('[data-sid]');
    if (row) selectSensor(row.dataset.sid);
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
    if (S.records.length) {
      if (S.mode === 'chart') renderChart();
      if (S.mode === 'map')   renderMap();
      if (S.mode === 'table') renderTable();
    }
  });

  $('refresh-btn').addEventListener('click', refresh);
  $('autorefresh-btn').addEventListener('click', () => setAutoRefresh(!S.autoRefresh));

  // Theme toggle
  $('theme-btn').addEventListener('click', () => {
    const light = !document.documentElement.hasAttribute('data-theme');
    document.documentElement.setAttribute('data-theme', light ? 'light' : '');
    localStorage.setItem('netmap-theme', light ? 'light' : 'dark');
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

async function renderAdminPanel() {
  const list = $('admin-users-list');
  list.innerHTML = '<p class="admin-loading">Loading…</p>';
  try {
    const [users, assets] = await Promise.all([
      apiFetch('/api/admin/users'),
      apiFetch('/api/vehicles'),
    ]);
    if (!users.length) {
      list.innerHTML = '<p class="sidebar-hint">No users.</p>';
      return;
    }
    list.innerHTML = users.map(u => {
      const linked = new Set(u.assetIDs || []);
      const checks = assets.length
        ? assets.map(a => `
          <label class="admin-asset-check">
            <input type="checkbox" data-user="${u.id}" data-asset="${a.id}"${linked.has(a.id) ? ' checked' : ''}>
            ${a.name}
          </label>`).join('')
        : '<span class="sidebar-hint">No assets</span>';
      return `
        <div class="admin-user-row" data-uid="${u.id}">
          <div class="admin-user-header">
            <div class="admin-user-info">
              <span class="admin-user-email">${u.email}</span>
              ${u.displayName ? `<span class="admin-user-dname">${u.displayName}</span>` : ''}
              <span class="role-badge ${u.role}">${u.role}</span>
            </div>
            <button class="modal-btn-danger admin-small-btn" data-delete-user="${u.id}" title="Delete user">🗑</button>
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
        const uid  = btn.dataset.deleteUser;
        const user = users.find(u => u.id === uid);
        if (!confirm(`Delete user ${user?.email}? This action is irreversible.`)) return;
        try { await adminDeleteUser(uid); await renderAdminPanel(); }
        catch (err) { alert(err.message); }
      });
    });
  } catch (err) {
    list.innerHTML = `<p class="auth-error">${err.message}</p>`;
  }
}

function openAdminPanel()  { $('admin-modal').style.display = 'flex'; renderAdminPanel(); }
function closeAdminPanel() { $('admin-modal').style.display = 'none'; }
// ─── Init ─────────────────────────────────────────────────────────────────────
async function main() {
  if (localStorage.getItem('netmap-theme') === 'light') {
    document.documentElement.setAttribute('data-theme', 'light');
  }
  setup();  // register all event listeners first (auth form needs to be live)

  try {
    await checkAuth();
    await Promise.all([loadSensors(), loadServerVehicles(), loadAssetTypes()]);
    // Auto-select first vehicle then first sensor
    const groups = groupByVehicle();
    const firstVehicle = Object.keys(groups)[0];
    if (firstVehicle) {
      S.vehicleFilter = firstVehicle;
      S.selected      = groups[firstVehicle].sensors[0]?.sensorID ?? null;
      if (S.selected) await loadRecords();
    }
    renderSidebar();
    renderAll();
  } catch (e) {
    console.error('Init error:', e);
    D.sensorList.innerHTML = `<div class="sidebar-hint" style="color:var(--danger)">
      Error: ${e.message}<br>
      <small>Is NetMapServer running?<br>Start with: <code>swift run App</code></small>
    </div>`;
  }
}

main();
