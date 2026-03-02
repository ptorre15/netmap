import SwiftUI

// MARK: - Vehicle Detail View

struct VehicleDetailView: View {
    @EnvironmentObject var store: VehicleStore
    @EnvironmentObject var bleScanner: BLEScanner

    let vehicleID: UUID

    @State private var showEditSheet  = false
    @State private var showPairSheet  = false
    @State private var editSensor: PairedSensor?
    @State private var detailSensor: PairedSensor?

    private var vehicle: VehicleConfig? {
        store.vehicles.first { $0.id == vehicleID }
    }

    var body: some View {
        Group {
            if let v = vehicle {
                content(v)
            } else {
                ContentUnavailableView("Asset not found", systemImage: "shippingbox.fill")
            }
        }
        .navigationTitle(vehicle?.name ?? "Asset")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.large)
        #endif
        .toolbar { toolbarItems }
        .sheet(isPresented: $showEditSheet) {
            if let v = vehicle {
                VehicleEditSheet(config: v)
                    .environmentObject(store)
                    .environmentObject(bleScanner)
            }
        }
        .sheet(isPresented: $showPairSheet) {
            if let v = vehicle {
                PairSensorSheet(vehicleID: v.id)
                    .environmentObject(store)
                    .environmentObject(bleScanner)
            }
        }
        .sheet(item: $editSensor) { sensor in
            if let v = vehicle {
                EditPairedSensorSheet(vehicleID: v.id, sensor: sensor)
                    .environmentObject(store)
                    .environmentObject(bleScanner)
            }
        }
        .sheet(item: $detailSensor) { sensor in
            if let v = vehicle {
                NavigationStack {
                    SensorDetailView(sensor: sensor, vehicleID: v.id)
                        .environmentObject(store)
                        .environmentObject(bleScanner)
                        .toolbar {
                            ToolbarItem(placement: .confirmationAction) {
                                Button("Done") { detailSensor = nil }
                            }
                        }
                }
            }
        }
    }

    // MARK: - Main content

    @ViewBuilder
    private func content(_ v: VehicleConfig) -> some View {
        List {
            // ── Identity section ──────────────────────────────────────
            let assetType = v.resolvedAssetType(from: store.assetTypes)
            Section(assetType.name) {
                if v.assetTypeID == AssetType.vehicle.id {
                    vehicleInfoRow("Brand",  value: v.brand,                icon: "building.2")
                    vehicleInfoRow("Model",  value: v.model,                icon: "car.rear.and.collision.road.lane")
                    vehicleInfoRow("Year",   value: v.year.map { String($0) }, icon: "calendar")
                    vehicleInfoRow("VIN",    value: v.vin,                  icon: "barcode")
                    vehicleInfoRow("Plate",  value: v.vrn,                  icon: "licenseplate")
                } else if v.assetTypeID == AssetType.tool.id {
                    vehicleInfoRow("Tool Type",     value: v.toolType,      icon: "wrench.and.screwdriver.fill")
                    vehicleInfoRow("Serial Number", value: v.serialNumber,  icon: "number")
                } else {
                    // Custom asset type — show available fields generically
                    vehicleInfoRow("Type", value: assetType.name, icon: assetType.systemImage)
                }
            }

            // ── Paired sensors section ────────────────────────────────
            Section {
                if v.pairedSensors.isEmpty {
                    Label("No sensors paired yet", systemImage: "sensor.fill")
                        .foregroundStyle(.secondary)
                        .font(.subheadline)
                } else {
                    ForEach(v.pairedSensors) { sensor in
                        let live = bleScanner.devices.first { $0.id == sensor.id }
                        PairedSensorRow(
                            sensor: sensor,
                            liveDevice: live,
                            onDetail: { detailSensor = sensor },
                            onUnpair: { store.unpairSensor(id: sensor.id) }
                        )
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button(role: .destructive) {
                                store.unpairSensor(id: sensor.id)
                            } label: {
                                Label("Unpair", systemImage: "minus.circle")
                            }
                            Button {
                                editSensor = sensor
                            } label: {
                                Label("Edit", systemImage: "pencil")
                            }
                            .tint(.blue)
                        }
                        .contextMenu {
                            Button {
                                editSensor = sensor
                            } label: {
                                Label("Edit Sensor", systemImage: "pencil")
                            }
                            Divider()
                            Button(role: .destructive) {
                                store.unpairSensor(id: sensor.id)
                            } label: {
                                Label("Unpair Sensor", systemImage: "link.badge.minus")
                            }
                        }
                    }
                }
            } header: {
                HStack {
                    Text("Paired Sensors (\(v.pairedSensors.count))")
                    Spacer()
                    Button {
                        showPairSheet = true
                    } label: {
                        Label("Pair", systemImage: "plus")
                            .font(.caption)
                    }
                }
            }

            // ── Wheel map section (when sensors have wheel positions) ─
            if v.pairedSensors.contains(where: { $0.wheelPosition != nil }) {
                Section("Wheel Map") {
                    OverallStatusBanner(vehicle: v, bleScanner: bleScanner, store: store)
                        .listRowInsets(.init(top: 6, leading: 0, bottom: 6, trailing: 0))
                        .listRowBackground(Color.clear)
                    WheelDiagram(vehicle: v, bleScanner: bleScanner, store: store)
                        .listRowInsets(.init(top: 4, leading: 0, bottom: 4, trailing: 0))
                        .listRowBackground(Color.clear)
                    WheelDetailGrid(vehicle: v, bleScanner: bleScanner, store: store)
                        .listRowInsets(.init(top: 4, leading: 0, bottom: 4, trailing: 0))
                        .listRowBackground(Color.clear)
                }
            }
        }
        #if os(macOS)
        .listStyle(.inset)
        #endif
    }

    // MARK: - Info row helper

    @ViewBuilder
    private func vehicleInfoRow(_ label: String, value: String?, icon: String) -> some View {
        if let v = value, !v.isEmpty {
            HStack {
                Label(label, systemImage: icon)
                    .foregroundStyle(.secondary)
                    .font(.subheadline)
                Spacer()
                Text(v)
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
            }
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarItems: some ToolbarContent {
        ToolbarItem(placement: .automatic) {
            Button {
                showPairSheet = true
            } label: {
                Label("Pair Sensor", systemImage: "sensor.fill")
            }
            .help("Pair a new sensor to this vehicle")
        }
        ToolbarItem(placement: .automatic) {
            Button {
                showEditSheet = true
            } label: {
                Label("Edit", systemImage: "pencil")
            }
            .help("Edit asset information")
        }
    }
}

// MARK: - Paired Sensor Row

struct PairedSensorRow: View {
    let sensor: PairedSensor
    let liveDevice: BLEDevice?
    var onDetail: (() -> Void)? = nil
    var onUnpair: (() -> Void)? = nil

    @State private var confirmUnpair = false

    private var isLive: Bool { liveDevice != nil }

    var body: some View {
        HStack(spacing: 12) {
            // Tappable content area (icon + labels + RSSI) — mirrors vehicle row behaviour
            Button { onDetail?() } label: {
                HStack(spacing: 12) {
                    // Icon
                    ZStack {
                        RoundedRectangle(cornerRadius: 8)
                            .fill(sensor.brand.badgeColor.opacity(0.12))
                            .frame(width: 36, height: 36)
                        Image(systemName: sensor.brand.systemImage)
                            .font(.system(size: 15))
                            .foregroundStyle(sensor.brand.badgeColor)
                    }
                    innerContent
                    Spacer(minLength: 0)
                    // RSSI if live
                    if let dev = liveDevice {
                        VStack(alignment: .trailing, spacing: 2) {
                            SignalBarsView(strength: dev.signalStrength)
                            Text("\(dev.rssi) dBm")
                                .font(.caption2.monospaced())
                                .foregroundStyle(dev.signalStrength.color)
                        }
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(onDetail == nil)

            // Action icons (kept outside the button to avoid nested-tap conflicts)
            HStack(spacing: 10) {
                if let detail = onDetail {
                    Button(action: detail) {
                        Image(systemName: "info.circle")
                            .font(.system(size: 16))
                            .foregroundStyle(.blue.opacity(0.8))
                    }
                    .buttonStyle(.plain)
                    .help("View sensor details")
                }
                if onUnpair != nil {
                    Button {
                        confirmUnpair = true
                    } label: {
                        Image(systemName: "minus.circle")
                            .font(.system(size: 16))
                            .foregroundStyle(.red)
                    }
                    .buttonStyle(.plain)
                    .help("Unpair sensor")
                }
            }
        }
        .padding(.vertical, 3)
        .confirmationDialog(
            "Unpair \"\(sensor.displayLabel)\"?",
            isPresented: $confirmUnpair,
            titleVisibility: .visible
        ) {
            Button("Unpair", role: .destructive) { onUnpair?() }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("The sensor will be removed from this asset.")
        }
    }

    @ViewBuilder
    private var innerContent: some View {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(sensor.displayLabel)
                        .font(.body.weight(.medium))
                    if isLive {
                        Circle().fill(.green).frame(width: 6, height: 6)
                            .help("In range")
                    }
                }

                HStack(spacing: 6) {
                    Text(sensor.brand.displayName)
                        .font(.caption)
                        .foregroundStyle(sensor.brand.badgeColor)

                    if let pos = sensor.wheelPosition {
                        Text("·")
                            .foregroundStyle(.tertiary)
                        Text(pos.label)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if let target = sensor.targetPressureBar {
                        Text("·")
                            .foregroundStyle(.tertiary)
                        Text(String(format: "Target: %.1f bar", target))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                // Live sensor data (compact)
                if let tms = liveDevice?.tmsData {
                    HStack(spacing: 8) {
                        if let p = tms.pressureBar {
                            Label(String(format: "%.2f bar", p),
                                  systemImage: "gauge.open.with.lines.needle.33percent")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.orange)
                        }
                        if let t = tms.temperatureC {
                            Label(String(format: "%.0f °C", t),
                                  systemImage: "thermometer.medium")
                                .font(.caption)
                                .foregroundStyle(.blue)
                        }
                    }
                } else if let sc = liveDevice?.stihlConnectorData {
                    HStack(spacing: 8) {
                        Label(String(format: "%d%%  %.2fV", sc.batteryPercent, sc.batteryVolts),
                              systemImage: "battery.50")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(sc.batteryPercent < 20 ? .red : .yellow)
                        if let t = sc.temperatureC {
                            Label(String(format: "%.0f °C", Double(t)),
                                  systemImage: "thermometer.medium")
                                .font(.caption)
                                .foregroundStyle(.blue)
                        }
                    }
                } else if let sb = liveDevice?.stihlBatteryData {
                    HStack(spacing: 8) {
                        Label("\(sb.chargePercent)%",
                              systemImage: "battery.50")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(sb.chargePercent < 20 ? .red : .yellow)
                        Label(sb.stateLabel, systemImage: "bolt.fill")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else if let ela = liveDevice?.elaData {
                    Label(ela.productVariant.displayName, systemImage: ela.productVariant.systemImage)
                        .font(.caption)
                        .foregroundStyle(.cyan)
                }

                // MAC ou UUID (truncated)
                Text(sensor.macAddress ?? (String(sensor.id.uuidString.prefix(8)) + "…"))
                    .font(.caption2.monospaced())
                    .foregroundStyle(.tertiary)
            }
    }
}

// MARK: - Pair Sensor Sheet

struct PairSensorSheet: View {
    @EnvironmentObject var store: VehicleStore
    @EnvironmentObject var bleScanner: BLEScanner
    @Environment(\.dismiss) var dismiss

    let vehicleID: UUID

    @State private var selectedBrand: SensorBrandTag = .michelin
    @State private var selectedDeviceID: UUID?
    @State private var customLabel: String = ""
    @State private var wheelPosition: WheelPosition = .frontLeft
    @State private var targetPressureText: String = "2.2"

    private var vehicle: VehicleConfig? {
        store.vehicles.first { $0.id == vehicleID }
    }

    /// Brands allowed for this asset type
    private var allowedBrands: [SensorBrandTag] {
        vehicle?.allowedBrands(from: store.assetTypes) ?? SensorBrandTag.allCases
    }

    /// Positions already assigned to existing sensors on this vehicle
    private var takenPositions: Set<WheelPosition> {
        let sensors = vehicle?.pairedSensors ?? []
        // Exclude the selected device itself (re-pairing case)
        return Set(sensors.filter { $0.id != selectedDeviceID }.compactMap { $0.wheelPosition })
    }

    private var availablePositions: [WheelPosition] {
        WheelPosition.allCases.filter { !takenPositions.contains($0) }
    }

    private var candidateDevices: [BLEDevice] {
        bleScanner.devices
            .filter { !($0.vehicle(in: store) != nil && $0.vehicle(in: store)?.id != vehicleID) }
            .filter { deviceMatchesBrand($0) }
            .sorted { $0.rssi > $1.rssi }
    }

    private func deviceMatchesBrand(_ d: BLEDevice) -> Bool {
        switch selectedBrand {
        case .michelin: return d.isTMSDevice
        case .stihl:    return d.stihlConnectorData != nil || d.stihlBatteryData != nil
        case .ela:      return d.elaData != nil
        case .airtag:   return d.manufacturerName == "Apple" && d.appleDeviceCategory == "FindMy"
        case .other:    return true
        }
    }

    private var isSaveEnabled: Bool { selectedDeviceID != nil }

    var body: some View {
        NavigationStack {
            Form {
                // Brand picker (filtered to what this asset type allows)
                Section("Sensor Type") {
                    Picker("Brand", selection: $selectedBrand) {
                        ForEach(allowedBrands) { brand in
                            Label(brand.displayName, systemImage: brand.systemImage)
                                .tag(brand)
                        }
                    }
                    .pickerStyle(.menu)
                    .onChange(of: selectedBrand) { _, _ in
                        selectedDeviceID = nil
                    }
                    .onAppear {
                        // If default brand is not allowed for this asset, switch to first allowed
                        if !allowedBrands.contains(selectedBrand),
                           let first = allowedBrands.first {
                            selectedBrand = first
                        }
                    }
                }

                // Device picker
                Section {
                    if candidateDevices.isEmpty {
                        Label(
                            bleScanner.isScanning
                                ? "Scanning for \(selectedBrand.displayName) devices…"
                                : "No \(selectedBrand.displayName) device detected",
                            systemImage: "antenna.radiowaves.left.and.right"
                        )
                        .foregroundStyle(.secondary)
                        .font(.subheadline)
                    } else {
                        Picker("Device", selection: $selectedDeviceID) {
                            Text("Select…").tag(Optional<UUID>.none)
                            ForEach(candidateDevices) { device in
                                HStack {
                                    Text(device.displayName)
                                    Text(device.stihlConnectorData?.macAddress ?? device.macAddress ?? String(device.id.uuidString.prefix(8)) + "…")
                                        .foregroundStyle(.secondary)
                                        .font(.caption.monospaced())
                                }
                                .tag(Optional(device.id))
                            }
                        }
                        .pickerStyle(.menu)
                    }
                } header: {
                    Text("Available Devices")
                } footer: {
                    if vehicle?.isPaired(selectedDeviceID ?? UUID()) == true {
                        Label("Already paired to this vehicle", systemImage: "checkmark.circle")
                            .foregroundStyle(.green).font(.caption)
                    }
                }

                // Optional label
                Section("Label (optional)") {
                    TextField("Custom name for this sensor", text: $customLabel)
                }

                // TMS-specific: wheel position + target pressure
                if selectedBrand.supportsTMSMapping {
                    Section("Wheel Mapping") {
                        Picker("Position", selection: $wheelPosition) {
                            ForEach(availablePositions) { pos in
                                Text(pos.label).tag(pos)
                            }
                        }
                        .pickerStyle(.menu)

                        LabeledContent("Target Pressure") {
                            HStack {
                                TextField("bar", text: $targetPressureText)
                                    .multilineTextAlignment(.trailing)
                                    .frame(width: 60)
                                    #if os(iOS)
                                    .keyboardType(.decimalPad)
                                    #endif
                                Text("bar")
                                    .foregroundStyle(.secondary)
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
                ToolbarItem(placement: .confirmationAction) {
                    Button("Pair") { pair() }
                        .disabled(!isSaveEnabled)
                }
            }
        }
    }

    private func pair() {
        guard let deviceID = selectedDeviceID else { return }
        let pairedDevice = bleScanner.devices.first { $0.id == deviceID }
        // For non-TMS sensors, fall back to the BLE device name if no custom label was entered
        let resolvedLabel: String? = {
            if !customLabel.isEmpty { return customLabel }
            if !selectedBrand.supportsTMSMapping {
                let n = pairedDevice?.displayName ?? ""
                return (n == "Unknown" || n.isEmpty) ? nil : n
            }
            return nil
        }()
        // Capture stable hardware key at pairing time for UUID-change recovery.
        // Without this, if the CBPeripheral UUID changes (BT reset, reinstall), the
        // sensor becomes invisible to the push loop and is never sent to the server.
        // – STIHL Connector : hardware MAC embedded in every BLE frame   → very reliable
        // – AirTag          : device name (MAC rotates by design)         → best available hint
        // – TMS             : lazily captured via storeMACIfNeeded on first detection
        let hardwareKey: String? = {
            if let sc = pairedDevice?.stihlConnectorData { return sc.macAddress }
            if selectedBrand == .airtag { return pairedDevice?.name }
            return nil
        }()
        let sensor = PairedSensor(
            id: deviceID,
            macAddress: hardwareKey,
            brand: selectedBrand,
            customLabel: resolvedLabel,
            wheelPosition: selectedBrand.supportsTMSMapping ? wheelPosition : nil,
            targetPressureBar: selectedBrand.supportsTMSMapping
                ? (Double(targetPressureText) ?? 2.2)
                : nil,
            pairedAt: Date()
        )
        store.pairSensor(sensor, to: vehicleID)
        dismiss()
    }
}

// MARK: - Edit Paired Sensor Sheet

struct EditPairedSensorSheet: View {
    @EnvironmentObject var store: VehicleStore
    @Environment(\.dismiss) var dismiss

    let vehicleID: UUID
    let sensor: PairedSensor

    @State private var customLabel: String = ""
    @State private var wheelPosition: WheelPosition = .frontLeft
    @State private var targetPressureText: String = "2.2"

    /// Positions already taken by OTHER sensors on this vehicle
    private var takenPositions: Set<WheelPosition> {
        let sensors = store.vehicles.first { $0.id == vehicleID }?.pairedSensors ?? []
        return Set(sensors.filter { $0.id != sensor.id }.compactMap { $0.wheelPosition })
    }

    private var availablePositions: [WheelPosition] {
        // Always include the sensor's current position so it stays selectable
        WheelPosition.allCases.filter { !takenPositions.contains($0) || $0 == sensor.wheelPosition }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Sensor") {
                    HStack {
                        Label(sensor.brand.displayName, systemImage: sensor.brand.systemImage)
                            .foregroundStyle(sensor.brand.badgeColor)
                        Spacer()
                        Text(sensor.macAddress ?? (String(sensor.id.uuidString.prefix(8)) + "…"))
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                    }
                }

                Section("Label") {
                    TextField("Custom name (optional)", text: $customLabel)
                }

                if sensor.brand.supportsTMSMapping {
                    Section("Wheel Mapping") {
                        Picker("Position", selection: $wheelPosition) {
                            ForEach(availablePositions) { pos in
                                Text(pos.label).tag(pos)
                            }
                        }
                        .pickerStyle(.menu)

                        LabeledContent("Target Pressure") {
                            HStack {
                                TextField("bar", text: $targetPressureText)
                                    .multilineTextAlignment(.trailing)
                                    .frame(width: 60)
                                    #if os(iOS)
                                    .keyboardType(.decimalPad)
                                    #endif
                                Text("bar")
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }

                Section {
                    Button("Unpair Sensor", role: .destructive) {
                        store.unpairSensor(id: sensor.id)
                        dismiss()
                    }
                }
            }
            .navigationTitle("Edit Sensor")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                }
            }
        }
        .onAppear {
            customLabel        = sensor.customLabel ?? ""
            wheelPosition      = sensor.wheelPosition ?? .frontLeft
            targetPressureText = sensor.targetPressureBar.map { String(format: "%.1f", $0) } ?? "2.2"
        }
    }

    private func save() {
        var updated = sensor
        updated.customLabel       = customLabel.isEmpty ? nil : customLabel
        updated.wheelPosition     = sensor.brand.supportsTMSMapping ? wheelPosition : nil
        updated.targetPressureBar = sensor.brand.supportsTMSMapping
            ? (Double(targetPressureText) ?? 2.2)
            : nil
        store.updatePairedSensor(updated, in: vehicleID)
        dismiss()
    }
}

// MARK: - Sensor Detail View

struct SensorDetailView: View {
    @EnvironmentObject var store: VehicleStore
    @EnvironmentObject var bleScanner: BLEScanner
    @Environment(\.dismiss) private var dismiss

    let sensor: PairedSensor
    let vehicleID: UUID

    @State private var showEditSheet = false
    @State private var showUnpairConfirm = false

    private var liveDevice: BLEDevice? {
        bleScanner.devices.first { $0.id == sensor.id }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {

                // ── Header ────────────────────────────────────────────
                HStack(spacing: 14) {
                    ZStack {
                        Circle()
                            .fill(sensor.brand.badgeColor.opacity(0.15))
                            .frame(width: 48, height: 48)
                        Image(systemName: sensor.brand.systemImage)
                            .font(.system(size: 22))
                            .foregroundStyle(sensor.brand.badgeColor)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text(sensor.displayLabel)
                            .font(.headline)
                        HStack(spacing: 5) {
                            Text(sensor.brand.displayName)
                                .font(.caption)
                                .padding(.horizontal, 7).padding(.vertical, 2)
                                .background(sensor.brand.badgeColor.opacity(0.12), in: Capsule())
                                .foregroundStyle(sensor.brand.badgeColor)
                            if let pos = sensor.wheelPosition {
                                Text(pos.label)
                                    .font(.caption)
                                    .padding(.horizontal, 7).padding(.vertical, 2)
                                    .background(Color.secondary.opacity(0.12), in: Capsule())
                                    .foregroundStyle(.secondary)
                            }
                            if liveDevice != nil {
                                HStack(spacing: 3) {
                                    Circle().fill(.green).frame(width: 5, height: 5)
                                    Text("Live")
                                        .font(.caption)
                                        .foregroundStyle(.green)
                                }
                            }
                        }
                    }
                    Spacer()
                    if let dev = liveDevice {
                        VStack(alignment: .trailing, spacing: 2) {
                            SignalBarsView(strength: dev.signalStrength)
                            Text("\(dev.rssi) dBm")
                                .font(.caption2.monospaced())
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(.top, 8)

                // ── Live sensor data ──────────────────────────────────
                if let tms = liveDevice?.tmsData {
                    TMSSectionView(tms: tms)
                    Divider().padding(.vertical, 4)
                }
                if let sc = liveDevice?.stihlConnectorData {
                    StihlConnectorSectionView(data: sc)
                    Divider().padding(.vertical, 4)
                }
                if let sb = liveDevice?.stihlBatteryData {
                    StihlBatterySectionView(data: sb)
                    Divider().padding(.vertical, 4)
                }
                if let ela = liveDevice?.elaData {
                    ELASectionView(data: ela)
                    Divider().padding(.vertical, 4)
                }
                if let dev = liveDevice, dev.isAirTagDevice {
                    BLEInfoSection(title: "AirTag / FindMy") {
                        BLEInfoRow(label: "Category",     value: "FindMy Network")
                        BLEInfoRow(label: "Manufacturer", value: dev.manufacturerName ?? "Apple")
                        BLEInfoRow(label: "Connectable",  value: dev.isConnectable ? "Yes" : "No")
                        if !dev.serviceUUIDs.isEmpty {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Services")
                                    .font(.caption).foregroundStyle(.secondary)
                                ForEach(dev.serviceUUIDs, id: \.self) { uuid in
                                    Text(uuid)
                                        .font(.caption2.monospaced())
                                        .foregroundStyle(.secondary)
                                        .textSelection(.enabled)
                                }
                            }
                        }
                    }
                    Divider().padding(.vertical, 4)
                }

                // ── Live signal ───────────────────────────────────────
                if let dev = liveDevice {
                    BLEInfoSection(title: "Signal") {
                        BLEInfoRow(label: "Quality", value: dev.signalStrength.label)
                        HStack {
                            Text("Strength")
                                .font(.caption).foregroundStyle(.secondary)
                                .frame(width: 80, alignment: .leading)
                            SignalBarsView(strength: dev.signalStrength)
                            Spacer()
                        }
                        if let dist = dev.estimatedDistance {
                            BLEInfoRow(label: "Distance ~", value: String(format: "%.1f m", dist))
                        }
                        BLEInfoRow(label: "Packets",
                                   value: "\(dev.seenCount)")
                        BLEInfoRow(label: "Last seen",
                                   value: dev.lastSeen.formatted(.relative(presentation: .named)))
                    }
                    Divider().padding(.vertical, 4)
                }

                // ── Stored configuration ──────────────────────────────
                BLEInfoSection(title: "Configuration") {
                    if let pos = sensor.wheelPosition {
                        BLEInfoRow(label: "Position", value: pos.label)
                    }
                    if let target = sensor.targetPressureBar {
                        BLEInfoRow(label: "Target", value: String(format: "%.2f bar", target))
                    }
                    if let mac = sensor.macAddress {
                        BLEInfoRow(label: "MAC", value: mac)
                    }
                    BLEInfoRow(label: "UUID", value: sensor.id.uuidString)
                }

                // ── Actions ───────────────────────────────────────────
                HStack(spacing: 12) {
                    Button {
                        showEditSheet = true
                    } label: {
                        Label("Edit", systemImage: "pencil")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)

                    Button(role: .destructive) {
                        showUnpairConfirm = true
                    } label: {
                        Label("Unpair", systemImage: "link.badge.minus")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .tint(.red)
                }
                .padding(.bottom, 16)
            }
            .padding(.horizontal, 16)
        }
        .background(Color.platformWindowBackground)
        .navigationTitle(sensor.displayLabel)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .sheet(isPresented: $showEditSheet) {
            EditPairedSensorSheet(vehicleID: vehicleID, sensor: sensor)
                .environmentObject(store)
                .environmentObject(bleScanner)
        }
        .confirmationDialog(
            "Unpair \"\(sensor.displayLabel)\"?",
            isPresented: $showUnpairConfirm,
            titleVisibility: .visible
        ) {
            Button("Unpair", role: .destructive) {
                store.unpairSensor(id: sensor.id)
                dismiss()
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This sensor will be removed from the vehicle. You can re-pair it later.")
        }
    }
}

// MARK: - BLEDevice convenience extension

extension BLEDevice {
    /// Vehicle that has this device paired (lookup in store)
    @MainActor
    func vehicle(in store: VehicleStore) -> VehicleConfig? {
        store.vehicle(for: self.id)
    }
}
