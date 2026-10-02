// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "JuiceCore",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "JuiceCore", targets: ["JuiceCore"]),
        .executable(name: "juice-probe", targets: ["juice-probe"]),
    ],
    targets: [
        .target(name: "JuiceCore", swiftSettings: [.swiftLanguageMode(.v6)]),
        .executableTarget(name: "juice-probe", dependencies: ["JuiceCore"], swiftSettings: [.swiftLanguageMode(.v6)]),
        .testTarget(
            name: "JuiceCoreTests",
            dependencies: ["JuiceCore"],
            resources: [.copy("Fixtures")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
