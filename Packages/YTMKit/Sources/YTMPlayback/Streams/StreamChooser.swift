import Foundation
import os
import Synchronization
import YTMCore

public enum PremiumStatus: Sendable {
    case unknown, premium, notPremium

    public var summary: String {
        switch self {
        case .premium: "Active: playing 256 kbps Premium streams."
        case .notPremium: "This account has no Premium; playing standard streams."
        case .unknown: "When signed in with YouTube Premium, plays 256 kbps Opus."
        }
    }
}

struct PremiumCounters {
    /// Songs in a row without Premium formats before an unknown account counts
    /// as without it, as some songs simply have no Premium version.
    static let notPremiumAfter = 3
    /// The same for a known Premium account: only a long run of uploads
    /// reaches it, and a lapsed subscription soon does.
    static let lapsedAfter = 20
    /// Cool-off after Premium keeps failing, and between background checks
    /// of an account taken as without Premium.
    static let backoff = Duration.seconds(10 * 60)
    static let maxErrors = 3

    private(set) var status: PremiumStatus
    /// Songs in a row that offered no Premium formats.
    private var misses = 0
    /// Premium requests in a row that failed outright.
    private var errors = 0
    private var pausedUntil: ContinuousClock.Instant?
    /// A run of music videos, which never have Premium formats, can mistake a
    /// Premium account for one, hence the recheck. Unset: checked on the first song.
    var recheckAt: ContinuousClock.Instant?

    /// `known` says the account has been served Premium formats before, and
    /// `none` that it was last taken as without Premium.
    init(known: Bool, none: Bool) {
        status = known ? .premium : none ? .notPremium : .unknown
    }

    /// Whether to go straight to the free stream.
    func skipped(at now: ContinuousClock.Instant) -> Bool {
        status == .notPremium || pausedUntil.map { now < $0 } == true
    }

    /// Claims the background check when due, so only one runs.
    mutating func takeRecheck(at now: ContinuousClock.Instant) -> Bool {
        guard status == .notPremium, recheckAt.map({ now >= $0 }) ?? true else { return false }
        recheckAt = now + Self.backoff
        return true
    }

    mutating func recordPremium() {
        status = .premium
        misses = 0
        errors = 0
    }

    mutating func recordMiss(at now: ContinuousClock.Instant) {
        misses += 1
        if misses >= (status == .premium ? Self.lapsedAfter : Self.notPremiumAfter) {
            status = .notPremium
            recheckAt = now + Self.backoff
        }
    }

    /// Returns whether this error started a cool-off.
    mutating func recordError(at now: ContinuousClock.Instant) -> Bool {
        errors += 1
        guard errors >= Self.maxErrors else { return false }
        errors = 0
        pausedUntil = now + Self.backoff
        return true
    }
}

/// Chooses between the Premium and the free stream for a song. Safe to call
/// from anywhere: the counters' lock is never held across an await.
final class StreamChooser: Sendable {
    private let music: any MusicService
    private let counters = Mutex(PremiumCounters(known: false, none: false))

    init(music: any MusicService) {
        self.music = music
    }

    var status: PremiumStatus { counters.withLock(\.status) }

    func seed(known: Bool, none: Bool) {
        counters.withLock { $0 = PremiumCounters(known: known, none: none) }
    }

    func reset() {
        seed(known: false, none: false)
    }

    /// `wantPremium` means signed in at High quality. Downloads pass `counting` false: a
    /// playlist of music videos, which have no Premium formats, says nothing of the account.
    /// With `reopening`, a song opened again after a drop, its failures say nothing of Premium either.
    @concurrent
    func resolve(
        videoId: String, wantPremium: Bool, signedIn: Bool, quality: AudioQuality, counting: Bool = true, reopening: Bool = false
    ) async throws -> ResolvedStream {
        if wantPremium {
            if !counters.withLock({ $0.skipped(at: .now) }) {
                if let stream = try await premium(videoId, counting: counting, reopening: reopening) { return stream }
            } else if counting, counters.withLock({ $0.takeRecheck(at: .now) }) {
                // Checked off the playback path: this song plays the free
                // stream at once, and the next one gets Premium if it is back.
                Task { [self] in await recheck(videoId) }
            }
        }
        return try await free(videoId, signedIn: signedIn, quality: quality)
    }

    /// Asks the path that gave the stream, so it comes back as the same file: a free stream, web-client
    /// ones too, is asked of the plain-URL clients in format `itag`, so one googlevideo refuses still
    /// plays. `cutOff` names the client whose fresh URL was refused too, asked last from now on.
    /// Counts nothing towards the Premium counters, as the song already counted when first resolved,
    /// but has the player checked sooner.
    @concurrent
    func refresh(
        videoId: String, wasPremium: Bool, itag: Int, cutOff: String?, signedIn: Bool, quality: AudioQuality
    ) async throws -> ResolvedStream {
        Logger.playback.info("\(videoId, privacy: .public): stream refused partway; asking for a fresh URL")
        if let cutOff { music.cutOffStreams(of: cutOff) }
        guard wasPremium else { return try await free(videoId, signedIn: signedIn, quality: quality, itag: itag) }
        await music.suspectPremiumPlayer()
        guard signedIn, case .stream(let stream) = try await music.premiumStream(videoId: videoId, anyFormat: false, maxKbps: nil) else {
            throw YTMError(.unplayable, "The Premium stream couldn't be had again.")
        }
        return stream
    }

    /// Nil to play the free stream. A known Premium account takes any format
    /// from the same answer, which saves asking the free clients.
    private func premium(_ videoId: String, counting: Bool, reopening: Bool) async throws -> ResolvedStream? {
        let known = status == .premium
        do {
            switch try await music.premiumStream(videoId: videoId, anyFormat: known, maxKbps: nil) {
            case .stream(let stream):
                if counting { counters.withLock { stream.isPremium ? $0.recordPremium() : $0.recordMiss(at: .now) } }
                return stream
            case .noPremiumFormats:
                if counting { counters.withLock { $0.recordMiss(at: .now) } }
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as YTMError where error == .playerUnprepared {
            // Not the account's fault, so not counted.
            Logger.playback.info("\(videoId, privacy: .public): could not prepare the player; using the free stream")
        } catch {
            Logger.playback.info("\(videoId, privacy: .public): Premium path failed, using the free stream: \(sentence(for: error), privacy: .public)")
            if counting, !reopening {
                await music.suspectPremiumPlayer()
                if counters.withLock({ $0.recordError(at: .now) }) {
                    Logger.playback.info("Premium requests keep failing; using free streams for 10 minutes")
                }
            }
        }
        return nil
    }

    private func recheck(_ videoId: String) async {
        do {
            switch try await music.premiumStream(videoId: videoId, anyFormat: false, maxKbps: nil) {
            case .stream: counters.withLock { $0.recordPremium() }
            case .noPremiumFormats: counters.withLock { $0.recordMiss(at: .now) }
            }
        } catch {
            Logger.playback.info("\(videoId, privacy: .public): Premium check failed: \(sentence(for: error), privacy: .public)")
        }
    }

    /// YTMCore retries a bot-checked visitor ID itself. Signed in, falls back to
    /// the web client's scrambled URLs through the Premium solver, Premium or not.
    /// `itag` holds the plain-URL clients to that format, but not the web client.
    private func free(_ videoId: String, signedIn: Bool, quality: AudioQuality, itag: Int? = nil) async throws -> ResolvedStream {
        do {
            return try await music.stream(videoId: videoId, quality: quality, itag: itag)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            guard signedIn else { throw error }
            do {
                if case .stream(let stream) = try await music.premiumStream(videoId: videoId, anyFormat: true, maxKbps: quality.maxKbps) {
                    Logger.playback.info("\(videoId, privacy: .public): no client gave a plain URL; playing through the web client")
                    return stream
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                Logger.playback.debug("\(videoId, privacy: .public): web client fallback failed: \(sentence(for: error), privacy: .public)")
            }
            throw error
        }
    }
}
