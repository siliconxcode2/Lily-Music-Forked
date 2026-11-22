import SwiftUI

/// Covers only the commands Material Symbols use: moves, lines, cubic curves
/// (with the smooth form) and closing, absolute and relative.
nonisolated enum SVGPath {
    static func parse(_ data: String) -> Path {
        var scanner = Scanner(bytes: Array(data.utf8))
        var path = Path()
        var current = CGPoint.zero
        var start = CGPoint.zero
        // The last curve's second control point, for the smooth form.
        var lastControl: CGPoint?
        var command: UInt8 = 0

        while let next = scanner.command(after: command) {
            command = next
            let relative = command >= UInt8(ascii: "a")
            let origin = relative ? current : .zero
            func point() -> CGPoint? {
                guard let x = scanner.number(), let y = scanner.number() else { return nil }
                return CGPoint(x: origin.x + x, y: origin.y + y)
            }
            var control: CGPoint?
            switch command | 0x20 {
            case UInt8(ascii: "m"):
                guard let p = point() else { return path }
                path.move(to: p)
                current = p
                start = p
                // Further pairs after a move are lines.
                command = relative ? UInt8(ascii: "l") : UInt8(ascii: "L")
            case UInt8(ascii: "l"):
                guard let p = point() else { return path }
                path.addLine(to: p)
                current = p
            case UInt8(ascii: "h"):
                guard let x = scanner.number() else { return path }
                current.x = origin.x + x
                path.addLine(to: current)
            case UInt8(ascii: "v"):
                guard let y = scanner.number() else { return path }
                current.y = origin.y + y
                path.addLine(to: current)
            case UInt8(ascii: "c"):
                guard let c1 = point(), let c2 = point(), let p = point() else { return path }
                path.addCurve(to: p, control1: c1, control2: c2)
                control = c2
                current = p
            case UInt8(ascii: "s"):
                guard let c2 = point(), let p = point() else { return path }
                path.addCurve(to: p, control1: reflected(lastControl, about: current), control2: c2)
                control = c2
                current = p
            case UInt8(ascii: "z"):
                path.closeSubpath()
                current = start
            default:
                return path
            }
            lastControl = control
        }
        return path
    }

    /// The previous control point mirrored through `point`, or `point`
    /// itself when the previous segment was not a curve.
    private static func reflected(_ control: CGPoint?, about point: CGPoint) -> CGPoint {
        guard let control else { return point }
        return CGPoint(x: 2 * point.x - control.x, y: 2 * point.y - control.y)
    }

    /// Reads commands and numbers, which SVG lets run together: "1.1.9" is
    /// 1.1 and .9, and "2-.5" is 2 and -.5.
    private struct Scanner {
        let bytes: [UInt8]
        var index = 0

        /// The next command letter, or `previous` repeated when numbers
        /// follow without one; nil at the end.
        mutating func command(after previous: UInt8) -> UInt8? {
            skipSeparators()
            guard index < bytes.count else { return nil }
            let byte = bytes[index]
            if Self.isLetter(byte) {
                index += 1
                return byte
            }
            // Implicit repeats need a previous command that takes numbers.
            return previous == 0 || previous | 0x20 == UInt8(ascii: "z") ? nil : previous
        }

        mutating func number() -> CGFloat? {
            skipSeparators()
            let begin = index
            if index < bytes.count, bytes[index] == UInt8(ascii: "-") || bytes[index] == UInt8(ascii: "+") { index += 1 }
            var seenPoint = false
            var seenExponent = false
            while index < bytes.count {
                let byte = bytes[index]
                if Self.isDigit(byte) {
                    index += 1
                } else if byte == UInt8(ascii: "."), !seenPoint, !seenExponent {
                    seenPoint = true
                    index += 1
                } else if byte | 0x20 == UInt8(ascii: "e"), !seenExponent, index > begin {
                    seenExponent = true
                    index += 1
                    if index < bytes.count, bytes[index] == UInt8(ascii: "-") || bytes[index] == UInt8(ascii: "+") { index += 1 }
                } else {
                    break
                }
            }
            guard index > begin, let text = String(bytes: bytes[begin..<index], encoding: .ascii),
                  let value = Double(text)
            else { return nil }
            return CGFloat(value)
        }

        private mutating func skipSeparators() {
            while index < bytes.count, bytes[index] == UInt8(ascii: " ") || bytes[index] == UInt8(ascii: ",")
                || bytes[index] == UInt8(ascii: "\n") || bytes[index] == UInt8(ascii: "\t") {
                index += 1
            }
        }

        private static func isDigit(_ byte: UInt8) -> Bool {
            byte >= UInt8(ascii: "0") && byte <= UInt8(ascii: "9")
        }

        private static func isLetter(_ byte: UInt8) -> Bool {
            let lower = byte | 0x20
            return lower >= UInt8(ascii: "a") && lower <= UInt8(ascii: "z") && lower != UInt8(ascii: "e")
        }
    }
}
