# NetMap UI/UX Analysis
*Generated: 7 March 2026*

## UI Weaknesses

### Layout & Structure
- Admin panel is a side drawer — with 5+ tabs (Users, Assets, Trackers, Security, Stats) it's becoming cramped and navigation is not obvious
- No persistent navigation — single-page with no URL routing; back/forward buttons are broken, can't deep-link to a sensor or tab
- Sidebar fixed at 290px with no resize handle or collapse option; significant real estate on laptop screens

### Data Density vs. Readability
- Tables are the primary UI pattern for everything — events, journeys, lifecycle, security — but with 10+ columns they break down on smaller screens and become hard to scan
- No row hover state on most tables, making it hard to track which row you're reading
- Dates use browser default locale in some places, custom `dfShortEv` in others — inconsistent visual weight

### Visual Hierarchy
- KPI cards have no color coding (green for healthy, amber for warning thresholds) — all numbers feel equal
- Tab bar in admin drawer has subtle active state, not immediately obvious
- Error states and empty states are inline plain text (`color:var(--fg3)`) with no iconography, indistinguishable from normal secondary content

### Charts
- Sparkline bars use rotated labels at `-45deg` — will overlap badly at 30 days in narrow containers
- No axis labels or gridlines — absolute values invisible without hover
- All charts custom-built from `div`s — no charting library, so tooltips/zoom/interactivity are absent

### Responsiveness
- Layout is desktop-assumed; sidebar + main panel will break below ~900px
- Font sizes go as small as 9px (bar labels) — painful on non-retina or mobile

---

## UX vs. Pro Products (Grafana, Datadog, Samsara)

| Aspect | NetMap | Pro product |
|---|---|---|
| **Time navigation** | Period buttons + custom picker | Draggable time range on chart, zoom-in on anomaly |
| **Live data** | Auto-refresh timer (polling) | WebSocket push, streaming charts |
| **Alerting** | None in UI | Threshold alerts, notification channels |
| **Search/filter** | None across events or readings | Full-text search, saved filters, faceted filtering |
| **Correlation** | Events and readings in separate tabs | Overlay events on time-series charts |
| **State persistence** | Only period in localStorage | Full URL state, shareable links, dashboards |
| **Loading feedback** | Skeleton rows | Progressive loading, partial data visible |
| **Error recovery** | Toast "Delete failed" | Retry button, detailed error with suggested action |
| **Keyboard navigation** | None | Full keyboard shortcuts, command palette |
| **Data export** | None | CSV/JSON export of any query result |

## Top Priority Gaps

1. **No cross-sensor timeline** — no way to see "what happened at this time" across multiple sensors simultaneously. A timeline overlaying GPS events + lifecycle + sensor readings would be transformative.

2. **No fleet overview** — can't see current state at a glance for all assets simultaneously. Sidebar shows sensors with a badge but no summary of alarm states, battery levels, or last-seen deltas in a scannable grid.

---

## Improvement Plan

Ordered by impact vs. effort. Each phase is self-contained and shippable.

---

### Phase 1 — Quick wins (1–2 days, zero new dependencies)

#### 1.1 Table: row hover + sticky header
- Add `tbody tr:hover { background: var(--bg3); }` to `style.css`.
- Add `thead { position: sticky; top: 0; background: var(--bg2); z-index: 1; }`.
- Fixes the most common readability complaint at zero cost.

#### 1.2 KPI cards: colour-coded thresholds
- The `stat-value` elements already know the value; add a `data-status` attribute (`ok/warn/danger`) at render time using the existing `pStatus()` logic and apply a matching CSS colour.
- Adds immediate visual triage without any new component.

#### 1.3 Consistent date formatting
- Replace all raw `toLocaleDateString` / `toLocaleString` calls with the existing `fmtTs()` helper throughout `app.js`.
- Creates visual consistency across all views.

#### 1.4 Empty and error states: add icons
- The existing `nodata-icon` pattern (SVG + message) is already used in the chart GPS-only state. Apply it to every `innerHTML = '<p style="color:var(--fg3)…">'` pattern in the Events, Alerts, System, and Errors views.

#### 1.5 Bar chart label fix
- In the sparkline rendering, replace `-45deg` label rotation with `display: none` for bars when the period is `30D`, or switch to showing the label only on hover via a CSS `title` attribute tooltip. Prevents overlap at 30 days.

---

### Phase 2 — Navigation & state (3–5 days, no new dependencies)

#### 2.1 URL hash routing
- Encode the current state as `#vehicleID/sensorID/mode/period` (e.g. `#vehicle-3/sensor-42/chart/7D`).
- Read on load; write on every state change via `history.replaceState`.
- Enables back/forward, deep-links, and bookmarks with no backend changes.

#### 2.2 Collapsible sidebar
- Add a `<button id="sidebar-toggle">` at the sidebar edge.
- Toggle a `.sidebar-collapsed` class on `#main` that sets `--sidebar-w: 44px` and hides text labels.
- Recovers ~250px of content space on laptop screens.

#### 2.3 Admin panel: move to a dedicated page or full-screen modal
- The current side drawer is 380px wide with 5 tabs — not enough room for the security audit table (8+ columns).
- Replace the drawer with a `position: fixed; inset: 0` full-screen overlay (reuse `logs-overlay` pattern already in the code).
- No new routing needed; the existing tab/pane structure is kept.

---

### Phase 3 — Data & charts (1 week)

#### 3.1 Adopt Chart.js for all charts (it is already loaded)
- `chart.js@4.4.2` and `chartjs-adapter-date-fns` are already included in `index.html` for the pressure/temperature charts.
- The sparkline bars in the stats panel and driver-behavior charts are currently hand-built `div`-based. Migrate them to `Chart.js` bar charts to get: proper axis labels, gridlines, zoom plugin, and hover tooltips — for free.

#### 3.2 Axis labels and gridlines on existing Chart.js charts
- The existing `pressure-canvas` and `temp-canvas` charts already use Chart.js but have `display: false` for axes. Enabling them takes ~10 lines of config change.
- Add a y-axis label (`bar`) and x-axis time ticks with the adapter already loaded.

#### 3.3 Event overlay on time-series chart
- Fetch the alert events for the selected period in parallel with records.
- Render them as vertical annotation lines on the Chart.js chart using the `chartjs-plugin-annotation` plugin (CDN, ~8 KB).
- Correlates pressure drops with alert events on one view — the highest-value feature gap identified.

#### 3.4 Data export button
- Add a `Export CSV` button to the Table view toolbar.
- Implementation: 5 lines of JS — iterate `S.records`, build a CSV string, trigger a `<a download>` click.

---

### Phase 4 — Fleet overview (1 week)

#### 4.1 Fleet summary bar (above sidebar)
- Add a horizontal strip above the sensor list showing aggregate counts: `🟢 N ok · 🟡 N warn · 🔴 N alert · 🔋 N low battery`.
- Data is already available in `S.sensors` on every refresh.

#### 4.2 Fleet grid view (new mode button in toolbar)
- Add a `Fleet` mode button (alongside Map, Chart, Events…).
- Renders a CSS grid of sensor cards with: icon, name, last pressure, status badge, last-seen delta.
- Clicking a card selects that sensor and switches to Chart mode.
- Replaces the current workflow of opening the dropdown to scan all sensor states.

#### 4.3 Cross-sensor timeline (stretch goal)
- A dedicated `Timeline` mode that fetches the last N events for *all* sensors of the selected vehicle in one call.
- Renders a swimlane chart (one row per sensor, time on x-axis, events as dots) using Chart.js scatter.
- Requires a new API endpoint: `GET /api/vehicles/:id/events?from=&to=` — the underlying data is already in the DB.

---

### Phase 5 — Live data & alerting (2 weeks)

#### 5.1 WebSocket push (replace polling)
- Add a Vapor WebSocket route that pushes a `{type: "record", sensorID, data}` JSON message on every new record insert.
- Client sides replaces the 30s polling timer with a WS connection; falls back to polling on disconnect.
- Eliminates the ~15s average data lag with polling.

#### 5.2 In-browser threshold alerts
- Add a `thresholds` config object per sensor (stored in `localStorage` or a new API endpoint).
- On each data refresh, compare readings against thresholds; fire a browser `Notification` (with permission) and a persistent toast if crossed.
- No backend changes required for a client-only MVP.

---

### Phase 6 — Polish & accessibility (ongoing)

| Item | Effort | Notes |
|---|---|---|
| Keyboard navigation (arrow keys between sensors, `Escape` to close modals) | Small | All modals already trap focus, just need key handlers |
| `prefers-reduced-motion` media query for transitions | Trivial | 2 CSS lines |
| `aria-live` region for toast notifications | Small | Screen-reader support |
| Responsive breakpoint at 900px (stack sidebar above content) | Medium | 30 lines of CSS |
| Command palette (`⌘K`) for jumping to asset/sensor | Large | Could use a lightweight lib like `ninja-keys` |
