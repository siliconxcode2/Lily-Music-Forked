import Foundation

/// googleusercontent artwork renders at any size named in its URL, so one
/// stored URL serves a row, a card and Now Playing alike.
enum Thumbnail {
    /// Edges in pixels that parsers store thumbnails at.
    static let row = 120
    static let card = 240
    static let header = 544

    /// `url` resized to `edge`, or nil if its host isn't on the allowlist.
    static func url(_ url: String?, edge: Int) -> URL? {
        guard let url, let resized = URL(string: resized(url, edge: edge)), HTTP.isAllowed(resized) else { return nil }
        return resized
    }

    /// googleusercontent URLs end in a size such as `=w60-h60-l90-rj`; this
    /// names `edge` instead. Other URLs come back as they are.
    static func resized(_ url: String, edge: Int) -> String {
        let url = url.hasPrefix("//") ? "https:" + url : url
        guard url.contains("googleusercontent.com"), let eq = url.lastIndex(of: "="),
              url[url.index(after: eq)...].hasPrefix("w")
        else { return url }
        return "\(url[..<eq])=w\(edge)-h\(edge)-l90-rj"
    }

    /// Of a `thumbnails` array (`[{url, width, height}]`), the smallest at
    /// least `edge` wide, else the largest, sized to `edge`.
    static func pick(_ thumbnails: JSON, edge: Int) -> String? {
        var smallestFitting: (width: Int, url: String)?
        var largest: (width: Int, url: String)?
        for thumbnail in thumbnails.array {
            guard let url = thumbnail["url"].string else { continue }
            let width = thumbnail["width"].int ?? 0
            if width >= edge, width < smallestFitting?.width ?? .max { smallestFitting = (width, url) }
            if width > largest?.width ?? -1 { largest = (width, url) }
        }
        return (smallestFitting ?? largest).map { resized($0.url, edge: edge) }
    }

    static func list(in renderer: JSON) -> JSON {
        let wrapper = renderer.first("thumbnailRenderer", "thumbnail")
        return wrapper.first("musicThumbnailRenderer", "croppedSquareThumbnailRenderer")["thumbnail", "thumbnails"]
    }
}
