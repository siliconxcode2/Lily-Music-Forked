import Foundation
import os
import YTMCore

extension PlayerController {
    /// Pressing previous later than this into a song restarts it instead.
    static let restartAfterSeconds = 3.0
    /// Opening a song again after its connection dropped, each try waiting `reopenAfter` longer than the last.
    static let maxReopens = 3
    static let reopenAfter = Duration.seconds(5)

    public func togglePlayPause() {
        setPaused(isPlaying)
    }

    /// At the queue's end with autoplay on, plays on into a radio of the last. The song is chosen, so earlier
    /// failures no longer count towards the run that stops playback.
    public func next() {
        playback.failures = 0
        next(user: true)
    }

    /// A restart counts as a new play.
    public func previous() {
        if enginePosition > Self.restartAfterSeconds {
            seek(to: 0)
            if playback.started { recordPlay() }
            return
        }
        if queue.back(repeat: repeatMode) != nil {
            playback.failures = 0
            startCurrent()
        }
    }

    public func jump(to index: Int) {
        if queue.jump(to: index) != nil {
            playback.failures = 0
            startCurrent()
        }
    }

    /// Moves to `seconds` into the song, kept short of its very end. With
    /// nothing loaded yet, or while it is opened again, it starts there.
    public func seek(to seconds: Double) {
        guard let current else { return }
        let length = playback.duration
        let target = length > 0 ? max(min(seconds, length - 0.5), 0) : max(seconds, 0)
        if playback.itemID == nil || playback.reopening(current.id) { playback.resume = (current.id, target) }
        recorder.seeked()
        if playback.itemID == nil {
            playback.heldPosition = target
        } else {
            audio.seek(to: target)
        }
        lastSeek = Seek(count: lastSeek.count + 1, to: target)
        publishPlayback(at: target)
    }

    /// The device playing went away: pauses rather than carrying on through another, keeping the queue and
    /// position, so Play carries on through whatever plays now.
    func outputUnplugged() {
        guard settings.value.pauseOnUnplug, isPlaying else { return }
        setPaused(true)
        say("Paused, as the device playing was unplugged")
    }

    /// Playing with nothing loaded starts the song shown.
    func setPaused(_ paused: Bool) {
        guard current != nil else { return }
        if !paused, isStopped {
            // Replayed, as after stopping at the queue's end.
            playback.failures = 0
            startCurrent()
            return
        }
        if paused {
            audio.pause()
        } else {
            activateAudioSession()
            audio.resume()
        }
        isPlaying = !paused
        if paused { recorder.flushWatch(.now, paused: true, reporting: reportsToYouTube) }
        updateBuffering()
        publishPlayback()
    }

    /// With `user` false the song played through, which ends the run of failures.
    func next(user: Bool) {
        if !user { playback.failures = 0 }
        if queue.advance(user: user, repeat: repeatMode) != nil {
            startCurrent()
            return
        }
        guard settings.value.autoplay, !queue.isEmpty, let seed = queue.current?.id else {
            if !user { stop() }
            return
        }
        let generation = playback.generation
        let music = music
        let pending = playback.extending ? extending : nil
        autoplay?.cancel()
        autoplay = Task { [weak self] in
            // The radio queued as this queue's last song started may still be
            // loading; it is waited for rather than asked for a second time.
            if let pending {
                await pending.value
                guard let self, !Task.isCancelled, playback.generation == generation else { return }
                if queue.advance(user: true, repeat: repeatMode) != nil {
                    startCurrent()
                    return
                }
            }
            let result = await Result { try await music.radio(videoId: seed) }
            // The playback generation, not the queue's revision: the radio
            // queued as the last song started may have just extended it.
            guard let self, !Task.isCancelled, playback.generation == generation else { return }
            switch result {
            case .success(let tracks): appendUnique(tracks)
            // Failed, it may still move on to what that radio added.
            case .failure(let error): Logger.playback.warning("autoplay radio failed: \(sentence(for: error), privacy: .public)")
            }
            if queue.advance(user: true, repeat: repeatMode) != nil {
                startCurrent()
            } else {
                stop()
            }
        }
    }

    func startCurrent() {
        guard let track = queue.current else {
            stop()
            return
        }
        let recorded = playback.playRecorded == playback.generation
        playback.generation += 1
        // A song opened again carries on without a second play.
        if !playback.reopening(track.id) {
            playback.reopen = nil
        } else if recorded {
            playback.playRecorded = playback.generation
        }
        playback.started = false
        playback.loading = true
        playback.stalled = false
        playback.duration = track.seconds
        playback.requestedAt = .now
        playback.currentPremium = false
        // A skip to the song queued in the engine plays its stream, unless
        // that is a Premium one being retried on the free path.
        if gapless.queued?.trackID == track.id, playback.forceFree != track.id {
            gapless.unqueue(into: &prefetcher)
        } else {
            gapless.forget()
        }
        for task in [resolving, queueing, autoplay, reopenWait] { task?.cancel() }
        // Before the stop, which forgets how much of the song the engine holds.
        let held = heldStream(track.id)
        // The output runs on while the stream resolves, so iOS keeps the app
        // running, and the system's Now Playing, through a slow fetch.
        audio.stop(keepingOutput: true)
        playback.itemID = nil
        let resume = playback.resume.flatMap { $0.id == track.id ? $0.position : nil } ?? 0
        present(track, at: resume)
        updateBuffering()
        publishPlayback()
        // A stream resolved ahead needs no await, so the song loads on this
        // turn and the quality badge never shows empty in between.
        if let prefetched = localStream(track.id) ?? held ?? prefetcher.take(track.id) {
            load(track, prefetched)
            return
        }
        stream = nil

        let source = streamSource(for: track.id)
        let generation = playback.generation
        resolving = Task { [weak self] in
            async let resolved = Result { try await source() }
            // The session starts while the stream resolves off the main actor, not after it. Not
            // offline, where a song not downloaded fails and would only silence other apps.
            if let self, isPlaying, downloads.online != false { activateAudioSession() }
            let result = await resolved
            guard let self, !Task.isCancelled, playback.generation == generation else { return }
            switch result {
            case .success(let prefetched): load(track, prefetched)
            // Still offline.
            case .failure where playback.reopening(track.id): connectionLost()
            case .failure(let error): playbackFailed(track.title, sentence(for: error))
            }
        }
    }

    private func load(_ track: Track, _ prefetched: StreamPrefetcher.Prefetched) {
        show(prefetched.stream)
        let start = resumePosition()
        do {
            let item = try audioItem(for: track, stream: prefetched.stream)
            playback.itemID = item.id
            activateAudioSession()
            audio.play(item, from: start, paused: !isPlaying)
            // Kept with when it was resolved, so previous, a jump back or
            // repeat one plays it again without asking.
            prefetcher.storePlaying(track.id, prefetched)
        } catch {
            playbackFailed(track.title, error.message)
        }
    }

    private func resumePosition() -> Double {
        guard let resume = playback.resume, resume.id == queue.current?.id else { return 0 }
        return resume.position
    }

    /// Opens the song again where it stopped, a few times while the connection
    /// is gone, then stops on it, so Play carries on.
    func connectionLost() {
        guard let id = queue.current?.id else { return }
        Logger.playback.warning("lost the connection")
        let tries = playback.reopenTry(id, position: currentTime)
        playback.started = false
        // Resolved afresh, as on Windows, which offline fails at once rather than riding out another minute.
        prefetcher.remove(id)
        let held = resumePosition()
        guard isPlaying, tries <= Self.maxReopens else {
            if tries > Self.maxReopens { say("Lost the connection. Press play to carry on.") }
            stop()
            playback.heldPosition = held
            publishPlayback()
            return
        }
        if tries == 1 { say("Lost the connection; trying again") }
        playback.loading = true
        playback.itemID = nil
        playback.heldPosition = held
        updateBuffering()
        publishPlayback()
        let generation = playback.generation
        reopenWait?.cancel()
        reopenWait = Task { [weak self] in
            try? await Task.sleep(for: Self.reopenAfter * tries)
            // A late event may have sent it after the song played on.
            guard let self, !Task.isCancelled, playback.generation == generation, !playback.started, playback.reopen != nil
            else { return }
            if isPlaying {
                startCurrent()
            } else {
                // Play then opens it.
                playback.loading = false
                updateBuffering()
            }
        }
    }

    /// A Premium stream or a downloaded file gets one retry on the free stream
    /// without counting a second play; otherwise the next song plays, until a few in a row fail.
    func playbackFailed(_ title: String, _ message: String) {
        Logger.playback.warning("playback failed: \(message, privacy: .public)")
        if let id = queue.current?.id { prefetcher.remove(id) }
        if let id = queue.current?.id, playback.currentPremium || stream?.url.isFileURL == true, playback.forceFree != id {
            if playback.currentPremium { Task { [music] in await music.suspectPremiumPlayer() } }
            playback.currentPremium = false
            playback.forceFree = id
            prefetcher.clear()
            Logger.premium.info("\(id, privacy: .public): stream failed to play (\(message, privacy: .public)); retrying the free stream")
            restartCurrent()
            return
        }
        playback.failures += 1
        // Offline, YouTube Music skips songs not downloaded without a word, through the whole queue.
        let offline = downloads.online == false
        if !offline { say("Couldn't play “\(title)”: \(message)") }
        if playback.failures < (offline ? queue.count : Self.maxConsecutiveFailures), queue.peekNext(repeat: repeatMode) != nil {
            next(user: true)
        } else {
            stop()
            if offline { say("You're offline, and nothing else in the queue is downloaded.") }
        }
    }

    /// The system's media services restarted, taking the audio graph with
    /// them. The position is read first, as the rebuild stops the sound.
    func mediaServicesReset() {
        let position = enginePosition
        audio.rebuild()
        if !isStopped { restartCurrent(from: position) }
    }

    /// Reloads the current song from where it got to, or `position`, without
    /// counting a second play; at the very end it starts over.
    private func restartCurrent(from position: Double? = nil) {
        guard let id = queue.current?.id else { return }
        let position = position ?? enginePosition
        let carryOn = playback.started && (playback.duration <= 0 || position < playback.duration - 1)
        if carryOn { playback.resume = (id, position) }
        startCurrent()
        if carryOn { playback.playRecorded = playback.generation }
    }

    /// Stops the sound, keeping the song shown where it got to.
    func stop() {
        playback.heldPosition = enginePosition
        playback.started = false
        playback.loading = false
        playback.itemID = nil
        resolving?.cancel()
        reopenWait?.cancel()
        gapless.unqueue(into: &prefetcher)
        audio.stop(keepingOutput: false)
        isPlaying = false
        // Play carries on a song stopped on a dropped connection as the same play.
        let reopening = queue.current.map { playback.reopening($0.id) } ?? false
        recorder.flushWatch(reopening ? .now : .last, paused: true, reporting: reportsToYouTube)
        updateBuffering()
        publishPlayback()
    }
}
