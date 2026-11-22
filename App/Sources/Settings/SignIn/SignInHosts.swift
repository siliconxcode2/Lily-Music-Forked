import Foundation

/// The hosts Google's sign-in may show; everything else leaves for the browser.
nonisolated enum SignInHosts {
    static let musicHost = "music.youtube.com"
    /// Sign-in passes through these on its way to YouTube Music. Never handed to
    /// the system, which would open the YouTube apps and leave sign-in behind.
    private static let youtubeHosts: Set<String> = ["youtube.com", "www.youtube.com", "m.youtube.com", musicHost]
    /// Sign-in and cookie consent hosts, allowed on any path.
    private static let signInHosts: Set<String> = [
        "accounts.youtube.com", "consent.google.com", "consent.youtube.com", "gds.google.com",
    ]
    /// Google also sets cookies on regional accounts hosts, such as accounts.google.co.uk.
    private static let accountsPrefix = "accounts."
    private static let googlePrefix = "google."
    /// What follows `google.` in each of https://www.google.com/supported_domains.
    private static let googleDomains: Set<Substring> = [
        "com", "ad", "ae", "com.af", "com.ag", "al", "am", "co.ao", "com.ar", "as", "at", "com.au", "az", "ba",
        "com.bd", "be", "bf", "bg", "com.bh", "bi", "bj", "com.bn", "com.bo", "com.br", "bs", "bt", "co.bw",
        "by", "com.bz", "ca", "cd", "cf", "cg", "ch", "ci", "co.ck", "cl", "cm", "cn", "com.co", "co.cr",
        "com.cu", "cv", "com.cy", "cz", "de", "dj", "dk", "dm", "com.do", "dz", "com.ec", "ee", "com.eg", "es",
        "com.et", "fi", "com.fj", "fm", "fr", "ga", "ge", "gg", "com.gh", "com.gi", "gl", "gm", "gr", "com.gt",
        "gy", "com.hk", "hn", "hr", "ht", "hu", "co.id", "ie", "co.il", "im", "co.in", "iq", "is", "it", "je",
        "com.jm", "jo", "co.jp", "co.ke", "com.kh", "ki", "kg", "co.kr", "com.kw", "kz", "la", "com.lb", "li",
        "lk", "co.ls", "lt", "lu", "lv", "com.ly", "co.ma", "md", "me", "mg", "mk", "ml", "com.mm", "mn",
        "com.mt", "mu", "mv", "mw", "com.mx", "com.my", "co.mz", "com.na", "com.ng", "com.ni", "ne", "nl",
        "no", "com.np", "nr", "nu", "co.nz", "com.om", "com.pa", "com.pe", "com.pg", "com.ph", "com.pk", "pl",
        "pn", "com.pr", "ps", "pt", "com.py", "com.qa", "ro", "ru", "rw", "com.sa", "com.sb", "sc", "se",
        "com.sg", "sh", "si", "sk", "com.sl", "sn", "so", "sm", "sr", "st", "com.sv", "td", "tg", "co.th",
        "com.tj", "tl", "tm", "tn", "to", "com.tr", "tt", "com.tw", "co.tz", "com.ua", "co.ug", "co.uk",
        "com.uy", "co.uz", "com.vc", "co.ve", "co.vi", "com.vn", "vu", "ws", "rs", "co.za", "co.zm", "co.zw",
        "cat",
    ]

    /// Whether the sign-in page may show `url`. Only HTTPS.
    static func allows(_ url: URL) -> Bool {
        guard url.scheme == "https", let host = url.host() else { return false }
        return isYouTube(host) || signInHosts.contains(host) || isGoogleAccountsHost(host)
    }

    /// Sign-in has finished once a YouTube page has the session's cookies.
    static func isYouTube(_ host: String) -> Bool {
        youtubeHosts.contains(host)
    }

    /// Refused links open in the browser, except sign-in hops, whose URLs carry
    /// tokens, and YouTube's, which iOS gives to the YouTube apps.
    static func opensInBrowser(_ url: URL) -> Bool {
        guard url.scheme == "https" || url.scheme == "http", let host = url.host() else { return false }
        return !host.hasPrefix(accountsPrefix) && !host.hasSuffix("youtube.com")
    }

    /// `accounts.google.<tld>` for one of Google's own domains, so that
    /// lookalikes such as accounts.google.co.uk.example.com are refused.
    private static func isGoogleAccountsHost(_ host: String) -> Bool {
        guard host.hasPrefix(accountsPrefix) else { return false }
        let domain = host.dropFirst(accountsPrefix.count)
        guard domain.hasPrefix(googlePrefix) else { return false }
        return googleDomains.contains(domain.dropFirst(googlePrefix.count))
    }
}
