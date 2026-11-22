import Foundation
import os
import YTMCore

extension PlayerController {
    /// Rates `track` (nil for the one playing), or takes the rating back if the
    /// playing song already had it. Disliking the playing song skips it. Signed in only.
    public func rate(_ rating: Rating, track: Track? = nil) {
        guard let track = track ?? current else { return }
        let id = track.id
        let playing = id == current?.id
        let before = playing ? self.rating : .none
        let rating = rating == before ? .none : rating
        if playing {
            ratingGeneration += 1
            self.rating = rating
            if rating == .dislike {
                next()
                // Nothing to skip to: the queue's end, or a repeat of it.
                if current?.id == id { stop() }
            }
        }
        let music = music
        Task { [weak self] in
            let result = await Result { try await music.rate(videoId: id, rating) }
            guard let self else { return }
            switch result {
            case .success:
                libraryRevision += 1
                downloads.rated(track, rating)
                let message = switch (rating, before) {
                case (.like, _): "Added to your liked songs"
                case (.dislike, _): "Disliked"
                case (.none, .dislike): "Dislike removed"
                case (.none, .none): "Rating removed"
                case (.none, .like): "Removed from your liked songs"
                }
                say(message)
            case .failure(let error):
                // Undone on the player, unless it has moved on.
                if current?.id == id, self.rating == rating { self.rating = before }
                say("Couldn't rate the song: \(sentence(for: error))")
            }
        }
    }

    /// Only a new song, not one shown again as on repeat or a retry, reloads its
    /// rating and lyrics.
    func present(_ track: Track, at position: Double) {
        let newSong = current?.id != track.id
        current = track
        duration = playback.duration
        playback.heldPosition = position
        isPlaying = true
        nowPlaying?.show(track, duration: duration)
        persistSoon()
        if newSong {
            loadRating(of: track.id)
            lyricsLoad?.cancel()
            lyricsFor = nil
            lyrics = .idle
        }
        if showsLyrics { loadLyrics() }
    }

    /// Shows the stream's quality, and fills in a length the song lacked.
    func show(_ stream: ResolvedStream) {
        self.stream = stream
        playback.currentPremium = stream.isPremium
        if playback.duration <= 0, let length = stream.duration {
            playback.duration = length
            duration = length
            nowPlaying?.setDuration(length)
        }
    }

    /// Loads the playing song's lyrics, unless they are shown or loading.
    func loadLyrics() {
        guard let id = current?.id else {
            lyrics = .idle
            return
        }
        guard lyricsFor != id else { return }
        lyricsFor = id
        lyricsLoad?.cancel()
        if let cached = lyricsCache[id] {
            lyrics = cached.map(LyricsState.loaded) ?? .unavailable
            return
        }
        lyrics = .loading
        let music = music
        lyricsLoad = Task { [weak self] in
            let result = await Result { try await music.lyrics(videoId: id) }
            guard let self else { return }
            // Kept even when the song has changed meanwhile, for when it plays again.
            if case .success(let found) = result { remember(found, for: id) }
            guard !Task.isCancelled, lyricsFor == id else { return }
            switch result {
            case .success(let found): lyrics = found.map(LyricsState.loaded) ?? .unavailable
            case .failure(let error):
                // Asked again when next shown.
                lyricsFor = nil
                lyrics = .failed("Couldn't load lyrics: \(sentence(for: error))")
            }
        }
    }

    /// Fetches the next song's lyrics ahead, only while lyrics are on screen.
    func prefetchLyrics(of id: String) {
        guard showsLyrics, id != current?.id, lyricsCache[id] == nil, lyricsAhead.insert(id).inserted else { return }
        let music = music
        Task { [weak self] in
            // Not `try?`, which would fold a song without lyrics into a failure.
            let result = await Result { try await music.lyrics(videoId: id) }
            self?.lyricsAhead.remove(id)
            if case .success(let found) = result { self?.remember(found, for: id) }
        }
    }

    /// Keeps `found` for `id`, starting over once the cache is full.
    func remember(_ found: Lyrics?, for id: String) {
        if lyricsCache.count >= Self.lyricsCacheLimit { lyricsCache.removeAll() }
        // `.some`, as nil assigned through the subscript would remove the entry.
        lyricsCache[id] = .some(found)
    }

    func loadRating(of id: String) {
        ratingGeneration += 1
        rating = .none
        ratingLoad?.cancel()
        guard signedIn else { return }
        let generation = ratingGeneration
        let music = music
        ratingLoad = Task { [weak self] in
            let result = await Result { try await music.rating(videoId: id) }
            guard let self, ratingGeneration == generation else { return }
            switch result {
            case .success(let found): rating = found
            case .failure(let error): Logger.playback.debug("could not load the song's rating: \(sentence(for: error), privacy: .public)")
            }
        }
    }

    /// Remembers a firm Premium answer across launches, so it isn't asked for
    /// again on the first songs.
    func syncPremiumStatus() {
        let status = chooser.status
        if premiumStatus != status { premiumStatus = status }
        let (known, none) = (status == .premium, status == .notPremium)
        guard known || none, settings.value.premiumAccount != known || settings.value.noPremium != none else { return }
        settings.value.premiumAccount = known
        settings.value.noPremium = none
    }
}
