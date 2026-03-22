// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "CanvasTerm",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", revision: "3c45fdcfcf4395c72d2a4ee23c0bce79017b5391"),
    ],
    targets: [
        .executableTarget(
            name: "CanvasTerm",
            dependencies: [
                .product(name: "SwiftTerm", package: "SwiftTerm"),
            ],
            path: "CanvasTerm",
            exclude: ["Resources"],
            swiftSettings: [
                .unsafeFlags(["-strict-concurrency=targeted"])
            ]
        ),
    ]
)
