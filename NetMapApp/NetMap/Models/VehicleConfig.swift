import Foundation
import SwiftUI

// MARK: - Wheel Position

enum WheelPosition: String, CaseIterable, Codable, Identifiable {
    case frontLeft  = "FL"
    case frontRight = "FR"
    case rearLeft   = "RL"
    case rearRight  = "RR"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .frontLeft:  return "Front Left"
        case .frontRight: return "Front Right"
        case .rearLeft:   return "Rear Left"
        case .rearRight:  return "Rear Right"
        }
    }

    var shortLabel: String { rawValue }

    /// Normalized position (0…1) within the vehicle silhouette
    var relativeX: Double {
        switch self {
        case .frontLeft, .rearLeft:   return 0.18
        case .frontRight, .rearRight: return 0.82
        }
    }

    var relativeY: Double {
        switch self {
        case .frontLeft, .frontRight: return 0.12
        case .rearLeft, .rearRight:   return 0.80
        }
    }
}

// MARK: - Sensor Brand Tag (Codable mirror of BLEDevice.SensorBrand)

/// Codable brand identifier for persisting paired sensor types.
enum SensorBrandTag: String, Codable, CaseIterable, Identifiable {
    case michelin = "michelin"
    case stihl    = "stihl"
    case ela      = "ela"
    case airtag   = "airtag"
    case tracker  = "tracker"
    case other    = "other"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .michelin: return "Michelin TMS"
        case .stihl:    return "STIHL"
        case .ela:      return "ELA Innovation"
        case .airtag:   return "AirTag"
        case .tracker:  return "GPS Tracker"
        case .other:    return "Generic BLE"
        }
    }

    var systemImage: String {
        switch self {
        case .michelin: return "gauge.open.with.lines.needle.33percent"
        case .stihl:    return "waveform.badge.exclamationmark"
        case .ela:      return "location.fill.viewfinder"
        case .airtag:   return "airtag"
        case .tracker:  return "location.fill"
        case .other:    return "dot.radiowaves.left.and.right"
        }
    }

    var badgeColor: Color {
        switch self {
        case .michelin: return .orange
        case .stihl:    return .yellow
        case .ela:      return .cyan
        case .airtag:   return .blue
        case .tracker:  return .green
        case .other:    return .secondary
        }
    }

    /// Whether this sensor type supports wheel-position mapping
    var supportsTMSMapping: Bool { self == .michelin }
}

// MARK: - Asset Type

/// Describes a category of asset (Vehicle, Tool, or custom admin-defined types).
struct AssetType: Codable, Identifiable, Equatable {
    var id: String                          // "vehicle", "tool", or UUID string for custom
    var name: String
    var systemImage: String
    var allowedBrands: [SensorBrandTag]     // which sensors can be paired
    var isBuiltIn: Bool                     // prevents deletion

    // ── Built-in types ──────────────────────────────────────────────
    static let vehicle = AssetType(
        id: "vehicle",
        name: "Vehicle",
        systemImage: "car.fill",
        allowedBrands: [.michelin, .airtag, .ela],
        isBuiltIn: true
    )
    static let tool = AssetType(
        id: "tool",
        name: "Tool",
        systemImage: "wrench.and.screwdriver.fill",
        allowedBrands: [.airtag, .ela, .stihl],
        isBuiltIn: true
    )
    static let builtInTypes: [AssetType] = [.vehicle, .tool]
}

// MARK: - Paired Sensor

/// A sensor of any type paired to a vehicle.
/// TMS sensors may have a wheelPosition + targetPressureBar.
struct PairedSensor: Codable, Identifiable, Equatable {
    var id: UUID                       // CBPeripheral.identifier (BLE UUID) — may change after reinstall
    /// Stable hardware key for post-reinstall / UUID-change recovery.
    /// Set at pairing time by PairSensorSheet for non-TMS sensors:
    ///   – TMS             : 3-byte MAC from frames 0x04/0x07 (e.g. "A7:03:BC"), stored lazily
    ///   – STIHL Connector : full hardware MAC from BLE frame (e.g. "AA:BB:CC:DD:EE:FF")
    ///   – AirTag          : device name (MAC rotates by Apple design; name is best hint)
    ///   – Others          : nil
    var macAddress: String?
    var brand: SensorBrandTag
    var customLabel: String?           // user-defined label
    var wheelPosition: WheelPosition?  // non-nil for TMS sensors
    var targetPressureBar: Double?     // target pressure — TMS only
    var pairedAt: Date

    /// Stable hardware ID matching the server's sensorID field.
    /// Uses MAC address when known (e.g. "TMS-A703BC"), falls back to UUID string.
    var stableSensorID: String {
        guard let mac = macAddress else { return id.uuidString }
        return "TMS-\(mac.replacingOccurrences(of: ":", with: ""))"
    }

    var displayLabel: String {
        if let l = customLabel, !l.isEmpty { return l }
        if let pos = wheelPosition { return pos.label }
        return brand.displayName
    }
}

// MARK: - Asset (formerly VehicleConfig)

/// Typealias so existing code keeps compiling while we migrate to "Asset" terminology.
typealias Asset = VehicleConfig

struct VehicleConfig: Codable, Identifiable {
    var id: UUID = UUID()
    /// Server-authoritative UUID from GET /api/vehicles.
    var serverVehicleID: UUID?

    // ── Asset type ────────────────────────────────────────
    var assetTypeID: String = AssetType.vehicle.id   // "vehicle" | "tool" | custom

    // ── Common identity ───────────────────────────────────
    var name: String

    // ── Vehicle-specific fields ───────────────────────────
    var brand: String?           // manufacturer, e.g. "Volkswagen"
    var model: String?           // model name, e.g. "Golf 8 GTI"
    var year: Int?               // model year, e.g. 2023
    var vin: String?             // Vehicle Identification Number (17 chars)
    var vrn: String?             // Vehicle Registration Number / plate

    // ── Tool-specific fields ──────────────────────────────
    var serialNumber: String?    // tool serial number
    var toolType: String?        // e.g. "Chainsaw", "Hedge Trimmer"

    // ── Paired sensors ────────────────────────────────────
    var pairedSensors: [PairedSensor] = []

    init(id: UUID = UUID(), name: String, assetTypeID: String = AssetType.vehicle.id) {
        self.id = id
        self.name = name
        self.assetTypeID = assetTypeID
    }

    // MARK: - Convenience helpers

    /// Asset type resolved from the stored ID against the provided list (falls back to vehicle)
    func resolvedAssetType(from types: [AssetType]) -> AssetType {
        types.first { $0.id == assetTypeID } ?? .vehicle
    }

    /// Which sensor brands are allowed to pair with this asset
    func allowedBrands(from types: [AssetType]) -> [SensorBrandTag] {
        resolvedAssetType(from: types).allowedBrands
    }

    /// Short subtitle for list cells
    var subtitle: String {
        if assetTypeID == AssetType.tool.id {
            let parts: [String?] = [toolType, serialNumber]
            let joined = parts.compactMap { $0 }.joined(separator: " · ")
            return joined.isEmpty ? "Tool" : joined
        }
        let parts: [String?] = [brand, model, year.map { String($0) }]
        let joined = parts.compactMap { $0 }.joined(separator: " ")
        return joined.isEmpty ? "No details" : joined
    }

    /// Paired TMS sensors that have a wheel position assigned
    var tmsSensors: [PairedSensor] {
        pairedSensors.filter { $0.brand == .michelin && $0.wheelPosition != nil }
    }

    /// Sensor mapped to a given wheel position (TMS only)
    func sensor(for position: WheelPosition) -> PairedSensor? {
        pairedSensors.first { $0.wheelPosition == position }
    }

    /// Assign / replace the TMS sensor for a wheel position
    mutating func setTMSSensor(_ sensor: PairedSensor) {
        pairedSensors.removeAll { $0.wheelPosition == sensor.wheelPosition && $0.brand == .michelin }
        pairedSensors.append(sensor)
    }

    /// Remove TMS sensor at a given position
    mutating func removeSensor(for position: WheelPosition) {
        pairedSensors.removeAll { $0.wheelPosition == position }
    }

    /// Pair any sensor (adds or replaces by UUID or by hardware key).
    /// Deduplicates both by CBPeripheral UUID AND by macAddress so that
    /// re-pairing an AirTag (whose UUID rotates) doesn't create a second entry.
    mutating func pairSensor(_ sensor: PairedSensor) {
        pairedSensors.removeAll { $0.id == sensor.id }
        if let mac = sensor.macAddress, !mac.isEmpty {
            pairedSensors.removeAll { $0.macAddress == mac }
        }
        pairedSensors.append(sensor)
    }

    /// Unpair a sensor by BLE UUID
    mutating func unpairSensor(id: UUID) {
        pairedSensors.removeAll { $0.id == id }
    }

    /// True if the given BLE UUID is already paired to this vehicle
    func isPaired(_ sensorID: UUID) -> Bool {
        pairedSensors.contains { $0.id == sensorID }
    }
}

// MARK: - Pressure Status

enum PressureStatus {
    case ok
    case warning
    case danger

    var label: String {
        switch self {
        case .ok:      return "OK"
        case .warning: return "WARNING"
        case .danger:  return "DANGER"
        }
    }

    var color: Color {
        switch self {
        case .ok:      return .green
        case .warning: return .orange
        case .danger:  return .red
        }
    }

    var systemImage: String {
        switch self {
        case .ok:      return "checkmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .danger:  return "xmark.octagon.fill"
        }
    }
}

extension PressureStatus {
    static func evaluate(actual: Double, target: Double) -> PressureStatus {
        guard actual >= 1.0 else { return .danger }
        let delta = abs(actual - target)
        if delta <= 0.2 { return .ok }
        if delta <= 0.5 { return .warning }
        return .danger
    }
}
