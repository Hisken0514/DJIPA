// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "DJIPA",
    platforms: [.macOS(.v13)],
    targets: [
        .target(name: "AudioCore", linkerSettings: [.linkedFramework("CoreAudio")]),
        .executableTarget(name: "DJIPA", dependencies: ["AudioCore"]),
    ]
)
