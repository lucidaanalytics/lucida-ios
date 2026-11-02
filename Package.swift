// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Lucida",
    platforms: [.iOS(.v15), .macOS(.v12)],
    products: [
        .library(name: "Lucida", targets: ["Lucida"]),
        .library(name: "LucidaOpenFeature", targets: ["LucidaOpenFeature"]),
    ],
    dependencies: [
        // Apache-2.0; only the LucidaOpenFeature target links it.
        .package(url: "https://github.com/open-feature/swift-sdk.git", from: "0.3.0"),
    ],
    targets: [
        .target(name: "Lucida"),
        .target(
            name: "LucidaOpenFeature",
            dependencies: ["Lucida", .product(name: "OpenFeature", package: "swift-sdk")]),
        .testTarget(name: "LucidaTests", dependencies: ["Lucida"], resources: []),
        .testTarget(name: "LucidaOpenFeatureTests", dependencies: ["LucidaOpenFeature", "Lucida"]),
    ]
)
