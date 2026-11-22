import Foundation
import os
import YTMCore

extension Logger {
    /// Never cookies or stream URLs.
    static let playback = Logger(subsystem: "Lily", category: "Playback")
}

extension Result where Failure == any Error {
    /// `init(catching:)` for async work.
    init(_ body: @Sendable () async throws -> Success) async {
        do {
            self = .success(try await body())
        } catch {
            self = .failure(error)
        }
    }
}
