import SwiftUI
import CoreBluetooth

// MARK: - Cross-platform helpers

extension Color {
    /// Control background color: NSColor.controlBackgroundColor (macOS) / secondarySystemBackground (iOS)
    static var platformControlBackground: Color {
        #if os(macOS)
        Color(NSColor.controlBackgroundColor)
        #else
        Color(UIColor.secondarySystemBackground)
        #endif
    }
    /// Window background color: NSColor.windowBackgroundColor (macOS) / systemBackground (iOS)
    static var platformWindowBackground: Color {
        #if os(macOS)
        Color(NSColor.windowBackgroundColor)
        #else
        Color(UIColor.systemBackground)
        #endif
    }
}

/// Copies `text` to the clipboard (NSPasteboard on macOS, UIPasteboard on iOS)
private func copyToClipboard(_ text: String) {
    #if os(macOS)
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
    #else
    UIPasteboard.general.string = text
    #endif
}

/// Formats a duration in seconds as "Xd Xh Xm" (omitting zero-valued leading units).
private func formatDuration(_ totalSeconds: UInt32) -> String {
    let d = Int(totalSeconds) / 86_400
    let h = Int(totalSeconds) % 86_400 / 3_600
    let m = Int(totalSeconds) % 3_600  / 60
    let s = Int(totalSeconds) % 60
    if d > 0 { return "\(d)d \(h)h \(m)m" }
    if h > 0 { return "\(h)h \(m)m" }
    if m > 0 { return "\(m)m \(s)s" }
    return "\(s)s"
}

struct BLEDeviceListView: View {
    @EnvironmentObject var bleScanner: BLEScanner
    @EnvironmentObject var vehicleStore: VehicleStore
    @EnvironmentObject var serverClient: NetMapServerClient
    @State private var selectedDevice: BLEDevice?
    @State private var searchText = ""
    @State private var sortMode: SortMode = .rssi
    @State private var sensorTypeFilter: SensorTypeFilter = .all
    @State private var showServerSettings = false

    enum SortMode: String, CaseIterable {
        case rssi      = "Signal"
        case name      = "Name"
        case lastSeen  = "Recent"
        case seenCount = "Packets"
    }

    enum SensorTypeFilter: String, CaseIterable, Identifiable {
        case all    = "All"
        case tms    = "TMS"
        case stihl  = "STIHL"
        case ela    = "ELA"
        case airtag = "AirTag"
        var id: Self { self }
        var systemImage: String {
            switch self {
            case .all:    return "list.bullet"
            case .tms:    return "gauge.open.with.lines.needle.33percent"
            case .stihl:  return "waveform.badge.exclamationmark"
            case .ela:    return "location.fill.viewfinder"
            case .airtag: return "airtag"
            }
        }
    }

    /// UUIDs and MAC addresses of sensors already paired to a vehicle
    private var pairedSensorIDs: Set<UUID> {
        Set(vehicleStore.vehicles.flatMap { $0.pairedSensors }.map { $0.id })
    }
    private var pairedSensorMACs: Set<String> {
        Set(vehicleStore.vehicles.flatMap { $0.pairedSensors }.compactMap { $0.macAddress })
    }

    var filteredDevices: [BLEDevice] {
        let ids  = pairedSensorIDs
        let macs = pairedSensorMACs
        let base = bleScanner.devices.filter { device in
            // Exclude sensors already paired to a vehicle
            let isPaired = ids.contains(device.id) ||
                (device.macAddress != nil && macs.contains(device.macAddress!))
            guard !isPaired else { return false }
            let matchesSearch = searchText.isEmpty ||
                device.displayName.localizedCaseInsensitiveContains(searchText) ||
                (device.manufacturerName?.localizedCaseInsensitiveContains(searchText) ?? false) ||
                device.id.uuidString.localizedCaseInsensitiveContains(searchText)
            let matchesType: Bool
            switch sensorTypeFilter {
            case .all:    matchesType = true
            case .tms:    matchesType = device.isTMSDevice
            case .stihl:  matchesType = device.sensorBrand == .stihl
            case .ela:    matchesType = device.sensorBrand == .ela
            case .airtag: matchesType = device.isAirTagDevice
            }
            return matchesSearch && matchesType
        }
        return base.sorted { a, b in
            switch sortMode {
            case .rssi:      return a.rssi > b.rssi
            case .name:      return a.displayName < b.displayName
            case .lastSeen:  return a.lastSeen > b.lastSeen
            case .seenCount: return a.seenCount > b.seenCount
            }
        }
    }

    var body: some View {
        navigationRoot
            .onAppear {
                if bleScanner.bluetoothState == .poweredOn, !bleScanner.isScanning {
                    bleScanner.startScan()
                }
            }
            .onDisappear {
                // Do NOT stop scan here — other tabs need it running for server push
            }
            .onChange(of: bleScanner.bluetoothState) { _, state in
                if state == .poweredOn && !bleScanner.isScanning {
                    bleScanner.startScan()
                }
            }
    }

    @ViewBuilder
    private var navigationRoot: some View {
        #if os(iOS)
        NavigationStack {
            listColumnContent
                .navigationTitle("Sensors")
                .navigationBarTitleDisplayMode(.inline)
                .searchable(text: $searchText, prompt: "Search BLE devices…")
                .toolbar { toolbarItems }
                .safeAreaInset(edge: .bottom) { statusFooter }
        }
        .sheet(isPresented: $showServerSettings) {
            NavigationStack {
                ServerSettingsView()
                    .environmentObject(serverClient)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { showServerSettings = false }
                        }
                    }
            }
        }
        #else
        NavigationSplitView {
            listColumnContent
                .navigationTitle("Sensors")
                .searchable(text: $searchText, prompt: "Search BLE devices…")
                .toolbar { toolbarItems }
                .safeAreaInset(edge: .bottom) { statusFooter }
                .navigationSplitViewColumnWidth(min: 380, ideal: 440)
        } detail: {
            detailColumn
        }
        #endif
    }

    // MARK: - Toolbar (HIG: native items, no custom controls inside content)

    @ToolbarContentBuilder
    private var toolbarItems: some ToolbarContent {
        // Server settings — iOS only (macOS uses App > Settings menu)
        #if os(iOS)
        ToolbarItem(placement: .topBarLeading) {
            Button { showServerSettings = true } label: {
                Image(systemName: "server.rack")
                    .foregroundStyle(
                        serverClient.isEnabled
                            ? serverClient.connectionStatus.color
                            : Color.secondary
                    )
            }
        }
        #endif
        // Bluetooth state indicator — macOS only (iOS shows the system indicator)
        #if os(macOS)
        ToolbarItem(placement: .automatic) {
            bluetoothStateView
        }
        #endif

        // Sort mode
        ToolbarItem(placement: .automatic) {
            Picker("Sort by", selection: $sortMode) {
                ForEach(SortMode.allCases, id: \.self) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.menu)
            #if os(macOS)
            .frame(width: 130)
            #endif
            .help("Change sort order")
        }

        // Sensor type filter
        ToolbarItem(placement: .automatic) {
            Picker(selection: $sensorTypeFilter) {
                ForEach(SensorTypeFilter.allCases) { f in
                    Label(f.rawValue, systemImage: f.systemImage).tag(f)
                }
            } label: {
                Label("Filter", systemImage: sensorTypeFilter == .all ? "line.3.horizontal.decrease" : "line.3.horizontal.decrease.circle.fill")
            }
            .pickerStyle(.menu)
            .help("Filter by sensor type")
        }

        // Scan button — .topBarTrailing on iOS (.navigationBarTrailing is deprecated)
        ToolbarItem(placement: scanButtonPlacement) {
            Button {
                if bleScanner.isScanning { bleScanner.stopScan() }
                else { bleScanner.startScan() }
            } label: {
                Label(
                    bleScanner.isScanning ? "Stop" : "Scan",
                    systemImage: bleScanner.isScanning ? "stop.fill" : "wave.3.right"
                )
            }
            .help(bleScanner.isScanning ? "Stop BLE scan" : "Start BLE scan")
        }
    }

    private var scanButtonPlacement: ToolbarItemPlacement {
        #if os(macOS)
        .automatic
        #else
        .topBarTrailing
        #endif
    }

    // MARK: - Status footer (safeAreaInset — HIG: no custom VStack footer)

    @ViewBuilder
    private var statusFooter: some View {
        if !bleScanner.devices.isEmpty || bleScanner.isScanning {
            HStack(spacing: 8) {
                if !bleScanner.devices.isEmpty {
                    if sensorTypeFilter != .all {
                        let filteredCount = filteredDevices.count
                        Label("\(filteredCount) \(sensorTypeFilter.rawValue) / \(bleScanner.devices.count) total",
                              systemImage: sensorTypeFilter.systemImage)
                            .font(.caption)
                            .foregroundStyle(.cyan)
                    } else {
                        Text("\(bleScanner.devices.count) device\(bleScanner.devices.count > 1 ? "s" : "") detected")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if bleScanner.isScanning {
                    HStack(spacing: 5) {
                        // HIG: .controlSize(.mini) instead of .scaleEffect(0.6)
                        ProgressView()
                            .controlSize(.mini)
                        Text("Scanning…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.bar)
        }
    }

    // MARK: - Colonne liste

    @ViewBuilder
    private var listColumnContent: some View {
        Group {
            if bleScanner.bluetoothState == .unknown {
                // HIG: plain ProgressView, no scaleEffect
                VStack(spacing: 12) {
                    ProgressView()
                    Text("Initializing Bluetooth…")
                        .font(.body).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if bleScanner.bluetoothState != .poweredOn {
                BLEErrorStateView(
                    state: bleScanner.bluetoothState,
                    message: bleScanner.errorMessage
                )
            } else if filteredDevices.isEmpty {
                BLEEmptyStateView(isScanning: bleScanner.isScanning)
            } else {
                #if os(iOS)
                // iOS: NavigationLink in a NavigationStack (no split view)
                List(filteredDevices) { device in
                    NavigationLink {
                        BLEDeviceDetailView(device: device)
                    } label: {
                        BLEDeviceRowView(device: device)
                    }
                }
                .listStyle(.plain)
                #else
                List(filteredDevices, selection: $selectedDevice) { device in
                    BLEDeviceRowView(device: device)
                        .tag(device)
                }
                .listStyle(.inset)
                #endif
            }
        }
    }

    // MARK: - Detail column

    @ViewBuilder
    private var detailColumn: some View {
        if let device = selectedDevice {
            BLEDeviceDetailView(device: device)
        } else {
            // HIG: ContentUnavailableView instead of a custom VStack (macOS 14+ / iOS 17+)
            ContentUnavailableView {
                Label("No Device Selected", systemImage: "antenna.radiowaves.left.and.right")
            } description: {
                Text("Select a device from the list.")
            }
        }
    }

    // MARK: - Bluetooth state badge

    @ViewBuilder
    var bluetoothStateView: some View {
        HStack(spacing: 5) {
            // HIG: color alone must not be the sole information carrier —
            // the text repeats it; the dot is purely decorative (accessibilityHidden)
            Circle()
                .fill(bluetoothStateColor)
                .frame(width: 7, height: 7)
                .accessibilityHidden(true)
            Text(bluetoothStateLabel)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }

    var bluetoothStateColor: Color {
        switch bleScanner.bluetoothState {
        case .poweredOn:  return .green
        case .poweredOff: return .red
        default:          return .orange
        }
    }

    var bluetoothStateLabel: String {
        switch bleScanner.bluetoothState {
        case .poweredOn:   return "Bluetooth On"
        case .poweredOff:  return "Bluetooth Off"
        case .unauthorized: return "Unauthorized"
        default:            return "Bluetooth…"
        }
    }
}

// MARK: - BLE Device Row

struct BLEDeviceRowView: View {
    let device: BLEDevice
    @EnvironmentObject var store: VehicleStore
    @EnvironmentObject var serverClient: NetMapServerClient
    @State private var showPairSheet = false

    var body: some View {
        HStack(spacing: 12) {
            // Manufacturer icon
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(device.signalStrength.color.opacity(0.12))
                    .frame(width: 36, height: 36)
                Image(systemName: deviceIcon)
                    .font(.system(size: 16))
                    .foregroundStyle(device.signalStrength.color)
            }

            // Infos principales
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(device.displayName)
                        .font(.body.weight(.medium))
                        .lineLimit(1)
                    if let v = store.vehicle(for: device.id) {
                        HStack(spacing: 3) {
                            Image(systemName: "car.fill")
                                .font(.caption2)
                            Text(v.name)
                                .font(.caption2.weight(.medium))
                                .lineLimit(1)
                        }
                        .padding(.horizontal, 5).padding(.vertical, 2)
                        .background(Color.blue.opacity(0.10), in: Capsule())
                        .foregroundStyle(.blue)
                    }
                    if device.isTMSDevice {
                        Text("🛡 TMS")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 5).padding(.vertical, 2)
                            .background(Color.orange.opacity(0.15), in: Capsule())
                            .foregroundStyle(.orange)
                    }
                    if device.isConnectable {
                        Image(systemName: "link")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .help("Connectable")
                    }
                }
                // Ligne 2 : pression + temp si TMS, sinon fabricant
                if device.isTMSDevice, let tms = device.tmsData {
                    HStack(spacing: 8) {
                        if let p = tms.pressureBar {
                            Label(String(format: "%.2f bar", p), systemImage: "gauge.open.with.lines.needle.33percent")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.orange)
                        }
                        if let t = tms.temperatureC {
                            Label(String(format: "%.1f°C", t), systemImage: "thermometer.medium")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.blue)
                        }
                        if let model = tms.tireModel {
                            Text(model)
                                .font(.caption2.monospaced())
                                .padding(.horizontal, 4).padding(.vertical, 1)
                                .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 3))
                                .foregroundStyle(.secondary)
                        }
                        if tms.decodingConfidence == .raw {
                            Text("raw bytes")
                                .font(.caption2)
                                .foregroundStyle(.orange.opacity(0.7))
                        }
                    }
                } else {
                    HStack(spacing: 6) {
                        if let mf = device.manufacturerName {
                            Text(mf).font(.caption).foregroundStyle(.secondary)
                            Text("·").foregroundStyle(.tertiary)
                        }
                        if let cat = device.appleDeviceCategory {
                            Text(cat).font(.caption).foregroundStyle(.blue)
                            Text("·").foregroundStyle(.tertiary)
                        }
                        Text(device.id.uuidString.prefix(8) + "…")
                            .font(.caption.monospaced())
                            .foregroundStyle(.tertiary)
                    }
                }
            }

            Spacer()

            // RSSI
            VStack(alignment: .trailing, spacing: 4) {
                SignalBarsView(strength: device.signalStrength)
                Text("\(device.rssi) dBm")
                    .font(.caption.monospaced())
                    .foregroundStyle(device.signalStrength.color)
            }
        }
        .padding(.vertical, 3)
        .contextMenu {
            if let v = store.vehicle(for: device.id) {
                Text("Paired: \(v.name)")
                Divider()
                Button {
                    showPairSheet = true
                } label: {
                    Label("Edit Pairing…", systemImage: "pencil")
                }
                Button(role: .destructive) {
                    store.unpairSensor(id: device.id)
                    let sid = (device.isAirTagDevice || device.airtagData != nil) ? (device.name ?? device.id.uuidString) : device.id.uuidString
                    Task { try? await serverClient.pushUnpairing(stableID: sid) }
                } label: {
                    Label("Remove Pairing", systemImage: "link.badge.minus")
                }
            } else {
                Button {
                    showPairSheet = true
                } label: {
                    Label("Pair with Asset…", systemImage: "shippingbox.fill")
                }
            }
        }
        #if os(iOS)
        .swipeActions(edge: .leading, allowsFullSwipe: false) {
            Button {
                showPairSheet = true
            } label: {
                Label("Pair", systemImage: "car.badge.plus")
            }
            .tint(.blue)
        }
        #endif
        .sheet(isPresented: $showPairSheet) {
            PairToVehicleSheet(device: device)
                .environmentObject(store)
        }
    }

    private var deviceIcon: String {
        if let brand = device.sensorBrand { return brand.systemImage }
        if device.isTMSDevice { return "gauge.open.with.lines.needle.33percent" }
        if let mf = device.manufacturerName {
            switch mf {
            case "Apple":     return "laptopcomputer"
            case "Microsoft": return "pc"
            case "Samsung", "Samsung (Mobile)": return "candybarphone"
            case "Google":    return "globe"
            case "Fitbit", "Garmin", "Polar Electro": return "figure.walk"
            case "Bose", "BOSE", "Jabra": return "headphones"
            case "Tile":      return "tag.fill"
            default: break
            }
        }
        if !device.serviceUUIDs.isEmpty { return "dot.radiowaves.right" }
        return "dot.radiowaves.left.and.right"
    }

    /// Maps a battery percentage to a battery SF Symbol level string (100/75/50/25)
    private func batteryIconLevel(_ pct: Int) -> String {
        switch pct {
        case 75...100: return "100"
        case 50..<75:  return "75"
        case 25..<50:  return "50"
        default:       return "25"
        }
    }
}

// MARK: - Signal Bars

struct SignalBarsView: View {
    let strength: BLEDevice.SignalStrength
    private let totalBars = 4

    var body: some View {
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(0..<totalBars, id: \.self) { i in
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(i < strength.bars ? strength.color : Color.secondary.opacity(0.25))
                    .frame(width: 4, height: CGFloat(5 + i * 3))
            }
        }
        // HIG: purely visual elements must have an accessibility label
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Signal \(strength.label)")
    }
}

// MARK: - BLE Device Detail Panel

struct BLEDeviceDetailView: View {
    let device: BLEDevice
    @EnvironmentObject var store: VehicleStore
    @State private var showPairSheet = false

    var body: some View {
        Group {
        #if os(iOS)
        // ── iOS: Form layout (native look) ──────────────────────────
        Form {
            Section {
                HStack(spacing: 14) {
                    let headerColor: Color = device.sensorBrand?.badgeColor
                        ?? (device.isTMSDevice ? .orange : device.signalStrength.color)
                    let headerIcon: String = device.sensorBrand?.systemImage
                        ?? (device.isTMSDevice ? "gauge.open.with.lines.needle.33percent" : "dot.radiowaves.left.and.right")
                    ZStack {
                        Circle().fill(headerColor.opacity(0.15)).frame(width: 48, height: 48)
                        Image(systemName: headerIcon).font(.system(size: 22)).foregroundStyle(headerColor)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text(device.displayName).font(.headline)
                        HStack(spacing: 5) {
                            if let mf = device.manufacturerName {
                                Text(mf).font(.caption)
                                    .padding(.horizontal, 7).padding(.vertical, 2)
                                    .background(headerColor.opacity(0.10), in: Capsule())
                                    .foregroundStyle(headerColor)
                            }
                            if let cat = device.appleDeviceCategory {
                                Text(cat).font(.caption)
                                    .padding(.horizontal, 7).padding(.vertical, 2)
                                    .background(Color.blue.opacity(0.12), in: Capsule())
                                    .foregroundStyle(.blue)
                            }
                        }
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 2) {
                        SignalBarsView(strength: device.signalStrength)
                        Text("\(device.rssi) dBm").font(.caption2.monospaced()).foregroundStyle(.secondary)
                    }
                }
                .listRowBackground(Color.clear)
            }
            Section {
                VehiclePairingCard(device: device, showSheet: $showPairSheet).environmentObject(store)
            }
            if device.isTMSDevice, let tms = device.tmsData    { TMSSectionView(tms: tms) }
            if let c = device.stihlConnectorData               { StihlConnectorSectionView(data: c) }
            if let b = device.stihlBatteryData                 { StihlBatterySectionView(data: b) }
            if let e = device.elaData                          { ELASectionView(data: e) }
            if let a = device.airtagData                       { AirTagSectionView(data: a, estimatedDistance: device.estimatedDistance) }
            BLEInfoSection(title: "Signal") {
                BLEInfoRow(label: "Quality", value: device.signalStrength.label)
                if let tx = device.txPowerLevel { BLEInfoRow(label: "TX Power", value: "\(tx) dBm") }
                if let d = device.estimatedDistance { BLEInfoRow(label: "Distance ~", value: String(format: "%.1f m", d)) }
                HStack {
                    Text("Strength").font(.caption).foregroundStyle(.secondary).frame(width: 80, alignment: .leading)
                    SignalBarsView(strength: device.signalStrength); Spacer()
                }
            }
            BLEInfoSection(title: "Identification") {
                BLEInfoRow(label: "UUID", value: device.id.uuidString)
                BLEInfoRow(label: "Connectable", value: device.isConnectable ? "Yes" : "No")
                if let data = device.manufacturerData {
                    BLEInfoRow(label: "Mfr. Data", value: data.map { String(format: "%02X", $0) }.joined(separator: " "))
                }
            }
            if !device.serviceUUIDs.isEmpty {
                BLEInfoSection(title: "Services GATT") {
                    ForEach(device.serviceUUIDs, id: \.self) { uuid in
                        HStack(spacing: 6) {
                            Image(systemName: "square.stack.3d.up.fill").font(.caption).foregroundStyle(.blue)
                            Text(uuid).font(.caption.monospaced()).foregroundStyle(.primary).textSelection(.enabled)
                        }
                    }
                }
            }
            BLEInfoSection(title: "Activity") {
                BLEInfoRow(label: "Packets", value: "\(device.seenCount)")
                BLEInfoRow(label: "Last seen", value: device.lastSeen.formatted(.relative(presentation: .named)))
            }
            Section {
                Button { copyToClipboard(device.id.uuidString) } label: {
                    Label("Copy UUID", systemImage: "doc.on.clipboard").frame(maxWidth: .infinity)
                }
            }
        }
        #else
        // ── macOS: sidebar-style scroll layout ────────────────────
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 14) {
                    let headerColor: Color = device.sensorBrand?.badgeColor
                        ?? (device.isTMSDevice ? .orange : device.signalStrength.color)
                    let headerIcon: String = device.sensorBrand?.systemImage
                        ?? (device.isTMSDevice ? "gauge.open.with.lines.needle.33percent" : "dot.radiowaves.left.and.right")
                    ZStack {
                        Circle().fill(headerColor.opacity(0.15)).frame(width: 48, height: 48)
                        Image(systemName: headerIcon).font(.system(size: 22)).foregroundStyle(headerColor)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text(device.displayName).font(.headline)
                        HStack(spacing: 5) {
                            if let mf = device.manufacturerName {
                                Text(mf).font(.caption)
                                    .padding(.horizontal, 7).padding(.vertical, 2)
                                    .background(headerColor.opacity(0.10), in: Capsule()).foregroundStyle(headerColor)
                            }
                            if let cat = device.appleDeviceCategory {
                                Text(cat).font(.caption)
                                    .padding(.horizontal, 7).padding(.vertical, 2)
                                    .background(Color.blue.opacity(0.12), in: Capsule()).foregroundStyle(.blue)
                            }
                        }
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 2) {
                        SignalBarsView(strength: device.signalStrength)
                        Text("\(device.rssi) dBm").font(.caption2.monospaced()).foregroundStyle(.secondary)
                    }
                }
                .padding(.top, 8)
                VehiclePairingCard(device: device, showSheet: $showPairSheet).environmentObject(store)
                if device.isTMSDevice, let tms = device.tmsData    { TMSSectionView(tms: tms); Divider().padding(.vertical, 4) }
                if let c = device.stihlConnectorData               { StihlConnectorSectionView(data: c); Divider().padding(.vertical, 4) }
                if let b = device.stihlBatteryData                 { StihlBatterySectionView(data: b); Divider().padding(.vertical, 4) }
                if let e = device.elaData                          { ELASectionView(data: e); Divider().padding(.vertical, 4) }
                if let a = device.airtagData                       { AirTagSectionView(data: a, estimatedDistance: device.estimatedDistance); Divider().padding(.vertical, 4) }
                BLEInfoSection(title: "Signal") {
                    BLEInfoRow(label: "Quality", value: device.signalStrength.label)
                    if let tx = device.txPowerLevel { BLEInfoRow(label: "TX Power", value: "\(tx) dBm") }
                    if let d = device.estimatedDistance { BLEInfoRow(label: "Distance ~", value: String(format: "%.1f m", d)) }
                    HStack {
                        Text("Strength").font(.caption).foregroundStyle(.secondary).frame(width: 80, alignment: .leading)
                        SignalBarsView(strength: device.signalStrength); Spacer()
                    }
                }
                Divider().padding(.vertical, 4)
                BLEInfoSection(title: "Identification") {
                    BLEInfoRow(label: "UUID", value: device.id.uuidString)
                    BLEInfoRow(label: "Connectable", value: device.isConnectable ? "Yes" : "No")
                    if let data = device.manufacturerData {
                        BLEInfoRow(label: "Mfr. Data", value: data.map { String(format: "%02X", $0) }.joined(separator: " "))
                    }
                }
                Divider().padding(.vertical, 4)
                if !device.serviceUUIDs.isEmpty {
                    BLEInfoSection(title: "Services GATT") {
                        ForEach(device.serviceUUIDs, id: \.self) { uuid in
                            HStack(spacing: 6) {
                                Image(systemName: "square.stack.3d.up.fill").font(.caption).foregroundStyle(.blue)
                                Text(uuid).font(.caption.monospaced()).foregroundStyle(.primary).textSelection(.enabled)
                            }
                        }
                    }
                    Divider().padding(.vertical, 4)
                }
                BLEInfoSection(title: "Activity") {
                    BLEInfoRow(label: "Packets", value: "\(device.seenCount)")
                    BLEInfoRow(label: "Last seen", value: device.lastSeen.formatted(.relative(presentation: .named)))
                }
                Divider().padding(.vertical, 4)
                HStack {
                    Spacer()
                    Button { copyToClipboard(device.id.uuidString) } label: {
                        Label("Copy UUID", systemImage: "doc.on.clipboard").font(.caption)
                    }
                    .buttonStyle(.bordered).help("Copy UUID to clipboard")
                    Spacer()
                }
                .padding(.bottom, 16)
            }
            .padding(.horizontal, 16)
        }
        .background(Color.platformWindowBackground)
        #endif
        } // Group
        .navigationTitle(device.displayName)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .sheet(isPresented: $showPairSheet) {
            PairToVehicleSheet(device: device)
                .environmentObject(store)
        }
    }
}

// MARK: - Asset Pairing Card

struct VehiclePairingCard: View {
    @EnvironmentObject var store: VehicleStore
    let device: BLEDevice
    @Binding var showSheet: Bool

    private var paired: VehicleConfig? { store.vehicle(for: device.id) }
    private var wheelPos: WheelPosition? { store.wheelPosition(for: device.id) }
    private var pairedAssetIcon: String {
        paired.map { store.assetType(for: $0).systemImage } ?? "shippingbox.fill"
    }

    var body: some View {
        Button {
            showSheet = true
        } label: {
            HStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color.blue.opacity(0.10))
                        .frame(width: 44, height: 44)
                    Image(systemName: pairedAssetIcon)
                        .font(.system(size: 20))
                        .foregroundStyle(.blue)
                }
                VStack(alignment: .leading, spacing: 3) {
                    if let v = paired {
                        Text(v.name)
                            .font(.body.weight(.semibold))
                            .foregroundStyle(.primary)
                        if let pos = wheelPos {
                            Label(pos.label, systemImage: "arrow.triangle.turn.up.right.circle")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            Text(v.subtitle)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        Text("Pair with an Asset")
                            .font(.body.weight(.semibold))
                            .foregroundStyle(.blue)
                        Text("Tap to link this sensor to an asset")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if paired != nil {
                    Text("Change")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.blue)
                } else {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.blue.opacity(0.4))
                }
            }
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.blue.opacity(0.06))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .strokeBorder(Color.blue.opacity(0.18), lineWidth: 1)
                    )
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Michelin TMS Section

struct TMSSectionView: View {
    let tms: TMSData

    var body: some View {
        BLEInfoSection(title: "Michelin TMS") {

            // Type de trame
            BLEInfoRow(label: "Frame", value: tms.frameTypeName)

            // Pressure (frames C, D, 5, 7)
            if let bar = tms.pressureBar {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Pressure")
                            .font(.caption).foregroundStyle(.secondary)
                            .frame(width: 90, alignment: .leading)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(String(format: "%.2f bar", bar))
                                .font(.body.weight(.semibold)).foregroundStyle(.orange)
                            HStack(spacing: 8) {
                                if let kpa = tms.pressurekPa {
                                    Text(String(format: "%.0f kPa", kpa))
                                        .font(.caption2).foregroundStyle(.secondary)
                                }
                                if let psi = tms.pressurePSI {
                                    Text(String(format: "%.1f PSI", psi))
                                        .font(.caption2).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    PressureGaugeView(pressureBar: bar, maxBar: 4.0)
                }
            }

            // Temperature
            if let t = tms.temperatureC {
                BLEInfoRow(
                    label: "Temperature",
                    value: String(format: "%.0f °C  (%.0f °F)", t, t * 9/5 + 32)
                )
            }

            // Batterie (tension)
            if let v = tms.vbattVolts {
                HStack {
                    Text("Battery")
                        .font(.caption).foregroundStyle(.secondary)
                        .frame(width: 90, alignment: .leading)
                    HStack(spacing: 6) {
                        Image(systemName: batteryIcon(tms.vbattPct ?? 0))
                            .foregroundStyle((tms.vbattPct ?? 100) < 20 ? .red : .secondary)
                        Text(String(format: "%.2f V", v))
                            .font(.caption.monospaced())
                        if let pct = tms.vbattPct {
                            Text("(≈\(pct) %)")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                }
            }

            // Tire model (frames A, B, C)
            if let model = tms.tireModel {
                BLEInfoRow(label: "Model", value: model)
            }

            // Tire Type ID (frames 5, 6)
            if let tid = tms.tireTypeID {
                BLEInfoRow(label: "TireTypeID", value: String(format: "0x%08X", tid))
            }

            // 3 LSB MAC (frame D, 7)
            if let mac = tms.macLSB {
                BLEInfoRow(label: "MAC LSB", value: mac)
            }

            // État machine
            if let s = tms.state {
                BLEInfoRow(label: "State", value: stateLabel(s))
            }

            // Frame counter
            if let fc = tms.frameCounter {
                BLEInfoRow(label: "Counter", value: "\(fc)  (0x\(String(format: "%08X", fc)))")
            }

            // Firmware
            if let fw = tms.firmwareVersion {
                BLEInfoRow(label: "Firmware", value: "v\(fw)")
            }

            Divider().padding(.vertical, 2)

            // Raw bytes
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 5) {
                    confidenceBadge
                    Spacer()
                    Button {
                        copyToClipboard(tms.hexDump)
                    } label: {
                        Image(systemName: "doc.on.clipboard").font(.caption2)
                    }
                    .buttonStyle(.plain)
                    .help("Copy raw bytes")
                }
                Text(tms.annotatedHex)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .lineLimit(4)
                Text("[CID] [beacon] {frameType} T:temp V:vbatt payload…")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    @ViewBuilder
    private var confidenceBadge: some View {
        switch tms.decodingConfidence {
        case .validated:
            Label("Official Michelin format", systemImage: "checkmark.seal.fill")
                .font(.caption2).foregroundStyle(.green)
        case .likely:
            Label("Probable decoding", systemImage: "exclamationmark.triangle")
                .font(.caption2).foregroundStyle(.orange)
        case .raw:
            Label("Not decoded", systemImage: "questionmark.circle")
                .font(.caption2).foregroundStyle(.red)
        }
    }

    private func batteryIcon(_ pct: Int) -> String {
        switch pct {
        case 75...100: return "battery.100"
        case 50..<75:  return "battery.75"
        case 25..<50:  return "battery.50"
        default:       return "battery.25"
        }
    }

    private func stateLabel(_ s: Int) -> String {
        switch s {
        case 0: return "0 — Idle"
        case 1: return "1 — Active"
        case 2: return "2 — Rolling"
        case 3: return "3 — Alarm"
        case 4: return "4 — Inflation (bumpAir)"
        default: return "\(s)"
        }
    }
}

// MARK: - STIHL Smart Connector Section

struct StihlConnectorSectionView: View {
    let data: StihlConnectorData

    var body: some View {
        BLEInfoSection(title: "STIHL Smart Connector") {
            BLEInfoRow(label: "Product",    value: data.productName)
            BLEInfoRow(label: "MAC",         value: data.macAddress)
            BLEInfoRow(label: "Total time",  value: formatDuration(data.counterSeconds))
            BLEInfoRow(label: "HW Version", value: data.hwVersion)
            BLEInfoRow(label: "SW Version", value: data.swVersion)
            BLEInfoRow(label: "TX Power", value: "\(data.txPowerDBm) dBm")

            // Battery
            HStack {
                Text("Battery")
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(width: 90, alignment: .leading)
                HStack(spacing: 6) {
                    Image(systemName: batteryIcon(data.batteryPercent))
                        .foregroundStyle(data.batteryPercent < 20 ? .red : .secondary)
                    Text(String(format: "%.2f V  (≈%d %%)", data.batteryVolts, data.batteryPercent))
                        .font(.caption.monospaced())
                }
                Spacer()
            }

            // Temperature
            if let temp = data.temperatureC {
                let tempD = Double(temp)
                BLEInfoRow(label: "Temperature",
                           value: String(format: "%.0f °C  (%.0f °F)", tempD, tempD * 9/5 + 32))
            } else {
                BLEInfoRow(label: "Temperature", value: "Not implemented")
            }

            // Status flags
            HStack {
                Text("Status")
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(width: 90, alignment: .leading)
                VStack(alignment: .leading, spacing: 3) {
                    Label(data.isConnectable ? "Connectable" : "Not connectable",
                          systemImage: data.isConnectable ? "link" : "link.badge.plus")
                        .font(.caption2)
                        .foregroundStyle(data.isConnectable ? .green : .secondary)
                    if data.hasSoftwareError {
                        Label("Software error", systemImage: "exclamationmark.triangle.fill")
                            .font(.caption2).foregroundStyle(.red)
                    }
                    if data.hasHardwareError {
                        Label("Hardware error", systemImage: "xmark.octagon.fill")
                            .font(.caption2).foregroundStyle(.red)
                    }
                    if !data.hasSoftwareError && !data.hasHardwareError {
                        Label("No errors", systemImage: "checkmark.circle.fill")
                            .font(.caption2).foregroundStyle(.green)
                    }
                }
                Spacer()
            }

            Divider().padding(.vertical, 2)

            // Raw hex
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Label("Raw bytes", systemImage: "cpu")
                        .font(.caption2).foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        copyToClipboard(data.hexDump)
                    } label: {
                        Image(systemName: "doc.on.clipboard").font(.caption2)
                    }
                    .buttonStyle(.plain)
                    .help("Copy raw bytes")
                }
                Text(data.hexDump)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .lineLimit(4)
            }
        }
    }

    private func batteryIcon(_ pct: Int) -> String {
        switch pct {
        case 75...100: return "battery.100"
        case 50..<75:  return "battery.75"
        case 25..<50:  return "battery.50"
        default:       return "battery.25"
        }
    }
}

// MARK: - STIHL Smart Battery Section

struct StihlBatterySectionView: View {
    let data: StihlBatteryData

    var body: some View {
        BLEInfoSection(title: "STIHL Smart Battery") {
            BLEInfoRow(label: "Serial", value: data.serialNumber)

            // Charge
            HStack {
                Text("Charge")
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(width: 90, alignment: .leading)
                HStack(spacing: 6) {
                    Image(systemName: batteryIcon(Int(data.chargePercent)))
                        .foregroundStyle(data.chargePercent < 20 ? .red : .yellow)
                    Text("\(data.chargePercent) %")
                        .font(.body.weight(.semibold)).foregroundStyle(.yellow)
                }
                Spacer()
            }

            // Health
            HStack {
                Text("Health")
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(width: 90, alignment: .leading)
                HStack(spacing: 6) {
                    Image(systemName: "heart.fill")
                        .foregroundStyle(data.healthPercent < 50 ? Color.red : Color.green)
                    Text("\(data.healthPercent) %")
                        .font(.caption.monospaced())
                }
                Spacer()
            }

            BLEInfoRow(label: "State",            value: data.stateLabel)
            BLEInfoRow(label: "Cycles",            value: "\(data.chargingCycles)")
            BLEInfoRow(label: "Discharge time",    value: formatDuration(data.totalDischargeTime))

            Divider().padding(.vertical, 2)

            // Raw hex
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Label("Raw bytes", systemImage: "cpu")
                        .font(.caption2).foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        copyToClipboard(data.hexDump)
                    } label: {
                        Image(systemName: "doc.on.clipboard").font(.caption2)
                    }
                    .buttonStyle(.plain)
                    .help("Copy raw bytes")
                }
                Text(data.hexDump)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .lineLimit(4)
            }
        }
    }

    private func batteryIcon(_ pct: Int) -> String {
        switch pct {
        case 75...100: return "battery.100"
        case 50..<75:  return "battery.75"
        case 25..<50:  return "battery.50"
        default:       return "battery.25"
        }
    }
}

// MARK: - ELA Innovation Section

struct ELASectionView: View {
    let data: ELAData

    var body: some View {
        BLEInfoSection(title: "ELA Innovation") {
            // Product variant
            HStack {
                Text("Product")
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(width: 90, alignment: .leading)
                HStack(spacing: 6) {
                    Image(systemName: data.productVariant.systemImage)
                        .foregroundStyle(.cyan)
                    Text(data.productVariant.displayName)
                        .font(.caption.weight(.semibold)).foregroundStyle(.cyan)
                }
                Spacer()
            }

            BLEInfoRow(label: "Data Type", value: String(format: "0x%02X", data.dataType))

            // Payload bytes
            if !data.payload.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Payload")
                        .font(.caption).foregroundStyle(.secondary)
                    Text(data.payload.map { String(format: "%02X", $0) }.joined(separator: " "))
                        .font(.caption.monospaced())
                        .foregroundStyle(.primary)
                        .textSelection(.enabled)
                        .lineLimit(3)
                }
            }

            Divider().padding(.vertical, 2)

            // Raw hex
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Label("Raw bytes", systemImage: "cpu")
                        .font(.caption2).foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        copyToClipboard(data.hexDump)
                    } label: {
                        Image(systemName: "doc.on.clipboard").font(.caption2)
                    }
                    .buttonStyle(.plain)
                    .help("Copy raw bytes")
                }
                Text(data.hexDump)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .lineLimit(4)
            }
        }
    }
}

// MARK: - AirTag / FindMy Section

struct AirTagSectionView: View {
    let data: AirTagData
    let estimatedDistance: Double?

    var body: some View {
        BLEInfoSection(title: "AirTag / FindMy") {

            // Battery level
            HStack {
                Text("Battery")
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(width: 90, alignment: .leading)
                HStack(spacing: 6) {
                    Image(systemName: data.batteryLevel.systemImage)
                        .foregroundStyle(data.batteryLevel.color)
                    Text(data.batteryLevel.label)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(data.batteryLevel.color)
                    Text("(~\(data.batteryLevel.approximatePercent)%)")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
            }

            // Separated from owner
            HStack {
                Text("Status")
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(width: 90, alignment: .leading)
                HStack(spacing: 6) {
                    if data.isSeparated {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Text("Separated from owner")
                            .font(.caption.weight(.semibold)).foregroundStyle(.orange)
                    } else {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        Text("Near owner")
                            .font(.caption.weight(.semibold)).foregroundStyle(.green)
                    }
                }
                Spacer()
            }

            // Distance estimate
            if let d = estimatedDistance {
                HStack {
                    Text("Distance ~")
                        .font(.caption).foregroundStyle(.secondary)
                        .frame(width: 90, alignment: .leading)
                    Text(d < 1 ? String(format: "%.0f cm", d * 100)
                               : String(format: "%.1f m", d))
                        .font(.caption.weight(.semibold))
                    Text("(RSSI estimate, ±50%)")
                        .font(.caption2).foregroundStyle(.secondary)
                    Spacer()
                }
            }

            Divider().padding(.vertical, 2)

            // Rotating public key prefix
            if !data.publicKeyPrefix.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Label("Key prefix (rotates ~15 min)", systemImage: "key.rotate")
                            .font(.caption2).foregroundStyle(.secondary)
                        Spacer()
                    }
                    Text(data.publicKeyPrefix.map { String(format: "%02X", $0) }.joined(separator: " "))
                        .font(.caption.monospaced())
                        .foregroundStyle(.primary)
                        .textSelection(.enabled)
                }
            }

            Divider().padding(.vertical, 2)

            // Raw hex
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Label("Raw bytes", systemImage: "cpu")
                        .font(.caption2).foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        copyToClipboard(data.hexDump)
                    } label: {
                        Image(systemName: "doc.on.clipboard").font(.caption2)
                    }
                    .buttonStyle(.plain)
                    .help("Copy raw bytes")
                }
                Text(data.hexDump)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .lineLimit(4)
            }
        }
    }
}

// MARK: - Pressure Gauge

struct PressureGaugeView: View {
    let pressureBar: Double
    let maxBar: Double

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color.secondary.opacity(0.15))
                RoundedRectangle(cornerRadius: 3)
                    .fill(gaugeColor)
                    .frame(width: geo.size.width * min(pressureBar / maxBar, 1.0))
            }
        }
        .frame(height: 6)
    }

    private var gaugeColor: Color {
        switch pressureBar {
        case 2.0...3.5: return .green
        case 1.5..<2.0: return .orange
        case 3.5...4.5: return .orange
        default:        return .red
        }
    }
}

// MARK: - Sub-components

struct BLEInfoSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content
    var body: some View {
        #if os(iOS)
        Section(title) { content }
        #else
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased())
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .tracking(1.2)
            VStack(alignment: .leading, spacing: 6) { content }
                .padding(10)
                .background(Color.platformControlBackground, in: RoundedRectangle(cornerRadius: 8))
        }
        #endif
    }
}

struct BLEInfoRow: View {
    let label: String
    let value: String
    var body: some View {
        #if os(iOS)
        LabeledContent(label) {
            Text(value)
                .font(.caption.monospaced())
                .textSelection(.enabled)
                .multilineTextAlignment(.trailing)
        }
        #else
        HStack(alignment: .top) {
            Text(label)
                .font(.caption).foregroundStyle(.secondary)
                .frame(width: 90, alignment: .leading)
            Text(value)
                .font(.caption.monospaced())
                .foregroundStyle(.primary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        #endif
    }
}

// MARK: - Empty States

struct BLEEmptyStateView: View {
    let isScanning: Bool
    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "antenna.radiowaves.left.and.right.slash")
                .font(.system(size: 48)).foregroundStyle(.secondary)
            Text(isScanning ? "Searching for BLE devices…" : "No devices found")
                .font(.title3.weight(.medium))
            Text(isScanning
                 ? "Nearby Bluetooth devices will appear here."
                 : "Start a scan to detect nearby BLE devices.")
                .font(.body).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }
}

struct BLEErrorStateView: View {
    let state: CBManagerState
    let message: String?
    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "bluetooth.slash")
                .font(.system(size: 48)).foregroundStyle(.red)
            Text("Bluetooth Unavailable")
                .font(.title3.weight(.medium))
            if let msg = message {
                Text(msg).font(.body).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            if state == .poweredOff {
                Button("Open Bluetooth Settings") {
                    #if os(macOS)
                    NSWorkspace.shared.open(
                        URL(string: "x-apple.systempreferences:com.apple.preference.bluetooth")!
                    )
                    #else
                    UIApplication.shared.open(URL(string: UIApplication.openSettingsURLString)!)
                    #endif
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }
}
// MARK: - Pair Sensor to Vehicle Sheet

struct PairToVehicleSheet: View {
    @EnvironmentObject var store: VehicleStore
    @EnvironmentObject var serverClient: NetMapServerClient
    @Environment(\.dismiss) var dismiss

    let device: BLEDevice

    @State private var selectedVehicleID: UUID?
    @State private var customLabel: String = ""
    @State private var wheelPosition: WheelPosition = .frontLeft
    @State private var targetPressureText: String = "2.2"

    private var detectedBrand: SensorBrandTag {
        if device.isTMSDevice { return .michelin }
        if device.stihlConnectorData != nil || device.stihlBatteryData != nil { return .stihl }
        if device.elaData != nil { return .ela }
        if device.manufacturerName == "Apple" && device.appleDeviceCategory == "FindMy" { return .airtag }
        return .other
    }

    private var currentVehicle: VehicleConfig? { store.vehicle(for: device.id) }
    private var needsWheelMapping: Bool { detectedBrand.supportsTMSMapping }

    /// Only assets whose type allows the detected sensor brand
    private var compatibleAssets: [VehicleConfig] {
        store.vehicles.filter { $0.allowedBrands(from: store.assetTypes).contains(detectedBrand) }
    }

    /// Positions already assigned to OTHER sensors on the selected vehicle
    private var takenPositions: Set<WheelPosition> {
        guard let vid = selectedVehicleID,
              let v = store.vehicles.first(where: { $0.id == vid }) else { return [] }
        return Set(v.pairedSensors.filter { $0.id != device.id }.compactMap { $0.wheelPosition })
    }

    private var availablePositions: [WheelPosition] {
        WheelPosition.allCases.filter { !takenPositions.contains($0) }
    }

    var body: some View {
        NavigationStack {
            Form {
                // ── Sensor header (lecture seule) ────────────────────
                Section {
                    HStack(spacing: 14) {
                        ZStack {
                            Circle()
                                .fill(detectedBrand.badgeColor.opacity(0.15))
                                .frame(width: 44, height: 44)
                            Image(systemName: detectedBrand.systemImage)
                                .font(.system(size: 20))
                                .foregroundStyle(detectedBrand.badgeColor)
                        }
                        VStack(alignment: .leading, spacing: 3) {
                            Text(device.displayName)
                                .font(.headline)
                            HStack(spacing: 5) {
                                Text(detectedBrand.displayName)
                                    .foregroundStyle(detectedBrand.badgeColor)
                                Text("·").foregroundStyle(.tertiary)
                                Text(device.id.uuidString.prefix(8) + "…")
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(.tertiary)
                            }
                            .font(.subheadline)
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 2) {
                            SignalBarsView(strength: device.signalStrength)
                            Text("\(device.rssi) dBm")
                                .font(.caption2.monospaced())
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 4)
                }

                // ── Asset selection (filtered by compatibility) ──────
                Section {
                    if compatibleAssets.isEmpty {
                        VStack(alignment: .center, spacing: 10) {
                            Image(systemName: "shippingbox.fill")
                                .font(.title2).foregroundStyle(.secondary)
                            Text("No compatible asset")
                                .font(.subheadline.weight(.medium))
                            Text("\(detectedBrand.displayName) sensors can only be paired with assets that support this brand.")
                                .font(.caption).foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                    } else {
                        ForEach(compatibleAssets) { v in
                            let assetType = v.resolvedAssetType(from: store.assetTypes)
                            HStack(spacing: 12) {
                                ZStack {
                                    Circle()
                                        .fill(selectedVehicleID == v.id
                                              ? Color.blue.opacity(0.12)
                                              : Color.secondary.opacity(0.08))
                                        .frame(width: 36, height: 36)
                                    Image(systemName: assetType.systemImage)
                                        .font(.system(size: 15))
                                        .foregroundStyle(selectedVehicleID == v.id ? .blue : .secondary)
                                }
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(v.name)
                                        .font(.body)
                                        .foregroundStyle(.primary)
                                    Text(v.subtitle)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                if selectedVehicleID == v.id {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(.blue)
                                        .font(.title3)
                                }
                            }
                            .contentShape(Rectangle())
                            .onTapGesture { selectVehicle(v) }
                        }
                    }
                } header: {
                    Text("Choose an Asset")
                } footer: {
                    if !compatibleAssets.isEmpty && !needsWheelMapping {
                        Text("Tap an asset to pair immediately.")
                    }
                }

                // ── Position de roue TMS (apparaît après sélection) ──
                if needsWheelMapping && selectedVehicleID != nil {
                    Section {
                        Picker("Wheel Position", selection: $wheelPosition) {
                            ForEach(availablePositions) { pos in
                                Text(pos.label).tag(pos)
                            }
                        }
                        #if os(iOS)
                        .pickerStyle(.segmented)
                        #else
                        .pickerStyle(.menu)
                        #endif
                        LabeledContent("Target Pressure") {
                            HStack {
                                TextField("bar", text: $targetPressureText)
                                    .multilineTextAlignment(.trailing)
                                    .frame(width: 60)
                                    #if os(iOS)
                                    .keyboardType(.decimalPad)
                                    #endif
                                Text("bar").foregroundStyle(.secondary)
                            }
                        }
                    } header: {
                        Text("Wheel Position")
                    } footer: {
                        Text("Assign which wheel this TMS sensor monitors.")
                    }
                }

                // ── Label personnalisé (optionnel) ───────────────────
                Section("Label (optional)") {
                    TextField("Custom name for this sensor", text: $customLabel)
                }

                // ── Supprimer le pairing ─────────────────────────────
                if currentVehicle != nil {
                    Section {
                        Button(role: .destructive) {
                            store.unpairSensor(id: device.id)
                            let sid = (device.isAirTagDevice || device.airtagData != nil) ? (device.name ?? device.id.uuidString) : device.id.uuidString
                            Task { try? await serverClient.pushUnpairing(stableID: sid) }
                            dismiss()
                        } label: {
                            HStack {
                                Spacer()
                                Label("Remove Pairing", systemImage: "link.badge.minus")
                                Spacer()
                            }
                        }
                    }
                }
            }
            .navigationTitle("Pair Sensor")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                // Pour les TMS : Confirm après sélection véhicule + position roue
                if needsWheelMapping {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Confirm") {
                            guard let vid = selectedVehicleID else { return }
                            pairTo(vehicleID: vid)
                        }
                        .disabled(selectedVehicleID == nil)
                    }
                }
            }
        }
        .onAppear { prefill() }
    }

    // MARK: - Helpers

    /// Non-TMS : association immédiate au tap. TMS : sélectionne le véhicule puis Confirm.
    private func selectVehicle(_ v: VehicleConfig) {
        selectedVehicleID = v.id
        // Auto-select first free position when changing vehicle
        if needsWheelMapping {
            let taken = Set(v.pairedSensors.filter { $0.id != device.id }.compactMap { $0.wheelPosition })
            let free  = WheelPosition.allCases.filter { !taken.contains($0) }
            if let first = free.first, taken.contains(wheelPosition) {
                wheelPosition = first
            }
        } else {
            pairTo(vehicleID: v.id)
        }
    }

    private func pairTo(vehicleID: UUID) {
        // For non-TMS sensors, fall back to the BLE device name if no custom label was entered
        let resolvedLabel: String? = {
            if !customLabel.isEmpty { return customLabel }
            if !needsWheelMapping {
                let n = device.displayName
                return (n == "Unknown" || n.isEmpty) ? nil : n
            }
            return nil
        }()
        let hardwareKey: String? = {
            if let sc = device.stihlConnectorData { return sc.macAddress }
            if let sb = device.stihlBatteryData   { return "STIHLBATT-\(sb.serialNumber)" }
            if detectedBrand == .airtag {
                // On iOS, peripheral.name is nil — fall back to the user label
                return device.name ?? (customLabel.isEmpty ? nil : customLabel)
            }
            return nil
        }()
        let sensor = PairedSensor(
            id: device.id,
            macAddress: hardwareKey,
            brand: detectedBrand,
            customLabel: resolvedLabel,
            wheelPosition: needsWheelMapping ? wheelPosition : nil,
            targetPressureBar: needsWheelMapping ? (Double(targetPressureText) ?? 2.2) : nil,
            pairedAt: Date()
        )
        store.pairSensor(sensor, to: vehicleID)

        // Push pairing to server immediately (no BLE readings required).
        if let vehicle = store.vehicles.first(where: { $0.id == vehicleID }),
           !serverClient.host.isEmpty {
            let vid = vehicle.serverVehicleID?.uuidString ?? vehicle.id.uuidString
            let sensorID: String = {
                if let sc = device.stihlConnectorData {
                    return "STIHL-" + sc.macAddress.replacingOccurrences(of: ":", with: "")
                }
                if let sb = device.stihlBatteryData {
                    return "STIHLBATT-\(sb.serialNumber)"
                }
                // AirTag: use stable name as sensorID (matches SensorPushService)
                if detectedBrand == .airtag, let name = hardwareKey, !name.isEmpty {
                    return name
                }
                return device.stableSensorID
            }()
            let payload = NetMapServerClient.PairingPayload(
                sensorID:          sensorID,
                vehicleID:         vid,
                vehicleName:       vehicle.name,
                assetTypeID:       vehicle.assetTypeID,
                brand:             detectedBrand.rawValue,
                wheelPosition:     sensor.wheelPosition?.rawValue,
                targetPressureBar: sensor.targetPressureBar,
                sensorName:        sensor.customLabel ?? (device.displayName == "Unknown" ? nil : device.displayName)
            )
            Task { try? await serverClient.pushPairing(payload) }
        }

        dismiss()
    }

    private func prefill() {
        if let current = currentVehicle,
           let existing = current.pairedSensors.first(where: { $0.id == device.id }) {
            selectedVehicleID  = current.id
            // For non-TMS sensors with no saved label, pre-fill with device name
            let fallback = (!needsWheelMapping && (existing.customLabel == nil || existing.customLabel!.isEmpty))
                ? (device.displayName == "Unknown" ? "" : device.displayName)
                : ""
            customLabel        = existing.customLabel ?? fallback
            wheelPosition      = existing.wheelPosition ?? .frontLeft
            targetPressureText = existing.targetPressureBar.map { String(format: "%.1f", $0) } ?? "2.2"
        }
    }
}