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
    /// Latest telemetry stats from the server, keyed by sensorID (IMEI for trackers, MAC for BLE).
    @Published var latestServerStats: [String: SensorServerDTO] = [:]

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

    /// Pair a sensor to a vehicle (replaces existing entry with same BLE UUID or macAddress).
    /// Cleans up any previous pairing on another vehicle, matching by UUID or hardware key,
    /// so AirTags (rotating UUID) and reinstall scenarios never leave stale entries.
    func pairSensor(_ sensor: PairedSensor, to vehicleID: UUID) {
        guard let idx = vehicles.firstIndex(where: { $0.id == vehicleID }) else { return }
        // Remove from any other vehicle first — by UUID and by hardware key
        for i in vehicles.indices where vehicles[i].id != vehicleID {
            vehicles[i].unpairSensor(id: sensor.id)
            if let mac = sensor.macAddress, !mac.isEmpty {
                vehicles[i].pairedSensors.removeAll { $0.macAddress == mac }
            }
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

    /// Heals the macAddress field of an AirTag sensor to a stable name key.
    /// Called during push when the tag is detected but macAddress was never stored
    /// (e.g. old pairing created before the hardwareKey logic, or after UUID rotation).
    /// Without this, every CBPeripheral UUID rotation creates a new orphaned sensorID on the server.
    func healAirTagMACIfNeeded(name: String, in vehicleID: UUID) {
        guard !name.isEmpty,
              let vIdx = vehicles.firstIndex(where: { $0.id == vehicleID }),
              let sIdx = vehicles[vIdx].pairedSensors.firstIndex(where: {
                  $0.brand == .airtag && ($0.macAddress == nil || $0.macAddress!.isEmpty)
              })
        else { return }
        vehicles[vIdx].pairedSensors[sIdx].macAddress = name
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

    /// Sync local assets with the server-authoritative list.
    /// Matches by `serverVehicleID` first, then by case-insensitive name.
    /// Creates local assets for any server entry without a local counterpart.
    /// Sync local asset metadata from the server-authoritative list.
    /// Creates local entries for new server assets; updates metadata of existing ones.
    /// Does NOT touch pairedSensors — use syncPairedSensorsFromServer() for that.
    func syncFromServer(_ serverAssets: [VehicleServerDTO]) {
        var changed = false

        for sv in serverAssets {
            // Normalize assetTypeID: if server returns a UUID (old data), resolve to slug via name match
            let rawTypeID = sv.assetTypeID ?? AssetType.vehicle.id
            let typeID: String = {
                // Already a known slug → use directly
                if assetTypes.contains(where: { $0.id == rawTypeID }) { return rawTypeID }
                // UUID not recognized → fallback to "vehicle" (server normalizes these at startup)
                return AssetType.vehicle.id
            }()

            func apply(to v: inout VehicleConfig) {
                if v.name         != sv.name         { v.name         = sv.name;        changed = true }
                if v.assetTypeID  != typeID          { v.assetTypeID  = typeID;          changed = true }
                if v.brand        != sv.brand        { v.brand        = sv.brand;        changed = true }
                if v.model        != sv.modelName    { v.model        = sv.modelName;    changed = true }
                if v.year         != sv.year         { v.year         = sv.year;         changed = true }
                if v.vin          != sv.vin          { v.vin          = sv.vin;          changed = true }
                if v.vrn          != sv.vrn          { v.vrn          = sv.vrn;          changed = true }
                if v.serialNumber != sv.serialNumber { v.serialNumber = sv.serialNumber; changed = true }
                if v.toolType     != sv.toolType     { v.toolType     = sv.toolType;     changed = true }
            }

            if let idx = vehicles.firstIndex(where: { $0.serverVehicleID == sv.id }) {
                apply(to: &vehicles[idx])
            } else if let idx = vehicles.firstIndex(where: {
                $0.serverVehicleID == nil &&
                $0.name.lowercased() == sv.name.lowercased()
            }) {
                vehicles[idx].serverVehicleID = sv.id
                changed = true
                apply(to: &vehicles[idx])
            } else {
                var v = VehicleConfig(id: UUID(), name: sv.name, assetTypeID: typeID)
                v.serverVehicleID = sv.id
                v.brand        = sv.brand
                v.model        = sv.modelName
                v.year         = sv.year
                v.vin          = sv.vin
                v.vrn          = sv.vrn
                v.serialNumber = sv.serialNumber
                v.toolType     = sv.toolType
                vehicles.append(v)
                changed = true
            }
        }
        // Remove local assets that were deleted on the server.
        // Only remove assets that were previously synced from the server (serverVehicleID != nil).
        let serverIDs = Set(serverAssets.map(\.id))
        let toRemove = vehicles.filter { v in
            guard let sid = v.serverVehicleID else { return false }
            return !serverIDs.contains(sid)
        }
        if !toRemove.isEmpty {
            let removeIDs = Set(toRemove.map(\.id))
            vehicles.removeAll { removeIDs.contains($0.id) }
            changed = true
        }
        if changed { saveVehicles() }
    }

    /// Server-authoritative sensor sync.
    /// Replaces the pairedSensors of every server-linked vehicle with what the server
    /// reports via GET /api/sensors/latest. BLE UUIDs are preserved where possible
    /// so that live BLE matching continues to work without re-scanning.
    ///
    /// Must be called AFTER syncFromServer() so that serverVehicleID is already populated.
    func syncPairedSensorsFromServer(_ serverSensors: [SensorServerDTO]) {
        // Cache all server stats for display (keyed by sensorID = IMEI for trackers, MAC for BLE)
        for s in serverSensors {
            latestServerStats[s.sensorID] = s
        }

        // Group sensors by server vehicleID (UUID) — with a name fallback for stale UUIDs
        // (sensor_readings may store old local UUIDs that pre-date the current vehicles table)
        var byVehicleUUID: [UUID: [SensorServerDTO]] = [:]
        var byVehicleName: [String: [SensorServerDTO]] = [:]
        for s in serverSensors {
            if let vid = UUID(uuidString: s.vehicleID) {
                byVehicleUUID[vid, default: []].append(s)
            } else {
                let name = s.vehicleName.lowercased()
                byVehicleName[name, default: []].append(s)
            }
        }

        var changed = false
        for idx in vehicles.indices {
            guard let serverVehicleID = vehicles[idx].serverVehicleID else { continue }

            // Primary: match by server vehicle UUID
            var serverList = byVehicleUUID[serverVehicleID] ?? []

            // Fallback: sensors recorded with a stale/different vehicleID are grouped by name
            if serverList.isEmpty {
                let nameLower = vehicles[idx].name.lowercased()
                serverList = byVehicleName[nameLower] ?? []
            }

            // Also pick up UUID-keyed sensors that reference a stale vehicleID but
            // whose vehicleName matches — handles the local-UUID drift scenario.
            if serverList.isEmpty {
                let nameLower = vehicles[idx].name.lowercased()
                serverList = byVehicleUUID.values
                    .flatMap { $0 }
                    .filter { $0.vehicleName.lowercased() == nameLower }
            }

            let newPaired: [PairedSensor] = serverList.compactMap { s in
                let brandTag = SensorBrandTag(rawValue: s.brand) ?? .other
                let mac      = Self.extractTMSMac(from: s.sensorID)

                // Reuse existing PairedSensor (preserves BLE UUID for live matching)
                let existing: PairedSensor? = vehicles[idx].pairedSensors.first { ps in
                    if let mac { return ps.macAddress == mac }
                    if let uuid = UUID(uuidString: s.sensorID) { return ps.id == uuid }
                    // Non-BLE sensors (trackers…): sensorID stored in macAddress
                    return ps.macAddress == s.sensorID
                }

                let uuid: UUID
                if let existing {
                    uuid = existing.id
                } else if mac == nil, let parsed = UUID(uuidString: s.sensorID) {
                    uuid = parsed
                } else {
                    uuid = UUID()
                }

                // For non-BLE sensors (e.g. tracker), store sensorID in macAddress
                // so the next sync can find the existing entry without generating a new UUID.
                let stableAddress: String?
                if let mac {
                    stableAddress = mac
                } else if brandTag == .tracker || (mac == nil && UUID(uuidString: s.sensorID) == nil) {
                    stableAddress = s.sensorID
                } else {
                    stableAddress = existing?.macAddress
                }

                return PairedSensor(
                    id:                uuid,
                    macAddress:        stableAddress,
                    brand:             brandTag,
                    customLabel:       s.sensorName,
                    wheelPosition:     WheelPosition(rawValue: s.wheelPosition ?? ""),
                    targetPressureBar: s.targetPressureBar,
                    pairedAt:          existing?.pairedAt ?? Date()
                )
            }

            if vehicles[idx].pairedSensors != newPaired {
                vehicles[idx].pairedSensors = newPaired
                changed = true
            }
        }
        if changed { saveVehicles() }
    }

    /// Extracts the 3-byte MAC string from a TMS stable sensor ID.
    /// e.g. "TMS-A703BC" → "A7:03:BC"
    private static func extractTMSMac(from sensorID: String) -> String? {
        if sensorID.hasPrefix("TMS-") {
            let hex = String(sensorID.dropFirst(4))
            guard hex.count == 6 else { return nil }
            return stride(from: 0, to: 6, by: 2).map { i -> String in
                let s = hex.index(hex.startIndex, offsetBy: i)
                let e = hex.index(s, offsetBy: 2)
                return String(hex[s..<e])
            }.joined(separator: ":")
        }
        if sensorID.hasPrefix("STIHL-") {
            let hex = String(sensorID.dropFirst(6))
            guard hex.count == 12 else { return nil }
            return stride(from: 0, to: 12, by: 2).map { i -> String in
                let s = hex.index(hex.startIndex, offsetBy: i)
                let e = hex.index(s, offsetBy: 2)
                return String(hex[s..<e])
            }.joined(separator: ":")
        }
        return nil
    }

    // MARK: - Slow Puncture Detection
    // NOTE: Previously used local history; now requires server-side data.
    // slowPunctureDetected() removed — use server analytics if needed.

    // MARK: - Persistence

    private func load() {
        // Load assets
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
        // ── One-shot migration: fix assets whose assetTypeID is a server-generated UUID ──
        // Previous broken syncs may have stored random UUIDs (e.g. "D2EF02FA-...") instead
        // of canonical slugs ("vehicle", "tool"). Detect these and reset them so the next
        // server sync will re-match by name and apply the correct typeID.
        let knownTypeIDs = Set(assetTypes.map(\.id))
        var needsSave = false
        for idx in vehicles.indices {
            let typeID = vehicles[idx].assetTypeID
            // If the typeID looks like a UUID and isn't a known type, it's stale data
            if UUID(uuidString: typeID) != nil, !knownTypeIDs.contains(typeID) {
                vehicles[idx].assetTypeID = AssetType.vehicle.id  // safe fallback
                // Do NOT clear serverVehicleID — preserves server-matching on next sync
                needsSave = true
            }
        }
        if needsSave { saveVehicles() }
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
