import SwiftUI

@main
struct NetMapApp: App {
    #if os(iOS)
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    #endif

    // AppEnvironment.init() runs here, synchronously, wiring the push pipeline
    // before any CoreBluetooth callback can fire on the main queue.
    @StateObject private var env = AppEnvironment()

    @SceneBuilder
    var body: some Scene {
        let mainWindow = WindowGroup {
            ContentView()
                .environmentObject(env.bleScanner)
                .environmentObject(env.vehicleStore)
                .environmentObject(env.locationManager)
                .environmentObject(env.serverClient)
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
                    Button("Start BLE Scan") { env.bleScanner.startScan() }
                        .keyboardShortcut("r", modifiers: .command)
                        .disabled(env.bleScanner.isScanning)
                    Button("Stop BLE Scan") { env.bleScanner.stopScan() }
                        .keyboardShortcut(".", modifiers: .command)
                        .disabled(!env.bleScanner.isScanning)
                }
            }
        Settings {
            NavigationStack {
                ServerSettingsView()
                    .environmentObject(env.serverClient)
            }
            .frame(width: 500, height: 560)
        }
        #else
        mainWindow
        #endif
    }
}

// MARK: - ContentView (tab / split root)

struct ContentView: View {
    @EnvironmentObject var bleScanner:   BLEScanner
    @EnvironmentObject var vehicleStore: VehicleStore
    @EnvironmentObject var serverClient: NetMapServerClient
    #if os(iOS)
    @Environment(\.scenePhase) private var scenePhase
    #endif

    @State private var showServerSettings = false
    /// Tracks whether the user explicitly dismissed the login sheet this session.
    @State private var loginDismissed = false
    @State private var selectedTab = 0

    var body: some View {
        TabView(selection: $selectedTab) {
            // ── Assets tab — VehicleListView provides its own NavigationStack/SplitView ──
            VehicleListView()
                .environmentObject(bleScanner)
                .environmentObject(vehicleStore)
                .environmentObject(serverClient)
            .tabItem {
                Label("Assets", systemImage: "shippingbox.fill")
            }
            .tag(0)

            // ── BLE Scanner tab — BLEDeviceListView provides its own NavigationStack/SplitView ──
            BLEDeviceListView()
                .environmentObject(bleScanner)
                .environmentObject(vehicleStore)
                .environmentObject(serverClient)
            .tabItem {
                Label("Sensors", systemImage: "antenna.radiowaves.left.and.right")
            }
            .tag(1)

        }
        .onChange(of: selectedTab) { _, newTab in
            guard newTab == 0, !serverClient.host.isEmpty else { return }
            Task {
                async let typesResult   = try? serverClient.fetchAssetTypes()
                async let assetsResult  = try? serverClient.fetchAssets()
                async let sensorsResult = try? serverClient.fetchPairedSensors()
                let (types, assets, sensors) = await (typesResult, assetsResult, sensorsResult)
                if let types   { vehicleStore.mergeServerAssetTypes(types) }
                if let assets  { vehicleStore.syncFromServer(assets) }
                if let sensors { vehicleStore.syncPairedSensorsFromServer(sensors) }
            }
        }
        // Server settings button is now inside BLEDeviceListView's iOS toolbar
        // ── Asset + sensor sync on launch (public endpoints, no auth required) ──
        .task {
            async let typesResult   = try? serverClient.fetchAssetTypes()
            async let assetsResult  = try? serverClient.fetchAssets()
            async let sensorsResult = try? serverClient.fetchPairedSensors()
            let (types, assets, sensors) = await (typesResult, assetsResult, sensorsResult)
            if let types   { vehicleStore.mergeServerAssetTypes(types) }
            if let assets  { vehicleStore.syncFromServer(assets) }
            // Sensor sync must run after assets so serverVehicleID is populated
            if let sensors { vehicleStore.syncPairedSensorsFromServer(sensors) }
        }
        // ── Re-sync + validate token when forwarding is enabled ────────────
        .task(id: serverClient.isEnabled) {
            guard serverClient.isEnabled else { return }
            async let typesResult   = try? serverClient.fetchAssetTypes()
            async let assetsResult  = try? serverClient.fetchAssets()
            async let sensorsResult = try? serverClient.fetchPairedSensors()
            let (types, assets, sensors) = await (typesResult, assetsResult, sensorsResult)
            if let types   { vehicleStore.mergeServerAssetTypes(types) }
            if let assets  { vehicleStore.syncFromServer(assets) }
            if let sensors { vehicleStore.syncPairedSensorsFromServer(sensors) }
            await serverClient.validateStoredToken()
        }
        // ── Login gate ────────────────────────────────────────────────────
        // Sheet is OPTIONAL — syncing public endpoints works without auth.
        // Only shown once per launch; user can dismiss to browse assets read-only.
        .sheet(isPresented: Binding(
            get: { serverClient.isEnabled && !serverClient.isAuthenticated && !loginDismissed },
            set: { if !$0 { loginDismissed = true } }
        )) {
            LoginView()
                .environmentObject(serverClient)
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
        #if os(iOS)
        // ── Foreground: full scan (allowDuplicates:true + 30s cycle)
        // ── Background: efficient scan (allowDuplicates:false, no timer) ──
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:       bleScanner.enterForeground()
            case .background:   bleScanner.enterBackground()
            default:            break
            }
        }
        #endif
        // ── Forward all sensors to server handled by SensorPushService (background-safe) ──
    }
}
