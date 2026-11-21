import XCTest
@testable import FlowCloneCore

/// What keeps an installed copy alive when a release is wrong for a Mac: the relaunch helper
/// undoes an update that does not start, an update for a newer macOS is never swapped in, and
/// a check that could not reach the feed is tried again soon.
final class UpdaterDurabilityTests: XCTestCase {
    /// An install folder whose name would run commands or split arguments if the helper
    /// ever let a path reach the shell unquoted.
    private struct Install {
        let root: URL
        let app: URL
        let log: URL
        let mode: URL
        let alive: URL
        var watch: Updater.UpdateWatch

        var old: URL { app.appendingPathExtension("old") }
        func marker(_ bundle: URL) -> String? {
            try? String(contentsOf: bundle.appendingPathComponent("marker"), encoding: .utf8)
        }
        var calls: [String] {
            ((try? String(contentsOf: log, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
        }
    }

    private func makeInstall(open mode: String, alive: Bool, keepPrevious: Bool = true) throws -> Install {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("updater-watch-\(UUID().uuidString)")
        let bin = root.appendingPathComponent("bin")
        let folder = root.appendingPathComponent("it's a $(touch SENTINEL) `quoted` folder")
        let app = folder.appendingPathComponent("FlowClone.app")
        try fm.createDirectory(at: bin, withIntermediateDirectories: true)
        try fm.createDirectory(at: app, withIntermediateDirectories: true)
        try Data("new".utf8).write(to: app.appendingPathComponent("marker"))
        if keepPrevious {
            let old = app.appendingPathExtension("old")
            try fm.createDirectory(at: old, withIntermediateDirectories: true)
            try Data("old".utf8).write(to: old.appendingPathComponent("marker"))
        }
        let log = root.appendingPathComponent("calls.log")
        let modeFile = root.appendingPathComponent("open-mode")
        let aliveFile = root.appendingPathComponent("alive-status")
        try Data(mode.utf8).write(to: modeFile)
        try Data((alive ? "0" : "1").utf8).write(to: aliveFile)
        func tool(_ name: String, _ body: String) throws -> String {
            let url = bin.appendingPathComponent(name)
            try Data("#!/bin/sh\n\(body)\n".utf8).write(to: url)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
            return url.path
        }
        // `ok` opens anything, `never` nothing, `only-old` only the previous build: a new
        // build macOS refuses to launch while the one it replaced still works.
        let open = try tool("open", """
        echo "open $*" >> "\(log.path)"
        for a in "$@"; do case "$a" in *.app) app="$a" ;; esac; done
        case "$(cat "\(modeFile.path)")" in
          ok) exit 0 ;;
          only-old) [ "$(cat "$app/marker")" = old ] && exit 0; exit 1 ;;
          *) exit 1 ;;
        esac
        """)
        let aliveTool = try tool("alive", "exit \"$(cat \"\(aliveFile.path)\")\"")
        let defaults = try tool("defaults", "echo \"defaults $*\" >> \"\(log.path)\"")
        var watch = Updater.UpdateWatch(build: 2026120101, defaultsDomain: "com.example.flowclone-test")
        watch.graceSeconds = 0
        watch.watchSeconds = 2
        watch.open = open
        watch.alive = aliveTool
        watch.defaults = defaults
        return Install(root: root, app: app, log: log, mode: modeFile, alive: aliveFile, watch: watch)
    }

    /// Runs the helper exactly as `Updater.relaunch` starts it, after a process that has exited.
    private func runHelper(_ install: Install, arguments: [String] = ["--runid", "a b"]) throws -> Int32 {
        let finished = Process()
        finished.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try finished.run()
        finished.waitUntilExit()
        let helper = Process()
        helper.executableURL = URL(fileURLWithPath: "/bin/sh")
        helper.arguments = Updater.relaunchArguments(app: install.app, pid: finished.processIdentifier,
                                                     arguments: arguments, watch: install.watch)
        helper.currentDirectoryURL = install.root
        helper.standardOutput = FileHandle.nullDevice
        helper.standardError = FileHandle.nullDevice
        try helper.run()
        helper.waitUntilExit()
        XCTAssertFalse(FileManager.default.fileExists(atPath: install.root.appendingPathComponent("SENTINEL").path),
                       "The install path must never run as shell code")
        return helper.terminationStatus
    }

    func testHelperKeepsAnUpdateThatStaysRunning() throws {
        let install = try makeInstall(open: "ok", alive: true)
        defer { try? FileManager.default.removeItem(at: install.root) }
        XCTAssertEqual(try runHelper(install), 0)
        XCTAssertEqual(install.marker(install.app), "new")
        XCTAssertEqual(install.marker(install.old), "old", "Removing the previous build is the new build's job")
        XCTAssertEqual(install.calls, ["open -n \(install.app.path) --args --runid a b"])
    }

    func testHelperRestoresThePreviousBuildWhenTheUpdateDiesAtLaunch() throws {
        let install = try makeInstall(open: "ok", alive: false)
        defer { try? FileManager.default.removeItem(at: install.root) }
        XCTAssertEqual(try runHelper(install), 2)
        XCTAssertEqual(install.marker(install.app), "old")
        XCTAssertFalse(FileManager.default.fileExists(atPath: install.old.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: install.app.appendingPathExtension("failed").path))
        let calls = install.calls
        XCTAssertEqual(calls.count, 4)
        XCTAssertEqual(calls[1], "defaults write com.example.flowclone-test updateFailedBuild -string 2026120101")
        XCTAssertTrue(calls[2].hasPrefix("defaults write com.example.flowclone-test updateFailedAt -string "))
        XCTAssertNotNil(TimeInterval(calls[2].split(separator: " ").last ?? ""))
        XCTAssertEqual(calls[3], calls[0], "The restored build is reopened the same way")
    }

    func testHelperRestoresThePreviousBuildWhenTheUpdateCannotBeOpened() throws {
        let install = try makeInstall(open: "only-old", alive: true)
        defer { try? FileManager.default.removeItem(at: install.root) }
        XCTAssertEqual(try runHelper(install), 2)
        XCTAssertEqual(install.marker(install.app), "old")
        XCTAssertFalse(FileManager.default.fileExists(atPath: install.old.path))
        XCTAssertEqual(install.calls.filter { $0.hasPrefix("open ") }.count, 6, "Five tries, then the restored build")
        XCTAssertTrue(install.calls.contains { $0.contains("updateFailedBuild -string 2026120101") })
    }

    func testHelperDoesNotUndoAnUpdateTheUserQuit() throws {
        // A deliberate quit removes the previous build first (`Updater.applicationWillTerminate`).
        let install = try makeInstall(open: "ok", alive: false, keepPrevious: false)
        defer { try? FileManager.default.removeItem(at: install.root) }
        XCTAssertEqual(try runHelper(install), 1)
        XCTAssertEqual(install.marker(install.app), "new")
        XCTAssertEqual(install.calls.count, 1, "Nothing is recorded and nothing is reopened")
    }

    func testHelperRefusesAnythingThatIsNotAnApplicationPath() throws {
        let install = try makeInstall(open: "ok", alive: false)
        defer { try? FileManager.default.removeItem(at: install.root) }
        let helper = Process()
        helper.executableURL = URL(fileURLWithPath: "/bin/sh")
        helper.arguments = ["-c", install.watch.script(background: false), "_", "1", "7", "com.example", ""]
        helper.currentDirectoryURL = install.root
        try helper.run()
        helper.waitUntilExit()
        XCTAssertEqual(helper.terminationStatus, 1)
        XCTAssertTrue(install.calls.isEmpty)
        XCTAssertEqual(install.marker(install.app), "new")
    }

    func testWatchedRelaunchPassesTheBuildAndDomainAsArgumentsNotScript() {
        let app = URL(fileURLWithPath: "/Applications/FlowClone.app")
        let watch = Updater.UpdateWatch(build: 2026120101, defaultsDomain: "com.andre.flowclone")
        let quiet = Updater.relaunchArguments(app: app, pid: 42, arguments: [], background: true, watch: watch)
        XCTAssertEqual(Array(quiet.dropFirst(2)),
                       ["_", "42", "2026120101", "com.andre.flowclone", app.path, "--args", "--background"])
        XCTAssertTrue(quiet[1].contains("/usr/bin/open -g -n \"$@\""))
        XCTAssertTrue(quiet[1].contains("/usr/bin/pgrep -x -U \"$(/usr/bin/id -u)\" FlowClone"))
        XCTAssertFalse(quiet[1].contains("2026120101"))
        XCTAssertFalse(quiet[1].contains("/Applications"))
    }

    @MainActor
    func testInstallingAnUpdateKeepsThePreviousBuildForTheHelper() async throws {
        defer { Updater.resetForTesting() }
        Updater.resetForTesting()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("updater-keep-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        func bundle(_ name: String, build: Int) throws -> URL {
            let app = root.appendingPathComponent(name).appendingPathComponent("FlowClone.app")
            try FileManager.default.createDirectory(at: app.appendingPathComponent("Contents"),
                                                    withIntermediateDirectories: true)
            let plist: NSDictionary = ["CFBundleVersion": String(build), "CFBundleShortVersionString": "0.3"]
            XCTAssertTrue(plist.write(to: app.appendingPathComponent("Contents/Info.plist"), atomically: true))
            return app
        }
        let dest = try bundle("installed", build: 2026111003)
        let staged = try bundle("staging", build: 2026111201)
        var relaunched = false
        Updater.destinationBundleURL = { dest }
        Updater.verifyBundle = { _ in }
        Updater.performRelaunch = { _ in relaunched = true; return true }
        XCTAssertFalse(Updater.keepsPreviousBundleForRollback)
        Updater.stageForTesting(build: 2026111201, version: "0.3",
                                location: Updater.Staging(root: staged.deletingLastPathComponent(), app: staged))
        await Updater.installNow()
        XCTAssertTrue(relaunched)
        XCTAssertTrue(Updater.keepsPreviousBundleForRollback,
                      "Quitting after the swap must not delete the copy the helper rolls back to")
        // The process that installed the update is the one whose quit must leave it in place.
        Updater.applicationWillTerminate()
        XCTAssertEqual(Updater.bundleBuild(dest.appendingPathExtension("old")), 2026111003)
    }

    @MainActor
    func testADeliberateQuitRemovesThePreviousBuildSoTheHelperDoesNotRollBack() throws {
        defer { Updater.resetForTesting() }
        Updater.resetForTesting()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("updater-quit-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let app = root.appendingPathComponent("FlowClone.app")
        let old = app.appendingPathExtension("old")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: old, withIntermediateDirectories: true)
        Updater.destinationBundleURL = { app }
        Updater.applicationWillTerminate()
        XCTAssertFalse(FileManager.default.fileExists(atPath: old.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: app.path))
    }

    func testPreviousBuildIsRemovedOnlyAfterTheDelay() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("updater-delay-\(UUID().uuidString)")
        let old = root.appendingPathComponent("FlowClone.app.old")
        try FileManager.default.createDirectory(at: old, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let started = Date()
        let cleanup = Updater.schedulePreviousBundleCleanup(at: old, delay: 0.4, readAccess: { "present" },
                                                            migrateAccess: { _ in false })
        XCTAssertTrue(FileManager.default.fileExists(atPath: old.path))
        await cleanup.value
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(started), 0.4)
        XCTAssertFalse(FileManager.default.fileExists(atPath: old.path))
    }

    private func bundle(minimumSystem: String?) throws -> URL {
        let app = FileManager.default.temporaryDirectory
            .appendingPathComponent("updater-compat-\(UUID().uuidString)/FlowClone.app")
        try FileManager.default.createDirectory(at: app.appendingPathComponent("Contents"),
                                                withIntermediateDirectories: true)
        let plist = NSMutableDictionary(dictionary: ["CFBundleVersion": "2026120101"])
        if let minimumSystem { plist["LSMinimumSystemVersion"] = minimumSystem }
        XCTAssertTrue(plist.write(to: app.appendingPathComponent("Contents/Info.plist"), atomically: true))
        return app
    }

    func testAnUpdateForANewerMacOSOrAnotherProcessorIsNotInstallable() throws {
        let sonoma = OperatingSystemVersion(majorVersion: 14, minorVersion: 6, patchVersion: 1)
        let arm = NSBundleExecutableArchitectureARM64, intel = NSBundleExecutableArchitectureX86_64
        func error(_ minimum: String?, on system: OperatingSystemVersion = sonoma, built: [Int]? = [arm],
                   running: Int = arm) throws -> Updater.UpdateError? {
            let app = try bundle(minimumSystem: minimum)
            defer { try? FileManager.default.removeItem(at: app.deletingLastPathComponent()) }
            return Updater.compatibilityError(of: app, system: system, architecture: running,
                                              executableArchitectures: { _ in built })
        }
        for runnable in ["14.0", "14", "14.6", "14.6.1", "13.5", nil] {
            XCTAssertNil(try error(runnable), "\(runnable ?? "no minimum") runs on 14.6.1")
        }
        for tooNew in ["14.6.2", "14.7", "15.0", "26.0"] {
            let rejected = try XCTUnwrap(try error(tooNew))
            XCTAssertTrue(rejected.incompatibleWithThisMac)
            XCTAssertEqual(rejected.description, "needs macOS \(tooNew) or newer")
        }
        // 26 is newer than 15 as a number, not as text.
        XCTAssertNil(try error("15.0", on: OperatingSystemVersion(majorVersion: 26, minorVersion: 0, patchVersion: 0)))
        for unreadable in ["", "fourteen", "14.x", "0.0", "14.0.0.0", "-14"] {
            let rejected = try XCTUnwrap(try error(unreadable), unreadable)
            XCTAssertFalse(rejected.incompatibleWithThisMac, "A malformed bundle is an error, not a skipped build")
        }
        XCTAssertTrue(try XCTUnwrap(try error("14.0", built: [intel])).incompatibleWithThisMac)
        XCTAssertNil(try error("14.0", built: [intel, arm]))
        XCTAssertNil(try error("14.0", built: [intel], running: intel))
        XCTAssertNil(try error("14.0", built: nil), "A bundle that does not report architectures is left to the signature check")
    }

    func testThisBuildIsCompatibleWithTheMacRunningTheTests() throws {
        let app = try bundle(minimumSystem: "14.0")
        defer { try? FileManager.default.removeItem(at: app.deletingLastPathComponent()) }
        XCTAssertNil(Updater.compatibilityError(of: app))
    }

    private func scratchDefaults() -> (UserDefaults, String) {
        let suite = ScratchDefaults.name("updater")
        return (UserDefaults(suiteName: suite)!, suite)
    }

    func testAutomaticChecksLeaveARolledBackBuildAloneForAWeek() {
        let (defaults, suite) = scratchDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let failedAt = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertNil(Updater.skipReason(build: 2026120101, defaults: defaults, now: failedAt))
        // As the helper writes them: `defaults write <domain> <key> -string <value>`.
        defaults.set("2026120101", forKey: Updater.failedBuildKey)
        defaults.set("1800000000", forKey: Updater.failedAtKey)
        XCTAssertEqual(Updater.failedUpdate(defaults: defaults)?.build, 2026120101)
        XCTAssertNotNil(Updater.skipReason(build: 2026120101, defaults: defaults, now: failedAt.addingTimeInterval(60)))
        XCTAssertNotNil(Updater.skipReason(build: 2026120101, defaults: defaults,
                                           now: failedAt.addingTimeInterval(6 * 24 * 3600)))
        XCTAssertNil(Updater.skipReason(build: 2026120102, defaults: defaults, now: failedAt.addingTimeInterval(60)),
                     "The fixed build that follows is installed")
        XCTAssertNil(Updater.skipReason(build: 2026120101, defaults: defaults,
                                        now: failedAt.addingTimeInterval(7 * 24 * 3600)),
                     "A build that failed once for a passing reason gets another try")
        XCTAssertNil(Updater.skipReason(build: 2026120101, defaults: defaults, now: failedAt.addingTimeInterval(-60)),
                     "A record from the future (clock change) does not block updates")
        defaults.set("not a number", forKey: Updater.failedAtKey)
        XCTAssertNil(Updater.skipReason(build: 2026120101, defaults: defaults, now: failedAt))
    }

    func testAnIncompatibleBuildIsSkippedUntilMacOSChanges() {
        let (defaults, suite) = scratchDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(Updater.incompatibleMarker(build: 2026120101, system: "Version 14.6.1 (Build 23G93)"),
                     forKey: Updater.incompatibleKey)
        XCTAssertNotNil(Updater.skipReason(build: 2026120101, defaults: defaults,
                                           system: "Version 14.6.1 (Build 23G93)"))
        XCTAssertNil(Updater.skipReason(build: 2026120101, defaults: defaults, system: "Version 15.1 (Build 24B83)"))
        XCTAssertNil(Updater.skipReason(build: 2026120102, defaults: defaults,
                                        system: "Version 14.6.1 (Build 23G93)"))
    }

    func testAutomaticChecksAreOnUntilSwitchedOff() {
        let (defaults, suite) = scratchDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertTrue(Updater.automaticChecksEnabled(defaults), "A fresh install updates itself")
        defaults.set(false, forKey: Updater.automaticChecksKey)
        XCTAssertFalse(Updater.automaticChecksEnabled(defaults))
        defaults.set(true, forKey: Updater.automaticChecksKey)
        XCTAssertTrue(Updater.automaticChecksEnabled(defaults))
        XCTAssertEqual(Updater.automaticChecksKey, "autoUpdate", "The key older builds already honour")
    }

    func testOnlyAnUnreachableFeedIsRetriedSoon() {
        XCTAssertTrue(Updater.shouldRetrySoon(after: URLError(.notConnectedToInternet), retriesSoFar: 0))
        XCTAssertTrue(Updater.shouldRetrySoon(after: URLError(.timedOut), retriesSoFar: 2))
        XCTAssertFalse(Updater.shouldRetrySoon(after: URLError(.timedOut), retriesSoFar: 3))
        XCTAssertFalse(Updater.shouldRetrySoon(after: Updater.UpdateError("archive digest mismatch"), retriesSoFar: 0),
                       "A rejected download must not be fetched again every few minutes")
        XCTAssertFalse(Updater.shouldRetrySoon(after: Updater.UpdateError("GitHub update rate limit reached"),
                                               retriesSoFar: 0))
    }

    func testAWakeChecksOnlyWhenACheckIsDue() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertTrue(Updater.shouldCheckAfterWake(lastAttempt: .distantPast, now: now))
        XCTAssertTrue(Updater.shouldCheckAfterWake(lastAttempt: now.addingTimeInterval(-6 * 3600), now: now))
        XCTAssertFalse(Updater.shouldCheckAfterWake(lastAttempt: now.addingTimeInterval(-6 * 3600 + 1), now: now))
        XCTAssertFalse(Updater.shouldCheckAfterWake(lastAttempt: now, now: now))
    }
}
