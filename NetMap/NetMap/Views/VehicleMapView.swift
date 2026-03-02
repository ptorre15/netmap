import SwiftUI

// MARK: - Vehicle Map View

struct VehicleMapView: View {
    @EnvironmentObject var bleScanner: BLEScanner
    @EnvironmentObject var store: VehicleStore
    @State private var selectedVehicleID: UUID?

    private var selectedVehicle: VehicleConfig? {
        if let id = selectedVehicleID, let v = store.vehicles.first(where: { $0.id == id }) { return v }
        return store.vehicles.first
    }

    var body: some View {
        Group {
            if store.vehicles.isEmpty {
                emptyState
            } else {
                mainContent
            }
        }
        .navigationTitle("Wheel Map")
    }

    @ViewBuilder
    private var mainContent: some View {
        VStack(spacing: 0) {
            if store.vehicles.count > 1 {
                vehiclePicker
                Divider()
            }
            if let v = selectedVehicle {
                ScrollView {
                    VStack(spacing: 18) {
                        OverallStatusBanner(vehicle: v, bleScanner: bleScanner, store: store)
                            .padding(.horizontal).padding(.top, 16)
                        WheelDiagram(vehicle: v, bleScanner: bleScanner, store: store)
                            .padding(.horizontal)
                        WheelDetailGrid(vehicle: v, bleScanner: bleScanner, store: store)
                            .padding(.horizontal).padding(.bottom, 24)
                    }
                }
            }
        }
    }

    private var vehiclePicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(store.vehicles) { v in
                    let sel = selectedVehicle?.id == v.id
                    Button { selectedVehicleID = v.id } label: {
                        Text(v.name)
                            .font(.subheadline.weight(sel ? .semibold : .regular))
                            .padding(.horizontal, 14).padding(.vertical, 7)
                            .background(Capsule().fill(sel ? Color.accentColor : Color.secondary.opacity(0.12)))
                            .foregroundStyle(sel ? .white : .primary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
        }
        .background(.bar)
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No Vehicle Configured", systemImage: "car.fill")
        } description: {
            Text("Add a vehicle in the Vehicles tab, then pair TMS sensors to wheel positions.")
        }
    }
}

// MARK: - Overall Status Banner

struct OverallStatusBanner: View {
    let vehicle: VehicleConfig
    let bleScanner: BLEScanner
    let store: VehicleStore

    private struct WheelInfo: Identifiable {
        let pos: WheelPosition
        let sensor: PairedSensor?
        let device: BLEDevice?
        var id: String { pos.rawValue }
        var pressure: Double? { device?.tmsData?.pressureBar }
        var status: PressureStatus {
            guard let p = pressure, let t = sensor?.targetPressureBar else { return .ok }
            return PressureStatus.evaluate(actual: p, target: t)
        }
    }

    private var wheels: [WheelInfo] {
        WheelPosition.allCases.map { pos in
            let s = vehicle.sensor(for: pos)
            let d = bleScanner.devices.first { $0.id == s?.id }
            return WheelInfo(pos: pos, sensor: s, device: d)
        }
    }
    private var configured: [WheelInfo] { wheels.filter { $0.sensor != nil } }
    private var hasPunctureRisk: Bool { false }
    private var worstStatus: PressureStatus? {
        let live = configured.filter { $0.device != nil }
        guard !live.isEmpty else { return nil }
        if live.map(\.status).contains(.danger)  { return .danger }
        if live.map(\.status).contains(.warning) { return .warning }
        return .ok
    }

    var body: some View {
        if vehicle.tmsSensors.isEmpty {
            noSensorsView
        } else {
            bannerView
        }
    }

    private var bannerView: some View {
        let color: Color = hasPunctureRisk ? .red
            : (worstStatus == nil ? .secondary : worstStatus!.color)
        let icon = hasPunctureRisk ? "exclamationmark.triangle.fill"
            : (worstStatus == nil ? "antenna.radiowaves.left.and.right.slash"
               : worstStatus!.systemImage)
        let message: String = {
            if hasPunctureRisk { return "Pressure drop detected" }
            switch worstStatus {
            case .ok:      return configured.allSatisfy({ $0.device != nil })
                ? "All pressures normal" : "Normal — some sensors out of range"
            case .warning: return "Check tyre pressure"
            case .danger:  return "Tyre pressure critical"
            case nil:      return "No live pressure data"
            }
        }()

        return HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.title3.weight(.semibold)).foregroundStyle(color)
            Text(message)
                .font(.subheadline.weight(.medium)).foregroundStyle(color)
            Spacer()
            HStack(spacing: 5) {
                ForEach(wheels) { w in
                    let c: Color = w.sensor == nil ? Color.secondary.opacity(0.35)
                        : (w.device == nil ? Color.secondary : w.status.color)
                    Text(w.pos.shortLabel)
                        .font(.caption2.weight(.bold)).monospacedDigit()
                        .padding(.horizontal, 5).padding(.vertical, 3)
                        .background(RoundedRectangle(cornerRadius: 5).fill(c.opacity(0.15)))
                        .foregroundStyle(c)
                }
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(color.opacity(0.08))
                .overlay(RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(color.opacity(0.22), lineWidth: 1))
        )
    }

    private var noSensorsView: some View {
        HStack(spacing: 10) {
            Image(systemName: "gauge.open.with.lines.needle.33percent")
                .font(.title3).foregroundStyle(.secondary)
            Text("No TMS sensors paired. Open the Scanner tab and pair sensors to wheels.")
                .font(.subheadline).foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color.secondary.opacity(0.07)))
    }
}

// MARK: - Wheel Diagram

struct WheelDiagram: View {
    let vehicle: VehicleConfig
    let bleScanner: BLEScanner
    let store: VehicleStore

    var body: some View {
        GeometryReader { geo in
            let w = min(geo.size.width, 260.0)   // cap width so the car stays compact
            let h = w * 0.72

            ZStack {
                RoundedRectangle(cornerRadius: 16)
                    .fill(Color.secondary.opacity(0.05))
                    .frame(width: w, height: h)

                // ── Car body ── hood (darker) + cabin (lighter) + trunk (darker)
                CarTopShape()
                    .fill(
                        LinearGradient(
                            stops: [
                                .init(color: Color.secondary.opacity(0.22), location: 0.00),  // front bumper
                                .init(color: Color.secondary.opacity(0.18), location: 0.15),  // hood
                                .init(color: Color.secondary.opacity(0.30), location: 0.28),  // A-pillar
                                .init(color: Color.secondary.opacity(0.12), location: 0.45),  // cabin roof
                                .init(color: Color.secondary.opacity(0.30), location: 0.72),  // C-pillar
                                .init(color: Color.secondary.opacity(0.18), location: 0.85),  // trunk
                                .init(color: Color.secondary.opacity(0.22), location: 1.00),  // rear bumper
                            ],
                            startPoint: .top, endPoint: .bottom
                        )
                    )
                    .overlay(CarTopShape().stroke(Color.secondary.opacity(0.22), lineWidth: 0.8))
                    .frame(width: w * 0.32, height: h * 0.88)

                // Windshield
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color.blue.opacity(0.18))
                    .frame(width: w * 0.18, height: h * 0.10)
                    .offset(y: -(h * 0.88 / 2) + (h * 0.88 * 0.28))

                // Rear window
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color.blue.opacity(0.10))
                    .frame(width: w * 0.15, height: h * 0.09)
                    .offset(y: (h * 0.88 / 2) - (h * 0.88 * 0.28))

                Text("▲  FRONT")
                    .font(.system(size: 7, weight: .semibold)).kerning(1.2)
                    .foregroundStyle(Color.secondary.opacity(0.3))
                    .offset(y: -(h * 0.50))

                ForEach(WheelPosition.allCases) { pos in
                    WheelTireView(
                        position: pos,
                        sensor: vehicle.sensor(for: pos),
                        liveDevice: bleScanner.devices.first {
                            $0.id == vehicle.sensor(for: pos)?.id
                        },
                        store: store
                    )
                    .position(x: pos.relativeX * w, y: pos.relativeY * h + h * 0.06)
                }
            }
            .frame(width: w, height: h)
        }
        .frame(maxWidth: 260, minHeight: 210, maxHeight: 210)
    }
}

// MARK: - Car top-view shape  (sedan silhouette)

struct CarTopShape: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        let w = rect.width, h = rect.height

        // The shape models a top-down sedan:
        //  • narrow pointed front bumper (top)
        //  • hood widens to full body width
        //  • cabin (greenhouse) is the widest section
        //  • trunk narrows like the hood
        //  • narrow rounded rear bumper (bottom)

        let bw: CGFloat = 0.50   // body half-width at hood/trunk shoulders
        let cw: CGFloat = 0.50   // cabin full half-width (same as body)
        let nw: CGFloat = 0.30   // front/rear tip half-width (narrow)

        // Front tip
        p.move(to: CGPoint(x: w * (0.5 - nw * 0.5), y: 0))
        p.addLine(to: CGPoint(x: w * (0.5 + nw * 0.5), y: 0))
        // Hood — right side
        p.addCurve(
            to:          CGPoint(x: w * (0.5 + bw), y: h * 0.22),
            control1:    CGPoint(x: w * (0.5 + nw * 0.5 + 0.10), y: 0),
            control2:    CGPoint(x: w * (0.5 + bw), y: h * 0.08)
        )
        // Right side straight (A-pillar → C-pillar through cabin)
        p.addLine(to: CGPoint(x: w * (0.5 + cw), y: h * 0.78))
        // Trunk — right side
        p.addCurve(
            to:          CGPoint(x: w * (0.5 + nw * 0.5), y: h),
            control1:    CGPoint(x: w * (0.5 + bw), y: h * 0.92),
            control2:    CGPoint(x: w * (0.5 + nw * 0.5 + 0.10), y: h)
        )
        // Rear tip
        p.addLine(to: CGPoint(x: w * (0.5 - nw * 0.5), y: h))
        // Trunk — left side
        p.addCurve(
            to:          CGPoint(x: w * (0.5 - bw), y: h * 0.78),
            control1:    CGPoint(x: w * (0.5 - nw * 0.5 - 0.10), y: h),
            control2:    CGPoint(x: w * (0.5 - bw), y: h * 0.92)
        )
        // Left side straight (C-pillar → A-pillar)
        p.addLine(to: CGPoint(x: w * (0.5 - cw), y: h * 0.22))
        // Hood — left side back to front tip
        p.addCurve(
            to:          CGPoint(x: w * (0.5 - nw * 0.5), y: 0),
            control1:    CGPoint(x: w * (0.5 - bw), y: h * 0.08),
            control2:    CGPoint(x: w * (0.5 - nw * 0.5 - 0.10), y: 0)
        )
        p.closeSubpath()
        return p
    }
}

// MARK: - Wheel tyre view (in diagram)

struct WheelTireView: View {
    let position: WheelPosition
    let sensor: PairedSensor?
    let liveDevice: BLEDevice?
    let store: VehicleStore

    private var pressure: Double? { liveDevice?.tmsData?.pressureBar }
    private var target: Double?   { sensor?.targetPressureBar }
    private var status: PressureStatus {
        guard let p = pressure, let t = target else { return .ok }
        return PressureStatus.evaluate(actual: p, target: t)
    }
    private var arcFraction: Double {
        guard let p = pressure, let t = target else { return 0 }
        return min(p / (t * 1.25), 1.0)
    }
    private var isPunctureRisk: Bool { false }

    var body: some View {
        VStack(spacing: 5) {
            ZStack {
                // Tyre body
                RoundedRectangle(cornerRadius: 10)
                    .fill(sensor == nil ? Color.secondary.opacity(0.22) : Color(white: 0.16))
                    .frame(width: 38, height: 58)

                // Rim
                Circle()
                    .fill(RadialGradient(
                        colors: [Color(white: 0.68), Color(white: 0.28)],
                        center: .topLeading, startRadius: 1, endRadius: 20))
                    .frame(width: 28, height: 28)

                // Pressure arc
                if sensor != nil {
                    Circle()
                        .trim(from: 0, to: arcFraction)
                        .stroke(
                            pressure != nil ? status.color : Color.white.opacity(0.15),
                            style: StrokeStyle(lineWidth: 4, lineCap: .round))
                        .frame(width: 24, height: 24)
                        .rotationEffect(.degrees(-90))
                        .animation(.easeOut(duration: 0.6), value: arcFraction)
                }

                // Center
                if let p = pressure {
                    Text(String(format: "%.1f", p))
                        .font(.system(size: 8.5, weight: .black, design: .rounded))
                        .foregroundStyle(status.color)
                } else if sensor != nil {
                    Image(systemName: "wifi.slash")
                        .font(.system(size: 8)).foregroundStyle(Color.white.opacity(0.3))
                } else {
                    Image(systemName: "plus.circle.dashed")
                        .font(.system(size: 13)).foregroundStyle(Color.secondary.opacity(0.4))
                }

                // Puncture badge
                if isPunctureRisk {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 8)).foregroundStyle(.red)
                        .shadow(color: .red.opacity(0.5), radius: 3)
                        .offset(x: 15, y: -22)
                }

                // Signal dot
                if sensor != nil {
                    Circle()
                        .fill(liveDevice != nil ? Color.green : Color.red.opacity(0.55))
                        .frame(width: 5, height: 5)
                        .offset(x: -15, y: -22)
                }
            }
            Text(position.shortLabel)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel({
            if let p = pressure { return "\(position.label): \(String(format: "%.1f bar", p)), \(status.label)" }
            return "\(position.label): \(sensor != nil ? "no signal" : "not configured")"
        }())
    }
}

// MARK: - Wheel Detail Grid

struct WheelDetailGrid: View {
    let vehicle: VehicleConfig
    let bleScanner: BLEScanner
    let store: VehicleStore

    private let positions: [WheelPosition] = [.frontLeft, .frontRight, .rearLeft, .rearRight]

    var body: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 10),
                             GridItem(.flexible(), spacing: 10)],
                  spacing: 10) {
            ForEach(positions) { pos in
                let sensor = vehicle.sensor(for: pos)
                let device = bleScanner.devices.first { $0.id == sensor?.id }
                WheelDetailCard(position: pos, sensor: sensor, liveDevice: device, store: store)
            }
        }
    }
}

// MARK: - Wheel Detail Card

struct WheelDetailCard: View {
    let position: WheelPosition
    let sensor: PairedSensor?
    let liveDevice: BLEDevice?
    let store: VehicleStore

    private var tms: TMSData?         { liveDevice?.tmsData }
    private var pressure: Double?     { tms?.pressureBar }
    private var target: Double?       { sensor?.targetPressureBar }
    private var isLive: Bool          { liveDevice != nil && sensor != nil }
    private var status: PressureStatus {
        guard let p = pressure, let t = target else { return .ok }
        return PressureStatus.evaluate(actual: p, target: t)
    }
    private var isPunctureRisk: Bool { false }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Header
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(position.shortLabel)
                        .font(.caption2.weight(.heavy)).foregroundStyle(.secondary)
                    Text(position.label)
                        .font(.caption.weight(.semibold))
                }
                Spacer()
                statusBadge
            }

            // Pressure
            pressureSection

            // Gauge bar
            if let p = pressure, let t = target {
                VStack(alignment: .leading, spacing: 3) {
                    PressureGaugeView(pressureBar: p, maxBar: max(t * 1.35, 3.5))
                    HStack {
                        Text("0").font(.caption2.monospacedDigit()).foregroundStyle(.tertiary)
                        Spacer()
                        Text(String(format: "%.1f bar target", t))
                            .font(.caption2.monospacedDigit()).foregroundStyle(.tertiary)
                    }
                }
            }

            // Secondary row
            HStack(spacing: 8) {
                if let t = tms?.temperatureC {
                    Label(String(format: "%.0f°C", t), systemImage: "thermometer.medium")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                if let v = tms?.vbattVolts {
                    Label(String(format: "%.2fV", v), systemImage: "battery.50percent")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
                if isLive {
                    HStack(spacing: 3) {
                        Circle().fill(Color.green).frame(width: 5, height: 5)
                        Text("Live").font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }

            if isPunctureRisk {
                Label("Pressure drop detected", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption2.weight(.semibold)).foregroundStyle(.red)
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 16).fill(cardBg))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(cardBorder, lineWidth: 1))
        .shadow(color: cardShadow, radius: 6, y: 2)
    }

    @ViewBuilder
    private var statusBadge: some View {
        if isPunctureRisk {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red).font(.callout)
        } else if sensor == nil {
            Image(systemName: "questionmark.circle").foregroundStyle(.tertiary).font(.callout)
        } else if !isLive {
            Image(systemName: "antenna.radiowaves.left.and.right.slash")
                .foregroundStyle(.secondary.opacity(0.45)).font(.callout)
        } else {
            Image(systemName: status.systemImage).foregroundStyle(status.color).font(.callout)
        }
    }

    @ViewBuilder
    private var pressureSection: some View {
        if let p = pressure {
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text(String(format: "%.2f", p))
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                    .foregroundStyle(status.color)
                    .minimumScaleFactor(0.7).lineLimit(1)
                VStack(alignment: .leading, spacing: 0) {
                    Text("bar").font(.caption.weight(.medium)).foregroundStyle(.secondary)
                    if let t = target {
                        Text("/ \(String(format: "%.1f", t))")
                            .font(.caption2).foregroundStyle(.tertiary)
                    }
                }
                Spacer()
            }
        } else if sensor != nil {
            Label("Out of range", systemImage: "antenna.radiowaves.left.and.right.slash")
                .font(.subheadline).foregroundStyle(.secondary).padding(.vertical, 6)
        } else {
            Text("No sensor paired")
                .font(.subheadline).foregroundStyle(.tertiary).padding(.vertical, 6)
        }
    }

    private var cardBg: Color {
        if isPunctureRisk           { return Color.red.opacity(0.07) }
        if sensor == nil || !isLive { return Color.secondary.opacity(0.06) }
        return status.color.opacity(0.07)
    }
    private var cardBorder: Color {
        if isPunctureRisk           { return Color.red.opacity(0.25) }
        if sensor == nil || !isLive { return Color.secondary.opacity(0.10) }
        return status.color.opacity(0.22)
    }
    private var cardShadow: Color {
        if sensor == nil || !isLive { return .clear }
        if isPunctureRisk { return Color.red.opacity(0.10) }
        return status.color.opacity(0.12)
    }
}

// MARK: - Legacy shape (kept for compatibility)

struct CarSilhouette: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        let w = rect.width, h = rect.height
        p.addRoundedRect(in: CGRect(x: w*0.05, y: h*0.35, width: w*0.90, height: h*0.50),
                         cornerSize: CGSize(width: w*0.08, height: h*0.08))
        p.addRoundedRect(in: CGRect(x: w*0.20, y: h*0.08, width: w*0.60, height: h*0.34),
                         cornerSize: CGSize(width: w*0.07, height: h*0.07))
        return p
    }
}
