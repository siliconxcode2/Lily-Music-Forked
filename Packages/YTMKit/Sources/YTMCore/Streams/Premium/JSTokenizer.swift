import Foundation

/// Just enough JavaScript grammar to step over strings, nested template literals, regular
/// expressions and comments without mistaking what is inside them for code.
struct JSTokenizer {
    let source: [UInt8]
    private var offset: Int
    private let limit: Int
    /// One entry per open `{`: true for a template's `${`, whose `}`
    /// carries on the template rather than closing a block.
    private var braces: [Bool] = []
    /// The token before, which tells a regular expression from a division.
    private var previous: JSToken?

    /// Tokenizes `source[range]`, which must start between two tokens.
    init(_ source: [UInt8], range: Range<Int>? = nil) {
        self.source = source
        offset = range?.lowerBound ?? 0
        limit = range?.upperBound ?? source.count
    }

    /// The next token, or `.end` once the source runs out.
    mutating func next() throws -> JSToken {
        let newline = try skipSpace()
        guard offset < limit else { return JSToken(kind: .end, start: limit, end: limit, newlineBefore: newline) }
        let start = offset
        let c = source[start]
        let kind: JSToken.Kind
        switch c {
        case UInt8(ascii: "`"):
            kind = try template(from: start + 1, continuing: false)
        case UInt8(ascii: "}") where braces.last == true:
            braces.removeLast()
            kind = try template(from: start + 1, continuing: true)
        case UInt8(ascii: "\""), UInt8(ascii: "'"):
            try string(quote: c)
            kind = .string
        case UInt8(ascii: "0")...UInt8(ascii: "9"):
            number()
            kind = .number
        case UInt8(ascii: "."), UInt8(ascii: "/"), UInt8(ascii: "?"):
            if c == UInt8(ascii: "."), isDigit(at: start + 1) {
                number()
                kind = .number
            } else if c == UInt8(ascii: "/"), regexMayFollow {
                try regex()
                kind = .regex
            } else {
                try punctuator()
                kind = .punctuator
            }
        default:
            if Self.isIdentifierStart(c) {
                offset += 1
                while offset < limit, Self.isIdentifierPart(source[offset]) { offset += 1 }
                kind = .identifier
            } else {
                try punctuator()
                kind = .punctuator
            }
        }
        let nesting: Int8 = switch kind {
        case .templateHead: 1
        case .templateTail: -1
        case .punctuator where offset - start == 1:
            switch c {
            case UInt8(ascii: "("), UInt8(ascii: "["), UInt8(ascii: "{"): 1
            case UInt8(ascii: ")"), UInt8(ascii: "]"), UInt8(ascii: "}"): -1
            default: 0
            }
        default: 0
        }
        let token = JSToken(kind: kind, start: start, end: offset, newlineBefore: newline, nesting: nesting)
        previous = token
        return token
    }

    // MARK: Pieces

    /// Skips white space and comments; returns whether a line break was among them.
    private mutating func skipSpace() throws -> Bool {
        var newline = false
        while offset < limit {
            let c = source[offset]
            switch c {
            case UInt8(ascii: "\n"), UInt8(ascii: "\r"):
                newline = true
                offset += 1
            case UInt8(ascii: " "), UInt8(ascii: "\t"), 0x0B, 0x0C:
                offset += 1
            case UInt8(ascii: "/") where byte(offset + 1) == UInt8(ascii: "/"):
                while offset < limit, source[offset] != UInt8(ascii: "\n"), source[offset] != UInt8(ascii: "\r") {
                    offset += 1
                }
            case UInt8(ascii: "/") where byte(offset + 1) == UInt8(ascii: "*"):
                var end = offset + 2
                while end + 1 < limit, !(source[end] == UInt8(ascii: "*") && source[end + 1] == UInt8(ascii: "/")) {
                    if source[end] == UInt8(ascii: "\n") || source[end] == UInt8(ascii: "\r") { newline = true }
                    end += 1
                }
                guard end + 1 < limit else { throw Self.malformed }
                offset = end + 2
            case 0xC2 where byte(offset + 1) == 0xA0:
                offset += 2  // no-break space
            case 0xEF where byte(offset + 1) == 0xBB && byte(offset + 2) == 0xBF:
                offset += 3  // byte order mark
            case 0xE2 where byte(offset + 1) == 0x80 && ((0x80...0x8A).contains(byte(offset + 2)) || byte(offset + 2) == 0xAF):
                offset += 3  // Unicode spaces
            case 0xE2 where byte(offset + 1) == 0x80 && (byte(offset + 2) == 0xA8 || byte(offset + 2) == 0xA9):
                newline = true  // line and paragraph separators
                offset += 3
            default:
                return newline
            }
        }
        return newline
    }

    /// A template's text up to its end or its next `${`.
    private mutating func template(from start: Int, continuing: Bool) throws -> JSToken.Kind {
        var p = start
        while p < limit {
            switch source[p] {
            case UInt8(ascii: "\\"):
                p += 2
            case UInt8(ascii: "`"):
                offset = p + 1
                return continuing ? .templateTail : .template
            case UInt8(ascii: "$") where byte(p + 1) == UInt8(ascii: "{"):
                offset = p + 2
                braces.append(true)
                return continuing ? .templateMiddle : .templateHead
            default:
                p += 1
            }
        }
        throw Self.malformed
    }

    private mutating func string(quote: UInt8) throws {
        var p = offset + 1
        while p < limit {
            switch source[p] {
            case UInt8(ascii: "\\"): p += 2
            case quote:
                offset = p + 1
                return
            default: p += 1
            }
        }
        throw Self.malformed
    }

    /// Digits, letters, `_` and `.` in any order, which covers every
    /// numeric literal, with a sign after a decimal exponent.
    private mutating func number() {
        let radix = source[offset] == UInt8(ascii: "0") && "xXbBoO".utf8.contains(byte(offset + 1))
        offset += 1
        while offset < limit {
            let c = source[offset]
            if Self.isIdentifierPart(c) || c == UInt8(ascii: ".") {
                offset += 1
            } else if !radix, c == UInt8(ascii: "+") || c == UInt8(ascii: "-"),
                      source[offset - 1] | 0x20 == UInt8(ascii: "e") {
                offset += 1
            } else {
                return
            }
        }
    }

    private mutating func regex() throws {
        var p = offset + 1
        var inClass = false
        while p < limit {
            switch source[p] {
            case UInt8(ascii: "\\"): p += 2
            case UInt8(ascii: "["): inClass = true; p += 1
            case UInt8(ascii: "]"): inClass = false; p += 1
            case UInt8(ascii: "/") where !inClass:
                p += 1
                while p < limit, Self.isIdentifierPart(source[p]) { p += 1 }
                offset = p
                return
            case UInt8(ascii: "\n"), UInt8(ascii: "\r"): throw Self.malformed
            default: p += 1
            }
        }
        throw Self.malformed
    }

    private mutating func punctuator() throws {
        let c = source[offset], c1 = byte(offset + 1), c2 = byte(offset + 2)
        let eq = UInt8(ascii: "=")
        let length: Int
        switch c {
        case UInt8(ascii: "{"):
            braces.append(false)
            length = 1
        case UInt8(ascii: "}"):
            _ = braces.popLast()
            length = 1
        case UInt8(ascii: "("), UInt8(ascii: ")"), UInt8(ascii: "["), UInt8(ascii: "]"), UInt8(ascii: ";"),
             UInt8(ascii: ","), UInt8(ascii: "~"), UInt8(ascii: ":"), UInt8(ascii: "@"):
            length = 1
        case UInt8(ascii: "."):
            length = c1 == c && c2 == c ? 3 : 1
        case UInt8(ascii: "?"):
            length = c1 == c ? (c2 == eq ? 3 : 2) : c1 == UInt8(ascii: ".") && !isDigit(at: offset + 2) ? 2 : 1
        case eq, UInt8(ascii: "!"):
            length = c1 == eq ? (c2 == eq ? 3 : 2) : c == eq && c1 == UInt8(ascii: ">") ? 2 : 1
        case UInt8(ascii: "+"), UInt8(ascii: "-"):
            length = c1 == c || c1 == eq ? 2 : 1
        case UInt8(ascii: "*"), UInt8(ascii: "&"), UInt8(ascii: "|"), UInt8(ascii: "<"):
            length = c1 == c ? (c2 == eq ? 3 : 2) : c1 == eq ? 2 : 1
        case UInt8(ascii: ">"):
            length = c1 != c ? (c1 == eq ? 2 : 1)
                : c2 == c ? (byte(offset + 3) == eq ? 4 : 3)
                : c2 == eq ? 3 : 2
        case UInt8(ascii: "%"), UInt8(ascii: "^"), UInt8(ascii: "/"):
            length = c1 == eq ? 2 : 1
        default:
            throw Self.malformed
        }
        offset += length
    }

    /// A `/` starts a regular expression wherever an expression may begin, so not after a value.
    private var regexMayFollow: Bool {
        guard let previous else { return true }
        switch previous.kind {
        case .number, .string, .regex, .template, .templateTail: return false
        case .identifier: return Word.operators.contains { previous.isWord($0, in: source) }
        case .punctuator:
            let c = source[previous.start]
            if previous.end - previous.start == 2, c == UInt8(ascii: "+") || c == UInt8(ascii: "-"),
               source[previous.start + 1] == c {
                return false
            }
            return previous.end - previous.start > 1 || (c != UInt8(ascii: ")") && c != UInt8(ascii: "]"))
        default: return true
        }
    }

    // MARK: Bytes

    private func byte(_ index: Int) -> UInt8 {
        index < limit ? source[index] : 0
    }

    private func isDigit(at index: Int) -> Bool {
        (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte(index))
    }

    /// Letters, `$`, `_`, escapes, private names and anything outside ASCII.
    static func isIdentifierStart(_ c: UInt8) -> Bool {
        switch c {
        case UInt8(ascii: "a")...UInt8(ascii: "z"), UInt8(ascii: "A")...UInt8(ascii: "Z"),
             UInt8(ascii: "$"), UInt8(ascii: "_"), UInt8(ascii: "\\"), UInt8(ascii: "#"), 0x80...:
            true
        default:
            false
        }
    }

    static func isIdentifierPart(_ c: UInt8) -> Bool {
        isIdentifierStart(c) || (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(c)
    }

    static let malformed = YTMError(.parse, "YouTube's player script couldn't be read.")
}
