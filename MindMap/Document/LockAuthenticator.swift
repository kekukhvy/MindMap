import Foundation
import LocalAuthentication

/// Outcome of one authentication prompt.
enum LockAuthResult: Equatable {
    case success
    /// User / system / app cancelled: no message.
    case cancelled
    /// Wrong attempts, locked out, …: message for the lock screen.
    case failed(String)
    /// No passcode / password set, no biometry and no fallback…
    case unavailable(String)
}

/// Device-owner check before a lock key is used. Real: `LAContext`; tests
/// use a mock (success / failure / cancel).
protocol LockAuthenticator: AnyObject {
    /// "Face ID", "Touch ID", "Optic ID" or "Passcode" / "Password".
    var methodName: String { get }
    /// SF Symbol of `methodName`.
    var methodSymbol: String { get }
    /// nil when the device can authenticate the owner, else why not.
    func availabilityProblem() -> String?
    @MainActor func authenticate(reason: String) async -> LockAuthResult
}

/// `LAPolicy.deviceOwnerAuthentication`: Face ID / Touch ID (Apple Watch on
/// a Mac where enabled) with the SYSTEM passcode / Mac password as fallback.
/// No app-specific password, no recovery key (user decision 2026-11-12).
final class DeviceOwnerAuthenticator: LockAuthenticator {
    init() {}

    private var biometryType: LABiometryType {
        let context = LAContext()
        _ = context.canEvaluatePolicy(.deviceOwnerAuthentication, error: nil)
        return context.biometryType
    }

    var methodName: String {
        switch biometryType {
        case .faceID: return "Face ID"
        case .touchID: return "Touch ID"
        case .opticID: return "Optic ID"
        default:
            #if os(macOS)
            return "Password"
            #else
            return "Passcode"
            #endif
        }
    }

    var methodSymbol: String {
        switch biometryType {
        case .faceID: return "faceid"
        case .touchID: return "touchid"
        case .opticID: return "opticid"
        default: return "lock.open"
        }
    }

    func availabilityProblem() -> String? {
        var error: NSError?
        guard !LAContext().canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else { return nil }
        if let code = error.flatMap({ LAError.Code(rawValue: $0.code) }), code == .passcodeNotSet {
            #if os(macOS)
            return "Set a login password for this Mac first — it unlocks locked maps when Touch ID is not available."
            #else
            return "Set a device passcode first (Settings › Face ID & Passcode) — it unlocks locked maps when Face ID is not available."
            #endif
        }
        return error?.localizedDescription ?? "This device cannot verify its owner."
    }

    @MainActor
    func authenticate(reason: String) async -> LockAuthResult {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            return .unavailable(availabilityProblem() ?? error?.localizedDescription ?? "Authentication is not available.")
        }
        do {
            let ok = try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)
            return ok ? .success : .failed("Authentication failed.")
        } catch let error as LAError {
            switch error.code {
            case .userCancel, .appCancel, .systemCancel, .userFallback:
                return .cancelled
            case .passcodeNotSet:
                return .unavailable(availabilityProblem() ?? error.localizedDescription)
            default:
                return .failed(error.localizedDescription)
            }
        } catch {
            return .failed(error.localizedDescription)
        }
    }
}

/// Key store + authenticator used by documents (tests inject their own).
final class LockServices {
    nonisolated(unsafe) static var shared = LockServices(keyStore: KeychainKeyStore(),
                                                         authenticator: DeviceOwnerAuthenticator())

    let keyStore: LockKeyStore
    let authenticator: LockAuthenticator

    init(keyStore: LockKeyStore, authenticator: LockAuthenticator) {
        self.keyStore = keyStore
        self.authenticator = authenticator
    }
}
