// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Cyclop",
    // macOS 15 for Translation.framework, which the translate tab runs on.
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "Cyclop", targets: ["Cyclop"])
    ],
    targets: [
        .executableTarget(
            name: "Cyclop",
            path: "Sources/Cyclop",
            swiftSettings: [.swiftLanguageMode(.v6)]
        )
    ]
)
