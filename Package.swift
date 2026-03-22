// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "CanvasTerm",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", branch: "main"),
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
