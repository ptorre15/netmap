import SwiftUI

// MARK: - PairedSensorsView

struct PairedSensorsView: View {
    @EnvironmentObject var bleScanner:   BLEScanner
    @EnvironmentObject var vehicleStore: VehicleStore

    /// Vehicles that have at least one paired sensor
    private var pairedVehicles: [VehicleConfig] {
        vehicleStore.vehicles.filter { !$0.pairedSensors.isEmpty }
    }

    var body: some View {
        Group {
            if pairedVehicles.isEmpty {
                emptyState
            } else {
                sensorList
            }
        }
        .navigationTitle("Paired Sensors")
    }

    // MARK: - List

    private var sensorList: some View {
        List {
            ForEach(pairedVehicles) { vehicle in
                Section {
                    ForEach(vehicle.pairedSensors) { sensor in
                        PairedSensorRow(sensor: sensor,
                                        liveDevice: liveDevice(for: sensor))
                    }
                } header: {
                    HStack(spacing: 6) {
                        Image(systemName: "car.fill")
                            .foregroundStyle(.secondary)
                        Text(vehicle.name)
                            .font(.headline)
                        if let brand = vehicle.brand {
                            Text("· \(brand)")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        #if os(iOS)
        .listStyle(.insetGrouped)
        #else
        .listStyle(.inset)
        #endif
    }

    // MARK: - Empty state

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No Paired Sensors", systemImage: "sensor.tag.radiowaves.forward.fill")
        } description: {
            Text("Pair sensors to your vehicles from the Vehicles tab.")
        }
    }

    // MARK: - Helper

    private func liveDevice(for sensor: PairedSensor) -> BLEDevice? {
        bleScanner.devices.first {
            $0.id == sensor.id ||
            ($0.macAddress != nil && $0.macAddress == sensor.macAddress)
        }
    }
}

