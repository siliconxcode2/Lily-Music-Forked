import Foundation

/// Problems fail a check; notes only describe what it saw.
struct Findings {
    private(set) var problems: [String] = []
    private(set) var notes: [String] = []

    mutating func expect(_ condition: Bool, _ problem: @autoclosure () -> String) {
        if !condition { problems.append(problem()) }
    }

    mutating func fail(_ problem: String) {
        problems.append(problem)
    }

    mutating func note(_ note: String) {
        notes.append(note)
    }
}

@MainActor final class Report {
    private var passed = 0
    private var failed: [String] = []
    private let clock = ContinuousClock()

    /// A thrown error fails the check.
    func check(_ name: String, _ body: (inout Findings) async throws -> Void) async {
        var findings = Findings()
        let started = clock.now
        do {
            try await body(&findings)
        } catch {
            findings.fail("threw: \(error)")
        }
        let elapsed = (clock.now - started).formatted(.units(allowed: [.seconds, .milliseconds], width: .narrow))
        let ok = findings.problems.isEmpty
        print("\(ok ? "PASS" : "FAIL")  \(name)  (\(elapsed))")
        for note in findings.notes { print("        \(note)") }
        for problem in findings.problems.prefix(Self.problemsShown) { print("      ✗ \(problem)") }
        if findings.problems.count > Self.problemsShown {
            print("      ✗ …and \(findings.problems.count - Self.problemsShown) more")
        }
        if ok { passed += 1 } else { failed.append(name) }
    }

    /// True when every check passed.
    func summarise() -> Bool {
        print("\n\(passed) passed, \(failed.count) failed")
        for name in failed { print("  FAIL \(name)") }
        return failed.isEmpty
    }

    private static let problemsShown = 12
}
