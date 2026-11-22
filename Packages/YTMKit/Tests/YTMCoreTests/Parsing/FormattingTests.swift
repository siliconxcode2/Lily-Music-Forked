import Testing
@testable import YTMCore

@Suite struct FormattingTests {
    @Test func formatsNumbersAndDurations() {
        #expect(Formatting.compact(999) == "999")
        #expect(Formatting.compact(1_000) == "1K")
        #expect(Formatting.compact(1_260_000) == "1.3M")
        #expect(Formatting.compact(312_000) == "312K")
        #expect(Formatting.compact(2_500_000_000) == "2.5B")
        #expect(Formatting.duration(59) == "0:59")
        #expect(Formatting.duration(225) == "3:45")
        #expect(Formatting.duration(3725) == "1:02:05")
    }

    @Test func totalsRunningTime() {
        let t = { (d: Int) in Track(id: "x", title: "x", duration: d) }
        #expect(Formatting.totalTime([t(1500), t(2401)]) == "1 hr 6 min")
        #expect(Formatting.totalTime([t(61)]) == "2 min")
        #expect(Formatting.totalTime([]) == nil)
        #expect(Formatting.playlistMeta(count: 120, tracks: [t(61)]) == "120 songs • 2 min")
        #expect(Formatting.playlistMeta(count: nil, tracks: [Track(id: "x", title: "x")]) == "1 song")
    }

    @Test func readsYouTubesText() {
        #expect(Formatting.seconds("3:45") == 225)
        #expect(Formatting.seconds("1:02:05") == 3725)
        #expect(Formatting.seconds("3.2M plays") == nil)
        #expect(Formatting.seconds("3:4") == nil)
        #expect(Formatting.count("1.66K subscribers") == 1660)
        #expect(Formatting.count("3.2M plays") == 3_200_000)
        #expect(Formatting.count("12,345 views") == 12345)
        #expect(Formatting.count("1B views") == 1_000_000_000)
        #expect(Formatting.count("Artist") == nil)
        #expect(Formatting.number("49 songs") == 49)
        #expect(Formatting.number("2,024 tracks") == 2024)
    }
}

@Suite struct ThumbnailTests {
    private let thumbs = JSON([
        ["url": "a", "width": 60], ["url": "b", "width": 226], ["url": "c", "width": 544],
    ])

    @Test func picksSmallestSufficientThumbnail() {
        #expect(Thumbnail.pick(thumbs, edge: 120) == "b")
        #expect(Thumbnail.pick(thumbs, edge: 1000) == "c")
        #expect(Thumbnail.pick(JSON([Any]()), edge: 120) == nil)
    }

    @Test func resizesGoogleusercontentThumbnails() {
        #expect(Thumbnail.resized("https://lh3.googleusercontent.com/abc=w60-h60-l90-rj", edge: 360)
            == "https://lh3.googleusercontent.com/abc=w360-h360-l90-rj")
        let ytimg = "https://i.ytimg.com/vi/x/hqdefault.jpg"
        #expect(Thumbnail.resized(ytimg, edge: 360) == ytimg)
        #expect(Thumbnail.url("//lh3.googleusercontent.com/abc=w60-h60", edge: 90)?.absoluteString
            == "https://lh3.googleusercontent.com/abc=w90-h90-l90-rj")
        #expect(Thumbnail.url("https://example.com/a.jpg", edge: 90) == nil, "off the allowlist")
    }
}
