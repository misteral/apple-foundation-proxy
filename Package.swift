// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "apple-foundation-proxy",
    platforms: [
        .macOS(.v14) // We set this to v14, but we'll use #available(macOS 15.4, *) for FoundationModels
    ],
    dependencies: [
        .package(url: "https://github.com/vapor/vapor.git", from: "4.89.0"),
    ],
    targets: [
        .executableTarget(
            name: "apple-foundation-proxy",
            dependencies: [
                .product(name: "Vapor", package: "vapor")
            ],
            path: "Sources"
        )
    ]
)
