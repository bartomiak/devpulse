// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "SysMonitor",
    platforms: [.macOS(.v13)],
    targets: [
        // SMC access (Intel Macs) – written in C because it needs an exact struct layout.
        .target(
            name: "CSMC",
            linkerSettings: [.linkedFramework("IOKit")]
        ),
        .executableTarget(
            name: "SysMonitor",
            dependencies: ["CSMC"]
        ),
    ]
)
