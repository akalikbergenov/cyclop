// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Cyclop",
    // macOS 15 for Translation.framework, which the translate tab runs on.
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "Cyclop", targets: ["Cyclop"])
    ],
    // Единственная зависимость, и точная версия, а не диапазон: Sparkle
    // ставит обновления на чужие машины, и что именно ставит их, решается
    // правкой здесь, а не тем, что вышло вчера. Поднимать — вместе с
    // SPARKLE_VERSION в release.yml, оттуда берётся sign_update.
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.0")
    ],
    targets: [
        .executableTarget(
            name: "Cyclop",
            dependencies: [.product(name: "Sparkle", package: "Sparkle")],
            path: "Sources/Cyclop",
            swiftSettings: [.swiftLanguageMode(.v6)],
            // Sparkle.framework кладётся в Contents/Frameworks (bundle.sh), а
            // загрузчик сам туда не смотрит — путь ему называется здесь.
            linkerSettings: [
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])
            ]
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
