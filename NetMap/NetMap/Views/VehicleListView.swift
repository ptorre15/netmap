import SwiftUI

// MARK: - Asset List (root of the Assets tab)

struct VehicleListView: View {
    @EnvironmentObject var store: VehicleStore
    @EnvironmentObject var bleScanner: BLEScanner

    @State private var showAddSheet = false
    @State private var editTarget: VehicleConfig?

    /// Assets grouped by asset type, ordered by type name
    private var grouped: [(AssetType, [VehicleConfig])] {
        let types = store.assetTypes
        return types.compactMap { type in
            let assets = store.vehicles.filter { $0.assetTypeID == type.id }
            return assets.isEmpty ? nil : (type, assets)
        }
    }

    var body: some View {
        NavigationSplitView {
            listContent
                .navigationTitle("Assets")
                .toolbar { toolbarItems }
        } detail: {
            ContentUnavailableView {
                Label("No Asset Selected", systemImage: "shippingbox.fill")
            } description: {
                Text("Select an asset from the list.")
            }
        }
        .sheet(isPresented: $showAddSheet) {
            VehicleEditSheet(config: nil)
                .environmentObject(store)
                .environmentObject(bleScanner)
        }
        .sheet(item: $editTarget) { v in
            VehicleEditSheet(config: v)
                .environmentObject(store)
                .environmentObject(bleScanner)
        }
    }

    // MARK: - List content

    @ViewBuilder
    private var listContent: some View {
        if store.vehicles.isEmpty {
            ContentUnavailableView {
                Label("No Assets", systemImage: "shippingbox.fill")
            } description: {
                Text("Tap + to add your first asset.")
            } actions: {
                Button("Add Asset") { showAddSheet = true }
                    .buttonStyle(.borderedProminent)
            }
        } else {
            List {
                ForEach(grouped, id: \.0.id) { (type, assets) in
                    Section(type.name) {
                        ForEach(assets) { asset in
                            NavigationLink {
                                VehicleDetailView(vehicleID: asset.id)
                                    .environmentObject(store)
                                    .environmentObject(bleScanner)
                            } label: {
                                VehicleRowView(vehicle: asset, bleScanner: bleScanner)
                            }
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                Button(role: .destructive) {
                                    store.deleteVehicle(id: asset.id)
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                                Button { editTarget = asset } label: {
                                    Label("Edit", systemImage: "pencil")
                                }
                                .tint(.blue)
                            }
                            .contextMenu {
                                Button { editTarget = asset } label: {
                                    Label("Edit Asset Info", systemImage: "pencil")
                                }
                                Divider()
                                Button(role: .destructive) {
                                    store.deleteVehicle(id: asset.id)
                                } label: {
                                    Label("Delete Asset", systemImage: "trash")
                                }
                            }
                        }
                    }
                }
            }
            #if os(macOS)
            .listStyle(.inset)
            #else
            .listStyle(.plain)
            #endif
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarItems: some ToolbarContent {
        ToolbarItem(placement: .automatic) {
            Button {
                showAddSheet = true
            } label: {
                Label("Add Asset", systemImage: "plus")
            }
            .help("Add a new asset")
        }
    }
}

// MARK: - Asset Row

struct VehicleRowView: View {
    let vehicle: VehicleConfig
    let bleScanner: BLEScanner
    @EnvironmentObject var store: VehicleStore

    private var sensorCount: Int { vehicle.pairedSensors.count }
    private var activeSensorCount: Int {
        vehicle.pairedSensors.filter { sensor in
            bleScanner.devices.contains { $0.id == sensor.id }
        }.count
    }
    private var assetType: AssetType { vehicle.resolvedAssetType(from: store.assetTypes) }

    var body: some View {
        HStack(spacing: 12) {
            // Asset type icon
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.blue.opacity(0.12))
                    .frame(width: 44, height: 44)
                Image(systemName: assetType.systemImage)
                    .font(.system(size: 20))
                    .foregroundStyle(.blue)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(vehicle.name)
                    .font(.body.weight(.semibold))
                Text(vehicle.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if sensorCount > 0 {
                    HStack(spacing: 4) {
                        let brands = Array(Set(vehicle.pairedSensors.map(\.brand)))
                            .sorted { $0.rawValue < $1.rawValue }
                        ForEach(brands, id: \.self) { brand in
                            HStack(spacing: 3) {
                                Image(systemName: brand.systemImage)
                                    .font(.caption2)
                                Text(brand.displayName)
                                    .font(.caption2)
                            }
                            .padding(.horizontal, 5).padding(.vertical, 2)
                            .background(brand.badgeColor.opacity(0.15), in: Capsule())
                            .foregroundStyle(brand.badgeColor)
                        }
                    }
                }
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 3) {
                Text("\(sensorCount)")
                    .font(.title3.weight(.bold))
                    .foregroundStyle(sensorCount == 0 ? .tertiary : .primary)
                Text(sensorCount == 1 ? "sensor" : "sensors")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                if activeSensorCount > 0 {
                    HStack(spacing: 3) {
                        Circle().fill(.green).frame(width: 6, height: 6)
                        Text("\(activeSensorCount) live")
                            .font(.caption2).foregroundStyle(.green)
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Asset Edit / Create Sheet

struct VehicleEditSheet: View {
    @EnvironmentObject var store: VehicleStore
    @EnvironmentObject var bleScanner: BLEScanner
    @Environment(\.dismiss) var dismiss

    let config: VehicleConfig?   // nil = create new

    @State private var name:         String = ""
    @State private var assetTypeID:  String = AssetType.vehicle.id
    // Vehicle fields
    @State private var brand:        String = ""
    @State private var model:        String = ""
    @State private var yearText:     String = ""
    @State private var vin:          String = ""
    @State private var vrn:          String = ""
    // Tool fields
    @State private var serialNumber: String = ""
    @State private var toolType:     String = ""

    private var isNew: Bool { config == nil }
    private var isSaveDisabled: Bool { name.trimmingCharacters(in: .whitespaces).isEmpty }
    private var selectedType: AssetType {
        store.assetTypes.first { $0.id == assetTypeID } ?? .vehicle
    }

    var body: some View {
        NavigationStack {
            Form {
                // Asset type (only editable on new)
                if isNew {
                    Section("Asset Type") {
                        Picker("Type", selection: $assetTypeID) {
                            ForEach(store.assetTypes) { t in
                                Label(t.name, systemImage: t.systemImage).tag(t.id)
                            }
                        }
                        .pickerStyle(.menu)
                    }
                }

                Section {
                    LabeledContent("Name") {
                        TextField("e.g. My Golf, Chainsaw 1…", text: $name)
                            .multilineTextAlignment(.trailing)
                    }
                } header: { Text("Required") }

                // Vehicle-specific fields
                if assetTypeID == AssetType.vehicle.id {
                    Section("Vehicle Details") {
                        LabeledContent("Brand") {
                            TextField("e.g. Volkswagen", text: $brand)
                                .multilineTextAlignment(.trailing)
                        }
                        LabeledContent("Model") {
                            TextField("e.g. Golf 8 GTI", text: $model)
                                .multilineTextAlignment(.trailing)
                        }
                        LabeledContent("Year") {
                            TextField("e.g. 2023", text: $yearText)
                                .multilineTextAlignment(.trailing)
                                #if os(iOS)
                                .keyboardType(.numberPad)
                                #endif
                        }
                    }
                    Section("Registration") {
                        LabeledContent("VIN") {
                            TextField("17-character identifier", text: $vin)
                                .multilineTextAlignment(.trailing)
                                #if os(iOS)
                                .textInputAutocapitalization(.characters)
                                #endif
                        }
                        LabeledContent("Plate / VRN") {
                            TextField("Registration number", text: $vrn)
                                .multilineTextAlignment(.trailing)
                                #if os(iOS)
                                .textInputAutocapitalization(.characters)
                                #endif
                        }
                    }
                }

                // Tool-specific fields
                if assetTypeID == AssetType.tool.id {
                    Section("Tool Details") {
                        LabeledContent("Type") {
                            TextField("e.g. Chainsaw, Hedge Trimmer", text: $toolType)
                                .multilineTextAlignment(.trailing)
                        }
                        LabeledContent("Serial Number") {
                            TextField("Manufacturer serial", text: $serialNumber)
                                .multilineTextAlignment(.trailing)
                                #if os(iOS)
                                .textInputAutocapitalization(.characters)
                                #endif
                        }
                    }
                }

                // Custom asset types: just name, no extra fields

                if !isNew {
                    Section {
                        Button("Delete Asset", role: .destructive) {
                            if let id = config?.id { store.deleteVehicle(id: id) }
                            dismiss()
                        }
                    }
                }
            }
            .navigationTitle(isNew ? "New \(selectedType.name)" : "Edit Asset")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(isSaveDisabled)
                }
            }
        }
        .onAppear { loadExisting() }
    }

    private func loadExisting() {
        guard let c = config else { return }
        name         = c.name
        assetTypeID  = c.assetTypeID
        brand        = c.brand        ?? ""
        model        = c.model        ?? ""
        yearText     = c.year.map { String($0) } ?? ""
        vin          = c.vin          ?? ""
        vrn          = c.vrn          ?? ""
        serialNumber = c.serialNumber ?? ""
        toolType     = c.toolType     ?? ""
    }

    private func save() {
        var v            = config ?? VehicleConfig(name: name, assetTypeID: assetTypeID)
        v.name           = name.trimmingCharacters(in: .whitespaces)
        v.assetTypeID    = assetTypeID
        // Vehicle fields
        v.brand          = brand.isEmpty        ? nil : brand.trimmingCharacters(in: .whitespaces)
        v.model          = model.isEmpty        ? nil : model.trimmingCharacters(in: .whitespaces)
        v.year           = Int(yearText)
        v.vin            = vin.isEmpty          ? nil : vin.trimmingCharacters(in: .whitespaces).uppercased()
        v.vrn            = vrn.isEmpty          ? nil : vrn.trimmingCharacters(in: .whitespaces).uppercased()
        // Tool fields
        v.serialNumber   = serialNumber.isEmpty ? nil : serialNumber.trimmingCharacters(in: .whitespaces)
        v.toolType       = toolType.isEmpty     ? nil : toolType.trimmingCharacters(in: .whitespaces)
        if isNew {
            store.addVehicle(v)
        } else {
            store.updateVehicle(v)
        }
        dismiss()
    }
}
