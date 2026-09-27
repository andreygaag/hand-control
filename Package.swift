// swift-tools-version: 6.0
import Foundation
import PackageDescription

// A bare CLI binary has no bundle; this embeds an Info.plist (NSCameraUsageDescription,
// bundle id) into __TEXT,__info_plist so the binary itself carries a usage string.
// It does not change TCC's responsible process: when launched from a terminal, the
// terminal's own permission and usage string usually decide. Absolute path: the
// linker's cwd is not guaranteed.
let infoPlist = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .appendingPathComponent("Support/Info.plist").path

let package = Package(
    name: "hand-control",
    platforms: [.macOS(.v14)],
    targets: [
        // Pure logic: features, kNN, debouncing, config, log parsing. Unit-tested.
        .target(name: "HandControlCore"),
        // OS integration shared by the CLI and the app: camera, Vision, key events, engine.
        .target(name: "HandControlEngine", dependencies: ["HandControlCore"]),
        // Menu bar app; packaged into HandControl.app by scripts/build-app.sh with
        // Support/App-Info.plist as the bundle's Info.plist (the CLI embeds Support/Info.plist).
        .executableTarget(name: "HandControlApp", dependencies: ["HandControlEngine"]),
        .executableTarget(
            name: "hand-control",
            dependencies: ["HandControlCore", "HandControlEngine"],
            linkerSettings: [
                .unsafeFlags(["-Xlinker", "-sectcreate", "-Xlinker", "__TEXT",
                              "-Xlinker", "__info_plist", "-Xlinker", infoPlist]),
            ]
        ),
        .testTarget(name: "HandControlCoreTests", dependencies: ["HandControlCore"]),
        // Only hardware-free pieces (lock, paths); camera, Vision and key events are not
        // exercised here.
        .testTarget(name: "HandControlEngineTests", dependencies: ["HandControlEngine"]),
    ]
)
