import SwiftUI

/// Every icon in Lily, named by what it means and drawn as an SF Symbol, so it
/// takes the weight of the text beside it and animates as the system's do.
nonisolated enum Icon: CaseIterable, Sendable {
    case home, homeOutline, explore, library, search
    case play, pause, next, previous, shuffle, sparkle, `repeat`, repeatOne
    case volume, volumeLow, volumeOff
    case close, queue, lyrics, radio, account, note, more, clock, history
    case thumbUp, thumbUpFilled, thumbDown, thumbDownFilled, check, add, chevron
    case download, downloaded, pin, saveToPlaylist, inLibrary

    var symbol: String {
        switch self {
        case .home: "house.fill"
        case .homeOutline: "house"
        case .explore: "safari"
        case .library: "music.note.square.stack.fill"
        case .search: "magnifyingglass"
        case .play: "play.fill"
        case .pause: "pause.fill"
        case .next: "forward.fill"
        case .previous: "backward.fill"
        case .shuffle: "shuffle"
        case .sparkle: "sparkles"
        case .repeat: "repeat"
        case .repeatOne: "repeat.1"
        case .volume: "speaker.wave.3.fill"
        case .volumeLow: "speaker.wave.1.fill"
        case .volumeOff: "speaker.slash.fill"
        case .close: "xmark"
        case .queue: "list.bullet"
        case .lyrics: "quote.bubble"
        case .radio: "dot.radiowaves.left.and.right"
        case .account: "person.fill"
        case .note: "music.note"
        case .more: "ellipsis"
        case .clock: "clock"
        case .history: "clock.arrow.circlepath"
        case .thumbUp: "hand.thumbsup"
        case .thumbUpFilled: "hand.thumbsup.fill"
        case .thumbDown: "hand.thumbsdown"
        case .thumbDownFilled: "hand.thumbsdown.fill"
        case .check: "checkmark"
        case .add: "plus"
        case .chevron: "chevron.right"
        case .download: "arrow.down.circle"
        case .downloaded: "arrow.down.circle.fill"
        case .pin: "pin.fill"
        case .saveToPlaylist: "text.badge.plus"
        case .inLibrary: "text.badge.checkmark"
        }
    }
}

extension Image {
    init(icon: Icon) {
        self.init(systemName: icon.symbol)
    }
}
