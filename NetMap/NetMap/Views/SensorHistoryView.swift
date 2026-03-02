import SwiftUI
import Charts
import WebKit

// MARK: - History Period

enum HistoryPeriod: String, CaseIterable, Identifiable {
    case h1     = "1H"
    case h24    = "24H"
    case d7     = "7D"
    case d30    = "30D"
    case custom = "Custom"

    var id: String { rawValue }

    func range(customFrom: Date, customTo: Date) -> (from: Date, to: Date) {
        let now = Date()
        switch self {
        case .h1:     return (now.addingTimeInterval(-3_600),    now)
        case .h24:    return (now.addingTimeInterval(-86_400),   now)
        case .d7:     return (now.addingTimeInterval(-604_800),  now)
        case .d30:    return (now.addingTimeInterval(-2_592_000), now)
        case .custom: return (customFrom, customTo)
        }
    }
}

// MARK: - History View Mode

private enum HistViewMode: String, CaseIterable, Identifiable {
    case chart = "Chart"
    case map   = "Map"
    var id: String { rawValue }
    var systemImage: String { self == .chart ? "chart.line.uptrend.xyaxis" : "map" }
}

// MARK: - Sensor History View

struct SensorHistoryView: View {
    @EnvironmentObject var store:        VehicleStore
    @EnvironmentObject var serverClient: NetMapServerClient

    var preselectedSensorID: UUID? = nil

    @State private var selectedVehicleID: UUID?
    @State private var selectedSensorID: UUID?
    @State private var period: HistoryPeriod = .h24
    @State private var customFrom = Calendar.current.date(byAdding: .day, value: -1, to: Date())!
    @State private var customTo   = Date()
    @State private var viewMode: HistViewMode = .chart

    // Async-loaded history from server
    @State private var records:   [PressureRecord] = []
    @State private var isLoading  = false
    @State private var loadError: String? = nil

    // MARK: Helpers

    private struct SensorEntry: Identifiable {
        let sensor: PairedSensor
        let vehicle: VehicleConfig
        var id: UUID { sensor.id }
        var chipLabel: String {
            let pos = sensor.wheelPosition?.shortLabel
                      ?? String(sensor.brand.displayName.prefix(3))
            return pos
        }
    }

    private var allSensors: [SensorEntry] {
        store.vehicles.flatMap { v in v.pairedSensors.map { SensorEntry(sensor: $0, vehicle: v) } }
    }
    private var selectedVehicle: VehicleConfig? {
        guard let id = selectedVehicleID else { return store.vehicles.first }
        return store.vehicles.first { $0.id == id } ?? store.vehicles.first
    }
    private var vehicleSensors: [SensorEntry] {
        guard let v = selectedVehicle else { return [] }
        return v.pairedSensors.map { SensorEntry(sensor: $0, vehicle: v) }
    }
    private var selectedEntry: SensorEntry? {
        guard let id = selectedSensorID else { return nil }
        return vehicleSensors.first { $0.id == id }
    }
    private var statsMin: Double? { records.map(\.pressureBar).min() }
    private var statsMax: Double? { records.map(\.pressureBar).max() }
    private var statsAvg: Double? {
        guard !records.isEmpty else { return nil }
        return records.map(\.pressureBar).reduce(0, +) / Double(records.count)
    }

    private func loadRecords() async {
        guard let entry = selectedEntry else { records = []; return }
        guard serverClient.isEnabled    else { records = []; return }
        let (from, to) = period.range(customFrom: customFrom, customTo: customTo)
        isLoading = true
        loadError = nil
        defer { isLoading = false }
        do {
            records = try await serverClient.fetchHistory(
                sensorID: entry.sensor.stableSensorID, from: from, to: to
            )
        } catch {
            loadError = error.localizedDescription
            records = []
        }
    }

    // MARK: Body

    var body: some View {
        VStack(spacing: 0) {
            sensorPickerBar
            Divider()
            if allSensors.isEmpty {
                ContentUnavailableView {
                    Label("No Paired Sensors", systemImage: "sensor.fill")
                } description: {
                    Text("Pair TMS sensors to vehicles to start recording pressure history.")
                }
            } else if vehicleSensors.isEmpty {
                ContentUnavailableView {
                    Label("No Sensors on this Vehicle", systemImage: "sensor.fill")
                } description: {
                    Text("Pair sensors to this vehicle from the Vehicles tab.")
                }
            } else if !serverClient.isEnabled {
                ContentUnavailableView {
                    Label("Server Required", systemImage: "server.rack")
                } description: {
                    Text("Enable NetMap Server in Settings to fetch sensor history.")
                }
            } else {
                periodBar
                Divider()
                if isLoading {
                    Spacer()
                    ProgressView("Loading…").padding()
                    Spacer()
                } else if let err = loadError {
                    let isKeyError = err.localizedLowercase.contains("api key") || err.localizedLowercase.contains("401")
                    let isNetError = err.localizedLowercase.contains("network") || err.localizedLowercase.contains("connection")
                    ContentUnavailableView {
                        Label(
                            isKeyError ? "API Key Rejected"
                            : isNetError ? "No Connection"
                            : "Load Error",
                            systemImage: isKeyError ? "key.slash.fill"
                                : isNetError ? "wifi.slash"
                                : "exclamationmark.triangle"
                        )
                    } description: {
                        Text(err)
                        if isKeyError {
                            Text("Update the API key in Server Settings.")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                    } actions: {
                        Button("Retry") { Task { await loadRecords() } }
                            .buttonStyle(.bordered)
                    }
                } else if records.isEmpty {
                    ContentUnavailableView {
                        Label("No Readings", systemImage: "chart.line.downtrend.xyaxis")
                    } description: {
                        Text("No data recorded for this sensor in this period.")
                    }
                } else {
                    statsBar
                    Divider()
                    modeBar
                    Divider()
                    contentArea
                }
            }
        }
        .navigationTitle("Sensor History")
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Picker("Asset", selection: Binding(
                    get: { selectedVehicleID ?? store.vehicles.first?.id },
                    set: { selectedVehicleID = $0 }
                )) {
                    ForEach(store.vehicles) { v in
                        Text(v.name).tag(Optional(v.id))
                    }
                }
                .pickerStyle(.menu)
                .disabled(store.vehicles.isEmpty)
            }
        }
        .task {
            if selectedVehicleID == nil {
                selectedVehicleID = store.vehicles.first?.id
            }
            if selectedSensorID == nil {
                selectedSensorID = preselectedSensorID ?? vehicleSensors.first?.id
            }
            await loadRecords()
        }
        .onChange(of: selectedVehicleID) { _, _ in
            // Auto-select first sensor of new vehicle
            selectedSensorID = vehicleSensors.first?.id
            Task { await loadRecords() }
        }
        .onChange(of: selectedSensorID) { _, _ in Task { await loadRecords() } }
        .onChange(of: period)           { _, _ in Task { await loadRecords() } }
        .onChange(of: customFrom)       { _, _ in
            if period == .custom { Task { await loadRecords() } }
        }
        .onChange(of: customTo)         { _, _ in
            if period == .custom { Task { await loadRecords() } }
        }
    }

    // MARK: Sensor Picker

    private var sensorPickerBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(vehicleSensors) { entry in
                    let sel = selectedSensorID == entry.id
                    Button { selectedSensorID = entry.id } label: {
                        HStack(spacing: 4) {
                            Image(systemName: entry.sensor.brand.systemImage)
                                .font(.caption.weight(.medium))
                            Text(entry.chipLabel)
                                .font(.subheadline.weight(sel ? .semibold : .regular))
                        }
                        .padding(.horizontal, 12).padding(.vertical, 7)
                        .background(
                            Capsule().fill(sel ? Color.accentColor : Color.secondary.opacity(0.12))
                        )
                        .foregroundStyle(sel ? .white : .primary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
        }
        .background(.bar)
    }

    // MARK: Period Bar

    @ViewBuilder
    private var periodBar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                ForEach(HistoryPeriod.allCases) { p in
                    let sel = period == p
                    Button {
                        withAnimation(.easeInOut(duration: 0.18)) { period = p }
                    } label: {
                        Text(p.rawValue)
                            .font(.caption.weight(sel ? .bold : .regular))
                            .padding(.horizontal, 11).padding(.vertical, 5)
                            .background(
                                RoundedRectangle(cornerRadius: 7)
                                    .fill(sel ? Color.accentColor : Color.secondary.opacity(0.10))
                            )
                            .foregroundStyle(sel ? .white : .primary)
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.top, 10)
            .padding(.bottom, period == .custom ? 8 : 10)

            if period == .custom {
                HStack(spacing: 10) {
                    Text("From")
                        .font(.caption.weight(.medium)).foregroundStyle(.secondary)
                    DatePicker("", selection: $customFrom,
                               in: ...customTo,
                               displayedComponents: [.date, .hourAndMinute])
                        .labelsHidden().datePickerStyle(.compact)
                    Text("To")
                        .font(.caption.weight(.medium)).foregroundStyle(.secondary)
                    DatePicker("", selection: $customTo,
                               in: customFrom...,
                               displayedComponents: [.date, .hourAndMinute])
                        .labelsHidden().datePickerStyle(.compact)
                    Spacer()
                }
                .padding(.horizontal, 16).padding(.bottom, 10)
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .background(Color.secondary.opacity(0.03))
    }

    // MARK: Stats Bar

    private var statsBar: some View {
        HStack(spacing: 0) {
            statCell(label: "Readings", value: "\(records.count)")
            Divider().frame(height: 24)
            if let v = statsMin {
                statCell(label: "Min",  value: String(format: "%.2f bar", v))
                Divider().frame(height: 24)
            }
            if let v = statsAvg {
                statCell(label: "Avg",  value: String(format: "%.2f bar", v))
                Divider().frame(height: 24)
            }
            if let v = statsMax {
                statCell(label: "Max",  value: String(format: "%.2f bar", v))
            }
            Spacer()
        }
        .padding(.horizontal, 4).padding(.vertical, 8)
        .background(Color.secondary.opacity(0.04))
    }

    private func statCell(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).font(.caption2).foregroundStyle(.tertiary)
            Text(value).font(.caption.weight(.semibold).monospacedDigit())
        }
        .padding(.horizontal, 12)
    }

    // MARK: Mode Bar

    private var modeBar: some View {
        HStack(spacing: 12) {
            Picker("", selection: $viewMode) {
                ForEach(HistViewMode.allCases) { m in
                    Label(m.rawValue, systemImage: m.systemImage).tag(m)
                }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 180)
            if viewMode == .map {
                let gpsCount = records.filter { $0.latitude != nil }.count
                Text("\(gpsCount) / \(records.count) with GPS")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
    }

    // MARK: Content

    @ViewBuilder
    private var contentArea: some View {
        switch viewMode {
        case .chart:
            ScrollView {
                PressureHistoryChart(
                    records: records,
                    target: selectedEntry?.sensor.targetPressureBar
                )
                .padding(16)
            }
        case .map:
            let gpsRecs = records.filter { $0.latitude != nil && $0.longitude != nil }
            if gpsRecs.isEmpty {
                ContentUnavailableView {
                    Label("No GPS Data", systemImage: "location.slash.fill")
                } description: {
                    Text("Enable Location access in Settings and keep the app active to record GPS positions with sensor readings.")
                }
            } else {
                SensorOSMMapView(
                    records: gpsRecs,
                    target: selectedEntry?.sensor.targetPressureBar
                )
                .ignoresSafeArea(edges: .bottom)
            }
        }
    }
}

// MARK: - Pressure History Chart

struct PressureHistoryChart: View {
    let records: [PressureRecord]
    let target: Double?

    private var display: [PressureRecord] {
        guard records.count > 400 else { return records }
        let step = max(1, records.count / 400)
        return stride(from: 0, to: records.count, by: step).map { records[$0] }
    }

    private var yMin: Double {
        let d = display.map(\.pressureBar).min() ?? 0
        let t = target.map { $0 - 0.4 } ?? d
        return max(0, min(d, t) - 0.15)
    }
    private var yMax: Double {
        let d = display.map(\.pressureBar).max() ?? 4
        let t = target.map { $0 + 0.4 } ?? d
        return max(d, t) + 0.15
    }
    private func statusColor(_ p: Double) -> Color {
        guard let t = target else { return .accentColor }
        return PressureStatus.evaluate(actual: p, target: t).color
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {

            // ── Pressure chart ────────────────────────────────────────
            VStack(alignment: .leading, spacing: 6) {
                Label("Pressure (bar)", systemImage: "gauge.medium")
                    .font(.caption.weight(.semibold)).foregroundStyle(.secondary)

                Chart {
                    ForEach(display) { r in
                        AreaMark(
                            x: .value("Time", r.timestamp),
                            yStart: .value("Base", yMin),
                            yEnd: .value("Pressure", r.pressureBar)
                        )
                        .foregroundStyle(
                            LinearGradient(
                                colors: [Color.accentColor.opacity(0.22), .clear],
                                startPoint: .top, endPoint: .bottom
                            )
                        )
                        .interpolationMethod(.catmullRom)
                    }
                    ForEach(display) { r in
                        LineMark(
                            x: .value("Time", r.timestamp),
                            y: .value("Pressure", r.pressureBar)
                        )
                        .foregroundStyle(Color.accentColor)
                        .lineStyle(StrokeStyle(lineWidth: 2))
                        .interpolationMethod(.catmullRom)
                    }
                    if display.count <= 200 {
                        ForEach(display) { r in
                            PointMark(
                                x: .value("Time", r.timestamp),
                                y: .value("Pressure", r.pressureBar)
                            )
                            .foregroundStyle(statusColor(r.pressureBar))
                            .symbolSize(18)
                        }
                    }
                    if let t = target {
                        RuleMark(y: .value("Target", t))
                            .foregroundStyle(.orange.opacity(0.80))
                            .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [6, 3]))
                            .annotation(position: .trailing, spacing: 4) {
                                Text("Target").font(.caption2).foregroundStyle(.orange)
                            }
                    }
                }
                .chartYScale(domain: yMin ... yMax)
                .chartXAxis { AxisMarks(values: .automatic(desiredCount: 5)) }
                .chartYAxis {
                    AxisMarks(values: .automatic(desiredCount: 5)) { v in
                        AxisGridLine()
                        AxisTick()
                        AxisValueLabel {
                            if let d = v.as(Double.self) {
                                Text(String(format: "%.2f", d))
                                    .font(.caption2.monospacedDigit())
                            }
                        }
                    }
                }
                .frame(minHeight: 240)
            }

            // ── Temperature chart (if data present) ──────────────────
            if records.contains(where: { $0.temperatureC != nil }) {
                Divider()
                VStack(alignment: .leading, spacing: 6) {
                    Label("Temperature (°C)", systemImage: "thermometer.medium")
                        .font(.caption.weight(.semibold)).foregroundStyle(.secondary)

                    Chart {
                        ForEach(display) { r in
                            if let t = r.temperatureC {
                                LineMark(
                                    x: .value("Time", r.timestamp),
                                    y: .value("Temp", t)
                                )
                                .foregroundStyle(.orange)
                                .lineStyle(StrokeStyle(lineWidth: 1.5))
                                .interpolationMethod(.catmullRom)

                                AreaMark(
                                    x: .value("Time", r.timestamp),
                                    yStart: .value("Base", (display.compactMap(\.temperatureC).min() ?? 0) - 1),
                                    yEnd: .value("Temp", t)
                                )
                                .foregroundStyle(
                                    LinearGradient(
                                        colors: [Color.orange.opacity(0.18), .clear],
                                        startPoint: .top, endPoint: .bottom
                                    )
                                )
                                .interpolationMethod(.catmullRom)
                            }
                        }
                    }
                    .chartXAxis { AxisMarks(values: .automatic(desiredCount: 5)) }
                    .chartYAxis {
                        AxisMarks(values: .automatic(desiredCount: 4)) { v in
                            AxisGridLine()
                            AxisTick()
                            AxisValueLabel {
                                if let d = v.as(Double.self) {
                                    Text(String(format: "%.0f°", d))
                                        .font(.caption2.monospacedDigit())
                                }
                            }
                        }
                    }
                    .frame(height: 120)
                }
            }
        }
    }
}

// MARK: - OSM Map View

struct SensorOSMMapView: View {
    let records: [PressureRecord]
    let target: Double?

    var body: some View {
        _OSMWebView(html: buildLeafletHTML(records: records, target: target))
    }
}

// MARK: - Leaflet HTML Generator

private func buildLeafletHTML(records: [PressureRecord], target: Double?) -> String {
    let df = DateFormatter()
    df.dateStyle = .short
    df.timeStyle = .medium

    let pts: [String] = records.compactMap { r in
        guard let lat = r.latitude, let lon = r.longitude else { return nil }
        let ts  = df.string(from: r.timestamp).replacingOccurrences(of: "\"", with: "'")
        let p   = String(format: "%.2f", r.pressureBar)
        let tmp: String = r.temperatureC.map { String(format: "%.1f", $0) } ?? "null"
        let s: String
        if let tgt = target {
            switch PressureStatus.evaluate(actual: r.pressureBar, target: tgt) {
            case .ok:      s = "ok"
            case .warning: s = "warn"
            case .danger:  s = "danger"
            }
        } else { s = "ok" }
        return "{\"lat\":\(lat),\"lng\":\(lon),\"p\":\"\(p)\",\"tmp\":\(tmp),\"ts\":\"\(ts)\",\"s\":\"\(s)\"}"
    }

    let cLat = records.compactMap(\.latitude).first  ?? 48.8566
    let cLon = records.compactMap(\.longitude).first ?? 2.3522
    let ptsJS = "[\(pts.joined(separator: ","))]"

    return """
    <!DOCTYPE html>
    <html>
    <head>
    <meta charset="utf-8"/>
    <meta name="viewport" content="width=device-width,initial-scale=1,maximum-scale=1,user-scalable=no"/>
    <link rel="stylesheet" href="https://unpkg.com/leaflet@1.9.4/dist/leaflet.css"/>
    <script src="https://unpkg.com/leaflet@1.9.4/dist/leaflet.js"></script>
    <style>
    html,body{margin:0;padding:0;width:100%;height:100%;background:#1c1c1e;}
    #map{width:100%;height:100%;}
    .leaflet-popup-content-wrapper{border-radius:10px;box-shadow:0 4px 16px rgba(0,0,0,.35);}
    </style>
    </head>
    <body>
    <div id="map"></div>
    <script>
    (function(){
      var pts=\(ptsJS);
      var map=L.map('map',{preferCanvas:true}).setView([\(cLat),\(cLon)],14);
      L.tileLayer('https://{s}.tile.openstreetmap.org/{z}/{x}/{y}.png',{
        attribution:'&copy; <a href="https://openstreetmap.org/copyright">OpenStreetMap</a>',
        maxZoom:19
      }).addTo(map);
      var clr={ok:'#30D158',warn:'#FF9F0A',danger:'#FF453A'};
      var lls=pts.map(function(p){return[p.lat,p.lng];});
      if(lls.length>1){
        L.polyline(lls,{color:'#636366',weight:2,opacity:0.65,dashArray:'5 4'}).addTo(map);
      }
      pts.forEach(function(p,i){
        var c=clr[p.s]||'#8E8E93';
        var last=(i===pts.length-1);
        var m=L.circleMarker([p.lat,p.lng],{
          radius:last?10:6,
          fillColor:c,
          color:last?'#FFFFFF':'#1C1C1E',
          weight:last?2:1,
          opacity:1,
          fillOpacity:last?1:0.88
        });
        var pop='<div style="font:13px/1.65 system-ui,sans-serif;min-width:130px">'
          +'<b>'+p.ts+'</b><br>'
          +'&#x1F535; <b>'+p.p+' bar</b>'
          +(p.tmp!=='null'?'<br>&#x1F321; '+p.tmp+'&deg;C':'')
          +(last?'<br><span style="color:#30D158;font-size:11px">&#9679; Latest</span>':'')
          +'</div>';
        m.bindPopup(pop);
        m.addTo(map);
      });
      if(lls.length>0){
        try{map.fitBounds(lls,{padding:[30,30],maxZoom:16});}catch(e){}
      }
    })();
    </script>
    </body>
    </html>
    """
}

// MARK: - WKWebView Representable (cross-platform)

#if os(macOS)
private struct _OSMWebView: NSViewRepresentable {
    let html: String

    class Coordinator: NSObject {
        var lastHTML = ""
        lazy var wv: WKWebView = WKWebView()
    }
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> WKWebView { context.coordinator.wv }
    func updateNSView(_ v: WKWebView, context: Context) {
        guard html != context.coordinator.lastHTML else { return }
        context.coordinator.lastHTML = html
        v.loadHTMLString(html, baseURL: nil)
    }
}
#else
private struct _OSMWebView: UIViewRepresentable {
    let html: String

    class Coordinator: NSObject {
        var lastHTML = ""
        lazy var wv: WKWebView = WKWebView()
    }
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeUIView(context: Context) -> WKWebView { context.coordinator.wv }
    func updateUIView(_ v: WKWebView, context: Context) {
        guard html != context.coordinator.lastHTML else { return }
        context.coordinator.lastHTML = html
        v.loadHTMLString(html, baseURL: nil)
    }
}
#endif
