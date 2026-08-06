import Foundation

#if canImport(Security)
import Security
#endif

/// Persistence for install identity and attribution state.
///
/// Install identity moved out of `UserDefaults`. `UserDefaults` is included in
/// iCloud and iTunes device backups, so restoring a backup onto a new device
/// carried the install id and its token across — producing attributed events
/// from a device that never installed from the link.
///
/// The Keychain items are written with
/// `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`, which is excluded from
/// backups and correctly device-scoped.
///
/// Non-identity state (the cached attribution result, the "attribution
/// complete" flag) stays in `UserDefaults`: it is not a credential, and keeping
/// it there avoids a Keychain round trip on every launch.
final class LinkFlowStore {

    private enum Key {
        static let installID = "com.linkflow.sdk.installId"
        static let installToken = "com.linkflow.sdk.installToken"
        static let attributionComplete = "linkflow_attribution_complete"
        static let lastResult = "linkflow_last_attribution_result"

        /// Pre-2.0 keys, read once so an upgrading app does not re-resolve.
        static let legacyInstallID = "linkflow_install_id"
        static let legacyFirstLaunch = "linkflow_first_launch"
    }

    private let defaults: UserDefaults
    private let service: String

    init(defaults: UserDefaults = .standard, service: String = "com.linkflow.sdk") {
        self.defaults = defaults
        self.service = service
    }

    // MARK: - Install identity

    var installID: String? {
        get { keychainRead(Key.installID) ?? defaults.string(forKey: Key.legacyInstallID) }
        set { keychainWrite(Key.installID, value: newValue) }
    }

    var installToken: String? {
        get { keychainRead(Key.installToken) }
        set { keychainWrite(Key.installToken, value: newValue) }
    }

    // MARK: - Attribution state

    /// Whether attribution has been resolved successfully at least once.
    ///
    /// The flag is set only after a successful response. The previous
    /// implementation set its first-launch marker *before* the network call, so a
    /// launch with no connectivity permanently lost the attribution.
    var attributionComplete: Bool {
        get {
            if defaults.bool(forKey: Key.attributionComplete) { return true }
            // Migration: a 1.x install that already resolved has the legacy flag set.
            return defaults.bool(forKey: Key.legacyFirstLaunch) && installID != nil
        }
        set { defaults.set(newValue, forKey: Key.attributionComplete) }
    }

    var lastResultJSON: [String: Any]? {
        get { defaults.dictionary(forKey: Key.lastResult) }
        set { defaults.set(newValue, forKey: Key.lastResult) }
    }

    /// Test/reset hook.
    func reset() {
        keychainWrite(Key.installID, value: nil)
        keychainWrite(Key.installToken, value: nil)
        defaults.removeObject(forKey: Key.attributionComplete)
        defaults.removeObject(forKey: Key.lastResult)
    }

    // MARK: - Keychain

    private func keychainRead(_ account: String) -> String? {
        #if canImport(Security)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let value = String(data: data, encoding: .utf8),
              !value.isEmpty else {
            return nil
        }
        return value
        #else
        // Non-Apple platforms (the Linux test build) have no Keychain.
        return defaults.string(forKey: account)
        #endif
    }

    private func keychainWrite(_ account: String, value: String?) {
        #if canImport(Security)
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]

        // Delete first: SecItemUpdate cannot change accessibility, and a stale
        // item written by an older build may have the wrong class.
        SecItemDelete(base as CFDictionary)

        guard let value, let data = value.data(using: .utf8) else { return }

        var attributes = base
        attributes[kSecValueData as String] = data
        // Excluded from backups, and unavailable until the device is first
        // unlocked after boot — which is fine, the SDK runs after launch.
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly

        SecItemAdd(attributes as CFDictionary, nil)
        #else
        if let value {
            defaults.set(value, forKey: account)
        } else {
            defaults.removeObject(forKey: account)
        }
        #endif
    }
}
