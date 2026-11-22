import Foundation

/// Just enough of the grammar to tell where each statement ends and what a top-level one declares or assigns.
struct StatementReader {
    struct Statement {
        var range: Range<Int>
        var declares: [String] = []
        /// Declared names and `g.X` properties it gives a value to.
        var defines: [PlayerTrimmer.Key] = []
        /// The source naming the URL scrambler, when this defines it.
        var scrambler: Range<Int>?
        /// Ends in `;`, or is a declaration ending in `}`, so another statement can follow directly.
        var isTerminated = true
        /// A `var`, `let` or `const` list, whose declared names are not uses.
        var isDeclarationList = false
    }

    private var tokenizer: JSTokenizer
    let source: [UInt8]
    /// The next token, not yet consumed.
    private(set) var token: JSToken
    /// The token consumed last.
    private(set) var last: JSToken?

    init(_ source: [UInt8]) throws {
        self.source = source
        tokenizer = JSTokenizer(source)
        token = try tokenizer.next()
    }

    mutating func advance() throws {
        last = token
        token = try tokenizer.next()
    }

    // MARK: Top level

    /// What it defines, as yt-dlp's solver counts it: declarations, and expression
    /// statements that are a single assignment. Other statements define nothing.
    mutating func topLevelStatement(namespace: String) throws -> Statement {
        let start = token.start
        var statement = Statement(range: start..<start)
        // A declaration's closing brace ends it; an expression's may not.
        var isDeclaration = true
        if isWord(token, .function) {
            let (name, marked) = try function()
            if let name {
                statement.declares.append(text(name))
                if marked { statement.scrambler = name.start..<name.end }
            }
        } else if isWord(token, .async) {
            try advance()
            if isWord(token, .function), !token.newlineBefore {
                if let name = try function().name { statement.declares.append(text(name)) }
            } else {
                isDeclaration = false
                try expressionStatement(continuing: true)
            }
        } else if isWord(token, .class) {
            if let name = try classDeclaration() { statement.declares.append(text(name)) }
        } else if Word.declarations.contains(where: { isWord(token, $0) }) {
            isDeclaration = false
            try declarations(into: &statement)
        } else if token.kind == .identifier, !Word.statements.contains(where: { isWord(token, $0) }) {
            isDeclaration = false
            try assignment(into: &statement, namespace: namespace)
        } else {
            try skipStatement()
        }
        statement.defines += statement.declares.map(PlayerTrimmer.Key.symbol)
        // A stray closer consumes nothing, which would invert the range and stall the trimmer.
        guard let last, last.end > start else { throw JSTokenizer.malformed }
        statement.range = start..<last.end
        statement.isTerminated = isPunct(last, ";") || isDeclaration && isPunct(last, "}")
        return statement
    }

    /// `var a = 1, b = function () {…};`, noting a scrambler among them.
    private mutating func declarations(into statement: inout Statement) throws {
        statement.isDeclarationList = true
        try advance()
        repeat {
            if isPunct(token, ",") { try advance() }
            if token.kind == .identifier {
                statement.declares.append(text(token))
                let name = token
                try advance()
                if isPunct(token, "=") {
                    try advance()
                    if try initialFunctionIsScrambler() { statement.scrambler = name.start..<name.end }
                }
            } else if isPunct(token, "{") || isPunct(token, "[") {
                // A destructuring pattern names nothing yt-dlp's solver tracks.
                try skipBalanced()
                if isPunct(token, "=") {
                    try advance()
                    try expression(stopAtComma: true, continuing: false)
                }
            } else {
                throw JSTokenizer.malformed
            }
        } while isPunct(token, ",")
        try endStatement()
    }

    /// `a = …`, `a.b[c] = …` or `g.X = …` defines its target's root name, or `g.X` for the
    /// namespace. A sequence or any other expression defines nothing.
    private mutating func assignment(into statement: inout Statement, namespace: String) throws {
        let root = token
        let rootName = text(root)
        var key = PlayerTrimmer.Key.symbol(rootName)
        var first = true
        try advance()
        if isPunct(token, ":") {
            try advance()
            return try skipStatement()  // a label
        }
        while isPunct(token, ".") || isPunct(token, "[") {
            if isPunct(token, "[") {
                try skipBalanced()
            } else {
                try advance()
                guard token.kind == .identifier else { throw JSTokenizer.malformed }
                if first, rootName == namespace { key = .namespace(text(token)) }
                try advance()
            }
            first = false
        }
        let targetEnd = last?.end ?? root.end
        guard isAssignmentOperator(token), !isWord(root, .this) else { return try expressionStatement(continuing: true) }
        let plain = isPunct(token, "=")
        try advance()
        let marked = try initialFunctionIsScrambler() && plain
        guard !isPunct(token, ",") else { return try expressionStatement(continuing: true) }
        statement.defines.append(key)
        if marked { statement.scrambler = root.start..<targetEnd }
        try endStatement()
    }

    /// Reads an initialiser or assigned value, and whether it is exactly a
    /// non-async function expression whose body marks it as the scrambler.
    private mutating func initialFunctionIsScrambler() throws -> Bool {
        guard isWord(token, .function) else {
            try expression(stopAtComma: true, continuing: false)
            return false
        }
        let marked = try function().marked && atExpressionEnd(stopAtComma: true, previous: last)
        try expression(stopAtComma: true, continuing: true)
        return marked
    }

    // MARK: Statements

    mutating func skipStatement() throws {
        if isPunct(token, "{") { return try skipBalanced() }
        if isPunct(token, ";") { return try advance() }
        if isWord(token, .function) {
            _ = try function()
        } else if isWord(token, .class) {
            _ = try classDeclaration()
        } else if isWord(token, .if) {
            try advance()
            try skipBalanced()
            try skipStatement()
            if isWord(token, .else) {
                try advance()
                try skipStatement()
            }
        } else if isWord(token, .for) || isWord(token, .while) || isWord(token, .with) {
            try advance()
            if isWord(token, .await) { try advance() }
            try skipBalanced()
            try skipStatement()
        } else if isWord(token, .do) {
            try advance()
            try skipStatement()
            guard isWord(token, .while) else { throw JSTokenizer.malformed }
            try advance()
            try skipBalanced()
            if isPunct(token, ";") { try advance() }
        } else if isWord(token, .try) {
            try advance()
            try skipBalanced()
            if isWord(token, .catch) {
                try advance()
                if isPunct(token, "(") { try skipBalanced() }
                try skipBalanced()
            }
            if isWord(token, .finally) {
                try advance()
                try skipBalanced()
            }
        } else if isWord(token, .switch) {
            try advance()
            try skipBalanced()
            try skipBalanced()
        } else {
            try expressionStatement(continuing: false)
        }
    }

    /// `continuing` when part of the statement has been read already.
    private mutating func expressionStatement(continuing: Bool) throws {
        try expression(stopAtComma: false, continuing: continuing)
        try endStatement()
    }

    private mutating func endStatement() throws {
        if isPunct(token, ";") { try advance() }
    }

    /// `function [*] [name] (…) {…}`: its name, and whether its body calls
    /// `X.y("alr", "yes")` as a statement of its own, which marks the URL scrambler.
    private mutating func function() throws -> (name: JSToken?, marked: Bool) {
        try advance()
        if isPunct(token, "*") { try advance() }
        var name: JSToken?
        if token.kind == .identifier {
            name = token
            try advance()
        }
        guard isPunct(token, "(") else { throw JSTokenizer.malformed }
        try skipBalanced()
        guard isPunct(token, "{") else { throw JSTokenizer.malformed }
        var recent = RecentTokens()
        var depth = 0
        var marked = false
        repeat {
            guard token.kind != .end else { throw JSTokenizer.malformed }
            let opens = isOpening(token), closes = isClosing(token)
            if closes { depth -= 1 }
            if !marked, closes && depth == 0 || depth == 1 && isPunct(token, ";") {
                marked = isMarker(recent)
            }
            recent.append(token, level: depth)
            if opens { depth += 1 }
            try advance()
        } while depth > 0
        return (name, marked)
    }

    /// The last tokens before a statement's end spell `X.y("alr","yes")`,
    /// directly in the function's body, not in a nested block.
    private func isMarker(_ recent: RecentTokens) -> Bool {
        func at(_ i: Int, level: Int) -> JSToken? { recent[i].level == level ? recent[i].token : nil }
        let (open, openLevel) = recent[0]
        guard openLevel == 0 && isPunct(open, "{") || openLevel == 1 && (isPunct(open, ";") || isPunct(open, "}")),
              let object = at(1, level: 1), object.kind == .identifier,
              !isWord(object, .this), !isWord(object, .super),
              let dot = at(2, level: 1), isPunct(dot, "."),
              let method = at(3, level: 1), method.kind == .identifier,
              let call = at(4, level: 1), isPunct(call, "("),
              let alr = at(5, level: 2), isString(alr, "alr"),
              let comma = at(6, level: 2), isPunct(comma, ","),
              let yes = at(7, level: 2), isString(yes, "yes"),
              let close = at(8, level: 1), isPunct(close, ")")
        else { return false }
        return true
    }

    /// `class [name] [extends …] {…}`.
    private mutating func classDeclaration() throws -> JSToken? {
        try advance()
        var name: JSToken?
        if token.kind == .identifier, !isWord(token, .extends) {
            name = token
            try advance()
        }
        var depth = 0
        while !(depth == 0 && isPunct(token, "{")) {
            guard token.kind != .end else { throw JSTokenizer.malformed }
            if isOpening(token) { depth += 1 }
            if isClosing(token) { depth -= 1 }
            try advance()
        }
        try skipBalanced()
        return name
    }

    /// Up to a `;`, a `,` with `stopAtComma`, the enclosing bracket closing, or a line break where
    /// JavaScript inserts a semicolon. `continuing` when its start has been read.
    private mutating func expression(stopAtComma: Bool, continuing: Bool) throws {
        var depth = 0
        var previous = continuing ? last : nil
        while token.kind != .end {
            if depth == 0, atExpressionEnd(stopAtComma: stopAtComma, previous: previous) { return }
            if isOpening(token) { depth += 1 }
            if isClosing(token) { depth -= 1 }
            previous = token
            try advance()
        }
        guard depth == 0 else { throw JSTokenizer.malformed }
    }

    private func atExpressionEnd(stopAtComma: Bool, previous: JSToken?) -> Bool {
        if token.kind == .end || isPunct(token, ";") || isClosing(token) || stopAtComma && isPunct(token, ",") {
            return true
        }
        guard token.newlineBefore, let previous else { return false }
        return endsExpression(previous) && startsStatement(token)
    }

    /// Consumes an opening bracket and everything up to its partner.
    mutating func skipBalanced() throws {
        guard isOpening(token) else { throw JSTokenizer.malformed }
        var depth = 0
        repeat {
            guard token.kind != .end else { throw JSTokenizer.malformed }
            if isOpening(token) { depth += 1 }
            if isClosing(token) { depth -= 1 }
            try advance()
        } while depth > 0
    }

    // MARK: Tokens

    func text(_ token: JSToken) -> String {
        token.text(in: source)
    }

    func isPunct(_ token: JSToken, _ c: Unicode.Scalar) -> Bool {
        token.isPunct(c, in: source)
    }

    func isWord(_ token: JSToken, _ word: Word) -> Bool {
        token.isWord(word, in: source)
    }

    func isOpening(_ token: JSToken) -> Bool {
        token.nesting > 0
    }

    func isClosing(_ token: JSToken) -> Bool {
        token.nesting < 0
    }

    /// `"value"` or `'value'`, written without escapes.
    private func isString(_ token: JSToken, _ value: String) -> Bool {
        token.kind == .string && source[(token.start + 1)..<(token.end - 1)].elementsEqual(value.utf8)
    }

    /// `=` and the compound assignments, not comparisons or `=>`.
    private func isAssignmentOperator(_ token: JSToken) -> Bool {
        guard token.kind == .punctuator, source[token.end - 1] == UInt8(ascii: "=") else { return false }
        let first = source[token.start], length = token.end - token.start
        return length == 1 || first != UInt8(ascii: "=") && first != UInt8(ascii: "!")
            && !(length == 2 && (first == UInt8(ascii: "<") || first == UInt8(ascii: ">")))
    }

    private func endsExpression(_ token: JSToken) -> Bool {
        switch token.kind {
        case .number, .string, .regex, .template, .templateTail: return true
        case .identifier: return !Word.operators.contains { isWord(token, $0) }
        case .punctuator: return isPunct(token, ")") || isPunct(token, "]") || isPunct(token, "}") || isIncrement(token)
        default: return false
        }
    }

    /// A token that can't carry on the expression before it across a line
    /// break, so JavaScript ends the statement there.
    private func startsStatement(_ token: JSToken) -> Bool {
        switch token.kind {
        case .number, .string: return true
        case .identifier: return !isWord(token, .in) && !isWord(token, .instanceof)
        case .punctuator: return isIncrement(token)
        default: return false
        }
    }

    /// `++` or `--`.
    private func isIncrement(_ token: JSToken) -> Bool {
        token.kind == .punctuator && token.end - token.start == 2 && source[token.start + 1] == source[token.start]
            && (source[token.start] == UInt8(ascii: "+") || source[token.start] == UInt8(ascii: "-"))
    }
}

/// The last nine tokens with their bracket depth, enough to recognise `X.y("alr","yes")` and what precedes it.
struct RecentTokens {
    private var ring = Array(repeating: (token: JSToken(kind: .end, start: 0, end: 0, newlineBefore: false), level: -1), count: 9)
    private var oldest = 0

    mutating func append(_ token: JSToken, level: Int) {
        ring[oldest] = (token, level)
        oldest = oldest == 8 ? 0 : oldest + 1
    }

    /// The `index`th token, oldest first.
    subscript(index: Int) -> (token: JSToken, level: Int) {
        ring[(oldest + index) % 9]
    }
}
