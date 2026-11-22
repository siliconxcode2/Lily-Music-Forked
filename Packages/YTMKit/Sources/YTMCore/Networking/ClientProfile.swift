import Foundation

/// YouTube decides what to send by the client: the web client gets pages,
/// some apps get plain stream URLs, and the Android app gets timed lyrics.
struct ClientProfile: Sendable, Hashable {
    struct Device: Sendable, Hashable {
        let make: String
        let model: String
        let osName: String
        let osVersion: String
    }

    /// `context.client.clientName`.
    let name: String
    /// The same client's number, for `X-YouTube-Client-Name`.
    let id: String
    let version: String
    let host: String
    let userAgent: String
    /// Sent as `Origin`; app clients on Android send none.
    let origin: String?
    let device: Device?
    let androidSdkVersion: Int?
    /// A browser client: it takes the account's cookies and, signed out,
    /// the consent cookie a browser that dismissed YouTube's banner sends.
    let isWeb: Bool

    func url(_ endpoint: String) -> URL? {
        var parts = URLComponents()
        parts.scheme = "https"
        parts.host = host
        parts.path = "/youtubei/v1/" + endpoint
        parts.queryItems = [URLQueryItem(name: "prettyPrint", value: "false")]
        return parts.url
    }

    func context(hl: String, gl: String, visitorData: String?) -> [String: Any] {
        var client: [String: Any] = ["clientName": name, "clientVersion": version, "hl": hl, "gl": gl]
        if let visitorData { client["visitorData"] = visitorData }
        if let device {
            client["deviceMake"] = device.make
            client["deviceModel"] = device.model
            client["osName"] = device.osName
            client["osVersion"] = device.osVersion
            client["userAgent"] = userAgent
        }
        if let androidSdkVersion { client["androidSdkVersion"] = androidSdkVersion }
        return client
    }

    func headers(visitorData: String?) -> [String: String] {
        var headers = [
            "Content-Type": "application/json",
            "User-Agent": userAgent,
            "X-YouTube-Client-Name": id,
            "X-YouTube-Client-Version": version,
        ]
        if let origin {
            headers["Origin"] = origin
            if isWeb { headers["Referer"] = origin + "/" }
        }
        if let visitorData { headers["X-Goog-Visitor-Id"] = visitorData }
        return headers
    }
}

extension ClientProfile {
    static let browserUserAgent =
        "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/138.0.0.0 Safari/537.36"

    /// Every page, the library and, with Premium, the 256 kbps formats.
    /// The version is the site's own of November 2026.
    static let webRemix = ClientProfile(
        name: "WEB_REMIX", id: "67", version: "1.20261110.04.00", host: "music.youtube.com",
        userAgent: browserUserAgent, origin: "https://music.youtube.com", device: nil,
        androidSdkVersion: nil, isWeb: true
    )

    /// YouTube Studio, the second web client the Premium path tries.
    static let webCreator = ClientProfile(
        name: "WEB_CREATOR", id: "62", version: "1.20260708.06.00", host: "www.youtube.com",
        userAgent: browserUserAgent, origin: "https://www.youtube.com", device: nil,
        androidSdkVersion: nil, isWeb: true
    )

    /// YouTube's own website, whose guide holds the account's current
    /// picture. The version is the site's own of November 2026.
    static let web = ClientProfile(
        name: "WEB", id: "1", version: "2.20261112.10.00", host: "www.youtube.com",
        userAgent: browserUserAgent, origin: "https://www.youtube.com", device: nil,
        androidSdkVersion: nil, isWeb: true
    )

    /// Given lyrics line by line with their timings.
    static let androidMusic = ClientProfile(
        name: "ANDROID_MUSIC", id: "21", version: "7.21.50", host: "music.youtube.com",
        userAgent: "com.google.android.apps.youtube.music/7.21.50 (Linux; U; Android 14) gzip",
        origin: nil, device: nil, androidSdkVersion: 34, isWeb: false
    )

    /// The free stream path's first choice: YouTube hands it plain stream URLs.
    static let visionOS = ClientProfile(
        name: "VISIONOS", id: "101", version: "1.02", host: "www.youtube.com",
        userAgent: "Mozilla/5.0 (Macintosh; Intel Mac OS X 15_7_3) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Safari/605.1.15",
        origin: "https://www.youtube.com",
        device: Device(make: "Apple", model: "RealityDevice17,1", osName: "visionOS", osVersion: "26.5.23O471"),
        androidSdkVersion: nil, isWeb: false
    )

    /// YouTube on the Quest 3, the free path's second choice.
    static let androidVR = ClientProfile(
        name: "ANDROID_VR", id: "28", version: "1.65.10", host: "www.youtube.com",
        userAgent: "com.google.android.apps.youtube.vr.oculus/1.65.10 (Linux; U; Android 12L; eureka-user Build/SQ3A.220605.009.A1) gzip",
        origin: "https://www.youtube.com",
        device: Device(make: "Oculus", model: "Quest 3", osName: "Android", osVersion: "12L"),
        androidSdkVersion: 32, isWeb: false
    )

    /// YouTube's iPhone app, the free path's last choice.
    static let iOS = ClientProfile(
        name: "IOS", id: "5", version: "20.10.4", host: "www.youtube.com",
        userAgent: "com.google.ios.youtube/20.10.4 (iPhone16,2; U; CPU iOS 18_3_2 like Mac OS X;)",
        origin: "https://www.youtube.com",
        device: Device(make: "Apple", model: "iPhone16,2", osName: "iPhone", osVersion: "18.3.2.22D82"),
        androidSdkVersion: nil, isWeb: false
    )

    /// The plain-URL clients in the order the free path tries them: YouTube
    /// tends to change one at a time, so a song plays on the next meanwhile.
    static let plainStreamClients: [ClientProfile] = [.visionOS, .androidVR, .iOS]
}
