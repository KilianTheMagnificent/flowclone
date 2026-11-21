import Foundation

/// Throwaway `UserDefaults` suites that stay out of ~/Library/Preferences.
///
/// A suite named like `flowclone.tests.<uuid>` is a persistent domain. `removePersistentDomain`
/// empties it, but cfprefsd then writes an empty `{}` plist about ten seconds after the test
/// process has exited, so every run used to leave a 42-byte file per suite behind (26,000 of them
/// by October 2026). A suite named by an absolute path keeps its plist beside that path instead,
/// so these suites live in one temp directory per test process, removed again when it exits.
///
///     let suite = ScratchDefaults.name("history")
///     let defaults = UserDefaults(suiteName: suite)!
///     defer { defaults.removePersistentDomain(forName: suite) }
enum ScratchDefaults {
    private static let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("flowclone-test-defaults-\(UUID().uuidString)", isDirectory: true)

    private static let prepared: Void = {
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        atexit { try? FileManager.default.removeItem(at: ScratchDefaults.root) }
    }()

    /// A new suite name for `UserDefaults(suiteName:)`; `label` only makes the files readable.
    static func name(_ label: String) -> String {
        _ = prepared
        return root.appendingPathComponent("\(label)-\(UUID().uuidString)").path
    }
}
