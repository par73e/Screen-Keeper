// swift-tools-version:6.2
import PackageDescription

let package = Package(
    name: "ScreenMaintainer",
    platforms: [
        .macOS(.v26)
    ],
    targets: [
        .executableTarget(
            name: "ScreenMaintainer",
            path: "Sources/ScreenMaintainer",
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        )
    ]
)
