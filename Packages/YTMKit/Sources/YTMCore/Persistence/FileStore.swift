import Foundation
import os
import Synchronization

public enum StoreFile: String, Sendable {
    case settings, session, history, searches, home, scrobbles, visitor
    /// The Premium path's trimmed player script.
    case player
    case downloads
    /// Library as it last loaded, for the account signed in.
    case library
}

/// JSON files in Application Support/Lily/. Writes run in order on one
/// serial queue, atomically, and one overtaken by a newer save is skipped.
public final class FileStore: Sendable {
    public static let shared = FileStore(
        directory: URL.applicationSupportDirectory.appending(path: "Lily", directoryHint: .isDirectory)
    )

    private let directory: URL
    private let queue = DispatchQueue(label: "Lily.FileStore", qos: .utility)
    /// The newest save ticket per file, so older ones queued behind it are skipped.
    private let latest = Mutex<[StoreFile: UInt64]>([:])
    private static let log = Logger(subsystem: "Lily", category: "FileStore")

    /// `directory` is created on the first save.
    init(directory: URL) {
        self.directory = directory
    }

    /// Downloaded songs and their artwork, apart from the JSON files.
    public var downloads: URL {
        directory.appending(path: "Downloads", directoryHint: .isDirectory)
    }

    private func url(_ file: StoreFile) -> URL {
        directory.appending(path: file.rawValue + ".json", directoryHint: .notDirectory)
    }

    /// Waits for saves already queued, so it reads the latest; call it off the main actor.
    public func load<T: Decodable>(_ type: T.Type, from file: StoreFile) -> T? {
        let url = url(file)
        guard let data = queue.sync(execute: { try? Data(contentsOf: url) }) else { return nil }
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            Self.log.error("\(file.rawValue, privacy: .public).json could not be read: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// Writes off the caller's thread; of several saves of one file, the last asked for wins.
    public func save<T: Encodable & Sendable>(_ value: T, to file: StoreFile) {
        let ticket = nextTicket(for: file)
        let url = url(file)
        queue.async { [directory] in
            guard self.isLatest(ticket, for: file) else { return }
            do {
                let data = try Self.encoder.encode(value)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try data.write(to: url, options: .atomic)
            } catch {
                Self.log.error("\(file.rawValue, privacy: .public).json could not be saved: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Deletes the file after any saves already queued, which it overtakes.
    public func remove(_ file: StoreFile) {
        _ = nextTicket(for: file)
        let url = url(file)
        queue.async { try? FileManager.default.removeItem(at: url) }
    }

    private func nextTicket(for file: StoreFile) -> UInt64 {
        latest.withLock { tickets in
            let ticket = tickets[file, default: 0] + 1
            tickets[file] = ticket
            return ticket
        }
    }

    private func isLatest(_ ticket: UInt64, for file: StoreFile) -> Bool {
        latest.withLock { $0[file] == ticket }
    }

    /// Shared, and only used on `queue`, one encode at a time.
    private static let encoder = JSONEncoder()
}
