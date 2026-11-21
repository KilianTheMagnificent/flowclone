import CryptoKit
import Darwin
import Foundation

enum PersonalizationKind: String, CaseIterable, Codable, Sendable {
    case dictionary
    case snippet
    case correction

    var filename: String {
        switch self {
        case .dictionary: return "dictionary.txt"
        case .snippet: return "snippets.txt"
        case .correction: return "corrections.txt"
        }
    }

    var label: String {
        switch self {
        case .dictionary: return "Dictionary"
        case .snippet: return "Snippets"
        case .correction: return "Corrections"
        }
    }
}

struct PersonalizationDraft: Codable, Equatable, Sendable {
    let kind: PersonalizationKind
    let primary: String
    let replacement: String?
}

struct PersonalizationEntry: Identifiable, Equatable, Sendable {
    let id: String
    let kind: PersonalizationKind
    let primary: String
    let replacement: String?
    let line: Int

    var draft: PersonalizationDraft {
        PersonalizationDraft(kind: kind, primary: primary, replacement: replacement)
    }
}

struct PersonalizationSnapshot: Sendable {
    let kind: PersonalizationKind
    let fingerprint: Data
    let entries: [PersonalizationEntry]
    let ignoredLineCount: Int
}

struct PersonalizationUndoToken: Sendable {
    let kind: PersonalizationKind
    fileprivate let before: Data
    fileprivate let beforeExisted: Bool
    fileprivate let expectedAfterFingerprint: Data
}

struct PersonalizationImportRow: Identifiable, Sendable {
    enum Outcome: String, Sendable { case addition = "New", duplicate = "Unchanged", conflict = "Conflict" }
    let id: Int
    let draft: PersonalizationDraft
    let outcome: Outcome
    let previous: String?
}

struct PersonalizationImportPreview: Sendable {
    let rows: [PersonalizationImportRow]
    let kind: PersonalizationKind
    let entries: [PersonalizationDraft]
    let addedCount: Int
    let duplicateCount: Int
    let conflictCount: Int
    let invalidCount: Int
    fileprivate let baseFingerprint: Data
}

enum PersonalizationUpsertResult: Sendable {
    case added(PersonalizationUndoToken)
    case replaced(PersonalizationUndoToken)
    case unchanged

    var undoToken: PersonalizationUndoToken? {
        switch self {
        case .added(let token), .replaced(let token): return token
        case .unchanged: return nil
        }
    }
}

enum PersonalizationError: Error, LocalizedError, Equatable {
    case invalid(String)
    case duplicate
    case conflict
    case stale
    case missing
    case tooLarge
    case tooMany
    case notUTF8
    case ambiguousImport

    var errorDescription: String? {
        switch self {
        case .invalid(let reason): return reason
        case .duplicate: return "That entry already exists."
        case .conflict: return "An entry with that trigger already has a different value."
        case .stale: return "The file changed outside FlowClone. Refresh and try again."
        case .missing: return "That entry no longer exists."
        case .tooLarge: return "The import is larger than 1 MiB."
        case .tooMany: return "The resulting personalization file would contain too many entries."
        case .notUTF8: return "The file is not valid UTF-8 text."
        case .ambiguousImport:
            return "The import contains one trigger with different values. Remove the conflicting duplicate and try again."
        }
    }
}

/// Owner-only file writes shared by the personalization and history stores: a 0700
/// directory, a 0600 temporary file, then an atomic rename over the destination. The
/// destination's parent directory is the root that gets created and hardened.
enum PrivateFile {
    static func ensureDirectory(_ root: URL) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700],
                                              ofItemAtPath: root.path)
    }

    static func write(_ data: Data, to url: URL) throws {
        let root = url.deletingLastPathComponent()
        try ensureDirectory(root)
        let temporary = root.appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        let manager = FileManager.default
        guard manager.createFile(atPath: temporary.path, contents: data,
                                 attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        var moved = false
        defer { if !moved { try? manager.removeItem(at: temporary) } }
        try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary.path)
        guard Darwin.rename(temporary.path, url.path) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        moved = true
    }
}

final class PersonalizationStore: @unchecked Sendable {
    static let shared = PersonalizationStore(
        root: FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/FlowClone", isDirectory: true)
    )

    private struct Line {
        var content: String
        var ending: String
    }

    private struct Document {
        let kind: PersonalizationKind
        let existed: Bool
        let original: Data
        var lines: [Line]
        let entries: [PersonalizationEntry]
        let ignored: Int

        var fingerprint: Data { PersonalizationStore.fingerprint(original, existed: existed) }
    }

    /// Exposed inside FlowCloneCore so read-only consumers can share this store's canonical
    /// parser while retaining their own mtime-based compiled caches.
    let root: URL
    private let lock = NSLock()
    private let maximumImportBytes = 1_048_576

    init(root: URL) { self.root = root }

    func snapshot(_ kind: PersonalizationKind) throws -> PersonalizationSnapshot {
        try locked {
            let document = try read(kind)
            return PersonalizationSnapshot(kind: kind, fingerprint: document.fingerprint,
                                           entries: document.entries,
                                           ignoredLineCount: document.ignored)
        }
    }

    @discardableResult
    func add(_ draft: PersonalizationDraft, expected: Data) throws -> PersonalizationUndoToken {
        try locked {
            let clean = try Self.validated(draft)
            var document = try read(clean.kind)
            try require(expected, matches: document)
            if let current = document.entries.first(where: { Self.key($0.primary) == Self.key(clean.primary) }) {
                if current.draft == clean { throw PersonalizationError.duplicate }
                throw PersonalizationError.conflict
            }
            try requireCapacity(document.entries.count + 1, kind: clean.kind)
            append(Self.encoded(clean), to: &document.lines, kind: clean.kind)
            return try writeMutation(document)
        }
    }

    /// Spoken correction commands are explicit user intent: add a new rule, replace the
    /// existing rule for that heard form, or report that the exact rule already exists.
    /// The entire read/decision/write is serialized and every mutation is undoable.
    func upsertCorrection(wrong: String, right: String) throws -> PersonalizationUpsertResult {
        try locked {
            let clean = try Self.validated(PersonalizationDraft(
                kind: .correction, primary: wrong, replacement: right
            ))
            var document = try read(.correction)
            if let current = document.entries.first(where: {
                Self.key($0.primary) == Self.key(clean.primary)
            }) {
                // Correction triggers are applied case-insensitively, so changing only the
                // spoken/left-side casing is not a semantic mutation. Replacement casing
                // remains significant (Catalyst and catalyst are different corrections).
                if current.replacement?.precomposedStringWithCanonicalMapping
                    == clean.replacement?.precomposedStringWithCanonicalMapping {
                    return .unchanged
                }
                document.lines[current.line].content = Self.encoded(clean)
                return .replaced(try writeMutation(document))
            }
            try requireCapacity(document.entries.count + 1, kind: .correction)
            append(Self.encoded(clean), to: &document.lines, kind: .correction)
            return .added(try writeMutation(document))
        }
    }

    /// Creates a first-run template without exposing a second non-atomic writer. Existing
    /// files, including an intentionally empty one, are untouched.
    func ensureTemplate(_ text: String, for kind: PersonalizationKind) throws {
        try locked {
            let url = root.appendingPathComponent(kind.filename)
            guard !FileManager.default.fileExists(atPath: url.path) else { return }
            try write(Data(text.utf8), to: url)
        }
    }

    func modificationDate(for kind: PersonalizationKind) -> Date? {
        let url = root.appendingPathComponent(kind.filename)
        return (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate
    }

    /// One-time/startup migration plus an idempotent repair after users manually replace a
    /// config file. These files can contain names and personal expansions, so they inherit
    /// neither a permissive umask nor legacy 0755/0644 modes.
    @discardableResult
    func hardenPermissions() -> Bool {
        locked {
            do {
                try ensureRoot()
                for kind in PersonalizationKind.allCases {
                    let url = root.appendingPathComponent(kind.filename)
                    if FileManager.default.fileExists(atPath: url.path) {
                        try FileManager.default.setAttributes([.posixPermissions: 0o600],
                                                              ofItemAtPath: url.path)
                    }
                }
                return true
            } catch {
                log("personalization permission migration failed: \(error)")
                return false
            }
        }
    }

    @discardableResult
    func update(id: String, to draft: PersonalizationDraft,
                expected: Data) throws -> PersonalizationUndoToken {
        try locked {
            let clean = try Self.validated(draft)
            var document = try read(clean.kind)
            try require(expected, matches: document)
            guard let entry = document.entries.first(where: { $0.id == id }) else {
                throw PersonalizationError.missing
            }
            if document.entries.contains(where: {
                $0.id != id && Self.key($0.primary) == Self.key(clean.primary)
            }) { throw PersonalizationError.conflict }
            document.lines[entry.line].content = Self.encoded(clean)
            return try writeMutation(document)
        }
    }

    @discardableResult
    func delete(ids: Set<String>, kind: PersonalizationKind,
                expected: Data) throws -> PersonalizationUndoToken {
        try locked {
            var document = try read(kind)
            try require(expected, matches: document)
            let indexes = Set(document.entries.filter { ids.contains($0.id) }.map(\.line))
            guard indexes.count == ids.count, !indexes.isEmpty else { throw PersonalizationError.missing }
            document.lines = document.lines.enumerated().compactMap { indexes.contains($0.offset) ? nil : $0.element }
            return try writeMutation(document)
        }
    }

    func previewImport(_ data: Data, kind: PersonalizationKind) throws -> PersonalizationImportPreview {
        try locked {
            guard data.count <= maximumImportBytes else { throw PersonalizationError.tooLarge }
            guard let text = String(data: data, encoding: .utf8) else { throw PersonalizationError.notUTF8 }
            let document = try read(kind)
            let imported = Self.splitLines(text)

            var ordered: [PersonalizationDraft] = []
            var position: [String: Int] = [:]
            var duplicates = 0
            var conflicts = 0
            var invalid = 0
            for line in imported {
                let trimmed = line.content.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { continue }
                guard let parsed = Self.parse(trimmed, kind: kind) else { invalid += 1; continue }
                let clean: PersonalizationDraft
                do { clean = try Self.validated(parsed) }
                catch { invalid += 1; continue }
                let k = Self.key(clean.primary)
                if let i = position[k] {
                    guard Self.sameMeaning(ordered[i], clean) else {
                        // There is no safe interpretation of two values for one trigger.
                        // Reject before creating a preview so the UI cannot offer to
                        // "replace" a rule that was already discarded here.
                        throw PersonalizationError.ambiguousImport
                    }
                    duplicates += 1
                    continue
                }
                position[k] = ordered.count
                ordered.append(clean)
            }

            var current: [String: PersonalizationDraft] = [:]
            for entry in document.entries where current[Self.key(entry.primary)] == nil {
                current[Self.key(entry.primary)] = entry.draft
            }
            var added = 0
            for entry in ordered {
                if let existing = current[Self.key(entry.primary)] {
                    if Self.sameMeaning(existing, entry) { duplicates += 1 }
                    else { conflicts += 1 }
                } else { added += 1 }
            }
            try requireCapacity(document.entries.count + added, kind: kind)
            let rows = ordered.enumerated().map { index, entry in
                let existing = current[Self.key(entry.primary)]
                let outcome: PersonalizationImportRow.Outcome = existing.map {
                    Self.sameMeaning($0, entry) ? .duplicate : .conflict
                } ?? .addition
                return PersonalizationImportRow(id: index, draft: entry, outcome: outcome,
                                                previous: existing?.replacement)
            }
            return PersonalizationImportPreview(
                rows: rows, kind: kind, entries: ordered, addedCount: added, duplicateCount: duplicates,
                conflictCount: conflicts, invalidCount: invalid,
                baseFingerprint: document.fingerprint
            )
        }
    }

    @discardableResult
    func apply(_ preview: PersonalizationImportPreview,
               replaceConflicts: Bool) throws -> PersonalizationUndoToken {
        try locked {
            var document = try read(preview.kind)
            try require(preview.baseFingerprint, matches: document)
            var byKey: [String: PersonalizationEntry] = [:]
            for entry in document.entries where byKey[Self.key(entry.primary)] == nil {
                byKey[Self.key(entry.primary)] = entry
            }
            for incoming in preview.entries {
                let k = Self.key(incoming.primary)
                if let existing = byKey[k] {
                    if !Self.sameMeaning(existing.draft, incoming), replaceConflicts {
                        document.lines[existing.line].content = Self.encoded(incoming)
                    }
                    continue
                }
                append(Self.encoded(incoming), to: &document.lines, kind: preview.kind)
                byKey[k] = PersonalizationEntry(id: "pending-\(byKey.count)", kind: preview.kind,
                                                primary: incoming.primary,
                                                replacement: incoming.replacement,
                                                line: document.lines.count - 1)
            }
            try requireCapacity(byKey.count, kind: preview.kind)
            return try writeMutation(document)
        }
    }

    func undo(_ token: PersonalizationUndoToken) throws {
        try locked {
            let current = try read(token.kind)
            guard current.fingerprint == token.expectedAfterFingerprint else {
                throw PersonalizationError.stale
            }
            let url = root.appendingPathComponent(token.kind.filename)
            if token.beforeExisted {
                try write(token.before, to: url)
            } else if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
        }
    }

    private func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    private func read(_ kind: PersonalizationKind) throws -> Document {
        let url = root.appendingPathComponent(kind.filename)
        let existed = FileManager.default.fileExists(atPath: url.path)
        let data = existed ? try Data(contentsOf: url) : Data()
        guard let text = String(data: data, encoding: .utf8) else { throw PersonalizationError.notUTF8 }
        let lines = Self.splitLines(text)
        var entries: [PersonalizationEntry] = []
        var ignored = 0
        for (index, line) in lines.enumerated() {
            let trimmed = line.content.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { continue }
            guard let draft = Self.parse(trimmed, kind: kind) else { ignored += 1; continue }
            let id = Self.entryID(kind: kind, content: line.content, line: index)
            entries.append(PersonalizationEntry(id: id, kind: kind, primary: draft.primary,
                                                replacement: draft.replacement, line: index))
        }
        return Document(kind: kind, existed: existed, original: data, lines: lines,
                        entries: entries, ignored: ignored)
    }

    private func require(_ expected: Data?, matches document: Document) throws {
        if let expected, expected != document.fingerprint { throw PersonalizationError.stale }
    }

    private func requireCapacity(_ count: Int, kind: PersonalizationKind) throws {
        let limit = kind == .dictionary ? 2_000 : 500
        if count > limit { throw PersonalizationError.tooMany }
    }

    private func append(_ content: String, to lines: inout [Line], kind: PersonalizationKind) {
        if lines.isEmpty, kind == .snippet {
            lines = [
                Line(content: "# FlowClone snippets — one per line:  trigger -> expansion", ending: "\n"),
                Line(content: "# Case-insensitive whole-phrase match. Use \\n for a line break.", ending: "\n"),
                Line(content: "", ending: "\n"),
            ]
        } else if let last = lines.indices.last, lines[last].ending.isEmpty {
            lines[last].ending = "\n"
        }
        lines.append(Line(content: content, ending: "\n"))
    }

    private func writeMutation(_ document: Document) throws -> PersonalizationUndoToken {
        // Detect an editor or older FlowClone path that changed the bytes after this
        // mutation read them. This check is deliberately adjacent to the atomic rename.
        let current = try read(document.kind)
        guard current.fingerprint == document.fingerprint else { throw PersonalizationError.stale }
        let data = Data(Self.render(document.lines).utf8)
        let url = root.appendingPathComponent(document.kind.filename)
        try write(data, to: url)
        return PersonalizationUndoToken(
            kind: document.kind, before: document.original, beforeExisted: document.existed,
            expectedAfterFingerprint: Self.fingerprint(data, existed: true)
        )
    }

    private func write(_ data: Data, to url: URL) throws {
        try PrivateFile.write(data, to: url)
    }

    private func ensureRoot() throws {
        try PrivateFile.ensureDirectory(root)
    }

    private static func parse(_ line: String, kind: PersonalizationKind) -> PersonalizationDraft? {
        if kind == .dictionary {
            return PersonalizationDraft(kind: kind, primary: line, replacement: nil)
        }
        let delimiter = line.range(of: " -> ") ?? line.range(of: "->")
        guard let delimiter else { return nil }
        let primary = line[..<delimiter.lowerBound].trimmingCharacters(in: .whitespaces)
        var replacement = line[delimiter.upperBound...].trimmingCharacters(in: .whitespaces)
        if kind == .snippet { replacement = replacement.replacingOccurrences(of: "\\n", with: "\n") }
        guard !primary.isEmpty, !primary.contains("->"), !replacement.isEmpty else { return nil }
        return PersonalizationDraft(kind: kind, primary: primary, replacement: replacement)
    }

    static func validated(_ draft: PersonalizationDraft) throws -> PersonalizationDraft {
        let rawPrimary = draft.primary.precomposedStringWithCanonicalMapping
        guard !containsNewline(rawPrimary) else {
            throw PersonalizationError.invalid("The term or trigger must be one line of text.")
        }
        let primary = rawPrimary.trimmingCharacters(in: .whitespacesAndNewlines)
        var rawReplacement = draft.replacement?.precomposedStringWithCanonicalMapping
        if draft.kind == .snippet, let value = rawReplacement {
            rawReplacement = normalizedNewlines(value)
        }
        var replacement = rawReplacement?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !primary.isEmpty, !primary.hasPrefix("#") else {
            throw PersonalizationError.invalid("The term or trigger cannot be empty or begin with #.")
        }
        guard !primary.contains("->") else {
            throw PersonalizationError.invalid("The term or trigger cannot contain ->.")
        }
        guard !containsControl(primary, allowNewlines: false) else {
            throw PersonalizationError.invalid("The term or trigger must be one line of text.")
        }

        switch draft.kind {
        case .dictionary:
            guard primary.count <= 100,
                  primary.split(whereSeparator: \.isWhitespace).count <= 6 else {
                throw PersonalizationError.invalid("Dictionary terms are limited to 100 characters and six words.")
            }
            replacement = nil
        case .snippet:
            if replacement?.contains("\\n") == true {
                throw PersonalizationError.invalid("Literal \\n is reserved for line breaks. Press Return to insert a new line.")
            }
            guard primary.count <= 60 else {
                throw PersonalizationError.invalid("Snippet triggers are limited to 60 characters.")
            }
            guard let value = replacement, !value.isEmpty, value.count <= 4_000,
                  !containsControl(value, allowNewlines: true) else {
                throw PersonalizationError.invalid("Snippet expansions must be 1–4,000 printable characters.")
            }
        case .correction:
            guard primary.count <= 120, let value = replacement, !value.isEmpty,
                  value.count <= 120,
                  !containsNewline(value),
                  !containsControl(value, allowNewlines: false) else {
                throw PersonalizationError.invalid("Correction sides must be one line and at most 120 characters.")
            }
        }
        return PersonalizationDraft(kind: draft.kind, primary: primary, replacement: replacement)
    }

    private static func containsControl(_ text: String, allowNewlines: Bool) -> Bool {
        text.unicodeScalars.contains { scalar in
            guard CharacterSet.controlCharacters.contains(scalar) else { return false }
            return !allowNewlines || (scalar.value != 0x0A && scalar.value != 0x0D)
        }
    }

    private static func containsNewline(_ text: String) -> Bool {
        text.contains(where: \.isNewline)
    }

    /// Cleaner treats every Unicode newline as a record boundary. Snippet bodies are
    /// the sole multiline value, so canonicalize every newline grapheme to LF before
    /// escaping it into the line-oriented storage format.
    private static func normalizedNewlines(_ text: String) -> String {
        var result = ""
        result.reserveCapacity(text.utf8.count)
        for character in text {
            result.append(character.isNewline ? "\n" : character)
        }
        return result
    }

    private static func encoded(_ draft: PersonalizationDraft) -> String {
        switch draft.kind {
        case .dictionary: return draft.primary
        case .correction: return "\(draft.primary) -> \(draft.replacement ?? "")"
        case .snippet:
            let replacement = normalizedNewlines(draft.replacement ?? "")
                .replacingOccurrences(of: "\n", with: "\\n")
            return "\(draft.primary) -> \(replacement)"
        }
    }

    private static func splitLines(_ text: String) -> [Line] {
        guard !text.isEmpty else { return [] }
        var lines: [Line] = []
        var start = text.startIndex
        while start < text.endIndex {
            if let newline = text[start...].firstIndex(of: "\n") {
                var content = String(text[start..<newline])
                var ending = "\n"
                if content.last == "\r" { content.removeLast(); ending = "\r\n" }
                lines.append(Line(content: content, ending: ending))
                start = text.index(after: newline)
            } else {
                lines.append(Line(content: String(text[start...]), ending: ""))
                break
            }
        }
        return lines
    }

    private static func render(_ lines: [Line]) -> String {
        lines.map { $0.content + $0.ending }.joined()
    }

    private static func key(_ text: String) -> String {
        text.precomposedStringWithCanonicalMapping.lowercased()
    }

    /// Dictionary spelling/casing is the replacement itself and therefore significant.
    /// Snippet/correction triggers are matched case-insensitively; only their value changes
    /// meaning once the normalized trigger key is equal.
    private static func sameMeaning(_ lhs: PersonalizationDraft,
                                    _ rhs: PersonalizationDraft) -> Bool {
        guard lhs.kind == rhs.kind, key(lhs.primary) == key(rhs.primary) else { return false }
        switch lhs.kind {
        case .dictionary: return lhs.primary == rhs.primary
        case .snippet, .correction: return lhs.replacement == rhs.replacement
        }
    }

    private static func fingerprint(_ data: Data, existed: Bool) -> Data {
        var tagged = Data([existed ? 1 : 0])
        tagged.append(data)
        return Data(SHA256.hash(data: tagged))
    }

    private static func entryID(kind: PersonalizationKind, content: String, line: Int) -> String {
        let data = Data("\(kind.rawValue)\u{0}\(line)\u{0}\(content)".utf8)
        return SHA256.hash(data: data).prefix(10).map { String(format: "%02x", $0) }.joined()
    }
}
