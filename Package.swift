// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "DevPulse",
    platforms: [.macOS(.v13)],
    targets: [
        // SMC access (Intel Macs) – written in C because it needs an exact struct layout.
        .target(
            name: "CSMC",
            linkerSettings: [.linkedFramework("IOKit")]
        ),
        .executableTarget(
            name: "DevPulse",
            dependencies: ["CSMC"]
        ),
    ]
)
