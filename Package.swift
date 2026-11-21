// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "CanvasTerm",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", revision: "1488fac94f52e3934ffba185b44c2395d4f95d3c"),
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
