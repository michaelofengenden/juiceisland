// swift-tools-version: 6.2
import PackageDescription

// Upstream's Core tests start real BridgeServers, and every BridgeServer also rebinds the legacy
// /tmp/open-island-<uid>.sock after deleting it. They are part of the package only when scripts/test.sh sets
// JUICE_ISLAND_BRIDGE_TESTS=1 after checking that no island app owns a hook socket, so a bare `swift test` is safe.
let bridgeTests = Context.environment["JUICE_ISLAND_BRIDGE_TESTS"] == "1"

let package = Package(
    name: "JuiceIsland",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "IslandEngine", targets: ["IslandEngine"]),
        .library(name: "JuiceIslandUI", targets: ["JuiceIslandUI"]),
        // The superset helper (spec §3.2, §3.8): same product name and path as upstream's, so hook commands never change.
        .executable(name: "OpenIslandHooks", targets: ["IslandHooks"]),
    ],
    dependencies: [
        .package(path: "JuiceCore"),
    ],
    targets: [
        .target(name: "OpenIslandCore", path: "Vendor/open-vibe-island/Sources/OpenIslandCore"),
        // Upstream's helper, compiled by path and unchanged. Its `@main` entry is emitted under another name so the
        // superset helper's own main can run it after the context note (Sources/IslandHooksEntry declares it).
        .target(name: "OpenIslandHooksUpstream", dependencies: ["OpenIslandCore"], path: "Vendor/open-vibe-island/Sources/OpenIslandHooks",
                swiftSettings: [.unsafeFlags(["-Xfrontend", "-entry-point-function-name", "-Xfrontend", "open_island_hooks_upstream_main"])]),
        .target(name: "IslandHooksEntry"),
        .target(name: "IslandHookNotes", dependencies: ["OpenIslandCore"]),
        .executableTarget(name: "IslandHooks", dependencies: ["IslandHookNotes", "IslandHooksEntry", "OpenIslandHooksUpstream"]),
        .target(name: "IslandEngine", dependencies: ["OpenIslandCore", "IslandHookNotes", .product(name: "JuiceCore", package: "JuiceCore")]),
        // Measures transcript discovery on this Mac's rollouts and transcripts, read-only, printing numbers only (P83,
        // P84, P85). Never part of the app: `swift run -c release RolloutScanMeasure <mode>`, the modes listed in its
        // main.swift.
        .executableTarget(name: "RolloutScanMeasure", dependencies: ["IslandEngine", "OpenIslandCore",
                                                                     .product(name: "JuiceCore", package: "JuiceCore")]),
        .testTarget(name: "VendorEngineTests", dependencies: ["IslandEngine", "OpenIslandCore"]),
        .testTarget(name: "IslandEngineTests", dependencies: ["IslandEngine", "OpenIslandCore", "IslandHookNotes", "IslandHooks",
                                                              .product(name: "JuiceCore", package: "JuiceCore")]),
        // The app's views, models and AppKit shell. The Xcode app target (project.yml) is only App/Main/main.swift, so
        // `swift test` renders every view headless (ImageRenderer) without building or launching the app.
        .target(name: "JuiceIslandUI", dependencies: ["IslandEngine", "OpenIslandCore", .product(name: "JuiceCore", package: "JuiceCore")],
                path: "App", exclude: ["Main"]),
        // The needs-you end-to-end suite runs the built helper (`IslandHooks`) against the engine and the model.
        .testTarget(name: "JuiceIslandUITests", dependencies: ["JuiceIslandUI", "IslandEngine", "OpenIslandCore", "IslandHookNotes", "IslandHooks",
                                                               .product(name: "JuiceCore", package: "JuiceCore")]),
    ] + (bridgeTests ? [
        .testTarget(name: "OpenIslandCoreTests", dependencies: ["OpenIslandCore"], path: "Vendor/open-vibe-island/Tests/OpenIslandCoreTests"),
    ] : [])
)
