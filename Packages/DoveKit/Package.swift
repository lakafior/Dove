// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "DoveKit",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "DoveKit", targets: ["DoveKit"]),
        // The app's models (AppModel and the feature models), shared by the iOS and macOS apps. No UIKit or
        // AppKit: what differs per platform comes through `AppPlatform`.
        .library(name: "DoveAppCore", targets: ["DoveAppCore"])
    ],
    targets: [
        .target(name: "DoveKit"),
        .target(name: "DoveAppCore", dependencies: ["DoveKit"]),
        .testTarget(
            name: "DoveKitTests",
            dependencies: ["DoveKit"],
            resources: [.copy("Fixtures")]
        ),
        .testTarget(name: "DoveAppCoreTests", dependencies: ["DoveAppCore"])
    ]
)
