import AppKit
import Security
import CryptoKit

@MainActor
enum AppTermination {
    static var isRelaunching = false
    static var explicitUserQuit = false

    static func reset() {
        isRelaunching = false
        explicitUserQuit = false
    }

    static func requestUserQuit() {
        explicitUserQuit = true
        isRelaunching = false
        log("quit")
        flushLog()
        NSApp.terminate(nil)
    }
}

/// Self-update from an installer-only public feed; no account is needed on a fresh Mac.
/// Legacy private-feed probes can still use this installation's local update access.
/// The designated requirement preserves update trust and Accessibility/microphone identity.
@MainActor
enum Updater {
    static let defaultRepo = Bundle.main.object(forInfoDictionaryKey: "FlowCloneUpdateRepository") as? String
        ?? "KilianTheMagnificent/flowclone-updates"
    nonisolated static let interval: TimeInterval = 6 * 3600
    /// True while active work is running or (for unattended checks) FlowClone's main window is open.
    static var sessionActive: () -> Bool = { false }
    /// True only while active dictation, transform, or meeting work must not be interrupted.
    static var workActive: () -> Bool = { false }
    static var reserveForInstall: () async -> Bool = { true }
    static var releaseInstallReservation: () -> Void = {}
    static var destinationBundleURL: () -> URL = { Bundle.main.bundleURL }
    static var performRelaunch: @MainActor (URL) -> Bool = { relaunch($0) }
    static var verifyBundle: @Sendable (URL) throws -> Void = { try verify($0) }
    nonisolated static let didChange = Notification.Name("FlowCloneUpdaterDidChange")
    private(set) static var isInstalling = false { didSet { notifyStateChanged() } }
    private(set) static var isChecking = false { didSet { notifyStateChanged() } }
    static var isBusy: Bool { isChecking || isInstalling }
    private static var idleRetry: DispatchWorkItem?
    /// Set once this process has swapped in an update: its own bundle now sits at
    /// `FlowClone.app.old` and is the only copy the relaunch helper can restore.
    private(set) static var keepsPreviousBundleForRollback = false
    private static var installedBuildAwaitingRelaunch: Int?
    private static var lastAttempt = Date.distantPast
    private static var quickRetries = 0
    private static var wakeObserver: NSObjectProtocol?
    nonisolated static let quickRetryDelay: TimeInterval = 15 * 60
    nonisolated static let maximumQuickRetries = 3
    /// The new build removes its predecessor only after the relaunch helper's watch has ended.
    nonisolated static let previousBundleCleanupDelay: TimeInterval = 60
    nonisolated static let failedBuildKey = "updateFailedBuild"
    nonisolated static let failedAtKey = "updateFailedAt"
    nonisolated static let incompatibleKey = "updateIncompatible"
    nonisolated static let failedBuildRetryAfter: TimeInterval = 7 * 24 * 3600
    nonisolated private static let network: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 600
        return URLSession(configuration: configuration)
    }()
    nonisolated static let maximumDownloadBytes: Int64 = 128 * 1_024 * 1_024
    /// One line for the status menu.
    private(set) static var status = "Updates: not checked yet" { didSet { notifyStateChanged() } }
    private static var timer: Timer?
    private static var staged: (build: Int, version: String, location: Staging)? { didSet { notifyStateChanged() } }
    static var hasStagedUpdate: Bool { staged != nil }

    private static func notifyStateChanged() {
        NotificationCenter.default.post(name: didChange, object: nil)
    }

    /// The GitHub "latest release" payload, reduced to what the manifest needs.
    struct Release: Decodable, Sendable {
        struct Asset: Decodable, Sendable {
            let name: String
            let url: URL          // API asset URL; GET with Accept: application/octet-stream
            let size: Int64?
            let digest: String?
        }
        let tagName: String
        let assets: [Asset]
    }

    struct Manifest: Equatable, Sendable {
        let build: Int
        let version: String
        let url: URL
        let digest: String

        /// Tag `b<build>` + asset `FlowClone-<version>-<build>.zip` — the contract with build.sh.
        init(_ r: Release, expectedRepo: String? = nil) throws {
            let suffix = r.tagName.dropFirst()
            guard r.tagName.first == "b", !suffix.isEmpty,
                  suffix.allSatisfy({ $0.isASCII && $0.isNumber }),
                  let build = Int(suffix), build > 0, String(build) == suffix else {
                throw UpdateError("release tag is not b<positive build>")
            }
            let candidates = r.assets.filter {
                $0.name.hasPrefix("FlowClone-") && $0.name.hasSuffix("-\(build).zip")
            }
            guard candidates.count == 1, let zip = candidates.first else {
                throw UpdateError("release must have exactly one FlowClone-<version>-<build>.zip")
            }
            let version = String(zip.name.dropFirst("FlowClone-".count).dropLast("-\(build).zip".count))
            guard validVersion(version), isTrustedAPIURL(zip.url),
                  zip.url.path.range(of: #"^/repos/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+/releases/assets/[1-9][0-9]*$"#,
                                     options: .regularExpression) != nil,
                  expectedRepo.map({ zip.url.path.hasPrefix("/repos/\($0)/releases/assets/") }) ?? true,
                  zip.size.map({ $0 > 0 && $0 <= maximumDownloadBytes }) ?? true else {
                throw UpdateError("invalid update asset metadata")
            }
            guard let rawDigest = zip.digest?.lowercased(),
                  rawDigest.hasPrefix("sha256:"), rawDigest.count == 71,
                  rawDigest.dropFirst(7).allSatisfy({ $0.isASCII && $0.isHexDigit }) else {
                throw UpdateError("missing or invalid archive digest")
            }
            self.build = build
            self.version = version
            url = zip.url
            digest = rawDigest
        }
    }

    nonisolated static func validVersion(_ version: String) -> Bool {
        let parts = version.split(separator: ".", omittingEmptySubsequences: false)
        return (1...4).contains(parts.count) && parts.allSatisfy {
            !$0.isEmpty && $0.allSatisfy { $0.isASCII && $0.isNumber }
        }
    }

    nonisolated static func isTrustedAPIURL(_ url: URL) -> Bool {
        url.scheme == "https" && url.host == "api.github.com"
            && (url.port == nil || url.port == 443) && url.user == nil && url.password == nil
            && url.query == nil && url.fragment == nil
    }

    struct UpdateError: Error, CustomStringConvertible {
        let description: String
        let permitsAccessRetry: Bool
        /// A correctly signed update that this Mac cannot run (newer macOS, other processor).
        let incompatibleWithThisMac: Bool
        init(_ d: String, permitsAccessRetry: Bool = false, incompatibleWithThisMac: Bool = false) {
            description = d
            self.permitsAccessRetry = permitsAccessRetry
            self.incompatibleWithThisMac = incompatibleWithThisMac
        }
    }

    static var currentBuild: Int { bundleBuild(Bundle.main.bundleURL) ?? 0 }

    nonisolated static func bundleBuild(_ app: URL) -> Int? {
        let plist = app.appendingPathComponent("Contents/Info.plist")
        guard let d = NSDictionary(contentsOf: plist), let s = d["CFBundleVersion"] as? String else {
            return nil
        }
        return Int(s)
    }

    /// `--updaterepo owner/name` (tests) overrides the release repo.
    static var repo: String { launchArgValue("--updaterepo") ?? defaultRepo }

    /// A process-only override supports explicit probes. Production access lives in the
    /// login Keychain and never travels in a newly published bundle.
    nonisolated static var token: String? {
        ProcessInfo.processInfo.environment["FLOWCLONE_UPDATE_TOKEN"] ?? UpdateAccess.read()
    }

    /// Production: first check a minute after launch (let the model load first), then every
    /// 6 hours. Kill switch: `defaults write com.andre.flowclone autoUpdate -bool false`.
    static func start() {
        if handsfreeSession { Handsfree.log("blocked updater"); status = "Updates: off in hands-free testing"; return }
        // The previous updater leaves its signed bundle beside the replacement. Migrate any
        // legacy token and remove `FlowClone.app.old` off `@MainActor` so Keychain + code
        // signature verification never block launch.
        // It waits until the previous build's relaunch helper has stopped watching this
        // launch: until then `FlowClone.app.old` is what a failed start is rolled back to.
        let previous = Bundle.main.bundleURL.appendingPathExtension("old")
        schedulePreviousBundleCleanup(at: previous, delay: previousBundleCleanupDelay)
        let d = UserDefaults.standard
        noteRollback(defaults: d)
        guard automaticChecksEnabled(d) else {
            stopAutomaticChecks()
            status = "Automatic updates are off"
            log("updater: off")
            return
        }
        if let locationError = installLocationError(bundleURL: destinationBundleURL()) {
            status = "Update install blocked: \(locationError)"
            log("updater: install location warning — \(locationError)")
        }
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { _ in
            Task { @MainActor in await automaticCheck() }
        }
        timer?.tolerance = 60
        DispatchQueue.main.asyncAfter(deadline: .now() + 60) { Task { @MainActor in await automaticCheck() } }
        // The timer stands still while the Mac sleeps, so a laptop that is mostly closed
        // could go days between checks. Look again after a wake once a check is due.
        if wakeObserver == nil {
            wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated {
                    guard shouldCheckAfterWake(lastAttempt: lastAttempt) else { return }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 30) { Task { @MainActor in await automaticCheck() } }
                }
            }
        }
    }

    /// Settings › Updates › Check for updates automatically (`autoUpdate`, on when absent).
    nonisolated static let automaticChecksKey = "autoUpdate"

    nonisolated static func automaticChecksEnabled(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: automaticChecksKey) == nil || defaults.bool(forKey: automaticChecksKey)
    }

    /// Takes effect at once: off stops the timer and the wake check, on starts them again.
    /// "Check for updates" keeps working either way.
    static func setAutomaticChecks(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: automaticChecksKey)
        log("updater: automatic checks \(on ? "on" : "off")")
        start()
    }

    private static func stopAutomaticChecks() {
        timer?.invalidate()
        timer = nil
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
        wakeObserver = nil
    }

    /// Every unattended path comes through here, so a check queued before the switch was
    /// turned off (the first-minute check, a retry, a wake) does not run after it.
    private static func automaticCheck() async {
        guard timer != nil, automaticChecksEnabled() else { return }
        await check()
    }

    nonisolated static func shouldCheckAfterWake(lastAttempt: Date, now: Date = Date(),
                                                 every interval: TimeInterval = Updater.interval) -> Bool {
        now.timeIntervalSince(lastAttempt) >= interval
    }

    /// A check that never reached GitHub (no network yet after login or wake) is tried again
    /// soon instead of in six hours. A rejected or unsafe download is not: that would fetch
    /// the same archive every few minutes.
    nonisolated static func shouldRetrySoon(after error: Error, retriesSoFar: Int) -> Bool {
        error is URLError && retriesSoFar < maximumQuickRetries
    }

    private static func scheduleQuickRetry(after error: Error, userInitiated: Bool) {
        guard !userInitiated, timer != nil,
              shouldRetrySoon(after: error, retriesSoFar: quickRetries) else { return }
        quickRetries += 1
        DispatchQueue.main.asyncAfter(deadline: .now() + quickRetryDelay) {
            Task { @MainActor in await automaticCheck() }
        }
    }

    // MARK: - Builds this Mac leaves alone

    nonisolated static func incompatibleMarker(
        build: Int, system: String = ProcessInfo.processInfo.operatingSystemVersionString
    ) -> String { "\(build)|\(system)" }

    /// Why an automatic check does not fetch `build` again, or nil to go ahead. A build that
    /// needs a newer macOS is skipped until macOS changes; one that was rolled back because it
    /// did not start is left alone for a week. "Check for updates" always tries again.
    nonisolated static func skipReason(
        build: Int, defaults: UserDefaults = .standard, now: Date = Date(),
        system: String = ProcessInfo.processInfo.operatingSystemVersionString
    ) -> String? {
        if defaults.string(forKey: incompatibleKey) == incompatibleMarker(build: build, system: system) {
            return "Update (build \(build)) needs a newer macOS than this Mac has"
        }
        if let failed = failedUpdate(defaults: defaults), failed.build == build {
            let age = now.timeIntervalSince(failed.at)
            if age >= 0, age < failedBuildRetryAfter {
                return "Update (build \(build)) did not start on this Mac and was undone — waiting for the next version"
            }
        }
        return nil
    }

    /// Written by the relaunch helper (`defaults write`) after it restored the previous build.
    nonisolated static func failedUpdate(defaults: UserDefaults = .standard) -> (build: Int, at: Date)? {
        guard let build = defaults.string(forKey: failedBuildKey).flatMap({ Int($0) }), build > 0,
              let seconds = defaults.string(forKey: failedAtKey).flatMap({ TimeInterval($0) }) else { return nil }
        return (build, Date(timeIntervalSince1970: seconds))
    }

    private static func noteRollback(defaults: UserDefaults) {
        guard let failed = failedUpdate(defaults: defaults) else { return }
        if failed.build > currentBuild {
            log("updater: build \(failed.build) did not start on this Mac and was rolled back to \(currentBuild)")
        } else {
            // This build or a later one is running: the record has done its job.
            defaults.removeObject(forKey: failedBuildKey)
            defaults.removeObject(forKey: failedAtKey)
        }
    }

    nonisolated static func cleanupPreviousBundle(
        at previous: URL,
        readAccess: () -> String? = { UpdateAccess.read() },
        migrateAccess: (URL) -> Bool = { UpdateAccess.migrate(previous: $0) },
        removeItem: (URL) throws -> Void = { try FileManager.default.removeItem(at: $0) }
    ) {
        guard FileManager.default.fileExists(atPath: previous.path) else { return }
        if readAccess() == nil {
            _ = migrateAccess(previous)
        }
        try? removeItem(previous)
    }

    @discardableResult
    nonisolated static func schedulePreviousBundleCleanup(
        at previous: URL,
        delay: TimeInterval = 0,
        readAccess: @escaping @Sendable () -> String? = { UpdateAccess.read() },
        migrateAccess: @escaping @Sendable (URL) -> Bool = { UpdateAccess.migrate(previous: $0) },
        removeItem: @escaping @Sendable (URL) throws -> Void = { try FileManager.default.removeItem(at: $0) }
    ) -> Task<Void, Never> {
        Task.detached(priority: .utility) {
            if delay > 0 { try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
            cleanupPreviousBundle(at: previous, readAccess: readAccess,
                                  migrateAccess: migrateAccess, removeItem: removeItem)
        }
    }

    /// A deliberate quit inside the helper's watch must not look like a failed start: with the
    /// previous build gone there is nothing to roll back to. The process that just installed
    /// an update keeps it, because that copy is its own bundle and the helper's only fallback.
    static func applicationWillTerminate() {
        let bundle = destinationBundleURL()
        guard !handsfreeSession, !keepsPreviousBundleForRollback, bundle.pathExtension == "app" else { return }
        cleanupPreviousBundle(at: bundle.appendingPathExtension("old"))
    }

    static func check(userInitiated: Bool = false,
                      fetchLatest: @MainActor () async throws -> Manifest = { try await latest() }) async {
        guard !isChecking, !isInstalling else { return }
        if handsfreeSession { Handsfree.log("blocked update check"); status = "Updates: off in hands-free testing"; return }
        if let s = staged, !FileManager.default.fileExists(atPath: s.location.app.path) {
            s.location.remove()
            staged = nil
        }
        if staged != nil { await installWhenIdle(userInitiated: userInitiated); return }
        isChecking = true
        defer { isChecking = false }
        lastAttempt = Date()
        status = "Checking for updates…"
        do {
            let m = try await fetchLatest()
            quickRetries = 0
            guard m.build > currentBuild else {
                status = "Up to date (build \(currentBuild))"
                log("updater: up to date (latest release build \(m.build))")
                return
            }
            if !userInitiated, let reason = skipReason(build: m.build) {
                status = reason
                log("updater: leaving build \(m.build) alone — \(reason)")
                return
            }
            status = "Downloading \(m.version) (build \(m.build))…"
            log("updater: build \(m.build) available")
            let location: Staging
            do { location = try await download(m) }
            catch let error as UpdateError where error.incompatibleWithThisMac {
                UserDefaults.standard.set(incompatibleMarker(build: m.build), forKey: incompatibleKey)
                status = "Update \(m.version) (build \(m.build)) \(error) — this Mac stays on build \(currentBuild)"
                log("updater: build \(m.build) \(error); not installed")
                return
            }
            staged = (m.build, m.version, location)
            log("updater: build \(m.build) verified")
            await installWhenIdle(userInitiated: userInitiated)
        } catch {
            status = "Update check failed: \(error)"
            log("updater: FAILED \(error)")
            scheduleQuickRetry(after: error, userInitiated: userInitiated)
        }
    }

    static func installNow() async {
        await installWhenIdle(userInitiated: true)
    }

    static func windowDidClose() {
        guard staged != nil, !isInstalling else { return }
        idleRetry?.cancel()
        idleRetry = nil
        Task { @MainActor in await installWhenIdle(userInitiated: false) }
    }

    static func latest(access: @Sendable () -> String? = { token }) async throws -> Manifest {
        guard repo.range(of: #"^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$"#, options: .regularExpression) != nil,
              let url = URL(string: "https://api.github.com/repos/\(repo)/releases/latest") else {
            throw UpdateError("invalid release repository")
        }
        let data = try await fetch(url, accept: "application/vnd.github+json", access: access) { request in
            let (data, response) = try await network.data(for: request, delegate: RedirectStripper())
            try expectOK(response)
            return data
        }
        let dec = JSONDecoder()
        dec.keyDecodingStrategy = .convertFromSnakeCase
        return try Manifest(try dec.decode(Release.self, from: data), expectedRepo: repo)
    }

    nonisolated static func download(_ manifest: Manifest,
                                    access: @Sendable () -> String? = { token }) async throws -> Staging {
        let zip = try await fetch(manifest.url, accept: "application/octet-stream", access: access) { request in
            let (file, response) = try await network.download(for: request, delegate: RedirectStripper())
            do { try expectOK(response) }
            catch { try? FileManager.default.removeItem(at: file); throw error }
            return file
        }
        defer { try? FileManager.default.removeItem(at: zip) }
        return try await Task.detached(priority: .utility) {
            try validateDownload(zip, digest: manifest.digest)
            return try stage(zip: zip, expecting: manifest.build, version: manifest.version)
        }.value
    }

    /// Public releases work on a fresh Mac, even if a stale private-feed credential exists.
    /// Only an access denial can trigger one authenticated retry for legacy private feeds.
    nonisolated static func fetch<Value: Sendable>(
        _ url: URL, accept: String,
        access: @Sendable () -> String? = { token },
        send: @Sendable (URLRequest) async throws -> Value
    ) async throws -> Value {
        do { return try await send(request(url, accept: accept)) }
        catch let error as UpdateError {
            guard error.permitsAccessRetry, let value = access(), !value.isEmpty else { throw error }
            return try await send(request(url, accept: accept, token: value))
        }
    }

    nonisolated static func request(_ url: URL, accept: String, token: String? = nil) throws -> URLRequest {
        guard isTrustedAPIURL(url) else { throw UpdateError("untrusted update API URL") }
        var r = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        if let token, !token.isEmpty { r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        r.setValue(accept, forHTTPHeaderField: "Accept")
        r.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        return r
    }

    nonisolated static func expectOK(_ resp: URLResponse) throws {
        guard let http = resp as? HTTPURLResponse else { throw UpdateError("non-HTTP update response") }
        switch http.statusCode {
        case 200: return
        case 401:
            throw UpdateError("update access was rejected (HTTP 401) — get the latest installer from the distributor",
                              permitsAccessRetry: true)
        case 403, 429:
            if http.statusCode == 429 || http.value(forHTTPHeaderField: "X-RateLimit-Remaining") == "0"
                || http.value(forHTTPHeaderField: "Retry-After") != nil {
                throw UpdateError("GitHub update rate limit reached — try again later")
            }
            throw UpdateError("update access was denied (HTTP 403) — get the latest installer from the distributor",
                              permitsAccessRetry: true)
        case 404:
            throw UpdateError("update feed is unavailable or private (HTTP 404) — get the latest installer from the distributor",
                              permitsAccessRetry: true)
        default: throw UpdateError("HTTP \(http.statusCode) from \(http.url?.host ?? "?")")
        }
    }

    /// Credentials stay on GitHub's API origin. Signed CDN redirects use HTTPS without
    /// Authorization; plaintext or credential-bearing redirects are refused entirely.
    nonisolated static func redirected(_ request: URLRequest) -> URLRequest? {
        guard let url = request.url, url.scheme == "https", url.user == nil, url.password == nil else { return nil }
        var result = request
        if !isTrustedAPIURL(url) { result.setValue(nil, forHTTPHeaderField: "Authorization") }
        return result
    }

    final class RedirectStripper: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
        func urlSession(_ session: URLSession, task: URLSessionTask,
                        willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest) async -> URLRequest? {
            Updater.redirected(request)
        }
        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                        didFinishDownloadingTo location: URL) {}
        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                        didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                        totalBytesExpectedToWrite: Int64) {
            if totalBytesWritten > maximumDownloadBytes || totalBytesExpectedToWrite > maximumDownloadBytes {
                downloadTask.cancel()
            }
        }
    }

    nonisolated static func validateDownload(_ zip: URL, digest: String) throws {
        let size = try zip.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size > 0, size <= maximumDownloadBytes else { throw UpdateError("archive exceeds size limit") }
        let normalizedDigest = digest.lowercased()
        guard normalizedDigest.hasPrefix("sha256:"), normalizedDigest.count == 71,
              normalizedDigest.dropFirst(7).allSatisfy({ $0.isASCII && $0.isHexDigit }) else {
            throw UpdateError("missing or invalid archive digest")
        }
        let data = try Data(contentsOf: zip, options: .mappedIfSafe)
        let actual = "sha256:" + SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard actual == normalizedDigest else { throw UpdateError("archive digest mismatch") }
    }

    struct Staging: Sendable {
        let root: URL
        let app: URL
        nonisolated func remove() { try? FileManager.default.removeItem(at: root) }
    }

    /// A private directory belongs to exactly one check. On failure nothing is retained.
    nonisolated static func stage(zip: URL, expecting build: Int, version: String? = nil) throws -> Staging {
        try UpdateArchive.validate(zip)
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("flowclone-update-\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        var succeeded = false
        defer { if !succeeded { try? fm.removeItem(at: dir) } }
        try run("/usr/bin/ditto", "-x", "-k", zip.path, dir.path)
        let app = try findApp(in: dir)
        try verify(app)
        guard bundleBuild(app) == build,
              version.map({ bundleVersion(app) == $0 }) ?? true else {
            throw UpdateError("bundle version does not match release metadata")
        }
        if let incompatible = compatibilityError(of: app) { throw incompatible }
        stripDetritus(app)
        succeeded = true
        return Staging(root: dir, app: app)
    }

    nonisolated static var currentArchitecture: Int {
        #if arch(arm64)
        return NSBundleExecutableArchitectureARM64
        #else
        return NSBundleExecutableArchitectureX86_64
        #endif
    }

    nonisolated static func systemVersion(_ text: String) -> OperatingSystemVersion? {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
        guard (1...3).contains(parts.count), !parts.contains(nil), let major = parts[0], major > 0 else { return nil }
        return OperatingSystemVersion(majorVersion: major,
                                      minorVersion: parts.count > 1 ? parts[1] ?? 0 : 0,
                                      patchVersion: parts.count > 2 ? parts[2] ?? 0 : 0)
    }

    /// A signed update that this Mac cannot open must never replace the app that works here:
    /// after the swap macOS would refuse to launch it and nothing would be left running to
    /// fetch a fix. Checked against what the update itself declares.
    nonisolated static func compatibilityError(
        of app: URL,
        system: OperatingSystemVersion = ProcessInfo.processInfo.operatingSystemVersion,
        architecture: Int = currentArchitecture,
        executableArchitectures: (URL) -> [Int]? = { Bundle(url: $0)?.executableArchitectures?.map(\.intValue) }
    ) -> UpdateError? {
        let info = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist"))
        if let minimum = info?["LSMinimumSystemVersion"] as? String {
            guard let required = systemVersion(minimum) else {
                return UpdateError("declares an unreadable minimum macOS version")
            }
            let have = (system.majorVersion, system.minorVersion, system.patchVersion)
            let need = (required.majorVersion, required.minorVersion, required.patchVersion)
            if have < need {
                return UpdateError("needs macOS \(minimum) or newer", incompatibleWithThisMac: true)
            }
        }
        if let supported = executableArchitectures(app), !supported.isEmpty, !supported.contains(architecture) {
            return UpdateError("is not built for this Mac's processor", incompatibleWithThisMac: true)
        }
        return nil
    }

    /// The distribution has one optional wrapper directory. Do not enumerate thousands
    /// of bundle resources just to find the application, or accept a symlink as the app.
    nonisolated static func findApp(in root: URL) throws -> URL {
        let fm = FileManager.default
        func children(_ dir: URL) throws -> [URL] {
            try fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                                       options: [.skipsHiddenFiles])
        }
        var candidates: [URL] = []
        let top = try children(root)
        var entries = top
        for dir in top where dir.pathExtension != "app" && dir.lastPathComponent != "__MACOSX" {
            let values = try dir.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            if values.isDirectory == true, values.isSymbolicLink != true { entries += try children(dir) }
        }
        for app in entries where app.pathExtension == "app" {
            let values = try app.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard app.lastPathComponent == "FlowClone.app", values.isDirectory == true,
                  values.isSymbolicLink != true else { throw UpdateError("unexpected application in archive") }
            candidates.append(app)
        }
        guard candidates.count == 1, let app = candidates.first else {
            throw UpdateError("archive must contain exactly one FlowClone.app")
        }
        return app
    }

    nonisolated static func bundleVersion(_ app: URL) -> String? {
        (NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist")))?["CFBundleShortVersionString"] as? String
    }

    nonisolated static func verify(_ app: URL) throws {
        var mine: SecStaticCode?
        var req: SecRequirement?
        var theirs: SecStaticCode?
        guard SecStaticCodeCreateWithPath(Bundle.main.bundleURL as CFURL, [], &mine) == errSecSuccess,
              let mine, SecCodeCopyDesignatedRequirement(mine, [], &req) == errSecSuccess, let req,
              SecStaticCodeCreateWithPath(app as CFURL, [], &theirs) == errSecSuccess, let theirs
        else { throw UpdateError("cannot read our own designated requirement") }
        var err: Unmanaged<CFError>?
        let flags = SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures | kSecCSCheckNestedCode)
        let rc = SecStaticCodeCheckValidityWithErrors(theirs, flags, req, &err)
        guard rc == errSecSuccess else {
            let why = err?.takeRetainedValue().localizedDescription ?? ""
            throw UpdateError("signature rejected (\(rc)) \(why)")
        }
    }

    nonisolated static func stripDetritus(_ app: URL) {
        try? run("/usr/bin/xattr", "-dr", "com.apple.quarantine", app.path)
        try? run("/usr/bin/xattr", "-dr", "com.apple.FinderInfo", app.path)
    }

    nonisolated static func installLocationError(
        bundleURL: URL,
        isWritable: (String) -> Bool = { FileManager.default.isWritableFile(atPath: $0) }
    ) -> UpdateError? {
        let path = bundleURL.path
        if path.contains("/AppTranslocation/") {
            return UpdateError("FlowClone is running from a temporary macOS security folder — quit, drag FlowClone.app directly into Applications, and reopen")
        }
        let parent = bundleURL.deletingLastPathComponent().path
        if !isWritable(parent) {
            return UpdateError("cannot replace FlowClone in \(parent) (folder is not writable) — move FlowClone.app to ~/Applications or an admin-writable Applications folder")
        }
        return nil
    }

    private static func retryWhenIdle() {
        guard idleRetry == nil else { return }
        let work = DispatchWorkItem {
            MainActor.assumeIsolated {
                idleRetry = nil
                Task { await installWhenIdle() }
            }
        }
        idleRetry = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 30, execute: work)
    }

    private static func isBlockedForInstall(userInitiated: Bool) -> Bool {
        userInitiated ? workActive() : (workActive() || sessionActive())
    }

    private static func installWhenIdle(userInitiated: Bool = false) async {
        guard let s = staged, !isInstalling else { return }
        if !FileManager.default.fileExists(atPath: s.location.app.path) {
            log("updater: staged bundle missing — re-checking")
            s.location.remove()
            staged = nil
            if userInitiated { await check(userInitiated: true) }
            return
        }
        let dest = destinationBundleURL()
        if let locationError = installLocationError(bundleURL: dest) {
            status = "Update install blocked: \(locationError)"
            log("updater: install blocked — \(locationError)")
            return
        }
        guard !isBlockedForInstall(userInitiated: userInitiated) else {
            if workActive() {
                status = "Update \(s.version) (build \(s.build)) ready — installs after current dictation or meeting finishes"
            } else {
                status = "Update \(s.version) (build \(s.build)) ready — click Install & Relaunch or close this window"
            }
            retryWhenIdle()
            return
        }
        isInstalling = true
        defer { isInstalling = false }
        guard await reserveForInstall() else { retryWhenIdle(); return }
        defer { releaseInstallReservation() }
        // The reservation involved an await; active work or a window may have started while it ran.
        guard !isBlockedForInstall(userInitiated: userInitiated) else { retryWhenIdle(); return }
        idleRetry?.cancel()
        idleRetry = nil
        let prepared = dest.deletingLastPathComponent().appendingPathComponent(".FlowClone-update-\(UUID().uuidString).app")
        defer { try? FileManager.default.removeItem(at: prepared) }
        let stagedApp = s.location.app
        let stagedBuild = s.build
        let stagedVersion = s.version
        let verifier = verifyBundle
        do {
            // Copy and verify on the destination volume before renaming the running app.
            // If space/permissions/copy fail, its original pathname is still intact.
            try await Task.detached(priority: .utility) {
                try FileManager.default.copyItem(at: stagedApp, to: prepared)
                try verifier(prepared)
                guard bundleBuild(prepared) == stagedBuild, bundleVersion(prepared) == stagedVersion else {
                    throw UpdateError("prepared bundle version mismatch")
                }
                stripDetritus(prepared)
            }.value
            guard !isBlockedForInstall(userInitiated: userInitiated) else { retryWhenIdle(); return }
            try swap(new: prepared, into: dest)
        } catch {
            status = "Update install failed: \(error)"
            log("updater: install FAILED \(error)")
            staged = nil
            s.location.remove()
            return
        }
        staged = nil
        s.location.remove()
        keepsPreviousBundleForRollback = true
        installedBuildAwaitingRelaunch = s.build
        log("updater: installed build \(s.build) (\(s.version)) — relaunching")
        if !performRelaunch(dest) { status = "Update installed — quit and reopen FlowClone to finish" }
    }

    /// Test-only helper to stage a pre-verified bundle or clear state without network I/O.
    static func stageForTesting(build: Int, version: String, location: Staging) {
        staged = (build, version, location)
    }

    static func resetForTesting() {
        idleRetry?.cancel()
        idleRetry = nil
        staged?.location.remove()
        staged = nil
        isChecking = false
        isInstalling = false
        sessionActive = { false }
        workActive = { false }
        reserveForInstall = { true }
        releaseInstallReservation = {}
        destinationBundleURL = { Bundle.main.bundleURL }
        performRelaunch = { relaunch($0) }
        verifyBundle = { try verify($0) }
        keepsPreviousBundleForRollback = false
        installedBuildAwaitingRelaunch = nil
        lastAttempt = .distantPast
        quickRetries = 0
        status = "Updates: not checked yet"
    }

    /// Rename-swap; the running process keeps its mapped binary. The old bundle stays beside
    /// the new one until the new build's start() removes it.
    nonisolated static func swap(new: URL, into dest: URL) throws {
        let fm = FileManager.default
        let old = dest.appendingPathExtension("old")
        try? fm.removeItem(at: old)
        try fm.moveItem(at: dest, to: old)
        do { try fm.moveItem(at: new, to: dest) } catch {
            do { try fm.moveItem(at: old, to: dest) }
            catch { throw UpdateError("replacement and rollback failed; previous app remains at \(old.path)") }
            throw error
        }
    }

    /// Wait for our pid to exit, then `open -n` the new bundle with the same launch arguments.
    /// LaunchServices can transiently return -600 right after a bundle swap and process exit,
    /// so retry with brief spacing before giving up.
    nonisolated static func relaunchArguments(app: URL, pid: Int32, arguments: [String],
                                              background: Bool = false,
                                              watch: UpdateWatch? = nil) -> [String] {
        var forwarded = arguments
        if background, !forwarded.contains("--background") {
            forwarded.append("--background")
        }
        let launch = [app.path] + (forwarded.isEmpty ? [] : ["--args"] + forwarded)
        guard let watch else {
            let openCommand = background ? "/usr/bin/open -g -n \"$@\"" : "/usr/bin/open -n \"$@\""
            let script = "while kill -0 \"$1\" 2>/dev/null; do sleep 0.2; done; shift; "
                + "for attempt in 1 2 3 4 5; do \(openCommand) && exit 0; sleep 1; done; exit 1"
            return ["-c", script, "_", String(pid)] + launch
        }
        return ["-c", watch.script(background: background), "_", String(pid), String(watch.build),
                watch.defaultsDomain] + launch
    }

    /// After an update the helper also watches the new build start. If it cannot be opened or
    /// is gone again within the watch, the helper puts the previous build back, records the
    /// build so it is not fetched again right away, and reopens the previous build. Without
    /// this a release that fails at launch would leave every copy dead with nothing running
    /// to fetch the fix. Exit status: 0 new build running, 2 rolled back, 1 neither.
    struct UpdateWatch: Equatable, Sendable {
        let build: Int
        let defaultsDomain: String
        var graceSeconds = 3
        var watchSeconds = 20
        /// The programs the helper runs; replaced only by tests that execute the real script.
        var open = "/usr/bin/open"
        var alive = "/usr/bin/pgrep -x -U \"$(/usr/bin/id -u)\" FlowClone"
        var defaults = "/usr/bin/defaults"

        func script(background: Bool) -> String {
            let openCommand = "\(open) \(background ? "-g -n" : "-n") \"$@\""
            return """
            pid="$1"; build="$2"; domain="$3"; shift 3
            app="$1"
            case "$app" in /*.app) ;; *) exit 1 ;; esac
            while kill -0 "$pid" 2>/dev/null; do sleep 0.2; done
            started=0
            for attempt in 1 2 3 4 5; do
              if \(openCommand); then started=1; break; fi
              sleep 1
            done
            if [ "$started" = 1 ]; then
              sleep \(graceSeconds)
              left=\(watchSeconds)
              while [ "$left" -gt 0 ] && \(alive) >/dev/null 2>&1; do sleep 1; left=$((left - 1)); done
              [ "$left" -le 0 ] && exit 0
            fi
            old="$app.old"; failed="$app.failed"
            [ -d "$old" ] || exit 1
            /bin/rm -rf "$failed"
            /bin/mv "$app" "$failed" || exit 1
            if ! /bin/mv "$old" "$app"; then /bin/mv "$failed" "$app"; exit 1; fi
            /bin/rm -rf "$failed"
            \(defaults) write "$domain" \(Updater.failedBuildKey) -string "$build"
            \(defaults) write "$domain" \(Updater.failedAtKey) -string "$(/bin/date +%s)"
            for attempt in 1 2 3 4 5; do \(openCommand) && exit 2; sleep 1; done
            exit 1
            """
        }
    }

    @discardableResult
    static func relaunch(_ app: URL) -> Bool {
        if handsfreeSession { Handsfree.log("blocked relaunch"); return false }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        let allArgs = ProcessInfo.processInfo.arguments
        let rawArgs = Array(allArgs.dropFirst())
        let keepQuiet = !MainWindow.shared.isVisible && !AppLaunchPolicy.isProbe(allArgs)
        let forwarded = keepQuiet ? rawArgs : rawArgs.filter { $0 != "--background" }
        let watch = installedBuildAwaitingRelaunch.map {
            UpdateWatch(build: $0, defaultsDomain: Bundle.main.bundleIdentifier ?? "com.andre.flowclone")
        }
        installedBuildAwaitingRelaunch = nil
        p.arguments = relaunchArguments(app: app, pid: ProcessInfo.processInfo.processIdentifier,
                                        arguments: forwarded, background: keepQuiet, watch: watch)
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() }
        catch { log("relaunch helper could not start: \(error)"); return false }
        log("relaunching")
        History.flush()
        flushLog()
        AppTermination.isRelaunching = true
        AppTermination.explicitUserQuit = false
        NSApp.terminate(nil)
        return true
    }

    nonisolated static func run(_ cmd: String, _ args: String...) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: cmd)
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw UpdateError("\(cmd) exited \(p.terminationStatus)") }
    }

    // MARK: - Self-check

    /// `open -a FlowClone --args --updatetest`: zips THIS bundle and pushes it through
    /// unzip → verify (the real Security checks against a real signed bundle), then proves a
    /// copy with a bumped build number alone is rejected. Needs no network and no token.
    /// `--updatetest --updaterepo owner/name` (optional local access for private feeds)
    /// instead runs the real check against that repo — install and relaunch included.
    /// Add `--update-download-only` to check/download/verify without installing or accessing
    /// Keychain. This is the fresh-Mac acceptance gate for a published public release.
    static func selfCheck() {
        Task { @MainActor in
            if ProcessInfo.processInfo.arguments.contains("--update-download-only") {
                do {
                    let manifest = try await latest(access: { nil })
                    let location = try await download(manifest, access: { nil })
                    defer { location.remove() }
                    log("UPDATEFEEDTEST PASS anonymous feed/download/signature build=\(manifest.build) repo=\(repo)")
                } catch { log("UPDATEFEEDTEST FAIL \(error)") }
                flushLog()
                return
            }
            if launchArgValue("--updaterepo") != nil {
                log("UPDATETEST live check against \(repo) from build \(currentBuild)")
                await check()
                log("UPDATETEST status: \(status)")
                flushLog()
                return
            }
            var fails = 0
            func expect(_ name: String, _ ok: Bool) {
                log("UPDATETEST \(ok ? "ok" : "FAIL"): \(name)")
                if !ok { fails += 1 }
            }
            let fm = FileManager.default
            let tmp = fm.temporaryDirectory.appendingPathComponent("flowclone-updatetest")
            do {
                try? fm.removeItem(at: tmp)
                try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
                let zip = tmp.appendingPathComponent("self.zip")
                try run("/usr/bin/ditto", "-c", "-k", "--keepParent", Bundle.main.bundlePath, zip.path)
                let build = currentBuild
                let location = try await Task.detached { try stage(zip: zip, expecting: build) }.value
                defer { location.remove() }
                let app = location.app
                expect("own bundle passes verify", bundleBuild(app) == currentBuild)
                let other = try await Task.detached { try stage(zip: zip, expecting: build) }.value
                defer { other.remove() }
                expect("staging directories are independent", other.root != location.root)
                expect("wrong release build rejected", (try? stage(zip: zip, expecting: build + 1)) == nil)
                let plist = app.appendingPathComponent("Contents/Info.plist")
                let d = NSMutableDictionary(contentsOf: plist) ?? [:]
                d["CFBundleVersion"] = String(currentBuild + 1)
                expect("tamper written", d.write(to: plist, atomically: true))
                expect("bumped-but-unsigned bundle rejected", (try? verify(app)) == nil)
                expect("other staged bundle remains valid", (try? verify(other.app)) != nil)
                let destination = tmp.appendingPathComponent("installed/FlowClone.app")
                try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fm.copyItem(at: Bundle.main.bundleURL, to: destination)
                try swap(new: other.app, into: destination)
                expect("signed replacement passes verify after swap", (try? verify(destination)) != nil)
                expect("signed rollback retained after swap", (try? verify(destination.appendingPathExtension("old"))) != nil)
                let executable = destination.appendingPathComponent("Contents/MacOS/FlowClone")
                let handle = try FileHandle(forUpdating: executable)
                try handle.seek(toOffset: 4096)
                let byte = try handle.read(upToCount: 1)!.first!
                try handle.seek(toOffset: 4096)
                try handle.write(contentsOf: Data([byte ^ 1]))
                try handle.close()
                expect("modified executable rejected", (try? verify(destination)) == nil)
                expect("new bundle contains no update credential", Bundle.main.infoDictionary?["FlowCloneUpdateToken"] == nil)
            } catch {
                expect("\(error)", false)
            }
            try? fm.removeItem(at: tmp)
            log(fails == 0 ? "UPDATETEST PASS" : "UPDATETEST FAIL (\(fails))")
            flushLog()
        }
    }
}
