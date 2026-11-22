// swift-tools-version: 6.4
import PackageDescription

let strict: [SwiftSetting] = [
    .enableUpcomingFeature("ExistentialAny"),
]

let package = Package(
    name: "YTMKit",
    platforms: [.iOS("26.0"), .macOS("27.0")],
    products: [
        .library(name: "YTMCore", targets: ["YTMCore"]),
        .library(name: "YTMAudio", targets: ["YTMAudio"]),
        .library(name: "YTMPlayback", targets: ["YTMPlayback"]),
    ],
    targets: [
        // Foundation and Apple frameworks only.
        .target(name: "YTMCore", swiftSettings: strict),
        // Knows nothing of YouTube.
        .target(name: "YTMAudio", swiftSettings: strict),
        .target(name: "YTMPlayback", dependencies: ["YTMCore", "YTMAudio"], swiftSettings: strict),
        // A macOS command line check that talks to YouTube for real.
        .executableTarget(name: "ytmcheck", dependencies: ["YTMCore", "YTMAudio"], swiftSettings: strict),
        .testTarget(name: "YTMCoreTests", dependencies: ["YTMCore"], swiftSettings: strict),
        .testTarget(name: "YTMAudioTests", dependencies: ["YTMAudio"], swiftSettings: strict),
        .testTarget(name: "YTMPlaybackTests", dependencies: ["YTMPlayback"], swiftSettings: strict),
    ],
    swiftLanguageModes: [.v6]
)
