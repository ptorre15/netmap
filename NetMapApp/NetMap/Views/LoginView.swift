import SwiftUI

struct LoginView: View {
    @EnvironmentObject var serverClient: NetMapServerClient
    @Environment(\.dismiss) private var dismiss

    @State private var email       = ""
    @State private var password    = ""
    @State private var isLoading   = false
    @State private var errorMsg:   String? = nil

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            // ── Card ──────────────────────────────────────────────────────
            VStack(spacing: 28) {

                // Logo / title
                VStack(spacing: 8) {
                    Image(systemName: "gauge.open.with.lines.needle.33percent")
                        .font(.system(size: 48, weight: .light))
                        .foregroundStyle(.tint)
                    Text("NetMap")
                        .font(.largeTitle.weight(.bold))
                    Text("Sign in to \(serverClient.host)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                // ── Form ─────────────────────────────────────────────────
                VStack(spacing: 12) {
                    TextField("Email address", text: $email)
                        .textContentType(.emailAddress)
                        .autocorrectionDisabled()
                    #if os(iOS)
                        .keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never)
                    #endif
                        .padding(12)
                        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))

                    SecureField("Password", text: $password)
                        .textContentType(.password)
                        .padding(12)
                        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))

                    if let err = errorMsg {
                        Label(err, systemImage: "exclamationmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(.red)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 4)
                    }
                }

                // ── Button ───────────────────────────────────────────────
                Button {
                    Task { await doLogin() }
                } label: {
                    Group {
                        if isLoading {
                            ProgressView().tint(.white)
                        } else {
                            Text("Sign In").fontWeight(.semibold)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 13)
                    .foregroundStyle(.white)
                    .background(canSubmit ? Color.accentColor : Color.accentColor.opacity(0.4),
                                in: RoundedRectangle(cornerRadius: 12))
                }
                .disabled(!canSubmit || isLoading)
                .buttonStyle(.plain)
            }
            .padding(32)
            .background(.background, in: RoundedRectangle(cornerRadius: 20))
            #if os(iOS)
            .shadow(color: .black.opacity(0.12), radius: 20, y: 4)
            #endif
            .padding(.horizontal, 24)
            .frame(maxWidth: 420)

            Spacer()

            // ── Footer ────────────────────────────────────────────────────
            VStack(spacing: 6) {
                Button("Continue without signing in") {
                    dismiss()
                }
                .font(.subheadline)
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)

                Text("Contact your administrator to create an account.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button("Change server settings") {
                    NotificationCenter.default.post(name: .showServerSettings, object: nil)
                }
                .font(.caption2)
                .buttonStyle(.plain)
                .foregroundStyle(.tint)
            }
            .padding(.bottom, 20)
        }
        #if os(iOS)
        .background(Color(.systemGroupedBackground))
        #else
        .background(Color(.windowBackgroundColor))
        #endif
        .onSubmit { Task { await doLogin() } }
    }

    // MARK: - Logic

    private var canSubmit: Bool {
        email.contains("@") && !password.isEmpty
    }

    @MainActor
    private func doLogin() async {
        errorMsg  = nil
        isLoading = true
        defer { isLoading = false }
        do {
            try await serverClient.login(email: email.trimmingCharacters(in: .whitespaces),
                                         password: password)
        } catch NetMapServerError.invalidCredentials {
            errorMsg = "Invalid email or password."
        } catch NetMapServerError.noNetwork {
            errorMsg = "Cannot reach the server — check host & port in Settings."
        } catch NetMapServerError.timedOut {
            errorMsg = "Server did not respond. Is it running?"
        } catch {
            errorMsg = error.localizedDescription
        }
    }
}

// MARK: - Notification names

extension Notification.Name {
    static let showServerSettings = Notification.Name("netmap.showServerSettings")
}
