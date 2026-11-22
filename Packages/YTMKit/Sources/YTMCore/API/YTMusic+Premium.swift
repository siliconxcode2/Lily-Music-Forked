import Foundation

public enum PremiumOutcome: Sendable {
    /// A Premium stream, or with `anyFormat` the best the web client has.
    case stream(ResolvedStream)
    /// Music videos and uploads often have none, so this says nothing about
    /// the account on its own.
    case noPremiumFormats
}

extension YTMusic {
    /// The Premium path (signed in, High): 774/141 via the web clients and the JavaScriptCore solver.
    /// `anyFormat` takes the web client's best when it has no Premium format.
    /// `maxKbps` caps that best, for the last resort at Low and Normal quality; a cap rules out Premium formats.
    @concurrent
    public func premiumStream(videoId: String, anyFormat: Bool, maxKbps: Int? = nil) async throws -> PremiumOutcome {
        let player: PlayerScript
        do {
            player = try await PlayerScripts.shared.player(store: store)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // `PlayerScripts` has logged the real reason already.
            throw YTMError.playerUnprepared
        }
        return try await PremiumResolver(innerTube: innerTube, player: player).resolve(
            videoId: videoId, signedIn: auth.isSignedIn, anyFormat: anyFormat, maxKbps: maxKbps
        )
    }

    /// A Premium stream failed, so the held player script is checked against YouTube's sooner.
    public func suspectPremiumPlayer() async {
        await PlayerScripts.shared.suspect()
    }

    /// So the first song doesn't wait for the player script. A failure is left
    /// for the song to meet, after the script's own back-off.
    @concurrent
    public func preparePremium() async {
        _ = try? await PlayerScripts.shared.player(store: store)
    }
}

extension YTMError {
    /// Says nothing about the account, so the player doesn't count it as a
    /// Premium failure.
    public static let playerUnprepared = YTMError(.unplayable, "YouTube's player couldn't be prepared; trying again in a few minutes.")
}
