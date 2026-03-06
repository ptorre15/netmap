import LocalAuthentication
import Security
import Foundation

// MARK: - Errors

enum BiometricError: LocalizedError {
    case notAvailable
    case keychainReadFailed

    var errorDescription: String? {
        switch self {
        case .notAvailable:       return "Biometric authentication is not available on this device."
        case .keychainReadFailed: return "Could not retrieve saved credentials from Keychain."
        }
    }
}

// MARK: - Service

/// Manages Touch ID / Face ID login and the associated Keychain credential storage.
/// Credentials are protected by `biometryCurrentSet` — the item is invalidated automatically
/// if the user adds or removes a finger / face.
final class BiometricAuthService {

    static let shared = BiometricAuthService()
    private init() {}

    private let keychainService = Bundle.main.bundleIdentifier.map { "\($0).biometric" }
                                  ?? "io.netmap.biometric"
    private let keychainAccount = "login-credentials"

    // MARK: - Availability

    var biometryType: LABiometryType {
        let ctx = LAContext()
        var err: NSError?
        guard ctx.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &err) else {
            return .none
        }
        return ctx.biometryType
    }

    var isAvailable: Bool { biometryType != .none }

    /// Returns `true` if a Keychain item exists without triggering a biometric prompt.
    var hasSavedCredentials: Bool {
        let query: [CFString: Any] = [
            kSecClass:               kSecClassGenericPassword,
            kSecAttrService:         keychainService as CFString,
            kSecAttrAccount:         keychainAccount as CFString,
            kSecReturnData:          false,
            kSecUseAuthenticationUI: kSecUseAuthenticationUIFail,
        ]
        let status = SecItemCopyMatching(query as CFDictionary, nil)
        // errSecSuccess → item found without needing UI
        // errSecInteractionNotAllowed → item exists but requires biometric (expected)
        return status == errSecSuccess || status == errSecInteractionNotAllowed
    }

    // MARK: - Save

    struct Credentials: Codable {
        let email:    String
        let password: String
    }

    /// Stores credentials in Keychain protected by biometric authentication.
    /// Silently fails if biometrics are unavailable (graceful degradation).
    func saveCredentials(email: String, password: String) {
        guard isAvailable else { return }
        guard let data = try? JSONEncoder().encode(Credentials(email: email, password: password)) else { return }

        var cfError: Unmanaged<CFError>?
        guard let access = SecAccessControlCreateWithFlags(
            kCFAllocatorDefault,
            kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly,
            .biometryCurrentSet,  // invalidated if enrolled biometrics change
            &cfError
        ) else { return }

        // Remove any stale item first
        SecItemDelete([
            kSecClass:       kSecClassGenericPassword,
            kSecAttrService: keychainService as CFString,
            kSecAttrAccount: keychainAccount as CFString,
        ] as CFDictionary)

        SecItemAdd([
            kSecClass:             kSecClassGenericPassword,
            kSecAttrService:       keychainService as CFString,
            kSecAttrAccount:       keychainAccount as CFString,
            kSecValueData:         data,
            kSecAttrAccessControl: access,
        ] as CFDictionary, nil)
    }

    /// Removes saved credentials (e.g. on logout).
    func removeCredentials() {
        SecItemDelete([
            kSecClass:       kSecClassGenericPassword,
            kSecAttrService: keychainService as CFString,
            kSecAttrAccount: keychainAccount as CFString,
        ] as CFDictionary)
    }

    // MARK: - Load (triggers biometric prompt)

    /// Presents the system biometric prompt, then reads credentials from Keychain.
    /// - Parameter reason: The string shown to the user in the Touch ID / Face ID dialog.
    /// - Throws: `LAError` on biometric failure, `BiometricError.keychainReadFailed` if item is missing.
    func loadCredentials(reason: String) async throws -> Credentials {
        let context = LAContext()

        // Step 1: evaluate biometrics (wraps callback in async/await)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            context.evaluatePolicy(
                .deviceOwnerAuthenticationWithBiometrics,
                localizedReason: reason
            ) { success, error in
                if success {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: error ?? BiometricError.notAvailable)
                }
            }
        }

        // Step 2: read Keychain using the already-authenticated context (no second prompt)
        let query: [CFString: Any] = [
            kSecClass:                    kSecClassGenericPassword,
            kSecAttrService:              keychainService as CFString,
            kSecAttrAccount:              keychainAccount as CFString,
            kSecReturnData:               true,
            kSecUseAuthenticationContext: context,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess,
              let data = result as? Data,
              let creds = try? JSONDecoder().decode(Credentials.self, from: data)
        else { throw BiometricError.keychainReadFailed }

        return creds
    }
}
