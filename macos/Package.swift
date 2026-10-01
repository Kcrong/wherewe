// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "Wherewe",
    platforms: [
        .macOS(.v26),
    ],
    products: [
        .library(
            name: "MeetingTranscriberCore",
            targets: ["MeetingTranscriberCore"]
        ),
        .executable(
            name: "Wherewe",
            targets: ["MeetingTranscriberApp"]
        ),
        .executable(
            name: "MeetingTranscriberCoreChecks",
            targets: ["MeetingTranscriberCoreChecks"]
        ),
    ],
    dependencies: [],
    targets: [
        .target(
            name: "MeetingTranscriberCore"
        ),
        .executableTarget(
            name: "MeetingTranscriberApp",
            dependencies: ["MeetingTranscriberCore"]
        ),
        .executableTarget(
            name: "MeetingTranscriberCoreChecks",
            dependencies: ["MeetingTranscriberCore"]
        ),
        .testTarget(
            name: "MeetingTranscriberCoreTests",
            dependencies: ["MeetingTranscriberCore"]
        ),
    ]
)
