// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Lucida",
    platforms: [.iOS(.v15), .macOS(.v12)],
    products: [.library(name: "Lucida", targets: ["Lucida"])],
    targets: [
        .target(name: "Lucida"),
        .testTarget(name: "LucidaTests", dependencies: ["Lucida"], resources: []),
    ]
)
