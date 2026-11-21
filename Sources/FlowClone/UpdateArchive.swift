import Foundation

/// Validate the bounded ZIP directory before invoking ditto. Signed bundle validation
/// happens after extraction; it cannot protect against traversal or disk exhaustion
/// during extraction. Our small, flat app archives do not need ZIP64, links, or encryption.
enum UpdateArchive {
    static let maximumExpandedBytes = 512 * 1_024 * 1_024

    static func validate(_ url: URL) throws {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let size = try handle.seekToEnd()
        guard size >= 22, size <= UInt64(Updater.maximumDownloadBytes) else { throw invalid() }
        func read(_ offset: UInt64, _ count: Int) throws -> Data {
            guard offset <= size, count >= 0, UInt64(count) <= size - offset else { throw invalid() }
            try handle.seek(toOffset: offset)
            guard let bytes = try handle.read(upToCount: count), bytes.count == count else { throw invalid() }
            return bytes
        }
        let tailOffset = size - min(size, 65_557)
        let tail = try read(tailOffset, Int(size - tailOffset))
        var end: Int?
        for i in stride(from: tail.count - 22, through: 0, by: -1) {
            if u32(tail, i) == 0x06054b50, i + 22 + u16(tail, i + 20) == tail.count {
                end = i
                break
            }
        }
        guard let end, u16(tail, end + 4) == 0, u16(tail, end + 6) == 0 else { throw invalid() }
        let count = u16(tail, end + 10)
        let directorySize = u32(tail, end + 12)
        let directoryOffset = u32(tail, end + 16)
        guard (1...10_000).contains(count), u16(tail, end + 8) == count,
              directorySize <= 16 * 1_024 * 1_024,
              UInt64(directoryOffset) + UInt64(directorySize) == tailOffset + UInt64(end) else { throw invalid() }
        let directory = try read(UInt64(directoryOffset), directorySize)
        var cursor = 0
        var expanded = 0
        var names = Set<String>()
        for _ in 0..<count {
            guard cursor + 46 <= directory.count, u32(directory, cursor) == 0x02014b50 else { throw invalid() }
            let flags = u16(directory, cursor + 8)
            let method = u16(directory, cursor + 10)
            let compressed = u32(directory, cursor + 20)
            let unpacked = u32(directory, cursor + 24)
            let nameLength = u16(directory, cursor + 28)
            let extraLength = u16(directory, cursor + 30)
            let commentLength = u16(directory, cursor + 32)
            let mode = (u32(directory, cursor + 38) >> 16) & 0o170000
            let localOffset = u32(directory, cursor + 42)
            let next = cursor + 46 + nameLength + extraLength + commentLength
            guard flags & 1 == 0, method == 0 || method == 8,
                  mode == 0 || mode == 0o040000 || mode == 0o100000,
                  u16(directory, cursor + 34) == 0,
                  nameLength > 0, next <= directory.count else { throw invalid() }
            let nameData = directory.subdata(in: (cursor + 46)..<(cursor + 46 + nameLength))
            guard let name = String(data: nameData, encoding: .utf8), safePath(name),
                  names.insert(name.precomposedStringWithCanonicalMapping.lowercased()).inserted else { throw invalid() }
            expanded += unpacked
            guard expanded <= maximumExpandedBytes else { throw invalid() }
            let local = try read(UInt64(localOffset), 30)
            guard u32(local, 0) == 0x04034b50, u16(local, 6) == flags,
                  u16(local, 8) == method, u16(local, 26) == nameLength else { throw invalid() }
            let bodyOffset = UInt64(localOffset) + 30 + UInt64(nameLength + u16(local, 28))
            guard bodyOffset + UInt64(compressed) <= UInt64(directoryOffset),
                  try read(UInt64(localOffset) + 30, nameLength) == nameData else { throw invalid() }
            cursor = next
        }
        guard cursor == directory.count else { throw invalid() }
    }

    static func safePath(_ path: String) -> Bool {
        guard !path.hasPrefix("/"), !path.contains("\\"),
              !path.unicodeScalars.contains(where: { $0.value < 32 }) else { return false }
        let trimmed = path.hasSuffix("/") ? String(path.dropLast()) : path
        return !trimmed.isEmpty && trimmed.split(separator: "/", omittingEmptySubsequences: false)
            .allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }

    private static func u16(_ data: Data, _ offset: Int) -> Int {
        Int(data[offset]) | (Int(data[offset + 1]) << 8)
    }

    private static func u32(_ data: Data, _ offset: Int) -> Int {
        u16(data, offset) | (u16(data, offset + 2) << 16)
    }

    private static func invalid() -> Updater.UpdateError {
        Updater.UpdateError("unsafe, oversized, or unsupported update archive")
    }
}
