// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "NetMapServer",
    dependencies: [
        .package(url: "https://github.com/vapor/vapor.git",                from: "4.92.0"),
        .package(url: "https://github.com/vapor/fluent.git",               from: "4.9.0"),
        .package(url: "https://github.com/vapor/fluent-sqlite-driver.git", from: "4.6.0"),
        .package(url: "https://github.com/apple/swift-crypto.git",         from: "3.0.0"),
    ],
    targets: [
        .executableTarget(
            name: "App",
            dependencies: [
                .product(name: "Vapor",              package: "vapor"),
                .product(name: "Fluent",             package: "fluent"),
                .product(name: "FluentSQLiteDriver", package: "fluent-sqlite-driver"),
                .product(name: "Crypto",             package: "swift-crypto"),
            ],
            path: "Sources/App"
        ),
        .testTarget(
            name: "AppTests",
            dependencies: [
                "App",
                .product(name: "XCTVapor", package: "vapor"),
            ],
            path: "Tests/AppTests"
        ),
    ]
)
