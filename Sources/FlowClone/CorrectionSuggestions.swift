import Foundation

/// Transcript-derived suggestions are bounded (<= 20) and expire after 600s until the user
/// explicitly approves or dismisses them. Repeated edits are evidence, never automatic authority.
final class CorrectionSuggestions: @unchecked Sendable {
    static let didChange = Notification.Name("FlowCloneCorrectionSuggestionsChanged")
    static let ttl: TimeInterval = 600

    struct Item: Identifiable, Codable, Equatable, Sendable {
        let id: UUID
        let wrong: String
        let right: String
        let app: String
        let date: Date
    }

    private struct PersistedDocument: Codable {
        var version = 1
        var items: [Item]
    }

    private let lock = NSLock()
    private let storageURL: URL?
    private var items: [Item] = []

    init(storageURL: URL? = nil, now: Date = Date()) {
        self.storageURL = storageURL
        if let storageURL,
           let data = try? Data(contentsOf: storageURL),
           let doc = try? JSONDecoder().decode(PersistedDocument.self, from: data),
           doc.version == 1 {
            self.items = doc.items
                .filter { now.timeIntervalSince($0.date) <= Self.ttl }
                .suffix(20)
        }
    }

    func propose(wrong: String, right: String, app: String, now: Date = Date()) {
        lock.withLock {
            items.removeAll {
                $0.wrong.lowercased() == wrong.lowercased() || now.timeIntervalSince($0.date) > Self.ttl
            }
            items.append(Item(id: UUID(), wrong: wrong, right: right, app: app, date: now))
            if items.count > 20 { items.removeFirst(items.count - 20) }
            persistLocked()
        }
        postDidChange()
    }

    func current(now: Date = Date()) -> [Item] {
        var pruned = false
        let snapshot: [Item] = lock.withLock {
            let before = items.count
            items.removeAll { now.timeIntervalSince($0.date) > Self.ttl }
            pruned = items.count != before
            if pruned { persistLocked() }
            return items
        }
        if pruned { postDidChange() }
        return snapshot
    }

    @discardableResult
    func remove(_ id: UUID) -> Item? {
        let removed: Item? = lock.withLock {
            guard let index = items.firstIndex(where: { $0.id == id }) else { return nil }
            let item = items.remove(at: index)
            persistLocked()
            return item
        }
        if removed != nil { postDidChange() }
        return removed
    }

    func clear() {
        let hadItems: Bool = lock.withLock {
            guard !items.isEmpty else { return false }
            items.removeAll()
            persistLocked()
            return true
        }
        if hadItems { postDidChange() }
    }

    private func persistLocked() {
        guard let storageURL else { return }
        if items.isEmpty {
            try? FileManager.default.removeItem(at: storageURL)
            return
        }
        if let encoded = try? JSONEncoder().encode(PersistedDocument(items: items)) {
            try? PrivateFile.write(encoded, to: storageURL)
        }
    }

    private func postDidChange() {
        if Thread.isMainThread {
            NotificationCenter.default.post(name: Self.didChange, object: self)
        } else {
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: Self.didChange, object: self)
            }
        }
    }
}
