import SwiftUI

@main
struct NetMapApp: App {
    @StateObject private var bleScanner      = BLEScanner()
    @StateObject private var vehicleStore   = VehicleStore.shared
    @StateObject private var locationManager = LocationManager()
    @StateObject private var serverClient   = NetMapServerClient()

    init() {
        // One-shot migration: remove legacy local history that was stored in v1.
        UserDefaults.standard.removeObject(forKey: "history_v1")
    }

    @SceneBuilder
    var body: some Scene {
        let mainWindow = WindowGroup {
            ContentView()
                .environmentObject(bleScanner)
                .environmentObject(vehicleStore)
                .environmentObject(locationManager)
                .environmentObject(serverClient)
            #if os(macOS)
                .frame(minWidth: 800, minHeight: 560)
            #endif
        }
        #if os(macOS)
        mainWindow
            .windowStyle(.titleBar)
            .windowToolbarStyle(.unified(showsTitle: true))
            .commands {
                CommandGroup(replacing: .newItem) { }
                CommandMenu("Bluetooth") {
                    Button("Start BLE Scan") { bleScanner.startScan() }
                        .keyboardShortcut("r", modifiers: .command)
                        .disabled(bleScanner.isScanning)
                    Button("Stop BLE Scan") { bleScanner.stopScan() }
                        .keyboardShortcut(".", modifiers: .command)
                        .disabled(!bleScanner.isScanning)
                }
            }
        Settings {
            NavigationStack {
                ServerSettingsView()
                    .environmentObject(serverClient)
            }
            .frame(width: 500, height: 560)
        }
        #else
        mainWindow
        #endif
    }
}

// MARK: - Push throttle (reference type — mutations visible immediately across onChange calls)

/// Holds per-sensor last-push timestamps as a class so mutations take effect immediately,
/// avoiding the SwiftUI @State async-update pitfall where rapid onChange invocations all
/// see the stale pre-mutation value.
private class PushThrottle: ObservableObject {
    private var lastPushed: [String: Date] = [:]
    func canPush(_ id: String, now: Date, interval: TimeInterval = 60) -> Bool {
        guard let last = lastPushed[id] else { return true }
        return now.timeIntervalSince(last) >= interval
    }
    func stamp(_ id: String, now: Date) {
        lastPushed[id] = now
    }
}

// MARK: - ContentView (tab / split root)

struct ContentView: View {
    @EnvironmentObject var bleScanner:      BLEScanner
    @EnvironmentObject var vehicleStore:    VehicleStore
    @EnvironmentObject var locationManager: LocationManager
    @EnvironmentObject var serverClient:    NetMapServerClient

    @State private var showServerSettings = false
    /// @StateObject survives SwiftUI struct re-creation — plain `let` would reset on every BLE update.
    @StateObject private var throttle = PushThrottle()

    var body: some View {
        TabView {
            // ── BLE Scanner tab ───────────────────────────────────────
            NavigationStack {
                BLEDeviceListView()
                    .environmentObject(bleScanner)
                    .environmentObject(vehicleStore)
            }
            .tabItem {
                Label("Sensors", systemImage: "antenna.radiowaves.left.and.right")
            }

            // ── Assets tab ────────────────────────────────────────────
            VehicleListView()
                .environmentObject(bleScanner)
                .environmentObject(vehicleStore)
            .tabItem {
                Label("Assets", systemImage: "shippingbox.fill")
            }

            // ── History tab ───────────────────────────────────────────
            NavigationStack {
                SensorHistoryView()
                    .environmentObject(vehicleStore)
                    .environmentObject(serverClient)
            }
            .tabItem {
                Label("History", systemImage: "clock.arrow.circlepath")
            }
        }
        // ── Server settings button (iOS — on macOS use App > Settings) ──
        #if os(iOS)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { showServerSettings = true } label: {
                    Image(systemName: "server.rack")
                        .foregroundStyle(
                            serverClient.isEnabled
                                ? serverClient.connectionStatus.color
                                : Color.secondary
                        )
                }
            }
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
        #endif
        // ── Auth + sync on launch / when server enabled ───────────────────
        .task(id: serverClient.isEnabled) {
            guard serverClient.isEnabled else { return }
            await serverClient.validateStoredToken()
            guard serverClient.isAuthenticated else { return }
            if let svs = try? await serverClient.fetchVehicles() {
                vehicleStore.syncFromServer(svs)
            }
        }
        // ── Login gate ────────────────────────────────────────────────────
        .sheet(isPresented: Binding(
            get: { serverClient.isEnabled && !serverClient.isAuthenticated },
            set: { _ in }
        )) {
            LoginView()
                .environmentObject(serverClient)
                .interactiveDismissDisabled(true)
        }
        // ── Show server settings from LoginView ───────────────────────────
        .onReceive(NotificationCenter.default.publisher(for: .showServerSettings)) { _ in
            showServerSettings = true
        }
        // ── Keep BLE scan running regardless of active tab ─────────────
        .onAppear {
            if bleScanner.bluetoothState == .poweredOn { bleScanner.startScan() }
        }
        .onChange(of: bleScanner.bluetoothState) { _, state in
            if state == .poweredOn, !bleScanner.isScanning { bleScanner.startScan() }
        }
        // ── Forward all paired sensors to server ───────────────────────
        .onChange(of: bleScanner.devices) { _, devices in
            guard serverClient.isEnabled, serverClient.isAuthenticated else { return }
            let now = Date()
            for d in devices {
                // Resolve which asset this device belongs to
                var vehicle: VehicleConfig? = vehicleStore.vehicle(for: d.id)
                // TMS fallback: CBPeripheral UUID may change after reinstall, recover via MAC
                if vehicle == nil, let mac = d.macAddress {
                    vehicle = vehicleStore.vehicle(forMAC: mac)
                    if let v = vehicle {
                        vehicleStore.healSensorUUID(fromMAC: mac, to: d.id, in: v.id)
                    }
                }
                // STIHL Connector fallback: d.macAddress is always nil for STIHL; use the
                // hardware MAC embedded in the BLE frame (stored in PairedSensor.macAddress
                // at pairing time by PairSensorSheet.pair())
                if vehicle == nil, let sc = d.stihlConnectorData {
                    vehicle = vehicleStore.vehicle(forMAC: sc.macAddress)
                    if let v = vehicle {
                        vehicleStore.healSensorUUID(fromMAC: sc.macAddress, to: d.id, in: v.id)
                    }
                }
                // AirTag fallback: MAC rotates (Apple privacy); device name stored at pairing
                // time is the only available soft hint
                if vehicle == nil, d.isAirTagDevice, let name = d.name, !name.isEmpty {
                    vehicle = vehicleStore.vehicle(forMAC: name)
                    if let v = vehicle {
                        vehicleStore.healSensorUUID(fromMAC: name, to: d.id, in: v.id)
                    }
                }
                guard let vehicle else { continue }  // not paired — skip
                // Persist TMS MAC for post-reinstall recovery (lazily, first detection)
                if let mac = d.macAddress {
                    vehicleStore.storeMACIfNeeded(mac, forSensorUUID: d.id, in: vehicle.id)
                }
                // Persist STIHL MAC retroactively for sensors paired before this fix
                // (new pairings already have it saved by PairSensorSheet.pair())
                if let sc = d.stihlConnectorData {
                    vehicleStore.storeMACIfNeeded(sc.macAddress, forSensorUUID: d.id, in: vehicle.id)
                }

                // ── Compute stable push ID (MAC-based when available) ───────
                // Must match the sensorID sent to the server so the throttle key
                // stays stable even when the BLE UUID rotates after reconnection.
                let stableID: String
                if let sc = d.stihlConnectorData {
                    stableID = "STIHL-" + sc.macAddress.replacingOccurrences(of: ":", with: "")
                } else if let sb = d.stihlBatteryData {
                    stableID = "STIHLBATT-\(sb.serialNumber)"
                } else {
                    stableID = d.stableSensorID
                }

                // ── Per-sensor 1-minute throttle ────────────────────────────
                // PushThrottle is a class — canPush()/stamp() mutations are immediately
                // visible to the next onChange call, avoiding the @State async-update bug.
                if !throttle.canPush(stableID, now: now) { continue }

                let vid    = vehicle.serverVehicleID?.uuidString ?? vehicle.id.uuidString
                let vname  = vehicle.name
                let paired = vehicle.pairedSensors.first { $0.id == d.id }
                let lat    = locationManager.currentLatitude
                let lon    = locationManager.currentLongitude

                var payload: ServerSensorPayload?

                if let tms = d.tmsData {
                    // ── Michelin TPMS ────────────────────────────────────────
                    payload = ServerSensorPayload(
                        sensorID:          d.stableSensorID,
                        vehicleID:         vid,
                        vehicleName:       vname,
                        assetTypeID:       vehicle.assetTypeID,
                        brand:             paired?.brand.rawValue ?? "michelin",
                        wheelPosition:     paired?.wheelPosition?.rawValue,
                        pressureBar:       tms.pressureBar,
                        temperatureC:      tms.temperatureC,
                        vbattVolts:        tms.vbattVolts,
                        targetPressureBar: paired?.targetPressureBar,
                        batteryPct:        tms.vbattPct,
                        chargeState:       nil,
                        sensorName:        paired?.customLabel,
                        latitude:          lat,
                        longitude:         lon,
                        timestamp:         Date()
                    )

                } else if let sc = d.stihlConnectorData {
                    // ── STIHL Smart Connector ────────────────────────────────
                    payload = ServerSensorPayload(
                        sensorID:          stableID,
                        vehicleID:         vid,
                        vehicleName:       vname,
                        assetTypeID:       vehicle.assetTypeID,
                        brand:             "stihl",
                        wheelPosition:     nil,
                        pressureBar:       nil,
                        temperatureC:      sc.temperatureC.map(Double.init),
                        vbattVolts:        sc.batteryVolts,
                        targetPressureBar: nil,
                        batteryPct:        sc.batteryPercent,
                        chargeState:       nil,
                        sensorName:        paired?.customLabel ?? d.name ?? sc.productName,
                        healthPct:         nil,
                        chargingCycles:    nil,
                        productVariant:    nil,
                        totalSeconds:      Int(sc.counterSeconds),
                        latitude:          lat,
                        longitude:         lon,
                        timestamp:         Date()
                    )

                } else if let sb = d.stihlBatteryData {
                    // ── STIHL Smart Battery ──────────────────────────────────
                    payload = ServerSensorPayload(
                        sensorID:          stableID,
                        vehicleID:         vid,
                        vehicleName:       vname,
                        assetTypeID:       vehicle.assetTypeID,
                        brand:             "stihl",
                        wheelPosition:     nil,
                        pressureBar:       nil,
                        temperatureC:      nil,
                        vbattVolts:        nil,
                        targetPressureBar: nil,
                        batteryPct:        Int(sb.chargePercent),
                        chargeState:       sb.stateLabel,
                        sensorName:        paired?.customLabel ?? d.name ?? "STIHL Battery \(sb.serialNumber)",
                        healthPct:         Int(sb.healthPercent),
                        chargingCycles:    Int(sb.chargingCycles),
                        productVariant:    nil,
                        totalSeconds:      Int(sb.totalDischargeTime),
                        latitude:          lat,
                        longitude:         lon,
                        timestamp:         Date()
                    )

                } else if let ela = d.elaData {
                    // ── ELA Innovation (Blue Coin/Puck T) ────────────────────
                    // dataType 0x06: payload[0..1] = temperature in 0.01 °C (int16 LE)
                    var tempC: Double? = nil
                    if ela.dataType == 0x06, ela.payload.count >= 2 {
                        let raw = Int16(bitPattern: UInt16(ela.payload[0]) | (UInt16(ela.payload[1]) << 8))
                        tempC = Double(raw) / 100.0
                    }
                    payload = ServerSensorPayload(
                        sensorID:          d.stableSensorID,
                        vehicleID:         vid,
                        vehicleName:       vname,
                        assetTypeID:       vehicle.assetTypeID,
                        brand:             "ela",
                        wheelPosition:     nil,
                        pressureBar:       nil,
                        temperatureC:      tempC,
                        vbattVolts:        nil,
                        targetPressureBar: nil,
                        batteryPct:        nil,
                        chargeState:       nil,
                        sensorName:        paired?.customLabel ?? d.displayName,
                        healthPct:         nil,
                        chargingCycles:    nil,
                        productVariant:    ela.productVariant.variantID,
                        latitude:          lat,
                        longitude:         lon,
                        timestamp:         Date()
                    )

                } else if paired?.brand == .airtag {
                    // ── AirTag — presence / location heartbeat ───────────────
                    payload = ServerSensorPayload(
                        sensorID:          d.stableSensorID,
                        vehicleID:         vid,
                        vehicleName:       vname,
                        assetTypeID:       vehicle.assetTypeID,
                        brand:             "airtag",
                        wheelPosition:     nil,
                        pressureBar:       nil,
                        temperatureC:      nil,
                        vbattVolts:        nil,
                        targetPressureBar: nil,
                        batteryPct:        nil,
                        chargeState:       nil,
                        sensorName:        paired?.customLabel ?? d.displayName,
                        latitude:          lat,
                        longitude:         lon,
                        timestamp:         Date()
                    )
                }

                if let payload {
                    throttle.stamp(stableID, now: now)   // stamp only when data is valid
                    serverClient.enqueue(payload)
                }
            }
        }
    }
}
