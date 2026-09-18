// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "codex-switch",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "codex-switch", targets: ["CodexSwitchCLI"]),
        .executable(name: "CodexSwitchSelfTest", targets: ["CodexSwitchSelfTest"]),
        .library(name: "CodexSwitchKit", targets: ["CodexSwitchKit"])
    ],
    targets: [
        .target(name: "CodexSwitchKit", path: "Sources/CodexSwitchKit"),
        .target(
            name: "CodexSwitchCLIKit",
            dependencies: ["CodexSwitchKit"],
            path: "Sources/CodexSwitchCLIKit"
        ),
        .executableTarget(
            name: "CodexSwitchCLI",
            dependencies: ["CodexSwitchCLIKit"],
            path: "Sources/CodexSwitchCLI"
        ),
        .executableTarget(
            name: "CodexSwitchSelfTest",
            dependencies: ["CodexSwitchKit", "CodexSwitchCLIKit"],
            path: "Sources/CodexSwitchSelfTest"
        )
    ]
)
