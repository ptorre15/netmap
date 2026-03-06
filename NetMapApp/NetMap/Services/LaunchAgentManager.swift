#if os(macOS)
import Foundation

/// Manages a macOS LaunchAgent that auto-starts NetMap at login.
/// The plist is written to ~/Library/LaunchAgents/ and loaded via launchctl.
@MainActor
final class LaunchAgentManager: ObservableObject {

    static let shared = LaunchAgentManager()

    private let plistLabel = "com.phil.netmap.app"

    private var plistURL: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/LaunchAgents/\(plistLabel).plist")
    }

    @Published private(set) var isInstalled: Bool
    @Published private(set) var errorMessage: String? = nil

    init() {
        isInstalled = FileManager.default.fileExists(atPath:
            URL(fileURLWithPath: NSHomeDirectory())
                .appendingPathComponent("Library/LaunchAgents/com.phil.netmap.app.plist")
                .path
        )
    }

    // MARK: - Install

    func install() {
        errorMessage = nil
        guard let execPath = Bundle.main.executablePath else {
            errorMessage = "Cannot determine app executable path."
            return
        }

        let dict: [String: Any] = [
            "Label":            plistLabel,
            "ProgramArguments": [execPath],
            "RunAtLoad":        true,
            "KeepAlive":        false
        ]

        do {
            let data = try PropertyListSerialization.data(
                fromPropertyList: dict, format: .xml, options: 0
            )
            // Ensure directory exists
            try FileManager.default.createDirectory(
                at: plistURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: plistURL, options: .atomic)
            run("/bin/launchctl", args: ["load", "-w", plistURL.path])
            isInstalled = true
        } catch {
            errorMessage = "Install failed: \(error.localizedDescription)"
        }
    }

    // MARK: - Uninstall

    func uninstall() {
        errorMessage = nil
        run("/bin/launchctl", args: ["unload", "-w", plistURL.path])
        try? FileManager.default.removeItem(at: plistURL)
        isInstalled = false
    }

    // MARK: - Private

    @discardableResult
    private func run(_ executable: String, args: [String]) -> Int32 {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: executable)
        task.arguments = args
        // Suppress stdout/stderr from launchctl
        task.standardOutput = FileHandle.nullDevice
        task.standardError  = FileHandle.nullDevice
        try? task.run()
        task.waitUntilExit()
        return task.terminationStatus
    }
}
#endif
