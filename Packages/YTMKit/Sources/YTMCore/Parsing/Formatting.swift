import Foundation

/// The parsers read YouTube's English text only.
public enum Formatting {
    /// 225 → "3:45", 3725 → "1:02:05".
    public static func duration(_ seconds: Int) -> String {
        let seconds = max(seconds, 0)
        let (h, m, s) = (seconds / 3600, seconds / 60 % 60, seconds % 60)
        return h > 0 ? "\(h):\(twoDigits(m)):\(twoDigits(s))" : "\(m):\(twoDigits(s))"
    }

    /// 1234567 → "1.2M", 312000 → "312K".
    static func compact(_ n: Int) -> String {
        switch n {
        case ..<1_000: "\(n)"
        case ..<1_000_000: trimmed(Double(n) / 1e3, "K")
        case ..<1_000_000_000: trimmed(Double(n) / 1e6, "M")
        default: trimmed(Double(n) / 1e9, "B")
        }
    }

    public static func songs(_ n: Int) -> String {
        n == 1 ? "1 song" : "\(n) songs"
    }

    /// The tracks' total length as "1 hr 5 min" or "42 min", rounded up to
    /// the minute; nil when none has a length.
    static func totalTime(_ tracks: [Track]) -> String? {
        let total = tracks.reduce(0) { $0 + ($1.duration ?? 0) }
        guard total > 0 else { return nil }
        let minutes = (total + 59) / 60
        return minutes >= 60 ? "\(minutes / 60) hr \(minutes % 60) min" : "\(minutes) min"
    }

    /// A playlist header's "120 songs • 6 hr 2 min": `count` when YouTube
    /// gave the whole list's, else the tracks loaded.
    static func playlistMeta(count: Int?, tracks: [Track]) -> String {
        ([songs(count ?? tracks.count)] + [totalTime(tracks)].compactMap(\.self)).joined(separator: " • ")
    }

    /// "3:45" or "1:02:05" → seconds; nil for any other text.
    static func seconds(_ text: String) -> Int? {
        let parts = text.trimmingCharacters(in: .whitespaces).split(separator: ":", omittingEmptySubsequences: false)
        guard (2...3).contains(parts.count), parts.dropFirst().allSatisfy({ $0.count == 2 }) else { return nil }
        var total = 0
        for part in parts {
            guard !part.isEmpty, part.allSatisfy(\.isASCIIDigit), let n = Int(part) else { return nil }
            total = total * 60 + n
        }
        return total
    }

    /// "1.66K subscribers" → 1660, "12,345 views" → 12345; nil without digits.
    static func count(_ text: String) -> Int? {
        var digits = "", words = "", exponent = 0
        var afterPoint = false, inNumber = false
        for c in text {
            if c.isASCIIDigit {
                digits.append(c)
                if afterPoint { exponent -= 1 }
                if !inNumber { words.append(" ") }
                inNumber = true
            } else if c == ".", !digits.isEmpty {
                afterPoint = true
            } else if c != "," {
                words += c.lowercased()
                inNumber = false
            }
        }
        guard let n = Int(digits) else { return nil }
        for word in words.split(separator: " ") {
            exponent += magnitudes[word] ?? 0
        }
        guard exponent >= 0 else { return nil }
        let (value, overflow) = n.multipliedReportingOverflow(by: Int(pow(10, Double(min(exponent, 18)))))
        return overflow || exponent > 18 ? nil : value
    }

    private static let magnitudes: [Substring: Int] = ["k": 3, "m": 6, "b": 9]

    /// The first run of digits in `text`, as in "49 songs" or "2,024".
    static func number(_ text: String) -> Int? {
        let digits = text.drop { !$0.isASCIIDigit }.prefix { $0.isASCIIDigit || $0 == "," }.filter(\.isASCIIDigit)
        return Int(digits)
    }

    private static func trimmed(_ value: Double, _ suffix: String) -> String {
        if value >= 100 { return String(format: "%.0f", value) + suffix }
        var text = String(format: "%.1f", value)
        if text.hasSuffix(".0") { text.removeLast(2) }
        return text + suffix
    }

    private static func twoDigits(_ n: Int) -> String {
        n < 10 ? "0\(n)" : "\(n)"
    }
}

extension Character {
    var isASCIIDigit: Bool { isASCII && isNumber }
}
