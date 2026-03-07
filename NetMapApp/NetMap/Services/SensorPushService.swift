import Foundation
import os.log

private let pushLog = Logger(subsystem: "com.phil.netmap.app", category: "Push")

// MARK: - Push throttle

/// Holds per-sensor last-push timestamps.
/// Class (reference type) so mutations are immediately visible to the next BLE event,
/// avoiding the SwiftUI @State async-update pitfall.
final class PushThrottle {
    private var lastPushed: [String: Date] = [:]
    func canPush(_ id: String, now: Date, interval: TimeInterval = 60) -> Bool {
        guard let last = lastPushed[id] else { return true }
        return now.timeIntervalSince(last) >= interval
    }
    func stamp(_ id: String, now: Date) {
        lastPushed[id] = now
    }
}

// MARK: - SensorPushService

/// Background-safe push service.
///
/// Hooks into BLEScanner.onDeviceDiscovered — a callback fired synchronously from
/// CBCentralManagerDelegate.didDiscover, on the main thread, inside CoreBluetooth's
/// own background wakeup window.
///
/// WHY NOT COMBINE:
///   A Combine sink on $devices can involve an actor hop (nonisolated closure → @MainActor method)
///   that defers execution past iOS's short background wakeup window.
///   The direct callback has zero indirection: didDiscover → push → enqueue → beginBackgroundTask,
///   all synchronous on the main thread.
///
/// Usage:
///   let svc = SensorPushService()
///   svc.configure(scanner: bleScanner, store: vehicleStore, location: locationManager, client: serverClient)
@MainActor
final class SensorPushService: ObservableObject {
    private let throttle = PushThrottle()

    /// Call once at app startup. Idempotent — replaces any previous callback.
    func configure(
        scanner:  BLEScanner,
        store:    VehicleStore,
        location: LocationManager,
        client:   NetMapServerClient
    ) {
        // Direct callback — fired synchronously by didDiscover on the main thread.
        // No Combine, no actor hops, no async delays.
        scanner.onDeviceDiscovered = { [weak self] in
            self?.push(devices: scanner.devices, store: store, location: location, client: client)
        }
    }

    // MARK: - Core push logic

    private func push(
        devices:  [BLEDevice],
        store:    VehicleStore,
        location: LocationManager,
        client:   NetMapServerClient
    ) {
        guard client.isEnabled, client.isAuthenticated else {
            pushLog.error("[Push] push skipped: enabled=\(client.isEnabled) authenticated=\(client.isAuthenticated)")
            return
        }
        let now = Date()

        for d in devices {
            // ── Resolve which asset owns this device ─────────────────────────
            var vehicle: VehicleConfig? = store.vehicle(for: d.id)

            // TMS fallback: CBPeripheral UUID may change after reinstall
            if vehicle == nil, let mac = d.macAddress {
                vehicle = store.vehicle(forMAC: mac)
                if let v = vehicle {
                    store.healSensorUUID(fromMAC: mac, to: d.id, in: v.id)
                }
            }
            // STIHL Connector fallback: macAddress always nil, use hardware MAC from frame
            if vehicle == nil, let sc = d.stihlConnectorData {
                vehicle = store.vehicle(forMAC: sc.macAddress)
                if let v = vehicle {
                    store.healSensorUUID(fromMAC: sc.macAddress, to: d.id, in: v.id)
                }
            }
            // AirTag fallback: UUID is ephemeral, name is nil on iOS for owner's tags.
            // 1) Match by advertisement name when visible (macOS / non-owner).
            // 2) iOS: if anonymous, pick the sole vehicle that has a paired AirTag.
            if vehicle == nil, d.isAirTagDevice || d.airtagData != nil {
                if let name = d.name, !name.isEmpty {
                    vehicle = store.vehicle(forMAC: name)
                    // No UUID healing — AirTag UUID is ephemeral and useless
                }
                if vehicle == nil {
                    let candidates = store.vehicles.filter { v in
                        v.pairedSensors.contains { $0.brand == .airtag }
                    }
                    if candidates.count == 1 { vehicle = candidates[0] }
                }
            }
            guard let vehicle else { continue }

            // ── Persist MACs for post-reinstall recovery ─────────────────────
            if let mac = d.macAddress {
                store.storeMACIfNeeded(mac, forSensorUUID: d.id, in: vehicle.id)
            }
            if let sc = d.stihlConnectorData {
                store.storeMACIfNeeded(sc.macAddress, forSensorUUID: d.id, in: vehicle.id)
            }
            // AirTag: heal macAddress to a stable name key if not yet stored.
            // Without this, every UUID rotation (every ~15 min by Apple design) creates a new
            // orphaned sensorID on the server, fragmenting all historical readings.
            if (d.isAirTagDevice || d.airtagData != nil), let name = d.name, !name.isEmpty {
                store.healAirTagMACIfNeeded(name: name, in: vehicle.id)
            }

            // ── Stable push ID (MAC-based where available) ────────────────────
            let stableID: String
            if let sc = d.stihlConnectorData {
                stableID = "STIHL-" + sc.macAddress.replacingOccurrences(of: ":", with: "")
            } else if let sb = d.stihlBatteryData {
                stableID = "STIHLBATT-\(sb.serialNumber)"
            } else if d.isAirTagDevice || d.airtagData != nil,
                      let name = vehicle.pairedSensors.first(where: { $0.brand == .airtag })?.macAddress ?? d.name,
                      !name.isEmpty {
                stableID = name
            } else {
                stableID = d.stableSensorID
            }

            // ── Per-sensor throttle ───────────────────────────────────────────
            let interval = TimeInterval(client.pushIntervalSeconds)
            if !throttle.canPush(stableID, now: now, interval: interval) { continue }
            pushLog.error("[Push] will push \(stableID, privacy: .public)")

            let vid    = vehicle.serverVehicleID?.uuidString ?? vehicle.id.uuidString
            let vname  = vehicle.name
            let paired = vehicle.pairedSensors.first { $0.id == d.id }
            let lat    = location.currentLatitude
            let lon    = location.currentLongitude

            var payload: ServerSensorPayload?

            if let tms = d.tmsData {
                // ── Michelin TPMS ─────────────────────────────────────────────
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
                // ── STIHL Smart Connector ─────────────────────────────────────
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
                // ── STIHL Smart Battery ───────────────────────────────────────
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
                // ── ELA Innovation ────────────────────────────────────────────
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

            } else if d.isAirTagDevice || d.airtagData != nil || paired?.brand == .airtag {
                // ── AirTag / FindMy — présence / localisation ─────────────────
                let atBattPct     = d.airtagData?.batteryLevel.approximatePercent
                let atChargeState = d.airtagData?.isSeparated == true ? "Separated" : nil
                payload = ServerSensorPayload(
                    sensorID:          stableID,
                    vehicleID:         vid,
                    vehicleName:       vname,
                    assetTypeID:       vehicle.assetTypeID,
                    brand:             "airtag",
                    wheelPosition:     nil,
                    pressureBar:       nil,
                    temperatureC:      nil,
                    vbattVolts:        nil,
                    targetPressureBar: nil,
                    batteryPct:        atBattPct,
                    chargeState:       atChargeState,
                    sensorName:        paired?.customLabel ?? d.displayName,
                    latitude:          lat,
                    longitude:         lon,
                    timestamp:         Date()
                )
            }

            if let payload {
                throttle.stamp(stableID, now: now)
                client.enqueue(payload)
            }
        }
    }
}
