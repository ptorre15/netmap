import Vapor
import Fluent

struct TrackerConfigProfileController: RouteCollection {

    func boot(routes: RoutesBuilder) throws {
        let admin = routes
            .grouped("api", "admin")
            .grouped(BearerAuthMiddleware())
            .grouped(AdminMiddleware())

        admin.get   ("tracker-config-profiles",        use: listProfiles)   // GET    /api/admin/tracker-config-profiles
        admin.post  ("tracker-config-profiles",        use: createProfile)  // POST   /api/admin/tracker-config-profiles
        admin.put   ("tracker-config-profiles", ":id", use: updateProfile)  // PUT    /api/admin/tracker-config-profiles/:id
        admin.delete("tracker-config-profiles", ":id", use: deleteProfile)  // DELETE /api/admin/tracker-config-profiles/:id
    }

    // ─── DTOs ─────────────────────────────────────────────────────────────────

    struct ProfileSystemPayload: Content {
        var pingIntervalMin: Int
        var sleepDelayMin: Int
        var wakeUpSourcesEnabled: [String]
    }

    struct ProfileThresholdsPayload: Content {
        var harshBraking: Double
        var harshAcceleration: Double
        var harshCornering: Double
        var overspeed: Double
    }

    struct ProfileDriverBehaviorPayload: Content {
        var thresholds: ProfileThresholdsPayload
        var minimumSpeedKmh: Int
        var beepEnabled: Bool
    }

    struct ProfileDTO: Content {
        var id: String?
        var name: String
        var description: String?
        var version: Int?
        var system: ProfileSystemPayload
        var driverBehavior: ProfileDriverBehaviorPayload
        var createdBy: String?
        var createdAt: Date?
        var updatedAt: Date?
    }

    // ─── Helpers ──────────────────────────────────────────────────────────────

    private let allowedWakeSources: Set<String> = ["VOLTAGE_RISE", "CAN_ACTIVITY", "TIMER_BACKUP", "ESPNOW_HMI", "IMU_MOTION"]

    private func buildDTO(from p: TrackerConfigProfile) -> ProfileDTO {
        let wakes = (try? JSONDecoder().decode([String].self, from: Data(p.wakeUpSourcesJSON.utf8))) ?? []
        return ProfileDTO(
            id:          p.id?.uuidString,
            name:        p.name,
            description: p.description,
            version:     p.version ?? 1,
            system: ProfileSystemPayload(
                pingIntervalMin:      p.pingIntervalMin,
                sleepDelayMin:        p.sleepDelayMin,
                wakeUpSourcesEnabled: wakes
            ),
            driverBehavior: ProfileDriverBehaviorPayload(
                thresholds: ProfileThresholdsPayload(
                    harshBraking:      p.thresholdHarshBraking,
                    harshAcceleration: p.thresholdHarshAcceleration,
                    harshCornering:    p.thresholdHarshCornering,
                    overspeed:         p.thresholdOverspeedKmh
                ),
                minimumSpeedKmh: p.minimumSpeedKmh,
                beepEnabled:     p.beepEnabled
            ),
            createdBy: p.createdBy,
            createdAt: p.createdAt,
            updatedAt: p.updatedAt
        )
    }

    private func validate(_ dto: ProfileDTO) throws {
        let name = dto.name.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { throw Abort(.badRequest, reason: "Profile name is required.") }
        guard name.count <= 80 else { throw Abort(.badRequest, reason: "Name must not exceed 80 characters.") }
        guard (1...1440).contains(dto.system.pingIntervalMin) else {
            throw Abort(.badRequest, reason: "system.pingIntervalMin must be between 1 and 1440.")
        }
        guard (1...10080).contains(dto.system.sleepDelayMin) else {
            throw Abort(.badRequest, reason: "system.sleepDelayMin must be between 1 and 10080.")
        }
        guard !dto.system.wakeUpSourcesEnabled.isEmpty else {
            throw Abort(.badRequest, reason: "system.wakeUpSourcesEnabled cannot be empty.")
        }
        for src in dto.system.wakeUpSourcesEnabled {
            guard allowedWakeSources.contains(src) else {
                throw Abort(.badRequest, reason: "Invalid wake-up source: \(src).")
            }
        }
        let t = dto.driverBehavior.thresholds
        guard t.harshBraking > 0 else {
            throw Abort(.badRequest, reason: "driverBehavior.thresholds.harshBraking must be > 0.")
        }
        guard t.harshAcceleration > 0 else {
            throw Abort(.badRequest, reason: "driverBehavior.thresholds.harshAcceleration must be > 0.")
        }
        guard t.harshCornering > 0 else {
            throw Abort(.badRequest, reason: "driverBehavior.thresholds.harshCornering must be > 0.")
        }
        guard (1.0...300.0).contains(t.overspeed) else {
            throw Abort(.badRequest, reason: "driverBehavior.thresholds.overspeed must be between 1 and 300.")
        }
        guard (0...250).contains(dto.driverBehavior.minimumSpeedKmh) else {
            throw Abort(.badRequest, reason: "driverBehavior.minimumSpeedKmh must be between 0 and 250.")
        }
    }

    private func applyDTO(_ dto: ProfileDTO, to profile: TrackerConfigProfile, actor: String?) throws {
        let wakeJSON: String
        if let data = try? JSONEncoder().encode(dto.system.wakeUpSourcesEnabled),
           let str  = String(data: data, encoding: .utf8) {
            wakeJSON = str
        } else {
            wakeJSON = "[]"
        }
        profile.name                       = dto.name.trimmingCharacters(in: .whitespaces)
        profile.description                = (dto.description?.isEmpty == false) ? dto.description : nil
        profile.pingIntervalMin            = dto.system.pingIntervalMin
        profile.sleepDelayMin              = dto.system.sleepDelayMin
        profile.wakeUpSourcesJSON          = wakeJSON
        profile.thresholdHarshBraking      = dto.driverBehavior.thresholds.harshBraking
        profile.thresholdHarshAcceleration = dto.driverBehavior.thresholds.harshAcceleration
        profile.thresholdHarshCornering    = dto.driverBehavior.thresholds.harshCornering
        profile.thresholdOverspeedKmh      = dto.driverBehavior.thresholds.overspeed
        profile.minimumSpeedKmh            = dto.driverBehavior.minimumSpeedKmh
        profile.beepEnabled                = dto.driverBehavior.beepEnabled
        if let a = actor { profile.createdBy = a }
    }

    // ─── Route Handlers ───────────────────────────────────────────────────────

    /// GET /api/admin/tracker-config-profiles
    func listProfiles(req: Request) async throws -> [ProfileDTO] {
        let profiles = try await TrackerConfigProfile.query(on: req.db)
            .sort(\.$name)
            .all()
        return profiles.map { buildDTO(from: $0) }
    }

    /// POST /api/admin/tracker-config-profiles
    func createProfile(req: Request) async throws -> Response {
        let dto = try req.content.decode(ProfileDTO.self)
        try validate(dto)
        let profile = TrackerConfigProfile()
        try applyDTO(dto, to: profile, actor: req.authUser?.email)
        profile.version = 1
        try await profile.save(on: req.db)
        await req.auditSecurityEvent(
            action: "admin.tracker_config_profile.create",
            targetType: "tracker_config_profile",
            targetID: profile.id?.uuidString,
            metadata: ["name": profile.name]
        )
        let out = buildDTO(from: profile)
        return try await out.encodeResponse(status: .created, for: req)
    }

    /// PUT /api/admin/tracker-config-profiles/:id
    func updateProfile(req: Request) async throws -> ProfileDTO {
        guard let idStr    = req.parameters.get("id"),
              let id       = UUID(uuidString: idStr),
              let profile  = try await TrackerConfigProfile.find(id, on: req.db)
        else { throw Abort(.notFound, reason: "Profile not found.") }
        let dto = try req.content.decode(ProfileDTO.self)
        try validate(dto)
        try applyDTO(dto, to: profile, actor: nil)
        profile.version = (profile.version ?? 1) + 1
        try await profile.save(on: req.db)
        await req.auditSecurityEvent(
            action: "admin.tracker_config_profile.update",
            targetType: "tracker_config_profile",
            targetID: profile.id?.uuidString,
            metadata: ["name": profile.name]
        )
        return buildDTO(from: profile)
    }

    /// DELETE /api/admin/tracker-config-profiles/:id
    func deleteProfile(req: Request) async throws -> HTTPStatus {
        guard let idStr   = req.parameters.get("id"),
              let id      = UUID(uuidString: idStr),
              let profile = try await TrackerConfigProfile.find(id, on: req.db)
        else { throw Abort(.notFound, reason: "Profile not found.") }
        let name = profile.name
        try await profile.delete(on: req.db)
        await req.auditSecurityEvent(
            action: "admin.tracker_config_profile.delete",
            targetType: "tracker_config_profile",
            targetID: id.uuidString,
            metadata: ["name": name]
        )
        return .noContent
    }
}
