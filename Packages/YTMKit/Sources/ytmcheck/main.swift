import Foundation
import YTMCore

// ytmcheck: YTMCore and YTMAudio against live YouTube, signed out. Run with
// `swift run ytmcheck <command>`; exits non-zero when a check fails.

/// In the order `all` runs them.
let groups: [(name: String, run: @MainActor (Report) async -> Void)] = [
    ("pages", { await PageChecks.run($0); await CatalogueChecks.run($0) }),
    ("streams", StreamChecks.run),
    ("premium", PremiumChecks.run),
    ("audio", AudioChecks.run),
    ("lyrics", LyricsChecks.run),
    ("radio", RadioChecks.run),
]

let usage = """
    usage: ytmcheck <command>
      all | \(groups.map(\.name).joined(separator: " | "))   run checks and print a pass/fail report
      search <query>                              print a search page in full
      index [videoId]                             hold each file's seek index against its packets
      page <route>                                print a page in full: home, explore, charts,
                                                  new-releases, moods, album:<id>, artist:<id>,
                                                  playlist:<id>, genre:<params>, browse:<id>[:<params>],
                                                  or a bare browse or playlist ID
    """

/// Leaves nothing of the run behind on disk.
func finish(_ status: Int32) -> Never {
    try? FileManager.default.removeItem(at: Live.directory)
    exit(status)
}

let arguments = CommandLine.arguments.dropFirst()
let command = arguments.first ?? ""
let rest = arguments.dropFirst().joined(separator: " ")

guard await Live.requireSignedOut() else {
    print("ytmcheck runs signed out, but this Mac holds the app's Google session.")
    finish(2)
}

let selected = command == "all" ? groups : groups.filter { $0.name == command }
if !selected.isEmpty {
    let report = Report()
    for group in selected {
        print("— \(group.name)")
        await group.run(report)
    }
    finish(report.summarise() ? 0 : 1)
}

if command == "index" {
    do {
        finish(try await IndexInspect.show(rest) ? 0 : 1)
    } catch {
        print("error: \(error)")
        finish(1)
    }
}

let route: Route? = switch command {
case "search": rest.isEmpty ? nil : .search(rest)
case "page": Inspect.route(rest)
default: nil
}
guard let route else {
    print(usage)
    finish(2)
}
do {
    try await Inspect.show(route)
} catch {
    print("error: \(error)")
    finish(1)
}
finish(0)
