import AVFoundation

extension PlaybackEngine {
    /// Carries on from any warm-up; nil once the failure is reported.
    func open(_ item: AudioItem, at seconds: Double, announcingStart: Bool) -> Track? {
        let warmUp = takeWarmed(item)
        guard let loader = warmUp?.loader ?? makeLoader(item) else { return nil }
        let track = Track(item: item, loader: loader, startAt: seconds, announcesStart: announcingStart)
        track.download = Task { [self] in
            if let warming = warmUp?.task {
                // The file's start is on its way, and the rest follows it.
                await withTaskCancellationHandler { await warming.value } onCancel: { warming.cancel() }
            }
            let failure = await track.loader.run(source: source) { data in
                guard !track.isCancelled else { return }
                track.receive(data)
                progressed(track)
            } onElsewhere: {
                if !track.isCancelled { progressed(track) }
            }
            guard !track.isCancelled else { return }
            if let failure {
                track.fail(failure)
            }
            progressed(track)
        }
        return track
    }

    /// Nil once the failure is reported.
    private func makeLoader(_ item: AudioItem) -> StreamLoader? {
        do {
            return try StreamLoader(item: item, cache: cache)
        } catch {
            emit(.failed(id: item.id, message: error.message))
            return nil
        }
    }

    func progressed(_ track: Track) {
        if track === next {
            prepareNext()
        } else if track === producing {
            fill()
        }
        if track === heard {
            describeHeard()
        }
    }

    func describeHeard() {
        clock.describe(duration: heard?.duration, buffered: heard?.bufferedFraction ?? 0)
    }

    /// A next that fails is dropped and reported, and the item heard then simply ends.
    func prepareNext() {
        guard let next else { return }
        if let failure = next.failure {
            emit(Self.event(next, failure))
            dropNext()
            if awaitingNext {
                awaitingNext = false
                finish()
            }
            return
        }
        guard isReady(next) else { return }
        if awaitingNext {
            startAfresh(next)
        } else {
            fill()
        }
    }

    func isReady(_ track: Track) -> Bool {
        guard let rate = track.sampleRate else { return false }
        return nextFade <= 0 || track.trimLeadingSilence(limit: Int64(AudioPlayer.silenceTrimSeconds * rate))
    }

    /// Keeps what it downloaded. Reports nothing: the controller asked for it.
    func dropNext() {
        if let switched = producing, let heard, switched !== heard {
            keepWarm(switched)
            producing = heard
            fade = nil
            heard.seek(to: clock.position())
            restartPlayer()
        }
        if let next { keepWarm(next) }
        next = nil
        plan = nil
    }

    /// A next item keeps what it downloaded, as the song skipped to is often that one.
    func clear() {
        for track in [heard, fade?.from].compactMap(\.self) {
            track.cancel()
        }
        if let producing, producing !== heard { keepWarm(producing) }
        if let next { keepWarm(next) }
        heard = nil
        producing = nil
        next = nil
        plan = nil
        fade = nil
        awaitingNext = false
        resetPlayer()
    }
}
