import Foundation
import SwiftUI

struct BLEDevice: Identifiable, Equatable, Hashable {
    var id: UUID            // CBPeripheral.identifier (mutable: AirTag UUIDs rotate)
    var name: String?
    var rssi: Int           // dBm
    var manufacturerName: String?
    var manufacturerData: Data?
    var serviceUUIDs: [String]
    var txPowerLevel: Int?
    var isConnectable: Bool
    var lastSeen: Date
    var seenCount: Int      // number of packets received
    /// Stable hardware identifier: 3 LSB bytes of BLE MAC address (from TMS frames 0x04/0x07).
    /// Persisted across app reinstalls — use this as the canonical sensor ID when available.
    var macAddress: String?  // e.g. "A7:03:BC"

    var displayName: String { name ?? "Unknown" }

    /// Stable sensor identifier: MAC-based when available, CBPeripheral UUID fallback.
    /// Use this as `sensorID` in server payloads to survive app reinstalls.
    var stableSensorID: String {
        macAddress.map { "TMS-" + $0.replacingOccurrences(of: ":", with: "") } ?? id.uuidString
    }

    // MARK: - Signal Strength

    enum SignalStrength {
        case excellent  // > -55 dBm
        case good       // -55 to -70
        case fair       // -70 to -85
        case poor       // < -85

        var label: String {
            switch self {
            case .excellent: return "Excellent"
            case .good:      return "Good"
            case .fair:      return "Fair"
            case .poor:      return "Poor"
            }
        }
        var color: Color {
            switch self {
            case .excellent: return .green
            case .good:      return .blue
            case .fair:      return .orange
            case .poor:      return .red
            }
        }
        /// Number of filled bars (out of 4)
        var bars: Int {
            switch self {
            case .excellent: return 4
            case .good:      return 3
            case .fair:      return 2
            case .poor:      return 1
            }
        }
    }

    var signalStrength: SignalStrength {
        switch rssi {
        case (-55)...0:   return .excellent
        case (-70)...(-56): return .good
        case (-85)...(-71): return .fair
        default:            return .poor
        }
    }

    /// Estimated distance in metres (log-distance path loss, n=2).
    /// Reference power (RSSI at 1 m) is taken from txPowerLevel **only** when it
    /// looks like a calibrated RSSI-at-1m value (≤ −20 dBm).  Devices such as
    /// iPhones advertise their actual TX power (+4…+20 dBm), which would produce
    /// wildly wrong distances, so we fall back to −59 dBm in that case.
    var estimatedDistance: Double? {
        let ref: Double
        if let tx = txPowerLevel, tx <= -20 {
            ref = Double(tx)        // calibrated RSSI@1m (AirTags, some beacons)
        } else if airtagData != nil {
            ref = -59               // Apple first-party reference power @ 1 m
        } else if txPowerLevel != nil {
            ref = -59               // TX power present but not a valid RSSI@1m — use default
        } else {
            return nil
        }
        return pow(10, (ref - Double(rssi)) / 20.0)
    }

    /// Decoded data if the device is a Michelin TMS tyre pressure sensor
    var tmsData: TMSData?

    /// Decoded data if the device is a STIHL Smart Connector sensor
    var stihlConnectorData: StihlConnectorData?

    /// Decoded data if the device is a STIHL Smart Battery
    var stihlBatteryData: StihlBatteryData?

    /// Decoded data if the device is an ELA Innovation beacon
    var elaData: ELAData?

    /// Decoded data if the device is an Apple AirTag / FindMy item
    var airtagData: AirTagData?

    /// Unified sensor brand (nil = generic BLE device)
    var sensorBrand: SensorBrand? {
        if tmsData != nil                                        { return .michelin }
        if stihlConnectorData != nil || stihlBatteryData != nil { return .stihl }
        if elaData != nil                                       { return .ela }
        if airtagData != nil                                    { return .airtag }
        return nil
    }

    enum SensorBrand {
        case michelin, stihl, ela, airtag
        var displayName: String {
            switch self {
            case .michelin: return "Michelin"
            case .stihl:    return "STIHL"
            case .ela:      return "ELA Innovation"
            case .airtag:   return "AirTag"
            }
        }
        var badgeColor: Color {
            switch self {
            case .michelin: return .orange
            case .stihl:    return .yellow
            case .ela:      return .cyan
            case .airtag:   return .blue
            }
        }
        var systemImage: String {
            switch self {
            case .michelin: return "gauge.open.with.lines.needle.33percent"
            case .stihl:    return "waveform.badge.exclamationmark"
            case .ela:      return "location.fill.viewfinder"
            case .airtag:   return "airtag"
            }
        }
    }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

// MARK: - Michelin TMS Data (official BLE RF Frame spec)

/// Decoded data from the BLE manufacturer payload of a Michelin TMS sensor.
/// Michelin Company ID: 0x0828 (LE: 0x28 0x08)
/// Common layout: [0-1]=CompanyID  [2]=BeaconFlag(0x01)  [3]=FrameType
///                [4]=Temp (raw-60 = °C)  [5]=Vbatt ((raw+100)/100 = V)
struct TMSData: Equatable {

    // -- Identification -------------------------------------------------
    var companyID: UInt16?      // 0x0828 pour Michelin
    var frameType: Int          // 1=A, 2=B, 3=C, 4=D, 5=kPa, 6=sans pression, 7=D-v2, 8/0xA/0xB=H

    // -- Sensors --------------------------------------------------------
    var pressureBar: Double?    // pressure in bar (converted from mBar or kPa)
    var temperatureC: Double?   // temperature °C = rawByte - 60
    var vbattVolts: Double?     // battery voltage V = (rawByte + 100) / 100

    // -- Identification pneu --------------------------------------------
    var tireModel: String?      // 3 octets ASCII ex: "CUP", "P4S"
    var tireTypeID: UInt32?     // ID 32-bit (frames 5/6)

    // -- État interne --------------------------------------------------
    var state: Int?             // state machine [0;4]
    var frameCounter: UInt32?   // compteur trames little-endian
    var firmwareVersion: Int?   // version firmware
    var macLSB: String?         // 3 LSBytes MAC (frame D) ex: "A7:03:BC"

    // -- Raw data -------------------------------------------------------
    var rawPayload: [UInt8]     // payload after company ID (bytes[2...])
    var fullRawData: [UInt8]    // complete manufacturer data (company ID included)
    var decodingConfidence: DecodingConfidence

    enum DecodingConfidence {
        case validated   // official Michelin format confirmed
        case likely      // likely format
        case raw         // not decoded, raw bytes only
    }

    // -- Conversions ----------------------------------------------------
    var pressurePSI: Double? { pressureBar.map { $0 * 14.5038 } }
    var pressurekPa: Double? { pressureBar.map { $0 * 100.0 } }

    /// Battery estimate 0-100% from voltage (range 2.5V–3.0V)
    var vbattPct: Int? {
        guard let v = vbattVolts else { return nil }
        return max(0, min(100, Int((v - 2.5) / 0.5 * 100)))
    }

    /// Nom lisible du type de trame
    var frameTypeName: String {
        switch frameType {
        case 0x01: return "A — Temp + Model"
        case 0x02: return "B — Temp + Counter"
        case 0x03: return "C — Temp + Pressure + Model"
        case 0x04: return "D — Temp + Pressure + MAC"
        case 0x05: return "5 — Pressure kPa"
        case 0x06: return "6 — No pressure"
        case 0x07: return "7 — Pressure + MAC v2"
        case 0x08: return "H — History"
        case 0x0A: return "H+A — History + Accel."
        case 0x0B: return "H+P — History + Pressure + Accel."
        default:   return "0x\(String(format: "%02X", frameType))"
        }
    }

    /// Hex dump complet
    var hexDump: String {
        fullRawData.map { String(format: "%02X", $0) }.joined(separator: " ")
    }

    /// Annotated hex dump: [company_id] beacon frameType temp vbatt ...
    var annotatedHex: String {
        guard fullRawData.count >= 6 else { return hexDump }
        let parts = fullRawData.enumerated().map { (i, b) -> String in
            let hex = String(format: "%02X", b)
            switch i {
            case 0, 1: return hex  // company ID
            case 2:    return "[\(hex)]"  // beacon flag
            case 3:    return "{\(hex)}"  // frame type
            case 4:    return "T:\(hex)"  // temp
            case 5:    return "V:\(hex)"  // vbatt
            default:   return hex
            }
        }
        return parts.joined(separator: " ")
    }
}

extension BLEDevice {
    /// True if the device is a Michelin TMS sensor (detected by company ID 0x0828 or name)
    var isTMSDevice: Bool {
        if tmsData != nil { return true }
        if manufacturerName == "Michelin" { return true }
        guard let n = name else { return false }
        let u = n.uppercased()
        return u.contains("MICHELIN") || u.hasPrefix("TMS") || u.hasPrefix("TPMS")
    }

    /// True if the device broadcasts Apple FindMy payloads (AirTag / FindMy network).
    /// Also returns true when `airtagData` was populated synthetically (iOS strips mf data for owner devices).
    var isAirTagDevice: Bool {
        if airtagData != nil { return true }
        return manufacturerName == "Apple" && appleDeviceCategory == "FindMy"
    }

    /// True if the device is any known sensor (Michelin, STIHL, ELA, AirTag)
    var isKnownSensor: Bool { sensorBrand != nil || isTMSDevice || isAirTagDevice }
}

// MARK: - Known Apple BLE Category

extension BLEDevice {
    /// Identifies Apple device types from manufacturer data (type byte)
    var appleDeviceCategory: String? {
        guard manufacturerName == "Apple",
              let data = manufacturerData, data.count >= 2 else { return nil }
        let type_ = data[0]
        switch type_ {
        case 0x02: return "iBeacon"
        case 0x05: return "AirDrop"
        case 0x07: return "AirPods"
        case 0x09: return "AirPlay"
        case 0x0A: return "Hey Siri"
        case 0x0B: return "AirPods Case"
        case 0x0C: return "Handoff"
        case 0x0D: return "Wi-Fi Settings"
        case 0x0E: return "Instant Hotspot"
        case 0x0F: return "Nearby Action"
        case 0x10: return "Nearby Info"
        case 0x12: return "FindMy"
        case 0x1E: return "FindMy"   // AirTag near-owner frame (iOS)
        default:   return nil
        }
    }
}

// MARK: - STIHL Smart Connector Data (Company ID 0x03DD, Service UUID 0xFE43)

/// Decoded payload for a STIHL Smart Connector (protocol 0x01).
/// Full frame layout (bytes in raw manufacturer data, incl. Company ID):
///   [0-1]   Company ID 0x03DD (LE: 0xDD 0x03)
///   [2]     Protocol identifier: 0x01 = App API
///   [3-8]   MAC address, lowest byte first
///   [9-12]  Counter (uint32 LE, seconds of operation)
///   [13]    Product ID: 0x01 = STIHL Smart Connector 1.0
///   [14-15] Hardware version low/high (e.g. 0x28 0x00 = v40.0)
///   [16-17] Software version low/high
///   [18]    TX Power setting [dBm], signed 2's complement
///   [19]    Status flags (Bit0=connectable, Bit1=SW error, Bit2=HW error)
///   [20]    Battery voltage: V = byte * 0.05
///   [21]    Temperature [°C] signed; 0x80 = not implemented
struct StihlConnectorData: Equatable {
    var protocolID: UInt8         // 0x01 = App API, 0x02 = Developer API
    var macAddress: String        // "XX:XX:XX:XX:XX:XX" highest byte first
    var counterSeconds: UInt32    // total operating time in seconds
    var productID: UInt8          // 0x01 = Smart Connector 1.0
    var hwVersionLow: UInt8
    var hwVersionHigh: UInt8
    var swVersionLow: UInt8
    var swVersionHigh: UInt8
    var txPowerDBm: Int8          // signed TX power setting
    var statusFlags: UInt8        // bitmask
    var batteryVolts: Double      // byte * 0.05 V
    var temperatureC: Int?        // nil when 0x80 (not implemented)
    var fullRawData: [UInt8]

    var productName: String {
        switch productID {
        case 0x01: return "STIHL Smart Connector 1.0"
        default:   return "STIHL Product 0x\(String(format: "%02X", productID))"
        }
    }
    var hwVersion: String { "\(hwVersionHigh).\(hwVersionLow)" }
    var swVersion: String { "\(swVersionHigh).\(swVersionLow)" }
    var batteryPercent: Int {
        // CR2032 3V battery: 2.0V = 0%, 3.0V = 100%
        max(0, min(100, Int((batteryVolts - 2.0) / 1.0 * 100)))
    }
    var isConnectable: Bool  { statusFlags & 0x01 != 0 }
    var hasSoftwareError: Bool { statusFlags & 0x02 != 0 }
    var hasHardwareError: Bool { statusFlags & 0x04 != 0 }
    var hexDump: String { fullRawData.map { String(format: "%02X", $0) }.joined(separator: " ") }
}

/// Decoded payload for a STIHL Smart Battery (protocol 0x06).
/// Full frame layout (22 bytes as seen by CoreBluetooth, including company ID):
///   [0-1]   Company ID 0x03DD (LE: 0xDD 0x03)
///   [2]     Protocol identifier: 0x06 = Smart Battery
///   [3]     Flags / padding (0x05)
///   [4-9]   Serial number (6 bytes, e.g. E5:97:A7:36:00:0C)
///   [10-13] Total discharge time (uint32 LE, seconds)
///   [14-16] Charging cycles (3 bytes big-endian, e.g. 00 00 02 → 2)
///   [17]    Health (raw byte 0-255)
///   [18]    State ID (0=Idle, 1=Discharge, 2=Charging, 3=Full, 4=Error)
///   [19]    Charge % (0-100)
///   [20-21] Unknown
struct StihlBatteryData: Equatable {
    var serialNumber: String      // hex representation of 6 bytes
    var totalDischargeTime: UInt32 // seconds or cycles
    var chargingCycles: UInt32
    var healthPercent: UInt8
    var stateID: UInt8
    var chargePercent: UInt8
    var fullRawData: [UInt8]

    var stateLabel: String {
        switch stateID {
        case 0x00: return "Idle"
        case 0x01: return "Discharging"
        case 0x02: return "Charging"
        case 0x03: return "Full"
        case 0x04: return "Error"
        default:   return "0x\(String(format: "%02X", stateID))"
        }
    }
    var hexDump: String { fullRawData.map { String(format: "%02X", $0) }.joined(separator: " ") }
}

// MARK: - ELA Innovation Data (Company ID 0x0757)

/// Decoded payload for an ELA Innovation beacon.
/// Manufacturer data layout (Mfr Spec mode, firmware ≥2.0.0):
///   [0-1]  Company ID 0x0757 (LE: 0x57 0x07)
///   [2]    Data type / format ID:
///            0x06 = ID format
///            0x12 = Temperature (T) format
///            0x21 = RHT (humidity+temp) format
///            0x32 = MAG format
///            0xF1 = Battery capacity (in scan response)
///            0xF2 = Battery voltage (in scan response)
///   [3...]  Payload bytes (type-dependent)
/// Service Data mode (firmware <2.0.0): no manufacturer data, detection by name only.
/// Product type identified by device name prefix:
///   "C ID …" = ELA Blue Coin ID
///   "P ID …" = ELA Blue Puck ID
struct ELAData: Equatable {
    var dataType: UInt8           // 0x06 = ID, 0x12 = Temp, 0x21 = RHT, etc.
    var payload: [UInt8]          // bytes after dataType
    var productVariant: ProductVariant
    var mfrNumber: String?        // 6-byte MFR_Num hex (ID format, e.g. "AABBCCDDEEFF")
    var fullRawData: [UInt8]
    /// True when detected only by device name (Service Data mode / no mfr data)
    var detectedByNameOnly: Bool = false

    enum ProductVariant {
        case coin   // "C ID …" — ELA Blue Coin
        case puck   // "P ID …" — ELA Blue Puck
        case unknown

        var displayName: String {
            switch self {
            case .coin:    return "ELA Blue Coin"
            case .puck:    return "ELA Blue Puck"
            case .unknown: return "ELA Beacon"
            }
        }
        var systemImage: String {
            switch self {
            case .coin:    return "smallcircle.filled.circle"
            case .puck:    return "circle.hexagongrid.fill"
            case .unknown: return "location.fill.viewfinder"
            }
        }
        var variantID: String {
            switch self {
            case .coin:    return "coin"
            case .puck:    return "puck"
            case .unknown: return "unknown"
            }
        }
    }
    var hexDump: String { fullRawData.map { String(format: "%02X", $0) }.joined(separator: " ") }
}

// MARK: - Apple AirTag / FindMy Data (Company ID 0x004C, type 0x12)

/// Decoded payload for an Apple AirTag or third-party FindMy item.
/// Manufacturer data layout (company ID stripped by CoreBluetooth):
///   [0]    Type   = 0x12 (FindMy)
///   [1]    Length = 0x19 (25 bytes follow)
///   [2]    Status byte:
///             bits [7:6] = battery level (11=full, 10=medium, 01=low, 00=critical)
///             bit  [3]   = separated from owner (1 = item not near owner / alerting)
///   [3-24] Rotating public key material (22 bytes, changes every ~15 min)
struct AirTagData: Equatable {

    var statusByte: UInt8
    /// First 8 bytes of the rotating public key (changes every ~15 min by design)
    var publicKeyPrefix: [UInt8]
    var fullRawData: [UInt8]

    // MARK: Battery

    enum BatteryLevel: Int {
        case full     = 0   // FindMy spec: bits[7:6] = 0b00 → Full
        case medium   = 1
        case low      = 2
        case critical = 3   //                           0b11 → Critical

        var label: String {
            switch self {
            case .critical: return "Critical"
            case .low:      return "Low"
            case .medium:   return "Medium"
            case .full:     return "Full"
            }
        }
        var color: Color {
            switch self {
            case .critical: return .red
            case .low:      return .orange
            case .medium:   return .yellow
            case .full:     return .green
            }
        }
        var systemImage: String {
            switch self {
            case .critical: return "battery.0percent"
            case .low:      return "battery.25percent"
            case .medium:   return "battery.50percent"
            case .full:     return "battery.100percent"
            }
        }
        /// Approximate % for display (4 discrete levels only)
        var approximatePercent: Int {
            switch self {
            case .critical: return 0
            case .low:      return 25
            case .medium:   return 60
            case .full:     return 100
            }
        }
    }

    var batteryLevel: BatteryLevel {
        BatteryLevel(rawValue: Int((statusByte >> 6) & 0x03)) ?? .full
    }

    /// true when the item is alerting — not in proximity of its owner
    var isSeparated: Bool { statusByte & 0x08 != 0 }

    var hexDump: String { fullRawData.map { String(format: "%02X", $0) }.joined(separator: " ") }
}
