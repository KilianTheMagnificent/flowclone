import Foundation
import Security
import LocalAuthentication

/// Update access belongs to an installation, not to a distributable archive. Keychain
/// grants access to the signed app; neither migration nor diagnostics prints the value.
enum UpdateAccess {
    private static let service = "com.andre.flowclone.updates"
    private static let account = "github-releases"

    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service, kSecAttrAccount as String: account]
    }

    static func read() -> String? {
        guard !suppressHostAccess else { return nil }
        var request = query
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        // Automatic background checks must not summon a Keychain permission dialog.
        let context = LAContext()
        context.interactionNotAllowed = true
        request[kSecUseAuthenticationContext as String] = context
        var result: CFTypeRef?
        guard SecItemCopyMatching(request as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let value = String(data: data, encoding: .utf8), !value.isEmpty else { return nil }
        return value
    }

    /// Only a predecessor signed by this app's trusted developer can supply access.
    /// Leave the old bundle in place if storage fails, so a later launch can retry.
    @discardableResult
    static func migrate(previous: URL,
                        verify: (URL) throws -> Void = Updater.verify,
                        store: (String) -> Bool = save) -> Bool {
        guard FileManager.default.fileExists(atPath: previous.path) else { return false }
        do {
            try verify(previous)
            let plist = previous.appendingPathComponent("Contents/Info.plist")
            guard let value = NSDictionary(contentsOf: plist)?["FlowCloneUpdateToken"] as? String,
                  !value.isEmpty else { return false }
            guard store(value) else {
                log("updater: local access migration failed; previous app retained")
                return false
            }
            log("updater: migrated update access to this Mac's Keychain")
            return true
        } catch {
            log("updater: previous app could not be verified for access migration")
            return false
        }
    }

    private static func save(_ value: String) -> Bool {
        guard !suppressHostAccess else { return false }
        var item = query
        item[kSecValueData as String] = Data(value.utf8)
        item[kSecAttrLabel as String] = "FlowClone automatic updates"
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let result = SecItemAdd(item as CFDictionary, nil)
        return result == errSecSuccess || (result == errSecDuplicateItem && read() != nil)
    }
}
