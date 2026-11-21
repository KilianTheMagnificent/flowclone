import Foundation
import Darwin

/// Every committed dictation, newest first, persisted as JSON Lines so the main window's
/// history survives relaunch. Main-thread confined: the pipeline hops to the main actor to
/// add, the window reads `items` directly and re-renders when `version` changes.
///
/// Privacy: the file is owner-only (0700 dir / 0600 file). Saving can be switched off in
/// Settings ("Save dictation history"); while off, only the last `memoryCap` items of this
/// launch are kept in memory and nothing is written. Self-test and repaste origins are
/// never written, the same rule `TranscriptionStats` applies.
@MainActor
enum History {
    struct Item: Codable, Identifiable, Equatable, Sendable {
        var id = UUID()
        var date = Date()
        let raw: String
        let final: String
        var seconds: Double = 0
        var words: Int = 0
        var mode: String = ""
        var cleaned: String? = nil
        var effectiveMode: String? = nil
        var input: String? = nil
        var model: String? = nil
        var targetApp: String? = nil
        var delivery: DeliveryState? = nil
        var parentID: UUID? = nil
        var audioName: String? = nil
        var schemaVersion: Int? = 2

        enum CodingKeys: String, CodingKey {
            case id, date, raw, final, seconds, words, mode, cleaned, effectiveMode,
                 input, model, targetApp, delivery, parentID, audioName, schemaVersion
        }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
            date = try c.decodeIfPresent(Date.self, forKey: .date) ?? .distantPast
            raw = try c.decode(String.self, forKey: .raw)
            final = try c.decode(String.self, forKey: .final)
            seconds = try c.decodeIfPresent(Double.self, forKey: .seconds) ?? 0
            words = try c.decodeIfPresent(Int.self, forKey: .words) ?? 0
            mode = try c.decodeIfPresent(String.self, forKey: .mode) ?? ""
            cleaned = try c.decodeIfPresent(String.self, forKey: .cleaned)
            effectiveMode = try c.decodeIfPresent(String.self, forKey: .effectiveMode)
            input = try c.decodeIfPresent(String.self, forKey: .input)
            model = try c.decodeIfPresent(String.self, forKey: .model)
            targetApp = try c.decodeIfPresent(String.self, forKey: .targetApp)
            delivery = try c.decodeIfPresent(DeliveryState.self, forKey: .delivery)
            parentID = try c.decodeIfPresent(UUID.self, forKey: .parentID)
            audioName = try c.decodeIfPresent(String.self, forKey: .audioName)
            schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion)
        }

        init(id: UUID = UUID(), date: Date = Date(), raw: String, final: String,
             seconds: Double = 0, words: Int = 0, mode: String = "",
             cleaned: String? = nil, effectiveMode: String? = nil, input: String? = nil,
             model: String? = nil, targetApp: String? = nil, delivery: DeliveryState? = nil,
             parentID: UUID? = nil, audioName: String? = nil) {
            self.id = id; self.date = date; self.raw = raw; self.final = final
            self.seconds = seconds; self.words = words; self.mode = mode
            self.cleaned = cleaned; self.effectiveMode = effectiveMode; self.input = input
            self.model = model; self.targetApp = targetApp; self.delivery = delivery
            self.parentID = parentID; self.audioName = audioName
        }
    }

    static let cap = 5_000
    static let memoryCap = 10
    static let enabledKey = "saveHistory"
    static var defaults = UserDefaults.standard

    static var storeURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/FlowClone/history.jsonl") {
        didSet { persistence.flush(); loaded = false; stored = []; transient = []; diskCount = 0 }
    }

    static var isEnabled: Bool {
        get { defaults.object(forKey: enabledKey) as? Bool ?? true }
        set {
            defaults.set(newValue, forKey: enabledKey)
            // A flip changes what `items` is allowed to hold, and a stale in-memory copy
            // reconciled later by `rewrite()` would overwrite the file with it — the whole
            // saved history replaced by the ten items of an off period, or an off period's
            // transcripts written after the toggle came back on. Re-read instead of
            // trusting the caller to remember. Idempotent with an explicit `reload()`.
            reload()
        }
    }

    /// Set by the main window so SwiftUI re-reads `items`.
    static var onChange: (() -> Void)?

    private static var stored: [Item] = []
    /// Items held in memory that must never reach the file: self-test and repaste origins,
    /// and anything added while saving was off. `rewrite()` dumps `stored`, so without this
    /// marker a later `remove(id:)` or cap overflow would persist them — and at the cap,
    /// evict a real dictation to make room.
    private static var transient: Set<UUID> = []
    private static var loaded = false
    private static let persistence = HistoryPersistence()
    private static var diskCount = 0
    /// At most 63 expired records await compaction on disk; the visible cap stays exact.
    static let compactionSlack = 64

    static var items: [Item] { loadIfNeeded(); return stored }
    private(set) static var version = 0

    static func add(raw: String, final: String, origin: DictationOrigin = .utterance,
                    seconds: Double = 0, mode: String = "", date: Date = Date(),
                    id: UUID = UUID(), cleaned: String? = nil, effectiveMode: String? = nil,
                    input: String? = nil, model: String? = nil, targetApp: String? = nil,
                    delivery: DeliveryState? = nil, parentID: UUID? = nil,
                    audio: [Float]? = nil) {
        loadIfNeeded()
        guard !stored.contains(where: { $0.id == id }) else { return }
        let canPersist = isEnabled && origin.contributesTranscribedWords
        let audioName = canPersist && HistoryAudio.isEnabled && audio != nil ? id.uuidString + ".wav" : nil
        let item = Item(id: id, date: date, raw: raw, final: final, seconds: parentID == nil ? seconds : 0,
                        words: TranscriptionStats.wordCount(in: final), mode: mode,
                        cleaned: cleaned, effectiveMode: effectiveMode, input: input, model: model,
                        targetApp: targetApp, delivery: delivery, parentID: parentID, audioName: audioName)
        if let audioName, let audio { HistoryAudio.save(audio, name: audioName) }
        stored.insert(item, at: 0)
        if isEnabled && origin.contributesTranscribedWords {
            var savedCount = 0
            stored.removeAll { entry in
                guard !transient.contains(entry.id) else { return false }
                savedCount += 1
                return savedCount > cap
            }
            seedSpeakingSecondsFromStored()
            // Append most of the time, compact the bounded journal once per 64 inserts.
            if diskCount >= cap + compactionSlack - 1 { rewrite() }
            else {
                persistence.append(item, to: storeURL)
                diskCount += 1
            }
        } else {
            transient.insert(item.id)
            var kept = 0
            stored.removeAll { entry in
                guard transient.contains(entry.id) else { return false }
                kept += 1
                guard kept > memoryCap else { return false }
                transient.remove(entry.id)
                return true
            }
        }
        bump()
    }

    struct DeliveryPatch: Codable, Sendable {
        var id: UUID
        var delivery: DeliveryState
        var effectiveMode: String? = nil
    }

    static func updateDelivery(id: UUID, state: DeliveryState, effectiveMode: String? = nil) {
        loadIfNeeded()
        guard let index = stored.firstIndex(where: { $0.id == id }) else { return }
        stored[index].delivery = state
        if let effectiveMode { stored[index].effectiveMode = effectiveMode }
        if isEnabled && !transient.contains(id) {
            if diskCount >= cap + compactionSlack - 1 {
                rewrite()
            } else {
                persistence.appendPatch(
                    DeliveryPatch(id: id, delivery: state, effectiveMode: effectiveMode),
                    to: storeURL)
                diskCount += 1
            }
        }
        bump()
    }

    static func canPersistDerived(from id: UUID) -> Bool {
        loadIfNeeded()
        return isEnabled && !transient.contains(id) && stored.contains(where: { $0.id == id })
    }

    /// Retention never promotes a transcript created while saving was off.
    static func applyRetention(now: Date = Date()) {
        guard isEnabled else { HistoryAudio.prune(keeping: nil, now: now); return }
        loadIfNeeded()
        let days = defaults.integer(forKey: "historyRetentionDays")
        if days > 0 {
            let cutoff = now.addingTimeInterval(-Double(days) * 86_400)
            let expired = stored.filter { $0.date < cutoff }
            stored.removeAll { $0.date < cutoff }
            transient.subtract(expired.map(\.id))
            if !expired.isEmpty { if isEnabled { rewrite() }; bump() }
        }
        HistoryAudio.prune(keeping: Set(stored.compactMap(\.audioName)), now: now)
    }

    static func remove(id: UUID) {
        loadIfNeeded()
        guard let index = stored.firstIndex(where: { $0.id == id }) else { return }
        let removed = stored.remove(at: index)
        if let name = removed.audioName { HistoryAudio.remove(name: name) }
        let wasTransient = transient.remove(id) != nil
        if isEnabled && !wasTransient { rewrite() }
        bump()
    }

    static func clear() {
        loadIfNeeded()
        stored = []
        transient = []
        diskCount = 0
        persistence.clear(storeURL)
        HistoryAudio.prune(keeping: [])
        bump()
    }

    /// Drop the in-memory copy and re-read the file on next access. Used after the Save
    /// toggle flips so the window shows exactly what is on disk (or nothing).
    static func reload() {
        persistence.flush()
        diskCount = 0
        loaded = false
        stored = []
        transient = []
        bump()
    }

    // MARK: - Derived stats

    static func speakingSeconds() -> Double {
        let historyTotal = items.reduce(0.0) { $0 + ($1.seconds.isFinite ? max(0, $1.seconds) : 0) }
        return max(TranscriptionStats.totalSeconds(in: defaults), historyTotal)
    }

    static func wordsPerMinute() -> Int? {
        let timed = items.filter { $0.seconds > 0 }
        let seconds = timed.reduce(0.0) { $0 + $1.seconds }
        guard seconds > 0 else { return nil }
        let words = timed.reduce(0) { $0 + $1.words }
        return Int((Double(words) / seconds * 60).rounded())
    }

    /// Consecutive calendar days with at least one dictation, counted back from today, or
    /// from yesterday when today has none yet. Zero when both are empty.
    static func streakDays(today: Date = Date(), calendar: Calendar = .current) -> Int {
        let days = Set(items.map { calendar.startOfDay(for: $0.date) })
        var day = calendar.startOfDay(for: today)
        if !days.contains(day) {
            guard let yesterday = calendar.date(byAdding: .day, value: -1, to: day),
                  days.contains(yesterday) else { return 0 }
            day = yesterday
        }
        var streak = 0
        while days.contains(day) {
            streak += 1
            guard let previous = calendar.date(byAdding: .day, value: -1, to: day) else { break }
            day = previous
        }
        return streak
    }

    /// "TODAY", "YESTERDAY", "SEP 1", or "SEP 6, 2025" — the list's section headers.
    /// Main-actor confined so the two cached formatters below can be reused: building a
    /// `DateFormatter` per row is the expensive part, and the only callers (the window and
    /// the tests) are already on the main actor.
    static func sectionTitle(for date: Date, today: Date = Date(),
                             calendar: Calendar = .current) -> String {
        let day = calendar.startOfDay(for: date)
        let now = calendar.startOfDay(for: today)
        if day == now { return "TODAY" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), day == yesterday {
            return "YESTERDAY"
        }
        let sameYear = calendar.component(.year, from: day) == calendar.component(.year, from: now)
        let formatter = sameYear ? sameYearFormatter : otherYearFormatter
        // Callers pass their own calendar (the tests use a Gregorian one), so this stays
        // per-call even though the formatter itself is shared.
        formatter.calendar = calendar
        return formatter.string(from: day).uppercased()
    }

    private static let sameYearFormatter: DateFormatter = makeFormatter("MMM d")
    private static let otherYearFormatter: DateFormatter = makeFormatter("MMM d, yyyy")

    private static func makeFormatter(_ format: String) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = format
        return f
    }

    /// 34_812 → "34.8K", 1_250_000 → "1.3M". One decimal below 100 of a unit, none above.
    nonisolated static func compact(_ n: Int) -> String {
        func scaled(_ value: Double, _ suffix: String) -> String {
            let text = value < 100 ? String(format: "%.1f", value) : String(format: "%.0f", value)
            let trimmed = text.hasSuffix(".0") ? String(text.dropLast(2)) : text
            return trimmed + suffix
        }
        if n >= 1_000_000 { return scaled(Double(n) / 1_000_000, "M") }
        if n >= 1_000 { return scaled(Double(n) / 1_000, "K") }
        return String(n)
    }

    // MARK: - Storage

    /// Shutdown and explicit read-after-write barriers; ordinary dictations never wait.
    static func flush() { persistence.flush(); HistoryAudio.flush() }

    private static func bump() {
        version += 1
        onChange?()
    }

    private static func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        guard isEnabled else { return }
        let result = persistence.read(storeURL, cap: cap)
        stored = result.items
        diskCount = result.lineCount
        seedSpeakingSecondsFromStored()
        if diskCount >= cap + compactionSlack || result.totalItems > cap { rewrite() }
        applyRetention()
    }

    private static func seedSpeakingSecondsFromStored() {
        let savedSeconds = stored.reduce(0.0) { total, entry in
            guard !transient.contains(entry.id), entry.seconds.isFinite else { return total }
            return total + max(0, entry.seconds)
        }
        TranscriptionStats.seedTotalSeconds(atLeast: savedSeconds, in: defaults)
    }

    private static func rewrite() {
        let saved = stored.filter { !transient.contains($0.id) }
        diskCount = saved.count
        persistence.rewrite(saved, to: storeURL)
    }
}

/// One writer owns encoding and disk IO. FIFO ordering makes clear, remove, toggles,
/// compaction, and shutdown barriers consistent even while prior appends are pending.
private final class HistoryPersistence: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.andre.flowclone.history", qos: .utility)
    private let encoder = JSONEncoder()
    private var reportedFailure = false

    func flush() { queue.sync {} }

    func read(_ url: URL, cap: Int) -> (items: [History.Item], totalItems: Int, lineCount: Int) {
        queue.sync {
            guard let data = try? Data(contentsOf: url) else { return ([], 0, 0) }
            let decoder = JSONDecoder()
            var items: [History.Item] = []
            var indexByID: [UUID: Int] = [:]
            var validLines = 0
            var bad = 0
            for line in data.split(separator: 0x0a) where !line.isEmpty {
                if let item = try? decoder.decode(History.Item.self, from: line) {
                    validLines += 1
                    if let existing = indexByID[item.id] {
                        items[existing] = item
                    } else {
                        indexByID[item.id] = items.count
                        items.append(item)
                    }
                } else if let patch = try? decoder.decode(History.DeliveryPatch.self, from: line) {
                    validLines += 1
                    if let existing = indexByID[patch.id] {
                        items[existing].delivery = patch.delivery
                        if let effectiveMode = patch.effectiveMode {
                            items[existing].effectiveMode = effectiveMode
                        }
                    }
                } else {
                    bad += 1
                }
            }
            if bad > 0 { log("history: skipped \(bad) unreadable line(s)") }
            let totalItems = items.count
            items.sort { $0.date > $1.date }
            return (Array(items.prefix(cap)), totalItems, validLines)
        }
    }

    private func perform(_ operation: @Sendable @escaping () throws -> Void) {
        queue.async {
            do {
                try operation()
                self.reportedFailure = false
            } catch {
                if !self.reportedFailure {
                    self.reportedFailure = true
                    log("history: disk operation failed; in-memory changes may not survive relaunch: \(error)")
                }
            }
        }
    }

    func clear(_ url: URL) {
        perform {
            do { try FileManager.default.removeItem(at: url) }
            catch CocoaError.fileNoSuchFile { }
        }
    }

    func append(_ item: History.Item, to url: URL) {
        appendRecord(item, to: url)
    }

    func appendPatch(_ patch: History.DeliveryPatch, to url: URL) {
        appendRecord(patch, to: url)
    }

    private func appendRecord<T: Encodable & Sendable>(_ record: T, to url: URL) {
        perform {
            var line = try self.encoder.encode(record)
            line.append(0x0a)
            guard FileManager.default.fileExists(atPath: url.path) else {
                try PrivateFile.write(line, to: url)
                return
            }
            // Read the last byte before appending: a truncated record must not consume
            // the next valid one. Refuse symlinks and non-regular files before writing.
            let fd = Darwin.open(url.path, O_RDWR | O_APPEND | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
            guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
            defer { try? handle.close() }
            var info = stat()
            guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
                  fchmod(fd, 0o600) == 0 else { throw CocoaError(.fileWriteUnknown) }
            let end = try handle.seekToEnd()
            if end > 0 {
                try handle.seek(toOffset: end - 1)
                if try handle.read(upToCount: 1)?.first != 0x0a {
                    try handle.write(contentsOf: Data([0x0a]))
                }
            }
            try handle.write(contentsOf: line)
        }
    }

    func rewrite(_ items: [History.Item], to url: URL) {
        perform {
            var data = Data()
            for item in items.reversed() {
                data.append(try self.encoder.encode(item))
                data.append(0x0a)
            }
            try PrivateFile.write(data, to: url)
        }
    }
}
