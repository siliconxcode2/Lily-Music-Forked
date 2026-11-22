import Foundation

/// Keeps only the top-level statements the URL scrambler needs, as yt-dlp's solver (github.com/yt-dlp/ejs)
/// does, so JavaScriptCore loads a few hundred KB, not several MB. Inner scopes aren't tracked, so a
/// shadowing local keeps extra code: harmless, where a missed dependency breaks.
enum PlayerTrimmer {
    enum Key: Hashable {
        case symbol(String)
        /// A property of the player's namespace parameter, `g.X`.
        case namespace(String)
    }

    /// A script that, run as the body of `function (_result) {…}`, sets
    /// `_result.n` and `_result.sig` to functions that unscramble them.
    static func trim(_ source: [UInt8]) throws -> String {
        let layout = YTMError(.parse, "YouTube's player script has an unexpected layout.")
        var reader = try StatementReader(source)

        // var _yt_player={};(function(g){ … })(_yt_player);
        let programStart = reader.token.start
        try reader.skipStatement()
        for opening in ["(", "function", "("] {
            guard reader.text(reader.token) == opening else { throw layout }
            try reader.advance()
        }
        guard reader.token.kind == .identifier else { throw layout }
        let namespace = reader.text(reader.token)
        try reader.advance()
        guard reader.isPunct(reader.token, ")") else { throw layout }
        try reader.advance()
        guard reader.isPunct(reader.token, "{") else { throw layout }
        let bodyStart = reader.token.end
        try reader.advance()

        var statements: [StatementReader.Statement] = []
        while !reader.isPunct(reader.token, "}") {
            guard reader.token.kind != .end else { throw layout }
            // Every statement consumes a token at least, so this moves on.
            statements.append(try reader.topLevelStatement(namespace: namespace))
        }
        let bodyEnd = reader.token.start
        try reader.advance()
        guard reader.isPunct(reader.token, ")") else { throw layout }
        try reader.advance()
        guard reader.isPunct(reader.token, "(") else { throw layout }
        try reader.skipBalanced()
        if reader.isPunct(reader.token, ";") { try reader.advance() }
        guard reader.token.kind == .end, let wrapperEnd = reader.last?.end else { throw layout }

        // The first statement is `var window=this;`, which the stubs
        // replace, though the names it declares still count.
        var declared: Set<String> = [namespace]
        for statement in statements { declared.formUnion(statement.declares) }
        var definedBy: [Key: [Int]] = [:]
        for (index, statement) in statements.enumerated().dropFirst() {
            for key in statement.defines where isTracked(key, declared: declared) {
                definedBy[key, default: []].append(index)
            }
        }
        let scramblers = statements.indices.dropFirst().filter { statements[$0].scrambler != nil }
        guard !scramblers.isEmpty else {
            throw YTMError(.parse, "The URL scrambler wasn't found in YouTube's player script.")
        }

        var keep = [Bool](repeating: false, count: statements.count)
        var pending = scramblers
        while let index = pending.popLast() {
            guard !keep[index] else { continue }
            keep[index] = true
            let uses = try references(in: statements[index], of: source, namespace: namespace, declared: declared)
            for key in uses {
                pending += definedBy[key, default: []].filter { !keep[$0] }
            }
        }

        var out = [UInt8]()
        out.reserveCapacity(512 << 10)
        out += setup.utf8
        out += source[programStart..<bodyStart]
        out.append(UInt8(ascii: "\n"))
        for (statement, kept) in zip(statements, keep) where kept {
            out += source[statement.range]
            // A statement ended by a line break needs a semicolon now that another may follow.
            if !statement.isTerminated { out.append(UInt8(ascii: ";")) }
            out.append(UInt8(ascii: "\n"))
        }
        let solvers = scramblers.compactMap { statements[$0].scrambler }.map { range in
            solver(String(decoding: source[range], as: UTF8.self))
        }
        out += "_result.n = \(multiTry(solvers, field: "n"));\n_result.sig = \(multiTry(solvers, field: "sig"));\n".utf8
        out += source[bodyEnd..<wrapperEnd]
        return String(decoding: out, as: UTF8.self)
    }

    /// A `g.X` property or a top-level name the player declares, not a browser global.
    private static func isTracked(_ key: Key, declared: Set<String>) -> Bool {
        switch key {
        case .namespace: true
        case .symbol(let name): declared.contains(name)
        }
    }

    /// Names after a dot, object keys and the names a `var` list declares aren't uses, and `g.X` depends
    /// only on what defines `g.X`: the player's one long `var` list would otherwise keep everything.
    private static func references(
        in statement: StatementReader.Statement, of source: [UInt8], namespace: String, declared: Set<String>
    ) throws -> Set<Key> {
        var tokenizer = JSTokenizer(source, range: statement.range)
        var found = Set<Key>()
        func isDot(_ token: JSToken?) -> Bool {
            guard let token, token.kind == .punctuator else { return false }
            let length = token.end - token.start
            return source[token.end - 1] == UInt8(ascii: ".")
                && (length == 1 || length == 2 && source[token.start] == UInt8(ascii: "?"))
        }
        func isDeclaring(_ token: JSToken?) -> Bool {
            guard let token else { return false }
            return token.isPunct(",", in: source) || Word.declarations.contains { token.isWord($0, in: source) }
        }
        /// `{a: …}` and `, a: …` name a property rather than use `a`.
        func isPropertyKey(after previous: JSToken?, before next: JSToken) -> Bool {
            guard let previous, next.isPunct(":", in: source) else { return false }
            return previous.isPunct("{", in: source) || previous.isPunct(",", in: source)
        }
        // The two tokens before the current one, and the one after it.
        var older: JSToken?, previous: JSToken?
        var current = try tokenizer.next()
        var depth = 0
        while current.kind != .end {
            let next = try tokenizer.next()
            if current.kind == .identifier {
                if statement.isDeclarationList, depth == 0, isDeclaring(previous) {
                    // A name the list declares.
                } else if isDot(previous) {
                    if let older, older.kind == .identifier, older.text(in: source) == namespace {
                        found.insert(.namespace(current.text(in: source)))
                    }
                } else if !isPropertyKey(after: previous, before: next) {
                    let word = current.text(in: source)
                    if !(word == namespace && isDot(next)), declared.contains(word) {
                        found.insert(.symbol(word))
                    }
                }
            }
            depth += Int(current.nesting)
            (older, previous, current) = (previous, current, next)
        }
        return found
    }

    /// Browser globals the player expects, as yt-dlp's solver stubs them.
    private static let setup = #"""
    if (typeof globalThis.XMLHttpRequest === "undefined") { globalThis.XMLHttpRequest = { prototype: {} }; }
    if (typeof URL === "undefined") { globalThis.location = { hash: "", host: "www.youtube.com", hostname: "www.youtube.com", href: "https://www.youtube.com/watch?v=yt-dlp-wins", origin: "https://www.youtube.com", password: "", pathname: "/watch", port: "", protocol: "https:", search: "?v=yt-dlp-wins", username: "" }; } else { globalThis.location = new URL("https://www.youtube.com/watch?v=yt-dlp-wins"); }
    if (typeof globalThis.document === "undefined") { globalThis.document = Object.create(null); }
    if (typeof globalThis.navigator === "undefined") { globalThis.navigator = Object.create(null); }
    if (typeof globalThis.self === "undefined") { globalThis.self = globalThis; }
    if (typeof globalThis.window === "undefined") { globalThis.window = globalThis; }

    """#

    /// Drives the scrambler as yt-dlp's solver does: build a URL object with
    /// the challenge, run its unscrambling method, and read the result back.
    private static func solver(_ name: String) -> String {
        #"(({sig, n}) => { const url = ("# + name
            + #")("https://youtube.com/watch?v=yt-dlp-wins", "s", sig ? encodeURIComponent(sig) : undefined); url.set("n", n); const proto = Object.getPrototypeOf(url); const keys = Object.keys(proto).concat(Object.getOwnPropertyNames(proto)); for (const key of keys) { if (!["constructor", "set", "get", "clone"].includes(key)) { url[key](); break; } } const s = url.get("s"); return { sig: s ? decodeURIComponent(s) : null, n: url.get("n") ?? null }; })"#
    }

    /// Tries every candidate and insists they agree.
    private static func multiTry(_ solvers: [String], field: String) -> String {
        let candidates = solvers.map { "(\(field)) => \($0)({\(field)}).\(field)" }.joined(separator: ", ")
        return #"(_input) => { const _results = new Set(); const errors = []; for (const _try of ["# + candidates
            + #"]) { try { _results.add(_try(_input)); } catch (e) { errors.push(e); } } if (!_results.size) throw `no solutions: ${errors.join(", ")}`; if (_results.size !== 1) throw "conflicting solutions"; return _results.values().next().value; }"#
    }
}
