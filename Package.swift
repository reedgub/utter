// swift-tools-version:5.9
import PackageDescription

// UtterCore is plain Foundation (config, hotkey logic, state machine, API clients)
// so it builds and tests anywhere. The Utter app target needs AppKit, so it is
// only added on macOS.
var targets: [Target] = [
    .target(name: "UtterCore"),
    .testTarget(name: "UtterCoreTests", dependencies: ["UtterCore"]),
]

#if os(macOS)
targets.append(
    .executableTarget(
        name: "Utter",
        dependencies: ["UtterCore"],
        linkerSettings: [
            .linkedFramework("AppKit"),
            .linkedFramework("AVFoundation"),
            .linkedFramework("Carbon"),
            .linkedFramework("ServiceManagement"),
        ]
    )
)
#endif

let package = Package(
    name: "Utter",
    platforms: [.macOS(.v13)],
    targets: targets
)
