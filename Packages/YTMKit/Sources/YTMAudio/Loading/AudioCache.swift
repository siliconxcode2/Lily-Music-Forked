import Foundation

/// Downloads go to `.part` files that count only once complete; past the size
/// cap the least recently played files go first.
final class AudioCache {
    /// Where the cache lives and how large it may grow, in bytes.
    struct Location: Sendable {
        let directory: URL
        let limit: Int64
    }

    let directory: URL
    let limit: Int64
    private let files = FileManager.default
    /// Loaders on each file name, as the same song can play twice at once.
    private var reading: [String: Int] = [:]
    private static let partExtension = "part"

    /// Works on the disk, so it is made on the engine's queue. Trims to the cap,
    /// which may have shrunk since the last launch.
    init(_ location: Location) {
        directory = location.directory
        limit = location.limit
        try? files.createDirectory(at: directory, withIntermediateDirectories: true)
        for url in contents() where url.pathExtension == Self.partExtension {
            try? files.removeItem(at: url)
        }
        evict()
    }

    static var defaultDirectory: URL {
        URL.cachesDirectory.appending(path: "audio", directoryHint: .isDirectory)
    }

    /// Whether `url` holds a whole copy: there, and of the expected length, as a file
    /// of another length is another encode.
    static func isWhole(_ url: URL, length: Int64) -> Bool {
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize else { return false }
        return size > 0 && (length <= 0 || Int64(size) == length)
    }

    /// The complete file for `key`, marked as just played.
    func completeFile(for key: String, length: Int64) -> URL? {
        let url = file(for: key)
        guard Self.isWhole(url, length: length) else { return nil }
        try? files.setAttributes([.modificationDate: Date.now], ofItemAtPath: url.path(percentEncoded: false))
        return url
    }

    /// Each download has its own part, so the same song playing twice at once never shares one.
    func makePart(for key: String) throws -> URL {
        let url = partURL(for: key)
        guard files.createFile(atPath: url.path(percentEncoded: false), contents: nil) else {
            throw AudioFailure.storage
        }
        return url
    }

    func commit(_ part: URL, as key: String) {
        let url = file(for: key)
        // rename(2) replaces any older file atomically, and readers of the
        // part keep reading, as their descriptors follow the file.
        guard rename(part.path(percentEncoded: false), url.path(percentEncoded: false)) == 0 else {
            discard(part)
            return
        }
        evict(sparing: url.lastPathComponent)
    }

    func discard(_ part: URL) {
        try? files.removeItem(at: part)
    }

    /// APFS clones the copy, so it takes no time.
    func adopt(_ file: URL, as key: String) -> Bool {
        let part = partURL(for: key)
        guard (try? files.copyItem(at: file, to: part)) != nil else { return false }
        commit(part, as: key)
        return true
    }

    /// The bytes of complete files.
    func size() -> Int64 {
        completeFiles().reduce(0) { $0 + $1.size }
    }

    /// Removes every complete file. Downloads under way carry on, and files
    /// still being read stay readable until closed.
    func clear() {
        removeAll(except: [])
    }

    func remove(_ key: String) {
        try? files.removeItem(at: file(for: key))
    }

    /// Parts under way are left to finish.
    func removeAll(except keys: Set<String>) {
        let kept = Set(keys.map(Self.safeName))
        for entry in completeFiles() where !kept.contains(entry.url.lastPathComponent) {
            try? files.removeItem(at: entry.url)
        }
    }

    /// A file being read stays past the cap, so a mix over it is not fetched again on a replay.
    func hold(_ key: String) {
        reading[Self.safeName(key), default: 0] += 1
    }

    func release(_ key: String) {
        let name = Self.safeName(key)
        if let count = reading[name] { reading[name] = count > 1 ? count - 1 : nil }
    }

    /// By name, as the listing's URLs start /private/var where a built one has /var.
    private func evict(sparing kept: String? = nil) {
        guard limit < .max else { return }
        let entries = completeFiles().sorted { $0.used < $1.used }
        var total = entries.reduce(0) { $0 + $1.size }
        for entry in entries where total > limit {
            let name = entry.url.lastPathComponent
            guard name != kept, reading[name] == nil else { continue }
            try? files.removeItem(at: entry.url)
            total -= entry.size
        }
    }

    private func file(for key: String) -> URL {
        directory.appending(path: Self.safeName(key))
    }

    private func partURL(for key: String) -> URL {
        directory.appending(path: "\(Self.safeName(key)).\(UUID().uuidString).\(Self.partExtension)")
    }

    private func contents(keys: [URLResourceKey] = []) -> [URL] {
        (try? files.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys)) ?? []
    }

    private func completeFiles() -> [(url: URL, size: Int64, used: Date)] {
        let keys: Set<URLResourceKey> = [.fileSizeKey, .contentModificationDateKey]
        return contents(keys: Array(keys)).compactMap { url in
            guard url.pathExtension != Self.partExtension, let values = try? url.resourceValues(forKeys: keys),
                  let size = values.fileSize else { return nil }
            return (url, Int64(size), values.contentModificationDate ?? .distantPast)
        }
    }

    /// Keys are video IDs and itags, but nothing from outside names a path unchecked.
    static func safeName(_ key: String) -> String {
        String(key.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_" ? Character($0) : "_" })
    }
}
