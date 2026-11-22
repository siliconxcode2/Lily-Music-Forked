import Foundation

struct JSToken {
    enum Kind: UInt8 {
        case identifier, number, string, regex, punctuator
        /// A template literal without substitutions: `` `…` ``.
        case template
        /// `` `…${ ``, which opens a substitution as a bracket does.
        case templateHead
        /// `` }…${ ``, between two substitutions.
        case templateMiddle
        /// `` }…` ``, which closes the last substitution.
        case templateTail
        case end
    }

    let kind: Kind
    let start: Int
    let end: Int
    /// A line break before this token can end a statement that has no semicolon.
    let newlineBefore: Bool
    /// 1 for a bracket that opens (`(`, `[`, `{` and `` `…${ ``), -1 for
    /// one that closes, 0 for the rest.
    var nesting: Int8 = 0
}

extension JSToken {
    func text(in source: [UInt8]) -> String {
        String(decoding: source[start..<end], as: UTF8.self)
    }

    func isPunct(_ c: Unicode.Scalar, in source: [UInt8]) -> Bool {
        kind == .punctuator && end - start == 1 && source[start] == UInt8(ascii: c)
    }

    func isWord(_ word: Word, in source: [UInt8]) -> Bool {
        kind == .identifier && source[start..<end].elementsEqual(word.bytes)
    }
}

struct Word: Sendable {
    let bytes: [UInt8]

    private init(_ word: String) {
        bytes = Array(word.utf8)
    }

    static let function = Word("function"), async = Word("async"), `class` = Word("class"),
        extends = Word("extends"), `var` = Word("var"), `let` = Word("let"), const = Word("const"),
        `if` = Word("if"), `else` = Word("else"), `for` = Word("for"), `while` = Word("while"),
        with = Word("with"), `do` = Word("do"), `try` = Word("try"), `catch` = Word("catch"),
        finally = Word("finally"), `switch` = Word("switch"), `await` = Word("await"), this = Word("this"),
        `super` = Word("super"), `in` = Word("in"), instanceof = Word("instanceof")

    static let declarations: [Word] = [.var, .let, .const]

    /// Words that begin a statement other than an expression.
    static let statements: [Word] = [
        .if, .for, .while, .with, .do, .try, .switch, Word("return"), Word("throw"), Word("break"),
        Word("continue"), Word("debugger"),
    ]

    /// Words that take an operand, so never end an expression and may be followed by a regular expression.
    static let operators: [Word] = [
        .in, .instanceof, Word("of"), Word("typeof"), Word("new"), Word("delete"), Word("void"), Word("return"),
        Word("throw"), Word("case"), .do, .else, Word("yield"), .await,
    ]
}
