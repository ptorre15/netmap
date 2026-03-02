import Foundation
import Combine

/// Central persistence service: vehicle configurations + pressure history.
/// Stored in UserDefaults (JSON) — no Core Data to stay lightweight and cross-platform.
@MainActor
class VehicleStore: ObservableObject {

    static let shared = VehicleStore()

    @Published var vehicles: [VehicleConfig] = []
    /// All asset types (built-in + custom from server). Always includes .vehicle and .tool.
    @Published var assetTypes: [AssetType] = AssetType.builtInTypes

    private let vehiclesKey   = "vehicles_v2"
    private let assetTypesKey = "asset_types_v1"

    init() { load() }

    // MARK: - Vehicle CRUD

    func addVehicle(_ config: VehicleConfig) {
        vehicles.append(config)
        saveVehicles()
    }

    func updateVehicle(_ config: VehicleConfig) {
        if let idx = vehicles.firstIndex(where: { $0.id == config.id }) {
            vehicles[idx] = config
            saveVehicles()
        }
    }

    func deleteVehicle(id: UUID) {
        vehicles.removeAll { $0.id == id }
        saveVehicles()
    }

    // MARK: - Sensor Pairing

    /// Pair a sensor to a vehicle (replaces existing entry with same BLE UUID)
    func pairSensor(_ sensor: PairedSensor, to vehicleID: UUID) {
        guard let idx = vehicles.firstIndex(where: { $0.id == vehicleID }) else { return }
        // Remove from any other vehicle first
        for i in vehicles.indices where vehicles[i].id != vehicleID {
            vehicles[i].unpairSensor(id: sensor.id)
        }
        vehicles[idx].pairSensor(sensor)
        saveVehicles()
    }

    /// Unpair a sensor from its vehicle
    func unpairSensor(id sensorID: UUID) {
        for idx in vehicles.indices {
            vehicles[idx].unpairSensor(id: sensorID)
        }
        saveVehicles()
    }

    /// Update an existing paired sensor (e.g. change wheel position, label, pressure target)
    func updatePairedSensor(_ sensor: PairedSensor, in vehicleID: UUID) {
        guard let idx = vehicles.firstIndex(where: { $0.id == vehicleID }) else { return }
        vehicles[idx].pairSensor(sensor)
        saveVehicles()
    }

    // MARK: - History recording — moved to server
    // Readings are forwarded to NetMapServer via NetMapServerClient.
    // History is fetched on demand from GET /api/records/by-sensor/:id.

    // MARK: - Lookup

    /// Vehicle that owns the sensor matching the given BLE MAC address (3 LSB bytes).
    /// Use as fallback when `vehicle(for:)` returns nil after an app reinstall.
    func vehicle(forMAC mac: String) -> VehicleConfig? {
        vehicles.first { $0.pairedSensors.contains { $0.macAddress == mac } }
    }

    /// Store the MAC address in the PairedSensor if not yet known.
    /// Called whenever a UUID-matched device advertises a TMS frame with MAC bytes.
    /// This "heals forward" so that future reinstall-recovery via MAC will work.
    func storeMACIfNeeded(_ mac: String, forSensorUUID id: UUID, in vehicleID: UUID) {
        guard let vIdx = vehicles.firstIndex(where: { $0.id == vehicleID }),
              let sIdx = vehicles[vIdx].pairedSensors.firstIndex(where: { $0.id == id }),
              vehicles[vIdx].pairedSensors[sIdx].macAddress == nil
        else { return }
        vehicles[vIdx].pairedSensors[sIdx].macAddress = mac
        saveVehicles()
    }

    /// After an app reinstall the CBPeripheral UUID changes.
    /// When a MAC-based lookup succeeds, call this to update the stored UUID
    /// so that future scans match directly without going through the MAC fallback.
    func healSensorUUID(fromMAC mac: String, to newID: UUID, in vehicleID: UUID) {
        guard let vIdx = vehicles.firstIndex(where: { $0.id == vehicleID }),
              let sIdx = vehicles[vIdx].pairedSensors.firstIndex(where: { $0.macAddress == mac })
        else { return }
        vehicles[vIdx].pairedSensors[sIdx].id = newID
        saveVehicles()
    }

    /// Wheel position for a given TMS sensor UUID (nil for non-TMS)
    func wheelPosition(for sensorID: UUID) -> WheelPosition? {
        for v in vehicles {
            if let s = v.pairedSensors.first(where: { $0.id == sensorID }) {
                return s.wheelPosition
            }
        }
        return nil
    }

    /// Back-compat alias
    func position(for sensorID: UUID) -> WheelPosition? { wheelPosition(for: sensorID) }

    /// Vehicle that owns a given sensor
    func vehicle(for sensorID: UUID) -> VehicleConfig? {
        vehicles.first { $0.isPaired(sensorID) }
    }

    /// All vehicles that have at least one sensor of the given brand
    func vehicles(with brand: SensorBrandTag) -> [VehicleConfig] {
        vehicles.filter { $0.pairedSensors.contains { $0.brand == brand } }
    }

    /// Resolved AssetType for a given asset
    func assetType(for asset: VehicleConfig) -> AssetType {
        asset.resolvedAssetType(from: assetTypes)
    }

    // MARK: - Asset Type CRUD (admin only — UI enforces role)

    func addAssetType(_ type: AssetType) {
        guard !assetTypes.contains(where: { $0.id == type.id }) else { return }
        assetTypes.append(type)
        saveAssetTypes()
    }

    func updateAssetType(_ type: AssetType) {
        guard !type.isBuiltIn else { return }
        if let idx = assetTypes.firstIndex(where: { $0.id == type.id }) {
            assetTypes[idx] = type
            saveAssetTypes()
        }
    }

    func deleteAssetType(id: String) {
        guard let t = assetTypes.first(where: { $0.id == id }), !t.isBuiltIn else { return }
        assetTypes.removeAll { $0.id == id }
        saveAssetTypes()
    }

    /// Merge custom types fetched from the server (preserves built-ins)
    func mergeServerAssetTypes(_ serverTypes: [AssetType]) {
        let custom = serverTypes.filter { !$0.isBuiltIn }
        for t in custom {
            if let idx = assetTypes.firstIndex(where: { $0.id == t.id }) {
                assetTypes[idx] = t
            } else {
                assetTypes.append(t)
            }
        }
        saveAssetTypes()
    }

    /// Sync local vehicles with the server-authoritative vehicle list.
    /// Matches by `serverVehicleID` first, then falls back to case-insensitive name match.
    /// Sets `serverVehicleID` on newly matched local vehicles.
    func syncFromServer(_ serverVehicles: [VehicleServerDTO]) {
        var changed = false
        for sv in serverVehicles {
            if let idx = vehicles.firstIndex(where: { $0.serverVehicleID == sv.id }) {
                // Already linked — update display name if server renamed it
                if vehicles[idx].name != sv.name {
                    vehicles[idx].name = sv.name
                    changed = true
                }
            } else if let idx = vehicles.firstIndex(where: {
                $0.serverVehicleID == nil &&
                $0.name.lowercased() == sv.name.lowercased()
            }) {
                // Name match — link to server UUID
                vehicles[idx].serverVehicleID = sv.id
                changed = true
            }
            // Server-only vehicles (no local match) are not auto-created locally;
            // they will appear in the web dashboard but have no sensors yet.
        }
        if changed { saveVehicles() }
    }

    // MARK: - Slow Puncture Detection
    // NOTE: Previously used local history; now requires server-side data.
    // slowPunctureDetected() removed — use server analytics if needed.

    // MARK: - Persistence

    private func load() {
        // Load assets (auto-migration: existing records decode with default assetTypeID = "vehicle")
        if let data = UserDefaults.standard.data(forKey: vehiclesKey),
           let decoded = try? JSONDecoder().decode([VehicleConfig].self, from: data) {
            vehicles = decoded
        }
        // Load custom asset types (built-ins always present)
        if let data = UserDefaults.standard.data(forKey: assetTypesKey),
           let decoded = try? JSONDecoder().decode([AssetType].self, from: data) {
            let custom = decoded.filter { !$0.isBuiltIn }
            assetTypes = AssetType.builtInTypes + custom
        }
    }

    private func saveVehicles() {
        if let data = try? JSONEncoder().encode(vehicles) {
            UserDefaults.standard.set(data, forKey: vehiclesKey)
        }
    }

    private func saveAssetTypes() {
        // Only persist custom types; built-ins are compiled in
        let custom = assetTypes.filter { !$0.isBuiltIn }
        if let data = try? JSONEncoder().encode(custom) {
            UserDefaults.standard.set(data, forKey: assetTypesKey)
        }
    }
}
