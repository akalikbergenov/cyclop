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
        ),
        // Только чистые сторы — разбор файла, дедупликация, порядок. Панель
        // сюда не входит и не должна: вырез, наведение и раскладка рельса
        // проверяются глазами, а тест на них врал бы чаще, чем ловил (#65).
        .testTarget(
            name: "CyclopTests",
            dependencies: ["Cyclop"],
            path: "Tests/CyclopTests",
            swiftSettings: [.swiftLanguageMode(.v6)]
        )
    ]
)
