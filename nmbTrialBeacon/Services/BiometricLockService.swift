//
//  BiometricLockService.swift
//  nmbTrialBeacon
//
//  App lock via LocalAuthentication. Preference key is shared with Settings.bundle
//  so iPhone Settings → TrialBeacon and in-app Settings stay in sync.
//

import Foundation
import LocalAuthentication
import Observation

@MainActor
@Observable
final class BiometricLockService {
    static let shared = BiometricLockService()

    /// UserDefaults / Settings.bundle / `@AppStorage` key.
    static let enabledKey = "biometricAuthEnabled"

    private(set) var isUnlocked = false
    private(set) var isAuthenticating = false
    private(set) var biometryType: LABiometryType = .none
    /// True when Face ID, Touch ID, Optic ID, or device passcode can satisfy the policy.
    private(set) var canUseDeviceAuthentication = false
    private(set) var lastErrorMessage: String?

    private var isInBackground = false

    /// Mirrors Settings.bundle + in-app toggle.
    var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: Self.enabledKey)
    }

    var needsUnlock: Bool { isEnabled && !isUnlocked }

    var unlockButtonTitle: String {
        switch biometryType {
        case .faceID: return "Unlock with Face ID"
        case .touchID: return "Unlock with Touch ID"
        case .opticID: return "Unlock with Optic ID"
        default: return "Unlock"
        }
    }

    var settingsToggleLabel: String {
        switch biometryType {
        case .faceID: return "Lock with Face ID"
        case .touchID: return "Lock with Touch ID"
        case .opticID: return "Lock with Optic ID"
        default: return "Lock with Passcode"
        }
    }

    var settingsToggleSymbol: String {
        switch biometryType {
        case .faceID: return "faceid"
        case .touchID: return "touchid"
        case .opticID: return "opticid"
        default: return "lock.fill"
        }
    }

    private init() {
        refreshAvailability()
        // Cold start: require unlock when the preference is already on.
        if !isEnabled {
            isUnlocked = true
        }
        // Singleton lives for the process; no removal needed.
        NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.handlePreferenceChangedFromOutside()
            }
        }
    }

    func refreshAvailability() {
        let context = LAContext()
        var error: NSError?
        canUseDeviceAuthentication = context.canEvaluatePolicy(
            .deviceOwnerAuthentication,
            error: &error
        )
        // Meaningful even when only passcode is available (then `.none`).
        biometryType = context.biometryType
    }

    /// Call when the scene enters the background. Hides content in the app switcher.
    func handleEnteredBackground() {
        isInBackground = true
        guard isEnabled else { return }
        isUnlocked = false
        lastErrorMessage = nil
    }

    /// Call when the scene becomes active. Syncs lock state; the lock cover prompts LA.
    func handleBecameActive() {
        refreshAvailability()
        let returningFromBackground = isInBackground
        isInBackground = false

        if !isEnabled {
            isUnlocked = true
            lastErrorMessage = nil
            return
        }

        // Covers normal resume and enabling lock in iPhone Settings while away.
        if returningFromBackground {
            isUnlocked = false
        }
    }

    /// In-app toggle. Returns the value that should be stored in `@AppStorage`.
    @discardableResult
    func applyEnabled(_ wantEnabled: Bool) async -> Bool {
        refreshAvailability()
        if wantEnabled {
            guard canUseDeviceAuthentication else {
                lastErrorMessage = "Set a device passcode in iPhone Settings to use app lock."
                return false
            }
            let ok = await authenticate(
                reason: "Enable app lock for TrialBeacon",
                ignoringEnabledPreference: true
            )
            guard ok else { return false }
            UserDefaults.standard.set(true, forKey: Self.enabledKey)
            isUnlocked = true
            return true
        } else {
            UserDefaults.standard.set(false, forKey: Self.enabledKey)
            isUnlocked = true
            lastErrorMessage = nil
            return false
        }
    }

    @discardableResult
    func authenticate(
        reason: String = "Unlock TrialBeacon",
        ignoringEnabledPreference: Bool = false
    ) async -> Bool {
        refreshAvailability()
        if !ignoringEnabledPreference && !isEnabled {
            isUnlocked = true
            return true
        }
        guard canUseDeviceAuthentication else {
            lastErrorMessage = "Set a device passcode in iPhone Settings to unlock."
            return false
        }
        guard !isAuthenticating else { return false }

        isAuthenticating = true
        lastErrorMessage = nil
        defer { isAuthenticating = false }

        let context = LAContext()
        context.localizedCancelTitle = "Cancel"
        // Biometrics when available; device passcode as fallback (matches Settings copy).
        do {
            let success = try await context.evaluatePolicy(
                .deviceOwnerAuthentication,
                localizedReason: reason
            )
            if success {
                isUnlocked = true
                lastErrorMessage = nil
            }
            return success
        } catch {
            // User cancel is common — keep the cover, no alarming copy.
            let ns = error as NSError
            if ns.domain == LAErrorDomain,
               let code = LAError.Code(rawValue: ns.code),
               code == .userCancel || code == .appCancel || code == .systemCancel {
                lastErrorMessage = nil
            } else {
                lastErrorMessage = error.localizedDescription
            }
            return false
        }
    }

    private func handlePreferenceChangedFromOutside() {
        refreshAvailability()
        if !isEnabled {
            isUnlocked = true
            lastErrorMessage = nil
        }
    }
}
