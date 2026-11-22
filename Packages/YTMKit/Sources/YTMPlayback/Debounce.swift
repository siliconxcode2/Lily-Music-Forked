import Foundation

/// Each `schedule` replaces the last, so a burst of changes costs one write.
@MainActor final class Debounce {
    private let delay: Duration
    private var pending: Task<Void, Never>?

    init(after delay: Duration = .seconds(2)) {
        self.delay = delay
    }

    var isPending: Bool { pending != nil }

    func schedule(_ action: @escaping @MainActor () -> Void) {
        pending?.cancel()
        pending = Task { [weak self, delay] in
            try? await Task.sleep(for: delay)
            guard let self, !Task.isCancelled else { return }
            pending = nil
            action()
        }
    }

    func cancel() {
        pending?.cancel()
        pending = nil
    }
}
