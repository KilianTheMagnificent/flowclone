import Foundation
import AVFoundation

/// Separate from dictation history; atomic private files, no transcript text in logs.
@MainActor final class MeetingStore {
    let root: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private var securedDirectories: Set<UUID> = []
    private var rootSecured = false

    init(root: URL) { self.root = root }
    func directory(_ id: UUID) -> URL { root.appendingPathComponent(id.uuidString, isDirectory: true) }
    func save(_ note: MeetingNote) throws {
        let directory = directory(note.id)
        let fm = FileManager.default
        if !securedDirectories.contains(note.id) || !fm.fileExists(atPath: directory.path) {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true,
                                   attributes: [.posixPermissions: 0o700])
            if !rootSecured {
                try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
                rootSecured = true
            }
            securedDirectories.insert(note.id)
        }
        let noteURL = directory.appendingPathComponent("note.json")
        try encoder.encode(note).write(to: noteURL, options: [.atomic, .completeFileProtectionUnlessOpen])
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: noteURL.path)
    }
    func load() throws -> [MeetingNote] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: root.path) else { return [] }
        return try fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .filter { UUID(uuidString: $0.lastPathComponent) != nil }
            // One unreadable note must not stop every later meeting from being recorded.
            .compactMap { url -> MeetingNote? in
                guard var note = try? decoder.decode(MeetingNote.self, from: Data(contentsOf: url.appendingPathComponent("note.json"))) else {
                    return nil
                }
                note.segments = note.orderedSegments
                return note
            }
            .sorted { $0.startedAt > $1.startedAt }
    }
    func remove(_ id: UUID) throws {
        securedDirectories.remove(id)
        try FileManager.default.removeItem(at: directory(id))
    }
    /// Reconcile files written just before a crash, including a partially filled last segment.
    func recoveredSegments(for note: MeetingNote) throws -> [MeetingSegment] {
        var segments = note.segments
        for url in try FileManager.default.contentsOfDirectory(at: directory(note.id), includingPropertiesForKeys: nil) where url.pathExtension == "wav" {
            guard !segments.contains(where: { $0.audioFile == url.lastPathComponent }) else { continue }
            let parts = url.deletingPathExtension().lastPathComponent.split(separator: "-")
            guard parts.count == 2, let source = MeetingSource(rawValue: String(parts[0])), let offset = Double(parts[1]) else { continue }
            // A file cut off mid-write by a crash still says "no audio" in its header; give it
            // the length on disk first. One that still does not open or holds nothing is
            // skipped, and the rest is still recovered.
            Self.repairUnclosedWAV(at: url)
            guard let file = try? AVAudioFile(forReading: url), file.length > 0 else { continue }
            segments.append(MeetingSegment(audioFile: url.lastPathComponent, source: source, offset: offset / 1000,
                                           duration: Double(file.length) / file.processingFormat.sampleRate))
        }
        return segments.sorted { $0.offset < $1.offset }
    }
    /// AVAudioFile writes a WAV's RIFF and data sizes only when the file is closed, so after a
    /// crash, force-quit or power loss the header still says 0 bytes of audio although the
    /// samples are on disk. Rewrites both sizes from the file size, rounded down to whole
    /// frames (a crash can cut the last one). Leaves alone any file that is not a WAV, whose
    /// data size is already plausible, or that holds no whole frame. Returns whether it wrote.
    @discardableResult
    nonisolated static func repairUnclosedWAV(at url: URL) -> Bool {
        guard let handle = try? FileHandle(forUpdating: url) else { return false }
        defer { try? handle.close() }
        guard let end = try? handle.seekToEnd(), end <= UInt64(UInt32.max),
              (try? handle.seek(toOffset: 0)) != nil,
              let head = try? handle.read(upToCount: 64 * 1024) else { return false }
        let bytes = [UInt8](head)
        let size = Int(end)
        func u32(_ at: Int) -> Int { (0..<4).reduce(0) { $0 | Int(bytes[at + $1]) << (8 * $1) } }
        func id(_ at: Int, _ name: String) -> Bool { bytes[at..<(at + 4)].elementsEqual(name.utf8) }
        guard bytes.count >= 12, id(0, "RIFF"), id(8, "WAVE") else { return false }
        var at = 12
        var blockAlign = 0
        while at + 8 <= bytes.count {
            let declared = u32(at + 4)
            if id(at, "fmt ") {
                guard at + 8 + 14 <= bytes.count else { return false }
                blockAlign = Int(bytes[at + 20]) | Int(bytes[at + 21]) << 8
            } else if id(at, "data") {
                let start = at + 8
                let available = size - start
                guard blockAlign > 0, available > 0, declared == 0 || declared > available else { return false }
                let audio = available - available % blockAlign
                guard audio > 0 else { return false }
                func le(_ value: Int) -> Data { Data((0..<4).map { UInt8(truncatingIfNeeded: value >> (8 * $0)) }) }
                do {
                    try handle.seek(toOffset: UInt64(at + 4)); try handle.write(contentsOf: le(audio))
                    try handle.seek(toOffset: 4); try handle.write(contentsOf: le(start + audio - 8))
                    return true
                } catch { return false }
            }
            at += 8 + declared + declared % 2
        }
        return false
    }
}
