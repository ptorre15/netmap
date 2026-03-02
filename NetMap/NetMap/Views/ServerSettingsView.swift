import SwiftUI

struct ServerSettingsView: View {
    @EnvironmentObject var serverClient: NetMapServerClient

    @State private var hostDraft   = ""
    @State private var portDraft   = ""
    @State private var apiKeyDraft = ""
    @State private var isTesting   = false

    var body: some View {
        Form {

            // ── Status / Enable ──────────────────────────────────────────
            Section {
                HStack(spacing: 12) {
                    ZStack {
                        Circle()
                            .fill(serverClient.connectionStatus.color.opacity(0.15))
                            .frame(width: 36, height: 36)
                        Image(systemName: serverClient.connectionStatus.systemImage)
                            .foregroundStyle(serverClient.connectionStatus.color)
                            .font(.system(size: 17, weight: .semibold))
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(serverClient.isEnabled ? "Forwarding enabled" : "Forwarding disabled")
                            .font(.subheadline.weight(.medium))
                        Text(serverClient.connectionStatus.label)
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Toggle("", isOn: $serverClient.isEnabled).labelsHidden()
                }
                .padding(.vertical, 4)

                if let err = serverClient.lastErrorMessage {
                    Label(err, systemImage: "exclamationmark.circle")
                        .font(.caption).foregroundStyle(.red)
                        .lineLimit(3)
                }
            } header: {
                Text("Remote Server")
            } footer: {
                Text("When enabled, every TMS sensor reading is forwarded to the NetMapServer in real-time over HTTP/JSON.")
            }

            // ── Address ──────────────────────────────────────────────────
            Section("Server Address") {
                HStack {
                    Label("Host", systemImage: "network")
                        .frame(width: 76, alignment: .leading)
                    TextField("192.168.1.x  or  hostname", text: $hostDraft)
                        .autocorrectionDisabled()
                    #if os(iOS)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                    #endif
                }

                HStack {
                    Label("Port", systemImage: "number")
                        .frame(width: 76, alignment: .leading)
                    TextField("8765", text: $portDraft)
                    #if os(iOS)
                        .keyboardType(.numberPad)
                    #endif
                }

                HStack {
                    Label("API Key", systemImage: "key")
                        .frame(width: 76, alignment: .leading)
                    TextField("netmap-dev", text: $apiKeyDraft)
                        .autocorrectionDisabled()
                    #if os(iOS)
                        .textInputAutocapitalization(.never)
                    #endif
                }

                Button {
                    applyDraft()
                    isTesting = true
                    Task {
                        await serverClient.testConnection()
                        isTesting = false
                    }
                } label: {
                    HStack(spacing: 7) {
                        if isTesting {
                            ProgressView().scaleEffect(0.8)
                        } else {
                            Image(systemName: "bolt.horizontal.circle")
                        }
                        Text(isTesting ? "Testing…" : "Test Connection")
                    }
                }
                .disabled(isTesting)
            }

            // ── Stats ────────────────────────────────────────────────────
            Section("Statistics") {
                LabeledContent("Total records sent") {
                    Text("\(serverClient.totalSent)")
                        .monospacedDigit().foregroundStyle(.secondary)
                }
                LabeledContent("Pending in queue") {
                    Text("\(serverClient.pendingCount)")
                        .monospacedDigit()
                        .foregroundStyle(serverClient.pendingCount > 0 ? .orange : .secondary)
                }

                if serverClient.pendingCount > 0 {
                    HStack(spacing: 12) {
                        Button {
                            serverClient.retryNow()
                        } label: {
                            Label("Retry now", systemImage: "arrow.clockwise")
                        }
                        Divider().frame(height: 18)
                        Button(role: .destructive) {
                            serverClient.clearQueue()
                        } label: {
                            Label("Clear queue", systemImage: "trash")
                        }
                    }
                }
            }

            // ── Quick Setup Guide ────────────────────────────────────────
            Section {
                VStack(alignment: .leading, spacing: 10) {
                    Label("Start the server (macOS / Linux):", systemImage: "terminal")
                        .font(.caption.weight(.semibold))

                    Text("""
                    cd NetMapServer
                    swift run App
                    """)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .padding(8)
                    .background(
                        RoundedRectangle(cornerRadius: 7)
                            .fill(Color.secondary.opacity(0.07))
                    )

                    Text("Default port: **8765** — override with `PORT=xxxx swift run App`")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                .padding(.vertical, 2)
            } header: {
                Text("Server Setup")
            }
        }
        .navigationTitle("Server Settings")
        #if os(macOS)
        .formStyle(.grouped)
        #endif
        .onAppear {
            hostDraft   = serverClient.host
            portDraft   = String(serverClient.port)
            apiKeyDraft = serverClient.apiKey
        }
        .onDisappear { applyDraft() }
    }

    private func applyDraft() {
        let h = hostDraft.trimmingCharacters(in: .whitespaces)
        if !h.isEmpty { serverClient.host = h }
        if let p = Int(portDraft.trimmingCharacters(in: .whitespaces)),
           p > 0, p < 65536 {
            serverClient.port = p
        }
        let k = apiKeyDraft.trimmingCharacters(in: .whitespaces)
        if !k.isEmpty { serverClient.apiKey = k }
    }
}
