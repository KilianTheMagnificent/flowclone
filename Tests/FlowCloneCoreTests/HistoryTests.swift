import Foundation
import XCTest
@testable import FlowCloneCore

@MainActor
final class HistoryTests: XCTestCase {
    private var directory: URL!
    private var savedURL: URL!
    private var savedDefaults: UserDefaults!
    private var suiteName: String!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("flowclone-history-\(UUID().uuidString)", isDirectory: true)
        savedURL = History.storeURL
        savedDefaults = History.defaults
        suiteName = ScratchDefaults.name("history")
        History.defaults = UserDefaults(suiteName: suiteName)!
        History.storeURL = directory.appendingPathComponent("history.jsonl")
    }

    override func tearDown() async throws {
        History.storeURL = savedURL
        History.defaults.removePersistentDomain(forName: suiteName)
        History.defaults = savedDefaults
        try? FileManager.default.removeItem(at: directory)
    }

    private func date(_ daysAgo: Int, hour: Int = 10) -> Date {
        let cal = Calendar(identifier: .gregorian)
        let day = cal.date(byAdding: .day, value: -daysAgo, to: cal.startOfDay(for: Date()))!
        return cal.date(byAdding: .hour, value: hour, to: day)!
    }

    func testAddPersistsAndReloadsNewestFirst() throws {
        History.add(raw: "one raw", final: "one final", seconds: 2, mode: "clean")
        History.add(raw: "two raw", final: "two final", seconds: 3, mode: "polish")
        XCTAssertEqual(History.items.map(\.final), ["two final", "one final"])
        XCTAssertEqual(History.items.first?.words, 2)
        XCTAssertEqual(History.items.first?.mode, "polish")

        History.reload()
        XCTAssertEqual(History.items.map(\.final), ["two final", "one final"])
        XCTAssertEqual(History.items.last?.seconds, 2)

        let attrs = try FileManager.default.attributesOfItem(atPath: History.storeURL.path)
        XCTAssertEqual((attrs[.posixPermissions] as? Int).map { $0 & 0o777 }, 0o600)
    }

    func testCapKeepsNewest() {
        for i in 0..<(History.cap + 5) {
            History.add(raw: "r\(i)", final: "f\(i)", seconds: 1, mode: "clean")
        }
        XCTAssertEqual(History.items.count, History.cap)
        XCTAssertEqual(History.items.first?.final, "f\(History.cap + 4)")
        History.reload()
        XCTAssertEqual(History.items.count, History.cap)
    }

    func testDisabledKeepsLastTenInMemoryAndWritesNothing() {
        History.isEnabled = false
        History.reload()
        for i in 0..<12 { History.add(raw: "r\(i)", final: "f\(i)") }
        XCTAssertEqual(History.items.count, History.memoryCap)
        XCTAssertEqual(History.items.first?.final, "f11")
        XCTAssertFalse(FileManager.default.fileExists(atPath: History.storeURL.path))
    }

    func testSelfTestAndRepasteOriginsStayOutOfTheFile() {
        History.add(raw: "r", final: "self test", origin: .selfTest)
        History.add(raw: "r", final: "repaste", origin: .repaste)
        XCTAssertEqual(History.items.count, 2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: History.storeURL.path))
        History.add(raw: "r", final: "real", origin: .utterance)
        History.reload()
        XCTAssertEqual(History.items.map(\.final), ["real"])
    }

    func testCorruptLineIsSkipped() throws {
        History.add(raw: "r", final: "good one")
        History.flush()
        let handle = try FileHandle(forWritingTo: History.storeURL)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("{not json\n".utf8))
        try handle.close()
        History.add(raw: "r", final: "good two")
        History.reload()
        XCTAssertEqual(History.items.map(\.final), ["good two", "good one"])
    }

    /// A write cut short leaves a partial last line. The next append must not glue itself
    /// onto that fragment, which would lose the fragment's successor as well as the fragment.
    func testTruncatedLastLineDoesNotSwallowTheNextItem() throws {
        History.add(raw: "r", final: "intact", date: date(1))
        History.flush()
        let handle = try FileHandle(forWritingTo: History.storeURL)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("{\"raw\":\"cut sh".utf8))   // no trailing newline
        try handle.close()
        History.add(raw: "r", final: "after truncation", date: date(0))
        History.reload()
        XCTAssertEqual(History.items.map(\.final), ["after truncation", "intact"])
    }

    /// `rewrite()` dumps the in-memory list, so a self-test item left resident from an
    /// earlier `--selftest` must not ride along into the file on the next remove.
    func testRewriteDoesNotPersistTransientItems() {
        History.add(raw: "r", final: "self test", origin: .selfTest)
        History.add(raw: "r", final: "real", origin: .utterance)
        History.remove(id: History.items.first { $0.final == "real" }!.id)
        History.reload()
        XCTAssertTrue(History.items.isEmpty)
    }

    /// Flipping the Save toggle must reconcile the in-memory copy by itself: a stale copy
    /// later flushed by `rewrite()` would replace the saved file with an off period's items.
    func testSaveToggleReconcilesWithoutAnExplicitReload() {
        History.add(raw: "r", final: "a", date: date(3))
        History.add(raw: "r", final: "b", date: date(2))
        History.add(raw: "r", final: "c", date: date(1))
        History.isEnabled = false                       // setter only, no explicit reload
        History.add(raw: "r", final: "while off")
        XCTAssertEqual(History.items.map(\.final), ["while off"])
        History.isEnabled = true                        // setter only
        XCTAssertEqual(History.items.map(\.final), ["c", "b", "a"])
        History.remove(id: History.items.first { $0.final == "b" }!.id)
        History.reload()
        XCTAssertEqual(History.items.map(\.final), ["c", "a"])
    }

    func testRemoveAndClearRewriteTheFile() {
        History.add(raw: "r", final: "keep")
        History.add(raw: "r", final: "drop")
        let drop = History.items.first!.id
        History.remove(id: drop)
        History.reload()
        XCTAssertEqual(History.items.map(\.final), ["keep"])
        History.clear()
        XCTAssertTrue(History.items.isEmpty)
        History.flush()
        XCTAssertFalse(FileManager.default.fileExists(atPath: History.storeURL.path))
        History.reload()
        XCTAssertTrue(History.items.isEmpty)
    }

    func testVersionAndOnChangeFire() {
        var fired = 0
        History.onChange = { fired += 1 }
        defer { History.onChange = nil }
        let before = History.version
        History.add(raw: "r", final: "x")
        History.clear()
        XCTAssertEqual(History.version, before + 2)
        XCTAssertEqual(fired, 2)
    }

    func testTransientItemsAreBoundedWithoutEvictingSavedItems() {
        for i in 0..<History.cap { History.add(raw: "r", final: "saved \(i)") }
        for i in 0..<30 { History.add(raw: "r", final: "temporary \(i)", origin: .repaste) }
        XCTAssertEqual(History.items.count, History.cap + History.memoryCap)
        History.add(raw: "r", final: "new saved")
        XCTAssertEqual(History.items.filter { $0.final.hasPrefix("temporary") }.count, History.memoryCap)
        XCTAssertEqual(History.items.filter { !$0.final.hasPrefix("temporary") }.count, History.cap)
        History.reload()
        XCTAssertEqual(History.items.count, History.cap)
        XCTAssertFalse(History.items.contains { $0.final.hasPrefix("temporary") })
    }

    func testPendingWritesCannotResurrectClearedHistory() {
        for i in 0..<100 { History.add(raw: "r", final: "old \(i)") }
        History.clear()
        History.add(raw: "r", final: "after clear")
        History.reload()
        XCTAssertEqual(History.items.map(\.final), ["after clear"])
    }

    func testHistoryJournalCompactionIsBounded() throws {
        for i in 0..<(History.cap + History.compactionSlack + 5) {
            History.add(raw: "r", final: "saved \(i)")
        }
        History.flush()
        let lines = try Data(contentsOf: History.storeURL).split(separator: 0x0a)
        XCTAssertLessThan(lines.count, History.cap + History.compactionSlack)
        History.reload()
        XCTAssertEqual(History.items.count, History.cap)
    }

    func testWordsPerMinuteIgnoresUntimedItems() {
        XCTAssertNil(History.wordsPerMinute())
        History.add(raw: "r", final: "one two three four five six", seconds: 3)   // 120 wpm
        History.add(raw: "r", final: "untimed words here", seconds: 0)
        History.add(raw: "r", final: "seven eight", seconds: 3)                    // 40 wpm
        XCTAssertEqual(History.wordsPerMinute(), 80)                                // 8 words / 6 s
    }

    func testSpeakingSecondsSeedsFromSavedHistoryAndSurvivesClear() {
        XCTAssertEqual(History.speakingSeconds(), 0)
        History.add(raw: "r", final: "first dictation", seconds: 4.5)
        History.add(raw: "r", final: "second dictation", seconds: 7.5)
        XCTAssertEqual(History.speakingSeconds(), 12.0, accuracy: 0.001)
        History.clear()
        XCTAssertEqual(History.speakingSeconds(), 12.0, accuracy: 0.001)
    }

    func testStreakCountsConsecutiveDaysEndingTodayOrYesterday() {
        let cal = Calendar(identifier: .gregorian)
        XCTAssertEqual(History.streakDays(calendar: cal), 0)
        History.add(raw: "r", final: "a", date: date(3))
        History.add(raw: "r", final: "b", date: date(2))
        History.add(raw: "r", final: "c", date: date(1))
        XCTAssertEqual(History.streakDays(calendar: cal), 3)      // ends yesterday
        History.add(raw: "r", final: "d", date: date(0))
        XCTAssertEqual(History.streakDays(calendar: cal), 4)      // ends today
        History.clear()
        History.add(raw: "r", final: "e", date: date(2))
        XCTAssertEqual(History.streakDays(calendar: cal), 0)      // gap yesterday and today
    }

    func testSectionTitles() {
        let cal = Calendar(identifier: .gregorian)
        let today = cal.date(from: DateComponents(year: 2026, month: 9, day: 6, hour: 12))!
        XCTAssertEqual(History.sectionTitle(for: today, today: today, calendar: cal), "TODAY")
        XCTAssertEqual(History.sectionTitle(for: cal.date(byAdding: .day, value: -1, to: today)!,
                                            today: today, calendar: cal), "YESTERDAY")
        XCTAssertEqual(History.sectionTitle(for: cal.date(byAdding: .day, value: -5, to: today)!,
                                            today: today, calendar: cal), "SEP 1")
        XCTAssertEqual(History.sectionTitle(for: cal.date(byAdding: .year, value: -1, to: today)!,
                                            today: today, calendar: cal), "SEP 6, 2025")
    }

    func testCompactNumbers() {
        XCTAssertEqual(History.compact(0), "0")
        XCTAssertEqual(History.compact(999), "999")
        XCTAssertEqual(History.compact(1_000), "1K")
        XCTAssertEqual(History.compact(34_812), "34.8K")
        XCTAssertEqual(History.compact(120_400), "120K")
        XCTAssertEqual(History.compact(1_260_000), "1.3M")
    }

    func testGreetingUsesFirstName() {
        XCTAssertEqual(DictationPage.greeting(fullName: "Andre Romero"), "Welcome back, Andre")
        XCTAssertEqual(DictationPage.greeting(fullName: ""), "Welcome back")
    }

    func testUpdateDeliveryAppendsLightweightPatchWithoutRewritingAndCompactsAtBound() throws {
        let first = UUID(), second = UUID()
        History.add(raw: "raw one", final: String(repeating: "long body ", count: 40),
                    mode: "clean", id: first)
        History.add(raw: "raw two", final: "second dictation",
                    mode: "prompt", id: second)
        History.flush()

        let beforeLines = try String(contentsOf: History.storeURL, encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        XCTAssertEqual(beforeLines.count, 2)

        History.updateDelivery(id: first, state: .confirmed, effectiveMode: "clean")
        History.updateDelivery(id: second, state: .draft)
        History.flush()

        let afterLines = try String(contentsOf: History.storeURL, encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        XCTAssertEqual(afterLines.count, 4, "Each delivery update appends one patch line instead of rewriting all entries")
        XCTAssertEqual(Array(afterLines.prefix(2)), beforeLines, "Earlier item lines are untouched")
        XCTAssertFalse(afterLines[2].contains("long body"), "Patch record carries only id, delivery, and optional effectiveMode")

        // Reload reconciles patches in place without rewriting a clean journal under cap.
        History.reload()
        XCTAssertEqual(History.items.count, 2)
        XCTAssertEqual(History.items.first(where: { $0.id == first })?.delivery, .confirmed)
        XCTAssertEqual(History.items.first(where: { $0.id == first })?.effectiveMode, "clean")
        XCTAssertEqual(History.items.first(where: { $0.id == second })?.delivery, .draft)

        // Legacy compatibility: if an older build wrote a duplicate full Item line with the same id,
        // reload reconciles by id instead of duplicating the item.
        var duplicate = try XCTUnwrap(History.items.first(where: { $0.id == second }))
        duplicate.delivery = .confirmed
        duplicate.effectiveMode = "prompt"
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var legacyLine = try encoder.encode(duplicate)
        legacyLine.append(0x0a)
        let handle = try FileHandle(forWritingTo: History.storeURL)
        try handle.seekToEnd()
        try handle.write(contentsOf: legacyLine)
        try handle.close()

        History.reload()
        XCTAssertEqual(History.items.count, 2)
        XCTAssertEqual(History.items.first(where: { $0.id == second })?.delivery, .confirmed)
        XCTAssertEqual(History.items.first(where: { $0.id == second })?.effectiveMode, "prompt")

        // Repeated delivery updates eventually trigger bounded compaction once diskCount reaches cap + compactionSlack - 1.
        History.clear()
        let compactID = UUID()
        History.add(raw: "r", final: "f", id: compactID)
        for i in 0..<(History.cap + History.compactionSlack) {
            History.updateDelivery(id: compactID, state: i.isMultiple(of: 2) ? .unverified : .confirmed)
        }
        History.flush()
        let compactedLines = try Data(contentsOf: History.storeURL).split(separator: 0x0a)
        XCTAssertLessThan(compactedLines.count, 10, "Compaction collapses accumulated delivery patches back to stored items")
        History.reload()
        XCTAssertEqual(History.items.count, 1)
    }
}
