import Foundation
import CoreBluetooth
import os.log

private let bleLog = Logger(subsystem: "com.phil.netmap.app", category: "BLE")

@MainActor
class BLEScanner: NSObject, ObservableObject {

    @Published var devices: [BLEDevice] = []
    @Published var isScanning = false
    @Published var bluetoothState: CBManagerState = .unknown
    @Published var errorMessage: String?
    /// True when running in background mode (allowDuplicates:false, no cycle timer).
    @Published var isInBackgroundMode = false

    private var centralManager: CBCentralManager!
    private var scanTimer: Timer?
    /// Set to true by willRestoreState so that centralManagerDidUpdateState
    /// restarts the scan as soon as Bluetooth reaches .poweredOn.
    private var shouldRestartScan = false

    /// Called synchronously from `didDiscover`, on the main thread, every time a BLE
    /// advertisement is received and `devices` has been updated.
    /// Preferred over a Combine sink on `$devices` for background push because it fires
    /// directly inside CoreBluetooth's wakeup window — no async actor hops.
    var onDeviceDiscovered: (() -> Void)?

    /// Persisted map: CBPeripheral.identifier.uuidString → TMS macLSB (frames 0x04/0x07).
    /// Survives app reinstalls so a sensor's physical MAC can be re-linked to a new CBPeripheral UUID.
    private var knownMacs: [String: String] = [:]

    /// Last known Stihl data per CBPeripheral UUID — survives device going out of BLE range.
    /// Updated on every successful parse; used by SensorDetailView as fallback when not live.
    var lastKnownStihlConnector: [UUID: StihlConnectorData] = [:]
    var lastKnownStihlBattery:   [UUID: StihlBatteryData]   = [:]
    var lastKnownAirTagData:     [UUID: AirTagData]         = [:]
    /// Keyed by AirTag name — survives UUID rotation (iOS always rotates the CBPeripheral ID).
    var lastKnownAirTagDataByName: [String: AirTagData]     = [:]
    var lastKnownELAData:        [UUID: ELAData]            = [:]
    private static let knownMacsKey = "ble_tms_macs_v1"

    // MARK: - Company ID → Fabricant (Bluetooth SIG assigned numbers)
    private static let companyNames: [UInt16: String] = [
        0x0006: "Microsoft",
        0x004C: "Apple",
        0x0059: "Nordic Semiconductor",
        0x0075: "Samsung",
        0x00E0: "Google",
        0x008C: "Qualcomm",
        0x00D0: "Plantronics",
        0x00F0: "Samsung (Mobile)",
        0x0131: "Fitbit",
        0x0157: "Garmin",
        0x0171: "Amazon",
        0x01FF: "LG Electronics",
        0x02E5: "Espressif Systems",
        0x0310: "OnePlus",
        0x0499: "Ruuvi Innovations",
        0x004F: "Polar Electro",
        0x0822: "Xiaomi",
        0x02D5: "Jabra",
        0x01D5: "Sony",
        0x0046: "Bose",
        0x038F: "BOSE",
        0x08D1: "Tile",
        0x0641: "Withings",
        0x0089: "Casio",
        0x00E5: "Nintendo",
        0x0828: "Michelin",          // Michelin TMS sensors
        0x03DD: "STIHL",              // STIHL Smart Connector / Battery (Andreas Stihl AG)
        0x0757: "ELA Innovation",     // ELA Innovation beacons
    ]

    override init() {
        super.init()
        // Load persisted MAC map
        if let data = UserDefaults.standard.data(forKey: Self.knownMacsKey),
           let dict = try? JSONDecoder().decode([String: String].self, from: data) {
            knownMacs = dict
        }
        // queue: .main permet d'appeler les delegates sur le main thread
        // restoreIdentifier: requis pour la restauration d'état CoreBluetooth en arrière-plan (iOS)
        #if os(iOS)
        centralManager = CBCentralManager(delegate: self, queue: .main,
                                          options: [CBCentralManagerOptionRestoreIdentifierKey: "com.netmap.central"])
        #else
        centralManager = CBCentralManager(delegate: self, queue: .main)
        #endif
    }

    private func saveMacs() {
        if let data = try? JSONEncoder().encode(knownMacs) {
            UserDefaults.standard.set(data, forKey: Self.knownMacsKey)
        }
    }

    // MARK: - Public API

    /// Foreground scan: allowDuplicates = true, 30 s cycle timer for fresh advertising data.
    func startScan() {
        guard bluetoothState == .poweredOn else {
            errorMessage = stateDescription(bluetoothState)
            return
        }
        errorMessage = nil
        devices.removeAll()
        isScanning = true
        isInBackgroundMode = false

        centralManager.scanForPeripherals(
            withServices: nil,
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: true]
        )

        // Cycle the CoreBluetooth scan every 30 s so the OS doesn't coalesce
        // duplicate advertisements. The device list is NOT cleared — existing
        // entries are simply refreshed as they re-advertise.
        scanTimer?.invalidate()
        scanTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.isScanning else { return }
                self.centralManager.stopScan()
                self.centralManager.scanForPeripherals(
                    withServices: nil,
                    options: [CBCentralManagerScanOptionAllowDuplicatesKey: true]
                )
            }
        }
    }

    /// Background scan: restart the scan with allowDuplicates:false.
    /// iOS silently drops scan results for allowDuplicates:true scans when the app is
    /// backgrounded — the only supported background scan mode is allowDuplicates:false.
    /// Each device is delivered once per scan start, which is enough since SensorPushService
    /// already throttles pushes to 300 s per sensor anyway.
    func startBackgroundScan() {
        guard bluetoothState == .poweredOn else { return }
        // Cancel the foreground restart timer.
        scanTimer?.invalidate()
        scanTimer = nil
        isScanning = true
        isInBackgroundMode = true
        bleLog.error("[BLE] entering background scan (allowDuplicates:false)")
        // Must explicitly restart the scan: iOS stops delivering results for an
        // allowDuplicates:true scan once the app moves to background.
        centralManager.stopScan()
        centralManager.scanForPeripherals(withServices: nil,
                                          options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
    }

    /// Called when the app moves to the foreground — switches back to full scan.
    func enterForeground() {
        guard bluetoothState == .poweredOn else { return }
        isInBackgroundMode = false
        // Re-start with duplicates + cycle timer
        startScan()
    }

    /// Called when the app moves to the background — switches to battery-efficient scan.
    func enterBackground() {
        guard isScanning else { return }
        startBackgroundScan()
    }

    func stopScan() {
        centralManager.stopScan()
        scanTimer?.invalidate()
        scanTimer = nil
        isScanning = false
    }

    // MARK: - Helpers

    private func parseManufacturer(from data: Data?) -> (name: String?, data: Data?) {
        guard let data, data.count >= 2 else { return (nil, nil) }
        let companyID = UInt16(data[0]) | (UInt16(data[1]) << 8)
        let name = Self.companyNames[companyID]
        let payload = data.count > 2 ? data.subdata(in: 2..<data.count) : nil
        return (name, payload)
    }

    // MARK: - Michelin TMS Decoder (official BLE RF Frame spec)

    /// Decodes manufacturer payload according to the official Michelin TMS BLE RF Frame specification.
    /// Common structure across all frames:
    ///   bytes[0-1] = Company ID 0x0828 (LE: 0x28 0x08)
    ///   bytes[2]   = TMS Beacon Flag (must be 0x01)
    ///   bytes[3]   = Frame Type
    ///   bytes[4]   = Temp raw  → °C = raw - 60  (e.g. 0x57=87 → 27°C)
    ///   bytes[5]   = Vbatt raw → V  = (raw+100)/100  (e.g. 0xC3=195+100=295 centivolt = 2.95V)
    private func parseTMSData(rawManufacturerData: Data?, deviceName: String?) -> TMSData? {
        guard let raw = rawManufacturerData, raw.count >= 6 else { return nil }
        let bytes = [UInt8](raw)

        // Verify Michelin Company ID: 0x0828 (LE: 0x28 0x08)
        let companyID = UInt16(bytes[0]) | (UInt16(bytes[1]) << 8)
        guard companyID == 0x0828 else { return nil }

        // Verify Beacon Flag
        guard bytes[2] == 0x01 else { return nil }

        let frameType  = Int(bytes[3])
        let tempC      = Double(bytes[4]) - 60.0                     // 0x57 → 87-60 = 27°C
        let vbattVolts = (Double(bytes[5]) + 100.0) / 100.0          // 0xC3 → (195+100)/100 = 2.95V
        let payload    = Array(bytes[2...])                          // bytes[2...] = payload after company ID

        var tms = TMSData(
            companyID:          companyID,
            frameType:          frameType,
            temperatureC:       tempC,
            vbattVolts:         vbattVolts,
            rawPayload:         payload,
            fullRawData:        bytes,
            decodingConfidence: .validated
        )

        switch frameType {

        case 0x01: // Frame A : Temp + Tire Model Name + Active Flag + Counter
            // bytes: [2]=beacon [3]=0x01 [4]=temp [5]=vbatt [6-8]=tireModel [9]=activeFlag [10]=counter
            if bytes.count >= 9 {
                tms.tireModel = asciiString(from: bytes, range: 6..<9)
            }

        case 0x02: // Frame B : Temp + Tire Model + State + Frame Counter (4B LE)
            // bytes: [6-8]=tireModel [9]=state [10-13]=frameCounter LE
            if bytes.count >= 9  { tms.tireModel    = asciiString(from: bytes, range: 6..<9) }
            if bytes.count >= 10 { tms.state        = Int(bytes[9]) }
            if bytes.count >= 14 { tms.frameCounter = uint32LE(bytes, at: 10) }

        case 0x03: // Frame C: Temp + Pressure mBar (uint16 LE) + Tire Model + State + Counter
            // bytes: [6-7]=pressureMbar LE  [8-10]=tireModel  [11]=state  [12-15]=frameCounter LE
            guard bytes.count >= 8 else { break }
            let mbar = UInt16(bytes[6]) | (UInt16(bytes[7]) << 8)
            tms.pressureBar = Double(mbar) / 1000.0            // mBar → bar
            if bytes.count >= 11 { tms.tireModel    = asciiString(from: bytes, range: 8..<11) }
            if bytes.count >= 12 { tms.state        = Int(bytes[11]) }
            if bytes.count >= 16 { tms.frameCounter = uint32LE(bytes, at: 12) }

        case 0x04: // Frame D: Temp + Pressure mBar (uint16 LE) + 3 LSBytes MAC + State + Counter
            // bytes: [6-7]=pressureMbar LE  [8-10]=MAC LSB  [11]=state  [12-15]=frameCounter LE
            guard bytes.count >= 8 else { break }
            let mbar = UInt16(bytes[6]) | (UInt16(bytes[7]) << 8)
            tms.pressureBar = Double(mbar) / 1000.0
            if bytes.count >= 11 {
                let macBytes = Array(bytes[8..<11])
                tms.macLSB = macBytes.reversed().map { String(format: "%02X", $0) }.joined(separator: ":")
            }
            if bytes.count >= 12 { tms.state        = Int(bytes[11]) }
            if bytes.count >= 16 { tms.frameCounter = uint32LE(bytes, at: 12) }

        case 0x05: // Frame 5: Temp + Pressure kPa (uint16 LE) + TireTypeID (32b LE) + State + Counter + FW
            // bytes: [6-9]=tireTypeID LE  [10]=state  [11-12]=counter LE  [13]=fwVersion  [14-15]=pressureKPa LE
            if bytes.count >= 10 { tms.tireTypeID      = uint32LE(bytes, at: 6) }
            if bytes.count >= 11 { tms.state           = Int(bytes[10]) }
            if bytes.count >= 13 { tms.frameCounter    = UInt32(UInt16(bytes[11]) | (UInt16(bytes[12]) << 8)) }
            if bytes.count >= 14 { tms.firmwareVersion = Int(bytes[13]) }
            if bytes.count >= 16 {
                let kpa = UInt16(bytes[14]) | (UInt16(bytes[15]) << 8)
                tms.pressureBar = Double(kpa) / 100.0           // kPa → bar
            }

        case 0x06: // Frame 6 : Temp + TireTypeID + State + Counter + FW (sans pression)
            if bytes.count >= 10 { tms.tireTypeID      = uint32LE(bytes, at: 6) }
            if bytes.count >= 11 { tms.state           = Int(bytes[10]) }
            if bytes.count >= 13 { tms.frameCounter    = UInt32(UInt16(bytes[11]) | (UInt16(bytes[12]) << 8)) }
            if bytes.count >= 14 { tms.firmwareVersion = Int(bytes[13]) }

        case 0x07: // Frame 7 (D-v2 variant): Pressure mBar + 3 LSBytes MAC + State + Counter
            guard bytes.count >= 8 else { break }
            let mbar = UInt16(bytes[6]) | (UInt16(bytes[7]) << 8)
            tms.pressureBar = Double(mbar) / 1000.0
            if bytes.count >= 11 {
                let macBytes = Array(bytes[8..<11])
                tms.macLSB = macBytes.reversed().map { String(format: "%02X", $0) }.joined(separator: ":")
            }
            if bytes.count >= 12 { tms.state        = Int(bytes[11]) }
            if bytes.count >= 16 { tms.frameCounter = uint32LE(bytes, at: 12) }

        default:
            tms.decodingConfidence = .raw
        }

        return tms
    }

    // MARK: - Helpers

    /// Reads 4 bytes little-endian as UInt32
    private func uint32LE(_ bytes: [UInt8], at i: Int) -> UInt32 {
        guard bytes.count >= i + 4 else { return 0 }
        return UInt32(bytes[i]) | (UInt32(bytes[i+1]) << 8)
             | (UInt32(bytes[i+2]) << 16) | (UInt32(bytes[i+3]) << 24)
    }

    /// Extracts an ASCII string from bytes (filters non-printable characters)
    private func asciiString(from bytes: [UInt8], range: Range<Int>) -> String? {
        let safe = range.clamped(to: 0..<bytes.count)
        let str = safe.compactMap { bytes[$0] > 0x20 && bytes[$0] < 0x7F ? Character(UnicodeScalar(bytes[$0])) : nil }
        let result = String(str)
        return result.isEmpty ? nil : result
    }

    // MARK: - STIHL Decoder (Company ID 0x03DD, Service UUID 0xFE43)

    /// Decodes STIHL Smart Connector or Smart Battery from raw manufacturer data.
    /// Protocol byte (index 2 in raw data) selects the frame type:
    ///   0x01 = Smart Connector (App API)    → StihlConnectorData
    ///   0x06 = Smart Battery               → StihlBatteryData
    private func parseStihlData(rawManufacturerData: Data?) -> (StihlConnectorData?, StihlBatteryData?) {
        guard let raw = rawManufacturerData, raw.count >= 3 else { return (nil, nil) }
        let bytes = [UInt8](raw)

        // Company ID check: 0x03DD (LE: 0xDD 0x03)
        let companyID = UInt16(bytes[0]) | (UInt16(bytes[1]) << 8)
        guard companyID == 0x03DD else { return (nil, nil) }

        let protocolID = bytes[2]

        switch protocolID {
        case 0x01, 0x02: // Smart Connector — App API or Developer API
            guard bytes.count >= 21 else { return (nil, nil) }
            // Bytes [3..8] = MAC, lowest byte first → display highest first
            let macBytes = Array(bytes[3..<9])
            let mac = macBytes.reversed().map { String(format: "%02X", $0) }.joined(separator: ":")
            let counter  = uint32LE(bytes, at: 9)          // [9-12] seconds
            let prodID   = bytes[13]                        // [13] Product ID
            let hwLow    = bytes[14]                        // [14] HW ver low
            let hwHigh   = bytes[15]                        // [15] HW ver high
            let swLow    = bytes[16]                        // [16] SW ver low
            let swHigh   = bytes[17]                        // [17] SW ver high
            let txPwr    = Int8(bitPattern: bytes[18])      // [18] signed TX power
            let status   = bytes[19]                        // [19] status flags
            let batRaw   = bytes[20]                        // [20] battery
            let batVolts = Double(batRaw) * 0.05
            var tempC: Int? = nil
            if bytes.count >= 22 {
                let t = Int8(bitPattern: bytes[21])         // [21] temperature signed
                if t != -128 { tempC = Int(t) }             // 0x80 = not implemented
            }
            let connector = StihlConnectorData(
                protocolID:     protocolID,
                macAddress:     mac,
                counterSeconds: counter,
                productID:      prodID,
                hwVersionLow:   hwLow,
                hwVersionHigh:  hwHigh,
                swVersionLow:   swLow,
                swVersionHigh:  swHigh,
                txPowerDBm:     txPwr,
                statusFlags:    status,
                batteryVolts:   batVolts,
                temperatureC:   tempC,
                fullRawData:    bytes
            )
            return (connector, nil)

        case 0x06: // Smart Battery
            guard bytes.count >= 20 else { return (nil, nil) }
            // Bytes [4..9] = serial number (6 bytes), starting right after the 1-byte flags field at [3]
            let serialBytes = Array(bytes[4..<10])
            let serial = serialBytes.map { String(format: "%02X", $0) }.joined(separator: ":")
            let dischargeTime  = uint32LE(bytes, at: 10)   // [10-13] total discharge time
            // [14-16] charging cycles as 3-byte big-endian (e.g. 00 00 02 = 2 cycles)
            let cycles: UInt32 = bytes.count >= 17
                ? (UInt32(bytes[14]) << 16) | (UInt32(bytes[15]) << 8) | UInt32(bytes[16])
                : 0
            let health  = bytes.count >= 18 ? bytes[17] : 0  // [17] health (raw, 0-255)
            let stateID = bytes.count >= 19 ? bytes[18] : 0  // [18] state ID
            let charge  = bytes.count >= 20 ? bytes[19] : 0  // [19] charge %
            let battery = StihlBatteryData(
                serialNumber:       serial,
                totalDischargeTime: dischargeTime,
                chargingCycles:     cycles,
                healthPercent:      health,
                stateID:            stateID,
                chargePercent:      charge,
                fullRawData:        bytes
            )
            return (nil, battery)

        default:
            return (nil, nil)
        }
    }

    // MARK: - ELA Innovation Decoder (Company ID 0x0757)

    /// Decodes an ELA Innovation beacon from raw manufacturer data.
    /// Layout: [0-1]=CompanyID 0x0757  [2]=DataType  [3...]=payload
    /// Product variant inferred from the device name prefix ("C ID" or "P ID").
    private func parseELAData(rawManufacturerData: Data?, deviceName: String?) -> ELAData? {
        guard let raw = rawManufacturerData, raw.count >= 3 else { return nil }
        let bytes = [UInt8](raw)

        // Company ID check: 0x0757 (LE: 0x57 0x07)
        let companyID = UInt16(bytes[0]) | (UInt16(bytes[1]) << 8)
        guard companyID == 0x0757 else { return nil }

        let dataType = bytes[2]
        let payload  = bytes.count > 3 ? Array(bytes[3...]) : []

        // Determine product variant from device name prefix
        let variant: ELAData.ProductVariant
        if let n = deviceName {
            let up = n.uppercased()
            if up.hasPrefix("C ID") || up.contains("COIN") {
                variant = .coin
            } else if up.hasPrefix("P ID") || up.contains("PUCK") {
                variant = .puck
            } else {
                variant = .unknown
            }
        } else {
            variant = .unknown
        }

        return ELAData(
            dataType:       dataType,
            payload:        payload,
            productVariant: variant,
            fullRawData:    bytes
        )
    }

    // MARK: - Apple AirTag / FindMy Decoder (Company ID 0x004C, type 0x12 / 0x1E)

    /// Decodes an Apple FindMy advertisement from raw manufacturer data.
    /// Layout: [0-1]=CompanyID 0x004C  [2]=Type  [3]=Length
    ///         [4]=StatusByte  [5-26]=RotatingPublicKey (22 bytes)
    /// Type 0x12 = Offline Finding (AirTag away from owner)
    /// Type 0x1E = FindMy Accessory Info (AirTag near owner — iOS only)
    private func parseAirTagData(rawManufacturerData: Data?) -> AirTagData? {
        guard let raw = rawManufacturerData, raw.count >= 5 else { return nil }
        let bytes = [UInt8](raw)

        // Company ID check: 0x004C Apple (LE: 0x4C 0x00)
        let companyID = UInt16(bytes[0]) | (UInt16(bytes[1]) << 8)
        guard companyID == 0x004C else { return nil }

        // Type byte: 0x12 = Offline FindMy, 0x1E = FindMy near owner (iOS)
        guard bytes[2] == 0x12 || bytes[2] == 0x1E else { return nil }

        let statusByte  = bytes[4]
        let keyStart    = 5
        let keyEnd      = min(keyStart + 8, bytes.count)
        let keyPrefix   = keyStart < keyEnd ? Array(bytes[keyStart..<keyEnd]) : []

        return AirTagData(
            statusByte:       statusByte,
            publicKeyPrefix:  keyPrefix,
            fullRawData:      bytes
        )
    }

    /// iOS privacy fallback: returns a synthetic AirTagData when the manufacturer data is
    /// stripped by iOS (which hides Apple's 0x004C payload for the owner's own FindMy items).
    /// Detection heuristics, in order:
    /// 1. Overflow service UUID contains "FD44" (Apple Find My Network, Bluetooth SIG #0xFD44)
    /// 2. Peripheral name contains "AirTag" (user-assigned name returned even when mf data is hidden)
    /// 3. Manufacturer data present but type byte 0x1E was not yet parsed (should be handled by parseAirTagData)
    private func syntheticAirTagIfNeeded(name: String?, overflowUUIDs: [String], mfRaw: Data?) -> AirTagData? {
        // Heuristic 1: overflow UUID 0xFD44 = Apple Find My Network
        let hasFindMyUUID = overflowUUIDs.contains(where: { $0.contains("FD44") || $0.contains("fd44") })
        if hasFindMyUUID {
            return AirTagData(statusByte: 0, publicKeyPrefix: [], fullRawData: [])
        }
        // Heuristic 2: device name indicates AirTag/FindMy accessory
        if let n = name,
           n.localizedCaseInsensitiveContains("airtag") ||
           n.localizedCaseInsensitiveContains("find my") ||
           n.hasSuffix("-Find My") {
            return AirTagData(statusByte: 0, publicKeyPrefix: [], fullRawData: [])
        }
        return nil
    }

    private func stateDescription(_ state: CBManagerState) -> String {
        switch state {
        case .poweredOff:   return "Bluetooth is disabled. Enable it in System Settings."
        case .unauthorized: return "Bluetooth access was denied. Check your Privacy settings."
        case .unsupported:  return "Bluetooth Low Energy is not supported on this device."
        case .resetting:    return "Bluetooth is restarting…"
        default:            return "Bluetooth unavailable."
        }
    }
}

// MARK: - CBCentralManagerDelegate

extension BLEScanner: @preconcurrency CBCentralManagerDelegate {

    #if os(iOS)
    /// Called when iOS relaunches the app in background to restore a previous CB session.
    /// Fires *before* centralManagerDidUpdateState, so we set shouldRestartScan here
    /// and actually restart the scan in centralManagerDidUpdateState(.poweredOn).
    func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {
        // iOS calls willRestoreState when relaunching the app in background to restore a CB
        // session. We unconditionally restart the scan because:
        // - CBCentralManagerRestoredStateScanServicesKey is ABSENT when scanning
        //   withServices:nil (scan-all), so checking it would always return false.
        // - If we were scanning before suspension we should resume; there is no downside
        //   to restarting even if we weren't.
        bleLog.error("[BLE] willRestoreState — scheduling scan restart")
        shouldRestartScan = true
        isScanning        = true   // optimistic — confirmed by startBackgroundScan()
    }
    #endif

    // Called on .main because queue: .main is set in init
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        bluetoothState = central.state
        if central.state == .poweredOn {
            errorMessage = nil
            #if os(iOS)
            // Resume a scan that iOS suspended when the app was backgrounded.
            // Always use allowDuplicates:true — otherwise didDiscover fires once per device
            // and then goes silent, breaking background push.
            if shouldRestartScan {
                shouldRestartScan = false
                // Use background scan mode (allowDuplicates:false) since we are being
                // relaunched in background by CoreBluetooth state restoration.
                startBackgroundScan()
            }
            #endif
        } else {
            isScanning = false
            errorMessage = stateDescription(central.state)
        }
    }

    func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        let rssi = RSSI.intValue
        guard rssi != 127 else { return }   // 127 = RSSI indisponible

        let rawName = peripheral.name
            ?? (advertisementData[CBAdvertisementDataLocalNameKey] as? String)

        let mfRaw  = advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data
        let (mfName, mfPayload) = parseManufacturer(from: mfRaw)

        #if os(iOS)
        let overflowUUIDs = (advertisementData[CBAdvertisementDataOverflowServiceUUIDsKey] as? [CBUUID] ?? [])
            .map { $0.uuidString }
        #else
        let overflowUUIDs: [String] = []
        #endif

        let serviceUUIDs = (advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? [])
            .map { $0.uuidString }

        let txPower      = (advertisementData[CBAdvertisementDataTxPowerLevelKey] as? Int)
        let isConnectable = (advertisementData[CBAdvertisementDataIsConnectable] as? Bool) ?? false

        let peripheralKey = peripheral.identifier.uuidString
        if let idx = devices.firstIndex(where: { $0.id == peripheral.identifier }) {
            // Update the existing device
            devices[idx].rssi     = rssi
            devices[idx].lastSeen = Date()
            devices[idx].seenCount += 1
            if let n = rawName        { devices[idx].name             = n }
            if let n = mfName         { devices[idx].manufacturerName = n }
            if let d = mfPayload      { devices[idx].manufacturerData = d }
            if let t = txPower        { devices[idx].txPowerLevel     = t }
            if !serviceUUIDs.isEmpty  { devices[idx].serviceUUIDs     = serviceUUIDs }
            // Re-decode TMS on every packet (values change in real time)
            devices[idx].tmsData = parseTMSData(
                rawManufacturerData: mfRaw,
                deviceName: devices[idx].name
            )
            // Persist MAC from frames 0x04/0x07 for post-reinstall recovery
            if let mac = devices[idx].tmsData?.macLSB, knownMacs[peripheralKey] != mac {
                knownMacs[peripheralKey] = mac
                saveMacs()
            }
            devices[idx].macAddress = knownMacs[peripheralKey]
            // Re-decode STIHL — only overwrite if the new parse yields data;
            // keep the last known value when a generic (non-STIHL) frame arrives
            // so the UI doesn't flicker / lose data between advertisement cycles.
            let (stihlConn, stihlBatt) = parseStihlData(rawManufacturerData: mfRaw)
            if let sc = stihlConn { devices[idx].stihlConnectorData = sc; lastKnownStihlConnector[peripheral.identifier] = sc }
            if let sb = stihlBatt { devices[idx].stihlBatteryData   = sb; lastKnownStihlBattery[peripheral.identifier]   = sb }
            // Re-decode ELA
            let ela = parseELAData(rawManufacturerData: mfRaw, deviceName: devices[idx].name)
            devices[idx].elaData = ela
            if let e = ela { lastKnownELAData[peripheral.identifier] = e }
            // Re-decode AirTag / FindMy
            if let at = parseAirTagData(rawManufacturerData: mfRaw) {
                devices[idx].airtagData = at
                lastKnownAirTagData[peripheral.identifier] = at
                if let n = devices[idx].name, !n.isEmpty { lastKnownAirTagDataByName[n] = at }
            }
            // iOS privacy fallback: if manufacturer data absent, detect by name or overflow UUID
            if devices[idx].airtagData == nil {
                if let at = syntheticAirTagIfNeeded(name: rawName, overflowUUIDs: overflowUUIDs, mfRaw: mfRaw) {
                    devices[idx].manufacturerName = devices[idx].manufacturerName ?? "Apple"
                    devices[idx].airtagData = at
                    lastKnownAirTagData[peripheral.identifier] = at
                    if let n = devices[idx].name, !n.isEmpty { lastKnownAirTagDataByName[n] = at }
                }
            }
        } else {
            var device = BLEDevice(
                id: peripheral.identifier,
                name: rawName,
                rssi: rssi,
                manufacturerName: mfName,
                manufacturerData: mfPayload,
                serviceUUIDs: serviceUUIDs,
                txPowerLevel: txPower,
                isConnectable: isConnectable,
                lastSeen: Date(),
                seenCount: 1
            )
            device.tmsData = parseTMSData(rawManufacturerData: mfRaw, deviceName: rawName)
            // Persist MAC from frames 0x04/0x07 for post-reinstall recovery
            if let mac = device.tmsData?.macLSB, knownMacs[peripheralKey] != mac {
                knownMacs[peripheralKey] = mac
                saveMacs()
            }
            device.macAddress = knownMacs[peripheralKey]
            let (stihlConn, stihlBatt) = parseStihlData(rawManufacturerData: mfRaw)
            device.stihlConnectorData = stihlConn
            if let sc = stihlConn { lastKnownStihlConnector[peripheral.identifier] = sc }
            device.stihlBatteryData   = stihlBatt
            if let sb = stihlBatt { lastKnownStihlBattery[peripheral.identifier]   = sb }
            device.elaData = parseELAData(rawManufacturerData: mfRaw, deviceName: rawName)
            if let e = device.elaData { lastKnownELAData[peripheral.identifier] = e }
            device.airtagData = parseAirTagData(rawManufacturerData: mfRaw)
            // iOS privacy: Apple may strip manufacturer data for the owner's AirTag.
            // Fall back to peripheral name / overflow service UUIDs when mfRaw is nil.
            if device.airtagData == nil {
                if let at = syntheticAirTagIfNeeded(name: rawName, overflowUUIDs: overflowUUIDs, mfRaw: mfRaw) {
                    device.manufacturerName = device.manufacturerName ?? "Apple"
                    device.airtagData = at
                }
            }
            // Suppress Apple mf type log (too verbose)
            if let at = device.airtagData {
                lastKnownAirTagData[peripheral.identifier] = at
                if let n = rawName, !n.isEmpty { lastKnownAirTagDataByName[n] = at }
            }
            devices.append(device)
        }

        // Sort by descending RSSI (strongest signal first)
        devices.sort { $0.rssi > $1.rssi }

        // Notify the push service synchronously — no Combine, no async hop.
        onDeviceDiscovered?()
    }
}
