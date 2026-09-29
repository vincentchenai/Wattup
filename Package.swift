// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Wattup",
    platforms: [
        // macOS 14 起才有 .contentTransition(.numericText())、.symbolEffect、.animation(.smooth)
        .macOS(.v14)
    ],
    targets: [
        .executableTarget(
            name: "Wattup",
            path: "Sources/Wattup",
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        )
    ]
)
