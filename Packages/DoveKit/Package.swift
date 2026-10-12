// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "DoveKit",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "DoveKit", targets: ["DoveKit"])
    ],
    targets: [
        .target(name: "DoveKit"),
        .testTarget(
            name: "DoveKitTests",
            dependencies: ["DoveKit"],
            resources: [.copy("Fixtures")]
        )
    ]
)
