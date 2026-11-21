import os
import XCTest
@testable import FlowCloneCore

final class UpdaterTests: XCTestCase {
    private actor Feed {
        var requests: [URLRequest] = []
        var responses: [Int]
        init(_ responses: [Int]) { self.responses = responses }
        func send(_ request: URLRequest) throws -> Data {
            requests.append(request)
            guard !responses.isEmpty else { throw Updater.UpdateError("unexpected extra request") }
            try Updater.expectOK(HTTPURLResponse(url: request.url!, statusCode: responses.removeFirst(),
                                               httpVersion: nil, headerFields: nil)!)
            return Data("release fixture".utf8)
        }
    }

    func testFreshMacRequestsPublicMetadataAndArchivesWithoutCredentials() async throws {
        let endpoints = [
            ("https://api.github.com/repos/o/r/releases/latest", "application/vnd.github+json"),
            ("https://api.github.com/repos/o/r/releases/assets/2", "application/octet-stream")
        ]
        for (endpoint, accept) in endpoints {
            let feed = Feed([200])
            let result = try await Updater.fetch(URL(string: endpoint)!, accept: accept, access: {
                XCTFail("A public feed must not depend on Keychain or a stale credential")
                return "expired-test-fixture"
            }, send: { try await feed.send($0) })
            XCTAssertEqual(result, Data("release fixture".utf8))
            let requests = await feed.requests
            XCTAssertEqual(requests.count, 1)
            XCTAssertNil(requests[0].value(forHTTPHeaderField: "Authorization"))
            XCTAssertEqual(requests[0].value(forHTTPHeaderField: "Accept"), accept)
        }
    }

    func testLegacyPrivateFeedRetriesOnceWithLocalAccess() async throws {
        for status in [401, 403, 404] {
            let feed = Feed([status, 200])
            _ = try await Updater.fetch(URL(string: "https://api.github.com/repos/o/r/releases/latest")!,
                                       accept: "application/vnd.github+json", access: { "test-fixture" },
                                       send: { try await feed.send($0) })
            let requests = await feed.requests
            XCTAssertEqual(requests.count, 2)
            XCTAssertNil(requests[0].value(forHTTPHeaderField: "Authorization"))
            XCTAssertEqual(requests[1].value(forHTTPHeaderField: "Authorization"), "Bearer test-fixture")
        }
    }

    func testMissingAndRejectedAccessNeverLoopOrReportUpToDate() async {
        for access: String? in [nil, "", "expired-test-fixture"] {
            let feed = Feed([404, 401])
            do {
                _ = try await Updater.fetch(URL(string: "https://api.github.com/repos/o/r/releases/latest")!,
                                           accept: "application/vnd.github+json", access: { access },
                                           send: { try await feed.send($0) })
                XCTFail("Private access failure must remain visible")
            } catch { XCTAssertTrue(String(describing: error).contains("latest installer")) }
            let requests = await feed.requests
            XCTAssertEqual(requests.count, access?.isEmpty == false ? 2 : 1)
        }
    }

    func testRateLimitsAndServerFailuresDoNotReadCredentialsOrRetry() async {
        let url = URL(string: "https://api.github.com/repos/o/r/releases/latest")!
        for status in [429, 500, 503] {
            let feed = Feed([status])
            do {
                _ = try await Updater.fetch(url, accept: "application/vnd.github+json", access: {
                    XCTFail("No access retry for rate limits or server errors")
                    return "test-fixture"
                }, send: { try await feed.send($0) })
                XCTFail()
            } catch { }
            let requests = await feed.requests
            XCTAssertEqual(requests.count, 1)
        }
        for headers in [["X-RateLimit-Remaining": "0"], ["Retry-After": "60"]] {
            XCTAssertThrowsError(try Updater.expectOK(HTTPURLResponse(url: url, statusCode: 403,
                                                                     httpVersion: nil, headerFields: headers)!)) {
                XCTAssertFalse(($0 as? Updater.UpdateError)?.permitsAccessRetry ?? true)
                XCTAssertTrue(String(describing: $0).contains("rate limit"))
            }
        }
    }

    func testUntrustedURLNeverReadsOrSendsAccess() async {
        do {
            _ = try await Updater.fetch(URL(string: "https://example.com/releases/latest")!, accept: "application/json", access: {
                XCTFail("Untrusted origins cannot read access")
                return "test-fixture"
            }, send: { _ in XCTFail("Untrusted origins cannot be fetched"); return Data() })
            XCTFail()
        } catch { }
    }

    private static let validDigest = "sha256:" + String(repeating: "a", count: 64)

    private func release(tag: String = "b2026090601", name: String = "FlowClone-0.3-2026090601.zip",
                         url: String = "https://api.github.com/repos/o/r/releases/assets/2",
                         digest: String? = validDigest) throws -> Updater.Release {
        var asset: [String: Any] = ["name": name, "url": url]
        if let digest { asset["digest"] = digest }
        let data = try JSONSerialization.data(withJSONObject: [
            "tag_name": tag, "assets": [asset]
        ])
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(Updater.Release.self, from: data)
    }

    func testManifestRejectsAmbiguousOrUntrustedAssets() throws {
        XCTAssertNoThrow(try Updater.Manifest(release()))
        XCTAssertThrowsError(try Updater.Manifest(release(digest: nil)), "Manifest must require a non-nil sha256 digest")
        for badDigest in ["", "md5:" + String(repeating: "a", count: 32), "sha256:short",
                          "sha256:" + String(repeating: "z", count: 64)] {
            XCTAssertThrowsError(try Updater.Manifest(release(digest: badDigest)))
        }
        for tag in ["b0", "b-1", "b+12", "b02026090601", "b99999999999999999999999999999"] {
            XCTAssertThrowsError(try Updater.Manifest(release(tag: tag)))
        }
        for name in ["Other-0.3-2026090601.zip", "FlowClone--2026090601.zip", "FlowClone-../x-2026090601.zip"] {
            XCTAssertThrowsError(try Updater.Manifest(release(name: name)))
        }
        for url in ["http://api.github.com/repos/o/r/releases/assets/2",
                    "https://evil.example/repos/o/r/releases/assets/2",
                    "https://api.github.com:444/repos/o/r/releases/assets/2",
                    "https://api.github.com/repos/o/r/contents/file"] {
            XCTAssertThrowsError(try Updater.Manifest(release(url: url)))
        }
        XCTAssertThrowsError(try Updater.Manifest(release(), expectedRepo: "another/repo"))
    }

    func testRedirectsStripCredentialsAndRejectPlaintext() throws {
        var request = URLRequest(url: URL(string: "https://release-assets.githubusercontent.com/example?signature=fixture")!)
        request.setValue("Bearer fixture", forHTTPHeaderField: "Authorization")
        XCTAssertNil(Updater.redirected(request)?.value(forHTTPHeaderField: "Authorization"))
        request.url = URL(string: "http://example.com/archive.zip")!
        XCTAssertNil(Updater.redirected(request))
        XCTAssertThrowsError(try Updater.expectOK(URLResponse(url: URL(string: "file:///tmp/fixture")!,
                                                            mimeType: nil, expectedContentLength: 0, textEncodingName: nil)))
    }

    @MainActor
    func testOverlappingChecksAreSingleFlightAndFailureIsRetryable() async {
        var calls = 0
        var pending: CheckedContinuation<Void, Never>?
        let first = Task {
            await Updater.check {
                calls += 1
                await withCheckedContinuation { pending = $0 }
                throw Updater.UpdateError("fixture failure")
            }
        }
        for _ in 0..<1_000 {
            if pending != nil { break }
            await Task.yield()
        }
        XCTAssertNotNil(pending)
        await Updater.check { calls += 1; throw Updater.UpdateError("overlapping call") }
        XCTAssertEqual(calls, 1)
        pending?.resume()
        await first.value
        await Updater.check { calls += 1; throw Updater.UpdateError("retry") }
        XCTAssertEqual(calls, 2)
    }

    func testRelaunchPathAndArgumentsNeverBecomeShellCode() {
        let path = URL(fileURLWithPath: "/tmp/it's a $(touch SENTINEL) `quoted` app/FlowClone.app")
        let arguments = Updater.relaunchArguments(app: path, pid: 42, arguments: ["--runid", "a b"])
        XCTAssertFalse(arguments[1].contains(path.path))
        XCTAssertTrue(arguments[1].contains("for attempt in 1 2 3 4 5"))
        XCTAssertTrue(arguments[1].contains("/usr/bin/open -n \"$@\""))
        XCTAssertEqual(Array(arguments.dropFirst(2)), ["_", "42", path.path, "--args", "--runid", "a b"])

        let quiet = Updater.relaunchArguments(app: path, pid: 42, arguments: ["--runid", "1"], background: true)
        XCTAssertTrue(quiet[1].contains("/usr/bin/open -g -n \"$@\""))
        XCTAssertEqual(Array(quiet.dropFirst(2)), ["_", "42", path.path, "--args", "--runid", "1", "--background"])

        let alreadyQuiet = Updater.relaunchArguments(app: path, pid: 42, arguments: ["--background"], background: true)
        XCTAssertEqual(Array(alreadyQuiet.dropFirst(2)), ["_", "42", path.path, "--args", "--background"])
    }

    func testInstallLocationErrorRejectsAppTranslocationAndUnwritableFolders() {
        let translocated = URL(fileURLWithPath: "/private/var/folders/xx/yy/T/AppTranslocation/1234/d/FlowClone.app")
        let translocatedError = Updater.installLocationError(bundleURL: translocated, isWritable: { _ in true })
        XCTAssertNotNil(translocatedError)
        XCTAssertTrue(translocatedError?.description.contains("Applications") == true)

        let unwritable = URL(fileURLWithPath: "/Applications/FlowClone.app")
        let unwritableError = Updater.installLocationError(bundleURL: unwritable, isWritable: { _ in false })
        XCTAssertNotNil(unwritableError)
        XCTAssertTrue(unwritableError?.description.contains("~/Applications") == true)

        let writable = URL(fileURLWithPath: "/Users/example/Applications/FlowClone.app")
        XCTAssertNil(Updater.installLocationError(bundleURL: writable, isWritable: { _ in true }))
    }

    func testStripDetritusRemovesQuarantineAndFinderInfo() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("detritus-\(UUID().uuidString)")
        let app = root.appendingPathComponent("FlowClone.app")
        let nested = app.appendingPathComponent("Contents/Info.plist")
        try FileManager.default.createDirectory(at: nested.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("plist".utf8).write(to: nested)
        defer { try? FileManager.default.removeItem(at: root) }

        try Updater.run("/usr/bin/xattr", "-w", "com.apple.quarantine", "0081;00000000;Safari;", app.path)
        try Updater.run("/usr/bin/xattr", "-wx", "com.apple.FinderInfo", String(repeating: "00", count: 32), nested.path)
        Updater.stripDetritus(app)

        XCTAssertThrowsError(try Updater.run("/usr/bin/xattr", "-p", "com.apple.quarantine", app.path))
        XCTAssertThrowsError(try Updater.run("/usr/bin/xattr", "-p", "com.apple.FinderInfo", nested.path))
    }

    @MainActor
    private func makeFixtureBundle(in directory: URL, build: Int, version: String = "0.3") throws -> URL {
        let app = directory.appendingPathComponent("FlowClone.app")
        let contents = app.appendingPathComponent("Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let plist: NSDictionary = [
            "CFBundleVersion": String(build),
            "CFBundleShortVersionString": version
        ]
        XCTAssertTrue(plist.write(to: contents.appendingPathComponent("Info.plist"), atomically: true))
        return app
    }

    @MainActor
    func testUnattendedCheckDefersWhileWindowOpenAndUserInstallProceedsImmediately() async throws {
        defer { Updater.resetForTesting() }
        Updater.resetForTesting()

        let root = FileManager.default.temporaryDirectory.appendingPathComponent("updater-flow-\(UUID().uuidString)")
        let installedDir = root.appendingPathComponent("installed")
        let stagingDir = root.appendingPathComponent("staging")
        try FileManager.default.createDirectory(at: installedDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: stagingDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let dest = try makeFixtureBundle(in: installedDir, build: 2026111003)
        let stagedApp = try makeFixtureBundle(in: stagingDir, build: 2026111201)

        let windowOpen = true
        var workRunning = false
        var relaunched: URL?

        Updater.destinationBundleURL = { dest }
        Updater.verifyBundle = { _ in }
        Updater.workActive = { workRunning }
        Updater.sessionActive = { workRunning || windowOpen }
        Updater.performRelaunch = { url in relaunched = url; return true }

        Updater.stageForTesting(build: 2026111201, version: "0.3",
                                location: Updater.Staging(root: stagingDir, app: stagedApp))

        // Unattended check defers while MainWindow is open.
        await Updater.check(userInitiated: false) {
            XCTFail("Staged update must not re-fetch release metadata")
            throw Updater.UpdateError("unexpected fetch")
        }
        XCTAssertTrue(Updater.hasStagedUpdate)
        XCTAssertNil(relaunched)
        XCTAssertEqual(Updater.bundleBuild(dest), 2026111003)
        XCTAssertTrue(Updater.status.contains("Install & Relaunch"))

        // Even user-initiated install waits if real dictation/meeting work is running.
        workRunning = true
        await Updater.installNow()
        XCTAssertTrue(Updater.hasStagedUpdate)
        XCTAssertNil(relaunched)
        XCTAssertTrue(Updater.status.contains("dictation or meeting"))

        // Once work finishes, user-initiated install swaps and relaunches even with Settings open.
        workRunning = false
        await Updater.installNow()
        XCTAssertFalse(Updater.hasStagedUpdate)
        XCTAssertEqual(relaunched, dest)
        XCTAssertEqual(Updater.bundleBuild(dest), 2026111201)
        XCTAssertEqual(Updater.bundleBuild(dest.appendingPathExtension("old")), 2026111003)
    }

    @MainActor
    func testClosingWindowImmediatelyInstallsDeferredUpdate() async throws {
        defer { Updater.resetForTesting() }
        Updater.resetForTesting()

        let root = FileManager.default.temporaryDirectory.appendingPathComponent("updater-close-\(UUID().uuidString)")
        let installedDir = root.appendingPathComponent("installed")
        let stagingDir = root.appendingPathComponent("staging")
        try FileManager.default.createDirectory(at: installedDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: stagingDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let dest = try makeFixtureBundle(in: installedDir, build: 2026111003)
        let stagedApp = try makeFixtureBundle(in: stagingDir, build: 2026111201)

        var windowOpen = true
        var relaunched: URL?
        Updater.destinationBundleURL = { dest }
        Updater.verifyBundle = { _ in }
        Updater.workActive = { false }
        Updater.sessionActive = { windowOpen }
        Updater.performRelaunch = { url in relaunched = url; return true }

        Updater.stageForTesting(build: 2026111201, version: "0.3",
                                location: Updater.Staging(root: stagingDir, app: stagedApp))
        await Updater.check(userInitiated: false)
        XCTAssertTrue(Updater.hasStagedUpdate)
        XCTAssertNil(relaunched)

        windowOpen = false
        Updater.windowDidClose()
        for _ in 0..<200 where relaunched == nil {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(relaunched, dest)
        XCTAssertFalse(Updater.hasStagedUpdate)
        XCTAssertEqual(Updater.bundleBuild(dest), 2026111201)
    }

    func testArchiveSelectionRejectsDuplicatesAndSymlinkApps() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let app = root.appendingPathComponent("FlowClone.app")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertEqual(try Updater.findApp(in: root).resolvingSymlinksInPath().path,
                       app.resolvingSymlinksInPath().path)
        let duplicate = root.appendingPathComponent("wrapper/FlowClone.app")
        try FileManager.default.createDirectory(at: duplicate, withIntermediateDirectories: true)
        XCTAssertThrowsError(try Updater.findApp(in: root))
        try FileManager.default.removeItem(at: app)
        try FileManager.default.createSymbolicLink(at: app, withDestinationURL: duplicate)
        XCTAssertThrowsError(try Updater.findApp(in: root))
    }

    func testFailedSwapRestoresOriginalBundle() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let app = root.appendingPathComponent("FlowClone.app")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let sentinel = app.appendingPathComponent("original")
        try Data("original".utf8).write(to: sentinel)
        XCTAssertThrowsError(try Updater.swap(new: root.appendingPathComponent("missing.app"), into: app))
        XCTAssertEqual(try String(contentsOf: sentinel, encoding: .utf8), "original")
        XCTAssertFalse(FileManager.default.fileExists(atPath: app.appendingPathExtension("old").path))
    }
    /// Tag `b<build>` and asset `FlowClone-<version>-<build>.zip` are the contract with
    /// `build.sh publish`; the manifest must come out of GitHub's "latest release" JSON.
    func testManifestFromGitHubLatestRelease() throws {
        let expectedDigest = "sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
        let json = """
        {"tag_name":"b2026090601","name":"FlowClone 0.3 (2026090601)",
         "assets":[{"name":"README.txt","url":"https://api.github.com/repos/o/r/releases/assets/1"},
                   {"name":"FlowClone-0.3-2026090601.zip","url":"https://api.github.com/repos/o/r/releases/assets/2","digest":"\(expectedDigest.uppercased())"}]}
        """
        let dec = JSONDecoder()
        dec.keyDecodingStrategy = .convertFromSnakeCase
        let m = try Updater.Manifest(try dec.decode(Updater.Release.self, from: Data(json.utf8)))
        XCTAssertEqual(m.build, 2026090601)
        XCTAssertEqual(m.version, "0.3")
        XCTAssertEqual(m.url.absoluteString, "https://api.github.com/repos/o/r/releases/assets/2")
        XCTAssertEqual(m.digest, expectedDigest)

        let missingDigest = #"""
        {"tag_name":"b2026090601","name":"FlowClone 0.3 (2026090601)",
         "assets":[{"name":"FlowClone-0.3-2026090601.zip","url":"https://api.github.com/repos/o/r/releases/assets/2"}]}
        """#
        XCTAssertThrowsError(try Updater.Manifest(try dec.decode(Updater.Release.self, from: Data(missingDigest.utf8))))

        let bad = #"{"tag_name":"v0.3","assets":[]}"#
        XCTAssertThrowsError(try Updater.Manifest(try dec.decode(Updater.Release.self, from: Data(bad.utf8))))
    }

    @MainActor
    func testQuarantineIsNotStrippedBeforeSignatureAndVersionVerificationPasses() async throws {
        defer { Updater.resetForTesting() }
        Updater.resetForTesting()

        let root = FileManager.default.temporaryDirectory.appendingPathComponent("updater-quarantine-order-\(UUID().uuidString)")
        let installedDir = root.appendingPathComponent("installed")
        let stagingDir = root.appendingPathComponent("staging")
        try FileManager.default.createDirectory(at: installedDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: stagingDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let dest = try makeFixtureBundle(in: installedDir, build: 2026111003)
        let stagedApp = try makeFixtureBundle(in: stagingDir, build: 2026111201)
        try Updater.run("/usr/bin/xattr", "-w", "com.apple.quarantine", "0081;00000000;Safari;", stagedApp.path)

        let quarantinePresentDuringVerify = OSAllocatedUnfairLock(initialState: false)
        Updater.destinationBundleURL = { dest }
        Updater.verifyBundle = { candidate in
            let present = (try? Updater.run("/usr/bin/xattr", "-p", "com.apple.quarantine", candidate.path)) != nil
            quarantinePresentDuringVerify.withLock { $0 = present }
            throw Updater.UpdateError("signature rejected")
        }
        Updater.performRelaunch = { _ in XCTFail("Rejected bundle must never relaunch"); return false }
        Updater.stageForTesting(build: 2026111201, version: "0.3",
                                location: Updater.Staging(root: stagingDir, app: stagedApp))

        await Updater.installNow()
        XCTAssertTrue(quarantinePresentDuringVerify.withLock { $0 },
                      "stripDetritus must run only AFTER signature and version checks succeed")
    }

    func testBundleBuildReadsCFBundleVersionAsInteger() throws {
        let app = FileManager.default.temporaryDirectory
            .appendingPathComponent("UpdaterTests-\(UUID().uuidString).app")
        let contents = app.appendingPathComponent("Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: app) }
        XCTAssertNil(Updater.bundleBuild(app), "no Info.plist → nil, never 0")
        let plist: NSDictionary = ["CFBundleVersion": "2026090401"]
        XCTAssertTrue(plist.write(to: contents.appendingPathComponent("Info.plist"), atomically: true))
        XCTAssertEqual(Updater.bundleBuild(app), 2026090401)
    }

    func testUnsignedDirectoryNeverPassesVerify() throws {
        let app = FileManager.default.temporaryDirectory
            .appendingPathComponent("UpdaterTests-\(UUID().uuidString).app")
        try FileManager.default.createDirectory(at: app.appendingPathComponent("Contents/MacOS"),
                                                withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: app) }
        XCTAssertThrowsError(try Updater.verify(app))
    }

    @MainActor
    func testAppTerminationFlagsAndSettingsRelaunchBlockReasons() {
        defer { AppTermination.reset() }
        AppTermination.reset()
        XCTAssertFalse(AppTermination.isRelaunching)
        XCTAssertFalse(AppTermination.explicitUserQuit)

        AppTermination.isRelaunching = true
        XCTAssertTrue(AppTermination.isRelaunching)
        AppTermination.reset()
        XCTAssertFalse(AppTermination.isRelaunching)

        XCTAssertNil(SettingsPage.relaunchBlockReason(meetingBlocks: false, transformBlocks: false))
        XCTAssertEqual(
            SettingsPage.relaunchBlockReason(meetingBlocks: true, transformBlocks: false),
            "Finish the current meeting before relaunching.")
        XCTAssertEqual(
            SettingsPage.relaunchBlockReason(meetingBlocks: true, transformBlocks: true),
            "Finish the current meeting before relaunching.")
        XCTAssertEqual(
            SettingsPage.relaunchBlockReason(meetingBlocks: false, transformBlocks: true),
            "Finish the current dictation before relaunching.")
    }

    func testBackgroundPreviousBundleCleanupRunsOffMainActorAndAlwaysDeletesOldApp() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("updater-old-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }

        // 1. Public install with NO legacy FlowCloneUpdateToken (`migrateAccess` returns false):
        //    cleanup MUST run off `@MainActor` AND unconditionally remove `FlowClone.app.old`.
        let publicOld = root.appendingPathComponent("public/FlowClone.app.old")
        try FileManager.default.createDirectory(at: publicOld.appendingPathComponent("Contents"),
                                                withIntermediateDirectories: true)
        final class FlagBox: @unchecked Sendable {
            let lock = NSLock()
            var ranOnMainThread = true
            var migrateCalls = 0
        }
        let box = FlagBox()
        await Updater.schedulePreviousBundleCleanup(
            at: publicOld,
            readAccess: {
                box.lock.lock()
                box.ranOnMainThread = Thread.isMainThread
                box.lock.unlock()
                return nil
            },
            migrateAccess: { _ in
                box.lock.lock()
                box.migrateCalls += 1
                box.lock.unlock()
                return false
            }
        ).value

        XCTAssertFalse(box.ranOnMainThread, "Previous-bundle cleanup must run off the main thread")
        XCTAssertEqual(box.migrateCalls, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: publicOld.path),
                       "FlowClone.app.old must be removed even when no legacy token was migrated")

        // 2. Subsequent launch with no `FlowClone.app.old` performs no Keychain or migration work.
        await Updater.schedulePreviousBundleCleanup(
            at: publicOld,
            readAccess: { XCTFail("Must not read Keychain when FlowClone.app.old is absent"); return nil },
            migrateAccess: { _ in XCTFail("Must not verify missing bundle"); return false }
        ).value
    }

    @MainActor
    func testEvictedStagedBundleClearsAndReChecksWithoutError() async throws {
        defer { Updater.resetForTesting() }
        Updater.resetForTesting()

        let root = FileManager.default.temporaryDirectory.appendingPathComponent("updater-evicted-\(UUID().uuidString)")
        let missingStaging = root.appendingPathComponent("missing-staging")
        defer { try? FileManager.default.removeItem(at: root) }

        Updater.stageForTesting(
            build: 2026111601,
            version: "0.3",
            location: Updater.Staging(root: missingStaging, app: missingStaging.appendingPathComponent("FlowClone.app"))
        )

        var notifications = 0
        let token = NotificationCenter.default.addObserver(forName: Updater.didChange, object: nil, queue: nil) { _ in
            MainActor.assumeIsolated { notifications += 1 }
        }
        defer { NotificationCenter.default.removeObserver(token) }

        var fetchedAgain = false
        await Updater.check(userInitiated: true) {
            XCTAssertTrue(Updater.isChecking)
            XCTAssertTrue(Updater.isBusy)
            fetchedAgain = true
            throw Updater.UpdateError("network probed after evicted staging cleared")
        }
        XCTAssertTrue(fetchedAgain, "Evicted temp staging must trigger a fresh check instead of failing install")
        XCTAssertFalse(Updater.hasStagedUpdate)
        XCTAssertFalse(Updater.isBusy)
        XCTAssertGreaterThan(notifications, 0)
    }
}
